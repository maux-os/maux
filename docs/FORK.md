# fork() -- the bank clone, the frame patch, and what it costs

Landed 2026-08-23. `src/kernel/procfork.s`, syscall `SYS_FORK` = 8,
gated by `make check-fork` (`src/test/forktest.s`,
`scripts/check_fork.py`).

Specified by `docs/ARCHITECTURE.md`'s `fork() [v2]` bullet, the frame
contract in `docs/SYSCALL.md` sec 1/item 11, and the extent rule in
`docs/MEMMAP.md` sec 3.2b. The copy-the-text ruling is `docs/PLAN.md`
Wave 6 item 3 (operator, 2026-08-23).

## The call

```
    lda   #<parms          ; IGNORED -- fork takes no parameters
    ldx   #>parms
    ldy   #SYS_FORK
    jsr   $FF00
    ; both processes continue HERE
    ;   parent: A = child pid (never 0), carry clear
    ;   child:  A = 0,                   carry clear
    ;   failure (parent only): carry SET, A = ERR_AGAIN
```

The parms pointer is ignored entirely, so a caller may pass anything.
It is nonetheless worth passing something real: the gate does, because
with `A = 0` going in, deleting the kernel's `sta FRAME_A,x` is
invisible -- see "Proving the teeth" below.

## Two layers

**The bank-clone primitive** copies three regions and nothing else:

| region | size | how |
|---|---:|---|
| `$0000-$00FF` process zero page | 256 B | `FRK_CLN_ZP`, hand-rolled ALTZP window |
| `$0100-$01FF` process stack | 256 B | `FRK_CLN_STK`, same |
| `[PRC_LOWFREE, PCB_BRK*256)` | 1536-48384 B | `FRK_CLN_IMG` -> `BankCopy` |

The image copy's base is `PRC_LOWFREE` (`$0200`), not `LOAD_BASE` --
**widened 2026-08-23 by the S1b wiring stream**, closing the gap the
first cut recorded. The argument is below, under "What is copied that
the first cut skipped".

**The fork syscall** (`PRC_FORK`) allocates a bank, stamps its `$FFxx`
page, runs the primitive, patches the child's trapframe, and duplicates
the PCB's resources.

### Why the two low pages cannot use BankCopy

Page 0 and page 1 are **ALTZP**-governed, and ALTZP is the one switch
RAMRD/RAMWRT cannot stand in for
(`learning:01KW1GTYGVYAPQRGS5P7J66RWD`: "ZP is ALTZP-governed, the one
RAM the bracket cannot steal"). `COPYIN_ENTRY` flips RAMRD and reads
`(K_CPY_PROC),y` -- with ALTZP still main that reads the **kernel's own**
zero page and stack, whatever bank `$C073` has selected, and it does so
silently. The two pages a fork most needs are exactly the two the house
primitive cannot reach.

So `FRK_CLN_ZP`/`FRK_CLN_STK` open their own window: `$C073` = source
bank, `ALTZP` = aux, then `lda PRC_ZP,y` / `sta K_BOUNCEBUF,y` for 256
bytes, then the same in reverse into the destination bank. `PRC_ZP` is
`$0000` and **neither LDA nor STA has a zp,Y addressing mode**, so both
assemblers must emit absolute,Y -- verified, merlin32 emits `B9 00 00` /
`99 00 00`. No zero-page pointer is possible here for the obvious
reason: the pointer would live in the page being copied.

Inside that window the hardware stack **is** the process's page 1, so
there are no pushes: `PHP`/`SEI` before the first flip, `PLP` after the
last, the same discipline `KRN_EXIT` keeps between its ALTZP flip and
its `TXS`. `K_BOUNCEBUF` -- BankCopy's own bank-to-bank staging page -- is
borrowed rather than duplicated; no BankCopy call is in flight while
these windows run.

### The 80STORE bracket, and why it is load-bearing here

With 80STORE set, RAMRD/RAMWRT are **ignored** for `$0400-$07FF` and --
with HIRES also set -- for `$2000-$3FFF`; PAGE2 alone routes those pages
(`learning:01KW1GTYHGXMBZNR6DMQB2F712`, the learning that corrected this
project's fork design from first principles). fork's copied range starts
at `$0800`, so the `$0400-$07FF` window never arises -- but `$2000-$3FFF`
is inside every non-trivial extent.

The failure is **silent**, which is the whole problem. BankCopy advances
source and destination in lockstep from the same base, so an
unbracketed copy of that window is a main->main copy **onto itself**: no
crash, no corruption of the running kernel, nothing in any log -- just a
child whose `$2000-$3FFF` never arrives. `make check-fork` performs its
fork with 80STORE **and** HIRES set for exactly this reason. Run with
the switches off, the gate passes with the bracket deleted.

Since the 2026-08-23 widening the copy also enters `$0400-$07FF`, the
window 80STORE governs **alone** (no HIRES needed) -- so the bracket now
has a second exposure, and the gate a second pair of eyes on it: the
`S_TXT` signature at `$0567` plus the painted `$0200-$07FF` run in the
bulk compare.

### The frame patch -- how one call returns twice

The child's trapframe is not synthesised. It arrives as part of the
copied stack page, already holding the PC `KRN_ENTRY` incremented past
the parent's `jsr $FF00`, and `PCB_SAVEDSP` is set to the parent's
captured `K_CALLER_SP` rather than item 11's fresh `$F9`. **A forked
child is not a fresh process**: it resumes mid-syscall.

`FRK_PTCH_FRM` then changes exactly two bytes of it, at the offsets
`docs/SYSCALL.md` sec 1 defines:

* `FRAME_A` (`$0103,SP`) <- `0`
* `FRAME_P` (`$0104,SP`) <- carry cleared, every other flag (D included)
  left as the caller had it

`KRN_EXIT` patches the **parent's** pair on the way out, from
`K_RESULT` (the child's pid) and `K_RESULT_ERR` (0 -> carry clear).
Nothing else in either frame differs: same PC, same X, same Y.

Writing the child's A is not optional even though the copy already put
something there. At the moment `FRK_CLN_STK` runs, the parent's frame-A
still holds the syscall **argument** -- item 1's register transport --
because `KRN_EXIT` has not run yet. An unpatched child returns that
argument byte and reads as a parent.

### fd duplication

The child's fd **table** is a private copy; the **objects** it names are
shared. All eight slots are copied (unlike spawn's `PRC_DFLT_FDS`, which
copies 0/1/2 only), and each live one gets one `PRC_INC_OBJ_A` -- the
exact inverse of the `PRC_DEC_OBJ` that `PCLS_ONE_FD` runs at
close/exit.

| object | what the increment touches |
|---|---|
| `OFT_FILE` | `OFT_REFCNT`. One ProDOS refnum, one io_buffer, one shared file mark (V7 semantics); the refnum closes when the LAST fd naming it closes |
| `OFT_PIPE_R` | `OFT_REFCNT` **and** `PIPE_RREFS` -- the second keeps a pipe from reporting EOF while the child still holds a read end |
| `OFT_PIPE_W` | `OFT_REFCNT` **and** `PIPE_WREFS` -- symmetrically, a reader blocks rather than seeing EOF until BOTH write ends close |
| `FD_DEV_BASE+` (tty) | nothing. `PRC_INC_OBJ_A` returns immediately on a device handle, matching `PCLS_ONE_FD`, which skips `PRC_DEC_OBJ` for the same values. A tty fd is a constant, not an object |
| `0` | unused slot; stays unused in the child |

`PIPE_USED` -- the fourth counter `procfd2.s:177`'s own comment names --
needs no action, because it is **derived**: it is cleared only when both
ref counts reach zero (procfd2.s's slot reclaim), and this path only
ever raises them.

### Bank exhaustion

`ERR_AGAIN` (`$E4`), not `ERR_NOMEM`. `ARCHITECTURE.md` rules it
("fork() fails cleanly (EAGAIN-style) when the free-list is empty") and
`inc/errno.krn.equ` already spells `ERR_AGAIN` with that ruling
quoted in its own comment. The ramdisk competes for the same pool, so
the condition really is "try again later".

`PRC_ALLC_BANK` reports `ERR_NOMEM` because **spawn's** failure is
different in kind -- an image that will not fit is not transient -- so
fork overrides the verdict for itself rather than changing a shared
allocator's answer out from under spawn. The parent keeps running; the
gate asserts exactly 13 successful forks (the pool is 14 banks and the
first fork's unreaped child holds one) and `$E4` on the fourteenth.

### The allocation is never a warm hit

A retained bank's value is that it already holds a **program's** text; a
fork wants a copy of a **live process**, which is a different thing even
for the same program. `PRC_FORK` zeroes `LZ_WANT` before allocating, so
the child's bank is untagged, `PRC_FREE_BANK` plainly frees it at exit,
and no retained image can ever be confused with a forked one.

## What is NOT copied

**LC RAM (`$D000-$FEFF`, both `$D000` banks) -- settled ABI.**
`ARCHITECTURE.md` cold-read Q3-2 and `MEMMAP.md` sec 3.2: the child gets a
fresh `$FFxx` stamp and **undefined** LC contents. A process that needs
data to survive a fork keeps it below the break. This is not an
oversight -- 16,128 bytes of LC storage would more than double fork's
cost for a region no caller in this tree uses.

## What is copied that the first cut skipped -- the `$0200-$07FF` ruling

The first cut's extent was ZP + stack + `[LOAD_BASE, brk)`, which left
the argv/env block (`MEMMAP.md` sec 3.2a: `argc` at `$0200`, the pointer
arrays, the packed strings at `$0300`) holding whatever the child's
bank held before. The gap was recorded here as "an ABI change that
belongs to whoever rules on it". **Ruled by the S1b wiring stream,
2026-08-23: the extent is `[PRC_LOWFREE, brk)` -- the block crosses the
fork.** Three facts decided it, none of them matters of taste:

1. **The block is read lazily, for the process's whole life.**
   `GETARG` and `GETENV` (`src/liba/argv.s`, `src/liba/env.s`) walk
   `$0200+` on every call and hand back pointers INTO `$0300+`;
   nothing is copied out at startup. `sh` itself reads `ARGC`/`ARGV`
   on every `$0`-`$9` expansion. "Programs read argv at startup" was
   the gap's own defense, and it is not true of this tree.
2. **`docs/SYSCALL.md` item 13c already promised it.** Its
   environment ruling states "a forked child shares the parent's
   block by construction" -- written before fork landed, false under
   the first cut. The widening makes the documented ABI true rather
   than inventing a new one.
3. **The first consumer is the next stream.** S2's forked subshells
   resolve commands through the environment; a subshell whose
   `getenv` walks garbage pointers is the exact silent failure the
   gap predicted, arriving on schedule.

Cost: 1,536 more bytes per fork through BankCopy -- ~59k cycles,
~0.06 s at 1 MHz, a fixed cost independent of `brk`. The child pays it
even for a minimal fork; that is the price of `argv`/`getenv` being
valid on both sides, and it is an order of magnitude smaller than the
text copy the operator already ruled in.

**A break of `$0800` copies the low window and nothing above the
stack, text included.** The floor rule (`MEMMAP.md` sec 3.2b, "only the
program knows its own last symbol") is unchanged: a program that wants
a working fork must set its break at or above its own end of image,
exactly as it must before calling `sbrk`. The kernel cannot check it --
for a fork there is no file and no image length to check against.
`PCB_BRK` = 0 still means "no extent declared" and copies
`$0200-$BEFF`.

## The copy is non-preemptible

The syscall door sets I and nothing clears it -- BankCopy's per-window
`php`/`sei`/`plp` restores the masked state it found, so its comment
about re-enabling between windows does not apply in kernel context. A
fork of a `sh`-sized extent therefore masks interrupts for ~0.65 s at
1 MHz and the clock skews by that much. Accepted, documented v1 tradeoff
(`ARCHITECTURE.md`); a restartable copy with yield points is the later
fix and is deliberately **not** built here.

## Measured cost

`make check-fork`, verilogapple fast backend, 2026-08-23,
**re-measured after the extent widening**. One fork with `brk` =
`$4100` -- a **16,128-byte extent** (`$0200-$40FF`): `sh`'s own image
plus a modest heap, plus the 1,536-byte low window every fork now
carries.

| phase | cycles | rate |
|---|---:|---|
| setup + bank alloc + `$FFxx` stamp | 4,297 | -- |
| zero page + stack page (512 B) | 14,717 | 28.74 cyc/B |
| `[PRC_LOWFREE, brk)` via BankCopy | 621,614 | **38.54 cyc/B** |
| PCB + cwd + fds + frame patch | 5,982 | -- |
| **total syscall** | **646,610** | **0.647 s at 1 MHz** |

38.54 cyc/B against `docs/PROCIO.md`'s 39.07 model (predicting 630,120
for this extent) -- 1.4% under, i.e. the model holds. The widening
itself cost 58,847 cycles against the first cut's measured 587,763 --
the ~0.06 s the ruling above priced in.

The two low pages cost 28.74 cyc/B rather than 38.54 because they skip
BankCopy's per-chunk `$C073` window setup entirely: `lda abs,y` (4) +
`sta abs,y` (5) + `iny` (2) + `bne` (3) = 14 cycles per byte per pass,
two passes. They are a **fixed** 14,717 cycles regardless of extent.

**Fixed cost of any fork: 84,193 cycles** (24,996 bookkeeping + ZP +
stack, plus the 1,536-byte low window at 38.54 = 59,197). Everything
else is `38.54 x (brk - $0800)`.

Extrapolating to the no-`brk` case: 48,384 B x 38.54 + 24,996 ~
1.89 M cycles ~ **1.89 s**, matching `MEMMAP.md` sec 3.2b's whole-window
figure (updated with this widening) from the other end.

## What fraction is text -- the number the deferred optimisation needs

For the measured case (`sh`'s image as it was when the extent was
sized: 14,121 B, `brk` at `$4100`; `sh.bin` is 14,172 today, which
shifts the split by under 0.4% and none of the conclusions):

| | bytes | share of copy | cycles |
|---|---:|---:|---:|
| text | 14,121 | **87.6%** | 544,224 |
| heap above the image | 471 | 2.9% | 18,152 |
| argv/env low window | 1,536 | 9.5% | 59,197 |
| fixed (ZP, stack, bookkeeping) | 512 | -- | 24,996 |

So a text-skipping fork of `sh` would cost ~102,400 cycles instead of
646,610 -- **6.3x faster, an 84.2% saving.** That is the headline number,
and it is exactly the number that is unavailable: `sh` is one of the 23
`DIRTY-TAIL` programs (`STICKY.md` sec 29), so sharing a retained bank's
text would leave parent and child differing in a region fork promises is
shared.

**The saving is large precisely where it cannot be taken.** Ranking the
fleet by what the optimisation would be worth:

| program | image | eligible? | cycles the skip would save |
|---|---:|---|---:|
| `as` | 16,027 | no -- `DIRTY-TAIL` | 618,161 (0.62 s) |
| `sh` | 14,121 | no -- `DIRTY-TAIL` | 544,647 (0.55 s) |
| `ls` | 3,269 | **yes** | 126,086 (0.13 s) |
| `tr` | 1,584 | **yes** | 61,094 (0.06 s) |
| `mv` | 1,380 | **yes** | 53,227 (0.05 s) |
| `echo` | 814 | **yes** | 31,396 (0.03 s) |

The ten `TEXT_IMMUTABLE` programs (`cat date echo ls mkdir mv ps pwd rm
tr`) average 1,332 bytes of image. **The best case in the whole eligible
set is `ls` at 0.13 s, and the average is 0.05 s** -- against 0.55-0.62 s
for the two programs that would actually benefit and cannot. Whoever
revisits the certification channel should weigh new ABI against a
~0.05 s average saving on programs that are already the cheapest to
fork.

(One caveat on `sh` specifically: a real subshell fork would carry more
heap than the 471 bytes measured here, which shifts the ratio toward the
heap and makes the skip worth proportionally less, not more.)

## Proving the teeth

Three sabotages, each shown landing, each red with real output, each
reverted. Recorded including the one that did not work.

**1. Delete BankCopy's `sta CLR80STORE` (`src/kernel/bankcopy.s`, 1
line).** RED:

```
FAIL: C_HIRES = $00, expected $C3 -- $2ABC crossed
FAIL: C_HIEND = $00, expected $D4 -- $3F00 crossed
FAIL: 8160 of 12992 compared bytes differ between the parent bank and
      the child bank; first at $2000: parent $20 child $00
```

Exactly the predicted shape: the whole `$2000-$3FFF` window, and only
that window, fails to arrive. Nothing crashed; without the two HIRES
signatures and the bulk compare this would have been invisible.

**2. Delete `FRK_PTCH_FRM`'s `lda #0 / sta FRAME_A,x` (2 lines) --
FIRST ATTEMPT WAS A NO-OP.** It changed 774 binary bytes and the gate
stayed **green**, because the harness called fork with `A = 0`: the
child's inherited frame-A was already the value the patch would have
written. The harness was fixed to pass a nonzero parms pointer (which
fork ignores, so it costs nothing), and the same sabotage then went RED
-- by deadlock, which is the honest symptom: the child took the parent
branch, both processes waited on a pipe neither would write, and
`R_DONE` was never set.

```
FAIL: parent never finished: done=$00 err=$00 screen='MAUX FORK ...'
```

**3. Delete the `jsr FRK_CLN_ZP` call (1 line).** RED:

```
FAIL: C_ZP = $00, expected $5A -- zero page crossed the fork
FAIL: 96 of 12992 compared bytes differ between the parent bank and the
      child bank; first at $0090: parent $AC child $00
```

96 bytes is exactly the `$0090-$00EF` zero-page run the harness paints --
which is why it paints it. Without that fill, both banks' zero pages
would have been zeros above `$81` and the bulk compare would have passed
with the clone deleted.

## Gate design notes worth keeping

**A harness cell inside a region the harness itself paints is a gate
that lies.** The first version filled `$0C00-$40FF` straight through,
which put the pattern on `R_DONE`/`R_ERR` at `$11F0`/`$11F1`. The poll
loop read `$E1`/`$E0` out of them and reported a `brk` failure that had
never happened. The fill is now two runs with `$1000-$16FF` left alone.

**Bank exhaustion runs BEFORE the `wait()`.** An unreaped zombie keeps
its bank, so the child's result block stays readable in bank 2 while the
loop drains the rest of the pool. Reap first and the free list hands
bank 2 straight back out (it is LIFO), a later fork overwrites the very
results the gate is about to read, and the gate reports on the wrong
process.

**The blob's one long jump.** The process under test is copied to
`$0800`, so a label inside it is not the address it runs at. Every
control transfer is a short branch except the parent/child split, which
spells the runtime address as `LABEL+LOAD_BASE-PARENT_PROC` -- real
Merlin-8 has no operator precedence and evaluates strictly left to right
(`learning:01M051DJW89KV4JYM1EC9SDZ5Y`), so that is
`(LABEL+$0800)-PARENT_PROC` under both assemblers, which is the value
wanted.

## Wired into the shipping system (2026-08-23, stream S1b)

Every process-bearing manifest -- all 28 -- now runs its dispatch table
to 8 and `put`s `src/kernel/procfork.s`: `SYS_FORK` dispatches in
`v1-system`, `sh`, `play` and every other kernel image, and `SYS_CLOCK`
(entry 7, `procfile3.s`, already in every put chain) is wired
fleet-wide with it rather than riding as a hole.

What the wiring cost, measured against the pre-wiring tree:

- **+398 bytes per kernel image** (procfork.s ~394 + 4 dispatch
  bytes); +396 for `sumdatetest` (already had clock entries); +468 for
  `MAUXSH.SYSTEM` (the fork smoke probe below rides in its boot body).
- The raw block images (`forktest`, `processtest`, `argvtest`) still
  fit their hard `ds $4800-*` pads at 16,384 bytes; the largest
  .SYSTEM image is `MAUXEXPR.SYSTEM` at 18,401, nowhere near the
  ProDOS `$BF00` ceiling.
- The liba wrapper `SC_FORK` (`src/liba/syscallp.s`) adds 10 bytes to
  each of `sh`/`find`/`ps`/`date`; `sh.bin` is 14,172 of its 16,384
  tripwire. It emits no storage, so `date`/`ps` stay `TEXT_IMMUTABLE`.

**The proof it stays wired**: `src/test/shtestb.s` -- a boot body that
FOUR gates boot: `check-sh` and `check-v1-system` (which assert the
probe), plus `check-shwarm` and `check-textaudit` (which merely pay
its cost) -- forks, reaps, and records pid/status at `$1293-$1295`
before it spawns `sh` (step marker 7). A manifest that ever drops
back to `K_DISP_COUNT` 6 goes red in the shipping image itself, not
only in forktest. The probe sits upstream of `check-v1-system`'s
exactly-pinned `ps` table and is order-neutral only because the free
list is LIFO and the forked bank is untagged, so the reaped bank is
restored exactly -- the invariants are recorded at the probe itself in
`shtestb.s`. `check-userland`'s choke-point grep also now includes
`SYS_FORK`/`SYS_PSTAT`/`SYS_CLOCK`: userland reaches fork through
`SC_FORK` only.
