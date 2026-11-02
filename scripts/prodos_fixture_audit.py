#!/usr/bin/env python3
"""Audit (and optionally repair) ProDOS structures in a built image.

    python3 scripts/prodos_fixture_audit.py build/*.po        # report
    python3 scripts/prodos_fixture_audit.py --fix build/x.po  # repair

WHY THIS EXISTS.  docs/FINISH.md item D -- the hang that kept
`check-e2e-fs`'s emulator half parked -- was a MALFORMED FIXTURE, not a
maux defect.  The field is one byte:

**A subdirectory header's `parent_entry_number` (entry offset +$25) is
1-BASED WITHIN ITS PARENT'S BLOCK, AND THE DIRECTORY HEADER OCCUPIES
ENTRY 1.**  So the first real file in a directory is entry 2, never 1.

a2til stores the 0-based slot there instead, and reads it back with the
same convention -- self-consistent, so a2til itself never notices.  Real
ProDOS walking up from a subdirectory therefore lands ONE ENTRY EARLY.
Usually that is another file's entry: wrong, but survivable.  When the
subdirectory is the FIRST entry in its parent, one early is the
DIRECTORY HEADER -- whose +$25/+$26 bytes are `parent_entry_number,
parent_entry_length` (e.g. `07 27`).  Read as a block number that is
$2707 = 9991, far outside the volume; the write fails, ProDOS re-reads
block 0, parses the BOOT BLOCK as a directory, and retries forever.

That is the whole of item D: `rm` of a file two directory levels deep
never returned, while root and one level were fine.

`--fix` rewrites the field in place from the parent block's own slot
order, which is what made the diagnosis testable without touching the
a2til working tree.  It is a stopgap: **the real fix belongs in a2til**
(`prodos.py`, `header.parent_entry = slot` at two sites, plus the read
back at `_grow_dir`, which uses the same convention).
"""
import os
import struct
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ENTRY_LEN = 39
ST_SUBDIR = 0x0D
ST_SUBDIR_HEADER = 0x0E


def subdirs(img):
    """(path, key block) for every subdirectory, depth first."""
    vol = prodos.Volume(img, readonly=True)
    found = []
    try:
        def walk(path):
            for ent in vol.scandir(path):
                if ent.is_dir():
                    child = path.rstrip('/') + '/' + ent.name
                    found.append((child, ent.stat().key_pointer))
                    walk(child)
        walk('/')
    finally:
        vol.close()
    return found


def slot_of(block_bytes, name):
    """0-based slot holding `name` as a subdirectory entry."""
    for slot in range(13):
        off = 4 + slot * ENTRY_LEN
        ent = block_bytes[off:off + ENTRY_LEN]
        if not ent or ent[0] == 0:
            continue
        got = bytes(ent[1:1 + (ent[0] & 0x0F)]).decode('ascii', 'replace')
        if got == name and (ent[0] >> 4) == ST_SUBDIR:
            return slot
    return None


def audit(img, fix=False):
    problems = []
    for path, key in subdirs(img):
        with open(img, 'r+b' if fix else 'rb') as f:
            f.seek(key * 512)
            hdr = bytearray(f.read(512))
            parent = struct.unpack('<H', hdr[4 + 0x23:4 + 0x25])[0]
            got = hdr[4 + 0x25]
            f.seek(parent * 512)
            slot = slot_of(f.read(512), path.rsplit('/', 1)[-1])
            if slot is None:
                problems.append((path, got, None))
                continue
            want = slot + 1                      # 1-based, header is entry 1
            if got != want:
                problems.append((path, got, want))
                if fix:
                    hdr[4 + 0x25] = want
                    f.seek(key * 512)
                    f.write(bytes(hdr))
    return problems


def main():
    fix = '--fix' in sys.argv
    images = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not images:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    bad = 0
    for img in images:
        if not os.path.exists(img):
            continue
        problems = audit(img, fix)
        verb = 'repaired' if fix else 'wrong'
        if problems:
            bad += len(problems)
            print(f'[prodos-audit] {img}: {len(problems)} {verb}')
            for path, got, want in problems:
                w = '(entry not found in parent)' if want is None else \
                    f'parent_entry_number {got} -> {want}'
                print(f'   {path:32} {w}')
        else:
            print(f'[prodos-audit] {img}: clean')
    if bad and not fix:
        print(f'[prodos-audit] {bad} subdirectory header(s) carry a '
              f'parent_entry_number ProDOS cannot follow. See this '
              f'file\'s header; the fix belongs in a2til.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
