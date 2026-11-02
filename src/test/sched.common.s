*---------------------------------------------------------------
* sched.common.s -- shared body for `make check-sched`'s two
* boot images (src/test/sched.preempt.s,
* src/test/sched.coop.s -- task #6, docs/SCHED.md). PUT-
* included AFTER each top-level file's own LOADER section (block
* 0) and its own `ST_MODE equ 0|1` definition (0 = VBL-
* preemption round-robin, no process ever yields; 1 =
* cooperative, the timer probe is FORCED away from any hardware
* source and only an explicit yield syscall alternates the two
* processes) -- same "define a mode constant, then `put` the
* shared body" pattern as ffpage.s/ ffpage.size.s sharing one
* template two ways.
*
* Two fake processes, banks 1 and 2, each running an infinite
* loop that increments its OWN bank's $0900/$0901 counter --
* nothing in either process ever touches the other bank, so
* `make check-sched`'s Python driver can read both counters
* directly via peek(bank="aux", aux_bank=N), with zero in-kernel
* report/print code needed for grading (TIMER_REPORT's screen
* banner, promoted from src/kernel/timer.s, is kept only for
* human-readable boot confirmation).
*
* Library handles fetched for this task (HACKING.md loop) beyond
* the task-cited set: none new -- this file is pure test-harness
* plumbing, reusing src/test/syscalltest.s's already-verified
* LOADER/STAMP/ boot-sequence idioms
* (learning:01KZZ55AZ98V8P0FQASXWQ6K7T, block-0 boot contract)
* rather than re-deriving them.
*---------------------------------------------------------------
* NOTE: does NOT `use`/`put` any further files here -- merlin32
* only recurses ONE level of put/use from the file actually
* handed to the assembler (bankprobe.s's own header documents
* this gotcha in detail, confirmed AGAIN empirically while
* wiring up this task's own build: a `put ../kernel/entry.s`
* written inside THIS file, itself already put-included by
* sched.preempt.s/sched.coop.s, is silently never loaded
* -- "Can't find format for element 'FFP_SYSC_ENT'" was the
* symptom). K_DISP_COUNT/K_IRQ_HOOK and the four `put`s
* (entry.s/ffpage.s/sched.s/timer.s) therefore live in EACH top-
* level file directly, before `put`ting this file in -- see
* src/test/sched.preempt.s or sched.coop.s.

ST_YIELD_CALL equ 1
ST_WAKE_CALL  equ 2       ;ST_MODE=2 (wake) only
                                 ;-- see TCALL_WAKE below.
                                 ;Harmless, unused dispatch slot
                                 ;for modes 0/1.

K_DISP_LO
            dfb   <SCH_YIELD
            dfb   <TCALL_WAKE
K_DISP_HI
            dfb   >SCH_YIELD
            dfb   >TCALL_WAKE

*---------------------------------------------------------------
* TCALL_WAKE -- code review C1 regression gate
* (ST_MODE=2 only; docs/SCHED.md). Records K_VBL_TICKS at
* the moment of the call into this file's own K_WAKE_TICK (test-
* only global, peeked by scripts/check_sched.py -- NOT part of
* the kernel's real ABI), then calls SCH_WAKEUP on
* TESTWAKE_CHAN exactly like any real blocking syscall's wakeup
* half would. Runs in the same kernel dispatch context
* SCH_YIELD does (ALTZP/RAMRD/RAMWRT already main --
* KRN_ENTRY's own flip already happened before K_CALL_VEC
* reaches here).
*---------------------------------------------------------------
TESTWAKE_CHAN equ $55

TCALL_WAKE
            lda   K_VBL_TICKS
            sta   K_WAKE_TICK
            lda   K_VBL_TICKS+1
            sta   K_WAKE_TICK+1
            lda   #TESTWAKE_CHAN
            jsr   SCH_WAKEUP
            ;-- BUG FOUND BY TESTING, THIS ROUND: SCH_WAKEUP
            ;selects
            ;-- BANKSEL=0 (annex) internally for its PCB scan
            ;and never
            ;-- restores the CALLER's bank before returning --
            ;every real
            ;-- caller in src/kernel/process.s relies on its OWN
            ;-- PRC_SEL_CRBNK call after SCH_WAKEUP (see
            ;e.g.
            ;-- PRC_READ/PRC_WRITE's pipe-wake tails,
            ;PRC_FAIL_A/
            ;-- PRC_RET_OK_A which every process.s handler
            ;funnels
            ;-- through) to reselect the CURRENT process's bank
            ;before
            ;-- KRN_EXIT's ALTZP flip. This test-only handler
            ;needs the
            ;-- identical fixup, or KRN_EXIT patches the
            ;return frame
            ;-- (and EXIT_TAIL's RTI pulls it) from bank 0's
            ;page 1 instead
            ;-- of the calling process's -- a wild jump, not a
            ;benign
            ;-- no-op, exactly the class of bug docs/SYSCALL.md
            ;#5.1/#7.7
            ;-- already catalogs several instances of.
            jsr   ST_SELCURBNK
            stz   K_RESULT
            stz   K_RESULT_ERR
            rts

K_WAKE_TICK ds    2

*---------------------------------------------------------------
* ST_SELCURBNK -- re-selects BANKSEL for K_CURPID's
* OWN bank. Same shape as src/kernel/process.s's
* PRC_SEL_CRBNK (that file isn't `put` into this test
* harness, so it's duplicated here rather than cross-included --
* see this module's own header on the one-level put/use rule).
*---------------------------------------------------------------
ST_SELCURBNK
            lda   K_CURPID
            jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            lda   #PCB_BANK
            ldx   #1
            jsr   PCB_RD_FIELDS
            lda   K_PCB_SCRATCH
            sta   BANKSEL
            rts

*---------------------------------------------------------------
* BLOCK_PID -- ST_MODE=2 boot-time-only helper. A = pid,
* X = wait channel. Directly marks pid's PCB PCB_BLOCKED
* (PCB_WCHAN=X), the same two writes SCH_SLEEP performs, but
* for an ARBITRARY pid instead of K_CURPID -- there is no
* running process yet at boot time to call SCH_SLEEP itself
* as. Caller MUST already have removed this pid from the run
* queue (MAIN_ENTRY's mode-2 path does this via a bare `dec
* RUNQ_TAIL`, undoing the immediately-preceding SCH_CREATE's
* own RUNQ_PUSH, since nothing else has touched RUNQ yet at that
* point in boot) -- this routine only touches the PCB, never
* RUNQ.
*---------------------------------------------------------------
BLOCK_PID   pha                          ;pid, for the shadow
            jsr   PCB_PTR_FOR              ;A=pid consumed; X
                                           ;(wchan) survives --
                                           ;PCB_PTR_FOR clobbers
                                           ;only A
            lda   #0
            sta   BANKSEL
            sta   RAMWRTAUX
            lda   #PCB_BLOCKED
            ldy   #PCB_STATE
            sta   (K_PCB_PTR),y
            txa
            ldy   #PCB_WCHAN
            sta   (K_PCB_PTR),y
            sta   RAMWRTMAIN
            ply                        ;3rd write (WAKE-1):
            txa                        ;the wait shadow,
            sta   K_WAIT_SHD,y         ;main, after bracket
            rts

*---------------------------------------------------------------
* STAMP_BANK -- A = target aux bank number. Copies the $FFxx
* template (ffpage.s) into that bank's $FF00 (same
* RAMWRT+BANKSEL-then-ALTZP+LC bounce as
* src/test/syscalltest.s's STAMP_BANK1, generalized to an
* arbitrary bank) and stamps BANK_ID = the bank number (this
* test's own convention: pid == bank number, so BANK_ID doubles
* as each process's self-identity byte, docs/MEMMAP.md #3.3).
*---------------------------------------------------------------
STAMP_BANK  sta   K_STAMP_BANK
            sta   BANKSEL
            lda   LCBANK2_RAM
            lda   LCBANK2_RAM
            sta   ALTZPAUX
            ldy   #0
:cp1        lda   FFP_SYSC_ENT,y
            sta   $FF00,y
            iny
            bne   :cp1
            lda   K_STAMP_BANK
            sta   BANK_ID                     ;memmap.equ's own
                                              ;absolute $FF2E
                                              ;constant -- this
                                              ;write lands
                                              ;inside bank's OWN
                                              ;$FFxx page
                                              ;(ALTZP=aux, still
                                              ;open)
            sta   ALTZPMAIN
            rts
K_STAMP_BANK ds   1

* See T.SCHEDCOMM.TXT: "SYNTHFRAME -- A  target aux"
SYNTH_FRAME sta   BANKSEL
            sta   ALTZPAUX
            lda   #0
            sta   $01FA                        ;FRAME_Y (call#,
                                               ;irrelevant for a
                                               ;synthesized
                                               ;launch)
            sta   $01FB                        ;FRAME_X (parms
                                               ;hi)
            sta   $01FC                        ;FRAME_A (parms
                                               ;lo)
            lda   #$20
            sta   $01FD                        ;FRAME_P -- I=0
            lda   #<LOAD_BASE
            sta   $01FE                        ;FRAME_PCL
            lda   #>LOAD_BASE
            sta   $01FF                        ;FRAME_PCH --
                                               ;($0800)
            sta   ALTZPMAIN
            rts

*---------------------------------------------------------------
* COPY_PROC -- A = target aux bank number, CP_SRC (ZP, set by
* caller) = pointer to a PIC fake-process blob in main memory, X
* = blob length. Copies the blob to LOAD_BASE ($0800) in the
* target bank -- same RAMWRT+BANKSEL bounce as
* src/test/syscalltest.s's FAKEPROC copy.
*---------------------------------------------------------------
CP_SRC      equ   $F0             ;2 -- test-local ZP scratch,
                                  ;clear of sched.s's $E0-$ED
                                  ;and entry.s's $F3-$FC
CP_LEN      equ   $F2             ;1

COPY_PROC   sta   BANKSEL
            sta   RAMWRTAUX
            stx   CP_LEN
            ldy   #0
:cp         lda   (CP_SRC),y
            sta   LOAD_BASE,y
            iny
            cpy   CP_LEN
            bne   :cp
            sta   RAMWRTMAIN
            rts

*---------------------------------------------------------------
* FKP_SPIN -- the VBL-preemption variant's process body
* (both banks run an IDENTICAL copy -- position-independent, no
* internal absolute self-reference, same discipline as every
* other copy-source blob in this tree). Tight infinite loop:
* increments its OWN bank's $0900/$0901 16-bit counter forever.
* NEVER issues a syscall, NEVER yields -- the whole point is
* that preemption alternates it and its sibling process with
* zero cooperation, purely via VBL-driven quantum exhaustion.
*---------------------------------------------------------------
FKP_SPIN
:top        inc   $0900
            bne   :skip
            inc   $0901
:skip       bra   :top
FKP_SPIN_END
FKP_SPIN_LEN equ FKP_SPIN_END-FKP_SPIN

*---------------------------------------------------------------
* FKP_COOP -- the cooperative-mode variant's process body.
* Same counter, but yields voluntarily every COOP_BURST
* increments via ST_YIELD_CALL ($FF00, Y=1) --
* alternation happens ONLY because each process calls
* SCH_YIELD, never via a timer (the timer probe is forced to
* TIMER_MD_COOP for this build -- no hardware IRQ source is
* ever armed, src/kernel/timer.s's TMR_ARM_NOPHK).
*---------------------------------------------------------------
COOP_BURST  equ   50               ;increments per yield -- a
                                   ;judgment call, small enough
                                   ;that check-sched's step
                                   ;budget sees many yields

FKP_COOP
:top        inc   $0900
            bne   :skip
            inc   $0901
:skip       inc   $0902
            lda   $0902
            cmp   #COOP_BURST
            bne   :top
            stz   $0902
            lda   #<0
            ldx   #>0
            ldy   #ST_YIELD_CALL
            jsr   $FF00
            bra   :top
FKP_COOP_END
FKP_COOP_LEN equ FKP_COOP_END-FKP_COOP

*---------------------------------------------------------------
* FKP_WAKE -- ST_MODE=2's bank-1 process body (C1
* regression variant, code review, docs/SCHED.md).
* Spins like FKP_SPIN -- never yields, so alternation is
* entirely quantum-driven, exercising the SAME empty-runqueue
* cancel path C1 fixes over and over, since bank 2's process is
* parked BLOCKED (never on the run queue) until this body wakes
* it -- until WAKE_BURST loop iterations have passed (chosen
* large enough to span several QUANTUM_TICKS-sized timeslices'
* worth of cycles, so the cancel path fires repeatedly before
* the wake, reproducing the exact scenario
* the code review's C1 describes: "after another process
* wakes, the current process can receive a fresh 256-tick
* wraparound"), at which point it issues ONE ST_WAKE_CALL
* (guarded by the $0903 flag so it fires exactly once) and then
* spins forever, identical to FKP_SPIN.
*---------------------------------------------------------------
WAKE_BURST  equ   $2EE0            ;16-bit loop-iteration target
                                   ;(~12000) -- large enough to
                                   ;span several quantum
                                   ;timeslices of empty-runqueue
                                   ;cancels before the wake
                                   ;fires (see header)

FKP_WAKE
:top        inc   $0900
            bne   :skip
            inc   $0901
:skip       lda   $0903
            bne   :nowake
            inc   $0904
            bne   :chkhi
            inc   $0905
:chkhi      lda   $0904
            cmp   #<WAKE_BURST
            bne   :top
            lda   $0905
            cmp   #>WAKE_BURST
            bne   :top
            lda   #1
            sta   $0903
            lda   #<0
            ldx   #>0
            ldy   #ST_WAKE_CALL
            jsr   $FF00
:nowake     bra   :top
FKP_WAKE_END
FKP_WAKE_LEN equ FKP_WAKE_END-FKP_WAKE

*---------------------------------------------------------------
* STAMP_MAIN -- defensive-only, same rationale as
* src/test/syscalltest.s's copy: if ANY interrupt is ever
* recognized while ALTZP=main, the CPU vectors through MAIN's
* own $FFFE, which must not be garbage/uninitialized LC content.
*---------------------------------------------------------------
STAMP_MAIN  lda   LCBANK2_RAM
            lda   LCBANK2_RAM
            ldy   #0
:cpm        lda   FFP_SYSC_ENT,y
            sta   $FF00,y
            iny
            bne   :cpm
            rts
*-- BANNER0 moved above MAIN_ENTRY (S9 EQU burn-down
*-- 2026-08-29): BANNER0LEN was used immediate before its
*-- definition. After an rts -- never fallen into.

BANNER0     asc   "MAUX SCHED"
BANNER0LEN  equ   *-BANNER0


*---------------------------------------------------------------
* MAIN_ENTRY -- boot sequence, shared by both variants (branches
* on ST_MODE, defined by the top-level file before
* `put`ting this one in): install copyin/copyout, stamp main's
* defensive $FFxx, SCH_INIT, probe the timer (forced to
* cooperative for ST_MODE=1), stamp + populate both
* process banks, SCH_CREATE both pids, SCH_START -- never
* returns; the two processes run from here on, alternated purely
* by the scheduler (preemptively or cooperatively per the mode).
*---------------------------------------------------------------
MAIN_ENTRY  ldy   #0
:banner     lda   BANNER0,y
            sta   $0400,y
            iny
            cpy   #BANNER0LEN
            bne   :banner

            jsr   INSTALL_COPY
            jsr   STAMP_MAIN
            jsr   SCH_INIT

            stz   K_TIMER_FORCE
            lda   #ST_MODE
            cmp   #1
            bne   :notcoop
            lda   #TIMER_MD_COOP
            sta   K_TIMER_FORCE
:notcoop    jsr   TIMER_PROBE

            lda   #1
            jsr   STAMP_BANK
            lda   #1
            jsr   SYNTH_FRAME
            lda   #2
            jsr   STAMP_BANK
            lda   #2
            jsr   SYNTH_FRAME

            lda   #ST_MODE
            cmp   #1
            beq   :coopvariant
            cmp   #2
            beq   :wakevariant
            bra   :spinvariant

:coopvariant
            ;-- cooperative: copy FKP_COOP into both banks
            ;--
            lda   #<FKP_COOP
            sta   CP_SRC
            lda   #>FKP_COOP
            sta   CP_SRC+1
            ldx   #FKP_COOP_LEN
            lda   #1
            jsr   COPY_PROC
            lda   #<FKP_COOP
            sta   CP_SRC
            lda   #>FKP_COOP
            sta   CP_SRC+1
            ldx   #FKP_COOP_LEN
            lda   #2
            jsr   COPY_PROC
            bra   :bothcopied

:wakevariant
            ;-- C1 regression (docs/SCHED.md): bank 1 gets
            ;FKP_WAKE
            ;-- (spins, then wakes bank 2 once); bank 2 gets
            ;plain
            ;-- FKP_SPIN (it doesn't run at all until
            ;woken). --
            lda   #<FKP_WAKE
            sta   CP_SRC
            lda   #>FKP_WAKE
            sta   CP_SRC+1
            ldx   #FKP_WAKE_LEN
            lda   #1
            jsr   COPY_PROC
            lda   #<FKP_SPIN
            sta   CP_SRC
            lda   #>FKP_SPIN
            sta   CP_SRC+1
            ldx   #FKP_SPIN_LEN
            lda   #2
            jsr   COPY_PROC
            bra   :bothcopied

:spinvariant
            lda   #<FKP_SPIN
            sta   CP_SRC
            lda   #>FKP_SPIN
            sta   CP_SRC+1
            ldx   #FKP_SPIN_LEN
            lda   #1
            jsr   COPY_PROC
            lda   #<FKP_SPIN
            sta   CP_SRC
            lda   #>FKP_SPIN
            sta   CP_SRC+1
            ldx   #FKP_SPIN_LEN
            lda   #2
            jsr   COPY_PROC

:bothcopied
            lda   #1
            ldx   #1
            jsr   SCH_CREATE                 ;pid 1, bank 1
            lda   #2
            ldx   #2
            jsr   SCH_CREATE                 ;pid 2, bank 2 --
                                               ;pushed RUNNABLE
                                               ;by SCH_CREATE;
                                               ;mode 2
                                               ;immediately
                                               ;undoes that
                                               ;below

            stz   K_WAKE_TICK                   ;clean sentinel
                                                ;-- `ds`
            stz   K_WAKE_TICK+1                 ;storage isn't
                                                ;guaranteed zero
                                                ;at boot
                                                ;otherwise

            lda   #ST_MODE
            cmp   #2
            bne   :nowake2
            dec   RUNQ_TAIL                      ;undo pid 2's
                                                 ;SCH_CREATE
                                                 ;push above
                                                 ;(see
                                                 ;BLOCK_PID's
                                                 ;header) -- pid
                                                 ;1 is now the
                                                 ;RUN QUEUE's
                                                 ;sole member
            lda   #2
            ldx   #TESTWAKE_CHAN
            jsr   BLOCK_PID                      ;pid 2 ->
                                                 ;PCB_BLOCKED, W
                                                 ;CHAN=TESTWAKE_
                                                 ;CHAN
:nowake2
            jsr   SCH_START                   ;never returns
