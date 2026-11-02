*---------------------------------------------------------------
* syscalltest.s -- task #3 acceptance gate (`make check-
* syscall`).
* Full design notes: T.SYSCALLTE.TXT (docs/a2/)
*---------------------------------------------------------------

PTRP        equ   $E6
NBLOCKS     equ   8                             ;generous fixed
            lst   off
            xc                              ;65C02 instruction
                                            ;set
            org   $0800
            dsk   ../../build/syscalltest.bin
            typ   $00

*===============================================================
* LOADER -- block 0 ($0800-$09FF). Chain-loads NBLOCKS-1 more
* blocks (fixed, sequential -- this repo's own build script
* places them there, no filesystem needed) into $0A00 onward,
* then hands off. Slot 7 SmartPort dispatch adapted from
* ~/src/malisp/src/bootblock.s's SP_INIT/SP_DISPATCH (HACKING.md
* sanctions reading/reusing sibling-repo build precedent) --
* signature-checked, not hardcoded to a bare $C703 guess, since
* the real entry offset is card-supplied (byte at $CnFF).
*===============================================================
            dfb   $01                        ;chain count (ROM
                                             ;convention,
                                             ;matches
                                             ;src/bootblock.s)

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
            ldx   #1                          ;block number,
                                              ;ascending
:rdloop     stx   BLKNO
            stz   RD_PARMS+2                  ;buffer lo --
                                              ;always page-
                                              ;aligned
            txa
            asl   a                            ;A = blockno*2
                                               ;(pages/block)
            clc
            adc   #8                           ;+$0800's own
                                               ;page
            sta   RD_PARMS+3                   ;buffer hi
            lda   BLKNO
            sta   RD_PARMS+4
            stz   RD_PARMS+5
            stz   RD_PARMS+6
            jsr   SP_DISPATCH
            dfb   $01                          ;READ_BLOCK
                                               ;command
            da    RD_PARMS
            bcc   :rdok
            lda   #'X'+$80
            sta   $0400
            jmp   *
:rdok       ldx   BLKNO
            inx
            cpx   #NBLOCKS
            bne   :rdloop

            jmp   MAIN_ENTRY                    ;-> $0A00+, the
                                                ;real program's
                                                ;boot sequence
                                                ;(defined below,
                                                ;physically
                                                ;later in this
                                                ;file -- forward
                                                ;JMP, standard
                                                ;2-pass label
                                                ;resolution)

                                                ;cap (see file-
                                                ;end `ds` pad
                                                ;note) -- blocks
                                                ;1..7 loaded,
                                                ;4096 bytes
                                                ;total image

*---------------------------------------------------------------
* SP_INIT -- verify slot 7 carries a SmartPort/block-device
* signature and compute its real dispatch entry (base + id-byte
* offset + 3), same technique as malisp's bootblock.s. No multi-
* slot scan -- this repo's rig convention (docs/TOOLCHAIN.md) is
* slot 7 for non-.woz images.
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

SP_DISPATCH lda   $C006                        ;force external
                                               ;slot ROMs
            jmp   $0000                        ;target patched
                                               ;-> SP_TARGET
SP_TARGET   equ   SP_DISPATCH+4

RD_PARMS    dfb   3
            dfb   1
            da    0
            dfb   0,0,0

BLKNO       ds    1

            ds    $0800+512-*                   ;pad block 0 to
                                                ;exactly 512B

*===============================================================
* MAIN PROGRAM -- $0A00 onward (block 1+). MAIN_ENTRY (the
* loader's real jump target) is defined later in this same
* linear assembly, after the handler/data definitions it
* references -- a plain forward JMP, safe under 2-pass assembly
* (same as any forward branch/JSR elsewhere in this tree).
*===============================================================
            put   ../../inc/mm.hw.equ
            put   ../../inc/mm.mli.equ
            put   ../../inc/mm.annex.equ
            put   ../../inc/mm.annex2.equ
            put   ../../inc/mm.main.equ
                                  ;K_STACK_FLOOR -- no code
                                  ;here references it, but
                                  ;scripts/check_syscall.py's
                                  ;check_stack_floor() greps
                                  ;this assembly's own
                                  ;Output.txt listing for it
            put   ../../inc/bankcopy.equ
            put   ../../inc/entry.frame.equ
            put   ../../inc/sched.equ
            put   ../../inc/bankprobe.equ
            put   ../../inc/mli.const.equ
            put   ../../inc/ultraterm.equ
            put   ../../inc/errno.krn.equ

* -- entry.s preconditions (docs/kernel/entry.s header): a
* dispatch -- table (1-based call numbers) and an IRQ service
* hook, both defined -- BEFORE `put`ting entry.s in. --
K_DISP_COUNT equ  3          ;TCALL_ECHO, TCALL_ARITH,
                                 ;TCALL_REPORT
K_IRQ_HOOK       ds   2          ;filled at boot init with
                                 ;MOUSE_ISR's address

            put   ../kernel/entry.s
            put   ../kernel/entry2.s

* -- ffpage.s precondition: KRN_ENTRY/KRN_IRQ_ENTRY are
* already -- real labels, defined by the entry.s put above. --
            put   ../kernel/ffpage.s
            put   syscalltestb.s
