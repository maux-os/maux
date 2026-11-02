*---------------------------------------------------------------
* procfork.s -- fork(): the bank-clone primitive and the fork
* syscall (SYS_FORK = 8, inc/sc.proc.equ;
* docs/ARCHITECTURE.md's "fork() [v2]" bullet; docs/SYSCALL.md
* item 11 for the frame shape; docs/PLAN.md Wave 6 item 3 for
* the 2026-08-23 copy-the-text ruling; docs/FORK.md).
*
* Its own module, not more of process.s: that file is 29,343
* bytes against real Merlin's 41,215-byte source buffer, which
* check-dual enforces (learning:01M051EM2HQ3ZVJTR1W9P3G86J).
* src/kernel/lazyfree.s is the precedent.
*
* TWO LAYERS, exactly as ARCHITECTURE.md rules them.
*
*   1. THE BANK-CLONE PRIMITIVE -- FRK_CLN_ZP + FRK_CLN_STK +
*      FRK_CLN_IMG. Zero page (256B), the stack page (256B),
*      and [PRC_LOWFREE, PCB_BRK*256). Nothing else. The image
*      copy is a CALLER of BankCopy (39.07 cyc/byte, measured,
*      docs/PROCIO.md), never a second copy loop; the two low
*      pages cannot use it at all, for the reason below.
*
*   2. THE FORK SYSCALL -- PRC_FORK. Allocates the bank, stamps
*      $FFxx, runs the primitive, then patches the CHILD's
*      trapframe so parent and child differ only in frame-A and
*      frame-P's carry, and duplicates the PCB's resources
*      (cwd, open files, pid/bank map, break).
*
* WHY THE TWO LOW PAGES CANNOT GO THROUGH BankCopy. Page 0 and
* page 1 are ALTZP-governed, and ALTZP is the one switch
* RAMRD/RAMWRT cannot stand in for
* (learning:01KW1GTYGVYAPQRGS5P7J66RWD: "ZP is ALTZP-governed,
* the one RAM the bracket cannot steal"). COPYIN_ENTRY flips
* RAMRD and reads (K_CPY_PROC),y -- with ALTZP still main that
* reads the KERNEL's own zero page and the KERNEL's own stack,
* whatever bank $C073 has selected, and it would do so
* silently. So the two pages a fork most needs are exactly the
* two the house primitive cannot reach, and they get the
* hand-rolled ALTZP window in FRK_CLN_ZP/FRK_CLN_STK instead.
*
* THE 80STORE BRACKET IS BankCopy'S, AND IT IS LOAD-BEARING
* HERE. With 80STORE set, RAMRD/RAMWRT are IGNORED for
* $0400-$07FF and -- with HIRES also set -- for $2000-$3FFF;
* PAGE2 alone routes those pages
* (learning:01KW1GTYHGXMBZNR6DMQB2F712, the learning that
* corrected this project's fork() design from first
* principles). Since the copy starts at PRC_LOWFREE ($0200),
* BOTH windows are inside every extent: $0400-$07FF always,
* $2000-$3FFF in every non-trivial one -- and both the read
* and the write land in MAIN when the bracket is missing.
* Because BankCopy advances source and destination in lockstep
* from the same base, an unbracketed copy of those windows is
* a main->main copy onto itself: no crash, no corruption, and
* a child whose pages simply never arrive. That is precisely
* the silent shape the commons warns about, and check-fork's
* 80STORE phase exists to see it.
*
* LC RAM IS NOT PRESERVED ACROSS fork. Settled ABI
* (docs/ARCHITECTURE.md cold-read Q3-2, docs/MEMMAP.md 3.2):
* the child gets a FRESH $FFxx stamp and UNDEFINED contents in
* $D000-$FEFF, both $D000 banks. A process that needs data to
* survive a fork keeps it below the break. This is not an
* oversight to be improved later -- 16,128 bytes of LC storage
* would more than double fork's cost for a region no caller in
* this tree uses.
*
* $0200-$07FF IS COPIED (widened 2026-08-23, the S1b wiring).
* The first cut stopped at LOAD_BASE, which left the argv/env
* block (docs/MEMMAP.md 3.2a) holding whatever the child's
* bank held before -- while GETARG and GETENV read that block
* LAZILY on every call, and docs/SYSCALL.md item 13c already
* promised "a forked child shares the parent's block by
* construction". So the extent is [PRC_LOWFREE, brk): 1536
* more bytes, ~59k cycles (~0.06s) per fork, and getenv/argv
* survive the fork as the ABI says they do. See docs/FORK.md.
*
* THE COPY IS NON-PREEMPTIBLE and drops VBL ticks. The syscall
* door sets I and nothing clears it (BankCopy's per-window
* php/sei/plp restores the masked state it found), so a fork of
* a sh-sized extent masks interrupts for ~0.65 s at 1 MHz and
* the clock skews by that much. Accepted, documented v1 tradeoff
* (ARCHITECTURE.md); a restartable copy with yield points is
* the later fix and is deliberately NOT built here.
*---------------------------------------------------------------


*---------------------------------------------------------------
* Module state. Ordinary main memory (`ds`), never zero page:
* nothing here is read from inside a RAMRD/RAMWRT=aux bracket,
* which is exactly what makes plain absolute addresses safe --
* the same idiom and the same argument as entry.s's
* K_CALLER_SP and lazyfree.s's whole table set.
*---------------------------------------------------------------
FRK_SRCBNK  ds    1           ;parent's physical aux bank
FRK_DSTBNK  ds    1           ;child's, from PRC_ALLC_BANK
FRK_ENDPG   ds    1           ;EXCLUSIVE end page of the copy --
                              ;PCB_BRK, or >PRC_BRK_LIM when the
                              ;parent never declared one
FRK_BRKPG   ds    1           ;parent's PCB_BRK verbatim, which
                              ;the child inherits (0 included)
FRK_SP      ds    1           ;parent's K_CALLER_SP -- the
                              ;child's saved SP too, because its
                              ;stack page is a byte copy

*---------------------------------------------------------------
* FRK_CLN_ZP -- the parent bank's zero page ($0000-$00FF) into
* the child's, staged through K_BOUNCEBUF.
*
* K_BOUNCEBUF IS BankCopy's bank<->bank staging page, borrowed
* rather than duplicated. Its own header says nothing external
* names it; this is now the one exception, and it is safe by
* construction -- no BankCopy call is in flight while these two
* windows run, and the whole point of that page is bank-to-bank
* staging, which is what this is. The alternative was a second
* emitted 256-byte `ds` for a buffer that already exists.
*
* absolute,Y ADDRESSING IS THE MECHANISM. `lda PRC_ZP,y` is
* absolute,Y -- neither LDA nor STA has a zp,Y mode at all, so
* both assemblers MUST emit the 3-byte form (verified: merlin32
* emits B9 00 00 / 99 00 00). The access then lands in page 0
* of whichever zero page ALTZP selects. A (zp),y pointer is
* impossible here for the obvious reason: the pointer would
* live in the page being copied.
*
* NO PUSHES INSIDE THE WINDOW. While ALTZP=aux the hardware
* stack IS the process's own page 1, so any PHA/JSR/PLA between
* the flips would scribble the very frame this fork exists to
* copy. PHP/SEI happen before the first flip and PLP after the
* last, the same critical-section discipline KRN_EXIT keeps
* between its ALTZP flip and its TXS.
*
* NO 80STORE BRACKET, deliberately: 80STORE governs $0400-$07FF
* and (with HIRES) $2000-$3FFF, and neither page 0 nor page 1
* is in either window. The bracket fork DOES need is BankCopy's
* own, around FRK_CLN_IMG below.
*---------------------------------------------------------------
FRK_CLN_ZP  php
            sei
            lda   FRK_SRCBNK
            sta   BANKSEL
            sta   ALTZPAUX
* XBANK(zp): reading the PARENT's zero page IS the job.
            ldy   #0
:rd         lda   PRC_ZP,y             ;parent's ZP (ALTZP=aux)
            sta   K_BOUNCEBUF,y        ;main -- RAMWRT is main,
            iny                        ;and ALTZP does not reach
            bne   :rd                  ;past $01FF
            sta   ALTZPMAIN
            lda   FRK_DSTBNK
            sta   BANKSEL
            sta   ALTZPAUX
            ldy   #0
:wr         lda   K_BOUNCEBUF,y
            sta   PRC_ZP,y             ;child's ZP
            iny
            bne   :wr
            sta   ALTZPMAIN
            plp
            rts

*---------------------------------------------------------------
* FRK_CLN_STK -- the stack page ($0100-$01FF), same window, same
* rules. Two routines rather than one parameterised by page,
* because the page number is baked into an absolute operand and
* patching it would be self-modifying code -- the one thing this
* tree is removing (see bankcopy.s's BC_ZFILL for the same
* refusal).
*
* THIS IS WHAT CARRIES THE TRAPFRAME. The child's 6-byte
* [PCH][PCL][P][A][X][Y] frame is not synthesised anywhere: it
* arrives as part of this page, already holding the PC that
* KRN_ENTRY incremented past the parent's `jsr $FF00`, and
* FRK_PTCH_FRM below changes exactly two bytes of it.
*---------------------------------------------------------------
FRK_CLN_STK php
            sei
            lda   FRK_SRCBNK
            sta   BANKSEL
            sta   ALTZPAUX
* XBANK(stack): reading the PARENT's stack page IS the job.
            ldy   #0
:rd         lda   PRC_STACK,y
            sta   K_BOUNCEBUF,y
            iny
            bne   :rd
            sta   ALTZPMAIN
            lda   FRK_DSTBNK
            sta   BANKSEL
            sta   ALTZPAUX
            ldy   #0
:wr         lda   K_BOUNCEBUF,y
            sta   PRC_STACK,y
            iny
            bne   :wr
            sta   ALTZPMAIN
            plp
            rts

*---------------------------------------------------------------
* FRK_CLN_IMG -- [PRC_LOWFREE, FRK_ENDPG*256), bank to bank,
* through BankCopy: the 80STORE bracket, the $C073 windows, the
* bounce staging and the chunking are all its, not this
* module's. Returns BankCopy's own K_BC_ERR.
*
* THE BASE IS PRC_LOWFREE ($0200), NOT LOAD_BASE (widened
* 2026-08-23): the argv/env block lives at $0200-$07FF and
* GETARG/GETENV read it lazily for the process's whole life,
* so it must cross the fork -- see the module header.
*
* THE LENGTH IS PAGE-GRANULAR BY CONSTRUCTION. PCB_BRK is a
* page number and PRC_LOWFREE's low byte is zero, so the byte
* count is (FRK_ENDPG - $02) << 8 -- a single subtraction into
* the HIGH byte, with the low byte a constant zero. That is the
* whole reason PRC_BRK rounds every request up to a page.
*
* THE SMALLEST LEGAL COPY IS THE LOW WINDOW ALONE. A process
* whose break is $0800 has declared that it owns nothing above
* the stack, so fork copies $0200-$07FF -- argv included --
* and nothing else, its text included. That follows from
* docs/MEMMAP.md 3.2b's floor rule ("only the program knows
* its own last symbol"): a program that wants a working fork
* must set its break at or above its own end of image, exactly
* as it must before calling sbrk. The kernel cannot check it
* -- for a fork there is no file and no image length to check
* against.
*---------------------------------------------------------------
FRK_CLN_IMG
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            lda   #<PRC_LOWFREE
            sta   K_BC_SRCADDR
            lda   #>PRC_LOWFREE
            sta   K_BC_SRCADDR+1
            lda   FRK_SRCBNK
            sta   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   #<PRC_LOWFREE
            sta   K_BC_DSTADDR
            lda   #>PRC_LOWFREE
            sta   K_BC_DSTADDR+1
            lda   FRK_DSTBNK
            sta   K_BC_DSTBANK
            stz   K_BC_LEN
            lda   FRK_ENDPG
            sec
            sbc   #>PRC_LOWFREE
            sta   K_BC_LEN+1
            jmp   BankCopy

*---------------------------------------------------------------
* FRK_PTCH_FRM -- the two bytes that make one call return twice.
*
* The child's frame is a byte copy of the parent's, so on entry
* here the two processes are identical in every register the
* trapframe carries. docs/SYSCALL.md 1 puts frame-A at
* $0103,SP and frame-P at $0104,SP; KRN_EXIT patches the
* PARENT's pair on the way out (K_RESULT = the child's pid,
* K_RESULT_ERR = 0 -> carry clear), and this patches the
* CHILD's to 0 and carry clear. Nothing else in either frame
* differs -- same PC, same X, same Y, same flags but the carry.
*
* WHY THE CHILD'S A MUST BE WRITTEN AND NOT LEFT. At the moment
* FRK_CLN_STK ran, the parent's frame-A still held the syscall
* ARGUMENT (the parms-pointer low byte, item 1's register
* transport) -- KRN_EXIT has not patched it yet and will not
* until this handler returns. So an unpatched child would
* return that argument byte and read as a parent.
*
* SP DISCIPLINE: FRK_SP is read BEFORE the ALTZP flip. It is
* ordinary main memory rather than zero page precisely so that
* ordering is a matter of taste and not of correctness -- but
* the tree has already paid four times for the mirror mistake
* (docs/SYSCALL.md 7.7, sched.s SCH_START's own note), so this
* reads it early anyway.
*---------------------------------------------------------------
FRK_PTCH_FRM
            php
            sei
            ldx   FRK_SP
            lda   FRK_DSTBNK
            sta   BANKSEL
            sta   ALTZPAUX
* XBANK(stack): patching the CHILD's trapframe, in its own
* stack page.
            lda   #0
            sta   FRAME_A,x            ;child's fork() returns 0
            lda   FRAME_P,x
            and   #$FE                 ;carry CLEAR = success,
            sta   FRAME_P,x            ;every other flag as the
            sta   ALTZPMAIN            ;caller had it, D too
            plp
            rts

*---------------------------------------------------------------
* FRK_DUP_FDS -- the child's fd TABLE is a private copy of the
* parent's; the OBJECTS it names are SHARED.
*
* That is the whole of Unix fd inheritance and it is already
* built: PCB_FDTABLE holds OFT indices (or FD_DEV_BASE+ device
* handles), and procfd2.s's PRC_INC_OBJ_A is the exact inverse
* of the PRC_DEC_OBJ that PCLS_ONE_FD runs at close/exit. So
* duplication is a copy of eight bytes plus one increment per
* live entry, and the four counters procfd2.s's own pipe-slot
* comment names (OFT_REFCNT, PIPE_RREFS, PIPE_WREFS, and
* PIPE_USED which is derived from the other two) stay
* consistent for free:
*
*   OFT_FILE       OFT_REFCNT+1. Both processes share one
*                  ProDOS refnum and one io_buffer, so they
*                  share a file MARK -- V7 semantics. The
*                  refnum is closed when the LAST fd naming it
*                  closes, not the first.
*   OFT_PIPE_R     OFT_REFCNT+1 and PIPE_RREFS+1. The +1 on
*                  RREFS is what keeps a pipe from reporting
*                  EOF while the child still holds a read end.
*   OFT_PIPE_W     OFT_REFCNT+1 and PIPE_WREFS+1. Symmetrically,
*                  a reader blocks instead of seeing EOF until
*                  BOTH write ends close -- the classic bug this
*                  gets wrong is a shell that forgets its own
*                  copy of the write end.
*   FD_DEV_BASE+   NOT refcounted at all. PRC_INC_OBJ_A returns
*                  immediately on a device handle, matching
*                  PCLS_ONE_FD, which skips PRC_DEC_OBJ for the
*                  same values. A tty fd is a constant, not an
*                  object.
*   0              unused slot; stays unused in the child.
*
* PIPE_USED needs no action here BECAUSE it is derived: it is
* cleared only when both ref counts reach zero (procfd2.s's
* slot reclaim), and this routine only ever raises them.
*
* Note this is the FULL table, all eight fds -- unlike spawn's
* PRC_DFLT_FDS, which copies 0/1/2 only. fork inherits
* everything the parent has open; that is the difference
* between the two calls, not an inconsistency.
*---------------------------------------------------------------
FRK_DUP_FDS stz   P_FD
:loop       lda   P_FD
            cmp   #8
            beq   :done
            lda   PRC_PAR_PID
            sta   P_PID
            jsr   PRC_GET_FDOBJ
            beq   :next                ;0 = slot unused
            sta   P_TMP2               ;the object, for the kid
            jsr   PRC_INC_OBJ_A        ;A still holds it
            lda   PRC_CHILD_PID
            sta   P_PID
            jsr   PRC_SET_FDOBJ
:next       inc   P_FD
            bra   :loop
:done       rts

*---------------------------------------------------------------
* PRC_FORK -- SYS_FORK (8). No parameters: fork() takes none,
* so the register-carried parms pointer is ignored entirely and
* a caller may pass anything. Returns the child's pid to the
* parent and 0 to the child, carry clear on both; carry set
* with ERR_AGAIN when no bank can be had.
*
* BANK EXHAUSTION IS EAGAIN, NOT ENOMEM. ARCHITECTURE.md rules
* it ("fork() fails cleanly (EAGAIN-style) when the free-list is
* empty"), inc/errno.krn.equ spells ERR_AGAIN with that
* ruling quoted in its own comment, and the ramdisk competes for
* the same pool -- so the condition really is "try again later",
* not "this machine has no memory". PRC_ALLC_BANK reports
* ERR_NOMEM because SPAWN's failure is different in kind (an
* image that will not fit is not transient); this overrides it
* for fork alone rather than changing a shared allocator's
* verdict out from under spawn.
*
* THE ALLOCATION IS AN ORDINARY ONE, never a warm hit. A
* retained bank's value is that it already holds a PROGRAM's
* text; a fork wants a copy of a LIVE process, which is a
* different thing even for the same program. LZ_WANT is
* one-shot and PRC_SPAWN clears it on every use, so it is
* already 0 here -- this zeroes it anyway, for the same reason
* PRC_ALLC_BANK does: a stale preference must never be
* inheritable. The bank fork gets is therefore untagged, so
* PRC_FREE_BANK will plainly free it at exit and no retained
* image can ever be confused with a forked one.
*
* ORDER MATTERS IN ONE PLACE. SCH_CREATE zeroes PCB_BRK,
* PCB_PARENT and PCB_FDTABLE and sets PCB_SAVEDSP to $F9 (item
* 11's FRESH process), so all four fixups must follow it, not
* precede it. A forked child is not fresh: it resumes
* mid-syscall on a copy of the parent's frame.
*---------------------------------------------------------------
PRC_FORK
            stz   LZ_WANT               ;see the header: never a
                                        ;warm hit
            lda   K_CALLER_SP
            sta   FRK_SP
            lda   K_CURPID
            sta   PRC_PAR_PID

*-- The extent, before anything is allocated. PBRK_GET leaves
*-- the annex selected; PRC_SEL_CRBNK puts the parent's own bank
*-- back and returns its number in A -- the copy source.
            jsr   PBRK_GET
            sta   FRK_BRKPG
            bne   :havebrk
            lda   #>PRC_BRK_LIM         ;no declared extent: the
:havebrk    sta   FRK_ENDPG             ;whole window, 46848 B
            jsr   PRC_SEL_CRBNK
            sta   FRK_SRCBNK            ;A = the bank (shadow
                                        ;cell, no PCB read)

            jsr   PRC_ALLC_BANK
            bcc   :bankok
            lda   #ERR_AGAIN
            jsr   PRC_FAIL_A
            rts
:bankok     sta   FRK_DSTBNK
            sta   PRC_CHLD_BANK
            sta   PRC_CHILD_PID        ;pid == bank, spawn's own
                                        ;convention

*-- A FRESH $FFxx stamp, not a copy of the parent's LC. This IS
*-- the ABI (cold-read Q3-2): the child's $D000-$FEFF is
*-- undefined, and only the kernel's own page is guaranteed.
            lda   FRK_DSTBNK
            jsr   PRC_STMP_BANK

            jsr   FRK_CLN_ZP
            jsr   FRK_CLN_STK
            jsr   FRK_CLN_IMG
            lda   K_BC_ERR
            beq   :copyok
*-- BankCopy refused a range. Nothing points at the child yet --
*-- SCH_CREATE has not run, so freeing the bank is the whole
*-- cleanup, exactly as PRC_SPAWN's own load-failure path does.
            lda   FRK_DSTBNK
            jsr   PRC_FREE_BANK
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts

:copyok     lda   PRC_CHILD_PID
            ldx   FRK_DSTBNK
            jsr   SCH_CREATE

*-- S9 L3b: the child is a COPY of the parent's bank, so it is
*-- running the parent's image at the parent's load address --
*-- the base is inherited exactly like the break below. (The
*-- child does not LAUNCH at that address: it resumes after the
*-- parent's own `jsr $FF00`. The base matters here for brk()'s
*-- floor, and for the tag if this bank is ever retained.)
            ldx   K_CURPID
            lda   PRC_BASEPG,x
            ldx   PRC_CHILD_PID
            sta   PRC_BASEPG,x

*-- signals (docs/SIGNALS.md inheritance): fork copies BOTH
*-- masks -- V7 fork inherits dispositions whole; pending stays
*-- empty (SCH_CREATE zeroed the row). Y=1 selects fork's rule.
            lda   K_CURPID
            ldx   PRC_CHILD_PID
            ldy   #1
            jsr   PRC_SIG_INH

*-- SCH_CREATE zeroed PCB_BRK, which is right for spawn and
*-- wrong here: the child inherits the extent along with the
*-- memory it describes. Written back verbatim, 0 included -- a
*-- parent with no declared break forks a child with none.
            lda   PRC_CHILD_PID
            sta   P_PID
            lda   #PCB_BRK
            sta   P_TMP
            lda   FRK_BRKPG
            sta   P_TMP2
            jsr   PPCB_WR_BYTE

*-- and PCB_SAVEDSP, which SCH_CREATE set to item 11's $F9 for a
*-- process launching at LOAD_BASE. This child launches at the
*-- instruction after its parent's `jsr $FF00`, off a stack page
*-- that is a byte copy -- so its SP is the parent's captured
*-- SP, whatever that happened to be.
            lda   #PCB_SAVEDSP
            sta   P_TMP
            lda   FRK_SP
            sta   P_TMP2
            jsr   PPCB_WR_BYTE

            lda   PRC_PAR_PID
            jsr   PPCB_WR_PAR

*-- cwd is per-process state that a child inherits, same as
*-- spawn (a `cd` in the shell moves everything it forks after).
            lda   PRC_PAR_PID
            jsr   CWD_READ
            lda   PRC_CHILD_PID
            jsr   CWD_WRITE

            jsr   FRK_DUP_FDS
            jsr   FRK_PTCH_FRM

*-- PRC_RET_OK_A sets the PARENT's result and re-selects its
*-- bank; KRN_EXIT patches the parent's own frame-A and carry on
*-- the way out. The child's were patched above. One call, two
*-- returns.
            lda   PRC_CHILD_PID
            jsr   PRC_RET_OK_A
            rts
