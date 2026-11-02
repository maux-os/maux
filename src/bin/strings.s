*---------------------------------------------------------------
* strings.s -- print runs of printable characters in a file.
*
* Usage: strings [-a] [-n number] [-t format] [file...]
*
* CONTRACT: a "string" is a run of NUMBER (default 4, -n
* overrides) or more PRINTABLE bytes, terminated by a non-
* printable byte or EOF -- the terminator itself is never
* printed. -a is accepted and does nothing: this build has no
* object-file section table to restrict to, so the whole file
* is always scanned (measured against this host's own BSD
* strings, whose own -a means exactly "scan everything" and
* whose default for a non-Mach-O file is already that).
*
* PRINTABLE, ON THIS MACHINE, IS BOTH CONVENTIONS AT ONCE: plain
* ASCII $20-$7E, OR high-bit maux text $A0-$FE. A binary blob
* has no liba string convention of its own -- SC_READ hands back
* opaque bytes (docs/USERLAND.md, the same posture od.s's own
* HIGH-BIT RULING takes) -- so both ranges count on the way IN.
* On the way OUT every qualifying byte is MAKEHI'd (bit 7 forced
* set) before PUTC, same as od.s's own -c convention: PUTC/
* stdout expect liba's high-bit-set text convention for
* anything meant to display as text, and a plain-ASCII byte
* qualifying under the $20-$7E half of the rule above still
* needs that translation to print correctly as maux text -- a
* raw low-bit byte written straight through would not be text
* this system wrote correctly (measured: check-e2e's own
* comparator flags any stdout byte with bit 7 clear).
*
* -t d/o/x prefixes each string with its byte OFFSET FROM THE
* START OF THE FILE (resets to 0 per file, matched live against
* this host's BSD strings across two operands), in that base, a
* bare number with NO leading zeros and no width padding, then
* one space -- measured live: "-t x" on an offset of 255 prints
* "ff", not "0x00ff". NUMBER itself is capped at 255 (a
* KNOWN_GAPS row) -- the candidate-run buffer this tool streams
* through is one page wide, the same capacity liba's own read-
* chunk buffers use elsewhere in this tree (od.s, head.s), and a
* wider cap would cost a second buffer page for a case nothing
* in this tool's own test corpus needs.
*
* THE STREAMING SHAPE: bytes are buffered only until the run
* reaches NUMBER (a fixed-size RUNBUF, no dynamic growth on this
* machine); once qualified, every further printable byte in the
* SAME run is written straight through -- there is no second
* pass and no unbounded per-string buffer. A run that never
* reaches NUMBER before its terminator is discarded silently, as
* real strings(1) does.
*
* Cannot open FILE: "strings: cannot open NAME" to stderr, the
* file is skipped (not fatal), and the overall exit status is 1
* -- same posture as cat.s/head.s/od.s. Otherwise exit 0. No
* option validation error other than a bad -t argument or a
* non-numeric/out-of-range -n is possible; either is a usage
* error, exit 2.
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
            dsk   ../../build/strings.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255              ;read chunk, see GETBYTE
DEFNUM      equ   4                ;default minimum run length

START       stz   AFLAG
            lda   #DEFNUM
            sta   NUMBER
            stz   TFLAG
            lda   #<STROPTS
            ldx   #>STROPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcc   :na0
            jmp   :optdone
:na0        cmp   #$BF                  ;'?' unrecognised
            bne   :na1
            jmp   :usage
:na1        cmp   #$E1                  ;'a' high-bit
            beq   :aopt
            cmp   #$EE                  ;'n' high-bit
            beq   :nopt
            cmp   #$F4                  ;'t' high-bit
            beq   :topt
            jmp   :usage
:aopt       lda   #1
            sta   AFLAG
            bra   :optlp
:nopt       lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   PARSENUM
            bcc   :na2
            jmp   :usage
:na2        lda   ACCHI
            beq   :na3
            jmp   :usage
:na3        lda   ACCLO
            bne   :na4
            jmp   :usage
:na4        sta   NUMBER
            bra   :optlp
:topt       lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            lda   (PTR0)
            and   #$7F
            cmp   #'d'
            bne   :tcko
            lda   #1
            sta   TFLAG
            bra   :tlen
:tcko       cmp   #'o'
            bne   :tckx
            lda   #2
            sta   TFLAG
            bra   :tlen
:tckx       cmp   #'x'
            beq   :tsetx
            jmp   :usage
:tsetx      lda   #3
            sta   TFLAG
:tlen       ldy   #1
            lda   (PTR0),y
            beq   :na5             ;more than one char given
            jmp   :usage
:na5        jmp   :optlp
:optdone

            lda   ARGC
            sec
            sbc   OPTIND
            sta   NARGS
            stz   ERRFLAG
            lda   NARGS
            bne   :havefile
            lda   #FD_STDIN
            sta   SRCFD
            jsr   STRFILE
            jmp   :done

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
            jsr   STRFILE
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

:usage      lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* STRFILE -- scan SRCFD for qualifying runs and print them.
* RESETS ITS OWN STATE EVERY CALL (a `dum` arena is not zeroed
* between invocations, and a warm respawn hands the next process
* the same bank -- head.s's HEADCOPY documents the same trap).
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
STRFILE     stz   BUFPOS
            stz   BUFLEN
            stz   OFFSET
            stz   OFFSET+1
            stz   RUNLEN
            stz   STREAM
:sflp       jsr   GETBYTE
            bcs   :sfeof
            sta   SF_B
            jsr   ISPRINT
            bcs   :sfnp
            lda   STREAM
            bne   :sfstrm
            ldy   RUNLEN
            bne   :sfbuf
            lda   OFFSET
            sta   RUNSTART
            lda   OFFSET+1
            sta   RUNSTART+1
:sfbuf      ldy   RUNLEN
            lda   SF_B
            sta   RUNBUF,y
            inc   RUNLEN
            lda   RUNLEN
            cmp   NUMBER
            bne   :sfadv
            jsr   SFFLUSH
            lda   #1
            sta   STREAM
            bra   :sfadv
:sfstrm     lda   SF_B
            ora   #$80
            ldx   #FD_STDOUT
            jsr   PUTC
            bra   :sfadv
:sfnp       lda   STREAM
            beq   :sfnstm
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:sfnstm     stz   RUNLEN
            stz   STREAM
:sfadv      inc   OFFSET
            bne   :sflp
            inc   OFFSET+1
            bra   :sflp
:sfeof      lda   STREAM
            beq   :sfdone
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:sfdone     rts

*---------------------------------------------------------------
* SFFLUSH -- the run in RUNBUF[0..NUMBER-1] just qualified:
* print its -t prefix (if TFLAG) using RUNSTART, then the
* buffered bytes themselves. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
SFFLUSH     lda   TFLAG
            beq   :sfnpfx
            lda   RUNSTART
            sta   OFFVAL
            lda   RUNSTART+1
            sta   OFFVAL+1
            lda   TFLAG
            cmp   #1
            beq   :sffd
            cmp   #2
            beq   :sffo
            jsr   PRHEXV
            bra   :sfsep
:sffd       lda   OFFVAL
            sta   U2DEC_VAL
            lda   OFFVAL+1
            sta   U2DEC_VAL+1
            ldx   #FD_STDOUT
            jsr   PRNUM
            bra   :sfsep
:sffo       jsr   PROCTV
:sfsep      lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
:sfnpfx     ldy   #0
:sfflp      lda   RUNBUF,y
            ora   #$80
            ldx   #FD_STDOUT
            jsr   PUTC
            iny
            cpy   NUMBER
            bne   :sfflp
            rts

*---------------------------------------------------------------
* ISPRINT -- IN: A = a raw file byte. OUT: carry CLEAR if A is
* in $20-$7E or $A0-$FE (see file header); SET otherwise.
* CLOBBERS: nothing but the flags.
*---------------------------------------------------------------
ISPRINT     cmp   #$20
            bcc   :ipno
            cmp   #$7F
            bcc   :ipyes
            cmp   #$A0
            bcc   :ipno
            cmp   #$FF
            bcs   :ipno
:ipyes      clc
            rts
:ipno       sec
            rts

*---------------------------------------------------------------
* PARSENUM -- IN: PTR0 = a word (liba text). OUT: ACCLO/ACCHI =
* its value (16-bit); carry CLEAR on success, SET if empty or
* any byte is not a decimal digit. CLOBBERS: A, Y.
*---------------------------------------------------------------
PARSENUM    stz   ACCLO
            stz   ACCHI
            ldy   #0
:pnlp       lda   (PTR0),y
            beq   :pnend
            and   #$7F
            cmp   #'0'
            bcc   :pnbad
            cmp   #'9'+1
            bcs   :pnbad
            and   #$0F
            phy
            jsr   ACCUM10
            ply
            iny
            bne   :pnlp
            bra   :pnbad
:pnend      cpy   #0
            beq   :pnbad
            clc
            rts
:pnbad      sec
            rts

*---------------------------------------------------------------
* ACCUM10 -- ACCLO/ACCHI = ACCLO/ACCHI*10 + A (A=0-9). Same
* shape as head.s/tail.s's own digit accumulator. CLOBBERS: A.
*---------------------------------------------------------------
ACCUM10     sta   AC_DIGIT
            asl   ACCLO
            rol   ACCHI
            lda   ACCLO
            sta   AC_TWOLO
            lda   ACCHI
            sta   AC_TWOHI
            asl   ACCLO
            rol   ACCHI
            asl   ACCLO
            rol   ACCHI
            clc
            lda   ACCLO
            adc   AC_TWOLO
            sta   ACCLO
            lda   ACCHI
            adc   AC_TWOHI
            sta   ACCHI
            clc
            lda   ACCLO
            adc   AC_DIGIT
            sta   ACCLO
            bcc   :nc
            inc   ACCHI
:nc         rts

*---------------------------------------------------------------
* GETBYTE / REFILL -- buffered input, same shape as od.s/head.s.
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

USAGEMSG    asc   "usage: strings [-a] [-n number] [-t d|o|x]"
            asc   " [file...]"
            dfb   $8D,$00
CANTOPEN    asc   "strings: cannot open "
            dfb   $00
STROPTS     asc   "an:t:"
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

            put   strfmt.s

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
* strings' own scalars, `dum`/`dend` off LIBA_BSSEND -- no `ds`
* zeros needed (docs/STICKY.md sec 21): every cell below is
* write-before-read.
*  - AFLAG/NUMBER/TFLAG: START's own opening stores.
*  - ACCLO/ACCHI/AC_*: PARSENUM's own first stores.
*  - NARGS/ERRFLAG: written right after option parsing.
*  - ARGIDX: `sta` at :havefile; unread on the fd-0 path.
*  - SRCFD: written on both the stdin and opened-file paths.
*  - BUFPOS/BUFLEN/OFFSET/RUNLEN/STREAM: `stz`'d by STRFILE
*    itself, first thing, on EVERY call -- see its own header,
*    same reason head.s's HEADCOPY resets per file.
*  - SF_B: STRFILE's own current-byte stash.
*  - RUNSTART: written when RUNLEN transitions 0->1 (a new
*    candidate run begins), read only by SFFLUSH on the very
*    next qualifying byte of THAT SAME run.
*  - OFFVAL/HV_T/HV_DIG/HV_HI: PRHEXV/PROCTV's own scratch,
*    each call's first stores.
*  - PATHBUF/CBUF: MKPATH/SC_READ fill them; read only up to
*    what was written.
*  - RUNBUF: filled index 0..NUMBER-1 by STRFILE, read the same
*    range by SFFLUSH.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
AFLAG       ds    1
NUMBER      ds    1
TFLAG       ds    1
ACCLO       ds    1
ACCHI       ds    1
AC_DIGIT    ds    1
AC_TWOLO    ds    1
AC_TWOHI    ds    1
NARGS       ds    1
ERRFLAG     ds    1
ARGIDX      ds    1
SRCFD       ds    1
BUFPOS      ds    1
BUFLEN      ds    1
OFFSET      ds    2
RUNLEN      ds    1
STREAM      ds    1
SF_B        ds    1
RUNSTART    ds    2
OFFVAL      ds    2
HV_T        ds    2
HV_HI       ds    1
HV_DIG      ds    6

PATHBUF     ds    65
CBUF        ds    BUFSZ
RUNBUF      ds    255
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 is the top of the process window.
            err   */$BF00
            dend
