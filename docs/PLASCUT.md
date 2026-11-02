# plascut -- the plasma cutter: a cooked, spawnable binary from a PLASMA program (2026-09-13)

Current reading note, 2026-09-19: the mechanism below remains the host-side
production cooker, not an on-target compiler or general AOT pass. The
25.6M/32.5M measurements describe the 2026-09-13 implementation. Use
[NAS.md](NAS.md) for today's build path and
the cumulative figures there for current performance.

`plascut` turns a PLASMA program (rt + its module closure) into ONE
flat maux binary the kernel spawns like `ls` -- no VM boot that reads
rt off disk, no `loadmod` that reads/relocates/binds each module every
launch. It exists so `nas` (docs/AS-PLASMA.md) can run from `make`
without spending half its wall-clock respawning its own toolchain.

Status 2026-09-13: SHIPPED. `scripts/plascut.py`, the cooked rt init
path (`src/plasma/rt.pla`) and seed branch (`src/bin/plasmald.s`),
gate `check-plascut` (in `CHECK_ALL_TARGETS`). Measured on the
verilogapple fast backend: a warm `nas -o T.OBJ FIXTURE.S` costs
**25.6 M cycles cooked vs 32.5 M modular -- 6.8 M cycles / ~21 % saved
per invocation**, and the cooked object is byte-identical to
merlin32's, cold and warm.

## 0. The problem, in one measurement

`plasma NAS -o x y` today does this on EVERY spawn:

1. kernel spawns the 3 KB seed (`plasma.bin`);
2. the seed reads the 8 KB `rt.mod` off disk into `$2000` and jumps in;
3. rt's `loadmod` reads `NAS.mod` (16.5 KB), walks its dependency list,
   reads and relocates `FILEIO.mod` (2.6 KB) and `ARGS.mod`, binds
   every import against rt's export table, builds a def thunk for every
   one of ~160 bytecode defs, applies ~1,100 relocation-dictionary
   fixups, and only then runs nas.

Steps 2--3 are ~19 KB of file I/O plus a full link, redone identically
every launch, because none of it lives in the spawned image -- so lazy
free's no-copy warm respawn (docs/STICKY.md sec 27, 8.1x on `ls`) can only
ever cover the 3 KB seed. `make` running nas over a tree pays that link
once per file. The `check-plascut` PC4 measurement puts the redone work
at 6.8 M cycles.

## 1. What plascut does: loadmod, once, on the host

`plascut.py MODULE -o OUT.cut` is a host-side transcription of rt's
`loadmod` (`src/plasma/rt.pla`, lines ~1106--1274 -- read that first;
every rule in `scripts/plascut.py` is one of its lines):

1. lay the seed at `$0800` and `rt.mod` (flat) at `$2000`; the heap
   starts just past rt;
2. load the main module's dependency closure depth-first, each once,
   binding `CMDSYS` from rt's own export table (the addresses rt's init
   would register). Per module: a def table (`defcnt*5+1` bytes) then
   the image, exactly where loadmod's bump allocator would put them;
3. apply the module's RLD -- `$02` def entries become `JSR $0806 / da`
   thunks; `$8x` 16-bit internal fixups (a target past the bytecode
   subsegment resolves to its thunk, via lookupdef); `$4x`/`$0x` byte
   fixups; `$1x` external fixups add the bound export to the addend in
   place -- and record ESD exports/imports;
4. append an **init list** (each module's init thunk, in load order)
   and a **restore table** (sec 3);
5. patch two things and write `$0800..cookheap` as a BIN: the seed's
   `CKFLAG`/`CKEND` header, and rt's cook block.

The output is an ordinary `$06`/`$0800` binary. Stage it at
`/BASIC/BIN/NAS` and the shell spawns `nas -o x y` through its normal
PATH walk (`src/bin/shpath.s`). `make` spawns it the same way.

## 2. The two runtime hooks

**The seed (`src/bin/plasmald.s`).** A 5-byte header sits right after
the entry jump table at `$0809`: magic `CK`, a flag byte, and `CKEND`
(the cooked image's end). `plascut` sets the flag and end in the file;
the running seed never writes them (it must stay text-immutable for
lazy-free warm reuse, docs/PLASMA-PORT.md). On a cooked flag, `START`
skips the usage check and the rt-load entirely: `brk(SET, CKEND)`, set
up the VM env, `JMP $2000` -- the same tail the loaded path takes.

**rt's init (`src/plasma/rt.pla`).** A cook block (found by `plascut`
via its `CKPL` magic -- rt is flat, nothing relocates) carries the init
list, the heap value, the restore table, and the argv base. When it is
non-zero, rt's init does NOT register CMDSYS or `execmod` argv[1] (both
already done on the host); it restores the writable data (sec 3), takes
the cooked heap, builds the command line from `argv[cookargs..]`, runs
every module init in load order, and **exits with the last init's
return** -- the main module's own status. (The seed path's `execmod`
discards a module's positive return, an upstream cmd.pla inheritance;
the cooked path does not, which is what lets `make` stop on a nas
error. Gate leg PC3.)

## 3. The one thing the host cannot pre-compute: mutable data

A cooked binary is its own data segment, and every run mutates it
(rt's `heap`/`perr`/command line, each module's data). Lazy free hands
a warm respawn the SAME bank with the previous run's dirty data still
in it (docs/STICKY.md sec 27 -- it recopies nothing). So `plascut` appends,
after the modules, a **restore table** of `(dst, src, len)` triples
plus a pristine copy of every writable range: rt's `[$2003, @symtbl)`
and each module's data segment `[image, bytecode)`. rt's cooked init
`memcpy`s them back before running any init. The fixture
`src/test/plasma/cookt.pla` increments a module global and prints it;
cooked, it must print `RUNS=0` on every launch. Gate leg PC1 runs it
three times; the teeth (restore disabled) make the 2nd launch print
`RUNS=1` -- which also proves the launch was warm, since a cold load
would print 0 regardless.

**Constant tables need no copy (`--const-prefix MODULE`, 2026-09-15).**
The pristine copy is charged against the cooked program's heap, and a
module whose data is mostly read-only tables pays for them twice:
nas's 5.2 KB data segment held 2.8 KB of opcode/directive/hash tables,
and the cutter's heap for the assembler's own symbol table had fallen
to 6.5 KB (27 programs "not staged"). A module named with
`--const-prefix` declares its constant data FIRST and marks the first
mutable global with `word mutmark = $5AA5, $C33C`; plascut finds that
4-byte mark in the module's data (exactly once, or it refuses) and
restores only from the mark on. nas: cooked 39.0 -> 36.2 KB, heap 7.8
-> 10.7 KB. The rule is the author's to keep -- a mutable global
declared above the mark is silently not restored across a warm
respawn; check-nas-selfmake (198 warm nas runs under make) is the gate
that would show it.

**PLASM-FIX update (docs/PLASM-FIX-NOTES.md).** Three things changed in
the cooked contract: (1) a pristine run of 12 or more zero bytes is not
copied -- its restore entry has src 0 and rt `memset`s it; (2) the
command line now starts at the program's own name (`cookargs` is 0 in a
cooked image, 1 on the seed path), as on Dave's system, so a tool reads
its arguments after `argNext(argFirst)`; (3) rt's symbol table is no
longer 4,096 static bytes in every image -- it is allocated on the heap
by the seed-path init, and a cooked image has none (no loader).

## 4. A bug this surfaced, worth stating on its own

Building the cooked path exposed a latent hazard in the ported rt:
`byte cmdln = ""` reserved exactly ONE byte, and `buildcmdln` writes up
to 80 bytes of command line into it, overrunning into the CMDSYS string
table that follows. The seed path survived only because its init
consumes those strings (the `while *sysmodsym` registration loop)
BEFORE `buildcmdln` runs. The cooked path binds CMDSYS on the host and
skips that loop, so the overrun corrupted whatever the post-`buildcmdln`
module inits happened to read there -- a **silent, layout-sensitive
truncation** of the command line (adding one unrelated print statement
made it appear and disappear). Fixed by giving `cmdln` its own
buffer (82 bytes then, 127 + 2 since PLASM-FIX); importers reach it through the `syscmdln` pointer, so
the move is transparent. The overrun was always latent; the cooked
path is what made it bite.

## 5. Build & gate wiring

- `scripts/plascut.py` -- the cooker (host Python, like `relink.py`).
- `build/nas.cut` (`plascut NAS`), `build/cookt.cut`
  (`plascut COOKT`) -- Makefile targets `$(NAS_CUT)`/`$(COOKT_CUT)`.
- `scripts/build_plascut_image.py` stages `/BASIC/BIN/{NAS,COOKT}`
  (cooked) alongside the modular `plasma`+`PLRT`+`PLLIB/*` (so the
  gate times cooked vs modular in one boot).
- `scripts/check_plascut.py` (gate `check-plascut`): PC1 restore, PC2
  byte-identity of the cooked nas vs merlin32 (cold, warm, and vs the
  modular object), PC3 nonzero exit on a nas error, PC4 the cooked-vs-
  modular timing. Only one object is byte-checked per session -- a
  second file written in the same session hits a2til's last-file
  write-through flakiness (`check_nas.py` boots fresh per fixture for
  this); stress-fixture byte-identity is `check-nas`'s job on the same
  `nas.mod` plascut packages.

## 6. Scope and non-goals

- plascut does not change a module's emitted bytes -- it changes how the
  program LOADS. nas cooked is byte-for-byte the same assembler as nas
  modular (PC2 proves it three ways).
- It is not a compiler and not an AOT-native expander -- the bytecode is
  unchanged. Making nas itself faster per line is the separate
  AOT-native lever (memory `idea-plasma-aot-native`); plascut removes
  the STARTUP cost, which is what `make` re-pays per file.
- Every cooked program that mutates data needs its ranges in the
  restore table; `plascut` derives them from the module headers
  (rt's `[$2003, @symtbl)` and each `[image, bytecode)`), so this is
  automatic. A program that writes its OWN text (as `as` does, sec 27)
  would need more; no PLASMA module in this tree does.

## Library notes

- `learning:01M1XVKAY4N8QCVHTXH9N40N42` -- loadmod, the .mod format, and
  the PLASMA-on-maux memory model plascut transcribes.
- `learning:01M1Z844RR7Q9X8B3EM7NZWFZ1` -- RELADDR=$2000; plascut's
  relocation uses the same base.
- STICKY.md sec 27 (lazy free) -- why the cooked image's warm respawn
  copies nothing, and why the restore table is needed.
