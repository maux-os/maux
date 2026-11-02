*---------------------------------------------------------------
* tty8.s -- the console store's MOVERS: the two glass<->store
* blits (native-80 and UltraTerm), the UltraTerm write-through,
* and the scroll policy that feeds them (jump scroll).
*
* SPLIT OUT OF tty4.s and tty7.s, 2026-09-03, for the reason
* every ttyN.s exists: `as`'s 16,128-byte source window charges
* each unit its LARGEST single put, and VIDMODE V2.0's card
* repaint pushed tty7.s to 13.6k and tty4.s to 13.4k against
* tty3.s's 12.3k -- 16 test units went over at once. This file
* is `put` right after tty7.s in every kernel manifest; kernel
* modules are one flat symbol space, so nothing declares
* anything.
*
* What is here and why it belongs together: VCS_N8BLIT /
* VCS_UTBLIT move a console's screen between its annex store
* and the glass on a switch (VCS_UTSAVE reads the card's VRAM
* back on the way out, docs/VIDMODE.md sec 4/10); TTY_JSCROLL
* decides how far a scroll moves, and every scroll -- glass or
* store -- obeys it.
*---------------------------------------------------------------
*---------------------------------------------------------------
* TTY_JSCROLL -- the cursor just stepped off the bottom MARGIN
* row (TT9_NEWLINE/TT9_IND, tty9.s -- VT102 slice 1: the region
* is [VC_MTOP,VC_MBOT], not the whole screen, the moment DECSTBM
* has narrowed it). Scroll -- and JUMP-scroll when more of this
* write() is already staged: TTY_JS_COUNT counts the CR/LF bytes
* still unread in the TTY_OUTBUF chunk, the region moves up by
* 1+that in ONE pass, and VC_ROW lands that many rows above
* VC_MBOT so the counted newlines fill the blank rows without
* scrolling again. The final screen is identical to scrolling
* once per line: only relative motion happens in between, and
* every counted byte reaches TT9_NEWLINE/TT9_IND (the count
* stops
* at an ESC, whose sequence may swallow one). An UNDER-count is
* always safe -- the later newlines scroll normally. Cap at the
* region height minus 1 (was TTY_ROWS-1 before margins existed).
*---------------------------------------------------------------
TTY_JSCROLL
            lda   VC_MTOP
            sta   TTY_SCRL_TOP
            lda   VC_MBOT
            inc   a
            sta   TTY_SCRL_BOT              ;exclusive bound
            sec
            sbc   TTY_SCRL_TOP              ;region height-1 =
            dec   a                         ;the cap (was the
            sta   TT9_RH                    ;TTY_ROWS-1 cap)
            jsr   TTY_JS_COUNT
            inc   a                         ;rows = 1+lookahead
            cmp   TT9_RH
            bcc   :capped
            lda   TT9_RH
:capped     sta   TTY_SCRL_N
            jsr   TTY_SCROLL
            lda   VC_MBOT
            sec
            sbc   TTY_SCRL_N
            inc   a
            sta   VC_ROW
            rts

* TTY_JS_COUNT -- A = CR/LF bytes after the current one in this
* write's staged chunk (TTY_OUTBUF[P_FD+1..P_PIPE)), 0 outside
* the chunk loop (echo, the 1-byte path). Stops at ESC; capped
* at 22 (more cannot be used). Clobbers A/X/Y only.
TTY_JS_COUNT
            ldy   #0
            lda   TTY_JS_ON
            beq   :out
            ldx   P_FD
:scan       inx
            cpx   P_PIPE
            bcs   :out
            lda   TTY_OUTBUF,x
            and   #$7F
            cmp   #$1B
            beq   :out
            cmp   #$0D
            bne   :notcr
            lda   VC_TMODE              ;a raw CR is a column
            and   #TMD_OPOST            ;return, not a newline:
            beq   :scan                 ;count it only under
            bra   :nl                   ;OPOST (review VT1)
:notcr      cmp   #$0A                  ;LF, VT, FF all index
            bcc   :scan
            cmp   #$0D
            bcs   :scan
:nl         iny
            cpy   #22
            bcc   :scan
:out        tya
            rts

*---------------------------------------------------------------
* TTY_BLANK_A -- A = the blank CELL for this console's backend:
* $20 on the UltraTerm (plain ASCII, bit 7 = inverse), $A0 on
* the Apple text page (display code). The store is the console's
* truth now on every backend (VIDMODE V2.0), so a stored blank
* must be the byte the repaint will put on the glass. Preserves
* X/Y.
*---------------------------------------------------------------
TTY_BLANK_A
            lda   TTY_BKND
            cmp   #TTY_BKUT
            beq   :ut
            lda   #$A0
            rts
:ut         lda   #$20
            rts

*-- VCS_ACT_ON / VCS_ACT_OFF (aim the store redirect at the
*-- ACTIVE console, for the card's write-through era) went with
*-- their last caller, tty4.s VCS_ERS_TAIL, 2026-09-12.

* UT_ST_CELL and VCS_ST_SPAN (tty7.s) -- the per-cell / per-run
* write-through of a card cell to its store -- were REMOVED
* 2026-09-10: the card reads its VRAM back on switch-away now
* (VCS_UTSAVE), so the store is no longer kept write-through.

*---------------------------------------------------------------
* VCS_N8BLIT -- console X's screen between the N8 glass and its
* annex image, direction VCS_DIR (0 save, else load). The N8
* glass splits a row by COLUMN PARITY into two contiguous
* 40-byte halves (aux = even, main = odd, both behind the same
* $0400 addresses -- the 80STORE aperture serves READS as well
* as writes); the store row is 80 linear bytes. So each row is
* one BankCopy between store and VCS_ROWBUF plus two half
* passes -- never a per-byte BankCopy. VCS_ROWBUF is its OWN
* buffer, not TTY_OUTBUF: a blit can run from the parked switch
* at a write's exit, and the day the GLASS-path inline switch
* is fixed (carried finding 5) it will run mid-chunk,
* when TTY_OUTBUF is live.
* Caller brackets P_PTR1 (VCS_BLIT_X does). Clobbers VC_ROW
* (caller restores), A/X/Y, P_PTR2, VCS_N8I.
*---------------------------------------------------------------
VCS_N8BLIT
            lda   VCS_CLO,x            ;row 0 is real content
            sta   P_PTR1               ;now -- no offset
            lda   VCS_CHI,x
            sta   P_PTR1+1
            stz   VC_ROW
:row        lda   VCS_DIR
            beq   :save
            jsr   VCS_N8RCP            ;store row -> ROWBUF
            jsr   VCS_N8SCAT           ;ROWBUF -> both halves
            bra   :next
:save       jsr   VCS_N8GATH           ;both halves -> ROWBUF
            jsr   VCS_N8RCP            ;direction-aware copy
:next       clc
            lda   P_PTR1
            adc   #VC_STR_COLS
            sta   P_PTR1
            lda   P_PTR1+1
            adc   #0
            sta   P_PTR1+1
            inc   VC_ROW
            lda   VC_ROW
            cmp   TTY_ROWS
            bne   :row
            rts

*---------------------------------------------------------------
* VCS_UTBLIT -- console X's stored screen -> the UltraTerm, one
* row at a time: BankCopy the store row into UT_ROWBUF (the card
* module's own buffer, so the spike image still builds), then
* UT_PUT_ROW walks it onto the card. LOAD direction only: the
* card writes through to its store (docs/VIDMODE.md sec 4), so
* the store is already the truth on the way out. The row-0
* origin is whatever UT_START says -- the card's scroll position
* is card state, not console state, and a repaint at the current
* origin is exactly what a scrolled console wants. Clobbers
* VC_ROW (caller restores), A/X/Y, K_BC_*.
*---------------------------------------------------------------
VCS_UTBLIT
            lda   VCS_CLO,x
            sta   P_PTR1
            lda   VCS_CHI,x
            sta   P_PTR1+1
            stz   VC_ROW
:row        lda   #VC_STR_COLS
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            stz   K_BC_SRCBANK
            stz   K_BC_DSTBANK
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            lda   #BC_KIND_MAIN
            sta   K_BC_DSTKIND
            lda   P_PTR1
            sta   K_BC_SRCADDR
            lda   P_PTR1+1
            sta   K_BC_SRCADDR+1
            lda   #<UT_ROWBUF
            sta   K_BC_DSTADDR
            lda   #>UT_ROWBUF
            sta   K_BC_DSTADDR+1
            jsr   BankCopy
            lda   VC_ROW
            jsr   UT_PUT_ROW
            clc
            lda   P_PTR1
            adc   #VC_STR_COLS
            sta   P_PTR1
            lda   P_PTR1+1
            adc   #0
            sta   P_PTR1+1
            inc   VC_ROW
            lda   VC_ROW
            cmp   TTY_ROWS
            bne   :row
            rts

*---------------------------------------------------------------
* VCS_UTSAVE -- the card's VRAM -> console X's stored screen,
* one row at a time: UT_GET_ROW reads the row back from VRAM
* UT_ROWBUF, then a BankCopy lands it in the store. The SAVE
* mirror of VCS_UTBLIT, now that the $CC00 window reads VRAM
* (MEMSEL clear -- emulator pinned to MAME 2026-09-10). It reads
* at the current UT_START, so a scrolled console is captured in
* display order exactly as VCS_UTBLIT repaints it. THIS is what
* lets the card drop the per-cell/per-scroll write-through: the
* store is refreshed here, on switch-AWAY, instead of on every
* glass write (docs/VIDMODE.md sec 4's write-through is retired
* -- read-back-on-switch, the option that section rejected only
* because the window was believed unreadable). Clobbers VC_ROW
* (caller restores), A/X/Y, UT_ADDR, UT_TMPROW, K_BC_*.
*---------------------------------------------------------------
*---------------------------------------------------------------
* UT_GET_ROW -- READ row A's UT_COLS cells from the card's VRAM
* into UT_ROWBUF: the read mirror of UT_PUT_SPAN (ultraterm.s).
* One claim + one ring address + one page-select, then a window
* walk (page bumped on the wrap). The $CC00 window reads
* VRAM because maux runs MEMSEL clear ($C0B2 b7 = 0, UT_SEL_PAGE
* preserves it) -- pinned to MEMSEL 2026-09-10 (the verilogapple
* fix; commons 01M06YDGM1Q52V5TXX3GA8A2FZ). Reads at the
* current UT_START, so a scrolled screen comes back in display
* order. Lives HERE, not in ultraterm.s, to keep that file's
* `put` under the `as` window (uttest.s puts it, not this).
* CLOBBERS A, X, Y, UT_ADDR, UT_TMPROW.
*---------------------------------------------------------------
*-- UT_GET_SPAN reads only [0, X): the region row move
*-- (UT_MOV_ROW below) reads a row up to its dirty bound and
*-- nothing past it. UT_GET_ROW is the whole-row entry. The end
*-- sits in P_TMP2 (zero page: the loop's cpx is 3 cycles, not
*-- the 4 of an absolute cell -- 80 extra cycles a row showed up
*-- as +3% on IRM and DCH; P_TMP2 is the CSI parser's digit
*-- scratch, never live across a row read).
UT_GET_ROW
            ldx   #UT_COLS
UT_GET_SPAN
            stx   P_TMP2
            sta   UT_TMPROW
            jsr   UT_CLAIM
            lda   UT_TMPROW
            ldy   #0
            jsr   UT_ADDR_RC               ;UT_ADDR = row, col 0
            jsr   UT_SEL_PAGE
            ldy   UT_ADDR
            ldx   #0
:collp      cpx   P_TMP2
            bcs   :done
            lda   UT_WIN,y                 ;VRAM (MEMSEL clr)
            sta   UT_ROWBUF,x
            iny
            bne   :same
            inc   UT_ADDR+1                ;crossed a page: next
            lda   UT_ADDR+1                ;block of the ring
            and   #>UT_VRAM_MASK
            sta   UT_ADDR+1
            jsr   UT_SEL_PAGE
:same       inx
            bra   :collp
:done       rts

*---------------------------------------------------------------
* UT_MOV_ROW -- VRAM row A -> row X, by the source's DIRTY BOUND
* (perf slice 3, 2026-09-12, performance-review item 5):
* read
* [0, UT_EXT[src]) of the source, write it as one span to the
* destination, blank the destination's [UT_EXT[src], its own old
* bound) with the span eraser, which also lowers the bound. The
* old shape read all 80 cells, wrote all 80 and then scanned the
* buffer backwards to rediscover the bound (UT_GET_ROW +
* UT_PUT_ROW, ~4.4k cycles a row: a rows-1-23 region scroll --
* an editor with a status line -- cost 97.5k, all of it here).
* A blank source moves nothing and blanks the destination. The
* CALLER holds the IRQ mask + UT_RGN_CLAIM (the read-back needs
* it, learning:01M274ET8ETJ2WEA87EDR93V2J). CLOBBERS: A, X, Y,
* UT_MV*, UT_GET_SPAN's, UT_PUT_SPAN's and UT_ERS_SPAN's.
*---------------------------------------------------------------
UT_MOV_ROW
            stx   UT_MVDST
            sta   UT_MVSRC
            tax
            lda   UT_EXT,x                 ;source dirty bound
            sta   UT_MVEXT
            tax
            lda   UT_MVSRC
            jsr   UT_GET_SPAN              ;UT_ROWBUF[0,ext) <-
            stz   UT_TMPCOL                ;src
            ldx   UT_MVEXT
            lda   UT_MVDST
            jsr   UT_PUT_SPAN              ;dst[0,ext) <- buf
            ldx   UT_MVDST                 ;(raises dst's bound
            ldy   UT_MVEXT                 ;to ext if lower)
            jmp   UT_ERSLN_VRAM            ;dst[ext,bound) blank
                                           ;bound -> ext

VCS_UTSAVE
            lda   VCS_CLO,x
            sta   P_PTR1
            lda   VCS_CHI,x
            sta   P_PTR1+1
            stz   VC_ROW
:row        lda   VC_ROW
            jsr   UT_GET_ROW               ;UT_ROWBUF<-VRAM row
            lda   #VC_STR_COLS
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            stz   K_BC_SRCBANK
            stz   K_BC_DSTBANK
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   #<UT_ROWBUF
            sta   K_BC_SRCADDR
            lda   #>UT_ROWBUF
            sta   K_BC_SRCADDR+1
            lda   P_PTR1
            sta   K_BC_DSTADDR
            lda   P_PTR1+1
            sta   K_BC_DSTADDR+1
            jsr   BankCopy
            clc
            lda   P_PTR1
            adc   #VC_STR_COLS
            sta   P_PTR1
            lda   P_PTR1+1
            adc   #0
            sta   P_PTR1+1
            inc   VC_ROW
            lda   VC_ROW
            cmp   TTY_ROWS
            bne   :row
            rts

*---------------------------------------------------------------
* UT_SRGN_UP / UT_SRGN_DN -- the card's IL/DL, a VRAM row move
* over the region [TTY_SCRL_TOP, TTY_SCRL_BOT-1] (VT102 slice 1,
* DECSTBM -- was [TTY_SCRL_TOP, TTY_ROWS-1]) by TTY_SCRL_N rows.
* The whole-screen scroll (TOP=0) is a CRTC display-start bump
* (UT_SCROLL, ultraterm.s), but that moves the ENTIRE visible
* window -- it cannot open or close a hole in the middle -- so a
* region scroll reads each row back from VRAM (UT_GET_ROW, the
* $CC00 window, MEMSEL clear) and writes it to its shifted row
* (UT_PUT_ROW), then clears the vacated rows (UT_CLR_ROW). The
* store is not touched: it is rebuilt from VRAM on switch-away
* (VCS_UTSAVE), the same read-back model the whole-screen path
* uses. Lives HERE, not ultraterm.s, so it stays out of the `as`
* source window that uttest.s's `put` of ultraterm.s must fit
* (the reverse-scroll factoring already tipped it, 2026-09-10).
* P_IDX is the dst row -- nothing in the UT_GET/PUT/CLR chain
* touches it. Clobbers A, X, Y, P_IDX + the UT chain's own.
*
* UT_SRGN_UP (DL): rows [TOP+N, bottom] move UP to [TOP,
* bottom-N], low->high (src is always ahead of dst, uncopied);
* the bottom N rows are blanked.
*---------------------------------------------------------------
UT_SRGN_UP
            php
            sei                             ;mask VBL IRQ +
            jsr   UT_RGN_CLAIM             ;claim slot 3 (below)
            lda   TTY_SCRL_TOP
            sta   P_IDX                    ;dst from TOP up
:move       lda   TTY_SCRL_BOT             ;stop at dst=BOT-N
            sec                            ;(VT102 slice 1,
            sbc   TTY_SCRL_N               ;DECSTBM)
            cmp   P_IDX
            beq   :clrbot
            bcc   :clrbot
            lda   P_IDX                     ;src = dst+N
            clc
            adc   TTY_SCRL_N
            ldx   P_IDX
            jsr   UT_MOV_ROW                ;dst <- src, by
            inc   P_IDX                     ;src's dirty bound
            bra   :move
:clrbot     lda   TTY_SCRL_BOT              ;blank [BOT-N,BOT)
            sec
            sbc   TTY_SCRL_N
            sta   P_IDX
:clrlp      lda   P_IDX
            jsr   UT_CLR_ROW
            inc   P_IDX
            lda   P_IDX
            cmp   TTY_SCRL_BOT
            bcc   :clrlp
            plp                             ;restore IRQ mask
            rts

*---------------------------------------------------------------
* UT_RGN_CLAIM -- prepare a mid-output card VRAM read-back: the
* CALLER has already masked IRQs (php/sei). Reading the $CC00
* window needs slot 3 to OWN the $C800 expansion space, and the
* 60 Hz mouse VBL IRQ steals it mid-loop -- its ROM handler
* vector-fetches $C3FA, an internal $C3xx access that hands
* $C800 to the internal ROM (c800_slot=0), so an UNMASKED read
* comes back as internal-ROM garbage (WRITES are unaffected --
* the fill and the row CLEAR never showed it -- which is why it
* took a single-step A-register read to catch: paused, no IRQ
* fires and the read is correct; free-running, the IRQ corrupts
* it). Masking alone is not enough: an IRQ during the preceding
* fill may have ALREADY stolen the window, so re-claim it here
* -- drop the held flag so UT_CLAIM does a real claim ($C30C
* read sets c800_slot=3), then re-assert it so the loop's
* per-row UT_CLAIMs no-op. Commons 01M0J7NS4352S0MABTR2MENPA8.
* CLOBBERS: A.
*---------------------------------------------------------------
UT_RGN_CLAIM
            stz   UT_WHELD
            jsr   UT_CLAIM
            lda   #1
            sta   UT_WHELD
            rts

*---------------------------------------------------------------
* UT_SRGN_DN (IL): rows [TOP, bottom-N] move DOWN to [TOP+N,
* bottom], high->low (dst is always past src, uncopied); the top
* N rows of the region [TOP, TOP+N) are blanked.
*---------------------------------------------------------------
UT_SRGN_DN
            php
            sei                             ;mask VBL IRQ +
            jsr   UT_RGN_CLAIM             ;claim slot 3 (as UP)
            lda   TTY_SCRL_BOT              ;dst=region bottom-1
            sec                             ;(VT102 slice 1)
            sbc   #1
            sta   P_IDX
            lda   TTY_SCRL_TOP             ;floor = TOP+N
            clc
            adc   TTY_SCRL_N
            sta   TTY_SCRL_FLR
:move       lda   P_IDX                     ;stop at dst<floor
            cmp   TTY_SCRL_FLR
            bcc   :clrtop
            sec                              ;src = dst-N
            sbc   TTY_SCRL_N
            ldx   P_IDX
            jsr   UT_MOV_ROW
            dec   P_IDX
            bra   :move
:clrtop     lda   TTY_SCRL_TOP             ;blank [TOP, TOP+N)
            sta   P_IDX
:clrlp      lda   P_IDX
            jsr   UT_CLR_ROW
            inc   P_IDX
            lda   P_IDX
            cmp   TTY_SCRL_FLR
            bcc   :clrlp
            plp                             ;restore IRQ mask
            rts

* One 80-byte row between the store (P_PTR1, annex) and
* VCS_ROWBUF (main), direction VCS_DIR.
VCS_N8RCP
            lda   #VC_STR_COLS
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            stz   K_BC_SRCBANK
            stz   K_BC_DSTBANK
            lda   VCS_DIR
            beq   :save
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            lda   #BC_KIND_MAIN
            sta   K_BC_DSTKIND
            lda   P_PTR1
            sta   K_BC_SRCADDR
            lda   P_PTR1+1
            sta   K_BC_SRCADDR+1
            lda   #<VCS_ROWBUF
            sta   K_BC_DSTADDR
            lda   #>VCS_ROWBUF
            sta   K_BC_DSTADDR+1
            jmp   BankCopy
:save       lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   #<VCS_ROWBUF
            sta   K_BC_SRCADDR
            lda   #>VCS_ROWBUF
            sta   K_BC_SRCADDR+1
            lda   P_PTR1
            sta   K_BC_DSTADDR
            lda   P_PTR1+1
            sta   K_BC_DSTADDR+1
            jmp   BankCopy

* ROWBUF -> the glass row's two halves (load direction).
VCS_N8SCAT
            lda   VC_ROW
            jsr   TTY_ROW_DST_A        ;P_PTR2 = row base (the
                                       ;blit runs with the
                                       ;redirect off, so this
                                       ;is the GLASS)
            php
            sei
            jsr   N8_AUX_ON
            ldx   #0                   ;aux half: even columns
            ldy   #0
:auxlp      lda   VCS_ROWBUF,x
            sta   (P_PTR2),y
            inx
            inx
            iny
            cpy   #40
            bne   :auxlp
            jsr   N8_AUX_OFF
            plp
            ldx   #1                   ;main half: odd columns
            ldy   #0
:mainlp     lda   VCS_ROWBUF,x
            sta   (P_PTR2),y
            inx
            inx
            iny
            cpy   #40
            bne   :mainlp
            rts

* The glass row's two halves -> ROWBUF (save direction).
VCS_N8GATH
            lda   VC_ROW
            jsr   TTY_ROW_DST_A
            php
            sei
            jsr   N8_AUX_ON
            ldx   #0
            ldy   #0
:auxlp      lda   (P_PTR2),y
            sta   VCS_ROWBUF,x
            inx
            inx
            iny
            cpy   #40
            bne   :auxlp
            jsr   N8_AUX_OFF
            plp
            ldx   #1
            ldy   #0
:mainlp     lda   (P_PTR2),y
            sta   VCS_ROWBUF,x
            inx
            inx
            iny
            cpy   #40
            bne   :mainlp
            rts

*-- VCS_ROWBUF (80 B): inc/mm.kbss.equ, low main.

*---------------------------------------------------------------
* SURFACES (VIDMODE V2.1, operator ruling 2026-09-03). Two
* independent glasses -- 0 = the motherboard text page, 1 = the
* UltraTerm -- each owned by at most one console (VC_OWNER,
* tty.s). The owner's writes reach its glass even from the
* background; a switch onto a surface blits only when the
* incoming console is not already its owner; and when the active
* console LEAVES a surface (vidmode), the glass is handed to
* another realised console of the same backend if there is one,
* else cleared. These helpers keep every rule in one place.
*---------------------------------------------------------------
* VC_SURF_A -- A = backend id -> A = surface (0 mb, 1 card).
VC_SURF_A
            cmp   #TTY_BKUT
            beq   :card
            lda   #0
            rts
:card       lda   #1
            rts

* VC_OWNS_A -- carry SET if console A owns the surface of the
* LIVE struct's backend. Preserves A? No: clobbers A/X.
VC_OWNS_A
            sta   VC_SCANT
            lda   TTY_BKND
            jsr   VC_SURF_A
            tax
            lda   VC_OWNER,x
            cmp   VC_SCANT
            beq   :yes
            clc
            rts
:yes        sec
            rts

* VC_TAKE_A -- console A now owns the live backend's surface.
VC_TAKE_A
            pha
            lda   TTY_BKND
            jsr   VC_SURF_A
            tax
            pla
            sta   VC_OWNER,x
            rts

* VC_DROP_A -- console A owns nothing any more. A dropped CARD
* glass is cleared (the card is always 80x24, so that is safe
* whatever struct is live); a dropped motherboard glass keeps
* its stale image until the next switch onto it repaints.
VC_DROP_A
            sta   VC_SCANT
            cmp   VC_OWNER
            bne   :card
            lda   #$FF
            sta   VC_OWNER
:card       lda   VC_OWNER+1
            cmp   VC_SCANT
            bne   :out
            lda   #$FF
            sta   VC_OWNER+1
            jsr   UT_CLR_BODY
:out        rts

* VC_LEAVE -- the ACTIVE console is about to change backend;
* its current surface passes to another realised console of the
* SAME backend (so the live geometry is right for the blit), the
* lowest-numbered one, else the glass is cleared and unowned.
* Call BEFORE the live struct's TTY_BKND/COLS change.
VC_LEAVE
            lda   TTY_BKND
            jsr   VC_SURF_A
            sta   VC_SCANS                 ;surface leaving
            tax
            lda   #$FF
            sta   VC_OWNER,x
            stz   VC_SCANI
:scan       lda   VC_SCANI
            cmp   VC_ACTIVE
            beq   :next
            tax
            jsr   VC_MASK_X
            and   VC_INITED
            beq   :next                    ;never realised
            lda   VC_SCANI
            jsr   VC_PEEK_BK               ;its stored backend
            cmp   TTY_BKND
            bne   :next                    ;other surface or
                                           ;other geometry
            lda   VC_ROW                   ;found: repaint it
            pha
            ldx   VC_SCANI
            lda   #1
            jsr   VCS_BLIT_X
            pla
            sta   VC_ROW
            ldx   VC_SCANS
            lda   VC_SCANI
            sta   VC_OWNER,x
            rts
:next       inc   VC_SCANI
            lda   VC_SCANI
            cmp   #VC_COUNT
            bcc   :scan
            lda   TTY_BKND                 ;nobody: clear the
            cmp   #TTY_BKUT                ;glass we leave (the
            beq   :clrut                   ;card clears without
            jmp   TTY_CLR_BODY             ;touching any store;
:clrut      jmp   UT_CLR_BODY              ;so do 40/N8 here)

* VC_PEEK_BK -- A = console A's STORED TTY_BKND, read from its
* annex slot (one-byte BankCopy at the struct offset, computed
* at run time from relocatable low bytes -- PRC_TTYGEO's own
* idiom). Clobbers A/X/Y, K_BC_*.
VC_PEEK_BK
            tax
            lda   #<TTY_BKND
            sec
            sbc   #<VC_STATE
            clc
            adc   VC_SLT_LO,x
            sta   K_BC_SRCADDR
            lda   VC_SLT_HI,x
            adc   #0
            sta   K_BC_SRCADDR+1
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            stz   K_BC_SRCBANK
            lda   #BC_KIND_MAIN
            sta   K_BC_DSTKIND
            lda   #<VC_PEEKB
            sta   K_BC_DSTADDR
            lda   #>VC_PEEKB
            sta   K_BC_DSTADDR+1
            stz   K_BC_DSTBANK
            lda   #1
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   VC_PEEKB
            rts

VC_SCANI    ds 1
UT_MVSRC    ds 1                          ;UT_MOV_ROW: source
UT_MVDST    ds 1                          ;destination row
UT_MVEXT    ds 1                          ;source dirty bound
VC_SCANS    ds 1
VC_SCANT    ds 1
VC_PEEKB    ds 1

*---------------------------------------------------------------
* TTY_WR_ENTER / TTY_WR_LEAVE -- bracket a write that is NOT for
* the console on the glass (docs/CONSOLE.md sec 13).
*
* The console a write is for is TTY_TARGET, set from the fd's
* device handle by PRC_WRITE. When it is the active one -- which
* is every write in a single-console session -- these cost one
* compare each and nothing else happens.
*
* Otherwise the target's STRUCT is swapped in (cursor, escape
* state, attributes: a background console keeps its own) and
* TTY_DSTBASE is pointed at its stored screen, which redirects
* every renderer in the tree through TTY_ROW_DST_A. The GLASS IS
* NEVER TOUCHED, so nothing flickers and the foreground console
* is undisturbed.
*
* Only the struct moves, not the screen -- two 291-byte
* BankCopies per write() call, against the 24-row blit a real
* switch pays. Background output is meant to be cheap.
*---------------------------------------------------------------
TTY_WR_ENTER
            stz   TTY_DSTBASE
            stz   TTY_DSTBASE+1
            lda   TTY_TARGET
            cmp   VC_ACTIVE
            beq   :active
            cmp   #VC_COUNT
            bcs   :active              ;nonsense target: use the
                                       ;glass, do not index off
                                       ;the end of the table
            sta   VC_LIVE              ;the target's struct is
            lda   #1                   ;about to be the live one
            sta   TTY_WR_SWAP
            jsr   PRC_SEL_CRBNK        ;A = the caller's bank,
            sta   TTY_SVBANK           ;for the annex bracket
            ldx   VC_ACTIVE
            jsr   VC_SAVE_X
            ldx   TTY_TARGET
            jsr   VC_MASK_X
            and   VC_INITED
            bne   :warm
            ldx   TTY_TARGET
            jsr   VC_MASK_X
            ora   VC_INITED
            sta   VC_INITED
            jsr   VC_RESET
            jsr   TTY_SET_DSTB
            jmp   VCS_CLR_BODY         ;written to before it was
                                       ;ever shown: it still
                                       ;starts from a blank
                                       ;screen -- the store's
                                       ;own full-width clear,
                                       ;redirected like any
                                       ;other write
:warm       ldx   TTY_TARGET
            jsr   VC_LOAD_X
            lda   TTY_TARGET           ;a background console
            jsr   VC_OWNS_A            ;OWNS its surface writes
            bcs   :active              ;to the glass: the other
            jmp   TTY_SET_DSTB         ;monitor shows it live
:active     rts

TTY_SET_DSTB
            ldx   TTY_TARGET
            lda   VCS_CLO,x
            sta   TTY_DSTBASE
            lda   VCS_CHI,x
            sta   TTY_DSTBASE+1
            rts

TTY_WR_LEAVE
            stz   TTY_WR_BUSY          ;islands close with the
                                       ;write (every exit)
            jsr   TTY_VC_PEND           ;an Option-1..4 pressed
                                        ;while this write ran
            stz   UT_WHELD             ;drop held card window
                                     ;(no-op unless this was a
                                     ;a foreground UT write)
            lda   TTY_WR_SWAP          ;structs swapped? (not
            beq   :done                ;TTY_DSTBASE: an owner
            stz   TTY_WR_SWAP          ;wrote to its glass with
            stz   TTY_DSTBASE          ;no redirect at all)
            stz   TTY_DSTBASE+1
            lda   VC_ACTIVE
            sta   VC_LIVE
            ldx   TTY_TARGET
            jsr   VC_SAVE_X
            ldx   VC_ACTIVE
            jsr   VC_LOAD_X
            lda   VC_SW_PEND         ;a switch escape that
            beq   :home              ;arrived THROUGH the
            stz   VC_SW_PEND         ;redirect (TTY_CSI_VT's
            dec   a                  ;mid-redirect park) runs
            jsr   VC_SWITCH          ;now, structs back home
*-- The bank goes home too. VC_SAVE/LOAD (and the parked
*-- switch's blits) end in BankCopy, which leaves $C073
*-- wherever its last chunk ran. The success path is covered --
*-- PCPO_MLIPARM reselects -- but the ERROR exits jmp here
*-- after PRC_FAIL_A and return straight to KRN_EXIT's
*-- no-switch path, which never rewrites $C073: the caller
*-- would resume in the ANNEX (2nd review, finding 7).
:home       jmp   PRC_SEL_CRBNK
:done       rts

*---------------------------------------------------------------
* VC_RESET -- initialize the ACTIVE console image's per-console
* fields (factored out of TTY_INIT, which now shares it with
* VC_SWITCH's first-touch path). Home to TTY_HOME_ROW's row --
* as of the 2026-09-03 row-0 reclaim that is row 0 except on the
* UltraTerm (docs/CONSOLE.md sec 6). Buffers are deliberately
* NOT cleared -- the length fields are zero, so stale buffer
* bytes are unreachable, same as the flat cells always were.
*---------------------------------------------------------------
VC_RESET
            stz   VC_IN_LEN
            stz   VC_IN_POS
            stz   VC_EDIT_LEN
            stz   VC_KESC
            stz   VC_EDIT_POS
            stz   VC_HIST_N
            stz   VC_HIST_W
            lda   #$FF
            sta   VC_HIST_CUR
*-- a cold console inherits the MACHINE's boot mode
*-- (docs/VIDMODE.md sec 1); vidmode changes it later.
*-- TTY_BKND/TTY_COLS/TTY_ROWS/TTY_DISC are NOT reset: a console
*-- realised for the first time INHERITS the mode of the console
*-- that was live when it was touched (operator ruling
*-- 2026-09-03; TTY_INIT seeds console 0's cells itself).
            jsr   TTY_HOME_ROW
            stz   VC_COL
            stz   VC_CSI_P3
            stz   VC_CSI_P4
*-- cooked default (stty seed, 2026-09-02; +TMD_OPOST, VT102
*-- slice 1 -- CR is a newline in cooked mode, docs/CONSOLE-
*-- VT102.md sec 3)
            lda   #TMD_ICANON+TMD_ECHO+TMD_OPOST
            sta   VC_TMODE
            stz   VC_EOF_PEND
            stz   VC_RAW_HD
            stz   VC_RAW_TL
            stz   VC_ESC_STATE
            stz   VC_ATTR
            stz   VC_ATTRMODE
            stz   VC_OSHDW_LEN
            stz   VC_CSI_ROW
            stz   VC_CSI_COL
            stz   VC_CSI_PARAM
            phx                           ;the whole DECSC stash
            ldx   #VC_DSC_N-1             ;(VT102 slice 6)
:dsc        stz   VC_SAVE_ROW,x
            dex
            bpl   :dsc
            plx
            lda   #$A0
            sta   VC_CRSR_SAV
            stz   VC_CRSR_VIS
            stz   VC_DECCKM
            stz   VC_IRM                  ;VT102 slice 2: smir/
                                          ;rmir off by default
            lda   #1
            sta   VC_AWM                  ;slice 7: autowrap on
            jsr   TT9_CSRESET             ;VT102 slice 5: ASCII
            stz   VC_XENL                 ;VT102 slice 3: no
                                          ;wrap pending on a
                                          ;fresh console
            jmp   TT9_MRESET
