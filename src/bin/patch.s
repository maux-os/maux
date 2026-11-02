*---------------------------------------------------------------
* patch.s -- apply a diff to a file. The other half of diff(1):
* what `diff -u` writes here (or on a host, and carried in over
* `tip`), this reads back.
*
* Usage: patch [-b] [-R] [-p num] [-i patchfile] [-o outfile]
*              [file]
*
* THREE INPUT FORMS, DETECTED, never declared by a flag (POSIX:
* "patch shall read a patch file... and determine its format"):
*
*   UNIFIED   "@@ -l,s +l,s @@" then ' '/'-'/'+' lines
*   CONTEXT   "***************", "*** l,l ****", "--- l,l ----"
*             then '  '/'- '/'+ '/'! ' lines
*   NORMAL    "3c3" / "3a4" / "3,5d2" then "< " and "> " lines
*             around a "---" separator
*
* The three parsers (patchhnk.s) all produce the SAME thing: a
* hunk's OLD line list, its NEW line list, and the old-file line
* number it claims to start at. Everything downstream --
* matching, applying, rejecting, -R -- is written once against
* that triple and never asks which form it came from. -R is a
* SWAP of the two lists (and the two start numbers) at the end
* of parsing, for the same reason.
*
* ONE RULE COVERS ALL THREE FORMS' EMPTY-RANGE CASE. A diff
* prints the line number BEFORE a zero-length range: unified
* `@@ -2,0 +3 @@` inserts AFTER old line 2, context `*** 0 ****`
* means an empty file1, normal `3a4` appends after line 3. So
* after parsing (and after -R's swap), `if NOLD == 0 then
* OSTART = OSTART+1` turns every one of them into the same
* "insert BEFORE old line OSTART" that a matching hunk uses. It
* is derived from the formats, and every one of the three was
* checked against real output before it was written down
* (src/bin/diffctx.s carries the measurements).
*
* MATCHING is EXACT and FUZZ-FREE. A hunk's OLD lines must
* compare equal, whole line for whole line (liba STRCMP), to a
* run of target lines. The position is GUESSED from the stated
* line number carried forward by the lines applied so far, and
* if that guess misses, the run is searched for outward from it
* (+1, -1, +2, -2...) exactly as patch(1) has always done --
* that is an OFFSET, not fuzz: no context line is ever allowed
* to differ. `patch -l` (ignore white space) and fuzz factors
* are NOT implemented; both would need an inexact comparison
* this tool deliberately does not have.
*
* WHAT IT WRITES. The patched file, streamed as it goes, to the
* target path (or -o's). A hunk that fails is written verbatim
* -- the lines exactly as they were read, whichever form they
* were in -- to NAME.rej, which POSIX asks for and which is the
* only artifact that lets a human finish the job by hand. -b
* first copies the untouched original to NAME.orig; without -b
* nothing is saved, which is POSIX's rule and NOT this host's
* (BSD patch saves a .orig unconditionally -- a divergence, so
* it is recorded rather than copied).
*
* EXIT STATUS (POSIX): 0 every hunk applied, 1 one or more
* hunks were rejected, 2 an error (usage, unreadable patch or
* target, malformed patch, an input past the caps below).
*
* IN-PLACE, VIA liba's CREAT. The whole target is read into the
* arena and its fd CLOSED before the output is created, so
* output-onto-input is safe by construction and needs no
* temporary file. CREAT is make-or-truncate (SET_EOF 0 by
* HANDLE after OPEN) because ProDOS OPEN never shrinks EOF and
* has no truncate-by-pathname at all -- writing a shorter file
* over a longer one WITHOUT that leaves a stale tail, which is
* exactly the bug ed/ex's own `w` shipped with
* (learning:01M1GEND62D3RAY6M6550WKCN4).
*
* CAPS (loud, never silent truncation -- diff.s's own posture):
* MAXLINES lines in the target, ARENA_SIZE bytes of target
* text, MAXHLINES lines and HARENA_SZ bytes in any ONE hunk.
* Past any of them: "patch: input too large" on fd 2, exit 2.
*
* NAMES. A derived name (NAME.orig, NAME.rej) must still be a
* legal ProDOS name -- 15 characters INCLUDING the extension,
* and the parser, not the creator, is what enforces it
* (learning:01M07G8WT2R3G2P87EK1DNPVYP), so an over-long base
* is TRUNCATED to 11 characters before the suffix goes on
* rather than producing a name nothing can ever open.
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
            dsk   ../../build/patch.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ         equ   128      ;patch-stream read chunk
MAXLINES      equ   250      ;target lines (1-byte numbering)
ARENA_SIZE    equ   12000    ;target text bytes
MAXHLINES     equ   120      ;raw lines in ONE hunk
HARENA_SZ     equ   2400     ;raw text bytes in ONE hunk
NAMEMAX       equ   64       ;a pathname from the patch header

FORM_U        equ   1
FORM_C        equ   2
FORM_N        equ   3

* -- patch.s's own zero page, $30 up, the window every util
* -- opens for itself (diff.s/sort.s/ed.s all start at $30);
* -- clear of liba's own $E0-$F1.
PT_TPOS     equ   $30   ;2  target arena bump cursor
PT_LSTART   equ   $32   ;2  READTGT: current line's start
PT_CBYTE    equ   $34   ;1  READTGT: byte under test
PT_HPOS     equ   $35   ;2  hunk arena bump cursor
PT_LP       equ   $37   ;2  the line PGETLN just read
PT_LP2      equ   $39   ;2  second line pointer
PT_TMP      equ   $3B   ;2  generic scratch
PT_TMP2     equ   $3D   ;2  generic scratch #2
PT_SCAN     equ   $3F   ;2  in-line scan cursor (parsers)
PT_NBUF     equ   $41   ;2  name-building cursor
* window $30-$42, 19 bytes.

            put   patchio.s
            put   patchtgt.s
            put   patchwr.s
            put   patchhnk.s
            put   patchprs.s
            put   patchapp.s
            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/creat.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* Big structures -- `dum`/`dend` (addresses only, no emitted
* bytes), diff.s/sort.s/ed.s's own convention and the same
* reason: none of this needs to exist in the binary image, only
* in the process's address space.
*
* READ-BEFORE-WRITE TRACE (every cell, docs/STICKY.md sec 21):
*
*   Flags and counts written by START before anything reads
*   them: WANTB, WANTR, PSTRIP, HAVEOP, OPIDX, HAVEI, HAVEOUT,
*   PFD, OFD, RFD, RJOPEN, FORM, NT, NHOK, NHFAIL, CURT,
*   PREVEND, LASTSTAR, PBFLAG, HADHUNK, BUFPOS, BUFLEN. START
*   `stz`s or `sta`s all of them in its opening block, before
*   the option loop and before any routine below runs. TFD/
*   TBUFPOS/TBUFLEN are written at READTGT's head, BFD and EFD
*   by the routines that own them (WRBACKUP's CREAT, EMITLN's
*   own first instruction), all before any read.
*
*   TGTLP/ARENA: slot i and the bytes it points at are written
*   by READTGT (ADDTLINE publishes the pointer only after the
*   text and its NUL are stored), and NT is incremented past i
*   only then. Every reader -- MATCHAT's STRCMP, EMITT's PUTS --
*   indexes 1..NT only.
*
*   HARENA/RAWLP/NRAW: PGETLN stores a line's bytes and its NUL
*   at PT_HPOS and only then hands the pointer to HRAW, which
*   publishes it into RAWLP[NRAW] before incrementing NRAW. The
*   .rej writer walks 0..NRAW-1.
*
*   OLDLP/NOLD, NEWLP/NNEW: same shape, written by HOLD/HNEW
*   during parsing; NOLD/NNEW are `stz`'d at each parser's head
*   (HUNKINIT) before the first HOLD/HNEW.
*
*   OSTART/NSTART/OCNT/NCNT/CMDC: every parser writes all five
*   before returning carry-clear; the apply loop reads them
*   only after such a return.
*
*   OLDNAME/NEWNAME/NAMEBUF/PATHBUF/ORIGBUF/REJBUF: each is
*   written by the routine that names it (SCANHDR's SAVENAME,
*   SETTGT, MKDERIV) before the OPEN/CREAT that reads it; the
*   two header-name buffers start with an explicit NUL from
*   START so "absent" is distinguishable from "not yet
*   written".
*
*   PBUF: filled by SC_READ, indexed only below the BUFLEN that
*   same call set.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
WANTB       ds    1     ;-b: keep NAME.orig
WANTR       ds    1     ;-R: apply the reverse patch
PSTRIP      ds    1     ;-p num: path components to strip
HAVEOP      ds    1     ;a file operand was given
OPIDX       ds    1     ;its argv index
HAVEI       ds    1     ;-i was given (INAME)
HAVEOUT     ds    1     ;-o was given (OUTNAME)
PFD         ds    1     ;the patch stream's fd (0 = stdin)
TFD         ds    1     ;the target file's fd, while reading
OFD         ds    1     ;the output file's fd
BFD         ds    1     ;the -b backup file's fd
EFD         ds    1     ;EMITLN's fd across its PUTS
RFD         ds    1     ;the reject file's fd
RJOPEN      ds    1     ;is RFD open yet?
FORM        ds    1     ;FORM_U / FORM_C / FORM_N
NT          ds    1     ;target lines
NHOK        ds    1     ;hunks applied
NHFAIL      ds    1     ;hunks rejected
CURT        ds    1     ;next target line to emit, 1-based
PREVEND     ds    1     ;old-file line after the last hunk
LASTSTAR    ds    1     ;SCANHDR: previous line was "*** "
PBFLAG      ds    1     ;a line is pushed back
HADHUNK     ds    1     ;at least one hunk was parsed
BUFPOS      ds    1     ;patch-stream buffered reader
BUFLEN      ds    1
TBUFPOS     ds    1     ;target-file buffered reader
TBUFLEN     ds    1
OSTART      ds    1     ;this hunk's old-file start line
NSTART      ds    1     ;...and its new-file start line
OCNT        ds    1     ;unified header's counts
NCNT        ds    1
CMDC        ds    1     ;normal form's a/c/d
NRAW        ds    1
NOLD        ds    1
NNEW        ds    1
HMATCH      ds    1     ;where the hunk matched, 1-based
TIDX        ds    1     ;generic line index
TIDX2       ds    1
MIDX        ds    1     ;MATCHAT's own line index
SRCH        ds    1     ;offset search distance
CAND        ds    1     ;the position being tried
INRANGE     ds    1     ;did this step try anything at all?
OLDTBL      ds    2     ;the OLD list, after -R's swap
NEWTBL      ds    2     ;the NEW list, after -R's swap
OKIND       ds    MAXHLINES     ;context(0)/changed(1), -c only
NKIND       ds    MAXHLINES

PBUF        ds    BUFSZ
TBUF        ds    BUFSZ
OLDNAME     ds    NAMEMAX
NEWNAME     ds    NAMEMAX
NAMEBUF     ds    NAMEMAX
OUTNAME     ds    NAMEMAX
INAME       ds    NAMEMAX
DERIVBUF    ds    NAMEMAX+8
PATHBUF     ds    65
PATH2BUF    ds    65

TGTLP       ds    MAXLINES*2
RAWLP       ds    MAXHLINES*2
OLDLP       ds    MAXHLINES*2
NEWLP       ds    MAXHLINES*2
HARENA      ds    HARENA_SZ
HARENAEND   ds    0
ARENA       ds    ARENA_SIZE
ARENAEND    ds    0     ;dum labels (not equates) so a REL bss
                        ;can ENT them, diff.s's own note
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end
* -- and $BF00 is the top of the process window. The division
* -- is 0 while it fits and 1 when it does not, and `err` fails
* -- the assembly. check_modules' image-window gate cannot see
* -- this -- a `dum` arena emits no bytes. See src/bin/ed.s.
            err   */$BF00
            dend
