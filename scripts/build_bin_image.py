#!/usr/bin/env python3
"""Build the shared utility volume (build/bin.po, volume UTILS).

A gate image used to restage every userland binary into its own boot
volume -- ~78 blocks of `ls`, `cp`, `ed`, ... duplicated across ~40 gate
images, so a single kernel byte that crossed a block boundary could
starve the LAST file a test wrote (check-v1-system's LIST1, 2026-09-04).
"Bin bytes are volume bytes." The fix (operator's call, 2026-09-04): the
binaries live ONCE, here, on a volume named UTILS under
/mnt/UTILS/BIN, which a gate mounts as a second SmartPort unit beside its boot disk and reaches by
exporting PATH=/mnt/UTILS/BIN/ in its shell (see build_v1_system_image.py's
script). The global default PATH (src/liba/pathtab.s) is left alone, so
gates that stage their own /bin are unaffected.

NOT bootable and needs no boot block: it is mounted for reading only.
`sh` itself is NOT here -- the kernel spawns it by absolute path
(/bin/sh) before any PATH search exists, so it stays on the boot
volume.
"""
import os
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_IMG = os.path.join(ROOT, 'build', 'bin.po')
VOL = 'UTILS'
VOL_BLOCKS = 280            # a 5.25" volume is plenty: the binaries are
                            # ~78 blocks and nothing is written at runtime.

# The userland binaries the shell spawns. Mirrors build_v1_system_image's
# UTIL_BINS minus `sh` (which the kernel launches by absolute path).
UTIL_BINS = [
    ('echo', 'echo.bin'),
    ('cat', 'cat.bin'),
    ('ls', 'ls.bin'),
    ('cp', 'cp.bin'),
    ('rm', 'rm.bin'),
    ('ed', 'ed.bin'),
    ('grep', 'grep.bin'),
    ('wc', 'wc.bin'),
    ('mkdir', 'mkdir.bin'),
    ('mv', 'mv.bin'),
    ('pwd', 'pwd.bin'),
    ('ps', 'ps.bin'),
]


def main():
    util_data = []
    for name, fn in UTIL_BINS:
        path = os.path.join(ROOT, 'build', fn)
        if not os.path.exists(path):
            print(f'error: missing {name} binary: {path}', file=sys.stderr)
            return 2
        with open(path, 'rb') as f:
            util_data.append((name, f.read()))

    prodos.create(OUT_IMG, name=VOL, blocks=VOL_BLOCKS)
    prodos.mount(OUT_IMG)
    prodos.mkdir(f'/mnt/{VOL}/BIN')
    for name, data in util_data:
        prodos.write(f'/mnt/{VOL}/BIN/{name}', data, file_type=0x06,
                     aux_type=0x0800, overwrite=True)

    sizes = ', '.join(f'{n} ({len(d)} bytes)' for n, d in util_data)
    print(f'[build-bin] wrote /mnt/{VOL}/BIN: {sizes}')
    print(f'[build-bin] {OUT_IMG} ready ({os.path.getsize(OUT_IMG)} bytes)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
