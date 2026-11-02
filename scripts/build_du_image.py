#!/usr/bin/env python3
"""Build the ProDOS-hosted `du` acceptance-gate image (`make check-du`).

Companion to src/test/dutest.s / src/test/dutestb.s / scripts/check_du.py
-- same shape as scripts/build_find_image.py (a real userland binary
spawned from disk with a fd redirected to a ProDOS file, byte-exact
comparison), extended to SIX spawns (plain walk / -s / -a / single-file
argument / nonexistent-path-then-valid-path / the pathname fence).

House rule (HACKING.md): disk images via a2til only.

BLOCK COUNTS ARE HAND-DERIVED from the staged EOF values below using
ProDOS's own seedling/sapling allocation rule (TRM ch. 5): a file whose
EOF fits in one 512-byte block (<=512) is a SEEDLING, blocks_used=1; a
larger file (up to 128KB) is a SAPLING, blocks_used = ceil(EOF/512) data
blocks PLUS one index block. compute_expected() below performs exactly
that arithmetic from FILES's own EOF column -- see HAND_BLOCKS. It is
NOT derived by running du.bin (the task brief's own constraint).

That hand math is then CROSS-CHECKED (not superseded) against the real
blocks_used the a2til allocator gave each staged file/directory when the
image was actually built -- assert_blocks_match() raises loudly on any
mismatch, so a wrong hand-derivation cannot silently pass. This is the
same "trust but verify against the real bytes" discipline
build_ls_image.py's own compute_expected() documents for exactly this
field (a sapling's blocks_used is not a simple EOF/512 rounding), applied
in the opposite direction: build_ls_image.py takes the real bytes AS the
expectation; here the hand math IS the expectation, and the real bytes
are the check on it.

Two staged trees:
  DUDIR/              -- the main tree, >=2 levels deep, one sapling
                          boundary-crossing file per level (B.BIN,
                          D.TXT), used by runs 1-4.
    A.TXT   (100B, seedling, 1 block)
    B.BIN   (600B, sapling,  3 blocks -- the trap: EOF/512 rounds to 2)
    SUB1/                  (own storage: 1 block)
      C.TXT (50B,  seedling, 1 block)
      D.TXT (1000B, sapling, 3 blocks -- same trap)
      SUB2/               (own storage: 1 block)
        E.TXT (30B, seedling, 1 block)
  DUDIR2/             -- a second, tiny tree, used by run 5 alongside a
                          deliberately nonexistent path.
    F.TXT   (5B, seedling, 1 block)

ROLLUP (du semantics: a directory's own total includes its own storage
block AND every descendant, so du -s DIR counts DIR's own key block
too):
  SUB2  total = self(1) + E.TXT(1)                              = 2
  SUB1  total = self(1) + C.TXT(1) + D.TXT(3) + SUB2(2)          = 7
  DUDIR total = self(1) + A.TXT(1) + B.BIN(3) + SUB1(7)          = 12
  DUDIR2 total = self(1) + F.TXT(1)                              = 2
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
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXDUTEST.SYSTEM')
DU_BIN = os.path.join(ROOT, 'build', 'du.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'du.po')

DUDIR = f'/mnt/{CARRIER_VOL}/DUDIR'
DUDIR2 = f'/mnt/{CARRIER_VOL}/DUDIR2'
DUDIR3 = f'/mnt/{CARRIER_VOL}/LONGDIR'

# -- Tree 3: the pathname fence (run 6), the same shape as
# build_find_image.py's own LONGDIR (see that file's comment for the
# on-disk reachability argument: prefix + partial pathname reach 128
# chars, so a legal tree CAN hold a child no full MLI pathname can
# open). du must refuse each such child LOUDLY ("pathname too long",
# exit 1), leave its blocks OUT of every printed total, and keep
# walking -- before 2026-08-23 it overran FULLPATH ds 65 instead.
LONG_L1 = 'LEVELAAAAAAAAA'
LONG_L2 = 'LEVELBBBBBBBBB'
LONG_L3 = 'LEVELCCCCCCCCC'
LONG_BADF = 'LONGTAIL.TXT'
LONG_BADD = 'DIRTOOLONGXYZ'
LONG_OKF = 'Z'
LONG_L3P = f'{DUDIR3}/{LONG_L1}/{LONG_L2}/{LONG_L3}'

CR = bytes([0x8D])

# name -> (EOF bytes, parent dir path)
FILES = {
    'A.TXT': (100, DUDIR),
    'B.BIN': (600, DUDIR),
    'C.TXT': (50, f'{DUDIR}/SUB1'),
    'D.TXT': (1000, f'{DUDIR}/SUB1'),
    'E.TXT': (30, f'{DUDIR}/SUB1/SUB2'),
    'F.TXT': (5, DUDIR2),
    LONG_BADF: (20, LONG_L3P),
    LONG_OKF: (20, LONG_L3P),
}

# subdir name -> parent dir path (its OWN storage cost is read back the
# same way a file's is -- an entry in its PARENT's listing).
DIRS = {
    'DUDIR': f'/mnt/{CARRIER_VOL}',
    'DUDIR2': f'/mnt/{CARRIER_VOL}',
    'SUB1': DUDIR,
    'SUB2': f'{DUDIR}/SUB1',
    'LONGDIR': f'/mnt/{CARRIER_VOL}',
    LONG_L1: DUDIR3,
    LONG_L2: f'{DUDIR3}/{LONG_L1}',
    LONG_L3: f'{DUDIR3}/{LONG_L1}/{LONG_L2}',
    LONG_BADD: LONG_L3P,
}


def hitext(s):
    return bytes(ord(c) | 0x80 for c in s)


def hand_blocks(eof):
    """Seedling/sapling block math (TRM ch. 5) -- see module header."""
    if eof <= 512:
        return 1
    data_blocks = -(-eof // 512)  # ceil
    return data_blocks + 1        # + one index block


def build():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXDUTEST.SYSTEM'),
        (DU_BIN, 'du userland binary'),
    ]:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2

    shutil.copyfile(CARRIER_IMG, OUT_IMG)
    prodos.mount(OUT_IMG)
    root = f'/mnt/{CARRIER_VOL}'
    removed, kept = [], []

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
    with open(DU_BIN, 'rb') as f:
        dubin = f.read()

    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    try:                      # docs/VROOT.md: programs live in BIN
        prodos.mkdir(f'{root}/BIN')
    except FileExistsError:
        pass
    prodos.write(f'{root}/BIN/DU', dubin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)

    def filler(n):
        return bytes((i % 251) + 1 for i in range(n))

    prodos.mkdir(DUDIR)
    prodos.write(f'{DUDIR}/A.TXT', filler(FILES['A.TXT'][0]),
                 file_type=0x04, overwrite=True)
    prodos.write(f'{DUDIR}/B.BIN', filler(FILES['B.BIN'][0]),
                 file_type=0x06, overwrite=True)
    prodos.mkdir(f'{DUDIR}/SUB1')
    prodos.write(f'{DUDIR}/SUB1/C.TXT', filler(FILES['C.TXT'][0]),
                 file_type=0x04, overwrite=True)
    prodos.write(f'{DUDIR}/SUB1/D.TXT', filler(FILES['D.TXT'][0]),
                 file_type=0x04, overwrite=True)
    prodos.mkdir(f'{DUDIR}/SUB1/SUB2')
    prodos.write(f'{DUDIR}/SUB1/SUB2/E.TXT', filler(FILES['E.TXT'][0]),
                 file_type=0x04, overwrite=True)

    prodos.mkdir(DUDIR2)
    prodos.write(f'{DUDIR2}/F.TXT', filler(FILES['F.TXT'][0]),
                 file_type=0x04, overwrite=True)

    # -- Tree 3 (the pathname fence -- see the LONG_* comment). The
    # length arithmetic is asserted rather than trusted.
    assert len(LONG_L3P) == 62, f'{len(LONG_L3P)}: {LONG_L3P}'
    assert len(f'{LONG_L3P}/{LONG_BADF}') > 64
    assert len(f'{LONG_L3P}/{LONG_BADD}') > 64
    assert len(f'{LONG_L3P}/{LONG_OKF}') == 64
    prodos.mkdir(DUDIR3)
    prodos.mkdir(f'{DUDIR3}/{LONG_L1}')
    prodos.mkdir(f'{DUDIR3}/{LONG_L1}/{LONG_L2}')
    prodos.mkdir(LONG_L3P)
    prodos.write(f'{LONG_L3P}/{LONG_BADF}', filler(FILES[LONG_BADF][0]),
                 file_type=0x04, overwrite=True)
    prodos.mkdir(f'{LONG_L3P}/{LONG_BADD}')
    prodos.write(f'{LONG_L3P}/{LONG_OKF}', filler(FILES[LONG_OKF][0]),
                 file_type=0x04, overwrite=True)

    prodos.unmount(CARRIER_VOL)

    print(f'[build-du] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-du] kept={kept} removed={removed}')
    print(f'[build-du] {OUT_IMG} ready ({os.path.getsize(OUT_IMG)} bytes)')
    return 0


def _real_blocks_used(image_path, name, parent_path):
    """Read back the REAL blocks_used a2til's allocator gave `name`
    (a file or subdirectory) as seen in `parent_path`'s own listing --
    same technique build_ls_image.py's own compute_expected() uses.
    Caller must already hold the mount from compute_expected()."""
    vol = prodos._session.get(prodos._foldname(CARRIER_VOL))
    root = f'/mnt/{CARRIER_VOL}'
    rel = parent_path[len(root):] or '/'
    dir_blockno = vol._resolve_dir(rel)
    entry = vol._find_entry(dir_blockno, name.upper())
    assert entry is not None, f'{name} missing from {parent_path}'
    return entry.blocks_used


def compute_expected(image_path=OUT_IMG):
    """Read back the FINAL, already-built image (read-only). Hand
    math (hand_blocks(), on the EOF values staged above) is the
    SOURCE of every expected byte string; the real on-disk
    blocks_used is only a cross-check (assert_blocks_match) -- see
    module docstring."""
    prodos.mount(image_path, readonly=True)

    hand = {}
    for name, (eof, _parent) in FILES.items():
        hand[name] = hand_blocks(eof)
    # directories always cost exactly 1 block here (few entries, well
    # under one block's ~13-entry capacity) -- hand-asserted, then
    # cross-checked below same as the files.
    for name in DIRS:
        hand[name] = 1

    mismatches = []
    for name, (eof, parent) in FILES.items():
        real = _real_blocks_used(image_path, name, parent)
        if real != hand[name]:
            mismatches.append(f'{name}: hand={hand[name]} real={real}')
    for name, parent in DIRS.items():
        real = _real_blocks_used(image_path, name, parent)
        if real != hand[name]:
            mismatches.append(f'{name}: hand={hand[name]} real={real}')
    if mismatches:
        prodos.unmount(CARRIER_VOL)
        raise AssertionError('hand-derived blocks_used disagrees with '
                              'the real allocator: ' + '; '.join(mismatches))

    prodos.unmount(CARRIER_VOL)

    sub2 = hand['SUB2'] + hand['E.TXT']
    sub1 = hand['SUB1'] + hand['C.TXT'] + hand['D.TXT'] + sub2
    dudir = hand['DUDIR'] + hand['A.TXT'] + hand['B.BIN'] + sub1
    dudir2 = hand['DUDIR2'] + hand['F.TXT']

    def line(blocks, path):
        return f'{blocks}\t{path}'

    # -- run 1: plain walk, deepest first, no -a --
    run1_lines = [
        line(sub2, f'{DUDIR}/SUB1/SUB2'),
        line(sub1, f'{DUDIR}/SUB1'),
        line(dudir, DUDIR),
    ]
    expected_run1 = b''.join(hitext(l) + CR for l in run1_lines)

    # -- run 2: -s, summary only --
    expected_run2 = hitext(line(dudir, DUDIR)) + CR

    # -- run 3: -a, every file too, same walk order as run 1's rollups
    # plus a line per file as it is visited --
    run3_lines = [
        line(hand['A.TXT'], f'{DUDIR}/A.TXT'),
        line(hand['B.BIN'], f'{DUDIR}/B.BIN'),
        line(hand['C.TXT'], f'{DUDIR}/SUB1/C.TXT'),
        line(hand['D.TXT'], f'{DUDIR}/SUB1/D.TXT'),
        line(hand['E.TXT'], f'{DUDIR}/SUB1/SUB2/E.TXT'),
        line(sub2, f'{DUDIR}/SUB1/SUB2'),
        line(sub1, f'{DUDIR}/SUB1'),
        line(dudir, DUDIR),
    ]
    expected_run3 = b''.join(hitext(l) + CR for l in run3_lines)

    # -- run 4: single file argument (the sapling -- proves blocks_used,
    # not EOF/512, is what prints) --
    expected_run4 = hitext(line(hand['B.BIN'], f'{DUDIR}/B.BIN')) + CR

    # -- run 5: -s NONEXIST DUDIR2 -- bad path first (stderr, continue),
    # then the valid one (stdout), exit 1 --
    nonexist = f'/mnt/{CARRIER_VOL}/NONEXIST'
    expected_run5 = hitext(line(dudir2, DUDIR2)) + CR
    expected_run5_err = hitext(f'du: {nonexist}: cannot access') + CR

    # -- run 6: the pathname fence. LONGTAIL.TXT and DIRTOOLONGXYZ
    # sit past 64 chars: each is one stderr line (on-disk entry
    # order), each is ABSENT from every total, and Z -- at exactly
    # 64 -- is counted. Exit 1.
    l3tot = hand[LONG_L3] + hand[LONG_OKF]
    l2tot = hand[LONG_L2] + l3tot
    l1tot = hand[LONG_L1] + l2tot
    longdir = hand['LONGDIR'] + l1tot
    run6_lines = [
        line(l3tot, LONG_L3P),
        line(l2tot, f'{DUDIR3}/{LONG_L1}/{LONG_L2}'),
        line(l1tot, f'{DUDIR3}/{LONG_L1}'),
        line(longdir, DUDIR3),
    ]
    expected_run6 = b''.join(hitext(l) + CR for l in run6_lines)
    expected_run6_err = (
        hitext(f'du: {LONG_L3P}/{LONG_BADF}: pathname too long') + CR +
        hitext(f'du: {LONG_L3P}/{LONG_BADD}: pathname too long') + CR)

    # -- run 7: DUDIR with a TRAILING SLASH: children join with ONE
    # "/" (GNU du's shape; BSD du doubles it, which is the bug), the
    # total line echoes the operand as typed. --
    run7_lines = [
        line(sub2, f'{DUDIR}/SUB1/SUB2'),
        line(sub1, f'{DUDIR}/SUB1'),
        line(dudir, DUDIR + '/'),
    ]
    expected_run7 = b''.join(hitext(l) + CR for l in run7_lines)

    # -- run 8: no operand, cwd = DUDIR: names RELATIVE to it and
    # "." for the total (POSIX/V7/GNU/BSD all print this form). --
    run8_lines = [
        line(sub2, './SUB1/SUB2'),
        line(sub1, './SUB1'),
        line(dudir, '.'),
    ]
    expected_run8 = b''.join(hitext(l) + CR for l in run8_lines)

    return dict(
        run7=expected_run7, run7_status=0,
        run8=expected_run8, run8_status=0,
        run1=expected_run1, run1_status=0,
        run2=expected_run2, run2_status=0,
        run3=expected_run3, run3_status=0,
        run4=expected_run4, run4_status=0,
        run5=expected_run5, run5_err=expected_run5_err, run5_status=1,
        run6=expected_run6, run6_err=expected_run6_err, run6_status=1,
        hand=hand, sub1=sub1, sub2=sub2, dudir=dudir, dudir2=dudir2,
    )


def main():
    rc = build()
    if rc:
        return rc
    expected = compute_expected(OUT_IMG)
    for key in ('run1', 'run2', 'run3', 'run4', 'run5', 'run6', 'run7',
                'run8'):
        print(f'[build-du] {key} expected: {expected[key]!r}')
    print(f'[build-du] run5 expected stderr: {expected["run5_err"]!r} '
          f'status={expected["run5_status"]}')
    print(f'[build-du] run6 expected stderr: {expected["run6_err"]!r} '
          f'status={expected["run6_status"]}')
    print(f'[build-du] hand blocks_used: {expected["hand"]}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
