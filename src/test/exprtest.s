*---------------------------------------------------------------
* exprtest.s -- the `expr` acceptance gate (`make check-expr`).
* Boots the maux kernel + a hardwired parent process
* (exprtestb.s), same skeleton as src/test/testevtest.s.
*
* A 37-row case table calls EXPR_EVAL/EXPR_EXITCD DIRECTLY
* (src/bin/expr.eval.s, `put` below), same shape as
* check-testev's own gate against TEST_EVAL -- covers every
* operator, both outcomes per comparison, precedence both
* directions, the four exit statuses (0/1/2/3), overflow, and
* division/modulo by zero, entirely on real 6502.
*
* Phase 2 (exprtestb.s's PARENT_PROC, after the case table):
* the real EXPR binary's own top-level I/O glue (argv->PUTC/
* PUTS/PRNUM->EXIT), spawned DIRECTLY (no `sh` -- it has no
* quoting yet and cannot pass a literal `*`), stdout redirected
* to a capture file. A first attempt at this phase hit a
* file-syscall ERR_INVAL that wasn't pinned down at the time and
* was dropped; the root cause (CWD_READ, src/kernel/sched.s,
* never selected aux bank 0 before reading the shared per-pid
* cwd table -- see that routine's header) has since been found
* and fixed, and this rebuilt phase is the gate that proves it:
* SPAWN succeeds and the captured stdout reads "6" (2*3, the
* literal `*` surviving without `sh`). `expr.bin` is also a real
* ProDOS BIN, spawnable by other gates going forward.
*---------------------------------------------------------------

            lst   off
            xc
            org   $2000
            dsk   ../../build/MAUXEXPR.SYSTEM
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
            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/mli.equ

            jmp   ENTRY

*-- The process-call dispatch table lived HERE, copy-pasted
*-- byte-identically into 29 harnesses. It is one file now --
*-- src/kernel/kdisp.s -- so a new process call is a one-line
*-- change rather than a 29-file one. Position is load-bearing:
*-- the table emits real bytes, so it is put exactly where the
*-- inline copy used to sit.
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
            put   exprtestb.s

* EXPR_EVAL/EXPR_EXITCD and their liba dependencies -- put HERE,
* right after PARENT_PROC's body (exprtestb.s), so they land
* inside PARENT_PROC's span: PAR_PROC_LEN (exprtestb.s's own
* `*-PARENT_PROC`) must be computed AFTER all of this, and
* merlin32 forbids a `put` nested inside a `put`ed file, so
* neither the calls nor PAR_PROC_LEN itself can live there --
* same reason testevtest.s puts TEST_EVAL's dependencies here.
            put   ../liba/string.s
* -- stdio.s, stdiofl.s and print.s are NOT linked (KSPACE2,
* -- 2026-10-11): num.s's PRNUM is the only thing that reached
* -- PUTS -> SIO_PUTC, this harness never calls PRNUM (Phase 1
* -- calls EXPR_EVAL/EXPR_EXITCD, which use U2DEC only; Phase 2
* -- spawns the real expr.bin), and the three modules were 811 B
* -- of unreachable text. PUTS is a stub for num.s to resolve.
            put   ../liba/num.s
* -- liba/mli.s IS NOT HERE ANY MORE (2026-08-24). MKPATH and
* -- its three helpers are the whole module and NOTHING in this
* -- image referenced any of them -- not exprtestb.s, not
* -- expr.eval.s, not the four liba modules above. It was ~600
* -- bytes of dead text in the image the check_kernel_images
* -- ratchet calls its WORST overrun, and that ratchet's own
* -- note said the right question at the third liba change was
* -- "should exprtest.s still be carrying a put/use chain this
* -- size at all" rather than "what is the new number". This is
* -- that answer. liba/mli.EQU stays -- it is an equate file the
* -- kernel modules above need.
            put   ../liba/syscalls.s
            put   ../bin/expr.eval.s
            put   ../bin/expr.ops.s
* -- EX_COL is the `:` level (src/bin/expr.match.s), which links
* -- the BRE engine and has no business in a kernel-image test.
* -- A stub that falls straight through to the operand keeps
* -- this harness's rows exactly what they were (`:` is covered
* -- by check-posixutil's expr rows).
EX_COL      jmp   EX_PRIM
PUTS        rts                 ;num.s PRNUM, never run
            put   ../liba/libabss.s

PAR_PROC_LEN equ   *-PARENT_PROC
