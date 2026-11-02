#!/usr/bin/env python3
"""Build an opt-in native-loop experiment without changing production NAS.

Uses the existing NAS macro pass, compiler, modules and cooker. All generated
files live under --output-dir; source anchors fail closed if NAS changes.
"""
import argparse
from pathlib import Path
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
NATIVE_SOURCE = ROOT / 'src/asm/nasloop.pla'
# Descriptor words, shared with nasloop.pla. Pointers, never hardcoded module
# addresses; the PLASMA compiler/cooker relocate every entry normally.
FIELDS = ('@g_line', '@g_labelptr', '@dirhash', '@rd_buf0', '@mnhead',
          '@optab', '@g_blo', '@opmode', '@modestrm', '@outbuf', '@fxrec',
          '@xcflag', '@dumflag', '@hashhead', '@curzone', '@curstar',
          '@lineprep', '@mnlook', '@numscan', '@namescan', '@findsymh',
          '@modeprobe', '@noteinst', '@commitinst', '@fastloop',
          '0', '0', '0', '0', '0', '0', '0', '0', '0',
          '@rd_inputt', '@modeprefix', '@modetrim', '@fastvalue',
          '0', '0', '0', '0')  # raw value, relocation kind/refnum, selector


def source_variant(source, native):
    anchor = 'export asm ckdataend()#0'
    assert source.count(anchor) == 1
    source = source.replace(anchor, f'word[{len(FIELDS)}] loopctx\n' + anchor)
    anchor = 'def xalloc(n)#1'
    assert source.count(anchor) == 1
    source = source.replace(anchor, native + '\n' + anchor)
    anchor = '    word arg, lc, sc, lo, cl, hi\n'
    assert source.count(anchor) == 1
    init = ''.join(f'    loopctx[{i}] = {value}\n' for i, value in enumerate(FIELDS))
    source = source.replace(anchor, anchor + init)
    anchor = 'd = lineprep(@rd_buf0 + rd_inputt, @g_line, @g_labelptr, @dirhash)'
    assert source.count(anchor) == 2
    source = source.replace(anchor, 'd = fastloop(@loopctx, 1)', 1)
    source = source.replace(anchor, 'd = fastloop(@loopctx, 2)', 1)
    return source


def main():
    if 'asm initloop(seed)' in (ROOT / 'src/asm/nas.pla').read_text():
        raise SystemExit('Historical pre-promotion transform retired. '
                         'Use make build/nas.cut and make check-nas-native; '
                         'see docs/NAS-TWO-PASS-REFACTOR.md.')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, default=ROOT / 'build/nas-loop')
    args = parser.parse_args()
    out = args.output_dir.resolve()
    if out in (ROOT, ROOT / 'build'):
        raise ValueError('use a private experiment build directory')
    out.mkdir(parents=True, exist_ok=True)
    native = NATIVE_SOURCE.read_text()
    if NATIVE_SOURCE.name == 'nasreplace.pla':
        shared = (ROOT / 'src/asm/nasloop.pla').read_text().split('asm fastloop(', 1)[0]
        native = shared + native
    variant = source_variant((ROOT / 'src/asm/nas.pla').read_text(), native)
    expanded = subprocess.run(['sed', '-E', '-f', str(ROOT / 'scripts/nas_inline.sed')],
                              input=variant, text=True, capture_output=True, check=True).stdout
    (out / 'nas.pla').write_text(expanded)
    shutil.copytree(ROOT / 'build/inc', out / 'inc', dirs_exist_ok=True)
    plasma = Path(os.environ.get('PLASMA', str(Path.home() / 'src/PLASMA')))
    subprocess.run([str(plasma / 'src/xplasm'), '-AMOW', 'nas.pla'], cwd=out, check=True)
    subprocess.run(['acme', '--setpc', '8190', '-o', 'nas.mod', 'nas.a'], cwd=out, check=True)
    for name in ('plasma.bin', 'plasma.bin_Output.txt', 'rt.mod', 'args.mod', 'fileio.mod'):
        shutil.copyfile(ROOT / 'build' / name, out / name)
    subprocess.run(['python3', str(ROOT / 'scripts/plascut.py'), '--seed', str(out / 'plasma.bin'),
                    '--rt', str(out / 'rt.mod'), '-L', str(out), '--const-prefix', 'NAS',
                    '--immutable-native', 'NAS', '-o', str(out / 'nas.cut'), 'NAS'], check=True)


if __name__ == '__main__':
    main()
