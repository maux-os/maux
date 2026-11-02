#!/usr/bin/env python3
"""Build the docs/PROCIO.md sec 6 gates (c)/(d) ProDOS-hosted image.

Companion to src/test/bufiotest.s / src/test/bufiotestb.s /
src/test/bufwriter.s / scripts/check_bufio.py. Same shape as
build_catread_image.py -- a fresh carrier volume, PRODOS + the
MAUXBUFIO.SYSTEM harness + the real BUFWR userland binary staged as
files.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CARRIER_IMG = os.environ.get('PRODOS_CARRIER_IMG',
                             os.path.join(ROOT, 'vendor', 'prodos-basic.po'))
CARRIER_VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')
KERNEL_BIN = os.environ.get('PRODOS_KERNEL_BIN',
                            os.path.join(ROOT, 'vendor', 'ProDOS-2.4.bin'))
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXBUFIO.SYSTEM')
BUFWR_BIN = os.path.join(ROOT, 'build', 'bufwriter.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'bufio.po')

# Same literal PUTC writes, high-bit-set (src/test/bufwriter.s's own
# PAYLOAD, merlin32's double-quoted ASC convention -- verified against
# build/cat.bin's own ERRMSG bytes before relying on it here).
PAYLOAD_TEXT = 'BFWRT'
PAYLOAD_BYTES = bytes((ord(c) | 0x80) for c in PAYLOAD_TEXT)


def main():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXBUFIO.SYSTEM'),
        (BUFWR_BIN, 'bufwriter userland binary'),
    ]:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2

    shutil.copyfile(CARRIER_IMG, OUT_IMG)
    prodos.mount(OUT_IMG)
    root = f'/mnt/{CARRIER_VOL}'
    removed = []
    kept = []

    def rm_recursive(path, entry):
        if entry.is_dir():
            for child in list(prodos.scandir(path)):
                rm_recursive(f'{path}/{child.name}', child)
            prodos.rmdir(path)
        else:
            prodos.remove(path)

    for entry in list(prodos.scandir(root)):
        if entry.name.upper() == 'PRODOS':
            kept.append(entry.name)
            continue
        rm_recursive(f'{root}/{entry.name}', entry)
        removed.append(entry.name)

    with open(KERNEL_BIN, 'rb') as f:
        kernel = f.read()
    with open(SYS_BIN, 'rb') as f:
        system = f.read()
    with open(BUFWR_BIN, 'rb') as f:
        bufwr = f.read()

    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    try:                      # docs/VROOT.md: programs live in BIN
        prodos.mkdir(f'{root}/BIN')
    except FileExistsError:
        pass
    prodos.write(f'{root}/BIN/BUFWR', bufwr, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.unmount(CARRIER_VOL)

    print(f'[build-bufio] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-bufio] kept={kept} removed={removed}')
    print(f'[build-bufio] wrote MAUX.SYSTEM ({len(system)} bytes), '
          f'BUFWR ({len(bufwr)} bytes)')
    print(f'[build-bufio] {OUT_IMG} ready ({os.path.getsize(OUT_IMG)} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
