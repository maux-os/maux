#!/usr/bin/env python3
"""Build the ProDOS-hosted `diff` acceptance-gate image
(`make check-diff`).

Companion to src/test/difftest.s / difftestb.s / scripts/check_diff.py.
Same shape as scripts/build_fleet_image.py: stage input files + the
`diff`/`ed` userland binaries onto a carrier volume copy, boot a
hardwired parent process that spawns `diff` directly, ten times (one
per required contract shape: identical / pure addition / pure deletion
/ single change / multiple hunks / change at line 1 / change at the
last line / one file empty / overflow / -e), each with its relevant fd
dup'd to a captured output file, plus one more spawn of `ed` to prove
the diff-e-then-ed round trip.

Every expected output byte string below is DERIVED BY HAND from
diff.s's own documented algorithm (LCS dynamic programming, backtrace
tie-break "prefer INS on a tie" -- see diff.s's BACKTRACE header) --
never by running diff and recording what came out. That is the whole
point of this gate for a diff implementation: the output IS where the
bugs live.
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
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXDIFFTEST.SYSTEM')
DIFF_BIN = os.path.join(ROOT, 'build', 'diff.bin')
ED_BIN = os.path.join(ROOT, 'build', 'ed.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'difftest.po')


def hitext(s):
    return bytes(ord(c) | 0x80 for c in s)


CR = bytes([0x8D])


def hilines(*lines):
    return b''.join(hitext(l) + CR for l in lines)


# ---------------------------------------------------------------------
# Staged input files -- high-bit ASCII, $8D CR line endings (liba's own
# convention, same as every other util's staged input in this tree).
# ---------------------------------------------------------------------
A1 = hilines('ONE', 'TWO', 'THREE')
B1 = A1                                        # case 1: identical

A2 = hilines('ONE', 'TWO')
B2 = hilines('ONE', 'TWO', 'THREE')             # case 2: pure addition

A3 = hilines('ONE', 'TWO', 'THREE')
B3 = hilines('ONE', 'TWO')                      # case 3: pure deletion

A4 = hilines('ONE', 'TWO', 'THREE')
B4 = hilines('ONE', 'TWOX', 'THREE')            # case 4: single change

A5 = hilines('ONE', 'TWO', 'THREE', 'FOUR', 'FIVE')
B5 = hilines('ONE', 'TWOX', 'THREE', 'FOURX', 'FIVE')  # case 5: 2 hunks

A6 = hilines('ONE', 'TWO', 'THREE')
B6 = hilines('ONEX', 'TWO', 'THREE')            # case 6: change at line 1

A7 = hilines('ONE', 'TWO', 'THREE')
B7 = hilines('ONE', 'TWO', 'THREEX')            # case 7: change at last line

A8 = hilines('ONE', 'TWO', 'THREE')
B8 = b''                                        # case 8: B empty

# case 9: overflow trigger. (NA+1)*(NB+1) must exceed diff.s's
# DP_MAX_BYTES=10000 while both stay under MAXLINES=120 -- 110 lines
# each side (111*111=12321>10000), distinct content on each side so
# there is no shortcut (content is irrelevant to the trigger -- the
# DPCHECK cap fires on NA/NB alone, before any line is even compared,
# see diff.s's own header -- but distinct content keeps this file
# honest as a real "two big different files" case, not a contrived
# edge).
A9 = hilines(*[f'A9LINE{n:03d}' for n in range(1, 111)])
B9 = hilines(*[f'B9LINE{n:03d}' for n in range(1, 111)])

# case 10: -e round trip. Reuses A5/B5 (the two-hunk case) -- the
# richer shape is the stronger proof.


# ---------------------------------------------------------------------
# EXPECTED outputs -- THE CONTRACT, derived by hand from diff.s's
# documented LCS/backtrace algorithm (see file header), never by
# running diff.bin.
# ---------------------------------------------------------------------
EXPECT_OUT1 = b''                               # identical -- no output
EXPECT_STATUS1 = 0

EXPECT_OUT2 = hilines('2a3') + hilines('> THREE')
EXPECT_STATUS2 = 1

EXPECT_OUT3 = hilines('3d2') + hilines('< THREE')
EXPECT_STATUS3 = 1

EXPECT_OUT4 = (hilines('2c2') + hilines('< TWO') + hilines('---') +
               hilines('> TWOX'))
EXPECT_STATUS4 = 1

EXPECT_OUT5 = (
    hilines('2c2') + hilines('< TWO') + hilines('---') + hilines('> TWOX') +
    hilines('4c4') + hilines('< FOUR') + hilines('---') + hilines('> FOURX')
)
EXPECT_STATUS5 = 1

EXPECT_OUT6 = (hilines('1c1') + hilines('< ONE') + hilines('---') +
               hilines('> ONEX'))
EXPECT_STATUS6 = 1

EXPECT_OUT7 = (hilines('3c3') + hilines('< THREE') + hilines('---') +
               hilines('> THREEX'))
EXPECT_STATUS7 = 1

EXPECT_OUT8 = (hilines('1,3d0') + hilines('< ONE') + hilines('< TWO') +
               hilines('< THREE'))
EXPECT_STATUS8 = 1

EXPECT_STATUS9 = 2
EXPECT_STDERR9 = hitext('diff: input too large') + CR

# -e output for A5/B5 -- hunks in REVERSE order (4 before 2), each
# just "<range>c" (no right-hand side -- ed doesn't need one), then
# the replacement text verbatim (no "> " prefix), then a lone ".".
EXPECT_OUTE = (
    hilines('4c') + hilines('FOURX') + hilines('.') +
    hilines('2c') + hilines('TWOX') + hilines('.')
)
EXPECT_ESTATUS = 1

# The round trip's result: `ed` replays that script against A5 and
# writes RESULT -- must equal B5 byte-exact.
EXPECT_RESULT = B5
EXPECT_EDSTATUS = 0


def main():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXDIFFTEST.SYSTEM'),
        (DIFF_BIN, 'diff userland binary'),
        (ED_BIN, 'ed userland binary'),
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
    with open(DIFF_BIN, 'rb') as f:
        diffbin = f.read()
    with open(ED_BIN, 'rb') as f:
        edbin = f.read()

    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    try:                      # docs/VROOT.md: programs live in BIN
        prodos.mkdir(f'{root}/BIN')
    except FileExistsError:
        pass
    prodos.write(f'{root}/BIN/DIFF', diffbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/ED', edbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)

    inputs = {
        'A1': A1, 'B1': B1, 'A2': A2, 'B2': B2, 'A3': A3, 'B3': B3,
        'A4': A4, 'B4': B4, 'A5': A5, 'B5': B5, 'A6': A6, 'B6': B6,
        'A7': A7, 'B7': B7, 'A8': A8, 'B8': B8, 'A9': A9, 'B9': B9,
    }
    for name, data in inputs.items():
        prodos.write(f'{root}/{name}', data, file_type=0x04, aux_type=0x0000,
                     overwrite=True)

    prodos.unmount(CARRIER_VOL)

    print(f'[build-diff] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-diff] kept={kept} removed={removed}')
    print(f'[build-diff] wrote MAUX.SYSTEM ({len(system)}B), DIFF '
          f'({len(diffbin)}B), ED ({len(edbin)}B), '
          f'{len(inputs)} input files')
    print(f'[build-diff] {OUT_IMG} ready ({os.path.getsize(OUT_IMG)} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
