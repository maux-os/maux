#!/usr/bin/env python3
"""Build build/plascut.po -- the check-plascut gate image (docs/PLASCUT.md).

The play image plus BOTH ways of running nas, so the gate can prove
the cooked binary against the modular one in a single boot:

  /bin/NAS         build/nas.cut   -- nas COOKED by scripts/plascut.py:
                                            seed + rt + FILEIO + ARGS + NAS in
                                            one flat BIN, aux $0800, spawned
                                            like any util (`nas -o X Y`)
  /bin/COOKT       build/cookt.cut -- the restore-teeth fixture
                                            (src/test/plasma/cookt.pla)
  /bin/plasma          the seed         )
  /mnt/MAUX/PLRT            rt.mod, flat     ) the MODULAR path, staged exactly
  /mnt/MAUX/PLLIB/{ARGS,FILEIO,NAS}          ) as build_nas_image.py does, for
                                            the cooked-vs-modular timing
  /mnt/MAUX/PLLIB/FIXTURE.S, STRESS.S        the check-nas fixtures (same
                                            merlin32 references)

Same text-encoding note as build_nas_image.py: fixture sources are
staged low-ASCII with bare CRs, the encoding both nas and merlin32 read.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos, convert  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)
from plascut import Image  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAY_IMG = os.path.join(ROOT, 'build', 'play.po')
OUT_IMG = os.path.join(ROOT, 'build', 'plascut.po')
NAS_CUT = os.path.join(ROOT, 'build', 'nas.cut')
COOKT_CUT = os.path.join(ROOT, 'build', 'cookt.cut')
PLASMA_BIN = os.path.join(ROOT, 'build', 'plasma.bin')
RT_MOD = os.path.join(ROOT, 'build', 'rt.mod')
ARGS_MOD = os.path.join(ROOT, 'build', 'args.mod')
FILEIO_MOD = os.path.join(ROOT, 'build', 'fileio.mod')
NAS_MOD = os.path.join(ROOT, 'build', 'nas.mod')
FIXTURE_S = os.path.join(ROOT, 'src', 'test', 'asm', 'fixture.s')
STRESS_S = os.path.join(ROOT, 'src', 'test', 'asm', 'stress.s')
VOL = 'MAUX'
BINDIR = f'/mnt/{VOL}/BIN'
LIBDIR = f'/mnt/{VOL}/PLLIB'
RT_PATH = f'/mnt/{VOL}/PLRT'


def main():
    needed = [
        (PLAY_IMG, 'play image'),
        (NAS_CUT, 'nas.cut (make build/nas.cut)'),
        (COOKT_CUT, 'cookt.cut (make build/cookt.cut)'),
        (PLASMA_BIN, 'plasma.bin'),
        (RT_MOD, 'rt.mod'),
        (ARGS_MOD, 'args.mod'),
        (FILEIO_MOD, 'fileio.mod'),
        (NAS_MOD, 'nas.mod'),
        (FIXTURE_S, 'src/test/asm/fixture.s'),
        (STRESS_S, 'src/test/asm/stress.s'),
    ]
    for path, label in needed:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2
    blobs = {}
    for key, path in (('NASCUT', NAS_CUT), ('COOKT', COOKT_CUT),
                      ('SEED', PLASMA_BIN), ('RT', RT_MOD),
                      ('ARGS', ARGS_MOD), ('FILEIO', FILEIO_MOD),
                      ('NAS', NAS_MOD)):
        with open(path, 'rb') as f:
            blobs[key] = f.read()
    for key in ('NASCUT', 'COOKT'):
        b = blobs[key]
        if b[0] != 0x4C or b[9:11] != b'CK' or b[11] != 1:
            print(f'error: {key} is not a cooked image (CK header/flag)',
                  file=sys.stderr)
            return 2
    # Teeth: globals still reset, but mutable native text does not. The
    # fixture's second warm launch must expose its modified LDA operand.
    bad = Image(blobs['SEED'], blobs['RT'])
    bad.buf[:len(blobs['COOKT'])] = blobs['COOKT']
    table = bad.r16(bad.find_cook_block()['cookrestore'])
    if bad.r16(table + 12) != 0 or bad.r16(table + 10) <= 2:
        raise RuntimeError('COOKT teeth needs rt + fixture restore entries')
    bad.w16(table + 10, 2)  # keep runs, omit the mutable native helper
    blobs['COOKBAD'] = bytes(bad.buf[:len(blobs['COOKT'])])
    with open(FIXTURE_S, 'rb') as f:
        fixture_text = convert.text_from_host(f.read())
    with open(STRESS_S, 'rb') as f:
        stress_text = convert.text_from_host(f.read())

    shutil.copyfile(PLAY_IMG, OUT_IMG)
    prodos.mount(OUT_IMG)
    try:
        # The shell's PATH walks /bin/ before the volume root
        # (src/bin/shpath.s); the play image has no BIN yet, and the
        # root is near its 51-entry cap -- make it.
        try:
            prodos.mkdir(BINDIR)
        except FileExistsError:
            pass
        prodos.write(f'{BINDIR}/NAS', blobs['NASCUT'], file_type=0x06,
                     aux_type=0x0800, overwrite=True)
        prodos.write(f'{BINDIR}/COOKT', blobs['COOKT'], file_type=0x06,
                     aux_type=0x0800, overwrite=True)
        prodos.write(f'{BINDIR}/COOKBAD', blobs['COOKBAD'], file_type=0x06,
                     aux_type=0x0800, overwrite=True)
        try:                      # docs/VROOT.md: programs live in BIN
            prodos.mkdir(f'/mnt/{VOL}/BIN')
        except FileExistsError:
            pass
        prodos.write(f'/mnt/{VOL}/BIN/plasma', blobs['SEED'], file_type=0x06,
                     aux_type=0x0800, overwrite=True)
        prodos.write(RT_PATH, blobs['RT'], file_type=0xFE,
                     aux_type=0x0000, overwrite=True)
        prodos.mkdir(LIBDIR)
        for nm in ('ARGS', 'FILEIO', 'NAS'):
            prodos.write(f'{LIBDIR}/{nm}', blobs[nm], file_type=0xFE,
                         aux_type=0x0000, overwrite=True)
        prodos.write(f'{LIBDIR}/FIXTURE.S', fixture_text, file_type=0x04,
                     aux_type=0x0000, overwrite=True)
        prodos.write(f'{LIBDIR}/STRESS.S', stress_text, file_type=0x04,
                     aux_type=0x0000, overwrite=True)
        names = sorted(e.name for e in prodos.scandir(BINDIR))
    finally:
        prodos.unmount(VOL)
    print(f'[build-plascut] {BINDIR} holds {len(names)} entries incl. '
          f'NAS ({len(blobs["NASCUT"])} B cooked), COOKT '
          f'({len(blobs["COOKT"])} B cooked)')
    print(f'[build-plascut] {OUT_IMG} ready')
    return 0


if __name__ == '__main__':
    sys.exit(main())
