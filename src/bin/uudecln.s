*---------------------------------------------------------------
* uudecln.s -- uudecode's per-line drivers: DECLINEU/DECLINEB
* (one decoded line of each algorithm, via uudecdec.s's RECON4)
* and the normalized line reader GETLINE/GETBYTE/REFILL. `put`
* by src/bin/uudecode.s (NOT a standalone binary) -- see src/
* bin/uudecdec.s's own header for why the decode engine is split
* in two, and why this half being its own file (rather than
* folded into uudecdec.s) is what keeps EVERY put file under the
* size that would make it the new "largest put" the as source-
* window budget is measured against (docs/S9-PLAN.md sec 5).
* Every symbol here resolves against uudecode.s's own zero page,
* equates and `dum` cells -- see that file's own header for the
* algorithm and the round-trip contract.
*---------------------------------------------------------------

*---------------------------------------------------------------
* DECLINEU -- historical body line. IN: A = n (1-45, the
* length character's own decoded value). Decodes ceil(n/3)
* groups from LINEBUF[1..], writing exactly n bytes. OUT: carry
* SET on a short line or an invalid character. CLOBBERS: A, X,
* DU_REMAIN, DU_LOFS, DU_V0-3, RECON4's own.
*---------------------------------------------------------------
DECLINEU    sta   DU_REMAIN
            lda   #1
            sta   DU_LOFS
:dulp       ldx   DU_LOFS
            cpx   LINELEN
            bcs   :dumal
            lda   LINEBUF,x
            jsr   DECODE6
            bcs   :dumal
            sta   DU_V0
            inx
            cpx   LINELEN
            bcs   :dumal
            lda   LINEBUF,x
            jsr   DECODE6
            bcs   :dumal
            sta   DU_V1
            inx
            cpx   LINELEN
            bcs   :dumal
            lda   LINEBUF,x
            jsr   DECODE6
            bcs   :dumal
            sta   DU_V2
            inx
            cpx   LINELEN
            bcs   :dumal
            lda   LINEBUF,x
            jsr   DECODE6
            bcs   :dumal
            sta   DU_V3
            inx
            stx   DU_LOFS
            lda   DU_REMAIN
            cmp   #3
            bcc   :dowrit
            lda   #3
:dowrit     jsr   RECON4
            lda   DU_REMAIN
            cmp   #4
            bcc   :dudone
            sec
            sbc   #3
            sta   DU_REMAIN
            bra   :dulp
:dudone     clc
            rts
:dumal      sec
            rts

*---------------------------------------------------------------
* DECLINEB -- base64 body line. Decodes as many 4-character
* groups as LINEBUF[0..LINELEN-1] holds; a '=' pad in the last
* group's 3rd and/or 4th position ends the line's real data
* (nothing may follow it on the same line). OUT: carry SET on a
* short line, an invalid character, or a misplaced '='.
* CLOBBERS: A, X, DB_OFS, DU_V0-3, RECON4's own.
*---------------------------------------------------------------
DECLINEB    stz   DB_OFS
:dblp       ldx   DB_OFS
            cpx   LINELEN
            bcc   :dbmore
            jmp   :dbend
:dbmore     lda   LINEBUF,x
            jsr   B64DEC
            bcs   :dbmal
            sta   DU_V0
            inx
            cpx   LINELEN
            bcs   :dbmal
            lda   LINEBUF,x
            jsr   B64DEC
            bcs   :dbmal
            sta   DU_V1
            inx
            cpx   LINELEN
            bcs   :dbmal
            lda   LINEBUF,x
            jsr   B64DEC
            bcc   :db3ok
            cmp   #0
            bne   :dbmal
            inx
            cpx   LINELEN
            bcs   :dbmal
            lda   LINEBUF,x
            jsr   B64DEC
            bcc   :dbmal
            cmp   #0
            bne   :dbmal
            inx
            cpx   LINELEN
            bcc   :dbmal
            lda   #1
            jsr   RECON4
            bra   :dbend
:db3ok      sta   DU_V2
            inx
            cpx   LINELEN
            bcs   :dbmal
            lda   LINEBUF,x
            jsr   B64DEC
            bcc   :db4ok
            cmp   #0
            bne   :dbmal
            inx
            cpx   LINELEN
            bcc   :dbmal
            lda   #2
            jsr   RECON4
            bra   :dbend
:db4ok      sta   DU_V3
* -- X (not yet DB_OFS) is this group's END offset -- save it
* -- to DB_OFS BEFORE calling RECON4 (which clobbers X via its
* -- own `ldx OUTFD`), the same fix READCHNK needed in
* -- src/bin/uuencode.s: nothing called here restores a
* -- caller's X.
            inx
            stx   DB_OFS
            lda   #3
            jsr   RECON4
            jmp   :dblp
:dbmal      sec
            rts
:dbend      clc
            rts

*---------------------------------------------------------------
* GETLINE -- one normalized (7-bit) line into LINEBUF/LINELEN,
* NUL-terminated. A CR, LF, or CRLF pair ends a line; a byte
* peeked past a CR that is NOT LF is pushed back (BUFPOS--,
* always safe: it was just read from the CURRENT buffer). OUT:
* carry SET only when nothing at all remains (true EOF); a
* trailing unterminated line still returns carry CLEAR once.
* CLOBBERS: A, X, LINELEN.
*---------------------------------------------------------------
GETLINE     stz   LINELEN
:glloop     jsr   GETBYTE
            bcs   :gleof
            and   #$7F
            cmp   #$0D
            beq   :glcr
            cmp   #$0A
            beq   :gldone
            ldx   LINELEN
            cpx   #LBCAP
            bcs   :glloop            ;too long -- drop, keep
                                     ;draining to the terminator
            sta   LINEBUF,x
            inc   LINELEN
            bra   :glloop
:glcr       jsr   GETBYTE
            bcs   :gldone
            and   #$7F
            cmp   #$0A
            beq   :gldone
            dec   BUFPOS
            bra   :gldone
:gleof      lda   LINELEN
            bne   :gldone
            sec
            rts
:gldone     ldx   LINELEN
            lda   #0
            sta   LINEBUF,x
            clc
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

