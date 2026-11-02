# 0.1.0 candidate evidence -- `52a54cf`, 2026-09-21

The first revision at which all four automated release gates are green
together. Retained per [docs/VERIFICATION.md](../../docs/VERIFICATION.md) and
the rule in [evidence/README.md](../README.md): the outer summary of a sweep
worth citing, plus the logs of anything that failed.

Nothing here failed, so these are four summaries and no failure logs.

| log | command | result |
| --- | --- | --- |
| [mac-check-all-cross-par.log](mac-check-all-cross-par.log) | `make check-all-cross-par J=4` on the Mac | **110 PASS, 0 FAIL**, 397 s |
| [box-check-all-box-par.log](box-check-all-box-par.log) | `sh scripts/box_gate.sh` (Linux box) | **105 PASS, 0 FAIL**, 307 s |
| [check-nas-selfmake.log](check-nas-selfmake.log) | `make check-nas-selfmake` | **PASS** -- 85 of 85 staged utils and 1 of 1 kernel image byte-identical, second make run empty |
| [check-release-image.log](check-release-image.log) | `make check-release-image` | **PASS** -- 4,194,304 B, two builds byte-identical, `fdb295d2...` |

## What this evidence does and does not establish

It establishes the first two lines of `PROJECT-STATE.md`'s releasable-milestone
definition -- a clean canonical sweep and a clean `check-nas-selfmake` at one
commit -- plus image determinism, which is a release-tooling property rather
than a milestone criterion.

It does **not** establish the third line. The box runs gates from an `rsync`
of this working tree, which is a second HOST but not a clean CHECKOUT from
pinned dependencies. That reproduction is still owed, and it has to be the
last thing done: a fix after it starts a new candidate.

Two facts worth carrying forward, because both were surprises:

- The kernel the native pass rebuilds byte-identically is **29,509 B**, i.e.
  it covers the same-day `/BASIC/ETC/RC` work. The native world pass is not
  lagging the tree.
- The box's `check-man-image` failed on the run before this one for a reason
  that was **not in the tree**: its cached `build/man/*.TXT` predated its own
  `mandoc` and the gate re-renders and compares bytes. `build/` is deliberately
  not synced, so a stale box artifact can outlive the change that made it.
  Cleared by deleting `build/man/*.TXT`; the gate passes there now.
