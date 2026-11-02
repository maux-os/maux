*---------------------------------------------------------------
* ex.s -- maux's swap-file-backed line editor, MILESTONE 1
* (docs/EX-DESIGN.md sec 5.6). Mirrors src/bin/ed.s's manifest
* exactly -- same ZP map, same command set (a c d i p n q r w s
* g m t j =), same regex engine -- with exactly ONE fork:
* exbuf.s stands where ed.s puts edbuf.s. Every other module
* (edparse.s/edfile.s/edfil2.s/edsubst.s/edsub2.s, and all of
* liba) is `put` UNCHANGED, byte-for-byte the same source files
* `ed` links.
*
* WHAT'S DIFFERENT FROM `ed`: the line table holds a 4-byte
* {offset,len} SWAP-FILE descriptor per line instead of a 2-byte
* RAM pointer -- text lives in a per-session swap file
* (EX.SWPxx), not the process bank, so ex can edit files bigger
* than a 64K bank. See exbuf.s's own header for the full
* mechanism and the one handoff convention that let every reused
* module stay byte-identical to `ed`'s copy.
*
* M1 SCOPE (docs/EX-DESIGN.md sec 5.6): load via swap (`r`),
* print (`p`/`,p`/`N`), substitute (`s`), write back byte-
* identically (`w`), quit and unlink the swap file (`q`).
*
* M2 (docs/EX-DESIGN.md sec 5.6, 2026-09-02): excmd.s adds
* `q!`/`wq`/`x`, marks (`k`/`mark`, `'x`, `''`), `?re?` backward
* search (a hook into edparse.s's shared ED_PARSE1ADDR), `u`
* single-level undo, `e`/`e!`, and `#`/`nu` numbered print (`n`
* itself stays RESERVED in ex -- the Ex Reference Manual v1.1
* primary source, learning:01M1FX8HT89CKR9CB8T8VKCW1S, settled
* that `n` means `next` in real ex, not numbered-print, which
* `ed`'s own `n` still means and keeps meaning unchanged). M2
* also fixed `j` (join): it now goes through the SAME accessor
* contract as every other command (see edsub2.s's ED_CMD_J and
* exbuf.s's header) instead of the raw-arena poke that used to
* corrupt the joined line.
*---------------------------------------------------------------

            lst   off
            xc
            put   ../../inc/mm.procbank.equ
            put   ../../inc/mm.procbnk2.equ
            put   ../../inc/mm.hw.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            put   ../../inc/sc.fdact.equ
            org   LOAD_BASE
            dsk   ../../build/ex.bin
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
* IDENTICAL to ed.s's own window, with ONE change: ED_MPTR is
* gone from here (exbuf.s's ED_DOMOVE needs it 4 bytes wide, and
* nothing ever dereferences it indirectly -- only its ADDRESS is
* taken -- so it moved to the `dum` bss tail below, where width
* costs nothing and nobody has to renumber this block).
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
ED_TEXTPTR  equ   $45        ;2  vestigial-arena bump pointer --
                             ;kept only so edsub2.s's `j`
                             ;(unchanged) still assembles -- see
                             ;exbuf.s's header
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

ED_SFLAGN   equ   $5E        ;1  s command: numeric-occurrence
                             ;flag (`s/re/repl/N`) seen
ED_SNUM     equ   $5F        ;2  s command: the target
                             ;occurrence number N
ED_SUBOCC   equ   $61        ;2  s command: running match-
                             ;occurrence counter for THIS line
                             ;(ED_DO_SUBST)
ED_ADDRSTRT equ   $63        ;2  ED_PARSE1ADDR/ED_SEARCHFWD: the
                             ;address token's own start
ED_MDEST    equ   $65        ;2  m/t: the parsed destination
                             ;address
ED_MIA      equ   $67        ;2  m/t: ED_DOMOVE's constant
                             ;insert-after cursor
ED_MCOUNT   equ   $69        ;2  m/t: ED_DOMOVE's down-counter
                             ;(lines left to relocate)
* -- ED_MPTR ($6B-$6C in ed.s) is NOT here -- see this block's
* -- own header note. $6B-$6C is free in ex's ZP window.
ED_TCUR     equ   $6D        ;2  t: phase-1 append loop's
                             ;source- line scan cursor
ED_TSTART   equ   $6F        ;2  t: NLINES just before phase 1,
                             ;i.e. one less than the appended
                             ;block's own first line
ED_JCUR     equ   $71        ;2  j: source line number the copy
                             ;loop is currently on
ED_JOUT     equ   $73        ;1  j: running output length in
                             ;SUBSCR (0-254 -- exbuf's own
                             ;descriptor length cap; M2 fix, see
                             ;ed.s's own comment for this cell).
                             ;$74 unused (dead ZP, harmless).
ED_JTARGET  equ   $75        ;2  j: the join's target line
                             ;number (saved ADDR1)
ED_JSRC     equ   $77        ;2  j: current source line's read
                             ;cursor
ED_TEND     equ   $79        ;2  one past the vestigial arena --
                             ;see ED_TEXTPTR above
ED_NEEDEND  equ   $7B        ;2  ED_ROOM in: one past the last
                             ;   byte the caller is about to
                             ;   write
* -- widened g/v (2026-09-02), edsub2.s's ED_CMD_G/ED_CMD_V --
* -- SAME cells/meanings as ed.s's own copy of this block. --
ED_GNEG     equ   $7D        ;1  g=0 / v=1 -- RE_MATCH's carry
                             ;   sense is inverted for v
ED_GCMDPTR  equ   $7E        ;2  the command-list (cmds) text's
                             ;   own start, saved once by pass
                             ;   1 -- pass 2 (edparse.s
                             ;   MAINLOOP) resets ED_CMDPTR
                             ;   here every iteration
ED_GMCOUNT  equ   $80        ;1  pass 1's match count -- 0..
                             ;   GMARK_CAP; 0 outside any g/v
ED_GMODE    equ   $81        ;1  nonzero = MAINLOOP is driving
                             ;   pass 2
* window now $30-$81, 80 bytes (2 fewer than ed's, ED_MPTR moved
* out) -- still clear of regex.s ($B0-$D1) and zp.equ ($E0-$EB).

*---------------------------------------------------------------
* Sizing constants. MAXLINES raised for the swap design's own
* headline (docs/EX-DESIGN.md sec 5.4): the descriptor table is
* the one thing still living in the process bank, so M1 gives it
* a bigger FIXED size than ed's 1024 -- true growability is a
* named follow-up (sec 5.4), not needed to prove the swap-file
* mechanism end to end. 2048 slots * 4 bytes = 8,196 bytes
* (including the unused slot 0).
*---------------------------------------------------------------
ED_JOINSEP   equ   1           ;ex `j`: space (POSIX)
ED_SNUM_LINES equ  1           ;ex s///N: line count (POSIX)
ED_BARE_CUR  equ   1           ;ex bare ,/; = .,. (POSIX)
ED_NUM_RJUST equ  1           ;ex #/nu: rt-just + space
ED_ERR_QUIET equ  1           ;ex: silent `?` in script mode
ED_WGUARD    equ  1           ;ex w PATH: `w!` guard
ED_R_DFLT_DOT equ 1           ;ex r (no addr): insert at . (FF3)
MAXLINES    equ   2048
GMARK_CAP   equ   250              ;widened g/v (2026-09-02) --
                                   ;see ed.s's own copy of this
                                   ;equ for the rationale (SAME
                                   ;documented resource cap for
                                   ;both binaries)
CMDBUF_MAXLEN equ 250              ;one command/text-entry/file
                                   ;line, incl NUL -- unchanged;
                                   ;still under exbuf's 254-byte
                                   ;descriptor length cap
PATBUF_MAXLEN equ 250
REPLBUF_MAXLN equ 250
SUBSCR_MAXLEN equ 512
ED_GROW_SZ  equ   $1000            ;vestigial-arena growth step
                                   ;-- see ED_TEXTPTR above

*---------------------------------------------------------------
* Process entry (spawn() JMPs to LOAD_BASE -- startup.equ's
* contract, unchanged). ONE thing must happen before edparse.s's
* START runs that START itself (reused unchanged) does not know
* about: EXSW_OPEN, the swap-file lazy-open guard, must start at
* a KNOWN value. docs/STICKY.md sec 21 zeroes only a fixed
* 256-byte page, and ed.s's own bss (which this file's tail
* mirrors) explicitly does NOT rely on it for anything -- every
* cell that needs a known start is `stz`'d by code instead
* (ed.s's own "read-before-write trace" comment, further down).
* This is that same discipline applied to ex's one new flag,
* without touching edparse.s (EX-DESIGN.md sec 5.3: "costs zero
* edits to edparse.s's START") -- a few bytes here, then falls
* straight through into edparse.s's own START code below (no
* `jmp` needed; `put` is textual inclusion, so this is one
* contiguous instruction stream).
* M2 (2026-09-02): the SAME discipline extended to excmd.s's own
* new state -- EX_DIRTY/EX_HASUNDO/EX_SHDNLIN/EX_SHDCUR/
* EX_EFORCE/EX_MARKS are declared CONTIGUOUSLY below (61 bytes)
* precisely so this one loop can zero all of them without a
* per-cell `stz` list. EX_CPLEN/EX_SHADOW need no zeroing
* (write-before-read: EX_SNAPSHOT/EX_BLKCOPY/EX_BLKSWAP always
* fill EX_CPLEN fresh before any read, and EX_SHADOW is only
* ever read after EX_HASUNDO says a real snapshot landed there).
*---------------------------------------------------------------
            stz   EXSW_OPEN
            ldx   #60
:ex_zloop   stz   EX_DIRTY,x
            dex
            bpl   :ex_zloop
            jmp   START           ;skip EX_ONQUIT's dead-in-
                                  ;`ex` body below -- nothing
                                  ;may fall through to a bare
                                  ;`rts`

*---------------------------------------------------------------
* EX_ONQUIT -- no-op for `ex` (docs/VI-DESIGN.md sec 5 item 3).
* excmd.s's EX_CQBANG/EX_CWQ/EX_XCORE call this unconditionally,
* right before each successful EXIT, so vi (which reuses excmd.s
* UNCHANGED) can restore its saved tty mode there. `ex` itself
* never touches SYS_TTYMODE -- it is always cooked -- so this
* stays an RTS, same no-op-stub shape ED_QCLEANUP/EX_ONWRITE use
* in edbuf.s for the ed-side of THEIR fork. The fork point here
* is different (excmd.s is shared verbatim by ex.s AND vi.s, so
* neither edbuf.s nor exbuf.s can carry the two bodies) -- each
* top-level manifest supplies its own EX_ONQUIT instead; vi.s's
* real version lives in vicmd.s.
*---------------------------------------------------------------
EX_ONQUIT   rts

*---------------------------------------------------------------
* EX_ONSPAWN / EX_ONSPAWNED -- no-ops for `ex`, same fork as
* EX_ONQUIT above. excmd2.s's EX_BG_SPAWN/EX_BG_SPAWN2 call them
* around every `!`-family child (2026-09-07): vi's real bodies
* (vicmd.s) hand the console to the child cooked+echo and take
* raw mode back after; `ex` is cooked throughout.
*---------------------------------------------------------------
EX_ONSPAWN  rts
EX_ONSPAWNED rts

            put   edparse.s
            put   exbuf.s
            put   edfile.s
            put   edfil2.s
            put   edsubst.s
            put   edsub2.s
            put   excmd.s
            put   excmd2.s
            put   exname.s
LINETBL_SIZE equ MAXLINES*4+4     ;(MAXLINES+1) slots * 4 bytes
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
            put   ../liba/seek.s
            put   ../liba/brk.s
            put   ../liba/regex.s
            put   ../liba/regex2.s
            put   ../liba/argv.s
            put   ../liba/syscallp.s   ;SC_SPAWN/SC_WAIT -- the
                                       ;`!` family (excmd.s)
            put   ../liba/env.s        ;GETENV -- PATHRSLV's own
                                       ;dependency
            put   ../liba/pathres.s    ;PATHRSLV -- resolve `sh`
                                       ;against PATH/PATHTAB
            put   ../liba/pathtab.s    ;the default search path
            put   ../liba/libabss.s
            put   ../liba/regexbss.s

*---------------------------------------------------------------
* ED_HEAP -- see ed.s's own header for the full rationale (this
* is the same mechanism, unchanged): must stay the textually
* LAST
* thing in the file, one page gap on purpose for the kernel's
* fixed 256-byte zeroed page. The vestigial arena above ED_HEAP
* is still real (edsub2.s's `j` bump-allocates into it -- see
* exbuf.s's header) -- ED_ROOM/SC_SBRK still establish it
* exactly
* as edparse.s's START already does, unmodified.
*
* ex's own bss adds nine cells past what ed.s declares (all pure
* scratch -- see exbuf.s's data-section comment for the write-
* before-read trace on every one of them): EX_DESCSCR/
* EX_SEEKBUF/EX_LINECACHE (transient per-call scratch),
* ED_SHIFT4/ED_MPTR (transient per-call scratch, widened/moved
* out of ZP -- see this file's ZP block), EX_WLEN/EX_WSRC
* (ED_BUMP_ALLOC's own transient scratch), and the swap session
* state EXSW_FD/EXSW_END/EXSW_NAME/EXSW_PATH (EXSW_OPEN itself
* stays where it always was possible to reach from the entry
* stub above -- see that comment). LINETBL_SIZE (2048 lines * 4
* bytes) replaces ed's 1024*2, so ED_LINES alone is ~6KB bigger
* than ed's -- well inside the ~40KB of headroom EX-DESIGN.md
* sec 2.4 measured.
*---------------------------------------------------------------
            dum   REGEX_BSSEND
ED_ZPGRSV   ds    256
ED_WFORCE   ds    1     ;`w!` force flag (edfil2.s)

CMDBUF      ds    CMDBUF_MAXLEN
* -- FF1 2026-09-06: dedicated copy of a g/v's command-list text
* -- -- see ed.s's copy of this comment / edsub2.s's copy site.
GCMDBUF     ds    CMDBUF_MAXLEN
CMD_RDBUF   ds    128
CMD_RDPOS   ds    1
CMD_RDLEN   ds    1

R_RDBUF     ds    128
R_RDPOS     ds    1
R_RDLEN     ds    1

PATBUF      ds    PATBUF_MAXLEN
LASTPAT     ds    PATBUF_MAXLEN  ;the "last regular expression"
                                 ;(ED_LASTRE, edsubst.s) --
                                 ;shared with `ed`, same size as
                                 ;PATBUF
REPLBUF     ds    REPLBUF_MAXLN
SUBSCR      ds    SUBSCR_MAXLEN

PATHBUF     ds    65
ED_CURFNAME ds    65
NUMBUF      ds    6

* -- XC2 2026-09-06: ED_ABSPATH's own canonical-form scratch
* -- (edfile.s) -- ED_FNAME_EQ's compare buffers, always fully
* -- written before either is read.
ED_ABSBUF   ds    65
ED_ABSBUF2  ds    65
ED_ABSLEN   ds    1

* -- vi's ED_DISPATCH1 hook (docs/VI-DESIGN.md sec 5 item 2,
* -- edparse.s's MAINLOOP): storage only -- `ex`'s own START
* -- (edparse.s) zeroes ED_D1FLAG and never sets it again, so
* -- this is dead weight here, same posture as any other no-op
* -- hook's cost in the binary that doesn't use it.
ED_D1FLAG   ds    1
ED_D1RET    ds    2

* -- EX2 2026-09-06: session error status -- see ed.s's own
* -- comment on its copy of this cell for the full rationale.
ED_ERRSTAT  ds    1

* -- EX-BADCMD: exname.s's scratch and the last refusal's text.
* -- EX_MSGP's high byte is zeroed before a vi `:` dispatch
* -- (vicmd.s) and set by EX_ERRMSG; EX_MSGBUF is "word: Not an
* -- editor command" at the longest (12 + 2 + 21 + NUL).
EXN_WLEN    ds    1
EXN_N       ds    1
EX_MSGP     ds    2
EX_MSGBUF   ds    40

ED_LINES    ds    LINETBL_SIZE

* -- widened g/v (2026-09-02): the pending-match list,
* -- edsub2.s's ED_CMD_G/ED_GMARK_ADD/ED_GMARK_INS/
* -- ED_GMARK_DEL/ED_GNEXT_MARK -- SAME shape as ed.s's own
* -- copy (that file's comment has the sentinel/zero-init
* -- rationale).
ED_GMARKS   ds    GMARK_CAP*2

* -- exbuf.s's own scratch (see that file's data-section comment
* -- for the write-before-read trace on each). --
EX_DESCSCR  ds    4
EX_SEEKBUF  ds    3
EX_LINECACHE ds   255
ED_SHIFT4   ds    4
ED_MPTR     ds    4
EX_WLEN     ds    1
EX_WSRC     ds    2
EXSW_OPEN   ds    1
EXSW_FD     ds    1
EXSW_END    ds    3
EXSW_NAME   ds    9
EXSW_PATH   ds    65

* -- excmd.s's `!` family (EX_CBANG/EX_WBANG/EX_RBANG) scratch:
* -- three temp-file name/path pairs (EX.INxx/EX.OUTxx/
* -- EX.CMDxx, same EXSW_NAME/EXSW_PATH convention above), two
* -- transient fd cells, the argv/fdactions arrays SC_SPAWN
* -- reads, and the 1-byte SC_WAIT status buffer. All write-
* -- before-read per call -- see excmd.s's own header for each.
EX_BG_INNM   ds    9
EX_BG_INPTH  ds    65
EX_BG_OUTNM  ds    9
EX_BG_OUTPTH ds    65
EX_BG_CMDNM  ds    9
EX_BG_CMDPTH ds    65
EX_BG_FD     ds    1
EX_BG_IRFD   ds    1
EX_BG_ARGV   ds    6
EX_BG_FDACT  ds    7
EX_BG_WSTAT  ds    1
EX_BG_OWFD   ds    1
ED_GLASSOUT  ds    1          ;1 = this command wrote to the
                              ;glass (ED_PUTLINE's line prints,
                              ;`:!cmd`'s child) -- vi's `:`
                              ;landing (vicmd.s :vc_ret) shows
                              ;[Hit return to continue] before
                              ;its repaint; ex never reads it

* -- excmd.s's own state (M2, 2026-09-02). EX_DIRTY..EX_MARKS
* -- (61 bytes) MUST stay contiguous and in this order -- the
* -- entry stub's zero-init loop above depends on it. See
* -- excmd.s's own header for what each cell is for.
EX_DIRTY    ds    1
EX_HASUNDO  ds    1
EX_SHDNLIN  ds    2
EX_SHDCUR   ds    2
EX_EFORCE   ds    1
EX_MARKS    ds    54          ;27 slots x 2 bytes: index 0-25 =
                              ;marks a-z, index 26 (bytes 52-53)
                              ;= the '' previous-context slot
EX_CPLEN    ds    2           ;EX_BLKCOPY/EX_BLKSWAP's own
                              ;16-bit byte counter -- write-
                              ;before-read every call, no zero-
                              ;init needed
EX_FSTART   ds    2           ;FF4 (2026-09-06): EX_BANG_FILT's
                              ;own pre-read ED_RAFTER, so it can
                              ;set dot to the FIRST inserted
                              ;line (POSIX) instead of
                              ;ED_READLOOP's own last-line
                              ;default -- write-before-read
                              ;every call
* EX_SHADOW moved to the language card ($D000) -- see the dum
* block after this dend. Was 8196 low-window bytes.
ED_HEAP     ds    0     ;dum label, unchanged shape from ed.s
            err   */$BF00
            dend

* The undo shadow table lives in the process LANGUAGE CARD, out
* of the low window entirely. ALTZP maps it per-process;
* EX_SNAPSHOT / EX_UNDO_CORE (excmd.s) bracket every access with
* LCBANK2_RAM / LCBANK2_STORE. Written before read.
            dum   $D000
EX_SHADOW   ds    LINETBL_SIZE
            err   */PRC_LC_TOP      ;below the door
            dend
