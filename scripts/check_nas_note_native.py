#!/usr/bin/env python3
"""Independent opcode-record/PC/fixup CPU oracle (optional ACME + py65)."""
from pathlib import Path
import random
import re

from check_nas_line_native import (MODESIZE, assemble, call, must_reject,
                                   putword, word)
from check_nas_mode_native import optab_rows

ROOT = Path(__file__).resolve().parents[1]


def tables(source):
    section = source.split('byte opmode[] = ', 1)[1].split(
        '// The DIRECTIVE table', 1)[0]
    values = []
    for line in section.splitlines():
        line = line.split('//', 1)[0].strip()
        if not line:
            continue
        if '=' in line:
            line = line.split('=', 1)[1]
        values.extend(int(value.strip()) for value in line.split(','))
    modes = [0] * 256
    seen = {}
    for _, _, _, mode, opcode, _ in optab_rows():
        assert opcode not in seen or seen[opcode] == mode, (
            'one opcode must not encode two modes', opcode, seen[opcode], mode)
        seen[opcode] = mode
        modes[opcode] = mode
    assert values == modes + list(MODESIZE), 'opcode/modesize layout mismatch'
    assert re.search(r'word curpc\s*\nword nfixcand\b', source)
    fields = re.findall(r'^word (\w+)', source[source.index('word modestrm'):],
                        re.M)[:4]
    assert fields == ['modestrm', 'modecnt', 'modepos', 'maxmodes'], fields
    return values


def run(code, entry, origin, data):
    rng = random.Random(919)
    tests = []
    for op in range(256):
        for count in (0, 255, 256):
            tests.append((op, data[op], count, count + 1,
                          rng.choice((0, 255, 0x7FFF, 0xFFFE, 0xFFFF)),
                          rng.choice((0, 255, 0xFFFF))))
    for op in (0, 0xFF, 0x100, 0xFFFF):
        for count, limit in ((0, 0), (1, 1), (256, 255), (255, 256)):
            tests.append((op, data[op & 255], count, limit, 0xFFFF, 0xFFFF))
    for mode in (15, 255):
        tests.append((0xFF, mode, 0, 1, 0x2000, 1))
    positions = set()
    for index, (op, mode, count, limit, pc, fixes) in enumerate(tests):
        table = 0x80FF + index % 3 * 0x100
        stream = 0x60FE + index % 3
        state = 0x70FF + index % 3
        output = 0x90FF + index % 3
        position = 0xBEEF
        success = op < 256 and mode < 15 and count < limit
        size = MODESIZE[mode] if mode < 15 else 0
        updated = (fixes + (size > 1 and mode != 14)) & 0xFFFF

        def setup(mem):
            mem[table:table + len(data)] = data
            mem[table + (op & 255)] = mode
            for at, value in ((stream, output), (stream + 2, count),
                              (stream + 4, position), (stream + 6, limit),
                              (state, pc), (state + 2, fixes)):
                putword(mem, at, value)

        allowed = ({output + count} | set(range(stream + 2, stream + 4)) |
                   set(range(state, state + 4))) if success else set()
        x = index % 29
        positions.add(x)
        mem = call(code, origin, entry, [op, table, stream, state], int(success),
                   setup, allowed, x=x)
        assert word(mem, stream) == output
        assert word(mem, stream + 2) == count + int(success)
        assert word(mem, stream + 4) == position
        assert word(mem, stream + 6) == limit
        assert word(mem, state) == ((pc + size) & 0xFFFF if success else pc)
        assert word(mem, state + 2) == (updated if success else fixes)
        if success:
            assert mem[output + count] == op
        assert not (mem.writes & set(range(0x100, 0x200))), 'stack scratch used'
    assert positions == set(range(29))

    broken = bytearray(code)
    broken[entry - origin] = 0x60
    must_reject(lambda: call(broken, origin, entry, [0, 0x8000, 0x6000, 0x7000],
                             1, lambda mem: None))
    return len(tests)


def main():
    source = (ROOT / 'src/asm/nas.pla').read_text()
    data = tables(source)
    first = None
    total = 0
    for origin in (0x4000, 0x41F9):
        temp, code, entries = assemble(source, ['noteinst'], origin)
        try:
            if first is not None:
                assert code == first, 'native code contains absolute self references'
            first = code
            total += run(code, entries['noteinst'], origin, data)
        finally:
            temp.cleanup()
    print(f'PASS: {total} noteinst CPU cases; {len(first)} native bytes; '
          'all opcodes, capacity/PC/fixup wrap, page crossings, all legal X; '
          'every write checked, two-origin byte identity, sabotage rejected')


if __name__ == '__main__':
    main()
