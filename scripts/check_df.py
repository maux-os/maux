#!/usr/bin/env python3
"""check_df.py -- `df` reports used/free from the volume directory
(`make check-df`, docs/DU-DF.md).

Boots build/df.po (BASIC, unit 1), build/df2.po (SCRATCH, unit 2) and
a DOS 3.3 floppy on slot 6, and drives `df` at the shell. THE ORACLE
IS a2til, NOT df: every expected total/used/free comes from opening the
very image file the emulator is running (a2til's Volume.total_blocks
and free_blocks(), which COUNTS THE VOLUME BITMAP -- the one thing df
no longer reads). df gets there by a different road (one SYS_GFI,
aux_type and blocks_used), so agreement is not a tautology. The
images are write-through, so after a write the file is re-read.

Cases:
  1. `df` -> the -P header, then BASIC and SCRATCH rows (DEVLST order),
     each used/free equal to a2til's; disk2_state's motor/track/
     quarter_track unchanged across it (no Disk ][ was polled to list).
  2. `df /mnt/SCRATCH`, `df BASIC` (a bare volume name), `df
     /bin/ls` (a path on the volume), `df -P /mnt/SCRATCH`, and `df
     -k /mnt/SCRATCH` (halves, rounding up).
  3. A write: `cp /mnt/MAUX/MAUX.SYSTEM /mnt/SCRATCH/BIG`; `df /mnt/SCRATCH` moves
     Used up by exactly the new file's blocks_used (a2til's) and
     Available down by the same; BASIC's row does not move. Then `rm`
     and the numbers come back.
  3b. `du` of a VOLUME root agrees with the same oracle: GET_FILE_INFO
     on a volume directory reports the whole volume's used count in
     blocks_used (that is what df stands on), and du used to seed its
     walk with it and then add every file again -- `du /mnt/MAUX` said
     3362 on a volume with 1685 blocks used. A volume's files are its
     used count less its own metadata: 2 boot blocks, the 4-block
     volume directory, and ceil(total/4096) bitmap blocks.
  4. `df /nosuch; echo $?` -> the access line and 1; `df -z; echo $?`
     -> usage and 2.

The 40-column screen wraps the 59-character header, so rows are
re-joined: a screen row exactly 40 wide with a non-blank last cell
continues on the next one.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402
import check_devfs as cd  # noqa: E402
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

HDR512 = 'Filesystem 512-blocks Used Available Capacity Mounted on'
HDR1K = 'Filesystem 1024-blocks Used Available Capacity Mounted on'
COLS = 40


def volume_view(path):
    """(name, total, used) straight off the image file, from the
    bitmap -- a fresh open every call."""
    v = prodos.Volume(path)
    try:
        return v.name, v.total_blocks, v.total_blocks - v.free_blocks
    finally:
        v.close()


def file_blocks(path, parent_rel, name):
    v = prodos.Volume(path)
    try:
        dbn = v._resolve_dir(parent_rel)
        return v._find_entry(dbn, name.upper()).blocks_used
    finally:
        v.close()


def volume_meta(total):
    """Blocks a standard ProDOS volume spends on itself: boot 2,
    volume directory 4, one bitmap block per 4096 blocks."""
    return 2 + 4 + -(-total // 4096)


def row(name, total, used, k=False):
    pct = 0 if total == 0 else -(-used * 100 // total)
    if k:
        total, used = -(-total // 2), -(-used // 2)
    return (f'/mnt/{name} {total} {used} {max(total - used, 0)} '
            f'{pct}% /mnt/{name}')


def logical_lines(rows):
    """Re-join wrapped screen rows into logical lines."""
    out, cur = [], ''
    for i, r in enumerate(rows):
        if not r.strip() and not cur:
            continue
        cur += r.rstrip() if len(r.rstrip()) < COLS else r
        wrapped = len(r) >= COLS and r[COLS - 1] != ' '
        # A row of exactly COLS characters is ambiguous (wrapped, or
        # just full): '/mnt/SCRATCH ... /mnt/SCRATCH' is 40.  A prompt
        # line next to it settles it -- no df output starts with '$'.
        if wrapped and i + 1 < len(rows) and rows[i + 1].startswith('$'):
            wrapped = False
        if not wrapped:
            out.append(cur.rstrip())
            cur = ''
    if cur:
        out.append(cur.rstrip())
    return out


def run(client, cmd, failures):
    """Type cmd, wait for the next bare prompt, return the logical
    output lines between the command's echo and that prompt."""
    client.call_tool('type', {'text': cmd + '\r'})
    try:
        rows = cd.wait_for_screen(client, cd.prompt_ready,
                                  f'prompt after {cmd!r}', max_steps=6000)
    except RuntimeError as e:
        failures.append(str(e))
        return []
    lines = logical_lines(rows)
    echo = [i for i, l in enumerate(lines)
            if l in ('$' + cmd, '$ ' + cmd)]
    if not echo:
        failures.append(f'{cmd!r}: echo line not found in {lines!r}')
        return []
    return lines[echo[-1] + 1:-1]


def check(label, got, want, failures):
    if got != want:
        failures.append(f'{label}: got {got!r}, want {want!r}')
    else:
        print(f'[check-df] PASS {label}: {got!r}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('disk1')
    ap.add_argument('disk2')
    ap.add_argument('flop')
    args = ap.parse_args()
    d1, d2, flop = (os.path.abspath(p) for p in
                    (args.disk1, args.disk2, args.flop))
    failures = []
    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)

    b_name, b_tot, b_used = volume_view(d1)
    s_name, s_tot, s_used = volume_view(d2)
    print(f'[check-df] a2til: {b_name} {b_tot} used {b_used}; '
          f'{s_name} {s_tot} used {s_used}')
    big_expected = file_blocks(d1, '/', 'MAUX.SYSTEM') + 0

    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        client.call_tool('reset', {'backend': 'fast'})
        cd.mount_family(client, d1, d2, flop)

        # -- 1: bare df, and the no-Disk-][-poll proof. --
        d2_before = client.call_tool('disk2_state', {})
        out = run(client, 'df', failures)
        # DEVLST order (unit 2 before unit 1 here), NOT sorted, so
        # the rows are compared as a set under the one header.
        check('1: df', [out[0]] + sorted(out[1:]),
              [HDR512] + sorted([row(b_name, b_tot, b_used),
                                 row(s_name, s_tot, s_used)]), failures)
        d2_after = client.call_tool('disk2_state', {})
        for field in ('motor_on', 'track', 'quarter_track'):
            if d2_before.get(field) != d2_after.get(field):
                failures.append(
                    f'1: disk2_state {field!r} moved across `df` '
                    f'({d2_before.get(field)!r} -> '
                    f'{d2_after.get(field)!r}) -- a floppy was polled')
            else:
                print(f'[check-df] PASS 1: disk2_state {field!r} '
                      f'unchanged ({d2_before.get(field)!r})')

        # -- 2: operands. --
        want_s = [HDR512, row(s_name, s_tot, s_used)]
        want_b = [HDR512, row(b_name, b_tot, b_used)]
        check('2: df /mnt/SCRATCH', run(client, 'df /mnt/SCRATCH', failures),
              want_s, failures)
        check('2: df MAUX', run(client, 'df MAUX', failures),
              want_b, failures)
        check('2: df /bin/ls',
              run(client, 'df /bin/ls', failures), want_b, failures)
        check('2: df -P /mnt/SCRATCH',
              run(client, 'df -P /mnt/SCRATCH', failures), want_s, failures)
        check('2: df -k /mnt/SCRATCH',
              run(client, 'df -k /mnt/SCRATCH', failures),
              [HDR1K, row(s_name, s_tot, s_used, k=True)], failures)
        out = run(client, 'df -k', failures)
        check('2: df -k (every volume)', [out[0]] + sorted(out[1:]),
              [HDR1K] + sorted([row(b_name, b_tot, b_used, k=True),
                                row(s_name, s_tot, s_used, k=True)]),
              failures)

        # -- 3b (first half): du of BASIC's root, before any write. --
        out = run(client, 'du -s /mnt/MAUX', failures)
        check('3b: du -s /mnt/MAUX = used - volume metadata',
              [l.split() for l in out],
              [[str(b_used - volume_meta(b_tot)), '/mnt/MAUX']], failures)

        # -- 3: a write moves the numbers by the right amount. --
        run(client, 'cp /mnt/MAUX/MAUX.SYSTEM /mnt/SCRATCH/BIG', failures)
        s2_name, s2_tot, s2_used = volume_view(d2)
        big = file_blocks(d2, '/', 'BIG')
        if s2_used - s_used != big or big < big_expected:
            failures.append(f'3: a2til: SCRATCH used {s_used} -> '
                            f'{s2_used}, BIG has {big} blocks '
                            f'(MAUX.SYSTEM {big_expected})')
        check('3: df /mnt/SCRATCH after cp',
              run(client, 'df /mnt/SCRATCH', failures),
              [HDR512, row(s2_name, s2_tot, s2_used)], failures)
        check('3: used moved by the file\'s blocks_used',
              (s2_used - s_used, s_tot - s2_used),
              (big, s_tot - s_used - big), failures)
        check('3b: du -s /mnt/SCRATCH = the file\'s blocks',
              [l.split() for l in run(client, 'du -s /mnt/SCRATCH', failures)],
              [[str(big), '/mnt/SCRATCH']], failures)
        run(client, 'cd /mnt/SCRATCH', failures)
        check('3b: du at the volume root, no operand',
              [l.split() for l in run(client, 'du', failures)],
              [[str(big), '.']], failures)
        run(client, 'cd /', failures)
        check('3: BASIC did not move',
              run(client, 'df /mnt/MAUX', failures), want_b, failures)
        run(client, 'rm /mnt/SCRATCH/BIG', failures)
        check('3: df /mnt/SCRATCH after rm',
              run(client, 'df /mnt/SCRATCH', failures), want_s, failures)

        # -- 4: error paths. --
        check('4: df /nosuch',
              run(client, 'df /nosuch', failures),
              [HDR512, 'df: /nosuch: cannot access'], failures)
        check('4: exit status 1', run(client, 'echo $?', failures),
              ['1'], failures)
        check('4: df -z', run(client, 'df -z', failures),
              ['usage: df [-Pk] [file...]'], failures)
        check('4: exit status 2', run(client, 'echo $?', failures),
              ['2'], failures)
    finally:
        client.close()

    if failures:
        print('[check-df] FAIL:')
        for f in failures:
            print('  - ' + f)
        return 1
    print('[check-df] PASS: df -- header and a row per ONLINE volume '
          '(no Disk ][ poll), used/free equal to a2til\'s bitmap count '
          'on both volumes, operand forms, -P/-k, a write moves Used '
          'by exactly the new file\'s blocks and rm restores it, '
          'error and usage exits')
    return 0


if __name__ == '__main__':
    sys.exit(main())
