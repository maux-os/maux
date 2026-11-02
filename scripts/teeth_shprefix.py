#!/usr/bin/env python3
"""teeth_shprefix.py -- the sabotage runner behind check-shprefix's
teeth (docs/SH-PREFIX-NOTES.md), on scripts/teeth_lib.py (HYG-4). NOT a
gate and in no sweep: it edits the sh sources, rebuilds the play image,
runs ONE gate and requires the tooth's named rows RED and its controls
GREEN, with the sabotaged sh.bin DIFFERING from the good one. It
restores from the captured bytes (never `git checkout`) and the final
rebuild must reproduce the good sh.bin. ROWS names, per tooth, the
check-shprefix row ids that must fail and those that must stay green
(SH-ROOM2 review M1: the runner used to check only the gate's
aggregate exit). Exit status: teeth_lib.py (0 all behaved, 1 a tooth did
not bite, 2 runner broken).

  python3 scripts/teeth_shprefix.py            # all
  python3 scripts/teeth_shprefix.py T2 T4      # by name prefix
  python3 scripts/teeth_shprefix.py --dry
  python3 scripts/teeth_shprefix.py --observe T2   # print what failed
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import teeth_lib as T  # noqa: E402

PF = 'src/bin/shpfx.s'
SG = 'src/bin/shsgcld.s'      # SH-ROOM2: PFX_ISSPEC moved here
LX = 'src/bin/shlex.s'
B2 = 'src/bin/shblt2.s'
PH = 'src/bin/shpath.s'
P2 = 'src/bin/shpth2.s'
TC = 'src/bin/shtabc.s'


# (name, gate, file, [(old, new)]) -- the gate must go RED
SPECS = [
 ('T1 PFX_RESTORE never puts anything back: `echo $A` rows',
  'shprefix', PF,
  [("PFX_RESTORE lda   PFX_SV\n", "PFX_RESTORE rts\n            lda   PFX_SV\n")]),
 ('T2 nothing is a special builtin: `A=1 :` does not persist',
  'shprefix', SG,
  [("PFX_ISSPEC  lda   CMD_ARGV+0\n",
    "PFX_ISSPEC  clc\n            rts\n            lda   CMD_ARGV+0\n")]),
 ('T3 START no longer clears PFX_SV: a dirty bank restores garbage',
  'shwarm', LX,
  [("            stz   PFX_SV                 ;arena: nothing saved\n", "")]),
 ('T4 a pipeline stage keeps its prefix after the spawn',
  'shprefix', B2,
  [("            jsr   PFX_STG_UNDO           ;envp is the kernel's\n", "")]),
 ('T5 a second assignment word is field-split: `B=$V` of `A=1 B=$V`',
  'shprefix', P2,
  [("            bcs   :asgnck                ;is an assignment too\n",
    "            nop\n            nop\n")]),
 ('T6 the script fd is not moved high: F1-F3',
  'shprefix', PH,
  [("OPEN_HI     sta   OHI_FD\n", "OPEN_HI     rts\n            sta   OHI_FD\n")]),
 ('T7 exec onto the shell\'s own fd is allowed: F4',
  'shprefix', B2,
  [("            cpx   CUR_IN_FD\n            beq   :ref\n", "")]),
 ('T8 sh -c never runs its string: C rows',
  'shprefix', LX,
  [(":noexit     lda   SH_CMODE\n            beq   :nocmode\n",
    ":noexit     lda   SH_CMODE\n            bra   :nocmode\n")]),
 ('T9 a prefix is not exported: `A=1 env`',
  'shprefix', PF,
  [("            lda   #1                     ;exported for the child\n"
    "            sta   VAREXP,x\n", "")]),
 ('T10 TAB completion refuses after an assignment again: `A=1 ca`',
  'tabcomp', TC,
  [("            bcs   :adv               ;a prefix assignment:\n",
    "            bcs   :rf                ;a prefix assignment:\n")]),
 ('T13 `exec` with no command never persists: `A=1 exec 3<f`',
  'shprefix', SG,
  [(":no         lda   CMD_ARGC+0\n            cmp   #1\n",
    ":no         lda   CMD_ARGC+0\n            cmp   #99\n")]),
 ('T11 the console loop\'s spool file is not moved high: F3b',
  'shprefix', 'src/bin/shtrap.s',
  [(":spopn2     jsr   OPEN_HI                ;see shpath.s\n",
    ":spopn2     nop\n")]),
 ('T12 `:` ignores its redirects again: `: > F`, `A=1 > F`',
  'shprefix', 'src/bin/shbltn.s',
  [("            jsr   PFX_HASRD\n            bne   :ext\n", "")]),
 # SH-ROOM2 step 2b: a message a syscall receives must stay below
 # $D000 (copyin refuses a process address >= $D000).  Each tooth
 # points the cold bundle at a COPY of the message that lives in
 # the segment: the diagnostic is lost and the row goes red.
 ('T14 PFX_REC\'s "too many assignments" read from the segment: P20',
  'shprefix', SG,
  [("            lda   #<PFX_MANY_M\n            ldx   #>PFX_MANY_M\n",
    "            lda   #<SGT14\n            ldx   #>SGT14\n"),
   ("SETEOFF_STR  asc   \"+E\"\n             dfb   0\n",
    "SETEOFF_STR  asc   \"+E\"\n             dfb   0\n"
    "SGT14       asc   \"sh: too many assignments\"\n"
    "            dfb   $8D,0\n")]),
 ('T15 PFX_REC\'s "name too long" read from the segment: P21',
  'shprefix', SG,
  [(":nlong      lda   #<VARNMLONG_MSG\n            ldx   #>VARNMLONG_MSG\n",
    ":nlong      lda   #<SGT15\n            ldx   #>SGT15\n"),
   ("SETEOFF_STR  asc   \"+E\"\n             dfb   0\n",
    "SETEOFF_STR  asc   \"+E\"\n             dfb   0\n"
    "SGT15       asc   \"sh: variable name too long\"\n"
    "            dfb   $8D,0\n")]),
 ('T16 PFX_REC\'s "value too long" read from the segment: P22',
  'shprefix', SG,
  [(":vlong      lda   #<VARVLLONG_MSG\n            ldx   #>VARVLLONG_MSG\n",
    ":vlong      lda   #<SGT16\n            ldx   #>SGT16\n"),
   ("SETEOFF_STR  asc   \"+E\"\n             dfb   0\n",
    "SETEOFF_STR  asc   \"+E\"\n             dfb   0\n"
    "SGT16       asc   \"sh: variable value too long\"\n"
    "            dfb   $8D,0\n")]),
 ('T17 `set`\'s usage read from the segment: S1',
  'shprefix', SG,
  [(":usage      lda   #<SETUSAGE_MSG\n            ldx   #>SETUSAGE_MSG\n",
    ":usage      lda   #<SGT17\n            ldx   #>SGT17\n"),
   ("SETEOFF_STR  asc   \"+E\"\n             dfb   0\n",
    "SETEOFF_STR  asc   \"+E\"\n             dfb   0\n"
    "SGT17       asc   \"usage: set -x|+x|-e|+e\"\n"
    "            dfb   $8D,0\n")]),
]

ROWS = {
    'T1 ': (['P1', 'P2'], ['P5']),
    'T2 ': (['P9', 'P9c'], ['P9b']),
    'T3 ': (['PFX_SV was $A5 at PFX_RESTORE'], []),
    'T4 ': (['P8b'], ['P8']),
    'T5 ': (['P12b'], ['P12']),
    'T6 ': (['F1', 'F2', 'F3'], ['C1']),
    'T7 ': (['F4'], ['F1']),
    'T8 ': (['C1', 'C2'], ['P1']),
    'T9 ': (['P1', 'P3'], ['P5']),
    'T10': (['FAIL tabcomp cmd', 'A=1 ca TAB TAB is command position'],
            []),
    'T11': (['F3b'], ['F3']),
    'T12': (['P10', 'P10b'], ['P11']),
    'T13': (['P9c'], ['P9']),
    'T14': (['P20', 'P20b'], ['P21', 'P22']),
    'T15': (['P21'], ['P20', 'P22']),
    'T16': (['P22'], ['P20', 'P21']),
    'T17': (['S1'], ['P20']),
}


GATES = {'shprefix': 'make check-shprefix', 'shwarm': 'make check-shwarm',
         'tabcomp': 'python3 scripts/check_tabcomp.py text40 cmd'}


def tooth(name, gate, fn, edits):
    key = next(k for k in ROWS if name.startswith(k))
    red, ctrl = ROWS[key]
    if gate == 'shprefix':
        chk = T.Check(GATES[gate], 'devfs', T.Rows(red=red, controls=ctrl))
    elif gate == 'tabcomp':
        chk = T.Check(GATES[gate], 'namerows', T.Rows(red=['cmd [text40]']))
    else:                                   # shwarm: no rows, one message
        chk = T.Check(GATES[gate], 'aggregate', T.Aggregate(
            r'^\[check-shwarm\] FAIL: PFX_SV was \$A5 at PFX_RESTORE',
            'check-shwarm prints one failure line per problem, no row ids'))
    return T.Tooth(name, edits=[(fn, a, b) for a, b in edits],
                   checks=[chk])


T.main('shprefix', [tooth(*s) for s in SPECS],
       prep=T.Make('play-image'), artifacts=['build/sh.bin'])
