*---------------------------------------------------------------
* unexpand.s -- POSIX unexpand(1): spaces (and backspaces) back
* to tabs.
*
* Usage: unexpand [-a] [-t tablist] [file...]
*
* DEFAULT: only LEADING blanks (a run starting at column 0) are
* reconverted -- the instant a non-blank byte is seen, the REST
* OF THAT LINE is copied through untouched, blank runs and all
* (measured: `unexpand` on "a  b" -- an interior run of 2 spaces
* -- leaves it as two literal spaces; only a run running from
* the very start of the line is a candidate).
*
* -a: EVERY run of two or more blanks that reaches a tab stop is
* replaced, anywhere in the line, not just leading. -t implies
* -a (measured: `unexpand -t4` converts an interior run exactly
* like `unexpand -a -t4` does -- BSD's own man page states this
* too). A run of exactly ONE blank is never converted even if it
* lands exactly on a stop (measured: a single space one column
* before an 8-column stop stays a space) -- there is no length
* saved by turning one byte into one byte.
*
* WHETHER A RUN QUALIFIES AT ALL is decided ONCE, over its WHOLE
* length (byte count from the first blank to the non-blank/CR/
* EOF that ends it) -- NOT per stop crossing. A run of overall
* length < 2 never converts, full stop (the "one byte for one
* byte" case above). A run of length >= 2 converts EVERY stop it
* crosses, even a crossing whose own segment is a single byte:
* measured live, "1234567" (column 7) plus two spaces -- the
* FIRST space alone already reaches column 8, a stop, but the
* RUN's own total length (2) still qualifies it -- becomes "\t "
* (a tab for that lone first space, then a literal space for the
* second, which never reaches a further stop). A REAL BUG lived
* here first: gating each crossing on the count accumulated
* SINCE THE LAST conversion (rather than the run's own total)
* left every run whose first segment was exactly 1 byte
* unconverted, silently, with no diagnostic -- found by this
* exact "1234567" case going red in check-posixutil, not by
* inspection. FLUSHRUN's own header has the fix's full shape.
*
* A run that reaches an early stop but keeps going still
* collapses ONE TAB PER STOP CROSSED, not one tab for the whole
* run (measured: 16 leading spaces from column 2 become two
* tabs, columns 2->8 and 8->16, plus the two leftover spaces
* from 16->18 that never reach column 24 -- those stay literal).
* A run that never reaches a stop at all is flushed byte-for-
* byte, unchanged, when a non-blank, CR, or EOF ends it.
*
* BACKSPACE counts as a member of the current blank run (its
* column effect is -1, never below 0) WITHOUT itself forcing a
* flush -- measured live: "ab<BS><8 spaces>x" (BS backs column 2
* to 1, then the 8 spaces cross column 8 after 7 of them,
* producing ONE tab plus one leftover space before "x") and
* "abcdefgh<BS><8 spaces>x" (BS backs column 8 to 7; the FIRST
* space of the run reaches column 8 with a pending count of only
* 2 -- itself plus the backspace -- so it converts too, then the
* remaining 7 spaces don't reach column 16 and stay literal).
* Both were checked byte-for-byte against this Mac's own
* /usr/bin/unexpand before writing a line of this file; its own
* man page is silent on backspace, so this is measurement, not
* documentation. Because a run can therefore contain backspaces,
* the PENDING RUN IS BUFFERED BY VALUE (PENDBUF), not just
* counted -- a literal flush must reproduce the exact bytes.
*
* COLUMN STATE RESETS AT THE START OF EACH FILE -- measured
* live (unlike expand.s's own column, which does NOT reset
* between files -- see that file's header; the two were measured
* separately and simply differ on this host).
*
* PENDBUF/MAXWIDTH caps: same shape and same 120-column ceiling
* as fold.s/expand.s, sized to the largest gap between two
* explicit -t stops (or a single periodic step).
*
* A file that cannot be opened prints "unexpand: cannot open
* NAME" to stderr and is skipped, same policy as expand.s/
* fold.s; overall exit status is 1 if any operand failed to
* open.
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
            dsk   ../../build/unexpand.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255
MAXWIDTH    equ   120
MAXSTOPS    equ   16
PENDCAP     equ   MAXWIDTH
TABCH       equ   $89
BSCH        equ   $88
BLANKSP     equ   $A0

START       stz   TABCNT
            stz   WANT_A
:optlp0     lda   #<UXOPTS
            ldx   #>UXOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$E1                  ;'a'
            bne   :nota
            lda   #1
            sta   WANT_A
            bra   :optlp
:nota       cmp   #$F4                  ;'t'
            bne   :usageerr
            jsr   TPARSE
            lda   #1
            sta   WANT_A
            bra   :optlp
:usageerr   jmp   USAGEEXIT

:optdone    lda   TABCNT
            bne   :havestops
            lda   #8
            sta   TABSTOPS
            lda   #1
            sta   TABCNT

:havestops  lda   ARGC
            sec
            sbc   OPTIND
            sta   NARGS
            stz   ERRFLAG
            lda   NARGS
            bne   :havefile
            lda   #FD_STDIN
            sta   SRCFD
            jsr   UXFD
            jmp   :donemain

:havefile   lda   OPTIND
            sta   ARGIDX
:looparg    lda   ARGIDX
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :opened
            lda   #<CANTOPEN
            sta   PTR0
            lda   #>CANTOPEN
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ARGIDX
            jsr   GETARG
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   ERRFLAG
            bra   :nextarg

:opened     lda   OPARM_REF
            sta   SRCFD
            jsr   UXFD
            lda   SRCFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE

:nextarg    inc   ARGIDX
            lda   ARGIDX
            cmp   ARGC
            bcc   :looparg

:donemain   lda   ERRFLAG
            jsr   EXIT

*---------------------------------------------------------------
* TPARSE -- same shape as expand.s's own TPARSE (ascending
* stops, comma/blank separated, TABCNT==1 = periodic). Kept as
* an independent copy: the two tools are separate binaries with
* no shared put-module, and the routine is small.
*---------------------------------------------------------------
TPARSE      lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            stz   TABCNT
            ldy   #0
:skipsep    lda   (PTR0),y
            beq   :tpend
            and   #$7F
            cmp   #' '
            beq   :sepch
            cmp   #$2C              ;',' (a bare comma char
                                    ;literal confuses merlin32's
                                    ;operand parser)
            bne   :parsenum
:sepch      iny
            bra   :skipsep
:parsenum   stz   TACC
            stz   THAVE
:numloop    lda   (PTR0),y
            beq   :numdone
            and   #$7F
            cmp   #'0'
            bcc   :numdone
            cmp   #'9'+1
            bcs   :numdone
            and   #$0F
            sta   TDIGIT
            lda   TACC
            cmp   #26
            bcs   :usageerr2
            asl   a
            sta   TTMP
            lda   TACC
            asl   a
            asl   a
            asl   a
            clc
            adc   TTMP
            clc
            adc   TDIGIT
            sta   TACC
            lda   #1
            sta   THAVE
            iny
            bra   :numloop
:numdone    lda   THAVE
            beq   :usageerr2
            lda   TACC
            beq   :usageerr2
            cmp   #MAXWIDTH+1
            bcs   :usageerr2
            ldx   TABCNT
            beq   :store
            cpx   #MAXSTOPS
            bcs   :usageerr2
            lda   TABSTOPS-1,x
            cmp   TACC
            bcs   :usageerr2        ;must be STRICTLY increasing
:store      ldx   TABCNT
            lda   TACC
            sta   TABSTOPS,x
            inc   TABCNT
            bra   :skipsep
:tpend      lda   TABCNT
            beq   :usageerr2
            rts
:usageerr2  jmp   USAGEEXIT

*---------------------------------------------------------------
* USAGEEXIT -- usage banner to stderr, exit 2.
*---------------------------------------------------------------
USAGEEXIT   lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

            put   uxrun.s


*---------------------------------------------------------------
* GETBYTE / REFILL -- buffered input, same shape as fold.s.
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

USAGEMSG    asc   "usage: unexpand [-a] [-t tablist] [file ...]"
            dfb   $8D,$00
CANTOPEN    asc   "unexpand: cannot open "
            dfb   $00
UXOPTS      asc   "at:"
            dfb   0

OPARM       dfb   PCOUNT_OPEN
OPARM_PATH  da    PATHBUF
OPARM_IOBUF da    $0000
OPARM_REF   dfb   0

RPARM       dfb   PCOUNT_READ
RPARM_REF   dfb   0
RPARM_BUF   da    CBUF
RPARM_REQ   da    BUFSZ
RPARM_TRANS da    0

CPARM       dfb   PCOUNT_CLOSE
CPARM_REF   dfb   0

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* unexpand's bss -- `dum`/`dend` off LIBA_BSSEND (docs/STICKY.md
* sec 21). NOTHING ZEROES THIS ARENA:
*  - TABCNT/WANT_A: START's own stz, before option parsing can
*    read either.
*  - TABSTOPS: TPARSE's own stores (or START's default-8 store).
*  - NARGS/ERRFLAG/ARGIDX/SRCFD: written right after option
*    parsing or at :havefile/:opened, before any read.
*  - TACC/THAVE/TDIGIT/TTMP: TPARSE's own stores before its own
*    later reads, every call.
*  - TMPN/TMPR: PERSTOP's own stores before its own later reads.
*  - NEWCOL/IS_VAL/PP_BYTE: each routine's own store before its
*    own later read, every call.
*  - UBYTE: UXFD's own store, right after GETBYTE, before every
*    later classification/output use in the same iteration.
*  - COL/PENDCNT/PASSTHRU: `stz`'d by UXFD itself, first thing,
*    on EVERY call -- per file (this tool DOES reset per file,
*    unlike expand.s -- see this file's header).
*  - RUNSTCOL: `:isblank`'s own store, only on a run's first
*    byte (PENDCNT==0 test), before FLUSHRUN's only read of it.
*  - SEGSTART/RIDX: FLUSHRUN's own stores before its own later
*    reads, every call.
*  - BUFPOS/BUFLEN: same, UXFD's own per-file reset.
*  - PATHBUF: MKPATH writes chars then the count byte.
*  - CBUF: filled by SC_READ, indexed only below BUFLEN.
*  - PENDBUF: filled by PENDPUSH, indexed only below PENDCNT
*    (PENDLIT/FLUSHRUN never read past it).
*---------------------------------------------------------------
            dum   LIBA_BSSEND
TABCNT      ds    1
WANT_A      ds    1
TABSTOPS    ds    MAXSTOPS
NARGS       ds    1
ERRFLAG     ds    1
ARGIDX      ds    1
SRCFD       ds    1
TACC        ds    1
THAVE       ds    1
TDIGIT      ds    1
TTMP        ds    1
TMPN        ds    1
TMPR        ds    1
NEWCOL      ds    1
IS_VAL      ds    1
PP_BYTE     ds    1
UBYTE       ds    1
COL         ds    1
PENDCNT     ds    1
PASSTHRU    ds    1
RUNSTCOL    ds    1
SEGSTART    ds    1
RIDX        ds    1
BUFPOS      ds    1
BUFLEN      ds    1

PATHBUF     ds    65
CBUF        ds    BUFSZ
PENDBUF     ds    PENDCAP
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window (see src/bin/cut.s for the
* -- full note).
            err   */$BF00
            dend
