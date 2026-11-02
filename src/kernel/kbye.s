*---------------------------------------------------------------
* kbye.s -- PRC_BYE, PRC_RAMRECONN and PRC_RAMREDISC, moved into
* the kernel cold segment 2026-09-27 (docs/KSEG.md, coordinator
* review of commit 5edd6d3: "PRC_BYE MOVES"). Formerly the bulk
* of procbye.s's own body; procbye.s keeps PRC_BYE_INIT (boot-
* time), PBY_CHK_STAMP/PBY_WR_STAMP/PBY_SAVE_P1 (they flip ALTZP
* inline -- rule 1's allowed case, calling them from here via a
* plain `jsr` is fine), PBY_LOAD_RES and its own
* BL2_REF/BL2_DST/
* BL2_PSTG/KL_* flat cells.
*
* RULE 6'S REFINEMENT, the reason this file can exist at all
* (coordinator, 2026-09-27, amending docs/KSEG.md): rule 6's
* "return with rts" requirement has an exception for a routine
* whose SUCCESS path LEAVES maux entirely -- PRC_BYE issues a
* real MLI QUIT via BYE_LEAVE, IN THE SAME BANK (LCBANK1_RAM,
* since byeres.s's resident occupies $D100-$D3FF of the
* identical
* Apple bank 2 this segment lives in at $D400-$DFFF), and never
* returns through its own call chain: the kernel stack is
* abandoned, and BYE_BACK -> SCH_RESUME -> the next syscall/
* interrupt door re-establishes every LC and bank-select state
* from scratch. The trampoline's own missing $C08B reselect on
* that path is therefore moot -- nothing is left waiting for it.
* Every ERROR path in PRC_BYE (see its own body) returns with
* carry set + A = errno and goes back through KSEG_CALL
* normally,
* exactly like any other segment routine.
*
* RULE 2'S REFINEMENT (same coordinator review): reselecting
* $C083 (LCBANK1_RAM) from CODE ALREADY RUNNING IN THE SEGMENT
* is
* a no-op and allowed -- PRC_BYE does this itself (see its own
* "cheap insurance" comment) -- only selecting the OTHER bank
* ($C08B, LCBANK2_RAM) from inside the segment is fatal (it
* unmaps the very code that is running).
*
* THE CALLER: kdisp.s's SYS_BYE slot still names PRC_BYE_STUB
* (entry.s, unchanged, flat, common to every image) -- but
* PRC_BYE_INIT (procbye.s) now points K_BYE_VEC at K_BYE_TRAMP
* (procbye.s), a 5-byte flat trampoline (`jsr KSEG_CALL / da
* PRC_BYE / rts`) instead of at PRC_BYE's own address directly:
* PRC_BYE_STUB's `jmp (K_BYE_VEC)` is a TAIL jump (no new return
* address), so it lands in K_BYE_TRAMP with the ORIGINAL
* caller's
* return address still on top of the stack, exactly where a
* plain
* KSEG_CALL site expects it.
*
* THE TRAPFRAME PATCH still indexes the CALLER's own frame via
* K_CALLER_SP (main-resident, unaffected by which bank is
* selected or by the extra KSEG_CALL/K_BYE_TRAMP hops on the way
* in -- those hops only add stack frames on the CURRENT kernel
* stack, which K_CALLER_SP does not name at all: it is a
* SEPARATE cell recording the SP the caller's OWN trapframe sits
* at, captured at syscall entry, before any of this routine's
* own
* JSRs ran).
*---------------------------------------------------------------

* -- named, not a bare immediate (check-encoding: a bare #$BD/
* -- #$BF happens to fall in the ratchet's flagged range even
* -- though neither is TEXT -- a page count and a destination-
* -- address high byte). BYE_IMG_PAGES is the 189-page main-
* -- image save length ($0200-$BEFF, 48,384 B); BYE_ZP_DSTHI is
* -- K_BC_DSTADDR+1 for the ZP ($BF00) save below. The page-1
* -- save (PBY_SAVE_P1, procbye.s) targets a fixed literal, aux
* -- $0180, not a BankCopy destination -- BankCopy cannot reach
* -- it at all. Moved here with PRC_BYE (2026-09-27) -- equ'd at
* -- file scope, not inline, per the ANX_PAGES comment below.
BYE_IMG_PAGES equ $BD
BYE_ZP_DSTHI equ $BF
* -- ANX_PAGES: the annex-save's page count, $0200-$BFFF (190
* -- pages) -- equ'd HERE, at file scope, not inline in PRC_BYE
* -- itself (an `equ` is itself a global label, and one placed
* -- mid-routine ends the local-label ZONE right there,
* -- stranding
* -- `:local`s on both sides of a boundary neither meant to
* -- create -- measured directly when this was first written).
ANX_PAGES equ $BE

PRC_BYE
* -- SLICE 2 (docs/BYE.md "Slice 2 launch"): path copyin, FIRST
* -- of all -- nothing below has committed to anything yet
* -- either. IN: the caller's BYEPARM (src/liba/syscallp.s
* -- SC_BYE) at K_PARMLO/HI -- +0 unused, +1/+2 the path pointer
* -- (0/0 for a bare `bye`), matching MLI_PATHLO/MLI_PATHHI
* -- exactly so PCPY_MLI_PATH needs no offset change. No OUT
* -- field: a pinned entry's OFT index rides in the ERROR CODE
* -- itself (ERR_BYEPIN+index, the park loop below) rather
* -- than a BYEPARM writeback -- cheaper, see that routine.
* -- Reuses PCPI_CALLPARM/PCPY_MLI_PATH
* -- (procspawn.s/procfd.s) VERBATIM -- the SAME copyin every
* -- file syscall's own pathname already goes through, so this
* -- adds no new path-handling code at all.
*
* THE TYPE ($FF) AND SIZE (<= $7800) CHECKS ARE NOT HERE.
* MEASURED, not stylistic: a kernel-side GFI+OPEN+GETEOF+CLOSE
* check (an earlier version of this routine, PBY_CHECK_TENANT)
* cost ~130 B of procbye.s's own image, which this file's PT_
* HOLD headroom (measured 77 B before this slice) could not
* come close to absorbing even with byelaunch.s carrying the
* rest of the launch. bye.s ALREADY has SC_GFI/SC_OPEN/LSEEK/
* SC_CLOSE via liba (src/liba/seek.s) and refuses in USERLAND,
* before ever calling SC_BYE at all -- zero kernel image bytes,
* and no destructive round trip is even attempted for a bad
* file. The park loop below stays here because it is a genuine
* KERNEL operation (the OFT table); type/size are not.
            lda   #4
            jsr   PCPI_CALLPARM
            bcs   :s2_fail
            lda   PRC_PARM+1
            ora   PRC_PARM+2
            beq   :s2_cont
            jsr   PCPY_MLI_PATH
            bcs   :s2_fail
* -- PARK EVERY OPEN FILE (docs/BYE.md item 2), INLINED rather
* -- than called -- a separate JSR'd PBY_PARK_ALL cost 7 B more
* -- here for an outer call+check this file's own PT_HOLD
* -- headroom could not spare (measured). PRC_PARK_ONE
* -- (procfd2.s) to convergence, then confirm nothing RESIDENT
* -- is left -- it skips only PINNED entries (relatively-opened,
* -- PRC_OFT_SETP), so a survivor must be one.
:pa_loop    jsr   PRC_PARK_ONE
            bcc   :pa_loop
            beq   :pa_scan
            bra   :pa_fail
* -- decrementing scan, X: OFT_COUNT-1 down to 1 inclusive
* -- (index 0 is never a real fd). OFT_IOBUF,x ALONE (no
* -- separate OFT_TYPE==OFT_FILE check) is the whole test --
* -- VERIFIED, not assumed, by reading every write site
* -- (process.s PALOBJ_FILE, procfd2.s PRC_UNPARK's own
* -- restore, PRC_PARK_ONE's own park, PRC_DEC_OBJ's :clear):
* -- OFT_IOBUF is nonzero if and only if OFT_TYPE is OFT_FILE
* -- AND the entry is resident (not parked) -- a pipe slot's
* -- OFT_IOBUF is always 0, including right after reuse,
* -- because :clear zeroes it at release, before the slot can
* -- become a pipe.
:pa_scan    ldx   #OFT_COUNT-1
:pa_next    lda   OFT_IOBUF,x
            bne   :pa_pinned
:pa_adv     dex
            bne   :pa_next
* -- A IS ALREADY 0 here -- the last LDA OFT_IOBUF,x that did
* -- NOT branch to :pa_pinned loaded it, and DEX/BNE never touch
* -- A -- so PCLS_RAWREF_A (procfd2.s, A = the refnum to close)
* -- can be called with NO lda #0 first. CLOSE REFNUM 0 HERE, IN
* -- KERNEL CONTEXT, NOT IN byelaunch.s (a deviation from docs/
* -- BYE.md item 3's own listed order, MEASURED: issued from
* -- LC-resident code AFTER poison, MLI CLOSE(0) walks ProDOS's
* -- own FCB table, which lives below $BF00 and is therefore
* -- already destroyed -- it read poisoned $AA bytes as "open"
* -- entries with garbage device addresses and jumped into them,
* -- landing at $C20B decoding as BRK on the first launch
* -- attempt). ProDOS's own FCB table is still intact here,
* -- before BYE_LEAVE's poison runs, and every OFT-tracked file
* -- is already parked or closed by the loop above, so this
* -- covers only whatever ProDOS itself still thinks is open.
            jsr   PCLS_RAWREF_A
            bra   :s2_cont
* -- a resident (unparked) OFT_FILE entry survived the park
* -- loop above -- it must be pinned. NAME IT IN THE ERROR
* -- CODE ITSELF (ERR_BYEPIN + the OFT index, X, 1-15 since
* -- OFT_COUNT is 16 -- inc/mm.annex2.equ) rather than a
* -- BYEPARM writeback: MEASURED cheaper by 14 B (a P_PTR1/
* -- PWRPAR_BYTE copyout costs ~23 B here; encoding the index
* -- in A costs ~9), and every code from ERR_BYEPIN to
* -- ERR_BYEPIN+15 is otherwise unused (clear of every real MLI
* -- code, all <= $5A). bye.s decodes it back into "fd N" for
* -- the message.
:pa_pinned  txa
            clc
            adc   #ERR_BYEPIN
* -- shared fail tail -- ALSO reached from :pa_loop's own MLI-
* -- error exit above (A already the real error code there).
:pa_fail    jsr   PRC_FAIL_A
            sec
            rts
:s2_fail    rts
:s2_cont

* -- load the resident from disk FIRST -- see header. Nothing
* -- below has committed to anything yet, so a missing/short
* -- file or an exhausted io_buffer pool just falls straight
* -- through PRC_FAIL_A/rts, same shape as PRC_ALLC_BANK's own
* -- failure path two steps down. LOADS BYE_COMBO_LEN BYTES
* -- (2026-09-26 slice 2), not just BYE_BLOB_LEN --
* -- /MAUX/BYERES is now byeres.bin+byelaunch.bin
* -- CONCATENATED (Makefile) into one staged file, read here in
* -- ONE pass straight into $D100 (see byeres.equ's own
* -- BYE_COMBO_LEN comment) -- unconditional, even for a bare
* -- `bye`: the launch half then sits unused, which costs a few
* -- more read cycles and nothing else.
            jsr   PBY_LOAD_RES
            bcc   :resok
            rts                     ;PBY_LOAD_RES already called
                                    ;PRC_FAIL_A
:resok
* -- allocate the save bank, lazily, once, forever -- but a
* -- CACHED K_BYE_BANK is trusted only if PBY_CHK_STAMP still
* -- finds its own magic+bank-number stamp intact in that
* -- bank's own zero page (docs/BYE-SLICE1.md's accepted gap:
* -- an untagged held bank is invisible to LZ_RECLAIM today, but
* -- nothing proves it always will be, and this is the named
* -- trigger's own fix). A mismatch means the bank changed hands
* -- since bye last saw it -- forget the cached number and fall
* -- into the SAME allocation path the very first call takes.
            lda   K_BYE_BANK
            beq   :alloc
            sta   PBY_BANKARG
* -- BANKSEL select hoisted HERE from PBY_CHK_STAMP, 2026-09-30
* -- headroom round (docs/DEVFS-NOTES.md): A still holds the
* -- bank number, and BANKSEL is not an ALTZP touch (docs/
* -- KSEG.md rule 2) -- legal segment code, same reasoning as
* -- PRC_SEL_CRBNK's own move here in the 2026-09-27 round.
            sta   BANKSEL
            jsr   PBY_CHK_STAMP
* -- PRC_SEL_CRBNK + the match test moved HERE 2026-09-27
* -- (coordinator review, budget trim): neither touches ALTZP,
* -- so both are legal segment code -- PBY_CHK_STAMP itself now
* -- ends the instant its own ALTZP bracket closes, leaving A
* -- (0 = match) for the caller to test. A saved across
* -- PRC_SEL_CRBNK's own clobber via pha/pla, 2026-09-30 (docs/
* -- DEVFS-NOTES.md headroom round) -- cheaper here than reading
* -- a flat PBY_TMP cell back, and it let that cell's own final
* -- store go away (procbye.s).
            pha
            jsr   PRC_SEL_CRBNK
            pla
            beq   :havebank
            stz   K_BYE_BANK
:alloc      jsr   PRC_ALLC_BANK
            bcc   :gotbank
            rts                     ;PRC_ALLC_BANK already
                                    ;called PRC_FAIL_A
                                    ;(ERR_NOMEM)
:gotbank    sta   K_BYE_BANK
            sta   PBY_BANKARG
            sta   BANKSEL           ;hoisted from PBY_WR_STAMP,
                                    ;same reasoning as above
            jsr   PBY_WR_STAMP
            jsr   PRC_SEL_CRBNK
:havebank

* -- SAME shape, second save bank (the annex, 2026-09-26
* -- ruling): PBY_CHK_STAMP/PBY_WR_STAMP are generalized on
* -- PBY_BANKARG (see their own header) precisely so this block
* -- costs no new ALTZP bracket, only the ensure-and-branch
* -- logic itself.
            lda   K_BYE_BANK2
            beq   :alloc2
            sta   PBY_BANKARG
            sta   BANKSEL           ;hoisted from PBY_CHK_STAMP,
                                    ;2026-09-30 headroom round
            jsr   PBY_CHK_STAMP
* -- A (0=match) saved across PRC_SEL_CRBNK's clobber -- see the
* -- bank1 block's own comment above.
            pha
            jsr   PRC_SEL_CRBNK
            pla
            beq   :havebank2
            stz   K_BYE_BANK2
:alloc2     jsr   PRC_ALLC_BANK
            bcc   :gotbank2
            rts                     ;PRC_ALLC_BANK already
                                    ;called PRC_FAIL_A
                                    ;(ERR_NOMEM)
:gotbank2   sta   K_BYE_BANK2
            sta   PBY_BANKARG
            sta   BANKSEL           ;hoisted from PBY_WR_STAMP,
                                    ;2026-09-30 headroom round
            jsr   PBY_WR_STAMP
            jsr   PRC_SEL_CRBNK
:havebank2

* -- LOOP S4 (docs/LOOP-S2.md): nothing below can fail. A loop
* -- image is detached here -- $FF00 and DEVLST/DEVADR as ProDOS
* -- left them -- and a record is left for the `bye` tool to
* -- re-attach it when the tenant is gone. Called whether or not
* -- a loop is attached: with none it clears the record instead
* -- (KFIX11: stale 'LP' bytes made REATTACH attach garbage).
            jsr   LP_BYEDET
* -- KFIX2 4: forget every retained/live program tag. The tenant
* -- rewrites files with raw MLI calls (no PRC_CREAT/UNLINK/
* -- WRITE hook sees them) and a same-minute rewrite is
* -- invisible to the mtime compare, so a program the tenant
* -- rebuilt would respawn warm with its OLD text
* -- (lazyfree.s LZ_DROPALL).
            jsr   LZ_DROPALL

* -- patch OUR OWN caller's trapframe for A=0/success now, while
* -- BANKSEL/ALTZP still name it -- see header. PRC_BYE never
* -- fails past this point in this slice.
* -- PBY_PATCHFRM is FLAT (procbye.s) -- docs/KSEG.md rule 1's
* -- allowed case: a segment routine may `jsr` a flat routine
* -- that flips ALTZP internally, since it flips back before
* -- returning and the return address sits on the main stack.
* -- K_CALLER_SP load hoisted HERE, 2026-09-30 headroom round:
* -- X is unused at this point, so this is a pure flat-to-
* -- segment move (docs/DEVFS-NOTES.md).
            ldx   K_CALLER_SP
            jsr   PBY_PATCHFRM

* -- PUBLISH K_CALLER_SP INTO OUR OWN PCB's SAVEDSP FIELD.
* -- PCB_SAVEDSP is valid ONLY for a process that has been
* -- switched OUT (src/kernel/entry.s's own invariant, "valid
* -- only when K_SWITCH != 0") -- SCH_CREATE's default ($F9,
* -- item 11's synthesized-frame SP for a FRESH process,
* -- procfork.s) is the value still sitting there for a RUNNING
* -- process that has never been switched. SCH_RESUME (sched.s)
* -- dispatches THIS pid without ever switching it out first --
* -- it reads PCB_SAVEDSP via PCB_RD_FIELDS the same as
* -- SCH_START does for an ordinary switched-out process -- so
* -- without this write, SCH_DISPATCH's TXS+RTI would pull
* -- whatever stale frame happened to be at PCB_SAVEDSP (for a
* -- process that has run since boot without ever blocking or
* -- being preempted, that is still $F9: the ORIGINAL LAUNCH
* -- frame) instead of the real syscall frame this routine just
* -- patched above. MEASURED: exactly that bug, `bye` silently
* -- relaunched its own caller from its entry point instead of
* -- returning to it -- same shape as PRC_FORK's own child-SP
* -- fixup a few lines below SCH_CREATE's default in
* -- procfork.s, which exists for the identical reason (a forked
* -- child is not fresh either). Follows that file's own
* -- PPCB_WR_BYTE idiom rather than poking (K_PCB_PTR),y here by
* -- hand.
            lda   K_CURPID
            sta   P_PID
            lda   #PCB_SAVEDSP
            sta   P_TMP
            lda   K_CALLER_SP
            sta   P_TMP2
            jsr   PPCB_WR_BYTE

* -- quiesce: disarm the periodic interrupt device through the
* -- SAME K_HALT_TMR indirect PRC_HALT uses (0 in an image with
* -- no timer -- procfile3.s's own header explains why a direct
* -- jsr TMR_QUIESCE does not assemble everywhere).
            lda   K_HALT_TMR+1
            beq   :notimer
            jsr   :viatmr
:notimer

* -- capture what BYE_BACK will need to restore, into ordinary
* -- kernel memory -- all of it read BEFORE the poison exists,
* -- none of it read after (main is about to be destroyed).
            lda   $FFFE
            sta   PBY_SAVEVLO
            lda   $FFFF
            sta   PBY_SAVEVHI
            lda   RD80STORE
            and   #$80
            sta   PBY_SAVE80
            lda   K_BYE_ARM
            sta   PBY_ARMLO
            lda   K_BYE_ARM+1
            sta   PBY_ARMHI

* -- save the image: main $0200-$BEFF -> K_BYE_BANK, same
* -- offsets (48,384 bytes -- docs/BYE-SLICE1.md's table), then
* -- main's kernel ZP $0000-$00FF -> K_BYE_BANK $BF00-$BFFF.
* -- Both are plain BankCopy calls: a "main src, addr < $0200"
* -- call is safe for the ZP one because RAMRD does not govern
* -- the zero page at all, so it reads straight off main's own
* -- ZP with no flip needed (ALTZP is main throughout every
* -- syscall handler).
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #$00
            sta   K_BC_SRCADDR
            lda   #$02
            sta   K_BC_SRCADDR+1
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   #$00
            sta   K_BC_DSTADDR
            lda   #$02
            sta   K_BC_DSTADDR+1
            lda   K_BYE_BANK
            sta   K_BC_DSTBANK
            lda   #$00
            sta   K_BC_LEN
            lda   #BYE_IMG_PAGES
            sta   K_BC_LEN+1
            jsr   BankCopy

            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            stz   K_BC_SRCADDR
            stz   K_BC_SRCADDR+1
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   #$00
            sta   K_BC_DSTADDR
            lda   #BYE_ZP_DSTHI
            sta   K_BC_DSTADDR+1
            lda   K_BYE_BANK
            sta   K_BC_DSTBANK
            lda   #$00
            sta   K_BC_LEN
            lda   #$01
            sta   K_BC_LEN+1
            jsr   BankCopy

* -- 2026-09-26 ruling: save the annex too -- bank 0 $0200-$BFFF
* -- (48,640 bytes, ANX_PAGES=190 pages) -> K_BYE_BANK2, same
* -- offsets. UNCONDITIONAL -- SCH_DISPATCH reads the PCB table
* -- and every other kernel array out of bank 0 with BANKSEL=0
* -- regardless of whether /RAM is ever reconnected below.
* -- VERIFIED, not assumed (grepped every ALTZPAUX bracket in
* -- this tree): nothing ever selects BANKSEL=0 while ALTZP=aux
* -- -- bank 0 is never a process (entry.s's own K_CURBANK
* -- comment, sched.s), so its own $0000-$01FF and language card
* -- need no page-1-style treatment; this ONE BankCopy is the
* -- whole save. ANX_PAGES is equ'd at the top of this file
* -- (alongside BYE_IMG_PAGES) -- NOT here: an `equ` is itself a
* -- global label in merlin32, and one placed mid-routine ends
* -- the local-label ZONE right there, stranding every `:local`
* -- both before it (like :viatmr's own use a few lines up) and
* -- after it (like :viatmr's OWN DEFINITION near this routine's
* -- end) on opposite sides of a boundary neither meant to
* -- create -- measured directly: `jsr :viatmr` failed to decode
* -- with exactly this equ sitting between the two.
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            lda   #$00
            sta   K_BC_SRCADDR
            lda   #$02
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK              ;bank 0 -- the annex
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   #$00
            sta   K_BC_DSTADDR
            lda   #$02
            sta   K_BC_DSTADDR+1
            lda   K_BYE_BANK2
            sta   K_BC_DSTBANK
            lda   #$00
            sta   K_BC_LEN
            lda   #ANX_PAGES
            sta   K_BC_LEN+1
            jsr   BankCopy

* -- reconnect /RAM (TN #26, 2026-09-26 ruling: a suspend IS a
* -- quit from the tenant's side) ONLY if it was present at
* -- launch. BANKSEL/RAMRD/RAMWRT are main here (BankCopy's own
* -- exit state, just above) -- PRC_RAMRECONN needs that, since
* -- it pokes ProDOS's global page, still inside RAMRD/RAMWRT's
* -- $0200-$BFFF span.
* --
* -- FORMAT DOES NOT HAPPEN HERE -- deviation from the first
* -- draft, MEASURED, not stylistic. The TRM's own driver-level
* -- recipe (JSR the reinstalled vector with the $42-$47
* -- contract) was tried first and HUNG the round trip: the
* -- driver's own internal work left RAMRD/RAMWRT pointed at aux
* -- bank 0, and the very next instruction fetch back in THIS
* -- routine -- ordinary $0200-$BFFF kernel code, RAMRD-governed
* -- for fetch -- misfired into the (freshly written, mostly
* -- zero) annex instead of main, parking in a BRK avalanche.
* -- Confirmed with regs/disasm/softswitches on the parked
* -- machine: PC in the $2000s, RAMRD=aux, RAMWRT=aux,
* -- ramworks_bank=0. Writing the volume directly (byeres.s's
* -- BYE_LEAVE, LC-resident, immune to RAMRD by construction --
* -- the same fact that already lets BYE_LEAVE/BYE_BACK toggle
* -- RAMRD/RAMWRT freely) needs no call into driver code at all,
* -- so it cannot reopen that window -- see that file for the
* -- write itself, gated on BB_HADRAM (stamped below).
            lda   K_HAD_RAM
            beq   :noram
            jsr   PRC_RAMRECONN
:noram

* -- third save: main $0100-$017F (128 bytes) -> K_BYE_BANK's
* -- OWN aux $0180-$01FF -- the SAME ALTZP-governed "$0000-$01FF
* -- gap" the stamp already proved untouched by every BankCopy
* -- in this mechanism, not the save-bank's main-image window.
* -- BankCopy cannot reach it at all (BC_KIND_BANK goes through
* -- BANKSEL+RAMRD/RAMWRT, which govern $0200-$BFFF only), so
* -- this used to be one flat call, PBY_SAVE_P1 -- SPLIT
* -- 2026-09-27 (coordinator review, budget trim): the STAGE
* -- half
* -- (main $0100-$017F into PBY_P1BUF) touches no ALTZP at all
* -- --
* -- ordinary main-memory reads/writes, legal segment code -- so
* -- it moved HERE; only the WRITE half (the actual ALTZP flip
* -- into K_BYE_BANK's aux $0180-$01FF) needs to stay flat, as
* -- PBY_WR_P1 (rule 1's allowed case). This ALSO retires the
* -- old
* -- "$BE00-$BE7F is a deliberate overlap with the main-image
* -- save's own tail" story: the OFT lending store's slot 15
* -- ($BDFC-$BE3F) and PRC_CANON ($BE40-$BE80) both live in MAIN
* -- at exactly that address range and are real, persistent
* -- kernel state -- a `bye` round trip was silently destroying
* -- a
* -- parked file's saved path and seek mark, confirmed
* -- empirically (a 15-file OFT probe showed slot 15's bytes
* -- stomped by the restore). aux $0200-$BFFF is now the saved
* -- main image and NOTHING else.
            ldy   #0
:p1stage    lda   $0100,y
            sta   PBY_P1BUF,y
            iny
            cpy   #$80
            bne   :p1stage
* -- K_BYE_BANK select, the loop's Y=0 reset and the tail call
* -- to PRC_SEL_CRBNK all hoisted HERE from PBY_WR_P1,
* -- 2026-09-30 headroom round: none touch ALTZP, legal segment
* -- code (docs/DEVFS-NOTES.md).
            lda   K_BYE_BANK
            sta   BANKSEL
            ldy   #0
            jsr   PBY_WR_P1
            jsr   PRC_SEL_CRBNK

* -- the resident is already installed at $D100 -- PBY_LOAD_RES
* -- did that, first, before any of the above. RE-SELECT Apple
* -- bank 2 write-enabled here anyway rather than trust it to
* -- have survived the BankCopy calls above untouched: cheap
* -- insurance (4 bytes), not a measured hazard -- none of
* -- BankCopy/PRC_ALLC_BANK/PPCB_WR_BYTE touch $C080-$C08F
* -- today, but the stamp below is the one write that can never
* -- be allowed to land in the wrong LC bank.
            lda   LCBANK1_RAM
            lda   LCBANK1_RAM

* -- stamp the six data cells the resident cannot know at its
* -- own assembly time (see header).
            lda   K_BYE_BANK
            sta   BYE_BANKNO_A
            lda   PBY_SAVEVLO
            sta   BYE_SAVEVLO_A
            lda   PBY_SAVEVHI
            sta   BYE_SAVEVHI_A
            lda   PBY_SAVE80
            sta   BYE_SAVE80_A
            lda   PBY_ARMLO
            sta   BB_ARMVEC_A
            lda   PBY_ARMHI
            sta   BB_ARMVEC_A+1
* -- targets BYE_TTYRES (tty7.s), not SCH_RESUME directly,
* -- as of 2026-09-27 (docs/BYE-SLICE1-NOTES.md) -- a one-hop
* -- trampoline that reasserts the console's own display before
* -- falling into SCH_RESUME. Same 10-byte stamp cost as always;
* -- only the symbol changed.
            lda   #<BYE_TTYRES
            sta   BB_RESVEC_A
            lda   #>BYE_TTYRES
            sta   BB_RESVEC_A+1

* -- 2026-09-26: the second bank's number, K_HAD_RAM's own value
* -- (gates BYE_BACK's redisconnect call), and PRC_RAMREDISC's
* -- real address -- same "this separate assembly cannot know a
* -- kernel address at its own assembly time" reason as the six
* -- cells just above.
            lda   K_BYE_BANK2
            sta   BYE_BANKNO2_A
            lda   K_HAD_RAM
            sta   BB_HADRAM_A
            lda   #<PRC_RAMREDISC
            sta   BB_RAMDVEC_A
            lda   #>PRC_RAMREDISC
            sta   BB_RAMDVEC_A+1

* -- KSEG (docs/KSEG.md): KSEG_RELOAD's real address, same
* -- cross-assembly reason as the two stamps just above --
* -- byeres.s's own BB_KSGCALL thunk jsrs through this vector,
* -- right before the tick is re-armed, to reload the segment
* -- (byelaunch.s included) before ANY segment call.
            lda   #<KSEG_RELOAD
            sta   BB_KSGVEC_A
            lda   #>KSEG_RELOAD
            sta   BB_KSGVEC_A+1

* -- SLICE 2 (docs/BYE.md "Slice 2 launch"): BB_TENANT
* -- (byeres.s) is ALWAYS stamped, even 0 for a bare `bye` --
* -- PBY_LOAD_RES
* -- (above) already loaded byelaunch.s's own bytes into LC bank
* -- 2 UNCONDITIONALLY as part of the one combined blob, but a
* -- `ds 1` cell is zero only in the FILE on disk, never
* -- re-zeroed at load, so a PREVIOUS tenant `bye`'s stamp would
* -- otherwise survive into a later bare `bye`. BL2_PATH_A (the
* -- ALREADY-VALIDATED tenant pathname) is copied a few lines
* -- below, from a FRESH re-copyin rather than the top-of-
* -- routine PRC_PATHBUF (2026-09-27 fix, see that comment), and
* -- only when a tenant was named -- BB_TENANT gates BYE_LEAVE's
* -- own jump to byelaunch.s, so nothing ever reads a bare
* -- `bye`'s stale BL2_PATH bytes. Bank 2 is
* -- still selected write-enabled from the six-cell stamp block
* -- above; nothing between there and here touches $C080-$C08F.
*
* NO BL2_UTOWN FLAG (a deviation from an earlier draft, MEASURED
* not stylistic -- see docs/BYE-SLICE1-NOTES.md): computing
* "does the UltraTerm own the glass single-head?" here cost ~19
* B this file's own PT_HOLD headroom (77 B before this slice)
* could not spare. byelaunch.s drops UT_PAGE_CTL's VIDSEL bit
* UNCONDITIONALLY instead -- harmless when no card is present or
* the card was never initialized, and also releases a DUALHEAD
* card's second-monitor passthrough for the tenant's run (not
* restored on resume this slice -- a named, untested gap for a
* UT-booted machine; `vidmode hq` recovers it by hand).
*
* NO PBY_HASTEN CELL EITHER (a second measured deviation): PRC_
* PARM+1/+2 (the path pointer) are PROVEN untouched from the top
* of this routine to here (grepped the whole span -- nothing
* between reuses PRC_PARM), so BB_TENANT is computed FRESH from
* them rather than carried in a dedicated flag -- BYE_LEAVE
* (byeres.s) only ever tests BB_TENANT for zero/nonzero, so the
* raw OR result (not normalized to exactly 1) is exactly as
* good, and this way costs 4 B less than a separate cell +
* stz/inc pair.
*
* BL2_PATH_A (BL2_PSTG, byelaunch.s) is copied HERE, from a
* FRESH re-copyin, not from the top-of-routine PRC_PATHBUF
* (2026-09-27 fix, MEASURED): PBY_LOAD_RES, called between the
* top and here, overwrites PRC_PATHBUF with its own fixed
* "/MAUX/BYERES" literal as ITS OWN scratch pathname -- a live
* launch's OPEN read that string back and failed MLI $40,
* INVALID_PATHNAME_SYNTAX, on a syntactically fine tenant path.
* Re-running PCPY_MLI_PATH costs a few bytes but is the SAME
* copyin against the SAME untouched PRC_PARM+1/+2 pointer that
* already succeeded once at the top -- nothing between there and
* here can make it fail differently, so its carry is not
* re-checked (a second, deep failure-unwind path here would cost
* more than this file's headroom allows for a call that cannot
* newly fail). This also fixes a same-day wrong turn: a copy
* attempted from the TOP of this routine landed in whatever bank
* happened to be selected there (not guaranteed to be bank 2),
* where HERE bank 2 is guaranteed write-enabled -- the six-cell
* stamp block above already reselected it, and nothing since has
* touched $C080-$C08F.
* -- BL2_PSTG is an ORDINARY LINKED SYMBOL now (2026-09-27,
* -- docs/KSEG.md) -- byelaunch.s is `put` into this same
* -- assembly, not a separate one, so no more hand-pinned _A
* -- constant is needed here.
            lda   PRC_PARM+1
            ora   PRC_PARM+2
            sta   BB_TENANT_A
            beq   :s2_nolnch2
            jsr   PCPY_MLI_PATH
            ldy   #64
:s2_cppath  lda   PRC_PATHBUF,y
            sta   BL2_PSTG,y
            dey
            bpl   :s2_cppath
:s2_nolnch2

            jmp   BYE_LEAVE_A

*-- The 65C02 has no `jsr (abs)`, so the call goes through a
*-- one-instruction thunk: jsr pushes the return, the indirect
*-- jmp transfers, and the target's own rts lands after the jsr
*-- (same idiom as procfile3.s's PRC_HALT :viatmr).
:viatmr     jmp   (K_HALT_TMR)
*---------------------------------------------------------------
* PRC_RAMRECONN -- the exact inverse of PRC_RAMDIS's own
* disconnect (procmli.s), TN #26's reinstall (2026-09-26 ruling,
* docs/BYE.md -- a `bye` suspend IS a quit from the tenant's
* side). Called from PRC_BYE above, kernel/main context, ONLY
* when K_HAD_RAM is set. Lives HERE, not in procmli.s, so its
* bytes cost only MAUXPLAY.SYSTEM's own PT_HOLD headroom -- see
* procmli.s's own comment, right after PRC_RAMDIS, for why.
* Reads RD_DEVCNT/RD_DEVLST/RD_RAMSLT/K_RAM_DEV/K_RAM_VEC
* directly -- plain `equ`s and `ds` cells declared in procmli.s,
* visible tree-wide within this one assembly, the same way this
* file already reads K_HAD_RAM. The ProDOS 8 TRM's own
* reinstallation recipe (artifact d82965d8..., "Reinstalling
* /RAM") puts the device back as DEVLST's FIRST entry, not
* wherever it originally sat -- shift every existing entry right
* by one (from the top down, so nothing is overwritten before it
* is read), write K_RAM_DEV at index 0, restore K_RAM_VEC into
* the slot-3/drive-2 vector, increment RD_DEVCNT. Runs with
* RAMRD/RAMWRT=main (guaranteed by the annex-save BankCopy's own
* exit state, just above) -- RD_DEVLST/RD_DEVCNT are in ProDOS's
* global page, but that page is still governed by RAMRD/RAMWRT
* like the rest of $0200-$BFFF. Clobbers A/Y.
*---------------------------------------------------------------
PRC_RAMRECONN
            ldy   RD_DEVCNT
            beq   :ins0
:shiftup    lda   RD_DEVLST-1,y
            sta   RD_DEVLST,y
            dey
            bne   :shiftup
:ins0       lda   K_RAM_DEV
            sta   RD_DEVLST
            lda   K_RAM_VEC
            sta   RD_RAMSLT
            lda   K_RAM_VEC+1
            sta   RD_RAMSLT+1
            inc   RD_DEVCNT
            rts

*---------------------------------------------------------------
* PRC_RAMREDISC -- undo PRC_RAMRECONN, on the way back. /RAM is
* always at DEVLST[0] after a reconnect -- nothing else in this
* window touches DEVLST -- so no rescan is needed, unlike
* PRC_RAMDIS's own boot-time :scan. Same TN #8 ON_LINE-for-$28
* erase-VCB call and no-device vector patch as PRC_RAMDIS's own
* :found body (procmli.s). Called from byeres.s's BYE_BACK via
* a stamped vector, ONLY when K_HAD_RAM was set, BEFORE the tick
* is re-armed (learning:01M1B7W9Z76TMAKP7YPG63F7WQ: a tick taken
* while /RAM's driver has RAMRD on aux wedges the machine).
* Clobbers A/Y.
*---------------------------------------------------------------
PRC_RAMREDISC
            ldy   #0
:shift      lda   RD_DEVLST+1,y
            sta   RD_DEVLST,y
            beq   :patch
            iny
            bne   :shift
:patch      lda   RD_RAMSLT
            sta   K_RAM_VEC
            lda   RD_RAMSLT+1
            sta   K_RAM_VEC+1
            lda   RD_NODEV
            sta   RD_RAMSLT
            lda   RD_NODEV+1
            sta   RD_RAMSLT+1
            dec   RD_DEVCNT
* -- PMLI_ONLN_CL (procmli.s), not inline `jsr MLI` -- docs/
* -- KSEG.md rule 3 (2026-09-27 fix, coordinator review): this
* -- routine is now segment-resident, and the MLI reads inline
* -- call bytes under the OTHER bank (F4) -- a raw `jsr MLI`
* -- here
* -- would read garbage. jsr+rts, not a tail `jmp`, to keep the
* -- "return with rts to the trampoline" contract unambiguous
* -- even though PMLI_ONLN_CL's own rts would land correctly
* -- either way (it is an ordinary two-way call, not an exit
* -- like
* -- PRC_FAIL_A/KRN_EXIT).
* -- RDS_PARMS+1 SET HERE, EXPLICITLY, 2026-09-30
* -- (docs/DEVFS.md):
* -- RDS_PARMS is now SHARED with SYS_ONLINE's delegate
* -- (procfile4.s PRC_ONLINE), which overwrites this same byte
* -- with a caller's requested unit_num on every `ls /dev`/`ls
* -- /`.
* -- This call used to trust the compile-time initializer ($B0)
* -- had never moved; it no longer can.
            lda   #RD_RAMUNIT
            sta   RDS_PARMS+1
            jsr   PMLI_ONLN_CL
            rts

*---------------------------------------------------------------
* PBY_LOAD_RES -- open /MAUX/BYERES and read its BYE_BLOB_LEN
* (768) bytes straight into Apple LC bank 2 at BYE_ORG. MOVED
* HERE FROM procbye.s 2026-09-27 (headroom recovery, coordinator
* review): a thin wrapper over KSEG_LOAD (procfile5.s, flat) --
* the same routine that loads the KSEG cold segment at boot and
* after every tenant return. Nothing here flips ALTZP, selects
* an LC bank, embeds inline MLI bytes or declares data (rules
* 1/2/3/4 all clear), and its only caller, PRC_BYE above, is
* already segment-resident -- an ordinary same-bank `jsr` in
* both directions, no trampoline needed either way.
*
* Called FIRST by PRC_BYE, before anything is allocated or
* committed -- see that routine's header. PRC_PATHBUF (the
* shared canonical-path scratch every open() rebuilds) is
* overwritten with this fixed absolute path, deliberately: `bye`
* does not depend on cwd, and nothing after this call needs
* PRC_PATHBUF's old contents.
*
* OUT: carry CLEAR (BYE_ORG installed, LC bank 2 write-enabled
* and left selected) or carry SET with the real error already
* reported via PRC_FAIL_A -- a missing file, a short/wrong-size
* one, an exhausted io_buffer pool and a real MLI error all
* report identically, and PRC_BYE's caller just `rts`s with
* nothing to unwind.
*
* BYE_RES_PTXT (procbye.s, flat) is a count-prefixed literal in
* FLAT memory -- KSEG_LOAD's own path-pointer redirect opens it
* directly, no local path copy.
*---------------------------------------------------------------
PBY_LOAD_RES
            lda   #<BYE_RES_PTXT
            sta   PML_OPN_PARMS+MLI_PATHLO
            lda   #>BYE_RES_PTXT
            sta   PML_OPN_PARMS+MLI_PATHHI
            lda   #>BYE_ORG
            sta   KL_DESTHI
            lda   #3                       ;768 B = 3 pages,
            sta   KL_MAXPG                 ;exactly BYE_BLOB_LEN
            jsr   KSEG_LOAD
            bcc   :pblok
:pblfail    jsr   PRC_FAIL_A               ;A already the real
                                            ;error (KSEG_LOAD's
                                            ;own contract, or
                                            ;ERR_INVAL below)
            sec
            rts

* -- a resident that is not EXACTLY 3 pages (768 B) is corrupt
* -- -- KSEG_LOAD itself is happy with any shorter page count
* -- (the right answer for the segment, which is genuinely
* -- variable),
* -- so the exact-match check belongs here, at the caller that
* -- knows byeres.bin's real fixed size. Shares :pblfail's own
* -- tail (budget trim, coordinator review).
:pblok      lda   KL_PGCNT
            cmp   #3
            beq   :pblsz
            lda   #ERR_INVAL
            bra   :pblfail
:pblsz      clc
            rts
