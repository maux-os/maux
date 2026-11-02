# maux console and terminal architecture

Status: LIVE (src/kernel/tty*.s, gated by `check-play` and its family).
Started as a design note plus first implementation slice, 2026-08-15; the
later dated sections record what shipped (virtual consoles, UltraTerm,
native 80 columns, the console store, multi-mode consoles) and the
sections are not renumbered, so several section numbers repeat. This document
supersedes the earlier "tty driver writes the Apple text page" shorthand in
`docs/ARCHITECTURE.md`. The ruling is that maux has a terminal subsystem, not a
ROM-console wrapper. The first slice was intentionally small: `FD_TTY0`,
blocking cooked keyboard input, a steady inverse-space cursor, boot-screen
body clearing, 40-column text output, a small stateful VT-style output parser,
a VBL-polled tty wake path with an idle process in the playable image,
`make play-image`, and `make check-play`.

## 1. Ruling

The console is layered:

```
process fd
  -> tty character device
    -> line discipline
      -> small VT-style terminal emulator
        -> virtual-console surface
          -> display backend
```

The Apple ROM console is not the model. It is too tied to one physical display
shape and falls short of what Unix-style programs expect. maux programs should
see file descriptors and terminal behavior; the Apple display is just one
backend.

## 2. V1 scope

V1 should deliver enough console to make the system playable:

- fd 0/1/2 backed by `tty0`;
- blocking `read(0)`;
- cooked input with echo and backspace;
- `write(1)`/`write(2)` through a small terminal parser;
- one active virtual console (`vc0`) with state shaped so more can be added;
  **-- NOT TRUE OF THE IMPLEMENTATION, see sec 12.**
- Apple 40-column text fallback;
- UltraTerm as the preferred serious text backend when detection/support is
  ready.

Apple 80-column support is deferred. It is useful, and the Business BASIC port's
driver may be a good source of technique, but it should not block the first
real terminal. UltraTerm is a better Unix console target because it gives the
system enough columns to feel like a development environment.

## 3. File descriptors

The PCB fd table already stores one byte per fd, with OFT indices occupying the
small positive range. Device descriptors should use high-bit values that cannot
collide with `OFT_COUNT`:

```
FD_CLOSED    = $00
FD_DEV_BASE  = $80
FD_TTY0      = $80
FD_TTY1      = $81
FD_TTY2      = $82
FD_TTY3      = $83
```

The boot shell starts with:

```
fd 0 = FD_TTY0
fd 1 = FD_TTY0
fd 2 = FD_TTY0
```

Redirection and pipes replace those entries with OFT indices. Closing a tty fd
marks the fd closed and does not touch OFT refcounts.

The process syscall layer dispatches by fd value:

```
read:
  FD_TTYn    -> TTY_READ(n)
  OFT_PIPE_R -> PIPE_READ
  OFT_FILE   -> FILE_READ

write:
  FD_TTYn    -> TTY_WRITE(n)
  OFT_PIPE_W -> PIPE_WRITE
  OFT_FILE   -> FILE_WRITE
```

## 4. Line discipline

SYS_TTYMODE carries three bits now -- TMD_ICANON, TMD_ECHO, and TMD_OPOST
(VT102 slice 1, sec 6a below): OPOST governs whether an outgoing CR is a
full newline (cooked default) or column-0-only (raw, strict VT102) at the
TERMINAL layer -- orthogonal to ICANON/ECHO, which govern INPUT.

Cooked mode (the default; raw mode is `stty raw -echo`, 2026-09-02):

- printable keys append to the current line and echo;
- left-arrow (`$08` after clearing the Apple II high bit) and DEL (`$7F`)
  both erase within the uncommitted current line and erase visually;
- `^U` kills the current uncommitted line and erases it visually;
- `^D` on an empty line returns zero bytes to the reader, which `sh` treats as
  EOF;
- Return appends `$8D`, echoes a newline, commits the line, and wakes readers;
- `read(0)` returns only committed bytes;
- reads with no committed data block on the tty's read wait channel.

The first implementation uses the scheduler's per-tick hook to poll one key per
VBL tick. `TTY_READ` polls once synchronously, then sleeps on `TTY_RD_CHAN` when
no committed bytes are ready. A committed line or empty-line EOF wakes that
channel. The playable image includes a tiny idle process so the run queue never
empties while the shell is blocked on the keyboard.

V1 uses `$15` as cooked-mode line kill even though the IIe keyboard also uses
that byte for right-arrow in raw input. Likewise, cooked mode deliberately
normalizes the IIe's two erase keys: left-arrow arrives as backspace (`$08`)
and the key labelled DEL arrives as ASCII DEL (`$7F`). Raw/noecho mode must
preserve those original bytes so the future userland line editor can bind
left-arrow to movement, `$7F` to backward-delete, and `^D` to forward-delete.

**Raw mode and the arrows (2026-09-10).** `TTY_KEYIN` turns all four arrows
into `ESC [ A..D` before the cook sees them (sec 4b), so a raw reader never
receives a bare `$08`/`$15`/`$0A`/`$0B` from the arrow keys. The raw cook
(`tty7.s` `TTY_COOK_RAW`) commits an arrow's three bytes as ONE line: `KEYIN`
pushes them into the ring three-or-none, so when the cook dequeues an `ESC`
the `[` and final are already there if it was an arrow, and a hand-typed `ESC`
has nothing behind it. A raw reader that asks for 3 bytes therefore gets 1
back for a bare `ESC` and 3 for an arrow, with no timeout and no read-ahead; a
reader asking for 1 byte still sees the same bytes one at a time. This closes
`docs/VI-DESIGN.md` sec 8 item 1. vi reads 3 (`VI_RAWKEY`) and treats
left-arrow as `<erase>` inside insert mode -- on this keyboard it IS the
backspace key, one wire with `^H` -- while up/down/right end the insert and
move.

The state layout should leave room for raw/noecho later. BASIC and future
full-screen tools will eventually need raw mode, but cooked mode is the
right default for the shell and simple utilities.

**Priority amendment, 2026-08-16.** Raw/noecho was previously justified by
Merlin's full-screen editor. The `docs/SELFHOST.md` ruling drops that: maux
puts an `as`-style CLI on Merlin's assembler rather than porting its editor,
and `as` is line-oriented and runs in cooked mode. Raw mode is therefore
**no longer on the critical path** -- it is required by the userland line
editor and any future visual editor, and by nothing that blocks self-hosting.
Build it when a program actually needs it, not speculatively.

**^L redraws the prompt too, 2026-08-19.** The line discipline keeps an
80-byte output-line shadow (`VC_OUTSHDW`/`VC_OSHDW_LEN` in
`src/kernel/tty.s`) recording printable bytes ($A0-$FE) the PROCESS WRITE
path has emitted since the line began. The rule (KFIX9, 2026-10-18): the
shadow is valid only while the glass is an APPEND of it, so CR, any line
break (LF, IND, NEL, RI), any cursor-motion, erase or edit CSI, a cursor
restore and a reset all end it; SGR and mode finals and an autowrap do
not (`learning:01M56PNAW2BET2G4GAK9PQKWG3`). Before KFIX9 only a CR
reset it (in `TT9_CR`), so ESC E left a dead line in it. Leaving the alternate screen resets it too, in `VCA_EXIT`,
since what a pager painted there is not on the restored row -- before
2026-10-02 `man` left its own `--More--(END)` in the shadow and every
later `^L` redrew it beside the prompt). `^L` replays that shadow through
`TTY_PUT_BYTE` before re-echoing the uncommitted edit buffer, so both the
prompt sh printed and the partial command reappear after the clear. Limits:
escape/control bytes, and anything written while an escape sequence is
mid-parse, are never recorded -- so a prompt with its own escapes (e.g.
color) will not replay correctly -- and the shadow caps at 80 bytes, past
which recording stops until the next CR and replay is truncated rather than
corrupted. See `TTY_SHDW_TAP` in `src/kernel/tty.s` for the exact rule and
why (a partial replayed escape could corrupt the very sequence a live
write() is mid-way through, since `VC_ESC_STATE` is shared).

**^C races the spawn window, 2026-08-31 -- accepted gap, trigger named.**
The kill sweep (`PRC_INTR_SWP`) runs at tick time and kills what exists
*at that moment*. A ^C typed while the shell is
still loading the child -- a disk load, so most of a second of window --
is consumed with nothing to kill, and the child then starts unmolested
(it inherits only the discarded-line side effects: the type-ahead is
gone and an empty line is pending). Real Unix closes this by putting
the child in the foreground process group at fork time, before exec;
maux's shell declares the job only after the spawn (`SYS_TCSETFG`,
below), so the sweep can only kill what has been declared.
Found while diagnosing check-play's parked "^C broken,
no diagnosis": the gate's cat-is-running predicate fired on a mid-scroll
screen tear and typed ^C inside exactly this window. The gate now waits
for the child's own output on a settled screen, so it no longer enters
the window (check_jobctl_a waits for the declaration itself). **Fix this
when** the first human ^C's a slow-loading
command and it survives -- the shape of the fix is a "pending kill"
that the spawn path checks once the child's PCB exists, the same
park-then-perform idiom as `VC_SW_PEND`.

**^C is aimed at a per-console FOREGROUND JOB, 2026-09-08
(`docs/JOB-CONTROL.md` Increment A) -- the depth heuristic is gone.**
Until now the sweep killed every live process at spawn depth >= 3 on
the whole machine: the foreground pipeline, but also every `&` job on
the console and every other console's foreground job (a ^C on tty1
killed tty2's `cat`). Now `TTY_INTR` records the typing console in
`K_INTR_PEND` (`VC_ACTIVE+1`, 0 = none), the interactive shell declares
its foreground pipeline's pids with `SYS_TCSETFG` (`VC_FGJOB[console]`
in the annex; `{0}` at the prompt, or -- when sh's own line editor
owns the prompt -- the shell declares ITSELF, a SELF set the sweep
matches exactly, never its subtree: TAB-A2, 2026-10-18), and the sweep
kills that console's declared pids and their descendants -- a non-interactive `sh
SCRIPT` declares nothing (no job control in a script, as POSIX), so it
is killed as a member and its children as the job's subtree. Root tier
is still protected, per-victim INT disposition is unchanged, and an
empty set kills nothing -- the empty-line reprompt above still fires
(a SELF set at the idle prompt reaches the shell as a pending INT/TSTP,
which its editor catches). Gate: `check-jobctl-a`.

### 4a. Type-ahead across the raw switch, and ^C's empty line (2026-10-07)

Keys typed while a committed line is pending wait in the raw ring;
the moment the reader takes the line they are cooked into the EDIT
buffer. A program that then clears ICANON (`more`, `vi`) used to
leave them there: it read only the ring, and the stale bytes
resurfaced in the next cooked line. `SYS_TTYMODE` (kdevblk.s
`PRC_TTYMD_SEG`, cold segment) now carries the edit buffer INTO THE
FRONT of the ring on ICANON 1->0 of the console on the glass, in
typing order, capped at the ring's free room (63 slots -- hd==tl is
empty); the excess is dropped (the ring's existing drop rule) and the
edit buffer, its cursor and the history walk are cleared. 0->1 is
unchanged. A background console's slot is NOT carried (trigger: a
program going raw on a console that is not on the glass while it
holds half-typed cooked input). Gate: `make check-typeahead`.

^C delivers an empty completed line so a shell blocked in read wakes
and reprompts. A shell in WAIT on a killed child is not a reader, so
the line is retracted when SCH_WAKEUP woke nobody (tty3.s TTY_INTR_TL)
and again when the ^C sweep killed a job (procspawn2.s -- a killed
reader like `cat` was woken by the line but never consumed it).
Without this the prompt printed twice (`$ $`). Gate: `make check-intr`.

## 4b. Readline-lite in the cooked editor (2026-08-31, operator-scoped)

Operator: cursor editing and command history are "the usability gap
that makes maux feel ancient", and the machine can afford to close
it. Scope, fixed by the operator: **C-a C-e C-f C-b C-p C-n, the
meta word-motions, and C-k. No search (C-r et al.) yet** -- that
waits until this lands and the cost is known.

**Since 2026-10-18 (TAB-A2) `sh` has a userland editor of its own with
these same bindings (src/bin/shedit.s, docs/TAB-A2-NOTES.md): at the
interactive console prompt `sh` puts the console in raw mode for the
length of one line and edits it itself. This kernel editor is untouched
and still reads every other cooked reader (`cat`, `ed`, `read`, `sh -E`);
retiring it is A4 (docs/TAB-COMPLETION.md), not done.**

**Since TAB-A3 that editor also completes (TAB completes, TAB TAB lists;
src/bin/shtabc.s, shtabc2.s, docs/TAB-A3-NOTES.md, sh(1) COMPLETION).**
The kernel editor does NOT: a TAB is still dropped by every cooked
reader (docs/TAB-COMPLETION.md sec 7 item 2), and `sh -E` keeps that.

**It extends the KERNEL cooked editor, not a userland readline.**
Section 5's ruling stands -- the real editor arrives with raw mode --
but raw mode is off the critical path and the ^L handler already set
the precedent: the line discipline is the only layer that can
respond while the user is still typing. Everything here moves to the
userland editor when raw mode lands. The cooked dispatch's own
comment has reserved the arrows "until history and readline give
them meanings" since the CSI swallow landed; this is that.

**Bindings.** C-a/C-e line ends; C-f/C-b char motion; M-f / M-b
word motion; C-p/C-n history (up/down arrows alias them -- the CSI
A/B the cooked swallow has been reserving); kill-to-end is **M-k**,
because on this keyboard ^K cannot exist as its own key: the up
arrow produces the identical code (Sather -- same fold as
^U/right-arrow) and TTY_KEYIN turns $8B into CSI A, so a typed ^K
IS history-prev. The raw $0B binding is kept for future input
paths with a real ^K (a serial tty).

**Meta is OPEN APPLE, encoded as ESC at capture** (operator ruling
2026-08-31, assuming verilogapple#16 lands soon). TTY_KEYIN samples
BUTN0/$C061 the moment a key comes off the latch; OA-down pushes
ESC ahead of the key into the raw ring -- OA+f arrives at the cook
as the two bytes ESC f, which is exactly how terminals have always
encoded Meta. The cook's lone-ESC path dispatches it, so a typed
ESC f is the SAME binding. #16 landed its `buttons` tool the same
day, so check-play gates BOTH forms -- the typed prefix and a held
PB0 (its leg holds Open Apple across the capture and proves OA+k
kills like M-k). Arrows and ^C are exempt from the prefix (arrows are
already 3-byte CSI; ^C's intercept stays unconditional). A program
polling $C061 with no keypress in flight sees the button as ever. Unchanged: CR, ^D, ^U, ^L
(re-anchored to the cursor), and BS/DEL/left-arrow stay ERASE --
on this keyboard left-arrow IS $08 IS C-h, one wire, so it keeps
its erase meaning (which is also readline's C-h) and motion lives
on C-b. Right-arrow (the ^U wire, sec 4) is MOTION now -- CSI C
dispatches forward-char -- so a BARE ^U is the right-arrow; a real
^U is typed **OPTION+U** (Solid Apple folds the key to its control
code and takes the non-CSI path, TTY_KEYIN), which reaches the
cook as $15 and runs line-kill, and reaches vi as $95 = ^U
(half-page up, VI_PAGE_U). C-a + M-k still kills too; the raw $15
binding also serves a future serial tty with a real ^U.

**Display discipline: relative motion only, so scroll cannot lie.**
The editor is kernel code sharing VC_ROW/VC_COL, so motion is
direct row/col math with wrap handling (CSI D deliberately CLAMPS
at column 0 -- the VT battery pins that -- so the editor does not
ride the escape parser for motion). Every buffer edit renders
forward through TTY_PUT_BYTE (which owns wrap and scroll) and then
walks the cursor BACK a known count with the same wrap math. A
scroll can only fire on the final freshly-touched cell of a
forward pass, and a relative back-walk from wherever that pass
ended is correct whether or not it scrolled -- no anchors, no
scroll counters, nothing for a scroll to invalidate.

**History does NOT persist, and the trigger for changing that is
named** (operator ruling, 2026-08-31): a synchronous disk write per
committed command line would be paid at every prompt, so a
~/.history file waits until maux has a write-behind/buffered block
path where history appends can be AMORTISED into I/O the machine is
already doing -- not before. Until then the ring is annex RAM and
dies with the power, which is the cheaper loss.

**History: per-console, in the annex, walked by BankCopy.** Eight
128-byte entries plus one stash slot per console (the stash holds
the in-progress line when C-p starts a walk, so a stray C-p costs
nothing), $9300..$A4FF in aux bank 0 -- the next-free annex byte
after the console stores. CR commits every non-empty line -- NO
dedup in v1 (the compare needs the newest entry back in main
memory against a 96B staging buffer and a 126B line), so a
consecutive duplicate costs one extra ^P; the walk cursor
(VC_HIST_CUR, $FF = not walking) resets on commit. The VC struct grows 291 -> 295
(VC_EDIT_POS + three history cells) inside the save/load block;
VC_SLOT_RESV grows to match, still clear of $7500. BankCopy from
cook context is safe for the same reason the ^C sweep's annex
access is: ticks only fire with no syscall mid-flight, so the
K_BC_* scratch is dead (tty5.s's tick-path exposure note names
the requirement that keeps this true).

## 5. Userland line editing

Do not grow GNU Readline into the kernel tty. The kernel line discipline should
stay close to early Unix canonical mode: erase, line kill, EOF, interrupt, and
raw/noecho switching. Rich command-line editing belongs in userland once raw
mode exists.

The future split should be:

```
kernel tty cooked mode:
  simple programs, scripts, fallback shell input

kernel tty raw/noecho mode:
  userland line editor
  full-screen editor
  hosted BASIC special input paths
```

The userland line editor can live in `liba` and should start with the pieces
that make sense on a small machine:

- Emacs-style movement/editing as the preferred interactive binding set;
- IIe key mapping: `$08` left, `$15` right, `$7F` backward-delete, `^D`
  forward-delete; `^D` remains EOF in cooked mode;
- command history, bounded by explicit memory policy -- and the
  policy is RULED (operator, 2026-08-30): "history doesn't need
  to be deep to be useful. a few commands deep, in ram above the
  BRK where it won't get forked, is plenty." A small ring of
  line slots parked between the shell's own brk and the $BF00
  overlay page: outside [image, brk) so fork never copies it --
  a subshell should NOT inherit prompt history, and the copy
  loop never pays for it -- private to the owning process, gone
  at exit, and costing a region nothing else claims;
- redraw that tolerates 40 columns but improves on UltraTerm;
- completion only after the shell has a settled command/path model;
- no dependency between the script parser and interactive editing features.

This keeps `sh < script` deterministic and tiny while allowing the interactive
shell to become pleasant on a real terminal.

## 6. Terminal subset

The target is VT102 (docs/CONSOLE-VT102.md; ruled 2026-09-11), not a private
`maux` entry -- a stock `TERM=vt102` terminfo must drive the console. Slice 1
(2026-09-11) landed the escape-parser and line-discipline half of that gap
list; slice 2 (DCH/IRM) is still open.

Implemented subset (VT102 slice 1):

```
printable chars
CR (column 0 only, or a full newline under TMD_OPOST -- sec 4/4c below)
LF (column 0 + advance -- maux's own newline; see sec 4c)
BS, TAB
automatic wrap (immediate, no xenl -- measured, docs/CONSOLE-VT102.md sec 2)
scroll at the bottom MARGIN (DECSTBM, not always the physical bottom)

ESC [ H              cursor home
ESC [ r ; c H        cursor position
ESC [ r ; c f        cursor position alias
ESC [ n A/B/C/D      cursor up/down/right/left, count honoured, clamped
                     at the MARGIN when inside the scroll region, else
                     at the physical edge (CUU/CUD; CUF/CUB always clamp
                     at the physical column edge -- DECSTBM is vertical
                     only)
ESC [ n J            ED: 0 cursor..end of screen, 1 start..cursor
                     inclusive, 2 whole screen -- cursor NEVER moves
ESC [ n K            EL: 0 cursor..end of line, 1 start..cursor
                     inclusive, 2 whole line -- cursor never moves
ESC [ m              SGR: 0 reset, 7/27 inverse, 1/22 bold -- ONE emphasis
                     bit per cell, and 1 sets it only where the bit
                     means BRIGHT; ignore unsupported attrs
ESC [ ? 3001 h/l     emphasis MEANING on the UltraTerm: h = highlight
                     (bright), l = inverse (default; ESC c restores it).
                     No effect on the //e backends (always inverse).
ESC [ t ; b r        DECSTBM: set the scroll region (0 params = whole
                     screen); homes the cursor on success; bounds
                     scroll-at-bottom, IND/RI/NEL, SU/SD, IL/DL
ESC [ n S / n T       SU/SD: scroll the REGION up/down n rows
ESC [ n L / n M       IL/DL: region = [cursor,MBOT]; a no-op if the
                     cursor is outside the margins (VT102 semantics)
ESC [ ? 1 h / l       DECCKM: application cursor keys -- while set,
                     TTY_KEYIN frames a physical arrow as ESC O A..D
                     instead of ESC [ A..D
ESC [ ? 7 h / l, CSI 4 h/l (IRM), CSI 3 g, CSI n i
                     accepted, silently ignored (autowrap is always on
                     in V1; IRM/DCH are slice 2)
ESC D                 IND: down one line, same column, scrolls at MBOT
ESC M                 RI: up one line, same column, scrolls at MTOP
ESC E                 NEL: IND + column 0 (identical to maux's LF)
ESC 7 / ESC 8         save/restore cursor
ESC c                 reset terminal (RIS): also resets DECSTBM margins
                     and DECCKM
ESC ( x / ESC ) x     enacs family: the designator byte is swallowed,
                     nothing is rendered (no line-drawing set in V1)
ESC = / ESC >         DECKPAM/DECKPNM: consumed, no-op
ESC H                 HTS: consumed, no-op (tabs stay every 8)
```

**Emphasis (2026-09-11; SGR 1 narrowed 2026-11-01).** The console
carries one attribute bit per cell. SGR 7 sets it on every console.
SGR 1 sets it only where that bit renders as BRIGHTNESS -- an
UltraTerm already switched to highlight -- and is otherwise dropped
(`TTY_SGR_CLASS`, src/kernel/tty2.s), the way a terminfo entry without
a `bold` capability drops it. A //e cell has inverse and nothing else,
and bold-as-inverse mid-sentence is worse than plain: the manual paged
on a //e put an inverse block around every emphasised word, a ragged
column of them down a SYNOPSIS. So the man pages are staged with the
two sequences split by column -- a run that starts the line (a section
heading) as SGR 7, a run inside a sentence as SGR 1 (`man_to_maux`,
scripts/build_play_image.py) -- and the //e shows headings and clean
paragraphs while the UltraTerm, where `more` arms highlight on the
first run of either kind, shows both bright exactly as before. What the bit MEANS is per
console: on the //e text page it is always inverse; on the UltraTerm
the card's Character Attribute Register (`$C0B3`, Videx manual ch. 8:
two attribute sets, a cell's bit 7 picks one) is programmed
explicitly -- `UT_ATTR_INV` ($20, the factory look) by default, or
`UT_ATTR_HL` ($10, bit-7 cells bright) after `ESC [ ? 3001 h`. Inverse
is the default because it is what everything uses; a pager that meets
bold text (the manual pages, `more`'s TRACKSGR) switches to highlight
for its run and restores inverse at exit, so bold degrades to inverse
everywhere else. Two sets per screen means bold and inverse cannot be
distinguished at once on the card; that is the hardware. The driver
used to write `$80` ("attributes from the DIP switches"), which on iron
made inverse depend on the owner's S1-S4 and left highlight
unreachable; verilogapple modelled only the factory case until the
same day (its `ultraterm.h` now applies the register like MAME does).

The parser currently consumes these sequences in the tty output path and
updates the 40-column surface directly. It does not yet maintain a separate
logical screen buffer or inactive virtual consoles.

### 6a. The CR/LF split and TMD_OPOST (VT102 slice 1)

maux's file convention keeps `$8D` (high-bit CR) as the line terminator, but
the VT102 TERMINAL layer treats CR and LF differently: CR returns the
carriage only, LF indexes. GNO/ME hit the identical collision on the IIgs
and put the fix in the LINE DISCIPLINE, not the terminal
(`learning:01M287MW1Y9Q719BAYFTN4C5M8`) -- maux does the same:

- **`SYS_TTYMODE` gained a third bit, `TMD_OPOST`** (inc/syscall-
  proc.equ), on by default (cooked = `TMD_ICANON|TMD_ECHO|TMD_OPOST` = 7).
- With `TMD_OPOST` set, a CR reaching the terminal layer (tty9.s `TT9_CR`)
  is CR LF: column 0 AND a margin-bounded index (maux's own newline).
- With it clear (raw mode -- `tip`'s console stays mode 0; vi's raw mode is
  `TMD_OPOST` alone, ICANON/ECHO clear), CR is strict VT102: column 0 only.
- **LF is IND in every mode** (down one row, SAME column, region scroll at
  the bottom margin), exactly `ESC D`. There is no deviation from the
  VT102 at the terminal layer; `$8D` is maux's newline and the line
  discipline supplies the LF. Plain `\n`-terminated text therefore
  staircases on a maux console, as it does on a real VT102 with no ONLCR.

A program writing its own literal CR (not routed through a $8D-to-newline
convention) to a console that might be in raw mode should use LF instead --
found live building the VT102 slice-1 gate: `tip`'s own escape-list message
(`~?`) used embedded CR separators and rendered as one overwritten line
under its raw+noecho console; fixed to LF (`src/bin/tip.s` ESCLIST).

**That gate is now met (2026-08-16).** `TTY_VT_SUITE` in `src/test/playtest.s`
runs a 16-case escape-sequence battery at boot, asserted cell by cell in
`scripts/check_play.py`: absolute positioning (`H` and the `f` alias),
all four relative moves, left-clamping at column 0, erase-to-end-of-line
against text on both sides of the cursor, two-parameter SGR, tab stops, and
an unknown CSI final byte that must terminate the sequence rather than wedge
the parser. Each case asserts a specific cell, so a failure names the escape
that broke rather than reporting that the screen looks wrong.

The logical screen buffer and inactive virtual consoles are therefore the
next layer, and the battery is the thing that should catch regressions when
the parser stops writing the surface directly and starts writing a buffer.

Attributes should start tiny:

```
normal
inverse
```

Bold, underline, color, scrolling regions, and xterm extensions are later work.

### Character set policy (2026-08-15)

`TTY_INIT` writes `ALTCHARSETON` ($C00F). The console owns the character set
rather than inheriting whatever ProDOS left, because **inverse lowercase does
not exist in the primary character set**. The primary set's $40-$7F block is
flashing, and its inverse block ($00-$3F) only mirrors ASCII $20-$5F -- so
`ESC [ 7 m` over lowercase text is unrenderable there. The alternate set trades
that flashing block, which a Unix tty has no use for, for inverse lowercase at
$60-$7F and MouseText at $40-$5F.

Consequently the ASCII-to-inverse fold is range-dependent, and `TTY_INVERSE_A`
in `src/kernel/process.s` is the single place that implements it:

```
ASCII $60-$7F (lowercase)      -> $60-$7F    (and #$7F alone)
ASCII $20-$5F (upper/symbols)  -> $00-$3F    (fold again with and #$3F)
```

A bare `and #$7F` for everything -- the shape this code shipped with first --
puts uppercase in $40-$5F, which is MouseText under ALTCHRSET and the flashing
block without it. It is never inverse. Verified on verilogapple (fast backend,
2026-08-15) by poking display codes to $0400 and rendering: $02 renders inverse
'B', $61 inverse 'a', $21 inverse '!', $20 inverse space, while $42 renders as
a MouseText glyph. `[likely]` grade on the primary set's *flashing* behavior:
that backend renders $40-$7F statically and does not model flash phase, so the
"without ALTCHRSET it flashes" half wants a MAME or real-hardware cross-check.
The load-bearing half -- that $42 is not inverse -- holds under every reading.

MouseText becoming reachable is a side benefit worth noting for later
status-line and box-drawing work, not something V1 uses.

Library notes: `learning:01M02NT5M7PXSZTHGVJKRENGM4` -- the display-code fold
table and the ALTCHRSET/inverse-lowercase constraint this section rules on,
deposited from this verification (the commons had no coverage of the text-page
display-code map before it).

### Screen geometry: 24 rows, no reserved line (row-0 reclaim, 2026-09-03)

The 40-column backend's physical screen is 24 rows, and **the terminal is all
24 of them -- rows 0-23.** There is no reserved status/banner line any more;
row 0 is ordinary terminal content, exactly like every other row:

- `TTY_CLR_BODY`, `TTY_SCROLL`, and `TTY_TERM_RESET` all start at row 0 now,
  so a clear, a scroll, or `ESC c` covers the whole screen, row 0 included;
- the CSI row parameter is decremented like the column (both are 1-based on
  the wire), so `ESC [ 1 ; 1 H` is the terminal's top-left, physical row 0 --
  and `ESC [ 24 ; 1 H` addresses the last row, 23;
- `src/test/playtestb.s`, `argvtestb.s`, and `astestb.s` no longer write a
  pre-boot banner to $0400 -- there is no reserved line for one to occupy, and
  it would just be overwritten as ordinary row-0 content on the first
  `TTY_INIT` clear.

**Row 0 used to be exempted, and getting that right was its own small saga --
worth keeping as history even though the reservation itself is gone.**
`TTY_SCROLL` began its copy at row 1 and wrote to row 1 minus 1 (2026-08-17)
-- so the first thing every scroll did was copy the terminal's top line over
the status line. playtest's "MAUX PLAY" banner survived boot and then
vanished the moment output reached the bottom of the screen. Fixed then by
starting the copy at row 2, preserving row 0; `check-play` grew a marker-based
scroll assertion rather than a "bottom row non-empty" check, because the
latter goes true *before* the first scroll and had passed against the live
bug. That whole reservation -- the exemption, the banner, and the reflow
machinery (`TTY_ST_RFLW`/`VC_RFLW_CK`) that kept row 0 legible across a
40<->80 width change -- is gone as of the 2026-09-03 reclaim: the per-console
screen store already had room for 24 rows (`VC_STR_ROWS=24`, `inc/
mm.annex.equ`), so extending the ordinary blit/scroll/clear to cover row
0 needed new OFFSETS only, no new storage. `check-play` now asserts the
OPPOSITE of the old claim: that row 0 scrolls away like any other row, and
that the shell's very first prompt lands there.

`SYS_TTYGEO` reports 24 rows (`TTY_ROWS`) -- which was already its value
before the reclaim (the physical glass height was always 24; this file used
to say a future backend "must report 23, not 24" once a VC indicator owned
row 0, but the live code never actually did that, and now never needs to).
What changed is that all 24 are addressable terminal content, not that the
count changed.

When virtual consoles land, the VC indicator can no longer live in a reserved
row 0 -- there isn't one any more. It needs another home, e.g. a reverse-video
top line living INSIDE the scroll region (costing one line of the 24 rather
than a whole reserved row), decided when virtual consoles proper are scoped.

**The UltraTerm backend's own row-0 status line went the same way, the
same evening.** The first cut of this reclaim left `src/kernel/ultraterm.s`
(`UT_ROW0`, `UT_STAMP_ROW0`, `UT_CLR_BODY` from row 1, a `TTY_HOME_ROW` that
homed the card to row 1) untouched. Measuring the console
(`CONSOLE-OPT.md` sec 6) showed the re-stamp was ~9k of the card's 20k-cycle
scroll, and `UT_CLR_ROW` recomputed its ring address per cell for most of
the rest. Both are gone: the card clears all 24 rows, scrolls without
re-stamping, walks the 256-byte window once per row (bumping the page
nibble exactly when the offset wraps), and `TTY_HOME_ROW` is `stz VC_ROW`
on every backend -- kept as the single call site for "home" so a future
indicator row has somewhere to live. `check-ultraterm` now asserts the
opposite of what it used to: a word written across row 0 must scroll OFF
and never come back.

## 7. Virtual consoles

The V1 implementation can expose only `vc0`, but the data model should be:

```
tty0 -> vc0
tty1 -> vc1
tty2 -> vc2
tty3 -> vc3
```

Each virtual console owns:

```
input queue and line-discipline state
terminal parser state
cursor
current attrs
logical screen buffer
optional graphics surface state
read wait channel
```

The active display backend is global. Writes to inactive VCs update their
logical buffers without touching hardware. Switching consoles later is just:

```
active_vc = n
backend.redraw(vc[n])
```

This is valuable even on an Apple II: shell on one VC, BASIC on another, editor
or build output on a third.

## 8. Display backends

Backends paint a logical surface. They do not parse escape sequences and do not
own tty policy.

Backend shape:

```
detect
init
cols
rows
put_cell(row, col, ch, attr)
clear_row(row)
scroll_up(top, bottom)
redraw(vc)
show_cursor(row, col)
hide_cursor
```

Backend order:

1. Apple 40-column text page 1 fallback.
2. UltraTerm text backend.
3. Apple 80-column backend later.

The Apple 40-column backend is for bringup and no-card fallback. UltraTerm is
the development-console target. Apple 80-column is useful but more entangled
with 80STORE and aux bank-0 video routing, so it should not distort the core
tty design.

## 9. BASIC as a process

Apple BASIC should be treated as a first-class future personality runtime:

```
BASIC process
  -> BASIC/Firmware I/O vectors or ported shims
    -> maux read(0) / write(1)
      -> tty
        -> terminal / VC / backend
```

The useful milestone is:

```
$ BASIC
] 10 PRINT "HELLO"
] RUN
HELLO
] SAVE /BASIC/HELLO.BAS
] NEW
] LOAD /BASIC/HELLO.BAS
] LIST
] BYE
$
```

This turns maux into a development environment for the Apple II itself, not just
a Unix-flavored demo.

There are two compatibility levels:

- hosted BASIC: `PRINT`, `INPUT`, `LOAD`, `SAVE`, `RUN`, and graphics commands
  are adapted to maux tty/files/graphics APIs;
- display-owner BASIC: an explicit compatibility mode may grant direct physical
  display ownership for old code that insists on Apple video memory semantics.

The normal hosted path is the one to build first. Direct display ownership is an
exception because it breaks virtual-console isolation.

## 10. Graphics future

Graphics should not be forced through `write(1)`. The tty remains a character
stream; graphics are a capability of a virtual-console display surface.

Future VC surface:

```
text plane
graphics plane
active display mode
palette/color state
backend-specific render hooks
```

Future graphics API targets:

```
lores
hires page 1
hires page 2
double-hires page 1
double-hires page 2
mixed text/graphics
```

BASIC graphics commands then map naturally:

```
GR       -> set lores surface
HGR      -> set hires page 1 surface
HGR2     -> set hires page 2 surface
TEXT     -> restore text surface
HCOLOR=  -> graphics state
HPLOT    -> graphics drawing operation
```

Private terminal escapes for mode switching can exist later, but they should be
small. A sixel/ReGIS-style graphics language is too heavy for the kernel path
until there is a real program demanding it.

## 11. Video memory policy

The display apertures are not general kernel scratch.

Hard video reserve in main memory:

```
$0400-$07FF   text/lores page 1
$2000-$3FFF   hires page 1
$4000-$5FFF   hires page 2
```

Hard video reserve in aux bank 0:

```
$0400-$07FF   80-column text aux half / double-lores companion
$2000-$3FFF   double-hires page 1 companion
$4000-$5FFF   double-hires page 2 companion
```

Soft reserve:

```
$0800-$0BFF   text/lores page 2
```

Text page 2 is deliberately soft. It has no native console role and is far less
strategic than hires page 2. The hard rule is that new kernel allocations
should avoid text page 1 and both hires pages. Existing text-only V1 reclaim of
hires apertures is a debt to retire before graphics, BASIC display ownership,
or virtual-console graphics become real.

Aux banks other than 0 have no physical display holes: the video scanner reads
main and aux bank 0, not process banks. A process writing `$2000` in its own
bank is just writing process RAM. Hosted Apple software that expects those
writes to affect the display must go through the graphics API or an explicit
display-owner compatibility mode.


## 9. Interactive session, verified (2026-08-17)

`make play-image` boots to a live shell on the kernel tty (`playtest.s` spawns
`/BASIC/SH` with no fdactions, so `PRC_DFLT_FDS` gives it fd 0/1/2 =
`FD_TTY0`). Driven from the emulator keyboard, end to end:

    $ ED
    a
    alpha the first line
    beta the second line
    alpha again here
    .
    w /BASIC/POEM
    q
    $ GREP ^alpha /BASIC/POEM
    alpha the first line
    alpha again here
    $ PWD
    /BASIC/

That is a file created at the prompt with `ed`, matched with `grep`, and the
per-process cwd answering live. The play image now ships the full utility set
(grep, wc, mkdir, mv, pwd, ps) rather than the original six.

**Reading the screen from a harness:** `screen_text` returns `main`, `aux` and
`merged`. `merged` is EMPTY unless the machine is in 80-column mode, so a
40-column image must read `main`. Reading `merged` unconditionally reports a
blank screen and looks exactly like a boot failure.

## 10a. UltraTerm implementation recipe (everything pinned, 2026-08-17)

The unknowns are gone. What remains is the tty rebinding, which is real work
but no longer research. Sources: verilogapple `sim/ultraterm/ultraterm.h` and
`ultraterm_slot.h`, both unusually well commented, plus direct probing.

**Address decode (slot 3).**

    $C0B0   CRTC address register (select Rn); read = status
    $C0B1   CRTC data register
    $C0B2   page/control: bit7 MEMSEL, bit6 VIDSEL (1 = card owns the
            monitor), bit4 VTEMU, bits3-0 = VRAM page (256-byte granular)
    $C0B3   mode/control latch
    $C300   slot ROM, signature $C30C = $87
    $CC00-$CDFF   512-byte VRAM window into 4 KB of card RAM;
            byte = vram[page*256 + (addr & $FF)]. The $CC00 and $CD00
            halves are MIRRORS -- both index the page-selected block by
            their low byte.

**Gating.** `$C0Bx` is always decoded (INTCXROM does not gate `$C0xx`).
`$C300-$C3FF` needs INTCXROM=0 and SLOTC3ROM=1. `$C800-$CFFF` needs INTCXROM=0
AND this slot owning the `$C800` last-claimant latch, which is claimed by
touching our `$C3xx` and released by `$CFFF`. That latch is the same mechanism
that once hung ProDOS boot (`learning:01KWKWN3HHY2DY1VDA33T9X52J`).

**HIGH QUALITY MODE, which is the bit that was asked for.** `$C0B3` bit 2 is
the character-generator ROM's A11, **inverted**: bit2 SET selects set0, the
standard font; bit2 CLEAR selects set1, the dense "high-quality" font. The
card firmware drives it per mode from a table at `$C9B5` -- 80x24 standard is
`$84` (set0), the HQ 80x24/80x32/128x32 modes are `$80` (set1). So HQ 80x24
is `$C0B3 = $80`. Note VRAM bit 7 is the INVERSE-VIDEO attribute, not a font
address line.

**The CRTC subset that actually matters.** The emulated renderer is
behavioral: it draws `cols() x char_w` by `rows() x char_h()` straight off the
register file and ignores the timing registers entirely. So a driver only has
to program R1 (columns), R6 (rows), R9 (cell height - 1), R12/R13 (display
start), R14/R15 (cursor address) and R10/R11 (cursor shape/enable). R0, R2-R5,
R7 do not affect what is rendered. On real hardware they do, so UT-CELL
(2026-10-21) makes `UT_INIT` copy the firmware's own format-4 entry
(ROM `$F55`, read live; `UT_CRTC_TBL` is only a guard fallback) rather than R1/R6/R9 alone.

**Verification is possible, which was the open question.** ~~`peek`/`poke` DO go
through the slot decode: writing R1=80 via `$C0B0`/`$C0B1` and reading it back
returned `$50`, and `poke $CC00` then `peek $CC00` round-tripped. So a harness
can read card VRAM directly and assert on screen content -- there is no
`screen_text` support for the card, and none is needed.~~

**REFUTED 2026-08-17, and this one was load-bearing.** Both round-trips went
through main DRAM; the card was never in the path. `tool_peek`/`tool_poke` call
`main_peek`/`main_poke`, which index the raw DRAM array at the logical address
without consulting the slot decode or the MMU. Poking `$11` to `$CC00`, then
having guest code `STA $CC00` a `$5A`, leaves `peek $CC00` still reading `$11`.
Same for the `$C0B0`/`$C0B1` "CRTC round-trip". A poke followed by a peek at any
address round-trips -- that is what DRAM does, and it says nothing about a card.

Two separate facts hide behind that one mistake, and only one of them is bad:

* **From GUEST code the CRTC really is readable.** `LDA $C30C` returns `$87`,
  and after writing R1=80, `LDA $C0B1` returns `$50`. Registers are fine.
* **VRAM is WRITE-ONLY over the bus.** `$CC00-$CDFF` *reads* serve firmware ROM
  (`ultraterm_slot.h`), deliberately: the card's COUT executes from `$CC6E`, so
  a read-VRAM latch would derail its own instruction fetches. Guest probe:
  `STA $CC00` <- `$5A`, then `LDA $CC00` reads `$38` -- the firmware byte at
  offset `$C00`. Neither guest code nor a debug peek can read a character back.

This is an emulator fidelity gap, not a hardware property: the model's own
header says the real card multiplexes that window via a control bit "not yet
pinned". Do not design around the gap by guessing the bit; design so the driver
never needs a readback, which is also authentic 6845 practice.

**Resolved by tooling.** `ultraterm_state` was added to verilogapple
(`feat(mcp)`, branch `milestone/ultraterm-state`): CRTC R0-R17, page/`reg_b2`/
`reg_b3`, vidsel, geometry, charset, and `text` -- the displayed page decoded to
ASCII rows, following R12/R13 display start. Optional `addr`/`count` returns a
raw VRAM slice keeping bit 7. **That tool is the only way to see the card's
screen**; `screen_text` covers the Apple page only and always will.

**Consequences for the driver, which are what make this worth the detour:**

1. `TTY_SCROLL`'s read-a-row-and-copy-it-up cannot work on this backend. Scroll
   by bumping the CRTC display start (R12/R13) instead -- no reads at all.
2. `TTY_CRSR_SHOW`/`HIDE`'s save-the-glyph-and-restore-it cannot work either.
   The CRTC has a hardware cursor (R14/R15 address, R10/R11 shape), so the whole
   save/restore dance is deleted rather than ported.

Both replacements are strictly better than what they replace. The gap pushed the
design somewhere it should have gone anyway.

**Path chosen: direct VRAM (2), because the readback gap kills path 1.** The
card firmware's COUT scrolls by reading VRAM back, which returns firmware ROM
here, so routing through it would render garbage the moment the screen filled.
It also costs the ANSI positioning layer and the 16-case `TTY_VT_SUITE` battery
that section 6 just finished earning. Direct VRAM keeps both.

**Scroll addressing: a 4096-byte ring, and the row stride does not divide it.**
Hardware scroll advances the display start by one row (80 bytes). VRAM is 4 KB
and 4096 is *not* a multiple of 80, so after enough scrolls a row straddles the
wrap. Rows then drift relative to VRAM while staying exactly where the scanner
looks for them, and `start` can advance by 80 forever with no rebase, no shadow
buffer, and no special case. The 24 visible rows are 1920 bytes, well under
4096, so the window never overlaps itself.

**The mod-4096 wrap is free, which was worth measuring rather than asserting.**
The obvious worry is that a driver must mask every address to `$0FFF` or the
screen shears after ~51 scrolls. It does not: `$C0B2` takes a **4-bit** page
nibble and the `$CC00` window is **256 bytes**, so the hardware already reduces
every address mod 4096. `ultraterm.s` keeps the `AND $0FFF` for readability, and
deleting it leaves `make check-ultraterm` fully green -- checked, because a
comment claiming "MUST mask or it shears" is the kind of thing that gets
believed for years. What *is* load-bearing is adding the display start into
every cell address: dropping that fails 26 of the gate's 37 checks.

**Row 0 is ordinary content on THIS backend too (since the evening of
2026-09-03).** The first cut of the row-0 reclaim (section 6) left the
UltraTerm's own reservation in place -- an 80-byte `UT_ROW0` copy in kernel
RAM re-stamped after each scroll -- and measurement showed that re-stamp
was ~9k of the card's 20k-cycle scroll. It is gone: the card scrolls with
one CRTC write plus one row clear, and the row clear walks the window once
per row instead of recomputing the ring address per cell.

**Two implementation paths, and the cheap one is probably right.**

1. *Route through the card firmware.* The card provides a full 80-column COUT
   driver: init via its `$C300` entry, then send characters. Scrolling,
   cursor and mode setup come free, and `TTY_PUT_BYTE` becomes a call. Loses
   direct cursor addressing, which costs the ANSI positioning in section 6 --
   fine for running `ls` and `grep`, not fine for a full-screen editor.
2. *Drive VRAM directly.* Program the CRTC, then write characters as
   `addr = row*80 + col`, `$C0B2 = $40 | (addr >> 8)`, store at
   `$CC00 + (addr & $FF)`. Full control, keeps the ANSI layer, and the page
   must be re-selected per character because an 80-column row straddles the
   256-byte window.

Library notes (deposited from this work, 2026-08-17 -- the commons had **zero**
UltraTerm coverage before it, and the search that established that swept the
card by name, "CRTC", "6845", "$C800 arbitration" and "character generator ROM"
separately, per the project's search-the-nouns rule):

* `learning:01M06YDGM1Q52V5TXX3GA8A2FZ` -- the whole slot-3 programming model:
  decode, gating, the inverted-A11 charset latch, the bit-7 inverse attribute,
  the six registers that matter, and the write-only-window consequences for
  scroll and cursor. Cite this before touching the backend again.
* `learning:01M06YC8SPHT3Z8PE0YHBV2HAA` -- the verification trap that produced
  section 10a's refuted paragraph, generalized: `peek`/`poke` bypass the bus, so
  a round-trip at a card register proves nothing. Includes the discriminating
  three-value experiment to use instead.

**Coupling to the existing tty.** Contained: 7 call sites plus
`TTY_ROW_DST_A`, which already carries a correct interleaved row table for the
Apple text page. The work is a width constant (40 -> 80), a second row-address
scheme, and replacing the `sta (P_PTR2),y` store idiom with a backend call,
since the window needs a page select per character.

## 10c. SHIPPED: the tty is rebound, and the shell runs at 80 columns

`src/kernel/ultraterm.s` is the backend; `TTY_INIT` selects it when a card
answers `$87` at `$C30C` and otherwise keeps the 40-column text page. Selection
happens once, at init, and every dispatch below tests `UT_PRESENT` -- nothing
re-probes hardware per character.

What became backend-dispatched, and why each one had to:

| primitive | 40-column | UltraTerm |
|---|---|---|
| `TTY_WR_CELL` | Apple display codes, `TTY_INVERSE_A` fold | plain ASCII, bit 7 = inverse |
| `TTY_BLANK_CELL` | store `$A0` | store `$20` |
| `TTY_SCROLL` | copy rows 1-23 up (was 2-23 before sec 6's 2026-09-03 reclaim) | bump CRTC R12/R13 |
| `TTY_CLR_BODY` | blank all 24 rows (was 1-23) | same, via `UT_CLR_ROW` |
| `TTY_CRSR_SHOW`/`HIDE` | save glyph, paint inverse | park the CRTC cursor |

The character encoding is the subtle one. The two backends are not the same
alphabet: the //e text page needs the range-dependent inverse fold of section 6,
while an UltraTerm cell is plain ASCII with bit 7 as the attribute. Applying the
//e fold to the card would corrupt the glyph. So `TTY_WR_CELL`'s contract
changed -- **callers now pass ASCII and set `TTY_ATTR`; the backend owns the
encoding.** Nothing above that line knows what a display code is, which is what
section 8 asked for in the first place.

Width is `TTY_COLS`, set by `TTY_INIT`. Wrap, backspace-across-a-wrap, `ESC [ K`
and both CSI column clamps read it instead of a literal 40.

`ESC [ K` also stopped walking a row pointer. An 80-column row is 80 bytes
inside a 256-byte window, so it can straddle a page boundary -- there is no
single pointer to walk. It now steps cells through the backend and restores
`TTY_COL`, because erase must not move the cursor.

**Where the card's equates live, and why it is not `memmap.equ`.** They are in
`src/kernel/ultraterm.s`. Putting 4 KB of card documentation into
`inc/memmap.equ` broke `check-dual` by **83 bytes**: real Merlin's source
buffer is 41215 bytes and holds the manifest and one PUT file *together*
(`learning:01M051EM2HQ3ZVJTR1W9P3G86J`), and `memmap.equ` was already within a
few hundred bytes of the ceiling. The failure surfaced as `56 MEMORY IN USE` --
which names neither the file nor the limit -- and the object code was byte-for-byte
the same size before and after, so nothing about the symptom pointed at a
*source* budget. Hardware constants belong to the module that drives that
hardware; `memmap.equ` is for what the whole kernel shares.

Consequence: **every image PUTs `ultraterm.s` BEFORE `tty.s`.** Real Merlin
requires an EQU to be defined before its first reference, and `TTY_INIT`
references `UT_COLS`.

**Both paths are gated, on the SAME image:** `check-play` boots `play.po` with
no card and runs the 40-column path including the 16-case VT battery;
`check-play80` boots the identical image with an UltraTerm in slot 3 and asserts
the shell renders on the card -- 80 columns, HQ font, VIDSEL, the CRTC cursor
parked at row 1 column 2 after the prompt, `LS` listing all 13 utilities through
a real child process, and a second prompt below the listing. One gate alone
would let the other path rot.

## 10. Videx UltraTerm: reconnaissance (superseded by 10c)

Section 8 names the UltraTerm as the preferred serious text backend. It is
still unimplemented -- the tty writes the //e text page directly -- but the
pieces were checked (2026-08-17):

* verilogapple ships it: `reset {ultraterm: true}` puts a Videx UltraTerm on
  **slot 3**, with `sim/roms/ultraterm/firmware_v3.bin` and `chargen_v3.bin`
  present. The reset result echoes `ultraterm: true` when it took.
* **It coexists with our SmartPort.** maux boots to the shell prompt normally
  with the card installed, and slot-3 firmware is live at `$C300`. That is
  worth having checked, because `$C800` expansion-ROM arbitration between a
  SmartPort and the 80-column ROM is exactly what once hung ProDOS boot on the
  RTL backend (`learning:01KWKWN3HHY2DY1VDA33T9X52J`).
* `$C800` reads as zeros until claimed, and **`peek` cannot claim it** -- a
  debug read bypasses the bus, so it triggers no soft switch. Testing the
  last-claimant handover needs a real CPU access from guest code, not a probe.

## 11. Stray characters on the play screen -- partly solved

**Found (2026-08-17):** `TMR_RPRT_ROW` was `$04C8`, documented as
"$0400 + 5*40". The Apple II text page is not linear -- rows interleave in
thirds -- so row 5 is `$0680`, and `$04C8` is column 32 of ROW 9, with the
tail of a 16-character write running into the `$04D0` screen hole where it is
never displayed. Corrected to `$0680`.

**And it was invisible for a second, independent reason.** `TIMER_PROBE` runs
before `PRC_INIT`, and `TTY_INIT`'s `TTY_CLR_BODY` blanks rows 1-23 right
afterwards -- erasing whatever the report wrote. So docs/TASKS.md #6's "loud,
not silent" duty has never actually been loud, in any image, since it landed.
Fixing the address is necessary and not sufficient; the real fix is a console
the kernel can log to, which is what this document is for. Deliberately NOT
papered over by moving the report to a row `TTY_CLR_BODY` happens to miss.

Method note, since reading the code did not settle it: sampling row 3 every
500K cycles through boot showed it CLEAN at 0.5M and dirty at 1.0M, which
proved the junk arrives after the clear rather than surviving it. That is what
turned a code-reading argument into a two-minute measurement.

Residual characters remain in some rows and are not explained by this. The
`$0400+row*40` mistake is worth grepping for wherever else a screen address
was computed by hand.

## 11b. SOLVED: the stray characters were never stray (2026-08-17)

The "residual characters ... not explained by this" are `TTY_VT_SUITE`'s own
output. Every one of them is a deliberate write from the boot-time escape
battery, and `scripts/check_play.py` asserts each cell by address:

| screen | glyphs | the case that writes it |
|---|---|---|
| row 3 col 4 / col 20 | `AB` / `f` | `ESC[r;cH`, and the `f` alias |
| row 4 col 6 / col 9 | `L` / `R` | `ESC[nD` left, `ESC[nC` right |
| row 5 col 0 | `C` | `ESC[nD` clamping at column 0 |
| row 6 col 11 / row 7 col 10 | `U` / `D` | `ESC[nA` up, `ESC[nB` down |
| row 8 col 0 | `0123` | `ESC[K` keeping text before the cursor |
| row 9 col 0 | `IN` | `ESC[0;7m` both params, then `ESC[27m` |
| row 10 col 8 / col 16 | `T` / `OK` | TAB stop, unknown CSI final byte |
| row 21 / 22 / 23 | `S` / `ABC` / `Z` | `ESC 7`/`ESC 8`, SGR, `ESC[K` |

Nothing was wrong. The screen was showing a passing test.

**What made it obvious was porting to the UltraTerm**, which is the useful part.
The card's VRAM is blanked by `UT_INIT` and is physically unreachable except
through this driver, so anything visible on it *must* have been written by the
tty after init -- "stale memory left by a previous owner", the hypothesis that
survived two investigations of the //e text page, is not available as an
explanation there. The characters appeared at identical (row, col) on both
backends, which is the signature of a cell write through `TTY_WR_CELL`, not of
leftover bytes at some `$0400` address. A second backend is a diagnostic
instrument, not just a feature.

Section 11's real finding (`TMR_RPRT_ROW` pointing into a screen hole) stands
and was a genuine bug. Only the leftover "residual characters" paragraph is
retracted.

## 11a. Original note (superseded above)

Rows 3-7 carry scattered single characters (`AB`, `L R`, `C`, `U`, `D`) from
boot. Established so far: the only direct screen write in the tree is
playtest's row-0 banner; `TTY_INIT` is called unconditionally from `PRC_INIT`
and `TTY_CLR_BODY` clears rows 1-23; and tty output lands on the right rows
(text is correct, junk survives only past the end of written text). Those
facts do not yet reconcile -- if the clear runs, those rows should be blank.
Cosmetic, but it means either the clear or the row mapping is not doing what
it appears to. Not chased further.


---

## 12. Console debt, stated honestly (2026-08-21)

> **STALE AS OF 2026-08-30 -- THE REFACTOR BELOW HAS BEEN DONE.**
> This section says there are "**zero `VC_*` symbols anywhere in the
> kernel**" and that reaching per-console state means converting 23
> flat variables and threading a console index through every tty
> routine. That was true when written. Today the kernel has **44
> `VC_*` symbols**: `VC_COUNT` is 4, per-console state lives in the
> annex at `VC_SLOT_ADDR` as a 290-byte `VC_ST_SIZE` struct, and
> `VC_SWITCH`/`VC_RESET` are in `src/kernel/tty3.s` and gated by
> `check-vc`.
>
> **What is actually missing is smaller and different: a TRIGGER.**
> `VC_SWITCH` is called from exactly one place in the tree --
> `src/test/playtestb.s`, a test harness. No key chord, no syscall,
> no command reaches it, so a user has no way to change console.
> Section 4 of docs/COMPLETISH.md has it right: the switching
> *interface* and whatever owns the policy, not the mechanism.
>
> Left as written rather than rewritten, per this section's own
> precedent -- but do not price the work off it.


Operator: *"we will need the native 80 col support. and the virtual
consoles you promised, and a way to switch between the modes, I could
go on."*

Checked rather than taken on trust, and **sec 2's claim is wrong about the
code**.

### The promise vs. the build

sec 2 says v1 ships "one active virtual console (`vc0`) **with state
shaped so more can be added**", and sec 7 says switching is then "just":

```
active_vc = n
backend.redraw(vc[n])
```

**The state is not shaped that way.** There are **23 flat TTY state
variables** across `src/kernel/tty.s`, `tty2.s` and `process.s` --
`TTY_IN_LEN ds 1`, `TTY_IN_POS ds 1`, `TTY_RAW_BUF ds 64`,
`TTY_OUTSHDW ds 80` and the rest. Single instances, none indexed by
console. There are **zero `VC_*` symbols anywhere in the kernel.**

So sec 7's "switching is just two lines" is true of the *design* and false
of the *code*. Getting there means converting 23 variables to
per-console arrays and threading a console index through every tty
routine that touches them. That is a real refactor, not a feature bolt-
on, and it is the kind of gap that only shows up when someone asks.

**Kept the design as written and flagged sec 2 rather than quietly
rewriting it.** The design is still right; what was wrong is the claim
that v1 had already met it halfway.

### The queue this implies, ordered by what blocks what

1. **Native Apple 80-column support.** sec 2 deferred it: *"Apple
   80-column support is deferred."* The IIc has **no slots**, so the
   UltraTerm backend cannot exist there and the 40-column fallback is
   the only path today. **This blocks the IIc target entirely** and is
   the first thing to build. `sec 8`'s backend abstraction is the right
   seam -- it needs a third backend, not a special case.
   **BACKEND BUILT AND GATED 2026-08-23 -- sec 14 -- but NO SHIPPING
   IMAGE SELECTS IT.** [Superseded 2026-09-03 evening: auto now boots
   the BEST surface present -- card, else built-in 80; 40 is never a
   default, and the test harnesses pin it. VIDMODE.md sec 10.] Auto
   selection WAS (UltraTerm else
   40-col); the only selector today is `TTY_BKND_REQ=2` via the
   `PT_N80` gate poke. So the IIc-blocking half of this item -- a
   machine actually coming up at 80 columns -- is still gated on
   item 4's selection/mode-switching scope call. Do not read DONE
   here.
2. **Per-console state.** The 23-variable refactor above. Nothing user-
   visible ships from it, which is exactly why it will keep being
   deferred unless it is scheduled on its own.
   **DONE 2026-08-23 -- sec 14.**
3. **Virtual consoles.** Cheap *after* (2), as sec 7 describes.
   **BUILT since this was written (four consoles, `chvt`, docs/man/chvt.1;
   sec 13 and 14 below). The "not built" wording was true on 2026-08-23.**
4. **Mode/console switching.** The key binding, the indicator (sec 6
   used to reserve row 0 for it; that reservation is gone as of the
   2026-09-03 reclaim, so the indicator needs a different home --
   see sec 6's closing note), and the redraw path.
   **BUILT since (`chvt`, `vidmode`; docs/VIDMODE.md).**

**The scope call (S3, 2026-08-23):** `ARCHITECTURE.md` marks
additional virtual consoles and raw/noecho as explicitly v2+, while
task #14 names them as its own later work -- and this project's scope
statements have drifted before without amendment (`PLAN.md` sec 2). Items
1-2 are unambiguously in scope and were done first. Items 3-4 (anything
user-visible: switching, key bindings, the row-0 indicator, logical
screen buffers, raw/noecho) were **deliberately held** on 2026-08-23
until the operator ruled; they have since been built (above).

### What "I could go on" is pointing at

Also outstanding, from this file's own text: **raw/noecho mode** (sec 4/sec 5,
deferred until a program needs it -- `mash` and `vi` both do), and
**userland line editing** (sec 5, which raw mode gates). The `rows` report
being 23 not 24 once a VC indicator owned row 0 is no longer applicable --
the 2026-09-03 reclaim (sec 6) removed the reservation the report was going
to be about; `rows` stays 24, unconditionally, and a future VC indicator
finds its own home inside the scroll region instead.

None of it is hard. All of it is unbuilt, and the honest position is
that the console is **v1 scope met, v2 designed, v2 unstarted** -- with
the IIc target now supplying the first concrete reason to start.

---

## 13. The original UltraTerm and IRQs -- a real hardware exposure

Operator, 2026-08-21: *"my ultraterm card is the original one so it has
issues with interrupts on the enhanced IIe."*

**This is a live bug against real hardware, not a compatibility
footnote, and it makes native 80-column support necessary on the IIe as
well as the IIc.**

### The mechanism, from the commons

`learning:01M0ACSFHDGY0P566NCMNHYV57` establishes it: the //e's ROM
vectors IRQs through **`$C3FA`**, and *who owns that address depends on
`SLOTC3ROM`*. With a Videx card in slot 3 and `SLOTC3ROM` external,
**the CPU executes the CARD's ROM as its interrupt handler.**

Videx shipped bytes for exactly that -- at offset `$FA` of every
256-byte page, `BIT $C015` / `STA $C007`, a stub that detects "I was
entered as the IRQ handler" and hands off to the machine's internal
handler, which then dispatches through `($03FE)`.

**That is `[fact]` from the *v3* firmware dump.** An original UltraTerm
predates it. So on an original card an IRQ taken with `SLOTC3ROM`
external executes whatever the original firmware happens to hold at
`$C3FA` -- which is precisely the reported symptom.

### What maux does today, and why it is exposed continuously

`UT_CLAIM` (`src/kernel/ultraterm.s`) sets `SETSLOTC3ROM` as a
**per-entry precondition on every tty write**, because claiming the
`$C800` VRAM window requires reaching the card's `$C300` I/O SELECT
space.

**It is never cleared.** Grepping the whole kernel finds exactly two
`SLOTC3ROM` writes: the `SET` in `UT_CLAIM`, and a `CLR` on
`UT_DETECT`'s *failure* path. So after the first tty write, `SLOTC3ROM`
stays external for the rest of the session -- and maux takes interrupts
in main context continuously (the scheduler tick, `^C`, and interrupts
now run during MLI).

**On a v3 card the stub absorbs this. On an original card it does not.**

### The fix, and it is small

1. **Restore `SLOTC3ROM` to internal at the end of each tty operation.**
   The card's CRTC registers live at `$C0B0`-`$C0B2` -- **slot I/O
   space, not slot ROM** -- so only the `$C800` claim and the VRAM
   access need `SLOTC3ROM` external. Outside those windows, `$C3FA`
   should belong to the internal ROM handler, which dispatches
   correctly through `($03FE)`.
2. **Bracket the remaining window with `SEI`/`CLI`.** `UT_CLAIM` is not
   interrupt-bracketed today (checked: no `sei`/`php` at any call
   site). The exposure then shrinks from "the whole session" to "a few
   dozen cycles inside a bracketed write" -- the same discipline
   `BankCopy` already uses for its `$C073` windows.

That should make an original UltraTerm behave, and it costs a handful
of cycles per tty entry.

### SHIPPED (2026-08-21) -- and the `$C800` latch question is settled

The fix above is in `UT_CLAIM`, in the cheap shape, because the
question it hung on came back the convenient way.

**Does clearing `SLOTC3ROM` release the `$C800` last-claimant latch?
No.** Measured, not reasoned off Sather's tables (`src/liba/stdio.s`'s
header records what reasoning off those tables cost last time), and
measured on **both** rigs, which agree byte for byte:

| step | `$C800` reads |
|---|---|
| release `$CFFF` + claim `$C30C`, `SLOTC3ROM` external | `$38` -- the card |
| `CLRSLOTC3ROM`, nothing else | **`$38` -- still the card** |
| read `$C3FA` (internal, i.e. the IRQ vector fetch) | `$4C` -- internal ROM |
| `SETSLOTC3ROM` again, no re-claim | `$4C` -- still internal |
| release + re-claim | `$38` -- the card |

`SLOTC3ROM` selects who *decodes* `$C3xx`; it does not touch the card's
own `$C800` enable. `INTCXROM` likewise only **masks** the window --
setting it hides the card, clearing it hands the card straight back
with no re-claim (verilogapple, by writing through the window in each
state). What *does* take the window away is an **internal `$C3xx`
access**, which sets `INTC8ROM`; only `$CFFF` or a re-claim undoes it.
Deposited as `learning:01M0J7NS4352S0MABTR2MENPA8`.

So the claim outlives the restore, and `UT_CLAIM` needs no bracket
around the VRAM access at all -- only around the claim itself:

```
UT_CLAIM  php / sei
          sta CLRINTCXROM / sta SETSLOTC3ROM
          lda CLRC8ROM  (release)  /  lda UT_SIG  (claim)
          sta CLRSLOTC3ROM
          plp / rts
```

`PHP`/`PLP`, not `SEI`/`CLI`: the tty calls in already masked and a
blind `cli` would unmask the kernel mid-operation. **`SLOTC3ROM` is
external for 12 cycles**, all of them masked; the worst-case *added*
interrupt-disabled window is **24 cycles** (five 4-cycle accesses plus
the `PLP`), and zero when the caller was already masked. `sta` rather
than `stz` for the restore keeps `A` = the signature byte `UT_DETECT`
compares. `UT_DETECT`'s own fail-path store is gone: `UT_CLAIM` now
gives that guarantee on **both** paths, which the present-card path
needed just as badly.

**The gate has teeth on the actual invariant, not on the pixels.**
`check_ultraterm.py`'s `check_bracket()` catches the claim in flight
(`until_write` on `$C00B`, then `$C00A`) and asserts the mask is set
inside the window, that the window is <= 16 cycles, that the restore
preserves `A`, that the caller's mask comes back, and -- at rest --
that `softswitches` reports `SLOTC3ROM` **internal**. Watched failing:
deleting the restore leaves **every one of the 40 display assertions
green** and only the two new ones red, which is this bug's whole
signature; deleting the `sei` reddens only the mask assertion.
(`uttest.s` now `cli`s and the gate boots with mouse/clock off, so the
mask observed inside `UT_CLAIM` can only have come from `UT_CLAIM`.)

**Still open, and pre-existing:** an interrupt taken *during* a
multi-cell burst still loses the window, because `MAIN_IRQ_SHIM` ends
with `CLRC8ROM` + a SmartPort re-claim on every main-context tick
(`timer.s`). That is unchanged by this fix -- the shim steals the window
the same way whichever side of `SLOTC3ROM` the `$C3FA` fetch fell on --
and closing it means claiming per cell or masking the whole burst,
which is an interrupt-latency decision rather than a correctness-on-an-
original-card one.

**Also now stale:** `src/kernel/procfd2.s`'s MLI-bracket comment still
says the ROM path reaches "the Videx IRQ stub when slot 3 holds the
UltraTerm". After this change it is the internal ROM in every case.

### Native 80-column is the BASELINE, not the replacement

**Corrected 2026-08-21.** A first draft of this section concluded that
native 80-column should become "the default backend worth having",
because the UltraTerm path carries a shared `$C800` window, a slot-3
IRQ vector, and revision-dependent firmware. That reasoning is sound
about *robustness* and wrong about *purpose*.

Operator: *"the internal hardware is fine but it doesn't produce the
lovely high-matrix fonts for long-persistence phosphor displays."*

**Nobody buys an UltraTerm for 80 columns -- the //e already has 80
columns.** They buy it for the character matrix. And maux already
drives it that way: `UT_INIT` selects **HQ 80x24**, the CRTC's own cell (UT-CELL 2026-10-21 -- this said a fixed
`UT_CELL_H equ 16`, and drew a short glyph at the top of a tall cell), and `UT_MODE_HQ80 = $80`
leaves the mode latch's bit 2 **clear**, selecting **set1 -- the dense
"high quality" font** rather than the standard one.

The card's cell is not one size, and "dense" is not one font. The
firmware's format-4 entry (`$CF55`, which maux copies) differs by
revision, and so does the character ROM set 1 selects:

| card | format 4 | set 1 (`$800`) glyph rows |
|---|---|---|
| updated (v3, `frm_b5c9`/`chs_5604`) | R9 = 8, 9-line cell, 262 lines, 60 Hz | 7 rows (ends by row 6) |
| ORIGINAL (v1, `frm_b537`/`chs_7859`) | R8 = 3 interlace, R9 = $0E = 16 lines under RN-2, ~30 Hz frames | TALL: 72 glyphs end on row 9, 5 on row 10, 9 on row 11 |

On v3 set 1 is the SHORTER font; the tall one exists only on the
original card, where a 9-line table clips the descenders. So the
driver takes cell height, interlace and timing from the card's own
entry (UT-CELL round 1; the v3 values are kept only as a guard
fallback). The earlier 'twice the vertical resolution' claim assumed
a fixed 16-line cell. Someone chose set1
deliberately; treating native 80-column as a replacement would throw
that away to fix an interrupt bug.

**So the backend set is a hierarchy, not a migration:**

| backend | role |
|---|---|
| **UltraTerm HQ 80x24** | **preferred when present** -- the card's own format-4 cell, set 1 font. The reason the card exists. |
| **Native 80-column** | **portable baseline** -- required on the IIc (no slots), and on any //e without the card. Immune to the `$C3FA` problem. |
| 40-column | last-resort fallback, already present |

The IRQ exposure above gets **fixed**, not routed around. Native
80-column is still worth building -- it is genuinely required for the
IIc and it is the honest default for machines without a card -- but it
is an *addition* to `sec 8`'s backend set, not a promotion over the
UltraTerm.

### And the matrix is not the only thing the card can do

Operator, same exchange: *"plus the fact that ultraterm can produce
other useful video modes."*

**The geometry is software-selectable and the driver already has the
levers**, it simply pins one mode. `src/kernel/ultraterm.s` programs
the CRTC directly: `UT_R_COLS` (R1, horizontal displayed),
`UT_R_ROWS` (R6, vertical displayed) and `UT_R_MAXSCAN` (R9, cell
height - 1). `UT_INIT` copies the card's own format-4 entry R0-R11 from `$CF55` (needs MEMSEL, `$C0B2` bit 7); the cursor is that entry's R10 start (steady) to its R11 end. Other
geometries are a different set of writes to registers the driver
already knows.

The card also carries a **second personality**: `UT_VTEMU` (mode-latch
bit 4) selects **native UltraTerm mode** versus **Videoterm
emulation**, in which the VRAM window banks Videoterm-style and bits
3-0 stop being a page number. So "UltraTerm" is really two cards in
one, and maux uses one of them.

**The constraint that bounds all of it: VRAM is a 4 KB ring**
(`UT_VRAM_MASK = $0FFF`, 4-bit page select plus an 8-bit window
offset). 80x24 is 1,920 characters -- under half the ring, which is why
the current scroll can use it. A 128x32 geometry would be 4,096
characters, **exactly the whole ring with nothing spare**, so a mode
that large changes what scrolling can do. Any mode work has to budget
against that, not just against the CRTC.

**Two connections worth noting before anyone builds either half:**

- **Virtual consoles (sec 7) and video modes compose.** sec 7 already says
  inactive VCs update *logical buffers* without touching hardware --
  which means different VCs can hold different geometries, with only
  the active one painted. Shell at 80x24, build output wider. That
  falls out of the existing design rather than needing new machinery.
- **The mode set is also a graphics-future question** (sec 10), since
  changing cell height and displayed rows is the same register work.

**Deliberately not enumerating the modes here.** The specific
geometries the card supports want the **Videx UltraTerm manual**, which
this project does not have and the commons does not carry. Guessing a
mode table into a design doc is how a wrong number becomes load-bearing
-- and this section has already been corrected twice today for asserting
past the evidence. **Obtain the manual, then write the table.**

### RESOLVED by the manual -- it is a known factory issue with a kit

The UltraTerm **addendum** (`ULT-DOC-000`, 12 March 1985) is now in the
commons as `learning:01M0J3YRZ8A7Y9B4FMED3XFS58`, and it names this
exact problem. Videx shipped a **three-part field update** for the
enhanced //e:

1. **A firmware EPROM** -- *"With the introduction of new ROMs for the
   Apple //e, Videx has updated the UltraTerm to insure
   compatibility."*
2. **A 251C PAL into socket U4.**
3. **A board mod** -- the diode below U6 removed (later boards: a jumper
   block lifted), and **J1 moved to the LOWER two pins**, the "Apple
   II+ position".

Videx's own framing of the cause:

> *"With this enhancement, the Apple //e now supports the use of video
> display cards in slot 3. The UltraTerm is no longer required to
> override Apple's slot select routines. **However, the new chip set
> does require a change in the UltraTerm.**"*

The enhancement *removed* the need for the card's slot-3 override and
simultaneously *broke* the card that was doing the overriding.

**And it closes the loop on `learning:01M0ACSFHDGY0P566NCMNHYV57`.**
That note found the `$C3FA` compatibility stub in the **v3 firmware
dump**. The v3 firmware is almost certainly this update's EPROM
[likely -- dating and purpose align; not confirmed by comparing dumps].
So an un-updated card has pre-enhancement firmware with **no stub at
all**, which is why the symptom exists and why it is
**load-dependent**: text displays perfectly, and it only misbehaves
once something takes interrupts in main context -- which maux does
continuously.

**So there are two independent fixes, and they are not alternatives:**

- **Hardware:** apply the Videx update if the parts can be sourced.
  **The contents are not the obstacle -- the chips are.** See the
  sourcing note below.
- **Software:** the `SLOTC3ROM`-restore + `SEI` bracket described
  above. **Worth doing regardless** -- it makes maux correct on an
  un-updated card, which is the population that actually exists.

Do the software fix. Treat the hardware kit as the real repair for
anyone who can source it.

### Sourcing the kit -- the bits are preserved, the silicon is not

**Both programmable parts of the 1985 kit already exist as data, and
we have both on disk.** MAME's `a2ultrme` romset carries all three
chips the update touches:

| kit part | MAME name | our name | size |
|---|---|---|---|
| firmware EPROM | `frm_b5c9.bin` | `ultraterm/firmware_v3.bin` | 4,096 B |
| character generator | `chs_5604.bin` | `ultraterm/chargen_v3.bin` | 4,096 B |
| **the U4 PAL** | `ult_251c.jed` | `ultraterm/pal_u4_v3.jed` | 773 B |

`scripts/vendor_mame_roms.py` assembles them into
`vendor/mameroms/a2ultrme.zip`. This is not a lucky accident: **PAL
contents survive precisely where an emulator's romset needed them.**
The same is true of the AppleMouse -- we vendor `mmi_pal16r4a_jedec.2a`,
a PAL16R4A fuse map read out on a BP-1400/84 programmer in 2014.
Someone put a 40-year-old chip in a reader before it died, and that is
the only reason the logic still exists.

**So the hard part is the physical device, not its contents** --
observed 2026-08-21, and it inverts the usual retrocomputing problem.

- Original bipolar PALs are **one-time-programmable**. You cannot
  erase and reuse a pulled one, and fusible-link parts of that age
  degrade.
- The standard substitute is a **GAL** (electrically erasable, absorbs
  the 20-pin PAL family). Lattice's GAL16V8 is long discontinued;
  Microchip's ATF16V8 is the live equivalent and has been drifting
  toward EOL. New-old-stock is a counterfeit minefield.
- You also need a programmer whose algorithm covers the target part --
  the ATF series notably needs a current one (TL866II+/T48 class).

**Open item before anyone burns one.** Unlike the AppleMouse file,
`ult_251c.jed` **does not declare its device** -- no `DD`/`DM` line,
just a bare `*D21051` code from an old Data I/O-style dump. Measured
geometry: **560 fuses, 20 product-term rows x 28 columns**, i.e. a
14-input part. That does not match any of the textbook 20-pin
`PAL14L4`-class sizes (which are 16 rows), so **the target device must
be identified from the board before programming a substitute** -- the
addendum's block diagram puts U4 along the top edge, so a pin count
off a real card would settle it. Programming the right fuses into the
wrong device yields a part that fits the socket and misbehaves.

---

## 14. SHIPPED (2026-08-23): per-console state, and the native 80-column backend

Stream S3 closed sec 12's queue items 1 and 2. What sec 12 said -- *"23
flat TTY state variables ... zero `VC_*` symbols anywhere in the
kernel"* -- is no longer true of the code.

### 14.1 Per-console state -- the VC struct

The 23 flat cells are now **one contiguous 290-byte struct in
`src/kernel/tty.s`** (`VC_STATE`..`VC_ST_END`): 18 scalars
(cursor, cooked-input lengths, escape-parser state, SGR attribute,
ESC 7/8 stash, raw-ring indexes, shadow length) plus the three
buffers (`VC_INBUF` 128, `VC_RAW_BUF` 64, `VC_OUTSHDW` 80). Every
tty routine reads the struct's cells directly -- the hot paths cost
exactly what the flat cells cost; there is no per-access indexing.

**Switching is a block exchange, not indexed addressing.** Backing
slots for `VC_COUNT` = 4 consoles live in the **annex** (aux bank 0,
`VC_SLOT_ADDR` = `$7000`, directly above the LZ pathname slots --
the cwd-table precedent, and zero bytes of kernel image).
`VC_SWITCH` saves the active image to its slot and loads the
target's via two BankCopies, interrupt-masked so the tick hook
cannot cook keys into a half-switched console; a console touched
for the first time is `VC_RESET` instead of loaded (`VC_INITED`
bitmask). Adding a per-console field means adding it INSIDE the
struct; `VC_ST_SIZE` is derived, so the exchange covers it
automatically -- and `make check-vc` runs a 6502-side roundtrip
(sentinels -> switch -> $A5 fill -> switch home -> 16-bit checksum
over all 290 bytes) that fails on any field the exchange misses.
Teeth proven by shortening the copy 64 bytes: check-vc red at the
checksum step while check-play stayed green.

**Not per-console:** `TTY_COLS` and `TTY_BKND` (one display until
per-VC geometry exists), `TTY_OUTBUF` (staging scratch).

**Debt handed to the merge:** the old flat cells still sit unused
in `src/kernel/process.s` lines ~219-244 (S3 does not own that
file) -- 143 dead bytes for S1/S8 to delete; and
`inc/mm.annex.equ` should record the `$7000`-`$7488` annex
claim beside `LZ_PTH_ADDR`. The `TTY80_STT_SZ equ 32` annex
reservation in that file predates this work and remains unused.

**What VC_SWITCH deliberately does NOT do:** no redraw. Inactive
consoles have no logical screen buffer yet (sec 7's next layer), so
switching exchanges line-discipline/parser/cursor state while the
glass keeps showing what it showed. That, the keyboard binding, and
per-console read channels are sec 12 items 3-4 -- awaiting the scope
call.

### 14.2 The native 80-column backend (N8)

`TTY_BKND` selects among three backends: 40-column, UltraTerm, and
**native //e 80-column** (`N8_*` in `src/kernel/tty2.s`) -- the sec 13
hierarchy's portable baseline, immune to the `$C3FA` exposure, and
the only possible console on a IIc.

Mechanism: even display columns live in **aux bank 0** `$0400-$07FF`,
odd in main, both at `rowbase + col/2` through the same interleave
table. Odd columns are plain stores. Even columns open a masked
window: **force `$C073` to bank 0**, `SET80STORE`, `PAGE2ON`, access,
`PAGE2OFF`, `CLR80STORE`, restore the process bank via
`PRC_SEL_CRBNK`, `plp`. The bank forcing exists because an
80STORE+PAGE2 access follows the **selected** RamWorks bank
(`learning:01KW1GTYHGXMBZNR6DMQB2F712`, corroborated again by this
work: removing the force makes the shell prompt vanish the moment
processes run, because even-column writes land in the current
process's bank). Resting state is 80STORE OFF -- the STEADY STATE
that BankCopy's restore-exact bracket and S1's fork sabotage assume
-- and the aux half is readable through the same route, so the
cursor's save/paint works (unlike the UltraTerm's write-only VRAM).
Scroll and clear run the 40-column main-half code unchanged, then an
aux pass with one masked window per row (~600 cycles, well under a
VBL period). Row 0 is never touched.

**Selection is by request, not promotion.** `TTY_BKND_REQ` (0 auto,
1 force-40, 2 force-native-80) is read once by `TTY_INIT`; AUTO
meant UltraTerm-else-40 until the 2026-09-03 evening ruling (now
UltraTerm-else-built-in-80, VIDMODE.md sec 10); at the time no image changed
behaviour. Promoting native-80 into the auto chain (it is the honest
default for a card-less machine, per sec 13) is part of the
mode-switching scope call, not taken unilaterally -- and every gate
that reads 40-column screens would need to move with it.

**Gates.** `make check-play80n` boots the SAME `play.po` as
check-play/check-play80 with the `PT_N80` poke: the 16-case VT
battery asserted cell by cell in the half each byte must land in
(imported from check_play.py so the two cannot drift), the 80STORE
bracket caught in flight (masked, <=2000 cycles, kernel writer, OFF
at rest -- the same teeth-on-the-invariant shape as sec 13's SLOTC3ROM
gate, because the display is pixel-identical with the restore
deleted), row 0 holding ordinary scrolled content (not the old
reserved-line banner, gone as of sec 6's 2026-09-03 reclaim) after a
real scroll, and a live shell at 80 columns. Sabotages, each seen
red before trust: restore
deleted -> only the invariant assertions red (the bug's whole
signature); store parity flipped -> every cell pair reported
transposed, by name; bank forcing removed -> prompt never renders.

---

## 13. The console store: where a non-displayed console goes
## (2026-08-30)

Operator, on being told a switch would not change the glass:
*"you need a kstored or some such thing so that the non-displayed
console goes somewhere."* Right, and the code is already shaped for
it.

### What is actually missing, in order

The question that settles the design is **"does a write to a
non-visible console block?"** and today the answer is neither yes nor
no: **you cannot write to a non-visible console at all.** There is no
`PCB_VC`, no console field on a process, nothing -- `VC_STATE` is a
SINGLE live struct (its own comment: "struct base -- ACTIVE console")
and `VC_SWITCH` copies live->slot[old], slot[new]->live. `TTY_WRITE`
consults no console id because there is none to consult. So a write
lands on whichever console is swapped in, whoever issued it.

That puts the work one step earlier than "add a trigger", and the
order is:

1. **Ownership.** A console id per process (or per tty fd), so a
   write knows where it is going. Nothing else is possible without
   this.

   **Attempted and REVERTED 2026-08-30, and the findings are the
   useful part:**

   * **It cannot be a PCB field.** The PCB entry is *exactly* 16
     bytes and full (PID/STATE/WCHAN/BANK/PARENT/SAVEDSP/EXITSTAT/
     BRK + 8 FDTABLE), and `mm.annex2.equ` rules that it stays
     16 because `PCB_PTR_FOR` computes `pid<<4` in four ASL/ROL
     pairs -- a non-power-of-two stride would need a real multiply
     on *every* PCB access, in `SCH_SWITCH`, `SCH_SLEEP` and the
     `SCH_WAKEUP` scan.
   * **The right shape is a main-memory array indexed by pid**,
     `PRC_VCTAB ds PCB_COUNT`, exactly like `PRC_BASEPG`. Seed in
     `PRC_INIT`; inherit at the two sites that already inherit
     `PRC_BASEPG` -- `process2.s` for spawn, `procfork.s` for fork --
     right beside the cwd inheritance whose comment makes the same
     argument ("what makes cwd a per-PROCESS property rather than a
     global one"). That much was written and built clean.
   * **It is INERT until something can switch, and that is why it
     was reverted.** Every pid seeds to 0, so nothing observable
     changes -- and it costs **82 bytes on all 27 kernel images**,
     against a ceiling two images crossed earlier the same day.
     Spending the ratchet on unproven, inert code is the wrong
     trade.
   * **It cannot be tested from a harness.** The first attempt had
     `forktestb.s` do `lda PRC_VCTAB,x` directly; the harness runs
     in PROCESS context, so it read the aux bank and got the
     poison byte `$A5` rather than the kernel's main-memory table.
     Poking the table from the checker mid-run works in principle
     (`PRC_VCTAB` resolves to `$14FE` in `forktest.bin`) but is
     timing-fragile, which is its own smell.

   **AND THEN IT DISSOLVED. Operator: "starting to smell like you
   need a /dev/" -- and the scaffolding is already built.**

   `inc/sc.devfd.equ` defines `FD_DEV_BASE $80` and
   `FD_TTY0`..`FD_TTY3`: a `PCB_FDTABLE` byte holds *either* an OFT
   index *or* a character-device handle. And the syscall paths
   already range-check all four:

   ```
   :objok      cmp   #FD_DEV_BASE
               bcc   :oftobj
               cmp   #FD_TTY3+1
               bcc   :istty
               ...
   :istty      jmp   TTY_READ        <- the handle is DISCARDED
   ```

   **The kernel already validates four consoles and throws away
   which one, one instruction later.** `TTY_READ` and `TTY_WRITE`
   take no console argument, and `PRC_DFLT_FDS` only ever hands out
   `FD_TTY0` (`procfd.s`).

   So a console id per process was **redundant state** -- the fd
   table already encodes it, and fork and spawn already copy the fd
   table, so inheritance is free. That is why `PRC_VCTAB` felt
   wrong: it duplicated an answer the system already had. Reverting
   it was right for a better reason than the one recorded above.

   ### The corrected shape

   1. **Pass the console through.** `:istty` computes
      `handle - FD_DEV_BASE` and gives it to `TTY_READ`/`TTY_WRITE`
      instead of discarding it. No new per-process state at all.
   2. **`PRC_DFLT_FDS` keeps handing out `FD_TTY0`**, so the default
      is unchanged and everything existing keeps working.
   3. **A `/dev/` path namespace** makes it reachable: `open` on
      `/dev/tty2` yields a fd whose table byte is `FD_TTY2`. Then
      redirection (`cmd > /dev/tty2`) and `chvt` are ordinary
      userland, with no console-specific syscall invented for
      them.

   This is the Unix answer, it needs no PCB byte, and step 1 above
   is better read as "route the handle that is already there" than
   as "add an owner".

   ### How do we mknod? We do not -- and GNO/ME is why. (2026-08-30)

   **The argument from ProDOS reserved `storage_type` values was
   withdrawn.** An earlier version of this section leaned on the
   TRM's *"all other values are reserved for future use"*. ProDOS
   8 has been end-of-life since the 1990s; a label reserving
   values for a future that never arrived binds nobody. What
   survives is the consequence rather than the label -- a
   `storage_type` no reader knows still confuses every tool that
   reads these volumes, a2til included, and every gate in this
   tree reads its images with a2til.

   **The real precedent is GNO/ME**, the one shipped, field-tested
   Unix for an Apple (the IIgs, over GS/OS). It has **no mknod** --
   not a limited one; the string does not occur anywhere in its
   published documentation. Its devices are built-in kernel
   drivers, and its kernel reference says so directly:

   > *"GNO/ME supports a new range of character device drivers.
   > These drivers are not installed like normal GS/OS drivers,
   > but they are accessed the same way... `.NULL` This driver is a
   > bit bucket. Any data written to it is ignored, and any
   > attempt to read from it results in an end-of-file error
   > ($4C)... these GNO/ME drivers are accessed with the same Open,
   > Read, Write, and Close calls that are used on files."*

   Built-ins: `.TTYCO` (console), `.TTYA[0-9,A-F]` (serial),
   `.PTYQ[0-9,A-F]` (ptys), `.NULL`. A synthetic namespace reached
   through the ordinary open path -- which is exactly what maux
   built, arrived at independently and now confirmed by
   precedent. See [[01M0798FFCHB60SWQDE8NQEQXN]] for GNO's other
   Unix-onto-Apple rulings.

   **What we take from them, and what we don't.**

   *Taken:* no mknod; no on-disk nodes; devices reached through
   the ordinary `open`. And `.NULL`'s semantics confirm ours --
   writes ignored, reads at EOF. GNO reports EOF as error `$4C`
   where maux reports carry-clear with `trans_count = 0`; that is
   not a divergence in meaning, it is maux's own normalisation of
   MLI EOF ([[01M0PYBMS4TSKS0RW5N2NAENV2]]), and it is the form a
   `cat` loop here already expects.

   *Also taken, as a direction rather than code:* GNO controls
   device characteristics through **`ioctl()`**, explicitly *not*
   through device-specific calls -- *"the characteristics of
   GNO/ME drivers are controlled through the `ioctl()` system
   call. The GS/OS Device calls (like DInfo, DStatus) are not
   applicable"*. sec 14's multi-mode consoles need a way to set a
   console's mode; that is what it should be, rather than a
   bespoke syscall.

   *Not taken: the spelling -- because GNO's names serve a goal
   maux does not have.* `.TTYCO` and `.NULL` are **GS/OS device
   names**: the native Apple character-device convention, a
   leading period, which cannot collide with a filename because
   a ProDOS name must begin with a letter. GNO used that
   convention because it is, in its own FAQ's words, *"intended
   to be a **replacement for ORCA/Shell**"* while still running
   *"the various ORCA languages and (the majority of)
   utilities"* -- GS/OS binaries that open GS/OS device names.
   Keeping that ecosystem working **required** the GS/OS
   spelling.

   maux inherits no such ecosystem. ProDOS 8's MLI offers no
   character-device namespace at all -- that is a GS/OS feature --
   so there are no //e programs whose names we would be
   honouring, and a GNO binary is 65816 code that cannot run
   here regardless. Copying `.TTYCO` would be cargo cult: it
   buys nothing and costs the name every shell script and every
   human habit already uses. maux is Unix; `/dev/null` is what a
   human types.

   The leading-dot *mechanism* is still worth remembering -- it
   is collision-proof by construction -- if an alias is ever
   wanted.

   **One real hazard their docs surfaced.** `/dev` was a live
   volume name in period practice -- GNO installed *itself* into
   `/dev/gno`, with `/dev/gno/src` and `/dev/gno/orca` beneath
   it. So this namespace shadows a volume actually named DEV.
   That is the same property Unix's own devfs has, and it is
   accepted, but it is the strongest argument for eventually
   accepting the dotted spelling as an alias.

   ### What shipped (2026-08-30)

   `PRC_DEVOPEN`, in the new `src/kernel/procfile5.s`. Three
   devices: `/DEV/TTY`, `/DEV/TTY0`, `/DEV/NULL`. Matching folds
   to 7-bit upper case, because the high bit is not settled at
   this layer (liba's own `asc "..."` literals arrive high-bit
   set, characters typed at a console arrive stripped) and
   because nobody types `/DEV/TTY0`.

   **`/DEV/TTY1..TTY3` are deliberately absent.** *(STALE as of
   2026-08-31 -- the trigger fired; see "What shipped
   (2026-08-31)" at the end of this section. The names are live,
   one-based, and the handle is carried through.)* `PRC_READ` and
   `PRC_WRITE` still dispatch every tty-range handle to
   `TTY_READ`/`TTY_WRITE` with the handle discarded, so all four
   names would reach console 0. A namespace whose entries
   silently alias is worse than a shorter one -- a script
   redirecting to `/DEV/TTY2` would appear to work. The trigger
   that adds them is step 1 above plus the store.

   **A bug the feature surfaced, which was the expensive part:**
   `PRC_SETEOF` refused device handles. liba's `CREAT` SET_EOFs
   every fd it opens -- that is how it truncates by handle rather
   than UNLINK+CREATE -- and sh's `>` *is* `CREAT`. So the refusal
   is precisely what would have made `cmd > /dev/null` fail, with
   an errno arriving from a call the user never made. Truncating
   a character device is now a no-op, as Unix ignores `O_TRUNC`
   on one.

   **Gated** by `check-sh`, which runs both the uppercase and the
   lowercase form. Teeth proven by two sabotages: removing the
   intercept, and removing *only* the case fold -- both go red,
   the second confirming the lowercase path is load-bearing and
   not decoration.

   **Observed while sabotaging, not fixed:** a redirect whose
   target fails to open does not make sh report and continue --
   the harness never reaches `done`. Both sabotages failed that
   way rather than through the byte assertions. That is
   pre-existing sh behaviour this test now exposes; worth its own
   look.

   **Known gap with a named trigger:** `PRC_GETEOF` still returns
   `ERR_INVAL` for a device where `PRC_SETEOF` now succeeds. Unix
   would report length 0. Nothing in the tree calls GET_EOF on a
   device today; the day something does, it wants 0, not an
   error.

   **Where the intercept goes:** `PRC_OPEN` (`procfile3.s`) copies
   the caller's path into `PRC_PATHBUF` and *then* allocates an
   io_buffer. A device needs no buffer, so the check belongs
   between those two steps -- match the path, bind the handle into
   `PCB_FDTABLE`, return the fd, and never call the MLI at all.
2. **The store.** Somewhere for an inactive console's output to land.
3. **The blit.** `VC_SWITCH` paints the incoming console's store onto
   the glass.
4. **The trigger.** Option-1..4 -- the keyboard half is already built
   (sec 12's correction).

### The store is a THIRD BACKEND, not a new subsystem

`TTY_WR_CELL` (src/kernel/tty2.s) is a single cell-store choke point.
It already dispatches on `TTY_BKND` -- `TTY_BKUT` (UltraTerm) vs
`TTY_BKN8` (native 80-col) vs the 40-column text page -- and every
path ends at `sta (P_PTR2),y`, with `P_PTR2` set by
`TTY_ROW_DST_A`. **The render target is already indirected.**

So the store is one more target: when the write's console is not
`VC_ACTIVE`, point `P_PTR2` into that console's buffer instead of the
text page. One branch, reusing the machinery that is there.

**And the store's rows are LINEAR**, which is simpler than the glass:
`base + console*size + row*width`, a shift-add, with none of the text
page's `$0400/$0480/$0500` interleave. The blit on switch walks the
store linearly and the glass through `TTY_ROW_LO/HI`.

### It must not block, and it does not have to

A write to an inactive console appends to that console's store and
returns. Blocking would wedge any background job the moment it
produced output, which is the opposite of what consoles are for.
Linux does the same thing: the tty writes into the vc's buffer and
you see it when you switch.

### Cost, measured -- and A HARD WALL FOUND (2026-08-30)

An 80x24 store is 1,920 B per console, 7,680 for four, and the
annex has the room: `ANNEX_STRCT_C` is 24,576 B at `$6000` with
only `VC_SLOT_RESV` (1,164) used at `$7000`. Claimed at `$7500`,
ending `$9300`.

**The annex was never the constraint. The KERNEL IMAGE is.**

The general implementation -- read every cell through a backend
dispatch into a staging buffer, so all three backends work --
was written and measured at **438 bytes** on all 27 kernel
images. It does not fit, and the way that showed up is worth
recording because it looked exactly like a bug:

* `check-vc` and `check-play` both failed with a blank screen
  body and no shell prompt. `check-play` **never calls
  `VC_SWITCH`**, and on a plain boot none of the new code
  executes at all -- so the cause could not be the code running.
* Confirmed by replacing the whole feature with `ds 438`, no
  code whatsoever: **the boot wedges identically.** That is the
  experiment that separated "my code is wrong" from "the image
  cannot afford the bytes", and it took one run.
* Bisected: `ds 220` boots (MAUXPLAY ends `$6597`), `ds 438`
  does not (`$6671`). So MAUXPLAY has on the order of **220
  bytes** of headroom, total.

Six io_buffers occupy `$6000-$77FF` and MAUXPLAY spawns a shell,
so it allocates them; the image's tail grows into buffers that
are live. `check_kernel_images.py` ratchets this region but
calls it *tolerated*, and MAUXEXPR sits 3,821 B into it happily
-- so the tolerance is real but it is **per-image**, and it
depends on how much LIVE code each harness has pushed past the
first buffer it allocates. For MAUXPLAY it is nearly exhausted.

**What shipped instead: 40 columns only, 186 bytes.** A
40-column glass row is 40 CONTIGUOUS bytes -- the text page's
interleave is between rows, not within one -- so a row moves
with a single BankCopy and the feature becomes a pointer walk
with no staging buffer and no per-cell dispatch at all. Native
80-column (a row split across main and aux behind 80STORE) and
UltraTerm (VRAM that cannot be read back) are **named gaps**,
not oversights.

### The wall is GONE (2026-08-30, same day)

The ~34 bytes of headroom above were real but the diagnosis was
shallow: the ceiling was never a property of the console work.
**`PMLI_IBF_BASE` moved `$6000` -> `$9800`** (and `PMLI_XFER_BUF`
`$7800` -> `$B000`) and every one of the 27 kernel images came in
under the ceiling for the first time, each by exactly 14,336 B.
`KNOWN_OVERRUN` went from 27 entries -- the largest 4,207 B -- to
empty.

(2026-09-07: the layout above the image is now EIGHT buffers
`$9800-$B7FF`, the xfer buffer at `$B800`, and the io_buffer lending
store at `$BA00` -- docs/IOBUF-LENDING.md. The image ceiling, `$9800`,
did not move. 2026-10-21, B1: it did -- six buffers at `$A000`, ceiling
`$A000`; see docs/IOBUF-LENDING.md sec 7.)

Why it was there at all: a ProDOS `.SYSTEM` image loads **flat**
from `$2000` and grows up, so the first allocation above it *is*
its ceiling -- and that was the io_buffers sitting on the floor of
`K_CODE_C`. `K_CODE_C` is `$6000`-`$C000` and used 6,656 B of its
24,576, so the room was always there; nobody had moved them into
it. `mm.mlibuf.equ` had carried the fix as a written debt
since task #11: *"future graphics/BASIC display-owner work should
relocate MLI buffers into non-video main slack first."*

Image budget: **16,384 B -> 30,720 B.** One lower ceiling
survives and is not that constant -- the harnesses park result
cells in main memory at `$9300`-`$9316` (`check_vc.py`'s
`R_VC_DONE` and friends, read with `peek_main`), so a *test*
image growing past `$9300` would overwrite its own verdict.
That is ~25,000 B, still half again what these images had.

And the overruns that table recorded were never harmless, which
is worth saying because for a long time they behaved as though
they were: an image survived only while the code pushed into the
buffer range happened not to be reached before an overlapping
buffer was allocated. That is luck, and it ran out.

### PROVEN (2026-08-30)

`check-vc` no longer only checksums the struct. `VC_SUITE` now
plants a marker cell on vc0's glass, and asserts it is **gone**
after switching to a fresh vc1 (a first-touch console arrives
blank) and **back** after switching home -- which is the half with
teeth, because with no store the glass simply stays blank on the
return.

Teeth confirmed by sabotage: making `VCS_BLIT_X` an immediate
`rts` fails at step 3, with a distinct binary so no stale
artifact could be responsible.

### REACHABLE, AND GATED END TO END (2026-08-30)

Switching is now something a program does, and the whole path is
exercised by `check-play`: **shell -> `chvt` -> `write()` ->
`ESC [ n z` -> `VC_SWITCH` -> the annex and back.**

* **`ESC [ n z`** (`TTY_CSI_VT`, tty2.s) makes console *n* active.
  `n` is ONE-BASED because that is what a person types. Out of
  range or absent is a no-op -- a terminal must not be steerable
  into a console that does not exist by a stray byte in a text
  file.
* **`chvt N`** (`src/bin/chvt.s`, 1,232 B) writes it. No new
  syscall, no privilege: it rides the escape parser the tty
  already had.

**Why a sequence and not an ioctl.** maux has no `ioctl` and
console switching is not worth inventing one for on its own.
GNO/ME's `ioctl()` remains the right long-term home for device
properties ([[01M18SQJ4CN8RQXDPPTPK0YTJ9]]); when maux grows one,
this becomes its front-end rather than its competitor.

**One bug this surfaced, worth keeping:** a switch can now arrive
from *inside* `TTY_WRITE`, which walks the caller's buffer with
`P_PTR1` -- and the blit was using `P_PTR1` as its own working
pointer. It now saves and restores it. `P_PTR2` needs no such
care, because `TTY_WR_CELL` rewrites it on every character, so
nothing can be relying on it across one.

**Teeth, both halves, by sabotage with distinct binaries:**
*(the phase was reshaped 2026-08-31 for per-fd routing -- the
labels below are the 2026-08-30 CONSOLEMARK phase's; today's
equivalents live in the round-trip phase, "What shipped
(2026-08-31)" below)*

| sabotage | fails at |
|---|---|
| blit -> `rts` | *"vc1's screen to be RESTORED from the console store"* |
| `TTY_CSI_VT` -> `rts` | *"vc2 to arrive blank (the switch itself)"* |

Neither half is vacuous: a fresh console arrives blank, so the
marker vanishing proves the switch really happened; and nothing
but the store repaints a cleared screen, so the marker returning
proves the blit.

### The Option-1..4 key trigger -- SHIPPED 2026-09-20

**The blocker below is gone and the trigger is built and gated.**
verilogapple#16 landed its persistent `buttons` tool (hold PB0/PB1/PB2
until changed, both tiers, surviving `type`), which is exactly what this
section said it was waiting for. Option (Closed Apple, `BUTN1`/`$C062`)
plus 1..4 switches consoles, in `TTY_KEYIN`; `check-lazyvc` cases 6-8
gate it by holding the button and typing the digit.

Three things about the shape, because none of them was obvious:

* **The key records, it does not switch.** `TTY_KEYIN` runs from
  `TTY_TICK`, i.e. the interrupt, and `VC_SWITCH` blits a 24x80 screen
  -- ~100,000 cycles, which is why `VC_SWITCH` already moves its own
  blit outside its masked region. So the chord sets `VC_HOTREQ` and the
  first process-context tty path performs it (`TTY_VC_PEND`, serviced
  from `TTY_READ`'s poll and from `TTY_WR_LEAVE`).
* **It must also wake somebody.** A swallowed hotkey completes no line,
  so nothing woke the blocked reader and the switch waited for the
  user's next Return -- measured, with the chord detected and the key
  correctly eaten and the screen sitting still. `TTY_KEYIN` now calls
  `TTY_WAKE_RDRS` alongside setting the request.
* **KNOWN LIMITATION, named rather than hidden:** a console whose shell
  is running a command that neither reads nor writes (`sleep 200` is the
  clean example) services the request only when it next does one or the
  other. A build that prints is fine. Fixing it properly means servicing
  at a syscall boundary, which is the hot path `KRN_EXIT`'s own comment
  warns about; it is not worth that risk for this case.

**It takes nothing away, and the first version of this paragraph claimed
otherwise.** Option-1 used to mean `^Q` -- but only because the fold was
a blanket `and #$9F` applied to whatever key was held, and a digit fell
into it. Its own note says what it is for: *"both cases at once: 'H'
$C8 -> $88, 'h' $E8 -> $88"* -- upper and lower CASE, i.e. letters. So
the fold is now scoped to letters (operator, 2026-09-20: "option
1,2,3,4 has nothing to do with QRST or JKUH"), digits fall through and
type themselves, and the hotkey displaces nothing. The four codes the
fold genuinely exists for are still `Option-h/u/j/k`: on this keyboard
`^H`/`^U`/`^J`/`^K` ARE the arrow keys, so Control-U is
indistinguishable from right-arrow and that chord is the only way to
type a literal `^U`. `check-lazyvc` case 8 pins that; case 9 pins that
`Option-5` now types a `5`.

**It will not switch to a console that has no shell, and the first
version of this section was wrong about why that matters.** It claimed
the hotkey "cannot strand anyone, because console 1 always has a
shell". What matters is not whether console 1 has one -- it is whether
the console you are ON has a READER, because `TTY_VC_PEND` is run by a
reader coming back from `TTY_READ`. Move the glass somewhere nobody
reads and there is nothing awake to move it back: the operator found
this within a minute of first touching it, by pressing Option-2 before
any `chvt 2`. The tick still ran and the key was still taken, but the
machine was unusable, which is the only test that counts.

So `TTY_VC_PEND` now asks `PRC_VCSCAN` (the same console-attachment
scan `SYS_VCSTAT` reports, split out for this) and declines the switch
if that console has no shell. The scan is 47 PCB reads -- unaffordable
in the ISR, which is the whole reason this routine exists, and
perfectly affordable here in process context. `check-lazyvc` case 10
presses Option-3 on a console that was never created and asserts both
that the glass did not move AND that the console still responds
afterwards.

The original entry, retained for its reasoning:

The keyboard trigger -- Option (Closed Apple, `BUTN1`/`$C062`)
plus 1..4 -- **cannot be tested from the host**: verilogapple's
MCP server drives `btn_n` only inside its `reset` entry point,
for the ROM's cold-vs-warm check, and offers no way to hold a
button during normal running. Building it would ship a keyboard
path no gate can reach, and this project has already reverted one
feature (`PRC_VCTAB`) for being inert and unproven.

That is now a *convenience* gap rather than a functional one:
switching works and is gated; the keys are a second front-end
onto a mechanism that exists. The ask -- a button-hold next to the
`reset` one it already has -- belongs in verilogapple, which
another agent works.

**FILED 2026-08-31:**
https://forgejo.cornflower.au/mdj/verilogapple/issues/16 -- a
persistent `buttons` MCP tool (PB0/PB1/PB2 held until changed,
both tiers; the fast tier already answers $C061-$C063 from its
`button[3]` array, so only the setter is missing). PB2 is in the
ask on purpose: with the shift-key mod (X6 jumper -- Sather; the
mod is factory-standard on the Platinum IIe) $C063 reads the
SHIFT keys, so Shift-chord semantics need the same hold. The
Platinum default is SETTLED as of 2026-08-31 -- Apple's 1987 IIe
Technical Reference: "The extended keyboard IIe already has the
single-wire Shift-key mod hardwired on the logic board" (its OCR
is attached to the learning below; pre-Platinum boards ship X6 as
an open "broken diamond" you solder). Same manual, boxed warning:
with the mod in, a switch-2 hand control's button pressed
together with Shift SHORT-CIRCUITS the supply and powers the
machine off -- on a Platinum that is the out-of-the-box state, so
any future maux Shift-chord design inherits that hardware caveat.

**But PB2 = Shift is a PER-MACHINE fact, not a family one**
(operator caveat, verified against the IIc Technical Reference):
on the IIc there is no shift-key mod -- $C063 is the MOUSE BUTTON,
with bit 7 INVERTED (1 = not pressed) deliberately so shift-mod
probes false-positive at idle and the mouse button impersonates a
held Shift. Any maux design that reads $C063 as Shift must gate
on the machine being a modded IIe, never probe-and-assume.
Commons: `learning:01M1ASSB9VAYF685Z2E1NMHD3Q` (retitled to carry
the caveat; both verbatim quotes inside). When the tool lands,
the Option-1..4 trigger stops being blocked and this section's
gap closes.

### What shipped (2026-08-31): per-fd routing, the /dev names live

The step-1 ownership question answered itself as predicted: **the fd
is the console.** `PRC_READ`/`PRC_WRITE` now subtract `FD_DEV_BASE`
from the validated handle into `TTY_TARGET` instead of discarding it,
and `/DEV/TTY1..TTY4` are in `PDEV_TAB` -- **one-based**, as `chvt`
counts and as Linux names them; there is no `/DEV/TTY0` (the first
cut had one, and it produced exactly the off-by-one it invited:
`> /dev/tty2` wrote the third console while `chvt 2` displayed the
second).

* **Writes**: `TTY_WR_ENTER`/`TTY_WR_LEAVE` (tty.s) bracket
  `TTY_WRITE`. Active target: two compares, nothing else. Background
  target: the target's struct is swapped in and `TTY_DSTBASE` aims
  the renderer at its stored screen via `TTY_ROW_DST_A`/`TTY_STORE_Y`
  -- the glass is never touched. EVERY exit leaves the bracket, error
  paths included; a leaked `TTY_DSTBASE` sends every later write into
  the store and the glass just stops changing.
* **Scroll cannot use the redirect** -- it READS the rows it moves and
  RAMRD must never be toggled from $0200-$BFFF -- so a stored screen
  scrolls itself with BankCopy (`VCS_SCROLL`, tty4.s). The cursor is
  not painted on a background console for the same read reason.
* **Reads**: a background console's reader blocks IMMEDIATELY on
  `TTY_RD_CHAN + target` -- everything past that check reads
  `VC_STATE`, the ACTIVE console's struct, so running the buffered
  path from a background read would eat the foreground console's
  committed line (review finding 2). There is one keyboard and
  its bytes belong to the console on the glass; `TTY_WAKE_RDRS`
  wakes `TTY_RD_CHAN + VC_ACTIVE` (finding 3 -- the bare base channel
  would have left a `/dev/tty2` reader asleep forever), so a
  background reader wakes when its console is on the glass and a
  line completes -- and `VC_SWITCH`'s warm path re-wakes the channel
  when the loaded struct already holds a committed line or pending
  EOF, because a reader that re-blocked while its console was away
  would otherwise sleep beside ready data forever (2nd-pass finding
  6).
* **The bank goes home on every leave**: `TTY_WR_LEAVE` exits
  through `PRC_SEL_CRBNK`, because its `VC_SAVE/LOAD` BankCopies
  leave `$C073` wherever their last chunk ran and the ERROR exits
  return straight to `KRN_EXIT`'s no-switch path -- a bad-pointer
  write to a background console would have resumed its caller in
  the annex (2nd-pass finding 7).
* **A switch escape can now arrive THROUGH the redirect** -- `chvt 1`
  run while console 2 holds the glass writes `ESC [ 1 z` to fd 1 =
  console 1 = background -- and an inline `VC_SWITCH` there shreds
  both consoles' structs (seen as a glass full of garbage, not
  theorized). `TTY_CSI_VT` parks the switch in `VC_SW_PEND` and
  `TTY_WR_LEAVE` performs it after the structs are home.
* **Gated end to end** by check-play's virtual-console phase:
  `> /dev/tty2` stays off the glass (COUNTED -- teeth re-proven
  2026-08-31 against a discard sabotage), `chvt 2` brings the store
  to the glass, and `CHVT 2 ; SLEEP 2 ; CHVT 1` round-trips so the
  ^D-shutdown finale still runs. The phase must run BEFORE that
  finale -- its first cut sat after it, typing at a reaped shell,
  which was this branch's parked "no diagnosis" hang.
* **Not yet gated**: a background console's *read* path end to end --
  nothing runs a shell on console 2 yet, so no gate can type at one.
  The trigger is the second-shell/getty milestone.

### What this does NOT settle

Scrollback. A screen-image store gives none: it holds what is on the
console now, not what scrolled off. A byte-stream store would give
scrollback and cost an unbounded (so capped) buffer plus a replay
path through the renderer on switch. That is a bigger and different
feature, and it is not needed to make consoles work.

---

## 14. Multi-MODE consoles (2026-08-30)

Operator: *"I want consoles to be multi-mode. There is no reason
console 1 can't be displaying ultraterms 96x48 mode while console 2
has a BASIC program running in 40 col. Stock 80 col needs to be an
option too since ultraterm cards are like unicorn shit."*

This contradicts an assumption written into `tty.s` -- "NOT
per-console: TTY_COLS (backend width -- the display is a hardware
property until per-VC geometry exists) ... TTY_BKND (the active
backend)". Per-VC geometry is now wanted, so that parenthetical is
the thing to remove.

### The structural half is nearly free, and that is not obvious

`TTY_BKND` is defined at `tty.s:475` and `TTY_COLS` at
`process.s:252` -- **both OUTSIDE the `VC_STATE`..`VC_ST_END`
block**. Move them inside and they become per-console *with no
change to any read site*: `VC_SWITCH` already saves and loads the
whole struct, and all ~15 references name the live symbol, which is
whatever console is swapped in. Cost: two bytes per slot, eight
bytes of annex, and a `VC_ST_SIZE` bump the `err` guard checks.

That is the entire "each console has its own mode" data model.

### What is NOT free

1. **`VC_SWITCH` must reprogram the display**, not just swap state:
   UltraTerm CRTC registers (R1 horizontal displayed, R6 vertical
   displayed, R9 cell height) or the //e soft switches, to the
   incoming console's mode.
2. **The store (sec 13) is sized per console**, because geometries
   differ.
3. **A mode must be validated against detected hardware.** A console
   cannot select UltraTerm on a machine with no card, so mode
   selection needs a fallback -- and the fallback is `TTY_BKN8`,
   stock 80-column, which already exists. *The UltraTerm is the
   option; the built-in 80 columns are the baseline.*

### The geometry list, from the manual rather than memory

`learning:01M0J3M2B5DJJ4A3YVX7RNFK6N` carries the Videx UltraTerm
manual. It documents **seven** modes, quoted: *"160 characters by 24
lines and 80 characters by 48 lines"*, default 80x24 which is
**Videoterm emulation** (so a driver wanting the card's own
capabilities must leave it -- the `UT_VTEMU` latch bit). Tables show
80x24, 96x24, 128x_, 132x24, 160x24, 80x48.

**There is a 96x24 and an 80x48; there is no 96x48.** Worth pinning
before a store is sized for a mode that does not exist.

maux's driver does 80x24 HQ only today (`UT_MODE_HQ80`, `UT_COLS`
80) -- the other six are unimplemented.

### Cost at the widest geometry, measured

The widest documented modes are 160x24 and 80x48, both 3,840 cells.
Four consoles all at worst case is 15,360 B against `ANNEX_STRCT_C`'s
24,576 with 1,164 used -- about 23,400 free. **It fits even in the
pathological case**, so store sizing does not have to be clever.

One constraint that is NOT annex: **the UltraTerm's own VRAM is a
4 KB ring**, so 128x32 (4,096) consumes it exactly with nothing spare
for scroll. Mode choice budgets against VRAM as well as against the
annex.

### Which manual, and a hardware caveat that lands on this design

The geometry above is the ORIGINAL manual. There IS an addendum
(ULT-DOC-000, March 1985, `learning:01M0J3YRZ8A7Y9B4FMED3XFS58`) and
it was checked: it is a **hardware compatibility kit**, not a mode
revision -- firmware EPROM, a 251C PAL into socket U4, and a board mod
-- so the mode list is unrevised by it.

**But it matters here anyway.** An UltraTerm that never got that kit
is not enhanced-//e compatible, and the symptom is *interrupts*: the
//e vectors IRQs through `$C3FA`, so with the card in slot 3 the CPU
runs the card's ROM as its interrupt handler, and pre-update firmware
has no compatibility stub there. maux is an enhanced //e that takes a
timer tick in main context -- precisely the failure case. The card
displays text perfectly and only misbehaves once something takes
interrupts, which is why it gets reported as flaky rather than
broken.

The documented software mitigation, if the update is unavailable:
keep `SLOTC3ROM` **internal** except inside a short,
interrupt-disabled window around the `$C800` claim. The CRTC
registers are in slot I/O space (`$C0B0`-`$C0B2`) and need no slot
ROM at all, so only the claim needs the switch.

**And the mode table is graded `[observed]`, not `[fact]`** -- the
OCR of the manual's register tables is poor (column-aligned hex in a
scan). The 160x24 and 80x48 figures come from clean prose and are
`[fact]`; exact per-mode cell dimensions want a direct read of the
PDF pages before a driver is written against them.
