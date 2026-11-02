*---------------------------------------------------------------
* prout.s -- pr's output emitter: EMBEG/EMCH/EMFLUSH/EMDIST/
* EMPADTO/EMCR/EMNUM. `put` by src/bin/pr.s (NOT a standalone
* binary; same put-module shape as prfmt.s). Every byte of BODY
* text (single column or multi-column) goes through EMCH, which
* tracks the output column (OUTCOL, 8 bits: positions past 255
* wrap -- documented in docs/man/pr.1) so that -i can contract
* space runs to tabs. Measured on BSD and GNU (docs/POSIX-PR-
* NOTES.md): a run of two or more spaces becomes a tab at every
* tab stop it reaches; a lone space stays a space; trailing
* spaces at end of line are dropped; XCU: -e and -i are assumed
* for multi-column output.
*
* The caller must not hold X or Y across a call here (PUTC).
*---------------------------------------------------------------

*---------------------------------------------------------------
* EMBEG -- start of an output line, AFTER PUTOFS wrote the -o
* offset. CLOBBERS: A.
*---------------------------------------------------------------
EMBEG       lda   OFFSETVAL
            sta   OUTCOL
            stz   PENDSP
            rts

*---------------------------------------------------------------
* EMCH -- IN: A = one text byte (high bit set). CLOBBERS: A,
* X, Y.
*---------------------------------------------------------------
EMCH        sta   EMC
            cmp   #$A0
            bne   :nsp
            lda   IFLAG
            beq   :nsp
            inc   PENDSP
            rts
:nsp        jsr   EMFLUSH
            lda   EMC
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   EMC
            cmp   #$89
            bne   :one
            lda   OUTCOL
            and   #$F8
            clc
            adc   #8
            sta   OUTCOL
            rts
:one        inc   OUTCOL
            rts

*---------------------------------------------------------------
* EMFLUSH -- write the pending space run, tab-contracted when it
* is two or more spaces long. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
EMFLUSH     lda   PENDSP
            beq   :dn
            cmp   #2
            bcc   :sp
:tab        jsr   EMDIST
            cmp   PENDSP
            beq   :dotab
            bcs   :sp
:dotab      sta   EMD
            lda   ITABCH
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   OUTCOL
            clc
            adc   EMD
            sta   OUTCOL
            lda   PENDSP
            sec
            sbc   EMD
            sta   PENDSP
            bne   :tab
            rts
:sp         lda   PENDSP
            beq   :dn
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            inc   OUTCOL
            dec   PENDSP
            bra   :sp
:dn         rts

*---------------------------------------------------------------
* EMDIST -- OUT: A = columns from OUTCOL to the next -i tab stop
* (1..IGAP). CLOBBERS: A.
*---------------------------------------------------------------
EMDIST      lda   OUTCOL
:md         cmp   IGAP
            bcc   :mdd
            sbc   IGAP
            bra   :md
:mdd        sta   EMD
            lda   IGAP
            sec
            sbc   EMD
            rts

*---------------------------------------------------------------
* EMPADTO -- IN: A = target column. Emits spaces until the
* output
* column (flushed + pending) reaches it. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
EMPADTO     sta   EMT
:pl         lda   OUTCOL
            clc
            adc   PENDSP
            cmp   EMT
            bcs   :pd
            lda   #$A0
            jsr   EMCH
            bra   :pl
:pd         rts

*---------------------------------------------------------------
* EMCR -- end of an output line: pending spaces are dropped
* (that
* is what both hosts do under -i), then CR. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
EMCR        stz   PENDSP
            lda   #$8D
            ldx   #FD_STDOUT
            jmp   PUTC

*---------------------------------------------------------------
* EMNUM -- IN: U2DEC_VAL = the line number. Writes it right-
* aligned in NWIDTH columns, then NCHAR, through EMCH.
* CLOBBERS: A, X, Y, PTR1.
*---------------------------------------------------------------
EMNUM       lda   #<PRDIGBUF
            sta   PTR1
            lda   #>PRDIGBUF
            sta   PTR1+1
            jsr   U2DEC
            sta   PB_DLEN
            lda   NWIDTH
            sec
            sbc   PB_DLEN
            bcs   :hp
            lda   #0
:hp         sta   PB_PAD
:pl         lda   PB_PAD
            beq   :pd
            lda   #$A0
            jsr   EMCH
            dec   PB_PAD
            bra   :pl
:pd         stz   EL_IDX
:dl         ldy   EL_IDX
            lda   PRDIGBUF,y
            beq   :dd
            jsr   EMCH
            inc   EL_IDX
            bra   :dl
:dd         lda   NCHAR
            jmp   EMCH
