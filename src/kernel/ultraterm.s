*---------------------------------------------------------------
* ultraterm.s -- Videx UltraTerm (slot 3) display backend.
*
* The 80-column console surface of docs/CONSOLE.md section 8:
* detect / init / put_cell / clear_row / scroll / cursor. It
* owns NO tty policy -- no escape parsing, no line discipline,
* no wrap decisions. tty.s decides what goes where; this puts it
* on the glass.
*
* THE ONE CONSTRAINT THAT SHAPES EVERYTHING: the card is
* WRITE-ONLY. $CC00-$CDFF reads serve firmware ROM, not VRAM
* (the card's own COUT executes from $CC6E), so nothing here may
* read a character back. That rules out the two idioms the
* 40-column backend uses:
*
* - TTY_SCROLL copies rows upward by reading them. Here scroll
* is a CRTC display-start bump (R12/R13) -- no reads, and one
* register write instead of 1840 byte moves. - TTY_CRSR_SHOW
* saves the glyph under the cursor to restore it later. Here the
* CRTC has a hardware cursor (R14/R15), so the save/restore is
* deleted rather than ported.
*
* Both replacements are faster than what they replace, so the
* emulator's readback gap cost nothing. Verified against
* verilogapple's ultraterm_state (docs/CONSOLE.md section 10a).
*
* ADDRESSING. A cell is at (UT_START + row*80 + col) AND $0FFF.
* VRAM is a 4096-byte ring and 80 does not divide 4096, so after
* enough scrolls a row straddles the wrap. UT_ADDR_RC is the
* only place an address is computed, so the arithmetic exists
* once.
*
* The AND $0FFF in UT_ADDR_RC is documentary, not load-bearing:
* the hardware already does exactly that wrap, because
* UT_SEL_PAGE feeds the high byte to a 4-bit page nibble and the
* low byte indexes a 256-byte window -- 4 + 8 = the same 12
* bits. Measured, not assumed: deleting it leaves `make
* check-ultraterm` fully green. It is kept because it makes the
* ring explicit at the one place worth reading, and costs 2
* cycles. What IS load bearing is adding UT_START at all --
* dropping that fails 26 of the gate's checks.
*---------------------------------------------------------------

*---------------------------------------------------------------
* Card registers and CRTC register numbers. These live here, not
* in inc/memmap.equ: they are this module's hardware, and
* memmap.equ sits ~200 bytes from real Merlin's 41215-byte
* source-buffer ceiling (the buffer holds the manifest and one
* PUT file together -- learning:01M051EM2HQ3ZVJTR1W9P3G86J).
* Putting 4 KB of card documentation there broke `check-dual` by
* 83 bytes.
*
* EQUs must be defined before first reference under real Merlin,
* and tty.s references UT_COLS -- which is why every image PUTs
* ultraterm.s BEFORE tty.s.
*---------------------------------------------------------------


*-- UT_VTEMU ($10, inc/ultraterm.equ since 2026-09-03):
*-- CLEAR = Videoterm emulation,
*-- where bits 3-0 are NOT a
*-- page number and the window
*-- banks Videoterm-style
*-- instead. verilogapple's
*-- model ignores this bit (its
*-- page = low nibble always),
*-- which is how the driver ran
*-- green without setting it;
*-- MAME's a2ultraterm gates the
*-- page field on it, matching
*-- the Videx manual's ctrl1
*-- layout. Set it in EVERY
*-- page write.
*-- UT_MODE_HQ80 ($80) is gone (2026-09-11): $80 meant
*-- "attributes from the DIP switches", so inverse on iron hung
*-- on the owner's S1-S4 and highlight was unreachable.
*-- UT_ATTR_INV / UT_ATTR_HL (inc/ultraterm.equ) program it.
*-- UT_ROWS: hoisted to inc/ultraterm.equ (EQU burn-down
*-- 2026-08-29) -- uttest.s uses it immediate before this file
*-- is put.
*-- The card/CRTC equates (UT_CRTC_ADDR .. UT_FMT4_ROM) moved to
*-- inc/ultraterm.equ (2026-09-13) when this module was
*-- split at UT_CLAIM into ultraterm.s + ultraterm2.s: both
*-- halves use them and a REL module cannot export an equate.

*---------------------------------------------------------------
* Backend state. Held here rather than in process.s's data block
* (where the TTY_* cells live for historical reasons) so the
* module is self-contained and can be assembled into a spike
* image without dragging in the process layer.
*---------------------------------------------------------------
UT_PRESENT  ds 1                   ;1 = a card answered $87 at
                                   ;$C30C
UT_START    ds 2                   ;CRTC display start. Advances
                                   ;80 per scroll and wraps in
                                   ;the 4 KB ring -- this is the
                                   ;scroll POSITION, so it is
                                   ;state, not scratch
UT_ADDR     ds 2                   ;computed VRAM address;high
                                   ;byte doubles as the page
                                   ;select
UT_CHAR     ds 1                   ;byte in flight through
                                   ;UT_PUT_CELL
UT_TMPROW   ds 1
UT_TMPCOL   ds 1
UT_SPANEND  ds 1                   ;UT_PUT_SPAN end col (excl)
UT_RUNLEN   ds 1                   ;TTY_RUN: run length
UT_RUNCAP   ds 1                   ;TTY_RUN: run cap
*-- UT_EXT -- per-row DIRTY BOUND for the active card console.
*-- INVARIANT: every VRAM cell at column >= UT_EXT[row] is blank
*-- ($20). It is an UPPER bound: over-estimating only costs
*-- work, UNDER-estimating leaves stale cells -- so the rule is
*-- "every VRAM writer raises it". The tree has exactly four
*-- VRAM store sites, all in this file (audited 2026-09-05):
*--   UT_PUT_CELL  raises to col+1
*--   UT_PUT_SPAN  raises to the span's end col
*--   UT_PUT_ROW   sets it EXACTLY (scans UT_ROWBUF: a whole row
*--                is authoritative) -- which makes UT_CLR_ROW,
*--                UT_SCROLL's exposed rows and the switch-in
*--                blit (VCS_UTBLIT) exact for free
*--   UT_ERSLN_VRAM walks [Y,bound) instead of [Y,80), skips
*--                entirely when Y >= bound, then lowers to Y
*--   UT_CLR_ALL   zeroes all rows; UT_SCROLL shifts them up
*-- WHY: a 24-tilde vi repaint erased 23 x 79 already-blank
*-- cells -- ~90k cycles, measured by stubbing VI_ERSLN, about
*-- half of what remained after the repaint became one write.
*-- Main-bank, ACTIVE console only: the annex has no slack for
*-- four tables and needs none -- a switch rebuilds it exactly.
UT_EXT      ds UT_ROWS
UT_EXTEND   ds 1                   ;UT_ERSLN_VRAM: this row's
                                   ;bound, captured at entry
UT_WHELD    ds 1                   ;1 while a masked tty write
                                   ;holds the $C800 window --
                                   ;UT_CLAIM then no-ops, so the
                                   ;whole write claims ONCE, not
                                   ;per cell (2026-09-04). Safe
                                   ;because ffpage.s sei's the
                                   ;syscall: nothing steals
                                   ;the window mid-write.
UT_CRSR_ST  ds 1                   ;cursor start row (R10)
UT_CRSR_EN  ds 1                   ;cursor end row (R11); both
                                   ;from the format-4 entry
UT_INITED   ds 1                   ;1 once UT_INIT programmed
                                   ;the CRTC: a console may ask
                                   ;for the card at run time
                                   ;V2.0, tty7.s TTY_HW_SET)
* -- TTY_DUALHEAD: VIDMODE V2.1 head mode, machine-wide (not per
* -- console). 0 (default) = SINGLE monitor: TTY_HW_SET drops
* -- VIDSEL when a motherboard console takes the glass, so the
* -- one screen follows the active console. 1 = DUAL head:
* -- VIDSEL is held, so the card keeps its own console while a
* -- motherboard console runs on a second monitor. Set by
* -- `ESC [ n w` (vidmode onehead/dualhead).
TTY_DUALHEAD ds 1
*-- UT_ROWBUF (80 B): inc/mm.kbss.equ, low main.
UT_SCRLN    ds 1                   ;UT_SCROLL's row count (X on
                                   ;entry). Module-local: the
                                   ;uttest spike image has no
                                   ;tty.s and must still build
UT_BODYROW  ds 1                   ;UT_CLR_BODY's row counter --
                                   ;separate from UT_TMPROW,
                                   ;which UT_CLR_ROW owns and
                                   ;would clobber under it
UT_SDIR     ds 1                   ;UT_SCROLL: 0 = up, 1 = down
UT_CLREND   ds 1                   ;UT_SCROLL clear end (excl)
*-- UT_ROW0 / UT_STAMP_ROW0 (the reserved status line) are GONE
*-- (2026-09-03 evening): the row-0 reclaim (docs/CONSOLE.md sec
*-- 6) now covers this backend too, and the re-stamp was ~9k of
*-- a 20k-cycle scroll (docs/CONSOLE-OPT.md sec 6).


*---------------------------------------------------------------
* SPLIT 2026-09-13: the routines from UT_CLAIM on live in
* ultraterm2.s, `put` immediately after this file in every
* manifest, so no byte moves. Real Merlin holds a module's
* source in a 41,215 B buffer (resident + largest put) and KULT
* was 713 B over it (check-librel's budget). The card/CRTC
* equates both halves use moved to inc/ultraterm.equ.
*---------------------------------------------------------------
