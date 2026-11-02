#!/usr/bin/env python3
"""build_unpack_image.py -- the check-unpack gate fixtures
(docs/UNPACK-E2E.md): real archives from the wild, unpacked onto a
running maux, going the OTHER way from docs/NUFX.md's writer slices
and docs/FLOPPY-E2E.md's dd-then-archive chain.

Two images:

  build/unpack.po  -- the play image family (what check-dd/check-devblk/
      check-floppy boot) plus `dd` staged at the root (PLAY_EXCLUDEd for
      root-cap, the same precedent build_dd_image.py/build_floppy_image.py
      use), the four REAL fixtures (fixtures/PROVENANCE.md) staged under
      /mnt/MAUX/ARC/ with their own basenames (so a person reading the
      machine's own directory sees exactly what they downloaded), and an
      empty /mnt/MAUX/OUT/ directory as the unpack target. nulib2/cp/ls/cmp
      need no staging: all three are already play-image UTILS members.

  build/unpack2.po -- a SCRATCH 280-block ProDOS volume (a2til
      `prodos.create(blocks=280)`), holding nothing -- "the real disk"
      leg B/C image to a spare SmartPort unit and read back from.

Archive files are staged with ProDOS file_type $E0 (NON) / aux_type
$8002, the same convention check_nulib2.py/check_floppy.py already use
for NuFX archives (docs/NUFX.md's own "name is nulib2's too" section /
File Type Note $E0/8000-family).
"""
import os
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAY_IMG = os.path.join(ROOT, 'build', 'play.po')
DD_BIN = os.path.join(ROOT, 'build', 'dd.bin')
UNPACK_IMG = os.path.join(ROOT, 'build', 'unpack.po')
UNPACK2_IMG = os.path.join(ROOT, 'build', 'unpack2.po')

VOL = 'MAUX'
UNPACK2_VOLNAME = 'SCRATCH'
UNPACK2_BLOCKS = 280

#: fixtures/PROVENANCE.md -- real archives fetched from public Apple II
#: archives, committed byte-for-byte. Staged under /mnt/MAUX/ARC/ by their
#: own basenames.
FIXTURES = [
    os.path.join(ROOT, 'fixtures', 'asimov', 'VBLSET.SHK'),
    os.path.join(ROOT, 'fixtures', 'asimov', 'SLOTSCAN.SHK'),
    os.path.join(ROOT, 'fixtures', 'gem', 'DEMOPROG.SDK'),
    os.path.join(ROOT, 'fixtures', 'gem', 'XMASADV.SDK'),
]

#: ProDOS type/aux for a staged NuFX archive -- check_nulib2.py's/
#: check_floppy.py's own convention (docs/NUFX.md: "the name is
#: nulib2's too").
ARC_FTYPE = 0xE0
ARC_AUX = 0x8002


def build_unpack(path):
    for src, label in [(PLAY_IMG, 'play image'), (DD_BIN, 'dd.bin')]:
        if not os.path.exists(src):
            print(f'error: missing {label}: {src}', file=sys.stderr)
            sys.exit(2)
    for src in FIXTURES:
        if not os.path.exists(src):
            print(f'error: missing fixture: {src}', file=sys.stderr)
            sys.exit(2)
    import shutil
    shutil.copyfile(PLAY_IMG, path)
    with open(DD_BIN, 'rb') as f:
        ddbin = f.read()
    prodos.mount(path)
    try:
        # dd is PLAY_EXCLUDEd (root-cap): staged at the root exactly as
        # build_dd_image.py/build_floppy_image.py/build_devblk_image.py
        # already do. nulib2/cp/ls/cmp need no staging -- all three are
        # play-image UTILS members already.
        try:                      # docs/VROOT.md: programs live in BIN
            prodos.mkdir(f'/mnt/{VOL}/BIN')
        except FileExistsError:
            pass
        prodos.write(f'/mnt/{VOL}/BIN/dd', ddbin, file_type=0x06, aux_type=0x0800,
                     overwrite=True)
        prodos.mkdir(f'/mnt/{VOL}/ARC')
        prodos.mkdir(f'/mnt/{VOL}/OUT')
        for src in FIXTURES:
            name = os.path.basename(src)
            with open(src, 'rb') as f:
                data = f.read()
            prodos.write(f'/mnt/{VOL}/ARC/{name}', data, file_type=ARC_FTYPE,
                         aux_type=ARC_AUX, overwrite=True)
            print(f'[build-unpack] staged /{VOL}/ARC/{name}: {len(data)} '
                  f'bytes')
    finally:
        prodos.unmount(VOL)
    vol = prodos.Volume(path, readonly=True)
    try:
        free, total = vol.free_blocks, vol.total_blocks
    finally:
        vol.close()
    print(f'[build-unpack] {path}: {os.path.getsize(path)} bytes, '
          f'{free}/{total} blocks free (two 140K extracts plus the '
          f'eight small-archive files need roughly 700)')


def build_unpack2(path):
    prodos.create(path, name=UNPACK2_VOLNAME, blocks=UNPACK2_BLOCKS)
    print(f'[build-unpack] {path}: {UNPACK2_BLOCKS}-block scratch volume '
          f'{UNPACK2_VOLNAME!r} (the spare disk for legs B/C)')


def main():
    build_unpack(UNPACK_IMG)
    build_unpack2(UNPACK2_IMG)
    return 0


if __name__ == '__main__':
    sys.exit(main())
