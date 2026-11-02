*---------------------------------------------------------------
* more.s -- the pager, in POSIX more(1)'s shape (XCU more; the
* 2026-09-12 rewrite of the cooked pg-style v1 that FLEET F.3
* shipped on 2026-09-01). Operator: "our more seems a bit shit.
* can we posix it up". BSD-born, not V7 (ANACHRONISMS A12).
*
* Usage: more [-ceisu] [-n lines] [-p cmd] [-t tag] [file ...]
*        more -A ...   (private: the alternate screen, below)
*
* -A (maux, 2026-09-15; man(1) passes it): xterm's alternate
* screen, exactly vi's contract (docs/VI-ALTSCREEN.md) -- smcup
* ESC[?1049h once the console is raw, rmcup ESC[?1049l on every
* way out (exit, ^Z, `!`, `v`), smcup again on the way back.
* The console parks the shell's screen and brings it back, so
* quitting a man page leaves the screen the way it was. Plain
* more keeps the POSIX/BSD behaviour (the page stays on the
* glass): `ls | more` should leave the listing behind.
*
* A full page forward (SPACE, f, ^F) is painted from the top
* after a clear, not scrolled in: on the native 80-column //e a
* scroll is ~23k cycles and 23 of them were 69% of a page turn
* (2026-09-16, measured; the UltraTerm's is 800). Half pages and
* line counts still scroll, so context stays on the glass.
*
* Raw single-key commands (SC_TTYMODE raw+noecho on the console,
* the stty seed vi already uses), a count prefix, and BACKWARD
* motion: every line's start offset is kept in a table (LTAB, 3
* bytes a line -- ProDOS marks are 24-bit) over a SEEKABLE
* source. A pipe on standard input is spilled into a temp file
* (MORE.INxx, xx = this bank, ex's own naming) AS IT IS READ, so
* `ls | more` still starts at once and `b` still works. Search
* is the shared BRE engine (liba regex.s). Lines longer than the
* glass are counted as the rows they wrap to (the v1 limitation
* is gone). Overstruck X\bX is shown bold, _\bX plain, per POSIX
* "special character handling" (-u turns it off).
*
* MODULES: this file (entry, options, the exits), then
* morefile.s (the per-file driver, the copy path), moreio.s (the
* line table, the scan, the spill), moreshow.s (drawing, prompt,
* messages),
* morecmd.s (keys and commands). Split for the self-hosting
* source-buffer budget (check-dialect), like sed.
*
* PLUMBING: paging is gated by SC_TTYGEO on STDOUT (one call:
* "is it a console" AND "how many rows"). Commands are read from
* STDIN when it is the console, else from STDERR, which stays
* console-attached in a pipeline (V7's more read /dev/tty for
* the same reason). Standard output not a console: every file
* is copied through, -s honoured, nothing else (POSIX).
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/mm.procbnk2.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            put   ../../inc/sc.fdact.equ
            put   ../../inc/errno.krn.equ
            org   LOAD_BASE
            dsk   ../../build/more.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/regex.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

*-- more's own zero page ($30-$4F: the util window sed.s uses;
*-- liba is $E0+, the regex engine $B0-$D1).
MP_PTR      equ   $30       ;2  general pointer (LTAB walks)
MP_OFF      equ   $32       ;3  24-bit file offset scratch
MP_CNT      equ   $36       ;2  the command's count prefix
MP_LN       equ   $38       ;2  line index scratch (ENSURE etc)
MP_TMP      equ   $3A       ;2  16-bit scratch / jump vector
MP_TMP2     equ   $3C       ;2  16-bit scratch
MP_COL      equ   $3E       ;2  SHOWLINE's column counter
MP_NRD      equ   $40       ;2  READ_AT: bytes in IOBUF (0..256)
MP_ACC      equ   $42       ;3  24-bit scratch (PCT, APPEND)

BUFSZ       equ   256       ;one chunk of file per READ_AT
LINEMAX     equ   255       ;FETCH's cap (the regex line cap)
NLMAX       equ   10000     ;lines the table holds (3B each;
                            ;the `err` at the arena's end says
                            ;how many the bank affords)
PATMAX      equ   80        ;a typed pattern / name / command
MP_RAWMODE  equ   TMD_OPOST ;SC_TTYMODE: ICANON+ECHO clear,
                            ;OPOST kept -- more's CR must stay
                            ;a newline (vi's VI_RAWMODE, same)
MP_SIGTSTP  equ   14        ;SIG_TSTP -- cooperative ^Z

*---------------------------------------------------------------
* START -- options, geometry, the file list, then the driver.
*---------------------------------------------------------------
START       jsr   INITPARMS
            ldx   #FD_STDOUT         ;a page is ONE write:
            jsr   SIO_SETFULL        ;buffer fully on a tty
                                     ;as ls does; PROMPT,
                                     ;RAWKEY, RAWLEAVE flush
            stz   ERRFLAG
            stz   OPT_C
            stz   OPT_E
            stz   OPT_I
            stz   OPT_S
            stz   OPT_U
            stz   OPT_A
            stz   OPT_N
            stz   OPT_N+1
            stz   HAVEPAT
            stz   SPILLFD
            stz   CMDFILE
            stz   QUITFLG
            stz   TABFULL
            stz   RAWON
            stz   RDFD
            stz   ISSTDIN
            stz   PLEN
            stz   MSGUP
            stz   HLSW
            stz   FLUSHPAR
            ldx   #51                    ;26 marks x 2 = unset
:mk         lda   #$FF
            sta   MARKS,x
            dex
            bpl   :mk
            stz   LASTPOS
            stz   LASTPOS+1

            lda   #<OPTLIST
            ldx   #>OPTLIST
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #"c"
            beq   :oc
            cmp   #"e"
            beq   :oe
            cmp   #"i"
            beq   :oi
            cmp   #"s"
            beq   :os
            cmp   #"u"
            beq   :ou
            cmp   #"A"
            beq   :oa
            cmp   #"n"
            beq   :on
            cmp   #"p"                   ;-p cmd / -t tag: taken
            beq   :optlp                 ;and not acted on (no
            cmp   #"t"                   ;tags, no -p commands)
            beq   :optlp
            jmp   USAGE
:oc         inc   OPT_C
            bra   :optlp
:oe         inc   OPT_E
            bra   :optlp
:oi         inc   OPT_I
            bra   :optlp
:os         inc   OPT_S
            bra   :optlp
:ou         inc   OPT_U
            bra   :optlp
:oa         inc   OPT_A
            bra   :optlp
:on         lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   DECPARSE               ;-> MP_TMP; carry = bad
            bcs   :usage
            lda   MP_TMP
            ora   MP_TMP+1
            beq   :usage                 ;-n 0: not positive
            lda   MP_TMP
            sta   OPT_N
            lda   MP_TMP+1
            sta   OPT_N+1
            bra   :optlp
:usage      jmp   USAGE

:optdone    lda   OPTIND
            sta   CURIDX
            lda   ARGC
            sec
            sbc   OPTIND
            sta   NFILES

*-- geometry gates paging: a console stdout answers with rows.
            lda   #<GEOBUF
            sta   PTR0
            lda   #>GEOBUF
            sta   PTR0+1
            lda   #FD_STDOUT
            jsr   SC_TTYGEO
            bcc   :console
            stz   PAGING
            jmp   COPYALL
:console    lda   #1
            sta   PAGING
            lda   GEOBUF                 ;cols (0: assume 80)
            bne   :havecols
            lda   #80
:havecols   sta   COLS
            lda   OPT_N+1                ;-n given?
            bne   :nbig
            lda   OPT_N
            bne   :haverows
            lda   GEOBUF+1               ;rows
            beq   :fallrows
            sec
            sbc   #1                     ;the prompt's row
            bne   :haverows
:fallrows   lda   #23
            bra   :haverows
:nbig       lda   #255                   ;-n past 255: clamp
:haverows   sta   PAGEROWS
            lsr   a
            bne   :havehalf
            lda   #1
:havehalf   sta   HALF

*-- where commands come from: stdin if it is the console, else
*-- stderr (still the console in `ls | more`).
            lda   #FD_STDIN
            jsr   SC_FDSTAT
            bcs   :cmderr
            sta   STDINKIND
            bpl   :cmderr                ;not a device
            lda   #FD_STDIN
            bra   :havecmd
:cmderr     lda   #FD_STDERR
:havecmd    sta   CMDFD

            lda   NFILES
            bne   :files
*-- no operand: page standard input -- unless it is the console
*-- itself (nothing to page; V7/BSD print usage there too).
            lda   STDINKIND
            bmi   :usage2
            jsr   RAWENTER
            jsr   OPENSTDIN
            bcs   :done
            bra   :page
:usage2     jmp   USAGE

:files      jsr   RAWENTER
:nextf      jsr   OPENCUR                ;carry set: cannot open
            bcc   :page
            inc   CURIDX
            lda   CURIDX
            cmp   ARGC
            bcc   :nextf
            bra   :done
:page       jsr   SHOWFIRST
            jsr   CMDLOOP
:done       jmp   EXITALL

*---------------------------------------------------------------
* USAGE -- to stderr, exit 2.
*---------------------------------------------------------------
USAGE       lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* EXITALL -- the one way out while paging: cooked+echo back (a
* raw->shell handoff ALWAYS restores, docs/VI-DESIGN.md sec 5),
* the spill / command temp files unlinked, ERRFLAG the status.
*---------------------------------------------------------------
EXITALL     jsr   HLRESTORE
            jsr   RAWLEAVE
            jsr   SPILLDROP
            lda   ERRFLAG
            jsr   EXIT

OPTLIST     asc   "Acein:p:st:u"
            dfb   0
USAGEMSG    asc   "usage: more [-ceisu] [-n lines] [file ...]"
            dfb   $8D,0
ERRMSG      asc   "more: cannot open "
            dfb   0
SPILLMSG    asc   "more: cannot create the spill file"
            dfb   $8D,0
STDINNAME   asc   "(stdin)"
            dfb   0

            put   morefile.s
            put   moreio.s
            put   moreshow.s
            put   morecmd.s

            put   ../liba/regex.s
            put   ../liba/regex2.s
            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s
            put   ../liba/seek.s
            put   ../liba/env.s
            put   ../liba/pathres.s
            put   ../liba/pathtab.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/libabss.s
            put   ../liba/regexbss.s

*---------------------------------------------------------------
* more's own arena -- dum/dend at the textual end, chained onto
* the regex engine's block (REGEX_BSSEND, which itself follows
* liba's -- grep's own anchor; a `dum LIBA_BSSEND` here would
* OVERLAY RE_GRPST on these cells, and did, 2026-09-12). LTAB
* is LAST so the `err` below measures how many lines the bank
* affords.
*---------------------------------------------------------------
            dum   REGEX_BSSEND
ERRFLAG     ds    1
OPT_C       ds    1
OPT_E       ds    1
OPT_I       ds    1
OPT_S       ds    1
OPT_U       ds    1
OPT_A       ds    1              ;-A: the alternate screen
OPT_N       ds    2
PAGING      ds    1
PAGEROWS    ds    1              ;rows a screenful fills
COLS        ds    1
HALF        ds    1              ;d/u default, count resets it
CMDFD       ds    1              ;where keys come from
STDINKIND   ds    1              ;SC_FDSTAT of fd 0
SAVEMD      ds    1              ;the console mode we replaced
RAWON       ds    1              ;1 while the console is raw
NFILES      ds    1
CURIDX      ds    1              ;argv index of the current file
CURNAME     ds    2              ;its operand text (liba string)
ISLAST      ds    1
ISSTDIN     ds    1              ;1: a pipe, spilled
RDFD        ds    1              ;the seekable source
SPILLFD     ds    1              ;MORE.INxx while a pipe pages
CMDFILE     ds    1              ;1: MORE.CMDxx exists (unlink)
SIZEKNOWN   ds    1
FSIZE       ds    3
SCANPOS     ds    3              ;next byte the scan reads
NLINES      ds    2              ;line STARTS known
TOTAL       ds    2              ;lines, once EOFSEEN
EOFSEEN     ds    1
TABFULL     ds    1
TOP         ds    2              ;first line on the glass
BOT         ds    2              ;last line shown ($FFFF: none)
LASTPOS     ds    2              ;'' -- before the last big move
ATEOF       ds    1              ;the last fill ran out of file
FIRSTSCR    ds    1
QUITFLG     ds    1
FWDCLASS    ds    1              ;the command was a forward one
WASEOF      ds    1              ;ATEOF when it was typed
PREVBLANK   ds    1              ;-s: the line before was blank
ATBOL       ds    1
CNTSET      ds    1
FROWS       ds    1
FROWCNT     ds    1
FLEN        ds    1              ;FETCH's line length
INLEN       ds    1              ;LINEIN's line length
PLEN        ds    1              ;the prompt's visible width
MSGUP       ds    1              ;a message holds the prompt row
ARROWFLG    ds    1              ;RAWKEY mapped an arrow
PEND        ds    1              ;EMITCH's held character
PENDBOLD    ds    1
BSCNT       ds    1
BOLDON      ds    1
ESCST       ds    1
ESCN        ds    1              ;CSI parameter bytes seen
ESCPAR      ds    1              ;the last one
HLSW        ds    1              ;1: console switched to bright
FLUSHPAR    ds    1              ;SHOWLINE: flush every 2nd
SRCHDIR     ds    1              ;0 forward, 1 backward
SRCHNOT     ds    1              ;the ! prefix
HAVEPAT     ds    1
LASTDIR     ds    1
LASTNOT     ds    1
MARKS       ds    52             ;a-z -> TOP, $FFFF unset
GEOBUF      ds    4
SKBUF       ds    3              ;LSEEK's in/out offset
WSTAT       ds    1
FDACT       ds    1
ARGVB       ds    6
KEYBUF      ds    4
PATHBUF     ds    65             ;1 count byte + up to 64 chars
TMPNAME     ds    12             ;MORE.INxx / MORE.CMDxx
TMPPATH     ds    65
TMPPATH2    ds    65             ;:e's candidate
CMDNAME     ds    12
CMDPATH     ds    65
EXNAME      ds    PATMAX+1       ;:e's name, for the prompt
PATBUF      ds    PATMAX+1
PATFOLD     ds    PATMAX+1
INBUF       ds    PATMAX+2       ;LINEIN's text (+CR for !)
LINEBUF     ds    LINEMAX+1      ;FETCH: one line, NUL-ended

OPARM       ds    1              ;param_count
OPARM_PATH  ds    2
OPARM_IOBUF ds    2              ;kernel-owned; see cat.s
OPARM_REF   ds    1              ; result: fd

RPARM       ds    1
RPARM_REF   ds    1
RPARM_BUF   ds    2
RPARM_REQ   ds    2
RPARM_TRANS ds    2              ; result: bytes actually read

WPARM       ds    1
WPARM_REF   ds    1
WPARM_BUF   ds    2
WPARM_REQ   ds    2
WPARM_TRANS ds    2

CPARM       ds    1
CPARM_REF   ds    1

CRPARM      ds    1              ;CREATE for the temp files
CRPARM_PATH ds    2
CRPARM_ACC  ds    1
CRPARM_FTY  ds    1
CRPARM_AUX  ds    2
CRPARM_STY  ds    1
CRPARM_CDT  ds    2
CRPARM_CTM  ds    2

ULPARM      ds    1              ;DESTROY
ULPARM_PATH ds    2

EFPARM      ds    1              ;SET_EOF (truncate the spill)
EFPARM_REF  ds    1
EFPARM_EOF  ds    3

CHK_BASE    ds    3              ;READ_AT cache: IOBUF's file
CHK_LEN     ds    2              ; offset and byte count (0 =
CHK_DLT     ds    1              ; none); a hit's index scratch
IOBUF       ds    BUFSZ
LTAB        ds    NLMAX*3
            err   */$BF00
            dend
