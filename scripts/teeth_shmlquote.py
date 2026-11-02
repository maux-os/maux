#!/usr/bin/env python3
"""teeth_shmlquote.py -- the sabotage runner behind check-shmlquote's
teeth (docs/SH-MLQUOTE-NOTES.md), on scripts/teeth_lib.py (HYG-4). NOT
a gate and in no sweep: it edits the sh sources, rebuilds the play
image, runs the gate (or a slice of it) and requires every named row
RED, with the sabotaged sh.bin DIFFERING from the good one. It restores
from the captured bytes and the final rebuild must reproduce the good
sh.bin. Part a prints PASS/FAIL per row; part b (the console sessions)
prints failure bullets only (`console NAME: ROW: ...`), so its rows are
seen when they fail. Exit status: teeth_lib.py (0 all behaved, 1 a tooth
did not bite, 2 runner broken).

  python3 scripts/teeth_shmlquote.py            # all
  python3 scripts/teeth_shmlquote.py T2 T7      # by name prefix
  python3 scripts/teeth_shmlquote.py --dry
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import teeth_lib as T  # noqa: E402

RL = 'src/bin/shrlog.s'
SG = 'src/bin/shsgmlq.s'
L2 = 'src/bin/shlex2.s'
LX = 'src/bin/shlex.s'
ED = 'src/bin/shedit.s'
HB = 'src/bin/shbltn.s'

G = 'python3 scripts/check_shmlquote.py'


# (name, gate command, [(file, old, new)], rows that must be red)
SPECS = [
 ('T1 the continuation disabled (every line complete)',
  G + ' --part a --rows Q1', [(RL, "            lda   RL_KIND\n            beq   :ret\n",
                               "            lda   #0\n            beq   :ret\n")],
  ['Q1 ']),
 ('T3 history added per fragment, not per logical line',
  G + ' --part b --rows hist',
  [(ED, "            bra   :fin               ;Return: READLINE adds the\n",
    "            jsr   ED_HADD\n            bra   :fin               ;Return: READLINE adds the\n"),
   (L2, "RL_DONE     lda   RL_ED\n            beq   :ok\n",
    "RL_DONE     lda   #0\n            beq   :ok\n")],
  ['R2']),
 ('T4 STRIPCOMMENT without the escaped-blank rule',
  G + ' --part a --rows A8', [(L2, "            cpy   STRPEX                 ;... and not escaped?\n            beq   :hno\n", "")],
  ['A8 ']),
 ('T5 backslash-newline keeping the backslash',
  G + ' --part a --rows Q3', [(RL, ":bsl        dec   LINELEN                ;2: the backslash goes\n",
                                ":bsl        nop\n            nop\n            nop\n")],
  ['Q3a ', 'Q3b ']),
 ('T6 a comment is not stripped before the test (its quote continues)',
  G + ' --part a --rows Q4a', [(RL, "            jsr   STRIPCOMMENT\n            ldy   LINELEN",
                                "            nop\n            nop\n            nop\n            ldy   LINELEN")],
  ['Q4a ']),
 ('T7 the loop-head mark left at the LAST physical line',
  G + ' --part a --rows W1b', [(RL, "RL_FINISH   lda   RL_CONT\n", "RL_FINISH   lda   #0\n")],
  ['W1b ']),
 ('T8 a here-doc body with a QUOTED delimiter joins backslash-newline',
  G + ' --part a --rows H', [(HB, "            lda   HD_QUOTED\n            bne   :haveline\n            dec   HDLLEN",
                              "            dec   HDLLEN")],
  ['H2 ', 'H4 ']),
 ('T9 LINEMAX one too tight: a 255-byte logical line is refused',
  G + ' --part a --rows Q7c', [(SG, "            bcs   :big\n            sta   RL_NEWN\n",
                                "            bcs   :big\n            cmp   #LINEMAX\n            bcs   :big\n            sta   RL_NEWN\n")],
  ['Q7c ']),
 ('T10 an over-long physical line is not refused (it runs truncated)',
  G + ' --part a --rows Q7b', [(L2, "            lda   RL_OVER\n            bne   :slow                  ;over-long: refused\n",
                                "            lda   RL_OVER\n            nop\n            nop\n")],
  ['Q7b ']),
 ('T11 EOF after a trailing backslash joins (no-newline literal lost)',
  G + ' --part a --rows Q7g', [(RL, ":top        lda   RL_NOCR\n            bne   :done\n", ":top\n")],
  ['Q7g ']),
 ('T12 PS2 never shown',
  G + ' --part b --rows basic', [(RL, "RL_PS2      lda   SH_INTERACT\n            beq   :out\n",
                                  "RL_PS2      lda   SH_INTERACT\n            bra   :out\n")],
  ['Q1']),
 ('T13 ^C at PS2 does not abandon',
  G + ' --part b --rows interrupt', [(RL, "            lda   ED_INTR\n            bne   :abandon\n",
                                      "            lda   ED_INTR\n            nop\n            nop\n")],
  ['Q7i']),
 ('T14 the refusal scanner ignores $( ) spans',
  G + ' --part a --rows Q7k', [(SG, "            ldx   SUBDEPTH\n            bne   :span ",
                                "            ldx   #0\n            bne   :span ")],
  ['Q7k ']),
 ('T15 STRIPCOMMENT: a backslash in "..." only skips a quote',
  G + ' --part a --rows Q4d', [(L2, "            beq   :done\n            iny                          ;skip BOTH bytes",
                                "            cmp   #$A2\n            bne   :done\n            iny                          ;skip BOTH bytes")],
  ['Q4d ']),
 ('T16 a here-doc overflow is dropped silently again',
  G + ' --part a --rows H', [(HB, ":hdov       inc   HDOVF\n", ":hdov       nop\n            nop\n            nop\n")],
  ['H9 ']),
 ('T17 the refusal scanner has no group-( ) rule',
  G + ' --part a --rows Q7l', [(SG, "            cpx   #0                     ;a group span\n            beq   :wt\n",
                                "            cpx   #0\n            beq   :wt\n            bra   :wt\n")],
  ['Q7l ']),
 ('T18 the here-doc BODY cap is dropped silently again',
  G + ' --part a --rows H7', [(HB, ":full       inc   HDOVF\n", ":full       nop\n            nop\n            nop\n")],
  ['H7 ']),
]


def tooth(name, cmd, edits, rows):
    rows = [r.strip() for r in rows]
    part_b = '--part b' in cmd
    return T.Tooth(name, edits=edits, checks=[T.Check(
        cmd, 'bullets_only' if part_b else 'devfs',
        T.Rows(red=rows, rule=T.ANY if part_b else T.ALL))])


T.main('shmlquote', [tooth(*s) for s in SPECS],
       prep=T.Make('play-image'), artifacts=['build/sh.bin'])
