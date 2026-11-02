*---------------------------------------------------------------
* procspawn2.s -- Spawn child argument copying and interrupt
* sweep. Split out of procspawn.s (task #12, docs/PROCSPAWN.md)
* to keep each kernel module under 28000 bytes for compatibility
* with the maux assembler's shared symbol-table window.
* Full design notes: K.PROCESS.TXT (docs/a2/)
*---------------------------------------------------------------

PMEAS_ARG   stz   PRC_ARGLEN
            stz   PRC_ARGLEN+1

:measure     ;-- PRC_ARGSUM = PRC_ARGOFF + PRC_ARGLEN, the bytes
            ;-- already committed plus the bytes of this arg
            ;-- measured so far. Room for one more iff the
            ;-- is still below ARG_MAX. --
            clc
            lda   PRC_ARGOFF
            adc   PRC_ARGLEN
            sta   PRC_ARGSUM
            lda   PRC_ARGOFF+1
            adc   PRC_ARGLEN+1
            sta   PRC_ARGSUM+1
            cmp   #>ARG_MAX
            bcc   :haveroom
            bne   :toobig
            lda   PRC_ARGSUM
            cmp   #<ARG_MAX
            bcs   :toobig
:haveroom
            ;-- P_PTR1 = PRC_ARGV + PRC_ARGLEN --
            clc
            lda   PRC_ARGV
            adc   PRC_ARGLEN
            sta   P_PTR1
            lda   PRC_ARGV+1
            adc   PRC_ARGLEN+1
            sta   P_PTR1+1
            jsr   PRDPAR_BYTE
            bcs   :failed

            inc   PRC_ARGLEN              ;this byte counts --
            bne   :nocarry                ;the NUL included, so
            inc   PRC_ARGLEN+1            ;PRC_ARGLEN ends up
:nocarry                                  ;being the copy length
            lda   PRC_BYTE
            bne   :measure
            clc
            rts

:toobig     lda   #ERR_2BIG
            jsr   PRC_FAIL_A
            sec
:failed     rts

*---------------------------------------------------------------
* PSTG_ONE_ARG -- stage the measured arg into the child: its
* PRC_ARGLEN string bytes at PRC_ARGV_STR+PRC_ARGOFF, and a
* pointer to that address in the child's own pointer array at
* PRC_ARGV_PTRS+PRC_PTROFF. Advances PRC_ARGOFF by PRC_ARGLEN
* and PRC_PTROFF by 2.
*
* The pointer slot is the running OFFSET, not the entry index
* doubled (docs/SYSCALL.md item 13c): envp's pointers follow
* argv's with the envc byte between them, so index*2 stopped
* being the address the moment the two arrays shared one region.
*
* Returns: carry CLEAR = staged; carry SET = a copy was refused
* (ERR_INVAL, already reported).
*---------------------------------------------------------------
PSTG_ONE_ARG
            ;-- where this arg's string lands in the child --
            clc
            lda   #<PRC_ARGV_STR
            adc   PRC_ARGOFF
            sta   P_PTR1
            lda   #>PRC_ARGV_STR
            adc   PRC_ARGOFF+1
            sta   P_PTR1+1

            ;-- the string bytes, parent bank -> child bank --
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            lda   PRC_PAR_BANK
            sta   K_BC_SRCBANK
            lda   PRC_ARGV
            sta   K_BC_SRCADDR
            lda   PRC_ARGV+1
            sta   K_BC_SRCADDR+1
            lda   P_PTR1
            sta   K_BC_DSTADDR
            lda   P_PTR1+1
            sta   K_BC_DSTADDR+1
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   PRC_CHLD_BANK
            sta   K_BC_DSTBANK
            lda   PRC_ARGLEN
            sta   K_BC_LEN
            lda   PRC_ARGLEN+1
            sta   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            bne   :refused

            ;-- the pointer entry: the child's own address for
            ;-- the string just written, at PRC_PTROFF --
            lda   P_PTR1
            sta   PRC_ARGWORD
            lda   P_PTR1+1
            sta   PRC_ARGWORD+1
            lda   PRC_PTROFF
            clc
            adc   #<PRC_ARGV_PTRS
            sta   K_BC_DSTADDR
            lda   #>PRC_ARGV_PTRS
            adc   #0
            sta   K_BC_DSTADDR+1
            lda   #2
            jsr   PSTG_TO_CHILD
            bcs   :failed

            lda   PRC_PTROFF              ;PRC_PTROFF += 2. The
            clc                           ;caller refused any
            adc   #2                      ;offset past 253, so
            sta   PRC_PTROFF              ;this cannot wrap

            ;-- PRC_ARGOFF += PRC_ARGLEN (NUL included) --
            clc
            lda   PRC_ARGOFF
            adc   PRC_ARGLEN
            sta   PRC_ARGOFF
            lda   PRC_ARGOFF+1
            adc   PRC_ARGLEN+1
            sta   PRC_ARGOFF+1
            clc
            rts

:refused    lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            sec
:failed     rts

*---------------------------------------------------------------
* PSTG_ENV -- the environment half of the staging
* (docs/SYSCALL.md item 13c). Runs right after argv's, with
* PRC_ARGOFF and PRC_PTROFF still holding what argv spent, so
* the two share ARG_MAX and ARGV_PTR_LIM rather than each
* getting its own.
*
* The envc byte sits BETWEEN the two pointer arrays, and its
* value is not known until the whole list has been staged -- so
* its offset is reserved first (PRC_ENVCOFF) and the count is
* written back into it at the end. That is why 127 argv entries
* still fit: their pointers end at offset 254, envc lands in the
* one byte the pointer array had left, and any env ENTRY after
* that is refused with ERR_2BIG rather than staged short.
*
* SHARING THE ACCUMULATORS IS THE WHOLE MECHANISM. Give this
* pass its own PRC_ARGOFF and the environment's strings are
* written back OVER argv's -- not past the end of the region,
* into the middle of it -- while the one-byte-past case starts
* succeeding. Both symptoms, one line, measured:
* learning:01M0MHTWDNWJ3PSP2497SDZG97.
*
* Returns: carry CLEAR = staged; carry SET = failed, already
* reported (ERR_2BIG past a shared ceiling, ERR_INVAL on a
* refused copy).
*---------------------------------------------------------------
PSTG_ENV
            lda   PRC_PTROFF             ;reserve the envc byte
            sta   PRC_ENVCOFF
            cmp   #ARGV_PTR_LIM          ;255 is the first
            bcs   :toobig                ;offset past the array
            inc   PRC_PTROFF

            lda   PRC_PARM+6             ;the parent's envp
            sta   PRC_LISTP
            lda   PRC_PARM+7
            sta   PRC_LISTP+1
            jsr   PSTG_LIST
            bcs   :failed

            lda   P_COUNT                ;envc, into the byte
            sta   PRC_ARGWORD            ;held open above
            lda   PRC_ENVCOFF
            clc
            adc   #<PRC_ARGV_PTRS
            sta   K_BC_DSTADDR
            lda   #>PRC_ARGV_PTRS
            adc   #0
            sta   K_BC_DSTADDR+1
            lda   #1
            jsr   PSTG_TO_CHILD
            rts

:toobig     lda   #ERR_2BIG
            jsr   PRC_FAIL_A
            sec
:failed     rts

*---------------------------------------------------------------
* PSTG_TO_CHILD -- A = length (1 or 2): copy PRC_ARGWORD from
* main into the child bank at the K_BC_DSTADDR the caller set.
* The header bytes (ARGC, pointer entries) go through BankCopy
* for the same reason the strings do -- one primitive owns every
* write into another bank, brackets included.
*---------------------------------------------------------------
PSTG_TO_CHILD
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<PRC_ARGWORD
            sta   K_BC_SRCADDR
            lda   #>PRC_ARGWORD
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   PRC_CHLD_BANK
            sta   K_BC_DSTBANK
            jsr   BankCopy
            lda   K_BC_ERR
            bne   :refused
            clc
            rts
:refused    lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            sec
            rts

*---------------------------------------------------------------

*---------------------------------------------------------------
* PRC_INTR_SWP -- the ^C kill sweep (docs/CONSOLE.md section 4,
* docs/JOB-CONTROL.md Increment A). IN: A = the typing console
* +1 (K_INTR_PEND's value, handed over by SCH_TICK; 0 = none).
* Runs from SCH_TICK via K_INTR_HOOK, in process-context tick
* time only: the kernel is masked everywhere else, so no syscall
* is mid-flight and the P_*/K_PCB_* scratch is dead.
*
* THE TARGET IS THAT CONSOLE'S FOREGROUND JOB, not a spawn
* depth: VC_FGJOB[console], the pid set the shell declared with
* SYS_TCSETFG -- every LIVE pid in the set, and every live
* DESCENDANT of one (PRC_FG_HAS walks the parent chain up to a
* member). The descendants ARE the job: a non-interactive `sh
* SCRIPT` has no job control (POSIX: `set -m` is off in a
* script) and declares nothing, so its children are reachable
* only through it -- the same subtree the old depth >= 3 rule
* reached, now rooted at a NAMED job on ONE console. That is
* also what fixes the multi-console bug: a ^C on tty1 used to
* kill tty2's foreground job too. The root tier (parent 0) is
* never a victim. An EMPTY set (the idle prompt) kills nothing
* -- TTY_INTR's empty line still reprompts the shell. A stale
* entry can only name an UNUSED/ZOMBIE slot (skipped): the reap
* scrubs a freed pid out of every set (PRC_FG_SCRUB), so a
* REUSED pid is never named by mistake.
*
* Each victim: zombie + STATUS_INTR + the tty and alt-screen
* backstops + wake its parent, honouring its own INT
* disposition (IGN skips, CATCH pends+wakes, DFL dies) exactly
* as before. Fds are NOT closed here (MLI from tick context is
* illegal); the parent's reap does that. Returns carry SET if
* K_CURPID was among the killed, so SCH_TICK switches away
* without requeueing the zombie.
*
* PRC_STOP_SWP -- the ^Z SUSPEND sweep (docs/JOB-CONTROL.md
* Increment B) is the SAME scan with PRC_SWP_MODE set: the same
* console row, the same victim set (the job's live pids and
* their descendants, so a `sh SCRIPT` job stops whole), the
* same wake-the-parent tail and the same carry contract (set =
* K_CURPID was stopped; SCH_TICK switches away with no
* requeue). What differs at :victim: the victim is marked
* PCB_STOPPED with WCHAN 0 -- NOT zombied, no exit status, its
* bank and fds intact -- and only the tty backstop fires
* (PRC_TMD_RST: a ^Z'd raw-mode program must not leave the
* glass wedged), never PRC_ALT_RST (it still owns its alt-
* store: suspended, not dead). ^Z is a console-driver sweep,
* not a signal (docs/SIGNALS.md sec 1 has no stop action): no
* disposition is consulted, the job cannot decline. A pid that
* is ALREADY stopped is skipped by both modes -- it is not in
* any foreground set the shell keeps current, and if a stale
* entry named it, ^C must not kill a job the user parked.
*
* NO CONSOLE-SHELL GUARD NEEDED (PRC_KILL's 2026-09-14 refusal
* of the console shell is gone, RULINGS-1; restated for TAB-A2,
* 2026-10-18): a shell that declares its CHILDREN is never a
* member, and PRC_FG_HAS only walks UP from a candidate, so it
* can never match. A shell that declares ITSELF (TCSETFG naming
* the caller: the userland line editor at the idle prompt) is a
* member, but a SELF set (count bit 7) matches its members
* EXACTLY -- PRC_FG_HAS does not walk to the parent -- so the
* shell is a victim only as itself, and its children (a `&`
* job, a stopped job's running stages) are out of reach. The
* shell survives because it CATCHes INT and TSTP around the
* declare (sh's bracket: CATCH before, {0} before restoring);
* ^C reaches it as ERR_INTR, never as death. There is no guard
* to add here.
*---------------------------------------------------------------
PRC_STOP_SWP
            ldx   #1
            stx   PRC_SWP_MODE           ;1 = stop
            bra   PRC_FG_SWP
PRC_INTR_SWP
            stz   PRC_SWP_MODE           ;0 = kill
PRC_FG_SWP
            stz   P_COUNT                ;current-killed flag
            dec                          ;console+1 -> index
            cmp   #VC_FGJ_ROWS
            bcc   :conok
            jmp   :done                  ;no console: nothing
:conok      sta   PRC_SWP_CON
            jsr   PRC_FG_LOAD            ;PRC_FG_SET = its job
            ldx   #1
:scan       cpx   #PCB_COUNT
            bne   :body
            jmp   :done                  ;loop body outgrew beq
:body       txa
            jsr   PCB_PTR_FOR
            phx
            lda   #0
            sta   BANKSEL
            lda   #PCB_STATE
            ldx   #4
            jsr   PCB_RD_FIELDS          ;state,wchan,bank,par
            plx
            lda   K_PCB_SCRATCH
            beq   :skip                  ;unused
            cmp   #PCB_ZOMBIE
            beq   :skip
            cmp   #PCB_STOPPED
            beq   :skip                  ;parked: see header
            lda   K_PCB_SCRATCH+3        ;parent pid
            bne   :haspar                ;root tier: protected
:skip       jmp   :next                  ;grew past beq's reach
:haspar
            sta   PRC_INTR_PAR
            phx                          ;PRC_FG_HAS walks PCBs
                                         ;-- clobbers X, the
                                         ;scan index
            txa
            jsr   PRC_FG_HAS             ;in the job's subtree?
            plx
            bcs   :victim
            jmp   :next
:victim     lda   PRC_SWP_MODE
            beq   :depth3
*-- STOP mode (docs/JOB-CONTROL.md Increment E): consult the
*-- victim's SIG_TSTP disposition, as :depth3 does for INT.
*-- Signo 14 is bit 13 -> the mask's HI byte, $20. CATCH:
*-- deliver TSTP (pending + wake -> ERR_INTR) and let it stop
*-- ITSELF (vi: rmcup, SYS_STOP, smcup; the parent wakes in
*-- PRC_STOP). IGN: ^Z is a no-op. DFL: direct-stop below (a
*-- program that does not catch ^Z, today's behaviour).
            phx
            txa
            jsr   PRC_SIG_RD
            plx
            lda   K_PCB_SCRATCH+3       ;TSTP IGN (hi $20)
            and   #$20
            beq   :zchk
            jmp   :next
:zchk       lda   K_PCB_SCRATCH+1       ;TSTP CATCH (hi $20)
            and   #$20
            beq   :zdfl
            phx
            txa
            ldx   #SIG_TSTP
            jsr   PRC_SIG_SND
            plx
            jmp   :next
*-- DFL: mark PCB_STOPPED, clear WCHAN and the wait shadow (a
*-- BLOCKED victim must never be woken back to RUNNABLE by its
*-- channel -- SCH_WAKEUP matches the SHADOW only, so clearing
*-- it here is load-bearing, WAKE-1), restore its tty, then
*-- the shared wake-the-parent tail. On resume (SYS_CONT) a
*-- victim that was blocked in a
*-- syscall simply retries it: PRC_BLCK_RTRY rewound its PC.
:zdfl       txa
            jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            sta   RAMWRTAUX
            lda   #PCB_STOPPED
            ldy   #PCB_STATE
            sta   (K_PCB_PTR),y
            lda   #0
            ldy   #PCB_WCHAN
            sta   (K_PCB_PTR),y
            sta   RAMWRTMAIN
            sta   K_WAIT_SHD,x           ;A = 0: leaves the wait
                                         ;shadow (main, after
                                         ;the bracket)
            phx
            txa
            jsr   PRC_TMD_RST
            plx
            bra   :wakepar
:depth3
*-- the victim's INT disposition (docs/SIGNALS.md): IGN skips,
*-- CATCH pends+wakes (a trapping script sh SURVIVES ^C and
*-- runs its trap), DFL dies exactly as before. $02 is bit
*-- signo-1 for signal 2, spelled inline -- tick context wants
*-- no extra jsr depth for a constant.
            phx
            txa
            jsr   PRC_SIG_RD             ;clobbers K_PCB_PTR --
            plx                          ;re-derived below
            lda   K_PCB_SCRATCH+2        ;IGN lo
            and   #$02
            beq   :notign
            jmp   :next
:notign
            lda   K_PCB_SCRATCH+0        ;CATCH lo
            and   #$02
            bne   :catch2
            phx                          ;PRC_DIE clobbers X,
            txa                          ;scan index; A=victim
            ldx   #STATUS_INTR
            jsr   PRC_DIE                ;marking + backstops
            plx
*-- A killed foreground job takes the empty line TTY_INTR queued
*-- with it: a killed READER (cat) was woken by that line but
*-- never ran to consume it, so it would reach the shell's next
*-- READLINE and reprompt twice (TTYPEAHEAD-BELL Part 3; SIGINT
*-- flushes the tty queue). VC_STATE is the typing console's.
            stz   VC_IN_LEN
:wakepar    lda   PRC_INTR_PAR
            phx                          ;SCH_WAKEUP scans PCBs
                                         ;-- clobbers X, and X
                                         ;is the scan index
                                         ;(same trap as
                                         ;PRDPAR_FIELD above --
                                         ;the unbracketed call
                                         ;ran the scan away
                                         ;through the annex)
            jsr   SCH_WAKEUP
            lda   PRC_SWP_CON            ;both modes' backstop,
            jsr   PRC_FG_LOAD            ;PRC_TMD_RST, reloaded
            plx                          ;PRC_FG_SET back
            cpx   K_CURPID
            bne   :next
            lda   #1
            sta   P_COUNT
            bra   :next
:catch2     phx
            txa
            ldx   #2
            jsr   PRC_SIG_SND
            plx
:next       inx
            jmp   :scan
* -- Restore $C073 before returning: the tick exit path
* -- INTENTIONALLY does not rewrite it (KRN_IRQ_SVC :sameproc
* -- -- "always resumes the bank that was interrupted"), so a
* -- tick-context routine that touches BANKSEL must put the
* -- current bank back or the exit "resumes" the process in
* -- bank 0 -- the annex, unstamped LC, garbage frame, monitor
* -- break. Found the hard way 2026-08-19; same obligation
* -- TTY_WAKE_RDRS discharges via the same call.
:done       lda   PRC_SWP_MODE           ;a KILL sweep adopts
            bne   :nodie                 ;ONCE, after the whole
            jsr   PRC_ADOPT              ;sweep (ORPHAN-1)
:nodie      jsr   PRC_SEL_CRBNK
            lda   P_COUNT
            beq   :none
            sec
            rts
:none       clc
            rts

PRC_INTR_PAR ds 1
PRC_SWP_MODE ds 1                        ;0 kill (^C), 1 stop
PRC_SWP_CON  ds 1                        ;the sweep's console

*---------------------------------------------------------------
* PRC_DIE -- a FORCED death, ONE copy: PRC_INTR_SWP's :depth3
* (^C), PRC_KILL's :force and PRC_BRK_TRAP all end here, so "a
* change to the marking discipline belongs in BOTH routines" is
* now one change. IN: A = the victim's pid, X = its wait status
* ($80|signo). The victim goes ZOMBIE with WCHAN 0 and that
* status; its fds and bank stay for the parent's reap, so this
* is legal in tick context. Then the CRASH-SAFETY BACKSTOP
* (stty seed, 2026-09-02): the victim's OWN console (its fd0,
* if one) goes back to cooked+echo -- a raw-mode reader killed
* here must not leave the glass wedged -- and its alt-screen,
* if it held one, goes back too (tty5.s). Scoped to FORCIBLE
* death only, never PRC_EXIT's voluntary path: `stty raw -echo`
* followed by a SEPARATE `cat` has to survive stty's own clean
* exit, or the set-then-run idiom could never work. The caller
* wakes the parent. Clobbers A, X, Y, K_PCB_PTR, P_PID, P_FD,
* K_BC_*; ends in PRC_ALT_RST's PRC_SEL_CRBNK, so $C073 is the
* current bank's again.
*---------------------------------------------------------------
PRC_DIE
            pha
            jsr   PRC_ZOMB
            pla
            pha
            jsr   PRC_TMD_RST
            pla
            jmp   PRC_ALT_RST

*---------------------------------------------------------------
* PRC_BRK_TRAP -- K_BRK_VEC's target in every image with a
* process layer (PRC_INIT): a USER BRK is the process's fault,
* not the machine's. `$00` is BRK, so a jump into zeroed memory,
* a one-byte `$00` file, a corrupted binary or a wild pointer
* all land here; the base kernel parked the WHOLE machine in
* KRN_BRK_TRAP, with interrupts masked, for every one of them.
* Now the process dies with SIGTRAP (signal 5, V7's number: BRK
* is the 6502's breakpoint instruction, a PDP-11 BPT's class),
* wait status STATUS_TRAP, and the machine carries on.
*
* Context: KRN_IRQ_ENTRY's :isbrk, tick context -- ALTZP main,
* the BRK frame left on the process's own stack, K_CURPID the
* process that executed it. Only a BRK taken with ALTZP=aux gets
* here (entry.s says why), so there is no kernel/user test to
* make. It is the ^C sweep's own tail: PRC_DIE (marking,
* backstops), wake the parent, SCH_SWITCH with requeue 0 -- the
* current process is a zombie -- and join KRN_IRQ_SVC where it
* resumes the incoming process. Like ^C it is NOT catchable:
* there is nothing to resume after a fault.
*
* Refused (carry to the halt, marker and all): a root-tier
* process, parent 0. That is pid 1, init -- its death leaves
* nothing to respawn the shell -- and the idle process, which
* the scheduler cannot do without. The CONSOLE SHELL is not
* refused: init respawns it. (PRC_KILL refused it from
* 2026-09-14, before init existed; RULINGS-1 lifted that.)
*---------------------------------------------------------------
PRC_BRK_TRAP
            lda   K_CURPID
            sta   P_PID
            jsr   PRDPAR_FIELD
            lda   K_PCB_SCRATCH          ;parent pid
            beq   :halt                  ;root tier
            sta   PRC_KILL_PAR
            lda   K_CURPID
            ldx   #STATUS_TRAP
            jsr   PRC_DIE
*-- A FAULTED PROCESS'S BANK IS NOT RETAINED. LZ_RETAIN re-reads
*-- only the eight head bytes, so text a wild write corrupted
*-- would be reused warm with no reload. Drop the tag here; the
*-- reap then frees the bank plainly. (check-brk A6.)
            lda   K_CURBANK
            jsr   LZ_FIND_BNK
            bcs   :untagged
            jsr   LZ_DROP
:untagged   jsr   PRC_ADOPT             ;its children: init
            lda   PRC_KILL_PAR
            jsr   SCH_WAKEUP
            lda   #0                     ;requeue=0: a zombie
            jsr   SCH_SWITCH
            jmp   KRN_IRQ_SW
:halt       jmp   KRN_BRK_TRAP

*---------------------------------------------------------------
* PRC_FG_LOAD -- A = console index: K_PCB_PTR := &VC_FGJOB[A]
* (annex row, BANKSEL left at 0) and PRC_FG_SET := its 4 bytes
* {count, pid0, pid1, pid2}. One PCB_RD_FIELDS, the sweep's own
* reader. Clobbers A, X, K_PCB_SCRATCH.
*---------------------------------------------------------------
PRC_FG_LOAD
            asl
            asl                          ;console*VC_FGJ_STRIDE
            clc
            adc   #<VC_FGJOB_ADDR
            sta   K_PCB_PTR
            lda   #>VC_FGJOB_ADDR
            adc   #0
            sta   K_PCB_PTR+1
            lda   #0
            sta   BANKSEL
            lda   #0
            ldx   #VC_FGJ_STRIDE
            jsr   PCB_RD_FIELDS
            ldx   #VC_FGJ_STRIDE-1
:cp         lda   K_PCB_SCRATCH,x
            sta   PRC_FG_SET,x
            dex
            bpl   :cp
            rts

*---------------------------------------------------------------
* PRC_FG_HAS -- A = pid: carry SET iff that pid, or an ancestor
* of it, is in PRC_FG_SET's three pid slots (slot 0 is the
* count, never compared). EXCEPT a SELF set (count bit 7, set
* by TCSETFG when it names the caller): its members match only
* as the candidate itself, never as an ancestor. Walks the
* parent chain until it hits
* a member or the root tier; PRC_FG_DEPTH bounds the walk so a
* corrupt chain cannot spin the tick. A 0 slot never matches:
* the walk stops BEFORE comparing a parent of 0. Clobbers A, X,
* Y, P_PID, K_PCB_PTR, K_PCB_SCRATCH.
*---------------------------------------------------------------
PRC_FG_HAS  sta   P_PID
            lda   #8
            sta   PRC_FG_DEPTH
:walk       ldy   #VC_FGJ_STRIDE-1
:cmp        lda   PRC_FG_SET,y
            cmp   P_PID
            beq   :yes
            dey
            bne   :cmp                   ;slots 3..1
            bit   PRC_FG_SET             ;count bit 7: SELF set
            bmi   :no                    ;exact members only
            jsr   PRDPAR_FIELD           ;parent of P_PID
            lda   K_PCB_SCRATCH
            beq   :no                    ;root tier reached
            sta   P_PID
            dec   PRC_FG_DEPTH
            bne   :walk
:no         clc
            rts
:yes        sec
            rts

*---------------------------------------------------------------
* PRC_FG_SCRUB -- A = a pid whose PCB slot is being FREED (the
* wait reap, process2.s): zero it out of every console's
* foreground set. Closes the reuse window: `A | B` foreground,
* A reaped while B still runs, a background job forks into A's
* freed bank -- pid == bank -- and a ^C would have named the
* newcomer. Syscall context; one row read and at most one byte
* written per console. Clobbers A, X, Y, K_PCB_PTR,
* K_PCB_SCRATCH, PRC_FG_SET, PTF_CON, PTF_PID; BANKSEL left 0
* (the caller's return path restores it).
*---------------------------------------------------------------
PRC_FG_SCRUB
            sta   PTF_PID
            lda   #VC_FGJ_ROWS-1
            sta   PTF_CON
:row        lda   PTF_CON
            jsr   PRC_FG_LOAD            ;K_PCB_PTR = the row
            ldy   #VC_FGJ_STRIDE-1
:slot       lda   PRC_FG_SET,y
            cmp   PTF_PID
            bne   :nxslot
            lda   #0
            sta   RAMWRTAUX              ;BANKSEL is 0 (LOAD)
            sta   (K_PCB_PTR),y
            sta   RAMWRTMAIN
:nxslot     dey
            bne   :slot                  ;slots 3..1
            dec   PTF_CON
            bpl   :row
            rts

*---------------------------------------------------------------
* PRC_TCSETFG -- tcsetfg(&{count,pid0,pid1,pid2}) = SYS_TCSETFG
* (docs/JOB-CONTROL.md Increment A): the caller declares the
* foreground job of ITS console, and PRC_INTR_SWP above aims ^C
* at it. THE CALLER'S CONSOLE IS ITS FD 0's DEVICE -- exactly
* PRC_TMD_RST's derivation: fd 0 is what puts a shell "on" a
* console (sh decides SH_INTERACT from that same byte), the
* kernel maps it in one PCB read, and it costs no new state and
* nothing for the shell to learn or pass. A caller whose fd 0
* is a pipe, a file or closed has no console: ERR_INVAL.
* Set-time hardening: count <= TCSETFG_MAX and every named pid
* a CHILD of the caller (PCB_PARENT == K_CURPID -- a reaped slot
* has parent 0 and fails this too) OR THE CALLER ITSELF, else
* ERR_INVAL with the set untouched. Slots past count are written
* 0 so the sweep never meets a leftover.
*
* SELF IS NAMEABLE (TAB-A2, 2026-10-18): a shell that reads its
* prompt in raw mode owns the line, so it must be TOLD about ^C
* and ^Z; the sweep reaches only the declared set, and without
* this the shell is never in it -- the interrupt reaches it as a
* bare CR, identical to Return, and the half-typed line runs
* (learning:01M56Q7BH2T3B9TPX7FM47Q0VC; the phantom-CR rule is
* learning:01M284J8X2HESJQ9VQHP8RRD5C). PRC_FG_HAS already
* compares the candidate before its parent, and the caller's
* own INT/TSTP dispositions are honoured as for any member: a
* declaring shell CATCHes both. A set that names the caller is
* marked SELF (count bit 7 in the stored row, TCSETFG's tsb):
* the sweep then matches its members EXACTLY, never their
* subtrees, so the idle shell is the foreground of nothing but
* itself and a `&` job or a stopped job's running stages are
* not victims of its ^C (the review's R1, 2026-10-18). Readers
* of the row mask the count with $7F.
* Gate: check-jobctl-b's tcsetfg rows (src/test/jctest.s).
*---------------------------------------------------------------
PRC_TCSETFG
            lda   #VC_FGJ_STRIDE         ;parm: count + 3 pids
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   K_CURPID
            sta   P_PID
            stz   P_FD
            jsr   PRC_GET_FDOBJ          ;fd 0's object byte
            cmp   #FD_DEV_BASE
            bcc   :inval
            cmp   #FD_TTY3+1
            bcs   :inval
            sec
            sbc   #FD_DEV_BASE
            sta   PTF_CON
            lda   PRC_PARM+0
            cmp   #TCSETFG_MAX+1
            bcs   :inval
            sta   PTF_PID                ;the count, flag-free
            ldx   #0
:chk        cpx   PTF_PID
            beq   :zero
            lda   PRC_PARM+1,x
            beq   :inval                 ;pid 0: never a child
            cmp   #PCB_COUNT
            bcs   :inval
            cmp   K_CURPID               ;the caller itself: ok
            bne   :child
            lda   #$80                   ;mark the set SELF
            tsb   PRC_PARM+0
            bra   :nx
:child      sta   P_PID
            phx                          ;PRDPAR_FIELD eats X
            jsr   PRDPAR_FIELD
            plx
            lda   K_PCB_SCRATCH          ;its parent
            cmp   K_CURPID
            bne   :inval
:nx         inx
            bra   :chk
:zero       cpx   #TCSETFG_MAX
            beq   :store
            stz   PRC_PARM+1,x
            inx
            bra   :zero
:store      lda   PTF_CON
            asl
            asl
            clc
            adc   #<VC_FGJOB_ADDR
            sta   K_PCB_PTR
            lda   #>VC_FGJOB_ADDR
            adc   #0
            sta   K_PCB_PTR+1
            lda   #0
            sta   BANKSEL
            sta   RAMWRTAUX
            ldy   #0
:wr         lda   PRC_PARM,y
            sta   (K_PCB_PTR),y
            iny
            cpy   #VC_FGJ_STRIDE
            bne   :wr
            sta   RAMWRTMAIN
            jmp   PRC_RET_OK0
:inval      lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts

PRC_FG_SET   ds VC_FGJ_STRIDE
PRC_FG_DEPTH ds 1
PTF_CON      ds 1
PTF_PID      ds 1

*---------------------------------------------------------------
* PRC_TMD_RST -- crash-safety backstop (stty seed, 2026-09-02):
* IN: A = a pid that is about to die BY FORCE (kill/^C, never a
* voluntary SYS_EXIT -- see the call site notes for why). If
* its fd0 is bound to a console, that console's VC_TMODE goes
* back to the cooked default -- the same active-vs-annex-slot
* write TTY_TMODE_STO already does for SYS_TTYMODE, so a raw-
* mode reader that gets killed cannot leave the glass wedged.
* A non-console fd0 (file, pipe, closed) touches nothing.
*
* CALLER MUST RUN THIS BEFORE ANY FD-CLOSE ON THE VICTIM: fd0's
* device byte is gone the moment PCLS_ALL_FDS (or PCLS_ONE_FD)
* runs (procfd.s zeroes the table entry for every fd kind,
* devices included) -- see :selfkill below, which closes its
* own fds ahead of the mark and so calls this FIRST.
*
* Tick-context safe: PRC_GET_FDOBJ is a bare BANKSEL/PCB read
* (no MLI), and TTY_TMODE_STO's BankCopy write already runs from
* PRC_INTR_SWP's own tick-context sweep below. Clobbers A, X, Y,
* P_PID, P_FD.
*---------------------------------------------------------------
PRC_TMD_RST
            sta   P_PID
            stz   P_FD
            jsr   PRC_GET_FDOBJ
            cmp   #FD_DEV_BASE
            bcc   :out
            cmp   #FD_TTY3+1
            bcs   :out
            sec
            sbc   #FD_DEV_BASE
            pha                   ;console index, for below
*-- ONLY THE FOREGROUND JOB'S DEATH RESETS THE GLASS. A bg
*-- job inherits fd0 and so names the console too, and its death
*-- (a BRK, a kill) must not cook a foreground raw program's
*-- tty (`./buggy &` then vi). The sweep's victims are in the
*-- foreground job by construction; PRC_FG_LOAD below replaces
*-- PRC_FG_SET, which the sweep reloads at :wakepar.
            jsr   PRC_FG_LOAD
            lda   P_PID
            jsr   PRC_FG_HAS
            bcs   :infg
            pla
            rts
:infg       pla
            pha
            ldy   #TMD_ICANON+TMD_ECHO+TMD_OPOST
            jsr   TTY_TMODE_STO
            pla
*-- A force-killed writer's UNDRAINED output is discarded, but
*-- the console's escape parser may be MID-SEQUENCE on the bytes
*-- that did drain (vi killed during a repaint: "ESC [ 1" in,
*-- "; 1 H" never arrives). The next byte written -- the
*-- shell's own '$' -- is then eaten as the CSI final. Found by
*-- check-vi-alt's killed case on 2026-09-14 (phase-dependent:
*-- it hid behind sh.bin's size). Live console only: a
*-- background slot's half-open escape is already abandoned on
*-- switch-in (tty3.s VC_SWITCH).
            cmp   VC_ACTIVE
            bne   :out
            stz   VC_ESC_STATE
:out        rts

*---------------------------------------------------------------
* PRC_KILL -- SYS_KILL(pid), syscall context. PRC_INTR_SWP
* above is this routine's tick-context TWIN: same marking
* (zombie + $80|signo status + wake the parent, fds left for
* the parent's reap; ^C's own signo is 2), different context
* rules -- here the caller's
* P_*/parm scratch is live and the return travels through
* PRC_RET_OK0/PRC_FAIL_A, which restore the caller's bank
* themselves. The marking is shared (PRC_DIE, PRC_ZOMB). Policy
* is in sc.proc.equ's SYS_KILL note:
* root tier refused (pid 1 and the idle process), kill(self) =
* exit(STATUS_INTR), orphans are the caller's problem. THE
* CONSOLE SHELL is NOT refused: a 2026-09-14 rule did, because
* no init existed to respawn it, and RULINGS-1 (2026-10-18)
* lifted it -- init respawns it (with a back-off, KFIX7), the
* same reasoning PRC_BRK_TRAP's header already records.
* PRC_DIE's tty backstop resets only a victim in its console's
* FOREGROUND set; the shell, blocked in WAIT on this very kill,
* is not in it (at the PROMPT it is, as a SELF set: TAB-A2),
* so after a shell kill the console mode is the
* successor shell's start-up stamp's job (shlex.s).
*---------------------------------------------------------------
PRC_KILL
            lda   #2              ;parm: target pid, signo
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
*-- the SIGNO is carried through the ABI even though DELIVERY
*-- does not exist yet: the victim's wait status is $80|signo
*-- (STATUS_INTR $82 is exactly this encoding for ^C's signal
*-- 2), so kill's default 15 reaps $8F, -9 reaps $89, and the
*-- lanes stop being conflated -- when `trap` lands, default
*-- kills become catchable and -9 stays forced, with no ABI
*-- change. Signo 0 is V7's liveness probe: validate the pid,
*-- kill nothing.
:parmsok    lda   PRC_PARM+0
            beq   :badpid         ;pid 0: never a target
            cmp   #PCB_COUNT
            bcc   :pidok
:badpid     jmp   :nosuch         ;grew past beq's reach
:pidok
            cmp   K_CURPID
            bne   :other
            jmp   :self                  ;grew past beq's reach
:other      jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            lda   #PCB_STATE
            ldx   #4
            jsr   PCB_RD_FIELDS   ;state,wchan,bank,parent
            lda   K_PCB_SCRATCH
            beq   :badpid2        ;unused slot
            cmp   #PCB_ZOMBIE
            bne   :slotok         ;already dead. STOPPED is
                                  ;alive here -- kill -9 of a
                                  ;parked job works (docs/JOB-
                                  ;CONTROL.md Increment B)
:badpid2    jmp   :nosuch
:slotok
            lda   K_PCB_SCRATCH+3 ;parent pid
            beq   :roottier       ;boot process: refuse
            sta   PRC_KILL_PAR
            lda   PRC_PARM+1      ;signo 0: probe only -- the
            beq   :probed         ;pid just proved live
*-- DELIVERY (docs/SIGNALS.md): the TARGET's disposition rules,
*-- except 9, which force-kills unconditionally (V7: SIGKILL
*-- "cannot be caught or ignored"). IGN discards at the sender;
*-- CATCH pends + wakes a blocked target so its retried syscall
*-- meets PRC_BLCK_RTRY's ERR_INTR check; DFL falls through to
*-- the kill below, unchanged.
            cmp   #9              ;A = signo (nonzero, above)
            beq   :force
            lda   PRC_PARM+0
            jsr   PRC_SIG_DSP     ;clobbers K_PCB_PTR -- the
            cmp   #SIGA_IGN       ;kill path re-derives it
            beq   :probed         ;discarded: report OK
            cmp   #SIGA_CATCH
            bne   :force
            lda   PRC_PARM+0
            ldx   PRC_PARM+1
            jsr   PRC_SIG_SND
            jmp   PRC_RET_OK0
:force      lda   PRC_PARM+1
            and   #$7F
            ora   #$80            ;died-by-signal + signo, the
            tax                   ;STATUS_INTR encoding
            lda   PRC_PARM+0
            jsr   PRC_DIE         ;marking + backstops
            jsr   PRC_ADOPT       ;its children go to init
            lda   PRC_KILL_PAR
            jsr   SCH_WAKEUP
:probed     jmp   PRC_RET_OK0
:nosuch     lda   #ERR_SRCH
            jsr   PRC_FAIL_A
            rts
:roottier   lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
*-- kill(self) is exit(STATUS_INTR): PRC_EXIT's own tail,
*-- verbatim (process2.s:200), with the status forced -- its
*-- parm slot holds OUR pid, not an exit status, so the exit
*-- path cannot be entered at its top.
*-- kill(self, 0) is also just a probe -- you are alive.
:self       lda   PRC_PARM+1
            bne   :selfsig
            jmp   PRC_RET_OK0
*-- kill(self, signo): same disposition rules -- a caught signal
*-- pends against OURSELVES (we are running; no wake needed) and
*-- the syscall returns. NOT sh's `kill -2 $$`: kill is
*-- /bin/kill, so `$$` names another process (the shell) and
*-- that is the :other lane. Only a process signalling its OWN
*-- pid reaches here (processtestb2.s 15e/16b/16c); no shipped
*-- tool does.
:selfsig    cmp   #9
            beq   :selfkill
            lda   K_CURPID
            jsr   PRC_SIG_DSP
            cmp   #SIGA_IGN
            beq   :selfok
            cmp   #SIGA_CATCH
            bne   :selfkill
            lda   K_CURPID
            ldx   PRC_PARM+1
            jsr   PRC_SIG_SND
:selfok     jmp   PRC_RET_OK0
:selfkill   lda   K_CURPID
            sta   P_PID
            jsr   PRDPAR_FIELD
            lda   K_PCB_SCRATCH
            sta   PRC_KILL_PAR
            lda   K_CURPID          ;crash-safety backstop --
            jsr   PRC_TMD_RST       ;BEFORE PCLS_ALL_FDS clears
                                    ;fd0's device byte below
            lda   K_CURPID          ;alt-screen twin (tty5.s)
            jsr   PRC_ALT_RST
            lda   K_CURPID
            sta   P_PID
            jsr   PCLS_ALL_FDS
            lda   PRC_PARM+1
            and   #$7F
            ora   #$80
            tax
            lda   K_CURPID
            jsr   PRC_ZOMB
            jsr   PRC_ADOPT         ;children of the dead:
                                    ;PRC_EXIT's own step
            lda   PRC_KILL_PAR
            beq   :nowake
            jsr   SCH_WAKEUP
:nowake     lda   #0
            jsr   SCH_SWITCH
            stz   K_RESULT
            stz   K_RESULT_ERR
            rts

PRC_KILL_PAR ds 1
