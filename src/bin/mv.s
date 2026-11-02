*---------------------------------------------------------------
* mv.s -- move or rename a file.
*
* Usage: mv [-fi] SRC... DST
*
* MULTI-INTO-DIRECTORY (FLEET F.2, 2026-09-01): three or more
* operands mean "move each SRC into DST", DST must ALREADY be a
* directory (checked once, up front -- mvtop.s TGTISDIR), each
* pair runs the full single-move machinery (MOVEONE), and a
* failed pair reports, sets exit 1 and continues. Two operands
* are bit-for-bit the old behaviour. The old exit-2 lanes for a
* too-long pathname died with the single-shot shape: every
* failure is exit 1 now except the no-operand usage error.
*
* TWO MECHANISMS, chosen by ProDOS, not preference:
*   same directory    MLI RENAME. Atomic, no data moves.
*   anything else      copy SRC to DST, then unlink SRC.
*
* ProDOS RENAME cannot relink across directories AT ALL: the P8
* TRM requires pathname and new_pathname to "indicate files in
* the same directory" -- /EGG/ROLL -> /EGG/PLANT is legal,
* /EGG/ROLL -> /JELLY/ROLL is not. So a cross-directory move
* costs a full copy, same as crossing volumes. MLI limit, not a
* format one: the on-disk entry could in principle be relinked
* in place (P8 TRM B.2.4), but CREATE/DESTROY/RENAME are the
* only primitives exposed. (Hard links stay unsafe for a
* different reason: no reference count, so DESTROY on either
* entry dangles the other.)
*
* HOW THE CHOICE IS MADE: compare the two paths up to and
* including their last "/". Equal means same directory, so try
* RENAME -- a prediction, not a guarantee: a rejected RENAME
* falls through to the copy path, which remains the authority.
*
* Copy mode is NOT atomic: SRC is unlinked only after a clean
* copy, so a failed copy leaves DST short and SRC untouched.
*
* DST's file_type/aux_type come from SRC (SC_GFI-stat, then
* patch CRPARM before CREATE) -- cp.s's identical pattern.
* access/storage_type/dates stay liba DRAFT-VALUEs either way
* (task #11; no clock wired -- docs/USERLAND.md "ABI
* RESOLUTIONS").
*
* An existing DST is REPLACED, not appended onto: CREATE fails
* duplicate-pathname ($47, P8 TRM 4.4.1) on an existing DST, so
* COPYFILE destroys DST and retries CREATE once -- required, not
* just simpler, because CREATE is the only call that sets
* file_type/aux_type and never touches an EXISTING entry.
*
* T4 REVIEW FIX (2026-08-23), two data-loss defects:
*
* DEFECT 2 -- the destroy used to fire on ANY CREATE failure,
* not just a duplicate name. Now gated on errno $47
* SPECIFICALLY (any other CREATE failure is fatal, unchanged --
* cp.s's own `cmp #ERR_DUPFN` precedent). BEFORE destroying,
* DST is also GET_FILE_INFO-stat'd: an EMPTY subdirectory also
* satisfies DESTROY (P8 TRM 4.4.2, "subdirectory files must be
* empty before they can be destroyed"), so a blind destroy on
* $47 would silently delete an existing directory and replace
* it with a file. DST being a directory is now REFUSED instead
* (ordinary "mv: cannot move" path, errno=$47) -- POSIX
* mv-into-a-directory is out of scope; refusing is the simpler
* of two legitimate choices. Narrows, not widens, the paragraph
* above: a plain-FILE DST whose retry CREATE fails afterward is
* still gone with nothing in its place, just no longer reachable
* via a directory DST.
*
* DEFECT 1 -- SRC being a directory used to be COPIED, not
* rejected: ProDOS OPEN has no storage_type gate (PRC_OPEN is a
* plain MLI delegate -- learning:01M0PSV2PVPWKHZZF5A52EWX31), so
* SRC's raw directory blocks would be copied into a mislabelled
* DST and the real source directory then DESTROYed by UNLINKSRC
* -- same bug class cp.s's own SRC-directory gate closes
* (cp.s:202-222), same fix: GFIPARM_STYP checked before CREATE
* ever runs, "mv: SRC is a directory" to stderr, exit 1.
*
* REGRESSION found on hardware, same day: `bcs :done` after
* SC_READ treated ANY read failure like clean EOF (kernel folds
* MLI_ERR_EOF into clc/trans=0, procfile2.s PRC_FILE_READ) --
* silently reporting success on 0 bytes moved. Now `bcc :rok`/
* `jmp :wfail`, cp.s's idiom. WHY the READ fails is still open
* -- LASTERR/ERRNOMSG report the raw errno on the next run.
*
* -i prompts before replacing an existing destination; only y/Y
* proceeds. -f disables that prompt. In a cluster, the last of
* -i/-f wins. Exit status: 0 moved or declined, 1 failed.
*
* DIRECTORY DESTINATION (2026-08-25): `mv SRC DIR` moves SRC
* INTO DIR when DIR exists and is a directory, and `mv SRC DIR/`
* demands DIR be one -- Unix semantics, resolved up front by
* DSTRESOLV, which rewrites DSTBUF to DIR/basename(SRC) before
* SAMEDIR ever looks at it. This header used to say the form did
* not exist and mv refused it; that was avoidable semantic drift
* and it is gone. COPYFILE's :dupdir directory guard STAYS as a
* backstop -- it is now reachable only when the rewritten
* DIR/basename is ITSELF a directory.
*
* RECURSIVE MOVE (2026-08-25, task #16): a DIRECTORY SRC moving
* to a DIFFERENT PARENT is now performed instead of refused.
* MOVEDIR is the policy and src/liba/cptree.s is the engine --
* mirror the tree under DST, then remove SRC bottom-up, in two
* separate passes so that no source byte is destroyed until the
* whole copy has succeeded (this file's non-atomicity guarantee,
* at directory granularity). DEFECT 1's refusal below stays as a
* backstop and is now effectively unreachable: START asks
* SRCISDIR once, up front, and a directory SRC never reaches
* COPYFILE.
*
* Why it mattered: `mv DIR1 DIR2` is TWO operations chosen by
* the state of the volume -- a RENAME while DIR2 is absent, a
* MOVE INTO once it exists -- and mv did the first and refused
* the second. The identical shell line worked until the day DIR2
* happened to exist. See docs/RECURSIVE-MV.md, docs/CPTREE.md.
*
* Uses ONLY liba -- no direct syscalls, no raw gate address.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/mv.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/readdir.equ
            put   ../../inc/cptree.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ       equ   512

*-- SRCBUF/DSTBUF are ARGBUFSZ bytes each. STRCPY writes the
*-- terminator too, so the longest argument that FITS is
*-- ARGBUFSZ-1 -- an argument of exactly ARGBUFSZ already puts
*-- its NUL on the first byte of the next buffer. See CPYARG and
*-- the bss header.
ARGBUFSZ    equ   80

*-- MLI errno $47, "duplicate filename" (P8 TRM ch. 4 CREATE
*-- error table) -- cp.s's ERR_DUPFN, same value, same use.
ERR_DUPFN   equ   $47

PROMPTMSG   asc   "mv: overwrite? "
            dfb   0

            put   mvtop.s
            put   mvcopy.s
            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/hex.s
            put   ../liba/argv.s
*-- readdir.s + cptree.s: the recursive directory move (2026-08-
*-- 25). Both are CODE and both must be `put` BEFORE libabss.s,
*-- which opens liba's `dum` arena and must stay last -- sec
*-- 21's own gate fails any program that puts anything after it.
*-- cptree's storage therefore lives in libabss.s like every
*-- other liba module's; see the cptree section there.
            put   ../liba/readdir.s
            put   ../liba/readsyn.s
            put   ../liba/readsys.s
            put   ../liba/cptree.s
            put   ../liba/cptree2.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s
            put   ../liba/cptreebss.s

*---------------------------------------------------------------
* mv's bss -- `dum`/`dend` at the TEXTUAL END, past every
* emitted byte, anchored at LIBA_BSSEND rather than `*`
* (learning:01M0FNC75R7YSFRNS328WHXMHN). 807 bytes that were
* emitted zeros. The eight parmlists stay above as initialised
* data; their `da PATHBUF` / `da CBUF` fields resolve into this
* arena as forward references.
*
* The `ds`->`dum` sweep preserved this declaration order because
* SRCBUF's overflow ran into DSTBUF and the sweep was not
* allowed to change behaviour. FIXED 2026-08-22: CPYARG bounds
* both copies against ARGBUFSZ and refuses, so the order is no
* longer load-bearing -- and the threshold was 80, not "longer
* than 80", because STRCPY writes the terminator as well.
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21):
*  - SRCFD/DSTFD: each `sta`'d only after its own SC_OPEN
*    succeeded, and each reader sits past that store --
*    CLOSEBOTH is called only from :done/:wfail, both of which
*    are downstream of the DSTFD store, and the :closesrc
*    failure path never touches DSTFD at all.
*  - SRCDIR/DSTDIR: `sta`'d by SAMEDIR before its own compare.
*  - LSPOS: `ldy #0 / sty LSPOS` is LASTSLASH's SECOND
*    instruction, so the no-slash-anywhere path reads back a 0
*    that was stored, not one that was emitted.
*  - SRCBUF/DSTBUF: STRCPY'd from argv before SAMEDIR or the
*    error printer reads either.
*  - PATHBUF/PATHBUF2: MKPATH writes chars then the count
*    byte; the MLI reads only count+1.
*  - CBUF: filled by SC_READ, and WPARM_REQ is set from
*    RPARM_TRANS, so the write-back never reads past what this
*    call actually put there.
*  - LASTERR: only read at `:failed`, only reached after
*    COPYFILE/UNLINKSRC's own failure path just wrote it.
*---------------------------------------------------------------
            dum   CPT_BSSEND
SRCFD       ds    1
DSTFD       ds    1
SRCDIR      ds    1
DSTDIR      ds    1
DSLASHED    ds    1
DSTLEN      ds    1
LSPOS       ds    1
LASTERR     ds    1
*-- SSLASHED: `stz` is SRCSLASH's first instruction, and START
*-- calls SRCSLASH before anything reads it.
*-- SRCISDIRF: `stz` is SRCISDIR's first instruction, same
*-- shape, and every reader sits past that call.
SSLASHED    ds    1
SRCISDIRF   ds    1
*-- MERRFLG/MSRCIDX/IFLAG: initialized in START before use.
*-- PRINTED: `stz` is MOVEONE's first instruction.
MERRFLG     ds    1
MSRCIDX     ds    1
IFLAG       ds    1
PRINTED     ds    1

SRCBUF      ds    ARGBUFSZ
DSTBUF      ds    ARGBUFSZ
PATHBUF     ds    65
PATHBUF2    ds    65
CBUF        ds    BUFSZ

*---------------------------------------------------------------
* THE TEN MLI PARMLISTS. Cells, not emitted data -- INITPARMS
* (above) stores every constant field, and its header records
* why: the kernel writes RESULTS back into a parmlist, so an
* emitted one is writable text, and mv is TEXT_IMMUTABLE with a
* retained bank. Each list is CONTIGUOUS and must stay so.
*---------------------------------------------------------------
RNPARM      ds    1
RNPARM_PATH ds    2
RNPARM_NEW  ds    2

OPARM       ds    1
OPARM_PATH  ds    2
OPARM_IOBUF ds    2
OPARM_REF   ds    1

O2PARM      ds    1
O2PARM_PATH ds    2
O2PARM_IOBF ds    2
O2PARM_REF  ds    1

CRPARM      ds    1
CRPARM_PATH ds    2
CRPARM_ACC  ds    1
CRPARM_FTYP ds    1
CRPARM_AUX  ds    2
CRPARM_STYP ds    1
CRPARM_DATE ds    2
CRPARM_TIME ds    2

GFIPARM       ds    1
GFIPARM_PATH  ds    2
GFIPARM_ACC   ds    1
GFIPARM_FTYP  ds    1
GFIPARM_AUX   ds    2
GFIPARM_STYP  ds    1
GFIPARM_BLKS  ds    2
GFIPARM_MDATE ds    2
GFIPARM_MTIME ds    2
GFIPARM_CDATE ds    2
GFIPARM_CTIME ds    2

D2PARM      ds    1
D2PARM_PATH ds    2

RPARM       ds    1
RPARM_REF   ds    1
RPARM_BUF   ds    2
RPARM_REQ   ds    2
RPARM_TRANS ds    2

WPARM       ds    1
WPARM_REF   ds    1
WPARM_BUF   ds    2
WPARM_REQ   ds    2
WPARM_TRANS ds    2

CPARM       ds    1
CPARM_REF   ds    1

DPARM       ds    1
DPARM_PATH  ds    2
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end;
* -- $BF00 tops the process window. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */$BF00
            dend
