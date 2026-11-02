*---------------------------------------------------------------
* prfmt.s -- pr's page-rendering engine: VISIBLE/PUTOFS/
* PRINTPAD/PR2DIG0/PR2DIGSP/PRDATE/PRINTHDR/EMITLBUF/PRBODY/
* READLN/PRFILE/GETBYTE/REFILL. `put` by src/bin/pr.s (NOT a
* standalone binary -- the same put-module shape as nl.s's own
* nlfmt.s), split from pr.s because pr.s's own resident text
* alone was over the 16,128-byte check-dialect as-window
* budget. Every symbol here resolves against pr.s's own
* equates (LBUFCAP) and data (OFFSETVAL/EFFT/PAGELEN/BODYCAP/
* BODYCNT/PAGENUM/STARTPAGE/HAVEH/HAVEN/DFLAG/NCHAR/NWIDTH/
* LINENOLO/LINENOHI/HDATE/HTIME/FNAMEPTR/CURFD/HEADERBUF/LBUF/
* LLEN/RLEOF/BUFPOS/BUFLEN/CBUF/PRDIGBUF/the PR_* date scratch)
* -- see that file's own header for the page/date arithmetic
* this codifies. PRFILE is the one entry point pr.s's own file
* loop calls.
*---------------------------------------------------------------

*---------------------------------------------------------------
* VISIBLE -- OUT: carry SET if the current page should actually
* be written (effective -t, or PAGENUM >= STARTPAGE). CLOBBERS:
* A.
*---------------------------------------------------------------
VISIBLE     lda   EFFT
            bne   :visy
            lda   PAGENUM
            cmp   STARTPAGE
            bcc   :visn
:visy       sec
            rts
:visn       clc
            rts

*---------------------------------------------------------------
* PUTOFS -- OFFSETVAL literal spaces to stdout. CLOBBERS: A, X.
*---------------------------------------------------------------
PUTOFS      lda   OFFSETVAL
            beq   :podn
            sta   PO_CNT
:polp       lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            dec   PO_CNT
            lda   PO_CNT
            bne   :polp
:podn       rts

*---------------------------------------------------------------
* PRINTPAD -- IN: A = number of blank (offset-prefixed) lines.
* CLOBBERS: A, X.
*---------------------------------------------------------------
PRINTPAD    sta   PP_CNT
            lda   PP_CNT
            beq   :ppdn
:pplp       jsr   PUTOFS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            dec   PP_CNT
            lda   PP_CNT
            bne   :pplp
:ppdn       rts

*---------------------------------------------------------------
* PR2DIG0 -- IN: A = 0-99. Prints two zero-padded high-bit
* digits. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PR2DIG0     ldy   #0
:p0t        cmp   #10
            bcc   :p0o
            sec
            sbc   #10
            iny
            bra   :p0t
:p0o        sta   PR2_ONE
            tya
            ora   #$B0
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   PR2_ONE
            ora   #$B0
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* PR2DIGSP -- IN: A = 0-99. Prints a SPACE-padded (not
* zero-padded) tens digit, then the units digit. CLOBBERS:
* A, X, Y.
*---------------------------------------------------------------
PR2DIGSP    ldy   #0
:pst        cmp   #10
            bcc   :pso
            sec
            sbc   #10
            iny
            bra   :pst
:pso        sta   PR2_ONE
            cpy   #0
            bne   :psnz
            lda   #$A0
            bra   :pse
:psnz       tya
            ora   #$B0
:pse        ldx   #FD_STDOUT
            jsr   PUTC
            lda   PR2_ONE
            ora   #$B0
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* PRDATE -- prints "%b %e %H:%M %Y" from HDATE/HTIME (packed
* ProDOS date/time, same layout as date.s/lsprint.s). A zero
* date/time (never a real GET_FILE_INFO/SC_CLOCK answer, but
* defensive against one) prints a fixed placeholder instead of
* decoding month 0. CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
PRDATE      lda   HDATE
            ora   HDATE+1
            bne   :pdz
            lda   #<NODATE
            sta   PTR0
            lda   #>NODATE
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            rts
:pdz        lda   HDATE
            and   #$1F
            sta   PR_DAY
            lda   HDATE
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            and   #$07
            sta   PR_MON
            lda   HDATE+1
            and   #$01
            asl   a
            asl   a
            asl   a
            ora   PR_MON
            sta   PR_MON
            lda   HDATE+1
            lsr   a
            and   #$7F
            sta   PR_YR7
            lda   HTIME+1
            sta   PR_HOUR
            lda   HTIME
            sta   PR_MIN

            lda   PR_MON
            sec
            sbc   #1
            asl   a
            asl   a
            clc
            adc   #<MONABBR
            sta   PTR0
            lda   #>MONABBR
            adc   #0
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   PR_DAY
            jsr   PR2DIGSP
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   PR_HOUR
            jsr   PR2DIG0
            lda   #$BA
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   PR_MIN
            jsr   PR2DIG0
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC

            lda   PR_YR7
            cmp   #78
            bcc   :pdy2k
            lda   #<1900
            sta   PR_YRLO
            lda   #>1900
            sta   PR_YRHI
            bra   :pdya
:pdy2k      lda   #<2000
            sta   PR_YRLO
            lda   #>2000
            sta   PR_YRHI
:pdya       clc
            lda   PR_YRLO
            adc   PR_YR7
            sta   PR_YRLO
            lda   PR_YRHI
            adc   #0
            sta   PR_YRHI
            lda   PR_YRLO
            sta   U2DEC_VAL
            lda   PR_YRHI
            sta   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
            rts

*---------------------------------------------------------------
* PRINTHDR -- the 5-line page header (offset-prefixed on every
* line, per this build's own choice -- measured only for the
* dateline, see this file's own header note). CLOBBERS: A, X,
* Y, PTR0, PTR1.
*---------------------------------------------------------------
PRINTHDR    jsr   PUTOFS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   PUTOFS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   PUTOFS
            jsr   PRDATE
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   HAVEH
            bne   :phtitle
            lda   FNAMEPTR
            sta   PTR0
            lda   FNAMEPTR+1
            sta   PTR0+1
            bra   :phpr
:phtitle    lda   #<HEADERBUF
            sta   PTR0
            lda   #>HEADERBUF
            sta   PTR0+1
:phpr       ldx   #FD_STDOUT
            jsr   PUTS
            lda   #<PAGESTR
            sta   PTR0
            lda   #>PAGESTR
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   PAGENUM
            sta   U2DEC_VAL
            stz   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   PUTOFS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   PUTOFS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* EMITLBUF -- print LBUF[0..LLEN) verbatim, no CR. CLOBBERS:
* A, X, Y.
*---------------------------------------------------------------
EMITLBUF    stz   EL_IDX
:ellp       lda   EL_IDX
            cmp   LLEN
            bcs   :eldn
            ldy   EL_IDX
            lda   LBUF,y
            jsr   EMCH
            inc   EL_IDX
            bra   :ellp
:eldn       rts

*---------------------------------------------------------------
* PRBODY -- print one content line (offset, then -n numbering if
* HAVEN, then the line, then CR, then a second CR if DFLAG).
* CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
PRBODY      jsr   PUTOFS
            jsr   EMBEG
            lda   HAVEN
            beq   :pbnn
            lda   LINENOLO
            sta   U2DEC_VAL
            lda   LINENOHI
            sta   U2DEC_VAL+1
            jsr   EMNUM
            inc   LINENOLO
            bne   :pbnn
            inc   LINENOHI
:pbnn       jsr   EMITLBUF
            jsr   EMCR
            lda   DFLAG
            beq   :pbdn
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:pbdn       rts

*---------------------------------------------------------------
* READLN -- fill LBUF/LLEN with the next line (CR excluded).
* OUT: carry SET = nothing left at all; carry CLEAR = a line is
* ready (RLEOF also set if it was the last one, no trailing CR).
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
READLN      stz   LLEN
:rllp       jsr   GETBYTE
            bcs   :rleof
            cmp   #$8D
            beq   :rlcr
            ldx   EFLAG
            beq   :rlput
            cmp   ETABCH
            bne   :rlput
:rlex       lda   #$A0
            jsr   STORECH
            lda   LLEN
            cmp   #LBUFCAP
            bcs   :rllp
:rlmod      cmp   EGAP
            bcc   :rlrem
            sbc   EGAP
            bra   :rlmod
:rlrem      cmp   #0
            bne   :rlex
            bra   :rllp
:rlput      jsr   STORECH
            bra   :rllp
:rlcr       clc
            rts
:rleof      lda   LLEN
            bne   :rltl
            sec
            rts
:rltl       lda   #1
            sta   RLEOF
            clc
            rts

*---------------------------------------------------------------
* STORECH -- IN: A = byte. Appends to LBUF; silently dropped
* once LBUFCAP is reached. CLOBBERS: Y.
*---------------------------------------------------------------
STORECH     ldy   LLEN
            cpy   #LBUFCAP
            bcs   :scdn
            sta   LBUF,y
            inc   LLEN
:scdn       rts

*---------------------------------------------------------------
* PGEND -- IN: A = blank lines that would pad the page. -F
* writes
* one form feed instead of the pad. CLOBBERS: A, X.
*---------------------------------------------------------------
PGEND       ldx   FFLAG
            beq   :pgpad
            lda   #$8C
            ldx   #FD_STDOUT
            jmp   PUTC
:pgpad      jmp   PRINTPAD

*---------------------------------------------------------------
* PRFILE -- paginate CURFD to stdout, using FNAMEPTR/HDATE/HTIME
* already set by the caller. CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
PRFILE      lda   #<CBUF
            sta   PTR2
            lda   #>CBUF
            sta   PTR2+1
            stz   BUFPOS
            stz   BUFLEN
            stz   RLEOF
            lda   #1
            sta   PAGENUM
            sta   LINENOLO
            stz   LINENOHI
            stz   BODYCNT
            lda   TFLAG
            bne   :pfe1
            lda   PAGELEN
            cmp   #11
            bcs   :pfe0
:pfe1       lda   #1
            sta   EFFT
            bra   :pfed
:pfe0       stz   EFFT
:pfed       lda   PAGELEN
            sec
            sbc   #10
            sta   BODYCAP

:pfloop     jsr   READLN
            bcs   :pftr
            lda   EFFT
            bne   :pfnh
            lda   BODYCNT
            bne   :pfnh
            jsr   VISIBLE
            bcc   :pfnh
            jsr   PRINTHDR
:pfnh       jsr   VISIBLE
            bcc   :pfnp
            jsr   PRBODY
:pfnp       inc   BODYCNT
            lda   EFFT
            bne   :pfnc
            lda   BODYCNT
            cmp   BODYCAP
            bcc   :pfnc
            jsr   VISIBLE
            bcc   :pfnt
            lda   PAGELEN
            sec
            sbc   #5
            sec
            sbc   BODYCNT
            jsr   PGEND
:pfnt       stz   BODYCNT
            inc   PAGENUM
:pfnc       lda   RLEOF
            bne   :pftr
            jmp   :pfloop

:pftr       lda   EFFT
            bne   :pfcl
            lda   BODYCNT
            beq   :pfcl
            jsr   VISIBLE
            bcc   :pfcl
            lda   PAGELEN
            sec
            sbc   #5
            sec
            sbc   BODYCNT
            jsr   PGEND
:pfcl       rts

*---------------------------------------------------------------
* GETBYTE / REFILL -- buffered input from CURFD, same shape as
* head.s/nl.s.
*---------------------------------------------------------------
GETBYTE     ldy   BUFPOS
            cpy   BUFLEN
            bcc   :have
            jsr   REFILL
            bcs   :eof
            ldy   BUFPOS
:have       lda   (PTR2),y
            inc   BUFPOS
            clc
            rts
:eof        sec
            rts

REFILL      lda   CURFD
            sta   RPARM_REF
            lda   PTR2
            sta   RPARM_BUF
            lda   PTR2+1
            sta   RPARM_BUF+1
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

NODATE      asc   "??? ??"
            dfb   0
PAGESTR     asc   " Page "
            dfb   0

MONABBR     asc   "Jan"
            dfb   0
            asc   "Feb"
            dfb   0
            asc   "Mar"
            dfb   0
            asc   "Apr"
            dfb   0
            asc   "May"
            dfb   0
            asc   "Jun"
            dfb   0
            asc   "Jul"
            dfb   0
            asc   "Aug"
            dfb   0
            asc   "Sep"
            dfb   0
            asc   "Oct"
            dfb   0
            asc   "Nov"
            dfb   0
            asc   "Dec"
            dfb   0
