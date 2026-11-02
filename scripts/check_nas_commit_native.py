#!/usr/bin/env python3
"""Independent CPU oracle for the transactional pass2 instruction commit."""
from pathlib import Path
import random
import re

from check_nas_line_native import (MODESIZE, assemble, call, emit_model,
                                   must_reject, putword, word)

ROOT = Path(__file__).resolve().parents[1]


def layout(source):
    clean = re.sub(r'//[^\n]*', '', source)
    assert re.search(r'word outbuf\s+word outfill\s+word outtotal\s+'
                     r'word curpc\s+word nfixcand\s+word orgbase', clean)
    assert re.search(r'word fxrec\s+word numfixups\s+word maxfixups\s+'
                     r'word g_ern, g_eraw\s+byte g_ek, g_esel, relflag', clean)
    # Independently describe operand syntax, not the production trim algorithm.
    operands = ('', 'A', '#VALUE', 'VALUE', 'VALUE,X', 'VALUE,Y',
                'VALUE', 'VALUE,X', 'VALUE,Y', '(VALUE)', '(VALUE,X)',
                '(VALUE),Y', '(VALUE)', '(VALUE,X)', 'VALUE')
    prefix = [int(v) for v in re.search(
        r'byte modeprefix\[\] = ([\d,]+)', source)[1].split(',')]
    trim = [int(v) for v in re.search(
        r'byte modetrim\[\]\s*= ([\d,]+)', source)[1].split(',')]
    assert len(prefix) == len(trim) == 15
    for mode, operand in enumerate(operands[2:], 2):
        start, length = prefix[mode], len(operand) - trim[mode]
        assert operand[start:start + length] == 'VALUE', (mode, operand)


def check(code, entry, origin, row, index):
    op, mode, value, pc, base, fill, total, enabled, kind, sel, raw, ref, n, cap = row
    size, expected = emit_model(op, mode, value, pc)
    fixup = None
    if size < 0:
        result = -1
    elif fill + size > 512:
        result = -2
    else:
        if size > 1 and mode != 14 and enabled and kind:
            if size == 3:
                stored = (0x8000 + raw) & 0xffff
                expected[1:] = [stored & 255, stored >> 8]
                tag = {1: 0x8f, 2: 0x9f}[kind]
            elif sel == ord('>'):
                expected[1] = ((0x8000 + raw) >> 8) & 255
                tag = {1: 0x4f, 2: 0x50}[kind]
            else:
                expected[1] = raw & 255
                tag = {1: 0x0f, 2: 0x1f}[kind]
            offset = (pc - base + 1) & 0xffff
            fixup = [tag, offset & 255, offset >> 8,
                     (raw if kind == 1 else ref) & 255]
        result = -3 if fixup and n >= cap else size
    out = 0x60fe + index % 3
    rel = 0x70fe + index % 3
    buf = 0x90ff + index % 3
    records = 0xa0ff + index % 3
    sentinel = 0xbeef

    def setup(mem):
        for at, val in ((out, buf), (out + 2, fill), (out + 4, total),
                        (out + 6, pc), (out + 8, sentinel), (out + 10, base),
                        (rel, records), (rel + 2, n), (rel + 4, cap),
                        (rel + 6, ref), (rel + 8, raw)):
            putword(mem, at, val)
        mem[rel + 10:rel + 13] = [kind, sel, enabled]

    allowed = set()
    if result > 0:
        allowed.update(range(out + 2, out + 8))
        allowed.update(range(buf + fill, buf + fill + size))
        if fixup:
            allowed.update(range(rel + 2, rel + 4))
            allowed.update(range(records + n * 4, records + n * 4 + 4))
    mem = call(code, origin, entry, [op, mode, value, out, rel], result,
               setup, allowed, x=index % 28)
    assert not mem.writes & set(range(0x100, 0x200)), 'hardware stack scratch'
    assert word(mem, out) == buf and word(mem, out + 8) == sentinel
    assert word(mem, out + 10) == base
    assert word(mem, rel) == records and word(mem, rel + 4) == cap
    assert word(mem, rel + 6) == ref and word(mem, rel + 8) == raw
    assert mem[rel + 10:rel + 13] == [kind, sel, enabled]
    assert word(mem, out + 2) == fill + (size if result > 0 else 0)
    assert word(mem, out + 4) == (total + (size if result > 0 else 0)) & 0xffff
    assert word(mem, out + 6) == (pc + (size if result > 0 else 0)) & 0xffff
    assert word(mem, rel + 2) == n + int(result > 0 and fixup is not None), (
        row, result, fixup, word(mem, rel + 2))
    if result > 0:
        assert mem[buf + fill:buf + fill + size] == expected, row
        if fixup:
            assert mem[records + n * 4:records + n * 4 + 4] == fixup, row


def cases():
    rng = random.Random(921)
    rows = []
    # Every mode, REL kind, selector, and precise buffer edge. Stale expression
    # metadata must be ignored for implied/accumulator, branch and flat output.
    for mode in range(15):
        for kind in (0, 1, 2):
            for sel in (0, ord('<'), ord('>')):
                for fill in (0, 255, 509, 510, 511, 512):
                    pc = rng.choice((0, 255, 0x7fff, 0xfffe, 0xffff))
                    value = (pc + 2 + rng.choice((-128, 0, 127))) & 0xffff
                    rows.append((rng.randrange(256), mode, value, pc,
                                 rng.choice((0, 0x2000, 0xffff)), fill, 0xffff,
                                 1, kind, sel, rng.randrange(65536), 0xffff,
                                 rng.choice((0, 1, 255, 256)), 257))
    for _ in range(900):
        rows.append((rng.randrange(256), rng.choice((*range(15), 15, 256, 65535)),
                     rng.randrange(65536), rng.randrange(65536),
                     rng.randrange(65536), rng.choice((0, 256, 510, 511, 512,
                                                      513, 0xffff)),
                     rng.randrange(65536), rng.choice((0, 1, 255)),
                     rng.randrange(3), rng.choice((0, ord('<'), ord('>'))),
                     rng.randrange(65536), rng.randrange(65536),
                     rng.choice((0, 1, 255, 256, 0x8000, 0xffff)),
                     rng.choice((0, 1, 255, 256, 257))))
    for pc in (0, 1, 255, 0x7fff, 0xfffe, 0xffff):
        for delta in (-32768, -129, -128, -1, 0, 127, 128, 32767):
            rows.append((0xd0, 14, (pc + 2 + delta) & 0xffff, pc, 0, 0, 0,
                         1, 2, ord('>'), 0xffff, 42, 1, 1))
    # Deterministic stored-byte carry and fixup offset/count boundary coverage.
    for mode in (2, 6):
        for kind in (1, 2):
            for raw in (0, 255, 256, 0x7fff, 0x8000, 0xffff):
                for sel in (ord('<'), ord('>')):
                    for n, cap in ((0, 0), (1, 1), (255, 256), (256, 257)):
                        rows.append((0xad, mode, raw, 0xffff, 0, 509, 0xffff,
                                     1, kind, sel, raw, 255, n, cap))
    return rows


def main():
    source = (ROOT / 'src/asm/nas.pla').read_text()
    layout(source)
    first = None
    rows = cases()
    for origin in (0x4000, 0x41f9):
        temp, code, entries = assemble(source, ['commitinst'], origin)
        try:
            assert first is None or code == first, 'absolute internal reference'
            first = code
            for i, row in enumerate(rows):
                check(code, entries['commitinst'], origin, row, i)
            broken = bytearray(code)
            broken[0] = 0x60
            must_reject(lambda: check(broken, entries['commitinst'], origin,
                                     rows[0], 0))
            # Wrong internal-word kind must fail the byte oracle, independently
            # of the entry/ABI sabotage. Mutate the actual LDA #$8F instruction.
            signature = bytes.fromhex('a9 8f a4 9e c0 01')
            assert code.count(signature) == 1
            broken = bytearray(code)
            broken[code.index(signature) + 1] = 0x8e
            word_fix = (0xad, 6, 0, 0x20ff, 0x2000, 509, 0, 1, 1, 0,
                        0x1234, 0, 0, 1)
            must_reject(lambda: check(broken, entries['commitinst'], origin,
                                     word_fix, 0))
        finally:
            temp.cleanup()
    print(f'PASS: {len(rows) * 2} commitinst CPU cases; {len(first)} bytes; '
          'REL kinds, branch/buffer/counter boundaries, all X, every-write '
          'guards, transactional refusal, two origins, entry/kind sabotage')


if __name__ == '__main__':
    main()
