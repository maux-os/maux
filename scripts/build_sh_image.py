#!/usr/bin/env python3
"""Build the ProDOS-hosted `sh` integration gate image (`make check-sh`).

Companion to src/test/shtest.s / scripts/check_sh.py.
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
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXSH.SYSTEM')
SH_BIN = os.path.join(ROOT, 'build', 'sh.bin')
ECHO_BIN = os.path.join(ROOT, 'build', 'echo.bin')
CAT_BIN = os.path.join(ROOT, 'build', 'cat.bin')
LS_BIN = os.path.join(ROOT, 'build', 'ls.bin')
CP_BIN = os.path.join(ROOT, 'build', 'cp.bin')
RM_BIN = os.path.join(ROOT, 'build', 'rm.bin')
ED_BIN = os.path.join(ROOT, 'build', 'ed.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'sh.po')

# The script sh reads from fd 0 (docs/SH-DESIGN.md's own worked example,
# transcribed verbatim by the task brief). High-bit-set text, CR ($8D)
# line endings -- sh.s's own documented input convention (see that file's
# header, "INPUT ENCODING"). Command words are UPPERCASE to match every
# maux binary's uppercase on-disk name (sh.s's own "CASE" ruling).
SCRIPT_TEXT = (
    'ECHO HELLO > /mnt/MAUX/OUT1\r'
    'ECHO A | CAT > /mnt/MAUX/OUT2\r'
    'ED < /mnt/MAUX/EDSCRIPT > /mnt/MAUX/EDLOG\r'
    'CAT /mnt/MAUX/EDITED > /mnt/MAUX/CATOUT\r'
    # -- The /DEV namespace (procfile5.s). BOTH CASES ARE HERE ON
    # -- PURPOSE: /DEV/NULL is the form the tree's own uppercase
    # -- convention would produce, /dev/null is the form a human
    # -- types, and only the second exercises PDEV_FOLD at all.
    # -- DEVNUL must come back EXISTING and EMPTY -- cat reading a
    # -- device that is always at EOF -- and DEVAFT is what proves
    # -- sh survived both redirects rather than dying on the first.
    'CAT /mnt/MAUX/EDITED > /DEV/NULL\r'
    'CAT < /dev/null > /mnt/MAUX/DEVNUL\r'
    'ECHO AFTER > /mnt/MAUX/DEVAFT\r'
    'EXIT\r'
)
SCRIPT_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D for c in SCRIPT_TEXT)

# `sh SCRIPTFILE` mode (Phase B, EX3 pipeline work): SCRIPT3 is
# read by sh via argv[1] (OPEN_REDIR_RD), NOT fd 0 -- IN3 is
# dup'd onto fd 0 instead, and SCRIPT3's own `CAT` (no args, no
# redirection) reads it, proving fd 0 was free for the command
# the whole time (src/test/shtestb.s's SPAWN_SH2/OPN_IN3_FILE).
SCRIPT3_TEXT = (
    'CAT > /mnt/MAUX/OUT3\r'
    'EXIT\r'
)
SCRIPT3_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                      for c in SCRIPT3_TEXT)
IN3_TEXT = 'PIPEDATA\r'
IN3_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D for c in IN3_TEXT)
EXPECT_OUT3 = IN3_BYTES

EDSCRIPT_TEXT = (
    'a\r'
    'alpha one\r'
    'BANK two\r'
    '.\r'
    'w /mnt/MAUX/EDITED\r'
    'q\r'
)
EDSCRIPT_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                       for c in EDSCRIPT_TEXT)

# Expected OUT1/OUT2 contents -- echo's own documented contract (one
# trailing CR, high-bit-set) -- scripts/check_sh.py's source of truth.
EXPECT_OUT1 = bytes([0xC8, 0xC5, 0xCC, 0xCC, 0xCF, 0x8D])          # "HELLO"+CR
EXPECT_OUT2 = bytes([0xC1, 0x8D])                                  # "A"+CR


def hitext(s):
    return bytes(ord(c) | 0x80 for c in s)


EXPECT_EDITED = (
    hitext('alpha one') + bytes([0x8D]) +
    hitext('BANK two') + bytes([0x8D])
)
EXPECT_CATOUT = EXPECT_EDITED

# /dev/null reads EOF immediately, so cat writes nothing at all --
# the file must EXIST (sh got far enough to create the redirect
# target) and be exactly zero bytes.
EXPECT_DEVNUL = b''
EXPECT_DEVAFT = hitext('AFTER') + bytes([0x8D])


def main():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXSH.SYSTEM'),
        (SH_BIN, 'sh userland binary'),
        (ECHO_BIN, 'echo userland binary'),
        (CAT_BIN, 'cat userland binary'),
        (LS_BIN, 'ls userland binary'),
        (CP_BIN, 'cp userland binary'),
        (RM_BIN, 'rm userland binary'),
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
    with open(SH_BIN, 'rb') as f:
        shbin = f.read()
    with open(ECHO_BIN, 'rb') as f:
        echobin = f.read()
    with open(CAT_BIN, 'rb') as f:
        catbin = f.read()
    with open(LS_BIN, 'rb') as f:
        lsbin = f.read()
    with open(CP_BIN, 'rb') as f:
        cpbin = f.read()
    with open(RM_BIN, 'rb') as f:
        rmbin = f.read()
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
    prodos.write(f'{root}/BIN/SH', shbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/ECHO', echobin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/CAT', catbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/LS', lsbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/CP', cpbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/RM', rmbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/ED', edbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/SCRIPT', SCRIPT_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/EDSCRIPT', EDSCRIPT_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/SCRIPT3', SCRIPT3_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/IN3', IN3_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.unmount(CARRIER_VOL)

    print(f'[build-sh] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-sh] kept={kept} removed={removed}')
    print(f'[build-sh] wrote MAUX.SYSTEM ({len(system)} bytes), '
          f'SH ({len(shbin)} bytes), ECHO ({len(echobin)} bytes), '
          f'CAT ({len(catbin)} bytes), LS ({len(lsbin)} bytes), '
          f'CP ({len(cpbin)} bytes), RM ({len(rmbin)} bytes), '
          f'ED ({len(edbin)} bytes), SCRIPT ({len(SCRIPT_BYTES)} bytes), '
          f'EDSCRIPT ({len(EDSCRIPT_BYTES)} bytes), '
          f'SCRIPT3 ({len(SCRIPT3_BYTES)} bytes), '
          f'IN3 ({len(IN3_BYTES)} bytes)')
    print(f'[build-sh] {OUT_IMG} ready ({os.path.getsize(OUT_IMG)} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
