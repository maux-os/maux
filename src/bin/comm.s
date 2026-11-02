*---------------------------------------------------------------
* comm.s -- select/reject lines common to two SORTED files.
*
* Usage: comm [-123] file1 file2
*
* CONTRACT (classic V6 comm -- comm's OWN sibling to sort.s/
* uniq.s's "does not sort" split): produces three columns as the
* two files merge in sorted order --
*   column 1: lines only in file1
*   column 2: lines only in file2
*   column 3: lines in both
* `-1`/`-2`/`-3` SUPPRESS the corresponding column (the line is
* simply not printed -- not blanked, not renumbered into a
* different column). They cluster like every other getopt.s
* flag (`-12` == `-1 -2`). Column N's <lead> is ADAPTIVE, per
* POSIX's own STDOUT section (verified against a live BSD comm
* with -1, -2 and -12): column 2's lead is one <tab> ($89,
* high-bit-set -- wc.s's own tab byte), or the null string when
* -1 is selected. Column 3's lead is two <tab>s, minus one for
* EACH of -1/-2 that is selected -- so `comm -1` (column 3 the
* only survivor) prints it with a single leading tab, not two.
* 2026-09-13 fix: OUT2/OUT3 used to emit a fixed 1/2 tabs.
*
* comm ASSUMES sorted input and does NOT sort, does NOT check,
* and does NOT say so at runtime -- classic V6 behaviour. Feed
* it unsorted files and the three-way merge below produces
* garbage columns (every "later" line looks new), silently. Sort
* first (`sort file | comm - other` in a shell with process
* substitution, or `sort` into a temp file here, since there is
* no `-` stdin operand support in this v1).
*
* Exactly two FILE operands are required -- missing/extra
* operand or a bad option is a usage error, exit 2 (cmp.s's own
* "must be exactly 2" shape). An unopenable file is "comm:
* cannot open <path>" to stderr, exit 2.
*
* LINE BUFFER: LINEMAX(255)-byte buffers per file, overflow
* policy identical to uniq.s's GETLINE (a forced break at
* LINEMAX, every byte still lands in some line -- see that
* file's header for the full reasoning, not re-derived here).
*
* Two files open at once, buffered byte-at-a-time per fd -- same
* duplicated GETB1/GETB2+REFIL1/REFIL2 shape cmp.s uses (liba
* has no generic per-fd buffered reader). Line comparison is
* liba's STRCMP (0 equal, $FF A<B, 1 A>B -- high-bit-set strings
* collate as plain unsigned bytes, string.s's own header).
*
* comm reads only -- its output is stdout (fd 1) alone, no named
* output file, so there is no FCLOSE concern here (that liba
* wrinkle is tee.s's own, not this file's -- PUTC's buffer for
* fd 1 is flushed by EXIT's own SIO_FLUSHALL either way).
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
            dsk   ../../build/comm.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255              ;per-fd read chunk
LINEMAX     equ   255              ;forced-break cap -- see
                                   ;header (uniq.s's GETLINE)
TAB         equ   $89              ;high-bit-set tab -- wc.s's
                                   ;own byte

START       lda   #1
            sta   WANT1
            sta   WANT2
            sta   WANT3
            lda   #<COMMOPTS
            ldx   #>COMMOPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$B1                   ;'1' high-bit-set
            bne   :not1
            stz   WANT1
            bra   :optlp
:not1       cmp   #$B2                   ;'2'
            bne   :not2
            stz   WANT2
            bra   :optlp
:not2       cmp   #$B3                   ;'3'
            bne   :badopt
            stz   WANT3
            bra   :optlp
:badopt     jmp   :usage
:optdone
            lda   ARGC
            sec
            sbc   OPTIND
            cmp   #2                     ;must be exactly 2
            beq   :nargok
:usage      lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D                  ;terminate the line --
            ldx   #FD_STDERR            ;cmp.s's USAGERR does
            jsr   PUTC                  ;this; comm's own copy
                                        ;used to omit it, so the
                                        ;shell's next prompt
                                        ;drew onto this same row
                                        ;(2026-09-13 fix)
            lda   #2
            jsr   EXIT

:nargok     lda   OPTIND
            sta   F1IDX
            clc
            adc   #1
            sta   F2IDX

            lda   F1IDX
            jsr   GETARG
            lda   #<PATH1BUF
            sta   PTR1
            lda   #>PATH1BUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<O1PARM
            ldx   #>O1PARM
            jsr   SC_OPEN
            bcc   :o1ok
            lda   F1IDX
            sta   OERRIDX
            jmp   OPENERR
:o1ok       lda   O1PARM_REF
            sta   FD1

            lda   F2IDX
            jsr   GETARG
            lda   #<PATH2BUF
            sta   PTR1
            lda   #>PATH2BUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<O2PARM
            ldx   #>O2PARM
            jsr   SC_OPEN
            bcc   :o2ok
            lda   F2IDX
            sta   OERRIDX
            jmp   OPENERR
:o2ok       lda   O2PARM_REF
            sta   FD2

            stz   BUFPOS1
            stz   BUFLEN1
            stz   BUFPOS2
            stz   BUFLEN2
            jsr   GETLN1
            jsr   GETLN2
            jmp   MRGLOOP

*---------------------------------------------------------------
* MRGLOOP -- the three-way sorted merge. See header for the
* column/suppression contract.
*---------------------------------------------------------------
MRGLOOP     lda   HAVE1
            bne   :h1
            lda   HAVE2
            beq   :alldone
            jsr   OUT2
            jsr   GETLN2
            bra   MRGLOOP
:h1         lda   HAVE2
            bne   :both
            jsr   OUT1
            jsr   GETLN1
            bra   MRGLOOP
:both       lda   #<L1BUF
            sta   PTR0
            lda   #>L1BUF
            sta   PTR0+1
            lda   #<L2BUF
            sta   PTR1
            lda   #>L2BUF
            sta   PTR1+1
            jsr   STRCMP
            cmp   #0
            beq   :eq
            cmp   #1
            beq   :gt
            jsr   OUT1                   ;A<B ($FF)
            jsr   GETLN1
            bra   MRGLOOP
:gt         jsr   OUT2
            jsr   GETLN2
            bra   MRGLOOP
:eq         jsr   OUT3
            jsr   GETLN1
            jsr   GETLN2
            bra   MRGLOOP
:alldone    lda   FD1
            sta   C1PARM_REF
            lda   #<C1PARM
            ldx   #>C1PARM
            jsr   SC_CLOSE
            lda   FD2
            sta   C2PARM_REF
            lda   #<C2PARM
            ldx   #>C2PARM
            jsr   SC_CLOSE
            lda   #0
            jsr   EXIT

*---------------------------------------------------------------
* OUT1/OUT2/OUT3 -- print one column's line to fd 1 (indent,
* text, CR), or nothing if that column is suppressed.
*---------------------------------------------------------------
OUT1        lda   WANT1
            beq   :rt
            lda   #<L1BUF
            sta   PTR0
            lda   #>L1BUF
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:rt         rts

OUT2        lda   WANT2
            beq   :rt
            lda   WANT1                 ;-1 selected (WANT1=0):
            beq   :nolead2              ;lead is the null string
            lda   #TAB
            ldx   #FD_STDOUT
            jsr   PUTC
:nolead2    lda   #<L2BUF
            sta   PTR0
            lda   #>L2BUF
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:rt         rts

OUT3        lda   WANT3
            beq   :rt
            lda   WANT1                 ;lead is 2 tabs minus 1
            beq   :skip1                ;for each of -1/-2
            lda   #TAB                  ;selected (WANT{1,2}=0)
            ldx   #FD_STDOUT
            jsr   PUTC
:skip1      lda   WANT2
            beq   :skip2
            lda   #TAB
            ldx   #FD_STDOUT
            jsr   PUTC
:skip2      lda   #<L1BUF
            sta   PTR0
            lda   #>L1BUF
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
:rt         rts

*---------------------------------------------------------------
* OPENERR -- IN: OERRIDX = argv index of the file that failed to
* open. Exit 2.
*---------------------------------------------------------------
OPENERR     lda   #<OPENMSG
            sta   PTR0
            lda   #>OPENMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   OERRIDX
            jsr   GETARG
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* GETLN1/GETLN2 -- next line from FD1/FD2 into L1BUF/
* L2BUF, NUL-terminated. Sets HAVE1/HAVE2: 1 = a line is
* buffered, 0 = EOF with nothing pending. Overflow policy:
* uniq.s's GETLINE (see header).
*---------------------------------------------------------------
GETLN1      stz   LEN1
:next       lda   LEN1
            cmp   #LINEMAX
            bcs   :haveln
            jsr   GETB1
            bcs   :eofhit
            cmp   #$8D
            beq   :haveln
            cmp   #$0D             ;either terminator ends a
            beq   :haveln        ;line -- a foreign file
            ldy   LEN1
            sta   L1BUF,y
            inc   LEN1
            bra   :next
:haveln     ldy   LEN1
            lda   #0
            sta   L1BUF,y
            lda   #1
            sta   HAVE1
            rts
:eofhit     lda   LEN1
            beq   :nothing
            ldy   LEN1
            lda   #0
            sta   L1BUF,y
            lda   #1
            sta   HAVE1
            rts
:nothing    stz   HAVE1
            rts

GETLN2      stz   LEN2
:next       lda   LEN2
            cmp   #LINEMAX
            bcs   :haveln
            jsr   GETB2
            bcs   :eofhit
            cmp   #$8D
            beq   :haveln
            cmp   #$0D             ;either terminator ends a
            beq   :haveln        ;line -- a foreign file
            ldy   LEN2
            sta   L2BUF,y
            inc   LEN2
            bra   :next
:haveln     ldy   LEN2
            lda   #0
            sta   L2BUF,y
            lda   #1
            sta   HAVE2
            rts
:eofhit     lda   LEN2
            beq   :nothing
            ldy   LEN2
            lda   #0
            sta   L2BUF,y
            lda   #1
            sta   HAVE2
            rts
:nothing    stz   HAVE2
            rts

*---------------------------------------------------------------
* GETB1/REFIL1, GETB2/REFIL2 -- buffered input, one pair per fd
* (cmp.s's own dual-fd shape, duplicated -- liba has no generic
* per-fd buffered reader).
*---------------------------------------------------------------
GETB1       ldx   BUFPOS1
            cpx   BUFLEN1
            bcc   :hv1
            jsr   REFIL1
            bcs   :eo1
            ldx   BUFPOS1
:hv1        lda   CBUF1,x
            inc   BUFPOS1
            clc
            rts
:eo1        sec
            rts

REFIL1      lda   FD1
            sta   R1PARM_REF
            lda   #<R1PARM
            ldx   #>R1PARM
            jsr   SC_READ
            bcs   :er1
            lda   R1PARM_TRANS
            ora   R1PARM_TRANS+1
            beq   :er1
            lda   R1PARM_TRANS
            sta   BUFLEN1
            stz   BUFPOS1
            clc
            rts
:er1        sec
            rts

GETB2       ldx   BUFPOS2
            cpx   BUFLEN2
            bcc   :hv2
            jsr   REFIL2
            bcs   :eo2
            ldx   BUFPOS2
:hv2        lda   CBUF2,x
            inc   BUFPOS2
            clc
            rts
:eo2        sec
            rts

REFIL2      lda   FD2
            sta   R2PARM_REF
            lda   #<R2PARM
            ldx   #>R2PARM
            jsr   SC_READ
            bcs   :er2
            lda   R2PARM_TRANS
            ora   R2PARM_TRANS+1
            beq   :er2
            lda   R2PARM_TRANS
            sta   BUFLEN2
            stz   BUFPOS2
            clc
            rts
:er2        sec
            rts

USAGEMSG    asc   "usage: comm [-123] file1 file2"
            dfb   0
OPENMSG     asc   "comm: cannot open "
            dfb   0
COMMOPTS    asc   "123"
            dfb   0

O1PARM      dfb   OPEN_RO
O1PARM_PATH da    PATH1BUF
O1PARM_IOBF da    $0000          ;kernel-owned (main memory)
O1PARM_REF  dfb   0              ; result: fd

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
            put   ../liba/libabss.s

*---------------------------------------------------------------
* comm's own scratch, `dum`/`dend`'d at the textual end of the
* file (never `ds` -- see tee.s's own header for why this
* matters at spawn time). Must stay textually LAST.
*
* `dum` memory is NOT zeroed -- read-before-write trace:
*  - WANT1/WANT2/WANT3: written by START before any read.
*  - F1IDX/F2IDX/OERRIDX: written before their own first read
*    each (F1IDX/F2IDX by :nargok, OERRIDX right before
*    OPENERR jumps to the routine that reads it).
*  - FD1/FD2: written by the two OPEN blocks before MRGLOOP (via
*    GETB1/GETB2/REFIL1/REFIL2) or :alldone's CLOSE read them.
*  - BUFPOS1/BUFLEN1/BUFPOS2/BUFLEN2: explicitly zeroed by START
*    before the first GETLN1/GETLN2 call -- GETB1/GETB2's own
*    `cpx BUFLEN{1,2}` would otherwise compare against garbage
*    (same hazard tee.s's own arena doc calls out).
*  - HAVE1/HAVE2/L1BUF/L2BUF/LEN1/LEN2: every GETLN1/
*    GETLN2 call writes HAVEn (and, when it sets HAVEn=1,
*    LINEnBUF NUL-terminated) before MRGLOOP/OUT1/OUT2/OUT3 ever
*    read that copy again; LENn is GETLNn's own loop counter,
*    zeroed at each call's own start before its first read.
*  - PATH1BUF/PATH2BUF: written whole by MKPATH (count-prefixed,
*    not NUL-scanned) before the matching SC_OPEN reads it.
*  - CBUF1/CBUF2: written by REFIL1/REFIL2's SC_READ before
*    GETB1/GETB2 read them; BUFPOSn/BUFLENn bound every read to
*    bytes that call actually wrote.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
WANT1       ds    1
WANT2       ds    1
WANT3       ds    1
F1IDX       ds    1
F2IDX       ds    1
OERRIDX     ds    1
FD1         ds    1
FD2         ds    1
HAVE1       ds    1
HAVE2       ds    1
LEN1        ds    1
LEN2        ds    1
BUFPOS1     ds    1
BUFLEN1     ds    1
BUFPOS2     ds    1
BUFLEN2     ds    1

*-- L1BUF/L2BUF are spelt short ON PURPOSE: this unit sits
*-- against as's 16128-byte source window, and label text is
*-- what the strip leaves behind. See docs/S9-PLAN.md s5.
L1BUF    ds    LINEMAX+1
L2BUF    ds    LINEMAX+1
PATH1BUF    ds    65
PATH2BUF    ds    65
CBUF1       ds    BUFSZ
CBUF2       ds    BUFSZ
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's
* -- end; $BF00 is the top of the process window. The
* -- division is 0 while it fits, 1 when it does not, and
* -- `err` fails the assembly. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
* -- See src/bin/ed.s for the full note.
            err   */$BF00
            dend
