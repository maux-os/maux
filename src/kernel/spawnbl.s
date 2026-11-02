*---------------------------------------------------------------
* spawnbl.s -- the BUILTIN-IMAGE spawn path (KFIX5): the lookup
* PRC_SPAWN used to carry inline, the embedded-image loader
* (PRC_LOAD_IMG, was procspawn.s) and the load dispatch. REAL
* twin; spawnpl.s is the plain twin every manifest WITHOUT
* builtin images puts instead (module choice, not `do`/`fin`:
* the procdev.s / procdevs.s precedent, docs/KSEG.md).
*
* WHO PUTS THIS. Only the manifests whose harness really spawns
* a builtin image, or whose gate needs the lookup to exist so it
* can prove a pathname is NOT taken for one: processtest and
* argvtest (real images) and envtest (its EGONE case pins the
* whole-path rule below). The ~150 B the lookup, the loader,
* the table and the dummy images cost were carried by every
* other image, MAUXPLAY included, for nothing: sh spawns real
* files. (forktest and sertest, table of 0, put spawnpl.s.)
*
* Both twins define the SAME two labels:
*   PRC_BLTN   OUT: carry SET = the path in PRC_BYTE named a
*              builtin image (PRC_IMAGE_SRC/LEN and PRC_IMG_KIND
*              set); carry CLEAR = a pathname.
*   PRC_LD_ANY load the child's image: the builtin or the file.
* The table (K_BLTN_COUNT/TAG/SRC_LO/SRC_HI/LEN_LO/LEN_HI) is
* the manifest's, as before; spawnpl.s needs none of it.
*---------------------------------------------------------------
PRC_IMAGE_SRC ds  2             ;builtin image address
PRC_IMG_KIND  ds  1             ;0 builtin, 1 file

*-- THE BUILTIN TAG IS A WHOLE PATH, NOT A PREFIX. This used to
*-- match on the first character alone, so ANY spawn path
*-- beginning with a tag letter became that builtin -- and the
*-- tags are single letters ('E','R','W' in the env harness).
*-- `ECHO`, spawned as a bare word once PATH stopped resolving
*-- it (sh's BUILD_PATH :exhausted branch spawns the WORD),
*-- matched 'E' and was loaded as SIMG_EXIT: a ONE-BYTE image
*-- containing a lone `rts`. Entered as a real process at
*-- LOAD_BASE with a fresh, empty stack, that `rts` returns to
*-- $0000 and runs zero page as BRK opcodes: a user BRK, so the
*-- child dies of SIGTRAP ($?=133; before KBRK it parked the
*-- machine in KRN_BRK_TRAP).
*-- Measured: PRC_IMG_KIND=0, PRC_IMAGE_LEN=1, PRC_CHLD_BANK=7,
*-- bank 7 at $0800 holding `60 00 00...`.
*-- docs/SPAWN-BANK7-CRASH.md carries the trace and the gate.
PRC_BLTN    lda   PRC_BYTE+1
            bne   :fileimg             ;longer than one char --
                                       ;it is a real pathname
            lda   PRC_BYTE
            and   #$7F
* See K.PROCESS.TXT: "-- Builtin-image lookup. The kernel used"
*-- S9 L4/L5: A LINKED CELL, NOT AN EQUATE. Every other field of
*-- the builtin table is read from memory already; this bound
*-- was
*-- the one immediate, and an EQUATE cannot cross the Merlin
*-- linker (ENT exports code labels only), so it was the single
*-- symbol keeping process.s from generating a REL form. Its
*-- value differs per harness (0, 1, 3 in twenty-seven of them,
*-- 4), so it is per-manifest configuration and cannot move to a
*-- shared equ file either. `ldx abs` sets Z exactly as `ldx
*-- #imm` does, so the empty-table `beq` below is unchanged.
            ldx   K_BLTN_COUNT
            beq   :fileimg
:blsearch   dex
            cmp   K_BLTN_TAG,x
            beq   :blhit
            cpx   #0
            bne   :blsearch
:fileimg    lda   #1
            sta   PRC_IMG_KIND
            clc
            rts
:blhit      stz   PRC_IMG_KIND
            lda   K_BLTN_SRC_LO,x
            sta   PRC_IMAGE_SRC
            lda   K_BLTN_SRC_HI,x
            sta   PRC_IMAGE_SRC+1
            lda   K_BLTN_LEN_LO,x
            sta   PRC_IMAGE_LEN
            lda   K_BLTN_LEN_HI,x
            sta   PRC_IMAGE_LEN+1
            sec
            rts

PRC_LD_ANY  lda   PRC_IMG_KIND
            beq   PRC_LOAD_IMG
            jmp   PRC_LD_FL_IMG

PRC_LOAD_IMG
*-- A BUILTIN IMAGE HAS NO FILE, so it has no aux_type to
*-- honour: it loads at the floor, exactly as everything did
*-- before S9 L3b.
            lda   #<LOAD_BASE
            sta   PRC_LOADADR
            lda   #>LOAD_BASE
            sta   PRC_LOADADR+1
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   PRC_IMAGE_SRC
            sta   K_BC_SRCADDR
            lda   PRC_IMAGE_SRC+1
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   PRC_LOADADR
            sta   K_BC_DSTADDR
            lda   PRC_LOADADR+1
            sta   K_BC_DSTADDR+1
            lda   PRC_CHLD_BANK
            sta   K_BC_DSTBANK
            lda   PRC_IMAGE_LEN
            sta   K_BC_LEN
            lda   PRC_IMAGE_LEN+1
            sta   K_BC_LEN+1
* -- docs/STICKY.md sec 21: BankCopyZ, not BankCopy. A builtin
* -- image is ONE copy call, so the zeroed page is genuinely
* -- fused into it -- same 80STORE bracket, and the page
* -- address is whatever DSTADDR advanced to, which is exactly
* -- LOAD_BASE+PRC_IMAGE_LEN. No second pass, no arithmetic.
            jsr   BankCopyZ
            rts
