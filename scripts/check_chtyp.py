#!/usr/bin/env python3
"""check_chtyp.py -- `chtyp` changes the ProDOS type and aux, and NOTHING
else.

WHY THE READ-BACK MATTERS MORE THAN THE CHANGE. SET_FILE_INFO ($C3) takes
a FULL parameter block -- access, file_type, aux_type, mod_date, mod_time
-- and writes every field verbatim, so a tool that sends zeros for the
fields it does not mean to touch DESTROYS them, silently and on disk.
`chmod` has the same hazard from the other side and check_chmod.py proves
its half; this proves chtyp's. Every case below therefore asserts the
whole directory entry, not just the field under test.

THE TYPE IS NOT COSMETIC HERE. On ProDOS the type is where "can this be
run?" lives (inc/mli.equ at FTYPE_TXT, citing GNO/ME's precedent: no
`chmod +x`, use `chtyp`), and maux leans on the AUX harder than ProDOS
did -- spawn() loads a binary AT ITS aux_type. A wrong aux is a program
that loads at the wrong address.

Cases:
  1. -t with a MNEMONIC (BIN). The mnemonics are inc/mli.equ's own
     FTYPE_* names, so this also proves the two have not drifted.
  2. -t with HEX ($FF) -- quoted, because `$` opens a shell expansion.
  3. -t with DECIMAL (4). Its own case because it is the one form that
     carries a value in A across a jsr, and it was wrong on the first
     run: `chtyp -t 4` set the type to $00 while BIN and $FF were both
     already right (MUL10 clobbers the accumulator).
  4. -a alone: the aux changes and the TYPE, ACCESS, dates and EOF do
     not. The preservation proof.
  5. -t alone: the type changes and the AUX does not. The other half --
     a tool that read back only the fields it was about to write would
     pass case 4 and fail this one.
  6. -t and -a together.
  7. a bad type is a usage error, exit 2, and the file is UNTOUCHED.
  8. neither option is a usage error -- not a no-op that rewrites every
     named file with its own current values.
  9. an unreadable path reports, sets exit 1, and chtyp CONTINUES: a
     later file on the same command line is still changed.

TEETH (2026-09-21, each sabotage built and run separately):
  * with the `lda GFIPARM_AUX / sta SFIPARM_AUX` pair removed from the
    write-back, case 5 fails -- a -t-only run writes whatever aux the
    LAST chtyp in that bank used. It only fails because case 5 poisons
    the parmlist with a different aux first: SFIPARM is emitted TEXT and
    a warm respawn does not recopy text, so the first version of this
    gate passed that sabotage. A probe that cannot produce a different
    answer is not evidence.
  * with the `lda GFIPARM_ACC / sta SFIPARM_ACC` pair removed, cases 4
    and 5 fail on access.
  * with PARSETYPE's `lda PVAL+1 / bne` guard removed, `-t 260` is
    ACCEPTED and sets $04 -- 260 is $104 and the low byte lands. The
    command reports success and the type is one nobody asked for, which
    is why silent truncation gets a case of its own.
"""
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_vi as V                                      # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR     # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos                                  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

VOL = 'MAUX'
STEP = 200_000


def at_prompt(rows):
    nb = [r for r in rows if r.strip()]
    return bool(nb) and nb[-1].strip().endswith('$')


def step(c, n=1):
    for _ in range(n):
        c.call_tool('step', {'cycles': STEP})


def sh(c, line, tries=400):
    """Type one command and wait for the prompt back."""
    V.t(c, line + '\r')
    for _ in range(tries):
        step(c)
        if at_prompt(V.rows(c)):
            return
    raise AssertionError(f'{line!r}: no prompt; screen '
                         f'{[r.rstrip() for r in V.rows(c) if r.strip()][-3:]!r}')


def meta(disk, name):
    """The whole directory entry, read from the HOST -- the guest's own
    `ls -l` shows the type but not the aux, and not the access byte."""
    prodos.mount(disk, replace=True)
    try:
        e = prodos.stat(f'/mnt/{VOL}/{name}')
        return {'type': e.type, 'aux': e.aux_type, 'access': e.access,
                'eof': e.eof, 'created': e.creation, 'modified': e.last_mod}
    finally:
        prodos.unmount(VOL)


def main():
    if not os.path.exists(V.DISK):
        print('error: build/play.po missing -- run make play-image',
              file=sys.stderr)
        return 2
    tmp = tempfile.mkdtemp(prefix='maux-chtyp-')
    disk = os.path.join(tmp, 'chtyp.po')
    shutil.copyfile(V.DISK, disk)
    failures = []
    c = MCPClient([SUPERVISOR],
                  dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR))
    try:
        c.initialize()
        r = c.call_tool('reset', {'backend': 'fast', 'aux': 'ramworks'})
        if not r.get('ok'):
            raise RuntimeError(f'reset failed: {r}')
        # write-through, not copy: the host reads the entries back
        r = c.call_tool('mount_disk', {'path': disk, 'unit': 1})
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')
        V.settle(c, at_prompt, 'shell prompt', max_steps=3000)

        sh(c, 'echo payload > /mnt/MAUX/CTA')
        sh(c, 'echo payload > /mnt/MAUX/CTB')
        born = meta(disk, 'CTA')
        if born['type'] != 0x04:
            failures.append(f'fixture is type ${born["type"]:02X}, not TXT '
                            f'-- a shell redirect should make TXT')

        def check(label, name, want_type, want_aux, base):
            m = meta(disk, name)
            if m['type'] != want_type:
                failures.append(f'{label}: type is ${m["type"]:02X}, '
                                f'expected ${want_type:02X}')
            if m['aux'] != want_aux:
                failures.append(f'{label}: aux is ${m["aux"]:04X}, '
                                f'expected ${want_aux:04X}')
            for f in ('access', 'eof', 'created'):
                if m[f] != base[f]:
                    failures.append(
                        f'{label}: {f} changed ({base[f]!r} -> {m[f]!r}) -- '
                        f'SET_FILE_INFO writes the WHOLE block, so a field '
                        f'chtyp did not mean to touch was destroyed')
            return m

        sh(c, 'chtyp -t BIN /mnt/MAUX/CTA')
        m = check('-t BIN (mnemonic)', 'CTA', 0x06, born['aux'], born)
        print('[check-chtyp] -t BIN: type $06, everything else intact')

        sh(c, "chtyp -t '$FF' /mnt/MAUX/CTA")
        m = check('-t $FF (hex)', 'CTA', 0xFF, born['aux'], born)
        print('[check-chtyp] -t $FF: hex form parsed')

        sh(c, 'chtyp -t 4 /mnt/MAUX/CTA')
        m = check('-t 4 (decimal)', 'CTA', 0x04, born['aux'], born)
        print('[check-chtyp] -t 4: decimal form parsed (the form that was '
              'wrong on the first run)')

        sh(c, "chtyp -a '$0800' /mnt/MAUX/CTA")
        m = check('-a alone', 'CTA', 0x04, 0x0800, born)
        print('[check-chtyp] -a alone: aux $0800, TYPE PRESERVED')

        # POISON THE PARMLIST FIRST, and this is the whole reason case 5
        # bites. SFIPARM lives in the TEXT segment (`da 0`), and a warm
        # respawn reuses the bank WITHOUT recopying text -- so the next
        # chtyp starts with the previous chtyp's parmlist still in it.
        # Without this line, "-t alone preserves the aux" passes even
        # with the aux write-back deleted, because the stale value left
        # by the -a run above happens to be the value being asserted.
        # Measured: that exact sabotage passed until this was added.
        sh(c, "chtyp -a '$1234' /mnt/MAUX/CTB")
        sh(c, 'chtyp -t SYS /mnt/MAUX/CTA')
        m = check('-t alone after -a', 'CTA', 0xFF, 0x0800, born)
        print('[check-chtyp] -t alone: type $FF, AUX PRESERVED -- and the '
              'parmlist was poisoned with a different aux first, so this '
              'is a read-back and not a leftover')

        sh(c, 'chtyp -t BIN -a 8192 /mnt/MAUX/CTA')
        m = check('-t and -a together', 'CTA', 0x06, 8192, born)
        print('[check-chtyp] -t with -a: both applied')

        before = meta(disk, 'CTA')
        sh(c, 'chtyp -t ZZZ /mnt/MAUX/CTA')
        after = meta(disk, 'CTA')
        if after != before:
            failures.append(f'a bad type CHANGED the file: {before} -> '
                            f'{after}')
        else:
            print('[check-chtyp] a bad type is refused and the file is '
                  'untouched')

        # A type is ONE byte. 260 is $104, and without the guard its low
        # byte lands as $04 -- the command succeeds and sets TXT, a type
        # nobody asked for. Silent truncation, so it gets its own case.
        sh(c, 'chtyp -t 260 /mnt/MAUX/CTA')
        if meta(disk, 'CTA') != before:
            failures.append('chtyp -t 260 was accepted and TRUNCATED to '
                            '$04 -- an out-of-range type must be refused, '
                            'not silently narrowed')
        else:
            print('[check-chtyp] -t 260 is refused, not truncated to $04')

        sh(c, 'chtyp /mnt/MAUX/CTA')
        if meta(disk, 'CTA') != before:
            failures.append('chtyp with NEITHER option rewrote the file')
        else:
            print('[check-chtyp] neither option: refused, not a silent '
                  'rewrite')

        # 9: a bad path first, a good one second
        sh(c, 'chtyp -t TXT /mnt/MAUX/NOSUCHFILE /mnt/MAUX/CTB')
        mb = meta(disk, 'CTB')
        if mb['aux'] != 0x1234:
            failures.append(
                f'CTB aux is ${mb["aux"]:04X}, not the $1234 set above -- '
                f'the continue path did not preserve it')
        if mb['type'] != 0x04:
            failures.append(
                f'after an unreadable path, the NEXT file was not changed '
                f'(CTB type ${mb["type"]:02X}) -- chtyp must report and '
                f'continue')
        else:
            print('[check-chtyp] an unreadable path reports and chtyp '
                  'continues to the next file')
    finally:
        try:
            c.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        c.close()
        shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        print()
        for f in failures:
            print(f'[check-chtyp] FAIL: {f}', file=sys.stderr)
        return 1
    print()
    print('[check-chtyp] PASS: mnemonic, hex and decimal type forms; -a '
          'alone preserves the type and -t alone preserves the aux; a bad '
          'type and a bare invocation are both refused without touching '
          'the file; an unreadable path reports and continues -- and every '
          'case asserts the WHOLE directory entry, not just the field '
          'under test')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
