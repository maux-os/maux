# maux File Type Note

    File Type:        $F8 (248)
    Auxiliary Type:   code length in bytes (see below)
    Full Name:        Merlin-8 relocatable object module
    Short Name:       Merlin REL

    Written by:       the maux project, August 2026
    Status:           DOCUMENTATION of an existing de-facto type.
                      $F8 is formally "ProDOS user defined file 8";
                      Merlin-8 (Glen Bredon) used it for its REL
                      object modules, informally, as was his way.
                      Nobody appears to have published the byte
                      format; this note records it as measured.

    NOT to be confused with $FE, the REGISTERED "Relocatable code
    file" -- that type and the name REL properly belong to Apple's
    own EDASM toolchain (the ProDOS Assembler Tools), whose
    ESD/RLD record format is entirely different and incompatible.
    Merlin's modules share only the word "REL".

## Background

Merlin-8's `REL` directive assembles a source into a relocatable
object module; its linking loader (`LINK $addr,namesfile`) combines
modules into a flat binary. Merlin writes these objects as type
`$F8` with the auxiliary type carrying the CODE length. maux's `as`
produces the identical format (byte-verified against real Merlin-8
2.59 output across 25 modules), and maux's `ld` consumes it.

## File format

    [ code image          ]   aux_type bytes
    [ fixup list          ]   4 bytes per entry, $00-terminated
    [ symbol list         ]   variable,        $00-terminated

The code image is assembled at the fictional base `$8000`; every
unresolved external reference site holds `$8000 + refnum` as a
placeholder (so a `JSR` to external #0 reads `20 00 80` unlinked).

### Fixup list

One 4-byte record per reference SITE (not per symbol):

    +0  kind      nonzero; $9F observed for a 2-byte reference,
                  $50 for a hi-byte (`#>ext`) reference -- encodes
                  fixup class, not fully decoded
    +1  offset lo  \  site's offset within the code image
    +2  offset hi  /
    +3  refnum    external reference number ($00-$FE)

Records for the same external interleave freely; order is reverse
source order (a prepend-built list). A lone `$00` terminates.

### Symbol list

One record per ENT (export) or EXT (import) name:

    +0        flag|len   $40 = ENT, $80 = EXT, OR'd with the name
                         length in the low 6 bits
    +1..+len  name       raw 7-bit ASCII (NOT high-bit)
    +len+1    addr lo    \  ENT: $8000 + module-relative offset
    +len+2    addr hi    /  EXT: $8000 + refnum (placeholder)

A lone `$00` terminates the list and the file.

## Constraints the format implies

- External refnums span `$00-$FE`: <= 255 imports per module.
- Byte-select externals (`#<ext`/`#>ext`) tolerate an offset of at
  most 7; the assembler refuses more. Full 16-bit references take
  arbitrary offsets (measured: `+$23` links exactly).
- `ds` storage EMITS into the code image (zeros), so a pure-bss
  module is representable -- and linking one LAST yields a
  contiguous [image][bss] layout a consumer may truncate.

## Provenance

Reverse-engineered from five Merlin-8 2.59-built specimens
(2026-08-21) and since confirmed across the 23-module maux liba
sweep plus offset/negative/hi-byte probes, all against real
Merlin-8 under cycle emulation. The Merlin 8/16 manual documents
the SEMANTICS (ENT/EXT, the $8000 base, the refnum budget) but not
this byte layout.
