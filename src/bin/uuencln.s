*---------------------------------------------------------------
* uuencln.s -- uuencode's base64 line driver (ENCLINEB) and its
* buffered chunk reader (READCHNK/GETBYTE/REFILL). `put` by
* src/bin/uuencode.s (NOT a standalone binary): uuencode's own
* resident text plus this file's own content ran past the native
* assembler's 16128-byte window in one piece, and `as` holds
* exactly one put file's text at a time (docs/S9-PLAN.md sec 5).
* Every symbol here resolves against uuencode.s's own zero page,
* equates and `dum` cells -- see that file's own header for the
* algorithm.
*---------------------------------------------------------------
*---------------------------------------------------------------
* ENCLINEB -- base64 body: IN A = n (1-57, real byte count for
* this line). Groups with fewer than 3 real bytes left (the
* line's LAST group only) pad the missing character(s) with '='
* rather than encoding a zero group. CLOBBERS: A, X, Y,
* EB_REMAIN, EB_OFS, SP_*.
*---------------------------------------------------------------
ENCLINEB    sta   EB_REMAIN
            stz   EB_OFS
:bloop      ldx   EB_OFS
            jsr   SPLIT3
            ldy   SP_V0
            lda   B64TAB,y
            ldx   #FD_STDOUT
            jsr   PUTC
            ldy   SP_V1
            lda   B64TAB,y
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   EB_REMAIN
            cmp   #2
            bcc   :bpad2
            ldy   SP_V2
            lda   B64TAB,y
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   EB_REMAIN
            cmp   #3
            bcc   :bpad1
            ldy   SP_V3
            lda   B64TAB,y
            ldx   #FD_STDOUT
            jsr   PUTC
            bra   :badv
:bpad2      lda   #EQCHAR
            ldx   #FD_STDOUT
            jsr   PUTC
:bpad1      lda   #EQCHAR
            ldx   #FD_STDOUT
            jsr   PUTC
:badv       lda   EB_REMAIN
            cmp   #4
            bcc   :bdone
            sec
            sbc   #3
            sta   EB_REMAIN
            lda   EB_OFS
            clc
            adc   #3
            sta   EB_OFS
            bra   :bloop
:bdone      rts

*---------------------------------------------------------------
* READCHNK -- IN: A = target byte count (CHUNKSZ, 45 or 57).
* Fills ENCBUF[0..count-1] from SRCFD via GETBYTE, zero-fills
* the rest of ENCBUF (up to its own 57-byte size) so SPLIT3 may
* freely read past a short final group. OUT: A = count actually
* read (0 = source exhausted). CLOBBERS: A, X, RC_TARGET,
* RC_IDX, RC_COUNT, ENCBUF.
*---------------------------------------------------------------
READCHNK    sta   RC_TARGET
            stz   RC_IDX
* -- RC_IDX, not X: `jsr GETBYTE` clobbers X (BUFPOS, then the
* -- >RPARM hi-byte for SC_READ), never restoring a caller's X.
* -- Found live: X surviving the call was assumed here once,
* -- and `cpx RC_TARGET` then never matched -- an infinite
* -- reread.
:rcloop     lda   RC_IDX
            cmp   RC_TARGET
            beq   :rcdone
            jsr   GETBYTE
            bcs   :rcdone
            ldx   RC_IDX
            sta   ENCBUF,x
            inc   RC_IDX
            bra   :rcloop
:rcdone     lda   RC_IDX
            sta   RC_COUNT
            ldx   RC_COUNT
            cpx   #57
            beq   :rcret
:rczlp      lda   #0
            sta   ENCBUF,x
            inx
            cpx   #57
            bne   :rczlp
:rcret      lda   RC_COUNT
            rts

*---------------------------------------------------------------
* GETBYTE / REFILL -- buffered input, same shape as sum.s/wc.s.
*---------------------------------------------------------------
GETBYTE     ldx   BUFPOS
            cpx   BUFLEN
            bcc   :have
            jsr   REFILL
            bcs   :eof
            ldx   BUFPOS
:have       lda   CBUF,x
            inc   BUFPOS
            clc
            rts
:eof        sec
            rts

REFILL      lda   SRCFD
            sta   RPARM_REF
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :eof
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :eof
            lda   RPARM_TRANS
            sta   BUFLEN
            stz   BUFPOS
            clc
            rts
:eof        sec
            rts
