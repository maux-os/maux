*---------------------------------------------------------------
* kdevblk.s -- the OFT_BLK (/dev/sNdM block device) BODY code,
* moved into the kernel cold segment 2026-09-27 (docs/KSEG.md
* "Landing /dev on it", "What moves" item 2). `put` directly
* into playtest.s's own `org KSEG_ORG` block, right after
* byelaunch.s -- this file has NO `org`/`dsk`/`typ`/`put` header
* of its own, same convention byelaunch.s now uses, because it
* is a MODULE in that manifest's single assembly, not a
* standalone one.
*
* Audited against docs/KSEG.md's nine segment rules, one fix
* needed: PRC_BLK_SMARK ended in `jmp PRC_RET_OK0` (rule 6 --
* no `jmp` out of the segment); changed to `jsr`+`rts`. Every
* other routine here already reports errors via `jsr PRC_FAIL_A`
* + `rts` (carry set, A = errno) or success via `jsr
* PRC_RET_OK0` + `rts`, calls only flat routines with a plain
* `jsr` (PRC_FAIL_A, PRC_RET_OK0, PRC_SEL_CRBNK, BankCopy,
* PMLI_RDBLK_CL/PMLI_WRBLK_CL, PDEV_FOLD -- segment code calling
* FLAT code needs no trampoline at all, only the reverse
* direction does), touches no LC switch, no ALTZP, no `cli`, no
* `$D000-$D3FF`. Every array it indexes -- OFT_UNIT,
* OFT_BLKPOS0/1/2, PBLK_OFFLO/OFFHI/ROOMLO/ROOMHI,
* PML_RDBLK_PRM/PML_WRBLK_PRM -- lives in process.s's/
* procdev.s's flat BSS, because the MLI itself dereferences
* the two parmlists (rule 4's literal text: cross-boundary
* consumers must stay flat). OFT_BLKCNT0/1 (2026-09-28, the
* EOF gap fix) is the ONE EXCEPTION: declared HERE, in the
* segment (below), because
* nothing outside this file ever reads or writes it -- rule 4's
* clarification (data written and read entirely within the
* segment, never needing to survive a KSEG_RELOAD between the
* write and the read here) applies exactly, the same shape as
* byelaunch.s's own BL2_PSTG precedent.
*
* Reached from five flat dispatch sites (procmli.s PRC_READ,
* procmli3.s PRC_WRITE, procfile3.s PRC_SETMARK/PRC_GETMARK/
* PRC_GETEOF) and PRC_DEVOPEN's own `:unknown` hook
* (procfile5.s), every one of them `jsr KSEG_CALL` + inline
* pointer, `do ]KSEG_WANT`-guarded so the other 31 images never
* reference a symbol this file alone defines.
*---------------------------------------------------------------

* -- OFT_BLKCNT0/1 -- total_blocks, cached at open time
* -- (PDEV_BLK_SIZE below), 0 = unknown. Segment-resident `ds`
* -- (KSEG.md rule 4's clarification; see the file header
* -- above): read and written only by PALOBJ_BLK/PDEV_BLK_SIZE/
* -- PBLK_EOF_CK/PRC_BLK_GEOF, all in this file.
OFT_BLKCNT0  ds OFT_COUNT        ;total_blocks, lo
OFT_BLKCNT1  ds OFT_COUNT        ;              hi

* -- PDL_REC -- PRC_DL_BODY's own staging record (docs/DEVFS.md,
* -- 2026-09-30), moved here from process.s the SAME day and for
* -- the SAME KSEG.md rule 4 reason as OFT_BLKCNT0/1 above:
* -- written whole, read whole, entirely within one PRC_DL_BODY
* -- call, by nothing else in the tree.
PDL_REC      ds 16                ;one byte per DEVLST entry, 16
                                  ;is DEVLST's own max (4-bit
                                  ;DSSS nibble)

*---------------------------------------------------------------
* PDEV_BLK_FIND -- the pure half of PDEV_TRY_BLK: is the name in
* PRC_PATHBUF+6.. shaped like sNdM, and is that unit in DEVLST?
* No allocation, no I/O (GET_FILE_INFO of /dev/sNdM calls it).
* OUT: carry SET = not shaped; carry CLEAR with A = 1 present
* (P_TMP = unit_num, DSSS0000), A = 0 shaped but absent.
*---------------------------------------------------------------
PDEV_BLK_FIND
            lda   P_COUNT
            cmp   #4
            bne   :noshape
            lda   PRC_PATHBUF+6
            jsr   PDEV_FOLD
            cmp   #'S'
            bne   :noshape
            lda   PRC_PATHBUF+7
            jsr   PDEV_FOLD
            cmp   #'0'
            bcc   :noshape
            cmp   #':'            ;'9'+1 -- tty2.s's own digit-
            bcs   :noshape        ;range idiom
            sec
            sbc   #'0'
            cmp   #1
            bcc   :noshape        ;slot 0 is not a slot
            cmp   #8
            bcs   :noshape        ;slots are 1..7
            sta   P_TMP           ;slot digit, 1..7
            lda   PRC_PATHBUF+8
            jsr   PDEV_FOLD
            cmp   #'D'
            bne   :noshape
            lda   PRC_PATHBUF+9
            jsr   PDEV_FOLD
            cmp   #'1'
            beq   :d1
            cmp   #'2'
            beq   :d2
            bra   :noshape
:d1         stz   P_TMP2
            bra   :haveunit
:d2         lda   #$80
            sta   P_TMP2
:haveunit   lda   P_TMP
            asl   a
            asl   a
            asl   a
            asl   a
            ora   P_TMP2
            sta   P_TMP           ;unit_num, DSSS0000
            ldy   RD_DEVCNT
:dscan      lda   RD_DEVLST,y
            and   #$F0            ;DEVLST byte's TYPE nibble is
                                   ;not unit_num -- mask it off
                                   ;(learning:
                                   ;01KW1GTYH4NRG0F8M7AAT6EG9Z)
            cmp   P_TMP
            beq   :found
            dey
            bpl   :dscan
            lda   #0              ;shaped, absent from DEVLST
            clc
            rts
:found      lda   #1
            clc
            rts
:noshape    sec
            rts

*---------------------------------------------------------------
* PDEV_TRY_BLK -- docs/DEV-BLOCK.md: /dev/sNdM, N a slot digit
* 1-7, M a drive digit 1-2. unit_num = (M-1)<<7 | N<<4 --
* ProDOS's own DSSS0000 form, straight arithmetic, no table
* (library note learning:01M0W6RW48EWBVGDN3BF5G65TZ). Reached
* only from PRC_DEVOPEN's :unknown, after the fixed-name table
* found no match, so the common case (tty/null/ser) pays nothing
* extra beyond the one KSEG_CALL trampoline.
*
* Entry: P_COUNT already holds the name length; PRC_PATHBUF+6..
* +9 hold the 4 name bytes when P_COUNT is 4 (PRC_PATHBUF+1 is
* the leading '/', +2..+4 "DEV", +5 the second '/' -- the same
* layout the table scan relies on). Not yet case-folded --
* PDEV_FOLD (procfile5.s, stays flat) runs here per byte, same
* as the table scan.
*
* Exit: carry SET = not shaped like sNdM (wrong length, wrong
* literal, a non-digit, or a slot/drive digit out of range) --
* the caller's ordinary "no such device" applies. Carry CLEAR =
* the shape matched, and either A holds a freshly allocated
* OFT_BLK index (unit_num was present in DEVLST) or an error has
* ALREADY been posted via PRC_FAIL_A and A is 0 (validated but
* absent from DEVLST, or the OFT is full) -- the caller just
* returns either way, unchanged from its existing contract.
*
* /RAM is never a match here: PRC_RAMDIS (procmli.s) removed
* its DEVLST entry at boot (learning:
* 01KW1GTYH4NRG0F8M7AAT6EG9Z), so /dev/s3d2 parses fine, scans
* DEVLST, finds nothing at $B0, and reports "no such device" --
* docs/DEV-BLOCK.md's gate case, with no special case written
* for it.
*---------------------------------------------------------------
PDEV_TRY_BLK
            jsr   PDEV_BLK_FIND
            bcs   :ret            ;not shaped like sNdM
            bne   :devfound
            lda   #MLIE_NOFILE
            jsr   PRC_FAIL_A
            lda   #0
            clc
            rts
:devfound   jsr   PALOBJ_BLK
            bcc   :blkok
            lda   #0
            clc
            rts
:blkok      tax
            jsr   PDEV_BLK_SIZE    ;cache total_blocks (the EOF
                                    ;gap fix) -- preserves X
            txa
            clc
:ret        rts

*---------------------------------------------------------------
* PALOBJ_BLK -- docs/DEV-BLOCK.md: allocate an OFT_BLK slot for
* a /dev/sNdM open. IN: P_TMP = unit_num (DSSS0000). OUT: A =
* OFT index, carry clear; or carry set, ERR_NFILE reported
* (PDEV_TRY_BLK's own "no such device" fallback then applies).
* Position starts at 0, same as a freshly-opened file.
* Refcount/close/dup2 need NO changes of their own:
* PRC_INC_OBJ_A and PRC_DEC_OBJ already fall through to the
* generic path for any OFT_TYPE that is neither pipe end (this
* one isn't OFT_FILE either, so PRC_DEC_OBJ's zero-refcount arm
* clears the slot without attempting a ProDOS CLOSE -- exactly
* right, there is no refnum to close).
*---------------------------------------------------------------
PALOBJ_BLK
            ldx   #1
:loop       cpx   #OFT_COUNT
            beq   :none
            lda   OFT_TYPE,x
            beq   :found
            inx
            bra   :loop
:found      lda   #OFT_BLK
            sta   OFT_TYPE,x
            lda   #0
            sta   OFT_PIPE,x
            lda   P_TMP
            sta   OFT_UNIT,x
            stz   OFT_BLKPOS0,x
            stz   OFT_BLKPOS1,x
            stz   OFT_BLKPOS2,x
            lda   #1
            sta   OFT_REFCNT,x
            txa
            clc
            rts
:none       lda   #ERR_NFILE
            jsr   PRC_FAIL_A
            sec
            rts

*---------------------------------------------------------------
* PDEV_BLK_SIZE -- cache a freshly-opened OFT_BLK's
* total_blocks at open time (docs/FLOPPY-E2E-NOTES.md,
* coordinator review 2026-09-28: the EOF gap this closes -- a
* bare `dd if=/dev/s6d1 of=X` with no count= used to walk off
* the formatted end of a real floppy into a track that does
* not exist, and what happened next was UNDEFINED, not merely
* slow: sometimes a clean I/O error, sometimes a crash,
* depending on what garbage the Disk ][ model's nibblizer
* synthesises for the unformatted track -- see that notes
* file's dated correction for the measurement that found
* this).
*
* IN: X = OFT index (OFT_UNIT,x already set by PALOBJ_BLK).
* OUT: OFT_BLKCNT0/1,x = the device's total_blocks, read from
* its own block 2's ProDOS volume-directory-header field at
* offset +$29/+$2A -- the SAME field PRC_BLK_GEOF used to
* re-read live on every call; read ONCE here instead, and
* PRC_BLK_GEOF now answers from the cache. A read failure (no
* such unit, a genuinely dead device, or a device whose block
* 2 is not a ProDOS volume header at all) leaves
* OFT_BLKCNT0/1,x at 0 -- "unknown size", which PBLK_EOF_CK
* below treats as "never clamp, let the driver itself report
* the error" -- this project's own /dev design doc's already-
* documented fallback for a device whose size cannot be
* determined, unchanged by this fix. Clobbers A, Y; X is
* preserved (the caller still needs it).
*---------------------------------------------------------------
PDEV_BLK_SIZE
            lda   OFT_UNIT,x
            sta   PML_RDBLK_PRM+MLI_BLK_UNIT
            lda   #2
            sta   PML_RDBLK_PRM+MLI_BLK_NUMLO
            stz   PML_RDBLK_PRM+MLI_BLK_NUMHI
            phx
            jsr   PMLI_RDBLK_CL
* -- `beq` HERE, testing the call's own flag -- NOT after
* -- `plx`, which (like any PLA/PLX/PLY) sets N/Z from the
* -- pulled byte and would silently retest THAT instead.
* -- Measured 2026-09-28: with the check after `plx`, X (an
* -- OFT index, almost always nonzero) cleared Z on every
* -- call, so this always fell to the "unknown" branch and
* -- the clamp never engaged at all -- caught by the
* -- no-count= gate case, still red until this reorder.
            beq   :havehdr
            plx
            stz   OFT_BLKCNT0,x
            stz   OFT_BLKCNT1,x
            rts
:havehdr    plx
            lda   PMLI_XFER_BUF+$29
            sta   OFT_BLKCNT0,x
            lda   PMLI_XFER_BUF+$2A
            sta   OFT_BLKCNT1,x
            rts

*---------------------------------------------------------------
* PBLK_EOF_CK -- IN: X = P_OBJ (the OFT index),
* PML_RDBLK_PRM's block_num already filled (PBLK_PREP's own
* job, called first). OUT: carry SET when this lap's block_num
* is AT OR PAST the cached OFT_BLKCNT0/1,x (the caller must
* stop -- EOF, or for a write, refuse); carry CLEAR to
* proceed, including the "unknown size" case (OFT_BLKCNT0/1,x
* both zero), which never clamps -- the same "read until the
* driver reports an error" fallback this project's own /dev
* design doc already specifies. Clobbers A.
*---------------------------------------------------------------
PBLK_EOF_CK
            lda   OFT_BLKCNT0,x
            ora   OFT_BLKCNT1,x
            beq   :unknown
            sec
            lda   PML_RDBLK_PRM+MLI_BLK_NUMLO
            sbc   OFT_BLKCNT0,x
            lda   PML_RDBLK_PRM+MLI_BLK_NUMHI
            sbc   OFT_BLKCNT1,x
            rts                    ;carry SET (no borrow): at or
                                    ;past end; CLEAR: in range
:unknown    clc
            rts

*---------------------------------------------------------------
* OFT_BLK read/write (docs/DEV-BLOCK.md). One 512-byte kernel
* buffer (PMLI_XFER_BUF, already shared by every OFT_FILE
* transfer -- one synchronous kernel call at a time, so nothing
* new to allocate), one whole ProDOS block per lap, so a request
* straddling a block boundary just takes two laps, each aligned
* to a single block. Writes are read-modify-write
* unconditionally (even a full aligned block re-reads first) --
* simpler and smaller than special-casing the aligned run, and
* correct either way.
*
* PBLK_PREP -- IN: P_OBJ = the OFT_BLK index. OUT:
* PML_RDBLK_PRM/PML_WRBLK_PRM's unit_num+block_num fields filled
* from the CURRENT position (both parmlists, so either call can
* be issued with no further setup); PBLK_OFFLO/OFFHI = byte
* offset within that block; PRC_CHUNK = this lap's run length
* (1..512), MIN(room-left-in-block, PRC_REMAIN). Does not touch
* position or PRC_DONE/PRC_REMAIN -- the caller advances those
* only after its transfer succeeds. Clobbers A, X, Y.
*---------------------------------------------------------------
PBLK_PREP
            ldx   P_OBJ
            lda   OFT_UNIT,x
            sta   PML_RDBLK_PRM+MLI_BLK_UNIT
            sta   PML_WRBLK_PRM+MLI_BLK_UNIT
* -- block_num = position >> 9; PBLK_OFFLO/HI = position & $1FF.
* -- position is byte2:byte1:byte0 (LE); drop byte0 (>>8) then
* -- shift the remaining 16 bits right once more (>>1 total 9).
            lda   OFT_BLKPOS2,x
            lsr   a
            pha                    ;block_num hi
            lda   OFT_BLKPOS1,x
            ror   a                ;block_num lo; carry out is
            tay                    ;position's original bit 8
            lda   #0
            rol   a
            sta   PBLK_OFFHI
            tya
            sta   PML_RDBLK_PRM+MLI_BLK_NUMLO
            sta   PML_WRBLK_PRM+MLI_BLK_NUMLO
            pla
            sta   PML_RDBLK_PRM+MLI_BLK_NUMHI
            sta   PML_WRBLK_PRM+MLI_BLK_NUMHI
            lda   OFT_BLKPOS0,x
            sta   PBLK_OFFLO
* -- room = 512 - offset (16-bit; offset is 0..511, so room is
* -- always 1..512).
            sec
            lda   #0
            sbc   PBLK_OFFLO
            sta   PBLK_ROOMLO
            lda   #2
            sbc   PBLK_OFFHI
            sta   PBLK_ROOMHI
* -- PRC_CHUNK = MIN(room, PRC_REMAIN), PRC_PCK_CHUNK's own
* -- 16-bit compare-and-clamp shape.
            lda   PRC_REMAIN+1
            cmp   PBLK_ROOMHI
            bcc   :userem
            bne   :useroom
            lda   PRC_REMAIN
            cmp   PBLK_ROOMLO
            bcc   :userem
:useroom    lda   PBLK_ROOMLO
            sta   PRC_CHUNK
            lda   PBLK_ROOMHI
            sta   PRC_CHUNK+1
            rts
:userem     lda   PRC_REMAIN
            sta   PRC_CHUNK
            lda   PRC_REMAIN+1
            sta   PRC_CHUNK+1
            rts

*-- PBLK_ADVANCE -- position += PRC_CHUNK (24-bit); PRC_DONE +=
*-- PRC_CHUNK, PRC_REMAIN -= PRC_CHUNK (both 16-bit) -- the same
*-- bookkeeping PRC_FILE_READ/PRC_FILE_WR's own loops use.
*-- Called only after a transfer has actually succeeded.
*-- Clobbers A, X.
PBLK_ADVANCE
            ldx   P_OBJ
            clc
            lda   OFT_BLKPOS0,x
            adc   PRC_CHUNK
            sta   OFT_BLKPOS0,x
            lda   OFT_BLKPOS1,x
            adc   PRC_CHUNK+1
            sta   OFT_BLKPOS1,x
            lda   OFT_BLKPOS2,x
            adc   #0
            sta   OFT_BLKPOS2,x
            clc
            lda   PRC_DONE
            adc   PRC_CHUNK
            sta   PRC_DONE
            lda   PRC_DONE+1
            adc   PRC_CHUNK+1
            sta   PRC_DONE+1
            sec
            lda   PRC_REMAIN
            sbc   PRC_CHUNK
            sta   PRC_REMAIN
            lda   PRC_REMAIN+1
            sbc   PRC_CHUNK+1
            sta   PRC_REMAIN+1
            rts

*-- PRC_BLK_READ -- PRC_READ's OFT_BLK arm. IN: X = OFT index
*-- (same convention PRC_FILE_READ takes). Shape mirrors
*-- PRC_FILE_READ (procfile2.s) exactly, one block per lap
*-- instead of one MLI chunk.
PRC_BLK_READ
            stx   P_OBJ
            lda   PRC_PARM+MLI_BUFLO
            sta   PRC_USER_PTR
            lda   PRC_PARM+MLI_BUFHI
            sta   PRC_USER_PTR+1
            lda   PRC_PARM+MLI_REQLO
            sta   PRC_REMAIN
            lda   PRC_PARM+MLI_REQHI
            sta   PRC_REMAIN+1
            stz   PRC_DONE
            stz   PRC_DONE+1
:loop       lda   PRC_REMAIN
            ora   PRC_REMAIN+1
            bne   :more
            jmp   :done
:more       jsr   PBLK_PREP
            jsr   PBLK_EOF_CK      ;the EOF gap fix: at/past the
            bcc   :inrange         ;cached total_blocks -> stop,
            jmp   :done            ;return whatever PRC_DONE has
:inrange    jsr   PMLI_RDBLK_CL
            beq   :rdok
            jsr   PRC_FAIL_A
            rts
:rdok       jsr   PRC_SEL_CRBNK
            sta   P_BANK
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            clc
            lda   #<PMLI_XFER_BUF
            adc   PBLK_OFFLO
            sta   K_BC_SRCADDR
            lda   #>PMLI_XFER_BUF
            adc   PBLK_OFFHI
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            clc
            lda   PRC_USER_PTR
            adc   PRC_DONE
            sta   K_BC_DSTADDR
            lda   PRC_USER_PTR+1
            adc   PRC_DONE+1
            sta   K_BC_DSTADDR+1
            lda   P_BANK
            sta   K_BC_DSTBANK
            lda   PRC_CHUNK
            sta   K_BC_LEN
            lda   PRC_CHUNK+1
            sta   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :copied
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:copied     jsr   PBLK_ADVANCE
            jmp   :loop
:done       lda   PRC_DONE
            sta   PRC_PARM+MLI_TRANSLO
            lda   PRC_DONE+1
            sta   PRC_PARM+MLI_TRANSHI
            jsr   PCPO_MLIPARM
            rts

*-- PRC_BLK_WR -- PRC_WRITE's OFT_BLK arm. IN: X = OFT index.
*-- Read-modify-write per lap (see file header above).
PRC_BLK_WR
            stx   P_OBJ
            lda   PRC_PARM+MLI_BUFLO
            sta   PRC_USER_PTR
            lda   PRC_PARM+MLI_BUFHI
            sta   PRC_USER_PTR+1
            lda   PRC_PARM+MLI_REQLO
            sta   PRC_REMAIN
            lda   PRC_PARM+MLI_REQHI
            sta   PRC_REMAIN+1
            stz   PRC_DONE
            stz   PRC_DONE+1
:loop       lda   PRC_REMAIN
            ora   PRC_REMAIN+1
            bne   :more
            jmp   :done
:more       jsr   PBLK_PREP
            jsr   PBLK_EOF_CK      ;the EOF fix: refuse a write
            bcc   :inrange         ;at/past the cached
            lda   #MLIE_IOERROR    ;total_blocks, the code a
            jsr   PRC_FAIL_A       ;real driver returns for an
            rts                    ;out-of-range access
:inrange    jsr   PMLI_RDBLK_CL
            beq   :haveblk
            jsr   PRC_FAIL_A
            rts
:haveblk    jsr   PRC_SEL_CRBNK
            sta   P_BANK
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            clc
            lda   PRC_USER_PTR
            adc   PRC_DONE
            sta   K_BC_SRCADDR
            lda   PRC_USER_PTR+1
            adc   PRC_DONE+1
            sta   K_BC_SRCADDR+1
            lda   P_BANK
            sta   K_BC_SRCBANK
            lda   #BC_KIND_MAIN
            sta   K_BC_DSTKIND
            clc
            lda   #<PMLI_XFER_BUF
            adc   PBLK_OFFLO
            sta   K_BC_DSTADDR
            lda   #>PMLI_XFER_BUF
            adc   PBLK_OFFHI
            sta   K_BC_DSTADDR+1
            stz   K_BC_DSTBANK
            lda   PRC_CHUNK
            sta   K_BC_LEN
            lda   PRC_CHUNK+1
            sta   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :spliced
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:spliced    jsr   PMLI_WRBLK_CL
            beq   :wrote
            jsr   PRC_FAIL_A
            rts
:wrote      jsr   PBLK_ADVANCE
            jmp   :loop
:done       lda   PRC_DONE
            sta   PRC_PARM+MLI_TRANSLO
            lda   PRC_DONE+1
            sta   PRC_PARM+MLI_TRANSHI
            jsr   PCPO_MLIPARM
            rts

*-- PRC_BLK_SMARK/PRC_BLK_GMARK -- SYS_SET_MARK/SYS_GET_MARK's
*-- OFT_BLK arm (procfile3.s PRC_SETMARK/PRC_GETMARK; the SMARK/
*-- GMARK abbreviation matches PML_SMARK_PRM/PML_GMARK_PRM's own
*-- naming). No MLI call: the position is this kernel's own
*-- state, not ProDOS's, so it is a plain store/fetch of
*-- OFT_BLKPOS0/1/2. IN: X = OFT index (the dispatcher's own
*-- `tax` result, unchanged since).
PRC_BLK_SMARK
            lda   PRC_PARM+MLI_EOFLO
            sta   OFT_BLKPOS0,x
            lda   PRC_PARM+MLI_EOFHI
            sta   OFT_BLKPOS1,x
            lda   PRC_PARM+MLI_EOFBANK
            sta   OFT_BLKPOS2,x
            jsr   PRC_RET_OK0      ;rule 6 -- `jmp` in the
            rts                    ;original flat routine, fixed
                                    ;to jsr+rts moving here

PRC_BLK_GMARK
            lda   OFT_BLKPOS0,x
            sta   PML_GMARK_PRM+MLI_EOFLO
            lda   OFT_BLKPOS1,x
            sta   PML_GMARK_PRM+MLI_EOFHI
            lda   OFT_BLKPOS2,x
            sta   PML_GMARK_PRM+MLI_EOFBANK
            jsr   PRC_SEL_CRBNK
            sta   P_BANK
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            clc
            lda   #<PML_GMARK_PRM
            adc   #MLI_EOFLO
            sta   K_BC_SRCADDR
            lda   #>PML_GMARK_PRM
            adc   #0
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            clc
            lda   K_PARMLO
            adc   #MLI_EOFLO
            sta   K_BC_DSTADDR
            lda   K_PARMHI
            adc   #0
            sta   K_BC_DSTADDR+1
            lda   P_BANK
            sta   K_BC_DSTBANK
            lda   #3
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :bgmcopied
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:bgmcopied  jsr   PRC_RET_OK0
            rts

*---------------------------------------------------------------
* PRC_BLK_GEOF -- SYS_GET_EOF's OFT_BLK arm (procfile3.s
* PRC_GETEOF): the "size" of a block device, reported the SAME
* way a file's byte length is -- docs/DEV-BLOCK.md's own choice
* of vocabulary ("a block fd's 24-bit position answers to" the
* seek family), extended to this seek family's size call rather
* than widening SYS_FDSTAT's single-byte contract (inc/
* sc.proc.equ's FDST_BLK comment; docs/DEV-BLOCK-NOTES.md has
* the full reasoning -- SYS_FDSTAT has 7 existing callers on a
* fixed 1-byte parmlist, and widening it would break every one
* of them).
*
* The count itself comes from the volume directory header's own
* total_blocks field (block 2, offset $29/$2A, TRM B.2.2;
* a2til's
* prodos.py VolHeader.total_blocks = U16(0x29), house precedent
* cross-checked against the TRM's own prose) -- read via
* READ_BLOCK, NEVER a driver STATUS call reached by a direct JSR
* (library note 01M1B7W9Z76TMAKP7YPG63F7WQ says that is unsafe
* from here). CHANGED 2026-09-28 (docs/FLOPPY-E2E-NOTES.md,
* the EOF gap fix): read ONCE, at open time (PDEV_BLK_SIZE),
* into OFT_BLKCNT0/1,x -- this call now answers from that
* cache rather than re-reading block 2 live on every call. A
* device whose media cannot change size while open (every
* block device this kernel opens today) makes the earlier
* "read fresh every call, per-media like a UniDisk 3.5's
* STATUS answer" caution moot; the cache is what
* PRC_BLK_READ/WR's own new clamp (PBLK_EOF_CK) also needs, so
* one read now serves both. If block 2 could not be read at
* open time, the cache is 0 -- "unknown" -- and this call
* reports size 0, the SAME fallback docs/DEV-BLOCK.md always
* documented.
*
* IN: X = OFT index. Bytes = total_blocks << 9; a volume at or
* past 32768 blocks (16 MB) overflows the 24-bit result the same
* way SET_MARK/GET_MARK already cap every ordinary file's
* position -- an existing systemic limit, not a new one.
*---------------------------------------------------------------
PRC_BLK_GEOF
            stz   PML_GTF_PARMS+MLI_EOFLO
            lda   OFT_BLKCNT0,x
            sta   PML_GTF_PARMS+MLI_EOFHI
            lda   OFT_BLKCNT1,x
            sta   PML_GTF_PARMS+MLI_EOFBANK
            asl   PML_GTF_PARMS+MLI_EOFLO
            rol   PML_GTF_PARMS+MLI_EOFHI
            rol   PML_GTF_PARMS+MLI_EOFBANK
            jsr   PRC_SEL_CRBNK
            sta   P_BANK
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            clc
            lda   #<PML_GTF_PARMS
            adc   #MLI_EOFLO
            sta   K_BC_SRCADDR
            lda   #>PML_GTF_PARMS
            adc   #0
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            clc
            lda   K_PARMLO
            adc   #MLI_EOFLO
            sta   K_BC_DSTADDR
            lda   K_PARMHI
            adc   #0
            sta   K_BC_DSTADDR+1
            lda   P_BANK
            sta   K_BC_DSTBANK
            lda   #3
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :bgedone
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:bgedone    jsr   PRC_RET_OK0
            rts

*---------------------------------------------------------------
* PRC_DL_BODY -- SYS_DEVLIST's real body (docs/DEVFS.md),
* reached
* from procdev.s's PRC_DEVLIST trampoline via KSEG_CALL. Copies
* out DEVCNT+1 bytes, one per DEVLST entry: DSSS in the high
* nibble (RD_DEVLST's own byte, `$F0`-masked -- learning:
* 01KW1GTYH4NRG0F8M7AAT6EG9Z) OR'd with bit 0 when that unit's
* driver-address vector (RD_NODEV+2*nibble, the $BF10-$BF2F
* table, same nibble indexing RD_RAMSLT already relies on) falls
* in main LC bank 1 $D000-$D5FF -- ProDOS 8's built-in Disk ][
* driver (learning:01M0W5ZCYJQH2A19V5XJW2HZR4, "CLD / JSR / LDA
* $C08E,X"). NO DEVICE IS TOUCHED: this reads only ProDOS's
* global page and the driver-vector table, both ordinary main
* memory, and neither is bank-switched -- the whole point, per
* the operator's ruling, is that `/dev` costs nothing with an
* empty 5.25" drive on the bus. Touches no LC switch, no ALTZP,
* no `cli`, embeds no inline MLI bytes (rules 1/2/3 all clear);
* ends `jsr`+`rts`, never `jmp` (rule 6).
*
* IN: one parameter, the caller's buffer pointer (no leading
* MLI-style count byte -- this is a maux call, not a delegate).
* KSEG_CALL is a flat-to-segment JUMP, not a fresh syscall
* entry,
* so K_PARMLO/K_PARMHI still hold the ORIGINAL syscall's parms
* pointer untouched -- this routine calls PCPI_CALLPARM itself,
* exactly as the flat original did before the move.
* OUT: A = DEVCNT+1 (byte count actually written), carry clear.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
*---------------------------------------------------------------
* PRC_SYN_DISP -- shared KSEG_CALL target for procdev.s's four
* PRC_DEVLIST/PRC_ROOTLIKE/PRC_SYNAPPLY/PRC_ONLINE stubs,
* 2026-09-30 headroom round (docs/DEVFS-NOTES.md): re-dispatches
* on the selector the flat stub left in X, then `jmp`s (never
* `jsr`s) into the real body so that body's own `rts` returns
* straight through KSEG_CALL, unchanged from when each stub
* reached its body directly. CLOBBERS: whatever the reached body
* clobbers (X itself is always clobbered, by construction).
*---------------------------------------------------------------
PRC_SYN_DISP
            cpx   #0
            beq   :d0
            cpx   #1
            beq   :d1
            cpx   #2
            beq   :d2
            cpx   #4
            beq   :d4
            jmp   PRC_ON_BODY
:d0         jmp   PRC_DL_BODY
:d1         jmp   PRC_SG_BODY
:d2         jmp   PRC_SA_BODY
:d4         jmp   PRC_DV_BODY

PRC_DL_BODY
            lda   #2
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM
            sta   PRC_USER_PTR
            lda   PRC_PARM+1
            sta   PRC_USER_PTR+1
            ldx   RD_DEVCNT
:loop       jsr   PDL_ONE
            sta   PDL_REC,x
            dex
            bpl   :loop

            lda   RD_DEVCNT
            sta   P_TMP             ;byte count = DEVCNT+1,
            inc   P_TMP             ;  computed once, BankCopy
                                    ;  and the return value
                                    ;  alike
            jsr   PRC_SEL_CRBNK
            sta   P_BANK
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<PDL_REC
            sta   K_BC_SRCADDR
            lda   #>PDL_REC
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   PRC_USER_PTR
            sta   K_BC_DSTADDR
            lda   PRC_USER_PTR+1
            sta   K_BC_DSTADDR+1
            lda   P_BANK
            sta   K_BC_DSTBANK
            lda   P_TMP
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :dlcopied
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:dlcopied   lda   P_TMP
            jsr   PRC_RET_OK_A
            rts

*---------------------------------------------------------------
* PRC_SR_BODY -- is the VIRTUAL path in PRC_PATHBUF ("/", or a
* synthetic row of the root table: /dev, /mnt) a directory the
* kernel owns? (docs/VROOT.md; the kernel's own `..` is gone --
* liba MKPATH pops the virtual text.) One optional trailing '/'.
* OUT: A = 0 an ordinary path, 1 "/", 2 a synthetic row (VR_ROW
* names it). Rows of kind 1 are real directories: not ours.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PRC_SR_BODY
            lda   PRC_PATHBUF
            cmp   #1
            bne   :row
            rts                     ;A = 1: "/"
:row        tay
            ldx   #2
            jsr   VR_LOOK
            bcs   :no
            cmp   #2                ;kind 2 and up are synthetic
            bcc   :no
            lda   VR_END
            cmp   PRC_PATHBUF
            bcc   :no               ;more path follows the row
            lda   #2
            rts
:no         lda   #0
            rts

*---------------------------------------------------------------
* PRC_SG_BODY -- PRC_SYNCLASS (GET_FILE_INFO, docs/VROOT.md): if
* the VIRTUAL path is "/" or a synthetic row, fill
* PML_GFI_PARMS's result fields as a directory (access $C3,
* type $0F, storage $0D, the rest zero) and return A <> 0; a
* KNOWN DEVICE (/dev/null, /dev/s7d1: PDEV_KIND) is the same
* record typeless with storage $0A (CHR) / $0B (BLK), the pair
* the /dev lister reports (docs/EXEC-SHEBANG.md Part 3). Else
* A = 0, nothing touched.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PRC_SG_BODY
            jsr   PRC_SR_BODY
            cmp   #0
            beq   :dev
            ldy   #$0F
            lda   #$0D
            bra   :fill
:dev        jsr   PDEV_KIND
            beq   :no
            ldy   #0
:fill       pha
            phy
            ldx   #MLI_GFI_RLEN
            lda   #0
:z          sta   PML_GFI_PARMS+MLI_GFI_ACC-1,x
            dex
            bne   :z
            lda   #$C3
            sta   PML_GFI_PARMS+MLI_GFI_ACC
            pla
            sta   PML_GFI_PARMS+MLI_GFI_ACC+1
            pla
            sta   PML_GFI_PARMS+MLI_GFI_ACC+4
            lda   #1
:no         rts

*---------------------------------------------------------------
* PDEV_KIND -- is the VIRTUAL path in PRC_PATHBUF "/dev/NAME"
* with NAME a device? Pure: no allocation, no I/O.
* It asks PRC_DEVOPEN itself, with VR_DRY set. PRC_DEVOPEN's
* unknown arm would re-enter the segment through KSEG_CALL (and
* that return reselects the flat bank under a segment routine),
* so PDEV_TRYBLK_G (procdev.s) answers "not shaped" while VR_DRY
* is set, and the sNdM half is asked here, PDEV_BLK_FIND.
* OUT: A = $0A CHR / $0B BLK, or 0 (Z set) unknown.
* CLOBBERS: X, Y, P_COUNT, P_TMP, P_TMP2.
*---------------------------------------------------------------
PDEV_KIND
            lda   #1
            sta   VR_DRY
            jsr   PRC_DEVOPEN
            stz   VR_DRY
            bcs   :no               ;not a /dev/NAME path
            cmp   #1
            bcs   :chr              ;a table handle
            jsr   PDEV_BLK_FIND     ;unknown name: sNdM?
            bcs   :no
            beq   :no
            lda   #$0B              ;BLK, as readdir.equ
            rts
:chr        lda   #$0A              ;CHR
            rts
:no         lda   #0
            rts

*---------------------------------------------------------------
* PRC_DV_BODY -- VR_DEVCALL (vroot.s): a /dev path met by
* VR_XLATE. It NEVER reaches the MLI, whichever call it is
* (docs/EXEC-SHEBANG.md Part 3; ProDOS would hunt a volume named
* DEV and poll every drive). OPEN and GET_FILE_INFO of a device
* answered before getting here. K_CALLNUM picks the verdict:
*   CREATE   a known device: success, a no-op (so `> /dev/null`
*            works); mkdir over one: duplicate; else not found
*   DESTROY, RENAME, SET_FILE_INFO   access error (read-only)
*   anything else (GFI of a stranger, cd, spawn)   not found
* OUT: carry SET, the verdict posted, caller returns.
*---------------------------------------------------------------
PRC_DV_BODY
            lda   K_CALLNUM
            sec
            sbc   #SYS_CREAT        ;CREAT, UNLINK, RENAME, SFI
            beq   :creat            ;are $C0-$C3 in that order
            cmp   #4
            bcs   :nofile
            lda   #MLIE_ACCESS
            bra   :fail
:creat      jsr   PDEV_KIND
            beq   :nofile
            lda   PRC_PARM+7        ;storage_type: mkdir over
            cmp   #$0D              ;a device is a duplicate
            beq   :dup
            jsr   PRC_RET_OK0
            sec
            rts
:dup        lda   #MLIE_DUPFILE
            bra   :fail
:nofile     lda   #MLIE_NOFILE
:fail       jsr   PRC_FAIL_A
            sec
            rts

*---------------------------------------------------------------
* PRC_SA_BODY -- PRC_SYNAPPLY's real body (docs/DEVFS.md): if
* PRC_SR_BODY finds a synthetic directory, do the K_CWD_BUF/
* CWD_WRITE/PRC_PIN_BOOT sequence PRC_SETPFX would do after a
* SET_PREFIX. A synthetic cwd is stored with bit 7 SET on its
* leading '/' ($AF), which no GET_PREFIX answer ever has: that
* is what tells PRC_ABSPATH it is a virtual path, and VR_REV
* leaves it alone. "/" is [1,$AF]; a row is [n+2,$AF,name in
* lower case,'/'].
* OUT: carry SET = handled, caller returns A=0. Carry CLEAR = an
* ordinary path, PRC_PATHBUF untouched. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PRC_SA_BODY
            jsr   PRC_SR_BODY
            cmp   #0
            bne   :handle
            clc
            rts
:handle     cmp   #1
            bne   :row
            sta   K_CWD_BUF         ;length 1
            bra   :mark
:row        ldy   VR_ROW
            lda   VR_TAB,y
            clc
            adc   #2
            sta   K_CWD_BUF
            ldx   #2
:cn         iny
            lda   VR_TAB,y
            ora   #$20
            sta   K_CWD_BUF,x
            inx
            cpx   K_CWD_BUF
            bne   :cn
            lda   #"/"+$80
            sta   K_CWD_BUF,x
:mark       lda   #$AF
            sta   K_CWD_BUF+1
            lda   K_CURPID
            jsr   CWD_WRITE
            jsr   PRC_PIN_BOOT     ;still pinned, even though
                                   ;ProDOS's own prefix was
                                   ;never touched -- idempotent
            sec
            rts

*---------------------------------------------------------------
* PRC_ON_BODY -- PRC_ONLINE's real body: SYS_ONLINE ($C5),
* docs/DEVFS.md, PER UNIT ONLY. Reached from procdev.s's
* trampoline via KSEG_CALL. unit_num 0 (the all-devices poll
* ON_LINE performs when asked for it) is refused with ERR_INVAL
* BEFORE any MLI call is even attempted -- the entire reason
* this
* exists is to give userland a way to read ONE unit's entry
* without ever being able to trigger the poll that grinds an
* empty 5.25" drive (operator ruling, docs/DEVFS.md,
* 2026-09-30).
*
* Parmlist (MLI ON_LINE shape, TRM 4.4.6): param_count(1)=2,
* unit_num(1), data_buffer ptr(2) -- 4 bytes total, copied in
* whole even though param_count itself is not otherwise used
* (every OTHER delegate copies the MLI header verbatim too).
*
* RDS_PARMS+1 IS SET HERE, then PMLI_ONLN_CL (procmli.s, flat --
* an ordinary `jsr`, no trampoline needed in THIS direction)
* issues the real MLI call into the SAME PMLI_XFER_BUF every
* other synchronous MLI transfer shares -- see that routine's
* own
* header for why this parmlist is shared, and why PRC_RAMREDISC
* (kbye.s) needs a defensive reset before its own use.
* PMLI_ONLN_CL's `lda LCBANK1_RAM` epilogue restores THIS
* segment's own bank before returning here (rules 1/2/3 all
* clear: no ALTZP flip of its own, no inline MLI bytes embedded
* HERE, and the one LC touch is PMLI_ONLN_CL's, a flat routine's
* to make); ends `jsr`+`rts` only (rule 6). On success, exactly
* 16 bytes (ON_LINE's own fixed per-unit entry size) are copied
* out to the caller's buffer.
*---------------------------------------------------------------
PRC_ON_BODY
            lda   #4               ;count + unit_num + buf ptr
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM+1        ;unit_num
            bne   :unitok
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:unitok     sta   RDS_PARMS+1       ;PMLI_ONLN_CL reads THIS
            lda   PRC_PARM+2
            sta   PRC_USER_PTR
            lda   PRC_PARM+3
            sta   PRC_USER_PTR+1
            jsr   PMLI_ONLN_CL
            beq   :onlok
            jsr   PRC_FAIL_A
            rts
:onlok      jsr   PRC_SEL_CRBNK
            sta   P_BANK
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<PMLI_XFER_BUF
            sta   K_BC_SRCADDR
            lda   #>PMLI_XFER_BUF
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   PRC_USER_PTR
            sta   K_BC_DSTADDR
            lda   PRC_USER_PTR+1
            sta   K_BC_DSTADDR+1
            lda   P_BANK
            sta   K_BC_DSTBANK
            lda   #16               ;ON_LINE's fixed per-unit
            sta   K_BC_LEN          ;  entry size (TRM 4.4.6)
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :onlcopied
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:onlcopied  jsr   PRC_RET_OK0
            rts

*---------------------------------------------------------------
* PRC_TTYMD_SEG -- SYS_TTYMODE's body (was tty7.s PRC_TTYMODE)
* plus the TYPE-AHEAD CARRY (docs/TTY-TYPEAHEAD-BELL.md). Keys
* typed while a committed line is pending wait in the raw ring
* and are cooked into the EDIT buffer the moment the reader
* takes the line; a program that then clears ICANON never saw
* them and the stale bytes lingered into the next cooked line.
* On ICANON 1->0 of the ACTIVE console (a syscall, masked, so no
* tick races it) the edit buffer goes IN FRONT of the ring's
* contents -- it was typed earlier -- capped at the ring's free
* room (63 slots: hd==tl is empty); the excess is dropped, the
* ring's existing drop-type-ahead rule. 0->1 is untouched.
* A background console's slot is not carried (documented gap).
*---------------------------------------------------------------
PRC_TTYMD_SEG
            lda   #2              ;parm: fd, newflags
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM+0
            sta   P_FD
            jsr   PRC_CUR_FDOBJ
            bcc   :objok
            rts
:objok      cmp   #FD_DEV_BASE
            bcc   :inval
            cmp   #FD_TTY3+1
            bcs   :inval
            sec
            sbc   #FD_DEV_BASE    ;console index
            cmp   VC_ACTIVE
            bne   :set
            ldy   PRC_PARM+1      ;new flags keep ICANON?
            tya
            and   #TMD_ICANON
            bne   :set2
            lda   VC_TMODE        ;was already raw?
            and   #TMD_ICANON
            beq   :set2
            jsr   TTK_CARRY
:set2       lda   VC_ACTIVE       ;A = console index again
:set        ldy   PRC_PARM+1      ;new flags
            jsr   TTY_TMODE_STO
            jsr   PRC_RET_OK_A
            rts
:inval      lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts

TTK_CARRY
            lda   VC_RAW_TL
            sec
            sbc   VC_RAW_HD
            and   #VC_RAW_MASK
            eor   #VC_RAW_MASK    ;free slots = 63 - queued
            cmp   VC_EDIT_LEN
            bcc   :cap
            lda   VC_EDIT_LEN
:cap        sta   P_TMP           ;n bytes to carry
            beq   :clr
            eor   #$FF
            sec
            adc   VC_RAW_HD       ;HD - n
            and   #VC_RAW_MASK
            sta   VC_RAW_HD
            tay
            ldx   #0
:cp         lda   VC_INBUF,x
            sta   VC_RAW_BUF,y
            iny
            tya
            and   #VC_RAW_MASK
            tay
            inx
            cpx   P_TMP
            bcc   :cp
:clr        stz   VC_EDIT_LEN
            stz   VC_EDIT_POS
            lda   #$FF
            sta   VC_HIST_CUR
            rts

*---------------------------------------------------------------
* PRC_TTYGEO -- ttygeo(buf, fd) = SYS_TTYGEO (docs/VIDMODE.md
* sec 2). Four bytes to the caller: cols, rows, backend id,
* discipline -- the CONSOLE'S mode, live cells for the active
* console, its annex slot for a background one. The four cells
* are CONTIGUOUS in the VC struct by construction, and their
* offset is computed at RUNTIME from relocatable immediates
* (#<TTY_COLS - #<VC_STATE): a label-difference EQU could not
* cross the REL linker (the VC_ST_SIZE lesson), but two
* relocated low bytes subtracted in code can.
*---------------------------------------------------------------
PRC_TTYGEO_SG
            lda   #3              ;bufptr(2) + fd(1)
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM+0
            sta   PRC_USER_PTR
            lda   PRC_PARM+1
            sta   PRC_USER_PTR+1
            lda   PRC_PARM+2
            sta   P_FD
            jsr   PRC_CUR_FDOBJ
            bcc   :objok
            rts
:objok      cmp   #FD_DEV_BASE
            bcc   :inval
            cmp   #FD_TTY3+1
            bcs   :inval
            sec
            sbc   #FD_DEV_BASE    ;console index
            cmp   VC_ACTIVE
            bne   :slot
            lda   TTY_COLS        ;active: the live cells
            sta   GEO_BUF
            lda   TTY_ROWS
            sta   GEO_BUF+1
            lda   TTY_BKND
            sta   GEO_BUF+2
            lda   TTY_DISC
            sta   GEO_BUF+3
            bra   :out
:inval      lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:slot       tax                   ;background console
            phx                   ;VC_MASK_X counts X down
            jsr   VC_MASK_X
            and   VC_INITED
            plx                   ;plx sets Z from the INDEX --
            ora   #0              ;retest the AND result, or the
                                  ;cold branch is unreachable
                                  ;for every console but 0
                                  ;(caught by the gate leg's
                                  ;first run)
            beq   :cold           ;never touched: its slot is
                                  ;garbage, but its mode is not
                                  ;in doubt -- report what
                                  ;VC_RESET will give it on
                                  ;first touch, the boot-probe
                                  ;inherit (review V1 finding 2)
            lda   #<TTY_COLS      ;4 bytes from the annex slot
                                  ;at the struct
            sec                   ;offset, computed at runtime
            sbc   #<VC_STATE      ;(see header)
            clc
            adc   VC_SLT_LO,x
            sta   K_BC_SRCADDR
            lda   VC_SLT_HI,x
            adc   #0
            sta   K_BC_SRCADDR+1
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            stz   K_BC_SRCBANK
            lda   #BC_KIND_MAIN
            sta   K_BC_DSTKIND
            lda   #<GEO_BUF
            sta   K_BC_DSTADDR
            lda   #>GEO_BUF
            sta   K_BC_DSTADDR+1
            stz   K_BC_DSTBANK
            lda   #4
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            bra   :out
:cold       lda   TTY_CO_BOOT
            sta   GEO_BUF
            lda   #24
            sta   GEO_BUF+1
            lda   TTY_BK_BOOT
            sta   GEO_BUF+2
            stz   GEO_BUF+3
:out        jsr   PRC_SEL_CRBNK
            sta   P_BANK
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<GEO_BUF
            sta   K_BC_SRCADDR
            lda   #>GEO_BUF
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   PRC_USER_PTR
            sta   K_BC_DSTADDR
            lda   PRC_USER_PTR+1
            sta   K_BC_DSTADDR+1
            lda   P_BANK
            sta   K_BC_DSTBANK
            lda   #4
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :ok
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:ok         jsr   PRC_RET_OK0
            rts

*---------------------------------------------------------------
* PCASE_MASK -- docs/PRODOS-CASE.md. Build the GS/OS case word
* for the LAST component of the pathname in PRC_PATHBUF slot
* PC_SLOT (0 = CREATE's path, PRC_PATH2OFF = RENAME's new name):
* bit 15-n set when character n (1-based, counted from the
* component's first character) is a lowercase letter. OUT:
* PC_W (procdev.s, flat), 0 when the name has no lowercase
* letter; the caller sets the bit-15 flag (a flat OR is cheaper
* than 16 B of the segment's last 79). A '/' restarts the
* count. Pure compute -- reads main RAM, no MLI, no LC switch;
* P_PTR1 is the running bit, P_PTR2 the last index (kernel
* scratch, dead at this point of PRC_CREAT/PRC_RENAME).
*---------------------------------------------------------------
PCASE_MASK  ldx   PC_SLOT
            lda   PRC_PATHBUF,x
            clc
            adc   PC_SLOT
            sta   P_PTR2
:init       stz   PC_W
            stz   PC_W+1
            stz   P_PTR1
            lda   #$40
            sta   P_PTR1+1
:next       cpx   P_PTR2
            beq   :mdone
            inx
            lda   PRC_PATHBUF,x
            and   #$7F
            cmp   #'/'
            beq   :init
            cmp   #'a'
            bcc   :adv
            cmp   #$7B
            bcs   :adv
            lda   PC_W
            ora   P_PTR1
            sta   PC_W
            lda   PC_W+1
            ora   P_PTR1+1
            sta   PC_W+1
:adv        lsr   P_PTR1+1
            ror   P_PTR1
            bra   :next
:mdone      rts
