#!/usr/bin/env python3
"""teeth_shforeign.py -- the sabotage runner behind check-shforeign's
teeth (docs/SH-FOREIGN.md), on scripts/teeth_lib.py (HYG-4). NOT a gate
and in no sweep: it edits src/bin/shlex2.s, rebuilds the play image, runs
check-shforeign and requires every row in the tooth's `rows` RED, with the
sabotaged sh.bin DIFFERING from the good one. It restores from the
captured bytes and the final rebuild must reproduce the good sh.bin.
Exit status: teeth_lib.py (0 all behaved, 1 a tooth did not bite, 2
runner broken).

  python3 scripts/teeth_shforeign.py            # all
  python3 scripts/teeth_shforeign.py T2         # by name prefix
  python3 scripts/teeth_shforeign.py --dry
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import teeth_lib as T  # noqa: E402

SL = 'src/bin/shlex2.s'

FOLD = """:rlscan     lda   RL_BUF,y
            ora   #$80
            sta   RL_BUF,y
            cmp   #$8D
            beq   :rlgotcr
"""

SPECS = [
 ('T1 the fold removed: the reader is as it was',
  SL,
  [(FOLD, ":rlscan     lda   RL_BUF,y\n            cmp   #$8D\n"
          "            beq   :rlgotcr\n")],
  ['S1 ', 'S2 ', 'S5 ', 'S6 ', 'S10 ', 'S12 ', 'S13 ']),
 ('T2 folded for the compare only (not stored): a $0D ends the line '
  'but the separators stay low',
  SL,
  [(FOLD, ":rlscan     lda   RL_BUF,y\n            ora   #$80\n"
          "            cmp   #$8D\n            beq   :rlgotcr\n")],
  ['S1 ', 'S5 ', 'S7 ', 'S9 ']),
 ('T3 stored but the terminator tested before the fold: the content '
  'is high, the $0D ends nothing',
  SL,
  [(FOLD, ":rlscan     lda   RL_BUF,y\n            cmp   #$8D\n"
          "            beq   :rlgotcr\n            ora   #$80\n"
          "            sta   RL_BUF,y\n")],
  ['S1 ', 'S2 ', 'S6 ', 'S10 ', 'S11 ', 'S12 ']),
]


def tooth(name, fn, edits, rows):
    return T.Tooth(name, edits=[(fn, a, b) for a, b in edits], checks=[
        T.Check('make check-shforeign', 'devfs',
                T.Rows(red=[r.strip() for r in rows]))])


T.main('shforeign', [tooth(*s) for s in SPECS],
       prep=T.Make('play-image'), artifacts=['build/sh.bin'])
