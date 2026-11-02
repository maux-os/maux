*---------------------------------------------------------------
* expr.match.s -- expr's `:` matching operator (XCU: "expr1 :
* expr2 -- the string resulting from the evaluation of expr1 is
* compared with the regular expression pattern resulting from
* the evaluation of expr2"). SHIPPED 2026-10-08,
* docs/POSIX-REGEXLINK.md. One assembly stream: `put` by
* src/bin/expr.s right after expr.ops.s, and NOT by the
* src/test/exprtest.s harness (which stubs EX_COL -- the kernel-
* image test has no business linking the 66 KB regex engine, and
* a stub that is `jmp EX_PRIM` keeps its 37 rows byte-for-byte
* what they were).
*
* GRAMMAR. `:` binds TIGHTER than `*` `/` `%` (XCU lists it
* first in the precedence table), so it is a new level BELOW
* EX_MUL: EX_MUL now calls EX_COL where it called EX_PRIM, and
* EX_COL is "an operand, then any number of `: operand`", left
* associative. Nothing else in the grammar moved.
*
* SEMANTICS (measured on the Mac's BSD expr and the box's GNU
* expr, which agree on every row the gate keeps host-oracled --
* docs/POSIX-REGEXLINK-NOTES.md has the table):
*  - The match is ANCHORED at the first byte of the left string.
*    RE_MATCH is the unanchored searcher, so the result is
*    accepted only when it started at the string's first byte:
*    leftmost means that is exactly the anchored answer (a match
*    at byte 0 beats any later one), and it costs no copy of the
*    pattern to prepend a `^`. A pattern that STARTS with `^` is
*    taken as written -- BSD and GNU both read a leading `^` as
*    the (redundant) anchor, not as a second, literal one.
*  - No \( \) in the pattern: the result is the match LENGTH, a
*    number (0 when there is no match; exit status 1 then).
*  - A \( \) in the pattern: the result is the text of the FIRST
*    group, a string -- empty when nothing matched or the group
*    took no part in the match (exit status 1, null result).
*    The text is NUL-terminated IN PLACE in the left string (the
*    argv memory is this process's own), so there is no result
*    buffer to overflow: a group of any length prints whole. A
*    group that is a canonical decimal integer ("10", not "010")
*    is a NUMBER, so `expr 10 : '\(1.\)' + 1` is 11 (GNU's
*    answer; BSD refuses it). A non-canonical one ("00") stays a
*    string and prints as written, falsy under EX_FALSCK's
*    all-zeros rule.
*  - A numeric LEFT or RIGHT operand matches against its text AS
*    TYPED when it is a bare token (`expr 007 : 0` is 1, because
*    EX_PRIM threw the zeros away and this file goes back to
*    argv for them); a computed number (`( 1 + 2 ) : 3`) is
*    stringified.
*  - A pattern of 255 bytes or more is a LOUD status 2: the
*    engine walks a pattern with an 8-bit index and would
*    otherwise treat the 256th byte as the end, quietly.
*  - A malformed BRE (`[`, `\(` with no `\)`) has no compile
*    step to refuse it -- regex.s's own rule is a safe NO-MATCH
*    -- so it yields 0 / "" and exit 1, where both hosts exit
*    2. A named known gap in check_posixutil.py.
*
* EX_MLT carries "the left operand is argv[EX_MLT]" ($FF: it is
* a computed value) from EX_COL to EX_DOMATCH. EX_COL pushes it
* across the right operand's parse on the HARDWARE stack,
* because a parenthesised right operand re-enters EX_COL and
* would overwrite the cell.
*---------------------------------------------------------------

*-- High-bit character constants, NAMED (check_encoding's
*-- IMMEDIATES_MAX ratchet counts a bare `cmp #$DC`; a name is
*-- the house answer, as sh.s's ALC_xx). Defined before use.
MC_COLON    equ   $BA             ;':'
MC_BSL      equ   $DC             ;'\'
MC_LBRK     equ   $DB             ;'['
MC_RBRK     equ   $DD             ;']'
MC_LPAR     equ   $A8             ;'('
MC_CARET    equ   $DE             ;'^'
MC_DOT      equ   $AE             ;'.'
MC_EQ       equ   $BD             ;'='
MC_ZERO     equ   $B0             ;'0'
MC_NONE     equ   $FF             ;no token index / unset group

*---------------------------------------------------------------
* EX_COL -- `:`.  operand { ':' operand }
*---------------------------------------------------------------
EX_COL      lda   EX_POS
            sta   EX_MLT
            jsr   EX_PRIM
            jsr   EX_ISTOK
:loop       lda   EX_STATUS
            bne   :done
            jsr   EX_PEEK
            bcs   :done
            lda   #MC_COLON             ;':'
            jsr   EX_IS1CH
            bcs   :done
            inc   EX_POS
            lda   EX_MLT
            pha
            jsr   EX_PUSHRV
            lda   EX_POS
            sta   EX_MLT
            jsr   EX_PRIM
            jsr   EX_ISTOK
            lda   EX_MLT
            sta   EX_MRT
            pla
            sta   EX_MLT
            jsr   EX_POPSV
            lda   EX_STATUS
            bne   :done
            jsr   EX_DOMATCH
            lda   #MC_NONE         ;the result is a value, no
            sta   EX_MLT           ;longer a token
            bra   :loop
:done       rts

*---------------------------------------------------------------
* EX_ISTOK -- EX_MLT held the token index EX_PRIM started at.
* If EX_PRIM consumed exactly that one token, leave it; if it
* consumed more (a parenthesised group is at least three) set
* EX_MLT to $FF. CLOBBERS A.
*---------------------------------------------------------------
EX_ISTOK    lda   EX_POS
            sec
            sbc   EX_MLT
            cmp   #1
            beq   :ok
            lda   #MC_NONE
            sta   EX_MLT
:ok         rts

*---------------------------------------------------------------
* EX_MTOK -- PTR1 = argv[A], leaving EX_POS as it was.
*---------------------------------------------------------------
EX_MTOK     ldx   EX_POS
            phx
            sta   EX_POS
            jsr   EX_GETTOK
            plx
            stx   EX_POS
            rts

*---------------------------------------------------------------
* EX_DOMATCH -- EX_SV (left, the text) : EX_RV (right, the BRE)
* -> EX_RV.  EX_MLT / EX_MRT are the operands' argv indices, or
* $FF for a computed value.  See the file header for the result.
*---------------------------------------------------------------
EX_DOMATCH  lda   EX_MLT
            cmp   #MC_NONE
            bne   :ltok
            lda   EX_SV_ISNM
            beq   :lstr
            lda   EX_SV_NUM
            sta   U2DEC_VAL
            lda   EX_SV_NUM+1
            sta   U2DEC_VAL+1
            lda   #<EX_SBUFA
            sta   PTR1
            lda   #>EX_SBUFA
            sta   PTR1+1
            jsr   U2DEC
            lda   #<EX_SBUFA
            sta   EX_MTXT
            lda   #>EX_SBUFA
            sta   EX_MTXT+1
            bra   :rside
:lstr       lda   EX_SV_PTR
            sta   EX_MTXT
            lda   EX_SV_PTR+1
            sta   EX_MTXT+1
            bra   :rside
:ltok       jsr   EX_MTOK
            lda   PTR1
            sta   EX_MTXT
            lda   PTR1+1
            sta   EX_MTXT+1

:rside      lda   EX_MRT
            cmp   #MC_NONE
            bne   :rtok
            lda   EX_RV_ISNM
            beq   :rstr
            lda   EX_RV_NUM
            sta   U2DEC_VAL
            lda   EX_RV_NUM+1
            sta   U2DEC_VAL+1
            lda   #<EX_SBUFB
            sta   PTR1
            lda   #>EX_SBUFB
            sta   PTR1+1
            jsr   U2DEC
            lda   #<EX_SBUFB
            sta   EX_MPAT
            lda   #>EX_SBUFB
            sta   EX_MPAT+1
            bra   :scan
:rstr       lda   EX_RV_PTR
            sta   EX_MPAT
            lda   EX_RV_PTR+1
            sta   EX_MPAT+1
            bra   :scan
:rtok       jsr   EX_MTOK
            lda   PTR1
            sta   EX_MPAT
            lda   PTR1+1
            sta   EX_MPAT+1

*-- does the BRE hold a \( ?  EX_MGRP = 1 if so.  The walk is
*-- escape- and bracket-aware: `\\(` is a literal backslash then
*-- a literal paren, and `[\(]` is a bracket expression -- the
*-- engine's own RE_LONGEST scan is not (it only skips ONE byte
*-- after a backslash), so it is not reused.  Length first: 255
*-- non-NUL bytes is a loud error, see the file header.
:scan       stz   EX_MGRP
            lda   EX_MPAT
            sta   PTR1
            lda   EX_MPAT+1
            sta   PTR1+1
            ldy   #0
:len        lda   (PTR1),y
            beq   :lenok
            iny
            cpy   #255
            bcc   :len
            lda   #2
            sta   EX_STATUS
            lda   #1
            sta   EX_RV_ISNM
            stz   EX_RV_NUM
            stz   EX_RV_NUM+1
            rts
:lenok      ldy   #0
:wlk        lda   (PTR1),y
            beq   :wdone
            iny
            cmp   #MC_BSL             ;'\'
            beq   :wesc
            cmp   #MC_LBRK             ;'['
            beq   :wbrk
            bra   :wlk
:wesc       lda   (PTR1),y
            beq   :wdone
            iny
            cmp   #MC_LPAR             ;'('
            bne   :wlk
            lda   #1
            sta   EX_MGRP
            bra   :wdone
:wbrk       lda   (PTR1),y
            cmp   #MC_CARET             ;'^'
            bne   :wb1
            iny
:wb1        lda   (PTR1),y
            cmp   #MC_RBRK             ;']' first is a member
            bne   :wbl
            iny
:wbl        lda   (PTR1),y
            beq   :wdone
            iny
            cmp   #MC_RBRK             ;']' ends the bracket
            beq   :wlk
            cmp   #MC_LBRK             ;'[' may open [:c:] etc
            bne   :wbl
            lda   (PTR1),y
            cmp   #MC_COLON             ;':'
            beq   :wcls
            cmp   #MC_DOT             ;'.'
            beq   :wcls
            cmp   #MC_EQ             ;'='
            bne   :wbl
:wcls       sta   EX_TMPCH
            iny
:wcl2       lda   (PTR1),y
            beq   :wdone
            iny
            cmp   EX_TMPCH
            bne   :wcl2
            lda   (PTR1),y
            cmp   #MC_RBRK
            bne   :wcl2
            iny
            bra   :wbl
:wdone

*-- run the engine: PTR0 = line start, PTR1 = pattern, PTR2 =
*-- search-from (the same).  It clobbers all three.
            lda   EX_MTXT
            sta   PTR0
            sta   PTR2
            lda   EX_MTXT+1
            sta   PTR0+1
            sta   PTR2+1
            lda   EX_MPAT
            sta   PTR1
            lda   EX_MPAT+1
            sta   PTR1+1
            jsr   RE_MATCH
            bcs   :nomatch
            lda   RE_MSTART        ;anchored: a hit later in
            cmp   EX_MTXT          ;the string is no answer
            bne   :nomatch
            lda   RE_MSTART+1
            cmp   EX_MTXT+1
            bne   :nomatch
            lda   EX_MGRP
            bne   :group
            sec                    ;length = match end - start
            lda   RE_MEND
            sbc   EX_MTXT
            sta   EX_RV_NUM
            lda   RE_MEND+1
            sbc   EX_MTXT+1
            sta   EX_RV_NUM+1
:retnum     lda   #1
            sta   EX_RV_ISNM
            rts
:nomatch    lda   EX_MGRP
            bne   :empty
            stz   EX_RV_NUM
            stz   EX_RV_NUM+1
            bra   :retnum
:empty      lda   #<EX_MEMPTY
            sta   EX_RV_PTR
            lda   #>EX_MEMPTY
            sta   EX_RV_PTR+1
            stz   EX_RV_ISNM
            rts

*-- group 1: cut the text off at the group's end, in place.
:group      lda   RE_GRPST+1
            cmp   #MC_NONE
            beq   :nomatch         ;the group took no part
            lda   RE_GRPEND
            sta   PTR0
            lda   RE_GRPEND+1
            sta   PTR0+1
            lda   RE_GRPST
            sta   PTR1
            lda   RE_GRPST+1
            sta   PTR1+1
            lda   #0
            tay
            sta   (PTR0),y
            lda   PTR1
            sta   EX_RV_PTR
            lda   PTR1+1
            sta   EX_RV_PTR+1
            stz   EX_RV_ISNM
            jsr   EX_NPARSE        ;a decimal integer is a
            bcs   :gdone           ;number, if CANONICAL:
            ldy   #0               ;"00" must print as "00"
            lda   (PTR1),y
            cmp   #MC_ZERO
            bne   :gnum
            iny
            lda   (PTR1),y
            bne   :gdone
:gnum       lda   EX_TMP
            sta   EX_RV_NUM
            lda   EX_TMP+1
            sta   EX_RV_NUM+1
            lda   #1
            sta   EX_RV_ISNM
:gdone      rts

EX_MEMPTY   dfb   0
*-- EX_SBUFB EX_MLT EX_MRT EX_MTXT EX_MPAT EX_MGRP live in
*-- expr.s's `dum` arena (STICKY sec 21): every one is written
*-- before it is read -- EX_MLT/EX_MRT by EX_COL, the rest by
*-- EX_DOMATCH.
