#!/usr/bin/env python3
"""kledger.py -- the exact per-label ledger of a flat kernel image.

Reads ONE merlin32 `-v1` listing (build/<IMAGE>.SYSTEM_Output.txt) and
attributes EVERY emitted byte of the image to
(segment, module file, nearest preceding GLOBAL label, kind).  It
changes no kernel byte; it measures (docs/KLEDGER.md).

THE LISTING.  `merlin32 -v1` prints one row per source line:
  seq | file# file line | Line Type | MX | Reloc | Size | addr : obj | src
with the object bytes continued on following rows (4 per row).  Each
row's Size is the bytes it emits, EXCEPT rows of Line Type `Dum`, which
are address bookkeeping inside a dum/dend arena and emit nothing
(learning:01M0PE18BN7FYDNGV0D8SDQ1WF).  The listing dumps a `:local`
label as `_name` and invents `ozunid_NNN` anchors for `*`; both bucket
into the preceding GLOBAL label (learning:01M2KR4SK1HCPV5Q691EJZMTJG),
and a label scope never crosses a put boundary: each put instance keeps
its own "last global label".

KINDS.
  code     Line Type `Code` (instruction rows)
  data     `dfb db dw da dda ddb dd asc dci str rev hex` rows (tables,
           strings)
  storage  `ds` rows: linked BSS carried INSIDE the image
  pad      a `ds` that is layout, not storage: its operand is
           star-relative (merlin32 prints the PC `*` as `ozunid_N`; a
           bare `*` in an operand is a multiply, e.g. `ds 14*8`, and
           is NOT a pad), or its trailing comment contains
           slack / align / pad / filler.  FFXX_SLACK is the former.
  Nothing else is allowed: a Line Type, or a sized mnemonic, that this
  file does not know is a hard failure naming the row, never a guess.

SEGMENTS.  A manifest that carries a cold segment (today only the play
image) assembles it after the labels KSEG_LOW and LSEG_LOW, and
scripts/split_kseg.py cuts the raw output there: the flat part is the
real `.SYSTEM`, the rest become the `_KSEG` and `_LSEG` sibling files
(each padded to 256 B).  The ledger follows the same cut by LABEL, so
three sections exist for that image: flat, kseg, lseg.

EXHAUSTIVENESS (the contract).  verify() fails, naming the rows, unless
  1. every row's Size equals the object bytes the listing prints for it;
  2. the segment boundaries agree with the symbol dump
     (KSEG_LOW - org == the flat length);
  3. the flat sum equals the `.SYSTEM` size ON DISK, the kseg / lseg sums
     equal their files' unpadded lengths (files are 256-padded); and
  4. the listing's object bytes equal the bytes on disk, byte for byte.
Unattributed bytes are therefore zero by construction: they would show
as a size or content mismatch.  A stale listing, a listing from another
build, and a hand-edited image all fail (3) or (4).

Python 3 stdlib only.  ASCII only.
"""
import argparse
import collections
import fnmatch
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')
TABLE = os.path.join(ROOT, 'docs', 'KLEDGER-TABLE.md')

ZERO_TYPES = ('Comment', 'Empty', 'Directive', 'Equivalence', 'Dum')
SIZED_TYPES = ('Code', 'Data')
DATA_MNEM = ('dfb', 'db', 'dw', 'da', 'dda', 'ddb', 'dd', 'asc', 'dci',
             'str', 'rev', 'hex')
PAD_COMMENT = re.compile(r'slack|align|pad|filler', re.I)
ROW_RE = re.compile(r'\s*(\d+) \|')
SYM_RE = re.compile(r'^\s*([A-Za-z0-9_]+)\s*=\s*\$([0-9A-Fa-f]+)\s*$')
SEGMENTS = (('flat', None), ('kseg', 'KSEG_LOW'), ('lseg', 'LSEG_LOW'))
KINDS = ('code', 'data', 'storage', 'pad')

# sec 1.3 of docs/ARCH-REVIEW-MEMORY.md, as patterns on the module's
# basename.  First match wins.  A module under src/test is `harness`;
# a kernel module that matches nothing is `other kernel`, and the
# rollup says so rather than hiding it.
FAMILIES = (
    ('console', ('tty*.s', 'ultraterm*.s')),
    ('files', ('procfile*.s', 'procfd*.s', 'procmli*.s', 'vroot.s',
               'procdev.s')),
    ('process', ('process*.s', 'procspawn*.s', 'spawn*.s', 'sched*.s',
                 'lazyfree.s', 'procfork.s')),
    ('entry', ('entry*.s', 'bankcopy.s', 'timer.s', 'ser.s',
               'procsig*.s', 'procbye.s')),
    ('small', ('ffpage.s', 'kdisp.s', 'mouse.s')),
)
FAMILY_TEXT = {
    'console': 'tty*.s, ultraterm*.s',
    'files': 'procfile*, procfd*, procmli*, vroot, procdev',
    'process': 'process*, procspawn*, spawn*, sched*, lazyfree, procfork',
    'entry': 'entry*, bankcopy, timer, ser, procsig*, procbye',
    'harness': 'src/test/*',
    'small': 'ffpage, kdisp, mouse',
    'other kernel': 'every other src/kernel module',
}
FAMILY_ORDER = ('console', 'files', 'process', 'entry', 'harness',
                'small', 'other kernel')


class LedgerError(Exception):
    """One or more rows could not be placed; .problems names them."""

    def __init__(self, problems):
        Exception.__init__(self, '\n'.join(problems))
        self.problems = problems


class Row(object):
    __slots__ = ('seq', 'fileno', 'path', 'line', 'ltype', 'size', 'addr',
                 'obj', 'label', 'mnem', 'oper', 'comment')


def where(r):
    return '%s:%d (listing row %d, Line Type %s)' % (
        r.path, r.line, r.seq, r.ltype)


def parse_row(text):
    f = text.split('|', 7)
    if len(f) < 8:
        return None
    r = Row()
    r.seq = int(f[0])
    fl = f[1].split()
    r.fileno = int(fl[0])
    r.path = fl[1] if len(fl) > 2 else '?'
    r.line = int(fl[-1])
    r.ltype = f[2].strip()
    r.size = int(f[5].strip() or 0)
    left, _, right = f[6].partition(':')
    a = left.strip()
    r.addr = int(a.split('/')[-1], 16) if '/' in a else None
    r.obj = bytearray(int(x, 16) for x in right.split())
    src = f[7][1:]
    r.label = r.mnem = r.oper = r.comment = ''
    body = src
    if src[:1] not in (' ', '\t', '*', ';', ''):
        parts = src.split(None, 1)
        r.label = parts[0]
        body = parts[1] if len(parts) > 1 else ''
    body = body.strip()
    if body and body[0] not in ';*':
        mp = body.split(None, 1)
        r.mnem = mp[0].lower()
        r.oper = (mp[1] if len(mp) > 1 else '').split(';', 1)[0].strip()
    if ';' in body:
        r.comment = body.split(';', 1)[1].strip()
    return r


def read_listing(path):
    """-> (rows, symbols).  Raises LedgerError on a malformed listing."""
    rows, syms, problems = [], {}, []
    cur = None
    with open(path, encoding='ascii', errors='replace') as fh:
        for text in fh:
            text = text.rstrip('\n')
            if ROW_RE.match(text):
                cur = parse_row(text)
                if cur is None:
                    problems.append('unparseable listing line: %r' %
                                    text[:80])
                else:
                    rows.append(cur)
            elif text.startswith('      |') and cur is not None:
                f = text.split('|')
                if len(f) >= 7:
                    cur.obj.extend(int(x, 16) for x in f[6].split())
            else:
                m = SYM_RE.match(text)
                if m:
                    syms[m.group(1)] = int(m.group(2), 16)
                    cur = None
    if problems or not rows:
        raise LedgerError(problems or ['%s: no listing rows' % path])
    return rows, syms


def is_global(label):
    return bool(label) and not label.startswith(('_', ':', ']')) \
        and not label.startswith('ozunid_')


def classify(r):
    """kind for a sized, non-Dum row, or None (caller reports it)."""
    if r.ltype == 'Code':
        return 'code'
    if r.ltype == 'Data':
        if r.mnem in DATA_MNEM:
            return 'data'
        if r.mnem == 'ds':
            if 'ozunid_' in r.oper or PAD_COMMENT.search(r.comment):
                return 'pad'
            return 'storage'
    return None


class Ledger(object):
    """Buckets, in listing order: (seg, module, label, kind) ->
    [first address, bytes, runs] where runs is the list of contiguous
    [address, length] extents the bucket occupies (a label's code and
    data can interleave, so a bucket need not be one extent)."""

    def __init__(self, name, modules, buckets, seglen, emitted, problems,
                 rowcount):
        self.name = name
        self.modules = modules
        self.buckets = buckets
        self.seglen = seglen
        self.emitted = emitted
        self.problems = problems
        self.rowcount = rowcount

    def total(self, seg=None):
        return sum(v[1] for k, v in self.buckets.items()
                   if seg is None or k[0] == seg)

    def sums(self, index, seg=None):
        out = collections.OrderedDict()
        for k, v in self.buckets.items():
            if seg is None or k[0] == seg:
                out[k[index]] = out.get(k[index], 0) + v[1]
        return out

    def by_family(self, seg=None):
        out = collections.OrderedDict((f, 0) for f in FAMILY_ORDER)
        for k, v in self.buckets.items():
            if seg is None or k[0] == seg:
                out[family(k[1])] += v[1]
        return out


def family(module):
    base = os.path.basename(module)
    for name, pats in FAMILIES:
        if any(fnmatch.fnmatch(base, p) for p in pats):
            return name
    if '/test/' in '/' + module:
        return 'harness'
    return 'other kernel'


def module_resolver(rows, root):
    """Listed paths are relative to the manifest's directory.  Find the
    manifest (file #1) under src/ and re-root every path at the repo."""
    first = next((r.path for r in rows if r.fileno == 1), None)
    mdir = ''
    if first:
        hits = []
        for d, _, fs in os.walk(os.path.join(root, 'src')):
            if os.path.basename(first) in fs:
                hits.append(os.path.relpath(d, root))
        if len(hits) == 1:
            mdir = hits[0]
    cache = {}

    def res(p):
        if p not in cache:
            cache[p] = os.path.normpath(os.path.join(mdir, p)) \
                .replace(os.sep, '/')
        return cache[p]
    return res


def build_ledger(listing, root=ROOT):
    rows, syms = read_listing(listing)
    name = os.path.basename(listing)
    if name.endswith('_Output.txt'):
        name = name[:-len('_Output.txt')]
    res = module_resolver(rows, root)
    problems = []
    buckets = collections.OrderedDict()
    last = {}                       # fileno -> last global label
    seg, offset, emitted = 'flat', 0, bytearray()
    starts = {}                     # seg -> byte offset of its first byte
    order = [s for s, _ in SEGMENTS]
    for r in rows:
        for s, lab in SEGMENTS[1:]:
            if r.label == lab and s not in starts:
                starts[s] = offset
                seg = s
        if r.ltype not in ZERO_TYPES and r.ltype not in SIZED_TYPES:
            problems.append('unknown Line Type: ' + where(r))
            continue
        if r.size != len(r.obj):
            problems.append('Size %d but %d object bytes printed: %s' %
                            (r.size, len(r.obj), where(r)))
        if r.ltype == 'Dum':
            continue        # address bookkeeping: emits nothing
        if r.ltype in ('Code', 'Data', 'Empty') and is_global(r.label):
            last[r.fileno] = r.label
        if r.ltype in ZERO_TYPES:
            if r.size:
                problems.append('sized %s row: %s' % (r.ltype, where(r)))
            continue
        kind = classify(r)
        if kind is None:
            problems.append('cannot classify (mnemonic %r): %s' %
                            (r.mnem, where(r)))
            continue
        if r.size == 0:
            continue
        key = (seg, res(r.path), last.get(r.fileno, '(file head)'), kind)
        a = r.addr if r.addr is not None else 0
        b = buckets.get(key)
        if b is None:
            buckets[key] = [a, r.size, [[a, r.size]]]
        else:
            b[1] += r.size
            run = b[2][-1]
            if run[0] + run[1] == a:
                run[1] += r.size        # contiguous with the last run
            else:
                b[2].append([a, r.size])
        emitted.extend(r.obj)
        offset += r.size
    seglen = {}
    bounds = [(s, starts.get(s)) for s in order if s == 'flat'
              or s in starts]
    bounds[0] = ('flat', 0)
    for i, (s, st) in enumerate(bounds):
        en = bounds[i + 1][1] if i + 1 < len(bounds) else offset
        seglen[s] = en - st
    modules = sorted(set(k[1] for k in buckets))
    led = Ledger(name, modules, buckets, seglen, bytes(emitted), problems,
                 len(rows))
    led.syms = syms
    led.starts = starts
    return led


def ceil256(n):
    return (n + 255) // 256 * 256


def verify(led, build=BUILD):
    """Problems (list of str) against the files on disk; [] = exhaustive."""
    p = list(led.problems)
    base = os.path.join(build, led.name)           # .../X.SYSTEM
    stem = base[:-len('.SYSTEM')] if base.endswith('.SYSTEM') else base
    files = [('flat', base)]
    files += [(s, '%s_%s' % (stem, s.upper())) for s in ('kseg', 'lseg')
              if s in led.seglen]
    pos = 0
    attributed = sum(v[1] for v in led.buckets.values())
    if attributed != len(led.emitted):
        p.append('buckets sum %d != emitted %d' % (attributed,
                                                   len(led.emitted)))
    for seg, path in files:
        n = led.seglen[seg]
        if not os.path.exists(path):
            p.append('%s: missing (needed for the %s section)' %
                     (path, seg))
            pos += n
            continue
        with open(path, 'rb') as fh:
            disk = fh.read()
        want = n if seg == 'flat' else ceil256(n)
        if len(disk) != want:
            p.append('%s: %d bytes on disk, ledger attributes %d%s' % (
                os.path.basename(path), len(disk), want,
                '' if seg == 'flat' else ' (256-padded)'))
        mine = led.emitted[pos:pos + n]
        if disk[:n] != mine:
            at = next((i for i in range(min(len(mine), len(disk)))
                       if mine[i] != disk[i]), min(len(mine), len(disk)))
            p.append('%s: listing bytes differ from the file at offset '
                     '%d (listing is stale or not this image\'s)' % (
                         os.path.basename(path), at))
        if seg != 'flat' and any(disk[n:]):
            p.append('%s: nonzero bytes in the padding' %
                     os.path.basename(path))
        pos += n
    if 'kseg' in led.starts:
        org = None
        first = next((v[0] for k, v in led.buckets.items()
                      if k[0] == 'flat'), None)
        org = first
        low = led.syms.get('KSEG_LOW')
        if org is None or low is None or low - org != led.seglen['flat']:
            p.append('KSEG_LOW $%s - org $%s != flat length %d' % (
                '%04X' % low if low is not None else '?',
                '%04X' % org if org is not None else '?',
                led.seglen['flat']))
    return p


# ------------------------------------------------------- storage roster

READ_OPS = ('lda', 'ldx', 'ldy', 'cmp', 'cpx', 'cpy', 'adc', 'sbc',
            'and', 'ora', 'eor', 'bit')
WRITE_OPS = ('sta', 'stx', 'sty', 'stz')
RMW_OPS = ('inc', 'dec', 'asl', 'lsr', 'rol', 'ror', 'tsb', 'trb')
WORD_RE = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
ROSTER_DIRS = ('src', 'inc', 'scripts')


def source_files(root=ROOT):
    for d in ROSTER_DIRS:
        for dp, _, fs in os.walk(os.path.join(root, d)):
            for f in sorted(fs):
                if f.endswith(('.s', '.equ', '.py')):
                    yield os.path.join(dp, f)


def ref_kind(line, label):
    """R / W / M (read-modify-write) / A (address taken: an immediate,
    or a data word) / O (anything else) for one source line naming
    `label`.  Comment-only lines are skipped by the caller."""
    body = line.split(';', 1)[0]
    toks = body.split()
    if not toks:
        return None
    i = 0 if body[:1] in (' ', '\t') else 1
    mn = toks[i].lower() if i < len(toks) else ''
    op = ' '.join(toks[i + 1:])
    if label not in WORD_RE.findall(op):
        return 'O'
    if op.startswith('#'):
        return 'A'
    if mn in READ_OPS or (mn in ('jmp', 'jsr') and '(' in op):
        return 'R'              # jmp (CELL) / jsr (CELL,x) load the cell
    if mn in WRITE_OPS:
        return 'W'
    if mn in RMW_OPS:
        return 'M'
    if mn in ('da', 'dw', 'dda', 'ddb', 'dfb', 'db'):
        return 'A'
    return 'O'


def storage_roster(led, root=ROOT):
    """Every storage (`ds`) bucket in the image with the grep roster of
    who touches it.  -> list of dicts, listing order."""
    words = {}
    texts = {}
    for path in source_files(root):
        with open(path, encoding='ascii', errors='replace') as fh:
            lines = fh.read().split('\n')
        texts[path] = lines
        seen = set()
        for ln in lines:
            if ln[:1] in ('*', ';'):
                continue
            seen.update(WORD_RE.findall(ln.split(';', 1)[0]))
        for w in seen:
            words.setdefault(w, []).append(path)
    out = []
    for (seg, mod, lab, kind), v in led.buckets.items():
        if kind != 'storage':
            continue
        refs = collections.OrderedDict()
        for path in words.get(lab, ()):
            rel = os.path.relpath(path, root).replace(os.sep, '/')
            for n, ln in enumerate(texts[path], 1):
                if ln[:1] in ('*', ';') or lab not in ln:
                    continue
                if lab not in WORD_RE.findall(ln.split(';', 1)[0]):
                    continue
                k = ref_kind(ln, lab)
                if k is None:
                    continue
                if ln.split(None, 1)[0] == lab and k == 'O' \
                        and ' ds ' in ' ' + ln.lower().split(';')[0] + ' ':
                    k = 'D'                 # its own definition
                refs.setdefault(rel, collections.Counter())[k] += 1
        out.append({'seg': seg, 'module': mod, 'label': lab,
                    'size': v[1], 'addr': v[0], 'refs': refs})
    return out


def fmt_roster(rows):
    o = ['| addr | bytes | label | module | R | W | M | A | readers '
         '(file:count) | note |', '|---|---:|---|---|---:|---:|---:|---:|'
         '---|---|']
    for r in rows:
        c = collections.Counter()
        readers = []
        for f, k in r['refs'].items():
            c.update(k)
            if k['R'] or k['M'] or k['A']:
                readers.append('%s:%d' % (os.path.basename(f),
                                          k['R'] + k['M'] + k['A']))
        note = []
        if not (c['R'] or c['M']):
            note.append('never loaded' if not c['A'] else
                        'address taken only')
        if not (c['W'] or c['M']):
            note.append('never stored' + (' (zero-init)'
                                           if not c['A'] else ''))
        o.append('| $%04X | %d | %s | %s | %d | %d | %d | %d | %s | %s |' % (
            r['addr'], r['size'], r['label'],
            os.path.basename(r['module']), c['R'], c['W'], c['M'],
            c['A'], ' '.join(readers[:6]) + (' ...' if len(readers) > 6
                                             else ''),
            ', '.join(note)))
    return '\n'.join(o) + '\n'


# ---------------------------------------------------------------- output

def fmt_table(led, addr=False):
    """The committed ledger (docs/KLEDGER-TABLE.md).  Deterministic: no
    clock, no host path.  The committed form has NO address column: a
    byte-neutral 5 B shuffle between two modules rewrote 405 of its
    ~1,207 lines when it had one (docs/KLEDGER-NOTES.md 2.5), and the
    gate guards sizes, modules, labels and kinds.  addr=True (`--table
    --addresses`) prints the first address of each bucket."""
    o = []
    w = o.append
    w('# KLEDGER-TABLE -- the per-label ledger of %s' % led.name)
    w('')
    w('GENERATED by `make kledger` (scripts/kledger.py).  Do not edit: '
      '`make check-kledger` regenerates it and fails on any difference.')
    w('A kernel change regenerates it with one command and the diff '
      'rides in the commit.')
    w('')
    w('Source: build/%s_Output.txt (merlin32 -v1), %d listing rows.  '
      'Every emitted byte is attributed; the sums below equal the files '
      'on disk (scripts/kledger.py header: the exhaustiveness contract).'
      % (led.name, led.rowcount))
    w('')
    w('## Sections')
    w('')
    w('| section | bytes | on disk |')
    w('|---|---:|---|')
    for s in led.seglen:
        n = led.seglen[s]
        disk = ('%s' % led.name if s == 'flat'
                else '%s_%s (%d B, 256-padded)' % (
                    led.name[:-len('.SYSTEM')], s.upper(), ceil256(n)))
        w('| %s | %d | %s |' % (s, n, disk))
    w('| total | %d | |' % led.total())
    w('')
    for seg in led.seglen:
        w('## Section %s: %d B' % (seg, led.seglen[seg]))
        w('')
        w('### by kind')
        w('')
        w('| kind | bytes | share |')
        w('|---|---:|---:|')
        kinds = led.sums(3, seg)
        for k in KINDS:
            n = kinds.get(k, 0)
            w('| %s | %d | %.1f%% |' % (k, n, 100.0 * n /
                                          max(1, led.seglen[seg])))
        w('')
        w('### by family (docs/ARCH-REVIEW-MEMORY.md sec 1.3)')
        w('')
        w('| family | members | bytes | share |')
        w('|---|---|---:|---:|')
        for f, n in led.by_family(seg).items():
            if n:
                w('| %s | %s | %d | %.1f%% |' % (
                    f, FAMILY_TEXT[f], n, 100.0 * n /
                    max(1, led.seglen[seg])))
        w('')
        w('### by module')
        w('')
        w('| module | bytes | code | data | storage | pad |')
        w('|---|---:|---:|---:|---:|---:|')
        mk = collections.OrderedDict()
        for (s, m, lab, kind), v in led.buckets.items():
            if s == seg:
                d = mk.setdefault(m, dict.fromkeys(KINDS, 0))
                d[kind] += v[1]
        for m, d in sorted(mk.items(), key=lambda t: (-sum(t[1].values()),
                                                      t[0])):
            w('| %s | %d | %d | %d | %d | %d |' % (
                m, sum(d.values()), d['code'], d['data'], d['storage'],
                d['pad']))
        w('')
        w('### by label (listing order)')
        w('')
        w(('| addr ' if addr else '') + '| bytes | module | label | kind |')
        w(('|---' if addr else '') + '|---:|---|---|---|')
        for (s, m, lab, kind), v in led.buckets.items():
            if s == seg:
                w(('| $%04X ' % v[0] if addr else '') +
                  '| %d | %s | %s | %s |' % (v[1], m, lab, kind))
        w('')
    text = '\n'.join(o) + '\n'
    return text


def listing_path(image, build=BUILD):
    n = image if image.endswith('.SYSTEM') else image + '.SYSTEM'
    return os.path.join(build, n + '_Output.txt')


def all_images(build=BUILD):
    return sorted(os.path.basename(p)[:-len('_Output.txt')] for p in
                  [os.path.join(build, f) for f in os.listdir(build)
                   if f.endswith('.SYSTEM_Output.txt')])


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--image', default='MAUXPLAY',
                    help='image basename (default MAUXPLAY)')
    ap.add_argument('--build', default=BUILD)
    ap.add_argument('--all', action='store_true',
                    help='verify every listing in the build dir (M1)')
    ap.add_argument('--table', action='store_true',
                    help='print the full markdown ledger')
    ap.add_argument('--addresses', action='store_true',
                    help='with --table: add the address column (the '
                         'committed table has none)')
    ap.add_argument('--write', metavar='PATH',
                    help='write the markdown ledger to PATH')
    ap.add_argument('--top', type=int, metavar='N',
                    help='the N largest labels')
    ap.add_argument('--storage', action='store_true',
                    help='the storage roster: every ds cell, with who '
                         'reads and writes it (by grep)')
    args = ap.parse_args(argv)
    names = all_images(args.build) if args.all else [args.image]
    bad = 0
    for img in names:
        path = listing_path(img, args.build) if not args.all else \
            os.path.join(args.build, img + '_Output.txt')
        try:
            led = build_ledger(path)
            probs = verify(led, args.build)
        except LedgerError as e:
            led, probs = None, e.problems
        except OSError as e:
            led, probs = None, [str(e)]
        if probs:
            bad += 1
            print('%s: FAIL' % img)
            for x in probs[:20]:
                print('  ' + x)
            if len(probs) > 20:
                print('  ... %d more' % (len(probs) - 20))
            continue
        segs = ' '.join('%s=%d' % (s, n) for s, n in led.seglen.items())
        print('%s: exhaustive, %d B (%s), %d buckets' % (
            led.name, led.total(), segs, len(led.buckets)))
        if args.write and not args.all:
            with open(args.write, 'w', encoding='ascii') as fh:
                fh.write(fmt_table(led))
            print('wrote ' + args.write)
        if args.table and not args.all:
            sys.stdout.write(fmt_table(led, addr=args.addresses))
        if args.storage and not args.all:
            rows = storage_roster(led)
            sys.stdout.write(fmt_roster(sorted(
                rows, key=lambda r: (-r['size'], r['label']))))
        if args.top and not args.all:
            agg = collections.Counter()
            for (s, m, lab, kind), v in led.buckets.items():
                agg[(s, m, lab)] += v[1]
            for (s, m, lab), n in agg.most_common(args.top):
                print('%6d  %-5s %-28s %s' % (n, s, m, lab))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
