*---------------------------------------------------------------
* cutlist.s -- cut's LIST-syntax parser and range test, `put` by
* src/bin/cut.s (NOT a standalone binary -- the same put-module
* shape as ed.s's edparse.s/sh.s's shlex.s, split from cut.s for
* the same reason units split anywhere: `as`'s 16,128-byte
* source window holds the resident manifest plus one put file at
* a time, and cut.s's own text alone was past it). Every symbol
* here resolves against cut.s's own equates (MAXRANGE), data
* (RCOUNT/RLO/RHI/NLO/NHI/HAVEN/ACDIG/ACT2LO/ACT2HI/SEL_POS) and
* USAGEEXIT; see that file's header for LIST's grammar.
*---------------------------------------------------------------
LISTPARSE   ldy   #0
:tok        stz   HAVEN
            stz   NLO
            stz   NHI
            ldx   #0
:d1         lda   (PTR0),y
            cmp   #$B0
            bcc   :d1end
            cmp   #$BA
            bcs   :d1end
            and   #$0F
            jsr   ACCUM
            lda   #1
            sta   HAVEN
            iny
            bra   :d1
:d1end      lda   (PTR0),y
            cmp   #$AD
            bne   :bare
            iny
            stz   HAVEN+1
            stz   NLO+1
            stz   NHI+1
            ldx   #1
:d2         lda   (PTR0),y
            cmp   #$B0
            bcc   :d2end
            cmp   #$BA
            bcs   :d2end
            and   #$0F
            jsr   ACCUM
            lda   #1
            sta   HAVEN+1
            iny
            bra   :d2
:d2end      lda   HAVEN
            bne   :n1given
            lda   #1
            sta   NLO
            stz   NHI
:n1given    lda   HAVEN+1
            bne   :n2given
            lda   HAVEN
            beq   :baddash
            lda   NLO
            ora   NHI
            beq   :baddash
            lda   #255
            sta   NLO+1
            stz   NHI+1
            bra   :haverng
:n2given    lda   HAVEN
            beq   :skipck
            lda   NLO
            ora   NHI
            beq   :baddash
            jsr   CKORDER
            bcc   :baddash
:skipck     lda   NLO+1
            ora   NHI+1
            beq   :baddash
:haverng    ldx   #0
            jsr   CLAMPN
            pha
            ldx   #1
            jsr   CLAMPN
            tax
            pla
            jsr   APPENDRNG
            bra   :tokend
:bare       lda   HAVEN
            beq   :baddash
            lda   NLO
            ora   NHI
            beq   :baddash
            ldx   #0
            jsr   CLAMPN
            tax
            jsr   APPENDRNG
:tokend     lda   (PTR0),y
            beq   :lpdone
            cmp   #$AC
            bne   :baddash
            iny
            jmp   :tok
:lpdone     rts
:baddash    jmp   USAGEEXIT

*---------------------------------------------------------------
* ACCUM -- IN: A = digit 0-9, X = 0 or 1 (which N). Updates
* NLO,x/NHI,x = NLO,x/NHI,x * 10 + A. Same shape as head.s's
* ACCUM10, indexed so one copy serves both N's.
*---------------------------------------------------------------
ACCUM       sta   ACDIG
            asl   NLO,x
            rol   NHI,x
            lda   NLO,x
            sta   ACT2LO
            lda   NHI,x
            sta   ACT2HI
            asl   NLO,x
            rol   NHI,x
            asl   NLO,x
            rol   NHI,x
            clc
            lda   NLO,x
            adc   ACT2LO
            sta   NLO,x
            lda   NHI,x
            adc   ACT2HI
            sta   NHI,x
            clc
            lda   NLO,x
            adc   ACDIG
            sta   NLO,x
            bcc   :nc
            inc   NHI,x
:nc         rts

*---------------------------------------------------------------
* CLAMPN -- IN: X = 0 or 1. OUT: A = NLO,x/NHI,x saturated to
* 255 (any nonzero high byte clamps).
*---------------------------------------------------------------
CLAMPN      lda   NHI,x
            beq   :ok
            lda   #255
            rts
:ok         lda   NLO,x
            rts

*---------------------------------------------------------------
* CKORDER -- 16-bit unsigned compare, N (index 0) vs M (index
* 1), by subtraction. OUT: carry SET = N<=M (ok); carry CLEAR =
* N>M (bad).
*---------------------------------------------------------------
CKORDER     sec
            lda   NLO+1
            sbc   NLO
            lda   NHI+1
            sbc   NHI
            rts

*---------------------------------------------------------------
* APPENDRNG -- IN: A = lo, X = hi (both 1-255, lo<=hi). Appends
* (lo,hi) to RLO/RHI. A list with more than MAXRANGE tokens is a
* usage error -- no v1 bank has unbounded range storage.
*
* PRESERVES Y: LISTPARSE keeps its string-scan cursor in Y
* across this call (and across CLAMPN, which never touches Y)
* -- Y here is local RCOUNT-array indexing, must not leak out.
*---------------------------------------------------------------
APPENDRNG   phy
            ldy   RCOUNT
            cpy   #MAXRANGE
            bcs   :full
            sta   RLO,y
            txa
            sta   RHI,y
            iny
            sty   RCOUNT
            ply
            rts
:full       ply
            jmp   USAGEEXIT

*---------------------------------------------------------------
* SELECTED -- IN: A = position (1-255). OUT: carry set = the
* position falls inside some (RLO,RHI) pair.
*---------------------------------------------------------------
SELECTED    sta   SEL_POS
            ldx   #0
:sloop      cpx   RCOUNT
            bcs   :no
            lda   SEL_POS
            cmp   RLO,x
            bcc   :nextr
            lda   RHI,x
            cmp   SEL_POS
            bcc   :nextr
            sec
            rts
:nextr      inx
            bra   :sloop
:no         clc
            rts
