*---------------------------------------------------------------
* splitpc.s -- split's numeric-argument parser and piece-file
* open/close routines, `put` by src/bin/split.s (NOT a
* standalone binary -- the same put-module shape as cut.s's
* cutlist.s), split out purely to fit as's 16,128-byte source
* window (split.s alone measured over it, stripped). Every
* symbol here resolves against split.s's own equates/bss
* (PFXBUF/PFXLEN, SUFBUF/SUFLEN, PNAMEBUF, PATHBUF, NUMLO/NUMHI,
* REMAINLO/HI, CURFD, PIECEOPEN/EVEROPEN/EXHAUSTED, ACCLO/ACCHI)
* and its CREATEFAIL/SUFFEXHAUSTED/WRITEFAIL error exits.
*---------------------------------------------------------------
*---------------------------------------------------------------
* PARSEDEC -- IN: PTR0 = digit string (liba high-bit text). OUT:
* ACCLO/ACCHI = the value; Y = number of digit chars consumed
* (0 = no leading digit at all -- caller's error to raise).
* Stops at the first non-digit; (PTR0),y is that byte (0 if the
* string ended). CLOBBERS: A, Y, ACCLO, ACCHI.
*---------------------------------------------------------------
PARSEDEC    stz   ACCLO
            stz   ACCHI
            ldy   #0
:loop       lda   (PTR0),y
            beq   :done
            and   #$7F
            cmp   #'0'
            bcc   :done
            cmp   #'9'+1
            bcs   :done
            and   #$0F
            jsr   ACCUM10
            iny
            bra   :loop
:done       rts

*---------------------------------------------------------------
* ACCUM10 -- ACCLO/ACCHI = ACCLO/ACCHI*10 + A (A=0-9). Same
* shape as head.s's own routine of the same name. CLOBBERS: A.
*---------------------------------------------------------------
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

*---------------------------------------------------------------
* SHL10 -- ACCLO/ACCHI <<= 10 (times 1024). CLOBBERS: A, X.
*---------------------------------------------------------------
SHL10       ldx   #10
:lp         asl   ACCLO
            rol   ACCHI
            dex
            bne   :lp
            rts

*---------------------------------------------------------------
* SUFINC -- odometer increment. IN: SUFBUF[0..SUFLEN-1]. OUT:
* carry SET = every digit was 'z' and wrapped (exhausted); carry
* CLEAR otherwise. CLOBBERS: A, X.
*---------------------------------------------------------------
SUFINC      ldx   SUFLEN
            dex
:lp         lda   SUFBUF,x
            cmp   #"z"
            bne   :inc
            lda   #"a"
            sta   SUFBUF,x
            dex
            bpl   :lp
            sec
            rts
:inc        inc   SUFBUF,x
            clc
            rts

*---------------------------------------------------------------
* OPENPIECE -- build the next piece's name from PFXBUF+SUFBUF,
* CREATE+OPEN it, arm REMAINLO/HI from NUM, then advance the
* odometer for the FOLLOWING piece (recording EXHAUSTED if that
* advance wraps every digit). CLOBBERS: A, X, Y.
*---------------------------------------------------------------
OPENPIECE   lda   EXHAUSTED
            beq   :go
            jmp   SUFFEXHAUSTED
:go         ldy   #0
            ldx   #0
:cp1        cpx   PFXLEN
            beq   :cp1d
            lda   PFXBUF,x
            sta   PNAMEBUF,y
            iny
            inx
            bra   :cp1
:cp1d       ldx   #0
:cp2        cpx   SUFLEN
            beq   :cp2d
            lda   SUFBUF,x
            sta   PNAMEBUF,y
            iny
            inx
            bra   :cp2
:cp2d       lda   #0
            sta   PNAMEBUF,y
            lda   #<PNAMEBUF
            sta   PTR0
            lda   #>PNAMEBUF
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   CREAT
            bcc   :ok
            jmp   CREATEFAIL
:ok         sta   CURFD
            lda   #1
            sta   PIECEOPEN
            sta   EVEROPEN
            lda   NUMLO
            sta   REMAINLO
            lda   NUMHI
            sta   REMAINHI
            jsr   SUFINC
            bcc   :noexh
            lda   #1
            sta   EXHAUSTED
:noexh      rts

*---------------------------------------------------------------
* CLOSEPIECE -- FCLOSE the current piece (flush THEN close --
* see header). CLOBBERS: A, X.
*---------------------------------------------------------------
CLOSEPIECE  ldx   CURFD
            jsr   FCLOSE
            bcc   :ok
            jmp   WRITEFAIL
:ok         stz   PIECEOPEN
            rts
*---------------------------------------------------------------
* GETBYTE / REFILL -- buffered SRCFD reader, head.s's own shape.
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
* USAGEEXIT -- a GLOBAL label (not `:local`), reached by `jmp`
* from every option/operand-shape error above: some of those
* sites sit further than a branch's +/-127-byte range from a
* single shared handler, so each site branches SHORT on the
* GOOD case and `jmp`s here (full 16-bit range) on the bad one
* -- the same trampoline shape as src/bin/find.s's :haveent.
*---------------------------------------------------------------
USAGEEXIT   lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
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

SUFFEXHAUSTED
            lda   #<SUFEXM
            sta   PTR0
            lda   #>SUFEXM
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

WRITEFAIL   lda   #<WRFAILM
            sta   PTR0
            lda   #>WRFAILM
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT
