*---------------------------------------------------------------
* expand.s -- POSIX expand(1): tabs to spaces.
*
* Usage: expand [-t tablist] [file...]
*
* Default tab stops every 8 columns. -t N sets stops every N
* columns (a single number is PERIODIC/infinite, not "one stop
* then stop converting" -- measured live: `expand -t4` on a line
* with several tabs keeps expanding every one of them, each to
* the next multiple of 4, forever). -t list (two or more
* comma/blank-separated increasing numbers) sets EXPLICIT stops;
* past the last one a tab becomes exactly ONE space (measured:
* `expand -t4,10` on five tabs stops using multiples after the
* 10-column stop and falls back to a single space per tab).
*
* BACKSPACE is written to the output AS ITSELF (not consumed)
* and decrements the column by one, never below 0 -- measured
* against this Mac's own /usr/bin/expand (its own man page says
* the same: "Backspace characters are preserved ... and
* decrement the column count").
*
* CR ($8D, this machine's own line terminator -- there is no
* separate LF) always resets the column to 0, satisfying the XCU
* "a <carriage-return> resets the column" rule for free.
*
* COLUMN STATE IS NOT RESET BETWEEN FILES -- measured live: an
* unterminated first file's trailing column carries into the
* second file's very first tab (`expand F1 F2` with F1 ending
* "ab" with no newline and F2 starting with a tab: the tab
* expands from column 2, NOT column 0). This is the OPPOSITE of
* fold.s's per-file reset and of unexpand's own per-file reset
* (see unexpand.s's header) -- each measured separately, this is
* simply what this host's own expand does.
*
* WIDTH CAP: explicit -t stop values are capped at MAXWIDTH
* (120), the same ceiling fold.s uses, for the same reason (a
* single-byte stop table). The running COLUMN itself saturates
* at 250 rather than wrapping a byte -- a defensive cap, not
* something the corpus exercises (test lines are short).
*
* A file that cannot be opened prints "expand: cannot open NAME"
* to stderr and is skipped, same policy as fold.s/cut.s; overall
* exit status is 1 if any operand failed to open.
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
            dsk   ../../build/expand.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255
MAXWIDTH    equ   120
MAXSTOPS    equ   16
TABCH       equ   $89
BSCH        equ   $88
*-- the LOW twins of tab and backspace, which is how they arrive
*-- in a file that came from outside maux (ProDOS semantics).
TABLO       equ   $09
BSLO        equ   $08

START       stz   TABCNT
            lda   #<EXPOPTS
            ldx   #>EXPOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$F4                  ;'t'
            bne   :usageerr
            jsr   TPARSE
            bra   :optlp
:usageerr   jmp   USAGEEXIT

:optdone    lda   TABCNT
            bne   :havestops
            lda   #8
            sta   TABSTOPS
            lda   #1
            sta   TABCNT
:havestops  stz   COL

            lda   ARGC
            sec
            sbc   OPTIND
            sta   NARGS
            stz   ERRFLAG
            lda   NARGS
            bne   :havefile
            lda   #FD_STDIN
            sta   SRCFD
            jsr   EXPFD
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
            jsr   EXPFD
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
* TPARSE -- parse -t's OPTARG into TABSTOPS[0..TABCNT), an
* ascending run of 1-byte stops (1..MAXWIDTH), comma- or
* blank-separated (POSIX allows either). TABCNT==1 means the
* PERIODIC form (a lone number); TABCNT>1 means an explicit LIST
* -- see EXPFD's NEXTSTOP for how the two modes differ past the
* end. A repeated call (more than one -t) restarts the table.
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

*---------------------------------------------------------------
* EXPFD -- expand SRCFD to stdout. Resets per-file read state
* (BUFPOS/BUFLEN) but NOT the running COL -- see this file's
* header: column state spans every operand, unlike fold.s.
*---------------------------------------------------------------
EXPFD       stz   BUFPOS
            stz   BUFLEN
:xloop      jsr   GETBYTE
            bcs   :xdone
            cmp   #$8D
            beq   :xcr
            cmp   #$0D             ;either terminator ends a
            beq   :xcr           ;line -- a foreign file
            cmp   #TABCH
            beq   :xtab
            cmp   #TABLO           ;either polarity is a tab
            beq   :xtab
            cmp   #BSCH
            beq   :xbs
            cmp   #BSLO
            beq   :xbs
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   COL
            cmp   #250
            bcs   :xloop
            inc   COL
            bra   :xloop
:xcr        lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            stz   COL
            bra   :xloop
:xbs        lda   #BSCH
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   COL
            beq   :xloop
            dec   COL
            bra   :xloop
:xtab       jsr   NEXTSTOP          ;-> NEWCOL
:xsploop    lda   COL
            cmp   NEWCOL
            bcs   :xtdone
            lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            inc   COL
            bra   :xsploop
:xtdone     lda   NEWCOL
            sta   COL
            bra   :xloop
:xdone      rts

*---------------------------------------------------------------
* NEXTSTOP -- IN: COL. OUT: NEWCOL = column after a tab from
* COL, per TABCNT's mode (see TPARSE's own header).
*---------------------------------------------------------------
NEXTSTOP    lda   TABCNT
            cmp   #1
            beq   PERSTOP
            ldx   #0
:lloop      cpx   TABCNT
            bcs   :lpast
            lda   TABSTOPS,x
            cmp   COL
            bcc   :lnext
            beq   :lnext
            sta   NEWCOL
            rts
:lnext      inx
            bra   :lloop
:lpast      lda   COL
            clc
            adc   #1
            sta   NEWCOL
            rts

*---------------------------------------------------------------
* PERSTOP -- periodic mode (TABCNT==1): NEWCOL = COL rounded up
* to the next multiple of TABSTOPS[0], strictly greater than
* COL (a value already ON a stop still advances a full step --
* measured: `expand -t4` on a 4-column prefix expands its next
* tab to column 8, not 4).
*---------------------------------------------------------------
PERSTOP     lda   TABSTOPS
            sta   TMPN
            lda   COL
:modlp      cmp   TMPN
            bcc   :modok
            sec
            sbc   TMPN
            bra   :modlp
:modok      sta   TMPR
            lda   TMPN
            sec
            sbc   TMPR
            clc
            adc   COL
            sta   NEWCOL
            rts

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

USAGEMSG    asc   "usage: expand [-t tablist] [file ...]"
            dfb   $8D,$00
CANTOPEN    asc   "expand: cannot open "
            dfb   $00
EXPOPTS     asc   "t:"
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
* expand's bss -- `dum`/`dend` off LIBA_BSSEND (docs/STICKY.md
* sec 21). NOTHING ZEROES THIS ARENA:
*  - TABCNT: START stores it (stz) before TPARSE or the default
*    fallback can be read.
*  - TABSTOPS: TPARSE's own stores (or START's default-8 store),
*    always before NEXTSTOP/PERSTOP read them.
*  - COL: START's own stz, ONCE, before any file is processed --
*    deliberately NOT reset per file (see this file's header).
*  - NARGS/ERRFLAG/ARGIDX/SRCFD: written right after option
*    parsing or at :havefile/:opened, before any read.
*  - TACC/THAVE/TDIGIT/TTMP: TPARSE's own stores before its own
*    later reads, every call.
*  - TMPN/TMPR: PERSTOP's own stores before its own later reads,
*    every call.
*  - NEWCOL: NEXTSTOP's own stores (both paths) before EXPFD
*    reads it back, every call.
*  - BUFPOS/BUFLEN: `stz`'d by EXPFD itself, first thing, on
*    EVERY call -- per file, same reasoning as fold.s's FOLDFD.
*  - PATHBUF: MKPATH writes chars then the count byte.
*  - CBUF: filled by SC_READ, indexed only below BUFLEN.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
TABCNT      ds    1
TABSTOPS    ds    MAXSTOPS
COL         ds    1
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
BUFPOS      ds    1
BUFLEN      ds    1

PATHBUF     ds    65
CBUF        ds    BUFSZ
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window (see src/bin/cut.s for the
* -- full note).
            err   */$BF00
            dend
