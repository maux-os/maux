#!/usr/bin/env python3
"""Build the ProDOS-hosted TEST_EVAL acceptance-gate image
(`make check-testev`).

Companion to src/test/testevtest.s / src/test/testevtestb.s /
scripts/check_testev.py -- same carrier-volume shape as
scripts/build_catread_image.py, staging real files instead of a
spawned binary: testevtestb.s's -f/-d/-e case rows stat these
via GET_FILE_INFO, same as src/bin/ls.s.
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
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXTESTEV.SYSTEM')
OUT_IMG = os.path.join(ROOT, 'build', 'testev.po')

# testevtestb.s's TK_TESTF/TK_TESTD/TK_NOPE/TK_TESTB tokens are the SAME
# literal absolute paths as these -- TESTF must exist as a regular TXT
# file, TESTD as a directory, TESTB as a regular BIN file (the -x TRUE
# case -- src/bin/testeval.s decision 4's "-x is file_type SYS or BIN"
# rule), and NOPE must NOT exist (the "nonexistent path" cases).
TESTF_PATH = f'/mnt/{CARRIER_VOL}/TESTF'
TESTD_PATH = f'/mnt/{CARRIER_VOL}/TESTD'
TESTB_PATH = f'/mnt/{CARRIER_VOL}/TESTB'
TESTF_BYTES = bytes((ord(c) | 0x80) for c in 'test file content')
TESTB_BYTES = bytes((ord(c) | 0x80) for c in 'bin')


def main():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXTESTEV.SYSTEM'),
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

    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    prodos.write(TESTF_PATH, TESTF_BYTES, file_type=0x04, aux_type=0x0000,
                 overwrite=True)
    prodos.write(TESTB_PATH, TESTB_BYTES, file_type=0x06, aux_type=0x0000,
                 overwrite=True)
    prodos.mkdir(TESTD_PATH)
    # NOPE_PATH ('/mnt/MAUX/NOPE') is deliberately never written -- it is the
    # nonexistent-path case for -f/-d/-e.
    prodos.unmount(CARRIER_VOL)

    print(f'[build-testev] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-testev] kept={kept} removed={removed}')
    print(f'[build-testev] wrote MAUX.SYSTEM ({len(system)} bytes), '
          f'{TESTF_PATH} ({len(TESTF_BYTES)} bytes), '
          f'{TESTB_PATH} ({len(TESTB_BYTES)} bytes, BIN), {TESTD_PATH}/')
    print(f'[build-testev] {OUT_IMG} ready '
          f'({os.path.getsize(OUT_IMG)} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
