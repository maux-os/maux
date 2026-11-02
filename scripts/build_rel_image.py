#!/usr/bin/env python3
"""build_rel_image.py -- assemble the REL/LNK spike work disk (`make rel-image`).

Task #8a. Copies the vendored public-domain Merlin-8 2.59 volume, then uses
**a2til mirror** to push `src/relspike/` into `/SOURCE/RELSPIKE` on the image.

WHY MIRROR AND NOT write_file LOOPS: a2til ships a poll-sync that keeps a host
directory and a ProDOS directory in step -- transactional per pass, `--once`
for scripts -- which is the supported way to edit image-resident sources.
Driving the low-level API by hand instead means re-implementing it badly; see
HACKING.md's "knowing a house tool exists is not knowing what it does".

`--raw` is deliberate. a2til's text translation writes STANDARD ProDOS text
(low ASCII, $0D). Merlin's own sources are HIGH-BIT ASCII with $8D, so the
host files carry the cadius-style `NAME.S#040000` type/aux suffix and are
pre-encoded, and mirror moves them byte-exactly. See
learning:01M04J31Y8DQM8V8DSN4DK9HJH.

Needs vendor/VALIDATE.PO -- run `make vendor-merlin` first (vendor/ is
gitignored).
"""
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
A2TIL = os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til'))
SRC_IMG = os.path.join(ROOT, 'vendor', 'VALIDATE.PO')
OUT_IMG = os.path.join(ROOT, 'build', 'rel.po')
MIRROR_DIR = os.path.join(ROOT, 'src', 'relspike')
IMAGE_DIR = '/SOURCE'

sys.path.insert(0, A2TIL)
import a2til  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)


def names_file(paths):
    """Merlin linker names file: length-prefixed high-bit pathnames, each
    $00-terminated, the file ending with a second $00. Format confirmed
    against the shipped /MERLIN.8/PI/NAMES (learning:01M041MZER5YQJQYR7JP5N7F01).
    """
    out = bytearray()
    for p in paths:
        out.append(len(p))
        out += bytes((ord(c) | 0x80) for c in p)
        out.append(0x00)
    out.append(0x00)
    return bytes(out)


def main():
    if not os.path.exists(SRC_IMG):
        print(f'error: {SRC_IMG} not found -- run `make vendor-merlin` first',
              file=sys.stderr)
        return 2

    os.makedirs(os.path.join(ROOT, 'build'), exist_ok=True)
    shutil.copyfile(SRC_IMG, OUT_IMG)

    # The names file is derived (its contents are just the module paths), so
    # it is generated here rather than checked in, and lands in the mirror
    # directory so the same mirror pass carries it.
    nf = names_file([f'{IMAGE_DIR}/RTMAIN', f'{IMAGE_DIR}/RTLIB'])
    with open(os.path.join(MIRROR_DIR, 'RTNAMES#068000'), 'wb') as fh:
        fh.write(nf)

    # WHY NOT `a2til mirror` HERE, given it is the right workflow: mirroring
    # wants its own subdirectory (pointing it at a volume root drags every
    # file on the volume down to the host), and files inside a subdirectory
    # CREATED BY a2til are rejected by ProDOS with "4A MLI ERROR". Isolated
    # 2026-08-16 with identical bytes written three ways and loaded first from
    # a fresh boot each time:
    #     /SOURCE/PROBE            volume root            -> LOADED
    #     /SOURCE/SAVE/PROBE       directory that SHIPPED -> LOADED
    #     /SOURCE/RELSPIKE/PROBE   directory a2til made   -> 4A MLI ERROR
    # a2til's own `check` reports the volume clean, so this looks like a
    # subdirectory-creation bug rather than anything about the files. Until
    # it is fixed, this gate writes to the volume ROOT, which works. Restore
    # the mirror path (it is in git history) once mkdir is sound.
    vol = a2til.open_image(OUT_IMG)
    for host in sorted(os.listdir(MIRROR_DIR)):
        if host.startswith('.'):
            continue
        name, _, suffix = host.partition('#')
        ftype = int(suffix[:2], 16) if suffix else 0x06
        aux = int(suffix[2:], 16) if len(suffix) > 2 else 0
        with open(os.path.join(MIRROR_DIR, host), 'rb') as fh:
            data = fh.read()
        vol.write_file(f'{IMAGE_DIR}/{name}', data, file_type=ftype,
                       aux_type=aux, overwrite=True)
        print(f'push {host} -> {name} ({len(data)} bytes)')
    vol.flush()

    vol = a2til.open_image(OUT_IMG)
    listing = sorted(e.name for e in vol.scandir(IMAGE_DIR))
    listing = [n for n in listing if n.startswith('RT')]
    print(f'[build-rel] {OUT_IMG} ready; {IMAGE_DIR} holds {listing}')
    for want in ('RTLIB.S', 'RTMAIN.S', 'RTNAMES'):
        if want not in listing:
            print(f'[build-rel] ERROR: {want} missing from the image',
                  file=sys.stderr)
            return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
