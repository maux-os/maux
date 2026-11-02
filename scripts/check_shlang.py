#!/usr/bin/env python3
"""Boot and verify the `sh` LANGUAGE (Tier 0 + `test`/`[`) acceptance gate
(`make check-shlang`).

Companion to src/test/shlangtest.s / scripts/build_shlang_image.py.
docs/SH-SUBSET.md sec 3's Tier 0: `$?`, `;`, `&&`, `||`. sec 6: `test`
as a shell BUILTIN (not a binary -- there is no TEST.bin on this image)
and `[` as an alias handled entirely in the shell, both ends.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
from build_shlang_image import (  # noqa: E402
    EXPECT_RESULTS, EXPECT_RESULTS2, EXPECT_RESULTS3, OUT_IMG2, OUT_IMG3,
)

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

LISTING = os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), 'build', 'MAUXSHLANG.SYSTEM_Output.txt')


def kernel_symbols(*names):
    """Kernel symbol addresses from the image's OWN merlin32 symbol
    dump (`NAME = $ADDR` lines) -- never pinned by hand; see
    check_find.py for the precedent and check_ex.py for the twin."""
    import re
    wanted = set(names)
    found = {}
    for line in open(LISTING, errors='replace'):
        m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\$([0-9A-Fa-f]+)\s*$',
                     line)
        if m and m.group(1) in wanted:
            found[m.group(1)] = int(m.group(2), 16)
    missing = wanted - set(found)
    if missing:
        raise RuntimeError(f'{sorted(missing)} absent from {LISTING}')
    return found

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'shlang.po')
VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')

R_SCRIPT_FD = 0x1200
R_SH_PID    = 0x1201
R_SH_WAIT   = 0x1202
R_SH_STATUS = 0x1203
R_DONE      = 0x1290
R_ERR       = 0x1291
R_STEP      = 0x1292


def peek_aux1(client, addr, count=1):
    return client.call_tool('peek', {
        'addr': addr,
        'count': count,
        'bank': 'aux',
        'aux_bank': 1,
    })['bytes']


def read_results(disk):
    prodos.mount(disk)
    try:
        return prodos.read(f'/mnt/{VOL}/RESULTS')
    finally:
        prodos.unmount(VOL)


def read_file(disk, name):
    """One named file off a mounted image, as raw bytes."""
    prodos.mount(disk)
    try:
        return prodos.read(f'/mnt/{VOL}/{name}')
    finally:
        prodos.unmount(VOL)


def read_sherr(disk):
    """Tier 3 `set -x` (docs/SH-FEATURES.md sec 4): sh's OWN fd 2 is
    sent to /mnt/MAUX/SHERR by an ordinary `2>` on the nested spawn the
    FIRST image's own SCRIPT makes -- NOT by the harness, whatever this
    docstring used to say (SPAWN_SH wires exactly one fdaction, fd 0
    from the script; corrected 2026-09-16 after a gate looked for SHERR
    on an image whose script never created one),
    since the trace lands there and nowhere a per-command `2>` could
    ever catch it. Checked by SUBSTRING below, not byte-exact --
    every OTHER loud sh diagnostic this script provokes lands here
    too, in an order this file does not re-derive."""
    prodos.mount(disk)
    try:
        return prodos.read(f'/mnt/{VOL}/SHERR')
    finally:
        prodos.unmount(VOL)


def hitext(s):
    return bytes(ord(c) | 0x80 for c in s)


def volume_report(disk):
    """After a red run: the spare blocks of each image, read from the
    files the emulator wrote through to (the client is closed by now).
    A row that creates a file can fail for want of blocks on these
    140 KB volumes -- `cannot redirect`, a short write -- and the
    symptom looks exactly like a code defect (KFIX3-NOTES 2.5 item 4).
    The three images are named by the sibling paths build_shlang_image.py
    writes."""
    here = os.path.dirname(os.path.abspath(disk))
    print('[check-shlang] volume free blocks after the failed run '
          '(a create that fails on a FULL volume is not a code defect):',
          file=sys.stderr)
    for name in ('shlang.po', 'shlang-hd.po', 'shlang-b.po'):
        path = os.path.join(here, name)
        if not os.path.exists(path):
            continue
        try:
            free, total = volume_free(path)
        except Exception as e:           # never mask the real failure
            print(f'    {name}: unreadable ({e})', file=sys.stderr)
            continue
        note = '   <-- FULL: suspect blocks before code' if free < 3 else ''
        print(f'    {name}: {free} of {total} free{note}', file=sys.stderr)


# Spare blocks that must remain on each image AFTER a green run (the
# builder's FREE_MARGIN is the staging-side floor). Measured on 71175a2:
# 11, 13, 25. Erosion below these means the next new row that creates a
# file can fail for want of blocks, so it fails the gate now, loudly.
END_MARGIN = {'shlang.po': 8, 'shlang-hd.po': 10, 'shlang-b.po': 20}


def volume_free(path):
    vol = prodos.Volume(path)
    try:
        return vol.free_blocks, vol.total_blocks
    finally:
        vol.close()


def end_margin_check(disk):
    here = os.path.dirname(os.path.abspath(disk))
    low = []
    for name, want in END_MARGIN.items():
        path = os.path.join(here, name)
        if not os.path.exists(path):
            continue
        free, total = volume_free(path)
        print(f'[check-shlang] {name}: {free} of {total} blocks free after '
              f'the run (margin {want})')
        if free < want:
            low.append(f'{name}: {free} free, margin {want}')
    if low:
        print('[check-shlang] FAIL: the rows now leave too little room on '
              'a 140 KB image -- the next row that creates a file will '
              'fail for want of blocks, not code: ' + '; '.join(low),
              file=sys.stderr)
        return 1
    return 0


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    rc = run(disk)
    if rc == 0:
        rc = end_margin_check(disk)
    if rc == 1:
        volume_report(disk)
    return rc


def run(disk):
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}',
              file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make shlang-image first',
              file=sys.stderr)
        return 2

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-shlang] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-shlang] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        done = 0
        # Tier 0 alone spawned FORTY-ONE children (echo x24, cat x7,
        # cmp x10) and read its script one byte at a time; `test`/`[`
        # ran SEVEN more times on top of that and spawned NOTHING
        # (docs/SH-SUBSET.md sec 6.3: builtin, not a binary). Tier 1
        # (docs/SH-FEATURES.md sec 4 -- if/while/until/break/continue)
        # adds another ~50 spawns (39 echo + 11 cmp) plus a couple
        # dozen more builtin `test`/`break`/`continue` calls that
        # spawn nothing either, PLUS every WHILE/UNTIL line now pays
        # for an extra GET_MARK/SET_MARK round trip (CAP_LINE_MARK)
        # on every single line read, looped construct or not.
        # Same generous per-child headroom as before, scaled up
        # again -- Tier 1 adds real loop iterations (each its own
        # CMP+TEST+ECHO spawns, several nested two deep) on top of
        # Tier 0's 41. Cycles/call raised alongside the iteration
        # count (200_000 -> 2_000_000): the MCP round trip itself
        # dominates wall time at the old granularity far more than
        # emulated cycles do. Measured completion: 35 steps (70M
        # cycles) -- 400 steps (800M cycles) is ~11x that, generous
        # without being the multi-billion-cycle budget an early,
        # much-slower-than-necessary draft of this gate used.
        # Tier 3 (docs/SH-FEATURES.md sec 4/6) adds a real `ed`
        # spawn (a bigger binary than echo/cat/cmp) plus two extra
        # `.`-sourced fd opens/closes and a here-doc pipe write/read
        # per case -- 400 -> 500 steps (1B cycles) for headroom, kept
        # generous rather than trimmed to the measured minimum.
        for i in range(500):
            client.call_tool('step', {'cycles': 2_000_000})
            done = peek_aux1(client, R_DONE)[0]
            if done in (0xAA, 0xEE):
                break
        err = peek_aux1(client, R_ERR)[0]
        step = peek_aux1(client, R_STEP)[0]
        sh_pid = peek_aux1(client, R_SH_PID)[0]
        sh_wait = peek_aux1(client, R_SH_WAIT)[0]
        sh_status = peek_aux1(client, R_SH_STATUS)[0]

        print(f'[check-shlang] done=${done:02X} err=${err:02X} '
              f'step=${step:02X} sh_pid={sh_pid} sh_wait={sh_wait} '
              f'sh_status=${sh_status:02X}')

        failures = []
        if done != 0xAA:
            failures.append(f'test did not finish successfully '
                            f'(done=${done:02X}, err=${err:02X}, '
                            f'step={step})')
        if err != 0:
            failures.append(f'R_ERR expected $00, got ${err:02X}')
        if sh_pid == 0:
            failures.append('SPAWN(SH) returned pid 0')
        if sh_wait != sh_pid:
            failures.append(f'wait pid {sh_wait} != spawn pid {sh_pid}')
        if sh_status != 0:
            failures.append(f'sh exit status expected $00, got '
                            f'${sh_status:02X}')

        if failures:
            for failure in failures:
                print(f'[check-shlang] FAIL: {failure}', file=sys.stderr)
            return 1

        results = read_results(disk)
        print(f'[check-shlang] RESULTS = {results!r}')
        if results != EXPECT_RESULTS:
            print(f'[check-shlang] FAIL: RESULTS expected '
                  f'{EXPECT_RESULTS!r}, got {results!r}', file=sys.stderr)
            return 1

        # Tier 3 `set -x` (docs/SH-FEATURES.md sec 4): the trace goes
        # to sh's OWN fd 2, captured whole-run into /mnt/MAUX/SHERR
        # (shlangtestb.s). Checked by SUBSTRING, not byte-exact --
        # SHERR also carries every OTHER loud sh diagnostic this
        # script provokes (break/continue outside a loop, one shift
        # too many, the unterminated here-doc, ...), in an order this
        # file does not re-derive.
        sherr = read_sherr(disk)
        print(f'[check-shlang] SHERR = {sherr!r}')
        sherr_failures = []
        traced_on = hitext('+ ECHO TRACEME')
        traced_off = hitext('+ ECHO NOTRACE')
        traced_setoff = hitext('+ SET -X')
        traced_seton = hitext('+ SET +X')
        untermed = hitext('sh: here-doc: EOF before terminator')
        if traced_on not in sherr:
            sherr_failures.append(
                f'expected {traced_on!r} in SHERR (set -x should trace '
                f'ECHO TRACEME) -- not found')
        if traced_off in sherr:
            sherr_failures.append(
                f'found {traced_off!r} in SHERR -- set +x should have '
                f'stopped tracing before ECHO NOTRACE ran')
        if traced_setoff in sherr:
            sherr_failures.append(
                f'found {traced_setoff!r} in SHERR -- SET -X itself must '
                f'NOT be traced (tracing was still off when that line '
                f'was dispatched)')
        if traced_seton not in sherr:
            sherr_failures.append(
                f'expected {traced_seton!r} in SHERR -- SET +X itself '
                f'SHOULD be traced (tracing was still on when that line '
                f'was dispatched)')
        if untermed not in sherr:
            sherr_failures.append(
                f'expected {untermed!r} in SHERR (the unterminated '
                f'here-doc inside /mnt/MAUX/HDBAD) -- not found')
        if sherr_failures:
            for failure in sherr_failures:
                print(f'[check-shlang] FAIL: {failure}', file=sys.stderr)
            return 1

        # -------------------------------------------------------------
        # SECOND image (`build/shlang-hd.po`) -- this task's own gate
        # cases (a)/(b)/`<<-'WORD'`/(d), a SEPARATE boot for a real,
        # pre-existing, OUT-OF-SCOPE resource reason -- see
        # build_shlang_image.py's own banner comment on OUT_IMG2 for
        # why these do not live in the first image's own SCRIPT_TEXT.
        # Same harness, same peek addresses (identical compiled
        # MAUXSHLANG.SYSTEM/shlangtestb.s) -- but a genuinely SEPARATE
        # MCPClient/emulator process, not a second `reset` on the SAME
        # one: found the hard way, calling `reset` again on an
        # already-run emulator instance and mounting a different disk
        # does NOT fully clear everything a truly fresh boot would --
        # the second image hung reliably reused-in-process, and passed
        # reliably as its own fresh process, repeatably.
        # -------------------------------------------------------------
        if not os.path.exists(OUT_IMG2):
            print(f'error: {OUT_IMG2} not found -- run make shlang-image '
                  f'first', file=sys.stderr)
            return 2
        client.close()
        client = MCPClient([SUPERVISOR], env)
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-shlang-hd] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(OUT_IMG2)})
        print(f'[check-shlang-hd] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        done2 = 0
        for i in range(500):
            client.call_tool('step', {'cycles': 2_000_000})
            done2 = peek_aux1(client, R_DONE)[0]
            if done2 in (0xAA, 0xEE):
                break
        err2 = peek_aux1(client, R_ERR)[0]
        step2 = peek_aux1(client, R_STEP)[0]
        sh_pid2 = peek_aux1(client, R_SH_PID)[0]
        sh_wait2 = peek_aux1(client, R_SH_WAIT)[0]
        sh_status2 = peek_aux1(client, R_SH_STATUS)[0]
        print(f'[check-shlang-hd] done=${done2:02X} err=${err2:02X} '
              f'step=${step2:02X} sh_pid={sh_pid2} sh_wait={sh_wait2} '
              f'sh_status=${sh_status2:02X}')

        hd_failures = []
        if done2 != 0xAA:
            hd_failures.append(f'test did not finish successfully '
                               f'(done=${done2:02X}, err=${err2:02X}, '
                               f'step={step2})')
        if err2 != 0:
            hd_failures.append(f'R_ERR expected $00, got ${err2:02X}')
        if sh_pid2 == 0:
            hd_failures.append('SPAWN(SH) returned pid 0')
        if sh_wait2 != sh_pid2:
            hd_failures.append(f'wait pid {sh_wait2} != spawn pid {sh_pid2}')
        if sh_status2 != 0:
            hd_failures.append(f'sh exit status expected $00, got '
                               f'${sh_status2:02X}')
        if hd_failures:
            for failure in hd_failures:
                print(f'[check-shlang-hd] FAIL: {failure}', file=sys.stderr)
            return 1

        results2 = read_results(OUT_IMG2)
        print(f'[check-shlang-hd] RESULTS = {results2!r}')
        if results2 != EXPECT_RESULTS2:
            print(f'[check-shlang-hd] FAIL: RESULTS expected '
                  f'{EXPECT_RESULTS2!r}, got {results2!r}', file=sys.stderr)
            return 1
        # io_buffer LENDING teeth (docs/IOBUF-LENDING.md): the DEEP1-4
        # case above only proves lending if lending actually HAPPENED.
        # The kernel counts parks (K_PARK_CNT) and keeps the pool's
        # high-water (K_IBF_HIWAT); read both by SYMBOL from the
        # image's own listing. A run that never parked means the case
        # no longer reaches the ceiling and has lost its teeth.
        syms = kernel_symbols('K_PARK_CNT', 'K_IBF_HIWAT')
        parks = client.call_tool('peek', {
            'addr': syms['K_PARK_CNT'], 'count': 1, 'bank': 'main',
        })['bytes'][0]
        hiwat = client.call_tool('peek', {
            'addr': syms['K_IBF_HIWAT'], 'count': 1, 'bank': 'main',
        })['bytes'][0]
        print(f'[check-shlang-hd] io_buffer lending: {parks} file(s) '
              f'parked, pool high-water {hiwat}')
        if parks == 0:
            print('[check-shlang-hd] FAIL: the DEEP1-4 case ran but the '
                  'kernel never parked a file -- the case no longer '
                  'exceeds the io_buffer pool and proves nothing',
                  file=sys.stderr)
            return 1
        print('[check-shlang-hd] PASS: `<<WORD` expanded $1/$?/$VAR, '
              "`<<'WORD'` left the SAME body text completely literal, "
              "`<<-'WORD'` composed quoting with tab-stripping, and the "
              'etymology demo (docs/DEMOS.md sec 1) -- `ed` scripted by '
              'an expanding here-doc whose pattern is $1 -- matched real '
              '`grep` byte-for-byte on the same pattern/file -- and '
              'command substitution `$(cmd)` (docs/ANACHRONISMS.md A10) '
              'spliced INTO a word, carried arguments through the token '
              'split, kept interior newlines while stripping THREE '
              'trailing ones, worked as `VAR=$(cmd)` and inside `"..."`, '
              "stayed literal inside `'...'` and inside a `<<'WORD'` "
              'body while expanding inside a `<<WORD` one, captured a '
              'no-match command as EMPTY, refused a nested and an '
              'unclosed `$(` loudly (nonzero $?, line abandoned), and '
              'TWO expanding words on one line no longer overwrite each '
              "other's terminator -- and `2>&1` fd duplication, with "
              'BOTH orderings asserted to DIFFER: `> D1 2>&1` puts the '
              'diagnostic AND the data in D1, while `2>&1 > D2` leaves '
              'the diagnostic out of D2 and sends it to the OLD fd 1 '
              '(a pipe, read back through DUPOUT) -- and the `read` '
              'builtin (docs/SH-FEATURES.md sec 16) read fd 0 while '
              'the shell read its script from a `.`-sourced file, '
              'proving the two fds are distinct; split a line into '
              'three variables with the LAST one absorbing a '
              'remainder containing spaces; honoured TAB as a '
              'separator while stripping leading and trailing '
              'whitespace and keeping interior runs; left surplus '
              'variables empty; treated an EMPTY line as data '
              '(status 0) rather than EOF; read a command-shaped '
              'line without executing it; refused `read VAR < FILE` '
              'loudly without consuming a line; drove a '
              '`WHILE READ` loop for two iterations off fd 0; and '
              'returned NONZERO at EOF with the variable untouched '
              '-- and COMPOUND REDIRECTION (docs/SH-FEATURES.md '
              "sec 18): `FI > FILE` captured a construct's output "
              '(the case sec 17 had locked as CR2, "silently '
              'discarded", is CR0 now), `WHILE READ ... DONE < '
              'FILE` read a real three-line file IN ORDER while '
              'the shell went on reading its script from fd 0 -- '
              'the idiom sec 16.7 had to list as unusable -- a '
              'FALSE condition still created its target, `DONE >> '
              'FILE` on a `for` loop APPENDED to a file that '
              'already had a line in it, a nested pair proved '
              'INNERMOST WINS (the inner `FI > CINNER` kept its '
              'body out of the outer `DONE > COUTER`), `FI 2> '
              'FILE` carried a non-default TARGET fd, a PIPELINE '
              "body sent its LAST stage to the construct's file, "
              'a construct opened as a LATER segment of its line '
              'is still refused (the documented scan limit, '
              'locked so it cannot widen by accident), and a bare '
              '`< FILE` with no construct at all is still refused '
              '-- RESULTS byte-exact')

        # -------------------------------------------------------------
        # THIRD image (`build/shlang-b.po`) -- the six POSIX builtins of
        # 2026-09-16 (docs/SH-FEATURES.md sec 29). Its own boot, for the
        # reason the SECOND image's banner already gives and this one
        # inherits: both existing scripts run at the io_buffer ceiling
        # on purpose, and five more nested shells appended to either
        # would be testing the ceiling rather than the builtins. Same
        # separate-process rule as the second image -- a second `reset`
        # on a used emulator instance does not fully clear it.
        # -------------------------------------------------------------
        if not os.path.exists(OUT_IMG3):
            print(f'error: {OUT_IMG3} not found -- run make shlang-image '
                  f'first', file=sys.stderr)
            return 2
        client.close()
        client = MCPClient([SUPERVISOR], env)
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-shlang-b] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(OUT_IMG3)})
        print(f'[check-shlang-b] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        done3 = 0
        for i in range(500):
            client.call_tool('step', {'cycles': 2_000_000})
            done3 = peek_aux1(client, R_DONE)[0]
            if done3 in (0xAA, 0xEE):
                break
        err3 = peek_aux1(client, R_ERR)[0]
        step3 = peek_aux1(client, R_STEP)[0]
        sh_pid3 = peek_aux1(client, R_SH_PID)[0]
        sh_wait3 = peek_aux1(client, R_SH_WAIT)[0]
        sh_status3 = peek_aux1(client, R_SH_STATUS)[0]
        print(f'[check-shlang-b] done=${done3:02X} err=${err3:02X} '
              f'step=${step3:02X} sh_pid={sh_pid3} sh_wait={sh_wait3} '
              f'sh_status=${sh_status3:02X}')

        b_failures = []
        if done3 != 0xAA:
            b_failures.append(f'test did not finish successfully '
                              f'(done=${done3:02X}, err=${err3:02X}, '
                              f'step={step3})')
        if err3 != 0:
            b_failures.append(f'R_ERR expected $00, got ${err3:02X}')
        if sh_pid3 == 0:
            b_failures.append('SPAWN(SH) returned pid 0')
        if sh_wait3 != sh_pid3:
            b_failures.append(f'wait pid {sh_wait3} != spawn pid {sh_pid3}')
        if b_failures:
            for failure in b_failures:
                print(f'[check-shlang-b] FAIL: {failure}', file=sys.stderr)
            return 1

        results3 = read_results(OUT_IMG3)
        print(f'[check-shlang-b] RESULTS = {results3!r}')
        if results3 != EXPECT_RESULTS3:
            print(f'[check-shlang-b] FAIL: RESULTS expected '
                  f'{EXPECT_RESULTS3!r}, got {results3!r}', file=sys.stderr)
            return 1

        # `type ... > FILE` is REFUSED (SB_NOREDIR, shsgblt.s), and a
        # refusal that quietly created the file anyway would be the
        # quiet-wrong-answer class this shell exists to close. The
        # status assertion (TY3:1) is above; this is the side-effect
        # half, and it is the half a "return 1 and print nothing"
        # implementation would still pass without.
        prodos.mount(OUT_IMG3)
        try:
            nul_there = any(e.name.upper() == 'NUL'
                            for e in prodos.scandir(f'/mnt/{VOL}'))
        finally:
            prodos.unmount(VOL)
        if nul_there:
            print('[check-shlang-b] FAIL: /mnt/MAUX/NUL exists -- `TYPE ECHO '
                  '> /mnt/MAUX/NUL` was supposed to be refused BEFORE the '
                  'redirect was ever opened', file=sys.stderr)
            return 1

        # `times` (docs/SH-FEATURES.md sec 29). Its first field is the
        # shell's ELAPSED time, so there is no byte-exact expectation to
        # write -- the SHAPE is the contract: two lines, four
        # "<min>m<sec>.<hundredths>s" fields, and the children's line
        # structurally zero because maux has no child CPU accounting at
        # all. Asserting the shape rather than a literal is the honest
        # form of this gate, not a weakened one: a `times` that printed
        # nothing, printed one line, or dropped the fractional field
        # fails every clause below.
        timesout = read_file(OUT_IMG3, 'TIMESOUT')
        print(f'[check-shlang-b] TIMESOUT = {timesout!r}')
        plain = timesout.decode('latin-1')
        plain = ''.join(chr(ord(c) & 0x7F) for c in plain)
        tlines = [ln for ln in plain.split('\r') if ln != '']
        field = r'\d+m\d+\.\d\ds'
        # WHICH `times` PATH SHOULD HAVE RUN IS A PROPERTY OF THE
        # HARNESS, so read it rather than assume it. src/test/
        # shlangtest.s does NOT `put` src/kernel/timer.s and never
        # calls TIMER_PROBE, so K_TIMER_MODE stays 0 ("unprobed") and
        # `times` must print its structural-zero path -- measured
        # 2026-09-16 by temporarily changing the zero string and
        # watching it appear. Asserting the mode makes that a gated
        # fact instead of a comment, and makes this row say something
        # STRONGER the day the harness grows a timer: the elapsed field
        # would then have to be nonzero.
        tmode = client.call_tool('peek', {
            'addr': kernel_symbols('K_TIMER_MODE')['K_TIMER_MODE'],
            'count': 1, 'bank': 'main',
        })['bytes'][0]
        live = tmode in (1, 2)
        print(f'[check-shlang-b] K_TIMER_MODE={tmode} '
              f'({"live" if live else "no usable tick source"})')
        tms_failures = []
        if len(tlines) != 2:
            tms_failures.append(f'expected 2 lines from `times`, got '
                                f'{len(tlines)}: {tlines!r}')
        else:
            if not re.fullmatch(f'{field} {field}', tlines[0]):
                tms_failures.append(f'line 1 {tlines[0]!r} is not two '
                                    f'"MmSS.HHs" fields')
            elif live and tlines[0].split()[0] == '0m0.00s':
                tms_failures.append(
                    f'line 1 {tlines[0]!r}: K_TIMER_MODE is {tmode}, so '
                    f'the tick counter IS advancing and the shell had '
                    f'three spawns of elapsed time behind it -- a zero '
                    f'elapsed field means SB_T0CAP or the subtraction '
                    f'is not working')
            elif not live and tlines[0] != '0m0.00s 0m0.00s':
                tms_failures.append(
                    f'line 1 {tlines[0]!r}: K_TIMER_MODE is {tmode} '
                    f'(no usable tick source), so `times` must print '
                    f'its structural-zero path exactly')
            if tlines[1] != '0m0.00s 0m0.00s':
                tms_failures.append(f'line 2 {tlines[1]!r} -- the '
                                    f"children's pair is structurally "
                                    f'zero on maux and must read '
                                    f'"0m0.00s 0m0.00s" exactly')
        if tms_failures:
            for failure in tms_failures:
                print(f'[check-shlang-b] FAIL: {failure}', file=sys.stderr)
            return 1

        # The diagnostics the byte-exact RESULTS cannot see. They come
        # from ERRSCR, a SECOND run of the same three refusals under
        # `2> BLTERR` -- see build_shlang_image.py's own banner for why
        # one spawn cannot capture both streams here, and for the stale
        # comment (now corrected) that claimed the harness wires fd 2
        # itself. Substring, like the first image's SHERR.
        sherr3 = read_file(OUT_IMG3, 'BLTERR')
        print(f'[check-shlang-b] SHERR = {sherr3!r}')
        s3_failures = []
        for want, why in [
            (hitext('NOSUCHCMD: not found'),
             '`type NOSUCHCMD` must name the operand it could not find'),
            (hitext('sh: read-only variable'),
             'assigning to / unsetting a `readonly` must be LOUD, not a '
             'silent no-op'),
            (hitext('sh: builtin: redirection not supported'),
             '`type ... > FILE` must refuse in words, not just in $?'),
        ]:
            if want not in sherr3:
                s3_failures.append(f'expected {want!r} in SHERR -- {why}')
        if s3_failures:
            for failure in s3_failures:
                print(f'[check-shlang-b] FAIL: {failure}', file=sys.stderr)
            return 1

        # alias/unalias/hash/fc diagnostics (ALIERRS, `2> ALIERRF`):
        # substring-exact, the same contract as BLTERR above.
        alierr = read_file(OUT_IMG3, 'ALIERRF')
        print(f'[check-shlang-b] ALIERRF = {alierr!r}')
        al_failures = []
        for want, why in [
            ('sh: alias: reserved word',
             '`alias if=x` must be refused in words'),
            ('alias: nosuch: not found', '`alias NAME` miss'),
            ('unalias: nosuch: not found', '`unalias NAME` miss'),
            ('sh: unalias: usage', 'bare `unalias`'),
            ('hash: nosuchcmd: not found', '`hash NAME` miss'),
            ("sh: fc: not supported (history is the console's)",
             '`fc` must say why it is not built'),
            ('sh: alias: bad name', 'a name with a `/`'),
            ('sh: alias: value too long', 'a 32-character value'),
            ('sh: alias: table full', 'the ninth alias, never a silent '
             'drop'),
            ('sh: alias: expansion too long', 'LINEMAX overflow is an '
             'error, not a truncation'),
        ]:
            if hitext(want) not in alierr:
                al_failures.append(f'expected {want!r} in ALIERRF -- {why}')
        # SH-ROOM: `alias ""` and `unalias ""` are each "not found" --
        # once apiece, and no listing of an unwritten value on stdout.
        n_empty = alierr.count(hitext('alias: : not found'))
        if n_empty != 2:
            al_failures.append(
                f'expected 2 x \'alias: : not found\' in ALIERRF (the '
                f'empty name of `alias ""` and of `unalias ""`), got '
                f'{n_empty}')
        if al_failures:
            for failure in al_failures:
                print(f'[check-shlang-b] FAIL: {failure}', file=sys.stderr)
            return 1

        # KFIX2 5: NSPERRS's stderr (NSPERRF) and its side effects. Five
        # refusals, none of which may have run anything: three
        # `cannot redirect` (8>F, 10>F, 8<F -- 2<F was the third until
        # KFIX3 item 2 made it a real redirect, E2L:0) and two `too many
        # arguments` (a full operator pool, a line past MAXTOK), and the
        # files `8>F`/`10>F` used to create must not exist.
        nsperr = read_file(OUT_IMG3, 'NSPERRF')
        print(f'[check-shlang-b] NSPERRF = {nsperr!r}')
        ns_failures = []
        for want, n in (('sh: cannot redirect', 3),
                        ('sh: too many arguments', 4)):
            got = nsperr.count(hitext(want))
            if got != n:
                ns_failures.append(f'NSPERRF holds {got} x {want!r}, '
                                   f'want {n}')
        # A FULL process table: every refused spawn says why. FULLERF is
        # the stderr of twenty `SLEEP 5 &`. It printed `sh: command not
        # found` for each refusal until 2026-10-31 -- a missing command
        # is not what a full machine means. Both directions are asserted:
        # a refusal exists, and so do started sleeps (no refusal-always).
        fullerr = read_file(OUT_IMG3, 'BIN/FULLERF')
        print(f'[check-shlang-b] FULLERF = {fullerr!r}')
        n_full = fullerr.count(b'sh: no more processes')
        n_cnf = (fullerr.count(hitext('command not found'))
                 + fullerr.count(b'command not found'))
        if n_full < 1 or n_full > 15 or n_cnf != 0:
            ns_failures.append(
                f'FULLERF holds {n_full} x \'sh: no more processes\' '
                f'and {n_cnf} x \'command not found\': a full process '
                f'table must report the former for 1..15 of the twenty '
                f'spawns and never the latter')
        # KFIX3 item 3: SIGERR holds the V7 names of the foreground
        # deaths, in order, and nothing for ^C (2) and the pipe (13).
        sigerr = read_file(OUT_IMG3, 'SIGERR')
        print(f'[check-shlang-b] SIGERR = {sigerr!r}')
        want_sig = hitext('Killed\rTerminated\rTrace/BPT trap\rHangup\r')
        if sigerr != want_sig:
            ns_failures.append(f'SIGERR is {sigerr!r}, want the four V7 '
                               f'names {want_sig!r} (nothing for 2/13)')
        prodos.mount(OUT_IMG3)
        try:
            made = [e.name.upper() for e in prodos.scandir(f'/mnt/{VOL}')
                    if e.name.upper() in ('NSG1', 'NSG2')]
        finally:
            prodos.unmount(VOL)
        if made:
            ns_failures.append(f'{made} exist: `ECHO 8>F` / `ECHO 10>F` '
                               f'were run as plain redirects of fd 1')
        if ns_failures:
            for failure in ns_failures:
                print(f'[check-shlang-b] FAIL: {failure}', file=sys.stderr)
            return 1

        print('[check-shlang-b] PASS: `type` named a BUILTIN, a PATH-'
              'resolved binary, a reserved WORD and a missing name (each '
              'in its own wording, status 1 for the miss, diagnostic on '
              'stderr), probed a `/`-bearing name instead of PATH-'
              'searching it, and REFUSED a redirect without creating the '
              'target; `command -V` matched `type` and `command -v` gave '
              'the terse form (a builtin as its own word, a command as '
              'its path, silence + status 1 on a miss), while plain '
              '`command NAME` reached the ECHO BUILTIN through the '
              'shifted argv; `eval` expanded its operands TWICE (the '
              "quoted '$X' proving the second pass) and abandoned the "
              'rest of its own line as documented; `exec > FILE` moved '
              "the SHELL's own fd 1 for TWO later commands, `exec 2>&1` "
              "carried a CHILD's stderr onto it, and `exec CMD` ran the "
              'command and left the shell with NOTREACHED never running; '
              '`readonly` refused both an assignment and an `unset` '
              'loudly while keeping the original value, took NAME=VALUE '
              'in one operand, and listed what it holds in a re-readable '
              'form; `times` printed two well-formed lines with the '
              "children's pair structurally zero -- RESULTS byte-exact, "
              'TIMESOUT shape-exact, SHERR substring-exact')

        print('[check-shlang] PASS: `;` sequenced two commands in order '
              '(bare and piped), `&&` ran ECHO SAME1 on success and '
              'skipped ECHO SAME2 on failure, `||` ran ECHO DIFF1 on '
              'failure, a three-term `&&`/`||` chain proved left '
              'associativity (CHAINA skipped, CHAINB ran), `$?` '
              'expanded to the last exit status both standalone and '
              'embedded mid-word, `test -f`/`[ -f ]`/`[ -d ]` set '
              '$? for true and false branches alike (and agree with '
              'each other), `[` missing its `]` reported status 2 '
              'without ever reaching TEST_EVAL, and `ECHO TEST`/`ECHO [` '
              'proved the command-position rule (argv[1] is not '
              'argv[0]) -- Tier 1 (docs/SH-FEATURES.md sec 4): '
              '`if`/`elif`/`else`/`fi` both branches and a chain, '
              'one line with `;` and spanning lines, `while`/`until` '
              'each terminated after growing a file to match a fixed '
              'target -- the repeated body output IS the proof the '
              'loop actually re-executes by SEEKING, not just runs '
              'once -- a loop containing an `if` and an `if` '
              'containing a `while` (true branch loops, false '
              'branch never even evaluates the nested condition), '
              '`break`/`continue` with and without an explicit '
              'count (including crossing TWO nesting levels), '
              '`break`/`continue` outside a loop diagnosing without '
              'unwinding, and `ECHO IF`/`ECHO "WHILE"` proving the '
              'new reserved words stay command-position-only -- '
              'RESULTS byte-exact -- Tier 3 (docs/SH-FEATURES.md sec '
              '4/6): `:` always succeeds and ignores its args, `.` '
              'sourced a file that reassigned FOO in the CURRENT '
              'shell (visible afterward -- a spawned child could '
              'never do that), a plain `<<WORD` here-doc fed `cat`, '
              '`<<-WORD` stripped leading tabs from the body AND the '
              'terminator line, a here-doc scripted an `ed` edit '
              '(the motivating case, no separate .ED file), a '
              'here-doc INSIDE a `while` loop was re-captured fresh '
              'on each of two iterations (the seek trick surviving '
              'it), an unterminated here-doc inside a sourced file '
              'diagnosed and let the outer script resume rather than '
              'hanging, and `set -x`/`set +x` traced exactly the '
              'commands between them on SHERR, never before or after '
              '-- and, TYPED THE WAY A HUMAN TYPES IT: lowercase '
              '`cd` really moved the directory (proved by a '
              'relative read, not by echoing `pwd`), lowercase '
              '`test`/`if`/`then`/`fi`/`for`/`in`/`do`/`done`/'
              '`break`/`set -x`/`set +x` all dispatched, and '
              '`echo cd` still passed its argument through '
              'UNFOLDED -- while `./X`, `../X`, a bare `.` and a '
              'bare `..` resolved against the cwd from a SPAWNED '
              'program and from a builtin alike, and `cd ..`/'
              '`cd ../..` both genuinely move (one level below the '
              'volume root, not clamped at it, since docs/DEVFS.md '
              'made "/" a real pseudo-root above it) '
              '-- RESULTS and SHERR both byte-exact/substring-exact')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
