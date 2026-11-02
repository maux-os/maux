*---------------------------------------------------------------
* ed.s -- maux's line editor. Commands: a c d i p n q r w s g m
* t j =. Addresses: . $ N /re/ and addr,addr ranges (classic ed
* defaults per-command, below); bare `,` (= 1,$) and bare `;` (=
* .,$) are ALSO accepted (2026-08-19 -- see B.ED.TXT) -- a
* partially-omitted range (`,5` or `1,`) is still NOT supported,
* only the fully-bare separator. The regex engine (^ $ . * [...]
* \escape, no backreferences/intervals/ alternation) lives in
* src/liba/regex.s -- see that file's header for the exact
* grammar; ed.s never re-implements matching, only calls
* RE_MATCH. Full design notes: B.ED.TXT (docs/a2/)
*
* `j` (2026-08-19) -- [range]j joins the addressed lines into
* one line with no separator; default range is `.,.+1`. CHOSEN
* SEMANTICS (classic V7/POSIX, not GNU ed's variant): if the
* resolved range collapses to a single line (an explicit single
* address, or `.,.+1` at `.`==`$` would be out of range and is
* a `?` -- see ED_CHC_RNG12N), `j` is a NO-OP -- buffer AND `.`
* both left exactly as they were, nothing printed. A genuine
* multi-line join ALLOCATES a fresh combined line (ED_TEXTBUF's
* monotonic bump allocator -- see ED_CMD_T's header for why
* nothing here may mutate an existing line's bytes in place)
* and repoints only the range's first line-table slot; `.`
* becomes the joined line.
*
* `=` (2026-08-19) -- [addr]= prints the line number of addr
* (default `$`) as decimal, then CR, to stdout. At most one
* address (two is a `?`, same posture as a/i). Buffer and `.`
* are untouched -- `=` never assigns ED_CURLINE.
*---------------------------------------------------------------

            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/mm.procbnk2.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            org   LOAD_BASE
            dsk   ../../build/ed.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/regex.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

* -- ed's own private zero page, $30-$5F (regex.s separately
* claims -- $B0-$D1 -- see that file's header; both are chosen
* clear of zp.equ's -- $E0-$EB, by inspection, since neither
* module may edit zp.equ -- -- out of this task's scope). --
ED_CMDPTR   equ   $30        ;2  cursor into CMDBUF while
                             ;parsing a command
ED_LTPTR    equ   $32        ;2  scratch: a line-table SLOT
                             ;address
ED_SRC      equ   $34        ;2  scratch: source text pointer
ED_DST      equ   $36        ;2  scratch: dest text pointer
ED_TMP16    equ   $38        ;2  generic 16-bit scratch
ED_TMP16B   equ   $3A        ;2  generic 16-bit scratch #2
ED_ADDR1    equ   $3C        ;2  parsed first address
ED_ADDR2    equ   $3E        ;2  parsed second address
ED_ADDRCNT  equ   $40        ;1  0/1/2 -- how many addresses
                             ;were parsed
ED_CURLINE  equ   $41        ;2  '.' -- 0 means "before line
                             ;1"/empty buffer
ED_NLINES   equ   $43        ;2  '$' -- also the live line count
ED_TEXTPTR  equ   $45        ;2  bump allocator: next free byte
ED_GAFTER   equ   $47        ;2  text-entry mode's running
                             ;insert-after line
ED_GIDX     equ   $49        ;2  g command's scan index
ED_GEND     equ   $4B        ;2  g command's range end (shrinks
                             ;under g...d)
ED_SFLAGG   equ   $4D        ;1  s command: g flag seen
ED_SFLAGP   equ   $4E        ;1  s command: p flag seen
ED_DIDANY   equ   $4F        ;1  s/g: "matched/substituted at
                             ;least once"
ED_RFD      equ   $50        ;1  r command: fd of the file being
                             ;read
ED_RAFTER   equ   $51        ;2  r command: running insert-after
                             ;line
* window: $30-$52, 35 bytes.

*---------------------------------------------------------------
* 2026-08-19 audit fixes -- new ed-private ZP, growing the
* window
* past the old $30-$5F box (nothing else claims $60-$AF: regex.s
* has $B0-$D1, zp.equ has $E0-$EB -- see the box's own header
* comment). One flag/pair per finding, grouped by which fix owns
* it:
*---------------------------------------------------------------
ED_SFLAGN   equ   $5E        ;1  s command: numeric-occurrence
                             ;flag (`s/re/repl/N`) seen
ED_SNUM     equ   $5F        ;2  s command: the target
                             ;occurrence number N
ED_SUBOCC   equ   $61        ;2  s command: running match-
                             ;occurrence counter for THIS line
                             ;(ED_DO_SUBST)
ED_ADDRSTRT equ   $63        ;2  ED_PARSE1ADDR/ED_SEARCHFWD: the
                             ;address token's own start, so a
                             ;failed /re/ search can restore
                             ;ED_CMDPTR and keep its "carry
                             ;clear = untouched" contract honest
ED_MDEST    equ   $65        ;2  m/t: the parsed destination
                             ;address
ED_MIA      equ   $67        ;2  m/t: ED_DOMOVE's constant
                             ;insert-after cursor
ED_MCOUNT   equ   $69        ;2  m/t: ED_DOMOVE's down-counter
                             ;(lines left to relocate)
ED_MPTR     equ   $6B        ;2  m/t: ED_DOMOVE's line-pointer
                             ;scratch (survives the delete+
                             ;insert pair -- ED_SRC does not)
ED_TCUR     equ   $6D        ;2  t: phase-1 append loop's
                             ;source- line scan cursor
ED_TSTART   equ   $6F        ;2  t: NLINES just before phase 1,
                             ;i.e. one less than the appended
                             ;block's own first line
* -- j (join), added this round --
ED_JCUR     equ   $71        ;2  j: source line number the copy
                             ;loop is currently on
ED_JOUT     equ   $73        ;1  j: running output length in
                             ;SUBSCR (0-254 -- exbuf's own
                             ;descriptor length cap, M2 fix:
                             ;j now builds into SUBSCR and goes
                             ;through ED_BUMP_ALLOC/ED_SETSLOT
                             ;like every other command, instead
                             ;of poking a raw arena pointer).
                             ;$74 unused (was ED_JSTART's high
                             ;byte -- dead ZP, harmless).
ED_JTARGET  equ   $75        ;2  j: the join's target line
                             ;number (saved ADDR1 -- ED_ADDR1
                             ;itself gets repurposed for the
                             ;ED_DLT_RANGE sub-call)
ED_JSRC     equ   $77        ;2  j: current source line's read
                             ;cursor
ED_TEND     equ   $79        ;2  one past the text heap -- the
                             ;   CURRENT break, not a constant
ED_NEEDEND  equ   $7B        ;2  ED_ROOM in: one past the last
                             ;   byte the caller is about to
                             ;   write
* -- widened g/v (2026-09-02), edsub2.s's ED_CMD_G/ED_CMD_V --
ED_GNEG     equ   $7D        ;1  g=0 / v=1 -- RE_MATCH's carry
                             ;   sense is inverted for v
ED_GCMDPTR  equ   $7E        ;2  the command-list (cmds) text's
                             ;   own start, saved once by pass
                             ;   1 -- pass 2 (edparse.s
                             ;   MAINLOOP) resets ED_CMDPTR
                             ;   here every iteration, since
                             ;   cmds is re-parsed fresh per
                             ;   marked line
ED_GMCOUNT  equ   $80        ;1  pass 1's match count -- 0..
                             ;   GMARK_CAP, also ED_GMARK_INS/
                             ;   ED_GMARK_DEL/ED_GNEXT_MARK's
                             ;   own scan bound (edsub2.s); 0
                             ;   outside any g/v -- the fast-
                             ;   exit guard that makes those
                             ;   hooks free when idle
ED_GMODE    equ   $81        ;1  nonzero = MAINLOOP is driving
                             ;   pass 2 (edparse.s's own top) --
                             ;   set by ED_CMD_G/V, cleared by
                             ;   ED_GNEXT_MARK once no marks
                             ;   remain
* window now $30-$81, 82 bytes -- still clear of regex.s ($B0-
* $D1) and zp.equ ($E0-$EB).

*---------------------------------------------------------------
* Sizing constants (see file header "IN-BANK TEXT BUFFER").
*---------------------------------------------------------------
ED_JOINSEP   equ   0           ;ed `j`: no separator
ED_SNUM_LINES equ  0           ;ed s///N: Nth occurrence in line
ED_BARE_CUR  equ   0           ;ed bare ,/; = 1,$ / .,$
ED_NUM_RJUST equ  0           ;ed n: number + TAB
ED_ERR_QUIET equ  0           ;ed: always print `?`
ED_WGUARD    equ  0           ;ed w: overwrite, no guard
ED_R_DFLT_DOT equ 0           ;ed r (no addr): append at $
MAXLINES    equ   1024             ;line-table capacity (index
                                   ;1..MAXLINES)
GMARK_CAP   equ   250              ;widened g/v (2026-09-02):
                                   ;max simultaneously-pending
                                   ;matches ED_CMD_G's pass 1
                                   ;may mark (edsub2.s) -- a
                                   ;documented resource cap,
                                   ;same posture as diff.s's
                                   ;120-line-per-file MAXLINES
                                   ;or real ex's own finite
                                   ;limits (256 chars/global-
                                   ;command-list, 512/line)
                                   ;rather than the full
                                   ;MAXLINES worst case; pass 1
                                   ;refuses the WHOLE g/v with
                                   ;`?` before any mutation if
                                   ;exceeded, never partial
CMDBUF_MAXLEN equ 250              ;one command/text-entry/file
                                   ;line, incl NUL
PATBUF_MAXLEN equ 250
REPLBUF_MAXLN equ 250
SUBSCR_MAXLEN equ 512              ;scratch for one substituted
                                   ;line (>=2x a full line, room
                                   ;for a heavily-`g`'d
                                   ;replacement to grow past the
                                   ;original)
* -- ED_ROOM's sbrk() step: how much more heap to ask for when
* -- the text buffer runs out. Large enough that a 36KB session
* -- costs a handful of syscalls rather than a few thousand,
* -- and NOT load-bearing for correctness -- ED_ROOM re-reads
* -- the break with sbrk(0) afterwards rather than adding this
* -- constant to its own idea of it. That matters: an earlier
* -- draft did the add, which silently required the value to be
* -- page-aligned (the kernel keeps the break as a page NUMBER
* -- and rounds up), and setting it to $0040 to force repeated
* -- growth turned ed into a program that answered "?" to every
* -- append. Nothing here is tuned against the image size any
* -- more -- that was the whole point of retiring TEXTBUF_SIZE.
ED_GROW_SZ  equ   $1000

*---------------------------------------------------------------
* -- The body lives in three put modules below, split so this
* -- unit fits real Merlin-8's 41,215-byte source buffer
* -- (scripts/check_dialect.py budget 3): the resident manifest
* -- plus its largest single put must fit, and one 60KB file did
* -- not. Same put-module precedent as sed.s/sedexec.s; one
* -- assembly unit either way. They are put BEFORE the liba
* -- modules because Merlin cannot nest a put inside a put file,
* -- so every put line has to stand here in the manifest.
*---------------------------------------------------------------
            put   edparse.s
            put   edbuf.s
            put   edfile.s
            put   edfil2.s
            put   edsubst.s
            put   edsub2.s
LINETBL_SIZE equ MAXLINES*2+2     ;(MAXLINES+1) slots * 2 bytes
                                  ;-- merlin32's `ds` operand
                                  ;rejects parens, so written
                                  ;without them

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s
            put   ../liba/syscalls.s
            put   ../liba/brk.s
            put   ../liba/regex.s
            put   ../liba/regex2.s
            put   ../liba/argv.s
            put   ../liba/libabss.s
            put   ../liba/regexbss.s

*---------------------------------------------------------------
* ED_HEAP -- where this program's heap begins, and the one
* thing the kernel cannot work out for itself: brk() enforces
* the CEILING ($BF00, PRC_BRK_LIM), but only this file knows
* its own last emitted byte.
*
* Must stay the textually LAST thing in the file. A `dum`
* block's addresses are computed relative to the real PC at the
* point it opens, and anything emitted after `dend` resumes at
* that SAME real PC -- real code after this block would collide
* with the heap base it computes.
*
* THE 256-BYTE GAP IS DELIBERATE. docs/STICKY.md sec 21 puts a
* fixed kernel-zeroed page immediately after the image, so a
* heap starting at end-of-image would land on it. One page is
* nothing against a ~36KB heap and keeps this file correct
* whether that ruling has landed yet or not. START rounds up to
* a page boundary regardless: the kernel keeps the break as a
* page NUMBER.
*
* WHAT THIS REPLACED, and why it is not just tidiness:
*
*   TEXTBUF_SIZE equ 36480     ;~35.6KB, see above
*               dum   *
*   ED_TEXTBUF  ds    TEXTBUF_SIZE
*   ED_TEXTEND  equ   ED_TEXTBUF+TEXTBUF_SIZE
*
* 36480 was a hand-measured constant: build the file, subtract,
* type the number back in. It was 37000 until 2026-08-20, when
* liba's buffered-stream module linked in and pushed ed.bin to
* 46855 bytes against a 46848-byte window -- SEVEN bytes into
* the $BF00 MLI overlay page, with every gate still green. The
* trim bought margin; it did not remove the mechanism. ED_ROOM
* asks the kernel on every allocation instead, so the buffer
* now follows the image rather than being re-tuned after it.
*
* THE HEAP IS UNCLEARED, AND THAT IS CORRECT HERE (sec 21:
* whether a heap block is cleared is the caller's malloc-
* versus-calloc decision, not the system's). The arena was
* verified write-before-read when it was `dum` and the argument
* does not depend on where the storage comes from: every write
* goes through ED_BUMP_ALLOC or ED_JPUTBYTE, both of which only
* copy FROM already-initialized sources (CMDBUF, or an existing
* line's own text via ED_JSRC) and never read back a byte at
* (ED_TEXTPTR) before writing it. It is a pure monotonic bump
* allocator, write-only until a line pointer in ED_LINES hands
* a caller an address that was already written.
*---------------------------------------------------------------
*-- sec 21: chain onto liba's block. `dend` restores the PC
*-- `dum` saved, so a second block opening at `*` would be
*-- the SAME BYTES as liba's own.
            dum   REGEX_BSSEND
ED_ZPGRSV   ds    256
ED_WFORCE   ds    1     ;`w!` force flag (edfil2.s)

*-- ed's own bss, 3,708 bytes that used to be emitted `ds`
*-- zeros in ed.bin. They go AFTER ED_ZPGRSV and BEFORE
*-- ED_HEAP, and both halves of that are load-bearing:
*-- ED_ZPGRSV must stay the FIRST 256 bytes of this arena
*-- because that is the window the kernel actually zeroes, and
*-- ED_HEAP must stay past everything or the bump allocator
*-- would hand out addresses that alias these cells.
*-- The image shrinks by exactly what this arena grows, so
*-- ED_HEAP lands on the same address it did before.
*--
*-- NOTHING ZEROES THIS (sec 21). Read-before-write trace:
*--  - CMD_RDPOS/CMD_RDLEN and ED_CURFNAME: `stz`'d by START
*--    at its top, and THOSE THREE STORES ARE LOAD-BEARING --
*--    do not remove or reorder them below MAINLOOP. The
*--    command reader's refill test is `pos >= len`, which was
*--    true by accident only because `ds` emitted zeros;
*--    ED_CURFNAME[0]==0 IS the "no remembered filename" flag
*--    that a bare `w` tests before handing ProDOS a pathname.
*--  - R_RDPOS/R_RDLEN: `stz`'d by ED_CMD_R after its SC_OPEN
*--    succeeds. ED_RDFILELINE, the only reader, has exactly
*--    one caller and it is straight-line dominated by those
*--    two stores.
*--  - CMDBUF: NUL-terminated by ED_RDCMDLINE on BOTH exits
*--    (EOF and CR) before any parse reads it.
*--  - CMD_RDBUF/R_RDBUF: filled by SC_READ, and each length
*--    cell is set from the ACTUAL transfer count, not the 128
*--    requested -- so a short read lowers the ceiling and no
*--    stale tail is reachable.
*--  - PATBUF/REPLBUF: ED_COPYDELIM always stores a NUL, so a
*--    fresh non-empty token never sees stale bytes past its own
*--    end. `s//x/` (empty search field) now DELIBERATELY reuses
*--    whatever's in LASTPAT (edsubst.s's ED_LASTRE, "last
*--    regular expression", 2026-09-02) -- that's the feature,
*--    not a leftover-state bug -- and LASTPAT itself IS
*--    `stz`'d by START (edparse.s), same discipline as
*--    ED_CURFNAME just above, so "no prior RE yet" reads as
*--    empty rather than garbage.
*--  - SUBSCR: ED_SUBOUT is zeroed on every ED_DO_SUBST entry,
*--    ED_SUBPUTCHAR writes densely below it, and the NUL is
*--    planted at exactly ED_SUBOUT before the copy reads it.
*--  - PATHBUF: written by MKPATH (count byte last) or copied
*--    from ED_CURFNAME under its own length byte; the MLI
*--    reads only count+N.
*--  - NUMBUF: U2DEC always emits at least one digit and
*--    always writes the terminator before PUTS scans it.
*--  - ED_ABSBUF/ED_ABSBUF2 (XC2 2026-09-06): ED_ABSPATH always
*--    fills the WHOLE destination (count byte then N data
*--    bytes, or a straight verbatim copy on its fallback path)
*--    before ED_FNAME_EQ's fold loop ever reads either one.
*--  - ED_LINES: there is NO "is this line present" zero test
*--    in the file -- presence is ED_NLINES, which START
*--    zeroes. Slots 1..ED_NLINES are dense because
*--    ED_INSRT_AFTR writes the slot BEFORE it bumps the
*--    count, and slot 0 is rejected by ED_CHC_RNG12N. Every
*--    reader is bounded above by ED_NLINES.
CMDBUF      ds    CMDBUF_MAXLEN
* -- FF1 2026-09-06: a DEDICATED copy of a g/v's command-list
* -- text (edsub2.s's ED_CMD_G/ED_CMD_V), so a sub-command's own
* -- text read (ED_RDFILELINE into CMDBUF for r/r!/filter, or
* -- text-entry) can never clobber the bytes pass 2 still
* -- needs. See edsub2.s's header comment at the copy site.
GCMDBUF     ds    CMDBUF_MAXLEN
CMD_RDBUF   ds    128
CMD_RDPOS   ds    1
CMD_RDLEN   ds    1

R_RDBUF     ds    128
R_RDPOS     ds    1
R_RDLEN     ds    1

PATBUF      ds    PATBUF_MAXLEN
LASTPAT     ds    PATBUF_MAXLEN  ;the "last regular expression"
                                 ;(ED_LASTRE, edsubst.s) -- same
                                 ;size as PATBUF since it only
                                 ;ever holds a copy of one
REPLBUF     ds    REPLBUF_MAXLN
SUBSCR      ds    SUBSCR_MAXLEN

PATHBUF     ds    65
ED_CURFNAME ds    65           ;finding 3, 2026-08-19: the
                               ;remembered r/w filename, same
                               ;MLI length-prefixed shape as
                               ;PATHBUF
NUMBUF      ds    6

ED_ABSBUF   ds    65           ;XC2 2026-09-06: ED_ABSPATH's
ED_ABSBUF2  ds    65           ;canonical-form scratch, see the
ED_ABSLEN   ds    1            ;write-before-read trace above

* -- vi's ED_DISPATCH1 hook (docs/VI-DESIGN.md sec 5 item 2,
* -- edparse.s's MAINLOOP): storage only -- START zeroes
* -- ED_D1FLAG and `ed` never sets it, so this is permanently
* -- dead weight here, same posture as any other no-op hook's
* -- cost in the binary that doesn't use it.
ED_D1FLAG   ds    1
ED_D1RET    ds    2
ED_GLASSOUT ds    1           ;set by ED_PUTLINE (shared): the
                              ;command wrote to the glass. vi's
                              ;`:` landing prompts before its
                              ;repaint; ed never reads it

* -- EX2 2026-09-06: session error status, set by ED_ERR and
* -- checked by every normal EXIT path (edparse.s's ED_DOEXIT0,
* -- edfile.s's ED_CMD_Q). `ed` gets this too since it shares
* -- those routines -- it exits nonzero on error, matching real
* -- ed's own exit-status contract.
ED_ERRSTAT  ds    1

ED_LINES    ds    LINETBL_SIZE

* -- widened g/v (2026-09-02): the pending-match list,
* -- edsub2.s's ED_CMD_G/ED_GMARK_ADD/ED_GMARK_INS/
* -- ED_GMARK_DEL/ED_GNEXT_MARK. GMARK_CAP line numbers, 2
* -- bytes each, entries [0,ED_GMCOUNT) live -- 0 means
* -- "consumed/unset", same sentinel convention excmd.s's own
* -- EX_MARKS already uses (no line is ever 0). NOTHING ZEROES
* -- THIS array itself (sec 21,
* -- same discipline as ED_LINES below) -- ED_GMCOUNT stz'd
* -- by START and by ED_GNEXT_MARK's own exhaustion path is
* -- what bounds every reader; stale bytes past ED_GMCOUNT
* -- are never read.
ED_GMARKS   ds    GMARK_CAP*2

ED_HEAP     ds    0     ;dum label (was `equ *`) so
                        ;the REL bss can ENT it
*-- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end,
*-- and $BF00 tops the process window. check_modules'
*-- image-window gate cannot see it: a `dum` arena emits no
*-- bytes, so the .bin size says nothing about where the
*-- arena ENDS.
            err   */$BF00
            dend
