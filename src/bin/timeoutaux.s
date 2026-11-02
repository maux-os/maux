*---------------------------------------------------------------
* timeoutaux.s -- timeout's own error-diagnostic tail (waiterr/
* notick/spawnerr/cantexec/notfound/toolarge/toomany/envfull/
* usage125), the tick-sampling package (TO_DECODE/SAMPLE/
* TO_REACHD/TO_REACHK), and every option/usage/message string
* plus the per-unit tick table (OPTLIST/PERITAB). `put` by
* src/bin/timeout.s (NOT a standalone binary -- the same
* put-module shape as cal.s's own calcalc.s), split out for the
* same reason units split anywhere: `as`'s 16,128-byte source
* window holds the resident manifest plus one put file at a
* time, and timeout.s's own text alone was past it (measured
* 24,421 B stripped, over by 8,295). Every symbol here resolves
* against timeout.s's own equates, data (TO_RSTAT/TO_TIMDOUT/
* TICKBUF/TARGET/KTARGET/WJSTAT/WSTATUS) and jump targets
* (:done/:notimo, referenced from timeout.s's own main flow via
* absolute jmp/jsr -- physical file location does not matter to
* those). See timeout.s's own header for the design.
*---------------------------------------------------------------
:waiterr    lda   #<WAITERRMS
            sta   PTR0
            lda   #>WAITERRMS
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

:notick     lda   #<NOTICKMS
            sta   PTR0
            lda   #>NOTICKMS
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #125
            jsr   EXIT

:spawnerr   cmp   #ERR_2BIG
            bne   :cantexec
            jmp   :toolarge
:cantexec   ldx   #<TOSPFX
            ldy   #>TOSPFX
            jsr   SPAWNWHY               ;A = the errno still
            bcc   :cantex2               ;no bank, no file slot:
            lda   #126                   ;say so. 126: found,
            jsr   EXIT                   ;could not be run (man)
:cantex2    lda   #<CANTEXEC1
            sta   PTR0
            lda   #>CANTEXEC1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   TO_ORGW
            sta   PTR0
            lda   TO_ORGW+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<CANTEXEC2
            sta   PTR0
            lda   #>CANTEXEC2
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #126
            jsr   EXIT

:notfound   lda   #<NOTFOUND1
            sta   PTR0
            lda   #>NOTFOUND1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   TO_ORGW
            sta   PTR0
            lda   TO_ORGW+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<NOTFOUND2
            sta   PTR0
            lda   #>NOTFOUND2
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #127
            jsr   EXIT

:toolarge   lda   #<TOOLARGEM
            sta   PTR0
            lda   #>TOOLARGEM
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

:toomany    lda   #<TOOMANYMS
            sta   PTR0
            lda   #>TOOMANYMS
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

:envfull    lda   #<ENVFULLMS
            sta   PTR0
            lda   #>ENVFULLMS
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #1
            jsr   EXIT

:usage125   lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #125
            jsr   EXIT

*---------------------------------------------------------------
* TO_DECODE -- WJSTAT = {kind,code} (SC_WAITJOB's own answer) ->
* TO_RSTAT, the legacy one-byte $80|signo-or-exit-code shape
* (shjob.s's JOB_REAP, line for line). CLOBBERS: A.
*---------------------------------------------------------------
TO_DECODE   lda   WJSTAT+1
            ldy   WJSTAT
            cpy   #WJ_SIGNALED
            bne   :st
            ora   #$80
:st         sta   TO_RSTAT
            rts

*---------------------------------------------------------------
* SAMPLE -- one SYS_TICK into TICKBUF (sleep.s's own routine,
* same carry-check reasoning: a garbage mode byte must never
* read as 1 or 2). CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
SAMPLE      lda   #<TICKBUF
            sta   PTR0
            lda   #>TICKBUF
            sta   PTR0+1
            jsr   SC_TICK
            bcc   :ok
            stz   TICKBUF                ;force a refusal rather
                                          ;than poll on garbage
:ok         rts

*---------------------------------------------------------------
* TO_REACHD -- carry SET when TICKBUF has reached TARGET (a
* 32-bit unsigned compare, sleep.s's REACHED, high byte first).
* CLOBBERS: A.
*---------------------------------------------------------------
TO_REACHD   lda   TICKBUF+4
            cmp   TARGET+3
            bcc   :no
            bne   :yes
            lda   TICKBUF+3
            cmp   TARGET+2
            bcc   :no
            bne   :yes
            lda   TICKBUF+2
            cmp   TARGET+1
            bcc   :no
            bne   :yes
            lda   TICKBUF+1
            cmp   TARGET
            bcc   :no
:yes        sec
            rts
:no         clc
            rts

*---------------------------------------------------------------
* TO_REACHK -- same compare, against KTARGET -- fixed storage
* of its own, kept separate from TARGET so a -k grace period
* never disturbs the original deadline. CLOBBERS: A.
*---------------------------------------------------------------
TO_REACHK   lda   TICKBUF+4
            cmp   KTARGET+3
            bcc   :no
            bne   :yes
            lda   TICKBUF+3
            cmp   KTARGET+2
            bcc   :no
            bne   :yes
            lda   TICKBUF+2
            cmp   KTARGET+1
            bcc   :no
            bne   :yes
            lda   TICKBUF+1
            cmp   KTARGET
            bcc   :no
:yes        sec
            rts
:no         clc
            rts

OPTLIST     asc   "fpk:s:"
            dfb   0
USAGEMSG    asc   "usage: timeout [-fp] [-k time] "
            asc   "[-s signal] duration utility "
            asc   "[argument...]"
            dfb   $8D,$00
NOTICKMS    asc   "timeout: no timer (needs a mouse card"
            asc   " or Mockingboard)"
            dfb   $8D,$00
WAITERRMS   asc   "timeout: wait failed"
            dfb   $8D,$00
TOOLARGEM   asc   "timeout: environment too large"
            dfb   $8D,$00
TOOMANYMS   asc   "timeout: argument list too long"
            dfb   $8D,$00
ENVFULLMS   asc   "timeout: too many environment vars"
            dfb   $8D,$00
NOTFOUND1   asc   "timeout: "
            dfb   $00
NOTFOUND2   asc   ": not found"
            dfb   $8D,$00
TOSPFX      asc   'timeout: '
            dfb   0
CANTEXEC1   asc   "timeout: "
            dfb   $00
CANTEXEC2   asc   ": cannot execute"
            dfb   $8D,$00
SIGNM_TERM  asc   "TERM"
            dfb   0
SIGNM_KILL  asc   "KILL"
            dfb   0
SIGNM_HUP   asc   "HUP"
            dfb   0
SIGNM_INT   asc   "INT"
            dfb   0
SIGNM_QUIT  asc   "QUIT"
            dfb   0

*-- per-unit tick constants, little-endian 32-bit: seconds(60),
*-- minutes(3600), hours(216000). Computed, not guessed --
*-- 216000 = 60(TICKS_HZ) * 3600(s/hr).
PERITAB     dfb   $3C,$00,$00,$00
            dfb   $10,$0E,$00,$00
            dfb   $C0,$4B,$03,$00

*-- ONE TENTH of each of those, same order and same shape: 6,
*-- 360, 21600. A fractional duration's digit is worth a tenth
*-- of ITS OWN unit, so "1.5m" is 90 seconds and not 1 minute
*-- plus half a second. Each entry is exact -- every tick count
*-- above divides by 10 -- so there is no rounding to document
*-- and no division to perform at run time.
TENTHTAB    dfb   $06,$00,$00,$00
            dfb   $68,$01,$00,$00
            dfb   $60,$54,$00,$00
