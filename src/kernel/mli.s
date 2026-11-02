*---------------------------------------------------------------
* mli.s -- kernel-skeleton ProDOS MLI coexistence primitives
* (docs/TASKS.md #11 spike). PUT-included, no ORG/DSK (same
* convention as bankprobe.s / entry.s). SPIKE-GRADE: proves the
* mechanisms docs/PRODOS-SPIKE.md's answers (a)-(d) depend on.
* NOT wired to the real syscall ABI -- src/kernel/entry.s's
* P8_DELEGATE stub (docs/SYSCALL.md item 2) is untouched by
* this file; task #12+ does the real wiring, gated on this spike
* per docs/TASKS.md #11's own text ("File syscalls... wire up
* only after this passes").
* Full design notes: K.MLI.TXT (docs/a2/)
*---------------------------------------------------------------


DEVCNT      equ   $BF31
DEVLST      equ   $BF32      ;16 bytes, $BF32-$BF3F, device
                             ;NUMBERS ($B3/ $B7/$BB/$BF = the
                             ;/RAM family's low-nibble ID)
RAMSLOT     equ   $BF26      ;slot3/drive2 driver-vector cell
                             ;within the $BF10-$BF2F driver-
                             ;address table (TRM's own fixed
                             ;constant, ch. 5.2.2.3 sample --
                             ;not re-derived here)
NODEV       equ   $BF10      ;slot0/drive1 "no device connected"
                             ;vector, reserved by Apple as the
                             ;disconnect target
MACHID      equ   $BF98

* -- LC softswitches, main context (ALTZP=main always in this
* module -- -- values match inc/memmap.equ's LCBANK2_* table
* verbatim). --

* -- AppleMouse II PIA, slot 5 (verilogapple default machine, --
* learning:01KZXDQCQF2FZMDQ59FVZ5D7T4) -- same
* constants/protocol as -- src/kernel/timer.s's
* TMR_INT_MOUSE/MOUSE_SND_CMD, copied rather -- than
* `put`-shared for the same one-level-nesting + isolation
* reasons -- as the LC constants above. This spike's ISR does
* NOT call SCH_TICK -- (no scheduler exists in this test
* image) -- it only counts ticks and -- clears the card's IRQ
* source, per the "never call mouse ROM firmware" -- rule. The
* PIA register equates now live in inc/memmap.equ. -- policy
* (docs/SYSCALL.md #7.5) which this module also honors.

* See K.MLI.TXT: "RAMDISCONNECT -- the A7 lifecycles HADRAM"
RAM_DISCON
            php
            sei
            stz   MLI_HAD_RAM
            lda   MACHID
            and   #$30
            cmp   #$30
            bne   :ramdone              ;not 128K -- no /RAM
                                        ;possible
            ldy   DEVCNT
:scan       lda   DEVLST,y
            and   #$F3
            cmp   #$B3
            beq   :found
            dey
            bpl   :scan
            bra   :ramdone              ;ran out of units, none
                                        ;matched
:found      lda   #1
            sta   MLI_HAD_RAM
:shift      lda   DEVLST+1,y             ;bubble trailing
                                         ;entries up over
            sta   DEVLST,y               ;the removed one (TRM
                                         ;pattern)
            beq   :patch                 ;zero trails the list
                                         ;-- done
            iny
            bne   :shift
:patch      lda   NODEV
            sta   RAMSLOT
            lda   NODEV+1
            sta   RAMSLOT+1
            dec   DEVCNT
            jsr   MLI                    ;TN #8: ON_LINE unit
                                         ;$B0, expect
            dfb   $C5                    ;$28 -- clears the
                                         ;stale VCB
            da    ONLINE_PARMS
            sta   MLI_ONLN_ERR
:ramdone    plp
            rts

ONLINE_PARMS
            dfb   2
            dfb   $B0                    ;slot3/drive2, MLI
                                         ;unit_num FORMAT
            da    ONLINE_BUF
ONLINE_BUF  ds    16

*---------------------------------------------------------------
* INSTALL_IRQ -- raw ownership of main's hardware $FFFE/$FFFF
* vector (docs/PRODOS-SPIKE.md answer (b): the ALLOC_INTERRUPT-
* vs-raw-ownership decision). Snapshots the pre-patch
* $FF00-$FFFF page into MLI_VCPG_BOOT FIRST (empirical record
* of what ProDOS actually left there -- feeds (a) and (b)'s
* writeup), then write-enables LC bank 2 (double-read idiom,
* same mechanism as src/kernel/entry.s's INSTALL_COPY), patches
* ONLY the 2-byte IRQ/BRK vector to point at OUR_IRQ_HNDLR
* (leaves NMI/RESET vectors and every other byte of the page
* untouched -- deliberately a SURGICAL 2-byte patch, not the
* whole-page FFP_SYSC_ENT-style stamp task #3's ProDOS-less
* boot path uses, because this page is NOT free headroom under
* ProDOS residency -- see the MLI_VCPG_BOOT snapshot's own
* finding, recorded in docs/PRODOS-SPIKE.md), and LEAVES the
* card write-enabled.
*
* It used to re-protect here, "so ProDOS's own resident code
* is not left write-exposed by an oversight". That was well
* meant and wrong in one specific way: write-enable is ONE
* latch for the WHOLE MACHINE and CANNOT be read back, so
* re-protecting does not restore a state -- it IMPOSES one on
* every other process, including one paused in the middle of
* its own copy loop, whose remaining stores are then dropped
* in silence. ProDOS itself never does this: its MLI entry
* write-ENABLES on every call ($BFC6 `BIT $C08B` twice, read
* live off the bus), and the only protects in its resident
* image are the QUIT window and the exit-to-ROM glue.
* docs/LANGUAGE-CARD.md.
*---------------------------------------------------------------
INSTALL_IRQ
            php
            sei
            ldy   #0
:snap       lda   $FF00,y
            sta   MLI_VCPG_BOOT,y
            iny
            bne   :snap
            lda   LCBANK2_RAM            ;write-enable (double
                                         ;read)
            lda   LCBANK2_RAM
            lda   #<OUR_IRQ_HNDLR
            sta   $FFFE
            lda   #>OUR_IRQ_HNDLR
            sta   $FFFF
*-- NO re-protect here. LC write-enable is the machine-wide
*-- steady state as of 2026-09-20 -- docs/LANGUAGE-CARD.md.
            plp
            rts

*---------------------------------------------------------------
* MOUSE_INIT -- direct-PIA AppleMouse VBL bring-up.
* MOUSE_SND_CMD itself now lives in src/kernel/mouse.s, which
* owns it outright; includers must `put ../kernel/mouse.s`
* before this module. Bring-up mechanism promoted verbatim
* (mechanism) from src/kernel/timer.s's TMR_INT_MOUSE/
* MOUSE_SND_CMD -- no ROM firmware call, ever (docs/SYSCALL.md
* #7.5 policy: a called firmware routine's own internal CLI can
* land inside a critical section this kernel doesn't control;
* direct register pokes sidestep the whole hazard class).
*---------------------------------------------------------------
MOUSE_INIT  lda   #$FF
            sta   MOUSE_PRA              ;CRA bit2=0 (reset
                                         ;default) -> DDRA
            lda   MOUSE_PRA
            lda   #$30
            sta   MOUSE_PRB              ;CRB bit2=0 -> DDRB
            lda   #$04
            sta   MOUSE_CRA
            sta   MOUSE_CRB
            lda   #$09                   ;M_SET, mode=on+VBL-
                                         ;interrupt-enable
            jsr   MOUSE_SND_CMD
            rts


*---------------------------------------------------------------
* OUR_IRQ_HNDLR -- the raw $FFFE target. Hardware already
* pushed PCH,PCL,P and set I (65C02 auto-clears D) -- this stub
* PHAs/PHXs/PHYs, discriminates BRK via the stacked P's B flag
* (same bit-4 test as src/kernel/entry.s's KRN_IRQ_ENTRY,
* independently arrived at here since this module doesn't share
* that file's trapframe machinery), and on a real IRQ calls
* VBL_ISR then RTIs. No trapframe/bank-switch dance -- this
* spike is main-context only, no process banks are involved.
*---------------------------------------------------------------
OUR_IRQ_HNDLR
            pha
            phx
            phy
            tsx
            lda   $0104,x                ;hardware-pushed P (see
                                         ;header
            and   #$10                   ;offset derivation: 3
                                         ;pushes above
            bne   :isbrk                 ;put P at $0100+SP+4)
            jsr   VBL_ISR
            ply
            plx
            pla
            rti
:isbrk      ply                          ;BRK unused in this
                                         ;spike -- park
            plx                          ;visibly (regs/peek-
                                         ;inspectable)
            pla                          ;rather than silently
                                         ;falling into
            sta   MLI_BRK_SEEN             ;anything MLI-shaped
:parkbrk    bra   :parkbrk

*---------------------------------------------------------------
* VBL_ISR -- per-tick work: clear the card's IRQ source (M_SERV,
* IRQ-source clear per docs/SYSCALL.md #7.5's "never re-enter"
* discipline -- this routine never re-enables interrupts
* internally, so I stays 1 throughout, same non-re-entry
* argument as timer.s's TIMER_ISR), count the tick, sample
* MLIACTV for the (b)/(c) evidence log, then run the
* docs/PRODOS- SPIKE.md answer (d) lock-contention check: if
* K_MLI_LOCK is held, this is a genuine "a second context wanted
* the MLI while the first was mid- call" observation -- log it
* and return WITHOUT ever calling MLI itself (an IRQ handler
* making a nested MLI call needs the TRM 6.2.1 CMDADR-swap
* dance; this design sidesteps that entirely by policy: IRQ
* context only ever READS K_MLI_LOCK and sets a deferred-
* dispatch flag for FOREGROUND code to act on, matching maux's
* own real architecture where IRQ handlers never make syscalls
* on a process's behalf).
*---------------------------------------------------------------
VBL_ISR     lda   #$20                   ;M_SERV -- synchronous
                                         ;IRQ-source
            jsr   MOUSE_SND_CMD         ;clear (mouse_card.h
                                         ;on_command())
            inc   MLI_VBL_TICKS
            bne   :nowrap
            inc   MLI_VBL_TICKS+1
:nowrap     lda   MLIACTV
            beq   :notactv
            inc   MLI_MLCTV_SN
:notactv    lda   K_MLI_LOCK
            beq   :maybedisp
            inc   MLI_CNTND_CNT
            bne   :rts
            inc   MLI_CNTND_CNT+1
            bra   :rts
:maybedisp
            lda   MLI_WTR_WANT
            beq   :rts
            lda   #1
            sta   MLI_WTR_READY
:rts        rts

*---------------------------------------------------------------
* K_MLI_LOCK / MLI_LOCK_ACQ / MLI_LOCK_REL --
* docs/PRODOS-SPIKE.md answer (d)'s serialization primitive.
* FOREGROUND-ONLY: only ever WRITTEN from foreground (non-IRQ)
* code, matching the "IRQ context only reads it" policy VBL_ISR
* documents above -- so a bare STA is atomic with respect to the
* ISR (nothing else can interleave a write). Not general-purpose
* SMP- grade locking (this is a single 6502 core, not multiple
* real processors) -- it is the same shape the real kernel's
* P8_DELEGATE lock (task #12+) needs: serialize access from
* multiple SCHEDULED CONTEXTS (whichever process is current +
* whatever the VBL scheduler tick wants to do), not multiple
* simultaneously-executing cores.
*---------------------------------------------------------------
*---------------------------------------------------------------
* Module-owned observation and handshake cells (task #8a, `make
* check-modules`).
*
* These were previously declared by src/test/prodos.spike.s and
* written into from here -- a kernel module reaching up into its
* includer's memory, which is exactly what cannot survive
* separate assembly. They are this module's own state now; the
* harness and scripts/check_mli.py READ them, resolving
* addresses from merlin32's -v1 symbol dump rather than
* hardcoding.
*
* Precedent: src/kernel/sched.s already owns K_SW_COUNT the
* same way ("diagnostic ... check-sched's assertion reads this
* via peek").
*
* -- outputs: written here, read by the harness/checker --
MLI_HAD_RAM      ds 1     ;/RAM was present at launch ->
                          ;reinstall on exit. NOT merely
                          ;diagnostic: the polite-citizen
                          ;protocol
                          ;(learning:01KW1GTYH4NRG0F8M7AAT6EG9Z)
                          ;is wrong without it, so this is real
                          ;kernel state that had been living in
                          ;a test harness.
MLI_ONLN_ERR   ds 1     ;ON_LINE result from the TN#8
                          ;disconnect follow-up
MLI_BRK_SEEN     ds 1     ;BRKs observed by the raw $FFFE
                          ;handler
MLI_VBL_TICKS    ds 2     ;VBL ticks serviced
MLI_MLCTV_SN ds 1     ;ticks that landed while MLIACTV was
                          ;nonzero
MLI_CNTND_CNT ds 2    ;ticks that landed while the MLI lock
                          ;was held
MLI_VCPG_BOOT ds 256   ;$FF00-$FFFF snapshot taken BEFORE the
                          ;2-byte vector patch -- the evidence
                          ;for docs/PRODOS-SPIKE.md's "252 of
                          ;256 bytes are ProDOS's own" finding.
                          ;256 bytes of kernel space for a one-
                          ;shot observation is heavy; a later
                          ;cleanup should let the caller
                          ;snapshot instead.
*
* -- lock-waiter handshake: the caller sets WANT, VBL_ISR sets
* READY once the -- lock is free. This is a real mechanism, not
* test scaffolding -- it is a -- wakeup-on-lock-release, and it
* belongs with the lock it serves. --
MLI_WTR_WANT  ds 1     ;caller: a waiter wants the lock
MLI_WTR_READY ds 1     ;VBL_ISR: lock was free, waiter may
                          ;proceed
*---------------------------------------------------------------
K_MLI_LOCK  ds    1

MLI_LOCK_ACQ                         ;A = holder id on entry
            sta   K_MLI_LOCK
            rts

MLI_LOCK_REL
            stz   K_MLI_LOCK
            rts
