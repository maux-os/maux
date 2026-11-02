"""Host model of the REL linker -- the ORACLE for the `ld` rewrite.

Written before any 6502, to prove the format in docs/REL-FORMAT.md is
complete: if this cannot reproduce the stock linker's bytes, an
assembly version cannot either, and here that costs seconds to find
out rather than an emulator boot.

It earned that keep immediately. Against the full corpus it found two
things the format notes had wrong -- external references carry an
ADDEND (30 of 34 utils mis-linked without it), and there is a SEVENTH
fixup kind, `$51`, which occurs four times in 12,965 records and was
invisible in the 55-object sample the notes were written from.

STATUS: reproduces the stock Merlin LINK byte-for-byte on
build/rtlinked.bin, and reproduces all 34 utils check-librelas linked
(checked while scripts/check_relink.py existed; that gate was retired
2026-10-18, RULINGS-1, and the model is kept as the REL-format
reference). It is what the 6502 linker was developed against.
"""
import os, sys


def parse(path, codelen):
    d = open(path, 'rb').read()
    code = bytearray(d[:codelen])
    i = codelen
    fx = []
    while i + 3 < len(d) and d[i] != 0:
        fx.append((d[i], d[i + 1] | (d[i + 2] << 8), d[i + 3]))
        i += 4
    i += 1
    ents, exts = {}, {}
    while i < len(d) and d[i] != 0:
        h = d[i]; i += 1
        # LENGTH IS THE LOW SIX BITS, not five -- src/bin/nm.s's header
        # is an independently derived reading of this format and says
        # so. It never bites here (no name reaches 32 characters) but a
        # 5-bit mask would silently mangle one that did.
        n, flag = h & 0x3F, h & 0xC0
        name = ''.join(chr(b & 0x7F) for b in d[i:i + n]); i += n
        addr = d[i] | (d[i + 1] << 8); i += 2
        if flag & 0x40:
            ents[name] = addr
        if flag & 0x80:
            # AN EXT's ADDRESS FIELD IS ITS REFNUM ($8000 + n), which
            # is what a fixup's byte3 indexes. Positional order agrees
            # across all 878 EXT records in the corpus, but the field
            # is what the format actually says, so use it.
            exts[addr - 0x8000] = name
    return code, fx, ents, exts


def link(modules, base, zflag=False):
    """modules: [(path, codelen)] in link order. Returns the image.

    `zflag` is ld's -z: truncate the trailing zero span. That is how a
    BSS module works here -- it is linked LAST, occupies address space
    so its symbols resolve, emits nothing but zeros, and -z removes
    them from the file. Without it a util's image carries its whole
    uninitialised arena on disk (CAT: 4,183 B instead of 1,652)."""
    # PASS 1 -- assign each module a base and collect its exports.
    parsed, addr, globals_ = [], base, {}
    for path, codelen in modules:
        code, fx, ents, exts = parse(path, codelen)
        for name, a in ents.items():
            if name in globals_:
                raise SystemExit(f'duplicate symbol {name}')
            globals_[name] = addr + (a - 0x8000)
        parsed.append((addr, code, fx, exts))
        addr += len(code)

    # PASS 2 -- lay the code down and apply every fixup.
    out = bytearray()
    codes = []
    for modbase, code, fx, exts in parsed:
        for kind, off, b3 in fx:
            if kind in (0x1F, 0x50, 0x51, 0x9F):   # external: b3 = refnum
                if b3 not in exts:
                    raise SystemExit(f'refnum {b3} names no external')
                name = exts[b3]
                if name not in globals_:
                    raise SystemExit(f'undefined symbol {name}')
                # AN EXTERNAL REFERENCE CARRIES AN ADDEND, held in the
                # code as $8000 + addend -- `lda SYM` and `ora SYM+1`
                # are two fixups with the SAME refnum and different
                # stored values. Discarding it silently mis-links every
                # SYM+n reference.
                if kind == 0x9F:
                    addend = (code[off] | (code[off + 1] << 8)) - 0x8000
                elif kind in (0x50, 0x51):
                    addend = (code[off] - 0x80) << 8
                else:                                  # $1F, low byte
                    addend = code[off]
                target = globals_[name] + addend
            else:                                  # internal
                # byte3 is the target's LOW byte; the stored code
                # supplies the high half for a 2-byte or high-byte
                # fixup (docs/REL-FORMAT.md).
                if kind == 0x8F:
                    stored = code[off] | (code[off + 1] << 8)
                elif kind == 0x4F:
                    stored = (code[off] << 8) | b3
                else:                              # $0F, 1-byte low
                    stored = b3
                target = modbase + (stored - 0x8000)
            if kind in (0x8F, 0x9F):
                code[off] = target & 0xFF
                code[off + 1] = (target >> 8) & 0xFF
            elif kind in (0x4F, 0x50, 0x51):
                code[off] = (target >> 8) & 0xFF
            else:
                code[off] = target & 0xFF
        codes.append(code)
    if zflag:
        # MODULE-granular, as the streaming ld is (ldstream.s ZRUN /
        # MODNZ): a code module keeps its own trailing zeros (ex.s
        # ends in `dfb 0`; proshimpg's page ends in two zero pads);
        # only trailing ALL-ZERO modules (bss) are dropped.
        while codes and not any(codes[-1]):
            codes.pop()
    for code in codes:
        out += code
    return bytes(out)


if __name__ == '__main__':
    got = link([('build/rtmain.rel', 4), ('build/rtlib.rel', 68)], 0x2000)
    ref = open('build/rtlinked.bin', 'rb').read()
    print(f'linked {len(got)}B, reference {len(ref)}B')
    if got == ref:
        print('BYTE-IDENTICAL to the stock Merlin LINK')
    else:
        for i, (a, b) in enumerate(zip(got, ref)):
            if a != b:
                print(f'  first diff at {i}: got ${a:02X} want ${b:02X}')
                break
        print('  got', got.hex())
        print('  ref', ref.hex())
