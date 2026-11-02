# Teeth: how to prove a gate bites

Status: LIVE (HYG-4). The house rule is "prove the teeth of every gate":
sabotage the code, see the named rows go red, restore byte for byte.
Every `scripts/teeth_*.py` is a small spec on `scripts/teeth_lib.py`,
which does the editing, the building, the waiting, the judging and the
restoring. Design and audit: the HYG-4 work (not published).

## Run one

    python3 scripts/teeth_shnlvar.py            # every tooth
    python3 scripts/teeth_shnlvar.py T2 T4      # by name prefix
    python3 scripts/teeth_shnlvar.py --dry      # static lint, builds nothing
    python3 scripts/teeth_shnlvar.py --list     # the tooth names
    python3 scripts/teeth_shnlvar.py --observe T2   # what failed, no verdict

Exit status: 0 every tooth behaved as declared (and at least one ran);
1 a tooth did NOT bite (the product is the finding); 2 the runner or its
spec is broken (unknown selector, stale pattern, build or baseline
failure, a witness that did not move, a gate that did not finish, a
restore that is not byte-identical). Commit first is no longer required:
the runner restores from the bytes it captured, never `git checkout`.

`make check-teeth-lib` is the library's own self-test (in preflight,
under 2 s). `make check-teeth-patterns` runs `--dry` on every runner (in
the sweep, not in preflight): a refactor that moves code a tooth
sabotages must retarget the tooth before it lands.

## Write one

    import teeth_lib as T
    T.main('mything', [
        T.Tooth('T1 the retry is gone',
                edits=[T.Edit('src/bin/shsgrw.s', old, new)],
                checks=[T.Check('python3 scripts/check_mything.py R1 R2',
                                'devfs', T.Rows(red=['R1', 'R2'],
                                                controls=['R5']))])],
           prep=T.Make('play-image'), artifacts=['build/sh.bin'])

- `Edit(file, old, new, count=1, regex=False, comment_ok=None)`: `old`
  must occur exactly `count` times, and its span must hold code, not
  only a comment (`comment_ok='why'` is the justified escape).
- `Check(cmd, reporter, expect)`: one gate command, the reporter that
  reads its output, and what RED means:
  `Rows(red, controls, rule=ALL|ANY)` (named rows go red, controls
  stay green), `FailureMarker(m)` (ascore), or `Aggregate(pred, why)` (a
  gate that prints no rows: an anchored `^` regex its output must match).
- RED always needs the gate's own terminal verdict line saying FAIL, an
  exit status that agrees, and the assertion. `make` status alone, a
  Traceback, a timeout, a signal or a missing prerequisite is an ERROR
  (exit 2), never a red.
- A control must be observable (the reporter prints PASS rows); the lint
  rejects a control on a gate that cannot show it ran.
- The change witness defaults to "the artifacts differ from the good
  build" (`Changed(paths, quant=ANY|ALL)`); `Unchanged` for a static
  tooth, `SourceOnly` for a Python-tool edit, `Intrinsic(why)` for a gate
  self-test, `CommandMutation(why)` for a mutation the command makes.
- `GREEN_EQUIVALENT` is a mutant a second defence covers (green, but the
  witness changed). `GREEN_PROOF` is a "stays green" claim: every green
  check needs a matching RED check in its `pair` tooth.
- Reporters: `devfs`, `tagged`, `bullets_only`, `namerows`, `sleep`,
  `wait`, `recorder`, `ascore`, `jobctl`, `fdact`, `demo`, `assertion`,
  `aggregate` (see `REPORTERS` in the library and its `FIXTURES`: a real
  excerpt of each gate's output). A new gate shape is a new reporter plus
  a fixture in the self-test, not a substring search in a runner.

## The traps the library closes

Each of these once made a teeth run pass while testing nothing:
a build failure skipped without a result; declared controls never run;
an unknown selector or an empty run exiting 0; a tooth counted red on
ANY gate failure; a restore by `git checkout` destroying an uncommitted
edit; a same-second rebuild leaving the sabotaged binary staged (GNU make
3.81 compares whole seconds: the library waits and deletes the artifact);
a stale pattern after a refactor; a gate that died early counted as red.
