#!/usr/bin/env python3
"""check_nas_text.py -- nas's diagnostics and its two text conventions
(KFIX10 items 1 and 2; run after ``make nas-image``).

Item 1, an undefined symbol is an ERROR.  Before KFIX10 `lda #FOO` with
FOO undefined assembled to `A9 00`, widened a zero-page operand to
absolute, and exited 0.  Each row below runs the cooked nas (NCUT) on a
small source and pins the EXACT diagnostics -- name, file, and the line
IN that file (a PUT file counts its own lines) -- the exact number of
them, and the exit status.  A forward reference and an EXT symbol are
not undefined: those rows must still assemble.

Item 2, nas reads either text convention: see TEXT_CASES.  Those rows
compare the BYTES nas emits, never the glass (learning:01M317VKBTQ...,
a tool that finds no line break still renders as separate lines).

All fixtures are staged into a PRIVATE copy of the image, so the shared
build/nas.po is never touched.
"""
import os
from pathlib import Path
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_nas_boundary import boot  # noqa: E402
from check_plascut import blob, run_cmd  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos, convert  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md)

LIB = 'PLLIB'


def src(*lines):
    return ('\n'.join(lines) + '\n').encode('ascii')


# tag, {file: host-ascii bytes}, main file, [exact diagnostics],
# exit status.  An empty diagnostic list means "must assemble", and
# `want` then gives the exact object bytes (None: only that it built).
ERROR_CASES = [
    ('U1', {'U1.S': src(' org $2000', ' lda #FOO', ' rts')}, 'U1.S',
     ['unknown label FOO (U1.S line 2)']),
    # a zero-page store used to be WIDENED to absolute and exit 0
    ('U2', {'U2.S': src(' org $2000', ' sta BAR', ' rts')}, 'U2.S',
     ['unknown label BAR (U2.S line 2)']),
    # the PUT file counts its own lines, and the main file resumes
    # counting after it (lines 2 and 5 here, not 2 and 7)
    ('U3', {'U3.S': src(' org $2000', ' lda #1', ' put U3P', ' rts',
                        ' lda ZZ'),
            'U3P.S': src('* hdr', ' lda QQ')}, 'U3.S',
     ['unknown label QQ (U3P.S line 2)', 'unknown label ZZ (U3.S line 5)']),
    ('U4', {'U4.S': src(' org $2000', ' dfb FOO', ' da BAZ', ' ddb QUX')},
     'U4.S',
     ['unknown label FOO (U4.S line 2)', 'unknown label BAZ (U4.S line 3)',
      'unknown label QUX (U4.S line 4)']),
    # an EQU found unresolved by the retry names its own line
    ('U5', {'U5.S': src(' org $2000', 'X equ NOPE+1', 'Y equ X+1',
                        ' lda #Y', ' rts')}, 'U5.S',
     ['unknown label NOPE (U5.S line 2)']),
    ('U6', {'U6.S': src(' org $2000', ' err NOPE', ' rts')}, 'U6.S',
     ['unknown label NOPE (U6.S line 2)']),
    ('U7', {'U7.S': src(' org $2000', ' bne :NO', ' rts')}, 'U7.S',
     ['unknown label :NO (U7.S line 2)']),
    # a REL object without the EXT declaration: the symbol is unknown
    ('U8', {'U8.S': src(' rel', ' jsr XSY', ' rts')}, 'U8.S',
     ['unknown label XSY (U8.S line 2)']),
    # K7: a token that is not a name at all is a bad operand, not an
    # "unknown label %" / "unknown label -"
    ('U9', {'U9.S': src(' org $2000', ' lda #%1010', ' rts')}, 'U9.S',
     ['bad operand %1010 (U9.S line 2)']),
    ('U10', {'U10.S': src(' org $2000', ' lda #-1', ' rts')}, 'U10.S',
     ['bad operand -1 (U10.S line 2)']),
]

# Forward references of every shape that reaches evalexpr in pass 1
# (a bare `jsr LATER` is sized by the native fast path and would not
# notice a check wrongly raised in pass 1): a compound operand, a data
# directive, a byte selector, a forward EQU.  The expected bytes are
# merlin32's own, taken at gate time.
FWD_SRC = src(' org $2000', ' jsr LATER', ' lda LATER+1', ' da LATER',
              ' dfb <LATER,>LATER', 'FWD equ LATER2+1', ' lda #FWD',
              ' rts', 'LATER rts', 'LATER2 equ $12')

OK_CASES = [
    # forward references are fine: pass 1 must still allow them
    ('F1', {'F1.S': FWD_SRC}, 'F1.S', 'merlin32'),
    # an EXTERNAL symbol is not undefined (REL output, `ext`)
    # (merlin32 spells EXT differently and cannot assemble these two, so
    # the REL objects are FROZEN from this stream's nas, read against
    # docs/REL-FORMAT.md: the code, then a dictionary of external
    # fixups ($9F two-byte, $1F low, $50 high; refnum 0), then the
    # symbol table `XSY`. check-nas-rel links real ones end to end.)
    ('F2', {'F2.S': src(' rel', 'XSY ext', ' jsr XSY', ' rts')}, 'F2.S',
     bytes.fromhex('200080609f0100000083585359008000')),
    # ... also inside a compound expression, which the native fast path
    # does not take (only evalterm2's EXT branch can answer these)
    ('F3', {'F3.S': src(' rel', 'XSY ext', ' lda XSY+2', ' lda #<XSY',
                        ' lda #>XSY+1', ' da XSY+4', ' rts')}, 'F3.S',
     bytes.fromhex('ad0280a900a9800480609f0100001f040000500600009f07'
                   '0000' '0083585359008000')),
]


def oracle(tag, data):
    """merlin32's own bytes for one fixture (the byte-identity oracle
    check-nas-boundary uses)."""
    from check_nas_boundary import merlin_oracle
    with tempfile.TemporaryDirectory(prefix='nas-text-oracle-') as tmp:
        path = Path(tmp) / (tag + '.S')
        path.write_bytes(data)
        return merlin_oracle(path)


def stage(disk, files):
    vol = prodos.mount(disk, replace=True)
    try:
        for name, data in files.items():
            prodos.write(f'/mnt/{vol}/{LIB}/{name}', data, file_type=4,
                         aux_type=0, overwrite=True)
    finally:
        prodos.unmount(vol)


def nas_run(client, main, obj, tag):
    # sh has no `clear`: slice the screen at THIS run's own command
    # echo, so an earlier row's diagnostics cannot be counted again
    cmd = f'/mnt/MAUX/pllib/NCUT -o {obj} {main}'
    rows, _ = run_cmd(client, cmd, f'{tag} NAS', max_steps=12000)
    at = max(i for i, r in enumerate(rows) if cmd in r)
    text = blob(rows[at + 1:])
    status, _ = run_cmd(client, f'echo {tag}=$?', f'{tag} status',
                        max_steps=2500)
    marker = [r for r in status if r.strip().startswith(f'{tag}=')]
    if not marker:
        raise RuntimeError(f'{tag}: no exit marker:\n{blob(status)}')
    return text, marker[0].strip()


def main():
    if len(sys.argv) != 2:
        print(f'usage: {sys.argv[0]} build/nas.po', file=sys.stderr)
        return 2
    disk = os.path.abspath(sys.argv[1])
    files = {}
    for case_ in ERROR_CASES + OK_CASES:
        files.update(case_[1])
    raw = {}
    for case_ in TEXT_CASES:
        raw.update(case_[1])
    failures = []
    with tempfile.TemporaryDirectory(prefix='nas-text-') as tmp:
        image = str(Path(tmp) / 'text.po')
        shutil.copyfile(disk, image)
        stage(image, {n: convert.text_from_host(d) for n, d in files.items()})
        stage(image, raw)
        client = boot(image)
        try:
            run_cmd(client, 'cd /mnt/MAUX/pllib', 'cd')
            for tag, _, mainf, want in ERROR_CASES:
                text, marker = nas_run(client, mainf, tag + '.OBJ', tag)
                got = (text.count('unknown label') +
                       text.count('bad operand'))
                if marker != f'{tag}=1':
                    failures.append(f'{tag}: exit {marker!r}, want {tag}=1')
                if got != len(want):
                    failures.append(f'{tag}: {got} diagnostics, want '
                                    f'{len(want)}:\n{text}')
                for line in want:
                    if line not in text:
                        failures.append(f'{tag}: missing {line!r}:\n{text}')
                if 'bytes ->' in text:
                    failures.append(f'{tag}: reported an object:\n{text}')
                print(f'[check-nas-text] {tag}: {len(want)} diagnostic(s), '
                      'exit 1')
            for tag, _, mainf, _ in OK_CASES:
                text, marker = nas_run(client, mainf, tag + '.OBJ', tag)
                if (marker != f'{tag}=0' or 'bytes ->' not in text or
                        'unknown label' in text):
                    failures.append(f'{tag}: should assemble, silently:'
                                    f'\n{text}\n{marker}')
                print(f'[check-nas-text] {tag}: assembled, {marker}')
            for tag, _, mainf, _ in TEXT_CASES:
                text, marker = nas_run(client, mainf, tag + '.OBJ', tag)
                if marker != f'{tag}=0' or 'bytes ->' not in text:
                    failures.append(f'{tag}: should assemble:\n{text}\n'
                                    f'{marker}')
            run_cmd(client, 'ls', 'flush', max_steps=2000)
        finally:
            client.close()
        vol = prodos.mount(image, replace=True, readonly=True)
        try:
            for tag, _, _, want in OK_CASES:
                try:
                    data = prodos.read(f'/mnt/{vol}/{LIB}/{tag}.OBJ')
                except FileNotFoundError:
                    failures.append(f'{tag}: no object was written')
                    continue
                if want == 'merlin32':
                    want = oracle(tag, files[tag + '.S'])
                if want is not None and data != want:
                    failures.append(f'{tag}: object {data.hex()}, want '
                                    f'{want.hex()}')
            for tag, _, _, want in TEXT_CASES:
                try:
                    data = prodos.read(f'/mnt/{vol}/{LIB}/{tag}.OBJ')
                except FileNotFoundError:
                    failures.append(f'{tag}: no object was written')
                    continue
                if data != want:
                    failures.append(f'{tag}: object {data.hex()}, want '
                                    f'{want.hex()}')
        finally:
            prodos.unmount(vol)
    if failures:
        print('[check-nas-text] FAIL:', file=sys.stderr)
        for f in failures:
            print('  - ' + f, file=sys.stderr)
        return 1
    print(f'[check-nas-text] PASS: {len(ERROR_CASES)} unknown-label rows, '
          f'{len(OK_CASES)} must-assemble rows, {len(TEXT_CASES)} '
          'text-convention rows')
    return 0


# ---- item 2: nas reads either text convention ------------------------
# One program, one header (a PUT that must DEFINE its symbols), many
# encodings.  Every row must emit the SAME bytes: the tag only says
# which polarity the main file and the header were written in.
PROG = ['* text-convention fixture', ' org $2000', ' put TH',
        ' lda #FOO', ' sta BAR', ' jsr SUB', ' asc "Hi"', " asc 'Hi'",
        ' rts', 'SUB rts']
HDR = ['* header', 'FOO equ $42', 'BAR equ $FA']
# FOO and BAR only exist if the header was read: lda #$42, sta $FA (a
# zero-page store, not the widened `8D FA 00`), jsr $200C, "Hi" with the
# high bit set by the `"`, 'Hi' without.
WANT = bytes.fromhex('a9 42 85 fa 20 0c 20 c8 e9 48 69 60 60')


def enc(lines, polarity, term):
    """polarity 'low'|'high' for the characters, term 0x0D|0x8D."""
    out = bytearray()
    for line in lines:
        body = line.encode('ascii')
        if polarity == 'high':
            body = convert.text_from_host(body, high_bit=True)
        out += body + bytes([term])
    return bytes(out)


def mixed(lines):
    """Alternate polarity line by line, in ONE file."""
    out = bytearray()
    for i, line in enumerate(lines):
        out += enc([line], 'high' if i % 2 else 'low',
                   0x8D if i % 2 else 0x0D)
    return bytes(out)


def case(tag, main_bytes, hdr_bytes):
    return (tag, {tag + '.S': main_bytes, tag + 'H.S': hdr_bytes},
            tag + '.S', WANT)


def _text_cases():
    # the header is named `TH` in PROG; stage it under that name once
    # per case by renaming the PUT target to the case's own header
    rows = []
    for tag, mp, mt, hp, ht in (
            ('T1', 'low', 0x0D, 'low', 0x0D),     # ProDOS standard text
            ('T2', 'high', 0x8D, 'high', 0x8D),   # what maux's vi writes
            ('T3', 'low', 0x8D, 'low', 0x8D),     # low chars, $8D ends
            ('T4', 'high', 0x0D, 'high', 0x0D),   # high chars, $0D ends
            ('T5', 'low', 0x0D, 'high', 0x8D),    # header differs
            ('T6', 'high', 0x8D, 'low', 0x0D)):   # the other way round
        prog = [l.replace('put TH', f'put {tag}H') for l in PROG]
        rows.append(case(tag, enc(prog, mp, mt), enc(HDR, hp, ht)))
    prog = [l.replace('put TH', 'put T7H') for l in PROG]
    rows.append(case('T7', mixed(prog), mixed(HDR)))
    return rows


TEXT_CASES = _text_cases()

# The reader-edge fixture of check-nas-boundary (254/255/256/511-byte
# lines, CR at block offset 511, a line straddling the 512-byte block,
# a PUT, partial last lines) re-run as maux text: the same expected
# bytes.  The slow path (findcr) and the fast path (lineprep's scan)
# both see high-bit data here.
def _stream_cases():
    from check_nas_boundary import stream_fixture
    source, child, want = stream_fixture()

    def hi(b):
        return convert.text_from_host(b, high_bit=True)
    return [('S1', {'S1.S': hi(source), 'PART.S': hi(child)}, 'S1.S', want),
            ('S2', {'S2.S': source, 'PART.S': hi(child)}, 'S2.S', want)]


TEXT_CASES += _stream_cases()
if __name__ == '__main__':
    sys.exit(main())
