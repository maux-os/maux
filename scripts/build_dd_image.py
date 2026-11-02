#!/usr/bin/env python3
"""Build build/dd.po -- the check-dd gate image (file-level `dd`).

The play image (which already stages `dd`, `cmp` and `sh`) plus one
directory /mnt/MAUX/D holding four raw fixtures the gate's typed
`dd`/`cmp` sequence reads:

  A  48 bytes, the ramp $00..$2F -- the input every case copies.
  K  16 bytes, the ramp $10..$1F -- what `dd skip=1 count=1 bs=16`
     must extract (the second 16-byte block of A).
  P   1 byte,  $EE               -- the one-byte "patch" the notrunc
     case pokes into a copy of A.
  Q  48 bytes, A with byte 5 set to $EE -- what a copy of A must look
     like AFTER `dd ... bs=1 seek=5 conv=notrunc` overwrites offset 5
     in place and leaves every other byte untouched.

check_dd.py types, at the shell: a copy, a skip+count slice, and the
load-bearing in-place seek+notrunc poke, each followed by a `cmp`
against the matching fixture and `echo <TAG>=$?`. Byte-exactness is
the fixture's job; the gate only scrapes the tags.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAY_IMG = os.path.join(ROOT, 'build', 'play.po')
OUT_IMG = os.path.join(ROOT, 'build', 'dd.po')
DD_BIN = os.path.join(ROOT, 'build', 'dd.bin')
VOL = 'MAUX'
SUBDIR = f'/mnt/{VOL}/D'

A_BYTES = bytes(range(0x00, 0x30))          # ramp $00..$2F, 48 bytes
K_BYTES = bytes(range(0x10, 0x20))          # A's second 16-byte block
P_BYTES = bytes([0xEE])                     # the one-byte patch
_q = bytearray(A_BYTES)
_q[5] = 0xEE
Q_BYTES = bytes(_q)                         # A with offset 5 poked


def main():
    for path, label in [(PLAY_IMG, 'play image'), (DD_BIN, 'dd.bin')]:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2
    shutil.copyfile(PLAY_IMG, OUT_IMG)
    with open(DD_BIN, 'rb') as f:
        ddbin = f.read()
    prodos.mount(OUT_IMG)
    try:
        # dd is PLAY_EXCLUDEd from the shared image (root-cap); stage it
        # here, exactly as build_play_image stages a util.
        try:                      # docs/VROOT.md: programs live in BIN
            prodos.mkdir(f'/mnt/{VOL}/BIN')
        except FileExistsError:
            pass
        prodos.write(f'/mnt/{VOL}/BIN/dd', ddbin, file_type=0x06, aux_type=0x0800,
                     overwrite=True)
        prodos.mkdir(SUBDIR)
        for name, data in (('A', A_BYTES), ('K', K_BYTES),
                           ('P', P_BYTES), ('Q', Q_BYTES)):
            prodos.write(f'{SUBDIR}/{name}', data, file_type=0x06,
                         aux_type=0x0000, overwrite=True)
        names = sorted(e.name for e in prodos.scandir(SUBDIR))
    finally:
        prodos.unmount(VOL)
    print(f'[build-dd] wrote {SUBDIR} fixtures {names}')
    print(f'[build-dd] {OUT_IMG} ready')
    return 0


if __name__ == '__main__':
    sys.exit(main())
