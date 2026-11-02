#!/usr/bin/env python3
"""Boot and verify the write-failure e2e image.

The checker has a host-only selftest (`--selftest`) because the post-run
comparators are bespoke invariants, not a host-reference corpus.  Each
mutation builds a wrong poststate and requires this checker to reject it.
"""
import copy
import os
import re
import sys
import time
from dataclasses import dataclass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
import e2e_compare as C  # noqa: E402
import build_writefail_image as B  # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'writefail.po')

R_SCRIPT_FD = 0x1200
R_SH_PID = 0x1201
R_SH_WAIT = 0x1202
R_SH_STATUS = 0x1203
R_DONE = 0x1290
R_ERR = 0x1291
R_STEP = 0x1292

STEP_CYCLES = 5_000_000
MAX_STEPS = 2000

STATUS_LABELS = ['cp', 'mv', 'mkdir', 'tee', 'ed', 'redir', 'append']
EXPECTED_STATUS = {
    'cp': 1,
    'mv': 1,
    'mkdir': 1,
    'tee': 1,
    # ed's `w` to the locked target fails: `?` on stdout (below) AND a
    # nonzero exit. ed reads its commands from a SCRIPT here (non-tty
    # stdin), so a command error is a session error -- POSIX ed "exit
    # >0 if an error occurred", real /bin/ed exits 2 on this exact
    # script, and maux's ED_ERRSTAT model (EX2, shared with ex's
    # oracle-validated `ex -s` nonzero-on-error) reports 1. Was 0 here
    # until 2026-09-07; that predated EX2 and disagreed with every ed
    # oracle (see the note below EXPECTED_STATUS).
    'ed': 1,
    # `>` fails in the SHELL (the CREATE inside OPEN_REDIR_WR), so the
    # child never runs: sh's own $? must say so.
    'redir': 1,
    # `>>` opens the locked file fine and the CHILD's write fails, so
    # this one is stdio's error path end to end: PUTS records the
    # errno, EXIT turns echo's zero status into EXIT_WRFAIL.
    'append': 1,
}
# RETIRED 2026-08-24, BY THE FIX. All three pins -- tee exiting 0 on a
# locked target, ed's `w` printing no `?`, and `echo REDIR > FILE`
# leaving `$?` at 0 -- were ONE root cause: src/liba/stdio.s's flush did
# `bcs :wdone` and then reset the byte count "even on a partial/failed
# write", so a failed SC_WRITE left no trace anywhere.  stdio.s now
# records the errno per fd in SIO_ERR and delivers it at FCLOSE (carry +
# errno, for a file the program can name) or at EXIT (a zero status
# becomes EXIT_WRFAIL, for a stream nobody closes -- which is the
# redirected-stdout case).  src/bin/tee.s reports `tee: cannot write
# <path>`; src/bin/ed.s checks both SC_WRITEs in ED_CMD_W and answers
# `?`.  KNOWN_DEFECTS is empty and PINNED_STATUS is gone: every status
# and every capture below is now asserted EXACTLY, and the run went from
# three green PINNED DEFECT lines to none.
#
# ed's status is NONZERO on a failed `w` (EXPECTED_STATUS above), and
# that is not a contradiction of "`w` failing is one command, not a
# failed editor": the error still surfaces as `?` on stdout (ed's whole
# error vocabulary, asserted in the captures below), AND it surfaces in
# the exit status because stdin here is a SCRIPT, not a tty. That is
# what real ed does -- POSIX "exit >0 if an error occurred", /bin/ed
# exits 2 on this script -- and what maux's own ex already does for a
# refused command under `ex -s` (EX2, oracle-checked against /usr/bin/ex).
# This gate expected 0 until 2026-09-07; that expectation predated EX2
# and was never oracle-true. Reverting ed to exit 0 was not an option:
# it would undo the EX2 behavior posix-ex now pins.
KNOWN_DEFECTS = {}

FILES_TO_READ = [
    '/E2E/ST',
    '/E2E/CPNF',
    '/E2E/MVNF',
    '/E2E/MKNF',
    '/E2E/TEEP',
    '/E2E/EDP',
    '/WF/CPSRC',
    '/WF/MVDIR/MVSRC',
    '/WF/TEESRC',
    '/WF/PROT',
    '/WF/EDSCRIPT',
    '/WF/CPNEW',
    '/WF/MVDST/MVSRC',
]
ENTRIES_TO_CHECK = FILES_TO_READ + ['/WF/NEWDIR']

EXPECTED_FILES = {
    '/WF/CPSRC': B.CPSRC_BYTES,
    '/WF/MVDIR/MVSRC': B.MVSRC_BYTES,
    '/WF/TEESRC': B.TEESRC_BYTES,
    '/WF/EDSCRIPT': B.EDSCRIPT_BYTES,
}
ABSENT_AFTER = ['/WF/CPNEW', '/WF/MVDST/MVSRC', '/WF/NEWDIR']


@dataclass
class PostState:
    files: dict
    entries: set
    access: dict
    free_blocks: int


def peek_aux1(client, addr, count=1):
    return client.call_tool('peek', {
        'addr': addr, 'count': count, 'bank': 'aux', 'aux_bank': 1,
    })['bytes']


def run_emulator(disk):
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-writefail] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-writefail] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')
        t0 = time.time()
        done = 0
        for i in range(MAX_STEPS):
            client.call_tool('step', {'cycles': STEP_CYCLES})
            done = peek_aux1(client, R_DONE)[0]
            if done in (0xAA, 0xEE):
                break
        elapsed = time.time() - t0
        return {
            'done': done,
            'err': peek_aux1(client, R_ERR)[0],
            'step': peek_aux1(client, R_STEP)[0],
            'sh_pid': peek_aux1(client, R_SH_PID)[0],
            'sh_wait': peek_aux1(client, R_SH_WAIT)[0],
            'sh_status': peek_aux1(client, R_SH_STATUS)[0],
            'steps': i + 1,
            'seconds': elapsed,
        }
    finally:
        client.close()


def read_poststate(disk):
    vol = prodos.Volume(disk, readonly=True)
    try:
        files = {}
        entries = set()
        access = {}
        for path in ENTRIES_TO_CHECK:
            try:
                ent = vol.entry_for(path)
            except FileNotFoundError:
                continue
            entries.add(path)
            access[path] = ent.access
            if not ent.is_dir():
                files[path] = vol.read_file(path)
        return PostState(files, entries, access, vol.free_blocks)
    finally:
        vol.close()


def decoded_file(state, path, failures):
    if path not in state.files:
        failures.append(f'{path} was not created')
        return b''
    text, problems = C.decode_maux_text(state.files[path])
    if problems:
        failures.append(f'{path} has {len(problems)} low-bit byte(s); '
                        f'first at {problems[0]}')
    return text


def check_status_log(state, failures):
    text = decoded_file(state, '/E2E/ST', failures)
    try:
        got = [int(tok) for tok in text.split()]
    except ValueError:
        failures.append(f'/E2E/ST is not a list of integer statuses: '
                        f'{text!r}')
        return
    if len(got) != len(STATUS_LABELS):
        failures.append(f'/E2E/ST has {len(got)} statuses, expected '
                        f'{len(STATUS_LABELS)}: {text!r}')
        return
    for label, status in zip(STATUS_LABELS, got):
        want = EXPECTED_STATUS[label]
        if status != want:
            failures.append(f'{label} status expected {want}, got {status}')


def check_captures(state, failures):
    cp = decoded_file(state, '/E2E/CPNF', failures)
    if cp != b'cp: error\n':
        failures.append(f'cp diagnostic expected b"cp: error\\n", got {cp!r}')

    mv = decoded_file(state, '/E2E/MVNF', failures)
    mv_re = rb'^mv: cannot move /mnt/MAUX/WF/MVDIR/MVSRC errno=\$[0-9A-F]{2}\n$'
    if re.match(mv_re, mv) is None:
        failures.append(f'mv diagnostic has wrong shape: {mv!r}')

    mk = decoded_file(state, '/E2E/MKNF', failures)
    want_mk = b'mkdir: cannot create /mnt/MAUX/WF/NEWDIR\n'
    if mk != want_mk:
        failures.append(f'mkdir diagnostic expected {want_mk!r}, got {mk!r}')

    # 2026-08-29: the diagnostic became "cannot open" -- tee adopted
    # liba CREAT (create-or-truncate), so a write-locked target now
    # fails AT THE OPEN (SET_EOF $4E refused, fd closed), which is
    # where host tee fails too (EACCES at open). Everything else
    # holds: status 1, PROT byte-identical, diagnostic first.
    # The DIAGNOSTIC comes first and the payload second, and that
    # order is a property of the buffering, not an accident. Under the
    # probed policy (docs/PERF-PLAN.md step 4, 2026-08-28) stdout to
    # the capture file is FULLY buffered, so the payload reaches the
    # capture only at the exit flush; the named locked file's error is
    # detected at its FCLOSE flush, whose stderr line (line mode)
    # lands immediately -- before the exit. Pre-policy, fd 1 was
    # line-buffered and the payload landed first; that order is now
    # one of the selftest's mutations.
    tee = decoded_file(state, '/E2E/TEEP', failures)
    want_tee = (b'tee: cannot open /mnt/MAUX/WF/PROT\n' +
                B.TEESRC_TEXT.encode('ascii'))
    if tee != want_tee:
        failures.append(f'tee capture expected {want_tee!r}, got {tee!r}')

    ed = decoded_file(state, '/E2E/EDP', failures)
    if ed != b'?\n':
        failures.append(f'ed capture expected b"?\\n", got {ed!r}')


def check_volume_poststate(state, failures):
    if state.free_blocks != 0:
        failures.append(f'volume free_blocks expected 0 after run, got '
                        f'{state.free_blocks}')
    for path, want in EXPECTED_FILES.items():
        got = state.files.get(path)
        if got != want:
            failures.append(f'{path} changed or disappeared')
    got_prot = state.files.get('/WF/PROT')
    if got_prot != B.PROT_BYTES:
        failures.append('/WF/PROT changed under a protected write attempt')
    got_access = state.access.get('/WF/PROT')
    if got_access != B.LOCKED_ACCESS:
        failures.append(f'/WF/PROT access expected ${B.LOCKED_ACCESS:02X}, '
                        f'got ${got_access:02X}' if got_access is not None
                        else 'got missing entry')
    for path in ABSENT_AFTER:
        if path in state.entries:
            failures.append(f'{path} exists after a failed write path')


def evaluate_poststate(state):
    failures = []
    check_status_log(state, failures)
    check_captures(state, failures)
    check_volume_poststate(state, failures)
    return failures


def encoded(text):
    return C.encode_maux_text(text.encode('ascii'))


# -- Under the probed buffering policy (docs/PERF-PLAN.md step 4,
# -- 2026-08-28) the DIAGNOSTIC lands first: stdout to the capture
# -- file is fully buffered, so the payload reaches the file only at
# -- the exit flush, while the FCLOSE-detected error's stderr line is
# -- line-mode and lands at emission. This is also what a host tee
# -- with a redirected stdout shows. The pre-policy order (payload
# -- first, stdout line-buffered) is now a MUTATION below.
TEE_FIXED = 'tee: cannot open /mnt/MAUX/WF/PROT\ntee payload\n'


def good_state():
    files = {
        '/E2E/ST': encoded('1\n1\n1\n1\n1\n1\n1\n'),
        '/E2E/CPNF': encoded('cp: error\n'),
        '/E2E/MVNF': encoded(
            'mv: cannot move /mnt/MAUX/WF/MVDIR/MVSRC errno=$48\n'),
        '/E2E/MKNF': encoded(
            'mkdir: cannot create /mnt/MAUX/WF/NEWDIR\n'),
        '/E2E/TEEP': encoded(TEE_FIXED),
        '/E2E/EDP': encoded('?\n'),
        '/WF/CPSRC': B.CPSRC_BYTES,
        '/WF/MVDIR/MVSRC': B.MVSRC_BYTES,
        '/WF/TEESRC': B.TEESRC_BYTES,
        '/WF/PROT': B.PROT_BYTES,
        '/WF/EDSCRIPT': B.EDSCRIPT_BYTES,
    }
    return PostState(files, set(files), {'/WF/PROT': B.LOCKED_ACCESS}, 0)


def run_selftest():
    base = good_state()
    failures = evaluate_poststate(base)
    if failures:
        for failure in failures:
            print(f'[check-writefail-host] baseline FAIL: {failure}',
                  file=sys.stderr)
        return 1

    mutations = []

    s = copy.deepcopy(base)
    s.files['/E2E/ST'] = encoded('0\n1\n1\n1\n1\n1\n1\n')
    mutations.append(('status comparator rejects false cp success', s))

    s = copy.deepcopy(base)
    s.files['/E2E/ST'] = b'1\n1\n1\n1\n1\n1\n1\n'
    mutations.append(('text decoder rejects low-bit status log', s))

    # -- The three RETIRED pins, now as regression mutants: each of
    # -- these IS the poststate the pinned defect produced, and each
    # -- must now be rejected.  A pin that is deleted without leaving a
    # -- mutant behind takes its own teeth with it.
    s = copy.deepcopy(base)
    s.files['/E2E/ST'] = encoded('1\n1\n1\n0\n1\n1\n1\n')
    mutations.append(('tee exiting 0 on a failed write is the old bug', s))

    s = copy.deepcopy(base)
    s.files['/E2E/ST'] = encoded('1\n1\n1\n1\n1\n0\n1\n')
    mutations.append(('redir leaving $? at 0 is the old bug', s))

    s = copy.deepcopy(base)
    s.files['/E2E/ST'] = encoded('1\n1\n1\n1\n1\n1\n0\n')
    mutations.append(('a child whose WRITE failed must not exit 0 -- '
                      'stdio error path', s))

    s = copy.deepcopy(base)
    s.files['/E2E/EDP'] = encoded('')
    mutations.append(('ed printing nothing for a failed w is the old bug', s))

    s = copy.deepcopy(base)
    s.files['/E2E/TEEP'] = encoded('tee payload\n')
    mutations.append(('tee capture without the diagnostic is the old bug', s))

    # -- ed's failed `w` under a SCRIPT stdin must report nonzero, like
    # -- real ed and like ex -s. A 0 there is the pre-EX2 bug.
    # -- (ed is the 5th status: cp mv mkdir tee ED redir append.)
    s = copy.deepcopy(base)
    s.files['/E2E/ST'] = encoded('1\n1\n1\n1\n0\n1\n1\n')
    mutations.append(('ed exiting 0 on a failed w (script stdin) is the '
                      'pre-EX2 bug', s))

    # -- ORDER, not just content: the diagnostic lands before the
    # -- payload because the capture-file stdout is FULLY buffered
    # -- (probed policy, docs/PERF-PLAN.md step 4) and only the exit
    # -- flush delivers the payload, while the FCLOSE-detected error's
    # -- stderr line is immediate. The OLD order -- payload first,
    # -- from the line-buffered era -- is the mutation now.
    s = copy.deepcopy(base)
    s.files['/E2E/TEEP'] = encoded(
        'tee payload\ntee: cannot open /mnt/MAUX/WF/PROT\n')
    mutations.append(('tee payload must follow the diagnostic, not '
                      'precede it (probed-buffering order)', s))

    s = copy.deepcopy(base)
    s.files['/E2E/TEEP'] = encoded('garbage\n')
    mutations.append(('tee capture rejects unrelated output', s))

    s = copy.deepcopy(base)
    s.files['/E2E/EDP'] = encoded('garbage\n')
    mutations.append(('ed capture rejects unrelated output', s))

    s = copy.deepcopy(base)
    s.files['/WF/PROT'] = B.PROT_BYTES + B.image_text('oops\n')
    mutations.append(('protected target content must not change', s))

    s = copy.deepcopy(base)
    s.access['/WF/PROT'] = 0xE3
    mutations.append(('protected target access byte must not change', s))

    s = copy.deepcopy(base)
    s.files['/WF/CPNEW'] = B.CPSRC_BYTES[:8]
    s.entries.add('/WF/CPNEW')
    mutations.append(('failed cp must not leave a destination', s))

    s = copy.deepcopy(base)
    del s.files['/WF/MVDIR/MVSRC']
    s.entries.discard('/WF/MVDIR/MVSRC')
    mutations.append(('failed mv must keep its source', s))

    s = copy.deepcopy(base)
    s.entries.add('/WF/NEWDIR')
    mutations.append(('failed mkdir must not leave the directory', s))

    s = copy.deepcopy(base)
    s.free_blocks = 2
    mutations.append(('volume must remain full after the run', s))

    rejected = 0
    for label, state in mutations:
        failures = evaluate_poststate(state)
        if not failures:
            print(f'[check-writefail-host] FAIL: mutation passed: {label}',
                  file=sys.stderr)
            return 1
        rejected += 1
        print(f'[check-writefail-host] rejected: {label} -> '
              f'{failures[0]}')

    print(f'[check-writefail-host] PASS: baseline accepted and '
          f'{rejected} wrong poststates rejected')
    return 0


def check_boot_state(state):
    failures = []
    if state['done'] != 0xAA:
        failures.append(
            f"the harness process did not finish (done=${state['done']:02X}, "
            f"err=${state['err']:02X}, step={state['step']})")
    if state['err'] != 0:
        failures.append(f"R_ERR expected $00, got ${state['err']:02X}")
    if state['sh_pid'] == 0:
        failures.append('SPAWN(SH) returned pid 0')
    if state['sh_wait'] != state['sh_pid']:
        failures.append(
            f"wait pid {state['sh_wait']} != spawn pid {state['sh_pid']}")
    return failures


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--selftest':
        return run_selftest()

    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}',
              file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make writefail-image first',
              file=sys.stderr)
        return 2

    boot = run_emulator(disk)
    print(f"[check-writefail] done=${boot['done']:02X} "
          f"err=${boot['err']:02X} step=${boot['step']:02X} "
          f"sh_pid={boot['sh_pid']} sh_wait={boot['sh_wait']} "
          f"sh_status=${boot['sh_status']:02X} "
          f"({boot['steps']} x {STEP_CYCLES} cycles, "
          f"{boot['seconds']:.1f}s)")
    failures = check_boot_state(boot)
    if not failures:
        failures.extend(evaluate_poststate(read_poststate(disk)))
    if failures:
        for failure in failures:
            print(f'[check-writefail] FAIL: {failure}', file=sys.stderr)
        return 1

    for key in sorted(KNOWN_DEFECTS):
        title, reason = KNOWN_DEFECTS[key]
        print(f'[check-writefail] KNOWN DEFECT {key}: {title}')
        print(f'[check-writefail]   {reason}')
    print('[check-writefail] PASS: full-volume cp/mv/mkdir failures left '
          'sources intact and no destinations behind; locked-target tee, '
          'ed and shell redirection all REPORTED the failure -- tee names '
          'the file and exits 1, ed answers ?, redirection reaches $? -- '
          'and /WF/PROT is byte- and access-identical')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
