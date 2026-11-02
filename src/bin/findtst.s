*---------------------------------------------------------------
* findtst.s -- find's PRIMITIVE TESTS and their support: GETNOW/
* EXTRACTDATE/DAYNUM/MULDAYS (the clock/calendar machinery),
* TESTNAME/TESTPATH/TESTTYPE/TESTLINKS/STATPATH/DTGT/TESTNEWER/
* TESTMTIME/GETSIZE/TESTSIZE/CMPSIGN, CUMTAB, and the flag
* dispatch table + strings TOKENIZE scans. Split out of
* findexpr.s at a GLOBAL boundary purely for the `as` source-
* window budget (docs/S9-PLAN.md section 5: resident + largest
* single `put` <= 16,128B) -- findexpr.s's own header carries
* the WHOLE engine's design; this file is audited with it, one
* design, three `put` pieces. One assembly stream: put exactly
* where the text sat.
*---------------------------------------------------------------
*---------------------------------------------------------------
* GETNOW -- read the clock ONCE, at parse time (POSIX's
* "initialization time" for -mtime, literally): CLKBUF2 via
* SC_CLOCK, the SAME validity rule date.s/ls.s already use (both
* raw bytes zero, or hour>=24, or minute>=60, means NO clock --
* an unreadable stamp, or a 2.5 Extended one on purpose).
* CLOCKOK=0 leaves -mtime false for every file (TESTMTIME's own
* guard). CLOCKOK=1 also precomputes NOWDAYSLO/HI once, since
* every -mtime test needs "today" and it cannot change while
* find runs. Called only when CLOCKNEED is set (a -mtime
* appeared somewhere in the expression). CLOBBERS: everything.
*---------------------------------------------------------------
GETNOW      stz   CLOCKOK
            lda   #<CLKBUF2
            sta   PTR0
            lda   #>CLKBUF2
            sta   PTR0+1
            jsr   SC_CLOCK
            bcs   :gndone
            lda   CLKBUF2
            ora   CLKBUF2+1
            beq   :gndone
            lda   CLKBUF2+3
            cmp   #24
            bcs   :gndone
            lda   CLKBUF2+2
            cmp   #60
            bcs   :gndone
            lda   #1
            sta   CLOCKOK
            lda   CLKBUF2
            sta   DATEWLO
            lda   CLKBUF2+1
            sta   DATEWHI
            jsr   EXTRACTDATE
            jsr   DAYNUM
            lda   DNRESLO
            sta   NOWDAYSLO
            lda   DNRESHI
            sta   NOWDAYSHI
:gndone     rts

*---------------------------------------------------------------
* EXTRACTDATE -- decode a raw ProDOS date word (DATEWLO/DATEWHI)
* into DAYV2(1-31)/MONTHV2(1-12)/YEARV2(0-127, pivot-78) -- the
* SAME decode date.s/ls.s's PRINTDATE already use (one date
* policy, not two). CLOBBERS: A.
*---------------------------------------------------------------
EXTRACTDATE lda   DATEWLO
            and   #$1F
            sta   DAYV2
            lda   DATEWLO
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            and   #$07
            sta   MONTHV2
            lda   DATEWHI
            and   #$01
            asl   a
            asl   a
            asl   a
            ora   MONTHV2
            sta   MONTHV2
            lda   DATEWHI
            lsr   a
            and   #$7F
            sta   YEARV2
            rts

*---------------------------------------------------------------
* DAYNUM -- a calendar day number from YEARV2(pivot-78)/
* MONTHV2/DAYV2 into DNRESLO/DNRESHI. ONLY the DIFFERENCE
* between two DAYNUM results is meaningful (TESTMTIME); the
* origin is never printed. Leap years are YRS8 (years since
* 1900) divisible by 4, NO century exception -- correct across
* this tool's whole reachable range (1978-2077): the one
* century boundary in
* range, 2000, IS divisible by 400 too, and 1900 itself (NOT
* divisible by 400) is excluded by the pivot. CLOBBERS: A, X.
*---------------------------------------------------------------
DAYNUM      lda   YEARV2
            cmp   #78
            bcc   :dnfold
            sta   YRS8
            bra   :dnhave
:dnfold     clc
            adc   #100
            sta   YRS8
:dnhave     lda   YRS8
            jsr   MULDAYS
            lda   YRS8
            lsr   a
            lsr   a
            sta   MULC
            clc
            lda   DNRESLO
            adc   MULC
            sta   DNRESLO
            lda   DNRESHI
            adc   #0
            sta   DNRESHI
            lda   MONTHV2
            sec
            sbc   #1
            asl   a
            tax
            clc
            lda   DNRESLO
            adc   CUMTAB,x
            sta   DNRESLO
            lda   DNRESHI
            adc   CUMTAB+1,x
            sta   DNRESHI
            lda   MONTHV2
            cmp   #3
            bcc   :dnnolp
            lda   YRS8
            and   #3
            bne   :dnnolp
            inc   DNRESLO
            bne   :dnnolp
            inc   DNRESHI
:dnnolp     lda   DAYV2
            sec
            sbc   #1
            clc
            adc   DNRESLO
            sta   DNRESLO
            lda   DNRESHI
            adc   #0
            sta   DNRESHI
            rts

*---------------------------------------------------------------
* MULDAYS -- DNRESLO/DNRESHI := A * 365 (A a byte; 0-177 in
* practice, so the product fits 16 bits: max 177*365=64605).
* Standard 8-iteration shift-and-add: multiplicand=A (MULC),
* multiplier doubled each pass from 365. CLOBBERS: A, X.
*---------------------------------------------------------------
MULDAYS     sta   MULC
            stz   DNRESLO
            stz   DNRESHI
            lda   #<365
            sta   MULPLO
            lda   #>365
            sta   MULPHI
            ldx   #8
:mdloop     lsr   MULC
            bcc   :mdnoadd
            clc
            lda   DNRESLO
            adc   MULPLO
            sta   DNRESLO
            lda   DNRESHI
            adc   MULPHI
            sta   DNRESHI
:mdnoadd    asl   MULPLO
            rol   MULPHI
            dex
            bne   :mdloop
            rts

*---------------------------------------------------------------
* TESTNAME/TESTPATH -- glob CURVLO/CURVHI (the pattern) against
* EVBASE (basename) / EVPATH (full path). GLOBMATCH: carry CLEAR
* on match. OUT: A=1/0. CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
TESTNAME    lda   CURVLO
            sta   PTR0
            lda   CURVHI
            sta   PTR0+1
            lda   EVBASE
            sta   PTR1
            lda   EVBASE+1
            sta   PTR1+1
            jsr   GLOBMATCH
            bcc   :tnyes
            lda   #0
            rts
:tnyes      lda   #1
            rts

TESTPATH    lda   CURVLO
            sta   PTR0
            lda   CURVHI
            sta   PTR0+1
            lda   EVPATH
            sta   PTR1
            lda   EVPATH+1
            sta   PTR1+1
            jsr   GLOBMATCH
            bcc   :tpyes
            lda   #0
            rts
:tpyes      lda   #1
            rts

*---------------------------------------------------------------
* TESTTYPE -- CURVLO=$E4('d')/$E6('f') vs AF_ISDIR. OUT: A=1/0.
* CLOBBERS: A.
*---------------------------------------------------------------
TESTTYPE    lda   CURVLO
            cmp   #$E4
            bne   :ttwantf
            lda   AF_ISDIR
            bne   :ttyes
            lda   #0
            rts
:ttwantf    lda   AF_ISDIR
            beq   :ttyes
            lda   #0
            rts
:ttyes      lda   #1
            rts

*---------------------------------------------------------------
* TESTLINKS -- every maux file has exactly ONE link (no hard-
* link support anywhere in this filesystem), so the "measured
* value" is the constant 1 -- CMPSIGN does the +/-/exact compare
* against the token's own N. CLOBBERS: A.
*---------------------------------------------------------------
TESTLINKS   lda   #1
            sta   ACTUALLO
            stz   ACTUALHI
            jmp   CMPSIGN

*---------------------------------------------------------------
* STATPATH -- GET_FILE_INFO(EVPATH) into GFIPARM (findact.s's
* static parmlist -- WALK's own use of it for the root argument
* is long since consumed by the time any primary runs). OUT:
* carry clear=ok (GFIPARM_* fresh), carry set=stat failed.
* CLOBBERS: everything.
*---------------------------------------------------------------
STATPATH    lda   EVPATH
            sta   PTR0
            lda   EVPATH+1
            sta   PTR0+1
            lda   #<EVMLIP
            sta   PTR1
            lda   #>EVMLIP
            sta   PTR1+1
            jsr   MKPATH
            lda   #<EVMLIP
            sta   GFIPARM_PATH
            lda   #>EVMLIP
            sta   GFIPARM_PATH+1
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jmp   SC_GFI

*---------------------------------------------------------------
* DTGT -- IN: GFIPARM_MDATE/MTIME (current file, freshly stat'd)
* vs NEWERMD/NEWERMT (the -newer reference, fetched once at
* parse time). OUT: A=1 iff current is STRICTLY later (date
* compared first, time on a tie -- both ordinary unsigned
* magnitudes, see this file's header). CLOBBERS: A.
*---------------------------------------------------------------
DTGT        lda   GFIPARM_MDATE+1
            cmp   NEWERMD+1
            bcc   :dtno
            bne   :dtyes
            lda   GFIPARM_MDATE
            cmp   NEWERMD
            bcc   :dtno
            bne   :dtyes
            lda   GFIPARM_MTIME+1
            cmp   NEWERMT+1
            bcc   :dtno
            bne   :dtyes
            lda   GFIPARM_MTIME
            cmp   NEWERMT
            bcc   :dtno
            beq   :dtno
:dtyes      lda   #1
            rts
:dtno       lda   #0
            rts

*---------------------------------------------------------------
* TESTNEWER -- fresh-stat EVPATH, then DTGT against NEWERMD/
* NEWERMT. OUT: A=1/0. CLOBBERS: everything.
*---------------------------------------------------------------
TESTNEWER   jsr   STATPATH
            bcc   :tnwok
            lda   #0
            rts
:tnwok      jmp   DTGT

*---------------------------------------------------------------
* TESTMTIME -- see this file's header for exactly what this
* measures (a CALENDAR-DAY difference, not a true 86400-second
* window) and why. FALSE, with no error, when CLOCKOK=0.
* CLOBBERS: everything.
*---------------------------------------------------------------
TESTMTIME   lda   CLOCKOK
            bne   :mtok
            lda   #0
            rts
:mtok       jsr   STATPATH
            bcc   :mtstok
            lda   #0
            rts
:mtstok     lda   GFIPARM_MDATE
            sta   DATEWLO
            lda   GFIPARM_MDATE+1
            sta   DATEWHI
            jsr   EXTRACTDATE
            jsr   DAYNUM
            sec
            lda   NOWDAYSLO
            sbc   DNRESLO
            sta   ACTUALLO
            lda   NOWDAYSHI
            sbc   DNRESHI
            sta   ACTUALHI
            bcs   :mtok2
            stz   ACTUALLO
            stz   ACTUALHI
:mtok2      jmp   CMPSIGN

*---------------------------------------------------------------
* GETSIZE -- OPEN(EVPATH), GET_EOF, CLOSE -- the ONE primitive
* that answers a size question the same way for the root
* argument and a descendant alike (see this file's header). OUT:
* carry clear=ok, FSZPARM_EF=3-byte little-endian EOF; carry
* set=open/stat failed. CLOBBERS: everything.
*---------------------------------------------------------------
GETSIZE     lda   EVPATH
            sta   PTR0
            lda   EVPATH+1
            sta   PTR0+1
            lda   #<EVMLIP
            sta   PTR1
            lda   #>EVMLIP
            sta   PTR1+1
            jsr   MKPATH
            lda   #PCOUNT_OPEN
            sta   EVOPARM
            lda   #<EVMLIP
            sta   EVOPARM_PT
            lda   #>EVMLIP
            sta   EVOPARM_PT+1
            lda   #<EVOPARM
            ldx   #>EVOPARM
            jsr   SC_OPEN
            bcc   :gsopenok
            rts
:gsopenok   lda   EVOPARM_RF
            sta   FSZPARM_RF
            lda   #2           ;param_count -- GET_EOF is
            sta   FSZPARM      ;ref_num + a 3-byte value
            lda   #<FSZPARM
            ldx   #>FSZPARM
            jsr   SC_GETEOF
            bcc   :gseofok
            lda   #1
            bra   :gseofsv
:gseofok    lda   #0
:gseofsv    sta   GSEOFERR
            lda   EVOPARM_RF
            sta   EVCPARM_RF
            lda   #PCOUNT_CLOSE
            sta   EVCPARM
            lda   #<EVCPARM
            ldx   #>EVCPARM
            jsr   SC_CLOSE
            lda   GSEOFERR
            beq   :gsok
            sec
            rts
:gsok       clc
            rts

*---------------------------------------------------------------
* TESTSIZE -- IN: A=0 for -size N (512-byte blocks, rounded UP),
* A=1 for -size Nc (bytes; a file at or past 65536 bytes
* saturates ACTUAL to $FFFF rather than wrapping -- see this
* file's header). CLOBBERS: everything.
*---------------------------------------------------------------
TESTSIZE    sta   NPSUF
            jsr   GETSIZE
            bcc   :tsok
            lda   #0
            rts
:tsok       lda   NPSUF
            bne   :tsbytes
            lda   FSZPARM_EF+1
            sta   ACTUALLO
            lda   FSZPARM_EF+2
            sta   ACTUALHI
            lda   ACTUALLO
            and   #1
            sta   CSTMP2
            lsr   ACTUALHI
            ror   ACTUALLO
            lda   FSZPARM_EF
            ora   CSTMP2
            beq   :tsround
            inc   ACTUALLO
            bne   :tsround
            inc   ACTUALHI
:tsround    jmp   CMPSIGN
:tsbytes    lda   FSZPARM_EF+2
            beq   :tssmall
            lda   #$FF
            sta   ACTUALLO
            sta   ACTUALHI
            jmp   CMPSIGN
:tssmall    lda   FSZPARM_EF
            sta   ACTUALLO
            lda   FSZPARM_EF+1
            sta   ACTUALHI
            jmp   CMPSIGN

*---------------------------------------------------------------
* CMPSIGN -- generic POSIX +n/-n/n compare. IN: ACTUALLO/HI = a
* measured 16-bit value, CURSIGN/CURVLO/CURVHI = the just-
* consumed token's own target (0/1/2=exact/+/-, magnitude).
* OUT: A=1/0. CLOBBERS: A.
*---------------------------------------------------------------
CMPSIGN     sec
            lda   ACTUALLO
            sbc   CURVLO
            sta   CSTMP
            lda   ACTUALHI
            sbc   CURVHI
            bcc   :cslt
            ora   CSTMP
            beq   :cseq
            lda   CURSIGN
            cmp   #1
            beq   :csyes
            lda   #0
            rts
:cslt       lda   CURSIGN
            cmp   #2
            beq   :csyes
            lda   #0
            rts
:cseq       lda   CURSIGN
            bne   :csno
:csyes      lda   #1
            rts
:csno       lda   #0
            rts

*---------------------------------------------------------------
* CUMTAB -- non-leap cumulative days before each month (Jan=0).
* DAYNUM indexes this by (MONTHV2-1)*2.
*---------------------------------------------------------------
CUMTAB      da    0,31,59,90,120,151,181,212,243,273,304,334

*---------------------------------------------------------------
* Flag dispatch table -- TOKENIZE's STRCMP loop. Parallel
* arrays, index-matched: FLAGSTRLO/HI (the word), FLAGTOK
* (token type),
* FLAGARGK (how many/what shape of following words it eats).
*---------------------------------------------------------------
FLAGSTRLO   dfb   <FS_NAME,<FS_TYPE,<FS_PRINT,<FS_EXEC
            dfb   <FS_PRUNE,<FS_NEWER,<FS_PATH,<FS_MTIME
            dfb   <FS_SIZE,<FS_LINKS,<FS_XDEV,<FS_NOUSR
            dfb   <FS_NOGRP,<FS_LP,<FS_RP,<FS_NOT
            dfb   <FS_AND,<FS_OR,<FS_DEPTH,<FS_OK
FLAGSTRHI   dfb   >FS_NAME,>FS_TYPE,>FS_PRINT,>FS_EXEC
            dfb   >FS_PRUNE,>FS_NEWER,>FS_PATH,>FS_MTIME
            dfb   >FS_SIZE,>FS_LINKS,>FS_XDEV,>FS_NOUSR
            dfb   >FS_NOGRP,>FS_LP,>FS_RP,>FS_NOT
            dfb   >FS_AND,>FS_OR,>FS_DEPTH,>FS_OK
FLAGTOK     dfb   TT_NAME,TT_TYPE,TT_PRINT,TT_EXEC
            dfb   TT_PRUNE,TT_NEWER,TT_PATH,TT_MTIME
            dfb   TT_SIZEB,TT_LINKS,TT_XDEV,TT_NOUSER
            dfb   TT_NOGROUP,TT_LPAR,TT_RPAR,TT_NOT
            dfb   TT_AND,TT_OR,TT_DEPTH,TT_OK
FLAGARGK    dfb   AK_PTR,AK_TYPE,AK_NONE,AK_EXEC
            dfb   AK_NONE,AK_NEWER,AK_PTR,AK_NUM
            dfb   AK_NUMC,AK_NUM,AK_NONE,AK_NONE
            dfb   AK_NONE,AK_NONE,AK_NONE,AK_NONE
            dfb   AK_NONE,AK_NONE,AK_NONE,AK_EXEC

FS_NAME     asc   "-name"
            dfb   0
FS_TYPE     asc   "-type"
            dfb   0
FS_PRINT    asc   "-print"
            dfb   0
FS_EXEC     asc   "-exec"
            dfb   0
FS_PRUNE    asc   "-prune"
            dfb   0
FS_NEWER    asc   "-newer"
            dfb   0
FS_PATH     asc   "-path"
            dfb   0
FS_MTIME    asc   "-mtime"
            dfb   0
FS_SIZE     asc   "-size"
            dfb   0
FS_LINKS    asc   "-links"
            dfb   0
FS_XDEV     asc   "-xdev"
            dfb   0
FS_NOUSR    asc   "-nouser"
            dfb   0
FS_NOGRP    asc   "-nogroup"
            dfb   0
FS_LP       asc   "("
            dfb   0
FS_RP       asc   ")"
            dfb   0
FS_NOT      asc   "!"
            dfb   0
FS_AND      asc   "-a"
            dfb   0
FS_OR       asc   "-o"
            dfb   0
FS_DEPTH    asc   "-depth"
            dfb   0
FS_OK       asc   "-ok"
            dfb   0
