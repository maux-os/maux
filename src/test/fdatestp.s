*---------------------------------------------------------------
* fdatestp.s -- acceptance image for the spawn fdactions list
* (`make check-fdact`, docs/DUPFD-1.md phase K).
*
* WHAT IT IS FOR. PRC_SPAWN judges the WHOLE fdactions list
* before anything exists (procfile2.s PRC_FDA_CHECK): a dup from
* a fd the caller does not have open, an fd >= 8, an unknown
* opcode, an unreadable list byte, or a list with no END inside
* 32 records fails the spawn ERR_INVAL with no bank, no pid, no
* refcount and no LZ_WANT left behind. This image spawns lists
* that are bad in each way, from a process, and the gate reads
* the kernel's own cells before and after.
*
* The PLAIN twin of fdatest.s (spawnpl.s, no builtin images):
* the same body, the same bad lists, but no positive list and no
* final good spawn -- there is no file to load in a raw image.
* PRC_FDA_CHECK sits ABOVE the PRC_BLTN hook, so both twins must
* refuse; this proves it on the one nobody can spawn a child on.
*
* Thin MANIFEST only; the body is fdatestb.s (shared).
*---------------------------------------------------------------

PTRP        equ   $E6
SLOT7_PG    equ   $C7      ;the SmartPort card's page
FDA_NPOS    equ   0        ;positive lists to spawn (0 = none)
NBLOCKS     equ   64       ;MUST equal ($PADEND-$0800)/512 for
                           ;fdatestb.s's `ds $8800-*` target --
                           ;one constant expressed twice.
            lst   off
            xc
            org   $0800
            dsk   ../../build/fdatestp.bin
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
            lda   #SLOT7_PG
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
* -- byeres.equ / procbye.s NOT put here (2026-09-25): like
* -- argvtest, this image never calls SYS_BYE, and kdisp.s's
* -- SYS_BYE slot is wired to
* -- PRC_BYE_STUB (entry.s), not PRC_BYE directly -- see that
* -- file's K_BYE_VEC comment. Dropping the real bye/procbye.s
* -- closure (entry2/ffpage/sched/sched2/bankcopy/process/
* -- process2/procfile2-4's SHARE of it) is what fixes gap 4
* -- (docs/BYE-SLICE1.md, NOTES-BYE.md): it was never this
* harness's
* -- own need for `bye`, only kdisp.s's compile-time reference,
* -- that pulled all of that into this harness's link closure.
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

* -- No builtin-image table: spawnpl.s needs none (forktest's
* shape). SIMG_FDA stays in the body, unreferenced.

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
            put   ../kernel/spawnpl.s
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
            put   ../kernel/procfork.s
            put   fdatestb.s
