*---------------------------------------------------------------
* process.s -- task #12 process syscalls: spawn/exit/wait/pipe,
* plus ProDOS-backed file calls and file-backed spawn for the
* #12->#10 bridge.
* Full design notes: K.PROCESS.TXT (docs/a2/)
*---------------------------------------------------------------

*-- P_PTR3 ($D4) lives in inc/proc.const.equ (2026-09-13)

* See K.PROCESS.TXT: "OFT_COUNT/OFT_FREE/OFT_PIPE_R/OFT_PIPE_W/"

WAIT_CHAN_MAX equ  PCB_COUNT


* PRC_ARGV_HDR / PRC_ARGV_PTRS / PRC_ARGV_STR moved to
* inc/memmap.equ (2026-08-17, docs/LIMITS.md): the child's
* argv layout is a property of the process memory map, and
* keeping a second copy here is what let this file and
* inc/startup.equ describe the same three addresses
* independently. ARG_MAX and ARGV_PTR_LIM are derived from them
* there, so PSTG_ARGV's ceilings move with the map.

* MLI ($BF00) comes from inc/memmap.equ (task #8a).
* -- K1 (docs/PROCIO.md section 3): 128 -> 512, one ProDOS
* block,
* -- block-aligned. PRC_CHUNK below grew 1 -> 2 bytes to hold it
* -- (a 1-byte chunk field tops out at 255); every consumer of
* -- PMLI_XFR_SIZE/PRC_CHUNK (procfile.s
* PRC_FILE_READ/PRC_FILE_WR,
* -- procspawn.s's PRC_LD_FL_IMG loader) was updated to move the
* -- now-2-byte chunk size into MLI_REQLO/REQHI instead of
* -- hardcoding REQHI=0. Verified empirically (merlin32 -v1
* -- build of src/test/fileproctest.s, 2026-08-20 -- the
* -- exact KERNEL_PROC_MODS set MAUXSH.SYSTEM ships) that this
* -- kernel's own code+data ends at $567F, with everything from
* -- $6000 up entirely unclaimed by anything else, inside
* -- K_CODE_C ($6000-$BFFF, memmap.equ). See docs/MEMMAP.md's
* -- task #16 addendum.
* --
* -- NO LONGER AN INVARIANT, and no longer unenforced (T2 item
* -- 1, 2026-08-23): the "$6000 up unclaimed" claim above went
* -- false the day it was marked stale (S3 review N2, fork
* -- fleet-wiring rebase) and nothing gated it until now.
* -- scripts/check_kernel_images.py does, DERIVED not
* -- enumerated: it walks check_manifests.build_graph()/
* -- closure() for every top-level manifest whose put/use
* -- chain reaches THIS file, keeps only the ones the Makefile
* -- builds to a `.SYSTEM` target (27, measured), parses
* -- PMLI_IBF_BASE below as the ceiling and each manifest's own
* -- `org` + built file size as its extent, and fails if a
* -- member's overrun grows past KNOWN_OVERRUN's recorded
* -- value or a new member overruns at all -- a shrink-only
* -- ratchet, not a hard gate: ELEVEN images measure over the
* -- ceiling as of this writing (the ten named below, plus
* -- MAUXSEDTEST -- task #8b landed after the count below was
* -- written), all still measured-safe the same way this
* -- comment always argued (boot-time tail bytes consumed
* -- before file traffic allocates the buffer).
* -- check_kernel_images.py also scans every merlin32 -v1 dump
* -- for a silent `[Error]` and flags a `.SYSTEM` older than
* -- its own put/use closure, so a stale artifact or a
* -- swallowed assembler error cannot defeat the Makefile's
* -- `test -f` guard unnoticed either. See that module's
* -- docstring for the full derivation and docs/STICKY.md's
* -- PLACEHOLDER section for the writeup.
* --
* -- Original finding, kept for the history (addresses as
* -- measured 2026-08-23, before the pathname-fence RELAYOUT
* -- grew two of them further -- check_kernel_images.py's
* -- KNOWN_OVERRUN has the current numbers): TEN test .SYSTEM
* -- images ended past $6000, inside the io_buffer range --
* -- MAUXEXPR $6A96 (reaches io_buffer 3), MAUXEDTEST $63BD,
* -- MAUXFINDTEST $63AB, MAUXTESTEV $6239, MAUXDUTEST $6231,
* -- MAUXLSTEST $61F1, MAUXTAIL $615B, MAUXPLAY $60D3,
* -- MAUXDIFFTEST $6042, MAUXFILEPROC $602F.
* --
* -- MOVED $7000 -> $7800, 2026-08-22, when MLI_IOBUF_CNT went
* -- 4 -> 6. PRC_IBF_HI_A places io_buffer N (1-based) at
* -- >PMLI_IBF_BASE + (N-1)*4, so four buffers filled
* -- $6000-$6FFF and buffer FIVE lands exactly on the old
* -- $7000. Six buffers occupy $6000-$77FF, so the xfer buffer
* -- goes above them. K_CODE_C is 24576B and this uses 6656B of
* -- it, so the constraint here is arithmetic, not space.

* MLI parmlist offsets used by the delegate.
* -- GET_FILE_INFO ($C4) parmlist offsets. MLI_GFI_MDATE/ --
* MODTIME were added by sticky.s (task #15) for the raw-mtime --
* compare only; docs/STICKY.md section 4: the dates are opaque
* -- under ProDOS 2.5's Extended format, but equality needs no
* -- decoding. The rest (task: "wire GET_FILE_INFO into the --
* kernel file-syscall broker", 2026-08-19) are the remaining --
* RESULT fields PRC_GFI copies back to a stat() caller -- see --
* PML_GFI_PARMS below for the full $0A-param shape these index
* -- into.
MLI_GFI_FTYPE   equ 4
MLI_GFI_STYPE   equ 7
MLI_GFI_NBLKS equ 8
MLI_GFI_CDATE   equ 14
MLI_GFI_CTIME   equ 16

* -- SET_FILE_INFO ($C3) parmlist offsets (chmod task,
* -- 2026-08-21). access/file_type/aux_type share GET_FILE_
* -- INFO's own MLI_GFI_ACC/FTYPE/ATYPE offsets (3/4/5) -- the
* -- two calls' parmlists agree up to that point (TRM 4.4.3 vs
* -- 4.4.4). null_field is 3 BYTES (TRM: "these three bytes
* -- preserve symmetry between this and the GET_FILE_INFO
* -- call") -- it occupies the SAME 3 bytes (offsets 7-9) GFI's
* -- storage_type+blocks_used do, which is exactly why mod_date/
* -- mod_time land at the SAME offsets (10/12) as GFI's own --
* -- MLI_SFI_MDATE/MTIME below are deliberately the identical
* -- numbers as MLI_GFI_MDATE/MTIME above, not a coincidence.
MLI_SFI_MDATE equ 10
MLI_SFI_MTIME equ 12
MLI_SFI_LEN   equ 11  ;bytes from MLI_GFI_ACC..MLI_SFI_MTIME+1,
                       ;offsets 3..13 -- the whole SET_FILE_INFO
                       ;INPUT half caller supplies past
                       ;param_count+pathname_ptr

*---------------------------------------------------------------
* Kernel-owned process state.
*---------------------------------------------------------------
PRC_FREE_CNT ds 1
PRC_FREE_LIST  ds 16

OFT_TYPE     ds OFT_COUNT
OFT_PIPE     ds OFT_COUNT
OFT_REFCNT   ds OFT_COUNT
OFT_REFNUM   ds OFT_COUNT
OFT_IOBUF    ds OFT_COUNT
OFT_LRU      ds OFT_COUNT        ;K_FTICK at last use -- the
                                 ;lending victim is the oldest
                                 ;(procfd2.s PRC_PARK_ONE)

* -- OFT_BLK per-slot state (docs/DEV-BLOCK.md) MOVED to
* -- procdev.s 2026-09-27 (coordinator review, DECISION 1 --
* -- module choice replaces `do ]KSEG_WANT`, which nas cannot
* -- assemble): OFT_UNIT/OFT_BLKPOS0-2/PBLK_OFFLO/OFFHI/ROOMLO/
* -- ROOMHI now live there, `put` only by a manifest carrying
* -- the
* -- segment.

MLI_BUF_USED ds MLI_IOBUF_CNT
K_FTICK      ds 1                ;file-op tick, wraps freely
K_IBF_INUSE  ds 1                ;io_buffers held right now
K_IBF_HIWAT  ds 1                ;max K_IBF_INUSE since boot
K_ROOWN      ds 1                ;OPEN-RO: OFT entry holding
                                 ;the live mark (0 = none)
PRC_ROI      ds 1                ;OPEN-RO: open's OFT flags
                                 ;($80, or $C0 joining)
PRC_ROX      ds 1                ;OPEN-RO: PRC_ROACQ's entry
K_CLSERR     ds 1                ;OPEN-RW-2: last close/flush
                                 ;error PRC_DEC_OBJ saw (0=none)
K_QUAR_CNT   ds 1                ;OPEN-RW-2: buffers held back
                                 ;after a failed CLOSE (a
                                 ;counted leak, never re-lent)
K_PARK_CNT   ds 1                ;files parked since boot
                                 ;(diagnostic; harnesses read
                                 ;both by symbol, never by
                                 ;address)

PIPE_USED    ds PIPE_COUNT+1
PIPE_RDP     ds PIPE_COUNT+1
PIPE_WRP     ds PIPE_COUNT+1
PIPE_BYTES   ds PIPE_COUNT+1
PIPE_RREFS   ds PIPE_COUNT+1
PIPE_WREFS   ds PIPE_COUNT+1

* -- 14, not 12: SET_FILE_INFO's caller-input struct (param_
* -- count + path ptr(2) + access + file_type + aux_type(2) +
* -- null_field(3, TRM: "preserve symmetry between this and
* -- GET_FILE_INFO") + mod_date(2) + mod_time(2) = 14 bytes,
* -- chmod task 2026-08-21) is the largest PCPI_CALLPARM copies
* -- in here -- two bytes past CREATE's own 12 (its previous
* -- high-water mark).
PRC_PARM    ds 14
*-- TWO bytes, not one, since 2026-08-26: PRDPAR_BYTE copies the
*-- path's first byte AND the one after it, so the builtin-image
*-- lookup below can require a path exactly ONE character long.
*-- A valid C string of length >= 1 always has that second byte.
PRC_BYTE    ds 2
* -- PSTG_ARGV scratch (task #13 C4; full story docs/LIMITS.md).
PRC_ARGV    ds 2        ;one argv pointer entry at a time
PRC_ARGOFF  ds 2        ;running offset = ARG_MAX accumulator
PRC_ARGLEN  ds 2        ;this arg's bytes, NUL included
PRC_ARGSUM  ds 2        ;ARGOFF+ARGLEN vs ARG_MAX
PRC_ARGWORD ds 2        ;staged header bytes (via BankCopy)
* -- The environment shares argv's block (docs/SYSCALL.md item
* -- 13c), so the two ceilings became SHARED budgets and the
* -- staging loop had to stop deriving the pointer-array slot
* -- from the arg INDEX: envp's pointers start after argv's
* -- pointers AND the envc byte between them. PRC_PTROFF is that
* -- running byte offset from PRC_ARGV_PTRS -- one accumulator
* -- for both arrays, the way PRC_ARGOFF is one accumulator for
* -- both string blocks.
PRC_PTROFF  ds 1        ;bytes of pointer array used so far
PRC_ENVCOFF ds 1        ;PRC_PTROFF at the envc byte, held while
                        ;the env is staged and the count is
                        ;still unknown
PRC_LISTP   ds 2        ;the PARENT's pointer array being walked
                        ;(argv's, then envp's)
PRC_PAR_BANK ds 1       ;parent bank as a NUMBER for BankCopy
PRC_IMAGE_LEN ds 2
PRC_CHILD_PID ds 1
PRC_CHLD_BANK ds 1
PRC_PAR_PID ds 1
PRC_STAT_PTR ds 2
PRC_FDA_PTR ds 2
PRC_TRANS   ds 1
PRC_PATH_PTR ds 2
*-- PRC_PATHBUF: 130 B homed in KBSS (inc/mm.kbss.equ), KSPACE2.
                                 ;TWO 65-byte pathname slots:
                                 ;RENAME must translate both of
                                 ;its paths before the call goes
*-- PSTAT_REC (6 B): gone -- PRC_PSTAT copies straight from
*-- K_PCB_SCRATCH (PS-ARGS).
* -- PDL_REC MOVED to kdevblk.s (the segment), 2026-09-30 (docs/
* -- DEVFS.md/DEVFS-NOTES.md, KSEG.md rule 4's clarification):
* -- PRC_DEVLIST (SYS_DEVLIST) is segment-resident now, and
* -- nothing outside it ever touches this 16-byte scratch, so
* -- 16 flat bytes on all ~31 non-play images bought nothing.
PRC_PFXSAVE ds 66                ;boot prefix, held constant
*-- PRC_TMPPATH: 66 B homed in KBSS (inc/mm.kbss.equ), KSPACE2:
*-- PRC_ABSPATH composition scratch.
VR_PEND     ds 1                 ;slot holds a VIRTUAL path
PRC_CWDPID  ds 1                 ;PRC_SETPFX: the caller's pid,
                                 ;captured BEFORE the MLI call
                                 ;that may switch away
PRC_PATH_SRC ds 1                ;parm offset being copied FROM
PRC_PATH_DST ds 1                ;byte offset in PRC_PATHBUF
PRC_BASEPG  ds PCB_COUNT         ;S9 L3b: per-process load-base
                                 ;PAGE, one byte per pid, in
                                 ;ORDINARY MAIN KERNEL MEMORY --
                                 ;the lazy-free slot arrays'
                                 ;precedent, not the annex.
                                 ;
                                 ;A PAGE, not an address: the
                                 ;only thing that outlives the
                                 ;spawn is brk()'s floor, and
                                 ;that comparison is on the high
                                 ;byte (a break is page-granular
                                 ;-- PCB_BRK is a page too). The
                                 ;full 16-bit base lives in
                                 ;PRC_LOADADR for the length of
                                 ;the load, and in the lazy-free
                                 ;slot for a retained bank.
                                 ;
                                 ;The annex was tried first and
                                 ;was wrong twice over: reading
                                 ;it means PCB_RD_FIELDS ->
                                 ;COPYIN_ENTRY on fork's hot
                                 ;path, and the accessors cost
                                 ;~300B the kernel does not have
                                 ;(every .SYSTEM image crossed
                                 ;PMLI_IBF_BASE). Main memory is
                                 ;`lda PRC_BASEPG,x`.
PRC_LOADADR ds 2                 ;S9 L3b: the load address for
                                 ;the spawn in progress -- the
                                 ;binary's aux_type, or
                                 ;LOAD_BASE for a builtin image
                                 ;(no file, so no aux). Set
                                 ;before any of the four sites
                                 ;that used to name LOAD_BASE
                                 ;directly (image copy, the
                                 ;sec-21 zeroed page, the file
                                 ;loader's write pointer, and
                                 ;the launch address).
PRC_USER_PTR ds 2
PRC_REMAIN ds 2
PRC_DONE   ds 2
PRC_CHUNK  ds 2               ;K1: 512 needs 2 bytes
PRC_IOBUF_ID ds 1
PRC_LENDX   ds 1                 ;lending scratch: the OFT index
                                 ;being unparked (PRC_UNPARK)
PRC_VICT    ds 1                 ;lending scratch: the victim
                                 ;(PRC_PARK_ONE) -- SEPARATE
                                 ;from PRC_LENDX: an unpark can
                                 ;park on the way
PRC_VAGE    ds 1                 ;lending scratch: victim's age
PRC_UNPKID  ds 1                 ;PRC_UNPARK: the buffer id held
                                 ;until SET_MARK proves the
                                 ;reopen usable (IB5)
PRC_CANLEN  ds 1                 ;PRC_CANONPATH result length,
                                 ;0 = could not canonicalize
PRC_BRKPG   ds 1                 ;PBRK_SET's one-byte hold: the
                                 ;new break page, read back
                                 ;INSIDE the RAMWRTAUX bracket
                                 ;(a main-memory READ, which
                                 ;RAMWRT does not govern) so the
                                 ;bracket stays three
                                 ;instructions long
*-- TTY_ROW .. TTY_INBUF (15 legacy single-console cells and
*-- the 128 B cooked-line buffer) DELETED 2026-10-11 (docs/
*-- KSPACE2-NOTES.md sec 1): nothing referenced any of them.
*-- TTY_COLS lives in the VC struct (tty.s), docs/VIDMODE.md.

PML_OPN_PARMS
            dfb   3
            da    PRC_PATHBUF
            da    0
            dfb   0
*-- io_buffer lending's own OPEN parmlist (procfd2.s
*-- PRC_UNPARK): its pathname pointer is repointed at an OFT
*-- slot's saved path per call, so it must not share
*-- PML_OPN_PARMS, whose pointer the spawn loader trusts.
PML_UNPK_PRM
            dfb   3
            da    0
            da    0
            dfb   0
*-- GET_PREFIX into PRC_CANON (PRC_CANONPATH) -- its own block:
*-- PMLI_GPFX_CL's PRC_PARM is the caller's OPEN parmlist at the
*-- moment the lending checks run.
PML_GPFX2
            dfb   1
            da    PRC_CANON
PMLI_RD_PARMS
            dfb   4
            dfb   0
            da    PMLI_XFER_BUF
            da    0
            da    0
PMLI_WR_PARMS
            dfb   4
            dfb   0
            da    PMLI_XFER_BUF
            da    0
            da    0
PML_CLS_PARMS
            dfb   1
            dfb   0
PML_GTF_PARMS
            dfb   2
            dfb   0
            dfb   0,0,0
* -- SET_MARK ($CE)/GET_MARK ($CF)/SET_EOF ($D0) -- the other
* three of the seek family (docs/FLEET.md "`>>` and the seek
* family"; GET_EOF is the ABOVE PML_GTF_PARMS, already wired for
* the spawn loader -- PRC_GETEOF (procfile.s) becomes its SECOND
* caller, not a duplicate). Byte-identical (param_count=2,
* ref_num, 3-byte value) shape to PML_GTF_PARMS per the TRM, so
* PRC_SETMARK/PRC_GETMARK/PRC_SETEOF (procfile.s) address these
* via the SAME MLI_REF/MLI_EOFLO/MLI_EOFHI/MLI_EOFBANK offsets
* already declared above for GET_EOF -- "EOF" in those equ names
* is GET_EOF's own field name, but the offsets (1/2/3/4) are
* just this parmlist SHAPE's, reused rather than duplicated
* under a "MARK"-named alias.
PML_SMARK_PRM
            dfb   2
            dfb   0
            dfb   0,0,0
PML_GMARK_PRM
            dfb   2
            dfb   0
            dfb   0,0,0
PML_SEOF_PARM
            dfb   2
            dfb   0
            dfb   0,0,0
* -- READ_BLOCK ($80)/WRITE_BLOCK ($81) parmlists MOVED to
* -- procdev.s 2026-09-27 (coordinator review, DECISION 1): this
* -- parmlist is DATA (rule 4), so it stays flat there, `put`
* -- only by a manifest carrying the segment -- PML_RDBLK_PRM/
* -- PML_WRBLK_PRM.
* -- GET_FILE_INFO ($C4), param_count $0A -- pathname ptr,
* access, file_type, aux_type(2), storage_type, blocks_used(2),
* mod_date (2), mod_time(2), create_date(2), create_time(2).
* sticky.s (task #15) only ever reads mod_date/mod_time back
* (MLI_GFI_ MODDATE/MODTIME above); PRC_GFI (SYS_GFI, below) is
* the second user of this SAME struct and copies every other
* RESULT field back to a stat() caller. Both run in process
* context only, never concurrently (see PRC_GFI's own header) --
* sharing one kernel- owned instance, pathname pointer included,
* is safe.
PML_GFI_PARMS
            dfb   10
            da    0
            dfb   0
            dfb   0
            da    0
            dfb   0
            da    0
            da    0
            da    0
            da    0
            da    0

ANX_CLR_PG0  equ   $08          ;annex clear: first page
ANX_CLR_END  equ   $BF          ;first page above the span; the
                                ;last user VCA_STR_B ends $B400

*---------------------------------------------------------------
* PRC_INIT -- boot-time process layer init. Call after
* INSTALL_COPY and SCH_INIT, before the first process starts.
*---------------------------------------------------------------
PRC_INIT
            lda   #<PRC_FILECALL
            sta   K_PRODOS_VEC
            lda   #>PRC_FILECALL
            sta   K_PRODOS_VEC+1
            lda   #<PRC_BRK_TRAP        ;user BRK = SIGTRAP,
            sta   K_BRK_VEC             ;not a halt (entry.s)
            lda   #>PRC_BRK_TRAP
            sta   K_BRK_VEC+1

*-- S9 L3b: every pid's load-base PAGE starts at the floor.
*-- Spawn and fork overwrite it with the real one; this covers
*-- pid 1, which no spawn ever created, and any pid read before
*-- a spawn writes it -- a zero here would give brk() a floor
*-- of $0000 and let a process set its break below its own
*-- image.
            ldx   #PCB_COUNT-1
            lda   #>LOAD_BASE
:basepglp   sta   PRC_BASEPG,x
            dex
            bpl   :basepglp

            lda   #14
            sta   PRC_FREE_CNT
            ldx   #0
            lda   #15
:freelp     sta   PRC_FREE_LIST,x
            sec
            sbc   #1
            inx
            cpx   #14
            bne   :freelp

            ldx   #0
            lda   #0
:oftlp      sta   OFT_TYPE,x
            sta   OFT_PIPE,x
            sta   OFT_REFCNT,x
            sta   OFT_REFNUM,x
            sta   OFT_IOBUF,x
            sta   OFT_LRU,x
            inx
            cpx   #OFT_COUNT
            bne   :oftlp

            ldx   #0
:iobuflp    sta   MLI_BUF_USED,x
            inx
            cpx   #MLI_IOBUF_CNT
            bne   :iobuflp
            sta   K_FTICK
            sta   K_IBF_INUSE
            sta   K_IBF_HIWAT
            sta   K_PARK_CNT
            sta   K_ROOWN
            sta   K_NOSWITCH

            ldx   #0
:pipel      sta   PIPE_USED,x
            sta   PIPE_RDP,x
            sta   PIPE_WRP,x
            sta   PIPE_BYTES,x
            sta   PIPE_RREFS,x
            sta   PIPE_WREFS,x
            inx
            cpx   #PIPE_COUNT+1
            bne   :pipel
*-- KFIX11: the annex is aux bank 0, $0800-$BEFF, and its
*-- power-on contents are nobody's (a real RamWorks powers up
*-- with a pattern; the emulators that zero-fill hid every
*-- read-before-write: pid 1's cwd slot, docs/KFIX11-NOTES.md).
*-- One clear over the whole span, before anything writes it:
*-- the cwd table, the PCB array, SIG rows, the ^C sweep's
*-- foreground table, every console's state and screen store.
*-- A is still 0 (the table loops above only store it).
*-- 80STORE off first: with it on (and HIRES), RAMWRT is
*-- ignored over $2000-$3FFF and this would clear MAIN's image.
            sta   BANKSEL
            sta   RAMWRTAUX
            sta   CLR80STORE
            sta   K_PCB_PTR
            tay
            ldx   #ANX_CLR_PG0
:anxpg      stx   K_PCB_PTR+1
:anxclr     sta   (K_PCB_PTR),y
            iny
            bne   :anxclr
            inx
            cpx   #ANX_CLR_END
            bne   :anxpg
            sta   RAMWRTMAIN
            jsr   SER_DETECT                   ;ser.s: SSC slot
                                              ;scan, before the
                                              ;tick hook can
                                              ;ever poll it
            jsr   TTY_INIT
            lda   #<TTY_TICK                 ;NOT TTY_POLL --
                                             ;the hook must
            sta   K_TICK_HOOK                 ;save/restore
                                              ;shared ZP scratch
            lda   #>TTY_TICK
            sta   K_TICK_HOOK+1
            jsr   LZ_INIT                     ;lazy-free bank
                                              ;tags (src/kernel
                                              ;/lazyfree.s,
                                              ;docs/STICKY.md
                                              ;sec 25) -- one
                                              ;choke point, as
                                              ;for every other
                                              ;table this
                                              ;routine clears
            jsr   PRC_RAMDIS                  ;polite-citizen
                                              ;/RAM disconnect
                                              ;(procmli.s; no-op
                                              ;on raw-block
                                              ;boots) -- the
                                              ;bad-volume wedge,
                                              ;docs/BADVOL-
                                              ;WEDGE.md
* -- KSEG (docs/KSEG.md "The loader"): the FIRST real MLI call
* -- this routine issues (PRC_RAMDIS above pokes the global page
* -- directly, no MLI) -- the io_buffer pool is already zeroed
* -- (the :iobuflp loop above), so PRC_ALLC_IBF (inside
* -- KSEG_LOAD)
* -- is safe here. KSEG_BOOT is a glue label (procdev.s, real;
* -- procdevs.s, stub) called UNCONDITIONALLY (2026-09-27,
* -- coordinator review, DECISION 1 -- module choice replaces
* -- `do ]KSEG_WANT`, which nas cannot assemble at all): the
* -- stub
* -- is a plain `rts`, nothing to load; the real body captures
* -- K_BOOTPFX and loads the segment, halting (K_HALT_KSEG) on a
* -- missing or truncated file.
            jsr   KSEG_BOOT
            rts

*---------------------------------------------------------------
* Public process-call handlers.
*---------------------------------------------------------------
*---------------------------------------------------------------
* PRC_BRK -- brk(value, mode). A process call, so the 3-byte
* parmlist carries NO param_count byte:
*   [0],[1] = value, lo/hi
*   [2]     = mode. 0 = SET (value is an ADDRESS), nonzero =
*             GROW (value is a BYTE COUNT; 0 is a pure query).
*
* The break is the address ONE PAST the heap: a process owns
* [LOAD_BASE, brk). It is stored as a PAGE NUMBER in PCB_BRK
* (inc/mm.annex.equ), so every request rounds UP to a
* whole page -- a caller never gets back less than it asked
* for, and a future fork() gets a page-granular copy extent for
* free, which is the granularity a bank copy wants anyway.
*
* On success the PREVIOUS break is written back over [0],[1]
* (page-aligned; $0000 if there was none) and carry is clear.
* That IS sbrk's contract: GROW hands back the base address of
* the block it just reserved.
*
* A SET MUST COME FIRST. The kernel cannot know where a
* program's uncleared `dum` region ends -- only the program
* knows its own last symbol -- so the kernel never invents an
* initial break. GROW against an unset break is ERR_INVAL, not
* a heap that silently starts at $0800 on top of the program.
*
* ERR_NOMEM  break above PRC_BRK_LIM ($BF00): the overlay page
*            is not the process's to spend
* ERR_INVAL  break below LOAD_BASE, or GROW before any SET
* Neither one changes the stored break.
*---------------------------------------------------------------
PRC_BRK
            lda   #3
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    jsr   PBRK_GET
            sta   P_TMP                 ;the OLD break page
            lda   PRC_PARM              ;round the request UP to
            beq   :nopart               ;  a whole page: any low
            inc   PRC_PARM+1            ;  byte at all costs one
            beq   :toohigh              ;  wrapped past page $FF
:nopart     lda   PRC_PARM+2
            beq   :absolute
            lda   P_TMP                 ;GROW -- needs a base
            beq   :toolow
            clc
            adc   PRC_PARM+1
            bcs   :toohigh
            bra   :chkrange
*-- S9 L3b: THE FLOOR IS THIS PROCESS'S OWN LOAD BASE, not the
*-- kernel-wide LOAD_BASE. A binary linked higher has its image
*-- above $0800, and a break inside that image would hand the
*-- program a heap overlapping its own text.
:absolute   lda   PRC_PARM+1
:chkrange   sta   P_TMP2
            ldx   K_CURPID
            cmp   PRC_BASEPG,x
            bcc   :toolow
            cmp   #>PRC_BRK_LIM
            beq   :inrange
            bcs   :toohigh
:inrange    lda   P_TMP2
            jsr   PBRK_SET
            stz   PRC_PARM              ;hand back the OLD break
            lda   P_TMP                 ;  -- page-aligned, so
            sta   PRC_PARM+1            ;  the low byte is zero
            lda   #3
            jsr   PCPO_PARM_LEN
            rts
:toohigh    lda   #ERR_NOMEM
            jsr   PRC_FAIL_A
            rts
:toolow     lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts

*---------------------------------------------------------------
* PBRK_GET -- OUT: A = the CALLING process's break page (0 =
* none established). Leaves BANKSEL on the annex; every path
* out of PRC_BRK runs through PRC_SEL_CRBNK (inside PRC_FAIL_A
* or PCPO_PARM_LEN) before control returns to the process, and
* that puts the caller's bank back.
*---------------------------------------------------------------
PBRK_GET    lda   K_CURPID
            jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            lda   #PCB_BRK
            ldx   #1
            jsr   PCB_RD_FIELDS
            lda   K_PCB_SCRATCH
            rts

*---------------------------------------------------------------
* PBRK_SET -- IN: A = new break page. Write-only bracket, safe
* inline (RAMWRT moves stores only; the fetch stream stays in
* main) -- the same shape SCH_CREATE and PRC_EXIT already use
* on this array.
*---------------------------------------------------------------
PBRK_SET    sta   PRC_BRKPG
            lda   K_CURPID
            jsr   PCB_PTR_FOR
            lda   #0
            sta   BANKSEL
            sta   RAMWRTAUX
            lda   PRC_BRKPG
            ldy   #PCB_BRK
            sta   (K_PCB_PTR),y
            sta   RAMWRTMAIN
            rts

* -- spawn()'s parmlist is EIGHT bytes since 2026-08-22
* -- (docs/SYSCALL.md item 13c): path(2), argv(2), fdactions(2),
* -- envp(2). envp is a NULL-terminated array of pointers to
* -- "NAME=VALUE" strings in the PARENT's memory, exactly argv's
* -- shape; a NULL envp pointer means "no environment", which is
* -- what every caller that predates the environment passes.
