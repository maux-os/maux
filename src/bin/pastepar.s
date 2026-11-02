*---------------------------------------------------------------
* pastepar.s -- paste's PARALLEL (non -s) mode: PARDISP/OPENALL/
* CLOSEALL/CBUFBASE/LBUFBASE/GETBYTEM/REFILLM/GETLINEM/
* EMITFIELDM/MERGERUN. `put` by src/bin/paste.s (NOT a
* standalone binary -- the same put-module shape as cut.s's own
* cutlist.s), split out for the same reason units split
* anywhere: `as`'s 16,128-byte source window holds the resident
* manifest plus one put file at a time, and paste.s's own text
* alone was past it (measured: 18,690 B stripped, over by
* 2,562). Every symbol here resolves against paste.s's own
* equates (MAXFILES/BUFSZ), zero-page pointers (PTR1/PTR2), data
* (SRCFDA/BUFPOSA/BUFLENA/EOFFLGA/LINELENA/CBUFALL/LBUFALL/
* CBB_IDX/LBB_IDX/EFM_LEN/FSLOT/NFILES/ARGIDX/OPTIND/DIDX/
* OPARM*/RPARM*/CPARM*/PATHBUF) and EMITDELIM/USAGEEXIT/
* TOOMANYERR/OPENMSG -- see that file's own header for the
* row/termination rule this codifies.
*---------------------------------------------------------------
*===============================================================
* PARALLEL MODE
*===============================================================
PARDISP     lda   NFILES
            cmp   #MAXFILES+1
            bcs   :toomany
            jsr   OPENALL
            jsr   MERGERUN
            jsr   CLOSEALL
            lda   #0
            jsr   EXIT
:toomany    jmp   TOOMANYERR

*---------------------------------------------------------------
* OPENALL -- open every operand into SRCFDA[0..NFILES-1] before
* any output happens. `-` means stdin. On the FIRST failure,
* prints one diagnostic and exits 1 -- see this file's header.
*
* FSLOT (a `dum` cell), NOT X, carries the file-slot index
* across this loop's body: GETARG's own body ends `asl a / tax`
* (src/liba/argv.s), so X comes back from EVERY GETARG call
* holding 2*ARGIDX, not whatever the caller had in it -- a real
* bug, found live (X=2 after the FIRST operand, then 3, instead
* of the expected 0 -- SRCFDA[2] got a real fd while SRCFDA[0]
* stayed 0, and the "first" operand read back as unopened).
* X is reloaded from FSLOT only in the instant before each
* indexed SRCFDA store, never trusted to survive a call.
*---------------------------------------------------------------
OPENALL     lda   OPTIND
            sta   ARGIDX
            stz   FSLOT
:oaloop     lda   ARGIDX
            jsr   GETARG
            ldy   #0
            lda   (PTR0),y
            cmp   #$AD
            bne   :oareal
            iny
            lda   (PTR0),y
            bne   :oareal
            lda   #FD_STDIN
            ldx   FSLOT
            sta   SRCFDA,x
            bra   :oanext
:oareal     lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   :oafail
            lda   OPARM_REF
            ldx   FSLOT
            sta   SRCFDA,x
:oanext     inc   ARGIDX
            inc   FSLOT
            lda   FSLOT
            cmp   NFILES
            bne   :oaloop
            rts
:oafail     lda   #<OPENMSG
            sta   PTR0
            lda   #>OPENMSG
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
            jsr   EXIT

*---------------------------------------------------------------
* CLOSEALL -- close every real (non-stdin) fd in SRCFDA.
*---------------------------------------------------------------
CLOSEALL    ldx   #0
:caloop     lda   SRCFDA,x
            cmp   #FD_STDIN
            beq   :canext
            sta   CPARM_REF
            phx
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            plx
:canext     inx
            cpx   NFILES
            bne   :caloop
            rts

*---------------------------------------------------------------
* CBUFBASE -- IN: A = file index 0..MAXFILES-1. OUT: PTR2 =
* CBUFALL + A*256 (each file's 256-byte read-chunk buffer sits
* on its own page boundary offset, so the multiply is just
* "add the index to the high byte"). CLOBBERS: A.
*---------------------------------------------------------------
CBUFBASE    sta   CBB_IDX
            lda   #<CBUFALL
            sta   PTR2
            lda   #>CBUFALL
            clc
            adc   CBB_IDX
            sta   PTR2+1
            rts

*---------------------------------------------------------------
* LBUFBASE -- IN: A = file index. OUT: PTR1 = LBUFALL + A*256,
* same trick as CBUFBASE. CLOBBERS: A.
*---------------------------------------------------------------
LBUFBASE    sta   LBB_IDX
            lda   #<LBUFALL
            sta   PTR1
            lda   #>LBUFALL
            clc
            adc   LBB_IDX
            sta   PTR1+1
            rts

*---------------------------------------------------------------
* GETBYTEM -- IN: X = file index. OUT: A = byte, carry clear; or
* carry set = EOF on that file. PRESERVES: X.
*---------------------------------------------------------------
GETBYTEM    lda   BUFPOSA,x
            cmp   BUFLENA,x
            bcc   :have
            jsr   REFILLM
            bcs   :eof
:have       txa
            pha
            jsr   CBUFBASE
            pla
            tax
            ldy   BUFPOSA,x
            lda   (PTR2),y
            inc   BUFPOSA,x
            clc
            rts
:eof        sec
            rts

*---------------------------------------------------------------
* REFILLM -- IN: X = file index. Refills that file's CBUF chunk.
* PRESERVES: X.
*---------------------------------------------------------------
REFILLM     lda   SRCFDA,x
            sta   RPARM_REF
            txa
            pha
            jsr   CBUFBASE
            lda   PTR2
            sta   RPARM_BUF
            lda   PTR2+1
            sta   RPARM_BUF+1
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            pla
            tax
            bcs   :eof
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :eof
            lda   RPARM_TRANS
            sta   BUFLENA,x
            stz   BUFPOSA,x
            clc
            rts
:eof        sec
            rts

*---------------------------------------------------------------
* GETLINEM -- IN: X = file index. Fills that file's LBUF chunk
* and LINELENA,x with the next CR-terminated line (truncated at
* LINEMAX, same rule as cut.s's GETLINE). OUT: carry clear = a
* line is ready; carry set = EOF, nothing pending. PRESERVES: X.
*---------------------------------------------------------------
GETLINEM    stz   LINELENA,x
            txa
            jsr   LBUFBASE
:gloop      jsr   GETBYTEM
            bcs   :gleof
            cmp   #$8D
            beq   :glhave
            ldy   LINELENA,x
            cpy   #LINEMAX
            bcs   :gloop
            sta   (PTR1),y
            inc   LINELENA,x
            bra   :gloop
:glhave     clc
            rts
:gleof      lda   LINELENA,x
            beq   :glnone
            clc
            rts
:glnone     sec
            rts

*---------------------------------------------------------------
* EMITFIELDM -- IN: X = file index. Print LBUF(X)[0..LINELENA).
* PRESERVES: X.
*---------------------------------------------------------------
EMITFIELDM  phx
            lda   LINELENA,x
            sta   EFM_LEN
            txa
            jsr   LBUFBASE
            ldy   #0
:eloop      cpy   EFM_LEN
            bcs   :edone
            lda   (PTR1),y
            phy
            ldx   #FD_STDOUT
            jsr   PUTC
            ply
            iny
            bra   :eloop
:edone      plx
            rts

*---------------------------------------------------------------
* MERGERUN -- the parallel-merge main loop. See this file's
* header for the row/termination rule.
*---------------------------------------------------------------
MERGERUN    ldx   #0
:initlp     stz   BUFPOSA,x
            stz   BUFLENA,x
            stz   EOFFLGA,x
            inx
            cpx   NFILES
            bne   :initlp

:roundloop  stz   PRODUCED
            ldx   #0
:fieldloop  lda   EOFFLGA,x
            bne   :fldempty
            jsr   GETLINEM
            bcc   :fldgot
            lda   #1
            sta   EOFFLGA,x
            stz   LINELENA,x
            bra   :fldnext
:fldgot     lda   #1
            sta   PRODUCED
            bra   :fldnext
:fldempty   stz   LINELENA,x
:fldnext    inx
            cpx   NFILES
            bne   :fieldloop

            lda   PRODUCED
            beq   :mergedone
            stz   DIDX
            ldx   #0
:emitloop   jsr   EMITFIELDM
            inx
            cpx   NFILES
            beq   :emitlast
            jsr   EMITDELIM
            bra   :emitloop
:emitlast   lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            jmp   :roundloop
:mergedone  rts
