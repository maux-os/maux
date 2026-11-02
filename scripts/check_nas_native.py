#!/usr/bin/env python3
"""Independent CPU oracle for NAS native lookup helpers (ACME + py65).

Extracts the actual inline assembly, not a second implementation. Tests
relocated code/data, page-crossing strings/records, all stack positions,
collisions, wildcard zones and directive spellings against Python oracles.
Optional host diagnostic: py65 is not a production/build dependency.
"""
import ast
from pathlib import Path
import random
import re
import subprocess
import tempfile

from py65.devices.mpu6502 import MPU

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'src/asm/nas.pla').read_text()


def block(name):
    return re.search(r'^asm ' + name + r'\([^\n]*\n(.*?)^end$',
                     SOURCE, re.M | re.S)[1]


def tables():
    constants = {k: int(v) for k, v in re.findall(
        r'^const (D_\w+)\s*=\s*(\d+)', SOURCE, re.M)}
    data = SOURCE.split('byte dirhash[] = ', 1)[1].split('// STATIC', 1)[0]
    values = []
    for line in data.splitlines():
        line = line.split('//')[0]
        if '=' in line:
            line = line.split('=', 1)[1]
        for item in line.split(','):
            item = item.strip()
            if not item:
                continue
            value = constants[item] if item in constants else ast.literal_eval(item)
            values.append(ord(value) if isinstance(value, str) else value)
    return values


def putword(mem, addr, value):
    mem[addr] = value & 255
    mem[addr + 1] = value >> 8


def invoke(mem, address, args, expected, x):
    cpu = MPU(memory=mem)
    cpu.pc, cpu.x, cpu.sp = address, x, 0xF0
    # RTS returns to $3000, outside either relocated code region.
    mem[0x1F1:0x1F3] = [0xFF, 0x2F]
    mem[0x9F:0xE9] = [(i * 73 ^ x) & 255 for i in range(0xE9 - 0x9F)]
    for index, value in enumerate(reversed(args)):
        mem[0xC0 + x + index] = value & 255
        mem[0xA0 + x + index] = value >> 8
    before = mem.copy()
    for _ in range(3000):
        cpu.step()
        if cpu.pc == 0x3000:
            break
    else:
        raise AssertionError('helper failed to return')
    result_slot = x + len(args) - 1
    actual = mem[0xC0 + result_slot] | mem[0xA0 + result_slot] << 8
    assert actual == expected, (args, hex(actual), hex(expected))
    assert cpu.x == result_slot and cpu.sp == 0xF2
    # Only scratch ZP, consumed arguments and hardware-stack scratch may change.
    allowed = set(range(6, 10)) | {0x9E, 0xE7, 0xE8, 0x1F0}
    allowed |= set(range(0xA0 + x, 0xA0 + x + len(args)))
    allowed |= set(range(0xC0 + x, 0xC0 + x + len(args)))
    changed = {i for i, (a, b) in enumerate(zip(before, mem)) if a != b}
    assert changed <= allowed, ('unexpected memory writes', changed - allowed)


def run(code, addresses, origin, rng):
    mem = [0] * 65536
    mem[origin:origin + len(code)] = code
    data = tables()
    # Independent directive oracle: declared spelling -> ID, no hash traversal.
    directives = {}
    for offset in range(256, len(data) - 7, 7):
        _, ident, length, *name = data[offset:offset + 7]
        directives[bytes(name[:length])] = ident
    names = [b'', b'A', b'NOTADIRECTIVE', b'LDA', b'ADC', b'NOP']
    for name in directives:
        names.extend((name, name.lower(), name[:1] + name[1:].lower(),
                      name + b'X', b'Z' + name[1:]))
    names.extend(bytes(rng.randrange(65, 91) for _ in range(rng.randrange(2, 5)))
                 for _ in range(300))
    count = 0
    if 'dirid' in addresses:
        for index, name in enumerate(names):
            table, parse, text = 0x60F9, 0x70FC, 0x80FE
            mem[table:table + len(data)] = data
            mem[text:text + len(name)] = name
            folded = bytes(c & 0xDF for c in name)
            padded = folded + b'\0\0\0'
            hashed = (5 * padded[0] + 3 * padded[1] + padded[2]) & 255
            putword(mem, parse + 4, text)
            putword(mem, parse + 6, len(name))
            putword(mem, parse + 12, hashed)
            invoke(mem, addresses['dirid'], [parse, table],
                   directives.get(folded, 0), index % 31)
            count += 1
    for index in range(600):
        length = rng.choice([0, 1, 2, 12, 13, 14, 32, 255])
        query = bytes(rng.choice(b'aAbB:XYZ') for _ in range(length))
        zone = rng.choice([0, 1, 255, 256, 0x7FFF, 0x8000, 0xFFFF])
        text = rng.choice([0x8000, 0x80FF, 0x80FE])
        mem[text:text + length] = query
        records = []
        for j in range(rng.randrange(6)):
            name = rng.choice([query[:13], query[:13].swapcase(),
                               query[:12] + b'?', b'collision'])
            zc = rng.choice([zone, 0xFFFF, zone ^ 1])
            addr, namep = 0x90FD + j * 16, 0xA0FC + j * 32
            records.append((addr, name, zc))
            putword(mem, addr, namep)
            mem[namep:namep + len(name) + 1] = [len(name), *name]
            putword(mem, addr + 4, zc)
        for j, (addr, _, _) in enumerate(records):
            putword(mem, addr + 6, records[j + 1][0] if j + 1 < len(records) else 0)
        expected = next((addr for addr, name, zc in records
                         if name == query[:13] and zc in (zone, 0xFFFF)), 0)
        head = records[0][0] if records else 0
        invoke(mem, addresses['findsymh'], [text, length, head, zone],
               expected, index % 29)
        count += 1
    # Gate teeth: replace the helper entry with RTS. It must fail the oracle.
    mem[addresses['findsymh']] = 0x60
    try:
        invoke(mem, addresses['findsymh'], [0x8000, 1, 0, 0], 0, 0)
    except AssertionError:
        pass
    else:
        raise AssertionError('deliberately broken helper escaped detection')
    return count


def main():
    equates = block('findcr').split('        LDA', 1)[0]
    with tempfile.TemporaryDirectory(prefix='nas-native-') as tmp:
        tmp = Path(tmp)
        asm, binary, symbols = tmp/'lookup.a', tmp/'lookup.bin', tmp/'lookup.sym'
        source = equates + '\nfindsymh\n' + block('findsymh') + '\n'
        if re.search(r'^asm dirid\(', SOURCE, re.M):
            source += 'dirid\n' + block('dirid') + '\n'
        asm.write_text(source)
        total = 0
        for origin in (0x4000, 0x41F9):
            subprocess.run(['acme', '--setpc', str(origin), '-o', str(binary),
                            '-l', str(symbols), str(asm)], check=True)
            addresses = {k: int(v, 16) for k, v in re.findall(
                r'(\w+)\s*=\s*\$([0-9a-fA-F]+)', symbols.read_text())}
            code = binary.read_bytes()
            total += run(code, addresses, origin, random.Random(618))
        print(f'PASS: {total} CPU-oracle cases; {len(code)} native bytes; '
              'two relocations; stack/memory guards; deliberate failure rejected')


if __name__ == '__main__':
    main()
