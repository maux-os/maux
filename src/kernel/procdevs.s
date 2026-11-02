*---------------------------------------------------------------
* procdevs.s -- the STUB twin of procdev.s (docs/KSEG.md,
* docs/DEV-BLOCK.md), `put` by every full-kernel manifest that
* does NOT carry the kernel cold segment (every one today except
* src/test/playtest.s).
*
* Every label here matches a label procdev.s ALSO defines, so
* the shared modules (procfile3.s, procmli.s, procmli3.s,
* process.s) reference exactly ONE of the two files' definitions
* depending on which one a given manifest puts -- a dangling
* reference (neither file put) is a genuine link error, not a
* silent miscompile, which is the whole point of scoping by
* module choice instead of `do ]KSEG_WANT ... fin` (nas has no
* `do`/`fin` directive at all; see procdev.s's own header for
* the
* full reasoning).
*
* KSEG_BOOT: PRC_INIT's one call site (process.s) -- nothing to
* load, so a plain `rts`.
*
* The five OFT_BLK dispatch glue labels (PRC_BLK_RD_G/WR_G/
* SMARK_G/GMARK_G/GEOF_G) share ONE body: OFT_TYPE can never
* actually read OFT_BLK in an image that puts this file (nothing
* here ever allocates a slot with that type -- PDEV_TRYBLK_G
* below always answers "not found"), so these are unreachable in
* practice, but the shared dispatch sites call them
* UNCONDITIONALLY and need a real symbol to link against. The
* shared body matches PRC_DEVOPEN's own "no such device" shape
* (ERR_INVAL via PRC_FAIL_A) rather than inventing a new error.
*
* PDEV_TRYBLK_G's OWN contract is different from the other five
* (carry SET = "not an sNdM path at all", checked by the CALLER,
* PRC_DEVOPEN's :unknown arm, which posts the real MLIE_NOFILE
* error itself) -- so it gets its own two-byte body instead of
* sharing PDEV_NOBLK's.
*
* JMP, not `equ`, to PDEV_NOBLK (2026-09-27, coordinator review,
* check-nas-librel): an EQUATE that OTHER modules reference
* cannot
* be exported under REL (Merlin-8 ENT is code labels only) --
* nas-
* librel's own export checker refuses it outright. Five real
* 3-byte trampolines cost 15 B more than five aliases would
* have,
* still well inside the "~15 B" this stub file was estimated at.
*---------------------------------------------------------------
KSEG_BOOT
            rts

* -- PCASE_CREAT/PCASE_RENAME (docs/PRODOS-CASE.md): procdev.s
* -- records the typed case of a created or renamed name; an
* -- image without it just finishes the call, as PRC_CREAT and
* -- PRC_RENAME always did. One shared 3-byte body.
PCASE_CREAT
PCASE_RENAME
            jmp   PRC_RET_MLI_A

PDEV_NOBLK  lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
PRC_BLK_RD_G
            jmp   PDEV_NOBLK
PRC_BLK_WR_G
            jmp   PDEV_NOBLK
PRC_BLK_SM_G
            jmp   PDEV_NOBLK
PRC_BLK_GM_G
            jmp   PDEV_NOBLK
PRC_BLK_GE_G
            jmp   PDEV_NOBLK

PDEV_TRYBLK_G
            sec
            rts

* -- PRC_DEVLIST -- SYS_DEVLIST's stub twin (docs/DEVFS.md,
* -- 2026-09-30): the real body is segment-resident (kdevblk.s
* -- PRC_DL_BODY), so every image that does NOT carry the
* -- segment answers ERR_NOSYS, the same shape BYE_UNWIRE
* -- (entry.s) already uses for an unwired process call.
PRC_DEVLIST lda   #ERR_NOSYS
            jsr   PRC_FAIL_A
            rts

* -- PRC_SYNAPPLY -- docs/DEVFS.md, 2026-09-30: real body is
* -- segment-resident (kdevblk.s); "always carry CLEAR" is
* -- exactly today's pre-devfs PRC_SETPFX behaviour (real
* -- SET_PREFIX, unaffected) for the 31 images that never type
* -- `cd /`/`cd /dev` in their own test scripts.
PRC_SYNAPPLY
            clc
            rts

* -- VR_OTHER -- SYS_VROOT's ops 0-2 (ROW, mount, umount), stub
* -- twin: ERR_NOSYS. PRC_VROOT itself (PHYS) is in vroot.s.
VR_OTHER    jmp   PRC_DEVLIST

* -- VR_MNTCK -- /mnt/NAME names a volume (loopseg.s, KFIX5):
* -- the stub images leave every name to the MLI, carry clear.
VR_MNTCK    clc
            rts

* -- VR_DEVCALL -- a /dev path met by VR_XLATE: the stub images
* -- keep the old answer (left for the MLI), carry clear.
VR_DEVCALL  clc
            rts

* -- PRC_SYNCLASS -- GET_FILE_INFO's synthetic-directory
* -- test: the stub says "not synthetic" (A = 0).
PRC_SYNCLASS
            lda   #0
            rts

* -- PRC_ONLINE -- docs/DEVFS.md, 2026-09-30: real body is
* -- segment-resident (kdevblk.s), same ERR_NOSYS shape as
* -- PRC_DEVLIST above.
PRC_ONLINE  lda   #ERR_NOSYS
            jsr   PRC_FAIL_A
            rts

* -- PRC_TTYMODE / PRC_TTYGEO -- ERR_NOSYS stubs (2026-10-08).
* -- Real bodies: segment-resident (kdevblk.s PRC_TTYMD_SEG and
* -- PRC_TTYGEO_SG). They WERE plain bodies here; the visual
* -- bell's flat hooks pushed the pinned test kernels past the
* -- io_buffer ceiling, so ~210 B per image go. Callers on
* -- segment-less images get carry SET, the same a non-console
* -- fd gave before (docs/TTY-TYPEAHEAD-BELL-NOTES.md audit).
PRC_TTYMODE
PRC_TTYGEO  jmp   PRC_DEVLIST        ;ERR_NOSYS, shared
