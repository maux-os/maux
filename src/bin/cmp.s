*---------------------------------------------------------------
* cmp.s -- byte-compare two files (V6 semantics).
*
* Usage: cmp [-l | -s] file1 file2
*
* CONTRACT:
*   Identical         -> print nothing, exit 0.
*   Differ            -> to STANDARD OUTPUT (POSIX's own STDOUT
*     section names the exact format and the stream; BSD cmp
*     confirms live -- stdout, exit 1, nothing on stderr):
*     "file1 file2 differ: char N, line L"; exit 1. N is the
*     1-based byte offset of the first differing byte; L is
*     1-based (count of $8D/CR bytes seen strictly BEFORE that
*     byte, plus 1) -- matches wc.s's own CR-counts-a-line rule.
*   One file a prefix of the other -> "cmp: EOF on <shorter>"
*     to stderr; exit 1.
*   -s -- silent: suppress the differ/EOF messages above (status
*     only). Usage and open errors still print -- same split
*     cat.s/wc.s use for their own errors vs. normal output.
*   -l (FLEET F.2, 2026-09-01) -- list EVERY differing byte pair
*     to stdout as "%6d %3o %3o" (offset decimal 1-based right-
*     aligned width 6, both bytes octal, leading zeros shown as
*     spaces -- BSD cmp's exact bytes, measured before this was
*     written), continue to EOF, exit 1 if anything differed.
*     A length mismatch still says "cmp: EOF on <shorter>" to
*     stderr after the listing. -l with -s is refused (usage,
*     exit 2 -- the reference refuses the pair too). The offset
*     shares the 24-bit byte counter (see COUNTERS below).
*   Missing/extra operand or unopenable file -> message to
*     stderr, exit 2.
*
* COUNTERS (SH-DEFECTS item 8, 2026-10-25): BYTECNT and LINECNT
* are 24-bit. A ProDOS/maux file EOF is a 3-byte field (inc/
* readdir.equ RD_EOF), so no file maux can open holds more than
* 16,777,215 bytes: 24 bits is EXACT for char N, and the line
* number (<= bytes + 1 <= 2^24) fits too. 32 bits would buy
* nothing a file can reach and cost a byte per cell.
*
* Two files open at once -- SAME shape as cp.s's two-fd dance
* (SOPARM/DOPARM there, O1PARM/O2PARM here), just two READs
* instead of a read+write. Buffered byte-at-a-time input is
* wc.s's own GETBYTE/REFILL shape, duplicated per fd (liba has
* no generic per-fd buffered reader -- every util hand-rolls
* this loop over SC_READ directly, same as wc/cat/cp.s do).
*
* Uses ONLY liba -- no direct syscalls beyond what wc.s/cat.s/
* cp.s already establish as the house pattern for a read loop.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/cmp.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   128              ;per-fd chunk size -- two of
                                   ;these cost what cat/cp.s pay
                                   ;for one 512B buffer

START       stz   WANT_S
            stz   WANT_L
            stz   DIFFFLG
            lda   #<OPTS
            ldx   #>OPTS
            jsr   OPTINIT
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #$F3                  ;'s' high-bit-set
            beq   :sflag
            cmp   #$EC                  ;'l' list every pair
            beq   :lflag
            jmp   USAGERR
:sflag      sta   WANT_S
            bra   :optlp
:lflag      sta   WANT_L
            bra   :optlp
:optdone    lda   WANT_L                ;-l with -s: refused,
            beq   :noclash              ;as the reference does
            lda   WANT_S
            beq   :noclash
            jmp   USAGERR
:noclash    lda   ARGC
            sec
            sbc   OPTIND
            cmp   #2                    ;must be exactly 2
            beq   :nargok               ;operands
            jmp   USAGERR
:nargok     lda   OPTIND
            sta   F1IDX
            clc
            adc   #1
            sta   F2IDX

            lda   F1IDX
            jsr   GETARG                ;-> PTR0 = argv[F1IDX]
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
            jsr   GETARG                ;-> PTR0 = argv[F2IDX]
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
            stz   BYTECNT
            stz   BYTECNT+1
            stz   BYTECNT+2
            stz   LINECNT
            stz   LINECNT+1
            stz   LINECNT+2
            jmp   CMPLOOP

*---------------------------------------------------------------
* CMPLOOP -- the byte-by-byte compare. Reads one byte from each
* fd per iteration; EOF on one/both/neither drives the three
* terminal outcomes (identical, one file shorter, differ).
*---------------------------------------------------------------
CMPLOOP     jsr   GETB1
            bcs   :e1
            sta   CURB1
            stz   EOF1FLG
            bra   :hb1
:e1         lda   #1
            sta   EOF1FLG
:hb1        jsr   GETB2
            bcs   :e2
            sta   CURB2
            stz   EOF2FLG
            bra   :hb2
:e2         lda   #1
            sta   EOF2FLG
:hb2        lda   EOF1FLG
            bne   :f1e
            lda   EOF2FLG
            bne   :f2e
            bra   :bh
:f1e        lda   EOF2FLG
            bne   :adone                ;both EOF -- identical
            lda   F1IDX                 ;file1 hit EOF first --
            sta   SHORTIDX              ;it is the shorter one
            jmp   EOFCOMMON
:f2e        lda   F2IDX                 ;file2 hit EOF first
            sta   SHORTIDX
            jmp   EOFCOMMON
:adone      lda   FD1
            sta   C1PARM_REF
            lda   #<C1PARM
            ldx   #>C1PARM
            jsr   SC_CLOSE
            lda   FD2
            sta   C2PARM_REF
            lda   #<C2PARM
            ldx   #>C2PARM
            jsr   SC_CLOSE
            lda   DIFFFLG               ;-l reached EOF with
            beq   :allsame              ;pairs listed: exit 1
            lda   #1
            jsr   EXIT
:allsame    lda   #0
            jsr   EXIT

:bh         inc   BYTECNT               ;N is 1-based -- this
            bne   :bok                  ;byte pair's position
            inc   BYTECNT+1
            bne   :bok                  ;24-bit, see COUNTERS
            inc   BYTECNT+2
:bok        lda   CURB1
            cmp   CURB2
            beq   :sm
            lda   WANT_L                ;-l: say the pair, keep
            beq   :hard                 ;walking; else the old
            jsr   PRLPAIR               ;first-diff exit
            lda   #1
            sta   DIFFFLG
            jmp   CMPLOOP
:hard       jmp   DIFFER
:sm         cmp   #$8D                  ;A still == CURB1 (cmp
                                        ;doesn't touch it) -- CR
                                        ;check, wc.s's own rule
            bne   :ncr
            inc   LINECNT
            bne   :ncr
            inc   LINECNT+1
            bne   :ncr
            inc   LINECNT+2
:ncr        jmp   CMPLOOP

*---------------------------------------------------------------
* USAGERR -- bad option or wrong operand count. Exit 2.
*---------------------------------------------------------------
USAGERR     lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* GETB1/REFIL1, GETB2/REFIL2 -- buffered input, one pair per fd.
* Same shape as wc.s's GETBYTE/REFILL, duplicated because two
* streams are live at once here.
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

USAGEMSG    asc   "usage: cmp [-l|-s] file1 file2"
            dfb   0
OPENMSG     asc   "cmp: cannot open "
            dfb   0
EOFMSG      asc   "cmp: EOF on "
            dfb   0
DIFFMID     asc   " differ: char "
            dfb   0
LINEMID     asc   ", line "
            dfb   0
OPTS        asc   "sl"
            dfb   0

O1PARM      dfb   OPEN_RO
O1PARM_PATH da    PATH1BUF
O1PARM_IOBF da    $0000          ;kernel-owned -- see cat.s/cp.s
O1PARM_REF  dfb   0              ; result: fd

O2PARM      dfb   OPEN_RO
O2PARM_PATH da    PATH2BUF
O2PARM_IOBF da    $0000
O2PARM_REF  dfb   0

R1PARM      dfb   PCOUNT_READ
R1PARM_REF  dfb   0
R1PARM_BUF  da    CBUF1
R1PARM_REQ  da    BUFSZ
R1PARM_TRANS da   0

R2PARM      dfb   PCOUNT_READ
R2PARM_REF  dfb   0
R2PARM_BUF  da    CBUF2
R2PARM_REQ  da    BUFSZ
R2PARM_TRANS da   0

C1PARM      dfb   PCOUNT_CLOSE
C1PARM_REF  dfb   0
C2PARM      dfb   PCOUNT_CLOSE
C2PARM_REF  dfb   0

            put   cmprpt.s
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
* cmp's bss -- `dum`/`dend` at the TEXTUAL END, past every
* emitted byte, anchored at LIBA_BSSEND rather than `*`
* (learning:01M0FNC75R7YSFRNS328WHXMHN). 405 bytes that were
* emitted zeros. OPTS and the six parmlists stay above as
* initialised data; `da PATH1BUF` / `da CBUF1` resolve into
* this arena as forward references. comm.s is the same program
* one column over and already carries this exact arena.
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - WANT_S: `stz` as START's first instruction.
*  - F1IDX/F2IDX: `sta` at :nargok before any read.
*  - OERRIDX/SHORTIDX: each `sta`'d IMMEDIATELY before the
*    `jmp` to the routine that reads it, and OPENERR/
*    EOFCOMMON are reachable ONLY from those jumps -- the
*    preceding code ends in `jsr EXIT`, so there is no
*    fall-through into either.
*  - FD1/FD2: `sta`'d after their opens succeed, before
*    CMPLOOP is entered.
*  - CURB1/CURB2: written every iteration on the path that
*    reads them -- :bh is reached only when BOTH eof flags are
*    zero, and both flags are rewritten every iteration, so a
*    zero flag means THIS iteration did the store.
*  - EOF1FLG/EOF2FLG: unconditionally written (stz or sta)
*    every iteration before the test reads them.
*  - BUFPOS1/BUFLEN1/BUFPOS2/BUFLEN2: all four `stz`'d on the
*    single path into CMPLOOP, which is what makes GETB1/GETB2's
*    `pos >= len` refill test a decision rather than an
*    accident. REFIL1/REFIL2 re-store both on success and leave
*    pos == len on failure, so the next call retries the refill
*    instead of serving stale bytes.
*  - BYTECNT/LINECNT: both `stz`'d as a block before the
*    compare loop; the `inc` read-modify-writes depend on it.
*  - PATH1BUF/PATH2BUF: MKPATH writes chars then the count
*    byte; the MLI reads only count+1.
*  - CBUF1/CBUF2: filled by SC_READ, indexed only below the
*    BUFLEN that same call set.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
WANT_S      ds    1
WANT_L      ds    1              ;-l list every pair
DIFFFLG     ds    1              ;-l saw at least one pair
OCTB        ds    1              ;OCT3 scratch
PADTMP      ds    1              ;PRLPAIR pad arithmetic
F1IDX       ds    1
F2IDX       ds    1
OERRIDX     ds    1
SHORTIDX    ds    1
FD1         ds    1
FD2         ds    1
CURB1       ds    1
CURB2       ds    1
EOF1FLG     ds    1
EOF2FLG     ds    1
BUFPOS1     ds    1
BUFLEN1     ds    1
BUFPOS2     ds    1
BUFLEN2     ds    1
BYTECNT     ds    3              ;24-bit, little-endian
LINECNT     ds    3
N3VAL       ds    3              ;U3DEC value (consumed)
N3SUB       ds    3              ;U3DEC current power of ten
N3DIG       ds    1
N3LZ        ds    1
N3FD        ds    1              ;PR3NUM's fd
N3BUF       ds    9              ;8 digits + NUL

PATH1BUF    ds    65
PATH2BUF    ds    65
CBUF1       ds    BUFSZ
CBUF2       ds    BUFSZ
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
