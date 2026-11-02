*---------------------------------------------------------------
* sed.s -- stream editor, POSIX-shaped (docs/SED.md).
*
* Usage: sed [-n] SCRIPT [FILE...]
*        sed [-n] -e SCRIPT ... [-f FILE] ... [FILE...]
*
* The regex is liba/regex.s + regex2.s -- the ONE engine ed,
* ex, vi and grep share: BRE with \(..\) \1-\9 and \{n,m\}
* (docs/ANACHRONISMS.md W5a/W5b). sed adds the command layer:
*
*   script := ( [addr[,addr]] ['!'] cmd )*   separated by
*                                            newline or ';'
*   addr   := N | '$' | /re/ | \cREc     ('//' = last RE used)
*   cmd    := { } a i c b t : d D g G h H l n N p P q r s w
*             x y =  and '#' comments ('#n' on line 1 = -n)
*   s      := s/re/repl/[g][p][N][w file]   any delimiter;
*             repl knows & \1-\9 \n \<newline> \X
*   y      := y/src/dst/                     \n \\ \<delim>
*
* The pattern space and hold space hold up to PSMAX bytes;
* an INPUT line is capped at LINEMAX (the read window). The
* embedded newline of a multi-line pattern space is CR ($8D),
* the maux text newline, so p/P/D/w and the console all agree,
* and the engine's \n atom matches it.
*
* LIMITS, every one LOUD (exit 2) -- see scripts/check_sed.py
* DIVERGENCE for the named rows:
*  - script text <= SCRMAX bytes, <= SED_MAXCMD commands,
*    <= MAXLAB labels, <= MAXWF distinct w files, <= MAXAPP
*    queued a/r per cycle.
*  - input lines longer than LINEMAX truncate (grep.s's rule);
*    a pattern space grown past PSMAX (s, N, G, H) is
*    "sed: pattern space overflow".
*  - N with no next line quits WITHOUT the autoprint (POSIX
*    and BSD; GNU prints) -- use $!N.
*  - text is CR-terminated high-bit ASCII.
*
* Exit status: 0; q's exit code if given; 2 on a usage error,
* a bad script, an overflow, or a FILE that could not be
* opened (reported, the remaining input still runs).
*
* Uses ONLY liba -- no direct syscalls, no raw gate address.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/sed.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/regex.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255       ;read WINDOW -- (CBPTR),y walk and
                            ;BUFPOS/BUFLEN are 8-bit
RDCHUNK     equ   1020      ;bytes per SC_READ -- 4 windows
                            ;(docs/PERF-PLAN.md)
LINEMAX     equ   255       ;longest INPUT line
PSMAX       equ   2047      ;pattern/hold space capacity
SCRMAX      equ   2048      ;script text capacity
SED_MAXCMD  equ   48        ;compiled commands
MAXLAB      equ   16        ;labels
MAXWF       equ   4         ;distinct w files
MAXAPP      equ   16        ;queued a/r per cycle
MAXBLK      equ   8         ;{ nesting depth
LFOLD       equ   70        ;l folds so no row exceeds 69 + \

* -- command flags (CFLG) --
SF_G        equ   1
SF_P        equ   2
SF_NEG      equ   4         ;'!'
SF_W        equ   8         ;s///w
SF_LABREF   equ   16        ;CP1 holds a label ptr (parse only)

* -- verb codes: index into VCHARS/PTAB/VTAB --
V_LBRACE    equ   0
V_RBRACE    equ   1
V_A         equ   2
V_B         equ   3
V_C         equ   4
V_D         equ   5
V_DD        equ   6
V_EQ        equ   7
V_G         equ   8
V_GG        equ   9
V_H         equ   10
V_HH        equ   11
V_I         equ   12
V_L         equ   13
V_N         equ   14
V_NN        equ   15
V_P         equ   16
V_PP        equ   17
V_Q         equ   18
V_R         equ   19
V_S         equ   20
V_T         equ   21
V_W         equ   22
V_X         equ   23
V_Y         equ   24
V_LABEL     equ   25

* -- error codes: index into MSGTAB --
E_CMD       equ   0
E_UNTERM    equ   1
E_EXTRA     equ   2
E_ADDR      equ   3
E_LABEL     equ   4
E_BRACE     equ   5
E_YLEN      equ   6
E_TOOMANY   equ   7
E_NOPREV    equ   8
E_FLAG      equ   9
E_FILE      equ   10
E_DUPLAB    equ   11
E_WOPEN     equ   12
E_PSOVF     equ   13
E_APPFULL   equ   14
E_SCRLONG   equ   15
E_SCRFILE   equ   16
E_LABFULL   equ   17

*-- CBPTR: sed-private ZERO PAGE claim. liba's window is
*-- $E0-$F1 (zp.equ), the kernel's $F7-$FC, regex.s's $90-$A2,
*-- $B0-$D1 and $D4-$DA -- $D2/$D3 is unclaimed by anything sed
*-- links. (CBPTR),y is the read-window walk.
CBPTR       equ   $D2       ;2  current CBUF window base
* -- sed-private zero page $30-$47: clear of every regex
* -- window and of zp.equ; nothing else claims $30-$8F in a
* -- userland bank (ed.s's own box establishes the same fact).
SD_SRC      equ   $30       ;2  substitution verbatim cursor
SD_BND      equ   $32       ;2  SBVERB's copy bound
SD_REP      equ   $34       ;2  SBEXPAND's replacement walk
SD_AMP      equ   $36       ;2  & / \N copy cursor
SD_NUM      equ   $38       ;2  PARSENUM accumulator / addr val
SD_TMP      equ   $3A       ;2  16-bit scratch
SD_SP       equ   $3C       ;2  script parse cursor
SD_DST      equ   $3E       ;2  output cursor (SUBPUT, copies)
SD_WK       equ   $40       ;2  walk pointer 1
SD_WK2      equ   $42       ;2  walk pointer 2
SD_LIM      equ   $44       ;2  overflow bound for SD_DST
SD_CNT      equ   $46       ;1  l's column
SD_CH       equ   $47       ;1  current delimiter / char
SD_NCT      equ   $48       ;2  -f ingest fold byte counter

*---------------------------------------------------------------
* START
*---------------------------------------------------------------
START       stz   NFLAG
            stz   ERRFLAG
            stz   QUITFLG
            stz   QCODE
            stz   LINENO
            stz   LINENO+1
            stz   NCMDS
            stz   NLAB
            stz   NWF
            stz   NAPP
            stz   STRMDEAD
            stz   USESTDIN
            stz   NSCRIPT
            stz   TFLAG
            stz   RESTART
            stz   LASTRE
            stz   LASTRE+1
            lda   #<ARENA_A
            sta   PSOWN
            lda   #>ARENA_A
            sta   PSOWN+1
            lda   #<ARENA_B
            sta   HSPTR
            lda   #>ARENA_B
            sta   HSPTR+1
            lda   #<ARENA_C
            sta   SCRPTR
            lda   #>ARENA_C
            sta   SCRPTR+1
            lda   #0
            sta   ARENA_B            ;hold space starts empty
            lda   #<SCRIPTBUF        ;script assembly cursor
            sta   SD_DST
            lda   #>SCRIPTBUF
            sta   SD_DST+1
            lda   #<SEDOPTS
            ldx   #>SEDOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$EE               ;'n'
            beq   :fn
            cmp   #$E5               ;'e'
            beq   :fe
            cmp   #$E6               ;'f'
            beq   :ff
:usage      jmp   USAGE_ERR
:fn         lda   #1
            sta   NFLAG
            bra   :optlp
:fe         lda   OPTARG             ;OPTARG dies at the next
            sta   PTR0               ;GETOPT -- copy it out now
            lda   OPTARG+1
            sta   PTR0+1
            jsr   SCRADD
            bra   :optlp
:ff         lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   SCRFILE
            bra   :optlp
:optdone    lda   OPTIND
            sta   FIRSTFILE
            lda   NSCRIPT
            bne   :havescr
            lda   ARGC               ;no -e/-f: the first
            sec                      ;operand is the script
            sbc   OPTIND
            cmp   #1
            bcc   :usage
            lda   OPTIND
            jsr   GETARG
            jsr   SCRADD
            inc   FIRSTFILE
:havescr    lda   #0
            sta   (SD_DST)           ;terminate the script
            lda   SCRIPTBUF          ;'#n' as the whole first
            cmp   #"#"               ;line = -n (POSIX)
            bne   :parse
            lda   SCRIPTBUF+1
            cmp   #"n"
            bne   :parse
            lda   SCRIPTBUF+2
            beq   :setn
            cmp   #$8D
            beq   :setn              ;either terminator ends the
            cmp   #$0D               ;'#n' line -- a -f script
            bne   :parse             ;written outside maux
:setn       lda   #1
            sta   NFLAG
:parse      jsr   PARSESCRIPT
            jsr   WFOPEN
            jsr   STREAMINIT
*-- The cycle. No lookahead LINE: the '$' address needs only
*-- the BIT "is any byte left after this line" -- PEEKEOF
*-- (sedio.s) answers it without consuming or copying.
:cycle      jsr   GETLINE            ;current line -> LINEPTR
            bcs   :empty
            jsr   PEEKEOF            ;sets LASTFLG
            inc   LINENO
            bne   :lnc
            inc   LINENO+1
:lnc        stz   TFLAG              ;t: "since the most recent
                                     ;reading of an input line"
:again      stz   RESTART
            jsr   EXECLINE
            lda   QUITFLG
            bne   :empty
            lda   RESTART            ;D: rerun the script on
            bne   :again             ;the rest, no read
            bra   :cycle
:empty      lda   QCODE
            bne   :ex
            lda   ERRFLAG
:ex         jsr   EXIT

*---------------------------------------------------------------
* SCRADD -- append the liba string at PTR0 to the script text,
* then a CR (POSIX: -e pieces join with newlines). Overflow is
* a loud E_SCRLONG.
*---------------------------------------------------------------
SCRADD      lda   #1
            sta   NSCRIPT
            ldy   #0
:lp         lda   (PTR0),y
            beq   :done
            jsr   SCRPUT
            iny
            bne   :lp
            inc   PTR0+1
            bra   :lp
:done       lda   #$8D
            jmp   SCRPUT

* -- SCRPUT: A -> script text at SD_DST, bounded at SCRMAX.
SCRPUT      pha
            lda   SD_DST
            cmp   #<SCRIPTBUF+SCRMAX
            bne   :ok
            lda   SD_DST+1
            cmp   #>SCRIPTBUF+SCRMAX
            beq   :long
:ok         pla
            sta   (SD_DST)
            inc   SD_DST
            bne   :rts
            inc   SD_DST+1
:rts        rts
:long       lda   #E_SCRLONG
            jmp   RUNERR

*---------------------------------------------------------------
* SCRFILE -- append the contents of the -f FILE named at PTR0
* to the script text (one read: the request is the room left
* plus one, so a file that does not fit is detected, never
* silently cut). A file whose last byte is not a CR gets one.
*---------------------------------------------------------------
SCRFILE     lda   #1
            sta   NSCRIPT
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :opened
            jmp   :nofile
:opened     lda   OPARM_REF
            sta   RPARM3_REF
            sta   CPARM_REF
            lda   SD_DST
            sta   RPARM3_BUF
            lda   SD_DST+1
            sta   RPARM3_BUF+1
            lda   #<SCRIPTBUF+SCRMAX ;room left + 1
            sec
            sbc   SD_DST
            sta   RPARM3_REQ
            lda   #>SCRIPTBUF+SCRMAX
            sbc   SD_DST+1
            sta   RPARM3_REQ+1
            inc   RPARM3_REQ
            bne   :req
            inc   RPARM3_REQ+1
:req        lda   #<RPARM3
            ldx   #>RPARM3
            jsr   SC_READ
            php
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            plp
            bcc   :read
            jmp   :nofile
:read       lda   RPARM3_TRANS       ;trans == room+1: too long
            cmp   RPARM3_REQ
            bne   :fits
            lda   RPARM3_TRANS+1
            cmp   RPARM3_REQ+1
            bne   :fits
            lda   #E_SCRLONG
            jmp   RUNERR
:fits       lda   RPARM3_TRANS
            ora   RPARM3_TRANS+1
            beq   :done              ;empty file
            clc
            lda   SD_DST
            adc   RPARM3_TRANS
            sta   SD_DST
            lda   SD_DST+1
            adc   RPARM3_TRANS+1
            sta   SD_DST+1
*-- NORMALISE ON INGEST. A -f script written outside maux ends
*-- its lines with $0D. Fold the bytes just read, ONCE, here --
*-- so sedparse downstream sees maux's own terminator and
*-- nothing below this point has to know where a script came
*-- from. Runs over RPARM3_BUF for RPARM3_TRANS bytes, i.e.
*-- exactly what SC_READ delivered, never the whole buffer.
            lda   RPARM3_BUF
            sta   SD_WK
            lda   RPARM3_BUF+1
            sta   SD_WK+1
            lda   RPARM3_TRANS
            sta   SD_NCT
            lda   RPARM3_TRANS+1
            sta   SD_NCT+1
:fold       lda   SD_NCT
            ora   SD_NCT+1
            beq   :folded
            lda   (SD_WK)
            cmp   #$0D
            bne   :fnext
            lda   #$8D
            sta   (SD_WK)
:fnext      inc   SD_WK
            bne   :fdec
            inc   SD_WK+1
:fdec       lda   SD_NCT
            bne   :fdec2
            dec   SD_NCT+1
:fdec2      dec   SD_NCT
            bra   :fold
:folded     lda   SD_DST             ;last byte a CR?
            bne   :nb
            dec   SD_DST+1
:nb         dec   SD_DST
            lda   (SD_DST)
            inc   SD_DST
            bne   :nc
            inc   SD_DST+1
:nc         cmp   #$8D
            beq   :done
            cmp   #$0D             ;either terminator ends a
            beq   :done          ;line -- a foreign file
            lda   #$8D
            jsr   SCRPUT
:done       rts
:nofile     lda   #E_SCRFILE
            jmp   RUNERR

*---------------------------------------------------------------
* USAGE_ERR -- usage line, exit 2.
* BADSCRIPT -- A = error code: "sed: MSG near char N", exit 2
*              (N = the parse cursor's offset into the script).
* RUNERR    -- A = error code: "sed: MSG", exit 2.
*---------------------------------------------------------------
USAGE_ERR   lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

BADSCRIPT   jsr   ERRHEAD
            lda   #<NEARMSG
            sta   PTR0
            lda   #>NEARMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   SD_SP
            sec
            sbc   #<SCRIPTBUF
            sta   U2DEC_VAL
            lda   SD_SP+1
            sbc   #>SCRIPTBUF
            sta   U2DEC_VAL+1
            ldx   #FD_STDERR
            jsr   PRNUM
            bra   ERRTAIL

RUNERR      jsr   ERRHEAD
ERRTAIL     lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            jsr   EXIT

* -- ERRHEAD: "sed: " + MSGTAB[A] to stderr.
ERRHEAD     asl   a
            tay
            lda   MSGTAB,y
            sta   SD_TMP
            lda   MSGTAB+1,y
            sta   SD_TMP+1
            lda   #<SEDPFX
            sta   PTR0
            lda   #>SEDPFX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   SD_TMP
            sta   PTR0
            lda   SD_TMP+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jmp   PUTS

* -- The compiler, the executor, the selection/substitution
* -- half, the stream reader and the output helpers are `put`
* -- modules: one assembly unit, split so each file clears the
* -- self-hosting source windows (scripts/check_dialect.py).
            put   sedparse.s
            put   sedexec.s
            put   sedsel.s
            put   sedio.s
            put   sedout.s

*---------------------------------------------------------------
SEDOPTS     asc   "ne:f:"
            dfb   0
USAGEMSG    asc   "usage: sed [-n] script [file...]"
            dfb   $8D
            asc   "       sed [-n] [-e script]... [-f sfile]..."
            asc   " [file...]"
            dfb   $8D,0
SEDPFX      asc   "sed: "
            dfb   0
NEARMSG     asc   " near char "
            dfb   0
OPENMSG     asc   "sed: cannot open "
            dfb   0
DEVSTDOUT   asc   "/dev/stdout"
            dfb   0

MSGTAB      da    M_CMD,M_UNTERM,M_EXTRA,M_ADDR
            da    M_LABEL,M_BRACE,M_YLEN,M_TOOMANY
            da    M_NOPREV,M_FLAG,M_FILE,M_DUPLAB
            da    M_WOPEN,M_PSOVF,M_APPFULL,M_SCRLONG
            da    M_SCRFILE,M_LABFULL
M_CMD       asc   "unknown command"
            dfb   0
M_UNTERM    asc   "unterminated s, y or address"
            dfb   0
M_EXTRA     asc   "extra characters after command"
            dfb   0
M_ADDR      asc   "bad address"
            dfb   0
M_LABEL     asc   "undefined or missing label"
            dfb   0
M_BRACE     asc   "unmatched { or }"
            dfb   0
M_YLEN      asc   "y strings differ in length"
            dfb   0
M_TOOMANY   asc   "too many commands"
            dfb   0
M_NOPREV    asc   "no previous regular expression"
            dfb   0
M_FLAG      asc   "bad flag to s"
            dfb   0
M_FILE      asc   "missing filename"
            dfb   0
M_DUPLAB    asc   "duplicate label"
            dfb   0
M_WOPEN     asc   "cannot create w file"
            dfb   0
M_PSOVF     asc   "pattern space overflow"
            dfb   0
M_APPFULL   asc   "too many a/r in one cycle"
            dfb   0
M_SCRLONG   asc   "script too long"
            dfb   0
M_SCRFILE   asc   "cannot read -f file"
            dfb   0
M_LABFULL   asc   "too many labels"
            dfb   0

* -- verb characters, indexed by verb code --
VCHARS      asc   "{}abcdD=gGhHilnNpPqrstwxy:"
            dfb   0

OPARM       dfb   PCOUNT_OPEN
OPARM_PATH  da    PATHBUF
OPARM_IOBUF da    $0000          ;kernel-owned, main memory --
                                 ;see cat.s's header
OPARM_REF   dfb   0

RPARM       dfb   PCOUNT_READ
RPARM_REF   dfb   0
RPARM_BUF   da    CBUF
RPARM_REQ   da    RDCHUNK
RPARM_TRANS da    0

RPARM2      dfb   PCOUNT_READ    ;r FILE chunks
RPARM2_REF  dfb   0
RPARM2_BUF  da    RBUF
RPARM2_REQ  da    BUFSZ
RPARM2_TRNS da    0

RPARM3      dfb   PCOUNT_READ    ;-f FILE, one read
RPARM3_REF  dfb   0
RPARM3_BUF  da    0
RPARM3_REQ  da    0
RPARM3_TRANS da   0

CPARM       dfb   PCOUNT_CLOSE
CPARM_REF   dfb   0

            put   ../liba/regex.s
            put   ../liba/regex2.s
            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s
            put   ../liba/creat.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s
            put   ../liba/regexbss.s

*---------------------------------------------------------------
* sed's own scratch -- `dum`/`dend` at the textual end, past
* every emitted byte, chained on REGEX_BSSEND (never `ds` in
* text: real zeros cost 39.07 cyc/byte at spawn). NOTHING
* ZEROES THIS ARENA (docs/STICKY.md sec 21) -- every cell is
* written before its first read:
*  - the flag/counter block through LASTRE: stz'd at START.
*  - PSOWN/HSPTR/SCRPTR/ARENA_B[0]: stored at START.
*  - FIRSTFILE: stored after the option loop.
*  - the command arrays: PARSECMD clears every field of entry
*    N before NCMDS admits N; CACT is stz'd there too.
*  - LABTAB/WFTAB/BLKSTK/APPQ: indexed only below their own
*    counters, which START/PARSESCRIPT zero.
*  - WFFD: stored by WFOPEN for every entry below NWF.
*  - CURCMD/DELFLG: stz'd at EXECLINE entry, every line.
*  - LASTFLG: stored by PEEKEOF before EXECLINE runs.
*  - SUBHIT/SUBOCC/LASTMEND: DOSUBST's own, per call.
*  - SRCFD/ARGIDX/BUFPOS/BUFLEN/W_REM/LINELEN: STREAMINIT,
*    NEXTFILE and GETLINE write them before any read.
*  - SCRIPTBUF: filled to SD_DST and NUL-terminated before
*    PARSESCRIPT reads it.
*  - LINEBUF/ARENA_*: NUL-terminated by whoever fills them
*    before anyone reads; bytes past a NUL are never read.
*  - PATHBUF/RBUF/CBUF: MLI-filled, read only below the count.
*---------------------------------------------------------------
            dum   REGEX_BSSEND
NFLAG       ds    1
ERRFLAG     ds    1
QUITFLG     ds    1
QCODE       ds    1
DELFLG      ds    1
LASTFLG     ds    1
USESTDIN    ds    1
STRMDEAD    ds    1
NSCRIPT     ds    1
TFLAG       ds    1
RESTART     ds    1
LINENO      ds    2
LASTRE      ds    2
NCMDS       ds    1
NLAB        ds    1
NWF         ds    1
NAPP        ds    1
BLKDEPTH    ds    1
FIRSTFILE   ds    1
ADDRFLD     ds    1
CURCMD      ds    1
SUBHIT      ds    1
SUBOCC      ds    2
LASTMEND    ds    2
SRCFD       ds    1
ARGIDX      ds    1
BUFPOS      ds    1
BUFLEN      ds    1
LINELEN     ds    1
WFIDX       ds    1
WRFD        ds    1
PSOWN       ds    2         ;the arena the pattern space OWNS
HSPTR       ds    2         ;the hold space arena
SCRPTR      ds    2         ;the substitution scratch arena
*-- LINEPTR: the PATTERN SPACE is a POINTER: a line that sits
*-- whole inside the read window is served straight out of
*-- CBUF (zero-copy GETLINE); a straddling line lives in
*-- LINEBUF; anything a command builds lives in PSOWN (or the
*-- freshly rotated SCRPTR). Written by GETLINE on every line.
LINEPTR     ds    2

* -- the compiled script: one array per field, indexed by
* -- command number (X) -- 48 x 16 bytes would not fit an
* -- 8-bit byte offset.
CA1T        ds    SED_MAXCMD    ;addr1 type 0/1 num/2 re/3 $
CA1VL       ds    SED_MAXCMD    ;number, or RE ptr (0 = last)
CA1VH       ds    SED_MAXCMD
CA2T        ds    SED_MAXCMD
CA2VL       ds    SED_MAXCMD
CA2VH       ds    SED_MAXCMD
CVERB       ds    SED_MAXCMD    ;verb code
CFLG        ds    SED_MAXCMD    ;SF_* bits
CP1L        ds    SED_MAXCMD    ;s pat / y src / text / r name
CP1H        ds    SED_MAXCMD    ;/ b,t target / { skip / q code
CP2L        ds    SED_MAXCMD    ;s repl / y dst
CP2H        ds    SED_MAXCMD
CNUML       ds    SED_MAXCMD    ;s numeric flag
CNUMH       ds    SED_MAXCMD
CACT        ds    SED_MAXCMD    ;range active
CWFD        ds    SED_MAXCMD    ;s///w: WFTAB index

LABPL       ds    MAXLAB        ;label text ptr
LABPH       ds    MAXLAB
LABIDX      ds    MAXLAB        ;command it names
WFPL        ds    MAXWF         ;w file name ptr
WFPH        ds    MAXWF
WFFD        ds    MAXWF         ;its open fd
BLKSTK      ds    MAXBLK        ;open '{' command numbers
AQKIND      ds    MAXAPP        ;V_A text or V_R file
AQPL        ds    MAXAPP
AQPH        ds    MAXAPP

SCRIPTBUF   ds    SCRMAX+2
LINEBUF     ds    LINEMAX+1
ARENA_A     ds    PSMAX+1
ARENA_B     ds    PSMAX+1
ARENA_C     ds    PSMAX+1
PATHBUF     ds    65
RBUF        ds    BUFSZ+1
CBUF        ds    RDCHUNK
W_REM       ds    2         ;bytes read but beyond the current
                            ;window (NEXTWIN serves them without
                            ;another syscall)
SED_BSSEND                       ;scripts/check_sed.py's poison
                                 ;span ends here
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
