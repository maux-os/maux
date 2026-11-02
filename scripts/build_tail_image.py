#!/usr/bin/env python3
"""Build the ProDOS-hosted `tail` acceptance-gate image (`make
check-tail`).

Companion to src/test/tailtest.s / src/test/tailtestb.s /
scripts/check_tail.py -- same shape as scripts/build_catread_image.py
(a real userland binary spawned from disk with fds redirected to real
ProDOS files, byte-exact comparison), extended to SIX spawns: default
N=10, -3, -20 (more than the file has), an empty file, a file whose
last line lacks a trailing CR, and reading from fd 0.

Every expected-output constant below is derived BY HAND from the
fixture content this module itself writes -- never by running tail
and recording its output (that would enshrine bugs as the contract).
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
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXTAIL.SYSTEM')
TAIL_BIN = os.path.join(ROOT, 'build', 'tail.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'tail.po')


def hitext(s):
    return bytes(ord(c) | 0x80 for c in s)


CR = bytes([0x8D])

# -- TAILSRC: 15 CR-terminated lines, L01..L15. Chosen short/unique
# so a wrong-line-selected failure is obvious by inspection.
TAILSRC_LINES = [f'L{i:02d}' for i in range(1, 16)]
TAILSRC_BYTES = b''.join(hitext(l) + CR for l in TAILSRC_LINES)

# -- TAILMT: empty file.
TAILMT_BYTES = b''

# -- TAILNOCR: 5 lines, A1..A5 -- every line but the last CR-
# terminated; A5 has NO trailing CR (EOF hits right after it).
NOCR_LINES = ['A1', 'A2', 'A3', 'A4', 'A5']
TAILNOCR_BYTES = (b''.join(hitext(l) + CR for l in NOCR_LINES[:-1])
                  + hitext(NOCR_LINES[-1]))

# -- Hand-derived expectations (see tail.s's own header for the
# output-normalization policy RUN5 exercises: every printed line
# gets a CR appended, whether or not the SOURCE line had one).
EXPECT_RUN1 = b''.join(hitext(l) + CR for l in TAILSRC_LINES[5:15])   # L06..L15
EXPECT_RUN2 = b''.join(hitext(l) + CR for l in TAILSRC_LINES[12:15]) # L13..L15
EXPECT_RUN3 = TAILSRC_BYTES                                          # all 15 (-20 > 15)
EXPECT_RUN4 = b''
EXPECT_RUN5 = hitext('A4') + CR + hitext('A5') + CR                  # normalized
EXPECT_RUN6 = EXPECT_RUN1                                            # fd 0, same src

EXPECT_STATUS = 0  # tail always exits 0 on these paths


def main():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXTAIL.SYSTEM'),
        (TAIL_BIN, 'tail userland binary'),
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
    with open(TAIL_BIN, 'rb') as f:
        tailbin = f.read()

    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    try:                      # docs/VROOT.md: programs live in BIN
        prodos.mkdir(f'{root}/BIN')
    except FileExistsError:
        pass
    prodos.write(f'{root}/BIN/TAIL', tailbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/TAILSRC', TAILSRC_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/TAILMT', TAILMT_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/TAILNOCR', TAILNOCR_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.unmount(CARRIER_VOL)

    print(f'[build-tail] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-tail] kept={kept} removed={removed}')
    print(f'[build-tail] wrote MAUX.SYSTEM ({len(system)} bytes), '
          f'TAIL ({len(tailbin)} bytes), TAILSRC ({len(TAILSRC_BYTES)} '
          f'bytes), TAILMT ({len(TAILMT_BYTES)} bytes), TAILNOCR '
          f'({len(TAILNOCR_BYTES)} bytes)')
    print(f'[build-tail] {OUT_IMG} ready ({os.path.getsize(OUT_IMG)} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
