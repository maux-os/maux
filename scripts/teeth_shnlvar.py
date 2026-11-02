#!/usr/bin/env python3
"""teeth_shnlvar.py -- the sabotage runner behind check-shnlvar's teeth
(docs/SH-NLVAR-NOTES.md), on scripts/teeth_lib.py (HYG-4). NOT a gate
and in no sweep: it edits the sh sources, rebuilds the play image, runs
check-shnlvar and requires every row in the tooth's `rows` RED, with the
sabotaged sh.bin DIFFERING from the good one. It restores from the
captured bytes and the final rebuild must reproduce the good sh.bin.
Exit status: teeth_lib.py (0 all behaved, 1 a tooth did not bite, 2
runner broken).

  python3 scripts/teeth_shnlvar.py            # all
  python3 scripts/teeth_shnlvar.py T2         # by name prefix
  python3 scripts/teeth_shnlvar.py --dry
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import teeth_lib as T  # noqa: E402

SB = 'src/bin/shsubst.s'
SP = 'src/bin/shparse.s'

VSAFE = """:punct      cmp   #$8D                   ;a newline: bare, and
            beq   :yes                   ;  one byte (SUB_WRVAL)
"""
XLATE = """:vplain     cmp   #$8D                   ;a newline goes as the
            bne   :vput                  ;  bit-7-CLEAR $0D: no
            lda   #$0D                   ;  line end, not a meta
:vput       ldx   SUBBWFD
"""


# (name, gate, file, [(old, new)], rows) -- the gate must go RED, and
# every row in `rows` must be among the failures
SPECS = [
 ('T1 the encoding removed: a newline is escaped as before',
  'shnlvar', SB,
  [(VSAFE, ":punct\n"),
   (XLATE, ":vplain     ldx   SUBBWFD\n")],
  ['N1 ', 'N2 ']),
 ('T1b a newline is bare but written raw: it ends the line',
  'shnlvar', SB,
  [(XLATE, ":vplain     ldx   SUBBWFD\n")],
  ['N1 ', 'N2 ']),
 ('T2 the encoding kept but the budget counts two bytes',
  'shnlvar', SB,
  [(VSAFE, ":punct\n")],
  ['N7a ', 'N7b ']),
 ('T3 UNESC not applied on the argv funnel (the value path)',
  'shnlvar', SP,
  [("APPEND_ARGV jsr   UNESC\n", "APPEND_ARGV nop\n            nop\n            nop\n")],
  ['N1d ', 'N4b ']),
 ('T4 the ring bound one too loose: 250 is accepted',
  'shnlvar', SB,
  [("            cmp   #SUBPIPECAP\n            bcs   :bad\n",
    "            cmp   #SUBPIPECAP+1\n            bcs   :bad\n")],
  ['N7c ', 'N7d ']),
 ('T5 the ring bound one too tight: 249 is refused',
  'shnlvar', SB,
  [("            cmp   #SUBPIPECAP\n            bcs   :bad\n",
    "            cmp   #SUBPIPECAP-1\n            bcs   :bad\n")],
  ['N7a ', 'N7b ']),
]


def tooth(name, gate, fn, edits, rows):
    return T.Tooth(name, edits=[(fn, a, b) for a, b in edits], checks=[
        T.Check('make check-shnlvar', 'devfs',
                T.Rows(red=[r.strip() for r in rows]))])


T.main('shnlvar', [tooth(*s) for s in SPECS],
       prep=T.Make('play-image'), artifacts=['build/sh.bin'])
