*---------------------------------------------------------------
* sched.s -- O(1) two-queue round-robin scheduler (task #6,
* docs/SCHED.md).
* Full design notes: K.SCHED.TXT (docs/a2/)
*---------------------------------------------------------------

K_SW_OUTPTR equ   $E2        ;2  outgoing PCB pointer, cached
                             ;across the RAMRD/RAMWRT bracket in
                             ;SCH_SWITCH
K_SW_INPTR  equ   $E4        ;2  incoming PCB pointer, ditto
K_SW_OUTSP  equ   $E6        ;1  outgoing process's captured SP
                             ;(from K_CALLER_SP -- cached BEFORE
                             ;the bracket)
K_SW_INSP   equ   $E7        ;1  incoming process's saved SP,
                             ;read from its PCB inside the
                             ;bracket
K_SW_INBANK equ   $E8        ;1  incoming process's PCB_BANK,
                             ;ditto
* K_SW_OUTPID moved to inc/sched.equ ($E9): entry.s's
* KRN_EXIT reads it (the caller whenever a handler ran its own
* SCH_SWITCH) without pulling in the rest of this file -- same
* reason K_CURBANK was tried and reverted; see entry.s.
K_SW_INPID  equ   $EA        ;1  incoming pid (RUNQ_POP's
                             ;result)
K_PCB_TMP   equ   $EB        ;1  PCB_PTR_FOR scratch
K_PCB_TMP2  equ   $EE        ;1  PCB_RD_FIELDS scratch (field
                             ;offset)

* -- ordinary main memory (module-placed `ds`, same idiom as
* entry.s's -- K_CALLER_SP/K_CALLNUM). None of these are ever
* touched from INSIDE a -- RAMRD/RAMWRT=aux bracket (see the
* discipline note above) -- that is -- precisely what keeps them
* safe as plain absolute addresses. --
*-- TIMER STATE, moved here from src/kernel/timer.s on
*-- 2026-08-25 (see that file's note). The DRIVER is still
*-- there; these are declared here because SYS_TICK made them
*-- shared -- kdisp.s is linked by 29 kernel harnesses and
*-- timer.s by four, and K_VBL_TICKS was already the
*-- scheduler's clock (K_WAKE_TICK is compared against it).
*-- Mode 0 means "unprobed", which is also what a harness with
*-- no timer driver linked correctly reports.
K_TIMER_FORCE  ds    1

K_TIMER_MODE   ds    1        ;0 = unprobed; see TIMER_MODE_*
                              ;below
K_VBL_TICKS    ds    4        ;serviced-tick counter -- the
                              ;stale-VBL non-re-entry
                              ;regression test,
                              ;docs/SYSCALL.md #7.5, checks this
                              ;against the expected rate, not
                              ;just "nonzero"
* -- WIDENED 2 -> 4 BYTES on 2026-08-25 for SYS_TICK. 16 bits at
* -- 60 Hz wraps every ~18.2 MINUTES, which is fine for `sleep`
* -- and wrong for `time`. Widened HERE rather than teaching
* -- every consumer to detect wrap: there is one incrementer per
* -- interrupt path and there will be many consumers.
* -- The low two bytes keep their meaning exactly, so
* -- src/test/sched.common.s and scripts/check_sched.py, which
* -- both read 2 bytes, are unaffected.

K_CURPID       ds  1         ;pid of the RUNNING process
K_CURBANK      ds  1         ;its PCB_BANK (PRC_SEL_CRBNK)
                             ;(PCB_STATE= PCB_RUNNING there); 0
                             ;(bank 0, never a process) only
                             ;before SCH_START runs
K_QUANTUM      ds  1         ;ticks remaining in the running
                             ;process's current timeslice;
                             ;SCH_TICK decrements
K_SCHD_RQ ds 1         ;SCH_SWITCH's own parameter cache
                             ;(0 = outgoing is blocking, don't
                             ;requeue; nonzero = outgoing stays
                             ;runnable, requeue at tail)
K_IDLE_PID ds 1        ;the boot image's idle process (0 =
                             ;none): SCH_SWITCH dispatches it
                             ;ONLY when nothing else is queued
                             ;-- as an ordinary pid it took
                             ;every other quantum, half the
                             ;machine (2026-09-14, SCHED.md 9)
*-- K_WAIT_SHD: PCB_COUNT B homed in KBSS (mm.kbss.equ).
                             ;per pid: wait channel while the
                             ;PCB is BLOCKED, else 0 (WAKE-1).
                             ;Main memory: SCH_WAKEUP scans it,
                             ;not the annex. EVERY store into
                             ;or out of BLOCKED writes it:
                             ;SCH_SLEEP, SCH_WAKEUP, PRC_SIG_
                             ;SND, PRC_ZOMB, the ^Z sweep
                             ;(docs/WAKE-1-NOTES.md sec 4)
K_PAR_SHD  ds PCB_COUNT+1    ;per pid: its PCB_PARENT while the
                             ;slot is occupied, 0 while it is
                             ;free (WAIT-1). REVERSED: pid p is
                             ;in cell 48-p (PAR_CELL), so the
                             ;wait scan is a plain dex/bne and
                             ;descending cells are ASCENDING
                             ;pids. No biased index: a flat ds
                             ;less a constant is no absolute in
                             ;the native build (SLEEP-1-NOTES
                             ;sec 3). Cells 1-48 are used (48 is
                             ;pid 0, never a child). Main RAM,
                             ;FLAT: the KBSS chain is full at
                             ;$0FF0. PRC_WAIT_CORE filters on
                             ;it, then re-reads the annex PCB.
                             ;Writers: SCH_INIT (zero), PPCB_WR_
                             ;PAR (spawn, fork), PRC_REAP_ONE
                             ;(clear). docs/WAIT-1-NOTES.md
K_TICK_HOOK    ds  2         ;optional per-tick poll hook.
                             ;Defaults to a no-op; process.s
                             ;installs TTY_POLL when a tty-
                             ;backed image wants keyboard
                             ;wakeups.
K_INTR_PEND    ds  1         ;^C seen: the typing CONSOLE+1,
                             ;0 = none (set by the tty from ANY
                             ;poll context, incl. the mid-MLI
                             ;shim); consumed by SCH_TICK's
                             ;sweep dispatch, which hands the
                             ;value to the hook in A
K_INTR_HOOK    ds  2         ;the sweep (PRC_INTR_SWP in
                             ;process-bearing images; clc stub
                             ;default). Returns carry set =
                             ;current process was killed
K_STOP_PEND    ds  1         ;^Z seen (docs/JOB-CONTROL.md
                             ;Increment B): the typing CONSOLE
                             ;+1, 0 = none -- K_INTR_PEND's
                             ;twin, set by tty3.s TTY_STOP,
                             ;consumed by SCH_TICK
K_STOP_HOOK    ds  2         ;the suspend sweep (PRC_STOP_SWP;
                             ;clc stub default). Carry set =
                             ;the current process was STOPPED,
                             ;so SCH_TICK switches away without
                             ;requeueing it
K_WAKE_PEND    ds  1         ;nonzero = SCH_WAKEUP made >=1
                             ;process runnable since the last
                             ;tick; SCH_TICK switches to a woken
                             ;process THIS tick instead of
                             ;letting the current one finish its
                             ;quantum (wake preemption -- an
                             ;I/O-woken process, e.g. vi after a
                             ;keystroke, must not wait up to a
                             ;full QUANTUM_TICKS behind whatever
                             ;is running, incl. a spinning idle
                             ;process; docs/CONSOLE-LATENCY.md
                             ;sec 5 item 1). SCH_TICK clears.
                             ;Never set with K_NOSWITCH honoured
                             ;first, so an in-syscall wake just
                             ;defers to the next safe tick.
K_SLP_ARM      ds  1         ;nonzero = K_SLP_DL holds a pending
                             ;sleep deadline (SLEEP-1). Set by
                             ;PRC_SLPUNTIL, cleared by the tick
                             ;hook's wake; zeroed by SCH_INIT
K_NOSWITCH     ds  1         ;nonzero = a non-reentrant kernel
                             ;critical section is live;
                             ;SCH_TICK must NOT preempt.
                             ;process.s's MLI wrappers own this
                             ;flag -- see SCH_TICK's comment
                             ;for why the ProDOS MLI makes it
                             ;load-bearing rather than advisory.
K_SW_COUNT ds  2         ;diagnostic: total successful
                             ;SCH_SWITCH completions (not
                             ;SCH_START) -- docs/ SCHED.md's
                             ;measured cycle-budget numbers and
                             ;check-sched's fairness assertion
                             ;both read this via peek, not
                             ;printed by this kernel
*-- K_CWD_BUF: CWD_ENT_SIZE B (cwd staging, main side) homed
*-- in KBSS (inc/mm.kbss.equ), KSPACE2.
K_PCB_SCRATCH  ds  7         ;PCB_RD_FIELDS landing buffer. 7:
                             ;PRC_PSTAT reads PID..EXITSTAT in
                             ;one go (PS-ARGS); procsig SIG rows
                             ;are 6 and RUNQ follows -- 4
                             ;overran it (SIGNALS).
                             ;(main-side half of the
                             ;COPYIN_ENTRY call -- see that
                             ;routine). Read via ordinary LDA
                             ;AFTER COPYIN_ENTRY returns (RAMRD
                             ;is back to main by then) -- never
                             ;touched while RAMRD=aux

QUANTUM_TICKS  equ   4       ;timer ticks per process timeslice
                             ;-- a judgment call (docs/SCHED.md
                             ;cites the measured cycle budget
                             ;this implies); small enough that
                             ;check-sched's step budget sees
                             ;many switches without an excessive
                             ;VBL count

RUNQ_CAP    equ   PCB_COUNT+1  ;49 -- the classic circular-
                               ;buffer "N+1 slots for N items"
                               ;trick: head==tail means EMPTY
                               ;unambiguously, at the cost of
                               ;one slot never holding a live
                               ;entry. PCB_COUNT (48) already
                               ;includes bank 0 (never a
                               ;process, so at most 47 pids are
                               ;EVER concurrently schedulable)
                               ;-- 49 slots is never exercised
                               ;past 47 in correct operation,
                               ;comfortable headroom, not a
                               ;tight fit
K_CWD_PTR   equ   $EF        ;2  computed cwd-table pointer
K_CWD_TMP   equ   $F1        ;1  CWD_PTR_FOR scratch

PCB_ARRY_ADDR equ   ANNEX_STRCT_A  ;docs/MEMMAP.md #2.2: the
                                      ;PCB array is the first
                                      ;structure in the annex's
                                      ;$0800-$1FFF region, in
                                      ;aux bank 0; this borrows
                                      ;the soft page-2 reserve
                                      ;only

* -- run queue: circular array of pids + head/tail (module-
* placed `ds`, -- same "no fixed address yet, K_CODE_C's
* placement is link-order" -- reasoning as bankprobe.s's
* FREELIST/FREECOUNT). --
RUNQ        ds    RUNQ_CAP   ;49 bytes
RUNQ_HEAD   ds    1
RUNQ_TAIL   ds    1

* See K.SCHED.TXT: "SCH_INIT -- boot-time setup. Zeroes the"
SCH_INIT  stz   RUNQ_HEAD
            stz   RUNQ_TAIL
            stz   K_IDLE_PID
            stz   K_CURPID
            stz   K_CURBANK
            stz   K_QUANTUM
            stz   K_SWITCH
            stz   K_NOSWITCH
            lda   #<STICK_HK_NOP
            sta   K_TICK_HOOK
            lda   #>STICK_HK_NOP
            sta   K_TICK_HOOK+1
            stz   K_INTR_PEND
            stz   K_WAKE_PEND
            stz   K_SLP_ARM
            lda   #<SINTR_HK_NOP
            sta   K_INTR_HOOK
            lda   #>SINTR_HK_NOP
            sta   K_INTR_HOOK+1
            stz   K_STOP_PEND                ;^Z twin -- same
            lda   #<SINTR_HK_NOP             ;clc stub until a
            sta   K_STOP_HOOK                ;process-bearing
            lda   #>SINTR_HK_NOP             ;image installs
            sta   K_STOP_HOOK+1              ;PRC_STOP_SWP

            lda   #0
            sta   BANKSEL                    ;annex is always
                                             ;bank 0
            sta   RAMWRTAUX                   ;only WRITING
                                              ;PCB_STATE here
            ldx   #0                          ;X = pid under
                                              ;init, 0..47 --
                                              ;register, not
                                              ;memory, per the
                                              ;KERNEL-DATA-READ
                                              ;DISCIPLINE inside
                                              ;this bracket
:loop       txa
            jsr   PCB_PTR_FOR                  ;-> K_PCB_PTR
                                               ;(pure kernel-
                                               ;side arithmetic,
                                               ;safe to call
                                               ;from inside the
                                               ;bracket --
                                               ;touches only
                                               ;registers/ZP, no
                                               ;absolute main-
                                               ;memory reads)
            lda   #PCB_UNUSED
            ldy   #PCB_STATE
            sta   (K_PCB_PTR),y
            inx
            cpx   #PCB_COUNT
            bne   :loop
            sta   RAMWRTMAIN                   ;A is PCB_UNUSED
                                               ;(0) here --
                                               ;irrelevant,
                                               ;switch triggers
                                               ;on address
            ldx   #PCB_COUNT              ;nobody is BLOCKED
:zshd       stz   K_WAIT_SHD-1,x          ;main: AFTER bracket
            stz   K_PAR_SHD,x             ;no slot has a parent
            dex
            bne   :zshd
            rts

*---------------------------------------------------------------
* PAR_CELL -- A = pid -> A = X = its K_PAR_SHD cell, 48 - pid.
* Its own inverse: A = cell -> A = X = pid. Clobbers A, X, C.
*---------------------------------------------------------------
PAR_CELL    eor   #$FF                    ;~A + 49 = 48 - A
            clc
            adc   #PCB_COUNT+1
            tax
            rts

* See K.SCHED.TXT: "PCB_PTR_FOR -- A = pid (0-47). Sets"
PCB_PTR_FOR sta   K_PCB_TMP
            stz   K_PCB_PTR+1
            lda   K_PCB_TMP
            sta   K_PCB_PTR
            asl   K_PCB_PTR
            rol   K_PCB_PTR+1
            asl   K_PCB_PTR
            rol   K_PCB_PTR+1
            asl   K_PCB_PTR
            rol   K_PCB_PTR+1
            asl   K_PCB_PTR
            rol   K_PCB_PTR+1
            clc
            lda   K_PCB_PTR
            adc   #<PCB_ARRY_ADDR
            sta   K_PCB_PTR
            lda   K_PCB_PTR+1
            adc   #>PCB_ARRY_ADDR
            sta   K_PCB_PTR+1
            rts

* See K.SCHED.TXT: "PCB_RD_FIELDS -- A = field offset (within"
*---------------------------------------------------------------
* CWD_PTR_FOR -- A = pid, K_CWD_PTR = that entry in the annex
* cwd table. Same shape as PCB_PTR_FOR but a 64-byte stride.
*---------------------------------------------------------------
CWD_PTR_FOR sta   K_CWD_TMP
            stz   K_CWD_PTR+1
            lda   K_CWD_TMP
            sta   K_CWD_PTR
            ldx   #6                   ;x64
:sh         asl   K_CWD_PTR
            rol   K_CWD_PTR+1
            dex
            bne   :sh
            clc
            lda   K_CWD_PTR
            adc   #<CWD_TBL_ADDR
            sta   K_CWD_PTR
            lda   K_CWD_PTR+1
            adc   #>CWD_TBL_ADDR
            sta   K_CWD_PTR+1
            rts

*---------------------------------------------------------------
* CWD_READ -- copy pid A's cwd entry into K_CWD_BUF.
* Must go through COPYIN_ENTRY: an annex READ cannot be done
* inline, because RAMRD governs instruction fetch too.
*
* MUST select aux bank 0 before reading: the cwd table is a
* FIXED shared location in bank 0, but COPYIN_ENTRY's aux read
* is governed by RAMRD, not by BANKSEL -- which stays sticky
* from whichever process last ran. Without this it read the
* CALLING PROCESS's own bytes as a cwd. Latent for months
* because every harness image was too small to have written
* past bank 1's $6040. Full account: docs/CWD-BANK-BUG.md.
*---------------------------------------------------------------
CWD_READ    jsr   CWD_PTR_FOR
            lda   #0
            sta   BANKSEL
            lda   K_CWD_PTR
            sta   K_CPY_PROC
            lda   K_CWD_PTR+1
            sta   K_CPY_PROC+1
            lda   #<K_CWD_BUF
            sta   K_CPY_MAIN
            lda   #>K_CWD_BUF
            sta   K_CPY_MAIN+1
            lda   #CWD_ENT_SIZE
            sta   K_CPY_LEN
            jmp   COPYIN_ENTRY

*---------------------------------------------------------------
* CWD_WRITE -- copy K_CWD_BUF into pid A's cwd entry.
* A WRITE may be done inline (RAMWRTAUX moves stores only; the
* fetch stream stays in main), which is why SCH_CREATE writes
* PCB fields the same way.
*---------------------------------------------------------------
CWD_WRITE   jsr   CWD_PTR_FOR
            lda   #0
            sta   BANKSEL
            sta   RAMWRTAUX
            ldy   #0
:cp         lda   K_CWD_BUF,y
            sta   (K_CWD_PTR),y
            iny
            cpy   #CWD_ENT_SIZE
            bne   :cp
            sta   RAMWRTMAIN
            rts

PCB_RD_FIELDS
            sta   K_PCB_TMP2
            clc
            lda   K_PCB_PTR
            adc   K_PCB_TMP2
            sta   K_CPY_PROC
            lda   K_PCB_PTR+1
            adc   #0
            sta   K_CPY_PROC+1
            lda   #<K_PCB_SCRATCH
            sta   K_CPY_MAIN
            lda   #>K_PCB_SCRATCH
            sta   K_CPY_MAIN+1
            stx   K_CPY_LEN
            jmp   COPYIN_ENTRY

* See K.SCHED.TXT: "RUNQ_PUSH (A = pid) / RUNQ_POP (-> A ="
RUNQ_PUSH   ldx   RUNQ_TAIL
            sta   RUNQ,x
            inc   RUNQ_TAIL
            lda   RUNQ_TAIL
            cmp   #RUNQ_CAP
            bne   :nowrap
            stz   RUNQ_TAIL
:nowrap     rts

RUNQ_POP    lda   RUNQ_HEAD
            cmp   RUNQ_TAIL
            beq   :empty
            tax
            lda   RUNQ,x
            pha
            inc   RUNQ_HEAD
            lda   RUNQ_HEAD
            cmp   #RUNQ_CAP
            bne   :nowrap
            stz   RUNQ_HEAD
:nowrap     pla
            rts
:empty      lda   #0
            rts

* See K.SCHED.TXT: "SCH_CREATE -- A = pid, X = physical aux"
SCH_CREATE
            sta   K_SW_INPID
            stx   K_SW_INBANK
            jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            sta   RAMWRTAUX
            lda   K_SW_INPID
            ldy   #PCB_PID
            sta   (K_PCB_PTR),y
            lda   #PCB_RUNNABLE
            ldy   #PCB_STATE
            sta   (K_PCB_PTR),y
            lda   #0
            ldy   #PCB_WCHAN
            sta   (K_PCB_PTR),y
            lda   K_SW_INBANK
            ldy   #PCB_BANK
            sta   (K_PCB_PTR),y
            lda   #0
            ldy   #PCB_PARENT
            sta   (K_PCB_PTR),y
            lda   #$F9                        ;docs/SYSCALL.md
                                              ;item 11: SP after
                                              ;a synthesized
                                              ;6-byte trapframe
                                              ;($FF-6)
            ldy   #PCB_SAVEDSP
            sta   (K_PCB_PTR),y
            lda   #0
            ldy   #PCB_EXITSTAT
            sta   (K_PCB_PTR),y
            ldy   #PCB_BRK
            sta   (K_PCB_PTR),y
            ldy   #PCB_FDTABLE
:fdclr      sta   (K_PCB_PTR),y
            iny
            cpy   #PCB_FDTABLE+8
            bne   :fdclr
            sta   RAMWRTMAIN                   ;A=0 here,
                                               ;irrelevant
*-- zero the pid's SIG_TBL row (SIGNALS.md). After PCB writes.
            lda   K_SW_INPID
            jsr   PRC_SIG_ZRO

            lda   K_SW_INPID
            jsr   RUNQ_PUSH                     ;outside the
                                                ;bracket --
                                                ;ordinary kernel
                                                ;memory
            rts

* See K.SCHED.TXT: "SCH_START -- no arguments. Pops the first"
* runnable pid, marks it RUNNING and falls into SCH_DISPATCH.
SCH_START jsr   RUNQ_POP
            sta   K_SW_INPID
            jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            ;-- mark it RUNNING -- write-only bracket, safe
            ;inline
            ;-- (RAMWRT does not gate instruction fetch).
            ;BANKSEL is
            ;-- still 0 (annex) from above -- COPYIN_ENTRY never
            ;touches
            ;-- it. --
            sta   RAMWRTAUX
            lda   #PCB_RUNNING
            ldy   #PCB_STATE
            sta   (K_PCB_PTR),y
            sta   RAMWRTMAIN                    ;A=PCB_RUNNING,
                                                ;irrelevant
            bra   SCH_DISPATCH

* SCH_RESUME -- no arguments. `bye`'s return path
* (src/kernel/procbye.s): K_CURPID is already RUNNING and
* already off the run queue -- the process that called SYS_BYE
* was never blocked or requeued while the machine was away, so
* there is no RUNQ_POP and no PCB_STATE write (both would be
* redundant: the state never changed). Falls into the SAME
* SCH_DISPATCH tail SCH_START uses -- docs/BYE-SLICE1.md is
* explicit that this must be shared, not copied.
*
* NOT the console-reassert call site (2026-09-27 false start,
* see docs/BYE-SLICE1-NOTES.md): a `jsr TTY_HW_SET` was tried
* HERE first, since this routine really is bye's own dedicated
* return path -- but sched.s is `put` by every image that has a
* scheduler, including the three schedtest harnesses
* (sched.coop.s/sched.wake.s/sched.preempt.s), which link
* NEITHER tty7.s NOR procbye.s. merlin32 assembles this
* routine's body unconditionally regardless of whether it is
* ever CALLED, so a direct reference to TTY_HW_SET here is an
* undefined-symbol error in those three builds -- confirmed by
* actually rebuilding schedtest_coop.bin, not just running
* check-modules (which only checks staleness/boundaries, never
* re-assembles). The call belongs where only bye-capable images
* ever assemble it: see BYE_TTYRES (tty7.s), reached via
* BB_RESVEC's own stamp in procbye.s -- SCH_RESUME itself stays
* exactly as it always was, with the ONE safe, unrelated
* byte-saving found while chasing this (stz below).
SCH_RESUME  lda   K_CURPID
            sta   K_SW_INPID
            jsr   PCB_PTR_FOR
* -- `stz` not `lda #0/sta`, 2026-09-27: A's incoming value here
* -- (PCB_PTR_FOR's own return) is never read again before
* -- SCH_DISPATCH's own `lda #PCB_BANK` overwrites it. Safe in
* -- every image (no TTY_HW_SET dependency, unlike the false
* -- start above) -- 2 B back toward the trampoline's own cost.
            stz   BANKSEL
            bra   SCH_DISPATCH

* SCH_DISPATCH -- shared tail for SCH_START/SCH_RESUME. Entry
* contract: K_SW_INPID = the pid to dispatch, K_PCB_PTR = that
* pid's PCB pointer (a just-completed PCB_PTR_FOR), BANKSEL = 0
* (annex). Never returns.
SCH_DISPATCH
            ;-- read BANK(3)/PARENT(4)/SAVEDSP(5) in one
            ;PCB_RD_FIELDS
            ;-- call (RAMRD-fetch-immune -- see this file's
            ;header; the
            ;-- earlier inline-RAMRDAUX version of this routine
            ;wild-
            ;-- jumped). PARENT rides along unused -- one 3-byte
            ;copy is
            ;-- cheaper than two separate 1-byte ones. --
            lda   #PCB_BANK
            ldx   #3
            jsr   PCB_RD_FIELDS
            lda   K_PCB_SCRATCH
            sta   K_SW_INBANK
            lda   K_PCB_SCRATCH+2
            sta   K_SW_INSP

            lda   K_SW_INPID
            sta   K_CURPID
            lda   #QUANTUM_TICKS
            sta   K_QUANTUM

            lda   K_SW_INBANK
            sta   K_CURBANK                      ;shadow
            sta   BANKSEL                        ;$C073 = first
                                                 ;pid's bank
* BUG FOUND BY TESTING, THIS ROUND: this MUST happen BEFORE the
* ALTZP flip below -- K_SW_INSP is ZERO PAGE ($E7), which is
* ALTZP-governed. An earlier version of this routine read it
* AFTER `STA ALTZPAUX`, silently landing in the INCOMING bank's
* OWN zero page instead of main's -- X came back garbage, TXS
* loaded a garbage SP, and EXIT_TAIL's RTI pulled a garbage
* frame (confirmed by direct emulator inspection: `regs`/`peek`
* showed the pushed-frame bytes in the target bank's own page 1
* untouched after the crash, proving the launch never correctly
* reached it). Exactly the same bug CLASS as docs/SYSCALL.md
* #5.1/#7.7's cross-flip cell-ordering mistakes, a fourth
* instance in this kernel.
            ldx   K_SW_INSP
            sta   ALTZPAUX                        ;NOW flip --
                                                  ;no pushes OR
                                                  ;reads until
                                                  ;TXS below
                                                  ;(same
                                                  ;critical-
                                                  ;section
                                                  ;discipline as
                                                  ;KRN_EXIT/
                                                  ;KERNEL_IRQ_SE
                                                  ;RVICE)
            txs
            jmp   $FF22                            ;EXIT_TAIL
                                                   ;launches it
                                                   ;from its
                                                   ;synthesized
                                                   ;frame --
                                                   ;zero
                                                   ;special-
                                                   ;casing (item
                                                   ;11)

* See K.SCHED.TXT: "SCH_SWITCH -- A = requeue flag (0 ="
SCH_SWITCH
            sta   K_SCHD_RQ
            lda   K_CALLER_SP                  ;cache OUTGOING's
                                               ;captured
            sta   K_SW_OUTSP                    ;SP BEFORE any
                                                ;bracket opens
                                                ;(K_CALLER_SP is
                                                ;ordinary main
                                                ;memory --
                                                ;entry.s's own
                                                ;cross-flip
                                                ;cell; reading
                                                ;it here is
                                                ;fine,
                                                ;RAMRD/RAMWRT
                                                ;are still main
                                                ;at this point
                                                ;in every
                                                ;caller)
            lda   K_CURPID
            sta   K_SW_OUTPID

:pop        jsr   RUNQ_POP
            sta   K_SW_INPID
            beq   :empty
            cmp   K_IDLE_PID
            bne   :statechk
*-- The idle process runs only when nothing else can: with
*-- entries behind it, it goes back to the tail and the next
*-- one is taken; alone in the queue while the outgoing is
*-- still runnable, it stays queued and the switch is
*-- cancelled (the outgoing keeps the CPU); only when the
*-- outgoing has blocked is idle dispatched.
            lda   RUNQ_HEAD
            cmp   RUNQ_TAIL
            beq   :idleonly
            lda   K_SW_INPID
            jsr   RUNQ_PUSH
            bra   :pop
:idleonly   lda   K_SCHD_RQ
            beq   :statechk
            lda   K_SW_INPID
            jsr   RUNQ_PUSH
            bra   :cancel

            ;-- run queue empty --
:empty      lda   K_SCHD_RQ
            beq   :deadlock
:cancel
* -- :statechk may have left BANKSEL=0, and the cancel path's
* -- downstream (KRN_IRQ_SVC :sameproc) deliberately does NOT
* -- rewrite $C073 -- restore the outgoing bank from its PCB.
* -- Harmless when untainted (always-write discipline).
            lda   K_SW_OUTPID
            jsr   PCB_PTR_FOR
* -- `stz` not `lda #0/sta`, 2026-09-27: A is overwritten by the
* -- very next `lda #PCB_BANK` regardless -- 2 more B toward the
* -- SLICE 2 console-reassert trampoline's own PT_HOLD cost.
            stz   BANKSEL
            lda   #PCB_BANK
            ldx   #1
            jsr   PCB_RD_FIELDS
            lda   K_PCB_SCRATCH
            sta   BANKSEL
            stz   K_SWITCH                      ;cancel -- keep
                                                ;running the one
                                                ;live process
* -- C1 FIX: reset K_QUANTUM here too, not only on a real
* -- switch, else the next tick's dec wraps 0->$FF and skips
* -- SCH_SWITCH for 255 ticks. Full story: docs/SCHED.md.
            lda   #QUANTUM_TICKS
            sta   K_QUANTUM
            rts

:deadlock   ;-- v1 known limitation (docs/SCHED.md): no idle
            ;process. -- Park, inspectable, rather than corrupt
            ;state by "resuming" -- pid 0. --
            jmp   *

* -- A queued pid may have died between enqueue and dispatch
* -- (^C wakes readers, then the sweep zombies them, same
* -- tick). Dispatching a zombie would TXS into a freed bank:
* -- skip anything no longer RUNNABLE. That also covers a pid
* -- the ^Z sweep STOPPED after it was queued (PCB_STOPPED,
* -- docs/JOB-CONTROL.md Increment B) -- the load-bearing rule
* -- for that state is the converse: never RUNQ_PUSH a stopped
* -- pid, or it is popped and skipped here forever. SYS_CONT is
* -- the one path that pushes one, after marking it RUNNABLE.
:statechk   lda   K_SW_INPID          ;(the :idleonly entry
            jsr   PCB_PTR_FOR             ;arrives with A=0)
            lda   #0
            sta   BANKSEL
            lda   #PCB_STATE
            ldx   #1
            jsr   PCB_RD_FIELDS
            lda   K_PCB_SCRATCH
            cmp   #PCB_RUNNABLE
            bne   :pop
:havein     lda   K_SCHD_RQ
            beq   :noreq
            lda   K_SW_OUTPID
            jsr   RUNQ_PUSH
:noreq
            ;-- compute both PCB pointers now (pure register/ZP
            ;arithmetic,
            ;-- OUTSIDE any bracket) and cache them --
            ;PCB_PTR_FOR reuses
            ;-- K_PCB_PTR, so each result must be stashed before
            ;computing
            ;-- the other. --
            lda   K_SW_OUTPID
            jsr   PCB_PTR_FOR
            lda   K_PCB_PTR
            sta   K_SW_OUTPTR
            lda   K_PCB_PTR+1
            sta   K_SW_OUTPTR+1
            lda   K_SW_INPID
            jsr   PCB_PTR_FOR
            lda   K_PCB_PTR
            sta   K_SW_INPTR
            lda   K_PCB_PTR+1
            sta   K_SW_INPTR+1

            ;-- select the annex; write outgoing's saved SP +
            ;(if
            ;-- requeued) RUNNABLE -- write-only bracket, safe
            ;inline
            ;-- (RAMWRT does not gate instruction fetch; see
            ;this file's
            ;-- header). If not requeued, SCH_SLEEP already
            ;wrote
            ;-- PCB_BLOCKED before calling us -- do not
            ;overwrite it. --
            lda   #0
            sta   BANKSEL
            sta   RAMWRTAUX
            lda   K_SW_OUTPTR
            sta   K_PCB_PTR
            lda   K_SW_OUTPTR+1
            sta   K_PCB_PTR+1
            lda   K_SW_OUTSP
            ldy   #PCB_SAVEDSP
            sta   (K_PCB_PTR),y
            lda   K_SCHD_RQ
            beq   :skipst
            lda   #PCB_RUNNABLE
            ldy   #PCB_STATE
            sta   (K_PCB_PTR),y
:skipst     sta   RAMWRTMAIN

            ;-- read incoming's bank + saved SP via
            ;PCB_RD_FIELDS
            ;-- (RAMRD-fetch-immune -- an inline RAMRDAUX flip
            ;here wild-
            ;-- jumps, see this file's header). --
            lda   K_SW_INPTR
            sta   K_PCB_PTR
            lda   K_SW_INPTR+1
            sta   K_PCB_PTR+1
            lda   #PCB_BANK
            ldx   #3                              ;BANK/PARENT/S
                                                  ;AVEDSP
            jsr   PCB_RD_FIELDS
            lda   K_PCB_SCRATCH
            sta   K_SW_INBANK
            lda   K_PCB_SCRATCH+2
            sta   K_SW_INSP

            ;-- mark incoming RUNNING -- write-only bracket,
            ;safe inline.
            ;-- BANKSEL is still 0 (annex) from above. --
            sta   RAMWRTAUX                       ;A=K_SW_INSP's
                                                  ;value,
                                                  ;irrelevant
            lda   #PCB_RUNNING
            ldy   #PCB_STATE
            sta   (K_PCB_PTR),y
            sta   RAMWRTMAIN

            ;-- publish the switch request for entry.s's shared
            ;exit path. --
            lda   K_SW_INBANK
            sta   K_TARGETBANK
            sta   K_CURBANK                       ;shadow, see
                                                  ;K_CURPID
            lda   K_SW_INSP
            sta   K_TARGETSP
            lda   K_SW_INPID
            sta   K_CURPID
            lda   #QUANTUM_TICKS
            sta   K_QUANTUM
            lda   #1
            sta   K_SWITCH
            inc   K_SW_COUNT
            bne   :swcdone
            inc   K_SW_COUNT+1
:swcdone    rts
