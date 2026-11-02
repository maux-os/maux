*---------------------------------------------------------------
* tty5.s -- the native //e 80-column backend (N8).
*
* SPLIT OUT OF tty4.s, 2026-08-30, for the reason tty4.s was
* split out of tty2.s: `as`'s 16,126-byte source window. tty4.s
* is the charged put of the kernel manifests, and the console
* store's routing work pushed src/test/testevtest.s over -- a
* unit past that window cannot be assembled inside maux at all,
* and merlin32 cannot see the ceiling.
*
* The cut is at a section boundary and this file is `put`
* immediately after its parent, so the emitted bytes are
* unchanged -- which is what check-bytes asserts.
*
* N8 is a coherent unit on its own terms: it is the native
* 80-column backend, the same way ultraterm.s is the UltraTerm
* one. Kernel modules are one flat symbol space, so tty2.s and
* tty4.s call into here with no declaration.
*---------------------------------------------------------------
*---------------------------------------------------------------
* TICK-PATH EXPOSURE, stated so the safety stays DESIGNED
* rather than incidental (S3 review N6, 2026-08-23). N8 adds
* state to the tick-shared tty path that TTY_TICK's
* save/restore list does NOT cover: N8_BYTE below, plus
* PRC_SEL_CRBNK's A clobber (a K_CURBANK load since
* 2026-09-03 -- no K_PCB_*/K_CPY_* traffic any more), plus
* two $C073 writes per even-column access. Today this cannot
* race: ffpage.s masks the WHOLE syscall (sei for the
* duration), every N8 aux window is php/sei-bracketed, and
* BankCopy brackets its chunks -- so no tick can interleave a
* second N8_STORE with one in flight. THE REQUIREMENT THAT
* KEEPS IT TRUE: anyone unmasking any part of the syscall or
* tick path must EITHER add N8_BYTE and the bank-select
* discipline to TTY_TICK's save/restore, or keep every
* TTY_PUT_BYTE reachable only under a mask. Related staleness,
* not this module's to fix: bankcopy.s's "KRN_IRQ_SVC never
* writes BANKSEL" comment is no longer true of the IRQ path as
* a whole once the tick's echo can reach N8_AUX_ON (flagged to
* S4 in the S3 stream report).
N8_BYTE     ds 1               ;byte in flight through
N8_EMAIN    ds 1               ;N8_ERSSPAN: odd-half end
N8_EAUX     ds 1               ;N8_ERSSPAN: even-half end
                               ;N8_STORE/N8_LOAD -- survives
                               ;the helpers' A clobbers

N8_INIT
            lda   #80
            sta   TTY_COLS
            sta   COL80ON                  ;80-column display on
                                           ;-- the access is the
                                           ;switch, the value is
                                           ;ignored
            rts

* N8_SETUP -- P_PTR2 = row base (shared interleave table), Y =
* column/2, and CARRY = column bit 0: set = odd = MAIN half,
* clear = even = AUX half. tay/rts preserve carry.
N8_SETUP
            lda   VC_ROW
            jsr   TTY_ROW_DST_A
            lda   VC_COL
            lsr
            tay
            rts

* N8_AUX_ON / N8_AUX_OFF -- open/close the aux-half window.
* CALLER holds php/sei around the pair (a helper cannot own
* php/plp across its own rts). ON leaves the routing at aux
* bank 0; OFF restores main routing and the current process's
* sticky bank. OFF clobbers A/X/Y (PRC_SEL_CRBNK's PCB read).
N8_AUX_ON
            lda   #0
            sta   BANKSEL                  ;the video scanner
                                           ;reads bank 0 ONLY --
                                           ;and BANKSEL is
                                           ;sticky with someone
                                           ;else's bank
            sta   SET80STORE
            sta   PAGE2ON
            rts

N8_AUX_OFF
            sta   PAGE2OFF
            sta   CLR80STORE               ;STEADY STATE is off
                                           ;(mm.hw.equ) --
                                           ;fork/BankCopy and
                                           ;S1's sabotage gate
                                           ;depend on it
            jmp   PRC_SEL_CRBNK

* N8_STORE -- display byte A -> (VC_ROW, VC_COL).
N8_STORE
            sta   N8_BYTE
            jsr   N8_SETUP
            bcs   :main
            php
            sei
            jsr   N8_AUX_ON
            lda   N8_BYTE
            sta   (P_PTR2),y
            jsr   N8_AUX_OFF
            plp
            rts
:main       lda   N8_BYTE
            sta   (P_PTR2),y
            rts

* N8_LOAD -- A = display byte at (VC_ROW, VC_COL). The read
* half of the cursor's save/paint -- possible here because the
* 80STORE+PAGE2 route serves reads too.
N8_LOAD
            jsr   N8_SETUP
            bcs   :main
            php
            sei
            jsr   N8_AUX_ON
            lda   (P_PTR2),y
            sta   N8_BYTE
            jsr   N8_AUX_OFF
            plp
            lda   N8_BYTE
            rts
:main       lda   (P_PTR2),y
            rts

* N8_ERSSPAN -- TTY_ERS_SPAN's native-80 case: blank display
* columns [VC_COL, TT9_EEND) with ONE masked aux window for the
* whole even half, not one per even cell (~40 brackets, each a
* PCB read -- vi repaints one ESC [ K per row and crawled; see
* TTY_ERS_SPAN). The window is <=40 stores, inside the per-row
* ~600-cycle bound, 80STORE off again on exit --
* learning:01M0NZFJMX163HFK2CM64Q9GVA. The odd (main) half
* needs no window at all. Odd columns c in [s,e) are main
* offsets [s>>1, e>>1); even columns are aux offsets
* [(s+1)>>1, (e+1)>>1) -- N8_SETUP's Y is s>>1 with C = s&1, so
* Y+C is the even start, and one lsr of the end gives both
* ends the same way. (Was N8_ERSLN, the tail only, until the
* head erase and the whole-row clear joined it, 2026-09-12.)
* VC_COL and VC_ROW are untouched -- erase must not move the
* cursor.
* The two fills COUNT DOWN in X (dex/bne) rather than compare Y
* against an end cell each store: cpy abs + bcc cost 2 cycles a
* cell more than the old cpy #40, and over 80 cells that put 5%
* back on every ESC [ K (measured, 2026-09-12). The counts can
* never be negative: every caller passes s <= e.
N8_ERSSPAN
            lda   TT9_EEND
            lsr                            ;A = e>>1, C = e&1
            sta   N8_EMAIN                 ;odd-half end
            adc   #0
            sta   N8_EAUX                  ;even-half end
            jsr   N8_SETUP                 ;P_PTR2 = row base,
            tya                            ;C = column bit 0
            adc   #0                       ;A = Y+C, even start
            sta   P_TMP
            tya
            eor   #$FF                     ;-Y-1
            sec
            adc   N8_EMAIN                 ;odd count = end - Y
            beq   :aux                     ;(none)
            tax
            lda   #$A0
:mainlp     sta   (P_PTR2),y               ;odd half -- plain
            iny                            ;main stores
            dex
            bne   :mainlp
:aux        lda   P_TMP
            eor   #$FF
            sec
            adc   N8_EAUX                  ;even count
            beq   :done                    ;(none: no window)
            sta   N8_EAUX                  ;(N8_AUX_ON keeps Y;
            ldy   P_TMP                    ;X reloaded after it)
            php
            sei
            jsr   N8_AUX_ON                ;even half -- ONE
            ldx   N8_EAUX                  ;masked aux window
            lda   #$A0
:auxlp      sta   (P_PTR2),y
            iny
            dex
            bne   :auxlp
            jsr   N8_AUX_OFF
            plp
:done       rts

* N8_PUT_SPAN -- TTY_RUN's native-80 case (perf slice 2,
* 2026-09-12): store the encoded cells UT_ROWBUF[VC_COL,
* TT9_EEND) to row VC_ROW -- odd columns straight to main,
* even columns through ONE masked aux window (<=40 stores,
* the per-row bound, learning:01M0NZFJMX163HFK2CM64Q9GVA).
* Column c lives at rowbase + c/2: odd c in main, even c in
* aux. The first odd column at or after s is s|1 and its main
* offset s>>1 (N8_SETUP's Y); the first even column is (s+1)&
* $FE and its aux offset (s+1)>>1 (Y + N8_SETUP's carry). Per
* cell the old path (N8_STORE) recomputed the row base and, on
* every even column, opened and closed the window with a PCB
* read -- 31.7k cycles for an 80-character row. VC_COL/VC_ROW
* untouched (TTY_RUN advances them). CLOBBERS: A, X, Y, P_TMP,
* P_PTR2 (+ N8_AUX_OFF's).
N8_PUT_SPAN
            jsr   N8_SETUP                 ;P_PTR2 = row base,
            tya                            ;Y = s>>1, C = s&1
            adc   #0
            sta   P_TMP                    ;even dest (s+1)>>1
            lda   VC_COL
            ora   #1
            tax                            ;first odd column
            bra   :mtest
:mainlp     lda   UT_ROWBUF,x              ;odd half -- plain
            sta   (P_PTR2),y               ;main stores
            iny
            inx
            inx
:mtest      cpx   TT9_EEND
            bcc   :mainlp
            lda   VC_COL
            inc   a
            and   #$FE
            tax                            ;first even column
            cpx   TT9_EEND
            bcs   :done                    ;(none: no window)
            ldy   P_TMP
            php
            sei
            jsr   N8_AUX_ON                ;even half -- ONE
:auxlp      lda   UT_ROWBUF,x              ;masked aux window
            sta   (P_PTR2),y
            iny
            inx
            inx
            cpx   TT9_EEND
            bcc   :auxlp
            jsr   N8_AUX_OFF
            plp
:done       rts

* N8_SCRL_AUX -- the aux half of a scroll: rows 1-23 copied up
* one, aux half of row 23 blanked. Runs AFTER TTY_SCROLL40 has
* done the same to the main half. Window is opened per ROW, not
* per byte and not across the whole body: ~600 masked cycles a
* row keeps IRQ latency bounded, and the row copy stays inside
* one open window so it costs 40 copies, not 40 brackets.
N8_SCRL_AUX
            lda   TTY_SCRL_TOP             ;src=TOP+N, like the
            clc                             ;TTY_SCROLL40 half
            adc   TTY_SCRL_N                ;(TOP=0=whole)
            sta   P_IDX
:rowlp      lda   P_IDX
            sec
            sbc   TTY_SCRL_N
            jsr   TTY_ROW_DST_A            ;P_PTR2 = row P_IDX-N
            lda   P_IDX
            jsr   TTY_ROW_SRC_A            ;P_PTR1 = this row
            php
            sei
            jsr   N8_AUX_ON
            ldy   #0
:copy       lda   (P_PTR1),y
            sta   (P_PTR2),y
            iny
            cpy   #40
            bne   :copy
            jsr   N8_AUX_OFF
            plp
            inc   P_IDX
            lda   P_IDX
            cmp   TTY_SCRL_BOT              ;region bot (VT102
            bcc   :rowlp                    ;slice 1, DECSTBM)
            lda   TTY_SCRL_BOT             ;blank the aux half
            sec                            ;of the bottom N
            sbc   TTY_SCRL_N               ;rows of the REGION,
            sta   P_IDX                    ;one window each
:clrlp      lda   P_IDX
            jsr   TTY_ROW_DST_A
            php
            sei
            jsr   N8_AUX_ON
            ldy   #0
            lda   #$A0
:clear      sta   (P_PTR2),y
            iny
            cpy   #40
            bne   :clear
            jsr   N8_AUX_OFF
            plp
            inc   P_IDX
            lda   P_IDX
            cmp   TTY_SCRL_BOT
            bcc   :clrlp
            rts

*---------------------------------------------------------------
* N8_SAUX_REV -- the aux half of TTY_SCRL_REV: rows
* [0, textrows-N) move DOWN to [N, textrows); top N blanked.
* Mirror of N8_SCRL_AUX, dst high->low (dst = src + N).
*---------------------------------------------------------------
N8_SAUX_REV
            lda   TTY_SCRL_TOP             ;floor = TOP+N (TOP=0
            clc                             ;-> N), like the
            adc   TTY_SCRL_N                ;TTY_SCR40_REV half
            sta   TTY_SCRL_FLR
            lda   TTY_SCRL_BOT              ;dst=region
            sec                             ;bottom-1
            sbc   #1                        ;(VT102 sl 1)
            sta   P_IDX
:rowlp      lda   P_IDX
            jsr   TTY_ROW_DST_A            ;P_PTR2 = dst row
            lda   P_IDX
            sec
            sbc   TTY_SCRL_N
            jsr   TTY_ROW_SRC_A            ;P_PTR1 = dst-N
            php
            sei
            jsr   N8_AUX_ON
            ldy   #0
:copy       lda   (P_PTR1),y
            sta   (P_PTR2),y
            iny
            cpy   #40
            bne   :copy
            jsr   N8_AUX_OFF
            plp
            dec   P_IDX
            lda   P_IDX
            cmp   TTY_SCRL_FLR             ;dst>=floor: more
            bcs   :rowlp
            lda   TTY_SCRL_TOP             ;blank aux[TOP,TOP+N)
            sta   P_IDX
:clrlp      lda   P_IDX
            jsr   TTY_ROW_DST_A
            php
            sei
            jsr   N8_AUX_ON
            ldy   #0
            lda   #$A0
:clear      sta   (P_PTR2),y
            iny
            cpy   #40
            bne   :clear
            jsr   N8_AUX_OFF
            plp
            inc   P_IDX
            lda   P_IDX
            cmp   TTY_SCRL_FLR
            bcc   :clrlp
            rts

* N8_CLR_AUX -- aux half of TTY_CLR_BODY: all 24 rows blanked.
* Runs AFTER TTY_CLR_BD40's main half.
N8_CLR_AUX
            lda   #0
            sta   P_IDX
:rowlp      lda   P_IDX
            jsr   TTY_ROW_DST_A
            php
            sei
            jsr   N8_AUX_ON
            ldy   #0
            lda   #$A0
:clear      sta   (P_PTR2),y
            iny
            cpy   #40
            bne   :clear
            jsr   N8_AUX_OFF
            plp
            inc   P_IDX
            lda   P_IDX
            cmp   TTY_ROWS
            bcc   :rowlp
            rts

*---------------------------------------------------------------

*---------------------------------------------------------------
* THE ALTERNATE SCREEN -- ESC [ ? 1049 h / l, xterm's smcup/
* rmcup (docs/VI-ALTSCREEN.md; tty2.s TTY_CSI_PRIV dispatches).
* `h` parks the live console's MAIN screen in its alt-store
* (VCS_C4+console -- the console store's own movers take a
* table index, and the alt-stores are four more table entries)
* and clears the glass for the full-screen program; `l` blits
* it back and restores the ESC 7 cursor. On the UltraTerm the
* park SNAPSHOTS the live card VRAM into the store (VCS_UTSAVE,
* now the $CC00 window reads back -- 2026-09-10) then copies
* store->alt annex to annex; the restore is alt->store then the
* store's own card repaint (VCS_UTBLIT). (Before the readback it
* parked store->alt directly and relied on a write-through
* store.)
*
* OWNERSHIP: VCA_OWNER[console] = the pid that entered, 0 = not
* in alt-screen. It is the backstop's key (PRC_ALT_RST below):
* a program that dies in the alt-screen -- killed, ^C'd, or an
* error exit that skipped rmcup -- leaves its console restored
* by the kernel, the hazard class PRC_TMD_RST closes for a raw
* tty. Anyone's `l` restores (xterm: the terminal does not know
* who is writing); a second `h` while active is ignored.
*
* v1 SCOPE: the glass path. A REDIRECTED write (a background
* console, TTY_DSTBASE set) ignores both -- its "glass" is its
* store, and vi on a console nobody is looking at is not this
* brief's case. A vidmode geometry change while active clears
* the body; the parked image keeps its old shape.
*---------------------------------------------------------------
VCA_OWNER   ds VC_COUNT

VCA_ENTER   ldx   VC_LIVE
            lda   VCA_OWNER,x
            bne   :out                 ;already there: ignored
            lda   TTY_DSTBASE+1
            bne   :out                 ;redirected: v1 ignores
            lda   K_CURPID
            sta   VCA_OWNER,x
            jsr   TTY_CRSR_SAVE        ;DECSC -- ESC 7's stash
            lda   #0
            jsr   VCA_MOVE             ;park: glass -> alt
            jmp   TTY_CLR_SCRN         ;blank glass, home
:out        rts

VCA_EXIT    ldx   VC_LIVE
            lda   VCA_OWNER,x
            beq   :out                 ;not in alt: a no-op
            lda   TTY_DSTBASE+1
            bne   :out                 ;redirected: v1 ignores
            stz   VCA_OWNER,x
            stz   VC_OSHDW_LEN         ;what the pager painted
                                       ;in alt is not on the
                                       ;restored row: ^L must
                                       ;not replay it (man's
                                       ;own --More--(END)
                                       ;stacked beside every
                                       ;later prompt)
            lda   #1
            jsr   VCA_MOVE             ;restore: alt -> glass
            jmp   TTY_CRSR_RSTR        ;DECRC
:out        rts

*-- VCA_MOVE -- A = 0: park the live glass in its alt-store;
*-- A = 1: bring it back. ONE mover for both directions and
*-- both callers (`h`/`l`; the backstop goes through VCA_EXIT).
*-- The cursor glyph is hidden first (never parked, never
*-- painted over); VC_ROW is kept (VC_SWITCH's own bracket).
*-- 40/N8: VCS_BLIT_X against the alt index, direction as given.
*-- UltraTerm: park snapshots VRAM -> store (VCS_UTSAVE) then
*-- store -> alt; restore alt -> store then the card repaint.
*-- VCS_DIR is the direction cell (VCS_BLIT_X's own; it re-sets
*-- it). Clobbers A/X/Y and the movers' scratch.
VCA_MOVE    sta   VCS_DIR
            jsr   TTY_CRSR_HIDE
            lda   VC_ROW
            pha
            jsr   VCA_ALT_X            ;X = the alt-store index
            lda   TTY_BKND
            cmp   #TTY_BKUT
            beq   :ut
            lda   VCS_DIR
            jsr   VCS_BLIT_X           ;glass <-> alt
            bra   :done
:ut         lda   VCS_DIR
            bne   :utload
*-- park: the card's VRAM is the truth now (the store is no
*-- longer kept write-through), so SNAPSHOT the live glass into
*-- the store first (VCS_UTSAVE, the read-back), then copy the
*-- store to the alt. Was a bare store->alt, correct only while
*-- the store tracked every write (2026-09-10).
            ldx   VC_LIVE
            jsr   VCS_UTSAVE           ;VRAM -> store(live)
            jsr   VCA_ALT_X            ;X = alt index again
            txa                        ;store(live) -> alt
            tay
            ldx   VC_LIVE
            jsr   VCA_CP_XY
            bra   :done
:utload     ldy   VC_LIVE              ;restore: alt -> store,
            jsr   VCA_CP_XY            ;then repaint the card
            ldx   VC_LIVE              ;from its store
            lda   #1
            jsr   VCS_BLIT_X
:done       pla
            sta   VC_ROW
            rts

*-- VCA_ALT_X -- X = the live console's alt-store index.
VCA_ALT_X   lda   VC_LIVE
            clc
            adc   #VC_COUNT
            tax
            rts

*-- VCA_CP_XY -- store X -> store Y, the whole 24 x 80 image in
*-- one annex-to-annex BankCopy (VCS_SCROLL's shape). X/Y are
*-- VCS_CLO/CHI indexes: 0-3 consoles, 4-7 alt-stores.
VCA_CP_XY   lda   VCS_CLO,x
            sta   K_BC_SRCADDR
            lda   VCS_CHI,x
            sta   K_BC_SRCADDR+1
            lda   VCS_CLO,y
            sta   K_BC_DSTADDR
            lda   VCS_CHI,y
            sta   K_BC_DSTADDR+1
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            sta   K_BC_DSTKIND
            stz   K_BC_SRCBANK
            stz   K_BC_DSTBANK
            lda   #<VCA_STR_SIZE
            sta   K_BC_LEN
            lda   #>VCA_STR_SIZE
            sta   K_BC_LEN+1
            jmp   BankCopy

*---------------------------------------------------------------
* PRC_ALT_RST -- the alt-screen backstop, PRC_TMD_RST's twin
* (procspawn2.s). IN: A = a pid that is dying -- by force (kill,
* ^C) OR by its own exit: unlike the tty mode, an unrestored
* alt-screen has no legitimate set-then-run idiom, so the owner
* leaving IS the restore. Every console that pid holds goes
* back: the active one through VCA_EXIT itself, a background
* one by an annex copy alt -> store plus its parked cursor
* (VCA_SLTCRSR), so its next switch-in repaints the shell
* screen. Tick-context safe (PRC_INTR_SWP): no syscall is
* mid-flight there, so VC_LIVE is VC_ACTIVE and the redirect is
* off. Clobbers A, X, Y, K_BC_*. Ends in PRC_SEL_CRBNK --
* BankCopy's $C073 obligation, TTY_TMODE_STO's precedent.
*---------------------------------------------------------------
PRC_ALT_RST
            sta   VCA_PID
            ldx   #VC_COUNT-1
:scan       lda   VCA_OWNER,x
            cmp   VCA_PID
            bne   :next
            cpx   VC_ACTIVE
            bne   :bg
            phx
            jsr   VCA_EXIT             ;the live lane IS rmcup
            plx
            bra   :next
:bg         stz   VCA_OWNER,x
            phx
            txa
            tay                        ;Y = the console's store
            clc
            adc   #VC_COUNT
            tax                        ;X = its alt-store
            jsr   VCA_CP_XY
            plx
            phx
            jsr   VCA_SLTCRSR          ;and its parked cursor
            plx
:next       dex
            bpl   :scan
            jmp   PRC_SEL_CRBNK

*-- VCA_SLTCRSR -- DECRC for a BACKGROUND console X: its slot's
*-- VC_SAVE_ROW.. block over its VC_ROW.. block (the struct
*-- base) -- the whole VC_DSC_N-byte DECSC stash (rendition and
*-- character sets too, VT102 slice 6), one annex-to-annex
*-- BankCopy at a runtime offset (PRC_TTYGEO's idiom -- a label
*-- difference cannot cross the REL linker). The console's next
*-- write, the shell's reprompt, lands where vi was launched.
VCA_SLTCRSR lda   #<VC_SAVE_ROW
            sec
            sbc   #<VC_STATE
            clc
            adc   VC_SLT_LO,x
            sta   K_BC_SRCADDR
            lda   VC_SLT_HI,x
            adc   #0
            sta   K_BC_SRCADDR+1
            lda   VC_SLT_LO,x
            sta   K_BC_DSTADDR
            lda   VC_SLT_HI,x
            sta   K_BC_DSTADDR+1
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            sta   K_BC_DSTKIND
            stz   K_BC_SRCBANK
            stz   K_BC_DSTBANK
            lda   #VC_DSC_N
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jmp   BankCopy

VCA_PID     ds 1
