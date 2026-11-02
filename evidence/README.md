# Retained gate evidence

Status: LIVE, 2026-09-19. This directory exists because
[docs/VERIFICATION.md](../docs/VERIFICATION.md) asked a candidate to preserve
its sweep summary, per-target logs and failure dispositions, and the only copy
of the last full canonical sweep was sitting in `/tmp` on one laptop -- one
reboot from gone, while the document that cited it stayed in the repository.
`build/` is no better: it is ignored, and `make clean` on this tree is itself
a documented hazard.

What belongs here: the OUTER SUMMARY of a sweep worth citing, the logs of its
FAILURES, and a README saying what each failure was and what was decided.
What does not: 100 passing per-target logs (1.1 MB per sweep, nobody reads
them), generated images, or measurement JSON whose numbers already live in a
document. Keep a directory per (revision, date) so a citation can name one.

A log here is a record of what a run PRINTED, not a claim that its conclusion
still holds. Each archived run's README says which findings have since been
closed, and by what.

## What is here

| revision, date | run | outcome |
| --- | --- | --- |
| `828309c`, 2026-09-18 | `make check-all`, serial, pre-candidate | 99 of 104. All five reds triaged 2026-09-19/20: three were the undone Merlin-8 retirement, one a stale divergence-ledger entry, one a real `ls -R` defect. None open. |
| `983ae9c`, 2026-09-20 | `make check-all-cross-par J=4` at `983ae9c` | 102 of 104. `check-idle` was its own sample budget and is fixed; `check-jobctl-a` was a kernel defect, since CLOSED -- see the next row. |
| `703ad36`, 2026-09-21 | the gate suite after the POSIX close-out | **Mac 111/111, box 106/106.** `check-posixutil` 565/565 with 23 gaps, from 40. Two gaps closed by correcting a wrong REASON, not code; `xargs -E` exposed a latent bank-reuse bug; five source-window splits across four units. |
| [candidate-52a54cf-2026-09-21](candidate-52a54cf-2026-09-21/README.md) | the four automated release gates at `52a54cf` | **All green, first time together.** Mac 110/110, box 105/105, `check-nas-selfmake` 85+1 byte-identical, `check-release-image` deterministic. The clean-checkout second-host reproduction is still owed. |
| `299d0ae`, 2026-09-20 | `make check-all-cross-par J=4` at `299d0ae` | **106 of 106.** The first complete green. The `KRN_BRK_TRAP` halt was a language-card write-enable held across a preemptible copy; `docs/LANGUAGE-CARD.md` has the mechanism. Two new gates (`check-lc`, `check-lc-prodos`) are in the 106. |
| [plascut-485672f5-2026-10-23](plascut-485672f5-2026-10-23/README.md) | `make check-plascut` at `485672f5` | PASS. PC4: warm nas on a 34-byte fixture, cooked 1,650,000 vs modular 5,950,000 cycles. The site quotes it. |
| [conformance-f9a0e021-2026-10-24](conformance-f9a0e021-2026-10-24/README.md) | the POSIX conformance gates (`check-posixutil`, `-posixsed`, `-fowler`, `-posixvi`, `-posixex`) and `check-e2e` | ALL PASS. Utilities 837/837 with 14 named gaps, sed 137/137, regex corpora 109/109, vi 72/72, ex 92/92, e2e 327 cases with 2 pinned shell defects. The site's Conformance page quotes it. |
