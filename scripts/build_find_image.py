#!/usr/bin/env python3
"""Build the ProDOS-hosted `find` acceptance-gate image (`make
check-find`). Companion to src/test/findtest.s / findtestb.s /
scripts/check_find.py -- same shape as scripts/build_ls_image.py (a
real userland binary spawned from disk with a fd redirected to a
ProDOS file, byte-exact comparison against a HAND-DERIVED expectation),
extended to SEVEN spawns (plain walk / -name / -type d / -type f /
-exec / depth-limit overflow / the pathname fence) instead of ls's
four.

House rule (HACKING.md): disk images via a2til only. Case-flag names go
through a2til's public write() (it round-trips GS/OS case flags off the
mixed-case Python string, same as build_ls_image.py already
established), so no manual case-flag patching is needed here.

DERIVING EXPECTATIONS "BY HAND" (task brief: never by running find and
recording its output): compute_expected() below does NOT run find.bin
at all. It re-implements find's OWN documented algorithm -- visit the
root, then walk each directory's entries in their REAL ON-DISK slot
order (a2til's own `prodos.scandir()`, which walks storage_type!=0
slots in physical order, skipping deleted gaps -- textually the exact
same algorithm src/liba/readdir.s implements, confirmed by reading
a2til's own `_iter_dir` docstring/source, not assumed) -- as a plain
recursive Python DFS mirroring find.s's iterative depth-stack WALK
routine's documented visiting order (root first, then each entry in
scandir order, recursing into a subdirectory immediately after it is
itself tested, before continuing to the parent's remaining siblings).
This is "deriving from the real filesystem structure", the same
technique build_ls_image.py's own compute_expected() already uses for
blocks_used/dates -- not "running the subject and recording its
output".
"""
import fnmatch
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
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXFINDTEST.SYSTEM')
FIND_BIN = os.path.join(ROOT, 'build', 'find.bin')
CAT_BIN = os.path.join(ROOT, 'build', 'cat.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'find.po')

ROOT1 = f'/mnt/{CARRIER_VOL}/FINDDIR'   # main tree -- runs 1-5
ROOT2 = f'/mnt/{CARRIER_VOL}/DEEPDIR'   # single-chain tree -- run 6 (depth)
ROOT3 = f'/mnt/{CARRIER_VOL}/LONGDIR'   # long-path tree -- run 7

# -- Tree 3: the pathname fence (run 7). ProDOS's 64-char limit is
# an MLI-CALL limit, not an on-disk one (prefix + partial pathname
# reach 128 chars, TRM ch. 2), so a legal tree CAN hold a child no
# full pathname can open. find must refuse that child LOUDLY
# ("pathname too long", exit 1) and keep walking -- before
# 2026-08-23 it overran FULLPATH ds 65 into MLIPATH instead
# (docs/PLAN.md "known bugs": the walk concatenates PATHLEN + '/'
# + a 15-char name with unchecked X).
#   LONGDIR/LEVELAAAAAAAAA/LEVELBBBBBBBBB/LEVELCCCCCCCCC  (62)
#     LONGTAIL.TXT   (created 1st: 62+1+12 = 75 > 64 -> refused)
#     DIRTOOLONGXYZ  (dir, 2nd: 76 > 64 -> refused, NOT descended)
#     Z              (file, 3rd: 62+1+1 = 64 -> EXACTLY the limit,
#                     must still print -- the off-by-one witness)
LONG_L1 = 'LEVELAAAAAAAAA'
LONG_L2 = 'LEVELBBBBBBBBB'
LONG_L3 = 'LEVELCCCCCCCCC'
LONG_BADF = 'LONGTAIL.TXT'
LONG_BADD = 'DIRTOOLONGXYZ'
LONG_OKF = 'Z'

CR = bytes([0x8D])


def hitext(s):
    return bytes(ord(c) | 0x80 for c in s)


# -- Tree 1: FINDDIR. Created in THIS on-disk order deliberately, so
# the DFS order is not accidentally alphabetical (same
# "deliberately not alphabetical" discipline build_ls_image.py's own
# FILES table documents) -- a SUBDIRECTORY first (SUBDIR1), so pop/
# resume-to-parent is exercised even for the ROOT level, not just the
# nested one.
#   FINDDIR/
#     SUBDIR1/            (dir, created 1st)
#       NESTED.TXT        (created 1st in SUBDIR1)
#       SUBDIR2/          (dir, created 2nd -- 2nd nesting level)
#         DEEP.TXT
#       NOMATCH.DAT       (created 3rd in SUBDIR1, AFTER SUBDIR2 --
#                          proves resume-after-pop lands on the RIGHT
#                          next sibling, not just "whatever's left")
#     AFILE.TXT           (created 2nd in FINDDIR)
#     bFile.BIN           (created 3rd -- mixed case, GS/OS decode)
#     OTHER.DAT           (created 4th)
CONTENT = {
    'AFILE.TXT': 'AFILE-DATA\r',
    'NESTED.TXT': 'NESTED-DATA\r',
    'DEEP.TXT': 'DEEP-DATA\r',
}


def build():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXFINDTEST.SYSTEM'),
        (FIND_BIN, 'find userland binary'),
        (CAT_BIN, 'cat userland binary'),
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
    with open(FIND_BIN, 'rb') as f:
        findbin = f.read()
    with open(CAT_BIN, 'rb') as f:
        catbin = f.read()

    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    try:                      # docs/VROOT.md: programs live in BIN
        prodos.mkdir(f'{root}/BIN')
    except FileExistsError:
        pass
    prodos.write(f'{root}/BIN/FIND', findbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/CAT', catbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)

    def filler(name, n):
        data = CONTENT.get(name)
        if data is not None:
            return hitext(data)
        return bytes((i % 251) + 1 for i in range(n))

    # -- Tree 1 --
    prodos.mkdir(ROOT1)
    prodos.mkdir(f'{ROOT1}/SUBDIR1')
    prodos.write(f'{ROOT1}/SUBDIR1/NESTED.TXT', filler('NESTED.TXT', 20),
                 file_type=0x04, overwrite=True)
    prodos.mkdir(f'{ROOT1}/SUBDIR1/SUBDIR2')
    prodos.write(f'{ROOT1}/SUBDIR1/SUBDIR2/DEEP.TXT', filler('DEEP.TXT', 20),
                 file_type=0x04, overwrite=True)
    prodos.write(f'{ROOT1}/SUBDIR1/NOMATCH.DAT', filler('NOMATCH.DAT', 30),
                 file_type=0x06, overwrite=True)
    prodos.write(f'{ROOT1}/AFILE.TXT', filler('AFILE.TXT', 20),
                 file_type=0x04, overwrite=True)
    prodos.write(f'{ROOT1}/bFile.BIN', filler('bFile.BIN', 40),
                 file_type=0x06, overwrite=True)
    prodos.write(f'{ROOT1}/OTHER.DAT', filler('OTHER.DAT', 30),
                 file_type=0x06, overwrite=True)

    # -- Tree 2: DEEPDIR/A/B/C/D/E/F/G/H/I -- 9 nested single-letter
    # directories below DEEPDIR itself (DEEPDIR=depth 0; descending
    # into A is the 1st push, ..., H is the 8th push, landing AT
    # FIND_MAXDEP=8; the ATTEMPT to descend into I is the 9th push,
    # which find.s's WALK must refuse loudly).
    letters = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I']
    prodos.mkdir(ROOT2)
    cur = ROOT2
    for letter in letters:
        cur = f'{cur}/{letter}'
        prodos.mkdir(cur)

    # -- Tree 3 (see the LONG_* comment above). The length
    # arithmetic is asserted rather than trusted: the whole run
    # exists to sit exactly on the fence.
    l3 = f'{ROOT3}/{LONG_L1}/{LONG_L2}/{LONG_L3}'
    assert len(l3) == 62, f'L3 path is {len(l3)}, wanted 62: {l3}'
    assert len(f'{l3}/{LONG_BADF}') > 64
    assert len(f'{l3}/{LONG_BADD}') > 64
    assert len(f'{l3}/{LONG_OKF}') == 64
    prodos.mkdir(ROOT3)
    prodos.mkdir(f'{ROOT3}/{LONG_L1}')
    prodos.mkdir(f'{ROOT3}/{LONG_L1}/{LONG_L2}')
    prodos.mkdir(l3)
    prodos.write(f'{l3}/{LONG_BADF}', filler(LONG_BADF, 20),
                 file_type=0x04, overwrite=True)
    prodos.mkdir(f'{l3}/{LONG_BADD}')
    prodos.write(f'{l3}/{LONG_OKF}', filler(LONG_OKF, 20),
                 file_type=0x04, overwrite=True)

    prodos.unmount(CARRIER_VOL)

    print(f'[build-find] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-find] kept={kept} removed={removed}')
    print(f'[build-find] {OUT_IMG} ready ({os.path.getsize(OUT_IMG)} bytes)')
    return 0


# ---------------------------------------------------------------------
# compute_expected() -- see module docstring. Re-reads the FINAL,
# already-built image (read-only) and derives every expected byte
# string from a fresh Python re-implementation of find's own
# documented algorithm, run over the REAL on-disk entry order.
# ---------------------------------------------------------------------

def _isdir(entry):
    return entry.is_dir()


def compute_expected(image_path=OUT_IMG):
    prodos.mount(image_path, readonly=True)

    def basename(path):
        return path.rsplit('/', 1)[-1]

    def child_entries(path):
        """scandir(path), in REAL on-disk slot order -- see module
        docstring."""
        return list(prodos.scandir(path))

    def dfs(path, isdir, on_visit, errs):
        """on_visit(path, isdir) is called for THIS node first (find
        semantics: the starting point / every entry is tested before
        its own children, exactly find.s's WALK order), THEN --
        if isdir -- every child in scandir order, recursing
        immediately into subdirectories. A child whose full path
        exceeds 64 chars is find.s's BUILDCHILD refusal: one stderr
        line, no visit, no descent, walk continues (the rule under
        test in run 7 -- and derived HERE from the same length
        arithmetic the TRM states, not from running find.bin)."""
        on_visit(path, isdir)
        if not isdir:
            return
        for child in child_entries(path):
            cpath = f'{path}/{child.name}'
            if len(cpath) > 64:
                errs.append(f'find: {cpath}: pathname too long')
                continue
            dfs(cpath, _isdir(child), on_visit, errs)

    def run(root_path, name_pat=None, type_filt=None, action='print'):
        lines = []
        errs = []
        root_entry_isdir = True  # ROOT1/ROOT2/ROOT3 are directories

        def on_visit(path, isdir):
            base = basename(path)
            if type_filt == 'd' and not isdir:
                return
            if type_filt == 'f' and isdir:
                return
            if name_pat is not None:
                if not fnmatch.fnmatch(base.upper(), name_pat.upper()):
                    return
            if action == 'print':
                lines.append(path)
            elif action == 'cat':
                lines.append(CONTENT[base])

        dfs(root_path, root_entry_isdir, on_visit, errs)
        return lines, errs

    run1_paths, _ = run(ROOT1)
    run2_paths, _ = run(ROOT1, name_pat='[AND]*.TXT')
    run3_paths, _ = run(ROOT1, type_filt='d')
    run4_paths, _ = run(ROOT1, type_filt='f')
    run5_cat, _ = run(ROOT1, name_pat='[AND]*.TXT', action='cat')

    # -- run 7: the pathname fence. Two refused children (a file
    # and a directory -- the directory also proves no-descent),
    # one child at EXACTLY 64 that must still print, exit 1.
    run7_paths, run7_errs = run(ROOT3)
    assert len(run7_errs) == 2, run7_errs
    assert run7_paths[-1].endswith(f'/{LONG_OKF}'), run7_paths

    # -- run 6: depth overflow. Every node down to and including "I"
    # is VISITED (and printed -- action happens before the descend
    # check in find.s's WALK), but descending INTO "I" is refused.
    letters = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I']
    run6_paths = [ROOT2]
    cur = ROOT2
    for letter in letters:
        cur = f'{cur}/{letter}'
        run6_paths.append(cur)

    prodos.unmount(CARRIER_VOL)

    expected_run1 = b''.join(hitext(p) + CR for p in run1_paths)
    expected_run2 = b''.join(hitext(p) + CR for p in run2_paths)
    expected_run3 = b''.join(hitext(p) + CR for p in run3_paths)
    expected_run4 = b''.join(hitext(p) + CR for p in run4_paths)
    expected_run5 = b''.join(hitext(c) for c in run5_cat)
    expected_run6 = b''.join(hitext(p) + CR for p in run6_paths)
    expected_run6_err = hitext('find: max depth exceeded') + CR
    expected_run7 = b''.join(hitext(p) + CR for p in run7_paths)
    expected_run7_err = b''.join(hitext(e) + CR for e in run7_errs)

    return dict(
        run1=expected_run1, run1_status=0,
        run2=expected_run2, run2_status=0,
        run3=expected_run3, run3_status=0,
        run4=expected_run4, run4_status=0,
        run5=expected_run5, run5_status=0,
        run6=expected_run6, run6_err=expected_run6_err, run6_status=2,
        run7=expected_run7, run7_err=expected_run7_err, run7_status=1,
        run1_paths=run1_paths, run2_paths=run2_paths,
        run3_paths=run3_paths, run4_paths=run4_paths,
        run6_paths=run6_paths, run7_paths=run7_paths,
    )


def main():
    rc = build()
    if rc:
        return rc
    expected = compute_expected(OUT_IMG)
    for key in ('run1', 'run2', 'run3', 'run4', 'run5', 'run6', 'run7'):
        print(f'[build-find] {key} expected: {expected[key]!r}')
    print(f'[build-find] run6 expected stderr: '
          f'{expected["run6_err"]!r} status={expected["run6_status"]}')
    print(f'[build-find] run7 expected stderr: '
          f'{expected["run7_err"]!r} status={expected["run7_status"]}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
