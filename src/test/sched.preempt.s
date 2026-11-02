*---------------------------------------------------------------
* sched.preempt.s -- task #6 acceptance gate (`make check-
* sched`), VBL-preemption variant. Two fake processes (banks
* 1/2), neither ever yields voluntarily -- the scheduler's VBL-
* driven quantum exhaustion alone alternates them. See
* src/test/sched.common.s for the shared boot/stamp/process-body
* machinery this file `put`s in, and docs/SCHED.md for the
* design this proves.
*
* LOADER section (block 0) adapted verbatim from
* src/test/syscalltest.s's own SmartPort chain-loader -- same
* technique, same rationale (see that file's header). Not
* factored into sched.common.s: `org`/`dsk`/`typ` are top-level-
* file properties, and the loader itself must physically BE
* block 0, so duplicating this ~90-line boilerplate is simpler
* than threading it through a shared put-included file.
*---------------------------------------------------------------

PTRP        equ   $E6
NBLOCKS     equ   11                         ;generous fixed cap
            lst   off
            xc                              ;65C02 instruction
                                            ;set
            org   $0800
            dsk   ../../build/schedtest_preempt.bin
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

                                            ;(blocks 1..7, 4096
                                            ;bytes total --
                                            ;measured real usage
                                            ;~2.4KB of that, see
                                            ;docs/SCHED.md)

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
* MAIN PROGRAM -- block 1+. ST_MODE=0 selects the VBL-
* preemption variant in sched.common.s's shared MAIN_ENTRY (see
* that file).
*---------------------------------------------------------------
ST_MODE equ 0

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

            ;-- pad to NBLOCKS*512 bytes -- literal hex sum, NOT
            ;-- `NBLOCKS*512` (merlin32 note: combining a `*`
            ;MULTIPLY
            ;-- operator with the trailing `-*` CURRENT-PC token
            ;in one
            ;-- expression mis-assembled -- "Object code size >
            ;64 KB" --
            ;-- apparently the parser can't disambiguate the two
            ;`*`
            ;-- meanings in the same expression; keep this
            ;literal and
            ;-- update it by hand if NBLOCKS above changes).
            ;NBLOCKS=40 ->
            ;-- 40*512 = $5000; target = $0800+$5000 = $5800.
            ds    $1E00-*
