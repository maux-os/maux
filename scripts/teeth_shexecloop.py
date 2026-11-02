#!/usr/bin/env python3
"""teeth_shexecloop.py -- the sabotage runner behind check-shexecloop's
teeth (docs/SH-EXECLOOP-NOTES.md), on scripts/teeth_lib.py (HYG-4). NOT
a gate and in no sweep: it edits the sh sources, rebuilds the play
image, runs the gate (or a slice of it) and requires every named row RED,
with the sabotaged sh.bin DIFFERING from the good one. It restores from
the captured bytes and the final rebuild must reproduce the good sh.bin.
T12 has no edit: it runs the gate's own `--selftest` (a planted leak the
buffer-counter check must name), so its clean-tree baseline is the same
gate part without the flag. Exit status: teeth_lib.py (0 all behaved,
1 a tooth did not bite, 2 runner broken).

  python3 scripts/teeth_shexecloop.py            # all
  python3 scripts/teeth_shexecloop.py T1 T4      # by name prefix
  python3 scripts/teeth_shexecloop.py --dry
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import teeth_lib as T  # noqa: E402

LX = 'src/bin/shlex.s'
V2 = 'src/bin/shvar2.s'
BL = 'src/bin/shbltn.s'
SB = 'src/bin/shsgblt.s'

G = 'python3 scripts/check_shexecloop.py'


# (name, gate command, [(file, old, new)], rows that must be red)
SPECS = [
 ('T1 the fix reverted: do CMD is refused again, its frame left pushed',
  G + ' --part a',
  [(V2, "RW_DO_FOR   stx   FORDOX",
    "RW_DO_FOR   lda   RW_HASRES\n            beq   :hok\n"
    "            lda   #1\n            sta   LASTSTATUS\n"
    "            jmp   MAINLOOP\n:hok        stx   FORDOX")],
  ['L3 ', 'L4 ', 'L5 ', 'X1 ', 'X2 ']),
 ('T2 the replay coordinate is off by three tokens (one is invisible: '
  'DO itself does nothing on a replay)',
  G + ' --part a --rows C',
  [(V2, "            lda   SEG_TOKI\n            sta   CSFORTOK,x",
    "            lda   SEG_TOKI\n            clc\n            adc   #3\n"
    "            sta   CSFORTOK,x")],
  ['C1 ', 'C5 ', 'C6 ']),
 ('T3 the first word is not assigned (RW_FOR)',
  G + ' --part a --rows L',
  [(V2, "            jmp   FOR_ASSIGN\n:noasg      rts",
    "            rts\n:noasg      rts")],
  ['L3 ', 'L4 ']),
 ('T4 the next word is not assigned before the seek (RW_DONE_FOR)',
  G + ' --part a --rows L',
  [(BL, "            jsr   FOR_ASSIGN             ;next word, BEFORE the\n",
    "            nop\n            nop\n            nop\n")],
  ['L1 ', 'L4 ']),
 ('T5 the replay does not start at the DO token (RP_TOK unused)',
  G + ' --part a --rows C',
  [(LX, "            beq   :seg\n            sta   TOKI\n",
    "            beq   :seg\n            nop\n            nop\n            nop\n")],
  ['C5 ', 'C7 ']),
 ('T6 RP_PEND never reaches RP_TOK',
  G + ' --part a --rows L',
  [(LX, "            lda   RP_PEND\n            sta   RP_TOK\n",
    "            lda   RP_PEND\n            nop\n            nop\n"
    "            nop\n")],
  ['L2 ', 'L4 ', 'L5 ']),
 ('T7 no second CHCK_RESERVED after THEN/ELSE/DO',
  G + ' --part a --rows N',
  [(LX, "            cmp   #8                     ;DO\n            bne   :ckskip",
    "            cmp   #8                     ;DO\n            bra   :ckskip")],
  ['N1 ', 'N3 ', 'N6 ']),
 ('T8 eval no longer enters through SH_RUNSTR',
  G + ' --part a --rows S1',
  [(SB, ":evpubd     jmp   SH_RUNSTR", ":evpubd     jmp   SH_RUNLINE")],
  ['S1 ']),
 ('T9 the signal pump no longer enters through SH_RUNSTR',
  G + ' --part a --rows S2',
  [(LX, "            jmp   SH_RUNSTR              ;a trap string is",
    "            jmp   SH_RUNLINE             ;a trap string is")],
  ['S2 ']),
 ('T10 the here-doc-before-DO refusal is gone',
  G + ' --part a --rows C9',
  [(V2, ":seekable   lda   HD_BEFORE\n            beq   :nohd",
    ":seekable   lda   #0\n            beq   :nohd")],
  ['C9 ']),
 ('T11 a here-doc capture does not set LN_HD',
  G + ' --part a --rows C9',
  [(BL, "            sta   LN_HD                  ;  after it: no replay",
    "            nop\n            nop\n            nop")],
  ['C9 ']),
 ('T12 the buffer-counter check (a planted leak must be named)',
  G + ' --part a --selftest', [],
  ['Z1 ']),
 ('T14 the BYTE-OFFSET coordinate (CS_MARKHEAD at the DO word, as '
  'WHILE does): right for plain ASCII lines, wrong after a '
  'backslash-newline or an alias before DO (ruling H2)',
  G + ' --part a --rows C',
  [(V2, ":nohd       txa\n            sta   CSTMP\n            clc\n"
    "            adc   CSTMP\n            clc\n"
    "            adc   CSTMP                      ;a = 3*x\n"
    "            tay\n            lda   LINE_MARK\n"
    "            sta   CSHEAD,y\n            lda   LINE_MARK+1\n"
    "            sta   CSHEAD+1,y\n            lda   LINE_MARK+2\n"
    "            sta   CSHEAD+2,y\n            lda   SEG_TOKI\n"
    "            sta   CSFORTOK,x\n",
    ":nohd       jsr   CS_MARKHEAD\n            lda   #0\n"
    "            sta   CSFORTOK,x\n")],
  ['C2b ', 'C5 ', 'C6 ']),
 ('T15 (review finding H1) a string source may read the callers lines again',
  G + ' --part a --rows S',
  [("src/bin/shtrap.s", ":spcont     lda   STR_SRC                ;a string ends with its\n            beq   :spnostr",
    ":spcont     lda   #0                     ;a string ends with its\n            beq   :spnostr")],
  ['S5 ', 'S6 ']),
 ('T16 (review finding M1) a second do revives a refused frame',
  G + ' --part a --rows C11',
  [(V2, ":fordead    rts                     ;dominated or poisoned:",
    ":fordead    ldx   FORDOX\n            stz   CSSKIP,x\n            rts"
    "                     ;dominated or poisoned:")],
  ['C11 ']),
 ('T17 (review) no one-spool-at-a-time guard',
  G + ' --part b --rows nested',
  [("src/bin/shtrap.s", "            beq   :spidle\n            jmp   SPOOL_DEEP",
    "            bra   :spidle\n            jmp   SPOOL_DEEP")],
  ['N1 ', 'N2 ']),
 ('T13 break leaves the frame skipping nothing (CSSKIP not set)',
  G + ' --part a --rows B',
  [("src/bin/shrsv2.s", ":dobreaknow lda   #1\n            sta   CSSKIP,x",
    ":dobreaknow lda   #0\n            sta   CSSKIP,x")],
  ['B1 ', 'B2 ']),
]


def tooth(name, cmd, edits, rows):
    rows = [r.strip() for r in rows]
    if '--selftest' in cmd:
        # Z1 exists only in the self-test's own (red) output, so it is
        # seen when it fails; the clean baseline is the gate without it
        return T.Tooth(name, checks=[T.Check(
            cmd, 'bullets_only', T.Rows(red=rows, rule=T.ANY),
            baseline=cmd.replace(' --selftest', ''))],
            witness=T.Intrinsic('the gate plants a leak in its own '
                                'buffer-counter check: no edit'))
    return T.Tooth(name, edits=edits, checks=[
        T.Check(cmd, 'devfs', T.Rows(red=rows))])


T.main('shexecloop', [tooth(*s) for s in SPECS],
       prep=T.Make('play-image'), artifacts=['build/sh.bin'])
