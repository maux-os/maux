#!/usr/bin/env python3
"""check_bytes.py -- prove a refactor changed no emitted byte.

    make check-bytes REF=<commit>

Builds every image at REF, builds them again with the working tree, and
compares all artifacts. Used for changes that MUST be byte-neutral: comment
rewrapping, doc extraction, symbol renaming.

WHY THIS IS A SCRIPT AND NOT A SHELL ONE-LINER

Because the shell one-liner got it wrong. The comparison was originally run
with `find build -name '*.bin' -o -name '*.po'`, which silently omits the six
build/MAUX*.SYSTEM kernels -- the largest artifacts in the tree and the ones
containing all the kernel code being refactored. Several "byte-identical"
claims rested on a set that excluded the most important files. Defining the
artifact set ONCE, here, is the fix.

It also excludes merlin32's *_Output.txt listings deliberately: those contain
the symbol table, so a rename changes them legitimately and they are
diagnostics, not build output.

NEVER RUN THIS WHILE ANOTHER GATE'S EMULATOR BOOT IS IN FLIGHT. It runs
`make clean` TWICE, deleting every build/ image out from under any boot
that staged one -- the emulator grinds on against its unlinked file
handle while the other gate's end-of-run host-side reads find nothing.
Cost so far, 2026-08-29/30: one gate's ad-hoc rel.po staging (46 FILE
NOT FOUND, five probe cycles from the cause) and one 25-util sweep boot
killed mid-run. Serialize: emulator gates first, check-bytes alone.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')

# Every image target. Keep in sync with .PHONY in the Makefile.
TARGETS = ['image', 'fileprocess-image', 'mli-image', 'catread-image',
           'sh-image', 'play-image', 'v1-system-image', 'ed-image',
           'rel-image']

# Artifacts are everything the build drops in build/ EXCEPT assembler
# listings, which legitimately mention symbol names.
#
# .po IMAGES ARE FINGERPRINTED BY CONTENT, NOT RAW BYTES. Found
# 2026-08-29, on a change that was provably byte-neutral on every .bin
# and .SYSTEM: two consecutive runs of this gate failed on two
# DIFFERENT sets of .po files. a2til stamps every file's creation/mod
# time with datetime.now() at minute resolution (prodos.py has no
# override hook), so a raw .po hash differs whenever the REF pass and
# the working-tree pass straddle a minute boundary -- a false red that
# depends on the wall clock, the exact failure shape the
# wide-gate/narrow-gate lesson warns about (same change, different
# verdicts => diff the gate's ENVIRONMENT). The fingerprint below
# walks the volume with a2til itself and hashes the boot blocks plus
# every file's (path, type, aux, data) -- everything the image
# MEANS, nothing about when it was built. A parse failure falls back
# to the raw hash rather than passing silently.
def _po_fingerprint(p):
    import hashlib
    sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
    from a2til import prodos
    import vpath  # noqa: F401  (docs/VROOT.md)
    h = hashlib.sha1()
    with open(p, 'rb') as fh:
        h.update(fh.read(1024))              # boot blocks: not files
    try:
        vol = prodos.mount(p, replace=True, readonly=True)
    except Exception:
        with open(p, 'rb') as fh:
            return 'raw:' + hashlib.sha1(fh.read()).hexdigest()
    try:
        def walk(path):
            for e in sorted(prodos.scandir(path), key=lambda e: e.name):
                sub = f'{path}/{e.name}'
                if e.is_dir():
                    h.update(f'D {sub}\n'.encode())
                    walk(sub)
                else:
                    h.update(f'F {sub} {e.type:02X} '
                             f'{e.aux_type:04X}\n'.encode())
                    h.update(prodos.read(sub))
        walk(f'/mnt/{vol}')
        return 'po:' + h.hexdigest()
    except Exception:
        with open(p, 'rb') as fh:
            return 'raw:' + hashlib.sha1(fh.read()).hexdigest()
    finally:
        prodos.unmount(vol)


def artifacts():
    out = {}
    for name in sorted(os.listdir(BUILD)):
        if name.endswith(('_Output.txt', '.log')):
            continue
        p = os.path.join(BUILD, name)
        if not os.path.isfile(p):
            continue
        if name.endswith('.po'):
            out[name] = _po_fingerprint(p)
        else:
            out[name] = __import__('hashlib').sha1(
                open(p, 'rb').read()).hexdigest()
    return out


def build():
    subprocess.run(['make', 'clean'], cwd=ROOT, capture_output=True)
    for t in TARGETS:
        r = subprocess.run(['make', t], cwd=ROOT, capture_output=True)
        if r.returncode != 0:
            print(f'[check-bytes] build failed: {t}', file=sys.stderr)
            print(r.stderr.decode()[-2000:], file=sys.stderr)
            sys.exit(2)
    return artifacts()


def git(*a):
    return subprocess.run(['git', *a], cwd=ROOT, capture_output=True,
                          text=True)


def main(argv):
    ref = None
    for a in argv:
        if a.startswith('REF='):
            ref = a[4:]
    if not ref:
        print('usage: make check-bytes REF=<commit>', file=sys.stderr)
        return 2

    branch = git('rev-parse', '--abbrev-ref', 'HEAD').stdout.strip()
    stashed = git('stash', 'push', '--', 'src', 'inc',
                  'scripts').returncode == 0
    try:
        if git('checkout', '-q', ref).returncode != 0:
            print(f'[check-bytes] cannot check out {ref}', file=sys.stderr)
            return 2
        print(f'[check-bytes] building at {ref}')
        before = build()
    finally:
        git('checkout', '-q', branch)
        if stashed:
            git('stash', 'pop')
    print('[check-bytes] building the working tree')
    after = build()

    names = sorted(set(before) | set(after))
    diffs = [n for n in names if before.get(n) != after.get(n)]
    print(f'[check-bytes] {len(names)} artifact(s) compared')
    if not diffs:
        print(f'[check-bytes] PASS: every artifact is byte-identical to {ref} '
              f'-- the change emitted no different code')
        return 0
    for n in diffs:
        print(f'    {n}: {before.get(n, "(absent)")} -> '
              f'{after.get(n, "(absent)")}', file=sys.stderr)
    print(f'[check-bytes] FAIL: {len(diffs)} artifact(s) differ',
          file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
