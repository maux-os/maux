*---------------------------------------------------------------
* sched2.s -- Scheduler tick handling, sleep/wakeup/yield
* syscalls. Split out of sched.s (task #6, docs/SCHED.md) to
* keep each kernel module under 28000 bytes for compatibility
* with the maux assembler's shared symbol-table window.
* Full design notes: K.SCHED.TXT (docs/a2/)
*---------------------------------------------------------------


* See K.SCHED.TXT: "SCH_TICK -- called once per serviced timer"
SCH_TICK  jsr   SCLL_TCK_HOOK
            lda   K_NOSWITCH
            beq   :mayswitch
            rts                                ;critical section
                                               ;-- hold the
                                               ;quantum, do not
                                               ;preempt
* -- ^C: the tty only SETS K_INTR_PEND (any context); the
* -- kill sweep runs HERE in process-context tick time via
* -- K_INTR_HOOK (PRC_INTR_SWP, or a clc stub). Carry set =
* -- current process killed -> switch away, no requeue.
* -- A = the cell's value at the hook: the typing console+1
* -- (tty3.s TTY_INTR), which the sweep aims at. `stz` does not
* -- touch A, so the load below IS the argument.
:mayswitch  lda   K_INTR_PEND
            beq   :maystop
            stz   K_INTR_PEND
            jsr   SCLL_INTR_HK
            bcc   :maystop
            lda   #0                           ;requeue=0: the
                                               ;current process
                                               ;is a zombie now
            jsr   SCH_SWITCH
            rts
* -- ^Z (docs/JOB-CONTROL.md Increment B): the same shape, one
* -- cell over. K_STOP_HOOK is PRC_STOP_SWP where a process-
* -- bearing image installs it. Carry set = the current process
* -- is STOPPED now -- switch away with requeue=0 so it is not
* -- pushed back on the run queue (sched.s :statechk's rule).
:maystop    lda   K_STOP_PEND
            beq   :wake
            stz   K_STOP_PEND
            jsr   SCLL_STOP_HK
            bcc   :wake
            lda   #0
            jsr   SCH_SWITCH
            rts
* -- WAKE PREEMPTION (2026-09-13, docs/CONSOLE-LATENCY.md sec 5
* -- item 1): a process made runnable by SCH_WAKEUP since the
* -- last tick runs NOW, not after the current process finishes
* -- its quantum. requeue=1: the current process stays runnable
* -- and goes to the back of the run queue (SCH_SWITCH pops the
* -- woken process, already pushed by SCH_WAKEUP, before it
* -- requeues the outgoing one). Cuts an I/O-woken process's
* -- wait from up to QUANTUM_TICKS (~66 ms) to <=1 tick. K_NO-
* -- SWITCH was already honoured at the top, so an in-syscall
* -- wake defers here to the next safe tick.
:wake       lda   K_WAKE_PEND
            beq   :quantum
            stz   K_WAKE_PEND
            lda   #1
            jsr   SCH_SWITCH
            rts
:quantum    dec   K_QUANTUM
            bne   :norun
            lda   #1                           ;requeue=1:
                                               ;preempted, not
                                               ;blocked -- still
                                               ;runnable
            jsr   SCH_SWITCH
:norun      rts

SCLL_TCK_HOOK
            jmp   (K_TICK_HOOK)

SCLL_INTR_HK
            jmp   (K_INTR_HOOK)

SCLL_STOP_HK
            jmp   (K_STOP_HOOK)

STICK_HK_NOP
            rts

SINTR_HK_NOP
            clc
            rts

* See K.SCHED.TXT: "SCH_YIELD -- the cooperative-mode syscall"
SCH_YIELD lda   #1
            jsr   SCH_SWITCH
            stz   K_RESULT
            stz   K_RESULT_ERR
            rts

* See K.SCHED.TXT: "SCH_SLEEP -- A = wait channel (nonzero"
SCH_SLEEP sta   K_SW_CHAN                      ;ZP -- immune
                                                 ;to the RAMWRT-
                                                 ;only bracket
                                                 ;below
            lda   K_CURPID
            jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            sta   RAMWRTAUX                       ;WRITE-only
                                                  ;bracket --
                                                  ;RAMRD stays
                                                  ;main
            lda   #PCB_BLOCKED
            ldy   #PCB_STATE
            sta   (K_PCB_PTR),y
            lda   K_SW_CHAN
            ldy   #PCB_WCHAN
            sta   (K_PCB_PTR),y
            sta   RAMWRTMAIN
            ldx   K_CURPID                        ;the wait
            lda   K_SW_CHAN                       ;shadow, main
            sta   K_WAIT_SHD,x                    ;memory: AFTER
                                                  ;the bracket
            lda   #0                              ;requeue=0:
                                                  ;blocked, NOT
                                                  ;runnable --
                                                  ;do not
                                                  ;requeue
            jsr   SCH_SWITCH
            rts

WSHD_BIAS   equ   256-PCB_COUNT           ;scan index bias

* See K.SCHED.TXT: "SCH_WAKEUP -- A = wait channel. The O(48)"
*-- WAKE-1: the scan reads K_WAIT_SHD (48 main bytes), not the
*-- annex PCBs. It touches the annex only to wake a match, and
*-- pushes each woken pid at once (ascending pid order, as the
*-- old buffered push did), so there is no found-pid buffer.
*-- Channel 0 is "nobody": it equals every idle shadow cell, so
*-- it returns before the scan. X is biased by 256-PCB_COUNT so
*-- the loop ends on the inx wrap, with no cpx (WSHD_BIAS).
SCH_WAKEUP
            stz   K_WAKE_COUNT
            stz   BANKSEL                  ;annex, as ever:
                                           ;callers restore
            cmp   #0
            beq   :nowk
            sta   K_SW_CHAN
            ldx   #WSHD_BIAS
:scan       cmp   K_WAIT_SHD-WSHD_BIAS,x
            beq   :hit
:next       inx
            bne   :scan
            lda   K_WAKE_COUNT             ;woke >=1: ask
            beq   :nowk                    ;SCH_TICK to run a
            sta   K_WAKE_PEND              ;woken process next
:nowk       rts                            ;tick (wake preempt)

:hit        txa
            clc
            adc   #PCB_COUNT                      ;X -> pid
            pha
            jsr   PCB_PTR_FOR              ;clobbers A only
            sta   RAMWRTAUX                       ;write-only
                                                  ;bracket, safe
                                                  ;inline
            lda   #PCB_RUNNABLE
            ldy   #PCB_STATE
            sta   (K_PCB_PTR),y
            lda   #0
            ldy   #PCB_WCHAN
            sta   (K_PCB_PTR),y
            sta   RAMWRTMAIN                      ;A=0 here
            plx                                   ;X = pid
            sta   K_WAIT_SHD,x                    ;main: after
                                                  ;the bracket
            inc   K_WAKE_COUNT
            phx                                   ;RUNQ_PUSH
            txa                                   ;clobbers X
            jsr   RUNQ_PUSH
            pla
            clc
            adc   #WSHD_BIAS               ;pid -> biased X
            tax
            lda   K_SW_CHAN
            bra   :next
