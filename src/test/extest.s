*---------------------------------------------------------------
* extest.s -- ProDOS-hosted `make check-ex` integration gate.
* Boots as MAUX.SYSTEM (edtest.s's own pattern -- entry.s/
* ffpage.s/sched.s/bankcopy.s/process.s installed, one parent
* process started in bank 1), and has that parent process drive
* ONE `ex` session through real fd 0/1 redirection: load a
* multi-line file via `r` (swap-backed), print it (`,p`),
* substitute one line (`s`), print again, write back (`w`), quit
* (`q`, which unlinks the swap file). See extestb.s for the
* actual script and expected content.
*---------------------------------------------------------------

            lst   off
            xc
            org   $2000
            dsk   ../../build/MAUXEXTEST.SYSTEM
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

*-- The process-call dispatch table -- one file, put exactly
*-- where the inline copy used to sit (edtest.s's own
*-- precedent).
            put   ../kernel/kdisp.s

K_IRQ_HOOK  ds    2

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
            put   extestb.s
            put   extestb2.s
            put   extestb4.s
            put   extestb5.s
            put   extestb6.s
            put   extestb7.s
            put   extestb8.s
            put   extestb9.s
            put   extestb3.s
