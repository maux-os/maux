*---------------------------------------------------------------
* virg.s -- vi's REGISTER ARENA: the named registers "a-"z, the
* multi-line registers (linewise, and charwise spanning lines),
* and the multi-line charwise put (docs/VI-GAPS-2.md). `put` by
* vi.s ONLY, after virep.s.
*
* MODEL. Every register is one packed entry in ONE arena in the
* process language card (vi.s's dum block, the EX_SHADOW house
* pattern): {type}{count}{count NUL-terminated strings}. Entries
* 0-25 are "a-"z; entry 26 (VI_RGU) is the UNNAMED register's
* multi-line state. The unnamed register is split by shape:
*   VI_REGTY 0  charwise one-liner, the text in VI_REG (low BSS)
*   VI_REGTY 1  linewise, VI_REGLCNT strings in entry 26
*   VI_REGTY 2  charwise SPANNING lines, VI_REGLCNT strings in
*               entry 26: first line's tail, middle lines whole,
*               last line's head; a put glues them back with the
*               line breaks between
* A named register is a saved COPY of that state: `"ayy` yanks
* as
* `yy` does, then the core's last act is VI_RG_STORE, which
* packs
* (type 0) or copies entry 26 (type 1/2) into entry a; `"ap`
* runs
* VI_RG_LOAD first, which unpacks entry a into the unnamed
* register, then p/P put as always. So the unnamed register ends
* up holding the last register used, as vim's "" does.
*
* The directory (VI_RGDIR) is 27 {off16,len16} entries (len 0 =
* empty); entries may sit anywhere in the arena. Removing one
* slides the tail down (VI_RG_MOVE) and fixes the offsets after
* it; adding one appends at VI_RGEND. VI_RGCAP bounds the arena;
* an entry that would not fit rings the bell and leaves THAT
* REGISTER EMPTY (never truncated, never a half register).
*
* WRITING (yank/delete cores): VI_RG_BEG(idx), VI_RG_PUT per
* string (PTR0 = the NUL-terminated string), VI_RG_FIN(count).
* READING (puts): VI_RG_RDBEG, then VI_RG_NEXT per string into a
* low-window buffer (the kernel never copies from the LC for
* us).
* Every LC access is preceded by the LCBANK2_RAM double read in
* the SAME routine; no syscall runs between that read and the
* access it covers (a syscall may sit between two NEXT calls).
*
* ERRORS (all: BEL, no edit): `"` followed by anything but a-z
* (so "A-"Z append and "1-"9 numbered registers are errors, by
* ruling), `"x` followed by a key that is not an operator or a
* put, `"x` again, a put from an empty register, an entry that
* does not fit (that register is left empty), a multi-line yank
* over VI_REGMAXL lines (the unnamed register is left empty).
*
* Depends on: viop.s (VI_OPKEY, VI_OP_COMBINE, VI_REGTY, VI_REG,
* VI_REGLCNT), vimotion.s (VI_READCMD, VI_CLAMP_COL), vicmd.s
* (VI_RAWKEY), viscreen.s (VI_PLACE_CUR, VI_REPAINT), exbuf.s/
* excmd.s (ED_*, EX_SNAPSHOT), liba STRLEN/PUTC/SIO_FLUSH.
*---------------------------------------------------------------

* VI_BELL -- ring the bell (BEL, flushed). The console ignores
* BEL today (tty2.s) but the byte is the protocol. CLOBBERS: A,
* X.
VI_BELL     lda   #$87
            ldx   #FD_STDOUT
            jsr   PUTC
            ldx   #FD_STDOUT
            jmp   SIO_FLUSH

* VI_RG_LCON -- the LC double read (write-enable + read RAM).
VI_RG_LCON  lda   LCBANK2_RAM
            lda   LCBANK2_RAM
            rts

* VI_RG_INIT -- process entry: every register empty, no pending
* prefix. CLOBBERS: A, X.
VI_RG_INIT  stz   VI_RGSEL
            stz   VI_REGTY
            jsr   VI_RG_LCON
            ldx   #109                ;VI_RGDIR (108) + VI_RGEND
:z          stz   VI_RGDIR,x
            dex
            bpl   :z
            rts

* VI_RG_ENTRY -- IN: A = entry index 0-26. OUT: PTR2 = its
* directory entry. LC must be enabled. CLOBBERS: A, PTR2.
VI_RG_ENTRY asl
            asl
            clc
            adc   #<VI_RGDIR
            sta   PTR2
            lda   #>VI_RGDIR
            adc   #0
            sta   PTR2+1
            rts

* VI_RG_LEN -- IN: A = entry index. OUT: VI_RGOLD = its packed
* length, PTR2 = its directory entry. Enables the LC.
VI_RG_LEN   pha
            jsr   VI_RG_LCON
            pla
            jsr   VI_RG_ENTRY
            ldy   #2
            lda   (PTR2),y
            sta   VI_RGOLD
            iny
            lda   (PTR2),y
            sta   VI_RGOLD+1
            rts

* VI_RG_STRCP -- copy the NUL-terminated string at (PTR1) to
* (PTR2), NUL included, then advance BOTH pointers past it. OUT:
* X = bytes copied, NUL included. Strings are <=254 chars.
* CLOBBERS: A, X, Y, PTR1, PTR2.
VI_RG_STRCP ldy   #0
:lp         lda   (PTR1),y
            sta   (PTR2),y
            beq   :done
            iny
            bne   :lp
:done       iny                         ;bytes copied, NUL too
            tya
            tax
            clc
            adc   PTR1
            sta   PTR1
            bcc   :n1
            inc   PTR1+1
:n1         txa
            clc
            adc   PTR2
            sta   PTR2
            bcc   :n2
            inc   PTR2+1
:n2         rts

* VI_RG_MOVE -- copy VI_RGCNT bytes ascending from (PTR1) to
* (PTR0). CLOBBERS: A, Y, PTR0, PTR1, VI_RGCNT.
VI_RG_MOVE  ldy   #0
:lp         lda   VI_RGCNT
            ora   VI_RGCNT+1
            beq   :done
            lda   (PTR1),y
            sta   (PTR0),y
            iny
            bne   :nb
            inc   PTR1+1
            inc   PTR0+1
:nb         lda   VI_RGCNT
            bne   :dec
            dec   VI_RGCNT+1
:dec        dec   VI_RGCNT
            bra   :lp
:done       rts

* VI_RG_ROOM -- IN: VI_RGNEW = bytes to add, VI_RGOLD = bytes
* the
* add frees. OUT: carry clear = END-old+new is UNDER VI_RGCAP;
* carry set = does not fit, bell rung. CLOBBERS: A, VI_RGCNT.
VI_RG_ROOM  jsr   VI_RG_LCON
            sec
            lda   VI_RGEND
            sbc   VI_RGOLD
            sta   VI_RGCNT
            lda   VI_RGEND+1
            sbc   VI_RGOLD+1
            sta   VI_RGCNT+1
            clc
            lda   VI_RGCNT
            adc   VI_RGNEW
            sta   VI_RGCNT
            lda   VI_RGCNT+1
            adc   VI_RGNEW+1
            cmp   #>VI_RGCAP
            bcc   :fits
            bne   :full
            lda   VI_RGCNT
            cmp   #<VI_RGCAP
            bcc   :fits
:full       jsr   VI_BELL
            sec
            rts
:fits       clc
            rts

* VI_RG_DEL -- IN: A = entry index. Empty it: slide the arena
* tail down over it and fix every later offset. No-op if empty.
* CLOBBERS: A, X, Y, PTR0-2, VI_RGK, VI_RGOLD, VI_RGOOF,
* VI_RGCNT.
VI_RG_DEL   sta   VI_RGK
            jsr   VI_RG_LEN
            lda   VI_RGOLD
            ora   VI_RGOLD+1
            bne   :go
            rts
:go         ldy   #0
            lda   (PTR2),y
            sta   VI_RGOOF
            iny
            lda   (PTR2),y
            sta   VI_RGOOF+1
            clc                         ;PTR1 = arena+off+old
            lda   VI_RGOOF
            adc   VI_RGOLD
            sta   PTR1
            lda   VI_RGOOF+1
            adc   VI_RGOLD+1
            sta   PTR1+1
            sec                         ;count = END - (off+old)
            lda   VI_RGEND
            sbc   PTR1
            sta   VI_RGCNT
            lda   VI_RGEND+1
            sbc   PTR1+1
            sta   VI_RGCNT+1
            clc
            lda   PTR1
            adc   #<VI_RGARENA
            sta   PTR1
            lda   PTR1+1
            adc   #>VI_RGARENA
            sta   PTR1+1
            clc                         ;PTR0 = arena+off
            lda   VI_RGOOF
            adc   #<VI_RGARENA
            sta   PTR0
            lda   VI_RGOOF+1
            adc   #>VI_RGARENA
            sta   PTR0+1
            jsr   VI_RG_MOVE
            ldx   #0                    ;entries above it follow
:adj        lda   VI_RGDIR+2,x
            ora   VI_RGDIR+3,x
            beq   :adjn                 ;empty entry
            lda   VI_RGDIR+1,x
            cmp   VI_RGOOF+1
            bcc   :adjn
            bne   :adjdo
            lda   VI_RGDIR,x
            cmp   VI_RGOOF
            bcc   :adjn
            beq   :adjn                 ;the entry itself
:adjdo      sec
            lda   VI_RGDIR,x
            sbc   VI_RGOLD
            sta   VI_RGDIR,x
            lda   VI_RGDIR+1,x
            sbc   VI_RGOLD+1
            sta   VI_RGDIR+1,x
:adjn       inx
            inx
            inx
            inx
            cpx   #108
            bcc   :adj
            sec
            lda   VI_RGEND
            sbc   VI_RGOLD
            sta   VI_RGEND
            lda   VI_RGEND+1
            sbc   VI_RGOLD+1
            sta   VI_RGEND+1
            lda   VI_RGK
            jsr   VI_RG_ENTRY
            lda   #0
            ldy   #2
            sta   (PTR2),y
            iny
            sta   (PTR2),y
            rts

* VI_RG_ADV -- IN: A = bytes to claim at END for the entry being
* written. OUT: carry clear = claimed (VI_RGEND moved); carry
* set
* = no room, bell rung, VI_RGBAD set (VI_RG_FIN cleans up).
VI_RG_ADV   sta   VI_RGNEW
            stz   VI_RGNEW+1
            stz   VI_RGOLD
            stz   VI_RGOLD+1
            jsr   VI_RG_ROOM
            bcs   :fail
            clc
            lda   VI_RGEND
            adc   VI_RGNEW
            sta   VI_RGEND
            bcc   :nb
            inc   VI_RGEND+1
:nb         clc
            rts
:fail       lda   #1
            sta   VI_RGBAD
            rts

* VI_RG_BEG -- IN: A = entry index to (re)write, VI_REGTY = its
* type. Empties the entry, then claims its 2 header bytes at END
* (the entry's off = END, its len stays 0 until VI_RG_FIN).
VI_RG_BEG   sta   VI_RGI
            stz   VI_RGBAD
            jsr   VI_RG_DEL
            lda   VI_RGI
            jsr   VI_RG_ENTRY
            ldy   #0
            lda   VI_RGEND
            sta   (PTR2),y
            iny
            lda   VI_RGEND+1
            sta   (PTR2),y
            lda   #2
            jmp   VI_RG_ADV

* VI_RG_PUT -- IN: PTR0 = a NUL-terminated string (<=254 chars).
* Append it to the entry being written. OUT: carry set = failed
* (this or an earlier PUT). CLOBBERS: A, X, Y, PTR1, PTR2.
VI_RG_PUT   lda   VI_RGBAD
            beq   :ok
            sec
            rts
:ok         jsr   VI_RG_LCON
            clc
            lda   VI_RGEND
            adc   #<VI_RGARENA
            sta   PTR2
            lda   VI_RGEND+1
            adc   #>VI_RGARENA
            sta   PTR2+1
            jsr   STRLEN
            clc
            adc   #1                    ;the NUL
            jsr   VI_RG_ADV
            bcs   :out
            lda   PTR0
            sta   PTR1
            lda   PTR0+1
            sta   PTR1+1
            jsr   VI_RG_STRCP
            clc
:out        rts

* VI_RG_FIN -- IN: A = the entry's string count. Write the
* header
* and the entry's length. A failed write (VI_RGBAD) instead
* gives
* back every byte claimed, leaving the entry empty; carry set.
VI_RG_FIN   sta   VI_RGN
            jsr   VI_RG_LCON
            lda   VI_RGI
            jsr   VI_RG_ENTRY
            ldy   #0
            lda   (PTR2),y
            sta   VI_RGOOF
            clc
            adc   #<VI_RGARENA
            sta   PTR1
            iny
            lda   (PTR2),y
            sta   VI_RGOOF+1
            adc   #>VI_RGARENA
            sta   PTR1+1
            lda   VI_RGBAD
            beq   :good
            lda   VI_RGOOF          ;END back to the entry's off
            sta   VI_RGEND
            lda   VI_RGOOF+1
            sta   VI_RGEND+1
            sec
            rts
:good       ldy   #0
            lda   VI_REGTY
            sta   (PTR1),y
            iny
            lda   VI_RGN
            sta   (PTR1),y
            sec
            lda   VI_RGEND
            sbc   VI_RGOOF
            ldy   #2
            sta   (PTR2),y
            lda   VI_RGEND+1
            sbc   VI_RGOOF+1
            iny
            sta   (PTR2),y
            clc
            rts

* VI_RG_COPY -- IN: VI_RGS = source entry, VI_RGI = destination
* entry. Replace the destination with a copy of the source.
* OUT: carry set = no room (bell rung), destination untouched.
VI_RG_COPY  lda   VI_RGS
            jsr   VI_RG_LEN
            lda   VI_RGOLD
            sta   VI_RGNEW
            lda   VI_RGOLD+1
            sta   VI_RGNEW+1
            lda   VI_RGI
            jsr   VI_RG_LEN             ;OLD = what dest frees
            jsr   VI_RG_ROOM
            bcc   :room
            rts
:room       lda   VI_RGI
            jsr   VI_RG_DEL            ;(shifts the source down)
            lda   VI_RGS
            jsr   VI_RG_ENTRY
            ldy   #0
            lda   (PTR2),y
            clc
            adc   #<VI_RGARENA
            sta   PTR1
            iny
            lda   (PTR2),y
            adc   #>VI_RGARENA
            sta   PTR1+1
            lda   VI_RGNEW
            sta   VI_RGCNT
            lda   VI_RGNEW+1
            sta   VI_RGCNT+1
            clc
            lda   VI_RGEND
            adc   #<VI_RGARENA
            sta   PTR0
            lda   VI_RGEND+1
            adc   #>VI_RGARENA
            sta   PTR0+1
            jsr   VI_RG_MOVE
            lda   VI_RGI
            jsr   VI_RG_ENTRY
            ldy   #0
            lda   VI_RGEND
            sta   (PTR2),y
            iny
            lda   VI_RGEND+1
            sta   (PTR2),y
            iny
            lda   VI_RGNEW
            sta   (PTR2),y
            iny
            lda   VI_RGNEW+1
            sta   (PTR2),y
            clc
            lda   VI_RGEND
            adc   VI_RGNEW
            sta   VI_RGEND
            lda   VI_RGEND+1
            adc   VI_RGNEW+1
            sta   VI_RGEND+1
            clc
            rts

* VI_RG_STORE -- the LAST act of every yank/delete core: if a "x
* prefix is pending (VI_RGSEL), save the unnamed register into
* register x and clear the prefix. No prefix = a plain return.
* CLOBBERS: A, X, Y, PTR0-2, VI_RG*.
VI_RG_STORE lda   VI_RGSEL
            bne   :go
            rts
:go         sec
            sbc   #1
            sta   VI_RGI
            stz   VI_RGSEL
            lda   VI_REGTY
            bne   :ml
            lda   VI_RGI               ;a one-liner: pack VI_REG
            jsr   VI_RG_BEG
            lda   #<VI_REG
            sta   PTR0
            lda   #>VI_REG
            sta   PTR0+1
            jsr   VI_RG_PUT
            lda   #1
            jmp   VI_RG_FIN
:ml         lda   #VI_RGU
            sta   VI_RGS
            jsr   VI_RG_LEN
            lda   VI_RGOLD
            ora   VI_RGOLD+1
            bne   :cp
            rts                        ;the yank failed: nothing
:cp         jmp   VI_RG_COPY

* VI_RG_LOAD -- the FIRST act of p/P: if a "x prefix is pending,
* unpack register x into the unnamed register and clear the
* prefix. OUT: carry clear = go ahead (also with no prefix);
* carry set = nothing to put (register empty, or no room to
* stage it), bell rung. CLOBBERS: A, X, Y, PTR0-2, VI_RG*,
* VI_REGTY, VI_REGLCNT, VI_REG.
VI_RG_LOAD  lda   VI_RGSEL
            bne   :go
            clc
            rts
:go         sec
            sbc   #1
            sta   VI_RGI
            stz   VI_RGSEL
            jsr   VI_RG_LEN
            lda   VI_RGOLD
            ora   VI_RGOLD+1
            bne   :has
            jsr   VI_BELL
            sec
            rts
:has        ldy   #0
            lda   (PTR2),y
            clc
            adc   #<VI_RGARENA
            sta   PTR1
            iny
            lda   (PTR2),y
            adc   #>VI_RGARENA
            sta   PTR1+1
            ldy   #0
            lda   (PTR1),y              ;type
            bne   :ml
            sta   VI_REGTY
            clc                         ;skip the header
            lda   PTR1
            adc   #2
            sta   PTR1
            bcc   :s
            inc   PTR1+1
:s          lda   #<VI_REG
            sta   PTR2
            lda   #>VI_REG
            sta   PTR2+1
            jsr   VI_RG_STRCP
            clc
            rts
:ml         sta   VI_RGKEY             ;type, kept past the copy
                                  ;(VI_RG_DEL reuses VI_RGK)
            iny
            lda   (PTR1),y
            sta   VI_RGN                ;count
            lda   VI_RGI
            sta   VI_RGS
            lda   #VI_RGU
            sta   VI_RGI
            jsr   VI_RG_COPY            ;register -> entry 26
            bcs   :out
            lda   VI_RGKEY
            sta   VI_REGTY
            lda   VI_RGN
            sta   VI_REGLCNT
            clc
:out        rts

* VI_RG_RDBEG -- before reading the unnamed multi-line register:
* point VI_RGP at its first string. OUT: carry set = it is empty
* (a failed or over-long yank), bell rung.
VI_RG_RDBEG jsr   VI_RG_LCON
            lda   #VI_RGU
            jsr   VI_RG_LEN
            lda   VI_RGOLD
            ora   VI_RGOLD+1
            bne   :ok
            jsr   VI_BELL
            sec
            rts
:ok         ldy   #0
            lda   (PTR2),y
            clc
            adc   #<VI_RGARENA
            sta   VI_RGP
            iny
            lda   (PTR2),y
            adc   #>VI_RGARENA
            sta   VI_RGP+1
            clc                         ;skip the header
            lda   VI_RGP
            adc   #2
            sta   VI_RGP
            bcc   :nb
            inc   VI_RGP+1
:nb         clc
            rts

* VI_RG_NEXT -- IN: PTR2 = a low-window buffer (>=255 bytes),
* VI_RGP = the next string. Copy it there, NUL included, advance
* VI_RGP. OUT: A = its length. CLOBBERS: A, X, Y, PTR1, PTR2.
VI_RG_NEXT  jsr   VI_RG_LCON
            lda   VI_RGP
            sta   PTR1
            lda   VI_RGP+1
            sta   PTR1+1
            jsr   VI_RG_STRCP
            lda   PTR1
            sta   VI_RGP
            lda   PTR1+1
            sta   VI_RGP+1
            txa
            sec
            sbc   #1
            rts

*---------------------------------------------------------------
* VI_OP_RGPFX -- `"`: read the register name (a-z; anything else
* is an error), then the command it prefixes (with its own
* optional count, combined with one typed before the `"`), and
* run it through VI_OPKEY with VI_RGSEL set. The yank/delete/put
* cores see the prefix (VI_RG_STORE / VI_RG_LOAD); a command
* that
* never reaches one (a refused motion, J, r, ~) just has the
* prefix cleared on the way out. A `c` that falls into insert
* never returns here: its store ran BEFORE the insert and
* cleared
* the prefix itself. CLOBBERS: everything VI_OPKEY's commands
* do.
*---------------------------------------------------------------
VI_OP_RGPFX lda   VI_COUNT
            pha
            lda   VI_COUNT+1
            pha
            jsr   VI_RAWKEY
            bcs   :abort
            sec
            sbc   #"a"                  ;a (high bit set)
            cmp   #26
            bcs   :bad
            clc
            adc   #1
            sta   VI_RGSEL
            jsr   VI_READCMD
            bcs   :abort
            cmp   #VI_KQUOTE           ;`""`: refuse, never nest
            beq   :bad
            sta   VI_RGKEY
            pla
            sta   ED_TMP16B+1
            pla
            sta   ED_TMP16B
            jsr   VI_OP_COMBINE
            lda   VI_RGKEY
            jsr   VI_OPKEY
            bcc   :ran
            jsr   VI_BELL              ;not an operator or a put
:ran        stz   VI_RGSEL
            rts
:bad        pla
            pla
            stz   VI_RGSEL
            jmp   VI_BELL
:abort      pla
            pla
            stz   VI_RGSEL
            jmp   VI_PLACE_CUR

*---------------------------------------------------------------
* VI_OP_PMLA / VI_OP_PMLB -- `p` / `P` of a charwise register
* that
* spans lines (VI_REGTY 2): split the cursor line at column c
* (after the cursor char for p, at it for P), glue slot 0 onto
* the head, insert the middle slots as whole lines, and glue the
* last slot onto the tail on a new line below. The cursor lands
* on the start of the pasted text (column c of the split line).
* A full repaint: the line count changed by REGLCNT-1.
*---------------------------------------------------------------
VI_OP_PMLA  lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT
            jsr   STRLEN
            beq   :col0                 ;empty line -> column 0
            lda   VI_CURCOL
            clc
            adc   #1
            bra   VI_OP_PML
:col0       lda   #0
            bra   VI_OP_PML
VI_OP_PMLB  lda   VI_CURCOL

*---------------------------------------------------------------
* VI_OP_PML -- IN: A = the split column. CLOBBERS: A, X, Y,
* PTR0,
* PTR1, ED_TMP16, ED_SRC, SUBSCR, VI_RG*, EX_SNAPSHOT's, the
* repaint's.
*---------------------------------------------------------------
VI_OP_PML   sta   VI_RGC
            jsr   EX_SNAPSHOT
            lda   ED_CURLINE
            sta   VI_RGL
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   VI_RGL+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT
            jsr   STRLEN
            sta   VI_RGLN
            cmp   VI_RGC             ;column past the end: clamp
            bcs   :cok
            sta   VI_RGC
:cok        ldy   VI_RGC                ;the tail -> SUBSCR+256
            ldx   #0
:sfx        cpy   VI_RGLN
            bcs   :sfxd
            lda   (PTR0),y
            sta   SUBSCR+256,x
            iny
            inx
            bra   :sfx
:sfxd       lda   #0
            sta   SUBSCR+256,x
            ldy   #0                    ;the head -> SUBSCR
:pfx        cpy   VI_RGC
            bcs   :pfxd
            lda   (PTR0),y
            sta   SUBSCR,y
            iny
            bra   :pfx
:pfxd       jsr   VI_RG_RDBEG           ;slot 0 lands after the
            clc                         ;head, in SUBSCR itself
            lda   #<SUBSCR
            adc   VI_RGC
            sta   PTR2
            lda   #>SUBSCR
            adc   #0
            sta   PTR2+1
            jsr   VI_RG_NEXT            ;A = its length
            clc
            adc   VI_RGC
            bcs   :cap
            cmp   #255
            bcc   :tot
:cap        lda   #254
:tot        tax
            lda   #0
            sta   SUBSCR,x
            jsr   VI_RG_BUMP
            lda   VI_RGL
            sta   ED_TMP16
            lda   VI_RGL+1
            sta   ED_TMP16+1
            lda   PTR0
            sta   ED_SRC
            lda   PTR0+1
            sta   ED_SRC+1
            jsr   ED_SETSLOT
            lda   VI_RGL                ;insert after the split
            sta   VI_RGAF               ;line, in order
            lda   VI_RGL+1
            sta   VI_RGAF+1
            lda   #1
            sta   VI_RGK
:mid        lda   VI_REGLCNT
            sec
            sbc   #1                   ;index of the last string
            cmp   VI_RGK
            beq   :last
            lda   #<SUBSCR
            sta   PTR2
            lda   #>SUBSCR
            sta   PTR2+1
            jsr   VI_RG_NEXT
            tax
            jsr   VI_RG_BUMP
            jsr   VI_RG_INSAF
            bcs   :fin
            inc   VI_RGK
            bra   :mid
:last       lda   #<SUBSCR
            sta   PTR2
            lda   #>SUBSCR
            sta   PTR2+1
            jsr   VI_RG_NEXT
            tax                       ;X = the last string's end
            ldy   #0
:l2         lda   SUBSCR+256,y
            beq   :l2d
            cpx   #254
            bcs   :l2d
            sta   SUBSCR,x
            iny
            inx
            bra   :l2
:l2d        lda   #0
            sta   SUBSCR,x
            jsr   VI_RG_BUMP
            jsr   VI_RG_INSAF
:fin        lda   VI_RGL
            sta   ED_CURLINE
            lda   VI_RGL+1
            sta   ED_CURLINE+1
            lda   VI_RGC
            sta   VI_CURCOL
            jsr   VI_CLAMP_COL
            jmp   VI_REPAINT

* VI_RG_BUMP -- IN: X = length of the text in SUBSCR. OUT: PTR0
* =
* its stored descriptor (ED_BUMP_ALLOC's). CLOBBERS: A, ED_SRC.
VI_RG_BUMP  lda   #<SUBSCR
            sta   ED_SRC
            lda   #>SUBSCR
            sta   ED_SRC+1
            txa
            jmp   ED_BUMP_ALLOC

* VI_RG_INSAF -- IN: PTR0 = a stored descriptor. Insert it as a
* new line after VI_RGAF; VI_RGAF becomes that line. OUT: carry
* set = line table full, nothing inserted.
VI_RG_INSAF lda   VI_RGAF
            sta   ED_TMP16
            lda   VI_RGAF+1
            sta   ED_TMP16+1
            lda   PTR0
            sta   ED_SRC
            lda   PTR0+1
            sta   ED_SRC+1
            jsr   ED_INSRT_AFTR
            bcs   :full
            lda   ED_CURLINE
            sta   VI_RGAF
            lda   ED_CURLINE+1
            sta   VI_RGAF+1
:full       rts
