*---------------------------------------------------------------
* num.s -- number to decimal string.
*
* Classic power-of-ten repeated-subtraction conversion (no
* divide instruction on 6502/65C02) -- table-driven, 5 positions
* (10000s down to 1s), leading zeros suppressed except the units
* position (so 0 prints as "0", not "").
*---------------------------------------------------------------

POW10       da    10000
            da    1000
            da    100
            da    10
            da    1

* See L.NUM.TXT: "U2DEC -- convert an unsigned 16-bit"
U2DEC       ldy   #0
            lda   #0
            sta   U2DEC_LZ
            ldx   #0             ;byte offset into POW10
                                 ;(0,2,4,6,8)
:digitloop  lda   #0
            sta   U2DEC_DIGIT
:sub10      lda   POW10,x
            sta   U2DEC_SUB
            lda   POW10+1,x
            sta   U2DEC_SUB+1
            lda   U2DEC_VAL+1
            cmp   U2DEC_SUB+1
            bcc   :nodig         ;hi byte less -> value <
                                 ;subtrahend, stop
            bne   :dosub         ;hi byte greater -> definitely
                                 ;>=, subtract
            lda   U2DEC_VAL
            cmp   U2DEC_SUB
            bcc   :nodig         ;hi equal, lo less -> value <
                                 ;subtrahend
:dosub      sec
            lda   U2DEC_VAL
            sbc   U2DEC_SUB
            sta   U2DEC_VAL
            lda   U2DEC_VAL+1
            sbc   U2DEC_SUB+1
            sta   U2DEC_VAL+1
            inc   U2DEC_DIGIT
            bra   :sub10
:nodig      lda   U2DEC_DIGIT
            bne   :emit          ; nonzero digit -> always emit
            lda   U2DEC_LZ
            bne   :emit          ;already past leading zeros ->
                                 ;emit the 0
            cpx   #8
            beq   :emit          ;units position -> always emit
                                 ;(so "0" prints)
            bra   :skip          ; still-leading zero, suppress
:emit       lda   #1
            sta   U2DEC_LZ
            lda   U2DEC_DIGIT
            ora   #$B0           ;digit -> high-bit-set ASCII
                                 ;('0'..'9')
            sta   (PTR1),y
            iny
:skip       inx
            inx
            cpx   #10
            bne   :digitloop
            lda   #0
            sta   (PTR1),y       ; NUL terminator
            tya
            rts

*---------------------------------------------------------------
* PRNUM -- print U2DEC_VAL as decimal to a fd. Was a private
* helper inside wc.s; grep's -n and -c wanted the same three
* lines, so it moved here rather than being copied.
*
* IN: X = fd (matches PUTC/PUTS's own convention -- was
* hardcoded FD_STDOUT; a caller that doesn't set X now gets a
* garbage fd, docs/PLAN.md "The liba wave"). CLOBBERS: A, X, Y
* (PUTS's own clobbers, unchanged).
*---------------------------------------------------------------
PRNUM       stx   PRNUM_FD
            lda   #<PRNBUF
            sta   PTR1
            lda   #>PRNBUF
            sta   PTR1+1
            jsr   U2DEC
            lda   #<PRNBUF
            sta   PTR0
            lda   #>PRNBUF
            sta   PTR0+1
            ldx   PRNUM_FD
            jsr   PUTS
            rts

* -- PRNUM_FD and the 8-byte PRNBUF used to be declared here as
* -- emitted `ds` text that PRNUM/U2DEC then wrote -- writable
* -- text, which docs/STICKY.md sec 21 forbids. They are in
* -- src/liba/libabss.s's `dum` arena now (sec 25): PRNUM stores
* -- the fd on entry, and U2DEC fills PRNBUF (always at least a
* -- digit and always the NUL) before PUTS reads it back.
