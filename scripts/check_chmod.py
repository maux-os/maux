#!/usr/bin/env python3
"""Boot and verify the chmod/df acceptance gate (`make check-chmod`).

Companion to src/test/chmodtest.s / chmodtestb.s / scripts/
build_chmod_image.py.

Phase 1: `sh` (stdin redirected from a staged script) sets a prefix,
locks LOCKFILE (`chmod -dnw`), round-trips RWFILE through lock then
unlock, and runs `df` twice (bare, and with an explicit "BASIC"
argument) redirecting both to files. Every expectation -- the DF output
line, and LOCKFILE/RWFILE's post-run metadata -- is derived by
build_chmod_image.py's compute_expectations() from the STAGED image,
called here BEFORE the emulator ever runs (it snapshots the pre-run
state a post-run read is compared against), never hand-typed and never
by running the tool first.

Phase 2: `rm` is spawned DIRECTLY against the still-locked LOCKFILE
(`sh` cannot capture a child's own fd 2) -- expect a nonzero exit and
LOCKFILE still present afterward: the resists-deletion proof.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
from build_chmod_image import (  # noqa: E402
    compute_expectations, CARRIER_VOL, EXPECT_RM_STATUS, EXPECT_RM_STDERR,
)

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'chmod.po')

R_SCRIPT_FD   = 0x1300
R_SH_PID      = 0x1301
R_SH_WAIT     = 0x1302
R_SH_STATUS   = 0x1303
R_RM_FD       = 0x1304
R_RM_PID      = 0x1305
R_RM_WAIT     = 0x1306
R_RM_STATUS   = 0x1307
R_RM_TRANS    = 0x1308
R_RM_DATA     = 0x130A
R_DONE        = 0x1390
R_ERR         = 0x1391
R_STEP        = 0x1392


def peek_aux1(client, addr, count=1):
    return client.call_tool('peek', {
        'addr': addr,
        'count': count,
        'bank': 'aux',
        'aux_bank': 1,
    })['bytes']


def read_prodos_files(disk, names):
    prodos.mount(disk, replace=True)
    try:
        return {name: prodos.read(f'/mnt/{CARRIER_VOL}/{name}') for name in names}
    finally:
        prodos.unmount(CARRIER_VOL)


def read_meta(disk, names):
    prodos.mount(disk, replace=True)
    try:
        out = {}
        for name in names:
            e = prodos.stat(f'/mnt/{CARRIER_VOL}/{name}')
            out[name] = {
                'access': e.access,
                'type': e.type,
                'aux_type': e.aux_type,
                'eof': e.eof,
                'blocks_used': e.blocks_used,
                'creation': e.creation,
                'last_mod': e.last_mod,
            }
        return out
    finally:
        prodos.unmount(CARRIER_VOL)


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}', file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make chmod-image first',
              file=sys.stderr)
        return 2

    # Derive every expectation from the STAGED (pre-run) image first.
    expect = compute_expectations(disk)

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-chmod] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-chmod] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        done = 0
        # sh (six commands) plus one direct rm spawn -- generous budget,
        # same shape as check_fleet.py's own.
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
        rm_pid = peek_aux1(client, R_RM_PID)[0]
        rm_wait = peek_aux1(client, R_RM_WAIT)[0]
        rm_status = peek_aux1(client, R_RM_STATUS)[0]
        t = peek_aux1(client, R_RM_TRANS, 2)
        rm_trans = t[0] | (t[1] << 8)
        rm_data = bytes(peek_aux1(client, R_RM_DATA, min(rm_trans, 40)))

        print(f'[check-chmod] done=${done:02X} err=${err:02X} '
              f'step=${step:02X} sh_pid={sh_pid} sh_wait={sh_wait} '
              f'sh_status=${sh_status:02X}')
        print(f'[check-chmod] rm pid={rm_pid} wait={rm_wait} '
              f'status=${rm_status:02X} trans={rm_trans} data={rm_data!r}')

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

        if rm_pid == 0:
            failures.append('direct SPAWN(RM) returned pid 0')
        if rm_status != EXPECT_RM_STATUS:
            failures.append(f'rm exit status expected {EXPECT_RM_STATUS} '
                            f'(locked file resists DESTROY), got {rm_status}')
        if rm_trans != len(EXPECT_RM_STDERR):
            failures.append(f'rm stderr trans_count expected '
                            f'{len(EXPECT_RM_STDERR)}, got {rm_trans}')
        if rm_data != EXPECT_RM_STDERR:
            failures.append(f'rm stderr expected {EXPECT_RM_STDERR!r}, '
                            f'got {rm_data!r}')

        if failures:
            for failure in failures:
                print(f'[check-chmod] FAIL: {failure}', file=sys.stderr)
            return 1

        # DF's output (POSIX -P form): the header exact, then one row
        # "/VOL total used avail pct% /VOL" with total == the image's
        # own block count, used+avail == total, used bracketed by the
        # pre-run and post-run bitmap counts (the script's own
        # redirections allocate blocks before df stats the volume),
        # and the capacity the ceiling of 100*used/total. Both
        # argument forms. check-df owns the exact used/free numbers.
        files = read_prodos_files(disk, ['DFOUT', 'DFOUT2'])
        v = prodos.Volume(disk)
        try:
            used_post = expect['total_blocks'] - v.free_blocks
        finally:
            v.close()
        hdr = ('Filesystem 512-blocks Used Available Capacity '
               'Mounted on')
        for name in ('DFOUT', 'DFOUT2'):
            lines = bytes(c & 0x7F for c in files[name]).decode(
                'ascii').split('\r')
            if lines[-1] == '':
                lines.pop()
            m = re.fullmatch(r'/mnt/(\S+) (\d+) (\d+) (\d+) (\d+)% /mnt/(\S+)',
                             lines[1]) if len(lines) == 2 else None
            ok = (lines[0] == hdr and m is not None
                  and m.group(1) == m.group(6) == CARRIER_VOL
                  and int(m.group(2)) == expect['total_blocks']
                  and int(m.group(3)) + int(m.group(4)) == int(m.group(2))
                  and expect['used_pre'] <= int(m.group(3)) <= used_post
                  and int(m.group(5)) == -(-int(m.group(3)) * 100
                                           // int(m.group(2))))
            if not ok:
                print(f"[check-chmod] FAIL: {name} not a valid df -P "
                      f"report (total {expect['total_blocks']}, used in "
                      f"[{expect['used_pre']}, {used_post}]): {lines!r}",
                      file=sys.stderr)
                return 1
            print(f'[check-chmod] {name}: {lines[1]}', file=sys.stderr)

        # The read-modify-write proof: LOCKFILE/RWFILE's full metadata,
        # read straight off the disk, must match compute_expectations()'s
        # PRE-run snapshot in every field except access -- which itself
        # must match the expected LOCK/round-trip value exactly.
        try:
            meta = read_meta(disk, ['LOCKFILE', 'RWFILE'])
        except FileNotFoundError as e:
            print(f'[check-chmod] FAIL: {e} (a locked file must survive '
                  f'rm)', file=sys.stderr)
            return 1

        for name in ('LOCKFILE', 'RWFILE'):
            want = expect['meta'][name]
            got = meta[name]
            for field, wval in want.items():
                gval = got[field]
                if gval != wval:
                    print(f'[check-chmod] FAIL: {name}.{field} expected '
                          f'{wval!r}, got {gval!r}', file=sys.stderr)
                    return 1

        print('[check-chmod] PASS: sh locked LOCKFILE and round-tripped '
              'RWFILE through chmod -dnw/+dnw with type/aux_type/eof/'
              'blocks_used/creation/mod-time byte-identical to staging; '
              'df -P reported the real total and a used/free split '
              'bracketed by the bitmap on both argument forms; rm (spawned directly) failed to DESTROY the '
              'locked file and it is still present')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
