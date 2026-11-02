# maux File Type Note

    File Type:        $2E (46)
    Auxiliary Type:   $C073
    Full Name:        maux executable
    Short Name:       P8C

    Written by:       the maux project, 2026-08-30
    Status:           CLAIM -- published per the post-registry
                      convention: Apple's filetype registry is no
                      longer maintained, so projects document the
                      types they camp on and publish the note.
    Supersedes:       FTN.B5.MAUX.md

## Why $2E

`$2E` is the registered **P8C -- "ProDOS 8 Code Module"**, and it is a
*live, shared, subtyped namespace* rather than an empty slot:

    2E P8C             ProDOS 8 Code Module
    2E P8C   8001      Davex 8 Command
    2E PTP   8002      Point-To-Point Driver
    2E PTP   8003      Point-To-Point Code

Four things follow, and each was a requirement argued separately
before the type was chosen:

1. **It means what we mean.** A maux executable is ProDOS 8 code.
   `$06 BIN` is DOS 3.3's `B` and means "BLOAD me at my aux address,
   BRUN me" -- so a loader honouring BIN will accept any BASIC-era
   utility as one of its own, and BASIC.SYSTEM will BRUN a maux
   binary into a crash. That hazard is BIN's inherited meaning, not
   an accident of it.

2. **The aux subtype disambiguates BETWEEN SYSTEMS, not just within
   ours.** One volume can carry Davex commands, Point-To-Point
   drivers and maux executables; each loader recognises its own and
   politely refuses the others. A private type byte cannot do this;
   a shared registered one does it for free.

3. **It is inert to every non-maux launcher.** ProDOS launches only
   `$FF`; BASIC.SYSTEM `BRUN`s `$06`, `RUN`s `$FC`/`$FA`, `EXEC`s
   `$04`. Nothing reaches for `$2E`.

4. **It is not a squat.** `$2E` is registered and it is being used
   for what it says. Contrast `$F1-$F8`, the "ProDOS user defined"
   range, which is for *locally* redefinable meanings -- a format
   that ships to thousands of people needs a global one. Merlin's
   REL sits at `$F8` for want of anywhere better (`$FE REL`, DOS
   3.3's `R`, was already spent on EDASM), and the cost is exactly
   what a user-range squat predicts: catalogs abbreviate `$F8` as
   LNK while the community table lists it as PRG, and neither is
   wrong.

And it reads as **IIe**.

## Why $C073

`$C073` is the RamWorks bank-select register -- the single write that
IS a maux context switch (`docs/ARCHITECTURE.md`: "each 64K aux bank
IS a process ... Context switch ~ one write to $C073"). The whole
architecture in four hex digits, under a type that spells the
machine.

It is also correct by convention and free by measurement. The high
bit is set, which is how third-party aux subtypes are distinguished
from Apple-assigned ones throughout the registry (`$E0 LBR`: Apple's
`$0000-$0003` for AppleSingle/AppleDouble, third-party `$8000-$8002`
for Binary II / AppleLink ACU / ShrinkIt). And across all 109 types
in the comprehensive table, the only `$Cxxx` auxiliary values in use
are one vendor block at `$C000-$C006` -- see
`docs/ftn/refs/ProDOS.File.Types.v2.0.txt` and
`learning:01M18Z7280MJX814T726SRQGPM`.

## File format

**STATUS: PROPOSED. The type claim above is settled; this section is
not yet implemented and the loader does not yet read it.**

A 16-byte header followed by a raw 65C02 memory image.

    +$00  1  $60        RTS. The file BEGINS WITH CODE so that a
                        stray entry is defined behaviour, not a
                        crash: an accidental CALL or BRUN returns.
    +$01  2  $6D $78    signature, "mx" in 7-bit ASCII
    +$03  1  version    maux binary layout version
    +$04  1  minkern    minimum maux kernel version
    +$05  1  cpu        $61 = 6502 level 1 (65C02)
    +$06  1  hwreq      hardware requirement bitmap
    +$07  2  loadaddr   address the image wants
    +$09  2  entry      entry point
    +$0B  2  descr      -> ASCII description, or $0000
    +$0D  3  reserved   zero
             = 16 bytes

### Why the identity is in the FILE and not only in the metadata

Because the two shipped ProDOS 8 Unix-alikes both put it there, and
because the header can answer questions no type byte can -- *"is this
the right CPU?"*, *"is this binary older than this kernel?"*

* **Davex** (Lyons, 1988) -- `$2E`/`$8001`, header measured off
  `src/xtn/2/what.asm`: `rts`, `$EE $EE`, own version, minimum Davex
  version, hardware-requirement bitmap, `.addr` description, load
  address, entry address, four reserved bytes. Sixteen bytes.
  (Davex's own SourceForge page says *three* reserved bytes; the
  source says four. Measured, not read.)
* **A2osX** (contemporary, multitasking, ProDOS 8) -- keeps its
  executables at plain `$06 BIN` and puts everything in a 16-byte
  header: `cld / jmp (.1,x)`, a CPU/level byte (`$61` = 65C02), a
  layout version, process flags, and declared CS/DS/SS/ZP sizes. Its
  kernel checks the header's own type and version fields before
  relocating (`SYS/KERNEL.S.BIN.txt`, `BIN.RelExe`).

Two independent designs, both 16 bytes, both beginning with
executable code. maux takes the union of what they each got right:
Davex's leading `RTS` and hardware bitmap, A2osX's CPU byte --
**deliberately reusing A2osX's `$61` encoding, so the same byte means
the same thing on both systems** -- and a load address in the file so
a binary survives transport that drops `aux_type`.

## Interim

Until the loader's type check ships, maux executables remain type
`$06` BIN with `aux_type` as the load address -- see FTN.06.MAUX.md
for that interim and its period precedent (KIX shipped the same way,
and Davex still accepts BIN "for compatibility with old versions").

## Related types, noted for the future, NOT claimed

`$2E` is the executable end of a registered ProDOS 8 toolchain
family. The rest is recorded because it is genuinely useful to know
it exists -- not as work queued up. The executable type is the one
that had to be settled; nothing else here is urgent:

    2A 8SC   Source Code
    2B 8OB   Object Code          ($8001 = GBBS Pro)
    2C 8IC   Interpreted Code     ($8003 = APEX Program File)
    2D 8LD   Language Data
    2E P8C   ProDOS 8 Code Module  <- claimed above

**`$2B 8OB` is where maux objects should go IF `as` ever emits
them.** It does not today: `as` has the capability -- `as.s`'s
`:isrel` arm sets `$F8` and `check-as` byte-compares two REL modules
against real Merlin's own output -- but nothing in the build routes
objects through it. The REL objects the toolchain consumes come from
Merlin. Capability, not pipeline.

When that changes, `$2B` is the registered "Object Code" type and
would be an option. **It is not a debt.** `$F8`/LNK works, and forty
years of catalogs read it as LNK whether or not a registrar ever
blessed it -- it landed in the user range because `$FE REL`, DOS 3.3's
`R`, was already spent on EDASM, which is history rather than a
defect. REL and LNK are fine where they are.

One constraint if anyone does move: real Merlin restricts `DSK`
output to types `0, 6, $F0-$F7, $FF`, so it cannot write `$2B` -- only
maux's own tools can, since they CREATE their own output.

`$2C 8IC` "Interpreted Code" is likewise the registered home for a
`#!` script, should scripts ever want an identity beyond `$04 TXT`.

`$2A` for `.s` sources is the one to leave alone: Merlin reads TXT
source, and the stagers, `check-strip` and the self-hosting image are
all built on that.
