# What a gate waits for, and when waiting is a lie

Status: LIVE, 2026-09-21, written at `52a54cf`+ after the Tier D audit of gate waits. Companion to
[VERIFICATION.md](VERIFICATION.md), which says what each gate covers; this
says whether its *waiting* is sound.

## The failure this is about

2026-09-20, `check-play80`: the gate stepped the machine until row 0 began
with `$`, then asserted the hardware cursor's address and its visibility.
The predicate held one poll before those were true. Measured at the firing
poll: `cursor_addr` 0, `cursor_on` False; one poll later, correct.

The gate had been green for weeks. It went red on 25 bytes of unrelated
kernel growth, because the growth moved the boot by one poll -- and a
session then went into code bisection and concluded "latent N8 IL alignment
bug". There was no such bug. Any gate with this shape can be green for the
wrong reason indefinitely, and its eventual red names the wrong thing.

## The rule

**Wait on a barrier the machine itself raises, not on a symptom you
recognise.**

A *handshake* predicate is a value the guest writes, at a point in its own
code, AFTER everything the gate is about to assert. `PT_READY` in
`src/test/playtestb.s` is one: the boot writes `$55` only once
`TTY_VT_SUITE` has returned. `check_iobuf`'s `$AA` is another, and its
generated probe stores every result cell before the state byte, in that
order, on purpose. A handshake cannot fire early, because the guest is the
thing that fires it.

A *symptom* predicate is the harness recognising a shape on the glass --
a prompt, a word, a row that looks finished. It is a guess about progress
made from outside, and it is sound only when the thing being asserted IS
the symptom. The moment a symptom stands in for readiness and something
else gets asserted, the gate has a race whose period is however long the
guest takes to get from the symptom to the state.

When a symptom is the only thing available, require it on **two
consecutive polls**. `check_vi.settle()` has always done this ("avoids a
mid-repaint tear") and is the house helper; a mid-repaint screen satisfies
a predicate once and not twice. That is a mitigation, not a proof: it
narrows the window rather than closing it, which is why a handshake is
preferred wherever the guest can be made to raise one.

## The audit, 2026-09-21

Forty wait/settle helpers across the gate scripts do not require two
consecutive polls. That number is not the finding -- most of them are
sound, and converting them wholesale would be churn that hides the real
cases. The shape that matters is **symptom predicate, then an assertion on
different state**, and the sweep for it was mechanical: every call to a
wait/settle helper followed within five lines by a `peek`, a `sym_addr`, a
`live_pids` or a tick read.

Ten sites matched. Each was read, and none is unsound:

| site | predicate | why it holds |
| --- | --- | --- |
| `check_iobuf` 508, 525 | guest state byte `$66` / `$AA` | handshake, and the generated probe stores every result cell BEFORE the state byte |
| `check_jobctl_b` 213 | `JC READY` on screen | the program printed it, so it exists; the assertion is only that it exists |
| `check_jobctl_b` 314 | `JC EXIT`, then the prompt back | the prompt implies the shell reaped it -- the screen text alone would not |
| `check_jobctl_a` 281 | `^C` visible AND at the prompt | same: the prompt is the barrier, not the `^C` |
| `check_jobctl_c` 317, 339, 412 | at the prompt AND the job notice | both halves, and the notice is the shell's own reap record |
| `check_shutdown` 190 | the prompt | asserts `K_HALT_TMR`, which `TIMER_PROBE` set at boot, long before |

`check-play` was measured rather than reasoned about, because it is the
largest gate and uses the same shape the failure had -- a wait on one thing
followed by assertions on another. Its `PT_READY` handshake fired at poll
5; all fifteen `VT_CASES` cell groups were sampled at that poll and again
at +1, +2, +5 and +20, and **none changed**. The predicate implies the
assertion.

## What this does not cover, and what to do about it

The audit covers gates whose assertion is *adjacent* to the wait. A gate
that waits, types, waits, and asserts twenty lines later is outside the
sweep. The rule is the durable part, not the table.

The honest conclusion is that this tree got one bad predicate and not a
class of them, and the reason is that most gates were already written
against handshakes. **When adding a gate: if you find yourself recognising
a shape on the screen in order to know the machine is ready, ask whether
the guest can raise a barrier instead.** In a test harness you control
both sides, so usually it can.

## Waiting for a background fixture (GATE-RACE-1, 2026-10-21)

A gate that starts a guest background job or timer and then acts on it is
calibrated to ONE guest speed unless it waits for a PROPERTY of the
fixture. Two incidents, one class, opposite directions:

* **WAKE-1, the guest got faster.** check-vi-alt `killed_bg` armed
  `( sleep 2 ; chvt 2 ; kill N ) &` and then waited to see vi repaint.
  A cheaper tty wake started the guest's `sleep` sooner, the `chvt`
  fired before the harness looked, and a correct kernel read the wrong
  console (`learning:01M5DVRZGJ865JR719VGE24XND`).
* **TAB-A3, the guest got slower.** check-shutdown started `sh HS > HF &`
  and typed `shutdown` as soon as the prompt came back. sh grew 1.9 KB,
  the writer took longer to load, `shutdown` overtook it, and the file
  was empty at the halt for the honest reason that nothing had been
  written. The first fix polled `ps` for the writer's `sleep` -- which
  was vacuous: `ps` prints no command name, and the words it matched
  were still on the glass from the echoed setup line.

The rule: **wait for the fixture's state, never for a duration.**

* **Fixture not ready (class B).** Wait until the fixture has said so.
  For a process the KERNEL blocks (a pipe, a tty read, `wait`), peek the
  PCB or the wait shadow. For anything else -- and userland `sleep`
  POLLS SYS_TICK, so it is RUNNABLE with no wait channel and the PCB has
  no command name -- have the fixture print a readiness marker the
  glass could not already show (check-shutdown's `HSUP$$`: the setup
  line echoes `HSUP$$`, the script prints `HSUP12`).
* **Timer fires too soon (class A).** Poll for the timer's side effect
  inside every settle that comes before it and fail AT ONCE with the
  cause (`not_yet_console2`, `vi_not_yet_dead`). Checking at failure
  time does not work: by then the killer has run to the end. Where the
  harness could deliver the event itself once it sees the state, do
  that and drop the timer.
* **Overlap is the test.** Some gates exist to land an event DURING a
  state (a TERM at a raw read with a line typed, a kill mid-CSI, a BRK
  while vi owns raw tty state, an `umount` while a job holds a file
  open). Do not remove the overlap; ASSERT it. The killer's subshell is
  a live PCB until its last `kill` has been delivered, so "not fired
  yet" and "fired, and the fixture was still running" are both
  readable (`killer_pending`, `await_killer`, `job_alive`,
  `arm_killer`). Without that a speed change makes the gate pass
  VACUOUSLY: the TERM lands at an idle prompt, every assertion holds,
  and the overlap the gate exists for is gone.

A timer that the harness races is a margin you engineer
(`learning:01M2M1GPJ9ZAXJ5SP7NYP26YDJ`), so every such timer carries its
arithmetic in a comment (typing cost in 50k-cycle keys, settle polls,
the guest's ~1.4M start-up, plus the 3M `late` lag) and the guard that
reports a violation.

### Perturbing the harness: MAUX_GATE_RACE

`scripts/gate_race.py`. Not a sweep setting -- the sweeps run with it
unset. It is the tool to run BEFORE a stream that changes guest speed,
and the check that a new gate was written to the rule.

    MAUX_GATE_RACE=late    after every typed line that arms a background
                           fixture (a lone `&`), step 3M extra guest
                           cycles: the harness LOOKS late (class A red)
    MAUX_GATE_RACE=early   no lag; every prompt/property poll steps 1/10
                           of its quantum and gets 10x the iterations
                           (same total timeout): the harness ACTS as soon
                           as it can (class B red)

    MAUX_GATE_LAG=<cycles>   override the 3M (bisect a site's slack)
    MAUX_GATE_SITE=<n>       lag only the n-th arming line of the run
    MAUX_GATE_TRACE=1        list the arming lines at exit (with late)

The key drain (`V.t`, `Clock.typ`, `Term.press`) and fixed-length waits
are deliberately NOT scaled -- shrinking the drain loses keystrokes,
which is a third kind of red. A new poll loop uses `GR.polls(c, n)` (or
`GR.count` / `GR.quantum` / `GR.poll_step` when it checks before it
steps) so the knob reaches it; the exit summary prints how many fine
polls ran, and zero means a loop was missed.

A gate converted to the rule is expected to pass with the variable unset,
under `early`, and under `late`:

    MAUX_GATE_RACE=late python3 scripts/check_vi_alt.py
