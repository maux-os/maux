*---------------------------------------------------------------
* csplit.s -- split a file into pieces at context lines.
*
* Usage: csplit [-ks] [-f prefix] [-n number] file arg...
*
* Each ARG names where a piece boundary falls, processed in
* order, current position starting at line 1:
*   NUMBER        -- boundary right before that (1-based) line
*                    (NUMBER == the current line makes an EMPTY
*                    piece, valid; NUMBER less than it is the
*                    "line number out of range" error below).
*   /bre/[+-off]  -- search forward for the next line matching
*                    bre; the boundary falls off lines after it
*                    (off defaults to 0). The matched-through
*                    span becomes a real piece file.
*   %bre%[+-off]  -- same search, but the span is DISCARDED --
*                    no piece file for it (SKIP, house's own
*                    shorthand for POSIX's "does not create a
*                    file for the selected section").
*   {n}           -- repeat the PRECEDING /bre/ or %bre/ arg n
*                    MORE times (same pattern AND offset), each
*                    a fresh forward search from wherever the
*                    last one left off. `{*}` (repeat until no
*                    more match) is a KNOWN GAP -- cheap, not
*                    special-cased: the digit parser below
*                    requires a decimal number and refuses '*'
*                    as a usage error, same as any other non-
*                    digit.
* Whatever remains after the last ARG becomes one final piece
* (nothing, if the last ARG already consumed to EOF).
*
* Pieces are named PREFIX (`-f`, default "xx") + a zero-padded
* decimal counter (`-n` digits, default 2) -- "xx00","xx01",...
* -- unlike split.s's letter odometer, matching every host
* csplit. Each piece's byte count is written to stdout, one
* line, right after it closes, unless `-s`. `-k` keeps whatever
* pieces exist so far when a later ARG fails; without it every
* piece this invocation created (the partial one included) is
* destroyed and the run exits 1.
*
* ERRORS (POSIX csplit.html): a /bre/ or %bre/ that never
* matches before EOF, or a NUMBER strictly LESS than the current
* line, are the two ways an ARG can fail; both take the -k/
* cleanup path above.
*
* OFFSET is honored only when POSITIVE (0 or more extra lines
* copied/discarded past the match before cutting) -- a KNOWN
* LIMITATION: a NEGATIVE offset would need to un-write lines
* already streamed into the current piece, which needs a multi-
* line lookback buffer this machine's small per-process window
* does not have room for. A negative offset is accepted
* syntactically and treated as 0.
*
* BRE DELIMITER: the first occurrence of the SAME delimiter
* character ends the pattern -- no `\/`/`\%` escape scanning (a
* v1 simplification; no fixture needs an escaped delimiter).
*
* Links the house BRE engine exactly as grep.s does (regex.s/
* regex2.s, REGEX_BSSEND anchoring) -- MANDATORY and fixed, the
* same as ed.s/ex.s/sed.s/more.s/grep.s, so this unit is pinned
* in check_dialect.py's AS_WINDOW_OVER for the identical reason
* grep.s already is (see that set's own comment).
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
            dsk   ../../build/csplit.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/regex.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255
LINEMAX     equ   255
DEFDIG      equ   2                ;-n default
NAMECAP     equ   15

START       stz   WANTK
            stz   WANTS
            stz   HAVEPFX
            lda   #DEFDIG
            sta   NDIG
            lda   #<CSOPTS
            ldx   #>CSOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcc   :haveopt
            jmp   :optdone
:haveopt    cmp   #$EB                   ;'k'
            bne   :notk
            jmp   :kopt
:notk       cmp   #$F3                   ;'s'
            bne   :nots
            jmp   :sopt
:nots       cmp   #$E6                   ;'f'
            bne   :notf
            jmp   :fopt
:notf       cmp   #$EE                   ;'n'
            bne   :notn
            jmp   :nopt
:notn       jmp   USAGEEXIT
:kopt       lda   #1
            sta   WANTK
            jmp   :optlp
:sopt       lda   #1
            sta   WANTS
            jmp   :optlp
:fopt       lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            lda   #<PFXBUF
            sta   PTR1
            lda   #>PFXBUF
            sta   PTR1+1
            jsr   STRCPY
            lda   #1
            sta   HAVEPFX
            jmp   :optlp
:nopt       lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   PARSEDEC
            cpy   #0
            bne   :nhave
            jmp   USAGEEXIT
:nhave      lda   (PTR0),y
            beq   :nok
            jmp   USAGEEXIT
:nok        lda   ACCHI
            bne   :nbad
            lda   ACCLO
            beq   :nbad
            cmp   #10
            bcs   :nbad
            sta   NDIG
            jmp   :optlp
:nbad       jmp   USAGEEXIT
:optdone

            lda   ARGC
            sec
            sbc   OPTIND
            cmp   #2
            bcs   :nargok
            jmp   USAGEEXIT
:nargok     sta   NARGS

            lda   HAVEPFX
            bne   :pfxdone
            lda   #<DEFPFXS
            sta   PTR0
            lda   #>DEFPFXS
            sta   PTR0+1
            lda   #<PFXBUF
            sta   PTR1
            lda   #>PFXBUF
            sta   PTR1+1
            jsr   STRCPY
:pfxdone    lda   #<PFXBUF
            sta   PTR0
            lda   #>PFXBUF
            sta   PTR0+1
            jsr   STRLEN
            sta   PFXLEN
*-- the cap is a ProDOS FILENAME limit, not a whole-PATH one --
*-- see split.s's own identical fix/comment (a -f prefix may be
*-- "/mnt/MAUX/O/x", a real, ordinary usage). BASENIDX is the
*-- index
*-- right after the LAST '/' in PFXBUF, 0 if there is none.
            stz   BASENIDX
            ldx   #0
:bnlp       cpx   PFXLEN
            beq   :bndone
            lda   PFXBUF,x
            cmp   #$AF
            bne   :bnnext
            inx
            stx   BASENIDX
            dex
:bnnext     inx
            bra   :bnlp
:bndone     lda   PFXLEN
            sec
            sbc   BASENIDX
            clc
            adc   NDIG
            cmp   #NAMECAP+1
            bcc   :namok
            jmp   NAMETOOLONG
:namok

            lda   OPTIND
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :fok
            jmp   CANTOPENSRC
:fok        lda   OPARM_REF
            sta   SRCFD

            stz   BUFPOS
            stz   BUFLEN
            stz   LINENO
            stz   LINENO+1
            stz   PIECEIDX
            stz   CUROPEN
            stz   HAVELAST
            jsr   GETSLN

            lda   OPTIND
            clc
            adc   #1
            sta   ARGIDX
:argloop    lda   ARGIDX
            cmp   ARGC
            bcs   :remain
            jsr   GETARG
            ldy   #0
            lda   (PTR0),y
            and   #$7F
            cmp   #'0'
            bcc   :notnum
            cmp   #'9'+1
            bcs   :notnum
            jsr   DONUM
            bra   :argnext
:notnum     lda   (PTR0),y
            cmp   #$AF                   ;'/'
            bne   :notslash
            jsr   DOREGEX
            bra   :argnext
:notslash   cmp   #$A5                   ;'%'
            bne   :notpct
            jsr   DOREGEX
            bra   :argnext
:notpct     cmp   #$FB                   ;'{'
            bne   :badarg
            jsr   DOREPEAT
            bra   :argnext
:badarg     jmp   USAGEEXIT
:argnext    inc   ARGIDX
            jmp   :argloop

:remain     lda   SHAVE
            beq   :alldone
            jsr   OPENPIECE
:remlp      lda   SHAVE
            beq   :remend
            jsr   WRITELINE
            jsr   GETSLN
            bra   :remlp
:remend     jsr   CLOSEPIECE
:alldone    lda   SRCFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            lda   #0
            jsr   EXIT

USAGEMSG    asc   "usage: csplit [-ks] [-f prefix] "
            asc   "[-n number] file arg..."
            dfb   $8D,$00
CANTOPENM   asc   "csplit: cannot open input file"
            dfb   $8D,$00
NAMELONGM   asc   "csplit: prefix+digits exceeds 15 "
            asc   "characters"
            dfb   $8D,$00
WRFAILM     asc   "csplit: write error"
            dfb   $8D,$00
CREATFM     asc   "csplit: cannot create output file"
            dfb   $8D,$00
NUMRANGEM   asc   "csplit: line number out of range"
            dfb   $8D,$00
REGEXERRM   asc   "csplit: no match"
            dfb   $8D,$00
DEFPFXS     asc   "xx"
            dfb   0
CSOPTS      asc   "ksf:n:"
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

DPARM       dfb   PCNT_DESTROY
DPARM_PATH  da    PATHBUF

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/creat.s
            put   ../liba/syscalls.s
            put   csplitrn.s
            put   ../liba/regex.s
            put   ../liba/regex2.s
            put   ../liba/libabss.s
            put   ../liba/regexbss.s

*---------------------------------------------------------------
* csplit's own scalars, `dum`/`dend` off REGEX_BSSEND (regex.s/
* regex2.s's own bss chains here -- see regexbss.s's header; NOT
* LIBA_BSSEND, since this unit links the BRE engine).
*
* `dum` memory is NOT zeroed (docs/STICKY.md sec 21):
*  - WANTK/WANTS/HAVEPFX/NDIG: START's own defaults, before the
*    option loop that may override them.
*  - NARGS/PFXLEN: each written before its own first read.
*  - BASENIDX: `stz`'d right before the scan loop that is its
*    only reader (the length-cap check right after it).
*  - SRCFD/BUFPOS/BUFLEN/LINENO/PIECEIDX/CUROPEN/HAVELAST:
*    START's own explicit stores before the arg loop that reads
*    them (GETBYTE's `cpx BUFLEN` needs BUFPOS/BUFLEN zeroed
*    first, the same hazard every buffered reader in this tree
*    documents).
*  - ARGIDX: written right before the loop that is its only
*    reader.
*  - TARGLO/TARGHI: DONUM's own stores, before its own compares.
*  - DELIM/SKIPMODE/OFFNEG/OFFLO/OFFHI/OFFYSTRT: DOREGEX's own
*    stores, each before its own read within the same call.
*  - REPMODE: DOREGEX/DOREPEAT each store it right before their
*    own `jsr`/`jmp RUNSEG`, RUNSEG's own only reader.
*  - LASTBRE/LASTSKIP/LASTOFLO/LASTOFHI: written by DOREGEX
*    whenever HAVELAST becomes 1 -- DOREPEAT never runs unless
*    HAVELAST is already 1, so these are never read unwritten.
*  - REPCNT: DOREPEAT's own store, its own loop's reader.
*  - CURFD/BYTCNTLO/BYTCNTHI: OPENPIECE's own stores, every
*    piece, before WRITELINE/CLOSEPIECE read them.
*  - SLEN/SHAVE/SHADCR/SLINEBUF: GETSLN's own stores, every
*    call, before RUNSEG/WRITELINE/DONUM read that copy again.
*  - FN_V/FN_H/FN_T/FN_PAD/DIGS3/NUMDIGS: FMTNUM's own stores,
*    each before its own read.
*  - PNAMEBUF: BUILDNAME's own two copy loops then the NUL, all
*    before MKPATH reads it.
*  - DELCNT/DELI/ERRMSGP: ERRCLEANUP's/NUMRANGEERR's/REGEXERR's
*    own stores, before the loop or the final PUTS reads them.
*  - ACCLO/ACCHI/AC_DIGIT/AC_TWOLO/AC_TWOHI: PARSEDEC/ACCUM10's
*    own stores, each before its own read.
*  - PATHBUF: MKPATH writes chars then the count byte.
*  - CBUF: filled by SC_READ, indexed only below BUFLEN.
*---------------------------------------------------------------
            dum   REGEX_BSSEND
WANTK       ds    1
WANTS       ds    1
HAVEPFX     ds    1
NDIG        ds    1
NARGS       ds    1
PFXLEN      ds    1
BASENIDX    ds    1
SRCFD       ds    1
BUFPOS      ds    1
BUFLEN      ds    1
LINENO      ds    2
PIECEIDX    ds    1
CUROPEN     ds    1
HAVELAST    ds    1
ARGIDX      ds    1
TARGLO      ds    1
TARGHI      ds    1
DELIM       ds    1
SKIPMODE    ds    1
REPMODE     ds    1
OFFNEG      ds    1
OFFLO       ds    1
OFFHI       ds    1
OFFYSTRT    ds    1
LASTSKIP    ds    1
LASTOFLO    ds    1
LASTOFHI    ds    1
REPCNT      ds    2
CURFD       ds    1
BYTCNTLO    ds    1
BYTCNTHI    ds    1
SLEN        ds    1
SHAVE       ds    1
SHADCR      ds    1
FN_V        ds    1
FN_H        ds    1
FN_T        ds    1
FN_PAD      ds    1
DELCNT      ds    1
DELI        ds    1
ERRMSGP     ds    2
ACCLO       ds    1
ACCHI       ds    1
AC_DIGIT    ds    1
AC_TWOLO    ds    1
AC_TWOHI    ds    1

DIGS3       ds    3
NUMDIGS     ds    12
PFXBUF      ds    32
PNAMEBUF    ds    48
PATBUF      ds    128
LASTBRE     ds    128
SLINEBUF    ds    LINEMAX+1
PATHBUF     ds    65
CBUF        ds    BUFSZ
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 is the top of the process window (see src/bin/ed.s
* -- for the full note).
            err   */$BF00
            dend
