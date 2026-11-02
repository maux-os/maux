*---------------------------------------------------------------
* hex.s -- hex-digit printing, split out of num.s (which owns
* decimal, U2DEC/PRNUM) so a hex-only caller does not pay for
* POW10/U2DEC/PRNUM/PRNBUF it never uses -- this build links
* liba by `put` (whole-file textual inclusion, no dead-code
* elimination), so a program pays for everything in a file it
* puts. docs/FAT.md sec 3: four private copies of this nibble
* math (HEXPRINT/PRHEXDIG in ls.s/file.s, PRHEXBYTE/PRHEXNIB in
* od.s/nm.s) -- one place to agree now.
*---------------------------------------------------------------

*---------------------------------------------------------------
* PRHEX8 -- print A as 2 uppercase hex digits, high-bit ASCII.
* No "$" prefix -- that is a caller's rendering choice, not
* this primitive's job.
* IN: A = byte, X = fd (PUTC/PUTS/PRNUM's own convention).
* OUT: -. CLOBBERS: A, X, Y (PUTC's own clobbers, unchanged).
*---------------------------------------------------------------
PRHEX8      stx   PRHEX8_FD
            pha
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            jsr   :nib
            pla
            and   #$0F
            jsr   :nib
            rts
:nib        cmp   #10
            bcc   :dig
            sec
            sbc   #10
            clc
            adc   #$C1
            bra   :out
:dig        ora   #$B0
:out        ldx   PRHEX8_FD
            jsr   PUTC
            rts

*---------------------------------------------------------------
* PRHEX16 -- print a 16-bit value as 4 uppercase hex digits,
* high byte first (od.s's PRHEX4 shape).
* IN: A = hi byte, Y = lo byte, X = fd.
* OUT: -. CLOBBERS: A, X, Y (PRHEX8's own clobbers).
*---------------------------------------------------------------
PRHEX16     stx   PRHEX16_FD
            sty   PRHEX16_LO
            ldx   PRHEX16_FD
            jsr   PRHEX8
            lda   PRHEX16_LO
            ldx   PRHEX16_FD
            jsr   PRHEX8
            rts

* -- PRHEX8_FD/PRHEX16_FD/PRHEX16_LO used to be declared here as
* -- emitted `ds` text that these two routines then wrote --
* -- writable text, which docs/STICKY.md sec 21 forbids. They
* -- are in src/liba/libabss.s's `dum` arena now (sec 25): each
* -- is stored by the routine's own first instruction, so
* -- uncleared memory is safe for all three.
