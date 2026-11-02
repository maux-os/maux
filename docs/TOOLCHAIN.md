# maux toolchain and test rig


NOT PUBLISHED: refs/ -- the notebook snapshot mentioned below is kept
in the project tree, not in the public repository.

Written for task #1 (docs/TASKS.md). Covers the assembler choice, the
Merlin-8 dialect subset actually relied on, the disk-image strategy, how
to build and run the rig, and the rig-verification answers the task's
acceptance gate requires.

**Where the files are: docs/LAYOUT.md.** Since 2026-09-16 the host tree
and the guest tree are one tree -- `inc/` holds every put-able header,
every name under `inc/` and `src/` is ProDOS-legal, and put operands
have exactly two shapes so that "drop the leading `..`, anchor at /SRC"
is a total rule. That document carries the host/guest table, the full
rename list, and the two `check-modules` rows that hold it.

## STATUS (2026-08-23): tasks #1 and #7 meet their acceptance gates

**Task #1 -- CLOSED against its own hard gate.** The acceptance was:
hello-world visible via `screen_text` on BOTH backends, and the three
rig-verification questions answered or explicitly deferred with a
reason. All three hold: `make check-boot` asserts "MAUX ALIVE" on
`fast` and `rtl` (in `check-all`, re-verified green 2026-08-23);
question (a) 65C02-vs-NMOS is answered YES from source on both
backends, (b) the $C073 fine points are answered with one new finding,
(c) mouse-VBL is explicitly deferred to task #6 with the reason stated
-- see "Rig verification" below. The Merlin-8 manual the cold-read
amendment asked for is in the street-library commons as a searchable
primary source (learning:01M050TRV68DY9GBARSDRX9B1W) rather than in
refs/ -- deliberately, so its facts carry confidence tags and every
project can cite them. The dialect subset below is no longer
PROVISIONAL; see the next paragraph. Status lives here because this
file is the task's deliverable; the board's crosswalk row is S8's to
flip (docs/PLAN.md sec 0 rule 2).

**Task #7 -- the gate now covers the tree, not just the kernel.**
`make check-dual` is the byte-identity instrument (real Merlin-8
assembles the kernel unit on the emulated //e; 16,384 bytes,
byte-identical to merlin32, re-verified green 2026-08-23), and the new
`make check-dialect` enforces the dialect INTERSECTION statically over
all 83 compilation units (incl. src/bootblock.s and src/check.memmap.s,
which every other gate's glob missed -- 2026-08-23 review finding N3)
-- interior-space and precedence expression divergences, dum
placement, the 41,215-byte source-buffer budget, line/label limits for
the two units check-modules cannot see (54 over-long lines pinned as a
shrink-only ratchet -- real Merlin-8 debt, not yet fixed), and the
owed PARMS $83 assertion (asserted in check-dialect statically AND in
check-dual against the very volume it boots). Both gates' teeth are
proven: nine sabotages, each verified to change behaviour before its
red was trusted -- see "Task #7 closed" below. What "covers the tree"
does NOT claim: only the kernel unit is byte-verified under real
Merlin; the other 82 units are statically clean against measured
dialect facts, and the gate prints that split every run so green
cannot overclaim.
Real-Merlin byte-coverage of the remaining units grows with S9's
conversion (extend check_dual.py's manifest set as units are staged).

## Assembler: merlin32 v1.1.10

**Ruling (docs/TASKS.md #1): merlin32 (Brutal Deluxe, v1.1.10 via
`brew install merlin32`), chosen for the self-hosting arc** -- task #8 ports
real Merlin-8 to run *under maux itself*, assembling this same source tree.
That only works if the tree stays inside the intersection of merlin32's and
real Merlin-8's dialects from day one; retrofitting portability later would
mean re-auditing everything. `~/src/malisp`'s Makefile is the working
precedent for the merlin32+a2til pipeline and was read in full before
building this one (`~/src/malisp/Makefile`, `~/src/malisp/src/bootblock.s`).

Confirmed locally: `/opt/homebrew/bin/merlin32`, `merlin32 v1.1.10, (c)
Brutal Deluxe 2011-2015`.

## Merlin-8 dialect subset relied on (validated 2026-08-23; table kept as history)

**PROVISIONAL retired 2026-08-23.** When this section was written no
Merlin-8 dialect authority existed anywhere; the commons now carries the
manual as a primary source plus eight measured dialect learnings (the
64-char line, the 13-char label, no-precedence expressions, the 41215
buffer, EQU forward references, negative `ds`, `dum` placement, and the
PARMS structure -- handles cited throughout this file). The per-row
"flagged for task #7" caveats below are settled two ways:

- **Byte-verified under real Merlin-8** (`make check-dual`, kernel unit,
  byte-identical output): `asc` (high-bit strings -- the silent-string
  worry in the table below is dead), `da`, `dfb`, `ds`, `dum`/`dend`,
  `equ`, `lst`, `org`, `put`, `typ`, `xc`, `dsk` (path-rewritten on the
  staged volume, as anticipated), `:local` labels, `#<`/`#>`, PC
  arithmetic, and every 65C02 mnemonic the kernel uses.
- **Model-verified only** (measured constraints, no byte-compare yet):
  `err`, `putbin`, and anything only src/bin or src/liba uses -- those
  units reach real Merlin when S9 stages them.

One residue, so "retired" does not overclaim (review finding N3):
src/bootblock.s and src/check.memmap.s sat outside every line-length
glob and carry 31 + 23 lines over Merlin-8's 64-char limit -- real
rejections, now pinned as check-dialect section 5's shrink-only
ratchet, owned by the streams that own those files.

The table below is the original catalog, kept verbatim as history of
what was once uncertain.

Directives and syntax relied on so far (all from `src/bootblock.s`):

| Construct | Used as | Confidence it's in real Merlin-8 |
|---|---|---|
| `lst off` | suppress listing | plausible -- standard Merlin listing control |
| `xc` | select 65C02 instruction set | plausible -- the `xc`/`xc off` toggle is documented merlin32 behavior consistent with Merlin's 65C02 extension model |
| `org $0800` | set origin | certain -- universal assembler primitive |
| `dsk <path>` | name the output binary | **merlin32-specific mechanism** -- real Merlin-8 running under ProDOS on real/emulated hardware doesn't take a `dsk` directive to name a *host* output file; it SAVEs from its own editor to a ProDOS volume. Task #7's dual-assembly gate has to reconcile this (drive the editor via `type`, per docs/TASKS.md #1) -- the directive itself is unlikely to be Merlin-8-compatible source syntax and this file will likely need adjustment once #7 stands up. Flagged, not yet resolved. |
| `typ $00` | set output ProDOS file type | same caveat as `dsk` -- merlin32 cross-build convenience, sidecar-driven (learning:01KW1GTYGZ9TE2ZGCDG0V2CNE0), not verified against real Merlin-8 |
| `dfb $01` | define byte | plausible -- standard Merlin pseudo-op |
| `ds <expr>` | pad/reserve storage, expression incl. `*` (current PC) | plausible -- standard Merlin pseudo-op; PC-relative expressions (`$0800+512-*`) are common Merlin idiom (malisp's bootblock.s uses the identical idiom) |
| `equ` with `*-LABEL` | compute a length from two labels | plausible -- same PC-arithmetic idiom as `ds` above |
| `asc "STR"` | string literal, **high-bit SET** | **merlin32-confirmed** (learning:01KW1GTYGZ9TE2ZGCDG0V2CNE0) but the corresponding real-Merlin-8 behavior is UNVERIFIED -- this is exactly the kind of fact task #7's gate exists to catch, since a silent divergence here (e.g. real Merlin-8 emitting plain ASCII) would corrupt every string literal in the tree without a build error |
| `:label` (colon-prefixed local labels) | branch targets scoped to the enclosing non-local label | plausible -- standard Merlin local-label convention |
| `*` full-line comment, `;` inline comment | comments | plausible -- standard Merlin convention |
| Standard 6502/65C02 mnemonics (`sei`,`cld`,`txs`,`ldx`,`lda`,`sta`,`inx`,`cpx`,`bne`,`jmp`) | instructions | certain |
| `put <path>` | inline-include another source file at assembly time (task #5: `src/test/probetest.s` PUTs `src/kernel/bankprobe.s`) | plausible -- real Merlin-8/16 have supported `PUT` (whole-source-tree composition, not just a merlin32 cross-build convenience) since the 1980s; **not previously catalogued here because `src/bootblock.s` is a single file and never needed it.** Precedent: `~/src/malisp/src/boot.s` uses the identical `put apple2.s` / `put zp.s` / ... pattern extensively (13 files). Path resolves relative to the directory of the file CONTAINING the `put`, same rule as `dsk` (confirmed empirically: `src/test/probetest.s`'s `put ../kernel/bankprobe.s` correctly reaches `src/kernel/bankprobe.s`) -- not yet independently verified against real Merlin-8, flagged for task #7 like `dsk`/`typ` above. |
| `use <path>` | pull in a shared symbol/library file (task #2: `src/check.memmap.s` USEs `inc/memmap.equ`; task #5: `src/test/probetest.s` does the same before PUTting bankprobe.s in) | plausible -- standard Merlin distinction from `put` (library/symbol file vs. plain source paste), not independently verified against real Merlin-8; same `dsk`-relative path-resolution rule as `put` above. |
| **`put`/`use` NESTING IS ONE LEVEL DEEP** (merlin32 gotcha, found building task #5) | a `put`/`use` directive written INSIDE a file that itself only reaches the assembler via another file's `put` is silently never loaded | **merlin32-confirmed by direct experiment, real-Merlin-8 behavior UNVERIFIED -- flag for task #7.** merlin32's source-file discovery only scans the file actually handed to it on the command line for `put`/`use` lines; it does not recurse into files pulled in by those directives to find FURTHER `put`/`use` lines within them. Symptom: a `use ../../inc/memmap.equ` written inside `src/kernel/bankprobe.s` (itself only reached via `src/test/probetest.s`'s `put ../kernel/bankprobe.s`) produced `[Error] Impossible to decode address mode ... Can't find format for element 'BANKSEL'` -- NOT a file-not-found error, because the `use` line was never even added to the "Loading Sources files" list merlin32 prints at the start of a run (visible by comparing that list with vs. without the nested directive). Fix used here: the shared symbol file must be `use`d by the TOP-LEVEL file (the one merlin32 is actually invoked on), before it `put`s in anything that references those symbols -- `src/test/probetest.s` now `use`s `inc/memmap.equ` directly, and `src/kernel/bankprobe.s`'s header documents this as a precondition on its includer rather than trying (and silently failing) to satisfy its own dependency. Matters directly for task #7's dual-assembly gate: if real Merlin-8 DOES recurse nested `put`/`use`, this precondition is over-cautious but harmless; if it also doesn't, this repo's structure already assumes the stricter (merlin32) behavior everywhere, so no rework would be needed either way -- but the fact itself should be confirmed, not assumed, when that gate stands up. |
| `PHX`/`PLX` (push/pull X), `BRA` (branch always) | instructions | certain these are genuine 65C02 opcodes (absent from NMOS 6502; see docs/TOOLCHAIN.md's task #1 rig-verification section for the `cpu65c02_impl.h` opcode-presence evidence) -- first *used* by task #5's `src/test/probetest.s` (`PrintHexY`'s `PHX`/`PLX` register-save bracket, `showloop`'s `BRA`); Merlin-8-dialect confidence follows the same "certain, universal 65C02 mnemonic" reasoning as the bootblock.s mnemonic row above, not re-litigated per-opcode. `BRA` additionally corroborated by task #10, which relies on it throughout `src/liba/*.s`/`src/bin/*.s` for every loop back-edge (e.g. `string.s`'s `STRLEN`/`STRCMP`, `num.s`'s `U2DEC` digit loop) -- heaviest single user of the mnemonic in the tree so far, still the same "certain" confidence. |
| `da <expr>` | define a 2-byte little-endian word (e.g. a lookup-table entry) | plausible -- standard Merlin "define address" pseudo-op, same PC-arithmetic-adjacent family as `dfb`/`ds` above; first used by task #10's `src/liba/num.s` (`POW10`, five sequential `da` entries for `U2DEC`'s decimal-conversion table). Not independently verified against real Merlin-8, flagged for task #7 like the other pseudo-ops in this table. |
| `#<expr` / `#>expr` (low-byte / high-byte extraction in an immediate operand) | e.g. `lda #<LABEL` / `lda #>LABEL` to split a 16-bit pointer into two 8-bit loads | plausible -- the standard 6502-assembler idiom for this, present in essentially every mainstream 6502/Merlin dialect, and already relied on by the working `~/src/malisp` precedent build (`~/src/malisp/src/reader.s`'s `LSET` macro: `adc #<LINE_BUF`). First used directly by task #10 (`src/liba/print.s`'s `PUTC`/`PUTS`, and every `src/bin/*.s` util's string-literal pointer loads). Not independently verified against real Merlin-8, flagged for task #7 like the other operators in this table. |

**Bottom line:** the *instruction* subset is safe. The *directives that talk
to the host filesystem* (`dsk`, `typ`) are the ones most likely to need
rework for task #7 -- they encode "how merlin32 packages output for a
cross-build," not "what real Merlin-8 source syntax looks like." Flagging
this now so task #7 doesn't rediscover it from scratch.

## REL/LNK and liba packaging

The current userland build is intentionally primitive: each program `put`s the
liba source files it needs, because merlin32 is being used as a flat
cross-assembler with no separate object/link step. That is not assumed to be
the final self-hosted format.

`docs/REL-LIBA-SPIKE.md` tracks the required spike: test real Merlin REL/LNK
under ProDOS, confirm whether unused routines/data are omitted from linked
outputs, and decide whether liba should be packaged as a canonical common
profile plus selective feature modules. Regex, future readline-style editing,
terminal helpers, and screen libraries are the pressure cases: they should not
burn RAM in tiny programs that never call them.

## Disk-image strategy (staged)

Per docs/TASKS.md #1's cold-read amendment, transcribed and refined against
what was actually built:

- **Stage 0 (THIS TASK, DONE):** raw SmartPort block image. `src/bootblock.s`
  assembles to a single 512-byte block; `scripts/build_image.py` places it
  at block 0 of a zero-filled `build/maux.po` (800 blocks = 400KB -- "a few
  hundred KB" per the task contract) and does nothing else. No filesystem,
  no ProDOS, no MLI. This is exactly the malisp `bootblock.s` boot path
  (SmartPort firmware loads block 0 to `$0800`, jumps to `$0801`) minus the
  chain-loading logic malisp needs to find `MALISP.SYSTEM` -- maux's
  hello-world has nothing to chain-load yet, so it just prints and halts.
- **Stage 1 (future, task depends on #2+):** hosted ProDOS 2.4 volume via
  a2til (vendored ProDOS kernel + a `MAUX.SYSTEM` auto-launch file, same
  shape as malisp's `build_image.py` + `install_bootblock.py` pair). Gate
  work-in-progress disks via `a2til mirror` so a host editor and a live
  emulator session can share source without a NuFX/ShrinkIt shuffle.
- **Stage 2 (much later):** native `mkfs.maux` host tool -- deterministic
  from birth, no vendored ProDOS at all -- eventually a maux-fs engine
  inside a2til itself. `.woz` floppy images are explicitly deferred
  throughout; SmartPort `.po` is the format for all of the above.

**Determinism:** `build/maux.po` is a pure function of `bootblock.bin`'s
bytes and the fixed block count -- `scripts/build_image.py` writes no
timestamps or host metadata, so `make clean && make` reproduces
byte-identical output. Verified: two consecutive clean builds produce
identical `build/maux.po` (not yet automated as a test; trivial to add
later -- `cmp` two builds). a2til's own fixed-timestamp support for stage 1
(ProDOS directory entries carry a date/time field) has NOT been checked
yet -- deferred to whichever task first builds a ProDOS volume, since stage
0 doesn't touch ProDOS structures at all.

## Building and running the rig

```sh
make            # -> build/maux.po (merlin32 assemble + block-0 pack)
make clean      # remove build/
make check-boot # THE HARD GATE: boots build/maux.po on fast AND rtl,
                # asserts "MAUX ALIVE" via screen_text on both
```

`make check-boot` depends on `~/src/verilogapple/sim/mcp/obj_dir/mcp_supervisor`
and builds it (`make -C ~/src/verilogapple mcp`) if missing. **This repo
never modifies `~/src/verilogapple`** -- only builds and drives it, since
another agent works that tree in a separate worktree.

### Which verilogapple branch the gates need (read before rebuilding it)

That "only builds it" is sharper than it looks: **`make -C ~/src/verilogapple mcp`
builds whatever branch happens to be checked out there, and maux's gates
need MCP tools that live on two different unmerged branches.**

| MCP tool | needed by | lives on |
|---|---|---|
| `eject_disk` | `check-rel`, `check-merlin`, `check-dual` | `milestone/smartport-n-drive` |
| `ultraterm_state` | `check-ultraterm`, `check-play80` | `milestone/ultraterm-state` |
| `buttons` | `check-play` (readline's OA-meta leg) | `feat/mcp-buttons` (verilogapple#16) |

None is on `main`. The worker must be built from
`integration/ultraterm-plus-smartport`, which UNIONS the tool branches;
that branch exists for exactly this reason and is not intended for
review or merge (the milestone branches are the reviewable ones).
`feat/mcp-buttons` was merged into it 2026-08-31 -- the cost row below
recurred that day: the buttons agent's checkout rebuilt from its own
branch alone and `ultraterm_state` vanished from three green gates.

Cost of not knowing this, 2026-08-17: rebuilding from a `main`-based
branch silently dropped `eject_disk` and broke three green gates. The
symptom was an `unknown tool: eject_disk` traceback from inside
`mcp_drive.call_tool`, three frames deep, naming no branch and no cause.
`MCPClient.require_tools()` now front-runs that -- the UltraTerm gates
fail immediately with a message that names the missing tool and points
here. Add a `require_tools` call to any new gate that depends on a tool
outside `main`.

`scripts/mcp_drive.py` is a from-scratch, Python-stdlib-only MCP client
(no SDK) -- it has to be, because a lightweight one-shot driver doesn't
warrant pulling in a dependency, and the task explicitly asked for stdlib
only. It talks newline-delimited JSON-RPC 2.0 directly to
`mcp_supervisor`'s stdin/stdout (verified against `mcp_supervisor.cpp` /
`mcp_server.cpp` source -- there is no `Content-Length` framing the way
LSP does it; one JSON object per line, both directions). Two protocol
details that aren't obvious from the tool docs and cost time to find by
reading source instead of guessing:

1. **Tool-call results are double-encoded.** The JSON-RPC `result` is
   `{"content": [{"type": "text", "text": "<json>"}]}` -- the `text` field
   is itself a JSON document holding the tool's actual return value. The
   driver `json.loads()`s twice.
2. **The worker's cwd is not the caller's cwd.** `mcp_supervisor` forks
   the real emulator (`Vapple2e_sim_top`) into `<supervisor_dir>/../../top`
   so its own relative ROM paths resolve -- any filesystem path handed to a
   tool (`mount_disk`'s `path`) must be made absolute by the *client*
   first, or it resolves against the wrong directory. `mcp_drive.py`
   calls `os.path.abspath()` on the disk path before sending.

### The step-unit gotcha (why `check-boot` doesn't hardcode a cycle count)

Per learning:01KWF4QBFJ8EJWK21JVP16VEM7 and the task's cold-read
amendment: `step {cycles}`'s unit **differs by backend** -- on `fast` it's
one CPU bus cycle; on `rtl` it's one 14.318 MHz tick, and roughly 14 ticks
elapse per CPU cycle (14.318 MHz / ~1.023 MHz). A cycle count that boots
`fast` does essentially nothing on `rtl` if passed unconverted, and `rtl`
is dramatically slower wall-clock per unit of emulated time than `fast`
(the task's budget: "minutes, not seconds" for rtl boot stepping).

`mcp_drive.py` handles this two ways: (1) it multiplies the CPU-cycle
budget by 14 internally when the backend is `rtl`, so `--chunk-cycles` and
`--max-cycles` are always specified in **CPU-cycle** terms regardless of
backend; (2) rather than guess a single "boots by cycle N" constant (which
would need re-deriving for every change to the boot path), it steps in
chunks and polls `screen_text` after each chunk, stopping as soon as the
needle string appears. This costs a few extra `screen_text` round-trips
but avoids both under-stepping (silently missing a slow boot) and
grossly over-stepping on the expensive backend.

**Observed timing (2026-08-14, this task's actual run):** both backends
found `"MAUX ALIVE"` on the very **first** poll -- `fast` after 200,000
CPU cycles, `rtl` after 2,800,000 ticks (= 200,000 CPU cycles x 14). Wall
time for the whole `make check-boot` run was on the order of seconds for
both backends combined, nowhere near the 15-minute contingency budget --
the hello-world path is short enough (autostart scan -> SmartPort block 0
read -> ~30 instructions -> halt) that it doesn't exercise the
"rtl is 1000x slower wall-clock" concern the task warned about; that
concern applies to full ProDOS/filesystem boots, not this stage-0 image.

## Rig verification (task #1 hard-gate requirement)

### (a) Does verilogapple's CPU model the 65C02 (not NMOS 6502)?

**Yes, confirmed on both backends by reading source, not by trusting a
label.**

- `sim/cpu_cpp/cpu65c02.h` (the fast backend's C++ core): header comment
  states "Abstract C++ interface for a WDC 65C02 core... a pure C++ port
  of cpu65c02.sv." `sim/cpu_cpp/cpu65c02_impl.h` implements the CMOS-only
  opcode set that would be **absent** from an NMOS 6502 core: `STZ`
  ($64/$74/$9C/$9E), `TRB`/`TSB` ($14/$1C/$04/$0C), `RMB`/`SMB`
  (bit-set/clear-direct), and `BRA` ($80) -- these don't exist on NMOS
  6502 silicon at all, so their presence (not just a comment claiming
  "65C02") is the actual evidence.
- `rtl/cpu65c02.sv`: the cycle-accurate reference core, same instruction
  set by construction (the C++ core is explicitly documented as a port of
  this file, and `sim/cpu_cpp/cpu65c02.h`'s cycle-model comment says
  "matches cpu65c02.sv exactly").

Both backends the rig can select (`reset {backend: "fast"|"rtl"}`) are
genuine 65C02 cores, not NMOS 6502 with CMOS opcodes bolted on. This
matters for maux directly: the project targets 65C02 (per HACKING.md) and
several planned constructs (e.g. `BRA`, `STZ` for zeroing without
clobbering a register) depend on this.

### (b) Which $C073 fine points does the AuxCard model?

Read `sim/aux/aux_ramworks.h`, `sim/fast/fast_apple2e.h`, and (for the RTL
side) `rtl/aux_slot.sv` + `rtl/iou.sv`. Four facts checked against the
known AE RamWorks III manual claims (learning:01KYYJ98T5R0M9K1AW2550M132,
learning:01KYYPR1CB9H9JK88W5QF56QWQ):

1. **Write-only (can't read the bank back):** modeled correctly on `fast`
   -- `fast_apple2e.h`'s `c0xx_read_value()` has no case for `$C073`; reads
   there fall through to the default `return 0x00`, so software can never
   read its own bank selection back through the register (must keep an
   in-bank identity byte, per the manual). `rtl/aux_slot.sv`'s
   `ramworks_bank` output only ever comes from the write-triggered latch;
   there is no read path defined for it either.
2. **Reset persistence -- KNOWN, already tracked, not re-reporting:** `fast`
   clears `ramworks_bank = 0` in `reset()` (`fast_apple2e.h:122`),
   contradicting real hardware; `rtl/aux_slot.sv` has no reset input at all
   (matches the real LS273's POR-only /CLR, per its own header comment).
   This is verilogapple issue #13 / maux task #9 -- already filed, cited
   here only to confirm it's the one this task's rig-verification question
   was pointing at, not to refile it.
3. **Dense-only banking (no sparse period-card model):** `AuxRamWorks`
   (`aux_ramworks.h`) is constructed with a flat `bank_count_` and indexes
   contiguously `0..bank_count_-1`; there is no period-card alias/sparse
   map ($00-$17,$30-$37,$50-$57,$70-$77) on either backend. Also already
   tracked (task #9(b)).
4. **Paddle-strobe-on-any-$C07x-write -- NEW FINDING, both backends
   diverge from the real card, in different ways:**
   - `fast`: the 558 one-shot restart (`pdl_start = cycles`, which gates
     `PDL0-3` reads at `$C064-$C067`) is triggered ONLY by the literal
     address `$C070` (`fast_apple2e.h:326`: `if ((a & 0xFF) == 0x70)
     pdl_start = cycles;`). Writing `$C073` (the RamWorks bank select
     itself) does **not** retrigger the paddle timers on `fast` -- contrary
     to the AE manual's documented behavior ("writing $C073 trips the
     paddle strobe... wait >=3ms before reading paddles").
   - `rtl`: `iou.sv` DOES correctly decode the *whole* `$C07x` window for
     the game-port reset signal (`c07x_n`, `aux_slot.sv`'s own header
     comment confirms: "`$C073` sits within the IOU's `$C07x` window
     (game-port one-shot reset), so a write here still triggers that on
     the motherboard") -- but `iou.sv:521-522` says outright: "Paddle
     one-shots ($C064-$C067, $C070) are not modelled yet." So `rtl` knows
     *when* the trigger condition fires across the correct address range,
     but the timer behavior itself is a stub on both `$C070` and `$C073`.
   - **Net effect:** neither backend currently reproduces "any $C07x
     write restarts the paddle one-shots" end-to-end. `fast` has the
     timer but the wrong (too-narrow) trigger address; `rtl` has the
     right trigger address but no timer. Not a fact this task depended
     on (the hello-world gate doesn't touch paddles), flagged for
     whichever future task needs paddle-adjacent timing (task #6's
     "paddle-strobe consequence" documentation references this exact
     mechanism) -- see DEPOSIT CANDIDATES in the task report.

### (c) Mouse-card VBL-enable path from a non-stock environment

**Deferred to task #6**, per the task contract's explicit allowance.
Reason: nothing in this task's boot pipeline (a 30-instruction hello-world
that never touches slot 5 or interrupts) exercises the mouse card's VBL
enable sequence, so no incidental finding fell out of building/verifying
the rig. Task #6 (scheduler/timer source) is where this needs answering
for real, against `learning:01KZXDQCQF2FZMDQ59FVZ5D7T4`'s AppleMouse-VBL
baseline ruling and `learning:01KWK8F6HFGRWS8SPPQ9MHC6GS`'s ClearMouse
narrow-clear semantics.

## Merlin-8 manual: deferred (RESOLVED -- see "The manual arrived" below)

**Deferred -- found the exact location but not the budget to fetch it.**
The asimov mirror (`mirrors.apple2.org.za/ftp.apple.asimov.net`) has it
under `documentation/programming/6502assembly/`, as two bundle archives:
`Merlin-Manuals.zip` (110,438,437 bytes per `Content-Length`) and
`Merlin16-Manuals.zip` (43.92 MB) -- there is no standalone smaller Merlin-8
PDF alongside the ~85 other files in that directory; the full manual set is
only available as this single large zip. A timed download attempt
(`curl --max-time 90`) pulled 13.6 MB in 90 seconds (~150 KB/s from this
network) -- extrapolating, the full `Merlin-Manuals.zip` would take
roughly 12 minutes, past the task's "~10 minutes, don't rabbit-hole"
budget once the search time to locate it is included. Recorded here rather
than attempted further; a future task (most naturally task #7, which
actually needs the manual's content to validate the dialect gate) should
either budget the full download or fetch just the relevant Merlin-8
volume out of the zip via an HTTP range request if the mirror supports
partial zip extraction.

Exact URL for the next attempt:
`https://mirrors.apple2.org.za/ftp.apple.asimov.net/documentation/programming/6502assembly/Merlin-Manuals.zip`

## Real-Merlin dialect constraints (measured, not assumed)

### Source lines: 64 characters, hard

Real Merlin-8 rejects any line longer than **64 characters** with
`Operand too long in line: N` -- and it fires on COMMENT lines too, where
there is no operand at all, which makes the message actively misleading.
Measured 2026-08-16 by assembling comment lines of 62..69 characters under
Merlin-8 2.59: 64 passes, 65 is the first flagged. Merlin's own shipped
sources never exceed 58 characters, and their boxed `*-----` comment style is
a consequence of the limit rather than decoration.

merlin32 has no such limit, so this tree was written without regard to it.
**As of 2026-08-16 the backlog is cleared: 5165 over-long lines -> 0**, and
`make check-modules` now GATES on it rather than ratcheting, so the tree stays
assemblable by real Merlin.

Every step was verified byte-identical: comments and symbol names cannot
change emitted code, so all 9 build artifacts had to match the pre-rewrap
baseline exactly, and did. That check is what made an automated edit of
several thousand lines defensible -- and what let a bad first attempt be
thrown away with confidence.

How the 5165 were cleared:

```
2176  mechanical rewrap   banner rules; `code ;comment` reflowed at its column
 616  header extraction   design essays -> docs/a2/*.TXT (operator ruling)
 295  paragraph reflow    plain prose runs inside mixed blocks
 113  block extraction    mid-file structured blocks -> docs/a2
  32  code splitting      dfb/da comma lists and asc strings split (same bytes)
  33  by hand             pointer lines, commented lists, three long symbols
```

The operator ruling that unblocked it: stop carrying elaborate inline
documentation, write the docs to Apple II readable text files and refer to
them. See `docs/a2/README.TXT`. The realisation that made it clean is that
**64 characters is an assembler constraint, not a display one** -- once the
content is in a text file, tables and diagrams keep their natural width.

Deposited as `learning:01M04SAJTJAYXCR3YNFW313FMZ`, the collection's first
Merlin dialect entry (HACKING.md has asked for these since task #1).

### Label length: 13 characters, and that was the LAST divergence

Measured the same way, 2026-08-16: labels of 11..17 characters assembled
under real Merlin 2.59. **13 passes, 14 fails** with `Bad label in line: N`.
For a `:local` the colon is part of the field, so the identifier gets 12.
It is a hard rejection, not a truncation -- the symbol is never defined, so
every reference to it fails afterwards too.

284 symbols in this tree were over the limit (~1300 occurrences). All were
renamed by `scripts/shorten_labels.py`, byte-identically. Two things that
went wrong and are now encoded in that tool:

* **Do not shrink from the right.** The trailing word is what distinguishes
  family members (`FKP_SRC_END` vs `FKP_SRC_LEN`). A right-to-left
  abbreviator deletes exactly that and then collides with its own sibling.
* **Rename whole families, including members already legal.**
  `K_DISPATCH_COUNT` (16) had to shrink; `K_DISPATCH_LO` (13) did not.
  Renaming only the first split the family and left dangling references --
  and **merlin32 resolved the undefined symbols to zero and emitted a
  plausible-looking wrong image rather than failing.** Only `make
  check-bytes` caught it.

The same probe assembled every directive this tree uses (`LST ORG DSK PUT
EQU DS DFB DA ASC HEX DCI DUM/DEND TYP XC`) and every 65C02 opcode
(`STZ BRA PHX PLX PHY PLY`) with zero errors and the exact expected byte
count. So **line length and label length were the only two divergences** --
the dialect is otherwise clean, which is a far better position than
"unknown".

End-to-end confirmation: `src/kernel/mouse.s` assembled by real Merlin-8 with
`Errors: 0`, object byte-identical to merlin32's for the same source
(`8dd0c0add2c009208dd2c029df8dd2c060`). That is task #7's comparison, made.

Deposited as `learning:01M050C6KW01MPJ2TQTPMTZXN6`.

### `make check-bytes REF=<commit>`

Refactors that must not change emitted code are now proved, not asserted.
The artifact set is defined once in `scripts/check_bytes.py` -- because the
shell one-liner it replaces used `find build -name '*.bin' -o -name '*.po'`,
which silently omitted the six `build/MAUX*.SYSTEM` kernels: the largest
artifacts in the tree and precisely the ones containing the code being
refactored. Several earlier "byte-identical" claims rested on that
incomplete set. Re-run against the full set, the whole series -- comment
rewrap, doc extraction and all 351 renames -- is confirmed to have changed
zero emitted bytes across all 24 artifacts.

### Does the kernel fit? No -- ~40 KB per PUT file (measured)

Real Merlin-8 is a **memory-based** assembler: the source being assembled
lives in RAM. Measured 2026-08-16 with graduated filler files, each pulled in
by a minimal top-level doing nothing but PUT:

    ~34 KB  assembles          ~40 KB  assembles
    ~36 KB  assembles          ~41 KB  56 MEMORY IN USE
    ~39 KB  assembles          ~43 KB  56 MEMORY IN USE

So the ceiling is between 40,960 and 41,984 bytes for one PUT file, with a
near-empty editor buffer -- an optimistic bound, since a larger top-level
lowers it. `$56` is the ProDOS code for a bad buffer address: Merlin asks
ProDOS to open the next source file and the buffer lands in pages the memory
bitmap already has allocated. The message never mentions size.

Against that ceiling, this tree today:

    KPROCESS     86775   OVER by 2.1x  -- needs a real source split
    KSCHED       44432   OVER          -- within reach of comment extraction
    IMEMMAP      34039   under, close
    KENTRY       30953   under
    everything else      comfortably under

**Comments count** -- Merlin stores source as text, so a 44 KB module can
assemble to a few hundred bytes of object. This is the measurement behind the
`as`/REL plan in docs/SELFHOST.md: the tree cannot be assembled as one PUT
chain on a 64K machine no matter how the files are arranged, which is exactly
what separate assembly to REL objects is for.

Untested lead: Merlin 2.58+ has a PARMS bit that moves ProDOS into aux memory
(`learning:01M041MZER5YQJQYR7JP5N7F01`). Since the failure is a ProDOS buffer
conflict, that may move the ceiling. Worth trying before committing to a
split of process.s.

Deposited as `learning:01M051EM2HQ3ZVJTR1W9P3G86J`.

### Expressions: no precedence, no parentheses

`2+3*4` is **20** under Merlin-8 and **14** under merlin32. Parentheses are
rejected outright (`Illegal char in operand`). Half of this divergence is
loud and half is silent -- both assemblers accept `A+B*C` and emit different
bytes.

Only one expression in this tree was affected (`inc/memmap.equ`, the pipe
sizing) and it now names its sub-expression instead. Note `*` is also
Merlin's location counter, so `$0800+512-*` contains no multiplication --
any scan for this must tell a binary `*` from the PC term or it reports
26 false positives where there are 2 real ones.

This one is a correction as much as a finding: the previous section claimed
label length was the only remaining divergence, on the strength of a probe
that tested directives and opcodes but never expressions. Enumerating what
you tested is not the same as enumerating what exists.

Deposited as `learning:01M051DJW89KV4JYM1EC9SDZ5Y`; the label-limit learning
carries a dated correction.

### `scripts/build_maux_src_image.py`

Stages the tree onto an 800K MAUXSRC volume with flat ProDOS names and
rewritten PUT paths, so real Merlin can be pointed at maux modules
repeatably. `--probes` adds the graduated filler files used above.

### The manual arrived; what it confirmed and what it changed

The Merlin 8/16 User's Manual is now in the commons as a searchable primary
source (`learning:01M050TRV68DY9GBARSDRX9B1W`). Checked against everything
measured above.

**Confirmed, verbatim.** "The maximum allowable LABEL length is 26 characters
in Merlin 16 or 13 characters in Merlin 8, but more than 8 will produce messy
assembly listings unless you change the tab settings." Measurement and manual
agree exactly. Two rules we had not measured, both of which this tree already
satisfies (checked: 0 violations):

* a label must begin with a character whose ASCII value is >= `:` ($3A), so
  no leading digits -- and that is why the local-label sigil is `:`, it sits
  exactly on the boundary;
* `.` is not used in any label here.

Merlin 16 allowing 26 is worth remembering if the 65816 tool ever becomes the
target: the renaming work would not have been needed.

**Changed our approach: USE vs PUT.** The manual says `PUT` reads a file and
inserts it, and is "the workaround for source too large to assemble in
memory" -- while `USE` works similarly "but the file is kept in memory",
intended for a macro library. merlin32 treats them interchangeably, so the
distinction was invisible here.

It is not a small distinction. This tree had 54 `use` lines pulling three
equate files:

    inc/memmap.equ     34114
    inc/errno.equ       3077
    inc/syscall.equ     4787
    TOTAL                  41978   against a ~41000-byte ceiling

The equates alone would have filled the entire source buffer before a single
kernel module loaded. All 54 are now `put`; byte-identical, verified with
`make check-bytes`. Nothing here is an actual macro library, so nothing needs
to stay resident.

**Still to read:** the manual carries a Merlin memory map at pages 176-178 and
a "memory use by Merlin" section at 166, which should let the ~40 KB ceiling
be derived rather than measured. `MEMORY IN USE` is documented at 146 and 182,
and is distinct from `Memory full` at 181.

### The ceiling, derived: $AA00 - $0901 = 41215 bytes

The manual's memory-allocation section did not need reading in the end --
Merlin's own PARMS file already had it (learning:01M041MZER5YQJQYR7JP5N7F01):
source text buffer `SOURCE = $901`, buffer limit `$AA00` ("Don't change
this"). That is 41215 bytes, and every probe run earlier brackets it exactly:

    ~40 KB probe = 40931 bytes   under 41215   assembled
    ~41 KB probe = 41968 bytes   over  41215   56 MEMORY IN USE

So the ceiling is not approximately 40K; it is 41215 bytes, less whatever the
top-level source occupies in the editor buffer.

**The budget charges the LARGEST put, not their sum**, because `PUT` reads a
file in and releases it rather than accumulating (`USE` is the one that
accumulates, which is why this tree uses `PUT` exclusively):

    size(resident manifest) + MAX over puts of size(put)  <=  41215

That distinction is not pedantry. Five kernel modules sat over this line for
a fortnight recorded as "an unexplained capacity limit", after someone
measured put file sizes as a SUM and correctly observed that the sum does not
separate the failures from the successes. The MAX separates all 31 modules
exactly. `check_librel.check_source_budgets()` computes it on the host now,
before anything boots, and prints every module's margin.

**And it is not the only capacity limit.** The SYMBOL TABLE is a second,
independent one, bounded by a different pair of addresses, and **splitting
`put` files does nothing for it** -- splitting changes which bytes are
resident, never how many labels the assembly defines. `sh` is the tree's
worked example: ~9,885 B of symbol table against `as`'s 8,192 B arena, where
seven source splits would have bought the window and arrived at the wall.
Count the labels as well as the bytes before splitting anything
(`9 + sum(len(name) + 4)`); see docs/S9-PLAN.md's tier-2 bullet.

**The symbol table's ceiling, measured (2026-09-12): ~17.5 KB.** The
VT102 console work added 36 kernel globals and real Merlin-8 stopped
with `Memory full in line: 217 >826` at the editor prompt -- no
`Errors:` banner, which check-dual read as a hang. The unit passed at
17,478 B of `9 + sum(len(name)+4)` and failed at 17,700. The kernel
alone is ~16.5 KB of that, so every kernel manifest is within a few
hundred bytes of the wall; `build_maux_src_image.py` now prints the
per-unit figure. Operator ruling the same day: stop grinding against
Merlin-8, cross-assemble with merlin32 (the assembler of record) and
leave the byte-identity proof to nas -- so `check-dual` is PARKED out
of the sweep (Makefile), runnable by hand on the leanest manifest.

**The escape hatch is closed for us, specifically.** PARMS has a V-bit --
`$C3` instead of `$83` -- that "will cause ProDOS to be moved to aux memory
and Merlin to load into main memory". For maux that is not an option, it is
the trap: aux memory IS the process space, one bank per process. We must ship
`$83` and assert it. For exactly the kind of system most likely to need the
room, 41215 is a hard floor.

### sched.s now fits; process.s needs a real split

`scripts/shrink_source.py` moves the largest mid-file comment blocks into the
module's docs/a2 text file, leaving one-line pointers, until the module fits
the buffer. On sched.s: two blocks, 69 lines, 44433 -> 40867 bytes,
byte-identical.

Proof it worked, on the real thing: sched.s plus the three equate files
assembled under Merlin-8 with **no memory error**, emitting 766 bytes. Its
only remaining complaints are `Unknown label` on K_SWITCH, K_TARGETBANK,
K_TARGETSP, K_RESULT, K_RESULT_ERR -- all defined in entry.s, i.e. exactly
the cross-module symbols `make check-modules` has been tracking as "45
symbols cross kernel module boundaries". Those become EXT/ENT under REL.
That is the boundary ratchet's whole purpose, confirmed against real Merlin.

Status against the 41215-byte buffer:

    every module                    fits
    src/kernel/process.s   86776    OVER by 45561

process.s is the last one, and comments cannot save it -- only 4765 bytes sit
in extractable blocks. It needs a genuine source split, which is task #8's
work anyway.

Note: `make check-bytes` runs `make clean`, so it removes build/merlinsrc.po
and build/mauxsrc.po. Rebuild both before driving the emulator.

### Task #7 achieved: `make check-dual`

Real Merlin-8 2.59, running on the emulated //e, assembles the maux kernel
with **Errors: 0** and produces a **byte-identical 12288-byte image** to
merlin32's. That is the dual-assembly gate, and it is now `make check-dual`.

It is the only gate here with no model of Merlin inside it. Every other check
-- line length, label length, module boundaries -- encodes something measured,
and each was at some point wrong or incomplete. This one just asks the real
assembler.

Getting there needed process.s split, and then four more things:

**1. The top-level must be a thin MANIFEST.** The buffer holds the resident
top-level source AND the PUT file being read. Every module fitting 41215
individually still died, because the 13 KB test harness stayed resident while
a 34 KB equate file loaded beside it. Each image's body now lives in its own
`*b.s` module and the top-level is just directives plus a PUT chain (largest
manifest 3.5 KB). scripts/shrink_source.py enforces MODULE_MAX = 37000.

**2. No EQU may be defined after its first reference.** `Illegal forward
reference`. Two flavours:

* Length equates (`X_LEN equ END-START`) referenced earlier. The VALUE still
  came out right -- Merlin resolves it in pass 2 -- but it counts as an error.
  Fixed by deleting the equate and using the label subtraction directly at
  each use, which is legal: forward LABEL arithmetic assembles fine.
* Plain constants (`PTRP equ $E6`) referenced earlier. This is the genuinely
  broken one the manual warns about -- a zero-page value not known in pass 1
  gets sized as absolute. Fixed by hoisting to the head of the file.

**3. Substituting a symbol by an expression is unsafe without parentheses.**
The first attempt at fix #1 rewrote `PFXLEN` to `PFX_END-PFX` everywhere,
which turned `#SH_PTHFLL_LEN-PFXLEN-1` into
`#SH_PTHFLL_LEN-PFX_END-PFX-1` -- sign flipped on the last term, because
Merlin evaluates strictly left to right and has no parentheses to preserve the
grouping. `make check-bytes` caught it. The lesson generalises: in a
parenthesis-free dialect, textual substitution of a symbol is only safe when
the symbol is the whole operand or the context is purely additive.

**4. A global label ends the local-label scope.** Hoisting those constant
EQUs to just before their first use put a global label in the middle of a
routine and orphaned the `:rdloop` / `:baddisp` locals after it. They go at
the head of the file instead.

Verified `>` binds the whole expression, not just the first term, so
`dfb >END-START` is safe (probed: emits `00 05` for a 5-byte span).


### Task #7 closed: `make check-dialect` over the tree (2026-08-23)

`check-dual` was the instrument; the task owed the gate. `make
check-dialect` (scripts/check_dialect.py, in `check-all`) now enforces
the dialect intersection over every compilation unit -- 83 top-level
manifests and their transitive put chains, enumerated from source by
check_manifests' graph plus the two units outside its glob
(src/bootblock.s, src/check.memmap.s -- review finding N3), never from
a hand-list. Five sections, each carrying something no other gate
watched:

1. **Silent expression divergences.** ANY interior space in an operand
   field (Merlin-8 terminates the expression at the space and treats
   the rest as comment; merlin32 joins the fragments -- and rejects
   free comments, so in a host-assembled unit a spaced operand is
   ALWAYS a join, always a divergence). Plus, on the merlin32-JOINED
   expression: any EQU right-hand side mixing `+`/`-` with a later
   binary `*`/`/`, and any parenthesis outside an indirect-addressing
   form. Why EQU specifically: see "merlin32 is two evaluators" below.
   The first cut scanned only the first operand token (Merlin-8's own
   field rule) and so could not see the joined tail -- review finding
   B1 walked the decisive sabotage through green with one space. The
   repaired rule immediately found TEN LIVE instances in
   src/test/difftestb.s (`da ARGV1, OUT1_PATH` -- Merlin-8 would emit
   half the table), fixed by deleting the spaces, byte-identical under
   merlin32 (same sha before/after).
2. **`dum` placement.** A symbol- or PC-anchored `dum` block that
   precedes still-emitted code in its unit's assembly stream silently
   overlaps it (learning:01M0FNC75R7YSFRNS328WHXMHN's family).
   Literal-address blocks (`dum $FF00`) are deliberate overlays, exempt.
3. **Source-buffer budget.** Per unit: manifest + all `use` files +
   largest single `put` file <= 41215. Ten units are over today --
   sh, ed, ld, as, ls, diff, find, nm, du, sort, all by way of their
   own source plus liba's stdio.s -- and are pinned as a SET ratchet
   (membership may only shrink; bytes are not gated because unit sizes
   drift hourly under parallel streams while membership only changes
   when a unit is split or a new fat unit appears). That set IS S9's
   conversion backlog, stated by the gate every run.
4. **PARMS $83.** The 80-column byte in the embedded blob
   (src/merlin/patches.py) and in the staged /SOURCE/PARMS of
   build/merlinsrc.po must be $83; $C3 sets the V-bit that relocates
   ProDOS into aux memory, which maux owns one-bank-per-process.
   check_dual.py asserts the same byte at run time against the very
   volume it boots (failing CLEANLY, not with a traceback, when the
   staged PARMS is absent -- review finding N4). The task-#7 board
   item, done.
5. **Line/label limits for the units check-modules cannot see.**
   src/bootblock.s and src/check.memmap.s sit outside
   check_modules.py's LONG_LINE_BASELINE globs; their 31 + 23
   over-64-char lines are real Merlin-8 rejections, pinned here as a
   shrink-only ratchet (the files belong to other streams); labels
   gate at zero.

**Teeth, proven before any green was trusted** (nine sabotages, each
verified to change behaviour first, per the house rule):

- EQU-precedence divergence planted in src/kernel/sched2.s
  (`SABLO equ SABW-$04*256` + `dfb SABLO`): both assemblers reported
  0 errors, and check-dual went red with exactly one differing byte --
  `+$0888: merlin8 $00 merlin32 $34` -- the silent class caught by
  byte-identity, which is the property S9's safety rests on.
- PARMS flipped to $C3 on the staged image (read back and confirmed
  $C3 before running): check-dual red at the assertion, exit 1, before
  booting; check-dialect red on the same byte.
- Interior-space forms of the SAME sabotage (`SABW - $04*256` and
  `SABW-$04 *256` -- the exact pair review finding B1 used to walk the
  first-cut scanner): both red under the repaired rule, plus the
  interior-space flag itself; reverted, green after.
- Static scanners: an EQU-precedence line in inc/sched.equ, a
  parenthesized expression, a symbol-anchored `dum` ahead of code, and
  the budget ratchet in both directions (an unpinned over-budget unit;
  a pinned unit gone under) -- all red, all reverted, gate green after.

**The `as` switch, decided on merit: NOT taken.** The board allowed
switching the gate to drive `as` once #8 landed (it landed 2026-08-20).
Declined, for three reasons. (1) Instrument independence: the editor
path has no maux in the loop, so a red means DIALECT, not a kernel
regression from the in-flight S1-S4 streams -- a gate whose failures
need triage against someone else's stream is a gate people learn to
wave through. (2) Fidelity: the editor path exercises real Merlin's own
L/ASM loading, PUT handling and source buffer -- the constraints this
file measures; `as` manages source loading itself (its front end does
FIXNAME/JOPEN, learning:01M0CC62FZ351EBXCAAKX52KAJ), so an as-driven
gate would not test the 41215 ceiling at all. (3) The as-driven
assembly IS S9's own acceptance shape (E2E stage 4, self-hosting):
when the converted tree assembles under maux-hosted Merlin, that gate
arrives with S9 and tests what S9 actually ships. Revisit then.

### merlin32 is TWO evaluators -- the precedence divergence, sharpened (2026-08-23)

The section above ("Expressions: no precedence, no parentheses")
recorded `2+3*4` = 20 under Merlin-8 and 14 under merlin32. Probing
merlin32 v1.1.10 per-context while building check-dialect shows the
truth is narrower and stranger -- merlin32 is internally inconsistent:

    context                      merlin32          Merlin-8
    dfb/da/ds/lda # (inline)     LEFT-TO-RIGHT     left-to-right
    EQU right-hand side          C PRECEDENCE      left-to-right
    parens, inline               rejected          rejected
    parens, EQU                  rejected          rejected

Probe bytes: `dfb 2+3*4` -> $14 (20, L2R) but `FOO equ 2+3*4` /
`dfb FOO` -> $0E (14, precedence); `dfb 2+20/2` -> $0B (11) but
`BAR equ 2+20/2` -> $0C (12). The Merlin-8 column's EQU cell is
HARDWARE-confirmed by the sabotage above: real Merlin emitted $00 for
`SABW-$04*256` = ($1234-$04)*256 taken left to right, with 0 errors.

So the silent divergence lives exactly in EQU definitions -- and the
deadliest shape is the hi/lo idiom `LO equ W-HI*256`, which merlin32
resolves as intended (W-(HI*256)) and real Merlin as (W-HI)*256, both
silently. That is what check-dialect section 1 scans for, and why it
scans EQU lines only: inline operands agree between the assemblers.
(Commons note appended to learning:01M051DJW89KV4JYM1EC9SDZ5Y.)

### PUT reclaims its buffer space; USE does not (2026-08-23)

learning:01M0CC62FZ351EBXCAAKX52KAJ records "PUT never reclaims" from
the DECD HIMEM copy loop. Reading the loop in context
(vendor/merlin/ASS.BNK1.S, `USE`/`PUT` at the lines around 1336-1364)
shows that loop is guarded by `PLP / BEQ WASPUT` -- it runs ONLY for
USE, whose file is copied below HIMEM and stays resident (HIMEM is
never raised; each USE permanently spends buffer). A PUT file loads at
ENDSRC+1, past the resident top-level, and the NEXT put reuses that
region. Empirical anchor: the PTEST unit's put chain is 40 files and
448,518 bytes, and real Merlin assembles it inside the 41,215-byte
buffer -- impossible under a cumulative model. So the budget rule is:

    resident (manifest + every USE file) + LARGEST single put <= 41215

which is what check-dialect section 3 computes. This also retroactively
explains why the 54 use->put conversions above were the fix and not
just a tidy-up. Two adjacent facts from the same source read: real
Merlin-8 REJECTS a nested PUT loudly (`PUTFLG` check -> PUTERR) where
merlin32 silently never loads it -- so the tree's no-nesting structure
is doubly safe; and a PUT inside a macro is likewise refused (MACFLG in
the same check). (Correction appended to the commons learning.)

### Parallel gate runs, measured (2026-08-23; PLAN sec 4's open question)

**Question:** gates spawn their own `mcp_supervisor` each, so parallel
worktrees could gate concurrently -- but workers share a fixed cwd, and
the quiet-rig rule predates the per-tree checklog fix. Is concurrent
gating actually safe?

**Method.** (a) Source inspection of the shared surfaces: the worker
cwd (verilogapple/sim/top), every fopen/ofstream in mcp_server.cpp and
the worker, and the supervisor's popen. (b) Before/after snapshot of
the shared cwd across all trials. (c) Trials on the fast backend:
10 quiet sequential boot gates; 5 rounds of 2 simultaneous boot gates;
12 boot gates hammering WHILE a full `make check-dual` (mount, type,
real-Merlin assembly, disk write-back, byte-compare) ran alongside.

**Results** (restated 2026-08-23 after adversarial review, finding B2
-- the first cut of this section counted its 10 quiet-control runs as
concurrent evidence and overclaimed "safe"):
- Correctness: all 23 CONCURRENT-condition runs, plus the 10 quiet
  controls, produced correct results -- every boot gate found its
  needle, and one full check-dual running under a 12-gate hammer
  reported the same byte-identical 16,384-byte kernel as quiet. No
  false GREEN and no cross-contamination path was found by inspection
  or observed. All trials were the FAST backend; rtl -- the heaviest,
  most timing-sensitive leg -- was NOT tested under load.
- Shared cwd: byte-for-byte untouched across all runs. Gate workloads
  write only to caller-supplied absolute .po paths, which are per-tree.
- The historical smoking gun reproduced: `libc++abi: terminating due
  to uncaught exception ... mutex lock failed: Invalid argument` --
  0/10 quiet vs 3/23 concurrent in the original trials, and it can
  appear MID-RUN with the run still completing correctly. Two
  supervisors share no memory, so it is a race INTERNAL to the harness
  (upstream candidate, task #9). A later re-run on a busier box saw
  the marker in a strictly SEQUENTIAL run too -- it tracks load on the
  BOX, not only gate concurrency.
- The historical FALSE-RED class is NOT explained away: the recorded
  6-red concurrent check-all (all six green individually) and the
  phantom bisection hang carried NO mutex message, and this stream's
  own sweep saw check-ascore-process die silently once under load and
  pass quiet. A clean marker scan therefore does NOT certify a loaded
  red.

**What the evidence supports -- no more.** No false-green or
cross-contamination path was found by inspection or in 23 concurrent
fast-backend runs; false REDS occur under load at >=13% per sweep-scale
sample; every red or hang seen under load must be re-run quiet before
it is believed; and ACCEPTANCE SWEEPS STAY QUIET -- the quiet-rig rule
stands for anything that certifies a branch. What concurrency buys is
day-to-day iteration: a developing stream may run its own gates while
others work, treating any red as unproven until quiet. Operational
rules: (1) the supervisor binary must exist before parallel runs start
-- two trees cold-building it concurrently race in obj_dir (the one
shared write left); (2) never call `trace_capture` without an explicit
per-tree path (its DEFAULT is a fixed /tmp file -- the single fixed
shared path in the tool surface; no gate uses it today); (3) the mutex
marker in a log means that run is suspect regardless of its color.
The measurement is re-runnable: `scripts/measure_parallel_rig.py`
(supports --backend rtl for the leg this measurement owes).

### Gating on the box: one tree per BRANCH (2026-09-16)

`box_gate.sh` rsyncs the working tree to
`~/$TREE` on the box with `--delete`, so two callers sharing one `$TREE`
clobber each other. The default is now derived from the CHECKED-OUT
BRANCH: `src/maux` for main (the human's habit is unchanged), and
`src/maux--<branch>` otherwise with slashes turned into dashes, so
`fix/gate-infra` syncs to `src/maux--fix-gate-infra`. The project part
is the MAIN checkout's directory name (`git rev-parse --git-common-dir`),
not the local one, so every worktree of one repo shares a prefix and
sorts together in `ls ~/src`. The rule this replaces keyed the name on
the LOCAL DIRECTORY, which reads fine for a hand-made worktree and not
at all for an agent's (`src/agent-aa1550e05091c6b4d`) and still let two
agents working the same checkout collide. `BOX_TREE` still overrides --
use it for a scratch tree or to share one deliberately.

Each tree is a full build (~450-500 MB on the box; its first run there
pays `make image play-image` from scratch, ~60 s), so
`sh scripts/box_gate.sh --prune [DAYS]` lists every maux tree on the box
with no file touched in DAYS (default 14) and their sizes; `--force`
then removes exactly those by explicit name, never `src/maux` or this
checkout's own tree.

### `play-image` is PHONY, and the parallel sweep raced on it (2026-09-16)

The sporadic `make: *** [Makefile:1800: play-image] Bus error` reds in
`make check-all-box-par` -- on gates like check-plasm, check-jobctl-b,
check-proshim, check-nas, check-mlival, check-play80, check-plasma, which
never boot `build/play.po` themselves -- were two lanes running the image
BUILDER at once. `scripts/sweep_par.sh`'s serial play lane covers the 23
gates whose DIRECT prerequisite line names `play-image` (they BOOT the
shared image); the 13 gates that reach it TRANSITIVELY through their own
image sit in 13 other lanes, and phony means make re-runs the recipe for
each of them. The loser's `mmap` of the file the winner had just
truncated faulted. Measured on the box before the fix: six rounds of two
concurrent `make play-image`, six failures -- one `Bus error`, five
`FileExistsError: '/BASIC/DEMO' already exists` (the softer shape, two
builders staging into one mounted volume).

What was NOT the fix: the sweep's `make -s image play-image $images`
pre-build cannot help, because a phony target has no up-to-date state to
leave behind. Making the lane transitive pulls ~44 gates into one serial
lane and roughly doubles the sweep. Making `play-image` a real file
target would defeat the reason it is phony -- a gate boots it
WRITE-THROUGH and leaves its own files on the volume, so it has to be
regenerated per gate rather than kept by mtime (the Makefile says the
same over `ed-image` and `mli-image`).

The fix is in the builder: `scripts/imglock.py` gives
`build_play_image.py` (and `build_proshim_image.py`, whose image
check-proshim and check-mlival rebuild from two lanes) an exclusive
`flock` on `<image>.lock` plus a staged temp file published by
`os.replace`. Concurrent builders queue instead of racing, and no reader
-- another builder, an emulator's mmap, a derived image's `copyfile` --
ever sees a half-written image. A build is ~0.1 s, so the queueing costs
nothing measurable. After the fix, 24 concurrent builds of play.po and
proshim.po across six rounds: 24 rc=0, zero Bus errors, no leftover temp
files. `sweep_par.sh` now also WARNS (stderr, silent otherwise) when an
image target is reachable from more than one lane and its builder does
not import `imglock` -- the named trigger for the next one.

Note for anyone diffing two play.po builds: they are NOT byte-identical.
The volume carries wall-clock ProDOS timestamps, so the md5 changes
every build; that is long-standing and unrelated.

**The neighbour this uncovered: two gates BOOTING one image.** With the
builder race fixed, a second sweep still went red once -- `check-proshim`
reporting `/BASIC/SHIM/T2 unreadable after the run`, the file its own
tenant had just written. `check-proshim` and `check-mlival` both pass
`$(PROSHIMIMAGE)` to their checker, so both BOOT `build/proshim.po`
write-through, and they share no make edge, so `sweep_par.sh` put them
in two lanes (their two logs are one second apart). That is the header's
hazard 3, HIDDEN SHARING, and it predates the builder fix -- it is the
family the PROCIO note meant by "the documented parallel-lane
`play-image` driver race". They are now a `SWEEP_GROUPS` pair, one
serial lane, and the lane partition WARNS whenever two lanes name one
image on their own recipe lines. Exactly one pair in the sweep does
today; the audit that says so is the same walk of make's database the
warning runs.
