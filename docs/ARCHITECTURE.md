# maux architecture -- invariants and design history

## Current reading guide, 2026-09-19

maux is implemented. This document preserves the architectural reasoning and
its dated amendments; it is not a current feature backlog. The bank-per-process,
$FFxx entry/vector-page and no-memory-protection invariants remain central.
For current implementation status use [PROJECT-STATE.md](PROJECT-STATE.md),
the subsystem contracts and their source/gates.

In particular, these historical status statements below are superseded:

- `fork()` is wired into the shipping kernel, not only a private test image:
  `src/test/playtest.s` includes the shared `src/kernel/kdisp.s` table with
  `PRC_FORK`, and includes `procfork.s`. Its image copy starts at
  `PRC_LOWFREE` ($0200), not the early $0800 design; see [FORK.md](FORK.md).
- Signals, job control, virtual consoles and the built-in 80-column backend
  are implemented, not all deferred v2 proposals. See
  [CONSOLE.md](CONSOLE.md), [SYSCALL.md](SYSCALL.md) and the live status.
- The native assembly-world rebuild uses `make` + `nas` + `ld`; the old
  real-Merlin milestone is not the release path. NAS and source/media
  preparation still need host tools; see [NAS.md](NAS.md).
- Hardware support is bounded by [SUPPORT.md](SUPPORT.md), not by the old
  target-hardware wishlist or open-question list. Emulator evidence does
  not qualify an unmeasured physical card.

The sections below retain the original design narrative. Treat their
`v1`/`v2`, `pending`, `not wired` and task-assignment wording as historical
unless confirmed by the live references above. Handles are cited as
`learning:<ULID>`; this reading guide does not re-grade hardware claims.

## Core idea

One RamWorks 64K aux bank = one process. ALTZP gives each bank its own zero
page and hardware stack, so a bank switch swaps the register file, stack, and
address space in one motion. Every process sees the same logical address space
from $0000 -- no relocation, stock assemblers work. This is a poor man's MMU
with 64K pages.

**The one-page invariant:** user space is $0000-$BFFF plus $D000-$FEFF -- the
entire $C000-$CFFF window is carved out (always main: I/O at $C0xx, slot and
expansion ROM at $C100-$CFFF; no //e switch ever steers it to aux RAM) --
and the kernel's entire per-bank footprint is $FF00-$FFFF -- the page the
hardware already claims for vectors. Syscall entry, IRQ entry, exit tail, and
the vectors all live there (~250 usable bytes; the stubs are dozens). It sits
in the LC *common* region ($E000-$FFFF), so one stamping covers both $D000
banks, and LC-region instruction fetch is governed by the LC switches -- not
RAMRD -- so the stubs may legally flip RAMRD
(`learning:01KW1GTYGVYAPQRGS5P7J66RWD`).

**No hardware protection -- stated axiom.** Soft switches are plain addresses;
any process can write $C073, flip RAMRD, or SEI. Bank-per-process buys
*isolation for correctness* (a well-behaved process cannot accidentally touch
another), not security. One wild store into $C0xx can take down the system.
Debugging corollary: corruption in process B is evidence about process A.
Convention, not enforcement, also covers: processes run LC-RAM-read-enabled.
Banking LC ROM in is machine-fatal, not process-fatal: the next IRQ vectors
through ROM $FFFE, whose handler scribbles process ZP and jumps through the
process's own ($03FE) with I set -- the machine hangs until reset, the same
DoS class as SEI-forever (which this axiom already concedes). Reset recovers
via kernel-owned main $03F2 -- docs/RESET.md is what that sentence has to
become (what reset can trust, who it kills, when it panics instead).

## Memory ownership

| region | owner |
|---|---|
| main 64K | kernel: code, main ZP/stack, LC RAM, disk buffers, and the main video apertures. Text page 1 plus both hires pages are display-reserved for the console/graphics roadmap (`docs/CONSOLE.md`, `docs/MEMMAP.md`) |
| aux bank 0 | kernel annex + console/video companions: 80-col text aux half, DHR pages, PCB array, pipe rings, per-process kernel structures. Video scanner reads ONLY bank 0 (`learning:01KW1GTYHGXMBZNR6DMQB2F712`) |
| aux banks != 0 | one process each, allocated from a FIXED free list, banks 2-15 (`PRC_INIT`, `src/kernel/process.s`; the shell is bank 1). The shipped kernel does not probe: it needs a RamWorks of at least 1 MB (banks 0-15 present) and runs at most 15 processes. A probed free list is the unshipped design (see Bank management). No physical display holes -- $0400-$07FF / $2000-$5FFF are ordinary RAM in banks 1+, but Apple-software display pokes there are not visible; hosted graphics goes through the tty/graphics APIs or an explicit display-owner mode |

Optional build-time: `CONFIG_INIT_IN_BANK0` coresides init in bank 0's
non-hard-video free regions ($0800-$1FFF, $6000-$BFFF) -- worth it on 256K
cards (4 banks total), not on 1MB+ cards. The `$0800-$0BFF` overlap is only
the soft page-2 reserve.

## Process model

- **PCB**: partly in bank 0 (kernel annex), plus a per-bank identity/PCB page
  inside each process bank ($C073 is write-only -- each bank must self-identify;
  kernel also keeps authoritative `curbank` in main). The annex PCB is the
  source of truth (`ps`, PSTAT); main memory holds two one-byte-per-pid
  shadows the kernel scans instead of 47 cross-bank reads: `K_WAIT_SHD`
  (wait channel while BLOCKED; `SCH_WAKEUP`, WAKE-1) and `K_PAR_SHD`
  (PCB_PARENT while the slot is occupied, 0 free; `PRC_WAIT_CORE`, WAIT-1;
  stored reversed, pid p in cell 48-p). Each only filters: a match re-reads
  the annex. Orphans keep today's semantics (a dead parent's pid stays in
  the child; a reused pid adopts it; nothing reparents).
- **Syscall ABI**: native gate is `JSR $FF00`, with argument transport
  chosen in task #3 (stack-push/register forms leading -- see below); the
  inline `.byte call` / `.word parms` MLI shape belongs ONLY to the $BF00
  compat overlay, never the native ABI. NOT BRK (B-flag discrimination
  taxes every IRQ; BRK pushes PC+2). BRK is not the syscall path
  and there is no debugger: **a BRK in a user process is SIGTRAP**
  (signal 5, wait status $85, `$?` 133) -- the kernel kills the
  process and the machine goes on (KBRK, docs/KBRK.md); a BRK in the
  kernel, in the idle process or in pid 1 still HALTS, marker and
  all. Which BRKs reach the per-bank door: those taken with
  ALTZP=aux, because main's language card has its own `$FFFE`
  (timer.s MAIN_IRQ_SHIM, which parks a kernel-context BRK).
  Accepted gap: the few main-resident kernel windows that run with
  ALTZP=aux (PRC_RWND_FRM, FRK_CLN_ZP/STK, the frame stamps, bye)
  would kill K_CURPID on a corrupted-byte BRK rather than halt.
  **Trapframe contract (review finding A1)**:
  the stub executes `PHP` FIRST (capturing caller P, including a possibly-set
  D flag), then `SEI`/`CLD`, then saves A/X/Y -- frame [PCH][PCL][P][A][X][Y]
  matches RTI pull order once the kernel patches stacked PC += 1 (RTI does
  not increment where RTS does; +3 MORE only when the inline trailer is in
  play, i.e. the $BF00 compat overlay), so one RTI exit tail serves syscall
  and IRQ entry alike. Syscall results return via kernel-patched frame A and the
  carry bit of frame P. **Call-argument transport is a task #3 decision
  (review finding A2 + operator refinement)**, cycle-counted across three
  permutations: (i) inline MLI-shape trailer -- ZP-pointer borrow for the
  indirect read plus the PC patch, slowest; (ii) caller pushes call#/parms
  on the stack -- main kernel code reads $01xx via absolute,X *before the
  ALTZP flip* ($01xx is ALTZP-governed, not RAMRD-governed): no ZP borrow,
  no PC patch; (iii) registers (call# in Y, parms in A/X) -- zero transport
  cost, captured by the trapframe anyway. Leading candidate: (ii)/(iii)
  native; the inline-MLI shape retreats to the $BF00 overlay's translation
  layer, paid only by compat processes. **General user-buffer access (review finding
  A2)**: copyin/copyout primitives resident in MAIN LC (fetch-immune to
  RAMRD) for $0200-$BFFF; process ZP/stack readable from main $0200+ code
  via ALTZP toggling (safe there -- ALTZP steers only $0000-$01FF); the
  ENTIRE $C000-$CFFF window refused with an error (always main -- I/O plus
  slot/expansion ROM, never process memory); $D000-$FEFF via the ALTZP-aware
  LC path, whose spec must name which of the two $D000 banks (both are
  per-process; the selector is part of the address, decided in #2/#3).
  MLI compatibility ($BF00 gate + fake global page) is an OPT-IN overlay
  stamped per process at exec -- and the claim is **Tier 1: MLI FILE calls
  only** (review finding A3). ROM/firmware entry points are not provided; programs
  that bank LC ROM in are unsupported. maux canonicalizes caller LC state
  across syscalls rather than preserving it (LC write-enable is not exactly
  restorable without a destructive probe -- prohfs finding).
- **Kernel entry/exit**: stubs live in each bank's $FFxx page (see the
  one-page invariant above; formerly page 1 -- moved because the stack grows
  down into $0180 and would overwrite a page-1 stub):
  - entry (two doors, one frame -- the trapframe contract, review finding A1):
    the syscall door does `PHP` FIRST (capturing caller P, including D,
    before anything disturbs it), then `SEI`/`CLD`; the IRQ door skips
    those (hardware already pushed P and set I; 65C02 auto-clears D). Both
    then save A/X/Y, yielding frame [PCH][PCL][P][A][X][Y] on the process
    stack, flip RAMRD/RAMWRT->main, JMP kernel ($0200+ main); kernel TSXes
    to capture SP, flips ALTZP->main, **loads the kernel SP before any push**
    (mirror of the exit hazard: until then S indexes kernel page 1 at a
    process-chosen offset); now free to write $C073.
  - exit: kernel writes $C073=target, flips ALTZP->aux -- **critical section:
    no pushes between the ALTZP flip and TXS** (SP still holds the kernel
    value but page 1 is now the process's) -- TXS, JMP target bank's $FFxx
    exit tail; tail flips RAMRD/RAMWRT->aux, restores registers, RTI (one
    tail for both doors -- the frame layout makes RTI valid for each).
  - Every bank's $FFxx page (stubs + vectors) is stamped at creation ("every
    bank has its own $FFFE"). Exact sequences with a per-window
    interrupt-safety argument are task #3's deliverable.
- **NMI: ruled out as a timer source.** Unmaskable means unmaskable by the
  kernel too; an NMI inside a transition window (inconsistent ALTZP/bank
  state) corrupts the switch unrecoverably. IRQ only -- the CPU's I-flag and
  SEI cover every critical window.
- **spawn() is the primary process-creation call (operator ruling,
  v1-scope):** most fork() calls exist to be immediately replaced by exec,
  and on this architecture exec loads into a fresh bank anyway -- so the
  common path is `spawn(path, argv, fdactions)`: allocate bank, stamp
  $FFxx, load image, apply the fd-action list (dup/redirect specs, applied
  by the kernel to the child PCB before first schedule -- this is what the
  shell uses instead of child-side redirection code), schedule. **Zero
  parent copying; spawn costs only what exec already cost.** vfork is
  DELETED -- its entire purpose was cheap fork+exec, which spawn subsumes
  without the borrowed-bank UB rules. True fork() (the sbrk-bounded
  bank-clone + frame patch below) drops to a **v2 slow path** -- specified,
  not v1-blocking; v1 returned ENOSYS. **LANDED 2026-08-23**
  (`src/kernel/procfork.s`, `SYS_FORK` = 8, `docs/FORK.md`) -- as a
  kernel syscall wired into its own gate image only; every other
  manifest's dispatch table still stops short of 8, so `fork()` is
  still `ERR_NOSYS` in the shipping system. This also defangs the fork/VBL
  tick-skew concern for v1: no 160ms copies on any common path.
- **fork() -- ~~[v2]~~ LANDED IN V1, 2026-08-23** (`src/kernel/procfork.s`,
  `SYS_FORK` = 8, `make check-fork`, `docs/FORK.md`; the v2->v1 move is
  PLAN.md sec 2a, ordered because the shell needs it -- `STICKY.md` sec 22).
  Two layers, as review finding A6 specified: the **bank-clone primitive**
  (task #4's copy core) copies ZP (256B) + stack page (256B) +
  `[LOAD_BASE, PCB_BRK*256)` -- **text included, unconditionally**
  (operator ruling 2026-08-23: the text-skip optimisation is OUT,
  measured worth ~0.05 s on the average eligible program and largest
  exactly where it cannot be taken -- `docs/FORK.md`). **ABI rule
  (cold-read Q3-2): process LC RAM ($D000-$FEFF, both $D000 banks) is
  NOT preserved across fork** -- the child gets a fresh $FFxx stamp and
  undefined LC contents; processes needing data across fork keep it
  below brk. The **fork syscall** (task #3's trapframe contract)
  patches the child's frame so parent and child differ only in frame-A
  and frame-P carry, and duplicates PCB resources (fd table private,
  objects shared; cwd; pid/bank map). The primitive MUST bracket
  $0400-$07FF and (with HIRES) $2000-$3FFF with CLR80STORE/SET80STORE
  or the copy is a silent main->main self-copy that never reaches the
  child (`learning:01KW1GTYHGXMBZNR6DMQB2F712`; both windows stated
  at the bracket site in `src/kernel/bankcopy.s`; the $2000-$3FFF arm
  proven red by sabotage in check-fork). (RESTORED 2026-08-23,
  adversarial review: this bullet's first re-cut narrowed the
  constraint to $2000-$3FFF alone, which would have deleted the
  $0400-$07FF half from this document entirely -- bankcopy.s carries
  both.) Measured 2026-08-23: 38.57 cyc/byte for the copied extent
  (562,767 cycles); the whole syscall is 587,763 cycles = 0.588 s at
  1 MHz for a 14,592-byte extent, the difference being fork's 24,996-
  cycle fixed per-call cost (`docs/FORK.md` -- multiply 38.57 by the
  extent and ADD the fixed term). This sketch's old "~20 cyc/byte"
  was the single-window main<->bank figure; bank-to-bank is 2x. The
  copy is non-preemptible, dropping ~35 VBL ticks per 14 KB fork -- clock skews under fork load; a restartable copy with
  yield points is the later fix. ~~vfork ABI: child may only
  exec/_exit, must not touch memory below the borrowed SP; violations
  are documented UB (debug-build canary). vfork escape hatch: child
  borrows parent's bank until exec, parent sleeps.~~ vfork is DELETED
  (spawn ruling above); struck rather than removed so A6's original
  shape stays on the record. **Wired into its own gate image ONLY**:
  every shipping manifest's dispatch table still stops short of call
  8, so `fork()` remains `ERR_NOSYS` in `v1-system`, `sh` and `play`
  until the 28-manifest wiring lands as its own change
  (`docs/FORK.md`, "Not wired into the shipping system yet").
- **Bank exhaustion**: no swap. fork() fails cleanly (EAGAIN-style) when the
  free-list is empty; the ramdisk competes with processes for the same pool,
  so the allocator keeps a configured process-bank reserve.
- **exec()**: loads into a fresh/recycled bank; same 80STORE bracket applies.

## Scheduling

- Context switch: save SP -> PCB (A/X/Y/P already live in the trapframe on
  the process stack -- do NOT duplicate them in the PCB), write $C073, flip
  switches, TXS, exit tail restores from the frame.
- Preemption baseline: AppleMouse-card 60 Hz VBL IRQ -- verilogapple's default
  machine config (slot 5), and it keeps a IIc + Z-RAM port plausible
  (`learning:01KZXDQCQF2FZMDQ59FVZ5D7T4`). **Timer is probed, not assumed
  (review finding A8)**: boot probes mouse+VBL -> Mockingboard 6522 -> cooperative-only,
  and reports the outcome loudly. The VBL driver owns the card handshake
  (init, per-tick IRQ-source clear per the card firmware protocol -- see the
  ClearMouse narrow-clear learning); the gate tests non-re-entry on a stale
  VBL source. Authentic TimeMaster II H.O. (6821 PIA, DIP-routed IRQ only --
  NMI excluded) pending a verilogapple faithful-card model.
- Every $C073 write trips the paddle strobe (3-4ms settle) -- joystick reads
  need the scheduler held briefly (`learning:01KYYJ98T5R0M9K1AW2550M132`).

## Bank management

- **Shipped today: a FIXED bank list.** `PRC_INIT` fills `PRC_FREE_LIST`
  with banks 15 down to 2 (14 entries); the shell is bank 1 and bank 0 is
  the annex. maux touches banks 0-15 and no others, so it needs a
  RamWorks of at least 1 MB with all of banks 0-15 present, and runs at
  most 15 processes (bank 1 plus the 14 on the list) although
  `PCB_COUNT` is 48. A 512K card fails silently: nothing at boot detects
  the missing banks (`learning:01M5BZT24FCGW28BWFR02TAJ12`).
- **Designed, NOT shipped: a probed list.** Bank numbers are sparse and
  card-dependent on period cards, so the intended design is to probe at
  boot (FindBanks pattern, `src/kernel/bankprobe.s`, linked only by
  `src/test/probetest.s`), build a free list of physical bank numbers
  and map pid->bank via table, never assuming contiguity
  (`learning:01KYYJ98T5R0M9K1AW2550M132`). Nothing in the boot calls it.
- $C073: write-only; NOT cleared by reset on real hardware; zeroed only at
  power-up. **Coding discipline (operator ruling): the selection is UNKNOWN
  at every entry** -- boot, reset, any return from firmware -- and is always
  written before any aux-dependent operation; no code ever reads meaning
  from persistence (it couldn't: the register is write-only, and a hardware
  reset re-enables ROM and lands in kernel-controlled code before any aux
  access regardless). Consequence: verilogapple#13's fast/rtl reset
  divergence cannot affect maux correctness -- it constrains only tests that
  assert HARDWARE-fidelity claims (deposit-grade statements about period
  behavior), which still need rtl/MAME/iron. Even warm-boot ramdisk
  recovery is unaffected: bank CONTENTS persist on both backends, and
  recovery is a signature probe that writes $C073 first anyway.
- v1 targets RamWorks II/III (electrically identical) + modern dense repros.
  MultiRam (whole-$C07x decode) and TransWarp (shadow-RAM question,
  `learning:01KYYPR1CB9H9JK88W5QF56QWQ`) are out of scope; bank select goes
  behind a small driver interface so they can be added later.

## Filesystem / I/O

- **ProDOS 8 is the v1 filesystem layer (operator ruling, 2026-08-14).**
  The V6-flavored fs, the ramdisk engine, and mkfs.maux are CUT from v1
  (v2-or-never). Rationale: the fs was the largest line item in the summer
  project and the same imported-reverence mistake as fork -- ProDOS is a
  better filesystem than we'd likely build, an excellent fit for the 6502,
  and it lives exactly in the memory maux doesn't use (main LC + the $BF00
  main global page; process banks untouched -- the one-page invariant
  survives intact). Storage is already SmartPort blocks (fast on emulator
  and on CFFA/FloppyEmu iron), so the ramdisk's reason evaporates; a2til
  already speaks ProDOS volumes host-side. On-platform precedent: GNO/ME
  on the IIgs -- a real Unix-like that delegated its filesystem to the host
  OS.
- Mechanics: ProDOS stays resident; the kernel delegates file syscalls to
  the MLI under a kernel lock (MLI is non-reentrant -- one file op
  machine-wide; invisible at 1MHz with a handful of processes). Native
  file-call numbers ARE the MLI numbers with verbatim MLI parmlists;
  process calls (spawn/exit/wait/pipe/brk) take numbers outside MLI's
  range. fds map to MLI refnums via a per-process fd table (0/1/2 = tty).
  Each open file needs the MLI's 1K page-aligned buffer, allocated from
  main slack. The $BF00 compat overlay becomes a near-passthrough, and
  Merlin-8's file I/O works unmodified -- task #8 shrinks accordingly.
- **Gated on the MLI-coexistence spike (task #11)**: ZP footprint under the
  kernel ZP map, the MLIACTV interrupt protocol vs our VBL tick (register
  via ALLOC_INTERRUPT like a polite period citizen, or own main $FFFE and
  honor MLI-active around calls -- spike decides), and IRQ-during-MLI
  behavior, proven in the emulator before file syscalls wire up.
- /RAM is disconnected at boot per the polite protocol (it squats on the
  annex) -- `learning:01KW1GTYH4NRG0F8M7AAT6EG9Z`.
- Console: `docs/CONSOLE.md` is the spec. The ruling is a kernel terminal
  subsystem (fd-backed tty, line discipline, small VT-style parser, virtual
  console surface, pluggable display backend), not an Apple ROM console or an
  80-column page writer. Apple 40-col is the fallback; UltraTerm is the serious
  text-console target; Apple 80-col is deferred.

## Boot / hosted mode

**The native/hosted split has dissolved (ProDOS ruling):** maux always
boots via ProDOS 2.4 and keeps the MLI resident as its file layer -- what
was "hosted mode" is now simply *the* boot path, and the A7 lifecycle
contract below is the boot contract. The historical two-mode framing:
1. **Native**: own boot disk, own the machine. *(Now: ProDOS boot disk
   auto-launching MAUX.SYSTEM -- same artifact as hosted.)*
2. **Hosted** (dev convenience): launch as ProDOS system file, follow the
   /RAM disconnect protocol (`learning:01KW1GTYH4NRG0F8M7AAT6EG9Z`,
   `learning:01KYYGZ8C3FQFWCF3S0FQ0DJ7B`), take the machine, restore on quit --
   the sanctioned AppleWorks transient pattern. **Lifecycle contract (review finding
   A7)**: record HAD_RAM at launch and never reinstall /RAM if it was absent
   (absence = other system software owns aux); normal quit restores /RAM,
   DEVCNT/DEVLST + driver table, $C073=0, LC state, video softswitches, and
   the global page; the reset-vector chain reasserts $C073=0 and LC before
   ProDOS regains control; crash/debugger exits are documented as
   reboot-required, not silently half-restored.

## Target hardware -- what a real person actually had

**Operator ruling, 2026-08-23.** The machine maux targets is one
somebody could plausibly have owned in the period: an enhanced //e with
a **ZipChip**, **RamWorks III / Z-RAM**, and a **UniDisk 3.5"**. That
is the fidelity boundary, and it is a design constraint rather than a
preference.

**Hard drives were period-real too** -- ProFile, Sider, CMS, later SCSI
cards. So there is no hard ceiling at 800K, and an earlier draft of
this section was wrong to state one. What is NOT period is a modern
multi-gigabyte mass-storage device; the boundary is the era, not the
medium.

**Period-real, but NOT cheap -- and this section's affordability claim is
now sourced (2026-09-05).** Until today every hardware claim here was
graded and the affordability of the target was simply asserted. Closed
with mail-order ad prices from inCider 1988-11, 1989-05 and 1989-11:
`learning:01M1RWRR7XV5JSZRQ8GVCE8ZZ0`.

What it establishes, and it INVERTS the intuition this section was
carrying:

- **Memory and acceleration were the cheap part.** RamWorks III w/1 Meg
  fell from **$514** (Nov 1988) to **$313** (Nov 1989); a 4 MHz Zip Chip
  was **$119**. maux's entire memory-and-accelerator floor is ~**$432**
  in late 1989 -- `[likely]`, being arithmetic across two advertisers
  rather than a quoted bundle.
- **Mass storage was the expensive part.** A 20 MB hard disk ran
  **$475-$629** (AE Vulcan, Sider D2, Chinook CT20, CMS). One drive cost
  more than the whole memory floor.
- The RamWorks ladder shows why any single price misleads: `w/0K $103`
  against `w/1 Meg $514` means ~$411 of that price was DRAM, which is
  why it moved so fast.

**Consequence for the design, and it is the reason the pricing matters:
a hard disk is period-real but is the single most expensive thing in the
build, so maux does not get to assume one.** The system must be good on
800K and modest media. The buffered/cached-I/O answer to this is an
OPEN operator ruling (2026-09-05) and is deliberately not written up
yet -- it forks on whether the cache sits above MLI (file-level) or
below it (block-level, which would reopen the ProDOS ruling). Do not
cite it as settled.

**Do not quote $299 as a UniDisk 3.5 price.** That figure is from a
ZIMCO ad reading "Genuine Apple 3.5" 800K drive (IIGS, Mac)" -- the
**Apple 3.5 Drive**, a different product with a different controller
from the **UniDisk 3.5** this section targets. No UniDisk 3.5 price has
been sourced. Page attributions in the learning come from OCR page
markers and want re-checking before anything leans on them.

**But a UniDisk 3.5" is 800K = 1600 blocks, and the whole development
system fitting on ONE FLOPPY is a genuine 1980s virtue** -- a thing you
could hand someone. As of 2026-08-23 that looks achievable rather than
aspirational. So track it as a **goal with a visible number**, not as
a gate: crossing 800K means reaching for a hard disk, which is
authentic but less good, and it should be a decision somebody makes
rather than a threshold nobody noticed.

Two consequences that are easy to miss:

- ~~**Source lives on its OWN volume, mounted as unit 2**~~ --
  **AMENDED 2026-08-28, on both halves of the argument.** The ruling
  was: a period developer with two drives is authentic, a single
  volume holding system and 682 KB of source is not, do not
  consolidate. Both halves fell in one session.

  **The authenticity half is answered by the hardware, and by a
  source this project already had.** The *Checkmate MultiRam //e
  User's Manual* ((c) 1985), deposited in the commons for its
  memory-card content, says in its compatibility chapter: **"Hard disk
  drives for the Apple range from 5 megabytes to over 50 megabytes"**,
  names "the Sider, an increasingly popular inexpensive hard disk
  drive manufactured by First Class Peripherals", and recommends
  "the MultiRam //e card, AppleWorks, and a hard disk drive together".
  A multi-megabyte disk on a **//e** -- this project's own target -- is
  1985 mainstream, not a late retrofit.

  The //e reached it through **slots**, and had the choice: Apple's
  ProFILE (5 MB in 1981, parallel, with an Apple II interface card
  from 1983), the Sider, two Apple SCSI cards with **DMA on the later
  one** (0.5 MB/s on a //e), and late-life internal Vulcan /
  InnerDrive units from Applied Engineering -- the RamWorks vendor --
  that replaced the power supply to make room for the mechanism. Even
  the **//c**, with no slots at all, could hang a SmartPort hard disk
  off its disk port (Chinook CT-20c, 20 MB, 1988).
  `learning:01M13SWTZBKWRZYY1R3HQS4VTP` carries all of it with grades;
  the capacity range and the Sider are `[fact]` from the 1985 manual,
  the interfaces are `[likely]` from secondary sources, no card manual
  fetched yet.

  So "one volume holding both" is not an anachronism -- it is an
  ordinary 1985 //e with a hard disk.

  **"SmartPort" names two different things, and conflating them got
  this paragraph wrong once already.** It is (a) a **block-device API**
  -- the call interface ProDOS drives, `$CN00 + ($CNFF) + 3`, STATUS /
  READBLOCK / WRITEBLOCK / CONTROL -- and (b) a **wire protocol** that
  turns an Apple II disk port into a daisy-chained bus. A //c's drives
  use both. A //e slot card can present (a) while never touching (b),
  and that is what most //e mass storage does.

  This paragraph previously said "verilogapple models a SmartPort
  block device, so maux is exercising the //c-shaped storage path".
  **That is wrong.** verilogapple's device is a **slot-7 card** with
  memory-mapped registers at `$C0F0-$C0FF`, slot firmware supplying
  the ProDOS + SmartPort signatures, and a fast-PIO state machine at
  **6 cycles/byte** (`~/src/verilogapple/docs/smartport.md`). It is the
  API without the bus -- a **//e-shaped** path, and the same shape as a
  period //e controller card or a modern CFFA-class one. Its own design
  note says the register interface is meant to map onto an FPGA+MCU
  product, so it is modelled on a modern card, not a period one.

  What that does mean for timing: ~6 cycles/byte is faster than a
  period programmed-I/O card and slower than the DMA SCSI card's
  0.5 MB/s, and it is still **one block per ProDOS call** -- which is
  the ceiling that no interface escapes.

  **The engineering half is worse than answered -- the two-volume
  layout does not currently work at all.** maux cannot read a second
  volume: ProDOS lists it (`$F0`, slot 7 drive 2, in `DEVLST`) but
  `vendor/ProDOS-2.5.bin` installs **no driver** -- `$BF2E` holds
  `$E1CC`, the no-device stub, where drive 1 holds a real `$FE78` -- so
  any maux path on unit 2 dispatches into the stub and **wedges in
  empty slot-2 ROM**. A hang, not an error. Not the disk size
  (reproduced at 800K); not the emulator (booted from the MERLIN
  disk's own ProDOS, both drives hold `$C77B` and it reads fine).
  `check-dual` never caught it because **real Merlin** reads
  `/MAUXSRC` -- maux never has.

  What replaces it: `scripts/build_bigdisk_image.py` builds ONE
  bootable 32 MB volume (65535 blocks, ProDOS 8's own ceiling)
  carrying the system, the userland and all 208 source files, and
  **maux strips its own tree and assembles from it** -- see
  `docs/AS-PUT.md`. The one-floppy goal above is untouched: that is
  about the SYSTEM volume, and this is a development disk.
- The self-hosting milestone (task #8) therefore does **not** need two
  volumes, and as of 2026-08-28 does not use them.

**Gap CLOSED, and the source refined the claim (2026-08-23, stream
T2).** Apple's UniDisk 3.5 Owner's Manual and DTS Technical Notes are
now deposited with their PDFs --
`learning:01M0PE7JQHC9WVDAY7D6011M78` and
`learning:01M0PE538GF71R0GXYXHG3MB39`. What they settle:

- **800K on double-sided media is `[fact]`** -- the Owner's Manual
  (part 030-1151-A, p.2/p.10) says "800 kilobytes", scoped to
  double-sided disks.
- **The figure "1600" appears in NEITHER document.** It is arithmetic
  (800 x 1024 / 512) and holds only for double-sided media. Technical
  Note #4 (p.3) is explicit that the same drive reports **800 blocks
  (400K)** for a single-sided disk, and that capacity comes from a
  live SmartPort `STATUS` call against **the media last accessed** --
  so capacity is a property of the disk in the drive, not of the
  drive. Still the right number for the one-floppy goal; just say it
  is computed, not quoted.
- **Two daisy-chained drives, labelled "drive 1" and "drive 2", are
  the documented normal configuration** -- so source-on-unit-2 above is
  period-authentic per primary source, not merely a preference.

Still wanted: the Apple IIc Technical Reference and the 3.5 ROM
Programmer's Guide, which carry the full SmartPort command set.

## V1 scope -- the summer project

Operator ruling: v1 honors the Bill Joy ethos -- the kernel and core utils
are a summer project, and every feature must defend its place in one.

**V1 kernel:** boot + fixed-list bank allocator (banks 2-15; the probe is unshipped) - $FFxx page + JSR $FF00 syscalls
- spawn/exit/wait - file calls delegated to resident ProDOS MLI (locked,
serialized; MLI numbers + verbatim parmlists) - pipes (256-byte rings in
the bank-0 annex -- small, and Unix without pipes isn't Unix) - fd-backed tty
console with cooked input, small VT-style output, one virtual console, Apple
40-col fallback, and UltraTerm-shaped backend seam - VBL round-robin scheduler
- BRK: SIGTRAP for a user process, a halt in the kernel.

**V1 userland, as originally ruled (2026-08-14):** sh (spawn +
fdactions + pipes + wait -- no job control), ls, cat, echo, cp, rm, ed.
~~That's the list; a util not on it argues its way on by displacing
one.~~

**The displacement rule is RETIRED (2026-08-23, S8 ruling; PLAN.md
sec 2b).** Retired rather than restated, for three reasons:

1. **It was never once applied.** `grep` argued on (2026-08-16, task
   #10) by merit and displaced nothing; wave 3 added six more; the
   tree now holds 33 programs. A rule silently broken from its first
   test stops carrying information -- `ANACHRONISMS.md` sec 0's own
   principle, applied to ourselves.
2. **The scarcity it priced is gone.** Displacement made sense while
   the list was a summer-project budget: seven slots, every utility
   competing for the same scarce effort. THE GOAL (operator,
   2026-08-21; PLAN.md) re-founded maux as a development environment --
   against that goal `diff`, `nm`, `sort`, `find` are not applicants
   arguing past a fence, they are the point -- and liba's maturity made
   each one cheap in exactly the way the fence assumed they could not
   be. The rule's premise changed under it; the utilities did nothing
   wrong.
3. **Its real job passed to a mechanism that postdates it.** The
   costs the fence guarded -- image bloat, unproven code, drift -- are
   held mechanically today by exactly ONE named ratchet:
   `check_purity`'s exact-equality debts (`BIN_DEBT`,
   `TEXT_IMMUTABLE`, `WARM_UNSAFE`), which bind every program in the
   roster on every `check-modules` run. (CORRECTED 2026-08-23,
   adversarial review of this ruling: the first cut also credited
   "per-image size tripwires" -- there is exactly one, `sh.bin`'s
   16,384-byte budget in `check_modules.py` -- and `docs/E2E.md` sec 7's
   differential-entry rule, which has no script or make target behind
   it and is conditional by its own terms. Both are policy we intend
   to mechanise, not mechanisms; the retirement decision rests on
   reasons 1 and 2 plus the one live ratchet, and does not need them.)
   The fence bound only the next applicant, and only rhetorically.

**What replaces it -- the entry test.** A new utility argues its way on
by stating, in its task or commit: (a) the development-environment
workflow it serves (THE GOAL is the measure, not the count); (b) its
e2e coverage -- an `E2E.md` sec 7 differential entry where a host
reference exists, declared invariants otherwise; (c) its
`check_purity` ratchet standing, plus its size against its budget
tripwire where one exists (today only `sh.bin` carries one). Nothing
is removed retroactively: the 33 residents earned their places under
the goal that changed under them.

**Explicitly v2+:** ~~true fork() (ENOSYS in v1)~~ **landed
2026-08-23, `docs/FORK.md`** - signals beyond
exit/wait + tty ^C kill - additional virtual consoles - raw/noecho tty mode
- hosted Apple BASIC personality - lores/hires/double-hires graphics surfaces
- Apple 80-col backend - the $BF00 MLI compat overlay and the Merlin port
(tasks #7/#8 continue as their own track -- the dual-assembly gate still
runs in CI from v1's first module, it just doesn't gate the summer) -
a native V6-flavored fs + ramdisk (v2-or-never; ProDOS ruling above) -
Mockingboard timers - floppy.

## Second-chair review (2026-08-13)

the design review -- eight findings, all accepted, corrections folded in
above and into the task board. Highlights: A1/A2 caught two critical design
bugs (JSR/RTI trapframe mismatch; kernel losing user-memory access after
the RAMRD flip); A5 found a verilogapple fast-backend fidelity bug via
source inspection ($C073 cleared on reset in fast, persists in rtl and on
hardware -- task #9, and corrected in the street-library).

## Open questions

- Whether AE Z-RAM (IIc) bank select matches $C073 semantics -- unverified;
  gates the IIc portability claim.
- ~~Assembler choice~~ RULED: merlin32 (v1.1.10, malisp precedent), written in
  the intersection of merlin32 and real Merlin-8 dialects, enforced by a
  dual-assembly gate (real Merlin under ProDOS in verilogapple, byte-diffed
  against merlin32 output -- task #7). Long arc: port real Merlin to maux for
  self-hosting (task #8). Rig: verilogapple
  (`learning:01KWF4QBFJ8EJWK21JVP16VEM7`) -- see task #1.
- MLI compatibility: the shape is RULED (opt-in $BF00 overlay, Tier 1 file
  calls only -- see the syscall section); the one open sub-decision is
  whether native call NUMBERS are the MLI numbers ($40-$D3, Unix calls in
  unused slots) -- decided in task #3 alongside argument transport.
- Which $C073 fine points verilogapple's AuxCard implements (write-only,
  reset persistence, paddle strobe, sparse numbering) -- determines what can
  be emulator-verified vs needs MAME/hardware.
- Whether 80STORE+PAGE2 CPU writes land in bank 0 or the selected bank --
  library marks this `[likely selected bank]`, unverified; we sidestep by
  keeping 80STORE off in copy primitives, but pin it down in emulator anyway.
- TransWarp shadow RAM vs. live state in high banks -- empirical test needed
  if accelerator support ever matters.
