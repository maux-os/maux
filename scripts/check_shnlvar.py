#!/usr/bin/env python3
"""check_shnlvar.py -- a variable holding a newline survives a subshell
(`make check-shnlvar`, docs/SH-NLVAR.md, docs/SH-NLVAR-NOTES.md).

Boots the play image and types each row at the shell, the
check_shprefix.py idiom (check_shfd's helpers are imported).

ORACLE.  A row with want=None is also run, line for line, by the
host's `dash` and by bash 5, in a scratch directory holding the same
files, and maux must print exactly what dash prints (dash and bash 5
must agree with each other first; macOS /bin/sh is bash 3.2 and is
never the oracle).  A row with a WANT list has no POSIX twin -- a
deliberate maux refusal -- and carries its output.

Every row that reads a variable in a subshell holds a `$8D` in that
variable: a quote-only or backslash-only value already passed before
the fix.  Rows that echo a value are paired with a comparator
(`( . ./s5 )`) that rebuilds the value INSIDE the child and compares
byte for byte, because run_cmd drops blank rows and echo re-adds a
newline, so neither can see an empty line or a trailing one.

Rows:
  N1  the defect: three lines through ( ) and $( )
  N2  hostile: a line that is a real command must not run
  N3  content: quote, backslash, `$X`, an empty middle line
  N4  trailing newlines
  N5  IFS (unexported, exported, holding a newline)
  N6  an exported variable (envp, never the pipe)
  N7  the ring budget, at its boundary
  N8  nested pipelines in the body

Teeth: scripts/teeth_shnlvar.py.

ASCII only.  Exit 0 green, 1 red (listed), 2 rig problem.
"""
import argparse
import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_shfd as F  # noqa: E402
import check_devfs as D  # noqa: E402
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The files every row works on.  k3: L1 L2 L3.  kh: the middle line is
# a real, side-effecting command.  kq/kb/kx: a quote, a backslash, a
# `$X`.  ke: an empty middle line.  kl: 16 letters on 16 lines, 31
# bytes (VARVALLEN) with 15 newlines.  s4/s5: comparators run INSIDE
# the child (`( . ./s5 )`): s5 re-captures $Z and compares it with $V;
# s4 rebuilds `a<NL>` and compares.
F.FIXTURE += [
    'echo L1 > k3', 'echo L2 >> k3', 'echo L3 >> k3',
    'echo L1 > kh', "echo 'echo PWNED > SIDE' >> kh", 'echo L3 >> kh',
    'echo L1 > kq', 'echo "it\'s" >> kq', 'echo L3 >> kq',
    'echo L1 > kb', "echo 'a\\qb' >> kb", 'echo L3 >> kb',
    'echo L1 > kx', "echo '$X' >> kx", 'echo L3 >> kx',
    'echo L1 > ke', 'echo >> ke', 'echo L3 >> ke',
    'echo a > kl',
] + [f'echo {c} >> kl' for c in 'bcdefghijklmnop'] + [
    "echo 'W=$(cat $Z)' > s5",
    "echo 'if [ \"$V\" = \"$W\" ]' >> s5",
    "echo 'then echo same; fi' >> s5",
    "echo 'W=$(echo a; echo .)' > s4",
    "echo 'W=${W%.}' >> s4",
    "echo 'if [ \"$V\" = \"$W\" ]' >> s4",
    "echo 'then echo same; fi' >> s4",
]

# Typed into maux ONLY (the host shells would print a uudecode error
# into every oracle row): files that hold a LOW $0D, which no typed
# line can make.  lo = `a` $0D; sc3 = `echo x` (high-bit text) $0D `y`: no $8D.
MAUX_FIXTURE = [
    "echo 'begin 644 lo' > lo.uu", "echo '\"80T`' >> lo.uu",
    "echo '`' >> lo.uu", 'echo end >> lo.uu', 'uudecode lo.uu',
    "echo 'begin 644 sc3' > sc3.uu", "echo '(Y>/H[Z#X#?D`' >> sc3.uu",
    "echo '`' >> sc3.uu", 'echo end >> sc3.uu', 'uudecode sc3.uu',
]

CMP = '( . ./s5 )'


def unset(*names):
    """`unset` lines that stay inside the 38-column glass."""
    out, cur = [], 'unset'
    for n in names:
        if len(cur) + 1 + len(n) > 38:
            out.append(cur)
            cur = 'unset'
        cur += ' ' + n
    out.append(cur)
    return out


def big(n):
    """The name of the n-th 15-character variable of the N7 rows."""
    return 'B' * 14 + str(n)


def n7(rlen, *lines):
    """Four 15-byte names holding kl's 31-byte, 15-newline value (48
    bytes each on the pipe once a newline costs one byte), a 31-byte Q,
    and an R of `rlen` bytes, then `lines`, then the cleanup."""
    names = [big(i) for i in range(1, 5)]
    return ([f'{n}=$(cat kl)' for n in names]
            + ['Q=' + 'abcdefghijklmnopqrstuvwxyz01234',
               'R=' + 'r' * rlen] + list(lines)
            + unset(*names, 'Q', 'R'))


# The ring: SUBVCNT starts at body+CR; each variable adds name + '=' +
# value + CR; a total of SUBPIPECAP (250) or more is refused.  The body
# `echo ran` is 9, four big variables are 192, Q is 1+1+31+1 = 34, and
# R adds 3 + its length: R of 11 bytes makes 249, accepted; 12 makes
# 250, refused.  Counting a newline as two bytes the four big ones
# alone are 252.
REFUSED = 'sh: $(): cannot pass variables'

# (label, lines, want) -- want None = ORACLE (dash decides).
ROWS = [
    # ---- N1. the defect --------------------------------------------
    ('N1 ( ) sees three lines',
     ['V=$(cat k3)', '(echo "$V")', 'echo S$?', 'unset V'], None),
    ('N1b ( ) unquoted: L1 L2 L3',
     ['V=$(cat k3)', '(echo $V)', 'unset V'], None),
    ('N1c $( ) sees three lines',
     ['V=$(cat k3)', 'W=$(echo "$V")', 'echo "$W"', 'unset V W'], None),
    ('N1d byte for byte, in the child',
     ['Z=k3', 'V=$(cat k3)', CMP, 'unset V Z'], None),
    # ---- N2. hostile: a line of F that is a real command -----------
    ('N2 ( ) does not run a line of the value',
     ['rm -f SIDE', 'V=$(cat kh)', '(echo "$V")',
      'test -f SIDE && echo EXISTS', 'rm -f SIDE', 'unset V'], None),
    ('N2b $( ) does not run a line of the value',
     ['rm -f SIDE', 'V=$(cat kh)', 'W=$(echo "$V")', 'echo "$W"',
      'test -f SIDE && echo EXISTS', 'rm -f SIDE', 'unset V W'], None),
    # ---- N3. content, each paired with a $8D -----------------------
    ('N3a a quote',
     ['Z=kq', 'V=$(cat kq)', '(echo "$V")', CMP, 'unset V Z'], None),
    ('N3b a backslash',
     ['Z=kb', 'V=$(cat kb)', '(echo "$V")', CMP, 'unset V Z'], None),
    ('N3c $X does not expand in the child',
     ['Z=kx', 'X=EXP', 'V=$(cat kx)', '(echo "$V")', CMP,
      'unset V Z X'], None),
    ('N3d an empty middle line',
     ['Z=ke', 'V=$(cat ke)', CMP, '(echo "$V" | grep -c "^$")',
      'unset V Z'], None),
    # ---- N4. trailing newlines -------------------------------------
    ('N4a $( ) strips every trailing newline',
     ['V=$(echo a; echo; echo)', 'echo "[$V]"', 'unset V'], None),
    ('N4b a value ENDING in a newline survives ( )',
     ['V=$(echo a; echo .)', 'V=${V%.}', '( . ./s4 )', 'unset V'], None),
    ('N4c ... and is observable through $( )',
     ['V=$(echo a; echo .)', 'V=${V%.}', "X=$(printf '%s|' \"$V\")",
      'echo "$X"', 'unset V X'], None),
    # A low $0D is not a newline to `$( )` (it is not stripped), and
    # UNESC folds it to $8D when the word is assigned, so it is held as
    # a newline and now crosses ( ) like one.  No POSIX twin: dash holds
    # a CR.  This pins today's fold; it is not a feature of this stream.
    ('N4d a low $0D is kept by $( ), folded to a newline',
     ['V=$(cat lo)', 'echo "[$V]"', '(echo "[$V]")', 'unset V'],
     ['[a', ']', '[a', ']']),
    # FLIPPED by SH-FOREIGN (docs/SH-FOREIGN.md, operator ruling "a
    # script in the system's standard text convention must execute"):
    # a script FILE (the seekable read path) is foreign text, so its low
    # $0D ENDS a line -- sc3 is `echo x` $0D `y`, i.e. two lines, the
    # second a command that does not exist.  It used to pin "one line,
    # prints x then y", which is byte-for-byte the shape of a two-line
    # ProDOS script; the two cannot both hold.  What N4d/N2 pin -- a low
    # $0D that arrives on a PIPE (the serialiser's newline) is data -- is
    # untouched, and is the reason the fold is conditioned on provenance.
    ('N4e a low $0D in a script FILE ends the line (SH-FOREIGN)',
     ['sh ./sc3'], ['x', 'sh: command not found']),
    # ---- N5. IFS ---------------------------------------------------
    ('N5a an unexported IFS reaches the child',
     ['IFS=:', 'V=$(cat k3)', '(echo $V)', 'unset IFS V'], None),
    ('N5b an exported IFS reaches the child',
     ['IFS=:', 'export IFS', 'V=$(cat k3)', '(echo $V)',
      'unset IFS V'], None),
    ('N5c an IFS holding a newline survives',
     ['IFS=$(echo; echo .)', 'IFS=${IFS%.}', 'V=$(cat k3)',
      '(echo $V)', '(echo "$V")', 'unset IFS V'], None),
    ('N5d "$V" is unaffected, $V follows the inherited IFS',
     ['IFS=:', 'V=$(echo a:b; echo c)', '(echo "$V")', '(echo $V)',
      'unset IFS V'], None),
    # ---- N6. exported: envp, not the pipe --------------------------
    ('N6 an exported variable',
     ['EV=$(cat k3)', 'export EV', '(echo "$EV")', '(echo $EV)',
      'W=$(echo "$EV")', 'echo "$W"', 'unset EV W'], None),
    # ---- N7. the ring budget ---------------------------------------
    ('N7a ( ) accepted at 249',
     n7(11, '(echo ran)', 'echo S$?'), ['ran', 'S0']),
    ('N7b $( ) accepted at 249',
     n7(11, 'echo a$(echo ran)b'), ['aranb']),
    ('N7c ( ) refused at 250, atomically',
     n7(12, '(echo ran)', 'echo S$?'), [REFUSED, 'S1']),
    ('N7d $( ) refused at 250, atomically',
     n7(12, 'echo a$(echo ran)b', 'echo S$?'),
     [REFUSED, 'ab', 'S0']),
    # ---- N8. nested pipelines in the body --------------------------
    ('N8 $(cat F | cat) equals $V',
     ['V=$(cat k3)', 'W=$(cat k3 | cat)', '[ "$V" = "$W" ] && echo same',
      'echo "$W"', 'unset V W'], None),
    # No POSIX twin: dash runs it.  CHCK_GROUP refuses NCMD != 1, loudly.
    ('N8b a group as a pipeline stage is still refused',
     ['(echo hi) | cat', 'echo S$?'], ['sh: (): no redirect|pipe', 'S1']),
]


def run_table(client, tmp, failures, only=None):
    for line in F.FIXTURE + MAUX_FIXTURE:
        F.typed(client, line, 'fixture', failures)
    for label, lines, want in ROWS:
        if only and not label.startswith(only):
            continue
        if want is None:
            want = F.oracle(tmp, lines, failures, label)
        got = []
        for line in lines:
            out = F.typed(client, line, label, failures)
            if out is None:
                got = None
                break
            got.extend(out)
        if got is None:
            continue
        D.assert_eq(label, got, want, failures)


def run(play, failures, only=None):
    tmp = tempfile.mkdtemp(prefix='maux-shnlvar-')
    try:
        boot = os.path.join(tmp, 'play.po')
        shutil.copy(play, boot)
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
            work = os.path.join(tmp, 'host')
            os.mkdir(work)
            run_table(client, work, failures, only)
        finally:
            client.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--play', default=os.path.join(ROOT, 'build',
                                                   'play.po'))
    ap.add_argument('--rows', default=None,
                    help='run only the rows whose label starts with this '
                         '(teeth_shnlvar.py uses N1 / N7)')
    args = ap.parse_args()
    play = os.path.abspath(args.play)
    if not os.path.exists(play):
        print(f'check-shnlvar: {play} missing -- make play-image')
        return 2
    for name, tool in (('dash', F.DASH), ('bash 5+', F.BASH5)):
        if not tool:
            print(f'check-shnlvar: oracle {name} missing on this host')
            return 2
    failures = []
    t0 = time.time()
    try:
        run(play, failures, args.rows)
    except RuntimeError as exc:
        failures.append(str(exc))
    if failures:
        print(f'[check-shnlvar] FAIL: {len(failures)} row(s)')
        for x in failures:
            print(f'  - {x}'.replace('\n', '\n    '))
        return 1
    print(f'[check-shnlvar] PASS: a newline-holding variable survives '
          f'( ) and $( ) ({time.time() - t0:.0f} s)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
