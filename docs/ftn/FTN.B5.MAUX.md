# maux File Type Note

    File Type:        $B5 (181)
    Auxiliary Type:   load address (see below)
    Full Name:        maux executable
    Short Name:       EXE

    Written by:       the maux project, August 2026
    Status:           SUPERSEDED 2026-08-30 by FTN.2E.C073.MAUX.md.
                      Withdrawn as a claim; retained because it was
                      published as one and because its reasoning is
                      worth keeping legible.

## Why this was withdrawn

`$B5` is a **65816 type**. The comprehensive filetype table
(`docs/ftn/refs/ProDOS.File.Types.v2.0.txt`) shows every entry in the
`$Bx` block reading "Apple IIGS ...", and `$B5 EXE` is "Apple IIGS
Shell" with no auxiliary subtypes at all. GS/OS Reference Vol. 1
confirms: "GS/OS Shell application file", and *"for both $B3 and $B5
files, standard input, output, and error..."*.

GNO/ME belongs there because GNO is 65816 code on GS/OS. maux is
65C02 code on ProDOS 8, so a raw 8-bit memory image under `$B5`
squats a namespace belonging to another architecture -- which is why
this note needed the awkward disambiguation heuristic below ("OMF
begins with a segment header; a maux image begins with live 65C02
code") that a correctly-chosen type does not need.

`$2E P8C` -- "ProDOS 8 Code Module" -- says what maux executables
actually are, is already the shared home for 8-bit loadable code
(Davex `$8001`, Point-To-Point `$8002`/`$8003`), and is inert to
every non-maux launcher. See FTN.2E.C073.MAUX.md.

**The original note follows, unaltered.**

---

    Status (original):
                      CLAIM -- published per the post-registry
                      convention: Apple's filetype registry is no
                      longer maintained, so projects document the
                      types they camp on and publish the note.

## Background

`$B5` is the registered "Shell Application" (EXE) type from Apple's
filetype registry, defined originally for Apple IIGS shell
environments (APW, ORCA). GNO/ME -- the Unix-like for the IIGS --
shipped its executables as `$B5` and documented the stance maux
adopts: **the filetype is the execute bit.** "Can this be run?" is
answered by the type field, not a permission flag (GNO's own manual:
use `chtyp`, not `chmod +x`).

maux extends the same type to 8-bit ProDOS volumes: a `$B5` file on
a maux system is an executable for the maux execution environment.

## File format

A raw 65C02 memory image, loaded whole at the address given by the
auxiliary type and entered at its first byte. No header, no
relocation records: the image is position-dependent, and rebasing is
performed by relinking (maux binaries are linked from REL modules --
see FTN.F8.MERLIN.md).

## Auxiliary type

The 16-bit load address, honoured by the loader -- the BASIC.SYSTEM
`BLOAD`/`BRUN` convention generalized. maux's conventional base is
`$0800`; the loader refuses addresses below its floor (the low pages
hold the stack, the syscall copy window, and -- while the interim
argv layout stands -- the process startup frame).

## Distinguishing maux EXE from IIGS shell applications

By host filesystem context and capability: an 8-bit maux volume does
not carry OMF, and a GS/OS shell does not expect raw memory images.
Within a maux system the type means exactly one thing. Cross-mounted
archaeology should check the first bytes: OMF begins with a segment
header; a maux image begins with live 65C02 code.

## Interim note

Until the loader's type check ships, maux executables are type `$06`
BIN with the same auxiliary-type convention -- see FTN.06.MAUX.md for
that interim and its period precedent (KIX shipped the same way).
