# CONSOLE-VT102 -- the console's terminal target is the DEC VT102

Ruling 2026-09-11 (operator): "we should target vt102 capability." A stock
`TERM=vt102` terminfo entry must drive the maux console correctly. This
document is the gap list between what `infocmp vt102` claims and what the
console does, the order the gaps close in, and the gate that proves each
one. Primary source: `learning:01M286W9KVA7TW7KN0BRGGHV0D` (VT102 User
Guide ch. 5 + the June 1981 reference card); the escape summary the console
documents today is docs/CONSOLE.md sec 4.

## 1. Why VT102 and not VT100 or a private `maux` entry

- VT100's terminfo has no `il`/`dl`, so vim and less scroll with `csr` +
  `ind`/`ri`. The console has IL/DL (393e435) but no scroll region and no
  `ESC M`, so under `vt100` a region scroll shears the whole screen.
- VT102 = VT100 + the editing set (IL, DL, DCH, IRM). That is the set a
  1979-83 vi uses through termcap `al`/`dl`, it is what Apple II terminal
  programs of the day emulated (ProTERM, in the commons), and it is what
  maux's own vi already emits. One target serves the host's vim and ours.
- A private `maux` entry would work sooner but proves nothing: the point of
  `tip` is host programs exercising the console with output maux did not
  write, and they assume a standard terminal.

## 2. Gap list (capability -> console today -> work)

| terminfo | sequence | console today | work |
|---|---|---|---|
| `cup`,`home` | `CSI r;cH` | yes | -- |
| `cuu/cud/cuf/cub` | `CSI nA..D` | **DONE (slice 1)**: count honoured, CUU/CUD clamp at the MARGIN when the cursor started inside/at it, else the physical edge (tty9.s TT9_CUU/TT9_CUD); CUF/CUB unchanged (already physical-edge clamped, no margin concept) | verified in check-vt102's `cur` case |
| `ed`, `el` | `CSI J`, `CSI K` | **DONE (slice 1)**: `0J`/`1J`/`2J`, `0K`/`1K`/`2K` (tty9.s TT9_ED/TT9_EL); cursor never moves for any of them, including 2J (was TTY_CLR_SCRN, which homed it -- now TTY_CLR_BODY alone). **Batched (perf slice 1, 2026-09-12)**: every row erase is ONE per-backend span -- tty2.s TTY_ERS_SPAN blanks [VC_COL, A) of the row through a 40-column text-page fill, tty5.s N8_ERSSPAN (odd/even halves, one aux window) or ultraterm.s UT_ERS_SPAN (one ring walk, clamped to the row's dirty bound); `0K` is the tail, `1K` the head [0, col], and TT9_CLRROW (so `2K` and ED's rows) the whole row. `1K` was a cell walk (15.7k cycles a row on native-80, 18.4k on the card, now 4.1k / 4.8k) and a 40-column ED 0 from home was 116k (now 23k) | check-vt102 `ed0`/`ed1`/`ed2`/`el1`/`el2`, all three backends since perf slice 1 (they ran on text40 only, and `ed0` checked only the cursor row -- review 2026-09-12) |
| `il1`,`dl1` | `CSI L/M` | **DONE (slice 1)**: region = [cursor,VC_MBOT]; a no-op outside the margins (tty9.s TT9_IL/TT9_DL/TT9_RGN) | check-vt102 `il/dl_outside` |
| `sc`,`rc` | `ESC 7/8` | **DONE (slice 6)**: the whole DECSC set -- position, rendition, character sets (G0/G1/GL/ACS) and the pending wrap, which DEC hardware restores (wraptest's DEC/VT100/VT220/VT420/VT510 columns all say so) -- one contiguous VC_DSC_N-byte block in the VC struct (tty.s VC_ROW..VC_ACS mirrored by VC_SAVE_ROW..), copied by TTY_CRSR_SAVE/RSTR (tty2.s) and by the background-console restore (tty5.s VCA_SLTCRSR); the restore clamps the column to the live width and a geometry change voids the stash (tty7.s) -- review finding VT6/VT7 | check-vt102 `sgr` (rendition + charset restored), `wrap` segment 5 (pending wrap restored), `rsz` (void after a geometry change) |
| `flash` (visual bell) | `BEL` ($07) | **DONE (2026-10-08)**: BEL arms one global cell (TTY_FLSH, tty9.s; tty2.s TTY_PUT_CTL); the TICK does the rest -- after TTY_POLL it folds every text-page cell to its inverse (TTY_FLFOLD, an involution over all 256 display codes, learning 01M02NT5M7PXSZTHGVJKRENGM4: bit 5 set eor $80; else $00-$1F <-> $C0-$DF eor $C0; MouseText untouched; N8 walks the aux half in ONE masked 80STORE/PAGE2 window per row, learning 01M0NZFJMX163HFK2CM64Q9GVA), counts 4 ticks down and folds back from the cell content (no copy). The UltraTerm swaps $C0B3 to $02 (plain cells inverse) and TTY_ATTR_APP restores it -- no VRAM. Anything that would draw on an inverted page (TTY_CRSR_HIDE: every write entry and console switch) puts it back first and RE-ARMS the bell, so the flash still gets its frames. The fold walk is ~37k cycles (40-col) / ~75k (N8) in the tick: a few VBLs are missed per bell. A BEL on a background console flashes the glass (one global cell). No speaker ($C030 untouched) | check-vt102 `bell`, three backends: a stable page, then its exact fold on consecutive polls, then the original byte-for-byte (UT: $C0B3 $20 -> $02 -> $20, card text unchanged) |
| `rev`,`sgr0` | `CSI 7m`, `CSI m` | **DONE (slice 6)**: EVERY parameter applies, in order -- curses' stock vt102 standout is `CSI 0;1;7m` and the combined form is `CSI 0;1;4;7;5m` (five parameters), and the parser applied only the first two; a fifth+ parameter now FOLDS into the third slot when SGR acts on it (tty2.s TTY_CSI_BYTE's `;`, TTY_SGR_CLASS) and the parameter count saturates at four (no byte wrap after 256 semicolons) -- review finding VT5 | check-vt102 `sgr` (text-page bytes peeked, text40) |
| `bold`,`smul`,`blink` | `CSI 1/4/5m` | ignored | keep ignoring (no glyph attribute for them); `smul` may map to inverse later |
| `csr` | `CSI t;br` | **DONE (slice 1)**: DECSTBM sets VC_MTOP/VC_MBOT (tty9.s TT9_DECSTBM); TTY_SCRL_BOT (tty.s) replaces every hardcoded TTY_ROWS/VC_STR_ROWS bound in the scroll primitives (tty4.s/tty5.s/tty8.s); `CSI r` alone = whole screen; cursor homes after a successful set | check-vt102 `csr+ind`, `ri`, `csr_home` |
| `ind`,`ri` | `^J`, `ESC M` | **DONE (slice 1)**: `ESC D` = IND, `ESC M` = RI, `ESC E` = NEL (tty9.s TT9_IND/TT9_RI/TT9_NEL), all margin-bounded; a bare LF is IND too (sec 3) | check-vt102 `nel`; IND/RI exercised via `csr+ind`/`ri` |
| `dch1` | `CSI P` | **DONE (slice 2)**: `CSI Pn P` shifts the row left from the cursor by n (0 default -> 1), clamped to the columns at/right of the cursor; the opened tail is blanked with the backend's own blank cell; cursor unmoved (tty9.s TT9_DCH, via the new TT9_ROWRD/TT9_ROWWR row<->linear-buffer primitives) | check-vt102 `dch1`/`dch_clamp`/`dch_col0`/`dch_last` |
| `smir`,`rmir` | `CSI 4h/4l` | **DONE (slice 2)**: `CSI 4h`/`CSI 4l` set/clear VC_IRM (tty2.s CSI_CH -> TT9_MODE); while set, every printable pushes the row's tail right by one first (TT9_ICHSH, TT9_ROWRD/TT9_ROWWR again) before storing, VT102's own description of how a terminal with no ICH inserts text | check-vt102 `smir/rmir`/`smir_col0`/`smir_last` |
| `smacs`,`rmacs`,`enacs` | `^N`,`^O`,`ESC ( x`,`ESC ) x` | **DONE (slice 5, 2026-09-12)**: SCS designators recorded (G0/G1, `0` = DEC special graphics), SO/SI invoke them, the graphics set maps `$60-$7E` to the `+ - |` ASCII fallback at TTY_WR_CELL (tty9.s TT9_ACSMAP); UltraTerm batch path defers to per-byte when it is active | check-vt102 `acs` (all backends; teeth: map disabled -> letters) |
| `smkx`,`rmkx`,`rs2` | `CSI ?1h ESC =`, `CSI ?1l ESC >` | **DONE (slice 1)**: `ESC =`/`>` consumed (fall through TTY_ESC_BYTE's default drop); DECCKM (`CSI ?1h/l`) sets/clears VC_DECCKM (tty9.s TT9_CKM), TTY_KEYIN frames a physical arrow as `ESC O A..D` when set (tty3.s `:csi`); reset by `ESC c` | check-vt102 `smkx` (run separately -- needs the SSC MCP tools, see the Makefile note beside check-tip) |
| `smam`,`rmam` | `CSI ?7h/l` | **DONE (slice 7, 2026-09-12)**: DECAWM is VC_AWM (tty.s; 1 = on, the default and what the terminfo entry's `am` assumes), set/cleared by `CSI ?7h/l` (tty2.s TTY_CSI_PRIV -> tty9.s TT9_AWM; `?7l` also drops a pending wrap), checked at the last column by BOTH renderers (tty2.s TTY_PUT_PRNTB, procfd.s TTY_RUN): with it off a printable overwrites the last cell and the cursor stays, no deferred wrap. Reset on by ESC c and VC_RESET. VC_ST_SIZE 318 -> 319, VC_SLOT_RESV 1272 -> 1276 (4 B of annex slack left) -- the review remaining-debt item | check-vt102 `awm` (the run renderer: 80 'A' + 'XY' -> width-1 A's and a Y, all three backends) and `awm_acs` (the per-byte renderer: the same overflow under SO, which the run path rejects); teeth: each renderer's check removed turns its own case red, and ONLY its own -- the first `awm` sabotage stayed green because every byte of it is a run |
| `hts`,`tbc` | `ESC H`, `CSI 3g` | **accepted, ignored** (both already fell through the parser's default-drop paths before this slice; confirmed, no code needed) | tabs stay every 8 |
| `ht` (HT), `cub1` (BS) | `^I`, `^H` | **DONE (slice 6)**: HT is a cursor motion to the next 8-column stop, paints nothing, clamps at the last column and never wraps (it used to print spaces through TTY_PUT_PRNTB -- overwriting cells, inserting under IRM, wrapping onto the next row -- so every curses `ht` motion erased text; review finding VT3). BS is one column left, none at column 0, no blanking (it blanked the cell and stepped onto the previous row; `cub1` is this byte, so curses erased by moving left; review finding VT2). DEL is ignored. The destructive erase lives in readline-lite alone now (tty6.s TTY_ED_KILL steps + blanks for itself); vi paints its own tabs as spaces (viscreen.s VI_PUTCT, VI_LBCOL, viinsert.s VI_INS_ECHO) since the terminal no longer does | check-vt102 `bs`, `ht` (all three backends); check-vi/check-play unchanged |
| `mc0/4/5` | `CSI 0i/4i/5i` | dropped | fine (printer) |
| `xenl` | wrap glitch | **DONE (slice 3)**: the deferred-wrap flag (VC_XENL) is set in TTY_PUT_PRNTB the instant a printable lands in the last column instead of wrapping immediately, and consumed by the NEXT printable. **Slice 6 (review finding VT4)**: it is cancelled by the operations that cancel it on DEC hardware -- CR, IND/LF/NEL/RI, BS, and every CSI final except SGR and the `h`/`l` mode families -- and PRESERVED across SGR, BEL, NUL, SO/SI, HT and DECSC (slice 3 cleared it for every byte < $20, so `CSI 7m` or a BEL after a full row made the next character overwrite the last cell instead of wrapping). The UltraTerm's batched printable-run path (TTY_UT_RUN, procfd.s) needed the identical consume/defer checks repeated -- it is a SECOND renderer that bypasses TTY_PUT_PRNTB entirely, and slice-1's measurement below never exercised it (see the slice-3 note) | check-vt102 `xenl` (CR cancels), `wrap` (SGR/BEL/NUL/SO-SI keep it, DECRC restores it), all three backends |
| `it#8`, `cols#80`, `lines#24` | -- | 40 or 80 by vidmode | serbridge exports the real geometry (`--cols/--rows`), tip_live passes it |
| `kcuu1..` | `ESC O A` | **DONE (slice 1)**, covered by DECCKM above | check-vt102 `smkx` |

**xenl measurement (slice 1, 2026-09-12, superseded by slice 3 below):**
writing 92 printable characters onto a fresh row showed exactly 80 landing
on row 0 before the console wrapped to row 1, immediately, before the
next printable ever arrived -- no `xenl`. That measurement also noted
`e2e_term.py`'s `'text40'` backend label did not actually force 40
columns (task #23 deliverable C fixed this, sec 7).

**xenl implementation (slice 3, 2026-09-12):** the flag is now SET, to
match the `vt102` terminfo entry rather than drop it. A bulk-write
measurement like slice 1's 92-dot burst cannot actually tell immediate
and deferred wrap apart: both models place IDENTICAL final bytes for a
plain sequential character stream, because the single difference is
*intermediate cursor state* between the last column's printable and
the next one, and a burst processed in one syscall never exposes that
moment to an outside observer. check-vt102's `xenl` case instead writes
80 dots (a multiple of both known widths, so the last dot always lands
exactly on a width boundary), then CR, then a marker: under xenl the
CR's own newline is the ONLY one that fires (the deferred wrap it
would-have executed is CANCELLED, not run, by the CR's own byte < $20
check) and the marker lands one row earlier than it would under
immediate wrap, where the CR's newline is a SECOND one stacked on the
one the 80th dot already ran. See build_play_image.py's `_vt_xenl2` for
the full derivation and check_vt102.py's `case_xenl`/`_xenl_width` for
the assertion.

**The UltraTerm's batched printable-run path is a second renderer.**
`TTY_UT_RUN` (procfd.s, docs/CONSOLE-RUN-BATCH.md) intercepts a whole
run of printables for the card BEFORE `TTY_PUT_BYTE`/`TTY_PUT_PRNTB`
ever sees them, as a performance optimization (one firmware span setup
per run instead of one `UT_PUT_CELL` per character). Slice 1 never
exercised it because DECSTBM/IND/RI/NEL etc. never plot printable
TEXT; slices 2/3 do, and `check-vt102`'s `smir/rmir` and `xenl` cases
went red on the `ut` backend ONLY (text40/text80 green) the first time
they ran, because this second path had neither check: IRM's insert-
shift has no batched form (fixed by REJECTING the batch outright when
`VC_IRM` is set, falling back to the correct per-byte path -- IRM is
an interactive-typing feature, not a bulk-output one, so nothing is
lost); xenl needed the identical top-of-routine consume and tail-of-
routine defer TTY_PUT_PRNTB already has, repeated here instead of
shared, because the two routines process a batch of bytes vs. one.

Two-byte escapes the parser now knows (`TTY_ESC_BYTE`, tty2.s, was `[`,
`7`, `8`, `c`): `D` `M` `E` (jump to tty9.s TT9_IND/TT9_RI/TT9_NEL) -- `H`
`=` `>` need no new code, they already fall through the existing default
drop -- and `(` `)` `#` swallow one more byte (VC_ESC_STATE=4, tty9.s
TT9_SWALLOW). Anything else after ESC: drop the byte, as before.

## 3. CR is the newline -- and the fix is in the line discipline, not the terminal

**DONE (2026-09-12), part of slice 1.**

maux text is high-bit ASCII with `$8D` as the line terminator (the
ProDOS/Merlin convention, docs/E2E.md sec 9.2), so every program ends a line
with a lone CR and the console had made CR a full newline AT THE TERMINAL
LAYER. That collides with the VT102, where CR only returns the carriage and
LF indexes.

GNO/ME faced the same collision on the IIgs and put the mapping where V7
puts it: the tty line discipline (`learning:01M287MW1Y9Q719BAYFTN4C5M8`,
from `kern/gno/tty.asm`). Its sgtty `CRMOD` bit outputs CR as CR LF and maps
an incoming LF to CR -- Unix's `ONLCR`/`ICRNL`, mirrored because GNO's
newline byte is CR -- and `RAW` mode skips all output processing, leaving
the terminal layer a plain terminal (`$0D` = left edge, `$0A` = down a line).

maux does the same:

- `SYS_TTYMODE` gains `TMD_OPOST` (bit 2, on in cooked mode, off in raw).
  With it set, the output path turns `$8D` into CR LF before the terminal
  layer sees it; nothing changes for `ls`, `cat`, `sh` or any cooked program.
- With it clear (vi, tip, anything that goes raw), the terminal is a strict
  VT102: CR returns the carriage, LF/`ESC D` index at the bottom margin.
  `tip` stops folding CR LF, because the host's `\r\n` now renders as one
  newline on its own.
- Input is unchanged: the keyboard produces `$8D` for RETURN already.

No deviation from the VT102 remains; the file convention stays Apple's.

## 4. Order (each slice its own commit, gate first)

1. **DONE (2026-09-12).** Parser + region + index (kernel, new put file
   `tty9.s` so no existing module crosses the `as` source window): two-byte
   ESC consumption, DECSTBM (`TTY_SCRL_BOT`), IND/RI/NEL, scroll-at-bottom
   bounded by the region, SU/SD/IL/DL bounded by it, `ED 0/1/2`, `EL 0/1/2`,
   DECCKM keyboard framing, `ESC =`/`>`/`H`, `CSI 3g`/`4h/l`/`?7h/l` (already
   silent by default, confirmed rather than newly coded), margin-aware
   CUU/CUD, and `TMD_OPOST` in the line discipline. This is what makes vim
   and less draw right.
2. **DONE (2026-09-12). DCH + IRM** (per-backend row shifts through a
   new linear scratch buffer, tty9.s TT9_ROWRD/TT9_ROWWR -- the same
   "one masked window, not one per cell" shape as N8_ERSLN). This is
   what makes typing in vim's insert mode draw right. Found and fixed
   live: the CSI_CH/CSI_JT table dispatch (tty2.s) that DCH's `P` and
   IRM's `h`/`l` share with every other final byte does NOT preserve A
   as the final byte across the jump (unlike TTY_CSI_PRIV's own direct
   dispatch, which is what makes TT9_CKM's identical-looking convention
   true) -- TT9_MODE read PRC_BYTE instead. Also found: the UltraTerm's
   batched printable-run path (TTY_RUN, was TTY_UT_RUN) is a second renderer that
   bypasses TTY_PUT_PRNTB, so it needed the IRM/xenl checks repeated
   (see sec 2's xenl entry for the full account).
3. **DONE (2026-09-12). `xenl`**: implemented to match the `vt102`
   entry's own flag (see sec 2) -- a `vt102-maux` derivative was the
   documented fallback if the console's wrap turned out NOT to be
   fixable; it was. **Found and fixed the same day, a THIRD site**:
   readline-lite (docs/CONSOLE.md sec 4b, tty6.s) paints forward
   through `TTY_PUT_BYTE` N times and later walks the SCREEN cursor
   back N cells with its OWN, separate, immediate-wrap stepping model
   (`TTY_ED_CLF`/`TTY_ED_CRT`, unchanged since before xenl) -- a
   deferred-then-consumed-by-the-next-character wrap is not
   invertible from `(row,col,xenl)` alone, so `TTY_ED_DEL`'s "print a
   blank, walk back" trick overshot by one cell at the wrap boundary
   the moment xenl could defer. `check-play`'s cooked-mode erase-
   crosses-wrap case caught it (36 stray cells, not 37 -- the
   backspace count was off by exactly the one deferred step). Fixed
   with `TTY_ED_ECHO` (tty6.s): every readline-lite call site that
   plans a symmetric walk-back resolves its own pending wrap on the
   spot, immediately, instead of leaving it deferred -- exactly what
   happened before xenl existed, for internal bookkeeping ONLY (a
   real `write()` through `TTY_WRITE` still defers, VT102-style,
   since nothing there plans to walk itself back by counting steps).
4. **serbridge/tip**: `TERM=vt102`, geometry flags, tip_live passes them.
   DONE 2026-09-12: serbridge `--term` (default vt102), `--cols/--rows`
   (TIOCSWINSZ on the pty + LINES/COLUMNS), `tip_live.sh` honours
   TIP_TERM/TIP_COLS/TIP_ROWS. Proof: headless `fast_sdl --type tip` with
   `vim -u NONE hello.txt` on the host end draws the buffer, tildes and
   status line on the maux screen (screenshot in the session record).
5. **Line drawing**: DONE 2026-09-12 as the ASCII fallback (`+ - |`), SO/SI
   and SCS honoured. MouseText glyphs for the real box pieces are the
   remaining refinement (sec 7).
6. **DONE (2026-09-12). The implementation review, VT1-VT9**
   (the design review "VT102 implementation review -- 2026-09-12"), all
   nine closed in one slice:
   - VT1: the jump-scroll look-ahead (tty8.s TTY_JS_COUNT) counted a
     raw CR as a newline, so the same bytes scrolled differently
     delivered as one write or one byte per write. A CR now counts
     only under TMD_OPOST; LF, VT and FF count (VT/FF are indexes
     now too, tty2.s TTY_PUT_CTL -- they used to print nothing).
   - VT2/VT3: BS non-erasing and floored at column 0; HT a clamped
     non-painting motion (gap table). vi expands its own tabs.
   - VT4: the pending wrap survives SGR/BEL/NUL/SO-SI (gap table).
   - VT5: every SGR parameter, with the fifth+ fold (gap table).
   - VT6: DECRC clamps the column; a geometry change voids the stash.
   - VT7: DECSC/DECRC carry rendition, character sets and the wrap.
   - VT8: C0 controls are classified before the parser state sees
     the byte (tty2.s TTY_PUT_BYTE): ESC restarts a sequence, CAN/SUB
     abort, NUL/DEL are ignored, and every other control EXECUTES
     while the sequence keeps its parameters (DEC VT102 UG 5.5.1).
     `ESC [ 2 ; NUL 3 H` used to print `3H` at home.
   - VT9: the card's reverse-scroll fast path (tty4.s TTY_SCRL_REV)
     took the CRTC display-start shortcut for any top-zero region;
     it now requires the bottom bound too, as TTY_SCROLL always did
     -- RI under `CSI 1;23r` moved the status row.
   Source of the wrap rules: wraptest's measured DEC/VT100/VT220/
   VT420/VT510 columns (https://github.com/mattiase/wraptest), which
   also show a real VT100 NOT cancelling on NL/CUP -- maux follows
   DEC STD-070 and the VT220+ (and xterm), the behaviour every
   program assumes. Still open from the review's debt list: `rmam`
   (gap table), HTS/TBC, origin mode, terminal replies. Deposited as
   `learning:01M2AQKQ8MX8RP3KT0S4XSKKNM` (the nine rules, the wraptest
   columns, and the vi-must-expand-its-own-tabs consequence).

## 5. The gate: `check-vt102`

**Slice 1 shipped (2026-09-12):** `scripts/check_vt102.py` +
`make check-vt102` (in `CHECK_ALL_TARGETS`, next to `check-ildl`). Same
shape as check-ildl: raw-escape `DEMO/VT*` fixtures (built by
`build_play_image.py`) cat'd on all three console backends, one case per
terminfo capability -- `csr+ind`, `ri`, `il/dl_outside` (all three
backends); `nel`, `csr_home`, `ed0`, `ed1`, `ed2`, `el1`, `el2`, `cur`
(CUU/CUD/CUF/CUB), `enacs`, `kpam` (DECKPAM/DECKPNM), `opost` (text40
only -- backend-independent line-discipline/parser logic); `smkx`
is a separate session (`python3 check_vt102.py smkx`), needing the SSC MCP
tools (`reset {ssc:true, clock:false}`) as check-ser/check-tip do; it is
still NOT part of `CHECK_ALL_TARGETS` although those two now are (SER-1,
2026-10-20; folding it in is a candidate, docs/SER-1-NOTES.md sec 5).

**Slices 2/3 added (2026-09-12):** `dch1`, `dch_clamp`, `dch_col0`,
`dch_last`, `smir/rmir`, `smir_col0`, `smir_last`, `xenl` -- all moved
into the ALL-THREE-BACKENDS group (`REGION_CASES`), alongside csr/ri/
il_outside, since the row-copy differs per backend (tty4.s/tty5.s/
tty8.s, tty9.s TT9_ROWRD/TT9_ROWWR) and a bug can hide on one and not
the others -- exactly what happened (the UT-only IRM/xenl bug, sec 2).
The DCH/IRM fixtures use CUP-clamped positioning (`ESC[1;999H`, which
`TTY_CSI_HOME` clamps to the true last column) rather than a hardcoded
column, so ONE fixture file serves 40- and 80-column consoles alike --
load-bearing now that `text40` genuinely boots 40 columns (sec 7).

Completion is detected by settling on a returned, STABLE shell prompt
(`e2e_term.py`'s `wait_prompt`, two identical polls) rather than a
content-based predicate: found live building this gate -- `il/dl_outside`'s
own expected FINAL state (R01..R14 unchanged) is also exactly `ri`'s
leftover screen, so a content predicate keyed on that pattern declared
victory before the new command had even started running. Every `DEMO/VT*`
fixture that paints its own last glyph therefore also parks the cursor
(and, where the row underneath might still hold something, explicitly
erases it, `_park()` in `build_play_image.py`) so the NEXT case's prompt
has a clean line to land on -- the one exception is `cur`, whose `B` marker
sits at the PHYSICAL BOTTOM row by design (it is CUD's clamp target), so
nothing can park below it; that case settles on the marker's own arrival
instead and cats an explicit `DEMO/VTCLEAR` afterward.

**Teeth, all proven and reverted (paste of the red output is in the task
report, not restated here):** reverting `tty5.s`'s `N8_SCRL_AUX` region
bound from `TTY_SCRL_BOT` back to `TTY_ROWS` turns `csr+ind` red (the
scroll copies past the region into unrelated rows); dropping the
`TMD_OPOST` test in `tty9.s` `TT9_CR` (CR never newlines, even cooked)
cascades into an early hang before the `opost` case is even reached, since
the shell's own cooked prompt output depends on it too.

**Slice 2/3 teeth (2026-09-12):** skipping the aux half of `tty9.s`
`TT9_RWN8` (`ldy #40` instead of `#0` before the write-back loop, so
it never runs) turns `dch1` red on `text80` -- the row shows garbled
even-column content instead of the shifted letters, and `text40`/`ut`
stay green (proof the case is backend-specific, not a fixture bug).
Forcing `TTY_PUT_PRNTB`'s top-of-routine xenl check to always skip
(`lda #0` in place of `lda VC_XENL`, so a pending wrap is armed but
never consumed) turns `xenl` red on `text40` (marker landed on row 1,
wanted row 2) while `text80`/`ut` stay green -- the 80-dot burst only
crosses ONE width boundary at 80 columns, so nothing in the same
burst ever exercises the consume path there; the false-negative on
two backends and the true-positive on the third is itself informative
about what the check actually exercises. Both reverted, both green
again (`MAUXPLAY.SYSTEM` back to 27,932 B either way).

**Slice 6 added (2026-09-12, the review VT1-VT9 pass):** `bs`, `ht`,
`wrap` (five 80-char segments: SGR, BEL, NUL, SO/SI, DECSC+CUP+DECRC),
`ctl` (NUL/ESC/CAN/BEL inside a CSI), `ri_bottom` (RI under `CSI
1;23r`, the UT display-start shortcut) in the all-three-backends
group; `sgr` (five-parameter standout + DECRC of rendition/charset,
asserted on the TEXT-PAGE BYTES via peek, since no screen reader
exposes an attribute), `rsz` (DECRC after `CSI 80;24v`, then back)
and the raw jump-scroll check inside `opost` (`DEMO/VTJSRAW`, one
131-byte write: LF X CR JSY LF at the bottom row must scroll by 2)
on text40. `ri_bottom` settles on the prompt at row 0 and cats
`VTCLEAR` afterwards, case_cur's idiom, because the surviving R24 IS
the last row. Teeth, each case run alone against the pre-slice
kernel (9fa9ebf) with `git checkout HEAD~1 -- src/kernel src/bin
include`: see the commit message for the red lines; all restored and
green again.

**Not built** (this doc's own aspiration, beyond the task's scope): the
person-like end-to-end test -- a `tip` session where host vim
(`TERM=vt102`) opens a file and its screen is compared byte-for-byte
against maux's rendering of the same session.

## 6. Growth budget

New code goes in a new put file (the house rule from tty5.s's split: the
`as` 16128-byte source window is per put). Kernel image growth shows up as
test-image pad bumps (argvtest/forktest/processtest, as slice 2 of the SSC
did) -- bump them in the same commit. The Merlin-8 resident+largest-put
ceiling (41215, docs/TOOLCHAIN.md) is per kernel manifest and is checked
by `check_librel.check_source_budgets()`.

**Slice 1 measured (2026-09-12):** MAUXPLAY.SYSTEM grew 26,840 -> 27,394 B
(+554 B), all in the new `src/kernel/tty9.s` put plus small dispatch
retargets in tty2.s/tty3.s/tty7.s/tty8.s (tty2.s shrank slightly on its
own -- several existing routines, e.g. TTY_CSI_SU/SD/IL/DL/RGN/SCLAMP and
the old TTY_CSI_UP/DOWN, moved to tty9.s wholesale rather than being
forwarded, since DECSTBM changed their bodies anyway). Pads bumped:
argvtest/argvtestb NBLOCKS 52->53 (target $7000->$7200), forktest/
forktestb NBLOCKS 53->54 ($7200->$7400), processtest/processtestb2
NBLOCKS 57->58 ($7A00->$7C00).

The per-console VC struct also grew: 3 new fields (VC_MTOP, VC_MBOT,
VC_DECCKM -- the ESC-swallow state reused an existing VC_ESC_STATE value,
no new byte there) took VC_ST_SIZE from 302 to 305 B (inc/tty.equ).
VC_SLOT_RESV (inc/mm.annex.equ) grew from 1208 to 1220 B (4 x 305)
to match -- a renegotiation the annex map had room for: the reservation's
old end ($74B8) sat 72 B short of the next occupant (SIG_TBL_ADDR, $7500),
already-unused slack in that file's own "preferred non-video continuation"
carve, so nothing downstream moved.

**Slices 2/3 measured (2026-09-12):** MAUXPLAY.SYSTEM grew 27,394 ->
27,932 B (+538 B total, including the TTY_ED_ECHO fix below): TT9_
ROWRD/TT9_ROWWR/TT9_DCH/TT9_MODE/TT9_ICHSH + the 80-byte TT9_RBUF
scratch in tty9.s, the CSI_CH/CSI_JT table's 3 new entries + TTY_
PUT_PRNTB's xenl/IRM checks in tty2.s, the IRM/xenl repeat in TTY_
UT_RUN (procfd.s), and TTY_ED_ECHO + its 4 call-site retargets in
tty6.s/tty3.s. VC_ST_SIZE grew 305 -> 307 B (VC_IRM, VC_XENL);
VC_SLOT_RESV grew 1220 -> 1228 B (4 x 307) -- new end
$7000+1228=$74CC, still 52 B short of SIG_TBL_ADDR ($7500), so again
no downstream renegotiation. MAUXEDTEST.SYSTEM: 29,658 -> 29,673 B,
end $93E9, margin 1047 B under PMLI_IBF_BASE ($9800) -- no near-miss.
Pads bumped: argvtest/argvtestb NBLOCKS 53->54 (target
$7200->$7400), forktest/forktestb NBLOCKS 54->55 ($7400->$7600).

**Slice 6 measured (2026-09-12):** MAUXPLAY.SYSTEM 28,153 -> 28,285 B
(+132 B: the C0 classifier, the SGR fold + four-slot apply, the
VC_DSC_N-byte save/restore + clamp, the per-operation xenl cancels,
TTY_JS_COUNT's OPOST test, the reverse-scroll bound). VC_ST_SIZE 312
-> 318 (the six new stash cells); VC_SLOT_RESV 1248 -> 1272, end
$74F8, 8 B short of SIG_TBL_ADDR ($7500) -- **the annex slack is
spent; the next per-console byte moves SIG_TBL_ADDR.** MAUXEXPR.SYSTEM
would have gone 83 B OVER PMLI_IBF_BASE (its 49 B margin, sec 7); its
case table was packed 8 -> 4 bytes a row (src/test/exprtestb.s, 148 B
of data + the 16-bit row walk it no longer needs), leaving a 92 B
margin. Do not pin it. vi grew 22,072 -> 22,175 B (the tab expansion).
Pads bumped: forktest/forktestb NBLOCKS 55->56 (target $7600->$7800,
101 B over -- found by the box sweep, as 1ac30c6's were). The box sweep
also caught a pre-existing slice-phase race in the `opost` case: under
-opost the shell's reprompt CR is a column return, so "$ " overpainted
the raw fixture's marker on the same row before the poll saw it; the
VTCRRAW fixture now ends with an LF so the prompt lands on a fresh row.

**Perf slice 1 measured (2026-09-12, review performance items 1-3):**
MAUXPLAY.SYSTEM 28,285 -> 28,269 B (-16 B: TTY_ERS_SPAN + its 40-column
fill and N8_ERSSPAN's count-down loops + UT_ERS_SPAN's clamp + three
scratch cells, paid for by retiring VCS_ERS_TAIL, VCS_ACT_ON/OFF, UT_ERSLN
and UT_CLR_ROW's 80-byte buffer round trip). No per-console byte, no
pad bump. Cycles, whole-write syscall brackets (build/
vt102_performance_probe.py's method, median of three), before -> after:

| Operation | 40-col | Native 80 | UltraTerm |
|---|---:|---:|---:|
| 80-char ASCII row | 14.8k -> 14.9k | 31.7k -> 31.7k | 36.5k -> 11.9k |
| 254 ASCII printables | 85.8k -> 86.4k | 97.3k -> 97.8k | 112.5k -> 34.5k |
| EL 0, dirty row | 7.0k -> 3.2k | 3.7k -> 3.8k | 6.0k -> 4.5k |
| EL 1 at the last column | 7.3k -> 3.4k | 15.7k -> 4.0k | 18.4k -> 4.8k |
| EL 2 | 7.3k -> 3.5k | 4.0k -> 4.1k | 6.2k -> 4.8k |
| ED 2, populated screen | 33.8k -> 33.7k | 49.2k -> 49.2k | 100.9k -> 49.0k |
| ED 0 from home | 115.7k -> 23.1k | 34.2k -> 35.3k | 86.7k -> 50.7k |
| ED 1 from the end | 116.0k -> 23.3k | 46.1k -> 35.5k | 99.1k -> 51.0k |
| one bottom LF | 17.4k | 38.3k | 6.4k -> 4.1k |
| twenty bottom LFs | 20.7k | 37.2k | 90.2k -> 47.0k |
| scroll region 1-23 | 16.7k | 36.8k | 99.7k -> 97.5k |

The native-80 EL 0 / ED 0 costs went UP 1-3%: TTY_ERS_SPAN's end cell
and N8_ERSSPAN's count prologue (~50 cycles a row) -- the price of one
primitive serving three spans, accepted.

**Perf slice 2 measured (2026-09-12, review item 4):** the card's
run-batch path became `TTY_RUN` (procfd.s) for ALL three backends --
the encode loop is per backend (card: ASCII + bit-7 inverse; text page:
ASCII OR $80 with the TTY_INVERSE_A fold), the span is UT_PUT_SPAN,
tty5.s N8_PUT_SPAN (odd columns straight to main, even columns through
ONE masked aux window) or a direct 40-column row copy. Same probe:

| Operation | 40-col | Native 80 | UltraTerm |
|---|---:|---:|---:|
| 80-char ASCII row | 14.8k -> 6.5k | 31.7k -> 11.7k | 36.5k -> 11.9k |
| 80-char high-bit row | 15.3k -> 7.0k | 32.7k -> 12.7k | 12.7k -> 12.7k |
| 254 ASCII printables | 85.8k -> 33.5k | 97.3k -> 34.2k | 112.5k -> 34.5k |
| 80-char line-drawing (ACS) row | 16.4k -> 17.0k | 34.8k -> 36.2k | 38.8k -> 38.2k |
| SGR / CUP (parser only) | 2.6k -> 2.7k | 2.7k -> 2.8k | 2.8k -> 2.8k |

Every backend now paints ordinary text at ~150 cycles a character;
native-80 is no longer the slow one. The +4% on an ACS row (the run
path rejects it per byte, four checks deeper than the old card-only
test) and the +75 cycles on a bare CSI are the cost of the bytes
below, accepted. Kernel bytes: slice 2 alone was +150 B (the second
encode loop, N8_PUT_SPAN, the dispatch), which put MAUXEXPR.SYSTEM
42 B OVER PMLI_IBF_BASE; reclaimed by laying the four CSI parameter
cells contiguously (tty.s VC_CSI_ROW/COL/P3/P4, then VC_CSI_PARAM) so
the digit accumulator, TTY_CSI_START and TTY_CSI_ATTR index them
instead of carrying a copy per cell (-70 B), and the unused TT9_COL.
Net for both slices: MAUXPLAY.SYSTEM 28,285 -> 28,346 B (+61 B);
MAUXEXPR ended $97E1, 31 B under $9800 -- and that wall is now GONE:
the harness's Phase-1 case table, argv arrays and token strings
(~430 B of constants) moved to src/test/exprcases.s, assembled alone
at $1800 and staged as /BASIC/EXPRCASES, which exprtestb.s READs into
its bank before Phase 1 (LOAD_CASES; a missing file parks R_ERR and
fails the gate -- proven). MAUXEXPR.SYSTEM 30,689 -> 30,327 B, end
$9677, 393 B under PMLI_IBF_BASE. No per-console byte, no pad bump. check-vt102's ed0/ed1/ed2/el1/el2 run on all three backends;
teeth: N8_PUT_SPAN's halves transposed turns check-play80n and the
text80 `acs` case red (pairs swap), each erase backend's span
sabotaged turns its leg red.

**Perf slice 3 measured (2026-09-12, review item 5, the card's
region scroll):** tty8.s UT_MOV_ROW moves a VRAM row by the SOURCE'S
DIRTY BOUND -- read [0, UT_EXT[src]) (UT_GET_SPAN), write it as one
span, blank the destination's [ext, old bound) with the span eraser
(which lowers the bound) -- instead of read 80 / write 80 / rescan
(UT_GET_ROW + UT_PUT_ROW). UT_SRGN_UP and UT_SRGN_DN (IL/DL, region
IND/RI) use it. The old cost was content-independent, so the
full-row figure is the short-row baseline too:

| Operation (UltraTerm) | rows of 79 'A' | rows of 'Rnn' (3 chars) |
|---|---:|---:|
| scroll region rows 1-23 (editor with a status line) | 97.5k -> 98.8k | 97.5k -> 16.5k |
| insert line at row 12 | 55.6k -> 56.3k | 55.6k -> 11.5k |

The full-row case is +1%: UT_PUT_ROW's backward scan already exited
on the first non-blank cell, so there was no rescan to save there,
and the move's prologue plus the eraser's skip test are the cost.
The read end lives in P_TMP2 (zero page) rather than an absolute
cell: the loop's `cpx` at 4 cycles instead of 3 was +80 a row and
showed as +3% on IRM/DCH, which read a row per character. Kernel
+42 B (28,346 -> 28,388). New check-vt102 case `csr_tail` (all three
backends): a short row scrolled up over a long one must leave a blank
tail -- the exact cell a missing blank leaves stale. Teeth: the blank
step removed turns it red on `ut`.

**Perf slice 4 measured (2026-09-12, the rest of review item 5 +
`rmam`):** DECAWM (above, sec 2). IRM at the last column shifts
nothing and skips the row read/write (tty9.s TT9_ICHSH); DCH at the
last column just blanks the cell (TT9_DCH -> TTY_BLNK_CELL). On the
card the row halves go by the DIRTY BOUND: TT9_RRUT reads [0,
UT_EXT[row]) (UT_GET_SPAN), the shifts are bounded by the row's end
(TT9_WEND: the width on the text-page backends, the bound on the card
-- TT9_ROWRD sets it, TT9_RRUT overrides it), TT9_RWUT writes [0,
end) or one more for IRM's shifted row; an insert with the cursor at
or past the end writes nothing back (the cell past the end was never
read -- check-vt102 `smir_past` found the stale write live). Same
probe, UltraTerm:

| Operation (UltraTerm) | before | after |
|---|---:|---:|
| IRM, one char at column 4, 80-char row | 10.5k | 10.9k (+4%) |
| IRM, one char at column 4, 10-char row | 10.5k | 3.3k |
| IRM at the last column | 8.9k | 1.8k |
| IRM, 80 chars typed onto an empty row | 715k | 198k |
| DCH at column 4, 80-char row | 12.7k | 13.1k (+3%) |
| DCH at column 4, 10-char row | 12.7k | 4.1k |
| DCH at the last column | 9.7k | 2.6k |

Full rows pay 3-4% (the bound bookkeeping); every short row -- an
editor's -- pays a third. Kernel +137 B (28,388 -> 28,525; VC_AWM's
two renderer checks, TT9_AWM, the shortcuts, the bounded halves).
New check-vt102 cases: `awm`, `awm_acs`, `smir_past` (all three
backends). Teeth: TTY_RUN's DECAWM check removed -> `awm` red;
TTY_PUT_PRNTB's -> `awm_acs` red; the past-the-end guard removed ->
`smir_past` red on `ut` (and the guard must sit BEFORE the shift: a
shift that starts at end+1 with the cursor beyond it walks X down
past the cursor, wraps through $FF and scribbles below TT9_RBUF --
seen as a wedged console when the guard was at the tail).

Still open from the review's debt list: HTS/TBC, origin mode,
terminal replies.

## 7. Follow-ups found by slice 1

- **DONE (2026-09-12, task #23 deliverable C).** `scripts/e2e_term.py`'s
  `text40` backend label did NOT force 40 columns: the play image
  boots native-80, so the `text40` legs of check-ildl and check-vt102
  exercised the N8 backend twice and the 40-column scroll path
  (`TTY_BK40`) never. Fixed by factoring `check_play.py`'s PT_F40
  patch bytes into `scripts/pt_f40.py` (the ONE copy, since
  check_play.py had hardcoded them rather than deriving them) and
  giving `e2e_term.boot()` the identical poke, landed the same place
  in the boot sequence (right after `reset`, before `mount_disk`).
  The label is HONEST from this commit: `text40` genuinely boots 40
  columns, and re-running check-ildl and check-vt102 on it found
  NOTHING the 40-column paths needed fixed -- the DCH/IRM/xenl work
  (slices 2/3, this doc) was already width-agnostic (CUP-clamped
  positioning where "the last column" mattered, no hardcoded column
  numbers), so it passed on a genuine 40-column console on the first
  try. "All three backends" now means three.
- **MAUXEDTEST.SYSTEM sat 4 bytes under PMLI_IBF_BASE** (2026-09-12).
  Slice 1's +554 B put it 70 B over; the table-driven ESC/CSI dispatch in
  tty2.s (`jmp (table,x)`, 3 B an entry instead of 7) and a shared scroll
  count clamp in tty9.s bought back 82 B, leaving only 4 B of margin --
  the NEXT kernel byte would have tripped it again. RETIRED the same
  day: scripts/build_ed_image.py now stages the 13 edtest fixture/
  script files (FIXTURES) that edtestb.s/edtestb2.s used to write from
  embedded `_TEXT` blocks at runtime, same precedent as de7ea88's
  build_ex_image.py FIXTURES table for MAUXEXTEST.SYSTEM. Result:
  30716 B (end $97FC, 4 B margin) -> 29053 B (end $917D, 1667 B
  margin), 1663 B reclaimed. Do not pin it.
- **DONE (2026-09-12).** Slice 2 (DCH + IRM) and slice 3 (xenl) --
  see sec 2/4/5 for the implementation and the gate.
- The host-vim-as-oracle case in sec 5 is BUILT (2026-09-12):
  `make check-tip-vim` (scripts/check_tip_vim.py) -- open, `j` x30, `dd`,
  `x`, insert-mode typing, `:q!`, each screen asserted against the edits
  applied to the file in Python. It found the serial receive path losing
  bytes under vim's first-screen burst (no flow control); the driver now
  speaks XON/XOFF (docs/SERIAL.md 3d), which is also what the `vt102`
  entry's `xon` flag promises.
- **New, found by slice 2/3.** `TTY_RUN`'s (was `TTY_UT_RUN`) batched printable-run
  path (procfd.s, docs/CONSOLE-RUN-BATCH.md) is a growing list of
  things it has to duplicate from `TTY_PUT_PRNTB` by hand (now: the
  IRM reject, the xenl consume/defer) because it is a genuinely
  separate renderer for the same semantics. Not a bug today -- both
  copies are correct and gated -- but the THIRD such duplication is
  the trigger to factor a shared helper instead of a third copy-paste.
  Perf slice 2 (2026-09-12) made it the renderer for EVERY backend, so
  the check-vt102 cases that used to go red on `ut` only (smir/rmir,
  xenl, acs) now guard all three legs -- and the run path's own encode
  is a second copy of TTY_WR_CELL's per-backend fold (card bit 7 vs
  text-page OR $80 + TTY_INVERSE_A). Same trigger applies.
- MouseText line drawing: the DEC special set renders as `+ - |` today
  (what termcap did for terminals without ACS). The //e's MouseText
  glyphs (ALTCHARSET is on) could draw real corners and bars; needs the
  IIe Technical Reference glyph table (in the commons) checked on all
  three backends before mapping. TT9_ACSMAP/ACSTAB is the one place.
- Slice 2's insert mode does one row read + write per typed character;
  fine for typing, and vim uses it only for that.
- **MAUXEXPR.SYSTEM's PMLI_IBF_BASE margin -- RETIRED as a wall
  (2026-09-12).** History: 92 B after slice 6 (49 after 6078bcb retired
  the runtime parameter fill; slice 6's +132 B put it 83 B over; packing
  the case table 8 -> 4 bytes a row bought 175 B back), 31 B after perf
  slice 2 (+150 B; the CSI cells laid contiguously and indexed -- the
  TTY_CSI_ATTR loop named here -- bought 70 B back). Then the case
  table itself left the image: src/test/exprcases.s at $1800, staged as
  /BASIC/EXPRCASES and READ by the harness at start-up (sec 6). Margin
  now 393 B. MAUXEXTEST has 1452 B, edtest 694 B.
- **vi's insert-mode tab echo is right; its erase of a typed tab is
  not** (2026-09-12, found fixing review finding VT3): VI_INS_ERASE moves the
  tail one cell left and blanks one cell whatever it erased, so
  erasing a typed TAB leaves up to 7 stale cells until ESC's repaint;
  VI_INS_TAIL/VI_PLACE_CUR place the cursor from the buffer line's OLD
  text, so a typed tab mis-places it until the line commits. Both
  pre-date slice 6 (they were wrong with the painting HT too) and are
  named here rather than fixed.
- check-dual is PARKED until nas (docs/TOOLCHAIN.md, TASKS #7 addendum):
  the VT102 work's 36 kernel globals filled real Merlin-8's symbol table.
  merlin32 is the assembler of record.
