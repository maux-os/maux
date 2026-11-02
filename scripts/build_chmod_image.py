#!/usr/bin/env python3
"""Build the chmod/df acceptance-gate image (`make check-chmod`).

Companion to src/test/chmodtest.s / chmodtestb.s / scripts/check_chmod.py.
Same shape as scripts/build_fleet_image.py: stage input files + a script +
the userland binaries onto a carrier volume copy, boot a hardwired parent
process that spawns `sh` (stdin redirected from the script) for phase 1,
then spawns `rm` directly for phase 2. Every expected byte string lives in
THIS module -- scripts/check_chmod.py imports them and never hand-computes
an expectation of its own, EXCEPT block counts, which it re-derives from
the real built image the same way this module does (never a hand-picked
number -- the task's own "never invent a number" rule cuts both ways).
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
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXCHMOD.SYSTEM')
SH_BIN = os.path.join(ROOT, 'build', 'sh.bin')
CHMOD_BIN = os.path.join(ROOT, 'build', 'chmod.bin')
DF_BIN = os.path.join(ROOT, 'build', 'df.bin')
RM_BIN = os.path.join(ROOT, 'build', 'rm.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'chmod.po')


def hitext(s):
    return bytes(ord(c) | 0x80 for c in s)


CR = bytes([0x8D])


def hilines(*lines):
    return b''.join(hitext(l) + CR for l in lines)


# ---------------------------------------------------------------------
# Staged input files. LOCKFILE/RWFILE are plain TXT files with distinct
# content, staged with a2til's own default access byte ($E3 -- D/RN/B/W/R
# all set, see a2til/prodos.py Volume.write_file) so the "lock" round
# trip below has somewhere real to start from.
# ---------------------------------------------------------------------
LOCKFILE_BYTES = hilines('this file will be locked')
RWFILE_BYTES = hilines('this file is locked then unlocked')

STAGED_ACCESS = 0xE3           # a2til's own write_file default
LOCKED_ACCESS = 0x21           # STAGED_ACCESS with D/RN/W cleared
                               # (-dnw): 0xE3 & ~($80|$40|$02)

# ---------------------------------------------------------------------
# The shell script `sh` runs from fd 0 (staged as /mnt/MAUX/SCRIPT).
# `CD /mnt/MAUX` first -- this synthetic boot harness never runs ProDOS's
# own STARTUP, so nothing has set a prefix yet; `DF .` needs one (same
# reason ls.s/du.s/pwd.s's own "no current directory" path exists).
# NOT bare `DF`: with no operand df lists every ONLINE volume through
# SYS_DEVLIST, whose real body lives in the full kernel's KSEG -- this
# test kernel carries only the stub (ERR_NOSYS), so the listing form is
# check-df's, on the real kernel. `DF .` is the working-directory form.
# ---------------------------------------------------------------------
SCRIPT_TEXT = (
    'CD /mnt/MAUX\r'
    'CHMOD -dnw /mnt/MAUX/LOCKFILE\r'
    'CHMOD -dnw /mnt/MAUX/RWFILE\r'
    'CHMOD +dnw /mnt/MAUX/RWFILE\r'
    'DF . > /mnt/MAUX/DFOUT\r'
    'DF MAUX > /mnt/MAUX/DFOUT2\r'
    'EXIT\r'
)
SCRIPT_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                     for c in SCRIPT_TEXT)

# ---------------------------------------------------------------------
# EXPECTED phase-2 (`rm`, spawned directly) result: LOCKFILE is still
# locked (-dnw), so DESTROY must fail -- exit 1, "rm: cannot unlink
# /mnt/MAUX/LOCKFILE" on stderr (rm.s's own ERRMSG + the path argument).
# ---------------------------------------------------------------------
EXPECT_RM_STATUS = 1
EXPECT_RM_STDERR = (
    hitext('rm: cannot unlink ') + hitext('/mnt/MAUX/LOCKFILE') + CR
)


def main():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXCHMOD.SYSTEM'),
        (SH_BIN, 'sh userland binary'),
        (CHMOD_BIN, 'chmod userland binary'),
        (DF_BIN, 'df userland binary'),
        (RM_BIN, 'rm userland binary'),
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
    with open(CHMOD_BIN, 'rb') as f:
        chmodbin = f.read()
    with open(DF_BIN, 'rb') as f:
        dfbin = f.read()
    with open(RM_BIN, 'rb') as f:
        rmbin = f.read()

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
    prodos.write(f'{root}/BIN/CHMOD', chmodbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/DF', dfbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/RM', rmbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)

    prodos.write(f'{root}/LOCKFILE', LOCKFILE_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/RWFILE', RWFILE_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/SCRIPT', SCRIPT_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.unmount(CARRIER_VOL)

    expect = compute_expectations(OUT_IMG)

    print(f'[build-chmod] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-chmod] kept={kept} removed={removed}')
    print(f'[build-chmod] wrote MAUX.SYSTEM ({len(system)}B), SH '
          f'({len(shbin)}B), CHMOD ({len(chmodbin)}B), DF ({len(dfbin)}B), '
          f'RM ({len(rmbin)}B)')
    print(f"[build-chmod] {OUT_IMG} ready ({expect['image_size']} bytes, "
          f"{expect['total_blocks']} blocks)")
    return 0


def compute_expectations(disk):
    """Derive every expectation FROM THE ALREADY-STAGED IMAGE -- never a
    hand-typed number. Read-only (mount, stat, unmount) -- safe to call
    any number of times, but MUST be called before the emulator mutates
    `disk`, since it snapshots the PRE-run state (LOCKFILE/RWFILE's
    metadata, the volume's total_blocks) that a post-run read is then
    compared against.

    total_blocks is a volume-format constant, not a per-file count --
    ProDOS itself requires it to equal the image's own byte size / 512
    (learning:01KWK8EM9RWMBGTSE3JHPXE40F's own DOS-order discriminator
    relies on exactly this equality), so the image's OWN file size is
    the ground truth df.s must reproduce.
    """
    prodos.mount(disk, replace=True)
    root = f'/mnt/{CARRIER_VOL}'
    lock_before = prodos.stat(f'{root}/LOCKFILE')
    rw_before = prodos.stat(f'{root}/RWFILE')
    assert lock_before.access == STAGED_ACCESS, (
        f'staging assumption broke: LOCKFILE access is '
        f'${lock_before.access:02x}, expected ${STAGED_ACCESS:02x}')
    assert rw_before.access == STAGED_ACCESS, (
        f'staging assumption broke: RWFILE access is '
        f'${rw_before.access:02x}, expected ${STAGED_ACCESS:02x}')
    meta = {
        'LOCKFILE': {
            'access': LOCKED_ACCESS,           # chmod -dnw applied once
            'type': lock_before.type,
            'aux_type': lock_before.aux_type,
            'eof': lock_before.eof,
            'blocks_used': lock_before.blocks_used,
            'creation': lock_before.creation,
            'last_mod': lock_before.last_mod,
        },
        'RWFILE': {
            'access': STAGED_ACCESS,           # -dnw then +dnw: round trip
            'type': rw_before.type,
            'aux_type': rw_before.aux_type,
            'eof': rw_before.eof,
            'blocks_used': rw_before.blocks_used,
            'creation': rw_before.creation,
            'last_mod': rw_before.last_mod,
        },
    }
    prodos.unmount(CARRIER_VOL)

    image_size = os.path.getsize(disk)
    assert image_size % 512 == 0, (
        f'{disk} is {image_size} bytes -- not a whole number of blocks')
    total_blocks = image_size // 512

    # df's row is the POSIX -P form now (docs/DU-DF.md): header, then
    # "/VOL total used avail pct% /VOL". Total is the image's own
    # block count. Used is NOT a pre-run constant -- the script's own
    # `> DFOUT` / `> DFOUT2` redirections allocate blocks on this
    # volume before df stats it -- so the gate checks the row's
    # structure and brackets Used between the pre-run count and the
    # post-run one (check_chmod.py); check-df owns the exact numbers.
    v = prodos.Volume(disk)
    try:
        used_pre = total_blocks - v.free_blocks
    finally:
        v.close()

    return {
        'meta': meta,
        'image_size': image_size,
        'total_blocks': total_blocks,
        'used_pre': used_pre,
    }


if __name__ == '__main__':
    raise SystemExit(main())
