*---------------------------------------------------------------
* ld.s -- maux's OWN two-pass REL linker (S9, the ld rewrite).
*
* Usage: nld [-a addr] [-z] [-o out] module...
*
* This replaces src/bin/ld.s, which is not a linker at all but
* a linking LOADER: it embeds Merlin's LINKER.S and emulates the
* MLI calls that core makes. See docs/LD-NATIVE.md
* for why that is being retired and docs/REL-FORMAT.md for the
* object format, which is measured rather than guessed.
*
* BUILT AS A SEPARATE BINARY ON PURPOSE. check-librelas links 34
* utils with build/ld.bin, so an `ld` that half-works stops the
* whole tree. This becomes ld.s only once check-ld and
* check-librelas are green on it.
*
* THE ALGORITHM is scripts/relink.py's, with pass 2 STREAMED:
*
*   PASS 1  for each module in order: read its code length from
*           the directory entry (the AUX TYPE *is* the code
*           length), assign it a base, advance, then read the
*           symbol list and record every ENT at
*           base + (addr - $8000).
*   PASS 2  for each module: read its dictionary tail once,
*           resolve its EXTs from the table, then STREAM its
*           code through a 2 KB chunk buffer -- every fixup
*           applied as its offset passes -- straight to the
*           output file (ldstream.s). The image is never built
*           in memory: a 64 KB machine cannot hold a big object
*           and the output is serial anyway, so across the link
*           only the symbol table is resident.
*
* MEMORY. Carrying no Merlin core, this file is a few KB rather
* than twenty, and nothing here is a SACRIFICIAL region -- the
* symbol table has its own span and eats nobody's code, which is
* the trap ld.s's layout lives with (docs/S9-PLAN.md L4 item 2).
* There is NO build area (2026-09-13): the -l pools and the
* chunk buffer sit at the top of the bank, and the freed 26 KB
* went to the symbol pool.
*---------------------------------------------------------------
            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/ld.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/readdir.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

*-- limits. Each is MEASURED against the tree, not chosen: the
*-- largest fixup+symbol tail in 183 objects is MVMR's 2,323 B,
*-- and the largest module count on a sweep link line is 13.
MODMAX      equ   96           ;modules per link -- explicit
                               ;operands plus -l members (vi's
                               ;streamed link is 59: 35 pieces
                               ;+ 18 liba + 5 bss + main)
MODPLCAP    equ   1536         ;module path pool (kernel link
                               ;measured ~850 B of paths)
LIBDMAX     equ   4            ;-L search directories
LIBRMAX     equ   4            ;-l requests
*-- LIBPLCAP must be a page multiple >=256: the overflow check
*-- is `cmp #>LIBPLCAP`, and >128 is ZERO -- every -l/-L
*-- registration refused, LDOUT3/4 wrote nothing (2026-09-01).
LIBPLCAP    equ   256          ;-L/-l string pool
*-- The three -l resolution pools live in the BUILD AREA, not
*-- the arena (see the equates under BUILDBASE): the kernel's
*-- closure measured 2,294 B of undefined names against the old
*-- 1,024 cap, and every arena byte comes out of the build
*-- window, which MAUXEXPR already needs 23,210 B of.
*-- 6144, was 4096 (2026-10-10, docs/VROOT-NOTES.md): the
*-- playtest kernel link needed 4,098 B and ADDUNDEF's full
*-- path exited 1 with NO message. It says "too many symbols"
*-- now.
UNDPLCAP    equ   6144         ;undefined-symbol pool
MEMPLCAP    equ   768          ;one library's member names
                               ;(34 kernel members = 296 B)
TAKEPLCAP   equ   768          ;names -l took, in take order
TAILCAP     equ   3584         ;fixup+symbol tail buffer
*-- the symbol pool: [len][name][addr] entries, no index array.
*-- 16 KB now that there is no build area to pay for: the
*-- kernel link defines 355 symbols = 4,795 B, sh's 30-piece
*-- link overran the old 5,632 (`ld: too many symbols`,
*-- 2026-09-13). The `err` guard at the arena's end keeps the
*-- pool under the -l pools, not this comment.
SYMNMCAP    equ   16384        ;packed symbol pool
*-- EXTMAX is 256 BY CONSTRUCTION, not by measurement: a fixup's
*-- refnum is a byte indexed straight into EXTTAB_L/H with no
*-- guard, so only the full 8-bit space keeps a large refnum
*-- from silently indexing across the halves.
EXTMAX      equ   256          ;refnums in one module
*-- `ld @FILE` (ldargf.s): the file's words, strings in the
*-- arena, pointers over ARGV (255 B for argv+envp, <= 127)
ARGFCAP     equ   1024         ;argument file buffer
ARGFLIM     equ   1023         ;bytes read; full = refused
ARGFMAXW    equ   100          ;argv slots, incl. argv[0]
ARGF_AT     equ   $C0          ;a high-bit '@'
ARGF_WORD   equ   $A1          ;> a blank, high-bit
NAMEMASK    equ   $3F          ;symbol record: len is 6 bits
FLAG_ENT    equ   $40
FLAG_EXT    equ   $80

*-- THE TOP OF THE BANK. $BD00 is the ceiling ld may use (the
*-- old build area proved the bank writable up there). From the
*-- top down: the 2 KB code CHUNK pass 2 streams through (plus
*-- one carried byte -- ldstream.s), then the three -l
*-- resolution pools, live only during LIBRESOLVE. Everything
*-- else -- the arena, the symbol pool, the tail buffer -- lives
*-- below POOLBASE, and the `err */POOLBASE` guard at the
*-- arena's
*-- end is what keeps them apart.
MEMTOP      equ   $BD00
CODECHUNK   equ   2048         ;bytes of code streamed per read
*-- CODEBUF = $B400; the read lands at CODEBUF+1 when a byte
*-- is carried over, so 256 B of slack sits above the chunk
CODEBUF     equ   MEMTOP-CODECHUNK-256
TAKEPOOL    equ   CODEBUF-TAKEPLCAP
MEMPOOL     equ   TAKEPOOL-MEMPLCAP
UNDEFPOOL   equ   MEMPOOL-UNDPLCAP
POOLBASE    equ   UNDEFPOOL
            err   CODEBUF+CODECHUNK+1/MEMTOP

*-- nld's own ZP window, $30 up (nm.s/ed.s/sort.s precedent)
ND_PTR      equ   $30   ;2  general walk cursor
ND_END      equ   $32   ;2  walk limit
ND_TMP      equ   $34   ;2  scratch
ND_BASE     equ   $36   ;2  current module's link base
ND_TGT      equ   $38   ;2  resolved fixup target
ND_CODE     equ   $3A   ;2  current module's code length
ND_DST      equ   $3C   ;2  build-area write cursor
ND_I        equ   $3E   ;2  loop index
ND_NAME     equ   $40   ;2  symbol name pointer
ND_LEN      equ   $42   ;1  symbol name length
ND_FLAG     equ   $44   ;1  symbol record flag
ND_ADDR     equ   $46   ;2  symbol record address field
ND_OFF      equ   $48   ;2  fixup code offset
ND_KIND     equ   $4A   ;1  fixup kind byte
ND_B3       equ   $4C   ;1  fixup byte3
ND_PTR2     equ   $50   ;2  symbol-pool walk cursor
ND_PTR3     equ   $52   ;2  member-pool walk cursor
ND_TMP2     equ   $54   ;2  library pool scratch
MODNAMEP    equ   $56   ;2  OPENMOD's saved module-name
                       ;   pointer (2026-09-25, -L module
                       ;   resolution) -- MUST be ZP: MODCOMPOSE
                       ;   (ldscan.s) uses (MODNAMEP),y
FIXADR      equ   $4E   ;2  patch site -- MUST be ZP: the
                       ;   fixup writer uses (FIXADR),y

            put   ldpass.s
            put   ldsym.s
            put   ldpass2.s
            put   ldstream.s
            put   ldzout.s
            put   ldout.s
            put   ldlib.s
            put   ldscan.s
            put   ldargf.s
            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/seek.s
            put   ../liba/argv.s
            put   ../liba/readdir.s
            put   ../liba/readsyn.s
            put   ../liba/readsys.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* nld's arena -- `dum`/`dend` at the TEXTUAL END, chained onto
* LIBA_BSSEND, the house idiom (make.s's own precedent). It has
* to sit HERE and not in a file of its own: LIBA_BSSEND does not
* exist until libabss.s has been assembled, and check-modules
* refuses anything that is not a liba module `put` after it.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
ZFLAG       ds    1
OFLAG       ds    1
ERRFLAG     ds    1
ARGI        ds    1
NMODS       ds    1
MODFD       ds    1
OUTFD       ds    1
LNKADDR     ds    2
NEXTADR     ds    2
OBJPTR      ds    2
TAILLEN     ds    2
SEEKPOS     ds    3
NAMEUSED    ds    2
PATHBUF     ds    64
MODOFF_L    ds    MODMAX
MODOFF_H    ds    MODMAX
MODPOOL     ds    MODPLCAP
MODUSED     ds    2
OUTTYPE     ds    1
HEXVAL      ds    2
SEEDPHASE   ds    1
NAMEBUF     ds    16
NLIBD       ds    1
NLIBR       ds    1
LIBI        ds    1
LIBD        ds    1
LIBCHG      ds    1
MEMLEN      ds    1
LIBUSED     ds    2
UNDUSED     ds    2
MEMUSED     ds    2
TAKEUSED    ds    2
INSAT       ds    1
SPLCNT      ds    1
LIBDOF_L    ds    LIBDMAX
LIBDOF_H    ds    LIBDMAX
LIBROF_L    ds    LIBRMAX
LIBROF_H    ds    LIBRMAX
LIBPOS      ds    LIBRMAX
LIBPOOL     ds    LIBPLCAP
*-- LIBDBUF's cap grew 72->128 (2026-09-25, -L module
*-- resolution): shared now with MODCOMPOSE (ldscan.s), whose
*-- worst case is COMPOSEDIR's own 48-char dir + "/" + a module
*-- name up to ADDMOD's 64-char pool cap + NUL = 114. Inside
*-- this file's own dum/dend BSS arena -- no file-size cost.
LIBDBUF     ds    128
MEMBUF      ds    80
LIBPATH     ds    80
RDREC       ds    RD_SIZE
MODBASE_L   ds    MODMAX
MODBASE_H   ds    MODMAX
*-- -s: THE SEGMENT RUN. A module's base is a LINKER policy,
*-- not a property of the $F8 object (every address in a REL
*-- module is $8000-based and every reference to it is a
*-- fixup), so "one image base" was only ever what PASS1 was
*-- written to do. -s adr says: base the modules that follow
*-- at adr while the FILE keeps growing sequentially, and -s 0
*-- resumes. sh's $E000 language-card code segment is the one
*-- caller (docs/SH-SUBSET.md 7.6); its bytes ride in the flat
*-- image above the low window and SEG_INIT copies them up.
*-- TWO runs (docs/LOOP-S1.md: the play kernel carries the cold
*-- segment at $D400 AND the low segment at $1300, each its own
*-- base): each run has a cursor, a module records which
*-- run it was named in. A THIRD nonzero -s is a usage error,
*-- because a base nobody keeps a cursor for would mis-link in
*-- silence.
SEGADR      ds    2            ;-s base (0 = never given)
SEGCUR      ds    2            ;running base inside the run
SEGADR2     ds    2            ;the SECOND -s base (0 = none)
SEGCUR2     ds    2            ;running base inside run 2
SEGON       ds    1            ;run number while -s is on
SEGFLG      ds    MODMAX       ;per module: 0 flat, 1 or 2 = run
EXTTAB_L    ds    EXTMAX
EXTTAB_H    ds    EXTMAX
*-- the streaming writer's state (ldstream.s)
MODPOS      ds    2            ;module offset of CODEBUF[0]
HAVE        ds    2            ;bytes held in CODEBUF
KEEP        ds    1            ;1 = hold the last byte back
FIXPEND     ds    1            ;a decoded fixup is pending
FIXEND      ds    1            ;the fixup list is exhausted
LASTOFF     ds    2            ;ordering guard
ZRUN        ds    2            ;-z: pending trailing zeros
MODNZ       ds    1            ;this module emitted a nonzero
OUTOPEN     ds    1
ZEROS       ds    256          ;FLUSHZ's source (START clears)
ARGFBUF     ds    ARGFCAP      ;`ld @FILE` words (ldargf.s)
NAMEPOOL    ds    SYMNMCAP
TAILBUF     ds    TAILCAP
NLD_BSSEND
*-- The arena must end BELOW the -l pools and the chunk buffer,
*-- or the linker overwrites its own symbol table. `*/POOLBASE`
*-- is the house idiom (ld.s's own `err */$BE00`): integer
*-- division stays 0 while * is below the address and goes
*-- nonzero the moment it reaches it. `err *-POOLBASE` was the
*-- first attempt and is WRONG -- `err` fires on any nonzero
*-- value, so a subtraction fires when the arena is comfortably
*-- UNDER the limit too.
            err   */POOLBASE
            dend
