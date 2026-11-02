*---------------------------------------------------------------
* sched.coop.s -- task #6 acceptance gate (`make check-
* sched`), cooperative-mode variant. The timer probe is FORCED
* to TIMER_MD_COOP (src/kernel/timer.s's K_TIMER_FORCE hook)
* -- no hardware IRQ source is ever armed -- and the two fake
* processes (banks 1/2) alternate ONLY by each calling
* ST_YIELD_CALL ($FF00) explicitly. See
* src/test/sched.common.s for the shared machinery and
* docs/SCHED.md for the design this proves.
*
* LOADER section identical in structure to
* src/test/sched.preempt.s (see that file's header for why
* it's duplicated rather than shared).
*---------------------------------------------------------------

PTRP        equ   $E6
NBLOCKS     equ   11
            lst   off
            xc
            org   $0800
            dsk   ../../build/schedtest_coop.bin
            typ   $00

            dfb   $01

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
* MAIN PROGRAM -- block 1+. ST_MODE=1 selects the
* cooperative variant in sched.common.s's shared MAIN_ENTRY (see
* that file).
*---------------------------------------------------------------
ST_MODE equ 1

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
                                 ;(sched.common.s's shared table
                                 ;now always has both entries;
                                 ;this variant's process body
                                 ;never issues call #2, it's
                                 ;just an unused, harmless
                                 ;dispatch slot here)
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
