#!/usr/bin/env python3
"""teeth_shseq.py -- the sabotage runner behind check-shseq's teeth
(docs/SH-SEQ-NOTES.md), on scripts/teeth_lib.py (HYG-4). NOT a gate and
in no sweep: it edits the sh sources, rebuilds the play image, runs the
WHOLE gate (so every declared control row actually runs) expecting RED
on the named rows and GREEN on the control rows, with the sabotaged
sh.bin DIFFERING from the good one. A pattern is a literal, or `re:` + a
regex that must hit exactly once. It restores from the captured bytes
(never `git checkout`) and the final rebuild must reproduce the good
sh.bin. TG1 (SH-G21) is a HOST-script sabotage: no rebuild, sh.bin is
untouched by construction. Exit status: teeth_lib.py (0 all behaved,
1 a tooth did not bite, 2 runner broken).

  python3 scripts/teeth_shseq.py            # all
  python3 scripts/teeth_shseq.py TA1 TA3    # by name prefix
  python3 scripts/teeth_shseq.py --dry
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import teeth_lib as T  # noqa: E402

LX = 'src/bin/shlex.s'
R2 = 'src/bin/shrsv2.s'
BL = 'src/bin/shbltn.s'
R1 = 'src/bin/shresv.s'
TK = 'src/bin/shtok.s'
V2 = 'src/bin/shvar2.s'
S2 = 'src/bin/shsub2.s'
TR = 'src/bin/shtrap.s'

MQ = 'scripts/check_shmlquote.py'

G = 'python3 scripts/check_shseq.py'
GB = G + ' --rows B'
GC = G + ' --part a --rows '


# (name, gate command, [(file, old, new)], rows that must be red,
#  rows that must stay green)
SPECS = [
 # ---- phase A -------------------------------------------------------
 ('TA1 the fix reverted: sh -c enters through SH_RUNLINE again',
  G,
  [(LX, "never reads the caller's stdin).\n            jmp   SH_RUNSTR\n",
    "never reads the caller's stdin).\n            jmp   SH_RUNLINE\n")],
  ['A2 ', 'A3 ', 'A4 ', 'A5 ', 'A6 ', 'A7 ', 'A9 '],
  ['A1 ', 'A8 ']),
 ('TA2 the stale cell is back: SH_RUNSTR no longer clears LMARK_OK',
  G,
  [(LX, "SH_RUNSTR   stz   LMARK_OK\n",
    "SH_RUNSTR   nop\n            nop\n            nop\n")],
  ['A2 ', 'A3 ', 'A4 ', 'A5 ', 'A6 ', 'A7 '],
  ['A1 ', 'A8 ']),
 ('TA3 sh -c is not a string source: SH_RUNSTR no longer sets STR_SRC',
  G,
  [(LX, "            lda   #1\n            sta   STR_SRC\n"
    "            jmp   SH_RUNLINE\n",
    "            nop\n            nop\n            nop\n            nop\n"
    "            nop\n            jmp   SH_RUNLINE\n")],
  ['A9 '],
  ['A1 ', 'A2 ', 'A3 ', 'A4 ']),
 # ---- phase B -------------------------------------------------------
 ('TB1 the residual after `in` is discarded again (the old RW_CASE)',
  GB,
  [(R2, "            jsr   RW_SHIFT\n            jmp   RW_SHIFT\n",
    "            stz   RW_HASRES\n            rts\n")],
  ['B1 ', 'B4 ', 'B5 ', 'B6 ', 'B7 ', 'B8 ', 'B13 ', 'B20 ',
   'B21 ', 'B22 ', 'B23 '],
  # B3 (the first pattern misses, the second hits) worked on the old
  # code too: the second pattern follows a `;;`, never the residual
  ['B2 ', 'B3 ', 'B24 ', 'B27 ']),
 ('TB1b the same, seen by check_shfd C10 (one-line esac <&3)',
  'python3 scripts/check_shfd.py --rows C10',
  [(R2, "            jsr   RW_SHIFT\n            jmp   RW_SHIFT\n",
    "            stz   RW_HASRES\n            rts\n")],
  ['C10 '], []),
 ('TB1c the same, seen by check-shlang (appended CASEL rows)',
  'make check-shlang',
  [(R2, "            jsr   RW_SHIFT\n            jmp   RW_SHIFT\n",
    "            stz   RW_HASRES\n            rts\n")],
  ['RESULTS expected'], []),
 ('TB2 CASE is not routed to the pattern test after a reserved word',
  GB,
  [(LX, "            cmp   #11                    ;SH-SEQ B: CASE's\n"
    "            bne   :wr2",
    "            cmp   #11                    ;SH-SEQ B: CASE's\n"
    "            bra   :wr2")],
  ['B1 ', 'B4 ', 'B20 ', 'B23 '],
  ['B2 ', 'B3 ', 'B24 ']),
 # TB3 (a nested CASE's residual after a pattern kept unread) is RETIRED
 # by SH-CASE2 B: a pattern is a segment of its own now, so the
 # `:ptnonempt` path it sabotaged no longer exists (deleted, -16 B).
 # B21b/B26 still guard the nesting, through TK-family teeth.
 ('TB4 a case with no match leaves $? alone',
  GB,
  [(R2, "            beq   :zero                  ;no match\n",
    "            beq   :no                    ;no match\n")],
  ['B9 ', 'B26 '],
  ['B10 ', 'B12 ']),
 ('TB5 a command running does not clear CASE_EMPTY',
  GB,
  [(LX, ":csskipok   stz   CASE_EMPTY             ;SH-SEQ B\n",
    ":csskipok   nop\n            nop\n            nop\n")],
  ['B12 ', 'B26 ', 'B27 '],
  ['B9 ', 'B1 ']),
 ('TB6 a match does not set CASE_EMPTY (an empty clause keeps $?)',
  GB,
  [(R2, "            sta   CASE_EMPTY             ;SH-SEQ B\n",
    "            nop\n            nop\n            nop\n")],
  ['B26 ', 'B27 '],
  ['B9 ', 'B12 ']),
 ('TB7 a head skipped by && still matches and ESAC clobbers $?',
  GB,
  [(R2, "            ror   a                      ;$80 if SH_SKIP\n",
    "            lda   #0                     ;$80 if SH_SKIP\n")],
  ['B12b ', 'B12c ', 'B25 ', 'B26 '],
  ['B1 ', 'B9 ']),
 ('TB8 set -e never fires inside a construct (the E6 pin bites, E1 too)',
  G + ' --rows E',
  [(BL, "            lda   CSPTR\n            beq   :ret\n"
    "            tax\n            dex\n            lda   CSCOND,x\n",
    "            lda   CSPTR\n            beq   :ret\n"
    "            lda   #1\n")],
  ['E1 ', 'E6 '],
  ['E2 ', 'E5 ']),
 # ---- phase C -------------------------------------------------------
 ('TC1 the remainder is never saved (DOT_SAVE copies nothing)',
  GC + 'C',
  [(BL, "            cpx   NTOK\n            bcs   :nul\n",
    "            cpx   NTOK\n            bra   :nul\n")],
  ['C1 ', 'C2 ', 'C2d ', 'C3 ', 'C4 ', 'C6c '],
  ['C5 ', 'C6 ']),
 ('TC2 H1: NEXT_SKIP is not run at resume (&& / || ignored)',
  GC + 'C2',
  [(LX, ":nds        jsr   NEXT_SKIP\n            stz   SEG_FIRST\n:nocont",
    ":nds        nop\n            nop\n            nop\n"
    "            stz   SEG_FIRST\n:nocont")],
  ['C2 ', 'C2c '], ['C2b ', 'C1 ', 'C2d ']),
 ('TC2b H1: the ordinary SH_SKIP=0 init runs AFTER the hook',
  GC + 'C2',
  [(LX, "            stz   SEG_FIRST\n:nocont",
    "            stz   SEG_FIRST\n            stz   SH_SKIP\n:nocont")],
  ['C2 ', 'C2c '], ['C2b ', 'C1 ', 'C2d ']),
 ('TC3 the ;; of the .  segment is never replayed',
  GC + 'C6',
  [(LX, "            jsr   RW_DSEMI\n:nds        jsr   NEXT_SKIP",
    "            nop\n            nop\n            nop\n"
    ":nds        jsr   NEXT_SKIP")],
  ['C6 ', 'C6b '], ['C1 ', 'C6c ']),
 ('TC4 no EOF unwind (X leaves its frames open)',
  GC + 'C5',
  [(BL, "            beq   :clean\n            jsr   CONT_UNWIND\n",
    "            beq   :clean\n            nop\n            nop\n"
    "            nop\n")],
  ['C5 ', 'C5b ', 'C5c ', 'C5d ', 'C5e ', 'C5f '], ['C1 ']),
 ('TC5 H2: the floor is gone from RW_FI',
  GC + 'F1',
  [(R1, "RW_FI       lda   CSPTR\n            cmp   CS_FLOOR"
    "               ;C floor\n",
    "RW_FI       lda   CSPTR\n            nop\n            nop\n"
    "            nop\n")],
  ['F1 '], ['F2 ', 'F7 ']),
 ('TC5b H2: the floor is gone from RW_DONE',
  GC + 'F2',
  [(R1, "RW_DONE     lda   CSPTR\n            cmp   CS_FLOOR"
    "               ;C floor\n",
    "RW_DONE     lda   CSPTR\n            nop\n            nop\n"
    "            nop\n")],
  ['F2 '], ['F1 ', 'F7 ']),
 ('TC5c H2: the floor is gone from CS_FINDLOOP (break/continue)',
  GC + 'F',
  [(R2, ":loop       cpy   CS_FLOOR               ;C floor\n",
    ":loop       cpy   #0\n")],
  ['F3 ', 'F4 '], ['F1 ', 'F2 ']),
 ('TC5d H2: the floor is gone from RW_ESAC',
  GC + 'F5',
  [(R2, "RW_ESAC     lda   CSPTR\n            cmp   CS_FLOOR"
    "               ;C floor\n",
    "RW_ESAC     lda   CSPTR\n            nop\n            nop\n"
    "            nop\n")],
  ['F5 '], ['F1 ', 'F6 ']),
 ('TC5e H2: the floor is gone from RW_DSEMI',
  GC + 'F6',
  [(R2, "RW_DSEMI    lda   CSPTR\n            cmp   CS_FLOOR"
    "               ;C floor\n",
    "RW_DSEMI    lda   CSPTR\n            nop\n            nop\n"
    "            nop\n")],
  ['F6 '], ['F1 ', 'F5 ']),
 ('TC6 H3: the unwound status 2 skips the errexit decision',
  GC + 'E1',
  [(BL, "            sta   PARSE_SEPOP\n            jsr   ERREXIT_CK\n",
    "            sta   PARSE_SEPOP\n            nop\n            nop\n"
    "            nop\n")],
  ['E16 '], ['E17 ', 'E10 ']),
 ('TC7 H4 pin: every . suppresses errexit (the E18 pin and E10 bite)',
  GC + 'E1',
  [(BL, "            jsr   EE_TESTED\n            beq   :cpy0\n",
    "            jsr   EE_TESTED\n            nop\n            nop\n")],
  ['E10 ', 'E18 '], ['E11 ', 'E15 ']),
 ('TC8 the errexit suppression is never restored at the pop',
  GC + 'E1',
  [(BL, "            sta   EE_SUPP\n            iny\n"
    "            lda   (PTR1),y\n            sta   STR_SRC",
    "            nop\n            nop\n            nop\n            iny\n"
    "            lda   (PTR1),y\n            sta   STR_SRC")],
  ['E15 '], ['E11 ', 'E10 ']),
 ('TC9 M1: a successful . leaves the old status',
  GC + 'M1',
  [(BL, "            stz   LASTSTATUS             ;an empty file is 0\n",
    "            nop\n            nop\n            nop\n")],
  ['M1 '], ['C1 ']),
 ('TC10 M2: SH_EOF prints its scan message for a . file too',
  GC + 'C5',
  [(LX, "            lda   SRC_DEPTH\n            bne   :noscan\n"
    "            lda   #<CSEOF_MSG",
    "            lda   SRC_DEPTH\n            nop\n            nop\n"
    "            lda   #<CSEOF_MSG")],
  ['C5 ', 'C5d ', 'C5e ', 'C5f '], ['C1 ', 'C3 ']),
 ('TC11 M3: an aliased line does not refuse a loop in the remainder',
  GC + 'A',
  [(LX, "            bcc   :nali\n            stz   ALI_MINPOS\n",
    "            bra   :nali\n            stz   ALI_MINPOS\n")],
  ['A3 '], ['A4 ', 'A1 ']),
 ('TC12 the resumed text goes through the alias pass again',
  GC + 'A',
  [(LX, "            bne   :alidone               ;  remainder: done\n",
    "            nop\n            nop\n")],
  ['A1 '], ['A4 ', 'A3 ']),
 ('TC13 M4: a here-doc in a string source reads the caller',
  GC + 'M4',
  [(BL, "            lda   STR_SRC\n            beq   :notstr\n",
    "            lda   STR_SRC\n            bra   :notstr\n")],
  ['M4 ', 'M4b '], ['H1 ', 'H2 ']),
 ('TC14 STR_SRC is not restored at resume (-c remainder reads stdin)',
  GC + 'S',
  [(BL, "            sta   STR_SRC\n            iny\n"
    "            lda   (PTR1),y\n            sta   CS_FLOOR",
    "            nop\n            nop\n            nop\n            iny\n"
    "            lda   (PTR1),y\n            sta   CS_FLOOR")],
  ['S3 '], ['S1 ', 'C1 ']),
 ('TC15 LMARK_OK is not cleared: a loop in the remainder seeks',
  GC + 'L',
  [(BL, "            stz   LMARK_OK               ;a loop here must spool\n",
    "            nop\n            nop\n            nop\n")],
  ['L5 '], ['L4 ', 'L1 ']),
 ('TC16 TOKENIZE records no raw offsets',
  GC + 'A',
  [(TK, "            ldx   NTOK                   ;SH-SEQ C: raw offset,\n"
    "            sta   TOKOFF,x               ;  PRETOK's index\n",
    "            nop\n            nop\n            nop\n            nop\n"
    "            nop\n            nop\n")],
  ['A5 ', 'A6 '], []),
 ('TC17 PRETOK is never filled',
  GC + 'A',
  [(LX, "            lda   #<PRETOK\n            ldx   #>PRETOK\n"
    "            jsr   LB_COPY\n",
    "            lda   #<PRETOK\n            ldx   #>PRETOK\n"
    "            nop\n            nop\n            nop\n")],
  ['A5 ', 'A6 '], []),
 ('TC18 the floor is not put back at the pop',
  GC + 'F1',
  [(BL, "            sta   CS_FLOOR\n            ldy   #0\n",
    "            nop\n            nop\n            nop\n            ldy   #0\n")],
  ['F1 ', 'F2 ', 'F7 '], ['C1 ']),
 ('TC20 review finding M1: a match under a skipping ancestor sets CASE_EMPTY',
  GC + 'N',
  [(R2, "            jsr   CS_EFFSKIP\n            bne   :shift\n"
    "            lda   #1\n            sta   CASE_EMPTY",
    "            nop\n            nop\n            nop\n"
    "            nop\n            nop\n            lda   #1\n"
    "            sta   CASE_EMPTY")],
  ['N1 ', 'N2 ', 'N3 '], ['B26 ', 'B27 ']),
 ('TC21 review finding M2: CONT_SEP is published before errexit can leave',
  GC + 'N',
  [(BL, "            sta   PARSE_SEPOP\n            jsr   ERREXIT_CK\n",
    "            sta   PARSE_SEPOP\n            sta   CONT_SEP\n"
    "            jsr   ERREXIT_CK\n")],
  ['N4 ', 'N5 '], ['C5 ', 'E16 ']),
 # ---- SH-CASE2 phase A ---------------------------------------------
 ('TQ1 CS_POPLIVE ignores the ancestors (a dead nested construct zeroes)',
  G,
  [(R1, "CS_POPLIVE  jsr   CS_EFFSKIP\n            bne   :r\n",
    "CS_POPLIVE  jsr   CS_EFFSKIP\n            nop\n            nop\n")],
  ['Q16 ', 'Q16b ', 'Q16c '],
  ['Q1 ', 'Q9 ', 'Q10 ', 'Q17g ']),
 ('TQ2 RW_IF records no dead head (CSSKIP/CSTAKEN from SH_SKIP)',
  G,
  [(R1, "            lda   SH_SKIP                ;SH-CASE2 A: a head\n",
    "            lda   #0                     ;SH-CASE2 A: a head\n")],
  ['Q17 ', 'Q17b '],
  ['Q1 ', 'Q17g ', 'Q17c ', 'Q17e ']),
 ('TQ2b a loop head records no dead head in CSTAKEN',
  G,
  [(R1, "            lda   SH_SKIP\n            sta   CSTAKEN,x              ;every path",
    "            lda   #0\n            sta   CSTAKEN,x              ;every path")],
  ['Q17c ', 'Q17d ', 'QT6b '],
  ['Q9 ', 'Q17g ', 'Q17 ', 'Q17e ']),
 ('TQ2c RW_FOR records no dead head',
  G,
  [(V2, "            lda   SH_SKIP                ;SH-CASE2 A: dead head,\n",
    "            lda   #0                     ;SH-CASE2 A: dead head,\n")],
  ['Q17e ', 'Q17f ', 'QT6 '],
  ['Q17g ', 'Q10 ', 'Q17 ']),
 ('TQ2d a loop head skipped by &&/|| still spools when typed',
  G,
  [(R1, "            ora   SH_SKIP                ;SH-CASE2 A: or a head\n",
    "            nop\n            nop\n            nop\n")],
  ['QT6b '],
  ['Q17d ', 'Q17c ', 'QT2 ']),
 ('TQ2e a for head skipped by &&/|| still spools when typed',
  G,
  [(V2, "            ora   SH_SKIP                ;SH-CASE2 A: a skipped\n",
    "            nop\n            nop\n            nop\n")],
  ['QT6 '],
  ['Q17f ', 'Q17e ', 'QT3 ']),
 ('TQ2f a brace group whose head was skipped runs',
  G,
  [(R1, "            ora   SH_SKIP                ;SH-CASE2 A: a skipped\n"
    "            sta   CSTMP3                 ;  head is dead too\n",
    "            nop\n            nop\n            nop\n"
    "            sta   CSTMP3                 ;  head is dead too\n")],
  ['Q17h '],
  ['Q17 ', 'Q17c ']),
 ('TQ3 an elif whose condition ran marks the if taken',
  G,
  [(R1, ":fresh      stz   CSSKIP,x\n            lda   #1\n"
    "            sta   CSCOND,x               ;`set -e`: a fresh elif",
    ":fresh      stz   CSSKIP,x\n            lda   #1\n"
    "            sta   CSTAKEN,x\n"
    "            sta   CSCOND,x               ;`set -e`: a fresh elif")],
  ['Q2 ', 'Q5b '],
  ['Q1 ', 'Q3 ']),
 ('TQ4a an empty for list does not publish 0',
  G,
  [(BL, "            stz   LASTSTATUS\n:done       rts\n:formore",
    "            nop\n            nop\n            nop\n:done       rts\n:formore")],
  ['Q10 ', 'QT3 ', 'QT3b ', 'Q18 '],
  ['Q10b ', 'Q10c ', 'Q9 ']),
 ('TQ4b a for that ran publishes 0 too (no CSFORCNT test)',
  G,
  [(BL, "            lda   CSFORCNT,x             ;  (else the last\n"
    "            bne   :done                  ;  status stands)\n",
    "            nop\n            nop\n            nop\n"
    "            nop\n            nop\n")],
  ['Q10b '],
  ['Q10 ', 'Q10c ']),
 ('TQ5a the body status is not handed across the pop and re-push',
  G,
  [(R2, "            sta   LP_PEND                ;  status rides along\n",
    "            nop\n            nop\n            nop\n")],
  ['Q7 ', 'Q8 ', 'Q19 ', 'QT4 ', 'QT5 '],
  ['Q6 ', 'Q9 ']),
 ('TQ5b the final done zeroes the status (C-H1: the stateless design)',
  G,
  [(R1, "            lda   CSLPSTAT,x             ;  0 if no body ran\n",
    "            lda   #0\n            nop                          ;"
    "  0 if no body ran\n")],
  ['Q7 ', 'Q8 ', 'Q19 ', 'QT4 ', 'QT5 '],
  ['Q6 ', 'Q9 ']),
 ("TQ6 a fresh loop inherits the last loop's status (LP_PEND kept)",
  G,
  [(R1, "            stz   LP_PEND                ;  a fresh loop)\n",
    "            nop\n            nop\n            nop\n")],
  ['Q19d '],
  ['Q19c ', 'Q9 ', 'Q7 ']),
 ('TQ7 break does not store its 0 in the frame',
  G,
  [(R2, "            stz   CSLPSTAT,x             ;SH-CASE2 A: the loop\n"
    "                                         ;  ends with status 0\n",
    "            nop\n            nop\n            nop\n")],
  ['Q13b '],
  ['Q13 ', 'Q15 ']),
 ('TQ8 continue zeroes the status AFTER the handoff filed the old one',
  G,
  [(R2, ":docontinue stx   CSN2\n            stz   LASTSTATUS             ;before the handoff,\n"
    "                                         ;  which files it\n",
    ":docontinue stx   CSN2\n"),
   (R2, "            sta   CSPTR\n            jmp   CS_GOHEAD",
    "            sta   CSPTR\n            stz   LASTSTATUS\n"
    "            jmp   CS_GOHEAD")],
  ['Q14 '],
  ['Q13b ', 'Q13 ']),
 ('TQ9a the scan pass of an if publishes (FI rescan path)',
  G,
  [(R1, ":rescan     jmp   CR_RESCAN\n:err        jmp   RW_SYNTAXERR\n\n"
    "*---------------------------------------------------------------\n"
    "* RW_DO -- close",
    ":rescan     stz   LASTSTATUS\n            jmp   CR_RESCAN\n"
    ":err        jmp   RW_SYNTAXERR\n\n"
    "*---------------------------------------------------------------\n"
    "* RW_DO -- close")],
  ['Q21 '],
  ['Q21d ', 'Q1 ']),
 ('TQ9b the scan pass of a loop publishes (DONE rescan path)',
  G,
  [(R1, ":rescan     jmp   CR_RESCAN\n:isloop     jsr   CS_EFFSKIP",
    ":rescan     stz   LASTSTATUS\n            jmp   CR_RESCAN\n"
    ":isloop     jsr   CS_EFFSKIP")],
  ['Q21b ', 'Q21c '],
  ['Q21 ', 'Q21d ']),
 ('TQ10 RW_DO ignores the dead head (the condition alone decides)',
  G,
  [(R1, ":store      ora   CSTAKEN,x              ;SH-CASE2 A: dead head\n",
    ":store      nop\n            nop\n            nop\n")],
  ['Q17d ', 'QT6b '],
  ['Q17c ', 'Q17 ', 'Q9 ']),
 ('TQ11 CS_POPLIVE does not read CSTAKEN (a taken if or dead head zeroes)',
  G,
  [(R1, "            lda   CSTAKEN,x\n:r          rts\n",
    "            lda   #0\n:r          rts\n")],
  ['Q3 ', 'Q5 ', 'Q5b ', 'Q17 ', 'Q17c ', 'Q17e '],
  ['Q1 ', 'Q9 ', 'Q10 ']),
 # ---- SH-CASE2 phase B --------------------------------------------
 ('TK1 split EVERYWHERE: PAT_CHECK says yes whenever a `)` was recorded',
  G,
  [(S2, "PAT_CHECK   ldx   TOKI\n            lda   TOKCP,x\n",
    "PAT_CHECK   ldx   TOKI\n            lda   TOKCP,x\n"
    "            beq   :no\n            sec\n            rts\n")],
  ['K30 ', 'K31 ', 'K33 '],
  ['K1 ', 'K1b ', 'K25 ']),
 ('TK2 ignore quotes: a double-quoted `)` is recorded as the terminator',
  G,
  [(TK, "            iny\n            bra   :qloop2\n:qesc2      iny",
    "            iny\n            jsr   SUB_TRKCH\n            bra   :qloop2\n"
    ":qesc2      iny")],
  ['K20 '],
  ['K1b ', 'K22 ', 'K21 ']),
 ('TK3 ignore spans: a `$( )` span\'s `)` is recorded at any depth',
  G,
  [(TK, "re:            beq   :cand [^\\n]*\\n            cmp   #1",
    "            bra   :cand\n            cmp   #1")],
  ['K22 '],
  ['K1b ', 'K4b ', 'K20 ']),
 ('TK4 drop the leading-`(` skip: the pattern keeps its paren',
  G,
  [(S2, "            lda   CPOFF\n            bne   :nolead\n",
    "            lda   CPOFF\n            bra   :nolead\n")],
  ['K4 ', 'K4b ', 'K4c ', 'K4d '],
  ['K1 ', 'K23 ', 'K23b ']),
 ('TK5 a quoted `(` loses its meaning: the lead test reads the squeezed byte',
  G,
  [(S2, "re:            lda   PRETOK,y[^\\n]*\\n",
    "            lda   LINEBUF,y\n")],
  ['K23 ', 'K23b '],
  ['K4 ', 'K4b ', 'K1 ']),
 ('TK6 TOK_ENDPAR back to the last-byte rule: `a|b)echo` is a pipeline',
  G,
  [(TK, "re:            cpx   #0\\n            beq   :yes[^\\n]*\\n",
    "            cpx   #0\n            nop\n            nop\n")],
  ['K2 ', 'K4 ', 'KT3 '],
  ['K1 ', 'K4b ', 'K25 ', 'K25b ']),
 ('TK7 no frame test: a first word with a `)` is a pattern anywhere',
  G,
  [(S2, ":first      jmp   CS_CASEBTW",
    ":first      sec\n            rts\n            jmp   CS_CASEBTW")],
  ['K33 '],
  ['K1 ', 'K30 ', 'K31 ']),
 ('TK8 CS_CASEPAT does not look at SEP_PAT: every segment is a pattern',
  G,
  [(R2, "re:            cmp   #SEP_PAT[^\\n]*\\n            bne   :no[^\\n]*\\n"
    "            jsr   CS_CASEBTW",
    "            nop\n            nop\n            nop\n            nop\n"
    "            jsr   CS_CASEBTW")],
  ['K8b '],
  ['K8 ', 'K1 ', 'K30 ']),
 ('TK9 the pattern goes through GLOB_APPEND (expanded against the dir)',
  G,
  [(S2, ":raw        jsr   APPEND_RAW", ":raw        jsr   GLOB_APPEND")],
  ['K1 ', 'K2 ', 'K3 ', 'K7b ', 'K24 '],
  ['K1b ', 'K5 ', 'K10 ']),
 ('TK9b the pattern goes through UNESC (a quoted glob char regains meaning)',
  G,
  [(S2, ":raw        jsr   APPEND_RAW", ":raw        jsr   APPEND_ARGV")],
  ['K24 '],
  ['K7b ', 'K1 ']),
 ('TK10 the remainder is not repointed (TOKPTR keeps the cut token)',
  G,
  [(S2, "re:            sta   TOKPTR,x[^\\n]*\\n            lda   PTR0\\+1[^\\n]*\\n"
    "            adc   #0\\n            sta   TOKPTR\\+1,x\\n",
    "            nop\n            nop\n            nop\n            lda   PTR0+1\n"
    "            adc   #0\n            nop\n            nop\n            nop\n")],
  ['K1 ', 'K1b ', 'K5 '],
  ['K30 ', 'K33 ']),
 ('TK11 an empty remainder does not move TOKI on (`x)` alone on a line)',
  G,
  [(S2, "re:            inc   TOKI[^\\n]*\\n:more",
    "            nop\n            nop\n:more")],
  ['K5 ', 'K10 '],
  ['K1 ', 'K1b ']),
 ('TK12 :segdone clears SEG_FIRST after a pattern segment (sec 18 scan)',
  G,
  [(LX, "re:            cmp   #SEP_PAT[^\\n]*\\n            beq   :segkeep",
    "            cmp   #SEP_PAT\n            nop\n            nop")],
  ['K12 '],
  ['K1 ', 'K5 ']),
 ('TK13 M1: `&&` after a pattern is dropped, not refused',
  G,
  [(S2, "PAT_NOEMPTY lda   PARSE_SEPOP\n            cmp   #SEP_PAT\n            bne   :ok",
    "PAT_NOEMPTY lda   PARSE_SEPOP\n            cmp   #SEP_PAT\n            bra   :ok")],
  ['K26 ', 'K26b '],
  ['K10 ', 'K1 ']),
 ('TK14 M2: a quoted `case`/`in` opens a case through the argv rule',
  G,
  [(S2, "re:            ora   TOKQUOTE,x\\n            bne   :reload",
    "            ora   TOKQUOTE,x\n            nop\n            nop")],
  ['K27 '],
  ['K1 ', 'K5 ']),
 ('TK15 H1: TOK_ENDPAR has no stop set (a quoted `)` keeps the `|` content)',
  G,
  [(TK, "re::nxt        cmp   #ALC_A7[^\\n]*\\n            beq   :stop\\n"
    "            cmp   #ALC_A2[^\\n]*\\n            beq   :stop\\n"
    "            cmp   #ALC_DC[^\\n]*\\n            beq   :stop\\n"
    "            cmp   #ALC_A4[^\\n]*\\n            bne   :adv[^\\n]*\\n",
    ":nxt        bra   :adv\n")],
  ['K25b ', 'K25c ', 'K25d '],
  ['K25 ', 'K2 ']),
 ('TK15b H2: `$` is not a stop (a `$(` span keeps the `|` content)',
  G,
  [(TK, "re:            cmp   #ALC_A4[^\\n]*\\n            bne   :adv[^\\n]*\\n:stop",
    "            bra   :adv\n:stop")],
  ['K25d '],
  ['K25b ', 'K25c ', 'K2 ']),
 ('TK16a H2: the pattern half of a seeded group token stays literal',
  G,
  [(S2, ":nl2        stz   CURQFLAG",
    ":nl2        nop\n            nop\n            nop")],
  ['K4c '],
  ['K4d ', 'K4 ']),
 ('TK16b H2: the remainder of a seeded group token stays literal',
  G,
  [(S2, "            ldx   TOKI\n            stz   TOKQUOTE,x\n:nolead",
    "            ldx   TOKI\n            nop\n            nop\n            nop\n"
    ":nolead")],
  ['K4d '],
  ['K4c ', 'K4 ']),
 ('TK17 H3: a backslash before a spooled head is not refused',
  G,
  [(TR, "re:            cmp   #ALC_DC[^\\n]*\\n            beq   :spquotd[^\\n]*\\n"
    "            iny",
    "            iny")],
  ['KT5 '],
  ['KT4 ', 'KT1 ']),
 ('TK18 M4: SPOOL_SPLIT loses `;;` again',
  G,
  [(TR, "re:            cmp   #OPC_SEMI\\n            bne   :splw1\\n"
    "            ldy   SPOOL_CUR",
    "            cmp   #OPC_SEMI\n            bra   :splw1\n"
    "            ldy   SPOOL_CUR")],
  ['K50 '],
  ['K1 ', 'K9 ']),
 # ---- the review of 4f306140 ---------------------------------
 ('TK19 H1: the pump never hides a pending loop-back from a trap',
  G,
  [(TR, "re:            beq   :nohide[^\\n]*\\n", "            bra   :nohide\n")],
  ['Q22 ', 'Q22c ', 'Q22d '],
  ['Q22b ', 'K1 ']),
 ('TK19b H1: ...or never puts it back',
  G,
  [(TR, "re:            bne   :nosv[^\\n]*\\n            lda   TRAPSV_LP",
    "            bra   :nosv\n            lda   TRAPSV_LP")],
  ['Q22 ', 'Q22b ', 'Q22c ', 'Q22d '],
  ['K1 ', 'Q7 ']),
 ('TK21 H3: PAT_CHECK has no NCMD test (a pattern in a later stage)',
  G,
  [(S2, "            lda   NCMD\n            bne   :no",
    "            nop\n            nop\n            nop\n            nop\n            nop")],
  ['K28 '],
  ['K1 ', 'K5 ']),
 ('TK22 M1: `|` right after a pattern is not refused',
  G,
  [(S2, ":pipe       jsr   PAT_NOEMPTY\n",
    ":pipe       nop\n            nop\n            nop\n")],
  ['K26c '],
  ['K26 ', 'K26b ', 'K1 ']),
 ('TK23 M2: a bare `)` first is not refused',
  G,
  [(S2, "re:            cmp   #1[^\\n]*\\n            beq   :bad",
    "            cmp   #1\n            nop\n            nop")],
  ['K44b '],
  ['K44 ', 'K45 ', 'K1 ']),
 ('TK24 M2: `()` is not refused',
  G,
  [(S2, "re:            cmp   #ALC_A9[^\\n]*\\n            bne   :ok\\n:bad",
    "            cmp   #ALC_A9\n            bra   :ok\n:bad")],
  ['K44 '],
  ['K44b ', 'K45 ', 'K1 ']),
 ('TK25 M2: offsets are 0-based again (a `)` at offset 0 is "none")',
  G,
  [(TK, "re:            sec  [^\\n]*offset \\+ 1: 0 = none\\n", "            clc\n"),
   (S2, "re:            dey  [^\\n]*offset of the `\\)`\\n", "")],
  ['K45 ', 'K44b '],
  ['K1 ', 'K4 ', 'K44 ']),
 # ---- SH-G21 stream: the oracle rig (a HOST-script sabotage: no sh
 # rebuild, sh.bin is unchanged by construction) ---------------------
 ('TG1 the dash shim is back: a script row\'s `sh` runs dash under '
  'either host shell, so bash 5 is never asked',
  G,
  [(MQ, "fh.write('sh() { %s \"$@\"; }\\n' % shell)",
    "fh.write('sh() { %s \"$@\"; }\\n' % F.DASH)")],
  ['RIG selftest'],
  []),
 ('TC19 a . frame is popped like a spool frame (no continuation)',
  GC + 'C',
  [(LX, "            plp\n            bne   :dotpop ",
    "            plp\n            nop\n            nop\n ")],
  ['C1 ', 'C2 ', 'C5 '], []),
]


SHSEQ = 'python3 scripts/check_shseq.py'      # always the whole gate


def edit(fn, old, new):
    if old.startswith('re:'):
        return T.Edit(fn, old[3:], new, regex=True)
    return T.Edit(fn, old, new)


def tooth(name, cmd, edits, rows, greens):
    rows = [r.strip() for r in rows]
    greens = [g.strip() for g in greens]
    edits = [edit(*e) for e in edits]
    if 'check_shseq' in cmd:
        host = bool(edits) and all(e.file.startswith('scripts/')
                                   for e in edits)
        if host:                      # TG1: the rig canary, a failure row
            chk = T.Check(SHSEQ, 'aggregate', T.Aggregate(
                r'^\[check-shseq\] FAIL: RIG selftest',
                'the canary is a single FAIL line, before any row'))
            return T.Tooth(name, edits=edits, checks=[chk],
                           witness=T.SourceOnly(), prep=T.NoBuild(),
                           artifacts=())
        chk = T.Check(SHSEQ, 'devfs', T.Rows(red=rows, controls=greens))
    elif 'check_shfd' in cmd:
        chk = T.Check(cmd, 'devfs', T.Rows(red=rows))
    else:                              # make check-shlang: one RESULTS file
        chk = T.Check(cmd, 'aggregate', T.Aggregate(
            r'^\[check-shlang[a-z-]*\] FAIL: RESULTS expected',
            'check-shlang compares one RESULTS file: an aggregate verdict'),
            tag='re:check-shlang(?:-[a-z]+)?')
    return T.Tooth(name, edits=edits, checks=[chk])


T.main('shseq', [tooth(*s) for s in SPECS],
       prep=T.Make('play-image'), artifacts=['build/sh.bin'])
