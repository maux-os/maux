#!/usr/bin/env python3
"""Build build/nas.po -- the check-nas gate image (docs/AS-PLASMA.md
L0: nas, a native maux assembler written in PLASMA, runs on maux).

Modeled directly on build_plasm_image.py. The play image plus:

  /bin/plasma         the seed (unchanged from M1/M2/M3)
  /mnt/MAUX/PLRT            rt.mod, flat, syspath "/mnt/MAUX/PLLIB/"
  /mnt/MAUX/PLLIB/ARGS      args.mod      )
  /mnt/MAUX/PLLIB/FILEIO    fileio.mod    ) nas.mod's two loadable deps
  /mnt/MAUX/PLLIB/NAS       nas.mod       the modular assembler
  /mnt/MAUX/PLLIB/NCUT      nas.cut       the cooked assembler executable
  /mnt/MAUX/PLLIB/FIXTURE.S the L0 fixture source (src/test/asm/fixture.s)
  /mnt/MAUX/PLLIB/STRESS.S  the L1a stress fixture (src/test/asm/stress.s)
  /mnt/MAUX/PLLIB/LOCAL.S   the :local fixture (src/test/asm/local.s)
  /mnt/MAUX/PLLIB/L2B.S     the L2 fixture (src/test/asm/l2b.s, task #21:
                         DUM/DEND, ERR, `.`/`!`/`&`, DSK)

nas.mod is an ordinary relocatable PLASMA module (-AMOW, --setpc 8190,
RELADDR $2000) -- built exactly like ARGS/FILEIO/PLASM, NOT flat like
rt. It needs no inc/*.plh staged on the DISK (unlike plasm.mod, nas.pla
does not process a PLASMA-language `include` at COMPILE time -- that
already happened on the HOST, in xplasm; nas reads a MERLIN source
file at runtime, not a .plh).

TEXT ENCODING: the fixture is Merlin/6502-assembler source, not PLASMA
source, but the same low-ASCII-bare-CR convention applies for the same
reason build_plasm_image.py's T.PLA does -- nas's own line-splitter
(pass1's search for a bare $0D) assumes unmasked low-ASCII bytes, and
merlin32 on the host reads the identical plain-text encoding, which is
exactly the byte-identity contract this gate proves.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos, convert  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAY_IMG = os.path.join(ROOT, 'build', 'play.po')
OUT_IMG = os.path.join(ROOT, 'build', 'nas.po')
PLASMA_BIN = os.path.join(ROOT, 'build', 'plasma.bin')
RT_MOD = os.path.join(ROOT, 'build', 'rt.mod')
ARGS_MOD = os.path.join(ROOT, 'build', 'args.mod')
FILEIO_MOD = os.path.join(ROOT, 'build', 'fileio.mod')
NAS_MOD = os.path.join(ROOT, 'build', 'nas.mod')
FIXTURE_S = os.path.join(ROOT, 'src', 'test', 'asm', 'fixture.s')
STRESS_S = os.path.join(ROOT, 'src', 'test', 'asm', 'stress.s')
LOCAL_S = os.path.join(ROOT, 'src', 'test', 'asm', 'local.s')
L2B_S = os.path.join(ROOT, 'src', 'test', 'asm', 'l2b.s')
BOUNDARY_S = os.path.join(ROOT, 'src', 'test', 'asm', 'boundary.s')
BOUNDFAIL_S = os.path.join(ROOT, 'src', 'test', 'asm', 'boundaryfail.s')
BOUNDFAILNEG_S = os.path.join(ROOT, 'src', 'test', 'asm', 'boundneg.s')
NOXC_S = os.path.join(ROOT, 'src', 'test', 'asm', 'noxc.s')
FORWARD_S = os.path.join(ROOT, 'src', 'test', 'asm', 'forward.s')
NAS_CUT = os.path.join(ROOT, 'build', 'nas.cut')
VOL = 'MAUX'
LIBDIR = f'/mnt/{VOL}/PLLIB'
RT_PATH = f'/mnt/{VOL}/PLRT'


def main():
    needed = [
        (PLAY_IMG, 'play image'),
        (PLASMA_BIN, 'plasma.bin (the VM seed)'),
        (RT_MOD, 'rt.mod (make build/rt.mod)'),
        (ARGS_MOD, 'args.mod (make build/args.mod)'),
        (FILEIO_MOD, 'fileio.mod (make build/fileio.mod)'),
        (NAS_MOD, 'nas.mod (make build/nas.mod)'),
        (NAS_CUT, 'nas.cut (make build/nas.cut)'),
        (FIXTURE_S, 'src/test/asm/fixture.s'),
        (STRESS_S, 'src/test/asm/stress.s'),
        (LOCAL_S, 'src/test/asm/local.s'),
        (L2B_S, 'src/test/asm/l2b.s'),
        (BOUNDARY_S, 'src/test/asm/boundary.s'),
        (BOUNDFAIL_S, 'src/test/asm/boundaryfail.s'),
        (BOUNDFAILNEG_S, 'src/test/asm/boundneg.s'),
        (NOXC_S, 'src/test/asm/noxc.s'),
        (FORWARD_S, 'src/test/asm/forward.s'),
    ]
    for path, label in needed:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2

    mods = {}
    for nm, pth in (('ARGS', ARGS_MOD), ('FILEIO', FILEIO_MOD),
                    ('NAS', NAS_MOD), ('RT', RT_MOD)):
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
    with open(NAS_CUT, 'rb') as f:
        ncutbin = f.read()
    with open(FIXTURE_S, 'rb') as f:
        fixture_text = convert.text_from_host(f.read())
    with open(STRESS_S, 'rb') as f:
        stress_text = convert.text_from_host(f.read())
    with open(LOCAL_S, 'rb') as f:
        local_text = convert.text_from_host(f.read())
    with open(L2B_S, 'rb') as f:
        l2b_text = convert.text_from_host(f.read())
    with open(BOUNDARY_S, 'rb') as f:
        boundary_text = convert.text_from_host(f.read())
    with open(BOUNDFAIL_S, 'rb') as f:
        boundfail_text = convert.text_from_host(f.read())
    with open(BOUNDFAILNEG_S, 'rb') as f:
        boundfailneg_text = convert.text_from_host(f.read())
    with open(NOXC_S, 'rb') as f:
        noxc_text = convert.text_from_host(f.read())
    with open(FORWARD_S, 'rb') as f:
        forward_text = convert.text_from_host(f.read())

    shutil.copyfile(PLAY_IMG, OUT_IMG)
    prodos.mount(OUT_IMG)
    try:
        # plasma is PLAY_EXCLUDEd from the shared image (root-cap); stage
        # the seed itself here, as build_plasm_image does.
        try:                      # docs/VROOT.md: programs live in BIN
            prodos.mkdir(f'/mnt/{VOL}/BIN')
        except FileExistsError:
            pass
        prodos.write(f'/mnt/{VOL}/BIN/plasma', seedbin, file_type=0x06,
                     aux_type=0x0800, overwrite=True)
        prodos.write(RT_PATH, mods['RT'], file_type=0xFE,
                     aux_type=0x0000, overwrite=True)
        prodos.mkdir(LIBDIR)
        for nm in ('ARGS', 'FILEIO', 'NAS'):
            prodos.write(f'{LIBDIR}/{nm}', mods[nm], file_type=0xFE,
                         aux_type=0x0000, overwrite=True)
        prodos.write(f'{LIBDIR}/NCUT', ncutbin, file_type=0x06,
                     aux_type=0x0800, overwrite=True)
        prodos.write(f'{LIBDIR}/FIXTURE.S', fixture_text, file_type=0x04,
                     aux_type=0x0000, overwrite=True)
        prodos.write(f'{LIBDIR}/STRESS.S', stress_text, file_type=0x04,
                     aux_type=0x0000, overwrite=True)
        prodos.write(f'{LIBDIR}/LOCAL.S', local_text, file_type=0x04,
                     aux_type=0x0000, overwrite=True)
        prodos.write(f'{LIBDIR}/L2B.S', l2b_text, file_type=0x04,
                     aux_type=0x0000, overwrite=True)
        prodos.write(f'{LIBDIR}/BOUNDARY.S', boundary_text, file_type=0x04,
                     aux_type=0x0000, overwrite=True)
        prodos.write(f'{LIBDIR}/BOUNDFAIL.S', boundfail_text, file_type=0x04,
                     aux_type=0x0000, overwrite=True)
        prodos.write(f'{LIBDIR}/BOUNDFAILNEG.S', boundfailneg_text,
                     file_type=0x04, aux_type=0x0000, overwrite=True)
        prodos.write(f'{LIBDIR}/NOXC.S', noxc_text, file_type=0x04,
                     aux_type=0x0000, overwrite=True)
        prodos.write(f'{LIBDIR}/FORWARD.S', forward_text, file_type=0x04,
                     aux_type=0x0000, overwrite=True)
        names = sorted(e.name for e in prodos.scandir(LIBDIR))
    finally:
        prodos.unmount(VOL)
    print(f'[build-nas] {LIBDIR} holds {names}')
    print(f'[build-nas] {RT_PATH} staged (rt {len(mods["RT"])} B, flat)')
    print(f'[build-nas] {OUT_IMG} ready')
    return 0


if __name__ == '__main__':
    sys.exit(main())
