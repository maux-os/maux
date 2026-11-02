#!/usr/bin/env python3
"""Build build/plasma.po -- the check-plasma gate image (the native
PLASMA VM seed, docs/PLASMA-PORT.md milestone 1).

The play image (which stages `plasma`, the VM seed, alongside `sh`)
plus /mnt/MAUX/P/HELLO: build/hello.mod, the compiled PLASMA module
(src/test/plasma/hello.pla, built by the Makefile's hello.mod rule
with the sibling-repo xplasm + acme, image base $2000). It is a
self-contained module -- no dependencies, no library -- whose init
routine calls one inline-asm function that does a raw maux WRITE
syscall of "HELLO FROM PLASMA ON MAUX" to fd 1.

check_plasma.py types `plasma /mnt/MAUX/p/hello` and scrapes that line
plus the exit status. Staged as ProDOS type $FE (REL), PLASMA's own
convention for a module; the seed does not check the type.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAY_IMG = os.path.join(ROOT, 'build', 'play.po')
OUT_IMG = os.path.join(ROOT, 'build', 'plasma.po')
PLASMA_BIN = os.path.join(ROOT, 'build', 'plasma.bin')
RT_MOD = os.path.join(ROOT, 'build', 'rt.mod')
HELLO2_MOD = os.path.join(ROOT, 'build', 'hello2.mod')
VOL = 'MAUX'
SUBDIR = f'/mnt/{VOL}/P'
RT_PATH = f'/mnt/{VOL}/PLRT'    # the seed loads this root file


def main():
    for path, label in [(PLAY_IMG, 'play image'),
                        (PLASMA_BIN, 'plasma.bin (the VM seed)'),
                        (RT_MOD, 'rt.mod (make build/rt.mod)'),
                        (HELLO2_MOD, 'hello2.mod (make build/hello2.mod)')]:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2
    mods = {}
    for nm, pth in (('HELLO2', HELLO2_MOD), ('RT', RT_MOD)):
        with open(pth, 'rb') as f:
            mods[nm] = f.read()
        # HELLO/HELLO2 are relocatable modules ($6502 magic at :2);
        # RT is the FLAT bootstrap (-AOW --setpc 8192) -- it begins
        # with JMP _INIT ($4C) at $2000 and carries no magic, so the
        # seed raw-loads and JMPs it. Check accordingly.
        if nm == 'RT':
            if mods[nm][0] != 0x4C:
                print(f'error: {pth} is not a flat rt (no JMP at $2000)',
                      file=sys.stderr)
                return 2
        elif mods[nm][2:4] != b'\x02\x65':
            print(f'error: {pth} lacks the $6502 module magic',
                  file=sys.stderr)
            return 2
    with open(PLASMA_BIN, 'rb') as f:
        seedbin = f.read()
    shutil.copyfile(PLAY_IMG, OUT_IMG)
    prodos.mount(OUT_IMG)
    try:
        # plasma is PLAY_EXCLUDEd from the shared image (root-cap); stage
        # the seed itself here, as build_play_image stages a util.
        try:                      # docs/VROOT.md: programs live in BIN
            prodos.mkdir(f'/mnt/{VOL}/BIN')
        except FileExistsError:
            pass
        prodos.write(f'/mnt/{VOL}/BIN/plasma', seedbin, file_type=0x06,
                     aux_type=0x0800, overwrite=True)
        prodos.mkdir(SUBDIR)
        prodos.write(f'{SUBDIR}/HELLO2', mods['HELLO2'], file_type=0xFE,
                     aux_type=0x0000, overwrite=True)
        prodos.write(RT_PATH, mods['RT'], file_type=0xFE,
                     aux_type=0x0000, overwrite=True)
        names = sorted(e.name for e in prodos.scandir(SUBDIR))
    finally:
        prodos.unmount(VOL)
    print(f'[build-plasma] {SUBDIR} holds {names}; '
          f'{RT_PATH} staged (rt {len(mods["RT"])} B, flat)')
    print(f'[build-plasma] {OUT_IMG} ready')
    return 0


if __name__ == '__main__':
    sys.exit(main())
