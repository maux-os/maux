#!/usr/bin/env python3
"""Build the write-failure e2e image (`make writefail-image`).

This is one deliberately hostile volume for docs/E2E-COVERAGE.md
section 4: no free blocks after staging, plus a locked target.  The
unchanged stage-1 parent (`src/test/e2etestb.s`) boots `sh` from
/mnt/MAUX/E2E/SCRIPT; the script runs cp, mv, mkdir, tee, ed, and a shell
redirection against failure surfaces that ordinary fixtures cannot
reach.

The control files are staged with the `prodos` module directly rather
than `a2til mirror` because this image needs exact access bytes and an
exact post-staging free-block count.  The text encoding still comes from
a2til's converter, the same single boundary used by stage 1.
"""
import hashlib
import math
import os
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import convert, prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')
CARRIER_IMG = os.environ.get('PRODOS_CARRIER_IMG',
                             os.path.join(ROOT, 'vendor', 'prodos-basic.po'))
CARRIER_VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')
KERNEL_BIN = os.environ.get('PRODOS_KERNEL_BIN',
                            os.path.join(ROOT, 'vendor', 'ProDOS-2.4.bin'))
SYS_BIN = os.path.join(BUILD, 'MAUXE2E.SYSTEM')
OUT_IMG = os.path.join(BUILD, 'writefail.po')

VOL_BLOCKS = 1600
BOOT_BYTES = 1024
TXT = 0x04
BIN = 0x06
SYS = 0xFF
LOAD_AUX = 0x0800
SYS_AUX = 0x2000
LOCKED_ACCESS = 0x21
FILL_BYTE = b'\xA5'

TOOLS = ['sh', 'echo', 'cp', 'mv', 'mkdir', 'tee', 'ed']
CAPTURES = ['ST', 'CPNF', 'MVNF', 'MKNF', 'TEEP', 'EDP']

ROOTDIR = '/mnt/MAUX'
IMG_DIR = f'{ROOTDIR}/E2E'
WF_DIR = f'{ROOTDIR}/WF'

CPSRC_TEXT = 'cp source line one\ncp source line two\n'
MVSRC_TEXT = 'mv source line one\nmv source line two\n'
TEESRC_TEXT = 'tee payload\n'
PROT_TEXT = 'protected target must not change\n'
EDSCRIPT_TEXT = (
    'a\n'
    'ed replacement\n'
    '.\n'
    'w /mnt/MAUX/WF/PROT\n'
)

SCRIPT_LINES = [
    'CD /mnt/MAUX',
    'CP /mnt/MAUX/WF/CPSRC /mnt/MAUX/WF/CPNEW >> /mnt/MAUX/E2E/CPNF 2>&1',
    'ECHO $? >> /mnt/MAUX/E2E/ST',
    ('MV /mnt/MAUX/WF/MVDIR/MVSRC /mnt/MAUX/WF/MVDST/MVSRC '
     '>> /mnt/MAUX/E2E/MVNF 2>&1'),
    'ECHO $? >> /mnt/MAUX/E2E/ST',
    'MKDIR /mnt/MAUX/WF/NEWDIR >> /mnt/MAUX/E2E/MKNF 2>&1',
    'ECHO $? >> /mnt/MAUX/E2E/ST',
    'TEE /mnt/MAUX/WF/PROT < /mnt/MAUX/WF/TEESRC >> /mnt/MAUX/E2E/TEEP 2>&1',
    'ECHO $? >> /mnt/MAUX/E2E/ST',
    'ED < /mnt/MAUX/WF/EDSCRIPT >> /mnt/MAUX/E2E/EDP 2>&1',
    'ECHO $? >> /mnt/MAUX/E2E/ST',
    'ECHO REDIR > /mnt/MAUX/WF/PROT',
    'ECHO $? >> /mnt/MAUX/E2E/ST',
    # `>>` and `>` fail in DIFFERENT PLACES on a locked target, and
    # separating them is the point of having both lines.  `>` destroys
    # then creates (OPEN_REDIR_WR), so it fails in the SHELL, at the
    # CREATE, and the child never runs -- nothing is ever written.
    # `>>` only creates-if-missing then opens and seeks, and a locked
    # file OPENs fine because its access byte still permits reads -- so
    # the child runs and the failure is a real WRITE failure inside
    # echo.  That is the only line here that exercises stdio's own
    # error path end to end (PUTS records it, EXIT reports it), and
    # without it the fix for the shell would look like the fix for the
    # library.
    'ECHO APPEND >> /mnt/MAUX/WF/PROT',
    'ECHO $? >> /mnt/MAUX/E2E/ST',
    'EXIT',
]


def image_text(text):
    return convert.text_from_host(text.encode('ascii'), high_bit=True)


CPSRC_BYTES = image_text(CPSRC_TEXT)
MVSRC_BYTES = image_text(MVSRC_TEXT)
TEESRC_BYTES = image_text(TEESRC_TEXT)
PROT_BYTES = image_text(PROT_TEXT)
EDSCRIPT_BYTES = image_text(EDSCRIPT_TEXT)
SCRIPT_BYTES = image_text(''.join(line + '\n' for line in SCRIPT_LINES))


def stage_txt(vol, path, data=b''):
    vol.write_file(path, data, file_type=TXT, aux_type=0, overwrite=True)


def blocks_used_for_nonzero_data(data_blocks):
    if data_blocks <= 1:
        return 1
    if data_blocks <= 256:
        return 1 + data_blocks
    return 1 + math.ceil(data_blocks / 256) + data_blocks


def largest_payload_blocks(free_blocks):
    for data_blocks in range(free_blocks, 0, -1):
        if blocks_used_for_nonzero_data(data_blocks) <= free_blocks:
            return data_blocks
    raise RuntimeError(f'cannot consume {free_blocks} free block(s)')


def fill_volume(vol):
    fills = []
    idx = 0
    while vol.free_blocks:
        before = vol.free_blocks
        data_blocks = largest_payload_blocks(before)
        data = FILL_BYTE * (data_blocks * 512)
        path = f'/FILLD/F{idx:02d}'
        vol.write_file(path, data, file_type=BIN, aux_type=0)
        after = vol.free_blocks
        fills.append((path, len(data), before - after))
        if after >= before:
            raise RuntimeError('filler did not reduce free blocks')
        idx += 1
    return fills


def main():
    missing = []
    for path, label in ([(CARRIER_IMG, 'carrier volume'),
                         (KERNEL_BIN, 'vendored ProDOS kernel'),
                         (SYS_BIN, 'MAUXE2E.SYSTEM')]
                        + [(os.path.join(BUILD, f'{t}.bin'), f'{t} binary')
                           for t in TOOLS]):
        if not os.path.exists(path):
            missing.append(f'{label}: {path}')
    if missing:
        for m in missing:
            print(f'error: missing {m}', file=sys.stderr)
        return 2

    prodos.create(OUT_IMG, name=CARRIER_VOL, blocks=VOL_BLOCKS)
    with open(CARRIER_IMG, 'rb') as f:
        boot = f.read(BOOT_BYTES)
    if len(boot) != BOOT_BYTES or boot == bytes(BOOT_BYTES):
        print(f'error: {CARRIER_IMG} has no boot block to copy',
              file=sys.stderr)
        return 2
    with open(OUT_IMG, 'r+b') as f:
        f.write(boot)

    vol = prodos.Volume(OUT_IMG)
    try:
        with open(KERNEL_BIN, 'rb') as f:
            kernel = f.read()
        with open(SYS_BIN, 'rb') as f:
            system = f.read()
        vol.write_file('/PRODOS', kernel, file_type=SYS,
                       aux_type=SYS_AUX, overwrite=True)
        vol.write_file('/MAUX.SYSTEM', system, file_type=SYS,
                       aux_type=SYS_AUX, overwrite=True)

        sizes, shas = {}, {}
        vol.mkdir('/BIN')
        for tool in TOOLS:
            path = os.path.join(BUILD, f'{tool}.bin')
            with open(path, 'rb') as f:
                data = f.read()
            sizes[tool] = len(data)
            shas[tool] = hashlib.sha256(data).hexdigest()[:12]
            vol.write_file(f'/BIN/{tool.upper()}', data, file_type=BIN,
                           aux_type=LOAD_AUX, overwrite=True)

        for path in ('/E2E', '/WF', '/WF/MVDIR', '/WF/MVDST', '/FILLD'):
            vol.mkdir(path)
        stage_txt(vol, '/E2E/SCRIPT', SCRIPT_BYTES)
        for name in CAPTURES:
            stage_txt(vol, f'/E2E/{name}')

        stage_txt(vol, '/WF/CPSRC', CPSRC_BYTES)
        stage_txt(vol, '/WF/MVDIR/MVSRC', MVSRC_BYTES)
        stage_txt(vol, '/WF/TEESRC', TEESRC_BYTES)
        stage_txt(vol, '/WF/PROT', PROT_BYTES)
        stage_txt(vol, '/WF/EDSCRIPT', EDSCRIPT_BYTES)
        vol.set_file_info('/WF/PROT', access=LOCKED_ACCESS)

        before_fill = vol.free_blocks
        fills = fill_volume(vol)
        free, total = vol.free_blocks, vol.total_blocks
    finally:
        vol.close()

    print(f'[build-writefail] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-writefail] MAUX.SYSTEM {len(system)}B '
          f'{hashlib.sha256(system).hexdigest()[:12]}')
    for t in TOOLS:
        print(f'[build-writefail]   {t:6} {sizes[t]:6}B  sha256:{shas[t]}')
    print(f'[build-writefail] staged script {len(SCRIPT_LINES)} lines; '
          f'longest line {max(len(line) for line in SCRIPT_LINES)} chars')
    print(f'[build-writefail] volume free before fill: {before_fill} '
          f'of {total} blocks')
    for path, nbytes, blocks in fills:
        print(f'[build-writefail]   filler {path} {nbytes}B -> '
              f'{blocks} block(s)')
    print(f'[build-writefail] protected target access=${LOCKED_ACCESS:02X}')
    print(f'[build-writefail] volume free after fill: {free} of '
          f'{total} blocks')
    if free != 0:
        print('[build-writefail] FAIL: expected zero free blocks',
              file=sys.stderr)
        return 1
    print(f'[build-writefail] {OUT_IMG} ready '
          f'({os.path.getsize(OUT_IMG)} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
