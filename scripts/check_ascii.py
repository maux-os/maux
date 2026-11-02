#!/usr/bin/env python3
"""check_ascii.py -- the tree-wide ASCII rule, finally gated.

WHY THIS EXISTS. HACKING.md has said "ASCII only, in every file the tree
carries -- source AND docs" for months, and NOTHING enforced it. The rule
has a hardware reason, not a stylistic one: the console is a 7-bit VT102
and the keyboard is a //e's, so an em-dash paints as `b` through tip(1)
and cannot be typed back. Use `--`, `->`, `sec`, `<=`.

The cost of not gating it, twice:

  * 2026-09-12: 75 of 81 docs carried non-ASCII and were folded BY HAND.
    No gate was added, so the tree started drifting again immediately.
  * 2026-09-19: docs/SUPPORT.md and docs/HOST-PROVISIONING.md -- both
    written in the preceding two days -- had curly quotes, and the same
    day's docs/MAN.md edit quietly DELETED its own claim that the rule
    "is gated tree-wide, not just here", because that claim was false.
    A doc correcting itself to match the absence of a gate is the wrong
    direction of repair. Hence this file.

docs/man/*.1 and their renders were already covered by check_man.py; this
is the rest of the tree, from the same roster git itself reports, so a new
file is covered the moment it is tracked.

WHAT COUNTS AS NON-ASCII here is any byte >= 0x80. Control bytes below
0x20 are NOT policed: form feeds are load-bearing in the quoted Caldera
letter and tabs are load-bearing in Makefiles.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

#: Deliberate high-bit text -- path -> why it is exempt. Same shape as
#: check_modules.py's KNOWN_DEBT and e2e_divergence.py's DIVERGENCE: a
#: dict nobody can add to silently. These are not debt; they are files
#: whose CONTENT IS high-bit ASCII because ProDOS text is high-bit.
ALLOW = {
    'src/relspike/RTLIB.S#040000':
        "ProDOS TXT staged BY BYTE onto a disk image (the `#040000` "
        "suffix is a2til's type/auxtype spelling). Its high bit IS the "
        "file format -- folding it would break the REL spike image.",
    'src/relspike/RTMAIN.S#040000':
        "Same: high-bit ProDOS TXT, staged as bytes, not read as host "
        "text.",
}

#: Extensions whose content is not text at all.
BINARY_EXT = ('.bin', '.po', '.dsk', '.2mg', '.png', '.gif', '.jpg',
              '.pdf', '.gz', '.zip', '.rom', '.jed', '.o', '.mod',
              '.cut', '.pyc',
              # pinned/ (docs/DEPS-TIER.md): Merlin REL/object bytes
              '.obj', '.rel')




def _walk(root, keep):
    """Fallback roster when git is unavailable. The box runs the suite
    from an rsync'd tree with no .git (scripts/box_gate.sh), so
    `git ls-files` exits 128 there and this gate could never run on the
    second host at all -- found 2026-09-20, the first time the box was
    able to sweep since 2026-09-11. Walking the tree is STRICTER than
    the git roster (it also sees untracked files), which is the safe
    direction for a rule about what the tree carries."""
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if d not in ('.git', 'build', 'vendor', 'evidence')]
        for f in filenames:
            rel = os.path.relpath(os.path.join(dirpath, f), root)
            if keep(rel):
                out.append(rel)
    return sorted(out)


def tracked():
    try:
        out = subprocess.run(['git', '-C', ROOT, 'ls-files', '-z'],
                             capture_output=True, text=True,
                             check=True).stdout
        return [p for p in out.split('\0') if p]
    except (subprocess.CalledProcessError, FileNotFoundError):
        print('[check-ascii] no git here -- walking the tree instead '
              '(stricter: untracked files count too)')
        return _walk(ROOT, lambda r: True)


def offenders(paths, allow=ALLOW, root=None):
    bad = []
    for rel in paths:
        if rel in allow:
            continue
        if rel.lower().endswith(BINARY_EXT):
            continue
        full = os.path.join(root or ROOT, rel)
        if not os.path.isfile(full) or os.path.islink(full):
            continue
        raw = open(full, 'rb').read()
        # A NUL means this is not text the rule was written about.
        if b'\0' in raw[:8192]:
            continue
        hits = [i for i, c in enumerate(raw) if c >= 0x80]
        if hits:
            line = raw[:hits[0]].count(b'\n') + 1
            bad.append((rel, len(hits), line, raw[hits[0]]))
    return bad


def dead_allow_entries(paths, allow=ALLOW, root=None):
    """The ratchet only tightens: an exemption for a gone or now-clean
    file is cover for the next one, so it is an error, not a shrug."""
    dead = []
    present = set(paths)
    for rel in allow:
        if rel not in present:
            dead.append((rel, 'no longer tracked'))
            continue
        raw = open(os.path.join(root or ROOT, rel), 'rb').read()
        if not any(c >= 0x80 for c in raw):
            dead.append((rel, 'is now pure ASCII -- delete the entry'))
    return dead


def self_test():
    """Teeth: the gate must FAIL on a planted byte, and must not be
    satisfied by an exemption that no longer describes anything.

    The planted byte is written as an explicit UTF-8 BYTE SEQUENCE, not
    as a source literal -- a gate for ASCII source cannot itself carry
    the character it rejects, or it fails on itself."""
    import tempfile
    emdash = b"an em-dash \xe2\x80\x94 here\n"
    with tempfile.TemporaryDirectory() as d:
        clean, dirty = 'clean.md', 'dirty.md'
        open(os.path.join(d, clean), 'wb').write(b'plain -- ascii ->\n')
        open(os.path.join(d, dirty), 'wb').write(emdash)
        assert not offenders([clean], allow={}, root=d)
        found = offenders([dirty], allow={}, root=d)
        assert len(found) == 1 and found[0][0] == dirty, found
        assert found[0][1] == 3 and found[0][2] == 1, found
        assert not offenders([dirty], allow={dirty: 'exempt'}, root=d)
        assert dead_allow_entries([clean], allow={clean: 'x'}, root=d)
        assert dead_allow_entries([], allow={dirty: 'gone'}, root=d)
        assert not dead_allow_entries([dirty], allow={dirty: 'ok'}, root=d)
    print('PASS ascii gate mutations: planted high byte rejected, '
          'exemption honoured, stale/gone exemption rejected')


def main():
    self_test()
    paths = tracked()
    bad = offenders(paths)
    dead = dead_allow_entries(paths)
    for rel, n, line, byte in bad:
        print(f'FAIL ascii: {rel}: {n} byte(s) >= 0x80, first at line '
              f'{line} (0x{byte:02x}) -- fold it (-- -> <= sec)')
    for rel, why in dead:
        print(f'FAIL ascii: stale ALLOW entry {rel}: {why}')
    if bad or dead:
        return 1
    print(f'PASS ascii: {len(paths)} tracked paths, '
          f'{len(ALLOW)} declared high-bit ProDOS exemption(s)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
