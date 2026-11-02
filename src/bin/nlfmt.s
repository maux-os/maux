*---------------------------------------------------------------
* nlfmt.s -- nl's per-line engine: BUILDMK/NLRUN/RESETNUM/
* PRINTONE/PRINTNUM/PRINTBLANK/ADVANCE/EMITLINE/CHECKHDR/
* CHECKBODY/CHECKFOOT/READLINE. `put` by src/bin/nl.s (NOT a
* standalone binary -- the same put-module shape as cut.s's own
* cutlist.s), split from nlopt.s's own PARSE* routines because
* nl.s's own resident text stayed over the 16,128-byte as-window
* budget even after that first split (18,997 B stripped, over by
* 2,869) -- a SECOND put file, not a bigger one: only the single
* LARGEST put counts against the window, so two balanced put
* files (nlopt.s 6,002 B, this file ~5,555 B) beat one file
* carrying both (11,557 B, which would have become the new
* largest-put term and left the unit over budget again). Every
* symbol here resolves against nl.s's own equates and data
* (CURLO/CURHI/CURSEC/TYPEARR/HDRBUF/BODYBUF/FOOTBUF/DELIM1/
* DELIM2/ERRFLAG/EOFFLAG/WIDTH/NFORMAT/SEPBUF/STARTLO/STARTHI/
* INCRMAG/INCRNEG/DIGLEN/PADN/PADCH/ELIDX/LLEN/LBUF/DIGBUF/
* BUFPOS/BUFLEN/CBUF/SRCFD/NARGS/NLNUM/BLANKCNT) and GETBYTE/
* U2DEC/USAGEEXIT --
* see nl.s's own header for the page/delimiter/numbering rules
* this codifies.
*---------------------------------------------------------------
BUILDMK     lda   DELIM1
            sta   HDRBUF
            sta   HDRBUF+2
            sta   HDRBUF+4
            sta   BODYBUF
            sta   BODYBUF+2
            sta   FOOTBUF
            lda   DELIM2
            sta   HDRBUF+1
            sta   HDRBUF+3
            sta   HDRBUF+5
            sta   BODYBUF+1
            sta   BODYBUF+3
            sta   FOOTBUF+1
            rts

*---------------------------------------------------------------
* NLRUN -- number SRCFD to stdout.
*---------------------------------------------------------------
NLRUN       stz   BUFPOS
            stz   BUFLEN
:nlloop     jsr   READLINE
            bcs   :nldone
            jsr   CHECKHDR
            bcc   :nchdr
            stz   CURSEC
            lda   WANT_P
            bne   :nlcont
            jsr   RESETNUM
            bra   :nlcont
:nchdr      jsr   CHECKBODY
            bcc   :ncbody
            lda   #1
            sta   CURSEC
            lda   WANT_P
            bne   :nlcont
            jsr   RESETNUM
            bra   :nlcont
:ncbody     jsr   CHECKFOOT
            bcc   :ncfoot
            lda   #2
            sta   CURSEC
            lda   WANT_P
            bne   :nlcont
            jsr   RESETNUM
            bra   :nlcont
:ncfoot     jsr   PRINTONE
:nlcont     lda   EOFFLAG
            bne   :nldone
            jmp   :nlloop
:nldone     rts

*---------------------------------------------------------------
* RESETNUM -- CURLO/CURHI = STARTLO/STARTHI.
*---------------------------------------------------------------
RESETNUM    lda   STARTLO
            sta   CURLO
            lda   STARTHI
            sta   CURHI
            rts

*---------------------------------------------------------------
* PRINTONE -- an ordinary (non-marker) line: decide numbered or
* not from TYPEARR[CURSEC], print the field + separator + the
* line body + CR.
*---------------------------------------------------------------
PRINTONE    ldx   CURSEC
            lda   TYPEARR,x
            cmp   #TY_A
            beq   :isa
            cmp   #TY_N
            beq   :ponot
            cmp   #TY_P
            beq   :isp
            lda   LLEN
            bne   :ponum
            bra   :ponot
*-- type `pBRE`: number the line iff NLMATCH says the section's
*-- pattern matches it.
:isp        jsr   NLMATCH
            bcs   :ponum
            bra   :ponot
*-- type `a`: every line numbered, EXCEPT a blank line under -l
*-- (NLNUM>1) counts only every NLNUM'th of a run -- see file
*-- header. LLEN!=0 (a real line) always resets the run and
*-- always numbers, same as -l's absence.
:isa        lda   LLEN
            bne   :aresetnum
            lda   NLNUM
            cmp   #2
            bcc   :aresetnum        ;NLNUM<=1: always number
                                    ;as before -l existed
            inc   BLANKCNT
            lda   BLANKCNT
            cmp   NLNUM
            bcc   :ponot            ;not yet the run's Nth blank
            stz   BLANKCNT
            bra   :ponum
:aresetnum  stz   BLANKCNT
:ponum      jsr   PRINTNUM
            jsr   ADVANCE
            bra   :poline
:ponot      jsr   PRINTBLANK
:poline     lda   #<SEPBUF
            sta   PTR0
            lda   #>SEPBUF
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            jsr   EMITLINE
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* PRINTNUM -- print CURLO/CURHI as decimal, justified/padded per
* NFORMAT/WIDTH (see this file's header for the three formats).
*---------------------------------------------------------------
PRINTNUM    lda   CURLO
            sta   U2DEC_VAL
            lda   CURHI
            sta   U2DEC_VAL+1
            lda   #<DIGBUF
            sta   PTR1
            lda   #>DIGBUF
            sta   PTR1+1
            jsr   U2DEC
            sta   DIGLEN
            lda   WIDTH
            sec
            sbc   DIGLEN
            bcs   :havepad
            lda   #0
:havepad    sta   PADN
            lda   NFORMAT
            beq   :ln
            cmp   #2
            beq   :usezero
            lda   #$A0
            bra   :padgo
:usezero    lda   #$B0
:padgo      sta   PADCH
:rnploop    lda   PADN
            beq   :rnprint
            lda   PADCH
            ldx   #FD_STDOUT
            jsr   PUTC
            dec   PADN
            bra   :rnploop
:rnprint    lda   #<DIGBUF
            sta   PTR0
            lda   #>DIGBUF
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            rts
:ln         lda   #<DIGBUF
            sta   PTR0
            lda   #>DIGBUF
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
:lnploop    lda   PADN
            beq   :lndone
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            dec   PADN
            bra   :lnploop
:lndone     rts

*---------------------------------------------------------------
* PRINTBLANK -- WIDTH literal spaces (an unnumbered line's own
* blank field -- measured: the separator still follows).
*---------------------------------------------------------------
PRINTBLANK  lda   WIDTH
            sta   PADN
:pbloop     lda   PADN
            beq   :pbdone
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            dec   PADN
            bra   :pbloop
:pbdone     rts

*---------------------------------------------------------------
* ADVANCE -- CURLO/CURHI += (signed) INCRMAG/INCRNEG.
*---------------------------------------------------------------
ADVANCE     lda   INCRNEG
            bne   :advneg
            lda   CURLO
            clc
            adc   INCRMAG
            sta   CURLO
            bcc   :adone
            inc   CURHI
            bra   :adone
:advneg     lda   CURLO
            sec
            sbc   INCRMAG
            sta   CURLO
            bcs   :adone
            dec   CURHI
:adone      rts

*---------------------------------------------------------------
* EMITLINE -- print LBUF[0..LLEN) verbatim (no CR -- PRINTONE's
* own caller adds it).
*---------------------------------------------------------------
EMITLINE    stz   ELIDX
:eloop      lda   ELIDX
            cmp   LLEN
            bcs   :edone
            ldy   ELIDX
            lda   LBUF,y
            ldx   #FD_STDOUT
            jsr   PUTC
            inc   ELIDX
            bra   :eloop
:edone      rts

*---------------------------------------------------------------
* NLMATCH -- does the section's pBRE match LBUF[0..LLEN)?
* OUT: carry SET = yes. The engine wants a NUL-ended line in
* its own polarity (bit 7 SET -- grepbody.s NORMLINE), so match
* a bit-7-set copy in MBUF and leave LBUF alone for the print.
* RE_MATCH takes PTR0 = line start, PTR1 = pattern, PTR2 = where
* to search from (the line start, for a whole-line search) and
* clobbers all three, so they are loaded fresh per call.
*---------------------------------------------------------------
NLMATCH     ldy   #0
:nmcp       cpy   LLEN
            bcs   :nmend
            lda   LBUF,y
            ora   #$80
            sta   MBUF,y
            iny
            bra   :nmcp
:nmend      lda   #0
            sta   MBUF,y
            lda   CURSEC
            asl   a
            tax
            lda   NLPAT,x
            sta   PTR1
            lda   NLPAT+1,x
            sta   PTR1+1
            lda   #<MBUF
            sta   PTR0
            sta   PTR2
            lda   #>MBUF
            sta   PTR0+1
            sta   PTR2+1
            jsr   RE_MATCH
            bcc   :nmyes            ;RE_MATCH: clear = a match
            clc
            rts
:nmyes      sec
            rts

*---------------------------------------------------------------
* CHECKHDR/CHECKBODY/CHECKFOOT -- OUT: carry SET if LBUF[0..
* LLEN) exactly equals the header(6)/body(4)/footer(2) marker.
*---------------------------------------------------------------
CHECKHDR    lda   LLEN
            cmp   #6
            bne   :chdno
            ldy   #0
:chdloop    cpy   #6
            bcs   :chdyes
            lda   LBUF,y
            cmp   HDRBUF,y
            bne   :chdno
            iny
            bra   :chdloop
:chdyes     sec
            rts
:chdno      clc
            rts

CHECKBODY   lda   LLEN
            cmp   #4
            bne   :cbono
            ldy   #0
:cboloop    cpy   #4
            bcs   :cboyes
            lda   LBUF,y
            cmp   BODYBUF,y
            bne   :cbono
            iny
            bra   :cboloop
:cboyes     sec
            rts
:cbono      clc
            rts

CHECKFOOT   lda   LLEN
            cmp   #2
            bne   :cfono
            ldy   #0
:cfoloop    cpy   #2
            bcs   :cfoyes
            lda   LBUF,y
            cmp   FOOTBUF,y
            bne   :cfono
            iny
            bra   :cfoloop
:cfoyes     sec
            rts
:cfono      clc
            rts

*---------------------------------------------------------------
* READLINE -- fill LBUF/LLEN with the next line (excluding its
* CR), truncating silently past LBUFCAP. OUT: carry SET = truly
* nothing left (caller stops without processing); carry CLEAR =
* a line is ready -- if it is the last one (EOF hit with no
* trailing CR), EOFFLAG is also set so the caller stops AFTER
* processing this one.
*---------------------------------------------------------------
READLINE    stz   LLEN
:rlloop     jsr   GETBYTE
            bcs   :rleof
            cmp   #$8D
            beq   :rlcr
            cmp   #$0D             ;either terminator ends a
            beq   :rlcr          ;line -- a foreign file
            ldy   LLEN
            cpy   #LBUFCAP
            bcs   :rlloop
            sta   LBUF,y
            inc   LLEN
            bra   :rlloop
:rlcr       clc
            rts
:rleof      lda   LLEN
            bne   :rltail
            sec
            rts
:rltail     lda   #1
            sta   EOFFLAG
            clc
            rts
