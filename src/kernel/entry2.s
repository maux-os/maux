*---------------------------------------------------------------
* entry2.s -- Interrupt handling, initialization (task #3,
* docs/SYSCALL.md). Split from entry.s to keep kernel modules
* under 28KB for maux assembler's symbol-table window.
* Full design notes: K.ENTRY.TXT (docs/a2/)
*---------------------------------------------------------------
KRN_IRQ_SVC
            jsr   K_IRQ_CLL_HK ;-> device driver (task #6:
                                  ;src/kernel/timer.s -- direct-
                                  ;PIA ack, then SCH_TICK,
                                  ;which may set K_SWITCH/
                                  ;K_TARGETBANK/K_TARGETSP on
                                  ;quantum exhaustion) -- TASK
                                  ;#6 LANDING: identical
                                  ;mechanism to KRN_EXIT
                                  ;above -- -- see
                                  ;docs/SCHED.md's extended per-
                                  ;window argument for this --
                                  ;exact window (an IRQ exit
                                  ;resuming a DIFFERENT bank
                                  ;than -- the one it
                                  ;interrupted). --
KRN_IRQ_SW  lda   K_SWITCH            ;PRC_BRK_TRAP joins here
            beq   :sameproc
            stz   K_SWITCH
            lda   K_TARGETBANK
            sta   BANKSEL         ;$C073 = INCOMING pid's bank
            sta   ALTZPAUX        ;critical section -- no pushes
                                  ;until TXS
* XBANK(zp): reading the INCOMING process's own K_LCBANK is
* precisely the job -- it is per-process storage BECAUSE it
* lives in the process's zero page (inc/entry.frame.equ).
*-- zero page is the INCOMING process's now: restore the LC bank
*-- it was holding when it last lost the CPU (docs/LANGUAGE-
*-- CARD.md). Reads only; no pushes before the TXS below.
            lda   K_LCBANK
            bmi   :lcalti
            lda   LCBANK2_RAM
            bra   :lcseli
:lcalti     lda   LCBANK1_RAM
:lcseli     ldx   K_TARGETSP
            txs                   ;SP = INCOMING's saved SP
            jmp   $FF22           ;EXIT_TAIL resumes INCOMING's
                                  ;OWN trapframe -- the
                                  ;interrupted (now OUTGOING)
                                  ;process's own frame stays
                                  ;exactly as the hardware IRQ
                                  ;left it, on ITS OWN stack,
                                  ;resumed later by a future
                                  ;switch back to it
*-- THE CASE THIS WHOLE MECHANISM EXISTS FOR: a tick landed
*-- while the process was inside an LC bank bracket. Nothing
*-- switched, but the tick handler (or ProDOS, on any MLI call
*-- it made) may have reselected the default bank underneath it.
*-- Put back what the door saw, or the rest of that process's
*-- copy lands in the wrong 4 KB bank. docs/LANGUAGE-CARD.md.
:sameproc   ldx   K_CALLER_SP
            sta   ALTZPAUX        ;same critical-section
                                  ;discipline as KRN_EXIT --
                                  ;no pushes until TXS -- $C073
                                  ;intentionally NOT written --
                                  ;see file header's SCOPE --
                                  ;NOTE; this always resumes the
                                  ;bank that was interrupted. --
* XBANK(zp): reading the INTERRUPTED process's own K_LCBANK is
* precisely the job -- it is per-process storage BECAUSE it
* lives in the process's zero page (inc/entry.frame.equ).
            lda   K_LCBANK
            bmi   :lcalts
            lda   LCBANK2_RAM
            bra   :lcsels
:lcalts     lda   LCBANK1_RAM
:lcsels     txs
            jmp   $FF22
K_IRQ_CLL_HK
            jmp   (K_IRQ_HOOK)    ;same JSR-indirect trick as
                                  ;K_CALL_VEC -- the hook's own
                                  ;RTS returns to
                                  ;KRN_IRQ_SVC
*---------------------------------------------------------------
* KRN_BRK_TRAP -- the BRK HALT, and the default K_BRK_VEC target
* (INSTALL_COPY). BRK is NOT the syscall path (docs/ARCHITECTURE
* .md). Who halts here: a kernel-context BRK does not reach this
* door (main's LC $FFFE is timer.s MAIN_IRQ_SHIM, which parks
* it; the ALTZP=aux kernel windows are an accepted gap, see
* entry.s), so this is reached by a process's own BRK in an
* image with no process layer (syscalltest's closing BRK),
* and by PRC_BRK_TRAP's refusals -- pid 1 and the idle process,
* whose death would leave nothing to run. In a full image a user
* BRK is SIGTRAP instead: PRC_BRK_TRAP (procspawn2.s) kills the
* process and the machine goes on. The halt writes a marker byte
* then parks in an inspectable state; no debugger UI exists.
* A refusal parks with $C073 = 0: PRC_BRK_TRAP reads the PCB
* (BANKSEL 0) before it decides, and nothing restores the bank.
*---------------------------------------------------------------
KRN_BRK_TRAP
            lda   #$42
            sta   K_BRK_MARKER
:hang       jmp   :hang
K_BRK_MARKER ds   1
*-- K_HALT_TMR -- TMR_QUIESCE's address (timer.s fills it in at
*-- TIMER_PROBE), or 0 in an image with no timer, which is 30 of
*-- the 32. PRC_HALT (procfile3.s) calls through it; it is
*-- DEFINED HERE because three low-level harnesses --
*-- bankcopytest, schedtest, syscalltest -- link entry2.s
*-- without procfile3.s, and the zeroing below is in this file.
*-- Every image with procfile3.s has entry2.s; the reverse is
*-- not true, so the definition belongs at the wider end.
K_HALT_TMR  ds    2
* K_BYE_ARM -- TMR_REARM's address (timer.s fills it in at
* TIMER_PROBE, same call), or 0 in an image with no timer.
* PRC_BYE (procbye.s) calls through it on the way back in,
* same containment reason as K_HALT_TMR above: 30 of the 32
* kernel images link no timer.s, and kdisp.s (all 32) wires
* PRC_BYE unconditionally.
K_BYE_ARM   ds    2
* See K.ENTRY.TXT: "copyin/copyout -- resident below the active"
INSTALL_COPY
            ;-- task #6: K_SWITCH defaults to zero for every
            ;includer, even
            ;-- ones (task #3's own syscalltest.s) that never
            ;reference
            ;-- src/kernel/sched.s at all -- `ds` storage is
            ;uninitialized
            ;-- RAM, not guaranteed zero, so this explicit STZ
            ;is what makes
            ;-- KRN_EXIT/KRN_IRQ_SVC's new branch a
            ;no-op (falls
            ;-- through to the pre-existing same-bank path) for
            ;any build
            ;-- that doesn't call SCH_SWITCH. Run once, here,
            ;before any
            ;-- syscall or IRQ can possibly land. --
            stz   K_SWITCH
            ;-- SAME REASON, SAME PLACE: K_HALT_TMR
            ;-- (procfile3.s) is PRC_HALT's "does this image
            ;-- have a timer to quiesce" answer, and 30 of the
            ;-- 32 kernel images link no timer.s at all, so
            ;-- TIMER_PROBE never runs to fill it in. `ds` is
            ;-- uninitialised RAM; without this the answer is
            ;-- whatever those two bytes held at power-on, and
            ;-- PRC_HALT would jmp through it.
            stz   K_HALT_TMR
            stz   K_HALT_TMR+1
            stz   K_BYE_ARM
            stz   K_BYE_ARM+1
            ;-- SAME REASON AGAIN: K_BYE_BANK (procbye.s) is
            ;PRC_BYE's -- "already allocated" sentinel, and `ds`
            ;is uninitialised RAM. Bank 0 is never a real
            ;process/save bank (K_CURBANK's own comment,
            ;sched.s), so zero is a safe "not yet allocated"
            ;marker, but only if something actually writes it.
            stz   K_BYE_BANK
            ;-- K_BYE_BANK2 (entry.s): the SAME reason, SAME
            ;place -- the second save bank's sentinel.
            stz   K_BYE_BANK2
            ;-- K_BYE_VEC defaults to BYE_UNWIRE (entry.s), the
            ;-- SAME idiom as K_PRODOS_VEC/PRODOS_UNWIRE just
            ;-- below: only playtest.s's own PRC_BYE_INIT call
            ;-- (procbye.s) overwrites this for the one image
            ;-- that actually wants `bye` -- see entry.s's
            ;-- K_BYE_VEC comment for why (kdisp.s's shared
            ;-- dispatch table cannot omit PRC_BYE at compile
            ;-- time, so this is what lets every OTHER harness
            ;-- skip linking procbye.s at all).
            lda   #<BYE_UNWIRE
            sta   K_BYE_VEC
            lda   #>BYE_UNWIRE
            sta   K_BYE_VEC+1
            ;-- NOTE (docs/LANGUAGE-CARD.md): the LC steady
            ;-- state is NOT established here, deliberately.
            ;-- `lda LCBANK2_RAM` twice would latch write-enable
            ;-- but it also moves the READ SOURCE to RAM, and
            ;-- this runs early enough in boot for that to
            ;-- matter -- it cost check-play80 its UltraTerm
            ;-- hardware cursor when tried, 2026-09-20. It is
            ;-- also unnecessary: every LC writer in the tree
            ;-- still opens with the double read, and nothing
            ;-- can clear write-enable once latched because the
            ;-- clearing spellings are banned (check-lc).
            lda   #<PRODOS_UNWIRE
            sta   K_PRODOS_VEC
            lda   #>PRODOS_UNWIRE
            sta   K_PRODOS_VEC+1
            ;-- K_BRK_VEC defaults to the halt (entry.s), the
            ;-- SAME idiom; PRC_INIT makes a user BRK a kill
            lda   #<KRN_BRK_TRAP
            sta   K_BRK_VEC
            lda   #>KRN_BRK_TRAP
            sta   K_BRK_VEC+1
            ldx   #CPILC_SRC_END-CPILC_SRC-1
:cp1        lda   CPILC_SRC,x
            sta   COPYIN_ENTRY,x
            dex
            bpl   :cp1
            ldx   #CPOLC_SRC_END-CPOLC_SRC-1
:cp2        lda   CPOLC_SRC,x
            sta   COPYOUT_ENTRY,x
            dex
            bpl   :cp2
            rts
CPILC_SRC
            lda   K_CPY_PROC+1
            cmp   #$C0
            bcc   :inrange        ;< $C0 -> ordinary $0200-$BFFF
                                  ;flat range
            cmp   #$D0
            bcc   :refuse_io      ;$C0-$CF -> refused forever
                                  ;(never process memory, one-
                                  ;page invariant)
            lda   #2              ;>= $D0 -> LC path not
            sta   K_CPY_ERR       ;wired yet -- FIX
            rts                   ;(architect review): this used
                                  ;to fall through into :inrange
                                  ;and "copy" MAIN's own LC
                                  ;(this routine's own code --
                                  ;RAMRD does not govern $D000+
                                  ;at all) as if it were process
                                  ;memory
:refuse_io  lda   #1
            sta   K_CPY_ERR
            rts
:inrange    lda   K_CPY_LEN       ;hoist the length BEFORE the
                                  ;RAMRD flip (KERNEL-DATA-READ
                                  ;DISCIPLINE) -- pair count and
                                  ;odd bit both derive from it
                                  ;pre-flip
            beq   :emptyok        ;len=0 -> nothing to copy,
                                  ;still success
            ldy   #0
            lsr                   ;A = pair count, C = odd byte
            tax                   ;X = pair count (N/Z only --
                                  ;C survives into the bcc)
            sta   RAMRDAUX        ;flip (A irrelevant to the
                                  ;switch trigger)
            bcc   :pairs
            lda   (K_CPY_PROC),y  ;the odd byte first, so the
            sta   (K_CPY_MAIN),y  ;2x loop below is exact pairs
            iny
:pairs      txa                   ;pair count 0 (len was 1) --
            beq   :done           ;the odd byte was everything
:lp         lda   (K_CPY_PROC),y  ;process's aux memory
                                  ;(RAMRD=aux governs this
                                  ;(ptr),y read -- intentional)
            sta   (K_CPY_MAIN),y  ;main (RAMWRT unaffected,
                                  ;still main)
            iny
            lda   (K_CPY_PROC),y  ;2x unroll: 15.5 cyc/byte vs
            sta   (K_CPY_MAIN),y  ;18 un-unrolled (PERF-PLAN
            iny                   ;step 3). 2x is what the 64-
                                  ;byte template slot allows:
                                  ;this template is 63 bytes,
                                  ;and COPYOUT_ENTRY is $0140
            dex                   ;count down pairs in X --
            bne   :lp             ;zero memory reads of kernel
                                  ;state in this whole bracket
:done       sta   RAMRDMAIN
            stz   K_CPY_ERR
            rts
:emptyok    stz   K_CPY_ERR
            rts
CPILC_SRC_END
* -- SIZING TRIPWIRE (cptreebss.s's err idiom): COPYOUT_ENTRY is
* -- COPYIN_ENTRY+64, so this template gets exactly 64 bytes --
* -- one byte MORE and INSTALL_COPY overwrites the copyout
* -- template's head. Left-to-right eval: (END-SRC)/65 is 0 up
* -- to 64 bytes, nonzero at 65+, and `err` fails the assembly.
            err   CPILC_SRC_END-CPILC_SRC/65
CPOLC_SRC
            lda   K_CPY_PROC+1
            cmp   #$C0
            bcc   :inrange
            cmp   #$D0
            bcc   :refuse_io
            lda   #2              ;>= $D0 -> LC path not
            sta   K_CPY_ERR       ;wired yet -- same FIX
            rts                   ;as CPILC_SRC
:refuse_io  lda   #1
            sta   K_CPY_ERR
            rts
:inrange    lda   K_CPY_LEN       ;hoist before the RAMWRT flip
                                  ;-- see CPILC_SRC's header
                                  ;note (RAMWRT only gates
                                  ;writes, so this read was
                                  ;already safe either way, but
                                  ;the uniform pattern is
                                  ;simpler to audit)
            beq   :emptyok
            ldy   #0
            lsr                   ;A = pair count, C = odd byte
            tax
            sta   RAMWRTAUX
            bcc   :pairs
            lda   (K_CPY_MAIN),y  ;odd byte first -- mirror of
            sta   (K_CPY_PROC),y  ;CPILC_SRC's 2x scheme
            iny
:pairs      txa
            beq   :done
:lp         lda   (K_CPY_MAIN),y  ;main (RAMRD unaffected)
            sta   (K_CPY_PROC),y  ;process's aux memory
                                  ;(RAMWRT=aux governs this
                                  ;write)
            iny
            lda   (K_CPY_MAIN),y  ;2x unroll -- see CPILC_SRC
            sta   (K_CPY_PROC),y
            iny
            dex
            bne   :lp
:done       sta   RAMWRTMAIN
            stz   K_CPY_ERR
            rts
:emptyok    stz   K_CPY_ERR
            rts
CPOLC_SRC_END
* -- SIZING TRIPWIRE, same idiom as CPILC_SRC's: this template's
* -- 64 bytes end at $0180, where the active stack's floor is
* -- (the stack grows DOWN into $0180 -- ARCHITECTURE.md).
            err   CPOLC_SRC_END-CPOLC_SRC/65