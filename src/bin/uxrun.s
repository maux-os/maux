*---------------------------------------------------------------
* uxrun.s -- unexpand's per-line engine: UXFD/PENDPUSH/PENDLIT/
* FLUSHRUN/ISSTOP/NEXTSTOP/PERSTOP. `put` by src/bin/unexpand.s
* (NOT a standalone binary -- the same put-module shape as
* cut.s's own cutlist.s), split out for the same reason units
* split anywhere: `as`'s 16,128-byte source window holds the
* resident manifest plus one put file at a time, and
* unexpand.s's own text alone was past it (measured: 16,572 B
* stripped, over by 446). Every symbol here resolves against
* unexpand.s's own equates (TABCH/BSCH/BLANKSP/PENDCAP), zero
* page pointers, and data (BUFPOS/BUFLEN/COL/PENDCNT/PASSTHRU/
* UBYTE/TABCNT/TABSTOPS/TMPN/TMPR/NEWCOL/IS_VAL/PP_BYTE/PENDBUF)
* and GETBYTE/FD_STDOUT -- see that file's own header for the
* run/backspace/carry-over rules this codifies.
*---------------------------------------------------------------
*---------------------------------------------------------------
* UXFD -- unexpand SRCFD to stdout. Resets ALL per-file state:
* COL/PENDCNT/PASSTHRU (this tool's own COL DOES reset per
* file -- see this file's header, the opposite of expand.s).
*---------------------------------------------------------------
UXFD        stz   BUFPOS
            stz   BUFLEN
            stz   COL
            stz   PENDCNT
            stz   PASSTHRU
:uloop      jsr   GETBYTE
            bcc   :ugotbyte
            jmp   :ueofchk          ;bcs's own +/-127 range
                                    ;can't reach :ueofchk once
                                    ;this routine grew past it,
                                    ;so jmp -- same trampoline
                                    ;shape as getopt.s's
                                    ;:takesarg
:ugotbyte   sta   UBYTE             ;the fetched byte MUST
                                    ;survive every classify step
                                    ;below -- GETOPT's own trap
                                    ;(house rule: nothing
                                    ;indexed or compared later
                                    ;trusts A or X across a jsr)
                                    ;applies to a plain `lda`
                                    ;overwrite too
            cmp   #$8D
            bne   :unotcr
            jmp   :ucr              ;beq's own range can't
                                    ;reach :ucr this far down --
                                    ;same trampoline shape
:unotcr     lda   PASSTHRU
            beq   :uchkbl
            lda   UBYTE
            ldx   #FD_STDOUT
            jsr   PUTC
            jmp   :uloop
:uchkbl     lda   UBYTE
            cmp   #BLANKSP
            beq   :isblank
            cmp   #TABCH
            beq   :isblank
            cmp   #BSCH
            beq   :isblank
            jmp   :nonblank
:isblank    lda   PENDCNT           ;capture the column the RUN
            bne   :isb2             ;began at, once, on its own
            lda   COL               ;first byte -- FLUSHRUN's
            sta   RUNSTCOL          ;replay starts from here (a
:isb2       lda   UBYTE             ;WHOLE-RUN decision, not one
            jsr   PENDPUSH          ;made byte by byte -- see
            lda   UBYTE             ;that routine's header)
            cmp   #TABCH
            beq   :ubtab
            cmp   #BSCH
            beq   :ubbs
            lda   COL
            cmp   #250
            bcs   :ucont
            inc   COL
            bra   :ucont
:ubbs       lda   COL
            beq   :ucont
            dec   COL
            bra   :ucont
:ubtab      jsr   NEXTSTOP          ;-> NEWCOL
            lda   NEWCOL
            sta   COL
:ucont      jmp   :uloop

:nonblank   lda   PENDCNT
            beq   :nbdirect
            jsr   FLUSHRUN
:nbdirect   lda   UBYTE
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   COL
            cmp   #250
            bcs   :nbmark
            inc   COL
:nbmark     lda   WANT_A
            bne   :nbska
            lda   #1
            sta   PASSTHRU
:nbska      jmp   :uloop

:ucr        lda   PENDCNT
            beq   :crdirect
            jsr   FLUSHRUN
:crdirect   lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            stz   COL
            stz   PENDCNT
            stz   PASSTHRU
            jmp   :uloop

:ueofchk    lda   PENDCNT
            beq   :udone
            jsr   FLUSHRUN
:udone      rts

*---------------------------------------------------------------
* PENDPUSH -- IN: A = the blank byte just classified. Appends it
* to PENDBUF (silently drops past PENDCAP -- a defensive check;
* MAXWIDTH<=PENDCAP keeps this from firing in practice) and
* returns A unchanged so the caller's own `cmp` chain still
* works.
*---------------------------------------------------------------
PENDPUSH    sta   PP_BYTE
            ldy   PENDCNT
            cpy   #PENDCAP
            bcs   :ppfull
            sta   PENDBUF,y
:ppfull     inc   PENDCNT
            lda   PP_BYTE
            rts

*---------------------------------------------------------------
* PENDLIT -- flush PENDBUF[0..PENDCNT) to stdout byte-for-byte
* (a run that never reached a stop, or was interrupted by a
* non-blank/CR/EOF) and reset PENDCNT.
*---------------------------------------------------------------
PENDLIT     ldy   #0
:plloop     cpy   PENDCNT
            bcs   :pldone
            lda   PENDBUF,y
            phy
            ldx   #FD_STDOUT
            jsr   PUTC
            ply
            iny
            bra   :plloop
:pldone     stz   PENDCNT
            rts

*---------------------------------------------------------------
* FLUSHRUN -- the blank run just ended (a non-blank, CR, or EOF
* was reached). REAL BUG, found live: an earlier version decided
* "convert to a tab?" separately at EACH stop crossing, using
* the byte count accumulated SINCE THE LAST conversion -- but
* this host's own unexpand decides "is this run long enough to
* convert AT ALL?" ONCE, over the run's TOTAL length, and then
* converts EVERY crossing within a qualifying run, even one
* whose own segment is a single byte. Measured live: "1234567"
* (col 7) + two spaces -- the FIRST space alone reaches column
* 8, a stop, with only 1 byte in that segment -- becomes "\t "
* (a tab for the first space, a literal space for the second),
* NOT left unconverted (the old bug) and NOT collapsed to one
* bare tab either. A single-space run landing on a stop (no
* second byte at all) still never converts, matching the
* earlier "one byte for one byte saves nothing" case -- that is
* the run-length<2 test below, now applied to the WHOLE run
* rather than a per-crossing count.
*
* PENDCNT<2: the whole run is too short to ever qualify --
* PENDLIT emits it byte for byte, unchanged.
*
* PENDCNT>=2: REPLAY the buffered run from RUNSTCOL (the column
* the run began at), reusing COL/NEXTSTOP/ISSTOP exactly as the
* main loop's own per-byte column math does (COL is safe to
* borrow here -- see below). Each time the replayed column lands
* on a stop, the buffered bytes since the last such landing (as
* few as one) become a single tab; whatever is left over at the
* end of the buffer, never having reached a further stop, is
* copied out literally. Fold.s's own CARRYOVER is the same shape
* (buffer now, recompute column on replay).
*
* COL is genuinely safe to overwrite and replay through: by the
* time FLUSHRUN runs, COL already holds the CORRECT column for
* every byte up to and including the run's last one (the main
* loop advanced it byte by byte as the run was scanned) -- so
* replaying the SAME bytes from the SAME starting column through
* the SAME advance rules necessarily recomputes that identical
* final value. Nothing after FLUSHRUN returns needs COL to hold
* anything mid-replay ever saw.
*---------------------------------------------------------------
FLUSHRUN    lda   PENDCNT
            cmp   #2
            bcs   :frmany
            jsr   PENDLIT
            rts
:frmany     lda   RUNSTCOL
            sta   COL
            stz   SEGSTART
            stz   RIDX
:frloop     lda   RIDX
            cmp   PENDCNT
            bcs   :frtail
            ldy   RIDX
            lda   PENDBUF,y
            cmp   #TABCH
            beq   :frtab
            cmp   #BSCH
            beq   :frbs
            lda   COL
            cmp   #250
            bcs   :frck
            inc   COL
            bra   :frck
:frbs       lda   COL
            beq   :frck
            dec   COL
            bra   :frck
:frtab      jsr   NEXTSTOP          ;-> NEWCOL
            lda   NEWCOL
            sta   COL
:frck       lda   COL
            jsr   ISSTOP
            bcc   :frnext
            lda   #TABCH
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   RIDX
            clc
            adc   #1
            sta   SEGSTART
:frnext     inc   RIDX
            bra   :frloop
:frtail     ldy   SEGSTART
:ftloop     cpy   PENDCNT
            bcs   :ftdone
            lda   PENDBUF,y
            phy
            ldx   #FD_STDOUT
            jsr   PUTC
            ply
            iny
            bra   :ftloop
:ftdone     stz   PENDCNT
            rts

*---------------------------------------------------------------
* ISSTOP -- IN: A = a candidate column. OUT: carry SET if that
* column is exactly one of the configured stops (periodic:
* divisible by TABSTOPS[0]; list: an exact array member -- NOT
* "past the last one", so a run beyond an explicit list's last
* stop never converts, same reasoning as expand.s's own past-
* last-stop rule).
*---------------------------------------------------------------
ISSTOP      sta   IS_VAL
            lda   TABCNT
            cmp   #1
            beq   :isper
            ldx   #0
:isllp      cpx   TABCNT
            bcs   :isno
            lda   TABSTOPS,x
            cmp   IS_VAL
            beq   :isyes
            inx
            bra   :isllp
:isper      lda   TABSTOPS
            sta   TMPN
            lda   IS_VAL
:ismodlp    cmp   TMPN
            bcc   :ismodok
            sec
            sbc   TMPN
            bra   :ismodlp
* REAL BUG, found live: `:ismodok` used to `bne :isno` straight
* off the loop-exit `cmp TMPN` above -- that flag reflects
* (remainder == TMPN), not (remainder == 0). For COL=8 against
* TABSTOPS[0]=8 the remainder is 0 but 0<>8, so Z was CLEAR and
* an exact stop read as "not a stop" on every single call --
* unexpand never converted anything, ever (both the default and
* -a paths share this one routine). A still holds the remainder
* here, untouched by the branch; `cmp #0` tests IT.
:ismodok    cmp   #0
            bne   :isno
:isyes      sec
            rts
:isno       clc
            rts

*---------------------------------------------------------------
* NEXTSTOP -- IN: COL. OUT: NEWCOL = column after a tab from
* COL (used only for an actual TAB byte in the input -- same
* math as expand.s's own NEXTSTOP/PERSTOP).
*---------------------------------------------------------------
NEXTSTOP    lda   TABCNT
            cmp   #1
            beq   PERSTOP
            ldx   #0
:lloop      cpx   TABCNT
            bcs   :lpast
            lda   TABSTOPS,x
            cmp   COL
            bcc   :lnext
            beq   :lnext
            sta   NEWCOL
            rts
:lnext      inx
            bra   :lloop
:lpast      lda   COL
            clc
            adc   #1
            sta   NEWCOL
            rts

PERSTOP     lda   TABSTOPS
            sta   TMPN
            lda   COL
:modlp      cmp   TMPN
            bcc   :modok
            sec
            sbc   TMPN
            bra   :modlp
:modok      sta   TMPR
            lda   TMPN
            sec
            sbc   TMPR
            clc
            adc   COL
            sta   NEWCOL
            rts
