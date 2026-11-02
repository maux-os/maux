*---------------------------------------------------------------
* byelaunch.s -- the `bye PATH.SYSTEM` launch (docs/BYE.md
* "Slice 2 launch: `bye PATH.SYSTEM`"). Assembled STANDALONE at
* BYE2_ORG ($D400, inc/byeres.equ) -- Apple LC bank 2, the SAME
* bank byeres.s occupies, in the 3 KB QUIT's own $D100-$D3FF
* copy window never reaches ($D400-$DFFF, docs/BYE.md item 6's
* named escape hatch). Loaded by PBY_LOAD_RES2 (procbye.s), a
* generalization of the SAME PBY_LOAD_RES routine byeres.s
* itself is loaded through -- not a duplicate.
*
* MEASURED, not guessed: byeres.s (768 B fixed) has only ~119 B
* free below its own real content (BB_P1BUF ends at $D389, not
* the ~336 B docs/BYE.md's own item 6 estimated -- that number
* predates this file's 2026-09-26 FORMAT-in-byeres.s addition,
* which is the correction; see docs/BYE-SLICE1-NOTES.md). The
* whole launch -- five raw MLI calls, two 65-byte path buffers,
* the bitmap and $280 writes -- does not fit in either budget,
* so this is a SECOND blob, not an extension of byeres.s.
*
* ENTERED ONCE, by a plain JMP from BYE_LEAVE (byeres.s), AFTER
* poison -- main $0200-$BEFF is destroyed by that point, so
* EVERY MLI call here goes through the page-1 trigger mechanism
* byeres.s's own BYE_LEAVE bare-QUIT already uses (docs/
* BYE-SLICE1.md: ProDOS's MLI entry reselects Apple BANK 1
* (BIT $C08B x2) before dereferencing the inline command+
* parameter-list pointer through the JSR's own return address,
* so a JSR issued FROM bank-2-resident code has that pointer
* land on whatever bank 1 holds at the same offset instead).
* Page 1 ($0100-$017F) is ALTZP-governed, not bank-select-
* governed, so it reads/executes correctly regardless of which
* LC bank happens to be selected -- the same fact BYE_LEAVE's
* own BL_PARM/BL_TRIG already rely on.
*
* THE BANK-1 RESELECT ALSO HAPPENS ON THE WAY BACK. ProDOS's
* MLI entry selects bank 1 as part of ITS OWN dispatch (BYE_
* LEAVE's header comment) and never restores bank 2 -- so the
* RTS this file's own raw MLI trigger lands on cannot simply
* return into bank-2-resident code (this blob) directly: bank 1
* would still be selected, and the very next instruction fetch
* from a $D4xx address would read BANK 1's bytes instead of
* this blob's own. BL2_RET therefore reselects Apple bank 2
* write-enabled FIRST, then RTS -- see BL2_CALL below.
*
* NEVER RETURNS to byeres.s: it ends in `cli` / `jmp
* TENANT_ORG`. The tenant's own eventual QUIT re-enters this
* SAME LC bank 2 via ProDOS's ordinary $D100-$D3FF-to-$1000
* copy, landing in
* byeres.s's BYE_START/BYE_BACK exactly as a bare `bye` would --
* this file has nothing to do with the RETURN half at all, and
* never jumps back into byeres.s.
*
* VALIDATION ALREADY HAPPENED, in TWO PLACES, neither of which
* is this file. File type $FF and size <= $7800 were checked in
* USERLAND (bye.s, via liba's SC_GFI/SC_OPEN/LSEEK/SC_CLOSE)
* BEFORE SC_BYE was ever called -- a kernel-side check cost too
* much of procbye.s's own tight PT_HOLD headroom (measured, see
* docs/BYE-SLICE1-NOTES.md). "No pinned open file" was checked
* in KERNEL CONTEXT (PBY_PARK_ALL, procbye.s), a genuine kernel
* operation on the OFT table. There is no clean way to report a
* refusal to the person once main is destroyed, so nothing here
* re-checks any of it -- a file that changes on disk between
* either check and this point is an accepted, documented gap (a
* single-user dev-tool race, not a hostile one; the READ loop's
* own courtesy stop at PMLI_IBF_BASE, below, keeps even a grown
* file from corrupting memory past the read window -- it just
* launches a truncated tenant).
*
* THE MEMORY BIT MAP ($BF58-$BF6F, 24 bytes, one bit per page of
* the lower 48K) is [likely], not [fact]: the ProDOS 8 TRM text
* in the commons (artifact d82965d8..., chunk 311) confirms the
* ADDRESS (immediately after AFBANK at $BF57) and the semantics
* ("protected areas are marked with a 1"), but not this file's
* own MSB-first bit-per-page convention, which is inferred by
* analogy with this tree's own disk-bitmap table (byeres.s's
* RF_BMTBL) and cross-checked only by hand arithmetic against
* the six pages the spec names (0, 1, 4-7, $BF) -- not verified
* against a real ProDOS 8 memory-map consumer. Flagged here so
* the next reader knows to verify before leaning on it further.
*
* 2026-09-27 (docs/KSEG.md): moved OUT of standalone-assembly-
* plus-putbin and INTO the kernel manifest's own segment `org`
* block (playtest.s: `org KSEG_ORG` right after KSEG_LOW,
* immediately following procbye.s in the put chain) -- this file
* is now `put` directly, in the SAME assembly and symbol table
* as procbye.s, at its real link address. Its own `org`/`dsk`/
* `typ`/`put` header retired with the standalone build (the
* manifest already puts every equ file this module needs); its
* trailing `ds BYE2_ORG+BYE2_BLOB_LEN-*` pad retired too -- a
* segment file's length is whatever KSEG_LOAD actually reads
* (docs/KSEG.md "The loader"), not a fixed padded blob. BL2_REF/
* BL2_DST moved to flat BSS in procbye.s (rule 4: no `ds` in the
* segment; pure post-poison scratch, safe there). BL2_PSTG stays
* HERE (see its own declaration, below) -- moving it flat was a
* real bug, found and reverted this round: it must survive
* BYE_LEAVE's poison, and only the segment (bank 2, outside
* $0200-$BEFF) does that.
*---------------------------------------------------------------

* -- page-1 scratch (docs/BYE-SLICE1.md fact 3; header above).
* -- Free here: BYE_LEAVE (byeres.s) jumps to this blob AFTER
* -- its own poison but BEFORE ever touching $0100 for the
* -- bare-QUIT trigger, so nothing of byeres.s's own is live in
* -- this window -- $0100-$0114 (21 bytes).
BL2_PARM    equ   $0100        ;8 bytes -- READ's own param list
                               ;(count+ref+buf(2)+req(2)+
                               ;trans(2)) is the widest of the
                               ;five calls this file issues
BL2_TRIG    equ   $0108        ;6 bytes: JSR $BF00/cmd/ptrlo/hi
* -- BL2_RET: 9 bytes, not 7 -- MEASURED THE HARD WAY (2026-09-
* -- 26): PHA(1) + LDA abs(3) + LDA abs(3) + PLA(1) + RTS(1) =
* -- 9, and an earlier version of this file undercounted it as 7
* -- and placed BL2_SCRATCH two bytes too early, at $0115 --
* -- exactly on top of BL2_RET's own PLA/RTS ($0115/$0116).
* -- SET_PREFIX's real MLI dispatch ran correctly (the prefix
* -- parse, the VCB lookup, the real SmartPort driver transfer
* -- at $C7xx-$CDxx, the $BF00 postlude) because BL2_SCRATCH is
* -- built BEFORE the call and the real work doesn't touch page
* -- 1 -- but building BL2_SCRATCH had already overwritten
* -- BL2_RET+7/+8 with the prefix's own length byte and first
* -- path character, so the RTS that should have landed on
* -- BL2_RET's PLA/RTS instead executed those two bytes as
* -- opcodes and ran off into whatever they happened to decode
* -- as -- confirmed by single- stepping the real round trip: PC
* -- walked correctly through the SmartPort driver and the MLI's
* -- own $BFA0-$BFB6 postlude, then wandered into unrelated
* -- process-space code instead of returning to byelaunch.s's
* -- own OPEN step.
BL2_RET     equ   $010E        ;9 bytes: reselect bank 2 + RTS
* -- BL2_SCRATCH: the tenant's own directory, length-prefixed,
* -- built from BL2_PATH by scanning backward for the last '/'
* -- (below). 65 bytes -- the same "length + up to 64" shape as
* -- BL2_PATH itself. Starts at $0117, immediately after
* -- BL2_RET's own 9 bytes ($010E-$0116) -- NOT $0115 (see
* -- BL2_RET's own comment above for the bug that lived here).
BL2_SCRATCH equ   $0117
* -- BL2_PATH: the WORKING copy SET_PREFIX/OPEN/READ actually
* -- read, MOVED into page 1 2026-09-26 -- THE THIRD BUG this
* -- file shipped with, same shape as the "parameter list must
* -- live in page 1" lesson the header already drew for
* -- BL2_PARM, applied one level too shallow: that lesson covers
* -- the INLINE cmd+ pointer bytes ProDOS reads through the
* -- JSR's own return address, but BL2_PATH is a PATHNAME the
* -- parameter list POINTS TO, and OPEN/READ dereference that
* -- pointer AFTER ProDOS's own MLI entry has ALREADY reselected
* -- Apple bank 1 (BYE_LEAVE's header comment, same fact).
* -- BL2_PATH used to be `ds`-declared directly in this blob
* -- (bank 2) and read from there -- so procbye.s's own copy
* -- (bank 2 selected write-enabled, same six-cell-stamp window)
* -- landed correctly, but every later OPEN/READ then
* -- dereferenced that same address WHILE BANK 1 WAS SELECTED
* -- (for ProDOS's own dispatch code) and read BANK 1's
* -- unrelated resident bytes instead -- MEASURED directly: OPEN
* -- returned status $40 (INVALID_PATHNAME, confirmed against
* -- the TRM's own MLI error table) every time, with the pointer
* -- itself ($D514) correctly built and correctly read by
* -- ProDOS's own dispatch (single-stepped: A/X held $14/$D5
* -- right where the pointer is dereferenced), yet the bytes AT
* -- that address were never our pathname. Page 1 is
* -- ALTZP-governed only, so it reads correctly no matter which
* -- LC bank is selected -- the same reason
* -- BL2_PARM/BL2_TRIG/BL2_RET/BL2_SCRATCH live here.
* --
* -- BUT NOT WRITTEN HERE DIRECTLY BY procbye.s (a SECOND round
* -- of this bug, caught the same way, same day): procbye.s's
* -- own path copyin runs WHILE THE KERNEL IS STILL ALIVE, well
* -- before BYE_LEAVE's poison -- and page 1's $0100-$017F is
* -- exactly COPYIN_ENTRY/COPYOUT_ENTRY, which bankcopy.s (among
* -- others) uses as ITS OWN transient scratch for every
* -- aux<->main copy, including the very save-to-K_BYE_BANK copy
* -- PRC_BYE issues moments later in the SAME call. Landing
* -- BL2_PATH's real bytes there THAT EARLY got them overwritten
* -- by that later bankcopy before byelaunch.s ever ran --
* -- measured as an outright hang, PC parked forever at
* -- bankcopy.s's own `lda K_BC_DSTBANK`
* -- (build/MAUXPLAY.SYSTEM_Output.txt line ~4760), not a status
* -- code. So procbye.s still stages the path in the BANK-2 BLOB
* -- (BL2_PSTG, below, immune to poison, exactly like before)
* -- and BYE2_START -- running with bank 2 already selected,
* -- AFTER every kernel bankcopy call has long since finished --
* -- copies STAGE into this page-1 BL2_PATH as its OWN first
* -- action, before touching $280 or anything else. Two hops,
* -- each one valid only in the memory regime it actually runs
* -- in.
* --
* -- 65 bytes, right after BL2_SCRATCH's own 65 ($0117-$0157).
BL2_PATH    equ   $0158
* -- BL2_EXIT: page 1, 7 bytes, right after BL2_PATH's own 65
* -- ($0158-$0198) -- LDA $C082 (select read-ROM) / CLI / JMP
* -- TENANT_ORG, copied from BL2_EXITTBL (below) and JMP'd to as
* -- BYE2_START's OWN LAST action, 2026-09-27 (bug 6, the
* -- coordinator's diagnosis). NOT run in place, in the LC blob,
* -- for the SAME reason BL2_PARM/BL2_TRIG/BL2_PATH already had
* -- to move here: MEASURED, the read-ROM select takes effect
* -- for the VERY NEXT instruction fetch, and the next bytes
* -- after a bare `lda $C082` in THIS file's own LC-resident
* -- code are NOT this file's own `cli`/`jmp` opcodes once ROM
* -- is mapped in -- they are whatever the real //e monitor ROM
* -- holds at that same offset, and execution wanders into it
* -- (confirmed: PC landed in slot-2 ROM territory, $C2xx,
* -- decoding real ROM bytes as random opcodes). Page 1 is
* -- ALTZP-governed, not LC- bank/ROM-governed, so it reads
* -- correctly regardless of which side of the ROM/RAM switch
* -- the LC is currently on.
BL2_EXIT    equ   $0199
* -- named per check-encoding (a bare #$BF is flagged even
* -- though it is not TEXT) -- same constant as byeres.s's own.
BL2_MLI_HI  equ  $BF
* -- MLI command bytes, prefix bitmap byte, and the raw-output
* -- vector/INVFLAG values below -- named for the SAME reason
* -- (check-encoding's high-bit-immediate ratchet counts any
* -- `#$A0-$FE` regardless of whether it is text; none of these
* -- are).
MLI_SETPFX  equ  $C6
MLI_OPEN    equ  $C8
MLI_READ    equ  $CA
MLI_CLOSE   equ  $CC
BMP_PAGES01 equ  $CF        ;pages 0,1,4,5,6,7 protected
COUT1_LO    equ  $F0        ;CSWL -> $FDF0 (COUT1)
COUT1_HI    equ  $FD        ;CSWH
INV_NORMAL  equ  $FF        ;INVFLAG: normal (non-inverse) video
* -- SYSNAME280 moved to inc/proc.const.equ 2026-09-27
* -- (coordinator review, check-nas-librel):
* -- src/test/byetenant.s
* -- (the tenant fixture) ALSO references it, and nas-librel's
* -- own export checker refuses a cross-module EQUATE.
TENANT_ORG  equ   $2000        ;a .SYSTEM loads flat here
* -- BYE2_MAXLEN: a COURTESY stop only (see header) -- the real
* -- refusal already happened in bye.s (userland), before this
* -- blob ever ran. $7800 = the old PMLI_IBF_BASE($9800) -
* -- TENANT_ORG($2000): kept as policy when B1 moved the
* -- pool to $A000, so bye's accepted size did not grow.
BYE2_MAXLEN equ  $7800
* -- MEMBITMAP: ProDOS's own memory-usage bit map (see header's
* -- [likely] note) -- 24 bytes, $BF58-$BF6F, immediately after
* -- the global page's own AFBANK cell ($BF57). Survives the
* -- poison (which stops at $BEFF).
MEMBITMAP   equ   $BF58

BYE2_START
* -- -1. release the $C800 expansion window, 2026-09-27,
* -- UNTESTED UNTIL THIS BUILD: `grep CFFF` over this file was
* -- empty before now. maux's own console lives on slot 3's
* -- 80-column firmware ($C3xx); any access to it sets INTC8ROM,
* -- which maps the INTERNAL ROM into $C800-$CFFF until
* -- something reads CLRC8ROM ($CFFF, inc/mm.hw.equ's own
* -- comment: "READ = release every card's $C800 latch +
* -- INTC8ROM. A bare $Cnxx claim is NOT portable: release THEN
* -- claim"). verilogapple's SmartPort driver runs its transfer
* -- loop out of $C800-$CFFF (HACKING.md) and does exactly the
* -- bare claim the equ's own comment warns about -- with
* -- INTC8ROM still latched from the console, that claim does
* -- not take, and the driver jumps into $C800 expecting its own
* -- code but executing the internal ROM's bytes instead: not a
* -- crash, a wander, which matches what was actually observed
* -- (PC cycling through $C7xx-$FFxx for tens of thousands of
* -- instructions on the tenant's own CREATE call --
* -- SET_PREFIX/OPEN/READ/CLOSE never reached the driver's WRITE
* -- path, so they may simply have been getting lucky). Read
* -- here, ONCE, before SET_PREFIX -- released state persists as
* -- a hardware latch, not something a JMP or a bank switch
* -- resets, so this also covers the tenant's own later CREATE
* -- without needing a second read (one is added anyway right
* -- before the JMP $2000, in case anything between here and
* -- there re-latches it -- cheap insurance, not a guess).
            lda   CLRC8ROM
* -- 0. stage -> page 1 (BL2_PATH's own equ comment above): bank
* -- 2 is still the currently-selected bank right here (a plain
* -- JMP from BYE_LEAVE, no bank switch in between), so this
* -- read of BL2_PSTG is correct, and it MUST happen before
* -- anything below that reads BL2_PATH (the very next step
* -- already does).
            ldx   #64
:cpp1       lda   BL2_PSTG,x
            sta   BL2_PATH,x
            dex
            bpl   :cpp1

* -- 1. $280: the system program name, length-prefixed, exactly
* -- as ProDOS stamps it for a normal .SYSTEM launch -- ordinary
* -- main memory, no MLI call needed (docs/BYE.md item 3).
            ldx   BL2_PATH
:cpsysnm    lda   BL2_PATH,x
            sta   SYSNAME280,x
            dex
            bpl   :cpsysnm

* -- install BL2_RET once (header's own "the reselect also
* -- happens on the way back" note): PRESERVE A (the MLI's own
* -- status/errno -- FOUND BY MEASUREMENT, not designed in: a
* -- first version omitted the PHA/PLA, and `LDA LCBANK1_RAM`
* -- SILENTLY CLOBBERED A with the soft switch's own read value
* -- before the caller ever saw it, so EVERY BL2_CALL appeared
* -- to return A=0/success regardless of the real MLI result --
* -- READ's own trans_count was legitimately never written
* -- because the read was actually failing, and nothing here
* -- ever saw the real error code to say so), re-select Apple
* -- bank 2 write-enabled, restore A, THEN RTS. Every BL2_CALL
* -- below lands here after its own raw MLI call, regardless of
* -- which command.
            ldx   #8
:cpret      lda   BL2_RETTBL,x
            sta   BL2_RET,x
            dex
            bpl   :cpret

* -- 2. CLOSE refnum 0 is NOT here. DEVIATION from docs/BYE.md
* -- item 3's own listed order, MEASURED: a real MLI CLOSE(0)
* -- issued from HERE (after poison) walks ProDOS's own FCB
* -- table, which lives BELOW $BF00 and is therefore already
* -- destroyed by BYE_LEAVE's own poison fill -- it read
* -- poisoned $AA bytes as "open" entries with garbage device
* -- addresses and jumped into them (measured directly:
* -- landed at $C20B, decoding as BRK, on the very first launch
* -- attempt). PRC_BYE (procbye.s) now issues this CLOSE(0)
* -- ITSELF, in kernel context, right after PBY_PARK_ALL
* -- succeeds and BEFORE BYE_LEAVE's poison runs -- ProDOS's own
* -- FCB table is still intact there, and every OFT-tracked file
* -- was already parked or closed by PBY_PARK_ALL, so this
* -- covers only whatever ProDOS itself still thinks is open.

* -- 3. clear then protect the memory bit map -- see header's
* -- [likely] note. Protect pages $00 (zero page), $01 (stack),
* -- $04-$07 (text), $BF (the ProDOS global page itself, the
* -- LAST page this bitmap covers) -- MSB-first bit order, the
* -- same convention this tree's own disk-bitmap table
* -- (byeres.s RF_BMTBL) already uses. No MLI call: plain
* -- memory, and it SURVIVES the poison ($BF00-$BFFF is
* -- excluded from it).
            ldx   #23
            lda   #0
:bmzero     sta   MEMBITMAP,x
            dex
            bpl   :bmzero
            lda   #BMP_PAGES01              ;pages 0,1,4,5,6,7
            sta   MEMBITMAP
            lda   #$01                    ;page $BF -- bit 7 of
            sta   MEMBITMAP+23            ;the 24th byte

* -- 4. prefix set to the tenant's own directory (docs/BYE.md
* -- item 3): scan BL2_PATH backward for the last '/' and copy
* -- everything up to and including it into BL2_SCRATCH,
* -- length-prefixed. BL2_PATH holds LOW-BIT (plain 7-bit) ASCII
* -- -- CORRECTED 2026-09-26, reversing an earlier wrong claim
* -- here that it was high-bit: BL2_PATH is copied wholesale
* -- from the kernel's own PRC_PATHBUF (procbye.s), and
* -- PRC_PATHBUF is built by procfd.s's
* -- PCPY_MLI_PATH/PCPY_PATH_G, which does `and #$7F` on every
* -- character it copies in (that routine's own comment: "ProDOS
* -- masks path high bits (TRM 2.1), GET_ PREFIX returns low
* -- ASCII"). The earlier claim was reasoned from a live
* -- comparison that DID succeed against a bare `"/"` (merlin32
* -- evaluates a double-quoted literal high-bit, $AF) -- but
* -- that success was a coincidence of the OTHER bug fixed
* -- alongside this one (BL2_PATH used to live in bank 2 and was
* -- read back through a bank-1-selected pointer dereference, so
* -- the backward scan was comparing against WRONG-BANK garbage
* -- the whole time, not real path bytes; it happened to fall
* -- through to an empty prefix, and SET_PREFIX with an empty
* -- pathname is a harmless no-op on a machine whose prefix was
* -- already "/MAUX"). With BL2_PATH now correctly in page 1
* -- (see its own equ comment above), the real bytes are
* -- visible, and they are low-bit -- so the comparison must be
* -- too.
            ldx   BL2_PATH
:findsl     lda   BL2_PATH,x
            cmp   #'/'
            beq   :foundsl
            dex
            bne   :findsl
:foundsl    stx   BL2_SCRATCH
            ldy   #0
:cppfx      cpy   BL2_SCRATCH
            beq   :pfxdone
            iny
            lda   BL2_PATH,y
            sta   BL2_SCRATCH,y
            bra   :cppfx
:pfxdone    lda   #<BL2_SCRATCH
            sta   BL2_PARM+1
            lda   #>BL2_SCRATCH
            sta   BL2_PARM+2
            lda   #1
            sta   BL2_PARM
            lda   #MLI_SETPFX               ;SET_PREFIX
            jsr   BL2_CALL

* -- 5. OPEN the tenant, using a fixed, otherwise-idle 1 KB
* -- transfer window at PMLI_IBF_BASE ($A000) for the MLI's own
* -- io_buffer -- nothing else needs that memory at this point
* -- in the round trip (docs/BYE.md item 4's own reasoning for
* -- the $7800 read-window ceiling).
            lda   #3
            sta   BL2_PARM
            lda   #<BL2_PATH
            sta   BL2_PARM+1
            lda   #>BL2_PATH
            sta   BL2_PARM+2
            stz   BL2_PARM+3
            lda   #>PMLI_IBF_BASE
            sta   BL2_PARM+4
            lda   #MLI_OPEN                 ;OPEN
            jsr   BL2_CALL
            lda   BL2_PARM+5              ;ref_num result
            sta   BL2_REF

* -- 6. READ the tenant flat into TENANT_ORG ($2000), one 256-
* -- byte page at a time -- simple beats fast here; this code
* -- path runs once per `bye`. Stop on a short read (real EOF)
* -- or at BYE2_MAXLEN (the courtesy stop; see header and
* -- BYE2_MAXLEN's own comment -- bye.s's own userland check
* -- already refused anything that could reach it).
            lda   #<TENANT_ORG
            sta   BL2_DST
            lda   #>TENANT_ORG
            sta   BL2_DST+1
:rdloop     lda   #4
            sta   BL2_PARM
            lda   BL2_REF
            sta   BL2_PARM+1
            lda   BL2_DST
            sta   BL2_PARM+2
            lda   BL2_DST+1
            sta   BL2_PARM+3
            stz   BL2_PARM+4
            lda   #1                      ;request 256 ($0100)
            sta   BL2_PARM+5
            lda   #MLI_READ                 ;READ
            jsr   BL2_CALL
            lda   BL2_PARM+6              ;trans_count lo
            ora   BL2_PARM+7              ;trans_count hi
            beq   :rddone                 ;0 transferred: EOF
            inc   BL2_DST+1
            lda   BL2_DST+1
            cmp   #>PMLI_IBF_BASE         ;courtesy stop only --
            bcs   :rddone                 ;see BYE2_MAXLEN's own
                                          ;comment
* -- SHORT-READ CHECK, FIXED 2026-09-26 (found by
* -- single-stepping the real round trip): the request is always
* -- exactly 256 ($0100), so a FULL transfer is the ONLY case
* -- with a nonzero trans_count HIGH byte -- checking that byte
* -- for zero is a correct, self-contained "< 256 transferred"
* -- test needing no assumption about the low byte at all. The
* -- previous version compared the LOW byte alone against 1
* -- (`cmp #1 / bcc`), which cannot distinguish a short read
* -- from a full one: for our 248-byte ($F8) test tenant that
* -- compare set carry (since $F8>=1) and NEVER took the branch,
* -- so the loop free-ran past real EOF toward the pool-base
* -- courtesy stop, ~120 needless READ calls later, instead of
* -- stopping on the very first (short) read -- confirmed
* -- directly: single-stepping the real launch showed the
* -- identical MLI dispatch pattern repeating dozens of times
* -- after the tenant's own 248 bytes were already in place at
* -- $2000.
            lda   BL2_PARM+7              ;trans_count hi: 0 = a
            beq   :rddone                 ;short read (< 256)
            bra   :rdloop
:rddone

* -- 7. CLOSE the tenant.
            lda   #1
            sta   BL2_PARM
            lda   BL2_REF
            sta   BL2_PARM+1
            lda   #MLI_CLOSE                ;CLOSE
            jsr   BL2_CALL

* -- 8. the glass: text, page 1, 40 columns, 80STORE off (plain
* -- memory-mapped soft switches, no MLI call). Drop
* -- UT_PAGE_CTL's VIDSEL bit UNCONDITIONALLY (docs/BYE.md item
* -- 5) so the
* -- motherboard's own video passes through -- harmless to write
* -- when no UltraTerm sits in the slot, or when it was never
* -- initialized, at all. NOT gated on the card's own single-vs-
* -- dual-head state (a deviation, MEASURED: computing that flag
* -- cost procbye.s's own tight PT_HOLD headroom more than this
* -- slice could spare -- see procbye.s's own comment and
* -- docs/BYE-SLICE1-NOTES.md). A dualhead card's second-monitor
* -- passthrough is therefore also dropped for the tenant's run
* -- and NOT restored on resume -- a named, untested gap for a
* -- UT-booted machine; `vidmode hq` recovers it by hand.
* --
* -- COL80OFF ($C00C) ADDED 2026-09-27, MEASURED: the comment
* -- above always claimed "40 columns" but the code never
* -- actually cleared the 80-COLUMN DISPLAY softswitch (COL80,
* -- $C00C/$C00D) -- only 80STORE (a MEMORY addressing mode, a
* -- different switch). maux's own console runs in 80 columns,
* -- so COL80 was still SET when the tenant took over; its $FDED
* -- COUT calls then wrote through the ordinary 40-column-shaped
* -- monitor routine while the hardware displayed the
* -- interleaved main/aux 80-column page, producing a garbled
* -- every-other-column glass -- confirmed directly: the tenant
* -- ran and wrote real text, but screen_text() (and a person
* -- looking at the glass) saw it shredded across two
* -- interleaved halves.
            sta   TEXTMODEON
            sta   PAGE2OFF
            sta   HIRESOFF
            sta   CLR80STORE
            sta   COL80OFF
            stz   UT_PAGE_CTL

* -- 8a. real-ROM zero-page monitor conventions, 2026-09-27,
* -- MEASURED: with all four MLI calls (SET_PREFIX/OPEN/READ/
* -- CLOSE) confirmed succeeding (A=0 every time, READ's own
* -- trans_count reading exactly $F8 -- the tenant's real size)
* -- and the launch reaching $2000, the glass STILL showed
* -- nothing but the poison byte ($AA, which paints as `*`) --
* -- no visible "TENANT RAN" anywhere. Main's zero page is
* -- MAUX's OWN layout (never Apple-monitor-shaped -- this
* -- machine is never "hosted", BYE_LEAVE's poison starts at
* -- $0200 and never touches $0000-$01FF at all), so a real
* -- ProDOS 8 .SYSTEM's $FDED COUT calls inherit whatever the
* -- KERNEL happened to leave in WNDLFT/WNDWDTH/WNDTOP/WNDBTM/
* -- CH/CV/BASL/BASH/CSWL/CSWH -- garbage window bounds or a
* -- garbage output vector, not necessarily a visible on-screen
* -- write at all. Set the handful of cells a cold ROM reset
* -- would: 40-column full-height window, cursor at row 0 col 0,
* -- BASL/BASH pointing at row 0's own base ($0400), CSWL/CSWH
* -- at the standard raw-output entry ($FDF0), normal (non-
* -- inverse) video. Cheap here -- byelaunch.s pads to
* -- BYE2_BLOB_LEN with ~400 B to spare -- unlike procbye.s's
* -- own razor-thin PT_HOLD headroom.
            stz   $20                     ;WNDLFT
            lda   #40
            sta   $21                     ;WNDWDTH
            stz   $22                     ;WNDTOP
            lda   #24
            sta   $23                     ;WNDBTM
            stz   $24                     ;CH
            stz   $25                     ;CV
            stz   $28                     ;BASL (row 0 = $0400)
            lda   #$04
            sta   $29                     ;BASH
            lda   #COUT1_LO
            sta   $36                     ;CSWL -> $FDF0 (COUT1)
            lda   #COUT1_HI
            sta   $37                     ;CSWH
            lda   #INV_NORMAL
            sta   $32                     ;INVFLAG: normal video

* -- 8a. release $C800 again, cheap insurance (see the -1
* -- comment at BYE2_START) -- nothing between there and here is
* -- known to re-latch INTC8ROM, but the tenant's own CREATE is
* -- the one real block WRITE this whole mechanism has ever
* -- attempted, so a second free read costs 3 bytes to rule the
* -- question out rather than assume it.
            lda   CLRC8ROM

* -- 8b/9/10. SELECT READ-ROM, CLI, JMP $2000 -- via BL2_EXIT
* -- (page 1), 2026-09-27 (bug 6, the coordinator's own
* -- diagnosis, confirmed against docs/LANGUAGE-CARD.md's own
* -- measured ProDOS QUIT dispatcher: "LDA $C082 ... switch ROM
* -- in, hand the machine back", CLI only AFTER). maux's own LC
* -- ratchet (check-lc, docs/LANGUAGE-CARD.md) permits ONLY
* -- $C083/$C08B tree-wide -- under maux the language card is
* -- NEVER read-ROM. A tenant inherits that: $D000-$FFFF still
* -- reads as LC RAM (ProDOS's own MLI image, or this resident)
* -- when control passes to $2000. The tenant's own MLI calls
* -- (CREATE etc.) are unaffected -- $BF00's own dispatch
* -- reselects read-RAM/write-enable on entry regardless of
* -- prior state, docs/LANGUAGE-CARD.md's own measured `BIT
* -- $C08B x2` -- but a bare ROM call like $FDED (COUT) is not
* -- an MLI call: it fetches straight from whatever the LC
* -- currently maps, and finds MLI bytes (or a stray $00)
* -- instead of the real monitor ROM. MEASURED, live: the
* -- tenant's own first $FDED call hit a real BRK (stacked P had
* -- the B flag SET, not a hardware IRQ) barely past $FDED, at
* -- $FDF7 -- inside COUT's own address range with COUT itself
* -- unmapped. This is the read-ROM window `shutdown -r`'s own
* -- header already named as "bye's to open". A bare read of
* -- $C082 (read-ROM, write-protect -- the bank is irrelevant
* -- for a read, and the tenant's own MLI calls reselect
* -- whichever bank they need on entry; write-protect is the
* -- safer half to leave selected) is EXEMPTED in
* -- scripts/check_lc.py, same rationale proshim.s already
* -- carries.
* --
* -- NOT run in place: a SECOND bug, found by MEASURING this
* -- file's own first attempt, not guessed -- the read-ROM
* -- select takes effect for the VERY NEXT instruction fetch,
* -- and this file's own following bytes (`cli`/`jmp`) are then
* -- fetched FROM ROM, not from this LC-resident blob -- PC
* -- wandered into real monitor-ROM bytes decoded as random
* -- opcodes (confirmed: landed in slot-2 ROM territory, $C2xx).
* -- Page 1 (BL2_EXIT) is ALTZP-governed, not
* -- LC-bank/ROM-governed, so it fetches correctly on either
* -- side of the switch -- the SAME reason
* -- BL2_PARM/BL2_TRIG/BL2_PATH already had to move here.
            ldx   #6
:cpexit     lda   BL2_EXITTBL,x
            sta   BL2_EXIT,x
            dex
            bpl   :cpexit
            jmp   BL2_EXIT

*---------------------------------------------------------------
* BL2_CALL -- issue one raw MLI call from page 1 (header). IN:
* A = the MLI command byte; BL2_PARM already built by the
* caller. OUT: A/carry = the MLI's own status (0/clear =
* success). Clobbers A, X, Y, and re-selects Apple bank 2
* write-enabled on the way back (see BL2_RET / header).
*---------------------------------------------------------------
BL2_CALL    sta   BL2_TRIG+3
            lda   #$20                    ;JSR opcode
            sta   BL2_TRIG
            stz   BL2_TRIG+1
            lda   #BL2_MLI_HI
            sta   BL2_TRIG+2
            lda   #<BL2_PARM
            sta   BL2_TRIG+4
            lda   #>BL2_PARM
            sta   BL2_TRIG+5
            jmp   BL2_TRIG

* -- BL2_RETTBL: PHA (save the MLI's own status), LDA
* -- LCBANK1_RAM (x2, latches write-enable), PLA (restore it),
* -- RTS -- copied into BL2_RET (page 1) once, at BYE2_START.
* -- LCBANK1_RAM is
* -- this tree's OWN (Apple-inverted) name for the bank-2 select
* -- address, docs/BYE.md's naming-trap note.
BL2_RETTBL  dfb   $48                     ;PHA
            dfb   $AD
            da    LCBANK1_RAM
            dfb   $AD
            da    LCBANK1_RAM
            dfb   $68                     ;PLA
            dfb   $60                     ;RTS

* -- BL2_EXITTBL: LDA $C082 (select read-ROM) / CLI / JMP
* -- TENANT_ORG -- copied into BL2_EXIT (page 1) once, at
* -- BYE2_START's own last action (see BL2_EXIT's own equ
* -- comment for why this cannot run in place).
BL2_EXITTBL dfb   $AD
            da    $C082
            dfb   $58                     ;CLI
            dfb   $4C
            da    TENANT_ORG

* -- BL2_REF/BL2_DST moved to flat BSS in procbye.s (2026-09-27,
* -- docs/KSEG.md rule 4) -- pure post-poison scratch, safe
* -- flat.
*
* BL2_PSTG stays HERE (a `ds`, in the segment), and moving it to
* flat BSS was a REAL BUG this round found and reverted, not a
* style choice: PRC_BYE (kbye.s, segment-resident, "PRC_BYE
* MOVES") writes it BEFORE BYE_LEAVE's poison runs; BYE2_START
* above reads it as its OWN FIRST ACTION, AFTER the poison runs.
* Poison fills $0200-$BEFF -- exactly where flat BSS lives -- so
* the flat placement would have handed BYE2_START back $AA
* poison
* bytes instead of the real tenant path, corrupting every launch
* silently (never caught: MAUXPLAY was not boot-tested between
* that move landing and this fix). A `ds` HERE is immune to the
* poison (bank 2, $D400-$DFFF, outside the poisoned $0200-$BEFF
* range) -- exactly the property the pre-segment design relied
* on
* ("immune to poison, exactly like before", this file's own
* header comment above). Rule 4 exists for data the MLI or
* BankCopy must dereference from OUTSIDE the segment (F4's own
* wrong-bank hazard) -- neither ever touches BL2_PSTG; it is a
* pure intra-segment handoff between two segment-resident
* routines (PRC_BYE and BYE2_START, both here now), so the
* hazard
* rule 4 guards against does not apply to it.
BL2_PSTG    ds    65
