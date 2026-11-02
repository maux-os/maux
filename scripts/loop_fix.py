"""loop_fix.py -- fixtures for check-loop (docs/LOOP-S1.md): ProDOS
tree-file images written by a2til into a host volume.

a2til stores an all-zero data block SPARSELY (a zero in the index, no
block), which is exactly the image `mount` must refuse -- and exactly
what a naive 'empty volume' fixture would silently be. A dense fixture
therefore marks every all-zero block (they are free blocks, boot
blocks or never-written tail) with a junk byte at offset 511.

ASCII only.
"""
import os
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL',
                                                     '~/src/a2til')))
from a2til import prodos  # noqa: E402

from a2til import convert  # noqa: E402

HELLO = convert.text_from_host(b'HI\n', high_bit=True)   # "HI" as maux holds text


def junk_zero_blocks(data):
    """Dense version of a volume image: no all-zero 512-byte block."""
    out = bytearray(data)
    for off in range(0, len(out) - 511, 512):
        if not any(out[off:off + 512]):
            out[off + 511] = 0xA5
    return bytes(out)


def make_volume(path, name, blocks, files=()):
    prodos.create(path, name=name, blocks=blocks)
    v = prodos.Volume(path)
    for fname, data in files:
        v.write_file(fname, data, file_type=4, aux_type=0)
    v.close()
    with open(path, 'rb') as f:
        return f.read()


def dense_image(tmp, name, blocks, files=()):
    """The bytes of a dense volume image (a ProDOS volume NAME)."""
    p = os.path.join(tmp, f'img-{name}.po')
    return junk_zero_blocks(make_volume(p, name, blocks, files))


def sparse_image(tmp, name, blocks, files=()):
    """The same volume, left as a2til wrote it (all-zero blocks)."""
    p = os.path.join(tmp, f'img-{name}-s.po')
    return make_volume(p, name, blocks, files)


def twomg(raw, fmt=1, off=64, flags=0, blocks=None):
    """A 2IMG container around a .po image (64-byte header, data at
    `off`).  fmt/off/flags/blocks override header fields for the
    refusal fixtures; flags bit 31 (byte $13 bit 7) is 'locked'."""
    hdr = bytearray(64)
    hdr[0:4] = b'2IMG'
    hdr[4:8] = b'MAUX'
    hdr[8:10] = (64).to_bytes(2, 'little')
    hdr[10:12] = (1).to_bytes(2, 'little')
    hdr[12:16] = fmt.to_bytes(4, 'little')          # 1 = ProDOS order
    hdr[16:20] = flags.to_bytes(4, 'little')
    nb = len(raw) // 512 if blocks is None else blocks
    hdr[20:24] = nb.to_bytes(4, 'little')
    hdr[24:28] = off.to_bytes(4, 'little')
    hdr[28:32] = len(raw).to_bytes(4, 'little')
    body = bytes(hdr)[:64]
    if off != 64:
        body = bytes(hdr) + bytes(max(0, off - 64))
    return junk_zero_blocks(body + raw)
