#!/usr/bin/env python3
"""check_lseg.py -- the play-only low segment's layout (`make
check-lseg`, docs/LOOP-S1.md ruling 2026-10-10).

The loop driver, attach/detach, the cells and the saved bytes live in
main RAM $1300-$1AFF (file LSEG, loaded at boot); above them sit the
caches, which are NOT in the file:

    LP_MAST  $1B00  master index, 128 lo + 128 hi
    LP_IDX0  $1C00  index block 0, pinned (2 pages)
    LP_SLOT  $1E00  one more index block (2 pages)

The image file's io_buffer is not here: it is one of the kernel pool's
eight (PRC_ALLC_IBF), the pool being ProDOS's own FCB ceiling.

Pinned here, from the assembler's own symbol dump and the staged
files, so none of it can drift silently:

  1. the code ends at or below LP_MAST and is at most LSEG_MAXPG pages;
  2. the three caches do not overlap, are page aligned, and end at or
     below $2000;
  3. the segment starts above every probe/harness cell the play
     manifest (playtestb.s) keeps in $0800-$1FFF;
  4. build/MAUXPLAY_LSEG is the assembled segment, whole pages, and the
     play image carries that exact file as /LSEG.

`--selftest` plants broken layouts and shows each is rejected.
ASCII only. Exit 0 green, 1 red, 2 rig problem.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL',
                                                     '~/src/a2til')))
from split_kseg import _read_symbol  # noqa: E402

ROOT = os.path.dirname(HERE)
NAMES = ('LSEG_ORG', 'LSEG_END', 'LSEG_MAXPG', 'LP_MAST', 'LP_IDX0',
         'LP_SLOT', 'LSEG_TOP')


def layout_problems(s, probe_cells):
    """s: symbol dict. Returns a list of problems (empty = fine)."""
    p = []
    if s['LSEG_END'] <= s['LSEG_ORG']:
        p.append('the segment is empty')
    if s['LSEG_END'] > s['LP_MAST']:
        p.append(f"code ends ${s['LSEG_END']:04X}, past LP_MAST "
                 f"${s['LP_MAST']:04X}")
    if s['LSEG_END'] - s['LSEG_ORG'] > s['LSEG_MAXPG'] * 256:
        p.append('the segment is more than LSEG_MAXPG pages')
    for n in ('LP_MAST', 'LP_IDX0', 'LP_SLOT'):
        if s[n] & 0xFF:
            p.append(f'{n} is not page aligned')
    spans = (('LP_MAST', 256), ('LP_IDX0', 512), ('LP_SLOT', 512))
    for (a, la), (b, _) in zip(spans, spans[1:]):
        if s[a] + la > s[b]:
            p.append(f'{a} overlaps {b}')
    if s['LP_SLOT'] + 512 > s['LSEG_TOP'] or s['LSEG_TOP'] > 0x2000:
        p.append('the buffers run past $2000')
    for name, addr in probe_cells.items():
        if addr >= s['LSEG_ORG']:
            p.append(f'harness cell {name} (${addr:04X}) is at or '
                     f"above LSEG_ORG ${s['LSEG_ORG']:04X}")
    return p


def probe_cells():
    """Every equ in playtestb.s that names an address in $0800-$1FFF."""
    out = {}
    path = os.path.join(ROOT, 'src', 'test', 'playtestb.s')
    with open(path, encoding='ascii') as fh:
        for line in fh:
            m = re.match(r'^(\w+)\s+equ\s+\$([0-9A-Fa-f]{4})\b', line)
            if m and 0x0800 <= int(m.group(2), 16) < 0x2000:
                out[m.group(1)] = int(m.group(2), 16)
    return out


def selftest():
    good = dict(LSEG_ORG=0x1300, LSEG_END=0x16F8, LSEG_MAXPG=8,
                LP_MAST=0x1B00, LP_IDX0=0x1C00, LP_SLOT=0x1E00,
                LSEG_TOP=0x2000)
    cells = {'R_DONE': 0x1210}
    assert not layout_problems(good, cells), 'the good layout is red'
    bad = (dict(good, LSEG_END=0x1B01),
           dict(good, LP_IDX0=0x1C10),
           dict(good, LP_SLOT=0x1D00),
           dict(good, LP_SLOT=0x1F00, LSEG_TOP=0x2100),
           dict(good, LSEG_TOP=0x2100),
           dict(good, LSEG_ORG=0x1200, LSEG_END=0x16F8))
    for b in bad:
        assert layout_problems(b, cells), f'not rejected: {b}'
    assert layout_problems(good, {'R_X': 0x1300}), 'cell not rejected'
    print('PASS lseg gate mutations: six broken layouts and a colliding '
          'harness cell rejected, the good layout accepted')


def main():
    selftest()
    out = os.path.join(ROOT, 'build', 'MAUXPLAY.SYSTEM_Output.txt')
    if not os.path.exists(out):
        print(f'check-lseg: {out} missing -- make play-image')
        return 2
    s = {n: _read_symbol(out, n) for n in NAMES if n != 'LSEG_MAXPG'}
    with open(out, encoding='ascii', errors='replace') as fh:
        m = re.search(r'^\s*LSEG_MAXPG\s*=\s*(\d+)\s*$', fh.read(), re.M)
    s['LSEG_MAXPG'] = int(m.group(1)) if m else None
    missing = [n for n, v in s.items() if v is None]
    if missing:
        print(f'FAIL lseg: symbols missing from the dump: {missing}')
        return 1
    probs = layout_problems(s, probe_cells())
    seg = os.path.join(ROOT, 'build', 'MAUXPLAY_LSEG')
    full = os.path.join(ROOT, 'build', 'MAUXPLAY.SYSTEM.full')
    with open(seg, 'rb') as fh:
        blob = fh.read()
    n = s['LSEG_END'] - s['LSEG_ORG']
    if len(blob) % 256 or len(blob) < n or len(blob) - n >= 256:
        probs.append(f'MAUXPLAY_LSEG is {len(blob)} B for a {n} B segment')
    if os.path.exists(full):
        with open(full, 'rb') as fh:
            raw = fh.read()
        if raw[-n:] != blob[:n]:
            probs.append('MAUXPLAY_LSEG is not the tail of the '
                         'assembled image')
    try:
        from a2til import prodos
        v = prodos.Volume(os.path.join(ROOT, 'build', 'play.po'))
        staged = v.read_file('/MAUX/LSEG')
        v.close()
        if staged != blob:
            probs.append('play.po carries a different /LSEG')
    except FileNotFoundError:
        probs.append('play.po has no /LSEG')
    if probs:
        print(f'FAIL lseg: {len(probs)} problem(s)')
        for x in probs:
            print(f'  - {x}')
        return 1
    print(f"PASS lseg: ${s['LSEG_ORG']:04X}-${s['LSEG_END']:04X} "
          f'({n} B of {s["LSEG_MAXPG"] * 256}), caches '
          f"${s['LP_MAST']:04X}-${s['LSEG_TOP']:04X}, below every probe "
          'cell, and the staged /LSEG is the assembled one')
    return 0


if __name__ == '__main__':
    sys.exit(main())
