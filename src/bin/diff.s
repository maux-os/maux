*---------------------------------------------------------------
* diff.s -- line-oriented diff, V6/V7 ed-script-compatible
* output (default), a pure ed script (-e), or a CONTEXT diff
* (-u unified / -c context, -U n / -C n for a width other than
* the default 3 -- src/bin/diffctx.s and diffcout.s).
*
* Usage: diff [-e|-u|-c] [-U n] [-C n] file1 file2
*
* ALGORITHM. Classic dynamic-programming LCS (Longest Common
* Subsequence) over WHOLE LINES (compared with liba's STRCMP,
* not per-byte). NA = lines in file1, NB = lines in file2. A
* byte-per-cell table LCS[0..NA][0..NB] is filled with the
* textbook recurrence (LCS[i][j] = LCS[i-1][j-1]+1 when the
* lines match, else max(LCS[i-1][j], LCS[i][j-1])), then
* backtraced from (NA,NB) to (0,0) to recover the KEEP/DELETE/
* INSERT op stream, which is grouped into hunks and printed.
* This is the textbook-optimal algorithm (minimal edit script),
* not a heuristic.
*
* MEMORY COMPLEXITY: O(NA*NB) for the DP table -- exactly the
* "prohibitive" cost this task's brief warns about, so it is
* capped explicitly: DP_MAX_BYTES (see below) bounds
* (NA+1)*(NB+1) BEFORE the table is ever filled. Every other
* structure is O(NA+NB): the line-pointer tables (LPA/LPB), the
* text arena, the backtrace op stream (OPS, at most NA+NB
* entries), and the hunk table (at most NA+NB records). Line
* indices are 1 byte (MAXLINES caps each file at 120 lines, well
* under 256) so no structure needs 16-bit indexing except real
* byte addresses (arena/table pointers) and the DP table's row
* stride, which stays a simple pointer-increment walk (see
* DPFILL) -- the fill needs exactly ONE multiply in the whole
* program (the DP_MAX_BYTES cap check), because row i+1 always
* starts one byte past row i's last cell (row-major, fixed
* stride) so the fill/backtrace never re-derives an address from
* scratch except the backtrace's own single starting cell.
*
* FAILURE MODE (loud, never silent truncation, task ruling):
*   - a file exceeding MAXLINES lines, or the shared text arena
*     exceeding ARENA_SIZE bytes, during input: OVERFLOW.
*   - (NA+1)*(NB+1) > DP_MAX_BYTES (files too different/large
*     for the DP table budget): OVERFLOW, checked BEFORE the
*     table is touched.
*   - more hunks than MAXHUNKS (pathological alternating-line
*     inputs): OVERFLOW.
*   All three print "diff: input too large" to fd 2 and exit
* 2 -- see OVERFLOW below.
*
* OUTPUT: default is the classic ed-script-compatible form
* (a/c/d commands, </> context lines, "---" separator for c).
* -e emits a PURE ed script (no context lines) -- hunks in
* REVERSE order (last-to-first) so earlier line numbers stay
* valid as ed applies each edit, the same reason real diff -e
* does it. -u and -c emit the two CONTEXT forms `patch` reads;
* both group the same HUNKTBL records into wider hunks by the
* 2*context overlap rule and print copied context around them
* (diffctx.s, which carries the format details and the
* measurements they came from, plus diffcout.s for -c's own
* two-section body).
*
* EXIT STATUS (POSIX): 0 identical (no hunks -- no output at
* all), 1 differences found, 2 error (usage/open/overflow).
*
* Two files open at once, buffered per-fd reads -- cmp.s's own
* O1PARM/O2PARM + GETB1/GETB2 shape, duplicated here.  Line
* storage (arena + line-pointer table, CR -> NUL in place) is
* sort.s's own LINE STORAGE convention, duplicated per file.
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
            dsk   ../../build/diff.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/readdir.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

BUFSZ         equ   128        ;per-fd read chunk, cmp.s's split
MAXLINES      equ   120        ;lines/file cap -- fits 1 byte,
                               ;see header
ARENA_SIZE    equ   6000       ;shared text arena, both files
DP_MAX_BYTES  equ   10000      ;(NA+1)*(NB+1) cap -- see header
OPS_MAX       equ   240        ;backtrace op stream, MAXLINES*2
MAXHUNKS      equ   120        ;hunk-table cap

DMAXDEP       equ   16         ;diff -r: directory levels
FRSZ          equ   10         ;one saved level, see diffrec.s
RECSZ         equ   17         ;listing record: type + 16 name
NAMESZ        equ   12000      ;diff -r name arena, all levels

OPTR          equ   $F2        ;'r', as GETOPT returns it
DSLASH        equ   $AF        ;'/' in a liba (high-bit) string

OP_KEEP       equ   0
OP_DEL        equ   1
OP_INS        equ   2

* -- diff.s's own zero page, $30 up (neither sort.s nor ed.s is
* -- PUT here, so this window is free -- house style, both those
* -- files also start their own window at $30).
DF_TPOS     equ   $30   ;2  arena bump-allocation cursor
DF_LSTART   equ   $32   ;2  READALL*: current line's start addr
DF_CBYTE    equ   $34   ;1  READALL*: byte under test
DF_ROWSTA   equ   $35   ;2  DPFILL: row i's cell(i,0) address
DF_PVSTART  equ   $37   ;2  DPFILL: row i-1's cell(i-1,0) addr
DF_ROWPTR   equ   $39   ;2  DPFILL: moving cursor, row i
DF_PVPTR    equ   $3B   ;2  DPFILL: moving cursor, row i-1
DF_STRIDE   equ   $3D   ;2  NB+1 -- DP row stride
DF_I        equ   $3F   ;1  DPFILL/BACKTRACE: line index i
DF_J        equ   $40   ;1  DPFILL/BACKTRACE: line index j
DF_M1       equ   $41   ;2  MUL16 in: multiplicand
DF_M2       equ   $43   ;1  MUL16 in: multiplier
DF_PROD     equ   $44   ;2  MUL16 out
DF_CURPTR   equ   $46   ;2  BACKTRACE: current DP cell address
DF_UPPTR    equ   $48   ;2  BACKTRACE: cell(i-1,j) scratch addr
DF_LEFTPTR  equ   $4A   ;2  BACKTRACE: cell(i,j-1) scratch addr
DF_WPOS     equ   $4C   ;1  BACKTRACE: OPS write cursor
DF_LPTMP    equ   $4D   ;2  LPA_GET/LPB_GET result
DF_TMP      equ   $4F   ;2  generic scratch
DF_TMP2     equ   $51   ;2  generic scratch #2
* -- diffrec.s's walker pointers, $53 up. DF_CUR1..DF_E2 are one
* -- contiguous 8-byte block: a saved level is a copy of it.
DF_CUR1     equ   $53   ;2  list 1 cursor (next unread record)
DF_CUR2     equ   $55   ;2  list 2 cursor
DF_E1       equ   $57   ;2  list 1 end (= list 2 start)
DF_E2       equ   $59   ;2  list 2 end (= level's arena top)
DF_NTOP     equ   $5B   ;2  name arena bump pointer
DF_TNAME    equ   $5D   ;2  the entry name under work
DF_LB       equ   $5F   ;2  start of the list being built
DF_P        equ   $61   ;2  INSREC: insertion point
DF_S        equ   $63   ;2  INSREC: shift source / room check
DF_D        equ   $65   ;2  INSREC: shift destination
DF_CNT      equ   $67   ;2  INSREC: bytes left to shift
DF_FP       equ   $69   ;2  saved-level stack pointer
DF_PD       equ   $6B   ;2  Only-in directory string
* window $30-$6C, clear of liba's $E0-$F1.

            put   difftop.s
            put   difflpb.s
            put   diffhnk.s
            put   diffctx.s
            put   diffcout.s
            put   diffdir.s
            put   diffrec.s
            put   ../liba/string.s
            put   ../liba/readdir.s
            put   ../liba/readsyn.s
            put   ../liba/readsys.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s
            put   ../liba/argv.s
            put   ../liba/getopt.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* Big structures -- `dum`/`dend` (compute addresses only, emit
* nothing), sort.s/ed.s's own conversion, for the same reason:
* merlin32 emits `ds` as real zero bytes, and none of these need
* to exist in the binary image, only in the process's runtime
* address space. Must be the textually LAST thing in the file
* (dend resumes real code emission at the SAME address `dum`
* opened at -- anything after this block would collide).
*
* READ-BEFORE-WRITE TRACE (all six regions):
*
*   LPA/LPB: every slot [0..NA-1]/[0..NB-1] is written by
*   ADDLINEA/ADDLINEB, strictly increasing, before NA/NB is
*   incremented past it. LPA_GET/LPB_GET (and everything built
*   on them -- DPFILL, BACKTRACE, PRLINE_A/B) only ever look up
*   indices 1..NA/1..NB, i.e. only slots ADDLINE* already wrote.
*
*   ARENA: every byte is written via `sta (DF_TPOS)` in
*   READALLA/READALLB (main loop and the tail/EOF case) BEFORE
*   the line's start pointer is published into LPA/LPB by
*   ADDLINE*. Every later reader (STRCMP via LPA_GET/LPB_GET,
*   PUTS via PRLINE_A/B) reaches arena bytes only through a
*   published LPA/LPB pointer.
*
*   DPTABLE: row 0 is explicitly zero-filled (DPFILL's
*   :zloop) before the i=1 outer iteration ever reads it as
*   "the previous row". Every row i's cell(i,0) is stored
*   (:dorow's `sta (DF_ROWSTA)`) before the j=1 inner
*   iteration reads it as "left". Every row i is fully
*   written before row i+1 is touched, and BACKTRACE (reads
*   arbitrary cells) never runs until DPFILL has returned,
*   i.e. the whole table is written first.
*
*   OPS: every slot [OPS_START..OPS_MAX-1] is written by BPUTOP
*   during BACKTRACE before MKHUNKS (which runs strictly after
*   BACKTRACE returns) reads any of them; MKHUNKS's own scan
*   bounds itself to exactly that range (OPS_START.. OPS_MAX-1).
*
*   HUNKTBL: every record [0..NHUNKS-1] is written by CLOSEHUNK
*   before NHUNKS is incremented past it; OUTNORM/OUTE (via
*   GETHUNK) only ever index 0..NHUNKS-1.
*
* No zeroing loop needed for any of the six.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
*-- The 411 bytes below were still EMITTED `ds` zeros outside
*-- this arena. They are residue, not a carve-out -- the arena
*-- was built for the six big structures and the scalars were
*-- never revisited. Read-before-write trace (sec 21):
*--  - OUTMODE/CTXN: `stz OUTMODE` is START's first
*--    instruction and `lda #3 / sta CTXN` its second, both
*--    before the option loop that may overwrite either.
*--  - GS/GE/FHA/FHB/LAE/LBE/OSTART/OEND/OCNT/NSTART/NEND/
*--    NCNT: GS is `stz`'d at OUTU's/OUTC's head; GRPSCAN
*--    writes GE and the other ten from GS before any reader,
*--    and no body routine runs before a GRPSCAN.
*--  - CURA/CURB/GK/GKN/CPFX/CPFX2/CLN/CLN2/DTMPA: each is
*--    written at the head of the loop that reads it --
*--    UBODY/COLDBODY/CNEWBODY set CURA/CURB/GK before their
*--    first read, GKN is `sta`'d from HDELS/HINS immediately
*--    before its own `dec`, CPFX/CPFX2 are set on every arm
*--    before PRPFX reads them, CLN/CLN2 by every PRRNGU/
*--    PRRNGC caller, and DTMPA inside DFPARSED's multiply
*--    before the `adc` that reads it.
*--  - F1IDX/F2IDX: `sta` before any read.
*--  - OERRIDX: `sta` immediately before the `jmp OPENERR`,
*--    and OPENERR is reachable ONLY from those two jumps --
*--    the code above it ends in `jsr EXIT`.
*--  - FD1/FD2: `sta`'d after their opens succeeded.
*--  - BUFPOS1/BUFLEN1: `stz`'d as READALLA's first two
*--    instructions; BUFPOS2/BUFLEN2 likewise by READALLB.
*--    That per-file reset is also what makes reusing GETB1/
*--    GETB2 across the two sequential reads correct, and it
*--    turns the `pos >= len` refill test into a decision
*--    rather than an accident.
*--  - NA/NB: `stz`'d before READALLA/READALLB run.
*--  - OPS_START: `sta`'d at BACKTRACE's only loop exit, which
*--    always terminates (every arm decrements I or J), and
*--    read only by MKHUNKS, which is called strictly after
*--    `jsr BACKTRACE`. Even the NA=NB=0 case reaches it.
*--  - NHUNKS/INHUNK/ANEXT/BNEXT/OPSCUR: MKHUNKS writes all
*--    five in its opening block before its loop reads any.
*--  - HA/HB/HDELS/HINS: written by OPENHUNK, and every reader
*--    is gated on INHUNK being nonzero -- which only OPENHUNK
*--    makes it. GETHUNK writes all four for the output pass.
*--  - HI: `stz`/`sta` at the head of each of the two output
*--    routines, which are its only entry points.
*--  - KIDX: `lda #1 / sta KIDX` at the head of each of the
*--    three body printers.
*--  - CMDCH: CLASSIFY writes it on ALL THREE arms, and every
*--    reader sits after a `jsr CLASSIFY`.
*--  - PATH1BUF/PATH2BUF: MKPATH writes chars then the count
*--    byte; the MLI reads only count+1.
*--  - CBUF1/CBUF2: filled by SC_READ, indexed only below the
*--    BUFLEN that same call set.
OUTMODE     ds    1     ;0 normal, 1 -e, 2 -u, 3 -c
BFLAG       ds    1     ;-b: white space compares loosely
DF_BI       ds    1     ;DF_LCMP cursor into the A line
DF_BJ       ds    1     ;.. and into the B line
DF_AWS      ds    1     ;.. A was on a white-space run
DF_BWS      ds    1     ;.. so was B
DF_BA       ds    1     ;.. the A byte under comparison
DF_BB       ds    1     ;.. and the B byte
CTXN        ds    1     ;context lines, -U/-C (default 3)
GS          ds    1     ;first hunk of the current group
GE          ds    1     ;last hunk of the current group
FHA         ds    1     ;HA of hunk GS
FHB         ds    1     ;HB of hunk GS
LAE         ds    1     ;HA+HDELS of hunk GE
LBE         ds    1     ;HB+HINS of hunk GE
OSTART      ds    1     ;group's file1 range, 1-based
OEND        ds    1
OCNT        ds    1
NSTART      ds    1     ;group's file2 range, 1-based
NEND        ds    1
NCNT        ds    1
CURA        ds    1     ;body cursors, 1-based line numbers
CURB        ds    1
GK          ds    1     ;hunk index within a group
GKN         ds    1     ;lines left in a del/ins run
CPFX        ds    1     ;output prefix char
CPFX2       ds    1     ;second prefix char, 0 = none (-u)
CLN         ds    1     ;PRRNG*/PRP* argument scratch
CLN2        ds    1
DTMPA       ds    1     ;DFPARSED's multiply scratch
F1IDX       ds    1
F2IDX       ds    1
OERRIDX     ds    1
FD1         ds    1
FD2         ds    1
BUFPOS1     ds    1
BUFLEN1     ds    1
BUFPOS2     ds    1
BUFLEN2     ds    1
NA          ds    1
NB          ds    1
OPS_START   ds    1
NHUNKS      ds    1
INHUNK      ds    1
ANEXT       ds    1
BNEXT       ds    1
OPSCUR      ds    1
HA          ds    1
HB          ds    1
HDELS       ds    1
HINS        ds    1
HI          ds    1
KIDX        ds    1
CMDCH       ds    1

PATH1BUF    ds    65
PATH2BUF    ds    65
CBUF1       ds    BUFSZ
CBUF2       ds    BUFSZ

LPA         ds    MAXLINES*2
LPB         ds    MAXLINES*2
ARENA       ds    ARENA_SIZE
ARENAEND    ds    0     ;dum label (was an equ) so
                        ;the REL bss can ENT it
OPS         ds    OPS_MAX
HUNKTBL     ds    MAXHUNKS*4
DPTABLE     ds    DP_MAX_BYTES
*-- diff -r (diffrec.s). Write-before-read trace:
*--  - RFLAG/HDRFLAG/DSTAT: `stz`'d at START's head.
*--  - DP1/DP2/DL1/DL2: LOADOP writes string and length from
*--    argv before anything reads either; APPEND/POPFR keep
*--    them paired.
*--  - SDL1/SDL2: `sta`'d in the pair arm before PUSHFR or the
*--    truncation reads them.
*--  - DEPTH: `stz`'d by WALKTOP. FRAMES: PUSHFR writes a level
*--    before POPFR reads it (DEPTH only pops what it pushed).
*--  - ST1/ST2/T1/T2: GFISTAT / the pair arm write before use.
*--  - HDI: PRHDR's loop index, set at its head.
*--  - RDREC: written whole by READDIR before INSREC reads it.
*--  - NAMES: INSREC writes a record before a cursor reaches it.
RFLAG       ds    1     ;-r given
HDRFLAG     ds    1     ;print the `diff ...` header line
DSTAT       ds    1     ;exit status the walk will return
DL1         ds    1     ;strlen(DP1)
DL2         ds    1
SDL1        ds    1     ;DL1 before this entry's name went on
SDL2        ds    1
DEPTH       ds    1
ST1         ds    1     ;operand 1: 1 = directory
ST2         ds    1
T1          ds    1     ;entry type, side 1 (0 file, 1 dir)
T2          ds    1
HDI         ds    1
DP1         ds    82    ;display path 1: 64 chars + '/' + name
DP2         ds    82
FRAMES      ds    DMAXDEP*FRSZ
RDREC       ds    RD_SIZE
NAMES       ds    NAMESZ
NAMEEND     ds    0
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's
* -- end; $BF00 is the top of the process window. The
* -- division is 0 while it fits, 1 when it does not, and
* -- `err` fails the assembly. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
* -- See src/bin/ed.s for the full note.
            err   */$BF00
            dend
