#!/usr/bin/env python3
"""Build build/nas-rel.po -- the check-nas-rel gate image (docs/AS-
PLASMA.md L1b: PUT/USE splicing + REL object emission + linking).

Modeled directly on build_nas_image.py (same play-image + rt + PLLIB
staging), extended with the pieces L1b needs beyond L1a's flat-binary
check-nas:

  /mnt/MAUX/PLLIB/RELMAIN.S  the top-level L1b fixture: `REL`, `EXT
                          LIBGREET`, and `PUT relsub` (proves PUT
                          splicing) -- src/test/asm/relmain.s
  /mnt/MAUX/PLLIB/RELSUB.S   spliced into RELMAIN.S by its `PUT` line --
                          src/test/asm/relsub.s
  /mnt/MAUX/PLLIB/RELLIB.S   the library half: `REL`, `LIBGREET ENT` --
                          src/test/asm/rellib.s
  /mnt/MAUX/PLLIB/LD         build/ld.bin, maux's own native REL linker,
                          staged the SAME way build_ld_image.py stages
                          it (type $06, aux $0800/LOAD_BASE) -- but
                          HERE, inside /mnt/MAUX/PLLIB alongside
                          everything else, so a bare `LD` at the shell
                          resolves it via the SAME current-directory
                          fallback (BUILD_PATH's :exhausted branch,
                          src/bin/shblt2.s) that already lets a bare
                          `plasma NAS ...` argument resolve FIXTURE.S
                          relative to the shell's own prefix -- no
                          PATH entry needed for either.

check_nas_rel.py assembles both REL fixtures with nas (`plasma NAS -o
RELMAIN.REL RELMAIN.S` / `... RELLIB.REL RELLIB.S`), links them with
`LD -o OUT RELMAIN.REL RELLIB.REL` (LD's own default link address is
LOAD_BASE, $0800 -- the SAME address a spawned process loads at, so
the linked OUT file is directly spawnable), then spawns `OUT` itself
and reads its exit status: `assemble -> link -> run`, all inside maux.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos, convert  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAY_IMG = os.path.join(ROOT, 'build', 'play.po')
OUT_IMG = os.path.join(ROOT, 'build', 'nas-rel.po')
PLASMA_BIN = os.path.join(ROOT, 'build', 'plasma.bin')
RT_MOD = os.path.join(ROOT, 'build', 'rt.mod')
ARGS_MOD = os.path.join(ROOT, 'build', 'args.mod')
FILEIO_MOD = os.path.join(ROOT, 'build', 'fileio.mod')
NAS_MOD = os.path.join(ROOT, 'build', 'nas.mod')
LD_BIN = os.path.join(ROOT, 'build', 'ld.bin')
RELMAIN_S = os.path.join(ROOT, 'src', 'test', 'asm', 'relmain.s')
RELSUB_S = os.path.join(ROOT, 'src', 'test', 'asm', 'relsub.s')
RELLIB_S = os.path.join(ROOT, 'src', 'test', 'asm', 'rellib.s')
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
        (LD_BIN, 'ld.bin (make build/ld.bin)'),
        (RELMAIN_S, 'src/test/asm/relmain.s'),
        (RELSUB_S, 'src/test/asm/relsub.s'),
        (RELLIB_S, 'src/test/asm/rellib.s'),
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
    with open(LD_BIN, 'rb') as f:
        ldbin = f.read()
    with open(RELMAIN_S, 'rb') as f:
        relmain_text = convert.text_from_host(f.read())
    with open(RELSUB_S, 'rb') as f:
        relsub_text = convert.text_from_host(f.read())
    with open(RELLIB_S, 'rb') as f:
        rellib_text = convert.text_from_host(f.read())

    shutil.copyfile(PLAY_IMG, OUT_IMG)
    prodos.mount(OUT_IMG)
    try:
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
        prodos.write(f'{LIBDIR}/LD', ldbin, file_type=0x06,
                     aux_type=0x0800, overwrite=True)
        prodos.write(f'{LIBDIR}/RELMAIN.S', relmain_text, file_type=0x04,
                     aux_type=0x0000, overwrite=True)
        prodos.write(f'{LIBDIR}/RELSUB.S', relsub_text, file_type=0x04,
                     aux_type=0x0000, overwrite=True)
        prodos.write(f'{LIBDIR}/RELLIB.S', rellib_text, file_type=0x04,
                     aux_type=0x0000, overwrite=True)
        names = sorted(e.name for e in prodos.scandir(LIBDIR))
    finally:
        prodos.unmount(VOL)
    print(f'[build-nas-rel] {LIBDIR} holds {names}')
    print(f'[build-nas-rel] {RT_PATH} staged (rt {len(mods["RT"])} B, flat)')
    print(f'[build-nas-rel] {OUT_IMG} ready')
    return 0


if __name__ == '__main__':
    sys.exit(main())
