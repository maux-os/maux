#!/usr/bin/env python3
"""Build the ProDOS-hosted `expr` acceptance-gate image
(`make check-expr`).

Companion to src/test/exprtest.s / exprtestb.s / scripts/check_expr.py.
Same carrier-volume shape as scripts/build_testev_image.py: the gate
calls EXPR_EVAL directly with a synthetic argv array (case-table
style, no staged input needed) -- just the kernel and the test
harness SYSTEM file. `expr.bin` itself is also staged as a real
spawnable ProDOS BIN (matching build_fleet_image.py's own staged
utils) so other gates can spawn it directly going forward, even
though this gate does not yet exercise that path itself -- see
exprtest.s's header for why.
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
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXEXPR.SYSTEM')
EXPR_BIN = os.path.join(ROOT, 'build', 'expr.bin')
CASES_BIN = os.path.join(ROOT, 'build', 'exprcases.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'expr.po')


def main():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXEXPR.SYSTEM'),
        (EXPR_BIN, 'expr userland binary'),
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
    with open(EXPR_BIN, 'rb') as f:
        exprbin = f.read()

    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    # file_type/aux_type match build_fleet_image.py's own staged utils
    # (0x06 BIN, 0x0800 = LOAD_BASE).
    try:                      # docs/VROOT.md: programs live in BIN
        prodos.mkdir(f'{root}/BIN')
    except FileExistsError:
        pass
    prodos.write(f'{root}/BIN/EXPR', exprbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    # -- the Phase-1 case table (src/test/exprcases.s, assembled at
    # -- $1800), READ into the harness's bank at start-up -- moved out
    # -- of MAUXEXPR.SYSTEM 2026-09-12 for PMLI_IBF_BASE room.
    with open(CASES_BIN, 'rb') as f:
        casesbin = f.read()
    prodos.write(f'{root}/EXPRCASES', casesbin, file_type=0x06,
                 aux_type=0x1800, overwrite=True)
    prodos.unmount(CARRIER_VOL)

    print(f'[build-expr] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-expr] kept={kept} removed={removed}')
    print(f'[build-expr] wrote MAUX.SYSTEM ({len(system)} bytes), '
          f'EXPR ({len(exprbin)} bytes)')
    print(f'[build-expr] {OUT_IMG} ready '
          f'({os.path.getsize(OUT_IMG)} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
