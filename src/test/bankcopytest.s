*---------------------------------------------------------------
* bankcopytest.s -- task #4 PRIMARY GATE (`make check-
* bankcopy`): the 2x2x2 {80STORE, PAGE2, HIRES} incoming-state
* matrix.
* Full design notes: T.BANKCOPYT.TXT (docs/a2/)
*---------------------------------------------------------------

PTRP        equ   $E6
NBLOCKS     equ   8                             ;matches build_m
            lst   off
            xc                              ;65C02 instruction
                                            ;set
            org   $0800
            dsk   ../../build/bankcopytest.bin
            typ   $00

*===============================================================
* LOADER -- block 0 ($0800-$09FF). Verbatim structure from
* src/test/syscalltest.s's own LOADER (same SmartPort chain-load
* technique, adapted from ~/src/malisp/src/bootblock.s --
* HACKING.md sanctions reusing sibling/in-tree build precedent).
* NBLOCKS below is this file's own total; nothing else differs.
*===============================================================
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

                                                ;ultiblock_
                                                ;image.py's
                                                ;total_blocks
                                                ;arg in the
                                                ;Makefile

*---------------------------------------------------------------
* SP_INIT/SP_DISPATCH -- slot 7 SmartPort signature check +
* dispatch, identical to syscalltest.s's own (see that file's
* header for the malisp-derived rationale).
*---------------------------------------------------------------
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

            ds    $0800+512-*                   ;pad block 0 to
                                                ;512B

*===============================================================
* MAIN PROGRAM -- $0A00 onward (block 1+).
*===============================================================
KBSS        equ   $0A00        ;kernel scratch home
            put   ../../inc/mm.kbss.equ
* -- KSPACE: this raw image owns $0800 up, so its scratch
* -- home is reserved INSIDE it, right after block 0, at the
* -- same KBSS=$0A00 as every other image (the block-0 pad
* -- above ends the code at $0A00). After the equ: a forward
* -- EQU in a ds is a silent miscompile. Literal size and no
* -- `ds KBSS-*`: the native build cuts this file into segments
* -- that do not all see mm.kbss.equ; `*` is module-relative.
            ds    1520      ;check-kbss: chain length
            put   ../../inc/mm.hw.equ
            put   ../../inc/mm.annex.equ
            put   ../../inc/mm.annex2.equ
            put   ../../inc/bankcopy.equ
            put   ../../inc/entry.frame.equ
            put   ../../inc/sched.equ
            put   ../../inc/bankprobe.equ
            put   ../../inc/mli.const.equ
            put   ../../inc/ultraterm.equ
            put   ../../inc/errno.krn.equ

* -- entry.s preconditions: this harness never calls
* KRN_ENTRY or -- takes an IRQ, so these are inert stubs, not
* real tables. --
K_DISP_COUNT equ  1
K_DISP_LO    ds   1
K_DISP_HI    ds   1
K_IRQ_HOOK       ds   2

            put   ../kernel/entry.s
            put   ../kernel/entry2.s
            put   ../kernel/bankcopy.s
            put   bankcopytestb.s
