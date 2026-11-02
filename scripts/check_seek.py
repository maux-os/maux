#!/usr/bin/env python3
"""Boot and verify the seek-family gate (`make check-seek`).

Companion to src/test/seektest.s / src/test/seektestb.s /
src/test/seekwr.s / scripts/build_seek_image.py. docs/FLEET.md "`>>`
and the seek family":

  Phase A: SEEKWR (a real liba-linked program) exercises
  LSEEK(fd,3,SEEK_SET), LSEEK(fd,2,SEEK_CUR), LSEEK(fd,0,SEEK_END) on
  a freshly-written 10-byte file and independently re-verifies each
  landing with a raw GET_MARK call (NOT LSEEK's own return value --
  see seekwr.s's header for why that distinction has teeth). Expects
  marks (3,0,0), (5,0,0), (10,0,0) and zero error flags.

  Phase B: sh, spawned with fd 0 redirected from a staged script,
  runs `ECHO A > /mnt/MAUX/APPF` then `ECHO B >> /mnt/MAUX/APPF`. APPF must
  hold BOTH lines afterward, in order -- proving `>>` does not
  truncate what `>` already wrote.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
from build_seek_image import (  # noqa: E402
    EXPECT_APPF, EXPECT_SET_MARK, EXPECT_CUR_MARK, EXPECT_END_MARK,
    EXPECT_ERRFLAGS,
)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'seek.po')

R_SEEKWR_PID    = 0x1300
R_SEEKWR_WPID   = 0x1301
R_SEEKWR_STATUS = 0x1302
R_SEEKRES_FD    = 0x1303
R_SEEKRES_TRANS = 0x1304
R_SEEKRES_DATA  = 0x1306
R_PHASEA_DONE   = 0x1310

R_SH_PID        = 0x1320
R_SCRIPT_FD     = 0x1321
R_SH_WPID       = 0x1322
R_SH_STATUS     = 0x1323
R_APPF_FD       = 0x1324
R_APPF_TRANS    = 0x1325
R_APPF_DATA     = 0x1327
R_PHASEB_DONE   = 0x1330

R_DONE = 0x1390
R_ERR  = 0x1391
R_STEP = 0x1392


def peek_aux1(client, addr, count=1):
    return client.call_tool('peek', {
        'addr': addr,
        'count': count,
        'bank': 'aux',
        'aux_bank': 1,
    })['bytes']


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}', file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make seek-image first',
              file=sys.stderr)
        return 2

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-seek] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-seek] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        # Two spawns (SEEKWR, then sh which itself spawns ECHO twice) --
        # generous budget, same order of magnitude as check-sh's own.
        done = 0
        for _ in range(1200):
            client.call_tool('step', {'cycles': 200_000})
            done = peek_aux1(client, R_DONE)[0]
            if done in (0xAA, 0xEE):
                break

        err = peek_aux1(client, R_ERR)[0]
        step = peek_aux1(client, R_STEP)[0]
        phase_a = peek_aux1(client, R_PHASEA_DONE)[0]
        phase_b = peek_aux1(client, R_PHASEB_DONE)[0]

        seekwr_pid = peek_aux1(client, R_SEEKWR_PID)[0]
        seekwr_wpid = peek_aux1(client, R_SEEKWR_WPID)[0]
        seekwr_status = peek_aux1(client, R_SEEKWR_STATUS)[0]
        t = peek_aux1(client, R_SEEKRES_TRANS, 2)
        seekres_trans = t[0] | (t[1] << 8)
        seekres = bytes(peek_aux1(client, R_SEEKRES_DATA, 10))

        sh_pid = peek_aux1(client, R_SH_PID)[0]
        sh_wpid = peek_aux1(client, R_SH_WPID)[0]
        sh_status = peek_aux1(client, R_SH_STATUS)[0]
        t2 = peek_aux1(client, R_APPF_TRANS, 2)
        appf_trans = t2[0] | (t2[1] << 8)
        appf = bytes(peek_aux1(client, R_APPF_DATA, len(EXPECT_APPF)))

        set_mark = tuple(seekres[0:3])
        cur_mark = tuple(seekres[3:6])
        end_mark = tuple(seekres[6:9])
        errflags = seekres[9]

        print(f'[check-seek] done=${done:02X} err=${err:02X} step={step} '
              f'phaseA=${phase_a:02X} phaseB=${phase_b:02X}')
        print(f'[check-seek] phase A: seekwr_pid={seekwr_pid} '
              f'wait_pid={seekwr_wpid} status=${seekwr_status:02X} '
              f'trans={seekres_trans} set_mark={set_mark} '
              f'cur_mark={cur_mark} end_mark={end_mark} '
              f'errflags=${errflags:02X}')
        print(f'[check-seek] phase B: sh_pid={sh_pid} wait_pid={sh_wpid} '
              f'status=${sh_status:02X} trans={appf_trans} appf={appf!r}')

        failures = []
        if done != 0xAA:
            failures.append(f'test did not finish successfully '
                            f'(done=${done:02X}, err=${err:02X}, step={step})')

        if phase_a != 0xAA:
            failures.append(f'phase A (SEEKWR) did not complete '
                            f'(phaseA=${phase_a:02X})')
        else:
            if seekwr_pid == 0:
                failures.append('gate A: SPAWN(SEEKWR) returned pid 0')
            if seekwr_wpid != seekwr_pid:
                failures.append(f'gate A: wait pid {seekwr_wpid} != '
                                f'spawn pid {seekwr_pid}')
            if seekwr_status != 0:
                failures.append(f'gate A: seekwr exit status expected $00, '
                                f'got ${seekwr_status:02X}')
            if seekres_trans != 10:
                failures.append(f'gate A: SEEKRES trans_count expected 10, '
                                f'got {seekres_trans}')
            if errflags != EXPECT_ERRFLAGS:
                failures.append(f'gate A: seekwr reported LSEEK failure(s), '
                                f'errflags=${errflags:02X}')
            if set_mark != EXPECT_SET_MARK:
                failures.append(f'gate A: SEEK_SET landed at {set_mark}, '
                                f'expected {EXPECT_SET_MARK} (verified via '
                                f'independent GET_MARK)')
            if cur_mark != EXPECT_CUR_MARK:
                failures.append(f'gate A: SEEK_CUR landed at {cur_mark}, '
                                f'expected {EXPECT_CUR_MARK} (verified via '
                                f'independent GET_MARK)')
            if end_mark != EXPECT_END_MARK:
                failures.append(f'gate A: SEEK_END landed at {end_mark}, '
                                f'expected {EXPECT_END_MARK} (verified via '
                                f'independent GET_MARK)')

        if phase_a == 0xAA and phase_b != 0xAA:
            failures.append(f'phase B (sh `>>`) did not complete '
                            f'(phaseB=${phase_b:02X})')
        elif phase_a == 0xAA:
            if sh_pid == 0:
                failures.append('gate B: SPAWN(SH) returned pid 0')
            if sh_wpid != sh_pid:
                failures.append(f'gate B: wait pid {sh_wpid} != spawn pid '
                                f'{sh_pid}')
            if sh_status != 0:
                failures.append(f'gate B: sh exit status expected $00, got '
                                f'${sh_status:02X}')
            if appf_trans != len(EXPECT_APPF):
                failures.append(f'gate B: APPF trans_count expected '
                                f'{len(EXPECT_APPF)}, got {appf_trans}')
            if appf != EXPECT_APPF:
                failures.append(f'gate B: APPF bytes expected '
                                f'{EXPECT_APPF!r}, got {appf!r} -- `>>` lost '
                                f'or reordered what `>` already wrote')

        if failures:
            for failure in failures:
                print(f'[check-seek] FAIL: {failure}', file=sys.stderr)
            return 1

        print('[check-seek] PASS: LSEEK(SEEK_SET/SEEK_CUR/SEEK_END) landed '
              'exactly where expected (independently GET_MARK-verified), '
              'and `echo a > F` followed by `echo b >> F` left F holding '
              'both lines, in order')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
