*---------------------------------------------------------------
* libabss.s -- liba's uninitialised storage, in ONE `dum` block
* at the textual end of whatever program links it
* (docs/STICKY.md sec 21).
*
* WHY IT IS A SEPARATE MODULE AND WHY IT IS PUT LAST. A `dum`
* block computes addresses from the real PC where it opens and
* `dend` restores that PC, so a block opened in the middle of a
* program is silently overlaid by everything emitted after it
* (learning:01M0FNC75R7YSFRNS328WHXMHN). liba modules are `put`
* in the middle of every program, so liba's storage cannot be
* declared where liba's code is. It has to be here, after every
* other `put`, which also makes this block's first byte exactly
* LOAD_BASE + the image length -- and that address is the whole
* mechanism sec 21 rests on (see THE ZEROED PAGE below).
*
* A program with storage of its own opens its block at
* LIBA_BSSEND, not at `*`: two blocks both anchored at `*` are
* the SAME BYTES.
*
* THE ZEROED PAGE. The kernel zeroes LIBA_ZPGLEN bytes at
* LOAD_BASE+imagelen in the child's bank at every spawn
* (src/kernel/bankcopy.s BC_ZPAGE, reached via BankCopyZ), with
* no metadata of any kind -- it already knows the load address
* and the image length. That region is exactly LIBA_ZPG..
* LIBA_ZPGEND-1 below, so **cells declared before LIBA_ZPGEND
* start at zero and cells after it do not.**
*
* ONLY READ-BEFORE-WRITE CELLS BELONG ABOVE LIBA_ZPGEND, and
* today that is one pair. Everything else in liba is written
* before it is read, which is what makes uncleared `dum` safe
* for it -- the same test FAT.md sec 13 applied to `sh`'s
* arenas, and the same test that kept VARNAMES/VARVALS in `ds`.
* A NEW cell that needs a zero start goes at the TOP of this
* block, not the bottom; scripts/check_purity.py fails the
* build if the zero-requiring group outgrows LIBA_ZPGLEN.
*
* Every cell here left EMITTED text to get here, which is the
* other half of sec 21: text is immutable by construction, and
* scripts/check_purity.py audits that claim.
*---------------------------------------------------------------

* -- MUST equal src/kernel/bankcopy.s's BC_ZPG_LEN. Two
* -- spellings of one number across a source boundary the
* -- toolchain cannot cross (userland cannot `put` a kernel
* -- module), so scripts/check_purity.py compares them.
LIBA_ZPGLEN equ   256

* -- stdio.s's buffer size. Declared HERE rather than in
* -- stdio.s because SIO_STAGE is the only thing that uses it
* -- and this module is `put` by manifests (src/test/
* -- testevtest.s) that link string.s/syscalls.s WITHOUT
* -- stdio.s -- a `ds BUFSIZ` here would be undefined for them.
BUFSIZ      equ   512

* -- readdir.s's directory-block buffer size, declared here for
* -- the same reason: RD_DIRBUF is the only thing that uses it,
* -- and a program that links libabss.s without readdir.s (most
* -- of them) must still be able to reserve the buffer. One
* -- ProDOS block; readdir.s's own RD_INITPARM stores it into
* -- RD_RPARM_REQ, so the number is spelled once.
* -- RD_BLKSZ moved to zp.equ 2026-08-29 (REL: ENT cannot
* -- export an equate; zp.equ is the universal home).

            dum   *
LIBA_ZPG
*---------------------------------------------------------------
* ZEROED BY THE KERNEL. Read before written; garbage here is
* not a wrong value, it is memory corruption.
*
* SIO_CNT_LO/HI -- the per-fd buffered-byte counts. SIO_FLUSH
* opens `lda SIO_CNT_LO,x / ora SIO_CNT_HI,x / bne :havework`
* with no prior write on any path, and SIO_PUTC builds its
* store address out of them the same way. EXIT calls
* SIO_FLUSHALL over all eight fds, so EVERY program reaches
* this read on its way out whether or not it ever buffered a
* byte -- which is why 16 bytes of zero is the whole
* zero-dependency of this system.
*
* SIO_ERR -- the per-fd STICKY WRITE ERROR (0 = none, else the
* errno of the first SC_WRITE that failed on that fd). Read
* before written on exactly the same path and for the same
* reason: EXIT's own error check sweeps all eight before
* SC_EXIT, so every program reads these eight bytes on the way
* out whether or not it ever wrote one. Garbage here would make
* a clean program exit nonzero at random, which is worse than a
* dropped byte -- it is a false report of a write failure.
*---------------------------------------------------------------
SIO_CNT_LO  ds    8
SIO_CNT_HI  ds    8
SIO_ERR     ds    8

* SIO_MODE -- the per-fd BUFFERING MODE (0 = not yet probed;
* SIOM_LINE = flush on CR; SIOM_FULL = flush at BUFSIZ).
* Read-before-write BY DESIGN: SIO_PUTC/PUTS test it on every
* buffered byte and probe the kernel (SYS_FDSTAT -- maux's
* isatty, docs/PERF-PLAN.md step 4) only when it is still 0.
* Garbage here is not a wrong value, it is a console that stops
* echoing per line or a stderr that reorders -- so it belongs
* in the kernel-zeroed page with the counts above.
SIO_MODE    ds    8

* SIO_STGOWN -- fd+1 of the fd that OWNS SIO_STAGE as its
* buffer (0 = unclaimed). Read by SIO_MODEOF's first probe of
* any fd, i.e. read-before-write on the same path as SIO_MODE
* above -- so it belongs in the zeroed page with it.
SIO_STGOWN  ds    1
LIBA_ZPGEND equ   LIBA_ZPG+LIBA_ZPGLEN

*---------------------------------------------------------------
* UNCLEARED FROM HERE. The first LIBA_ZPGEND-* bytes below
* happen to fall inside the kernel's page and so happen to
* start zeroed -- do not rely on it. Everything below is
* write-before-read; the trace is per group.
*
* stdio.s scratch: SIO_PUTC opens `sta SIO_BYTE / stx SIO_FD`,
* SIO_FLUSH opens `stx SIO_FLFD` and sets SIO_CPYLO/HI from
* SIO_CNT_* before SIO_CPY reads them, EXIT opens `sta
* SIO_EXITSTAT`.
*---------------------------------------------------------------
SIO_BYTE    ds    1
SIO_FD      ds    1
SIO_FLFD    ds    1
SIO_CPYLO   ds    1
SIO_CPYHI   ds    1
SIO_EXITSTAT ds   1
* -- SIO_MODEOF's SYS_FDSTAT parmlist: one fd byte, stored by
* -- SIO_MODEOF before its own $FF00 call (stdio.s carries the
* -- call itself rather than pulling syscallp.s's SC_FDSTAT
* -- into all ~36 stdio consumers' put lists).
SIO_FDPARM  ds    1
* -- SIO_PUTSB's chunk length (0 means 256): stored at the top
* -- of each outer pass before the copy loop compares against
* -- it. Write-before-read.
SIO_PBLEN   ds    1
* -- Per-fd buffer GEOMETRY, filled by SIO_MODEOF alongside the
* -- mode (every reader is gated on SIO_MODE,x != 0, so these
* -- are write-before-read): 16-bit buffer base (an LC fd's is
* -- page-aligned $Dx00; the stage owner's is SIO_STAGE, which
* -- is NOT aligned -- every base+count add is 16-bit for that
* -- reason) and the flush trigger in 256-byte pages (2 = the
* -- LC fds' 512, STGSIZE/256 for the owner).
SIO_BASELO  ds    8
SIO_BASEHI  ds    8
SIO_LIMHI   ds    8

* -- SIO_FLUSH's write parmlist. param_count is a NONZERO
* -- constant, so it is STORED by SIO_FLUSH rather than emitted
* -- (an MLI parmlist must be contiguous, so its one constant
* -- byte cannot stay behind in text). ref/buf/req are set from
* -- SIO_FLFD/SIO_CNT_* before every call; trans_count is
* -- written by the kernel's copyout and read only after a
* -- successful SC_WRITE.
SIO_WPARM   ds    1
SIO_WPARM_REF ds  1
SIO_WPARM_BUF ds  2
SIO_WPARM_REQ ds  2
SIO_WPRM_TRNS ds  2

* -- FCLOSE: `stx FCL_FD` first, param_count stored, ref_num
* -- set from FCL_FD before SC_CLOSE. FCL_WERR holds the fd's
* -- recorded write errno across the SC_CLOSE call (read out of
* -- SIO_ERR, and cleared there, BEFORE the close -- SC_CLOSE
* -- returns its own carry/A and there is nowhere else to keep
* -- the write error while it does).
* -- CREAT's (creat.s) parmlists: stored, not emitted, per the
* -- house parmlist rule; every field is written by CREAT before
* -- the call that reads it.
CR8_CPARM   ds    1
CR8_CPATH   ds    2
CR8_CACC    ds    1
CR8_CTYP    ds    1
CR8_CAUX    ds    2
CR8_CSTY    ds    1
CR8_CDAT    ds    2
CR8_CTIM    ds    2
CR8_OPARM   ds    1
CR8_OPATH   ds    2
CR8_OIOB    ds    2
CR8_OREF    ds    1
CR8_SPARM   ds    1
CR8_SREF    ds    1
CR8_SEOF    ds    3
CR8_KPARM   ds    1
CR8_KREF    ds    1
CR8_ERR     ds    1

FCL_FD      ds    1
FCL_PARM    ds    1
FCL_PARM_REF ds   1
FCL_WERR    ds    1

* -- PUTS's write parmlist: `stx PUTS_WPRM_REF` is PUTS's first
* -- instruction, buf/req are set from PTR0/STRLEN every call,
* -- param_count stored, trans_count never read at all.
PUTS_WPARM  ds    1
PUTS_WPRM_REF ds  1
PUTS_WPRM_BUF ds  2
PUTS_WPRM_REQ ds  2
PTS_WPRM_TRNS ds  2

* -- GETC's read parmlist and its one-byte target. GETC_BYTE is
* -- written by the MLI's own copyout before GETC reads it, and
* -- only when trans_count came back nonzero. buf/req USED to
* -- be emitted constants (`da GETC_BYTE` / `da 1`); GETC now
* -- stores them, like every other constant that had to leave
* -- text.
GETC_BYTE   ds    1
GETC_WPARM  ds    1
GETC_WPRM_REF ds  1
GETC_WPRM_BUF ds  2
GETC_WPRM_REQ ds  2
GTC_WPRM_TRNS ds  2

* -- string.s STRCMPI's one scratch byte: `sta SCI_B` then
* -- `cmp SCI_B`.
SCI_B       ds    1

* -- mli.s MKPATH's dot-path scratch. MKP_ADJ is written by
* -- `stz MKP_ADJ` as MKPATH's FIRST instruction, before
* -- anything reads it. MKP_GPARM is a CONTIGUOUS three-byte
* -- GET_PREFIX parmlist whose param_count is a nonzero
* -- constant, so -- like SIO_WPARM and FCL_PARM before it --
* -- it is STORED rather than emitted; MKP_PFX writes all
* -- three fields immediately before the call that reads them.
* -- Four bytes in every program that links mli.s, and zero
* -- bytes of text in any of them.
MKP_ADJ     ds    1
MKP_GPARM   ds    3

* -- syscalls.s's shared process-call parmlist. Every SC_*
* -- process wrapper fills the fields it uses before the call.
* -- EIGHT bytes since 2026-08-22: spawn() grew an envp
* -- argument (docs/SYSCALL.md item 13c), and SC_SPAWN writes
* -- all eight.
PROCPARM    ds    8

* -- SC_SPAWN's envp argument (syscallp.s). Write-before-read
* -- like PROCPARM itself and for the same reason: SC_SPAWN's
* -- contract is that every caller stores it -- zero for "no
* -- environment" -- immediately before the call, the same way
* -- it stores PTR0-PTR2. It is deliberately NOT in the zeroed
* -- page above: a cell that starts at zero would make a
* -- FORGOTTEN store look correct on the first spawn of a run
* -- and hand the child a previous spawn's environment on the
* -- second, which is the worst of both.
SPWN_ENVP   ds    2

* -- env.s's GETENV cursor, both written before read on every
* -- call: GETENV opens `sta GENV_CNT` (from the envc byte it
* -- just read) and `sty GENV_OFF` (the offset of envp[0]),
* -- before the search loop reads either back.
GENV_CNT    ds    1
GENV_OFF    ds    1

* -- pathres.s's PATHRSLV scratch. PRS_BUFSZ now lives in
* -- inc/zp.equ -- pathres.s is put BEFORE this file and
* -- referenced it, which real Merlin-8 rejects as a forward
* -- reference. Its rationale moved with it.
* -- All are write-before-read within one PATHRSLV call.
PRS_WORD    ds    2
PRS_SRC     ds    2
PRS_SI      ds    1
PRS_MORE    ds    1
PRS_BUF     ds    PRS_BUFSZ
PRS_PATHBUF ds    PRS_BUFSZ
*-- MLI parmlists as CELLS: the MLI writes a refnum back into
*-- an OPEN parmlist, and emitted ones in a liba module are
*-- writable text every linker inherits. PRS_EXISTS fills
*-- both before use.
PRS_NM      ds    5          ;"PATH", built at runtime
PTB_SRCBUF  ds    PTB_SRCSZ  ;PATHTAB, copied in --
                            ;shared by sh.s and
                            ;pathres.s, which never
                            ;run in the same image
PRS_OPARM   ds    6
PRS_CPARM   ds    2

* -- stdio.s's flush staging buffer. SIO_CPY writes exactly the
* -- byte count SC_WRITE is then asked for, so no byte is ever
* -- read that this run did not write. 512 bytes that used to
* -- be 512 zeros in EVERY binary in the tree.
* -- SPLIT LABEL, byte-identical (a label emits nothing): the
* -- upper half gets its own name because stdio.s addresses it
* -- as #<SIO_STAGE+BUFSIZ / #>..., and under REL a hi-byte
* -- external tolerates an offset of at most 7 -- the tree's
* -- ONLY two restricted-form sites (S9-PLAN sec 6 L1 audit,
* -- learning:01M15S5BTYRKFM1FNC7YJRBS7H fact 3). Full 16-bit
* -- external refs take arbitrary offsets (probed +$23, links
* -- exact), so no other cell needs this.
SIO_STAGE   ds    BUFSIZ
SIO_STGB2   ds    STGSIZE-BUFSIZ

*---------------------------------------------------------------
* THE SIX MODULES SEC 24 LEFT BEHIND (docs/STICKY.md sec 25).
* Sec 24's widened audit found 42 more emitted-and-written cells
* in the six liba modules `cat` does not link, and recorded them
* in check_purity.LIBA_DEBT rather than converting them. They
* are converted here. Every one was traced read-vs-write the
* same way sec 24 traced SIO_CNT_LO/HI, and NOT ONE of the 42
* qualified for the zeroed page: the group above is still the
* whole zero-dependency of this system. The traces are per
* group below, because a claim nobody can re-check is not a
* trace.
*
* Three constants had to become runtime STORES to get here (an
* MLI parmlist must be contiguous, so a parmlist that is mostly
* scratch cannot leave its constant bytes behind in text --
* sec 24's own SIO_WPARM/FCL_PARM precedent): readdir.s's
* OPENDIR stores its three param_counts, RD_RPARM's buffer
* address and request count and RD_OPARM's zero io_buffer;
* seek.s's LSEEK stores SEEK_PARM's param_count.
*---------------------------------------------------------------

* -- getopt.s's option-scan cursor, plus its option-argument
* -- pointer. OPTINIT writes all four in the same breath (`sta
* -- OPTIND / stz OPTPOS / stz OPTOPT / stz OPTARG / stz
* -- OPTARG+1`) and is called before the first GETOPT by all 13
* -- callers -- checked one by one, the documented `jsr OPTINIT`
* -- / `:optlp jsr GETOPT` idiom in this module's header, never
* -- split up. OPTARG itself is then only ever WRITTEN by GETOPT
* -- (on an argument-taking letter, attached or separated form)
* -- and only ever READ by the caller, right after such a
* -- GETOPT -- so it is write-before-read the same way the three
* -- older cells are, just with GETOPT as the writer instead of
* -- OPTINIT alone.
OPTIND      ds    1
OPTPOS      ds    1
OPTOPT      ds    1
OPTARG      ds    2

* -- glob.s's matcher state, all of it per-call scratch:
* -- GLOBMATCH opens `stz GPI / stz GNI / lda #$FF / sta GSPI /
* -- sta GSNI`, and GTMP/GNEG/GHIT/GCH/GLO/GHI are each stored
* -- by the class scan immediately before that same scan reads
* -- them back. HASMETA touches none of them.
GPI         ds    1
GNI         ds    1
GSPI        ds    1
GSNI        ds    1
GTMP        ds    1
GNEG        ds    1
GHIT        ds    1
GCH         ds    1
GLO         ds    1
GHI         ds    1

* -- hex.s's fd holders: PRHEX8 opens `stx PRHEX8_FD`, PRHEX16
* -- opens `stx PRHEX16_FD / sty PRHEX16_LO`.
PRHEX8_FD   ds    1
PRHEX16_FD  ds    1
PRHEX16_LO  ds    1

* -- num.s: PRNUM opens `stx PRNUM_FD`, and PRNBUF is filled
* -- through PTR1 by U2DEC -- which always emits at least the
* -- units digit and ALWAYS writes the NUL terminator -- before
* -- PUTS reads it back through PTR0.
PRNUM_FD    ds    1
PRNBUF      ds    8

* -- seek.s. LSEEK opens `sta LSK_FD`, then stores SEEK_PARM's
* -- param_count and sets SEEK_PARM_REF from LSK_FD before every
* -- call. SEEK_PARM_VAL is written before it is read on all
* -- three paths: SEEK_SET copies the caller's 3 bytes into it,
* -- and SEEK_CUR/SEEK_END take it from the kernel's own
* -- copyback (PRC_GETMARK/PRC_GETEOF BankCopy offsets 2..4,
* -- src/kernel/procfile3.s) before LSK_ADD_OFF adds to it.
LSK_FD      ds    1
SEEK_PARM   ds    1
SEEK_PARM_REF ds  1
SEEK_PARM_VAL ds  3

* -- readdir.s's directory cursor. OPENDIR writes every cell in
* -- this group before READDIR/CLOSEDIR read any of them
* -- (ENTLEN/EPB/FCNT out of the key block, CURSOR/BENT/ACNT/
* -- DONEFLAG/DONEERR from constants), and the module's calling
* -- convention -- one OPENDIR live at a time, CLOSEDIR only
* -- after a SUCCESSFUL OPENDIR -- is what makes that ordering
* -- total rather than usual. NAMLEN/CHARIDX/CASELO/CASEHI are
* -- per-entry scratch READDIR stores before reading.
RD_DFD      ds    1
RD_ENTLEN   ds    1
RD_EPB      ds    1
RD_FCNT     ds    2
RD_ACNT     ds    2
RD_BENT     ds    1
RD_CURSOR   ds    2
RD_NAMLEN   ds    1
RD_CHARIDX  ds    1
RD_CASELO   ds    1
RD_CASEHI   ds    1
RD_DONEFLAG ds    1
RD_DONEERR  ds    1

* -- readdir.s's three MLI parmlists, each CONTIGUOUS. OPENDIR
* -- stores every constant field (see this block's header) and
* -- patches path/ref before each call; the ref_num and
* -- trans_count RESULT fields are written by the kernel's own
* -- copyback before anything reads them.
RD_OPARM    ds    1
RD_OPARM_PATH ds  2
RD_OPARM_IOB ds   2
RD_OPARM_REF ds   1

RD_RPARM    ds    1
RD_RPARM_REF ds   1
RD_RPARM_BUF ds   2
RD_RPARM_REQ ds   2
RD_RPARM_TR ds    1
* -- RD_RPARM_TR2: a REAL label, not `RD_RPARM_TR+1`
* -- arithmetic -- nas and merlin32 evaluate `<`/`>` of a
* -- label-plus-constant expression DIFFERENTLY (found the
* -- hard way, check-nas-librel, docs/DEVFS.md 2026-09-30: a
* -- 1-byte mismatch in LS/SH at the analogous `#<RD_DIRBUF+16`
* -- sites, fixed the same way by the RD_ONBUF label below). A
* -- bare label needs no such arithmetic.
RD_RPARM_TR2 ds   1

RD_CPARM    ds    1
RD_CPARM_REF ds   1

* -- readdir.s's directory block buffer, and the single biggest
* -- item in this file after SIO_STAGE: 512 bytes of emitted
* -- zeros in ls/du/find/df until now. The kernel's copyout
* -- fills all 512 before OPENDIR reads the key-block header out
* -- of it, and a ProDOS directory's EOF is always a whole
* -- number of 512-byte blocks, so no READ this module issues
* -- can come back short and leave a stale tail in view.
RD_DIRBUF   ds    16
* -- RD_ONBUF: a REAL label 16 bytes into RD_DIRBUF's own
* -- 512, not `RD_DIRBUF+16` arithmetic -- see RD_RPARM_TR2's
* -- comment above for why. Splitting the `ds` into labeled
* -- pieces changes no address and no byte count (16 +
* -- (RD_BLKSZ-16) = RD_BLKSZ).
RD_ONBUF    ds    RD_BLKSZ-16

* -- The SYNTHETIC-mode state (readsyn.s, split out of readdir.s
* -- 2026-10-17; docs/DEVFS.md, 2026-09-30) adds ZERO new bytes
* -- here: every synthetic-mode field readsyn.s needs is one of
* -- the real-mode cells ABOVE, referenced by its OWN real name
* -- directly from readsyn.s. Its two siblings share them:
* -- readsys.s (SC_DEVLIST writes RD_RPARM_REQ; mount and umount
* -- put it without readsyn.s, so it is an arena user in its own
* -- right) and, since KFIX9, SYN_OPEN's SYS_VROOT op 5 parm
* -- ({5, path}) is built in RD_RPARM+0..2 --
* -- NOT via a same-file `equ` alias. Two things were tried and
* -- both failed:
* --
* -- (1) plain new `ds` cells (46 bytes) grew LIBA_BSSEND by 46
* -- (a `dum` block still advances the symbolic PC that later
* -- labels inherit, even with no OUTPUT bytes) and broke
* -- src/bin/as.s's `err */SYMADR` ceiling; a single extra `ds`
* -- byte STILL broke src/bin/sh.s's byte-exact segment-layout
* -- asserts (check-modules) -- as.s and sh.s both `put` this
* -- file but not readdir.s, so EITHER paid for scratch only
* -- the directory modules use.
* --
* -- (2) `equ`-aliasing a new name onto a real cell HERE (e.g.
* -- `RD_SYNMODE equ RD_DFD`) achieves the zero-byte goal but
* -- broke `check-librel`/nas-librel-image instead: an EQUATE
* -- cannot be exported across the REL linker (same rule as
* -- inc/tty.equ's own comment on this), so a name defined as
* -- an equate in libabss.s's own module is invisible to
* -- readsyn.s's SEPARATE REL module -- caught only by the box
* -- sweep, not any Mac-side gate. Fixed by deleting the alias
* -- names and having readsyn.s reference the REAL cross-
* -- module-safe names (RD_DFD, RD_ENTLEN, RD_EPB, RD_FCNT,
* -- RD_DIRBUF, RD_ONBUF, RD_RPARM, RD_RPARM_REQ, RD_RPARM_TR,
* -- RD_RPARM_TR2, RD_CPARM, RD_CPARM_REF) directly, the same
* -- way any OTHER cross-module consumer of this file's real
* -- ds-declared cells already must.
* --
* -- The dispatch safety argument still holds with the real
* -- name: RD_DFD is 0/1-8 for a real fd (bit 7 clear) and
* -- RD_SYN_ROOT/DEV/MNT (readsyn.s) are $80/$81/$82 (bit 7
* -- set), so the dispatch is one `bpl`/`bmi`, never an `=0`
* -- test -- READDIR/CLOSEDIR's per-call check and the real
* -- OPENDIR path's own fd-store are reading/writing the SAME
* -- byte, by construction, not by alias.
LIBA_BSSEND
            dend
