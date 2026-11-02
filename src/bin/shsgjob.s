*---------------------------------------------------------------
* shsgjob.s -- the wait/kill/jobs/fg/bg builtins
* and the job-report printers, segment-resident.
* Moved out of shjob.s 2026-09-16 with NO source change: this
* file is `put` inside sh.s's `org PRC_LC_COMMON` block, so
* every label here resolves at $E000+ and the low image keeps
* only the `jsr`s into it. docs/SH-SUBSET.md ruling 7.6 has
* the mechanism (SEG_INIT, the low copy, the two tripwires).
*
* NOTHING HERE MAY BE REACHED BEFORE SEG_INIT RAN -- it is the
* first thing START (shlex.s) does.
*
* AND NOTHING HERE MAY BE HANDED TO A SYSCALL. The kernel's
* COPYIN_ENTRY/COPYOUT_ENTRY templates (src/kernel/entry2.s)
* REFUSE a process address >= $D000 outright ("LC path not
* wired yet", K_CPY_ERR=2), and BankCopy -- the path a tty or
* file write's BUFFER takes -- is built on them. So the
* strings, parmlists and buffers these routines hand to
* PUTS/PR_ERRAX/SC_* stayed behind in shjob.s; only CODE moved.
*---------------------------------------------------------------

*---------------------------------------------------------------
* CHCK_BLTN_WT -- the `wait` builtin, command-position only like
* every builtin. Bare `wait` reaps until no row is Running, then
* frees the Done rows silently and returns 0 (POSIX: operand-
* less `wait` is 0 whatever the children did -- a shell that
* collapsed several statuses into one would have to pick, and
* every pick is wrong). `wait %spec` (JOB_SPECP's specs: `%n`,
* `%+`/`%%`/`%`, `%-`) reaps until THAT row stops being Running,
* then `$?` = the row's status (the tail's exit code or
* $80|signo, what `fg` would have given) and the row is freed
* silently -- other jobs' Done notices wait for the prompt. A
* Stopped row returns at once, the row kept. The operand must
* start with `%`: `wait PID` stays REFUSED, never silently
* widened into "job PID" (JOB_SPECP alone would read a bare `n`
* as job n, the fg/bg convention: wrong for wait). With nothing
* Running it never reaches the kernel: a bare `wait` in a script
* with no `&` is a no-op in Bourne, and here it would be an
* ERR_CHILD. ERR_CHILD with rows still Running (a child reaped
* past this table) marks them Done rather than leave a row
* nothing will ever complete. The one known reaper past this
* table was SUB_WAITST's pid-less wait, and it is gone
* (2026-09-16, gated by check-shlang's SW row): the guard stays
* because the alternative to a wrong status here is a `wait`
* that never returns. OUT: carry set = handled.
* CLOBBERS: A, X, Y, PTR0, PTR1, WT_ROW.
*---------------------------------------------------------------
CHCK_BLTN_WT
            lda   NCMD
            cmp   #1
            bne   :no
            lda   #<WAIT_STR
            ldx   #>WAIT_STR
            jsr   JOB_CMPA0
            beq   :iswait
:no         clc
            rts
:iswait     stz   WT_ROW                 ;0 = every job
            lda   CMD_ARGC+0
            cmp   #1
            beq   :reap
            cmp   #2
            bne   :usage
            lda   CMD_ARGV+2
            ldx   CMD_ARGV+3
            sta   PTR0
            stx   PTR0+1
            ldy   #0
            lda   (PTR0),y
            cmp   #$A5                   ;'%': a job, not a pid
            bne   :usage
            lda   CMD_ARGV+2
            jsr   JOB_SPECP
            bcs   :handled
            inx
            stx   WT_ROW
            bra   :reap
:usage      lda   #<WAITUSAGE
            ldx   #>WAITUSAGE
            jmp   JOB_ERR
:reap       ldx   WT_ROW
            beq   :any
            dex
            lda   JOB_ST,x
            cmp   #JS_RUN
            bne   :onedone
            bra   :wait
:any        lda   #JS_RUN
            jsr   JOB_OTHER
            bcc   :alldone
:wait       lda   #0
            ldx   #<WJSTAT
            stx   PTR0
            ldx   #>WJSTAT
            stx   PTR0+1
            jsr   SC_WAITJOB
            bcs   :stale
            tax
            beq   :reap
            jsr   JOB_REAP
            bra   :reap
:stale      jsr   SIG_RETRY              ;untrapped (TERM):
            bcc   :reap                  ;not an interruption
            ldx   #0
:srow       lda   JOB_ST,x
            cmp   #JS_RUN
            bne   :snext
            lda   #JS_DONE
            sta   JOB_ST,x
:snext      inx
            cpx   #BGMAX
            bne   :srow
            bra   :reap                  ;now Done: both exits
:alldone    lda   #1
            sta   JOB_QUIET
            jsr   JOB_DRAIN
            stz   JOB_QUIET
            stz   LASTSTATUS
            sec
            rts
:onedone    lda   JOB_EXST,x
            sta   LASTSTATUS
            lda   JOB_ST,x
            cmp   #JS_DONE
            bne   :handled               ;Stopped: back at once
            jsr   JOB_FREE
:handled    sec
            rts

*---------------------------------------------------------------
* KILL_SPECS -- `kill [-signo] %spec ...` (docs/JOB-CONTROL.md
* Increment C, the kill/wait follow-up). In an interactive shell
* each `%` operand of a one-stage `kill` line is REPLACED in
* CMD_ARGV, before RUN_PIPELINE spawns /bin/kill, by the job's
* live member pids as decimal text -- one argv slot each, so a
* pipeline job is signalled whole (maux has no process groups).
* /bin/kill's own -signo/pid parsing and diagnostics stay the
* one truth, and this is a per-command rewrite, NOT a word
* expansion
* (the csh/bash shape): `echo %1` is literal, and `/bin/kill %1`
* by path or a script's `kill %1` reach kill as typed. Called
* from the builtin chain right before RUN_PIPELINE. OUT: carry
* clear = spawn as usual (argv possibly rewritten); carry set =
* handled without spawning: a spec naming no job with a live
* member (`sh: no such job`, `$?` = 1) or the pids outgrowing
* argv (`sh: too many arguments`). CLOBBERS: A, X, Y, PTR0,
* PTR1, JTMP, JTMP2, KS_*, U2DEC's cells.
*---------------------------------------------------------------
KILL_SPECS  lda   SH_INTERACT
            beq   :no
            lda   NCMD
            cmp   #1
            bne   :no
            lda   #<KILL_STR
            ldx   #>KILL_STR
            jsr   JOB_CMPA0
            bne   :no
            stz   KS_BUFN
            stz   KS_X                   ;argv[0]; stepped below
:arg        inc   KS_X
            inc   KS_X
            lda   CMD_ARGC+0
            asl   a
            cmp   KS_X
            bne   :scan
:no         clc                          ;past the last operand
            rts
:scan       ldx   KS_X
            lda   CMD_ARGV,x
            sta   PTR0
            lda   CMD_ARGV+1,x
            sta   PTR0+1
            ldy   #0
            lda   (PTR0),y
            cmp   #$A5                   ;'%'
            bne   :arg
            lda   PTR0
            ldx   PTR0+1
            jsr   JOB_SPECP
            bcc   :row
            rts                          ;diagnosed, `$?` = 1
:row        jsr   JOB_PIDIDX             ;Y = the row's 1st slot
            sty   KS_Y
            stz   KS_N                   ;members placed so far
            lda   #MAXCMD
            sta   KS_M                   ;slots left to look at
:member     ldy   KS_Y
            lda   JOB_PID,y
            beq   :mnext
            lda   KS_N
            beq   :place                 ;the first takes the
                                         ;spec's own slot
*-- Every later member needs a slot of its own: open one after
*-- KS_X by moving [KS_X+2 .. argc*2] (the 0 terminator with it)
*-- up one slot, top down. The slot past argc is 0 by ZR_CMD_
*-- TABLES's zeroing, and argc is capped at MAXARGV as APPEND_
*-- ARGV caps it, so the terminator always lands inside CMD_ARGV
*-- (at MAXARGV it is the next stage's argv[0] -- 0 at NCMD=1).
            lda   CMD_ARGC+0
            cmp   #MAXARGV
            bcs   :full
            inc   CMD_ARGC+0
            asl   a                      ;X = the OLD argc*2 --
            tax                          ;the terminator's slot
            inc   KS_X
            inc   KS_X
:shift      lda   CMD_ARGV-2,x
            sta   CMD_ARGV,x
            lda   CMD_ARGV-1,x
            sta   CMD_ARGV+1,x
            cpx   KS_X
            beq   :place
            dex
            dex
            bra   :shift
:place      lda   #<KS_BUF               ;PTR1 = KS_BUF+KS_BUFN
            clc
            adc   KS_BUFN
            sta   PTR1
            lda   #>KS_BUF
            adc   #0
            sta   PTR1+1
            ldx   KS_X
            lda   PTR1
            sta   CMD_ARGV,x
            lda   PTR1+1
            sta   CMD_ARGV+1,x
            ldy   KS_Y
            lda   JOB_PID,y
            sta   U2DEC_VAL
            stz   U2DEC_VAL+1
            jsr   U2DEC                  ;A = digits written
            sec                          ;+1 past the NUL
            adc   KS_BUFN
            sta   KS_BUFN
            inc   KS_N
:mnext      inc   KS_Y
            dec   KS_M
            bne   :member
            lda   KS_N
            bne   :again
            lda   #<NOJOB_MSG            ;a row with no live
            ldx   #>NOJOB_MSG            ;member: all reaped
            bra   :err
:full       lda   #<TOOMANY_MSG
            ldx   #>TOOMANY_MSG
:err        jmp   JOB_ERR
:again      jmp   :arg

*---------------------------------------------------------------
* CHCK_BLTN_JOB -- `jobs`, `fg [%n]`, `bg [%n]`. Command-
* position only; case-insensitive like the rest of the chain.
* `fg`/`bg` are refused in a non-interactive shell: a script is
* inside its parent's job and has no console to take.
*   jobs   `[n]<+|-| > <state>   <cmd>` per live row, on fd 1.
*   fg     declare the row's live members the console's
*          foreground job (SYS_TCSETFG, so ^C/^Z aim at it),
*          continue them, print the command, then FG_WAIT.
*   bg     continue the members, mark Running, `[n]+ cmd &`,
*          back to the prompt at once -- the fg set untouched.
*   %spec  the POSIX/csh shorthand: a one-stage line whose
*          argv[0] begins with `%` IS `fg %spec` -- `bg %spec`
*          when the line ended in `&`. Interactive only: a
*          script has no job control, so its `%1` stays the
*          command-not-found it always was. Tested LAST, after
*          the names, and only at NCMD=1: `%1 | foo` is not a
*          job spec and keeps today's behaviour too.
* OUT: carry set = handled. CLOBBERS: A, X, Y, PTR0-2.
*---------------------------------------------------------------
CHCK_BLTN_JOB
            lda   NCMD
            cmp   #1
            bne   :no
            lda   #<JOBS_STR
            ldx   #>JOBS_STR
            jsr   JOB_CMPA0
            beq   :jobs
            lda   #<FG_STR
            ldx   #>FG_STR
            jsr   JOB_CMPA0
            beq   :fg
            lda   #<BG_STR
            ldx   #>BG_STR
            jsr   JOB_CMPA0
            beq   :bg
            jmp   :pct                   ;past bra's reach
:no         clc
            rts
:jobs       lda   #FD_STDOUT
            sta   JOB_FD
            ldx   #0
:row        lda   JOB_ST,x
            beq   :next
            jsr   PR_JOBLINE
:next       inx
            cpx   #BGMAX
            bne   :row
            stz   LASTSTATUS
            sec
            rts
:fg         lda   SH_INTERACT
            beq   :nojc
            jsr   JOB_SPEC
            bcs   :handled
:fgx        jsr   JOB_MKCUR              ;X = row (:pct joins)
            inx
            stx   JOB_FG
            dex
            lda   #JS_RUN
            sta   JOB_ST,x
*-- Declare through FG_DECLARE's own CMD_PID walk: the row's
*-- members stand in for the stages. NCMD is dead until the next
*-- segment's ZR_CMD_TABLES, and nothing after a builtin's
*-- carry-set return reads it.
            jsr   JOB_PIDIDX
            ldx   #0
:cp         lda   JOB_PID,y
            sta   CMD_PID,x
            iny
            inx
            cpx   #MAXCMD
            bne   :cp
            stx   NCMD
            jsr   FG_DECLARE
            ldx   JOB_FG
            dex
            jsr   JOB_CONTJ
            lda   #FD_STDERR
            sta   JOB_FD
            jsr   PR_JOBTXT
            jsr   JOB_CR
            jsr   FG_WAIT
:handled    sec
            rts
:bg         lda   SH_INTERACT
            beq   :nojc
            jsr   JOB_SPEC
            bcs   :handled
:bgx        jsr   JOB_CONTJ              ;X = row (:pct joins)
            lda   #JS_RUN
            sta   JOB_ST,x
            lda   #FD_STDERR
            sta   JOB_FD
            jsr   PR_JOBNUM
            jsr   PR_JOBTXT
            lda   #<AMP_STR
            ldx   #>AMP_STR
            jsr   JOB_PUTS
            jsr   JOB_CR
            stz   LASTSTATUS
            sec
            rts
:nojc       lda   #<NOJC_MSG
            ldx   #>NOJC_MSG
            jmp   JOB_ERR
*-- `%spec` [&] -- argv[0] itself is the operand, so it goes to
*-- JOB_SPECP (the parser under JOB_SPEC, pointer in A/X) and
*-- the row joins the fg or bg path above; `$?`, `%+`/`%-` and
*-- the diagnostics are theirs. Not interactive, or no leading
*-- `%`: not ours -- carry clear, RUN_PIPELINE says "not found".
:pct        lda   SH_INTERACT
            beq   :nope
            lda   CMD_ARGV+0
            ldx   CMD_ARGV+1
            sta   PTR0
            stx   PTR0+1
            ldy   #0
            lda   (PTR0),y
            cmp   #$A5                   ;'%'
            bne   :nope
            lda   CMD_ARGV+0
            jsr   JOB_SPECP
            bcs   :handled
            lda   PARSE_SEPOP
            cmp   #SEP_BG                ;`%n &` = bg %n
            beq   :bgx
            jmp   :fgx                   ;past bra's reach
:nope       clc
            rts

*-- JOB_ERR -- diagnostic at A/X, `$?` = 1, carry set.
JOB_ERR     jsr   PR_ERRAX
            lda   #1
            sta   LASTSTATUS
            sec
            rts

*-- JOB_CMPA0 -- compare argv[0] with the string at A/X.
*-- OUT: Z set on a match (STRCMPI's own).
JOB_CMPA0   sta   PTR1
            stx   PTR1+1
            lda   CMD_ARGV+0
            sta   PTR0
            lda   CMD_ARGV+1
            sta   PTR0+1
            jmp   STRCMPI

*---------------------------------------------------------------
* JOB_SPEC -- the job operand of `fg`/`bg`: none or `%+`/`%%`
* (or a bare `%`) = the current job, `%-` = the previous, `%n`
* (or bare `n`) = job n. `%string` is not implemented (v1). OUT:
* carry clear, X = row; carry set = no such job (diagnosed,
* `$?` = 1). CLOBBERS: A, X, Y, PTR0.
* JOB_SPECP is the parser under it: A/X = the operand string
* (X = 0, no operand: the current job). CHCK_BLTN_JOB's `%spec`
* shorthand enters here with argv[0] -- one parser, two callers.
*---------------------------------------------------------------
JOB_SPEC    lda   CMD_ARGV+2
            ldx   CMD_ARGV+3
            ldy   CMD_ARGC+0
            cpy   #2
            bcs   JOB_SPECP
            ldx   #0                     ;no operand
JOB_SPECP   sta   PTR0
            stx   PTR0+1
            cpx   #0
            beq   :cur
            ldy   #0
            lda   (PTR0),y
            cmp   #$A5                   ;'%'
            bne   :kind
            iny
            lda   (PTR0),y
            beq   :cur                   ;bare `%`
:kind       cmp   #$AB                   ;'+'
            beq   :cur
            cmp   #$A5                   ;'%%'
            beq   :cur
            cmp   #$AD                   ;'-'
            beq   :prev
            jsr   JOB_DIGIT
            bcs   :bad
            sta   JTMP
            iny
            lda   (PTR0),y
            beq   :one
            jsr   JOB_DIGIT
            bcs   :bad
            sta   JTMP2
            lda   JTMP
            asl   a
            asl   a
            adc   JTMP
            asl   a
            adc   JTMP2                  ;10*d1 + d2
            sta   JTMP
            iny
            lda   (PTR0),y
            bne   :bad
:one        ldx   JTMP
:chk        beq   :bad
            cpx   #BGMAX+1
            bcs   :bad
            dex
            lda   JOB_ST,x
            beq   :bad
            clc
            rts
:cur        ldx   JOB_CUR
            bra   :chk
:prev       ldx   JOB_PREV
            bra   :chk
:bad        lda   #<NOJOB_MSG
            ldx   #>NOJOB_MSG
            jmp   JOB_ERR

*-- JOB_DIGIT -- A = '0'..'9' (high bit set) -> its value,
*-- carry clear; anything else carry set.
JOB_DIGIT   cmp   #$B0
            bcc   :no
            cmp   #$BA
            bcs   :no
            and   #$0F
            clc
            rts
:no         sec
            rts

*---------------------------------------------------------------
* The printers. All take X = row, preserve it (JOB_X), and write
* to JOB_FD. PUTS is unbuffered and flushes first, PUTC buffers,
* so the mix stays in order and JOB_CR's flush ends the line --
* CHCK_BLTN_ECH's own reasoning.
*   PR_JOBLINE  `[n]<flag> <state>   <cmd>` CR
*   PR_JOBNUM   `[n]<flag> `   (flag: + current, - previous)
*   PR_JOBBRK   `[n]` alone -- the `&` line has no flag
*   PR_JOBTXT   the command text
*   PR_JOBDEC   A as decimal (a pid)
*---------------------------------------------------------------
PR_JOBLINE  jsr   PR_JOBNUM
            lda   JOB_ST,x
            cmp   #JS_RUN
            bne   :notrun
            lda   #<RUN_STR
            ldx   #>RUN_STR
            bra   :state
:notrun     cmp   #JS_STOP
            bne   :done
            lda   #<STOP_STR
            ldx   #>STOP_STR
            bra   :state
:done       lda   JOB_EXST,x
            bmi   :term
            lda   #<JDONE_STR
            ldx   #>JDONE_STR
            bra   :state
:term       jsr   SIG_JOBSTATE           ;the signal's V7 name
            bra   :text
:state      jsr   JOB_PUTS
:text       ldx   JOB_X
            jsr   PR_JOBTXT
            bra   JOB_CR

PR_JOBNUM   jsr   PR_JOBBRK
            inx
            lda   #$AB                   ;'+'
            cpx   JOB_CUR
            beq   :flag
            lda   #$AD                   ;'-'
            cpx   JOB_PREV
            beq   :flag
            lda   #$A0
:flag       jsr   JOB_PUTC
            lda   #$A0
            jsr   JOB_PUTC
            ldx   JOB_X
            rts

PR_JOBBRK   stx   JOB_X
            lda   #$DB                   ;'['
            jsr   JOB_PUTC
            lda   JOB_X
            inc   a
            jsr   PR_JOBDEC
            lda   #$DD                   ;']'
            jsr   JOB_PUTC
            ldx   JOB_X
            rts

PR_JOBTXT   stx   JOB_X
            jsr   JOB_TXTPTR
            lda   PTR2
            sta   PTR0
            lda   PTR2+1
            sta   PTR0+1
            ldx   JOB_FD
            jsr   PUTS
            ldx   JOB_X
            rts

PR_JOBDEC   sta   U2DEC_VAL
            stz   U2DEC_VAL+1
            ldx   JOB_FD
            jsr   PRNUM
            ldx   JOB_X
            rts

JOB_PUTS    sta   PTR0
            stx   PTR0+1
            ldx   JOB_FD
            jmp   PUTS

JOB_PUTC    ldx   JOB_FD
            jmp   PUTC

JOB_CR      lda   #$8D
            jsr   JOB_PUTC
            ldx   JOB_FD
            jsr   SIO_FLUSH
            ldx   JOB_X
            rts
