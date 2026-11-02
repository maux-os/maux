*---------------------------------------------------------------
* procspawn.s -- Process spawn: blocking, memory access,
* argv staging.
* Split out of process.s 2026-08-16 so each kernel module fits
* real Merlin's 41215-byte source buffer
* (learning:01M051EM2HQ3ZVJTR1W9P3G86J). The top-level image
* PUTs each module in order; Merlin-8 cannot nest PUT.
* Full design notes: K.PROCESS.TXT (docs/a2/)
*---------------------------------------------------------------


* Split from process.s: the spawn path and the helpers only it
* uses. PRC_BLCK_RTRY rewinds a suspended PC to the JSR so a
* blocked syscall re-runs on wake.
* Blocking support. PRC_BLCK_RTRY changes the suspended
* process PC from "after JSR $FF00" back to the JSR opcode and
* arranges KRN_EXIT to restore A to the original parameter
* low byte. X/Y are already untouched in the frame. The process
* re-enters the syscall after wakeup without seeing a transient
* return.
*---------------------------------------------------------------
PRC_BLCK_RTRY
            sta   P_CHAN
*-- THE ONE ERR_INTR DELIVERY POINT (docs/SIGNALS.md sec 2):
*-- every blocking syscall blocks by retry through here, so a
*-- held (caught) signal fails the call out ONCE, right where
*-- it would otherwise sleep. A signal that lands mid-sleep
*-- wakes the target (PRC_SIG_SND); the rewound PC re-runs the
*-- whole syscall; no data; this check fires on the way back in.
            jsr   PRC_SIG_TST
            bcc   :nosig
            lda   #ERR_INTR
            jsr   PRC_FAIL_A
            rts
:nosig      jsr   PRC_RWND_FRM
            lda   P_CHAN
            jsr   SCH_SLEEP
            lda   K_PARMLO
            sta   K_RESULT
            stz   K_RESULT_ERR
            rts

PRC_RWND_FRM
            jsr   PRC_SEL_CRBNK
            ldx   K_CALLER_SP
            sta   ALTZPAUX
* XBANK(stack): rewinding the CALLER's saved PC, in its own
* stack page.
            sec
            lda   FRAME_PCL,x
            sbc   #3
            sta   FRAME_PCL,x
            lda   FRAME_PCH,x
            sbc   #0
            sta   FRAME_PCH,x
            sta   ALTZPMAIN
            rts

PPP_REQ_LIMIT
            lda   PRC_PARM+MLI_REQHI
            beq   :lo
            lda   #$FF
            sta   P_COUNT
            rts
:lo         lda   PRC_PARM+MLI_REQLO
            sta   P_COUNT
            rts

*---------------------------------------------------------------
* Memory access helpers.
*---------------------------------------------------------------
PCPI_CALLPARM
            sta   P_COUNT
            jsr   PRC_SEL_CRBNK
            lda   K_PARMLO
            sta   K_CPY_PROC
            lda   K_PARMHI
            sta   K_CPY_PROC+1
            lda   #<PRC_PARM
            sta   K_CPY_MAIN
            lda   #>PRC_PARM
            sta   K_CPY_MAIN+1
            lda   P_COUNT
            sta   K_CPY_LEN
            jsr   COPYIN_ENTRY
            lda   K_CPY_ERR
            beq   :ok
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            sec
            rts
:ok         clc
            rts

*-- COPIES TWO BYTES since 2026-08-26, so callers can tell a
*-- one-character path from one that merely STARTS with that
*-- character -- see the builtin lookup in process.s for the
*-- crash that distinction prevents. Safe for any valid C
*-- string of length >= 1: the byte after the first is either
*-- more path or the NUL.
PRDPAR_BYTE
            jsr   PRC_SEL_CRBNK
            lda   P_PTR1
            sta   K_CPY_PROC
            lda   P_PTR1+1
            sta   K_CPY_PROC+1
            lda   #<PRC_BYTE
            sta   K_CPY_MAIN
            lda   #>PRC_BYTE
            sta   K_CPY_MAIN+1
            lda   #2
            sta   K_CPY_LEN
            jsr   COPYIN_ENTRY
            lda   K_CPY_ERR
            beq   :ok
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            sec
            rts
:ok         clc
            rts

PWRPAR_BYTE
            jsr   PRC_SEL_CRBNK
            lda   P_PTR1
            sta   K_CPY_PROC
            lda   P_PTR1+1
            sta   K_CPY_PROC+1
            lda   #<PRC_BYTE
            sta   K_CPY_MAIN
            lda   #>PRC_BYTE
            sta   K_CPY_MAIN+1
            lda   #1
            sta   K_CPY_LEN
            jsr   COPYOUT_ENTRY
            lda   K_CPY_ERR
            beq   :ok
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            sec
            rts
:ok         clc
            rts

PCPO_MLIPARM
            lda   #8
PCPO_PARM_LEN
            sta   P_COUNT
            jsr   PRC_SEL_CRBNK
            lda   K_PARMLO
            sta   K_CPY_PROC
            lda   K_PARMHI
            sta   K_CPY_PROC+1
            lda   #<PRC_PARM
            sta   K_CPY_MAIN
            lda   #>PRC_PARM
            sta   K_CPY_MAIN+1
            lda   P_COUNT
            sta   K_CPY_LEN
            jsr   COPYOUT_ENTRY
            lda   K_CPY_ERR
            beq   :ok
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:ok         stz   K_RESULT
            stz   K_RESULT_ERR
            rts

* PRC_SEL_CRBNK -- $C073 = the running process's bank; A = that
* bank on return. X/Y and every K_PCB_*/K_CPY_* cell PRESERVED.
*
* Was a PCB read (PCB_PTR_FOR + a 1-byte COPYIN of PCB_BANK):
* 203 cycles, measured 2026-09-03, on ~30 call sites -- every
* syscall parm copy and, worst, every native-80 aux-window close
* (80% of the 260-cycle bracket, CONSOLE-OPT.md sec 6). The bank
* of record cannot change under a running pid (PCB_BANK is
* written only by SCH_CREATE), so sched.s shadows it into
* K_CURBANK at the two places it stores K_CURPID, and this is a
* load. learning:01M1JNVYS4E6K0DX5CCSJYD5GE.
*
* CONTRACT CHANGE for callers: K_PCB_SCRATCH no longer holds
* the bank afterwards -- the two readers that depended on that
* (procfork.s FRK_SRCBNK, procspawn3.s PRC_PAR_BANK) take A.
PRC_SEL_CRBNK
            lda   K_CURBANK
            sta   BANKSEL
            rts

*---------------------------------------------------------------
* Spawn helpers.
*---------------------------------------------------------------
* -- docs/STICKY.md sec 25's three-way preference, in order:
* -- (1) a bank already TAGGED with the program being spawned
* -- (LZ_WANT says one is wanted and PRC_PATHBUF names it) --
* -- that bank's text IS the program, so the whole load is
* -- skipped; (2) any genuinely free bank; (3) the least-
* -- recently-retained tagged bank, reclaimed. Step 3 is
* -- "processes always win" (sec 3), unchanged in meaning from
* -- the cache's surrender protocol and much smaller: one
* -- allocator, no negotiation. Nothing retained either = a
* -- genuine ERR_NOMEM, exactly the pre-cache behavior.
PRC_ALLC_BANK
            stz   LZ_WARM
            lda   LZ_WANT
            beq   :nowarm
            stz   LZ_WANT              ;one-shot -- a direct
                                       ;caller can never inherit
            jsr   LZ_TRY_WARM          ;a stale preference
            bcc   :out
:nowarm     lda   PRC_FREE_CNT
            bne   :have
            jsr   LZ_RECLAIM
            bcc   :have
            lda   #ERR_NOMEM
            jsr   PRC_FAIL_A
            sec
            rts
:have       dec   PRC_FREE_CNT
            ldx   PRC_FREE_CNT
            lda   PRC_FREE_LIST,x
            clc
:out        rts

* -- LAZY FREE (sec 25). A bank carrying a LIVE tag is not
* -- freed at all: LZ_RETAIN marks it HELD, stamps it, and
* -- returns carry clear, and this routine returns without
* -- touching the free list. Everything else -- an untagged
* -- bank, a builtin-image spawn, a bank whose load failed
* -- before it was ever tagged -- falls through to the plain
* -- push this routine has always been.
PRC_FREE_BANK
            jsr   LZ_RETAIN
            bcs   PRC_PUSH_BANK
            rts

* -- the raw push, split out under its own GLOBAL name because
* -- lazyfree.s needs it too (a reclaimed or invalidated bank
* -- goes back on the list) and a local label cannot cross a
* -- module boundary.
PRC_PUSH_BANK
            ldx   PRC_FREE_CNT
            sta   PRC_FREE_LIST,x
            inc   PRC_FREE_CNT
            rts

*---------------------------------------------------------------
* PRC_ZERO_PG -- the same sec-21 page for the loaders that
* CANNOT fuse it into their last copy: the file loader moves
* the image in read-sized chunks and does not know which chunk
* is last until the read after it comes back empty, and a warm
* respawn runs no copy here at all (the image is already in the
* bank -- that is where it ran). One zero-length BankCopyZ: no
* bytes move, one $C073 window opens, 256 bytes are zeroed.
* This is the ONE thing a warm respawn still has to do to the
* child's memory (docs/STICKY.md sec 25).
*
* The page address is computed, not remembered -- LOAD_BASE
* (ratified $0800) plus the image length the kernel already
* holds. That is the whole of sec 21's "no metadata".
*---------------------------------------------------------------
PRC_ZERO_PG
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   PRC_CHLD_BANK
            sta   K_BC_DSTBANK
            clc
            lda   PRC_LOADADR
            adc   PRC_IMAGE_LEN
            sta   K_BC_DSTADDR
            lda   PRC_LOADADR+1
            adc   PRC_IMAGE_LEN+1
            sta   K_BC_DSTADDR+1
            stz   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopyZ
            rts
