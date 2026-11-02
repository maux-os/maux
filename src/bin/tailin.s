*---------------------------------------------------------------
* tailin.s -- tail's input and accumulation layer: the 16-bit
* -N digit accumulator (MUL10ADD), the saturating line/byte
* counter (BUMPCNT), the ring-buffer line reader (RDLINE) and
* the buffered byte source (GETBYTE/REFILL). `put` by
* src/bin/tail.s (NOT a standalone binary -- the same
* put-module shape as cal.s's own calcalc.s), split out for the
* same reason units split anywhere: `as`'s 16,128-byte source
* window holds the resident manifest plus one put file at a
* time, and tail.s's own text alone was past it once -c landed.
* Every symbol here resolves against tail.s's own equates, zero
* page pointers and dum cells (BUFSZ/LINEMAX/MAXLINES/RINGSZ/
* RING/CBUF/BUFPOS/BUFLEN/SRCFD/WIDX/CNTLO/CNTHI/CURIDX/RL_LEN/
* MD_DIGIT/MD_TWOLO/MD_TWOHI/NEWNLO/NEWNHI/RPARM*) -- see that
* file's own header.
*---------------------------------------------------------------
*---------------------------------------------------------------
* MUL10ADD -- NEWNLO/NEWNHI = NEWNLO/NEWNHI*10 + A (A=0-9), the
* decimal-digit accumulator behind `-N`'s GETOPT clustering
* (each digit char of "-15" arrives as its own GETOPT call --
* see getopt.s's clustering loop; digits are just permitted
* "option letters" here). 16-bit so a many-digit N (e.g.
* "-99999999") cannot silently wrap byte-narrow before the
* MAXLINES check above catches it. CLOBBERS: A.
*---------------------------------------------------------------
MUL10ADD    sta   MD_DIGIT
            asl   NEWNLO
            rol   NEWNHI                ;NEWN = old*2
            lda   NEWNLO
            sta   MD_TWOLO
            lda   NEWNHI
            sta   MD_TWOHI
            asl   NEWNLO
            rol   NEWNHI                ;NEWN = old*4
            asl   NEWNLO
            rol   NEWNHI                ;NEWN = old*8
            clc
            lda   NEWNLO
            adc   MD_TWOLO
            sta   NEWNLO
            lda   NEWNHI
            adc   MD_TWOHI
            sta   NEWNHI                ;NEWN = old*10
            clc
            lda   NEWNLO
            adc   MD_DIGIT
            sta   NEWNLO
            bcc   :nc
            inc   NEWNHI
:nc         rts

*---------------------------------------------------------------
* BUMPCNT -- CNTLO/CNTHI++ (16-bit), saturating at $FFFF, same
* shape as wc.s's BUMP/uniq.s's BUMPRUN, scoped to tail's one
* lines-seen counter. Saturation is harmless here: only whether
* the count is < or >= NLINES (<=MAXLINES=64) is ever asked, and
* a saturated $FFFF is still >= any legal NLINES.
*---------------------------------------------------------------
BUMPCNT     lda   CNTLO
            cmp   #$FF
            bne   :inclo
            lda   CNTHI
            cmp   #$FF
            beq   :pinned
:inclo      inc   CNTLO
            bne   :out
            inc   CNTHI
:out        rts
:pinned     rts

*---------------------------------------------------------------
* RDLINE -- read one line from SRCFD into the 256-byte slot at
* (PTR0), NUL-terminated. Same overflow policy as uniq.s's
* GETLINE (see this file's header) -- ported to write through an
* indirect pointer instead of a fixed CURBUF, since tail needs a
* different slot each call. OUT: carry clear = a line is stored;
* carry set = EOF, nothing pending.
*---------------------------------------------------------------
RDLINE      stz   RL_LEN
:next       lda   RL_LEN
            cmp   #LINEMAX
            bcs   :haveline              ;forced break -- header
            jsr   GETBYTE
            bcs   :eofhit
            cmp   #$8D                   ;CR ends the line
            beq   :haveline
            cmp   #$0D             ;either terminator ends a
            beq   :haveline      ;line -- a foreign file
            ldy   RL_LEN
            sta   (PTR0),y
            inc   RL_LEN
            bra   :next
:haveline   ldy   RL_LEN
            lda   #0
            sta   (PTR0),y
            clc
            rts
:eofhit     lda   RL_LEN
            beq   :nothing
            ldy   RL_LEN
            lda   #0
            sta   (PTR0),y
            clc
            rts
:nothing    sec
            rts

*---------------------------------------------------------------
* GETBYTE / REFILL -- buffered input, same shape as wc.s/uniq.s.
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
            jsr   ADDOFF
            clc
            rts
:eof        sec
            rts

*---------------------------------------------------------------
* ADDOFF -- OFFLO/MID/HI += RPARM_TRANS: where in the file the
* bytes consumed so far end, 24 bits because that is the width
* of a ProDOS mark. Called after every successful read, by
* REFILL and by the follow loop. CLOBBERS: A.
*---------------------------------------------------------------
ADDOFF      clc
            lda   OFFLO
            adc   RPARM_TRANS
            sta   OFFLO
            lda   OFFMID
            adc   RPARM_TRANS+1
            sta   OFFMID
            lda   OFFHI
            adc   #0
            sta   OFFHI
            rts

*---------------------------------------------------------------
* FOLLOW -- tail -f. One poll a second, forever: wait for the
* tick count to pass TARGET, then TF_DRAIN. The wait SPINS on
* SYS_TICK exactly as sleep.s does (there is no userland yield;
* the scheduler preempts on quantum, so nothing else starves).
* Refuses, like sleep, when there is no tick to count -- a spin
* on a frozen counter would hang silently. NEVER RETURNS.
*---------------------------------------------------------------
POLLTICKS   equ   60                ;one second at 60 Hz

FOLLOW      jsr   TF_SAMPLE
            lda   TF_TICKBUF            ;mode: 1 mouse VBL,
            cmp   #1                    ;2 Mockingboard
            beq   :clock
            cmp   #2
            beq   :clock
            lda   #<NOTICKMSG
            sta   PTR0
            lda   #>NOTICKMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT
:clock      ldx   #0
:zero       lda   TF_TICKBUF+1,x
            sta   TF_TARGET,x
            inx
            cpx   #4
            bne   :zero
            clc
            lda   TF_TARGET
            adc   #POLLTICKS
            sta   TF_TARGET
            bcc   :spin
            inc   TF_TARGET+1
            bne   :spin
            inc   TF_TARGET+2
            bne   :spin
            inc   TF_TARGET+3
:spin       jsr   TF_SAMPLE
            ldx   #3
:chk        lda   TF_TICKBUF+1,x        ;sampled >= TARGET,
            cmp   TF_TARGET,x           ;high byte first
            bcc   :spin
            bne   :due
            dex
            bpl   :chk
:due        jsr   TF_DRAIN
            jmp   FOLLOW

*---------------------------------------------------------------
* TF_SAMPLE -- one SYS_TICK into TF_TICKBUF. Checks the carry:
* the buffer is `dum` storage, so a failed call leaves garbage
* that could read as a valid mode (src/bin/sleep.s, SAMPLE).
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
TF_SAMPLE   lda   #<TF_TICKBUF
            sta   PTR0
            lda   #>TF_TICKBUF
            sta   PTR0+1
            jsr   SC_TICK
            bcs   :fail
            rts
:fail       lda   #<TICKFAILMSG
            sta   PTR0
            lda   #>TICKFAILMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

*---------------------------------------------------------------
* TF_DRAIN -- open the file, seek to OFF, copy what is there to
* stdout as raw bytes, close. An OPEN that fails (a writer has
* the file at this instant, or it is gone) just means "next
* poll". A SET_MARK that fails means the file is now SHORTER
* than OFF: start again from the top. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
TF_DRAIN    lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   :out
            lda   OPARM_REF
            sta   SMREF
            lda   #2
            sta   SMCNT
            lda   OFFLO
            sta   SMPOS
            lda   OFFMID
            sta   SMPOS+1
            lda   OFFHI
            sta   SMPOS+2
            lda   #<SMCNT
            ldx   #>SMCNT
            jsr   SC_SETMARK
            bcc   :marked
            stz   OFFLO
            stz   OFFMID
            stz   OFFHI
:marked     lda   OPARM_REF
            sta   RPARM_REF
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :close
            lda   RPARM_TRANS
            beq   :close
            sta   TF_CNT
            jsr   ADDOFF
            stz   TF_IDX
:emit       ldy   TF_IDX
            lda   CBUF,y
            ldx   #FD_STDOUT
            jsr   PUTC
            inc   TF_IDX
            lda   TF_IDX
            cmp   TF_CNT
            bne   :emit
            bra   :marked
:close      lda   OPARM_REF
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
:out        rts
