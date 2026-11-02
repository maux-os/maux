*---------------------------------------------------------------
* vi.s -- maux's screen editor: FOUNDATION + LIVING SLICE
* (docs/VI-DESIGN.md). Mirrors ex.s's manifest almost exactly --
* SAME ZP map for the reused ed/ex modules, SAME reused files
* (edparse.s/exbuf.s/edfile.s/edfil2.s/edsubst.s/edsub2.s/
* excmd.s, put UNCHANGED) -- plus vi's own new modules
* (viscreen.s/vimotion.s/viinsert.s/vicmd.s/visearch.s), wired
* through the four small shared-module hooks docs/VI-DESIGN.md
* sec 5 names: ED_STARTFILE (edparse.s), ED_DISPATCH1
* (edparse.s), EX_ONQUIT (excmd.s, real body here in vicmd.s),
* EX_UNDO_CORE (excmd.s).
*
* SCOPE SO FAR (not the fan-out): `vi FILE` opens, h/j/k/l
* motion + scroll + repaint, `i a A I o O` insert-entry variants
* (raw byte loop, live echo, ESC exits -- viinsert.s), `/ ? n N`
* search sharing ex's own last-RE (visearch.s), `:` drops one
* command into the real ex engine via ED_DISPATCH1, `ZZ` writes-
* if-dirty and quits, `u` single-level undo. The full command
* set (w/b/e word motion, d/c/y operators, `.`-repeat, R/r/~,
* named registers, marks-as-motions) is the command-module
* fan-out this foundation hands off to -- viop.s does not exist
* yet (docs/VI-DESIGN.md sec 6 permits stubs; v1 has no
* operators to give it a body).
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
            put   ../../inc/errno.krn.equ
            org   LOAD_BASE
            dsk   ../../build/vi.bin
            typ   $00

            put   ../../inc/zp.equ
            put   ../../inc/regex.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

* -- ed/ex's own private zero page, $30-$81 -- COPIED VERBATIM
* -- from ex.s (same addresses -- edparse.s/exbuf.s/edfil2.s/
* -- edsubst.s/edsub2.s/excmd.s all reference these names
* -- directly, unchanged, and must resolve identically here).
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
ED_CURLINE  equ   $41        ;2  '.' -- vi's OWN line cursor too
                             ;(shared cell -- 0 means "before
                             ;line 1"/empty buffer); this is
                             ;deliberate, not an oversight: `:s`
                             ;with no address defaults to `.`,
                             ;so vi's cursor motions must move
                             ;the SAME cell the `:` bridge reads
ED_NLINES   equ   $43        ;2  '$' -- also the live line count
ED_TEXTPTR  equ   $45        ;2  vestigial-arena bump pointer --
                             ;kept only so edsub2.s's `j`
                             ;(unchanged) still assembles
ED_GAFTER   equ   $47        ;2  text-entry mode's running
                             ;insert-after line
ED_GIDX     equ   $49        ;2  g command's scan index
ED_GEND     equ   $4B        ;2  g command's range end
ED_SFLAGG   equ   $4D        ;1  s command: g flag seen
ED_SFLAGP   equ   $4E        ;1  s command: p flag seen
ED_DIDANY   equ   $4F        ;1  s/g: "matched at least once"
ED_RFD      equ   $50        ;1  r command: fd of file read
ED_RAFTER   equ   $51        ;2  r command: running insert-after
                             ;line
* window: $30-$52, 35 bytes.

ED_SFLAGN   equ   $5E        ;1  s command: numeric-occurrence
                             ;flag seen
ED_SNUM     equ   $5F        ;2  s command: target occurrence N
ED_SUBOCC   equ   $61        ;2  s command: running match count
ED_ADDRSTRT equ   $63        ;2  address token's own start
ED_MDEST    equ   $65        ;2  m/t: parsed destination address
ED_MIA      equ   $67        ;2  m/t: ED_DOMOVE's insert-after
ED_MCOUNT   equ   $69        ;2  m/t: ED_DOMOVE's down-counter
* -- ED_MPTR ($6B-$6C in ed.s) is NOT here -- exbuf.s's own
* -- ED_MPTR lives in the `dum` bss tail, same as ex.s.
ED_TCUR     equ   $6D        ;2  t: append loop's scan cursor
ED_TSTART   equ   $6F        ;2  t: NLINES just before phase 1
ED_JCUR     equ   $71        ;2  j: source line, copy loop
ED_JOUT     equ   $73        ;1  j: running output length
ED_JTARGET  equ   $75        ;2  j: join's target line number
ED_JSRC     equ   $77        ;2  j: current source line cursor
ED_TEND     equ   $79        ;2  one past the vestigial arena
ED_NEEDEND  equ   $7B        ;2  ED_ROOM in
ED_GNEG     equ   $7D        ;1  g=0 / v=1
ED_GCMDPTR  equ   $7E        ;2  the command-list text's start
ED_GMCOUNT  equ   $80        ;1  pass 1's match count
ED_GMODE    equ   $81        ;1  nonzero = MAINLOOP driving g/v
                             ;pass 2
* window now $30-$81, 80 bytes -- clear of regex.s ($B0-$D1) and
* zp.equ ($E0-$EB), same as ex.s's own copy of this block.

* -- vi's OWN zero page, $82-$93 (18 bytes) -- clear of the
* -- block above, regex.s's $B0-$D1, and zp.equ's $E0-$EB, by
* -- the same inspection ex.s's own header already did for its
* -- window.
VI_CURCOL   equ   $82        ;1  byte offset into the current
                             ;line's text (0-based)
VI_TOP      equ   $83        ;2  buffer line number shown at the
                             ;first TEXT row (row 1 -- row 0 is
                             ;the console's own reserved status
                             ;line, docs/CONSOLE.md sec 6)
VI_MODE     equ   $85        ;1  0=command 1=insert 2=cmdline
VI_SAVEMD   equ   $86        ;1  SC_TTYMODE's previous flags,
                             ;saved at entry, restored on every
                             ;exit path
VI_ROWS     equ   $87        ;1  SYS_TTYGEO rows, cached once
VI_COLS     equ   $88        ;1  SYS_TTYGEO cols, cached once
VI_SCRROW   equ   $89        ;1  cursor's on-screen row, 1-based
VI_SCRCOL   equ   $8A        ;1  cursor's on-screen col, 1-based
VI_LLEN     equ   $8B        ;1  current line's cached text
                             ;length (viscreen.s/vimotion.s)
VI_TMP      equ   $8C        ;2  scratch
VI_TMP2     equ   $8E        ;2  scratch
VI_KEY      equ   $90        ;1  the last raw key read
VI_INSLEN   equ   $91        ;1  viinsert.s: running length of
                             ;VI_LBUF's accumulator while in
                             ;insert mode
* window: $82-$91, 16 bytes.

* -- MOTION-SET addition (this task): $90-$A2 is ALREADY
* -- regex.equ's own RE_GNTARG..RE_GMARK group (RE_GROUPNUM/
* -- RE_GSTAR, `\(..\)`/`\1`-`\9` grouping) -- overlapping
* -- VI_KEY/VI_INSLEN above, an existing collision this task
* -- did NOT introduce (VI_KEY is dead/unused; VI_INSLEN is only
* -- ever live within ONE routine's own short-lived read loop,
* -- never held across a call into the ex engine/regex, same
* -- discipline every cell below follows). $A3-$AF is the first
* -- genuinely CLEAR gap after that group (confirmed by grepping
* -- every equ file this binary `put`s -- zp.equ's own $90-$A2
* -- users end at RE_GMARK+1=$A3) and before regex.s's other
* -- block at $B0-$D1. None of these new cells is ever live
* -- across a `:`-bridge/ED_DISPATCH1 call (VI_DOMOTION and its
* -- callers run entirely within one raw-key command, same as
* -- VI_INSLEN's own established safety argument above).
VI_COUNT    equ   $A3        ;2  pending count prefix
                             ;(vimotion.s VI_READCMD) --
                             ;0 = none = 1
VI_MO_L1    equ   $A5        ;2  VI_DOMOTION OUT: target line
                             ;(also the word/find motions' own
                             ;working position while computing)
VI_MO_C1    equ   $A7        ;1  VI_DOMOTION OUT: target column
VI_MO_TYPE  equ   $A8        ;1  VI_DOMOTION OUT: 0 charwise
                             ;exclusive, 1 charwise inclusive,
                             ;2 linewise
VI_FCHAR    equ   $A9        ;1  last f/F/t/T target char (low
                             ;7 bits only -- normalized once at
                             ;capture, see vimotion.s), for `;`/
                             ;`,` repeat
VI_FCMD     equ   $AA        ;1  last f/F/t/T command char (0 =
                             ;none yet -- `;`/`,` fail)
VI_BIGF     equ   $AB        ;1  0 = small word (w/b/e), 1 = big
                             ;WORD (W/B/E) -- transient, set/
                             ;cleared around each word-motion
                             ;dispatch
* window: $A3-$AB, 9 bytes.

* -- viop.s's own 2 bytes, the last of the $A3-$AF gap this
* -- file's own comment above already named clear (before
* -- regex.s's $B0-$D1 block) -- VI_SPAN_NORM's own OUT, live
* -- only within one operator command's own call tree, same
* -- short-lived-scratch discipline as everything above.
VI_SPSC     equ   $AC        ;1  charwise span: start column
VI_SPEC     equ   $AD        ;1  charwise span: end column
                             ;(EXCLUSIVE)

* -- vicache.s's own 2 bytes, the last of the $A3-$AF gap --
* -- live only within one VI_LTEXTC call, same short-lived-
* -- scratch discipline as VI_SPSC/VI_SPEC above.
VC_SPTR     equ   $AE        ;2  slot-scan/build pointer
* window: $A3-$AF, 13 bytes -- FULL now.

*---------------------------------------------------------------
* vicache.s's repaint-only line cache -- W3 (docs/VI-DESIGN.md).
* ED_LINETEXT costs an LSEEK+READ per line (~4.8k cycles);
* a full repaint re-fetches every visible line every time even
* though the swap is append-only (a line's 4-byte descriptor
* never changes once written -- exbuf.s's own header). This
* caches by that descriptor: a hit skips the syscalls entirely.
*
* RAM WALL, measured 2026-09-05 (empirically, not estimated):
* assembling this file with `merlin32 -v1` and reading the
* listing puts the last BSS symbol (ED_HEAP) at $B31F; the
* ceiling is BF00_OVERLAY=$BF00 (mm.procbnk2.equ), a
* ProDOS MLI reserved page, enforced below by `err */$BF00`.
* Pinned the exact boundary by bisecting a throwaway `ds`
* there: 3040 more bytes assembles clean, 3041 fails the err
* line ('evaluation is 0x1'). So vicache.s's own BSS (added at
* the tail, below) has EXACTLY 3040 bytes to work with, no more
* -- an earlier $9918-based estimate (VI_LBUF, not the true
* tail) overstated this by ~6.5KB. That 3040 is why the slot
* count/width below are what they are, not 32 or 24 slots of a
* full 255-byte line each (8321B/6241B -- both would have blown
* the wall): 28 slots x 86 bytes (4-byte key + 1 flags byte +
* 80 chars + NUL) = 2408B + 1-byte round-robin index = 2409B
* of BSS. NOTE: the 3040B figure above is BSS-only headroom
* BEFORE vicache.s existed -- its own CODE (VI_LTEXTC/
* VI_CACHE_ZR/VC_SLOTADR, ~256B) sits ahead of the `dum`
* boundary and eats the SAME wall, since ED_HEAP is dum'd right
* after all code. Measured after linking both in: ED_HEAP ends
* at $BD8B, leaving 372B before the wall -- re-measure with
* `merlin32 -v1` before adding anything else here.
* -- VI_RAWKEY's FRAMED ARROW codes (2026-09-10). The kernel
* -- commits an arrow as ONE 3-byte line ESC [ A..D (tty7.s
* -- TTY_COOK_RAW); VI_RAWKEY reads 3 at a time and hands back
* -- one of these instead. Below $80, so they can never collide
* -- with a keyboard byte (every raw byte has bit 7 set). The
* -- final's low 3 bits: $C1..$C4 -> 1..4.
VI_KUP      equ   1
VI_KDOWN    equ   2
VI_KRIGHT   equ   3
VI_KLEFT    equ   4           ;the //e's BACKSPACE key: ^H, one
                              ;wire (Sather) -- erase in insert
* -- Caught-signal numbers (docs/SIGNALS.md). HERE, not vicmd.s,
* -- because vimotion.s (put earlier) uses VI_SIGTSTP and a
* -- same-tree forward `equ` is illegal on real Merlin-8.
VI_SIGINT   equ   2           ;^C -- shell trap's `kill -2 $$`
VI_SIGTSTP  equ   14          ;cooperative ^Z: VI_SUSPEND rmcups
                              ;before the stop, smcups after
VI_KQUOTE   equ   $A2         ;the `"` key (a register prefix)
VI_RGU      equ   26          ;the unnamed multi-line register's
                              ;arena entry (virg.s)
VI_RGCAP    equ   3700        ;register arena bytes (LC,
                              ;dum block below); a store fits
                              ;only while the arena stays UNDER
                              ;this, so 3699 usable (virg.s)
VI_DOTCAP   equ   96          ;`.`-repeat keystroke buffer cap
                              ;(vicmd.s) -- a change command
                              ;longer than this (a big insert)
                              ;is not dot-repeatable, marked so
                              ;and `.` no-ops on it
VI_NCACHE   equ   28          ;cache slot count. 28 (from 13)
                              ;2026-09-05 when EX_SHADOW moved
                              ;to the language card, freeing
                              ;~8 KB low window (ED_HEAP $BC6C
                              ;-> under $A400 at 28). 28 covers
                              ;a full 23-row page plus scroll
                              ;margin: an unedited repaint
                              ;never touches the swap file.
                              ;See the EX_SHADOW dum block
                              ;after the BSS dend below.
VC_SLOTSZ   equ   86          ;4 key + 1 flags + 81 text (80
                              ;chars + NUL) -- a line over 80
                              ;chars sets the TRUNCATED flag
                              ;and is never served from a slot
                              ;(vicache.s's own header has the
                              ;full contract)

ED_JOINSEP   equ   1           ;vi `J`: space (POSIX)
ED_SNUM_LINES equ  1           ;vi s///N: line count (POSIX)
ED_BARE_CUR  equ   1           ;vi bare ,/; = .,. (POSIX)
ED_NUM_RJUST equ  1           ;vi #/nu: rt-just + space
ED_ERR_QUIET equ  0           ;vi: always show `?`
ED_WGUARD    equ  1           ;vi w PATH: `w!` guard
ED_R_DFLT_DOT equ 1           ;vi r (no addr): insert at . (FF3)
MAXLINES    equ   2048
GMARK_CAP   equ   250
CMDBUF_MAXLEN equ 250
PATBUF_MAXLEN equ 250
REPLBUF_MAXLN equ 250
SUBSCR_MAXLEN equ 512
ED_GROW_SZ  equ   $1000

VI_LBUFLEN  equ   250         ;vi's own scratch line -- the `:`
                              ;bridge's status-row read buffer
                              ;AND insert mode's growing text,
                              ;capped like every other line
                              ;buffer in this tree

*---------------------------------------------------------------
* Process entry. Same EXSW_OPEN/EX_DIRTY..EX_MARKS zero-init as
* ex.s (unchanged reason -- exbuf.s/excmd.s need it), but then
* vi.s jumps straight to ITS OWN entry (VI_START, vicmd.s)
* instead of falling into edparse.s's classic START -- vi drives
* its own raw-key command loop, not the fd-0 MAINLOOP `ed`/`ex`
* use.
*---------------------------------------------------------------
            stz   EXSW_OPEN
            ldx   #60
:vi_zloop   stz   EX_DIRTY,x
            dex
            bpl   :vi_zloop
            stz   VI_LNCNT      ;no lines painted yet (wrap
                                ;row table, viscreen.s)
            stz   VI_DOTLEN     ;no last change yet -- first `.`
            stz   VI_DOTPLAY    ;is a no-op (vicmd.s)
            stz   VI_STMSG      ;no pending status banner
            jsr   VI_RG_INIT    ;registers empty (virg.s)
            stz   VI_NOLAND     ;searches land normally
            jsr   VI_CACHE_ZR   ;vicache.s -- the swap opens
                                ;once per process (EXSW_OPEN
                                ;above), so this is the one
                                ;place cache keys ever need
                                ;invalidating (vicache.s header)
            jmp   VI_START

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

            put   viscreen.s
            put   vimotion.s
            put   vipage.s
            put   viinsert.s
            put   vicmd.s
            put   visearch.s
            put   viop.s
            put   viop2.s
            put   virep.s
            put   virg.s
            put   vicache.s

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/num.s
            put   ../liba/syscalls.s
            put   ../liba/syscallp.s
            put   ../liba/env.s        ;GETENV -- PATHRSLV's own
                                       ;dependency (the `!`
                                       ;family, shared verbatim)
            put   ../liba/pathres.s    ;PATHRSLV -- resolve `sh`
            put   ../liba/pathtab.s    ;the default search path
            put   ../liba/seek.s
            put   ../liba/brk.s
            put   ../liba/regex.s
            put   ../liba/regex2.s
            put   ../liba/argv.s
            put   ../liba/libabss.s
            put   ../liba/regexbss.s

*---------------------------------------------------------------
* ED_HEAP -- see ex.s's own header for the full rationale
* (unchanged mechanism). Must stay the textually LAST thing in
* the file, one page gap on purpose for the kernel's fixed
* 256-byte zeroed page.
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
LASTPAT     ds    PATBUF_MAXLEN
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
* -- edparse.s's MAINLOOP) -- the REAL user here, unlike ed.s/
* -- ex.s's dead-weight copies of the same two cells.
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

ED_GMARKS   ds    GMARK_CAP*2

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

* -- excmd.s's `!` family scratch -- mirrors ex.s's own copy,
* -- same cells, same reason (excmd.s is shared verbatim).
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
ED_GLASSOUT  ds    1          ;see ex.s's own copy -- vi's
                              ;:vc_ret is the reader

EX_DIRTY    ds    1
EX_HASUNDO  ds    1
EX_SHDNLIN  ds    2
EX_SHDCUR   ds    2
EX_EFORCE   ds    1
EX_MARKS    ds    54
EX_CPLEN    ds    2
EX_FSTART   ds    2           ;FF4 -- see ex.s's own copy of
                              ;this comment
* EX_SHADOW moved to the language card ($D000) -- dum block
* after the BSS dend below. Was 8196 low-window bytes.

* -- vi's own bss: the read/insert scratch line, and a small
* -- 4-byte MLI-shaped geo buffer for SC_TTYGEO (viscreen.s's
* -- VI_QUERYGEO, vidmode.s's own idiom).
VI_LBUF     ds    VI_LBUFLEN
VI_GEOBUF   ds    4
VI_NOFLUSH  ds    1           ;1 = VI_CSI_POS suppresses its own
                             ;SIO_FLUSH (VI_REPAINT sets it
                             ;the row loop -- a repaint is
                             ;ONE write, not one per row)
VI_INS_STRUCT ds  1           ;0 none, 1 CR typed (ESC must
                              ;repaint all), 2 o/O opened a
                              ;line (entry repainted it; ESC
                              ;does two rows). Was: 1 = the
                             ;insert changed the line COUNT (a
                             ;typed CR, or o/O/c opened a line)
                             ;-- rows below moved, full repaint.
                             ;0 = a single-line edit (i/a/A/I,
                             ;no CR) -- VI_RPT_LN redraws just
                             ;that row (viinsert.s :doesc)
VI_RDBUF    ds    3           ;vicmd.s/viinsert.s VI_RAWKEY's
                              ;SC_READ target: 1 byte, or a
                              ;framed arrow's ESC [ final
VI_RDPOS    ds    1           ;VI_RAWKEY: next unserved byte of
VI_RDLEN    ds    1           ;VI_RDBUF / bytes the read gave
                              ;(typed-ahead cooked bytes come
                              ;back 3 at a time; see vicmd.s)
VI_UNGET    ds    1           ;a key VI_RAWKEY hands back FIRST
                              ;(0 = none): an arrow that ended
                              ;an insert is re-read by command
                              ;mode as the motion (viinsert.s)
VI_ERRSAVE  ds    1           ;sticky ED_ERRSTAT across a `:`
VI_ERRNOW   ds    1         ;this `:` dispatch failed (vicmd.s)
VI_D1SP     ds    1           ;S pinned by VI_COLON/VI_ZZ before
                              ;`jmp ED_DISPATCH1`/EX_XCORE and
                              ;restored at the ED_D1RET landing
                              ;-- the ex engine's handlers end
                              ;`jmp MAINLOOP` and leave `jsr`
                              ;return addresses on the stack
                              ;(vicmd.s VI_COLON header)

* -- visearch.s's own scratch/state, plain BSS (not zero page --
* -- none of this is on a hot path, and vi's own ZP window is
* -- already full, $82-$91).
VI_MCOL     ds    1           ;VI_LMATCH_FWD/BK: matched column
VI_SCOL     ds    1           ;VI_LMATCH_FWD/BK: start/boundary
                              ;column parameter (survives the
                              ;ED_LINETEXT call inside them)
VI_MFLAG    ds    1           ;VI_LMATCH_BK: "found one" flag
VI_LASTDIR  ds    1           ;last search direction, 0=fwd
                              ;1=back -- `n`/`N`
VI_NOLAND   ds    1           ;1 = VI_SRCH_LAND does nothing (an
                              ;operator's search, VI_SMO_*)
VI_SSL      ds    2           ;..the cursor line it started on
VI_SSC      ds    1           ;..and its column

* -- viop.s's own bss: the ONE unnamed register (docs/VI-
* -- DESIGN.md sec 4.4), plain BSS like visearch.s's own state
* -- above -- none of it is on a hot path either, and vi's ZP
* -- window is already full.
VI_REG      ds    254         ;charwise register text, NUL-term
VI_REGTY    ds    1           ;0 = charwise one-liner (VI_REG),
                              ;1 = linewise, 2 = charwise across
                              ;lines (both: arena entry 26)
VI_REGLCNT  ds    1           ;types 1/2: strings stored
* -- virg.s's own bss: named registers "a-"z. The register TEXT
* -- lives in the LC arena (dum block after the BSS dend); these
* -- are the low-window cells around it. (The linewise
* -- register's
* -- old 24 x 256 B VI_REGLBUF is gone: it is arena entry 26.)
VI_RGSEL    ds    1           ;pending "x prefix: 0 none, 1-26
VI_RGKEY    ds    1           ;the command key after "x
VI_RGI      ds    1           ;register index 0-25 in flight
VI_RGN      ds    1           ;strings in the register
VI_RGK      ds    1           ;string loop counter
VI_RGC      ds    1           ;multi-line put: split column
VI_RGLN     ds    1           ;multi-line put: line length
VI_RGNEW    ds    2           ;packed size of the new register
VI_RGOLD    ds    2          ;packed size of the one it replaces
VI_RGOOF    ds    2           ;..and its arena offset
VI_RGCNT    ds    2           ;byte count for VI_RG_MOVE
VI_RGBAD    ds    1           ;1 = the register being written
                              ;did not fit (VI_RG_PUT/FIN)
VI_RGS      ds    1           ;VI_RG_COPY: source entry
VI_RGP      ds    2           ;VI_RG_NEXT: read pointer (LC)
VI_RGL      ds    2           ;multi-line put: the split line
VI_RGAF     ds    2           ;..the line to insert after next
VI_OPCHAR   ds    1           ;viop.s VI_OP_DC_BODY: which key
                              ;("d"/"c") means the doubled form
VI_OPISCH   ds    1           ;viop.s VI_OP_DC_BODY: 0=delete,
                              ;1=change (falls into insert)
VI_MO_END   ds    1           ;vimotion.s VI_MO_ADV1: nonzero =
                              ;the word walk was CLAMPED at the
                              ;end of the buffer (VI_W_OPADJ)

* -- vicache.s's own bss: VI_NCACHE slots of VC_SLOTSZ bytes
* -- each (see the equates' own header for the 3040B-wall
* -- rationale), plus the 1-byte round-robin victim index.
* -- Array-of-structs, {key:4}{flags:1}{text:81} per slot, so
* -- vicache.s's own routines can offset off ONE pointer
* -- (VC_SPTR) for every field.
VC_SLOTS    ds    2408         ;VI_NCACHE*VC_SLOTSZ (28*86) --
                              ;a literal count, not the product,
                              ;because dialect arithmetic in a
                              ;`ds` operand is one more thing to
                              ;get silently wrong; if VI_NCACHE
                              ;or VC_SLOTSZ change, this must
                              ;change with them
VC_NEXT     ds    1           ;round-robin victim slot index,
                              ;0..VI_NCACHE-1

* -- line WRAP (viscreen.s, 2026-09-05; VI-DESIGN sec 2.3 "vi
* -- wraps, it does not truncate" finally true): a buffer line
* -- occupies ceil(width/VI_COLS) screen rows. VI_REPAINT fills
* -- this table with each visible line's row count so cursor
* -- placement and the one-line repaint can do row math without
* -- refetching text. 48 covers the tallest console (UltraTerm
* -- 80x48: 47 text rows).
VI_LNROWS   ds    48          ;rows used by visible line i
                              ;(i = line - VI_TOP)
VI_LNCNT    ds    1           ;lines painted (entries valid)
VI_SCR_SAVT ds    2           ;VI_SCROLL_DN: old VI_TOP, for the
                              ;partial-scroll delta
VI_SCR_DLT  ds    1           ;VI_SCROLL_DN: rows to scroll (SU)
VI_WCOL     ds    1           ;VI_LNWIDTH/VI_BPUTSW: columns
VI_WBUDG    ds    1           ;VI_BPUTSW: column budget
VI_LRIDX    ds    1           ;scratch: visible-line index /
                              ;VI_FITCUR's running row total
VI_LR       ds    1           ;scratch: one line's row count
VI_SFXLEN   ds    1           ;viinsert.s: length of the saved
                              ;suffix (SUBSCR) this session
VI_RPADJ    ds    1           ;VI_RPCUR/P: 0 = from the
                              ;cursor line, 1 = one above

* -- the IL/DL redisplay (viscreen.s VI_RPINS/VI_RPDEL,
* -- 2026-09-11): one insert-line/delete-line escape + paint the
* -- new rows, instead of a repaint from the cursor down.
VI_RPLIM    ds    1           ;VI_RPFROMN: real lines left to
                              ;paint (0 = to the bottom)
VI_ILK      ds    1           ;visible index of the first new/
                              ;deleted line
VI_ILN      ds    1           ;.. how many lines
VI_ILROW    ds    1           ;.. its screen row
VI_ILDLR    ds    1           ;VI_RPDEL: rows the deleted held
VI_ILADJ    ds    1           ;1 = the line above k changed too
VI_ILSAV    ds    1           ;VI_LNCNT before the edit
VI_ILTOP    ds    2           ;VI_TOP before VI_FITCUR
VI_DA1      ds    2           ;a LINEWISE delete's first line,
                              ;captured before the delete (ED_
                              ;ADDR1 gets clobbered by ED_DLT_
                              ;RANGE/VI_OP_CWD)
VI_DNL      ds    2           ;ED_NLINES before the delete: the
                              ;DL count is the ACTUAL line delta
                              ;(VI_DNL - ED_NLINES), not the
                              ;span -- a no-join `dw` leaves
                              ;ADDR2 on the next line it did NOT
                              ;remove

* -- `.`-repeat (vicmd.s, 2026-09-05). Every command's raw
* -- keystrokes are recorded into VI_RECBUF as VI_RAWKEY reads
* -- them; a change command COMMITS that recording into
* -- VI_DOTBUF; `.` replays VI_DOTBUF by switching VI_RAWKEY's
* -- source to it. A separate record buffer (not VI_DOTBUF
* -- itself) means a non-change command -- or the replay of a
* -- change -- can never clobber the stored change.
VI_DOTBUF   ds    VI_DOTCAP    ;the committed last-change keys
VI_RECBUF   ds    VI_DOTCAP    ;the current command's keys
VI_DOTLEN   ds    1           ;length of VI_DOTBUF (0 = none)
VI_RECLEN   ds    1           ;current record write index
VI_RECING   ds    1           ;1 = recording (per cmd)
VI_RECOVF   ds    1           ;1 = this command overran the cap
VI_STMSG    ds    1           ;1 = the status row holds the
                              ;on-open banner, clear it on the
                              ;next key clears it (vicmd.s)
VI_DOTPLAY  ds    1           ;1 = VI_RAWKEY replaying
VI_DOTPTR   ds    1           ;replay read index into VI_DOTBUF

ED_HEAP     ds    0
            err   */$BF00
            dend

* The undo shadow table lives in the process LANGUAGE CARD, out
* of the low window entirely. ALTZP maps it per-process;
* EX_SNAPSHOT / EX_UNDO_CORE (excmd.s) bracket every access with
* LCBANK2_RAM / LCBANK2_STORE. Written before read.
            dum   $D000
EX_SHADOW   ds    LINETBL_SIZE
* -- Register arena (virg.s): 27 {offset,len} directory
* -- entries, the arena end offset, then ONE packed arena. Same
* -- LC-resident side-table pattern as EX_SHADOW above; every
* -- access brackets with the LCBANK2_RAM double read.
* -- VI_RG_INIT
* -- zeroes the directory and VI_RGEND at process entry.
VI_RGDIR    ds    108
VI_RGEND    ds    2
VI_RGARENA  ds    VI_RGCAP
            err   */PRC_LC_TOP      ;below the door
            dend
