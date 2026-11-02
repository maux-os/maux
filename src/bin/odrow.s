*---------------------------------------------------------------
* odrow.s -- od's dump engine: the offset column (PRHEX4, in
* whichever base -A named), the buffered byte source
* (GETBYTE/REFILL) and the -j/-N operand parser
* (OD_PARSENUM/OD_MUL10ADD). `put` by src/bin/od.s (NOT a
* standalone binary -- the same put-module shape as cal.s's own
* calcalc.s), split out for the same reason units split
* anywhere: `as`'s 16,128-byte source window holds the resident
* manifest plus one put file at a time, and od.s's own text
* alone was past it once -j/-N landed. Every symbol here
* resolves against od.s's own equates, zero page pointers and
* dum cells (BUFSZ/ROWMAX/LINEBUF/CBUF/BUFPOS/BUFLEN/LINECNT/
* ROWIDX/OFFSET/OD_OBYTE/OD_NVAL/OD_NVAL2/OD_DIGIT/OD_T2LO/
* OD_T2HI/SRCFD/REMAIN/RPARM*) -- see that file's own header.
*---------------------------------------------------------------
*---------------------------------------------------------------
* PRHEX4 -- print OFFSET (2 bytes) as 4 hex digits, no prefix.
* Thin od.s wrapper over liba's PRHEX16 (docs/FAT.md sec 3).
*---------------------------------------------------------------
*---------------------------------------------------------------
* PRHEX4 -- the offset column, in whichever base -A named. Still
* called PRHEX4 at every site because hex is what it prints
* unless told otherwise, and renaming it would touch more code
* than the feature does.
*
* WIDTHS ARE FIXED PER BASE, which is what makes the column a
* column: 4 hex digits, 6 octal, 5 decimal -- each the widest a
* 16-bit offset can need. A host `od` pads its decimal column
* the same way for the same reason.
*---------------------------------------------------------------
PRHEX4      lda   OD_ABASE
            cmp   #$EE                  ;'n' -- print nothing at
            beq   :offnone              ;all
            cmp   #$E4                  ;'d'
            beq   :offdec
            cmp   #$EF                  ;'o'
            beq   :offoct
            lda   OFFSET+1
            ldy   OFFSET
            ldx   #FD_STDOUT
            jsr   PRHEX16
:offnone    rts

*-- SIX octal digits, three bits at a time from the top. The top
*-- digit of a 16-bit value is 0 or 1, the other five are 0-7.
:offoct     lda   #5
            sta   OD_ASUP
:ooloop     jsr   OD_OCTDIG
            dec   OD_ASUP
            bpl   :ooloop
            rts

*-- FIVE decimal digits by repeated subtraction of each power of
*-- ten, leading zeros printed (not suppressed) so the column
*-- keeps its width.
:offdec     lda   OFFSET
            sta   OD_ADLO
            lda   OFFSET+1
            sta   OD_ADHI
            ldx   #0
:odloop     lda   #0
            sta   OD_ASUP
:odsub      sec
            lda   OD_ADLO
            sbc   OD_POW10L,x
            tay
            lda   OD_ADHI
            sbc   OD_POW10H,x
            bcc   :oddone
            sty   OD_ADLO
            sta   OD_ADHI
            inc   OD_ASUP
            bra   :odsub
:oddone     lda   OD_ASUP
            ora   #$B0
            phx
            ldx   #FD_STDOUT
            jsr   PUTC
            plx
            inx
            cpx   #5
            bne   :odloop
            rts

OD_POW10L   dfb   $10,$E8,$64,$0A,$01
OD_POW10H   dfb   $27,$03,$00,$00,$00

*---------------------------------------------------------------
* OD_OCTDIG -- print the octal digit OD_ASUP places up from the
* bottom of OFFSET (OD_ASUP 0 = least significant). The index is
* a CELL and not X because this ends in PUTC, which wants X for
* the fd. Shifts a copy right 3*X times rather than
* keeping a running remainder: six digits at three shifts each
* is cheaper in BYTES than the state a running version needs,
* and this runs once per row.
*---------------------------------------------------------------
OD_OCTDIG   lda   OFFSET
            sta   OD_ADLO
            lda   OFFSET+1
            sta   OD_ADHI
            ldx   OD_ASUP
            beq   :odgot
:odshift    lsr   OD_ADHI
            ror   OD_ADLO
            lsr   OD_ADHI
            ror   OD_ADLO
            lsr   OD_ADHI
            ror   OD_ADLO
            dex
            bne   :odshift
:odgot      lda   OD_ADLO
            and   #$07
            ora   #$B0
            ldx   #FD_STDOUT
            jmp   PUTC

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

*---------------------------------------------------------------
* OD_PARSENUM -- IN: PTR0 = operand text (-j/-N's own OPTARG).
* OUT: carry CLEAR, OD_NVAL/OD_NVAL2 = its unsigned 16-bit value
* (tail.s's own MUL10ADD shape, renamed); carry SET on empty or
* any non-digit byte. CLOBBERS: A, Y.
*---------------------------------------------------------------
OD_PARSENUM stz   OD_NVAL
            stz   OD_NVAL2
            ldy   #0
            lda   (PTR0),y
            beq   :bad
:loop       lda   (PTR0),y
            beq   :ok
            and   #$7F
            cmp   #'0'
            bcc   :bad
            cmp   #'9'+1
            bcs   :bad
            and   #$0F
            jsr   OD_MUL10ADD
            iny
            bra   :loop
:ok         clc
            rts
:bad        sec
            rts

*---------------------------------------------------------------
* OD_MUL10ADD -- OD_NVAL/OD_NVAL2 = OD_NVAL/OD_NVAL2*10 + A
* (A=0-9). CLOBBERS: A.
*---------------------------------------------------------------
OD_MUL10ADD sta   OD_DIGIT
            asl   OD_NVAL
            rol   OD_NVAL2
            lda   OD_NVAL
            sta   OD_T2LO
            lda   OD_NVAL2
            sta   OD_T2HI
            asl   OD_NVAL
            rol   OD_NVAL2
            asl   OD_NVAL
            rol   OD_NVAL2
            clc
            lda   OD_NVAL
            adc   OD_T2LO
            sta   OD_NVAL
            lda   OD_NVAL2
            adc   OD_T2HI
            sta   OD_NVAL2
            clc
            lda   OD_NVAL
            adc   OD_DIGIT
            sta   OD_NVAL
            bcc   :nc
            inc   OD_NVAL2
:nc         rts
