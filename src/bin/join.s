*---------------------------------------------------------------
* join.s -- relational join of two sorted files on a common
* field.
*
* Usage: join [-a n|-v n] [-e s] [-o list] [-t c]
*              [-1 n] [-2 n] file1 file2
*
* CONTRACT (XCU join.html): both files are assumed already
* sorted on their own join field (field 1 by default, `-1`/`-2`
* override which field per side) -- join does not sort and does
* not check, same posture as comm.s. Default field separator is
* a run of blanks (space $A0 or tab $89), leading blanks
* ignored, runs collapsing to one separator; `-t CHAR` makes
* CHAR the separator on BOTH sides, and every field it bounds
* -- including an EMPTY one between two adjacent separators --
* counts. Default output separator is one blank; `-t` makes it
* CHAR too.
*
* MERGE, comm.s's OWN three-way shape, adapted to compare only
* the JOIN FIELD rather than the whole line: while both files
* still have a line, the smaller join field's line is unpaired
* (emitted only under -a/-v for that side), and an EQUAL pair is
* the ordinary joined record. Once one file is exhausted, every
* remaining line of the other is unpaired the same way.
*
* -a n ADDS unpaired lines from file n to the normal output (n
* is 1 or 2, and both may be given). -v n instead SUPPRESSES the
* normal paired output and prints ONLY the unpaired lines from
* file n (VMODE below) -- classic join's way of listing what did
* NOT match. -o LIST (comma-separated `m.n` field selectors, or
* the bare digit `0` for the join field) picks the output
* fields; an item naming the side that has NO line for this
* record (an -a/-v unpaired record) prints EMPTY, replaced by
* `-e STRING` when given -- GNU and the XCU both apply -e only
* through -o (BSD differs; a `hand=` row covers it). Field
* numbers in `-o`/`-1`/`-2` are single digits in this v1 (no
* fixture needs a two-digit field), keeping OLIST's own token
* scanner a one-pass digit-or-dot walk.
*
* WITHOUT -o: a joined record is the join field, then file1's
* OTHER fields (in order), then file2's OTHER fields (in order).
* An unpaired record under -a/-v has only its OWN side's other
* fields -- there is no partner to draw a second half from.
*
* FIELD TABLES: FLDSPLIT1/FLDSPLIT2 scan a line ONCE per GETLNn
* call into FOFFn/FLENn (offset+length pairs, MAXFLD entries),
* the same shape cutlist.s's own range table uses, indexed by
* absolute addressing (`FOFF1,x`) rather than a passed pointer
* -- no indirection needed since each side owns fixed labels.
*
* `-` NAMES STDIN for either operand (not both at once -- an
* untested, undefined double-stdin case, same posture as split.s
* leaving suffix arithmetic undefined past 16 bits).
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
            dsk   ../../build/join.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255
LINEMAX     equ   255
MAXFLD      equ   12               ;fields tracked per line
MAXOL       equ   8                ;-o list entries
TAB         equ   $89

START       lda   #1
            sta   JF1
            sta   JF2
            stz   TMODE
            stz   HAVEO
            stz   HAVEE
            stz   WANTA1
            stz   WANTA2
            stz   WANTV1
            stz   WANTV2
            stz   OCOUNT
            lda   #<JOINOPTS
            ldx   #>JOINOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcc   :haveopt
            jmp   :optdone
:haveopt    cmp   #$E1                   ;'a'
            bne   :nota
            jmp   :aopt
:nota       cmp   #$F6                   ;'v'
            bne   :notv
            jmp   :vopt
:notv       cmp   #$E5                   ;'e'
            bne   :note
            jmp   :eopt
:note       cmp   #$EF                   ;'o'
            bne   :nopto
            jmp   :oopt
:nopto      cmp   #$F4                   ;'t'
            bne   :nott
            jmp   :topt
:nott       cmp   #$B1                   ;'1'
            bne   :nof1
            jmp   :f1opt
:nof1       cmp   #$B2                   ;'2'
            bne   :nof2
            jmp   :f2opt
:nof2       jmp   USAGEEXIT

:aopt       jsr   PDOPTARG
            cpy   #0
            bne   :ahave
            jmp   USAGEEXIT
:ahave      lda   (PTR0),y
            beq   :aok
            jmp   USAGEEXIT
:aok        lda   ACCLO
            ora   ACCHI
            beq   :abad
            lda   ACCHI
            bne   :abad
            lda   ACCLO
            cmp   #1
            beq   :a1
            cmp   #2
            beq   :a2
:abad       jmp   USAGEEXIT
:a1         lda   #1
            sta   WANTA1
            jmp   :optlp
:a2         lda   #1
            sta   WANTA2
            jmp   :optlp

:vopt       jsr   PDOPTARG
            cpy   #0
            bne   :vhave
            jmp   USAGEEXIT
:vhave      lda   (PTR0),y
            beq   :vok
            jmp   USAGEEXIT
:vok        lda   ACCHI
            bne   :vbad
            lda   ACCLO
            cmp   #1
            beq   :v1
            cmp   #2
            beq   :v2
:vbad       jmp   USAGEEXIT
:v1         lda   #1
            sta   WANTV1
            jmp   :optlp
:v2         lda   #1
            sta   WANTV2
            jmp   :optlp

:eopt       lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            lda   #<ESTR
            sta   PTR1
            lda   #>ESTR
            sta   PTR1+1
            jsr   STRCPY
            lda   #1
            sta   HAVEE
            jmp   :optlp

:topt       lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            ldy   #0
            lda   (PTR0),y
            beq   :tbad
*-- -t's character arrives high-bit from argv; the same
*-- character in the FILE may be low. Mask BOTH sides, which is
*-- what sort.s does for its own SEPCHAR.
            and   #$7F
            sta   SEPCH
            lda   #1
            sta   TMODE
            jmp   :optlp
:tbad       jmp   USAGEEXIT

:f1opt      jsr   PDOPTARG
            cpy   #0
            bne   :f1have
            jmp   USAGEEXIT
:f1have     lda   (PTR0),y
            beq   :f1ok
            jmp   USAGEEXIT
:f1ok       lda   ACCLO
            sta   JF1
            jmp   :optlp

:f2opt      jsr   PDOPTARG
            cpy   #0
            bne   :f2have
            jmp   USAGEEXIT
:f2have     lda   (PTR0),y
            beq   :f2ok
            jmp   USAGEEXIT
:f2ok       lda   ACCLO
            sta   JF2
            jmp   :optlp

:oopt       lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   OPARSE
            lda   #1
            sta   HAVEO
            jmp   :optlp
:optdone

            lda   ARGC
            sec
            sbc   OPTIND
            cmp   #2
            beq   :nargok
            jmp   USAGEEXIT
:nargok     lda   OPTIND
            jsr   OPENSIDE1
            lda   OPTIND
            clc
            adc   #1
            jsr   OPENSIDE2

            stz   BUFPOS1
            stz   BUFLEN1
            stz   BUFPOS2
            stz   BUFLEN2
            jsr   GETLN1
            jsr   GETLN2
            jmp   MRGLOOP

USAGEEXIT   lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* MRGLOOP -- comm.s's own merge shape, on join fields.
*---------------------------------------------------------------
MRGLOOP     lda   HAVE1
            bne   :h1
            lda   HAVE2
            beq   :alldone
            lda   #2
            sta   CURSIDE
            jsr   MAYBEOUT2
            jsr   GETLN2
            jmp   MRGLOOP
:h1         lda   HAVE2
            bne   :both
            lda   #1
            sta   CURSIDE
            jsr   MAYBEOUT1
            jsr   GETLN1
            jmp   MRGLOOP
:both       jsr   CMPJF
            cmp   #0
            beq   :eq
            cmp   #1
            beq   :gt
            lda   #1
            sta   CURSIDE
            jsr   MAYBEOUT1
            jsr   GETLN1
            jmp   MRGLOOP
:gt         lda   #2
            sta   CURSIDE
            jsr   MAYBEOUT2
            jsr   GETLN2
            jmp   MRGLOOP
:eq         lda   WANTV1
            ora   WANTV2
            bne   :veq
            lda   #0
            sta   CURSIDE
            jsr   OUTREC
:veq        jsr   GETLN1
            jsr   GETLN2
            jmp   MRGLOOP
:alldone    lda   ISFILE1
            beq   :c2
            lda   FD1
            sta   C1PARM_REF
            lda   #<C1PARM
            ldx   #>C1PARM
            jsr   SC_CLOSE
:c2         lda   ISFILE2
            beq   :xd
            lda   FD2
            sta   C2PARM_REF
            lda   #<C2PARM
            ldx   #>C2PARM
            jsr   SC_CLOSE
:xd         lda   #0
            jsr   EXIT

*---------------------------------------------------------------
* MAYBEOUT1/MAYBEOUT2 -- an unpaired line from one side; print
* it (via OUTREC, CURSIDE already set) iff -a or -v named this
* side.
*---------------------------------------------------------------
MAYBEOUT1   lda   WANTA1
            ora   WANTV1
            beq   :rt
            jmp   OUTREC
:rt         rts

MAYBEOUT2   lda   WANTA2
            ora   WANTV2
            beq   :rt
            jmp   OUTREC
:rt         rts


USAGEMSG    asc   "usage: join [-a n|-v n] [-e s] "
            asc   "[-o list] [-t c] [-1 n] [-2 n] "
            asc   "file1 file2"
            dfb   $8D,$00
CANTOPENM   asc   "join: cannot open input file"
            dfb   $8D,$00
JOINOPTS    asc   "a:v:e:o:t:1:2:"
            dfb   0

O1PARM      dfb   OPEN_RO
O1PARM_PATH da    PATH1BUF
O1PARM_IOBF da    $0000
O1PARM_REF  dfb   0

O2PARM      dfb   OPEN_RO
O2PARM_PATH da    PATH2BUF
O2PARM_IOBF da    $0000
O2PARM_REF  dfb   0

R1PARM       dfb   PCOUNT_READ
R1PARM_REF   dfb   0
R1PARM_BUF   da    CBUF1
R1PARM_REQ   da    BUFSZ
R1PARM_TRANS da    0

R2PARM       dfb   PCOUNT_READ
R2PARM_REF   dfb   0
R2PARM_BUF   da    CBUF2
R2PARM_REQ   da    BUFSZ
R2PARM_TRANS da    0

C1PARM      dfb   PCOUNT_CLOSE
C1PARM_REF  dfb   0
C2PARM      dfb   PCOUNT_CLOSE
C2PARM_REF  dfb   0

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/syscalls.s
            put   joinio.s
            put   joinout.s
            put   joinopt.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* join's own scalars, `dum`/`dend` off LIBA_BSSEND -- no `ds`
* zeros needed (docs/STICKY.md sec 21): every cell below is
* write-before-read.
*  - JF1/JF2/TMODE/HAVEO/HAVEE/WANTA1/WANTA2/WANTV1/WANTV2/
*    OCOUNT: START's own defaults, before the option loop that
*    may override them.
*  - SEPCH/ESTR: written only on the -t/-e paths, each before
*    its own reader (PRINTOFS/PREMPTY test TMODE/HAVEE first).
*  - OLSIDE/OLFLD: OAPPEND's own stores, [0..OCOUNT) only.
*  - FD1/FD2/ISFILE1/ISFILE2: OPENSIDE1/2's own stores, every
*    path, before GETB1/GETB2 or the closing check read them.
*  - BUFPOS1/BUFLEN1/BUFPOS2/BUFLEN2: `stz`'d before the first
*    GETLN1/GETLN2 call -- GETB1/GETB2's `cpx BUFLENn` would
*    otherwise compare against garbage.
*  - HAVE1/HAVE2/LEN1/LEN2/L1BUF/L2BUF: every GETLN1/
*    GETLN2 call writes HAVEn (and LINEnBUF, NUL-terminated,
*    when HAVEn=1) before MRGLOOP/CMPJF/OUTREC read that copy
*    again; LENn is each call's own loop counter.
*  - NFLD1/NFLD2/FOFF1/FLEN1/FOFF2/FLEN2/FSTART: FLDSPLIT1/2's
*    own stores, every GETLN1/GETLN2 call, before GETFLD1/2 or
*    PREXTRA1/2 read them.
*  - CURSIDE: MRGLOOP's own store before every OUTREC call.
*  - JFOFF/JFLEN/CFALEN/CFBLEN: GETFLD1/2's/CMPJF's own stores,
*    each before its own reader.
*  - PSLEN/PSFD: PRSLICE's own stores, its only reader.
*  - OOSIDE/OOFLD: OPARSE's own stores, before OAPPEND reads
*    them.
*  - ACCLO/ACCHI/AC_DIGIT/AC_TWOLO/AC_TWOHI: PARSEDEC/ACCUM10's
*    own stores, each before its own read.
*  - PATH1BUF/PATH2BUF: MKPATH writes chars then the count byte.
*  - CBUF1/CBUF2: filled by SC_READ, indexed only below BUFLENn.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
JF1         ds    1
JF2         ds    1
TMODE       ds    1
SEPCH       ds    1
HAVEO       ds    1
HAVEE       ds    1
WANTA1      ds    1
WANTA2      ds    1
WANTV1      ds    1
WANTV2      ds    1
OCOUNT      ds    1
FD1         ds    1
FD2         ds    1
ISFILE1     ds    1
ISFILE2     ds    1
BUFPOS1     ds    1
BUFLEN1     ds    1
BUFPOS2     ds    1
BUFLEN2     ds    1
HAVE1       ds    1
HAVE2       ds    1
LEN1        ds    1
LEN2        ds    1
NFLD1       ds    1
NFLD2       ds    1
FSTART      ds    1
CURSIDE     ds    1
JFOFF       ds    1
JFLEN       ds    1
CFALEN      ds    1
CFBLEN      ds    1
PSLEN       ds    1
PSFD        ds    1
OOSIDE      ds    1
OOFLD       ds    1
ACCLO       ds    1
ACCHI       ds    1
AC_DIGIT    ds    1
AC_TWOLO    ds    1
AC_TWOHI    ds    1

OLSIDE      ds    MAXOL
OLFLD       ds    MAXOL
FOFF1       ds    MAXFLD
FLEN1       ds    MAXFLD
FOFF2       ds    MAXFLD
FLEN2       ds    MAXFLD
ESTR        ds    64
*-- L1BUF/L2BUF are spelt short ON PURPOSE: this unit sits
*-- against as's 16128-byte source window, and label text is
*-- what the strip leaves behind. See docs/S9-PLAN.md s5.
L1BUF    ds    LINEMAX+1
L2BUF    ds    LINEMAX+1
PATH1BUF    ds    65
PATH2BUF    ds    65
CBUF1       ds    BUFSZ
CBUF2       ds    BUFSZ
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 is the top of the process window (see src/bin/ed.s
* -- for the full note).
            err   */$BF00
            dend
