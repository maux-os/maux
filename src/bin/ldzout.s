*---------------------------------------------------------------
* ldzout.s -- the streaming linker's OUTPUT side: the -z
* pending-zero writer (ZWRITE/FLUSHZ), the raw write (WRITEIO),
* and the output file's open/finish/abort. Split from
* ldstream.s for `as`'s source window (resident + LARGEST single
* put <= 16,128 B): ldstream.s alone was 11,726 B stripped and
* put ld.s 364 B over, which would have dropped LD from the `as`
* self-host sweep. Cut at a top-level label with no `:local`
* zone straddling it, `put` immediately after ldstream.s.
*---------------------------------------------------------------

*---------------------------------------------------------------
* ZWRITE -- append ND_TMP bytes at (ND_TMP2) to the output,
* under the -z rule (see the header). Clobbers ND_TMP/ND_TMP2/
* ND_DST/ND_TGT.
*---------------------------------------------------------------
ZWRITE      lda   ZFLAG
            bne   :z
*-- -z off: everything goes out
            lda   ND_TMP2
            sta   WPARM_BUF
            lda   ND_TMP2+1
            sta   WPARM_BUF+1
            lda   ND_TMP
            sta   WPARM_REQ
            lda   ND_TMP+1
            sta   WPARM_REQ+1
            jmp   WRITEIO
*-- find the last nonzero byte, scanning back from the end
:z          lda   ND_TMP
            sta   ND_DST
            lda   ND_TMP+1
            sta   ND_DST+1
:scan       lda   ND_DST
            ora   ND_DST+1
            beq   :allzero
            lda   ND_DST
            bne   :s1
            dec   ND_DST+1
:s1         dec   ND_DST
            clc
            lda   ND_TMP2
            adc   ND_DST
            sta   ND_TGT
            lda   ND_TMP2+1
            adc   ND_DST+1
            sta   ND_TGT+1
            ldy   #0
            lda   (ND_TGT),y
            beq   :scan
*-- byte ND_DST is the last nonzero: the pending run is real,
*-- then bytes 0..ND_DST go out, then the rest is the new run
*-- this module is not all-zero
            lda   #1
            sta   MODNZ
            jsr   FLUSHZ
            bcs   :fail
            inc   ND_DST
            bne   :n1
            inc   ND_DST+1
:n1         sec
            lda   ND_TMP
            sbc   ND_DST
            sta   ZRUN
            lda   ND_TMP+1
            sbc   ND_DST+1
            sta   ZRUN+1
            lda   ND_TMP2
            sta   WPARM_BUF
            lda   ND_TMP2+1
            sta   WPARM_BUF+1
            lda   ND_DST
            sta   WPARM_REQ
            lda   ND_DST+1
            sta   WPARM_REQ+1
            jmp   WRITEIO
:allzero    clc
            lda   ZRUN
            adc   ND_TMP
            sta   ZRUN
            lda   ZRUN+1
            adc   ND_TMP+1
            sta   ZRUN+1
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* FLUSHZ -- write the pending zero run, 256 bytes at a time
* from ZEROS (cleared at START; the arena is not).
*---------------------------------------------------------------
FLUSHZ      lda   ZRUN
            ora   ZRUN+1
            beq   :done
            lda   ZRUN+1
            beq   :rest
            stz   WPARM_REQ          ;256
            lda   #1
            sta   WPARM_REQ+1
            bra   :go
:rest       lda   ZRUN
            sta   WPARM_REQ
            stz   WPARM_REQ+1
:go         lda   #<ZEROS
            sta   WPARM_BUF
            lda   #>ZEROS
            sta   WPARM_BUF+1
            jsr   WRITEIO
            bcs   :fail
            sec
            lda   ZRUN
            sbc   WPARM_REQ
            sta   ZRUN
            lda   ZRUN+1
            sbc   WPARM_REQ+1
            sta   ZRUN+1
            bra   FLUSHZ
:done       clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* WRITEIO -- SC_WRITE WPARM_REQ bytes at WPARM_BUF to OUTFD; a
* short write is a failure, not a partial success.
*---------------------------------------------------------------
WRITEIO     lda   OUTFD
            sta   WPARM_REF
            lda   #<WPARM
            ldx   #>WPARM
            jsr   SC_WRITE
            bcs   :fail
            lda   WPARM_TRN
            cmp   WPARM_REQ
            bne   :fail
            lda   WPARM_TRN+1
            cmp   WPARM_REQ+1
            bne   :fail
            clc
            rts
:fail       jsr   ERR_WRITE
            sec
            rts

*---------------------------------------------------------------
* OPENOUT -- create the output (an EXISTING file is destroyed
* first: writing a shorter image over a longer file would leave
* the old tail behind it) and open it for pass 2's appends.
*---------------------------------------------------------------
OPENOUT     jsr   OUTPATH
            lda   #<DPARM
            ldx   #>DPARM
            jsr   SC_UNLINK          ;absent is fine
            jsr   MAKEFILE
            bcs   :fail
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   :fail
            lda   OPARM_REF
            sta   OUTFD
            lda   #1
            sta   OUTOPEN
            stz   ZRUN
            stz   ZRUN+1
            clc
            rts
:fail       jsr   ERR_WRITE
            sec
            rts

*---------------------------------------------------------------
* OUTPATH -- PATHBUF = the -o operand (OPENMOD reuses PATHBUF
* for every module, so the output path is rebuilt on demand).
*---------------------------------------------------------------
OUTPATH     lda   OBJPTR
            sta   PTR0
            lda   OBJPTR+1
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jmp   MKPATH

*---------------------------------------------------------------
* FINISHOUT -- the link is complete: the pending zero run (if
* any) is the trailing span -z drops. Close the output.
*---------------------------------------------------------------
FINISHOUT   jsr   CLOSEOUT
            bcs   :fail
            clc
            rts
:fail       jsr   ERR_WRITE
            sec
            rts

*---------------------------------------------------------------
* ABORTOUT -- a pass-2 refusal: close and DESTROY the partial
* output, so a failed link leaves no file that looks linked
* (check-ld's NOLIB contract, kept for the streaming writer).
*---------------------------------------------------------------
ABORTOUT    lda   OUTOPEN
            beq   :done
            jsr   CLOSEOUT
            jsr   OUTPATH
            lda   #<DPARM
            ldx   #>DPARM
            jsr   SC_UNLINK
:done       rts

CLOSEOUT    stz   OUTOPEN
            lda   OUTFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jmp   SC_CLOSE
