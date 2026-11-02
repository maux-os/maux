#!/usr/bin/env python3
"""check_shprefix.py -- `NAME=value cmd`, `sh -c`, and a script that
`exec 3<` cannot eat (`make check-shprefix`, docs/SH-PREFIX.md,
docs/SH-PREFIX-NOTES.md).

Boots the play image and types each row at the shell, the
check_shfd.py idiom (its helpers are imported).

ORACLE.  A row with want=None is also run, line for line, by the
host's `dash` and by bash 5, in a scratch directory holding the same
files, and maux must print exactly what dash prints (dash and bash 5
must agree with each other first; macOS /bin/sh is bash 3.2 and is
never the oracle).  A row with a WANT list has no POSIX twin -- a
deliberate maux refusal or a limit -- and carries its output.

Rows:
  P  prefix assignments (POSIX 2.9.1; V7 sh(1))
  C  `sh -c STRING [NAME [ARG...]]`
  F  the shell's own script / `.` file / construct redirect is not on
     a descriptor `exec N<F` can reach (SH-FD-NOTES sec 13)

Teeth: scripts/teeth_shprefix.py.

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
import gate_race as GR  # noqa: E402
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# f1/f2 (two lines each), f3 (four words) come from check_shfd; f4
# is the one-line `read` input for the IFS row.
F.FIXTURE.append('echo p:q > f4')

NOTFOUND = 'sh: command not found'

# (label, lines, want) -- want None = ORACLE (dash decides).
ROWS = [
    # ---- P. prefix assignments -----------------------------------
    ('P1 A=1 env lists it; the shell keeps nothing',
     ['ZQA=1 env | grep ^ZQA; echo a${ZQA}b'], None),
    ('P2 an exported name: the child sees new, the shell keeps old',
     ['export ZQA', 'ZQA=old', 'ZQA=new env | grep ^ZQA', 'echo $ZQA',
      'unset ZQA'], None),
    ('P3 two assignments', ['ZQA=1 ZQB=2 env | grep ^ZQ | sort'], None),
    ('P4 assignment words after the command are arguments',
     ['env ZQA=1 | grep ^ZQA', 'ZQA=1 echo ZQB=2'], None),
    ('P5 a lone assignment is a shell assignment',
     ['ZQA=1', 'echo $ZQA', 'unset ZQA'], None),
    ('P6 two lone assignments', ['ZQA=1 ZQB=2', 'echo $ZQA$ZQB',
                                  'unset ZQA ZQB'], None),
    ('P7 the value is expanded',
     ['H=/q', 'ZQA=$H/x env | grep ^ZQA', 'unset H'], None),
    ('P8 each stage takes its own: A in stage 0 only',
     ['ZQA=1 env | ZQB=2 grep ^ZQ'], None),
    ('P8b B in the env stage only, A not',
     ['ZQA=1 echo x | ZQB=2 env | grep ^ZQ'], None),
    # POSIX 2.14: a special builtin's assignments persist.  dash and
    # bash --posix agree (verified by hand); bash 5 in its default mode
    # does not, so these two rows cannot use the two-shell oracle.
    ('P9 a special builtin persists',
     ['ZQA=1 : ; echo a${ZQA}b', 'unset ZQA'], ['a1b']),
    # dash and bash --posix agree (bash 5 default does not): WANT
    ('P9c exec with no command is special: persists',
     ['ZQA=1 exec 3<f1', 'echo a${ZQA}b', 'exec 3<&-', 'unset ZQA'],
     ['a1b']),
    ('P9d exec WITH a command: its environment has it, the shell not',
     ["sh -c 'ZQA=1 exec env' | grep ^ZQA", 'echo a${ZQA}b'], None),
    ('P9b a regular builtin does not', ['ZQA=1 cd .; echo a${ZQA}b'],
     None),
    ('P10 redirection only: the assignment persists, F is made',
     ['ZQA=1 > pf1; echo a${ZQA}b', 'ls pf1', 'unset ZQA'], None),
    ('P10b `: > F` makes F too', [': > pf2', 'ls pf2'], None),
    ('P10c a failing redirect fails the command',
     ['ZQA=1 < nosuch 2>/dev/null; echo S$?', 'echo a${ZQA}b',
      'unset ZQA'], ['sh: cannot redirect', 'S1', 'a1b']),
    ('P11 not found: 127, and the name is gone',
     ['ZQA=1 nosuchcmd', 'echo S$? a${ZQA}b'], [NOTFOUND, 'S127 ab']),
    ('P12 no field splitting of the value',
     ["V='a b'", 'ZQA=$V env | grep ^ZQA', 'unset V'], None),
    ('P12b ... and none for a SECOND assignment word',
     ["V='a b'", 'ZQA=1 ZQB=$V env | grep ^ZQB', 'unset V'], None),
    ('P13 a quoted value', ['ZQA="x y" env | grep ^ZQA'], None),
    ('P14 the same name twice: the last wins, nothing stays',
     ['ZQA=1 ZQA=2 env | grep ^ZQA', 'echo a${ZQA}b'], None),
    ('P15 the command sees the old value in its own words',
     ['ZQA=1 echo a${ZQA}b'], None),
    ('P16 a special builtin: persists, but is not exported',
     ['ZQA=1 export ZQB; echo a${ZQA}b', 'env | grep ^ZQA; echo end',
      'unset ZQA ZQB'], ['a1b', 'end']),
    ('P17 IFS for one read, then the default again',
     ['exec 3<f4', 'IFS=: read A B <&3', 'echo $A-$B', 'exec 3<f3',
      'read C D <&3', 'echo $C-$D', 'exec 3<&-',
      'unset A B C D'], None),
    # SH-ROOM2 step 2b moved PFX_REC and `set` into the $D000
    # segment; the messages they print must still be reachable by a
    # syscall (copyin refuses >= $D000).  No POSIX twin: WANT rows.
    ('P20 nine prefix words: refused, nothing run',
     ['A=1 B=1 C=1 D=1 E=1 F=1 G=1 H=1 I=1 :', 'echo S$?'],
     ['sh: too many assignments', 'S1']),
    ('P20b nine lone assignment words',
     ['A=1 B=1 C=1 D=1 E=1 F=1 G=1 H=1 I=1', 'echo S$?'],
     ['sh: too many assignments', 'S1']),
    ('P21 a 16-character name: refused, nothing run',
     ['ZQ0123456789ABCD=1 :', 'echo S$?'],
     ['sh: variable name too long', 'S1']),
    ('P22 a 32-character value: refused, nothing run',
     ['A=01234567890123456789012345678901 :', 'echo S$?'],
     ['sh: variable value too long', 'S1']),
    ('P22b the same two, as a lone assignment word',
     ['ZQ0123456789ABCD=1', 'echo S$?',
      'ZQA=01234567890123456789012345678901', 'echo S$?'],
     ['sh: variable name too long', 'S1',
      'sh: variable value too long', 'S1']),
    ('S1 `set` with a flag it does not know prints its usage',
     ['set -q', 'echo S$?', 'set', 'echo S$?'],
     ['usage: set -x|+x|-e|+e', 'S1', 'usage: set -x|+x|-e|+e', 'S1']),
    # ---- C. sh -c -------------------------------------------------
    ('C1 $0 and $1', ["sh -c 'echo $0 $1' x y"], None),
    ('C2 exit status', ["sh -c 'exit 3'", 'echo S$?'], None),
    ('C3 an assignment inside', ["sh -c 'A=1; echo $A'"], None),
    ('C4 a list, a pipe and $#',
     ["sh -c 'echo a;echo b|cat;echo $#' q r"], None),
    ('C5 false', ["sh -c false", 'echo S$?'], None),
    ('C6 the string reads the caller\'s stdin',
     ['echo hi | sh -c cat'], None),
    ('C7 a compound command in the string',
     ["sh -c 'if true; then echo y; fi'",
      "sh -c 'for i in 1 2; do echo $i; done'"], None),
    ('C8 two args', ["sh -c 'echo $1$2' n a b"], None),
    ('C9 no string: usage, status 2',
     ['sh -c', 'echo S$?'], ['sh: -c: option requires an argument',
                             'S2']),
    # ---- F. the shell's own descriptors ------------------------------
    ('F1 a script survives exec 3<f1',
     ["echo 'exec 3<f1' > c4", "echo 'read V <&3' >> c4",
      "echo 'echo got $V' >> c4", "echo 'echo after' >> c4",
      'sh ./c4'], None),
    ('F2 a `.` file survives it too',
     ["echo '. ./c4' > c5", 'sh ./c5'], None),
    ('F3 a while ... done <f2 frame survives it',
     ["echo 'while read V; do' > c6", "echo 'exec 3<f1' >> c6",
      "echo 'read W <&3' >> c6", "echo 'echo $V$W' >> c6",
      "echo 'done <f2' >> c6", 'sh ./c6'], None),
    ('F3b a typed loop (the spool file) survives it',
     ['for i in a b;do exec 3<f1;echo $i;done', 'exec 3<&-',
      'unset i'], None),
    ('F4 exec onto the script\'s own fd is refused (loud)',
     ["echo 'exec 7<f1' > c7", "echo 'echo after' >> c7", 'sh ./c7'],
     ['sh: exec: cannot redirect', 'after']),
]

#: rows that need more than typing lines (ctrl-C, an oversize
#: environment); run after the table
SPECIAL = ['P18 ^C during A=1 cat leaves nothing',
           'P19 a prefix the table has no room for']


def run_table(client, tmp, failures):
    for line in F.FIXTURE:
        F.typed(client, line, 'fixture', failures)
    for label, lines, want in ROWS:
        if want is None:
            want = F.oracle(tmp, lines, failures, label)
        got = []
        for line in lines:
            out = F.typed(client, line, label, failures)
            if out is None:
                got = None
                break
            got.extend(out)
        for line in ('exec 3<&-', 'exec 4<&-'):
            F.typed(client, line, label + ' cleanup', [])
        if got is None:
            continue
        D.assert_eq(label, got, want, failures)


def pcb_states(client):
    """State byte of every pid 0-11 (annex bank 0, 16 bytes a pid, +1
    state: mm.annex2.equ); 1 RUNNABLE, 2 RUNNING, 3 BLOCKED."""
    r = client.call_tool('peek', {'addr': 0x0800, 'count': 12 * 16,
                                  'bank': 'aux', 'aux_bank': 0})
    d = r.get('bytes') or r.get('data')
    return [d[p * 16 + 1] for p in range(12)]


def row_ctrl_c(client, failures):
    """^C during `ZQA=1 cat`.  The fixture is `cat` BLOCKED on its tty
    read, so the harness waits for that property in the PCB table (a
    new pid, in state BLOCKED) and not for a duration
    (docs/GATE-PREDICATES.md): under MAUX_GATE_RACE=early the ^C must
    still land on a cat that is already reading."""
    label = SPECIAL[0]
    before = {p for p, st in enumerate(pcb_states(client))
              if st in (1, 2, 3)}
    client.call_tool('type', {'text': 'ZQA=1 cat\r'})
    for _ in GR.polls(client, 400):
        now = pcb_states(client)
        if any(p not in before and st == 3
               for p, st in enumerate(now)):
            break
    else:
        failures.append(f'{label}: cat never blocked on its read')
        return
    client.call_tool('type', {'text': '\x03'})
    try:
        D.wait_for_screen(client, D.prompt_ready, label, max_steps=600)
    except RuntimeError as exc:
        failures.append(f'{label}: the shell never came back: {exc}')
        return
    out = F.typed(client, 'echo a${ZQA}b', label, failures)
    D.assert_eq(label, out, ['ab'], failures)


def row_tablefull(client, failures):
    """A prefix that needs more slots than the 8-slot variable table
    has free: the shell says so, the command does not run, the
    prefix already applied is put back, and the shell is fine.

    The brief also asked for an envp that overflows the kernel's
    argv+envp region.  It cannot be produced: ARG_MAX is 1,280 B of
    packed strings (the 255 B is the POINTER array), the shell's own
    environment is at most 8 x 48 = 384 B and a line is at most 255
    bytes, so ERR_2BIG is out of reach of a prefix (SH-PREFIX-NOTES
    sec 6)."""
    label = SPECIAL[1]
    F.typed(client, 'V1=1 V2=2 V3=3 V4=4 V5=5 V6=6 V7=7', label,
            failures)
    out = F.typed(client, 'X1=1 X2=2 env', label, failures)
    out2 = F.typed(client, 'echo S$? a${X1}b', label, failures)
    F.typed(client, 'X1=1', label, failures)
    out3 = F.typed(client, 'echo x$X1', label, failures)
    F.typed(client, 'unset V1 V2 V3 V4 V5 V6 V7 X1', label, [])
    if None in (out, out2, out3):
        return
    D.assert_eq(label + ' (a diagnostic, nothing run)', out,
                ['sh: variable table full'], failures)
    D.assert_eq(label + ' (status 1, prefix put back)', out2,
                ['S1 ab'], failures)
    D.assert_eq(label + ' (the shell is fine)', out3, ['x1'], failures)


def run(play, failures):
    tmp = tempfile.mkdtemp(prefix='maux-shprefix-')
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
            run_table(client, work, failures)
            row_ctrl_c(client, failures)
            row_tablefull(client, failures)
        finally:
            client.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--play', default=os.path.join(ROOT, 'build',
                                                   'play.po'))
    args = ap.parse_args()
    play = os.path.abspath(args.play)
    if not os.path.exists(play):
        print(f'check-shprefix: {play} missing -- make play-image')
        return 2
    for name, tool in (('dash', F.DASH), ('bash 5+', F.BASH5)):
        if not tool:
            print(f'check-shprefix: oracle {name} missing on this host')
            return 2
    failures = []
    t0 = time.time()
    try:
        run(play, failures)
    except RuntimeError as exc:
        failures.append(str(exc))
    if failures:
        print(f'[check-shprefix] FAIL: {len(failures)} row(s)')
        for x in failures:
            print(f'  - {x}'.replace('\n', '\n    '))
        return 1
    print(f'[check-shprefix] PASS: prefix assignments, sh -c and the '
          f'shell\'s own descriptors ({time.time() - t0:.0f} s)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
