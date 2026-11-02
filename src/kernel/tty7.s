*---------------------------------------------------------------
* tty7.s -- the VIDMODE machinery (docs/VIDMODE.md): TTY_HW_SET,
* the N8 store<->glass blit movers, and TTY_CSI_MODE
* (ESC [ c;r;d v). The row-0 status-line reflow that used to
* live here (TTY_ST_RFLW/VC_RFLW_CK) was removed 2026-09-03: row
* 0 is ordinary per-console content now (docs/CONSOLE.md sec 6),
* covered by the same blit/clear every other row goes through.
*
* SPLIT OUT OF tty6.s 2026-09-01, same reason tty6 was split out
* of tty3 the day before: tty6's STRIPPED size (18,191 B) alone
* outgrew as's 16,128 B source window, and as the largest put of
* every kernel harness it charged all of them (check-dialect 3b,
* 15 units newly over). The cut is at the section banner above
* TTY_HW_SET; this file is `put` immediately after tty6.s.
* Kernel modules are one flat symbol space.
*---------------------------------------------------------------
*---------------------------------------------------------------
* TTY_HW_SET -- program the DISPLAY for the loaded console's
* backend (VIDMODE V1). Called by VC_SWITCH after the struct
* swap, and by the mode escape after a change. 40/N8 are one
* soft switch apart; a UT console leaves the card exactly as it
* is (V1's validator never mixes UT with anything else -- the
* VIDSEL pass-through work is V2's).
*---------------------------------------------------------------
TTY_HW_SET
            lda   TTY_BKND
            cmp   #TTY_BKUT
            beq   :ut
            cmp   #TTY_BKN8
            beq   :n8
            cmp   #TTY_BK40
            bne   :rej
            sta   COL80OFF
            bra   :mboard
:n8         sta   COL80ON
* -- a motherboard console took the glass. Is a card driving the
* monitor? Only if UT_INIT ever ran -- else VIDSEL was never set
* and there is nothing to drop. Dual head: the card keeps its
* glass on a second monitor. Single (the default): the card
* passes the mainboard video through, so the one screen follows
* the active console (VIDMODE V2.1).
:mboard     lda   UT_INITED
            beq   :rej
            lda   TTY_DUALHEAD
            bne   :rej
            jmp   UT_VID_PASS
:rej        rts
:ut         lda   UT_INITED            ;first card console on a
            bne   :vidsel              ;machine that booted on
            jsr   UT_INIT              ;the motherboard: program
:vidsel     jsr   UT_SEL_PAGE          ;the CRTC once; then the
                                       ;card takes the monitor
            jmp   TTY_ATTR_APP       ;and shows THIS console's
                                       ;emphasis (VC_ATTRMODE)

*---------------------------------------------------------------
* BYE_TTYRES -- bye's own return-path trampoline
* (docs/BYE-SLICE1-NOTES.md, the console-corruption finding).
* byelaunch.s forces the glass to plain 40-column, VIDSEL-off
* for the tenant; nothing on the return path put the CONSOLE's
* own mode back (BYE_BACK only restores 80STORE, a memory
* switch, not a display one) -- confirmed as garbled screen
* text. Calls the SAME routine the console uses to reassert its
* own display whenever it becomes visible (TTY_HW_SET, above),
* which reads the ACTIVE console's own already-correct state,
* then falls into SCH_RESUME.
*
* NOT inlined into SCH_RESUME (sched.s): that routine is `put`
* by every scheduler-having image, including three schedtest
* harnesses with no console or bye at all -- an inline `jsr
* TTY_HW_SET` there is an undefined-symbol assembly error in
* those builds (confirmed by rebuilding one). This file is put
* ONLY where TTY_HW_SET itself is defined, and procbye.s's own
* BB_RESVEC stamp (its ONLY caller) now targets this symbol
* instead of SCH_RESUME directly -- the SAME 10-byte stamp cost
* as before, just a different address loaded, so procbye.s's own
* razor-thin PT_HOLD headroom is untouched by this file's cost.
*---------------------------------------------------------------
BYE_TTYRES
            jsr   TTY_HW_SET
            jmp   SCH_RESUME

*---------------------------------------------------------------
* TTY_CSI_MODE -- ESC [ <cols> ; <rows> ; <disc> ; <surface> v:
* set THIS console's mode (docs/VIDMODE.md sec 2, sec 10).
* Geometry-addressed on the wire; the kernel derives the backend
* -- 40x24 -> BK40, 80x24 -> BKN8 (the motherboard wins the tie
* by ruling) -- unless the FOURTH parameter, the surface (V2.0
* says 2 = the card: 80x24 on the UltraTerm's HQ format,
* accepted only when a card answers (probed now if boot never
* did). Surface 3/4 is not a surface at all but the machine
* HEAD MODE (3 onehead, 4 dualhead, docs/VIDMODE.md sec 11),
* handled and returned before the geometry validation.
* cols=0 keeps geometry (a pure discipline switch).
* Everything else is IGNORED, the terminal discipline for an
* impossible escape -- vidmode(1) speaks, the wire does not.
* A UT-boot console is no longer pinned: `vidmode 80` moves it
* to the motherboard and TTY_HW_SET drops VIDSEL so the card
* passes the motherboard video through (one monitor), and
* `vidmode hq` brings it back, its screen repainted from the
* store it wrote through to (docs/VIDMODE.md sec 4).
* A geometry CHANGE clears the body and homes the cursor (the
* UltraTerm firmware's own behaviour on format change); a
* discipline-only change repaints nothing.
*
* VALIDATE EVERYTHING, THEN COMMIT (review V1 finding 3: the
* first cut stored TTY_DISC before checking the geometry, so a
* refused escape still half-applied). The whole tuple is one
* request: an invalid discipline value ignores the escape
* ENTIRELY, and an unacceptable geometry ignores it entirely
* TOO, discipline included. cols=0 makes it a discipline-only
* request, which a UT-pinned machine still honours -- the pin
* is about the glass, not the byte stream.
*---------------------------------------------------------------
* -- surface 3/4 is the machine HEAD MODE, not a per-console
* -- surface: 3 = onehead (VIDSEL follows the active console --
* -- the default), 4 = dualhead (VIDSEL held for a 2nd monitor).
* -- 3->0, 4->1; 5+ ignored. Re-run TTY_HW_SET so the change
* -- takes on the live console at once (docs/VIDMODE.md sec 11).
TTY_CSI_MODE
            lda   VC_CSI_P4
            cmp   #3
            bcc   :notohead
            cmp   #5
            bcs   :nope
            sec
            sbc   #3
            sta   TTY_DUALHEAD
            jmp   TTY_HW_SET
:notohead   lda   VC_CSI_P3           ;-- validation pass --
            cmp   #3
            bcs   :nope              ;disc 3+: ignore ALL
            lda   VC_CSI_P4           ;param 4 = surface (V2.0):
            cmp   #3                  ;0 derive, 1 motherboard,
            bcs   :nope              ;2 card (3/4 handled above)
            lda   VC_CSI_ROW          ;param 1 = cols
            beq   :commit             ;0: discipline-only
            lda   VC_CSI_COL          ;param 2 = rows
            cmp   #24
            bne   :nope              ;24 rows only
            lda   VC_CSI_ROW
            cmp   #40
            bne   :not40
            lda   VC_CSI_P4           ;40 columns: motherboard
            cmp   #2                  ;only -- the card has no
            beq   :nope              ;40-column format here
            bra   :commit
:not40      cmp   #80
            bne   :nope              ;40 or 80 only
            lda   VC_CSI_P4
            cmp   #2
            bne   :commit             ;80 on the motherboard
            lda   UT_PRESENT          ;80 on the CARD: is there
            bne   :commit             ;one? Probe now if boot
            jsr   UT_DETECT           ;never did (a forced 40/
            bcc   :commit             ;N8 boot skips UT_DETECT)
:nope       rts                       ;(near: :done is out of
                                      ;branch range from here)
:commit     lda   VC_CSI_P3           ;-- commit pass --
            beq   :geom               ;no disc param
            cmp   #2
            beq   :ap
            stz   TTY_DISC            ;1 = vt
            bra   :geom
:ap         lda   #1                  ;2 = apple
            sta   TTY_DISC
:geom       lda   VC_CSI_ROW
            beq   :done               ;discipline-only: done
            cmp   #40
            beq   :b40
            ldx   #TTY_BKN8
            ldy   VC_CSI_P4           ;surface 2 = the card at
            cpy   #2                  ;80x24 (validated above)
            bne   :apply
            ldx   #TTY_BKUT
            bra   :apply
:b40        ldx   #TTY_BK40
:apply      cpx   TTY_BKND
            beq   :done               ;already there: no clear
            ldy   TTY_WR_SWAP         ;a BACKGROUND console: the
            bne   :store              ;glass is not ours
            phx                       ;-- the ACTIVE console
            pha                       ;leaves its surface: hand
            jsr   VC_LEAVE            ;that glass on first --
            pla                       ;its old geometry is live
            plx
            stx   TTY_BKND
            sta   TTY_COLS            ;A still holds cols
            lda   #24
            sta   TTY_ROWS
            jsr   TT9_MRESET          ;a geometry change re-
                                      ;derives DECSTBM margins
                                      ;(VT102 slice 1)
            jsr   TTY_HW_SET
            jsr   TTY_CLR_BODY        ;fresh body in the new
            lda   VC_ACTIVE           ;geometry, cursor home,
            jsr   VC_TAKE_A           ;and the new glass is ours
            bra   :home
:store      stx   TTY_BKND            ;background: its store
            sta   TTY_COLS            ;only. An owner gives its
            lda   #24                 ;glass up (VC_DROP_A) and
            sta   TTY_ROWS            ;is redirected from here
            jsr   TT9_MRESET          ;VT102 slice 1
            lda   TTY_TARGET
            jsr   VC_DROP_A
            jsr   TTY_SET_DSTB
            jsr   VCS_CLR_BODY        ;the GLASS-shaped clear is
                                      ;lethal here: N8_CLR_AUX
                                      ;raw-stores through store
                                      ;addresses, which in main
                                      ;memory is KERNEL TEXT at
                                      ;$2000+ -- seen live as a
                                      ;full-machine wedge on the
                                      ;first `vidmode 80 >
                                      ;/dev/tty2` (2026-09-01);
                                      ;the store clear banks
                                      ;each byte via TTY_STORE_Y
:home       stz   VC_ROW              ;home to row 0 -- no more
            stz   VC_COL              ;reserved status line
            stz   VC_SAVE_ROW         ;a cursor saved under the
            stz   VC_SAVE_COL         ;old geometry is void
                                      ;(finding VT6, 2026-09-12)
:done       rts

*---------------------------------------------------------------
* PRC_TTYGEO -- SYS_TTYGEO (docs/VIDMODE.md sec 2). Defined by
* procdev.s (KSEG_CALL trampoline into kdevblk.s PRC_TTYGEO_SG)
* or procdevs.s (the plain body, manifests with no segment).
* MOVED OUT of this file 2026-10-08 for flat headroom (the
* visual bell, docs/TTY-TYPEAHEAD-BELL.md); GEO_BUF stays here,
* flat, because BankCopy reads and writes it.
*---------------------------------------------------------------

GEO_BUF     ds 4

*---------------------------------------------------------------
* TTY_COOK_RAW -- tick context, reached only from tty3.s's
* TTY_COOK1 when the active console's VC_TMODE has ICANON clear
* (stty seed, 2026-09-02). PRC_BYTE already holds the one ring
* byte TTY_COOK1 just dequeued (VC_RAW_HD advanced, cursor
* hidden) -- the line-editor dispatch below TTY_COOK1's :cooked
* label never runs for this byte. ECHO still applies here,
* orthogonally: a raw+echo console (cbreak with visible keys)
* paints the byte through the SAME primitive cooked mode uses;
* raw+noecho (vi's mode) paints nothing. Either way the byte
* commits as its own one-byte "line" -- TTY_READ needs no
* change at all, it already serves whatever VC_IN_LEN/VC_IN_POS
* say is ready. Caller (TTY_POLL's :drain) has already ensured
* no line is pending (VC_IN_POS>=VC_IN_LEN), so this always has
* room.
*---------------------------------------------------------------
*-- AN ARROW IS ONE 3-BYTE LINE (2026-09-10). TTY_KEYIN pushes
*-- an arrow as ESC [ final, three bytes or none (tty3.s :csi),
*-- so when this dequeues an ESC the other two are ALREADY in
*-- the ring if it was an arrow -- a hand-typed ESC has nothing
*-- behind it (the next key is ticks away). Committing the trio
*-- as one line lets a raw reader that asks for 3 bytes tell a
*-- bare ESC (1 byte back) from an arrow (3 back) without a
*-- timeout, which is VI-DESIGN sec 8 item 1 answered: framed.
*-- A reader asking for 1 byte still gets them one at a time
*-- (TTY_READ serves min(req, avail) of the committed line), so
*-- nothing that reads a byte at a time changes. Found live
*-- 2026-09-10: vi's insert loop took the arrow's ESC as
*-- end-of-insert, so the //e's left-arrow -- its BACKSPACE key,
*-- one wire with ^H -- silently dropped you into command mode
*-- and the Enter after it ran as a motion.
TTY_COOK_RAW
            lda   PRC_BYTE
            sta   VC_INBUF
            ldx   #1
            stx   VC_IN_LEN
            stz   VC_IN_POS
            cmp   #$9B                    ;ESC: an arrow's CSI?
            bne   :echo
            ldx   VC_RAW_HD
            cpx   VC_RAW_TL
            beq   :echo                   ;ring empty: bare ESC
            lda   VC_RAW_BUF,x
            cmp   #$DB                    ;'['
            bne   :echo
            inx
            txa
            and   #VC_RAW_MASK
            tax
            cpx   VC_RAW_TL
            beq   :echo                   ;'[' alone: leave it
            lda   VC_RAW_BUF,x
            cmp   #$C1                    ;A..D = up/down/right
            bcc   :echo                   ;/left
            cmp   #$C5
            bcs   :echo
            sta   VC_INBUF+2
            lda   #$DB
            sta   VC_INBUF+1
            inx
            txa
            and   #VC_RAW_MASK
            sta   VC_RAW_HD               ;dequeue '[' + final
            lda   #3
            sta   VC_IN_LEN
:echo       lda   VC_TMODE
            and   #TMD_ECHO
            beq   :wake
            ldy   #0
:echol      lda   VC_INBUF,y
            phy
            jsr   TTY_PUT_BYTE
            ply
            iny
            cpy   VC_IN_LEN
            bcc   :echol
:wake       jmp   TTY_WAKE_RDRS

*---------------------------------------------------------------
* TTY_TMODE_STO -- store console A's VC_TMODE (live cell if A is
* VC_ACTIVE, else its annex slot -- same dual addressing
* PRC_TTYGEO uses for the other three mode bytes). IN: A =
* console index 0..VC_COUNT-1, Y = new flags. A cold (never
* switched-to) console's slot is written too -- harmless: its
* first VC_SWITCH still runs VC_RESET, which stamps the cooked
* default over every field including this one, so nothing a
* SET wrote to a cold slot can ever be read back stale -- a
* cold console's SLOT bytes may be uninitialized garbage, so the
* OLD value this returns for one is meaningless too, same
* rationale, and not distinguished from a warm read: nobody
* depends on a cold console's PREVIOUS mode meaning anything.
* RETURNS THE OLD VALUE IN A -- PRC_TTYMODE (below) and
* PRC_TMD_RST (procspawn2.s, the crash-safety backstop) share
* this ONE routine rather than each owning a slot BankCopy of
* its own. Clobbers A, X, Y, TMD_NEWVAL, TMD_PREV, TMD_SLO,
* TMD_SHI.
*---------------------------------------------------------------
TTY_TMODE_STO
            sty   TMD_NEWVAL
            cmp   VC_ACTIVE
            bne   :slot
            lda   VC_TMODE
            pha
            lda   TMD_NEWVAL
            sta   VC_TMODE
            pla
            rts
:slot       tax
            lda   #<VC_TMODE
            sec
            sbc   #<VC_STATE
            clc
            adc   VC_SLT_LO,x
            sta   TMD_SLO
            lda   VC_SLT_HI,x
            adc   #0
            sta   TMD_SHI
            lda   #BC_KIND_BANK    ;read: slot -> TMD_PREV
            sta   K_BC_SRCKIND
            lda   TMD_SLO
            sta   K_BC_SRCADDR
            lda   TMD_SHI
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_MAIN
            sta   K_BC_DSTKIND
            lda   #<TMD_PREV
            sta   K_BC_DSTADDR
            lda   #>TMD_PREV
            sta   K_BC_DSTADDR+1
            stz   K_BC_DSTBANK
            lda   #1
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
*-- K_BC_LEN AGAIN: BankCopy consumes it in place (it is the
*-- REMAINING count), so after the read it is 0 and a second
*-- call copies nothing -- "a zero-length call is legal and
*-- fills only". Found 2026-09-08 by check_vi_alt's killed_bg:
*-- a vi killed while its console was in the BACKGROUND came
*-- back raw+noecho (slot never written); the foreground lane
*-- above never had the bug, which is why check_vi_bang's
*-- killed case was green all along.
            lda   #1
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            lda   #BC_KIND_MAIN    ;write: TMD_NEWVAL -> slot
            sta   K_BC_SRCKIND
            lda   #<TMD_NEWVAL
            sta   K_BC_SRCADDR
            lda   #>TMD_NEWVAL
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   TMD_SLO
            sta   K_BC_DSTADDR
            lda   TMD_SHI
            sta   K_BC_DSTADDR+1
            stz   K_BC_DSTBANK
            jsr   BankCopy
            jsr   PRC_SEL_CRBNK    ;$C073 home -- BankCopy's own
                                   ;obligation, TTY_WAKE_RDRS'
                                   ;precedent
            lda   TMD_PREV
            rts

TMD_NEWVAL  ds 1
TMD_PREV    ds 1
TMD_SLO     ds 1
TMD_SHI     ds 1

*---------------------------------------------------------------
* PRC_TTYMODE -- SYS_TTYMODE. Defined by procdev.s (a KSEG_CALL
* trampoline into kdevblk.s PRC_TTYMD_SEG, which also carries
* the cooked edit buffer into the raw ring on ICANON 1->0,
* docs/TTY-TYPEAHEAD-BELL.md) or by procdevs.s (the plain body,
* for the manifests with no segment). MOVED OUT of this file
* 2026-10-07 for flat headroom; TTY_TMODE_STO stays here.
*---------------------------------------------------------------

*---------------------------------------------------------------
* VCS_ST_SPAN was the run-batch write-through of a card span to
* its store. REMOVED 2026-09-10: the card reads its VRAM back on
* switch-away (VCS_UTSAVE, tty8.s) instead of keeping the store
* write-through, so TTY_RUN writes VRAM only.
*---------------------------------------------------------------
