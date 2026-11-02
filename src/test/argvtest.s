*---------------------------------------------------------------
* argvtest.s -- acceptance image for the ARG_MAX byte budget
* (`make check-argv`, docs/LIMITS.md).
*
* Its own gate, as docs/LIMITS.md required, and the second case
* is the entire point: an argv exactly AT the byte ceiling must
* arrive WHOLE, and an argv ONE BYTE PAST it must ERROR rather
* than arrive short. A gate that only tests the first passes by
* accident on truncating code -- which is how ARGV_MAX_CNT's
* silent truncation survived from task #13 to 2026-08-17
* (learning:01M07V2D0T25FYD6ASCMPJYNWQ).
*
* Same shape as processtest.s: a raw SmartPort block image, no
* ProDOS involved. This gate needs spawn/wait and nothing
* else -- no files, no tty -- so the chain-loading block 0
* below is the whole bootstrap.
*
* Thin MANIFEST only; the body is argvtestb.s (real Merlin holds
* the top-level source AND the PUT file in one 41215-byte buffer
* -- learning:01M051EM2HQ3ZVJTR1W9P3G86J).
*---------------------------------------------------------------

PTRP        equ   $E6
NBLOCKS     equ   60       ;56->60 SYS_VCSTAT (the new call
                           ;plus its PCB scan grew every kernel
                           ;harness image past $7800);
                           ;54->55 sl 5+flow; 53->54 (tty9.s
                           ;DCH/IRM row-shift + xenl, tty2.s/
                           ;procfd.s); 52->53 VT102 slice 1
                           ;(tty9.s); 51->52 ser.s ttya0
                           ;(50->51 IL/DL, job-control B,
                           ;47->48 alt screen) MUST equal
                           ;($PADEND-$0800)/512 for the
                           ;sibling's `ds $5800-*` target --
                           ;one constant expressed twice.
            lst   off
            xc
            org   $0800
            dsk   ../../build/argvtest.bin
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
* -- byeres.equ / procbye.s NOT put here (2026-09-25): argvtest
* -- never calls SYS_BYE, and kdisp.s's SYS_BYE slot is wired to
* -- PRC_BYE_STUB (entry.s), not PRC_BYE directly -- see that
* -- file's K_BYE_VEC comment. Dropping the real bye/procbye.s
* -- closure (entry2/ffpage/sched/sched2/bankcopy/process/
* -- process2/procfile2-4's SHARE of it) is what fixes gap 4
* -- (docs/BYE-SLICE1.md, NOTES-BYE.md): it was never argvtest's
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

* -- Builtin spawn-image table (the kernel's PRC_SPAWN reads
* this; see -- src/kernel/process.s). Path first-character ->
* embedded image. ONE image here: 'V', the argv verifier.
K_BLTN_COUNT dfb 1
K_BLTN_TAG
            dfb   'V'
K_BLTN_SRC_LO
            dfb   <SIMG_VERIFY
K_BLTN_SRC_HI
            dfb   >SIMG_VERIFY
K_BLTN_LEN_LO
            dfb   <SIMG_VFY_END-SIMG_VERIFY
K_BLTN_LEN_HI
            dfb   >SIMG_VFY_END-SIMG_VERIFY

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
            put   ../kernel/procfork.s
            put   argvtestb.s
