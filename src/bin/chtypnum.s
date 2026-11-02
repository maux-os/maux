*---------------------------------------------------------------
* chtypnum.s -- chtyp's operand parsers: PARSETYPE, MATCHMNEM,
* UPFOLD, PARSENUM, DIGIT10, DIGIT16, MUL10. `put` by chtyp.s,
* which keeps the option loop, the per-file loop, the parmlists
* and the `dum` arena.
*
* WHY THE SPLIT, 2026-09-21: the vendored `as`'s 16,128-byte
* SOURCE WINDOW -- manifest plus its largest single put -- and
* chtyp.s reached 16,676 against liba/stdio.s's 5,584. A unit
* over that window cannot be rebuilt by maux itself. FIFTH split
* in a day, and the fifth time a single utility's own feature
* set tipped it; docs/POSIX-GAPS.md sec 6b prices that.
*
* The seam is DECIDING WHAT A WORD MEANS (here) against DOING
* something to a file (there). `put` at top level in chtyp.s --
* Merlin cannot nest a put inside a put file.
*---------------------------------------------------------------
*---------------------------------------------------------------
* PARSETYPE -- a file type: mnemonic, $hex or decimal. Carry
* SET = not one of those. OUT: PVAL (PVAL+1 is not meaningful --
* a file type is ONE byte, and a decimal 256 is rejected here
* rather than silently truncated).
*---------------------------------------------------------------
PARSETYPE   jsr   MATCHMNEM
            bcc   :ptok
            jsr   PARSENUM
            bcs   :ptbad
            lda   PVAL+1              ;a type is one byte
            bne   :ptbad
:ptok       clc
            rts
:ptbad      sec
            rts

*---------------------------------------------------------------
* MATCHMNEM -- PTR0 against the FTYPE_* table. Case-insensitive
* (a person types `txt`; ProDOS shouts). Carry CLEAR and PVAL
* set on a match.
*---------------------------------------------------------------
MATCHMNEM   stz   MNIDX
:mmloop     ldx   MNIDX
            lda   MNEMTAB,x
            beq   :mmno               ;table end
            ldy   #0
:mmch       ldx   MNIDX
            lda   MNEMTAB,x
            beq   :mmlen              ;name ran out
            sta   MNTMP
            lda   (PTR0),y
            jsr   UPFOLD
            cmp   MNTMP
            bne   :mmnext
            inc   MNIDX
            iny
            bra   :mmch
*-- the table name ended: the operand must end here too, or
*-- "BINARY" would match "BIN"
:mmlen      lda   (PTR0),y
            beq   :mmhit
:mmnext     ldx   MNIDX               ;skip to this row's value
:mmskip     lda   MNEMTAB,x
            beq   :mmval
            inx
            bra   :mmskip
:mmval      inx                       ;past the NUL
            inx                       ;past the value byte
            stx   MNIDX
            bra   :mmloop
:mmhit      ldx   MNIDX
:mmhskip    lda   MNEMTAB,x
            beq   :mmgot
            inx
            bra   :mmhskip
:mmgot      inx
            lda   MNEMTAB,x
            sta   PVAL
            stz   PVAL+1
            clc
            rts
:mmno       sec
            rts

*-- UPFOLD -- A to upper case, high-bit ASCII throughout.
UPFOLD      cmp   #$E1                ;'a'
            bcc   :ufdone
            cmp   #$FB                ;past 'z'
            bcs   :ufdone
            and   #$DF
:ufdone     rts

*---------------------------------------------------------------
* PARSENUM -- `$hex` (1-4 digits) or decimal (0-65535) at PTR0
* into PVAL. Carry SET on anything else, INCLUDING an empty
* string: that is what an unquoted `$F8` becomes after the shell
* has expanded it, and accepting it would change a type to zero
* on a command that looks right.
*---------------------------------------------------------------
PARSENUM    stz   PVAL
            stz   PVAL+1
            ldy   #0
            lda   (PTR0),y
            beq   :pnbad
            cmp   #$A4                ;'$'
            beq   :pnhex
*-- decimal
*-- The digit goes to a CELL, not to A, across the MUL10 call:
*-- MUL10 loads PVAL and clobbers the accumulator, so adding "A"
*-- afterwards added whatever MUL10 left there. Measured, not
*-- reasoned: `chtyp -t 4` set the type to $00 while `-t '$FF'`
*-- and `-t BIN` were both already right, because only this path
*-- carries a value in A across a jsr.
:pndec      lda   (PTR0),y
            beq   :pnok
            jsr   DIGIT10
            bcs   :pnbad
            sta   DTMP
            jsr   MUL10
            bcs   :pnbad
            clc
            lda   DTMP
            adc   PVAL
            sta   PVAL
            lda   PVAL+1
            adc   #0
            sta   PVAL+1
            bcs   :pnbad
            iny
            bra   :pndec
*-- hex, after the '$'
:pnhex      iny
            lda   (PTR0),y
            beq   :pnbad              ;a bare "$"
:pnhloop    lda   (PTR0),y
            beq   :pnok
            jsr   DIGIT16
            bcs   :pnbad
            pha
            lda   PVAL+1              ;<<4, 16-bit
            asl   PVAL
            rol   a
            asl   PVAL
            rol   a
            asl   PVAL
            rol   a
            asl   PVAL
            rol   a
            sta   PVAL+1
            pla
            ora   PVAL
            sta   PVAL
            iny
            bra   :pnhloop
:pnok       clc
            rts
:pnbad      sec
            rts

*-- DIGIT10 / DIGIT16 -- A (high-bit ASCII) to its value, carry
*-- SET if it is not a digit of that base.
DIGIT10     cmp   #$B0
            bcc   :d10no
            cmp   #$BA
            bcs   :d10no
            and   #$0F
            clc
            rts
:d10no      sec
            rts

DIGIT16     cmp   #$B0
            bcc   :d16no
            cmp   #$BA
            bcs   :d16al
            and   #$0F
            clc
            rts
:d16al      jsr   UPFOLD
            cmp   #$C1                ;'A'
            bcc   :d16no
            cmp   #$C7                ;past 'F'
            bcs   :d16no
            sec
            sbc   #$C1
            clc
            adc   #10
            clc
            rts
:d16no      sec
            rts

*-- MUL10 -- PVAL *= 10, carry SET on 16-bit overflow.
MUL10       lda   PVAL
            sta   MTMP
            lda   PVAL+1
            sta   MTMP+1
            asl   PVAL                ;x2
            rol   PVAL+1
            bcs   :m10bad
            asl   PVAL                ;x4
            rol   PVAL+1
            bcs   :m10bad
            clc                       ;x5
            lda   PVAL
            adc   MTMP
            sta   PVAL
            lda   PVAL+1
            adc   MTMP+1
            sta   PVAL+1
            bcs   :m10bad
            asl   PVAL                ;x10
            rol   PVAL+1
            bcs   :m10bad
            clc
            rts
:m10bad     sec
            rts

