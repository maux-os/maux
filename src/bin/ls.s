*---------------------------------------------------------------
* ls.s -- list files and directories.
*
* Usage: ls [-lC1trdFsR] [path ...]
*
* CONTRACT (pinned; -t/-r added 2026-09-01, FLEET F.2 tier 1 --
* "ls -lt is THE idiom for what changed"):
*  Options, if present, occupy argv[1] ONLY, as one clustered
*  word: "-l", "-lt", "-lFR". Only argv[1] is ever scanned for
*  a RECOGNISED option: leading-word parsing (V6 ls's own
*  shape), not POSIX getopt(3) (which keeps scanning past the
*  first operand) and not BSD's after-operand scanning either.
*  The old "exactly -l, no clustering" rule fell WITH ITS
*  REASON -- one flag slot meant nothing to cluster; three
*  flags make "-lt" the thing every hand types. A letter
*  outside lC1trdFsR, or a lone "-", is still :badopt.
*
*  -t sorts NEWEST FIRST -- directory entries and path operands
*  both (OPTKEYS stats every operand before SORTPATHS, so `ls
*  -t A B C` orders the operand lines too, which is what a
*  glob expands to). Chronology is a 5-byte key built from
*  mod_date/mod_time with the year PIVOT-ADJUSTED (BLDKEY's
*  header); equal instants fall back to the name order, a zero
*  date sorts oldest, and an unstattable operand keys as zero
*  (pass 1 still prints its error). -r reverses the final
*  order, -t's or the name's, ties untouched.
*  -d prints a directory argument as an entry rather than
*  deferring it to pass 2. -F appends '/' only to directory
*  names. -s prefixes ProDOS blocks_used. -R prints a header
*  for each root, then walks descendants depth-first in sorted
*  order through lsrec.s's bounded, loud worklist.
*
*  ONE RULE, NO EXCEPTIONS: every argument in the path list
*  (argv[PATHSTART..]) that begins with "-" -- "-l" included --
*  is an unknown option there: usage to stderr, exit 2, with
*  NOTHING printed first. Checked in a validation pass over the
*  whole operand list before pass 1 does any work, so a bad
*  flag discovered after a good path cannot leave partial
*  output behind (the same all-or-nothing shape argv[1]'s own
*  check already has). An earlier draft of this fix carved out
*  an exact "-l" past argv[1] as a silent pass-through operand,
*  matching a since-corrected corpus fixture -- reverted: the
*  fixture was evidence about behaviour, not a specification of
*  it (docs/E2E.md sec 1's own ruling, the same shape as
*  `check-fleet` staging lines that could never trigger `sort
*  -u`'s bug), and a corpus built so this exact defect shape
*  cannot recur is worthless as a check of the fix it exists to
*  prove. `ls FILE -l` therefore now errors instead of silently
*  reporting "-l: cannot access" -- the same class of bug this
*  whole fix targets, just spelled with the recognised letter.
*
*  No "--": nothing past argv[1] ever treats a flag as valid,
*  so there is no dash-prefixed pathname to rescue by ending
*  option scanning early. Not adding it is the smaller change,
*  and V6 ls had no such convention to begin with.
*
*  A lone "-" is an error too, same as any other dash argument
*  -- not an operand. src/liba/getopt.s's house convention
*  (bare "-" is an operand, preserving "read stdin") does not
*  transfer: ls never reads stdin, so the convention's own
*  reason to exist is absent, and one uniform rule ("does this
*  argument begin with -?") beats a stdin-flavoured exception
*  with nothing here to serve it. This also matches argv[1]'s
*  existing behaviour, unchanged by this fix: "ls -" already
*  hit :badopt before today.
*
*  No paths: list the current directory, obtained the same way
*  pwd.s does (SC_GETPFX) -- GET_PREFIX's length-prefixed, raw-
*  ASCII answer is ALREADY the MLI pathname shape MKPATH would
*  otherwise build, so it is fed to OPEN directly, no
*  conversion. An empty prefix (GET_PREFIX's count byte is 0) is
*  reported as "ls: no current directory", exit 1 -- should not
*  happen in practice.
*
*  Each path argument is STATTED with GET_FILE_INFO ($C4, SC_GFI
*  -- inc/mli.equ's PCOUNT_GFI shape: pathname, access,
*  file_type, aux_type, storage_type, blocks_used, mod_date,
*  mod_time, create_date, create_time). storage_type $0D
*  (subdirectory) or $0F (volume directory) means "list its
*  contents"; anything else means "print this file's own line".
*  A GFI failure prints "ls: <path>: cannot access" to stderr,
*  continues with the remaining arguments, and forces exit 1.
*
*  Grouping (classic ls): every file argument's line prints
*  FIRST, in argument order, THEN every directory's listing.
*  Multiple path arguments with at least one directory print
*  "<path>:" before each directory's listing, with a blank line
*  BETWEEN directory listings (not before the first, not after
*  the last). A single argument (or the no-args cwd case) prints
*  no header, -R INCLUDED: this file used to say "recursive
*  roots are named" and lstop.s forced the header whenever
*  RECFLAG was set, which is not what -R means. BSD `ls -R D`
*  prints D's CONTENTS first and then names each subdirectory
*  it descends into ("D/SUB:"), never D itself; the root is
*  named only when the ordinary multiple-argument rule above
*  already names it. Fixed 2026-09-19 -- the -R landing was
*  gated by check-posixutil's host oracle, which caught it
*  (expected ['SUB','','D/SUB:'], got ['D:','SUB','',...]),
*  and nothing else asserted the shape. PRRHEAD (lsrec.s)
*  prints the descended headers, each with its leading blank.
*
*  Directory listing: the walk itself -- OPEN as a file, READ
*  raw 512-byte blocks, walk 39-byte entries per the ProDOS 8
*  TRM Appendix B.2.4/B.2.5 algorithm (entry_length/entries_
*  per_block read from the key block's header, inactive entries
*  -- a zero storage_type/name_length byte -- skipped without
*  counting) -- now lives in src/liba/readdir.s's OPENDIR/
*  READDIR/CLOSEDIR, the SECOND-consumer extraction docs/
*  FLEET.md's readdir ruling called for (find.s is the second
*  consumer). ls's own job is just collecting READDIR's records
*  into memory FIRST (ENTRIES, 128 x 32 bytes), sorting them
*  ascending by name -- STRCMPI, a case-INSENSITIVE compare
*  (see string.s's own header: readdir hands back a case-
*  DECODED name now, so a plain byte compare on the old always-
*  uppercase-stored bytes is no longer available "for free" the
*  way it used to be) -- with an insertion sort over an INDEX
*  (lssort.s SORTENTRIES; the records never move), then
*  printing -- in COLUMNS, down then across, when stdout is a
*  console (4.2BSD -C; -1 forces one per line, -C forces columns
*  to a file), one per line otherwise. A directory whose
*  file_count exceeds 128 lists
*  only the first 128 and prints "ls: <path>: truncated at 128
*  entries" to stderr (no silent caps -- house rule), forcing
*  exit 1.
*
*  GS/OS case bitflags (ProDOS 2.5, GS/OS TN #8): version/
*  min_version at entry offset $1C/$1D are one 16-bit word; bit
*  15 set means the word carries per-character lowercase flags
*  (character n, 1-based, reads bit 15-n); the name FIELD stays
*  stored uppercase. This decode now runs ONCE, inside READDIR
*  itself (readdir.s's own ruling: the name is returned already
*  display-ready) -- ls.s no longer touches the raw case word at
*  all.
*
*  Short output: one name per line (case-decoded), to stdout.
*
*  Long output (-l), fixed columns:
*    TTT SSSSSSSS YYYY-MM-DD HH:MM NAME
*  TTT: $04 TXT, $06 BIN, $0F DIR, $FF SYS, $FC BAS, else "$xx"
*  hex -- always exactly 3 characters, so this column never
*  pads.
*  SSSSSSSS: for a DIRECTORY ENTRY, its real EOF in decimal
*  bytes, right-aligned width 8 (EOF is a 3-byte field --
*  16,777,215 is 8 digits, hence the width). For a path ARGUMENT
*  (the GFI case), GET_FILE_INFO returns blocks_used, not EOF --
*  printing blocks_used*512 as if it were EOF would be WRONG, so
*  this instead prints blocks_used followed by "b", right-
*  aligned width 8 (e.g. "     12b"). Two different numbers,
*  both legitimately in this column depending on which call
*  produced the row -- documented here, not silently conflated.
*  Date: mod_date/mod_time, decoded per docs/PRODOS-VERSION.md's
*  standing rulings -- legacy iff hour<=23 AND minute<=59 (else
*  Extended/invalid), legacy year pivots at 78 (78..99 ->
*  1978..1999, 0..77 -> 2000..2077). A zero date word, or a
*  failed validity check, prints "-" padded to the 16-char date
*  field. TIME word layout confirmed against the ProDOS 8 TRM
*  (street-library artifact d82965d8...f13a335c258273dcb0171-
*  fa692ff8, "TIME: | hour | | minute |", hour at the HIGHER
*  address i.e. the high byte, minute at the lower/low byte) --
*  same layout docs/PRODOS-VERSION.md's own prose already
*  described; nothing new to deposit.
*  NAME: the decoded entry name for directory entries, or the
*  argument's own path text for a file argument (GFI returns no
*  name at all -- there is nothing else to print).
*
*  Exit 0 if every argument was accessible (and no directory was
*  truncated); 1 if any GFI/open/read failed or any directory
*  was truncated; 2 on a usage error.
*
* Uses ONLY liba (src/liba) -- no direct syscalls, no raw gate
* address, no raw call-number equates (SC_GFI wraps SYS_GFI --
* see src/liba/syscalls.s).
*---------------------------------------------------------------

            lst   off
            xc
*-- HOW MANY DIRECTORY ENTRIES ls CAN HOLD. It reads a whole
*-- directory into ENTRIES before sorting, so this is a real
*-- cap and not a buffer size -- past it ls lists the first
*-- LS_MAXENT and says so on stderr.
*-- RAISED 128 -> 255 on 2026-09-20: the operator hit it just
*-- by running `ls` on the manual directory, which is 149 pages
*-- and growing. 255 is the ceiling for THIS shape, not an
*-- arbitrary pick -- ENTRYCOUNT is one byte and ENTIDX holds
*-- one-byte indices, so 255 is the largest value both can
*-- still express. Going further means widening both and the
*-- sort with them.
*-- It costs no image bytes: ENTRIES and ENTIDX live in the
*-- `dum` arena at the end of this file, which emits nothing.
LS_MAXENT   equ   255
            put   ../../inc/mm.procbank.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/ls.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/readdir.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

* -- ls's own private zero page, clear of zp.equ's $E0-$ED by
* -- inspection (same discipline ed.s's header documents for its
* -- own $30-$5D window; this file uses a disjoint low range).
LS_ENT      equ   $30       ;2  -- &ENTRIES[index], general use
LS_ENT2     equ   $32       ;2  -- &ENTRIES[index], sort's 2nd
                            ;arm
LS_TMP16    equ   $34       ;2  -- MULT32's working cell
LS_RPAR     equ   $36       ;2  -- -R parent path pointer

* -- the collected directory-entry record is now src/liba/
* -- readdir.s's own RD_SIZE/RD_* shape (RD_LEN/RD_NAME/
* -- RD_FTYPE/RD_STYPE/RD_EOF/RD_MDATE/RD_MTIME) -- ls's own
* -- ENTRIES array below just stores RD_SIZE bytes per slot,
* -- unchanged from the old RD_SIZE=32 stride (so MULT32's *32
* -- shift needs no change either). See that file's header for
* -- the field layout and the ruling behind it.

            put   lstop.s
            put   lssort.s
            put   lsrec.s
            put   lsprint.s
            put   lscol.s
            put   ../liba/string.s
            put   ../liba/readdir.s
            put   ../liba/readsyn.s
            put   ../liba/readsys.s
            put   ../liba/readfold.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s
            put   ../liba/hex.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* ls's bss -- `dum`/`dend` at the TEXTUAL END of the file, so
* the arena begins past every emitted byte. `dum` computes
* addresses relative to the real PC where it opens and `dend`
* RESTORES that PC, so anything emitted after `dend` would be
* laid down over the arena with no diagnostic
* (learning:01M0FNC75R7YSFRNS328WHXMHN). 4,443 bytes that were
* `ds` -- real zeros in the image, carried on every disk read
* and every 39.07 cyc/byte bank copy -- plus the 24 bytes of
* parmlist LSINITPARM now stores instead. ENTRIES alone was
* 4,096 of them, more than half of ls.bin.
*
* Anchored at LIBA_BSSEND, not at `*`: src/liba/libabss.s has
* already opened its own block at `*` (the image end, which is
* where the kernel's zeroed page is), and two blocks anchored
* at `*` are the SAME BYTES.
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21 retired sec
* 17's entry-time sweep). The read-before-write trace below is
* what makes that safe. Re-derived from a full read of this
* file, not from grep hits:
*
*  - LFLAG/TFLAG/RFLAG/ERRFLAG: `stz` in START's opening run.
*  - OPTIMES: written whole-slot by OPTKEYS (BLDKEY or the
*    zero-fill) for every position 0..NPATHS-1 -- but ONLY
*    under -t, and PCMPJI reads it only under -t: the flag
*    guards both ends.
*  - KEYA/KEYB: BLDKEY writes all 5 bytes of each before
*    ENTCMP's compare loop reads them, on the only path (-t)
*    that reaches either.
*  - PATHSTART: `sta` on BOTH surviving option paths (`#2` for
*    -l, `#1` at :noopt) before :argsdone reads it; the third
*    path, :badopt, EXITs.
*  - NPATHS: `sta` at :argsdone before :vloop (VALIDATE) and
*    then :p1loop each read it.
*  - PATHIDX: `stz` at :havepaths, again at :vdone (VALIDATE's
*    own exit, before :p1loop reads it), and again before
*    :p2loop.
*  - ARGIDX: `sta` from PATHIDX+PATHSTART at the top of each
*    pass's loop body, before GETARG and before PRINTACCESERR/
*    PRINTTRUNCERR/PRINTARGFILE read it. VALIDATE computes the
*    same PATHIDX+PATHSTART sum but feeds it straight to
*    GETARG in the accumulator, never through ARGIDX -- it has
*    no error path that needs the path text again, only
*    :badopt, which reads nothing. The no-args cwd path never
*    reads ARGIDX at all -- it cannot reach any of those.
*  - DIRSHOWN: `stz` before :p2loop.
*  - STYPES: pass 1 writes STYPES,PATHIDX on ALL THREE of its
*    branches (GFI failure -> $FF, plain file -> 0, directory ->
*    its storage_type); pass 2 reads exactly the same 0..
*    NPATHS-1 range pass 1 just wrote.
*  - ENTRYCOUNT: `stz` at :capset before :rloop reads it.
*  - TRUNCATED: written on both arms (:bigcount / :notbig)
*    before :capset, and read only after LISTDIR returns carry
*    CLEAR -- the two carry-set returns (OPENDIR failure, mid-
*    walk READ error) leave :p2ok unreached.
*  - PRIDX: `stz` at PRINTENTRIES' first instruction.
*  - SORTI/SORTJ: SORTI `sta #1` after the <2-entry early out;
*    SORTJ `sta` from SORTI-1 before :inner reads it.
*  - SORTKEY: `sta` from ENTIDX[SORTI] at :dosort before :place
*    reads it.
*  - CFLAG/ONEFLAG/DFLAG/FFLAG/SFLAG/RECFLAG: `stz` in
*    START's opening run.
*  - RCOUNT/RERRFLAG: `stz` at START; RUNREC and RRECERR write
*    before later reads. RQIDX/RNAMLEN/RINDEX/RCHAR/RSEP/
*    RTOTAL/RPARLEN/RDEST are stored by the lsrec.s routine
*    that owns each before any read. LS_RPAR is stored at every
*    LISTDIR entry before QUEUEDIRS uses it. Each RSTACK slot is
*    filled completely through its count before RUNREC pops it.
*  - LSGEO: written by SC_TTYGEO (or LSGEO by the -C fallback)
*    before COLSETUP's divide reads it; the not-a-console/no -C
*    exit never reads it.
*  - LSMAXLEN/LSCOLW/LSNCOLS/LSNROWS: each stored in COLSETUP
*    before its own read; PRINTENTRIES' :columns runs only after
*    COLSETUP returned carry clear: all four written.
*  - LSROW/LSCOL/LSI/LSPAD: stz/sta at PRINTCOLS's loop heads
*    before each loop reads them.
*  - ENTIDX: the identity fill 0..ENTRYCOUNT-1 at SORTENTRIES'
*    entry, BEFORE the <2 early-out, and only that range is ever
*    read -- by the sort's :inner/:place and by PRINTENTRIES.
*  - DTDATE/DTTIME: all four bytes stored by PRINTARGFILE or
*    PRINTENTLONG immediately before their `jsr PRINTDATE`,
*    which is PRINTDATE's only pair of callers.
*  - HOURV/MINUTEV/DAYV/MONTHV/YEAR7: each `sta`'d by PRINTDATE
*    before its own later read; the paths that skip the store
*    (hour>23, minute>59) jump to :ext and read none of them.
*  - PR2DIG_ONE: `sta` then read, four instructions apart.
*  - LS3_VAL/LS3_SUB/LS3_DIGIT/LS3_LZ: LS3_VAL stored whole by
*    PRINTEOFCOL; the other three stored by U3DEC's own loop
*    setup before that loop reads them back.
*  - SIZEBUF: NUL-terminated by U3DEC, or by PRINTBLKSCOL's own
*    'b'+NUL store after U2DEC, before PRPAD8's STRLEN scans
*    it. 10 bytes holds U3DEC's 8 digits + NUL.
*  - PRPADTMP/PADCNT: stored by PRPAD8 before it reads either.
*  - PATHBUF: written whole (count-prefixed, not NUL-scanned)
*    by MKPATH before SC_GFI or LISTDIR reads it.
*  - PFXBUF: written by GET_PREFIX before `lda PFXBUF` reads
*    the count byte -- and not read at all when SC_GETPFX
*    returns carry set.
*  - ENTRIES: READDIR fills slot i, then ENTRYCOUNT is
*    incremented; SORTENTRIES and PRINTENTRIES only ever index
*    BELOW ENTRYCOUNT. Every field ls reads (RD_NAME and its
*    NUL, RD_FTYPE, RD_EOF, RD_MDATE, RD_MTIME, RD_BLOCKS) is
*    stored by READDIR -- checked against src/liba/readdir.s
*    rather than assumed. Record offset 19 and the final 3 pad
*    bytes are not read as values.
*  - GPPARM/GFIPARM: constants stored by LSINITPARM (above),
*    result fields written by the kernel's copyback before ls
*    reads them, GFIPARM_PATH pointing at a `dum` address is
*    still a compile-time constant word.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
LFLAG       ds    1
TFLAG       ds    1              ;-t newest first
RFLAG       ds    1              ;-r reverse
KEYA        ds    5              ;ENTCMP's chronology keys
KEYB        ds    5
ERRFLAG     ds    1
PATHSTART   ds    1
NPATHS      ds    1
PATHIDX     ds    1
ARGIDX      ds    1
DIRSHOWN    ds    1

*-- docs/DEVFS.md: LS_DEVCHK's own scratch (lstop.s).
LS_CWDDEV   ds    1              ;1 = this invocation's cwd is
                                 ;the synthetic /dev
LSD_NAMLEN  ds    1
LSD_NAMBUF  ds    5              ;longest device name, "ttya0"
LSD_UNIT    ds    1
LSD_DEVN    ds    1
LSD_DEVBUF  ds    16

SP_I        ds    1
SP_J        ds    1
PORDER      ds    128
STYPES      ds    128
OPTIMES     ds    1024           ;-t: 128 operands x 8 (5-byte
                                 ;chronology key + 3 pad --
                                 ;OPTKADDR's shift addressing)

ENTRYCOUNT  ds    1
TRUNCATED   ds    1
PRIDX       ds    1

SORTI       ds    1
SORTJ       ds    1
SORTKEY     ds    1              ;entry index being placed
CFLAG       ds    1              ;-C
ONEFLAG     ds    1              ;-1
DFLAG       ds    1              ;-d list directories as entries
FFLAG       ds    1              ;-F append directory slash
SFLAG       ds    1              ;-s print ProDOS blocks used
RECFLAG     ds    1              ;-R recursive
RCOUNT      ds    1              ;pending recursive paths
RQIDX       ds    1
RNAMLEN     ds    1
RINDEX      ds    1
RCHAR       ds    1
RSEP        ds    1
RTOTAL      ds    1
RPARLEN     ds    1
RDEST       ds    1
RERRFLAG    ds    1
*-- column layout, lscol.s COLSETUP/PRINTCOLS
LSGEO       ds    4
LSMAXLEN    ds    1
LSCOLW      ds    1
LSNCOLS     ds    1
LSNROWS     ds    1
LSROW       ds    1
LSCOL       ds    1
LSI         ds    1
LSPAD       ds    1
*-- ENTIDX: the sorted ORDER (2026-09-03, index sort -- see
*-- lssort.s SORTENTRIES). Replaces KEYBUF/KEYBUFMD, the 32-byte
*-- key copy the record-shifting sort needed (and with it the
*-- real-Merlin hi-byte-offset caveat, learning:
*-- 01M15S5BTYRKFM1FNC7YJRBS7H, that split it in two).
ENTIDX      ds    LS_MAXENT+1    ;one byte per ENTRIES slot,
                                 ;+1 so the insertion sort's
                                 ;`sta ENTIDX+1,x` shift has
                                 ;somewhere to land at the top

DTDATE      ds    2
DTTIME      ds    2
HOURV       ds    1
MINUTEV     ds    1
DAYV        ds    1
MONTHV      ds    1
YEAR7       ds    1
PR2DIG_ONE  ds    1

LS3_VAL     ds    3
LS3_SUB     ds    3
LS3_DIGIT   ds    1
LS3_LZ      ds    1
SIZEBUF     ds    10
PRPADTMP    ds    1
PADCNT      ds    1

PATHBUF     ds    65
PFXBUF      ds    80
RSTACK      ds    1056           ;16 paths, 66 bytes each
* -- DIRBUF/OPARM/RPARM/CPARM (the raw OPEN/READ/CLOSE parmlists
* -- the inline walk used to own) moved into src/liba/readdir.s
* -- along with the walk itself -- see LISTDIR's own header.
ENTRIES     ds    LS_MAXENT*32   ;LS_MAXENT x RD_SIZE

* -- GET_PREFIX, PCOUNT 1. Constants stored by LSINITPARM.
GPPARM      ds    1              ;param_count
GPPARM_BUF  ds    2              ;-> PFXBUF

* -- GET_FILE_INFO ($C4), PCOUNT_GFI-shaped (inc/mli.equ):
* -- pathname, access, file_type, aux_type, storage_type,
* -- blocks_used, mod_date, mod_time, create_date, create_time.
* -- CONTIGUITY IS LOAD-BEARING: the MLI reads these as one
* -- block, so no field may be split out and left in text.
GFIPARM     ds    1              ;param_count
GFIPARM_PATH ds   2              ;-> PATHBUF
GFIPARM_ACC ds    1              ; result
GFIPARM_FTYP ds   1              ; result
GFIPARM_AUX ds    2              ; result
GFIPARM_STYP ds   1              ; result
GFIPARM_BLKS ds   2              ; result
GFIPARM_MDATE ds  2              ; result
GFIPARM_MTIME ds  2              ; result
GFIPARM_CDATE ds  2              ; result
GFIPARM_CTIME ds  2              ; result
LS_BSSEND                        ;scripts/check_ls.py's poison
                                 ;window ends here -- a `dum`
                                 ;label, emits nothing. Without
                                 ;it the poison stopped at
                                 ;LIBA_BSSEND, which is exactly
                                 ;where THIS arena starts, so
                                 ;the gate proved nothing about
                                 ;any of the 4,443 bytes below.
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's
* -- end; $BF00 is the top of the process window. The
* -- division is 0 while it fits, 1 when it does not, and
* -- `err` fails the assembly. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
* -- See src/bin/ed.s for the full note.
            err   */$BF00
            dend
