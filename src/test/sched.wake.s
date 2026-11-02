*---------------------------------------------------------------
* sched.wake.s -- code review C1 regression gate
* (`make check-sched`), wake-after-empty-runqueue variant. Bank
* 1's process runs ALONE (bank 2's process is created but
* immediately parked PCB_BLOCKED, never pushed to the run queue)
* -- every quantum exhaustion while it's alone exercises
* SCH_SWITCH's empty-runqueue CANCEL path (the exact path C1
* found leaving K_QUANTUM exhausted). After enough quantum
* exhaustions to prove the cancel path fires repeatedly, bank
* 1's process wakes bank 2 exactly once (ST_WAKE_CALL)
* and then spins forever. scripts/check_sched.py measures, in
* VBL-tick units (not wall/cycle time, which the cancel-path bug
* does not affect at all -- only how PROMPTLY K_QUANTUM re-
* arms), how many ticks pass between the wake and bank 2
* actually becoming K_CURPID: at most a handful (QUANTUM_TICKS-
* ish) with the fix landed in src/kernel/sched.s, vs. up to a
* 256-tick wraparound without it (the code review's own
* description).
*
* See src/test/sched.common.s (ST_MODE=2 branch,
* FKP_WAKE, TCALL_WAKE, BLOCK_PID) for the shared
* mechanics, and src/test/sched.preempt.s for the LOADER
* boilerplate this file duplicates verbatim (see that file's
* header for why it's not factored out).
*---------------------------------------------------------------

PTRP        equ   $E6
NBLOCKS     equ   11                         ;same fixed cap as
            lst   off
            xc                              ;65C02 instruction
                                            ;set
            org   $0800
            dsk   ../../build/schedtest_wake.bin
            typ   $00

            dfb   $01                        ;chain count (ROM
                                             ;convention)

START       sei
            ldx   #$FF
            txs
            cld

            jsr   SP_INIT
            bcc   :sp_ok
            lda   #'!'+$80
            sta   $0400
            jmp   *
:sp_ok
            ldx   #1
:rdloop     stx   BLKNO
            stz   RD_PARMS+2
            txa
            asl   a
            clc
            adc   #8
            sta   RD_PARMS+3
            lda   BLKNO
            sta   RD_PARMS+4
            stz   RD_PARMS+5
            stz   RD_PARMS+6
            jsr   SP_DISPATCH
            dfb   $01
            da    RD_PARMS
            bcc   :rdok
            lda   #'X'+$80
            sta   $0400
            jmp   *
:rdok       ldx   BLKNO
            inx
            cpx   #NBLOCKS
            bne   :rdloop

            jmp   MAIN_ENTRY

                                            ;preempt/coop

SP_INIT     stz   PTRP
            lda   #$C7
            sta   PTRP+1
            ldy   #$01
            lda   (PTRP),y
            cmp   #$20
            bne   :fail
            ldy   #$03
            lda   (PTRP),y
            cmp   #$00
            bne   :fail
            ldy   #$05
            lda   (PTRP),y
            cmp   #$03
            bne   :fail
            ldy   #$07
            lda   (PTRP),y
            cmp   #$00
            bne   :fail
            ldy   #$FF
            lda   (PTRP),y
            clc
            adc   #3
            adc   PTRP
            sta   SP_TARGET
            lda   PTRP+1
            adc   #0
            sta   SP_TARGET+1
            clc
            rts
:fail       sec
            rts

SP_DISPATCH lda   $C006
            jmp   $0000
SP_TARGET   equ   SP_DISPATCH+4

RD_PARMS    dfb   3
            dfb   1
            da    0
            dfb   0,0,0

BLKNO       ds    1

            ds    $0800+512-*

*---------------------------------------------------------------
* MAIN PROGRAM -- block 1+. ST_MODE=2 selects the wake-
* after- empty-runqueue variant in sched.common.s's shared
* MAIN_ENTRY.
*---------------------------------------------------------------
ST_MODE equ 2

* -- KSPACE2: sched.s now homes K_CWD_BUF/K_WAKE_BUF in KBSS,
* -- so this raw image reserves the scratch hole like the
* -- other org-$0800 images (docs/KSPACE2-NOTES.md).
KBSS        equ   $0A00        ;kernel scratch home
            put   ../../inc/mm.kbss.equ
            ds    1520      ;check-kbss: chain length

            put   ../../inc/mm.procbank.equ
            put   ../../inc/mm.procbnk2.equ
            put   ../../inc/mm.hw.equ
            put   ../../inc/mm.mli.equ
            put   ../../inc/mm.annex.equ
            put   ../../inc/mm.annex2.equ
            put   ../../inc/bankcopy.equ
            put   ../../inc/entry.frame.equ
            put   ../../inc/sched.equ
            put   ../../inc/sched.zp.equ
            put   ../../inc/bankprobe.equ
            put   ../../inc/mli.const.equ
            put   ../../inc/timer.equ
            put   ../../inc/ultraterm.equ
            put   ../../inc/errno.krn.equ

K_DISP_COUNT equ  2          ;ST_YIELD_CALL +
                                 ;ST_WAKE_CALL
K_IRQ_HOOK       ds   2          ;filled by src/kernel/timer.s's
                                 ;TIMER_PROBE

            put   ../kernel/entry.s
            put   ../kernel/entry2.s
            put   ../kernel/ffpage.s
            put   ../kernel/sched.s
            put   ../kernel/sched2.s
            put   ../kernel/procsig.s
            put   ../kernel/mouse.s
            put   ../kernel/timer.s

            put   sched.common.s

            ;-- literal hex sum, not `NBLOCKS*512` -- see
            ;-- sched.preempt.s's note on merlin32's `*`
            ;ambiguity.
            ;-- NBLOCKS=11 -> 11*512 = $1600; target =
            ;-- $0800+$1600 = $1E00 (was $1800).
            ds    $1E00-*
