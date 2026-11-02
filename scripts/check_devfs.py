#!/usr/bin/env python3
"""check_devfs.py -- docs/DEVFS.md's pseudo-root and `/dev` space
(`make check-devfs`).

Boots build/devfs.po (the play image, unit 1, boot volume BASIC) with
a second ProDOS volume build/devfs2.po (unit 2, volume SCRATCH) and a
DOS 3.3 floppy build/devfs_flop.do on slot 6 (build_devfs_image.py's
own header explains all three), drives everything at the shell and
asserts against the resulting screen -- the same idiom check_devblk.py
uses, adapted for `ls`/`cd`/`cat` instead of `dd`/`cmp`.

MOUNT ORDER IS LOAD-BEARING, found the hard way this session: a
slot-6 `mount_disk` call COLD-RESETS the machine (the SAME hazard
scripts/check_floppy.py's own `mount_disk` comment documents
independently for its OWN two-mount sequence) -- mounting it AFTER
units 1/2 are already running wipes the whole boot. Slot 6 is
therefore mounted FIRST, before either SmartPort unit, exactly once,
before any PT_F40 poke or stepping begins.

PROMPT DETECTION is the bare-`$` form (`rstrip() == '$'`), not
`startswith('$')`: the moment a command is typed and echoed, the SAME
row also starts with '$' (e.g. "$ls -1 /") and would false-positive
as "ready" before the command has done anything -- documented at
length in scripts/check_floppy.py's own `prompt_ready`, and measured
directly in this task: a naive `startswith('$')` predicate raced
ahead mid-command and fed the NEXT command's keystrokes into the
shell while the current one was still echoing, corrupting the whole
session ("sh: command not found" for a real, present program).

Five cases (docs/DEVFS.md):
  1. `ls -1 /` -> BASIC, dev, SCRATCH (ls's own pre-existing
     case-insensitive sort interleaves them this way, NOT literally
     "BASIC SCRATCH dev" -- docs/DEVFS-NOTES.md's dated entry); `ls -l
     /` shows DIR for all three. disk2_state's motor/track/
     quarter_track must not move across `ls /` with the floppy
     mounted -- the whole point of the SYS_DEVLIST design is that
     `/` never touches a device.
  2. `ls -1 /dev` -> the 7 fixed names, then s6d1 s6d2 s7d1 s7d2
     (alphabetical); s3d2 (/RAM's old slot) absent. `ls -l /dev`
     shows BLK for sNdM, CHR for the ttys and null.
  3. `cd /dev; ls s6d1` -> s6d1; `cd /; cd BASIC; pwd` -> /mnt/MAUX/;
     `cd /mnt/MAUX; cd ..; pwd` -> / (docs/DEVFS-NOTES.md: this
     actually resolves in liba's MKPATH/MKP_POP, not the kernel's
     PRC_DOTDOT -- sh's `cd` calls MKPATH before SC_SETPFX ever
     sees a raw ".."); `cd /; ls` -> the root listing.
  4. A SEPARATE fresh session, floppy NOT mounted: `ls -1 /dev` no
     longer shows s6d1/s6d2 (DEVLST-driven, not a table).
  5. Negative: `cat /dev` and `cat /` fail the SAME way a missing
     regular file does (`cat: cannot open PATH`); `ls /nosuch` still
     fails (`ls: PATH: cannot access`).

  7. (docs/GLOB-VROOT.md) sh's glob walks the kernel-owned `/`,
     `/dev` and `/mnt`: `echo /*`, `echo /m*`, `echo /MNT/*`, `echo
     /mnt/*`, every `/dev/*` name (compared space-free: the 40-column
     glass wraps a long `echo` with no separator), the bare-`*` forms
     from `cd /`, `cd /mnt` and `cd /dev` (the SC_GETPFX path), and
     the same `/mnt/*` and `/dev/*` again while the case-6 loop image
     is attached and after it is detached. disk2_state's motor/
     track/quarter_track/bit_pos must not move across `echo /mnt/*`
     with the floppy present and NOT mounted. Controls that must
     stay as they were: `echo /bin/ca*`, `echo DE*`, a quoted
     `'/*'`, an unmatched `/nosuch*` -- and `echo /*/` and `echo
     /bin/*/`, which stay LITERAL because glob matches only the last
     path component (shpth2.s GLOB_APPEND's header); that is the
     contract today, pinned here so a change to it is deliberate.
     KFIX7 item 2 (case 7b): the RELATIVE forms -- `echo mnt/*` from
     `/`, `./*` and `../*` from each of `/`, `/dev`, `/mnt`, an
     interior `..` (`/mnt/../*`), plus `ls -1 mnt`, `ls -1 dev`,
     `find dev` from `/`, `ls -1 ../mnt` from `/dev`, `ls -1 ..` from
     `/mnt` -- classified on the canonical path, with all four
     disk2_state fields unmoved. They replace the four rows that
     pinned these forms as literal.
     The storage type sh keeps per match (GLOBTYP -- $D for the
     root's children, $F for a /mnt volume, $A/$B for /dev's
     devices, a file nibble vs $D for a real directory's entries)
     is read back out of the shell's arena with `peek`. Expected
     lists are written out below from the fixture (the
     seven fixed names plus sNdM from the DEVLST bytes, the boot
     volume, SCRATCH, LOOPVOL), never from running the glob.

Teeth (docs/DEVFS.md): verified ONCE each by hand this session (a
source edit, a rebuild, a red run, a revert) rather than wired as
permanent CLI flags -- none of the three admits a data-level flag the
way check_unpack.py's --teeth-corrupt/--teeth-order do (they are
kernel/liba LOGIC changes: a masked-off flag test, a case-fold
skipped, a nibble mask dropped), and this gate's own images are
already assembled from source, not corrupted at mount time. The
transcripts are in docs/DEVFS-NOTES.md.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import arena  # noqa: E402  (merlin32 -v1 symbol dumps)
import gate_race as GR  # noqa: E402
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402
from pt_f40 import (PT_F40_ADDR, PT_F40B_ADDR, PT_F40_MAG1,  # noqa: E402
                    PT_F40_MAG2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def screen_rows(client):
    return client.call_tool('screen_text', {}).get('main', [])


def screen_blob(rows):
    return '\n'.join(rows)


def prompt_ready(rows):
    """A BARE prompt only -- see this module's own docstring for why
    `startswith('$')` is unsafe across a multi-command sequence."""
    live = [r for r in rows if r.strip()]
    return bool(live) and live[-1].rstrip() == '$'


STALE_STEPS = 60           # polls after which an unchanged screen counts


def wait_for_screen(client, predicate, label, max_steps=2000):
    rows = []
    for _ in GR.polls(client, max_steps):
        rows = screen_rows(client)
        if predicate(rows):
            return rows
    raise RuntimeError(f'timed out waiting for {label}; screen was:\n'
                       f'{screen_blob(rows)}')


def run_cmd(client, cmd, label, failures, max_steps=2000):
    """Type cmd (WITHOUT a trailing \\r -- callers supply it, matching
    the exact text a person types), wait for the next bare prompt,
    and return every non-blank row printed since the command's own
    echo (the command's OUTPUT, one string per screen row)."""
    before = len(screen_rows(client))
    # -- a bare prompt already on the glass is the PREVIOUS command's:
    # -- a busy shell (ten background jobs) takes longer than one
    # -- polling step to echo the keys just typed, and the first poll
    # -- then sees the stale prompt and calls the command done, so the
    # -- NEXT command's output is read as this one's (check-loop row H,
    # -- layout-dependent: learning:01M3KY2AS0XJ22DY89S7R728GC). Accept a
    # -- prompt only once the screen has CHANGED since before the
    # -- keys; STALE_STEPS bounds the wait for the one screen that can
    # -- legitimately come back identical (a full screen scrolled by
    # -- a periodic history).
    snap = [r.rstrip() for r in screen_rows(client) if r.strip()]
    polls = [0]

    def settled(rows):
        polls[0] += 1
        if not prompt_ready(rows):
            return False
        live_ = [r.rstrip() for r in rows if r.strip()]
        return live_ != snap or polls[0] >= GR.count(STALE_STEPS)

    client.call_tool('type', {'text': cmd})
    try:
        rows = wait_for_screen(client, settled,
                               f'{label}: prompt after {cmd!r}',
                               max_steps=max_steps)
    except RuntimeError as e:
        failures.append(str(e))
        return []
    live = [r.rstrip() for r in rows if r.strip()]
    # -- live[-1] is the fresh bare "$"; the row before it is the
    # -- LAST line of output (or, for a no-output command, the
    # -- command's own echo). Walk backward collecting output rows
    # -- until we hit the command's own echo line ("$cmd" or "$
    # -- cmd").
    out = []
    echo_bare = '$' + cmd.rstrip('\r')
    echo_sp = '$ ' + cmd.rstrip('\r')
    for row in reversed(live[:-1]):
        if row == echo_bare or row == echo_sp:
            break
        out.append(row)
    out.reverse()
    return out


def assert_eq(label, got, want, failures):
    if got != want:
        failures.append(f'{label}: got {got!r}, want {want!r}')
    else:
        print(f'[check-devfs] PASS {label}: {got!r}')


def assert_in(label, needle, haystack, failures):
    if needle not in haystack:
        failures.append(f'{label}: {needle!r} not found in {haystack!r}')
    else:
        print(f'[check-devfs] PASS {label}: found {needle!r}')


def check_glob(client, label, cmd, want_rows, failures):
    """Type cmd, assert the rows it printed are exactly want_rows."""
    out = run_cmd(client, cmd + '\r', label, failures)
    assert_eq(label, out, want_rows, failures)


def check_glob_flat(client, label, cmd, names, failures):
    """For a list too long for one 40-column glass row: the console
    wraps an `echo` with no separator and run_cmd right-strips each
    row, so compare the rows joined and SPACE-FREE against the
    expected names joined and space-free. Names are distinct tokens,
    so a wrong order, a missing or an extra name still fails."""
    out = run_cmd(client, cmd + '\r', label, failures)
    got = ''.join(out).replace(' ', '')
    want = ''.join(names)
    if got != want:
        failures.append(f'{label}: got {out!r}, want the names {names!r}')
    else:
        print(f'[check-devfs] PASS {label}: {len(names)} names in order')


GLOBREC = 64        # sh's result record stride (shpth2.s GLOBREC)


def glob_records(client, syms, n):
    """The first n result records sh's glob left in its arena and
    their storage types, as {name: type}, found by CONTENT: the console
    shell's bank is not a number this gate may assume, so every
    RamWorks bank that could hold a process is read and the one whose
    GLOBBUF decodes to n well-formed records is the shell's. Addresses
    come from a fresh merlin32 -v1 of sh.s, never a constant (a listing
    address is a property of one build). Returns None if no bank (or
    more than one) fits."""
    found = []
    for bank in range(1, 16):
        raw = client.call_tool('peek', {
            'addr': syms['GLOBBUF'], 'count': GLOBREC * n,
            'bank': 'aux', 'aux_bank': bank}).get('bytes')
        if not raw:
            continue
        names = []
        for i in range(n):
            rec = raw[i * GLOBREC:(i + 1) * GLOBREC]
            if 0 not in rec or not all(b >= 0x80 for b in rec[:rec.index(0)]):
                names = None
                break
            names.append(''.join(chr(b & 0x7F) for b in rec[:rec.index(0)]))
        if not names or not all(names):
            continue
        typ = client.call_tool('peek', {
            'addr': syms['GLOBTYP'], 'count': n,
            'bank': 'aux', 'aux_bank': bank}).get('bytes')
        found.append((bank, dict(zip(names, typ))))
    return found


def check_glob_types(client, syms, cmd, want, failures):
    """Type cmd (a glob whose matches are all in `want`, {name:
    wanted-type-or-set}) and assert the storage type sh kept per
    match (GLOBTYP, shpth2.s GLOB_KEEP) -- the directory-ness tab
    completion will read ($D directory, $F volume, $A/$B device)."""
    label = f'case7 types: {cmd}'
    run_cmd(client, cmd + '\r', label, failures)
    found = glob_records(client, syms, len(want))
    cands = [(b, d) for b, d in found if set(d) == set(want)]
    if len(cands) != 1:
        failures.append(f'{label}: want one bank holding {sorted(want)}, '
                        f'found {found!r}')
        return
    _bank, got = cands[0]
    for name, wt in want.items():
        ok = got[name] in wt if isinstance(wt, (set, tuple)) \
            else got[name] == wt
        if not ok:
            failures.append(f'{label}: {name} has storage type '
                            f'${got[name]:02X}, want {wt!r}')
    if not any(label in f for f in failures):
        print(f'[check-devfs] PASS {label}: '
              f'{ {n: hex(t) for n, t in got.items()} }')


def dev_paths(names):
    return ['/dev/' + n for n in names]


def mount_family(client, disk1, disk2, flop):
    """slot 6 FIRST (it cold-resets), then unit 1, then unit 2, then
    the PT_F40 poke, then boot -- see this module's own docstring."""
    if flop is not None:
        r3 = client.call_tool('mount_disk',
                              {'path': flop, 'slot': 6, 'order': 'do'})
        print(f'[check-devfs] slot6(floppy)={r3}', file=sys.stderr)
        if r3.get('ok') is False:
            raise RuntimeError(f'mount_disk(floppy) failed: {r3}')
    r1 = client.call_tool('mount_disk', {'path': disk1, 'unit': 1})
    print(f'[check-devfs] unit1={r1}', file=sys.stderr)
    if r1.get('ok') is False:
        raise RuntimeError(f'mount_disk(unit1) failed: {r1}')
    if disk2 is not None:
        r2 = client.call_tool('mount_disk', {'path': disk2, 'unit': 2})
        print(f'[check-devfs] unit2={r2}', file=sys.stderr)
        if r2.get('ok') is False:
            raise RuntimeError(f'mount_disk(unit2) failed: {r2}')
    for addr, val in ((PT_F40_ADDR, PT_F40_MAG1),
                      (PT_F40B_ADDR, PT_F40_MAG2)):
        client.call_tool('poke', {'addr': addr, 'bytes': [val],
                                  'bank': 'main'})
    wait_for_screen(client, prompt_ready, 'shell prompt')
    print('[check-devfs] shell prompt reached')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('disk1')
    ap.add_argument('disk2')
    ap.add_argument('flop')
    args = ap.parse_args()
    disk1 = os.path.abspath(args.disk1)
    disk2 = os.path.abspath(args.disk2)
    flop = os.path.abspath(args.flop)

    failures = []
    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)

    # -- Cases 1/2/3/5: one session, all three units mounted. --
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        client.call_tool('reset', {'backend': 'fast'})
        mount_family(client, disk1, disk2, flop)

        # -- Case 1: `ls /`, and the no-Disk-][-access proof. --
        d2_before = client.call_tool('disk2_state', {})
        out = run_cmd(client, 'ls -1 /\r', 'case1 ls -1 /', failures)
        # docs/VROOT.md: "/" is the kernel's table, no volume listing
        assert_eq('case1: ls -1 /', out,
                  ['bin', 'dev', 'etc', 'mnt', 'tmp', 'usr'], failures)
        out = run_cmd(client, 'ls -1 /mnt\r', 'case1 ls -1 /mnt',
                      failures)
        assert_eq('case1: ls -1 /mnt', out, ['MAUX', 'SCRATCH'],
                  failures)
        d2_after = client.call_tool('disk2_state', {})
        # -- bit_pos too (docs/GLOB-VROOT-NOTES.md sec 5): a poll that
        # -- spins the drive up and lets it spin down again leaves
        # -- motor_on and the head where they were; the read position
        # -- is the counter that cannot hide it.
        for field in ('motor_on', 'track', 'quarter_track', 'bit_pos'):
            if d2_before.get(field) != d2_after.get(field):
                failures.append(
                    f'case1: disk2_state {field!r} moved across '
                    f'`ls /` ({d2_before.get(field)!r} -> '
                    f'{d2_after.get(field)!r}) -- a floppy was '
                    f'polled listing "/"')
            else:
                print(f'[check-devfs] PASS case1: disk2_state '
                      f'{field!r} unchanged ({d2_before.get(field)!r})')

        out = run_cmd(client, 'ls -l /\r', 'case1 ls -l /', failures)
        for row in out:
            if not row.startswith('DIR'):
                failures.append(f'case1: ls -l / row not DIR: {row!r}')
        if len(out) == 6:
            print(f'[check-devfs] PASS case1: ls -l / all DIR: {out}')
        else:
            failures.append(f'case1: ls -l / expected 6 rows, got {out}')
        out = run_cmd(client, 'ls -l /mnt\r', 'case1 ls -l /mnt',
                      failures)
        if len(out) == 2 and all(r.startswith('DIR') for r in out):
            print(f'[check-devfs] PASS case1: ls -l /mnt all DIR: {out}')
        else:
            failures.append(f'case1: ls -l /mnt expected 2 DIR rows, '
                            f'got {out}')

        # -- Case 2: `ls /dev`. --
        out = run_cmd(client, 'ls -1 /dev\r', 'case2 ls -1 /dev',
                      failures)
        want = ['null', 's6d1', 's6d2', 's7d1', 's7d2', 'tty', 'tty1',
                'tty2', 'tty3', 'tty4', 'ttya0']
        assert_eq('case2: ls -1 /dev', out, want, failures)
        ram_present = [a for a in ('s3d1', 's3d2') if a in out]
        if ram_present:
            failures.append(f'case2: {ram_present!r} (/RAM\'s slot) '
                            f'present in /dev, expected absent')
        else:
            print('[check-devfs] PASS case2: s3d1/s3d2 (/RAM) absent')

        out = run_cmd(client, 'ls -l /dev\r', 'case2 ls -l /dev',
                      failures)
        ok = True
        for row in out:
            name = row.split()[-1] if row.split() else ''
            if name.startswith('s') and 'd' in name:
                if not row.startswith('BLK'):
                    ok = False
                    failures.append(f'case2: ls -l /dev {name!r} not '
                                    f'BLK: {row!r}')
            else:
                if not row.startswith('CHR'):
                    ok = False
                    failures.append(f'case2: ls -l /dev {name!r} not '
                                    f'CHR: {row!r}')
        if ok:
            print(f'[check-devfs] PASS case2: ls -l /dev BLK/CHR '
                  f'columns correct')

        # -- Case 3: cd / relative resolution / dot-dot from a
        # -- synthetic or volume root. --
        run_cmd(client, 'cd /dev\r', 'case3 cd /dev', failures)
        out = run_cmd(client, 'ls s6d1\r', 'case3 ls s6d1', failures)
        assert_eq('case3: cd /dev; ls s6d1', out, ['s6d1'], failures)

        run_cmd(client, 'cd /\r', 'case3 cd /', failures)
        run_cmd(client, 'cd mnt/MAUX\r', 'case3 cd mnt/MAUX', failures)
        out = run_cmd(client, 'pwd\r', 'case3 pwd (/mnt/MAUX)', failures)
        assert_eq('case3: cd /; cd mnt/MAUX; pwd', out, ['/mnt/MAUX/'],
                  failures)

        run_cmd(client, 'cd /mnt/MAUX\r', 'case3 cd /mnt/MAUX', failures)
        run_cmd(client, 'cd ..\r', 'case3 cd .. (volume root)',
               failures)
        out = run_cmd(client, 'pwd\r', 'case3 pwd (after ..)',
                      failures)
        assert_eq('case3: cd /mnt/MAUX; cd ..; pwd', out, ['/mnt/'],
                  failures)
        run_cmd(client, 'cd ..\r', 'case3 cd .. (/mnt)', failures)
        out = run_cmd(client, 'pwd\r', 'case3 pwd (after ../..)',
                      failures)
        assert_eq('case3: cd /mnt/MAUX; cd ..; cd ..; pwd', out, ['/'],
                  failures)

        run_cmd(client, 'cd /\r', 'case3 cd / (for bare ls)', failures)
        out = run_cmd(client, 'ls\r', 'case3 ls (bare)', failures)
        joined = ' '.join(out)
        for name in ('bin', 'dev', 'mnt'):
            assert_in('case3: bare ls at /', name, joined, failures)
        run_cmd(client, 'cd /mnt\r', 'case3 cd /mnt (for bare ls)',
                failures)
        out = run_cmd(client, 'ls\r', 'case3 ls (bare, /mnt)', failures)
        joined = ' '.join(out)
        for name in ('MAUX', 'SCRATCH'):
            assert_in('case3: bare ls at /mnt', name, joined, failures)

        # -- Case 5: negative. --
        out = run_cmd(client, 'cat /dev\r', 'case5 cat /dev', failures)
        assert_eq('case5: cat /dev', out, ['cat: cannot open /dev'],
                  failures)
        out = run_cmd(client, 'cat /\r', 'case5 cat /', failures)
        assert_eq('case5: cat /', out, ['cat: cannot open /'],
                  failures)
        out = run_cmd(client, 'ls /nosuch\r', 'case5 ls /nosuch',
                      failures)
        assert_eq('case5: ls /nosuch', out,
                  ['ls: /nosuch: cannot access'], failures)

        # -- Case 7 (docs/GLOB-VROOT.md): sh's glob over `/`, `/dev`
        # -- and `/mnt`. The cwd is /mnt here (case 3's last cd).
        d2_before = client.call_tool('disk2_state', {})
        check_glob(client, 'case7: echo /*', 'echo /*',
                   ['/bin /dev /etc /mnt /tmp /usr'], failures)
        check_glob(client, 'case7: echo /m*', 'echo /m*', ['/mnt'],
                   failures)
        check_glob(client, 'case7: echo /MNT/*', 'echo /MNT/*',
                   ['/MNT/MAUX /MNT/SCRATCH'], failures)
        check_glob(client, 'case7: echo /mnt/*', 'echo /mnt/*',
                   ['/mnt/MAUX /mnt/SCRATCH'], failures)
        check_glob_flat(client, 'case7: every /dev/* name',
                        'echo /dev/*', dev_paths(want), failures)
        run_cmd(client, 'cd /\r', 'case7 cd /', failures)
        check_glob(client, 'case7: cd /; echo *', 'echo *',
                   ['bin dev etc mnt tmp usr'], failures)
        run_cmd(client, 'cd /mnt\r', 'case7 cd /mnt', failures)
        check_glob(client, 'case7: cd /mnt; echo *', 'echo *',
                   ['MAUX SCRATCH'], failures)
        run_cmd(client, 'cd /dev\r', 'case7 cd /dev', failures)
        check_glob_flat(client, 'case7: cd /dev; every * name',
                        'echo *', want, failures)
        # -- the recorded limit: only the last component is matched
        check_glob(client, 'case7: echo /*/ stays literal', 'echo /*/',
                   ['/*/'], failures)
        check_glob(client, 'case7: echo /bin/*/ stays literal',
                   'echo /bin/*/', ['/bin/*/'], failures)
        # -- Case 7b (KFIX7 item 2): the RELATIVE forms. RD_SYNCHK used
        # -- to see only an absolute `/`, `/dev` or `/mnt`, so a glob
        # -- or listing that named one of them relative to a virtual
        # -- cwd stayed literal / "cannot access". It classifies the
        # -- CANONICAL path now (KFIX9: SYS_VROOT op 5, loopseg.s
        # -- LP_CLASS; it was readsyn.s RD_CANON): the cwd appended,
        # -- "." and ".." resolved wherever they stand. These rows
        # -- REPLACE the four that pinned the old behaviour:
        # --   'cd /; echo mnt/* stays literal'      -> case7b '/' 'mnt/'
        # --   'cd /mnt; echo ./* stays literal'     -> case7b '/mnt' './'
        # --   'cd /dev; echo ../* stays literal'    -> case7b '/dev' '../'
        # --   'echo /mnt/../* stays literal'        -> case7b, '/mnt/../'
        # --                                            from all 3 cwds
        d2b_before = client.call_tool('disk2_state', {})
        root_l = ['bin', 'dev', 'etc', 'mnt', 'tmp', 'usr']
        mnt_l = ['MAUX', 'SCRATCH']
        matrix = {
            '/': [('./', root_l), ('../', root_l), ('mnt/', mnt_l),
                  ('./mnt/', mnt_l), ('dev/', want),
                  ('/mnt/../', root_l)],
            '/dev': [('./', want), ('../', root_l), ('../mnt/', mnt_l),
                     ('../dev/', want), ('/mnt/../', root_l),
                     ('/dev/../dev/', want)],
            '/mnt': [('./', mnt_l), ('../', root_l), ('../mnt/', mnt_l),
                     ('../dev/', want), ('../../', root_l),
                     ('/mnt/../', root_l)],
        }
        for cwd, rows in matrix.items():
            run_cmd(client, f'cd {cwd}\r', f'case7b cd {cwd}', failures)
            for prefix, names in rows:
                check_glob_flat(
                    client, f'case7b: cd {cwd}; echo {prefix}*',
                    f'echo {prefix}*', [prefix + n for n in names],
                    failures)
        # -- a pattern, not just `*`: the match runs on the right list
        run_cmd(client, 'cd /dev\r', 'case7b cd /dev', failures)
        check_glob(client, 'case7b: cd /dev; echo ../m*', 'echo ../m*',
                   ['../mnt'], failures)
        run_cmd(client, 'cd /mnt\r', 'case7b cd /mnt', failures)
        check_glob(client, 'case7b: cd /mnt; echo ../d*', 'echo ../d*',
                   ['../dev'], failures)
        # -- the other readdir.s consumers share the one classifier
        run_cmd(client, 'cd /\r', 'case7b cd /', failures)
        out = run_cmd(client, 'ls -1 mnt\r', 'case7b ls -1 mnt', failures)
        assert_eq('case7b: cd /; ls -1 mnt', out, mnt_l, failures)
        out = run_cmd(client, 'ls -1 dev\r', 'case7b ls -1 dev', failures)
        assert_eq('case7b: cd /; ls -1 dev', out, want, failures)
        out = run_cmd(client, 'find dev\r', 'case7b find dev', failures)
        got = sorted(''.join(out).replace(' ', '').replace('dev/', ' dev/')
                     .split())
        assert_eq('case7b: cd /; find dev (names, sorted)', got,
                  sorted(['dev'] + ['dev/' + n for n in want]), failures)
        run_cmd(client, 'cd /dev\r', 'case7b cd /dev', failures)
        out = run_cmd(client, 'ls -1 ../mnt\r', 'case7b ls -1 ../mnt',
                      failures)
        assert_eq('case7b: cd /dev; ls -1 ../mnt', out, mnt_l, failures)
        run_cmd(client, 'cd /mnt\r', 'case7b cd /mnt', failures)
        out = run_cmd(client, 'ls -1 ..\r', 'case7b ls -1 ..', failures)
        assert_eq('case7b: cd /mnt; ls -1 ..', out, root_l, failures)
        # -- Case 7b-real (KFIX8 item 4): `..` from a REAL cwd. Every row
        # -- above stands at `/`, `/dev` or `/mnt`; these stand below a
        # -- volume. `/mnt/MAUX/BIN` is the boot volume's BIN, so its
        # -- cwd reads back as `/bin/` (longest match) and `..` is `/`;
        # -- `/mnt/MAUX/DEMO` maps to nothing, stays `/mnt/MAUX/DEMO/`,
        # -- and its `..` is the volume root, `../..` is `/mnt`,
        # -- `../../..` is `/`. The absolute forms put the dots INSIDE
        # -- the path, where only op 5 resolves them (MKPATH takes a
        # -- leading run only); only `echo` rows, because `ls` stats its
        # -- operand first and the kernel resolves no interior `..`
        # -- (KFIX7-NOTES sec 3 item 4), so `ls /mnt/MAUX/DEMO/../..`
        # -- says "cannot access" on the base too.
        run_cmd(client, 'cd /mnt/MAUX/BIN\r', 'case7b-real cd BIN',
                failures)
        out = run_cmd(client, 'ls -1 ..\r', 'case7b-real ls ..',
                      failures)
        assert_eq('case7b-real: cd /mnt/MAUX/BIN; ls -1 ..', out,
                  root_l, failures)
        check_glob_flat(client, 'case7b-real: cd /mnt/MAUX/BIN; echo ../*',
                        'echo ../*', ['../' + n for n in root_l],
                        failures)
        out = run_cmd(client, 'ls -1 ../..\r', 'case7b-real ls ../..',
                      failures)
        assert_eq('case7b-real: cd /mnt/MAUX/BIN; ls -1 ../..', out,
                  root_l, failures)
        run_cmd(client, 'cd /mnt/MAUX/DEMO\r', 'case7b-real cd DEMO',
                failures)
        out = run_cmd(client, 'ls -1 ..\r', 'case7b-real ls .. (DEMO)',
                      failures)
        # -- KFIX9 (review of KFIX8): the WHOLE volume root, compared
        # -- with the same directory named by its absolute path
        root_vol = run_cmd(client, 'ls -1 /mnt/MAUX\r',
                           'case7b-real ls /mnt/MAUX', failures)
        assert_in('case7b-real: the volume root is not empty',
                  'DEMO', ' '.join(root_vol), failures)
        assert_eq('case7b-real: cd /mnt/MAUX/DEMO; ls -1 .. is the '
                  'volume root', out, root_vol, failures)
        out = run_cmd(client, 'ls -1 ../..\r', 'case7b-real ls ../..',
                      failures)
        assert_eq('case7b-real: cd /mnt/MAUX/DEMO; ls -1 ../..', out,
                  mnt_l, failures)
        out = run_cmd(client, 'ls -1 ../../..\r',
                      'case7b-real ls ../../..', failures)
        assert_eq('case7b-real: cd /mnt/MAUX/DEMO; ls -1 ../../..', out,
                  root_l, failures)
        check_glob_flat(client,
                        'case7b-real: cd /mnt/MAUX/DEMO; echo ../../*',
                        'echo ../../*', ['../../' + n for n in mnt_l],
                        failures)
        check_glob_flat(client,
                        'case7b-real: cd /mnt/MAUX/DEMO; echo ../../../*',
                        'echo ../../../*', ['../../../' + n
                                            for n in root_l], failures)
        # -- KFIX9: the classifier is SYS_VROOT op 5 now (loopseg.s
        # -- LP_CLASS). The last four rows pop the FIRST component and
        # -- push another, so a stale "first component" kind answers the
        # -- wrong directory (`/dev/../mnt` must list /mnt, not /dev);
        # -- the empty and "." components must vanish.
        for rel, names in (('/mnt/MAUX/DEMO/../..', mnt_l),
                           ('/mnt/MAUX/DEMO/../../..', root_l),
                           ('/mnt/MAUX/../..', root_l),
                           ('/bin/../mnt', mnt_l),
                           ('/dev/../mnt', mnt_l),
                           ('/mnt/../dev', want),
                           ('/mnt/MAUX/../../dev', want),
                           ('/mnt/./MAUX/../.', mnt_l)):
            check_glob_flat(client, f'case7b-real: echo {rel}/*',
                            f'echo {rel}/*',
                            [rel + '/' + n for n in names], failures)
        # -- KFIX9 (review R1): the cwd is respelled virtually, a
        # -- component the user TYPED is not. At the volume root a typed
        # -- `BIN` is not the virtual `/bin`: `BIN/../..` is `/mnt`, and
        # -- `BIN/../*` is a real path (no interior `..` resolves, so it
        # -- stays literal), not the names of `/`.
        run_cmd(client, 'cd /mnt/MAUX\r', 'case7b-real cd MAUX', failures)
        check_glob_flat(client, 'case7b-real: cd /mnt/MAUX; echo '
                        'BIN/../../*', 'echo BIN/../../*',
                        ['BIN/../../' + n for n in mnt_l], failures)
        check_glob(client, 'case7b-real: cd /mnt/MAUX; echo BIN/../*',
                   'echo BIN/../*', ['BIN/../*'], failures)
        # -- an EMPTY path is not a path: op 5 answers 0 for it and the
        # -- callers see what they always saw (these pin the base)
        for cwd in ('/', '/mnt'):
            run_cmd(client, f'cd {cwd}\r', f'case7b cd {cwd}', failures)
            out = run_cmd(client, "ls ''\r", 'case7b ls empty', failures)
            assert_eq(f"case7b: cd {cwd}; ls ''", out,
                      ['ls: : cannot access'], failures)
            out = run_cmd(client, "find ''\r", 'case7b find empty',
                          failures)
            assert_eq(f"case7b: cd {cwd}; find ''", out,
                      ['find: : cannot access'], failures)
            out = run_cmd(client, "echo ''\r", 'case7b echo empty',
                          failures)
            assert_eq(f"case7b: cd {cwd}; echo ''", out, [], failures)
        # -- sh's glob copies the directory part into the 65-byte
        # -- SH_GPATH (op 5 classifies it): up to 64 bytes is walked
        # -- (and finds nothing here), a longer prefix stays literal and
        # -- must not run past the buffer. The shell is alive and the
        # -- namespace intact afterwards.
        # the buffer's neighbour is HD_BODY (the heredoc body, idle here):
        # an unbounded copy lands in it, silently, so the rows below read
        # it back from the console shell's bank (pid 3) around each word
        sh_syms = arena.symbol_table('sh')
        sh_bank = client.call_tool('peek', {
            'addr': 0x0800 + 3 * 16 + 3, 'count': 1, 'bank': 'aux',
            'aux_bank': 0}).get('bytes')[0]

        def hd_body():
            return client.call_tool('peek', {
                'addr': sh_syms['HD_BODY'], 'count': 48, 'bank': 'aux',
                'aux_bank': sh_bank}).get('bytes')
        for n in (62, 63, 64, 70, 100):
            word = '/' + 'a' * n + '/x*'
            hd_before = hd_body()
            # the word is too long for one glass row, so count it
            # (`wc -c` counts echo's newline too) rather than read it
            out = run_cmd(client, f'echo {word} | wc -c\r',
                          f'case7b long prefix {n}', failures)
            got = out[-1].strip() if out else None
            if hd_body() != hd_before:
                failures.append(f'case7b: a {n + 2}-byte directory prefix '
                                f'wrote past SH_GPATH (HD_BODY changed)')
            if got != str(len(word) + 1):
                failures.append(f'case7b: echo of a {len(word)}-byte '
                                f'word (directory prefix {n + 2}) wrote '
                                f'{got!r} bytes, wanted the word back '
                                f'literally ({len(word) + 1})')
            else:
                print(f'[check-devfs] PASS case7b: a {n + 2}-byte '
                      f'directory prefix stays literal')
        run_cmd(client, 'cd /\r', 'case7b cd /', failures)
        check_glob_flat(client, 'case7b: after the long prefixes: echo /*',
                        'echo /*', ['/' + n for n in root_l], failures)
        # -- none of it polled the Disk ][ (all four fields)
        d2b_after = client.call_tool('disk2_state', {})
        for field in ('motor_on', 'track', 'quarter_track', 'bit_pos'):
            if d2b_before.get(field) != d2b_after.get(field):
                failures.append(
                    f'case7b: disk2_state {field!r} moved across the '
                    f'relative-form rows ({d2b_before.get(field)!r} -> '
                    f'{d2b_after.get(field)!r}) -- a floppy was polled')
            else:
                print(f'[check-devfs] PASS case7b: disk2_state {field!r} '
                      f'unchanged ({d2b_before.get(field)!r})')
        # -- controls
        run_cmd(client, 'cd /mnt/MAUX\r', 'case7 cd /mnt/MAUX', failures)
        check_glob(client, 'case7 control: echo DE*', 'echo DE*',
                   ['DELTEN.SYSTEM DEMO'], failures)
        check_glob(client, 'case7 control: echo /bin/ca*',
                   'echo /bin/ca*', ['/bin/cal /bin/cat'], failures)
        check_glob(client, "case7 control: echo '/*' (quoted)",
                   "echo '/*'", ['/*'], failures)
        check_glob(client, 'case7 control: echo /nosuch*',
                   'echo /nosuch*', ['/nosuch*'], failures)
        # -- directory-ness per match (GLOBTYP): the storage type the
        # -- enumerator reported, kept for tab completion to read.
        syms = arena.symbol_table('sh')
        check_glob_types(client, syms, 'echo /*',
                         {'/' + n: 0x0D for n in
                          ('bin', 'dev', 'etc', 'mnt', 'tmp', 'usr')},
                         failures)
        check_glob_types(client, syms, 'echo /mnt/*',
                         {'/mnt/MAUX': 0x0F, '/mnt/SCRATCH': 0x0F},
                         failures)
        check_glob_types(client, syms, 'echo /dev/tty*',
                         {'/dev/' + n: 0x0A for n in
                          ('tty', 'tty1', 'tty2', 'tty3', 'tty4',
                           'ttya0')}, failures)
        check_glob_types(client, syms, 'echo /dev/s*',
                         {'/dev/' + n: 0x0B for n in
                          ('s6d1', 's6d2', 's7d1', 's7d2')}, failures)
        check_glob_types(client, syms, 'echo /mnt/MAUX/DE*',
                         {'/mnt/MAUX/DELTEN.SYSTEM': (1, 2, 3),
                          '/mnt/MAUX/DEMO': 0x0D}, failures)
        run_cmd(client, 'cd /\r', 'case7 cd / (leave MAUX)', failures)

        # -- Case 6 (docs/LOOP-S1.md): s3d2 is in /dev only while a
        # -- loop image is attached, as a block device like the rest.
        out = run_cmd(client, 'mount /mnt/MAUX/DEMO/L.PO\r',
                      'case6 mount', failures)
        assert_eq('case6: mount L.PO is silent', out, [], failures)
        out = run_cmd(client, 'ls -1 /dev\r', 'case6 ls -1 /dev',
                      failures)
        assert_eq('case6: ls -1 /dev with a loop attached', out,
                  sorted(want + ['s3d2']), failures)
        check_glob(client, 'case7: /mnt/* with a loop attached',
                   'echo /mnt/*', ['/mnt/LOOPVOL /mnt/MAUX /mnt/SCRATCH'],
                   failures)
        check_glob_flat(client, 'case7: /dev/* with a loop attached',
                        'echo /dev/*',
                        dev_paths(sorted(want + ['s3d2'])), failures)
        out = run_cmd(client, 'ls -l /dev\r', 'case6 ls -l /dev',
                      failures)
        rows = [r for r in out if r.split() and r.split()[-1] == 's3d2']
        if len(rows) == 1 and rows[0].startswith('BLK'):
            print('[check-devfs] PASS case6: s3d2 is a BLK row')
        else:
            failures.append(f'case6: s3d2 not a single BLK row: {rows!r}')
        out = run_cmd(client, 'umount /mnt/LOOPVOL\r', 'case6 umount',
                      failures)
        assert_eq('case6: umount is silent', out, [], failures)
        out = run_cmd(client, 'ls -1 /dev\r', 'case6 ls -1 /dev again',
                      failures)
        assert_eq('case6: ls -1 /dev after umount', out, want, failures)
        check_glob(client, 'case7: /mnt/* after the loop is detached',
                   'echo /mnt/*', ['/mnt/MAUX /mnt/SCRATCH'], failures)
        check_glob_flat(client, 'case7: /dev/* after the loop is detached',
                        'echo /dev/*', dev_paths(want), failures)
        # -- the whole case, loop attach included, never polled the
        # -- Disk ][ (d2_before was taken at the top of case 7).
        d2_after = client.call_tool('disk2_state', {})
        for field in ('motor_on', 'track', 'quarter_track', 'bit_pos'):
            if d2_before.get(field) != d2_after.get(field):
                failures.append(
                    f'case7: disk2_state {field!r} moved across all of '
                    f'case 7 ({d2_before.get(field)!r} -> '
                    f'{d2_after.get(field)!r}) -- a floppy was polled '
                    f'to list /mnt')
            else:
                print(f'[check-devfs] PASS case7: disk2_state '
                      f'{field!r} unchanged ({d2_before.get(field)!r})')
    finally:
        client.close()

    # -- Case 4: a FRESH session, floppy NOT mounted. --
    client2 = MCPClient([SUPERVISOR], env)
    try:
        client2.initialize()
        client2.call_tool('reset', {'backend': 'fast'})
        mount_family(client2, disk1, disk2, None)
        out = run_cmd(client2, 'ls -1 /dev\r', 'case4 ls -1 /dev '
                      '(no floppy)', failures)
        want = ['null', 's7d1', 's7d2', 'tty', 'tty1', 'tty2', 'tty3',
                'tty4', 'ttya0']
        assert_eq('case4: ls -1 /dev, floppy not mounted', out, want,
                  failures)
    finally:
        client2.close()

    if failures:
        print('[check-devfs] FAIL:')
        for f in failures:
            print('  - ' + f)
        return 1
    print('[check-devfs] PASS: ls / and ls /dev list correctly (no '
          'Disk ][ access for "/"), cd / and cd /dev admit the two '
          'synthetic directories and their relative lookups, "cd .." '
          'from a synthetic or volume root reaches "/", a rebooted '
          'floppy-less session drops s6d1/s6d2 from /dev, and cat/ls '
          'on the synthetic paths fail exactly like a missing file')
    return 0


if __name__ == '__main__':
    sys.exit(main())
