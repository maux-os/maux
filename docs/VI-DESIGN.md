# vi design -- architect phase

Status: **IMPLEMENTED and shipped.** `vi` is built (`src/bin/vi.s` and
`vicmd.s`, `viscreen.s`, `vimotion.s`, `viinsert.s`, `viop.s`, `viop2.s`,
`virep.s`, `virg.s`, `vipage.s`, `vicache.s`, `vidmode.s`), documented in
`docs/man/vi.1`, and gated by `check-vi`, `check-vi-bang` and
`check-vi-alt` (plus `check-jobctl-e` for the cooperative `^Z`). This
is the original architect design, in the shape of `docs/EX-DESIGN.md`;
the module map (sec 6) and the sec 5 interface edits were built as
designed. Sec 9 lists where the build differs from the design. The
raw-tty seed it depends on (`SYS_TTYMODE`, cbreak+noecho, ^C-as-signal,
crash-safety reset-to-cooked) is a separate subsystem, treated below as
GIVEN.

## Library notes

Per `HACKING.md`'s street-library loop, fetched before the design:

- `learning:01M1FX8HT89CKR9CB8T8VKCW1S` -- *Ex Reference Manual v1.1* (Bill
  Joy, UC Berkeley, Nov 1977), **[fact]**, primary source. Settles: the full
  1977 `ex` command/option/addressing set (which `:`-mode inherits
  verbatim, already shipped), `window` defaults to 23, single-level undo
  ("undo is its own inverse"), `%`/`wq`/`x`-as-exit/`wrapscan` are **not**
  in this source (they are POSIX-era -- see the next handle), and the
  `g`/`v` widening precedent this project already leaned on for `ex`.
- `learning:01M1GQFV47MCWCAZ43XBN43DSZ` -- the ex/vi evolution timeline,
  **[fact]** against POSIX/SUS text and Vim's own `vi_diff.txt`. Pins:
  `wq`, `x`/`xit`, `ZZ`, `%`-as-`1,$`, `wrapscan` are POSIX-era (absent
  from 1977, present in the 1992 SUS text quoted verbatim) -- maux ships
  them as A12 modern-canonical, not as 1977-attested. Multi-level undo is
  a **Vim** (post-1991) addition, explicitly named in `vi_diff.txt`
  ("undo changes {Vi: only one level}") -- single-level is correct for
  BOTH 1977 and POSIX, confirming the operator's own ruling
  ("can't unbrain :wq and ZZ", both committed) rather than merely
  permitting it. Also carries the `ed`->`em`->`en`->`ex`->`vi` lineage: `vi`
  is literally **the visual mode of `ex`**, spawned as its own binary name
  at ex 2.0/2BSD (1979) -- not a separate program with its own command
  language.

WebFetch of the Joy & Horton rationale paper
(`docs-archive.freebsd.org/44doc/usd/12.vi/paper.html`) this session
returned a thin extraction -- confirms the operator-composition philosophy
("a small set of operators... combined with the motion commands... in a
simple and natural way", "regularity and... mnemonic assignment... makes
the command set easy to remember") and the terminal-independence goal
("vi will work on a large number of display terminals... new terminals
are easily driven after editing a terminal description file"), but did
not surface hjkl-specific rationale or an explicit modal-editing
justification. **Graded [reported], not mined further** -- the commons
copy noted in `learning:01M1FX8HT89CKR9CB8T8VKCW1S` as "confirmed
reachable but not deposited" remains a pickup for whoever needs the full
motion-key rationale; this design did not need it (the primary source
above already settles command syntax/semantics, which is what the
implementation actually depends on -- screen ergonomics do not need Joy's
own justification to be built correctly).

Commons search this session (`terminal cursor addressing screen redraw
scrolling region raw noecho tty`, `vintage-apple` scope) surfaced only
material already cited elsewhere in this tree (UltraTerm, IIe TRM cursor
routines, ProDOS monitor cursor keys, Merlin's own full-screen editor) --
nothing new and deposit-worthy for vi's own mechanism. No deposit made
this session; see the closing note for what a future pass could still
mine (sec 8).

## 1. The given facts (from the parallel tty-mode stream)

Stated as given -- not designed here, treated as the contract this
design builds against (all of it has since shipped):

- **Input**: a `SYS_TTYMODE` syscall, set-and-return-previous semantics,
  puts a console into cbreak+noecho. `^C` is **still** delivered as a
  signal, intercepted **upstream of the cook layer** (so raw mode does not
  lose `^C` handling by leaving cooked mode). A **kernel crash-safety
  reset to cooked** exists on process exit -- vi's own explicit restore
  (sec 4) is belt, this kernel guarantee is suspenders, not the other way
  around.
- **Output**: the existing cursor-addressing/CSI renderer
  (`src/kernel/tty2.s`'s `TTY_PUT_BYTE` and the `ESC [ ... H/A/B/C/D/J/K/m`
  subset `docs/CONSOLE.md` sec 6 documents, gated live by `TTY_VT_SUITE`),
  80-column via the UltraTerm/vidmode path (`docs/VIDMODE.md`). `SYS_TTYGEO`
  (12, already shipped -- `inc/sc.proc.equ:112`) reports
  `cols`/`rows`. **[fact]**: `rows` already excludes the console's own
  reserved row 0 (`docs/CONSOLE.md` sec 6, "a future backend reporting `rows`
  to userland must report 23, not 24") -- vi's own window math (sec 2) does
  not need to know row 0 exists at all.
- **Buffer**: the existing `ex`/`ed` swap-file buffer, `src/bin/exbuf.s`
  unchanged -- descriptor table + `EX.SWPxx` swap file, `ED_LINETEXT`/
  `ED_BUMP_ALLOC`/`ED_GETSLOT`/`ED_SETSLOT`/`ED_LTSLOT`/`ED_INSRT_AFTR`/
  `ED_DLT_RANGE` as the ONLY accessors (`docs/EX-DESIGN.md` sec 5 verified
  this is exhaustive -- no module indexes `ED_LINES` directly). vi reuses
  every one of these unchanged; no new buffer design in this document.
- **`:` command mode**: the existing `ex` engine -- `edparse.s`'s
  addressing/dispatch, `excmd.s`'s M2 commands (`q!`/`wq`/`x`/marks/`?re?`/
  `u`/`e`/`#`/`nu`), `edfile.s`/`edfil2.s`/`edsubst.s`/`edsub2.s`. Regex is
  `src/liba/regex.s` (now with `\(..\)`/`\1`-`\9` grouping, per
  `docs/EX-DESIGN.md`'s closing state). `:` in vi drops into this engine;
  sec 5 below is precise about how, because "drops into" is not free (the
  loop shape does not compose with vi's own event loop as written today).

## 2. The screen model

This is the one genuinely new subsystem -- everything else in this design
is new *orchestration code* over an existing buffer/regex/addressing
stack. Nothing below implies any change to exbuf's on-disk format, the
4-byte descriptor, or the single-line-cache contract
(`ED_LINETEXT`'s "valid only until the next call", `docs/EX-DESIGN.md`
sec 5.1) -- vi is simply the next caller that must respect it, same as every
`ed`/`ex` module already does.

### 2.1 The window

- `VI_TOP` -- the buffer line number displayed at the first text row.
- `VI_CURLINE`/`VI_CURCOL` -- the cursor's LOGICAL position: a buffer line
  number (shared meaning with `ED_CURLINE`) plus a byte offset into that
  line's text (from `ED_LINETEXT`'s NUL-terminated result).
- `VI_SCRROW`/`VI_SCRCOL` -- the cursor's on-screen position, derived from
  `VI_CURLINE - VI_TOP` (row) and a tab-stop-aware column computation
  (below) -- never trusted incrementally, always **recomputed** after any
  edit to the current line, for the reason in sec 2.4.
- Text area: `TTY_ROWS - 1` physical rows. The last reported row is vi's
  own **status/message line** -- file name + dirty flag + line count in
  normal display, the typed `:` command while composing one, error/status
  messages, and (deferred, sec 6) a `--INSERT--` mode indicator. This is
  exactly real vi's own bottom-line convention, and it composes cleanly
  with maux's own row-0 reservation: `SYS_TTYGEO` already reports the
  23-row *terminal* (row 0 excluded, per sec 1), so vi's own text area is
  `TTY_ROWS - 1` = 22 rows on the stock 40/80-column backends -- one row
  narrower than "classic" vi's 23-line text area on an unmodified 24-line
  terminal, because maux reserves an *additional* row for the console
  itself. Named, not fought: the ex manual's own `window` default of 23
  (`learning:01M1FX8HT89CKR9CB8T8VKCW1S`, **[fact]**) is a *different*
  option (how many lines `ex`'s own line-mode scrolling commands show),
  not vi's screen height, so there is no real inconsistency to reconcile,
  just a coincidence in the numbers worth not over-reading.

### 2.2 Redraw

Two repaint granularities, both operating directly against the buffer
through `ED_LINETEXT` (a swap-file `SET_MARK`+`READ` per line, same cost
model `docs/EX-DESIGN.md` sec 2.3 already priced for `,p`/`s///g`):

- **`VI_REPAINT` (full)**: walk `VI_TOP .. VI_TOP + textrows - 1`,
  `ED_LINETEXT` each, write it, stop early (blank remaining rows) at EOF.
  Used on: entry, `^L`, any vertical scroll (below), return from the `:`
  bridge, return from insert mode if it inserted/removed enough text to
  shift row counts (conservative: any insert-mode exit that touched more
  than the current line).
- **`VI_REPAINT_LINE` (current-line-only)**: re-fetch and rewrite just the
  row `VI_CURLINE` maps to. Used for the common case -- a char-wise edit
  confined to one line (`x`, `r`, most of insert mode while still on the
  same line, `.`-repeat of the same).

**v1 scope decision -- REVISITED 2026-09-10, the named trigger fired.**
The v1 rule was: ANY scroll triggers a FULL repaint, no reuse of the
kernel's hardware/CSI scroll. The operator hit exactly the named trigger
("scrolling feels slow... 400-500ms"), and the prescribed discipline was
followed -- measure first: a full-window repaint on the UltraTerm is
~480k cycles (~480ms), and the cost is the repaint pipeline, not the
card (which scrolls for ~nothing via a CRTC display-start bump). So the
"first thing to try" has been done:

- A scroll CSI now exists -- `ESC [ n S` (SU, `tty2.s` `TTY_CSI_SU`),
  riding the same `TTY_SCROLL` the bottom-margin newline uses (CRTC bump
  on the card, row-copy on 40/N8, store scroll on a background console).
  This is the new process-facing terminal surface sec 6 lacked.
- `VI_SCROLL_DN` now emits it and repaints only the exposed bottom rows
  when the window is unwrapped and moved less than a screen -- a
  single-line `j` scroll fell from ~480k to ~60-125k cycles (4-8x),
  line-for-line correct (gate: `check-vi` "j partial scroll tracks
  line-for-line").
- The reverse followed (both directions now done): `ESC [ n T` (SD,
  `tty2.s` `TTY_CSI_SD` -> `TTY_SCRL_REV`: a CRTC-start DECREMENT on the
  card -- IL/SD at row 0 is "move the pointer, zero one row," no data
  moves -- a downward row-copy on 40/N8, a store scroll on a background
  console). `VI_SCROLL_UP` emits it for a one-line `k` into an unwrapped
  window and redraws only the new top line (`VI_RPT_LN`); `k` fell the
  same ~480k -> ~40-115k. Gate: `check-vi` "k partial scroll-up tracks
  line-for-line", proven against a no-redraw sabotage.

**IL/DL now wired into the editor (2026-09-11).** The general
`ESC [ n L` / `ESC [ n M` (insert-line / delete-line) that the kernel
grew for all four backends (commit `393e435`) is now what `o`/`O`, a
linewise/charwise `d`, `dd`, `c`/`cc`/`C`/`S`/`s`, `p`/`P`, `J`, and the
`RETURN` split inside insert EMIT, instead of repainting from the cursor
to the bottom. `VI_RPINS` (open lines) positions to the cursor row,
emits `ESC [ n L`, paints only the new line(s) and then fixes the
painted-row table in place; `VI_RPDEL` (remove lines) emits `ESC [ m M`
for the removed lines' row count, pulls the table down over them, and
paints only what scrolls in at the bottom (or `~` rows once the file
ends on the glass). Both size the change by the ACTUAL line-count delta
(`ED_NLINES` captured before the delete), not the motion span -- a
no-join `dw` leaves `ED_ADDR2` on a line it does not remove, so the span
would overcount. Each fast path is gated on the shift being provably
rows-equal-lines (unwrapped around the change, `VI_TOP` unmoved) and
falls back to `VI_RPFROM` from the first changed line otherwise -- same
result, more bytes. Measured: a text-screen `o` repaint fell from 32,494
to 14,144 tty-write cycles and is now independent of how many lines sit
below the cursor (`scripts/profile_vi_repaint.py`); `check-vi` gains two
mid-full-window cases (`ildl:` o/dd) that a mis-shift corrupts. The
routines live in `viscreen.s` (VI_RPINS/VI_RPDEL/VI_ILSAVE/VI_ILADJCK/
VI_ILSLOW) and `virep.s` (VI_RP_LWD/CWD/VI_SAVESPAN/VI_DELCNT/
VI_OP_CWCHG -- split out of viop.s to keep its source buffer under the
real-Merlin-8 budget).

**Still FULL repaint:** only the paging keys now (`^F`/`^B`/`^D`/`^U`),
which set `VI_TOP` directly through `VI_PAGE_*` rather than a motion.
Forward paging (`^D`/`^F`) could reuse the SU path (`^D` ~half a screen
would halve its cost); `^F`/`^B` move a whole screen of new content and
a full repaint is near-optimal. Bigger-than-one-line `j`/`k` jumps and
wrapped windows also fall back (correct, just not optimized).

### 2.3 One logical line, N physical rows

A buffer line is capped at 254 bytes (the swap descriptor's 1-byte `len`
field, `docs/EX-DESIGN.md` sec 2.2/sec 5.2, itself inherited from
`CMDBUF_MAXLEN`). On an 80-column terminal that is up to 4 physical rows
per logical line; on 40-column, up to 7. vi **wraps**, it does not
truncate -- this is real vi's own behavior, not a maux invention, and it
falls out of `TTY_PUT_BYTE`'s existing "automatic wrap" (`docs/CONSOLE.md`
sec 6) for free at the *terminal* level. What vi's own window accounting
must do that the terminal does not: when walking `VI_TOP` forward during
a full repaint, each buffer line can consume more than one *physical*
row, so the repaint loop counts consumed rows (not lines) against the
`textrows` budget and can stop **mid-line** -- the remainder of a very
long line simply is not shown until the user scrolls further, same as
real vi on a small terminal. Buffer lines past EOF are shown as bare `~`
in column 0, the conventional vi empty-line marker -- **[reported]**, not
independently verified against a primary source this session (the Joy &
Horton fetch was too thin to confirm it, and the ex manual is line-mode
only), but universal enough across every attested vi lineage that
shipping it is low-risk; flagged honestly rather than cited to a source
that does not actually say it.

### 2.4 Column tracking has no readback

There is no "where is the cursor now" query from the terminal -- the same
shape this project already hit and solved for the UltraTerm's own VRAM
(`docs/CONSOLE.md` sec 10a: "VRAM is WRITE-ONLY over the bus... design so
the driver never needs a readback"). vi inherits that discipline: the
on-screen column for a given buffer byte offset is computed by vi itself,
mirroring the SAME 8-column tab-stop math `TTY_TAB` already implements
(`src/kernel/tty2.s:427-433`, `and #7` -- verified by reading the routine,
**[fact]**), never trusted to be "wherever the terminal happens to have
left it." `VI_SCRCOL` is therefore recomputed from `VI_CURCOL` and the
line's own text on every cursor move within a line, and cursor placement
is always an absolute `ESC [ r ; c H`, never a relative walk from an
assumed prior position -- cheaper to get right than to get subtly wrong
once, and the CSI absolute-position case is already gated
(`TTY_VT_SUITE`).

## 3. The mode model

Three modes, exactly `ex`'s own historical split of "command" vs. "open/
visual insertion" made concrete with a real screen: **command** (normal),
**insert**, **command-line** (`:`). No fourth mode -- no visual-selection
mode (`v`/`V`/`^V`), which is explicitly **not** period/POSIX vi at all
(it is an nvi/Vim-era addition layered on top of vi's own
operator+motion composition, e.g. `d3w` rather than `3vwd`) and the task
brief names visual-block as a Vim-ism to avoid; this design excludes it
outright rather than merely deferring it, since 1977/POSIX vi never had
it to begin with.

### 3.1 The raw-tty lifecycle

- **Entry**: `vi.s`'s `START` loads the initial file exactly as `ed FILE`/
  `ex FILE` already do (`edparse.s`'s `ARGC`/`GETARG`/`MKPATH`/
  `ED_READLOOP` path -- reused, see sec 5's interface note on splitting
  `START`), then calls `SYS_TTYMODE(cbreak, noecho)` and saves the
  returned previous mode in `VI_SAVEMODE`, then does one `VI_REPAINT` and
  enters command mode.
- **Exit** (every path -- `:q`, `:q!`, `:wq`, `:x`, `ZZ`, an unrecoverable
  swap-file I/O failure, a caught INT that the user lets terminate):
  `SYS_TTYMODE(VI_SAVEMODE)` **before** `SYS_EXIT`. The kernel's own
  crash-safety reset-to-cooked (sec 1) is the backstop for paths that don't
  reach this -- vi still restores explicitly on every path it controls, so
  the shell prompt that follows is never left waiting on the backstop for
  an ordinary quit.
- **`^C`**: delivered as a HELD signal per `docs/SIGNALS.md`'s v1 model --
  `SYS_SIGNAL(2, CATCH)` at startup (mirroring `sh`'s own `trap`
  mechanics, `docs/SIGNALS.md` sec 3), and vi's raw single-key `read(0,1)`
  in command mode is a BLOCKING syscall, which is exactly where
  `ERR_INTR` fires (`docs/SIGNALS.md`: "at `PRC_BLCK_RTRY`'s entry, if the
  current process has any pending CAUGHT signal, fail `ERR_INTR` instead
  of sleeping"). Since vi spends nearly all of its idle time blocked in
  that one read, this is the common, well-covered case: `^C` interrupts
  the read, vi treats `ERR_INTR` on the command-mode key read as "abort
  whatever count/operator prefix was pending, redraw the status line,
  stay in command mode" (matching real vi's own `^C`-during-editing
  behavior -- it does not quit the editor). `docs/SIGNALS.md` sec 1 names vi
  explicitly as "the likely first claimant" for a future async-handler
  upgrade ("a vi that must abort a redraw mid-loop"); this design's own
  read of that risk (sec 8) is that v1's poll-at-syscall-boundary model is
  *probably* sufficient because vi's redraws are bounded and interleaved
  with syscalls, not because the risk is imaginary -- see sec 8's explicit
  mitigation (a `SYS_SIGPEND` poll per repainted row) and open question.

### 3.2 Command (normal) mode

Default mode. Reads one raw byte at a time (sec 8 names the one real open
question about how many bytes a single `read(0)` hands back for a
CSI-framed key). Dispatches through count-prefix parsing, then motions,
operators, insert-entry, `:`, `u`, `.`, `ZZ` (sec 4).

### 3.3 Insert mode

Entered by `i a o O A I` (sec 4). A raw byte loop: printable bytes are
appended to a growing scratch line buffer AND echoed by vi itself via
`TTY_PUT_BYTE` (the tty's own echo is off, per cbreak+noecho -- vi is
responsible for making typed text visible, exactly the shape `ED_TEXTENTRY`
already has for `a`/`i`/`c` today, just character-at-a-time with live
echo instead of line-at-a-time from a cooked `read`). `RETURN` splits the
current insertion into a new line (an `ED_INSRT_AFTR` call, same as
`ed`'s own `a`/`i`/`c`); `ESC` finishes the current line (one
`ED_BUMP_ALLOC`+`ED_SETSLOT`, same handoff shape `exbuf.s`'s header
already documents for every reused caller) and returns to command mode.
The typed bytes are also recorded into `VI_LASTINS` for `.`-repeat (sec 4).

**Erase and the arrows (2026-09-10, `viinsert.s` `VI_INS_ERASE`).**
Left-arrow and DEL are `<erase>`: drop the last typed character, never
past the insert point, never joining lines (POSIX). On the //e the
left-arrow IS the backspace key (one wire with `^H`), and the kernel frames
it as one 3-byte line (`docs/CONSOLE.md` sec 4), so it no longer arrives
as an `ESC` that ends the insert -- which is how "I `o`'d a line and
Enter did nothing" happened: the insert had silently ended and Enter ran
as a command-mode key. Up/down/right still end the insert and move
(pushed back through `VI_UNGET` for command mode to read). The same two
erase keys work on the `:` and `/` lines (`VI_LNERASE`). In command mode
`RETURN` is `+` (next line, first non-blank; invalid on the last line;
linewise under an operator).

### 3.4 Command-line (`:`) mode

`:` clears and takes over the status line, echoes typed bytes there
(again: tty echo is off, vi echoes), reads until `RETURN`, then hands the
line to the SAME `ex` engine already shipped -- see sec 5's interface note,
because this is the one place "reuse unchanged" is not quite true as
written today. Real vi's own behavior when an `ex` command produces
scrolling output (`:g/re/p`, a multi-line `:r !cmd` once that lands) is
to let it scroll the terminal normally and prompt before returning to the
screen -- maux vi does the SAME thing, for the same reason real vi did:
`excmd.s`/`edfile.s`'s existing `PUTS`/`PUTC` calls to `FD_STDOUT`/
`FD_STDERR` need no interception at all if vi simply lets them write to
the live tty and does a full `VI_REPAINT` on return. Zero new output
plumbing, and it is period-authentic, not a maux shortcut.

## 4. Hot-path command tiers

Grading follows `docs/EX-DESIGN.md` sec 3's own convention:
`[fact]`/`[likely]`/`[reported]`, cited inline. **A12 discipline applied
explicitly against a real near-miss**: `gg` (go to first line) is a
**Vim-only** addition -- original/POSIX vi has no `gg`; the period-correct
spelling is `1G` (count-prefixed `G`, which this design ships anyway).
Caught and excluded here rather than shipped by habit, the same kind of
catch `docs/EX-DESIGN.md` sec 3's `wq`/`x` correction made against the
primary source.

### 4.1 Tier 1 -- can't-live-without

| command | behavior | grade / reuse |
|---|---|---|
| `h j k l` | char/line motion | new (vimotion.s) |
| `w b e` | word motion (fwd-start, back-start, fwd-end) | **[reported]**, new |
| `0 ^ $` | line-start, first-non-blank, line-end | **[reported]**, new |
| `G` (count = line N, none = EOF; `1G` = top) | **[fact]** POSIX/1977 lineage -- no `gg` (Vim-only, excluded) | new, reuses `ED_NLINES` |
| `f t F T` `;` `,` | find/till char in line, repeat | **[reported]**, new |
| `/re` `?re` `n` `N` | search fwd/back, repeat same/reverse | **[fact]** addressing -- direct reuse of `ED_SEARCHFWD`/`EX_SEARCHBACK`/`ED_LASTRE` (`docs/EX-DESIGN.md` sec 1.3/sec 3.1), UNCHANGED. Three-way `n` collision resolved by namespace, not spelling: `ed`'s `n`=numbered-print, `ex`'s `:n`=next-file, vi's normal-mode `n`=repeat-search coexist because they are keyed by MODE, not letter |
| count prefix | `3dd`, `5j`, `10G` | new, parser shape copies `ED_PARSENUM` (`edparse.s:566-596`) verbatim against vi's own key buffer |
| `d`/`c`/`y` + motion | delete/change/yank a span | new (viop.s), sec 4.3 |
| `x` | delete char forward | new, one-byte case of the above |
| `dd cc yy` `D C Y` | whole-line / to-end-of-line forms | new |
| `p P` | put after/before the unnamed or a named (`"a`-`"z`) register | new; named registers and the multi-line register live in virg.s (sec 4.4) |
| `J` | join current+count lines | **[fact]** -- direct reuse of `ED_CMD_J` (`edsub2.s`), vi only needs to set `ED_ADDR1`/`ED_ADDR2`/`ED_ADDRCNT` first |
| `i a o O A I` | insert-mode entry | new (viinsert.s), sec 3.3 |
| `.` | repeat last change | **[reported]** (attested across every vi lineage checked, not independently verified against a primary source this session -- see sec 8) |
| `u` | single-level undo | **[fact]** single-level is period-correct (both handles above) -- reuses `EX_CUNDO`'s block-swap core (sec 5 interface note) |
| `:` | ex command-line bridge | **[fact]** -- reuses the full `ex` engine, sec 3.4/sec 5 |
| `ZZ` | write-if-modified, quit | **[fact]** POSIX (`learning:01M1GQFV47MCWCAZ43XBN43DSZ`) -- same semantics as `ex`'s own `x`, reused core (sec 5) |

### 4.2 Tier 2

`R` (overtype/replace mode until `ESC`), `r` (replace one char), `~`
(toggle case under cursor), `%` (matching-bracket motion, **[reported]**),
`` ` `` and `'` as normal-mode motions to a mark (distinct from `ex`'s own
`'x` ADDRESS token which `:` already inherits -- vi binds the SAME
`EX_MARKS` table, `excmd.s`, as motions, not just addresses), `autoindent`
(copy the current line's leading whitespace into a new line from `o`/`O`/
insert-mode `RETURN` -- **[fact]** the option exists in 1977 `ex`, default
off, `learning:01M1FX8HT89CKR9CB8T8VKCW1S`; `docs/EX-DESIGN.md` sec 3.4
already deferred it explicitly "to the `vi` phase" as a named pickup),
`set`-driven behavior already shipped for `ex` (`wrapscan`/`ignorecase`
etc., `docs/EX-DESIGN.md` sec 3.2) becoming visible through vi's own motions
(e.g. search wrap) at no extra cost since it is the SAME `ED_SEARCHFWD`
call.

### 4.3 How operators compose with motions -- the actual mechanism

Every `ed`/`ex` mutation falls into the same two shapes
`docs/EX-DESIGN.md` sec 2.3 already named for the buffer layer, and vi's
operators split along the identical line:

- **Linewise operators** (`dd`, `d}`-style whole-line spans, `dj`, `dk`,
  `dG`) compute a `[ED_ADDR1, ED_ADDR2]` line range from the motion and
  call `ED_DLT_RANGE`/`ED_INSRT_AFTR` **directly** -- the exact primitives
  `edbuf.s`/`exbuf.s` already export, zero new buffer logic. `yy`/`y` +
  linewise motion reads the range's text into `VI_REG` (the unnamed
  register, sec 4.4) without deleting.
- **Charwise operators** (`dw`, `d$`, `dfx`, `de`, `x`) that do not span
  whole lines need a small NEW primitive: fetch the current line via
  `ED_LINETEXT`, splice out the selected byte range in a resident scratch
  buffer, then one `ED_BUMP_ALLOC` + `ED_SETSLOT` to repoint that single
  line's descriptor. This is not invented from nothing -- it is the same
  shape `edsubst.s`'s `ED_DO_SUBST` already uses to build a rewritten line
  in `SUBSCR` before one `ED_BUMP_ALLOC` call (`docs/EX-DESIGN.md` sec 2.3) --
  viop.s's splice routine is a sibling of that, not a new pattern.

### 4.4 Registers (named registers: virg.s, 2026-10-06)

`y`/`d`/`c` write the affected text into the unnamed register, in one of
three shapes (`VI_REGTY`): 0 = a charwise one-liner in `VI_REG` (254 bytes,
low BSS), 1 = linewise, 2 = charwise spanning lines. Types 1 and 2 are a
packed list of strings in the process language card (the `EX_SHADOW`
pattern), not in the low window: the old 24 x 256 byte `VI_REGLBUF` was
6 KB of a window with ~340 bytes to spare. A named register `"a`-`"z` is a
saved copy of that state in the same arena (27 `{off,len}` entries, one
arena of `VI_RGCAP` bytes shared by all, an entry that does not fit leaves
that register empty with a BEL). `"x` + command sets a pending selector the
yank/delete cores (`VI_RG_STORE`) and the puts (`VI_RG_LOAD`) consume; the
unnamed register ends up holding the last register used, as vim's does.
Not implemented, and errors: `"A`-`"Z` append, `"1`-`"9`. `y`/`d`/`c` also
take `/` `?` `n` `N` as motions (`VI_SMO_PRE/POST`, visearch.s), which is what
makes a charwise span cross lines in practice. Full contract: the header of
`src/bin/virg.s`; notes: `docs/VI-GAPS-2-NOTES.md`.

## 5. Interfaces between existing `ex` modules and new `vi` modules

Everything in sec 4.3's linewise case, `J`, `/`/`?`, and the buffer accessors
themselves reuse `edbuf.s`/`exbuf.s`/`edsub2.s` etc. with **zero** edits.
Four places do NOT compose as written today and need a small, explicit,
precedented change -- each one mirrors a hook pattern `excmd.s`'s own
header already documents four times over (`EX_CMD`/`EX_PREMOVE`/
`EX_MUTCHECK`/`EX_MARKREF`/`EX_SEARCHBACK`/`EX_ONWRITE`/`EX_MARK_INS`/
`EX_MARK_DEL` -- a no-op stub in `edbuf.s` for `ed`, a real routine in
`exbuf.s`/`excmd.s` for `ex`). These are the ONLY touches outside brand-new `vi*.s` files (items 1-4
were built; see sec 9 for item 5):

1. **`edparse.s`'s `START` must split.** Today `START` loads an optional
   argv file then falls through unconditionally into `MAINLOOP`, which
   blocks reading fd 0 forever. vi needs the file-load half but NOT the
   fd-0 loop (it drives its own raw-key command loop instead). Split
   `START` into `ED_STARTFILE` (argv handling, MKPATH, `SC_OPEN`,
   `ED_READLOOP` -- returns instead of falling through) and leave the
   existing `MAINLOOP`-entry tail for `ed`/`ex`'s own CLI wrapper.
   `vi.s`'s own `START` calls `ED_STARTFILE`, then branches to its own
   command loop.
2. **`edparse.s`'s `MAINLOOP` body must expose a "dispatch ONE command
   line" entry.** `MAINLOOP` is an infinite loop reading fd 0; every
   command handler ends with `jmp MAINLOOP` (`excmd.s`'s own header:
   "NEVER `rts`"), so nothing outside it can call in and get a return.
   vi's `:` bridge needs exactly one parse-and-dispatch pass per typed
   command line, then a return to its OWN loop. Factor the parse+dispatch
   body (address parse, `EX_PREMOVE`, `EX_CMD`, the classic
   `a i c d p n q r w s g m t j =` chain) into `ED_DISPATCH1`, called
   with `ED_CMDPTR` pointing at a caller-supplied line (vi's own
   status-line-read buffer, not `CMDBUF`/fd 0) and returning normally
   after ONE command instead of looping. `MAINLOOP` becomes a thin
   "read a line from fd 0, call `ED_DISPATCH1`, repeat" wrapper --
   behavior-preserving for `ed`/`ex`, and the new entry point vi needs.
3. **A `EX_ONQUIT` hook, same shape as `EX_ONWRITE`.** `EX_CQBANG`
   (`q!`), `EX_CWQ` (`wq`), `EX_CX` (`x`) each call `SYS_EXIT` directly
   after `ED_QCLEANUP`. vi's `:q`/`:q!`/`:wq`/`:x`/`ZZ` need the
   IDENTICAL dirty-check/write/cleanup logic but must ALSO restore
   `VI_SAVEMODE` (sec 3.1) first. Add one `jsr EX_ONQUIT` immediately before
   each of those three `EXIT` calls -- a no-op `rts` stub in `ed`/`ex`
   (matching `edbuf.s`'s existing no-op stubs for the other five hooks),
   a real `SYS_TTYMODE(VI_SAVEMODE)` call in vi's own binary. `ZZ` in vi
   calls the SAME `EX_CX`-shaped tail directly (it is two keystrokes in
   command mode, never typed after `:`, so it cannot route through
   `EX_CMD`'s text-match dispatch -- it calls the underlying write+cleanup
   routine, now `EX_ONQUIT`-clean, straight from `vicmd.s`).
4. **Factor `EX_CUNDO`'s block-swap core out of its command-line-token
   wrapper.** `EX_CUNDO` today is entangled with `EX_CMD`'s dispatch
   contract (reads `ED_CMDPTR`, checks `ED_ADDRCNT==0`). vi's `u` key is
   not typed after `:` and carries no such token to parse -- it needs the
   underlying `EX_BLKSWAP`-based table swap + `EX_DIRTY` set directly.
   Factor that body into `EX_UNDO_CORE`, called by both `EX_CUNDO`'s
   existing wrapper (`:u`) and `vicmd.s`'s `u` key handler.
5. **(Recommended, not required) an `EX_BAREADDR` hook for `:N`.** In
   `ed`/`ex`, a bare address with no command (`:42`) falls through
   `edparse.s`'s `:bareaddr` to `ED_CMD_P` -- print the line, scrolling the
   terminal. Real vi's `:42` instead **moves the cursor and repaints** --
   it is a goto, not a print. Recommend the same no-op/real hook shape:
   `EX_BAREADDR`, no-op-falls-through-to-`ED_CMD_P` in `ed`/`ex`, real
   `VI_CURLINE`-set in vi (letting the normal post-`:` `VI_REPAINT`
   handle display). Small, cheap, and closes the one visible behavioral
   gap between "drop to `:`" and real vi's own `:N` idiom -- worth doing
   in the same pass as items 1-4 since it touches the identical call
   site, but does not block anything else in this design if deferred.

## 6. Module map

Mirrors `docs/EX-DESIGN.md` sec 5's shape: new files own new state and call
into the reused engine only through the interfaces above.

- **`vi.s`** (NEW) -- manifest, ZP map, `put` order, `START` (calls
  `ED_STARTFILE`, `SYS_TTYMODE` set, first `VI_REPAINT`, falls into the
  command loop). Owns: `VI_TOP`, `VI_CURLINE`/`VI_CURCOL`,
  `VI_SCRROW`/`VI_SCRCOL`, `VI_SAVEMODE`, `TTY_ROWS`/`TTY_COLS` cached
  from `SYS_TTYGEO` at startup (geometry is queried once -- no resize
  events on this hardware).
- **`viscreen.s`** (NEW) -- the screen manager: `VI_REPAINT` (full),
  `VI_REPAINT_LINE`, `VI_STATUS_MSG` (write to the reserved bottom row),
  `VI_PLACE_CURSOR` (absolute CSI positioning from `VI_SCRROW`/
  `VI_SCRCOL`), the tab-stop column math (sec 2.4), the tilde-fill-past-EOF
  logic (sec 2.3). Depends on: `ED_LINETEXT` only (read-only against the
  buffer) plus `TTY_PUT_BYTE`/CSI writes (kernel tty, unchanged).
- **`vimotion.s`** (NEW) -- `h j k l w b e 0 ^ $ G f t F T ; ,`, the
  count-prefix parser, and thin wrappers over `ED_SEARCHFWD`/
  `EX_SEARCHBACK` for `/`/`?`/`n`/`N`. Exposes `VI_DOMOTION` (IN: motion
  key + pending count; OUT: new `VI_CURLINE`/`VI_CURCOL`, OR -- when
  called as an operator's argument -- a `[start,end)` span plus a
  linewise/charwise flag for `viop.s` to consume). Depends on:
  `ED_LINETEXT` (read-only), `ED_LASTRE`/`ED_SEARCHFWD`/`EX_SEARCHBACK`
  (unchanged reuse).
- **`viop.s`** (NEW) -- `d c y` + motion composition, `x dd cc yy D C Y
  J p P r ~`, the unnamed register (`VI_REG`), `EX_SNAPSHOT`-before-mutate
  (called directly, NOT through `EX_MUTCHECK`'s letter-keyed hook -- vi's
  own command loop is not `edparse.s`'s dispatch chain, so it calls
  `EX_SNAPSHOT` itself once per user-visible mutating command, same
  one-snapshot-per-command discipline `EX_MUTCHECK` already established),
  and `.`-repeat bookkeeping for operator-class commands (record a
  symbolic descriptor: which operator, which motion, what count -- NOT raw
  keystrokes, since an operator+motion combo is already small and
  bounded, unlike free-form inserted text). Depends on: `ED_LINETEXT`,
  `ED_BUMP_ALLOC`, `ED_SETSLOT`, `ED_DLT_RANGE`, `ED_INSRT_AFTR`,
  `ED_CMD_J` (all unchanged), `VI_DOMOTION` (vimotion.s), `EX_SNAPSHOT`
  (exbuf.s, unchanged), `VI_REPAINT`/`VI_REPAINT_LINE` (viscreen.s).
- **`viinsert.s`** (NEW) -- `i a o O A I`, the raw-byte insert loop with
  live application-level echo, `RETURN`-splits-line via `ED_INSRT_AFTR`,
  `ESC`-exit via `ED_BUMP_ALLOC`+`ED_SETSLOT`, `VI_LASTINS` recording for
  `.`-repeat of insert-class commands. Depends on: `ED_BUMP_ALLOC`,
  `ED_SETSLOT`, `ED_INSRT_AFTR` (unchanged), `TTY_PUT_BYTE` (echo),
  `EX_SNAPSHOT` (once, on entry to insert mode, per sec 5 item 4's
  discipline).
- **`vicmd.s`** (NEW) -- the top-level command-mode key dispatch tying the
  above together; the `:` bridge (status-line read -> `ED_DISPATCH1`,
  sec 5 item 2 -> `VI_REPAINT` on return); `ZZ` (-> `EX_ONQUIT`-clean tail,
  sec 5 item 3); `u` (-> `EX_UNDO_CORE`, sec 5 item 4); `.` dispatch (replays the
  recorded operator-descriptor or `VI_LASTINS`); `^C`/`ERR_INTR` handling
  (sec 3.1); the count-prefix-then-key top switch.
- **REUSED UNCHANGED** (put by `vi.s`, after the four small interface
  edits in sec 5 land): `exbuf.s`, `edparse.s`, `excmd.s`, `edfile.s`,
  `edfil2.s`, `edsubst.s`, `edsub2.s`, and all of `liba` (`regex.s`/
  `regex2.s`, `seek.s`, `mli.s`, `hex.s`).

Dependency order, which still holds: `viop.s` needs `vimotion.s`'s
`VI_DOMOTION` contract (the span/flag shape it returns), and `vicmd.s`
needs the entry points of the other four.

## 7. Gate strategy

**vi is fundamentally an interactive/raw-tty/screen program -- there is no
`vi < script` equivalent** the way `ex`'s `check-ex` gate redirects fd 0
(`docs/EX-DESIGN.md` sec 5.6/sec 6). A meaningful gate for vi's own screen
behavior REQUIRES the raw-keyboard driver `scripts/check_play.py` already
has (proven at `ex`'s own check-play phase, sec 6 of `docs/EX-DESIGN.md`, and
`more.s`'s own "stty seed" precedent). Proposed `check-play` `vi` phase,
same discipline as `ex`'s (cell-by-cell assertions, sabotage-proven red-
then-green, not "screen looks right"):

1. Launch `vi FILE` against a small fixture; assert the initial paint
   (line 1 at the text area's first row, `~` fill below EOF if the
   fixture is short, status line shows the filename).
2. Motions: `j`/`k`/`w`/`0`/`$`/`G` typed, cursor position asserted via
   the CSI target the harness can read back from screen state (same
   technique `TTY_VT_SUITE` already uses to assert absolute positioning).
3. Operators: `dd` on a known line, assert both the screen (line removed,
   everything below shifted up one row) AND -- via `:wq` at the end --
   the file on disk, cross-checked by `cat`-ing it back (the exact
   technique `docs/EX-DESIGN.md` sec 6 used for `ex`'s own `w`).
4. Insert mode: `i`, type a line, `ESC`; assert live echo happened
   character-by-character (not just the end state) since that is the one
   behavior a fd-0-redirected test could never distinguish from cooked
   `a`/`i`/`c`.
5. `:` bridge: `:s/OLD/NEW/`, assert the substitute landed exactly as
   `check_ex.py` already asserts for plain `ex`.
6. `ZZ`: assert the file was written (same `cat`-back) AND that the
   session actually exited AND -- the vi-specific assertion `ex`'s own
   gate had no reason to make -- that the tty mode was RESTORED: type a
   character at the shell prompt that follows and confirm it echoes
   normally (cooked mode came back). This is the sabotage-provable claim
   this whole design is built around; it needs to be a real assertion,
   not an assumption.
7. `^C` mid-session: interrupt a pending count/operator prefix, assert
   the editor is still alive and in command mode (not quit, not hung).

**Scriptable pieces, to keep the slow/flaky interactive gate for what
only it can prove**: `vimotion.s`'s word-boundary scanner and `viop.s`'s
charwise splice-and-repoint routine are pure buffer-text logic with no
tty dependency -- these can get an `extest`-style harness (poking buffer
state directly and asserting descriptor/text results, the same shape
`EXTEST_DEPS` already uses for `ex`'s own regex/descriptor logic,
`Makefile:1641-1644`) rather than being proven only through a keyboard
session. Reserve `check-play`'s vi phase for what genuinely needs a real
tty: redraw correctness, cursor position, raw key framing, and the
tty-mode restore assertion above.

**Self-host size risk, named proactively rather than discovered**: `ed`
and `ex` are already pinned **tier-2** (no self-assembly,
`check_librelas.py`'s `TIER2_BASELINE` (deleted 2026-10-18), `docs/EX-DESIGN.md`'s own
2026-09-02 ruling) purely on feature+test growth outrunning the native
assembler/linker -- `vi` adds five wholly new modules (screen management
is genuinely new code, unlike `ex`'s mostly-reused command engine) on top
of that, so it should be **pinned tier-2 from the start**, not discovered
via a failing self-host gate the way `ed`/`ex` were. Separately, `ed`'s
own code-size scare (`docs/IDE.md` sec 3, "98.2% of a bank") turned out to
be stale the same day it was measured, because the `sbrk()`-heap rewrite
had already moved the buffer arena out of the image (`docs/EX-DESIGN.md`
sec 2.4: `build/ed.bin` measured 6,461 bytes against a 46,848-byte window,
~40 KB headroom). vi inherits that same fix for free (the buffer is
still the swap file via unchanged `exbuf.s`), so vi's size risk is
specifically about the NEW screen/motion/operator code, not the buffer --
and that headroom should NOT be assumed comfortable without measuring,
since vi's new code is materially larger than `ex`'s was. **Recommend an
early "hello screen" checkpoint**: build `vi.s` + `viscreen.s` + the
reused `ed`/`ex` modules with NO motion/operator/insert code yet, measure
the image, and use that as the real starting budget for the remaining
four modules -- the same "measure early" lesson `docs/EX-DESIGN.md` sec 2.4
itself drew from `ed`'s own false alarm.

## 8. Open questions / risks

1. **Raw-mode input framing (blocks nothing structural, blocks
   `vimotion.s`'s exact shape)**: does a single `read(0, N)` in
   cbreak+noecho mode hand back a CSI-framed key (an arrow, or an
   Open-Apple/Meta-prefixed key per `docs/CONSOLE.md` sec 4b's existing
   cooked-mode precedent -- "OA-down pushes ESC ahead of the key into the
   raw ring") as one atomic multi-byte unit, or byte-by-byte, requiring
   vi to run its own small escape-recognizer state machine (mirroring the
   kernel's own output-side `VC_ESC_STATE` parser) to disambiguate a bare
   `ESC` (exit insert mode / abort a pending prefix) from the first byte
   of a longer sequence? `TTY_KEYIN` already frames SOME multi-byte
   sequences below the cook layer (the arrows-become-CSI conversion,
   `docs/CONSOLE.md` sec 4b), which suggests raw mode likely inherits that
   framing -- but this was not verified against the parallel tty-mode
   stream's actual implementation, since it did not exist to read at
   design time. **Needs a one-question check-in with that stream before
   `vimotion.s` is written**, not before this design is accepted.
   **RESOLVED 2026-09-10: framed.** The answer at first was byte-by-byte
   (three 1-byte "lines"), and vi's insert loop paid for it: the arrow's
   `ESC` ended the insert. The raw cook now commits an arrow as ONE
   3-byte line (`tty7.s` `TTY_COOK_RAW`; `docs/CONSOLE.md` sec 4), and
   `VI_RAWKEY` reads 3 at a time -- 1 back is a key, 3 back is an arrow,
   returned as `VI_KUP..VI_KLEFT`. No state machine, no timeout.
2. **`SYS_TTYMODE`'s exact syscall number/parameter encoding** -- this
   design assumes "set-and-return-previous" semantics per the task brief
   and writes `vi.s`'s `START`/`EX_ONQUIT` against that shape. Low risk
   (the contract given is simple and unlikely to change materially), but
   a one-line adjustment is expected once the real signature lands.
3. **`^C` responsiveness during a non-blocking, WRITE-heavy full
   repaint** (sec 3.1): `ERR_INTR` only fires at a BLOCKING syscall's retry
   point (`docs/SIGNALS.md`); a `VI_REPAINT` that issues many `WRITE`
   syscalls without ever blocking would not itself be interrupted
   mid-paint under the v1 signal model -- the pending signal is caught
   (never lost) but not *acted on* until the next blocking point (the
   following raw-key read). Mitigation designed in but not proven: insert
   an explicit `SYS_SIGPEND` poll once per repainted physical row inside
   `VI_REPAINT` (cheap -- one syscall per row, dozens of rows at most),
   so a slow repaint (e.g. a cold swap-file read on a large file) still
   responds to `^C` within roughly one row's latency rather than only at
   the next keystroke. `docs/SIGNALS.md` sec 1 already names vi as the
   predicted first program to strain the v1 held-signal model; this
   design's bet is that the per-row poll keeps v1 sufficient without
   needing the async-handler upgrade that document flags as the
   eventual trigger -- worth confirming against the real interactive gate
   once built, not merely asserted here.
4. **`.` (dot-repeat) is graded `[reported]`, not verified.** Both
   commons handles fetched for this design are `ex`-manual-focused (ex
   itself, as a line editor, has no `.` command); the Joy & Horton fetch
   this session was too thin to confirm `.`'s original-vi provenance
   directly. It is universal enough across every vi lineage checked
   (informally) that shipping it in v1 is low-regret, but per this
   project's own confidence discipline (HACKING.md's confidence grades: "`[reported]`
   claims a design depends on must be verified first") it should not be
   treated as settled without a primary source. **Deposit-worthy pickup**
   for whoever mines the full Joy & Horton text or a POSIX vi(1) page
   next -- the commons currently has no explicit citation for `.` at all.
5. **Explicitly deferred** (named, not silently dropped): `:map`/`:ab` (macros/abbreviations -- already deferred by
   `docs/EX-DESIGN.md` sec 3.3 "meaningless in a line editor", now genuinely
   in scope for vi but still cut from v1), `open` mode (`ex`'s own
   degraded line-mode fallback for non-visual terminals -- has no use case
   once raw+cursor-addressing exists, which is vi's whole premise),
   split windows and visual-selection mode (both explicitly Vim/nvi-era,
   excluded per the task brief and sec 3's own note), multi-level undo
   (Vim-era, explicitly excluded -- single-level is the period-correct AND
   POSIX-correct choice, both handles above), `gg` (Vim-only -- `1G` ships
   instead, sec 4.1), text-object motions beyond the basic word/line/char
   set (`i(`/`a"` etc. -- nvi/Vim territory), `:ta`/ctags (no ctags
   equivalent exists yet, same cut `docs/EX-DESIGN.md` sec 3.3 already made).
6. **The quickfix hook `docs/IDE.md` sec 4 names** (`as` writing
   `file:line: message`, vi jumping to it) is NOT designed here -- it is
   future `as` work per that document's own scope. This design does not
   block it: sec 5 item 5's `:N`-as-goto behavior (or a `-c`/`+N` argv
   convention on launch, not designed here either) is the natural landing
   spot when that arrives.
7. **The four `edparse.s`/`excmd.s` interface edits in sec 5 are built**
   (`ED_STARTFILE`, `ED_DISPATCH1`, `EX_ONQUIT`, `EX_UNDO_CORE`). Any
   future `ex` maintenance must keep them: `ed`, `ex` and `vi` all
   link these files.

## 9. As built -- where the code differs from this design

Checked against `src/bin/vi*.s`, `docs/man/vi.1` and the Makefile.

- **`.`-repeat records KEYSTROKES, not a symbolic descriptor.** Sec 6
  (`viop.s`) says operator-class repeat records "which operator, which
  motion, what count -- NOT raw keystrokes". What shipped
  (`VI_RAWKEY`, `vicmd.s`, 2026-09-05) records every byte the single
  key-read choke point returns into `VI_RECBUF` (armed once per command
  by `VI_DOT_ARM`), commits it to `VI_DOTBUF`, and replays by serving
  `VI_RAWKEY` from that buffer. One mechanism covers insert text and
  operator+motion alike.
- **Item 5, `EX_BAREADDR`, was not built.** No such hook exists in the
  tree; `:N` goes through `edparse.s`'s `:bareaddr` like `ex`.
- **Sec 8 item 3's per-row `SYS_SIGPEND` poll inside `VI_REPAINT` is not
  there.** `viscreen.s` makes no `SC_SIGPEND` call; pending signals are
  popped in `VI_RAWKEY` (`vicmd.s`) and `vimotion.s`.
- **Modules beyond the map:** `viop2.s`, `virep.s` (delete/change
  redisplay helpers split out for the source-buffer budget), `virg.s`
  (named registers, sec 4.4), `vipage.s`, `vicache.s`, and `vidmode.s`.
  `VI_SAVEMODE` is `VI_SAVEMD` (a zero-page cell, `$86`).
- **Cooperative `^Z` was added** after this design:
  `docs/JOB-CONTROL.md` Increment E (`SIGTSTP` = signo 14,
  `VI_SUSPEND`, `SYS_STOP`).
- **Sec 8 items 1 and 2 are resolved** (arrows arrive framed; the
  `SYS_TTYMODE` signature landed). Item 5's cuts (`gg`, `:map`,
  `R`, visual mode, ctags) still hold; `docs/man/vi.1` BUGS lists the
  implemented subset (no `gg`, no `R`, no normal-mode `!` filter).
