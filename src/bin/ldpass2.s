*---------------------------------------------------------------
* ldpass2.s -- ld's fixup resolution: BLDEXTS (the module's EXT
* table), RESOLVE and STORFIX. Split from ldpass.s for `as`'s
* source window (main + LARGEST single put <= 16,126 B); the
* cut is at a top-level label with no `:local` zone straddling
* it, and this file is `put` IMMEDIATELY AFTER ldsym.s.
*
* READCODE, APPLYFIX and WRITEOUT -- the build-area pass 2 --
* are gone (2026-09-13): the code is streamed by ldstream.s,
* which calls RESOLVE/STORFIX per fixup with FIXADR pointing
* into the chunk buffer instead of the build area. They read
* and write through FIXADR exactly as before.
*---------------------------------------------------------------
*---------------------------------------------------------------
* BLDEXTS -- walk this module's symbol list and fill EXTTAB so
* EXTTAB[refnum] is the resolved address. An EXT's own address
* field IS its refnum, so the table is indexed by what the fixup
* records actually carry rather than by list position.
*---------------------------------------------------------------
BLDEXTS     lda   #<TAILBUF
            sta   ND_PTR
            lda   #>TAILBUF
            sta   ND_PTR+1
            jsr   SKIPFIX
:loop       jsr   SYMREC
            bcs   :done
            lda   ND_FLAG
            and   #FLAG_EXT
            beq   :loop
            jsr   FINDSYM
            bcs   :undef
*-- refnum = ND_ADDR - $8000, and EXTTAB is indexed by its LOW
*-- byte, so a refnum of 256 or more would silently alias to 0.
*-- The corpus tops out at 84 today; this refuses rather than
*-- trusting that, because an accepted limit with no guard is
*-- one nobody notices being crossed.
            lda   ND_ADDR+1
            cmp   #$80
            bne   :badref
            lda   ND_ADDR
            tax
            lda   ND_TGT
            sta   EXTTAB_L,x
            lda   ND_TGT+1
            sta   EXTTAB_H,x
            bra   :loop
:done       clc
            rts
:undef      jsr   ERR_UNDEF
            sec
            rts
:badref     jsr   ERR_REFNUM
            sec
            rts

*---------------------------------------------------------------
* RESOLVE -- compute ND_TGT for the decoded fixup.
*
* INTERNAL: the stored value is $8000-based and byte3 is the
* target's LOW byte -- which is the only place the low half
* exists for a high-byte fixup, and is what makes the carry
* computable. EXTERNAL: byte3 is the refnum and the code holds
* $8000 + ADDEND, so the addend must be added to the symbol.
* Dropping it mis-links every SYM+n reference.
*---------------------------------------------------------------
RESOLVE     lda   ND_KIND
            cmp   #$1F
            beq   :extlo
            cmp   #$50
            beq   :exthi
            cmp   #$51
            beq   :exthi
            cmp   #$9F
            beq   :extwd
            cmp   #$0F
            beq   :intlo
            cmp   #$4F
            beq   :inthi
            cmp   #$8F
            beq   :intwd
            jsr   ERR_KIND
            sec
            rts

*-- internal, 1-byte low: stored = byte3
:intlo      lda   ND_B3
            sta   ND_TGT
            lda   #$80
            sta   ND_TGT+1
            jmp   :intrel
*-- internal, 1-byte high: stored = code<<8 | byte3
:inthi      lda   ND_B3
            sta   ND_TGT
            jsr   PEEKFIX
            sta   ND_TGT+1
            jmp   :intrel
*-- internal, 2-byte: stored = the 16-bit value in the code
:intwd      jsr   PEEKFIX
            sta   ND_TGT
            inc   FIXADR
            bne   :iw1
            inc   FIXADR+1
:iw1        jsr   PEEKFIX
            sta   ND_TGT+1
            lda   FIXADR
            bne   :iw2
            dec   FIXADR+1
:iw2        dec   FIXADR
:intrel     sec
            lda   ND_TGT
            sbc   #$00
            sta   ND_TGT
            lda   ND_TGT+1
            sbc   #$80
            sta   ND_TGT+1
            clc
            lda   ND_TGT
            adc   ND_BASE
            sta   ND_TGT
            lda   ND_TGT+1
            adc   ND_BASE+1
            sta   ND_TGT+1
            clc
            rts

*-- external, 1-byte low: addend = the stored low byte
:extlo      jsr   PEEKFIX
            sta   ND_TMP
            stz   ND_TMP+1
            jmp   :extadd
*-- external, 1-byte high: addend = (stored - $80) << 8
:exthi      jsr   PEEKFIX
            sec
            sbc   #$80
            sta   ND_TMP+1
            stz   ND_TMP
            jmp   :extadd
*-- external, 2-byte: addend = stored - $8000
:extwd      jsr   PEEKFIX
            sta   ND_TMP
            inc   FIXADR
            bne   :ew1
            inc   FIXADR+1
:ew1        jsr   PEEKFIX
            sec
            sbc   #$80
            sta   ND_TMP+1
            lda   FIXADR
            bne   :ew2
            dec   FIXADR+1
:ew2        dec   FIXADR
:extadd     ldx   ND_B3
            clc
            lda   EXTTAB_L,x
            adc   ND_TMP
            sta   ND_TGT
            lda   EXTTAB_H,x
            adc   ND_TMP+1
            sta   ND_TGT+1
            clc
            rts

*---------------------------------------------------------------
* PEEKFIX -- read the build-area byte at FIXADR into A.
*---------------------------------------------------------------
PEEKFIX     ldy   #0
            lda   (FIXADR),y
            rts

*---------------------------------------------------------------
* STORFIX -- write ND_TGT back per the fixup's width and half.
*---------------------------------------------------------------
STORFIX     lda   ND_KIND
            cmp   #$8F
            beq   :word
            cmp   #$9F
            beq   :word
            cmp   #$4F
            beq   :high
            cmp   #$50
            beq   :high
            cmp   #$51
            beq   :high
            lda   ND_TGT              ;$0F / $1F -- low byte
            ldy   #0
            sta   (FIXADR),y
            rts
:high       lda   ND_TGT+1
            ldy   #0
            sta   (FIXADR),y
            rts
:word       lda   ND_TGT
            ldy   #0
            sta   (FIXADR),y
            lda   ND_TGT+1
            iny
            sta   (FIXADR),y
            rts

