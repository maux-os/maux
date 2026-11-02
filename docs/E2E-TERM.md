# Person-like end-to-end tests for the terminal and vi

**Why this exists.** The `check_vi` / `check_jobctl_*` gates drive the
emulator the way no human does: `type` a whole string into the keyboard
latch in one burst, then `step` a big fixed cycle slice, then read the
glass. Two consequences, both of which shipped real false results this
project acted on:

- **Bursting + fixed stepping serialises the pipeline** (all keys land
  before the CPU runs any) and steps deterministically, so it hides the
  real-time interleavings of input -> cook -> echo -> scheduler -> render.
- It can **register a key the guest never echoed** (the `type` tool puts
  the byte in the latch; a stopped-echo terminal still shows a command's
  *output* but not the typed command), so a dead-echo terminal reads as
  working.

A `^Z` that left the shell with no echo (fixed in the `VI_SUSPEND`
cooked+echo restore) sailed through the burst gates, because they never
typed at the shell after the `^Z` and asserted the echo. That is the gap
this suite closes.

**The methodology (`scripts/e2e_term.py`, class `Term`).** Operate the
machine like a person:

1. **One key at a time.** `press()` injects a single key, then lets the
   guest FREE-RUN a realistic, JITTERED slice (~40k-160k CPU cycles ~
   50-200 ms) so it fully consumes and echoes that key -- and so the
   NEXT key lands at a varying point in the CPU's work, sampling
   timing-dependent behaviour. `type_human()` presses each character
   separately; never a burst.
2. **Wait for the glass, not a step count.** `wait()` polls what is
   actually rendered until the expected text appears; `wait_prompt()`
   waits for a SETTLED `$` prompt (stable across two polls) before
   typing a shell command -- a person waits to see the prompt, and
   typing into mid-output races the echo against that output. (Both a
   false FAIL, from typing too early, and a false PASS, from bursting,
   come from getting this wrong -- so the harness must model the human
   pause honestly.)
3. **Assert what a person sees.** Especially echo: `type_and_expect_echo`
   requires the typed text to become visible; the `type` tool does not
   fake echo, so a row holding the typed text is a true cooked+echo
   oracle. Realistic speed matters too: superhuman typing (a few k
   cycles/key) overruns the latch and drops keys -- that is a harness
   artifact, not a maux bug, so keep to human cadence.

**Backends.** Every case runs on `text40` (40-col), `text80`
(native-80, via `vidmode 80`) and `ut` (the UltraTerm card, read through
`ultraterm_state` since `run_until`'s text match cannot see it).

**Cases (`scripts/e2e_vi_term.py`).** `shell_echo`, `vi_insert`,
`suspend_echo` (the ^Z-then-type-at-the-shell echo check the old harness
lacked), `nesting_edit` (vi, ^Z, second vi, edit, ^Z -- the nesting the
operator hit), `shellout` (`:!cmd`), and `wedge_hunt` (nested ^Z + 80
rapid i/ESC toggles at realistic speed, then a fresh-line responsiveness
check -- the reported "wedge", which under a correct person-like test
does NOT reproduce: vi stays responsive).

**Running.** `python3 scripts/e2e_vi_term.py [text40|text80|ut|all]
[case] [seed]`, or on the box, off-laptop:
`sh scripts/box_gate.sh check-e2e-term`. It IS in the sweep
(`check-all-box`): on the box, where sweeps run, all three backends
finish in ~36 s. A LOCAL `check-all-cross` that includes it is slower
(person-scale timing), but local full sweeps are discouraged anyway --
run sweeps on the box.

## Recording a live session and replaying it

The surest person-authored test is a real one. `make play-rec` runs the
SDL machine exactly like `make play` but with `VERILOGAPPLE_KEYLOG` set,
logging every key you press -- with the CPU cycle at that moment -- to
`build/session.klog`. Reproduce a bug live, quit, then:

    python3 scripts/e2e_vi_term.py replay build/session.klog [backend]

replays your exact keystrokes AND timing headless: a deterministic
re-run of your real session. Save the `.klog` as a fixture and it is a
person-authored regression case -- no guessing keystrokes.

The keylog is `<cycle> <hexbyte>` per line (the raw Apple keycodes the
keyboard latch saw). Replay (`e2e_term.Term.replay`) steps each recorded
inter-key cycle gap, then injects the byte -- a long idle gap is capped
so a coffee break does not stall the test. RECORDING is a `fast_sdl`
feature (verilogapple `fast_sdl.cpp`, the `bus.key()` hook); REPLAY needs
no emulator change, because the headless `type`/`step` path injects the
same way `bus.key()` does.

**What it found.** All cases pass on all three backends post-`66fb48a`
(the `VI_SUSPEND` echo fix): the terminal and vi, including nested `^Z`
with rapid mode-switching, work correctly. Several "bugs" chased during
its development turned out to be flaws in earlier, non-person-like
harnesses (typing before the prompt, superhuman typing overrunning the
latch, asserting a marker on an already-full line) -- which is the whole
argument for this suite: a person-accurate oracle catches real bugs and
does not manufacture false ones.
