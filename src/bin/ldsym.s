*---------------------------------------------------------------
* ldsym.s -- nld's dictionary walk (SKIPFIX/SYMREC), pass 1 and
* the symbol pool. Split from nldpass.s at SKIPFIX.
*
* WHY, and it is a DIFFERENT ceiling from the last split.
* check-dialect measures a unit's FLAT put-chain closure --
* resident + largest put over the whole stripped tree -- while
* build_librelas_image measures the GENERATED REL main. Both are
* real and they do not agree: nld.s passed the REL model at
* 15,570 and failed the flat one at 16,709. This split is for
* the flat one.
*
* Cut at a top-level label with no `:local` zone straddling it,
* and `put` immediately after nldpass.s, so no byte moves.
*---------------------------------------------------------------
*---------------------------------------------------------------
* SKIPFIX -- advance ND_PTR over the fixup list to the first
* symbol record. IN: ND_PTR = TAILBUF. The list is 4-byte
* records ended by a lone $00 kind byte.
*---------------------------------------------------------------
SKIPFIX     jsr   ATEND
            bcs   :done
            ldy   #0
            lda   (ND_PTR),y
            beq   :done
            lda   #4
            jsr   ADVPTR
            bra   SKIPFIX
:done       lda   #1
            jmp   ADVPTR

*---------------------------------------------------------------
* ATEND -- carry SET when ND_PTR has reached ND_END, the end of
* the tail READTAIL actually read.
*
* This is the bound the walk had been computing and never using.
* Without it a truncated or non-REL file walks off TAILBUF into
* the rest of the arena looking for a $00 that is not there --
* and ND_END sitting there unread was worse than no bound,
* because it reads like one.
*---------------------------------------------------------------
ATEND       lda   ND_PTR+1
            cmp   ND_END+1
            bcc   :inside
            bne   :past
            lda   ND_PTR
            cmp   ND_END
            bcc   :inside
:past       sec
            rts
:inside     clc
            rts

*---------------------------------------------------------------
* ADVPTR -- ND_PTR += A.
*---------------------------------------------------------------
ADVPTR      clc
            adc   ND_PTR
            sta   ND_PTR
            bcc   :done
            inc   ND_PTR+1
:done       rts

*---------------------------------------------------------------
* SYMREC -- decode the symbol record at ND_PTR and step past it.
* OUT: carry set at the list terminator; otherwise ND_FLAG,
* ND_LEN, ND_NAME (-> the name bytes) and ND_ADDR.
* The length is the LOW SIX BITS (nm.s's own reading); an ENT's
* address is a module-relative offset and an EXT's IS its
* refnum, both $8000-based (docs/REL-FORMAT.md).
*---------------------------------------------------------------
SYMREC      jsr   ATEND
            bcs   :stop
            ldy   #0
            lda   (ND_PTR),y
            bne   :have
:stop       sec
            rts
:have       sta   ND_FLAG
            and   #NAMEMASK
            sta   ND_LEN
            lda   #1
            jsr   ADVPTR
            lda   ND_PTR
            sta   ND_NAME
            lda   ND_PTR+1
            sta   ND_NAME+1
            lda   ND_LEN
            jsr   ADVPTR
            ldy   #0
            lda   (ND_PTR),y
            sta   ND_ADDR
            iny
            lda   (ND_PTR),y
            sta   ND_ADDR+1
            lda   #2
            jsr   ADVPTR
            clc
            rts

*---------------------------------------------------------------
* PASS 1 -- place every module and record what it exports.
* Nothing is emitted. A module's base is where the previous one
* ended, starting at LNKADDR; every ENT it declares becomes a
* global at base + (addr - $8000).
*---------------------------------------------------------------
PASS1       lda   LNKADDR
            sta   NEXTADR
            lda   LNKADDR+1
            sta   NEXTADR+1
            lda   SEGADR            ;-s: the segment run's own
            sta   SEGCUR            ;cursor, 0 when never given
            lda   SEGADR+1
            sta   SEGCUR+1
            lda   SEGADR2           ;and run 2's
            sta   SEGCUR2
            lda   SEGADR2+1
            sta   SEGCUR2+1
            stz   ND_I
:modloop    lda   ND_I
            cmp   NMODS
            bcc   :more
            clc
            rts
:more       jsr   OPENMOD
            bcc   :opened
            jmp   :fail
:opened
*-- assign this module's base, then advance by its code length
*-- -- TWO cursors since -s (ld.s's SEGADR comment). NEXTADR is
*-- where the bytes GO and always advances; SEGCUR is where a
*-- segment-run module RUNS. PASS2 streams module by module and
*-- never derives a file position from an address, so the two
*-- are independent all the way to the output. The modules
*-- AFTER the run get NEXTADR, which is exactly what sh.s's
*-- third `org` computes -- so that `org` needs no
*-- representation here at all.
            ldx   ND_I
            lda   SEGFLG,x
            bne   :segmod
            lda   NEXTADR
            sta   MODBASE_L,x
            sta   ND_BASE
            lda   NEXTADR+1
            sta   MODBASE_H,x
            sta   ND_BASE+1
            bra   :advance
:segmod     cmp   #2
            beq   :seg2
            lda   SEGCUR
            sta   MODBASE_L,x
            sta   ND_BASE
            lda   SEGCUR+1
            sta   MODBASE_H,x
            sta   ND_BASE+1
            clc
            lda   SEGCUR
            adc   ND_CODE
            sta   SEGCUR
            lda   SEGCUR+1
            adc   ND_CODE+1
            sta   SEGCUR+1
            bra   :advance
:seg2       lda   SEGCUR2
            sta   MODBASE_L,x
            sta   ND_BASE
            lda   SEGCUR2+1
            sta   MODBASE_H,x
            sta   ND_BASE+1
            clc
            lda   SEGCUR2
            adc   ND_CODE
            sta   SEGCUR2
            lda   SEGCUR2+1
            adc   ND_CODE+1
            sta   SEGCUR2+1
:advance    clc
            lda   NEXTADR
            adc   ND_CODE
            sta   NEXTADR
            lda   NEXTADR+1
            adc   ND_CODE+1
            sta   NEXTADR+1
            jsr   READTAIL
            bcs   :closefail
            lda   #<TAILBUF
            sta   ND_PTR
            lda   #>TAILBUF
            sta   ND_PTR+1
            jsr   SKIPFIX
:symloop    jsr   SYMREC
            bcs   :symdone
            lda   ND_FLAG
            and   #FLAG_ENT
            beq   :symloop
            jsr   ADDSYM
            bcs   :closefail
            bra   :symloop
:symdone    jsr   CLOSEMOD
            inc   ND_I
            jmp   :modloop
:closefail  jsr   CLOSEMOD
:fail       sec
            rts

*---------------------------------------------------------------
* THE SYMBOL TABLE is one PACKED, linearly-walked pool:
*
*     [len][name bytes][addr lo][addr hi] ... [$00]
*
* and NOT a set of parallel arrays with an index. The first cut
* used arrays indexed by `ldx NSYMS` -- an 8-BIT register --
* under a SYMMAX of 400 -- so `cmp #SYMMAX` truncated to 144 and
* ADDSYM refused partway through every real link. The largest
* link in the tree (mv) needs 281 symbols, so 8-bit indexing was
* never going to work; a packed pool has no index at all.
*
* The linear scan is affordable because lookups happen ONCE PER
* EXTERNAL, in BLDEXTS, not once per fixup: the fixup records
* then index EXTTAB directly. That is ~500 lookups for a whole
* util, not the ~3,000 a per-fixup design would cost.
*---------------------------------------------------------------
* ADDSYM -- append the symbol just decoded, resolved to
* ND_BASE + (ND_ADDR - $8000).
*---------------------------------------------------------------
*-- A NAME DEFINED TWICE is a link error, not a race the first
*-- definition happens to win. scripts/relink.py raises and
*-- this did not, so the model and the implementation disagreed.
ADDSYM      jsr   FINDSYM
            bcs   :fresh
            jsr   ERR_DUP
            sec
            rts
:fresh      sec
            lda   ND_ADDR
            sbc   #$00
            sta   ND_TGT
            lda   ND_ADDR+1
            sbc   #$80
            sta   ND_TGT+1
            clc
            lda   ND_TGT
            adc   ND_BASE
            sta   ND_TGT
            lda   ND_TGT+1
            adc   ND_BASE+1
            sta   ND_TGT+1
*-- room? len + name + 2 address bytes + the pool terminator
            clc
            lda   NAMEUSED
            adc   ND_LEN
            sta   ND_TMP
            lda   NAMEUSED+1
            adc   #0
            sta   ND_TMP+1
            clc
            lda   ND_TMP
            adc   #4
            sta   ND_TMP
            lda   ND_TMP+1
            adc   #0
            cmp   #>SYMNMCAP
            bcs   :full
*-- write [len][name][addr] at NAMEPOOL+NAMEUSED
            clc
            lda   #<NAMEPOOL
            adc   NAMEUSED
            sta   ND_TMP
            lda   #>NAMEPOOL
            adc   NAMEUSED+1
            sta   ND_TMP+1
            ldy   #0
            lda   ND_LEN
            sta   (ND_TMP),y
:cpy        cpy   ND_LEN
            beq   :cpydone
            lda   (ND_NAME),y        ;src[y] -> dst[y+1]
            iny
            sta   (ND_TMP),y
            bra   :cpy
:cpydone    ldy   ND_LEN
            iny
            lda   ND_TGT
            sta   (ND_TMP),y
            iny
            lda   ND_TGT+1
            sta   (ND_TMP),y
            iny
            lda   #0
            sta   (ND_TMP),y         ;keep the pool terminated
            clc
            lda   NAMEUSED
            adc   ND_LEN
            sta   NAMEUSED
            lda   NAMEUSED+1
            adc   #0
            sta   NAMEUSED+1
            clc
            lda   NAMEUSED
            adc   #3
            sta   NAMEUSED
            lda   NAMEUSED+1
            adc   #0
            sta   NAMEUSED+1
            clc
            rts
:full       jsr   ERR_SYMS
            sec
            rts

*---------------------------------------------------------------
* FINDSYM -- look up ND_NAME/ND_LEN in the pool.
* OUT: carry clear + ND_TGT = its address, or carry set.
*---------------------------------------------------------------
FINDSYM     lda   #<NAMEPOOL
            sta   ND_PTR2
            lda   #>NAMEPOOL
            sta   ND_PTR2+1
:loop       ldy   #0
            lda   (ND_PTR2),y
            beq   :miss
            cmp   ND_LEN
            bne   :next
            jsr   CMPNAM
            bcc   :hit
:next       ldy   #0
            lda   (ND_PTR2),y
            clc
            adc   #3
            jsr   ADVPTR2
            bra   :loop
:hit        ldy   ND_LEN
            iny
            lda   (ND_PTR2),y
            sta   ND_TGT
            iny
            lda   (ND_PTR2),y
            sta   ND_TGT+1
            clc
            rts
:miss       sec
            rts

*---------------------------------------------------------------
* ADVPTR2 -- ND_PTR2 += A.
*---------------------------------------------------------------
ADVPTR2     clc
            adc   ND_PTR2
            sta   ND_PTR2
            bcc   :done
            inc   ND_PTR2+1
:done       rts

*---------------------------------------------------------------
* CMPNAM -- compare the pool entry at ND_PTR2 against ND_NAME
* for ND_LEN bytes. Carry clear if equal.
*---------------------------------------------------------------
CMPNAM      ldy   #0
:loop       cpy   ND_LEN
            beq   :same
            iny
            lda   (ND_PTR2),y
            dey
            cmp   (ND_NAME),y
            bne   :diff
            iny
            bra   :loop
:same       clc
            rts
:diff       sec
            rts

*---------------------------------------------------------------
* PASS 2 -- for each module: dictionary tail, externals, then
* STREAM the code to the output (ldstream.s). Nothing is laid
* into memory; the output file is the image.
*---------------------------------------------------------------
PASS2       stz   ND_I
:modloop    lda   ND_I
            cmp   NMODS
            bcc   :more
            clc
            rts
:more       jsr   OPENMOD
            bcc   :opened
            jmp   :fail
:opened
            ldx   ND_I
            lda   MODBASE_L,x
            sta   ND_BASE
            lda   MODBASE_H,x
            sta   ND_BASE+1
            jsr   READTAIL
            bcs   :closefail
            jsr   BLDEXTS
            bcs   :closefail
            jsr   STREAMMOD
            bcs   :closefail
            jsr   CLOSEMOD
            inc   ND_I
            jmp   :modloop
:closefail  jsr   CLOSEMOD
:fail       sec
            rts
