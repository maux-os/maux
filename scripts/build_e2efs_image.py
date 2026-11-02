#!/usr/bin/env python3
"""Build the T4 filesystem-tranche image (`make e2efs-image`).

TRANSPORT, per CONTRACT sec 3 (corrected 2026-08-23): `a2til mirror` is
used ONLY for the two FLAT directories, /mnt/MAUX/E2E (SCRIPT, ST) and
/mnt/MAUX/OUT (Onn) -- exactly like stage 1's scripts/build_e2e_image.py,
same reasons (`--once --raw`, the `#040000` suffix, the sidecar, one
transaction per pass; see that file's header for a2til mirror's own
feature list, which this file does not repeat).

/mnt/MAUX/RO and /mnt/MAUX/MUT are staged with the **`prodos` module directly**
(mkdir/write), because `a2til mirror` cannot do it: it does not recurse
into subdirectories, does not create them on either side, and does not
mirror empty directories (`~/src/a2til/a2til/mirror.py:232-234`,
CONTRACT sec 3.0). This follows scripts/build_e2e_image.py:107-124's
own precedent (`strip_volume`'s recursive prodos.mkdir/write/rmdir) and
scripts/check_v1_system.py:164-196's ("boot, guest mutates, inspect the
volume host-side"). e2e_fsmap.stage_tree()/host_stage_tree() do the
actual writing; this file just calls them for RO and every MUT_TREES
entry.

Each of the FOUR directories gets its own host-side representation and,
for the two that ARE mirrored, its OWN `.a2til-mirror.json` sidecar (a
shared sidecar across pairs is a conflict generator -- CONTRACT sec 3.2).

DISK BUDGET (CONTRACT sec 4): the build MUST fail if fewer than 250
blocks are free after staging. Measured (TL, 2026-08-23): stage 1's
280-block carrier ran out entirely; the 800K/1600-block volume stage 1
uses leaves ~1395 free with 11 binaries staged, so this tranche -- ~16
binaries plus RO/MUT content -- has real headroom, but the gate is an
assertion, not a hope.
"""
import hashlib
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e_fs_common as FC    # noqa: E402
import e2e_fs_corpus as CORP  # noqa: E402
import e2e_fsmap as FM        # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')
CARRIER_IMG = os.environ.get('PRODOS_CARRIER_IMG',
                             os.path.join(ROOT, 'vendor', 'prodos-basic.po'))
CARRIER_VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')
KERNEL_BIN = os.environ.get('PRODOS_KERNEL_BIN',
                            os.path.join(ROOT, 'vendor', 'ProDOS-2.4.bin'))
SYS_BIN = os.path.join(BUILD, 'MAUXE2E.SYSTEM')       # reused, UNCHANGED
OUT_IMG = os.path.join(BUILD, 'e2efs.po')
#: The `.pre` VolumeSnapshot (TL, 2026-08-23), persisted as JSON
#: alongside the image so check_e2e_fs.py loads it rather than
#: re-deriving it -- taken here, after ALL staging (RO/MUT/CTL/OUT) and
#: strictly BEFORE the boot, which happens in a separate process/script.
PRE_SNAPSHOT = OUT_IMG + '.pre.json'

#: CONTRACT sec 3.1's ASCII layout row, plus `wc` (TL note, 2026-08-23:
#: "roughly sixteen (add ls find du rm mv cp mkdir chmod file ps pwd df
#: cat wc)").  `sh`/`echo` are the harness's own; the rest are this
#: tranche's tool roster across all six packages.
TOOLS = ['ls', 'find', 'du', 'rm', 'mv', 'cp', 'mkdir', 'chmod', 'file', 'touch',
        'ps', 'pwd', 'df', 'cat', 'wc']
NEEDED = ['sh', 'echo'] + TOOLS

HOSTDIR_RO = os.environ.get('E2EFS_HOSTDIR_RO', os.path.join(BUILD, 'e2efs-ro'))
HOSTDIR_MUT = os.environ.get('E2EFS_HOSTDIR_MUT', os.path.join(BUILD, 'e2efs-mut'))
MIRRORDIR_CTL = os.environ.get('E2EFS_MIRRORDIR_CTL',
                               os.path.join(BUILD, 'e2efs-ctl'))
MIRRORDIR_OUT = os.environ.get('E2EFS_MIRRORDIR_OUT',
                               os.path.join(BUILD, 'e2efs-out'))

A2TIL_ROOT = os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til'))

VOL_BLOCKS = 1600
BOOT_BYTES = 1024
MIN_FREE_AFTER_BUILD = 250       # CONTRACT sec 4


def mirror(image, imgdir, localdir, label):
    """Identical shape to scripts/build_e2e_image.py's mirror() -- one
    `a2til mirror --once --raw` pass, its log lines printed and returned."""
    argv = [sys.executable, '-m', 'a2til', 'mirror',
           f'{os.path.abspath(image)}:{vpath.phys(imgdir)}', localdir,
           '--once', '--raw', '--interval', '1']
    proc = subprocess.run(argv, cwd=A2TIL_ROOT, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True)
    for line in proc.stdout.splitlines():
        print(f'[{label}] mirror: {line}')
    if proc.returncode != 0:
        raise RuntimeError(f'a2til mirror failed ({proc.returncode})')
    return proc.stdout.splitlines()


def main():
    if FM.IMG_CTL != f'/mnt/{CARRIER_VOL}/E2E':
        print(f'error: src/test/e2etestb.s hardwires the script path '
             f'{FM.IMG_CTL}/SCRIPT, which does not match carrier volume '
             f'{CARRIER_VOL}', file=sys.stderr)
        return 2

    missing = []
    for path, label in ([(CARRIER_IMG, 'carrier volume'),
                        (KERNEL_BIN, 'vendored ProDOS kernel'),
                        (SYS_BIN, 'MAUXE2E.SYSTEM (built by stage 1; '
                                 'reused UNCHANGED)')]
                       + [(os.path.join(BUILD, f'{t}.bin'), f'{t} binary')
                          for t in NEEDED]):
        if not os.path.exists(path):
            missing.append(f'{label}: {path}')
    if missing:
        for m in missing:
            print(f'error: missing {m}', file=sys.stderr)
        print('       (`make build/<tool>.bin` builds one tool without '
             'dragging in check-userland\'s ascore-process dependency; '
             '`make check-e2e` builds MAUXE2E.SYSTEM)', file=sys.stderr)
        return 2

    # Fresh everything: a stale RO/MUT host tree or mirror sidecar from a
    # previous build would make this pass read as a conflict, or stage
    # yesterday's fixtures under today's names.
    for d in (HOSTDIR_RO, HOSTDIR_MUT, MIRRORDIR_CTL, MIRRORDIR_OUT):
        shutil.rmtree(d, ignore_errors=True)
    CORP.write_host_ro(HOSTDIR_RO)
    CORP.write_host_mut(HOSTDIR_MUT)
    os.makedirs(MIRRORDIR_CTL, exist_ok=True)
    os.makedirs(MIRRORDIR_OUT, exist_ok=True)   # OUT starts empty (pulled later)

    # A fresh, larger volume, boot blocks spliced from the carrier --
    # identical technique to scripts/build_e2e_image.py (a2til's `create`
    # formats an empty volume; blocks 0-1 are the ProDOS boot loader, the
    # one thing on the carrier that is not a file, and finding+loading
    # PRODOS out of the volume directory is size-independent).
    prodos.create(OUT_IMG, name=CARRIER_VOL, blocks=VOL_BLOCKS)
    with open(CARRIER_IMG, 'rb') as f:
        boot = f.read(BOOT_BYTES)
    if len(boot) != BOOT_BYTES or boot == bytes(BOOT_BYTES):
        print(f'error: {CARRIER_IMG} has no boot block to copy', file=sys.stderr)
        return 2
    with open(OUT_IMG, 'r+b') as f:
        f.write(boot)

    prodos.mount(OUT_IMG)
    root = f'/mnt/{CARRIER_VOL}'

    with open(KERNEL_BIN, 'rb') as f:
        prodos.write(f'{root}/PRODOS', f.read(), file_type=0xFF,
                    aux_type=0x2000, overwrite=True)
    with open(SYS_BIN, 'rb') as f:
        system = f.read()
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF,
                aux_type=0x2000, overwrite=True)

    sizes, shas = {}, {}
    prodos.mkdir(f'{root}/BIN')
    for tool in NEEDED:
        with open(os.path.join(BUILD, f'{tool}.bin'), 'rb') as f:
            data = f.read()
        sizes[tool] = len(data)
        # SIZE IS NOT IDENTITY (learning:01M0P0AE3G3P2VSMYTZ2KEBAKB /
        # docs/E2E.md sec 9.10's ROTCK sabotage): a one-opcode change can
        # leave a binary's byte count unchanged, so hash every staged
        # binary and print it -- the same discipline stage 1's
        # build_e2e_image.py carries.
        shas[tool] = hashlib.sha256(data).hexdigest()[:12]
        prodos.write(f'{root}/BIN/{tool.upper()}', data, file_type=0x06,
                    aux_type=0x0800, overwrite=True)

    # CTL and OUT must exist before `a2til mirror` can push into them --
    # mirror does not create the image-side directory.
    prodos.mkdir(FM.IMG_CTL)
    prodos.mkdir(FM.IMG_OUT)

    # RO and MUT: prodos.mkdir/write, NEVER mirror -- CONTRACT sec 3.0.
    ro_written = CORP.stage_image_ro(root)
    mut_written = CORP.stage_image_mut(root)

    prodos.unmount(CARRIER_VOL)

    # The two mirrored pairs, each its OWN host dir + sidecar (CONTRACT
    # sec 3.2: "a shared sidecar across pairs is a conflict generator").
    with open(os.path.join(MIRRORDIR_CTL, 'SCRIPT#040000'), 'wb') as fh:
        fh.write(CORP.script_bytes())
    with open(os.path.join(MIRRORDIR_CTL, f'{FM.STATUS_NAME}#040000'), 'wb') as fh:
        fh.write(b'')   # pre-created EMPTY, so the first `>>` never creates it
    mirror(OUT_IMG, FM.IMG_CTL, MIRRORDIR_CTL, 'build-e2efs-ctl')
    mirror(OUT_IMG, FM.IMG_OUT, MIRRORDIR_OUT, 'build-e2efs-out')

    # Re-mount (session-level, for FM.snapshot_volume's prodos.scandir/
    # stat calls -- TL TRAP #1) now that BOTH mirror passes have landed,
    # so the pre-boot snapshot includes SCRIPT/ST too. This IS the `.pre`
    # snapshot CONTRACT's volume.pre wants: after staging, before boot.
    prodos.mount(OUT_IMG)
    try:
        ctl_entries = list(prodos.scandir(FM.IMG_CTL))
        out_entries = list(prodos.scandir(FM.IMG_OUT))
        snapshot = FM.snapshot_volume(root)
        pre = FC.VolumeSnapshot(snapshot)
        pre.save(PRE_SNAPSHOT)
    finally:
        prodos.unmount(CARRIER_VOL)

    vol = prodos.Volume(OUT_IMG, readonly=True)
    try:
        free, total = vol.free_blocks, vol.total_blocks
    finally:
        vol.close()

    # Per-module block cost (TL, 2026-08-23): attributed via
    # Registry.file_owner/dir_owner (RO) and .tree_owner (MUT, whose
    # entire subtree one module owns outright); an implicit RO
    # directory nobody declared in RO_DIRS (an auto-created parent of a
    # nested RO_FILES relpath) is not attributable to one module and
    # falls into 'shared scaffolding' below.
    module_costs = {}
    for relpath, owner in CORP.REGISTRY.file_owner.items():
        e = snapshot.get(f'{FM.IMG_RO}/{relpath}')
        if e:
            module_costs[owner] = module_costs.get(owner, 0) + e['blocks_used']
    for relpath, owner in CORP.REGISTRY.dir_owner.items():
        e = snapshot.get(f'{FM.IMG_RO}/{relpath}')
        if e:
            module_costs[owner] = module_costs.get(owner, 0) + e['blocks_used']
    for tree, owner in CORP.REGISTRY.tree_owner.items():
        prefix = f'{FM.IMG_MUT}/{tree}'
        total_tree = sum(f['blocks_used'] for p, f in snapshot.items()
                        if p == prefix or p.startswith(prefix + '/'))
        module_costs[owner] = module_costs.get(owner, 0) + total_tree
    ro_mut_total = sum(f['blocks_used'] for p, f in snapshot.items()
                       if p.startswith(FM.IMG_RO + '/') or p == FM.IMG_RO
                       or p.startswith(FM.IMG_MUT + '/') or p == FM.IMG_MUT)
    shared = ro_mut_total - sum(module_costs.values())

    print(f'[build-e2efs] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-e2efs] MAUX.SYSTEM {len(system)}B '
         f'{hashlib.sha256(system).hexdigest()[:12]}')
    for t in NEEDED:
        print(f'[build-e2efs]   {t:6} {sizes[t]:6}B  sha256:{shas[t]}')
    print(f'[build-e2efs] /mnt/MAUX/RO: {len(ro_written)} files staged via '
         f'prodos.write (never mirror)')
    print(f'[build-e2efs] /mnt/MAUX/MUT: {len(mut_written)} files across '
         f'{len(CORP.REGISTRY.mut_trees)} case-owned tree(s) '
         f'{sorted(CORP.REGISTRY.mut_trees)}, staged via prodos.write '
         f'(never mirror)')
    print(f'[build-e2efs] /mnt/MAUX/E2E (ctl pair): {len(ctl_entries)} entries '
         f'via a2til mirror --once --raw')
    print(f'[build-e2efs] /mnt/MAUX/OUT (out pair): {len(out_entries)} entries '
         f'via a2til mirror --once --raw (should be 0 -- OUT starts empty)')
    print(f'[build-e2efs] {len(CORP.CASES)} cases; longest sh line '
         f'{max(len(c.sh_line()) for c in CORP.CASES)} of LINEMAX '
         f'{FC.SH_LINEMAX}')
    for owner in sorted(module_costs):
        print(f'[build-e2efs]   block cost: {owner:32} {module_costs[owner]:5} blocks')
    if shared:
        print(f'[build-e2efs]   block cost: {"(shared RO/MUT scaffolding)":32} '
             f'{shared:5} blocks')
    print(f'[build-e2efs] volume.pre snapshot: {len(snapshot)} entries -> '
         f'{PRE_SNAPSHOT}')

    if free is not None:
        print(f'[build-e2efs] volume {free} of {total} blocks free '
             f'after staging')
        if free < MIN_FREE_AFTER_BUILD:
            print(f'error: only {free} blocks free after staging, need at '
                 f'least {MIN_FREE_AFTER_BUILD} (CONTRACT sec 4)',
                 file=sys.stderr)
            return 1

    print(f'[build-e2efs] {OUT_IMG} ready ({os.path.getsize(OUT_IMG)} bytes)')

    if len(out_entries) != 0:
        print(f'error: /mnt/MAUX/OUT has {len(out_entries)} entries before '
             f'the run -- it must start empty', file=sys.stderr)
        return 1
    if len(ctl_entries) != 2:
        print(f'error: /mnt/MAUX/E2E (ctl) has {len(ctl_entries)} entries, '
             f'expected 2 (SCRIPT, ST)', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
