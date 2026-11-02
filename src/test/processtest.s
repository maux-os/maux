* See T.PROCESSTE.TXT: "processtest.s -- task #12 acceptance im"

PTRP        equ   $E6
NBLOCKS     equ   65       ;64->65 2026-10-22 (OPEN-RW-2: kernel
                           ;grew 12 B past $8800); 62->64
                           ;2026-09-25: found already
                           ;684 B over $8400 before this session
                           ;touched anything; this session's own
                           ;kernel growth (procbye.s's
                           ;PCB_SAVEDSP publish) added ~66 B
                           ;more, to 750 over -- two blocks
                           ;clears it with margin.
                           ;->62 SYS_VCSTAT (docs/COVER-OFF.md:
                           ;lazy consoles); ->61 (wake-preempt
                           ;2026-09-13)
                           ;MUST
                           ;equal ($PADEND-$0800)/512 for the
                           ;sibling's `ds $8800-*` target --
                           ;one constant expressed twice.
            lst   off
            xc
            org   $0800
            dsk   ../../build/processtest.bin
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
:sp_ok      ldx   #1
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
* MAIN PROGRAM -- block 1+.
*---------------------------------------------------------------
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
            put   ../../inc/mm.procbank.equ
            put   ../../inc/mm.procbnk2.equ
            put   ../../inc/mm.hw.equ
            put   ../../inc/mm.mli.equ
            put   ../../inc/mm.mlibuf.equ
            put   ../../inc/mm.annex.equ
            put   ../../inc/mm.annex2.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.status.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.devfd.equ
            put   ../../inc/sc.fdact.equ
            put   ../../inc/errno.krn.equ
            put   ../../inc/errno.spawn.equ
            put   ../../inc/bankcopy.equ
            put   ../../inc/entry.frame.equ
            put   ../../inc/sched.equ
            put   ../../inc/kdisp.equ
* -- byeres.equ/procbye.s NOT put here (2026-09-25): this
* -- harness never calls SYS_BYE, and kdisp.s's SYS_BYE slot is
* -- wired to PRC_BYE_STUB (entry.s), not PRC_BYE directly --
* -- see entry.s's K_BYE_VEC comment. Dropping the real
* -- procbye.s closure fixes docs/BYE-SLICE1.md's gap 4.
            put   ../../inc/sched.zp.equ
            put   ../../inc/bankprobe.equ
            put   ../../inc/mli.const.equ
            put   ../../inc/proc.const.equ
            put   ../../inc/ultraterm.equ
            put   ../../inc/tty.equ

*-- The process-call dispatch table lived HERE, copy-pasted
*-- byte-identically into 29 harnesses. It is one file now --
*-- src/kernel/kdisp.s -- so a new process call is a one-line
*-- change rather than a 29-file one. Position is load-bearing:
*-- the table emits real bytes, so it is put exactly where the
*-- inline copy used to sit.
            put   ../kernel/kdisp.s

K_IRQ_HOOK  ds    2


* -- Builtin spawn-image table (the kernel's PRC_SPAWN reads
* this; see -- src/kernel/process.s). Path first-character ->
* embedded image.
K_BLTN_COUNT dfb 8
K_BLTN_TAG
            dfb   'E','R','W','B','Q','K','C','I'
K_BLTN_SRC_LO
            dfb   <SIMG_EXIT,<SIMG_READER
            dfb   <SIMG_WRITER,<SIMG_BRK
            dfb   <SIMG_KROOT,<SIMG_KSELF
            dfb   <SIMG_CATCH,<SIMG_INHER
K_BLTN_SRC_HI
            dfb   >SIMG_EXIT,>SIMG_READER
            dfb   >SIMG_WRITER,>SIMG_BRK
            dfb   >SIMG_KROOT,>SIMG_KSELF
            dfb   >SIMG_CATCH,>SIMG_INHER
K_BLTN_LEN_LO
            dfb   <SIMG_EXIT_END-SIMG_EXIT
            dfb   <SIMG_RDR_END-SIMG_READER
            dfb   <SIMG_WRTR_END-SIMG_WRITER
            dfb   <SIMG_BRK_END-SIMG_BRK
            dfb   <SIMG_KRT_END-SIMG_KROOT
            dfb   <SIMG_KSF_END-SIMG_KSELF
            dfb   <SIMG_CAT_END-SIMG_CATCH
            dfb   <SIMG_INH_END-SIMG_INHER
K_BLTN_LEN_HI
            dfb   >SIMG_EXIT_END-SIMG_EXIT
            dfb   >SIMG_RDR_END-SIMG_READER
            dfb   >SIMG_WRTR_END-SIMG_WRITER
            dfb   >SIMG_BRK_END-SIMG_BRK
            dfb   >SIMG_KRT_END-SIMG_KROOT
            dfb   >SIMG_KSF_END-SIMG_KSELF
            dfb   >SIMG_CAT_END-SIMG_CATCH
            dfb   >SIMG_INH_END-SIMG_INHER

            put   ../kernel/entry.s
            put   ../kernel/entry2.s
            put   ../kernel/ffpage.s
            put   ../kernel/sched.s
            put   ../kernel/sched2.s
            put   ../kernel/bankcopy.s
            put   ../kernel/process.s
            put   ../kernel/process2.s
            put   ../kernel/procfile.s
            put   ../kernel/procfile4.s
            put   ../kernel/procfile2.s
            put   ../kernel/procfile3.s
            put   ../kernel/procfile5.s
            put   ../kernel/procdevs.s
            put   ../kernel/vroot.s
            put   ../kernel/ultraterm.s
            put   ../kernel/ultraterm2.s
            put   ../kernel/tty.s
            put   ../kernel/tty3.s
            put   ../kernel/tty2.s
            put   ../kernel/tty4.s
            put   ../kernel/tty5.s
            put   ../kernel/tty6.s
            put   ../kernel/tty7.s
            put   ../kernel/tty8.s
            put   ../kernel/tty9.s
            put   ../kernel/procspawn.s
            put   ../kernel/spawnbl.s
            put   ../kernel/procspawn3.s
            put   ../kernel/procspawn2.s
            put   ../kernel/procsig.s
            put   ../kernel/procsig2.s
            put   ../kernel/procfd.s
            put   ../kernel/procfd2.s
            put   ../kernel/procmli.s
            put   ../kernel/procmli3.s
            put   ../kernel/ser.s
            put   ../kernel/procmli2.s
            put   ../kernel/lazyfree.s
* -- procfork.s was PUT here (unwired) before the 2026-08-23
* -- fleet wiring, because check-dual's target IS this
* -- manifest: a kernel module no dual-assembled image contains
* -- is a kernel module real Merlin has never read. Since the
* -- wiring, K_DISP_COUNT above is 8 and SYS_FORK dispatches
* -- here exactly as in every other process-bearing image.
            put   ../kernel/procfork.s
            put   processtestb.s
            put   processtestb2.s
