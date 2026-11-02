*---------------------------------------------------------------
* mldload.s -- LD_JRLOAD and its helpers: the streaming module
* loader that replaces Merlin's RLOAD.
*
* SPLIT OUT OF ld.s (S9 L5, 2026-08-30). Streaming the module
* code rather than staging it whole took ~440 lines, which
* pushed
* ld.s's `resident + largest put` past real Merlin's 41,215-byte
* source buffer -- where it would have died with "56 MEMORY IN
* USE", check-dialect's hazard 3. The cut is at a section
* boundary and this file is `put` where the routine used to sit,
* so the emitted bytes do not move.
*---------------------------------------------------------------
*---------------------------------------------------------------
* LD_JRLOAD ($B218) -- replaces RLOAD entirely (LD-A3: RLOAD
* bypasses ENTRY with its own SETBNK/MAINZP/AUXZP sequence, so
* there is nothing of the real routine to reuse). IN (per
* LINKER.S:83-106): DOSFNAM = the module's pathname (high-bit,
* already copied by LINKER's own `:MV` loop), RWBUF = SPNT = the
* destination address for the code portion. OUT (per LINKER.S:
* 107-121, read back immediately after this returns): RWGOT =
* code
* bytes actually transferred, BLEN = the module's total (code +
* dictionary) byte length. Leaves the file OPEN (MODFD) for
* subsequent GENTRY reads via ENT_RDMOD above, matching real
* RLOAD's own "leave file open for RLOAD" contract.
*---------------------------------------------------------------
LD_JRLOAD   jsr   STRIPFNAM
            lda   #<DOSFNAM
            sta   GFIPARM_PATH
            lda   #>DOSFNAM
            sta   GFIPARM_PATH+1
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcc   :gfiok
            jmp   :openfail
:gfiok      lda   GFIPARM_AUX
            sta   MODCODELEN
            lda   GFIPARM_AUX+1
            sta   MODCODELEN+1

            lda   #<DOSFNAM
            sta   MODOPARM_PATH
            lda   #>DOSFNAM
            sta   MODOPARM_PATH+1
            lda   #<MODOPARM
            ldx   #>MODOPARM
            jsr   SC_OPEN
            bcc   :opok
            jmp   :openfail
:opok       lda   MODOPARM_REF
            sta   MODFD
            sta   MODRPARM_REF

*-- STREAMED, NOT STAGED (S9 L5). This used to read the WHOLE
*-- module into MODBUF and then BLOCKCP its code portion to the
*-- destination, which made MODBUF as big as the largest module
*-- (7,936 B + a 512 B guard). The linked image accumulates
*-- above that arena, so those 8.4 KB came straight out of the
*-- build window -- and the build window is the one thing
*-- standing between maux and linking its own kernel.
*--
*-- Now the CODE is streamed through a MODCHUNK-sized slice of
*-- MODBUF, copied on to the destination piece by piece, and
*-- only the DICTIONARY is buffered whole (measured: 12 B to
*-- ~2 KB, against the 7,936 B the old shape reserved). MODBUF
*-- shrinks to the dictionary's needs and BUILDBASE drops by
*-- what that frees.
*--
*-- MODPOS and MODLEN keep their FILE-OFFSET meaning, because
*-- LINKER.S reads BLEN as the module's total length -- so
*-- ENT_RDMOD subtracts MODCODELEN when it indexes MODBUF.
            lda   RWBUF_FLD
            sta   MODDST
            lda   RWBUF_FLD+1
            sta   MODDST+1
            lda   MODCODELEN
            sta   MODREM
            lda   MODCODELEN+1
            sta   MODREM+1

*-- BUILD-WINDOW CLAMP, computed once: MODALW is how many code
*-- bytes may actually land below BLDTOP. A pure-bss module
*-- placed past the ceiling is ALL ZEROS -- exactly what -z
*-- drops from the file anyway -- so under -z the overflow is
*-- verified zero as it streams past and not copied; anything
*-- nonzero out there, or any overflow without -z, refuses.
            lda   MODCODELEN
            sta   MODALW
            lda   MODCODELEN+1
            sta   MODALW+1
            clc
            lda   RWBUF_FLD
            adc   MODCODELEN
            tay
            lda   RWBUF_FLD+1
            adc   MODCODELEN+1
            cmp   #>BLDTOP
            bcc   :strloop
            bne   :clamp
            cpy   #<BLDTOP
            beq   :strloop
:clamp      lda   ZFLAG
            bne   :clampok           ;`bne` past a `jmp` -- the
            jmp   :imgbig            ;stream loop is long
:clampok    sec
            lda   #<BLDTOP
            sbc   RWBUF_FLD
            sta   MODALW
            lda   #>BLDTOP
            sbc   RWBUF_FLD+1
            sta   MODALW+1
            bcs   :strloop
            stz   MODALW
            stz   MODALW+1

:strloop    lda   MODREM
            ora   MODREM+1
            bne   :strmore
            jmp   :strdone
:strmore    lda   #<MODBUF
            sta   MODRPARM_BUF
            lda   #>MODBUF
            sta   MODRPARM_BUF+1
*-- REQUEST min(MODREM, MODCHUNK), NOT MODCHUNK. The file holds
*-- code THEN dictionary, so a blind 512-byte request on the
*-- last
*-- code chunk hands back dictionary bytes too -- which then get
*-- copied into the image while MODREM underflows past zero and
*-- the loop runs to EOF scribbling as it goes. Measured: RTLIB
*-- (68 code bytes) read 512, copied all 512, and both links
*-- produced no usable output at all.
            lda   MODREM+1
            cmp   #>MODCHUNK
            bcs   :reqfull
            lda   MODREM
            sta   MODRPARM_REQ
            lda   MODREM+1
            sta   MODRPARM_REQ+1
            bra   :reqset
:reqfull    lda   #<MODCHUNK
            sta   MODRPARM_REQ
            lda   #>MODCHUNK
            sta   MODRPARM_REQ+1
:reqset
            lda   #<MODRPARM
            ldx   #>MODRPARM
            jsr   SC_READ
            lda   MODRPARM_TRN
            ora   MODRPARM_TRN+1
            bne   :strgot
            jmp   :strdone            ;short file: nothing left
*-- MODAVL = min(bytes read, remaining clamp allowance)
:strgot     lda   MODRPARM_TRN
            sta   MODAVL
            lda   MODRPARM_TRN+1
            sta   MODAVL+1
            lda   MODALW+1
            cmp   MODAVL+1
            bcc   :useclamp
            bne   :haveavl
            lda   MODALW
            cmp   MODAVL
            bcs   :haveavl
:useclamp   lda   MODALW
            sta   MODAVL
            lda   MODALW+1
            sta   MODAVL+1
:haveavl    lda   MODAVL
            ora   MODAVL+1
            beq   :novfy
            lda   #<MODBUF
            sta   PTR0
            lda   #>MODBUF
            sta   PTR0+1
            lda   MODDST
            sta   PTR1
            lda   MODDST+1
            sta   PTR1+1
            lda   MODAVL
            sta   CPLEN
            lda   MODAVL+1
            sta   CPLEN+1
            jsr   BLOCKCP
            clc
            lda   MODDST
            adc   MODAVL
            sta   MODDST
            lda   MODDST+1
            adc   MODAVL+1
            sta   MODDST+1
            sec
            lda   MODALW
            sbc   MODAVL
            sta   MODALW
            lda   MODALW+1
            sbc   MODAVL+1
            sta   MODALW+1
*-- anything this chunk carried BEYOND the allowance must be
*-- zero
:novfy      sec
            lda   MODRPARM_TRN
            sbc   MODAVL
            sta   LDZVCNT
            lda   MODRPARM_TRN+1
            sbc   MODAVL+1
            sta   LDZVCNT+1
            lda   LDZVCNT
            ora   LDZVCNT+1
            beq   :stradv
            clc
            lda   #<MODBUF
            adc   MODAVL
            sta   PTR0
            lda   #>MODBUF
            adc   MODAVL+1
            sta   PTR0+1
:zvloop     lda   LDZVCNT
            ora   LDZVCNT+1
            beq   :stradv
            lda   (PTR0)
            bne   :imgbig
            inc   PTR0
            bne   :zv1
            inc   PTR0+1
:zv1        lda   LDZVCNT
            bne   :zv2
            dec   LDZVCNT+1
:zv2        dec   LDZVCNT
            bra   :zvloop
:stradv     sec
            lda   MODREM
            sbc   MODRPARM_TRN
            sta   MODREM
            lda   MODREM+1
            sbc   MODRPARM_TRN+1
            sta   MODREM+1
            jmp   :strloop
:imgbig     lda   #<TOOBIGIMG
            ldx   #>TOOBIGIMG
            jsr   DIAG1
            lda   #1
            jsr   EXIT

*-- the DICTIONARY, buffered whole at MODBUF -- this is the only
*-- part LINKER.S reads back at random through ENT_RDMOD
:strdone    lda   MODCODELEN
            sta   MODLEN
            lda   MODCODELEN+1
            sta   MODLEN+1
            stz   MODDICT
            stz   MODDICT+1
:dctloop    clc
            lda   MODDICT
            adc   #<MODBUF
            sta   MODRPARM_BUF
            lda   MODDICT+1
            adc   #>MODBUF
            sta   MODRPARM_BUF+1
*-- REQUEST ONLY WHAT STILL FITS, so the read cannot overrun
*-- MODBUF and no guard page is needed after it. That is what
*-- lets MODBUF use the whole span between the bridge stubs and
*-- Merlin's variables rather than surrendering 512 B of it.
            sec
            lda   #<MODBUF_CAP
            sbc   MODDICT
            sta   MODRPARM_REQ
            lda   #>MODBUF_CAP
            sbc   MODDICT+1
            sta   MODRPARM_REQ+1
            bcc   :dctfull
            lda   MODRPARM_REQ+1
            cmp   #>MODCHUNK
            bcc   :reqok
            lda   #<MODCHUNK
            sta   MODRPARM_REQ
            lda   #>MODCHUNK
            sta   MODRPARM_REQ+1
:reqok      lda   MODRPARM_REQ
            ora   MODRPARM_REQ+1
            beq   :dctfull
            lda   #<MODRPARM
            ldx   #>MODRPARM
            jsr   SC_READ
            lda   MODRPARM_TRN
            ora   MODRPARM_TRN+1
            beq   :dctdone
            clc
            lda   MODDICT
            adc   MODRPARM_TRN
            sta   MODDICT
            lda   MODDICT+1
            adc   MODRPARM_TRN+1
            sta   MODDICT+1
            clc
            lda   MODLEN
            adc   MODRPARM_TRN
            sta   MODLEN
            lda   MODLEN+1
            adc   MODRPARM_TRN+1
            sta   MODLEN+1
            jmp   :dctloop
:dctfull    lda   #<TOOBIGMOD
            ldx   #>TOOBIGMOD
            jsr   DIAG1
            lda   #1
            jsr   EXIT
:dctdone
* RWGOT (code length) = INFAUX, and BLEN = the module's TOTAL
* length, both as LINKER.S reads them back. MODPOS starts past
* the code portion, a file offset, ready for GENTRY.
            lda   MODCODELEN
            sta   RWGOT_FLD
            lda   MODCODELEN+1
            sta   RWGOT_FLD+1
            lda   MODLEN
            sta   BLEN_ADR
            lda   MODLEN+1
            sta   BLEN_ADR+1
            lda   MODCODELEN
            sta   MODPOS
            lda   MODCODELEN+1
            sta   MODPOS+1
*-- JRLOAD's contract: carry CLEAR on success. The core's SPNT
*-- advance is `LDA ADRS / ADC RWGOT` with NO CLC (LINKER.S:
*-- 107-111), and the clamp's sbc chains above exit carry SET.
            clc
            rts

* Module pathname is already high-bit-stripped by STRIPFNAM
* above (PUTS wants liba's own high-bit convention, so the
* pathname itself is not echoed here -- a fixed diagnostic is
* enough to satisfy the "missing module -> nonzero exit + an
* `ld:` diagnostic" bar; the failing pathname is still visible
* to the caller via its own argv).
:openfail   lda   #<CANTMOD
            ldx   #>CANTMOD
            jsr   DIAG1
            lda   #1
            jsr   EXIT
