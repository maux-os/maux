#!/usr/bin/env python3
"""Build build/plasm.po -- the check-plasm gate image (plasm itself
runs on maux, docs/PLASMA-PORT.md milestone 3).

Modeled on build_plasma_image.py (M2). The play image plus:

  /bin/plasma        the seed (unchanged from M1/M2)
  /mnt/MAUX/PLRT           rt.mod, flat, syspath now "/mnt/MAUX/PLLIB/" (NOT
                        "/mnt/MAUX/PLASMA/" -- that collides case-
                        insensitively with the `plasma` util itself)
  /mnt/MAUX/PLLIB/ARGS     args.mod       )
  /mnt/MAUX/PLLIB/FILEIO   fileio.mod     ) the three loadable
  /mnt/MAUX/PLLIB/LONGJMP  longjmp.mod    ) dependencies plasm.mod names
  /mnt/MAUX/PLLIB/PLASM    plasm.mod      the compiler itself
  /mnt/MAUX/PLLIB/inc/CMDSYS.PLH
                        plasm's own lexer reads this at COMPILE TIME
                        (T.PLA's `include "inc/cmdsys.plh"` is a
                        PLASMA-language include, processed by lex.pla
                        running ON MAUX, not a host-side thing) --
                        so it must be a real file, staged relative to
                        wherever the shell's cwd is when plasm runs
                        (check_plasm.py `cd`s to /mnt/MAUX/pllib first).
  /mnt/MAUX/PLLIB/T.PLA    the trivial compile fixture

All FOUR PLLIB modules are ProDOS type $FE (REL), PLASMA's own
loadable-module convention (matches HELLO2 in build_plasma_image.py).

TEXT ENCODING, the one non-obvious part: plasm.pla's own lexer
(toolsrc/lex.pla) is UNMODIFIED upstream source and assumes plain
low-ASCII source text with bare $0D line endings -- real ProDOS/
Apple II PLASMA convention, NOT maux's own high-bit-ASCII-plus-$8D
console/file convention every other maux text file uses. `scan()`'s
whitespace/digit/etc. checks compare against literal low-ASCII byte
values (`^scanptr == ' '`, `>= '0' and <= '9'`), and `nextln()` strips
the trailing newline with an UNMASKED `== $0D` (not `& $7F`). High-bit
source would silently fail every one of those comparisons. So T.PLA
and the staged CMDSYS.PLH are written as ProDOS-standard low-ASCII
text (a2til's `convert.text_from_host`, default `high_bit=False`:
normalizes line endings to bare CR, does not set bit 7) -- the
opposite convention from every other build_*_image.py fixture in this
tree, and worth flagging because it is easy to get backwards.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos, convert  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAY_IMG = os.path.join(ROOT, 'build', 'play.po')
OUT_IMG = os.path.join(ROOT, 'build', 'plasm.po')
PLASMA_BIN = os.path.join(ROOT, 'build', 'plasma.bin')
RT_MOD = os.path.join(ROOT, 'build', 'rt.mod')
ARGS_MOD = os.path.join(ROOT, 'build', 'args.mod')
LONGJMP_MOD = os.path.join(ROOT, 'build', 'longjmp.mod')
FILEIO_MOD = os.path.join(ROOT, 'build', 'fileio.mod')
PLASM_MOD = os.path.join(ROOT, 'build', 'plasm.mod')
CMDSYS_PLH = os.path.join(ROOT, 'src', 'plasma', 'inc', 'cmdsys.plh')
VOL = 'MAUX'
LIBDIR = f'/mnt/{VOL}/PLLIB'
INCDIR = f'{LIBDIR}/inc'
RT_PATH = f'/mnt/{VOL}/PLRT'

T_PLA = (
    'include "inc/cmdsys.plh"\n'
    '\n'
    'puts("PLASM RAN\\n")\n'
    'done\n'
)


def main():
    needed = [
        (PLAY_IMG, 'play image'),
        (PLASMA_BIN, 'plasma.bin (the VM seed)'),
        (RT_MOD, 'rt.mod (make build/rt.mod)'),
        (ARGS_MOD, 'args.mod (make build/args.mod)'),
        (LONGJMP_MOD, 'longjmp.mod (make build/longjmp.mod)'),
        (FILEIO_MOD, 'fileio.mod (make build/fileio.mod)'),
        (PLASM_MOD, 'plasm.mod (make build/plasm.mod)'),
        (CMDSYS_PLH, 'src/plasma/inc/cmdsys.plh'),
    ]
    for path, label in needed:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2

    mods = {}
    for nm, pth in (('ARGS', ARGS_MOD), ('LONGJMP', LONGJMP_MOD),
                    ('FILEIO', FILEIO_MOD), ('PLASM', PLASM_MOD),
                    ('RT', RT_MOD)):
        with open(pth, 'rb') as f:
            mods[nm] = f.read()
        if nm == 'RT':
            if mods[nm][0] != 0x4C:
                print(f'error: {pth} is not a flat rt (no JMP at $2000)',
                      file=sys.stderr)
                return 2
        elif mods[nm][2:4] != b'\x02\x65':
            print(f'error: {pth} lacks the $6502 module magic',
                  file=sys.stderr)
            return 2
        elif mods[nm][10:12] == b'\x00\x00':
            print(f'error: {pth} has a zero init word', file=sys.stderr)
            return 2

    with open(PLASMA_BIN, 'rb') as f:
        seedbin = f.read()
    with open(CMDSYS_PLH, 'rb') as f:
        cmdsys_text = convert.text_from_host(f.read())
    t_pla_text = convert.text_from_host(T_PLA.encode('ascii'))

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
        prodos.write(RT_PATH, mods['RT'], file_type=0xFE,
                     aux_type=0x0000, overwrite=True)
        prodos.mkdir(LIBDIR)
        for nm in ('ARGS', 'LONGJMP', 'FILEIO', 'PLASM'):
            prodos.write(f'{LIBDIR}/{nm}', mods[nm], file_type=0xFE,
                         aux_type=0x0000, overwrite=True)
        prodos.mkdir(INCDIR)
        prodos.write(f'{INCDIR}/CMDSYS.PLH', cmdsys_text, file_type=0x04,
                     aux_type=0x0000, overwrite=True)
        prodos.write(f'{LIBDIR}/T.PLA', t_pla_text, file_type=0x04,
                     aux_type=0x0000, overwrite=True)
        names = sorted(e.name for e in prodos.scandir(LIBDIR))
        incnames = sorted(e.name for e in prodos.scandir(INCDIR))
    finally:
        prodos.unmount(VOL)
    print(f'[build-plasm] {LIBDIR} holds {names}')
    print(f'[build-plasm] {INCDIR} holds {incnames}')
    print(f'[build-plasm] {RT_PATH} staged (rt {len(mods["RT"])} B, flat)')
    print(f'[build-plasm] {OUT_IMG} ready')
    return 0


if __name__ == '__main__':
    sys.exit(main())
