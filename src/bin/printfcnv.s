*---------------------------------------------------------------
* printfcnv.s -- printf's per-conversion handlers: PF_DO_D/U/O/
* X/XU/C/S/PCT/B, each consuming the arguments its conversion
* needs and printing the field via printfnum.s's PF_EMITNUM (or,
* for %c/%s, its own small width-pad shape; %% and %b bypass it
* entirely). %b's own escape engine (PF_ADVB/PF_BLOOP) lives
* here too -- it is reached only from PF_DO_B. `put` by
* src/bin/printf.s right after printfnum.s -- see printffmt.s's
* own header for why this is a three-way split, not two. Every
* symbol here resolves against printf.s's own zero page
* (PF_BARG) and `dum` cells.
*---------------------------------------------------------------
PF_DO_D     jsr   PF_NUMCONV
            lda   PF_NUMVAL+1
            and   #$80
            beq   :dpo
            lda   #1
            sta   PF_NEG
            sec
            lda   #0
            sbc   PF_NUMVAL
            sta   PF_MAG
            lda   #0
            sbc   PF_NUMVAL+1
            sta   PF_MAG+1
            bra   :dck
:dpo        stz   PF_NEG
            lda   PF_NUMVAL
            sta   PF_MAG
            lda   PF_NUMVAL+1
            sta   PF_MAG+1
:dck        jsr   PF_CKZERO
            jsr   PF_DEC
            lda   #1
            sta   PF_SIGNOK
            stz   PF_PFXMODE
            jmp   PF_EMITNUM

*---------------------------------------------------------------
* PF_DO_U -- %u: unsigned 16-bit decimal.
*---------------------------------------------------------------
PF_DO_U     jsr   PF_NUMCONV
            stz   PF_NEG
            lda   PF_NUMVAL
            sta   PF_MAG
            lda   PF_NUMVAL+1
            sta   PF_MAG+1
            jsr   PF_CKZERO
            jsr   PF_DEC
            stz   PF_SIGNOK
            stz   PF_PFXMODE
            jmp   PF_EMITNUM

*---------------------------------------------------------------
* PF_DO_O -- %o: unsigned 16-bit octal, # forces a leading 0.
*---------------------------------------------------------------
PF_DO_O     jsr   PF_NUMCONV
            stz   PF_NEG
            lda   PF_NUMVAL
            sta   PF_MAG
            lda   PF_NUMVAL+1
            sta   PF_MAG+1
            jsr   PF_CKZERO
            jsr   PF_OCT
            stz   PF_SIGNOK
            lda   #1
            sta   PF_PFXMODE
            jmp   PF_EMITNUM

*---------------------------------------------------------------
* PF_DO_X -- %x: unsigned 16-bit hex, lower case, # -> "0x".
*---------------------------------------------------------------
PF_DO_X     jsr   PF_NUMCONV
            stz   PF_NEG
            lda   PF_NUMVAL
            sta   PF_MAG
            lda   PF_NUMVAL+1
            sta   PF_MAG+1
            jsr   PF_CKZERO
            stz   PF_HEXUP
            jsr   PF_HEX
            stz   PF_SIGNOK
            lda   #2
            sta   PF_PFXMODE
            lda   #$F8
            sta   PF_PFXCH2
            jmp   PF_EMITNUM

*---------------------------------------------------------------
* PF_DO_XU -- %X: unsigned 16-bit hex, upper case, # -> "0X".
*---------------------------------------------------------------
PF_DO_XU    jsr   PF_NUMCONV
            stz   PF_NEG
            lda   PF_NUMVAL
            sta   PF_MAG
            lda   PF_NUMVAL+1
            sta   PF_MAG+1
            jsr   PF_CKZERO
            lda   #1
            sta   PF_HEXUP
            jsr   PF_HEX
            stz   PF_SIGNOK
            lda   #2
            sta   PF_PFXMODE
            lda   #$D8
            sta   PF_PFXCH2
            jmp   PF_EMITNUM

*---------------------------------------------------------------
* PF_DO_C -- %c: the argument's first byte only (nothing for a
* missing/empty argument), width-padded.
*---------------------------------------------------------------
PF_DO_C     jsr   CONSUME_ARG
            ldy   #0
            lda   (PTR0),y
            beq   :cem
            sta   PF_CCHAR
            lda   #1
            sta   PF_CLEN
            bra   :cwd
:cem        stz   PF_CLEN
:cwd        stz   PF_TMP2
            lda   PF_WIDTH
            cmp   PF_CLEN
            bcc   :cwn
            beq   :cwn
            sec
            lda   PF_WIDTH
            sbc   PF_CLEN
            sta   PF_TMP2
:cwn        lda   PF_FLNEG
            bne   :csl
            ldx   PF_TMP2
            beq   :csl
            lda   #$A0
            jsr   PF_EMITN
:csl        lda   PF_CLEN
            beq   :csc
            lda   PF_CCHAR
            jsr   PF_EMIT1
:csc        lda   PF_FLNEG
            beq   :cdn
            ldx   PF_TMP2
            beq   :cdn
            lda   #$A0
            jsr   PF_EMITN
:cdn        rts

*---------------------------------------------------------------
* PF_DO_S -- %s: the argument string, truncated to PRECISION
* characters if given, width-padded. A counted byte-by-byte
* PUTC (not PUTS -- precision may cut it short of the NUL).
*---------------------------------------------------------------
PF_DO_S     jsr   CONSUME_ARG
            jsr   STRLEN
            sta   PF_SLEN
            lda   PF_HASPREC
            beq   :sng
            lda   PF_PREC
            cmp   PF_SLEN
            bcs   :sng
            sta   PF_SLEN
:sng        stz   PF_TMP2
            lda   PF_WIDTH
            cmp   PF_SLEN
            bcc   :swd
            beq   :swd
            sec
            lda   PF_WIDTH
            sbc   PF_SLEN
            sta   PF_TMP2
:swd        lda   PF_FLNEG
            bne   :ssl
            ldx   PF_TMP2
            beq   :ssl
            lda   #$A0
            jsr   PF_EMITN
:ssl        lda   PF_SLEN
            beq   :ssn
            ldy   #0
:slp        lda   (PTR0),y
            jsr   PF_EMIT1
            iny
            cpy   PF_SLEN
            bne   :slp
:ssn        lda   PF_FLNEG
            beq   :sdn
            ldx   PF_TMP2
            beq   :sdn
            lda   #$A0
            jsr   PF_EMITN
:sdn        rts

*---------------------------------------------------------------
* PF_DO_PCT -- %%: a literal '%'. No argument, flags/width
* ignored (the task's own corpus only asks for the literal).
*---------------------------------------------------------------
PF_DO_PCT   lda   #$A5
            jmp   PF_EMIT1

*---------------------------------------------------------------
* PF_DO_B -- %b: the argument's OWN backslash escapes, per XCU's
* extension: \\ \a \b \f \n \r \t \v, \0ddd (a literal '0' then
* up to 3 octal digits -- %b's own spelling, NOT the format
* string's plain \ddd), and \c -- a full stop: nothing more of
* THIS argument, no further arguments, no more of the format
* operand either (PF_STOP, checked by FMTSCAN and by the reuse
* loop in printf.s's own START).
*---------------------------------------------------------------
PF_DO_B     jsr   CONSUME_ARG
            lda   PTR0
            sta   PF_BARG
            lda   PTR0+1
            sta   PF_BARG+1
            jmp   PF_BLOOP

*---------------------------------------------------------------
* PF_ADVB -- PF_BARG += 1. CLOBBERS: A.
*---------------------------------------------------------------
PF_ADVB     inc   PF_BARG
            bne   :abr
            inc   PF_BARG+1
:abr        rts

PF_BLOOP    ldy   #0
            lda   (PF_BARG),y
            bne   :bnz
            jmp   :bdn
:bnz        cmp   #$DC
            beq   :bes
            jsr   PF_EMIT1
            jsr   PF_ADVB
            jmp   PF_BLOOP
:bes        jsr   PF_ADVB
            ldy   #0
            lda   (PF_BARG),y
            cmp   #$DC
            beq   :bbs
            cmp   #$E1
            beq   :bba
            cmp   #$E2
            beq   :bbb
            cmp   #$E3
            beq   :bsc
            cmp   #$E6
            beq   :bbf
            cmp   #$EE
            beq   :bbn
            cmp   #$F2
            beq   :bbr
            cmp   #$F4
            beq   :bbt
            cmp   #$F6
            beq   :bbv
            cmp   #$B0
            beq   :bz0
            lda   #$DC
            jsr   PF_EMIT1
            jmp   PF_BLOOP
:bbs        lda   #$DC
            jsr   PF_EMIT1
            jsr   PF_ADVB
            jmp   PF_BLOOP
:bba        lda   #$87
            jsr   PF_EMIT1
            jsr   PF_ADVB
            jmp   PF_BLOOP
:bbb        lda   #$88
            jsr   PF_EMIT1
            jsr   PF_ADVB
            jmp   PF_BLOOP
:bbf        lda   #$8C
            jsr   PF_EMIT1
            jsr   PF_ADVB
            jmp   PF_BLOOP
:bbn        lda   #$8D
            jsr   PF_EMIT1
            jsr   PF_ADVB
            jmp   PF_BLOOP
:bbr        lda   #$8D
            jsr   PF_EMIT1
            jsr   PF_ADVB
            jmp   PF_BLOOP
:bbt        lda   #$89
            jsr   PF_EMIT1
            jsr   PF_ADVB
            jmp   PF_BLOOP
:bbv        lda   #$8B
            jsr   PF_EMIT1
            jsr   PF_ADVB
            jmp   PF_BLOOP
:bsc        lda   #1
            sta   PF_STOP
            rts
:bz0        jsr   PF_ADVB
            stz   PF_OVAL
            ldx   #0
:bz1        cpx   #3
            beq   :bz2
            ldy   #0
            lda   (PF_BARG),y
            cmp   #$B0
            bcc   :bz2
            cmp   #$B8
            bcs   :bz2
            and   #$07
            sta   PF_TMP
            lda   PF_OVAL
            asl   a
            asl   a
            asl   a
            clc
            adc   PF_TMP
            sta   PF_OVAL
            jsr   PF_ADVB
            inx
            bra   :bz1
:bz2        lda   PF_OVAL
            ora   #$80
            jsr   PF_EMIT1
            jmp   PF_BLOOP
:bdn        rts
