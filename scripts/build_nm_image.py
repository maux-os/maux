#!/usr/bin/env python3
"""Build the ProDOS-hosted `nm` acceptance-gate image (`make check-nm`).

Companion to src/test/nmtest.s / src/test/nmtestb.s / scripts/check_nm.py.
Same carrier-volume shape as scripts/build_sh_image.py: stage the parent
SYSTEM program, `sh`, `nm`, two REAL REL object files, and a script `sh`
runs from fd 0.

THE REL FILES ARE REAL, NOT SYNTHESIZED. RTLIB/RTMAIN below are the exact
on-disk bytes real Merlin-8 2.59 wrote for src/relspike/RTLIB.S and
RTMAIN.S (docs/REL-LIBA-SPIKE.md's own spike modules; `make check-rel`
assembles and links them, but never persists the standalone .REL objects
anywhere reusable). Captured 2026-08-21 by booting build/rel.po (`make
rel-image`) under verilogapple's fast backend, typing `ASM` against each
source file (each source's own `DSK /SOURCE/RTLIB`/`DSK /SOURCE/RTMAIN`
line saves the REL object as a side effect -- see scripts/check_rel.py's
own assemble() for the identical drive sequence), then reading /SOURCE/
RTLIB and /SOURCE/RTMAIN back off that disk image with a2til. Reproducible
by anyone: `make rel-image`, drive the same ASM sequence, read the two
files back -- the bytes will match, because src/relspike/RTLIB.S and
RTMAIN.S have not changed since.

nm.s's own header derives the dictionary byte layout these constants
encode from these SAME two files (RTLIB is 68 code bytes + a 24-byte
dictionary: ENT LIBUSED at offset 0, ENT LIBUNUSED at offset 3; RTMAIN is
4 code bytes + a 16-byte dictionary: EXT LIBUSED, one reference). This
module's EXPECT_* constants below are derived BY HAND from that same
layout -- not by running nm and recording its output.
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
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXNM.SYSTEM')
SH_BIN = os.path.join(ROOT, 'build', 'sh.bin')
NM_BIN = os.path.join(ROOT, 'build', 'nm.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'nm.po')

# -- REAL Merlin-8 2.59 REL objects -- see module header for provenance.
# Captured verbatim off build/rel.po as one contiguous hex dump (not
# hand-reassembled from smaller pieces, to avoid a transcription slip):
#
#   RTLIB  (92B = 68 code + 24 dictionary): LDA #$11/RTS (LIBUSED, 3B),
#   16x $DEADBEEF + RTS (LIBUNUSED, 65B), then the dictionary -- empty
#   fixup list ($00), ENT "LIBUSED" at offset $0000, ENT "LIBUNUSED" at
#   offset $0003, end-of-dictionary ($00). nm.s's header derives its
#   dictionary byte layout from exactly these bytes.
#   RTMAIN (20B = 4 code + 16 dictionary): JSR $8000/RTS, one fixup
#   record (offset 1, refnum 0), EXT "LIBUSED" (refnum 0 placeholder),
#   end-of-dictionary.
RTLIB_REL = bytes.fromhex(
    'a91160deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
    'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbe'
    'efdeadbeef600047'
    '4c4942555345440080494c4942554e5553454403'
    '8000'
)
RTMAIN_REL = bytes.fromhex(
    '200080609f01000000874c494255534544008000'
)
assert len(RTLIB_REL) == 92, f'RTLIB_REL: expected 92B, got {len(RTLIB_REL)}'
assert len(RTMAIN_REL) == 20, f'RTMAIN_REL: expected 20B, got {len(RTMAIN_REL)}'


def hitext(s):
    return bytes(ord(c) | 0x80 for c in s)


CR = bytes([0x8D])

# -- The script `sh` runs from fd 0 (staged as /mnt/MAUX/SCRIPT). --
SCRIPT_TEXT = (
    'NM /mnt/MAUX/RTLIB > /mnt/MAUX/NM1OUT\r'
    'NM /mnt/MAUX/RTLIB /mnt/MAUX/RTMAIN > /mnt/MAUX/NM2OUT\r'
    'NM -u /mnt/MAUX/RTMAIN > /mnt/MAUX/NM3OUT\r'
    'NM -g /mnt/MAUX/RTMAIN > /mnt/MAUX/NM4OUT\r'
    'NM -u /mnt/MAUX/RTLIB > /mnt/MAUX/NM5OUT\r'
    'NM -g /mnt/MAUX/RTLIB > /mnt/MAUX/NM6OUT\r'
    'EXIT\r'
)
SCRIPT_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                     for c in SCRIPT_TEXT)


def main():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXNM.SYSTEM'),
        (SH_BIN, 'sh userland binary'),
        (NM_BIN, 'nm userland binary'),
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
    with open(SH_BIN, 'rb') as f:
        shbin = f.read()
    with open(NM_BIN, 'rb') as f:
        nmbin = f.read()

    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    try:                      # docs/VROOT.md: programs live in BIN
        prodos.mkdir(f'{root}/BIN')
    except FileExistsError:
        pass
    prodos.write(f'{root}/BIN/SH', shbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/NM', nmbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/RTLIB', RTLIB_REL, file_type=0xF8, aux_type=68,
                 overwrite=True)
    prodos.write(f'{root}/RTMAIN', RTMAIN_REL, file_type=0xF8, aux_type=4,
                 overwrite=True)
    prodos.write(f'{root}/SCRIPT', SCRIPT_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.unmount(CARRIER_VOL)

    print(f'[build-nm] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-nm] kept={kept} removed={removed}')
    print(f'[build-nm] wrote MAUX.SYSTEM ({len(system)}B), SH '
          f'({len(shbin)}B), NM ({len(nmbin)}B), RTLIB '
          f'({len(RTLIB_REL)}B), RTMAIN ({len(RTMAIN_REL)}B)')
    print(f'[build-nm] {OUT_IMG} ready ({os.path.getsize(OUT_IMG)} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
