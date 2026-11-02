#!/usr/bin/env python3
"""build_ascore_image.py -- work disk for building and gating the PATCHED
`as` core (task #8 phase B, docs/AS-DESIGN.md sections 2/6/13).

Extends build_merlin_src_image.py's shape (task #7's stock work disk) with
the maux patch overlay: the seven core-chain sources are staged to
/SOURCE/ with src/merlin/patches.py applied first, then the same KBD->EQU
substitution the stock pipeline uses (primaries only). MACASS.S is both a
primary AND patched; ASSMAIN.S / ASS.BNK1.S / SYMPRINT.S are not
primaries -- MACASS.S PUTs them at assembly time from the same /SOURCE/
path, so each is staged individually.

TWO ARTIFACTS FROM ONE OVERLAY (docs/AS-DESIGN.md section 13, ruling 2):
--variant hardware (default) is today's check-ascore group set
(src/merlin/patches.py's HARDWARE_GROUPS) -- unchanged meaning, unchanged
output paths (build/ascore.po, build/merlin_patched/), so check-ascore's
own 6/6 teeth stay exactly what they were. --variant process adds P10
(the RAMRD/RAMWRT-class removal, docs/AS-P10-ENUMERATION.txt) and writes
to DIFFERENT, unambiguous paths (build/ascore-process.po,
build/merlin_patched_process/) so the two variants never collide and both
can exist on disk at once. `--exclude` (teeth) still applies on TOP of
whichever variant's own base set -- see patches.exclude_for_variant().

The derived patched sources are also written to the variant's own
PATCHED_DIR so a human (or check_ascore.py's divergence audit) can diff
them against vendor/merlin/ on the host without mounting anything.

P2: /SOURCE/PARMS is written from the embedded, verified 44-byte blob in
src/merlin/patches.py (VALIDATE.PO ships none) -- see PARMS_BYTES there
for provenance and the two asserted bytes.

TESTDSK.S is staged for check-ascore's P7 phase: a 3-byte program whose
`DSK TDSKOBJ` directive must be IGNORED by the patched core (no TDSKOBJ
file may appear) and must produce the file under a P7-reverted build.

MUST BE REBUILT BEFORE EVERY GATE RUN (PHONY, like mli-image):
check_ascore.py's artifact phase REPLACES /SOURCE/MERLIN.SYSTEM on this
image with the freshly-rebuilt patched core, after which the image no
longer has a stock assembler to rebuild with -- a second gate run against
the same image would drive the patched (SAV-neutered) core through the
STEPBYSTEP build and silently produce no ASMOBJ objects at all.

Teeth flags (each builds a deliberately-broken variant; check_ascore.py
run against it must FAIL, and the failure must be watched -- see
docs/AS-DESIGN.md's phase-B addendum for the recorded outcomes):
  --exclude P1[,P4,P5,P7,P10]  revert whole patch groups on top of
                           the variant's own base set
  --corrupt-packop2        one-operand mutation in PACKOP2.S (object
                           byte-compare teeth)
  --sabotage-audit         flip one staged byte at a non-patch site
                           (divergence-audit teeth)

Needs vendor/VALIDATE.PO and vendor/merlin/ (`make vendor-merlin`).
"""
import argparse
import os
import shutil
import sys

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SCRIPTS)
sys.path.insert(0, SCRIPTS)
from build_merlin_src_image import strip_kbd_bytes  # noqa: E402

sys.path.insert(0, os.path.join(ROOT, 'src', 'merlin'))
import patches  # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import a2til  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

SRC_IMG = os.path.join(ROOT, 'vendor', 'VALIDATE.PO')
MERLIN_SRC = os.path.join(ROOT, 'vendor', 'merlin')

# Variant-named defaults -- hardware keeps the ORIGINAL paths byte-for-
# byte so nothing that already depends on them (Makefile, check_ascore.py
# callers) needs to change; process gets its own, unambiguous names.
VARIANT_DEFAULTS = {
    'hardware': {
        'img': os.path.join(ROOT, 'build', 'ascore.po'),
        'patched_dir': os.path.join(ROOT, 'build', 'merlin_patched'),
    },
    'process': {
        'img': os.path.join(ROOT, 'build', 'ascore-process.po'),
        'patched_dir': os.path.join(ROOT, 'build', 'merlin_patched_process'),
    },
}
OUT_IMG = VARIANT_DEFAULTS['hardware']['img']          # back-compat default
PATCHED_DIR = VARIANT_DEFAULTS['hardware']['patched_dir']

# STEPBYSTEP's four top-level sources, in its order.
PRIMARY = ['INTERPRETER.S', 'MACED.S', 'MACEXEC.S', 'MACASS.S']
# Patched files MACASS.S PUTs (staged too, no KBD directives inside).
# LINKER.S added 2026-08-20: MACASS.S:237-241 is `ORG $D000 / PUT LINKER
# / PUT ASS.BNK1`, so LINKER.S is part of the bank-1 object as.s embeds
# and P10 sweeps its 9 RAMRD/RAMWRT sites. Omitting it here left those
# 7 patch entries silently UNAPPLIED (29/36) -- the sweep was inert, and
# the divergence audit was the only thing that noticed. A file that
# patches.py patches must be staged here, or the patch does nothing.
PUT_INCLUDED = ['ASSMAIN.S', 'ASS.BNK1.S', 'SYMPRINT.S', 'LINKER.S']

# P7-phase test program: DSK must be a no-op in the patched core. Merlin
# dialect, will be encoded high-bit/$8D on staging.
TESTDSK_LINES = [
    ' TR ADR',
    ' ORG $300',
    ' DSK TDSKOBJ',
    ' LDA #1',
    ' RTS',
]

# --corrupt-packop2: one operand byte changes, same length, 0 errors --
# exactly the class of miscompile assertion (b) exists to catch.
PACKOP2_CORRUPT = ('PACKOP2.S', 5, 5, [' LDA #$4C'], [' LDA #$4D'])


def encode_source(lines):
    return b'\x8d'.join(patches.encode_line(t) for t in lines) + b'\x8d'


def derive(name, all_patches):
    """vendor bytes -> (patched [+ KBD-stripped] bytes, n_patches, kbd)."""
    raw = open(os.path.join(MERLIN_SRC, name), 'rb').read()
    n_patch = 0
    if name in all_patches:
        raw, n_patch = patches.apply_patches(raw, all_patches[name], name)
    kbd = []
    if name in PRIMARY:
        raw, kbd = strip_kbd_bytes(raw)
    return raw, n_patch, kbd


def build(out_img, variant='hardware', exclude=(), corrupt_packop2=False,
          sabotage_audit=False, patched_dir=None):
    for path in (SRC_IMG, MERLIN_SRC):
        if not os.path.exists(path):
            print(f'error: {path} not found -- run `make vendor-merlin` '
                  f'first', file=sys.stderr)
            return 2

    if patched_dir is None:
        patched_dir = VARIANT_DEFAULTS[variant]['patched_dir']
    full_exclude = patches.exclude_for_variant(variant, exclude)

    os.makedirs(os.path.join(ROOT, 'build'), exist_ok=True)
    os.makedirs(patched_dir, exist_ok=True)
    shutil.copyfile(SRC_IMG, out_img)
    vol = a2til.open_image(out_img)
    all_patches = patches.build_all_patches(exclude=full_exclude)

    total_patches, total_kbd = 0, 0
    for name in PRIMARY + PUT_INCLUDED:
        data, n_patch, kbd = derive(name, all_patches)
        vol.write_file(f'/SOURCE/{name}', data, file_type=0x04, aux_type=0,
                       overwrite=True)
        with open(os.path.join(patched_dir, name), 'wb') as fh:
            fh.write(data)
        kbd_shown = ', '.join(f'{n}={v}' for n, v in kbd) or '-'
        print(f'[ascore] {name:<16} {len(data):>6}B  patches={n_patch:<2} '
              f'KBD->EQU: {kbd_shown}')
        total_patches += n_patch
        total_kbd += len(kbd)

    vol.write_file('/SOURCE/PARMS', patches.PARMS_BYTES, file_type=0x06,
                   aux_type=0x8000, overwrite=True)
    print(f'[ascore] PARMS            {len(patches.PARMS_BYTES):>6}B  '
          f'embedded blob (P2 bytes asserted at import)')

    vol.write_file('/SOURCE/TESTDSK.S', encode_source(TESTDSK_LINES),
                   file_type=0x04, aux_type=0, overwrite=True)
    print('[ascore] TESTDSK.S staged (P7 phase: DSK must stay a no-op)')

    if corrupt_packop2:
        raw = open(os.path.join(MERLIN_SRC, 'PACKOP2.S'), 'rb').read()
        data, _ = patches.apply_patches(raw, [PACKOP2_CORRUPT], 'PACKOP2.S')
        vol.write_file('/SOURCE/PACKOP2.S', data, file_type=0x04,
                       aux_type=0, overwrite=True)
        print('[ascore] TEETH: PACKOP2.S corrupted (LDA #$4C -> #$4D)')

    if sabotage_audit:
        staged = bytearray(vol.read_file('/SOURCE/ASS.BNK1.S'))
        staged[5000] ^= 0x01     # mid-file, not at any patch site
        vol.write_file('/SOURCE/ASS.BNK1.S', bytes(staged), file_type=0x04,
                       aux_type=0, overwrite=True)
        print('[ascore] TEETH: unauthorized byte flipped in staged '
              'ASS.BNK1.S @5000')

    vol.flush()

    expected = sum(len(v) for v in all_patches.values())
    if total_patches != expected or total_kbd != 5:
        print(f'[ascore] ERROR: applied {total_patches}/{expected} patches, '
              f'{total_kbd}/5 KBD substitutions', file=sys.stderr)
        return 1
    excl = ','.join(sorted(full_exclude)) or 'none'
    print(f'[ascore] variant={variant} {out_img} ready -- {total_patches} '
          f'patches (excluded: {excl}), {total_kbd} KBD subs, PARMS + '
          f'TESTDSK staged')
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--variant', choices=sorted(VARIANT_DEFAULTS),
                    default='hardware',
                    help='hardware = today\'s check-ascore set (default); '
                         'process = hardware + P10 (bank-agnostic core, '
                         'what as.s embeds) -- docs/AS-DESIGN.md section 13')
    ap.add_argument('--out', default=None,
                    help='defaults to the variant\'s own path '
                         '(build/ascore.po or build/ascore-process.po)')
    ap.add_argument('--exclude', default='',
                    help='comma-separated patch groups to revert on top '
                         'of the variant\'s own base set (P1,P4,P5,P7,'
                         'P10) -- teeth builds')
    ap.add_argument('--corrupt-packop2', action='store_true')
    ap.add_argument('--sabotage-audit', action='store_true')
    args = ap.parse_args()
    out_img = args.out or VARIANT_DEFAULTS[args.variant]['img']
    exclude = {g.strip() for g in args.exclude.split(',') if g.strip()}
    bad = exclude - set(patches.GROUPS)
    if bad:
        print(f'error: unknown group(s) {sorted(bad)}; valid: '
              f'{sorted(patches.GROUPS)}', file=sys.stderr)
        return 2
    return build(out_img, variant=args.variant, exclude=exclude,
                 corrupt_packop2=args.corrupt_packop2,
                 sabotage_audit=args.sabotage_audit)


if __name__ == '__main__':
    raise SystemExit(main())
