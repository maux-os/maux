*---------------------------------------------------------------
* difftop.s -- diff's front half,
* extracted from diff.s at a GLOBAL boundary for
* the as source window (S9-PLAN sec 6, tier 2 mains). One
* assembly stream: put exactly where the text sat; every rule
* in the manifest header applies unchanged.
*---------------------------------------------------------------
* -- OUTMODE is LAST-ONE-WINS across -e/-u/-c/-U/-C, real
* -- diff's own rule; -U n and -C n select their format AND
* -- set the context width, so `diff -u -C2` is a context diff
* -- with two lines of context, exactly as the reference does
* -- it.
START       stz   OUTMODE
            stz   RFLAG
            stz   HDRFLAG
            stz   DSTAT
            lda   #3
            sta   CTXN
            stz   BFLAG
            lda   #<OPTS
            ldx   #>OPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$E5              ;'e' high-bit-set
            beq   :eflag
            cmp   #$F5              ;'u'
            beq   :uflag
            cmp   #$E3              ;'c'
            beq   :cflag
            cmp   #$D5              ;'U'
            beq   :ubign
            cmp   #$C3              ;'C'
            beq   :cbign
            cmp   #$E2              ;'b' blanks
            beq   :bflag
            cmp   #OPTR             ;'r' recursive
            beq   :rflag
            jmp   USAGERR
:rflag      lda   #1
            sta   RFLAG
            bra   :optlp
:bflag      lda   #1
            sta   BFLAG
            bra   :optlp
:eflag      lda   #1
            sta   OUTMODE
            bra   :optlp
:uflag      lda   #2
            sta   OUTMODE
            bra   :optlp
:cflag      lda   #3
            sta   OUTMODE
            bra   :optlp
:ubign      lda   #2
            sta   OUTMODE
            bra   :ctxarg
:cbign      lda   #3
            sta   OUTMODE
:ctxarg     jsr   DFPARSED
            cmp   #MAXLINES
            bcc   :ctxok
            lda   #MAXLINES         ;a context wider than the
:ctxok      sta   CTXN              ;file cannot ask for more
            bra   :optlp
:optdone    lda   ARGC
            sec
            sbc   OPTIND
            cmp   #2
            beq   :nargok
            jmp   USAGERR
:nargok     lda   OPTIND
            sta   F1IDX
            clc
            adc   #1
            sta   F2IDX
            lda   #1
            sta   OERRIDX
            lda   #<DP1
            sta   PTR1
            lda   #>DP1
            sta   PTR1+1
            lda   F1IDX
            jsr   LOADOP
            sta   DL1
            lda   #2
            sta   OERRIDX
            lda   #<DP2
            sta   PTR1
            lda   #>DP2
            sta   PTR1+1
            lda   F2IDX
            jsr   LOADOP
            sta   DL2
            lda   #1
            sta   OERRIDX
            lda   #<DP1
            sta   PTR0
            lda   #>DP1
            sta   PTR0+1
            lda   #<PATH1BUF
            sta   PTR1
            lda   #>PATH1BUF
            sta   PTR1+1
            jsr   GFISTAT
            sta   ST1
            lda   #2
            sta   OERRIDX
            lda   #<DP2
            sta   PTR0
            lda   #>DP2
            sta   PTR0+1
            lda   #<PATH2BUF
            sta   PTR1
            lda   #>PATH2BUF
            sta   PTR1+1
            jsr   GFISTAT
            sta   ST2
            lda   ST1
            ora   ST2
            bne   :somedir
            jsr   DOPAIR            ;two plain files, no header
            jsr   EXIT
:somedir    lda   ST1
            and   ST2
            beq   :mixed
            jmp   WALKTOP
:mixed      jmp   MIXED

*---------------------------------------------------------------
* DOPAIR -- compare the files named by DP1 and DP2 (display
* paths). OUT: A = 0 identical, 1 different, the diff written to
* stdout (preceded by the `diff OPTS A B` line when HDRFLAG).
* The same path twice is identical without being opened.
*---------------------------------------------------------------
DOPAIR      lda   #<DP1
            sta   PTR0
            lda   #>DP1
            sta   PTR0+1
            lda   #<PATH1BUF
            sta   PTR1
            lda   #>PATH1BUF
            sta   PTR1+1
            jsr   MKPATH
            bcc   :p1
            lda   #1
            sta   OERRIDX
            jmp   OPENERR
:p1         lda   #<DP2
            sta   PTR0
            lda   #>DP2
            sta   PTR0+1
            lda   #<PATH2BUF
            sta   PTR1
            lda   #>PATH2BUF
            sta   PTR1+1
            jsr   MKPATH
            bcc   :p2
            lda   #2
            sta   OERRIDX
            jmp   OPENERR
:p2         jsr   PATHEQ
            bcc   :open
            lda   #0
            rts
:open       lda   #<O1PARM
            ldx   #>O1PARM
            jsr   SC_OPEN
            bcc   :o1ok
            lda   #1
            sta   OERRIDX
            jmp   OPENERR
:o1ok       lda   O1PARM_REF
            sta   FD1

            lda   #<O2PARM
            ldx   #>O2PARM
            jsr   SC_OPEN
            bcc   :o2ok
            lda   #2
            sta   OERRIDX
            jmp   OPENERR
:o2ok       lda   O2PARM_REF
            sta   FD2

            lda   #<ARENA
            sta   DF_TPOS
            lda   #>ARENA
            sta   DF_TPOS+1
            stz   NA
            stz   NB

            jsr   READALLA
            lda   FD1
            sta   C1PARM_REF
            lda   #<C1PARM
            ldx   #>C1PARM
            jsr   SC_CLOSE

            jsr   READALLB
            lda   FD2
            sta   C2PARM_REF
            lda   #<C2PARM
            ldx   #>C2PARM
            jsr   SC_CLOSE

            jsr   DPCHECK
            jsr   DPFILL
            jsr   BACKTRACE
            jsr   MKHUNKS

            lda   NHUNKS
            bne   :havediff
            lda   #0
            rts
:havediff   lda   HDRFLAG
            beq   :nohdr
            jsr   PRHDR
:nohdr      lda   OUTMODE
            cmp   #1
            bne   :note
            jsr   OUTE
            bra   :setex1
:note       cmp   #2
            bne   :notu
            jsr   OUTU
            bra   :setex1
:notu       cmp   #3
            bne   :normal
            jsr   OUTC
            bra   :setex1
:normal     jsr   OUTNORM
:setex1     lda   #1
            rts

*---------------------------------------------------------------
* CHKROOM -- OUT: rts if DF_TPOS has a free byte in ARENA;
* jumps to OVERFLOW (no return) otherwise. Shared by both
* files' reads.
*---------------------------------------------------------------
CHKROOM     lda   DF_TPOS+1
            cmp   #>ARENAEND
            bcc   :ok
            bne   :full
            lda   DF_TPOS
            cmp   #<ARENAEND
            bcc   :ok
:full       jmp   OVERFLOW
:ok         rts

*---------------------------------------------------------------
* ADDLINEA/ADDLINEB -- append DF_LSTART to LPA[NA]/LPB[NB],
* count++. Jumps to OVERFLOW (no return) if MAXLINES is reached.
* (NA/NB*2 fits one byte -- MAXLINES-1 doubled is well under
* 256, see header.)
*---------------------------------------------------------------
ADDLINEA    lda   NA
            cmp   #MAXLINES
            bcc   :roomA
            jmp   OVERFLOW
:roomA      lda   NA
            asl   a
            sta   DF_TMP
            stz   DF_TMP+1
            clc
            lda   DF_TMP
            adc   #<LPA
            sta   DF_TMP
            lda   DF_TMP+1
            adc   #>LPA
            sta   DF_TMP+1
            lda   DF_LSTART
            sta   (DF_TMP)
            inc   DF_TMP
            bne   :a1
            inc   DF_TMP+1
:a1         lda   DF_LSTART+1
            sta   (DF_TMP)
            inc   NA
            rts

ADDLINEB    lda   NB
            cmp   #MAXLINES
            bcc   :roomB
            jmp   OVERFLOW
:roomB      lda   NB
            asl   a
            sta   DF_TMP
            stz   DF_TMP+1
            clc
            lda   DF_TMP
            adc   #<LPB
            sta   DF_TMP
            lda   DF_TMP+1
            adc   #>LPB
            sta   DF_TMP+1
            lda   DF_LSTART
            sta   (DF_TMP)
            inc   DF_TMP
            bne   :b1
            inc   DF_TMP+1
:b1         lda   DF_LSTART+1
            sta   (DF_TMP)
            inc   NB
            rts

*---------------------------------------------------------------
* READALLA/READALLB -- read FD1/FD2 to EOF into ARENA/LPA (or
* LPB), CR ($8D) -> NUL in place, sort.s/ed.s's own convention.
* A final unterminated line still counts (synthetic NUL, charged
* against CHKROOM like any byte, no TPOS advance -- it is a
* terminator, not a stored byte). Jumps into OVERFLOW (via
* CHKROOM/ADDLINE*) on either cap, never returns in that case.
*---------------------------------------------------------------
READALLA    stz   BUFPOS1
            stz   BUFLEN1
            lda   DF_TPOS
            sta   DF_LSTART
            lda   DF_TPOS+1
            sta   DF_LSTART+1
:loop       jsr   GETB1
            bcs   :eof
            sta   DF_CBYTE
            jsr   CHKROOM
            lda   DF_CBYTE
            cmp   #$8D
            bne   :put
            lda   #0
:put        sta   (DF_TPOS)
            lda   DF_CBYTE
            cmp   #$8D
            bne   :adv
            jsr   ADDLINEA
            inc   DF_TPOS
            bne   :sl
            inc   DF_TPOS+1
:sl         lda   DF_TPOS
            sta   DF_LSTART
            lda   DF_TPOS+1
            sta   DF_LSTART+1
            bra   :loop
:adv        inc   DF_TPOS
            bne   :loop
            inc   DF_TPOS+1
            bra   :loop
:eof        lda   DF_TPOS
            cmp   DF_LSTART
            bne   :tail
            lda   DF_TPOS+1
            cmp   DF_LSTART+1
            bne   :tail
            rts
:tail       jsr   CHKROOM
            lda   #0
            sta   (DF_TPOS)
            jsr   ADDLINEA
            rts

READALLB    stz   BUFPOS2
            stz   BUFLEN2
            lda   DF_TPOS
            sta   DF_LSTART
            lda   DF_TPOS+1
            sta   DF_LSTART+1
:loop       jsr   GETB2
            bcs   :eof
            sta   DF_CBYTE
            jsr   CHKROOM
            lda   DF_CBYTE
            cmp   #$8D
            bne   :put
            lda   #0
:put        sta   (DF_TPOS)
            lda   DF_CBYTE
            cmp   #$8D
            bne   :adv
            jsr   ADDLINEB
            inc   DF_TPOS
            bne   :sl
            inc   DF_TPOS+1
:sl         lda   DF_TPOS
            sta   DF_LSTART
            lda   DF_TPOS+1
            sta   DF_LSTART+1
            bra   :loop
:adv        inc   DF_TPOS
            bne   :loop
            inc   DF_TPOS+1
            bra   :loop
:eof        lda   DF_TPOS
            cmp   DF_LSTART
            bne   :tail
            lda   DF_TPOS+1
            cmp   DF_LSTART+1
            bne   :tail
            rts
:tail       jsr   CHKROOM
            lda   #0
            sta   (DF_TPOS)
            jsr   ADDLINEB
            rts

*---------------------------------------------------------------
* GETB1/REFIL1, GETB2/REFIL2 -- buffered input, cmp.s's own
* shape, one pair per fd.
*---------------------------------------------------------------
GETB1       ldx   BUFPOS1
            cpx   BUFLEN1
            bcc   :hv1
            jsr   REFIL1
            bcs   :eo1
            ldx   BUFPOS1
:hv1        lda   CBUF1,x
            inc   BUFPOS1
            clc
            rts
:eo1        sec
            rts

REFIL1      lda   FD1
            sta   R1PARM_REF
            lda   #<R1PARM
            ldx   #>R1PARM
            jsr   SC_READ
            bcs   :er1
            lda   R1PARM_TRANS
            ora   R1PARM_TRANS+1
            beq   :er1
            lda   R1PARM_TRANS
            sta   BUFLEN1
            stz   BUFPOS1
            clc
            rts
:er1        sec
            rts

GETB2       ldx   BUFPOS2
            cpx   BUFLEN2
            bcc   :hv2
            jsr   REFIL2
            bcs   :eo2
            ldx   BUFPOS2
:hv2        lda   CBUF2,x
            inc   BUFPOS2
            clc
            rts
:eo2        sec
            rts

REFIL2      lda   FD2
            sta   R2PARM_REF
            lda   #<R2PARM
            ldx   #>R2PARM
            jsr   SC_READ
            bcs   :er2
            lda   R2PARM_TRANS
            ora   R2PARM_TRANS+1
            beq   :er2
            lda   R2PARM_TRANS
            sta   BUFLEN2
            stz   BUFPOS2
            clc
            rts
:er2        sec
            rts

*---------------------------------------------------------------
* LPA_GET/LPB_GET -- IN: A = 1-based line number n. OUT:
* DF_LPTMP = that line's arena text address (LPA[n-1]/LPB[n-1]).
*---------------------------------------------------------------
LPA_GET     sec
            sbc   #1
            asl   a
            sta   DF_LPTMP
            stz   DF_LPTMP+1
            clc
            lda   DF_LPTMP
            adc   #<LPA
            sta   DF_LPTMP
            lda   DF_LPTMP+1
            adc   #>LPA
            sta   DF_LPTMP+1
            lda   (DF_LPTMP)
            tax
            ldy   #1
            lda   (DF_LPTMP),y
            sta   DF_LPTMP+1
            stx   DF_LPTMP
            rts
