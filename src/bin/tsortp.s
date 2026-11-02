*---------------------------------------------------------------
* tsortp.s -- tsort's token-parsing engine: PARSE/SKIPWS/
* READTOK/LOOKUPADD/NODEPTR/SLOTCMP/SLOTSET/ADDEDGE. `put` by
* src/bin/tsort.s (NOT a standalone binary -- the same put-
* module shape as cut.s's own cutlist.s), split from tsort.s
* because tsort.s's own resident text alone was over the
* 16,128-byte check-dialect as-window budget (16,435 B
* stripped, 309 over). Every symbol here resolves against
* tsort.s's own equates (TS_MAXN/TS_MAXE/TS_TOKCAP) and data
* (NNODES/NEDGES/PENDING/FIRSTIDX/TOKLEN/TOKEOF/TOKBUF/NAMETAB/
* EDGEFROM/EDGETO/NP_HI/AE_TMP) and GETBYTE -- see that file's
* own header for the parse/tie-break rules this codifies.
*---------------------------------------------------------------
*---------------------------------------------------------------
* PARSE -- read every whitespace/CR-delimited token pair from
* SRCFD, building NAMETAB/EDGEFROM/EDGETO. OUT: PENDING = 1 if
* the input held an odd number of tokens (an unpaired trailing
* token), 0 if every token paired off. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PARSE       stz   PENDING
:ploop      jsr   SKIPWS
            bcs   :pdone
            jsr   READTOK
            jsr   LOOKUPADD
            ldx   PENDING
            bne   :second
            sta   FIRSTIDX
            lda   #1
            sta   PENDING
            bra   :pcont
:second     cmp   FIRSTIDX
            beq   :selfpr
            jsr   ADDEDGE
:selfpr     stz   PENDING
:pcont      lda   TOKEOF
            bne   :pdone
            jmp   :ploop
:pdone      rts

*---------------------------------------------------------------
* SKIPWS -- consume $8D/$A0/$89 bytes. OUT: carry CLEAR and A =
* the first non-whitespace byte found; carry SET = EOF, no more
* tokens. CLOBBERS: A, X, Y (via GETBYTE).
*---------------------------------------------------------------
SKIPWS      jsr   GETBYTE
            bcs   :swend
            cmp   #$8D
            beq   SKIPWS
            cmp   #$0D             ;either terminator ends a
            beq   SKIPWS         ;line -- a foreign file
            cmp   #$A0
            beq   SKIPWS
            cmp   #$89
            beq   SKIPWS
            cmp   #$20             ;the LOW twins, from a file
            beq   SKIPWS             ;from outside maux
            cmp   #$09
            beq   SKIPWS
            clc
            rts
:swend      sec
            rts

*---------------------------------------------------------------
* READTOK -- IN: A = the token's first byte (SKIPWS already read
* it). Reads further bytes from SRCFD into TOKBUF/TOKLEN until a
* delimiter or EOF, NUL-terminates. OUT: TOKEOF = 1 if the
* source is now exhausted (this was the last token). CLOBBERS:
* A, X, Y.
*---------------------------------------------------------------
READTOK     ldx   #0
            stx   TOKLEN
            stz   TOKEOF
            cpx   #TS_TOKCAP-1
            bcs   :rtloop
            sta   TOKBUF,x
            inx
            stx   TOKLEN
:rtloop     jsr   GETBYTE
            bcs   :rteof
            cmp   #$8D
            beq   :rtend
            cmp   #$0D             ;either terminator ends a
            beq   :rtend         ;line -- a foreign file
            cmp   #$A0
            beq   :rtend
            cmp   #$89
            beq   :rtend
            cmp   #$20             ;the LOW twins, from a file
            beq   :rtend             ;from outside maux
            cmp   #$09
            beq   :rtend
            ldx   TOKLEN
            cpx   #TS_TOKCAP-1
            bcs   :rtloop
            sta   TOKBUF,x
            inx
            stx   TOKLEN
            bra   :rtloop
:rteof      lda   #1
            sta   TOKEOF
:rtend      ldx   TOKLEN
            lda   #0
            sta   TOKBUF,x
            rts

*---------------------------------------------------------------
* LOOKUPADD -- find TOKBUF in NAMETAB; add a new slot if absent.
* OUT: A = the node's index. CLOBBERS: A, X, Y, PTR1.
*---------------------------------------------------------------
LOOKUPADD   ldx   #0
:laloop     cpx   NNODES
            bcs   :ladd
            jsr   SLOTCMP
            bcs   :lafound
            inx
            bra   :laloop
:lafound    txa
            rts
:ladd       lda   NNODES
            cmp   #TS_MAXN
            bcs   :lafull
            tax
            jsr   SLOTSET
            lda   NNODES
            inc   NNODES
            rts
:lafull     lda   #TS_MAXN-1
            rts

*---------------------------------------------------------------
* NODEPTR -- IN: X = node index. OUT: PTR1 = NAMETAB + X*16.
* CLOBBERS: A, PTR1.
*---------------------------------------------------------------
NODEPTR     lda   #0
            sta   NP_HI
            txa
            asl   a
            rol   NP_HI
            asl   a
            rol   NP_HI
            asl   a
            rol   NP_HI
            asl   a
            rol   NP_HI
            clc
            adc   #<NAMETAB
            sta   PTR1
            lda   NP_HI
            adc   #>NAMETAB
            sta   PTR1+1
            rts

*---------------------------------------------------------------
* SLOTCMP -- IN: X = candidate node index. OUT: carry SET if
* NAMETAB[X] equals TOKBUF (both NUL-terminated). CLOBBERS:
* A, Y, PTR1.
*---------------------------------------------------------------
SLOTCMP     jsr   NODEPTR
            ldy   #0
:sccmp      lda   TOKBUF,y
            cmp   (PTR1),y
            bne   :scno
            lda   TOKBUF,y
            beq   :scyes
            iny
            cpy   #TS_TOKCAP-1
            bcs   :scyes
            bra   :sccmp
:scyes      sec
            rts
:scno       clc
            rts

*---------------------------------------------------------------
* SLOTSET -- IN: X = target node index. Copies TOKBUF (incl. its
* NUL) into NAMETAB[X]. CLOBBERS: A, Y, PTR1.
*---------------------------------------------------------------
SLOTSET     jsr   NODEPTR
            ldy   #0
:ssloop     lda   TOKBUF,y
            sta   (PTR1),y
            beq   :ssdone
            iny
            bra   :ssloop
:ssdone     rts

*---------------------------------------------------------------
* ADDEDGE -- IN: A = the second token's node index; FIRSTIDX
* holds the first's. Appends FIRSTIDX -> A. CLOBBERS: A, X.
*---------------------------------------------------------------
ADDEDGE     ldx   NEDGES
            cpx   #TS_MAXE
            bcs   :aefull
            sta   AE_TMP
            lda   FIRSTIDX
            sta   EDGEFROM,x
            lda   AE_TMP
            sta   EDGETO,x
            inc   NEDGES
:aefull     rts
