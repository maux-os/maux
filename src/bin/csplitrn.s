*---------------------------------------------------------------
* csplitrn.s -- csplit's segment engine (NUMBER/regex/repeat
* argument handlers, piece open/close/write, the source-line
* reader, error cleanup, and decimal parsing), `put` by
* src/bin/csplit.s (NOT a standalone binary -- the same put-
* module shape as cut.s's cutlist.s), split out purely to fit
* real Merlin's 41,215-byte source buffer: csplit.s alone
* measured over it, stripped, once regex.s/regex2.s (mandatory,
* shared, fixed -- see csplit.s's own header) are charged as its
* largest `put`. Every symbol here resolves against csplit.s's
* own equates/bss and data (WANTK/WANTS/NDIG/PFXBUF/PFXLEN,
* PIECEIDX/CUROPEN/BYTCNTLO/HI, LINENO/SLEN/SHAVE/SHADCR/
* SLINEBUF, PATBUF/LASTBRE/SKIPMODE/OFF*, the USAGEMSG family of
* strings and the OPARM/RPARM/CPARM/DPARM parmlists).
*---------------------------------------------------------------
*---------------------------------------------------------------
* DONUM -- IN: PTR0 = the argv word (a decimal line number). The
* segment [current line .. NUMBER-1] becomes one piece (empty if
* NUMBER equals the current line), position left at NUMBER
* (unread). NUMBER < current line is the range error.
*---------------------------------------------------------------
DONUM       jsr   PARSEDEC
            cpy   #0
            bne   :have
            jmp   USAGEEXIT
:have       lda   (PTR0),y
            beq   :ok
            jmp   USAGEEXIT
:ok         lda   ACCLO
            sta   TARGLO
            lda   ACCHI
            sta   TARGHI
            stz   HAVELAST
            lda   TARGHI
            cmp   LINENO+1
            bcc   :outrange
            bne   :inrange
            lda   TARGLO
            cmp   LINENO
            bcc   :outrange
:inrange    jsr   OPENPIECE
:nlp        lda   LINENO+1
            cmp   TARGHI
            bcc   :cont
            bne   :stop
            lda   LINENO
            cmp   TARGLO
            bcs   :stop
:cont       lda   SHAVE
            bne   :ok2
            jmp   NUMRANGEERR
:ok2        jsr   WRITELINE
            jsr   GETSLN
            jmp   :nlp
:stop       jmp   CLOSEPIECE
:outrange   jmp   NUMRANGEERR

*---------------------------------------------------------------
* DOREGEX -- IN: PTR0 = argv word ("/bre/[+-n]" or "%bre%..").
* Copies the BRE into PATBUF (and LASTBRE, for a later {n}),
* records SKIPMODE/LASTSKIP and the offset (also into LASTOFF*),
* then runs RUNSEG.
*---------------------------------------------------------------
DOREGEX     ldy   #0
            lda   (PTR0),y
            sta   DELIM
            cmp   #$A5
            bne   :notskip
            lda   #1
            sta   SKIPMODE
            bra   :ext
:notskip    stz   SKIPMODE
:ext        iny
            ldx   #0
:cplp       lda   (PTR0),y
            bne   :cplpok
            jmp   :baddlm
:cplpok     cmp   DELIM
            beq   :cpdone
            sta   PATBUF,x
            iny
            inx
            bra   :cplp
:cpdone     lda   #0
            sta   PATBUF,x
            iny
            stz   OFFNEG
            stz   OFFLO
            stz   OFFHI
            lda   (PTR0),y
            beq   :nooff
            cmp   #$AB                   ;'+'
            beq   :sgn
            cmp   #$AD                   ;'-'
            bne   :parseoff
            lda   #1
            sta   OFFNEG
:sgn        iny
:parseoff   sty   OFFYSTRT
            jsr   PDCORE
            cpy   OFFYSTRT
            bne   :havedig
            jmp   USAGEEXIT
:havedig    lda   (PTR0),y
            bne   :baddlm
            lda   OFFNEG
            bne   :nooff              ;negative -- clamp to 0
            lda   ACCLO
            sta   OFFLO
            lda   ACCHI
            sta   OFFHI
:nooff      lda   #<PATBUF
            sta   PTR0
            lda   #>PATBUF
            sta   PTR0+1
            lda   #<LASTBRE
            sta   PTR1
            lda   #>LASTBRE
            sta   PTR1+1
            jsr   STRCPY
            lda   SKIPMODE
            sta   LASTSKIP
            lda   OFFLO
            sta   LASTOFLO
            lda   OFFHI
            sta   LASTOFHI
            lda   #1
            sta   HAVELAST
            stz   REPMODE
            jmp   RUNSEG
:baddlm     jmp   USAGEEXIT

*---------------------------------------------------------------
* DOREPEAT -- "{n}": IN PTR0 = the argv word "{n}". Requires a
* preceding /bre/ or %bre/ arg (HAVELAST); runs RUNSEG n MORE
* times, restoring PATBUF/SKIPMODE/OFFLO/OFFHI from the saved
* LASTBRE/LASTSKIP/LASTOFLO/LASTOFHI each time.
*---------------------------------------------------------------
DOREPEAT    lda   HAVELAST
            bne   :ok
            jmp   USAGEEXIT
:ok         ldy   #1
            sty   OFFYSTRT
            jsr   PDCORE
            cpy   OFFYSTRT
            bne   :havedig
            jmp   USAGEEXIT
:havedig    lda   (PTR0),y
            cmp   #$FD                  ;'}'
            beq   :term
            jmp   USAGEEXIT
:term       lda   ACCLO
            sta   REPCNT
            lda   ACCHI
            sta   REPCNT+1
:rlp        lda   REPCNT
            ora   REPCNT+1
            beq   :done
            lda   REPCNT
            bne   :rdeclo
            dec   REPCNT+1
:rdeclo     dec   REPCNT
            lda   #<LASTBRE
            sta   PTR0
            lda   #>LASTBRE
            sta   PTR0+1
            lda   #<PATBUF
            sta   PTR1
            lda   #>PATBUF
            sta   PTR1+1
            jsr   STRCPY
            lda   LASTSKIP
            sta   SKIPMODE
            lda   LASTOFLO
            sta   OFFLO
            lda   LASTOFHI
            sta   OFFHI
            lda   #1
            sta   REPMODE
            jsr   RUNSEG
            jmp   :rlp
:done       rts

*---------------------------------------------------------------
* RUNSEG -- one regex/pct segment: search forward from the
* CURRENT line (already loaded via GETSLN) for a line matching
* PATBUF; on a hit, copy/discard OFFLO more lines, then cut.
* EOF before a match is REGEXERR. IN: SKIPMODE, PATBUF, OFFLO/
* OFFHI.
*---------------------------------------------------------------
RUNSEG      lda   SKIPMODE
            bne   :chkrep
            jsr   OPENPIECE
*-- IN: REPMODE. A repeat's ({n}) currently-loaded line is the
*-- PREVIOUS match -- already established, unconditionally the
*-- first line of THIS new piece -- so it is written/discarded
*-- without re-testing (verified live: `csplit F /M/ {2}` puts
*-- the SECOND M-line at the head of the SECOND piece, not held
*-- again as an empty one) and the search resumes from the line
*-- after it. A fresh /bre/ or %bre/ arg (REPMODE=0) tests its
*-- own first line as usual.
:chkrep     lda   REPMODE
            beq   :sloop
            lda   SKIPMODE
            bne   :rnowrit
            jsr   WRITELINE
:rnowrit    jsr   GETSLN
*-- test the CURRENT line BEFORE writing it anywhere -- POSIX's
*-- own boundary (verified live against this host's csplit): a
*-- plain (offset 0) match line becomes the FIRST line of the
*-- NEXT section, never the last line of this one. A non-
*-- matching line is unconditionally part of THIS section, so it
*-- writes/discards immediately and the scan moves on.
:sloop      lda   SHAVE
            bne   :havln
            jmp   REGEXERR
:havln      lda   #<SLINEBUF
            sta   PTR0
            lda   #>SLINEBUF
            sta   PTR0+1
            lda   #<PATBUF
            sta   PTR1
            lda   #>PATBUF
            sta   PTR1+1
            lda   #<SLINEBUF
            sta   PTR2
            lda   #>SLINEBUF
            sta   PTR2+1
            jsr   RE_MATCH
            bcc   :hit
            lda   SKIPMODE
            bne   :nowrit1
            jsr   WRITELINE
:nowrit1    jsr   GETSLN
            jmp   :sloop
*-- matched, line still unwritten. offset 0: leave it loaded for
*-- the NEXT segment, cut now. offset N>=1: this line (and N-1
*-- more after it) belong to THIS section -- see header.
:hit        lda   OFFLO
            ora   OFFHI
            beq   :cut
            lda   SKIPMODE
            bne   :nowrit2
            jsr   WRITELINE
:nowrit2    jsr   GETSLN
            lda   OFFLO
            bne   :fdeclo
            dec   OFFHI
:fdeclo     dec   OFFLO
:extralp    lda   OFFLO
            ora   OFFHI
            beq   :cut
            lda   SHAVE
            beq   :cut
            lda   SKIPMODE
            bne   :ediscard
            jsr   WRITELINE
:ediscard   jsr   GETSLN
            lda   OFFLO
            bne   :edeclo
            dec   OFFHI
:edeclo     dec   OFFLO
            jmp   :extralp
:cut        lda   SKIPMODE
            bne   :rt
            jmp   CLOSEPIECE
:rt         rts

*---------------------------------------------------------------
* OPENPIECE -- build the next piece's name (PFXBUF + zero-padded
* PIECEIDX, NDIG digits), CREATE+OPEN it, zero its byte count.
*---------------------------------------------------------------
OPENPIECE   jsr   FMTNUM
            jsr   BUILDNAME
            lda   #<PNAMEBUF
            sta   PTR0
            lda   #>PNAMEBUF
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            jsr   CREAT
            bcc   :ok
            jmp   CREATEFAIL
:ok         sta   CURFD
            lda   #1
            sta   CUROPEN
            stz   BYTCNTLO
            stz   BYTCNTHI
            rts

*---------------------------------------------------------------
* CLOSEPIECE -- FCLOSE the current piece; print its byte count
* (unless -s) and advance PIECEIDX for the next one.
*---------------------------------------------------------------
CLOSEPIECE  ldx   CURFD
            jsr   FCLOSE
            bcc   :ok
            jmp   WRITEFAIL
:ok         stz   CUROPEN
            inc   PIECEIDX
            lda   WANTS
            bne   :rt
            lda   BYTCNTLO
            sta   U2DEC_VAL
            lda   BYTCNTHI
            sta   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:rt         rts

*---------------------------------------------------------------
* WRITELINE -- append SLINEBUF[0..SLEN-1] (plus a CR iff
* SHADCR) to the current piece, counting bytes into BYTCNTLO/HI.
*---------------------------------------------------------------
WRITELINE   ldy   #0
:lp         cpy   SLEN
            beq   :crchk
            lda   SLINEBUF,y
            pha
            ldx   CURFD
            pla
            jsr   PUTC
            jsr   BCINC
            iny
            bra   :lp
:crchk      lda   SHADCR
            beq   :rt
            lda   #$8D
            ldx   CURFD
            jsr   PUTC
            jsr   BCINC
:rt         rts

BCINC       inc   BYTCNTLO
            bne   :rt
            inc   BYTCNTHI
:rt         rts

*---------------------------------------------------------------
* BUILDNAME -- PNAMEBUF = PFXBUF[0..PFXLEN-1] + NUMDIGS[0..
* NDIG-1] + NUL. IN: NUMDIGS already filled (FMTNUM).
*---------------------------------------------------------------
BUILDNAME   ldy   #0
            ldx   #0
:cp1        cpx   PFXLEN
            beq   :cp1d
            lda   PFXBUF,x
            sta   PNAMEBUF,y
            iny
            inx
            bra   :cp1
:cp1d       ldx   #0
:cp2        cpx   NDIG
            beq   :cp2d
            lda   NUMDIGS,x
            sta   PNAMEBUF,y
            iny
            inx
            bra   :cp2
:cp2d       lda   #0
            sta   PNAMEBUF,y
            rts

*---------------------------------------------------------------
* FMTNUM -- NUMDIGS[0..NDIG-1] = PIECEIDX (0-255), zero-padded
* decimal, NDIG wide (truncated to the low NDIG digits if NDIG
* is under 3 -- never exercised above 255 pieces in this v1).
*---------------------------------------------------------------
FMTNUM      lda   PIECEIDX
            sta   FN_V
            stz   FN_H
:h100       lda   FN_V
            cmp   #100
            bcc   :hdone
            sec
            sbc   #100
            sta   FN_V
            inc   FN_H
            bra   :h100
:hdone      stz   FN_T
:t10        lda   FN_V
            cmp   #10
            bcc   :tdone
            sec
            sbc   #10
            sta   FN_V
            inc   FN_T
            bra   :t10
:tdone      lda   FN_H
            ora   #$B0
            sta   DIGS3
            lda   FN_T
            ora   #$B0
            sta   DIGS3+1
            lda   FN_V
            ora   #$B0
            sta   DIGS3+2
            lda   NDIG
            cmp   #3
            bcs   :wide
            lda   #3
            sec
            sbc   NDIG
            tax
            ldy   #0
:cpn        cpy   NDIG
            beq   :done
            lda   DIGS3,x
            sta   NUMDIGS,y
            inx
            iny
            bra   :cpn
:done       rts
:wide       lda   NDIG
            sec
            sbc   #3
            sta   FN_PAD
            ldy   #0
:padlp      cpy   FN_PAD
            beq   :paddone
            lda   #$B0
            sta   NUMDIGS,y
            iny
            bra   :padlp
:paddone    ldx   #0
:cpw        cpx   #3
            beq   :wdone
            lda   DIGS3,x
            sta   NUMDIGS,y
            inx
            iny
            bra   :cpw
:wdone      rts

*---------------------------------------------------------------
* NUMRANGEERR/REGEXERR -- an ARG failed. Clean up per -k (see
* ERRCLEANUP), then exit 1.
*---------------------------------------------------------------
NUMRANGEERR lda   #<NUMRANGEM
            sta   ERRMSGP
            lda   #>NUMRANGEM
            sta   ERRMSGP+1
            jmp   ERRCLEANUP

REGEXERR    lda   #<REGEXERRM
            sta   ERRMSGP
            lda   #>REGEXERRM
            sta   ERRMSGP+1
            jmp   ERRCLEANUP

*---------------------------------------------------------------
* ERRCLEANUP -- IN: ERRMSGP = the diagnostic. A partial piece
* (CUROPEN) is closed (bare FCLOSE; its own carry is moot, this
* run is already failing) and counted among the pieces to
* remove. Without -k, every piece 0..DELCOUNT-1 this run
* created is DESTROYed by rebuilding its name (FMTNUM/BUILDNAME
* over a temporary PIECEIDX); with -k, none are touched. Either
* way: print ERRMSGP, exit 1.
*---------------------------------------------------------------
ERRCLEANUP  lda   CUROPEN
            beq   :havedel
            ldx   CURFD
            jsr   FCLOSE
            lda   PIECEIDX
            clc
            adc   #1
            sta   DELCNT
            bra   :gotdel
:havedel    lda   PIECEIDX
            sta   DELCNT
:gotdel     lda   WANTK
            bne   :skipdel
            stz   DELI
:dellp      lda   DELI
            cmp   DELCNT
            beq   :skipdel
            lda   DELI
            sta   PIECEIDX
            jsr   FMTNUM
            jsr   BUILDNAME
            lda   #<PNAMEBUF
            sta   PTR0
            lda   #>PNAMEBUF
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<DPARM
            ldx   #>DPARM
            jsr   SC_UNLINK
            inc   DELI
            bra   :dellp
:skipdel    lda   ERRMSGP
            sta   PTR0
            lda   ERRMSGP+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

CANTOPENSRC lda   #<CANTOPENM
            sta   PTR0
            lda   #>CANTOPENM
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

NAMETOOLONG lda   #<NAMELONGM
            sta   PTR0
            lda   #>NAMELONGM
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

WRITEFAIL   lda   #<WRFAILM
            sta   PTR0
            lda   #>WRFAILM
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

CREATEFAIL  lda   #<CREATFM
            sta   PTR0
            lda   #>CREATFM
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

USAGEEXIT   lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* GETSLN -- next line from SRCFD into SLINEBUF, NUL-terminated.
* SHAVE = 1 iff a line is buffered; SHADCR = 1 iff it really
* ended with a CR (0 for a forced LINEMAX break or a final
* unterminated line -- uniq.s's own overflow policy). Advances
* LINENO on every line it hands back.
*---------------------------------------------------------------
GETSLN      stz   SLEN
:next       lda   SLEN
            cmp   #LINEMAX
            bcs   :haveln
            jsr   GETBYTE
            bcs   :eofhit
            cmp   #$8D
            beq   :havecr
            ldy   SLEN
            sta   SLINEBUF,y
            inc   SLEN
            bra   :next
:havecr     ldy   SLEN
            lda   #0
            sta   SLINEBUF,y
            lda   #1
            sta   SHAVE
            sta   SHADCR
            jmp   BUMPLN
:haveln     ldy   SLEN
            lda   #0
            sta   SLINEBUF,y
            lda   #1
            sta   SHAVE
            stz   SHADCR
            jmp   BUMPLN
:eofhit     lda   SLEN
            beq   :nothing
            ldy   SLEN
            lda   #0
            sta   SLINEBUF,y
            lda   #1
            sta   SHAVE
            stz   SHADCR
            jmp   BUMPLN
:nothing    stz   SHAVE
            rts

BUMPLN      inc   LINENO
            bne   :rt
            inc   LINENO+1
:rt         rts

*---------------------------------------------------------------
* GETBYTE / REFILL -- buffered SRCFD reader.
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
* PARSEDEC/PDCORE -- IN: PTR0 = digit string (PARSEDEC starts at
* Y=0; PDCORE starts at the caller's own Y, for a delimiter- or
* sign-offset scan). OUT: ACCLO/ACCHI = value, Y = the index of
* the first non-digit (Y unchanged from entry = no digits).
*---------------------------------------------------------------
PARSEDEC    ldy   #0
PDCORE      stz   ACCLO
            stz   ACCHI
:lp         lda   (PTR0),y
            beq   :done
            and   #$7F
            cmp   #'0'
            bcc   :done
            cmp   #'9'+1
            bcs   :done
            and   #$0F
            jsr   ACCUM10
            iny
            bra   :lp
:done       rts

ACCUM10     sta   AC_DIGIT
            asl   ACCLO
            rol   ACCHI
            lda   ACCLO
            sta   AC_TWOLO
            lda   ACCHI
            sta   AC_TWOHI
            asl   ACCLO
            rol   ACCHI
            asl   ACCLO
            rol   ACCHI
            clc
            lda   ACCLO
            adc   AC_TWOLO
            sta   ACCLO
            lda   ACCHI
            adc   AC_TWOHI
            sta   ACCHI
            clc
            lda   ACCLO
            adc   AC_DIGIT
            sta   ACCLO
            bcc   :nc
            inc   ACCHI
:nc         rts
