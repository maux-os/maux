*---------------------------------------------------------------
* sleep.s -- `SLEEP N`, N whole seconds (docs/SHELL-GAPS.md
* sec 5). V6 had it; maux could not until SYS_TICK existed,
* because a WALL CLOCK is the wrong primitive for elapsed time:
* one that can be set backwards is not a stopwatch, and half the
* machines this runs on have a clock with no interrupt or an
* interrupt with no clock.
*
* IT SLEEPS. SYS_SLPUNTIL (docs/SLEEP-1.md) blocks the process
* on a kernel wait channel until the tick counter reaches an
* ABSOLUTE target, which this program computes: the count
* SYS_TICK reports now, plus SECONDS * 60. A sleeping process
* is BLOCKED, not runnable: it takes no share of any quantum,
* which the polling version did (a background `sleep 300` cost
* a CPU-bound foreground job 2.7x -- docs/SLEEP-1-NOTES.md).
* The target is absolute because a blocked call is RERUN whole
* on wake (PRC_BLCK_RTRY): a relative N would restart each wake.
* The kernel compares by signed modular subtraction, so a target
* that crosses $FFFFFFFF -> 0 is right; the old unsigned
* `now >= target` here was not.
*
* IT REFUSES RATHER THAN HANGS WHEN THERE IS NO TICK SOURCE. In
* TIMER_MD_COOP (and with no timer driver at all, mode 0) the
* counter is not slow, it is FROZEN, so the kernel answers
* ERR_NOSYS instead of blocking for ever, and this program says
* so on fd 2 and exits nonzero. The refusal is the KERNEL's:
* this program no longer checks the mode itself, so the guard
* in PRC_SLPUNTIL is the one that matters, and `sleep 0` is
* refused on such a machine as before.
*
* HOW IT IS PROVEN: the REFUSAL path is audited by
* check-textaudit (its harness links no timer driver, so
* SYS_TICK reports mode 0 and this program must exit 1,
* identically on both runs of a repeat pair); the RUNNING path
* by check-sleep and check-play, whose harnesses link
* src/kernel/timer.s so the probe finds the AppleMouse VBL:
* `SLEEP 0` returns promptly and `SLEEP 1` does not.
*
* Uses ONLY liba -- no direct syscalls, no raw gate address.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            put   ../../inc/errno.krn.equ
            org   LOAD_BASE
            dsk   ../../build/sleep.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

TICKS_HZ    equ   60          ;all three interrupt modes count
                              ;at the same nominal rate --
                              ;timer.s's own header says so for
                              ;the Mockingboard tier
MAXSECS     equ   9999        ;refused above this; 9999 s is
                              ;~2.8 h and 599,940 ticks, well
                              ;inside the 32-bit counter

START       lda   #1
            jsr   GETARG                 ;PTR0 = argv[1]
            bcc   :haveargs
            jmp   USAGE
:haveargs   lda   #2
            cmp   ARGC
            beq   :parse
            jmp   USAGE                  ;exactly one operand
:parse      jsr   PARSESECS
            bcc   :havesecs
            jmp   USAGE
:havesecs
*-- No mode check here: the kernel refuses a machine whose
*-- counter is frozen (see the header), and `sleep 0` takes the
*-- same road so it is refused there too.
            jsr   SAMPLE
            jsr   MKTARGET               ;TARGET = now + N*60
            lda   #<TARGET
            ldx   #>TARGET
            jsr   SC_SLPUNTIL
            bcs   :refused
            jmp   OKEXIT
:refused    cmp   #ERR_INTR              ;a held signal: sleep
            bne   :notimer               ;never catches one, but
            lda   #1                     ;say so by status,
            jsr   SC_EXIT                ;not "no timer"
:notimer    jmp   NOTICK

*---------------------------------------------------------------
* PARSESECS -- IN: PTR0 = the operand. OUT: carry CLEAR and SECS
* = its value; carry SET if it is empty, holds a non-digit, or
* exceeds MAXSECS. CLOBBERS: A, X, Y.
*
* REFUSES THE OVERFLOW rather than wrapping: `SLEEP 99999`
* silently becoming a 1.6-second nap is precisely the plausible
* wrong answer this tree keeps refusing.
*---------------------------------------------------------------
PARSESECS   stz   SECS
            stz   SECS+1
            ldy   #0
            lda   (PTR0),y
            bne   :loop                  ;empty operand
:badj       jmp   :bad
:loop       lda   (PTR0),y
            beq   :done
            and   #$7F                   ;liba text is high-bit
            cmp   #'0'
            bcc   :badj
            cmp   #'9'+1
            bcs   :badj
            sec
            sbc   #'0'
            pha
            jsr   MUL10SECS
            pla
            clc
            adc   SECS
            sta   SECS
            lda   SECS+1
            adc   #0
            sta   SECS+1
            lda   SECS+1                 ;past MAXSECS yet?
            cmp   #>MAXSECS
            bcc   :next
            bne   :bad
            lda   SECS
            cmp   #<MAXSECS+1
            bcs   :bad
:next       iny
            bne   :loop
:bad        sec
            rts
:done       clc
            rts

*---------------------------------------------------------------
* MUL10SECS -- SECS *= 10, as n*8 + n + n; this machine has no
* multiply. A SUBROUTINE rather than inline, because inlining it
* made PARSESECS's digit loop longer than an 8-bit backward
* branch could span -- merlin32 said so, twice.
* CLOBBERS: A.
*---------------------------------------------------------------
MUL10SECS   lda   SECS
            sta   TMPA
            lda   SECS+1
            sta   TMPA+1
            asl   SECS                   ;n*2
            rol   SECS+1
            asl   SECS                   ;n*4
            rol   SECS+1
            asl   SECS                   ;n*8
            rol   SECS+1
            clc
            lda   SECS                   ;n*8 + n ...
            adc   TMPA
            sta   SECS
            lda   SECS+1
            adc   TMPA+1
            sta   SECS+1
            clc
            lda   SECS                   ;... + n == n*10
            adc   TMPA
            sta   SECS
            lda   SECS+1
            adc   TMPA+1
            sta   SECS+1
            rts

*---------------------------------------------------------------
* SAMPLE -- one SYS_TICK into TICKBUF. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
*-- CHECK THE CARRY, and this is not defensive padding: it is
*-- the trap src/bin/date.s's own header records. PRC_TICK
*-- returns WITHOUT writing the caller's buffer if its parameter
*-- copy-in or its BankCopy fails, and TICKBUF lives in `dum`,
*-- which is bank GARBAGE rather than zeros. A garbage mode byte
*-- that happens to read 1 or 2 walks straight past the mode
*-- check into a poll loop on a frozen counter -- i.e. it hangs.
*-- Found exactly that way: check-fleet did not fail with a
*-- wrong byte, it ran 900 million cycles and stopped.
SAMPLE      lda   #<TICKBUF
            sta   PTR0
            lda   #>TICKBUF
            sta   PTR0+1
            jsr   SC_TICK
            bcs   :failed
            rts
:failed     jmp   TICKFAIL

*---------------------------------------------------------------
* MKTARGET -- TARGET = the count just sampled + SECS*TICKS_HZ,
* 32-bit. The multiply is SECS added TICKS_HZ times: 60 32-bit
* adds is nothing beside a sleep, and it is obviously correct,
* which a shift-and-add chain of four terms would not be at a
* glance. CLOBBERS: A, X.
*---------------------------------------------------------------
MKTARGET    ldx   #0
:zero       lda   TICKBUF+1,x
            sta   TARGET,x
            inx
            cpx   #4
            bne   :zero
            ldx   #TICKS_HZ
:add        clc
            lda   TARGET
            adc   SECS
            sta   TARGET
            lda   TARGET+1
            adc   SECS+1
            sta   TARGET+1
            lda   TARGET+2
            adc   #0
            sta   TARGET+2
            lda   TARGET+3
            adc   #0
            sta   TARGET+3
            dex
            bne   :add
            rts

USAGE       lda   #<USAGE_MSG
            sta   PTR0
            lda   #>USAGE_MSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   SC_EXIT

TICKFAIL    lda   #<TICKFAIL_MSG
            sta   PTR0
            lda   #>TICKFAIL_MSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   SC_EXIT

NOTICK      lda   #<NOTICK_MSG
            sta   PTR0
            lda   #>NOTICK_MSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   SC_EXIT

OKEXIT      lda   #0
            jsr   SC_EXIT

USAGE_MSG   asc   "usage: sleep SECONDS"
            dfb   $8D,0
*-- Names the CAUSE, not just the symptom: someone reading this
*-- on a bare //e needs to know an AppleMouse or a Mockingboard
*-- is what supplies the tick, because nothing else will tell
*-- them.
TICKFAIL_MSG
            asc   "sleep: tick syscall failed"
            dfb   $8D,0
NOTICK_MSG  asc   "sleep: no timer (needs a mouse card"
            asc   " or Mockingboard)"
            dfb   $8D,0

            put   ../liba/string.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/argv.s
            put   ../liba/syssleep.s
            put   ../liba/libabss.s

            dum   LIBA_BSSEND
SECS        ds    2
TMPA        ds    2
TICKBUF     ds    5
TARGET      ds    4
SLEEP_BSSEND
            dend
