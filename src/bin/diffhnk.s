*---------------------------------------------------------------
* diffhnk.s -- diff's hunk-close and output half,
* extracted from diff.s at a GLOBAL boundary for
* the as source window (S9-PLAN sec 6, tier 2 mains). One
* assembly stream: put exactly where the text sat; every rule
* in the manifest header applies unchanged.
*---------------------------------------------------------------
CLOSEHUNK   lda   NHUNKS
            cmp   #MAXHUNKS
            bcc   :room
            jmp   OVERFLOW
:room       lda   NHUNKS
            sta   DF_TMP
            stz   DF_TMP+1
            asl   DF_TMP
            rol   DF_TMP+1
            asl   DF_TMP
            rol   DF_TMP+1
            clc
            lda   DF_TMP
            adc   #<HUNKTBL
            sta   DF_TMP
            lda   DF_TMP+1
            adc   #>HUNKTBL
            sta   DF_TMP+1
            lda   HA
            sta   (DF_TMP)
            inc   DF_TMP
            bne   :n1
            inc   DF_TMP+1
:n1         lda   HB
            sta   (DF_TMP)
            inc   DF_TMP
            bne   :n2
            inc   DF_TMP+1
:n2         lda   HDELS
            sta   (DF_TMP)
            inc   DF_TMP
            bne   :n3
            inc   DF_TMP+1
:n3         lda   HINS
            sta   (DF_TMP)
            inc   NHUNKS
            stz   INHUNK
            rts

*---------------------------------------------------------------
* GETHUNK -- IN: A = hunk index. OUT: HA/HB/HDELS/HINS loaded
* from HUNKTBL[A].
*---------------------------------------------------------------
GETHUNK     sta   DF_TMP
            stz   DF_TMP+1
            asl   DF_TMP
            rol   DF_TMP+1
            asl   DF_TMP
            rol   DF_TMP+1
            clc
            lda   DF_TMP
            adc   #<HUNKTBL
            sta   DF_TMP
            lda   DF_TMP+1
            adc   #>HUNKTBL
            sta   DF_TMP+1
            lda   (DF_TMP)
            sta   HA
            inc   DF_TMP
            bne   :g1
            inc   DF_TMP+1
:g1         lda   (DF_TMP)
            sta   HB
            inc   DF_TMP
            bne   :g2
            inc   DF_TMP+1
:g2         lda   (DF_TMP)
            sta   HDELS
            inc   DF_TMP
            bne   :g3
            inc   DF_TMP+1
:g3         lda   (DF_TMP)
            sta   HINS
            rts

* CLASSIFY -- sets CMDCH from HDELS/HINS ('a'/'d'/'c').
CLASSIFY    lda   HDELS
            bne   :nchk
            lda   #"a"
            sta   CMDCH
            rts
:nchk       lda   HINS
            bne   :cchk
            lda   #"d"
            sta   CMDCH
            rts
:cchk       lda   #"c"
            sta   CMDCH
            rts

*---------------------------------------------------------------
* PRNRANGE -- IN: A = last (anchor line, 0-based), X = count
* (>=1). Prints "last+1" or, if count>1, "last+1,last+count".
* CLOBBERS: A,X,Y.
*---------------------------------------------------------------
PRNRANGE    sta   DF_TMP2
            stx   DF_TMP2+1
            lda   DF_TMP2
            clc
            adc   #1
            sta   U2DEC_VAL
            stz   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
            lda   DF_TMP2+1
            cmp   #1
            beq   :done
            lda   #$AC              ;',' high-bit-set (merlin32
                                    ;confuses #"," -- see
                                    ;ed.s's own note)
            ldx   #FD_STDOUT
            jsr   PUTC
            clc
            lda   DF_TMP2
            adc   DF_TMP2+1
            sta   U2DEC_VAL
            stz   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
:done       rts

*---------------------------------------------------------------
* OUTNORM -- default ed-script-compatible output, hunks in
* forward order.
*---------------------------------------------------------------
OUTNORM     stz   HI
:hloop      lda   HI
            cmp   NHUNKS
            bcc   :dohunk
            rts
:dohunk     lda   HI
            jsr   GETHUNK
            jsr   CLASSIFY
            lda   CMDCH
            cmp   #"a"
            bne   :leftr
            lda   HA
            sta   U2DEC_VAL
            stz   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
            bra   :aleft
:leftr      lda   HA
            ldx   HDELS
            jsr   PRNRANGE
:aleft      lda   CMDCH
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   CMDCH
            cmp   #"d"
            bne   :rightr
            lda   HB
            sta   U2DEC_VAL
            stz   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
            bra   :aright
:rightr     lda   HB
            ldx   HINS
            jsr   PRNRANGE
:aright     lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   CMDCH
            cmp   #"a"
            beq   :skipdel
            jsr   PRDELBODY
:skipdel    lda   CMDCH
            cmp   #"c"
            bne   :skipsep
            jsr   PRSEP
:skipsep    lda   CMDCH
            cmp   #"d"
            beq   :skipins
            jsr   PRINSBODY
:skipins    inc   HI
            jmp   :hloop

PRDELBODY   lda   #1
            sta   KIDX
:dloop      lda   KIDX
            cmp   HDELS
            beq   :d1
            bcc   :d1
            rts
:d1         lda   #"<"
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            clc
            lda   HA
            adc   KIDX
            jsr   PRLINE_A
            inc   KIDX
            bra   :dloop

PRINSBODY   lda   #1
            sta   KIDX
:iloop      lda   KIDX
            cmp   HINS
            beq   :i1
            bcc   :i1
            rts
:i1         lda   #">"
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            clc
            lda   HB
            adc   KIDX
            jsr   PRLINE_B
            inc   KIDX
            bra   :iloop

PRSEP       lda   #<SEPMSG
            sta   PTR0
            lda   #>SEPMSG
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* OUTE -- pure ed script, hunks in REVERSE order (see header).
*---------------------------------------------------------------
OUTE        lda   NHUNKS
            beq   :edone
            sec
            sbc   #1
            sta   HI
:eloop      lda   HI
            jsr   GETHUNK
            jsr   CLASSIFY
            lda   CMDCH
            cmp   #"a"
            bne   :eleftr
            lda   HA
            sta   U2DEC_VAL
            stz   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
            bra   :eaft
:eleftr     lda   HA
            ldx   HDELS
            jsr   PRNRANGE
:eaft       lda   CMDCH
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   CMDCH
            cmp   #"d"
            beq   :ebdone
            jsr   PREBODY
            lda   #"."
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:ebdone     lda   HI
            beq   :edone
            dec   HI
            jmp   :eloop
:edone      rts

PREBODY     lda   #1
            sta   KIDX
:eb1        lda   KIDX
            cmp   HINS
            beq   :eb2
            bcc   :eb2
            rts
:eb2        clc
            lda   HB
            adc   KIDX
            jsr   PRLINE_B
            inc   KIDX
            bra   :eb1

*---------------------------------------------------------------
* OVERFLOW -- either cap was hit. LOUD failure: message to fd 2,
* exit 2. Not reached via rts -- every caller jmp's here.
*---------------------------------------------------------------
OVERFLOW    lda   #<OOMMSG
            sta   PTR0
            lda   #>OOMMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* OPENERR -- IN: OERRIDX = 1 or 2, the side (DP1/DP2) that
* failed to open or list. Exit 2.
*---------------------------------------------------------------
OPENERR     lda   #<OPENMSG
            sta   PTR0
            lda   #>OPENMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<DP2
            ldx   #>DP2
            ldy   OERRIDX
            cpy   #2
            beq   :two
            lda   #<DP1
            ldx   #>DP1
:two        sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* USAGERR -- bad option or wrong operand count. Exit 2.
*---------------------------------------------------------------
USAGERR     lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            jsr   EXIT

USAGEMSG    asc   "usage: diff [-rb] [-e|-u|-c] "
            asc   "[-U n] [-C n] f1 f2"
            dfb   0
OPENMSG     asc   "diff: cannot open "
            dfb   0
OOMMSG      asc   "diff: input too large"
            dfb   0
SEPMSG      asc   "---"
            dfb   0
OPTS        asc   "eucU:C:br"
            dfb   0

O1PARM      dfb   OPEN_RO
O1PARM_PATH da    PATH1BUF
O1PARM_IOBF da    $0000
O1PARM_REF  dfb   0

O2PARM      dfb   OPEN_RO
O2PARM_PATH da    PATH2BUF
O2PARM_IOBF da    $0000
O2PARM_REF  dfb   0

R1PARM      dfb   PCOUNT_READ
R1PARM_REF  dfb   0
R1PARM_BUF  da    CBUF1
R1PARM_REQ  da    BUFSZ
R1PARM_TRANS da   0

R2PARM      dfb   PCOUNT_READ
R2PARM_REF  dfb   0
R2PARM_BUF  da    CBUF2
R2PARM_REQ  da    BUFSZ
R2PARM_TRANS da   0

C1PARM      dfb   PCOUNT_CLOSE
C1PARM_REF  dfb   0
C2PARM      dfb   PCOUNT_CLOSE
C2PARM_REF  dfb   0
