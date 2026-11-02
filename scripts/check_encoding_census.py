#!/usr/bin/env python3
"""check_encoding_census.py -- every program that could read text is
CLASSIFIED against foreign (low-ASCII, $0D) text
(`make check-encoding-census`; docs/ENCODING-CENSUS-NOTES.md).

WHY.  maux text is high-bit with $8D line ends; text from outside
(NuFX, a2til, ProDOS software) is low ASCII with $0D.  A tool that tests
only the high form misbehaves on it, usually INVISIBLY (the console
breaks lines on the file's own $0D).  `check-encoding` gates the tools
it has rows for, but that list is remembered: `more` was a fifteenth
tool nobody listed.  This gate removes the remembering.  It DERIVES the
candidate set from the tree and reconciles it with
scripts/encoding_census.txt, and fails when

  * a candidate program has no census line (new or renamed),
  * a census line names no candidate (stale),
  * a `covered` line names a row that does not exist in
    scripts/check_encoding.py FOREIGN_OK, or that row's command is not
    that program's,
  * a FOREIGN_OK row exists for a program the census does not call
    `covered` (the two lists disagree),
  * a `broken` line has no KNOWN_BROKEN entry in check_encoding.py, or
    a KNOWN_BROKEN entry names a program the census does not call
    `broken` (the two lists disagree),
  * a `gap` or `broken` has no kind or statement, an `exempt` has no
    reason, or the gap+broken count exceeds MAX_GAPS (a ratchet:
    classifying a new tool as either is a deliberate edit of both).

CANDIDATES = the union of
  (a) UTILS in the Makefile -- what the play image is built to carry;
  (b) every src/bin/*.s that no other src/bin file `put`s -- a top-level
      program manifest, which catches a tool someone forgot to add to
      UTILS (ld, mld) and the standalone stubs.
`put ../liba/X` is a library include and never makes X a bin helper
(liba/env.s vs bin/env.s).  Helper modules (shlex.s, sedexec.s) are
parts of their program and are not candidates.  Candidates are
programs, deliberately over-approximate: a tool that reads no text is
`exempt` WITH A REASON, which is the point -- someone said so.

CLASSES (one line per program, fields separated by `|`):
  NAME covered | ROW COMMAND | reason
      a FOREIGN_OK row (exact command string) exercises it on foreign
      text with EXACT rows pinned.
  NAME exempt | reason
      it does not read text line-wise (binary, argv-only, byte pump).
  NAME broken KIND | statement
      the defect is KNOWN and REPRODUCIBLE today.  check_encoding.py
      KNOWN_BROKEN holds the command and the EXACT broken output it
      produces, so the day the tool is fixed that gate (which boots the
      emulator, unlike this static one) goes RED, names this line, and
      forces it out: delete the KNOWN_BROKEN entry, add a FOREIGN_OK
      row, flip the line to `covered`.  A ratchet that records only
      good news stops being read (learning 01M0MR5GK102H8EXBJRWRNPSK7).
  NAME gap KIND | statement
      unverified or known broken on foreign text.  KIND keeps the two
      defect classes apart (learning 01M317VKBTQPCDM2DNMD36N1QV):
        terminator  the line-end predicate (a $0D beside the $8D)
        polarity    content/separator polarity (argv is high-bit, the
                    file low); a terminator fix does nothing for it
        both        both are known
        unverified  no evidence either way; nobody has run it
      A static audit (a `cmp #$8D` with no $0D sibling) is a SUSPECT,
      not proof; say so in the statement.  Closing a gap = add a
      FOREIGN_OK row, flip the line to `covered`.

Self-test (every run): a planted unclassified program, a dropped entry,
a stale entry, a covered claim naming a missing row, a row for a
non-covered program, a reasonless exempt and a statement-less gap must
each turn it red.

ASCII only.  Exit 0 green, 1 red (listed).
"""
import ast
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CENSUS = os.path.join(ROOT, 'scripts', 'encoding_census.txt')
ENCODING = os.path.join(ROOT, 'scripts', 'check_encoding.py')
MAKEFILE = os.path.join(ROOT, 'Makefile')
BINDIR = os.path.join(ROOT, 'src', 'bin')

#: Ratchet.  Raise only by deciding, in the same commit that adds the
#: census line, that a new tool ships unverified on foreign text.
MAX_GAPS = 19

PUT = re.compile(r'^\s+put\s+(\S+?)(?:\.s)?\s*$')
CLASSES = ('covered', 'exempt', 'gap', 'broken')
GAPKINDS = ('terminator', 'polarity', 'both', 'unverified')


def utils(makefile_text):
    m = re.search(r'^UTILS\s*:=(.*?)\n(?=\S)', makefile_text, re.M | re.S)
    return set(m.group(1).replace('\\', ' ').split()) if m else set()


def tops(bindir):
    names, put = set(), set()
    for f in glob.glob(os.path.join(bindir, '*.s')):
        names.add(os.path.basename(f)[:-2])
        for ln in open(f, errors='replace'):
            code = ln.split(';', 1)[0].rstrip()
            m = PUT.match(code)
            if not m or 'liba' in m.group(1):
                continue
            put.add(os.path.basename(m.group(1)))
    return names - put


def candidates(makefile_text, bindir):
    return utils(makefile_text) | tops(bindir)


def rows(encoding_text):
    """The FOREIGN_OK commands of check_encoding.py (parsed, not
    imported: that module drives an emulator at import)."""
    for node in ast.parse(encoding_text).body:
        if isinstance(node, ast.Assign) and any(
                getattr(t, 'id', '') == 'FOREIGN_OK' for t in node.targets):
            return [r[0] for r in ast.literal_eval(node.value)]
    return []


def broken_rows(encoding_text):
    """Census program names of check_encoding.py KNOWN_BROKEN."""
    for node in ast.parse(encoding_text).body:
        if isinstance(node, ast.Assign) and any(
                getattr(t, 'id', '') == 'KNOWN_BROKEN'
                for t in node.targets):
            return [r[2] for r in ast.literal_eval(node.value)]
    return []


def load(text):
    cen, bad = {}, []
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        head, _, rest = line.partition('|')
        w = head.split()
        if len(w) < 2 or w[1] not in CLASSES:
            bad.append(f'line {n}: malformed: {raw!r}')
            continue
        name, cls = w[0], w[1]
        kind = w[2] if len(w) > 2 else ''
        if name in cen:
            bad.append(f'line {n}: {name} classified twice')
        cen[name] = (cls, kind, [p.strip() for p in rest.split('|')])
    return cen, bad


def judge(cands, census_text, row_cmds, known=()):
    fails = []
    cen, bad = load(census_text)
    fails += ['encoding_census.txt: ' + b for b in bad]
    for c in sorted(cands):
        if c not in cen:
            fails.append(f'src/bin/{c}.s: program {c} is not in '
                         f'scripts/encoding_census.txt -- classify it '
                         f'covered, exempt (with a reason) or gap')
    for c in sorted(cen):
        if c not in cands:
            fails.append(f'encoding_census.txt: {c} names no program '
                         f'(stale -- renamed or removed)')
    covered = set()
    gaps = 0
    for c, (cls, kind, parts) in sorted(cen.items()):
        if cls == 'covered':
            covered.add(c)
            cmd = parts[0] if parts else ''
            if cmd not in row_cmds:
                fails.append(f'encoding_census.txt: {c} claims row '
                             f'{cmd!r} but check_encoding.py FOREIGN_OK '
                             f'has no such row')
            elif cmd.split()[0] != c:
                fails.append(f'encoding_census.txt: {c} claims row '
                             f'{cmd!r}, which is another program\'s')
        elif cls == 'exempt':
            if not parts or not parts[0]:
                fails.append(f'encoding_census.txt: {c} exempt without a '
                             f'reason')
        else:
            gaps += 1
            if cls == 'broken' and c not in known:
                fails.append(f'encoding_census.txt: {c} is `broken` but '
                             f'check_encoding.py KNOWN_BROKEN has no '
                             f'entry asserting its failure')
            if kind not in GAPKINDS:
                fails.append(f'encoding_census.txt: {c} gap needs a kind '
                             f'in {GAPKINDS}, got {kind!r}')
            if not parts or not parts[0]:
                fails.append(f'encoding_census.txt: {c} gap without a '
                             f'statement')
    for w in known:
        if cen.get(w, ('',))[0] != 'broken':
            fails.append(f'check_encoding.py: KNOWN_BROKEN entry for {w} '
                         f'but the census does not call {w} broken')
    for cmd in row_cmds:
        w = cmd.split()[0]
        if w not in covered:
            fails.append(f'check_encoding.py: FOREIGN_OK row {cmd!r} but '
                         f'the census does not call {w} covered')
    if gaps > MAX_GAPS:
        fails.append(f'{gaps} gaps exceeds MAX_GAPS={MAX_GAPS}: close one, '
                     f'or raise the ratchet deliberately')
    return fails, cen


def selftest(cands, text, row_cmds, known):
    bad = []
    cen, _ = load(text)
    gap1 = sorted(c for c in cen if cen[c][0] == 'gap')[0]
    brk1 = sorted(c for c in cen if cen[c][0] == 'broken')[0]
    cov1 = sorted(c for c in cen if cen[c][0] == 'covered')[0]

    def without(name):
        return '\n'.join(l for l in text.splitlines()
                         if l.split()[:1] != [name])

    def swap(name, newline):
        return without(name) + '\n' + newline + '\n'

    if not judge(cands | {'newtool'}, text, row_cmds, known)[0]:
        bad.append('an unclassified new program did not fail')
    if not judge(cands, without(cov1), row_cmds, known)[0]:
        bad.append('a dropped census entry did not fail')
    if not judge(cands, text + '\nghost exempt | planted\n', row_cmds, known)[0]:
        bad.append('a stale census entry did not fail')
    if not judge(cands, text + '\nghost2 covered | ghost2 /nope | x\n',
                 row_cmds, known)[0]:
        bad.append('a covered claim on a missing row did not fail')
    if not judge(cands, text, row_cmds + ['zz /mnt/MAUX/LOW'])[0]:
        bad.append('a FOREIGN_OK row for an uncovered program did not fail')
    if not judge(cands, swap(gap1, f'{gap1} exempt |'), row_cmds, known)[0]:
        bad.append('an exempt without a reason did not fail')
    if not judge(cands, swap(gap1, f'{gap1} gap unverified |'),
                 row_cmds, known)[0]:
        bad.append('a gap without a statement did not fail')
    if not judge(cands, text, row_cmds, [k for k in known if k != brk1])[0]:
        bad.append('a broken line with no KNOWN_BROKEN entry (the tool '
                   'was fixed and the entry removed, or never added) '
                   'did not fail')
    if not judge(cands, text, row_cmds, list(known) + [cov1])[0]:
        bad.append('a KNOWN_BROKEN entry for a program the census does '
                   'not call broken did not fail')
    return bad


def main():
    mk = open(MAKEFILE).read()
    text = open(CENSUS).read()
    cands = candidates(mk, BINDIR)
    row_cmds = rows(open(ENCODING).read())
    known = broken_rows(open(ENCODING).read())
    fails, cen = judge(cands, text, row_cmds, known)
    fails += ['SELF-TEST: ' + x for x in selftest(cands, text, row_cmds, known)]
    n = {k: sum(1 for v in cen.values() if v[0] == k) for k in CLASSES}
    if fails:
        print(f'[check-encoding-census] FAIL: {len(fails)} problem(s)')
        for x in fails:
            print('  - ' + x)
        return 1
    print(f'[check-encoding-census] PASS: {len(cands)} programs '
          f'classified ({n["covered"]} covered, {n["exempt"]} exempt, '
          f'{n["broken"]} broken, {n["gap"]} gap); self-test: unclassified program, dropped '
          f'entry, stale entry, missing row, orphan row, empty reason '
          f'empty gap, broken without an assertion and orphan assertion each fail')
    return 0


if __name__ == '__main__':
    sys.exit(main())
