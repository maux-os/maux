# maux scheduler, context switch, and timer driver (task #6)

Status: implemented and gated (`make check-sched`, fast backend), byte- and
cycle-verified against verilogapple. This document is the acceptance
artifact for task #6 alongside `src/kernel/sched.s`, `src/kernel/timer.s`,
the context-switch insertion into `src/kernel/entry.s`, and the PCB-layout
ratification in `inc/memmap.equ`/`docs/MEMMAP.md`.

Library handles fetched for this task (HACKING.md's notebook loop), beyond the
task-cited set: `learning:01KZZ5492YPQSFYTYNANRJZVWH` (verilogapple models
NO paddle one-shots -- the paddle-strobe documentation duty, sec 5 below cites
it), `learning:01KZZF3HE8F6R29MT126X4YCKF` (the ServeMouse/direct-PIA
finding -- the mouse driver here is a straight promotion of that resolved
design, not a rediscovery). Own search sweep (HACKING.md's notebook rules): "mouse card
ROM signature slot detection" and "peripheral card ROM identification byte"
found no dedicated learning or TRM listing pinning down AppleMouse-class
ID bytes -- sec 3.2 below records this as a real gap, not a silently-assumed
fact (a deposit candidate, sec 8).

---

## 1. The operator ruling (recap, verbatim from docs/TASKS.md #6)

> O(1) two-queue scheduler, both queues plain arrays. (1) RUN QUEUE:
> circular array of pids (49 bytes + head/tail bytes), pop-head-to-run /
> push-tail, round-robin. (2) "Everyone else" is a SET, not an ordered
> queue: physically just each PCB's state byte + wait-channel byte --
> legitimate because in v1 ONLY the running process can block itself
> (wait/pipe/tty-read; no signals yank others), so mid-queue removal never
> happens. wakeup(chan) = linear scan over the PCB array moving matching
> pids to the run-queue tail -- O(48) ~ ~500 cycles worst case, acceptable
> at 60Hz; document the cycle cost honestly in SCHED.md.

Implemented exactly as specified in `src/kernel/sched.s`:

- **RUN QUEUE** (`RUNQ`/`RUNQ_HEAD`/`RUNQ_TAIL`): a 49-byte circular
  buffer (`RUNQ_CAP = PCB_COUNT+1`, the classic "N+1 slots disambiguates
  empty from full via head==tail alone" trick). `RUNQ_PUSH`/`RUNQ_POP`
  are the only operations; both are pure kernel-main-memory routines,
  O(1), a handful of instructions each.
- **"Everyone else" SET**: no second data structure at all -- it IS the
  `PCB_STATE`/`PCB_WCHAN` byte pair inside the (already-existing, task
  #2-reserved) annex PCB array. `SCHED_SLEEP` writes `PCB_BLOCKED` +
  a channel; `SCHED_WAKEUP` is the linear scan the ruling names, moving
  every match to the run queue's tail. The legitimacy argument is
  reproduced verbatim because it is load-bearing for correctness, not
  just performance: **v1 has no mechanism by which a process can force
  ANY other process to stop running or leave the run queue** (no
  signals-to-others, no priority preemption, no external `kill` mid-run
  in this task's scope) -- the only two ways a PCB's `PCB_STATE` ever
  changes are (a) the CURRENTLY RUNNING process putting itself to sleep
  (`SCHED_SLEEP`, always self-targeted -- `K_CURPID` is the only pid this
  routine ever touches) and (b) the scheduler's own switch/wakeup
  bookkeeping. Consequence: nothing is ever removed from the middle of
  the run queue -- `RUNQ_POP` always takes the head, `RUNQ_PUSH` always
  appends the tail, and a strict FIFO array with two indices is
  sufficient; no linked list, no free-list of queue nodes, no O(n)
  removal path is ever needed. This is why the "everyone else" set does
  not need to be a queue at all -- nothing ever asks "who is 3rd in line
  among the blocked" the way it might ask that of the run queue.

---

## 2. PCB layout -- ratified (task #6, per docs/TASKS.md #6's instruction to
## ratify now and amend MEMMAP.md/memmap.equ in the same commit if needed)

Task #2's `PCB_ENTRY` was an explicit **size reservation**, not a real
field list (its own text: "Task #6 (scheduler) owns the real field list --
treat this as a size reservation, not a struct definition"). The
operator's two-queue design requires a `PCB_STATE` byte **and a separate
`PCB_WCHAN` byte** -- the "everyone else is a SET, not a queue" design's
entire physical representation -- which task #2's placeholder didn't
budget for (it had `PCB_STATE` only).

**Ratified layout (16 bytes -- unchanged from task #2's reservation; no
`PCB_ENTRY_SIZE` renegotiation needed, see the "why 16 stays 16" note
below):**

| offset | field | size | meaning |
|---|---|---:|---|
| 0 | `PCB_PID` | 1 | this slot's pid |
| 1 | `PCB_STATE` | 1 | `PCB_UNUSED`(0) / `PCB_RUNNABLE`(1) / `PCB_RUNNING`(2) / `PCB_BLOCKED`(3) / `PCB_ZOMBIE`(4) |
| 2 | `PCB_WCHAN` | 1 | wait channel; meaningful only when `PCB_STATE=PCB_BLOCKED`; 0 = not waiting |
| 3 | `PCB_BANK` | 1 | physical aux bank number (the annex's authoritative pid->bank map) |
| 4 | `PCB_PARENT` | 1 | parent pid (task #3 scope; unused by the scheduler itself) |
| 5 | `PCB_SAVEDSP` | 1 | saved kernel-visible SP at the last context switch -- the annex half of the PCB split |
| 6 | `PCB_EXITSTATUS` | 1 | task #3 scope |
| 7 | `PCB_CWDINO` | 1 | **re-scoped this task**: index (0..`INODE_COUNT`-1) into the inode cache, not a 2-byte pointer (see below) |
| 8-15 | `PCB_FDTABLE` | 8 | fd->refnum table, task #3 scope |

**Why 16 stays 16 (the actual ratification decision):** the only way to
fit `PCB_WCHAN` was to free a byte elsewhere. `PCB_CWD_INODE` was task
#2's one 2-byte field with headroom to give up: `INODE_COUNT` is 32
(`docs/MEMMAP.md` sec 2.2), which fits in a single byte, so a cwd **index**
into the inode cache (re-derived to a real inode-cache pointer by
whichever task actually implements lookup -- task #11's fs spike) does the
same job as a 2-byte raw pointer for one byte less. That freed byte is
exactly what `PCB_WCHAN` needed. `inc/memmap.equ`'s `PCB_ENTRY` `dum`
block and `docs/MEMMAP.md` sec 2.2's table are amended in this same commit
to match (`PCB_CWD_INODE` -> `PCB_CWDINO`, `PCB_WCHAN` inserted, offsets
renumbered) -- see that file's own "TASK #6 RATIFICATION" comment block.

**Why staying a power of two matters mechanically, not just tidily:** the
6502 has no hardware multiply. `sched.s`'s `PCB_PTR_FOR` computes
`PCB_ARRAY_ADDR + pid*PCB_ENTRY_SIZE` via four `ASL`/`ROL` pairs (`pid<<4`
-- exactly correct for size 16, and *only* for size 16 or another power of
two without a real shift-and-add multiply loop). This routine runs on
**every** PCB access -- `SCHED_INIT` (48x), every `SCHED_SWITCH`/
`SCHED_START` call, and every one of `SCHED_WAKEUP`'s 48 scan iterations --
so keeping the entry size a power of two isn't an aesthetic preference,
it is what keeps the pointer arithmetic O(1)-cheap (~20 cycles) instead of
a real multiply (would cost meaningfully more, repeated 48 times per
wakeup scan -- see sec 6's measured wakeup-scan cost, which is already the
single most expensive operation this module performs).

**The per-bank half of the PCB split** (per `docs/ARCHITECTURE.md`/
`docs/MEMMAP.md` #3.3) is unchanged by this task: `BANK_ID` (the per-bank
self-identity byte, `$FF2E`) + `FFXX_SCRATCH` (5 reserved bytes) inside
every bank's own `$FFxx` page. Task #6 does not add a second per-bank
structure -- `PCB_SAVEDSP` lives only in the annex, matching the
operator's own phrasing ("the per-bank half is `BANK_ID` + `SCRATCH`").

---

## 3. Timer driver -- the probed source (`src/kernel/timer.s`)

### 3.1 Probe chain and failure policy (review finding A8, docs/TASKS.md #6 amendment)

`TIMER_PROBE` tries, in order, and **reports the outcome loudly** (a fixed
text-page line, `TIMER:` + a 10-char mode name -- never silent):

1. **AppleMouse + VBL** (`TIMER_PROBE_MOUSE`) -- a register round-trip at
   the mouse card's PIA (`$C0D0`/`$C0D2`, slot 5, matching
   `learning:01KZXDQCQF2FZMDQ59FVZ5D7T4`'s documented default machine):
   write `$FF`/`$30` to DDRA/DDRB, read back, require an exact match on
   both. On success this doubles as the first half of init (the same
   register writes `TIMER_INIT_MOUSE` needs next -- no wasted work), then
   `TIMER_INIT_MOUSE` selects PRA/PRB (`CRA`/`CRB`=`$04`) and sends
   `M_SET` mode `$09` (on + VBL interrupt enable) via `MOUSE_SEND_CMD`
   (promoted **verbatim**, mechanism unchanged, from
   `src/test/syscalltest.s`'s working code -- the task's own starting
   point), and wires `K_IRQ_HOOK` at `TIMER_ISR`.
2. **Mockingboard** (`TIMER_PROBE_MB`) -- same register-readback technique
   at the 6522 VIA's DDRB (`$C0C2`, slot 4). v1 implements **presence
   detection only** -- no real 6522 timer-interrupt programming (out of
   scope: `docs/ARCHITECTURE.md`'s V1-scope fence explicitly lists
   "Mockingboard timers" under v2+). On success, `K_TIMER_MODE=2` and a
   defensive no-op IRQ hook is armed (`TIMER_ARM_NOP_HOOK`) -- a real
   Mockingboard driver is a later task's work, not this one's.
3. **Cooperative-only** -- neither tier found. `K_TIMER_MODE=3`, the same
   defensive no-op hook armed (no hardware source is EVER enabled in this
   mode -- see sec 3.3), the loud report printed.

**Missing-ROM loud failure** (the amendment's specific wording): if
`sim/roms/applemouse.rom` is absent, verilogapple's mouse-card model never
comes up at all (`learning:01KZXDQCQF2FZMDQ59FVZ5D7T4`: "else mouse+VBL
silently disabled with a stderr note" -- silent on the EMULATOR side). The
maux-side probe cannot see that stderr note; what it CAN see is that the
register round-trip simply fails (no card responds), which is exactly
what step 1 above tests for. Falling through to step 2 then step 3 and
printing the outcome is what makes the failure loud from the **kernel's**
point of view -- the boot never silently waits for ticks that will never
arrive.

### 3.2 What the mouse-presence probe is (and is NOT) a claim about

`TIMER_PROBE_MOUSE` is a **behavioral liveness test** -- verified, in this
task, to correctly distinguish "AppleMouse present" (fast backend, mouse
enabled) from "absent" (this task's cooperative-mode variant, forced past
the probe entirely -- see sec 3.3, so the negative case wasn't independently
exercised by the automated gate, only reasoned about). It is **not** a
claim about real Apple II open-bus behavior for unpopulated I/O
addresses, and it is deliberately **not** a slot-ROM signature scan
(`$Cn05`/`$Cn07` ID bytes) -- a scheme this task's own search sweep
(HACKING.md's notebook rules: "mouse card ROM signature slot detection", "peripheral
card ROM identification byte") could not confirm against the
street-library commons or the fetched TRM material. Per HACKING.md's
confidence discipline ("`[likely]` and `[reported]` claims a design
depends on must be verified first"), an unverified ID-byte convention is
not something this task will make load-bearing. The chosen probe range is
therefore narrowed to the two slots verilogapple's own machine actually
populates (5 for mouse, 4 for Mockingboard) rather than a full 1-7 sweep
-- a real v1 limitation, flagged here rather than silently generalized
(see sec 8's deposit candidates).

### 3.3 `K_TIMER_FORCE` -- the cooperative-mode test hook (and a real feature)

`TIMER_PROBE`'s very first check is `K_TIMER_FORCE`: if nonzero, it skips
all hardware detection and adopts that value as `K_TIMER_MODE` directly.
`check-sched`'s cooperative variant sets this to `TIMER_MODE_COOP` (3)
before calling `TIMER_PROBE`; every other build leaves it zero (real
probing runs). This is not just a test hook -- it is a legitimate
boot-time override a real kernel config flag could set -- but its only
CURRENT caller is the test harness. Critically, forcing cooperative mode
means **no hardware IRQ source is EVER armed** (`TIMER_ARM_NOP_HOOK`) --
not "mode 3 ignores ticks it still receives." `check-sched` asserts
`K_VBL_TICKS` stays exactly 0 for the whole cooperative run specifically
to prove this (sec 6).

### 3.4 The IRQ-source clear + stale-VBL non-re-entry requirement

`TIMER_ISR` acknowledges the VBL interrupt by sending `M_SERV` (`$20`)
directly via the PIA (`MOUSE_SEND_CMD`) -- the direct-PIA policy
(`learning:01KZZF3HE8F6R29MT126X4YCKF`) that resolved `docs/SYSCALL.md`
sec 7.5's finding (calling ROM `ServeMouse` from IRQ context re-enables
interrupts internally, corrupting a fixed-SP-reset kernel stack). Per
`mouse_card.h`'s own model, `M_SERV` clears the model's `irq` flag
**synchronously** the moment the command byte latches -- this IS the
"per-tick IRQ-source clear" the amendment asks for, and it happens BEFORE
`TIMER_ISR` does anything else (tick count, then `SCHED_TICK`). Because
this kernel never calls firmware that could internally re-enable
interrupts, `I` stays 1 for the entire IRQ service (the hardware
guarantee `docs/SYSCALL.md` sec 7.2 already established, unmodified by this
task) -- a second IRQ **cannot** be recognized mid-service, so
`K_VBL_TICKS` cannot run away from the nominal rate the way the pre-fix
sec 7.5 regression did (~30-40x nominal). `check-sched` asserts this
directly (sec 6): the observed rate stays within a generous, but bounded,
multiple of nominal -- see that section for the exact numbers.

### 3.5 Paddle-strobe consequence (documentation duty, docs/TASKS.md #6)

**Every `$C073` write retriggers the real game-paddle 558 one-shots on
ACTUAL hardware** (AE manual fact, `learning:01KYYJ98T5R0M9K1AW2550M132`:
wait >=3ms before trusting a paddle read after a bank switch). A
preemptive round-robin scheduler writes `$C073` on **every context
switch** -- at `QUANTUM_TICKS=4` ticks/timeslice and a VBL rate in the
tens-of-Hz-to-~120Hz range observed in this rig (sec 6), that is a `$C073`
write every few tens of milliseconds, indefinitely, for the life of the
system. On real hardware this would leave the paddles **permanently
mid-discharge** for any process trying to read a joystick -- a genuine,
architectural correctness hazard for any future paddle/joystick driver,
not a bug in this scheduler.

**This is completely UNMODELED by either verilogapple backend** --
confirmed by a dedicated street-library finding fetched for this task
(`learning:01KZZ5492YPQSFYTYNANRJZVWH`, checked 2026-08-14 at the cited
source lines): the fast backend's paddle one-shot arms ONLY on the
literal address `$C070` (`sim/fast/fast_apple2e.h:326`), never `$C073`;
the rtl backend's IOU generates the correct whole-`$C07x`-window strobe
but nothing downstream consumes it (`rtl/iou.sv:521-522`: "Paddle
one-shots... are not modelled yet"). **Consequence for this task
specifically:** nothing in `check-sched` -- or any test this kernel can
run against this rig -- can observe this hazard, because the rig has no
model of it to observe. This is not a gap in this task's testing; it is a
gap in the emulator, already tracked (adjacent to the open verilogapple#13
work `docs/TASKS.md` #9 references) and now cited by name rather than
silently assumed. v1 ships no joystick/paddle driver, so nothing in the
CURRENT kernel is affected today -- but the next task that adds one
inherits this finding as a **known, pre-documented hazard**, not a
rediscovery, and needs MAME, AppleWin, or real iron to even observe it,
let alone design around it.

---

## 4. Context switch -- the mechanics

### 4.1 The insertion points (task #3's own prediction, fulfilled verbatim)

`docs/SYSCALL.md` sec 6 already specified exactly where this task's work
would land: *"A context-switching exit (task #6's scheduler) inserts
exactly one `LDA K_TARGETBANK / STA BANKSEL` at the marked point in both
`KERNEL_EXIT` and `KERNEL_IRQ_SERVICE`; nothing else in this file
changes."* The landed diff (`src/kernel/entry.s`) is a superset of that --
because a context switch changes not just the bank but the *stack
pointer*, it needed one more thing (`LDX K_TARGETSP` / `TXS` instead of
resuming the same SP), but the SHAPE is exactly as predicted: one small,
one-shot-flag-gated branch inserted at the marked point, zero changes to
either function's pre-existing (same-bank) path.

**`K_SWITCH`/`K_TARGETBANK`/`K_TARGETSP`** are declared in `entry.s`
itself (not `sched.s`) precisely so `entry.s` keeps working, byte-for-
byte, for any includer that never touches the scheduler --
`src/test/syscalltest.s` (task #3's own gate) still passes unmodified
(sec 7) because `K_SWITCH` is zeroed once at boot (`INSTALL_COPY`) and
`sched.s` is the ONLY module that ever sets it nonzero.

### 4.2 `KERNEL_EXIT`'s switch branch (syscall-triggered switches -- `SCHED_YIELD`, `SCHED_SLEEP`)

```
KERNEL_EXIT
    LDX K_CALLER_SP
    LDA K_RESULT  : LDY K_RESULT_ERR      ; cache BEFORE the ALTZP flip
    STA ALTZPAUX                          ; --- critical section begins ---
    STA FRAME_A,X                         ; patch the OUTGOING/caller's
    LDA FRAME_P,X : AND #$FE              ;   OWN frame -- always correct
    CPY #0 : BEQ :setcarry : ORA #$01     ;   regardless of who resumes
:setcarry
    STA FRAME_P,X
    LDA K_SWITCH                          ; ordinary main memory -- safe
    BEQ :noswitch                         ;   to read here (see sec 4.4)
    STZ K_SWITCH
    LDA K_TARGETBANK : STA BANKSEL        ; $C073 = INCOMING pid's bank
    LDX K_TARGETSP
    TXS                                   ; --- critical section ends ---
    JMP $FF22                             ; EXIT_TAIL: resumes INCOMING
:noswitch
    TXS                                   ; --- critical section ends ---
    JMP $FF22                             ; EXIT_TAIL: resumes SAME bank
```

### 4.3 `KERNEL_IRQ_SERVICE`'s switch branch (tick-triggered switches -- `SCHED_TICK`)

Identical mechanism, one door earlier (before `ALTZPAUX` is even flipped,
since the IRQ door's critical section starts later than the syscall
door's):

```
KERNEL_IRQ_SERVICE
    JSR K_IRQ_CALL_HOOK           ; -> TIMER_ISR: ack + tick + maybe switch
    LDA K_SWITCH
    BEQ :sameproc
    STZ K_SWITCH
    LDA K_TARGETBANK : STA BANKSEL
    STA ALTZPAUX                  ; --- critical section begins here ---
    LDX K_TARGETSP
    TXS                           ; --- critical section ends ---
    JMP $FF22                     ; EXIT_TAIL: resumes INCOMING
:sameproc
    LDX K_CALLER_SP
    STA ALTZPAUX
    TXS
    JMP $FF22                     ; EXIT_TAIL: resumes the interrupted
                                   ; process, exactly as task #3 left it
```

### 4.4 Extended per-window interrupt-safety argument

`docs/SYSCALL.md` sec 7's own governing fact is unchanged and still covers
everything downstream of either door's `SEI`/hardware-forced `I=1`: **no
IRQ can land anywhere in either switch branch above** -- both branches
execute entirely inside the same `I=1` window sec 7.2/sec 7.4 already proved
unbroken (this task adds no new `CLI`, and per sec 3.4 the timer driver
itself never re-enables interrupts). What sec 7 did NOT anticipate, and what
this task's own instruction is to extend to the same standard, is a
**new kind of window**: one where `SP`, the annex `PCB` array, and
`curbank` (`$C073`'s write-only shadow) each name a **different**
process at different instruction boundaries within the same critical
section. Table, per instruction boundary (both branches share this
shape; `KERNEL_IRQ_SERVICE`'s is shown, `KERNEL_EXIT`'s differs only in
where the `ALTZPAUX` flip sits relative to the `BANKSEL` write):

| after instruction | curbank (`$C073`) | real SP register | page 1 resolves to | ZP resolves to | who does `SP`/PCB data belong to |
|---|---|---|---|---|---|
| `LDA K_TARGETBANK` | OUTGOING (unchanged) | kernel's own (`$FF`, set by the entry door) | kernel's own main page 1 | main | N/A -- pure register load, no memory named yet |
| `STA BANKSEL` | **INCOMING** | kernel's own (`$FF`) | **INCOMING's** aux page 1 (ALTZP still main here -- see next row) | main (ALTZP unchanged) | still nobody's data touched -- I/O write only |
| `STA ALTZPAUX` | INCOMING | kernel's own (`$FF`) | INCOMING's aux page 1 | **INCOMING's aux ZP** | still nobody's data touched -- I/O write only; **this is the window this table exists for**: `$C073` and `ALTZP` now BOTH name INCOMING, but the real SP register still holds the KERNEL's fixed value, not INCOMING's saved one |
| `LDX K_TARGETSP` | INCOMING | kernel's own (`$FF`) | INCOMING's aux page 1 | INCOMING's aux ZP | `K_TARGETSP` is ordinary main memory (sec 4.1) -- reading it here is safe regardless of the ALTZP flip already having happened (only ALTZP moved; RAMRD/RAMWRT are still main) |
| `TXS` | INCOMING | **INCOMING's saved SP** | INCOMING's aux page 1 | INCOMING's aux ZP | **first instruction where EVERY name (curbank, real SP, page 1, ZP) agrees on INCOMING** -- the critical section ends exactly here |
| `JMP $FF22` | INCOMING | INCOMING's saved SP | INCOMING's aux page 1 | INCOMING's aux ZP | consistent -- `EXIT_TAIL` runs entirely in INCOMING's own context from this point on |

**Why the "no pushes" discipline (sec 7.3/sec 7.4's original argument) still
closes this window, unchanged:** between `STA BANKSEL`/`STA ALTZPAUX` and
`TXS`, the real SP register still holds the KERNEL's fixed value ($FF),
but `$0100-$01FF` now resolves into **INCOMING's** aux bank (both
`$C073` and `ALTZP` already point there) -- a stray push in this window
would land in INCOMING's OWN stack at the KERNEL's offset ($FF),
clobbering whatever INCOMING had there, silently corrupting a process
that isn't even the one currently executing. This is the SAME hazard
class sec 7.4 already named for the same-bank case (a push landing "in the
process's stack at the kernel's own offset") -- extended here to name
which process is at risk when the target has CHANGED: it is the
**INCOMING**, not the outgoing, process's stack that a stray push would
corrupt, because `$C073`/`ALTZP` already point at INCOMING by the time
the hazard window opens. The code performs exactly `LDA`/`STA`/`LDX` in
this window (no `PHA`/`JSR`/`PLA`), so -- as with every other window in
this kernel -- the hazard is closed by construction, and this table
records the construction argument rather than merely asserting it.

**One more instance of the same hazard, found and fixed by this task's
own testing (not a hypothetical):** `sched.s`'s `SCHED_START` (the
one-time boot launch, structurally `SCHED_SWITCH`'s "incoming half with
no outgoing half" -- see its own header) originally read `K_SW_INSP` (a
**zero-page** cell) via `LDX K_SW_INSP` **after** `STA ALTZPAUX` -- the
zero-page analogue of exactly the ordering mistake this table exists to
prevent for main-memory cells. Because `K_SW_INSP` is ZP, not ordinary
main memory, reading it after the ALTZP flip silently redirected the
read into the INCOMING bank's own zero page instead of main's -- `X` came
back garbage, `TXS` loaded a garbage SP, and `EXIT_TAIL`'s `RTI` pulled a
garbage frame, producing a wild jump (confirmed by direct emulator
inspection -- `regs`/`peek`/`until_write` showed execution corrupted
within a handful of instructions of the flip, eventually hitting a stray
`$00` byte and parking in `KERNEL_BRK_TRAP`; the fix moved `LDX
K_SW_INSP` to before `STA ALTZPAUX`, exactly matching this table's row
ordering). sec 7 below has the complete bug-hunt account.

---

## 5. `SCHED_SWITCH`, `SCHED_START`, `SCHED_WAKEUP` -- the annex-access design

Every routine that needs to **read** annex (aux bank 0) PCB data does so
through `PCB_READ_FIELDS`, a thin wrapper around `entry.s`'s existing
`COPYIN_ENTRY` (LC-resident, fetch-immune to RAMRD). Routines that only
**write** annex data use a plain inline `RAMWRTAUX`/`RAMWRTMAIN` bracket
directly. This asymmetry is deliberate and load-bearing, not
inconsistent -- see sec 7 for the bug this design choice fixes and why the
write side never needed it.

`SCHED_TICK` first calls an optional `K_TICK_HOOK`, initialized to a no-op by
`SCHED_INIT`. The process layer installs the tty poller there when a tty-backed
image is built. The hook is deliberately scheduler-owned rather than
timer-owned so scheduler-only tests can keep using `timer.s` without also
including `process.s`.

`SCHED_SWITCH` (the shared machinery behind `SCHED_TICK`, `SCHED_YIELD`,
and `SCHED_SLEEP`): caches the outgoing pid/SP and does ALL run-queue
work (`RUNQ_POP`/`RUNQ_PUSH`) **before** opening any annex bracket -- RUNQ
is ordinary kernel main memory, and touching it from inside an
aux-targeted bracket would silently redirect those writes into the annex
bank instead (the `docs/SYSCALL.md` sec 5.1 discipline, applied here to a
NEW instance the same way copyin/copyout's own design already does).
Special-cases an empty run queue two ways: if the outgoing process is
still runnable, cancel the switch (steady state -- nothing else to run);
if not (it just blocked) and the queue is ALSO empty, park defensively
(`docs/SCHED.md`'s own stated v1 limitation -- no kernel-wide idle process;
see sec 9).

`SCHED_WAKEUP`'s scan used to defer every `RUNQ_PUSH` for a matched pid
until **after** the scan loop closed, buffering matched pids in a small
main-memory array (`K_WAKE_BUF`) written only while `RAMWRT` was briefly
back to main inside the loop -- the "don't touch main memory from inside
an aux bracket" discipline, applied to the loop's own bookkeeping.
**WAKE-1 (2026-10-21) replaced that scan.** `SCH_WAKEUP` now scans a
48-byte main-memory wait shadow (`K_WAIT_SHD`, in `K_WAKE_BUF`'s old
KBSS cell: nonzero iff the pid's PCB is BLOCKED, then equal to its
WCHAN), so the loop needs no bracket and no buffer; a match opens a
write-only bracket for its own two PCB bytes, closes it, clears the
shadow cell and pushes. Measured: 11,032 -> 654 cycles a call on
`cat /bin/sed | wc -c` (docs/WAKE-1-NOTES.md). The 10,882-cycle figure
below is the pre-WAKE-1 measurement.

**WAIT-1 (2026-10-21) applied the same lever to the parent field.**
`PRC_WAIT_CORE` scans a 49-byte main-memory parent shadow
(`K_PAR_SHD`, reversed, pid p in cell 48-p) and reads the annex only
for a pid whose cell equals the caller's pid; 12,744 -> 924 cycles a
call, and a shell with one background job pays 106% of a quiet shell
per command line instead of 163% (docs/WAIT-1-NOTES.md,
docs/a2/K.SCHED.TXT).

**ORPHAN-1 (2026-10-22) uses the same shadow to reparent.** Orphans go
to init (pid 1) at their parent's death (`PRC_ADOPT`, process2.s; V7
sys1.c exit(), 4.2BSD kern_exit.c): the shadow cell and the annex
`PCB_PARENT` of every child of a ZOMBIE become 1, and init is woken if
one of them is already a zombie (it blocks in wait on channel 1). One
scan of the 47 shadow cells (~11 cycles a cell) plus ~650 cycles an
adoptee; a quiet exit costs 905. It replaces `PRC_REAP_ORPH`, a
47-slot annex scan that cost ~12.9k cycles and ran twice per
foreground command (at the child's exit and at the shell's reap): net
about -24.9k cycles per external command (docs/ORPHAN-1-NOTES.md).

---

## 6. Cycle budgets -- measured in the emulator, not estimated

Every number below was measured against verilogapple's fast backend via
`until_pc`/`regs` cycle deltas (bracketing real entry/exit addresses of
the routine in question), in a fresh reset+mount session, using the
actual assembled `check-sched` images (or, for `SCHED_WAKEUP`, a small
dedicated scratch harness exercising the identical code with `INSTALL_COPY`
run first -- `SCHED_WAKEUP` is not exercised by `check-sched` itself, since
v1 has no real `wait`/`pipe` caller yet to trigger `SCHED_SLEEP`).

| operation | measured cost | method |
|---|---:|---|
| IRQ tick service, **no switch** (mouse ack + `SCHED_TICK`'s `DEC`, quantum not yet exhausted) | **157 cycles** | `until_pc($FF14)` -> `until_pc($FF22)`, repeated across many ticks, always exactly 157 when `K_SWITCH_COUNT` doesn't advance |
| IRQ tick service, **with switch** (mouse ack + `SCHED_TICK` + full `SCHED_SWITCH`, incl. one `PCB_READ_FIELDS`/`COPYIN_ENTRY` call) | **769 cycles** | same bracketing, on the 1-in-`QUANTUM_TICKS` tick that exhausts the quantum (`K_SWITCH_COUNT` advances) |
| `SCHED_WAKEUP`, full 48-entry scan, **zero matches** (worst case for the scan itself -- no early exits, no write-back bracket ever opens) | **10,882 cycles** | `until_pc(BENCH_START)` -> `until_pc(BENCH_END)` around a bare `SCHED_WAKEUP` call, scratch harness, `INSTALL_COPY` run first |
| `SCHED_INIT` (boot-time, 48-entry PCB-array zero) | one-time, sub-boot-budget; not separately isolated (folded into the ~180-200K-cycle boot-to-probe-complete window already measured for task #3's own gate, `docs/SYSCALL.md` sec 8) | -- |

**The switch-cost delta (769 - 157 = 612 cycles) is entirely
`SCHED_SWITCH`'s own work** -- RUNQ pop/push, two `PCB_PTR_FOR` calls, one
`PCB_READ_FIELDS`/`COPYIN_ENTRY` round trip, and the two PCB field
writes. At `QUANTUM_TICKS=4` and the observed VBL rate (sec 6.1), a switch
happens roughly once every 4 ticks -- the AMORTIZED per-tick scheduler
overhead is therefore `(3x157 + 769)/4 ~ 310` cycles/tick, comfortably
inside a 60 Hz (nominal) or even the rig's own faster-than-nominal
observed rate's budget (sec 6.1) at 1 MHz.

**Honest comparison against the operator's own estimate:** the ruling's
own "O(48) ~ ~500 cycles worst case" framing for `SCHED_WAKEUP` undershoots
the measured 10,882 cycles by roughly **22x**. This is not a design
failure -- it is the direct, load-bearing cost of the RAMRD-governs-fetch
fix (sec 7): a naive inline `RAMRDAUX` scan (which IS roughly 500-cycle
territory -- 48 iterations x ~10 cycles/iteration of pointer math + one
`(ptr),y` read + a compare) is **actively unsafe** in this kernel's own
code layout (ordinary flat `$0200-$BFFF` code, not LC-resident), so it
was never a real option once that hazard was found. Routing every annex
read through `COPYIN_ENTRY` (a real `JSR` into LC, a real copy loop, a
real `RTS` back) costs meaningfully more per iteration but is
*correct* -- and `SCHED_WAKEUP` is not on the tick-critical path (sec 6's own
per-tick figures above don't include it at all; it only runs when a
process explicitly wakes another, an event this v1 kernel doesn't even
have a caller for yet). The 22x gap between estimate and measurement is
recorded here specifically so the NEXT task that calls `SCHED_WAKEUP`
from a real hot path (a busy pipe, say) budgets against 10,882 cycles,
not 500.

### 6.1 Observed VBL rate (context for the paddle-strobe/tick-budget numbers above)

`check-sched`'s preempt variant serviced **401 VBL ticks over 3,600,000
CPU cycles** (401/3,600,000 x 1,023,000 ~ **114 Hz** at the //e's nominal
clock) -- well above nominal 60 Hz, consistent with `docs/SYSCALL.md`
item (e)'s own prior observation on this same rig ("not tuned against
the model's nominal 60 Hz period") and comfortably inside this gate's own
10x stale-VBL ceiling (sec 7.5's regression symptom was ~30-40x nominal, not
~2x) -- see `scripts/check_sched.py`'s own assertion and printed ratio.

---

## 7. Bug-hunt account (found and fixed by this task's own testing)

In the spirit of `docs/SYSCALL.md` sec 7.7/sec 8.1's own honest accounting:
getting `check-sched` from "assembles clean" to "genuinely passes" took
**two real, sequentially-discovered correctness bugs**, both instances of
bug classes this codebase had already named but not yet fully generalized
to every future module.

**Bug 1 -- `SYNTH_FRAME` (test harness) used `RAMWRTAUX` to reach page 1.**
`$0100-$01FF` is **not** part of the `$0200-$BFFF` RAMRD/RAMWRT-governed
flat range at all -- like zero page, it is `ALTZP`-governed
(`docs/ARCHITECTURE.md`: "ALTZP gives each bank its own zero page and
hardware stack"). The synthesized trapframe silently landed in MAIN's
own stack instead of the target bank's; the target bank's real page 1
stayed uninitialized, and the first launch attempt pulled a garbage
frame. Fixed: `ALTZPAUX`/`ALTZPMAIN`, the same switch `STAMP_BANK`
already used for the `$FFxx` write and `src/test/syscalltest.s`'s own
`ENTER_FAKEPROC_STUB` uses to reach page 1.

**Bug 2 -- `sched.s`'s `SCHED_START`/`SCHED_SWITCH`/`SCHED_WAKEUP`
originally opened `RAMRDAUX` INLINE, in their own ordinary
`$0200-$BFFF` code, then kept executing more instructions from that SAME
code before flipping back.** This directly violates
`learning:01KW1GTYGVYAPQRGS5P7J66RWD` (RAMRD governs ALL reads in
`$0200-$BFFF`, **including the CPU's own opcode fetches**) -- a rule this
codebase's `entry.s`/`bankprobe.s` already built their whole design
around (copyin/copyout live in LC precisely to be immune to it;
`bankprobe.s`'s `AUXRD` stub is relocated to page 1 for the same reason)
but which this task's FIRST draft of `sched.s` did not re-derive for its
own new code. The very next opcode fetch after `STA RAMRDAUX` was
redirected into the annex bank instead of `sched.s`'s own code -- a wild
jump, confirmed by direct emulator inspection (`regs`/`peek`/
`until_write` showed execution corrupted within a handful of
instructions of the flip, bouncing through ROM/expansion-ROM address
space, eventually executing a stray `$00` byte and parking in
`KERNEL_BRK_TRAP`). **Fixed** by introducing `PCB_READ_FIELDS` (sec 5): every
annex READ goes through `entry.s`'s existing `COPYIN_ENTRY` instead of an
inline flip. Annex WRITE-only brackets (`SCHED_INIT`, `SCHED_CREATE`,
`SCHED_SLEEP`, and the write halves of `SCHED_START`/`SCHED_SWITCH`/
`SCHED_WAKEUP`) never had this bug and needed no change -- `RAMWRT` gates
writes only, never instruction fetch, so an inline `RAMWRTAUX` bracket in
ordinary code is safe by the same argument `docs/SYSCALL.md` sec 5 already
makes for `COPYOUT`'s own asymmetric design.

**Bug 3 -- `SCHED_START` read a ZERO-PAGE cell (`K_SW_INSP`) AFTER the
`ALTZPAUX` flip.** The zero-page analogue of Bug 2, and a fourth instance
overall of the `docs/SYSCALL.md` sec 5.1/sec 7.7 "cross-flip cell ordering"
mistake this kernel has now made four separate times across two tasks.
sec 4.4 has the full account and the fix (read `K_SW_INSP` into `X` BEFORE
the `ALTZPAUX` flip, matching the table's own row ordering).

**Verification method for all three:** `regs` (CPU register snapshot),
`peek` (arbitrary main/aux-bank memory, including `aux_bank=N` for a
specific RamWorks bank -- the tool that made "is the synthesized frame
actually IN bank 1's page 1, or did it land in main's" a one-call
question instead of a guess), `until_pc`/`until_write` (deterministic
breakpoints on PC or a write address), and `regs`'s own `cycle` field
(the basis for every number in sec 6). All three bugs were found by
comparing ACTUAL emulator state against hand-derived expected state at a
specific instruction boundary -- not by code review alone (each survived
at least one read-through before the emulator caught it), which is
itself worth recording alongside `docs/SYSCALL.md` sec 8.1's own account of
the same pattern.

**A cross-check worth naming:** three of this task's four cross-flip-cell
mistakes (Bugs 1, 2's ZP half via Bug 3, and -- folded into Bug 2's fix
-- the discipline `PCB_READ_FIELDS` now enforces for every future annex
read) are all instances of ONE underlying rule this codebase has stated
in prose since task #3 (`docs/SYSCALL.md` sec 5.1's own "KERNEL-DATA-READ
DISCIPLINE") but has now demonstrated, empirically, is easy to
independently re-violate in NEW code even when the rule is already
written down elsewhere in the same repository. This strengthens (not
just repeats) the case for the existing deposit candidate in
`docs/SYSCALL.md` sec 9 rather than adding a new one -- see sec 8.

---

## 8. `make check-sched` -- what it proves and how

Two boot images sharing `src/test/sched.common.s`'s boot/stamp/process
machinery (`src/test/sched.preempt.s`, `src/test/sched.coop.s`),
driven by `scripts/check_sched.py`:

**(a) Preemptive variant** -- two fake processes (banks 1/2), each an
infinite `INC $0900 / BNE :skip / INC $0901 / BRA :top` loop over its OWN
bank's counter. **Neither ever yields or issues a syscall** -- alternation
happens purely via VBL-driven quantum exhaustion. Asserts:
- `K_TIMER_MODE == 1` (the REAL boot probe found AppleMouse+VBL -- this
  variant does not force anything)
- both counters advanced substantially (>200) and within 2x of each
  other (fairness -- measured 1.15x in the delivered run)
- `K_SWITCH_COUNT` advanced substantially (measured: 100 switches over
  3.6M cycles)
- `K_VBL_TICKS` is nonzero and within a 10x-of-nominal ceiling -- the
  stale-VBL non-re-entry regression check (sec 3.4/sec 6.1; measured: 401
  ticks, ~1.9x nominal, nowhere near the sec 7.5 regression's ~30-40x
  signature)

**(b) Cooperative variant** -- `K_TIMER_FORCE` forces `TIMER_MODE_COOP`
before the probe runs; the same two counters instead alternate ONLY via
each process calling `SCHEDTEST_YIELD_CALL` (`$FF00`) every 50
increments. Asserts:
- `K_TIMER_MODE == 3` (forced) and **`K_VBL_TICKS == 0` for the entire
  run** -- proving "cooperative" means no hardware IRQ source is ever
  armed, not merely "ignores ticks it still receives"
- both counters advanced substantially and closely (measured: 41,600 /
  41,600 -- exact parity, since both processes yield at the identical
  burst size)
- `K_SWITCH_COUNT` advanced substantially (measured: 1,663 switches over
  3.6M cycles -- voluntary yields are far more frequent than the
  preemptive variant's quantum-driven switches, as expected: `COOP_BURST`
  (50) is much smaller than the ~157-cycle-per-tick x 4-ticks-per-quantum
  preemptive cadence)

**Symbol addresses are never hardcoded** -- `scripts/check_sched.py`
recovers every `ds`-placed kernel-global address it peeks
(`K_TIMER_MODE`, `K_VBL_TICKS`, `K_CURPID`, `K_QUANTUM`,
`K_SWITCH_COUNT`) from merlin32's OWN `-v1` symbol-table dump
(`build/<name>.bin_Output.txt`, produced as a side effect of the
Makefile's `-v1` build rule for these two images) -- these addresses are
NOT fixed and shift whenever kernel source size changes, exactly the
lesson `docs/SYSCALL.md` never had to learn (task #3's addresses were
fixed at `$FF00` by design) but this task's own iteration process did
(every debugging round in sec 7 needed a fresh symbol dump).

**Backend:** FAST only, per HACKING.md's "fast proves behavior, never
hardware fidelity" -- the paddle-strobe consequence (sec 3.5) is explicitly
flagged as unobservable on either verilogapple backend, needing MAME,
AppleWin, or iron.

---

## 9. Known v1 limitations (recorded, not silently dropped)

- **No kernel-wide idle process.** `SCHED_SWITCH`'s deadlock case (run queue
  empty AND the outgoing process just blocked) still parks defensively
  (`JMP *`-equivalent) rather than corrupting state by "resuming" pid 0.
  Tty-attached boot images create a normal idle process instead
  (playtestb.s `IDLE_PROC`, a `bra *`). **Since 2026-09-14 that pid is
  LOWEST PRIORITY, not a peer:** the boot image stamps it into
  `K_IDLE_PID` and `SCH_SWITCH` dispatches it only when nothing else is
  queued -- popped with entries behind it, it goes back to the tail;
  alone in the queue while the outgoing is still runnable, it stays
  queued and the switch is cancelled. Before that rule it took every
  other 4-tick quantum whenever one real process was runnable (measured:
  733 of 1,466 bank samples during an assembly), so every foreground
  command ran at half speed and every cycle figure in docs/AS-PROFILE.md
  was 2x the work. Gate: `make check-idle` (bank-attributed sampling;
  fails at 50 % with the stamp removed).
- **`SCHED_SLEEP`/`SCHED_WAKEUP` are now exercised by real process paths, but
  not exhaustively.** `wait()`, `pipe()`, and tty-read use the same blocking
  machinery; remaining gaps are stress cases around multiple tty readers,
  typeahead beyond one cooked line, and future signal/foreground semantics.
  `SCHED_WAKEUP`'s 10,882-cycle figure is still the scratch-harness
  measurement from before the tty tick hook; remeasure the IRQ no-switch and
  switch rows before treating sec 6 as current cycle accounting.
- **Mockingboard is presence-detection only** -- no real 6522
  timer-interrupt programming (`docs/ARCHITECTURE.md`'s V1-scope fence:
  "Mockingboard timers" is explicitly v2+). The probe chain's middle
  tier is real and testable as a PROBE OUTCOME; the driver behind it is
  a stub, honestly labeled as such in `src/kernel/timer.s`'s own header.
- **AppleMouse detection is narrowed to slots {4, 5}**, not a full 1-7
  scan (sec 3.2) -- a real ID-byte-based scan needs a fact this task could
  not verify against the commons.
- **`QUANTUM_TICKS=4` is a judgment call**, not derived from any deeper
  constraint -- chosen small enough that `check-sched`'s step budget sees
  many switches without an excessive VBL count (sec 6's own amortized-
  overhead math would still work at other values; nothing about the
  design is tuned specifically to 4).

---

## 10. Deposit candidates (not deposited -- task rule: report, don't deposit)

- **The RAMRD-governs-instruction-fetch rule needs a stronger, more
  general statement than its current form.** `learning:
  01KW1GTYGVYAPQRGS5P7J66RWD` states the rule; `docs/SYSCALL.md` sec 5.1's
  own deposit candidate extends it to kernel DATA reads. This task found
  a THIRD facet empirically: **any new kernel module that reads aux/annex
  data from its own ordinary `$0200-$BFFF` code, not just the
  already-flagged copyin/copyout-adjacent code, silently reproduces this
  bug** unless it explicitly re-derives "route the read through LC" for
  itself -- the rule did not visibly transfer from `entry.s` to a brand
  new module (`sched.s`) in the SAME repository, written by an agent that
  had already read `docs/SYSCALL.md` sec 5.1 as a stated precondition for
  this task. Candidate title: "RAMRD-governs-fetch is a KERNEL-WIDE
  architectural constraint, not a copyin/copyout implementation detail --
  every module that reads aux memory from ordinary flat code needs an
  LC-resident (or page-1-relocated) read primitive, not just the two
  routines that currently have one." Concrete evidence for the "measure,
  don't estimate" half of the deposit: the resulting design costs 22x
  the operator's own back-of-envelope wakeup-scan estimate (sec 6) -- a real,
  quantified price for correctness under this constraint, useful for the
  next designer's own estimates.
- **Zero-page cross-`ALTZP`-flip cell ordering is now a FOUR-time repeat
  mistake across two tasks** (`docs/SYSCALL.md` sec 5.1/sec 7.7's three
  instances + this task's `SCHED_START` `K_SW_INSP` bug, sec 4.4/sec 7). Worth
  a dedicated, prominently-titled learning distinct from the RAMRD-fetch
  one above (this is the `ALTZP`/zero-page sibling, not the RAMRD/main-
  memory one) -- a design-pattern warning: "any kernel routine that flips
  ALTZP and ALSO needs a cached scalar value across that flip must read
  the cached value from a NON-zero-page location, OR read it into a
  register strictly before the flip -- zero page is exactly as
  cross-flip-hazardous as main memory is cross-RAMRD-hazardous, and this
  has now been gotten wrong four independent times."
- **Mouse-card / Mockingboard slot-ROM identification bytes
  (`$Cn05`/`$Cn07`-style signatures) are not covered by the
  street-library commons** -- this task's own search sweep (HACKING.md's notebook rules)
  came up empty, forcing a narrower (slot 4/5 only, register-liveness-
  based) probe than a "real" boot-time card scan would use. Worth
  depositing as a confirmed GAP (not a wrong answer, an ABSENT one) so
  the next task that needs to scan for a specific card class doesn't
  repeat the same fruitless search.
- **verilogapple's paddle-one-shot fidelity gap
  (`learning:01KZZ5492YPQSFYTYNANRJZVWH`) is now confirmed load-bearing
  for a SECOND, unrelated maux subsystem** (the scheduler, not just
  direct paddle-reading code) -- worth a brief follow-up note on that
  existing learning (not a new one) recording that a preemptive
  scheduler's own `$C073`-per-switch cadence is a second, independent
  reason the gap matters, strengthening the case for eventually closing
  it (verilogapple#13-adjacent work) beyond "a game read a joystick
  wrong."

## Caller convention: SCHED_WAKEUP clobbers the bank selection

SCHED_WAKEUP selects BANKSEL=0 internally (annex PCB scan) and does NOT
restore the caller's selection -- per the $C073 unknown-at-entry discipline,
callers must reselect (PROC_SELECT_CURBANK or explicit) before any
aux-dependent operation. Every process.s caller already does; this note
exists so the next kernel module does too. (Found by task #13's own test
harness tripping on it, 2026-08-14.)
