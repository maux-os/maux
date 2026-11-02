*---------------------------------------------------------------
* ldstream.s -- ld's STREAMING second pass: the image is never
* built in memory. Per module, the dictionary tail is read once
* (READTAIL, ldpass.s), the externals are resolved once
* (BLDEXTS, ldpass2.s), and then the CODE is streamed through a
* 2 KB chunk buffer -- each fixup applied as its offset passes,
* each chunk appended straight to the output file. Across the
* whole link only the symbol table is resident; per module only
* its dictionary; of its code, one chunk.
*
* WHY (2026-09-13, docs/AS-LINKER-SPIKE.md): the old pass 2 laid
* every module into a $5600-$BD00 build area and wrote it once
* at the end, so the WHOLE pre-`-z` image -- code, the util's
* bss chunks AND liba's pure-bss modules, all zeros -- had to
* fit 26,368 B. make linked 30 B under; ex failed at 26,803, sh
* at 32,579, vi at 43,430. A 64 KB machine cannot hold a big
* object, and the output is a serial file anyway, so the build
* area was the wrong architecture from the start (operator).
*
* THE ONE ORDERING ASSUMPTION: the fixup cursor walks records
* in ASCENDING offset order. nas writes them so (pass2's
* relpatch, in code order); REAL MERLIN writes them DESCENDING
* -- its list is a stack, last fixup first (measured 2026-09-13
* on check-librelas's objects: CATMR 84 records, 84 descending
* runs) -- so REVFIX turns a descending tail around in place
* before the cursor starts. Anything else is refused (NEXTFIX,
* `ld: fixups out of order`) rather than trusted, because a
* record that arrives after its byte has been written can no
* longer be applied.
*
* A 2-byte fixup can straddle a chunk end: the chunk's last byte
* is then HELD BACK (KEEP), copied to the front of the buffer,
* and the next read lands after it -- so the record is applied
* whole when its second byte arrives. That is the only carry
* between chunks.
*
* `-z` is a PENDING ZERO RUN, not a truncation: zeros at the
* tail of what has been seen so far are counted (ZRUN), written
* only when a later nonzero byte arrives (FLUSHZ), and dropped
* at the end of the link. It is MODULE-GRANULAR (2026-09-13):
* at the end of a module that emitted any nonzero byte the run
* is flushed, so a CODE module's own trailing zeros -- ex.s's
* final `dfb 0` string terminator -- stay in the file exactly
* as merlin32's monolithic build keeps them; only trailing
* modules that are all zeros (the bss chunks, liba's pure-bss
* modules) are dropped. The build-area version cut a byte span
* and would have lost that terminator; no earlier unit ended
* in a zero byte, so nothing had shown it.
*---------------------------------------------------------------

*---------------------------------------------------------------
* STREAMMOD -- stream module ND_I's code to the output.
* IN:  MODFD open; ND_CODE; ND_BASE; EXTTAB filled; TAILBUF
*      holds the dictionary (ND_END its bound).
* OUT: carry set on any refusal (the diagnostic already said).
*---------------------------------------------------------------
STREAMMOD   stz   ND_TMP
            stz   ND_TMP+1
            jsr   SEEKMOD            ;back to the code
            bcc   :s0
            jmp   :fail
:s0         jsr   REVFIX             ;Merlin's descending list
            stz   MODPOS
            stz   MODPOS+1
            stz   MODNZ
            stz   HAVE
            stz   HAVE+1
            lda   #<TAILBUF
            sta   ND_PTR
            lda   #>TAILBUF
            sta   ND_PTR+1
            stz   FIXPEND
            stz   FIXEND
            stz   LASTOFF
            stz   LASTOFF+1
*-- remaining = CODE - MODPOS - HAVE
:loop       sec
            lda   ND_CODE
            sbc   MODPOS
            sta   ND_TMP
            lda   ND_CODE+1
            sbc   MODPOS+1
            sta   ND_TMP+1
            sec
            lda   ND_TMP
            sbc   HAVE
            sta   ND_TMP
            lda   ND_TMP+1
            sbc   HAVE+1
            sta   ND_TMP+1
            lda   ND_TMP
            ora   ND_TMP+1
            bne   :more
            jmp   :final
*-- request = min(remaining, CODECHUNK)
:more       lda   ND_TMP+1
            cmp   #>CODECHUNK
            bcc   :reqok
            bne   :cap
            lda   ND_TMP
            cmp   #<CODECHUNK
            bcc   :reqok
:cap        lda   #<CODECHUNK
            sta   ND_TMP
            lda   #>CODECHUNK
            sta   ND_TMP+1
:reqok      lda   MODFD
            sta   RPARM_REF
            clc
            lda   #<CODEBUF
            adc   HAVE
            sta   RPARM_BUF
            lda   #>CODEBUF
            adc   HAVE+1
            sta   RPARM_BUF+1
            lda   ND_TMP
            sta   RPARM_REQ
            lda   ND_TMP+1
            sta   RPARM_REQ+1
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcc   :rd0
            jmp   :fail
:rd0        lda   RPARM_TRN
            ora   RPARM_TRN+1
            bne   :rd1
            jmp   :short             ;EOF before aux said
:rd1        clc
            lda   HAVE
            adc   RPARM_TRN
            sta   HAVE
            lda   HAVE+1
            adc   RPARM_TRN+1
            sta   HAVE+1
            jsr   APPLYIN            ;every fixup wholly inside
            bcc   :ap0
            jmp   :fail
*-- a word fixup on the last byte held?
:ap0        jsr   KEEPBYTE
            sec                      ;emit HAVE-KEEP bytes
            lda   HAVE
            sbc   KEEP
            sta   ND_TMP
            lda   HAVE+1
            sbc   #0
            sta   ND_TMP+1
            lda   #<CODEBUF
            sta   ND_TMP2
            lda   #>CODEBUF
            sta   ND_TMP2+1
            jsr   ZWRITE
            bcc   :wr0
            jmp   :fail
:wr0        sec                      ;MODPOS += HAVE-KEEP
            lda   HAVE
            sbc   KEEP
            sta   ND_TMP
            lda   HAVE+1
            sbc   #0
            sta   ND_TMP+1
            clc
            lda   MODPOS
            adc   ND_TMP
            sta   MODPOS
            lda   MODPOS+1
            adc   ND_TMP+1
            sta   MODPOS+1
            lda   KEEP
            beq   :nokeep
*-- carry the held byte to the front:
*-- CODEBUF[0] = CODEBUF[HAVE-1]
            lda   HAVE
            bne   :k1
            dec   HAVE+1
:k1         dec   HAVE
            clc
            lda   #<CODEBUF
            adc   HAVE
            sta   ND_TMP2
            lda   #>CODEBUF
            adc   HAVE+1
            sta   ND_TMP2+1
            ldy   #0
            lda   (ND_TMP2),y
            sta   CODEBUF
            lda   #1
            sta   HAVE
            stz   HAVE+1
            jmp   :loop
:nokeep     stz   HAVE
            stz   HAVE+1
            jmp   :loop
*-- all the code has been read: every fixup must be consumed
:final      jsr   NEXTFIX
            bcs   :fail
            lda   FIXPEND
            bne   :outside
            lda   FIXEND
            beq   :outside
*-- a held byte with nothing pending cannot happen;
*-- emit it anyway rather than lose it
            lda   HAVE
            ora   HAVE+1
            beq   :ok
            lda   HAVE
            sta   ND_TMP
            lda   HAVE+1
            sta   ND_TMP+1
            lda   #<CODEBUF
            sta   ND_TMP2
            lda   #>CODEBUF
            sta   ND_TMP2+1
            jsr   ZWRITE
            bcs   :fail
*-- a module that emitted anything nonzero keeps its own
*-- trailing zeros (module-granular -z, see the header)
:ok         lda   MODNZ
            beq   :ok2
            jsr   FLUSHZ
            bcs   :fail
:ok2        clc
            rts
:outside    jsr   ERR_FIXOFF
            sec
            rts
:short      jsr   ERR_SHORT
:fail       sec
            rts

*---------------------------------------------------------------
* REVFIX -- if the fixup list in TAILBUF runs DESCENDING (first
* record's offset above the last's -- real Merlin's stack order)
* reverse it in place, swapping 4-byte records from both ends.
* A one- or zero-record list and an ascending list are left as
* they are. Uses ND_PTR (front) and ND_TMP (back) -- both free
* between READTAIL/BLDEXTS and the cursor's start.
*---------------------------------------------------------------
*-- count the records -> ND_TMP2
REVFIX      lda   #<TAILBUF
            sta   ND_PTR
            lda   #>TAILBUF
            sta   ND_PTR+1
            stz   ND_TMP2
            stz   ND_TMP2+1
:count      jsr   ATEND
            bcs   :counted
            ldy   #0
            lda   (ND_PTR),y
            beq   :counted
            lda   #4
            jsr   ADVPTR
            inc   ND_TMP2
            bne   :count
            inc   ND_TMP2+1
            bra   :count
:counted    lda   ND_TMP2+1
            bne   :many
            lda   ND_TMP2
            cmp   #2
            bcc   :done
*-- back = TAILBUF + (n-1)*4 ; ND_PTR is already TAILBUF + n*4
:many       sec
            lda   ND_PTR
            sbc   #4
            sta   ND_TMP
            lda   ND_PTR+1
            sbc   #0
            sta   ND_TMP+1
            lda   #<TAILBUF
            sta   ND_PTR
            lda   #>TAILBUF
            sta   ND_PTR+1
*-- descending? compare first offset (ND_PTR+1,2) with last
            ldy   #2
            lda   (ND_PTR),y
            cmp   (ND_TMP),y
            bcc   :done              ;ascending
            bne   :swap              ;descending
            dey
            lda   (ND_PTR),y
            cmp   (ND_TMP),y
            bcc   :done
            beq   :done
*-- swap the two 4-byte records
:swap       ldy   #3
:sw1        lda   (ND_PTR),y
            pha
            lda   (ND_TMP),y
            sta   (ND_PTR),y
            pla
            sta   (ND_TMP),y
            dey
            bpl   :sw1
            clc                      ;front += 4
            lda   ND_PTR
            adc   #4
            sta   ND_PTR
            bcc   :f1
            inc   ND_PTR+1
:f1         sec                      ;back -= 4
            lda   ND_TMP
            sbc   #4
            sta   ND_TMP
            bcs   :b1
            dec   ND_TMP+1
*-- continue while front < back
:b1         lda   ND_TMP+1
            cmp   ND_PTR+1
            bcc   :done
            bne   :swap
            lda   ND_TMP
            cmp   ND_PTR
            bcc   :done
            beq   :done
            bra   :swap
:done       rts

*---------------------------------------------------------------
* NEXTFIX -- make sure a fixup record is decoded and pending
* (FIXPEND, ND_KIND/ND_OFF/ND_B3), or note the list's end
* (FIXEND). Records must not run backwards: see the header.
*---------------------------------------------------------------
NEXTFIX     lda   FIXPEND
            bne   :ok
            lda   FIXEND
            bne   :ok
            jsr   ATEND              ;bound: the tail read
            bcs   :end
            ldy   #0
            lda   (ND_PTR),y
            bne   :have
:end        inc   FIXEND
:ok         clc
            rts
:have       sta   ND_KIND
            iny
            lda   (ND_PTR),y
            sta   ND_OFF
            iny
            lda   (ND_PTR),y
            sta   ND_OFF+1
            iny
            lda   (ND_PTR),y
            sta   ND_B3
            lda   #4
            jsr   ADVPTR
*-- ND_OFF >= LASTOFF, or refuse
            lda   ND_OFF+1
            cmp   LASTOFF+1
            bcc   :bad
            bne   :fine
            lda   ND_OFF
            cmp   LASTOFF
            bcc   :bad
:fine       lda   ND_OFF
            sta   LASTOFF
            lda   ND_OFF+1
            sta   LASTOFF+1
            inc   FIXPEND
            clc
            rts
:bad        jsr   ERR_ORDER
            sec
            rts

*---------------------------------------------------------------
* FIXWIDTH -- A = the pending fixup's width: 2 for the word
* kinds ($8F internal, $9F external), else 1.
*---------------------------------------------------------------
FIXWIDTH    lda   ND_KIND
            cmp   #$8F
            beq   :word
            cmp   #$9F
            beq   :word
            lda   #1
            rts
:word       lda   #2
            rts

*---------------------------------------------------------------
* APPLYIN -- apply every pending fixup that lies WHOLLY inside
* the bytes held: ND_OFF + width <= MODPOS + HAVE. The patch
* site is CODEBUF + (ND_OFF - MODPOS); RESOLVE/STORFIX
* (ldpass2.s) read and write through FIXADR exactly as they did
* against the build area.
*---------------------------------------------------------------
APPLYIN     jsr   NEXTFIX
            bcs   :fail
            lda   FIXEND
            bne   :done
*-- end = ND_OFF + width -> ND_DST
            jsr   FIXWIDTH
            clc
            adc   ND_OFF
            sta   ND_DST
            lda   ND_OFF+1
            adc   #0
            sta   ND_DST+1
*-- limit = MODPOS + HAVE -> ND_TMP
            clc
            lda   MODPOS
            adc   HAVE
            sta   ND_TMP
            lda   MODPOS+1
            adc   HAVE+1
            sta   ND_TMP+1
            lda   ND_DST+1           ;end <= limit ?
            cmp   ND_TMP+1
            bcc   :apply
            bne   :done
            lda   ND_DST
            cmp   ND_TMP
            bcc   :apply
            beq   :apply
            bra   :done
*-- FIXADR = CODEBUF + (ND_OFF - MODPOS)
:apply      sec
            lda   ND_OFF
            sbc   MODPOS
            sta   FIXADR
            lda   ND_OFF+1
            sbc   MODPOS+1
            sta   FIXADR+1
            clc
            lda   FIXADR
            adc   #<CODEBUF
            sta   FIXADR
            lda   FIXADR+1
            adc   #>CODEBUF
            sta   FIXADR+1
            jsr   RESOLVE
            bcs   :fail
            jsr   STORFIX
            stz   FIXPEND
            bra   APPLYIN
:done       clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* KEEPBYTE -- KEEP = 1 iff the pending fixup begins at the last
* byte held AND is two bytes wide: it straddles the chunk end,
* so that byte must wait for its partner. (A 1-byte fixup on the
* last byte was already applied by APPLYIN; a pending fixup
* further on has not reached its bytes yet.)
*---------------------------------------------------------------
KEEPBYTE    stz   KEEP
            lda   FIXPEND
            beq   :done
            clc                      ;last = MODPOS + HAVE - 1
            lda   MODPOS
            adc   HAVE
            sta   ND_TMP
            lda   MODPOS+1
            adc   HAVE+1
            sta   ND_TMP+1
            lda   ND_TMP
            bne   :d1
            dec   ND_TMP+1
:d1         dec   ND_TMP
            lda   ND_OFF
            cmp   ND_TMP
            bne   :done
            lda   ND_OFF+1
            cmp   ND_TMP+1
            bne   :done
            jsr   FIXWIDTH
            cmp   #2
            bne   :done
            inc   KEEP
:done       rts

