*---------------------------------------------------------------
* process2.s -- PRC_SPAWN, PRC_EXIT, PRC_WAIT and PRC_PIPE:
* the second half of process.s (S9 L4).
*
* WHY THE CUT EXISTS. process.s's generated REL form is 16,314 B
* staged, and `as`'s source window charges manifest + largest
* single put: 16,314 + mm.annex.equ's 2,752 = 19,068 against
* a 16,126 B window. KPROC was the one oracle-gap module that
* could not even be OFFERED to `as`, so the question the gap's
* own note poses -- does `as` assemble what real Merlin refuses?
* -- could not be asked of it.
*
* WHERE THE CUT IS, and why here. At the PRC_SPAWN global
* label,
* which is a section boundary: no `:local` zone straddles it,
* so the cross-zone hazard that merlin32 hides and Merlin-8
* does not (learning:01M0VJF2DXZR55HGJ8PTN1MNJE) cannot apply.
* The four routines that moved are the process-lifecycle and
* IPC system calls; everything they need from the parent --
* the PRC_* cells and the PCB helpers -- crosses as ordinary
* linked symbols.
*
* WHY THE CUT IS HERE AND NOT AT PRC_EXIT, which is where it
* was first made: PRC_EXIT left KPROC needing 41,239 B against
* a 41,215 B buffer. Twenty-four bytes. Squeaking under a hard
* limit by 24 B is not a fix, it is a tripwire for whoever
* adds the next comment; PRC_SPAWN leaves 6,062 B of margin.
*
* This file is `put` IMMEDIATELY AFTER process.s in every
* manifest, which is what makes the split byte-neutral: the
* emitted bytes are in the same order at the same addresses.
* check-bytes is the gate that says so.
*---------------------------------------------------------------
PRC_SPAWN
            lda   #8
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
*-- DUPFD-1: the WHOLE fdactions list is judged here, before any
*-- pathname work, any LZ_WANT_SET and any bank (procfile2.s
*-- PRC_FDA_CHECK says why this spot and not a later one). A bad
*-- list fails the spawn with nothing created.
:parmsok    jsr   PRC_FDA_CHECK
            bcc   :fdaok
            rts
:fdaok      lda   PRC_PARM
            sta   P_PTR1
            lda   PRC_PARM+1
            sta   P_PTR1+1
            jsr   PRDPAR_BYTE
            bcc   :pathok
            rts
*-- The builtin-image lookup is a HOOK (KFIX5): PRC_BLTN is in
*-- spawnbl.s (the harness manifests that carry builtin images)
*-- or spawnpl.s (everything else: carry clear, nothing found).
*-- Carry SET = a builtin image, its source and length already
*-- in PRC_IMAGE_SRC/LEN: skip the pathname work, which only a
*-- file spawn has.
:pathok     jsr   PRC_BLTN
            bcs   :haveimg
* -- The spawn pathname is canonicalised HERE, before the bank
* -- is allocated, because under lazy free the ALLOCATOR is what
* -- decides whether this spawn needs a load at all: it prefers
* -- a bank already tagged with this very program (docs/
* -- STICKY.md sec 25). PRC_LD_FL_IMG used to do this copy
* -- itself and no longer does. A failure here is clean -- no
* -- bank has been claimed yet, and PCPY_SPWN_PTH has already
* -- set the error through PRC_FAIL_A.
            jsr   PCPY_SPWN_PTH
            bcc   :wantset
            rts
:wantset    jsr   LZ_WANT_SET

:haveimg    jsr   PRC_ALLC_BANK
            bcc   :bankok
            rts
:bankok     sta   PRC_CHLD_BANK
            sta   PRC_CHILD_PID
            lda   K_CURPID
            sta   PRC_PAR_PID

            lda   PRC_CHLD_BANK
            jsr   PRC_STMP_BANK
            lda   PRC_CHLD_BANK
            jsr   PRC_SYNTH_FRM
            stz   K_RESULT_ERR
            jsr   PRC_LD_ANY           ;image or file (the
                                       ;spawn twins)
            lda   K_BC_ERR
            bne   :loadbad
*-- S9 L3b: the frame above was built for LOAD_BASE (that is
*-- PRC_SYNTH_FRM's contract, and 31 test harnesses depend on
*-- it). Only now, with the image loaded, is its real base
*-- known -- so repoint the RTI address at it. The child is not
*-- on the run queue until SCH_CREATE, well below, so nothing
*-- reads the frame in between.
            lda   PRC_CHLD_BANK
            jsr   PRC_SET_ENTRY
            bra   :loadok
:loadbad
            lda   PRC_CHLD_BANK
            jsr   PRC_FREE_BANK
            lda   K_RESULT_ERR
            bne   :loadfail
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
:loadfail
            rts

*-- argv staging can now FAIL (ERR_2BIG past ARG_MAX, ERR_INVAL
*-- on a refused copy), and the failure has to be acted on here:
*-- the bank is already allocated and stamped, but
*-- SCH_CREATE has not run, so the child does not exist yet
*-- and freeing the bank is the whole cleanup. Before
*-- 2026-08-17 PSTG_ARGV could not fail by design (it
*-- truncated), and its copyin-refusal path
*-- returned with K_RESULT_ERR set only to have the
*-- PRC_RET_OK_A below clear it again -- so a parent got a
*-- SUCCESSFUL spawn whose child held a half-staged argv.
:loadok     jsr   PSTG_ARGV
            bcc   :argvok
            lda   PRC_CHLD_BANK
            jsr   PRC_FREE_BANK
            sec
            rts
:argvok
            lda   PRC_CHILD_PID
            ldx   PRC_CHLD_BANK
            jsr   SCH_CREATE

*-- S9 L3b: record where this image was actually loaded, for
*-- the one thing that outlives the spawn call -- brk()'s floor.
            ldx   PRC_CHILD_PID
            lda   PRC_LOADADR+1
            sta   PRC_BASEPG,x

*-- The child inherits the parent's working directory, which is
*-- what makes cwd a per-PROCESS property rather than a global
*-- one: `cd` in the shell moves the shell and everything it
*-- spawns afterwards, and nothing else on the machine.
            lda   K_CURPID
            jsr   CWD_READ               ;parent -> K_CWD_BUF
            lda   PRC_CHILD_PID
            jsr   CWD_WRITE              ;-> child

*-- signals (docs/SIGNALS.md inheritance): spawn takes V7's
*-- EXEC rule -- ignored dispositions carry to the child, caught
*-- ones reset to default. Y=0 selects that rule.
            lda   K_CURPID
            ldx   PRC_CHILD_PID
            ldy   #0
            jsr   PRC_SIG_INH

            lda   PRC_CHILD_PID
            sta   P_PID
            lda   PRC_PAR_PID
            jsr   PPCB_WR_PAR

            jsr   PRC_DFLT_FDS
            jsr   PRC_FDACTIONS

            lda   PRC_CHILD_PID
            jsr   PRC_RET_OK_A
            rts

PRC_EXIT
            lda   #1
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   K_CURPID
            sta   P_PID
            jsr   PRDPAR_FIELD
            lda   K_PCB_SCRATCH
            sta   PRC_PAR_PID

            lda   K_CURPID         ;alt-screen backstop (tty5.s
            jsr   PRC_ALT_RST      ;PRC_ALT_RST): a voluntary
                                   ;exit that skipped rmcup
                                   ;still hands the main screen
                                   ;back -- unlike PRC_TMD_RST,
                                   ;which forced deaths only get
            lda   K_CURPID
            sta   P_PID
            jsr   PCLS_ALL_FDS

            lda   K_CURPID
            ldx   PRC_PARM
            jsr   PRC_ZOMB

* -- ORPHAN-1: this process's live children go to init, and a
* -- STOPPED one gets SIGHUP then SIGCONT (4.2BSD kern_exit.c).
            jsr   PRC_ADOPT
            lda   PRC_PAR_PID
            beq   :nowake
            jsr   SCH_WAKEUP
:nowake     lda   #0
            jsr   SCH_SWITCH
            stz   K_RESULT
            stz   K_RESULT_ERR
            rts

*---------------------------------------------------------------
* PRC_ZOMB -- the ONE place a process is marked dead: A = pid,
* X = its wait status. State ZOMBIE, wchan 0, status stored;
* fds, bank and parent are the reaper's. PRC_EXIT, PRC_KILL's
* kill(self) and PRC_DIE (procspawn2.s: ^C, kill, user BRK) all
* call it. A write-only annex bracket, so legal in tick context.
* Leaves BANKSEL = 0 -- the callers' own tails restore the bank.
* Clobbers A, Y, K_PCB_PTR.
*---------------------------------------------------------------
PRC_ZOMB
            pha                          ;pid, for the shadow
            jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            sta   RAMWRTAUX
            lda   #PCB_ZOMBIE
            ldy   #PCB_STATE
            sta   (K_PCB_PTR),y
            lda   #0
            ldy   #PCB_WCHAN
            sta   (K_PCB_PTR),y
            txa
            ldy   #PCB_EXITSTAT
            sta   (K_PCB_PTR),y
            sta   RAMWRTMAIN
            ply                          ;wait shadow (main):
            lda   #0                     ;after the bracket; a
            sta   K_WAIT_SHD,y           ;victim may be BLOCKED
            rts

*---------------------------------------------------------------
* PRC_WAIT -- wait(&status) = SYS_WAIT, the legacy 1-byte form,
* and PRC_WAITJOB -- waitjob(&status2, flags) = SYS_WAITJOB
* (docs/JOB-CONTROL.md Increment B). ONE scan, PRC_WAIT_CORE,
* parameterised by PRC_WFLAGS: bits 0/1 are the caller's
* WJ_NOHANG / WJ_UNTRACED, bit 7 selects the two-byte {kind,
* code} status shape. Legacy is flags 0: block, reap ZOMBIE
* only, one status byte -- untouched for its ~60 hand-built
* callers.
*
* The scan counts this process's children (P_COUNT) and, apart,
* the ones that are NOT stopped (PRC_WLIVE). A ZOMBIE is reaped
* and reported. A STOPPED child is reported without being
* reaped when WJ_UNTRACED asked for it, and merely counted
* otherwise. Nothing ready: no children at all -> ERR_CHILD;
* WJ_NOHANG -> 0; every child stopped and not asked about ->
* ERR_CHILD too, because nothing could ever wake that sleep
* (only THIS process may continue them, and it would be
* asleep); else block, retried on wake exactly as before.
*---------------------------------------------------------------
PRC_WAITJOB
            lda   #3
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM+2
            and   #WJ_NOHANG+WJ_UNTRACED
            ora   #$80                   ;two-byte status
            sta   PRC_WFLAGS
            bra   PRC_WAIT_CORE
PRC_WAIT
            lda   #2
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    stz   PRC_WFLAGS
PRC_WAIT_CORE
            lda   PRC_PARM
            sta   PRC_STAT_PTR
            lda   PRC_PARM+1
            sta   PRC_STAT_PTR+1
            stz   P_COUNT
            stz   PRC_WLIVE
*-- WAIT-1: the scan reads K_PAR_SHD (47 main bytes), not the
*-- annex PCBs. The shadow only FILTERS: a pid whose cell equals
*-- K_CURPID is read from the annex at :hit, which re-checks the
*-- real PCB_PARENT; STATE and BANK are read there too. The
*-- shadow is REVERSED (pid p in cell 48-p, PAR_CELL): the loop
*-- is a plain dex/bne from pid 1's cell, and DESCENDING cells
*-- are ASCENDING pids, so the reap order is unchanged.
            lda   K_CURPID
            ldx   #PCB_COUNT-1            ;the cell of pid 1
:scan       cmp   K_PAR_SHD,x
            beq   :hit
:next       dex
            bne   :scan

:done       lda   P_COUNT
            beq   :nochild
            lda   PRC_WFLAGS
            and   #WJ_NOHANG
            beq   :maybloc
            jmp   PRC_RET_OK0            ;poll: nothing ready
:maybloc    lda   PRC_WLIVE
            bne   :block
:nochild    lda   #ERR_CHILD
            jsr   PRC_FAIL_A
            rts

:block      lda   K_CURPID
            jsr   PRC_BLCK_RTRY
            rts

*-- a shadow match: X = cell -> X = pid, read the annex PCB.
:hit        txa
            jsr   PAR_CELL                ;A = X = pid
            jsr   PCB_PTR_FOR
            phx
            lda   #0
            sta   BANKSEL
            lda   #PCB_STATE
            ldx   #4
            jsr   PCB_RD_FIELDS
            plx
            lda   K_PCB_SCRATCH+3         ;the real PCB_PARENT
            cmp   K_CURPID
            bne   :rescan
            inc   P_COUNT
            lda   K_PCB_SCRATCH
            cmp   #PCB_ZOMBIE
            beq   :reap
            cmp   #PCB_STOPPED
            bne   :live
            lda   PRC_WFLAGS
            and   #WJ_UNTRACED
            bne   :stopped
            bra   :rescan
:live       inc   PRC_WLIVE
:rescan     txa                           ;pid -> its cell
            jsr   PAR_CELL
            lda   K_CURPID
            bra   :next

* -- a STOPPED child, WJ_UNTRACED: {WJ_STOPPED, 0}, reported
* -- every call while it stays stopped (the report-once
* -- invariant lives with the ONE sanctioned consumer, `fg`).
:stopped    txa
            sta   PRC_CHILD_PID
            lda   #WJ_STOPPED
            sta   PRC_BYTE
            stz   PRC_BYTE+1
            jsr   PRC_WSTAT2
            bcc   :repstop
            rts
:repstop    lda   PRC_CHILD_PID
            jsr   PRC_RET_OK_A
            rts

:reap       txa
            sta   PRC_CHILD_PID
            lda   K_PCB_SCRATCH+2
            sta   PRC_CHLD_BANK
            lda   #PCB_EXITSTAT
            ldx   #1
            jsr   PCB_RD_FIELDS
            lda   K_PCB_SCRATCH
            sta   PRC_BYTE
            bit   PRC_WFLAGS
            bmi   :jobst
            lda   PRC_STAT_PTR
            sta   P_PTR1
            lda   PRC_STAT_PTR+1
            sta   P_PTR1+1
            jsr   PWRPAR_BYTE
            bra   :wrchk
* -- job shape: exit status s -> {WJ_EXITED, s}; a $80|signo
* -- death -> {WJ_SIGNALED, signo}.
:jobst      lda   #WJ_EXITED
            ldx   PRC_BYTE
            bpl   :kind
            txa
            and   #$7F
            sta   PRC_BYTE
            lda   #WJ_SIGNALED
:kind       ldx   PRC_BYTE
            stx   PRC_BYTE+1
            sta   PRC_BYTE
            jsr   PRC_WSTAT2
:wrchk      bcc   :wrote
            rts
:wrote      lda   PRC_CHILD_PID
            sta   PRC_WREAP              ;PRC_REAP_ONE reuses it
            jsr   PRC_REAP_ONE           ;a reap orphans nobody
            lda   PRC_WREAP              ;(ORPHAN-1: adopted)
            jsr   PRC_RET_OK_A
            rts

*---------------------------------------------------------------
* PRC_WSTAT2 -- copy PRC_BYTE/PRC_BYTE+1 ({kind, code}) to the
* caller's PRC_STAT_PTR, two PWRPAR_BYTE calls (it copies ONE
* byte, from PRC_BYTE). Carry as PWRPAR_BYTE's. Clobbers A, X,
* Y, P_PTR1, PRC_BYTE.
*---------------------------------------------------------------
PRC_WSTAT2
            lda   PRC_STAT_PTR
            sta   P_PTR1
            lda   PRC_STAT_PTR+1
            sta   P_PTR1+1
            jsr   PWRPAR_BYTE
            bcs   :out
            inc   P_PTR1
            bne   :nohi
            inc   P_PTR1+1
:nohi       lda   PRC_BYTE+1
            sta   PRC_BYTE
            jsr   PWRPAR_BYTE
:out        rts

*---------------------------------------------------------------
* PRC_REAP_ONE -- A = a child pid whose slot is being FREED,
* PRC_CHLD_BANK = its bank: the reap tail every reaper shares.
* Scrub it from every foreground set (the pid==bank reuse
* window, PRC_FG_SCRUB), close its fds (a ^C-killed or stopped
* child never ran exit -- MLI is legal here, in syscall
* context, never in the tick sweeps), mark the slot UNUSED with
* parent 0, and free the bank (LZ_RETAIN may keep it tagged).
* Clobbers everything PCLS_ALL_FDS does; K_PCB_PTR.
*---------------------------------------------------------------
PRC_REAP_ONE
            sta   PRC_CHILD_PID
            jsr   PRC_FG_SCRUB
            lda   PRC_CHILD_PID
            sta   P_PID
            jsr   PCLS_ALL_FDS
            lda   PRC_CHILD_PID
            jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            sta   RAMWRTAUX
            lda   #PCB_UNUSED
            ldy   #PCB_STATE
            sta   (K_PCB_PTR),y
            lda   #0
            ldy   #PCB_PARENT
            sta   (K_PCB_PTR),y
            sta   RAMWRTMAIN
            lda   PRC_CHILD_PID          ;slot free: ITS cell is
            jsr   PAR_CELL               ;0 again (main, AFTER
            stz   K_PAR_SHD,x            ;the bracket). Never a
                                         ;child's cell: orphans
                                         ;keep theirs
            lda   PRC_CHLD_BANK
            jsr   PRC_FREE_BANK
            rts

*---------------------------------------------------------------
* PRC_ADOPT -- ORPHAN-1. Run AFTER a death event has marked its
* victims ZOMBIE (PRC_ZOMB/PRC_DIE), never inside the per-victim
* loop of a sweep: PRC_FG_HAS finds a victim's descendants by
* the parent chain, so reparenting a dead node early would let a
* later descendant escape the ^C. V7 sys1.c exit() / 4.2BSD
* kern_exit.c: every process whose PARENT IS DEAD (state ZOMBIE)
* gets PCB_PARENT := 1 through PPCB_WR_PAR (annex and K_PAR_SHD
* together); an adoptee's own children keep it. The dead set is
* the zombie parents themselves, so one routine serves a single
* death, a sweep of several, and the cascade, and a repeat call
* finds nothing to do. A STOPPED adoptee gets SIGHUP, then
* SIGCONT, through its own disposition: default dies ($81, a
* new death, so the scan runs again for its children), ignored
* or caught leaves it alive and CONT resumes it (a caught HUP
* is pending).
* init is woken when an adoptee is a zombie. Tick-safe: marking,
* annex writes and wakes only; the fd closes and the slot free
* stay in PRC_REAP_ONE, where init's wait reaps. A cell of 0
* (free, root tier) and 1 (init's child) is skipped, so a dead
* init adopts nothing. Clobbers A, X, Y, P_PID, P_TMP, P_TMP2,
* K_PCB_PTR, K_PCB_SCRATCH and PRC_DIE's set; BANKSEL left 0.
*---------------------------------------------------------------
PRC_ADOPT
            stz   ADP_WAKE
:pass       stz   ADP_CHG
            ldx   #PCB_COUNT-1           ;the cell of pid 1
:scan       lda   K_PAR_SHD,x
            cmp   #2
            bcc   :next
            phx
            jsr   ADP_STATE              ;the parent's state
            plx
            cmp   #PCB_ZOMBIE
            bne   :next
            phx                          ;the cell
            txa
            jsr   PAR_CELL               ;A = X = the child pid
            sta   ADP_PID
            sta   P_PID
            lda   #1
            jsr   PPCB_WR_PAR
            lda   ADP_PID
            jsr   ADP_STATE
            cmp   #PCB_ZOMBIE
            beq   :zomb
            cmp   #PCB_STOPPED
            bne   :adopted
            lda   ADP_PID
            jsr   PRC_SIG_RD
            lda   K_PCB_SCRATCH+2        ;HUP ignored: just CONT
            and   #1
            bne   :cont
            lda   K_PCB_SCRATCH+0        ;HUP caught: pend it
            and   #1
            bne   :hcatch
            lda   ADP_PID                ;default: it dies, and
            ldx   #STATUS_HUP            ;its children are next
            jsr   PRC_DIE
            inc   ADP_CHG
:zomb       inc   ADP_WAKE
            bra   :adopted
:hcatch     lda   ADP_PID
            ldx   #SIG_HUP
            jsr   PRC_SIG_SND
:cont       lda   ADP_PID
            jsr   PRC_UNSTOP
:adopted    plx
:next       dex
            bne   :scan
            lda   ADP_CHG
            bne   :pass
            lda   ADP_WAKE
            beq   :out
            lda   #1                     ;init blocks in wait on
            jmp   SCH_WAKEUP             ;its own pid
:out        rts

*-- A = pid -> A = its PCB_STATE (annex read, BANKSEL 0).
ADP_STATE   jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            lda   #PCB_STATE
            ldx   #1
            jsr   PCB_RD_FIELDS
            lda   K_PCB_SCRATCH
            rts

ADP_WAKE    ds 1
ADP_CHG     ds 1
ADP_PID     ds 1

*---------------------------------------------------------------
* PRC_UNSTOP -- A = a STOPPED pid: RUNNABLE, WCHAN 0, on the run
* queue. The ONE path that may push a stopped pid (sched.s
* :statechk's rule); SYS_CONT and the orphan SIGCONT share it.
* Annex write plus RUNQ_PUSH: tick-safe. Clobbers A, X, Y,
* K_PCB_PTR.
*---------------------------------------------------------------
PRC_UNSTOP
            pha
            jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            sta   RAMWRTAUX
            lda   #PCB_RUNNABLE
            ldy   #PCB_STATE
            sta   (K_PCB_PTR),y
            lda   #0
            ldy   #PCB_WCHAN
            sta   (K_PCB_PTR),y
            sta   RAMWRTMAIN
            pla
            jmp   RUNQ_PUSH

*---------------------------------------------------------------
* PRC_CONT -- cont(pid) = SYS_CONT (docs/JOB-CONTROL.md
* Increment B): resume a STOPPED child. PRC_SIG_SND's blocked-
* wake above, applied to PCB_STOPPED instead of PCB_BLOCKED:
* RUNNABLE, WCHAN 0, RUNQ_PUSH -- the ONE path that may push a
* stopped pid (sched.s :statechk's rule). Refused ERR_INVAL
* unless the pid is a child of the caller (SYS_TCSETFG's
* hardening: a reaped slot has parent 0 and fails too) and is
* stopped right now. Not a SYS_KILL signo: a continue is not a
* termination and the disposition table (docs/SIGNALS.md sec 1)
* has no place for it.
*---------------------------------------------------------------
PRC_CONT    lda   #1
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM+0
            beq   :inval
            cmp   #PCB_COUNT
            bcs   :inval
            jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            lda   #PCB_STATE
            ldx   #4                   ;state,wchan,bank,parent
            jsr   PCB_RD_FIELDS
            lda   K_PCB_SCRATCH+3
            cmp   K_CURPID
            bne   :inval
            lda   K_PCB_SCRATCH
            cmp   #PCB_STOPPED
            bne   :inval
            lda   PRC_PARM+0
            jsr   PRC_UNSTOP
            jmp   PRC_RET_OK0
:inval      lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts

*---------------------------------------------------------------
* PRC_STOP -- stop(void) = SYS_STOP (docs/JOB-CONTROL.md
* Increment E): the caller parks ITSELF. SCH_SLEEP's shape with
* PCB_STOPPED for PCB_BLOCKED (WCHAN 0), and it WAKES THE PARENT
* first -- a fg-waiting shell blocks on its own pid as the wait
* channel, so SCH_WAKEUP(parent) makes its SYS_WAITJOB re-scan
* and see this child STOPPED. No retry-rewind (PRC_BLCK_RTRY's
* job): a continue is not an interrupt, so SYS_STOP RETURNS 0
* when SYS_CONT re-dispatches it. The catcher's half of
* cooperative ^Z (vi: rmcup, SYS_STOP, smcup). No parameters.
*---------------------------------------------------------------
PRC_STOP    lda   K_CURPID
            jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            lda   #PCB_STATE
            ldx   #4                   ;state,wchan,bank,parent
            jsr   PCB_RD_FIELDS
            lda   K_PCB_SCRATCH+3      ;parent pid, stashed
            sta   PRC_STOP_PAR         ;across the writes below
            lda   K_CURPID
            jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            sta   RAMWRTAUX            ;WRITE-only bracket
            lda   #PCB_STOPPED
            ldy   #PCB_STATE
            sta   (K_PCB_PTR),y
            lda   #0
            ldy   #PCB_WCHAN
            sta   (K_PCB_PTR),y
            sta   RAMWRTMAIN
            lda   PRC_STOP_PAR         ;wake a fg-waiting parent
            beq   :noparent            ;root tier: none
            jsr   SCH_WAKEUP
:noparent   lda   #0                   ;requeue=0: STOPPED, not
            jsr   SCH_SWITCH           ;runnable -- do not queue
*-- resumed here by SYS_CONT (RUNNABLE + RUNQ_PUSH); return 0
            jmp   PRC_RET_OK0
PRC_STOP_PAR ds 1

PRC_WFLAGS  ds 1
PRC_WLIVE   ds 1
PRC_WREAP   ds 1
PRC_PIPE
            lda   #2
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM
            sta   PRC_STAT_PTR
            lda   PRC_PARM+1
            sta   PRC_STAT_PTR+1
            jsr   PRC_ALLC_PIPE
            bcc   :pipeok
            rts
* -- UNWIND (2026-08-21). Freeing the pipe slot in PRC_DEC_OBJ
* -- when both ref counts hit zero fixes the COMMON leak, but it
* -- hangs the free off the CLOSE path -- and the two failures
* -- below happen with the slot allocated and NOTHING yet
* -- pointing at it, so no close is ever coming. Both are
* -- reachable: a pipe costs TWO OFT entries and only 15 are
* -- allocatable (index 0 never is), so 7 live pipes plus one
* -- open file already exhausts the OFT while pipe slots remain.
* -- Without these two unwinds the slot leaks for the life of
* -- the BOOT, exactly like the bug they accompany.
* --
* -- The three LATER failures in this routine (PALOBJ_W, the
* -- write fd, PWRPAR_BYTE) are deliberately NOT unwound here:
* -- by then the READ end is wired to a real fd of the calling
* -- process, so PCLS_ALL_FDS at exit/reap closes it and the
* -- slot comes back. Those leak for a process lifetime, not a
* -- boot, and unwinding them means fd-table writes (bank
* -- juggling) on an error path for no additional safety.
:pipeok     jsr   PALOBJ_R
            bcc   :objrok
            ldx   P_PIPE                 ;nothing references the
            lda   #0                     ;  slot -- release it
            sta   PIPE_USED,x
            rts
:objrok     sta   P_OBJ
            jsr   PRC_FND_FR_FD
            bcc   :fdrok
            jsr   PRC_DEC_OBJ            ;drops the read OFT
                                         ;  entry AND, with both
                                         ;  ref counts now zero,
                                         ;  the pipe slot
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:fdrok      sta   PRC_PARM+2             ;read fd result
            lda   P_OBJ
            sta   P_TMP2
            lda   PRC_PARM+2
            sta   P_FD
            lda   K_CURPID
            sta   P_PID
            jsr   PRC_SET_FDOBJ

            jsr   PALOBJ_W
            bcc   :objwok
            rts
:objwok     sta   P_OBJ
            jsr   PRC_FND_FR_FD
            bcc   :fdwok
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:fdwok      sta   PRC_PARM+3             ;write fd result
            lda   P_OBJ
            sta   P_TMP2
            lda   PRC_PARM+3
            sta   P_FD
            lda   K_CURPID
            sta   P_PID
            jsr   PRC_SET_FDOBJ

            lda   PRC_STAT_PTR
            sta   P_PTR1
            lda   PRC_STAT_PTR+1
            sta   P_PTR1+1
            lda   PRC_PARM+2
            sta   PRC_BYTE
            jsr   PWRPAR_BYTE
            bcc   :routok
            rts
:routok     inc   P_PTR1
            bne   :nohi
            inc   P_PTR1+1
:nohi       lda   PRC_PARM+3
            sta   PRC_BYTE
            jsr   PWRPAR_BYTE
            bcc   :woutok
            rts
:woutok     jsr   PRC_RET_OK0
            rts

