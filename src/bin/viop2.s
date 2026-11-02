*---------------------------------------------------------------
* viop2.s -- the rest of vi's operators: r, ~, p, P, J and the
* put
* helpers (VI_OP_PCH_AT, VI_OP_PLW). Split out of viop.s
* 2026-10-06
* (a seam, byte-neutral) so viop.s and `vi`'s manifest stay
* under
* real Merlin's source buffer (check-dialect rule 3) once the
* register arena (virg.s) landed. `put` by vi.s ONLY, after
* viop.s.
* Everything it needs is viop.s's (VI_REGTY/VI_REG, VI_CNTNORM,
* ...).
*---------------------------------------------------------------
*---------------------------------------------------------------
* VI_OP_R -- `r`{char}: replace count chars under/after the
* cursor with ONE typed char, cursor lands on the LAST replaced
* char. Refuses (no snapshot, no read even attempted past the
* count check) if the line does not have count chars left from
* the cursor -- real vi's own "not enough characters" refusal.
* Mutates EX_LINECACHE in place THROUGH the pointer ED_LINETEXT
* just handed back (same-length edit, no splice needed) before
* re-persisting it via the usual ED_BUMP_ALLOC/ED_SETSLOT pair.
* CLOBBERS: A, X, Y, PTR0, ED_TMP16, ED_SRC, VI_FCHAR, VI_TMP,
* VI_TMP2 (+ VI_RAWKEY/VI_RPT_LN's own).
*---------------------------------------------------------------
VI_OP_R     jsr   VI_CNTNORM
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT
            jsr   STRLEN
            sta   VI_TMP
            sec
            lda   VI_TMP
            sbc   VI_CURCOL
            sta   VI_TMP2
            lda   VI_COUNT+1
            bne   :refuse
            lda   VI_TMP2
            cmp   VI_COUNT
            bcs   :ok
:refuse     rts
:ok         jsr   VI_RAWKEY
            bcs   :refuse
            sta   VI_FCHAR
            jsr   EX_SNAPSHOT
            ldy   VI_CURCOL
            ldx   VI_COUNT
:loop       lda   VI_FCHAR
            sta   (PTR0),y
            iny
            dex
            bne   :loop
            lda   PTR0
            sta   ED_SRC
            lda   PTR0+1
            sta   ED_SRC+1
            lda   VI_TMP
            jsr   ED_BUMP_ALLOC
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            lda   PTR0
            sta   ED_SRC
            lda   PTR0+1
            sta   ED_SRC+1
            jsr   ED_SETSLOT
            clc
            lda   VI_CURCOL
            adc   VI_COUNT
            sec
            sbc   #1
            sta   VI_CURCOL
            jmp   VI_RPT_LN

*---------------------------------------------------------------
* VI_OP_TILDE -- `~`: toggle the case of count chars from the
* cursor forward (clamped to the line's own length), cursor
* lands one past the last toggled char. A true no-op (no
* snapshot) on an empty line / cursor already past the end.
* Masks each byte to 7 bits only to CLASSIFY it (same defensive
* posture VI_CLASS already uses for mixed 7-/8-bit text) but
* toggles bit 5 of the ORIGINAL byte, preserving bit 7 either
* way. CLOBBERS: A, X, Y, PTR0, ED_TMP16, ED_SRC, VI_TMP,
* VI_TMP2.
*---------------------------------------------------------------
VI_OP_TILDE jsr   VI_CNTNORM
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT
            jsr   STRLEN
            sta   VI_TMP
            cmp   VI_CURCOL
            beq   :none
            bcc   :none
            jsr   EX_SNAPSHOT
            sec
            lda   VI_TMP
            sbc   VI_CURCOL
            sta   VI_TMP2
            lda   VI_COUNT+1
            bne   :usemax
            lda   VI_TMP2
            cmp   VI_COUNT
            bcs   :usecount
:usemax     bra   :haven
:usecount   lda   VI_COUNT
:haven      sta   VI_TMP2
            ldy   VI_CURCOL
            ldx   VI_TMP2
:loop       cpx   #0
            beq   :loopdone
            lda   (PTR0),y
            and   #$7F
            cmp   #'A'
            bcc   :notupper
            cmp   #'Z'+1
            bcs   :notupper
            lda   (PTR0),y
            eor   #$20
            sta   (PTR0),y
            bra   :adv
:notupper   lda   (PTR0),y
            and   #$7F
            cmp   #'a'
            bcc   :adv
            cmp   #'z'+1
            bcs   :adv
            lda   (PTR0),y
            eor   #$20
            sta   (PTR0),y
:adv        iny
            dex
            bra   :loop
:loopdone   lda   PTR0
            sta   ED_SRC
            lda   PTR0+1
            sta   ED_SRC+1
            lda   VI_TMP
            jsr   ED_BUMP_ALLOC
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            lda   PTR0
            sta   ED_SRC
            lda   PTR0+1
            sta   ED_SRC+1
            jsr   ED_SETSLOT
            clc
            lda   VI_CURCOL
            adc   VI_TMP2
            sta   VI_CURCOL
            jsr   VI_CLAMP_COL
            jmp   VI_RPT_LN
:none       rts

*---------------------------------------------------------------
* VI_OP_PA -- `p`: put the register AFTER the cursor. Charwise:
* splices VI_REG into the current line right after the char
* under the cursor (at the end of an empty line, `p` degrades to
* `P`'s own column-0 case). Linewise: opens VI_REGLCNT lines
* right after the current one. CLOBBERS: A, X, Y, PTR0, PTR1,
* ED_TMP16, ED_TMP16B, ED_SRC, SUBSCR, VI_TMP, VI_TMP2 (+ VI_OP_
* PCH_AT/VI_OP_PLW/VI_RPT_LN/VI_REPAINT's own).
*---------------------------------------------------------------
VI_OP_PA    jsr   VI_RG_LOAD            ;"x prefix: unpack it
            bcs   :out                  ;empty register: bell
            lda   VI_REGTY
            beq   :chr
            jsr   VI_RG_RDBEG           ;entry 26 must hold it
            bcs   :out
            lda   VI_REGTY
            cmp   #1
            beq   :lw
            jmp   VI_OP_PMLA            ;charwise, spans lines
:out        rts
:chr        lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT
            jsr   STRLEN
            beq   :col0
            lda   VI_CURCOL
            clc
            adc   #1
            bra   :havecol
:col0       lda   #0
:havecol    sta   VI_TMP2
            jsr   EX_SNAPSHOT
            lda   VI_TMP2
            jsr   VI_OP_PCH_AT
            jmp   VI_RPT_LN
:lw         jsr   EX_SNAPSHOT
            lda   ED_CURLINE
            sta   VI_TMP
            lda   ED_CURLINE+1
            sta   VI_TMP+1
            jsr   VI_OP_PLW
            lda   VI_REGLCNT            ;the put lines, cursor
            ldx   #0                    ;the first: insert-line
            jmp   VI_RPINS              ;escape + paint them

*---------------------------------------------------------------
* VI_OP_PB -- `P`: put the register BEFORE the cursor. CLOBBERS:
* same as VI_OP_PA.
*---------------------------------------------------------------
VI_OP_PB    jsr   VI_RG_LOAD
            bcs   :out
            lda   VI_REGTY
            beq   :chr
            jsr   VI_RG_RDBEG
            bcs   :out
            lda   VI_REGTY
            cmp   #1
            beq   :lw
            jmp   VI_OP_PMLB
:out        rts
:chr        lda   VI_CURCOL
            sta   VI_TMP2
            jsr   EX_SNAPSHOT
            lda   VI_TMP2
            jsr   VI_OP_PCH_AT
            jmp   VI_RPT_LN
:lw         jsr   EX_SNAPSHOT
            lda   ED_CURLINE
            ora   ED_CURLINE+1
            beq   :atzero
            lda   ED_CURLINE
            sec
            sbc   #1
            sta   VI_TMP
            lda   ED_CURLINE+1
            sbc   #0
            sta   VI_TMP+1
            bra   :go
:atzero     stz   VI_TMP
            stz   VI_TMP+1
:go         jsr   VI_OP_PLW
            lda   VI_REGLCNT
            ldx   #0
            jmp   VI_RPINS

*---------------------------------------------------------------
* VI_OP_PCH_AT -- IN: A = the column to splice VI_REG's text
* into (caller already snapshotted). Builds prefix+VI_REG+suffix
* into SUBSCR, one ED_BUMP_ALLOC+ED_SETSLOT. OUT: VI_CURCOL = A
* (the start of the pasted text). CLOBBERS: A, X, Y, PTR0,
* ED_TMP16, ED_SRC, SUBSCR, VI_TMP, VI_TMP2.
*---------------------------------------------------------------
VI_OP_PCH_AT
            sta   VI_TMP2
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            jsr   ED_LINETEXT
            jsr   STRLEN
            sta   VI_TMP
            ldy   #0
            ldx   #0
:pfx        cpy   VI_TMP2
            beq   :pfxdone
            cpy   VI_TMP
            bcs   :pfxdone
            lda   (PTR0),y
            sta   SUBSCR,x
            iny
            inx
            bra   :pfx
:pfxdone    ldy   #0
:reg        lda   VI_REG,y
            beq   :regdone
            cpx   #254
            bcs   :regdone
            sta   SUBSCR,x
            iny
            inx
            bra   :reg
:regdone    ldy   VI_TMP2
:sfx        cpy   VI_TMP
            bcs   :sfxdone
            cpx   #254
            bcs   :sfxdone
            lda   (PTR0),y
            sta   SUBSCR,x
            iny
            inx
            bra   :sfx
:sfxdone    stz   SUBSCR,x
            lda   #<SUBSCR
            sta   ED_SRC
            lda   #>SUBSCR
            sta   ED_SRC+1
            txa
            jsr   ED_BUMP_ALLOC
            lda   ED_CURLINE
            sta   ED_TMP16
            lda   ED_CURLINE+1
            sta   ED_TMP16+1
            lda   PTR0
            sta   ED_SRC
            lda   PTR0+1
            sta   ED_SRC+1
            jsr   ED_SETSLOT
            lda   VI_TMP2
            sta   VI_CURCOL
            rts

*---------------------------------------------------------------
* VI_OP_PLW -- linewise put core. IN: VI_TMP/VI_TMP+1 = the
* "afterline" to insert the FIRST register line after (0 = start
* of buffer). Inserts VI_REGLCNT lines in order (each insert's
* own "afterline" becomes the line just inserted, so later lines
* land AFTER earlier ones -- preserves the yanked order). Keeps
* its own slot counter in VI_TMP2, NOT X -- STRLEN/ED_BUMP_
* ALLOC/ED_INSRT_AFTR all clobber X internally, the SAME hazard
* VI_OP_LWY's own header names (found live together, `yy`+`p`,
* 2026-09-03). OUT: ED_CURLINE = the FIRST inserted line, VI_
* CURCOL = 0. CLOBBERS: A, X, Y, PTR0, PTR1, ED_TMP16,
* ED_TMP16B, ED_SRC, VI_TMP2.
*---------------------------------------------------------------
VI_OP_PLW   lda   VI_TMP
            clc
            adc   #1
            sta   ED_TMP16B
            lda   VI_TMP+1
            adc   #0
            sta   ED_TMP16B+1
            stz   VI_TMP2
            jsr   VI_RG_RDBEG     ;VI_RGP = the first string
:loop       lda   VI_TMP2
            cmp   VI_REGLCNT
            bcs   :done
            lda   #<SUBSCR        ;stage the string low
            sta   PTR2
            lda   #>SUBSCR
            sta   PTR2+1
            jsr   VI_RG_NEXT      ;A = its length
            tax
            lda   #<SUBSCR
            sta   ED_SRC
            lda   #>SUBSCR
            sta   ED_SRC+1
            txa
            jsr   ED_BUMP_ALLOC
            lda   VI_TMP
            sta   ED_TMP16
            lda   VI_TMP+1
            sta   ED_TMP16+1
            lda   PTR0
            sta   ED_SRC
            lda   PTR0+1
            sta   ED_SRC+1
            jsr   ED_INSRT_AFTR
            lda   ED_CURLINE
            sta   VI_TMP
            lda   ED_CURLINE+1
            sta   VI_TMP+1
            inc   VI_TMP2
            bra   :loop
:done       sec                   ;first = last - cnt + 1
            lda   VI_TMP          ;(VI_TMP = the last inserted;
            sbc   VI_REGLCNT      ;ED_INSRT_AFTR rewrites
            sta   ED_CURLINE      ;ED_TMP16B each call, so it
            lda   VI_TMP+1        ;is NOT the first line)
            sbc   #0
            sta   ED_CURLINE+1
            inc   ED_CURLINE
            bne   :nocy
            inc   ED_CURLINE+1
:nocy       stz   VI_CURCOL
            rts

*---------------------------------------------------------------
* VI_OP_J -- `J`: join the current line with count further ones
* (no count / count<2 -> classic default of 2 lines total).
* Sets ED_ADDR1/ED_ADDR2/ED_ADDRCNT itself, snapshots, then
* reaches the shared ED_CMD_J (edsub2.s, unchanged) via the SAME
* ED_D1FLAG/ED_D1RET redirect VI_COLON/VI_ZZ already use for a
* classic handler that always ends `jmp MAINLOOP` -- MAINLOOP's
* own top (edparse.s) checks ED_D1FLAG before ever blocking on
* fd 0, so `jmp ED_CMD_J` (never `jsr` -- it has no `rts`) lands
* back at :ret instead. A join with nothing to join (last
* line, ED_ADDR1==ED_ADDR2 after clamping) is ED_CMD_J's own
* documented no-op -- harmless even though the snapshot already
* ran. CLOBBERS: A, X, Y, PTR0, ED_TMP16, ED_ADDR1, ED_ADDR2,
* ED_ADDRCNT (+ ED_CMD_J's own).
*---------------------------------------------------------------
VI_OP_J     lda   VI_COUNT
            beq   :def
            cmp   #1
            beq   :def
            bra   :have
:def        lda   #2
            sta   VI_COUNT
            stz   VI_COUNT+1
:have       lda   ED_CURLINE
            sta   ED_ADDR1
            lda   ED_CURLINE+1
            sta   ED_ADDR1+1
            clc
            lda   ED_CURLINE
            adc   VI_COUNT
            sta   ED_ADDR2
            lda   ED_CURLINE+1
            adc   VI_COUNT+1
            sta   ED_ADDR2+1
            lda   ED_ADDR2
            bne   :nb
            dec   ED_ADDR2+1
:nb         dec   ED_ADDR2
            lda   ED_ADDR2+1
            cmp   ED_NLINES+1
            bcc   :ok
            bne   :clamp
            lda   ED_ADDR2
            cmp   ED_NLINES
            bcc   :ok
            beq   :ok
:clamp      lda   ED_NLINES
            sta   ED_ADDR2
            lda   ED_NLINES+1
            sta   ED_ADDR2+1
:ok         lda   #2
            sta   ED_ADDRCNT
            jsr   EX_SNAPSHOT
            jsr   VI_SAVENL            ;count before join
            lda   #<:ret
            sta   ED_D1RET
            lda   #>:ret
            sta   ED_D1RET+1
            lda   #1
            sta   ED_D1FLAG
            jmp   ED_CMD_J
*-- ED_CMD_J leaves ED_ADDR1 = the first FOLDED line (it bumped
*-- it past the joined line before its ED_DLT_RANGE), dot on the
*-- joined line; its single-line no-op leaves both alone -- so
*-- dot still == ADDR1 says nothing changed. VI_DELCNT reads the
*-- pre-join count captured above. (2026-09-11)
:ret        lda   ED_CURLINE
            cmp   ED_ADDR1
            bne   :joined
            lda   ED_CURLINE+1
            cmp   ED_ADDR1+1
            bne   :joined
            jmp   VI_PLACE_CUR          ;no-op join
:joined     lda   ED_ADDR1             ;first folded line
            sta   VI_DA1
            lda   ED_ADDR1+1
            sta   VI_DA1+1
            ldx   #1                    ;the joined line changed
            jmp   VI_RP_LWD             ;+ the folded lines gone
