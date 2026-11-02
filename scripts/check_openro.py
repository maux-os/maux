#!/usr/bin/env python3
"""check_openro.py -- the read-only open intent (`make check-openro`,
docs/OPEN-RO-2.md, docs/OPEN-RO-2-NOTES.md).

Boots the play image and types each row at the shell, the
check_devpath.py idiom (check_mount's helpers are imported).  One file
/tmp/F of three lines ("a", "b", "c") and the rows of the brief:

  1. exec 3<F 4<F        two opens of one unlocked file succeed, and
                         the two fds read INDEPENDENT marks
  2. interleave          read 3, read 4, read 3: marks do not bleed;
                         3 bytes from fd 3, then 1 from fd 4 is the
                         file's FIRST byte, and fd 3 goes on at byte 4
  3. diff F F, cmp F F   exit 0 (they open the path twice)
     comm, paste, join, pr -m -t F F   match the host's tools
  4. write through a read-only fd is refused (MLIE_ACCESS $4E) by
     EITHER fd of a group, file intact
  5. OPEN-RW-2 CHANGED rows 5 and 6.  A write open of a path with
     read-only opens used to be refused (`cannot redirect`); ONE
     writer now joins the group.  5: exec 3<F; echo x >>F succeeds,
     the reader sees the appended line; a SECOND appender joins
     (OAPPEND-1), a SECOND no-intent writer (`>`) is refused.
  6. a write open first, then a `<` open: the reader now joins
  7. refcounted close: close one of two fds, the other still reads;
     close both, the file can be opened for write again
  8. fork, SET_EOF, error codes, group park/unpark: the kernel
     probe, scripts/check_openro_k.py (sh's subshell does not carry
     `<&N`, so the shell cannot drive those)
  9. pool pressure: six background jobs, each holding its OWN file
     open twice (six groups, a pool of six): all start, because a
     group parks like any other file.  A group that PINNED its
     buffer would starve the sixth job's spawn (`sh: command not
     found`) -- the shape that decided V1 over V3.

ASCII only.  Exit 0 green, 1 red (listed), 2 rig problem.
"""
import argparse
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import check_devfs as D  # noqa: E402
import check_mount as M  # noqa: E402
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402
from a2til import prodos  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STOP = False        # --stop: fail fast (sabotage runs; a red row can hang)


def host_two(argv, lines):
    """A two-operand host tool (comm, paste, join, pr -m -t) run on
    the same file twice, as the 40-col console shows it (tabs
    expanded to 8, trailing blanks gone)."""
    import subprocess
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, 'x')
        with open(p, 'w') as fh:
            fh.write(''.join(l + '\n' for l in lines))
        out = subprocess.run(argv + [p, p], capture_output=True,
                             text=True, check=True).stdout
    return [l.expandtabs(8).rstrip() for l in out.splitlines()]


# two bytes per call.  run_cmd anchors on the one-row echo of the
# command, so every typed line stays under the 40-column glass:
# $D is the dd, $N the bit bucket for its record report.
DD3 = '$D <&3 2>$N'
DD4 = '$D <&4 2>$N'
# (an odd byte count ends mid-row; the echo gives the prompt its row)
DT3 = '$T <&3 2>$N; echo'
DO4 = '$O <&4 2>$N; echo'
DT3B = '$D <&3 2>$N; echo'


def run_rows(client, f, dump=False):
    sh, status = M.sh, M.status

    def eq(label, got, want, failures):
        M.eq(label, got, want, failures)
        if failures and STOP:
            raise RuntimeError(f'stopped at the first red row: '
                               f'{failures[0]}')

    def S(cmd, label):
        got = M.unwrap(sh(client, cmd, label, f))
        if dump:
            print(f'[dump] {cmd!r} -> {got!r}')
        return got

    def X(label):
        return status(client, f, label)

    S('D="dd bs=1 count=2"', 'mkd')
    S('N=/dev/null', 'mkn')
    S('T="dd bs=1 count=3"', 'mkt')
    S('O="dd bs=1 count=1"', 'mko')
    S('echo a > /tmp/F', 'mk1')
    S('echo b >> /tmp/F', 'mk2')
    S('echo c >> /tmp/F', 'mk3')
    eq('0: the fixture', S('cat /tmp/F', '0 cat'), ['a', 'b', 'c'], f)
    S('echo 1 > /tmp/J1', 'mkj')

    # 1. two read opens of one unlocked file, independent marks
    got = S('exec 3</tmp/F 4</tmp/F', '1 exec')
    eq('1: exec 3<F 4<F: output', got, [], f)
    eq('1: exec 3<F 4<F: exit', X('1'), '0', f)
    eq('1: cat <&3', S('cat <&3', '1 cat3'), ['a', 'b', 'c'], f)
    eq('1: cat <&4 (its own mark, still at 0)',
       S('cat <&4', '1 cat4'), ['a', 'b', 'c'], f)
    S('exec 3<&- 4<&-', '1 close')

    # 2. interleaved reads: neither mark bleeds into the other
    S('exec 3</tmp/F 4</tmp/F', '2 exec')
    got = [S(c, '2 dd')
           for c in (DD3, DD4, DD3, DD4)]
    eq('2: two bytes at a time, fd 3 4 3 4', got,
       [['a'], ['a'], ['b'], ['b']], f)
    S('exec 3<&- 4<&-', '2 close')

    # 2b. three bytes from fd 3, then ONE from fd 4: the file's first
    # byte, not its fourth; and fd 3 goes on from byte 4
    S('exec 3</tmp/F 4</tmp/F', '2b exec')
    eq('2b: 3 bytes from fd 3', S(DT3, '2b dd3'), ['a', 'b'], f)
    eq('2b: then 1 from fd 4 is the first byte',
       S(DO4, '2b dd4'), ['a'], f)
    eq('2b: fd 3 goes on at byte 4', S(DT3B, '2b dd3b'),
       ['c'], f)
    S('exec 3<&- 4<&-', '2b close')

    # 3. the two-operand tools, one path twice
    eq('3: diff F F: output', S('diff /tmp/F /tmp/F', '3 diff'), [], f)
    eq('3: diff F F: exit', X('3d'), '0', f)
    eq('3: cmp F F: output', S('cmp /tmp/F /tmp/F', '3 cmp'), [], f)
    eq('3: cmp F F: exit', X('3c'), '0', f)
    got = S('comm /tmp/F /tmp/F', '3 comm')
    want = host_two(['comm'], ['a', 'b', 'c'])
    eq('3: comm F F matches the host', got, want, f)
    eq('3: comm F F: exit', X('3m'), '0', f)
    for tool, argv in (('paste', ['paste']), ('join', ['join']),
                       ('pr -m -t', ['pr', '-m', '-t'])):
        got = S(f'{tool} /tmp/F /tmp/F', f'3 {tool}')
        eq(f'3: {tool} F F matches the host', got,
           host_two(argv, ['a', 'b', 'c']), f)
        eq(f'3: {tool} F F: exit', X(f'3 {tool}'), '0', f)

    # 4. a write through a read-only fd is refused, the file intact
    S('exec 3</tmp/F', '4 exec')
    got = S('echo x >&3', '4 write')
    eq('4: echo x >&3 (fd 3 is a < open): refused', X('4w') != '0', True, f)
    S('exec 3<&-', '4 close')
    eq('4: file intact', S('cat /tmp/F', '4 cat'), ['a', 'b', 'c'], f)
    # ... through EITHER descriptor of a group of two
    S('exec 3</tmp/F 4</tmp/F', '4b exec')
    S('echo x >&4', '4b write4')
    eq('4b: echo x >&4 (fd 4 of a group): refused', X('4b') != '0',
       True, f)
    S('echo x >&3', '4b write3')
    eq('4b: echo x >&3 (fd 3 of a group): refused', X('4b3') != '0',
       True, f)
    S('exec 3<&- 4<&-', '4b close')
    eq('4b: file intact', S('cat /tmp/F', '4b cat'), ['a', 'b', 'c'], f)

    # 5. a write open of a path with a read-only open: ONE writer
    # joins (OPEN-RW-2; it was `cannot redirect` before)
    S('exec 3</tmp/F', '5 exec')
    got = S('echo x >> /tmp/F', '5 ap')
    eq('5: echo x >>F while 3<F: the writer joins', got, [], f)
    eq('5: exit', X('5r'), '0', f)
    eq('5: the reader sees the appended line',
       S('cat <&3', '5 cat3'), ['a', 'b', 'c', 'x'], f)
    S('exec 5>>/tmp/F', '5 w1')
    # OAPPEND-1: a second `>>` joins an appender; the second writer
    # that stays refused is a NO-INTENT one (`>` is creat: count 3)
    eq('5: a second APPENDER joins',
       S('echo z >> /tmp/F', '5 ap2'), [], f)
    eq('5: a SECOND, no-intent writer is still refused',
       S('echo y > /tmp/F', '5 ap3'), ['sh: cannot redirect'], f)
    S('exec 5>&- 3<&-', '5 close')
    eq('5: file', S('cat /tmp/F', '5 cat'), ['a', 'b', 'c', 'x', 'z'],
       f)
    S('echo a > /tmp/F', '5 r1')
    S('echo b >> /tmp/F', '5 r2')
    S('echo c >> /tmp/F', '5 r3')

    # 6. a read open of a path with a WRITE open: the reader joins
    # (OPEN-RW-2; it was `cannot redirect` before)
    S('exec 5>/tmp/G', '6 exec')
    eq('6: cat <G while 5>G: joins', S('cat < /tmp/G', '6 cat'), [], f)
    S('exec 5>&-', '6 close')
    eq('6: after the close it opens', S('cat < /tmp/G', '6 cat2'), [], f)
    eq('6: exit', X('6c'), '0', f)

    # 7. refcounted close
    S('exec 3</tmp/F 4</tmp/F', '7 exec')
    S('exec 3<&-', '7 close3')
    eq('7: fd 4 still reads after fd 3 closed',
       S('cat <&4', '7 cat4'), ['a', 'b', 'c'], f)
    S('exec 4<&-', '7 close4')
    S('echo z > /tmp/F', '7 write')
    eq('7: both closed: the file opens for write again',
       S('cat /tmp/F', '7 cat'), ['z'], f)
    # 7b. the mark HOLDER is freed with its entry: a group of three read
    # through its LAST fd (the highest OFT index holds the live mark),
    # all closed, then a smaller group on another file.  A stale holder
    # would be GET_MARKed through a freed (refnum 0) entry on the new
    # group's first read.
    S('exec 3</tmp/F 4</tmp/F 5</tmp/F', '7b exec')
    eq('7b: read through the last fd of three',
       S('cat <&5', '7b cat5'), ['z'], f)       # (row 7 left z)
    S('exec 3<&- 4<&- 5<&-', '7b close')
    S('exec 3</tmp/J1 4</tmp/J1', '7b exec2')
    eq('7b: a new group reads (no stale holder)',
       S('cat <&3', '7b cat3'), ['1'], f)
    eq('7b: ... and its other fd, from its own mark',
       S('cat <&4', '7b cat4'), ['1'], f)
    S('exec 3<&- 4<&-', '7b close2')
    S('echo a > /tmp/F', '7 r1')
    S('echo b >> /tmp/F', '7 r2')
    S('echo c >> /tmp/F', '7 r3')

    # 9. pool pressure: six groups at once, each on its own file, all
    # held by background jobs (check-loop G2's shape with a second
    # redirect).  Six buffers: the sixth job's spawn needs one, so a
    # group must be parkable.
    for i in range(1, 7):
        S(f'echo {i} > /tmp/J{i}', f'9 mk{i}')
    # all six must be running AT ONCE (the pressure is simultaneous):
    # ~1.5M harness cycles per arming line, +3M under MAUX_GATE_RACE=late
    # (GATE-RACE-1). 100 s is ~100M.
    bad = []
    rows_ = []
    for i in range(1, 7):
        rows = S(f'sleep 100 3</tmp/J{i} 4</tmp/J{i} &', f'9 job{i}')
        out = ' '.join(rows)
        if not out.startswith('[') or 'not found' in out \
                or 'cannot' in out:
            bad.append((i, out))
        rows_.append(rows)
    eq('9: six jobs each holding a group all start', bad, [], f)
    eq('9: ...and all six are still running (the overlap held)',
       [p for p in rows_ if not M.job_alive(client, p)], [], f)
    D.run_cmd(client, 'wait\r', '9 wait', f, max_steps=30000)

    # 8. (fork with a shared entry, and group park/unpark under pool
    # pressure: sh's subshell does not carry `<&N` -- the same
    # `(cat <&3)` prints nothing on the base kernel -- so those rows are
    # the kernel probe's: scripts/check_openro_k.py)


def run(play, failures, dump):
    tmp = tempfile.mkdtemp(prefix='maux-openro-')
    try:
        boot = os.path.join(tmp, 'play.po')
        shutil.copy(play, boot)
        # dd is a build tool, not in the play image: stage it, because
        # `dd bs=1 count=N` is the one reader that advances a mark by
        # EXACTLY N (cat, head and the shell's read take more or less)
        v = prodos.Volume(boot)
        with open(os.path.join(ROOT, 'build', 'dd.bin'), 'rb') as fh:
            v.write_file('/BIN/DD', fh.read(), file_type=0x06,
                         aux_type=0x0800)
        v.close()
        env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
        client = MCPClient([SUPERVISOR], env)
        try:
            client.initialize()
            client.call_tool('reset', {'backend': 'fast'})
            r = client.call_tool('mount_disk', {'path': boot, 'unit': 1})
            if r.get('ok') is False:
                raise RuntimeError(f'mount_disk(unit 1) failed: {r}')
            for addr, val in ((D.PT_F40_ADDR, D.PT_F40_MAG1),
                              (D.PT_F40B_ADDR, D.PT_F40_MAG2)):
                client.call_tool('poke', {'addr': addr, 'bytes': [val],
                                          'bank': 'main'})
            D.wait_for_screen(client, D.prompt_ready, 'shell prompt')
            run_rows(client, failures, dump)
        finally:
            client.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--play', default=os.path.join(ROOT, 'build',
                                                   'play.po'))
    ap.add_argument('--dump', action='store_true')
    ap.add_argument('--stop', action='store_true')
    args = ap.parse_args()
    global STOP
    STOP = args.stop
    play = os.path.abspath(args.play)
    if not os.path.exists(play):
        print(f'check-openro: {play} missing -- make play-image')
        return 2
    failures = []
    try:
        run(play, failures, args.dump)
    except RuntimeError as exc:
        failures.append(str(exc))
    if failures:
        print(f'[check-openro] FAIL: {len(failures)} row(s)')
        for x in failures:
            print(f'  - {x}'.replace('\n', '\n    '))
        return 1
    print('[check-openro] PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
