*---------------------------------------------------------------
* head.s -- print the first N lines of each file, or of fd 0.
*
* Usage: head [-n N | -N] [file ...]
*
* -n N is the POSIX spelling; the bare -N form is the historical
* one -- same accumulator, same NLINES effective count, same
* clustering convention as tail.s's own -n/-N pair (this file's
* option loop is copied from it almost verbatim). Default N=10.
*
* MULTIPLE FILES: with more than one operand, each file's output
* is preceded by a "==> NAME <==" header, blank-line-separated
* from the file before it (measured, BSD /usr/bin/head). Exactly
* one operand (or none -- fd 0) never gets a header. A file that
* fails to open prints "head: cannot open NAME" to stderr and is
* skipped -- no header, no blank line charged against it -- same
* policy as cat.s/tail.s, and the overall exit status is 1 if
* any file failed to open, 0 otherwise.
*
* STREAMING PREFIX COPY, NOT A LINE READER: unlike tail.s (which
* must hold candidate lines in a ring because it cannot know
* which ones are "last" until EOF), head knows the moment it has
* copied its Nth line terminator that it is done -- there is
* nothing to buffer. COPYN below copies bytes through untouched,
* counting CR ($8D) terminators, and stops at N of them or EOF,
* whichever comes first. A final unterminated line is therefore
* copied AS IS, with no synthesized trailing CR -- verified
* against BSD head, which does the same (a file with no trailing
* newline prints its last line bare).
*
* N is a plain 16-bit counter, not a ring-sized cap: head holds
* no per-line storage, so there is no MAXLINES-style capacity to
* protect the way tail's ring buffer needs one.
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
            dsk   ../../build/head.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255              ;read chunk -- see GETBYTE
DEFN        equ   10               ;default N

START       lda   #DEFN
            sta   NLINESLO
            stz   NLINESHI
            stz   HAVEOPT
            stz   WANT_C
            stz   ACCLO
            stz   ACCHI

            lda   #<HEADOPTS
            ldx   #>HEADOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$BF                  ;'?' unrecognised
            beq   :usage
            cmp   #$EE                  ;'n': the POSIX spelling
            beq   :nopt                 ;(-n N), count as OPTARG
*-- -c N counts BYTES where -n counts lines, and that is the
*-- only difference: the number is parsed by the same digits
*-- loop and the copy loop just decrements on every byte instead
*-- of on every CR. The two are mutually exclusive in practice
*-- (POSIX specifies them in separate synopsis forms); the last
*-- one given wins here rather than being diagnosed, which is
*-- what the host does too.
            cmp   #$E3                  ;'c' byte count
            bne   :notc
            lda   #1
            sta   WANT_C
            lda   #$EE                  ;-n's own parse follows;
            bra   :nopt                 ;:nopt stores A as the
                                        ;"an option was given"
                                        ;flag, so it must be
                                        ;non-zero
:notc
            sta   HAVEOPT
            and   #$0F                  ;hi-bit digit -> 0-9
            jsr   ACCUM10
            bra   :optlp
*-- -n N: same accumulator, digits from OPTARG instead of the
*-- cluster; bare -N stays. A non-digit anywhere in N is usage,
*-- never a silent partial parse (tail.s's own rule).
:nopt       sta   HAVEOPT
            lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            ldy   #0
:ndig       lda   (PTR0),y
            beq   :nde
            and   #$7F
            cmp   #'0'
            bcc   :usage
            cmp   #'9'+1
            bcs   :usage
            and   #$0F
            phy
            jsr   ACCUM10
            ply
            iny
            bne   :ndig
:nde        cpy   #0
            beq   :usage                ;-n '' -- an empty count
            bra   :optlp
:usage      lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

:optdone    lda   HAVEOPT
            beq   :ncheck                ;no -N: keep DEFN
            lda   ACCLO
            sta   NLINESLO
            lda   ACCHI
            sta   NLINESHI

:ncheck     lda   ARGC
            sec
            sbc   OPTIND
            sta   NARGS
            stz   ERRFLAG
            stz   FIRSTPRT

            lda   NARGS
            bne   :havefile
            ; no FILE operands: copy fd 0, never a header
            lda   #FD_STDIN
            sta   SRCFD
            jsr   HEADCOPY
            jmp   :done

:havefile   lda   #0
            sta   MULTI
            lda   NARGS
            cmp   #2
            bcc   :haveml
            lda   #1
            sta   MULTI
:haveml     lda   OPTIND
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
            jsr   GETARG                ;PUTS clobbered PTR0
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
            lda   MULTI
            beq   :nohdr
            lda   FIRSTPRT
            beq   :hdrgo
            lda   #$8D                  ;blank line before every
            ldx   #FD_STDOUT            ;header but the first
            jsr   PUTC
:hdrgo      lda   #<HDRLEAD
            sta   PTR0
            lda   #>HDRLEAD
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   ARGIDX
            jsr   GETARG                ;PUTS clobbered PTR0
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #<HDRTAIL
            sta   PTR0
            lda   #>HDRTAIL
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #1
            sta   FIRSTPRT
:nohdr      jsr   HEADCOPY
            lda   SRCFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE

:nextarg    inc   ARGIDX
            lda   ARGIDX
            cmp   ARGC
            bcs   :done
            jmp   :looparg

:done       lda   ERRFLAG
            jsr   EXIT

*---------------------------------------------------------------
* ACCUM10 -- ACCLO/ACCHI = ACCLO/ACCHI*10 + A (A=0-9), the
* decimal-digit accumulator behind both option forms (tail.s's
* MUL10ADD, same shape, different target cells). CLOBBERS: A.
*---------------------------------------------------------------
ACCUM10     sta   AC_DIGIT
            asl   ACCLO
            rol   ACCHI                 ;ACC = old*2
            lda   ACCLO
            sta   AC_TWOLO
            lda   ACCHI
            sta   AC_TWOHI
            asl   ACCLO
            rol   ACCHI                 ;ACC = old*4
            asl   ACCLO
            rol   ACCHI                 ;ACC = old*8
            clc
            lda   ACCLO
            adc   AC_TWOLO
            sta   ACCLO
            lda   ACCHI
            adc   AC_TWOHI
            sta   ACCHI                 ;ACC = old*10
            clc
            lda   ACCLO
            adc   AC_DIGIT
            sta   ACCLO
            bcc   :nc
            inc   ACCHI
:nc         rts

*---------------------------------------------------------------
* HEADCOPY -- copy up to NLINESLO/HI lines from SRCFD to stdout,
* stopping at the Nth CR ($8D) or EOF, whichever comes first. No
* per-line storage: every byte read is written straight through,
* so an unterminated final line reaches stdout exactly as it
* arrived. CLOBBERS: A, X, Y.
*
* RESETS BUFPOS/BUFLEN ITSELF, ONE CALL PER FILE (a `dum` arena
* is not zeroed, and a warm respawn hands the NEXT invocation
* the SAME bank with the LAST invocation's CBUF still in it) --
* measured red on check-e2e's first run: -3 on a 12-line file
* buffers the whole file in one REFILL, prints 3 lines and
* leaves 9 UNCONSUMED in CBUF, and the next HEADCOPY call (a
* different file, or the very next process to warm-respawn into
* this bank) saw BUFPOS < BUFLEN and served those stale bytes
* before ever reading its own SRCFD. tail.s resets at its own
* :run for the same reason; here that reset has to happen PER
* FILE, since one invocation's multi-file loop calls this more
* than once.
*---------------------------------------------------------------
HEADCOPY    stz   BUFPOS
            stz   BUFLEN
            lda   NLINESLO
            sta   REMAINLO
            lda   NLINESHI
            sta   REMAINHI
:cpylp      lda   REMAINLO
            ora   REMAINHI
            beq   :cpydone
            jsr   GETBYTE
            bcs   :cpydone               ;EOF
            sta   BYTETMP
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   WANT_C
            bne   :dec1                 ;-c: every byte counts
*-- EITHER TERMINATOR counts as a line -- see wc.s's own note.
            lda   BYTETMP
            cmp   #$8D
            beq   :dec1
            cmp   #$0D
            bne   :cpylp
:dec1       lda   REMAINLO
            bne   :declo
            dec   REMAINHI
:declo      dec   REMAINLO
            bra   :cpylp
:cpydone    rts

*---------------------------------------------------------------
* GETBYTE / REFILL -- buffered input, same shape as tail.s/wc.s.
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

USAGEMSG    asc   "usage: head [-n N | -N] [file ...]"
            dfb   $8D,$00
CANTOPEN    asc   "head: cannot open "
            dfb   $00
HDRLEAD     asc   "==> "
            dfb   $00
HDRTAIL     asc   " <=="
            dfb   $8D,$00
HEADOPTS    asc   "0123456789n:c:"
            dfb   0

OPARM       dfb   OPEN_RO
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
* head's own scalars, `dum`/`dend` off LIBA_BSSEND -- no `ds`
* zeros needed (docs/STICKY.md sec 21): every cell below is
* write-before-read. Trace:
*  - NLINESLO/HI: START's first two stores (default N).
*  - HAVEOPT/ACCLO/ACCHI: `stz`'d in the same opening run.
*  - NARGS/ERRFLAG/FIRSTPRT: written right after option parsing,
*    before anything reads them.
*  - MULTI: written at :havefile before the arg loop, which is
*    the only reader.
*  - ARGIDX: `sta` at :haveml; never read on the fd-0 path.
*  - SRCFD: written on both the stdin and opened-file paths.
*  - AC_DIGIT/AC_TWOLO/AC_TWOHI: ACCUM10 stores each before its
*    own later read.
*  - REMAINLO/HI: HEADCOPY's own first two stores, every call.
*  - BYTETMP: stored right before the PUTC that is its only
*    reader.
*  - BUFPOS/BUFLEN: `stz`'d by HEADCOPY itself, first thing, on
*    EVERY call -- see HEADCOPY's own header for why a per-file
*    reset is load-bearing here (a leftover unconsumed tail of
*    one file's CBUF must never feed the next file, or the next
*    process to warm-respawn into this bank).
*  - PATHBUF: MKPATH writes chars then the count byte.
*  - CBUF: filled by SC_READ, indexed only below BUFLEN.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
WANT_C      ds    1                 ;-c: N is BYTES, not lines
NLINESLO    ds    1                 ;effective N, 16-bit
NLINESHI    ds    1
HAVEOPT     ds    1
ACCLO       ds    1                 ;-N/-n accum., see ACCUM10
ACCHI       ds    1
AC_DIGIT    ds    1
AC_TWOLO    ds    1
AC_TWOHI    ds    1
NARGS       ds    1
ERRFLAG     ds    1
FIRSTPRT    ds    1
MULTI       ds    1
ARGIDX      ds    1
SRCFD       ds    1
REMAINLO    ds    1
REMAINHI    ds    1
BYTETMP     ds    1
BUFPOS      ds    1
BUFLEN      ds    1

PATHBUF     ds    65
CBUF        ds    BUFSZ
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 is the top of the process window (see src/bin/ed.s
* -- and tail.s for the full note).
            err   */$BF00
            dend
