# Recovered upstream filetype references

Not maux's own notes (those are `docs/ftn/FTN.*.MAUX.md`) -- upstream
material recovered so that type decisions are made against data rather
than against impressions.

## ProDOS.File.Types.v2.0.txt

Jon Relay, 1999, from
`https://www.apple.asimov.net/documentation/os/prodos/ProDOS.File.Types.v2.0.txt`.
247 rows, 109 types, **with registered auxiliary subtypes** and a DOS 3.3
equivalence column.

**Use this, not the web rendering.** `kreativekorp.com/miscpages/a2info/
filetypes.shtml` is the same author's data rendered for the web and it is
lossy: it drops `$2E`'s auxiliary rows entirely (so Davex's registered
`$2E`/`$8001` is invisible) and it mislabels `$B5 EXE` as "Apple IIgs Shell
*Script*" where this text says "Apple IIGS Shell" and GS/OS Reference
Vol. 1 says "GS/OS **Shell application** file". Both errors are material to
choosing a type; both were hit in one session, 2026-08-30.

## What this is NOT

A **compilation**, not Apple's per-type File Type Note documents. The FTN
series carries each type's FORMAT specification; this carries only
type/aux/name. Enough to choose a type; not enough to write a format note
against somebody else's. Only four ProDOS 8 FTNs are mirrored at
`prodos8.com/docs/technote/ftn/` (`08`, `19`, `1a`, `1b`) -- the GS/OS-range
notes 404 there and remain unrecovered.

Deposited as `learning:01M18Z7280MJX814T726SRQGPM`.
