#!/usr/bin/env python3
"""Build the ProDOS-hosted seek-family gate image (`make check-seek`).

Companion to src/test/seektest.s / src/test/seektestb.s /
src/test/seekwr.s / scripts/check_seek.py. Same shape as
build_sh_image.py -- a fresh carrier volume, PRODOS + the
MAUXSEEK.SYSTEM harness + the real SEEKWR/SH/ECHO userland binaries +
a staged sh script, as files.

Phase A (docs/FLEET.md "`>>` and the seek family"): SEEKWR exercises
liba's own LSEEK (SEEK_SET/SEEK_CUR/SEEK_END) and writes its
independently GET_MARK-verified results to /mnt/MAUX/SEEKRES.

Phase B: sh, spawned with fd 0 redirected from the staged
/mnt/MAUX/SEEKSCRIPT, runs `ECHO A > /mnt/MAUX/APPF` then
`ECHO B >> /mnt/MAUX/APPF` -- APPF must hold BOTH lines afterward, in
order, proving `>>` does not truncate what `>` already wrote.
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
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXSEEK.SYSTEM')
SEEKWR_BIN = os.path.join(ROOT, 'build', 'seekwr.bin')
SH_BIN = os.path.join(ROOT, 'build', 'sh.bin')
ECHO_BIN = os.path.join(ROOT, 'build', 'echo.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'seek.po')

# sh's own documented input convention (docs/SH-DESIGN.md / build_sh_image.py):
# high-bit-set text, CR ($8D) line endings, command words UPPERCASE.
SCRIPT_TEXT = (
    'ECHO A > /mnt/MAUX/APPF\r'
    'ECHO B >> /mnt/MAUX/APPF\r'
    'EXIT\r'
)
SCRIPT_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D for c in SCRIPT_TEXT)

# echo's own documented contract (one trailing CR, high-bit-set) --
# scripts/check_seek.py's source of truth for what APPF must hold
# after BOTH redirects.
EXPECT_APPF = bytes([0xC1, 0x8D, 0xC2, 0x8D])          # "A"+CR+"B"+CR

# The three marks SEEKWR (src/test/seekwr.s) independently re-verifies
# with a raw GET_MARK after LSEEK(fd,3,SEEK_SET),
# LSEEK(fd,2,SEEK_CUR), LSEEK(fd,0,SEEK_END) on a freshly-written
# 10-byte file -- see that file's own header for the arithmetic.
EXPECT_SET_MARK = (3, 0, 0)
EXPECT_CUR_MARK = (5, 0, 0)
EXPECT_END_MARK = (10, 0, 0)
EXPECT_ERRFLAGS = 0


def main():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXSEEK.SYSTEM'),
        (SEEKWR_BIN, 'seekwr userland binary'),
        (SH_BIN, 'sh userland binary'),
        (ECHO_BIN, 'echo userland binary'),
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
    with open(SEEKWR_BIN, 'rb') as f:
        seekwr = f.read()
    with open(SH_BIN, 'rb') as f:
        shbin = f.read()
    with open(ECHO_BIN, 'rb') as f:
        echobin = f.read()

    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    try:                      # docs/VROOT.md: programs live in BIN
        prodos.mkdir(f'{root}/BIN')
    except FileExistsError:
        pass
    prodos.write(f'{root}/BIN/SEEKWR', seekwr, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/SH', shbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/ECHO', echobin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/SEEKSCRIPT', SCRIPT_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.unmount(CARRIER_VOL)

    print(f'[build-seek] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-seek] kept={kept} removed={removed}')
    print(f'[build-seek] wrote MAUX.SYSTEM ({len(system)} bytes), '
          f'SEEKWR ({len(seekwr)} bytes), SH ({len(shbin)} bytes), '
          f'ECHO ({len(echobin)} bytes), SEEKSCRIPT ({len(SCRIPT_BYTES)} '
          f'bytes)')
    print(f'[build-seek] {OUT_IMG} ready ({os.path.getsize(OUT_IMG)} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
