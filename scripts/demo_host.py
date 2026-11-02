"""demo_host.py -- host-side oracles for site/demos (docs/DEMOS-W1.md).

A demo must not assert against a number or a list somebody typed: when
the image grows, the typed value goes stale and the gate goes red for
the wrong reason (or, worse, stays green because both were copied from
the same screen). These helpers read the SAME build/play.po the demo
mounts (a copy-on-write mount, so a --setup teeth experiment changes
the guest's copy and never this file) with a2til, and hand the demo the
facts the guest should agree with.

Stdlib plus a2til; ASCII only.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
sys.path.insert(0, HERE)
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

PLAY = os.path.join(ROOT, 'build', 'play.po')


def ls_order(names):
    """`names` in the order maux's `ls` prints them: CASE-INSENSITIVE,
    because lssort.s sorts with STRCMPI (its own header says why --
    readdir.s hands back a case-decoded name now, not the uppercase
    bytes ProDOS stores). ASCII order is NOT the same order: a
    directory holding `Makefile` and `check` prints check first, and
    this oracle said `Makefile` until a demo listed one
    (site/demos/lssys.py, 2026-10-26). Ties are broken by the ASCII
    name, so the result is deterministic whatever order came in; two
    entries cannot differ only by case anyway, since ProDOS stores one
    name with case flags beside it."""
    return sorted(names, key=lambda n: (n.lower(), n))


def names(path, image=PLAY):
    """Entry names in a directory of the image, as ProDOS stores them
    (case flags honoured: /BIN holds lower case, the root does not),
    in the order `ls` prints them, one per row (see ls_order)."""
    v = prodos.Volume(image, readonly=True)
    return ls_order(e.name for e in v.scandir(path))


def read(path, image=PLAY):
    v = prodos.Volume(image, readonly=True)
    return bytes(v.read_file(path))


def columns_to_names(rows):
    """Undo `ls`'s multi-column layout: the console rows of a column-
    major listing back to one name list in print order. A row's cells
    are whitespace-separated; every column but the last holds the same
    number of names, so read each column top to bottom."""
    cells = [r.split() for r in rows if r.strip()]
    if not cells:
        return []
    ncol = max(len(c) for c in cells)
    out = []
    for j in range(ncol):
        for c in cells:
            if j < len(c):
                out.append(c[j])
    return out


def text(path, image=PLAY):
    """A text file as maux holds it (high-bit ASCII, CR line ends, the
    ProDOS habit) decoded the way the guest's programs see it: 7-bit
    characters, LF between lines. Returns the list of lines."""
    raw = read(path, image)
    s = ''.join(chr(b & 0x7F) for b in raw).replace('\r', '\n')
    lines = s.split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    return lines


def still(t, label, slices=60):
    """Wait until the glass has not changed across two polls: a screen
    that is being painted (a pager's page, vi's redraw) is not yet the
    picture, and a poster or an assertion must not take it mid-paint
    (learning:01M1AH9XWGC8ZS7HNBJVJ2JHXW)."""
    prev, same = None, 0
    for _ in range(slices):
        cur = [r.rstrip() for r in t.screen()]
        same = same + 1 if cur == prev else 0
        if same >= 2:
            return cur
        prev = cur
        t._slice()
    t.expect(False, label + ': the screen never held still')


def cksum(data):
    """POSIX cksum(1): the CRC of the bytes, then of the length bytes,
    complemented. Returns (crc, length) as the tool prints them."""
    crc = 0
    for b in data:
        crc ^= b << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) if crc & 0x80000000 \
                else crc << 1
            crc &= 0xFFFFFFFF
    n = len(data)
    while n:
        crc ^= (n & 0xFF) << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) if crc & 0x80000000 \
                else crc << 1
            crc &= 0xFFFFFFFF
        n >>= 8
    return (~crc) & 0xFFFFFFFF, len(data)
