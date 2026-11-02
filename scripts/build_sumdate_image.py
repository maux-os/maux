#!/usr/bin/env python3
"""Build the `sum`/`date` acceptance-gate image (`make check-sumdate`).

Companion to src/test/sumdatetest.s / sumdatetestb.s /
scripts/check_sumdate.py. Same shape as scripts/build_fleet_image.py:
stage input files + the two userland binaries onto a carrier volume
copy; the hardwired parent process (sumdatetestb.s) spawns `sum` and
`date` directly (no `sh`) and this script's own EXPECT_* values are
what scripts/check_sumdate.py asserts against.

`sum`'s expected checksums/block counts are computed HERE, in Python,
from the SAME bytes staged below -- independent of the 6502 rotate
implementation (task brief's own requirement: the expectation must not
be derived by running the code under test).
"""
import os
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
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXSUMDT.SYSTEM')
SUM_BIN = os.path.join(ROOT, 'build', 'sum.bin')
DATE_BIN = os.path.join(ROOT, 'build', 'date.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'sumdate.po')


def hitext(s):
    return bytes(ord(c) | 0x80 for c in s)


CR = bytes([0x8D])
SP = hitext(' ')

# ---------------------------------------------------------------------
# Staged input files -- an empty file, a one-byte file, and a file
# crossing a 512-byte ProDOS block boundary (600 bytes -> 2 blocks),
# all summed in ONE invocation (task brief: cover all four cases --
# empty, one-byte, block-boundary-crossing, multiple files -- and a
# multi-file invocation naturally covers all three of the others too).
# ---------------------------------------------------------------------
EMPTY_BYTES = b''
ONE_BYTES = bytes([0x42])
BLOCKSZ = 512
BIG_BYTES = bytes((i * 7 + 3) & 0xFF for i in range(600))


def v6sum(data):
    """The rotate-and-add checksum src/bin/sum.s implements (its own
    header states the variant): rotate the 16-bit accumulator right
    ONE bit (bit 0 wraps into bit 15) before adding each byte, mod
    65536. Independent Python implementation -- not derived from the
    6502 code, per this gate's own requirement."""
    cksum = 0
    for b in data:
        cksum = (cksum >> 1) | ((cksum & 1) << 15)
        cksum = (cksum + b) & 0xFFFF
    return cksum


def v6blocks(nbytes):
    return (nbytes + BLOCKSZ - 1) // BLOCKSZ


def sumline(data, name):
    cksum = v6sum(data)
    blocks = v6blocks(len(data))
    return (hitext(f'{cksum:05d}') + SP + hitext(str(blocks)) + SP +
            hitext(name) + CR)


# Sanity: a plain (non-rotating) sum must NOT agree with v6sum on a
# multi-byte file, or sabotage 1 (breaking the rotate) would be
# invisible to this gate. Asserted at build time, not just hoped for.
def plainsum(data):
    s = 0
    for b in data:
        s = (s + b) & 0xFFFF
    return s


assert v6sum(BIG_BYTES) != plainsum(BIG_BYTES), (
    'BIG_BYTES does not distinguish the rotate from a plain sum -- '
    'sabotage 1 would go undetected; pick different content')

EXPECT_SUMOUT = (
    sumline(EMPTY_BYTES, '/mnt/MAUX/EMPTY') +
    sumline(ONE_BYTES, '/mnt/MAUX/ONE') +
    sumline(BIG_BYTES, '/mnt/MAUX/BIG')
)


def main():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXSUMDT.SYSTEM'),
        (SUM_BIN, 'sum userland binary'),
        (DATE_BIN, 'date userland binary'),
    ]:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2

    import shutil
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
    with open(SUM_BIN, 'rb') as f:
        sumbin = f.read()
    with open(DATE_BIN, 'rb') as f:
        datebin = f.read()

    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    try:                      # docs/VROOT.md: programs live in BIN
        prodos.mkdir(f'{root}/BIN')
    except FileExistsError:
        pass
    prodos.write(f'{root}/BIN/SUM', sumbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/DATE', datebin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)

    prodos.write(f'{root}/EMPTY', EMPTY_BYTES, file_type=0x06,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/ONE', ONE_BYTES, file_type=0x06,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/BIG', BIG_BYTES, file_type=0x06,
                 aux_type=0x0000, overwrite=True)
    prodos.unmount(CARRIER_VOL)

    print(f'[build-sumdate] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-sumdate] kept={kept} removed={removed}')
    print(f'[build-sumdate] wrote MAUXSUMDT.SYSTEM ({len(system)}B), SUM '
          f'({len(sumbin)}B), DATE ({len(datebin)}B)')
    print(f'[build-sumdate] EMPTY=0B ONE=1B BIG={len(BIG_BYTES)}B '
          f'(blocks {v6blocks(len(BIG_BYTES))})')
    print(f'[build-sumdate] {OUT_IMG} ready '
          f'({os.path.getsize(OUT_IMG)} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
