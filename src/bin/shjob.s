*---------------------------------------------------------------
* shjob.s -- the job table and `jobs` / `fg` / `bg` (docs/JOB-
* CONTROL.md Increment C), `put` by src/bin/sh.s after
* shtrap.s -- the same put-module shape as every other body
* module; see shbltn.s's header for the scope rules.
*
* ONE TRUTH: every pipeline RUN_PIPELINE spawns gets a job-table
* row (JOB_ALLOC before the spawn loop, JOB_SETPIDS after it).
* A `&` pipeline keeps its row Running (JOB_BG); a foreground
* one is waited on through FG_WAIT and freed when it completes,
* or kept as Stopped when ^Z parks it. BG_PIDS/BG_CNT (docs/
* SH-BG.md) are GONE -- the table is what `wait` drains now, so
* there are not two lists of children to drift apart.
*
* THE ROW (all in sh.s's dum arena, indexed by job number - 1):
*   JOB_ST    0 free / JS_RUN / JS_STOP / JS_DONE (reaped, the
*             notice not yet printed)
*   JOB_PID   MAXCMD member pids, zeroed one by one as reaped
*   JOB_TAIL  the last stage's pid -- its status is the job's
*   JOB_EXST  that status once known: exit code, or $80|signo,
*             the SAME shape legacy wait's one byte had
*   JOB_TXT   the command text for `jobs`, rebuilt from CMD_ARGV
*             at JOB_ALLOC (LINEBUF is tokenised in place, so
*             the line itself is gone by then)
* JOB_CUR/JOB_PREV hold %+ and %- as job numbers (0 = none);
* JOB_FG is the row FG_WAIT is waiting on, 0 at the prompt.
*
* THE WAIT MODES, and why there are three (FG_WAIT). The kernel
* reports the LOWEST-pid ready child, and WJ_UNTRACED makes a
* STOPPED child "ready" on EVERY call (process2.s PRC_WAIT_CORE,
* the report-once invariant lives with the consumer). So the
* moment a second job is parked, a WUNTRACED wait on the first
* never blocks -- it returns the parked pid forever. Hence:
*   no other job Stopped     -> WJ_UNTRACED, blocking (the
*                               common case, the fast path)
*   a parked job, nothing    -> flags 0, blocking: a ^Z on the
*   else Running                fg job leaves every child
*                               stopped, the kernel returns
*                               ERR_CHILD rather than sleep on a
*                               set nothing can wake, and
*                               SYS_PSTAT says which
*   a parked job AND a       -> WJ_NOHANG + SYS_PSTAT, polled.
*   Running one                 The only shape with no blocking
*                               primitive that can see the stop.
*                               Costs the fg job its quanta; a
*                               pid-filtered wait (waitpid) in
*                               the kernel would retire it.
* A NON-INTERACTIVE sh has no job control (POSIX: set -m is off
* in a script) and always uses flags 0: it is INSIDE the job its
* interactive parent declared, and when that parent `fg`s it,
* SYS_CONT resumes only the named child (it is parent-only), so
* the script sh finds ITS children still stopped -- and
* continues them itself, tier by tier. That is what makes `fg`
* of a `sh SCRIPT` job resume the whole subtree.
*---------------------------------------------------------------
JS_RUN      equ   1
JS_STOP     equ   2
JS_DONE     equ   3
JOBTXTLEN   equ   32         ;`jobs` text per row, NUL incl.

*---------------------------------------------------------------
* JOB_ALLOC -- take the lowest free row for the pipeline PARSE
* just built (NCMD/CMD_ARGC/CMD_ARGV), mark it Running, clear
* its tail/status, rebuild the command text, and make it JOB_FG.
* OUT: carry set = table full (nothing changed); else carry
* clear, X = row. Uses STAGEI as ARGV_PTR_STG's cursor -- the
* caller (RUN_PIPELINE :pipesdone) zeroes it right after.
* CLOBBERS: A, X, Y, PTR0, PTR1, PTR2, STAGEI.
*---------------------------------------------------------------
JOB_ALLOC   ldx   #0
:scan       lda   JOB_ST,x
            beq   :got
            inx
            cpx   #BGMAX
            bne   :scan
            sec
            rts
:got        lda   #JS_RUN
            sta   JOB_ST,x
            stz   JOB_TAIL,x
            stz   JOB_EXST,x
            inx
            stx   JOB_FG
            dex
            jsr   JOB_TXTPTR
            stz   JTX_N
            stz   STAGEI
:stage      jsr   ARGV_PTR_STG           ;PTR1 = stage argv
            stz   JTX_A
:arg        ldx   STAGEI
            lda   JTX_A
            cmp   CMD_ARGC,x
            beq   :stgdone
            asl   a
            tay
            lda   (PTR1),y
            sta   PTR0
            iny
            lda   (PTR1),y
            sta   PTR0+1
            lda   JTX_N
            beq   :word
            lda   #$A0                   ;blank before every
            jsr   JTX_PUT                ;word but the first
:word       ldy   #0
:cpy        lda   (PTR0),y
            beq   :wordend
            jsr   JTX_PUT
            iny
            bra   :cpy
:wordend    inc   JTX_A
            bra   :arg
:stgdone    inc   STAGEI
            lda   STAGEI
            cmp   NCMD
            beq   :txend
            lda   #$A0
            jsr   JTX_PUT
            lda   #$FC                   ;'|' between stages
            jsr   JTX_PUT
            bra   :stage
:txend      ldy   JTX_N
            lda   #0
            sta   (PTR2),y
            ldx   JOB_FG
            dex
            clc
            rts

*-- JTX_PUT -- append A to the row's text at JTX_N, clamped so
*-- the NUL always fits (EMITB's own reserve-the-last-slot
*-- shape). Preserves Y. CLOBBERS: A, X.
JTX_PUT     ldx   JTX_N
            cpx   #JOBTXTLEN-1
            bcs   :full
            phy
            ldy   JTX_N
            sta   (PTR2),y
            ply
            inc   JTX_N
:full       rts

*---------------------------------------------------------------
* JOB_TXTPTR -- PTR2 = JOB_TXT + X*JOBTXTLEN (16-bit: 14 rows of
* 32 is past one page). Preserves X. CLOBBERS: A.
*---------------------------------------------------------------
JOB_TXTPTR  stz   PTR2+1
            txa
            asl   a
            asl   a
            asl   a
            asl   a                      ;13*16 < 256: no carry
            asl   a                      ;yet; the fifth may
            rol   PTR2+1
            clc
            adc   #<JOB_TXT
            sta   PTR2
            lda   PTR2+1
            adc   #>JOB_TXT
            sta   PTR2+1
            rts

*---------------------------------------------------------------
* JOB_PIDIDX -- Y = X*MAXCMD, the row's first JOB_PID slot. The
* x3 below is MAXCMD (3); JOB_FREE zeroes that many slots.
* Preserves X. CLOBBERS: A.
*---------------------------------------------------------------
JOB_PIDIDX  txa
            sta   JTMP
            asl   a
            adc   JTMP                   ;asl left carry clear
            tay
            rts

*---------------------------------------------------------------
* JOB_SETPIDS -- RUN_PIPELINE's post-spawn half of JOB_ALLOC:
* copy CMD_PID[0..NCMD) into JOB_FG's row (unused slots 0) and
* record the tail stage's pid. OUT: carry set = NO stage
* spawned -- the row is freed and JOB_FG cleared, nothing to
* wait for. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
JOB_SETPIDS ldx   JOB_FG
            dex
            jsr   JOB_PIDIDX
            stz   JTMP
            ldx   #0
:cp         lda   #0
            cpx   NCMD
            bcs   :st
            lda   CMD_PID,x
:st         sta   JOB_PID,y
            ora   JTMP
            sta   JTMP
            iny
            inx
            cpx   #MAXCMD
            bne   :cp
            ldx   NCMD
            dex
            lda   CMD_PID,x
            ldx   JOB_FG
            dex
            sta   JOB_TAIL,x
            lda   JTMP
            beq   :none
            clc
            rts
:none       jsr   JOB_FREE
            stz   JOB_FG
            sec
            rts

*---------------------------------------------------------------
* JOB_FREE -- release row X; %+ falls back to %- when the
* current job goes. The row's PIDS are zeroed too (G3):
* JOB_FIND searches every row, free or not, and a row freed
* while it still held a pid (an abandoned wait, a `wait` that
* marked it Done) would match that pid for ever. Entry zeroing
* (shlex.s SH_INIT_ZR) is NOT redundant: it covers a killed
* shell's table, whose rows were never freed.
* Preserves X, Y. CLOBBERS: A, JTMP.
*---------------------------------------------------------------
*-- MAXCMD = 3 pid slots per row: JOB_PIDIDX's x3 and the
*-- three stores below are one constant (H11): change together.
JOB_FREE    stz   JOB_ST,x
            phy
            jsr   JOB_PIDIDX
            lda   #0
            sta   JOB_PID,y
            sta   JOB_PID+1,y
            sta   JOB_PID+2,y
            ply
            inx
            cpx   JOB_CUR
            beq   :wascur
            cpx   JOB_PREV
            bne   :out
            stz   JOB_PREV
            bra   :out
:wascur     lda   JOB_PREV
            sta   JOB_CUR
            stz   JOB_PREV
:out        dex
            rts

*---------------------------------------------------------------
* JOB_MKCUR -- row X becomes %+ (the old %+ becomes %-): on `&`,
* on a ^Z stop, on `fg`. Preserves X. CLOBBERS: A.
*---------------------------------------------------------------
JOB_MKCUR   inx
            cpx   JOB_CUR
            beq   :same
            lda   JOB_CUR
            sta   JOB_PREV
            stx   JOB_CUR
:same       dex
            rts

*---------------------------------------------------------------
* JOB_FIND -- which row holds pid A? OUT: carry clear, X = row,
* Y = the flat JOB_PID index; carry set = not a job member (a
* `$( )` child, or a pid the table never had). CLOBBERS: A.
*---------------------------------------------------------------
JOB_FIND    sta   JTMP
            ldy   #0
:scan       lda   JOB_PID,y
            cmp   JTMP
            beq   :hit
            iny
            cpy   #BGMAX*MAXCMD
            bne   :scan
            sec
            rts
:hit        ldx   #0                     ;row = Y / MAXCMD
            tya
:div        cmp   #MAXCMD
            bcc   :out
            sbc   #MAXCMD
            inx
            bra   :div
:out        clc
            rts

*---------------------------------------------------------------
* JOB_REAP -- SC_WAITJOB reported pid A exited/signalled with
* WJSTAT = {kind, code}: clear its slot, keep the tail's status,
* and mark the row Done once every member is gone. OUT: carry
* clear, X = row; carry set = not ours. CLOBBERS: A, Y.
*---------------------------------------------------------------
JOB_REAP    jsr   JOB_FIND
            bcs   :out
            lda   #0
            sta   JOB_PID,y
            lda   JTMP
            cmp   JOB_TAIL,x
            bne   :notail
            stz   JOB_TAIL,x
            lda   WJSTAT+1
            ldy   WJSTAT
            cpy   #WJ_SIGNALED
            bne   :st
            ora   #$80
:st         sta   JOB_EXST,x
:notail     jsr   JOB_PIDIDX
            lda   JOB_PID,y
            ora   JOB_PID+1,y
            ora   JOB_PID+2,y
            bne   :live
            lda   #JS_DONE
            sta   JOB_ST,x
:live       clc
:out        rts

*---------------------------------------------------------------
* JOB_OTHER -- is any row OTHER than JOB_FG's in state A? At the
* prompt JOB_FG is 0, so every row counts. OUT: carry set = yes.
* CLOBBERS: A, X.
*---------------------------------------------------------------
JOB_OTHER   sta   JTMP
            ldx   #0
:scan       lda   JOB_ST,x
            cmp   JTMP
            bne   :next
            inx
            cpx   JOB_FG
            beq   :chk                   ;the fg row itself
            sec
            rts
:next       inx
:chk        cpx   #BGMAX
            bne   :scan
            clc
            rts

*---------------------------------------------------------------
* JOB_ISFG -- carry set iff row X is JOB_FG's. Preserves X.
*---------------------------------------------------------------
JOB_ISFG    inx
            cpx   JOB_FG
            beq   :yes
            dex
            clc
            rts
:yes        dex
            sec
            rts

*---------------------------------------------------------------
* JOB_PSTOP -- SYS_PSTAT every live member of row X: carry set
* iff one is PCB_STOPPED. The kernel's own answer, for the two
* wait modes that cannot ask WJ_UNTRACED. Preserves X.
* CLOBBERS: A, Y, PTR0.
*---------------------------------------------------------------
JOB_PSTOP   stx   JTMP2
            jsr   JOB_PIDIDX
            sty   JTMP3
            ldx   #MAXCMD
:member     ldy   JTMP3
            lda   JOB_PID,y
            beq   :next
            stx   JTMP4
            ldx   #<PSBUF
            stx   PTR0
            ldx   #>PSBUF
            stx   PTR0+1
            jsr   SC_PSTAT
            ldx   JTMP4
            bcs   :next
            lda   PSBUF+PCB_STATE
            cmp   #PCB_STOPPED
            beq   :yes
:next       inc   JTMP3
            dex
            bne   :member
            ldx   JTMP2
            clc
            rts
:yes        ldx   JTMP2
            sec
            rts

*---------------------------------------------------------------
* JOB_CONTJ -- SYS_CONT every live member of row X. A member
* that is not stopped is refused ERR_INVAL and that is fine:
* `A | B` where A exited before the ^Z has one stopped member
* and one empty slot. Preserves X. CLOBBERS: A, Y.
*---------------------------------------------------------------
JOB_CONTJ   stx   JTMP2
            jsr   JOB_PIDIDX
            ldx   #MAXCMD
:member     lda   JOB_PID,y
            beq   :next
            phy
            phx
            jsr   SC_CONT
            plx
            ply
:next       iny
            dex
            bne   :member
            ldx   JTMP2
            rts

*---------------------------------------------------------------
* FG_WAIT -- wait for JOB_FG's row, the way RUN_PIPELINE's
* :waitloop did with SC_WAIT, but through SC_WAITJOB so a ^Z is
* SEEN (the three modes: this file's header). Every child's
* report that arrives meanwhile is demuxed into the table, not
* dropped. Exits:
*   the row's tail reaped and every member gone -> $? = the
*     tail's status (a stage that never spawned has tail 0 and
*     matches nothing, so `X > LOCKED`'s 1 from :redirfail
*     stands -- the same rule :waitloop kept), row freed;
*   a member Stopped -> row Stopped and current, `[n]+ Stopped
*     cmd` on fd 2, back to the prompt;
*   ERR_INTR (a trapping script sh woken by ^C, docs/SIGNALS.md
*     sec 3) -> abandon the wait exactly as :waitloop's `bcs
*     :done` did; the row stays Running and the prompt-time
*     drain reaps the sweep's victims.
* Always ends in FG_CLEAR: nothing is foreground at the prompt.
* CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
FG_WAIT     lda   SH_INTERACT
            beq   :block0
            lda   #JS_STOP
            jsr   JOB_OTHER
            bcc   :untr
            lda   #JS_RUN
            jsr   JOB_OTHER
            bcc   :block0
            lda   #WJ_NOHANG
            bra   :call
:untr       lda   #WJ_UNTRACED
            bra   :call
:block0     lda   #0
:call       ldx   #<WJSTAT
            stx   PTR0
            ldx   #>WJSTAT
            stx   PTR0+1
            jsr   SC_WAITJOB
            bcs   :err
            tax
            beq   :nothing
            ldy   WJSTAT
            cpy   #WJ_STOPPED
            beq   :stopped
            jsr   JOB_REAP
            bcs   FG_WAIT
            jsr   JOB_ISFG
            bcc   FG_WAIT
            lda   WJSTAT                 ;a foreground death by
            cmp   #WJ_SIGNALED           ;signal is NAMED (V7's
            bne   :notsig                ;await(); shsgsig.s)
            jsr   SIG_FGMSG
:notsig     lda   JOB_ST,x
            cmp   #JS_DONE
            bne   FG_WAIT
:fgdone     lda   JOB_EXST,x
            sta   LASTSTATUS
            jsr   JOB_FREE
            bra   :out
:stopped    jsr   JOB_STOPPED
            bcs   FG_WAIT
            jsr   JOB_ISFG
            bcc   FG_WAIT
:fgstop     lda   #JS_STOP               ;the PSTAT paths arrive
            sta   JOB_ST,x               ;with the row Running
            jsr   JOB_MKCUR
            lda   #FD_STDERR
            sta   JOB_FD
            jsr   PR_JOBLINE
            bra   :out
*-- A poll found nothing ready: ask the kernel whether the fg
*-- job was parked meanwhile; if not, keep polling.
:nothing    ldx   JOB_FG
            dex
            jsr   JOB_PSTOP
            bcs   :fgstop
            jmp   FG_WAIT
*-- ERR_CHILD in a flags-0 wait: every child is stopped (the ^Z
*-- case) or none is left. Anything else is ERR_INTR.
:err        cmp   #ERR_CHILD
            bne   :intr
            ldx   JOB_FG
            dex
            jsr   JOB_PSTOP
            bcc   :fgdone
            lda   SH_INTERACT
            bne   :fgstop
            jsr   JOB_CONTJ              ;a script sh, resumed
            jmp   FG_WAIT                ;by its parent's `fg`:
                                         ;pass the continue on
:intr       jsr   SIG_RETRY              ;untrapped (TERM):
            bcs   :out                   ;not an interruption
            jmp   FG_WAIT                ;(G2)
:out        stz   JOB_FG
            jmp   FG_CLEAR

*-- JOB_STOPPED -- SC_WAITJOB reported pid A stopped: its row is
*-- Stopped. OUT: carry clear, X = row; carry set = not ours.
JOB_STOPPED jsr   JOB_FIND
            bcs   :out
            lda   #JS_STOP
            sta   JOB_ST,x
            clc
:out        rts

*---------------------------------------------------------------
* JOB_BG -- RUN_PIPELINE's `&` tail (BG_RECORD's successor):
* the row stays Running and becomes %+, `$?` = 0 (POSIX: an
* asynchronous list's status is zero -- it does not exist yet),
* and an interactive shell prints `[n] pid`. ANACHRONISMS W4's
* cheap answer to SIGTTOU: a job whose last stage still writes
* the tty is DIAGNOSED, not refused -- redirect it or expect
* the mess. JOB_BGONE is the `( ... ) &` entry (shsub2.s
* CHCK_GROUP): the group spawned outside RUN_PIPELINE, so it
* allocates its row here. CLOBBERS: A, X, Y, PTR0-2.
*---------------------------------------------------------------
JOB_BGONE   jsr   JOB_ALLOC
            bcs   :full                  ;child already runs:
            jsr   JOB_SETPIDS            ;untracked, the way
            bcc   JOB_BG                 ;BG_RECORD dropped a
                                         ;pid past BGMAX
:full       stz   LASTSTATUS
            rts
JOB_BG      ldx   JOB_FG
            dex
*-- `$!` (docs/SH-FEATURES.md, 2026-09-15): X = row (0-based)
*-- here, same as PR_JOBBRK's own JOB_X below -- JOB_TAIL,x is
*-- the row's LAST STAGE pid, which is exactly POSIX's "process
*-- ID of the most recent background command" for a pipeline.
*-- Captured HERE, unconditionally, because the diagnostic print
*-- below this point only runs when SH_INTERACT is set.
            lda   JOB_TAIL,x
            sta   SH_BGPID
            jsr   JOB_MKCUR
            lda   SH_INTERACT
            beq   :quiet
            lda   DUPN
            bne   :redir
            ldx   NCMD
            dex
            txa
            asl   a
            tax
            lda   CMD_OUTFILE,x
            ora   CMD_OUTFILE+1,x
            bne   :redir
            lda   #<BGWARN_MSG
            ldx   #>BGWARN_MSG
            jsr   PR_ERRAX
:redir      lda   #FD_STDERR
            sta   JOB_FD
            ldx   JOB_FG
            dex
            jsr   PR_JOBBRK
            lda   #$A0
            jsr   JOB_PUTC
            ldx   JOB_X
            lda   JOB_TAIL,x
            jsr   PR_JOBDEC
            jsr   JOB_CR
:quiet      stz   LASTSTATUS
            stz   JOB_FG
            rts

*---------------------------------------------------------------
* JOB_DRAIN -- MAINLOOP calls this before every prompt (and
* every script line): reap whatever finished, WJ_NOHANG only --
* NEVER WJ_UNTRACED here, the named invariant (sc.proc.equ
* SYS_WAITJOB): a poll wants exits, not a re-sighting of every
* parked job. Then report `[n]  Done   cmd` / `Terminated` for
* each Done row on fd 2 -- V7's "reported at the next prompt",
* no async signal needed -- and free it. Interactive only for
* the printing; the reaping is what keeps a script's `&`
* children from lingering as zombies holding banks. JOB_QUIET
* is `wait`'s way of freeing silently. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
JOB_DRAIN   lda   #JS_RUN
            jsr   JOB_OTHER
            bcc   :report
:loop       lda   #WJ_NOHANG
            ldx   #<WJSTAT
            stx   PTR0
            ldx   #>WJSTAT
            stx   PTR0+1
            jsr   SC_WAITJOB
            bcs   :report
            tax
            beq   :report
            jsr   JOB_REAP
            bra   :loop
:report     ldx   #0
:row        lda   JOB_ST,x
            cmp   #JS_DONE
            bne   :next
            lda   SH_INTERACT
            beq   :free
            lda   JOB_QUIET
            bne   :free
            lda   #FD_STDERR
            sta   JOB_FD
            jsr   PR_JOBLINE
:free       jsr   JOB_FREE
:next       inx
            cpx   #BGMAX
            bne   :row
            rts
*---------------------------------------------------------------
* MOVED 2026-09-16 to src/bin/shsgjob.s -- the job-control
* builtins
* now lives in sh's SECOND CODE SEGMENT at $E000+ (docs/
* SH-SUBSET.md ruling 7.6). The strings stayed here: a segment
* address cannot be handed to a syscall (see the header of
* shsgjob.s).
*---------------------------------------------------------------


WAIT_STR    asc   "WAIT"
            dfb   0
WAITUSAGE   asc   "usage: wait [%job] -- no wait PID"
            dfb   $8D,0
KILL_STR    asc   "KILL"
            dfb   0
JOBS_STR    asc   "JOBS"
            dfb   0
FG_STR      asc   "FG"
            dfb   0
BG_STR      asc   "BG"
            dfb   0
RUN_STR     asc   "Running   "
            dfb   0
STOP_STR    asc   "Stopped   "
            dfb   0
JDONE_STR    asc   "Done   "
            dfb   0
AMP_STR     asc   " &"
            dfb   0
NOJOB_MSG   asc   "sh: no such job"
            dfb   $8D,0
NOJC_MSG    asc   "sh: no job control"
            dfb   $8D,0
JOBFULL_MSG asc   "sh: too many jobs"
            dfb   $8D,0
BGWARN_MSG  asc   "sh: background output not redirected"
            dfb   $8D,0
