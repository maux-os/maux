#!/usr/bin/env python3
"""vendor_merlin.py -- extract the public-domain Merlin-8 v2.59 sources from
Willi Kusche's VALIDATE.PO into vendor/merlin/, following the same
acquisition/extraction pattern as vendor_prodos.py (docs/TOOLCHAIN.md's
"vendor, never commit" rule; vendor/ is gitignored).

LICENSING (verified 2026-08-16, load-bearing -- task #8 previously carried
"Roger Wagner's; fine personally, flag before distribution", which is now
superseded): Merlin is PUBLIC DOMAIN. Glen Bredon died in 2000 and on
2000-08-24, what would have been his 68th birthday, his widow released all of
his Apple II software AND source code as public domain. Wikipedia's
"Merlin (assembler)" article cites a "Public.Domain.notice.txt" hosted on
apple2.org.za as the primary source for that release. So maux may modify and
redistribute Merlin sources; the old distribution caveat is dropped.

ACQUISITION: VALIDATE.PO is an 800K ProDOS image assembled by Willi Kusche
(A2@wilserv.com) specifically so that anyone can confirm an executable built
from the published sources matches the published binary. Its own READMEFIRST
states the sources were extracted from the upstream "MER8.Src.259.SHK"
archive at ftp://public.asimov.net/pub/apple_II/images/programming/assembler/
merlin/ . The asimov FTP host did not resolve over HTTP(S) from here on
2026-08-16; the apple2.org.za mirror did, and is the same mirror
vendor_prodos.py already relies on:

  https://mirrors.apple2.org.za/ftp.apple.asimov.net/images/programming/
  assembler/merlin/VALIDATE.PO
  819200 bytes, sha256
  8141b6082900c9b4965dab9d1068716c019677cec84b792d0deadb5dafc43245

REPRODUCIBILITY NOTE THAT MATTERS TO TASK #7: Kusche's READMEFIRST records
that "SAVE/MERLIN" generates two pairs of five RANDOM bytes between some of
the four object modules it binds into MERLIN.SYSTEM. He appended five bytes
each to the ends of MACASS.S and MACEXEC.S so the bind stops emitting random
padding. A byte-diff dual-assembly gate that does not account for this will
fail for reasons that have nothing to do with dialect divergence.

Usage: python3 scripts/vendor_merlin.py
Env overrides:
  MERLIN_SRC_IMG -- source image (default vendor/VALIDATE.PO)
  MERLIN_OUT_DIR -- extraction directory (default vendor/merlin)
"""
import hashlib
import json
import os
import shutil
import sys
import tempfile
import urllib.request

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import a2til  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCK_PATH = os.path.join(ROOT, 'dependencies.lock.json')
with open(LOCK_PATH, encoding='ascii') as _lock_file:
    _artifact = json.load(_lock_file)['artifacts']['merlin']
_default_src = os.path.join(ROOT, _artifact['path'])
SRC_IMG = os.environ.get('MERLIN_SRC_IMG', _default_src)
OUT_DIR = os.environ.get('MERLIN_OUT_DIR',
                         os.path.join(ROOT, 'vendor', 'merlin'))

# The four primary sources STEPBYSTEP assembles, in its order, plus the
# instructions themselves. Everything else on the volume is extracted too;
# this list exists so the build order is recorded in the tree rather than
# only inside a text file on a disk image.
PRIMARY_SOURCES = ['INTERPRETER.S', 'MACED.S', 'MACEXEC.S', 'MACASS.S']


def fetch_locked_image(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    print(f'[vendor-merlin] fetching {_artifact["url"]}')
    with urllib.request.urlopen(_artifact['url']) as response:
        data = response.read()
    digest = hashlib.sha256(data).hexdigest()
    if len(data) != _artifact['bytes'] or digest != _artifact['sha256']:
        raise ValueError('downloaded VALIDATE.PO does not match '
                         'dependencies.lock.json')
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=os.path.dirname(path),
                                         prefix='.merlin.', delete=False) as output:
            temporary = output.name
            output.write(data)
        os.replace(temporary, path)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)


def tree_manifest(root):
    manifest = {}
    for base, _, files in os.walk(root):
        for name in files:
            path = os.path.join(base, name)
            rel = os.path.relpath(path, root)
            with open(path, 'rb') as source:
                manifest[rel] = hashlib.sha256(source.read()).hexdigest()
    return manifest


def main():
    if not os.path.exists(SRC_IMG):
        if os.path.abspath(SRC_IMG) != os.path.abspath(_default_src):
            print(f'error: operator-specified MERLIN_SRC_IMG does not exist: '
                  f'{SRC_IMG}', file=sys.stderr)
            return 2
        try:
            fetch_locked_image(SRC_IMG)
        except (OSError, ValueError) as exc:
            print(f'error: cannot fetch locked VALIDATE.PO: {exc}',
                  file=sys.stderr)
            return 2

    data = open(SRC_IMG, 'rb').read()
    got = hashlib.sha256(data).hexdigest()
    if os.path.abspath(SRC_IMG) == os.path.abspath(_default_src):
        if len(data) != _artifact['bytes'] or got != _artifact['sha256']:
            print(f'error: refusing mismatched locked Merlin cache: {SRC_IMG} '
                  f'is {len(data)} bytes, sha256 {got}', file=sys.stderr)
            return 2

    vol = a2til.open_image(SRC_IMG)
    out_parent = os.path.dirname(os.path.abspath(OUT_DIR))
    os.makedirs(out_parent, exist_ok=True)
    staging = tempfile.mkdtemp(prefix='.merlin-extract.', dir=out_parent)
    count = 0

    def extract(path, rel):
        nonlocal count
        for entry in vol.scandir(path):
            spath = f'{path}/{entry.name}'
            srel = os.path.join(rel, entry.name)
            if entry.is_dir():
                os.makedirs(os.path.join(staging, srel), exist_ok=True)
                extract(spath, srel)
                continue
            blob = vol.read_file(spath)
            with open(os.path.join(staging, srel), 'wb') as fh:
                fh.write(blob)
            count += 1

    try:
        extract(f'/{vol.name}', '')

        missing = [s for s in PRIMARY_SOURCES
                   if not os.path.exists(os.path.join(staging, s))]
        if missing:
            print(f'[vendor-merlin] expected primary sources absent: {missing}',
                  file=sys.stderr)
            return 1

        if os.path.exists(OUT_DIR):
            if tree_manifest(OUT_DIR) != tree_manifest(staging):
                print(f'error: refusing to alter non-matching {OUT_DIR}',
                      file=sys.stderr)
                return 2
        else:
            os.rename(staging, OUT_DIR)
            staging = None
    finally:
        if staging is not None:
            shutil.rmtree(staging)

    print(f'[vendor-merlin] extracted {count} files from /{vol.name} '
          f'-> {OUT_DIR}')
    print(f'[vendor-merlin] STEPBYSTEP assembly order: '
          f'{" -> ".join(PRIMARY_SOURCES)}')
    print('[vendor-merlin] all four primary sources present')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
