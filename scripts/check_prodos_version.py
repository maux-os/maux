#!/usr/bin/env python3
"""check-prodos-version -- every built image boots the ProDOS the ruling
names (docs/PRODOS-VERSION.md: the 2.4 kernel, banner `ProDOS 8 V2.4`).

Why this gate exists: from 2026-08-19 to 2026-10-08 the tree's documented
kernel was 2.5 while every image booted 2.4, because a spike's global
`PRODOSBIN :=` override (Makefile) silently beat the `?=` default and the
builders' own fallbacks. Nothing read the version off an image, so the
drift lived in a comment for seven weeks. This reads it.

What it checks: for each image under build/ (.po/.hdv/.2mg) that is a
MAUX BOOT IMAGE -- a ProDOS volume whose root holds a `PRODOS` file and a
`MAUX*.SYSTEM` -- mount read-only with a2til, read `PRODOS`, and require
the 2.4 banner and NOT the 2.5 one. Images deliberately built on another
kernel are listed in ALLOW_OTHER by basename (check-dirfull's 2.5 leg).
Skipped, and counted by class so a vanished population shows: raw kernel
test images that are not ProDOS volumes at all (schedtest, forktest,
...), the Merlin-carrier `SOURCE` volumes of the legacy selfmake line
(ProDOS 2.0.3 from VALIDATE.PO, no maux kernel on them), the stock-ProDOS
MLI oracle (`MLIVAL.SYSTEM` on 2.0.1), scratch second volumes, and
nulib2 extraction results. None of those boots maux.

Teeth: `--self-test` runs the same predicate on vendor/ProDOS_2_5_a8.dsk
(must FAIL) and on vendor/ProDOS_2_4.dsk (must PASS); the gate refuses to
report green if either self-test does not behave.

Exit 0 = green. Exit 1 = a red, listed. Exit 2 = rig problem (a2til
missing, no images found).
"""
import glob
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
try:
    from a2til import prodos  # noqa: E402
    import vpath  # noqa: F401  (docs/VROOT.md)
except Exception as exc:  # pragma: no cover
    print(f'check-prodos-version: cannot import a2til: {exc}')
    sys.exit(2)

WANT = b'ProDOS 8 V2.4'
REFUSE = (b'ProDOS 8 V2.5', b'V2.5.0')
ALLOW_OTHER = {'dirfull-25.po'}      # check-dirfull's deliberate 2.5 leg
MIN_IMAGES = 10                       # fewer than this = the rig is wrong


def banner_of(image, require_maux=False):
    """Return (status, detail, volname): status in {'ok','other','none',
    'notvol','notmaux'}; volname is the mounted volume's name (None when
    it would not mount) -- check-volname reads it from this same walk."""
    name = None
    try:
        try:
            name = prodos.mount(image, readonly=True)
        except Exception as exc:
            return 'notvol', str(exc), None
        if require_maux:
            root = [n.upper() for n in prodos.listdir(f'/{name}')]
            if not any(n.startswith('MAUX') and n.endswith('.SYSTEM')
                       for n in root):
                return 'notmaux', 'no MAUX*.SYSTEM in the root', name
        try:
            raw = prodos.read(f'/{name}/PRODOS')
        except Exception:
            return 'none', 'no root PRODOS file', name
        data = bytes(c & 0x7F for c in raw)   # the banner is high-bit ASCII
        if WANT in data and not any(r in data for r in REFUSE):
            return 'ok', '2.4', name
        i = data.find(b'ProDOS 8 V')
        found = data[i:i + 20].decode('ascii', 'replace') if i >= 0 else '(no banner)'
        return 'other', found, name
    finally:
        if name is not None:
            try:
                prodos.unmount(name)
            except Exception:
                try:
                    prodos._session.unmount(prodos._foldname(name))
                except Exception:
                    pass


def self_test():
    bad = banner_of(os.path.join(ROOT, 'vendor', 'ProDOS_2_5_a8.dsk'))
    good = banner_of(os.path.join(ROOT, 'vendor', 'ProDOS_2_4.dsk'))
    ok = bad[0] == 'other' and good[0] == 'ok'
    print(f'self-test: 2.5 disk -> {bad[:2]}, 2.4 disk -> {good[:2]}: '
          f'{"PASS" if ok else "FAIL"}')
    return ok


def boot_images(images):
    """The ONE walk over built images (check-volname reuses it, per
    docs/VROOT.md: no second mount loop): yield (basename, status,
    detail, volname) for every image that is a MAUX boot image."""
    for img in images:
        status, detail, name = banner_of(img, require_maux=True)
        if status in ('notvol', 'notmaux', 'none'):
            continue
        yield os.path.basename(img), status, detail, name


def main(argv):
    if not self_test():
        print('check-prodos-version: self-test failed; the predicate has no teeth')
        return 2
    if '--self-test' in argv:
        return 0
    images = sorted(set(sum((glob.glob(os.path.join(ROOT, 'build', pat))
                             for pat in ('*.po', '*.hdv', '*.2mg')), [])))
    if len(images) < MIN_IMAGES:
        print(f'check-prodos-version: only {len(images)} image(s) under build/; '
              f'need {MIN_IMAGES} -- run the image targets first')
        return 2
    reds, checked, allowed = [], 0, 0
    skipped = {'notvol': 0, 'notmaux': 0, 'none': 0}
    for img in images:
        base = os.path.basename(img)
        status, detail, _name = banner_of(img, require_maux=True)
        if status in skipped:
            skipped[status] += 1
            continue
        if base in ALLOW_OTHER:
            allowed += 1
            if status == 'ok':
                reds.append(f'{base}: listed as another kernel but boots 2.4 '
                            f'-- the allow-list is stale')
            continue
        checked += 1
        if status != 'ok':
            reds.append(f'{base}: {detail}')
    for r in reds:
        print(f'RED  {r}')
    print(f'check-prodos-version: {checked} maux boot image(s) on ProDOS 2.4, '
          f'{allowed} allow-listed, skipped {skipped["notvol"]} non-ProDOS, '
          f'{skipped["notmaux"]} non-maux volumes, {skipped["none"]} without '
          f'PRODOS; {len(reds)} red')
    if checked < MIN_IMAGES:
        print(f'check-prodos-version: only {checked} maux boot images seen; '
              f'need {MIN_IMAGES}')
        return 2
    return 1 if reds else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
