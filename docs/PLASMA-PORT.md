# PLASMA on maux -- the native VM port (maux's "B")

Current boundary, 2026-09-19: the VM/runtime and on-target `plasm` compiler
run on maux. `check-plasm` proves a supported source compiles and runs; it
does not prove the compiler or NAS rebuilds itself. Production NAS still
uses host xplasm, ACME and the Python cooker. See [NAS.md](NAS.md) and
[PROJECT-STATE.md](PROJECT-STATE.md). Milestone timings below are dated
porting evidence, not current NAS performance figures.

Dave Schmenk's PLASMA (github.com/dschmenk/PLASMA, now PLEIADES; fork
emdeejay/PLASMA, cloned at `~/src/PLASMA`) is a word-oriented language
compiled to compact bytecode and run by a small VM, PLVM, self-hosting
on a 6502. That is exactly B's role on early Unix -- the systems
language one notch above assembly, riding a tiny threaded-code VM
because the machine was too small for a native compiler -- and maux is
an early-Unix recreation. So this port gives maux its B: the layer
where the userland stops being all hand-cut 6502, and the enabler for
tools that are insane in assembly (a lex, eventually an awk, a better
`as`). Commons: `learning:01M1XVKAY4N8QCVHTXH9N40N42` (the architect
read, with its dated correction) and `learning:01M1DKF0XYWX70VJ7WT8C41P1T`.

This is the NATIVE route -- PLASMA as a first-class maux program,
PLASMA code as maux processes -- not the proshim/ProDOS-tenant route
(that road is EDASM and BASIC, docs/EDASM-SHIM.md). Ethos throughout:
worse-is-better. Seed the VM once in assembly, wrap what works, let the
language build itself from there.

## Why the port is small

The hand-written seed is only the interpreter: `plvm02.s` (~1,600 lines
of ACME) plus a maux loader/glue. Much of the higher layer is
PLASMA that compiles to bytecode and runs ON the VM -- the module
loader/linker (`loadmod` in `cmd.pla`), the heap, and the compiler
itself (`plasm.pla`). This is the intended bootstrap shape, not evidence
of a closed maux bootstrap; native blocks and the production packaging
chain still use host tools.

## Memory model (settled 2026-09-07/08, operator rulings)

PLVM's ProDOS layout -- load at `$2000`, copy the core into the
language card at `$D000`, frame stack down from `$BF00` -- is a
ProDOS artifact and is NOT transliterated. The maux layout:

```
$0000-$00FF  ZP: PLVM's plvmzp.inc VERBATIM (ESTK $A0-$DF, X-indexed;
             VMZP $E0..; the inner loop at DROP=$EF; IP=$F2). This is
             the ABI inline-asm in compiled modules assumes -- never
             rearrange it. It is safe: the kernel runs on the other
             ALTZP side and preserves process ZP across `JSR $FF00`.
$0100-$01FF  hardware stack (the seed leaves S as the kernel set it)
$0200-$07FF  KERNEL-OWNED argv/env block: argc at $0200, pointer pairs
             from $0201, packed strings from $0300 (ARG_MAX = 1280 B).
             This -- not the text page -- is why LOAD_BASE is $0800.
             It is restaged on every warm relaunch, so nothing of ours
             may live here; the seed only READS argv at start.
$0800        `org LOAD_BASE`. Entry jump table, the maux interp ABI:
               $0800 jmp START   $0803 jmp DINTRP   $0806 jmp IINTRP
             (replaces PLVM's $03D0/$03D6 page-3 vectors, which would
             sit inside the argv strings; compiled modules never
             reference $03D6 -- verified against a def-bearing module
             -- the address is loader-private, so it is ours to move)
$0900        OPTBL, page-aligned: the 256-byte-indexed opcode->handler
             word table the ZP `JMP (OPTBL)` dispatches through
$0900+       the interpreter core + START/loader + parmlists, packed;
             then the bss arena (the kernel zeroes its first page)
  ...        FRAME STACK region: from the image+bss end up to $2000,
             >= 1 KB by assertion. IFP starts at $2000 (one-past, the
             PLVM convention) and grows DOWN, as ENTER/LEAVE already do.
$2000        BRK = the module load address = maux's module base = the
             heap base. Modules + heap grow UP from here. Graphics
             mode (later): heap base $4000 keeps hires page 1 free.
$BF00        no longer special -- nothing of the VM lives at the top.
LC $D000     NEVER touched. The VM runs entirely in main RAM.
```

Why each of those, briefly:

- **Main RAM, no language card.** Parking the core in `$D000` would
  cost a `$C088` (LC_KRN_RO, the steady state every syscall expects)
  / `$C083` bracket around every syscall, trampolines that must live
  in main RAM, and the hazard of switching a bank out from under
  executing code. In main RAM the VM is a plain program. Worth far
  more than the 4 KB the LC would have hidden.
- **The frame stack is low, not at `$BF00`.** A stack at the window
  ceiling pins the process extent to `$0200..$BFFF` regardless of
  program size, defeating "keep BRK low" and forcing whole-window
  bank copies (fork copies `[PRC_LOWFREE, PCB_BRK)`). A bounded low
  region is a one-line change (IFP's init value) and strictly safer
  than PLVM's unprotected frame/heap collision.
- **BRK = `$2000` = the module base**, and `brk` is real: `PRC_BRK`
  (SYS_BRK 5) takes a 3-byte parmlist (value lo/hi, mode 0=SET /
  nonzero=GROW), rounds to a page, floors at the process's own load
  base, limits at `$BF00`, and "a SET must come first -- the kernel
  never invents an initial break." The seed's first act is
  `brk(SET,$2000)`; after loading a module it SETs the break past it.
- **Modules are assembled with base `$2000`** (`acme --setpc 8190` --
  the 2-byte length word at `$1FFE`, image at `$2000`). The compiler
  emits relocatable source and `--setpc` picks the base, so RELADDR
  is a maux convention. Milestone 1 raw-loads a module at `$2000` with
  zero fixups; the real loader (milestone 2) relocates modules placed
  elsewhere via `modofst = modaddr - $2000`.
- **Text-immutable seed.** Lazy-free warm-reuses a bank WITHOUT
  recopying the image (it fingerprints the first 8 bytes at the load
  base), so the seed never writes its own text: the 16-byte inner-loop
  template is read-only text copied INTO ZP at start, the init thunk
  is built in bss, OPTBL and the jump table are static.

## The seed's contract (milestone 1: `plasma PATH`)

Raw syscalls, liba-free (liba's PTR0 at `$E0` collides with VMZP):
`A`/`X` = parmlist lo/hi, `Y` = call number, `JSR $FF00`, carry set =
error. EXIT=2, BRK=5, OPEN=$C8, READ=$CA, WRITE=$CB, CLOSE=$CC.

1. argv[1] (ARGC at `$0200`, pointer pairs at `$0201`, high-bit-set
   NUL-terminated strings) -> a count-prefixed 7-bit MLI pathname.
   No argument: `usage: plasma MODULE`, exit 2.
2. `brk(SET, $2000)`.
3. OPEN; READ the 2-byte length word to scratch; READ the image into
   `$2000` in `$0800` chunks until short; CLOSE.
4. `brk(SET, $2000 + length)`.
5. Magic word at `$2000` must be `$6502`.
6. init = the word at `$2008` (file offset 10 -- the module header:
   length, magic, sysflags, bytecode subseg, defcnt, INIT, then the
   dependency list, then code). 0 = nothing to run.
7. VM env: copy the inner-loop template to `$EF`; `$4C` into JMPTMP;
   IFP=`$2000`; X=ESTKSZ/2; build the def thunk `JSR $0806 / da init`
   in bss and `jsr` it. When it returns, exit 0.

A def thunk is 5 bytes -- `JSR <IINTRP vector> / da bytecode` -- which
is what `cmd.pla`'s `adddef` builds; IINTRP pulls the return address
and reads the bytecode address from the two bytes after the JSR.

## The .mod format (from `loadmod`, confirmed against a real module)

128-byte header: `modsize` at `:0`; magic `$6502` at `:2` (an EXTended
data+bytecode module); `systemflags`; `defofst` (the bytecode
subsegment); `defcnt`; `init`; then a DCI-encoded DEPENDENCY LIST.
Then the image; then at `modend` the RLD (Re-Location Dictionary,
4-byte entries: `$02` = bytecode def, else a relocation, `& $10` = an
external reference) and the ESD (Entry/External Symbol Directory: DCI
names + flags, `$08` export, `$10` import). Linking is recursive
dependency loading. A classic 6502 REL object -- a cousin of maux's own
REL/`ld`/ENT-EXT world.

## Toolchain

The VM seed is maux source (merlin32 dialect, `src/bin/plasma*.s`,
built as part of the native `nas` + `ld` world). Production PLASMA modules
are compiled on the host: locked `xplasm` writes `<input>.a` beside its
input and ACME assembles modular output with `--setpc 8190`.
Use the Makefile and [dependency bootstrap](DEPENDENCIES.md), not an
unversioned sibling checkout. The current runtime gate uses
`src/test/plasma/hello2.pla` and `build/hello2.mod`; `hello.pla` is the
historical milestone-1 fixture.
The ZP equates a module's inline asm needs come from `plvmzp.inc`
(a per-platform copy the PLASMA build creates); the fixture inlines
them so maux never depends on PLASMA's include path.

The on-target `plasm.pla` compiler already runs on maux (milestone 3),
but its parser does not accept NAS's inline `asm` blocks. It has not
replaced the production NAS host build or cooker. Closing that bootstrap
boundary is deferred during consolidation.

## Milestones

1. **The seed** (DONE, `plasma.bin`): `plasma hello` prints through a
   raw maux syscall from inside a module. Proves the interpreter in a
   maux bank, the loader, CALL into native, and the syscall path. Gate:
   `check-plasma` (now runs the M2 fixture; the M1 raw-syscall hello was
   retired -- its inline asm uses absolute self-refs the compiler does
   not relocation-fix, so it loads only at its `$2000` assembly base).
2. **The runtime** (DONE, `src/plasma/rt.pla`, staged `/BASIC/PLRT`):
   `cmd.pla` minus the shell -- `loadmod` (relocation, dependencies,
   the def directory) as the bundled loader; the heap over `sbrk`; a
   maux cmdsys (console -> fd 1/0, syscalls on `$FF00`, SYS_* == the
   MLI numbers). Built FLAT (`-AOW --setpc 8192`, self-linked, JMP
   `_INIT` at `$2000`) because rt IS the loader -- an `-AMOW` rt would
   need the very def-thunks it hasn't installed yet. Gate `check-plasma`
   runs `hello2` (`import cmdsys` + `puts`), exercising loadmod's
   relocation onto the heap + ESD import binding in one line.
3. **Self-hosting: plasm on maux** (DONE 2026-09-08, gate
   `check-plasm`): `plasma PLASM t.pla t.mod` compiles a source
   to a module and the compiled module runs. plasm's dependencies
   (ARGS, FILEIO, LONGJMP; CMDSYS is rt, resident) load from
   `/BASIC/PLLIB/` via rt's `syspath` -- NOT `/BASIC/PLASMA/`, which
   collides case-insensitively with the `plasma` util. FILEIO is
   maux's own retarget (`src/plasma/fileio.pla`): kernel-owned
   `io_buffer`s (open passes `$0000`), MLI NEWLINE emulated in the
   read path (READ then scan for `(byte & emask) == nlchar`, SET_MARK
   back), and `a2close` no longer refuses an untracked refnum (an
   upstream bug). THE FINDING: `plasm.pla` hardcodes
   `const RELADDR = $1000` (upstream's ProDOS default); maux's
   convention is `$2000`. Left at `$1000` plasm emits a well-formed
   `.mod` whose every RELADDR-derived header field (defofst, init) is
   exactly `$1000` low, so loadmod jumps `$1000` short into rt's own
   data and spins silently. Fixed by a build-time `sed` on a SCRATCH
   copy of the sibling checkout (`build/plasmasrc/`), never the
   checkout itself. Now: the better `as`, the lex, the awk -- written
   in PLASMA, profiled by sampling IP at `$F2` (a PLASMA-aware profile,
   not PC), hot loops dropped to native.

## Cooked binaries: `plascut` (2026-09-13, docs/PLASCUT.md)

A PLASMA program spawned as `plasma MODULE` re-reads rt and re-loads/
relocates/binds its whole module closure on EVERY launch, so lazy
free's warm respawn covers only the 3 KB seed. `scripts/plascut.py`
does that `loadmod` work ONCE on the host and writes seed + rt +
modules (relocated, bound, def-thunks built) as one flat `$0800` BIN
the kernel spawns like `ls`. A cook block in the seed (`plasmald.s`
`CKFLAG`/`CKEND`) and in rt (`rt.pla`, found by `CKPL` magic) makes the
cooked launch skip the load, restore its mutable data from appended
pristine copies (a warm bank arrives dirty -- STICKY.md sec 27), run the
module inits, and exit with the main module's status. Measured 6.8 M
cycles / ~21 % off a warm nas invocation; gate `check-plascut`. This is
what lets `nas` run from `make`. **A ported rt bug it surfaced:**
`byte cmdln = ""` was one byte and `buildcmdln` overran it into the
CMDSYS string table -- safe only in the seed path, which consumes those
strings first; the cooked path made it a silent layout-sensitive
command-line truncation. `cmdln` now has its own buffer (82 bytes then; PLASM-FIX made it 127
characters + length + the NUL argFirst writes, and bounded the build).

## PLASM-FIX (2026-10-22): plasm on the release disk

The command line a PLASMA program sees starts with its own name (Dave's
convention; plasm discards it with `argNext(argFirst)`), the FILEIO
retarget reads text in either maux convention, `inc/...` falls back to
/usr/inc, and rt no longer carries a static symbol table. Everything is
in docs/PLASM-FIX-NOTES.md; the gate is `check-plasm-full`.

## Design decisions to hold onto

- **Take the loader, leave the shell.** `cmd.pla` fuses the
  loader/linker (keep) with the CMD REPL and its ProDOS file built-ins
  CAT/DEL/REN/COPY/TYPE (drop -- maux has `cat`/`rm`/`mv`/`cp` and
  its own `sh`). `plasma MODULE` is a maux process under maux's `sh`;
  module chaining maps onto maux `spawn` later. Everything below CMD
  is PLASMA; the shell and userland stay maux's.
- **Rearrange the memory map freely; never the ZP contract.**
- **Profile before native-izing.** Build in PLASMA, sample IP, drop
  only the measured hot spots to native.
