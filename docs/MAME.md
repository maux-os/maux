# MAME: the second rig

Status: LANDED 2026-08-18. `make check-mame` (which builds the romsets
with `vendor-mame-roms` first, since KFIX12) boots maux end-to-end under MAME -- an emulator that shares no code with
verilogapple -- from block 0 through ProDOS, the kernel, a Mockingboard
preemptive timer, and an interactive `sh` session on the UltraTerm.

Until this spike, **maux had never executed outside verilogapple**, while
HACKING.md's own confidence rules warn against verifying verilogapple
against verilogapple. One afternoon against MAME found and fixed **three
real kernel bugs** that every green verilogapple gate had sailed past,
plus two verilogapple model gaps for task #9. That is the argument for
keeping the second rig alive, stated once here: an independent
implementation is a fuzzer for your hardware assumptions.

## Last verified: 2026-10-26, ALL GREEN (MAME v0.286, Mac)

Run from a tree at main `390ad45c` plus documentation commits only, so
this is effectively main. Ten assertions, every one green:

* the hello image boots -- `MAUX ALIVE` on the text page;
* the play image boots to an INTERACTIVE SHELL on the Mockingboard 6522
  timer tier, on the AppleMouse VBL tier (real 68705 protocol), AND on
  a RamWorks powered up with `$FF` in every bank;
* UltraTerm v3 and v1 both read back R0-R11 equal to their own ROM
  entries, synced -- 216 rows at 60.3 Hz and 384 at 30.6 Hz from each
  card's own format-4 entry;
* a full `ed` session typed DURING its own binary load survives --
  keystrokes captured, file written, shell reprompts;
* a `bye` round trip returns to a working shell, including with a VBL
  tick forced to be latched at `TMR_QUIESCE` (hits `PRC_BYE`, `STALL`,
  `QUIESCE`).

Why this run happened at all, and the finding worth more than the pass:
**`check-mame` is excluded from `CHECK_ALL_TARGETS`** (the Makefile says
"it needs `brew install mame`"), so it runs only when someone
deliberately remembers it. That is the same shape as `check-selfmake`:
a gate outside the sweep is a gate whose colour nobody knows. This one
is the rig that "found three real kernel bugs every verilogapple gate
sailed past", which makes it the worst candidate in the tree for silent
neglect. Before this run its last recorded exercise was 2026-10-18.

TRIGGER, since the exclusion is a deliberate accepted gap and needs
one: revisit the exclusion if (a) the Linux box gains MAME, at which
point there is no reason it is not in `check-all-box`; (b) any change
lands in banking, the console, timers or the spawn path -- the
Makefile's own comment already says to run it then, which is advice
with nothing enforcing it; or (c) a release is cut, where "runs on a
second rig" becomes a public claim. A loudly-skipping gate is NOT the
answer on its own: a gate that skips is a gate that passes vacuously,
and this tree has been bitten by vacuous runners before.

Operator decision, not taken here: whether `check-mame` joins an
optional Mac tier so a sweep on a MAME-equipped machine runs it.

One trap met on the way. The romsets are a build product whose make
rule depends on `vendor_mame_roms.py`, so copying a cached
`vendor/mameroms/` in with `cp -p` -- preserving mtimes, as the house
rule about copied `build/` directories recommends -- makes every zip
look OLDER than the script and the five pinned downloads are fetched
again. Harmless, and it does leave the set freshly verified, but
`touch vendor/mameroms/*.zip` after such a copy saves the round trip.

## What runs

`scripts/check_mame.py`, two phases, both headless, both asserted from
inside the machine by a Lua autoboot script:

1. **hello** -- `build/maux.po` (raw block image) on an AppleIISd card in
   slot 7. The boot ROM finds the card, the card loads block 0, "MAUX
   ALIVE" lands on the text page.
2. **play** -- `build/play.po` (ProDOS volume) on the same card, RamWorks
   III in the aux slot, UltraTerm (enhanced) in slot 3, Mockingboard in
   slot 4. ProDOS 2.4 boots, launches MAUX.SYSTEM, the timer probe
   selects the Mockingboard tier, the VT suite draws, `sh` spawns; the
   gate types `ls`, and asserts the echoed command, the directory
   listing, and a fresh `$ ` prompt -- read back from the UltraTerm's
   VRAM through the `$CC00` window.
3. **play-mouse** (added same day, completing the interrupt matrix) --
   the same image with the AppleMouse in slot 5 instead of the
   Mockingboard. MAME's `a2mouse` emulates the card's **real 68705 MCU
   running its actual mask ROM** (341-0269, vendored from the
   apple2.org.za mirror), so this phase exercises the genuine
   INITMOUSE/SETMOUSE/SERVEMOUSE handshake protocol -- and, because
   mouse-mode ticks land in the a2sd driver's CLI windows too, the
   `MAIN_IRQ_SHIM` mouse branch.
4. **type-ahead under I/O** (the responsiveness gate, docs/SYSCALL.md
   sec 7.8) -- a complete ed session is typed in one burst so most of it
   arrives WHILE ed's 44KB binary is still streaming off the disk.
   With the MLI interrupt bracket + the tty raw ring, every keystroke
   survives, the file gets written, and the shell reprompts. Verified
   to fail against the unbracketed kernel. (MAME detail: the IIe
   boots with Caps Lock engaged -- a TOGGLE ioport field that flips on
   simulated presses, not `set_value` writes.)

Machine: `apple2ee -aux rw3 -sl3 ultratermenh -sl4 mockingboard -sl6 ""
-sl7 a2sd -hard play.hdv` (phase 3 swaps `-sl4 mockingboard` for
`-sl5 mouse`). A `.hdv` is our `.po` bytes renamed -- MAME's hard-disk
media accepts raw blocks. `-sl6 ""` drops the default Disk II
controller (ROMs not vendored).

## ROMs: almost everything was already on disk

`scripts/vendor_mame_roms.py` builds `vendor/mameroms/` and is mostly a
renaming exercise, verified against `mame -listroms` CRCs:

| MAME wants | is byte-identical to |
|---|---|
| `342-0304-a.e10` / `342-0303-a.e8` | the two halves of verilogapple's `iie_cd_ef.rom` |
| `342-0265-a.chr` | `iie_video.rom` |
| `frm_b5c9.bin` / `chs_5604.bin` / `ult_251c.jed` | `ultraterm/firmware_v3.bin` / `chargen_v3.bin` / `pal_u4_v3.jed` |
| `341-0132-d.e12` | keyboard layout ROM, downloaded (reactivemicro), pinned |
| `appleiisd.bin` | AppleIISd firmware (GPL), downloaded (author's repo), pinned |
| `sc01a.bin` | 512-byte placeholder -- the Mockingboard's Votrax speech chip, never touched; MAME warns on the checksum and runs |

## What the second rig found

**1. `UT_CLAIM` claimed the `$C800` window without releasing it first
(kernel bug, fixed).** MAME's a2bus grants the shared `$C800` space to a
card's `$Cnxx` access only when the window is FREE (`$CFFF` releases);
verilogapple models last-claimant (any access steals); on real iron each
card latches independently, so claim-without-release leaves TWO cards
driving the bus. Under MAME the UltraTerm's claim silently failed, and
the tty's VRAM writes landed in the a2sd's **writable firmware EEPROM**,
corrupting the disk driver mid-boot -- the crash appeared as a wild jump
into ASCII spaces (`jsr $2020`) and a BRK at `$BECC`. The fix is one
instruction (read `CLRC8ROM` before the claim), correct under all three
arbitration models, and safe because well-built card firmware (AppleIISd
does `BIT $CFFF` at both entries) re-claims on every call.

**2. The Mockingboard timer tier was fictional (kernel bug, fixed).**
Three stacked problems, invisible while verilogapple's mouse always won
the probe: the VIA base address used the `$C080|(slot<<4)` convention
but the Mockingboard decodes `$Cn00` space (`$C400` for slot 4); the
probe was a single `$FF` readback, which a floating bus passes (MAME's
floating bus carries video data, `$FF`-heavy on blank screens); and the
"found" path armed nothing -- presence-only by design, leaving a
tickless scheduler starving a runnable `sh` behind a never-yielding
idle process. Now: two-value latch-echo probe (`$A5`/`$5A` through
T1L-L), T1 free-run at ~60 Hz (17045 cycles at 1.0227 MHz), ISR acks by
reading T1C-L.

**3. Hosted-mode main-context interrupts died in ProDOS (kernel bug,
fixed).** The kernel's interrupt design assumed I=1 through all
kernel/main execution, so ticks only land in process banks where the
per-bank `$FFxx` page owns `$FFFE`. Third-party ProDOS drivers break
the assumption -- and the `$CnFE` "interruptible" attribute cannot be
used as a guard: the AppleIISd DECLARES non-interruptible, saves the
caller's P at entry and restores it before its dispatch, yet its
slot-discovery preamble is bracketed `SEI ... CLI` with the `CLI`
unconditional -- a dozen-instruction window where interrupts are
force-enabled regardless of the caller's mask (a firmware slip that
ships in EEPROM; CFFA-class drivers carry similar windows, and a
genuinely interruptible card makes the window the whole call by
design). A pending tick fires there mid-MLI in main context, funnels
ROM `$FFFE` -> `$03FE` -> ProDOS's receiver, and an unclaimed interrupt
there is the **"RESTART SYSTEM-$01"** box. The kernel now owns `$03FE` (`MAIN_IRQ_SHIM`,
timer.s): ack the armed source, count the tick, restore A from `$45`
per the ROM contract, RTI. Deliberately no `SCH_TICK` from there -- no
context switch out from under a driver mid-MLI; the quantum stretches
slightly during disk I/O.

**4. UltraTerm paging needs ctrl-register bit 4 (kernel fix +
verilogapple model gap).** `$C0B2` bit 4 (`VTEMU`) selects native
UltraTerm addressing; with it clear the card is in Videoterm-emulation
mode and bits 3-0 are NOT a VRAM page. MAME's `a2ultraterm` (whose
constants match the Videx manual's ctrl1 layout) ignored our page
writes entirely -- all sixteen "pages" piled into one, superimposing
every screen row. verilogapple documents the bit in its model header
but ignores it (`page = low nibble`, unconditionally), which is how the
driver ran green without setting it. Every `UT_PAGE_CTL` write now
carries `UT_VIDSEL+UT_VTEMU`.

**5. The mouse driver spoke a fictional dialect of the 68705 protocol
(kernel bug, fixed -- found the moment the real MCU ROM was vendored).**
Three layers, all masked by verilogapple's synchronous behavioral
model: (a) `MOUSE_SND_CMD` pulsed the write-clock blind in ~12 cycles --
the real MCU polls its port and requires the documented four-phase
handshake (raise WRREQUEST, wait WRACK, drop, wait clear; MCU ROM
`$083`); (b) `M_SET` alone armed nothing -- on the real firmware
SETMOUSE only stores the mode byte (`$46C`), and it is **INITMOUSE**
that unmasks the MCU's timer interrupt and loads its divider (`$547`:
`BCLR 6,TCR / STA TDR`), via a 3-phase exchange (command, reply byte
out, sync byte in -- both values discarded); (c) SERVEMOUSE is not
fire-and-forget -- the MCU deasserts IRQ and then **blocks at `$4EB`**
presenting its interrupt-status byte until the host completes the read
handshake, so the old read-free ISR would have wedged the controller
after the first tick on real hardware. All three fixed
(`MOUSE_SND_CMD` handshake, `MOUSE_RD_BYTE`, `TMR_INT_MOUSE` sends
INITMOUSE, both ISR paths consume the reply); measured 60.0 Hz on both
rigs afterward. Protocol provenance: the 68705 mask ROM disassembled
via MAME's debugger (`dasm`), cross-checked against the A2USB
project's independent reverse engineering.

**6. The ROM interrupt chain corrupts block I/O through ZP $45 (kernel
fix, 2026-08-19 -- found when the type-ahead gate went from green to
red and back across unrelated rebuilds).** The //e ROM's IRQ handler
saves the interrupted accumulator at ZP `$45` before dispatching
through `($03FE)` -- and `$45` is the HIGH BYTE of the block driver's
live buffer pointer (ProDOS's `$42-$47` device convention; AppleIISd's
own source names `BUFFER := $44`). Any main-context tick taken while
that pointer is live redirects the rest of the transfer to a garbage
page. Worse, ticks pend during the kernel's masked stretches and get
taken exactly at the driver's unmasked windows, turning a tiny window
into a magnet. The interrupted A at that moment is deterministic
(`$C7`, the just-loaded CURSLOT byte), so the corrupted transfers land
in `$C7xx` -- I/O-select space, where writes hit the a2sd's EEPROM
(finding 1's nvram trap, by a second route). Yesterday's phase-4 pass
was dice. Fix: `TMR_OWN_03FE` patches main's **LC `$FFFE`** to point
directly at `MAIN_IRQ_SHIM` (the MLI runs with LC read-enabled, so
that is the vector actually taken), the shim saves its own registers,
and the ROM -- with its `$45` stomp and the `$C3FA` slot-3 hop -- never
runs for main-context IRQs again. Verified by eight consecutive
all-phase gate runs.

**RESOLVED (2026-08-19): the phase-4 "flake" was the harness, not the
kernel -- and it was never random.** A 12-run repro loop showed strict
PASS/FAIL alternation (6/6), which no timing race produces. The
failing runs' VRAM dumps were entirely UPPERCASE (`$ ED X` / `A` /
`?`): maux's `ed` correctly rejects `A`, and the "`?` to a valid `a`"
signature was Caps Lock, not corruption. Mechanism: MAME persists
input state in `cfg/apple2ee.cfg` across runs (observed alternating
between `<keyboard tag=":" enabled="1"/>` and an empty `<input>`
section -- the natural-keyboard enable flag that `natkeyboard:post()`
sets), and that state flips the Caps Lock TOGGLE's effective boot
state; the Lua script's unconditional simulated Caps Lock press then
lands alternate runs in caps mode. The earlier "green to red and back
across unrelated rebuilds" behavior that led into finding 6 is this
same alternation (the `$45` stomp it uncovered was real regardless --
verified by its own eight-run streak). Proof chain: fresh `.hdv` per
run still alternated (ruling out image mutation by ed's `w x`);
deleting `cfg/` per run went 5/5 green, then two consecutive full
4-phase gate runs -- which the alternation cannot survive -- passed.
Fix: `run_mame` now deletes `cfg/` alongside `nvram/` before every
run. Phases 2/3 never noticed because their asserts case-fold; only
phase 4 feeds lowercase to a case-sensitive consumer.

**7. The mouse VBL drain is verified here, `[fact]` (KFIX6 item 1,
2026-10-18, MAME 0.286).** `TMR_QUIESCE`'s `M_SERV` + reply read after
SETMOUSE mode 0 (KFIX5-NOTES 10.6) takes a tick the controller latched
before `bye` masked interrupts. The real 68705 answers it both ways -- reply
`$00` with nothing latched, `$08` with a tick latched -- and without the
drain a latched tick is taken in the AppleIISd driver's own `CLI` window
during ProDOS's QUIT read and the machine ends in a BRK storm at `$D221`
(verilogapple parks later, in the shim's wait; same cause, a different
unmasked window). `check_mame.py` phase 5 forces the latch with a MAME
debugger breakpoint (`-debug -debugger none -debuglog`, `b@` pokes at
`PRC_BYE`), as check-tenant row 9 does on verilogapple; `--bye-only --play
PO --sym LISTING` runs it against another build for the teeth. The natural
`pwd`-then-`bye` phase did not reproduce on MAME (the 60 Hz tick and the
frame notifier are phase-locked). Detail: docs/KFIX6-NOTES.md sec 1.

## verilogapple model gaps surfaced (feed task #9)

- **`$C800` arbitration**: verilogapple last-claimant vs MAME
  claim-when-free vs iron both-latch. The protocol that is correct
  everywhere is release-then-claim; the models should still converge --
  and the iron truth (independent per-card latches, bus fight when two
  are set) is worth modeling as a loud error.
- **UltraTerm `VTEMU` bit**: verilogapple should refuse (or
  Videoterm-bank) page writes with bit 4 clear, as the manual and MAME
  agree the card does.
- **Empty-slot reads**: verilogapple returns quiet values where MAME
  models the floating bus; the single-value Mockingboard probe
  false-positived only under a hostile bus. Probe design rule going
  forward: two distinct non-`$FF`, non-`$00` values, or a dynamic
  readback (a counting timer), never one `$FF` echo.
- **AppleMouse model leniency**: verilogapple's `mouse_card.h` latches
  commands synchronously on a bare clock edge (no WRACK handshake
  required), starts VBL generation on `M_SET` alone (no INITMOUSE
  needed), and never blocks on unread SERVEMOUSE replies. All three
  leniencies let a driver ship that the real MCU protocol rejects; the
  corrected driver (handshakes + INITMOUSE + reply reads) runs green
  against the model too, so tightening it is compatible.

## Traps for whoever drives MAME next

- **MAME persists the a2sd's EEPROM in `nvram/` per machine.** Guest
  writes into `$C800` space (i.e. exactly bug #1) corrupt the firmware
  ON DISK, and every later run inherits the corruption -- a poisoned
  heisenbug that survives "turn it off and on again". `check_mame.py`
  deletes `nvram/` before every run.
- **MAME persists input/UI state in `cfg/` per machine too** --
  including the natural-keyboard enable flag, which changes the Caps
  Lock TOGGLE's effective boot state and turned phase 4 into a
  deterministic pass/fail alternator (see RESOLVED above). Any state
  a run can write and a later run can read is a heisenbug vector:
  `check_mame.py` deletes `cfg/` alongside `nvram/` before every run.
- MAME's Lua: keep the subscription handle from
  `emu.add_machine_frame_notifier` in a GLOBAL -- a local is garbage
  collected and the notifier silently stops firing.
- The debugger (`-debug -debugscript`) works headless with
  `-video none`; `trace <file>` + a conditional `bpset ...,1,{...}`
  is how bug #1's `jsr $2020` was caught. `manager.machine.natkeyboard
  :post()` types through the real keyboard ROM.
- The shell prompt is `$ ` (check_play.py's constant), and the Apple
  keyboard uppercases the echo -- assert case-folded.

## Teeth

Every assertion in `check-mame` was watched failing live against the
pre-fix kernel during this spike: phase 1 against the unbootable
pre-romset setup, phase 2 against (in order) the `$C800` corruption
crash, the VTEMU superimposed display, the tickless starved shell, and
the RESTART-$01 box. The gate is the distillation of those five
failures, not a test written after the fact.
