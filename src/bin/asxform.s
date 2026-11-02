*---------------------------------------------------------------
* asxform.s -- RDXFORM -- fd-to-Merlin-shape source reader.
* SPLIT OUT of as.s 2026-09-01 (S9-PLAN 6b stage C): the
* resident main was 21,768 B stripped against as's own
* 16,126 B source window, so it could not assemble itself.
* Body put, same module -- put in place, no byte moves.
* Cut at zone-safe global-label boundaries (scan-verified).
*---------------------------------------------------------------
* RDXFORM -- read an already-open fd to EOF into (PTR0),
* transforming to Merlin's on-disk shape as it goes: $0D/$0A
* each become one $8D, every other byte is OR'd with $80.
*
* Factored 2026-08-28 out of the main source read, because
* AS_GOREAD needs precisely the same thing for a put file. Two
* copies of a transform is how the two spellings drift, and this
* file's own `as.s` image had no room for the second one -- the
* SYMADR tripwire caught it at 75 bytes over.
*
* Reads DIRECTLY to the destination and transforms IN PLACE: the
* transform is 1-for-1, never growing or shrinking the byte
* count, so the raw bytes and their translated form occupy the
* same offsets.
*
* IN:  A = fd, PTR0 = destination, RDX_BOUND = the high byte the
*      write pointer may not reach.
* OUT: carry CLEAR, PTR0 one past the last byte written.
*      carry SET with A=0 on a read error, A=1 on overrun.
* CLOBBERS: A, X, Y, PTR0 (advanced -- that IS the output).
*---------------------------------------------------------------
RDXFORM     sta   RDX_FD
:rdloop     lda   RDX_FD
            sta   RPARM_REF
            lda   PTR0
            sta   RPARM_BUF
            lda   PTR0+1
            sta   RPARM_BUF+1
*-- CLAMP THE REQUEST to what is actually left below RDX_BOUND.
*-- This asked for RD_CHUNK unconditionally until 2026-08-28 and
*-- only noticed the overrun in :xform below, a byte at a time,
*-- AFTER the kernel had already written up to 1024 bytes -- so
*-- a source ending within a chunk of the ceiling scribbled past
*-- it (into the object buffer, for the main read) and the
*-- "overrun"
*-- return came too late to mean anything. Found by adversarial
*-- review; it predates AS_GOREAD but the put path made it reach
*-- further. RDX_BOUND is a PAGE number, so the space left is
*-- (RDX_BOUND*256 - PTR0), computed here as a plain 16-bit
*-- subtract with 0 for the low byte of the bound.
            sec
            lda   #0
            sbc   PTR0
            sta   RPARM_REQ
            lda   RDX_BOUND
            sbc   PTR0+1
            sta   RPARM_REQ+1
            bcc   :toobig            ;PTR0 past the bound
            ora   RPARM_REQ
            beq   :toobig            ;exactly at it -- no room
*-- >=4 pages left means >=RD_CHUNK; ask for a full chunk.
            lda   RPARM_REQ+1
            cmp   #>RD_CHUNK
            bcc   :doread
            lda   #<RD_CHUNK
            sta   RPARM_REQ
            lda   #>RD_CHUNK
            sta   RPARM_REQ+1
:doread     lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :rderr
            lda   RPARM_TRANS
            ora   RPARM_TRANS+1
            beq   :done             ;EOF
            lda   RPARM_TRANS
            sta   RDX_LEFT
            lda   RPARM_TRANS+1
            sta   RDX_LEFT+1
*-- RD_CHUNK=1024 > 255, so RDX_LEFT is a real 16-bit down-
*-- counter, not an 8-bit X index. (PTR0),y with y=0 addresses
*-- both the just-read raw byte and its translated destination.
:xform      lda   RDX_LEFT
            ora   RDX_LEFT+1
            beq   :rdloop
            ldy   #0
            lda   (PTR0),y
            cmp   #$0D
            beq   :iscr
            cmp   #$0A
            bne   :plain
:iscr       lda   #$8D
            bra   :emit
:plain      ora   #$80
:emit       sta   (PTR0),y
            inc   PTR0
            bne   :nocarry
            inc   PTR0+1
:nocarry    lda   PTR0+1
            cmp   RDX_BOUND
            bcs   :toobig
            lda   RDX_LEFT
            bne   :dec1
            dec   RDX_LEFT+1
:dec1       dec   RDX_LEFT
            bra   :xform
:done       clc
            rts
:toobig     lda   #1
            bra   :setc
:rderr      lda   #0
:setc       sec
            rts

WRITEOBJ    lda   Z_OBJPNT
            sta   SAVOBJPNT
            lda   Z_OBJPNT+1
            sta   SAVOBJPNT+1
            lda   Z_OBLEN
            sta   SAVOBLEN
            lda   Z_OBLEN+1
            sta   SAVOBLEN+1

*-- The object (REL: code + dictionary copy) must end at or
*-- below $BF00, the process bank's kernel interface page. This
*-- is also the retroactive no-overlap proof for a REL pass 2:
*-- the P15 dictionary accumulates DOWN from $BF00 and its
*-- appended copy is never smaller than the accumulation list,
*-- so end<=$BF00 implies the code top never met the dictionary
*-- bottom mid-assembly (docs/S9-PLAN.md sec 6 L0). The core's
*-- own FENCE is $C000 -- one page too late for maux.
            clc
            lda   SAVOBJPNT
            adc   SAVOBLEN
            tay                      ;park end-lo; Y is dead
            lda   SAVOBJPNT+1
            adc   SAVOBLEN+1
            bcs   :objbig            ;wrapped past $FFFF
            cmp   #$BF
            bcc   :fits
            bne   :objbig
            tya                      ;hi=$BF: only =$BF00 ok
            beq   :fits
:objbig     lda   #<OBJBIG
            ldx   #>OBJBIG
            jsr   DIAG1
            lda   #1
            jsr   PREEXIT

*-- REL vs BIN: the core zeroes RELFLAG at every ASM entry and
*-- the source's own REL directive sets it minus, so the flag is
*-- authoritative here. Both branches store BOTH parm cells --
*-- CRPARM lives in this image and a previous run's values must
*-- never leak into this one's create.
:fits       bit   Z_RELFLAG
            bmi   :isrel
            lda   #FTYPE_BIN
            sta   CRPARM_TYPE
            stz   CRPARM_AUX
            stz   CRPARM_AUX+1
            bra   :parmset
:isrel      lda   #FTYPE_RELM        ;Merlin REL, $F8 -- NOT the
            sta   CRPARM_TYPE        ;EDASM $FE (see mli.equ)
            lda   Z_CODELEN          ;aux = CODE length: where
            sta   CRPARM_AUX         ;the dictionary begins, per
            lda   Z_CODELEN+1        ;the linker's own contract
            sta   CRPARM_AUX+1
:parmset
            lda   OBJPTR
            sta   PTR0
            lda   OBJPTR+1
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            ; For BIN, CRPARM_AUX is 0 -- v1 does not set
            ; aux_type=ADRSV (a cosmetic BIN-file convention,
            ; not part of the byte-identical-object bar).
            lda   #<CRPARM
            ldx   #>CRPARM
            jsr   SC_CREAT
            bcs   :fail
            lda   #<DOPARM
            ldx   #>DOPARM
            jsr   SC_OPEN
            bcs   :fail
            lda   DOPARM_REF
            sta   DSTFD
            lda   SAVOBJPNT
            sta   WPARM_BUF
            lda   SAVOBJPNT+1
            sta   WPARM_BUF+1
            lda   SAVOBLEN
            sta   WPARM_REQ
            lda   SAVOBLEN+1
            sta   WPARM_REQ+1
:wrloop     lda   WPARM_REQ
            ora   WPARM_REQ+1
            beq   :wrdone
            lda   DSTFD
            sta   WPARM_REF
            lda   #<WPARM
            ldx   #>WPARM
            jsr   SC_WRITE
            bcs   :fail
            lda   WPARM_TRANS
            ora   WPARM_TRANS+1
            beq   :fail             ;defensive -- avoid a spin
            sec
            lda   WPARM_REQ
            sbc   WPARM_TRANS
            sta   WPARM_REQ
            lda   WPARM_REQ+1
            sbc   WPARM_TRANS+1
            sta   WPARM_REQ+1
            clc
            lda   WPARM_BUF
            adc   WPARM_TRANS
            sta   WPARM_BUF
            lda   WPARM_BUF+1
            adc   WPARM_TRANS+1
            sta   WPARM_BUF+1
            bra   :wrloop
:wrdone     lda   DSTFD
            sta   C2PARM_REF
            lda   #<C2PARM
            ldx   #>C2PARM
            jsr   SC_CLOSE
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
