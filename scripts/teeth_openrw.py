#!/usr/bin/env python3
"""teeth_openrw.py -- the sabotage runner behind check-openrw's teeth
(docs/OPEN-RW-1-NOTES.md), on scripts/teeth_lib.py (HYG-4). NOT a gate
and in no sweep: it edits the sh sources, rebuilds the play image, runs
check_openrw.py on the tooth's rows and requires a named row RED, with
the sabotaged sh.bin DIFFERING from the good one. It restores from the
captured bytes and the final rebuild must reproduce the good sh.bin.
check-openrw prints failure bullets only (no PASS rows), so the rule is
the legacy ANY and a row is seen only when it fails. Exit status:
teeth_lib.py (0 all behaved, 1 a tooth did not bite, 2 runner broken).

  python3 scripts/teeth_openrw.py            # all
  python3 scripts/teeth_openrw.py T2 T4      # by name prefix
  python3 scripts/teeth_openrw.py --dry
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import teeth_lib as T  # noqa: E402

RW = 'src/bin/shsgrw.s'
B2 = 'src/bin/shblt2.s'


# (name, file, [(old, new)], rows that must be among the failures)
SPECS = [
 ('T1 no retry at all: a busy open fails at once (R1, R2, R3 red)',
  RW,
  [("            cmp   #$50                   ;MLIE_FILOPEN: busy\n"
    "            bne   :bad\n",
    "            bra   :bad\n")],
  ['R1', 'R2', 'R3']),
 ('T2 retry on EVERY error, not just $50 (R5 red)',
  RW,
  [("            cmp   #$50                   ;MLIE_FILOPEN: busy\n"
    "            bne   :bad\n", "")],
  ['R5']),
 ('T3 no bound: retries for ever (R3 red)',
  RW,
  [("            bcs   :bad                   ;the bound\n",
    "            nop\n            nop\n")],
  ['R3']),
 ('T4 no ^C bracket: the wait cannot be interrupted (R4 red)',
  RW,
  [("OW_ARM      lda   SH_INTERACT\n            beq   :out\n",
    "OW_ARM      rts\n            lda   SH_INTERACT\n            beq   :out\n")],
  ['R4']),
 ('T5 a ^C is reported as a refusal: message and status 1 (R4 red)',
  B2,
  [("            lda   OW_INTR\n            beq   :rfmsg\n",
    "            lda   OW_INTR\n            bra   :rfmsg\n")],
  ['R4']),
]


def tooth(name, fn, edits, rows):
    return T.Tooth(name, edits=[(fn, a, b) for a, b in edits], checks=[
        T.Check('python3 scripts/check_openrw.py ' + ' '.join(rows),
                'bullets_only', T.Rows(red=rows, rule=T.ANY))])


T.main('openrw', [tooth(*s[:4]) for s in SPECS],
       prep=T.Make('play-image'), artifacts=['build/sh.bin'])
