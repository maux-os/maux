# Merlin-8 REL object format, as measured

> **RETIRED GATES, 2026-10-18 (RULINGS-1).** `check-relink`, `check-librel` and `check-librelas`, which this document cites as its oracles, were retired (targets and drivers deleted). `scripts/relink.py` is kept as the REL-format reference model; `check-nas-librel` is the live byte gate.

**Why this file exists.** The approved `ld` rewrite -- a native two-pass
REL linker replacing the `LINKER.S` bridge -- rests entirely on this
format, and until 2026-08-30 the decoding existed only in a
conversation. Nothing in the tree recorded it. This is the re-derivation,
run against the 55 real-Merlin reference objects `check-librel` exports
to `build/lib/`, so it is reproducible rather than remembered.

Everything below is MEASURED over those objects unless marked otherwise.

## File layout

    [ code            ]  length = the file's ProDOS AUX TYPE
    [ fixup records   ]  4 bytes each, terminated by a $00 kind byte
    [ symbol list     ]  flag|len, name, $8000-based address; $00-terminated

File type is `$F8`. **The aux type is the code length** -- not decoration;
`ld` reads it from the directory entry, and a REL staged with aux=0 links
to a 0-byte output (that has actually happened, see
`build_textaudit_image.group_files`).

Symbol-list record: `flag|len`, then `len` name bytes (raw 7-bit ASCII,
NOT liba's high-bit convention), then a 2-byte address.

* **`len` is the LOW SIX BITS.** `src/bin/nm.s`'s header is an
  independently derived reading of this format and says six; a 5-bit
  mask agrees on every name in the tree (none reaches 32 characters)
  and would silently mangle one that did.
* `flag` is `$40` = `ENT` (exported) or `$80` = `EXT` (imported).
* **An `ENT`'s address is its module-relative offset**, `$8000`-based.
* **An `EXT`'s address is its REFNUM**, `$8000 + n` -- the same `n` a
  fixup's `byte3` carries. Positional order agrees with it across all
  878 `EXT` records in the corpus, but the field is what the format
  states, so index by it.

## The fixup record

Four bytes: `kind`, `offset_lo`, `offset_hi`, `byte3`. The offset is
little-endian and indexes the code section.

**There are SEVEN kinds.** Measured across 12,965 records in 183
objects -- the 55 real-Merlin library references AND the util
mains/bss objects from `build/librelas.po` (2026-08-30):

| kind | count | field | half | target | `byte3` |
|---|---|---|---|---|---|
| `$0F` |   313 | 1 byte | low  | internal | target's low byte |
| `$4F` |   313 | 1 byte | high | internal | target's low byte |
| `$1F` |   511 | 1 byte | low  | external | refnum |
| `$50` |   507 | 1 byte | high | external | refnum |
| `$51` |     4 | 1 byte | high | external | refnum |
| `$8F` | 2,843 | 2 byte | --    | internal | target's low byte |
| `$9F` | 8,474 | 2 byte | --    | external | refnum |

**`$51` occurs FOUR times in the entire corpus** and this table said
six kinds for a day because the first scan covered only the 55 library
objects -- the population there was a list of, not the population the
linker meets. A prototype linker built on the six-kind table linked 30
of 34 utils byte-identically and mis-linked four, each on a single
`$51` record. Scan `build/librelas.po` too.

`$50` and `$51` are treated IDENTICALLY by a correct linker -- external,
high byte -- and all four `$51` sites resolve to plain `high(target)`.
What the low bit distinguishes is unknown and appears not to matter for
linking; every other kind has bit 0 set, so `$50` is the odd one out
rather than `$51`.

### An external reference carries an ADDEND

`byte3` is the refnum, so the code itself holds `$8000 + addend`, and
the addend is REAL: `lda SYM` and `ora SYM+1` are two fixups with the
same refnum and stored values `$8000` and `$8001`. A linker that
resolves an external to `globals[name]` and ignores the stored value
mis-links every `SYM+n` reference -- measured, it broke 30 of 34 utils.

    target = globals[name] + (stored - $8000)

with `stored` read from the code: 2 bytes for `$9F`, the low byte for
`$1F`, and `(code[off] - $80) << 8` for `$50`/`$51`.

### ...but an EXTERNAL HIGH byte cannot carry a sub-page addend

The addend for `$50`/`$51` is recovered as `(code[off] - $80) << 8`.
Its LOW half has nowhere to live: the code holds one byte, and `byte3`
is spent on the refnum. So a high-byte fixup on an external is exact
only when `addend & $FF == 0`; otherwise the link silently drops the
carry out of `low(SYM) + low(addend)` and the byte comes out one too
low whenever that sum crosses a page.

Compare the INTERNAL high-byte kind `$4F`, which spends `byte3` on the
target's low byte precisely so the carry IS computable. An external has
no such spare field, so this is a limit of the FORMAT, not of any one
linker: `ld` (ldpass2.s `:exthi`), `relink.py` and the stock Merlin
LINK all behave the same way.

**Symptom:** one byte, off by exactly 1, in an otherwise byte-identical
linked image -- `check-nas-librel`'s `byte mismatch at offset N:
nas+ld=$1c merlin32=$1d`. Measured 2026-09-17 on `cal`, whose
`SLOTHI dfb >MBUFS,>MBUFS+184,>MBUFS+368` addressed three slots of a
`dum LIBA_BSSEND` cell -- and that arena is a separate bss MODULE under
the REL split, so `MBUFS` is an EXTERNAL and the two nonzero addends
were unrepresentable. Note the paired `SLOTLO dfb <MBUFS+184` was
CORRECT: kind `$1F` keeps the addend's low byte in the code, and a low
byte never needs the carry.

**The fix is in the SOURCE, not the toolchain: give the offset its own
label.** cal.s now declares `MBUFS0/MBUFS1/MBUFS2 ds 184` and
references three externals with addend zero, which the format carries
exactly. Byte-identical under merlin32 either way, so the monolithic
build cannot see the difference -- only the REL route can.

**Second instance, 2026-09-18: `make`.** `#>MK_NAMES+MK_NAMSZ-1` --
`MK_NAMES` at `$8F13`, addend 255 -- linked `$8F` against merlin32's
`$90`. Recorded in the commons at the time and NOT here, which is why
the next one got debugged from scratch; it is in this file now.
Remedied a different way, because the offset named nothing worth a
label: the addend moved out of the operand into a run-time 16-bit add
(`lda #<SYM / adc #<LIMIT`), six bytes a site, addend zero.

**Third instance, 2026-09-21: `nulib2`.** `#>RECHDR+6` -- the start of
the span a NuFX `header_crc` covers -- came out `$97` against merlin32's
`$98` in an otherwise byte-identical 9,523-byte image. `RECHDR` sits at
`$97FF`, so `+6` crosses a page: the same mechanism as cal's, reached by
a third route (an offset INTO a header, where cal's was a slot in an
array and make's the end of a buffer). Fixed cal's way -- `RECHDR ds 6` / `RECHDRCRC ds 52` -- and
`nulib2`'s four OTHER `#>BUF+n` sites (`MHBUF+8`, `RECBUF+6`, `MHDR+8`,
`LZ_CHDR+2`) were split at the same time although none of them carried
yet. The lesson from having three instances in five weeks: an arena
cell's low byte is not a property to rely on, because the cell MOVES
whenever the image before it changes size. `RECHDR` had been correct
for five slices and broke on a sixth that never touched it.

Still-latent sites in the tree, all `+1` on a count-byte buffer and all
correct TODAY only because `low(SYM) + 1` happens not to carry:
`src/bin/df.s`, `src/bin/du.s`, `src/bin/pwd.s` (`#>PFXBUF+1`) and
`src/bin/rmdir.s` (`#>PATHBUF+1`). `#>SCRIPTBUF+SCRMAX` in `src/bin/sed.s`
is safe for the other reason -- `SCRMAX` is 2048, a whole number of
pages. The trigger to fix the four is a one-byte `check-nas-librel` /
`check-librelas` miss on one of them; the fix is the same as cal's.

Deposited to the commons as `learning:01M2PSVAFMJJQN1PMPVS0FPYZP`.

### A `dum` ANCHORED ON A BSS SYMBOL is the same trap, one level up

Measured 2026-09-21 on `nulib2`, immediately after the carry fix above.
Overlaying one arena buffer on another reads naturally as:

    dum   LZ_STACK
    LZ_HEAD     ds    4096
    dend

merlin32 assembles it correctly, because it resolves `LZ_STACK` as a
plain address in one stream. Under the nas+ld split that arena is a
separate bss MODULE, so `LZ_STACK` is an **external** -- and a `dum`
needs its operand's VALUE at assembly time to place the block's labels.
nas has no such value, placed `LZ_HEAD` 18 bytes off, and said nothing;
`check-nas-librel` caught it as one byte of a 10,535-byte image
(`byte mismatch at offset 5056: nas+ld=$45 merlin32=$33`, the operand
of `lda #<LZ_HEAD`).

Note the symptom is NOT off-by-one: this is a different mechanism from
the fixup carry, reached from the same root cause -- a construct that
is correct in the flat build and unrepresentable in the relocatable
one. **The one-byte-difference signature therefore has at least three
causes now**; check the operand's SOURCE before assuming which.

**The fix is again in the source: drop the alias and spell the array by
its real name at every use site.** An overlay comment carries the
intent; a `dum` on an external cannot carry the address.

Deposited as the fourth instance on
`learning:01M2PSVAFMJJQN1PMPVS0FPYZP`, which now frames the whole family
as one class: **a construct that needs a bss symbol's VALUE at assembly
time, rather than a reference to it, cannot survive the REL split.**
`>SYM+n` needs its low half; `dum SYM` needs the whole address.

### Read it as an ENUMERATION, not a bitfield

A bitwise reading is tempting and *nearly* works -- `$80` looks like
"2-byte field", `$40` like "high half", `$10` like "external" -- and it is
how this was first written down. **It is wrong at one point:** the
external-high kind is `$50`, where a bitwise model predicts
`$4F | $10 = $5F`. Treat the six values as a lookup table. A linker that
masks bits instead will mis-handle every external high-byte reference,
of which there are 129 in the current corpus.

### 1-byte fixups come in LOW/HIGH PAIRS

The counts are exactly equal -- `$0F` 15 and `$4F` 15; `$1F` 129 and
`$50` 129 -- and the paired kinds have identical `byte3` distributions.
That is the `lda #<SYM` / `ldx #>SYM` idiom: one reference, two fixups.

### `byte3` has exactly two meanings, decided by internal vs external

**SETTLED 2026-08-30, measured over every record in the corpus.**

**Internal (`$0F`, `$4F`, `$8F`): `byte3` is the LOW BYTE of the
`$8000`-based target.** One rule, no exceptions:

| kind | `byte3 == code[offset]` | why |
|---|---|---|
| `$0F` | 15/15 (100%) | the code already holds the low byte there |
| `$8F` | 700/700 (100%) | the code holds the 2-byte value, low first |
| `$4F` | 0/15 (0%) | the code holds the HIGH byte -- `byte3` is the only place the low half exists |

That `$4F` row is the point of the field. Relocating a high byte needs
the **carry**: `high(base + target)` depends on whether
`low(base) + low(target)` overflowed, and for a high-byte fixup the low
half is not in the code at all. `byte3` is what makes the carry
computable without a second pass over the code. For `$0F` and `$8F` the
same value is simply redundant with what is already there.

**External (`$1F`, `$50`, `$9F`): `byte3` is the refnum.** Verified
structurally rather than by eye -- across the 46 objects that have
externals, `max(byte3) < ext_count` holds with **zero** violations.
`docs/REL-LIBA-SPIKE.md` independently records `$8000 + refnum` as the
external addressing convention, so ~255 externals is the budget.

## Linking semantics (what the stock LINK actually does)

Established by `scripts/relink.py`, a host prototype that reproduces
the stock linker byte-for-byte -- see below.

* **Whole-module.** No dead-code elimination: `build/rtlib.rel`
  exports `LIBUSED` and `LIBUNUSED`, and the reference image contains
  all 68 bytes of it. Confirms `docs/REL-LIBA-SPIKE.md`.
* **Bases are assigned in link order**, each module starting where the
  previous ended, from the `-a` address (default `LOAD_BASE`).
* ...but that is a LINKER POLICY, not a property of this format, and
  since 2026-09-17 it is not the only one. Every address in a REL
  module is `$8000`-based and every reference to it is a fixup, so
  nothing in the file says where the module lands; `ld`'s `PASS1`
  simply had one cursor. **`ld -s adr` bases the modules that follow
  at `adr` while the file offset keeps running, and `-s 0` resumes**
  -- two cursors, `NEXTADR` for where the bytes go and `SEGCUR` for
  where the code runs. Nothing in the object format changed, and
  `PASS2` needed no change at all: it streams module by module and
  never derives a file position from an address. The one caller is
  `sh`'s `$E000` language-card code segment (docs/SH-SUBSET.md 7.6),
  which is what made `sh` the last unit `check-nas-librel` could not
  link; the address may be written attached (`-sE000`) so the bracket
  costs two of the guest shell's 32 argv words rather than four.
  `scripts/relink.py` does NOT implement it -- it is the oracle for
  the real-Merlin objects (`check-relink`, `check-librel`), and no
  unit in those rosters has a segment run.
* **A module's own symbols relocate by `base - $8000`**, since every
  address in a REL object is `$8000`-based.
* **BSS modules go LAST and `-z` truncates the trailing zero span.**
  This is the whole mechanism for uninitialised space: the arena module
  occupies address space so its symbols resolve, emits only zeros, and
  `-z` keeps them out of the file. Without it `cat` is 4,183 B on disk
  instead of 1,652 -- the difference is exactly `LIBABSS` (1,927) plus
  `CATBR` (604).

## Reproducing this table

    python3 - <<'PY'
    import glob, os, json, collections
    meta = json.load(open('build/lib/meta.json'))
    kinds = collections.Counter()
    for base, m in sorted(meta.items()):
        p = f'build/lib/{base.lower()}.rel'
        if not os.path.exists(p):
            continue
        d = open(p, 'rb').read()
        i = m['aux']                      # aux type IS the code length
        while i + 3 < len(d) and d[i] != 0:
            kinds[d[i]] += 1
            i += 4
    print(sorted(kinds.items()))
    PY

Run `make check-librel` first -- it is what exports `build/lib/`.
The counts will drift as the tree grows; the six KINDS should not, and
a seventh appearing is a finding worth chasing rather than a number to
update.
