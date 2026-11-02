*---------------------------------------------------------------
* byeres.s -- the `bye` resident (docs/BYE-SLICE1.md). Assembled
* STANDALONE at $D100 and embedded in the kernel image via
* putbin (src/kernel/procbye.s), the proshimpg.s/asrom.s
* literal-address idiom. PRC_BYE copies this 768-byte blob into
* Apple's language-card bank 2 (this tree's LCBANK1_RAM, $C083
* -- the equ file's bank numbers are the OPPOSITE of Apple's,
* docs/BYE.md's naming-trap note) before issuing MLI QUIT.
*
* THIS IS A SEPARATE ASSEMBLY from the kernel image that
* installs it (merlin32 has no linker; `put` shares a symbol
* table, a second `merlin32` invocation does not). Every kernel
* symbol this code needs at runtime (SCH_RESUME's address, the
* K_BYE_ARM re-arm vector, the save-bank number, the bytes
* $FFFE/$FFFF held before the poison, the 80STORE bit) crosses
* that boundary as a STAMPED DATA CELL, poked by PRC_BYE at
* install time -- never as a symbol reference, because this
* file's assembler has never heard of PRC_BYE's kernel image and
* a numeric literal is the only thing both sides can agree on
* (byeres.equ is that agreement for the FIXED addresses; the
* PCB/scheduler ones move per build and are runtime data
* instead).
*
* THREE PIECES, ALL RUNNING IN THE LANGUAGE CARD:
*
* 1. The trampoline at $D100 itself. QUIT's own mechanism
*    copies $D100-$D3FF to $1000 and JMPs there UNCONDITIONALLY
*    -- that copy target is inside $0200-$BFFF, which RAMRD
*    governs for instruction FETCH (docs/BYE-SLICE1.md fact 3),
*    so this trampoline must not depend on RAMRD being main and
*    must not linger. It is ALSO the ONE place in this whole
*    path that can safely force ALTZP=main, AND THE ONLY PLACE
*    THAT CAN SAFELY FLIP IT AT ALL: $1000 sits in the RAMRD-
*    governed range, not the ALTZP-governed one (ALTZP selects
*    which LANGUAGE CARD -- main's or a process bank's -- is
*    mapped at $D000-$FFFF at all, docs/MEMMAP.md sec 3.4;
*    RAMRD/RAMWRT alone govern $0200-$BFFF), so fetching THIS
*    code never depended on ALTZP in the first place. Everything
*    downstream (BYE_BACK, entirely LC-resident) does depend
*    on it and CANNOT safely flip ALTZP itself (doing so swaps
*    out the very code that is running) -- which is why this
*    trampoline, not BYE_BACK, also restores page 1 ($0100-
*    $017F) from K_BYE_BANK's own aux $0180-$01FF before handing
*    off. So: force ALTZP=main, restore page 1 (a brief second
*    flip, still safe here), THEN reselect Apple bank 2 (in
*    case ProDOS's own quit-copy left a different LC state
*    behind, and now that "LC state" unambiguously means
*    main's), THEN jump into BYE_BACK.
*
* 2. BYE_LEAVE -- entered directly (JMP, not through $1000) by
*    PRC_BYE once the save is complete and this blob is
*    installed and stamped. Poisons main $0200-$BEFF (leaving
*    $BF00-$BFFF -- ProDOS's global page -- alone) and issues a
*    bare MLI QUIT, which is the WHOLE mechanism that reaches
*    BYE_BACK: QUIT always copies $D100-$D3FF (now THIS blob,
*    not Apple's dispatcher) to $1000 and jumps there.
*
* 3. BYE_BACK -- reached from the $1000 trampoline. Restores
*    main from the save bank using the bytes PRC_BYE stamped
*    into this blob's own data cells (none of that survives in
*    main, which is what BYE_LEAVE just destroyed), then jumps
*    to SCH_RESUME via a stamped indirect vector.
*
* The published ABI: byte 0 must be CLD ($D8), "so that programs
* can tell whether selector code or the ProDOS dispatcher code
* is resident" (ProDOS 8 TRM, quoted in docs/BYE.md).
*---------------------------------------------------------------
            lst   off
            xc
POISON      equ   $AA
* -- named, not a bare #$BF (check-encoding: a bare high byte
* -- happens to fall in the ratchet's flagged range though it
* -- is not TEXT) -- ProDOS's own MLI entry vector, $BF00.
MLI_ENTRY_HI equ  $BF
* -- ANXR_PAGES -- the annex restore's page count, $0200-$BFFF
* -- (190 pages) -- named per check-encoding, same reason as
* -- BYE_IMG_PAGES/BYE_ZP_DSTHI in procbye.s.
ANXR_PAGES   equ   $BE
* -- BB_P1BUF_A -- BB_P1BUF's own address, needed EARLY (in
* -- BYE_START, below) to compute its $1000-mirror offset before
* -- the real label is defined -- same _A-constant, err-tripwire
* -- shape as byeres.equ's cross-assembly cells, just local to
* -- this file. Placeholder; read off the real -v1 listing after
* -- every edit, same as every other _A constant here.
BB_P1BUF_A   equ   $D321
            org   BYE_ORG
            dsk   ../../build/byeres.bin
            typ   $00
            put   ../../inc/byeres.equ
            put   ../../inc/mm.hw.equ

BYE_START   cld
* -- BREADCRUMB 1: trampoline entry at $1000. $BF50-$BF54 are
* -- the documented ProDOS-global-page hole (src/bin/proshim.equ
* -- already colonises $BF40-$BF57 for the same reason): outside
* -- the saved image and skipped by the poison fill, so a byte
* -- written here survives the WHOLE round trip unmolested, and
* -- one peek after the fact says exactly how far execution got
* -- with no inference from residual state needed (BANKSEL is
* -- written by BankCopy too, during the save -- it proves
* -- nothing about which code ran afterward).
            lda   #1
            sta   $BF50
* -- force ALTZP=main FIRST (see the header note --
* -- this fetch is RAMRD-governed, not ALTZP-governed, so it
* -- runs correctly no matter which LC ALTZP pointed at on
* -- arrival; everything after this line is NOT).
            sta   ALTZPMAIN
* -- RESTORE PAGE 1 ($0100-$017F) FROM K_BYE_BANK'S OWN AUX
* -- $0180-$01FF, HERE, NOT in BYE_BACK. BYE_BACK is entirely
* -- LC-resident, and ALTZP ALSO picks WHICH language card is
* -- mapped at $D000-$FFFF (docs/MEMMAP.md sec 3.4) -- so a
* -- `sta ALTZPAUX` executed FROM the LC swaps out the very code
* -- that is running, the instant it executes (MEASURED: PC runs
* -- into K_BYE_BANK's own, never-initialized language card and
* -- parks in a BRK avalanche at low addresses). THIS point is
* -- different: $1000-$12FF is RAMRD-governed, not ALTZP-
* -- governed, for fetch (same fact BYE_START's own ALTZPMAIN
* -- force above already relies on), so flipping ALTZP here does
* -- not touch what is executing. The stamped bank number lives
* -- at the SAME OFFSET in THIS mirror -- QUIT copied the whole
* -- blob, stamped cells included -- so BYE_BANKNO_A-BYE_ORG+
* -- $1000 reads it correctly without waiting for BYE_BACK's own
* -- (real, $D1xx) copy to run. Nothing before this point needs
* -- $0100-$017F (ProDOS's own QUIT dispatcher used it as ITS
* -- stack, not maux's), and nothing after this point until
* -- resume touches it (BYE_LEAVE's poison and BB_PGLOOP both
* -- start at $0200) -- so writing the real content HERE is
* -- permanent, no bounce-buffer handoff into BYE_BACK needed.
* -- BB_P1BUF_A-BYE_ORG+$1000 is this file's OWN scratch cell
* -- (BB_P1BUF, far below), reached via ITS mirror the same way
* -- -- once read back out below, its real ($D1xx) copy is never
* -- touched again, so scribbling on the mirror here is safe.
            lda   BYE_BANKNO_A-BYE_ORG+$1000
            sta   BANKSEL
            sta   ALTZPAUX
* XBANK(stack): reading K_BYE_BANK's OWN saved page 1 IS the
* job.
            ldy   #0
:p1rd       lda   $0180,y
            sta   BB_P1BUF_A-BYE_ORG+$1000,y
            iny
            cpy   #$80
            bne   :p1rd
            sta   ALTZPMAIN
            ldy   #0
:p1wr       lda   BB_P1BUF_A-BYE_ORG+$1000,y
            sta   $0100,y
            iny
            cpy   #$80
            bne   :p1wr
* -- reselect Apple bank 2 WITHIN main's LC (double read -- the
* -- hardware's pre-write counter needs two odd accesses to
* -- latch write-enable, same idiom every LC writer in this tree
* -- opens with), then hand off.
            lda   LCBANK1_RAM
            lda   LCBANK1_RAM
            jmp   BYE_BACK

*---------------------------------------------------------------
* BYE_LEAVE -- entered from PRC_BYE (procbye.s), never from the
* trampoline. sei first: from here there is nothing worth an
* interrupt reaching until BYE_BACK's own restore completes --
* TMR_QUIESCE already disarmed the DEVICE (procbye.s's quiesce
* step, before this runs), so this is belt-and-braces against
* anything else that could still assert.
*---------------------------------------------------------------
BYE_LEAVE   sei
* -- Force ALTZP=main before touching ANYTHING else. PRC_BYE
* -- calls this via a plain JMP from kernel/syscall context,
* -- where ALTZP is already main -- but the QUIT trigger below
* -- dispatches into ProDOS's OWN MLI, which is ALSO LC-resident
* -- (docs/MEMMAP.md sec 3.4: ALTZP selects which LANGUAGE CARD,
* -- main's or a process bank's, is mapped at $D000-$FFFF at
* -- all). Handing ProDOS a process bank's LC instead of main's
* -- is exactly the class of assumption-across-a-boundary this
* -- whole routine exists to avoid, so this is forced here too,
* -- not merely inherited.
            sta   ALTZPMAIN
* -- DEVIATION FROM docs/BYE-SLICE1.md: the spec has this step
* -- restoring $FFFE/$FFFF from MLI_VCPG_BOOT, the snapshot
* -- INSTALL_IRQ takes. Checked before writing this: mli.s IS
* -- put by all 32 production kernel images (not just the
* -- historical src/test/prodos.spike.s) -- what is true is that
* -- INSTALL_IRQ is never CALLED outside that one spike, so
* -- MLI_VCPG_BOOT is 256 bytes of `ds`-zeros everywhere else
* -- and the snapshot does not exist to restore from. What DOES
* -- exist: only 2 of the 32 (playtest/sertest, the ones with a
* -- timer) ever move main's LC $FFFE away from ProDOS's own
* -- value at all
* -- (timer.s's TMR_OWN_03FE, pointing it at MAIN_IRQ_SHIM,
* -- which lives in the main memory about to be poisoned); the
* -- other 30 never touch it, so it is permanently safe already
* -- (ProDOS's own vector, in the LC, never poisoned). Rather
* -- than special-case on K_HALT_TMR, point it at THIS blob's
* -- own RTI stub unconditionally -- immune to the poison either
* -- way, and equally harmless for the 30 images where it was
* -- already safe. BYE_BACK restores the ORIGINAL bytes (saved
* -- by PRC_BYE below, before this write) once main is whole.
            lda   #<BYE_SAFE
            sta   $FFFE
            lda   #>BYE_SAFE
            sta   $FFFF
* -- FORMAT /RAM (2026-09-26 ruling), ONLY if BB_HADRAM is set
* -- (stamped from K_HAD_RAM before the poison, procbye.s).
* -- Writes a minimal, valid, empty ProDOS volume DIRECTLY into
* -- aux bank 0 -- blocks 2 (the volume directory key block) and
* -- 3 (one bitmap block) only; boot blocks 0-1 are left as
* -- whatever they were, since ProDOS never validates them to
* -- MOUNT a data volume, only to BOOT from one. THIS RUNS HERE,
* -- NOT via the driver's own $42-$47 direct-call contract
* -- (procbye.s's own header explains why -- that call reliably
* -- HUNG the round trip, measured, because the driver's own
* -- internal work leaves RAMRD/RAMWRT pointed at aux, and a
* -- return into ordinary $0200-$BFFF kernel code misfires the
* -- very next fetch). Safe HERE because this whole routine is
* -- LC-resident and already toggles RAMRD/RAMWRT freely (the
* -- poison fill two steps below is the proof). Layout verified
* -- against ~/src/a2til's own prodos.py VolHeader/format_image
* -- (the house tool that already builds real ProDOS volumes),
* -- not assumed: name "RAM" (high-bit ASCII), access $E3,
* -- entry_length $27, entries_per_block $0D, bit_map_pointer=3,
* -- total_blocks=95 ($0200-$BFFF = 48,640 B = 95 x 512, block N
* -- at aux $0200+N*512 -- the SAME mapping BYE_LEAVE's own
* -- poison fill below assumes for main).
            lda   BB_HADRAM
            beq   RF_SKIP
            stz   BANKSEL
            sta   RAMWRTAUX
* -- zero blocks 2+3 (aux $0600-$09FF, 4 pages) first -- most of
* -- both blocks (prev/next chain header, reserved, creation,
* -- the 12 unused directory entries, the bitmap past its first
* -- 12 bytes) is zero either way, so this is cheaper than a
* -- static table for the parts that stay zero.
            lda   #$06
            sta   RF_ZFILL+2
            ldx   #4
            lda   #0
RF_ZLOOP    ldy   #0
RF_ZFILL    sta   $0600,y
            iny
            bne   RF_ZFILL
            inc   RF_ZFILL+2
            dex
            bne   RF_ZLOOP
* -- the volume header entry (39 B, ENTRY_LENGTH) at aux $0604
* -- (block 2 + the 4-byte chain header already zeroed above).
            ldy   #0
RF_HDRCP    lda   RF_HDRTBL,y
            sta   $0604,y
            iny
            cpy   #39
            bne   RF_HDRCP
* -- the bitmap's own leading 12 bytes (aux $0800, block 3):
* -- blocks 0-3 used (0), blocks 4-94 free (1), block 95+ does
* -- not exist (0, the zero-fill's own default, untouched here).
            ldy   #0
RF_BMCP     lda   RF_BMTBL,y
            sta   $0800,y
            iny
            cpy   #12
            bne   RF_BMCP
            sta   RAMWRTMAIN
RF_SKIP
* -- SLICE 2 (docs/BYE.md "Slice 2 launch"), MOVED HERE
* -- 2026-09-27 (spec correction, coordinator-directed): a
* -- tenant was named -- hand off to the launch blob (Apple LC
* -- bank 2, already selected write-enabled and loaded by
* -- PBY_LOAD_RES2 before any of this ran) BEFORE the poison
* -- fill below, skipping it entirely for this path. "Poison
* -- stays" was written for slice 1's bare-QUIT round trip,
* -- where it is the whole POINT (proving main was really
* -- destroyed and really came back -- check-bye's own witness
* -- 1). It is WRONG for a launch: MEASURED, a real ProDOS 8
* -- .SYSTEM's own MLI CREATE (a real block WRITE, the first one
* -- anywhere in this mechanism) hung for 20+ million cycles
* -- after SET_PREFIX/OPEN/READ/CLOSE all succeeded, and the
* -- coordinator- requested instrument -- ZP $42-$47
* -- (cmd=2/WRITE, blk=2) and the slot-7 screen holes ($0478+7
* -- through $07F8+7) -- found every one of those holes poisoned
* -- to $AA at the hang: real slot-ROM drivers keep per-slot
* -- scratch there (retry state, DMA pointers), a fresh boot
* -- leaves it sane, and a real handover must too. The tenant's
* -- own CREATE+WRITE is the destructive proof this slice wants
* -- (docs/BYE.md's own worked example); the poison fill was
* -- redundant on top of it and actively harmful to it. Bare
* -- `bye` (BB_TENANT=0) still poisons below, unchanged -- slice
* -- 1's witnesses keep their teeth. ONE-WAY: byelaunch.s never
* -- returns here. The tenant's own eventual QUIT re-triggers
* -- THIS SAME $D100 resident from scratch, via the ordinary
* -- $1000 mirror (BYE_START, above), landing in BYE_BACK
* -- exactly as a bare `bye` would -- this branch has nothing to
* -- do with the return half.
            lda   BB_TENANT
            beq   BL_NOTEN
* -- KSEG_ORG, not BYE2_ORG: the launch blob is now the FIRST
* -- module of the KSEG segment (docs/KSEG.md), not a
* -- hand-pinned
* -- second putbin'd blob, and a fixed hardware address is the
* -- only thing this SEPARATE assembly and the kernel's own
* -- manifest can still agree on. Still comes from inc/mm.hw.equ
* -- (put above) -- KSEG_ORG stayed there through the 2026-09-27
* -- `do ]KSEG_WANT` removal (coordinator review, DECISION 1)
* -- specifically because this standalone assembly (and
* -- playtest.s's own top-level `org KSEG_ORG`) both need it as
* -- a plain, ordinarily-shared equ, not a module-scoped one.
            jmp   KSEG_ORG
BL_NOTEN
* -- POISON $0200-$BEFF (189 pages), skipping nothing: this
* -- code is in the LC, so it may (and does) destroy every byte
* -- of the kernel including the code that called it. Leaves
* -- $BF00-$BFFF (ProDOS's global page) alone -- QUIT is about
* -- to go through it. Self-modified high byte, no zero page
* -- needed (RAMWRT is already main, the steady state, so this
* -- is a plain absolute store).
            lda   #$02
            sta   BL_FILL+2
            ldx   #189
            lda   #POISON
BL_PGLOOP   ldy   #0
BL_FILL     sta   $0200,y
            iny
            bne   BL_FILL
            inc   BL_FILL+2
            dex
            bne   BL_PGLOOP
* -- MEASURED, on ProDOS's OWN resident code, disassembled live
* -- while stopped in kernel/main context (ALTZP=main, so this
* -- is genuinely main's LC, not a process bank's): a JSR $BF00
* -- issued from THIS code would have its inline command+
* -- paramlist bytes misread. ProDOS's MLI entry ($BF00 ->
* -- $BFB7) sets write-enable + selects APPLE BANK 1 (BIT $C08B
* -- x2) and JMPs to $DE00 BEFORE it ever looks at the inline
* -- bytes; $DE00's own code (PLA/STA $42,X ... LDA ($40),Y)
* -- pulls the return address into ZP $40/$41 and reads the
* -- command byte and parameter-list address THROUGH THAT
* -- POINTER -- i.e. AFTER the bank-1 reselect. A JSR issued
* -- from bank-2-resident code (this blob) has its own return
* -- address point back into BANK 2, so that read lands on
* -- WHATEVER BANK 1 HAPPENS TO HOLD at the same offset instead
* -- of our $65/paramlist bytes. (An earlier version of this
* -- comment also claimed this was confirmed by a crash into a
* -- process bank; that specific run turned out to be the
* -- separate zero-byte-putbin bug -- learning:
* -- 01KW1GTYGZ9TE2ZGCDG0V2CNE0 -- corrupting the resident
* -- entirely, so it is not evidence for THIS hazard. The
* -- disassembled ProDOS behaviour above stands on its own.)
* --
* -- FIRST FIX ATTEMPT, MEASURED WRONG: an earlier version built
* -- the trigger (JSR/cmd/pointer) in ZERO PAGE but left the
* -- 7-byte PARAMETER LIST ITSELF in this resident blob (bank 2,
* -- e.g. $D15B). Same hazard one level down: ProDOS reads the
* -- command+pointer through zero page correctly (unbanked), but
* -- then DEREFERENCES the pointer to read the parameter list
* -- CONTENTS -- which lands in bank 2 only while bank 2 is
* -- selected, and by then ProDOS has already reselected bank 1.
* -- Measured on the real round trip: QUIT returned via RTS with
* -- A=$04 (BAD_SYSTEM_CALL_PARAMETER_COUNT) to the byte right
* -- after the inline call, and that byte was uninitialized zero
* -- page ($00 = BRK), caught cleanly by MAIN_IRQ_SHIM's own
* -- main-context-BRK park (timer.s's :brkpark) -- confirmed by
* -- decoding the stacked frame with the shim's own verified
* -- prologue (PHA/PHX/PHY: Y=SP+1/X=SP+2/A=SP+3/P=SP+4/
* -- PCL=SP+5/PCH=SP+6), not assumed.
* --
* -- REAL FIX: the parameter list must live somewhere ProDOS can
* -- read regardless of which LC bank it reselects -- PAGE 1
* -- ($0100-$017F), not zero page and not this resident. Page 1
* -- is ALTZP-governed like zero page, not RAMRD-governed (seed
* -- handle learning:01KW1GTYGVYAPQRGS5P7J66RWD), so it is
* -- exactly as unbanked as zero page. UNLIKE zero page,
* -- $0100-$017F is NOT free scratch -- inc/entry.frame.equ
* -- places COPYIN_ENTRY at $0100 and COPYOUT_ENTRY at $0140, 64
* -- bytes each, wall to wall, used throughout the kernel
* -- (bankcopy.s, entry.s, procspawn.s, sched.s, ser.s, tty.s).
* -- Clobbering them here without restoring them would silently
* -- corrupt every syscall that runs COPYIN_ENTRY/COPYOUT_ENTRY
* -- after a successful `bye` resume. So procbye.s's save step
* -- now ALSO copies main $0100-$017F into the save bank's
* -- $BE00-$BE7F (the unused gap between the $0000-$BDFF
* -- main-image save and the $BF00-$BFFF ZP save -- same
* -- bank, no new allocation), and BYE_BACK's restore step
* -- (below) copies it back before resuming -- the same
* -- save/scratch/restore pattern already used for zero page,
* -- extended to this window.
* --
* -- LAYOUT (fixed literals -- PAGE 1 target addresses, not this
* -- file's own resident-blob offsets):
* --   BL_PARM  = $0100, 7 bytes: the QUIT parameter list
* --   BL_TRIG  = $0107, 6 bytes: JSR $BF00 / cmd / paramlist
* --              ptr
* --   BL_HANG2 = $010D, 3 bytes: JMP self -- a defensive park
* --              for the should-be-unreachable MLI-error
* --              fallthrough (return address = BL_TRIG+6 =
* --              $010D), so a renewed failure parks cleanly
* --              instead of falling into the parameter bytes.
BL_PARM     equ   $0100
BL_TRIG     equ   $0107
BL_HANG2    equ   $010D
            lda   #4                      ;QUIT param count
            sta   BL_PARM
            stz   BL_PARM+1                ;quit_type=0
            stz   BL_PARM+2                ;reserved
            stz   BL_PARM+3
            stz   BL_PARM+4                ;reserved
            stz   BL_PARM+5
            stz   BL_PARM+6
            lda   #$20                    ;JSR opcode
            sta   BL_TRIG
            lda   #$00
            sta   BL_TRIG+1
            lda   #MLI_ENTRY_HI
            sta   BL_TRIG+2
            lda   #$65                    ;QUIT
            sta   BL_TRIG+3
            lda   #<BL_PARM
            sta   BL_TRIG+4
            lda   #>BL_PARM
            sta   BL_TRIG+5
            lda   #$4C                    ;JMP opcode
            sta   BL_HANG2
            lda   #<BL_HANG2
            sta   BL_HANG2+1
            lda   #>BL_HANG2
            sta   BL_HANG2+2
            jmp   BL_TRIG
* -- unreachable in the resident itself: control goes to page 1
* -- above and never falls through to here.
BL_HANG     jmp   BL_HANG
* -- RF_HDRTBL: the volume directory's own header entry, 39 B
* -- (ENTRY_LENGTH), block-relative offsets $04-$2A -- storage
* -- type $F (volume header) | name_length 3, name "RAM" (high-
* -- bit ASCII) padded to 15 B, 8 B reserved, 4 B creation (left
* -- zero -- not required to mount), version/min_version 0,
* -- access $E3, entry_length $27, entries_per_block $0D,
* -- file_count 0, bit_map_pointer 3 (block 3, right after this
* -- one), total_blocks 95 ($005F).
RF_HDRTBL   dfb   $F3
            dfb   $D2,$C1,$CD
            dfb   0,0,0,0,0,0,0,0,0,0,0,0
            dfb   0,0,0,0,0,0,0,0
            dfb   0,0,0,0
            dfb   0
            dfb   0
            dfb   $E3
            dfb   $27
            dfb   $0D
            dfb   0,0
            dfb   3,0
            dfb   $5F,0
* -- RF_BMTBL: the bitmap block's own leading 12 bytes -- bit
* -- 0x80>>(N&7) of byte N>>3 is block N, 1=free (a2til's own
* -- prodos.py Bitmap docstring); blocks 0-3 used (byte 0's top
* -- 4 bits clear), blocks 4-94 free, block 95 does not exist.
RF_BMTBL    dfb   $0F
            dfb   $FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF
            dfb   $FE
* -- BYE_SAFE: where $FFFE/$FFFF point for the destroyed-main
* -- window (see the DEVIATION note above). Immune to the poison
* -- (lives in the LC).
* --
* -- NO LONGER a bare RTI, 2026-09-27 (coordinator's three
* -- readings, bye slice 2 bug 6): a bare RTI does not
* -- ACKNOWLEDGE whatever asserted the line, so an
* -- unacknowledged source fires again the instant RTI
* -- re-enables interrupts -- and on a REAL BRK (not just a
* -- stray IRQ), RTI does not even skip the BRK's own signature
* -- byte, so it walks straight back into the same trap.
* -- MEASURED, live: at the tenant's own first hit here (well
* -- after its last real MLI call, before QUIT had even run --
* -- $1000 still held pre-trampoline bytes), the stacked P had B
* -- SET (a real BRK, not a hardware IRQ) with return address
* -- $FDF7 -- inside ROM COUT territory -- and the slot-4 VIA's
* -- own IFR read back $F7, bit 7 (IRQ) SET, while the
* -- AppleMouse PIA's CRA/CRB/PRB all read clear. That names the
* -- device: ProDOS's CREATE calls the clock driver to timestamp
* -- a new file -- the first time in this whole mechanism that
* -- path has ever run -- and Timemaster's own VIA (slot 4)
* -- appears to come back from it still asserting, well after
* -- PRC_BYE's own one-time quiesce ran (before poison, long
* -- before CREATE). Fix, minimal and at exactly this quiesce
* -- point rather than guessing where in ProDOS's own clock call
* -- to intervene: acknowledge ALL seven VIA flag bits (the
* -- 6522's own "write 1 to clear" IFR convention -- $7F, not
* -- $FF, so bit 7 itself, which is read-only, is left alone)
* -- before the RTI, unconditionally -- harmless if the VIA was
* -- not in fact the cause, since writing to an already-clear
* -- IFR is a no-op.
MB_IFR      equ   $C40D        ;slot 4 VIA IFR (IER is $C40E,
                               ;timer.s's MB_IER) -- LOCAL here,
                               ;same reason ser.s's own 6551
                               ;equates are local to that file.
BYE_SAFE    pha
            lda   #$7F
            sta   MB_IFR
            pla
            rti
            err   BYE_LEAVE-BYE_LEAVE_A

*---------------------------------------------------------------
* BYE_BACK -- reached ONLY via the $1000 trampoline's JMP, which
* means ONLY after a real MLI QUIT actually ran. Runs entirely
* in the LC, immune to RAMRD (docs/BYE-SLICE1.md fact 3), so it
* is safe for it to set RAMRD=aux for the whole copy.
*---------------------------------------------------------------
* -- NOTE ON ALTZP: it is NOT forced here. BYE_BACK is entirely
* -- LC-resident, so fetching its own FIRST instruction already
* -- required the correct language card (main's) to be mapped --
* -- forcing ALTZP=main at this point would be one instruction
* -- too late to matter for anything before it, and everything
* -- after it (the ZP-governed cells this routine and
* -- SCH_DISPATCH share -- K_PCB_PTR, K_SW_INSP, K_SW_INBANK,
* -- K_SW_INPID, inc/sched.equ -- and BB_ZPCOPY's own $0000,y
* -- destination) is safe because the ONLY path that reaches
* -- here is the $1000 trampoline's own JMP, and the trampoline
* -- already forced ALTZP=main before that JMP (see BYE_START
* -- above). That is the correct place to do it: $1000 is
* -- RAMRD-governed rather than ALTZP-governed for fetch
* -- (docs/MEMMAP.md sec 3.4), so it runs safely regardless of
* -- ALTZP's incoming state, and can therefore fix ALTZP before
* -- handing off to this LC-resident code, which cannot fix
* -- anything until it is already correct.
BYE_BACK    sei
* -- BREADCRUMB 2: BYE_BACK entry (see BREADCRUMB 1's note).
            lda   #2
            sta   $BF51
* -- 1. force 80STORE off for the whole copy (else $0400-$07FF
* -- and $2000-$3FFF are intercepted and the restore writes to
* -- the wrong halves, learning:01KW1GTYHGXMBZNR6DMQB2F712).
            sta   CLR80STORE
* -- 2. $C073 := the embedded save-bank byte.
            lda   BYE_BANKNO
            sta   BANKSEL
* -- 3. RAMRD := aux, RAMWRT := main, for the whole copy.
            sta   RAMRDAUX
            sta   RAMWRTMAIN
* -- page walk, ABSOLUTE,Y with the two high bytes self-
* -- modified in LC RAM -- NO ZERO PAGE ANYWHERE IN THIS LOOP:
* -- main's ZP is one of the things being restored, and STA has
* -- no zp,Y mode at all (forcing absolute,Y by construction).
* -- 189 pages, $0200-$BEFF, same offsets in both banks.
            lda   #$02
            sta   BB_SRC+2
            sta   BB_DST+2
            ldx   #189
BB_PGLOOP   ldy   #0
BB_SRC      lda   $0200,y
BB_DST      sta   $0200,y
            iny
            bne   BB_SRC
            inc   BB_SRC+2
            inc   BB_DST+2
            dex
            bne   BB_PGLOOP
* -- BREADCRUMB 3: after the page walk (see BREADCRUMB 1).
            lda   #3
            sta   $BF52
* -- the 190th page: aux $BF00 (the saved kernel ZP) -> main
* -- $0000. Fixed addresses, no self-modification needed (a
* -- one-shot pair, not a walk).
            ldy   #0
BB_ZPCOPY   lda   $BF00,y
            sta   $0000,y
            iny
            bne   BB_ZPCOPY
* -- page 1 ($0100-$017F, BYE_LEAVE's own unbanked QUIT-trigger
* -- window) is ALREADY RESTORED by this point -- BYE_START did
* -- it, back at the $1000 trampoline, before jumping here. It
* -- CANNOT be done in THIS routine: BYE_BACK is LC-resident,
* -- and ALTZP ALSO picks which language card is mapped, so a
* -- flip here would swap out the very code that is running
* -- (see BYE_START's own comment; measured symptom: a BRK
* -- avalanche at low addresses).
* -- BREADCRUMB 4: after the ZP restore (see BREADCRUMB 1).
            lda   #4
            sta   $BF53
* -- 4. $C073 := 0, RAMRD/RAMWRT := main. Main memory is whole
* -- again from here on -- every ordinary kernel symbol below
* -- (via the stamped vectors) is a real read, not an aux one.
            stz   BANKSEL
            sta   RAMRDMAIN
            sta   RAMWRTMAIN
* -- ANNEX RESTORE: BYE_BANKNO2 (aux $0200-$BFFF, the annex's
* -- own save bank) -> bank 0, 128 B at a time through BB_P1BUF
* -- (this file's OWN scratch, its page-1 job already done above
* -- -- reusing it here instead of a second 256-byte buffer is
* -- what keeps this fitting in the resident's 768-byte budget).
* -- Two windows per half-page, same reason as BankCopy's own
* -- bank-to-bank case (BANKSEL is ONE shared register): select
* -- BYE_BANKNO2+RAMRD=aux to read a half into BB_P1BUF, then
* -- bank 0+RAMWRT=aux to write it out. 190 pages, two halves
* -- each ($00-$7F then $80-$FF of every page), same offsets in
* -- both banks. ANXR_PAGES fits a byte (190); the half-page
* -- toggle (EOR #$80 on the shared operand's LOW byte) is what
* -- lets X count real PAGES instead of the 380 halves, which
* -- would not fit one byte.
            lda   #$02
            sta   BX_RDOP+2
            sta   BX_WROP+2
            stz   BX_RDOP+1
            stz   BX_WROP+1
            ldx   #ANXR_PAGES
BX_PGLOOP2  lda   BYE_BANKNO2
            sta   BANKSEL
            sta   RAMRDAUX
            ldy   #0
BX_RDOP     lda   $0200,y
            sta   BB_P1BUF,y
            iny
            cpy   #$80
            bne   BX_RDOP
            sta   RAMRDMAIN
            stz   BANKSEL
            sta   RAMWRTAUX
            ldy   #0
BX_WRLP     lda   BB_P1BUF,y
BX_WROP     sta   $0200,y
            iny
            cpy   #$80
            bne   BX_WRLP
            sta   RAMWRTMAIN
            lda   BX_RDOP+1
            eor   #$80
            sta   BX_RDOP+1
            sta   BX_WROP+1
            bne   BX_ADVAN2
            inc   BX_RDOP+2
            inc   BX_WROP+2
            dex
            beq   BX_ANXDONE
BX_ADVAN2   jmp   BX_PGLOOP2
BX_ANXDONE
* -- restore 80STORE to EXACTLY what PRC_BYE captured
* -- (BankCopy's own restore-exact contract, mirrored here
* -- rather than assumed as a fixed steady state).
            lda   BYE_SAVE80
            beq   BB_80OFF
            sta   SET80STORE
            bra   BB_80DONE
BB_80OFF    sta   CLR80STORE
BB_80DONE
* -- put $FFFE/$FFFF back exactly as PRC_BYE found them (main's
* -- LC, the common $E000-$FFFF region -- outside the saved
* -- image, so this is the mechanism's own job, not BankCopy's).
            lda   BYE_SAVEVLO
            sta   $FFFE
            lda   BYE_SAVEVHI
            sta   $FFFF
* -- /RAM re-disconnect, BEFORE the tick is re-armed below --
* -- a tick taken while /RAM's driver has RAMRD on aux wedges
* -- the machine (learning:01M1B7W9Z76TMAKP7YPG63F7WQ). ONLY if
* -- it was reconnected in the first place (BB_HADRAM, stamped
* -- from K_HAD_RAM before the poison) -- PRC_RAMREDISC assumes
* -- /RAM sits at DEVLST[0] (where PRC_RAMRECONN put it), which
* -- is only true when the reconnect actually ran.
            lda   BB_HADRAM
            beq   BB_NORAM
            jsr   BB_RDVEC
BB_NORAM
* -- re-arm the periodic interrupt DEVICE (K_IRQ_HOOK itself was
* -- already restored by the page walk above, ordinary main
* -- memory -- see timer.s's TMR_REARM header). BB_ARMVEC is a
* -- COPY of K_BYE_ARM taken by PRC_BYE while main was still
* -- intact (before the poison), so it carries the SAME "0 = no
* -- timer" convention K_HALT_TMR/K_BYE_ARM use everywhere else.
* -- KSEG (docs/KSEG.md): reload the cold segment from disk
* -- BEFORE the tick is re-armed below and before ANY segment
* -- call -- a tick landing mid-reload, or a segment call
* -- against half-written bytes, is exactly the hazard the
* -- ordering guards against. Stamped vector, same shape as
* -- BB_RAMDVEC above -- KSEG_RELOAD's real address is a
* -- link-time fact of the KERNEL's own assembly, not this one.
            jsr   BB_KSGCALL
            lda   BB_ARMVEC+1
            beq   BB_NOTIMER
            jsr   BB_ARMCALL
BB_NOTIMER
* -- BREADCRUMB 5: about to jump to SCH_RESUME (see BREADCRUMB
* -- 1). The last one that can ever be written: if SCH_RESUME's
* -- own stamped vector is wrong, this is the last known-good
* -- point before control leaves byeres.s for good.
            lda   #5
            sta   $BF54
* -- 5. resume the process that called SYS_BYE, via a stamped
* -- indirect vector -- SCH_RESUME's real address is a link-time
* -- fact of the KERNEL's assembly, not this one.
            jmp   BB_RESJMP
BB_ARMCALL  jmp   (BB_ARMVEC)
BB_RESJMP   jmp   (BB_RESVEC)
BB_RDVEC    jmp   (BB_RAMDVEC)
BB_KSGCALL  jmp   (BB_KSGVEC)

BYE_BANKNO  ds    1
BYE_SAVEVLO ds    1
BYE_SAVEVHI ds    1
BYE_SAVE80  ds    1
BB_ARMVEC   ds    2
BB_RESVEC   ds    2
            err   BYE_BANKNO-BYE_BANKNO_A
            err   BYE_SAVEVLO-BYE_SAVEVLO_A
            err   BYE_SAVEVHI-BYE_SAVEVHI_A
            err   BYE_SAVE80-BYE_SAVE80_A
            err   BB_ARMVEC-BB_ARMVEC_A
            err   BB_RESVEC-BB_RESVEC_A

* -- 2026-09-26: the second save bank's number (the annex),
* -- K_HAD_RAM's own value (gates the redisconnect call below),
* -- and PRC_RAMREDISC's real address (a kernel routine this
* -- separate assembly cannot name directly -- same reason
* -- BB_RESVEC/BB_ARMVEC are stamped vectors, not symbols).
BYE_BANKNO2 ds    1
BB_HADRAM   ds    1
BB_RAMDVEC  ds    2
            err   BYE_BANKNO2-BYE_BANKNO2_A
            err   BB_HADRAM-BB_HADRAM_A
            err   BB_RAMDVEC-BB_RAMDVEC_A

* -- 2026-09-26 slice 2 (docs/BYE.md "Slice 2 launch"): 1 = a
* -- tenant was named on this `bye` -- BYE_LEAVE (above) jumps
* -- to BYE2_ORG (the launch blob, src/kernel/byelaunch.s)
* -- instead of the bare-QUIT trigger. Stamped from PBY_HASTEN,
* -- procbye.s.
BB_TENANT   ds    1
            err   BB_TENANT-BB_TENANT_A

* -- KSEG (docs/KSEG.md): KSEG_RELOAD's real address, stamped by
* -- procbye.s alongside the other kernel-address vectors above
* -- -- appended HERE, after every existing stamped cell, so no
* -- earlier _A offset shifts (only BB_P1BUF_A, already hand-
* -- adjusted for this insertion, moves).
BB_KSGVEC   ds    2
            err   BB_KSGVEC-BB_KSGVEC_A

* -- BYE_START's own bounce buffer (reached via its $1000
* -- mirror, BB_P1BUF_A-BYE_ORG+$1000, never at this real
* -- address -- see that routine). Purely internal scratch,
* -- never poked by
* -- procbye.s.
BB_P1BUF    ds    128
            err   BB_P1BUF-BB_P1BUF_A

* -- pad to exactly BYE_BLOB_LEN (768) bytes: QUIT always copies
* -- $D100-$D3FF as one fixed-size block regardless of what is
* -- installed, and procbye.s's own install loop copies this
* -- putbin'd file in three fixed 256-byte pages -- a short file
* -- would leave those pages carrying WHATEVER FOLLOWS this blob
* -- in procbye.s's own image instead of known, inert bytes.
            ds    BYE_ORG+BYE_BLOB_LEN-*
