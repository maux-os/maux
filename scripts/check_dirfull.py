#!/usr/bin/env python3
"""Boot and verify the FULL-VOLUME-DIRECTORY images, both kernels.

docs/E2E-COVERAGE.md section 4 item 7.  The fixture is one image built
twice -- identical bytes but for the ProDOS in `/PRODOS` -- staged with
its volume directory FULL by the classic rule (51 entries, 4 blocks) and
1,435 free blocks still on the volume.  Each variant is asserted against
its own documented outcome:

  2.4  the wall is real: mkdir, cp and shell redirection into the root
       each fail, name the path, and exit 1; the chain stays 4 blocks.
       This is the create failure item 7 asked for and no other fixture
       in the tree can produce.
  2.5  no wall: the same three creates succeed silently, the root grows
       to 54 entries, and the volume directory's block chain gains a
       fifth block.

Both matter.  2.4 is the kernel every other gate runs (the Makefile
exports it as PRODOS_KERNEL_BIN), so that is maux's live behaviour; 2.5
is vendored beside it, so the tree must not bake in a limit its own
alternative kernel does not have.

THE CROSS-CHECK IS THE POINT OF THE SELFTEST: each variant's poststate
is run against the OTHER variant's expectation and must be rejected.
Two expectation tables that both accept the same bytes would mean the
gate is not really testing a difference.
"""
import copy
import os
import sys
import time
from dataclasses import dataclass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
import e2e_compare as C  # noqa: E402
import build_dirfull_image as B  # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


R_DONE = 0x1290
R_ERR = 0x1291
R_STEP = 0x1292
R_SH_PID = 0x1201
R_SH_WAIT = 0x1202
R_SH_STATUS = 0x1203

STEP_CYCLES = 5_000_000
MAX_STEPS = 2000

STATUS_LABELS = ['mkdir-root', 'mkdir-sub', 'cp-root', 'cp-sub', 'redir-root']

#: 51 staged + the three a kernel without the wall adds.
GROWN_ENTRIES = B.VOLDIR_ENTRIES + len(B.GROWN_AFTER)


class Expect:
    """One kernel's documented outcome for this fixture."""

    def __init__(self, version, grows, statuses, diags, entries, blocks):
        self.version = version
        self.grows = grows          # do the root creates succeed?
        self.statuses = statuses    # per STATUS_LABELS
        self.diags = diags          # capture name -> exact bytes
        self.entries = entries      # root entry count afterwards
        self.blocks = blocks        # volume-directory chain length


WALL = Expect(
    '2.4', grows=False,
    statuses=[1, 0, 1, 0, 1],
    diags={'/E2E/MKNF': b'mkdir: cannot create /mnt/MAUX/DFNEW\n',
           '/E2E/CPNF': b'cp: error\n',
           '/E2E/MKOK': b'', '/E2E/CPOK': b''},
    entries=B.VOLDIR_ENTRIES, blocks=B.VOLDIR_BLOCKS)

GROW = Expect(
    '2.5', grows=True,
    statuses=[0, 0, 0, 0, 0],
    diags={'/E2E/MKNF': b'', '/E2E/CPNF': b'',
           '/E2E/MKOK': b'', '/E2E/CPOK': b''},
    entries=GROWN_ENTRIES, blocks=B.VOLDIR_BLOCKS + 1)

EXPECTS = {'2.4': WALL, '2.5': GROW}

FILES_TO_READ = ['/E2E/ST', '/E2E/MKNF', '/E2E/MKOK', '/E2E/CPNF',
                 '/E2E/CPOK', '/DF/CPSRC', '/DF/CPCOPY', '/DFCOPY']
ENTRIES_TO_CHECK = list(dict.fromkeys(
    FILES_TO_READ + B.GROWN_AFTER + B.PRESENT_AFTER))


@dataclass
class PostState:
    files: dict
    entries: set
    free_blocks: int
    root_entries: int
    voldir_blocks: int


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
        print(f'[check-dirfull] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-dirfull] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')
        t0 = time.time()
        done = 0
        for i in range(MAX_STEPS):
            client.call_tool('step', {'cycles': STEP_CYCLES})
            done = peek_aux1(client, R_DONE)[0]
            if done in (0xAA, 0xEE):
                break
        return {
            'done': done,
            'err': peek_aux1(client, R_ERR)[0],
            'step': peek_aux1(client, R_STEP)[0],
            'sh_pid': peek_aux1(client, R_SH_PID)[0],
            'sh_wait': peek_aux1(client, R_SH_WAIT)[0],
            'sh_status': peek_aux1(client, R_SH_STATUS)[0],
            'steps': i + 1,
            'seconds': time.time() - t0,
        }
    finally:
        client.close()


def read_poststate(disk):
    vol = prodos.Volume(disk, readonly=True)
    try:
        files, entries = {}, set()
        for path in ENTRIES_TO_CHECK:
            try:
                ent = vol.entry_for(path)
            except FileNotFoundError:
                continue
            entries.add(path)
            if not ent.is_dir():
                files[path] = vol.read_file(path)
        return PostState(files, entries, vol.free_blocks,
                         sum(1 for _ in vol.scandir('/')),
                         len(B.voldir_chain(disk)))
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


def check_status_log(state, expect, failures):
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
    for label, status, want in zip(STATUS_LABELS, got, expect.statuses):
        if status != want:
            failures.append(f'{label} status expected {want} on ProDOS '
                            f'{expect.version}, got {status}')


def check_captures(state, expect, failures):
    # The subdirectory captures are empty in BOTH variants: those cases
    # succeed either way, and a diagnostic there means the control broke
    # and nothing else in the image means anything.
    for path, want in expect.diags.items():
        text = decoded_file(state, path, failures)
        if text != want:
            failures.append(f'{path} expected {want!r} on ProDOS '
                            f'{expect.version}, got {text!r}')


def check_volume_poststate(state, expect, failures):
    if state.root_entries != expect.entries:
        failures.append(f'root holds {state.root_entries} entries, expected '
                        f'{expect.entries} on ProDOS {expect.version}')
    if state.voldir_blocks != expect.blocks:
        failures.append(f'the volume-directory chain is {state.voldir_blocks} '
                        f'blocks, expected {expect.blocks} on ProDOS '
                        f'{expect.version} -- entries have to come from '
                        f'somewhere, and the chain is where')
    if state.free_blocks <= 0:
        failures.append(f'volume has {state.free_blocks} free blocks -- with '
                        f'none left, a failed create would be the VOLUME '
                        f'being full and this fixture would be blind')
    for path in B.GROWN_AFTER:
        here = path in state.entries
        if expect.grows and not here:
            failures.append(f'{path} is missing -- the root did NOT grow on '
                            f'ProDOS {expect.version}')
        if not expect.grows and here:
            failures.append(f'{path} exists -- the root grew on ProDOS '
                            f'{expect.version}, where the TRM wall ("$49 '
                            f'volume directory full ... no more than 51 '
                            f'entries") is supposed to hold')
    for path in B.PRESENT_AFTER:
        if path not in state.entries:
            failures.append(f'{path} is missing -- the subdirectory CONTROL '
                            f'failed, so the root cases prove nothing')
    if state.files.get('/DF/CPSRC') != B.CPSRC_BYTES:
        failures.append('/DF/CPSRC changed under a copy that only read it')
    if state.files.get('/DF/CPCOPY') != B.CPSRC_BYTES:
        failures.append('/DF/CPCOPY does not match its source byte for byte')
    if expect.grows and state.files.get('/DFCOPY') != B.CPSRC_BYTES:
        failures.append('/DFCOPY does not match its source byte for byte -- '
                        'a copy PAST the classic wall must still be exact')


def evaluate_poststate(state, expect):
    failures = []
    check_status_log(state, expect, failures)
    check_captures(state, expect, failures)
    check_volume_poststate(state, expect, failures)
    return failures


def encoded(text):
    return C.encode_maux_text(text.encode('ascii'))


def good_state(expect):
    """The poststate a correct run leaves, for one kernel."""
    files = {
        '/E2E/ST': encoded('\n'.join(str(n) for n in expect.statuses) + '\n'),
        '/DF/CPSRC': B.CPSRC_BYTES,
        '/DF/CPCOPY': B.CPSRC_BYTES,
    }
    for path, want in expect.diags.items():
        files[path] = encoded(want.decode('ascii'))
    entries = set(files) | set(B.PRESENT_AFTER)
    if expect.grows:
        files['/DFCOPY'] = B.CPSRC_BYTES
        entries |= set(B.GROWN_AFTER)
    return PostState(files, entries, 1429 if expect.grows else 1433,
                     expect.entries, expect.blocks)


def run_selftest():
    problems = []
    rejected = 0
    for version, expect in sorted(EXPECTS.items()):
        base = good_state(expect)
        failures = evaluate_poststate(base, expect)
        if failures:
            for failure in failures:
                print(f'[check-dirfull-host] {version} baseline FAIL: '
                      f'{failure}', file=sys.stderr)
            return 1

        mutations = []

        # -- THE CROSS-CHECK. This variant's own poststate, judged by the
        # -- OTHER kernel's expectation, must be rejected. If it is not,
        # -- the two tables do not describe a difference and the pair is
        # -- decoration.
        other = GROW if expect is WALL else WALL
        mutations.append((f'the ProDOS {version} poststate must NOT satisfy '
                          f'the ProDOS {other.version} expectation',
                          base, other))

        for i, label in enumerate(STATUS_LABELS):
            s = copy.deepcopy(base)
            st = list(expect.statuses)
            st[i] = 1 - st[i]
            s.files['/E2E/ST'] = encoded('\n'.join(str(n) for n in st) + '\n')
            mutations.append((f'{label} taking the other verdict must not '
                              f'pass', s, expect))

        s = copy.deepcopy(base)
        s.files['/E2E/ST'] = b'\n'.join(
            str(n).encode() for n in expect.statuses) + b'\n'
        mutations.append(('text decoder rejects a low-bit status log',
                          s, expect))

        for path in expect.diags:
            s = copy.deepcopy(base)
            s.files[path] = encoded('mkdir: cannot create /mnt/MAUX/OTHER\n')
            mutations.append((f'the wrong diagnostic in {path} must not pass',
                              s, expect))

        # -- Spelled from the builder's own lists, never by hand: the
        # -- first run of this selftest passed a mutation because the
        # -- checker and the builder disagreed about whether a path
        # -- carries the volume name, and a lookup that finds nothing
        # -- checks nothing.
        for name in B.PRESENT_AFTER:
            s = copy.deepcopy(base)
            s.entries.discard(name)
            mutations.append((f'{name} missing (the CONTROL) must not pass',
                              s, expect))

        for name in B.GROWN_AFTER:
            s = copy.deepcopy(base)
            if expect.grows:
                s.entries.discard(name)
            else:
                s.entries.add(name)
            mutations.append((f'{name} on the wrong side of the wall must '
                              f'not pass', s, expect))

        s = copy.deepcopy(base)
        s.voldir_blocks = expect.blocks + 1
        mutations.append(('a chain of the wrong length must not pass',
                          s, expect))

        s = copy.deepcopy(base)
        s.root_entries = expect.entries + 1
        mutations.append(('the wrong root entry count must not pass',
                          s, expect))

        s = copy.deepcopy(base)
        s.files['/DF/CPSRC'] = B.CPSRC_BYTES + b'\xa0'
        mutations.append(('the copy source must be untouched', s, expect))

        s = copy.deepcopy(base)
        s.free_blocks = 0
        mutations.append(('a FULL VOLUME would make this fixture blind',
                          s, expect))

        for label, state, judge in mutations:
            if not evaluate_poststate(state, judge):
                problems.append(f'{version}: mutation passed: {label}')
                continue
            rejected += 1
            print(f'[check-dirfull-host] {version} rejected: {label}')

    for problem in problems:
        print(f'[check-dirfull-host] FAIL: {problem}', file=sys.stderr)
    if problems:
        return 1
    print(f'[check-dirfull-host] PASS: both kernels\' baselines accepted and '
          f'{rejected} wrong poststates rejected, including each variant '
          f'judged by the other kernel\'s expectation')
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

    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}',
              file=sys.stderr)
        return 2

    failures = []
    lines = []
    for version, disk in sorted(B.VARIANTS.items()):
        expect = EXPECTS[version]
        if not os.path.exists(disk):
            print(f'error: {disk} not found -- run make dirfull-image first',
                  file=sys.stderr)
            return 2
        boot = run_emulator(disk)
        print(f"[check-dirfull] {version}: done=${boot['done']:02X} "
              f"err=${boot['err']:02X} step=${boot['step']:02X} "
              f"sh_pid={boot['sh_pid']} sh_wait={boot['sh_wait']} "
              f"sh_status=${boot['sh_status']:02X} "
              f"({boot['steps']} x {STEP_CYCLES} cycles, "
              f"{boot['seconds']:.1f}s)")
        these = check_boot_state(boot)
        if not these:
            state = read_poststate(disk)
            these = evaluate_poststate(state, expect)
            verb = ('grew to' if expect.grows else 'held at')
            lines.append(
                f'[check-dirfull] {version}: root {verb} '
                f'{state.root_entries} entries over {state.voldir_blocks} '
                f'volume-directory blocks, {state.free_blocks} blocks free')
        failures.extend(f'{version}: {f}' for f in these)

    if failures:
        for failure in failures:
            print(f'[check-dirfull] FAIL: {failure}', file=sys.stderr)
        return 1
    for line in lines:
        print(line)
    print('[check-dirfull] PASS: one fixture, two kernels, opposite answers '
          '-- ProDOS 2.4 refuses the 52nd root name with 1,433 blocks free '
          '(the TRM wall, and the create failure docs/E2E-COVERAGE.md item 7 '
          'asked for), ProDOS 2.5 takes three more and links a fifth block '
          'into the volume directory. Both are gated so neither can drift '
          'unnoticed.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
