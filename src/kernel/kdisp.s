*---------------------------------------------------------------
* kdisp.s -- the process-call dispatch table, in ONE place.
*
* src/kernel/entry.s is a GENERIC gate: it bounds-checks the
* call number in Y against K_DISP_COUNT and vectors through
* K_DISP_LO/K_DISP_HI, all three of which are INCLUDER-supplied
* (entry.s:133 says so). That is a good split -- the sched-only
* harnesses supply tiny tables of their own (1, 2 and 3 entries,
* dispatching test calls that have no kernel handler) and the
* gate does not care.
*
* WHAT WAS NOT GOOD was that the FULL kernel table was then
* copy-pasted into 29 separate harnesses. Verified before this
* file existed: all 29 copies were BYTE-IDENTICAL, so the
* duplication bought nothing and cost a 29-file edit for every
* new process call. This module is those 29 copies, once.
*
* PUT IT WHERE THE TABLE USED TO BE -- after the includes and
* before the `put ../kernel/*.s` chain, at the same point in the
* image. It emits real bytes (`dfb`), so its position is not
* free: moving it moves the table, and every harness's image
* layout with it.
*
* Harnesses with a DIFFERENT table (the scheduler tests, and
* testevtest's TCALL_* set) must NOT put this file -- they are
* not incomplete copies of this one, they are different tables
* for different gates. Only the 29 that carried the full kernel
* table belong here.
*
* THE INDEX IS 1-BASED. entry.s does `tax / dex` before
* indexing, so entry N is call number N, and there is no
* zero entry. A hole would be worse than an error: an unwired
* number in range vectors through whatever byte pair sits at
* that offset. That is why entry 7 is SYS_CLOCK rather than a
* gap -- see the note there.
*---------------------------------------------------------------

* -- SYS_SLPUNTIL (procfile3.s) is 26 -- docs/SLEEP-1.md.
* -- SYS_DEVLIST (procfile4.s) is 24 -- docs/DEVFS.md, `/dev`'s
* -- no-I/O device list. Appended after SYS_BYE rather than
* -- reusing a gap: every entry below it is documented as
* -- sequential by an earlier task and this file's own header
* -- warns that a HOLE is worse than a new entry.
* -- SYS_BYE (procbye.s) is 23 -- `bye`; docs/BYE-SLICE1.md.
* -- Wired to PRC_BYE_STUB (entry.s), not PRC_BYE directly
* -- (2026-09-25): this table is put by all ~32 kernel-call
* -- harnesses and this slot is a compile-time `dfb <PRC_BYE`,
* -- so unlike every OTHER conditionally-present feature in this
* -- kernel it could not omit procbye.s no matter how few
* -- harnesses ever call `bye` -- measured to be what forced
* -- nas-librel-image's link line over budget for argvtest
* -- (NOTES-BYE.md, docs/BYE-SLICE1.md's gap-4 section). See
* -- entry.s's K_BYE_VEC comment for the indirect-vector fix.
* -- SYS_HALT (procfile3.s) is 22 -- `shutdown`; it does not
* -- return, so it is the one entry whose dispatch slot exists
* -- purely to be jumped INTO.
* -- The table runs to 19: SYS_CONT (procsig.s) and SYS_WAITJOB
* -- (process2.s) are 18/19 (docs/JOB-CONTROL.md Increment B);
* -- SYS_TCSETFG (procspawn2.s, Increment A) is 17;
* -- SYS_TTYMODE (tty7.s, docs stty seed)
* -- is 16; SYS_SIGNAL/SYS_SIGPEND (procsig.s, docs/SIGNALS.md)
* -- are 14/15; SYS_KILL (procspawn2.s) is 13,
* -- SYS_TTYGEO (tty7.s) is call 12, SYS_FDSTAT (procfd2.s) 11,
* -- SYS_TICK (procfile3.s) is call 10, SYS_DUP2 (procfd2.s) is
* -- call 9, and entry 7 wires SYS_CLOCK (procfile3.s, already
* -- in the put chain) rather than leaving a hole the 1-based
* -- index would fall into.
K_DISP_LO
            dfb   <PRC_SPAWN
            dfb   <PRC_EXIT
            dfb   <PRC_WAIT
            dfb   <PRC_PIPE
            dfb   <PRC_BRK
            dfb   <PRC_PSTAT
            dfb   <PRC_CLOCK
            dfb   <PRC_FORK
            dfb   <PRC_DUP2
            dfb   <PRC_TICK
            dfb   <PRC_FDSTAT
            dfb   <PRC_TTYGEO
            dfb   <PRC_KILL
            dfb   <PRC_SIGNAL
            dfb   <PRC_SIGPEND
            dfb   <PRC_TTYMODE
            dfb   <PRC_TCSETFG
            dfb   <PRC_CONT
            dfb   <PRC_WAITJOB
            dfb   <PRC_STOP
            dfb   <PRC_VCSTAT
            dfb   <PRC_HALT
            dfb   <PRC_BYE_STUB
            dfb   <PRC_DEVLIST
            dfb   <PRC_VROOT
            dfb   <PRC_SLPUNTIL
K_DISP_HI
            dfb   >PRC_SPAWN
            dfb   >PRC_EXIT
            dfb   >PRC_WAIT
            dfb   >PRC_PIPE
            dfb   >PRC_BRK
            dfb   >PRC_PSTAT
            dfb   >PRC_CLOCK
            dfb   >PRC_FORK
            dfb   >PRC_DUP2
            dfb   >PRC_TICK
            dfb   >PRC_FDSTAT
            dfb   >PRC_TTYGEO
            dfb   >PRC_KILL
            dfb   >PRC_SIGNAL
            dfb   >PRC_SIGPEND
            dfb   >PRC_TTYMODE
            dfb   >PRC_TCSETFG
            dfb   >PRC_CONT
            dfb   >PRC_WAITJOB
            dfb   >PRC_STOP
            dfb   >PRC_VCSTAT
            dfb   >PRC_HALT
            dfb   >PRC_BYE_STUB
            dfb   >PRC_DEVLIST
            dfb   >PRC_VROOT
            dfb   >PRC_SLPUNTIL
