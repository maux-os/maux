*---------------------------------------------------------------
* playtest.s -- ProDOS-hosted interactive shell launcher (`make
* play-image`).
*
* Boots as MAUXPLAY.SYSTEM, installs the maux
* syscall/scheduler/process machinery, then starts one parent
* process whose only job is to spawn /bin/sh with no
* fdactions. Because the parent has no stdio objects,
* PRC_DFLT_FDS gives the shell fd 0/1/2 = FD_TTY0, routing
* the shell through the kernel tty driver.
*---------------------------------------------------------------

            lst   off
            xc
            org   $2000
            dsk   ../../build/MAUXPLAY.SYSTEM
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
            put   ../../inc/mm.lseg.equ
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
            put   ../../inc/byeres.equ
            put   ../../inc/sched.zp.equ
            put   ../../inc/bankprobe.equ
            put   ../../inc/mli.const.equ
            put   ../../inc/timer.equ
            put   ../../inc/proc.const.equ
            put   ../../inc/ultraterm.equ
            put   ../../inc/tty.equ

* -- KSEG (docs/KSEG.md): this manifest carries a real segment
* -- (byelaunch.s, below) -- scoped by MODULE CHOICE now
* -- (2026-09-27, coordinator review, DECISION 1): `put
* -- ../kernel/procdev.s` below (not procdevs.s) is what makes
* -- this manifest a segment-bearing one, not a variable-label
* -- override. See src/kernel/procdev.s's own header for why
* -- (`do`/`fin` is not in nas's dialect).

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
            put   ../kernel/mouse.s
            put   ../kernel/timer.s
            put   ../kernel/bankcopy.s
            put   ../kernel/process.s
            put   ../kernel/process2.s
            put   ../kernel/procfile.s
            put   ../kernel/procfile4.s
            put   ../kernel/procfile2.s
            put   ../kernel/procfile3.s
* -- byeres.bin is NOT putbin'd here any more (2026-09-25): it
* -- is DATA loaded from /mnt/MAUX/BYERES at `bye` time
* -- (procbye.s's PBY_LOAD_RES), not always-resident image
* -- bytes -- see that file's header for why.
* -- build_play_image.py stages build/byeres.bin onto the
* -- volume; play-image's own
* -- Makefile rule depends on it directly now, not through this
* -- assembly.
            put   ../kernel/procbye.s
            put   ../kernel/procfile5.s
* -- vroot.s sits HERE, where every stub manifest puts it
* -- (after procdevs.s, which follows procfile5.s): LIBK's
* -- member order is THIS file's put order, so a vroot.s at the
* -- tail would break the `-l k` run of the other 30 kernels
* -- (check-nas-librel).
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
* -- procdev.s (docs/KSEG.md, docs/DEV-BLOCK.md): the REAL
* -- kernel-cold-segment loader and /dev/sNdM glue, `put` ONLY
* -- by a manifest carrying the segment (this one). Every other
* -- full-kernel manifest puts procdevs.s (the stub) instead --
* -- see procdev.s's own header. Module choice replaces
* -- `do ]KSEG_WANT` (2026-09-27, coordinator review,
* -- DECISION 1). MOVED HERE, to the tail of the kernel put
* -- block, 2026-09-28 (check-nas-librel, item 5): procdev.s/
* -- procdevs.s share defined symbol names by design
* -- (check_modules.KNOWN_DUPLICATES), so `ld -l k`'s shared-
* -- library fixpoint scan cannot select between them by
* -- position alone -- libk_link_plan() must always name
* -- whichever one THIS manifest wants as an explicit `kmod`
* -- operand, breaking the `-l k` run at that spot. Putting
* -- procdev.s in the MIDDLE of the run (its old position, right
* -- after procfile5.s) split the run into two large pieces and
* -- blew playtest's own link line past sh's 254-char LINEMAX
* -- (276 chars, measured). Putting it at the TAIL of the run
* -- instead leaves only an EMPTY trailing piece to explode into
* -- explicit names -- the whole preceding closure still rides
* -- one `-l k`, and procdev.s costs exactly one extra `kmod`
* -- operand. Byte-neutral for the flat image (same modules,
* -- same total size, only their internal order changes) and
* -- correctness-neutral (an ordinary put module with no fall-
* -- through or physical-adjacency dependency on its neighbors).
            put   ../kernel/procdev.s

            put   playtestb.s

* -- KSEG (docs/KSEG.md "The design"): the kernel cold segment,
* -- LC bank 2 $D400-$DFFF. KSEG_LOW marks the flat output's own
* -- split point -- the raw byte offset split_kseg.py cuts at is
* -- KSEG_LOW minus this manifest's `org` -- and it MUST be the
* -- LAST thing in the manifest, with NOTHING after KSEG_END: no
* -- third `org` winding the PC back to a low address the way
* -- sh.s's own segment does. That idiom relies on the segment's
* -- bytes ALSO serving as a low-memory copy source for a
* -- runtime SEG_INIT (nothing real follows it but a `dum` bss
* -- arena, which emits no bytes) -- exactly the shape this
* -- design does NOT want: the whole point of a SEPARATE `KSEG`
* -- file (docs/KSEG.md "Why a separate file") is that these
* -- bytes never occupy any of the flat `.SYSTEM`'s own address
* -- space at all. Measured directly: putting `playtestb.s`
* -- AFTER a third `org` here left it emitting 1445 real bytes
* -- past split_kseg.py's own cut+seg_len boundary -- a corrupt
* -- image (those bytes would load at the WRONG address, since
* -- ProDOS's flat load has no per-chunk relocation) that
* -- split_kseg.py's own length assertion catches loudly rather
* -- than silently. merlin32 lays a mid-file `org` block down
* -- CONTIGUOUSLY (learning:01M2MD0W...), so the segment being
* -- the true tail is what makes the cut a plain byte slice.
KSEG_LOW
            org   KSEG_ORG
            put   ../kernel/byelaunch.s
* -- docs/KSEG.md "PRC_BYE MOVES" (coordinator review of commit
* -- 5edd6d3): PRC_BYE/PRC_RAMRECONN/PRC_RAMREDISC, moved from
* -- procbye.s -- see src/kernel/kbye.s's own header for the two
* -- rule refinements that make this legal.
            put   ../kernel/kbye.s
* -- docs/KSEG.md "Landing /dev on it": the OFT_BLK body
* -- routines (docs/DEV-BLOCK.md), moved from the flat image
* -- into
* -- the segment 2026-09-27 -- see src/kernel/kdevblk.s's own
* -- header for the full audit against the nine segment rules.
            put   ../kernel/kdevblk.s
KSEG_END
* -- LSEG (docs/LOOP-S1.md ruling 2026-10-10): the play-only low
* -- segment, main $1300-$16FF, laid down CONTIGUOUSLY after the
* -- KSEG block and cut off by split_kseg.py into MAUXPLAY_LSEG.
* -- It is the true tail of the manifest, as KSEG was.
LSEG_LOW
            org   LSEG_ORG
            put   ../kernel/loopseg.s
LSEG_END
