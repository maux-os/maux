*---------------------------------------------------------------
* envtest.s -- ProDOS-hosted ENVIRONMENT gate (`make check-env`,
* docs/SYSCALL.md item 13c). Boots `sh` from disk with fd 0
* redirected from a staged script, exactly as shtest.s does, and
* lets the script itself produce every observable: `export`ed
* and unexported variables through a spawned probe's getenv, and
* command resolution through PATH and through PATHTAB's
* fallback. Manifest only -- the body is envtestb.s.
*---------------------------------------------------------------

            lst   off
            xc
            org   $2000
            dsk   ../../build/MAUXENV.SYSTEM
            typ   $FF
KBSS        equ   $0A00        ;kernel scratch home
            put   ../../inc/mm.kbss.equ

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
            put   ../../inc/sc.fd.equ
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

            jmp   ENTRY

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
K_BLTN_COUNT dfb 3
K_BLTN_TAG
            dfb   'E','R','W'
K_BLTN_SRC_LO
            dfb   <SIMG_EXIT,<SIMG_READER
            dfb   <SIMG_WRITER
K_BLTN_SRC_HI
            dfb   >SIMG_EXIT,>SIMG_READER
            dfb   >SIMG_WRITER
K_BLTN_LEN_LO
            dfb   <SIMG_EXIT_END-SIMG_EXIT
            dfb   <SIMG_RDR_END-SIMG_READER
            dfb   <SIMG_WRTR_END-SIMG_WRITER
K_BLTN_LEN_HI
            dfb   >SIMG_EXIT_END-SIMG_EXIT
            dfb   >SIMG_RDR_END-SIMG_READER
            dfb   >SIMG_WRTR_END-SIMG_WRITER

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
            put   envtestb.s
