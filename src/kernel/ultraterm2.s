*---------------------------------------------------------------
* ultraterm2.s -- the UltraTerm driver's ROUTINES (UT_CLAIM and
* everything after it), split from ultraterm.s 2026-09-13 for
* real Merlin's 41,215 B source buffer: KULT was 713 B over as
* one module. Cut at a top-level label with no `:local` zone
* straddling it and no short branch across it; `put`
* IMMEDIATELY AFTER ultraterm.s, so no byte moves. The data
* cells and tables stay in ultraterm.s; the shared card/CRTC
* equates are in inc/ultraterm.equ. See ultraterm.s's
* header for the design.
*---------------------------------------------------------------
*---------------------------------------------------------------
* UT_CLAIM -- make the $CC00 window reachable, then hand $C3xx
* straight back to the internal ROM. Must run before ANY window
* access.
*
* $C0Bx is always decoded, but $CC00 needs INTCXROM=0 and slot 3
* owning the $C800 last-claimant latch. maux calls the SmartPort
* at $C7xx for every file operation, and that steals the latch
* --
* so this is not init-time setup, it is a per-entry
* precondition. The alternative is writing characters into
* whatever card claimed the window last.
*
* WHY SLOTC3ROM DOES NOT STAY SET -- the original-card IRQ bug,
* docs/CONSOLE.md section 13. The //e ROM vectors IRQs through
* $C3FA (its $FFFE reads FA C3 -- read out of the ROM image, not
* assumed), so whoever owns $C3xx IS the interrupt handler. With
* SLOTC3ROM external that is the Videx firmware. A card carrying
* the March 1985 field-update EPROM has a compatibility stub at
* offset $FA of every page (BIT $C015 / STA $C007) that hands
* off to the internal handler; an UN-updated card -- the
* population that actually exists, including the operator's --
* has pre-enhancement firmware with no stub at all, and maux
* takes interrupts continuously. So the switch is set only
* across the claim and restored immediately after it: exposure
* drops from the whole session to the 12 cycles between the two
* writes below -- and those 12 are masked, so no interrupt can
* be taken inside them at all. check_ultraterm.py measures that
* number rather than trusting this comment.
* learning:01M0ACSFHDGY0P566NCMNHYV57 (the $C3FA mechanism),
* learning:01M0J3YRZ8A7Y9B4FMED3XFS58 (the field update).
*
* THE CLAIM SURVIVES THE RESTORE -- measured, not reasoned from
* a soft-switch table. Clearing SLOTC3ROM changes only who
* DECODES $C3xx; it does not touch the card's own $C800 enable.
* Probed on verilogapple AND MAME 0.286, same numbers: $C800
* reads $38 (card ROM) after the claim and STILL $38 after
* CLRSLOTC3ROM. What does take the window away is an INTERNAL
* $C3xx access -- exactly what an IRQ vectoring through $C3FA on
* the ROM path is -- which sets INTC8ROM and makes $C800 read
* $4C; only $CFFF (or a re-claim) undoes that. INTCXROM merely
* MASKS the window: clearing it hands the card back with no
* re-claim needed. Hence claim per entry, release-then-claim
* unconditionally, and a restore that costs nothing.
* learning:01M0J7NS4352S0MABTR2MENPA8 carries the probe table.
*
* PHP/PLP rather than SEI/CLI: this runs from tty paths that are
* themselves called masked, and a blind `cli` would unmask the
* kernel mid-operation. Worst-case ADDED interrupt-disabled
* window is 24 cycles (five 4-cycle accesses plus the PLP), and
* zero when the caller was already masked.
*
* `sta CLRSLOTC3ROM`, not `stz`: the value written is ignored --
* only the address matters -- so the store leaves A holding the
* signature byte UT_DETECT is about to compare.
*
* WHAT THIS DOES NOT FIX, stated so nobody re-derives it: an
* interrupt taken DURING a multi-cell burst (UT_CLR_ROW's 80
* writes, UT_CLR_ALL's 4096) still loses the window, because
* MAIN_IRQ_SHIM's own epilogue does CLRC8ROM + a SmartPort
* re-claim on every main-context tick (timer.s). That was true
* before this change and is unaffected by it -- the shim steals
* the window the same way whichever side of the switch $C3FA
* fell on. Closing it means claiming per cell or masking the
* whole burst, which is an interrupt-latency decision, not a
* correctness-on-an-original-card one.
*---------------------------------------------------------------
UT_CLAIM
            lda   UT_WHELD                 ;ours for this
            beq   :claim                   ;masked write?
            rts                            ;still holds
                                           ;skip the re-claim
:claim      php                            ;the caller's mask is
                                           ;not ours to change
            sei
            sta   CLRINTCXROM              ;slot ROM space, not
                                           ;internal
            sta   SETSLOTC3ROM             ;$C300 = the card,
                                           ;not the //e 80-col
                                           ;firmware
            lda   CLRC8ROM                 ;release the previous
                                           ;holder FIRST -- a
                                           ;$Cnxx read only
                                           ;claims a FREE window
                                           ;(and on iron a bare
                                           ;claim leaves BOTH
                                           ;cards latched). The
                                           ;a2sd-class SmartPort
                                           ;firmware does its
                                           ;own BIT $CFFF at
                                           ;entry, so releasing
                                           ;here never strands
                                           ;the disk driver.
            lda   UT_SIG                   ;the READ is the
                                           ;claim
            sta   CLRSLOTC3ROM             ;$C3FA belongs to the
                                           ;internal handler
                                           ;again -- the claim
                                           ;above outlives this
            plp
            rts

*---------------------------------------------------------------
* UT_DETECT -- carry CLEAR if an UltraTerm answers in slot 3.
* Sets UT_PRESENT. Signature is $87 at $C30C.
*---------------------------------------------------------------
* The fail path used to restore SLOTC3ROM here by itself, so an
* EMPTY slot 3 could not turn the $C3FA IRQ vector fetch into a
* floating-bus jump. UT_CLAIM now restores it on every exit, so
* both paths get that guarantee -- and the PRESENT-card path
* needs it just as badly, because an un-updated UltraTerm has no
* IRQ stub to land on. The store is gone rather than kept as
* belt-and-braces: a redundant one reads as load-bearing and
* invites someone to move the real one.
UT_DETECT
            stz   UT_PRESENT
            jsr   UT_CLAIM                 ;leaves A = the
                                           ;signature byte, and
                                           ;$C3xx already back
                                           ;to internal ROM
            cmp   #$87
            beq   :found
            sec
            rts
:found      lda   #1
            sta   UT_PRESENT
            clc
            rts

*---------------------------------------------------------------
* UT_SET_REG -- CRTC Rx = A. X = register number. The address
* register and the data register are separate ports, so this is
* always a two-write sequence.
*---------------------------------------------------------------
UT_SET_REG
            pha
            stx   UT_CRTC_ADDR
            pla
            sta   UT_CRTC_DATA
            rts

*---------------------------------------------------------------
* UT_INIT -- HQ 80x24, card driving the monitor, screen cleared.
*
* R0-R11 are copied from the card's OWN firmware, video format
* 4 (80x24 high quality), at $CF55 (UT_FMT4_ROM) -- what the
* card's own format handler loads. Whatever revision is in the
* slot supplies its own cell height, interlace and frame timing:
* the updated card (v3) is R9 = 8, 9-line cells, 262 lines; the
* ORIGINAL card (v1) is interlaced (R8 = 3), R9 = $0E, a 16-line
* row under the RN-2 rule, with a TALL font that a 9-line table
* clips. Programming only R1, R6 and R9 left R0/R2-R5 as the
* card held them. R12/R13 (display start) and R14/R15 (cursor
* address) are maux's, written below and by UT_CRSR_AT.
* UT_SET_REG leaves X alone, so the loops keep their index.
*
* $CF55 is in the $CC00-$CFFF window, which reads the card ROM
* only with MEMSEL ($C0B2 bit 7) set -- with it clear it is VRAM
* (MAME, both revisions: $50 reads $20, $D0 the table).
*
* GUARD: if $CF55 does not look like a CRTC entry (R1 not 80, or
* R6 not 24), copy UT_CRTC_TBL, the v3 values, instead.
*
* The cursor shape is the entry's R10 start (blink bits cleared:
* steady) and R11 end, kept in UT_CRSR_ST/UT_CRSR_EN.
*---------------------------------------------------------------
UT_INIT
            lda   #1
            sta   UT_INITED
            jsr   UT_CLAIM
            lda   #UT_MEMSEL+UT_VTEMU      ;MEMSEL: $CC00-$CFFF
            sta   UT_PAGE_CTL              ;reads the card ROM
            ldx   #0
            lda   UT_FMT4_ROM+1            ;R1 = 80?
            cmp   #UT_COLS
            bne   :fb
            lda   UT_FMT4_ROM+6            ;R6 = 24?
            cmp   #UT_ROWS
            bne   :fb
:rom        lda   UT_FMT4_ROM,x
            jsr   UT_SET_REG
            inx
            cpx   #12
            bcc   :rom
            sta   UT_CRSR_EN               ;A = R11
            lda   UT_FMT4_ROM+10
            bra   :st
:fb         lda   UT_CRTC_TBL,x
            jsr   UT_SET_REG
            inx
            cpx   #12
            bcc   :fb
            sta   UT_CRSR_EN
            lda   UT_CRTC_TBL+10
:st         and   #$1F                     ;blink bits -> steady
            sta   UT_CRSR_ST
            lda   #UT_VTEMU                ;MEMSEL off: VRAM
            sta   UT_PAGE_CTL

            stz   UT_START                 ;display start =
                                           ;$0000
            stz   UT_START+1
            jsr   UT_WR_START

            lda   #UT_ATTR_INV             ;HQ font, bit-7 cells
            jsr   UT_WR_ATTR               ;inverse -- explicit,
                                           ;never the DIPs

            jsr   UT_CLR_ALL               ;blank all 4 KB, so
                                           ;no stale glyph can
                                           ;scroll into view
                                           ;later

            jsr   UT_CRSR_INIT
            lda   #UT_VIDSEL+UT_VTEMU       ;card takes the
                                            ;monitor, page 0
            sta   UT_PAGE_CTL
            rts

*---------------------------------------------------------------
* UT_CRTC_TBL -- the GUARD fallback: CRTC R0-R11 for the updated
* (v3) card's video format 4, 80x24 HQ, from its firmware (MAME
* a2ultrme frm_b5c9, CRC b71e05e0) at ROM offset $F55 = $F25 +
* 16*3. 9-line cells (R9 = 8), 29 rows + R5 1 = 262 lines a
* field. Used only when the slot's ROM fails the R1/R6 check.
*---------------------------------------------------------------
UT_CRTC_TBL
            dfb   $7A,$50,$5D,$38,$1C,$01   ;R0-R5
            dfb   $18,$1A,$00,$08,$60,$08   ;R6-R11

*---------------------------------------------------------------
* UT_WR_START -- push UT_START into CRTC R12/R13.
*---------------------------------------------------------------
UT_WR_START
            lda   UT_START+1
            ldx   #UT_R_START_HI
            jsr   UT_SET_REG
            lda   UT_START
            ldx   #UT_R_START_LO
            jsr   UT_SET_REG
            rts

*---------------------------------------------------------------
* UT_CRSR_INIT -- hardware block cursor, shape from the card's
* own format-4 entry (UT_CRSR_ST/EN, set by UT_INIT): v3 is rows
* 0-8, the whole 9-line cell; v1 is 0-12. R10 bits 6/5 = 00
* means "display, no blink" (steady; the firmware blinks, maux
* has always been steady); the model treats $20 as non-display,
* which is what UT_CRSR_OFF writes.
*---------------------------------------------------------------
UT_CRSR_INIT
            lda   UT_CRSR_ST
            ldx   #UT_R_CRSR_ST
            jsr   UT_SET_REG
            lda   UT_CRSR_EN
            ldx   #UT_R_CRSR_END
            jsr   UT_SET_REG
            rts

*---------------------------------------------------------------
* UT_ADDR_RC -- UT_ADDR = (UT_START + A*80 + Y) AND $0FFF. A =
* row, Y = column. THE single address computation; see the ring
* note in the header.
*---------------------------------------------------------------
UT_ADDR_RC
            tax                            ;row -> table index
            clc
            lda   UT_ROWOFF_LO,x
            adc   UT_START
            sta   UT_ADDR
            lda   UT_ROWOFF_HI,x
            adc   UT_START+1
            sta   UT_ADDR+1
            tya                            ;+ column
            clc
            adc   UT_ADDR
            sta   UT_ADDR
            lda   UT_ADDR+1
            adc   #0
            and   #>UT_VRAM_MASK           ;makes the 4 KB ring
                                           ;explicit;the page
                                           ;nibble + window
                                           ;offset already wrap
                                           ;to the same 12 bits
                                           ;(header)
            sta   UT_ADDR+1
            rts

*---------------------------------------------------------------
* UT_SEL_PAGE -- window the 256-byte block holding UT_ADDR, and
* keep VIDSEL set. The page select and the "card owns the
* monitor" bit share one register, so a bare page write would
* blank the screen.
*---------------------------------------------------------------
UT_SEL_PAGE
            lda   UT_ADDR+1
            ora   #UT_VIDSEL+UT_VTEMU
            sta   UT_PAGE_CTL
            rts

*---------------------------------------------------------------
* UT_WR_ATTR -- A = UT_ATTR_INV or UT_ATTR_HL (inc/
* ultraterm.equ) -> the Character Attribute Register. The tty
* decides which (TTY_ATTR_APPLY, per console); the driver owns
* the register.
*---------------------------------------------------------------
UT_WR_ATTR  sta   UT_MODE_CTL
            rts

*---------------------------------------------------------------
* UT_VID_PASS -- the inverse of UT_SEL_PAGE: write UT_PAGE_CTL
* with VIDSEL CLEAR, so the card stops driving the monitor and
* the motherboard's own text video shows through. Single-monitor
* head mode (TTY_DUALHEAD=0) calls this when a motherboard
* console takes the glass. The page nibble is kept (harmless
* while the card is not displaying) so the very next UT write
* -- e.g. `vidmode hq` bringing a card console back -- lands on
* a sane page. VTEMU stays set (MAME gates the page field on it;
* see the UT_VTEMU note).
*---------------------------------------------------------------
UT_VID_PASS
            lda   UT_ADDR+1
            ora   #UT_VTEMU
            sta   UT_PAGE_CTL
            rts

*---------------------------------------------------------------
* UT_PUT_CELL -- put display byte A at row X, column Y. Bit 7 of
* A is the card's inverse-video attribute; bits 6-0 are plain
* ASCII. This is NOT the Apple display-code map -- the fold
* TTY_INVERSE_A implements does not apply here.
*---------------------------------------------------------------
UT_PUT_CELL
            sta   UT_CHAR
            iny                            ;UT_EXT -> col+1
            tya                            ;(X=row, Y=col intact
            cmp   UT_EXT,x                 ;here, before the
            bcc   :xr_nor                  ;address math)
            beq   :xr_nor
            sta   UT_EXT,x
:xr_nor     dey
            jsr   UT_CLAIM
            txa
            jsr   UT_ADDR_RC
            jsr   UT_SEL_PAGE
            ldy   UT_ADDR                  ;low byte indexes the
                                           ;window
            lda   UT_CHAR
            sta   UT_WIN,y
            rts

*---------------------------------------------------------------
* UT_PUT_ROW -- write the 80 cells in UT_ROWBUF to row A. ONE
* address computation per row, then a walk of the 256-byte
* window: a row is 80 consecutive ring bytes, so it crosses at
* most one page boundary, and the page nibble is bumped (mod 16,
* the 4 KB ring) exactly when the window offset wraps. The row
* clear and the switch-in repaint (tty7.s VCS_UTBLIT, VIDMODE
* V2.0) both come through here.
*---------------------------------------------------------------
UT_PUT_ROW
            ldx   #0                     ;whole row = [0,80)
            stx   UT_TMPCOL
            ldx   #UT_COLS
            jsr   UT_PUT_SPAN            ;(was a fall-through)
*-- A whole row is authoritative: set UT_EXT EXACTLY from the
*-- row image -- last non-blank + 1, or 0 for an all-blank row.
*-- UT_PUT_SPAN raised it to 80 a moment ago; this lowers it.
            ldx   #UT_COLS-1
:xr_scan    lda   UT_ROWBUF,x
            cmp   #$20
            bne   :xr_found
            dex
            bpl   :xr_scan               ;falls out with X=$FF:
:xr_found   inx                          ;inx -> 0 = all blank
            txa
            ldx   UT_TMPROW              ;the row (UT_PUT_SPAN
            sta   UT_EXT,x               ;left it intact)
            rts

*---------------------------------------------------------------
* UT_PUT_SPAN -- write UT_ROWBUF[UT_TMPCOL..X) to row A starting
* at column UT_TMPCOL: ONE claim + ONE address computation +
* ONE page-select, then a window walk (page nibble bumped on the
* 256-byte wrap). Generalizes UT_PUT_ROW so a RUN is one
* firmware setup, not one UT_PUT_CELL (address recompute + page
* select) per cell -- the per-character card tax (2026-09-04,
* docs/CONSOLE-RUN-BATCH.md). IN: A=row, UT_TMPCOL=start col,
* X=end col (excl). CLOBBERS: A, X, Y, UT_ADDR, UT_TMPROW,
* UT_SPANEND.
*---------------------------------------------------------------
UT_PUT_SPAN
            sta   UT_TMPROW                ;UT_CLAIM clobbers A
            stx   UT_SPANEND               ;end col (exclusive)
            jsr   UT_CLAIM
            lda   UT_TMPROW
            ldy   UT_TMPCOL                ;start col
            jsr   UT_ADDR_RC               ;UT_ADDR=row+start
            jsr   UT_SEL_PAGE
            ldy   UT_ADDR
            ldx   UT_TMPCOL                ;source index = start
:collp      cpx   UT_SPANEND
            bcs   :done
            lda   UT_ROWBUF,x
            sta   UT_WIN,y
            iny
            bne   :same
            inc   UT_ADDR+1                ;crossed a page: next
            lda   UT_ADDR+1                ;block of the ring
            and   #>UT_VRAM_MASK
            sta   UT_ADDR+1
            jsr   UT_SEL_PAGE
:same       inx
            bra   :collp
:done       ldx   UT_TMPROW                ;UT_EXT: raise to the
            lda   UT_SPANEND               ;span's end col
            cmp   UT_EXT,x
            bcc   :xr_keep
            beq   :xr_keep
            sta   UT_EXT,x
:xr_keep    rts

* UT_GET_ROW (the VRAM read-back) moved to tty8.s next to its
* only caller, VCS_UTSAVE: uttest.s `put`s ultraterm.s but not
* tty8.s, and adding the reverse scroll tipped uttest's closure
* over the `as` 16128-byte source window (check-dialect,
* 2026-09-10). UT_GET_ROW calls this file's UT_CLAIM/UT_ADDR_RC/
* UT_SEL_PAGE, fine across the flat kernel namespace.

*---------------------------------------------------------------
* UT_ERS_SPAN -- blank VRAM columns [Y..A) on row X, one claim +
* one ring-address computation, then a window walk (page nibble
* bumped when the offset wraps). The end is clamped to the row's
* dirty bound (UT_EXT: every cell at or past it is already
* blank)
* and the bound is LOWERED to Y when the span reached it -- so a
* tail erase (A = UT_COLS, the UT_ERSLN_VRAM entry: the card
* half of an ESC [ K, one per row of a vi repaint; per-cell it
* was ~79 UT_PUT_CELL calls per row, the '~'-repaint crawl the
* operator watched, 2026-09-04) leaves the bound at Y, and a
* head erase (ESC [ 1 K, Y = 0, A = col+1) leaves it alone
* unless it blanked the whole dirty run. CLOBBERS: A, X, Y,
* UT_ADDR, UT_TMPROW, UT_TMPCOL, UT_EXTEND, UT_SPANEND.
*---------------------------------------------------------------
UT_ERSLN_VRAM
            lda   #UT_COLS                ;tail: [Y, 80)
UT_ERS_SPAN
            stx   UT_TMPROW
            sty   UT_TMPCOL               ;start column
            sta   UT_SPANEND              ;requested end
            cmp   UT_EXT,x                ;past the dirty bound?
            bcc   :endok
            lda   UT_EXT,x                ;clamp to the bound
:endok      sta   UT_EXTEND
            cpy   UT_EXTEND               ;nothing dirty in
            bcs   :xr_skip                ;[Y, end): skip VRAM
            jsr   UT_CLAIM
            lda   UT_TMPROW
            ldy   UT_TMPCOL
            jsr   UT_ADDR_RC              ;UT_ADDR=row+col
            jsr   UT_SEL_PAGE
            ldy   UT_ADDR
            ldx   UT_TMPCOL               ;column counter
            lda   #$20
:elp        cpx   UT_EXTEND               ;walk [Y,bound), not
            bcs   :edone                  ;[Y,80)
            sta   UT_WIN,y
            iny
            bne   :esame
            inc   UT_ADDR+1               ;crossed a page
            lda   UT_ADDR+1
            and   #>UT_VRAM_MASK
            sta   UT_ADDR+1
            jsr   UT_SEL_PAGE             ;clobbers A; Y is 0
            lda   #$20                    ;(wrapped) for the new
                                          ;page -- reload fill
:esame      inx
            bra   :elp
:edone      ldx   UT_TMPROW
            lda   UT_SPANEND              ;reached the bound?
            cmp   UT_EXT,x
            bcc   :xr_skip                ;no: the bound stands
            lda   UT_TMPCOL               ;yes: everything from
            sta   UT_EXT,x                ;Y on is blank now
:xr_skip    rts

*---------------------------------------------------------------
* UT_CLR_ROW -- blank row A: ONE direct VRAM span (UT_ERS_SPAN
* over [0, 80)). It was a row of spaces through UT_PUT_ROW --
* an 80-byte buffer fill, the 80 window stores, then
* UT_PUT_ROW's
* backward scan to rediscover that every cell was blank: half
* the cost of a screen clear and a third of a bottom-row scroll
* (2026-09-12 performance review, item 2 -- measured 52%
* off ED 2 and 35% off one bottom LF with this exact shape).
* The dirty bound is FORCED to 80 first, not trusted: a row the
* scroll just exposed is a ring row whose VRAM still holds
* whatever fell off the top 24 rows ago, and UT_EXT for it is
* the stale bound the row it replaced left behind.
*---------------------------------------------------------------
UT_CLR_ROW
            tax
            lda   #UT_COLS
            sta   UT_EXT,x
            ldy   #0
            bra   UT_ERSLN_VRAM

*---------------------------------------------------------------
* UT_CLR_BODY -- blank the terminal body, all 24 rows (row 0 is
* ordinary content since the 2026-09-03 reclaim, docs/CONSOLE.md
* section 6), matching the 40-column backend's TTY_CLR_BODY.
*---------------------------------------------------------------
UT_CLR_BODY
            lda   #0
            sta   UT_BODYROW
:rowlp      lda   UT_BODYROW
            jsr   UT_CLR_ROW
            inc   UT_BODYROW
            lda   UT_BODYROW
            cmp   #UT_ROWS
            bcc   :rowlp
            rts

*---------------------------------------------------------------
* UT_CLR_ALL -- blank all 4 KB of VRAM, page by page. Init only.
*---------------------------------------------------------------
UT_CLR_ALL
            jsr   UT_CLAIM
            lda   #0
            sta   UT_TMPCOL                ;page counter
:pagelp     lda   UT_TMPCOL
            ora   #UT_VIDSEL+UT_VTEMU
            sta   UT_PAGE_CTL
            ldy   #0
            lda   #$20
:bytelp     sta   UT_WIN,y
            iny
            bne   :bytelp
            inc   UT_TMPCOL
            lda   UT_TMPCOL
            cmp   #16                      ;16 pages x 256 = 4
                                           ;KB
            bne   :pagelp
            ldx   #UT_ROWS-1               ;VRAM all blank now:
:xr_zero    stz   UT_EXT,x                 ;every bound is 0
            dex
            bpl   :xr_zero
            rts

*---------------------------------------------------------------
* UT_SCROLL -- scroll up, in one register write.
*
* Advance the display start; the rows that fall off the top
* become the new bottom rows, so they are cleared. Nothing is
* re-stamped: row 0 scrolls like every other row now.
*---------------------------------------------------------------
*-- By X rows, 1..UT_ROWS-1 (jump scroll, tty4.s TTY_JSCROLL
*-- passes TTY_SCRL_N): the start advances X rows, the bottom X
*-- rows are cleared.
*-- UT_SCROLL (up) and UT_SCROLL_REV (down) are one routine: the
*-- display-start bump, the UT_EXT follow, and the exposed-row
*-- clear are identical in shape, differ only by direction, so
*-- a `ds`-tight module shares them behind UT_SDIR rather than
*-- carrying two near-copies (the 2nd tipped uttest.s over the
*-- `as` 16128 source window, 2026-09-10). X = rows (1..ROWS-1).
UT_SCROLL   ldy   #0                       ;dir 0 = up (forward)
            bra   UT_SCR_GO
UT_SCROLL_REV
            ldy   #1                       ;dir 1 = down
*-- a GLOBAL label, not a :local: UT_SCROLL branches here across
*-- UT_SCROLL_REV's zone, and a cross-zone :local ref breaks in
*-- some put contexts (commons 01M0VJF2DXZR55HGJ8PTN1MNJE) --
*-- merlin32 resolved it by whole-file uniqueness here but real
*-- Merlin / the MAUXEXPR put did not (check-expr, 2026-09-10).
UT_SCR_GO   sty   UT_SDIR
            stx   UT_SCRLN
*-- BUMP: UT_START += UT_COLS per row (up) or -= per row (down),
*-- masked to the 4 KB ring.
:bump       lda   UT_SDIR
            bne   :bdn
            clc
            lda   UT_START
            adc   #UT_COLS
            sta   UT_START
            lda   UT_START+1
            adc   #0
            bra   :bmask
:bdn        sec
            lda   UT_START
            sbc   #UT_COLS
            sta   UT_START
            lda   UT_START+1
            sbc   #0
:bmask      and   #>UT_VRAM_MASK
            sta   UT_START+1
            dex
            bne   :bump
*-- UT_EXT follows the rows (up: low<-high from X; down: high<-
*-- low). The exposed rows' bounds are set by UT_CLR_ROW below.
            lda   UT_SDIR
            bne   :exd
            ldx   #0
            ldy   UT_SCRLN
:exu        cpy   #UT_ROWS
            bcs   :exdone
            lda   UT_EXT,y
            sta   UT_EXT,x
            inx
            iny
            bra   :exu
:exd        ldx   #UT_ROWS-1
:exdl       txa
            sec
            sbc   UT_SCRLN
            bcc   :exdone                  ;src < 0: shift done
            tay
            lda   UT_EXT,y
            sta   UT_EXT,x
            dex
            bra   :exdl
:exdone     jsr   UT_CLAIM
            jsr   UT_WR_START
*-- CLEAR the exposed rows: bottom X (up, [ROWS-X, ROWS)) or top
*-- X (down, [0, X)).
            lda   UT_SDIR
            bne   :cdn
            lda   #UT_ROWS
            sec
            sbc   UT_SCRLN
            sta   UT_BODYROW               ;start = ROWS-X
            lda   #UT_ROWS                 ;end = ROWS
            bra   :clrset
:cdn        stz   UT_BODYROW               ;start = 0
            lda   UT_SCRLN                 ;end = X
:clrset     sta   UT_CLREND
:clrlp      lda   UT_BODYROW
            jsr   UT_CLR_ROW
            inc   UT_BODYROW
            lda   UT_BODYROW
            cmp   UT_CLREND
            bcc   :clrlp
            rts

*---------------------------------------------------------------
* UT_CRSR_AT -- park the hardware cursor at row X, column Y. No
* glyph save/restore: the CRTC inverts the cell itself.
*---------------------------------------------------------------
UT_CRSR_AT
            jsr   UT_CLAIM
            txa
            jsr   UT_ADDR_RC
            lda   UT_ADDR+1
            ldx   #UT_R_CRSR_HI
            jsr   UT_SET_REG
            lda   UT_ADDR
            ldx   #UT_R_CRSR_LO
            jsr   UT_SET_REG
            jsr   UT_CRSR_INIT             ;R10 bits 6/5 = 00 ->
                                           ;displayed
            rts

*---------------------------------------------------------------
* UT_CRSR_OFF -- hide the hardware cursor (R10 bit 5 =
* non-display).
*---------------------------------------------------------------
UT_CRSR_OFF
            jsr   UT_CLAIM
            lda   #$20
            ldx   #UT_R_CRSR_ST
            jsr   UT_SET_REG
            rts

*---------------------------------------------------------------
* Row offsets: row * 80, as a table. Avoids a multiply in the
* per-character path.
*---------------------------------------------------------------
UT_ROWOFF_LO
            dfb   <0,<80,<160,<240,<320,<400,<480,<560
            dfb   <640,<720,<800,<880,<960,<1040,<1120,<1200
            dfb   <1280,<1360,<1440,<1520
            dfb   <1600,<1680,<1760,<1840
UT_ROWOFF_HI
            dfb   >0,>80,>160,>240,>320,>400,>480,>560
            dfb   >640,>720,>800,>880,>960,>1040,>1120,>1200
            dfb   >1280,>1360,>1440,>1520
            dfb   >1600,>1680,>1760,>1840

*---------------------------------------------------------------
