# maux File Type Note

    File Type:        $06 (6)
    Auxiliary Type:   load address
    Full Name:        Binary file (maux interim executable use)
    Short Name:       BIN

    Written by:       the maux project, August 2026
    Status:           INTERIM CONVENTION, not a claim. $06 BIN is
                      Apple's, defined by the ProDOS TRM; this note
                      documents how maux uses it until the loader's
                      type check ships and executables migrate to
                      $2E/$C073 (FTN.2E.C073.MAUX.md). Was $B5
                      until 2026-08-30; see that note for why it
                      was withdrawn.

## The convention

maux executables are currently type `$06` with auxiliary type
`$0800`, the load address, honoured by the loader -- the
BASIC.SYSTEM `BLOAD`/`BRUN` convention.

## Why this is interim

BIN's semantics belong to BASIC.SYSTEM: BRUNnable if it carries a
load address, a data blob if it doesn't. A maux executable is
neither -- it is not BRUNnable by BASIC.SYSTEM (it would crash into
maux syscall stubs that are not present), and a loader honouring
BIN + aux will happily treat any genuine BASIC.SYSTEM utility as
one of its own. The type check that fixes both is the migration to
`$2E`/`$C073`.

## Precedent

KIX -- Glen Bredon's Unix-like ProDOS shell, shipped on the Merlin
disk -- made the identical call: every KIX command in its `BIN/`
directory is `$06` with aux `$0800` (measured off VALIDATE.PO,
2026-08-30). Bredon eschewed the type registry generally; Merlin
itself restricts DSK output to types `0, 6, $F0-$F7, $FF`.

## When the interim ends

**Trigger, set 2026-08-30: the type check ships with shebang
dispatch, not before.** It is ugly to let a BASIC-era BIN be loaded
and entered, and it is a real crash -- but the loader has to read the
head of the file to recognise `#!` anyway, so the type check is a few
instructions on the same pass. Doing it separately means opening
`procspawn3.s` twice for one dispatch.

So this is an accepted gap with a named trigger, not an oversight.
