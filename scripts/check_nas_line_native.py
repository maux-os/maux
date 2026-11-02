#!/usr/bin/env python3
"""CPU oracle for NAS line preparation/emission (optional ACME + py65).

Extract real ASM, require origin-independent bytes, trace EVERY CPU write,
and compare against independent Python token/reader/instruction models.
--baseline-source also tests the original separate helpers on the same inputs.
"""
import argparse
import ast
from pathlib import Path
import random
import re
import subprocess
import tempfile
import os
import sys
from py65.devices.mpu6502 import MPU

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import convert  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
MODESIZE = (1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 2, 2, 2, 3, 2)

def block(source, name):
    match = re.search(r'^asm ' + re.escape(name) + r'\([^\n]*\n(.*?)^end$',
                      source, re.M | re.S)
    return match.group(1) if match else None


def table(source):
    constants = {k: int(v) for k, v in re.findall(
        r'^const (D_\w+)\s*=\s*(\d+)', source, re.M)}
    if 'byte dirhash[] = ' not in source:
        return [], {}
    data = source.split('byte dirhash[] = ', 1)[1].split('// STATIC', 1)[0]
    values = []
    for line in data.splitlines():
        line = line.split('//', 1)[0]
        if '=' in line:
            line = line.split('=', 1)[1]
        for item in line.split(','):
            item = item.strip()
            if item:
                value = constants[item] if item in constants else ast.literal_eval(item)
                values.append(ord(value) if isinstance(value, str) else value)
    names = {}
    for off in range(256, len(values) - 6, 7):
        _, ident, length, *name = values[off:off + 7]
        names[bytes(name[:length]).upper()] = ident
    return values, names


def word(mem, addr):
    return mem[addr] | mem[(addr + 1) & 0xffff] << 8


def putword(mem, addr, value):
    mem[addr & 0xffff] = value & 255
    mem[(addr + 1) & 0xffff] = value >> 8


def stackargs(mem, args, x=3):
    for index, value in enumerate(reversed(args)):
        mem[0xc0 + x + index] = value & 255
        mem[0xa0 + x + index] = value >> 8


def stackword(mem, slot):
    return mem[0xc0 + slot] | mem[0xa0 + slot] << 8


def token_model(text, ptr, stale):
    """Return only fields tokline is specified to write."""
    out = {2: 0, 3: 0, 6: 0, 7: 0, 10: 0, 11: 0}
    n = len(text)
    if not n or text[0] == ord('*'):
        return out
    y = 0
    if text[0] != 0x20:
        while y < n and text[y] != 0x20:
            y += 1
        out.update({0: ptr & 255, 1: ptr >> 8, 2: y, 3: 0})
    while y < n and text[y] == 0x20:
        y += 1
    if y >= n or text[y] == ord(';'):
        return out
    start = y
    while y < n and text[y] != 0x20:
        y += 1
    mnem = text[start:y]
    out.update({4: (ptr + start) & 255, 5: ((ptr + start) >> 8) & 255,
                6: len(mnem), 7: 0})
    folded = bytes(c & 0xdf for c in mnem)
    h = 5 * (folded[0] if len(folded) > 0 else 0)
    h += 3 * (folded[1] if len(folded) > 1 else 0)
    h += folded[2] if len(folded) > 2 else 0
    out.update({12: h & 255, 13: 0})
    while y < n and text[y] == 0x20:
        y += 1
    if y >= n or text[y] == ord(';'):
        return out
    start = y
    quote = None
    while y < n:
        c = text[y]
        if quote is not None:
            if c == quote:
                quote = None
            y += 1
            continue
        if c in (ord("'"), ord('"')):
            quote = c
        elif c in (0x20, ord(';')):
            break
        y += 1
    out.update({8: (ptr + start) & 255, 9: ((ptr + start) >> 8) & 255,
                10: y - start, 11: 0})
    return out


def emit_model(op, mode, value, pc):
    if not 0 <= mode < len(MODESIZE):
        return -1, []
    size = MODESIZE[mode]
    if mode == 14:
        delta = (value - (pc + 2)) & 0xffff
        delta -= 0x10000 if delta >= 0x8000 else 0
        if not -128 <= delta <= 127:
            return -1, []
        return size, [op & 255, delta & 255]
    result = [op & 255]
    if size > 1:
        result.append(value & 255)
    if size > 2:
        result.append((value >> 8) & 255)
    return size, result


def assemble(source, names, origin):
    prelude = block(source, 'findcr')
    if prelude is None:
        raise AssertionError('findcr block is required for standalone extraction')
    prelude = prelude.split('        LDA', 1)[0]
    text = prelude + '\n' + '\n'.join(name + '\n' + block(source, name)
                                      for name in names) + '\n'
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    tmp = tempfile.TemporaryDirectory(prefix='nas-line-')
    path = Path(tmp.name)
    asm, binary, symbols = path/'line.a', path/'line.bin', path/'line.sym'
    asm.write_text(text)
    result = subprocess.run(['acme', '--setpc', str(origin), '-o', str(binary),
                             '-l', str(symbols), str(asm)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise AssertionError('ACME extraction failed: ' + result.stderr.decode())
    addresses = {k: int(v, 16) for k, v in re.findall(
        r'(\w+)\s*=\s*\$([0-9a-fA-F]+)', symbols.read_text())}
    return tmp, binary.read_bytes(), addresses



class TracedMemory(list):
    def __init__(self):
        super().__init__([0xA5] * 65536)
        self.recording = False
        self.writes = set()

    def __setitem__(self, key, value):
        if self.recording:
            if isinstance(key, slice):
                self.writes.update(range(*key.indices(len(self))))
            else:
                self.writes.add(key)
        super().__setitem__(key, value)


def call(code, origin, entry, args, result, setup, allowed=(), x=0, returns=True,
         extra_setup=None):
    mem = TracedMemory()
    mem[origin:origin + len(code)] = code
    setup(mem)
    for at in list(range(0xA0, 0x100)) + list(range(0x1E8, 0x200)):
        mem[at] = (at * 73 + x * 31) & 255
    stackargs(mem, args, x)
    mem[0x1F1:0x1F3] = [0xFF, 0x2F]
    if extra_setup:
        extra_setup(mem)
    cpu = MPU(memory=mem)
    cpu.pc, cpu.x, cpu.sp = entry, x, 0xF0
    cpu.p = 0x30 | ((x * 73) & 0xC5)  # arbitrary entry flags, binary arithmetic
    mem.recording = True
    for _ in range(20000):
        cpu.step()
        if cpu.pc == 0x3000:
            break
    else:
        raise AssertionError(('timeout', args, hex(cpu.pc)))
    slot = x + len(args) - int(returns)
    assert cpu.x == slot and cpu.sp == 0xF2, ('ABI', args, cpu.x, cpu.sp)
    if returns:
        assert stackword(mem, slot) == result & 0xFFFF, (
            'result', args, stackword(mem, slot), result & 0xFFFF)
    scratch = set(range(6, 10)) | {0x9E, 0xE7, 0xE8}
    scratch |= set(range(0x1EE, 0x1F1))  # at most three balanced tokenizer PHAs
    scratch |= set(range(0xA0 + x, 0xA0 + x + len(args)))
    scratch |= set(range(0xC0 + x, 0xC0 + x + len(args)))
    assert mem.writes <= scratch | set(allowed), (
        'unexpected writes', args, sorted(mem.writes - scratch - set(allowed)))
    return mem


def tokens(text, ptr):
    result = [0xA5] * 14
    for offset, value in token_model(text, ptr, result).items():
        result[offset] = value
    return result


def classification(text, ptr, parsed, directives):
    if not parsed[2] and not parsed[6]:
        return -1
    start = ((parsed[4] | parsed[5] << 8) - ptr) & 0xFFFF
    spelling = bytes(c & 0xDF for c in text[start:start + parsed[6]])
    return directives.get(spelling, 0) if parsed[6] else 0


def fixtures(directives):
    rows = [b'', b' ', b'   ', b'*comment', b';label', b'; comment',
            b'LBL', b'LBL ', b'LBL ;comment', b' LDA', b' lda #1',
            b'LBL LDA #1 ; tail', b'LBL\tLDA\t#1', b' LDA\t#1',
            b' LDA #";"', b" LDA #' '", b' ASC "A ; B"',
            b' ASC "unterminated ; space', b" ASC 'A B'C",
            b' LDA;COMMENT #1', b' LDA ;empty', b'\tLDA #1']
    for name, ident in directives.items():
        if ident:
            for spelling in (name, name.lower(), name[:1] + name[1:].lower(),
                             name + b'X', b'Z' + name[1:], name[:1]):
                rows.append(b' ' + spelling + b' #1 ; comment')
    rng = random.Random(619)
    for _ in range(220):
        mnemonic = bytes(rng.choice(b'ABCDEFGHIJKLMNOPQRSTUVWXYZ;')
                         for _ in range(rng.randrange(1, 8)))
        rows.append(rng.choice((b' ', b'LABEL ', b':LOCAL ')) + mnemonic +
                    rng.choice((b'', b' #1', b' "A ; B"', b'\t#2')))
    for length in (1, 254, 255, 256, 511):
        rows.extend((b'A' * length, b' ' * length,
                     (b' LDA #1 ;' + b'x' * length)[:length]))
    return rows


def scanned_off(scanned, ptr):
    return {a - ptr for a in scanned}


def must_reject(test):
    try:
        test()
    except AssertionError:
        return
    raise AssertionError('deliberately corrupted helper escaped detection')


def run_front(source, code, addresses, origin, legacy=False):
    data, directives = table(source)
    rows = fixtures(directives)
    count = 0
    cases = [(False, row[:255], 0) for row in rows]
    cases += [(True, row + b'\r', 0) for row in rows]
    cases += [(True, b' LDA #1\rignored\r', pos) for pos in (1, 127, 255, 495)]
    cases += [(True, b' ' * 511 + b'\r', 0), (True, b'\r', 511)]
    cases += [(True, b'A' * length, pos)
              for length, pos in ((0, 0), (0, 512), (1, 0), (255, 0),
                                  (256, 0), (511, 0), (512, 0), (1, 511))]
    # KFIX10 item 2: a line ends on (b & $7F) == $0D and the scan masks
    # what it reads, in place.  maux text (high bit, $8D), low characters
    # with an $8D end, high characters with a $0D end, and one line that
    # changes polarity half way -- all must tokenize as the low text.
    def high(b):
        return convert.text_from_host(b, high_bit=True)
    for row in rows:
        row = row[:250]
        cases.append((True, high(row) + b'\x8d', 0))
        cases.append((True, row + b'\x8d', 0))
        cases.append((True, high(row) + b'\r', 0))
        cases.append((True, row[:len(row) // 2] + high(row[len(row) // 2:])
                      + b'\x8d', 0))
    cases += [(True, high(b' LDA #1\rignored\r'), pos) for pos in (1, 127, 495)]
    cases += [(True, b' ' * 255 + high(b' ' * 255) + b'\x8d', 0)]
    positions = set()
    for index, (reader, raw, pos) in enumerate(cases):
        x = index % 29
        positions.add(x)
        buf = (0x8000, 0x80FE, 0x80FF)[index % 3]
        if reader and not raw and pos == 0:
            buf = 0  # the real pending-PUT tuple has no buffer yet
        st, li, tok, dirs = ((0x12FE, 0x70FC, 0x72FC, 0x60F9),
                             (0x13FF, 0x71FF, 0x73FF, 0x62FE))[index % 2]
        assert not reader or pos + len(raw) <= 512
        ptr = buf + pos
        ordinal = (0, 255, 0xFFFF)[index % 3]
        ends = [i for i, c in enumerate(raw) if c & 0x7F == 13]
        hit = not reader or bool(ends)
        physical = ends[0] if reader and hit else len(raw)
        # the parse sees the MASKED bytes of a reader line
        seen = bytes(c & 0x7F for c in raw) if reader else raw
        text = seen[:min(physical, 255)]
        parsed = tokens(text, ptr)
        ident = classification(text, ptr, parsed, directives)
        def setup(mem):
            mem[ptr:ptr + len(raw)] = raw
            mem[ptr + len(raw)] = 13  # a no-CR search must not consume this
            putword(mem, st, buf)
            putword(mem, st + 2, pos)
            putword(mem, st + 4, pos + len(raw))
            putword(mem, li, ptr if not reader else 0x7777)
            putword(mem, li + 2, len(text) if not reader else 0x5555)
            putword(mem, li + 4, ordinal)
            mem[dirs:dirs + len(data)] = data
        if legacy:
            if reader:
                expected = min(physical, 255) if hit else 0xFFFF
                writable = set(range(li, li + (6 if hit else 2)))
                if hit:
                    writable |= {st + 2, st + 3}
                mem = call(code, origin, addresses['rdline'], [st, li],
                           expected, setup, writable, x)
                assert word(mem, li) == ptr
                assert word(mem, st + 2) == pos + (physical + 1 if hit else 0)
                assert word(mem, li + 4) == (ordinal + int(hit)) & 0xFFFF
                assert word(mem, li + 2) == (len(text) if hit else 0x5555)
                count += 1
            if hit:
                mem = call(code, origin, addresses['tokline'],
                           [ptr, len(text), tok], 0, setup,
                           range(tok, tok + 14), x, returns=False)
                assert mem[tok:tok + 14] == parsed, ('old tokens', text)
                def setup_dir(mem):
                    setup(mem)
                    mem[tok:tok + 14] = parsed
                call(code, origin, addresses['dirid'], [tok, dirs],
                     max(ident, 0), setup_dir, (), x)
                count += 2
        else:
            writable = set(range(tok, tok + 14)) if hit else set()
            # the bytes the scan reads are masked in place: the line up
            # to and including its terminator, or all `raw` with none
            scanned = range(ptr, ptr + (physical + 1 if reader and hit
                                        else len(raw) if reader else 0))
            writable |= set(scanned)
            if reader and hit:
                writable |= set(range(li, li + 6)) | {st + 2, st + 3}
            try:
                mem = call(code, origin, addresses['lineprep'],
                           [st if reader else 0, li, tok, dirs],
                           ident if hit else -2, setup, writable, x)
                assert word(mem, st) == buf
                for i in range(len(raw)):       # masked up to the end only
                    want = raw[i] & 0x7F if i in scanned_off(scanned, ptr) \
                        else raw[i]
                    assert mem[ptr + i] == want, ('mask', i, raw)
                assert mem[ptr + len(raw)] == 13   # the sentinel, untouched
                assert word(mem, st + 4) == pos + len(raw)
                assert word(mem, st + 2) == pos + (
                    physical + 1 if reader and hit else 0)
                assert word(mem, li + 4) == (ordinal + int(reader and hit)) & 0xFFFF
                if hit:
                    assert word(mem, li) == ptr
                    assert word(mem, li + 2) == len(text)
                    assert mem[tok:tok + 14] == parsed, (
                        'tokens', mem[tok:tok + 14], parsed)
            except AssertionError as error:
                raise AssertionError(('line case', index, reader, raw, pos, x, error)) from error
            count += 1
    assert positions == set(range(29))
    if not legacy:
        broken = bytearray(code)
        broken[addresses['lineprep'] - origin] = 0x60
        must_reject(lambda: call(broken, origin, addresses['lineprep'],
                    [0, li, tok, dirs], 0, setup, (), 0))
    return count


def run_emit(code, addresses, origin):
    count = 0
    positions = set()
    for mode in (*range(15), 15, 255, 256, 0x8000, 0xFFFF):
        for pc in (0, 0xFFFE, 0xFFFF, 0x7FFF, 0x80FE):
            values = [0, 1, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFFFF]
            if mode == 14:
                values += [(pc + 2 + delta) & 0xFFFF
                           for delta in (-129, -128, -1, 0, 1, 127, 128)]
            for value in values:
                for op in (0, 0xFF):
                    x = count % 28
                    positions.add(x)
                    dst = 0x74FF
                    expected, data = emit_model(op, mode, value, pc)
                    def setup(mem):
                        mem[dst:dst + 4] = [0xCC] * 4
                    mem = call(code, origin, addresses['emitinst'],
                               [op, mode, value, pc, dst], expected, setup,
                               range(dst, dst + len(data)), x)
                    assert mem[dst:dst + 4] == data + [0xCC] * (4 - len(data)), (
                        mode, value, pc, op, x, mem[dst:dst + 4], data)
                    count += 1
    assert positions == set(range(28))
    broken = bytearray(code)
    broken[addresses['emitinst'] - origin] = 0x60
    must_reject(lambda: call(broken, origin, addresses['emitinst'],
                [0xEA, 0, 0, 0, dst], 1, setup, (), 0))
    return count


def check_source(path, require=False):
    source = path.read_text()
    names = [name for name in ('lineprep', 'emitinst') if block(source, name)]
    legacy = not names
    if legacy:
        names = ['tokline', 'dirid', 'rdline']
    if require and ('lineprep' not in names or not (
            'emitinst' in names or block(source, 'commitinst'))):
        raise AssertionError('production requires native line prep and emission')
    frozen = None
    total = 0
    for origin in (0x4000, 0x41F9):
        tmp, code, addresses = assemble(source, names, origin)
        try:
            if frozen is not None:
                assert code == frozen, 'inline ASM contains origin-dependent bytes'
            frozen = code
            if legacy or 'lineprep' in names:
                total += run_front(source, code, addresses, origin, legacy)
            if 'emitinst' in names:
                total += run_emit(code, addresses, origin)
        finally:
            tmp.cleanup()
    print(f'PASS: {path}; {total} CPU cases; {len(code)} native bytes; '
          'two byte-identical relocations, all legal X, traced writes/IFP/stack guards'
          + ('; actual-helper sabotage rejected' if not legacy else '; baseline model differential'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / 'src/asm/nas.pla')
    parser.add_argument('--baseline-source', type=Path)
    parser.add_argument('--front-source', type=Path)
    parser.add_argument('--emit-source', type=Path)
    parser.add_argument('--require-native', action='store_true')
    args = parser.parse_args()
    if args.baseline_source:
        check_source(args.baseline_source)
    check_source(args.source, args.require_native)
    for path in (args.front_source, args.emit_source):
        if path:
            check_source(path)


if __name__ == '__main__':
    main()
