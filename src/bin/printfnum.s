*---------------------------------------------------------------
* printfnum.s -- printf's numeric-argument engine: PFNUM (parse
* a POSIX numeric argument into this machine's one 16-bit
* register, incl. the 'c/"c character form and the 16-bit
* range check), its PF_ACC10 helper, PF_CKZERO, the three digit-
* string builders (PF_DEC via src/liba/num.s's own U2DEC,
* PF_OCT, PF_HEX), PF_EMITN and the shared field assembler
* PF_EMITNUM (sign/prefix/zero-fill/width composition). `put`
* by src/bin/printf.s right after printffmt.s -- see that file's
* own header for why this is a three-way split, not two. Every
* symbol here resolves against printf.s's own `dum` cells.
*---------------------------------------------------------------
PF_ACC10    sta   PF_ADIG
            lda   PF_B0
            asl   a
            sta   PF_AT0
            lda   PF_B1
            rol   a
            sta   PF_AT1
            lda   PF_B2
            rol   a
            sta   PF_AT2
            asl   PF_B0
            rol   PF_B1
            rol   PF_B2
            asl   PF_B0
            rol   PF_B1
            rol   PF_B2
            asl   PF_B0
            rol   PF_B1
            rol   PF_B2
            clc
            lda   PF_B0
            adc   PF_AT0
            sta   PF_B0
            lda   PF_B1
            adc   PF_AT1
            sta   PF_B1
            lda   PF_B2
            adc   PF_AT2
            sta   PF_B2
            clc
            lda   PF_B0
            adc   PF_ADIG
            sta   PF_B0
            bcc   :ancy
            inc   PF_B1
            bne   :ancy
            inc   PF_B2
:ancy       rts

*---------------------------------------------------------------
* PF_CKZERO -- PF_DIGZERO := (PF_MAG == 0). CLOBBERS: A.
*---------------------------------------------------------------
PF_CKZERO   lda   PF_MAG
            ora   PF_MAG+1
            beq   :ckz
            stz   PF_DIGZERO
            rts
:ckz        lda   #1
            sta   PF_DIGZERO
            rts

*---------------------------------------------------------------
* PF_DEC -- DIGBUF := PF_MAG in decimal (src/liba/num.s's own
* U2DEC -- leading zeros suppressed, "0" prints as "0").
* CLOBBERS: A, X, Y, PTR1.
*---------------------------------------------------------------
PF_DEC      lda   PF_MAG
            sta   U2DEC_VAL
            lda   PF_MAG+1
            sta   U2DEC_VAL+1
            lda   #<DIGBUF
            sta   PTR1
            lda   #>DIGBUF
            sta   PTR1+1
            jmp   U2DEC

*---------------------------------------------------------------
* PF_OCT -- DIGBUF := PF_MAG in octal (up to 6 digits, leading
* zeros suppressed the same way PF_DEC's do -- LSB-first via
* shift-right-3/mask-7, no divide instruction needed since 8 is
* a power of two). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PF_OCT      ldx   #0
:o1         lda   PF_MAG
            and   #$07
            sta   PF_ODIG,x
            inx
            ldy   #3
:o1s        lsr   PF_MAG+1
            ror   PF_MAG
            dey
            bne   :o1s
            cpx   #6
            bne   :o1
            ldx   #5
:o1f        lda   PF_ODIG,x
            bne   :o1n
            cpx   #0
            beq   :o1n
            dex
            bra   :o1f
:o1n        ldy   #0
:o1e        lda   PF_ODIG,x
            ora   #$B0
            sta   DIGBUF,y
            iny
            cpx   #0
            beq   :o1d
            dex
            bra   :o1e
:o1d        lda   #0
            sta   DIGBUF,y
            rts

*---------------------------------------------------------------
* PF_HEX -- DIGBUF := PF_MAG in hex (up to 4 digits, leading
* zeros suppressed), lower case unless PF_HEXUP is set. Same
* shift-right-4/mask-$0F shape as PF_OCT. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PF_HEX      ldx   #0
:h1         lda   PF_MAG
            and   #$0F
            sta   PF_ODIG,x
            inx
            ldy   #4
:h1s        lsr   PF_MAG+1
            ror   PF_MAG
            dey
            bne   :h1s
            cpx   #4
            bne   :h1
            ldx   #3
:h1f        lda   PF_ODIG,x
            bne   :h1n
            cpx   #0
            beq   :h1n
            dex
            bra   :h1f
:h1n        ldy   #0
:h1e        lda   PF_ODIG,x
            cmp   #10
            bcc   :h1dg
            lda   PF_HEXUP
            beq   :h1lo
            lda   PF_ODIG,x
            clc
            adc   #$B7
            bra   :h1st
:h1lo       lda   PF_ODIG,x
            clc
            adc   #$D7
            bra   :h1st
:h1dg       lda   PF_ODIG,x
            ora   #$B0
:h1st       sta   DIGBUF,y
            iny
            cpx   #0
            beq   :h1d
            dex
            bra   :h1e
:h1d        lda   #0
            sta   DIGBUF,y
            rts

*---------------------------------------------------------------
* PF_EMIT1/PF_EMITN -- see printf.s for PF_EMIT1. PF_EMITN: IN
* A = byte, X = count; writes it X times. Stores both to `dum`
* cells first -- PUTC clobbers X (and A), so the count cannot
* stay live in a register across the call. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PF_EMITN    stx   PF_ECNT
            sta   PF_ECHAR
            lda   PF_ECNT
            beq   :en0
:en1        lda   PF_ECHAR
            jsr   PF_EMIT1
            dec   PF_ECNT
            lda   PF_ECNT
            bne   :en1
:en0        rts

*---------------------------------------------------------------
* PF_EMITNUM -- assembles and prints one numeric field from the
* plain digit string in DIGBUF (already built by PF_DEC/PF_OCT/
* PF_HEX) plus this directive's flags/width/precision and the
* per-conversion facts the caller set: PF_NEG (show a sign --
* %d/%i only), PF_SIGNOK (+/space flags apply), PF_PFXMODE
* (0 none, 1 octal-leading-0-if-needed, 2 hex 0x/0X-if-nonzero),
* PF_PFXCH2 (the second prefix byte for mode 2), PF_DIGZERO (the
* magnitude is exactly 0). Composition order: sign, prefix,
* zero-fill (0-flag, precision overrides it), digits, the whole
* thing space-padded to WIDTH. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PF_EMITNUM  lda   #<DIGBUF
            sta   PTR0
            lda   #>DIGBUF
            sta   PTR0+1
            jsr   STRLEN
            sta   PF_DIGLEN
            lda   PF_HASPREC
            beq   :en2
            lda   PF_DIGZERO
            beq   :en2
            lda   PF_PREC
            bne   :en2
            stz   PF_DIGLEN
:en2        stz   PF_ZCOUNT
            lda   PF_HASPREC
            beq   :en3
            lda   PF_DIGLEN
            cmp   PF_PREC
            bcs   :en3
            sec
            lda   PF_PREC
            sbc   PF_DIGLEN
            sta   PF_ZCOUNT
:en3        stz   PF_SIGNCH
            lda   PF_SIGNOK
            beq   :en5
            lda   PF_NEG
            beq   :en4
            lda   #$AD
            sta   PF_SIGNCH
            bra   :en5
:en4        lda   PF_FLPLUS
            beq   :en4b
            lda   #$AB
            sta   PF_SIGNCH
            bra   :en5
:en4b       lda   PF_FLSPC
            beq   :en5
            lda   #$A0
            sta   PF_SIGNCH
:en5        stz   PF_PFXLEN
            lda   PF_PFXMODE
            cmp   #1
            bne   :en7
            lda   PF_FLHASH
            beq   :en7
            lda   PF_ZCOUNT
            bne   :en7
            lda   PF_DIGLEN
            beq   :en6z
            ldy   #0
            lda   DIGBUF,y
            cmp   #$B0
            beq   :en7
:en6z       lda   #1
            sta   PF_ZCOUNT
:en7        lda   PF_PFXMODE
            cmp   #2
            bne   :en8
            lda   PF_FLHASH
            beq   :en8
            lda   PF_DIGZERO
            bne   :en8
            lda   #$B0
            sta   PF_PFXBUF
            lda   PF_PFXCH2
            sta   PF_PFXBUF+1
            lda   #2
            sta   PF_PFXLEN
:en8        ldx   PF_SIGNCH
            beq   :en9z
            lda   #1
            bra   :en9
:en9z       lda   #0
:en9        clc
            adc   PF_PFXLEN
            clc
            adc   PF_ZCOUNT
            clc
            adc   PF_DIGLEN
            sta   PF_INNERLEN
            stz   PF_WPADZ
            stz   PF_WPADS
            lda   PF_WIDTH
            cmp   PF_INNERLEN
            bcc   :en11
            beq   :en11
            sec
            lda   PF_WIDTH
            sbc   PF_INNERLEN
            sta   PF_TMP2
            lda   PF_FLNEG
            bne   :en10
            lda   PF_FLZERO
            beq   :en10
            lda   PF_HASPREC
            bne   :en10
            lda   PF_TMP2
            sta   PF_WPADZ
            bra   :en11
:en10       lda   PF_TMP2
            sta   PF_WPADS
:en11       lda   PF_FLNEG
            bne   :en12
            lda   PF_WPADS
            beq   :en12
            ldx   PF_WPADS
            lda   #$A0
            jsr   PF_EMITN
:en12       lda   PF_SIGNCH
            beq   :en13
            jsr   PF_EMIT1
:en13       lda   PF_PFXLEN
            beq   :en14
            lda   PF_PFXBUF
            jsr   PF_EMIT1
            lda   PF_PFXBUF+1
            jsr   PF_EMIT1
:en14       ldx   PF_WPADZ
            beq   :en15
            lda   #$B0
            jsr   PF_EMITN
:en15       ldx   PF_ZCOUNT
            beq   :en16
            lda   #$B0
            jsr   PF_EMITN
:en16       lda   PF_DIGLEN
            beq   :en17
            lda   #<DIGBUF
            sta   PTR0
            lda   #>DIGBUF
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
:en17       lda   PF_FLNEG
            beq   :en18
            lda   PF_WPADS
            beq   :en18
            ldx   PF_WPADS
            lda   #$A0
            jsr   PF_EMITN
:en18       rts

*---------------------------------------------------------------
* PF_DO_D -- %d/%i: signed 16-bit decimal.
*---------------------------------------------------------------
