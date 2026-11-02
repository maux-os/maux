#!/usr/bin/env python3
"""Build the check-df gate images (docs/DU-DF.md).

  build/df.po      -- the play image (unit 1, boot volume BASIC),
      copied from build/play.po (`make play-image` builds it).
  build/df2.po     -- a freshly created ProDOS volume SCRATCH (unit 2,
      280 blocks): a second row for `df`, and the volume the gate
      WRITES to, so BASIC's numbers never move under it.
  build/df_flop.do -- the DOS 3.3 XMASADV floppy for slot 6, mounted
      only to prove `df` never polls a Disk ][ (disk2_state counters).

Same shape as build_devfs_image.py, under its OWN names: the box sweep
runs check-devfs in a lane of its own, and a shared SCRATCH image that
check-df writes to would race it.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos, nufx  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAY_IMG = os.path.join(ROOT, 'build', 'play.po')
OUT_IMG = os.path.join(ROOT, 'build', 'df.po')
OUT_IMG2 = os.path.join(ROOT, 'build', 'df2.po')
FLOPPY_OUT = os.path.join(ROOT, 'build', 'df_flop.do')
XMASADV_PATH = os.path.join(ROOT, 'fixtures', 'gem', 'XMASADV.SDK')
SCRATCH_VOL = 'SCRATCH'
SCRATCH_BLOCKS = 280


def main():
    for path, label in [(PLAY_IMG, 'play image (run `make play-image`)'),
                        (XMASADV_PATH, 'XMASADV.SDK')]:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2
    shutil.copyfile(PLAY_IMG, OUT_IMG)
    if os.path.exists(OUT_IMG2):
        os.remove(OUT_IMG2)
    prodos.create(OUT_IMG2, name=SCRATCH_VOL, blocks=SCRATCH_BLOCKS)
    with nufx.NufxArchive(XMASADV_PATH) as arc:
        rec = arc.disk_record
        if rec is None:
            print(f'error: {XMASADV_PATH}: no single disk record',
                  file=sys.stderr)
            return 2
        img = rec.read()
    with open(FLOPPY_OUT, 'wb') as f:
        f.write(img)
    print(f'[build-df] {OUT_IMG} (BASIC, unit 1), {OUT_IMG2} '
          f'({SCRATCH_VOL}, {SCRATCH_BLOCKS} blocks, unit 2), '
          f'{FLOPPY_OUT} ({len(img)} bytes, slot 6)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
