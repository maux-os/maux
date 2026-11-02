*---------------------------------------------------------------
* tty4.s -- the scroll primitive and the bank-select helper.
*
* SPLIT OUT OF tty2.s (S9 L4, 2026-08-29): that file's own
* stripped text was 16629 B, past `as`'s 16126 B source window,
* so
* it could never be assembled inside maux as one REL module. The
* cut is at a section boundary and this file is `put`
* immediately
* after its parent, so the emitted bytes are unchanged -- which
* is
* what check-bytes asserts.
*---------------------------------------------------------------
* TTY_SCROLL -- move the terminal body up one line.
*
* The terminal is all 24 rows, 0-23 (docs/CONSOLE.md section 6:
* the row-0 reclaim, 2026-09-03). The first copy is row 1 -> row
* 0, same as every other row.
*
* Row 0 used to be exempt: a status/banner line owned by whoever
* booted the image, not the tty, and TTY_SCROLL started its copy
* at row 2 to leave it alone. That reservation, the banner, and
* the reflow machinery that kept row 0 legible across a width
* change are all gone now -- the per-console store already had
* room for 24 rows, so this just needed new offsets, not new
* storage. check-play now asserts row 0 scrolls like any other
* row.
*
* SCROLL BY N (jump scroll, 2026-09-03): TTY_SCRL_N = rows to
* move, 1..TTY_ROWS-1, set by TTY_JSCROLL below. Rows N..23 go
* to 0..23-N in one pass and the bottom N rows are blanked. A
* burst of N lines in one write() used to cost N full passes
* (~36k cycles each on native-80, docs/CONSOLE-OPT.md sec 6).
TTY_SCROLL
            lda   TTY_DSTBASE+1
            beq   :glass
            jmp   VCS_SCROLL           ;a stored screen scrolls
                                       ;itself: the redirect
                                       ;covers WRITES, and a
                                       ;scroll must READ the
                                       ;rows it moves
:glass      lda   TTY_BKND
            cmp   #TTY_BKUT
            bne   :notut
*-- A WHOLE-SCREEN scroll (TOP=0 AND BOT=TTY_ROWS -- DECSTBM's
*-- default, VT102 slice 1: the margins are not the whole screen
*-- any time DECSTBM narrowed them) is JUST the CRTC
*-- display-start
*-- bump + clear of the exposed rows. The store is no longer
*-- scrolled in lock-step (that per-scroll copy was the card's
*-- real scroll cost); it is rebuilt from VRAM on switch-away
*-- (VCS_UTSAVE), which the readable window now allows. A REGION
*-- scroll (IL/DL, or SU/SD under a narrowed DECSTBM) cannot use
*-- display-start -- it moves the whole visible window -- so it
*-- moves VRAM rows directly (UT_SRGN_UP, tty8.s), which the
*-- readable window also allows.
            lda   TTY_SCRL_TOP
            bne   :utrgn
            lda   TTY_SCRL_BOT
            cmp   TTY_ROWS
            bne   :utrgn
            ldx   TTY_SCRL_N               ;rows, in X (uttest
                                           ;image owns no cell)
            jmp   UT_SCROLL
:utrgn      jmp   UT_SRGN_UP               ;region up
:notut      cmp   #TTY_BKN8
            bne   TTY_SCROLL40
            jsr   TTY_SCROLL40             ;main half first (the
                                           ;odd display columns
                                           ;live in main memory)
            jmp   N8_SCRL_AUX              ;then the aux half --
                                           ;even columns
* -- Row-address caching (2026-08-20, docs/PROCIO.md "Make
* -- scrolling cheap"): this row's SRC (TTY_ROW_SRC_A(N)) IS
* -- next iteration's DST (TTY_ROW_DST_A(N)=TTY_ROW_DST_A((N+1)
* -- -1)) -- copying P_PTR1 into P_PTR2 after the row copy gets
* -- that address for free, instead of a SECOND table-lookup
* -- JSR. One TTY_ROW_xxx_A call per row instead of two, and
* -- P_PTR2 already holds row 23's address when the loop ends,
* -- so the trailing clear needs no lookup of its own either.
* -- The 4-way unrolled inner copy trades the per-byte INY/CPY/
* -- BNE loop-test overhead (6502 has no block-move instruction)
* -- for one test per 4 bytes -- real savings, kept to a modest
* -- unroll factor because this kernel image is within a few
* -- bytes of check-dual's own $4000 pad budget (docs/PROCIO.md
* -- "Bulk TTY_WRITE" results -- a full 40-way unroll would blow
* -- it outright).
*-- (The one-lookup-per-row trick above was N=1 only; scroll-by-
*-- N pays a DST lookup per row, ~30 cycles, 2% of a pass.)
TTY_SCROLL40
            lda   TTY_SCRL_TOP             ;src=TOP+N dst=TOP
            clc                             ;(TOP=0 = whole
            adc   TTY_SCRL_N                ;screen)
            sta   P_IDX
:rowlp      lda   P_IDX
            jsr   TTY_ROW_SRC_A             ;P_PTR1 = row P_IDX
            lda   P_IDX
            sec
            sbc   TTY_SCRL_N
            jsr   TTY_ROW_DST_A             ;P_PTR2 = row-N
            ldy   #0
:copy       lda   (P_PTR1),y
            sta   (P_PTR2),y
            iny
            lda   (P_PTR1),y
            sta   (P_PTR2),y
            iny
            lda   (P_PTR1),y
            sta   (P_PTR2),y
            iny
            lda   (P_PTR1),y
            sta   (P_PTR2),y
            iny
            cpy   #40
            bne   :copy
            inc   P_IDX
            lda   P_IDX
            cmp   TTY_SCRL_BOT              ;region bot (VT102
            bcc   :rowlp                    ;slice 1, DECSTBM)
            lda   TTY_SCRL_BOT              ;blank the bottom N
            sec                             ;of the REGION
            sbc   TTY_SCRL_N
            sta   P_IDX
:clrlp      lda   P_IDX
            jsr   TTY_ROW_DST_A
            ldy   #0
            lda   #$A0
:clear      sta   (P_PTR2),y
            iny
            cpy   #40
            bne   :clear
            inc   P_IDX
            lda   P_IDX
            cmp   TTY_SCRL_BOT
            bcc   :clrlp
            rts

*---------------------------------------------------------------
* TTY_SCRL_REV -- reverse of TTY_SCROLL: move body DOWN
* by TTY_SCRL_N rows, blank the N exposed rows at the TOP. The
* `ESC [ n T` (SD) path a partial scroll-UP rides (vi `k`), the
* mirror of TTY_SCROLL/`ESC [ n S`. On the card it is a CRTC
* display-start DECREMENT (UT_SCROLL_REV), on 40/N8 a downward
* row copy, on a background console a store scroll.
*---------------------------------------------------------------
TTY_SCRL_REV
            lda   TTY_DSTBASE+1
            beq   :glass
            jmp   VCS_SCRL_REV
:glass      lda   TTY_BKND
            cmp   #TTY_BKUT
            bne   :notut
            lda   TTY_SCRL_TOP            ;a display-start decr
            bne   :utrgn                   ;moves the WHOLE
            lda   TTY_SCRL_BOT             ;window: only a full-
            cmp   TTY_ROWS                 ;screen region may
            bne   :utrgn                   ;(TTY_SCROLL's own
            ldx   TTY_SCRL_N               ;test; review VT9)
            jmp   UT_SCROLL_REV
:utrgn      jmp   UT_SRGN_DN               ;region down
:notut      cmp   #TTY_BKN8
            bne   TTY_SCR40_REV
            jsr   TTY_SCR40_REV
            jmp   N8_SAUX_REV

* TTY_SCR40_REV -- rows [0, textrows-N) move DOWN to [N,
* textrows); top N blanked. Copies dst high->low so the shifted
* rows never overwrite an un-copied source (dst = src + N).
TTY_SCR40_REV
            lda   TTY_SCRL_TOP             ;floor=TOP+N: lowest
            clc                             ;dst + blank end
            adc   TTY_SCRL_N                ;(TOP=0 -> floor=N)
            sta   TTY_SCRL_FLR
            lda   TTY_SCRL_BOT              ;dst=region
            sec                             ;bottom-1
            sbc   #1                        ;(VT102 sl 1)
            sta   P_IDX
:rowlp      lda   P_IDX
            jsr   TTY_ROW_DST_A             ;P_PTR2 = dst row
            lda   P_IDX
            sec
            sbc   TTY_SCRL_N
            jsr   TTY_ROW_SRC_A             ;P_PTR1 = dst-N
            ldy   #0
:copy       lda   (P_PTR1),y
            sta   (P_PTR2),y
            iny
            lda   (P_PTR1),y
            sta   (P_PTR2),y
            iny
            lda   (P_PTR1),y
            sta   (P_PTR2),y
            iny
            lda   (P_PTR1),y
            sta   (P_PTR2),y
            iny
            cpy   #40
            bne   :copy
            dec   P_IDX
            lda   P_IDX
            cmp   TTY_SCRL_FLR              ;dst>=floor: more
            bcs   :rowlp
            lda   TTY_SCRL_TOP              ;blank [TOP,TOP+N)
            sta   P_IDX
:clrlp      lda   P_IDX
            jsr   TTY_ROW_DST_A
            ldy   #0
            lda   #$A0
:clear      sta   (P_PTR2),y
            iny
            cpy   #40
            bne   :clear
            inc   P_IDX
            lda   P_IDX
            cmp   TTY_SCRL_FLR
            bcc   :clrlp
            rts


TTY_CLR_BODY
            lda   TTY_BKND
            cmp   #TTY_BKUT
            bne   :notut
*-- VRAM only -- the store follows on switch-away (VCS_UTSAVE).
            jmp   UT_CLR_BODY
:notut      cmp   #TTY_BKN8
            bne   TTY_CLR_BD40
            jsr   TTY_CLR_BD40             ;main half (odd cols)
            jmp   N8_CLR_AUX               ;aux half (even cols)
TTY_CLR_BD40
            lda   #0
            sta   P_IDX
:rowlp      lda   P_IDX
            jsr   TTY_ROW_DST_A
            ldy   #0
            lda   #$A0
:clear      jsr   TTY_STORE_Y
            iny
            cpy   #40
            bne   :clear
            inc   P_IDX
            lda   P_IDX
            cmp   TTY_ROWS
            bcc   :rowlp
            rts

* Cursor. The 40-column backend has no cursor hardware, so it
* saves the glyph under the cursor and paints an inverse copy
* over it. The UltraTerm has a real CRTC cursor (R14/R15
* address, R10/R11 shape), so it just parks it -- no save, no
* restore, and nothing to get out of step. Which is as well:
* the save half reads the cell back, and the card's VRAM is
* write-only over the bus (docs/CONSOLE.md section 10a).
TTY_CRSR_SHOW
            lda   TTY_DSTBASE+1
            beq   TTY_CRSR_SHW2
            rts
TTY_CRSR_SHW2
            lda   VC_CRSR_VIS
            beq   :show
            rts
:show       lda   TTY_BKND
            cmp   #TTY_BKUT
            bne   :notut
            ldx   VC_ROW
            ldy   VC_COL
            jsr   UT_CRSR_AT
            lda   #1
            sta   VC_CRSR_VIS
            rts
:notut      cmp   #TTY_BKN8
            bne   :show40
            jsr   N8_LOAD                 ;glyph under cursor --
            sta   VC_CRSR_SAV             ;the aux half IS
                                          ;readable, unlike the
                                          ;card's VRAM
            jsr   TTY_INVERSE_A
            jsr   N8_STORE
            lda   #1
            sta   VC_CRSR_VIS
            rts
:show40     lda   VC_ROW
            jsr   TTY_ROW_DST_A
            ldy   VC_COL
            lda   (P_PTR2),y
            sta   VC_CRSR_SAV
            jsr   TTY_INVERSE_A           ;inverse form of the
                                          ;saved glyph
            sta   (P_PTR2),y
            lda   #1
            sta   VC_CRSR_VIS
            rts

*---------------------------------------------------------------
* VCS_SCROLL -- scroll a STORED screen up one row, all 24.
*
* BankCopy bank-to-bank inside the annex, one row at a time,
* then blank the last. It cannot reuse the glass scroll: that
* one READS its source rows through P_PTR1, and reads are not
* redirectable here: RAMRD governs instruction fetch and must
* never be toggled by code living in $0200-$BFFF
* (learning:01KW1GTYGVYAPQRGS5P7J66RWD), which is where the
* kernel is. Writes go through RAMWRTAUX, which is safe; reads
* have to be somebody else's problem, and BankCopy is that
* somebody.
*---------------------------------------------------------------
VCS_SCROLL
            lda   TTY_SCRL_TOP            ;src = TOP+N (TOP=0 ->
            clc                            ;N, whole screen)
            adc   TTY_SCRL_N
            sta   P_IDX
:rowlp      lda   P_IDX
            jsr   VCS_SRC_A               ;K_BC_SRC = row P_IDX
            lda   P_IDX
            sec
            sbc   TTY_SCRL_N
            jsr   VCS_DST_A               ;K_BC_DST = row-N
            lda   TTY_COLS
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            sta   K_BC_DSTKIND
            stz   K_BC_SRCBANK
            stz   K_BC_DSTBANK
            jsr   BankCopy
            inc   P_IDX
            lda   P_IDX
            cmp   TTY_SCRL_BOT         ;region bottom (VT102
            bne   :rowlp               ;slice 1, DECSTBM)
            lda   TTY_SCRL_BOT         ;blank the bottom N
            sec                        ;rows of the REGION --
            sbc   TTY_SCRL_N           ;these ARE redirected,
            sta   P_IDX                ;so ordinary writes
:blklp      lda   P_IDX
            jsr   TTY_ROW_DST_A
            ldy   #0
            jsr   TTY_BLANK_A
:blank      jsr   TTY_STORE_Y
            iny
            cpy   TTY_COLS
            bne   :blank
            inc   P_IDX
            lda   P_IDX
            cmp   TTY_SCRL_BOT
            bne   :blklp
            rts

*---------------------------------------------------------------
* VCS_SCRL_REV -- scroll a STORED screen DOWN N, blank the
* top N: reverse of VCS_SCROLL, for a redirected (background)
* console's SD (`ESC [ n T`). Copies dst high->low so a shifted
* row never overwrites an un-copied source (dst = src + N).
*---------------------------------------------------------------
VCS_SCRL_REV
            lda   TTY_SCRL_TOP            ;floor = TOP+N (TOP=0
            clc                            ;-> N): lowest dst +
            adc   TTY_SCRL_N               ;blank end
            sta   TTY_SCRL_FLR
            lda   TTY_SCRL_BOT             ;dst=region
            sec                            ;bottom-1
            sbc   #1                       ;(VT102 sl 1)
            sta   P_IDX
:rowlp      lda   P_IDX
            jsr   VCS_DST_A               ;K_BC_DST = row P_IDX
            lda   P_IDX
            sec
            sbc   TTY_SCRL_N
            jsr   VCS_SRC_A               ;K_BC_SRC = dst-N
            lda   TTY_COLS
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            sta   K_BC_DSTKIND
            stz   K_BC_SRCBANK
            stz   K_BC_DSTBANK
            jsr   BankCopy
            dec   P_IDX
            lda   P_IDX
            cmp   TTY_SCRL_FLR            ;dst>=floor: more
            bcs   :rowlp
            lda   TTY_SCRL_TOP            ;blank [TOP,TOP+N)
            sta   P_IDX
:blklp      lda   P_IDX
            jsr   TTY_ROW_DST_A
            ldy   #0
            jsr   TTY_BLANK_A
:blank      jsr   TTY_STORE_Y
            iny
            cpy   TTY_COLS
            bne   :blank
            inc   P_IDX
            lda   P_IDX
            cmp   TTY_SCRL_FLR
            bcc   :blklp
            rts

*---------------------------------------------------------------
* VCS_CLR_BODY -- blank a STORED screen's body, all 24 rows x
* VC_STR_COLS. The cold half of TTY_WR_ENTER. It cannot reuse
* TTY_CLR_BD40: that loop's 40 is load-bearing on the N8 GLASS
* (it clears the MAIN half of an 80-column screen, N8_CLR_AUX
* the other), while the store's rows are VC_STR_COLS wide
* whatever the glass backend -- a 40-column clear would leave
* the right half of an 80-column console's fresh store as
* whatever the annex held (review finding 4's tail,
* 2026-08-31).
*---------------------------------------------------------------
VCS_CLR_BODY
            lda   #0
            sta   P_IDX
:rowlp      lda   P_IDX
            jsr   TTY_ROW_DST_A
            ldy   #0
            jsr   TTY_BLANK_A
:clear      jsr   TTY_STORE_Y
            iny
            cpy   #VC_STR_COLS
            bne   :clear
            inc   P_IDX
            lda   P_IDX
            cmp   #VC_STR_ROWS
            bcc   :rowlp
            rts

VCS_SRC_A   tax
            clc
            lda   TTY_DSTBASE
            adc   VCS_RLO,x
            sta   K_BC_SRCADDR
            lda   TTY_DSTBASE+1
            adc   VCS_RHI,x
            sta   K_BC_SRCADDR+1
            rts

VCS_DST_A   tax
            clc
            lda   TTY_DSTBASE
            adc   VCS_RLO,x
            sta   K_BC_DSTADDR
            lda   TTY_DSTBASE+1
            adc   VCS_RHI,x
            sta   K_BC_DSTADDR+1
            rts

*-- THE CURSOR IS NOT PAINTED ON A CONSOLE NOBODY IS LOOKING AT.
*-- Both halves also READ the glyph they are covering, and that
*-- read cannot be redirected (see VCS_SCROLL), so this guard is
*-- correctness as much as economy.
TTY_CRSR_HIDE
            lda   TTY_DSTBASE+1
            beq   TTY_CRSR_HID2
            rts
TTY_CRSR_HID2
            jsr   TTY_FLSETTLE         ;flash in flight: put
                                       ;the page back FIRST
            lda   VC_CRSR_VIS
            bne   :hide
            rts
:hide       lda   TTY_BKND
            cmp   #TTY_BKUT
            bne   :notut
            jsr   UT_CRSR_OFF
            stz   VC_CRSR_VIS
            rts
:notut      cmp   #TTY_BKN8
            bne   :hide40
            lda   VC_CRSR_SAV             ;put the saved glyph
            jsr   N8_STORE                ;back
            stz   VC_CRSR_VIS
            rts
:hide40     lda   VC_ROW
            jsr   TTY_ROW_DST_A
            ldy   VC_COL
            lda   VC_CRSR_SAV
            sta   (P_PTR2),y
            stz   VC_CRSR_VIS
            rts

*---------------------------------------------------------------
* THE CONSOLE STORE (docs/CONSOLE.md sec 13)
*
* One screen image per console in the annex, so a console that
* is not on the glass still HAS a screen. Saved and restored by
* VC_SWITCH; the per-character path pays nothing.
*
* 40-COLUMN ONLY, and that is a size decision, not a design one.
* A 40-column glass row is 40 CONTIGUOUS bytes (the text page's
* interleave is between rows, not within one), so a row moves
* with a single BankCopy and this whole feature is a pointer
* walk. The general version -- read every cell through a backend
* dispatch into a staging buffer -- was written, measured at
* 438 bytes, and DOES NOT FIT: 438 bytes of `ds` alone wedges
* MAUXPLAY's boot identically, and the headroom is about 220.
* See docs/CONSOLE.md sec 13.
*
* All 24 rows, 0-23: row 0 is ordinary per-console content as
* of the 2026-09-03 reclaim (sec 6) -- it is no longer a
* reserved status line, and a switch now carries it like any
* other row.
*---------------------------------------------------------------
VCS_C0      equ VC_STR_ADDR
VCS_C1      equ VCS_C0+VC_STR_SIZE
VCS_C2      equ VCS_C1+VC_STR_SIZE
VCS_C3      equ VCS_C2+VC_STR_SIZE
*-- Entries 4-7: the ALT-SCREEN stores (tty5.s VCA_ENTER, docs/
*-- VI-ALTSCREEN.md) -- console n's parked main screen is store
*-- n+VC_COUNT, so every mover below serves it by index alone.
VCS_C4      equ VCA_STR_A
VCS_C5      equ VCA_STR_A+VCA_STR_SIZE
VCS_C6      equ VCA_STR_B
VCS_C7      equ VCA_STR_B+VCA_STR_SIZE

VCS_CLO     dfb <VCS_C0
            dfb <VCS_C1
            dfb <VCS_C2
            dfb <VCS_C3
            dfb <VCS_C4
            dfb <VCS_C5
            dfb <VCS_C6
            dfb <VCS_C7
VCS_CHI     dfb >VCS_C0
            dfb >VCS_C1
            dfb >VCS_C2
            dfb >VCS_C3
            dfb >VCS_C4
            dfb >VCS_C5
            dfb >VCS_C6
            dfb >VCS_C7

*---------------------------------------------------------------
* VCS_BLIT_X -- move console X's screen between the glass and
* its annex image. A = 0 saves (glass -> annex), nonzero loads.
*
* Refuses any backend but the 40-column text page: native
* 80-column splits a row across main and aux behind 80STORE, and
* the UltraTerm's VRAM cannot be read back at all (see
* TTY_CRSR_SHOW's note, "the aux half IS readable, unlike the
* card's VRAM"). Both are named gaps, not oversights.
*
* CLOBBERS VC_ROW, which the caller saves -- VC_SWITCH is
* restoring it from the struct on either side of this anyway.
*---------------------------------------------------------------
VCS_BLIT_X
            sta   VCS_DIR
            lda   TTY_BKND
            cmp   #TTY_BK40
            beq   :ok
            cmp   #TTY_BKN8
            beq   :ok8                 ;VIDMODE V1: the N8 blit
                                       ;(VCS_N8BLIT, tty6.s)
            cmp   #TTY_BKUT
            bne   :out
*-- UT (V2.3): SAVE reads the card's VRAM back into the store
*-- (VCS_UTSAVE, now the window reads); LOAD repaints the card
*-- from the store (VCS_UTBLIT). No write-through any more, so
*-- the save is real work, on switch-away only.
            lda   P_PTR1
            pha
            lda   P_PTR1+1
            pha
            lda   VCS_DIR
            bne   :utload
            jsr   VCS_UTSAVE
            bra   :utdone
:utload     jsr   VCS_UTBLIT
:utdone     pla
            sta   P_PTR1+1
            pla
            sta   P_PTR1
:out        rts
:ok8        lda   P_PTR1
            pha
            lda   P_PTR1+1
            pha
            jsr   VCS_N8BLIT
            pla
            sta   P_PTR1+1
            pla
            sta   P_PTR1
            rts
            ;-- P_PTR1 IS THE CALLER'S. TTY_WRITE walks the
            ;-- caller's buffer with it, and a console switch
            ;-- can now arrive from inside TTY_WRITE (the ESC [
            ;-- n z sequence, tty2.s), so this routine has to
            ;-- hand it back. P_PTR2 needs no such care --
            ;-- TTY_WR_CELL rewrites it on every character, so
            ;-- nothing can be relying on it across one.
:ok         lda   P_PTR1
            pha
            lda   P_PTR1+1
            pha
            jsr   VCS_BLIT_I
            pla
            sta   P_PTR1+1
            pla
            sta   P_PTR1
            rts

VCS_BLIT_I  lda   VCS_CLO,x         ;annex ptr = console base --
            sta   P_PTR1            ;row 0 is real content now
            lda   VCS_CHI,x
            sta   P_PTR1+1
            stz   VC_ROW
:row        lda   VC_ROW
            jsr   TTY_ROW_DST_A     ;P_PTR2 = this row on the
            jsr   VCS_BCROW         ;glass, 40 contiguous bytes
            clc
            lda   P_PTR1
            adc   #VC_STR_COLS      ;stride is the SLOT width,
            sta   P_PTR1            ;so the layout survives a
            lda   P_PTR1+1          ;backend change
            adc   #0
            sta   P_PTR1+1
            inc   VC_ROW
            lda   VC_ROW
            cmp   #VC_STR_ROWS
            bne   :row
            rts

*---------------------------------------------------------------
* VCS_BCROW -- one row between the glass (P_PTR2, main) and the
* annex (P_PTR1, bank 0), direction in VCS_DIR. The two
* directions differ only in the KIND bytes and which endpoint is
* which, so the block is filled once and the ends swapped.
*---------------------------------------------------------------
VCS_BCROW
            lda   TTY_COLS          ;LIVE width, not the stride
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            stz   K_BC_SRCBANK
            stz   K_BC_DSTBANK      ;bank 0 = the annex
            lda   VCS_DIR
            bne   :load
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            ldx   P_PTR2
            ldy   P_PTR2+1
            stx   K_BC_SRCADDR
            sty   K_BC_SRCADDR+1
            ldx   P_PTR1
            ldy   P_PTR1+1
            stx   K_BC_DSTADDR
            sty   K_BC_DSTADDR+1
            jmp   BankCopy
:load       lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            lda   #BC_KIND_MAIN
            sta   K_BC_DSTKIND
            ldx   P_PTR1
            ldy   P_PTR1+1
            stx   K_BC_SRCADDR
            sty   K_BC_SRCADDR+1
            ldx   P_PTR2
            ldy   P_PTR2+1
            stx   K_BC_DSTADDR
            sty   K_BC_DSTADDR+1
            jmp   BankCopy

VCS_DIR     ds  1


TTY_ROW_SRC_A
            tax
            lda   TTY_ROW_LO,x
            sta   P_PTR1
            lda   TTY_ROW_HI,x
            sta   P_PTR1+1
            rts

*---------------------------------------------------------------
* TTY_ROW_DST_A -- P_PTR2 = the destination for row A.
*
* THE ONE PLACE THE RENDERER IS REDIRECTED. Every 40-column
* write ends at `sta (P_PTR2),y` with P_PTR2 from here --
* TTY_WR_CELL, TTY_BLNK_CELL, the clear, the scroll -- so
* pointing it at a console's stored screen instead of the text
* page routes ALL of them at once, with no per-caller changes.
*
* The store is LINEAR where the glass interleaves, which is why
* it needs its own row table rather than reusing TTY_ROW_LO/HI.
*---------------------------------------------------------------
*---------------------------------------------------------------
* TTY_STORE_Y -- store A at (P_PTR2),y, in the annex if the
* renderer is redirected.
*
* WHY THE BRACKET IS HERE AND NOT AROUND THE RENDERER. Holding
* RAMWRTAUX across TTY_PUT_BYTE would send the renderer's OWN
* state -- VC_ROW, VC_COL, the escape machine, all of VC_STATE,
* all main memory -- into the aux bank as well. Only the cell
* store may be redirected, so only the cell store is bracketed.
* TTY_SVBANK puts the caller's bank back without re-reading a
* PCB; TTY_WR_ENTER captured it from PRC_SEL_CRBNK's return.
*---------------------------------------------------------------
*-- PRESERVES A (and Y); clobbers X. The clear and blank loops
*-- load their fill byte ONCE and store it 40-80 times, so an
*-- exit that leaves TTY_SVBANK in A fills a stored screen with
*-- the caller's BANK NUMBER -- seen as rows of inverse letters
*-- on the first chvt into a written-to console (review
*-- finding 1, 2026-08-31).
TTY_STORE_Y
            ldx   TTY_DSTBASE+1
            bne   :aux
            sta   (P_PTR2),y
            rts
:aux        pha
            lda   #0
            sta   BANKSEL
            sta   RAMWRTAUX
            pla
            sta   (P_PTR2),y
            sta   RAMWRTMAIN
            pha
            lda   TTY_SVBANK
            sta   BANKSEL
            pla
            rts

*-- VCS_ERS_TAIL (the card's ESC [ K store-tail fill,
*-- 2026-09-04)
*-- was RETIRED 2026-09-12: the store is rebuilt from VRAM on
*-- switch-away (tty8.s VCS_UTSAVE) since 2026-09-10, so a
*-- foreground erase has no store to keep -- and the fill was a
*-- quarter of every ESC [ K (performance review, item 3).

TTY_ROW_DST_A
            tax
            ldy   TTY_DSTBASE+1
            bne   :store
            lda   TTY_ROW_LO,x
            sta   P_PTR2
            lda   TTY_ROW_HI,x
            sta   P_PTR2+1
            rts
:store      clc
            lda   TTY_DSTBASE
            adc   VCS_RLO,x
            sta   P_PTR2
            lda   TTY_DSTBASE+1
            adc   VCS_RHI,x
            sta   P_PTR2+1
            rts

*-- row*VC_STR_COLS for rows 0-23, the store's linear geometry.
VCS_RLO     dfb   0,80,160,240,64,144,224,48
            dfb   128,208,32,112,192,16,96,176
            dfb   0,80,160,240,64,144,224,48
VCS_RHI     dfb   0,0,0,0,1,1,1,2
            dfb   2,2,3,3,3,4,4,4
            dfb   5,5,5,5,6,6,6,7

TTY_ROW_LO
            dfb   <$0400,<$0480,<$0500,<$0580,<$0600,<$0680
            dfb   <$0700,<$0780
            dfb   <$0428,<$04A8,<$0528,<$05A8,<$0628,<$06A8
            dfb   <$0728,<$07A8
            dfb   <$0450,<$04D0,<$0550,<$05D0,<$0650,<$06D0
            dfb   <$0750,<$07D0
TTY_ROW_HI
            dfb   >$0400,>$0480,>$0500,>$0580,>$0600,>$0680
            dfb   >$0700,>$0780
            dfb   >$0428,>$04A8,>$0528,>$05A8,>$0628,>$06A8
            dfb   >$0728,>$07A8
            dfb   >$0450,>$04D0,>$0550,>$05D0,>$0650,>$06D0
            dfb   >$0750,>$07D0

*---------------------------------------------------------------
* N8 -- the native //e 80-column backend (docs/CONSOLE.md sec
* 12 queue item 1, built 2026-08-23). The portable baseline of
* the sec 13 hierarchy: no slot card, no $C3xx involvement, so
* it is immune to the UltraTerm $C3FA IRQ-vector exposure and
* it is the only possible console on a IIc.
*
* THE MECHANISM. In 80-column text the EVEN display columns
* come from AUX bank 0's $0400-$07FF and the ODD columns from
* main's; a cell's byte offset is its row base + column/2, the
* SAME interleaved row table (TTY_ROW_LO/HI) both halves.
* Odd columns are plain main-memory stores. Even columns are
* reached through the 80STORE+PAGE2 route
* (learning:01KW1GTYHGXMBZNR6DMQB2F712, [fact]): with 80STORE
* set, PAGE2 alone routes $0400-$07FF reads AND writes to aux,
* and RAMRD/RAMWRT are ignored there -- so the fetch stream is
* never touched (the RAMRD trap does not apply) and the aux
* half is READABLE, which the UltraTerm's VRAM is not.
*
* BANK 0 IS FORCED FIRST, every access. The same learning's
* rig-corroborated finding is that an 80STORE+PAGE2 access
* lands in the $C073-SELECTED bank, not unconditionally in
* bank 0 -- and BANKSEL is sticky with the last process's bank
* (the CWD-BANK-BUG shape, src/kernel/sched.s CWD_READ). That
* claim is [likely] grade (one emulator family); writing with
* bank 0 forced is correct under EITHER reading, so this
* driver does not depend on it. The restore is
* PRC_SEL_CRBNK -- the kernel's one source of truth for the
* current bank, needed because $C073 is write-only and because
* a preempted process resumes FETCHING from its bank.
*
* THE WINDOW IS INTERRUPT-MASKED (php/sei/plp): resting state
* is 80STORE OFF -- mm.hw.equ marks it STEADY STATE, fork
* and BankCopy bracket against it, and S1's fork gate has a
* sabotage on exactly this switch. An IRQ inside the window
* would run the tick (and its tty echo path) over a flipped
* routing. Worst case masked stretch is one 40-byte row copy,
* ~600 cycles -- same order as UT_CLAIM's discipline, well
* under a VBL period. check_play80n.py asserts the switch is
* off at rest and masked while flipped, the same
* teeth-on-the-invariant shape as check_ultraterm.py's
* SLOTC3ROM bracket.
*
* Row 0 is ordinary content here exactly as on the 40-column
* backend as of the 2026-09-03 reclaim: scroll copies start at
* row 1 (dest row 0), and unlike the UltraTerm there is no
* re-stamp to do because nothing exempts a row any more.
