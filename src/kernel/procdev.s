*---------------------------------------------------------------
* procdev.s -- the kernel cold segment's loader (docs/KSEG.md)
* and the /dev/sNdM block-device REAL glue (docs/DEV-BLOCK.md).
*
* SCOPED BY MODULE CHOICE, NOT CONDITIONAL ASSEMBLY (2026-09-27,
* coordinator review, REPLACING `do ]KSEG_WANT ... fin`): nas
* has
* no `do`/`fin` directive at all (src/asm/nas.pla's own
* directive
* table has no D_DO/D_FIN), and nas is the assembler of record
* (docs/NAS.md) -- the checked dialect must equal what nas
* assembles, not the other way round. Separately, merlin32's own
* `do` with a VARIABLE label resolves to that variable's FINAL
* value FILE-WIDE, not the value at the point of the `do` --
* measured directly this round -- so a directive whose meaning
* depends on where in the file you look was never something this
* tree should have leaned on regardless of nas.
*
* This file is `put` ONLY by a manifest that carries the segment
* (today, src/test/playtest.s); every other full-kernel manifest
* puts src/kernel/procdevs.s instead, which stubs every label
* here with a "no such device"/no-op answer -- see that file's
* own header for the full label list. The SHARED modules
* (procmli.s, procmli3.s, procfile3.s, process.s, procfile5.s)
* reference ONLY those labels, unconditionally, so a missing
* `put` line for EITHER this file or its stub is a genuine link
* error (dangling reference), not a silent miscompile.
*---------------------------------------------------------------
* -- KSEG_ORG itself lives in inc/mm.hw.equ, not here:
* -- playtest.s's
* -- own top-level `org KSEG_ORG` (the segment's own org line)
* -- is
* -- CROSS-MODULE usage from a REL-object point of view, and
* -- nas-librel's own export checker refuses to export an EQUATE
* -- another module (or the top-level manifest) references
* -- (2026-09-27, coordinator review, check-nas-librel) --
* -- KSEG_MAXPG/K_HALT_KSEG stay here since only this file uses
* -- them.
KSEG_MAXPG  equ   12           ;3072 B = 12 pages, the
                                ;hardware ceiling (KSEG_LOAD's
                                ;own oversize check)
K_HALT_KSEG equ   $4B          ;'K' -- K_HALT_MARK reason byte

*---------------------------------------------------------------
* KSEG_LOAD -- ONE loader for both `/MAUX/BYERES` and the KSEG
* segment file (docs/KSEG.md "The loader" -- PBY_LOAD_RES
* generalised; coordinator review 2026-09-27: "ONE loader, not
* two", consolidating what was briefly a second, parallel
* mechanism). Opens the path the CALLER has already pointed
* PML_OPN_PARMS+MLI_PATHLO/HI at directly (count-prefixed, ANY
* convention -- ASCII case doesn't matter to the MLI, TRM 2.1)
* --
* no caller-side copy into PRC_PATHBUF at all; this routine
* restores the pointer to PRC_PATHBUF (every OTHER kernel
* opener's assumption) immediately after the OPEN call, so
* nothing else in the kernel can observe the redirection. Reads
* up to KL_MAXPG 256-byte pages into KL_DESTHI:00, stopping at
* the first ZERO-byte read.
*
* EVERY FILE THIS ROUTINE LOADS MUST BE PADDED TO A 256-BYTE
* BOUNDARY (byeres.bin already is, by its own trailing `ds`;
* split_kseg.py pads MAUXPLAY_KSEG the same way) -- this is what
* lets the read loop drop the old partial-last-page copy path
* entirely: a short-but-nonzero read cannot legitimately happen
* and is treated as a plain MLI error like any other short read
* would be (`:rderr`, via the `bne` fallthrough below), not a
* silent truncation.
*
* IN:  PML_OPN_PARMS+MLI_PATHLO/HI (path pointer, caller-set),
*      KL_DESTHI (destination page), KL_MAXPG (ceiling in pages
* --
*      KSEG_MAXPG for the segment, 3 for byeres.bin's fixed 768
* B).
* OUT: carry CLEAR, KL_PGCNT = whole 256-B pages loaded (0 is
*      legal; callers needing a nonzero minimum check it
*      themselves); or carry SET, A = the real MLI/kernel error
* --
*      PRC_FAIL_A is NOT called here (a boot-time caller wants
*      PRC_HALT_CORE; PBY_LOAD_RES calls PRC_FAIL_A itself). A
*      full KL_MAXPG pages with no zero terminator is ERR_INVAL
*      (oversize).
* Clobbers A, X, Y.
*---------------------------------------------------------------
KSEG_LOAD
* -- the caller writes the path pointer DIRECTLY into
* -- PML_OPN_PARMS+MLI_PATHLO/HI (no KL_PATHLO/KL_PATHHI
* -- intermediary -- coordinator review 2026-09-27, one fewer
* -- copy: both callers already build the address as an
* -- immediate, so targeting the real field costs them nothing
* -- extra and saves this routine 8 B + 2 B of cells).
            jsr   PRC_ALLC_IBF
            bcc   :ibfok
            rts                     ;PRC_ALLC_IBF already set
                                    ;carry+A; nothing to unwind
                                    ;(the path pointer is fixed
                                    ;up on the NEXT call -- no
                                    ;one else reads it first)
:ibfok      sta   PRC_IOBUF_ID
            stz   PML_OPN_PARMS+MLI_IOBUFLO
            jsr   PRC_IBF_HI_A
            sta   PML_OPN_PARMS+MLI_IOBUFHI
            jsr   PMLI_OPN_CALL
            pha
* -- restore the shared OPEN parmlist's path pointer to
* -- PRC_PATHBUF (every OTHER opener's assumption) BEFORE any
* -- exit -- one write, not a save/restore pair, since it is
* -- always this same fixed value between calls.
            lda   #<PRC_PATHBUF
            sta   PML_OPN_PARMS+MLI_PATHLO
            lda   #>PRC_PATHBUF
            sta   PML_OPN_PARMS+MLI_PATHHI
            pla
            beq   :openok
            pha
            lda   PRC_IOBUF_ID
            jsr   PRC_FR_IBF_A
            pla
            sec
            rts

:openok     lda   PML_OPN_PARMS+MLI_OPEN_REF
            sta   KL_REF
            sta   PMLI_RD_PARMS+MLI_REF

* -- select Apple bank 2, write-enabled: double read latches
* -- write-enable, same idiom every LC writer in this tree opens
* -- with (docs/LANGUAGE-CARD.md). Harmless when KL_DESTHI names
* -- a main-memory page (BYERES's own $D1 IS the LC, always).
            lda   LCBANK1_RAM
            lda   LCBANK1_RAM

            lda   #<PMLI_XFER_BUF
            sta   PMLI_RD_PARMS+MLI_BUFLO
            lda   #>PMLI_XFER_BUF
            sta   PMLI_RD_PARMS+MLI_BUFHI
            stz   PMLI_RD_PARMS+MLI_REQLO
            lda   #1
            sta   PMLI_RD_PARMS+MLI_REQHI   ;256 = $0100
            stz   KL_PGCNT
:chunk      stz   PMLI_RD_PARMS+MLI_TRANSLO
            stz   PMLI_RD_PARMS+MLI_TRANSHI
            jsr   PMLI_RD_CALL
            beq   :readok
* -- MLI_ERR_EOF ($4C) is READ's own "you are at the end of the
* -- file" status -- a REAL nonzero MLI status, not a generic
* -- failure (MEASURED 2026-09-27: a padded, whole-256-page file
* -- makes the lap AFTER the last real page come back this way,
* -- trans_count 0/0 -- treating it as a plain error halted
* -- every boot with K_HALT_MARK $4C until this check was
* -- added). A real EOF status transfers 0 bytes by definition,
* -- so it is safe to fall straight into :readok's OWN
* -- trans_count==0/0 test below rather than branching around it
* -- separately -- one shared check instead of two, folded in
* -- 2026-09-27 to win back headroom bytes without weakening
* -- either check.
            cmp   #MLI_ERR_EOF
            bne   :close            ;a real, non-EOF MLI error
                                    ;-- A already holds it;
                                    ;:close's own `pha` is the
                                    ;only push
:readok     lda   PMLI_RD_PARMS+MLI_TRANSLO
            bne   :close            ;not 0 or 256 -- treat as
                                    ;the same class of error a
                                    ;real MLI failure would be
                                    ;(A is stale -- named risk,
                                    ;see notes)
            lda   PMLI_RD_PARMS+MLI_TRANSHI
            beq   :done             ;0/0 this lap -- clean EOF,
                                    ;the padding convention's
                                    ;whole point
            lda   KL_PGCNT
            cmp   KL_MAXPG
            bcs   :oversize
            clc
            adc   KL_DESTHI
            sta   :cdst+2
            ldy   #0
:cfull      lda   PMLI_XFER_BUF,y
:cdst       sta   $0000,y
            iny
            bne   :cfull
            inc   KL_PGCNT
            bra   :chunk
* -- REAL BUG, found by boot-testing 2026-09-27: a first fix
* -- gave :done its OWN separate close+free tail so CLC could be
* -- set AFTER the calls, but that duplicated the 4-instruction
* -- close+free pair and cost the pinned headroom floor. Read
* -- the two routines instead of guessing again (procfd2.s):
* -- PCLS_RAWREF_A stores A into the CLOSE parm list and falls
* -- straight into the MLI call -- carry on return is literally
* -- the MLI call's own status flag, SET whenever the close
* -- itself errors. PRC_FR_IBF_A is worse: on its taken branch
* -- (A non-zero, the common case here) it runs `sec` as part of
* -- computing `sbc #1`, so carry comes back SET on that path
* -- regardless of anything -- it is not even trying to signal
* -- success/failure, that's incidental to the subtract. Neither
* -- routine's carry can be trusted, confirming the original bug
* -- and ruling out any fix that relies on carry surviving the
* -- calls. Fix: stash the verdict on the STACK (0 = clean EOF,
* -- else the real MLI/kernel error byte) BEFORE the shared
* -- calls, run the ONE shared close+free pair, then derive
* -- carry from the stashed byte AFTERWARD -- pla leaves the
* -- real error code in A for the failure return too, exactly
* -- matching KSEG_LOAD's OUT contract (A = the real error).
:oversize   lda   #ERR_INVAL
:close      pha                     ;stash the real error
                                    ;(nonzero)
            bra   :tail
:done       pha                     ;A is already 0 here --
                                    ;reached only via the
                                    ;trans_count==0/0 test
                                    ;above, never independently
:tail       lda   KL_REF
            jsr   PCLS_RAWREF_A
            lda   PRC_IOBUF_ID
            jsr   PRC_FR_IBF_A
            pla
            bne   :lfail
            clc
            rts
:lfail      sec
            rts

KL_DESTHI   ds    1
KL_MAXPG    ds    1
KL_PGCNT    ds    1
KL_REF      ds    1

*---------------------------------------------------------------
* KSEG_CALL -- the segment trampoline (docs/KSEG.md "The
* trampoline"). One inline pointer per call site:
*     jsr   KSEG_CALL
*     da    KSEG_ROUTINE       ; the segment label
*     ...                      ; resumes here, bank $C08B
* Pulls the return address, reads the 2-byte pointer that
* follows the `jsr KSEG_CALL`, selects LCBANK1_RAM (one read --
* the write-enable latch is already set and stays set, docs/
* LANGUAGE-CARD.md), JSRs the target with A/X/Y intact via a
* self-modified `jsr` (flat code -- rule 8's "no self-modifying
* code" binds the SEGMENT, not this trampoline), re-selects
* LCBANK2_RAM on return WITHOUT disturbing carry or A (`lda`
* sets N/Z only; error returns are carry+A), and returns past
* the inline pointer. Clobbers X, Y always; A only if the
* segment routine itself clobbers it (its own contract).
*---------------------------------------------------------------
KSEG_CALL
            pla
            sta   P_TMP
            pla
            sta   P_TMP2
* -- P_TMP2:P_TMP = address of the JSR's own last byte
* -- (jsr_addr+2) -- advance ONE to the inline pointer itself.
            inc   P_TMP
            bne   :p1
            inc   P_TMP2
:p1         ldy   #0
            lda   (P_TMP),y
            sta   :trg+1
            iny
            lda   (P_TMP),y
            sta   :trg+2
* -- advance ONE more: P_TMP2:P_TMP is now (pointer_addr+1) =
* -- resume_addr-1, exactly what THIS routine's own final `rts`
* -- needs pushed. Same cheap 16-bit-increment idiom as above
* -- (budget trim, coordinator review -- this used to be a
* -- clc/adc#1 sequence, 5 B more for the identical result).
            inc   P_TMP
            bne   :p2
            inc   P_TMP2
:p2         lda   P_TMP2
            pha
            lda   P_TMP
            pha
            lda   LCBANK1_RAM
:trg        jsr   $0000
            pha
            lda   LCBANK2_RAM
            pla
            rts

*---------------------------------------------------------------
* K_BOOTPFX -- the boot volume's ProDOS prefix PLUS the "KSEG"
* suffix, captured/built ONCE at boot (KSEG_BOOT) so the same
* ready-to-open path serves the initial segment load and every
* reload after a `bye` tenant returns (PRC_INIT does not change
* the prefix before this runs; this is the FIRST MLI call it
* issues). Length byte + up to 21 content bytes
* ("/VOLNAME/KSEG" -- a ProDOS volume name is 1-15 chars, so
* both slashes + 15 + "KSEG" is the true ceiling).
*---------------------------------------------------------------
K_BOOTPFX   ds    22

*-- K_MNT -- one byte per unit nibble (DSSS0000 >> 4): 2 = a
*-- Disk ][ the user MOUNTED (docs/VROOT.md). Fast units need
*-- no entry.
K_MNT       ds    16

*---------------------------------------------------------------
* KSEG_RELOAD -- the reload entry, reached two ways: PRC_INIT's
* own KSEG_BOOT (below, boot time, AFTER K_BOOTPFX is built) and
* BB_KSGVEC_A (kbye.s stamps this address into the resident,
* byeres.s, which jumps here directly on the way back in from a
* `bye` round trip -- K_BOOTPFX does not change between calls,
* so no prefix rebuild here). Halts (K_HALT_KSEG) rather than
* failing a syscall: a missing or truncated segment on the way
* back in from `bye` has no live process to report the failure
* to via the ordinary path.
*---------------------------------------------------------------
KSEG_RELOAD
            lda   #>KSEG_ORG
            ldx   #KSEG_MAXPG
            jsr   KSEG_ONE
*-- the play-only low segment (docs/LOOP-S1.md): the same prefix
*-- with "LSEG" for "KSEG" -- the 'K' sits 3 bytes from the end.
            ldy   K_BOOTPFX
            lda   #'L'
            sta   K_BOOTPFX-3,y
            lda   #>LSEG_ORG
            ldx   #LSEG_MAXPG
            jsr   KSEG_ONE
            ldy   K_BOOTPFX
            lda   #'K'
            sta   K_BOOTPFX-3,y
            rts

*-- KSEG_ONE -- load K_BOOTPFX into page A, X pages at most;
*-- halts (no live process to report to) on any failure.
KSEG_ONE    sta   KL_DESTHI
            stx   KL_MAXPG
            lda   #<K_BOOTPFX
            sta   PML_OPN_PARMS+MLI_PATHLO
            lda   #>K_BOOTPFX
            sta   PML_OPN_PARMS+MLI_PATHHI
            jsr   KSEG_LOAD
            bcs   :kfail
            lda   KL_PGCNT
            bne   :krdone
:kfail      lda   #K_HALT_KSEG
            jmp   PRC_HALT_CORE
:krdone     rts

*---------------------------------------------------------------
* KSEG_BOOT -- PRC_INIT's ONE call site (process.s),
* unconditional
* in every full-kernel image; the stub in procdevs.s is a plain
* `rts` (nothing to load). Captures+builds K_BOOTPFX: GET_PREFIX
* writes straight into it via PMLI_GPFX_CL/PRC_PARM (no
* PRC_CANON
* hop), then "KSEG" is appended in place, with one conditional
* slash-insert -- then jsr KSEG_RELOAD does the actual load. The
* FIRST real MLI call PRC_INIT issues (PRC_RAMDIS pokes the
* global page directly, no MLI) -- the io_buffer pool is already
* zeroed by the time PRC_INIT reaches this call, so PRC_ALLC_IBF
* (inside KSEG_LOAD's own PMLI_OPN_CALL bracket) is safe here.
*---------------------------------------------------------------
KSEG_BOOT
            lda   #1
            sta   PRC_PARM
            lda   #<K_BOOTPFX
            sta   PRC_PARM+1
            lda   #>K_BOOTPFX
            sta   PRC_PARM+2
            jsr   PMLI_GPFX_CL
            bne   :kbfail
            ldx   K_BOOTPFX
            cpx   #18               ;17 ("/"+15+"/") + "KSEG"
            bcs   :kbfail           ;(4) = 21 + length byte = 22
*-- GET_PREFIX's result already ends in '/' (P8 TRM: "bracketed
*-- by slashes"): the guard that appended one when missing
*-- (13 B) was never read -- deleted (docs/KGAPS-NOTES.md).
            inx
            lda   #'K'
            sta   K_BOOTPFX,x
            inx
            lda   #'S'
            sta   K_BOOTPFX,x
            inx
            lda   #'E'
            sta   K_BOOTPFX,x
            inx
            lda   #'G'
            sta   K_BOOTPFX,x
            stx   K_BOOTPFX
            bra   :kbok
:kbfail     lda   #K_HALT_KSEG
            jmp   PRC_HALT_CORE
:kbok       jsr   KSEG_RELOAD
            rts

*---------------------------------------------------------------
* /dev/sNdM block devices (docs/DEV-BLOCK.md). OFT_BLK per-slot
* state: a block device has no ProDOS refnum, so it needs none
* of
* OFT_REFNUM/OFT_IOBUF/OFT_LRU (process.s) -- only the unit and
* a
* 24-bit byte position. Parallel arrays, same convention as
* every
* OFT_* table in process.s.
*---------------------------------------------------------------
OFT_UNIT     ds OFT_COUNT        ;DSSS0000 unit_num, set at open
OFT_BLKPOS0  ds OFT_COUNT        ;24-bit byte position, lo
OFT_BLKPOS1  ds OFT_COUNT        ;                    mid
OFT_BLKPOS2  ds OFT_COUNT        ;                    hi
* -- OFT_BLKCNT0/1 (the EOF gap fix's total_blocks cache) is
* -- declared in kdevblk.s, IN THE SEGMENT, not here -- unlike
* -- OFT_UNIT/OFT_BLKPOS0-2 above, nothing outside kdevblk.s
* -- ever reads or writes it (grepped tree-wide), so KSEG.md
* -- rule 4's clarification applies (BL2_PSTG's own precedent:
* -- a segment-resident `ds`, written and read by segment code
* -- only): keeping it flat cost 32 B of MAUXPLAY.SYSTEM's own
* -- 256 B headroom floor for no correctness reason.
* -- PRC_BLK_READ/WR/GETEOF scratch (src/kernel/kdevblk.s): the
* -- byte offset within the CURRENT 512-byte block (0..511, so 9
* -- bits -- lo is the full byte, hi is 0 or 1) and how much
* -- room
* -- is left in that block (1..512) before the next block
* -- boundary. One kernel call at a time, so this is safe as
* -- plain scratch, same as P_TMP/P_BANK elsewhere.
PBLK_OFFLO   ds 1
PBLK_OFFHI   ds 1
PBLK_ROOMLO  ds 1
PBLK_ROOMHI  ds 1

* -- READ_BLOCK ($80)/WRITE_BLOCK ($81) -- TRM 4.7.1/4.7.2,
* -- param_count 3: unit_num, data_buffer ptr, block_num.
* -- docs/DEV-BLOCK.md's OFT_BLK read/write (src/kernel/
* -- kdevblk.s) and its size probe (block 2's volume-header
* -- total_blocks) both fill unit_num/block_num fresh per call;
* -- the buffer is always PMLI_XFER_BUF, the same 512-byte
* -- kernel scratch PMLI_RD_PARMS/PMLI_WR_PARMS already use for
* -- an OFT_FILE transfer -- one synchronous kernel call at a
* -- time, so sharing it costs nothing and adds no BSS.
* -- ONE parmlist for both calls (2026-10-08, PCASE_*):
* -- READ_BLOCK and WRITE_BLOCK take identical lists, and
* -- every caller fills unit_num and block_num fresh per
* -- call, so the two labels name
* -- the same 8 bytes.
PML_RDBLK_PRM
PML_WRBLK_PRM
            dfb   3
            dfb   0
            da    PMLI_XFER_BUF
            da    0

* -- READ_BLOCK ($80)/WRITE_BLOCK ($81), TRM 4.7.1/4.7.2 (docs/
* -- DEV-BLOCK.md; learning:01M0W6RW48EWBVGDN3BF5G65TZ,
* -- learning:01M1B7W9Z76TMAKP7YPG63F7WQ). These are the ONLY
* -- sanctioned way this kernel touches a block device: the
* -- commons is explicit that a raw JSR to the driver's DEVADR
* -- vector from $0200-$BFFF is unsafe (a driver may return with
* -- RAMRD/RAMWRT still on aux, and main-memory code fetching
* -- its own next instruction from aux is how that kernel found
* -- the /RAM wedge). The MLI call lives in the language card
* -- and restores the switches before it returns to us, exactly
* -- like every other wrapper in this file -- same interrupt-
* -- enabled bracket, same reason (the file-wide comment above
* -- PMLI_CRT_CALL, procmli.s).
*
* The ONLY callers are the segment's own PRC_BLK_READ/PRC_BLK_WR
* (src/kernel/kdevblk.s). THE ONE THING THE SEGMENT ITSELF
* CANNOT
* DO: re-select LCBANK1_RAM after this call. These two wrappers
* are the segment's "MLI island" (docs/KSEG.md "The trampoline")
* -- after `sei` they re-select LCBANK1_RAM before `rts`, never
* trusting the MLI's own `$D000` bank-restore heuristic (F4's
* second half; learning:01M3G46SEZ3D1RCVJGN39VYE43).
* -- MASKED, not the file's usual cli/sei bracket -- 2026-09-28,
* -- docs/FLOPPY-E2E-NOTES.md. NOT a fix for a proven crash
* -- mechanism: an earlier version of this comment claimed a
* -- `dd if=/dev/s6d1 ...` copy crashed to the classic ROM
* -- monitor because the built-in Disk ][ driver transiently
* -- selects LC ROM-visible, an IRQ landing in that window
* -- taking $FFFE through stock ROM instead of MAIN_IRQ_SHIM.
* -- MEASURED FALSE, same day: the crash never reproduced
* -- again once tested against a FRESH (unpolluted) fixture
* -- volume, with `cli` RESTORED here and the REAL bug (the
* -- EOF-gap fix below, kdevblk.s PBLK_EOF_CK) landed -- three
* -- separate runs, byte-identical, same cycle count, no
* -- monitor. The original crash almost certainly compounded
* -- the EOF gap (reading past the floppy's formatted end into
* -- a track the WOZ nibblizer leaves undefined, which is
* -- non-deterministic by nature) with this session's OWN
* -- repeated write-through test mounts of the same fixture
* -- file, corrupting it across many probe runs before a
* -- rebuild -- the corollary to the "Device is 8192 units"
* -- self-inflicted finding in the same notes file. The $C08x
* -- access being a Disk ][ controller switch, not a
* -- language-card one, and a ROM crash banner being the BRK
* -- path rather than the IRQ path, both independently argue
* -- against the original mechanism too.
* -- KEPT ANYWAY, on a DIFFERENT, better-grounded basis: the
* -- Apple IIc Technical Reference states plainly that "DOS 3.3,
* -- and ProDOS disable interrupts while accessing the disk" --
* -- real ProDOS's own documented convention for a block-driver
* -- caller is masked, and the built-in Disk ][ driver was
* -- never one of the third-party SmartPort-class drivers
* -- (AppleIISd, CFFA) the file-wide cli/sei bracket above
* -- (procmli.s) exists for. So these two calls keep SEI
* -- (K_NOSWITCH still set,
* -- matching every sibling wrapper's bracket shape) and never
* -- CLI -- the accepted cost is a stretched quantum / possible
* -- dropped tick during a block read, the same trade the
* -- masked-maux design always accepted, not a fix for anything
* -- specific to this bug.
PMLI_RDBLK_CL
            lda   #1
            sta   K_NOSWITCH
            jsr   MLI
            dfb   $80
            da    PML_RDBLK_PRM
            stz   K_NOSWITCH
            lda   LCBANK1_RAM
            lda   LCBANK1_RAM
            rts

PMLI_WRBLK_CL
            lda   #1
            sta   K_NOSWITCH
            jsr   MLI
            dfb   $81
            da    PML_WRBLK_PRM
            stz   K_NOSWITCH
            lda   LCBANK1_RAM
            lda   LCBANK1_RAM
            rts

*---------------------------------------------------------------
* PCASE_CREAT / PCASE_RENAME -- docs/PRODOS-CASE.md. ProDOS 2.4
* stores every name upper case and stamps $24/$00 into the two
* bytes GS/OS redefined as a per-character lowercase mask, so a
* name typed `Makefile` is listed `MAKEFILE`. This records the
* typed case the GS/OS way after the MLI call has succeeded:
* the 16-bit word at directory-entry +$1C (bit 15 = flags
* present, bit 15-n = char n is lowercase), and for a
* directory ALSO at +$1A of its own key block (the header).
* PRC_CREAT / PRC_RENAME tail-jump here instead of to
* PRC_RET_MLI_A: A/Z = the MLI result. Failing to record is
* silent -- the create or rename itself stands, as it does on
* a GS/OS that is short of buffers.
*
* HOW THE ENTRY IS FOUND, with no directory scan: OPEN the
* object just made, read its FCB (ProDOS bank 1 $D800 +
* (ref-1)*32: +1 unit, +2/+3 the directory block holding the
* entry, +6 its 1-based entry number, header = 1; measured
* 2.4, docs/PRODOS-CASE-NOTES.md M1), CLOSE, then ONE
* read-modify-write of that block. The FCB layout is internal
* to ProDOS; docs/LOOP-S0-NOTES.md already accepts the same
* dependency for /dev/loop.
*
* RENAME always rewrites: 2.4 KEEPS the old name's positional
* mask, so `mv Chm XYZ` would otherwise read back `Xyz`. A
* CREATE of a name with no lowercase writes nothing (the entry
* carries the $24 stamp, bit 15 clear, which already means "no
* flags").
*
* Flat, not in KSEG: needs the flat MLI wrappers and the FCB in
* ProDOS's own LC bank. The two block wrappers leave $C083
* selected (they serve segment callers), so every block call
* here re-selects LCBANK2_RAM, the kernel's steady state.
*---------------------------------------------------------------
PC_W        ds    2                ;case word (PCASE_MASK)
PC_SLOT     ds    1                ;0 create / 65 rename
PC_ENT      ds    1                ;1-based entry no. (FCB+6)
PC_DIR      ds    1                ;0 = the entry is a directory

PCASE_CREAT
            bne   PCASE_OUT
            ldx   #0
            bra   PCASE_RUN
PCASE_RENAME
            bne   PCASE_OUT
            ldx   #PRC_PATH2OFF
PCASE_RUN   stx   PC_SLOT
            jsr   PCASE_DO
            lda   #0
PCASE_OUT   jmp   PRC_RET_MLI_A

PCASE_DO    jsr   KSEG_CALL        ;PC_W from the last component
            da    PCASE_MASK
            lda   PC_W
            ora   PC_W+1
            beq   :nolow
            lda   PC_W+1
            ora   #$80             ;bit 15: "case flags present"
            sta   PC_W+1
            bra   :open
:nolow      lda   PC_SLOT
            bne   :open
:out0       rts                    ;create, no lowercase: no-op
:open       jsr   PRC_ALLC_IBF
            bcs   :out0
            sta   PRC_IOBUF_ID
            lda   #3               ;PRC_PARM is dead by now
            sta   PRC_PARM
            clc
            lda   #<PRC_PATHBUF
            adc   PC_SLOT
            sta   PRC_PARM+MLI_PATHLO
            lda   #>PRC_PATHBUF
            adc   #0
            sta   PRC_PARM+MLI_PATHHI
            stz   PRC_PARM+MLI_IOBUFLO
            lda   PRC_IOBUF_ID
            jsr   PRC_IBF_HI_A
            sta   PRC_PARM+MLI_IOBUFHI
            jsr   PMLI_OPEN_USR
            beq   :opened
            lda   PRC_IOBUF_ID
            jmp   PRC_FR_IBF_A
:opened     lda   LCBANK2_RAM      ;ProDOS's bank, for the FCB
            lda   LCBANK2_RAM
            lda   PRC_PARM+MLI_OPEN_REF
            pha
            dec   a
            asl   a
            asl   a
            asl   a
            asl   a
            asl   a
            tax
            lda   $D801,x          ;FCB: unit
            sta   PML_RDBLK_PRM+MLI_BLK_UNIT
*-- +2/+3 is the directory's KEY block; +4/+5 is the block that
*-- HOLDS this entry (measured on a 2-block dir,
*-- scripts/measure_case.py m5)
            lda   $D804,x          ;    the entry block
            sta   PML_RDBLK_PRM+MLI_BLK_NUMLO
            lda   $D805,x
            sta   PML_RDBLK_PRM+MLI_BLK_NUMHI
            lda   $D806,x          ;    ... and the entry in it
            sta   PC_ENT
            pla
            jsr   PCLS_RAWREF_A
            lda   PRC_IOBUF_ID
            jsr   PRC_FR_IBF_A
*-- the one read-modify-write. READ_BLOCK and WRITE_BLOCK share
*-- one parmlist (PML_RDBLK_PRM), so the block set up above is
*-- written back by the same fields.
            jsr   PCASE_RD
            bcs   :out
            lda   #4               ;P_PTR1 = the entry
            sta   P_PTR1
            lda   #>PMLI_XFER_BUF
            sta   P_PTR1+1
            ldx   PC_ENT
            dex
:mul        beq   :muld
            clc
            lda   P_PTR1
            adc   #39
            sta   P_PTR1
            bcc   :nc
            inc   P_PTR1+1
:nc         dex
            bra   :mul
:muld       ldy   #0
            lda   (P_PTR1),y
            and   #$F0
            eor   #$D0
            sta   PC_DIR
            ldy   #$1D
            lda   (P_PTR1),y       ;old word: bit 15 = a mask
            ora   PC_W+1
            bpl   :out             ;neither side has one
            lda   PC_W+1
            sta   (P_PTR1),y
            dey
            lda   PC_W
            sta   (P_PTR1),y
            lda   PC_DIR
            bne   :wr1
            ldy   #$11             ;a directory: keep its key
            lda   (P_PTR1),y       ;block for the header word
            sta   P_PTR2
            iny
            lda   (P_PTR1),y
            sta   P_PTR2+1
:wr1        jsr   PCASE_WR
            bcs   :out
            lda   PC_DIR
            bne   :out
            lda   P_PTR2
            sta   PML_RDBLK_PRM+MLI_BLK_NUMLO
            lda   P_PTR2+1
            sta   PML_RDBLK_PRM+MLI_BLK_NUMHI
            jsr   PCASE_RD
            bcs   :out
            lda   PC_W             ;header word: block +$1A
            sta   PMLI_XFER_BUF+$1A
            lda   PC_W+1
            sta   PMLI_XFER_BUF+$1B
            jsr   PCASE_WR
:out        rts

PCASE_RD    jsr   PMLI_RDBLK_CL
            bra   PCASE_BANK
PCASE_WR    jsr   PMLI_WRBLK_CL
PCASE_BANK  lda   LCBANK2_RAM      ;carry (the MLI error) kept
            lda   LCBANK2_RAM
            rts

* -- PMLI_ONLN_CL -- MOVED to procmli.s 2026-09-30 (docs/
* -- DEVFS.md): the new SYS_ONLINE file-call delegate
* -- (procfile4.s PRC_ONLINE) needs it too, and that delegate is
* -- linked by every full-kernel image (procfile4.s is, this
* -- file is not) -- "kernel-wide now", 23 B on all ~32 images
* -- that did not carry it before. PRC_RAMREDISC (kbye.s,
* -- segment-resident) still calls it by the same cross-file
* -- symbol reference; nothing about ITS call site changed, only
* -- where the routine's bytes live.

*---------------------------------------------------------------
* Glue routines the SHARED dispatch sites call unconditionally
* (procfile3.s/procmli.s/procmli3.s/procfile5.s) -- each a bare
* KSEG_CALL trampoline into the segment's own kdevblk.s body.
* procdevs.s stubs every one of these labels with a "no such
* device" answer for every manifest that does not put this file.
*---------------------------------------------------------------
PRC_BLK_RD_G
            jsr   KSEG_CALL
            da    PRC_BLK_READ
            rts

PRC_BLK_WR_G
            jsr   KSEG_CALL
            da    PRC_BLK_WR
            rts

PRC_BLK_SM_G
            jsr   KSEG_CALL
            da    PRC_BLK_SMARK
            rts

PRC_BLK_GM_G
            jsr   KSEG_CALL
            da    PRC_BLK_GMARK
            rts

PRC_BLK_GE_G
            jsr   KSEG_CALL
            da    PRC_BLK_GEOF
            rts

*-- VR_DEVCALL -- a /dev path met by VR_XLATE (vroot.s): not the
*-- MLI. Body: kdevblk.s PRC_DV_BODY, via the shared selector
*-- trampoline PRC_DEVFS_G.
VR_DEVCALL  ldx   #4                ;PRC_SYN_DISP's fifth arm
            bra   PRC_DEVFS_G

*-- VR_DRY: set by the segment's PDEV_KIND around a probe of
*-- PRC_DEVOPEN; PDEV_TRYBLK_G then answers "not shaped".
VR_DRY      ds    1

PDEV_TRYBLK_G
            lda   VR_DRY
            beq   :go
            sec
            rts
:go         jsr   KSEG_CALL
            da    PDEV_TRY_BLK
            rts

* -- PRC_DEVLIST/PRC_SYNAPPLY/PRC_ONLINE -- three (ROOTLIKE went
* -- with the kernel's `..`, docs/VROOT.md)
* -- SYS_DEVLIST/SYS_ONLINE-family entry points (kdisp.s and
* -- procfile.s/procfile4.s name these symbols at compile time),
* -- docs/DEVFS.md/DEVFS-NOTES.md, 2026-09-30: MAUXPLAY.SYSTEM
* -- had no flat headroom for the real bodies (188 B over
* -- PMLI_IBF_BASE, check-kernel-images), so they moved into the
* -- segment (kdevblk.s PRC_DL_BODY/PRC_RL_BODY/PRC_SA_BODY/
* -- PRC_ON_BODY) the same way PDEV_TRY_BLK did.
*
* SHARE ONE KSEG_CALL SITE, 2026-09-30 headroom round (docs/
* DEVFS-NOTES.md): each stub loads a selector into X and falls
* into the one shared trampoline below, which reaches the
* segment-side dispatcher PRC_SYN_DISP (kdevblk.s) instead of a
* body directly. Safe to clobber X here: KSEG_CALL's OWN
* contract already says "clobbers X, Y always" (its header,
* above), so every caller of these four already tolerates X
* being destroyed by the call -- this costs nothing new.
* PRC_SYN_DISP re-dispatches on X and `jmp`s (not `jsr`s) into
* the real body, so that body's own `rts` returns straight
* through KSEG_CALL exactly as before.
PRC_DEVLIST ldx   #0
            bra   PRC_DEVFS_G
PRC_SYNCLASS
            ldx   #1
            bra   PRC_DEVFS_G
PRC_SYNAPPLY
            ldx   #2
            bra   PRC_DEVFS_G
PRC_ONLINE  ldx   #3
PRC_DEVFS_G jsr   KSEG_CALL
            da    PRC_SYN_DISP
            rts

*---------------------------------------------------------------
* PDL_ONE -- DEVLST entry X as SYS_DEVLIST reports it: DSSS in
* the high nibble ($F0-masked, learning:01KW1GTYH4NRG0F8M7AAT
* 6EG9Z), bit 0 SET for a built-in Disk ][ (its DEVADR is in
* LC bank 1), bit 1 SET for one the user MOUNTED (K_MNT).
* X preserved; clobbers A, Y, P_PTR2.
*---------------------------------------------------------------
PDL_ONE     lda   RD_DEVLST,x
            and   #$F0
            pha
            lsr   a
            lsr   a
            lsr   a                 ;(nibble*2): the even index
            clc                     ;into RD_NODEV's 2-byte rows
            adc   #<RD_NODEV
            sta   P_PTR2
            lda   #>RD_NODEV
            adc   #0
            sta   P_PTR2+1
            ldy   #1
            lda   (P_PTR2),y        ;DEVADR hi byte
            cmp   #DSK2_LC_LO
            bcc   :fast
            cmp   #DSK2_LC_HI
            bcs   :fast
            pla
            pha
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            tay
            pla
            ora   K_MNT,y
            ora   #1
            rts
:fast       pla
            rts

*---------------------------------------------------------------
* VR_OTHER -- SYS_VROOT ops 0, 1, 2 (docs/VROOT.md). PRC_VROOT,
* with op 3 PHYS, is in vroot.s so every image has it (df needs
* PHYS everywhere). Entered with the parmlist in PRC_PARM and
* PRC_USER_PTR set.
* op 0 ROW:    arg = row index. The row comes back at the
*              pointer as [n+1][name, lower case][kind]; a
*              length byte of 0 ends the table (VR_TAB).
* op 1 MOUNT:  arg = unit_num (DSSS0000). A Disk ][ is marked
*              mounted (K_MNT); any other unit is mounted
*              already. No unit of that number: MLI error $28.
* op 2 UMOUNT: arg = unit, pointer = "/NAME" (MLI-shaped). Only
*              a mounted Disk ][ can go (ERR_INVAL otherwise);
*              the boot volume, a file open or parked on NAME, a
*              cwd on NAME or an open block device on the unit
*              is MLIE_FILOPEN. FLAT, not in the segment (the
*              segment has 148 B free; this is ~400): it reads
*              main memory only.
*---------------------------------------------------------------
VR_OTHER
            lda   PRC_PARM
            bne   :notrow
            ldx   #0
            ldy   PRC_PARM+3
:fr         lda   VR_TAB,x
            beq   :eof
            cpy   #0
            beq   :got
            dey
            sec
            adc   #1                ;row length + 2
            sta   P_TMP
            txa
            clc
            adc   P_TMP
            tax
            bra   :fr
:eof        stz   PRC_PATHBUF
            jmp   PRC_PB_OUT
:got        lda   VR_TAB,x
            inc   a
            sta   PRC_PATHBUF       ;name + the kind byte
            ldy   #0
:cp         inx
            iny
            lda   VR_TAB,x
            cpy   PRC_PATHBUF
            beq   :last             ;the kind, not a letter
            ora   #$20
:last       sta   PRC_PATHBUF,y
            cpy   PRC_PATHBUF
            bne   :cp
            jmp   PRC_PB_OUT

:notrow     cmp   #3                ;ops 1, 2, 4, 5 only
            bcc   :mount
            cmp   #6
            bcs   :bad
            jsr   PCPY_MLI_RAW      ;op 4 LOOPATT, 5 CLASSIFY
            bcs   :perr4            ;(LP_OP45, loopseg.s)
            jmp   LP_OP45
:perr4      rts
:bad        lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:mount      jsr   MC_FLUSH          ;VR_MNTCK's name cache
            ldx   RD_DEVCNT
:fu         jsr   PDL_ONE
            pha
            and   #$F0
            cmp   PRC_PARM+3
            beq   :found
            pla
            dex
            bpl   :fu
            lda   #$28              ;no device connected
            jsr   PRC_FAIL_A
            rts
:found      lda   PRC_PARM+3
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            tax                     ;X = the unit's nibble
            pla
            lsr   a                 ;carry = a built-in Disk ][
            ldy   PRC_PARM
            bcs   :slow
            cpy   #1                ;a fast unit: no-op
            beq   :ok
            cpx   #$0B              ;the loop unit ($B0)
            beq   :um0
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:slow       cpy   #1
            bne   :um
            lda   #2
            sta   K_MNT,x
            bra   :ok
:um0        cpy   #2
            bne   :bad
:um         phx
            jsr   PCPY_MLI_RAW      ;"/NAME" -> PRC_PATHBUF
            bcs   :perr
            jsr   VR_BUSY
            plx
            bcs   :busy
            cpx   #$0B
            bne   :nloop
            jmp   LP_DETACH         ;the loop: loopseg.s
:nloop      stz   K_MNT,x
:ok         jsr   PRC_RET_OK0
            rts
:perr       plx
            rts
:busy       lda   #MLIE_FILOPEN
            jsr   PRC_FAIL_A
            rts

*-- VR_SAMEVOL -- is the first component of the path at (P_PTR1)
*-- (length-prefixed, '/' first) the volume named by PRC_PATHBUF
*-- ("/NAME")? Carry set = yes. Clobbers A, Y, P_TMP.
VR_SAMEVOL
            lda   (P_PTR1)
            cmp   PRC_PATHBUF
            bcc   :no               ;shorter than the name
            ldy   #1
:c          iny
            lda   (P_PTR1),y
            jsr   PDEV_FOLD
            sta   P_TMP
            lda   PRC_PATHBUF,y
            jsr   PDEV_FOLD
            cmp   P_TMP
            bne   :no
            cpy   PRC_PATHBUF
            bne   :c
            lda   (P_PTR1)
            cmp   PRC_PATHBUF
            beq   :yes              ;exactly "/NAME"
            iny
            lda   (P_PTR1),y
            cmp   #"/"+$80
            beq   :yes              ;"/NAME/..."
:no         clc
            rts
:yes        sec
            rts

*-- VR_BUSY -- is "/NAME" (PRC_PATHBUF) or unit PRC_PARM+3 in
*-- use? Carry set = busy.
VR_BUSY
            jsr   LP_HBUSY          ;the loop's host volume
            bcc   :nh
            rts
:nh
            lda   #<PRC_PFXSAVE     ;the boot volume never goes
            sta   P_PTR1
            lda   #>PRC_PFXSAVE
            sta   P_PTR1+1
            jsr   VR_SAMEVOL
            bcs   :rts
            ldx   #1                ;open files: a saved (parked
:oft        cpx   #OFT_COUNT        ;or resident absolute) path
            beq   :cwds             ;on NAME, or a block device
            lda   OFT_TYPE,x        ;open on the unit. A pinned
            cmp   #OFT_BLK          ;file is on the boot volume
            bne   :nb
            lda   OFT_UNIT,x
            cmp   PRC_PARM+3
            beq   :yes
            bra   :on
:nb         cmp   #OFT_FILE
            bne   :on
            jsr   PRC_OFT_SLOTP
            lda   (P_PTR3)
            beq   :on
            lda   P_PTR3
            sta   P_PTR1
            lda   P_PTR3+1
            sta   P_PTR1+1
            phx
            jsr   VR_SAMEVOL
            plx
            bcs   :yes
:on         inx
            bra   :oft
:cwds       lda   #<K_CWD_BUF
            sta   P_PTR1
            lda   #>K_CWD_BUF
            sta   P_PTR1+1
            lda   #1
            sta   VR_N              ;pid
:cw         lda   VR_N
            cmp   #PCB_COUNT
            beq   :no
            jsr   PCB_PTR_FOR
            stz   BANKSEL
            lda   #PCB_STATE
            ldx   #1
            jsr   PCB_RD_FIELDS
            lda   K_PCB_SCRATCH
            beq   :cn               ;unused
            cmp   #PCB_ZOMBIE
            beq   :cn
            lda   VR_N
            jsr   CWD_READ
            lda   K_CWD_BUF+1
            bmi   :cn               ;a synthetic cwd, or none
            jsr   VR_SAMEVOL
            bcs   :yes
:cn         inc   VR_N
            bra   :cw
:no         clc
:rts        rts
:yes        sec
            rts

* -- PRC_TTYMODE -- SYS_TTYMODE, a bare trampoline (2026-10-07,
* -- docs/TTY-TYPEAHEAD-BELL.md: the body moved out of tty7.s to
* -- buy flat headroom, and carries the edit buffer into the raw
* -- ring on ICANON 1->0). procdevs.s holds the plain body for
* -- manifests without the segment.
PRC_TTYMODE
            jsr   KSEG_CALL
            da    PRC_TTYMD_SEG
            rts

* -- PRC_TTYGEO -- SYS_TTYGEO, a bare trampoline (2026-10-08).
* -- Body: kdevblk.s PRC_TTYGEO_SG; plain twin: procdevs.s.
PRC_TTYGEO
            jsr   KSEG_CALL
            da    PRC_TTYGEO_SG
            rts
