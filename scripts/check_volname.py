#!/usr/bin/env python3
"""check_volname.py -- the boot volume is MAUX and nothing names BASIC.

docs/VROOT.md, "The rename and the corpus", step 5.  The boot volume was
renamed BASIC -> MAUX when the kernel grew a virtual root (`/bin`, `/usr`,
`/etc`, `/tmp` map into it, every volume appears under `/mnt`).  479 files
carried the old name; this gate keeps it from coming back.

Two halves, both host-side, no emulator:

 1. SOURCE.  No `/BASIC` path literal in scripts/, src/, inc/, Makefile,
    docs/man/ or the LIVE docs (LIVE_DOCS below).  `/BASIC.SYSTEM` (the
    stock ProDOS file), `graphics/BASIC` and the like are not path
    literals: the pattern needs a path separator in front, a slash or
    end after.  History docs are deliberately NOT scanned -- one line in
    docs/README.md says `/BASIC/` reads as `/` after the rename.
 2. IMAGES.  Every built maux boot image's volume is named MAUX.  This is
    check_prodos_version.boot_images -- the SAME walk that gate does for
    the kernel banner, reused rather than a second mount loop.

Teeth (`--self-test`, always run first): a planted `/BASIC/BIN/x` line is
caught by the source scan, a planted `/BASIC.SYSTEM` and
`graphics/BASIC` are not, and the volume predicate refuses `BASIC`.
Shown red on the base build in docs/VROOT-NOTES.md.

Exit 0 green, 1 red (listed), 2 rig problem.
"""
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

WANT_VOLUME = 'MAUX'
MIN_IMAGES = 10

#: A `/BASIC` that is a path component: not glued to a word in front,
#: followed by a separator, a quote, a space, a bracket or the line end.
#: `/BASIC.SYSTEM` (a file) and `x/BASIC` (graphics/BASIC) do not match.
BASIC_RE = re.compile(r"(?<![A-Za-z0-9_.)\]])/BASIC(?=[/'\"`\s)\]:,;]|$)")

SCAN_DIRS = ('scripts', 'src', 'inc', 'docs/man')
SCAN_FILES = ('Makefile',)

#: What the no-.git fallback must not read as source.  `git ls-files`
#: shows tracked files only; the walk that stands in for it on the box
#: sees everything on disk, and that includes `scripts/__pycache__`.
#: A .pyc carries its module's string constants, so the `/BASIC` that
#: an EXEMPT source file is allowed to spell comes back as a red under
#: a name the exemption does not cover.  Measured 2026-11-02: the box
#: sweep reported 16 such literals in five .pyc files (check_play,
#: check_posixex, check_posixsed, posixutil_cases2,
#: build_librelas_image -- three of them exempt by name) while the Mac,
#: which has a .git and so never takes this path, reported none.
SKIP_DIRS = ('__pycache__', '.git')
SKIP_EXT = ('.pyc', '.pyo', '.so', '.o', '.po', '.hdv', '.2mg', '.obj',
            '.bin', '.rel', '.dsk', '.a', '.d')

#: The docs that tell a reader how the machine IS (rewritten with the
#: rename).  The brief's list: README, USERLAND, SUPPORT, KNOWN-
#: LIMITATIONS, MAN, DEVFS, CD, SH-*.  Anything else under docs/ is
#: history or a design note dated at its writing, and keeps its words.
LIVE_DOCS = (
    'README.md', 'docs/README.md', 'docs/USERLAND.md', 'docs/SUPPORT.md',
    'docs/KNOWN-LIMITATIONS.md', 'docs/MAN.md', 'docs/DEVFS.md',
    'docs/CD.md', 'docs/PROJECT-STATE.md', 'docs/SH-FEATURES.md',
    'docs/SH-DOTPATH.md', 'docs/SH-BG.md', 'docs/SH-ALIAS-NOTES.md',
)

#: file -> why it may name /BASIC.  Each is a measurement of, or a note
#: about, the OLD name, and must stay one.
EXEMPT = {
    'scripts/check_volname.py': 'this gate names the pattern',
    'scripts/measure_vroot.py': 'M2 runs a build of the base commit, '
                                'where the volume is still BASIC',
    'docs/README.md': 'the one history line that says how to read '
                      'the old name',
}


def walk_fallback(root):
    """Stand in for `git ls-files` where there is no .git (the box
    rsyncs the tree without one).  Skips SKIP_DIRS and SKIP_EXT, which
    git would never have listed anyway."""
    found = []
    for d in SCAN_DIRS:
        for base, dirs, names in os.walk(os.path.join(root, d)):
            dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
            found += [os.path.relpath(os.path.join(base, n), root)
                      for n in names
                      if os.path.splitext(n)[1] not in SKIP_EXT]
    return sorted(found + list(SCAN_FILES) + list(LIVE_DOCS))


def tracked():
    out = subprocess.run(['git', 'ls-files'], cwd=ROOT,
                         capture_output=True, text=True)
    if out.returncode:                       # no .git (the box rsyncs)
        return walk_fallback(ROOT)
    return sorted(out.stdout.split())


def in_scope(rel):
    if rel in SCAN_FILES or rel in LIVE_DOCS:
        return True
    return any(rel.startswith(d + '/') for d in SCAN_DIRS)


def scan_text(text):
    """Line numbers (1-based) of /BASIC path literals in `text`."""
    return [i for i, line in enumerate(text.split('\n'), 1)
            if BASIC_RE.search(line)]


def scan_source():
    reds, files = [], 0
    for rel in tracked():
        if not in_scope(rel) or rel in EXEMPT:
            continue
        try:
            with open(os.path.join(ROOT, rel), encoding='ascii',
                      errors='replace') as fh:
                text = fh.read()
        except OSError:
            continue
        files += 1
        for n in scan_text(text):
            reds.append(f'{rel}:{n}: /BASIC path literal')
    return reds, files


def volume_ok(name):
    return name is not None and name.upper() == WANT_VOLUME


def scan_images():
    import check_prodos_version as CPV
    images = sorted(set(sum((glob.glob(os.path.join(ROOT, 'build', pat))
                             for pat in ('*.po', '*.hdv', '*.2mg')), [])))
    reds, seen = [], 0
    for base, _status, _detail, name in CPV.boot_images(images):
        seen += 1
        if not volume_ok(name):
            reds.append(f'{base}: volume is {name!r}, not {WANT_VOLUME}')
    return reds, seen, len(images)


def fallback_test():
    """The no-.git walk reaches real source and not generated bytecode:
    a planted scripts/x.py IS listed, scripts/__pycache__/x.pyc is NOT.
    Both carry a /BASIC, so a walk that returned the .pyc would be red
    on a tree git calls clean (the box, 2026-11-02)."""
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        sd = os.path.join(tmp, 'scripts', '__pycache__')
        os.makedirs(sd)
        with open(os.path.join(tmp, 'scripts', 'x.py'), 'w') as fh:
            fh.write('ls /BASIC/BIN\n')
        with open(os.path.join(sd, 'x.cpython-311.pyc'), 'w') as fh:
            fh.write('ls /BASIC/BIN\n')
        got = walk_fallback(tmp)
    return ('scripts/x.py' in got
            and not any('__pycache__' in g for g in got))


def self_test():
    planted = ('ls /BASIC/BIN/x\n'
               'cat "/BASIC"\n'
               'cp /BASIC\n')
    clean = ('prodos.remove(\'/MAUX/BASIC.SYSTEM\')\n'
             'future graphics/BASIC\n'
             'the BASIC prompt\n')
    walk_ok = fallback_test()
    ok = (scan_text(planted) == [1, 2, 3] and scan_text(clean) == []
          and not volume_ok('BASIC') and not volume_ok(None)
          and volume_ok('MAUX') and volume_ok('maux') and walk_ok)
    print(f'self-test: planted /BASIC caught, /BASIC.SYSTEM and '
          f'graphics/BASIC left alone, volume BASIC refused, the '
          f'no-.git walk takes scripts/x.py and leaves __pycache__: '
          f'{"PASS" if ok else "FAIL"}')
    return ok


def main(argv):
    # The carrier itself first: a stale vendor/prodos-basic.po is the one
    # cause of every image being named wrong at once (check_carrier.py).
    import check_carrier
    carrier_msg = check_carrier.check(
        os.path.join(ROOT, 'vendor', 'prodos-basic.po'))
    if carrier_msg:
        print(f'RED  carrier: {carrier_msg}')
    if not self_test():
        print('check-volname: self-test failed; the predicate has no teeth')
        return 2
    if '--self-test' in argv:
        return 0
    reds, files = scan_source()
    for r in reds:
        print(f'RED  {r}')
    print(f'check-volname: source: {files} file(s) scanned '
          f'({len(EXEMPT)} exempt), {len(reds)} /BASIC literal(s)')
    if '--source-only' in argv:
        return 1 if reds else 0
    try:
        ireds, seen, total = scan_images()
    except Exception as exc:                 # a2til missing, etc.
        print(f'check-volname: cannot walk images: {exc}')
        return 2
    for r in ireds:
        print(f'RED  {r}')
    print(f'check-volname: images: {seen} maux boot image(s) of {total} '
          f'under build/, {len(ireds)} not named {WANT_VOLUME}')
    if seen < MIN_IMAGES:
        print(f'check-volname: only {seen} boot images seen; need '
              f'{MIN_IMAGES} -- run the image targets first')
        return 2
    return 1 if (reds or ireds) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
