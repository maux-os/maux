#!/usr/bin/env python3
"""check_lc.py -- the language-card ratchet: only $C083 and $C08B.

WHY THIS EXISTS. The write-enable for $D000-$FFFF is ONE latch for the
whole machine and there is NO way to read it back (the //e's $C011-$C018
status family reports bank-select and read-source; nothing reports
write-enable -- measured on MAME, docs/LANGUAGE-CARD.md). A scheduler
cannot save and restore what it cannot read. So a process that holds
write-enable across a window it can be preempted in loses the rest of
its stores IN SILENCE, because this machine has no memory protection and
therefore nothing to fault with.

That killed the machine on 2026-09-20: sh's SEG_INIT held write-enable
across a 4 KB copy into its own language card, liba stdio in ANOTHER
process closed its own bracket with a write-protect, and everything from
$ECD2 to $EFFF went nowhere. sh then called SB_T0CAP at $ED39, found
$00 $00, and the kernel parked in KRN_BRK_TRAP with interrupts masked
(a user BRK now kills just the process, docs/KBRK.md; this gate is a
static source scan and never watched the park).
It was the third instance of the shape -- ld hung the same way on
2026-08-20 (src/bin/mld.s LD_PUTCH) -- and the first that was fatal.

THE RULE, therefore: $C083 and $C08B are the only two of the sixteen
switches any maux code may touch. Both select read-RAM AND write-enable
and differ only in bank, so no sequence of them can ever protect, and
none can ever select ROM under a process that is about to call into its
own language card. The steady state is established once in INSTALL_COPY
(src/kernel/entry2.s) and never disturbed again.

Comments are not policed: this file's own prose, and several source
headers, must be able to NAME the banned spellings to explain them.

OAPPEND-1, 2026-10-23 (ruling after the check-lc-prodos red, docs/
OAPPEND-1-NOTES.md sec 16.3): check_lc_prodos.py no longer scans maux's
own cold segment (KSEG, LC bank 2 [KSEG_ORG, KSEG_END)) -- those bytes are
maux's, not ProDOS's, and a linear byte scan reads layout coincidences in
them as language-card accesses.  THIS file is therefore the ONLY guard for
the bytes of the segment, and it was hardened first:

  * byelaunch.s's file-wide ALLOW is gone.  The one legitimate switch it
    names is an EXACT SITE (SITE_ALLOW): the `da $C082` of the
    BL2_EXITTBL template.  Any other $C08x in that module is red, and the
    self-test plants one.
  * kseg_closure_problems(): every module put/used between KSEG_LOW and
    KSEG_END of a manifest that carries a segment must be a tracked
    source file this scan can read -- a `putbin` blob or a generated
    supplier (a file under build/, a missing file) in that closure is
    bytes this gate cannot see, and fails loudly.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SOURCE_EXT = ('.s', '.equ', '.pla')

#: The only two legal spellings, by literal address and by mm.hw.equ name.
LEGAL_ADDR = ('C083', 'C08B')
LEGAL_NAME = ('LCBANK1_RAM', 'LCBANK2_RAM', 'LC_FREE_RW', 'LC_KRN_RW')

#: mm.hw.equ names that resolve to a banned address.
BANNED_NAME = {
    'LCBANK1_STORE': '$C080 read RAM, write-PROTECT',
    'LCBANK1_RW':    '$C081 read ROM, write-enable',
    'LCBANK1_ROM':   '$C082 read ROM, write-protect',
    'LCBANK2_STORE': '$C088 read RAM, write-PROTECT',
    'LCBANK2_RW':    '$C089 read ROM, write-enable',
    'LCBANK2_ROM':   '$C08A read ROM, write-protect',
}

#: Declared exemptions -- path -> why. Same shape as check_ascii.ALLOW
#: and check_modules.KNOWN_DEBT: a dict nobody can add to silently.
ALLOW = {
    'inc/mm.hw.equ':
        "The DEFINITION file. It must spell all sixteen switches to "
        "name them, and it carries the rule itself.",
    'src/bin/proshim.s':
        "The ProDOS-tenant shim. It goes read-ROM ($C081) deliberately, "
        "to copy the real //e monitor ROM into the tenant's LC RAM, and "
        "it already masks interrupts across that window for exactly the "
        "reason this gate exists (an IRQ there fetches $FFFE from ROM).",
    'src/bin/proshimpg.s':
        "The LC page-mapping prober: enumerating the groups IS its job.",
}

#: Exact-site exemptions (path -> [(enclosing label, mnemonic, switch,
#: why)]): the ONE place in a file that may name a banned switch.
#: byelaunch.s used to be exempt FILE-WIDE, which made any new $C08x in
#: that module invisible -- and since check_lc_prodos.py stopped scanning
#: the segment this file is the only guard of those bytes.  A site is the
#: instruction's mnemonic and switch inside the block of ONE global label
#: (a column-0 label opens a block; `:local` labels do not).
SITE_ALLOW = {
    'src/kernel/byelaunch.s': [
        ('BL2_EXITTBL', 'da', 'C082',
         "The `bye PATH.SYSTEM` launch, docs/BYE.md 'Slice 2 launch': "
         "BL2_EXITTBL is a read-ROM SELECT TEMPLATE (LDA $C082 / CLI / "
         "JMP TENANT_ORG) copied byte-for-byte into page 1 (BL2_EXIT, "
         "ALTZP-governed) and executed THERE, never in place in the "
         "LC, immediately before handing off to the tenant: a real "
         "ProDOS .SYSTEM calling a bare monitor ROM routine ($FDED "
         "COUT) is not an MLI call and gets no bank reselect (MEASURED: "
         "a real BRK inside COUT's own address range). Interrupts are "
         "masked across the window (BYE_LEAVE's own `sei`, lifted only "
         "after this select, matching ProDOS's QUIT dispatcher order: "
         "LDA $C082 then CLI, docs/LANGUAGE-CARD.md)."),
    ],
}

#: Case-insensitive on purpose: gate the form a human types, not the
#: form the tree happens to use today.
ADDR_RE = re.compile(r'\$[Cc]08([0-9A-Fa-f])')
NAME_RE = re.compile(r'\b(' + '|'.join(BANNED_NAME) + r')\b',
                     re.IGNORECASE)


def code_of(line):
    """The instruction part of a merlin32 line: a `*` in column 1 makes
    the whole line a comment, and `;` opens a trailing one."""
    if line[:1] == '*' or line.strip()[:1] == '*':
        return ''
    return line.split(';', 1)[0]




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
        return [p for p in out.split('\0')
                if p and p.endswith(SOURCE_EXT)]
    except (subprocess.CalledProcessError, FileNotFoundError):
        print('[check-lc] no git here -- walking the tree instead '
              '(stricter: untracked files count too)')
        return _walk(ROOT, lambda r: r.endswith(SOURCE_EXT))


def _label_of(raw, current):
    """The enclosing GLOBAL label after this line: a column-0 token that
    is not a comment and not a `:local` opens a new block."""
    if not raw or raw[0] in ' \t*;:':
        return current
    return raw.split()[0]


def _mnemonic(raw):
    """The instruction mnemonic of a merlin32 code line (label, if any,
    skipped), lower case."""
    toks = code_of(raw).split()
    if not toks:
        return ''
    if raw[:1] not in ' \t' and len(toks) > 1:
        return toks[1].lower()
    return toks[0].lower()


def offenders(paths, allow=ALLOW, root=None, sites=None, used=None):
    """Every banned spelling in code, minus whole-file `allow` and exact
    `sites` (label, mnemonic, switch).  `used`, if given, collects the
    (path, site) pairs an exemption actually covered."""
    root = root or ROOT
    sites = SITE_ALLOW if sites is None else sites
    out = []
    for rel in paths:
        if rel in allow:
            continue
        try:
            text = open(os.path.join(root, rel), encoding='ascii',
                        errors='replace').read()
        except OSError:
            continue
        label = ''
        for n, raw in enumerate(text.splitlines(), 1):
            label = _label_of(raw, label)
            code = code_of(raw)
            if not code:
                continue
            hits = []
            for m in ADDR_RE.finditer(code):
                spelling = 'C08' + m.group(1).upper()
                if spelling not in LEGAL_ADDR:
                    hits.append((spelling, '$' + spelling))
            for m in NAME_RE.finditer(code):
                name = m.group(1).upper()
                hits.append((name, name + ' (' + BANNED_NAME[name] +
                             ')'))
            for sw, what in hits:
                site = next((x for x in sites.get(rel, ())
                             if x[0] == label and x[1] == _mnemonic(raw)
                             and x[2] == sw), None)
                if site:
                    if used is not None:
                        used.append((rel, site[:3]))
                    continue
                out.append((rel, n, what, raw.strip()))
    return out


def dead_site_entries(paths, sites=None, root=None):
    """A declared SITE that is not found EXACTLY ONCE is stale (or has
    been duplicated): report it."""
    sites = SITE_ALLOW if sites is None else sites
    used = []
    offenders(paths, allow={}, root=root, sites=sites, used=used)
    dead = []
    for rel, lst in sites.items():
        for site in lst:
            n = used.count((rel, site[:3]))
            if rel not in paths:
                dead.append((rel, site[:3], 'no such tracked source file'))
            elif n != 1:
                dead.append((rel, site[:3], f'found {n} times, want 1'))
    return dead


def dead_allow_entries(paths, allow=ALLOW, root=None):
    """An exemption that no longer names a file, or names one with
    nothing left to exempt, is a lie the next reader will believe."""
    dead = []
    for rel, why in allow.items():
        if rel not in paths:
            dead.append((rel, 'no such tracked source file'))
            continue
        if not offenders([rel], allow={}, root=root, sites={}):
            dead.append((rel, 'file no longer touches a banned switch'))
    return dead


DIRECTIVE_RE = re.compile(r'^\s+(put|use|putbin)\s+(\S+)', re.IGNORECASE)


def _directives(path):
    """(directive, operand, lineno) for every put/use/putbin in a
    source file's CODE (comments ignored)."""
    out = []
    try:
        lines = open(path, encoding='ascii', errors='replace').read() \
            .splitlines()
    except OSError:
        return None
    for n, raw in enumerate(lines, 1):
        m = DIRECTIVE_RE.match(code_of(raw))
        if m:
            out.append((m.group(1).lower(), m.group(2), n))
    return out


def kseg_closure_problems(root=None, manifest_dir='src/test'):
    """The segment's bytes are no longer scanned by check_lc_prodos.py,
    so every byte of the segment must be readable HERE.  For each
    manifest that carries a segment (a column-0 `KSEG_LOW` label), walk
    the modules put/used between KSEG_LOW and KSEG_END -- and what THEY
    put -- and report anything this scan cannot read: a `putbin` blob,
    a generated supplier (under build/), a file that does not exist, or
    anything that is not a tracked-kind source (.s/.equ).  Returns
    problem strings; [] = every segment byte is source this gate
    reads."""
    root = root or ROOT
    mdir = os.path.join(root, manifest_dir)
    problems = []
    manifests = 0
    for name in sorted(os.listdir(mdir)) if os.path.isdir(mdir) else []:
        if not name.endswith('.s'):
            continue
        mpath = os.path.join(mdir, name)
        lines = open(mpath, encoding='ascii', errors='replace').read() \
            .splitlines()
        lo = next((i for i, l in enumerate(lines)
                   if l.split()[:1] == ['KSEG_LOW']), None)
        if lo is None:
            continue
        manifests += 1
        hi = next((i for i, l in enumerate(lines)
                   if i > lo and l.split()[:1] == ['KSEG_END']), None)
        if hi is None:
            problems.append(f'{manifest_dir}/{name}: KSEG_LOW without a '
                            f'KSEG_END')
            continue
        todo = []
        for i in range(lo + 1, hi):
            m = DIRECTIVE_RE.match(code_of(lines[i]))
            if m:
                todo.append((m.group(1).lower(), m.group(2), mdir,
                             f'{manifest_dir}/{name}:{i + 1}'))
        seen = set()
        while todo:
            d, operand, base, where = todo.pop()
            if d == 'putbin':
                problems.append(f'{where}: `putbin {operand}` in the KSEG '
                                f'closure -- a binary blob this scan '
                                f'cannot read')
                continue
            cand = [os.path.normpath(os.path.join(base, operand)),
                    os.path.normpath(os.path.join(mdir, operand))]
            path = next((c for c in cand if os.path.exists(c)), None)
            rel = os.path.relpath(path or cand[0], root)
            if path is None:
                problems.append(f'{where}: `{d} {operand}` names no file '
                                f'-- a generated supplier? the KSEG '
                                f'closure must be tracked source')
                continue
            if (rel.startswith('build' + os.sep) or
                    not rel.endswith(SOURCE_EXT)):
                problems.append(f'{where}: `{d} {operand}` is generated or '
                                f'not a scannable source ({rel})')
                continue
            if rel in seen:
                continue
            seen.add(rel)
            sub = _directives(path)
            for d2, o2, n2 in sub or []:
                todo.append((d2, o2, os.path.dirname(path),
                             f'{rel}:{n2}'))
    return problems, manifests


def self_test():
    """Teeth. A gate for a rule about silence has to be seen failing."""
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        ok = 'ok.s'
        open(os.path.join(d, ok), 'w').write(
            '* a comment naming $C088 and LCBANK2_STORE is fine\n'
            '            lda   LCBANK2_RAM        ;$C088 in a comment\n'
            '            lda   $C083\n')
        assert not offenders([ok], allow={}, root=d), offenders(
            [ok], allow={}, root=d)
        for bad, needle in (('            lda   LCBANK2_STORE\n',
                             'LCBANK2_STORE'),
                            ('            lda   $C088\n', '$C088'),
                            ('            lda   $C081\n', '$C081'),
                            ('            lda   $c08a\n', '$C08A'),
                            ('            lda   LCBANK1_RW\n',
                             'LCBANK1_RW')):
            p = 'bad.s'
            open(os.path.join(d, p), 'w').write(bad)
            found = offenders([p], allow={}, root=d)
            assert len(found) == 1, (bad, found)
            assert found[0][2].startswith(needle), (bad, found)
            assert not offenders([p], allow={p: 'exempt'}, root=d)
        assert dead_allow_entries([ok], allow={ok: 'x'}, root=d)
        assert dead_allow_entries([], allow={'gone.s': 'x'}, root=d)
        assert not dead_allow_entries(['bad.s'], allow={'bad.s': 'ok'},
                                      root=d)
    # exact-site exemption (byelaunch.s): the template's own line is
    # waved through, anything else in that module is red
    sites = {'k.s': [('TBL', 'da', 'C082', 'the template')]}
    with tempfile.TemporaryDirectory() as d:
        def run(text):
            open(os.path.join(d, 'k.s'), 'w').write(text)
            used = []
            off = offenders(['k.s'], allow={}, root=d, sites=sites,
                            used=used)
            return off, used
        base = ('TBL         dfb   $AD\n            da    $C082\n'
                '            dfb   $58\n')
        off, used = run(base)
        assert not off and len(used) == 1, (off, used)
        assert not dead_site_entries(['k.s'], sites=sites, root=d)
        off, _ = run(base + 'OTHER       lda   $C080\n')
        assert len(off) == 1 and off[0][2] == '$C080', off
        off, _ = run(base + 'OTHER2      da    $C082\n')
        assert len(off) == 1, ('a second `da $C082` under ANOTHER label '
                               'must be red', off)
        off, _ = run('TBL         lda   $C082\n')
        assert len(off) == 1, ('the right label with the wrong mnemonic '
                               'must be red', off)
        off, _ = run(base + '            lda   LCBANK1_ROM\n')
        assert len(off) == 1, ('a banned NAME inside the exempt block '
                               'must be red', off)
        open(os.path.join(d, 'k.s'), 'w').write('TBL         dfb   $AD\n')
        assert dead_site_entries(['k.s'], sites=sites, root=d), \
            'an exemption whose site is gone must be reported'
        run(base + base)           # duplicated site
        assert dead_site_entries(['k.s'], sites=sites, root=d), \
            'a duplicated site must be reported'
    # the KSEG closure: clean passes; putbin / generated / missing fail
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, 'src', 'test'))
        os.makedirs(os.path.join(d, 'src', 'kernel'))
        os.makedirs(os.path.join(d, 'build'))

        def mk(rel, text):
            open(os.path.join(d, rel), 'w').write(text)
        mk('src/kernel/a.s', '            nop\n')
        mk('src/kernel/b.s', '            putbin ../../build/x.bin\n')
        mk('src/kernel/c.s', '            put   ../../build/gen.s\n')
        mk('build/gen.s', '            nop\n')
        mk('src/kernel/d.s', '            put   ../kernel/a.s\n')

        def man(*puts):
            mk('src/test/m.s', 'START       nop\nKSEG_LOW\n' + ''.join(
                f'            put   {x}\n' for x in puts) + 'KSEG_END\n')
            return kseg_closure_problems(root=d)
        pr, n = man('../kernel/a.s', '../kernel/d.s')
        assert n == 1 and not pr, (pr, n)
        pr, _ = man('../kernel/a.s', '../kernel/b.s')
        assert len(pr) == 1 and 'putbin' in pr[0], pr
        pr, _ = man('../kernel/c.s')
        assert pr and 'generated' in pr[0], pr
        pr, _ = man('../kernel/nothere.s')
        assert pr and 'names no file' in pr[0], pr
        mk('src/test/m.s', 'KSEG_LOW\n            put ../kernel/a.s\n')
        pr, _ = kseg_closure_problems(root=d)
        assert pr and 'without a KSEG_END' in pr[0], pr
    print('PASS lc exact-site exemption: the template line is waved '
          'through; a second site, the wrong mnemonic, a banned name in '
          'the block and a planted `lda $C080` elsewhere in the module '
          'are red; a gone or duplicated site is reported')
    print('PASS lc KSEG closure: clean closure passes; a putbin blob, a '
          'generated supplier, a missing file and an unterminated '
          'segment each fail')
    print('PASS lc gate mutations: five planted spellings rejected '
          '(name and literal, both cases), comments ignored, exemption '
          'honoured, stale/gone exemption rejected')


def main():
    self_test()
    paths = tracked()
    bad = offenders(paths)
    dead = dead_allow_entries(paths)
    for rel, site, why in dead_site_entries(paths):
        print(f'FAIL lc: stale SITE_ALLOW {rel} {site}: {why}')
        dead.append((rel, 'site'))
    closure, nseg = kseg_closure_problems()
    for pr in closure:
        print(f'FAIL lc: KSEG closure: {pr}')
    if not nseg:
        print('FAIL lc: no manifest carries a KSEG segment: the closure '
              'check has nothing to read, so its silence means nothing')
        return 1
    for rel, n, what, line in bad:
        print(f'FAIL lc: {rel}:{n} uses {what}\n    {line}\n'
              f'    Only $C083/$C08B (LCBANK1_RAM/LCBANK2_RAM) are '
              f'legal -- docs/LANGUAGE-CARD.md.')
    for rel, why in dead:
        print(f'FAIL lc: stale ALLOW entry {rel}: {why}')
    if bad or dead or closure:
        return 1
    nsite = sum(len(v) for v in SITE_ALLOW.values())
    print(f'PASS lc: {len(paths)} tracked source files touch only '
          f'$C083/$C08B, {len(ALLOW)} whole-file exemption(s), {nsite} '
          f'exact site(s); the KSEG closure of {nseg} manifest(s) is all '
          f'scannable source')
    return 0


if __name__ == '__main__':
    sys.exit(main())
