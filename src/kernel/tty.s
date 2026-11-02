*---------------------------------------------------------------
* tty.s -- TTY0/VC0 -- cooked line discipline, VT/ANSI output.
* Split out of process.s 2026-08-16 so each kernel module fits
* real Merlin's 41215-byte source buffer
* (learning:01M051EM2HQ3ZVJTR1W9P3G86J). The top-level image
* PUTs each module in order; Merlin-8 cannot nest PUT.
* Full design notes: K.PROCESS.TXT (docs/a2/)
*---------------------------------------------------------------

*-- TTY_ISL_N -- bytes of output between interrupt islands
*-- (TTY_ISLAND). 64 = ~10 ms of ordinary text at ~150 cycles
*-- a character; hoisted here (an equ used as an immediate must
*-- precede its use on Merlin-8).
TTY_ISL_N   equ   64


* This was embedded in process.s because process.s owns fd
* dispatch and a second-level `put` is invisible to the
* top-level test images -- Merlin-8 cannot nest PUT either.
* The note said it could split out "once the tree has a real
* kernel assembly unit".
* That is now: every top-level image PUTs the kernel modules in
* order, so this is a first-level module like any other.
*
* TTY_READ is scheduler-backed canonical input. The tick hook
* polls one key at a time, commits complete cooked lines, and
* wakes readers blocked on TTY_RD_CHAN. This is still
* deliberately small: no raw/noecho, no typeahead beyond the
* current line. Since 2026-08-23 the per-console state lives in
* the VC struct below (one active image + annex backing slots,
* VC_SWITCH to exchange); the ACTIVE console is the only one
* wired to the keyboard and to readers, so behaviour is
* unchanged until virtual consoles proper are ruled in scope.
*---------------------------------------------------------------

* -- TTY_OWBUF_SZ: TTY_WRITE's bulk staging chunk size
* -- (TTY_OUTBUF below). Defined here, ahead of TTY_WRITE's own
* -- first use -- real Merlin requires an EQU before its first
* -- reference (see ultraterm.s's header for the same rule).

* -- Active display backend (docs/CONSOLE.md sec 8/12). Set
* -- once by TTY_INIT; every dispatch in tty2.s tests TTY_BKND,
* -- and nothing re-probes hardware per character.
*-- TTY_BK40 moved to inc/tty.equ (2026-08-30) -- see
*-- that file; REL cannot export an equate.

TTY_INIT
            sta   CLR80STORE
            sta   PAGE2OFF
            sta   COL80OFF                 ;40-col display until
                                           ;a backend that wants
                                           ;more says so
            sta   HIRESOFF
            sta   TEXTMODEON
            sta   MIXEDOFF
            sta   ALTCHARSETON             ;own the char set, do
                                           ;not inherit ProDOS's
                                           ;-- inverse lowercase
                                           ;only exists in the
                                           ;alternate set

            ;-- Backend selection (docs/CONSOLE.md section 8 and
            ;-- 12; operator ruling 2026-09-03). TTY_BKND_REQ,
            ;-- set by the boot image BEFORE PRC_INIT: 0 = auto,
            ;-- 1 = force 40-column, 2 = force native 80. AUTO =
            ;-- THE BEST SURFACE PRESENT: UltraTerm HQ 80x24 if
            ;-- a card answers in slot 3, [a plain Videx 80-col
            ;-- card would go here -- no driver, no rig yet],
            ;-- else the built-in 80 columns. 40 is NEVER a
            ;-- default: this system needs aux memory, so 80 is
            ;-- always there. Test harnesses that assert 40-col
            ;-- screens pin it with req=1.
            lda   #40
            sta   TTY_CO_BOOT
            lda   TTY_BKND_REQ
            cmp   #2
            beq   :native80
            cmp   #1
            beq   :forty
            jsr   UT_DETECT
            bcs   :native80
            jsr   UT_INIT
            lda   #UT_COLS
            sta   TTY_CO_BOOT
            lda   #TTY_BKUT
            sta   TTY_BK_BOOT
            bra   :selected
:native80   jsr   N8_INIT                  ;display switch on;
                                           ;N8_INIT's TTY_COLS
                                           ;store is re-done by
                                           ;VC_RESET from the
                                           ;boot cells
            lda   #80
            sta   TTY_CO_BOOT
            lda   #TTY_BKN8
            sta   TTY_BK_BOOT
            bra   :selected
:forty      lda   #TTY_BK40
            sta   TTY_BK_BOOT
:selected   lda   TTY_BK_BOOT              ;the live struct IS
            sta   TTY_BKND                 ;console 0: VC_RESET
            lda   TTY_CO_BOOT              ;no longer copies the
            sta   TTY_COLS                 ;boot cells (a new
            lda   #24                      ;console inherits the
            sta   TTY_ROWS                 ;live mode, ruling
            stz   TTY_DISC                 ;2026-09-03)
            lda   #$FF
            sta   VC_OWNER                 ;no surface owned yet
            sta   VC_OWNER+1
            stz   VC_LIVE
            jsr   VC_RESET                 ;vc0's per-console
                                           ;fields (home to row
                                           ;0) -- BEFORE the
                                           ;clear: the clear
                                           ;reads TTY_ROWS and
                                           ;TTY_BKND, which are
                                           ;kernel-bss zeros
                                           ;until VC_RESET
                                           ;copies the boot
                                           ;cells in (finding V1
                                           ;finding 1: the old
                                           ;order cleared one
                                           ;row of a 0-row
                                           ;screen)
            jsr   TTY_CLR_BODY
            stz   VC_ACTIVE
            lda   #0                       ;console 0 owns the
            jsr   VC_TAKE_A                ;boot surface
            lda   #1                       ;bit0 = vc0 is live;
            sta   VC_INITED                ;vc1-3 are reset
                                           ;lazily on their
                                           ;first VC_SWITCH
            rts

TTY_READ
            lda   PRC_PARM+MLI_REQLO
            ora   PRC_PARM+MLI_REQHI
            bne   :want
            stz   PRC_PARM+MLI_TRANSLO
            stz   PRC_PARM+MLI_TRANSHI
            jsr   PCPO_MLIPARM
            rts
*-- A BACKGROUND CONSOLE'S READER BLOCKS, FULL STOP. Everything
*-- below this line reads VC_STATE -- the ACTIVE console's
*-- struct -- so a /dev/tty2 reader running it while console 1
*-- owns the glass would eat console 1's committed line and
*-- poll console 1's keyboard (review finding 2,
*-- 2026-08-31). Its line discipline runs only while its console
*-- is on the glass: sleep on the per-console channel and let
*-- the blocked-retry re-enter when TTY_WAKE_RDRS wakes it --
*-- which is per-active-console, so that is after a switch-in
*-- completes a line.
:want       lda   TTY_TARGET
            cmp   VC_ACTIVE
            bne   :block
            lda   VC_IN_POS
            cmp   VC_IN_LEN
            bcc   :buffered
            lda   VC_EOF_PEND
            beq   :poll
            stz   VC_EOF_PEND
            bra   :eof
:poll       jsr   TTY_POLL
*-- A hotkey switch may have landed in TTY_POLL. Re-evaluate
*-- ownership from the top if so: everything below reads
*-- VC_STATE, the ACTIVE console's struct, and this reader may
*-- no longer own it -- the same hazard the header above this
*-- routine describes.
            jsr   TTY_VC_PEND
            bcs   :want
            lda   VC_IN_POS
            cmp   VC_IN_LEN
            bcc   :buffered
            lda   VC_EOF_PEND
            beq   :block
            stz   VC_EOF_PEND
:eof        stz   PRC_TRANS
            jmp   :ret
*-- ONE CHANNEL PER CONSOLE. A reader on a console nobody is
*-- looking at must not wake on the FOREGROUND console's keys
*-- and eat them: there is one keyboard, and its bytes belong to
*-- whichever console is on the glass. Blocking on
*-- TTY_RD_CHAN+n means a background reader simply waits -- and
*-- wakes by itself the moment its console is switched to, with
*-- no extra bookkeeping, because that is when keys start
*-- arriving for it.
:block      clc
            lda   #TTY_RD_CHAN
            adc   TTY_TARGET
            jsr   PRC_BLCK_RTRY
            rts
:buffered   sec
            lda   VC_IN_LEN
            sbc   VC_IN_POS
            sta   P_COUNT                  ;available bytes in
                                           ;cooked line
            lda   PRC_PARM+MLI_REQHI
            bne   :capok
            lda   PRC_PARM+MLI_REQLO
            cmp   P_COUNT
            bcs   :capok
            sta   P_COUNT
* -- K3 (docs/PROCIO.md sec 3): bulk tty line copy. VC_INBUF is
* -- ordinary contiguous main memory (no ring, no wrap) so the
* -- committed line is always ONE BankCopy instead of a per-byte
* -- PWRPAR_BYTE loop. VC_IN_POS is only advanced AFTER a
* -- successful copy, so a bad caller buffer leaves it untouched
* -- -- the same end state the old byte-loop's explicit rollback
* -- produced, just never having moved it in the first place.
:capok      jsr   PRC_SEL_CRBNK
            sta   P_BANK
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            clc
            lda   #<VC_INBUF
            adc   VC_IN_POS
            sta   K_BC_SRCADDR
            lda   #>VC_INBUF
            adc   #0
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   PRC_PARM+MLI_BUFLO
            sta   K_BC_DSTADDR
            lda   PRC_PARM+MLI_BUFHI
            sta   K_BC_DSTADDR+1
            lda   P_BANK
            sta   K_BC_DSTBANK
            lda   P_COUNT
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :bcok
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:bcok       lda   P_COUNT
            sta   PRC_TRANS
            clc
            lda   VC_IN_POS
            adc   P_COUNT
            sta   VC_IN_POS
:done       lda   VC_IN_POS
            cmp   VC_IN_LEN
            bne   :ret
            stz   VC_IN_POS
            stz   VC_IN_LEN
:ret        lda   PRC_TRANS
            sta   PRC_PARM+MLI_TRANSLO
            stz   PRC_PARM+MLI_TRANSHI
            jsr   PCPO_MLIPARM
            rts

TTY_WRITE
            lda   PRC_PARM+MLI_REQLO
            ora   PRC_PARM+MLI_REQHI
            bne   :want
            stz   PRC_PARM+MLI_TRANSLO
            stz   PRC_PARM+MLI_TRANSHI
            jsr   PCPO_MLIPARM
            rts
:want       lda   PRC_PARM+MLI_REQHI
            beq   :lo
            lda   #$FF
            bra   :count
:lo         lda   PRC_PARM+MLI_REQLO
:count      sta   P_COUNT
            jsr   TTY_WR_ENTER
            jsr   TTY_CRSR_HIDE
            stz   PRC_TRANS
            lda   #1                 ;islands may open from
            sta   TTY_WR_BUSY        ;here to TTY_WR_LEAVE
*-- UltraTerm: claim the $C800 window ONCE for the whole write
*-- and hold it (UT_WHELD) so the per-cell UT_CLAIMs no-op. The
*-- syscall is masked end to end (ffpage.s), so nothing steals
*-- the window between here and TTY_WR_LEAVE, which clears the
*-- flag. Foreground glass only: a redirected (background) write
*-- touches no card. TTY_CRSR_HIDE above already did a real
*-- claim if it drew, so this is cheap either way.
            lda   TTY_BKND
            cmp   #TTY_BKUT
            bne   :noutw
            lda   TTY_DSTBASE+1
            bne   :noutw
            jsr   UT_CLAIM                  ;WHELD still 0: real
            lda   #1
            sta   UT_WHELD
:noutw
* -- Single-byte fast path (2026-08-20, found via check-play's
* -- type-ahead gate -- docs/PROCIO.md "Bulk TTY_WRITE" has the
* -- full account). BankCopy's fixed per-call overhead (80STORE
* -- save/restore, chunk-loop setup) is LARGER than a direct
* -- single-byte fetch -- measured, not assumed, after the first
* -- cut made every 1-byte PUTC call slower, not faster, and
* -- shifted the sh-prompt-vs-type-ahead race enough to flip
* -- check-play's ^L/prompt-redraw assertion. PUTC is ~92% of a
* -- program's own syscalls (sec 4), so this must not regress.
:chunklp    stz   TTY_JS_ON          ;no chunk staged
            sec
            lda   P_COUNT
            sbc   PRC_TRANS
            bne   :remain
            jmp   :done
:remain     cmp   #2
            bcs   :multi
* -- exactly one byte left: skip BankCopy/TTY_OUTBUF entirely.
            clc
            lda   PRC_PARM+MLI_BUFLO
            adc   PRC_TRANS
            sta   P_PTR1
            lda   PRC_PARM+MLI_BUFHI
            adc   #0
            sta   P_PTR1+1
            jsr   PRDPAR_BYTE
            bcc   :one_ok
            jmp   TTY_WR_LEAVE       ;EVERY exit leaves the
                                     ;redirect, error ones
                                     ;included -- a leaked
                                     ;TTY_DSTBASE sends every
                                     ;later write into a
                                     ;background console's store
                                     ;and the glass stops
                                     ;changing
:one_ok     jsr   TTY_SHDW_TAP
            lda   PRC_BYTE
            jsr   TTY_PUT_BYTE
            inc   PRC_TRANS
            bra   :chunklp
* -- Bulk fetch (docs/PROCIO.md "Bulk TTY_WRITE", 2026-08-20):
* -- ONE BankCopy pulls up to TTY_OWBUF_SZ bytes into
* -- TTY_OUTBUF, a kernel-side staging buffer in ordinary main
* -- memory, instead of the old loop's per-byte cross-bank
* -- fetch. Requests over TTY_OWBUF_SZ loop this chunk (the
* -- SAME shape K1 already uses for file reads over a chunk
* -- size, docs/PROCIO.md sec 3). The VT/escape parser below
* -- (TTY_SHDW_TAP/TTY_PUT_BYTE and everything they call) then
* -- runs entirely over TTY_OUTBUF -- pure main-memory access,
* -- no bank flip per byte. Parser state (VC_ESC_STATE/
* -- VC_CSI_ROW/VC_CSI_COL/VC_CSI_PARAM) lives in fixed cells
* -- this change never touches, so an escape sequence split
* -- across two write() calls, or across a chunk boundary
* -- inside ONE write() call, still resumes exactly as before.
* -- Chunk size lives in P_PIPE and the chunk-local TTY_OUTBUF
* -- index in P_FD, NOT P_TMP2/P_IDX/X -- TTY_PUT_BYTE's escape
* -- parser (TTY_CSI_BYTE) and TTY_SCROLL both clobber P_TMP/
* -- P_TMP2/P_IDX/P_PTR1/P_PTR2/X, and :wrlp below calls
* -- TTY_PUT_BYTE every iteration. P_PIPE/P_FD are free here --
* -- grepped, neither is touched by tty2.s, bankcopy.s,
* -- PRC_SEL_CRBNK, or COPYIN_ENTRY/COPYOUT_ENTRY.
:multi      cmp   #TTY_OWBUF_SZ+1
            bcc   :havesz
            lda   #TTY_OWBUF_SZ
:havesz     sta   P_PIPE                   ;this chunk's size
            jsr   PRC_SEL_CRBNK
            sta   P_BANK
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            clc
            lda   PRC_PARM+MLI_BUFLO
            adc   PRC_TRANS
            sta   K_BC_SRCADDR
            lda   PRC_PARM+MLI_BUFHI
            adc   #0
            sta   K_BC_SRCADDR+1
            lda   P_BANK
            sta   K_BC_SRCBANK
            lda   #BC_KIND_MAIN
            sta   K_BC_DSTKIND
            lda   #<TTY_OUTBUF
            sta   K_BC_DSTADDR
            lda   #>TTY_OUTBUF
            sta   K_BC_DSTADDR+1
            stz   K_BC_DSTBANK
            lda   P_PIPE
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :bcok
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            jmp   TTY_WR_LEAVE       ;see the note above --
                                     ;this exit leaks the
                                     ;redirect too
* -- Same failure shape K2 chose for pipes (docs/PROCIO.md sec
* -- 10): a bad caller pointer fails the WHOLE call before any
* -- byte in THIS chunk reaches the screen, rather than the old
* -- per-byte loop's partial-echo-then-fail -- a strictly
* -- cleaner failure state for a case no gate exercises either
* -- way. Bytes from any PRIOR chunk are already on screen and
* -- already counted in PRC_TRANS, same as a short write.
:bcok       stz   P_FD
            lda   #TTY_ISL_N         ;first island after
            sta   TTY_ISLAT          ;TTY_ISL_N bytes
            lda   #1
            sta   TTY_JS_ON          ;chunk staged: the
                                     ;newline path may look
                                     ;ahead (TTY_JSCROLL)
:wrlp       lda   P_FD
            cmp   P_PIPE
            bne   :more0
            jsr   TTY_ISLAND         ;and one per chunk edge
            jmp   :chunklp
:more0      cmp   TTY_ISLAT          ;TTY_ISL_N bytes since
            bcc   :more              ;the last island: open
            jsr   TTY_ISLAND         ;one
* -- foreground text: render a whole printable run in one
* -- backend span (it moves P_FD/PRC_TRANS); else per-byte.
:more       jsr   TTY_RUN
            bcc   :wrlp
            ldx   P_FD
            lda   TTY_OUTBUF,x
            sta   PRC_BYTE
            jsr   TTY_SHDW_TAP              ;record for ^L
                                            ;replay -- PROCESS
                                            ;WRITE path only,
                                            ;see TTY_SHDW_TAP's
                                            ;header
            lda   PRC_BYTE
            jsr   TTY_PUT_BYTE
            inc   P_FD
            inc   PRC_TRANS
            bra   :wrlp
:done       jsr   TTY_WR_LEAVE
            lda   PRC_TRANS
            sta   PRC_PARM+MLI_TRANSLO
            stz   PRC_PARM+MLI_TRANSHI
            jsr   PCPO_MLIPARM
*-- a ^C/^Z that arrived in an island runs now, the write done
*-- and the glass free (tty3.s TTY_KEYIN's :defer)
            lda   TTY_CTL_PEND
            beq   :out
            stz   TTY_CTL_PEND
            cmp   #$83
            bne   :stop
            jmp   TTY_INTR
:stop       jmp   TTY_STOP
:out        rts

*---------------------------------------------------------------
* TTY_ISLAND -- an INTERRUPT ISLAND inside a tty WRITE (review
* AC1 stage 1, 2026-09-13; docs/CONSOLE-LATENCY.md sec 8). The
* syscall is masked end to end (ffpage.s), so a long write --
* a vi half-page repaint, 72-119 ms measured -- held the tick,
* the keyboard latch and the serial line for its whole length.
* Every TTY_ISL_N bytes of TTY_OUTBUF, and at each chunk edge,
* the write opens interrupts for two instructions: a pending
* tick is taken THEN. The kernel-context IRQ shim (timer.s
* MAIN_IRQ_SHIM) acks the timer, counts the tick and runs the
* tick hook -- TTY_POLL captures the key into the ring but
* does not cook (TTY_WR_BUSY), and a ^C/^Z is parked for the
* write's end (TTY_CTL_PEND); SER_POLL drains the ACIA -- and
* never calls SCH_TICK, so no process switch can happen here:
* this is bounded interrupt SERVICE, not preemption (review:
* "do not treat a bare CLI inside an existing loop as
* preemption support" -- it is not treated as one). The
* renderer's state is between bytes (parser state in VC cells,
* no span in flight, 80STORE at rest); the shim's exit hands
* $C800 to the SmartPort slot, so a held card window is
* re-claimed (UT_RGN_CLAIM). Cost: one compare per :wrlp
* iteration and ~30 cycles per island. Bound: one slice's
* render, or one primitive (a scroll) -- whichever is longer.
*---------------------------------------------------------------
TTY_ISLAND  clc
            lda   P_FD
            adc   #TTY_ISL_N
            sta   TTY_ISLAT
*-- The write loop's own zero-page state (chunk index and size,
*-- caller bank, request count) is saved across the window: the
*-- tick hook (tty.s TTY_TICK) saves what the READ loop had live
*-- when it was written -- P_PTR1/2, P_IDX, P_TMP/2, PRC_BYTE --
*-- not these four, and the serial poll's read helpers use
*-- P_COUNT. A tick clobbering P_FD mid-write would end or loop
*-- the chunk: the shape of the one box-only red the first
*-- island build produced (e2e-term suspend_echo, 2026-09-13).
            lda   P_FD
            pha
            lda   P_PIPE
            pha
            lda   P_BANK
            pha
            lda   P_COUNT
            pha
            cli
            nop                      ;a pending IRQ is taken
            nop                      ;after the instruction
            sei                      ;following CLI
            pla
            sta   P_COUNT
            pla
            sta   P_BANK
            pla
            sta   P_PIPE
            pla
            sta   P_FD
            lda   UT_WHELD           ;card window held: the
            beq   :out               ;tick's ROM handler took
            jmp   UT_RGN_CLAIM       ;$C800 -- take it back
:out        rts

*-- TTY_WR_ENTER / TTY_WR_LEAVE / TTY_SET_DSTB moved to tty8.s
*-- (2026-09-03, as's source window: this file had become the
*-- kernel's largest put).

* See K.TTY.TXT: "TTY_SHDW_TAP -- record process WRITE-path"
*
* THE SHADOW'S RULE (KFIX9, docs/KFIX9-NOTES.md sec 2): the
* shadow is the printable run since the glass last stopped
* being an APPEND of it. It ends at a CR (TT9_CR), a line
* break (LF/VT/FF, ESC D, ESC E, ESC M: TT9_LBRK, TT9_NEL,
* TT9_RI), a cursor restore or a reset (ESC 8, ESC c) and any
* CSI final that cancels a pending wrap (TTY_CSI_BYTE
* :not_priv: cursor motion, erase, edit; SGR and the mode
* families keep it). A WRAP does not end it (TT9_IND, from
* TTY_NEWLINE): one logical line, and the replay re-wraps it
* the same way. check-play's ^L rows pin each.
TTY_SHDW_TAP
            lda   VC_ESC_STATE
            bne   :done                    ;mid-escape: never
                                           ;record
            lda   PRC_BYTE               ;a CR resets the shadow
            cmp   #$A0                   ;in TT9_CR, on its way
            bcc   :done                    ;control byte: not
                                           ;printable here
            cmp   #$FF
            bcs   :done
            ldx   VC_OSHDW_LEN
            cpx   #80
            bcs   :done                    ;at cap: stop
                                           ;recording until the
                                           ;next reset
            sta   VC_OUTSHDW,x
            inc   VC_OSHDW_LEN
:done       rts

* See K.TTY.TXT: "TTY_TICK -- the K_TICK_HOOK entry point."
TTY_TICK
            lda   PRC_BYTE
            pha
            lda   P_PTR1
            pha
            lda   P_PTR1+1
            pha
            lda   P_PTR2
            pha
            lda   P_PTR2+1
            pha
            lda   P_IDX
            pha
            lda   P_TMP
            pha
            lda   P_TMP2
            pha
            lda   TTY_FLSH    ;visual bell (tty9.s): count the
            cmp   #2          ;inverted page's ticks down and
            bcc   :nf1        ;restore BEFORE the poll, so no
            beq   :rst        ;cook, echo or cursor paint sees
            dec   TTY_FLSH    ;it inverted
            bra   :nf1
:rst        jsr   TTY_FLTOGL
            stz   TTY_FLSH
:nf1        jsr   TTY_POLL
            jsr   SER_POLL    ;ser.s: drain the 6551 RDRF byte,
                              ;if the SSC was detected at boot
            lda   K_SLP_ARM   ;SLEEP-1: a sleep deadline
            beq   :nosl       ;armed? (one load a tick if not)
            jsr   SLP_TICK
:nosl
            lda   TTY_FLSH    ;armed by a BEL? invert AFTER the
            cmp   #1          ;poll, so its own echo is drawn
            bne   :nf2        ;first and flashes with the page
            jsr   TTY_FLTOGL
            lda   #4          ;ticks to show (tty9.s)
            sta   TTY_FLSH
:nf2
            pla
            sta   P_TMP2
            pla
            sta   P_TMP
            pla
            sta   P_IDX
            pla
            sta   P_PTR2+1
            pla
            sta   P_PTR2
            pla
            sta   P_PTR1+1
            pla
            sta   P_PTR1
            pla
            sta   PRC_BYTE
            rts

*---------------------------------------------------------------
* SLP_TICK -- the tick hook's half of SYS_SLPUNTIL (procfile3.s
* PRC_SLPUNTIL has the design). Called from TTY_TICK only
* while K_SLP_ARM is set. If now has reached the deadline
* (signed modular: the sign of now - K_SLP_DL, valid under 2^31
* ticks), disarm and wake SLP_CHAN; every sleeper reruns.
*
* INTERRUPT CONTEXT, and both rules apply: this is reached from
* MAIN_IRQ_SHIM inside the MLI and TTY windows as well as from
* SCH_TICK, so it touches no cell TTY_TICK has not already saved
* and writes only K_SLP_ARM beyond what SCH_WAKEUP writes; and
* SCH_WAKEUP leaves BANKSEL at 0, so the interrupted process's
* bank is restored AFTER it, unconditionally -- the same pair
* as TTY_WAKE_RDRS (learning 01M28001EKW3KDXM109P97AJHH).
*---------------------------------------------------------------
SLP_TICK    sec
            lda   K_VBL_TICKS
            sbc   K_SLP_DL
            lda   K_VBL_TICKS+1
            sbc   K_SLP_DL+1
            lda   K_VBL_TICKS+2
            sbc   K_SLP_DL+2
            lda   K_VBL_TICKS+3
            sbc   K_SLP_DL+3
            bmi   :notyet
            stz   K_SLP_ARM
            lda   #SLP_CHAN
            jsr   SCH_WAKEUP
            jsr   PRC_SEL_CRBNK
:notyet     rts

*---------------------------------------------------------------
* Per-console state -- the VC struct (docs/CONSOLE.md sec 7,
* sec 12's queue item 2, 2026-08-23). ONE contiguous block: the
* ACTIVE console's image. Every tty routine reads and writes
* these cells directly -- no per-access indexing, so the hot
* paths cost exactly what the old flat cells cost. Switching
* consoles is a block save/load against the per-console backing
* slots in the ANNEX (aux bank 0, VC_SLOT_ADDR below), the same
* context-switch shape the scheduler already uses for banks.
*
* ADDING A FIELD: put it inside this block, between VC_STATE
* and VC_ST_END. VC_ST_SIZE is derived, so the save/load covers
* it automatically; a per-console field defined OUTSIDE the
* block silently stays global across consoles -- exactly the
* debt this block retires. check-vc's roundtrip is checksummed
* over the whole struct, so a mis-sized copy fails there.
*
* The FLAT cells these replace still sit, dead, in process.s
* lines 219-244 (S3 cannot edit that file -- stream ownership,
* docs/PLAN.md sec 3). Deleting them at merge is S1/S8's call;
* nothing references them any more.
*
* NOT per-console: TTY_COLS (backend width -- the display is a
* hardware property until per-VC geometry exists), TTY_OUTBUF
* (pure staging scratch), TTY_BKND (the active backend).
*---------------------------------------------------------------
VC_STATE                       ;struct base -- ACTIVE console
*-- The DECSC BLOCK (VT102 slice 6, VT7, 2026-09-12): the
*-- VC_DSC_N cells ESC 7 saves and ESC 8 restores -- position,
*-- rendition, the pending wrap (DEC hardware restores it) and
*-- the character-set state -- kept CONTIGUOUS and in the SAME
*-- ORDER as VC_SAVE_ROW.. below, so the save, the restore and
*-- the background-console restore (tty5.s VCA_SLTCRSR) are each
*-- one VC_DSC_N-byte copy. VC_ROW stays at offset 0
*-- (VCA_SLTCRSR aims its copy at the struct base).
VC_ROW      ds 1
VC_COL      ds 1
VC_ATTR     ds 1
*-- xenl -- the deferred-wrap pending flag (docs/CONSOLE-
*-- VT102.md sec 2/4, VT102 slice 3): set in TTY_PUT_PRNTB the
*-- instant a printable lands in the last column (instead of
*-- wrapping immediately); consumed at the top of TTY_PUT_PRNTB
*-- by the NEXT printable. Cancelled by the operations that
*-- cancel it on DEC hardware (slice 6, VT4): CR, IND/LF/
*-- NEL/RI, BS, and every CSI final except SGR and the mode
*-- families -- NOT by SGR, BEL, NUL, SO/SI, HT or DECSC. ESC c
*-- and TTY_INIT (VC_RESET) clear it.
VC_XENL     ds 1
*-- Character sets (VT102 slice 5, docs/CONSOLE-VT102.md):
*-- VC_G0/VC_G1 = the designated set (0 ASCII, 1 DEC special
*-- graphics), VC_ACS = the ACTIVE set's kind (SI->G0, SO->G1);
*-- VC_GL = which set is invoked (0 G0 after SI, 1 G1 after SO).
*-- VC_SCS (below, outside the block) = the pending designator
*-- introducer while an ESC ( / ESC ) is swallowing its byte.
VC_G0       ds 1
VC_GL       ds 1
VC_G1       ds 1
VC_ACS      ds 1
VC_IN_LEN   ds 1
VC_IN_POS   ds 1
VC_EDIT_LEN ds 1
VC_CRSR_SAV ds 1
VC_CRSR_VIS ds 1
VC_EOF_PEND ds 1
VC_ESC_STATE ds 1
*-- The four CSI parameters are CONTIGUOUS, then the count
*-- (perf slice 2, 2026-09-12): the digit accumulator, the reset
*-- and SGR's apply all index VC_CSI_ROW,x by the parameter
*-- number instead of carrying one copy per cell (-70 B, the
*-- bytes MAUXEXPR needed back). P3/P4 used to sit by TTY_BKND.
VC_CSI_ROW  ds 1
VC_CSI_COL  ds 1
VC_CSI_P3   ds 1               ;third CSI parameter (the mode
                               ;escape's discipline field)
VC_CSI_P4   ds 1               ;fourth CSI parameter (the mode
                               ;escape's SURFACE, VIDMODE V2.0:
                               ;0 derive, 1 motherboard, 2 card)
VC_CSI_PARAM ds 1              ;which parameter is accumulating
                               ;(0-3, saturates)
*-- ESC 7 / ESC 8 stash: the DECSC block's mirror, same order
*-- (see VC_ROW). Must not share the VC_CSI_* accumulators
*-- (TTY_CSI_START zeroes those per CSI). Voided (row/col
*-- homed) by a geometry change, tty7.s -- review finding VT6.
VC_SAVE_ROW ds 1
VC_SAVE_COL ds 1
VC_SAVE_ATTR ds 1
VC_SAVE_XENL ds 1
VC_SAVE_G0  ds 1
VC_SAVE_GL  ds 1
VC_SAVE_G1  ds 1
VC_SAVE_ACS ds 1
VC_RAW_HD   ds 1               ;raw type-ahead ring indexes --
VC_RAW_TL   ds 1               ;hd==tl empty; a full ring drops
                               ;the NEWEST key (2026-08-18)
VC_OSHDW_LEN ds 1
*-- Cooked-mode CSI state: 0 idle, 1 saw ESC, 2 saw ESC [.
*-- TTY_KEYIN turns the arrows into ESC [ A..D, and without this
*-- the editor would treat `[` and the final letter as ordinary
*-- printables and INSERT them -- left-arrow typing "[D" into
*-- your line, which is worse than the ^U it replaced.
VC_KESC     ds 1
*-- Per-console MODE (docs/VIDMODE.md sec 1, 2026-09-01):
*-- geometry, backend and discipline travel with the console.
*-- Sec 14's old "NOT per-console" ruling on TTY_COLS/TTY_BKND
*-- is hereby removed -- that was "until per-VC geometry
*-- exists", and this is it existing.
TTY_COLS    ds 1               ;this console's width
TTY_ROWS    ds 1               ;this console's height (24 until
                               ;VIDMODE V2's tall modes)
TTY_BKND    ds 1               ;this console's backend id
TTY_DISC    ds 1               ;0 = VT discipline, 1 = APPLE
                               ;(dispatch lands in stage D1)
*-- (VC_CSI_P3/P4 moved up beside VC_CSI_ROW/COL, 2026-09-12)
*-- Terminal mode (docs stty seed, 2026-09-02): TMD_ICANON /
*-- TMD_ECHO (inc/sc.proc.equ), set via SYS_TTYMODE
*-- (tty7.s PRC_TTYMODE). Default TMD_ICANON+TMD_ECHO (VC_RESET,
*-- tty3.s). ^C stays a signal in every mode -- TTY_INTR
*-- (tty3.s) is upstream of the ring and never reads this byte.
VC_TMODE    ds 1
*-- DECSTBM scroll-region margins (docs/CONSOLE-VT102.md sec
*-- 2/4,
*-- VT102 slice 1). 0-based, inclusive; default 0/TTY_ROWS-1
*-- (the
*-- whole screen) -- re-derived by
*-- TTY_INIT/VC_RESET/TTY_CSI_MODE
*-- whenever TTY_ROWS is (re)established, and by ESC c. See
*-- tty9.s TT9_MRESET.
VC_MTOP     ds 1
VC_MBOT     ds 1
*-- DECCKM (docs/CONSOLE-VT102.md sec 2): application cursor
*-- keys.
*-- Set/cleared by CSI ?1h/l (tty2.s TTY_CSI_PRIV -> tty9.s
*-- TT9_CKM); read by TTY_KEYIN's arrow framing (tty3.s). Reset
*-- by
*-- ESC c.
VC_DECCKM   ds 1
*-- IRM (docs/CONSOLE-VT102.md sec 2/4, VT102 slice 2): smir/
*-- rmir (CSI 4 h/l, tty2.s CSI_CH -> TT9_MODE). Set/clear only;
*-- the shift itself is TT9_ICHSH, called from TTY_PUT_PRNTB.
*-- Reset by ESC c and TTY_INIT (VC_RESET).
VC_IRM      ds 1
*-- DECAWM (smam/rmam, CSI ?7 h/l -> tty9.s TT9_AWM; VT102 slice
*-- 7, 2026-09-12, the remaining debt): 1 = autowrap ON (the
*-- default, what the vt102 terminfo entry's `am` assumes), 0 =
*-- a printable at the last column overwrites it and the cursor
*-- stays -- no pending wrap. Read by TTY_PUT_PRNTB (tty2.s) and
*-- TTY_RUN (procfd.s), the two renderers. Reset ON by ESC c and
*-- VC_RESET.
VC_AWM      ds 1
VC_ATTRMODE ds 1               ;what the emphasis bit MEANS on
                               ;the card: 0 inverse (default),
                               ;1 highlight (ESC [ ? 3001 h).
                               ;outside the DECSC run
*-- VC_SCS: the pending SCS designator introducer ('(' or ')')
*-- while an ESC ( / ESC ) is swallowing its one byte. The rest
*-- of the character-set state is in the DECSC block (VC_G0..).
VC_SCS      ds 1
*-- Readline-lite (docs/CONSOLE.md sec 4b, 2026-08-31).
VC_EDIT_POS ds 1               ;cursor within the edit buffer,
                               ;0..VC_EDIT_LEN
VC_HIST_N   ds 1               ;history entries stored, 0..8
VC_HIST_W   ds 1               ;ring write index (next slot)
VC_HIST_CUR ds 1               ;walk cursor, 0 = newest;
                               ;$FF = not walking
VC_INBUF    ds 128
VC_RAW_BUF  ds 64
VC_OUTSHDW  ds 80              ;^L prompt-replay shadow -- see
                               ;TTY_SHDW_TAP for the recording
                               ;rule
VC_ST_END
*-- VC_ST_SIZE IS DECLARED IN inc/tty.equ, NOT DERIVED HERE
*-- (S9 L4, 2026-08-30). It is the one cross-module tty constant
*-- that cannot simply be hoisted: its value is the DIFFERENCE
*-- OF
*-- TWO LABELS in this file, and Merlin-8's ENT exports code
*-- labels only -- an equate cannot cross the linker, and a
*-- label-derived one cannot be moved to a put file either. So
*-- the number is declared where every module can see it and the
*-- derivation becomes an ASSERTION: this `err` fails the
*-- assembly the moment the struct's real extent stops matching
*-- the declaration, which is the same protection the derived
*-- form gave and is checked in both assemblers.
            err   VC_ST_END-VC_STATE-VC_ST_SIZE


*---------------------------------------------------------------
* Per-console backing slots -- ANNEX-resident (aux bank 0), the
* cwd-table/LZ-path precedent. THE ADDRESS AND THE BUDGET LIVE
* IN inc/mm.annex.equ (VC_SLOT_ADDR / VC_SLOT_RESV) --
* the file that owns the annex map -- not here. Zero bytes of
* kernel image; reached only through BankCopy (bank 0), which
* owns the 80STORE bracket and the RAMRD/RAMWRT discipline.
* If VC_ST_SIZE or VC_COUNT grows past VC_SLOT_RESV, the
* reservation in mm.annex.equ is renegotiated FIRST.
*---------------------------------------------------------------
VC_SLOT0    equ VC_SLOT_ADDR
VC_SLOT1    equ VC_SLOT0+VC_ST_SIZE
VC_SLOT2    equ VC_SLOT1+VC_ST_SIZE
VC_SLOT3    equ VC_SLOT2+VC_ST_SIZE

*-- Boot-probe results: what TTY_INIT decided the MACHINE has.
*-- Every cold console inherits these (VC_RESET); the live
*-- per-console cells are in the VC struct above.
TTY_BK_BOOT ds 1
TTY_CO_BOOT ds 1
TTY_BKND_REQ ds 1              ;boot-image request, read once
                               ;by TTY_INIT: 0 auto, 1 force
                               ;40-col, 2 force native 80-col.
                               ;ds = image default 0 = auto
VC_ACTIVE   ds 1               ;which console owns VC_STATE
*-- ROUTING (docs/CONSOLE.md sec 13). TTY_TARGET is the console
*-- the CURRENT syscall is for, set from the fd's device handle
*-- by PRC_READ/PRC_WRITE -- which used to validate the handle
*-- and then throw it away. TTY_DSTBASE redirects the renderer
*-- into that console's stored screen when it is not the one on
*-- the glass; zero means "the glass", which is the normal case
*-- and costs one test. TTY_SVBANK is the caller's bank, saved
*-- once per write so the per-byte annex bracket can put it back
*-- without re-reading a PCB.
TTY_TARGET  ds 1
TTY_DSTBASE ds 2
TTY_SVBANK  ds 1
*-- TTY_JS_ON: 1 while TTY_WRITE's chunk loop is feeding
*-- TTY_OUTBUF[P_FD..P_PIPE) through the parser -- the only time
*-- TTY_JS_COUNT (tty4.s) may look ahead in it. TTY_SCRL_N: rows
*-- for the next TTY_SCROLL (1..TTY_ROWS-1), set by TTY_JSCROLL.
TTY_JS_ON   ds 1
TTY_SCRL_N  ds 1
*-- TTY_SCRL_TOP: top row of the region a scroll moves. VC_MTOP
*-- for whole-region SU/SD and the off-the-bottom jump scroll
*-- (VT102 slice 1, DECSTBM -- was hardcoded 0 before margins
*-- existed); the cursor row for TTY_CSI_IL/DL (ESC[nL / ESC[nM
*-- -- the editor insert-line / delete-line a fast vi uses for
*-- o/O/dd/p in place of repainting from the cursor, VI-DESIGN
*-- sec 2.2), bounded to VC_MBOT now rather than the screen
*-- bottom. Set by tty9.s TT9_SCLAMP (SU/SD) and TT9_RGN
*-- (IL/DL).
*-- TTY_SCRL_FLR = TOP+N, the reverse (down) loop's floor +
*-- blank
*-- end, computed once per pass to keep it off the per-row
*-- compare.
TTY_SCRL_TOP ds 1
TTY_SCRL_FLR ds 1
*-- TTY_SCRL_BOT (VT102 slice 1, DECSTBM): EXCLUSIVE bottom
*-- bound
*-- for the current scroll -- every scroll/blank loop's row
*-- bound,
*-- the same role TTY_ROWS played before margins existed (and
*-- VC_STR_ROWS for the store movers). Default TTY_ROWS
*-- (VC_MBOT+
*-- 1, whole screen); set from the margins by tty9.s TT9_SCLAMP/
*-- TT9_RGN/TTY_JSCROLL/TT9_RI before every scroll call. NOT
*-- per-console -- transient like TTY_SCRL_N/TOP, dead between
*-- calls.
TTY_SCRL_BOT ds 1
*-- VC_SW_PEND: console (ONE-based, 0 = none) a mid-redirect
*-- ESC [ n z asked to switch to -- TTY_CSI_VT parks it here
*-- and TTY_WR_LEAVE performs it after restoring the structs.
*-- GLOBAL, not per-console: it is about the glass.
VC_SW_PEND  ds 1
VC_INITED   ds 1               ;bit n set = console n has real
                               ;state (slot or active image); a
                               ;clear bit means first switch-in
                               ;runs VC_RESET instead of loading
                               ;a never-written slot
VC_TARGET   ds 1               ;VC_SWITCH scratch
*-- SURFACES (VIDMODE V2.1, operator ruling 2026-09-03): the
*-- motherboard and the card are two independent glasses.
*-- VC_OWNER[0]/[1] = the console whose image is on each ($FF
*-- none). The owner writes to its glass even from the
*-- background; everyone else writes to its store. VC_LIVE =
*-- the console whose struct is in VC_STATE right now (VC_ACTIVE
*-- except inside a background write). TTY_WR_SWAP = 1 while a
*-- background write has the structs swapped.
VC_OWNER    ds 2
VC_LIVE     ds 1
TTY_WR_SWAP ds 1

VC_SLT_LO   dfb <VC_SLOT0,<VC_SLOT1
            dfb <VC_SLOT2,<VC_SLOT3
VC_SLT_HI   dfb >VC_SLOT0,>VC_SLOT1
            dfb >VC_SLOT2,>VC_SLOT3

*---------------------------------------------------------------
