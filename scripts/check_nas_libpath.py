#!/usr/bin/env python3
"""check_nas_libpath.py -- every `ld -l NAME` in the staged native
MAKEFILE resolves, as the guest's ld would resolve it, to a library
directory that will hold REL members (KFIX4 item 1; part of
`make check-nas-selfmake-image`, so in the sweep).

WHY. The native kernel rebuild was dead for 19 days and no gate saw
it: `check-nas-selfmake` (the guest running the MAKEFILE) is not in the
sweep and `check-nas-selfmake-image` only modelled the graph.  The
defect was a DIRECTORY NAME.  ld finds a `-l k` library as
`<each -L path>/LIBK`, then `/usr/lib/LIBK`; the staged MAKEFILE built
the kernel objects into `/tmp/K`, so `-l k` scanned a directory that
held only sources, took nothing, and the guest's ld stopped on the
first symbol the explicit modules left undefined (`undefined symbol
PRC_BRK`).  Everything ld needs to decide that is in the staged image
and the MAKEFILE, so it is decided here on the host in about a second.

WHAT IT ASSERTS, for every link rule in /tmp/LR/MAKEFILE:
  1. each `-l NAME` resolves (first existing of `<-L>/LIBNAME`... in
     command-line order, then `/usr/lib/LIBNAME`, ldlib.s) to a
     directory whose REL members -- the `$F8` files already in the
     staged image plus every object some rule of the MAKEFILE will
     create there -- are NOT empty;
  2. every dependency of the rule that lives in a directory is either
     in a resolved library directory or in a `-L` directory (so ld
     can reach it by name); an object built where ld never looks is
     a defect even when something else satisfied `-l`.
`@file` argument files are expanded from the image the way ld does.

Teeth (KFIX4-NOTES sec 1): LIBKDIR back to `/tmp/K` in
build_nas_librel_image.py -> rule MAUXPLAY.SYSTEM red on assertion 1
(`/usr/lib/LIBK` holds sources, no REL member).

Exit 0 green, 1 red (listed), 2 rig problem.  ASCII only.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'scripts'))
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import a2til  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

IMG = os.path.join(ROOT, 'build', 'nas-selfmake.po')
DEFLIB = '/usr/lib'            # src/bin/ldout.s DEFLIB
FTYPE_RELM = 0xF8


def high_clear(data):
    return bytes(b & 0x7F for b in data).decode('ascii', 'replace') \
        .replace('\r', '\n')


def parse_makefile(text):
    """Returns ({macro: value}, [(targets, deps, [cmds])])."""
    macros, rules, cur = {}, [], None
    for raw in text.split('\n'):
        if not raw.strip():
            continue
        if raw.startswith('\t'):
            if cur is not None:
                cur[2].append(raw.strip())
            continue
        m = re.match(r'^([A-Za-z0-9_]+)\s*=\s*(.*)$', raw)
        if m:
            macros[m.group(1)] = m.group(2).strip()
            continue
        if ':' in raw and not raw.startswith('.'):
            head, deps = raw.split(':', 1)
            cur = (head.split(), deps.split(), [])
            rules.append(cur)
        else:
            cur = None
    return macros, rules


def expand(word_list, macros):
    out = []
    for w in word_list:
        m = re.fullmatch(r'\$\((\w+)\)', w)
        if m and m.group(1) in macros:
            out.extend(expand(macros[m.group(1)].split(), macros))
        else:
            out.append(w)
    return out


def norm(p):
    return p.rstrip('/').upper()


class Image:
    def __init__(self, path):
        self.vol = a2til.open_image(path)
        self._dirs = {}

    def listing(self, d):
        """{NAME: (type, is_dir)} of directory d, or None if absent."""
        key = norm(d)
        if key not in self._dirs:
            try:
                self._dirs[key] = {e.name.upper(): e
                                   for e in self.vol.scandir(d)}
            except Exception:  # noqa: BLE001 -- absent / not a directory
                self._dirs[key] = None
        return self._dirs[key]

    def read(self, path):
        return bytes(self.vol.read_file(path))


def ld_words(cmd_words, img):
    """The words of an `ld` command, `@file` expanded like ldargf.s."""
    out = []
    for w in cmd_words:
        if w.startswith('@') and len(w) > 1:
            out.extend(high_clear(img.read(w[1:])).split())
        else:
            out.append(w)
    return out


def check_rule(target, deps, cmds, macros, img, built, failures):
    for cmd in cmds:
        words = expand(cmd.split(), macros)
        # drop the `ld` itself (a macro or a path ending in LD)
        if not words or os.path.basename(words[0]).upper() != 'LD':
            continue
        words = ld_words(words[1:], img)
        ldirs = [w[2:] for w in words if w.startswith('-L') and len(w) > 2]
        libs = [words[i + 1] for i, w in enumerate(words[:-1]) if w == '-l']
        resolved = []
        for lib in libs:
            cands = [f'{d}/LIB{lib}' for d in ldirs] + [f'{DEFLIB}/LIB{lib}']
            hit = next((c for c in cands
                        if img.listing(c) is not None
                        or any(norm(os.path.dirname(b)) == norm(c)
                               for b in built)), None)
            if hit is None:
                failures.append(f'{target}: `-l {lib}`: none of '
                                f'{cands} exists')
                continue
            have = [n for n, e in (img.listing(hit) or {}).items()
                    if getattr(e, 'type', None) == FTYPE_RELM]
            will = [b for b in built if norm(os.path.dirname(b)) == norm(hit)]
            if not have and not will:
                failures.append(
                    f'{target}: `-l {lib}` resolves to {hit}, which holds '
                    f'no REL member now and that no MAKEFILE rule builds '
                    f'-- ld would take nothing from it (the unseen '
                    f'`undefined symbol` of KFIX4 item 1)')
            else:
                print(f'[check-nas-libpath] ok {target}: -l {lib} -> '
                      f'{hit} ({len(have)} staged, {len(will)} built)')
            resolved.append(norm(hit))
        reach = set(resolved) | {norm(d) for d in ldirs}
        for d in deps:
            if '/' not in d:
                continue
            dd = norm(os.path.dirname(d))
            if dd and dd not in reach:
                failures.append(
                    f'{target}: dependency {d} is built in {dd}, which is '
                    f'neither a resolved -l directory nor a -L directory '
                    f'of its link: ld cannot reach it')


def main():
    if not os.path.exists(IMG):
        print(f'check-nas-libpath: {IMG} missing -- make nas-selfmake-image',
              file=sys.stderr)
        return 2
    img = Image(IMG)
    try:
        text = high_clear(img.read('/tmp/LR/MAKEFILE'))
    except Exception as exc:  # noqa: BLE001
        print(f'check-nas-libpath: cannot read /tmp/LR/MAKEFILE: {exc}',
              file=sys.stderr)
        return 2
    macros, rules = parse_makefile(text)
    # every object some rule creates (its target, and with several
    # `$(A) -o OBJ` commands the objects those name)
    built = set()
    for targets, deps, cmds in rules:
        built.update(t for t in targets if '/' in t)
        for c in cmds:
            m = re.search(r'-o\s+(\S+)', c)
            if m and '/' in m.group(1) and 'NAS' in c.upper().split()[0]:
                built.add(m.group(1))
            m = re.search(r'\$\(A\)\s+-o\s+(\S+)', c)
            if m and '/' in m.group(1):
                built.add(m.group(1))
    # inferred objects are never a target: their names are only in
    # the dependency lists of the links that need them
    for targets, deps, cmds in rules:
        built.update(d for d in deps
                     if '/' in d and not d.upper().endswith('.S'))
    failures = []
    nlinks = 0
    for targets, deps, cmds in rules:
        if any(c.split() and os.path.basename(
                expand(c.split(), macros)[0]).upper() == 'LD'
               for c in cmds):
            nlinks += 1
            check_rule(targets[0], deps, cmds, macros, img, built, failures)
    if nlinks < 80:
        failures.append(f'only {nlinks} link rules found in the MAKEFILE: '
                        f'the parser is blind')
    if failures:
        print(f'[check-nas-libpath] FAIL: {len(failures)} problem(s)')
        for f_ in failures:
            print(f'  - {f_}')
        return 1
    print(f'[check-nas-libpath] PASS: {nlinks} link rules; every -l '
          f'library resolves to a directory ld can take members from')
    return 0


if __name__ == '__main__':
    sys.exit(main())
