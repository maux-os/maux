*---------------------------------------------------------------
* lazyfree.s -- lazy free: a dead process's bank is TAGGED with
* the program whose text it holds and kept, instead of being
* pushed back on the free list. The next spawn of that same
* program is handed the same bank and runs with NO image copy at
* all (docs/STICKY.md sec 25, superseding sec 2-5's spawn cache
* -- this file replaces sticky.s + sticky2.s).
*
* WHY THERE IS NO COPY. After sec 23 (brk) and sec 24 (the fixed
* 256-byte zeroed page) a warm respawn needs only: reset SP,
* zero PCB_BRK, restage argv, zero the page, jump to LOAD_BASE
* -- and spawn already did every one of those. Text is
* immutable (sec 26: liba emits no cell anything writes), the
* `dum` region and the heap are uncleared BY CONTRACT, and there
* is no data segment to restore because there is no data
* segment.
*
* THE THREE-WAY PREFERENCE (sec 25): PRC_ALLC_BANK takes
*   1. a bank already tagged with the program being spawned
*      (a warm hit -- no OPEN, no read loop, no BankCopy),
*   2. any genuinely free bank,
*   3. the least-recently-retained tagged bank, reclaimed.
* Step 3 is "processes always win" (sec 3), and it survives
* verbatim: a bank needed for a different program is taken back
* with no negotiation.
*
* INVALIDATION (sec 4, carried over exactly). A retained bank
* must prove its image is current before it is reused:
*   1. one MLI GET_FILE_INFO on every candidate hit, comparing
*      the RAW mod_date/mod_time bytes -- never decoded, because
*      equality is format-blind and ProDOS 2.5's Extended dates
*      are opaque (learning:01M0BQQ6XN04NQAWE0WAQX1RG5);
*   2. pathname invalidation from the kernel's own write path,
*      SYS_CREAT/UNLINK/RENAME/SET_FILE_INFO and the first
*      WRITE/SET_EOF of an opened file (procfile*.s), which is
*      the LOAD-BEARING half: ProDOS mtime has MINUTE
*      resolution, and the motivating loop -- assemble, then run
*      seconds later -- lives entirely inside
*      one minute. EVERY KEY IS THE CANONICAL PATH (PRC_CANON,
*      LZ_INVAL_PB/_CN below): the tags are absolute and a shell
*      that never chdir'd hands the kernel relative names. OPEN
*      is in the story because ProDOS has no open mode -- every
*      handle can write, so an in-place rewrite (dd, an editor,
*      `> FILE` onto an existing file) never reaches CREAT,
*      UNLINK or RENAME. But most opens only READ (sh's
*      PATH_EXISTS probes every command it is about to spawn),
*      so OPEN only ARMS the fd (LZ_ARM: the matching slot is
*      recorded against the OFT entry) and the first WRITE or
*      SET_EOF on it drops the tag (LZ_DIRTY).
*
* ABSOLUTE KEYS ONLY. Spawn's path copier does not cwd-resolve
* (unlike PCPY_MLI_PATH -> PRC_ABSPATH), so a relative spawn
* name would alias across cwds and could never match the
* RESOLVED names invalidation compares. A relative spawn is
* never tagged and never matched; it behaves exactly as before.
*
* WHERE THE STATE LIVES. One slot per bank in the pool. The
* small fields are ordinary main-memory kernel arrays indexed by
* slot; only the 65-byte pathname lives in the annex
* (LZ_PTH_ADDR, inc/mm.annex.equ), following the cwd
* table's precedent -- so the common operations (find the slot
* for a bank, pick the LRU) never touch aux memory at all, and
* only a path COMPARE pays for a BankCopy.
*
* Every routine here runs in PROCESS CONTEXT ONLY -- spawn and
* the file syscalls. Never from tick or IRQ context: BankCopy
* and PMLI_GFI_CALL both assume a quiescent kernel stack, and
* the MLI call runs CLI-bracketed, which tick code may not do.
*
* Loop counters live in memory (LZ_IDX), never in a register
* held across a call: BankCopy's contract promises only that
* A/X are clobbered, but COPYIN_ENTRY uses Y as its byte index
* too. Same discipline sticky.s recorded and PSTG_ARGV follows.
*---------------------------------------------------------------

* -- LZ_STATE values. A slot is one of these three, and a bank
* -- is in exactly one of: the free list (no slot), LIVE (a
* -- process is running in it), or HELD (retained, reusable).
LZ_FREE     equ   0
LZ_LIVE     equ   1
LZ_HELD     equ   2

*---------------------------------------------------------------
* Slot state. Ordinary main memory, same idiom as every other
* kernel module's tables -- none of it is zero page, so none of
* it needs ALTZP immunity; the only genuinely ZP cell touched
* here is P_PTR1 (process.s), used as a plain (zp),y pointer
* into a MAIN-memory buffer, never into process/aux memory.
*---------------------------------------------------------------
LZ_BANKS    ds    LZ_SLOT_CNT   ;physical bank # this slot
                                ;describes
LZ_STATE    ds    LZ_SLOT_CNT   ;LZ_FREE/LZ_LIVE/LZ_HELD
LZ_STAMP    ds    LZ_SLOT_CNT   ;retirement stamp -- the LRU
                                ;signal, set when a bank is
                                ;retained
LZ_BASELO   ds    LZ_SLOT_CNT   ;S9 L3b: the address the tagged
LZ_BASEHI   ds    LZ_SLOT_CNT   ;image was LOADED at (its
                                ;aux_type). The entry-point
                                ;check reads its 8 bytes from
                                ;there, and a warm relaunch
                                ;jumps there -- neither is
                                ;LOAD_BASE any more, and a slot
                                ;outlives the spawn that made
                                ;it, so the base has to be
                                ;tagged alongside the length.
LZ_LENLO    ds    LZ_SLOT_CNT   ;tagged image length, lo/hi --
LZ_LENHI    ds    LZ_SLOT_CNT   ;what the cold load's GET_EOF
                                ;found, so a warm hit needs no
                                ;GET_EOF of its own
*-- LZ_MT0..3: the raw mod_date lo/hi and mod_time lo/hi
*-- exactly as GET_FILE_INFO returned them -- compared, never
*-- decoded. 4 x LZ_SLOT_CNT B homed in KBSS (mm.kbss.equ) by
*-- KFIX: written when a slot is tagged, read only for a
*-- non-FREE slot, so they need no initial value.

LZ_CLOCK    ds    1             ;monotonic retirement counter,
                                ;wraps at 256 (a wrap can only
                                ;pick a worse victim, never a
                                ;wrong one)
LZ_IDX      ds    1             ;generic scan counter
LZ_SLOT     ds    1             ;slot under consideration
LZ_TMPB     ds    1             ;bank number held across a call
LZ_BEST     ds    1             ;LZ_RECLAIM: lowest stamp seen
LZ_BESTS    ds    1             ;LZ_RECLAIM: its slot, $FF none
LZ_WANT     ds    1             ;ONE-SHOT: nonzero = the next
                                ;PRC_ALLC_BANK may prefer a bank
                                ;tagged with PRC_PATHBUF
LZ_ARMX     ds    1             ;LZ_ARM's scan: OFT entry to arm
                                ;(0 = a plain invalidation)
LZ_WARM     ds    1             ;nonzero = this spawn was served
                                ;from a retained bank; the
                                ;loader skips OPEN/read entirely
LZ_STGOK    ds    1             ;nonzero = LZ_STGMT holds a
                                ;usable mtime for the load in
                                ;progress
LZ_STGMT    ds    4             ;mtime read ONCE, before the
                                ;read loop starts -- a write
                                ;DURING the load must invalidate
                                ;the tag, not be missed
LZ_ENTADR   ds    2             ;annex address of a slot's path
*-- LZ_PATHBUF: LZ_PTH_SIZE B homed in KBSS (mm.kbss.equ),
*-- KSPACE2.
                                ;main-side mirror of one slot's
                                ;annex pathname
LZ_HDBUF    ds    LZ_HEAD_LEN   ;the child bank's first bytes,
                                ;read back for the entry-point
                                ;check below
LZ_HEAD     ds    LZ_HEAD_TOTL  ;per slot: the same bytes as the
                                ;image was LOADED with

* -- the slots' fixed annex addresses. Pure `+` expressions (no
* -- `*`): real Merlin-8 has no operator precedence and
* -- evaluates strictly left to right
* -- (learning:01M051DJW89KV4JYM1EC9SDZ5Y), so a product inside
* -- a sum is a different number under the two assemblers.
LZ_PTH_TBL  da    LZ_PTH_ADDR
            da    LZ_PTH_ADDR+65
            da    LZ_PTH_ADDR+130
            da    LZ_PTH_ADDR+195
            da    LZ_PTH_ADDR+260
            da    LZ_PTH_ADDR+325
            da    LZ_PTH_ADDR+390
            da    LZ_PTH_ADDR+455
            da    LZ_PTH_ADDR+520
            da    LZ_PTH_ADDR+585
            da    LZ_PTH_ADDR+650
            da    LZ_PTH_ADDR+715
            da    LZ_PTH_ADDR+780
            da    LZ_PTH_ADDR+845

*---------------------------------------------------------------
* LZ_INIT -- boot-time setup, called from PRC_INIT (process.s)
* alongside every other table that routine clears. The annex
* pathname area needs no clearing: LZ_STATE is the authority on
* whether a slot means anything, and it is cleared here.
*---------------------------------------------------------------
LZ_INIT
            stz   LZ_CLOCK
            stz   LZ_WANT
            stz   LZ_WARM
            stz   LZ_STGOK
            ldx   #0
            lda   #LZ_FREE
:clr        sta   LZ_BANKS,x
            sta   LZ_STATE,x
            inx
            cpx   #LZ_SLOT_CNT
            bne   :clr
            rts

*---------------------------------------------------------------
* LZ_ENT_ADDR -- A = slot in; LZ_ENTADR = that slot's annex
* pathname address. Clobbers A/X.
*---------------------------------------------------------------
LZ_ENT_ADDR
            asl   a
            tax
            lda   LZ_PTH_TBL,x
            sta   LZ_ENTADR
            lda   LZ_PTH_TBL+1,x
            sta   LZ_ENTADR+1
            rts

*---------------------------------------------------------------
* LZ_RD_PATH -- A = slot in; BankCopy that slot's pathname from
* the annex into LZ_PATHBUF. Clobbers A/X/Y and every
* K_BC_*/K_CPY_* cell (BankCopy's own contract).
*---------------------------------------------------------------
LZ_RD_PATH
            jsr   LZ_ENT_ADDR
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            lda   LZ_ENTADR
            sta   K_BC_SRCADDR
            lda   LZ_ENTADR+1
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK        ;annex = bank 0
            lda   #BC_KIND_MAIN
            sta   K_BC_DSTKIND
            lda   #<LZ_PATHBUF
            sta   K_BC_DSTADDR
            lda   #>LZ_PATHBUF
            sta   K_BC_DSTADDR+1
            lda   #LZ_PTH_SIZE
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jmp   BankCopy

*---------------------------------------------------------------
* LZ_WR_PATH -- A = slot in; BankCopy PRC_PATHBUF's canonical
* spawn pathname (length byte + chars) into that slot's annex
* storage. Same clobbers as LZ_RD_PATH.
*---------------------------------------------------------------
LZ_WR_PATH
            jsr   LZ_ENT_ADDR
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<PRC_PATHBUF
            sta   K_BC_SRCADDR
            lda   #>PRC_PATHBUF
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   LZ_ENTADR
            sta   K_BC_DSTADDR
            lda   LZ_ENTADR+1
            sta   K_BC_DSTADDR+1
            stz   K_BC_DSTBANK
            lda   #LZ_PTH_SIZE
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jmp   BankCopy

*---------------------------------------------------------------
* LZ_CMP_PATH -- A = slot in, P_PTR1 = a 65-byte length-prefixed
* pathname buffer to compare against. Returns carry CLEAR =
* match. Clobbers A/X/Y.
*---------------------------------------------------------------
LZ_CMP_PATH
            jsr   LZ_RD_PATH
            ldy   #0
            lda   (P_PTR1),y
            cmp   LZ_PATHBUF
            bne   :no                 ;length differs
            tax                       ;X = length, 0..64
            cpx   #0
            beq   :yes                ;degenerate; a stored path
                                      ;is never zero-length
*-- CASE-BLIND, because ProDOS is: a tag keeps the spelling its
*-- spawn was typed in, and the probe is spelled however the
*-- unlinking program typed it. xor then mask bit 5 is exact
*-- for what a ProDOS path holds (letters, digits, '.', '/': no
*-- two differ by $20 but a letter and its case twin). The
*-- length byte above is still compared exactly.
:cp         iny
            lda   (P_PTR1),y
            eor   LZ_PATHBUF,y
            and   #$DF
            bne   :no
            dex
            bne   :cp
:yes        clc
            rts
:no         sec
            rts

*---------------------------------------------------------------
* LZ_FIND_BNK -- A = bank in. Returns carry CLEAR + X = the slot
* describing that bank; carry SET = this bank carries no tag.
* Leaves the bank number in LZ_TMPB either way.
*---------------------------------------------------------------
LZ_FIND_BNK
            sta   LZ_TMPB
            ldx   #0
:loop       lda   LZ_STATE,x
            beq   :next
            lda   LZ_BANKS,x
            cmp   LZ_TMPB
            beq   :hit
:next       inx
            cpx   #LZ_SLOT_CNT
            bne   :loop
            sec
            rts
:hit        clc
            rts

*---------------------------------------------------------------
* LZ_FREE_SLT -- returns carry CLEAR + X = an unused slot; carry
* SET = every slot is taken (which cannot happen while there is
* one slot per bank, but a caller that cannot get one simply
* leaves the bank untagged -- it is then freed the old way).
*---------------------------------------------------------------
LZ_FREE_SLT
            ldx   #0
:loop       lda   LZ_STATE,x
            beq   :hit
            inx
            cpx   #LZ_SLOT_CNT
            bne   :loop
            sec
            rts
:hit        clc
            rts

*---------------------------------------------------------------
* LZ_DROP -- X = slot in; forget the tag. The bank itself is NOT
* freed here (the caller decides that -- a LIVE bank has a
* process in it). Returns A = the bank the slot described.
*---------------------------------------------------------------
LZ_DROP
            lda   LZ_BANKS,x
            pha
            lda   #LZ_FREE
            sta   LZ_STATE,x
            sta   LZ_BANKS,x
            pla
            rts

*---------------------------------------------------------------
* LZ_RD_HEAD -- read LZ_HEAD_LEN bytes from slot X's base in
* bank named by LZ_TMPB into LZ_HDBUF. Clobbers A/X/Y and the
* K_BC_*/K_CPY_* cells.
*
* S9 L3b: X = the SLOT, and the address comes from that slot's
* own LZ_BASELO/HI rather than LOAD_BASE -- the bytes to
* compare are the ones at the address that bank's image was
* loaded at, and a retiring bank's base is whatever its
* aux_type said, not the floor. Read here rather than by each
* caller: both already hold X, and setting it twice was the
* same four lines twice.
*---------------------------------------------------------------
LZ_RD_HEAD
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            lda   LZ_BASELO,x
            sta   K_BC_SRCADDR
            lda   LZ_BASEHI,x
            sta   K_BC_SRCADDR+1
            lda   LZ_TMPB
            sta   K_BC_SRCBANK
            lda   #BC_KIND_MAIN
            sta   K_BC_DSTKIND
            lda   #<LZ_HDBUF
            sta   K_BC_DSTADDR
            lda   #>LZ_HDBUF
            sta   K_BC_DSTADDR+1
            lda   #LZ_HEAD_LEN
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jmp   BankCopy

*---------------------------------------------------------------
* LZ_HD_IDX -- A = slot in, X = &LZ_HEAD[slot] out. LZ_HEAD_LEN
* is a power of two on purpose: three shifts, no multiply.
*---------------------------------------------------------------
LZ_HD_IDX
            asl   a
            asl   a
            asl   a
            tax
            rts

*---------------------------------------------------------------
* LZ_SAVE_HD -- A = slot in; copy LZ_HDBUF into that slot.
*---------------------------------------------------------------
LZ_SAVE_HD
            jsr   LZ_HD_IDX
            ldy   #0
:cp         lda   LZ_HDBUF,y
            sta   LZ_HEAD,x
            inx
            iny
            cpy   #LZ_HEAD_LEN
            bne   :cp
            rts

*---------------------------------------------------------------
* LZ_CMP_HD -- A = slot in; compare LZ_HDBUF against the bytes
* recorded for that slot. Carry CLEAR = unchanged.
*---------------------------------------------------------------
LZ_CMP_HD
            jsr   LZ_HD_IDX
            ldy   #0
:cp         lda   LZ_HDBUF,y
            cmp   LZ_HEAD,x
            bne   :no
            inx
            iny
            cpy   #LZ_HEAD_LEN
            bne   :cp
            clc
            rts
:no         sec
            rts

*---------------------------------------------------------------
* LZ_RETAIN -- A = bank in, from PRC_FREE_BANK. If this bank
* carries a LIVE tag, it becomes HELD (retained, stamped) and is
* NOT pushed to the free list: carry CLEAR, and the caller
* returns without freeing anything. Carry SET = no tag worth
* keeping -- the caller pushes the bank exactly as it always
* did. A is the bank number on both exits.
*---------------------------------------------------------------
LZ_RETAIN
            jsr   LZ_FIND_BNK
            bcs   :none
            lda   LZ_STATE,x
            cmp   #LZ_LIVE
            bne   :drop
* -- THE ENTRY-POINT CHECK (docs/STICKY.md sec 27). The process
* -- that just died had write access to every byte of its own
* -- image, and one program here uses it: `as` overwrites
* -- 8,686 of its 15,957 image bytes, LOAD_BASE's own `jmp`
* -- among them, so respawning into its retained bank jumps into
* -- three zero bytes. Retaining a bank means promising its text
* -- is still the program -- so before promising it, read back
* -- the bytes the kernel itself is going to jump to and refuse
* -- if they moved. This is NOT a proof that the whole text is
* -- intact (that costs a full scan, and sec 9 priced it at the
* -- copy it would save); it checks the one invariant the KERNEL
* -- depends on. Everything past it is the program's own
* -- contract -- which is what check-ls's poison-between-runs
* -- gate exercises.
            stx   LZ_SLOT
            jsr   LZ_RD_HEAD
* -- and put the CALLER's bank back. KRN_EXIT does not write
* -- BANKSEL on its no-switch path ("same bank that entered" --
* -- entry.s), so a syscall must leave the selection as it found
* -- it; the house discipline is that the last routine before
* -- the return does it (PRC_FAIL_A/PRC_RET_OK_A both end in
* -- PRC_SEL_CRBNK). PRC_FREE_BANK never used to open a bank
* -- window at all, and one of its callers -- PRC_SPAWN's argv-
* -- staging failure -- returns straight to KRN_EXIT after it.
            jsr   PRC_SEL_CRBNK
            lda   LZ_SLOT
            jsr   LZ_CMP_HD
            ldx   LZ_SLOT
            bcs   :drop
            lda   #LZ_HELD
            sta   LZ_STATE,x
            inc   LZ_CLOCK
            lda   LZ_CLOCK
            sta   LZ_STAMP,x
            lda   LZ_TMPB
            clc
            rts
:drop       jsr   LZ_DROP            ;already HELD -- defensive;
                                     ;forget it, free it plainly
:none       lda   LZ_TMPB
            sec
            rts

*---------------------------------------------------------------
* LZ_TAG -- record PRC_CHLD_BANK as holding the program named by
* PRC_PATHBUF, at PRC_IMAGE_LEN bytes, stamped with LZ_STGMT.
* State LIVE: the child is about to run in it, and the tag only
* becomes reusable when PRC_FREE_BANK retires the bank.
*---------------------------------------------------------------
LZ_TAG
            lda   PRC_CHLD_BANK
            jsr   LZ_FIND_BNK
            bcc   :have               ;re-tag in place
            jsr   LZ_FREE_SLT
            bcs   :nope
:have       stx   LZ_SLOT
            lda   PRC_CHLD_BANK
            sta   LZ_BANKS,x
            lda   #LZ_LIVE
            sta   LZ_STATE,x
            lda   PRC_IMAGE_LEN
            sta   LZ_LENLO,x
            lda   PRC_IMAGE_LEN+1
            sta   LZ_LENHI,x
            lda   PRC_LOADADR
            sta   LZ_BASELO,x
            lda   PRC_LOADADR+1
            sta   LZ_BASEHI,x
            lda   LZ_STGMT
            sta   LZ_MT0,x
            lda   LZ_STGMT+1
            sta   LZ_MT1,x
            lda   LZ_STGMT+2
            sta   LZ_MT2,x
            lda   LZ_STGMT+3
            sta   LZ_MT3,x
            jsr   LZ_RD_HEAD          ;LZ_TMPB is PRC_CHLD_BANK
            lda   LZ_SLOT             ;(LZ_FIND_BNK left it
            jsr   LZ_SAVE_HD          ;there) -- the image AS
            lda   LZ_SLOT             ;LOADED, for the retire-
            jsr   LZ_WR_PATH          ;time check in LZ_RETAIN
:nope       rts

*---------------------------------------------------------------
* LZ_MATCH -- scan the RETAINED slots for PRC_PATHBUF. Returns
* carry CLEAR + X = slot; carry SET = no retained bank holds
* this program. LIVE slots are deliberately skipped: their bank
* has a process in it (sec 11's in-flight case), so a concurrent
* spawn of the same program takes the ordinary cold path.
*---------------------------------------------------------------
LZ_MATCH
            lda   #<PRC_PATHBUF
            sta   P_PTR1
            lda   #>PRC_PATHBUF
            sta   P_PTR1+1
            stz   LZ_IDX
:loop       ldx   LZ_IDX
            lda   LZ_STATE,x
            cmp   #LZ_HELD
            bne   :next
            lda   LZ_IDX
            jsr   LZ_CMP_PATH
            bcc   :hit
:next       inc   LZ_IDX
            lda   LZ_IDX
            cmp   #LZ_SLOT_CNT
            bne   :loop
            sec
            rts
:hit        ldx   LZ_IDX
            clc
            rts

*---------------------------------------------------------------
* LZ_TRY_WARM -- the whole warm path, called from
* PRC_ALLC_BANK's preference step 1 with PRC_PATHBUF already
* holding the canonical spawn pathname.
*
* Returns carry CLEAR + A = a bank whose text is ALREADY the
* program being spawned, with PRC_IMAGE_LEN set from the tag and
* LZ_WARM raised so the loader skips OPEN/GET_EOF/the read loop.
* Carry SET = no usable retained bank; the caller falls through
* to an ordinary allocation.
*
* A retained bank that fails the freshness test is not merely
* skipped -- its tag is dropped and the bank is pushed to the
* free list, so the cold load that follows lands in that same
* bank (the list is LIFO) and overwrites the stale image.
*---------------------------------------------------------------
LZ_TRY_WARM
            jsr   LZ_MATCH
            bcs   :miss
            stx   LZ_SLOT
            jsr   PRC_GFI_PATH
            bne   :stale              ;cannot confirm freshness
                                      ;-- the cold path's own
                                      ;OPEN reports the real
                                      ;error if there is one
            lda   PML_GFI_PARMS+MLI_GFI_ACC+1
            inc   a                   ;BIN->7, SYS->0: a file
            beq   :ftok               ;chtyp'd is not warm (cold
            cmp   #7                  ;refuses it). Inline: jsr
            bne   :stale              ;here kills the stack
:ftok
            ldx   LZ_SLOT
            lda   PML_GFI_PARMS+MLI_GFI_MDATE
            cmp   LZ_MT0,x
            bne   :stale
            lda   PML_GFI_PARMS+MLI_GFI_MDATE+1
            cmp   LZ_MT1,x
            bne   :stale
            lda   PML_GFI_PARMS+MLI_GFI_MTIME
            cmp   LZ_MT2,x
            bne   :stale
            lda   PML_GFI_PARMS+MLI_GFI_MTIME+1
            cmp   LZ_MT3,x
            bne   :stale

            lda   LZ_LENLO,x
            sta   PRC_IMAGE_LEN
            lda   LZ_LENHI,x
            sta   PRC_IMAGE_LEN+1
*-- S9 L3b: the warm path's own load address. The freshness
*-- test above compared mtime, so the FILE is the one this bank
*-- already holds -- its aux cannot have changed without the
*-- mtime changing, and the tagged base is what the image in
*-- the bank is actually sitting at. Taking it from the slot
*-- rather than from PML_GFI_PARMS keeps the tag the single
*-- authority on what is in the bank.
            lda   LZ_BASELO,x
            sta   PRC_LOADADR
            lda   LZ_BASEHI,x
            sta   PRC_LOADADR+1
            lda   #LZ_LIVE
            sta   LZ_STATE,x
            lda   #1
            sta   LZ_WARM
            lda   LZ_BANKS,x
            clc
            rts

:stale      ldx   LZ_SLOT
            jsr   LZ_DROP
            jsr   PRC_PUSH_BANK
:miss       sec
            rts

*---------------------------------------------------------------
* LZ_RECLAIM -- preference step 3, "processes always win" (sec
* 3). Called by PRC_ALLC_BANK when the free list is empty: takes
* the least-recently-retained tagged bank, drops its tag and
* pushes it, so the caller's pop succeeds. Returns carry CLEAR =
* a bank was reclaimed; carry SET = nothing is retained either,
* which is a genuine ERR_NOMEM -- exactly the old behavior.
*---------------------------------------------------------------
LZ_RECLAIM
            stz   LZ_IDX
            lda   #$FF
            sta   LZ_BESTS
            stz   LZ_BEST
:loop       ldx   LZ_IDX
            lda   LZ_STATE,x
            cmp   #LZ_HELD
            bne   :next
            lda   LZ_STAMP,x
            ldy   LZ_BESTS
            cpy   #$FF
            beq   :take               ;first candidate seen
            cmp   LZ_BEST
            bcs   :next               ;newer -- keep the older
:take       sta   LZ_BEST
            lda   LZ_IDX
            sta   LZ_BESTS
:next       inc   LZ_IDX
            lda   LZ_IDX
            cmp   #LZ_SLOT_CNT
            bne   :loop
            ldx   LZ_BESTS
            cpx   #$FF
            beq   :fail
            jsr   LZ_DROP
            jsr   PRC_PUSH_BANK
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* LZ_BEGIN -- called from PRC_LD_FL_IMG once a cold load's
* length is known (after GET_EOF, BEFORE the read loop starts).
* Reads the file's mtime NOW, not after: a write that lands
* mid-load must invalidate the tag rather than be stamped into
* it. Failure here is never fatal -- it just leaves LZ_STGOK
* clear, and the load proceeds untagged.
*---------------------------------------------------------------
LZ_BEGIN
            stz   LZ_STGOK
            lda   PRC_PATHBUF+1       ;absolute keys only -- see
            cmp   #"/"+$80            ;this file's header
            bne   :skip
*-- no tag for a path that is open anywhere (a parked fd is
*-- closed in ProDOS, so the loader's own OPEN let it through):
*-- an fd armed BEFORE the tag existed could never drop it
            jsr   PRC_FILE_BUSY
            bcs   :skip
            lda   #<PRC_PATHBUF
            sta   PML_GFI_PARMS+MLI_PATHLO
            lda   #>PRC_PATHBUF
            sta   PML_GFI_PARMS+MLI_PATHHI
            jsr   PMLI_GFI_CALL
            bne   :skip
            lda   PML_GFI_PARMS+MLI_GFI_MDATE
            sta   LZ_STGMT
            lda   PML_GFI_PARMS+MLI_GFI_MDATE+1
            sta   LZ_STGMT+1
            lda   PML_GFI_PARMS+MLI_GFI_MTIME
            sta   LZ_STGMT+2
            lda   PML_GFI_PARMS+MLI_GFI_MTIME+1
            sta   LZ_STGMT+3
            lda   #1
            sta   LZ_STGOK
:skip       rts

*---------------------------------------------------------------
* LZ_COMMIT -- called from PRC_LD_FL_IMG's NORMAL completion
* only. Every error exit above it returns directly, so a partial
* load can never tag a bank -- by construction, not by a flag
* this routine has to test.
*---------------------------------------------------------------
LZ_COMMIT
            lda   LZ_STGOK
            beq   :done
            stz   LZ_STGOK
            jsr   LZ_TAG
:done       rts

*---------------------------------------------------------------
* LZ_WANT_SET -- PRC_SPAWN calls this once PRC_PATHBUF holds the
* spawn pathname and before PRC_ALLC_BANK, to say "this
* allocation may prefer a bank already holding this program".
* One-shot: PRC_ALLC_BANK clears it whether it uses it or not,
* so a direct caller of the allocator (the play gate's boot code
* does this) can never inherit a stale preference.
*---------------------------------------------------------------
LZ_WANT_SET
            stz   LZ_WANT
            lda   PRC_PATHBUF+1
            cmp   #"/"+$80
            bne   :no
            lda   #1
            sta   LZ_WANT
:no         rts

*---------------------------------------------------------------
* LZ_INVAL -- caller sets P_PTR1 to a 65-byte length-prefixed
* pathname (PRC_PATHBUF, or PRC_PATHBUF+PRC_PATH2OFF for
* RENAME's second name); drops every tag naming it. Reached
* through LZ_INVAL_PB/_CN from PRC_CREAT/PRC_UNLINK/PRC_RENAME/
* PRC_OPEN/PRC_SETFI: the write-path half of sec 4's two-
* mechanism invalidation, and the half that actually catches the
* build loop, because mtime cannot see a same-minute rewrite.
*
* A HELD match releases its bank to the free list as well as
* dropping the tag -- the bank holds an image nobody may run
* again. A LIVE match drops the tag ONLY: a process is running
* in that bank right now, and it is still running the image it
* was loaded with; what must not happen is that bank being
* retained later under a name whose file has since changed.
*---------------------------------------------------------------
LZ_INVAL
            stz   LZ_IDX
:loop       ldx   LZ_IDX
            lda   LZ_STATE,x
            beq   :next
            lda   LZ_IDX
            jsr   LZ_CMP_PATH
            bcs   :next
            ldx   LZ_ARMX
            bne   :arm
            ldx   LZ_IDX
            jsr   LZ_KILL
            bra   :next
*-- LZ_ARM's scan: do not drop -- record slot+1 against the fd
:arm        lda   LZ_IDX
            inc   a
            sta   LZ_OFTARM,x
:next       inc   LZ_IDX
            lda   LZ_IDX
            cmp   #LZ_SLOT_CNT
            bne   :loop
            rts

*---------------------------------------------------------------
* LZ_KILL -- X = slot in; the drop LZ_INVAL has always made. A
* HELD slot releases its bank to the free list as well as
* dropping the tag; a LIVE (or already FREE) slot loses the tag
* ONLY. Clobbers A/X/Y.
*---------------------------------------------------------------
LZ_KILL
            lda   LZ_STATE,x
            cmp   #LZ_HELD
            bne   :live
            jsr   LZ_DROP
            jmp   PRC_PUSH_BANK
:live       jmp   LZ_DROP

*---------------------------------------------------------------
* LZ_DROPALL -- forget EVERY tag, HELD and LIVE alike (LZ_KILL
* per slot; a FREE slot is rewritten FREE, which is harmless).
* PRC_BYE calls it at its commit point: a ProDOS tenant writes
* files with raw MLI calls that never reach PRC_WRITE/CREAT/
* UNLINK, so nothing in the kernel's write path can see a
* program it rebuilt, and mtime cannot see a same-minute
* rewrite. Nothing runs between that call and the tenant's QUIT,
* so dropping here leaves the same table as dropping on the way
* back. LZ_IDX carries the slot across LZ_KILL, as LZ_INVAL
* does.
*---------------------------------------------------------------
LZ_DROPALL
            ldx   #LZ_SLOT_CNT
:next       dex
            bmi   :done
            stx   LZ_IDX
            jsr   LZ_KILL
            ldx   LZ_IDX
            bra   :next
:done       rts

*---------------------------------------------------------------
* LZ_ARM -- PRC_OPEN, P_OBJ = the file's new OFT entry. A READ
* keeps its tag: a lookup that opens a program only to see that
* it exists (sh's PATH_EXISTS, before EVERY spawn that misses
* its 4-slot cache) must not cost the program its retained
* bank. So the scan that would drop a matching tag RECORDS it
* instead, in LZ_OFTARM[obj] as slot+1 (0 = none); LZ_DIRTY
* drops it at the first WRITE or SET_EOF on that entry. A
* relative open is PINNED in the OFT with no path, so the SLOT,
* not the name, travels with the fd. LZ_DIRTY re-reads that
* slot's PATH and drops every tag of it (a path can hold two).
* A path open anywhere is never tagged (LZ_BEGIN), so every tag
* postdates every fd that can write to it
* (docs/KFIX-NOTES.md item 2).
*---------------------------------------------------------------
LZ_ARM
            lda   P_OBJ
            sta   LZ_ARMX
            jsr   LZ_INVAL_CN
            stz   LZ_ARMX
            rts

*---------------------------------------------------------------
* LZ_DIRTY -- X = an OFT_FILE entry about to be written or have
* its EOF set (PRC_WRITE, PRC_SETEOF). If LZ_ARM armed it, drop
* that tag now and disarm, so only the FIRST write pays. X kept.
*---------------------------------------------------------------
LZ_DIRTY
            lda   LZ_OFTARM,x
            beq   :out
            stz   LZ_OFTARM,x
            phx
            dec   a
*-- key by the armed slot's PATH, not its number: LZ_MATCH skips
*-- LIVE, so a cold spawn overlapping a running instance leaves
*-- a SECOND tag, and every tag of the path must go
            jsr   LZ_RD_PATH
            ldx   #LZ_PTH_SIZE-1
:cp         lda   LZ_PATHBUF,x
            sta   PRC_TMPPATH,x
            dex
            bpl   :cp
            lda   #<PRC_TMPPATH
            sta   P_PTR1
            lda   #>PRC_TMPPATH
            sta   P_PTR1+1
            jsr   LZ_INVAL
            plx
:out        rts

*---------------------------------------------------------------
* LZ_INVAL_PB / LZ_INVAL_CN -- invalidate by the CANONICAL path
* (KFIX 2). _PB: PRC_PATHBUF slot 0 holds the caller's path, not
* yet canonicalised (PRC_CREAT, PRC_SETFI) -- make PRC_CANON
* first. _CN: PRC_CANON is current already (PRC_FILE_BUSY ran,
* in PRC_UNLINK/PRC_RENAME/PRC_OPEN). PRC_CANLEN = 0 means the
* path has no canonical form (no prefix, or it passes 64
* characters): then PRC_CANON is a PREVIOUS call's leftover and
* is never used as a key. Such a name cannot have a tag either:
* a tag is an absolute spawn path of at most 64 characters, and
* LZ_WANT_SET refuses to tag anything else.
*---------------------------------------------------------------
LZ_INVAL_PB
            jsr   PRC_CANONPATH
LZ_INVAL_CN
            lda   PRC_CANLEN
            beq   :none
            lda   #<PRC_CANON
            sta   P_PTR1
            lda   #>PRC_CANON
            sta   P_PTR1+1
            jmp   LZ_INVAL
:none       rts
