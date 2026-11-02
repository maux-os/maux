# Job control -- suspend, fg/bg, jobs (the arc)

**Status:** LIVE. Increments A (foreground targeting), B (suspend core),
C (shell UX) and E (cooperative `^Z`, vi) are built and gated
(`check-jobctl-a`, `-b`, `-c`, `-e`); ORPHAN-1 (orphans go to init) is
built. Increment D (SIGTTIN/SIGTTOU tty arbitration) is NOT built, and
no pid-filtered wait (waitpid) exists. Operator asked for it 2026-09-08
("a check over the terminal -- suspend, job control, maybe having vi
save/restore the terminal"); this is the design and the as-built record
of the arc to `^Z` / `fg` / `bg` / `jobs`. The sections up to "Architect
pass" are the original brief (the starting point and the reasoning);
the sections from there on are the build contract and what was built.

Grounded in `docs/SIGNALS.md`, `docs/SCHED.md`, `docs/CONSOLE.md` sec 4,
`inc/mm.annex2.equ` (the PCB shape). User-facing: `docs/man/sh.1`
(`jobs`, `fg`, `bg`).

## What shipped before the arc

(Starting point of the brief. `BG_PIDS`/`BG_CNT`/`BG_RECORD` below were
replaced by the shell job table in Increment C.) Half of "job control"
was already here and was under-credited:

- **Background pipelines.** `A | B &` backgrounds the *whole* pipeline
  (`BG_RECORD`, shbltn.s): every stage that spawned is pushed onto
  `BG_PIDS`, `LASTSTATUS` = 0 (POSIX async-list status). `BGMAX` = 14,
  the bank ceiling, so the table can't overflow before the machine runs
  out of banks.
- **`wait`** (builtin, `CHCK_BLTN_WT`): drains `BG_CNT` recorded children
  by COUNT (SC_WAIT takes no pid in this ABI). `wait PID` is *refused*,
  not silently widened. Bare `wait` with nothing outstanding is a no-op.
- **`^C` sweep** (`PRC_INTR_SWP`, procspawn2.s): at tick time, zombies
  every LIVE process at spawn depth >= 3 (boot=parent 0, console shell =
  its child, the pipeline = grandchildren+), sets `STATUS_INTR`, wakes
  parents, and -- crash-safety backstop -- restores each victim's own tty
  to cooked+echo. Honours per-victim INT disposition (IGN skips, CATCH
  pends+wakes so a trapping `sh` survives, DFL dies).
- **Held-signal model** (SIGNALS.md): DFL kills / IGN discards / CATCH
  holds -> `ERR_INTR` at the one delivery point (`PRC_BLCK_RTRY`). NO
  async jump into user code; NO stop action; signo 9 uncatchable.

What's missing is the **suspend/resume** half -- and the machinery to aim
terminal signals at a *named* job rather than "whatever is at depth 3".

## The four gaps

(All four are closed by Increments A-C; real tty arbitration remains
Increment D.)

1. **No STOPPED state.** `PCB_STATE` is UNUSED/RUNNABLE/RUNNING/BLOCKED/
   ZOMBIE (0-4, mm.annex2.equ). Suspend needs a sixth: a process
   that is *not* schedulable but *not* dead -- bank intact, image live,
   waiting to be continued. This is the one genuinely new kernel state.
2. **Terminal signals are aimed structurally, not by identity.** The `^C`
   sweep uses spawn-depth >= 3 as a proxy for "the foreground pipeline".
   That proxy is exactly correct while there is only ever ONE foreground
   pipeline -- but `^Z` + `fg`/`bg` create *several* jobs on one console,
   only one of them foreground. The kernel needs an explicit per-console
   FOREGROUND pointer. (CONSOLE.md sec 4 already flags the depth heuristic
   as an accepted gap with a named trigger; this is that trigger.)
3. **`wait` can't poll or distinguish stopped.** It blocks, reaps by
   count, and only sees ZOMBIEs. `jobs`/`&`-reporting need a
   non-blocking reap (WNOHANG); `fg` waiting on a job that then *stops*
   again needs wait to report STOPPED (WUNTRACED), not just exited.
4. **No shell job table / no `jobs`/`fg`/`bg`.** `BG_PIDS` is a flat
   reap list, not a job model (no job numbers, no "current job", no
   stopped-vs-running). `fg %1` needs the shell to name jobs.

## The maux-native design decisions

**`^Z` is a console-driver sweep, NOT a signal disposition.** This is
the load-bearing call. The held-signal model has no "stop" action by
design (SIGNALS.md sec 1), the same way it has no async handler address --
and for the same reason: a stop that suspends a process mid-syscall is
async delivery. So `^Z` mirrors `^C`: a tick-context sweep
(`PRC_STOP_SWP`, sibling of `PRC_INTR_SWP`) that transitions the
foreground job to STOPPED and wakes the shell -- it does NOT travel
through the DFL/IGN/CATCH disposition table. A program that wants to
*catch* `^Z` (save state before suspend) is the exact analog of "a
program that must handle a signal asynchronously", and is deferred on
the same trigger SIGNALS.md already names for handler addresses. v1: the
foreground job stops; it cannot decline.

**Foreground ownership lives per-CONSOLE, job membership per-SHELL.**
The PCB is full -- 16 bytes, and `PCB_PTR_FOR` indexes with `pid<<4`
(four ASL/ROL pairs, no multiply), so a `PCB_PGID`/job byte can't be
added without renegotiating the entry size and paying a real
shift-and-add on every PCB touch. Don't. Instead:
- The KERNEL learns one small thing: **per console (tty1..4), which job
  is foreground** -- a table of <= 4 entries in the annex, keyed by
  console, holding the foreground job's *leader pid* (and enough to
  identify its pipeline members -- see below). Terminal signals (`^C`,
  `^Z`) target that job; everything else the kernel already does by
  parent-chain is unchanged.
- The SHELL keeps the **job table** in its own bank (job#, leader pid,
  member pids, state running/stopped, the command text for `jobs`).
  It spawned the pipeline; it already knows the members. This mirrors
  how `^C` works structurally today -- the kernel never needed a pgrp
  field, and it still doesn't.

**"Which pids are this job?"** The `^C` sweep answers this with the
parent chain (depth >= 3). For a *named* foreground job the cleaner
answer is the job LEADER + "processes whose parent is the shell and
whose leader is P" -- but maux has no pgid byte. Two ways, pick in the
build: (a) the kernel's per-console foreground entry stores the leader
pid, and the sweep walks the shell's children reaping the leader and any
child sharing its spawn-batch (the shell spawns a pipeline as a batch --
check whether `PRC_SPAWN`/`PRC_PIPE` already give a batch/leader link to
lean on); (b) the shell hands the kernel the member pid-set when it
foregrounds the job (a small `SYS_TCSETFG`-shaped call), so the kernel
holds the exact set and the sweep needs no chain-walk. (b) is more
honest and avoids re-deriving membership in tick context; prefer it
unless the annex space argues otherwise.

**Stopped status convention.** wait status is already `$80|signo` for a
signalled death and a small number for a normal exit. Reserve a
STOPPED encoding distinct from both -- V7 uses `0177` (`$7F`) in the low
byte for WIFSTOPPED; take `$7F` (or `$7F|signo` high) so the shell can
tell "job 1 Stopped" from "job 1 Done" from "job 1 Terminated". Pin the
three-way decode in a gate so a future exit-status change can't collide
with it silently.

## Layers, cheap -> expensive (ship each independently)

**Stage 0 -- explicit per-console foreground ownership.** Replace the
depth >= 3 heuristic in `PRC_INTR_SWP` with the per-console foreground
job set (kernel table + the shell setting it when it foregrounds a
pipeline). NO user-visible change: the single interactive foreground
pipeline still gets `^C`. This is pure refactor + the hook every later
stage hangs off. **Without it, the moment `^Z`/`fg` create a second
job, `^C` aimed at the wrong depth-3 process is a correctness bug.**
Also closes CONSOLE.md sec 4's accepted-gap trigger properly.

**Stage 1 -- WNOHANG wait + async job reporting.** Add a non-blocking
reap (WNOHANG flag on `PRC_WAIT`, returns 0 when no child is ready
instead of blocking). Shell polls it at prompt time and prints
`[1]  Done   cmp A B` / `[1]  Terminated` -- the V7 "reported at the next
prompt" behaviour, a clean fit with the held-signal/no-async model (no
SIGCHLD needed). Gives `&` users completion notices with no new state.
Depends on Stage 0 only so `^C` doesn't hit the bg job.

**Stage 2 -- the suspend core (the headline).** New `PCB_STOPPED` state;
`PRC_STOP_SWP` (`^Z` console sweep -> foreground job STOPPED + wake shell
with `$7F` status); `PRC_WAIT` grows WUNTRACED (report STOPPED
children); a resume path (STOPPED -> RUNNABLE + `RUNQ_PUSH`, the inverse
of the stop -- this is the SIGCONT equivalent, cheap once STOPPED
exists). Shell grows the **job table** and the `jobs` / `fg` / `bg`
builtins:
  - `jobs` -- list job#, state, command.
  - `fg %n` -- set job n foreground on the console (Stage 0 pointer),
    resume it, `wait` (WUNTRACED) on it.
  - `bg %n` -- resume job n, leave the shell foreground, reprint prompt.
This is the big stage; everything above is prerequisite plumbing that
also stands alone.

**Stage 3 -- DEFERRED: tty arbitration (SIGTTIN/SIGTTOU).** A background
job that reads the console should stop (SIGTTIN); one that writes
scrambles the foreground display (SIGTTOU). ANACHRONISMS W4 already
ruled the **cheap v1 answer**: require background jobs to redirect
output (`AS BIG.S > LOG &`) and *diagnose* a bare `&` with unredirected
stdout rather than allowing the mess. Do that in Stage 1/2; leave real
tty arbitration here until someone hits its absence. It is the deepest
layer (every console read/write path checks foreground identity) and the
least essential.

## Costs and tensions (state them, don't rediscover them)

- **PCB is full.** No per-process pgid byte without breaking `pid<<4`
  indexing. Foreground ownership is per-console (<= 4 entries), job
  membership is the shell's. This is a constraint, not a compromise --
  it's how `^C` already works.
- **The signal model stays intact.** `^Z` is a driver sweep, not a new
  disposition; DFL/IGN/CATCH are untouched. Catchable-`^Z` is deferred
  on SIGNALS.md's existing async-handler trigger. Don't grow the
  disposition table for this.
- **Stopped status must not collide** with `$80|signo` or normal exit --
  gate the three-way decode.
- **STOPPED banks are held banks.** A stopped job keeps its aux bank
  (that's the point -- its image is live). With a 14-bank ceiling,
  several stopped jobs + several background jobs can exhaust banks; `fg`
  failing to find a free bank isn't the risk (resume needs none), but
  spawning a *new* job while many are stopped is. Document it; the
  existing bank-exhaustion path already refuses a spawn.
- **Tick-context discipline.** `PRC_STOP_SWP` runs where `PRC_INTR_SWP`
  does -- no MLI, no fd close, annex writes + `RUNQ`/wake only. A stopped
  job's fds stay open (correct: it's resumable); only the shell's reap
  closes fds, and a stopped job is never reaped.

## Gates (emulator, check-play family shape)

- **Stage 0:** with a background job present, `^C` kills ONLY the
  foreground pipeline, not the bg job. RED on today's depth-only sweep
  (it'd kill the depth-3 bg job too), GREEN after. Teeth: prove the bg
  job survives a `^C` aimed at the foreground.
- **Stage 1:** `sleep-ish &` then a `^C`-free prompt; the completion
  line prints at the NEXT prompt, not synchronously. `$?` after `X &`
  is 0. WNOHANG returns 0 (not block) with a live-but-unfinished child.
- **Stage 2:** start a job, `^Z` -> prompt returns and `jobs` shows it
  Stopped (RED before: no STOPPED state, `^Z` is inert or kills);
  `fg %1` resumes and completes; `bg %1` resumes without taking the
  console; a job that stops, `fg`s, and stops AGAIN reports Stopped both
  times (WUNTRACED). Stopped-status decode: `$7F` != Done != `$80|signo`.
- **Backstop:** a STOPPED job whose shell is killed doesn't strand a
  bank forever -- the exit/reap path must reap stopped children of a
  dying parent (mirror the ZOMBIE reap). Prove no bank leak.

The gates run in `check-all-cross`. Pure software + scheduler -- no
hardware fidelity claim.

---

# Architect pass -- grounded decisions (2026-09-08)

The brief above is the shape; this section is the build contract, firmed
against the actual code (grounding pass, file:line below). Three findings
changed the plan:

- **There is NO per-console foreground notion, and `^C` is machine-GLOBAL.**
  `K_INTR_PEND` (sched.s:82) is one flag with no console index; `TTY_INTR`
  (tty3.s:294) sets it; `SCH_TICK` (sched2.s:22) runs `PRC_INTR_SWP`, which
  kills EVERY depth>=3 PCB on the whole machine -- a `^C` on tty1 already
  kills tty2's foreground job (latent bug, VC_COUNT=4). So the foundation
  is not "swap the depth heuristic for a pointer"; it is "add a per-console
  foreground job set AND thread the typing console through the interrupt
  path." `VC_ACTIVE` (tty.s:605) = on-glass console; `VC_LIVE` (tty.s:644)
  = a rendering pointer, NOT a foreground concept.
- **`MAXCMD = 3`** (sh.s:65) -- a job is <=3 pids, already in `CMD_PID`
  (sh.s:436). A per-console foreground set is 4 bytes x 4 consoles = 16
  bytes of annex. No pgid byte in the PCB needed (it stays full at 16).
- **A new syscall is the low-blast-radius path.** `SC_WAIT` (syscallp.s:88)
  has 8 userland callers (all via the wrapper, insulated from a parm-shape
  change) but ~60 test sites build the parm block by hand with `ldy
  #SYS_WAIT`. Extending `SYS_WAIT` breaks the tests; a NEW number
  (next free = 17, room to $64) breaks nothing.

## The three new syscalls (17, 18, 19)

Adding one: `sc.proc.equ` (the `equ`), `kdisp.equ` (`K_DISP_COUNT`
16->N, bounds-checked entry.s:157), `kdisp.s` (append `dfb <PRC_x` /
`dfb >PRC_x` -- positional, append-only, emits real bytes so image layout
shifts), the `PRC_x` handler, and the `SC_x` wrapper. Scheduler-only and
testev harnesses carry their own smaller dispatch tables and must NOT be
touched.

- **`SYS_TCSETFG` (17)** -- the shell declares its console's foreground
  job. Parm: pointer to `{count, pid0, pid1, pid2}` (count 0 = "shell
  itself is foreground", i.e. an idle prompt). Kernel stores it in
  `VC_FGJOB[console]` keyed by the caller's controlling console (fd0's
  console). SET-TIME HARDENING: each pid must be a child of the caller
  OR THE CALLER ITSELF (else ERR_INVAL) -- the only caller is the shell
  setting its own children, and this stops a buggy caller from aiming
  the sweep at arbitrary pids. A set that names the caller is a SELF
  set (TAB-A2, 2026-10-18; the stored count has bit 7 set): the sweep
  matches its members EXACTLY and never walks to their descendants, so
  the shell at an idle prompt is the foreground of nothing but itself
  (POSIX: the shell's own process group holds the tty) and its `&` jobs
  and stopped jobs are out of reach of its ^C. The shell is then a
  victim only as itself, and only while it has INT/TSTP set to CATCH
  (sh's editor brackets every raw read: CATCH before the declare, `{0}`
  before the restore). The user-visible difference: a raw-mode line
  editor can be told about ^C and ^Z instead of reading them as a bare
  CR (learning:01M56Q7BH2T3B9TPX7FM47Q0VC).
- **`SYS_CONT` (18)** -- resume a stopped process (the SIGCONT
  equivalent). Parm: pid. STOPPED -> RUNNABLE + clear WCHAN + `RUNQ_PUSH`,
  modelled EXACTLY on `PRC_SIG_SND`'s blocked-wake (procsig.s:103-118).
  Not folded into `SYS_KILL`: maux's signal model is "every nonzero signo
  terminates" (SIGNALS.md sec 1); a continue is not a termination and does
  not belong in the disposition table. ERR on a pid that is not STOPPED
  (or not the caller's child -- same hardening).
- **`SYS_WAITJOB` (19)** -- wait with job-control semantics. Parm:
  `{statusptr, flags}`. `flags`: `$01` WNOHANG, `$02` WUNTRACED. Writes a
  **2-byte** `{kind, code}` to statusptr -- `kind` 0 exited / 1 signalled /
  2 stopped, `code` = exit status / signo / (stop reason, 0 for `^Z`).
  Returns pid in A (0 = WNOHANG and nothing ready), carry+ERR_CHILD if the
  caller has no children. **Why 2 bytes, not V7's `0177`:** maux's status
  is a single byte, and `$7F` = exit code 127 = "command not found" -- a
  real collision. The `{kind,code}` pair is the WIFEXITED/WIFSIGNALED/
  WIFSTOPPED shape, collision-free, and the SYS_PSTAT/SYS_TTYGEO
  "platform-honest maux-ism" precedent. Shares `PRC_WAIT`'s reap core
  (process2.s:254) parameterised by flags + status shape; the legacy
  `SYS_WAIT` (1-byte status, blocks, reaps ZOMBIE only) is UNTOUCHED, so
  the `wait` builtin and all ~60 test sites keep working.

## PCB_STOPPED -- the blast radius (6 modules)

`PCB_STOPPED equ 5` in mm.annex2.equ:130. A stopped process is not
schedulable, not dead, bank intact, resumable. Every site that reads
PCB_STATE must weigh it:

- **sched.s `:statechk` (541-549)** -- dispatch skips non-RUNNABLE, so
  STOPPED is excluded automatically. LOAD-BEARING RULE: **never
  `RUNQ_PUSH` a stopped pid** (it would be popped and skipped forever).
- **sched2.s SCH_WAKEUP (110-139)** -- wakes BLOCKED-on-WCHAN -> RUNNABLE.
  STOPPED must be a DISTINCT state from BLOCKED so a channel wakeup can
  never un-stop a `^Z`'d job. (This is why STOPPED is its own value, not
  "BLOCKED on a magic channel.")
- **process2.s PRC_WAIT (272-282)** -- counts children by parent, reaps
  ZOMBIE. A stopped child still counts (so wait doesn't ERR_CHILD) but is
  not reaped. Legacy `SYS_WAIT` must not BLOCK forever on a
  children-all-stopped set -- decide: legacy wait treats a stopped child as
  "no reapable child" and returns... it must not hang. Simplest: legacy
  `SYS_WAIT` blocks only if a NON-stopped child exists; if every child is
  stopped, it returns ERR_CHILD-shaped or reports nothing. `SYS_WAITJOB`
  is the one that reports stops (WUNTRACED).
- **procspawn2.s PRC_INTR_SWP (259-266)** -- `^C` sweep. Once retargeted
  to `VC_FGJOB` (Increment A), a stopped job is not in the foreground set,
  so it is not hit; keep a defensive skip of STOPPED anyway.
- **procspawn2.s PRC_KILL (446-453)** -- "alive" = not UNUSED/ZOMBIE,
  which already includes STOPPED, so `kill -9` of a stopped job works.
- **procsig.s PRC_SIG_SND (103-118)** -- the template `SYS_CONT` copies.

**STOPPED report-once:** `SYS_WAITJOB(WUNTRACED)` reports a stop every
call on a STOPPED child. The ONLY sanctioned WUNTRACED consumer is `fg`'s
blocking loop, which consumes the stop and exits -- so a single STOPPED
state suffices and no "reported" bit is needed. NAMED INVARIANT (gate
it): do not poll WUNTRACED; the prompt-time poll uses WNOHANG WITHOUT
WUNTRACED (it wants exits, not stops). If a second WUNTRACED consumer
ever appears, add `PCB_STOPPED_RPT`.

## The `^Z` sweep and tty restore

`^Z` ($1A -> high-bit $9A) is captured in `TTY_KEYIN` exactly where `^C`
($83) is (tty3.s:195), sets a `K_STOP_PEND` (carrying the typing console,
like the retargeted `K_INTR_PEND`), and `SCH_TICK` runs `PRC_STOP_SWP` --
`PRC_INTR_SWP`'s twin: for each pid in `VC_FGJOB[console]` that is alive,
set PCB_STOPPED (do NOT zombie), and restore its console to cooked+echo
(`PRC_TMD_RST`, the same backstop `^C` uses -- a `^Z`'d raw-mode program
must not leave the glass wedged), then wake the shell. Process-context
tick time only (no scheduling from IRQ -- `learning:01M096X5CNKFNNJW8XND8BA89R`),
same masking discipline as `PRC_INTR_SWP`.

**v1 LIMITATION (document, don't solve):** `^Z`'ing a FULL-SCREEN program
(vi) is rough -- real vi catches SIGTSTP to save/restore its screen, which
needs async handler delivery, explicitly deferred (SIGNALS.md sec 1). v1
`^Z` restores cooked+echo so the shell is usable, and `fg` resumes the
program, but a clean redraw waits on the program's next repaint. The
common case -- suspend a long CPU/batch job -- works cleanly. The
alt-screen backstop (`PRC_ALT_RST`) is NOT fired on `^Z` (the program
still owns its alt-store; it is suspended, not dead).

## Increments

**Increment A -- foreground targeting (build first).** `VC_FGJOB[4][4]`
in the annex; `SYS_TCSETFG` (17) + its `SC_TCSETFG` wrapper; thread the
typing console through `K_INTR_PEND` (TTY_INTR records `VC_ACTIVE`);
retarget `PRC_INTR_SWP` to kill `VC_FGJOB[console]`'s live pids instead
of depth>=3; the shell (`RUN_PIPELINE`, shblt2.s:169) calls
`SYS_TCSETFG(CMD_PID[0..NCMD-1])` before the foreground reap loop
(shblt2.s:366) and `SYS_TCSETFG(count 0)` after it / on backgrounding.
NO new PCB state, NO suspend. Gate: with a background job live, `^C`
kills ONLY the foreground pipeline; a pid NOT in the fg set survives
(RED today -- the global sweep kills it). Also fixes the multi-console
`^C` bug. This is pure foundation; ship it alone.

**Increment A -- as built (2026-09-08).** Everything above, plus three
decisions the build had to make:

- *The caller's console is its fd 0's device* -- `PRC_TCSETFG` derives it
  the way `PRC_TMD_RST` already does (one `PRC_GET_FDOBJ`, `FD_TTY0..3`
  -> console 0..3). No new state, and the shell passes nothing: fd 0 is
  the same byte sh's `SH_INTERACT` is decided from, so "which console
  am I on" and "am I interactive" agree by construction. A caller whose
  fd 0 is a pipe/file/closed is refused `ERR_INVAL`.
- *The job is the declared pids' SUBTREE, and only an interactive shell
  declares.* A non-interactive `sh SCRIPT` (or a `$( )` child, which is
  a nested sh reading a pipe) is itself inside the job its parent
  declared. If it declared too it would replace its parent's set with
  its own child and step OUT of the job -- ^C would kill the command and
  leave the script running. So sh declares only when `SH_INTERACT`
  (POSIX: `set -m` is off in a script), and the sweep reaches a
  member's children by walking each live PCB's parent chain up to a
  member (`PRC_FG_HAS`, bounded). That is exactly the subtree the
  depth >= 3 rule used to reach, now rooted at a named job on one
  console; per-victim disposition (IGN/CATCH/DFL) is unchanged, so a
  trapping script sh still survives and runs its trap.
- *A reaped pid is scrubbed out of every set* (`PRC_FG_SCRUB`, called
  from `PRC_WAIT`'s reap). pid == bank on this kernel: in `A | B`
  foreground, A reaped while B runs, a `&` job forking into A's freed
  bank would otherwise inherit A's place in the set and die to the next
  ^C. The shell's `SYS_TCSETFG(count 0)` at the prompt is still made;
  the scrub covers the window between stage reaps.

Layout: `VC_FGJOB_ADDR` `$7680` (16 B, MEMMAP.md row), `K_INTR_PEND` =
typing console+1 (0 none), `SCH_TICK` hands it to the hook in A
(`stz` leaves A alone -- no sched2.s code change), `PRC_INIT` zeroes the
table. Pre-existing, not new: a killed member's own killed child is
left ZOMBIE (no init to adopt it -- sc.proc.equ's `SYS_KILL`
note; superseded by ORPHAN-1, below), and the ^C-before-declare spawn
window (CONSOLE.md sec 4).
Gate: `scripts/check_jobctl_a.py` (`check-jobctl-a`, in
check-all-cross) -- RED on d52920d for all three cases, `idle_prompt`
included (the depth sweep zombied the `&` sleep on every ^C, even one
typed at an empty prompt), GREEN after.

**Increment B -- the suspend core (kernel).** `PCB_STOPPED`; `K_STOP_PEND`
+ `^Z` capture + `PRC_STOP_SWP`; `SYS_CONT` (18); `SYS_WAITJOB` (19)
sharing PRC_WAIT's core. No shell UX yet -- gate at the syscall level
(a test harness: spawn a child, `SYS_TCSETFG` it, inject `^Z`, assert
PCB_STOPPED via SYS_PSTAT and cooked+echo restored; `SYS_CONT` ->
RUNNABLE; `SYS_WAITJOB(WUNTRACED)` returns {stopped}; a dying parent
reaps its stopped children -- no bank leak).

**Increment B -- as built (2026-09-08).** Everything above, plus the
decisions the build made:

- *One sweep, two modes.* `PRC_STOP_SWP` is not a copy of
  `PRC_INTR_SWP`: both are entries into one scan (`PRC_FG_SWP`,
  procspawn2.s) selected by `PRC_SWP_MODE`. Same console row, same
  victim set (the job's live pids and their descendants, so a
  `sh SCRIPT` job stops whole), same wake-the-parent tail and carry
  contract. The stop mode marks `PCB_STOPPED` + WCHAN 0, fires only
  `PRC_TMD_RST` (never `PRC_ALT_RST`), and consults no disposition.
  Both modes skip a pid that is already STOPPED: it is in no set the
  shell keeps current, and if a stale entry named it, `^C` must not
  kill a job the user parked.
- *`^Z` is `^C`'s twin all the way down.* `TTY_STOP` shares
  `TTY_INTR`'s tail (`TTY_INTR_TL`): echo `^Z`, drop type-ahead,
  complete an EMPTY line. So a shell blocked in read reprompts, and
  a harness cannot use "wait for return" as a pause (jctest.s waits
  for a `G`). `K_STOP_PEND` + `K_STOP_HOOK` mirror the `^C` cells
  (clc stub default from `SCH_INIT`; playtestb.s installs the sweep);
  `SCH_TICK` runs the stop dispatch after the kill one, switching
  away with requeue=0 when the current process was the victim.
- *The wait core is shared, parameterised by one byte.* `PRC_WAIT`
  and `PRC_WAITJOB` are two entries into `PRC_WAIT_CORE`
  (process2.s); `PRC_WFLAGS` bits 0/1 are WNOHANG/WUNTRACED and bit 7
  selects the two-byte `{kind, code}` shape. The scan counts children
  and, separately, NON-stopped children: **an all-stopped child set
  returns ERR_CHILD from both waits** (unless WUNTRACED asked) -- only
  the sleeper could continue them, so blocking would be a deadlock.
  Consequence for B alone (no shell UX yet): after a `^Z` the shell's
  legacy reap loop gets ERR_CHILD, clears the set and reprompts; the
  stopped job is parked until `fg` exists (C) or the shell exits. If a
  `&` job is also live, the legacy wait blocks on it instead -- C's
  `fg` loop uses `SYS_WAITJOB(WUNTRACED)` and does not have this.
- *The reap tail is a routine, and orphaned stops are reaped.*
  (SUPERSEDED 2026-10-22 by ORPHAN-1: `PRC_REAP_ORPH` is gone; the
  orphans are adopted by init at their parent's death, below.)
  `PRC_REAP_ONE` (scrub + close fds + UNUSED + free bank) is what
  the wait reap always did, callable; `PRC_REAP_ORPH` reaped every
  STOPPED process whose parent is UNUSED or ZOMBIE, restarting its
  scan after each reap so a stopped subtree drains tier by tier. It
  runs from `PRC_EXIT`, `PRC_KILL`'s kill-self path, and after every
  wait reap. A stopped child of a `^C`-killed parent is therefore
  reaped when the grandparent reaps the parent. Gated: the child's
  bank comes back `free` or lazy-free `held`, never `live`.
- *`SYS_CONT` lives in procsig.s*, next to the `PRC_SIG_SND` wake it
  copies; refused `ERR_INVAL` for anything but the caller's own
  STOPPED child.
- *Two PCB_STATE consumers the blast-radius list missed.* `ps`
  (src/bin/ps.s) clamped unknown states to `-` (unused); a stopped
  job now prints V7's `T`. And the scheduler-only harnesses put
  procsig.s WITHOUT procspawn.s, so `PRC_CONT` could not live next
  to `PRC_SIG_SND` (its `PCPI_CALLPARM` is unresolved there -- the
  box's check-sched found it); it lives in process2.s beside
  `PRC_WAITJOB`.
- *Costs.* Kernel +445 B; every process-bearing harness pad moved
  (forktest 49->50, processtest 53->54, argvtest 48->49 blocks);
  liba +36 B per process-calling program (the two wrappers), sh.bin
  18835 of 18864. **KNOWN_OVERRUN MAUXEXTEST 581->1026, bumped not
  retired** -- the fixture text is 32 `CRT_BY_PATH` sites across eight
  harness files, not one block; C (no kernel growth) is the window to
  pay it. *(Paid after C, 2026-09-08: all 37 fixture/script files are
  staged onto ex.po by `build_ex_image.py`'s FIXTURES, byte-identical;
  MAUXEXTEST ends `$8F6A`, 2.2 KB under, and KNOWN_OVERRUN is empty
  again.)* That overrun stayed latent (the main-memory tail is dead
  once copied to bank 1), but the SAME growth broke check-ex another
  way: extestb9.s reserved its sessions 10-16 result block at
  `$9800-$9EFF` in bank 1 "with several hundred bytes of headroom
  above the image's end", and A+B's +742 B walked the image tail to
  `$9C02`, through it -- session 10's first result write landed on
  the harness's own helpers and step 40 died with a ProDOS `$40`.
  The block is now `$A800-$AEFF` (harness + check_ex.py); ~3 KB of
  headroom again, and the header names the rule (above the image's
  END, not above a fixed number).
- *Gate:* `scripts/check_jobctl_b.py` (`check-jobctl-b`, in
  check-all-cross) drives `src/test/jctest.s` on `build/jobctl.po`
  (a play.po clone + `/BIN/JCTEST`, `build_jobctl_image.py`) -- stop /
  cont / stop2 / legacy / reap, asserted on the annex PCB table,
  `VC_TMODE`, SYS_PSTAT as printed, and the free list / LZ tags. RED
  on faad254 (call 19 unwired, `^Z` inert), GREEN after.

**Increment C -- the shell UX.** Job table (job#, leader, <=3 members,
state, command text) in sh's bank; `jobs`/`fg`/`bg` builtins; `fg`'s
`SYS_WAITJOB(WUNTRACED)` loop; prompt-time `SYS_WAITJOB(WNOHANG)` drain
printing `[n] Done/Terminated`; the `&`-unredirected-stdout diagnostic
(ANACHRONISMS W4). Uses B's syscalls; no new kernel surface.

**Increment C -- as built (2026-09-08).** `src/bin/shjob.s`, put after
shtrap.s; no kernel bytes. The decisions the build made:

- *Every pipeline is a job, one truth.* RUN_PIPELINE takes a job-table
  row BEFORE it spawns (`JOB_ALLOC`: state Running, the command text
  rebuilt from CMD_ARGV -- LINEBUF is tokenised in place by then -- and
  a full table refuses the line like a failed pipe would) and fills
  in the pids after (`JOB_SETPIDS`). A `&` pipeline keeps its row
  (`JOB_BG`: `[n] pid`, `$?` = 0, W4's `sh: background output not
  redirected` when the last stage's stdout is still the tty); a
  foreground one is waited on through `FG_WAIT` and freed on
  completion, or left Stopped by a `^Z`. `BG_PIDS`/`BG_CNT`/
  `BG_RECORD` are gone -- `wait` drains the table by state, and the
  `( ... ) &` path (`JOB_BGONE`) allocates its row the same way. The
  row: `JOB_ST` (free/Running/Stopped/Done), `JOB_PID[MAXCMD]`,
  `JOB_TAIL` + `JOB_EXST` (the tail stage's status, exit code or
  `$80|signo`, the legacy one-byte shape, so `$?` after `fg` is what
  the pipeline would have given), `JOB_TXT[32]`; `JOB_CUR`/`JOB_PREV`
  are `%+`/`%-`, `JOB_FG` the row being waited on. All in the arena:
  the table costs no image bytes; SH_INIT_ZR zeroes the states.
- *Three wait modes, because WUNTRACED cannot block past a parked
  job.* `PRC_WAIT_CORE` reports the lowest-pid ready child and a
  STOPPED child is "ready" on every WUNTRACED call (the report-once
  invariant was placed with the consumer). That is fine for the ONE
  stopped job `fg` is about to consume -- and wrong the moment a
  second job is parked: a WUNTRACED wait on the first returns the
  parked pid forever and never sleeps. So FG_WAIT picks per call: no
  other row Stopped -> `WJ_UNTRACED`, blocking (the common case); a
  parked row and nothing else Running -> flags 0, blocking, and the
  kernel's ERR_CHILD-on-all-stopped is the `^Z` signal, decoded with
  SYS_PSTAT; a parked row AND a Running one -> `WJ_NOHANG` + SYS_PSTAT,
  polled -- the only shape with no blocking primitive that can see the
  stop, and it costs the foreground job its quanta. **The clean fix
  is a pid-filtered wait (waitpid) -- ~10 kernel bytes in the scan --
  deliberately NOT taken here because C was to add no kernel bytes
  (the MAUXEXTEST KNOWN_OVERRUN pin); it retires the poll mode and
  is the next kernel change worth making.**
- *A non-interactive sh passes the continue down.* `SYS_CONT` is
  parent-only and resumes one pid; `fg` of a `sh SCRIPT` job resumes
  the script sh and leaves ITS children stopped. A script sh has no
  job control (flags 0 always, never WUNTRACED -- it is inside the job
  its parent declared), so its resumed wait returns ERR_CHILD, PSTAT
  says the children are stopped, and it `SYS_CONT`s them itself
  before waiting again -- tier by tier, so the whole subtree resumes.
  A non-shell parent of a stopped subtree would not do this; that is
  B's parent-only CONT, unchanged.
- *ERR_INTR keeps `:waitloop`'s contract:* a trapping script sh woken
  by `^C` abandons the wait as before; the row stays Running and the
  next line's drain reaps the sweep's victims.
- *The drain is per line, the notices per prompt.* `JOB_DRAIN` runs
  at MAINLOOP before every line, interactive or not -- a poll,
  `WJ_NOHANG` and NEVER `WJ_UNTRACED` (the named invariant), skipped
  outright when no row is Running -- so a script's `&` children stop
  lingering as zombies holding banks; only the `[n]  Done   cmd` /
  `Terminated` printing is interactive. `wait` frees Done rows
  silently (`JOB_QUIET`), and marks Running rows Done on an
  unexpected ERR_CHILD rather than leave a row nothing completes.
- *Builtins.* `jobs` (fd 1), `fg`, `bg` in one dispatcher after
  `trap`; `fg`/`bg` refused `sh: no job control` when not
  interactive. `fg` declares the row's live members through
  FG_DECLARE's own CMD_PID walk, continues them (a refused CONT on an
  already-exited member is fine), prints the text, FG_WAIT. `bg`
  continues, marks Running, `[n]+ cmd &`, prompt. Job specs: none/
  `%+`/`%%` = current, `%-` = previous, `%n` or bare `n` (1-14);
  `%string` is not implemented. A stop or a `&` makes its row `%+`.
- *The `%spec` command shorthand (POSIX/csh), added after C landed.*
  A one-stage interactive line whose argv[0] begins with `%` is
  `fg %spec`; ended in `&` (`PARSE_SEPOP == SEP_BG`) it is `bg %spec`;
  a bare `%` is the current job. It is the LAST test in
  `CHCK_BLTN_JOB`, after the three names, and hands argv[0] to
  `JOB_SPECP` -- the parser under `JOB_SPEC`, which now takes the
  operand string in A/X (X = 0: no operand) so `fg`/`bg` (argv[1]) and
  the shorthand (argv[0]) share one parser -- then joins the fg or bg
  path at its row-in-X point, so `$?`, `%+`/`%-` and `sh: no such job`
  are exactly the builtins'. A script (`SH_INTERACT` = 0) and a
  pipeline stage (`NCMD` != 1) keep the command-not-found they had.
  sh.bin 20332 -> 20381 (+49; SH_BUDGET 20384 unchanged, 3 B of
  headroom). Gate: `check_jobctl_c.py` case `pct` -- `%1`, `%1 &`, `%`,
  `%9`; RED on de7ea88 (`%1` is command-not-found, the job stays
  parked), GREEN after.
- *`kill %n` and `wait %n`, added after the shorthand.* Settled with
  the operator as PER-COMMAND features, deliberately NOT a `%` word
  expansion -- only `kill` and `wait` take a job spec, `echo %1` stays
  literal (the csh/bash-faithful, worse-is-better form). `kill %n` is
  `KILL_SPECS`, called from the builtin chain right before
  RUN_PIPELINE: on an interactive one-stage line whose argv[0] is
  `kill`, each `%` operand's argv slot is replaced by the job's LIVE
  member pids as decimal text (U2DEC into the arena's `KS_BUF`), one
  slot each with the rest of argv shifted up, so `kill %1` signals
  every stage of a pipeline (maux has no process groups); then
  `/bin/kill` is spawned as usual and stays the one parser of
  `-signo`/pids and the one source of `kill:` diagnostics. Chosen
  over a `kill` builtin (the bash way) because the builtin would carry
  kill.s's digit parser and four message strings a second time -- the
  rewrite is ~170 B and drifts from nothing. A spec with no live
  member, a script, `/bin/kill %1` by path: `sh: no such job` /
  untouched / untouched. `wait %n` is `CHCK_BLTN_WT`'s operand path:
  the operand must start with `%` (JOB_SPECP alone would read a bare
  `n` as job n, the fg/bg convention, which is wrong for a verb whose
  POSIX operand is a pid -- `wait PID` stays refused with the usage
  line); it reaps through the same flags-0 SC_WAITJOB loop until that
  row is no longer Running, sets `$?` to the row's status (the tail's
  exit code or `$80|signo` -- what `fg` would have given) and frees the
  row silently; other jobs' Done notices wait for the prompt; a
  Stopped row returns at once. sh.bin 20381 -> 20672 (+291; SH_BUDGET
  20384 -> 20736). Gate: `check_jobctl_c.py` cases `kill` (`sleep 20 |
  sleep 20 &` then `kill %1` kills both stages, `kill -9 %1`, plain
  `kill PID`, `kill %9`) and `wait` (`echo %1` literal, `wait %1`
  blocks then returns `$?` = 0 with no notice, `wait %9`, `wait 5`
  refused); RED on 77376d1 (`kill: %1: bad pid`), GREEN after.
- *Costs.* sh.bin 18835 -> 20332 (+1497, SH_BUDGET 18864 -> 20384);
  arena +~600 B (30 KB of headroom remains). Kernel: none.
- *Gate:* `scripts/check_jobctl_c.py` (`check-jobctl-c`, in
  check-all-cross) at the real shell's prompt on play.po -- stop /
  fg / bg / amp / badspec, asserted on the glass, the annex PCB
  table and `VC_FGJOB`. RED on dc19977 (`^Z` reprompts with no
  notice; `jobs` is command-not-found), GREEN here.

**Increment D -- DEFERRED:** SIGTTIN/SIGTTOU tty arbitration (Stage 3
above). Not built; W4's redirect-or-diagnose answer covers v1.

## Increment E -- cooperative `^Z` (vi saves/restores its screen)

**The problem (asked 2026-09-08).** `^Z`-ing a full-screen program was
the documented-rough case: the stop sweep parks it directly and does
NOT fire `PRC_ALT_RST` (it still owns its alt-store), so the shell
reprompts *on top of* vi's frozen screen, and -- worse -- a second vi
started while the first is suspended collides on the single per-console
alt-store/owner (`VCA_ENTER` is a no-op while owned, `VCA_EXIT` acts on
anyone's `l` and orphans the suspended vi's claim). See the trace in the
session notes.

**The fix is NOT frame-forging async signals.** True async delivery
(the kernel forging a call frame on a process's per-bank ALTZP stack +
a sigreturn trampoline) is the biggest, most delicate kernel arc there
is, and SIGNALS.md sec 1 names its trigger as "a vi that must abort a
redraw MID-LOOP" (catching `^C` mid-paint) -- still unmet. `^Z` is a
DIFFERENT case: **vi is always blocked in a `read()` when you suspend
it** (waiting for a key), so it rides the EXISTING held-signal / fetch
model -- the same `SC_READ`->`ERR_INTR`->`SC_SIGPEND` path vi already uses
for `SIGINT`. No frame-forging.

**Mechanism (right-sized, period-faithful fetch pattern):**
- **`SIGTSTP` = signo 14** -- a maux number (POSIX's 18 is outside
  maux's 1-15 signo space). Purely a DISPOSITION: a process opts into
  cooperative stop with `SC_SIGNAL(14, CATCH)`. Named `TSTP` in
  shtrap.s for completeness; `kill -14` still just terminates (every
  signo's DFL is terminate -- the `^Z` sweep is the only stop path).
- **The `^Z` sweep (`PRC_STOP_SWP`) branches on TSTP disposition**,
  exactly as `PRC_INTR_SWP` (`^C`) branches on INT: CATCH -> deliver via
  `PRC_SIG_SND` (pending bit + wake the blocked reader -> `ERR_INTR`),
  do NOT stop it -- the process stops ITSELF after cleanup; DFL -> mark
  `PCB_STOPPED` directly + `PRC_TMD_RST` (today's behaviour, for a
  program that does not catch `^Z`); IGN -> skip (cannot be `^Z`-stopped).
- **`SYS_STOP` (syscall 20)** -- "park me until continued." `PRC_STOP`
  is `SCH_SLEEP`'s shape but sets `PCB_STOPPED` (WCHAN 0, not BLOCKED),
  and -- load-bearing -- **wakes the caller's PARENT** (`SCH_WAKEUP` on
  PCB_PARENT) so a `fg`-waiting shell's `SYS_WAITJOB(WUNTRACED)` sees
  the stop, then `SCH_SWITCH`es away requeue=0. On `SYS_CONT` (fg/bg)
  the process is RUNNABLE+`RUNQ_PUSH`ed and `SYS_STOP` RETURNS (no
  retry-rewind -- unlike `PRC_BLCK_RTRY`; a continue is not an
  interrupt).
- **vi (`VI_RAWKEY`/`VI_START`)**: install `SC_SIGNAL(14, CATCH)` at
  entry (alongside the existing SIGINT catch); on `read()`->`ERR_INTR`,
  `SC_SIGPEND` pops the signo -- if it is `TSTP`, `VI_SUSPEND`: emit
  `rmcup` (the `ESC[?1049l` it already sends on quit), `SC_STOP`, and on
  return emit `smcup` (`ESC[?1049h`) then fall into the normal
  abort-to-repaint (which redraws). `SIGINT` keeps today's behaviour.

**Why this fixes nesting too.** Each vi now `rmcup`s BEFORE it stops, so
the single per-console alt-store is never contended -- only the active
vi owns it. `^Z` vi#1 -> rmcup (shell screen back, owner cleared) +
stop; start vi#2 -> smcup (saves the shell screen fresh); quit vi#2 ->
rmcup; `fg` vi#1 -> `SYS_STOP` returns -> smcup + repaint. Exactly how a
real terminal behaves, because it's exactly what a real vi's SIGTSTP
handler does.

**Cost:** kernel is small (one `SYS_STOP` handler modelled on
`SCH_SLEEP`+parent-wake, one disposition branch in the shared sweep,
the signo constant + dispatch wiring); the real work is vi's
`VI_SUSPEND` + the `VI_RAWKEY` branch. No frame-forging, no new PCB
state (reuses `PCB_STOPPED`), reuses `SIG_TBL`/`PRC_SIG_SND`/
`SC_SIGPEND`/`SYS_CONT` wholesale.

**Still deferred:** frame-forging async (needed only to catch a signal
in a CPU-bound loop -- nothing needs it yet); a `^Z`'d program that is
NOT at a syscall boundary won't stop until it next hits one (fine -- an
interactive full-screen program is always in `read()`).

**Gate:** `scripts/check_jobctl_e.py` (`check-jobctl-e`; the design
called it `check_jobctl_d.py`) -- `^Z` vi restores the shell screen
(marker BACK, not vi's frozen glass) and parks it Stopped; `fg` redraws
vi's screen; the nesting sequence (`^Z` vi#1 / vi#2 / quit vi#2 / `fg`
vi#1) leaves the right screen at each step; a non-catcher (`cat`) still
direct-stops on `^Z` (DFL path unchanged). RED before (shell prompt
over vi's screen; nesting orphans the restore).

## Ledger

Landing any stage updates `docs/ANACHRONISMS.md` Pending sec Job control
(the `jobs`/`fg`/`bg` half moves from "stays here until someone asks" to
ruled/landed) and W4's background-output note (Stage 1/2 implements the
diagnose-unredirected-`&` answer). Cite `docs/SIGNALS.md` sec 1 (the
no-stop-action / async-handler deferral this design honours) in the
commit that adds `PCB_STOPPED`.

## ORPHAN-1 -- orphans go to init, at death (2026-10-22)

V7 `sys1.c` exit() and 4.2BSD `kern_exit.c` reparent a dying process's
children to init (pid 1) AT DEATH and wake init; 4.2BSD, whose stops are
job-control stops like maux's, also sends a STOPPED child "a hangup and a
continue". maux did neither: a dead parent's children kept its pid in
`PCB_PARENT`, so any process that later took the pid (pid == bank, and a
respawned console shell lands in the dead shell's slot) silently adopted
them, and a stopped orphan was reaped by `PRC_REAP_ORPH`. Now
(docs/ORPHAN-1-NOTES.md):

* `PRC_ADOPT` (process2.s) runs after every death event and gives
  `PCB_PARENT := 1` (annex and `K_PAR_SHD` together, `PPCB_WR_PAR`) to
  every process whose parent is a ZOMBIE. Callers: `PRC_EXIT`,
  `PRC_KILL` (kill(other) and kill(self)), `PRC_BRK_TRAP`, and ONCE at
  the end of a ^C sweep -- never inside the per-victim loop, because
  `PRC_FG_HAS` finds a victim's descendants by the parent chain and an
  early reparent would let a later descendant escape the ^C. An
  adoptee's own children keep it (the subtree is not flattened). A
  zombie adoptee wakes init.
* A STOPPED adoptee gets SIGHUP then SIGCONT through its own
  disposition: default HUP kills it (wait status `$81`) and the scan
  repeats for ITS children; ignored or caught leaves it alive and the
  CONT resumes it (a caught HUP is pending). `nohup` therefore keeps a
  parked job alive across its shell's death.
* Two-phase death: the adoption marks, reparents, signals and wakes
  only (tick/BRK context, no MLI); fd closes and the slot free stay in
  `PRC_REAP_ONE`, run by whoever waits for the process -- now init.
* `PRC_REAP_ORPH` is deleted. A dead pid 1 adopts nothing.
* init (src/test/playtestb.s) already reaps and ignores a pid that is
  not R_SH_PID; a test harness whose pid 1 waits once must loop
  (MAUXSHLANG does).
