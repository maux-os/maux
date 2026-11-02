*---------------------------------------------------------------
* strfmt.s -- strings's -t offset formatters: PRHEXV (lowercase
* hex, no leading zeros) and PROCTV (octal, no leading zeros).
* `put` by src/bin/strings.s (NOT a standalone binary -- the
* same put-module shape as nl.s's own nlopt.s), split out for
* the same reason units split anywhere: `as`'s 16,128-byte
* source window holds the resident manifest plus one put file
* at a time, and strings.s's own text alone was 611 B over it.
* Every symbol here resolves against strings.s's own dum cells
* (OFFVAL/HV_T/HV_HI/HV_DIG) and FD_STDOUT -- see that file's
* own header.
*---------------------------------------------------------------
*---------------------------------------------------------------
* PRHEXV -- print OFFVAL (16-bit) as lowercase hex, NO leading
* zeros (0 prints as "0"). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PRHEXV      lda   OFFVAL
            sta   HV_T
            lda   OFFVAL+1
            sta   HV_T+1
            ldy   #0
:hvext      lda   HV_T
            and   #$0F
            sta   HV_DIG,y
            ldx   #4
:hvshr      lsr   HV_T+1
            ror   HV_T
            dex
            bne   :hvshr
            iny
            cpy   #4
            bne   :hvext
            ldy   #3
:hvfnz      lda   HV_DIG,y
            bne   :hvhi
            dey
            bpl   :hvfnz
            ldy   #0
:hvhi       sty   HV_HI
            ldy   HV_HI
:hvprlp     lda   HV_DIG,y
            cmp   #10
            bcc   :hvd09
            clc
            adc   #$D7
            bra   :hvprc
:hvd09      ora   #$B0
:hvprc      ldx   #FD_STDOUT
            jsr   PUTC
            dey
            bmi   :hvdone
            bra   :hvprlp
:hvdone     rts

*---------------------------------------------------------------
* PROCTV -- print OFFVAL (16-bit) as octal, NO leading zeros.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PROCTV      lda   OFFVAL
            sta   HV_T
            lda   OFFVAL+1
            sta   HV_T+1
            ldy   #0
:pvext      lda   HV_T
            and   #$07
            sta   HV_DIG,y
            ldx   #3
:pvshr      lsr   HV_T+1
            ror   HV_T
            dex
            bne   :pvshr
            iny
            cpy   #6
            bne   :pvext
            ldy   #5
:pvfnz      lda   HV_DIG,y
            bne   :pvhi
            dey
            bpl   :pvfnz
            ldy   #0
:pvhi       sty   HV_HI
            ldy   HV_HI
:pvprlp     lda   HV_DIG,y
            ora   #$B0
            ldx   #FD_STDOUT
            jsr   PUTC
            dey
            bmi   :pvdone
            bra   :pvprlp
:pvdone     rts
