*---------------------------------------------------------------
* nl.s -- POSIX nl(1): line numbering with logical pages.
*
* Usage: nl [-b type] [-f type] [-h type] [-d delim] [-i incr]
*           [-n format] [-p] [-s sep] [-v startnum] [-w width]
*           [file]
*
* At most ONE file operand (stdin if none) -- the XCU synopsis
* itself only ever shows one, unlike most of this tree's other
* filters.
*
* LOGICAL PAGES. A line consisting of EXACTLY the delimiter
* string repeated three/two/one times (\:\:\: / \:\: / \:, the
* default two-character delimiter is backslash+colon, changed by
* -d) switches the current section to header/body/footer and is
* itself CONSUMED -- never printed, never numbered. Measured
* live against this Mac's own /usr/bin/nl before writing a byte:
* with NO delimiter lines at all, every line is BODY from the
* start (matches the plain 3-line default-numbering case).
*
* NUMBERING RESET. By default, ANY delimiter line -- header,
* body, OR footer, not just header -- resets the counter to the
* -v start value; -p suppresses every one of those resets and
* lets the counter run on. Measured live (nl's own XCU prose
* only says "the start of each logical page", which reads as
* header-only; the host resets on body and footer delimiters
* too, and this file follows the host, since check-posixutil's
* own suite is measured against it).
*
* -b/-h/-f TYPE selects which lines of the body/header/footer
* get a number: a = all, t = only non-empty (BODY's default),
* n = none (HEADER's and FOOTER's default), pBRE = only the
* lines the basic regular expression BRE matches (SHIPPED
* 2026-10-08, docs/POSIX-REGEXLINK.md). The `p` is the type
* letter and the BRE follows it with no separator (`-b pfoo`
* and `-bpfoo` are the same). Each of the three sections keeps
* its OWN pattern (NLPAT, indexed like TYPEARR). The match is
* the house engine (liba regex.s + regex2.s, the one grep/sed
* link) run against a 7-bit-normalised COPY of the line (MBUF:
* bit 7 SET, because that is the polarity the engine's own
* metacharacters are written in -- grepbody.s NORMLINE's rule),
* so a ProDOS low-ASCII file and a maux high-bit one select the
* same lines. The line printed is the original. An EMPTY BRE
* (`-b p`) matches every line, GNU's reading; BSD refuses it and
* the XCU text is silent. A malformed BRE has no compile step
* to refuse it (regex.s's own rule: a bad RE is a safe
* no-match), so it numbers nothing rather than exiting 2.
*
* -l num (SHIPPED 2026-09-17): under a `-b a`/`-h a`/`-f a`
* section, a run of consecutive BLANK lines counts every `num`th
* one -- the others print unnumbered, same as an ordinary
* non-matching line under type `t`. Verified live against this
* Mac's own nl (`printf 'a\n\n\n\n\nb\n\n\nc\n' | nl -ba -l 2`):
* within each run the numbers land on the run's 2nd, 4th, ...
* blank line, never the 1st/3rd, and the run resets to 0 the
* moment a non-blank line appears. BLANKCNT (nlfmt.s's PRINTONE)
* is that per-run counter; num defaults to 1, which is every
* line numbered -- today's unmodified behavior.
*
* WHAT THE SPEC LEAVES OPEN, decided BSD's way (this Mac's own
* nl, the oracle everything above was measured against): an
* unnumbered line prints the blank field THEN the separator (GNU
* prints the separator's width in spaces), and a delimiter line
* produces NO output (GNU prints an empty line). Both are
* spec-authored rows, since the two hosts disagree.
*
* NUMBERS ARE 16-BIT (this machine has no wider integer path
* pre-built for a tool this size) -- the ceiling is 65535; -v/-i
* arithmetic past it wraps silently, undocumented further than
* this comment, since no test in this tree's corpus approaches
* it.
*
* -n FORMAT: ln (left justified, no leading zeros), rn (right
* justified, no leading zeros -- the DEFAULT, measured), rz
* (right justified, zero-padded to -w's width). -w WIDTH default
* 6, capped locally at NLMAXW (20) -- POSIX does not bound it,
* this tree does, the same spirit as fold.s's own WIDTH cap.
* -s SEP default a single tab, copied verbatim (not limited to
* one character -- measured: `-s ': '` prints a 2-character
* separator). An UNNUMBERED line still prints WIDTH blank
* columns and the separator, just no digits (measured).
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
            dsk   ../../build/nl.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/regex.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255
LBUFCAP     equ   200
SEPCAP      equ   16
NLMAXW      equ   20
TABCH       equ   $89
TY_A        equ   0
TY_T        equ   1
TY_N        equ   2
TY_P        equ   3                 ;pBRE: see NLPAT

START       stz   WANT_P
            lda   #TY_T
            sta   BTYPE
            lda   #TY_N
            sta   HTYPE
            sta   FTYPE
            lda   #$DC              ;default delim char 1: '\'
            sta   DELIM1
            lda   #$BA              ;default delim char 2: ':'
            sta   DELIM2
            lda   #1
            sta   INCRMAG
            stz   INCRNEG
            lda   #1
            sta   STARTLO
            stz   STARTHI
            lda   #6
            sta   WIDTH
            lda   #1
            sta   NFORMAT           ;default rn
            lda   #TABCH
            sta   SEPBUF
            stz   SEPBUF+1
            lda   #1
            sta   NLNUM
            stz   BLANKCNT

            lda   #<NLOPTS
            ldx   #>NLOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcc   :havopt
            jmp   :optdone
:havopt     cmp   #$E2              ;'b'
            bne   :notb
            jsr   SETPTRO
            ldx   #1                ;section 1 = body
            jsr   PARSETY
            sta   BTYPE
            jmp   :optlp
:notb       cmp   #$E4              ;'d'
            bne   :notd
            jsr   PARSED
            jmp   :optlp
:notd       cmp   #$E6              ;'f'
            bne   :notf
            jsr   SETPTRO
            ldx   #2                ;section 2 = footer
            jsr   PARSETY
            sta   FTYPE
            jmp   :optlp
:notf       cmp   #$E8              ;'h'
            bne   :noth
            jsr   SETPTRO
            ldx   #0                ;section 0 = header
            jsr   PARSETY
            sta   HTYPE
            jmp   :optlp
:noth       cmp   #$E9              ;'i'
            bne   :noti
            jsr   PARSEI
            jmp   :optlp
:noti       cmp   #$EC              ;'l'
            bne   :notl
            jsr   PARSEL
            jmp   :optlp
:notl       cmp   #$EE              ;'n'
            bne   :notn
            jsr   PARSEN
            jmp   :optlp
:notn       cmp   #$F0              ;'p'
            bne   :notp
            lda   #1
            sta   WANT_P
            jmp   :optlp
:notp       cmp   #$F3              ;'s'
            bne   :nots
            jsr   PARSES
            jmp   :optlp
:nots       cmp   #$F6              ;'v'
            bne   :notv
            jsr   PARSEV
            jmp   :optlp
:notv       cmp   #$F7              ;'w'
            bne   :usageerr
            jsr   PARSEW2
            jmp   :optlp
:usageerr   jmp   USAGEEXIT

:optdone    lda   ARGC
            sec
            sbc   OPTIND
            sta   NARGS
            cmp   #2
            bcc   :nargsok
            jmp   USAGEEXIT         ;bcs's own range can't reach
                                    ;USAGEEXIT this far down
:nargsok    jsr   BUILDMK
            lda   HTYPE
            sta   TYPEARR
            lda   BTYPE
            sta   TYPEARR+1
            lda   FTYPE
            sta   TYPEARR+2
            lda   STARTLO
            sta   CURLO
            lda   STARTHI
            sta   CURHI
            lda   #1
            sta   CURSEC            ;no delimiter yet = body
            stz   ERRFLAG
            stz   EOFFLAG

            lda   NARGS
            bne   :havefile
            lda   #FD_STDIN
            sta   SRCFD
            jsr   NLRUN
            jmp   :donemain

:havefile   lda   OPTIND
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
            lda   OPTIND
            jsr   GETARG
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            jsr   EXIT

:opened     lda   OPARM_REF
            sta   SRCFD
            jsr   NLRUN
            lda   SRCFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE

:donemain   lda   ERRFLAG
            jsr   EXIT
:usageerr2  jmp   USAGEEXIT


            put   nlopt.s
            put   nlfmt.s

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

USAGEMSG    asc   "usage: nl [-b type] [-f type] [-h type] "
            asc   "[-d delim] [-i incr] [-n format] [-p] "
            asc   "[-s sep] [-v start] [-w width] [file]"
            dfb   $8D,$00
CANTOPEN    asc   "nl: cannot open "
            dfb   $00
NLOPTS      asc   "b:d:f:h:i:l:n:ps:v:w:"
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
            put   ../liba/num.s
            put   ../liba/regex.s
            put   ../liba/regex2.s
            put   ../liba/libabss.s
            put   ../liba/regexbss.s

*---------------------------------------------------------------
* nl's bss -- `dum`/`dend` off LIBA_BSSEND (docs/STICKY.md sec
* 21). NOTHING ZEROES THIS ARENA:
*  - WANT_P/BTYPE/HTYPE/FTYPE/DELIM1/DELIM2/INCRMAG/INCRNEG/
*    STARTLO/STARTHI/WIDTH/NFORMAT/SEPBUF: START's own stores,
*    all before option parsing (or PRINTONE/NLRUN) can read any
*    of them.
*  - NLNUM: `lda #1 / sta` in START's opening run (default:
*    every blank line numbered, i.e. -l's old absence).
*    PARSEL overwrites it, same as INCRMAG/PARSEI.
*  - BLANKCNT: `stz` in START's opening run; PRINTONE (nlfmt.s)
*    is the only later writer, always before its own next read.
*  - IACC/IHAVE/IDIGIT/ITMP: PARSEI's own stores before its own
*    later reads, every call.
*  - VACC/VHAVE/AC_DIG/AC_T2LO/AC_T2HI: PARSEV/ACCUM16's own
*    stores before their own later reads, every call.
*  - WACC/WDIGIT/WTMP: PARSEW2's own stores before its own later
*    reads, every call.
*  - TYPEARR/HDRBUF/BODYBUF/FOOTBUF: written once by :optdone/
*    BUILDMK before NLRUN's first line.
*  - CURLO/CURHI/CURSEC/ERRFLAG/EOFFLAG: written at :optdone,
*    before NLRUN runs; RESETNUM/ADVANCE/READLINE update them
*    from then on, always writing before the next read.
*  - NARGS/SRCFD: written right after option parsing or at
*    :havefile/:opened, before any read.
*  - DIGLEN/PADN/PADCH: PRINTNUM/PRINTBLANK's own stores before
*    their own later reads, every call.
*  - ELIDX: EMITLINE's own stz, first thing, every call.
*  - NLPAT: PARSETY stores a section's slot, and NLMATCH reads
*    only the slot of a section whose TYPEARR entry is TY_P --
*    which PARSETY itself returned in the same call.
*  - MBUF: NLMATCH writes it whole (incl. the NUL) before
*    RE_MATCH reads it.
*  - LLEN/LBUF: READLINE's own stz/fill, first thing, every
*    call -- indexed only below LLEN thereafter.
*  - BUFPOS/BUFLEN: `stz`'d by NLRUN itself before the first
*    READLINE (this tool opens at most one fd, so no per-file
*    reset loop is needed the way fold.s/expand.s have one).
*  - PATHBUF: MKPATH writes chars then the count byte.
*  - CBUF: filled by SC_READ, indexed only below BUFLEN.
*---------------------------------------------------------------
            dum   REGEX_BSSEND
WANT_P      ds    1
BTYPE       ds    1
HTYPE       ds    1
FTYPE       ds    1
DELIM1      ds    1
DELIM2      ds    1
INCRMAG     ds    1
INCRNEG     ds    1
STARTLO     ds    1
STARTHI     ds    1
WIDTH       ds    1
NFORMAT     ds    1
SEPBUF      ds    SEPCAP
TYPEARR     ds    3
HDRBUF      ds    6
BODYBUF     ds    4
FOOTBUF     ds    2
CURLO       ds    1
CURHI       ds    1
CURSEC      ds    1
ERRFLAG     ds    1
EOFFLAG     ds    1
NARGS       ds    1
SRCFD       ds    1
NLNUM       ds    1              ;-l: blank lines counted as one
BLANKCNT    ds    1              ;PRINTONE's per-run counter
NLPAT       ds    6              ;pBRE ptr per section, in
                                 ;TYPEARR's order; into argv,
                                 ;set only by PARSETY
IACC        ds    1
IHAVE       ds    1
IDIGIT      ds    1
ITMP        ds    1
VACC        ds    2
VHAVE       ds    1
AC_DIG      ds    1
AC_T2LO     ds    1
AC_T2HI     ds    1
WACC        ds    1
WDIGIT      ds    1
WTMP        ds    1
DIGLEN      ds    1
PADN        ds    1
PADCH       ds    1
ELIDX       ds    1
LLEN        ds    1
BUFPOS      ds    1
BUFLEN      ds    1

PATHBUF     ds    65
CBUF        ds    BUFSZ
LBUF        ds    LBUFCAP
MBUF        ds    LBUFCAP+1      ;NLMATCH's bit-7-set copy + NUL
DIGBUF      ds    8
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window (see src/bin/cut.s for the
* -- full note).
            err   */$BF00
            dend
