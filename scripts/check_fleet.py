#!/usr/bin/env python3
"""Boot and verify the fleet (`cmp sort uniq tr od file`) acceptance gate
(`make check-fleet`).

Companion to src/test/fleettest.s / fleettestb.s / scripts/build_fleet_image.py.

Phase 1: `sh` (stdin redirected from a staged script) runs the nineteen-line
fleet script -- sort/uniq/tr/od/file, redirection and `>>` append -- then
`EXIT`. The result files it writes are read back and compared BYTE-EXACT
against scripts/build_fleet_image.py's own EXPECT_* constants (the task
brief's CONTRACT), the same "read the ProDOS files back off the disk image
in Python" mechanism scripts/check_sh.py already uses for EDITED/CATOUT --
far simpler than peeking a dozen result buffers out of aux memory.

Phase 2: `cmp` is spawned DIRECTLY (twice, fd 2 captured) -- `sh` has no
`if` and cannot redirect fd 2, but cmp's entire purpose is its exit status
and its stderr message, so this is checked the way scripts/check_ld.py
checks `ld`'s missing-module diagnostic.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
from build_fleet_image import (  # noqa: E402
    EXPECT_SORTOUT, EXPECT_SORTROUT, EXPECT_SORTUOUT, EXPECT_SLEEPOUT,
    EXPECT_UNIQOUT, EXPECT_UNIQCOUT, EXPECT_UNIQDOUT, EXPECT_UNIQUOUT,
    EXPECT_TROUT, EXPECT_TRDOUT, EXPECT_ODOUT, EXPECT_FILEOUT, EXPECT_COMBO,
    EXPECT_UNIQFOUT, EXPECT_BIGOUT, EXPECT_WIDEOUT, EXPECT_LONGOUT,
    EXPECT_TWINOUT, EXPECT_TWINUOUT,
    EXPECT_CMP1_STATUS, EXPECT_CMP1_STDERR,
    EXPECT_CMP2_STATUS, EXPECT_CMP2_STDERR,
)

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'fleet.po')
VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')

R_SCRIPT_FD   = 0x1300
R_SH_PID      = 0x1301
R_SH_WAIT     = 0x1302
R_SH_STATUS   = 0x1303
R_CMP1_FD     = 0x1304
R_CMP1_PID    = 0x1305
R_CMP1_WAIT   = 0x1306
R_CMP1_STATUS = 0x1307
R_CMP1_TRANS  = 0x1308
R_CMP1_DATA   = 0x130A
R_CMP2_FD     = 0x1320
R_CMP2_PID    = 0x1321
R_CMP2_WAIT   = 0x1322
R_CMP2_STATUS = 0x1323
R_CMP2_TRANS  = 0x1324
R_CMP2_DATA   = 0x1326
R_DONE        = 0x1390
R_ERR         = 0x1391
R_STEP        = 0x1392

OUT_FILES = {
    'SORTOUT': EXPECT_SORTOUT,
    'SLEEPOUT': EXPECT_SLEEPOUT,
    'SORTROUT': EXPECT_SORTROUT,
    'SORTUOUT': EXPECT_SORTUOUT,
    'UNIQOUT': EXPECT_UNIQOUT,
    'UNIQCOUT': EXPECT_UNIQCOUT,
    'UNIQDOUT': EXPECT_UNIQDOUT,
    'UNIQUOUT': EXPECT_UNIQUOUT,
    'TROUT': EXPECT_TROUT,
    'TRDOUT': EXPECT_TRDOUT,
    'ODOUT': EXPECT_ODOUT,
    'FILEOUT': EXPECT_FILEOUT,
    'COMBO': EXPECT_COMBO,
    # uniq's OWN named output -- the only case that runs FCLOSE.
    'UNIQFOUT': EXPECT_UNIQFOUT,
    # The heap cases -- inputs the pre-brk fixed partition could not
    # hold at all. See build_fleet_image.py's BIGIN/WIDEIN comment.
    'BIGOUT': EXPECT_BIGOUT,
    'WIDEOUT': EXPECT_WIDEOUT,
    # The WIDTH case -- nine lines of 1..900 characters, straddling the
    # 255/256 boundary where liba's STRLEN used to return zero and PUTS
    # wrote nothing at all. See build_fleet_image.py's LONGIN comment
    # for why every other string case in this tree is short.
    'LONGOUT': EXPECT_LONGOUT,
    # The COMPARE case -- operands identical through byte 255 and
    # differing only after it, the complement of LONGIN's differ-at-
    # byte-0 construction. TWINOUT catches the mis-ordering; TWINUOUT
    # catches the silent DELETION, which is the worse half: `sort -u`
    # skips PUTS entirely on a STRCMP of 0. See build_fleet_image.py's
    # TWININ comment for the three groups and why the control matters.
    'TWINOUT': EXPECT_TWINOUT,
    'TWINUOUT': EXPECT_TWINUOUT,
}


def peek_aux1(client, addr, count=1):
    return client.call_tool('peek', {
        'addr': addr,
        'count': count,
        'bank': 'aux',
        'aux_bank': 1,
    })['bytes']


def read_prodos_files(disk):
    prodos.mount(disk)
    try:
        return {name: prodos.read(f'/mnt/{VOL}/{name}') for name in OUT_FILES}
    finally:
        prodos.unmount(VOL)


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}', file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make fleet-image first',
              file=sys.stderr)
        return 2

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-fleet] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-fleet] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        done = 0
        # 13 spawns through `sh` plus two direct `cmp` spawns -- generous
        # budget, same shape as check_sh.py's own (a handful of spawns and
        # small file I/O, nothing heavy like `ld`'s REL linking).
        for i in range(3000):
            client.call_tool('step', {'cycles': 200_000})
            done = peek_aux1(client, R_DONE)[0]
            if done in (0xAA, 0xEE):
                break
        err = peek_aux1(client, R_ERR)[0]
        step = peek_aux1(client, R_STEP)[0]
        sh_pid = peek_aux1(client, R_SH_PID)[0]
        sh_wait = peek_aux1(client, R_SH_WAIT)[0]
        sh_status = peek_aux1(client, R_SH_STATUS)[0]
        cmp1_pid = peek_aux1(client, R_CMP1_PID)[0]
        cmp1_wait = peek_aux1(client, R_CMP1_WAIT)[0]
        cmp1_status = peek_aux1(client, R_CMP1_STATUS)[0]
        t1 = peek_aux1(client, R_CMP1_TRANS, 2)
        cmp1_trans = t1[0] | (t1[1] << 8)
        cmp1_data = bytes(peek_aux1(client, R_CMP1_DATA, min(cmp1_trans, 16)))
        cmp2_pid = peek_aux1(client, R_CMP2_PID)[0]
        cmp2_wait = peek_aux1(client, R_CMP2_WAIT)[0]
        cmp2_status = peek_aux1(client, R_CMP2_STATUS)[0]
        t2 = peek_aux1(client, R_CMP2_TRANS, 2)
        cmp2_trans = t2[0] | (t2[1] << 8)
        cmp2_data = bytes(peek_aux1(client, R_CMP2_DATA, min(cmp2_trans, 64)))

        print(f'[check-fleet] done=${done:02X} err=${err:02X} step=${step:02X} '
              f'sh_pid={sh_pid} sh_wait={sh_wait} sh_status=${sh_status:02X}')
        print(f'[check-fleet] cmp1(identical) pid={cmp1_pid} wait={cmp1_wait} '
              f'status=${cmp1_status:02X} trans={cmp1_trans} data={cmp1_data!r}')
        print(f'[check-fleet] cmp2(differ) pid={cmp2_pid} wait={cmp2_wait} '
              f'status=${cmp2_status:02X} trans={cmp2_trans} data={cmp2_data!r}')

        failures = []
        if done != 0xAA:
            failures.append(f'test did not finish successfully '
                            f'(done=${done:02X}, err=${err:02X}, step={step})')
        if err != 0:
            failures.append(f'R_ERR expected $00, got ${err:02X} at step {step}')
        if sh_pid == 0:
            failures.append('SPAWN(SH) returned pid 0')
        if sh_wait != sh_pid:
            failures.append(f'wait pid {sh_wait} != spawn pid {sh_pid}')
        if sh_status != 0:
            failures.append(f'sh exit status expected $00, got ${sh_status:02X}')

        if cmp1_pid == 0:
            failures.append('direct SPAWN(CMP) (identical run) returned pid 0')
        if cmp1_status != EXPECT_CMP1_STATUS:
            failures.append(f'cmp (identical) exit status expected '
                            f'{EXPECT_CMP1_STATUS}, got {cmp1_status}')
        if cmp1_trans != len(EXPECT_CMP1_STDERR):
            failures.append(f'cmp (identical) stderr trans_count expected '
                            f'{len(EXPECT_CMP1_STDERR)}, got {cmp1_trans}')
        if cmp1_data != EXPECT_CMP1_STDERR:
            failures.append(f'cmp (identical) stderr expected '
                            f'{EXPECT_CMP1_STDERR!r}, got {cmp1_data!r}')

        if cmp2_pid == 0:
            failures.append('direct SPAWN(CMP) (differ run) returned pid 0')
        if cmp2_status != EXPECT_CMP2_STATUS:
            failures.append(f'cmp (differ) exit status expected '
                            f'{EXPECT_CMP2_STATUS}, got {cmp2_status}')
        if cmp2_trans != len(EXPECT_CMP2_STDERR):
            failures.append(f'cmp (differ) stderr trans_count expected '
                            f'{len(EXPECT_CMP2_STDERR)}, got {cmp2_trans}')
        if cmp2_data != EXPECT_CMP2_STDERR:
            failures.append(f'cmp (differ) stderr expected '
                            f'{EXPECT_CMP2_STDERR!r}, got {cmp2_data!r}')

        if failures:
            for failure in failures:
                print(f'[check-fleet] FAIL: {failure}', file=sys.stderr)
            return 1

        files = read_prodos_files(disk)
        for name, expected in OUT_FILES.items():
            got = files[name]
            if got != expected:
                # Report the FIRST DIFFERING OFFSET, not just the first
                # 64 bytes: LONGOUT's early lines are short and match,
                # so a leading-bytes-only message would print two
                # identical-looking prefixes and leave the reader to
                # guess (2026-08-22).
                off = next((i for i in range(min(len(got), len(expected)))
                            if got[i] != expected[i]),
                           min(len(got), len(expected)))
                print(f'[check-fleet] FAIL: {name} expected '
                      f'{len(expected)}B, got {len(got)}B; first differs '
                      f'at offset {off}: expected '
                      f'{expected[off:off + 32]!r}, got '
                      f'{got[off:off + 32]!r}', file=sys.stderr)
                return 1

        print('[check-fleet] PASS: sh ran the nineteen-line fleet script '
              '(sort/uniq/tr/od/file, redirection and `>>` append) with '
              'every output byte-exact; cmp (spawned directly, fd 2 '
              'captured) exited 0 silently on identical files and exited 1 '
              'with the correct "differ: char N, line L" diagnostic on '
              'differing ones; and sort handled BOTH heap cases -- 4100 '
              'lines (the old fixed 4000-slot pointer table could not) '
              'and 36395 bytes (the old fixed 35600-byte arena could '
              'not)')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
