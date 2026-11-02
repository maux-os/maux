# The language card: one latch, one steady state

Status: LANDED 2026-09-20. Gate: `make check-lc` (source ratchet, with a
mutation self-test) and `make check-lc-prodos` (the resident-ProDOS scan).

## The rule

**`$C083` and `$C08B` are the only two of the sixteen language-card soft
switches any maux code may touch.** Both select read-RAM and write-enable;
they differ only in which `$D000-$DFFF` bank is mapped. The other fourteen
spellings are banned tree-wide:

| Spelling | What it does | Why it is banned |
|---|---|---|
| `$C080 $C088` (and `$C084 $C08C`) | read RAM, write-PROTECT | imposes a state on every other process |
| `$C082 $C08A` (and `$C086 $C08E`) | read ROM, write-protect | both of the above |
| `$C081 $C089` (and `$C085 $C08D`) | read ROM, write-enable | a process calling into its own LC executes ROM |

Declared exemptions, and only these, are listed in `scripts/check_lc.py`:
`src/bin/proshim.s`, `proshimpg.s`, `proshimcr.s` (the ProDOS-tenant shim
must present real ProDOS semantics to its tenant, including a genuine
read-ROM window, and already masks interrupts across it), and
`src/test/bufiotestb.s` (a declared violator harness).

The steady state is established by the first LC writer to run, and every LC
writer in the tree still opens with the double read (two odd accesses are
what the hardware's pre-write counter needs to latch write-enable). Once
latched it can never be cleared, because the clearing spellings are banned.

It is deliberately NOT established in the kernel's own `INSTALL_COPY`, and
that is worth recording: `lda LCBANK2_RAM` does not only latch write-enable,
it also moves the LC READ SOURCE to RAM. Doing that at kernel init is early
enough to matter -- tried 2026-09-20, it cost `check-play80` both of its
UltraTerm hardware-cursor checks, deterministically, while passing at the
base commit. The six bytes also pushed `MAUXEXPR.SYSTEM` further into the
MLI io_buffer region than its recorded overrun allowed. Two gates, one
cause, and the addition was redundant anyway.

## Why: the latch is global and cannot be read back

The write-enable is one flip-flop in the MMU, shared by the whole machine.
It is not per-process, not per-bank, and -- this is the load-bearing part --
**there is no way to read it.**

The //e added a readback family at `$C011-$C018` that the II+ lacked, and it
covers bank-select (`RDLCBNK2`), read-source (`RDLCRAM`), `RAMRD`, `RAMWRT`,
`CXROM`, `ALTZP`, `C3ROM` and `80STORE`. Write-enable is not among them. In
the hardware it is a two-stage pre-write/write counter wired to the memory
routing, not to the status mux.

Measured on MAME's `apple2ee` (an implementation sharing no code with
verilogapple), with teeth and a positive control:

```
SNAP WPROT C010..C01F bit7 = 0010010000100000
TEETH WPROT  $E000 before=00 after=00  write DROPPED
SNAP WREN  C010..C01F bit7 = 0010010000100000
TEETH WREN   $E000 before=00 after=5A  write LANDED
SNAP RDROM C010..C01F bit7 = 0000010000100000   <- $C012 flips
```

The two status snapshots are identical while the teeth prove the write-enable
genuinely changed; the read-ROM select moves `$C012`, so the range is live
and correctly addressed. Scope limit: `$C010-$C01F` only, because sweeping
the rest of `$C0xx` would trip the switches under test.

**A scheduler cannot save and restore what it cannot read.** So there is no
kernel-side fix for a process that holds write-enable across a window it can
be preempted in. Either nobody holds it, or nobody ever clears it. maux takes
the second: nobody ever clears it.

## The defect that produced this rule

`make check-jobctl-a`, case `orphan_zombie`, 2026-09-20: the machine went
dead with the CPU parked in `KRN_BRK_TRAP` (`src/kernel/entry2.s`) at `$217A`,
interrupts masked, `A=$42`. The gate blamed a leaked PCB slot. It was not.

The BRK frame is on the interrupted process's stack, not main's --
`KRN_IRQ_ENTRY` captures `K_CALLER_SP` before it flips `ALTZPMAIN` -- so with
`K_CALLER_SP=$F7` in aux bank 8:

```
$01F8..  00 10 00 33 3B ED      Y=00 X=10 A=00 P=33 (B set) PC=$ED3B
$01FE..  16 08                  the JSR return under it: $0816 -> $0817
```

The BRK opcode is at `$ED39`, reached by `jsr $ED39` at `$0814` -- which is
`shlex.s`'s `jsr SB_T0CAP`, the eighth instruction of `sh`. `$ED39` in that
bank held `00 00`. The shell called into its second code segment
(`docs/SH-SUBSET.md` ruling 7.6) and found nothing there.

From a full per-cycle trace of the same run:

| cycle | what |
|---|---|
| 20,839,342 | `$5F89/$5F8C` read `$C08B` twice -- `SEG_INIT` write-enables |
| 20,839,359 | the copy starts at `$E000` |
| 20,895,808 | writes `$ECD1` -- the last byte that lands |
| -- | preempted; 104,269 cycles in other banks |
| 20,934,674 | **bank 3** (the login shell) at `$52FA` reads `$C088` -- liba stdio closing its own bracket; write-enable off, machine-wide |
| 21,000,077 | our process resumes at `$ECD2`; every store from here is dropped |
| 21,013,684 | "copies" its last byte `$EFFF`, then `$C088` at `$5FA4` |
| 21,016,511 | `jsr $ED39` -> `00` -> BRK -> the kernel parks. Machine dead. |

The bank's language card read back after the halt confirms it: **`$ECD2`
begins a 4,654-byte run of zeros**, and `SB_T0CAP` sits inside it.

Nobody was misbehaving. stdio restoring the documented steady state was
correct by the convention of the day. The defect was the convention.

## ProDOS does not fight this

Two levels of evidence, because "permanent" is only permanent if the resident
operating system agrees.

**Live, 900,000 cycles of a real run:** 56 language-card switch accesses from
ProDOS, every one of them `$C08B` -- a write-enable. Zero protects. The MLI
entry path does it unconditionally on every call:

```
BFC0  LDX $E000        ; sample the caller's READ orientation --
BFC3  LDA $D000        ; ProDOS cannot read the switch either
BFC6  BIT $C08B        ; read RAM + WRITE-ENABLE, bank 1
BFC9  BIT $C08B        ; the double-read handshake
BFCC  PLP / JMP $DE00  ; into the dispatcher
```

Note what it samples: the `$E000` and `$D000` *bytes*, to work out whether
the caller had ROM or RAM readable. It never tries to restore write-enable,
for exactly the reason we cannot. So ProDOS can never silently re-protect
based on prior state -- it can only protect where a path hardcodes one.

**Static scan of all 16 KB of resident ProDOS** (dumped off a booted
`build/play.po`, so patches included) for absolute `$C080-$C08F` operands:
eight hits, six of them enables. The two write-protects are both exit paths:

| Where | Code | What it is |
|---|---|---|
| `$D101` | `CLD / LDA $C082 / CLI / STA $C00C / STA $C000 / JSR SETVID / JSR SETKBD / JSR INIT / JSR HOME` | the QUIT dispatcher: switch ROM in, hand the machine back |
| `$FFC8` | `STA $C082`, then pushes `$FA61` (the ROM entry) as a return address | the reset / exit-to-ROM glue |

Both are "we are leaving now" code, unreachable while maux runs, which is
what the live trace independently shows. ProDOS's own installer -- the
routine at `$FC9E` that copies the QUIT code into `$D100` -- ends by
re-selecting `$C08B` with write-enable, not by protecting.

`make check-lc-prodos` re-runs that scan and pins the expected set, so a
different ProDOS build cannot change the answer quietly.

Three limits, stated rather than buried: the scan is linear over bytes, so it
cannot see a switch access built at runtime or reached through an index
register; the 50 `$C08x,X` hits in the same image are Disk II slot addressing
(`X = slot<<4`, never 0), not the language card; and this is the ProDOS in
our play image.

## What this costs, and what it does not buy

Removing the protects costs negative cycles and negative bytes. What it gives
up is real and worth naming: a wild store above `$D000` used to be dropped by
the hardware and now lands -- on the process's own `$FFxx` syscall stubs and
`$FFFE` vector in its own bank, or, while the kernel is running with
`ALTZP` main, on ProDOS's resident code. maux has no memory protection
anywhere else, so this was one guard rail over the most load-bearing bytes in
the machine, and it is gone on purpose.

## The sibling race: bank-select, FIXED 2026-09-20

**Bank-select is global machine state too**, and it had the same shape.
liba stdio owns one whole 4 KB LC bank for its eight stream buffers (8 x
512 B) and selects it across a copy -- one byte in `SIO_PUTC`, up to 256 in
`SIO_PUTS`, up to 512 in the flush path's `SIO_CPY`. `ex`/`vi` keep
`EX_SHADOW`, and `ld`'s embedded core keeps its workspace, in the other
bank's `$D000-$DFFF`. A process preempted inside stdio's window resumed with
whatever bank someone else had selected, and ProDOS reselects the default on
every MLI call, so the kernel servicing a tick was enough to do it. Milder
than the write-enable failure -- a few buffered bytes into the wrong 4 KB
bank, corruption rather than a halt -- and never caught by a gate.

Eliminating the second bank is not available: stdio needs all 4 KB of one,
`ex` needs the other bank's `$D000`, and a process running `ex` uses both.
The bank-agnostic common region (`$E000-$FEFF`, 7,936 B) cannot absorb 4 KB
on top of `sh`'s 6,144 B segment budget. The two-bank arrangement is
load-bearing.

So the kernel saves and restores it, which is possible here because unlike
write-enable **the bank IS readable, at `$C011`**.

**The storage costs zero kernel-image bytes**, which is the part worth
copying. The saved bank lives in `K_LCBANK`, a byte in the PROCESS's own
zero page (`$FF`, `inc/entry.frame.equ`) -- the one cross-door cell in this
kernel that deliberately lives in ZP rather than main memory. Every other
one was moved OUT of ZP because it was written with `ALTZP=aux` and read
with `ALTZP=main`; this one is written aux and read aux on purpose. The
doors write it into whichever bank was interrupted, and a resume path reads
it back AFTER its own `sta ALTZPAUX`, which is by then the INCOMING
process's zero page. That is what makes it per-process without a pid-indexed
table, and it is declared to `check-altzp` as `XBANK(zp)` at each of the
three read sites.

Five touch points, 43 bytes:

| where | what |
|---|---|
| `KRN_ENTRY` | `stz K_LCBANK` -- a process never syscalls from inside a bank bracket, so the bank to resume with is the default. One store, no read, on the hot path |
| `KRN_IRQ_ENTRY` | `lda RDLCBNK2 / sta K_LCBANK` -- the only door through which a process can lose the CPU mid-bracket, so the only place the live value can still be read |
| `KRN_EXIT` (switching) | restore from the incoming process's own cell |
| `KRN_IRQ_SVC` (switching) | same |
| `KRN_IRQ_SVC` `:sameproc` | the case the mechanism exists for: a tick landed mid-bracket, nothing switched, and the tick handler or ProDOS may have reselected underneath it |

`KRN_EXIT`'s non-switching path is deliberately untouched: same process,
bank already default, and that is the hottest path in the kernel.

`make check-lcbank` gates it, and it does not race the race. It parks the
machine at the IRQ door, writes distinct sentinels into both of that bank's
LC banks, fault-injects the saved `K_LCBANK`, resumes, and reads `$DF00`
THROUGH THE MMU (the disassembler's bus read honours ALTZP, the LC bank and
the read source) to see which sentinel is live. Run once per direction: a
kernel that ignores the cell cannot answer two ways, and one that hardcodes
a bank fails the other case. Teeth proven by neutralising the three
restores -- the `$80` case goes red, the `$00` case correctly cannot.

## A gate that was passing on phase luck

Landing this turned `check-play80`'s two UltraTerm hardware-cursor checks
red, twice, on a machine whose cursor was correct. It was not a defect and
not image size (80 bytes of dead padding alone kept it green): the gate's
settle predicate was `row 0 of the card starts with $`, and it then asserted
`cursor_addr` and `cursor_on` out of that same sample. The driver puts the
prompt CHARACTER in VRAM before it programs the CRTC's cursor registers.
Measured at the gate's own 20,000-cycle polling granularity: at the poll the
predicate fired, `cursor_addr=0 / cursor_on=False`; at the very next poll,
`2 / True`, stable for 20 more. The gate passed only because the two
happened to coincide, and any change to kernel cycle cost on the
syscall/IRQ path moved the sample across that window.

`wait_for` now requires the predicate to hold on two consecutive polls AND
the whole asserted state to be identical between them, returning the second.
Nothing is weakened -- a genuinely wrong cursor is wrong in both polls,
settles, and still fails. This is HACKING.md's notebook rules and
`learning:01M1AH9XWGC8ZS7HNBJVJ2JHXW` arriving in a new gate, and it is
worth stating plainly: **a red that appears when you change kernel timing is
a question about the gate's predicate before it is a question about the
kernel.**

## Answered on the way past

`src/test/bufiotestb.s` phase D has carried an open question since
2026-09-06: a deliberate violator that leaves the wrong bank selected across
a real MLI call "completes CLEANLY every time", which `docs/PROCIO.md` sec 6
recorded as an undemonstrated hazard and an open risk.

It was never going to be loud. ProDOS's MLI entry re-selects its own bank on
every call, before it dispatches -- the `BIT $C08B` pair quoted above. A
violator cannot lose that race because ProDOS fixes the state first. The
sec 5 invariant still holds for anything touching `$D000-$DFFF` WITHOUT going
through ProDOS, which is the bank-select race above: a scheduler problem, not
a syscall one.

## The kernel cold segment, and why its wrappers re-select (2026-09-27)

`docs/KSEG.md` puts real, resident kernel code in `$D400-$DFFF` -- the
segment -- reloaded from `/BASIC/KSEG` on every boot and after every
`bye` tenant return, selected via `$C083`. This is a NEW consumer of
the bank-select rule above, not an exception to it: the segment is
CODE, so unlike the ordinary MLI-call race (fixed by ProDOS re-
selecting before it dispatches), nothing external re-selects `$C083`
before the CPU fetches the segment's own next instruction. The
segment's own `KSEG_CALL` trampoline (procfile5.s) is the mechanism
that takes the place of "ProDOS fixes the state first": it selects
`$C083`, self-modifies a `jsr` to the target, runs it, then reselects
`$C08B` (the steady state every OTHER process expects to find itself
in) before returning -- an explicit software re-select standing in
for the hardware race ProDOS's own MLI entry wins for free.

Docs/KSEG.md's own rules for code that lives IN the segment follow
directly from this document's findings, not new ground:

- **Rule 2** (no `lda LCBANK*` inside the segment, with one
  refinement): selecting `$C08B` from inside the segment unmaps the
  very code that is running -- the write-enable-is-global hazard this
  document's "sibling race" section already covers, one level up.
  Reselecting `$C083` (the segment's OWN bank) from inside the segment
  is the sole exception: a no-op, since it is already selected.
- **Rule 7** (never touch `$D000-$D0FF` or `$D100-$D3FF` of bank 2
  from the segment): `$D000-$D0FF` is ProDOS's own bank-ID byte and
  `$D100-$D3FF` is the QUIT window / `bye` resident (MEMMAP.md sec
  1.2) -- both live in the SAME physical bank as the segment, so an
  ordinary same-bank store from segment-resident code (`PRC_BYE`
  stamping the resident before handing it control) is not a cross-
  bank hazard; a write that could land there from the WRONG bank
  still is.
- **MLI calls from the segment** (rule 3) go through flat `PMLI_*`
  wrappers ending in a `$C083` reselect (`PMLI_RDBLK_CL`/
  `PMLI_WRBLK_CL`, procmli.s) rather than a bare inline `jsr MLI` --
  the MLI reads its own inline call bytes under WHATEVER bank was
  selected when it returns, and this document's own measurement (the
  `RDLCBNK2`/`BIT $C08B` re-select ProDOS's entry performs) is exactly
  the mechanism a segment-resident caller cannot assume protects it,
  since the call site itself is what needs to still be `$C083` after
  the MLI call returns, not `$C08B`.
