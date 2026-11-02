# Do RamWorks aux-bank CONTENTS survive a reset?

Status: MEASURED 2026-09-26. This is the load-bearing question under
`bye -r` (docs/BYE.md: suspend maux, reboot into another disk -- a
game, say -- and come back on the NEXT maux boot). Nobody had measured
it before this pass. `make check-ramworks-reset` (`scripts/
check_ramworks_reset.py`) guards the main result permanently.

## The mechanism under test

`src/kernel/procfile3.s`'s `PRC_HALT_CORE` forces the NEXT Ctrl-Reset
to take the COLD-START path with three instructions, and its own
header explains why: the //e ROM trusts $03F2/$03F3 as a warm-start
vector only if $03F4 equals $03F3 EOR $A5.

```
lda   $03F3
eor   #$5A            ; $5A != $A5, so this can never match
sta   $03F4
```

`bye -r` will use exactly this. This gate reproduces it exactly rather
than reasoning about it, and it is backend-agnostic: verilogapple's
`key_reset` open/closed-apple cold-path override is documented as
RTL-BACKEND ONLY (`learning:01KWF4QBFJ8EJWK21JVP16VEM7`), confirmed
live on the fast tier (its own response says `"warm reset (open/
closed-apple cold-path not modeled)"` even with the apple keys held).
The power-up-byte trick is the only way to force cold on the fast tier
-- and it is also the actual mechanism, so it is not a compromise.

## What was patterned, and where

Two non-zero, non-annex banks, 5 and 6 (arbitrary; nothing this build
allocates by default reaches that high), filled edge-to-edge with a
bank-and-address-dependent byte (`(addr ^ (addr>>8) ^ bank*0x29) &
0xFF` -- not 0, not $FF, not a flat $AA) across:

- `zp`: $0000-$01FF (that bank's zero page + hardware stack)
- `annex`: $0200-$BFFF (the 47.5K a maux process bank actually uses)
- `lc`: $D000-$FFFF (that bank's own language card)

`$C000-$CFFF` is aux I/O-select space, not RAM, and was skipped.

**Bank 0 is out of scope.** /RAM already owns it (TN #26,
`learning:01KW1GTYH4NRG0F8M7AAT6EG9Z`) and `bye` already saves and
restores it through a second bank (docs/BYE.md's 2026-09-26 ruling).
This measurement is about the OTHER banks -- the ones `bye -r` assumes
just sit there while a game disk runs.

## Results: the fast backend (verilogapple), `scripts/check_ramworks_reset.py`

| # | reset kind | checkpoint | mismatches (zp/annex/lc, banks 5+6) | $C073 before -> after |
|---|---|---|---|---|
| 1 | WARM (valid $03F4) | after ROM handler, no disk | 0 / 0 | 0 -> 0 |
| 2a | COLD (byte trick), no disk | after ROM handler, no disk | 0 / 0 | 0 -> 0 |
| 2b | COLD (byte trick), play.po | after ProDOS booted, PC=$2000, before MAUX.SYSTEM runs | 0 / 0 | 2 -> 0 |
| 3 | full maux reboot (same run as 2b) | after maux's own kernel init, fresh shell prompt | 0 / 0 | 2 -> 0 -> 2 |

Every byte of both banks, across all three regions, read back exactly
as written in every case. `$03F4`'s validity was confirmed at each step
(case 1: valid pair `$E0`/`$45` already installed by the machine's own
prior cold boot, untouched; cases 2a/2b: forced to `$E0`/`$BA` and
`$FF`/`$A5`-invalidated respectively, confirmed invalid before the
reset). `$C073` (`ramworks_bank`) went from 2 (the running shell's own
bank) to 0 by the time PC reached $2000 -- i.e. sometime during the ROM
cold-start + ProDOS/SmartPort boot, NOT from the reset event itself
(confirmed by sampling immediately after `key_reset` returns, before
any further `resume`: already 0 at that point, cycle 3.2M in). This
matches the AE manual's own documented convention (RamWorks III/basic
manual ch. 7, `learning:01KYYJ98T5R0M9K1AW2550M132`): *"All programs
should start by initializing the bank register to 0 (video bank)"* --
ProDOS's boot code (needing bank 0 for its own /RAM driver) is doing
exactly what the manual tells well-behaved software to do. It is not
evidence against "$C073 survives the reset itself" (also confirmed
directly: in the no-disk cases, where nothing runs to reselect a bank,
$C073 does not move at all).

Grade: **[likely]** on this backend alone, per HACKING.md's confidence grades (fast
backend proves behaviour, never hardware fidelity) -- raised to
something stronger below for the specific case MAME could also run.

## Cross-check: MAME (`-aux rw3`), the sanctioned fidelity verifier

RamWorks III IS configurable in MAME (`docs/MAME.md`'s own working
recipe: `apple2ee -aux rw3 ...`), so this is not a "cannot measure"
case. Ad hoc Lua scripts were written against `mame 0.286`
(not checked into the tree -- see "What was NOT kept" below)
using the CPU's own MMU-mapped `program` address space and the REAL
softswitches ($C073, $C002-$C005 for RAMRD/RAMWRT), not a raw
memory-region peek -- the same path real 6502 code uses. One gotcha
cost real time and is worth recording: **`-autoboot_script`
RE-EXECUTES THE WHOLE FILE on every machine reset**, including one the
script itself triggers via `manager.machine:soft_reset()` -- a `local`
phase variable silently reinitializes on the re-run; only plain Lua
globals (no `local`) survive across it. A second gotcha: on this
driver, `$C0xx`-family soft switches are flipped by WRITE access
(`mem:write_u8`), not read access, matching `check_mame.py`'s own
`INTCXROM`/`SLOTC3ROM` precedent but NOT its `$CFFF`/`$C30C` one (those
two are genuinely read-triggered, a different mechanism).

**Case tested: COLD START (the byte trick), no disk, $0200-$BFFF only**
(zp/lc were not attempted on MAME in this pass -- scope reduction,
stated plainly). Boot to a settled state (~5 s), fill banks 5 and 6,
force the invalid power-up byte, `soft_reset()`, re-settle (~5 s),
read back:

```
PRECHECK (before reset):
BANK5: 0/48640 mismatches
BANK6: 0/48640 mismatches
forced power-up byte: f3=$E0 f4=$BA (invalid=true)
POSTCHECK (after soft_reset, settled again):
BANK5: 0/48640 mismatches
BANK6: 0/48640 mismatches
post-reset f3=$E0 f4=$45
```

**Content of both non-selected banks survived byte-for-byte on MAME
too.** This turns the annex-region, cold-start, no-disk result from
[likely] into something stronger: two independently-implemented
emulators, using two different write paths (verilogapple's raw-DRAM
debug poke vs. MAME's genuine CPU-bus softswitch writes), agree.

## A second, DISPUTED finding: the CURRENTLY-SELECTED bank is not free

While building the MAME cross-check, a further, more interesting
experiment fell out almost for free, and it does NOT agree between the
two backends -- reported here in full rather than smoothed over.

**Setup**: boot maux on MAME to a real shell prompt (play.hdv, AppleIISd
+ RamWorks III + UltraTerm + Mockingboard -- `docs/MAME.md`'s own
working "play" slot layout; `-sl3 ""` alone was tried first and simply
HANGS the boot on this driver -- a documented trap for whoever tries
this next). Fill banks 5 and 6 as above, then, deliberately, leave
`$C073` pointing at bank 6 (simply because it was the last one checked)
before forcing the cold-start byte and calling `soft_reset()`.

```
EARLY CONTENT CHECK post-reset (frame 305, ~80ms after the reset):
BANK5: 0/48640 mismatches
BANK6: 508/48640 mismatches, first at $0200 want $F4 got $AD
```

Bank 6 -- the one `$C073` pointed at going into the reset -- took
~500 stray byte writes (~1% of the region) concentrated from $0200
upward; bank 5 was untouched. Repeating with `$C073` deliberately left
on bank 5 instead MOVED the corruption to bank 5 and left bank 6 clean:

```
deliberately left $C073 pointing at bank 5 before reset
EARLY CONTENT CHECK post-reset (frame 305):
BANK5: 513/48640 mismatches, first at $0200 want $CF got $AD
BANK6: 0/48640 mismatches
```

Reproducible, and it tracks the SELECTED bank, not bank identity --
this is a real mechanism on MAME's model, most plausibly the //e ROM's
own aux-64K self-test/detection code (a documented, generic part of
POST that toggles RAMRD/RAMWRT to test for the auxiliary 64K the
built-in 80-column card provides) landing its own writes wherever
`$C073` happens to be parked, because the ROM has no concept of
RamWorks banks and no reason to leave the switches alone.

**This was NOT reproduced on verilogapple's fast tier.** The identical
methodology -- entering the monitor for real (`CALL -151`), then a
genuine keystroke-driven monitor STORE (`C073:05`, which is a real ROM
routine performing a real bus write, not a debug backdoor) to select
bank 5 for real, confirmed via `softswitches()` reading
`ramworks_bank=5` -- then the same cold-start byte trick and
`key_reset()` -- came back **0/48640 mismatches** in bank 5. No
corruption at all.

**Grade: [reported], disputed, not [fact].** Per HACKING.md's confidence grades's own
hierarchy, MAME is a sanctioned fidelity verifier and the fast tier is
explicitly not ("proves behaviour, never hardware fidelity"), so MAME's
result is provisionally the more credible of the two -- most likely
explained as a gap in verilogapple's ROM model (it may simply not
implement the aux-memory POST self-test the real enhanced-//e ROM and
MAME's ROM dump both run) rather than a MAME-only artifact. But it has
not been checked against a THIRD source (real hardware, AppleWin, or a
disassembly of the actual ROM self-test routine), and HACKING.md is
explicit that a `[likely]`/`[reported]` claim a design depends on must
be verified before it is load-bearing. This is filed as a CONFLICT
between the two backends, not a correction of either.

**Actionable regardless of who is right.** This is cheap to defend
against and costs nothing to do defensively: `PRC_HALT_CORE` (and
therefore `bye -r`) should explicitly select a neutral, disposable bank
(bank 0, or whatever is truly free) via `$C073` immediately before
flipping the power-up byte and spinning, rather than leaving it
pointed at whatever bank a live process last selected. If the MAME
finding is real hardware behaviour, this closes it outright; if it
turns out to be MAME-only, the mitigation is free and maux loses
nothing by taking it.

## What was NOT kept in the tree

The MAME Lua scripts used for the cross-check and the dispute above
are NOT committed -- they were exploratory, needed hand-fixing twice
(the softswitch write-vs-read gotcha, the autoboot-script-reruns-on-
reset gotcha) and the with-disk full-maux-reboot version never reached
a fresh shell prompt within budget after `soft_reset()` on this
driver+romset (40 simulated seconds, ~8x the ~5s the FIRST cold boot
took) -- an unresolved harness or peripheral-reset question in its own
right, separate from the content-survival question, and NOT chased
further in this pass. `make check-ramworks-reset` therefore covers only
the fast-backend measurement; the MAME numbers above are a snapshot,
reproducible from this document's own recipe (`apple2ee -aux rw3 -sl6
"" -sl7 "" -video none -sound none -nothrottle`, an autoboot script
along the lines described, `mame 0.286`) but not gated.

## Bottom line

- **RamWorks aux-bank CONTENTS in banks NOT selected via $C073 at the
  moment of a Ctrl-Reset survive completely** -- warm, PRC_HALT's cold
  path, and a full maux reboot through that path -- confirmed on the
  fast backend for all three reset kinds across zp+annex+lc, and
  cross-checked on MAME for the cold/no-disk/annex case. `bye -r`'s
  central assumption HOLDS for this part.
- **$C073 itself is unaffected by the reset event** (fast backend, no-
  disk cases); ProDOS's own boot code reselects bank 0 as a side effect
  of bringing up /RAM, which is expected and harmless.
- **The bank CURRENTLY SELECTED at reset time may not be free of a
  small amount of stray corruption** -- disputed between the two
  emulators, MAME-only so far, [reported] not [fact], but cheap to
  defend against regardless. `bye`'s implementation should select a
  neutral bank before halting.
- **Nothing here says contents do NOT survive** for any of the three
  reset kinds as officially scoped (zp/annex/lc of a non-selected
  bank). The one open thread is the disputed selected-bank finding
  above, and the with-disk MAME full-reboot harness that did not
  complete in this pass.
