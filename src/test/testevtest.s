*---------------------------------------------------------------
* testevtest.s -- ProDOS-hosted acceptance gate for TEST_EVAL
* (src/bin/testeval.s, `make check-testev`). Same kernel-boot
* shape as src/test/catreadtest.s (single scheduled process in
* bank 1, real syscalls live) -- required because -f/-d/-e call
* SC_GFI, which only works inside a running maux process, not
* under bare ProDOS the way src/test/globtest.s runs (that is
* why THIS gate cannot be as light as check-glob's, despite
* testing an equally pure evaluator). testevtestb.s is the
* thin body, same split-out reason as catreadtestb.s's header.
*---------------------------------------------------------------

            lst   off
            xc
            org   $2000
            dsk   ../../build/MAUXTESTEV.SYSTEM
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
            put   testevtestb.s

* TEST_EVAL and its liba dependencies -- put HERE, right after
* PARENT_PROC's body (testevtestb.s), so they land inside
* PARENT_PROC's span: PAR_PROC_LEN (testevtestb.s's own
* `*-PARENT_PROC`) must be computed AFTER all of this, and
* merlin32 forbids a `put` nested inside a `put`ed file, so
* neither the calls nor PAR_PROC_LEN itself can live there.
            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/syscalls.s
            put   ../bin/testeval.s
* -- TEST_EVAL's cells (testeval.s). sh keeps the same list in
* -- its `dum` arena (sh.s, "TEST_EVAL cells"): there the code
* -- runs from the $D000 segment, and a syscall is never handed
* -- an address >= $D000, so the cells cannot sit by it. Here
* -- they are ordinary emitted storage after the code. Keep the
* -- two lists identical.
TE_ARGC     ds    1        ;argc, saved at entry
TE_AVBASE   ds    2        ;argv array base, saved at entry
TE_POS      ds    1        ;general-grammar token cursor
TE_OPCODE   ds    1        ;matched operator, in flight
CM_FLAGS    ds    1        ;CMP16's saved P
TE_TMPA     ds    1        ;result stash across a nested call
TE_LTOK     ds    2        ;left operand token pointer
TE_RTOK     ds    2        ;right operand token pointer
TE_LVAL     ds    2        ;left operand, parsed
TE_RVAL     ds    2        ;right operand, parsed
TE_VAL      ds    2        ;STR2NUM's own output
CM_TMPLO    ds    1        ;CMP16's difference lo
TE_V2       ds    1        ;STR2NUM's *10 scratch, 2 bytes
CM_TMPHI    ds    1        ;  ... and TE_V2+1 is its high half
TE_NEG      ds    1        ;STR2NUM's sign flag
TE_REL      ds    1        ;CMP16's relation, decoded

* -- GET_FILE_INFO parm, PCOUNT_GFI-shaped (inc/mli.equ), same
* -- field order as src/bin/ls.s's own GFIPARM. ALL `ds`:
* -- EVAL_UNARY stores the count and the path pointer before
* -- every SC_GFI, so the block needs no initial values.
TE_GFI      ds    1
TE_GFI_PATH ds    2
TE_GFI_ACC  ds    1
TE_GFI_FTYP ds    1
TE_GFI_AUX  ds    2
TE_GFI_STYP ds    1
TE_GFI_BLKS ds    2
TE_GFI_MDT  ds    2
TE_GFI_MTM  ds    2
TE_GFI_CDT  ds    2
TE_GFI_CTM  ds    2

TE_PATHBUF  ds    65       ;MLI pathname buffer, MKPATH's dest
* -- XEC_PEEK is sh's (shpath.s): test -x on a TXT reads its
* -- first line through it. No `#!` fixtures here; the
* -- real reader is gated by check-exec.
XEC_PEEK    sec
            rts
            put   ../liba/libabss.s

PAR_PROC_LEN equ   *-PARENT_PROC
