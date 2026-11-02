*---------------------------------------------------------------
* tsort.s -- topological sort.
*
* Usage: tsort [file]
*
* Input is pairs of whitespace/CR-separated tokens: "a b" means
* a must come before b; "a a" (a token paired with itself)
* merely DECLARES the node a, with no ordering edge. Output is
* one node per line, in an order consistent with every edge --
* Kahn's algorithm (repeatedly output a node with no remaining
* predecessor, then drop its outgoing edges).
*
* TIE-BREAK: among nodes with no remaining predecessor at a
* given step, GNU tsort picks the one that appeared FIRST in the
* input (this build follows GNU, not BSD -- BSD's own tie-break
* is a different, unspecified order; measured live against this
* host's /usr/bin/tsort, which is BSD and visibly does NOT do
* this). FINDFREE below always scans from node 0 in table order,
* and the table is built in first-appearance order (LOOKUPADD
* appends a token the first time it is seen), so the scan order
* = the input's own first-appearance order, giving GNU's
* tie-break for free -- no arrival-timestamp field is needed.
*
* CYCLES: if no node is free at some step, this is not a DAG.
* "tsort: cycle in data" plus the still-unresolved node names go
* to stderr, and the sort continues anyway by FORCING the output
* of the first still-unresolved node in table order (breaking
* every edge that pointed into it, the same way a normal
* selection breaks edges) -- GNU's own documented behaviour
* ("one edge of the cycle broken"). Exit status is 1 if this
* ever happened, 0 otherwise. A cycle's OWN internal order is
* spec-open (POSIX) and diverges between hosts (measured: BSD's
* own tsort prints a different order AND exits 0) -- callers
* needing a cycle row pin this build's own forced-order
* behaviour by hand, not a live host.
*
* An ODD number of tokens is an error: "tsort: odd number of
* tokens" to stderr, exit 1, with NO topological output at all
* (matches this host's own BSD tsort, which also refuses rather
* than sort a partial pair set).
*
* CAPACITY: up to TS_MAXN distinct tokens, TS_MAXE edges, each
* token up to TS_TOKCAP-1 characters -- fixed tables, no `dum`
* arena has room for anything unbounded on this machine. A
* token longer than the cap is silently truncated; more nodes
* or edges than the cap silently reuses the last slot -- no
* test in this tree's corpus approaches either limit.
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
            dsk   ../../build/tsort.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   255              ;read chunk, see GETBYTE
TS_MAXN     equ   32               ;max distinct tokens (nodes)
TS_MAXE     equ   64               ;max edges
TS_TOKCAP   equ   16               ;15 chars + NUL per slot

START       lda   ARGC
            cmp   #3
            bcc   :argok
            jmp   :usage
:argok      cmp   #2
            bcs   :havefile
            lda   #FD_STDIN
            sta   SRCFD
            bra   :opened
:havefile   lda   #1
            jsr   GETARG
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :opok
            jmp   :cantopen
:opok       lda   OPARM_REF
            sta   SRCFD
            lda   #1
            sta   ISFILE

:opened     stz   BUFPOS
            stz   BUFLEN
            stz   NNODES
            stz   NEDGES
            stz   PENDING
            jsr   PARSE
            lda   PENDING
            beq   :parseok
            jmp   :oddexit

:parseok    jsr   TOPOSORT
            lda   ISFILE
            beq   :noclose
            lda   SRCFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            bcs   :wrerr
:noclose    lda   CYCLEFLAG
            jsr   EXIT

:wrerr      lda   #1
            jsr   EXIT

:cantopen   lda   #<CANTOPEN
            sta   PTR0
            lda   #>CANTOPEN
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   GETARG
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            jsr   EXIT

:oddexit    lda   #<ODDMSG
            sta   PTR0
            lda   #>ODDMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

:usage      lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

            put   tsortp.s


*---------------------------------------------------------------
* TOPOSORT -- Kahn's algorithm over NAMETAB/EDGEFROM/EDGETO;
* prints one node name per line to stdout. OUT: CYCLEFLAG = 1 if
* any step had to force a non-free node. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
TOPOSORT    ldx   #0
:tinit      cpx   NNODES
            bcs   :tinitd
            stz   INDEG,x
            stz   OUTFLAG,x
            inx
            bra   :tinit
:tinitd     ldx   #0
:tedg       cpx   NEDGES
            bcs   :tedgd
            lda   EDGETO,x
            tay
            lda   INDEG,y
            clc
            adc   #1
            sta   INDEG,y
            inx
            bra   :tedg
:tedgd      stz   CYCLEFLAG
            stz   WARNDONE
            stz   OUTCNT

:tsloop     lda   OUTCNT
            cmp   NNODES
            bcs   :tsdone
            jsr   FINDFREE
            bcs   :tshave
            jsr   FINDFORCE
            lda   #1
            sta   CYCLEFLAG
            lda   WARNDONE
            bne   :tshave
            lda   #1
            sta   WARNDONE
            stx   CHOSEN
            jsr   CYCLEWARN
            ldx   CHOSEN
:tshave     stx   CHOSEN
            lda   #1
            sta   OUTFLAG,x
            inc   OUTCNT
            ldx   CHOSEN
            jsr   EMITNODE
            ldx   CHOSEN
            jsr   DECSUCC
            jmp   :tsloop
:tsdone     rts

*---------------------------------------------------------------
* FINDFREE -- OUT: carry SET and X = the first node (table
* order) with OUTFLAG=0 and INDEG=0; carry CLEAR if none.
* CLOBBERS: A, X.
*---------------------------------------------------------------
FINDFREE    ldx   #0
:ffloop     cpx   NNODES
            bcs   :ffnone
            lda   OUTFLAG,x
            bne   :ffnext
            lda   INDEG,x
            bne   :ffnext
            sec
            rts
:ffnext     inx
            bra   :ffloop
:ffnone     clc
            rts

*---------------------------------------------------------------
* FINDFORCE -- OUT: X = the first node (table order) with
* OUTFLAG=0. Assumes at least one exists (caller's OUTCNT<NNODES
* guard). CLOBBERS: A, X.
*---------------------------------------------------------------
FINDFORCE   ldx   #0
:fcloop     lda   OUTFLAG,x
            beq   :fcfound
            inx
            bra   :fcloop
:fcfound    rts

*---------------------------------------------------------------
* EMITNODE -- IN: X = node index. Prints its name and a CR to
* stdout. CLOBBERS: A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
EMITNODE    jsr   NODEPTR
            lda   PTR1
            sta   PTR0
            lda   PTR1+1
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            rts

*---------------------------------------------------------------
* DECSUCC -- IN: X = a node just output. For every edge whose
* source is X, decrements the target's INDEG. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
DECSUCC     stx   DS_SRC
            ldx   #0
:dsloop     cpx   NEDGES
            bcs   :dsdone
            lda   EDGEFROM,x
            cmp   DS_SRC
            bne   :dsnext
            lda   EDGETO,x
            tay
            lda   INDEG,y
            sec
            sbc   #1
            sta   INDEG,y
:dsnext     inx
            bra   :dsloop
:dsdone     rts

*---------------------------------------------------------------
* CYCLEWARN -- "tsort: cycle in data" and every still-unresolved
* node name (OUTFLAG=0), to stderr. CLOBBERS:
* A, X, Y, PTR0, PTR1.
*---------------------------------------------------------------
CYCLEWARN   lda   #<CYCMSG
            sta   PTR0
            lda   #>CYCMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            ldx   #0
:cwloop     cpx   NNODES
            bcs   :cwdone
            lda   OUTFLAG,x
            bne   :cwnext
            stx   CW_IDX
            jsr   NODEPTR
            lda   PTR1
            sta   PTR0
            lda   PTR1+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            ldx   CW_IDX
:cwnext     inx
            bra   :cwloop
:cwdone     rts

*---------------------------------------------------------------
* GETBYTE / REFILL -- buffered input, same shape as head.s/nl.s.
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

USAGEMSG    asc   "usage: tsort [file]"
            dfb   $8D,$00
CANTOPEN    asc   "tsort: cannot open "
            dfb   $00
ODDMSG      asc   "tsort: odd number of tokens"
            dfb   $8D,$00
CYCMSG      asc   "tsort: cycle in data"
            dfb   $00

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
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* tsort's own scalars, `dum`/`dend` off LIBA_BSSEND -- no `ds`
* zeros needed (docs/STICKY.md sec 21): every cell below is
* write-before-read.
*  - SRCFD/ISFILE: written on both the stdin and opened-file
*    paths before :opened.
*  - BUFPOS/BUFLEN/NNODES/NEDGES/PENDING: `stz`'d at :opened,
*    before PARSE's first call.
*  - FIRSTIDX: PARSE's own store, before the second-token branch
*    reads it.
*  - TOKLEN/TOKEOF/TOKBUF: READTOK's own fills, every call.
*  - NP_HI: NODEPTR's own store, every call, before its own
*    read.
*  - AE_TMP: ADDEDGE's own store, immediately read back.
*  - CYCLEFLAG/WARNDONE/OUTCNT: `stz`'d at TOPOSORT's own start.
*  - INDEG/OUTFLAG: TOPOSORT's own init loop, before any read.
*  - CHOSEN: `stx`'d at :tshave before every later read in that
*    same iteration.
*  - DS_SRC: DECSUCC's own store, before its own loop reads it.
*  - CW_IDX: CYCLEWARN's own store, saved across NODEPTR/PUTS/
*    PUTC and reloaded right after.
*  - PATHBUF: MKPATH writes chars then the count byte.
*  - CBUF: filled by SC_READ, indexed only below BUFLEN.
*  - NAMETAB/EDGEFROM/EDGETO: written by SLOTSET/ADDEDGE before
*    TOPOSORT (which runs only after PARSE returns) ever reads
*    them.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
SRCFD       ds    1
ISFILE      ds    1
BUFPOS      ds    1
BUFLEN      ds    1
NNODES      ds    1
NEDGES      ds    1
PENDING     ds    1
FIRSTIDX    ds    1
TOKLEN      ds    1
TOKEOF      ds    1
NP_HI       ds    1
AE_TMP      ds    1
CYCLEFLAG   ds    1
WARNDONE    ds    1
OUTCNT      ds    1
CHOSEN      ds    1
DS_SRC      ds    1
CW_IDX      ds    1

TOKBUF      ds    TS_TOKCAP
PATHBUF     ds    65
CBUF        ds    BUFSZ
NAMETAB     ds    TS_MAXN*TS_TOKCAP
EDGEFROM    ds    TS_MAXE
EDGETO      ds    TS_MAXE
INDEG       ds    TS_MAXN
OUTFLAG     ds    TS_MAXN
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 is the top of the process window.
            err   */$BF00
            dend
