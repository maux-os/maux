*---------------------------------------------------------------
* timeout.s -- run a utility, kill it if it outruns a deadline.
*
* Usage: timeout [-f] [-p] [-k time] [-s signal] duration
*        utility [argument...]
*
* POSIX.1-2024: spawn utility, poll for it to exit, and if
* `duration` seconds pass first, signal it (-s, default TERM)
* and exit 124. -p exits with the CHILD's own status even after
* a timeout (POSIX "preserve status"). -k time: if the signal
* alone did not reap it within `time` more seconds, follow up
* with KILL. -f (foreground): there is no process-group
* concept here to skip, so it is accepted and does nothing --
* documented, not silently swallowed.
*
* MECHANISM is sleep.s's own SAMPLE/target-tick shape, not a
* real interval timer (maux has none): SC_TICK is sampled, a
* target tick count is computed once, and SC_WAITJOB(WJ_NOHANG)
* is polled against it (sh.s's own FG_WAIT -- shjob.s -- is the
* three-mode version of this same poll-and-decode idea; timeout
* has exactly one child, so it needs none of FG_WAIT's job-table
* machinery, just its {kind,code} decode: WJ_SIGNALED ORs $80
* into the code, otherwise the code is the exit status itself --
* JOB_REAP's own line for line). SYS_TICK mode 0 (no tick
* source) is sleep.s's own refusal, exit 125 here too.
*
* NO HOST ORACLE (this Mac has no `timeout`): every
* check-posixutil row is hand-authored from the XCU text.
*
* DURATION AND -k TIME accept a decimal integer with an optional
* trailing s/m/h suffix (POSIX; default unit seconds), and
* (SHIPPED 2026-09-17) ONE fractional digit -- "1.5" is 90
* ticks -- but ONLY when the unit resolves to seconds; "1.5m"/
* "1.5h" and a second fractional digit ("1.55") are still
* refused, exit 125, loud rather than rounded away (see
* timeoutparse.s's own TO_PARSEDUR header for why). The
* multiply-by-repeated-add
* pattern is sleep.s's MKTARGET shape, done ONCE per parsed
* value: loop the DECIMAL VALUE (capped at TO_MAXVAL, matching
* sleep.s's own MAXSECS) times, adding a 32-bit per-unit tick
* constant (60/3600/216000) each time -- at most TO_MAXVAL
* iterations of a 32-bit add, not a multiply nobody wrote.
*
* SIGNAL: -s accepts a NUMBER (kill.s's own overflow-safe
* digit-to-byte parser, 0-255) or one of the names shtrap.s's
* own trap table already recognises (TERM/KILL/HUP/INT/QUIT) --
* kill.s itself parses numbers only, so this is shtrap.s's
* mechanism, not kill.s's, despite the family resemblance; see
* the report for this discrepancy from the task brief.
*
* REAPING. If the poll catches the child before the deadline,
* its status is used as-is (SC_WAITJOB's own decode) and -p is
* irrelevant -- there was no timeout. If the deadline fires,
* SC_KILL(signal) is sent; the poll continues (now against
* KTARGET if -k was given, else it simply blocks) and a SECOND
* SC_KILL(9) follows if -k's own grace period also expires. The
* child is ALWAYS fully reaped before this program exits -- one
* more wait after every kill, never a zombie left behind (proved
* live in check-play with `PS`).
*
* Uses ONLY liba -- no direct syscalls, no raw gate address.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            put   ../../inc/errno.spawn.equ
            org   LOAD_BASE
            dsk   ../../build/timeout.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

TICKS_HZ    equ   60
TO_MAXVAL   equ   9999       ;raw decimal value cap (sleep.s's
                             ;own MAXSECS)
TO_ARGVMAX  equ   32         ;child argv cap, env.s's own
TO_ENVCAP   equ   48         ;env entries, env.s's own cap

START       lda   #<OPTLIST
            ldx   #>OPTLIST
            jsr   OPTINIT
            stz   TO_PFLAG
            stz   TO_KFLAG
            lda   #15                ;default signal: TERM
            sta   TO_SIGNO
:optlp      jsr   GETOPT
            bcs   :optdone
            cmp   #"f"
            beq   :optlp             ;-f: accept, no-op (header)
            cmp   #"p"
            beq   :optp
            cmp   #"k"
            beq   :optk
            cmp   #"s"
            beq   :opts
            jmp   :usage125          ;'?' or anything else
:optp       lda   #1
            sta   TO_PFLAG
            bra   :optlp
:optk       lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   TO_PARSEDUR
            bcc   :koptok
            jmp   :usage125
:koptok     ldx   #0
:kcplp      lda   TO_PRESULT,x
            sta   TO_KTICKS,x
            inx
            cpx   #4
            bne   :kcplp
            lda   #1
            sta   TO_KFLAG
            bra   :optlp
:opts       lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jsr   TO_PARSESIG
            bcc   :optlp
            jmp   :usage125
:optdone

*-- need at least DURATION and UTILITY past the options.
            lda   ARGC
            sec
            sbc   OPTIND
            cmp   #2
            bcs   :haveops
            jmp   :usage125
:haveops    lda   OPTIND
            jsr   GETARG              ;PTR0 = the duration word
            jsr   TO_PARSEDUR
            bcc   :durok
            jmp   :usage125
:durok      ldx   #0
:dcplp      lda   TO_PRESULT,x
            sta   TO_DURTIX,x
            inx
            cpx   #4
            bne   :dcplp

*-- THE MODE CHECK COMES BEFORE THE SPAWN (sleep.s's own rule:
*-- "the mode check comes before any arithmetic"), and here it
*-- is load-bearing for a second reason too: a mode-0 refusal
*-- AFTER spawning would exit 125 with the child already alive
*-- and NEVER REAPED -- a zombie, left behind for whatever the
*-- shell tries to do next. Checked once here, before this
*-- process commits to being responsible for a child at all.
            jsr   SAMPLE
            lda   TICKBUF                ;mode
            cmp   #1
            beq   :haveclk
            cmp   #2
            beq   :haveclk
            jmp   :notick
:haveclk
            lda   OPTIND
            clc
            adc   #1
            sta   TO_UIDX             ;argv index of the utility

*-- build the child's environment reference: NONE -- timeout
*-- does not touch it, and a NULL SPWN_ENVP is "no environment"
*-- (syscallp.s header), which would DROP it -- so pass this
*-- process's own by pointing straight at ARGV's envp/envc, the
*-- same block ENVNTH walks, is wrong (count-prefixed, not
*-- NUL-terminated -- see nohup.s's own ENVNTH copy for why);
*-- reuse that exact copy loop here too.
            stz   TO_EI
            stz   TO_ECNT
:ecplp      lda   TO_EI
            jsr   ENVNTH
            bcs   :ecdone
            lda   TO_ECNT
            cmp   #TO_ENVCAP
            bcc   :ecroom
            jmp   :envfull
:ecroom     asl   a
            tax
            lda   PTR1
            sta   TO_ENVLST,x
            lda   PTR1+1
            sta   TO_ENVLST+1,x
            inc   TO_ECNT
            inc   TO_EI
            bra   :ecplp
:ecdone     lda   TO_ECNT
            asl   a
            tax
            stz   TO_ENVLST,x
            stz   TO_ENVLST+1,x

            lda   TO_UIDX
            jsr   GETARG              ;PTR0 = argv[uidx], as
                                       ;typed
            lda   PTR0
            sta   TO_ORGW
            lda   PTR0+1
            sta   TO_ORGW+1
            jsr   PATHRSLV
            bcc   :found
            jmp   :notfound
:found      lda   PTR0
            sta   TO_PATH
            lda   PTR0+1
            sta   TO_PATH+1

            lda   TO_ORGW
            sta   ARGVLIST
            lda   TO_ORGW+1
            sta   ARGVLIST+1
            lda   TO_UIDX
            clc
            adc   #1
            sta   TO_AI2
            lda   #1
            sta   TO_NI
:cvlp       lda   TO_AI2
            cmp   ARGC
            bcs   :cvdone
            lda   TO_NI
            cmp   #TO_ARGVMAX
            bcc   :cvok
            jmp   :toomany
:cvok       lda   TO_AI2
            jsr   GETARG
            lda   TO_NI
            asl   a
            tax
            lda   PTR0
            sta   ARGVLIST,x
            lda   PTR0+1
            sta   ARGVLIST+1,x
            inc   TO_NI
            inc   TO_AI2
            bra   :cvlp
:cvdone     lda   TO_NI
            asl   a
            tax
            stz   ARGVLIST,x
            stz   ARGVLIST+1,x

            lda   TO_PATH
            sta   PTR0
            lda   TO_PATH+1
            sta   PTR0+1
            lda   #<ARGVLIST
            sta   PTR1
            lda   #>ARGVLIST
            sta   PTR1+1
            stz   PTR2
            stz   PTR2+1              ;NULL fdactions -- inherit
                                       ;fd 0/1/2, same as env.s
            lda   #<TO_ENVLST
            sta   SPWN_ENVP
            lda   #>TO_ENVLST
            sta   SPWN_ENVP+1
            jsr   SC_SPAWN
            bcc   :spawnok
            jmp   :spawnerr
:spawnok    sta   TO_PID

*-- the deadline: TARGET = now + TO_DURTIX (sleep.s's own
*-- MKTARGET/SAMPLE shape, folded in below since the addend is
*-- already in TICKS, not seconds -- no *60 step here). The
*-- mode was already checked before the spawn above; resample
*-- now for an accurate start point, mode cannot have changed.
            jsr   SAMPLE
            ldx   #0
:mtlp       lda   TICKBUF+1,x
            sta   TARGET,x
            inx
            cpx   #4
            bne   :mtlp
            clc
            lda   TARGET
            adc   TO_DURTIX
            sta   TARGET
            lda   TARGET+1
            adc   TO_DURTIX+1
            sta   TARGET+1
            lda   TARGET+2
            adc   TO_DURTIX+2
            sta   TARGET+2
            lda   TARGET+3
            adc   TO_DURTIX+3
            sta   TARGET+3

            stz   TO_TIMDOUT
:poll       lda   #WJ_NOHANG
            ldx   #<WJSTAT
            stx   PTR0
            ldx   #>WJSTAT
            stx   PTR0+1
            jsr   SC_WAITJOB
            bcc   :pollok
            jmp   :waiterr
:pollok     cmp   #0
            beq   :nothing
            jsr   TO_DECODE
            jmp   :done
:nothing    jsr   SAMPLE
            jsr   TO_REACHD
            bcc   :poll
*-- deadline reached: signal, then the -k grace path.
            lda   TO_PID
            ldx   TO_SIGNO
            jsr   SC_KILL
            lda   #1
            sta   TO_TIMDOUT
            lda   TO_KFLAG
            bne   :kgrace
            jmp   :finalwt

:kgrace     jsr   SAMPLE
            ldx   #0
:kmtlp      lda   TICKBUF+1,x
            sta   KTARGET,x
            inx
            cpx   #4
            bne   :kmtlp
            clc
            lda   KTARGET
            adc   TO_KTICKS
            sta   KTARGET
            lda   KTARGET+1
            adc   TO_KTICKS+1
            sta   KTARGET+1
            lda   KTARGET+2
            adc   TO_KTICKS+2
            sta   KTARGET+2
            lda   KTARGET+3
            adc   TO_KTICKS+3
            sta   KTARGET+3
:kpoll      lda   #WJ_NOHANG
            ldx   #<WJSTAT
            stx   PTR0
            ldx   #>WJSTAT
            stx   PTR0+1
            jsr   SC_WAITJOB
            bcc   :kpollok
            jmp   :waiterr
:kpollok    cmp   #0
            beq   :knothin
            jsr   TO_DECODE
            jmp   :done
:knothin    jsr   SAMPLE
            jsr   TO_REACHK
            bcc   :kpoll
            lda   TO_PID
            ldx   #9                  ;KILL -- force
            jsr   SC_KILL
:finalwt    lda   #<WSTATUS
            sta   PTR0
            lda   #>WSTATUS
            sta   PTR0+1
            jsr   SC_WAIT
            lda   WSTATUS
            sta   TO_RSTAT

:done       lda   TO_TIMDOUT
            beq   :notimo
            lda   TO_PFLAG
            bne   :dopreserve
            lda   #124
            jsr   EXIT
:dopreserve lda   TO_RSTAT
            jsr   EXIT
:notimo     lda   TO_RSTAT
            jsr   EXIT

            put   timeoutaux.s
            put   timeoutparse.s
            put   timeoutsig.s


            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/spawnwhy.s
            put   ../liba/pathtab.s
            put   ../liba/pathres.s
            put   ../liba/env.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* timeout's own bss -- `dum`/`dend` off LIBA_BSSEND, no zero
* fills needed (docs/STICKY.md sec 21); every cell is written
* before its own first read on the path that reads it.
* TO_TENTH/TO_HAVEFRAC/TO_FTMP: TO_PARSEDUR's own fractional-
* duration scratch (timeoutparse.s) -- TO_HAVEFRAC is `stz`'d
* at TO_PARSEDUR's own entry, before its own later read/write.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
TO_PFLAG    ds    1
TO_KFLAG    ds    1
TO_SIGNO    ds    1
TO_UIDX     ds    1
TO_EI       ds    1
TO_ECNT     ds    1
TO_ORGW     ds    2
TO_PATH     ds    2
TO_AI2      ds    1
TO_NI       ds    1
TO_PID      ds    1
TO_TIMDOUT  ds    1
TO_RSTAT    ds    1
TO_DVAL     ds    2
TO_NDIG     ds    1
TO_UNITIX   ds    1
TO_MTMP     ds    2
TO_PERIT    ds    4
TO_DCNT     ds    2
TO_PRESULT  ds    4
TO_DURTIX   ds    4
TO_KTICKS   ds    4
TO_NMTMP    ds    1
TO_TENTH    ds    1              ;fractional-seconds digit, 0-9
TO_HAVEFRAC ds    1              ;a '.' was parsed
TO_FTMP     ds    1              ;(free since 2026-09-21)
TO_FUNIT    ds    1              ;fractional suffix s/m/h
TO_FT4      ds    4              ;this unit's tenth, 32-bit
TO_FCNT     ds    1              ;tenths left to add
TICKBUF     ds    5
TARGET      ds    4
KTARGET     ds    4
WJSTAT      ds    2
WSTATUS     ds    1
TO_ENVLST   ds    TO_ENVCAP*2+2
ARGVLIST    ds    TO_ARGVMAX*2+2
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 is the top of the process window.
            err   */$BF00
            dend
