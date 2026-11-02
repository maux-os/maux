#!/usr/bin/env python3
"""check_open_census.py -- every SC_OPEN call site is CLASSIFIED
(`make check-open-census`; docs/OPEN-RW-2.md item 6).

An open that declares READ intent (param_count OPEN_RO, inc/sc.file.equ)
may share a file with one writer (OPEN-RW-2); an open that does not is
write-capable, and a second write-capable open of a path is $50.  Which
call sites declare intent is therefore a property of every program, not
of the kernel, and it goes stale silently: a new `jsr SC_OPEN` defaults
to no intent, and `tail -f` beside a writer quietly stops working.  The
census (scripts/open_census.txt) lists every site with its intent and a
one-line reason, and this gate fails when

  * a site in src/bin or src/liba has no census line (new, or renamed),
  * a census line names no site (stale),
  * a site's census intent disagrees with what its parmlist's count byte
    is SET to (the literal OPEN_RO vs anything else).

OAPPEND-1 adds a third class, `append`: the count byte is OPEN_APPEND
(`$23`), the site's fd seeks to EOF before every write (src/kernel,
PRC_APPSEEK) and any number of appenders may share a file.  The gate
checks `ro` against OPEN_RO, `append` against OPEN_APPEND and `none`
against NEITHER, so a site silently called `none` that really declares
append (or the reverse) is red.

A site is `file LABEL`: the parmlist label loaded by the nearest
preceding `lda #<LABEL` (a second site on the same label in one file is
`LABEL#2`).  The count byte is the nearest preceding `lda #X / sta
LABEL` in the file, else the label's `dfb X` definition, else (a
parmlist defined in another file of the same program, found through the
`put` graph) OPEN_RO if the program ever stores it there.

Self-test (every run): a planted unclassified site, a dropped entry and
a flipped intent must each turn the gate red.

ASCII only.  Exit 0 green, 1 red (listed).
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CENSUS = os.path.join(ROOT, 'scripts', 'open_census.txt')
CALL = re.compile(r'^\s*\S*\s+(?:jsr|jmp)\s+SC_OPEN\b|^\s+ldy\s+#SYS_OPEN\b')
LOAD = re.compile(r'\blda\s+#<(\w+)')
DEF = re.compile(r'^(\w+)\s+dfb\s+(\w+)')


def strip(line):
    """Code part of a Merlin line (no comment, no full-line comment)."""
    if line[:1] in ('*', ';'):
        return ''
    return line.split(';', 1)[0].rstrip()


def source_files(root):
    out = []
    for d in ('src/bin', 'src/liba'):
        out += sorted(glob.glob(os.path.join(root, d, '*.s')))
    return out


def sites(files):
    """{(relfile, key): (lineno, label)} for every SC_OPEN call."""
    found = {}
    for f in files:
        rel = os.path.relpath(f, ROOT) if f.startswith(ROOT) else f
        if rel.endswith('liba/syscalls.s'):
            continue                      # the wrapper itself
        lines = open(f, errors='replace').read().splitlines()
        seen = {}
        for i, raw in enumerate(lines):
            code = strip(raw)
            if not code or not CALL.search(code):
                continue
            label = '?'
            for j in range(i - 1, max(i - 14, -1), -1):
                m = LOAD.search(strip(lines[j]))
                if m:
                    label = m.group(1)
                    break
            seen[label] = seen.get(label, 0) + 1
            key = label if seen[label] == 1 else f'{label}#{seen[label]}'
            found[(rel, key)] = (i + 1, label)
    return found


PUT = re.compile(r'^\s+put\s+(?:\.\./)*(?:bin/|liba/)?([\w.]+?)(?:\.s)?\s*$')
STORE_TOK = r'\blda\s+#(\w+)'


def acc_token(lines, j):
    """The `lda #X` that fed the `sta` on line j (other `sta`s of the
    same value may sit between)."""
    k = j - 1
    while k >= 0 and re.match(r'\s*sta\b', strip(lines[k]) or ' '):
        k -= 1
    m = re.search(STORE_TOK, strip(lines[k])) if k >= 0 else None
    return m.group(1) if m else None


class Tree:
    """The put graph of src/bin and src/liba: which files are one
    program (a top-level manifest and everything it puts)."""

    def __init__(self, byrel):
        self.by = byrel
        self.puts = {}
        for rel, ls in byrel.items():
            self.puts[rel] = set()
            for ln in ls:
                m = PUT.match(strip(ln))
                if not m:
                    continue
                for d in ('src/bin/', 'src/liba/'):
                    g = d + m.group(1) + '.s'
                    if g in byrel:
                        self.puts[rel].add(g)
        self.putby = {}
        for f, ps in self.puts.items():
            for g in ps:
                self.putby.setdefault(g, set()).add(f)

    def tops(self, f):
        seen, stack, res = {f}, [f], set()
        while stack:
            x = stack.pop()
            ps = self.putby.get(x, set())
            if not ps:
                res.add(x)
            for q in ps:
                if q not in seen:
                    seen.add(q)
                    stack.append(q)
        return res

    def program(self, f):
        """Every file in any program that contains f."""
        out = set()
        for t in self.tops(f):
            seen, stack = {t}, [t]
            while stack:
                x = stack.pop()
                for g in self.puts.get(x, ()):
                    if g not in seen:
                        seen.add(g)
                        stack.append(g)
            out |= seen
        return out


def tokens_in(lines, label):
    """Every count token a parmlist label gets in these lines: its
    `dfb X` definition and each `lda #X / sta LABEL`."""
    store = re.compile(r'\bsta\s+' + re.escape(label) + r'\s*$')
    out = []
    for j, ln in enumerate(lines):
        code = strip(ln)
        m = DEF.match(code)
        if m and m.group(1) == label:
            out.append(m.group(2))
        if j and store.search(code):
            t = acc_token(lines, j)
            if t:
                out.append(t)
    return out


def init_and_stores(rel, label, tree):
    """(initializer tokens, store tokens) of a parmlist label over the
    site's whole program: the `dfb X` definitions and every `lda #X /
    sta LABEL`.  A site's count is NOT only the nearest store above it:
    the cell starts at its initializer and a routine that stores around
    one call (sh's `<`) puts a resting value back."""
    store = re.compile(r'\bsta\s+' + re.escape(label) + r'\s*$')
    inits, stores = [], []
    for g in sorted(tree.program(rel) | {rel}):
        lines = tree.by[g]
        for j, ln in enumerate(lines):
            code = strip(ln)
            m = DEF.match(code)
            if m and m.group(1) == label:
                inits.append(m.group(2))
            if j and store.search(code):
                t = acc_token(lines, j)
                if t:
                    stores.append(t)
    return inits, stores


def count_token(rel, lineno, label, tree):
    """What the site's parmlist count byte is: 'OPEN_RO' or another
    token when visible in the site's own file (the nearest store above
    wins, then any, then the dfb), else, for a parmlist built in another
    file of the same program, 'OPEN_RO' if the program ever stores it,
    else the first other token; None when it cannot be seen."""
    lines = tree.by[rel]
    store = re.compile(r'\bsta\s+' + re.escape(label) + r'\s*$')
    order = list(range(lineno - 2, -1, -1)) + \
        list(range(len(lines) - 1, lineno - 2, -1))
    for j in order:                  # nearest above first, then below
        if j and store.search(strip(lines[j])):
            t = acc_token(lines, j)
            if t:
                return t
    local = tokens_in(lines, label)
    if local:
        return local[0]
    toks = []
    for g in sorted(tree.program(rel)):
        toks += tokens_in(tree.by[g], label)
    if 'OPEN_RO' in toks:
        return 'OPEN_RO'
    return toks[0] if toks else None


def load_census(text):
    cen = {}
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split(None, 3)
        if len(parts) < 4 or parts[2] not in ('ro', 'none', 'append'):
            cen[('?', f'line {n}')] = ('bad', raw)
            continue
        f = parts[0] if parts[0].startswith(('src/', '/')) \
            else 'src/' + parts[0]
        cen[(f, parts[1])] = (parts[2], parts[3])
    return cen


def judge(files, census_text):
    fails = []
    byrel = {}
    for f in files:
        rel = os.path.relpath(f, ROOT) if f.startswith(ROOT) else f
        byrel[rel] = open(f, errors='replace').read().splitlines()
    found = sites(files)
    tree = Tree(byrel)
    cen = load_census(census_text)
    for k, (ln, label) in sorted(found.items()):
        if k not in cen:
            fails.append(f'{k[0]}:{ln}: SC_OPEN site {k[1]} is not in '
                         f'scripts/open_census.txt -- classify it ro '
                         f'(it only reads) or none, with a reason')
            continue
        intent = cen[k][0]
        tok = count_token(k[0], ln, label, tree)
        want = {'ro': 'OPEN_RO', 'append': 'OPEN_APPEND'}
        if intent == 'append':
            inits, stores = init_and_stores(k[0], label, tree)
            bad = [t for t in inits if t != 'OPEN_APPEND'] + \
                  [t for t in stores if t not in ('OPEN_APPEND',
                                                  'OPEN_RO')]
            if not inits and not stores:
                bad = ['<none visible>']
            if bad:
                fails.append(f'{k[0]}:{ln}: census says {k[1]} is append '
                             f'but its parmlist initializer/stores '
                             f'include {sorted(set(bad))!r} (every '
                             f'initializer and store must be '
                             f'OPEN_APPEND, or the scoped OPEN_RO)')
        if intent in want and tok != want[intent]:
            fails.append(f'{k[0]}:{ln}: census says {k[1]} is {intent} '
                         f'but its parmlist count is {tok!r}, not '
                         f'{want[intent]}')
        if intent == 'none' and tok in ('OPEN_RO', 'OPEN_APPEND'):
            fails.append(f'{k[0]}:{ln}: census says {k[1]} is none but '
                         f'its parmlist count IS {tok}')
    for k, v in sorted(cen.items()):
        if v[0] == 'bad':
            fails.append(f'open_census.txt: malformed {k[1]}: {v[1]!r}')
        elif k not in found:
            fails.append(f'open_census.txt: {k[0]} {k[1]} names no '
                         f'SC_OPEN site (stale)')
    return fails, found, cen


def selftest(files, text):
    """The gate must be able to fail: plant each defect, expect red."""
    bad = []
    found = sites(files)
    drop = next(((f, k) for (f, k) in sorted(found)
                 if f.endswith('tail.s')), None)
    if drop:
        t = '\n'.join(l for l in text.splitlines()
                      if l.split()[:2] != [drop[0][4:], drop[1]])
        if not judge(files, t)[0]:
            bad.append('a dropped census entry (tail) did not fail')
    byrel = {}
    for f in files:
        rel = os.path.relpath(f, ROOT) if f.startswith(ROOT) else f
        byrel[rel] = open(f, errors='replace').read().splitlines()
    tree = Tree(byrel)
    cen0 = load_census(text)

    def flipped(cls, to, token):
        for k, v in sorted(cen0.items()):
            if v[0] == cls and k in found and count_token(
                    k[0], found[k][0], found[k][1], tree) == token:
                f0 = k[0][4:]
                return text.replace(f'{f0} {k[1]} {cls}',
                                    f'{f0} {k[1]} {to}', 1)
        return None

    for cls, to, token, what in (
            ('ro', 'none', 'OPEN_RO', 'a flipped read intent'),
            ('append', 'none', 'OPEN_APPEND', 'a flipped append<-none'),
            ('append', 'ro', 'OPEN_APPEND', 'an append called ro')):
        t = flipped(cls, to, token)
        if t is None:
            bad.append(f'{what}: no {cls} site to flip')
        elif not judge(files, t)[0]:
            bad.append(f'{what} did not fail')
    # a `none` site that is really declared append must be red too:
    # plant a synthetic append site classified none
    # an unclassified site: a synthetic file with one new call
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, 'newtool.s')
        with open(p, 'w') as fh:
            fh.write('START   lda #<NEWPARM\n        ldx #>NEWPARM\n'
                     '        jsr SC_OPEN\nNEWPARM dfb 3\n')
        if not judge(files + [p], text)[0]:
            bad.append('an unclassified new SC_OPEN site did not fail')
        # classified, but WRONG: count 3 called append / append called
        # none / append called ro
        for cnt, cls, what in (('3', 'append', 'a plain site called '
                                'append'),
                               ('OPEN_APPEND', 'none', 'an append site '
                                'called none'),
                               ('OPEN_APPEND', 'ro', 'an append site '
                                'called ro'),
                               ('OPEN_RO', 'append', 'a read site '
                                'called append')):
            with open(p, 'w') as fh:
                fh.write('START   lda #<NEWPARM\n        ldx #>NEWPARM\n'
                         '        jsr SC_OPEN\nNEWPARM dfb ' + cnt + '\n')
            t = text + f'\n{p} NEWPARM {cls} planted\n'
            if not judge(files + [p], t)[0]:
                bad.append(f'{what} did not fail')
        # M2: the nearest store says OPEN_APPEND, but the INITIALIZER is
        # count 3 -- a fresh process's first call opens with 3
        with open(p, 'w') as fh:
            fh.write('START   lda #OPEN_APPEND\n        sta NEWPARM\n'
                     '        lda #<NEWPARM\n        ldx #>NEWPARM\n'
                     '        jsr SC_OPEN\nNEWPARM dfb 3\n')
        t = text + f'\n{p} NEWPARM append planted\n'
        if not judge(files + [p], t)[0]:
            bad.append('an append site whose initializer is count 3 '
                       '(a store says append) did not fail')
        with open(p, 'w') as fh:           # and the right answer passes
            fh.write('START   lda #<NEWPARM\n        ldx #>NEWPARM\n'
                     '        jsr SC_OPEN\nNEWPARM dfb OPEN_APPEND\n')
        t = text + f'\n{p} NEWPARM append planted\n'
        if [x for x in judge(files + [p], t)[0] if p in x]:
            bad.append('a correctly classified append site failed')
    return bad


def main():
    files = source_files(ROOT)
    text = open(CENSUS).read()
    fails, found, cen = judge(files, text)
    st = selftest(files, text)
    for x in st:
        fails.append('SELF-TEST: ' + x)
    ro = sum(1 for v in cen.values() if v[0] == 'ro')
    ap = sum(1 for v in cen.values() if v[0] == 'append')
    if fails:
        print(f'[check-open-census] FAIL: {len(fails)} problem(s)')
        for x in fails:
            print('  - ' + x)
        return 1
    print(f'[check-open-census] PASS: {len(found)} SC_OPEN sites '
          f'classified ({ro} read-intent, {ap} append, '
          f'{len(found) - ro - ap} no-intent); self-test: dropped entry, '
          f'flipped intents (ro, append<->none), an append site with a wrong initializer and an unclassified site '
          f'each fail')
    return 0


if __name__ == '__main__':
    sys.exit(main())
