# ex design -- architect phase

Status: **IMPLEMENTED and shipped 2026-09-02** (`ex` is in Makefile UTILS,
9,439 B; `make check-all` green, 72/72). This document was the stage-1
architect deliverable; the sections below record the design as built. What
landed, in build order:

- **M1** swap-file buffer (`src/bin/exbuf.s`, forked from `edbuf.s`): line
  text lives in the disk swap file `EX.SWPxx`, only the 4-byte descriptor
  table is resident, so `ex` edits files larger than the process bank.
- **M2** tier-1 commands (`src/bin/excmd.s`): `q!`/`wq`/`x`, marks
  (`kx`/`'x`/`''`), `?re?` backward search, single-level `u`, `#`/`nu`
  (with `n` reserved for `next`), `e`/`e!`; the `j` accessor-contract fix.
- **A** interactive-tty gate (`make check-play` ex phase -- a real typed
  keyboard session, the `vi` on-ramp).
- **B** `ex FILE`/`ed FILE` filename-on-launch (shared `edparse.s START`).
- **C** the "last regular expression" -- `//`/`??`/`s//`/`g//` empty-pattern
  repeat (one shared `LASTPAT` + `ED_LASTRE`), improving `ed` too.
- **D** `g`/`v` widening -- mark-then-execute, runs any command (not just
  `{p,d}`), refuses `g`-in-`g`/`u`-in-`g`.
- **E** regex `\(...\)` grouping + `\1`-`\9` backreferences on the shared
  `src/liba/regex.s` (split into `regex.s`/`regex2.s`/`regex.equ` for the
  self-host window). ANACHRONISMS W5 CLOSED.
- **F** `w` truncation fix (`ED_DOWRITE` `SET_EOF`, shared `ed`+`ex`).

**Two self-host capacity rulings (2026-09-02)**, both because the feature +
test growth outran the native assembler/linker: `ed`/`ex` pinned **tier-2**
(no longer self-assemble, `check_librelas.py` `TIER2_BASELINE`), and the
`ed` test kernel **EDTEST** excluded from the self-host link sweep
(`build_librelas_image.py` `KLINK_SKIP`). Product features are unaffected.
(Both scripts were deleted 2026-10-18, RULINGS-1, with the gates they
served; the pins went with them.)

**Still open for the `vi` phase:** the raw/noecho tty ("stty seed") -- `ex`
is line-oriented and needs none, but `vi` blocks on it. Regex `magic`/
`nomagic` also deferred (needs `ex`'s `set`).

## Library notes

Per `HACKING.md`'s mandatory street-library loop, the following handles were
fetched and searched against before any design decision below. Each is
cited again inline at its point of use; listed here with the one-line
reason it matters to this task, per the task-authoring convention.

- `learning:01M0P08K94TE5DNQ0JWCG885WG` -- **[fact]** ProDOS MLI refuses to
  `OPEN` the same pathname twice concurrently (error $50, "file is open").
  Binds the swap file's naming scheme: it can never collide with a path the
  session might also open.
- `learning:01M18PZ6Q84NM0GVH7PBY9CK1W` -- `SET_EOF`/truncate-by-handle
  semantics and the character-device no-op case; informs how the swap file
  is created/truncated and confirms `SET_EOF` is a real, wired kernel call.
- `learning:01M1DG61015GY0BYXM99XQ1437` -- EDASM's measured MLI vocabulary,
  including its own `EDASM.SWAP` overlay's calls (`ON_LINE`, `SET_PREFIX`,
  `OPEN`x2, `READ`, `CLOSE`x2, `SET_MARK`) -- a period Apple II precedent for
  what an editor's swap mechanism actually calls.
- `learning:01M154VXS61SBQVMP8E1HQAQ1X` -- **[fact]** partial pathnames /
  `SET_PREFIX` save zero ProDOS block reads on 2.5; per-open directory
  walking is a floor the MLI cannot buy back. Rules out "clever prefix"
  micro-optimizations for the swap file's path.
- `learning:01M07G8WT2R3G2P87EK1DNPVYP` (and the EDASM manual's matching
  "BAD PATH/FILE NAME" text, artifact `8588fd45...`) -- **[fact]** ProDOS
  pathname components are letters/digits/periods only, <=15 characters.
  Binds the swap filename's alphabet and length.
- Artifact `93e04c707fdd48a095b0055d46996daa005aad427f558ee92a9d4241ae01f9b8`
  (*UNIX Programmer's Manual, Seventh Edition*, Vol. 1) -- **[fact]**, primary
  source: "`Ed` operates on a copy of any file it is editing... The copy of
  the text being edited resides in a temporary file called the buffer,"
  plus ed's own `DIAGNOSTICS`: `?name` for an inaccessible file, `?` for
  command errors, **`?TMP` for temporary file overflow**. This is the
  historical precedent the swap design generalizes, and its distinct
  "temp file" error class is worth keeping.
- Artifact `d82965d865557730323115a79ec150c5449f13a335c258273dcb0171fa692ff8`
  (*Apple ProDOS 8 Technical Reference Manual*) -- **[fact]**: `OPEN`'s
  page-aligned 1024-byte `io_buffer` requirement (TRM 4.5.1); `SET_MARK`/
  `GET_MARK`/`SET_EOF`/`GET_EOF` semantics (TRM 2.1.5); tree-file growth via
  a master index block + up to 128 index blocks x 256 data blocks (TRM
  B.3.1) -- the mechanics behind the swap file's effective ceiling.
- `learning:01M197TY462D8ZRJHSQ77FGWK9` -- a `.SYSTEM` program's real size
  ceiling is whatever it allocates above itself; io_buffers belong at the
  floor of the free region. Cautionary for wherever `ex`'s own resident
  read buffer for the swap fd is declared.
- No V7/BSD `ex(1)`/`vi(1)` manual or Bill-Joy/2BSD history document was
  found in the commons after several phrasings ("V7 ex vi manual",
  "ex editor swap file", "vi visual mode screen editor", "Bill Joy Berkeley
  2BSD 3BSD ex vi history"), run 2026-09-02 -- recorded as a dated, falsifiable
  negative per the street-library skill's rule 2a, not as "the library has
  nothing." `ex`/`vi` are BSD (Bill Joy, 2BSD/3BSD, ~1978) inventions,
  contemporaneous with V7 but never part of AT&T's V7 distribution -- the
  commons' V7 manual (which IS present and cited above for `ed`) would not
  carry them even if fully indexed. sec 3's command inventory is therefore
  graded **[reported]** (established POSIX/historical knowledge, not
  verified against a primary source the commons holds) unless stated
  otherwise, and this gap is itself worth a deposit once the primary source
  is found (see closing note).

## 1. Current `ed`, read in full

Every file in the put-chain was read in full:
`src/bin/ed.s` (manifest + ZP map + heap trailer), `edparse.s` (entry,
parsing, search), `edbuf.s` (line-table primitives, `a`/`i`/`c` shared text
entry, delete, move), `edfile.s` (command dispatch for `a i c d p n q`,
filename remembering), `edfil2.s` (`r`/`w`), `edsubst.s` (`s` and the
substitute engine), `edsub2.s` (`g`, `m`, `t`, `j`, `=`). Also read:
`src/liba/regex.s` (the shared BRE matcher), `src/liba/seek.s` (`LSEEK`),
`inc/sc.file.equ` (MLI call numbers), and the kernel's fd/OFT/
io_buffer pool sizing (`inc/mm.annex2.equ`,
`inc/mm.mlibuf.equ`).

### 1.1 Line storage model -- today

- **Line table**: `ED_LINES`, `MAXLINES=1024` slots x 2 bytes, slot `n`
  holds a 16-bit pointer into the text arena for line `n` (slot 0 unused,
  lines numbered 1..`ED_NLINES`). `ED_LTSLOT`/`ED_GETSLOT`/`ED_SETSLOT`
  (`edbuf.s:27-67`) are the only accessors.
- **Text arena**: a **monotonic bump allocator**, not `ds`-reserved in the
  image any more. `ED_HEAP` is a `dum` label (`ed.s:317-325`); at startup
  `START` calls `SC_BRK`/`SC_SBRK` to establish the break at `ED_HEAP`
  (`edparse.s:17-56`), and `ED_ROOM` (`edbuf.s:84-126`) grows it in
  `ED_GROW_SZ=$1000` steps via `sbrk()` as text arrives, up to the kernel's
  hard ceiling `PRC_BRK_LIM=$BF00`. **Every write goes through
  `ED_BUMP_ALLOC` or `ED_JPUTBYTE`; nothing is ever mutated in place**
  (`ed.s:233-243`'s own comment states this as the reason the heap is left
  uncleared and is safe that way). A rewritten line (`s`, `r`-inserted
  text, `a`/`i`/`c`, `j`) always allocates a **fresh** buffer and repoints
  only that one line-table slot -- the old bytes become dead, unreachable,
  and are **never reclaimed** (no compaction exists anywhere in this file
  set). `t`/`m` exploit the same invariant deliberately: a `t`-copied line
  shares its text pointer with the original rather than duplicating bytes
  (`edsub2.s:187-195`'s own comment).
- **Hard limits, verified against source, not inferred**:
  - `MAXLINES=1024` (`ed.s:140`) -- a hard line-count ceiling; `ED_INSRT_AFTR`
    refuses past it (`edbuf.s:174-178`).
  - Process bank window: `LOAD_BASE=$0800` (`inc/mm.procbank.equ:20`)
    to `PRC_BRK_LIM=BF00_OVERLAY=$BF00`
    (`inc/mm.procbnk2.equ:137-153`) -- **46,848 bytes total** for
    code + fixed buffers + the entire growable heap. This is the ceiling
    `ED_ROOM` grows against and the one `ed: no heap` (`ED_NOHEAPMSG`,
    `edsub2.s:484-485`) reports when exhausted.
  - **Measured today** (`build/ed.bin`, this session): **6,461 bytes.**
    This corrects `docs/IDE.md` sec 3's "`ed` is already at 98.2% of a bank"
    (46,005 B, measured 2026-08-20): that figure predates the very
    `sbrk()`-growable-heap rewrite whose own header comment is dated the
    same day and describes replacing a `ds TEXTBUF_SIZE` (~36-37 KB)
    *emitted into the image* with the runtime-growable heap above. sec 2.4
    below returns to what this means for `ex`'s code budget.
  - Per-line length: `CMDBUF_MAXLEN=250` (`ed.s:142`) governs every line
    read from a command, a file (`r`), or terminal input (`a`/`i`/`c`) --
    `ED_RDCMDLINE`/`ED_RDFILELINE` both truncate at `CMDBUF_MAXLEN-1`
    (`edparse.s:202-206`, `edfil2.s:36-40`). `PATBUF_MAXLEN`/
    `REPLBUF_MAXLN` are also 250; `SUBSCR_MAXLEN=512` (room for a heavily
    `g`-flagged substitution to outgrow the original line).
  - **No compaction** means edit-heavy sessions leak arena space
    monotonically even though the line COUNT may be small -- a long `s///g`
    session over the same file can exhaust the 46 KB heap well before 1024
    lines are ever reached. This is the second, less obvious limit the
    operator's "unbounded file lengths" ask must also address, and the
    swap design in sec 2 inherits (does not fix) this leak-on-edit shape --
    see sec 2.6.

### 1.2 Command set -- today

From `ed.s`'s own header and `edparse.s`'s dispatch (`MAINLOOP`,
lines 92-146): `a c d i p n q r w s g m t j =`. A bare address with no verb
implies `p` (classic `ed`, `edparse.s:148-153`). Every command's own
0/1/2-address default and range-validity rule is implemented per-command
(`ED_DFLT_DTDT`, `ED_CHC_RNG12N`, `ED_CHECK0N`, `edfile.s:1-70`) -- this is
the precedent sec 3 leans on for "ed already has this, ex inherits it
unchanged."

### 1.3 Addressing

`ED_PARSEADDR`/`ED_PARSE1ADDR` (`edparse.s:243-390`) implement: `.` (current
line), `$` (last line), a decimal literal, `/re/` (forward search,
**wrapping** through line 1 back to `.` -- `ED_SEARCHFWD`, `edparse.s:454-583`
-- note for sec 3: `ex`'s default `wrapscan` behavior is already this, for
free), and `addr1,addr2` ranges. Bare `,` (=> `1,$`) and bare `;` (=> `.,$`)
are accepted; a **partially**-bare range (`,5` or `1,`) is explicitly NOT
supported (`edparse.s:250-257`, `docs/a2/B.ED.TXT`). No `?re?` backward
search, no marks (`'x`), no address arithmetic (`.+3`, `$-1`) beyond what
`j`'s own default (`.,.+1`, computed in code, not parsed) already needs.
These are real, load-bearing `ex` additions -- see sec 3.

### 1.4 The substitute engine

`edsubst.s`/`edsub2.s` implement `s/re/repl/[g][p][N]` (mutually exclusive
`g`/`N`, `edsubst.s:377-381`), `&` and `\X` in the replacement
(`ED_SBXPND_RPL`, `edsubst.s:106-163`), and (2026-09-02, sec 3.2's own
tier-2 item, now landed) `g/re/cmds` / `v/re/cmds` where `cmds` may be
ANY addressable command, not just the old `{p, d}` v1 scope cut --
`edsub2.s`'s `ED_CMD_G`/`ED_CMD_V` run a real two-pass mark set
(`ED_GMARKS`, shift-adjusted by `ED_GMARK_INS`/`ED_GMARK_DEL` at the
same `ED_INSRT_AFTR`/`ED_DLT_RANGE` hook points `EX_MARK_INS`/
`EX_MARK_DEL` already use for `'x` marks), not the old single left-
to-right scan. `g`/`v`/`u` inside `cmds` are refused with `?` before
any mutation, per the primary source's own restriction.

The matcher is `src/liba/regex.s`'s Thompson-subset BRE (shared with
`grep`/`sed`): literals, `.`, `[...]` with negation/ranges, `*`, `\`-escape,
`^`/`$` anchors. **No grouping, no backreferences, no intervals**
(`docs/ANACHRONISMS.md` sec W5 -- the "V6-complete, one V7 feature short"
finding, itself already measured against source rather than inferred).
`ex` does not change this: it calls `RE_MATCH` exactly as `ed` does, and
inherits the same, already-documented gap.

### 1.5 File I/O via MLI

All of `inc/sc.file.equ`'s numbers are REAL, verbatim ProDOS MLI
call numbers, routed through `P8_DELEGATE` at the kernel dispatch level --
**verified present** in this pass: `SYS_CREAT=$C0`, `SYS_UNLINK=$C1`,
`SYS_RENAME=$C2` (same-directory only -- its own comment says so,
`sc.file.equ:33`), `SYS_SFI=$C3`, `SYS_GFI=$C4`, `SYS_SETPFX=$C6`,
`SYS_GETPFX=$C7`, `SYS_OPEN=$C8`, `SYS_READ=$CA`, `SYS_WRITE=$CB`,
`SYS_CLOSE=$CC`, `SYS_SET_MARK=$CE`, `SYS_GET_MARK=$CF`, `SYS_SET_EOF=$D0`,
`SYS_GET_EOF=$D1`. `ed`'s own `r`/`w` (`edfil2.s`) use `OPEN`/`READ`/
`WRITE`/`CLOSE`/`CREATE` directly with hand-built parmlists; **`ed` never
calls the seek family at all today** -- no `SET_MARK`/`GET_MARK` anywhere
in the put-chain. `ex`'s swap buffer is the first consumer of `liba`'s
`LSEEK` (`src/liba/seek.s`) inside the editor family.

`LSEEK(fd, offset, whence)` (`seek.s:36-119`) composes `GET_MARK`+
`SET_MARK` (`SEEK_CUR`), `GET_EOF`+`SET_MARK` (`SEEK_END`), or a bare
`SET_MARK` (`SEEK_SET`) -- offset is a **3-byte little-endian** value (16 MB
address space, V7's `lseek` shape per `docs/ANACHRONISMS.md` A1, not V6's
16-bit `seek`). `SEEK_SET` is exactly what sec 2 needs: an absolute,
non-negative 3-byte target, which is all a swap-file line offset ever is.

### 1.6 Kernel resource ceilings that bind the swap design

Verified in `inc/mm.annex2.equ`, `inc/mm.mlibuf.equ`:

| resource | limit | scope |
|---|---|---|
| fds per process | `PCB_FDTABLE=8` | per-process |
| open-file-table entries | `OFT_COUNT=16` | **system-wide** |
| MLI `io_buffer`s (1024B, page-aligned, TRM 4.5.1) | `MLI_IOBUF_CNT=6` | **system-wide**, live for the file's entire open lifetime |

**2026-09-07: the pool is 8 and the kernel LENDS** (docs/IOBUF-LENDING.md):
an exhausted pool parks the least-recently-used open file and reopens it at
its saved mark on the next use. The held swap fd is therefore no longer a
slot permanently taken from the machine, only a file that may be parked
while a spawned child runs -- which is exactly what `EX_BG_SWCLOSE` /
`EX_BG_SWOPEN` used to do by hand, and why they were retired. The
paragraphs below describe the world as it was when the design was made.

A `MLI_IOBUF_CNT` slot is occupied for as long as a file stays open, not
just per-call (`mm.mlibuf.equ:16-22`) -- so an `ex` session that keeps
its swap file open for the whole editing session permanently consumes
**one of six** system-wide slots. That is affordable (sec 2.3) but not free,
and is the reason sec 2 designs for the swap fd to be opened once at session
start and held, not opened/closed per operation.

## 2. The swap-file buffer design

### 2.1 Historical precedent, and why it maps directly onto what's here already

Classic `ed`'s buffer literally **is** a temporary disk file: a table of
line pointers (in core) into an append-only scratch file, never rewritten
in place, growing at the end as text is added
(`UNIX_Programmers_Manual...` **[fact]**, quoted in the library notes
above). `ed`'s own `DIAGNOSTICS` gives temp-file exhaustion its own error
class, `?TMP`, distinct from `?` -- worth carrying forward (sec 2.7).

**maux's `ed` already has this shape, just entirely in RAM**: a line-table
of pointers, a monotonic bump-append arena, no in-place mutation, no
compaction, `t`/`m` sharing pointers rather than duplicating bytes (sec 1.1).
Porting to a disk-backed swap file is therefore not a redesign -- it is
**relocating one arena and widening one pointer field**: the arena moves
from a process-bank heap address (2 bytes) to a swap-file byte offset
(3 bytes, matching ProDOS's own mark width), and every `ED_BUMP_ALLOC`
call becomes a `SET_MARK`+`WRITE` pair at the swap fd's current end.
Everything else -- the line-table shift-on-insert (`ED_INSRT_AFTR`), the
shift-on-delete (`ED_DLT_RANGE`), `t`/`m`'s pointer-sharing trick -- carries
over **unchanged in shape**, just operating on {offset, length} descriptors
instead of raw pointers.

**Period Apple II precedent, read but not directly load-bearing**: EDASM's
`SWAP` command (`EDASM-ProDOS_Assembler_Tools_Manual_text.pdf`, chunk 164,
and `learning:01M1DG61015GY0BYXM99XQ1437`'s measured MLI trace of the
`EDASM.SWAP` overlay) "splits the current text buffer, remembering the
current pathname and file size" to hold **two files in RAM at once** -- a
memory-partitioning trick, not a disk-backed unbounded buffer (`EDASM.SWAP`
issues `OPEN`x2/`READ`/`CLOSE`x2/`SET_MARK` -- consistent with paging a
*second* in-RAM buffer's worth of a file to/from disk, not with treating
disk as the primary store). Recorded because it is the actual thing
Apple II software of this era called "swap," and confirms `ON_LINE`/
`OPEN`/`READ`/`CLOSE`/`SET_MARK` is exactly the working MLI vocabulary a
period editor used for buffer overflow -- but it answers a different
problem (two files, bounded by RAM) than the operator's ask (one file,
unbounded by RAM). **[observed, not load-bearing]**.

### 2.2 Design decisions, concretely

**Line descriptor**: `{offset: 3 bytes, length: 1 byte}` = **4 bytes per
line**, replacing today's 2-byte RAM pointer. The 1-byte length field
caps a single stored line at 254 bytes (same "stops growing past 254"
convention `ED_SUBPUTCHAR` already uses, `edsubst.s:64-70`) -- this is not a
new limitation, it is the **existing** `CMDBUF_MAXLEN=250` ceiling that
already governs every line `ed` reads from a file or a terminal;
extending it to `j`'s synthesized joined lines (sec 2.5) keeps one ceiling
system-wide instead of introducing a second, larger one for one command.

**Line table becomes growable, not fixed at 1024**: today's `ED_LINES` is
a flat `ds LINETBL_SIZE` array sized for `MAXLINES=1024`. With the text
arena off the process bank entirely, the descriptor table is the **one**
thing that must still live in the 46,848-byte window -- so let it consume
whatever RAM code+scratch buffers don't need, via the *same* `sbrk()`/
`ED_ROOM`-style monotonic growth `ed` already uses for its text arena
today (sec 1.1), reused rather than reinvented (`t[n]` addresses as
`base + n*4`, an `asl`/`rol` pair twice instead of once -- mechanically the
same as today's `ED_LTSLOT`). This directly answers "unbounded line
COUNT" the same way the swap file answers "unbounded byte count": both
grow until the resource genuinely backing them (disk, or process-bank
RAM) runs out, not until a hand-picked constant does. Sizing guidance,
not a hard pin (see sec 2.4's own caution about hand-tuned constants going
stale): budget code + fixed buffers first, give everything else to the
table; at 4 bytes/line, each spare 4 KB of RAM buys 1,024 more resident
lines.

**Swap file location and naming**: the swap file lives in the **process's
current working directory at session start**, named deterministically
from the process's own bank identity -- `EX.SWPxx`, where `xx` is 2 hex
digits of `BANK_ID` (`$FF2E`, the same per-bank byte `sh.s` reads for `$$`,
`sh.s:12`). This is 8 characters, well inside ProDOS's 15-character
component limit **[fact]**, and -- because `BANK_ID` is unique across every
*live* process -- it is collision-free across concurrently running `ex`
sessions **without needing a registry, a source-filename derivation, or a
getpid() syscall** (none exists yet; `BANK_ID` already serves that role
for `sh`). Two design facts rule out the alternatives:

- **Deriving the swap name from the file being edited** (a la vi's
  `.foo.txt.swp`) was considered and rejected: `SYS_RENAME` is
  **same-directory only** (`sc.file.equ:33`, **[fact]**), so a swap
  file created before any filename is known (bare `ex`, or `a`/`i` before
  any `w`) could never be *moved* next to a file named later without a
  full copy-and-delete. Anchoring to cwd instead means the swap file never
  needs to move.
- **A fixed, undifferentiated name** (`EX.SWAP`) was rejected because
  maux has multiple virtual consoles and background jobs (`docs/CONSOLE.md`,
  `docs/ANACHRONISMS.md` W4) -- two `ex` sessions started from two consoles
  `cd`'d to the same directory, editing two different files, is an
  ordinary workflow, not an edge case, and would collide immediately on a
  bare fixed name. It would ALSO collide with the "can't open the same
  path twice" MLI refusal (`learning:01M0P08K94TE5DNQ0JWCG885WG`,
  **[fact]**) the instant the second session tried to create it.

Swap-file creation is attempted **eagerly at session start** (one code
path, matching the "no-surprises" instruction over a lazy-create special
case): `CREATE` (ignore "already exists"), `OPEN`. On failure -- an
unwritable cwd, most likely -- `ex` reports a **distinct, louder-than-`?`**
message and exits, the same posture `ed` already takes for a refused
`brk()` (`ED_NOHEAPMSG`, "ed: no heap", `edsub2.s:480-485`) and the
precedent the V7 `ed` DIAGNOSTICS class `?TMP` sets (sec 2.7). The swap fd is
opened once and held for the whole session -- consuming one of the six
system-wide `MLI_IOBUF_CNT` slots (sec 1.6) for the session's duration, which
is affordable (five remain for everything else machine-wide) and avoids
the `OPEN`/`CLOSE` cost on every command.

**On-disk format**: each stored line is its raw bytes followed by one
plain `$8D` CR -- **byte-identical to what `w` already writes**
(`WCRBYTE dfb $8D`, `edfil2.s:286`). This buys two things for free: (1) a
crash-abandoned swap file is still a legal ProDOS text file a human could
`cat`/salvage by hand (not a supported recovery feature -- sec 2.7 says why
explicitly) and (2) loading a file **streams straight through**: read the
source in chunks, split on CR exactly as `ED_RDFILELINE` already does
(`edfil2.s:13-40`), but instead of `ED_BUMP_ALLOC`-ing into RAM, `WRITE`
each line + CR to the swap file's current end and record `{offset, len}` --
a mechanical redirect of an already-proven loop, not new logic.

### 2.3 Mutation without rewriting the whole file

Every `ed`/`ex` command falls into exactly one of two shapes, and the
split is the reason this design stays cheap on the hottest paths:

- **Table-only** (no swap-file I/O at all): `d` (delete -- shrink the
  table, sec 1.1's `ED_DLT_RANGE` shape, dead bytes left behind exactly as
  today), `m` (move -- delete+reinsert *descriptors*, `ED_DOMOVE`'s
  existing shape, `edbuf.s:372-456`), `t`/`co` (copy -- **share** the same
  `{offset,len}` descriptor across two table slots, exactly
  `edsub2.s:187-195`'s existing comment, now literal disk-byte sharing
  instead of RAM-pointer sharing). Printing, searching and addressing
  read descriptors and then fetch text (below) but never write.
- **Append-and-repoint** (one `SET_MARK`+`WRITE` sequence at the swap
  file's current end, then one table-slot repoint): `a`/`i`/`c` (new
  text from the terminal), `r` (new text from another file), `s` (the
  rewritten line -- built in a resident scratch buffer exactly as
  `ED_DO_SUBST` already builds it in `SUBSCR` today, then appended once).

So only commands that **create new text** ever write to the swap file --
navigation, printing, deleting, moving and copying are descriptor-table
edits, which is exactly why they stay cheap regardless of file size.

**Reading one line** (`p`, `n`, `s`'s per-line scan, `g`'s scan, `w`): fetch
its descriptor, `SET_MARK` the swap fd to `offset`, `READ len` bytes into
a single resident **`LINEBUF`** (250 bytes, sized like `CMDBUF`/`R_RDBUF`
today -- no larger resident buffer is needed because no `ed`/`ex` tier-1
command holds two lines' raw text live at once; `j`'s merge streams,
sec 2.5). This is deliberately **not** a multi-line LRU cache for v1: no
measurement yet exists to justify one (the same "don't hand-tune against
a constant nobody has profiled" lesson `ED_GROW_SZ`'s own header already
records, sec 2.4), and ProDOS's own `io_buffer` already keeps the *current*
data block resident between calls for free (`mm.mlibuf.equ`'s own
comment). The one cache-shaped optimization included, because it is free
and covers the realistic common case: **track the swap fd's last-known
mark**, and skip the `SET_MARK` call when the next descriptor's `offset`
already equals it. A freshly loaded, unedited file is written and later
read back in strictly ascending offset order -- the whole-file scan that
`,p`, `/re/`, and `s///g` most commonly run -- so this turns the common
case into exactly one MLI call per line (`READ` alone) instead of two,
with zero risk of being wrong (worst case: one harmless extra `SET_MARK`)
on a file whose edit history has scrambled offset order relative to line
order.

**`w` (write)**: for each line in range, fetch its descriptor (as above:
`SET_MARK`+`READ` from the swap fd into `LINEBUF`), then `WRITE` the
content and a CR to the **target** fd -- the same two-`WRITE` shape
`ED_CMD_W` already uses (`edfil2.s:202-228`), with the swap-fetch prepended.
This is an honest, named cost: `w` goes from 2 MLI calls/line today (direct
RAM read, `WRITE`+`WRITE`) to up to 4 (`SET_MARK`+`READ`+`WRITE`+`WRITE`),
mitigated by the same offset-tracking trick above for the common
load-edit-save workflow.

### 2.4 What this does and does not fix in the code-size budget

`docs/IDE.md` sec 3 ("`ed` is already at 98.2% of a bank") is **stale as
measured**: `build/ed.bin` is 6,461 bytes today (checked this session),
not 46,005. The crisis IDE.md profiled and the `sbrk()`-growable-heap
rewrite that fixed it landed the same day (2026-08-20) -- the arena that
used to be `ds`-emitted into the image is now a runtime heap outside it,
already. **This should be corrected in IDE.md** when this document lands
(a stale-comment class already named in the operator's own memory: "a
`ds`-emitted arena number that used to be re-derived by hand" -- precisely
this file's own header explains the same rewrite).

What that means for `ex`: the swap-file design is the right answer to the
operator's stated headline requirement (files larger than a bank), and it
*also* means the descriptor table (sec 2.2) never needs to be anywhere near
the old 36-37 KB arena's size -- but it is **not**, by itself, the fix for
"`ex`'s bigger command set fits in the image." That is IDE.md's Routes 1
(code into process LC, the technique `as.s`/`ld.s` already use) and 2
(link, don't embed, via `ld`/REL modules) -- both still apply, independent
of this document, and should be sized against `ex`'s actual code once
written rather than estimated here. With ~40 KB of headroom available in
the static image alone (46,848 - 6,461 measured today) before touching
the heap at all, `ex`'s larger command set has considerably more room to
grow than IDE.md's stale crisis implied -- but "considerably more room"
is not "unlimited," and Routes 1/2 remain the lever once real numbers
exist.

### 2.5 `j` (join) under the swap design

`j`'s existing semantics (`edsub2.s:296-420`) synthesize ONE new line from
N source lines with no separator, streamed byte-by-byte via
`ED_JPUTBYTE`. Under the swap design this becomes: `SET_MARK` the swap
fd once to its current end, then for each source line `SET_MARK`+`READ`
its bytes into `LINEBUF` and `WRITE` them onward (the mark auto-advances
across sequential `WRITE`s, so no re-`SET_MARK` on the destination side
between lines) -- the same shape as loading a file (sec 2.2), reusing
`LINEBUF` rather than needing a second scratch buffer. The one behavior
change from today: the synthesized line is now subject to the same
254-byte ceiling every OTHER stored line already carries (sec 2.2) -- today's
RAM-arena `j` has no such cap (bounded only by total heap). This is a
**deliberate, named v1 scope decision**: keep one line-length ceiling
system-wide rather than widen the descriptor to a 2-byte length field for
one command's edge case. A join that would exceed it is refused with `?`,
matching `ed`'s existing error vocabulary.

### 2.6 What this design does NOT fix

The **no-compaction leak** (sec 1.1) carries over unchanged: an edit-heavy
session (repeated `s///g` over the same lines) still accumulates dead
bytes monotonically, now in the swap FILE instead of the RAM heap. This
is strictly better than today (the file, unlike the 46 KB bank, is bounded
only by the ~16 MB ProDOS tree-file ceiling and free disk space -- TRM
B.3.1, **[fact]**) but it is not truly unbounded either, and a
session that edits the same region thousands of times will eventually
hit disk space or the file's own header structures before hitting the
old RAM ceiling. Not a v1 blocker (real `ed`/`ex` accept the same
tradeoff), but worth a named trigger for later: if a compaction pass is
ever wanted, it is a straightforward walk-the-table-in-offset-order
rewrite, unblocked by anything in this design.

### 2.7 Crash behavior and cleanup -- explicitly scoped

On a clean `w`+`q`/`x`/`q!`, `SYS_UNLINK` the swap file as the final act,
mirroring real `ex`'s clean-exit removal. **Crash recovery from the swap
file is explicitly NOT a v1 goal**: the descriptor table (line order)
lives only in RAM, so a crash leaves a valid-but-unordered ProDOS text
file behind (sec 2.2's "salvageable by hand," not "recoverable by `ex`").
Real `vi -r`-style recovery would need enough metadata written INTO the
swap file to reconstruct the table, which is real, scoped, later work,
not assumed here.

Adopting the V7 `ed` DIAGNOSTICS precedent (sec 2.1, **[fact]**): `ex` should
give swap-file I/O failures (create-fails-on-startup, a `WRITE`/`READ`
failure against the swap fd mid-session -- e.g. the volume filled) their
**own** distinct message class, not the bare `?` ed already overloads for
every syntax and range error. `ed`'s own louder-than-`?` precedent
(`ED_NOHEAPMSG`, "ed: no heap") is the shape to copy, not invent.

## 3. Hottest-paths command prioritization

**Grading note -- UPGRADED 2026-09-02 to [fact]**: the *Ex Reference
Manual, Version 1.1* (William N. Joy, UC Berkeley, Nov 1977) is now in
the commons (`learning:01M1FX8HT89CKR9CB8T8VKCW1S`, artifact
`023c804b644ace0079dc047f9d40d26c10c69cde11064cfdd8f48b4a1b204b34`),
fetched from archive.org per HACKING.md's notebook rules. The tables below are
cross-checked against it, and TWO corrections it forced are marked
inline. Note that v1.1 is the 1977 Berkeley source: `wq`/`x`/`xit` are
NOT in it (later BSD/POSIX additions -- flagged, not assumed), `%` is
filename-only (not a `1,$` range), and the wrap option is spelled
`wrap` there, `wrapscan` in later ex.

### 3.1 Tier 1 -- can't-live-without

| command | syntax | ed has it? | no-surprises behavior |
|---|---|---|---|
| print | `[range]p` | **yes** (`ED_CMD_P`) | unchanged |
| number | `[range]#` (and `[range]nu`/`number`) | `#` new; `nu` new | **CORRECTED against the primary source (v1.1)**: in real `ex`, `n` is `next` (edit the next file in the arg list), NOT numbered-print -- it COLLIDES with `ed`'s `n`. Numbered print is `#` or `number`/`nu` only. maux must NOT carry `ed`'s `n` forward as ex's `n`; wire `#`/`nu` for numbered print and reserve `n` for `next` (tier 3, multi-file) |
| next | `n`/`next` | **new** | edit the next file in the argument list -- the real meaning of ex's `n`. Needs a multi-file arg list (tier 3), so `n` is DEFERRED with `next`; do not bind `n` to anything else in the meantime |
| substitute | `s/re/repl/[g][p][N]` | **yes** (`ED_CMD_S`) | unchanged; `&`/`\1`-style group refs stay unavailable -- regex engine gap, not an `ex` gap (sec 1.4) |
| write | `[range]w [file]` | `w` yes | unchanged. `wq` and `x`/`xit` (write-then-quit) are NOT in the v1.1 primary source -- later BSD/POSIX additions. Ship them (they compose `w`+`q`, no new I/O path, and every modern hand types `:wq`/`:x`) but grade them [reported]/A12-modern, not [fact], and note the divergence from the 1977 source |
| quit | `q`, `q!` | `q` yes; `q!` new | `q!` skips the "buffer modified" check sec 3.3 adds |
| append/insert/change | `a`, `i`, `c` | **yes** (all three) | unchanged -- `ED_TEXTENTRY`'s shared reader carries over verbatim |
| delete | `[range]d` | **yes** (`ED_CMD_D`) | unchanged |
| move/copy | `m`, `t`/`co` | **yes** (both) | `co` ships as a second spelling of `t` -- same handler, zero new logic |
| addressing | `.` `$` `N` `/re/` `?re?` ranges marks | `.`/`$`/`N`/`/re/`/ranges yes; `?re?`, marks **new** | `?re?` is backward search -- mirror `ED_SEARCHFWD`'s wrap logic in reverse; marks (`'x`/`kx`) are new state: a small `[26]` byte table of line numbers, set/cleared like `ED_CURLINE`. NOTE per v1.1: `%` is NOT a `1,$` range in the 1977 source (it is filename-only) -- `%` as `1,$` is a later convention. Ship `%`=`1,$` as A12-modern (universal today) but do not cite it to the primary source |
| undo | `u` | **new** | single-level (pre-command snapshot), not multi-level -- see sec 3.3's A12 divergence note |
| read/edit a file | `r [file]`, `e file` | `r` yes; `e` **new** | `e` replaces the whole buffer/descriptor table with a freshly loaded file -- same load path sec 2.2 already designs for `r`, just preceded by "discard current table" (with the same "buffer modified" guard as `q`) |

### 3.2 Tier 2

`g/re/cmd` / `v/re/cmd` (**have**, 2026-09-02 -- verb widened from
`{p,d}` to any addressable command via a real two-pass mark set,
`edsub2.s`'s `ED_CMD_G`/`ED_CMD_V`; `v` is the global-inverse, same
scan, inverted match test), `j` (**have**, sec 2.5's cost note applies),
`=` (**have**), `f`/`file`
(show/set the remembered filename -- `ed` already tracks
`ED_CURFNAME`/`ED_HAS_FNAME` internally, sec 1.2, but has no command to
*display* it; cheap, new), `k`/`'` (marks -- bundled with tier 1's
addressing since `'x` is meaningless without `k` to set it), `l` (list --
show tabs/nonprinting bytes unambiguously, useful once files can be
arbitrarily large and "what's actually in this line" stops being
obvious), `set` (a small options table: `wrap` (v1.1's spelling; `wrapscan` in later ex -- accept both) --
already the default, sec 1.3, exposing the existing behavior as a toggle;
`number`/`nu` -- default the `p` display to numbered; `ignorecase` -- new
regex-engine-adjacent flag, out of `regex.s`'s current scope, so `set ic`
should be refused rather than silently ignored until the engine supports
it).

### 3.3 Tier 3

`!cmd` (shell filter -- plausible now that `spawn()`+pipes+`fork()` have
landed, per `docs/ARCHITECTURE.md`'s process-model section, but real work:
needs a child spawned with stdin/stdout redirected to the addressed
range, not a v1 headline item), `:r !cmd` (read a command's output into
the buffer -- composes `!cmd` once it exists), `z` (scroll-window print --
low value in a system with `more` already shipped, `docs/FLEET.md`),
`map`/`ab`/`unmap`/`unab` (key mapping/abbreviation -- **defer to `vi`
entirely**, meaningless in a line editor with no character-level input
loop), `:next`/`:args` (multi-file argument lists -- real, but not
"hottest path"), tags (`:ta`) -- no ctags-equivalent exists yet, out of
scope until one does.

### 3.4 V7-vs-modern divergences (A12 discipline)

Per `docs/ANACHRONISMS.md` A12: ship the modern-canonical spelling where
eras diverge, note the older form beside it. Proposed entries, in the
same table shape A12 already uses, for folding into that register when
this work starts:

| `ex` ships | historical form | note |
|---|---|---|
| `#` and `n` both print numbered | `ex`'s own `#`; `ed`'s `n` | both cost nothing extra -- `n` already exists, `#` is the addition |
| `wq` and `x`/`xit` both | both existed in historical `ex` too | no real divergence; listed for completeness |
| single-level `u` (toggle) | matches historical `ex`/`vi`, **not** modern `vim`'s multi-level undo | **kept old-form, against A12's usual default** -- test 1 (does the old constraint still apply?) says yes: a full undo log is a real RAM/disk cost on a 46 KB-bank, 1 MHz machine, and test 3 (does the hardware make something different cheap?) says no, it makes history strictly more expensive. Flagged exactly as A12 asks: divergence named, reason stated, and here the reason favors the *older* form |
| `wrapscan` on by default | matches historical `ex` default | already `ed`'s existing behavior (sec 1.3), carried forward as a documented default rather than a new decision |
| `autoindent`/`ai` | vi/insert-mode feature | **deferred to the `vi` phase** -- meaningless in `ex`'s read-a-line-verbatim text entry (`a`/`i`/`c` read raw lines exactly as `ed` does today); would be dead code if built now |

## 4. The `vi` sightline

Not a `vi` design -- the point of this section is that stage-1 `ex`
decisions above do not foreclose it, and to name `vi`'s real
prerequisites so they are costed before hit, matching `docs/IDE.md`'s own
framing.

- **The line buffer already serves `vi` unchanged.** Nothing in sec 2 is
  `ex`-specific: the swap file, the descriptor table, `LINEBUF`, and the
  table-only vs. append-and-repoint split are all buffer-layer decisions
  a screen editor needs exactly as much as a line editor does. `vi`'s
  visual-mode motions (`h j k l`, `w`/`b`, etc.) become new ADDRESSING on
  top of the same descriptor table -- no buffer-layer rework implied.
- **Cursor addressing and screen refresh** are `docs/CONSOLE.md`'s
  existing VT/CSI subset (`TTY_VT_SUITE`) plus the scroll-cost work
  `docs/PROCIO.md` sec 11 already profiled -- both already named as `vi`
  prerequisites in `docs/IDE.md` sec 2, unaffected by this document.
- **Raw/noecho tty input is the one hard gap, confirmed still open.**
  `docs/CONSOLE.md` sec 4 states it explicitly: "Raw mode is... required by
  the userland line editor and any future visual editor... Build it when
  a program actually needs it, not speculatively." `vi` is that program.
  `src/bin/more.s` already hit the same wall for a much smaller reason
  (space-to-page without RETURN) and named the exact trigger in its own
  header: *"when a raw single-key tty read exists (the stty seed...)"*
  (`more.s:10-15`) -- `docs/FLEET.md`'s F.3 entry for `more` repeats it:
  paging-without-RETURN "arrives with the first raw tty read (stty seed)."
  **`vi` is the second, much larger consumer of that same seed** -- every
  visual-mode keystroke (motions, `x`, `dd`, etc.) needs unbuffered,
  unechoed single-key reads, which the kernel line discipline does not
  provide yet (`docs/CONSOLE.md` sec 4 ships cooked mode only in v1). This is
  not new information this document is contributing -- it is confirming
  the existing gap is still open and still exactly where `vi` will hit it
  first, at real cost (not a small patch -- it is a genuine line-discipline
  mode, `docs/CONSOLE.md` sec 4's own "leave room for raw/noecho later" note).
- **Nothing in this document's swap/descriptor design assumes cooked
  input.** The buffer layer never reads from the tty directly except
  through `ED_TEXTENTRY`'s line-at-a-time reader (`a`/`i`/`c`), which
  `vi`'s insert mode would replace with its own raw-mode character loop
  rather than reuse -- so raw-mode's arrival does not require touching
  anything in sec 2.

## Closing note for the next street-library pass

Two deposit-worthy findings from this session, for whoever picks up
implementation:

1. **The commons has no `ex(1)`/`vi(1)` primary source** in the
   `vintage-apple` collection as of 2026-09-02 (sec 3's grading note) -- worth
   a deposit once one is found (POSIX XCU `ex`, a 2BSD/3BSD manual, or a
   Kernighan/Joy retrospective), so the next searcher does not re-run the
   same negative.
2. **`docs/IDE.md` sec 3 is stale** (sec 2.4) -- its 46,005-byte/98.2%-full
   measurement predates the same-day `sbrk()` heap rewrite that mooted it;
   `build/ed.bin` is 6,461 bytes as of this session. Worth a dated
   correction note in `IDE.md` itself when this document lands, per this
   project's own "stale comments deter work" lesson.

---

## 5. IMPLEMENTATION PLAN (2026-09-02) -- the module split and build order

Verified against the code: **every ed module accesses the buffer ONLY
through the accessors** `ED_LINETEXT` / `ED_BUMP_ALLOC` / `ED_GETSLOT` /
`ED_SETSLOT` (grep-confirmed across edparse/edfile/edfil2/edsubst/edsub2 --
no module indexes `ED_LINES` directly). The descriptor width and the text
storage are therefore fully encapsulated in **edbuf.s**. `ex` forks ONLY
edbuf.s -> **exbuf.s** and reuses every other ed module unchanged.

### 5.1 The buffer contract exbuf.s must honour (identical to edbuf.s)

Same entry points, same register/ZP conventions, so ed's parse/file/subst
modules call them unchanged:

- `ED_LINETEXT` (IN: `ED_TMP16` = line n; OUT: `PTR0` = pointer to that
  line's NUL-terminated text). **THE ONE NEW RULE: the returned pointer is
  valid only until the next `ED_LINETEXT` call** -- it points into a single
  resident line-cache buffer that the next fetch overwrites. Verified safe:
  every caller reads one line at a time (fetch->use, or fetch->re-fetch the
  SAME line -- edsub2.s's `g` loop, edfile.s's write loop, edsubst's
  per-line scan). No caller holds two DIFFERENT lines' text at once (`t`/`m`
  share descriptors, not text; `j` reads source lines one at a time and
  appends). exbuf's `ED_LINETEXT`: read the 4-byte descriptor, `SET_MARK`
  the swap fd to its offset, `READ` `len` bytes into `EX_LINECACHE`,
  NUL-terminate, return `PTR0 = EX_LINECACHE`.
- `ED_BUMP_ALLOC` (IN: A = line length incl NUL? -- match edbuf's exact
  contract; OUT: `PTR0` = the value to store via `ED_SETSLOT`). exbuf:
  lazily open the swap file on first call (see 5.3), `SET_MARK` to swap
  end, `WRITE` the line bytes + one `$8D`, return the `{offset,len}`
  descriptor packed for `ED_SETSLOT`. Length capped at 254 (existing
  `CMDBUF_MAXLEN` ceiling).
- `ED_GETSLOT`/`ED_SETSLOT` (IN/OUT: the slot VALUE). Now a 4-byte
  descriptor `{offset:3, len:1}` instead of a 2-byte pointer. Callers treat
  it as opaque (t/m copy it whole), so widen the read/write to 4 bytes.
- `ED_LTSLOT` (IN: `ED_TMP16`=n; OUT: `ED_LTPTR`=&slot). Stride `n*4`
  (two asl/rol pairs) instead of `n*2`.
- `ED_INSRT_AFTR` / `ED_DLT_RANGE`: the slot-shift loops move/stride
  4 bytes instead of 2 (mechanical). Keep `MAXLINES` growth story (5.4).

### 5.2 The descriptor and the swap format

- Descriptor: 4 bytes `{offset lo, offset mid, offset hi, len}`. Offset is
  the byte position in the swap file (3 bytes = 16 MB, ProDOS tree-file
  ceiling). len <= 254.
- Swap on-disk: each line = its raw bytes + one `$8D` CR (byte-identical to
  what `w` writes). The stored `len` is the byte count WITHOUT the CR (so
  `ED_LINETEXT` reads exactly `len` bytes and NUL-terminates; the CR on
  disk is the salvage-by-hand courtesy, never read back).

### 5.3 Swap-file lifecycle -- LAZY, to keep edparse.s pristine

`ed`'s `START` (edparse.s) sets up the descriptor-table heap via
`SC_BRK`/`SC_SBRK` -- reuse it UNCHANGED for ex's now-growable descriptor
table (5.4). The swap file opens **lazily on the first `ED_BUMP_ALLOC`**,
guarded by an `EX_SWAP_OPEN` flag: `CREATE` (ignore "exists" $47), `OPEN`,
hold the fd for the session. Name: `EX.SWPxx`, xx = 2 hex of `BANK_ID`
($FF2E) in the cwd (`SC_GETPFX` for the prefix). On create/open failure:
a distinct louder message (`ED_NOHEAPMSG` shape) and exit. On clean
`q`/`w`+`q`: `SC_CLOSE` then `SYS_UNLINK` the swap file (a new cleanup hook
on the quit path -- one of the few edits outside exbuf.s; put it in the
quit-command handler). Lazy is functionally equal to the design's "eager"
for v1 (the swap file is created before any line is ever read back), and
it costs zero edits to edparse.s's START.

### 5.4 Growable descriptor table (replaces MAXLINES=1024 fixed)

`ED_LINES` moves from edsub2.s's fixed `ds LINETBL_SIZE` to a **runtime
region at the top of the descriptor heap**, grown by the SAME
`ED_ROOM`/`SC_SBRK` machinery. For the FOUNDATION milestone, keep it
SIMPLE: a fixed `MAXLINES` (e.g. 2048 at 4 bytes = 8 KB) declared in
exbuf.s, and defer true growability to a follow-up -- the headline
capability is unbounded BYTES (the swap file), which the fixed table does
not block for realistic files. Declare `ED_LINES` in exbuf.s; if edsub2.s
also declares it, remove that declaration there (the one edit edsub2 may
need). Grade this a NAMED v1 scope decision, not the final design.

### 5.5 Module list

- **NEW**: `src/bin/exbuf.s` (forked from edbuf.s), `src/bin/ex.s`
  (manifest, mirrors ed.s but puts exbuf.s where ed.s puts edbuf.s), and
  `src/bin/excmd.s` (the NEW tier-1 commands: `q!`, `wq`, `x`, marks +
  `'x`/`kx` + `?re?` backward search, `u` undo, `e` edit-file, `#`/`nu`
  numbered print). `n`/`next` DEFERRED (needs multi-file arg lists).
- **REUSED UNCHANGED** (put by ex.s): edparse.s, edfile.s, edfil2.s,
  edsubst.s, edsub2.s, and all liba. If edsub2.s's `ED_LINES` declaration
  must move, that is the lone reuse exception (5.4).
- The command dispatch: ex's new commands need a hook into edparse.s's
  command dispatcher. Prefer the sh-builtin pattern -- a `jsr EX_CMD` in
  the dispatch chain that returns "handled/not" -- added via a MINIMAL
  edparse fork (exparse.s) if a clean hook point does not already exist,
  else via the existing dispatch's default/unknown-command path.

### 5.6 Build order / milestones

- **M1 (foundation, single stream)**: exbuf.s + ex.s reusing ed modules;
  `ex FILE` loads via swap, `p`/`N`/`,p` print, `w` writes back
  byte-identically, `q` quits and unlinks the swap file. A minimal
  `check-ex` gate (build_ex_image.py + check_ex.py + extest harness,
  modelled on check-ed) asserting a load->print->substitute->write round
  trips byte-identically through the swap file. THIS proves the swap
  buffer end to end and is the gate everything else builds on.
- **M2 (commands, follow-on)**: excmd.s -- `q!`/`wq`/`x`, marks + `?re?`,
  `u` (single-level undo: snapshot the descriptor table before a mutating
  command, restore on `u`), `e`, `#`/`nu`. Extend check-ex per command.
- **M3 (integrate)**: Makefile UTILS += ex; rosters (check_purity
  TEXT_*), deps, check_dialect as-window, check_modules; full `make
  check-all` green. ex ships ALONGSIDE ed (ed stays; `evolve` = ex is the
  swap-backed successor, ed retained until ex is proven).

### 5.7 The vi sightline is unchanged by any of the above (sec 4)

Raw/noecho tty is vi's blocking prerequisite and nothing here forecloses
it; exbuf's single line-cache and 4-byte descriptors serve a screen
refresh as well as they serve `p`.

## 6. The interactive keyboard gate (check-play), 2026-09-02

`make check-ex` (sec 5.6's M1 gate, extestb.s) drives `ex` via `ex < script`
-- fd 0 redirection from a file. It has never proven the path a human
actually uses: `ex` read through a canonical (cooked, echo-on) tty, one
keystroke at a time via TTY_KEYIN. `ex` needs no raw/noecho mode for this
-- it is line-oriented, so the ordinary cooked discipline `sh` already
uses is exactly right (sec 4's raw-mode gap is `vi`'s problem, not this
one).

`scripts/check_play.py` now has an `ex` phase (after the `trap` phase,
before the `^D` shutdown finale) that types, at the keyboard: `ex EXFIX`
(a fixture staged by `build_play_image.py`, loaded through the swap
file AT LAUNCH -- see the 2026-09-02 update below), `,p`, `1a` / a
typed line / a BARE `.` on its own line (the classic ed/ex insert-mode
terminator -- and the exact "a dot was never typed" case HACKING.md's
own scar history names, alongside real lowercase command letters
`a`/`p`/`s`/`w`/`q`, which have no case-folding of their own the way
`sh`'s builtins got, docs/SH-CASE.md), `3s/OLD/NEW/`, `w EXOUT`, `q`.
Every step asserts the settled on-screen result; `w`'s write is
cross-checked by `cat`-ing the target back through the shell; and `q`'s
swap-file unlink (sec 2.7/5.3) is checked by `ls`-ing the (short,
unscrolled) directory afterward for the absence of any `EX.SWP*` name
-- the one ex-specific behavior the fd-0 gate already covers but a
human session should too.

**2026-09-02 update (filename-on-launch task):** the paragraph above
originally read bare `ex` then `r EXFIX` -- at the time this was
correct, ed/ex genuinely had no argv handling (grepped: no ARGC/GETARG
anywhere in ed.s/edparse.s/ex.s). That gap is now closed: `ed FILE` /
`ex FILE` load FILE at startup and remember it as the current
filename, exactly like real ed/ex (Ex Reference Manual v1.1,
learning:01M1FX8HT89CKR9CB8T8VKCW1S). This phase was updated to launch
`EX EXFIX` directly -- the real human hot path -- instead of bare `EX`
+ `r EXFIX`; see edparse.s's shared `START` for the implementation and
scripts/check_ed.py/check_ex.py for the fd-0 gates' own new sessions
(`ed FILE`/`ex FILE`, incl. a nonexistent-path negative case).

Every assertion in this phase was sabotage-proven red-then-green: the
bare-dot terminator and the swap-unlink call were each temporarily
broken at the source (exbuf.s) and confirmed to fail loudly, then
restored; the print/write assertions were each temporarily given wrong
expected text and confirmed to fail, then restored. One real bug was
found and fixed while building this phase: the first cut asserted the
`cat EXOUT` write-back with a whole-screen scan for its expected text,
which is byte-identical to the immediately preceding `,p` output still
on screen -- a stale match that passed before `cat` had even run, and
type-ahead cascaded into a hang three steps later. Fixed by switching to
the anchor-on-the-fresh-echo technique `check_play.py`'s own
`_typed_case` helper already uses for exactly this reason.
