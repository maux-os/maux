*---------------------------------------------------------------
* tty9.s -- the VT102 additions (task #23, docs/CONSOLE-VT102.md
* slice 1). New put file, `put` right after tty8.s in every
* kernel manifest, for the reason every ttyN.s split exists:
* `as`'s 16,128-byte source window is charged PER PUT, and this
* slice's DECSTBM scroll-region math, the two-byte ESC
* additions,
* ED/EL 0/1/2, and the margin-aware cursor clamps are new logic,
* not just a dispatch retarget -- landing them here instead of
* growing tty2.s keeps every existing module's window intact.
* tty2.s/tty3.s/tty7.s/tty8.s gain only cmp/bne/jmp retargets (a
* handful of existing dispatch-chain jumps now point in here)
* and
* the handful of small, unavoidable body edits the spec forces
* (the CR/LF terminal-layer split, the cooked-default bit, the
* margin re-derivation call sites) -- documented at each site.
* Kernel modules are one flat symbol space; nothing declares
* anything to reach these routines from another put.
*
* Library notes (fetched before writing this file): learning:
* 01M286W9KVA7TW7KN0BRGGHV0D (VT102 user guide + reference card
* --
* DECSTBM/IND/RI/NEL/ED/EL/DECCKM semantics, the spec this file
* implements); 01M287MW1Y9Q719BAYFTN4C5M8 (GNO/ME's CRMOD
* precedent -- TMD_OPOST's shape, the mapping lives in the line
* discipline, not the terminal); 01M1JNVYS4E6K0DX5CCSJYD5GE
* (scroll
* costs by backend -- the margin bound rides the EXISTING
* TTY_SCROLL/TTY_SCRL_REV machinery per backend, no new per-cell
* walk on the hot path); 01M1AH9XWGC8ZS7HNBJVJ2JHXW (screen
* gates
* settle on two identical polls -- check_vt102.py's own rule);
* 01M0VJF2DXZR55HGJ8PTN1MNJE (new global routines split local
* zones -- every :local below is defined and referenced within
* its
* own routine only); 01M050C6KW01MPJ2TQTPMTZXN6 (13-char labels,
* 12 for a :local -- TT9_* names are chosen short on purpose).
*---------------------------------------------------------------

*---------------------------------------------------------------
* TT9_SWALLOW -- the ESC ( / ESC ) / ESC # designator-swallow
* state (VC_ESC_STATE=4, TTY_PUT_BYTE's front dispatch). One
* byte
* in, discarded, state back to idle -- V1 has no line-drawing
* set
* (docs/CONSOLE-VT102.md gap table: SCS/enacs), so `ESC ( B` and
* `ESC ) 0` paint nothing rather than leaking 'B'/'0' as text.
*---------------------------------------------------------------
TT9_SWALLOW
            stz   VC_ESC_STATE
            lda   VC_SCS
            beq   :done                  ;ESC # x: no set to
                                         ;select
            ldx   #0                     ;kind: 0 = ASCII (B, A,
            lda   PRC_BYTE               ;1, 2), 1 = DEC special
            cmp   #'0'                   ;graphics
            bne   :kind
            inx
:kind       lda   VC_SCS
            stz   VC_SCS
            cmp   #'('
            bne   :g1
            stx   VC_G0
            bra   :redo
:g1         stx   VC_G1
:redo       jmp   TT9_ACSSEL             ;re-derive the active
                                         ;set's kind
:done       rts

* TT9_SCS_SET -- ESC ( or ESC ): remember which, then swallow
* the designator byte (TT9_SWALLOW applies it).
TT9_SCS_SET lda   PRC_BYTE
            sta   VC_SCS
            lda   #4
            sta   VC_ESC_STATE
            rts

* TT9_SO / TT9_SI -- shift out (G1 active) / shift in (G0).
* TT9_ACSSEL -- VC_ACS = kind of the active set. VC_XENL is the
* SO/SI byte's own concern in TTY_PUT_BYTE (any byte < $20
* clears the pending wrap), not this routine's.
TT9_SO      lda   #1
            sta   VC_GL
            bra   TT9_ACSSEL
TT9_SI      stz   VC_GL
TT9_ACSSEL  lda   VC_GL
            beq   :g0
            lda   VC_G1
            bra   :set
:g0         lda   VC_G0
:set        sta   VC_ACS
            rts

* TT9_CSRESET -- both sets ASCII, G0 invoked, nothing pending:
* the power-on / ESC c state. CLOBBERS: nothing but flags.
TT9_CSRESET stz   VC_G0
            stz   VC_G1
            stz   VC_GL
            stz   VC_ACS
            stz   VC_SCS
            rts

* TT9_ACSMAP -- A = 7-bit byte with the DEC special graphics set
* active: $60-$7E map through ACSTAB to the ASCII a terminal
* without a drawing set draws boxes with (`+ - |`; ncurses'
* own fallback). Below $60 the set is ASCII anyway. MouseText
* glyphs are the V2 refinement (CONSOLE-VT102.md sec 7).
TT9_ACSMAP  cmp   #$60
            bcc   :out
            cmp   #$7F
            bcs   :out
            sec
            sbc   #$60
            tax
            lda   ACSTAB,x
:out        rts
*--                 ` a b c d e f g h i j k l m n o
ACSTAB      dfb   '+',':','b','c','d','e',$27,'#'
            dfb   'h','i','+','+','+','+','+','~'
*--                 p q r s t u v w x y z { | } ~
            dfb   '-','-','-','_','+','+','+','+'
            dfb   '|','<','>','*','!','f','o'

*---------------------------------------------------------------
* TT9_CR -- CR ($0D) at the terminal layer (tty2.s TTY_PUT_NORM
* retargets its CR check here). Strict VT102: column 0 only --
* UNLESS this console's line discipline has TMD_OPOST set
* (cooked default), in which case CR is CR LF: column 0 plus
* a margin-bounded index (TT9_NEWLINE). The GNO/ME precedent's
* "CR LF before the terminal layer sees it" collapses to this
* one test; there is no second byte to inject.
*---------------------------------------------------------------
TT9_CR      stz   VC_XENL               ;CR cancels a pending
*-- Any CR -- output, the echoed Enter, ^C's echo -- ends the
*-- ^L replay shadow's line (2026-10-02: ONE reset here, where
*-- TTY_SHDW_TAP and both tty3.s commits each had their own).
            stz   VC_OSHDW_LEN
            lda   VC_TMODE              ;wrap (slice 6)
            and   #TMD_OPOST
            beq   :col0
            jmp   TTY_NEWLINE
:col0       stz   VC_COL
            rts

*---------------------------------------------------------------
* TT9_IND / TT9_RI / TT9_NEL -- ESC D / ESC M / ESC E.
*
* TT9_IND (index): down one line, same column; scrolls the
* region
* [VC_MTOP,VC_MBOT] when the cursor is AT the bottom margin.
* Below the region (only reachable when the margins do not reach
* the physical bottom), the cursor just advances until it hits
* the true screen bottom, where nothing scrolls -- xterm's own
* reading of "outside the scroll region", and the shared body
* TTY_NEWLINE (tty2.s) forwards into.
*---------------------------------------------------------------
*-- TT9_LBRK -- a LINE BREAK from outside (LF/VT/FF, ESC D,
*-- ESC E): the ^L replay shadow (VC_OUTSHDW) is the printable
*-- run since the glass last stopped being an append of it, so
*-- a break ends it (KFIX9). The wrap into the next row
*-- (TTY_NEWLINE) enters at TT9_IND and keeps it: one logical
*-- line, which the replay re-wraps the same way. The whole rule
*-- is at TTY_SHDW_TAP (tty.s).
TT9_LBRK    stz   VC_OSHDW_LEN
TT9_IND     stz   VC_XENL               ;an index cancels a
            lda   VC_ROW                ;pending wrap (slice 6)
            cmp   VC_MBOT
            bne   :notmargin
            jmp   TTY_JSCROLL           ;at the bottom margin:
                                        ;region-bounded (jump)
                                        ;scroll
:notmargin  lda   TTY_ROWS
            sec
            sbc   #1
            cmp   VC_ROW
            beq   :done                 ;already at the true
                                        ;bottom, outside the
                                        ;region: nothing scrolls
            inc   VC_ROW
:done       rts

*-- TTY_NEWLINE's real body (tty2.s keeps the label + a one-line
*-- forward so every existing caller -- CR under TMD_OPOST and
*-- the col-80 wrap -- is untouched): column 0 + IND. A bare LF
*-- is IND proper (TT9_IND above) and never touches the column.
TT9_NEWLINE
            stz   VC_COL
            bra   TT9_IND

*-- ESC E (NEL): IND + column 0 -- identical to maux's own
*-- newline (TT9_NEWLINE), named separately for the dispatch.
TT9_NEL     stz   VC_COL
            bra   TT9_LBRK

*---------------------------------------------------------------
* TT9_RI -- ESC M (reverse index): up one line, same column;
* scrolls the region DOWN when the cursor is AT the top margin.
* Above the region (VC_ROW < VC_MTOP -- reachable since DECOM is
* not implemented and CUP may put the cursor there) or already
* at
* the physical top, the cursor just stays -- nothing above it.
*---------------------------------------------------------------
TT9_RI      stz   VC_OSHDW_LEN          ;a line break (TT9_LBRK)
            stz   VC_XENL               ;RI cancels a pending
            lda   VC_ROW                ;wrap (slice 6)
            cmp   VC_MTOP
            bne   :notmargin
            lda   VC_MTOP
            sta   TTY_SCRL_TOP
            lda   VC_MBOT
            inc   a
            sta   TTY_SCRL_BOT
            lda   #1
            sta   TTY_SCRL_N
            jmp   TTY_SCRL_REV
:notmargin  lda   VC_ROW
            beq   :done                 ;physical top already:
                                        ;nothing above it
            dec   VC_ROW
:done       rts

*---------------------------------------------------------------
* TT9_MRESET -- VC_MTOP/VC_MBOT to the whole screen (0, rows-1).
* Called wherever TTY_ROWS is (re)established for a console: VC_
* RESET (tty8.s, first touch AND boot -- TTY_INIT calls it after
* seeding TTY_ROWS), TTY_CSI_MODE's geometry commit (tty7.s),
* and
* TTY_TRM_RESET / ESC c (tty2.s). CLOBBERS: A.
*---------------------------------------------------------------
TT9_MRESET
            stz   VC_MTOP
            lda   TTY_ROWS
            sec
            sbc   #1
            sta   VC_MBOT
            rts

*---------------------------------------------------------------
* TT9_DECSTBM -- ESC [ Pt ; Pb r. No params (both wire values
* 0):
* whole screen. Otherwise t defaults to 1, b to TTY_ROWS
* (1-based
* on the wire, like CUP); validated 0-based (t0 < b0 <= rows-1),
* else the escape is ignored ENTIRELY and prior margins are
* kept.
* A successful set homes the cursor (VT102: DECOM is reset, so
* HOME means absolute row 0 col 0, the same target CSI H uses).
* VC_CSI_ROW/COL are the wire values TTY_CSI_BYTE already
* parsed.
*---------------------------------------------------------------
TT9_DECSTBM
            lda   VC_CSI_ROW
            ora   VC_CSI_COL
            bne   :havep
            stz   VC_MTOP                ;no params: whole scrn
            lda   TTY_ROWS
            sec
            sbc   #1
            sta   VC_MBOT
            bra   :home
:havep      lda   VC_CSI_ROW
            bne   :t0
            lda   #1
:t0         sec
            sbc   #1                     ;t, 0-based
            sta   TT9_T0
            lda   VC_CSI_COL
            bne   :b0
            lda   TTY_ROWS
:b0         sec
            sbc   #1                     ;b, 0-based
            sta   TT9_B0
            cmp   TTY_ROWS
            bcs   :ignore                 ;b0 >= rows: invalid
            lda   TT9_T0
            cmp   TT9_B0
            bcs   :ignore                 ;t0 >= b0: invalid
            sta   VC_MTOP
            lda   TT9_B0
            sta   VC_MBOT
:home       jsr   TTY_HOME_ROW
            stz   VC_COL
:ignore     rts

*---------------------------------------------------------------
* TT9_SCLAMP -- SU/SD's prologue: TOP/BOT from the persistent
* margins (SU/SD always scroll the WHOLE region, never a
* sub-range), N from VC_CSI_ROW (0 absent -> 1), clamped to the
* region height. Replaces the old whole-screen-only TTY_SCLAMP
* (tty2.s's two callers, TTY_CSI_SU/SD, now forward straight
* here). TTY_SCRL_BOT is the EXCLUSIVE bound.
*---------------------------------------------------------------
TT9_SCLAMP
            lda   VC_MTOP
            sta   TTY_SCRL_TOP
            lda   VC_MBOT
            inc   a
            sta   TTY_SCRL_BOT
            sec
            sbc   TTY_SCRL_TOP
            sta   TT9_RH                  ;region height
            jmp   TT9_NCLAMP

*-- TT9_NCLAMP -- TTY_SCRL_N = VC_CSI_ROW (0 absent -> 1),
*-- clamped to TT9_RH. Shared tail of TT9_SCLAMP and TT9_RGN.
TT9_NCLAMP  lda   VC_CSI_ROW
            bne   :haven
            lda   #1
:haven      cmp   TT9_RH
            bcc   :nsmall
            lda   TT9_RH
:nsmall     sta   TTY_SCRL_N
            rts

TT9_SU      jsr   TT9_SCLAMP
            jmp   TTY_SCROLL
TT9_SD      jsr   TT9_SCLAMP
            jmp   TTY_SCRL_REV

*---------------------------------------------------------------
* TT9_RGN -- IL/DL's prologue: region = [VC_ROW, VC_MBOT]. OUT:
* carry SET if VC_ROW is outside [VC_MTOP, VC_MBOT] -- the whole
* IL/DL is then a no-op, VT102 semantics -- else carry CLEAR
* with
* TTY_SCRL_TOP/BOT/N set, N (from VC_CSI_ROW, 0 absent -> 1)
* clamped to the region height (VC_MBOT-VC_ROW+1).
*---------------------------------------------------------------
TT9_RGN     lda   VC_ROW
            cmp   VC_MTOP
            bcc   :skip                   ;VC_ROW < MTOP: above
                                          ;the region
            cmp   VC_MBOT
            beq   :inrange
            bcs   :skip                   ;VC_ROW > MBOT: below
:inrange    sta   TTY_SCRL_TOP
            lda   VC_MBOT
            inc   a
            sta   TTY_SCRL_BOT
            sec
            sbc   TTY_SCRL_TOP             ;region height
            sta   TT9_RH
            jsr   TT9_NCLAMP
            clc
            rts
:skip       sec
            rts

*---------------------------------------------------------------
* TT9_IL / TT9_DL -- ESC [ n L / M. Retargets of the old
* TTY_CSI_
* IL/DL dispatch (tty2.s :not_dl/:not_il jmp targets); the
* region
* is now MARGIN-bounded ([cursor,VC_MBOT], not [cursor,bottom]),
* and the whole op is skipped outside the margins (TT9_RGN).
*---------------------------------------------------------------
TT9_IL      jsr   TT9_RGN
            bcs   :out
            jmp   TTY_SCRL_REV
:out        rts
TT9_DL      jsr   TT9_RGN
            bcs   :out
            jmp   TTY_SCROLL
:out        rts

*---------------------------------------------------------------
* TT9_ED -- ESC [ n J (ED), n = VC_CSI_ROW (0 default). Cursor
* never moves for any case. Retarget of tty2.s's 'J' dispatch
* (was TTY_CSI_CLEAR, which only ever did 2J -- and homed the
* cursor doing it; VT102's ED never moves the cursor, so 2J is
* now TTY_CLR_BODY directly, not TTY_CLR_SCRN).
*---------------------------------------------------------------
TT9_ED      lda   VC_CSI_ROW
            cmp   #1
            beq   TT9_ED1
            cmp   #2
            beq   TT9_ED2
*-- fall through: 0 (or default) -- cursor to end of screen.
TT9_ED0     jsr   TTY_CSI_ERSLN           ;this row, cursor..EOL
            lda   VC_ROW
            inc   a
            sta   TT9_LOOP
:rlp        lda   TT9_LOOP
            cmp   TTY_ROWS
            bcs   :done
            jsr   TT9_CLRROW
            inc   TT9_LOOP
            bra   :rlp
:done       rts

*-- 1: start of screen through the cursor, inclusive.
TT9_ED1     stz   TT9_LOOP
:rlp        lda   TT9_LOOP
            cmp   VC_ROW
            bcs   TT9_EL1                 ;rows above done; this
                                          ;row: start..cursor
            jsr   TT9_CLRROW
            inc   TT9_LOOP
            bra   :rlp

*-- 2: whole screen, cursor unchanged (TTY_CLR_BODY touches no
*-- cursor cell -- unlike the retired TTY_CLR_SCRN path).
TT9_ED2     jmp   TTY_CLR_BODY

*---------------------------------------------------------------
* TT9_EL -- ESC [ n K (EL), n = VC_CSI_ROW. Retarget of tty2.s's
* 'K' dispatch (was a direct jmp to TTY_CSI_ERSLN, which is 0K
* only); 0 still tail-calls the existing backend-batched fast
* path unchanged.
*---------------------------------------------------------------
TT9_EL      lda   VC_CSI_ROW
            cmp   #1
            beq   TT9_EL1
            cmp   #2
            beq   TT9_EL2
            jmp   TTY_CSI_ERSLN

*-- 1: start of line through the cursor, inclusive -- ONE
*-- backend span [0, VC_COL] (TTY_ERS_SPAN), not a cell walk:
*-- per cell a full row cost 15.7k cycles on native-80 and
*-- 18.4k on the card against 3.7k / 6.0k for the batched tail
*-- (2026-09-12 performance review, item 3).
TT9_EL1     lda   VC_COL
            pha
            inc   a                       ;end = cursor + 1
            stz   VC_COL
            jsr   TTY_ERS_SPAN
            pla
            sta   VC_COL
            rts

*-- 2: the whole line.
TT9_EL2     lda   VC_ROW
            jmp   TT9_CLRROW

*---------------------------------------------------------------
* TT9_CLRROW -- blank the WHOLE row A (every column), cursor
* unchanged: TTY_CSI_ERSLN from column 0, i.e. TTY_ERS_SPAN over
* [0, TTY_COLS) -- one setup per row on every foreground backend
* (a 40-column ED 0 from home was 116k cycles of cell walk, ED 2
* 34k, before the 40-column fill joined the span primitive).
* CLOBBERS: A, X, Y (+ TTY_ERS_SPAN's own).
*---------------------------------------------------------------
TT9_CLRROW  sta   TT9_ROW
            lda   VC_ROW
            pha
            lda   VC_COL
            pha
            lda   TT9_ROW
            sta   VC_ROW
            stz   VC_COL
            jsr   TTY_CSI_ERSLN           ;the row-erase
                                          ;primitive, batched
                                          ;per backend
            pla
            sta   VC_COL
            pla
            sta   VC_ROW
            rts

*---------------------------------------------------------------
* TT9_CKM -- ESC [ ? 1 h / l (DECCKM), dispatched from tty2.s's
* TTY_CSI_PRIV once it has matched private-mode value 1. A is
* still the final byte ('h' or 'l') on entry, TTY_CSI_PRIV's own
* convention.
*---------------------------------------------------------------
TT9_CKM     cmp   #'h'
            beq   :seth
            cmp   #'l'
            bne   :out
            stz   VC_DECCKM
:out        rts
:seth       lda   #1
            sta   VC_DECCKM
            rts

*-- TT9_AWM -- ESC [ ? 7 h / l (DECAWM, smam/rmam; VT102 slice
*-- 7). Same entry convention as TT9_CKM: A = the final byte.
*-- Turning autowrap OFF also drops a pending wrap -- the
*-- deferred wrap is autowrap's, and with it off the next
*-- printable overwrites the last column instead.
TT9_AWM     cmp   #'h'
            beq   :on
            cmp   #'l'
            bne   :out
            stz   VC_AWM
            stz   VC_XENL
:out        rts
:on         lda   #1
            sta   VC_AWM
            rts

*---------------------------------------------------------------
* TT9_CUU / TT9_CUD -- ESC [ n A / B (CUU/CUD), margin-aware
* clamp (docs/CONSOLE-VT102.md sec 2 item 7): if the cursor
* started AT OR BELOW VC_MTOP (resp. AT OR ABOVE VC_MBOT), the
* move stops AT the margin; otherwise (the cursor is already
* outside the region -- DECOM is not implemented, so CUP can put
* it there) it stops at the physical edge. Retargets of the old
* TTY_CSI_UP/DOWN dispatch (tty2.s); TTY_CSI_RIGHT/LEFT
* (CUF/CUB)
* already clamp to the physical column edges and have no margin
* concept (DECSTBM is vertical only) -- unchanged.
*---------------------------------------------------------------
TT9_CUU     lda   VC_CSI_ROW
            bne   :haven
            lda   #1
:haven      sta   TT9_RH                  ;N
            lda   VC_ROW
            cmp   VC_MTOP
            bcc   :setfl0                 ;already above MTOP
            lda   VC_MTOP
            bra   :havefl
:setfl0     lda   #0
:havefl     sta   TT9_FLOOR
            lda   VC_ROW
            sec
            sbc   TT9_RH
            bcs   :chkfl                  ;no borrow: A valid
            lda   #0                      ;borrow: floor compare
                                          ;below still applies
:chkfl      cmp   TT9_FLOOR
            bcs   :store                  ;A >= floor: keep it
            lda   TT9_FLOOR
:store      sta   VC_ROW
            rts

TT9_CUD     lda   VC_CSI_ROW
            bne   :haven
            lda   #1
:haven      sta   TT9_RH                  ;N
*-- operands REVERSED from TT9_CUU on purpose: MBOT>=VC_ROW
*-- means VC_ROW<=MBOT (at/above MBOT), ceiling=MBOT. `cmp
*-- VC_MBOT` here tests the WRONG way -- check-vt102's cur case.
            lda   VC_MBOT
            cmp   VC_ROW
            bcs   :setcl
            lda   TTY_ROWS
            sec
            sbc   #1
            bra   :havecl
:setcl      lda   VC_MBOT
:havecl     sta   TT9_CEIL
            lda   VC_ROW
            clc
            adc   TT9_RH
            bcc   :chkcl                  ;no carry: A valid
            lda   #255                    ;carry: ceiling cmp
                                          ;below still clamps it
:chkcl      cmp   TT9_CEIL
            bcc   :store                  ;A < ceiling: keep it
            lda   TT9_CEIL
:store      sta   VC_ROW
            rts

*---------------------------------------------------------------
* TT9_ROWRD / TT9_ROWWR -- VT102 slice 2 (docs/CONSOLE-VT102.md
* sec 2/4): the row<->linear-buffer primitives DCH and IRM both
* shift in. TT9_RBUF is a LINEAR 80-byte scratch, kernel BSS --
* not zero page, not the tick path -- a row shift is done there,
* not cell-by-cell across the native-80 interleave, so DCH/IRM
* cost one read + one write of the row, same shape as N8_ERSLN's
* "one masked window, not one per cell" (learning:
* 01M1JNVYS4E6K0DX5CCSJYD5GE). Both always act on VC_ROW.
*
* Per-backend, matching each backend's EXISTING row-mover exact
* (no new addressing scheme):
*   redirected store   -- one BankCopy, annex row <-> TT9_RBUF
*                          (VCS_N8RCP's shape).
*   40-column glass     -- the row is already contiguous main
*                          memory (TTY_ROW_DST_A); no window.
*   N8 (native 80)       -- ONE php/sei-bracketed aux window for
*                          the even half, the odd half plain
*                          (N8_ERSLN's shape exactly; interleave
*                          gather/scatter as VCS_N8GATH/SCAT).
*   UltraTerm            -- ONE masked VRAM read-back (UT_RGN_
*                          CLAIM + UT_GET_ROW, learning:
*                          01M274ET8ETJ2WEA87EDR93V2J -- the VBL
*                          IRQ steals $C800 mid-read otherwise)
*                          into UT_ROWBUF, then copied here; the
*                          WRITE side needs no such mask (writes
*                          to $CC00 are decoded regardless of
*                          last-claimant, the same learning).
*---------------------------------------------------------------
TT9_ROWRD   lda   TTY_COLS
            sta   TT9_WEND                 ;the row's END for a
            ldx   TTY_DSTBASE+1            ;shift: the width, or
            bne   TT9_RRSTOR               ;the card's dirty
                                           ;bound (TT9_RRUT)
            lda   TTY_BKND
            cmp   #TTY_BKN8
            beq   TT9_RRN8
            cmp   #TTY_BKUT
            beq   TT9_RRUT
            lda   VC_ROW
            jsr   TTY_ROW_DST_A            ;40-col: one
            ldy   #0                       ;contiguous row, no
:lp         lda   (P_PTR2),y               ;window needed
            sta   TT9_RBUF,y
            iny
            cpy   TTY_COLS
            bcc   :lp
            rts

TT9_RRSTOR  lda   VC_ROW
            jsr   TTY_ROW_DST_A            ;P_PTR2 = the store's
                                           ;annex row address
            lda   P_PTR2
            sta   K_BC_SRCADDR
            lda   P_PTR2+1
            sta   K_BC_SRCADDR+1
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            stz   K_BC_SRCBANK
            lda   #BC_KIND_MAIN
            sta   K_BC_DSTKIND
            lda   #<TT9_RBUF
            sta   K_BC_DSTADDR
            lda   #>TT9_RBUF
            sta   K_BC_DSTADDR+1
            stz   K_BC_DSTBANK
            lda   TTY_COLS
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jmp   BankCopy

TT9_RRN8    lda   VC_ROW
            jsr   TTY_ROW_DST_A            ;P_PTR2 = row base
            ldx   #0                       ;odd/main half FIRST,
            ldy   #0                       ;plain -- no window
:mainlp     lda   (P_PTR2),y
            sta   TT9_RBUF+1,x
            iny
            inx
            inx
            cpy   #40
            bne   :mainlp
            php
            sei
            jsr   N8_AUX_ON
            ldx   #0
            ldy   #0
:auxlp      lda   (P_PTR2),y               ;even/aux half, ONE
            sta   TT9_RBUF,x               ;masked window
            iny
            inx
            inx
            cpy   #40
            bne   :auxlp
            jsr   N8_AUX_OFF
            plp
            rts

*-- The card halves go by the row's DIRTY BOUND (perf slice 4,
*-- 2026-09-12): read [0, UT_EXT[row]) into TT9_RBUF and leave
*-- the rest ALONE -- the shifts never read past TT9_WEND (the
*-- bound: TT9_ICHSH starts its shift there, TT9_DCH stops and
*-- blanks there), so no blank fill is needed -- then write back
*-- [0, TT9_WEND), the bound or one more for IRM's shifted row
*-- (TT9_ICHSH bumps it). A whole-row read + write was 8.5k
*-- cycles PER TYPED CHARACTER under IRM on the card, whatever
*-- the line held; vim inserts through IRM. P_TMP2 holds the end
*-- for the copy loops (UT_GET_SPAN left it there): cpy zp.
TT9_RRUT    php
            sei
            jsr   UT_RGN_CLAIM             ;mask the VBL IRQ +
                                           ;reclaim $C800
            ldx   VC_ROW
            lda   UT_EXT,x
            sta   TT9_WEND                 ;the dirty bound
            tax
            lda   VC_ROW
            jsr   UT_GET_SPAN              ;UT_ROWBUF[0,X) <-
            plp                            ;VRAM (P_TMP2 = X)
            ldy   #0
:cplp       cpy   P_TMP2
            bcs   :done
            lda   UT_ROWBUF,y
            sta   TT9_RBUF,y
            iny
            bra   :cplp
:done       rts

TT9_ROWWR   ldx   TTY_DSTBASE+1
            bne   TT9_RWSTOR
            lda   TTY_BKND
            cmp   #TTY_BKN8
            beq   TT9_RWN8
            cmp   #TTY_BKUT
            beq   TT9_RWUT
            lda   VC_ROW
            jsr   TTY_ROW_DST_A
            ldy   #0
:lp         lda   TT9_RBUF,y
            sta   (P_PTR2),y
            iny
            cpy   TTY_COLS
            bcc   :lp
            rts

TT9_RWSTOR  lda   VC_ROW
            jsr   TTY_ROW_DST_A
            lda   #<TT9_RBUF
            sta   K_BC_SRCADDR
            lda   #>TT9_RBUF
            sta   K_BC_SRCADDR+1
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   P_PTR2
            sta   K_BC_DSTADDR
            lda   P_PTR2+1
            sta   K_BC_DSTADDR+1
            stz   K_BC_DSTBANK
            lda   TTY_COLS
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jmp   BankCopy

TT9_RWN8    lda   VC_ROW
            jsr   TTY_ROW_DST_A
            ldx   #0                       ;odd/main half, plain
            ldy   #0
:mainlp     lda   TT9_RBUF+1,x
            sta   (P_PTR2),y
            iny
            inx
            inx
            cpy   #40
            bne   :mainlp
            php
            sei
            jsr   N8_AUX_ON
            ldx   #0
            ldy   #0
:auxlp      lda   TT9_RBUF,x                ;even/aux half, ONE
            sta   (P_PTR2),y                ;masked window
            iny
            inx
            inx
            cpy   #40
            bne   :auxlp
            jsr   N8_AUX_OFF
            plp
            rts

TT9_RWUT    lda   TT9_WEND
            sta   P_TMP2
            ldy   #0
:cplp       cpy   P_TMP2
            bcs   :put
            lda   TT9_RBUF,y
            sta   UT_ROWBUF,y
            iny
            bra   :cplp
:put        stz   UT_TMPCOL
            ldx   TT9_WEND
            lda   VC_ROW
            jmp   UT_PUT_SPAN               ;card write: no VBL
                                            ;read hazard, so no
                                            ;mask (see header);
                                            ;raises the bound to
                                            ;TT9_WEND

*---------------------------------------------------------------
* TT9_DCH -- ESC [ Pn P: shift the row left from the cursor by
* N (VC_CSI_ROW, 0 default -> 1), clamped to the columns AT OR
* RIGHT of the cursor (TTY_COLS-VC_COL) -- DCH cannot shift past
* its own margin. The tail opened by the shift is filled with
* the backend's own blank cell (TTY_BLANK_A, tty8.s). Cursor
* does not move. Not margin-bounded like IL/DL: DCH is a LINE
* operation on the VT102 (docs/CONSOLE-VT102.md sec 2), not a
* region one.
*---------------------------------------------------------------
TT9_DCH     lda   TTY_COLS
            sec
            sbc   VC_COL
            sta   TT9_RH                   ;cols at/right of the
                                           ;cursor
            lda   VC_CSI_ROW
            bne   :haven
            lda   #1
:haven      cmp   TT9_RH
            bcc   :nclamp
            lda   TT9_RH
:nclamp     sta   TT9_DN                    ;N, clamped
            lda   TT9_RH                    ;at the last column
            cmp   #1                        ;nothing shifts: the
            bne   :shift                    ;cell just blanks --
            jmp   TTY_BLNK_CELL             ;no row read/write
                                            ;(perf slice 4)
:shift      jsr   TT9_ROWRD
            jsr   TTY_BLANK_A
            sta   TT9_BLANK
            ldx   VC_COL
:shlp       cpx   TT9_WEND                  ;to the row's END
            bcs   :tail                     ;(width, or the
            txa                             ;card's dirty bound:
            clc                             ;cells past it are
            adc   TT9_DN                    ;blank already)
            cmp   TT9_WEND
            bcs   :blank1                   ;source past the row
                                           ;end: blank instead
            tay
            lda   TT9_RBUF,y
            bra   :store1
:blank1     lda   TT9_BLANK
:store1     sta   TT9_RBUF,x
            inx
            bra   :shlp
:tail       jmp   TT9_ROWWR

*---------------------------------------------------------------
* TT9_MODE -- ESC [ Pn h / l, the non-private ("ANSI") mode
* family (tty2.s CSI_CH/CSI_JT). Pn=4 (VC_CSI_ROW) is IRM
* (smir/rmir): VC_IRM on for 'h', off for 'l'. Any other Pn is
* accepted and silently ignored -- the same "swallow, don't
* render" convention TTY_CSI_PRIV already uses for the private
* modes this console does not model.
*
* UNLIKE TT9_CKM: this table (CSI_CH/CSI_JT, tty2.s
* TTY_CSI_BYTE's :hit) reaches its target through `txa / asl a /
* tax / jmp (CSI_JT,x)` -- A holds the DOUBLED TABLE INDEX on
* entry, not the final byte, because the index computation
* overwrites it. Only TTY_CSI_PRIV's OWN separate direct `jmp`
* (ESC_STATE=3, the `?` prefix) preserves A as the final byte,
* which is what makes that convention true for TT9_CKM and false
* here. So this reads PRC_BYTE (tty2.s TTY_PUT_BYTE's own byte-
* in-flight cell, still unclobbered) instead of trusting A --
* found live: a table-dispatch A compared against 'h' is never
* equal, so IRM never engaged until this was fixed (check-vt102
* smir/rmir, 2026-09-12).
*---------------------------------------------------------------
TT9_MODE    lda   VC_CSI_ROW
            cmp   #4
            bne   :out
            lda   PRC_BYTE
            cmp   #'h'
            beq   :seth
            stz   VC_IRM
            rts
:seth       lda   #1
            sta   VC_IRM
:out        rts

*---------------------------------------------------------------
* TT9_ICHSH -- IRM's push-right, run once per printable while
* VC_IRM is set (docs/CONSOLE-VT102.md sec 2/4, smir/rmir): read
* the row, shift RB[col..cols-2] right by one -- descending, so
* the pushed byte never smears across every later cell -- and
* the last cell falls off the right margin (VT102's own IRM
* wording), write the row back. RB[VC_COL] is left stale on
* purpose: the caller (TTY_PUT_PRNTB) stores the real character
* there, through the ordinary per-cell path, right afterward.
*---------------------------------------------------------------
TT9_ICHSH   lda   VC_COL                   ;at the last column
            inc   a                        ;nothing shifts: the
            cmp   TTY_COLS                 ;printable overwrites
            bcs   :none                    ;the cell (perf sl 4)
            jsr   TT9_ROWRD
*-- A cursor AT or past the row's end has nothing to its right
*-- to move: no shift, and NOTHING written back (the cell past
*-- the end was never read -- a write-back put a stale byte
*-- there, check-vt102 smir_past). This test must come BEFORE
*-- the shift: a shift that starts at end+1 with the cursor
*-- beyond it walks X down past the cursor, wraps through $FF
*-- and scribbles below TT9_RBUF (seen: the console wedged).
            lda   VC_COL
            cmp   TT9_WEND
            bcs   :none
*-- The shift walks DOWN from the row's end+1, clamped to the
*-- width: cells at or past the end are blank on both sides of
*-- the move. On the text-page backends the end IS the width.
            lda   TT9_WEND
            inc   a
            cmp   TTY_COLS
            bcc   :setx
            lda   TTY_COLS
:setx       tax
:shlp       dex
            cpx   VC_COL
            beq   :tail
            lda   TT9_RBUF-1,x
            sta   TT9_RBUF,x
            bra   :shlp
:tail       lda   TT9_WEND                 ;the card writes one
            cmp   #UT_COLS                 ;more cell than it
            bcs   :wr                      ;read: the shifted
            inc   TT9_WEND                 ;row is one longer
:wr         jmp   TT9_ROWWR                ;(TT9_RRUT/RWUT)
:none       rts

*-- Scratch, transient like TTY_SCRL_N/TOP/FLR/BOT (tty.s) --
*-- dead
*-- between calls, not per-console.
TT9_T0      ds 1
TT9_B0      ds 1
TT9_RH      ds 1
TT9_ROW     ds 1
TT9_LOOP    ds 1
TT9_EEND    ds 1                          ;TTY_ERS_SPAN: end col
                                          ;(exclusive)
TT9_WEND    ds 1                          ;TT9_RRUT/RWUT: the
                                          ;card row's write end
TT9_FLOOR   ds 1
TT9_CEIL    ds 1
TT9_DN      ds 1
TT9_BLANK   ds 1
TT9_PCHAR   ds 1
*---------------------------------------------------------------
* THE VISUAL BELL (docs/TTY-TYPEAHEAD-BELL.md, CONSOLE-VT102.md
* row 33; terminfo `flash`). TTY_FLSH: 0 idle, 1 armed by a BEL
* (tty2.s TTY_PUT_CTL), 2 page inverted. Only the TICK draws:
* after TTY_POLL it inverts the page (1 -> 2); at the top of the
* NEXT tick, before the poll, it inverts it back (2 -> 0), so
* one video frame shows the flash. The page is the only truth:
* the restore is the same fold applied again, from the cell
* content, never from a copy. Anything that would draw on an
* inverted page settles it first: TTY_CRSR_HIDE (every write
* entry, console switch) calls TTY_FLSETTLE, which RE-ARMS the
* bell (state 1): the page is inverted again, output included,
* at that tick's end and still gets one full frame. The
* cursor cell is just another cell. UltraTerm: no VRAM -- the
* card's attribute register $C0B3 is swapped so PLAIN cells show
* inverse (bits 1/0), and TTY_ATTR_APP rewrites the console's
* own value. The page walk costs ~30k cycles (40-col) / ~60k
* (N8) inside the tick: a few VBLs are missed per bell. A BEL on
* a background console arms the one global cell and flashes the
* glass (accepted).
*---------------------------------------------------------------
TTY_FLSH    ds 1
* -- Inverted page: TTY_FLSH counts DOWN from 4 (tty.s), one
* -- per tick, restoring at 2. The walk itself takes ~2 ticks
* -- (40-col: ~37k cycles, 15 polls) and the VBL that fell due
* -- meanwhile fires the instant it ends, so a bare "next tick"
* -- restore showed ~0 frames of flash. 4 = ~2 whole frames.

* TTY_FLSETTLE -- if the page is inverted, put it back.
TTY_FLSETTLE
            lda   TTY_FLSH
            cmp   #2
            bcc   :r
            jsr   TTY_FLTOGL
            lda   #1                   ;re-arm: not yet shown
            sta   TTY_FLSH             ;for its full ticks
:r          rts

* TTY_FLTOGL -- fold the whole glass (state 1: invert; >= 2:
* restore). Clobbers A X Y P_PTR2 P_IDX.
TTY_FLTOGL
            lda   TTY_BKND
            cmp   #TTY_BKUT
            bne   :text
            lda   TTY_FLSH
            cmp   #2
            bcs   :utrst
            lda   #$02
            sta   UT_MODE_CTL          ;plain cells inverse
            rts
:utrst      jmp   TTY_ATTR_APP
:text       stz   P_IDX
:row        lda   P_IDX
            jsr   TTY_ROW_DST_A
            ldy   #39
:m          lda   (P_PTR2),y
            jsr   TTY_FLFOLD
            sta   (P_PTR2),y
            dey
            bpl   :m
            lda   TTY_BKND
            cmp   #TTY_BKN8
            bne   :next
            php
            sei
            jsr   N8_AUX_ON
            ldy   #39
:a          lda   (P_PTR2),y
            jsr   TTY_FLFOLD
            sta   (P_PTR2),y
            dey
            bpl   :a
            jsr   N8_AUX_OFF
            plp
:next       inc   P_IDX
            lda   P_IDX
            cmp   TTY_ROWS
            bcc   :row
            rts

* TTY_FLFOLD -- display code <-> its inverse, an INVOLUTION over
* all 256 codes (ALTCHRSET on; learning 01M02NT5M7PXSZTHGVJKRENG
* M4). Normal ASCII c shows as c|$80, inverse as c&$3F, so:
* bit 5 set ($20-$3F $60-$7F $A0-$BF $E0-$FF) swaps by eor $80;
* bit 5 clear swaps $00-$1F <-> $C0-$DF by eor $C0; $40-$5F
* (MouseText) and $80-$9F are left alone. A only (X scratch).
TTY_FLFOLD
            tax
            and   #$20
            beq   :c5
            txa
            eor   #$80
            rts
:c5         txa
            asl                        ;C = bit 7, N = bit 6
            bcs   :hi
            bmi   :same                ;01: $40-$5F
            bra   :swap                ;00: $00-$1F
:hi         bpl   :same                ;10: $80-$9F
:swap       txa
            eor   #$C0                 ;00 or 11 -> the other
            rts
:same       txa
:x          rts

*-- The row-shift scratch (DCH/IRM). 80 bytes, kernel BSS: not
*-- zero page, not the tick path (docs/CONSOLE-VT102.md sec 4,
*-- task #23 deliverable A).
*-- TT9_RBUF (80 B): inc/mm.kbss.equ, low main.
