*---------------------------------------------------------------
* timer.s -- probed timer driver (task #6, docs/SCHED.md,
* docs/TASKS.md #6 post-review amendment A8).
* Full design notes: K.TIMER.TXT (docs/a2/)
*---------------------------------------------------------------

*-- THE COUNTERS MOVED TO src/kernel/sched.s ON 2026-08-25,
*-- and the driver stayed here. SYS_TICK made them shared
*-- state: kdisp.s's dispatch table is linked by 29 kernel
*-- harnesses and timer.s by FOUR, so a PRC_TICK that reads
*-- K_TIMER_MODE could not assemble anywhere the driver is
*-- absent. Declaring them beside K_CURPID/K_QUANTUM -- the
*-- scheduler's own notion of time, which K_VBL_TICKS already
*-- was -- costs nothing and makes "no timer driver linked"
*-- report as mode 0 (unprobed) rather than fail to build.
*-- The driver, the probe and the three ISRs are all still
*-- here; only the five bytes moved.

* -- CORRECTED 2026-08-25: this said "(mouse mode only)" and
* -- had since 2026-08-18. ALL THREE interrupt paths count:
* -- TIMER_ISR (mouse PIA), TIMER_ISR_MB (Mockingboard 6522 T1)
* -- and MAIN_IRQ_SHIM (the hosted-mode $03FE landing pad).
* -- Grep `inc K_VBL_TICKS` -- three sites, one per path.
* --
* -- WHAT IS TRUE, AND IS THE PART A CONSUMER MUST HANDLE:
* -- TIMER_MD_COOP (the probe's last resort, :nomb below) ARMS
* -- NO HARDWARE SOURCE AT ALL, so in that mode this counter
* -- NEVER ADVANCES. It is not slow; it is frozen. Any future
* -- SYS_TICK must therefore report the MODE alongside the
* -- count, and anything built on elapsed time -- `sleep`,
* -- `time` -- must REFUSE LOUDLY in coop mode rather than
* -- spin on a counter that will never change. That is the
* -- same shape `date` already uses for a machine with no
* -- readable clock, and `df` for free blocks it cannot reach.
* -- The reachable case is not exotic: a //e with neither an
* -- AppleMouse nor a Mockingboard lands here.

TMR_MD_MOUSE equ  1
TIMER_MODE_MB    equ  2

* -- AppleMouse II PIA registers (slot 5 -- verilogapple's
* default machine, -- learning:01KZXDQCQF2FZMDQ59FVZ5D7T4; base
* = $C080 | (slot<<4), the -- classic Apple II "$C0n0" device-
* select convention, n = 8+slot as a -- hex digit -- promoted
* verbatim from src/test/syscalltest.s). --
MOUSE_SLOT  equ   5
* -- merlin32 note: literal values below, not a `<<`-shift
* expression -- -- an earlier draft wrote
* `$C080+(MOUSE_SLOT<<4)+0` and merlin32 could -- not parse it
* ("Can't find format for element '(5'"); computed once -- by
* hand instead ($C080 | (slot<<4), slot=5 -> $C0D0). --

* -- Mockingboard 6522 VIA (slot 4 -- verilogapple's default
* machine, -- opt-in per learning:01KZXDQCQF2FZMDQ59FVZ5D7T4).
* CORRECTED 2026-08-18: the Mockingboard decodes its VIAs in
* the $Cn00 SLOT-ROM space ($C400-$C4FF for slot 4, VIA 1 at
* +$00, VIA 2 at +$80), NOT the $C080|(slot<<4) device-select
* convention the first draft borrowed from the mouse PIA. The
* wrong base went unnoticed because the probe was
* presence-only, single-value ($FF readback -- which floating
* bus happily returns), and verilogapple's default machine has
* a mouse in slot 5 that always wins the probe chain first.
* MAME exposed all three layers at once: no mouse ROM, so the
* MB tier actually ran, false-positived at $C0C2, and armed
* nothing -- leaving a tickless scheduler starving a runnable
* shell. Requires INTCXROM off (the kernel's canonical state)
* so $C4xx reaches the card. --
MB_SLOT     equ   4
MB_T1CL     equ   $C404        ;T1 counter low: READ = ack T1
                               ;IRQ (clears IFR6); WRITE = T1
                               ;latch low
MB_T1CH     equ   $C405        ;T1 counter high: WRITE loads
                               ;latch->counter, clears IFR6,
                               ;starts the timer
MB_T1LL     equ   $C406        ;T1 latch low (readable -- the
                               ;probe's echo register)
MB_ACR      equ   $C40B        ;aux control: bit6 = T1
                               ;continuous (free-run)
MB_IER      equ   $C40E        ;interrupt enable: write $C0 =
                               ;set-enable T1
* 1.0227 MHz phi0 / 60 Hz = 17045 ($4295) cycles/tick -- the
* same nominal rate as the mouse VBL tier, so K_VBL_TICKS rate
* checks hold in either mode.
MB_T1_LO    equ   $95
MB_T1_HI    equ   $42
SP_IOSEL    equ   $C700        ;boot disk slot's I/O-SELECT
                               ;page -- reading it re-claims
                               ;$C800 for the disk card (slot 7
                               ;by maux convention, same as the
                               ;multiblock loader's SP_INIT)

*---------------------------------------------------------------
* TIMER_PROBE -- entry point, called once at boot (after
* SCH_INIT, per docs/SCHED.md's boot sequence). Never returns
* without K_TIMER_MODE set to a real, reported outcome -- the
* "loud, not silent" requirement.
*---------------------------------------------------------------
TIMER_PROBE lda   #<TMR_QUIESCE           ;PRC_HALT's "there IS
            sta   K_HALT_TMR              ;a timer here" answer
            lda   #>TMR_QUIESCE           ;-- see procfile3.s
            sta   K_HALT_TMR+1
            lda   #<TMR_REARM             ;`bye`'s return-path
            sta   K_BYE_ARM               ;answer, same shape --
            lda   #>TMR_REARM             ;see procbye.s
            sta   K_BYE_ARM+1
            jsr   TMR_OWN_03FE            ;hosted-main IRQ
                                               ;landing pad --
                                               ;see the shim's
                                               ;header
            lda   K_TIMER_FORCE
            beq   :real
            sta   K_TIMER_MODE
            jsr   TIMER_REPORT
            jsr   TMR_ARM_NOPHK           ;forced mode
                                               ;never enables a
                                               ;real hardware
                                               ;IRQ source in
                                               ;this test
                                               ;harness -- see
                                               ;the header's
                                               ;K_TIMER_FORCE
                                               ;note
            rts

:real       jsr   TMR_PRB_MOUSE
            bcc   :nomouse
            lda   #TMR_MD_MOUSE
            sta   K_TIMER_MODE
            jsr   TMR_INT_MOUSE              ;selects
                                                ;PRA/PRB,
                                                ;enables VBL
                                                ;interrupt mode,
                                                ;wires
                                                ;K_IRQ_HOOK ->
                                                ;TIMER_ISR
            jsr   TIMER_REPORT
            rts

:nomouse    ;-- LOUD, not silent: the mouse+VBL tier failed its
            ;own -- register round-trip (this is exactly what
            ;happens if -- sim/roms/applemouse.rom is missing --
            ;the card model never -- comes up, so the round-trip
            ;naturally fails -- the "missing -- ROM loud
            ;failure" duty, satisfied by falling through here --
            ;rather than silently waiting for ticks that will
            ;never -- come). --
            jsr   TIMER_PRB_MB
            bcc   :nomb
            lda   #TIMER_MODE_MB
            sta   K_TIMER_MODE
            jsr   TMR_INT_MB                ;REAL tier since
                                                 ;2026-08-18: T1
                                                 ;free-run at 60
                                                 ;Hz -- the tier
                                                 ;MAME boots on
            jsr   TIMER_REPORT
            rts

:nomb       lda   #TIMER_MD_COOP
            sta   K_TIMER_MODE
            jsr   TMR_ARM_NOPHK
            jsr   TIMER_REPORT
            rts

*---------------------------------------------------------------
* TMR_PRB_MOUSE -- register-readback liveness test at the
* AppleMouse PIA's DDRA/DDRB (CRA/CRB bit2=0, the post-reset
* default, selects the DDR half of the register pair). Returns
* carry SET if found (and, as a side effect, leaves
* DDRA=$FF/DDRB=$30 written -- exactly what TMR_INT_MOUSE
* needs next, so this doubles as the first half of init, not
* wasted work), carry CLEAR if not.
*
* CONFIDENCE NOTE (docs/HACKING.md's discipline): this is a
* BEHAVIORAL liveness probe (does a register at this address
* read back what was written), constructed and verified working
* in THIS task against verilogapple's fast backend -- it is NOT
* a claim about real Apple II open-bus behavior for unpopulated
* slots, which would need MAME/iron to verify. Real slot-ROM
* signature scanning ($Cn05/$Cn07 ID bytes) was considered and
* REJECTED for v1: the exact ID-byte convention for AppleMouse-
* class cards could not be confirmed against the street-library
* commons or the fetched TRM material during this task (a search
* sweep found neither a dedicated learning nor a TRM listing
* pinning the bytes down) -- per HACKING.md's confidence
* discipline, an unverified [likely] claim must not be load-
* bearing, so this probe uses only the ALREADY- verified PIA
* register model (mouse_card.h, cited throughout entry.s/ this
* file) instead. Flagged as a deposit/follow-up candidate in
* docs/SCHED.md, not silently assumed.
*---------------------------------------------------------------
TMR_PRB_MOUSE
            lda   #$FF
            sta   MOUSE_PRA                     ;CRA bit2=0
                                                ;(reset default)
                                                ;-> this hits
                                                ;DDRA
            lda   MOUSE_PRA
            cmp   #$FF
            bne   :no
            lda   #$30
            sta   MOUSE_PRB                     ;CRB bit2=0 ->
                                                ;hits DDRB
            lda   MOUSE_PRB
            cmp   #$30
            bne   :no
            sec
            rts
:no         clc
            rts

*---------------------------------------------------------------
* TMR_INT_MOUSE -- called only after TMR_PRB_MOUSE
* returns found. Selects PRA/PRB for all subsequent register-0/2
* accesses (CRA/CRB=$04, bit2=1 -- a ONE-TIME mode switch, not
* re-armed per interrupt, matching src/test/syscalltest.s's
* MAIN_ENTRY precedent verbatim), then sends M_SET mode $09 (on
* + VBL interrupt enable) via MOUSE_SND_CMD, and wires
* K_IRQ_HOOK at TIMER_ISR.
*---------------------------------------------------------------
TMR_INT_MOUSE
            lda   #$04
            sta   MOUSE_CRA
            sta   MOUSE_CRB
* -- M_INIT FIRST (2026-08-18): on the real 68705, SETMOUSE
* -- only stores the mode byte -- it is INITMOUSE that unmasks
* -- the MCU's timer interrupt and loads its divider (MCU ROM
* -- $547: BCLR 6,TCR / STA TDR). Without it, mode $09 arms
* -- nothing and zero VBL ticks ever arrive (found on MAME,
* -- which runs the real MCU ROM; verilogapple's model starts
* -- VBL on M_SET alone, hiding the omission). INITMOUSE is a
* -- 3-phase exchange: command, one reply byte out (value $00,
* -- discarded), one sync byte back in (value ignored by the
* -- MCU -- ROM $56C reads it and immediately clobbers A).
            lda   #$50                          ;M_INIT
            jsr   MOUSE_SND_CMD
            jsr   MOUSE_RD_BYTE                 ;its sync reply
            lda   #$00
            jsr   MOUSE_SND_CMD                 ;our sync byte
            lda   #$09                          ;M_SET, mode=$09
                                                ;(on + VBL
                                                ;interrupt
                                                ;enable)
            jsr   MOUSE_SND_CMD
            lda   #<TIMER_ISR
            sta   K_IRQ_HOOK
            lda   #>TIMER_ISR
            sta   K_IRQ_HOOK+1
            rts

*---------------------------------------------------------------
* MOUSE_SND_CMD now lives in src/kernel/mouse.s, which owns it
* outright. It used to be duplicated here and in mli.s; see that
* file's header and `make check-modules`. Includers must `put
* ../kernel/mouse.s` first.
*---------------------------------------------------------------

*---------------------------------------------------------------
* TIMER_ISR -- K_IRQ_HOOK's target once mouse+VBL mode is live.
* Sends M_SERV ($20) directly (IRQ-SOURCE CLEAR per the card
* firmware protocol -- mouse_card.h's on_command() case M_SERV
* sets irq=false synchronously the moment the command byte
* latches; no response byte needs reading -- the docs/TASKS.md
* #6 amendment's "per-tick IRQ-source clear" duty), counts the
* tick, then hands off to SCH_TICK for the actual quantum/
* preemption decision. NEVER calls mouse ROM firmware (the
* architect ruling resolving docs/SYSCALL.md #7.5/the ServeMouse
* finding -- see this file's header) -- this IS the "non-re-
* entry on a stale VBL source" test subject: because M_SERV
* synchronously clears the model's irq flag and this routine
* never re-enables interrupts internally (unlike the real
* ServeMouse ROM), a second IRQ cannot be recognized mid-service
* (I stays 1 throughout, hardware-enforced, same argument as
* docs/SYSCALL.md section 7.2) -- so K_VBL_TICKS can never run
* away from the nominal rate the way the pre-fix #7.5 regression
* did (~30-40x nominal). check-sched's stale-VBL check asserts
* exactly this: K_VBL_TICKS stays within a sane multiple of the
* expected count for the simulated duration.
*---------------------------------------------------------------
TIMER_ISR   lda   #$20                          ;M_SERV command
                                                ;nibble
            jsr   MOUSE_SND_CMD
            jsr   MOUSE_RD_BYTE                 ;consume the
                                                ;int-status
                                                ;reply -- the
                                                ;real MCU BLOCKS
                                                ;presenting it
                                                ;(see
                                                ;MOUSE_RD_BYTE)
            inc   K_VBL_TICKS
            bne   :nowrap
            inc   K_VBL_TICKS+1
            bne   :nowrap
            inc   K_VBL_TICKS+2
            bne   :nowrap
            inc   K_VBL_TICKS+3
:nowrap     jsr   SCH_TICK
            rts

*---------------------------------------------------------------
* TIMER_PRB_MB -- 6522 liveness test at the T1 LATCH low
* register, which reads back what was written without touching
* port pins or timer state. Two DISTINCT values, deliberately
* neither $FF nor $00: the old single-$FF DDRB check at the
* (wrong) $C0Cx base passed against MAME's floating bus, which
* returns video-scanner data -- $FF-heavy on a blank screen.
* An $A5-then-$5A echo through a latch cannot come off a
* floating bus two reads in a row.
*---------------------------------------------------------------
TIMER_PRB_MB
            lda   #$A5
            sta   MB_T1LL
            lda   MB_T1LL
            cmp   #$A5
            bne   :no
            lda   #$5A
            sta   MB_T1LL
            lda   MB_T1LL
            cmp   #$5A
            bne   :no
            sec
            rts
:no         clc
            rts

*---------------------------------------------------------------
* TMR_INT_MB -- called only after TIMER_PRB_MB finds the VIA.
* T1 continuous mode at ~60 Hz, interrupt enabled, K_IRQ_HOOK
* -> TIMER_ISR_MB. Writing T1C-H transfers the latches into the
* counter, clears any pending T1 flag, and starts counting --
* the 6522's documented arm sequence, no warm-up tick needed.
*---------------------------------------------------------------
TMR_INT_MB
            lda   #$40                          ;ACR bit6: T1
                                                ;free-run, PB7
                                                ;untouched
            sta   MB_ACR
            lda   #$C0                          ;IER: set-mode +
                                                ;T1 enable
            sta   MB_IER
            lda   #MB_T1_LO
            sta   MB_T1CL                       ;latch low
            lda   #MB_T1_HI
            sta   MB_T1CH                       ;load + start
            lda   #<TIMER_ISR_MB
            sta   K_IRQ_HOOK
            lda   #>TIMER_ISR_MB
            sta   K_IRQ_HOOK+1
            rts

*---------------------------------------------------------------
* TIMER_ISR_MB -- ack T1 by reading T1C-L (clears IFR bit 6;
* free-run mode reloads and keeps counting on its own), count
* the tick, hand off to SCH_TICK. Same non-re-entry argument as
* TIMER_ISR: the ack is synchronous and I stays set throughout.
*---------------------------------------------------------------
TIMER_ISR_MB
            lda   MB_T1CL                       ;the READ is the
                                                ;ack
            inc   K_VBL_TICKS
            bne   :nowrap
            inc   K_VBL_TICKS+1
            bne   :nowrap
            inc   K_VBL_TICKS+2
            bne   :nowrap
            inc   K_VBL_TICKS+3
:nowrap     jsr   SCH_TICK
            rts

*---------------------------------------------------------------
* MAIN_IRQ_SHIM / TMR_OWN_03FE -- the hosted-mode MAIN-context
* interrupt landing pad, discovered the hard way on MAME
* (2026-08-18).
*
* The kernel's interrupt design assumes I=1 for the whole of
* kernel/main execution, so ticks are only ever taken in a
* process bank where the per-bank $FFxx page owns $FFFE. That
* assumption does not survive third-party ProDOS device
* drivers: the AppleIISd firmware (and CFFA-class drivers
* generally) does a bare CLI inside its driver entry,
* re-enabling interrupts mid-MLI-call regardless of the
* caller's mask. The pending tick then fires in MAIN context,
* where $FFFE resolves to the ROM handler chain: the //e ROM
* saves A at $45 and jumps through the $03FE user vector --
* which ProDOS points at its own receiver, and an unclaimed
* interrupt there is the "RESTART SYSTEM-$01" box.
*
* So the kernel takes the documented seat: own $03FE. The shim
* acks the armed timer source (mode-dispatched), counts the
* tick, restores A from $45 per the ROM contract, and RTIs. NO
* SCH_TICK from here -- a context switch cannot be taken out
* from under a driver mid-MLI. The quantum stretches slightly
* during disk I/O; that is the correct trade and it is
* documented here rather than discovered again.
*---------------------------------------------------------------
* -- REWRITTEN 2026-08-19: the shim now owns MAIN's LC $FFFE
* -- DIRECTLY (INSTALL_IRQ's proven patch idiom) instead of
* -- receiving via ROM handler -> $C3FA -> ($03FE). The ROM
* -- chain is disqualified twice over: (1) the ROM saves the
* -- interrupted A at ZP $45 -- which is the HIGH BYTE OF THE
* -- BLOCK DRIVER'S LIVE BUFFER POINTER ($44/$45, AppleIISd
* -- source; ProDOS's own $42-$47 device convention) -- so any
* -- tick taken in a window where the driver's pointer is live
* -- sent the block transfer to a garbage page and corrupted
* -- the load (check-mame phase 4's dice-roll failures); (2)
* -- the $C3FA hop executes slot 3's ROM or floating bus.
* -- During any main-context unmasked window (the MLI bracket)
* -- the LC is read-enabled -- ProDOS lives there -- so the LC
* -- $FFFE is the live vector and the ROM never runs. This
* -- handler therefore saves its own registers: hardware
* -- pushed P/PC only.
MAIN_IRQ_SHIM
            pha
            phx
            phy
* -- BRK discrimination: LC $FFFE serves BRK too. A BRK in
* -- main context is a kernel bug -- park it visibly (the old
* -- ROM path fell into the monitor; we no longer have one).
            tsx
            lda   $0104,x                     ;stacked P: entry
                                              ;SP+1 -> P; our 3
                                              ;pushes make it
                                              ;SP+4
            and   #$10
            bne   :brkpark
            lda   K_TIMER_MODE
            cmp   #TIMER_MODE_MB
            bne   :mouse
            lda   MB_T1CL                       ;ack T1
            bra   :count
:mouse      cmp   #TMR_MD_MOUSE
            bne   :tty                          ;coop: nothing
                                                ;armed, nothing
                                                ;to ack
            lda   #$20                          ;M_SERV
            jsr   MOUSE_SND_CMD
            jsr   MOUSE_RD_BYTE                 ;status reply --
                                                ;mandatory, see
                                                ;MOUSE_RD_BYTE
:count      inc   K_VBL_TICKS
            bne   :tty
            inc   K_VBL_TICKS+1
            bne   :tty
            inc   K_VBL_TICKS+2
            bne   :tty
            inc   K_VBL_TICKS+3
* -- RESPONSIVENESS (2026-08-18): with interrupts now enabled
* -- across MLI calls (the PMLI_* cli/sei brackets, procfd.s),
* -- this shim is the system's heartbeat during disk I/O. The
* -- IIe keyboard latches exactly ONE key, so without a poll
* -- here every keystroke past the first dies during a long
* -- read. The poll goes through K_TICK_HOOK -- the same
* -- includer-supplied vector SCH_TICK dispatches (play images
* -- point it at TTY_TICK, whose contract saves/restores every
* -- ZP cell it touches precisely so it is transparent to an
* -- interrupted MLI call; sched-only images point it at a
* -- stub, which is also what keeps this module linkable
* -- without a tty). X/Y are ours to preserve -- the ROM chain
* -- saves only A (at $45).
:tty        phx
            phy
            jsr   :hook
            ply
            plx
            bra   :c800
:hook       jmp   (K_TICK_HOOK)
* -- The vector fetch at $C3FA is a slot-3 access (Videx IRQ
* -- stub) and the tty echo path claims $C800 for slot 3, so
* -- the window's ownership is arbitrary here -- while the
* -- interrupted code may be the DISK card's $C800-resident
* -- driver. Make it deterministic: release everyone, re-claim
* -- the boot disk slot. Harmless when the interrupt landed
* -- outside the driver; essential when it landed inside:
* -- a2sd's block-copy loop EXECUTES from $C800-$CEFF (EXTROM
* -- segment, AppleIISd source), so this reclaim is what lets
* -- a tick land mid-transfer and resume it. Verified at source
* -- level 2026-08-19 (docs/SYSCALL.md 7.8 audit note).
:c800       lda   CLRC8ROM
            lda   SP_IOSEL
            ply
            plx
            pla
            rti
:brkpark    bra   :brkpark                    ;main-context BRK
                                              ;= kernel bug --
                                              ;park it, visible

*---------------------------------------------------------------
* TMR_OWN_03FE -- install the main-context IRQ landing pad.
* Primary: patch MAIN's LC $FFFE (both banked configs -- the
* $D000 difference doesn't touch $FFxx, but write under each
* bank select for the always-write discipline) directly at
* MAIN_IRQ_SHIM, INSTALL_IRQ's proven idiom. ProDOS keeps the
* LC read-enabled whenever main code runs unmasked, so this is
* the vector every main-context IRQ actually takes; the ROM
* handler -- whose $45 accumulator save corrupts the block
* driver's live buffer pointer -- never runs again. $03FE is
* still pointed at the shim as a defensive fallback for any
* future LC-read-off window; that path loses the interrupted A
* (the ROM's $45 stomp) but no longer loses the machine.
*---------------------------------------------------------------
TMR_OWN_03FE
            php
            sei
            lda   LCBANK2_RAM                   ;write-enable
            lda   LCBANK2_RAM                   ;(double read)
            lda   #<MAIN_IRQ_SHIM
            sta   $FFFE
            lda   #>MAIN_IRQ_SHIM
            sta   $FFFF
*-- No re-protect: write-enable is the steady state now
*-- (docs/LANGUAGE-CARD.md).
            lda   #<MAIN_IRQ_SHIM
            sta   $03FE
            lda   #>MAIN_IRQ_SHIM
            sta   $03FF
            plp
            rts

*---------------------------------------------------------------
* TIMER_ISR_NOP -- defensive hook target for every mode in which
* no tick source is live: cooperative (no device at all), the
* K_TIMER_FORCE test-harness modes (which report a mode without
* arming anything), and the parked state after TMR_QUIESCE.
* The REAL Mockingboard tier is NOT one of these: TMR_INT_MB
* programs the 6522 (ACR free-run, IER T1 enable, T1 latch,
* 60 Hz) and points K_IRQ_HOOK at TIMER_ISR_MB. In the modes
* above no source is armed to interrupt, so this should never
* actually be entered -- parked here (RTS, not a halt) as a
* safety net matching this kernel's existing defensive-stub
* habit (RESET_STUB, NMI_TRAP) rather than leaving K_IRQ_HOOK
* pointing at garbage if some OTHER, unexpected IRQ fires.
*---------------------------------------------------------------
TIMER_ISR_NOP
            rts

TMR_ARM_NOPHK
            lda   #<TIMER_ISR_NOP
            sta   K_IRQ_HOOK
            lda   #>TIMER_ISR_NOP
            sta   K_IRQ_HOOK+1
            rts

*---------------------------------------------------------------
* TMR_QUIESCE -- the exact inverse of whichever arm ran, so the
* machine stops having a periodic interrupt source. Written for
* PRC_HALT (shutdown); `bye` wants the identical window before
* it QUITs, because a ProDOS program does not expect a live IRQ
* (docs/BYE.md, "Interrupts").
*
* DISARM THE DEVICE, NOT JUST THE HOOK. TMR_ARM_NOPHK alone
* points K_IRQ_HOOK at an RTS, which makes the tick harmless but
* leaves the SOURCE asserting: the machine still takes 60
* interrupts a second and still needs someone to service them.
* That is fine while maux is the someone and fatal once it is
* not. So this goes at the hardware first and the hook second.
*
* Mouse tier: M_SET mode $00 is "off", the same command
* TMR_INT_MOUSE sends with mode $09 ("on + VBL interrupt
* enable"). Mockingboard tier: the 6522's IER is a set/clear
* register -- bit 7 SET means "enable the bits I name", bit 7
* CLEAR means "disable them", so $40 clears exactly the T1
* enable that $C0 set. Cooperative mode armed no device at all
* and has nothing to undo; falling through to the hook is right
* rather than merely harmless.
*
* Leaves the caller's interrupt mask as it found it. PRC_HALT
* masks for good afterwards; a future `bye` must not, because it
* has an MLI call to make.
*---------------------------------------------------------------
TMR_QUIESCE
            php
            sei
            lda   K_TIMER_MODE
            cmp   #TMR_MD_MOUSE
            bne   :notmouse
            lda   #$00                    ;M_SET, mode 0 = off
            jsr   MOUSE_SND_CMD
*-- ...AND TAKE THE VBL INTERRUPT THAT MAY ALREADY BE PENDING
*-- (KFIX5, found by the box sweep). Mode 0 stops new ticks but
*-- does not clear one the controller has latched; this runs
*-- masked, so a tick that landed in the window stays asserted
*-- and `bye` hands the machine to a tenant whose first CLI
*-- takes it, into maux's ISR, which waits for a reply the
*-- controller will not send: the same `bye` came back or hung
*-- by the phase of the 60 Hz tick (measured: base e0900c5,
*-- `pwd` then `bye /mnt/SECOND/TENANT.SYSTEM`). M_SERV with
*-- its reply read is exactly what the ISR does on a tick.
            lda   #$20                    ;M_SERV
            jsr   MOUSE_SND_CMD
            jsr   MOUSE_RD_BYTE
            bra   :hook
:notmouse   cmp   #TIMER_MODE_MB
            bne   :hook
            lda   #$40                    ;IER bit7 clear =
            sta   MB_IER                  ;DISABLE the T1 enable
:hook       jsr   TMR_ARM_NOPHK
            plp
            rts

*---------------------------------------------------------------
* TMR_REARM -- the exact inverse of TMR_QUIESCE's device half:
* re-enable whichever device K_TIMER_MODE says was probed.
* Written for `bye`'s return path (PRC_BYE, src/kernel/
* procbye.s), the only caller, via the SAME K_BYE_ARM indirect
* TIMER_PROBE fills in below (0 in an image with no timer,
* mirroring K_HALT_TMR -- procbye.s's own thunk skips the call
* entirely when it reads 0).
*
* K_IRQ_HOOK: the Mockingboard/coop branches do not touch it --
* `bye`'s caller resumes through the machine's own saved image,
* K_IRQ_HOOK is main memory in $0200-$BEFF, and BYE_BACK's bulk
* restore already put it back to whatever it was before `bye`
* ran, byte for byte, so a redundant write into a window this
* fragile earns no trust. The mouse branch is the ONE exception,
* below: TMR_INT_MOUSE writes K_IRQ_HOOK unconditionally (it is
* boot's own bring-up routine, not written bye-specific), to the
* SAME TIMER_ISR value the bulk restore already wrote --
* harmless by coincidence of both paths agreeing, not because
* this routine avoids the write.
*
* $FFFE/$FFFF are NOT this routine's job either -- they live in
* the language card, outside the saved image, and PRC_BYE saves
* and restores those two bytes itself (docs/BYE-SLICE1.md).
*
* Mouse tier: a full TMR_INT_MOUSE bring-up, not a bare M_SET --
* see that branch's own comment below for why. Mockingboard
* tier: IER bit7 SET means "enable the bits I name", so $C0
* re-arms exactly the T1 enable TMR_QUIESCE's $40 cleared -- a
* dumb VIA counter has no MCU firmware state for ProDOS to have
* disturbed, so the bare re-enable that was always correct for
* PRC_HALT's pause is equally correct here; NOT implicated in
* the mouse-tier defect below. Cooperative/unprobed: nothing was
* armed, nothing to redo.
*---------------------------------------------------------------
* -- named, not a bare #$C0 (check-encoding: a bare byte happens
* -- to fall in the ratchet's flagged range though it is not
* -- TEXT) -- same IER set-mode+T1-enable bit pattern TMR_INT_MB
* -- already writes above, used again here for the
* -- Mockingboard-tier bare re-enable below.
MB_IER_SETT1 equ  $C0
TMR_REARM
            php
            sei
            lda   K_TIMER_MODE
            cmp   #TMR_MD_MOUSE
            bne   :rnotmouse
* -- THE MECHANISM IS SETTLED, NOT JUST OBSERVED:
* -- learning:01M09GD7XX16W242VB96ADD1CB sec 2, MAME-verified
* -- against the real 68705 mask ROM disassembly, already said
* -- "SETMOUSE only stores the mode -- INITMOUSE arms the MCU
* -- timer ... symptom: VBL mode armed, zero interrupts" and
* -- gave the exact sequence: INITMOUSE (consume its reply byte,
* -- send the sync byte), THEN SETMOUSE|mode. TMR_REARM sent
* -- only SETMOUSE ($09) -- by that disassembly it could not
* -- have armed anything. Found the SAME conclusion by
* -- measurement first (2026-09-25, verilogapple fast backend:
* -- K_VBL_TICKS frozen solid after every `bye` round trip with
* -- bare M_SET, resumed with the full TMR_INT_MOUSE bring-up
* -- in its place) -- the commons already had it. GRADED
* -- HONESTLY: the mechanism above is [fact] (MAME/silicon);
* -- that ProDOS's own QUIT is what leaves the divider
* -- unloaded -- as opposed to, say, the MCU simply lapsing on
* -- its own -- is [likely], not determined here. The A/B
* -- proved the FIX, not the cause; this comment does not
* -- claim more than that. ALSO NOTED in that learning:
* -- verilogapple's fast backend "starts VBL on M_SET alone" --
* -- this project's own test rig would have let a SETMOUSE-only
* -- re-arm pass here if the timer had happened to still be
* -- armed, hiding the whole class of bug the mask-ROM
* -- disassembly explains directly.
* -- ASSUMES DDRA/DDRB are still $FF/$30 from boot:
* -- TMR_INT_MOUSE skips TMR_PRB_MOUSE's own DDR setup (it is
* -- written to run only after that probe already has), which
* -- held across every `bye` round trip tested but was not
* -- reverified here per call.
            jsr   TMR_INT_MOUSE
            bra   :rdone
:rnotmouse  cmp   #TIMER_MODE_MB
            bne   :rdone
            lda   #MB_IER_SETT1           ;IER: set-mode + T1
            sta   MB_IER                  ;enable
:rdone      plp
            rts

*---------------------------------------------------------------
* TIMER_REPORT -- the "loud, not silent" duty (docs/TASKS.md #6
* amendment A8): prints "TIMER:" + a fixed-width mode name to a
* dedicated text-page row. Deliberately NOT parameterized by the
* includer (no console driver exists yet, task #10 scope) --
* TMR_RPRT_ROW is fixed here; a real tty driver replaces
* this with a proper boot-log line later without changing WHEN
* this runs or WHAT it decides, only how it's displayed.
*---------------------------------------------------------------
*-- WRONG UNTIL 2026-08-17: this was $04C8, described as
*-- "$0400 + 5*40". The Apple II text page is NOT linear:
*-- rows interleave in thirds, so row 5 is $0680, and $04C8
*-- lands at column 32 of row 9, with the tail running into
*-- the $04D0 screen hole where it is not displayed at all.
*--
*-- It was invisible for a second reason too: TIMER_PROBE runs
*-- before PRC_INIT, and TTY_INIT's TTY_CLR_BODY then blanks
*-- rows 1-23, including whatever this wrote. So the "loud, not
*-- silent" duty in docs/TASKS.md #6 has never actually been
*-- loud. Fixing the address is necessary but not sufficient;
*-- see the note at TIMER_REPORT.
TR_LABEL    asc   "TIMER:"
TR_LABELLEN equ   *-TR_LABEL
TR_MOUSE    asc   "MOUSE-VBL "
TR_MB       asc   "MOCKNGBRD "
TR_COOP     asc   "COOPERATIV"
TR_NAMELEN  equ   *-TR_COOP        ;all three names padded to
                                   ;the same 10-char width in
                                   ;the source above

TMR_RPRT_ROW equ $0680                      ;40-col text page
                                                ;row 5 -- the
                                                ;REAL base, not
                                                ;$0400+5*40

*-- ORDERING: callers run this from TIMER_PROBE, which images
*-- invoke BEFORE PRC_INIT. TTY_INIT clears rows 1-23 right
*-- afterwards, so the line is erased before anyone sees it. The
*-- fix is a console the kernel can log to (docs/CONSOLE.md),
*-- not a different row -- so the address is now correct and the
*-- message is still transient. Recorded rather than papered
*-- over with a row TTY_CLR_BODY happens to miss.
TIMER_REPORT
            ldy   #0
:lbl        lda   TR_LABEL,y
            sta   TMR_RPRT_ROW,y
            iny
            cpy   #TR_LABELLEN
            bne   :lbl
            lda   K_TIMER_MODE
            cmp   #TMR_MD_MOUSE
            bne   :t2
            ldy   #0
:m1         lda   TR_MOUSE,y
            sta   TMR_RPRT_ROW+TR_LABELLEN,y
            iny
            cpy   #TR_NAMELEN
            bne   :m1
            rts
:t2         cmp   #TIMER_MODE_MB
            bne   :t3
            ldy   #0
:m2         lda   TR_MB,y
            sta   TMR_RPRT_ROW+TR_LABELLEN,y
            iny
            cpy   #TR_NAMELEN
            bne   :m2
            rts
:t3         ldy   #0
:m3         lda   TR_COOP,y
            sta   TMR_RPRT_ROW+TR_LABELLEN,y
            iny
            cpy   #TR_NAMELEN
            bne   :m3
            rts

*-- TR_LABEL/TR_MOUSE/TR_MB/TR_COOP and their lengths moved
*-- ABOVE TIMER_REPORT (S9 EQU burn-down 2026-08-29): the
*-- lengths were used in immediates before their definitions,
*-- which real Merlin-8 refuses.
