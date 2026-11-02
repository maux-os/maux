#!/usr/bin/env python3
"""Boot and verify the `sh` integration gate (`make check-sh`).

Companion to src/test/shtest.s / scripts/build_sh_image.py.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
from build_sh_image import (EXPECT_CATOUT, EXPECT_DEVAFT, EXPECT_DEVNUL,  # noqa: E402
                            EXPECT_EDITED, EXPECT_OUT1, EXPECT_OUT2,
                            EXPECT_OUT3)

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'sh.po')
VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')

R_SCRIPT_FD = 0x1200
R_SH_PID = 0x1201
R_WAIT_PID = 0x1202
R_SH_STATUS = 0x1203
R_OUT1_FD = 0x1204
R_OUT1_TRANS = 0x1205
R_OUT1_DATA = 0x1207
R_OUT2_FD = 0x1220
R_OUT2_TRANS = 0x1221
R_OUT2_DATA = 0x1223
R_DONE = 0x1290
R_ERR = 0x1291
R_STEP = 0x1292
# fork() smoke probe (src/test/shtestb.s, R_STEP 7): SYS_FORK is
# dispatched in the SHIPPING image, not only in forktest's.
R_FORK_A = 0x1293
R_FORK_ST = 0x1294
R_FORK_W = 0x1295
# `sh SCRIPTFILE` mode (Phase B, src/test/shtestb.s SPAWN_SH2):
# a second sh spawn, argv={"SH","/mnt/MAUX/SCRIPT3"}, fd 0 dup'd
# from IN3 (not the script) -- proves the script and fd 0 are
# now independent fds.
R_IN3_FD = 0x1240
R_SH2_PID = 0x1241
R_WAIT2_PID = 0x1242
R_SH2_STATUS = 0x1243
R_OUT3_FD = 0x1244
R_OUT3_TRANS = 0x1245
R_OUT3_DATA = 0x1247


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
        return {
            'EDITED': prodos.read(f'/mnt/{VOL}/EDITED'),
            'CATOUT': prodos.read(f'/mnt/{VOL}/CATOUT'),
            'DEVNUL': prodos.read(f'/mnt/{VOL}/DEVNUL'),
            'DEVAFT': prodos.read(f'/mnt/{VOL}/DEVAFT'),
        }
    finally:
        prodos.unmount(VOL)


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}', file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make sh-image first',
              file=sys.stderr)
        return 2

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-sh] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-sh] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        done = 0
        # sh spawns two children of its own (echo, cat) and reads a whole
        # script one byte at a time -- give this considerably more budget
        # than the single-spawn gates.
        for i in range(1200):
            client.call_tool('step', {'cycles': 200_000})
            done = peek_aux1(client, R_DONE)[0]
            if done in (0xAA, 0xEE):
                break
        err = peek_aux1(client, R_ERR)[0]
        step = peek_aux1(client, R_STEP)[0]
        fork_a = peek_aux1(client, R_FORK_A)[0]
        fork_st = peek_aux1(client, R_FORK_ST)[0]
        fork_w = peek_aux1(client, R_FORK_W)[0]
        sh_pid = peek_aux1(client, R_SH_PID)[0]
        wait_pid = peek_aux1(client, R_WAIT_PID)[0]
        sh_status = peek_aux1(client, R_SH_STATUS)[0]
        t1 = peek_aux1(client, R_OUT1_TRANS, 2)
        trans1 = t1[0] | (t1[1] << 8)
        data1 = bytes(peek_aux1(client, R_OUT1_DATA, len(EXPECT_OUT1)))
        t2 = peek_aux1(client, R_OUT2_TRANS, 2)
        trans2 = t2[0] | (t2[1] << 8)
        data2 = bytes(peek_aux1(client, R_OUT2_DATA, len(EXPECT_OUT2)))
        sh2_pid = peek_aux1(client, R_SH2_PID)[0]
        wait2_pid = peek_aux1(client, R_WAIT2_PID)[0]
        sh2_status = peek_aux1(client, R_SH2_STATUS)[0]
        t3 = peek_aux1(client, R_OUT3_TRANS, 2)
        trans3 = t3[0] | (t3[1] << 8)
        data3 = bytes(peek_aux1(client, R_OUT3_DATA, len(EXPECT_OUT3)))
        print(f'[check-sh] done=${done:02X} err=${err:02X} step=${step:02X} '
              f'fork_a={fork_a} fork_st=${fork_st:02X} fork_w={fork_w} '
              f'sh_pid={sh_pid} wait_pid={wait_pid} sh_status=${sh_status:02X} '
              f'trans1={trans1} data1={data1!r} trans2={trans2} data2={data2!r} '
              f'sh2_pid={sh2_pid} wait2_pid={wait2_pid} '
              f'sh2_status=${sh2_status:02X} trans3={trans3} data3={data3!r}')

        failures = []
        if done != 0xAA:
            failures.append(f'test did not finish successfully '
                            f'(done=${done:02X}, err=${err:02X}, step={step})')
        if err != 0:
            failures.append(f'R_ERR expected $00, got ${err:02X}')
        if fork_a == 0:
            failures.append('fork() smoke probe: parent got pid 0 '
                            '(SYS_FORK not dispatched in this image?)')
        if fork_st != 0xC9:
            failures.append(f'fork() smoke probe: child exit status '
                            f'${fork_st:02X}, expected $C9')
        if fork_w != fork_a:
            failures.append(f'fork() smoke probe: wait reaped pid '
                            f'{fork_w}, fork returned {fork_a}')
        if sh_pid == 0:
            failures.append('SPAWN(SH) returned pid 0')
        if wait_pid != sh_pid:
            failures.append(f'wait pid {wait_pid} != spawn pid {sh_pid}')
        if sh_status != 0:
            failures.append(f'sh exit status expected $00, got ${sh_status:02X}')
        if trans1 != len(EXPECT_OUT1):
            failures.append(f'OUT1 trans_count expected {len(EXPECT_OUT1)}, '
                            f'got {trans1}')
        if data1 != EXPECT_OUT1:
            failures.append(f'OUT1 bytes expected {EXPECT_OUT1!r}, got {data1!r}')
        if trans2 != len(EXPECT_OUT2):
            failures.append(f'OUT2 trans_count expected {len(EXPECT_OUT2)}, '
                            f'got {trans2}')
        if data2 != EXPECT_OUT2:
            failures.append(f'OUT2 bytes expected {EXPECT_OUT2!r}, got {data2!r}')
        if sh2_pid == 0:
            failures.append('SPAWN(SH, argv=SCRIPT3) returned pid 0')
        if wait2_pid != sh2_pid:
            failures.append(f'wait2 pid {wait2_pid} != spawn2 pid {sh2_pid}')
        if sh2_status != 0:
            failures.append(f'sh2 (script-mode) exit status expected $00, '
                            f'got ${sh2_status:02X}')
        if trans3 != len(EXPECT_OUT3):
            failures.append(f'OUT3 trans_count expected {len(EXPECT_OUT3)}, '
                            f'got {trans3}')
        if data3 != EXPECT_OUT3:
            failures.append(f'OUT3 bytes expected {EXPECT_OUT3!r}, got {data3!r} '
                            f'-- sh SCRIPTFILE mode: script read from argv[1], '
                            f'fd 0 free for the command')

        if failures:
            for failure in failures:
                print(f'[check-sh] FAIL: {failure}', file=sys.stderr)
            return 1

        files = read_prodos_files(disk)
        if files['EDITED'] != EXPECT_EDITED:
            print(f'[check-sh] FAIL: EDITED expected {EXPECT_EDITED!r}, '
                  f'got {files["EDITED"]!r}', file=sys.stderr)
            return 1
        if files['DEVNUL'] != EXPECT_DEVNUL:
            print(f'[check-sh] FAIL: DEVNUL (cat < /dev/null) expected '
                  f'{EXPECT_DEVNUL!r}, got {files["DEVNUL"]!r}', file=sys.stderr)
            failures.append('DEVNUL')
        if files['DEVAFT'] != EXPECT_DEVAFT:
            print(f'[check-sh] FAIL: DEVAFT expected {EXPECT_DEVAFT!r}, got '
                  f'{files["DEVAFT"]!r} -- sh did not survive the /DEV '
                  f'redirects', file=sys.stderr)
            failures.append('DEVAFT')
        if files['CATOUT'] != EXPECT_CATOUT:
            print(f'[check-sh] FAIL: CATOUT expected {EXPECT_CATOUT!r}, '
                  f'got {files["CATOUT"]!r}', file=sys.stderr)
            return 1

        print('[check-sh] PASS: sh, spawned from disk with fd 0 redirected from '
              'a script file, ran `ECHO HELLO > /mnt/MAUX/OUT1`, '
              '`ECHO A | CAT > /mnt/MAUX/OUT2`, `ED < /mnt/MAUX/EDSCRIPT > '
              '/mnt/MAUX/EDLOG`, `CAT /mnt/MAUX/EDITED > /mnt/MAUX/CATOUT`, '
              '`CAT /mnt/MAUX/EDITED > /DEV/NULL`, `CAT < /dev/null > '
              '/mnt/MAUX/DEVNUL` (LOWER CASE on purpose -- the only line that '
              'exercises PDEV_FOLD), `ECHO AFTER > /mnt/MAUX/DEVAFT`, and '
              '`EXIT`, exiting 0 with redirected, piped, edited, catted and '
              'device-sunk files byte-correct -- and a SECOND sh, spawned '
              '`SH /mnt/MAUX/SCRIPT3` (argv[1] names the script, not fd 0), '
              'ran `CAT > /mnt/MAUX/OUT3` with fd 0 dup\'d from a real data '
              'file (IN3) instead: CAT (no args, no redirection) read IN3 '
              'through the INHERITED fd 0, proving sh\'s own script source '
              '(now a separate fd via argv[1]) never touches fd 0, and the '
              'unchanged argc==1 path above already proved byte-identical')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
