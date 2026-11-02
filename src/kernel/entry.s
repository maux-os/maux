*---------------------------------------------------------------
* entry.s -- main-side kernel entry/exit/dispatch machinery
* (task #3, docs/SYSCALL.md).
* Full design notes: K.ENTRY.TXT (docs/a2/)
*---------------------------------------------------------------
MLI_RANGE_LO equ $65
* See K.ENTRY.TXT: "kernel-owned zero page (mains own ZP"
K_VEC       equ   $F5        ;2  computed dispatch-handler
                             ;address
* -- cross-ALTZP-flip cells -- ordinary main memory, NOT zero
* page (see -- the correctness-fix note above). Declared as real
* `ds` storage -- (assembler-placed, wherever this module ends
* up) rather than fixed -- literal addresses, same idiom as
* K_BRK_MARKER below. --
K_CALLER_SP ds    1           ;process SP captured by
                              ;[KRN_ENTRY|
                              ;KRN_IRQ_ENTRY]'s TSX
K_OUTBANK   ds    1           ;KRN_EXIT's own K_SWITCH!=0
                              ;branch: the caller's PCB_BANK,
                              ;looked up lazily there (never
                              ;touched on the hot, unswitched
                              ;path)
K_CALLNUM   ds    1           ;call number (frame-Y, cached)
K_ISBRK     ds    1           ;KRN_IRQ_ENTRY's B-flag test
                              ;result
K_PARMLO    ds    1           ;parms ptr lo (frame-A, cached --
                              ;the register-transport ruling's
                              ;"A low byte")
K_PARMHI    ds    1           ;parms ptr hi (frame-X, cached)
* -- task #6 scheduler hooks (docs/SCHED.md). Ordinary main
* memory for the -- SAME reason as the cross-flip cells above:
* KRN_EXIT/KERNEL_IRQ_ -- SERVICE read these AFTER their own
* ALTZP=aux flip, and RAMRD/RAMWRT -- are ALREADY main by that
* point -- so an ordinary (non-ZP) address -- reads correctly
* regardless of ALTZP's state, same argument as -- K_CALLER_SP.
* src/kernel/sched.s is the only module that writes them --
* (this file only READS K_SWITCH/K_TARGETBANK/K_TARGETSP, and
* only -- ever WRITES the zero in INSTALL_COPY below, to a safe
* default for -- includers that never touch the scheduler at
* all). --
K_SWITCH    ds    1           ;0 = resume the SAME bank (task
                              ;#3's original behavior); nonzero
                              ;= sched.s has picked a DIFFERENT
                              ;incoming pid -- see KRN_EXIT /
                              ;KRN_IRQ_SVC below
K_TARGETBANK ds   1           ;incoming pid's physical aux bank
                              ;(BANKSEL value) -- valid only
                              ;when K_SWITCH != 0
K_TARGETSP  ds    1           ;incoming pid's saved SP
                              ;(PCB_SAVEDSP) -- valid only when
                              ;K_SWITCH != 0
* -- K_BYE_BANK: declared HERE, not in procbye.s (moved
* -- 2026-09-25), for the SAME reason as K_SWITCH above --
* -- entry2.s's INSTALL_COPY zeroes it unconditionally
* -- (PRC_BYE's "already allocated" sentinel must be a safe
* -- 0 before any bye call), and entry2.s is put by every
* -- one of the ~32 production images plus the
* -- sched.*.s/prodos.spike.s test harnesses -- several of
* -- which do NOT put procbye.s at all
* -- (no `bye` support needed there). Declaring it in procbye.s
* -- itself left entry2.s's zero-out referencing an undefined
* -- symbol on every harness that omits procbye.s -- measured:
* -- 'Impossible to decode address mode for instruction stz
* -- K_BYE_BANK' on sched.preempt.s/sched.coop.s/sched.wake.s,
* -- caught only once check-all-box-par finally exercised them.
* -- procbye.s now just USES this symbol; it declares nothing.
K_BYE_BANK  ds    1           ;PRC_BYE's own "already allocated"
                              ;sentinel (procbye.s) -- 0 = not
                              ;yet allocated, never a real bank
* -- K_BYE_BANK2: the SECOND save bank, for aux bank 0 (the
* -- annex) -- 2026-09-26 ruling, docs/BYE.md. SAME containment
* -- reason as K_BYE_BANK above. procbye.s's PBY_CHK_STAMP/
* -- PBY_WR_STAMP are shared (generalized on PBY_BANKARG) by
* -- both banks' own ensure-and-stamp call sites.
K_BYE_BANK2 ds    1           ;PRC_BYE's second "already
                              ;allocated" sentinel -- same 0 =
                              ;not yet allocated convention
* -- K_BYE_VEC / PRC_BYE_STUB (2026-09-25): the SAME shape THIS
* -- FILE already uses for P8_DELEGATE/PRODOS_UNWIRE/
* -- K_PRODOS_VEC below -- an unconditional `jmp (vector)`,
* -- defaulting to a fail stub stamped by entry2.s's
* -- INSTALL_COPY (every harness runs it), overwritten only
* -- by an image that wants the real thing. kdisp.s's shared
* -- dispatch table is put by all ~32 kernel-call harnesses
* -- and names PRC_BYE (procbye.s) UNCONDITIONALLY at its
* -- SYS_BYE slot -- a `dfb <PRC_BYE` is a compile-time
* -- address, so kdisp.s itself
* -- cannot omit procbye.s no matter how few of those 32
* -- harnesses ever call `bye`. MEASURED: this is what forced
* -- every one of them to link procbye.s and its own wide
* -- dependency closure (entry2/ffpage/sched/sched2/bankcopy/
* -- process/process2/procfile2-4), which is what broke
* -- nas-librel-image's `-l k` contiguous-run collapse for
* -- argvtest (NOTES-BYE.md carries the full measurement). Fix:
* -- kdisp.s's SYS_BYE slot now names PRC_BYE_STUB (declared
* -- below, always linked, exactly where K_PRODOS_VEC's own
* -- pair already lives) instead of PRC_BYE directly. Only an
* -- image that ACTUALLY wants `bye` (today: playtest.s alone)
* -- calls PRC_BYE_INIT (procbye.s) at boot, mirroring
* -- TIMER_PROBE's own stamp of K_HALT_TMR/K_BYE_ARM, to
* -- overwrite K_BYE_VEC with PRC_BYE's real address. Every
* -- other image leaves entry2.s's default in place and the
* -- call fails loudly (ERR_NOSYS) instead of either linking
* -- procbye.s it never needed or silently doing nothing.
K_BYE_VEC   ds    2
* -- K_BRK_VEC: the user-BRK hook, K_BYE_VEC's own idiom.
* -- KRN_IRQ_ENTRY's :isbrk jumps THROUGH it. entry2.s's
* -- INSTALL_COPY points it at KRN_BRK_TRAP, the halt -- what
* -- every image with no process layer keeps (syscalltest's
* -- own end-of-program BRK parks there) -- and PRC_INIT
* -- (process.s) points it at PRC_BRK_TRAP (procspawn2.s), which
* -- kills the process. Same containment reason: entry2.s is
* -- put by images that link no process module, where a direct
* -- reference would not assemble.
K_BRK_VEC   ds    2
*---------------------------------------------------------------
* KRN_ENTRY -- syscall door's landing point.
*---------------------------------------------------------------
KRN_ENTRY
            tsx                                ;X = process SP
                                               ;(ALTZP still aux
                                               ;-- MUST read the
                                               ;frame before
                                               ;flipping ALTZP)
            lda   FRAME_Y,x                     ;call number
            sta   K_CALLNUM
            lda   FRAME_A,x                      ;parms ptr lo
            sta   K_PARMLO
            lda   FRAME_X,x                      ;parms ptr hi
            sta   K_PARMHI
            stx   K_CALLER_SP
*-- ALTZP is still AUX here, so this lands in the CALLER's own
*-- zero page. A process never issues a syscall from inside an
*-- LC bank bracket (docs/PROCIO.md sec 5, and ProDOS would
*-- reselect its own bank on the way in regardless), so the
*-- bank to restore when this process resumes is the default.
*-- One store, on the hot path, and no read:
*-- docs/LANGUAGE-CARD.md.
            stz   K_LCBANK
            ;-- FIX (root cause of the ECHO round trip never
            ;completing,
            ;-- found by testing): docs/ARCHITECTURE.md's
            ;trapframe
            ;-- contract requires this and it was never
            ;implemented.
            ;-- `JSR $FF00` pushed PCH/PCL as (return_addr - 1)
            ;-- the
            ;-- standard 6502 JSR/RTS convention, where RTS's
            ;own
            ;-- microcode adds the +1 back. EXIT_TAIL uses RTI
            ;for BOTH
            ;-- doors (the whole point of the shared-frame
            ;design), and
            ;-- RTI does NOT add +1 -- it pulls PCH/PCL/P and
            ;jumps
            ;-- exactly there. Without this patch, every syscall
            ;return
            ;-- landed ONE BYTE INTO its own `JSR $FF00`
            ;instruction
            ;-- (the $FF00 operand's high byte, executed as a
            ;stray
            ;-- opcode) instead of the instruction after it --
            ;silently
            ;-- "surviving" simple tests that only checked the
            ;callee
            ;-- side (dispatch succeeding, KRN_EXIT reached)
            ;without
            ;-- ever verifying the CALLER correctly resumed. The
            ;IRQ
            ;-- door needs NO such patch -- hardware pushes the
            ;true
            ;-- resume address directly, already correct for RTI
            ;as-is. --
            inc   FRAME_PCL,x
            bne   :pcdone
            inc   FRAME_PCH,x
:pcdone     sta   ALTZPMAIN                      ;NOW flip ALTZP
                                                 ;-> main (A's
                                                 ;value
                                                 ;irrelevant to
                                                 ;the switch
                                                 ;trigger) -- no
                                                 ;more process-
                                                 ;stack reads
                                                 ;needed
            ldx   #$FF                            ;kernel's own
                                                  ;fixed stack
                                                  ;--
            txs                                    ;the entry-
                                                   ;side hazard
                                                   ;ends HERE:
                                                   ;pushes are
                                                   ;safe from
                                                   ;this
                                                   ;instruction
                                                   ;onward
            ;-- dispatch on call number, TWO RANGES
            ;(docs/SYSCALL.md's
            ;-- mid-flight ProDOS-MLI ruling, item 2): call
            ;numbers below
            ;-- MLI_RANGE_LO are maux PROCESS calls
            ;(spawn/exit/wait/pipe/
            ;-- brk -- K_DISP_LO/HI, 1-based, includer-
            ;supplied, same
            ;-- mechanism as before); call numbers >=
            ;MLI_RANGE_LO are the
            ;-- REAL ProDOS MLI file-call numbers ($C0-$D3),
            ;routed to
            ;-- P8_DELEGATE (task #11's scope to actually
            ;wire up --
            ;-- this file returns a clearly-distinct not-yet-
            ;wired error,
            ;-- never silently falls through to the process-call
            ;table).
            lda   K_CALLNUM
            beq   :baddisp        ;call# 0 invalid -- FIX (found
                                  ;by testing): this must be
                                  ;tested BEFORE the MLI-range
                                  ;CMP below, which clobbers Z
                                  ;testing equality to $65, not
                                  ;0 -- callnum 0 used to fall
                                  ;through to the dispatch table
                                  ;with X=-1 (255), reading far
                                  ;outside K_DISP_LO/HI
            cmp   #MLI_RANGE_LO
            bcs   :mlidisp
            cmp   #K_DISP_COUNT ;FIX (architect review
                                    ;follow-up, found while
                                    ;chasing the ECHO bug): this
                                    ;was missing the `#` --
                                    ;without it, merlin32
                                    ;assembled a MEMORY READ of
                                    ;zero- page address $0003
                                    ;(K_DISP_COUNT's VALUE,
                                    ;3, used as an address since
                                    ;there was no immediate
                                    ;marker), not a compare
                                    ;against the literal 3.
                                    ;$0003 was never initialized
                                    ;(reads 0), so EVERY call
                                    ;number fell through to
                                    ;:baddisp -- no syscall, of
                                    ;any kind, ever reached its
                                    ;real handler in ANY of this
                                    ;task's testing until this
                                    ;fix; the "successful" ARITH
                                    ;runs were actually just
                                    ;reaching KRN_EXIT via
                                    ;the error path
            beq   :dispok
            bcc   :dispok
            bra   :baddisp
:dispok     tax
            dex                                   ;X = 0-based
                                                  ;table index
            lda   K_DISP_LO,x
            sta   K_VEC
            lda   K_DISP_HI,x
            sta   K_VEC+1
            jsr   K_CALL_VEC                       ;-> handler;
                                                   ;RTS returns
                                                   ;here
            jmp   KRN_EXIT
:mlidisp    jsr   P8_DELEGATE
            jmp   KRN_EXIT
:baddisp    lda   #ERR_NOSYS
            sta   K_RESULT
            lda   #1
            sta   K_RESULT_ERR
            jmp   KRN_EXIT
* See K.ENTRY.TXT: "MLIRANGELO the lowest real MLI call"
*---------------------------------------------------------------
* P8_DELEGATE -- task #11's spike proves MLI coexistence (ZP
* footprint, MLIACTV interrupt protocol, IRQ-during-MLI) and
* wires this up for real; task #3 (this file) only reserves the
* dispatch SHAPE. Returns a distinct, unmistakable "not yet
* wired" error so a caller can never confuse it with a real MLI
* failure.
*---------------------------------------------------------------
P8_DELEGATE
            jmp   (K_PRODOS_VEC)
PRODOS_UNWIRE
            lda   #ERR_P8_UNWIRE
            sta   K_RESULT
            lda   #1
            sta   K_RESULT_ERR
            rts
K_PRODOS_VEC ds    2
* -- PRC_BYE_STUB / BYE_UNWIRE -- see the K_BYE_VEC comment
* -- above. Same shape as P8_DELEGATE/PRODOS_UNWIRE immediately
* -- above: an unconditional indirect jump, defaulting (via
* -- entry2.s's INSTALL_COPY) to a stub that fails the call
* -- rather than either linking procbye.s or doing nothing.
PRC_BYE_STUB
            jmp   (K_BYE_VEC)
BYE_UNWIRE  lda   #ERR_NOSYS
            sta   K_RESULT
            lda   #1
            sta   K_RESULT_ERR
            rts
K_CALL_VEC  jmp   (K_VEC)                          ;the "JSR-
                                                   ;indirect"
                                                   ;trick: JSR
                                                   ;K_CALL_VEC
                                                   ;pushes a
                                                   ;return
                                                   ;address
                                                   ;pointing
                                                   ;just past
                                                   ;itself in KE
                                                   ;RNEL_ENTRY;
                                                   ;this JMP
                                                   ;hands
                                                   ;control to
                                                   ;the handler
                                                   ;WITHOUT
                                                   ;touching the
                                                   ;stack again,
                                                   ;so the
                                                   ;handler's
                                                   ;own RTS
                                                   ;returns to
                                                   ;KRN_ENTRY
                                                   ;exactly as
                                                   ;if it had
                                                   ;been JSR'd
                                                   ;directly by
                                                   ;address
*---------------------------------------------------------------
* KRN_EXIT -- shared by every syscall handler's return (via
* KRN_ENTRY's fallthrough) and the bad-call-number path
* above. Patches the return value + carry into the frame, then
* hands off to $FF22 (EXIT_TAIL, identical in every bank).
*---------------------------------------------------------------
KRN_EXIT
            ldx   K_CALLER_SP
            ;-- FIX (idle-merge job-control regression,
            ;docs/JOB-CONTROL.md): a handler that calls
            ;SCH_SWITCH itself (PRC_STOP's cooperative ^Z,
            ;PRC_WAIT_CORE's block) leaves BANKSEL naming the
            ;INCOMING pid by the time we get here. The frame
            ;patch below indexes with K_CALLER_SP (the
            ;OUTGOING/caller's depth) but writes through
            ;whatever bank ALTZPAUX resolves to -- restore
            ;THAT to the caller's own bank first, or the patch
            ;lands in the incoming pid's memory: caller depth
            ;N + FRAME_A's offset can equal incoming depth M +
            ;FRAME_Y's offset for unrelated processes, and the
            ;write silently corrupts the incoming pid's own
            ;saved frame-Y (its call number on retry): a
            ;bogus K_CALLNUM=0 next entry dispatches
            ;ERR_NOSYS instead of the syscall it actually
            ;made -- ^Z's foreground-stop symptom (jctl-e).
            ;
            ;GATED on K_SWITCH (nonzero here iff a handler's
            ;own SCH_SWITCH really ran -- its tail is the only
            ;writer of a nonzero K_SWITCH, and nothing clears
            ;it before this read), and the lookup itself is
            ;LAZY, done here rather than snapshotted at
            ;KRN_ENTRY: an entry-time snapshot cost two extra
            ;instructions on EVERY syscall, unswitched or not,
            ;which shifted the interrupt-nesting window enough
            ;to turn KRN_IRQ_ENTRY's own documented ServeMouse
            ;re-entrancy hazard (this file's "RIG FINDING",
            ;below) into a deterministic FRAME_A corruption
            ;under one build layout (check-iobuf's "duplicate"
            ;case) -- found by bisection, not reasoning: b504f10
            ;alone and the posix-sed utilities alone were each
            ;green, only the combination went red, and replacing
            ;the two-instruction snapshot with two NOPs turned
            ;it green again. This version touches NOTHING on
            ;the ordinary, unswitched path -- it is byte-for-
            ;byte what it was before this whole fix -- so it
            ;cannot perturb that window. A spike with no
            ;scheduler at all (src/test/syscalltest.s,
            ;bankcopytest.s) never sets K_SWITCH either (no
            ;SCH_SWITCH to write it), so it never takes this
            ;branch and never needs the lookup below to
            ;resolve against anything IT lacks.
            lda   K_SWITCH
            beq   :samebank
            ;-- K_SW_OUTPID (sched.equ) is the CALLER whenever
            ;a switch ran: SCH_SWITCH's own first act is
            ;"lda K_CURPID; sta K_SW_OUTPID", before it ever
            ;picks an incoming pid, and PRC_STOP/PRC_WAIT_CORE
            ;each call SCH_SWITCH exactly once, on themselves --
            ;out == caller for both. Look up ITS PCB_BANK the
            ;same way SCH_SWITCH's own :cancel path already
            ;does (sched.s), inlined here rather than jsr'd:
            ;PCB_PTR_FOR/PCB_RD_FIELDS/K_PCB_SCRATCH are
            ;sched.s-only and this file's two schedulerless
            ;spikes never put it.
            lda   K_SW_OUTPID
            sta   K_PCB_PTR
            stz   K_PCB_PTR+1
            asl   K_PCB_PTR
            rol   K_PCB_PTR+1
            asl   K_PCB_PTR
            rol   K_PCB_PTR+1
            asl   K_PCB_PTR
            rol   K_PCB_PTR+1
            asl   K_PCB_PTR
            rol   K_PCB_PTR+1
            clc
            lda   K_PCB_PTR
            adc   #<ANNEX_STRCT_A
            sta   K_PCB_PTR
            lda   K_PCB_PTR+1
            adc   #>ANNEX_STRCT_A
            sta   K_PCB_PTR+1
            stz   BANKSEL                        ;annex read
            clc
            lda   K_PCB_PTR
            adc   #PCB_BANK
            sta   K_CPY_PROC
            lda   K_PCB_PTR+1
            adc   #0
            sta   K_CPY_PROC+1
            lda   #<K_OUTBANK
            sta   K_CPY_MAIN
            lda   #>K_OUTBANK
            sta   K_CPY_MAIN+1
            lda   #1
            sta   K_CPY_LEN
            jsr   COPYIN_ENTRY
            lda   K_OUTBANK
            sta   BANKSEL
:samebank
            ;-- FIX (same bug class as the copyin/copyout
            ;finding, and
            ;-- the KRN_ENTRY frame-read ordering this file
            ;already
            ;-- got right elsewhere -- found by testing, missed
            ;here):
            ;-- K_RESULT/K_RESULT_ERR are ZERO PAGE, so they're
            ;ALTZP-
            ;-- governed. Every handler writes them while
            ;ALTZP=main
            ;-- (the kernel's whole operating posture). The
            ;ORIGINAL
            ;-- code here read them AFTER `STA ALTZPAUX` below
            ;-- by
            ;-- then ALTZP=aux, so the reads silently hit the
            ;PROCESS's
            ;-- zero page instead, always getting stale/zero
            ;data
            ;-- (K_RESULT=0, K_RESULT_ERR=0) regardless of what
            ;the
            ;-- handler actually computed. Cache both in
            ;registers
            ;-- BEFORE the flip instead -- A survives the
            ;switch-trigger
            ;-- STA below untouched (STA doesn't modify A), and
            ;Y holds
            ;-- K_RESULT_ERR for a register test instead of a
            ;second
            ;-- (now-also-wrong) post-flip zero-page read.
            lda   K_RESULT                         ;cache BEFORE
                                                   ;the flip
            ldy   K_RESULT_ERR                      ;ditto
            sta   ALTZPAUX                        ;ALTZP -> aux
                                                  ;-- CRITICAL
                                                  ;SECTION
                                                  ;BEGINS: no
                                                  ;pushes until
                                                  ;the final TXS
                                                  ;below
                                                  ;(ordinary
                                                  ;STA/LDA via
                                                  ;absolute,X do
                                                  ;NOT move SP,
                                                  ;so they're
                                                  ;safe in this
                                                  ;window;
                                                  ;PHA/JSR/PLA
                                                  ;are not)
* XBANK(stack): patching the RETURNING process's trapframe,
* in its
* own stack page. K_RESULT/K_RESULT_ERR were cached into A/Y
* above precisely because they could NOT be read here.
            sta   FRAME_A,x                        ;patch return
                                                   ;value (A =
                                                   ;the cached
                                                   ;K_RESULT --
                                                   ;STA above
                                                   ;didn't touch
                                                   ;it)
            lda   FRAME_P,x
            and   #$FE            ;clear carry bit, leave every
                                  ;OTHER flag (incl. D) exactly
                                  ;as the caller had it
            cpy   #0              ;test the CACHED Y, not a
            beq   :setcarry       ;fresh (now-wrong) ZP read
            ora   #$01            ;failure -> carry set
:setcarry   sta   FRAME_P,x
            ;-- TASK #6 LANDING:
            ;K_SWITCH/K_TARGETBANK/K_TARGETSP are
            ;-- ordinary main memory (see the ds block above) --
            ;safe to
            ;-- read here even though ALTZP=aux already (only
            ;ALTZP moved,
            ;-- RAMRD/RAMWRT are still main). docs/SCHED.md's
            ;extended
            ;-- argument covers this window: X still addresses
            ;the
            ;-- OUTGOING/caller's own frame above (the patch
            ;just applied
            ;-- is always correct for whichever process this
            ;WAS,
            ;-- regardless of who resumes next) -- switching
            ;banks changes
            ;-- only which process's SP loads into the real 6502
            ;S
            ;-- register, not anything already written. --
            lda   K_SWITCH
            beq   :noswitch
            stz   K_SWITCH        ;one-shot: sched.s re-arms it
                                  ;next switch
            lda   K_TARGETBANK
            sta   BANKSEL         ;$C073 = INCOMING pid's bank
                                  ;-- still inside the no-pushes
                                  ;critical section (I/O write,
                                  ;not a stack op)
* XBANK(zp): reading the INCOMING process's own K_LCBANK is
* precisely the job -- it is per-process storage BECAUSE it
* lives in the process's zero page (inc/entry.frame.equ).
*-- Page 1 and zero page already resolve to the INCOMING bank
*-- (ALTZP flipped above, BANKSEL just changed), so this reads
*-- the incoming process's OWN saved bank. Reads only -- no
*-- pushes -- so the critical section is undisturbed.
            lda   K_LCBANK
            bmi   :lcaltx
            lda   LCBANK2_RAM
            bra   :lcselx
:lcaltx     lda   LCBANK1_RAM
:lcselx     ldx   K_TARGETSP
            txs                   ;**critical section ends
                                  ;here** -- SP = INCOMING's
                                  ;saved SP; page 1 now resolves
                                  ;to INCOMING's bank (BANKSEL
                                  ;just changed)
            jmp   $FF22           ;EXIT_TAIL resumes the
                                  ;INCOMING process's OWN
                                  ;trapframe
:noswitch   ;-- $C073 intentionally NOT written here -- see file
            ;header's -- SCOPE NOTE: same bank that entered,
            ;exactly task #3's -- original behavior. --
            txs                   ;**the exit-critical TXS** SP
                                  ;= process's captured value;
                                  ;page 1 is ALREADY the
                                  ;process's own (ALTZP flipped
                                  ;above, untouched since) --
                                  ;critical section ends here
            jmp   $FF22           ;EXIT_TAIL (fixed address,
                                  ;every bank identical)
*---------------------------------------------------------------
* KRN_IRQ_ENTRY -- IRQ door's landing point. Shares the
* hardware $FFFE vector with BRK (6502/65C02 architecture) --
* discrimination via the stacked B flag happens here, not in the
* $FFxx stub.
* WHICH BRK GETS HERE: only one taken with ALTZP=aux. The CPU
* fetches $FFFE from whichever language card ALTZP selects, and
* main's own card has its own vector (timer.s MAIN_IRQ_SHIM,
* which parks a main-context BRK -- "a kernel bug, park it
* visibly"). So a BRK in the kernel, mid-syscall or in tick
* time, does not reach this door; a BRK that does is the running
* process's own and goes through K_BRK_VEC. MEASURED, KBRK
* notes sec 1. ONE ACCEPTED GAP: main-resident kernel code that
* runs with ALTZP=aux -- PRC_RWND_FRM (procspawn.s), FRK_CLN_ZP
* and FRK_CLN_STK (procfork.s), the frame stamps in procspawn3.s
* and procbye.s -- reaches this door with a BRK from a corrupted
* kernel byte, and K_BRK_VEC then kills K_CURPID mid-syscall
* instead of halting (KBRK notes sec 1b).
*---------------------------------------------------------------
* RIG FINDING (docs/SYSCALL.md has the full writeup -- recorded
* here as a known, DEFERRED hazard rather than a completed fix):
* this task's own interrupt-safety argument assumes
* SEI/hardware-I=1 covers the ENTIRE kernel critical section, so
* a second IRQ can never land while one is already being
* serviced. Testing against verilogapple's AppleMouse firmware
* surfaced behavior consistent with that assumption being
* violated by CALLED FIRMWARE (ServeMouse's ROM routine appears
* to re-enable interrupts internally as part of its own PIA
* handshake) -- see docs/SYSCALL.md's "rig finding" section for
* the full writeup and the reentrant depth-indexed design this
* comment describes. A first attempt at a fix (a K_IRQ_NEST-
* guarded, depth-indexed K_CALLER_SP array) is specified in
* docs/SYSCALL.md but is NOT landed in this file -- it did not
* converge within this task's time budget and risked introducing
* a second, less-understood bug on top of the first. Landing it
* (or an equivalent) is flagged as follow-up work, not silently
* dropped. This entry point currently keeps the SIMPLE, spec-
* matching "always reset SP to $FF" discipline, which is CORRECT
* as long as no firmware invoked from KRN_IRQ_SVC's hook
* ever re-enables interrupts -- true for any handler that itself
* never CLIs, which is the case for kernel-owned device drivers;
* it is NOT true for the real AppleMouse ROM's ServeMouse, a
* known, documented exception.
KRN_IRQ_ENTRY
            tsx
            stx   K_CALLER_SP
*-- The bank, captured into the INTERRUPTED process's own zero
*-- page while ALTZP is still aux. This door is the only way a
*-- process can lose the CPU from inside an LC bank bracket, so
*-- it is the only place the live value can still be read.
            lda   RDLCBNK2
            sta   K_LCBANK
            lda   FRAME_P,x
            and   #$10            ;B flag = bit 4
            sta   K_ISBRK         ;nonzero = BRK, zero = real
                                  ;hardware IRQ
            sta   ALTZPMAIN       ;(A = the AND result --
                                  ;irrelevant to the switch
                                  ;trigger)
            ldx   #$FF
            txs
*-- A BRANCH CANNOT TARGET AN EXTERNAL under REL: the assembler
*-- refuses it outright ("Bad external in line"), because a
*-- relative displacement cannot be relocated to an address the
*-- LINKER picks. KRN_IRQ_SVC lives in entry2.s, so in the
*-- monolithic build this was a short forward branch into the
*-- next put file and in a REL build it is an external. Inverted
*-- and jumped, which costs 3 bytes and is the only shape that
*-- works in both.
            lda   K_ISBRK
            bne   :isbrk
            jmp   KRN_IRQ_SVC
:isbrk      jmp   (K_BRK_VEC)     ;PRC_BRK_TRAP or the halt
*---------------------------------------------------------------
* KRN_IRQ_SVC -- real hardware IRQ (mouse VBL in this
* task's test rig; any boot-probed timer source in the real
* kernel, task #6). No call-number dispatch, no return-value
* patch -- an IRQ is asynchronous, it resumes the interrupted
* frame exactly as found. Device servicing is delegated through
* K_IRQ_HOOK (an includer-supplied JMP-indirect vector) so this
* generic module stays hardware-agnostic -- task #6 owns what
* the hook actually points at.
*---------------------------------------------------------------