*---------------------------------------------------------------
* uniq.s -- collapse adjacent duplicate lines.
*
* Usage: uniq [-cdu] [-f fields] [-s chars] [input [output]]
*
* -f/-s (SHIPPED 2026-09-17): SKIPCMP computes a per-line
* "compare from here" pointer -- skip SKIPFLD fields (leading
* blanks + a maximal non-blank run, repeated) then SKIPCHR more
* raw bytes -- run once for CURBUF and once for PREVBUF before
* the existing STRCMP; an exhausted line stops at its own NUL
* (an over-skipped line compares as its own empty tail, i.e.
* always equal to any other over-skipped line, which is what
* "ignore more than the line has" should do). -c's run count and
* the printed COPY are UNAFFECTED -- only which bytes decide
* adjacency changes; the full original line still prints.
*
* CONTRACT (V6 semantics -- uniq does not sort; it is sort's
* partner). Each ADJACENT run of identical lines collapses to
* one copy:
*   (default)  print one copy of each run.
*   -c         prefix the copy with the run's repeat count,
*              right-aligned in a CNTFLD-wide field + one space.
*   -d         print ONLY runs with length > 1 (the duplicates).
*   -u         print ONLY runs with length == 1 (the uniques).
* -d and -u together are a usage error: message to fd 2, exit 2.
*
* input defaults to fd 0, output to fd 1. A named output is
* CREATEd (if it doesn't exist) then OPENed; if it already
* exists, CREATE's duplicate-name error is ignored and OPEN is
* tried anyway -- but there is NO MLI truncate primitive in liba
* yet (see docs/USERLAND.md, cp.s carries the same gap), so
* writing into an existing, LONGER file will NOT shrink it. New
* and empty/shorter output files are unaffected. This is a
* documented v1 limitation, not silent data loss.
*
* LINE BUFFER: two LINEMAX(255)-byte buffers, CURBUF and PREVBUF
* -- a streaming tool needs no arena, just "current" and
* "previous". OVERFLOW is NOT silently truncated: once LINEMAX
* bytes have accumulated, GETLINE returns them as a complete
* line WITHOUT consuming further input, so the very next byte
* starts a NEW line. A physical line longer than LINEMAX is thus
* delivered as several logical lines (an implicit break at
* LINEMAX) -- every byte still reaches some line, and adjacent
* pieces of an over-long line will correctly show up as
* "duplicated" runs if repeated. See GETLINE's own header.
*
* -c does NOT reuse liba's PRNUM: PRNUM writes decimal only,
* right-aligned CNTFLD-wide padding is uniq's own requirement.
* PRCNT below is a thin rewrite of PRNUM's own body -- it still
* goes through liba's U2DEC for the conversion, only the field
* padding (and, as of PRNUM's own fd-in-X wave, redundantly the
* fd plumbing too) are uniq's own.
*
* CLOSE ordering: PUTC full-buffers a real output file (fd>=3)
* and only auto-flushes at 512B or at EXIT. Closing OUTFD before
* EXIT's own flush pass would write to an already-closed fd, so
* liba's FCLOSE (flush, then close, one call) replaces a bare
* SC_CLOSE on OUTFD -- see the :run block below.
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
            dsk   ../../build/uniq.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255              ;read chunk -- see GETBYTE
LINEMAX     equ   255              ;longest line before a forced
                                   ;break -- see header
CNTFLD      equ   5                ;-c count field width (65535
                                   ;is 5 digits -- RUNCNT's cap)

START       stz   WANT_C
            stz   WANT_D
            stz   WANT_U
            stz   SKIPFLD
            stz   SKIPCHR
            lda   #<UNIQOPTS
            ldx   #>UNIQOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$E3                   ;'c'
            bne   :not_c
            sta   WANT_C
            bra   :optlp
:not_c      cmp   #$E4                   ;'d'
            bne   :not_d
            sta   WANT_D
            bra   :optlp
:not_d      cmp   #$F5                   ;'u'
            bne   :not_u
            sta   WANT_U
            bra   :optlp
:not_u      cmp   #$E6                   ;'f' -- skip fields
            bne   :not_f
            lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   PARSENUM8
            bcs   :badopt
            lda   PNVAL
            sta   SKIPFLD
            bra   :optlp
:not_f      cmp   #$F3                   ;'s' -- skip chars
            bne   :badopt
            lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   PARSENUM8
            bcs   :badopt
            lda   PNVAL
            sta   SKIPCHR
            bra   :optlp
:badopt     jmp   :usage
:optdone
            lda   WANT_D
            beq   :okdu
            lda   WANT_U
            beq   :okdu
            lda   #<DUERRMSG
            sta   PTR0
            lda   #>DUERRMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

:okdu       lda   ARGC
            sec
            sbc   OPTIND
            sta   NARGS
            cmp   #3
            bcc   :nargsok
:usage      lda   #<USAGE
            sta   PTR0
            lda   #>USAGE
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

:nargsok    lda   NARGS
            bne   :havein
            lda   #FD_STDIN
            sta   SRCFD
            stz   HAVEIN
            lda   #FD_STDOUT
            sta   OUTFD
            stz   HAVEOUT
            jmp   :run

:havein     lda   OPTIND
            sta   ARGIDX
            jsr   GETARG
            lda   #<INPATHBUF
            sta   PTR1
            lda   #>INPATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<IOPARM
            ldx   #>IOPARM
            jsr   SC_OPEN
            bcc   :inok
            jmp   ERROPEN
:inok       lda   IOPARM_REF
            sta   SRCFD
            lda   #1
            sta   HAVEIN
            lda   NARGS
            cmp   #2
            beq   :haveout
            lda   #FD_STDOUT
            sta   OUTFD
            stz   HAVEOUT
            jmp   :run

:haveout    lda   OPTIND
            clc
            adc   #1
            sta   ARGIDX
            jsr   GETARG
            lda   #<OUTPATHBUF
            sta   PTR1
            lda   #>OUTPATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<CRPARM
            ldx   #>CRPARM
            jsr   SC_CREAT           ;ignore error -- see header
            lda   #<OOPARM
            ldx   #>OOPARM
            jsr   SC_OPEN
            bcc   :outok
            jmp   ERROPEN
:outok      lda   OOPARM_REF
            sta   OUTFD
            lda   #1
            sta   HAVEOUT

:run        jsr   RUNUNIQ
            lda   HAVEIN
            beq   :noclosin
            lda   SRCFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
:noclosin   lda   HAVEOUT
            beq   :noclosout
            ldx   OUTFD
            jsr   FCLOSE             ;flush PUTC's buffer, then
                                     ;close -- see header
:noclosout  lda   #0
            jsr   EXIT

*---------------------------------------------------------------
* ERROPEN -- "uniq: cannot open <argv[ARGIDX]>" to fd 2, exit 2.
* Shared by the input-open and output-create/open failure paths.
*---------------------------------------------------------------
ERROPEN     lda   #<CANTOPEN
            sta   PTR0
            lda   #>CANTOPEN
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ARGIDX
            jsr   GETARG             ;PUTS clobbered PTR0
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* RUNUNIQ -- read SRCFD line by line, collapse adjacent-equal
* runs, write survivors to OUTFD per WANT_C/WANT_D/WANT_U.
*---------------------------------------------------------------
RUNUNIQ     stz   BUFPOS
            stz   BUFLEN
            jsr   GETLINE
            bcs   :rudone            ;empty input -- nothing
            jsr   SAVEPREV
            lda   #1
            sta   RUNCNT
            stz   RUNCNT+1
:ruloop     jsr   GETLINE
            bcs   :ruflush
            lda   #<CURBUF
            sta   PTR0
            lda   #>CURBUF
            sta   PTR0+1
            jsr   SKIPCMP
            lda   PTR0
            sta   CMPCUR
            lda   PTR0+1
            sta   CMPCUR+1
            lda   #<PREVBUF
            sta   PTR0
            lda   #>PREVBUF
            sta   PTR0+1
            jsr   SKIPCMP
            lda   PTR0
            sta   PTR1
            lda   PTR0+1
            sta   PTR1+1
            lda   CMPCUR
            sta   PTR0
            lda   CMPCUR+1
            sta   PTR0+1
            jsr   STRCMP
            cmp   #0
            bne   :rudiff
            jsr   BUMPRUN
            bra   :ruloop
:rudiff     jsr   OUTRUN
            jsr   SAVEPREV
            lda   #1
            sta   RUNCNT
            stz   RUNCNT+1
            bra   :ruloop
:ruflush    jsr   OUTRUN
:rudone     rts

            put   uniqcmp.s

            put   uniqio.s

USAGE       asc   "usage: uniq [-cdu] [-f fields] [-s chars] "
            asc   "[input [output]]"
            dfb   $8D,$00
DUERRMSG    asc   "uniq: -d and -u are mutually exclusive"
            dfb   $8D,$00
CANTOPEN    asc   "uniq: cannot open "
            dfb   $00

UNIQOPTS    asc   "cduf:s:"
            dfb   0

IOPARM        dfb   PCOUNT_OPEN
IOPARM_PATH   da    INPATHBUF
IOPARM_IOBF   da    $0000        ;kernel-owned (main memory) --
                                 ;see cp.s's header
IOPARM_REF    dfb   0            ; result: input fd

OOPARM        dfb   PCOUNT_OPEN
OOPARM_PATH   da    OUTPATHBUF
OOPARM_IOBF   da    $0000        ;kernel-owned (main memory)
OOPARM_REF    dfb   0            ; result: output fd

* CREATE parmlist for a named output file. FTYPE_TXT: what a
* shell redirect produces (mli.equ's own words) -- uniq's output
* is a text stream. access/storage_type/dates are liba DRAFT-
* VALUEs, same as cp.s's CRPARM.
CRPARM        dfb   PCOUNT_CREATE
CRPARM_PATH   da    OUTPATHBUF
CRPARM_ACCESS dfb   ACCESS_UNLKD
CRPARM_TYPE   dfb   FTYPE_TXT
CRPARM_AUX    da    0
CRPARM_STORE  dfb   STYP_SEEDLING
CRPARM_CDATE  da    0            ;no clock wired
CRPARM_CTIME  da    0

RPARM       dfb   PCOUNT_READ
RPARM_REF   dfb   0              ; patched from SRCFD
RPARM_BUF   da    CBUF
RPARM_REQ   da    BUFSZ
RPARM_TRANS da    0

CPARM       dfb   PCOUNT_CLOSE
CPARM_REF   dfb   0              ; patched per close

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* uniq's bss -- `dum`/`dend` at the TEXTUAL END, past every
* emitted byte, anchored at LIBA_BSSEND rather than `*` (two
* blocks at `*` are the same bytes)
* (learning:01M0FNC75R7YSFRNS328WHXMHN). 921 bytes that were
* emitted zeros. UNIQOPTS and the five parmlists stay above:
* the option string and the parmlists' constants are real
* initialised data, and `da CBUF` / `da INPATHBUF` resolve into
* this arena perfectly well as forward references.
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - WANT_C/WANT_D/WANT_U/SKIPFLD/SKIPCHR: `stz` in START's
*    opening run.
*  - SK_I/CMPCUR/PNVAL: SK_I is `sta`'d before SKIPCMP's own
*    first read of it (once per skip phase, fields then chars);
*    CMPCUR is `sta`'d right after the CURBUF SKIPCMP call,
*    before :ruloop's own later read of it; PNVAL is `stz`'d as
*    PARSENUM8's first instruction.
*  - NARGS: `sta` before the argument-count test reads it.
*  - SRCFD/OUTFD/HAVEIN/HAVEOUT: written on EVERY path into
*    :run -- the no-args case stores the standard fds, the
*    file cases store the opened ones.
*  - ARGIDX: `sta` on both the input- and output-argument
*    paths, and ERROPEN (its only reader) is reachable only
*    downstream of one of them.
*  - BUFPOS/BUFLEN: `stz` as RUNUNIQ's first two instructions,
*    which is what makes GETBYTE's `pos >= len` refill test a
*    decision rather than an accident.
*  - RUNCNT: `lda #1 / sta RUNCNT / stz RUNCNT+1` before the
*    run loop that reads it.
*  - LINELEN: `stz` as GETLINE's entry.
*  - CNTLEN/PADCNT: written by the count formatter before it
*    reads either; the :nopad arms skip both.
*  - CURBUF: written with its NUL by GETLINE before STRCMP or
*    STRCPY reads it.
*  - PREVBUF: there is NO zero sentinel and no HAVEPREV flag --
*    the "no previous line" case is the `bcs :rudone` on the
*    FIRST GETLINE, which returns without touching PREVBUF at
*    all. Every reader is downstream of SAVEPREV.
*  - CNTBUF: U2DEC always writes at least a digit and the NUL
*    before PUTS scans it.
*  - INPATHBUF/OUTPATHBUF: MKPATH writes chars then the count
*    byte; the MLI reads only count+1.
*  - CBUF: filled by SC_READ, and GETBYTE only indexes below
*    the BUFLEN that same call set.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
SRCFD       ds    1
OUTFD       ds    1
HAVEIN      ds    1
HAVEOUT     ds    1
ARGIDX      ds    1
NARGS       ds    1
WANT_C      ds    1              ;-c  prefix the repeat count
WANT_D      ds    1              ;-d  duplicated runs only
WANT_U      ds    1              ;-u  unique runs only
SKIPFLD     ds    1              ;-f  fields to ignore
SKIPCHR     ds    1              ;-s  further chars to ignore
SK_I        ds    1              ;SKIPCMP's own countdown
CMPCUR      ds    2              ;SKIPCMP(CURBUF)'s own result
PNVAL       ds    1              ;PARSENUM8's own output
RUNCNT      ds    2              ;current run length, saturating
BUFPOS      ds    1
BUFLEN      ds    1
LINELEN     ds    1
CNTLEN      ds    1
PADCNT      ds    1

CURBUF      ds    LINEMAX+1
PREVBUF     ds    LINEMAX+1
CNTBUF      ds    8

INPATHBUF   ds    65
OUTPATHBUF  ds    65
CBUF        ds    BUFSZ
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
