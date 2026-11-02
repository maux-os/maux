*---------------------------------------------------------------
* time.s -- `TIME CMD [args...]`: run CMD and report how long it
* took (docs/SHELL-GAPS.md sec 5). V6 had it; maux could not
* until SYS_TICK, and specifically until SYS_TICK's counter was
* 32 bits: at 60 Hz a 16-bit tick count wraps every ~18.2
* MINUTES, which is fine for `sleep` and useless for this.
*
* ONE NUMBER, NOT THREE. V7's `time` prints real/user/sys. maux
* has no per-process CPU accounting -- nothing anywhere charges
* time to a process -- so `user` and `sys` would be fabricated,
* and this prints only `real`. Inventing two zeroes to look
* period-correct is exactly the plausible wrong answer this tree
* refuses; a missing line is honest and a zero is not.
*
* IT REPORTS ON fd 2, like V7, and that is not cosmetic: the
* whole point of `time CMD > FILE` is that FILE gets CMD's
* output and not the timing. Writing the report to stdout would
* corrupt every redirected use.
*
* IT EXITS WITH THE CHILD'S STATUS, also like V7, so `time CMD`
* is transparent in a `&&` chain.
*
* IT REFUSES WHEN THERE IS NO TICK SOURCE, the same way and for
* the same reason src/bin/sleep.s does: TIMER_MD_COOP arms no
* hardware, so the counter is not slow, it is FROZEN, and a
* measurement of a frozen counter is a confident zero. See
* src/kernel/procfile3.s's PRC_TICK header. Mode 0 -- no timer
* driver linked at all -- refuses on the same branch.
*
* CMD IS PATH-RESOLVED (src/liba/pathres.s), so `time echo hi`
* works the way `find -exec echo` does. An absolute CMD comes
* back untouched.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/time.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

TICKS_HZ    equ   60
TM_ARGVMAX  equ   16          ;child argv slots, +1 for the NULL

START       lda   ARGC
            cmp   #2
            bcs   :haveargs
            jmp   USAGE
:haveargs
*-- MODE FIRST, before anything is spawned. A machine that
*-- cannot measure should say so rather than run the command and
*-- then report a fabricated duration.
            jsr   SAMPLE
            lda   TICKBUF
            cmp   #1
            beq   :haveclk
            cmp   #2
            beq   :haveclk
            jmp   NOTICK
:haveclk
*-- Resolve BEFORE the argv array is built: PATHRSLV clobbers
*-- PTR1 and PTR2, and PTR1 is SC_SPAWN's argv pointer.
            lda   #1
            jsr   GETARG                 ;PTR0 = argv[1]
            bcc   :havecmd
            jmp   USAGE
:havecmd    jsr   PATHRSLV
            bcs   :nocmd
            lda   PTR0
            sta   TM_PATH
            lda   PTR0+1
            sta   TM_PATH+1
            jsr   BUILDARGV
            bcs   :toomany
            jsr   ENVPASS
            bcs   :envfail
            jsr   SAMPLE                 ;t0
            ldx   #0
:cpt0       lda   TICKBUF+1,x
            sta   TM_T0,x
            inx
            cpx   #4
            bne   :cpt0

            lda   TM_PATH
            sta   PTR0
            lda   TM_PATH+1
            sta   PTR0+1
            lda   #<TM_ARGV
            sta   PTR1
            lda   #>TM_ARGV
            sta   PTR1+1
            stz   PTR2                   ;NULL fdactions -- the
            stz   PTR2+1                 ;child inherits 0/1/2
            jsr   SC_SPAWN
            bcs   :spawnerr
            lda   #<TM_WSTAT
            sta   PTR0
            lda   #>TM_WSTAT
            sta   PTR0+1
            jsr   SC_WAIT
            jsr   SAMPLE                 ;t1
            jsr   REPORT
            lda   TM_WSTAT               ;transparent in a chain
            jsr   SC_EXIT

:nocmd      jmp   NOCMD
:toomany    jmp   TOOMANY
:envfail    jmp   ENVFAIL
:spawnerr   jmp   SPAWNERR

*---------------------------------------------------------------
* BUILDARGV -- the child's argv: pointers to THIS process's
* argv[1..argc-1], NULL-terminated. OUT: carry SET if the list
* does not fit.
*
* argv[0] IS THE COMMAND AS TYPED, not the resolved path --
* execvp's rule. A program that prints its own name should say
* what the user wrote.
*---------------------------------------------------------------
BUILDARGV   stz   TM_N
            lda   #1
            sta   TM_I
:loop       lda   TM_I
            cmp   ARGC
            bcs   :done
            lda   TM_N
            cmp   #TM_ARGVMAX
            bcs   :full
            lda   TM_I
            jsr   GETARG                 ;PTR0 = argv[TM_I]
            bcs   :done
            lda   TM_N
            asl   a
            tax
            lda   PTR0
            sta   TM_ARGV,x
            lda   PTR0+1
            sta   TM_ARGV+1,x
            inc   TM_N
            inc   TM_I
            bra   :loop
:done       lda   TM_N
            asl   a
            tax
            lda   #0
            sta   TM_ARGV,x
            sta   TM_ARGV+1,x
            clc
            rts
:full       sec
            rts

*---------------------------------------------------------------
* SAMPLE -- one SYS_TICK into TICKBUF, carry checked. PRC_TICK
* returns WITHOUT writing the buffer when its copy-in or its
* BankCopy fails, and TICKBUF is `dum` -- bank garbage, not
* zeros. src/bin/date.s's header records this trap; sleep.s
* walked into it first.
*---------------------------------------------------------------
SAMPLE      lda   #<TICKBUF
            sta   PTR0
            lda   #>TICKBUF
            sta   PTR0+1
            jsr   SC_TICK
            bcs   :failed
            rts
:failed     jmp   TICKFAIL

*---------------------------------------------------------------
* REPORT -- TICKBUF holds t1; TM_T0 holds t0. Prints
* "real S.T" to fd 2.
*
* THE ELAPSED COUNT CANNOT WRAP in any run this machine will
* see: 32 bits at 60 Hz is about 2.3 years. It is still computed
* as a full 32-bit subtract rather than assuming the high words
* match.
*---------------------------------------------------------------
*-- UNROLLED, and it has to be: a loop needs a `cpx`/`cpy` to
*-- end, and BOTH CLOBBER THE CARRY -- which is the borrow this
*-- chain is carrying between bytes. Written as a loop first and
*-- it reported "ran too long" for `time sleep 0`, because the
*-- broken borrow made a two-tick interval look like millions.
*-- The same hazard as RSLV_PTH_STG's indeterminate carry in
*-- src/bin/sh.s, from the other direction.
REPORT      sec
            lda   TICKBUF+1
            sbc   TM_T0
            sta   TM_EL
            lda   TICKBUF+2
            sbc   TM_T0+1
            sta   TM_EL+1
            lda   TICKBUF+3
            sbc   TM_T0+2
            sta   TM_EL+2
            lda   TICKBUF+4
            sbc   TM_T0+3
            sta   TM_EL+3

*-- Seconds by repeated subtraction of 60 -- no divide on this
*-- machine. The quotient is 16-bit because U2DEC is; a run past
*-- 65535 seconds (18 hours) is REFUSED rather than reported
*-- modulo 65536, which would print a small confident number for
*-- a very long run.
            stz   TM_SEC
            stz   TM_SEC+1
:divloop    lda   TM_EL+1
            ora   TM_EL+2
            ora   TM_EL+3
            bne   :cansub
            lda   TM_EL
            cmp   #TICKS_HZ
            bcc   :divdone
:cansub     sec
            lda   TM_EL
            sbc   #TICKS_HZ
            sta   TM_EL
            lda   TM_EL+1
            sbc   #0
            sta   TM_EL+1
            lda   TM_EL+2
            sbc   #0
            sta   TM_EL+2
            lda   TM_EL+3
            sbc   #0
            sta   TM_EL+3
            inc   TM_SEC
            bne   :divloop
            inc   TM_SEC+1
            beq   :toolong               ;wrapped 16 bits
            bra   :divloop
:toolong    jmp   TOOLONG

*-- Tenths, not hundredths: the clock ticks every 1/60 s, so a
*-- second decimal place would be finer than the instrument.
*-- V7 printed tenths too. rem is 0..59, so rem/6 is 0..9.
:divdone    stz   TM_TEN
:tenloop    lda   TM_EL
            cmp   #6
            bcc   :tendone
            sec
            sbc   #6
            sta   TM_EL
            inc   TM_TEN
            bra   :tenloop

:tendone    lda   #<REAL_MSG
            sta   PTR0
            lda   #>REAL_MSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   TM_SEC
            sta   U2DEC_VAL
            lda   TM_SEC+1
            sta   U2DEC_VAL+1
            ldx   #FD_STDERR
            jsr   PRNUM
            lda   #$AE                   ;'.' high-bit
            ldx   #FD_STDERR
            jsr   PUTC
            lda   TM_TEN
            clc
            adc   #$B0                   ;'0' high-bit
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            rts

ERROUT      sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   SC_EXIT

USAGE       lda   #<USAGE_MSG
            ldx   #>USAGE_MSG
            jmp   ERROUT
NOTICK      lda   #<NOTICK_MSG
            ldx   #>NOTICK_MSG
            jmp   ERROUT
NOCMD       lda   #<NOCMD_MSG
            ldx   #>NOCMD_MSG
            jmp   ERROUT
TOOMANY     lda   #<TOOMANY_MSG
            ldx   #>TOOMANY_MSG
            jmp   ERROUT
ENVFAIL     lda   #<ENVFAIL_MSG
            ldx   #>ENVFAIL_MSG
            jmp   ERROUT
SPAWNERR    ldx   #<TIME_PFX             ;A = the errno still
            ldy   #>TIME_PFX
            jsr   SPAWNWHY               ;no bank/file slot: say
            bcc   :generic
            lda   #1
            jsr   SC_EXIT
:generic    lda   #<SPAWN_MSG
            ldx   #>SPAWN_MSG
            jmp   ERROUT
TICKFAIL    lda   #<TICKFAIL_MSG
            ldx   #>TICKFAIL_MSG
            jmp   ERROUT
TOOLONG     lda   #<TOOLONG_MSG
            ldx   #>TOOLONG_MSG
            jmp   ERROUT

REAL_MSG    asc   "real "
            dfb   0
USAGE_MSG   asc   "usage: time CMD [args...]"
            dfb   $8D,0
NOTICK_MSG  asc   "time: no timer (needs a mouse card"
            asc   " or Mockingboard)"
            dfb   $8D,0
NOCMD_MSG   asc   "time: command not found"
            dfb   $8D,0
TOOMANY_MSG asc   "time: too many arguments"
            dfb   $8D,0
ENVFAIL_MSG asc   "time: environment too large"
            dfb   $8D,0
TIME_PFX    asc   'time: '
            dfb   0
SPAWN_MSG   asc   "time: cannot run command"
            dfb   $8D,0
TICKFAIL_MSG
            asc   "time: tick syscall failed"
            dfb   $8D,0
TOOLONG_MSG asc   "time: ran too long to report"
            dfb   $8D,0

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s
            put   ../liba/mli.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/spawnwhy.s
            put   ../liba/argv.s
            put   ../liba/pathtab.s
            put   ../liba/pathres.s
            put   ../liba/env.s
            put   ../liba/libabss.s

            dum   LIBA_BSSEND
TM_PATH     ds    2
TM_ARGV     ds    TM_ARGVMAX*2+2
TM_N        ds    1
TM_I        ds    1
TM_WSTAT    ds    1
TICKBUF     ds    5
TM_T0       ds    4
TM_EL       ds    4
TM_SEC      ds    2
TM_TEN      ds    1
TIME_BSSEND
            dend
