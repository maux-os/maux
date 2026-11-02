# Conformance runs at f9a0e021 (2026-10-24)

Six gates run on the Mac (verilogapple fast backend) from a clean tree at
f9a0e021 (branch site-posix, nothing modified), each a fresh `make` of the
target against a freshly built play image. The logs here are each gate's
own output, unedited. Every gate exited 0.

| log | command | reference |
| --- | --- | --- |
| check-posixutil.log | `make check-posixutil` | the host's own utilities (macOS BSD tools); the POSIX text where the hosts disagree |
| check-posixsed.log | `make check-posixsed` | the host's sed (macOS BSD sed) |
| check-fowler.log | `make check-fowler` | the AT&T (Fowler) and Spencer regular-expression test files |
| check-posixvi.log | `make check-posixvi` | macOS /usr/bin/vi (Vim 9.1 in vi mode) |
| check-posixex.log | `make check-posixex` | macOS /usr/bin/ex (Vim 9.1 in ex mode) |
| check-e2e.log | `make check-e2e` | the host's own utilities, and macOS /bin/sh for shell constructs |

The site's Conformance page reads its numbers from these logs through
site/facts.py (the `cf_*` facts); `check-site` holds the page to them.

A caveat that belongs with the numbers: a gate that passes with named gaps
(check-posixutil, check-e2e) passes because every other case matched AND
every named gap still differs. The gap lists are printed in the logs and
the page prints them in full.
