*---------------------------------------------------------------
* cut.s -- cut out selected fields of each line of a file.
*
* Usage: cut -b list [-n] [file ...]
*        cut -c list [file ...]
*        cut -f list [-d delim] [-s] [file ...]
*
* Exactly one of -b/-c/-f selects the mode; a second mode flag,
* or none at all, is a usage error (exit 2). LIST is the POSIX
* list syntax: comma-separated numbers and ranges -- N, N-M,
* N-, -M, one-based. LISTPARSE below turns LIST into a small
* set of (lo,hi) ranges; order and duplicates in LIST do not
* matter, since the line itself is scanned once, left to right,
* and each position is tested against the range set in turn --
* so each selected position is emitted exactly once, in line
* order, however the user wrote the list.
*
* 7-BIT ASCII RULING: this machine has no multibyte characters,
* so -b (bytes) and -c (characters) are the SAME operation here
* -- both select COLUMNS. -n ("do not split a multibyte
* character", -b only) is therefore a NO-OP, accepted but
* ignored regardless of which mode it appears with.
*
* -f selects DELIMITER-separated fields, default delimiter TAB
* ($89). -d takes the replacement delimiter as its own single-
* character option-argument -- more or less than one character
* is a usage error. The OUTPUT delimiter is the same byte as the
* input delimiter (this tool has no --output-delimiter).
*
* -s (fields only) SUPPRESSES a line with no delimiter byte at
* all -- no output, not even the line terminator. Without -s,
* such a line is passed through UNCHANGED (verified, BSD cut):
* the selected field list is irrelevant to that decision.
*
* LINES LONGER THAN LINEMAX ($FF) are truncated the same way
* grep.s's GETLINE truncates -- bytes past the limit are dropped
* and scanning resumes at the next CR. A file that fails to open
* prints "cut: cannot open NAME" to stderr and is skipped; the
* overall exit status is 1 if any operand failed to open (and
* not overridden by a usage error), 0 otherwise. A malformed
* LIST or a missing/duplicate mode flag is a usage error, exit
* 2, checked before any file is touched.
*
* '-' AS AN OPERAND MEANS STDIN, checked explicitly below since
* GETOPT itself only treats a bare '-' as an ordinary operand
* (never an option) -- src/liba/getopt.s's own header.
*
* Every output line, including a final line the input left
* unterminated, gets exactly one trailing CR -- cut is a LINE
* tool, the same convention grep.s's TESTLINE documents ("with a
* CR appended, including for a final unterminated line").
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
            dsk   ../../build/cut.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255
LINEMAX     equ   255
MODE_COL    equ   1
MODE_FLD    equ   2
MAXRANGE    equ   16

START       stz   HAVEMODE
            stz   MODE
            stz   WANT_S
            stz   WANT_N
            lda   #$89
            sta   DELIM
            jsr   SETTWIN
            stz   RCOUNT

            lda   #<CUTOPTS
            ldx   #>CUTOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$E2
            bne   :notb
            lda   #MODE_COL
            jsr   SETMODE
            bra   :optlp
:notb       cmp   #$E3
            bne   :notc
            lda   #MODE_COL
            jsr   SETMODE
            bra   :optlp
:notc       cmp   #$E6
            bne   :notf
            lda   #MODE_FLD
            jsr   SETMODE
            bra   :optlp
:notf       cmp   #$E4
            bne   :notd
            jsr   SETDELIM
            bra   :optlp
:notd       cmp   #$F3
            bne   :notseq
            lda   #1
            sta   WANT_S
            bra   :optlp
:notseq     cmp   #$EE
            bne   :usageerr
            lda   #1
            sta   WANT_N
            bra   :optlp
:usageerr   jmp   USAGEEXIT

:optdone    lda   HAVEMODE
            bne   :havem
            jmp   USAGEEXIT

:havem      lda   ARGC
            sec
            sbc   OPTIND
            sta   NARGS
            stz   ERRFLAG
            lda   NARGS
            bne   :havefile
            lda   #FD_STDIN
            sta   SRCFD
            jsr   CUTFD
            jmp   :donemain

:havefile   lda   OPTIND
            sta   ARGIDX
:looparg    lda   ARGIDX
            jsr   GETARG
            ldy   #0
            lda   (PTR0),y
            cmp   #$AD
            bne   :notdash
            iny
            lda   (PTR0),y
            bne   :notdash
            lda   #FD_STDIN
            sta   SRCFD
            jsr   CUTFD
            bra   :nextarg

:notdash    lda   #<PATHBUF
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
            jsr   CUTFD
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
* SETMODE -- IN: A = MODE_COL or MODE_FLD. Claims the exclusive
* mode and tail-calls LISTPARSE on this option's OPTARG.
*---------------------------------------------------------------
SETMODE     pha
            lda   HAVEMODE
            bne   :dup
            lda   #1
            sta   HAVEMODE
            pla
            sta   MODE
            lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jmp   LISTPARSE
:dup        pla
            jmp   USAGEEXIT

*---------------------------------------------------------------
* SETTWIN -- derive DELIM's opposite-polarity twin and seed the
* delimiter this run will EMIT.
*
* A delimiter reaches us from argv in maux's own encoding: `-d:`
* is $BA. The same character in a file staged by a2til, `tip` or
* NuFX is $3A. One `cmp` can only ever see one of them, so cut
* matched nothing and printed every line whole -- which LOOKS
* like the documented no-delimiter rule and is why a substring
* test for `one` passed over a completely broken cut.
*
* So the SPLIT is polarity-blind (both twins end a field) while
* the JOIN follows the file: DELOUT is re-set to the byte as it
* actually appeared, so a low-ASCII line does not come back with
* a high-bit separator wedged between its fields.
*---------------------------------------------------------------
SETTWIN     lda   DELIM
            sta   DELOUT
            eor   #$80
            sta   DELIMTW
            rts

*---------------------------------------------------------------
* SETDELIM -- -d's OPTARG must be exactly one character.
*---------------------------------------------------------------
SETDELIM    lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            ldy   #0
            lda   (PTR0),y
            beq   :baddelim
            sta   DELIM
            jsr   SETTWIN
            iny
            lda   (PTR0),y
            bne   :baddelim
            rts
:baddelim   jmp   USAGEEXIT

*---------------------------------------------------------------
* USAGEEXIT -- print the usage banner to stderr and exit 2.
* Reached by `jmp` from anywhere -- never returns.
*---------------------------------------------------------------
USAGEEXIT   lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

* LISTPARSE parses a POSIX list at PTR0 (NUL-terminated, high-
* bit ASCII) into the RLO/RHI range set SELECTED tests against
* -- both `put` from cutlist.s (see that file's own header),
* split out of this manifest to stay inside `as`'s 16,128-byte
* source window (docs/S9-PLAN.md sec 5 -- the same reason ed.s
* puts edparse.s and sh.s puts shlex.s). Grammar per comma-
* separated token: N | N-M | N- | -M. A missing bound defaults
* per POSIX (1 on the left, LINEMAX on the right); 0 is never a
* valid position; N-M requires N<=M. A malformed token jumps
* straight to USAGEEXIT and never returns.
            put   cutlist.s

*---------------------------------------------------------------
* CUTFD -- read SRCFD line by line, dispatching each line to
* COLOUT (-b/-c) or FLDOUT (-f). Resets BUFPOS/BUFLEN itself,
* once per call (per FILE) -- the `dum` arena is not zeroed and
* a warm respawn hands the next invocation the same bank with
* the last one's CBUF still in it (head.s's own HEADCOPY note).
*---------------------------------------------------------------
CUTFD       stz   BUFPOS
            stz   BUFLEN
:cflp       jsr   GETLINE
            bcs   :cfeof
            lda   MODE
            cmp   #MODE_FLD
            beq   :cffld
            jsr   COLOUT
            bra   :cflp
:cffld      jsr   FLDOUT
            bra   :cflp
:cfeof      rts

*---------------------------------------------------------------
* COLOUT -- print the selected columns of LINEBUF (positions
* 1..LINELEN), then a CR. -b and -c share this: no multibyte
* characters on this machine, so "byte" and "character" are the
* same column.
*---------------------------------------------------------------
COLOUT      stz   COL_Y
:cloop      lda   COL_Y
            cmp   LINELEN
            bcs   :cldone
            clc
            adc   #1
            jsr   SELECTED
            bcc   :clskip
            ldy   COL_Y
            lda   LINEBUF,y
            ldx   #FD_STDOUT
            jsr   PUTC
:clskip     inc   COL_Y
            bra   :cloop
:cldone     lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* FLDOUT -- split LINEBUF on DELIM and print the selected
* fields, joined by DELIM, then a CR. A line with NO delimiter
* byte at all is passed through UNCHANGED (or dropped entirely
* under -s) regardless of which fields were asked for -- the
* measured BSD rule, see this file's header.
*---------------------------------------------------------------
FLDOUT      stz   FY
            stz   SAWDELIM
:dscan      lda   FY
            cmp   LINELEN
            bcs   :dscandn
            ldy   FY
            lda   LINEBUF,y
            cmp   DELIM
            beq   :isdelim
            cmp   DELIMTW
            bne   :dnext
:isdelim    sta   DELOUT             ;join as the file does
            lda   #1
            sta   SAWDELIM
            bra   :dscandn
:dnext      inc   FY
            bra   :dscan
:dscandn    lda   SAWDELIM
            bne   :hasdelim
            lda   WANT_S
            beq   :nosupp
            jmp   :fdone
:nosupp     stz   FY
:rawloop    lda   FY
            cmp   LINELEN
            bcs   :rawdone
            ldy   FY
            lda   LINEBUF,y
            ldx   #FD_STDOUT
            jsr   PUTC
            inc   FY
            bra   :rawloop
:rawdone    lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            bra   :fdone

:hasdelim   lda   #1
            sta   FIELDNUM
            stz   WROTEONE
            stz   FSTART
            stz   FY
:fscan      lda   FY
            cmp   LINELEN
            beq   :fieldend
            ldy   FY
            lda   LINEBUF,y
            cmp   DELIM
            beq   :fieldend
            cmp   DELIMTW
            beq   :fieldend
            inc   FY
            bra   :fscan
:fieldend   lda   FY
            sta   FEND
            lda   FIELDNUM
            jsr   SELECTED
            bcc   :fskip
            lda   WROTEONE
            beq   :fnodelim
            lda   DELOUT
            ldx   #FD_STDOUT
            jsr   PUTC
:fnodelim   jsr   EMITFIELD
            lda   #1
            sta   WROTEONE
:fskip      lda   FEND
            cmp   LINELEN
            beq   :fdonefld
            lda   FEND
            clc
            adc   #1
            sta   FSTART
            sta   FY
            inc   FIELDNUM
            bne   :fcont
            dec   FIELDNUM
:fcont      bra   :fscan
:fdonefld   lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:fdone      rts

*---------------------------------------------------------------
* EMITFIELD -- print LINEBUF[FSTART..FEND), no join byte.
*---------------------------------------------------------------
EMITFIELD   lda   FSTART
            sta   EY
:eloop      lda   EY
            cmp   FEND
            bcs   :edone
            ldy   EY
            lda   LINEBUF,y
            ldx   #FD_STDOUT
            jsr   PUTC
            inc   EY
            bra   :eloop
:edone      rts

*---------------------------------------------------------------
* GETLINE -- next CR-terminated line from SRCFD into LINEBUF,
* same shape as grep.s's own GETLINE: over-long lines truncate
* at LINEMAX, and a final unterminated line is still returned.
* OUT: carry clear = a line is in LINEBUF/LINELEN; carry set =
* EOF with nothing pending.
*---------------------------------------------------------------
GETLINE     stz   LINELEN
:gloop      jsr   GETBYTE
            bcs   :gleof
            cmp   #$8D               ;either terminator -- see
            beq   :glhave            ;wc.s's own note
            cmp   #$0D
            beq   :glhave
            ldy   LINELEN
            cpy   #LINEMAX
            bcs   :gloop
            sta   LINEBUF,y
            inc   LINELEN
            bra   :gloop
:glhave     clc
            rts
:gleof      lda   LINELEN
            beq   :glnone
            clc
            rts
:glnone     sec
            rts

*---------------------------------------------------------------
* GETBYTE / REFILL -- buffered input, same shape as head.s/
* grep.s/wc.s.
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

USAGEMSG    asc   "usage: cut -b list [-n] [file ...]"
            dfb   $8D
            asc   "       cut -c list [file ...]"
            dfb   $8D
            asc   "       cut -f list [-d delim] [-s] "
            asc   "[file ...]"
            dfb   $8D,$00
CANTOPEN    asc   "cut: cannot open "
            dfb   $00
CUTOPTS     asc   "b:c:f:d:sn"
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
* cut's own scalars, `dum`/`dend` off LIBA_BSSEND -- no `ds`
* zeros needed (docs/STICKY.md sec 21): every cell below is
* write-before-read. Trace:
*  - HAVEMODE/MODE/WANT_S/WANT_N/DELIM/RCOUNT: START's opening
*    run stores every one before GETOPT can read them.
*  - RLO/RHI: only ever read by SELECTED for x<RCOUNT, and only
*    APPENDRNG advances RCOUNT, after writing both arrays at
*    that same index -- so nothing is read before it is written,
*    the same reasoning as CUTBM had, without needing a zero
*    loop at all: a warm respawn's stale bytes past the OLD
*    RCOUNT are simply never indexed by the NEW one, since
*    RCOUNT itself is reset to 0 by START first.
*  - NARGS/ERRFLAG/ARGIDX: written right after option parsing
*    (NARGS,ERRFLAG) or at :havefile (ARGIDX), before any read.
*  - SRCFD: written on both the stdin-operand and opened-file
*    paths before CUTFD's first GETBYTE.
*  - BUFPOS/BUFLEN: `stz`'d by CUTFD itself, first thing, on
*    EVERY call -- per FILE, same reasoning as RCOUNT above.
*  - LINELEN: `stz`'d by GETLINE, first thing, every call.
*  - NLO/NHI/HAVEN: `stz`'d at the top of LISTPARSE's :tok loop
*    (index 0) and again right after the '-' is seen (index 1),
*    each before its own digit loop can accumulate into it.
*  - ACDIG/ACT2LO/ACT2HI: ACCUM stores each before its own
*    later read.
*  - SEL_POS: SELECTED's own first store.
*  - COL_Y: `stz` at the top of COLOUT, every call.
*  - FY/SAWDELIM/FIELDNUM/WROTEONE/FSTART/FEND: `stz`'d (or
*    `sta`'d, FEND at :fieldend) at the top of FLDOUT/its own
*    scan, before any later read; FEND is written at :fieldend
*    before EMITFIELD or the :fskip comparison ever reads it.
*  - EY: EMITFIELD's own first store.
*  - PATHBUF: MKPATH writes chars then the count byte.
*  - CBUF: filled by SC_READ, indexed only below BUFLEN.
*  - LINEBUF: filled by GETLINE, indexed only below LINELEN
*    (COLOUT/FLDOUT never read past it).
*---------------------------------------------------------------
            dum   LIBA_BSSEND
HAVEMODE    ds    1
MODE        ds    1
WANT_S      ds    1
WANT_N      ds    1
DELIM       ds    1
DELIMTW     ds    1
DELOUT      ds    1
RCOUNT      ds    1
RLO         ds    MAXRANGE
RHI         ds    MAXRANGE
NARGS       ds    1
ERRFLAG     ds    1
ARGIDX      ds    1
SRCFD       ds    1
BUFPOS      ds    1
BUFLEN      ds    1
LINELEN     ds    1
NLO         ds    2
NHI         ds    2
HAVEN       ds    2
ACDIG       ds    1
ACT2LO      ds    1
ACT2HI      ds    1
SEL_POS     ds    1
COL_Y       ds    1
FY          ds    1
SAWDELIM    ds    1
FIELDNUM    ds    1
WROTEONE    ds    1
FSTART      ds    1
FEND        ds    1
EY          ds    1

PATHBUF     ds    65
CBUF        ds    BUFSZ
LINEBUF     ds    LINEMAX+1
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 is the top of the process window (see src/bin/ed.s
* -- and head.s for the full note).
            err   */$BF00
            dend
