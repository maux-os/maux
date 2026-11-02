#!/usr/bin/env python3
"""build_jobctl_image.py -- build/jobctl.po for `make check-jobctl-b`
(docs/JOB-CONTROL.md Increment B).

A CLONE of build/play.po (the real kernel + shell + every util, the
image whose playtest.s installs the ^C AND ^Z sweeps) with ONE file
added: src/test/jctest.s's binary at /bin/JCTEST. It is a
gate-only harness, not a utility -- staging it on play.po itself would
put it in the Makefile's UTILS roster (check_manifests CHECK 7) and
in the `LS BIN` listing check-play asserts on, for a program no human
runs. The clone costs one ProDOS write.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAY_IMG = os.path.join(ROOT, 'build', 'play.po')
JCTEST_BIN = os.path.join(ROOT, 'build', 'jctest.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'jobctl.po')
VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')


def main():
    for path, label in ((PLAY_IMG, 'play image (run make play-image)'),
                        (JCTEST_BIN, 'jctest.bin (src/test/jctest.s)')):
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2
    shutil.copyfile(PLAY_IMG, OUT_IMG)
    with open(JCTEST_BIN, 'rb') as f:
        data = f.read()
    prodos.mount(OUT_IMG)
    try:
        try:                      # docs/VROOT.md: programs live in BIN
            prodos.mkdir(f'/mnt/{VOL}/BIN')
        except FileExistsError:
            pass
        prodos.write(f'/mnt/{VOL}/BIN/JCTEST', data, file_type=0x06,
                     aux_type=0x0800, overwrite=True)
    finally:
        prodos.unmount(VOL)
    print(f'[build-jobctl] {OUT_IMG}: play.po + /BIN/JCTEST '
          f'({len(data)} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
