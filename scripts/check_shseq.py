#!/usr/bin/env python3
"""check_shseq.py -- warm `sh -c` loops, one-line `case`, and the rest of
the line after `.` (`make check-shseq`, docs/SH-SEQ.md,
docs/SH-SEQ-NOTES.md).

One emulator session, the check_shexecloop idiom (its helpers are
imported).  The play image is booted at the 40-column glass and every
row is TYPED at the console shell: a row's script files are written with
typed `echo`, then its `cmds` are typed one line each and the answer is
what the glass printed (so the console path -- a typed line, the line
editor, the prompt -- is part of what runs; check_shfd runs host rows
as scripts only).  A row with files runs them with `sh ./m`; a row
without is the typed line itself.

ORACLES.  A row with want=None is also run, line for line, by the
host's dash AND bash 5 (macOS /bin/sh is bash 3.2 and is never the
oracle), each in an EMPTY directory holding only the row's files, and
`sh ./m` in a row runs the script under THAT shell (SH-G21 F4: it used
to run dash under both; rig_selftest keeps it honest); maux
must print what they print, and a RIG line is raised if the two host
shells disagree first.  A row with a WANT list is SEMANTIC: a
diagnostic's wording differs between dash, bash and maux, so the row
carries what maux must print and its notes say which shell it follows.

PER-ROW TIMEOUT.  Every typed line is bounded (check_shfd.typed: 700
polls, then ^D/^D/^C) and the failure names the ROW and the line, so a
hang is a named red and never a stalled sweep.

POST CHECKS.  A row may carry `post=(cmds, fn)`: more typed lines whose
output goes to fn(outs) -> an error string or None (the warm rows use it
to prove the second spawn REUSED the first one's bank: pid == bank, so
the two `$$` files must be equal).

COUNTERS.  Before and after each row the kernel's buffer cells are read
(K_IBF_INUSE, K_QUAR_CNT, MLI_BUF_USED, used OFT entries): a row that
leaves a file open or a buffer leaked is red by name.

ROW ORDER MATTERS in phase A: A1 is the COLD control and must be the
first nested sh of the boot.

Teeth: scripts/teeth_shseq.py.  ASCII only.  Exit 0 green, 1 red
(listed), 2 rig problem.
"""
import argparse
import os
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_shfd as F  # noqa: E402
import check_devfs as D  # noqa: E402
import check_shmlquote as M  # noqa: E402
import check_shexecloop as X  # noqa: E402
import e2e_term as E  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
END = 'echo END'
STATUS = 'echo S$?'


def row(label, cmds, files=None, want=None, post=None):
    """label; cmds = typed lines; files = name -> script lines (written
    first, typed); want None = the host oracle; post = (cmds, fn)."""
    return {'label': label, 'cmds': list(cmds),
            'files': {k: list(v) for k, v in (files or {}).items()},
            'want': want, 'post': post}


def same_pid(outs):
    """post check: `cat B` then `cat C` printed the same pid."""
    flat = [r for r in M.norm(outs)]
    if len(flat) != 2 or not flat[0].isdigit():
        return f'expected two pids from cat B / cat C, got {flat!r}'
    if flat[0] != flat[1]:
        return (f'the -c shell ran in bank {flat[1]}, the primer in '
                f'{flat[0]}: the second spawn did NOT reuse the first '
                f"one's bank, so the row proves nothing")
    return None


#: the primer: a SEEKABLE script that ends with LMARK_OK = 1 (every
#: script file read through CAP_LINE_MARK does) and records its bank.
PRIMER = ['echo $$>B', 'for i in p q;do echo $i;done']
WARM = (['cat B', 'cat C'], same_pid)

# ---- phase A: sh -c on a reused bank ---------------------------------
ROWS_A = [
    # the cold control MUST come first (see the module docstring)
    row('A1 cold control: sh -c loop on a fresh bank',
        ["sh -c 'for i in a b;do echo $i;done'", STATUS]),
    row('A2 warm: for loop in sh -c after a seekable script (same bank)',
        ['sh ./m', STATUS],
        files={'P': PRIMER,
               'm': ['sh ./P',
                     "sh -c 'echo $$>C;for i in a b;do echo $i;done'",
                     END]},
        post=WARM),
    row('A3 warm, typed: primer then the loop, adjacent console lines',
        ['sh ./P', "sh -c 'for i in c d;do echo $i;done'", STATUS],
        files={'P': PRIMER}),
    row('A4 warm: while loop in sh -c',
        ['sh ./m', STATUS],
        files={'P': PRIMER,
               'm': ['sh ./P',
                     "sh -c 'echo $$>C;I=;while test \"$I\" != xx;do "
                     "echo L$I;I=${I}x;done'", END]},
        post=WARM),
    row('A5 warm: until loop in sh -c',
        ['sh ./m', STATUS],
        files={'P': PRIMER,
               'm': ['sh ./P',
                     "sh -c 'echo $$>C;I=;until test \"$I\" = xx;do "
                     "echo U$I;I=${I}x;done'", END]},
        post=WARM),
    row('A6 warm: nested loops and break in sh -c',
        ['sh ./m', STATUS],
        files={'P': PRIMER,
               'm': ['sh ./P',
                     "sh -c 'echo $$>C;for i in a b c;do for j in 1 2;"
                     "do echo $i$j;done;break;done'", END]},
        post=WARM),
    row('A7 warm: exit from inside an sh -c loop keeps its status',
        ['sh ./m', STATUS],
        files={'P': PRIMER,
               'm': ['sh ./P',
                     "sh -c 'echo $$>C;for i in a b c;do echo $i;"
                     "test $i = b&&exit 3;done'", 'echo T$?', END]},
        post=WARM),
    row('A8 the reverse order: sh -c first, then a script loop',
        ['sh ./m', STATUS],
        files={'P': PRIMER,
               'm': ["sh -c 'echo $$>C'", 'sh ./P', END]}),
    # an unfinished loop in -c is a syntax error: it must never read
    # the caller's stdin (D holds a line that would become the body).
    # dash and bash 5 both exit 2 and run nothing; maux follows them
    # (status 2, nothing run) with its own wording.
    row('A9 an unfinished loop in sh -c is refused, stdin untouched',
        ["sh -c 'for i in a b;do echo $i' < D", STATUS],
        files={'D': ['echo STOLEN', 'done']},
        want=['sh: EOF with a construct still open', 'S2']),
]



def srow(label, lines, want=None):
    """A script row: `lines` + END written to ./m, run with `sh ./m`."""
    return row(label, ['sh ./m', STATUS], files={'m': list(lines) + [END]},
               want=want)


# ---- phase B: the one-line `case` ------------------------------------
ROWS_B = [
    # ---- typed at the prompt (the console path) ----------------------
    row('B1 typed: first pattern matches, esac on the line',
        ['case x in x) echo hit;; esac', 'echo after']),
    row('B2 typed: no match, the shell carries on',
        ['case x in y) echo no;; esac', 'echo after']),
    row('B3 typed: first pattern misses, second hits',
        ['case x in y) :;; x) echo h2;; esac', 'echo after']),
    row('B4 typed: two commands in the branch',
        ['case x in x) echo a; echo b;; esac', 'echo after']),
    row('B5 typed: a pipeline in the branch',
        ['case x in x) echo p | cat;; esac']),
    row('B6 typed: alternation and star',
        ['case x in a|x) echo alt;; esac',
         'case q in *) echo star;; esac']),
    row('B7 typed: variable word and glob pattern',
        ['V=abc', 'case $V in a*) echo m$V;; esac']),
    row('B8 typed: last clause without ;;',
        ['case x in x) echo hit; esac', 'echo after']),
    row('B9 typed: status 0 when no pattern matched',
        ['false; case x in y) :;; esac; echo $?']),
    row('B10 typed: status 0 for a matched empty clause',
        ['false; case x in x) :;; esac; echo $?']),
    row('B11 typed: the branch sees the old $?',
        ['false; case x in x) echo $?;; esac']),
    row('B12 typed: the last command status stands',
        ['case x in x) false;; esac; echo $?']),
    row('B12b typed: a head skipped by && never matches',
        ['false && case x in x) echo no;; esac', 'echo S$?']),
    row('B12c typed: a skipped case leaves $? alone',
        ['false && case x in y) :;; esac', 'echo S$?']),
    row('B14 typed: sh -c and eval take the one-line case',
        ["sh -c 'case x in x) echo hit;; esac'",
         "eval 'case x in x) echo ev;; esac'"]),
    # the terminator redirect: a SEEKABLE script applies it (check_shfd
    # C10); a typed construct cannot be rescanned, so the body runs and
    # the redirect is then refused, loudly (same as check_shfd D6).
    # KNOWN GAP PIN, trigger: typed constructs gain a rescan.
    row('B13 typed esac <&3: body runs, redirect refused (known gap)',
        ['echo L1 > f1', 'exec 3<f1', 'case x in x) echo hi;; esac <&3',
         STATUS, 'exec 3<&-'],
        files={}, want=['hi', 'sh: redirection without a command', 'S1']),
    # ---- scripts -----------------------------------------------------
    srow('B20 script: the same one-line forms, one after another',
         ['case x in x) echo hit;; esac', 'echo after',
          'case x in y) echo no;; esac', 'echo after2',
          'case x in y) :;; x) echo h2;; esac',
          'case x in x) echo a; echo b;; esac',
          'case x in x) echo p | cat;; esac',
          'case x in x) echo q > o1;; esac', 'cat o1']),
    srow('B21 script: nested one-line cases',
         ['case x in x) case y in y) echo in;; esac;; esac',
          'case x in x) case y in z) echo no;; esac; echo out;; esac']),
    srow('B21b script: nested one-line cases, not the first segment',
         ['echo a; case x in x) case y in y) echo in;; esac;; esac',
          'echo b; case x in x) case y in z) echo no;; esac; echo out;; '
          'esac']),
    srow('B22 script: not the first segment of its line',
         ['echo a; case x in x) echo b;; esac; echo c']),
    srow('B23 script: inside an if and a loop body',
         ['if true; then',
          'case x in x) echo inif;; esac',
          'fi',
          # "$i": an unquoted EMPTY expansion right after THEN/DO is a
          # syntax error in the construct's scan pass (sibling, see the
          # notes; identical on the phase-A binary)
          'for i in 1 2; do case "$i" in 1) echo one;; 2) echo two;; '
          'esac; done']),
    srow('B24 script: multi-line control, same answers',
         ['case x in', 'x) echo multi;;', 'esac', 'echo after']),
    srow('B25 script: a head after && or || is dead or live by status',
         ['true && case x in x) echo live;; esac',
          'false || case x in x) echo live2;; esac',
          'false && case x in x) echo dead;; esac',
          'true || case x in x) echo dead2;; esac',
          # a command in a LATER segment of the dead branch: only the
          # dead mark (SH_SKIP is reset by the `;`) keeps it from running
          'false && case x in x) :; echo dead3;; esac',
          'true || case x in x) :; echo dead4;; esac']),
    srow('B26 script: statuses (no match, empty clause, last command)',
         ['false; case x in x) false;; esac; echo 1:$?',
          'true; case x in x) false;; esac; echo 2:$?',
          'false; case x in x) true;; esac; echo 3:$?',
          'false; case x in x) ;; esac; echo 4:$?',
          'false; case x in y) :;; esac; echo 5:$?',
          'false && case x in y) :;; esac; echo 6:$?',
          'false; case x in x) case y in y) ;; esac;; esac; echo 7:$?',
          'false; case x in x) false; case y in y) ;; esac;; esac; '
          'echo 8:$?',
          'true; case x in x) case y in y) false;; esac;; esac; echo 9:$?',
          'false; case x in y) :;; x) ;; esac; echo 10:$?']),
    srow('B27 script: the same statuses, multi-line (control)',
         ['false', 'case x in', 'x)', ';;', 'esac', 'echo 1:$?',
          'false', 'case x in', 'x) echo i$?', ';;', 'esac', 'echo 2:$?',
          'true', 'case x in', 'x) false', ';;', 'esac', 'echo 3:$?']),
    srow('B28 script: the case word is expanded',
         ['V=abc', 'case $V in a*) echo m$V;; esac',
          'case "$V" in abc) echo q;; esac']),
    # ---- set -e (C-M2) ----------------------------------------------
    srow('E1 set -e: a failing command in the branch ends the script',
         ['set -e', 'case x in x) false;; esac', 'echo after']),
    srow('E2 set -e: no match is status 0, the script goes on',
         ['set -e', 'case x in y) false;; esac', 'echo after']),
    srow('E3 set -e: an empty matched clause is status 0',
         ['set -e', 'case x in x) ;; esac', 'echo after']),
    srow('E4 set -e: no match as the left of ||, status 0',
         ['set -e', 'case x in y) :;; esac || echo no', 'echo after']),
    srow('E5 set -e: a passing branch before ||',
         ['set -e', 'case x in x) true;; esac || echo no', 'echo after']),
    # KNOWN GAP PIN (not the case's own): set -e looks only at the
    # failing command's separator and the top frame's CONDITION, so a
    # compound that is the LEFT of &&/|| does not suppress it. dash and
    # bash 5 print `no`, `after`; maux ends the script, status 1.
    # Same for `if true; then false; fi || echo no` and the multi-line
    # case. Trigger: errexit learns the tested context of a compound.
    srow('E6 set -e: case LHS of || (known gap, pinned)',
         ['set -e', 'case x in x) false;; esac || echo no', 'echo after'],
         want=['S1']),
]



def srowf(label, lines, files=None, want=None, cmds=None, post=None):
    """A script row with fixture files: `lines` + END is ./m."""
    f = {'m': list(lines) + [END]}
    f.update(files or {})
    return row(label, cmds or ['sh ./m', STATUS], files=f, want=want,
               post=post)


# the sourced files the C rows share (one fixture set, rewritten per
# row; a row's own files win)
XH = {'Xh': ['echo hi']}
XF = {'Xf': ['echo X1', 'false']}
XT = {'Xt': ['echo X1', 'true']}
XE = {'Xe': ['false', 'echo notreached']}
XIF = {'Xif': ['if true; then', 'echo inside']}
MSG_EOF = 'sh: EOF with a construct still open'
MSG_UNEXP = 'sh: unexpected then/elif/else/fi/do/done'


def J(msg, nxt):
    """The 40-column glass wraps a 40-character message and the
    harness's unwrap() joins it with the next row."""
    return msg + nxt


MSG_NOLOOP = 'sh: break/continue: not in a loop'

# ---- phase C: `. FILE; cmd` -------------------------------------------
ROWS_C = [
    # ---- the rest of the line (D1, C-H2) ------------------------------
    row('C1 typed: echo S; . ./Xh; echo after',
        ['echo S; . ./Xh; echo after'], files=XH),
    row('C2 typed: . X && ok || no, X ending false',
        ['. ./Xf && echo ok || echo no'], files=XF),
    row('C2b typed: . X && ok || no, X ending true',
        ['. ./Xt && echo ok || echo no'], files=XT),
    row('C2c H1: false X must not run the && branch',
        ['. ./Xf && echo WRONG || echo right'], files=XF),
    row('C2d typed: . X || recover, X ending false',
        ['. ./Xf || echo recover'], files=XF),
    srowf('C3 nested: both lines continue',
          ['. ./X1; echo c'],
          files={'X1': ['echo x1; . ./Y1; echo x2'],
                 'Y1': ['echo y']}),
    srowf('C4 four sourcings deep, each with a remainder',
          ['. ./L1; echo end'],
          files={'L1': ['. ./L2; echo l1'], 'L2': ['. ./L3; echo l2'],
                 'L3': ['. ./L4; echo l3'], 'L4': ['echo l4']}),
    # the fifth `.` is refused by the OPEN (a process has eight fds:
    # m, four sourced files and the shell's own), before the depth
    # test the message `too many nested sources` belongs to
    srowf('C4b the fifth is refused, the line goes on (semantic)',
          ['. ./L1; echo end'],
          files={'L1': ['. ./L2; echo l1'], 'L2': ['. ./L3; echo l2'],
                 'L3': ['. ./L4; echo l3'], 'L4': ['. ./L5; echo l4'],
                 'L5': ['echo l5']},
          want=['sh: .: cannot open file', 'l4', 'l3', 'l2', 'l1',
                'end', 'END', 'S0']),
    srowf('C6 a case branch whose command is `.` (the ;; effect)',
          ['case x in', 'x) . ./Xh ;;', 'y) echo WRONG ;;', 'esac',
           'echo end'], files=XH),
    srowf('C6b the same on one line',
          ['case x in x) . ./Xh;; y) echo WRONG;; esac', 'echo end'],
          files=XH),
    srowf('C6c a case branch with .  and a command after it',
          ['case x in x) . ./Xh; echo b;; y) echo W;; esac'], files=XH),
    # ---- the EOF leak and its policy (C-H3, H3, M2) --------------------
    # bash: one diagnostic, `.` is 2, the caller carries on. dash exits.
    # maux follows bash (docs/SH-SEQ-NOTES.md sec 5.4).
    srowf('C5 unterminated if in X: message once, $? 2, caller goes on',
          ['. ./Xif', 'echo after:$?', 'echo more'], files=XIF,
          want=[MSG_EOF, 'after:2', 'more', 'END', 'S0']),
    srowf('C5b unterminated for in X',
          ['. ./Xfor', 'echo after:$?', 'echo more'],
          files={'Xfor': ['for i in a b; do', 'echo L$i']},
          want=[MSG_EOF, 'after:2', 'more', 'END', 'S0']),
    srowf('C5c unterminated case in X',
          ['. ./Xcase', 'echo after:$?', 'echo more'],
          files={'Xcase': ['case x in', 'x) echo c', ';;']},
          want=[MSG_EOF, 'after:2', 'more', 'END', 'S0']),
    srowf('C5d two frames left open: both closed, none leaks',
          ['. ./Xnest', 'if true; then', 'echo callerif', 'fi',
           'echo more'],
          files={'Xnest': ['if true; then', 'for i in a; do']},
          want=[MSG_EOF, 'callerif', 'more', 'END', 'S0']),
    srowf('C5e the remainder of the line runs after an unwound X',
          ['. ./Xif; echo rest:$?'], files=XIF,
          want=[MSG_EOF, 'rest:2', 'END', 'S0']),
    srowf('C5f unwound X is 2 for && and ||',
          ['. ./Xif && echo ok || echo no'], files=XIF,
          want=[MSG_EOF, 'no', 'END', 'S0']),
    # ---- the construct floor (H2): X cannot close the caller's frames -
    srowf('F1 X = fi inside a caller if: refused, the caller closes it',
          ['if true; then', '. ./Xfi', 'echo inside', 'fi', 'echo end'],
          files={'Xfi': ['fi']},
          want=[J(MSG_UNEXP, 'inside'), 'end', 'END', 'S0']),
    srowf('F2 X = done inside a caller while: refused each time',
          ['I=', 'while test "$I" != xx', 'do', '. ./Xdone', 'I=${I}x',
           'echo L$I', 'done', 'echo end'],
          files={'Xdone': ['done']},
          want=[J(MSG_UNEXP, 'Lx'), J(MSG_UNEXP, 'Lxx'), 'end', 'END',
                'S0']),
    srowf('F3 X = continue inside a caller while: refused, not acted on',
          ['I=', 'while test "$I" != xx', 'do', 'I=${I}x',
           '. ./Xcont', 'echo L$I', 'done', 'echo end'],
          files={'Xcont': ['continue']},
          want=[MSG_NOLOOP, 'Lx', MSG_NOLOOP, 'Lxx', 'end', 'END', 'S0']),
    srowf('F4 X = break inside a caller while: refused, not acted on',
          ['I=', 'while test "$I" != xx', 'do', 'I=${I}x',
           '. ./Xbrk', 'echo L$I', 'done', 'echo end'],
          files={'Xbrk': ['break']},
          want=[MSG_NOLOOP, 'Lx', MSG_NOLOOP, 'Lxx', 'end', 'END', 'S0']),
    srowf('F5 X = esac inside a caller case branch',
          ['case x in', 'x) . ./Xesac', 'echo inb', ';;', 'esac',
           'echo end'], files={'Xesac': ['esac']},
          want=[J(MSG_UNEXP, 'inb'), 'end', 'END', 'S0']),
    srowf('F6 X = ;; inside a caller case branch',
          ['case x in', 'x) . ./Xds', 'echo inb', ';;', 'esac',
           'echo end'], files={'Xds': [';;']},
          want=[J(MSG_UNEXP, 'inb'), 'end', 'END', 'S0']),
    srowf('F7 X with its own loop, break and if is untouched',
          ['for i in 1 2; do . ./Xown; done', 'echo end'],
          files={'Xown': ['for j in a b c; do', 'if test $j = b; then',
                          'break', 'fi', 'echo $j', 'done']}),
    # ---- set -e (C-M2, H3, H4) -----------------------------------------
    srowf('E10 untested: a failing command in X ends the script',
          ['set -e', '. ./Xe', 'echo WRONG'], files=XE),
    srowf('E11 tested ||: X runs on, the || branch runs (bash)',
          ['set -e', '. ./Xe || echo recovered', 'echo after'],
          files=XE, want=['notreached', 'after', 'END', 'S0']),
    srowf('E12 tested if: X runs on, the then branch runs (bash)',
          ['set -e', 'if . ./Xe; then echo T; else echo F; fi',
           'echo after'], files=XE,
          want=['notreached', 'T', 'after', 'END', 'S0']),
    srowf('E13 tested &&: X runs on (bash)',
          ['set -e', '. ./Xe && echo ok', 'echo after'], files=XE,
          want=['notreached', 'ok', 'after', 'END', 'S0']),
    srowf('E14 a nested . inside a tested . inherits the suppression',
          ['set -e', '. ./Xo || echo r', 'echo after'],
          files={'Xo': ['. ./Xe', 'echo y2'], 'Xe': ['false',
                                                      'echo notreached']},
          want=['notreached', 'y2', 'after', 'END', 'S0']),
    srowf('E15 after a tested . returns, set -e fires again',
          ['set -e', '. ./Xt || echo r', 'false', 'echo WRONG'],
          files=XT),
    srowf('E16 H3: set -e, X unterminated: the unwound 2 ends the script',
          ['set -e', '. ./Xif', 'echo WRONG'], files=XIF,
          want=[MSG_EOF, 'S2']),
    srowf('E17 H3: tested, an unwound X is a failure the || sees',
          ['set -e', '. ./Xif || echo r', 'echo after'], files=XIF,
          want=[MSG_EOF, 'r', 'after', 'END', 'S0']),
    # KNOWN GAP PIN (H4): a `.` inside a compound that is ITSELF the
    # left of || is the E6 general compound gap. bash prints
    # notreached, recovered, after; maux ends the script, status 1.
    # Trigger: errexit learns the tested context of a compound.
    srowf('E18 { . ./Xe; false; } || recover (known gap, pinned)',
          ['set -e', '{ . ./Xe; false; } || echo recovered',
           'echo after'], files=XE, want=['S1']),
    # ---- M1: a successful . starts at 0 ---------------------------------
    row('M1 an empty file is status 0 (false; . EMPTY && OK)',
        [': > EMPTY', 'false; . ./EMPTY && echo OK']),
    # ---- here-docs (C-M3, M4) -------------------------------------------
    srowf('H1 the body of a here-doc after . comes from the caller',
          ['. ./Xh; cat <<E', 'body1', 'body2', 'E', 'echo end'],
          files=XH),
    srowf('H2 a here-doc inside X reads X',
          ['. ./Xhd; echo end'],
          files={'Xhd': ['cat <<E', 'inx', 'E', 'echo xdone']}),
    srowf('H3 a here-doc before the . on the same line',
          ['cat <<E; . ./Xh; echo after', 'pre', 'E'], files=XH),
    # M4: a string source holds no body. dash and bash read none either
    # (the heredoc is empty); maux refuses it loudly and NEVER takes the
    # caller's stdin or lines.
    row('M4 sh -c . X; cat <<E: stdin is not the body',
        ["sh -c '. ./Xh; cat <<E' < D", STATUS],
        files={'Xh': ['echo hi'], 'D': ['STOLEN', 'E']},
        want=['hi', 'sh: here-doc: EOF before terminator', 'S1']),
    srowf('M4b eval cat <<E does not take the caller lines',
          ["eval 'cat <<E'", 'echo NOTBODY'],
          want=['sh: here-doc: EOF before terminator', 'NOTBODY', 'END',
                'S0']),
    # ---- traps and history (C-M4) ----------------------------------------
    srowf('T1 a signal trapped while X runs; the remainder runs once',
          ['trap "echo T" 15', '. ./Xk; echo after'],
          files={'Xk': ['kill -15 $$', 'echo inx']},
          want=['T', 'inx', 'after', 'END', 'S0']),
    # ---- sh -c and a warm bank (C-M5) -------------------------------------
    row('S1 typed: sh -c . X; echo after',
        ["sh -c '. ./Xh; echo after'"], files=XH),
    srowf('S2 warm: sh -c . X; echo after on a reused bank',
          ["sh ./P", "sh -c 'echo $$>C;. ./Xh; echo after'"],
          files={'P': PRIMER, 'Xh': ['echo hi']}, post=WARM),
    row('S3 sh -c: an unfinished loop in the remainder never reads stdin',
        ["sh -c '. ./H;for i in a;do echo $i'<D", STATUS],
        files={'H': ['echo hi'], 'D': ['echo STOLEN', 'done']},
        want=['hi', MSG_EOF, 'S2']),
    # ---- aliases, joined lines, && and || before the . (C-M6, M3) ---------
    srowf('A1 alias before the .: the remainder is not expanded twice',
          ["alias echo='echo pre'", '. ./Xh; echo x'], files=XH,
          want=['pre hi', 'pre x', 'pre END', 'S0']),
    srowf('A2 alias dot=. then a remainder',
          ['alias dot=.', 'dot ./Xh; echo after'], files=XH,
          want=['hi', 'after', 'END', 'S0']),
    srowf('A3 M3: aliased line + a loop in the remainder is refused',
          ['alias e="echo A"', 'e; . ./Xh; for i in a b; do echo $i; done'],
          files=XH,
          want=['A', 'hi', J('sh: alias before a loop head on one line',
                             'END'), 'S0']),
    srowf('A4 no alias: a loop in the remainder runs (control for A3)',
          ['. ./Xh; for i in a b; do echo $i; done'], files=XH),
    srowf('A5 a joined logical line: a quote spanning two lines',
          [". ./Xh; echo 'two", "lines'", 'echo end'], files=XH),
    srowf('A6 a backslash-continued line',
          ['. ./Xh; echo a\\', 'b'], files=XH),
    srowf('A7 && and || before the .',
          ['true && . ./Xh; echo a1', 'false || . ./Xh; echo a2',
           'false && . ./Xh; echo a3', 'true || . ./Xh; echo a4'],
          files=XH),
    # ---- loops around a . --------------------------------------------------
    srowf('L1 a . in a one-line for body',
          ['for i in 1 2; do . ./Xh; echo $i; done', 'echo end'],
          files=XH),
    srowf('L4 a multi-line loop OPENED in the remainder (it must spool)',
          ['. ./Xh; for i in a b', 'do echo $i', 'done', 'echo end'],
          files=XH),
    # the stale seek mark X's last read left (X's length) must not be
    # used: it points past this caller's first line, into the next
    srowf('L5 a ONE-line loop in the remainder after a long X (spools)',
          ['. ./Xlong; for i in a b; do echo $i; done', 'echo mid',
           'echo end'],
          files={'Xlong': ['# padding padding padding padding padding',
                           '# padding padding padding padding padding',
                           'echo hi']}),
    srowf('L2 a . in a multi-line while body with a remainder',
          ['I=', 'while test "$I" != xx', 'do', '. ./Xh; echo L$I',
           'I=${I}x', 'done', 'echo end'], files=XH),
    srowf('L3 70 sourcings in one run (the SH-FD stack class)',
          ['for a in 1 2 3 4 5 6 7 8; do',
           'for b in 1 2 3 4 5 6 7 8 9; do . ./Xq; done',
           'done', 'echo end'], files={'Xq': [':']}),
    # ---- review of C -------------------------------------------------
    # M1: a nested case in a clause that did not match must not touch
    # the outer case's "no command ran" flag (the outer clause that DID
    # match ran `false`, so the case is 1).
    srowf('N1 a nested case in a skipped clause leaves the status alone',
          ['case x in', 'x) false;;', 'y) case z in z) ;; esac;;', 'esac',
           'echo $?']),
    srowf('N2 ...and the && / || after it sees that 1',
          ['case x in', 'x) false;;', 'y) case z in z) ;; esac;;',
           'esac && echo WRONG || echo right']),
    srowf('N3 the same on one line',
          ['case x in x) false;; y) case z in z) ;; esac;; esac; echo $?']),
    # M2: errexit leaves for the prompt (typed) or the EXIT trap; the
    # NEXT line must still get its alias pass.
    row('N4 typed: errexit after an unwound X, then an alias line',
        ['alias e=echo', 'set -e', '. ./Xif; echo NEVER', 'e AFTER',
         'set +e', 'unalias e'], files=XIF,
        want=[MSG_EOF, 'AFTER']),
    srowf('N5 the EXIT trap string still gets its alias pass',
          ['alias e=echo', 'trap "e EXIT" 0', 'set -e',
           '. ./Xif; echo NEVER'], files=XIF,
          want=[MSG_EOF, 'EXIT', 'S2']),
    # ---- exit, and the interaction set (after C) ---------------------------
    srowf('X1 exit in X ends the shell; the remainder must not run',
          ['. ./Xx; echo WRONG'], files={'Xx': ['echo bye', 'exit 3']}),
    srowf('Z1 a one-line case inside X, then the remainder',
          ['. ./Xc; echo after'],
          files={'Xc': ['case x in x) echo c1;; esac', 'echo c2']}),
    srowf('Z2 warm sh -c: . X then a one-line case',
          ["sh ./P",
           "sh -c 'echo $$>C;. ./Xh; case x in x) echo hit;; esac'"],
          files={'P': PRIMER, 'Xh': ['echo hi']}, post=WARM),
]

# ---- SH-CASE2 phase A: `$?` after an untaken `if`, a loop that never
# ran its body, and the last body's status (POSIX XCU 2.9.4) ----------
# Every row has an oracle (dash AND bash 5 agree on all of them).  The
# `false` before a construct is the STALE value an untaken one used to
# leave in `$?`; a row whose answer is the stale value too would prove
# nothing, so each compares a status the old code could not give.
ROWS_Q = [
    srow('Q1 an untaken if leaves $? 0, not the condition\'s 1',
         ['false; if false; then :; fi; echo $?']),
    srow('Q1b the same, multi-line',
         ['false', 'if false', 'then', ':', 'fi', 'echo $?']),
    srow('Q2 an untaken if/elif chain: the second condition ran, false',
         ['false', 'if false; then :; elif echo c2; false; then :; fi',
          'echo $?']),
    srow('Q3 else ran and its last command failed: 1',
         ['if false; then :; else false; fi; echo $?']),
    srow('Q4 else echo $? sees the condition\'s 1 (nothing zeroed)',
         ['false; if false; then :; else echo $?; fi']),
    srow('Q5 a taken then whose last command failed: 1',
         ['if true; then false; fi; echo $?']),
    srow('Q5b a taken elif whose last command failed: 1',
         ['if false; then :; elif true; then false; fi; echo $?']),
    srow('Q6 while: body ending `:` then a false condition: 0',
         ['i=', 'while test "$i" != xx; do i=${i}x; :; done; echo $?']),
    srow('Q7 while: body ending `false` then a false condition: 1',
         ['i=', 'while test "$i" != xx; do i=${i}x; false; done; '
          'echo $?']),
    srow('Q8 until: body ending false then a true condition: 1',
         ['i=0', 'until test "$i" = 1; do i=1; false; done; echo $?']),
    srow('Q9 a zero-iteration while after false: 0',
         ['false; while false; do :; done; echo $?']),
    srow('Q9b a zero-iteration until after false: 0',
         ['false; until true; do :; done; echo $?']),
    srow('Q10 for over an empty list after false: 0',
         ['false; for x in; do :; done; echo $?']),
    srow('Q10b for whose last body failed: 1 (the empty-list control)',
         ['for x in a b; do false; done; echo $?']),
    srow('Q10c for whose last body passed after a failure: 0',
         ['for x in a b; do false; :; done; echo $?']),
    srow('Q11 while body sees its condition\'s status',
         ['i=', 'while test "$i" != x; do echo c$?; i=x; done']),
    srow('Q11b until body sees its condition\'s 1',
         ['i=0', 'until test "$i" = 1; do echo c$?; i=1; done']),
    srow('Q12 a builtin-last body: 1',
         ['i=', 'while test "$i" != x; do i=x; test 1 = 2; done; '
          'echo $?']),
    srow('Q13 break out of loops that ran: 0',
         ['for i in a b; do false; break; done; echo $?',
          'while true; do false; break; done; echo $?',
          'until false; do false; break; done; echo $?']),
    srow('Q13b break after an iteration that failed: 0, not that 1',
         ['i=', 'while test "$i" != xxx; do i=${i}x; false; '
          'test "$i" = xx && break; done; echo $?']),
    srow('Q14 continue ends the body with its own 0',
         ['i=', 'while test "$i" != xx; do i=${i}x; false; continue; '
          'done; echo $?']),
    srow('Q15 break 2 out of nested loops: 0',
         ['while true; do while true; do false; break 2; done; done; '
          'echo $?']),
    srow('Q16 a dead nested if leaves the outer status alone',
         ['if true; then false; else if false; then :; fi; fi; '
          'echo $?']),
    srow('Q16b a dead nested while leaves it alone',
         ['if true; then false; else while false; do :; done; fi; '
          'echo $?']),
    srow('Q16c a dead nested for leaves it alone',
         ['if true; then false; else for x in; do :; done; fi; '
          'echo $?']),
    srow('Q17 a head skipped by && is dead: if',
         ['false && if true; then :; fi; echo $?']),
    srow('Q17b a head skipped by || runs nothing: if',
         ['true || if true; then echo D; fi; echo e$?',
          'true || if false; then :; else echo D2; fi; echo e$?']),
    srow('Q17c a head skipped by && is dead: while',
         ['false && while false; do :; done; echo $?']),
    srow('Q17d a head skipped by || runs nothing: while',
         ['true || while true; do echo D; break; done; echo e$?']),
    srow('Q17e a head skipped by && is dead: for',
         ['false && for x in; do :; done; echo $?']),
    srow('Q17f a head skipped by || runs nothing, assigns nothing: for',
         ['true || for x in a b; do echo D; done; echo e$?$x']),
    srow('Q17h a head skipped by || runs nothing: a brace group',
         ['true || {', 'echo D', '}', 'echo e$?',
          'false && {', 'echo D2', '}', 'echo e$?']),
    srow('Q17g a LIVE head after && or || runs and publishes',
         ['true && if false; then :; fi; echo a$?',
          'false || while false; do :; done; echo b$?',
          'true && for x in; do :; done; echo c$?']),
    srow('Q18 set -e: the untaken constructs publish 0 (rows capture $?)',
         ['set -e', 'if false; then :; fi', 'echo a$?',
          'while false; do :; done', 'echo b$?',
          # `false && :` leaves 1 behind without ending the script
          'false && :', 'for x in; do :; done', 'echo c$?']),
    srow('Q18b set -e: a loop that ran its body, status 0',
         ['set -e', 'i=', 'while test "$i" != x; do i=x; done',
          'echo $?']),
    srow('Q19 a nested loop: the outer takes the inner\'s last status',
         ['i=', 'while test "$i" != x; do i=x; j=; '
          'while test "$j" != y; do j=y; false; done; done; echo $?']),
    srow('Q19b an if untaken as the last command of a loop body: 0',
         ['i=', 'while test "$i" != x; do i=x; false; '
          'if false; then :; fi; done; echo $?']),
    srow('Q19c the inner loop is fresh each time round',
         ['for a in 1 2; do false; while false; do :; done; echo $?; '
          'done']),
    srow('Q19d a fresh loop does not inherit the last loop\'s status',
         ['i=', 'while test "$i" != x; do i=x; false; done',
          'while false; do :; done; echo $?']),
    srow('Q20 the status then drives &&',
         ['false; while false; do :; done && echo ok',
          'false; if false; then :; fi && echo ok2']),
    # the scan pass of a construct with a terminator redirect runs the
    # whole construct skipping; it must publish nothing, or the real
    # pass reads a `$?` the scan zeroed.  The redirect rows have the
    # `false` on a line of its own (a later segment is not scanned).
    srow('Q21 scan pass: if with a redirect sees the earlier 1',
         ['false', 'if test "$?" = 1; then echo one; fi < /dev/null']),
    srow('Q21b scan pass: while with a redirect sees the earlier 1',
         ['false', 'while test "$?" = 1; do echo one; break; done '
          '< /dev/null']),
    srow('Q21c scan pass: for with a redirect sees the earlier 1',
         ['false', 'for x in a; do echo $?; done < /dev/null']),
    srow('Q21d an untaken if with a redirect is 0 afterwards',
         ['false', 'if false; then :; fi < /dev/null', 'echo $?']),
    # A trap string's own constructs must not claim the OUTER loop's
    # pending hand-off (PCR_PEND, LP_PEND): PUMP_TRAP fires at depth 0,
    # which is exactly between a top-level loop's pop and its re-push
    # (SH-CASE2 B H1; this was a pinned gap, row Q22, until the review).
    # TERM, not INT: a shell started in the background ignores SIGINT on
    # entry and cannot trap it (the oracle then prints no T at all).
    srow('Q22 a trap holding a while loop leaves the loop-back status',
         ["trap 'while false; do :; done' TERM", 'i=',
          'while test "$i" != xx; do i=${i}x; kill -15 $$; false; done',
          'echo $?']),
    srow('Q22b a plain trap between iterations leaves the status alone',
         ["trap 'echo T' TERM", 'i=',
          'while test "$i" != xx; do i=${i}x; kill -15 $$; false; done',
          'echo $?']),
    srow('Q22c ...an if, a for, an if that prints',
         ["trap 'if true; then :; fi' TERM", 'i=',
          'while test "$i" != xx; do i=${i}x; kill -15 $$; false; done',
          'echo $?',
          "trap 'for j in a; do :; done' TERM", 'i=',
          'while test "$i" != xx; do i=${i}x; kill -15 $$; false; done',
          'echo $?',
          "trap 'if true; then echo T; fi' TERM", 'i=',
          'while test "$i" != xx; do i=${i}x; kill -15 $$; false; done',
          'echo $?']),
    srow('Q22d ...and a multi-line outer loop',
         ["trap 'while false; do :; done' TERM", 'i=',
          'while test "$i" != xx', 'do', 'i=${i}x', 'kill -15 $$', 'false',
          'done', 'echo $?']),
    # ---- typed at the console (typed ifs are frames; a typed loop is
    # spooled to a file and sourced) ---------------------------------
    row('QT1 typed: untaken if after false',
        ['false; if false; then :; fi; echo $?']),
    row('QT2 typed: zero-iteration while after false (spooled)',
        ['false;while false;do :;done;echo $?']),
    row('QT2b typed, three lines: the status survives the spool',
        ['false', 'while false;do :;done', 'echo $?']),
    row('QT3 typed: for over an empty list after false (spooled)',
        ['false;for x in;do :;done;echo $?']),
    row('QT3b typed, three lines',
        ['false', 'for x in;do :;done', 'echo $?']),
    row('QT4 typed: until whose last body failed',
        ['until test $n;do n=1;false;done', 'echo $?']),
    row('QT5 typed: until, body false then a true condition',
        ['i=0', 'until test $i = 1;do i=1;false;done', 'echo $?']),
    row('QT6 typed: a head skipped by || runs nothing',
        ['true||if true;then echo D;fi;echo $?',
         'true||for x in a;do echo D;done', 'echo $?']),
    row('QT6b typed: a while head skipped by || is not spooled',
        ['true||while :;do echo D;break;done', 'echo $?']),
]

# ---- SH-CASE2 phase B: glued and parenthesised case patterns ---------
# Oracle rows (dash AND bash 5) unless `want` is given.  A WANT row is
# either a pinned limit (named in its label) or a place where maux keeps
# a divergence on purpose (G17: an unquoted `)` outside pattern position
# is content in maux and a syntax error in both oracles).  Each quoting
# row holds a QUOTED `)` or `(` and the LEXICAL one in the SAME word,
# or it cannot tell the design from the naive one.
LONGPAT = 'q' * 130
ROWS_K = [
    # ---- the forms the brief names -----------------------------------
    srow('K1 glued star pattern',
         ['case x in *)echo hit;; esac']),
    srow('K1b glued literal pattern',
         ['case x in x)echo hit;; esac']),
    srow('K1c fully glued, esac on the same line',
         ['case x in x)echo hit;;esac']),
    srow('K2 glued alternation',
         ['case a in a|b)echo hit;; esac',
          'case b in a|b|c)echo hit;; esac',
          'case z in a|b)echo no;; *)echo other;; esac']),
    srow('K3 glued glob class',
         ['case a in [ab]*)echo hit;; esac',
          'case z in [ab]*)echo no;; *)echo other;; esac']),
    srow('K4 leading paren, spaced and glued',
         ['case x in (x) echo hit;; esac',
          'case x in (x)echo hit2;; esac',
          'case a in (a|b)echo hit3;; esac',
          'case x in (y|x) echo hit4;; esac']),
    srow('K4b leading paren as the first token of a line (a seeded '
         'group)',
         ['case x in', '(x) echo seeded;;', 'esac',
          'case x in', '(x)echo seeded2;;', 'esac',
          'case b in', '(a|b)echo seeded3;;', 'esac']),
    srow('K4c H2: the pattern half of a group token is expanded',
         ['V=x', 'case x in', '($V) echo HIT;;', 'esac',
          'case x in ($V)echo HIT2;; esac']),
    srow('K4d the remainder of a group token is expanded too',
         ['V=echo', 'case x in', '(x)$V hit;;', 'esac']),
    # ---- layout ------------------------------------------------------
    srow('K5 multi-line glued forms',
         ['case x in', 'x)echo multi;;', 'esac',
          'case x in', 'x)', 'echo body', ';;', 'esac',
          'case x in', 'y)echo no;;', 'x)echo yes;;', 'esac']),
    srow('K6 nested, glued',
         ['case x in x) case y in y)echo in;; esac;; esac',
          'case x in x)case y in y)echo in2;;esac;;esac',
          'case x in x) case y in z)echo no;; esac; echo out;; esac']),
    srow('K7 a pattern from a variable is expanded, not split or globbed',
         ['V=a', 'case a in $V)echo hit;; esac',
          'V=a', 'case "a b" in $V)echo no;; *)echo other;; esac']),
    srow('K7b a pattern is not pathname-expanded (the script is in '
         'the directory)',
         ['case x in ?)echo hit;; esac', 'case m in ?)echo hit2;; esac']),
    srow('K8 three clauses on one line, the second matches',
         ['case x in y)echo no;; x)echo yes;; z)echo no;; esac']),
    srow('K8b a skipped clause body is not a pattern (it equals the '
         'case word)',
         ['case x in y)x;; *)echo star;; esac']),
    srow('K9 inside if, else and a loop body',
         ['if true; then case x in x)echo t;; esac; fi',
          'if false; then :; else case x in x)echo e;; esac; fi',
          'for i in 1 2; do case "$i" in 1)echo one;; 2)echo two;; '
          'esac; done',
          'i=; while test "$i" != xx; do i=${i}x; case "$i" in x)echo '
          'wx;; xx)echo wxx;; esac; done']),
    srow('K10 status of the glued forms',
         ['false; case x in x)echo $?;; esac',
          'case x in x)false;; esac; echo $?',
          'case x in x);; esac; echo $?',
          'false; case x in y)echo no;; esac; echo $?',
          'case x in x)echo one&&echo two;; esac']),
    srow('K11 set -e with the glued forms',
         ['set -e', 'case x in y)false;; esac', 'echo a',
          'case x in x)true;; esac', 'echo b',
          'case x in x)false;; esac', 'echo NEVER']),
    srow('K12 a terminator redirect on a construct that shares its '
         "pattern's line",
         ['case x in', 'x) while false; do :; done < /dev/null; echo '
          'after', 'esac',
          'case x in', 'x) for i in a b; do echo $i; done < /dev/null',
          'esac',
          'case x in', 'x) if true; then echo t; fi > /dev/null; echo '
          'after2', 'esac',
          'case x in x)while false; do :; done < /dev/null;; esac']),
    srow('K13 a pipeline in the clause and a trailing redirect',
         ['case x in x)echo p|cat;; esac',
          'case x in x)echo q;; esac > /dev/null; echo after']),
    srow('K14 long pattern (the `)` at offset 130)',
         ['case x in ' + LONGPAT + ')echo no;; *)echo other;; esac']),
    srow('K50 M4: a multi-clause case inside a spooled loop keeps its '
         '`;;`',
         ["eval 'for i in a b;do case $i in a) echo A;; b) echo B;; "
          "esac;done'",
          "eval 'for i in a b;do case $i in a)echo A;;b)echo B;;esac;"
          "done'"]),
    # ---- quoting: each word holds a QUOTED paren and the lexical one -
    srow('K20 a quoted `)` is a pattern character, not the terminator',
         ["case ')' in ')')echo hit;; esac",
          'case ")" in ")")echo hit2;; esac',
          "case 'x)y' in 'x)'y)echo hit3;; esac",
          'case x in "x)"y)echo no;; *)echo other;; esac']),
    srow('K21 an escaped `)`',
         ['case ")" in [\\)])echo hit;; esac',
          'case "x)" in x\\))echo hit2;; esac']),
    srow('K22 the `)` that closes a $( ) span is not the terminator',
         ['case y in $(echo y))echo hit;; esac']),
    srow('K23 a quoted or escaped leading `(` stays a pattern character',
         ["case '(x' in '('x)echo hit;; esac",
          'case "(x" in "("x)echo hit2;; esac',
          'case "(x" in \\(x)echo hit3;; esac']),
    srow('K23b ...the same with the pattern first on its line',
         ["case '(x' in", "'('x)echo hit;;", 'esac',
          'case "(x" in', '"("x)echo hit2;;', 'esac',
          'case "(x" in', '\\(x)echo hit3;;', 'esac']),
    srow('K24 H4: a backslash- or single-quoted glob character is '
         'literal',
         ['case x in \\*) echo BAD;; *) echo OK;; esac',
          "case x in '*') echo BAD;; *) echo OK2;; esac"]),
    # ---- M2, M1, H1: refusals ---------------------------------------
    srow('K25 H1: a pipe stays a pipe when a quoted `)` follows it',
         ['echo LEFT|cat', 'echo LEFT|cat|cat']),
    srow('K25b H1: ...even with the `)` quoted in the second word '
         '(WANT: wording)',
         ['echo LEFT|echo")"X'],
         want=['sh: command not found', 'END', 'S0']),
    srow('K25c H1: ...or escaped (WANT: wording)',
         ['echo LEFT|echo\\)X'],
         want=['sh: command not found', 'END', 'S0']),
    srow('K25d H2: a $( ) span with no blank in it does not keep the '
         '`|` content',
         ['echo LEFT|$(true)cat']),
    srow('K26 M1: && right after a pattern is a syntax error, not a '
         'dropped empty command (WANT: wording)',
         ['case x in x)&& echo BAD;; esac'],
         want=['sh: syntax error',
               'sh: EOF with a construct still open', 'S1']),
    srow('K26b M1: ...and ||',
         ['case x in x)|| echo BAD;; esac'],
         want=['sh: syntax error',
               'sh: EOF with a construct still open', 'S1']),
    srow('K26c M1: ...and |',
         ['case x in x)|echo BAD;; esac'],
         want=['sh: syntax error',
               'sh: EOF with a construct still open', 'S1']),
    srow('K28 H3: a pattern in the second stage of a pipeline is not '
         'split (WANT: both oracles reject; maux runs no BAD)',
         ['case false in', 'y) false | x)echo BAD;;', '*) echo OK;;',
          'esac'],
         want=['OK', 'END', 'S0']),
    srow('K27 M2: a quoted "case" or "in" opens no case (WANT: both '
         'oracles reject; maux prints nothing, it has always treated '
         'a quoted keyword as the keyword)',
         ['"case" x in x)echo BAD;; esac',
          'case x "in" x)echo BAD2;; esac'],
         want=['END', 'S0']),
    srow('K44 M2: an empty pattern `()` is refused (WANT: wording; '
         'both oracles reject)',
         ['case "" in () echo BAD;; *) echo OK;; esac'],
         want=['sh: syntax error', 'END', 'S0']),
    srow('K44b M2: ...and a bare `)` (WANT: wording)',
         ['case x in ) echo BAD;; esac; echo AFTER'],
         want=['sh: syntax error', 'END', 'S0']),
    srow('K45 M2: ...but a QUOTED empty pattern is a pattern',
         ['case x in "") echo no;; x) echo yes;; esac',
          'V=', 'case $V in "") echo EMPTY;; esac']),
    # ---- outside pattern position (G17 kept; WANT rows) --------------
    srow('K30 G17: an unquoted `)` outside a pattern is content '
         '(dash and bash: syntax error)',
         ['echo a)b'], want=['a)b', 'END', 'S0']),
    srow('K31 G17: ...even after the words case x in',
         ['echo case x in y)z'],
         want=['case x in y)z', 'END', 'S0']),
    srow('K32 G17: ...and a bare `(`',
         ['echo (x)'], want=['(x)', 'END', 'S0']),
    srow('K33 a `)` in the first word, outside any case, is content '
         '(dash and bash: syntax error; WANT: wording)',
         ['x)echo hit'], want=['sh: command not found', 'END', 'S0']),
    # ---- pinned limits -----------------------------------------------
    srow('K40 LIMIT: blanks inside the parens (`( x )`) are not '
         'trimmed; dash/bash print hit',
         ['case x in ( x ) echo hit;; esac'], want=['END', 'S0']),
    srow('K41 LIMIT: a blank before the `)` (`x )`) is not a pattern '
         'end; dash/bash print hit',
         ['case x in x ) echo hit;; esac'], want=['END', 'S0']),
    srow('K43 LIMIT: a quote inside a line-first group `("a b")` is '
         'passed verbatim to the group span, so the pattern keeps the '
         'quote marks (the mid-line form works); dash/bash print hit',
         ['case "a b" in', '("a b") echo hit;;', 'esac'],
         want=['END', 'S0']),
    srow('K42 LIMIT: a double-quoted glob character in a pattern still '
         'matches as a glob (the tokenizer keeps them live inside '
         '"..." for $* and $( ); dash/bash print OK)',
         ['case x in "*") echo BAD;; *) echo OK;; esac',
          'case a in "[a]") echo BAD2;; *) echo OK2;; esac',
          'case ax in a"*") echo BAD3;; *) echo OK3;; esac'],
         want=['BAD', 'BAD2', 'BAD3', 'END', 'S0']),
    srow('K47 LIMIT: a `$` or a quote ahead of the `)` in a GLUED '
         'alternation lexes as a pipeline (the spaced `a|$V) echo` '
         'works); dash/bash print hit',
         ['V=b', 'case b in a|$V)echo hit;; esac',
          'case b in a|"$V")echo hit2;; esac'],
         want=['END', 'S0']),
    # ---- typed at the console ----------------------------------------
    row('KT1 typed: glued pattern',
        ['case x in x)echo hit;; esac']),
    row('KT2 typed: leading paren',
        ['case x in (x) echo hit;; esac']),
    row('KT3 typed: alternation, fully glued',
        ['case a in a|b)echo hit;;esac']),
    row('KT4 typed, three lines: a glued loop head after the pattern',
        ['case x in', 'x)for i in a;do echo H;done;;', 'esac']),
    row('KT5 typed: H3 the same with an escaped pattern is refused '
        'loudly (WANT)',
        ['case x in', '\\x)for i in a;do echo H;done;;', 'esac'],
        want=['sh: for/while: quoted text before the loop']),
    row('KT6 typed: a clause body on the next line',
        ['case x in', 'x)echo ml;;', 'esac']),
]

ROWS = ROWS_A + ROWS_B + ROWS_C + ROWS_Q + ROWS_K

# the 40-column glass wraps a typed line of more than 37 characters
# (the `$ ` prompt is two more) and the row then compares a mangled echo
for _r in ROWS_Q + ROWS_K:
    if not _r['files']:
        for _c in _r['cmds']:
            assert len(_c) <= 37, (_r['label'], _c)


def run_rows(client, tmp, failures, only=None):
    ctr = X.Counters(client)
    F.typed(client, 'cd /tmp', 'fixture', failures)
    for r in ROWS:
        label = r['label']
        if only and not label.startswith(only):
            continue
        host_files = {}
        for name, lines in r['files'].items():
            tcmds, text = M.file_cmds(name, lines, True)
            host_files[name] = text
            for c in tcmds:
                F.typed(client, c, label + ' fixture', failures)
        if r['want'] is None:
            want = X.fresh_oracle(tmp, host_files, r['cmds'], failures,
                                  label)
        else:
            want = r['want']
        before = ctr.snap()
        got = []
        for line in r['cmds']:
            out = F.typed(client, line, label, failures)
            if out is None:
                got = None
                break
            got.extend(out)
        if got is None:
            continue
        D.assert_eq(label, M.norm(got), M.norm(want), failures)
        if r['post']:
            pcmds, fn = r['post']
            outs = []
            for line in pcmds:
                o = F.typed(client, line, label + ' post', failures)
                outs.extend(o or [])
            err = fn(outs)
            if err:
                failures.append(f'{label}: {err}')
        after = ctr.snap()
        if after != before:
            failures.append(f'{label}: buffers/OFT before {before} '
                            f'after {after} (a file was left open)')


def run(play, failures, only=None):
    tmp, client = M.boot_a(play)
    try:
        work = os.path.join(tmp, 'host')
        os.mkdir(work)
        run_rows(client, work, failures, only)
    finally:
        client.close()
        shutil.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------------
# PART B: the console session (a spooled loop needs the PS2 prompt, and
# history recall needs the line editor; the harness above types whole
# lines and waits for a bare `$`).
def b_dot(t, failures):
    t.wait_prompt('ready')
    M.clear(t)
    M.line(t, "echo 'echo hi' > Xh", '$', 'D0')
    M.line(t, "echo 'if true; then' > Xi", '$', 'D0')
    M.line(t, "echo 'echo inside' >> Xi", '$', 'D0')
    M.clear(t)
    got = M.line(t, 'echo S; . ./Xh; echo after', '$', 'D1')
    M.need_eq(got, ['$ echo S; . ./Xh; echo after', 'S', 'hi', 'after',
                    '$'], 'D1 the typed line keeps its rest', failures)
    M.clear(t)
    t.c.call_tool('type', {'text': M.UP})
    for _ in range(8):
        t._slice()
    got = M.line(t, '', '$', 'D2')
    M.need_eq(got, ['$ echo S; . ./Xh; echo after', 'S', 'hi', 'after',
                    '$'], 'D2 recalled from history it runs ONCE', failures)
    M.clear(t)
    M.line(t, 'for i in a b', '>', 'D3')
    M.line(t, 'do', '>', 'D3')
    M.line(t, '. ./Xh; echo $i', '>', 'D3')
    got = M.line(t, 'done', '$', 'D3')
    M.need_eq(got[-5:], ['hi', 'a', 'hi', 'b', '$'],
              'D3 a . with a remainder inside a SPOOLED loop', failures)
    M.clear(t)
    got = M.line(t, '. ./Xi; echo after:$?', '$', 'D4')
    M.need_eq(got[-3:], ['sh: EOF with a construct still open',
                         'after:2', '$'],
              'D4 an unterminated X typed at the console', failures)
    M.clear(t)
    got = M.line(t, 'echo again', '$', 'D5')
    M.need_eq(got, ['$ echo again', 'again', '$'],
              'D5 the console is not left under a leaked frame', failures)


CASES_B = [('dot', b_dot)]


def part_b(play, failures, only=None):
    E.DISK = play
    for name, fn in CASES_B:
        if only and not name.startswith(only):
            continue
        mine = []

        def run(t, fn=fn, mine=mine):
            fn(t, mine)
        ok, err = E.session('text40', run)
        if not ok:
            failures.append(f'console {name}: {err}')
        failures.extend(mine)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--play', default=os.path.join(ROOT, 'build',
                                                   'play.po'))
    ap.add_argument('--part', default='all', choices=['a', 'b', 'all'])
    ap.add_argument('--rows', default=None,
                    help='run only the rows whose label starts with this '
                         '(A1 is the cold control: a later run of a '
                         'slice may see a warm bank), or the part B '
                         'cases whose name does')
    args = ap.parse_args()
    play = os.path.abspath(args.play)
    if not os.path.exists(play):
        print(f'check-shseq: {play} missing -- make play-image')
        return 2
    for name, tool in (('dash', F.DASH), ('bash 5+', F.BASH5)):
        if not tool:
            print(f'check-shseq: oracle {name} missing on this host')
            return 2
    failures = []
    t0 = time.time()
    M.rig_selftest(failures)
    if failures:
        print(f'[check-shseq] FAIL: {failures[0]}')
        return 1
    try:
        if args.part in ('a', 'all'):
            run(play, failures, args.rows)
        if args.part in ('b', 'all'):
            part_b(play, failures, args.rows)
    except (RuntimeError, AssertionError, E.Wedged) as exc:
        failures.append(str(exc))
    if failures:
        print(f'[check-shseq] FAIL: {len(failures)} row(s)')
        for x in failures:
            print(f'  - {x}'.replace('\n', '\n    '))
        return 1
    print(f'[check-shseq] PASS: sh -c loops run on a reused bank; the '
          f'one-line case matches dash and bash 5, typed and in scripts '
          f'({time.time() - t0:.0f} s)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
