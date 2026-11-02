*---------------------------------------------------------------
* uniqio.s -- uniq's buffered input layer (GETLINE/GETBYTE/
* REFILL), split out of uniq.s for S9's as-window budget
* (docs/S9-PLAN.md sec 5, W4 rehearsal: uniq was the smallest
* over-window unit, by 306 bytes). Put by uniq.s exactly where
* the code used to sit -- one assembly stream, byte-identical;
* same put-module precedent as sed.s/sedexec.s. Split at a
* GLOBAL boundary (GETLINE's banner) so no :local reparents.
*---------------------------------------------------------------
*---------------------------------------------------------------
* GETLINE -- next line from SRCFD into CURBUF, NUL-terminated.
* OUT: carry clear = a line is in CURBUF; carry set = EOF with
* nothing pending. A final unterminated line IS returned.
*
* OVERFLOW: not silent truncation -- see header. Once LINEMAX
* bytes have accumulated, the line is returned as-is WITHOUT
* reading further; the next GETLINE call resumes on the very
* next byte and returns the remainder as a further line.
*---------------------------------------------------------------
GETLINE     stz   LINELEN
:next       lda   LINELEN
            cmp   #LINEMAX
            bcs   :haveline          ;forced break -- see header
            jsr   GETBYTE
            bcs   :eofhit
            cmp   #$8D               ;either terminator ends the
            beq   :haveline          ;line -- a foreign file
            cmp   #$0D               ;carries ProDOS semantics
            beq   :haveline
            ldy   LINELEN
            sta   CURBUF,y
            inc   LINELEN
            bra   :next

:haveline   ldy   LINELEN
            lda   #0
            sta   CURBUF,y
            clc
            rts

:eofhit     lda   LINELEN
            beq   :nothing
            ldy   LINELEN
            lda   #0
            sta   CURBUF,y
            clc
            rts
:nothing    sec
            rts

*---------------------------------------------------------------
* GETBYTE / REFILL -- buffered input, same shape as wc.s/grep.s.
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

