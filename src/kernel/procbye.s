*---------------------------------------------------------------
* procbye.s -- SYS_BYE (call 23): save+destroy+restore round
* trip through a real ProDOS MLI QUIT (docs/BYE-SLICE1.md).
* PRC_BYE owns the machinery; the resident that actually
* survives the destruction is byeres.s, assembled standalone at
* $D100 (still a SEPARATE assembly -- merlin32 has no linker, so
* a `put` shares one symbol table and a second `merlin32`
* invocation does not).
*
* THE RESIDENT IS NOT EMBEDDED IN THIS IMAGE (2026-09-25). It
* used to be `putbin`'d into every kernel image that wanted
* `bye` -- 768 always-resident bytes for a blob that runs a few
* thousand cycles per call, and only while maux itself is not
* even running. That is backwards: `bye` is the rarest syscall
* this kernel has, and the resident is DATA, not kernel code --
* a blob to copy into the language card, nothing more. It now
* lives on disk at `/MAUX/BYERES` (build_play_image.py stages
* build/byeres.bin there) and PBY_LOAD_RES (below) opens, reads
* and installs it FIRST, before PRC_BYE allocates anything or
* commits to anything irreversible -- a missing or short file
* fails exactly like PRC_ALLC_BANK's own allocation failure,
* with nothing to unwind. This is what bought back the 768
* image bytes that pushed MAUXPLAY.SYSTEM's end past the
* PT_HOLD ceiling `check_kernel_images.py`'s
* `check_pt_hold_headroom()` gates (check-nas-librel's own boot
* hang traced to the same overrun -- NOTES-BYE.md has the
* numbers).
*
* THE BANK. K_BYE_BANK is allocated LAZILY, on the first `bye`,
* through PRC_ALLC_BANK, then held FOREVER -- never tagged
* (LZ_RETAIN, called only from PRC_FREE_BANK), never freed. Read
* LZ_RECLAIM (src/kernel/lazyfree.s) before trusting that: it
* only ever reclaims a slot whose LZ_STATE is LZ_HELD, and the
* ONLY writer of that state is LZ_RETAIN -- an untagged bank is
* invisible to it, by construction, not by convention. Zero
* (K_BYE_BANK's own "not yet allocated" sentinel, zeroed at boot
* in entry2.s alongside K_HALT_TMR/K_BYE_ARM) is never a live
* bank number -- bank 0 is main memory, never a process
* (sched.s's own K_CURBANK comment says so).
*
* THE RETURN FRAME. PRC_BYE patches its OWN caller's trapframe
* to A=0/success BEFORE doing anything destructive, using the
* same FRAME_A/FRAME_P mechanism entry.s's KRN_EXIT uses for
* every ordinary syscall return. It has to happen here, early,
* because nothing after this point returns through KRN_EXIT --
* SCH_RESUME (sched.s) resumes the caller's frame directly, and
* everything between here and there is a real MLI QUIT that
* abandons this routine's own call chain (the JSR that reached
* PRC_BYE is never RTS'd back through).
*
* WHAT CROSSES INTO THE RESIDENT. Six stamped data cells
* (byeres.equ's BYE_BANKNO_A/BYE_SAVEVLO_A/BYE_SAVEVHI_A/
* BYE_SAVE80_A/BB_ARMVEC_A/BB_RESVEC_A) -- the save-bank number,
* the $FFFE/$FFFF bytes captured before byeres.s's own poison
* fill (see that file's DEVIATION note on why MLI_VCPG_BOOT is
* not used -- it is not part of any of the 32 production kernel
* images), the 80STORE bit, a COPY of K_BYE_ARM's current value
* (byeres.s cannot name that kernel symbol -- it is a separate
* assembly with its own symbol table), and SCH_RESUME's real
* address (ditto).
*
* byeres.equ is put by the TOP-LEVEL harness (playtest.s etc.),
* alongside kdisp.equ -- NOT here. Measured, not assumed: a
* `put byeres.equ` line placed here (inside a module that is
* itself reached via `put`) silently failed to load the file at
* all -- BYE_ORG etc. came back undefined, no error, no entry
* for byeres.equ anywhere in the listing. Every equ file every
* OTHER kernel module in this tree needs is put by the
* top-level harness for the same reason (kdisp.equ, bankcopy.
* equ, entry.frame.equ, ... -- none of the kernel/*.s modules
* put their own).
*---------------------------------------------------------------

*---------------------------------------------------------------
* PRC_BYE_INIT retired 2026-09-27 (coordinator review, budget
* trim): it had exactly one caller (playtestb.s's boot sequence,
* right after TIMER_PROBE) and was four instructions plus a
* `rts` -- inlined there instead of `jsr`'d. It used to
* overwrite
* entry.s's K_BYE_VEC (defaulted by entry2.s's INSTALL_COPY to
* BYE_UNWIRE) with K_BYE_TRAMP's address (below), so kdisp.s's
* SYS_BYE slot -- wired to PRC_BYE_STUB, not PRC_BYE directly --
* actually reaches PRC_BYE, now segment-resident (src/kernel/
* kbye.s). See entry.s's K_BYE_VEC comment for the full reason
* this indirection exists at all, and K_BYE_TRAMP's own comment
* below for why it, not PRC_BYE's address, is what gets stamped
* (docs/KSEG.md, coordinator review: "PRC_BYE MOVES").
*
* BYE_IMG_PAGES/BYE_ZP_DSTHI/ANX_PAGES moved to kbye.s with
* PRC_BYE, which is their only user.
*---------------------------------------------------------------

*---------------------------------------------------------------
* K_BYE_TRAMP -- flat, common to any image that links procbye.s
* (only playtest.s today). PRC_BYE_STUB (entry.s) reaches this
* via a TAIL jump (`jmp (K_BYE_VEC)`, no new return address
* pushed), so this is entered exactly as if the ORIGINAL caller
* had done `jsr K_BYE_TRAMP` -- and K_BYE_TRAMP's own body is an
* ordinary KSEG_CALL site, so the whole chain (dispatcher -> jsr
* PRC_BYE_STUB -> jmp K_BYE_TRAMP -> jsr KSEG_CALL -> jsr
* PRC_BYE)
* nests correctly: PRC_BYE's ERROR paths unwind back through
* KSEG_CALL's own bank-restoring `rts`, then this routine's own
* `rts`, to the ORIGINAL caller. PRC_BYE's SUCCESS path never
* reaches this `rts` at all (it leaves maux -- see kbye.s's own
* header) and abandons every frame on this stack, harmlessly.
*---------------------------------------------------------------
K_BYE_TRAMP
            jsr   KSEG_CALL
            da    PRC_BYE
            rts

*---------------------------------------------------------------
* PBY_PATCHFRM -- flat helper for PRC_BYE's own inline ALTZP
* bracket (docs/KSEG.md rule 1's allowed case: a segment routine
* may `jsr` a FLAT routine that flips ALTZP internally, since it
* flips back before returning and the return address sits on the
* main stack -- not the aux one). Patches the CALLING process's
* own trapframe (FRAME_A=0, FRAME_P carry clear) for success,
* using K_CALLER_SP as the index -- same XBANK(stack) shape as
* entry.s's KRN_EXIT. Clobbers A, X.
*
* `ldx K_CALLER_SP` moved to the CALLER, 2026-09-30 (same
* headroom round as the three routines above): X is unused at
* the one call site (kbye.s) right before `jsr PBY_PATCHFRM`, so
* this is a pure flat-to-segment move. IN (now): X already holds
* K_CALLER_SP.
*---------------------------------------------------------------
PBY_PATCHFRM
            stz   ALTZPAUX
* XBANK(stack): patching OUR OWN CALLER's trapframe, in its own
* stack page -- same shape as entry.s's KRN_EXIT.
            stz   FRAME_A,x
            lda   FRAME_P,x
            and   #$FE              ;clear carry -- success
            sta   FRAME_P,x
            sta   ALTZPMAIN
            rts


* -- BYE_STAMP_OFF is a plain zero-page offset WITHIN K_BYE_BANK
* -- itself -- aux $0000-$01FF, the one region no BankCopy call
* -- in this file's own save/restore path ever reaches (those
* -- calls all go through BANKSEL+RAMRD/RAMWRT, which govern
* -- $0200-$BFFF only; $0000-$01FF is ALTZP-governed, docs/
* -- BYE-SLICE1.md's own table). Two bytes: a magic tag, then
* -- the bank's own number -- the number closes the one case the
* -- magic alone cannot (a bank that once carried bye's stamp
* -- and has since changed hands to something else entirely).
BYE_STMPMAGIC equ  $5B
BYE_STAMP_OFF equ  $F8

*---------------------------------------------------------------
* PBY_CHK_STAMP -- verify that a save bank's own stamp still
* reads back as bye's. IN: PBY_BANKARG = the bank number to
* check -- GENERALIZED 2026-09-26 (was hardcoded to K_BYE_BANK)
* so K_BYE_BANK2 (the annex's own save bank) can share this same
* routine and pay for no second ALTZP bracket. Selects it, flips
* ALTZP to aux JUST LONG ENOUGH to read the two stamp bytes out
* of ITS OWN zero page, then flips back. NO
* jsr/rts/stack-touching
* op executes while ALTZP=aux: the hardware stack would silently
* move to the wrong bank's page 1. Safe here because
* FFP_SYSC_ENT's own sei is still in force (PRC_BYE never
* re-enables interrupts before this point), so nothing can
* preempt between the two flips. NO BRANCH inside the bracket
* either (check-altzp's own second rule: a close a branch can
* jump over is not a close) -- both stamp bytes are folded into
* A with EOR/ORA, straight line. OUT: A = 0 if the stamp matches
* (this bank is still bye's own), nonzero if not (the caller
* must re-allocate). `sta ALTZPMAIN` and `rts` do not touch A,
* so the final ORA result survives unmodified to the caller.
* Clobbers A.
*
* PRC_SEL_CRBNK (restoring BANKSEL to the caller's own bank --
* the
* ambient invariant every syscall handler runs under) and the
* zero/nonzero test moved to the CALLER 2026-09-27 (coordinator
* review, budget trim): neither touches ALTZP, so both are legal
* segment code (kbye.s, both call sites) -- this routine used to
* do them itself and return carry, which cost 11 B
* of flat image for logic that runs identically whichever bank
* the caller is checking.
*
* `sta BANKSEL` (the SELECT half, not an ALTZP touch) moved to
* the CALLER too, 2026-09-30 (docs/DEVFS-NOTES.md headroom
* round): the caller already has the bank number in A right
* before `sta PBY_BANKARG` at both call sites, so this costs
* only one more flat-glue byte there (`sta BANKSEL`) against 6 B
* removed here (`lda PBY_BANKARG`/`sta BANKSEL`, both absolute).
* IN (now): PBY_BANKARG set AND BANKSEL already selected by the
* caller.
*
* OUTPUT CHANNEL CHANGED FROM PBY_TMP TO A, same round: the
* SECOND `sta PBY_TMP` this routine used to end with existed
* only because the caller's OWN `jsr PRC_SEL_CRBNK` (between
* this routine's return and the match test) clobbers A --
* PBY_TMP was memory that survived where A could not. The
* caller now saves A across that one call with `pha`/`pla`
* instead (2 B, segment code, cheaper than reading a flat cell
* back), so this routine's final ORA result can simply be A on
* return -- removing the redundant final store (3 B flat).
*---------------------------------------------------------------
PBY_CHK_STAMP
            sta   ALTZPAUX
* XBANK(zp): reading the bank's OWN stamp, in its own zero page
* -- the whole point of this bracket.
            lda   BYE_STAMP_OFF
            eor   #BYE_STMPMAGIC
            sta   PBY_TMP
            lda   BYE_STAMP_OFF+1
            eor   PBY_BANKARG
            ora   PBY_TMP
            sta   ALTZPMAIN
            rts

*---------------------------------------------------------------
* PBY_WR_STAMP -- stamp a FRESH save bank right after
* PRC_ALLC_BANK hands it back. IN: PBY_BANKARG = the bank number
* to stamp -- same generalization as PBY_CHK_STAMP above, same
* ALTZP-flip discipline; no out/carry contract needed, the
* caller never branches on it. Clobbers A.
*
* PRC_SEL_CRBNK moved to the CALLER 2026-09-27 (coordinator
* review, budget trim -- same reasoning as PBY_CHK_STAMP's own
* header): it does not touch ALTZP, so it is legal segment code.
*
* `sta BANKSEL` moved to the CALLER too, 2026-09-30 (same
* headroom round as PBY_CHK_STAMP above, same reasoning: A
* already holds the bank number there). IN (now): PBY_BANKARG
* set AND BANKSEL already selected by the caller.
*---------------------------------------------------------------
PBY_WR_STAMP
            sta   ALTZPAUX
            lda   #BYE_STMPMAGIC
            sta   BYE_STAMP_OFF
            lda   PBY_BANKARG
            sta   BYE_STAMP_OFF+1
            sta   ALTZPMAIN
            rts

*---------------------------------------------------------------
* PBY_WR_P1 -- write PBY_P1BUF (already staged by kbye.s's own
* PRC_BYE -- see its call site) into K_BYE_BANK's OWN aux
* $0180-$01FF -- the ALTZP-governed "$0000-$01FF gap" the stamp
* already proved untouched by every BankCopy in this mechanism
* (BC_KIND_BANK goes through BANKSEL+RAMRD/RAMWRT, which govern
* $0200-$BFFF only). SPLIT from the former PBY_SAVE_P1
* 2026-09-27
* (coordinator review, budget trim): the STAGE half (main
* $0100-$017F into PBY_P1BUF) touches no ALTZP at all, so it
* moved into PRC_BYE itself (kbye.s, segment-resident, docs/
* KSEG.md rule 1's allowed case: a segment routine may `jsr` a
* flat routine that flips ALTZP internally). Only this write
* half
* needs to stay flat. One straight-line loop, no jsr/rts/push
* inside the ALTZP bracket -- same discipline as PBY_CHK_STAMP/
* PBY_WR_STAMP -- and needs no XBANK comment at all: writes to
* ALTZP-governed memory are not flagged (check_altzp.py's own
* rule), only reads are, and this routine never READS an
* ALTZP-governed address while ALTZP=aux (PBY_P1BUF is ordinary
* main memory, unaffected either way). Clobbers A, Y.
* `lda K_BYE_BANK`/`sta BANKSEL` moved to the CALLER, 2026-09-30
* (same headroom round as PBY_CHK_STAMP/PBY_WR_STAMP above): A
* is not already loaded with K_BYE_BANK at this call site (the
* p1stage loop above it uses A last), so the caller pays for
* both instructions -- still a pure flat-to-segment move, since
* the caller (kbye.s) is segment-resident. IN (now): BANKSEL
* already selects K_BYE_BANK.
* `ldy #0` and the tail-call to PRC_SEL_CRBNK also moved to the
* CALLER, 2026-09-30 (same headroom round): neither touches
* ALTZP, and Y is free at the one call site right after the
* p1stage loop ends. IN (now): Y=0 on entry; the caller re-
* selects its own bank itself after this routine returns.
*---------------------------------------------------------------
PBY_WR_P1
* -- flip to aux JUST LONG ENOUGH to write the staged bytes
* -- (already in PBY_P1BUF -- kbye.s's own job now) into K_BYE_
* -- BANK's own $0180-$01FF (BANKSEL already selects it, Y=0).
            sta   ALTZPAUX
:wr         lda   PBY_P1BUF,y
            sta   $0180,y
            iny
            cpy   #$80
            bne   :wr
            sta   ALTZPMAIN
            rts

* -- ordinary main memory (like PBY_SAVEVLO etc. below), NOT
* -- zero page -- PBY_CHK_STAMP writes it while ALTZP=aux and
* -- reads it back after flipping to main, and RAMRD/RAMWRT stay
* -- main throughout, so this cell is the SAME physical byte on
* -- both sides of the flip (the K_CALLER_SP idiom entry.s
* -- documents at its own cross-flip cells).
PBY_TMP     ds    1
* -- the bank number PBY_CHK_STAMP/PBY_WR_STAMP act on -- set by
* -- the caller before every jsr, same cross-flip-safe idiom as
* -- PBY_TMP above (ordinary main memory, RAMRD/RAMWRT stay main
* -- throughout so it reads back unchanged on either side of the
* -- ALTZP flip).
PBY_BANKARG ds    1
* -- the page-1 bounce buffer -- ordinary main memory, staged by
* -- kbye.s's own PRC_BYE from main's real page 1 BEFORE any
* -- ALTZP flip, then copied into K_BYE_BANK's aux $0180-$01FF
* -- by
* -- PBY_WR_P1 once selected. ALIASED onto PMLI_XFER_BUF
* -- 2026-09-27 (docs/KSEG.md, coordinator review, "PBY_P1BUF")
* -- rather than a separate 128 B `ds`: the stage+write pair
* -- runs
* -- from PRC_BYE, always AFTER PBY_LOAD_RES's own use of
* -- PMLI_XFER_BUF has completed (PBY_LOAD_RES opens, reads and
* -- closes entirely within its own call, well before PRC_BYE
* -- reaches the bank-allocation/stamp/patch-frame/BankCopy
* -- sequence that precedes it) and nothing between those two
* -- points touches PMLI_XFER_BUF (BankCopy
* -- uses COPYIN_ENTRY/COPYOUT_ENTRY, not the MLI transfer
* -- buffer, at all) -- the two lifetimes provably do not
* -- overlap. PMLI_XFER_BUF is 512 B ($B800-$B9FF); this uses
* -- only its first 128. The `equ` itself moved to
* -- inc/proc.const.equ 2026-09-27 (coordinator review,
* -- check-nas-librel): kbye.s ALSO references PBY_P1BUF, and
* -- nas-librel's REL export checker refuses a cross-module
* -- EQUATE (an alias exported from procbye.s and used from a
* -- different module) -- the fix is the same one 2026-08-29
* -- already established for this exact shape, an equ file.

* -- K_BYE_BANK is declared in entry.s now, not here (moved
* -- 2026-09-25) -- see that file's own comment. entry2.s's
* -- INSTALL_COPY zeroes it unconditionally on every image,
* -- including harnesses that never put this file at all.
PBY_SAVEVLO ds    1
PBY_SAVEVHI ds    1
PBY_SAVE80  ds    1
PBY_ARMLO   ds    1
PBY_ARMHI   ds    1
* -- PBY_LOAD_RES MOVED to kbye.s 2026-09-27 (headroom recovery,
* -- coordinator review of the carry-tail fix): it flips no
* -- ALTZP, writes no LC bank-select register, contains no
* -- inline MLI bytes and declares no data of its own -- nothing
* -- in docs/KSEG.md's rules keeps it flat, and its ONLY caller
* -- (PRC_BYE, kbye.s) is already segment-resident, so the move
* -- costs no trampoline: an ordinary same-bank `jsr` either
* -- way.
* -- BYE_RES_PTXT stays HERE, flat -- it is data (rule 4), read
* -- by KSEG_LOAD (also flat) via a pointer PBY_LOAD_RES merely
* -- loads as an immediate; flat-vs-segment addressing below
* -- $D000 is unaffected by which LC bank is currently selected.
* -- fixed absolute path -- `bye` does not depend on cwd. High-
* -- bit ASCII, same convention as playtestb.s's own
* -- SHBIN_PTH_TXT/RCPTH_TXT fixed MLI paths. Read DIRECTLY by
* -- KSEG_LOAD's own path pointer now (no copy into
* -- PRC_PATHBUF).
BYE_RES_PTXT
            dfb   12
            ;/MAUX/BYERES -- PHYSICAL: a raw MLI path, not
            ;translated
            dfb   $AF,$CD,$C1,$D5,$D8,$AF
            dfb   $C2,$D9,$C5,$D2,$C5,$D3
* -- BYE_RES_PLEN retired 2026-09-27: it guarded a manual copy
* -- loop's own length immediate, and that loop is gone now that
* -- KSEG_LOAD reads this table directly (the MLI reads the
* -- length from the table's own first byte; nothing here needs
* -- to know it separately any more).

* -- BL2_REF/BL2_DST: byelaunch.s's own per-call scratch --
* -- written AND read entirely within ITS OWN post-poison
* -- execution (BYE2_START sets both fresh before either is ever
* -- read), so flat BSS is safe: nothing poisons them a SECOND
* -- time between byelaunch.s's own write and read.
BL2_REF     ds    1
BL2_DST     ds    2
* -- BL2_PSTG moved BACK to the segment (byelaunch.s)
* -- 2026-09-27,
* -- CORRECTING A REAL BUG found this round, not a style choice:
* -- it is written HERE, by PRC_BYE (kbye.s), BEFORE BYE_LEAVE's
* -- poison runs, and read by byelaunch.s's BYE2_START AFTER the
* -- poison runs -- a write-before-poison/read-after-poison
* -- crossing. Flat BSS (main memory, $0200-$BEFF) is EXACTLY
* -- the
* -- range BYE_LEAVE poisons, so the 2026-09-27 Slice A1 move
* -- ("rule 4 -- no `ds` in the segment") silently corrupted
* -- every tenant path -- BYE2_START would have read back $AA
* -- poison bytes, not the real path, and this was never caught
* -- because MAUXPLAY has not been boot-tested since that move
* -- landed. PRC_BYE and BL2_PSTG are BOTH segment-resident now
* -- (same physical bank), so PRC_BYE's write is an ordinary
* -- same-bank store -- no MLI, no BankCopy, none of rule 4's
* -- own
* -- stated hazards apply to a purely intra-segment handoff. See
* -- byelaunch.s's own declaration for the `ds`.

* -- (2026-09-26 slice 2: this used to be followed by a SECOND
* -- path table, BYE_LNCH_PTXT, and a PBY_LOAD_RES2 wrapper,
* -- for a second file. /MAUX/BYERES is now
* -- byeres.bin+byelaunch.bin CONCATENATED -- see
* -- BYE_COMBO_LEN's own comment, byeres.equ
* -- -- so there is only ever the one path/one OPEN above.)


* -- PRC_RAMRECONN/PRC_RAMREDISC moved to src/kernel/kbye.s
* -- 2026-09-27 (docs/KSEG.md, coordinator review), both still
* -- reached exactly as before -- PRC_RAMRECONN via a plain
* -- `jsr`
* -- from PRC_BYE (same file, same bank now, no switch needed),
* -- PRC_RAMREDISC via byeres.s's stamped `BB_RDVEC jmp
* -- (BB_RAMDVEC)` thunk. NEITHER needs KSEG_CALL: byeres.s
* -- itself runs from Apple bank 2 (LCBANK1_RAM), the SAME
* -- physical bank the segment occupies at $D400-$DFFF, so a
* -- same-bank call/jump crosses no switch at all.
