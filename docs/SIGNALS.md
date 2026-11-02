# SIGNALS -- held-signal delivery, dispositions, and trap

2026-09-02. The arc the kill ABI staged for: SYS_KILL has carried
`$80|signo` into wait status since 2026-09-01 *precisely so* this
design could land with no ABI change. Operator direction: "let's
build signal delivery -- trap is the payoff."

Primary source: V7 `sh(1)` trap and `signal(2)`, from the V7
Programmer's Manual in the commons
(artifact:93e04c707fdd48a095b0055d46996daa005aad427f558ee92a9d4241ae01f9b8,
chunks 558 and 750). Everything the maux column diverges on is
named here, not discovered later.

## 1. The v1 model: HELD signals, fetched at syscall boundaries

A process declares a per-signal DISPOSITION; a signal sent to it is
then one of:

  DFL    terminate, wait status $80|signo -- exactly today's kill.
  IGN    discarded at the sender. Nothing pends, nothing wakes.
  CATCH  the signal is HELD: a pending bit is set, and if the
         target is blocked in a syscall, that syscall fails with
         ERR_INTR instead of resuming its sleep. The process
         FETCHES held signals itself (SYS_SIGPEND) at its own
         safe points.

There is NO asynchronous jump into user code in v1. V7's signal(2)
hands the kernel a handler address and the kernel forges a call
frame; on this machine that means per-bank $FFxx stub surgery and
reentrancy rules no v1 consumer needs -- V7 sh's own INT handler
does nothing but set a flag and longjmp back to the loop, which is
the fetch pattern with extra steps. THE UPGRADE TRIGGER, named:
the first program that cannot poll at a syscall boundary (a vi
that must abort a redraw mid-loop is the likely first claimant).
When it arrives, SYS_SIGNAL grows handler-address actions and the
delivery point already exists (the same PRC_BLCK_RTRY choke point,
plus the syscall return path). Until then, an address passed as an
action is ERR_INVAL -- refused loudly, never stored as a promise
delivery would break.

## 2. Kernel surface

* SYS_SIGNAL (14): signal(signo, action). Actions: 0 SIG_DFL,
  1 SIG_IGN, 2 SIG_CATCH. Returns the PREVIOUS action. Refused
  (ERR_INVAL): signo 0, signo 9 (V7: SIGKILL "cannot be caught or
  ignored"), signo > 15, action > 2.
* SYS_SIGPEND (15): no parameters. Pops the LOWEST pending signo
  (fetch-and-clear one bit) and returns it; 0 = none pending.
  Lowest-first matches V7 trap's "executed in order of signal
  number". This call is a maux-ism (V7 has no sigpending) in the
  SYS_PSTAT/SYS_TTYGEO tradition: the platform-honest surface for
  a capability V7 spelled differently, documented as such.
* ERR_INTR ($E8): a blocked syscall interrupted by a held signal.
  V7's EINTR, maux's errno space.

### Dispositions are STICKY (A12)

V7 signal(2) resets a caught signal to SIG_DFL at delivery (the
"not reset when caught" asterisks in its table mark the
exceptions); every V7 handler's first act is reinstalling itself,
and the race between those two points is the canonical unreliable-
signals bug POSIX sigaction exists to fix. maux keeps dispositions
sticky -- the modern canonical behaviour, per ANACHRONISMS A12
(least surprise beats slavish mimicry). sh re-installs anyway, so
no V7 script can tell.

### Sender-side semantics (PRC_KILL, both contexts)

kill(pid, signo) consults the TARGET's disposition, except signo 9
which force-kills unconditionally. IGN: return OK, do nothing --
discarded at the sender, so an ignored signal can never
accumulate. CATCH: set the pending bit; if the target is BLOCKED,
make it RUNNABLE (clear wchan, requeue) -- the retried syscall
finds no data, reaches the block point, sees pending-caught, and
fails ERR_INTR. DFL: today's kill, unchanged. kill(self, caught)
sets the caller's own pending bit and returns -- the caller is
running, no wake needed.

The ^C sweep (PRC_INTR_SWP, tick context) applies the same rule
per victim for signal 2: IGN skips, CATCH pends+wakes, DFL kills.
A script sh at depth 3 with `trap ... 2` now SURVIVES ^C and runs
its trap; its own untrapping children still die. The marking is one
routine now (process2.s PRC_ZOMB, procspawn2.s PRC_DIE): PRC_KILL,
the ^C sweep and the BRK path below all end in it.

### SIGTRAP: a user BRK (KBRK, docs/KBRK.md)

`$00` is BRK, so a jump into zeroed memory, a corrupted binary or a
wild pointer executes it. A BRK in a USER process is signal 5, V7's
SIGTRAP (BRK is the 6502's breakpoint instruction, a PDP-11 BPT's
class): the process dies, wait status `$85`, `$?` 133, and the machine
carries on. It is delivered by the kernel to the process itself
(procspawn2.s PRC_BRK_TRAP, tick context, the ^C sweep's own tail), so
there is no sender and NO disposition is consulted: it is not
catchable or ignorable -- there is nothing to resume after a fault.
sh prints nothing for it, as for any signal death; `$?` is the report.
Refused (the machine halts, marker `$42`, as before): a root-tier
process -- pid 1 (init) and the idle process. A BRK in the KERNEL
does not reach this path: main's language card has its own `$FFFE`
(timer.s MAIN_IRQ_SHIM), which parks it -- except in the few
main-resident kernel windows that run with ALTZP=aux, an accepted
gap (KBRK-NOTES sec 1b). The console shell is NOT refused: init
respawns it. The dead process's lazy-free tag is dropped (its text
may be corrupted: a SIGTRAP bank is never reused warm), and the tty
backstop runs only if the victim was in its console's FOREGROUND
job (a background BRK must not cook a foreground raw program).

### The one delivery point

Every blocking syscall in this kernel blocks by RETRY:
PRC_BLCK_RTRY rewinds the caller's saved PC to the `jsr $FF00` and
sleeps, so a woken process re-executes the whole syscall from
userland. ERR_INTR therefore needs exactly ONE insertion: at
PRC_BLCK_RTRY's entry, if the current process has any pending
CAUGHT signal, fail ERR_INTR instead of sleeping. A signal
arriving mid-block wakes the target; the retry re-runs the
syscall; no data; the block point fires the check. Four blocking
sites (wait, tty read, MLI read paths), zero per-site code.

### State: SIG_TBL, the annex, stride 8

The PCB's 16 bytes are all spoken for, so signal state follows the
cwd-table precedent: an annex-resident pid-indexed array at
SIG_TBL_ADDR ($7500, inside the region VIDMODE's relocation freed;
48 x 8 = 384 B). Per row: +0/+1 CATCH mask, +2/+3 IGN mask, +4/+5
PEND mask (16-bit little-endian, bit signo-1), +6/+7 spare. Reads
go through PCB_RD_FIELDS (it is generic over K_PCB_PTR); writes
use the same RAMWRT-only bracket every PCB write uses.

### Inheritance (V7 exec/fork rules)

SCH_CREATE zeroes the new pid's row (a reused pid can never
inherit a dead process's traps). spawn then copies the PARENT's
IGN mask into the child -- V7 exec preserves ignored, resets caught
to default. fork copies CATCH+IGN both (V7 fork copies
dispositions); pending starts empty in every child.

## 3. trap, the payoff (sh builtin)

V7 sh(1), chunk 558: `trap [arg] [n] ...` -- arg is read and
executed when the shell receives signal(s) n; scanned once when
set and once when taken; executed in order of signal number; arg
absent resets traps to original values; arg '' ignores the
signal(s); n=0 runs arg on exit from the shell; `trap` alone
lists.

maux sh implements exactly that shape. Mechanics: `trap 'cmd' n`
stores the string and calls SYS_SIGNAL(n, CATCH); `trap '' n`
calls SYS_SIGNAL(n, IGN); reset restores DFL. The PUMP: after
every command completes -- and whenever a read comes back
ERR_INTR -- sh drains SYS_SIGPEND, running each popped signo's
stored string through the ordinary line-execution path (the line
buffer is free between commands, so there is no reentrancy). The
exit trap (0) runs once, cleared first, on every exit path.

Testability without a keyboard: `kill -2 $$` sends INT to the
script's own shell, so trap gates run in the script harnesses;
the tick-context CATCH path (a real ^C) is gated interactively in
check-play against a nested sh.

## 3a. trap SHIPPED 2026-09-02

`trap` the sh builtin is in (src/bin/shtrap.s, CHCK_BLTN_TRAP in the
dispatch chain). Numbers and the common names (EXIT INT TERM HUP QUIT
KILL). Storage is TRAPACT[0..15] + 16 x 256B TRAPTAB slots in sh's
arena; SH_INIT_ZR disarms them at every spawn. The pump
(PUMP_NEXT_TRAP) sits at MAINLOOP's top, drains one pending signal via
SC_SIGPEND, stuffs its string into LINEBUF and runs it through the
ordinary engine (SH_RUNLINE). The exit trap (0) fires from SH_EXIT,
which every exit path now routes through. Gated in check-play's trap
phase (a nested `SH < DEMO/TRAP`): `kill -2 $$` -> the pump runs
TRAPHIT; `exit` -> the 0-trap runs TRAPBYE. Sabotage-proven (disable
the pump -> the phase times out).

**TWO latent issues this work surfaced, both NOTED not yet fixed:**

1. **CSPTR leak on an unterminated-heredoc error.** The pump correctly
   DEFERS while a construct is open (CSPTR != 0) -- draining a trap
   mid-`if` would run it in the wrong frame. But sh's unterminated-
   heredoc ERROR path leaves CSPTR nonzero, so a trap set after such an
   error never fires in that shell. The guard is right; the heredoc
   cleanup is what is missing. (Found wiring the shlang gate: a trap
   after TR3SCRIPT's `. HDBAD` never fired.)

2. **Caught-signal-during-a-foreground-wait leaves transient state.**
   `kill -2 $$` spawns `kill` as a child the shell WAITS for; the
   self-signal interrupts that wait with ERR_INTR. The shell abandons
   the wait (procedurally correct -- the trap fires at the next
   MAINLOOP top), but the interrupted `kill` child is left an unreaped
   zombie, and under heavy bank/fd pressure the pump's immediately-
   following spawn can starve, dropping the trap's own output. It is
   reliable from a fresh-ish shell (check-play's nested sh proves it);
   it degraded only in the shlang harness after ~50 accumulated spawns.
   The real fix is a clean reap of the interrupted foreground child --
   deferred, since running the trap inline during the wait would
   clobber the wait loop's own LINEBUF/WAITCNT state (the re-entrancy
   the pump-at-MAINLOOP-top design exists to avoid).

## 4. What this is NOT yet

No handler addresses (trigger named above). No signal queuing --
pending is a BITMASK, a second INT before the first is fetched
coalesces, exactly V7's own behaviour. No process groups as a
PCB field -- but since 2026-09-08 (docs/JOB-CONTROL.md Increment
A) ^C no longer sweeps by spawn depth: the interactive shell
declares its foreground pipeline per console (SYS_TCSETFG) and
the sweep kills that job -- the declared pids and their
descendants -- so a background `&` child SURVIVES ^C without
needing INT ignored, and a ^C on one console no longer reaches
another's job. (V7 sh ignored INT/QUIT in `&` children for the
same effect; maux gets it from the foreground set instead.)

## 5. SIGHUP to a stopped orphan (ORPHAN-1, 2026-10-22)

When a process dies its children are adopted by init (src/kernel/
process2.s `PRC_ADOPT`). 4.2BSD kern_exit.c adds: "Stopped processes
are sent a hangup and a continue", designed to be safe for setuid
programs "since they must be willing to tolerate hangups anyways".
maux does the same through the dispositions of sec 1, not around them:

  DFL    the adoptee dies, wait status `$81` (`$80|1`, SIGHUP); it is a
         NEW death, so ITS children are adopted in turn
  IGN    nothing pends; the CONT resumes it
  CATCH  the signal is held (pending bit 1, no wake: it is not blocked);
         the CONT resumes it and it fetches the HUP with SYS_SIGPEND

A running (not stopped) adoptee is only reparented. The CONT is the
kernel's (`PRC_UNSTOP`, shared with `SYS_CONT`), not a signal number:
SYS_CONT stays parent-only. `nohup` (HUP ignored) therefore survives its
shell's death even when parked with ^Z.
