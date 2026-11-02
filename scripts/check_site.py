#!/usr/bin/env python3
"""check-site: build the site, then hold the output and the sources to account.

    make check-site

Fails on: a build error (a placeholder with no fact, a fact whose source is
missing, a page naming a demo with no file in site/demos, a repo: link to a
file the repository does not track, an unknown placeholder); a broken
internal link or fragment in the OUTPUT (href/src/poster to something not in
build/site/); a root-absolute link (the site is served from a sub-path); a
non-ASCII byte in any site/ source; a link to cornflower.au (the LAN-only
Forgejo) from source or output; an unexpanded {{...}} or [[...]]; a
`<!-- src: ... -->` comment naming a file that is not in the tree; a page
with paragraphs and no src comment; a lesson page (under learn/) whose
lesson has no check-examples row, no `row_<id>` function, or no session file
(build/examples/<id>/session.txt, written by a passing `make check-examples`
and nothing else) or whose session records another build/full.po than the
current one ("stale session"),
that has no `lesson:` header, or that includes a file that is not in
examples/; a film the site would publish (both displays when --ut) whose mp4 frame size or
poster size is not the one the recorder declares (scripts/demo_stamp.py reads
it from demo_overlay) or not the same as every other film's; a film with no
NAME.stamp.json, or whose stamp's sha256 of the demo script, the disk image or
a recorder source file is not the file's hash now (docs/RECORDER.md "Freshness
stamps and film sizes"; hashes, never mtimes);
and (full builds) a roster command with no man page, a stub page
without its badge, or a licences page without the required notices.

The self-test plants each defect in a scratch copy of site/ and requires the
check to go red on it (pattern: scripts/check_man.py self_test).
"""
import argparse
import html
import importlib.util
import json
import re
import os
import shutil
import struct
import subprocess
import sys
import tempfile
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
import demo_phos                                             # noqa: E402
import demo_stamp                                            # noqa: E402

#: the monitor a page shows before anyone picks one
DEF_PH = demo_phos.DEFAULT


def load_build(site):
    spec = importlib.util.spec_from_file_location('maux_site_build', Path(site) / 'build.py')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Scan(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []     # (attr, value)
        self.ids = set()
        self.paras = 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        for k in ('href', 'src', 'poster'):
            if a.get(k) is not None:
                self.links.append((tag, k, a[k]))
        if a.get('srcset'):
            for cand in a['srcset'].split(','):
                if cand.strip():
                    self.links.append((tag, 'srcset', cand.split()[0]))
        if a.get('id'):
            self.ids.add(a['id'])
        if a.get('name'):
            self.ids.add(a['name'])
        if tag == 'p':
            self.paras += 1


def source_files(site):
    for p in sorted(Path(site).rglob('*')):
        if p.is_file() and '__pycache__' not in p.parts:
            yield p


def source_errors(root, site):
    errs = []
    for p in source_files(site):
        data = p.read_bytes()
        bad = [i for i, c in enumerate(data) if c >= 128]
        rel = p.relative_to(site)
        if bad:
            errs.append('%s: non-ASCII byte at line %d' % (rel, data[:bad[0]].count(b'\n') + 1))
        text = data.decode('ascii', 'replace')
        if re.search(r'cornflower\.au', text, re.I):
            errs.append('%s: names cornflower.au (the LAN-only Forgejo)' % rel)
        if p.suffix == '.html' and 'pages' in p.parts:
            srcs = re.findall(r'<!--\s*src:(.*?)-->', text, re.S)
            body = text.split('\n---\n', 1)[-1]
            if '<p' in body and not srcs:
                errs.append('%s: has paragraphs and no <!-- src: --> comment' % rel)
            for s in srcs:
                for item in s.split(';'):
                    words = item.split()
                    w = words[0].rstrip(',.') if words else ''
                    if '/' in w and ':' not in w and not (root / w).exists() \
                            and not (root / w.rstrip('/')).exists():
                        errs.append('%s: src comment names %s, which is not in the tree' % (rel, w))
                for tok in re.findall(r'(?<![\w/.-])((?:[\w.-]+/)*[\w.-]+\.(?:md|py|log|s|equ|txt|json|html|svg)|Makefile)\b', s):
                    if not (root / tok).exists():
                        errs.append('%s: src comment names %s, which is not in the tree' % (rel, tok))
    errs += conformance_source_errors(root, site)
    return errs


NUMWORDS = set('''two three four five six seven eight nine ten eleven twelve
thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty
forty fifty sixty seventy eighty ninety hundred thousand million dozen
zero'''.split())


def bare_numbers(text):
    """Numbers typed into prose: digit tokens and number words, after
    dropping comments, {{placeholders}} (a fact is how a number gets in),
    tags and entities. A digit token right after "Version" is a version
    name (Version 7 Unix), not a count."""
    text = re.sub(r'<!--.*?-->', ' ', text, flags=re.S)
    text = re.sub(r'\{\{.*?\}\}', ' ', text)
    text = re.sub(r'<[^>]+>', ' ', text)
    text = re.sub(r'&#?\w+;', ' ', text)
    found, prev = [], ''
    for tok in text.split():
        t = tok.strip('(),.;:!?"\'')
        if re.fullmatch(r'\d[\d,.]*', t) and prev.lower() != 'version':
            found.append(t)
        elif any(w in NUMWORDS for w in t.lower().split('-')):
            found.append(t)
        prev = t
    return found


def conformance_source_errors(root, site):
    """The Conformance page and its table rows print no number that is
    not a {{fact:...}}: a hand-typed count goes stale the day a gate moves."""
    errs = []
    page = Path(site) / 'pages' / 'conformance.html'
    if page.is_file():
        body = page.read_text().split('\n---\n', 1)[-1]
        for n in bare_numbers(body):
            errs.append('conformance.html: hand-typed number %r (use a fact)' % n)
    cpath = Path(site) / 'conformance.py'
    if cpath.is_file():
        spec = importlib.util.spec_from_file_location('conf_rows_chk', cpath)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        for row in mod.ROWS:
            for cell in row[:5]:
                for n in bare_numbers(cell):
                    errs.append('conformance.py: row %r has a hand-typed '
                                'number %r (use a fact)' % (row[0], n))
    return errs


# What a visitor must never see, not even in view-source: the project's
# internal knowledge base (its handles, its name) and any HTML comment.
LEAKS = (
    ('an HTML comment', re.compile(r'<!--')),
    ('a learning: handle', re.compile(r'learning:')),
    ('a ULID-shaped token',
     re.compile(r'(?<![0-9A-Za-z])[0-9A-HJKMNP-TV-Z]{26}(?![0-9A-Za-z])')),
    ('the words commons / street-library',
     re.compile(r'commons|street-library', re.I)),
    ('the operator (internal process)', re.compile(r'\bthe operator\b(?!s)', re.I)),
    ('a notes-file name',
     re.compile(r'\b[A-Z0-9]+(?:-[A-Z0-9]+)*-NOTES\b')),
    ('a rulings reference', re.compile(r'\bRULINGS-\d')),
    ('a KFIX brief name', re.compile(r'\bKFIX\d*\b')),
    ('a confidence tag',
     re.compile(r'\[(?:fact|likely|reported|observed)\b')),
)


def brief_names(root=ROOT):
    """The project's internal brief names: every ALL-CAPS-HYPHEN stem of
    a docs/*.md file (UT-CELL, SH-ROOM, SH-DEFECTS-2026-10-20 ...), with
    its notes/date suffixes dropped as well. A name with a docs file is an
    internal brief, so a page that spells it leaks process; derived from
    the docs directory rather than listed by hand."""
    names = set()
    for p in Path(root, 'docs').glob('*.md'):
        st = p.stem
        if not re.fullmatch(r'[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)+', st):
            continue
        names.add(st)
        base = re.sub(r'(?:-\d+)+$', '', st)
        base = re.sub(r'-NOTES$', '', base)
        if '-' in base:
            names.add(base)
    return names


def brief_rule(root=ROOT):
    names = sorted(brief_names(root), key=len, reverse=True)
    return ('an internal brief name',
            re.compile(r'(?<![A-Za-z0-9-])(?:%s)(?![A-Za-z0-9-])'
                       % '|'.join(re.escape(n) for n in names)))


# A page may POINT at a design document of the public repository: a
# `docs/NAME.md` path, or a link to one whose text is NAME. That is a
# citation a reader can follow, not process talk, so it is blanked before
# the brief-name scan (same length, so line numbers hold). A bare NAME
# anywhere else ("after SH-ROOM landed") still leaks; a notes file, KFIX
# or RULINGS name leaks wherever it is, as the other rules say.
CITED_DOC = re.compile(r'docs/[A-Z0-9][A-Z0-9-]*\.md')
CITED_LINK = re.compile(r'(<a [^>]*docs/([A-Z0-9-]+)\.md[^>]*>)\2(</a>)')


def blank_citations(text):
    text = CITED_LINK.sub(lambda m: m.group(1) + ' ' * len(m.group(2))
                          + m.group(3), text)
    return CITED_DOC.sub(lambda m: ' ' * len(m.group(0)), text)
LEAK_SUFFIXES = ('.html', '.svg', '.vtt', '.txt', '.css', '.js')


def leak_errors(out):
    errs = []
    out = Path(out)
    for f in sorted(out.rglob('*')):
        if not f.is_file() or f.suffix not in LEAK_SUFFIXES:
            continue
        text = f.read_bytes().decode('latin-1')
        for what, rx in LEAKS + (brief_rule(),):
            m = rx.search(blank_citations(text)
                          if what == 'an internal brief name' else text)
            if m:
                errs.append('%s: leaks %s (line %d): %s' % (
                    f.relative_to(out), what, text[:m.start()].count('\n') + 1,
                    text[max(0, m.start() - 20):m.end() + 20].replace('\n', ' ')))
    return errs


def matching_count_errors(page, src, gaps):
    """"Cases matching" must mean cases that AGREED with the reference.
    The gate's per-tool tally counts a known gap as a pass (it passes while
    the tool still differs from the host), so the figure the page prints
    for a tool is the gate's tally minus that tool's gaps. Parsed here
    again from the log, independently of site/facts.py."""
    errs = []
    blk = re.search(r'per-tool tallies:\n((?:  \w+: \d+/\d+\n)+)', src)
    if not blk:
        return ['conformance: no per-tool tallies in the source run']
    owed = {}
    for tool, _name in gaps:
        owed[tool] = owed.get(tool, 0) + 1
    want = {}
    for m in re.finditer(r'  (\w+): (\d+)/(\d+)', blk.group(1)):
        want[m.group(1)] = (int(m.group(2)) - owed.get(m.group(1), 0),
                            int(m.group(3)))
    for tool in owed:
        if tool not in want:
            errs.append('conformance: a gap is listed for %s, which has no tally' % tool)
    m = re.search(r'<ul class="tallies">(.*?)</ul>', page, re.S)
    got = {}
    for tool, a, b in re.findall(r'<li><code>(\w+)</code> ([\d,]+) of ([\d,]+)',
                                 m.group(1) if m else ''):
        got[tool] = (int(a.replace(',', '')), int(b.replace(',', '')))
    if got != want:
        for tool in sorted(set(want) | set(got)):
            if want.get(tool) != got.get(tool):
                errs.append('conformance: %s is shown as %s matching; the run has '
                            '%s once its known gaps are taken out'
                            % (tool, got.get(tool), want.get(tool)))
    # the table cell of a tool with a gap says the same
    for tool in owed:
        row = re.search(r'<code>%s</code></th>.*?</tr>' % re.escape(tool), page, re.S)
        if row and tool in want:
            a, b = want[tool]
            if not re.search(r'>%d of %d<' % (a, b), row.group(0)):
                errs.append('conformance: the %s table row does not say %d of %d'
                            % (tool, a, b))
    total = sum(a for a, _b in want.values())
    if not re.search(r'\b%s of the %s tests on the standard utilities gave'
                     % (format(total, ','), format(sum(b for _a, b in want.values()), ',')),
                     re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', '', page))):
        errs.append('conformance: the page does not state %d agreeing utility tests'
                    % total)
    return errs


def conformance_output_errors(out, root=ROOT):
    """No Proof page or nav entry, nothing links to it, and the Conformance
    page lists exactly the gaps its source run reported (parsed here again,
    independently of site/facts.py)."""
    errs = []
    out = Path(out)
    if (out / 'proof').exists():
        errs.append('proof/: the Proof page was removed and must not be built')
    for f in sorted(out.rglob('index.html')):
        t = f.read_text()
        here = f.relative_to(out)
        if re.search(r'<a [^>]*>\s*Proof\s*</a>', t):
            errs.append('%s: has a Proof entry' % here)
        if re.search(r'href="[^"]*(?:^|/)proof/?(?:index\.html)?(?:#[^"]*)?"', t):
            errs.append('%s: links to the removed Proof page' % here)
    page = out / 'conformance' / 'index.html'
    if not page.is_file():
        return errs + ['conformance/: the Conformance page was not built']
    t = page.read_text()
    log = Path(root) / 'evidence'
    logs = sorted(log.glob('conformance-*/check-posixutil.log'))
    if not logs:
        return errs + ['conformance: no archived check-posixutil.log']
    src = logs[-1].read_text()
    blk = re.search(r'\[check-posixutil\] KNOWN_GAPS:\n((?:  .*\n)+)', src)
    want = []
    for ln in (blk.group(1).split('\n') if blk else []):
        m = re.match(r'  (\w+)/(\S+) ', ln)
        if m:
            want.append((m.group(1), m.group(2)))
    m = re.search(r'<h3>Utilities</h3>\s*<ul class="gaps">(.*?)</ul>', t, re.S)
    got = [html.unescape(g) for g in re.findall(r'<li><code>([^<]*)</code>', m.group(1))] if m else []
    if not want or len(got) != len(want):
        errs.append('conformance: the gaps list has %d entries, its source run '
                    'reported %d' % (len(got), len(want)))
    else:
        for (tool, name), g in zip(want, got):
            ok = len(g.split()) >= 2 and g.split()[0] == tool and (re.fullmatch(r'[A-Za-z0-9]+', name)
                                           or g.endswith(name))
            if not ok:
                errs.append('conformance: gap %s/%s is shown as %r' % (tool, name, g))
    for m in re.finditer(r'<ul class="gaps">(.*?)</ul>', t, re.S):
        for li in re.findall(r'<li>(.*?)</li>', m.group(1), re.S):
            text = html.unescape(re.sub(r'<[^>]+>', '', li)).strip()
            rest = re.sub(r'^<code>[^<]*</code>', '', li).strip()
            if re.match(r'[^\w(]', html.unescape(rest)[:1] or 'x'):
                errs.append('conformance: a gap row has punctuation where its '
                            'sentence should begin: %r' % text[:50])
    errs += matching_count_errors(t, src, want)
    e2e = sorted(log.glob('conformance-*/check-e2e.log'))
    if e2e:
        defects = re.findall(r'^\[check-e2e\] KNOWN DEFECT sh: ', e2e[-1].read_text(), re.M)
        m = re.search(r'<h3>The shell</h3>\s*<ul class="gaps">(.*?)</ul>', t, re.S)
        n = len(re.findall(r'<li>', m.group(1))) if m else 0
        if n != len(defects):
            errs.append('conformance: the shell list has %d entries, its source run '
                        'reported %d' % (n, len(defects)))
    return errs


LOCALHOST = re.compile(r'^(https?:)?//(localhost|127\.0\.0\.1|\[::1\])([:/]|$)', re.I)


def output_errors(out, full, roster=None, local_ok=False):
    errs = leak_errors(out)
    out = Path(out)
    files = sorted(out.rglob('index.html'))
    if not files:
        return ['no pages were built in %s' % out]
    scans = {}
    for f in files:
        sc = Scan()
        sc.feed(f.read_text())
        scans[f] = sc
        text = f.read_text()
        if not str(f.relative_to(out)).startswith('man/') and re.search(r'\{\{|\[\[', text):
            errs.append('%s: unexpanded placeholder' % f.relative_to(out))
        if re.search(r'cornflower\.au', text, re.I):
            errs.append('%s: links to cornflower.au' % f.relative_to(out))
        # THE SOURCE IS REACHABLE FROM EVERY PAGE, man pages
        # included. The link lives in the chrome, so one page missing it
        # means the template lost it for all of them -- and the whole
        # point of an MIT project with a site is that a reader who wants
        # the code does not have to hunt for it.
        # class="src github-button": buttons.js keys on the second class,
        # so the first one may not be the whole attribute any more.
        m = re.search(r'<a class="src(?: [^"]*)?" href="([^"]*)"', text)
        if not m:
            errs.append('%s: the header has no source link (class="src")'
                        % f.relative_to(out))
        elif not re.match(r'https://[^/]+/[^/]', m.group(1)):
            errs.append('%s: source link is %r, not a repository URL'
                        % (f.relative_to(out), m.group(1)))
        elif '/blob/' in m.group(1) or '/tree/' in m.group(1):
            errs.append('%s: source link %r points INTO a tree; a reader '
                        'who wants the code wants the project'
                        % (f.relative_to(out), m.group(1)))
    errs += conformance_output_errors(out)
    if (out / 'support').exists():
        errs.append('support/: the Support page was removed and must not be built')
    for f, sc in scans.items():
        here = f.relative_to(out)
        for tag, attr, val in sc.links:
            if re.search(r'(^|/)support/?(index\.html)?(#.*)?$', val.split('?')[0]) and '.po' not in val:
                errs.append('%s: links to the removed Support page (%s)' % (here, val))
            if re.match(r'(https?:)?//', val):
                if LOCALHOST.match(val) and not local_ok:
                    errs.append('%s: %s=%s names localhost (use --local-preview for a local test build)' % (here, attr, val))
                if re.search(r'cornflower\.au|forgejo', val, re.I):
                    errs.append('%s: external link to %s' % (here, val))
                continue
            if re.match(r'(mailto:|data:|javascript:)', val):
                continue
            if val.startswith('/'):
                errs.append('%s: root-absolute %s=%s (site is served from a sub-path)' % (here, attr, val))
                continue
            path, _, frag = val.partition('#')
            path = path.split('?')[0]
            if path == '':
                target = f.resolve()
            else:
                target = (f.parent / path).resolve()
                if target.is_dir():
                    target = target / 'index.html'
            try:
                target.relative_to(out.resolve())
            except ValueError:
                errs.append('%s: link %s leaves the site' % (here, val))
                continue
            if not target.is_file():
                errs.append('%s: broken link %s=%s' % (here, attr, val))
                continue
            if frag and target.suffix == '.html':
                tscan = scans.get(target) or scans.get(Path(str(target)))
                if tscan is None:
                    t = Scan()
                    t.feed(target.read_text())
                    tscan = t
                if frag not in tscan.ids:
                    errs.append('%s: link %s has no anchor #%s' % (here, val, frag))
    for css in sorted(out.rglob('*.css')):
        for ref in re.findall(r'url\(\s*[\'"]?([^\'")]+)', css.read_text()):
            if re.match(r'(data:|https?:|//|#)', ref):
                if LOCALHOST.match(ref) and not local_ok:
                    errs.append('%s: css url(%s) names localhost' % (css.relative_to(out), ref))
                continue
            if ref.startswith('/'):
                errs.append('%s: root-absolute css url(%s)' % (css.relative_to(out), ref))
            elif not (css.parent / ref.split('#')[0].split('?')[0]).is_file():
                errs.append('%s: broken css url(%s)' % (css.relative_to(out), ref))
    if full and roster:
        for n in sorted(roster):
            if not (out / 'man' / n / 'index.html').is_file():
                errs.append('man: roster command %s has no page' % n)
        for f in sorted((out / 'man').glob('*/index.html')):
            t = f.read_text()
            if 'is not provided on maux' in t and 'badge stub' not in t:
                errs.append('man/%s: stub without its badge' % f.parent.name)
        lic = out / 'man/licenses/index.html'
        if lic.is_file():
            t = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', lic.read_text()))
            for must in ('Copyright(C) Caldera International Inc.',
                         'The Regents of the University of California'):
                if must not in t:
                    errs.append('man/licenses: required notice naming %s is missing' % must)
        else:
            errs.append('man/licenses: page missing')
    return errs


UT_SENTENCE = 'The Videx UltraTerm was an 80-column video card for the Apple IIe'
# the browser-boot button's label (site/build.py gen_tryit/gen_tryhome)
TRY_LABEL = 'Try now in your browser'
#: A card file is NAME-ut.vtt / transcript-ut.txt, or a film or poster
#: with the monitor after the display: NAME-ut-amber.mp4,
#: poster-ut-green.png (docs/DEMO-PHOSPHOR.md). Matching `-ut.` alone
#: stopped working the day the phosphor suffix landed, and the hole was
#: SILENT -- a UT=0 build full of card films would have passed.
UT_FILE_RE = re.compile(r'-ut(-(%s))?\.(mp4|webm|vtt|png|txt)$'
                        % '|'.join(demo_phos.NAMES))


def ut_off_errors(out):
    """Without --ut (the Makefile passes it: UT ?= 1) the output has
    nothing of the UltraTerm films: no -ut file on any monitor, no
    card data, no link to a card film, no sentence about the card.

    display.js and `data-display` are NOT forbidden any more. They were
    while the script did one job, the display selector; it now also
    drives the monitor selector, which a build without the card still
    wants -- UT=0 turns off the UltraTerm, not the three monitors."""
    errs = []
    for f in sorted(out.rglob('*')):
        if f.is_file() and UT_FILE_RE.search(f.name):
            errs.append('%s: an UltraTerm file in a build without --ut'
                        % f.relative_to(out))
    bad_marks = ['data-ut-', 'data-display-alt', UT_SENTENCE]
    for ph in demo_phos.NAMES:
        bad_marks += ['-ut-%s.mp4' % ph, '-ut-%s.webm' % ph]
    for f in sorted(out.rglob('index.html')):
        t = f.read_text()
        for bad in bad_marks:
            if bad in t:
                errs.append('%s: %r in a build without --ut'
                            % (f.relative_to(out), bad))
    return errs


def captions_errors(out, b):
    """The caption overlay (static/captions.js, style.css): the script is
    shipped, every page that plays a film with captions wraps the video in
    .film with the dim layer and the plate, loads the script, and the
    script and style carry the pieces the design needs."""
    errs = []
    out = Path(out)
    js = out / 'static' / 'captions.js'
    if not js.is_file():
        return ['static/captions.js is not in the output']
    src = js.read_text()
    for need in ('"hidden"', 'cuechange', 'addtrack', 'fullscreenchange',
                 'activeCues', 'is-narrating'):
        if need not in src:
            errs.append('static/captions.js lacks %s' % need)
    if 'aria-label", "Captions"' not in src:
        errs.append('static/captions.js: the Captions button is not in '
                    'its own labelled group')
    dj = out / 'static' / 'display.js'
    if dj.is_file() and 't.default = true' in dj.read_text():
        errs.append('static/display.js makes the swapped-in track '
                    'default: the browser then re-enables captions the '
                    'viewer turned off')
    css = (out / 'static' / 'style.css').read_text()
    for need in ('.film-plate', '.film-dim', '#c88a18', 'prefers-reduced-motion',
                 '@keyframes cap-in', '@keyframes cap-out', '36.9231%'):
        if need not in css:
            errs.append('static/style.css lacks %s' % need)
    pages = [out / 'watch' / n / 'index.html' for n in sorted(b.demos)]
    pages.append(out / 'index.html')
    for page in pages:
        if not page.is_file():
            continue
        t = page.read_text()
        if '<video' not in t or '<track' not in t:
            continue
        rel = page.relative_to(out)
        for need in ('<div class="film">', 'class="film-dim"',
                     'class="film-cap"', 'class="film-plate"',
                     'static/captions.js'):
            if need not in t:
                errs.append('%s: the player lacks %s' % (rel, need))
        m = re.search(r'<div class="film">(.*?)</video>', t, re.S)
        if not m or '<video' not in m.group(0):
            errs.append('%s: the <video> is not inside the .film wrapper'
                        % rel)
    node = shutil.which('node')
    if node:
        for f in (js, out / 'static' / 'display.js'):
            if f.is_file():
                r = subprocess.run([node, '--check', str(f)],
                                   capture_output=True, text=True)
                if r.returncode:
                    errs.append('%s: not valid JavaScript: %s'
                                % (f.name, r.stderr.strip()[:200]))
    return errs


def tryemu_errors(out, b):
    """The emulator in the page (site/build.py gen_tryemu,
    static/tryemu.js, style.css .emu): when the build has a public image
    to boot, /try/ carries the facade -- one .emu block whose link IS the
    configured emulator, every card setting in its query -- plus the
    script that turns the click into a frame. When it does not, /try/
    carries no boot link at all and says why, because a button that
    cannot work is worse than a sentence.

    The configuration is asserted item by item on purpose. A boot URL
    that has lost `capslock=off` still boots; it just lands the reader on
    a machine that types in capitals, and nothing but this would notice.
    """
    errs = []
    out = Path(out)
    page = out / 'try' / 'index.html'
    if not page.is_file():
        return ['try/: the Try page was not built']
    t = page.read_text()
    # Whether there is anything to boot, derived the way the builder
    # derives it (site/build.py tryit_href) and not by asking the
    # builder again: a second call would move its state after the build
    # had already been checked.
    image, base = b.a.image_url, b.a.apple2ts_url
    local = bool(b.LOCAL.search(image) or b.LOCAL.search(base))
    bootable = (re.match(r'https?://', image) is not None
                and (not local or b.a.local_preview))
    if not bootable:
        for bad in ('class="emu"', 'emustart', 'tryemu.js', 'hd1='):
            if bad in t:
                errs.append('try/: carries %s with no public image to boot' % bad)
        if not local and 'goes live with the release' not in t:
            errs.append('try/: no public image, and no sentence saying so')
        return errs
    for need in ('<figure class="hero">', '<div class="film emu" data-frame-src=',
                 'class="emustart"', 'class="emubtn"', 'static/tryemu.js'):
        if need not in t:
            errs.append('try/: the emulator facade lacks %s' % need)
    m = re.search(r'<a class="emustart" href="([^"]+)"', t)
    if not m:
        errs.append('try/: no boot link in the facade')
    else:
        got = m.group(1).replace('&amp;', '&')
        for need in ('machine=apple2ee', 'ramdisk=', 'slot4=mockingboard',
                     'slot5=mouse', 'capslock=off', 'hd1='):
            if need not in got:
                errs.append('try/: the boot URL lacks %s' % need)
        if 'appmode=embed' in got:
            errs.append('try/: the link OUT is the canvas-only build; a '
                        'reader who opens the emulator in its own tab '
                        'wants its controls')
    # The frame gets the canvas-only machine: inside the page the
    # emulator's own panels crowd the screen into a corner of the box
    # (measured 2026-11-01, operator: "screen too tiny to be useful").
    m = re.search(r'<div class="film emu" data-frame-src="([^"]+)"', t)
    if not m:
        errs.append('try/: the .emu block names no frame source')
    else:
        got = m.group(1).replace('&amp;', '&')
        for need in ('appmode=embed', 'machine=apple2ee', 'capslock=off', 'hd1='):
            if need not in got:
                errs.append('try/: the frame source lacks %s' % need)
    # the two signposts lead HERE, not off-site: one page boots maux.
    for rel in ('index.html', 'get/index.html'):
        f = out / rel
        if not f.is_file():
            continue
        txt = f.read_text()
        if TRY_LABEL not in txt:
            continue
        if not re.search(r'class="trylink" href="[^"]*try/index\.html"', txt):
            errs.append('%s: its %r does not lead to /try/' % (rel, TRY_LABEL))
        if 'apple2ts' in txt:
            errs.append('%s: links straight to the emulator, bypassing /try/' % rel)
    # The machine is in the films' case, so it wears the films' chin:
    # one phosphor axis, the same three monitors, under the same
    # localStorage key, and picking one must reach the EMULATOR (its
    # `color` parameter) rather than put a filter over its canvas --
    # the rule docs/DEMO-PHOSPHOR.md sets for the films.
    if 'data-phosphor="%s"' % demo_phos.DEFAULT not in t:
        errs.append('try/: the screen does not name its default phosphor')
    js = out / 'static' / 'tryemu.js'
    if not js.is_file():
        errs.append('static/tryemu.js is not in the output')
    else:
        src = js.read_text()
        for need in ('querySelectorAll("div.emu")', 'querySelector("a.emustart")',
                     'createElement("iframe")', 'preventDefault', 'metaKey',
                     'getAttribute("data-frame-src")', '"maux-phosphor"',
                     '"monctl"', 'color=', 'aria-pressed', 'b.disabled = !!frame'):
            if need not in src:
                errs.append('static/tryemu.js lacks %s' % need)
        if '"sw sw-" + p' not in src:
            errs.append('static/tryemu.js builds no phosphor swatches')
        for ph in demo_phos.NAMES:
            if ph not in src:
                errs.append('static/tryemu.js does not name the %s monitor' % ph)
        if re.search(r'style\.filter|\.filter\s*=', src):
            errs.append('static/tryemu.js filters the picture: a phosphor is '
                        'the monitor, not a tint over one')
        node = shutil.which('node')
        if node:
            r = subprocess.run([node, '--check', str(js)],
                               capture_output=True, text=True)
            if r.returncode:
                errs.append('tryemu.js: not valid JavaScript: %s'
                            % r.stderr.strip()[:200])
    css = (out / 'static' / 'style.css').read_text()
    for need in ('.emuframe { display: block', '.emustart {',
                 '.emu.emulive {'):
        if need not in css:
            errs.append('static/style.css lacks %s' % need)
    return errs


def display_errors(out, b):
    """Both displays' films (docs/DEMO-UT.md): a demo that declares the
    UltraTerm has the //e's files AND the card's (video x2, poster,
    captions) or neither; a demo that does not declare it has none of the
    card's; and a watch page of a two-display demo carries the selector's
    data, the no-JavaScript link to the other film, the script, and the
    one public sentence about the card."""
    errs = []
    out = Path(out)
    if not b.a.ut:
        return ut_off_errors(out)
    if not (out / 'static' / 'display.js').is_file():
        errs.append('static/display.js is not in the output')
    for name, d in sorted(b.demos.items()):
        wd = out / 'watch' / name
        has = {}
        for disp, suf in (('e', ''), ('ut', '-ut')):
            # every variant by name, from the recorder's own table: the
            # film and the poster exist once per monitor, the captions
            # once (docs/DEMO-PHOSPHOR.md)
            has[disp] = {
                (kind if ph is None else '%s (%s)' % (kind, ph)):
                    (wd / fn).is_file()
                for (kind, ph), fn in demo_stamp.out_names(name, suf).items()}
        both = 'ut' in d['backends']
        any_e, any_ut = any(has['e'].values()), any(has['ut'].values())
        if not both and any_ut:
            errs.append('watch/%s: has UltraTerm files but the demo does '
                        'not declare the card' % name)
        if any_e or any_ut:
            for disp in (('e', 'ut') if both else ('e',)):
                miss = [k for k, v in has[disp].items() if not v]
                if miss:
                    errs.append('watch/%s: the %s display lacks %s'
                                % (name, 'UltraTerm' if disp == 'ut'
                                   else '//e', ', '.join(miss)))
        page = wd / 'index.html'
        if not page.is_file():
            continue
        t = page.read_text()
        if both:
            if UT_SENTENCE not in t:
                errs.append('watch/%s: no sentence saying what the UltraTerm '
                            'was' % name)
        if both and any_e:
            need = ['data-display="e"', 'data-phosphor="%s"' % DEF_PH,
                    'data-display-alt', 'display.js']
            # every cell of the matrix must be reachable from the markup,
            # or a monitor button swaps in a 404
            for disp in ('e', 'ut'):
                need.append('data-%s-vtt-src=' % disp)
                for ph in demo_phos.NAMES:
                    need += ['data-%s-%s-mp4-src=' % (disp, ph),
                             'data-%s-%s-webm-src=' % (disp, ph),
                             'data-%s-%s-poster=' % (disp, ph)]
            for n_ in need:
                if n_ not in t:
                    errs.append('watch/%s: player markup lacks %s'
                                % (name, n_))
            alt = demo_stamp.out_name('mp4', name, '-ut', DEF_PH)
            if '<a href="%s">' % alt not in t:
                errs.append('watch/%s: no plain link to the UltraTerm film '
                            '(the page must work with JavaScript off)' % name)
            vid = re.search(r'<video\b.*?</video>', t, re.S)
            if vid:
                # the <source> elements only: strip every data-* first,
                # since those legitimately name all six films
                bare = re.sub(r'data-[a-z0-9-]+="[^"]*"', '',
                              vid.group(0))
                want = demo_stamp.out_name('mp4', name, '', DEF_PH)
                if want not in bare or '-ut-' in bare:
                    errs.append('watch/%s: the default <video> is not the '
                                '//e film on %s' % (name, DEF_PH))
    home = out / 'index.html'
    if home.is_file():
        hero = [n for n, d in b.demos.items() if d.get('hero')]
        t = home.read_text()
        hero_mp4 = (demo_stamp.out_name('mp4', hero[0], '', DEF_PH)
                    if hero else None)
        if hero and 'ut' in b.demos[hero[0]]['backends'] and \
                (out / 'watch' / hero[0] / hero_mp4).is_file():
            for need in ('data-ut-%s-mp4-src=' % DEF_PH,
                         'data-display-alt', 'display.js'):
                if need not in t:
                    errs.append('index: the hero player lacks %s' % need)
    return errs


def demo_stamp_info(path):
    """The image, floppy and backends keys of a demo script's DEMO(...)
    call, read without importing the script. `backends` is normalised
    the way site/build.py and demo_record.py normalise it, so a demo
    declaring one display (site/demos/lssys.py, which crosses a `bye`
    window where the card is not the selected display) is described
    here as it is there."""
    import ast
    for n in ast.parse(Path(path).read_text()).body:
        if isinstance(n, ast.Assign) and isinstance(n.value, ast.Call) and \
           any(getattr(t, 'id', '') == 'DEMO' for t in n.targets):
            kw = {k.arg: ast.literal_eval(k.value) for k in n.value.keywords}
            bk = kw.get('backends', (kw.get('backend', 'text80'),))
            return {'image': kw.get('image', 'play'),
                    'floppy': kw.get('floppy'),
                    'backends': tuple(bk)}
    raise ValueError('%s: no DEMO' % path)


def fact_source_errors(root, site):
    """Every DEFINED fact's evidence must still be there, whether or not
    a page cites it. The build only resolves the facts the pages ask
    for, so without this a fact dropped from the site keeps its row in
    facts.py and quietly stops being checked."""
    spec = importlib.util.spec_from_file_location(
        'site_facts_sources', site / 'facts.py')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.check_sources(root)


def run(root, site, out, extra=None, full=True, roster=None, local_ok=False,
        images=None, floppies=None, ffmpeg_now='probe', env=None):
    build = load_build(site)
    build.FILM_ENV = env
    # site/build.py checks the films itself (so `make site` does too);
    # these are the self-test's hooks for scratch images and ffmpeg
    build.FILM_IMAGES, build.FILM_FLOPPIES = images, floppies
    build.FILM_FFMPEG = ffmpeg_now
    argv = ['--root', str(root), '--site', str(site), '--out', str(out)] + (extra or [])
    if local_ok:
        argv.append('--local-preview')
    b = build.build(argv)
    errs = list(b.errors)
    errs += source_errors(root, site)
    errs += fact_source_errors(root, site)
    if full and roster is None:
        sys.path.insert(0, str(root / 'scripts'))
        try:
            import check_man
            roster = check_man.command_roster()
        finally:
            sys.path.pop(0)
    errs += output_errors(out, full, roster, local_ok)
    errs += display_errors(out, b)
    errs += captions_errors(out, b)
    errs += tryemu_errors(out, b)
    return errs, b


COPY = ('Makefile', 'dependencies.lock.json', 'README.md', 'HACKING.md', 'LICENSE',
        'docs', 'src', 'inc', 'evidence', 'scripts', 'site', 'examples')


def self_test(root, cache):
    scratch = Path(tempfile.mkdtemp(prefix='checksite-'))
    try:
        keep = 'sh,cat,licenses,ar,grep,man,nas,ld'
        sessions = root / 'build/examples'
        extra = ['--man-only', keep, '--cache', str(cache),
                 '--examples', str(sessions),
                 '--demos', str(scratch / 'no-films')]   # a row's own --demos wins
        small_roster = {'sh', 'cat', 'grep', 'man', 'nas', 'ld'}
        n_rows = 0

        def say(name, hit):
            nonlocal n_rows
            n_rows += 1
            print('  red as required: %-44s -> %s' % (name, hit[:76]))

        # ---- site-only defects, in a scratch copy of site/ -------------
        def fresh():
            d = scratch / 'site'
            if d.exists():
                shutil.rmtree(d)
            shutil.copytree(root / 'site', d, ignore=shutil.ignore_patterns('__pycache__'))
            return d

        # Scratch disk images for the freshness stamps: the films below are
        # stamped against these, so the rows need neither build/play.po nor
        # an emulator.
        imgs = {}
        for k in demo_stamp.IMAGES:
            imgs[k] = str(scratch / ('img-' + k))
            Path(imgs[k]).write_bytes(b'image ' + k.encode())
        flops = {k: str(scratch / ('flop-' + k)) for k in demo_stamp.FLOPPIES}
        for f in flops.values():
            Path(f).write_bytes(b'floppy')
        imgs_all = dict(imgs)

        FAKE_FF = 'ffmpeg version 0.0-fixture'

        def make_va(top):
            """A scratch verilogapple checkout: the supervisor and its two
            workers, the ROMs (and a readme.txt no machine loads), the
            SmartPort firmware."""
            top = Path(top)
            for rel in ('sim/mcp/obj_dir/mcp_supervisor',
                        'sim/mcp/obj_dir/mcp_worker_fast',
                        'sim/mcp/obj_dir/Vapple2e_sim_top',
                        'sim/roms/iie_cd_ef.rom', 'sim/roms/iie_video.rom',
                        'sim/roms/applemouse.rom', 'sim/roms/disk2.rom',
                        'sim/roms/ssc.rom',
                        'sim/roms/ultraterm/firmware_v3.bin',
                        'sim/roms/ultraterm/firmware_v1.bin',
                        'sim/roms/ultraterm/chargen_v3.bin',
                        'sim/roms/ultraterm/chargen_v1.bin',
                        'sim/roms/ultraterm/readme.txt',
                        'sim/smartport/firmware'):
                f = top / rel
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_bytes(('fixture ' + rel).encode())
            return top

        va = make_va(scratch / 'verilogapple')
        base_env = {k: v for k, v in os.environ.items() if k in ('A2TIL', 'HOME')}
        film_env = dict(base_env, VERILOGAPPLE=str(va))

        def go(d, more=None, images=None, floppies=None, ff=FAKE_FF, env=None):
            errs, _ = run(root, d, scratch / 'out', extra + (more or []),
                          full=False, images=images or imgs_all,
                          floppies=floppies or flops, ffmpeg_now=ff,
                          env=env or film_env)
            return errs

        d = fresh()
        base = go(d)
        assert not base, ('baseline scratch build is not clean (the lesson '
                          'pages need build/examples: make check-examples): '
                          '%s' % base[:3])

        def append(page, text):
            p = d / 'pages' / page
            p.write_text(p.read_text() + text)

        def sub(path, old, new):
            p = d / path
            s = p.read_text()
            assert old in s, (path, old)
            p.write_text(s.replace(old, new, 1))

        def write(path, text):
            p = d / path
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)

        def high_byte():
            p = d / 'pages' / 'architecture.html'
            p.write_bytes(p.read_bytes() + b'\n<p>caf\xc3\xa9</p>\n')

        def css_url():
            p = d / 'static/style.css'
            p.write_text(p.read_text() + '\nbody { background: url(missing.png); }\n')

        cases = [
            ('broken internal link', 'broken link',
             lambda: append('architecture.html', '\n<p><a href="/nowhere/">x</a></p>\n')),
            ('broken fragment', 'no anchor',
             lambda: append('architecture.html', '\n<p><a href="/get/#nosuchanchor">x</a></p>\n')),
            ('page naming a demo with no file', 'no file in site/demos',
             lambda: append('architecture.html', '\n<p>{{demo:nosuchdemo}}</p>\n')),
            ('watch page whose demo header is missing', 'ghost',
             lambda: write('pages/watch/ghost.html',
                           'title: Ghost\ndescription: x\ndemo: ghost\n---\n'
                           '<!-- src: site/README -->\n<p>{{gen:democommands}}</p>\n')),
            ('two counts of different sets on one page', 'one page, one count',
             lambda: sub('pages/index.html', 'produces the utilities',
                         'produces all {{fact:selfrebuild_utils}} utilities')),
            ('placeholder with no fact', 'has no fact',
             lambda: append('architecture.html', '\n<p>{{fact:no_such_fact}}</p>\n')),
            ('fact whose source is missing', 'source missing',
             lambda: sub('facts.py', "SELF = 'evidence/", "SELF = 'evidence/gone-")),
            ('non-ASCII byte in a source', 'non-ASCII', high_byte),
            ('source link gone from the header', 'no source link',
             lambda: sub('templates/page.html', '<a class="src',
                         '<a class="notsrc')),
            ('source link pointing into a tree', 'points INTO a tree',
             lambda: sub('build.py', "r'/(blob|tree)/[^/]+/*$'",
                         "r'/(blobx|treex)/[^/]+/*$'")),
            ('link to cornflower.au', 'cornflower.au',
             lambda: append('architecture.html', '\n<p><a href="https://forgejo.cornflower.au/mdj/maux">x</a></p>\n')),
            ('link to the removed Support page', 'removed Support page',
             lambda: append('architecture.html', '\n<p><a href="/support/">x</a></p>\n')),
            ('Support back in the nav', 'support/: the Support page was removed',
             lambda: sub('build.py', "('about', 'About')]", "('support', 'Support'), ('about', 'About')]") or
             write('pages/support.html', 'title: Support\ndescription: x\n---\n<!-- src: site/README -->\n<p>x</p>\n')),
            ('Proof back in the nav', 'has a Proof entry',
             lambda: sub('build.py', "('conformance', 'Conformance'),",
                         "('proof', 'Proof'), ('conformance', 'Conformance'),")),
            ('link to the removed Proof page', 'links to the removed Proof page',
             lambda: append('architecture.html', '\n<p><a href="/proof/">x</a></p>\n')),
            ('hand-typed count on the Conformance page', 'hand-typed number',
             lambda: append('conformance.html', '\n<p>66 of 66 match.</p>\n')),
            ('hand-typed count spelled out', 'hand-typed number',
             lambda: append('conformance.html', '\n<p>Sixty-six of them match.</p>\n')),
            ('hand-typed count in a table row', 'hand-typed number',
             lambda: sub('conformance.py', "'Version 7 Unix.'",
                         "'Version 7 Unix, 138 cases.'")),
            ('known gaps counted as matching cases (the gate\'s 837/837)',
             'once its known gaps are taken out',
             lambda: sub('facts.py', 'g = gaps.get(tool, 0)', 'g = 0')),
            ('a gap tool\'s table row printing the gate figure',
             'the grep table row does not say',
             lambda: sub('conformance.py', "util('grep'),",
                         "'{{fact:cf_u_grep_total}} of {{fact:cf_u_grep_total}}',")),
            ('a tool with a gap listed without its tally',
             'which has no tally',
             lambda: sub('facts.py', "gaps[tool] = gaps.get(tool, 0) + 1",
                 "gaps[tool] = gaps.get(tool, 0) + 1; gaps['nosuch'] = 1")),
            ('a gap row whose empty option leaves a leading colon',
             'punctuation where its sentence should begin',
             lambda: sub('build.py', "'<li><code>sh</code> %s</li>'",
                         "'<li><code>sh</code>: %s</li>'")),
            ('a gap row whose option stays outside the chip',
             'is shown as',
             lambda: sub('build.py', "if not shown:", "if False:")),
            ('a gap missing from the gaps list', 'gaps list has',
             lambda: sub('build.py', 'for tool, name, head in gaps:',
                         'for tool, name, head in gaps[:-1]:')),
            ('a shell difference missing from its list', 'shell list has',
             lambda: sub('build.py', 'for d in sh:', 'for d in sh[:-1]:')),
            ('link to localhost', 'names localhost',
             lambda: append('architecture.html', '\n<p><a href="http://127.0.0.1:8000/x">x</a></p>\n')),
            ('src comment naming a missing file', 'not in the tree',
             lambda: append('architecture.html', '\n<!-- src: docs/NO-SUCH-DOC.md -->\n')),
            ('src comment naming a missing extensionless path', 'not in the tree',
             lambda: append('architecture.html', '\n<!-- src: docs/NOSUCH -->\n')),
            ('repo: link to an untracked file', 'untracked',
             lambda: append('architecture.html', '\n<p><a href="repo:docs/NO-SUCH-DOC.md">x</a></p>\n')),
            ('page of paragraphs with no src comment', 'no <!-- src',
             lambda: write('pages/bare.html', 'title: Bare\ndescription: x\n---\n<p>A claim.</p>\n')),
            ('unknown placeholder kind', 'unknown placeholder',
             lambda: append('architecture.html', '\n<p>{{wat:x}}</p>\n')),
            ('css url() to a missing file', 'broken css url', css_url),
            ('lesson page whose lesson has no check-examples row',
             'has no check-examples row',
             lambda: write('pages/learn/ghost.html',
                           'title: Ghost\ndescription: x\nlesson: l9\n---\n'
                           '<!-- src: site/README -->\n<p>{{gen:session}}</p>\n')),
            ('page under learn/ with no lesson header', 'no "lesson:" header',
             lambda: write('pages/learn/bare.html',
                           'title: Bare\ndescription: x\n---\n'
                           '<!-- src: site/README -->\n<p>x</p>\n')),
            ('lesson page including a file that is not in examples/',
             'is not a file of examples',
             lambda: append('learn/make.html',
                            '\n<!-- src: site/README -->\n<p>{{file:examples/upcase/NOSUCH}}</p>\n')),
            ('no demo claims the Home hero', 'exactly one demo must say hero',
             lambda: sub('demos/firstmin.py', '    hero=True,\n', '')),
            ('two demos claim the Home hero', 'exactly one demo must say hero',
             lambda: sub('demos/fedgrep.py', "    gate='check-demo-fedgrep',\n",
                         "    gate='check-demo-fedgrep',\n    hero=True,\n")),
            ('HTML comment left in the output', 'leaks an HTML comment',
             lambda: sub('build.py', "t2 = strip_comments(", "t2 = (")),
            ('a learning: handle in a page', 'leaks a learning: handle',
             lambda: append('architecture.html', '\n<p>see learning: x</p>\n')),
            ('a ULID-shaped token in a page', 'leaks a ULID-shaped token',
             lambda: append('architecture.html', '\n<p>01M5B7EHM1595W9XPJRTCT7MVF</p>\n')),
            ('"the operator" in a page', 'leaks the operator',
             lambda: append('architecture.html', '\n<p>The operator runs this card.</p>\n')),
            ('an internal brief name in a page', 'leaks an internal brief name',
             lambda: append('architecture.html', '\n<p>(UT-CELL, 2026-10-21)</p>\n')),
            ('a brief name nobody listed (SH-ROOM)', 'leaks an internal brief name',
             lambda: append('architecture.html', '\n<p>after SH-ROOM landed</p>\n')),
            ('a notes-file name in a page', 'leaks a notes-file name',
             lambda: append('architecture.html', '\n<p>see KFIX4-NOTES sec 3</p>\n')),
            ('a RULINGS reference in a page', 'leaks a rulings reference',
             lambda: append('architecture.html', '\n<p>deleted 2026-10-18, RULINGS-1</p>\n')),
            ('a KFIX name in a page', 'leaks a KFIX brief name',
             lambda: append('architecture.html', '\n<p>(since KFIX4)</p>\n')),
            ('a confidence tag in a page', 'leaks a confidence tag',
             lambda: append('architecture.html', '\n<p>[fact, MAME 0.286]</p>\n')),
            ('a dash-style confidence tag', 'leaks a confidence tag',
             lambda: append('architecture.html', '\n<p>[likely -- derived]</p>\n')),
            ('an observed tag', 'leaks a confidence tag',
             lambda: append('architecture.html', '\n<p>[observed]</p>\n')),
            ('the word commons in a page', 'leaks the words commons',
             lambda: append('architecture.html', '\n<p>The Commons.</p>\n')),
            ('street-library in an inline svg', 'leaks the words commons',
             lambda: sub('static/diagrams/fork80.svg', 'The documentation already',
                         'The street-library already')),
            ('img srcset to a missing file', 'broken link srcset',
             lambda: append('architecture.html', '\n<p><img srcset="nope.png 2x" alt=""></p>\n')),
        ]
        for name, expect, plant in cases:
            d = fresh()
            plant()
            errs = go(d)
            hit = [e for e in errs if expect in e]
            assert hit, 'defect NOT caught: %s (got %s)' % (name, errs[:3])
            say(name, hit[0])

        # ---- both displays' films (docs/DEMO-UT.md) --------------------
        # Scratch films (a few bytes each: the build only copies them) for
        # every demo, both displays, so the display rows have something to
        # check; then one defect at a time.
        def box(t, body):
            return struct.pack('>I4s', 8 + len(body), t) + body

        def mp4_bytes(w, h, coded=None, sar=None, matrix=None, uniq=b'x'):
            """The smallest mp4 whose moov has a video track of w x h (an
            audio-looking 0 x 0 track first, to prove the reader skips
            it), with the avc1 coded size (default w x h), an optional
            pasp, and the display matrix (default identity)."""
            def tkhd(w, h, m):
                return box(b'tkhd', bytes(4 + 8 + 4 + 4 + 4 + 8 + 2 + 2 + 2 + 2)
                           + struct.pack('>9i', *m)
                           + struct.pack('>II', w << 16, h << 16))
            cw, ch = coded or (w, h)
            kids = box(b'pasp', struct.pack('>II', *sar)) if sar else b''
            avc1 = box(b'avc1', bytes(24) + struct.pack('>HH', cw, ch)
                       + bytes(78 - 28) + kids)
            stsd = box(b'stsd', struct.pack('>II', 0, 1) + avc1)
            mdia = box(b'mdia', box(b'minf', box(b'stbl', stsd)))
            ident = demo_stamp.IDENTITY
            return (box(b'ftyp', b'isom\0\0\2\0')
                    + box(b'moov', box(b'trak', tkhd(0, 0, ident))
                          + box(b'trak', tkhd(w, h, matrix or ident) + mdia))
                    + box(b'mdat', uniq))

        def webm_bytes(w, h, uniq=b''):
            def el(i, body):
                return i + (0x10000000 | len(body)).to_bytes(4, 'big') + body
            video = el(b'\xe0', el(b'\xb0', w.to_bytes(2, 'big'))
                       + el(b'\xba', h.to_bytes(2, 'big')))
            seg = el(b'\x16\x54\xae\x6b', el(b'\xae', video))
            return (el(b'\x1a\x45\xdf\xa3', b'') +
                    el(b'\x18\x53\x80\x67', seg) + el(b'\xec', uniq))

        def png_bytes(w, h, uniq=b''):
            return (b'\x89PNG\r\n\x1a\n' + struct.pack('>I4sII5s', 13, b'IHDR',
                                                         w, h, b'\x08\x02\0\0\0') + uniq)

        snaps = {}

        def sufs_of(name):
            """The output-file suffixes a demo HAS: ('',) for one that
            declares a single display, ('', '-ut') for both. A fixture
            that assumes both is a fixture that cannot hold a
            single-display demo (site/demos/lssys.py)."""
            info = demo_stamp_info(root / 'site/demos' / (name + '.py'))
            return ('', '-ut') if 'ut' in info['backends'] else ('',)

        def films(root_dir, drop=(), size=None, stamps=True, mp4opt=None):
            """Scratch films for every demo, both displays: real mp4, webm
            and PNG headers at the recorder's declared size (size:
            {relative file: (w, h)} overrides one; mp4opt: {relative
            file: mp4_bytes options}), a stamp of the demo as it is in
            root/site (listing a scratch tool file and, for a demo that
            imports demo_host, scripts/demo_host.py) bound to those
            output files, and a few bytes for the vtt."""
            size, mp4opt = size or {}, mp4opt or {}
            if root_dir.exists():
                shutil.rmtree(root_dir)
            for dp in sorted((root / 'site/demos').glob('*.py')):
                n = dp.stem
                (root_dir / n).mkdir(parents=True)
                # only the displays the demo declares: a film set with
                # card files for a demo that does not declare the card
                # is exactly what the checker below must REFUSE, so the
                # fixture must not create one by default
                for suf in sufs_of(n):
                    for (kind, _ph), fn in demo_stamp.out_names(
                            n, suf).items():
                        rel = n + '/' + fn
                        if kind == 'mp4':
                            body = mp4_bytes(*size.get(rel, demo_stamp.FILM_SIZE),
                                             uniq=rel.encode(),
                                             **mp4opt.get(rel, {}))
                        elif kind == 'webm':
                            body = webm_bytes(*size.get(rel, demo_stamp.FILM_SIZE),
                                              uniq=rel.encode())
                        elif kind == 'poster':
                            body = png_bytes(*size.get(rel, demo_stamp.POSTER_SIZE),
                                             uniq=rel.encode())
                        else:
                            body = b'WEBVTT ' + rel.encode()
                        (root_dir / n / fn).write_bytes(body)
                    if stamps:
                        info = demo_stamp_info(dp)
                        if (dp, suf) not in snaps:
                            extra_f = []
                            if 'import demo_host' in dp.read_text():
                                extra_f.append(root / 'scripts/demo_host.py')
                            snaps[(dp, suf)] = demo_stamp.snapshot(
                                str(dp), imgs_all[info['image']],
                                flops.get(info['floppy']) if info['floppy']
                                else None, 'ut' if suf else 'text80',
                                ffmpeg=FAKE_FF,
                                extra_files=[str(x) for x in extra_f],
                                env=film_env)
                        demo_stamp.write_stamp(
                            str(root_dir / n), n, suf,
                            'ut' if suf else 'text80', snaps[(dp, suf)])
            for rel in drop:
                (root_dir / rel).unlink()

        dd = scratch / 'films'
        films(dd)
        d = fresh()
        errs = go(d, ['--demos', str(dd), '--ut'])
        assert not errs, 'a complete set of both displays rejected: %s' % errs[:3]
        n_rows += 1
        print('  passes as required: both displays\' films for every demo')
        for name, expect, drop in (
                ('UltraTerm captions missing',
                 'the UltraTerm display lacks vtt',
                 ('fedgrep/' + demo_stamp.out_name('vtt', 'fedgrep', '-ut'),)),
                ('UltraTerm poster missing',
                 'the UltraTerm display lacks poster (%s)' % DEF_PH,
                 ('fedgrep/' + demo_stamp.out_name(
                     'poster', 'fedgrep', '-ut', DEF_PH),)),
                ('UltraTerm webm missing',
                 'the UltraTerm display lacks webm (%s)' % DEF_PH,
                 ('vi/' + demo_stamp.out_name('webm', 'vi', '-ut', DEF_PH),)),
                # ONE monitor gone and the others present: the shape a
                # partial `make demos --phosphor X` leaves behind, and
                # the one a per-display check would miss
                ('one monitor missing, the others present',
                 'the UltraTerm display lacks mp4 (amber)',
                 ('vi/' + demo_stamp.out_name('mp4', 'vi', '-ut', 'amber'),)),
                ('//e captions missing', 'the //e display lacks vtt',
                 ('fedgrep/' + demo_stamp.out_name('vtt', 'fedgrep'),)),
                ('//e film gone, card film present',
                 'the //e display lacks mp4 (%s)' % DEF_PH,
                 ('man/' + demo_stamp.out_name('mp4', 'man', '', DEF_PH),))):
            d = fresh()
            films(dd, drop)
            errs = go(d, ['--demos', str(dd), '--ut'])
            hit = [e for e in errs if expect in e]
            assert hit, 'defect NOT caught: %s (got %s)' % (name, errs[:3])
            say(name, hit[0])
        # ---- frame size and freshness of the films (scripts/demo_stamp.py)
        fw, fh = demo_stamp.FILM_SIZE
        pw, ph = demo_stamp.POSTER_SIZE

        def restamp(name, mutate, suf=''):
            f = dd / name / ('%s%s.stamp.json' % (name, suf))
            doc = json.loads(f.read_text())
            mutate(doc)
            f.write_text(json.dumps(doc))

        def set_in(path, value):
            def m(doc):
                node = doc
                *head, last = path.split('/')
                for k in head:
                    node = node[k]
                node[last] = value
            return m

        def drop_file(key):
            return lambda doc: doc['inputs']['files'].pop(key)

        def copy_over(src, dst, both_kinds=True):
            """src's files and stamp copied over dst's, names kept."""
            for kind, fn in demo_stamp.out_names(src, '').items():
                shutil.copy(dd / src / fn, dd / dst / demo_stamp.out_names(dst, '')[kind])
            shutil.copy(dd / src / demo_stamp.stamp_name(src),
                        dd / dst / demo_stamp.stamp_name(dst))

        importers = sorted(
            p.stem for p in (root / 'site/demos').glob('*.py')
            if 'import demo_host' in p.read_text())
        assert importers, 'no demo imports demo_host: the reviewer\'s row is moot'

        def stale_all_importers():
            for n in importers:
                for suf in sufs_of(n):
                    restamp(n, lambda doc: doc['inputs']['files'].__setitem__(
                        'scripts/demo_host.py', '0' * 64), suf)

        # The rows below spell the DEFAULT monitor into their file
        # names and expected messages, which keeps them readable; this
        # is the one place that coupling is stated, so it cannot rot
        # quietly if the default moves.
        assert DEF_PH == 'paper', 'the rows below spell the default monitor'
        stamp_rows = (
            ('film of the wrong size', 'jobs/jobs-paper.mp4: frame size 720x468',
             dict(size={'jobs/jobs-paper.mp4': (720, 468)}), None),
            ('the old 720x420 film beside new ones', 'the films are not one size',
             dict(size={'man/man-paper.mp4': (720, 420)}), None),
            ('ut film a different size from its text80 twin',
             'vi-ut-paper.mp4: frame size %dx%d' % (fw, fh - 96),
             dict(size={'vi/vi-ut-paper.mp4': (fw, fh - 96)}), None),
            ('ut film a different size, caught as mixed sizes',
             'the films are not one size',
             dict(size={'vi/vi-ut-paper.mp4': (fw, fh - 96)}), None),
            ('webm (the first <source>) of the wrong size',
             'jobs/jobs-paper.webm: frame size 720x468',
             dict(size={'jobs/jobs-paper.webm': (720, 468)}), None),
            ('coded 720x936 shown at 1440x936 with SAR 2:1',
             'coded size 720x936',
             dict(mp4opt={'jobs/jobs-paper.mp4': dict(coded=(720, 936), sar=(2, 1))}),
             None),
            ('coded size right but the pixel aspect 2:1', 'pixel aspect 2:1',
             dict(mp4opt={'jobs/jobs-paper.mp4': dict(sar=(2, 1))}), None),
            ('a film rotated 90 degrees by its display matrix',
             'display matrix is not the identity',
             dict(mp4opt={'jobs/jobs-paper.mp4': dict(
                 matrix=(0, 0x10000, 0, -0x10000, 0, 0, 0, 0, 0x40000000))}),
             None),
            ('poster of the wrong size',
             'poster-paper.png: size 560x384',
             dict(size={'diffed/poster-paper.png': (560, 384)}), None),
            ('ut poster not its twin\'s size', 'the posters are not one size',
             dict(size={'diffed/poster-ut-paper.png': (pw, ph - 8)}), None),
            ('a stamp whose script hash differs',
             'jobs-paper.mp4: stale -- the demo script changed',
             dict(), lambda: restamp('jobs', set_in('inputs/script', '0' * 64))),
            ('a ut stamp whose script hash differs',
             'jobs-ut-paper.mp4: stale -- the demo script changed',
             dict(), lambda: restamp('jobs', set_in('inputs/script', '0' * 64),
                                     '-ut')),
            ('the demo script edited after the film',
             'fedgrep-paper.mp4: stale -- the demo script changed',
             dict(), lambda: sub('demos/fedgrep.py', 'DEMO = dict(',
                                 '# edited after the film\nDEMO = dict(')),
            ('a stamp whose image hash differs',
             'stale -- the disk image it booted changed',
             dict(), lambda: restamp('man', set_in('inputs/image', '0' * 64))),
            ('a stamp whose recorder-source hash differs',
             'input scripts/demo_overlay.py changed',
             dict(), lambda: restamp('man', lambda doc: doc['inputs']['files']
                                     .__setitem__('scripts/demo_overlay.py',
                                                  '0' * 64))),
            ('demo_host.py edited: every film that imports it is stale',
             'input scripts/demo_host.py changed',
             dict(), stale_all_importers),
            ('the verilogapple worker changed since the film',
             'input ext:worker_fast changed',
             dict(), lambda: restamp('man', lambda doc: doc['inputs']['files']
                                     .__setitem__('ext:worker_fast', '0' * 64))),
            ('a stamp that does not list a recorder source',
             'does not list recorder source scripts/demo_png.py',
             dict(), lambda: restamp('man', drop_file('scripts/demo_png.py'))),
            ('a missing stamp', 'fedgrep-paper.mp4: no fedgrep.stamp.json',
             dict(drop=('fedgrep/fedgrep.stamp.json',)), None),
            ('a missing ut stamp', 'vi-ut-paper.mp4: no vi-ut.stamp.json',
             dict(drop=('vi/vi-ut.stamp.json',)), None),
            ('films with no stamps at all (recorded before stamps)',
             're-record with `make demos`',
             dict(stamps=False), None),
            ('vi\'s files and stamp copied over man\'s',
             'man-paper.mp4: its stamp is for demo \'vi\'',
             dict(), lambda: copy_over('vi', 'man')),
            ('vi\'s files copied over man\'s, man\'s stamp kept',
             'is not the file this stamp was written for',
             dict(), lambda: [shutil.copy(dd / 'vi' / fn, dd / 'man' / fn2)
                              for (_, fn), (_, fn2) in zip(
                                  demo_stamp.out_names('vi').items(),
                                  demo_stamp.out_names('man').items())]),
            ('jobs-ut.stamp.json copied over jobs.stamp.json',
             'jobs-paper.mp4: its stamp is for the \'ut\' display',
             dict(), lambda: shutil.copy(dd / 'jobs/jobs-ut.stamp.json',
                                         dd / 'jobs/jobs.stamp.json')),
            ('a webm swapped for another film\'s (same size)',
             'jobs-paper.webm is not the file this stamp was written for',
             dict(), lambda: shutil.copy(dd / 'man/man-paper.webm',
                                         dd / 'jobs/jobs-paper.webm')),
            ('recorded with another seed',
             'recorded with seed 1,', dict(),
             lambda: restamp('man', set_in('inputs/seed', 1))),
            ('recorded with --setup', 'recorded with --setup',
             dict(), lambda: restamp('man', set_in('inputs/setup', ['true']))),
            ('recorded with --host-clock', 'recorded with --host-clock',
             dict(), lambda: restamp('man', set_in('inputs/host_clock', True))))
        HP = 'plasma hello.mod, the first time:'
        HC = './hello, cut by plascut, the first time:'
        HW = './hello again, warm:'

        def plant_measures(measures, say_first='1.19', say_cut='0.85'):
            """hellopla's captions state three figures, each after its own
            labelled cue; its stamp carries MEASURES, rebound to them."""
            (dd / 'hellopla/hellopla.vtt').write_text(
                'WEBVTT\n\n'
                '00:00:00.000 --> 00:00:03.000\n%s %s million cycles from '
                'RETURN to the output.\n\n'
                '00:00:03.000 --> 00:00:06.000\n%s %s million cycles, '
                'against %s million for plasma hello.mod.\n\n'
                '00:00:06.000 --> 00:00:09.000\n%s 0.17 million cycles.\n'
                % (HP, say_first, HC, say_cut, say_first, HW))
            demo_stamp.write_stamp(
                str(dd / 'hellopla'), 'hellopla', '', 'text80',
                snaps[(root / 'site/demos/hellopla.py', '')], measures)

        good = {'plasma_first': 1190560, 'cooked_first': 850400,
                'cooked_warm': 170080}
        d = fresh()
        films(dd)
        plant_measures(good)
        errs = go(d, ['--demos', str(dd), '--ut'])
        assert not errs, ('a stamp whose measures match their own captions '
                          'rejected: %s' % errs[:3])
        n_rows += 1
        print('  passes as required: measures that each caption states')
        for name, expect, measures, kw in (
                ('a measure edited to a figure no caption states',
                 'measure plasma_first=2500000 is not the figure its '
                 'caption states', dict(good, plasma_first=2500000), {}),
                ('plasma_first set to the cooked figure (another cue states it)',
                 'measure plasma_first=850400 is not the figure its caption '
                 'states', dict(good, plasma_first=850400), {}),
                ('plasma_first and cooked_first swapped',
                 'measure cooked_first=1190560 is not the figure its caption '
                 'states', dict(good, plasma_first=850400,
                                cooked_first=1190560), {}),
                ('captions and measures swapped together (out of order)',
                 'are out of order',
                 dict(good, plasma_first=850400, cooked_first=1190560),
                 dict(say_first='0.85', say_cut='1.19')),
                ('a measure no caption vouches for',
                 'measure extra has no MEASURE_CAPTIONS entry',
                 dict(good, extra=1), {})):
            d = fresh()
            films(dd)
            plant_measures(measures, **kw)
            errs = go(d, ['--demos', str(dd), '--ut'])
            hit = [e for e in errs if expect in e]
            assert hit, 'defect NOT caught: %s (got %s)' % (name, errs[:3])
            say(name, hit[0])
        d = fresh()
        films(dd)
        errs = go(d, ['--demos', str(dd), '--ut'])
        assert not errs, 'fresh stamped films rejected: %s' % errs[:3]
        n_rows += 1
        print('  passes as required: every film the declared size and stamped '
              'from the current script, image, recorder and tools')
        for name, expect, kw, plant in stamp_rows:
            d = fresh()
            films(dd, **kw)
            if plant:
                plant()
            errs = go(d, ['--demos', str(dd), '--ut'])
            hit = [e for e in errs if expect in e]
            assert hit, 'defect NOT caught: %s (got %s)' % (name, errs[:3])
            if name.startswith('demo_host.py'):
                gone = {e.split('/')[1] for e in errs
                        if 'input scripts/demo_host.py changed' in e}
                assert gone == set(importers), (gone, importers)
            say(name, hit[0])
        # external inputs are keyed by ROLE: the same stamps, checked with
        # VERILOGAPPLE pointing at a copy with identical bytes, stay green
        d = fresh()
        films(dd)
        stamp0 = json.loads((dd / 'man/man.stamp.json').read_text())
        assert all(not k.startswith(str(scratch)) and not os.path.isabs(k)
                   for k in stamp0['inputs']['files']), 'an absolute path in a stamp'
        va2 = make_va(scratch / 'elsewhere' / 'verilogapple-copy')
        errs = go(d, ['--demos', str(dd), '--ut'], env=dict(base_env, VERILOGAPPLE=str(va2)))
        assert not errs, 'a byte-identical copy of verilogapple rejected: %s' % errs[:3]
        n_rows += 1
        print('  passes as required: VERILOGAPPLE at a byte-identical copy (stamps keyed by role)')
        roles_bare = set(k for k in stamp0['inputs']['files'] if k.startswith('ext:'))
        assert 'ext:rom/ultraterm/readme.txt' not in roles_bare
        assert not any('ultraterm' in k or 'ssc' in k or 'disk2' in k
                       for k in roles_bare), roles_bare
        # the card the films show is the recorder's own (demo_ut.REVISIONS,
        # the original card v1); the other revision's firmware is not loaded
        ut_fw = demo_stamp.UT_FIRMWARE
        unloaded = 'ultraterm/firmware_v3.bin'
        assert ut_fw != unloaded
        assert 'ext:rom/' + ut_fw in json.loads(
            (dd / 'man/man-ut.stamp.json').read_text())['inputs']['files']
        # only the ROMs the machine loads: readme.txt, an unloaded ROM
        # (ssc, the other revision's firmware) change nothing
        for rel in ('ultraterm/readme.txt', 'ssc.rom', unloaded):
            (va / 'sim/roms' / rel).write_bytes(b'edited')
        errs = go(d, ['--demos', str(dd), '--ut'])
        assert not errs, 'a ROM the machine does not load made films stale: %s' % errs[:3]
        n_rows += 1
        print('  passes as required: editing ultraterm/readme.txt, ssc.rom and the other revision\'s firmware changes nothing')
        (va / 'sim/roms' / ut_fw).write_bytes(b'a new firmware')
        errs = go(d, ['--demos', str(dd), '--ut'])
        hit = [e for e in errs if 'input ext:rom/%s changed' % ut_fw in e]
        # ONLY the card's films, on every monitor. Matching '-ut.mp4'
        # here stopped being right when the phosphor suffix landed, so
        # this asks the one place that defines the card-file shape.
        def _label_file(e):
            return e.split(':', 1)[0].rsplit('/', 1)[-1]
        assert hit and all(UT_FILE_RE.search(_label_file(e))
                           for e in errs), errs[:4]
        assert len(hit) >= 1
        say('the UltraTerm firmware the -ut films show changed (-ut films only)', hit[0])
        (va / 'sim/roms' / ut_fw).write_bytes(('fixture sim/roms/' + ut_fw).encode())
        (va / 'sim/roms' / 'iie_cd_ef.rom').write_bytes(b'another //e ROM')
        errs = go(d, ['--demos', str(dd), '--ut'])
        assert any('input ext:rom/iie_cd_ef.rom changed' in e
                   and not UT_FILE_RE.search(_label_file(e))
                   for e in errs), errs[:3]
        say('the //e ROM changed (every film)',
            [e for e in errs if 'iie_cd_ef' in e][0])
        (va / 'sim/roms' / 'iie_cd_ef.rom').write_bytes(b'fixture sim/roms/iie_cd_ef.rom')

        # the ffmpeg that encoded them is not the one on PATH now
        d = fresh()
        films(dd)
        errs = go(d, ['--demos', str(dd), '--ut'], ff='ffmpeg version 9.9')
        hit = [e for e in errs if 'stale -- ffmpeg is now' in e]
        assert hit, 'a changed ffmpeg accepted: %s' % errs[:3]
        say('ffmpeg is another version than the films were encoded with', hit[0])
        errs = go(d, ['--demos', str(dd), '--ut'], ff=None)
        hit = [e for e in errs if 'ffmpeg is not on PATH' in e]
        assert hit, 'no ffmpeg accepted: %s' % errs[:3]
        say('no ffmpeg to compare the encoder version with', hit[0])
        # an image or floppy that is not here cannot vouch for the films
        d = fresh()
        films(dd)
        gone = {k: str(scratch / 'nowhere' / k) for k in imgs_all}
        errs = go(d, ['--demos', str(dd)], images=gone)
        hit = [e for e in errs if 'is absent, so the film cannot be checked' in e]
        assert hit, 'absent images accepted: %s' % errs[:3]
        say('the disk images absent where the films are checked', hit[0])
        errs = go(d, ['--demos', str(dd)],
                  floppies={k: str(scratch / 'nowhere' / k) for k in flops})
        hit = [e for e in errs if 'the floppy' in e and 'absent' in e]
        assert hit, 'absent floppy accepted: %s' % errs[:3]
        say('the slot-6 floppy absent where the films are checked', hit[0])
        # UT=0: every demo the site publishes has its films
        for name, expect, drop in (
                ('UT=0: a poster missing',
                 'demos/man: no ' + demo_stamp.out_name(
                     'poster', 'man', '', DEF_PH),
                 ('man/' + demo_stamp.out_name(
                     'poster', 'man', '', DEF_PH),)),
                ('UT=0: a webm with its mp4 missing',
                 'demos/man: no ' + demo_stamp.out_name(
                     'mp4', 'man', '', DEF_PH),
                 ('man/' + demo_stamp.out_name('mp4', 'man', '', DEF_PH),)),
                ('UT=0: captions missing', 'demos/jobs: no jobs.vtt',
                 ('jobs/jobs.vtt',))):
            d = fresh()
            films(dd, drop)
            errs = go(d, ['--demos', str(dd)])
            hit = [e for e in errs if expect in e]
            assert hit, 'defect NOT caught: %s (got %s)' % (name, errs[:3])
            say(name, hit[0])
        d = fresh()
        films(dd)
        for other in sorted(dd.iterdir()):
            if other.name != 'man':
                shutil.rmtree(other)
        for ut in ([], ['--ut']):
            errs = go(d, ['--demos', str(dd)] + ut)
            want_j = 'demos/jobs: no ' + demo_stamp.out_name(
                'mp4', 'jobs', '', DEF_PH)
            hit = [e for e in errs if want_j in e]
            assert hit, 'a records dir holding only man accepted (%s): %s' % (ut, errs[:3])
            say('a records dir holding only man' + (' (UT=1)' if ut else ' (UT=0)'),
                hit[0])
        # the image really is hashed: edit the scratch image under a fresh set
        d = fresh()
        films(dd)
        Path(imgs_all['play']).write_bytes(b'a newer play.po')
        errs = go(d, ['--demos', str(dd)])
        hit = [e for e in errs if 'the disk image it booted changed' in e]
        assert hit, 'a changed image accepted: %s' % errs[:3]
        say('the image file itself changed after the films', hit[0])
        Path(imgs_all['play']).write_bytes(b'image play')
        # UT off: the card's films are not published, so their size is not
        # this build's business, and the bare films still are
        d = fresh()
        films(dd, size={'vi/' + demo_stamp.out_name(
            'mp4', 'vi', '-ut', DEF_PH): (fw, fh - 96)})
        errs = go(d, ['--demos', str(dd)])
        assert not errs, 'a wrong-size card film rejected with UT off: %s' % errs[:3]
        n_rows += 1
        print('  passes as required: UT off ignores the card films\' size and '
              'stamps')

        d = fresh()
        films(dd)
        sub('demos/jobs.py', "backends=('text80', 'ut')", "backends=('text80',)")
        errs = go(d, ['--demos', str(dd), '--ut'])
        hit = [e for e in errs if 'does not declare the card' in e]
        assert hit, 'card files of a one-display demo accepted: %s' % errs[:3]
        say('card files for a demo that does not declare the card', hit[0])
        for name, expect, plant in (
                ('selector data: no-JavaScript link marker lost',
                 'player markup lacks data-display-alt',
                 lambda: sub('build.py', '<p class="display-alt" data-display-alt>',
                             '<p class="display-alt">')),
                ('the plain link to the other film is broken', 'broken link',
                 lambda: sub('build.py',
                             "alt = ut.get('mp4') or ut.get('webm')",
                             "alt = 'nowhere.mp4'")),
                ('the sentence about the card is gone',
                 'no sentence saying what the UltraTerm was',
                 lambda: sub('build.py', 'The Videx UltraTerm was an ',
                             'A video card was an ')),
                ('the default video is the card\'s',
                 'the default <video> is not the //e film',
                 lambda: sub('build.py', "e = film('e', ph0)\n",
                             "e = film('ut', ph0)\n")),
                # the monitor axis has the same hazard as the display
                # one: a default that is not what the buttons say
                ('the default video is not the default monitor',
                 'the default <video> is not the //e film',
                 lambda: sub('build.py', "b, ph0 = base, demo_phos.DEFAULT",
                             "b, ph0 = base, 'amber'")),
                ('display.js missing from the output',
                 'static/display.js is not in the output',
                 lambda: (d / 'static/display.js').unlink()),
                ('captions.js missing from the output',
                 'static/captions.js is not in the output',
                 lambda: (d / 'static/captions.js').unlink()),
                ('the film wrapper is gone',
                 'the player lacks <div class="film">',
                 lambda: sub('build.py', "o.insert(0, '<div class=\"film\">')",
                             "pass")),
                ('display.js re-enables captions on a swap',
                 'makes the swapped-in track default',
                 lambda: sub('static/display.js', 't.label = "English";',
                             't.label = "English"; t.default = true;')),
                ('a leak in display.js', 'leaks the words commons',
                 lambda: sub('static/display.js', 'Optional.',
                             'Optional. commons'))):
            d = fresh()
            films(dd)
            plant()
            errs = go(d, ['--demos', str(dd), '--ut'])
            hit = [e for e in errs if expect in e]
            assert hit, 'defect NOT caught: %s (got %s)' % (name, errs[:3])
            say(name, hit[0])

        # ---- UT off (the default): nothing of the card is published ----
        d = fresh()
        films(dd)
        errs = go(d, ['--demos', str(dd)])
        assert not errs, 'ut off with every film present rejected: %s' % errs[:3]
        # by the card-file shape, not by '-ut.': a glob for that stopped
        # matching the day the monitor suffix landed (vi-ut-paper.mp4),
        # and would have passed a UT=0 build full of card films
        stray = [f.name for f in (scratch / 'out').rglob('*')
                 if f.is_file() and UT_FILE_RE.search(f.name)]
        assert not stray, 'a card file copied: %s' % stray[:3]
        t = (scratch / 'out/watch/vi/index.html').read_text()
        assert 'data-ut' not in t and 'UltraTerm' not in t
        assert not re.search(r'-ut(-(%s))?\.' % '|'.join(demo_phos.NAMES), t)
        # display.js IS shipped with UT off: it drives the monitor
        # selector too, and the three monitors are not the card's
        assert (scratch / 'out/static/display.js').exists()
        n_rows += 1
        print('  passes as required: UT off publishes no card film, link '
              'or sentence, and still ships the monitor selector '
              '(every film present on disk)')
        for name, expect, plant in (
                ('UT off, but the builder ignores the switch',
                 'in a build without --ut',
                 lambda: sub('build.py', 'return bool(self.a.ut)',
                             'return True')),
                ('UT off, but a stray card film is copied',
                 'an UltraTerm file in a build without --ut',
                 lambda: sub('build.py',
                             "if disp == 'ut' and not self.ut_on():",
                             "if False:")),):
            d = fresh()
            films(dd)
            plant()
            errs = go(d, ['--demos', str(dd)])
            hit = [e for e in errs if expect in e]
            assert hit, 'defect NOT caught: %s (got %s)' % (name, errs[:3])
            say(name, hit[0])

        # ---- a lesson page needs its session file ----------------------
        d = fresh()
        none = scratch / 'no-sessions'
        none.mkdir()
        errs = go(d, ['--examples', str(none)])
        hit = [e for e in errs if 'no session file' in e]
        assert hit, 'lesson pages with no session files accepted: %s' % errs[:3]
        say('lesson page whose session file is missing', hit[0])
        empty = scratch / 'empty-session'
        for lid in sorted(p.name for p in sessions.iterdir() if p.is_dir()):
            (empty / lid).mkdir(parents=True)
            (empty / lid / 'session.txt').write_text('')
        errs = go(d, ['--examples', str(empty)])
        hit = [e for e in errs if 'no session file' in e]
        assert hit, 'empty session files accepted: %s' % errs[:3]
        say('lesson page whose session file is empty', hit[0])
        # a session records the sha256 of the build/full.po it ran on
        import hashlib
        fake = scratch / 'full-a.po'
        fake.write_bytes(b'one disk')
        other = scratch / 'full-b.po'
        other.write_bytes(b'another disk')
        ours = scratch / 'ours'
        for lid in sorted(p.name for p in sessions.iterdir() if p.is_dir()):
            (ours / lid).mkdir(parents=True)
            body = (sessions / lid / 'session.txt').read_text().split('\n')
            body = [x for x in body if not x.startswith('#! ')]
            sha = hashlib.sha256(b'one disk').hexdigest()
            (ours / lid / 'session.txt').write_text(
                '\n'.join(['#! revision test', '#! full.po sha256 ' + sha] + body))
        errs = go(d, ['--examples', str(ours), '--full-image', str(fake)])
        assert not errs, 'sessions of the current disk rejected: %s' % errs[:3]
        n_rows += 1
        print('  passes as required: a session of the current build/full.po')
        errs = go(d, ['--examples', str(ours), '--full-image', str(other)])
        hit = [e for e in errs if 'stale session' in e]
        assert hit, 'a session of another disk accepted: %s' % errs[:3]
        say('lesson session of another build/full.po', hit[0])
        nohdr = scratch / 'nohdr'
        for lid in sorted(p.name for p in sessions.iterdir() if p.is_dir()):
            (nohdr / lid).mkdir(parents=True)
            body = [x for x in (sessions / lid / 'session.txt').read_text().split('\n')
                    if not x.startswith('#! ')]
            (nohdr / lid / 'session.txt').write_text('\n'.join(body))
        errs = go(d, ['--examples', str(nohdr), '--full-image', str(fake)])
        hit = [e for e in errs if 'stale session' in e]
        assert hit, 'a session with no recorded disk accepted: %s' % errs[:3]
        say('lesson session with no recorded disk', hit[0])
        errs = go(d, ['--skip-lessons', '--examples', str(none)])
        assert not errs, '--skip-lessons build is not clean: %s' % errs[:3]
        n_rows += 1
        print('  passes as required: --skip-lessons builds with no sessions')

        # ---- a whole-tree copy with no .git (the box) -----------------
        def fresh_root(tag):
            r = scratch / tag
            if r.exists():
                shutil.rmtree(r)
            r.mkdir()
            for name in COPY:
                src = root / name
                if src.is_dir():
                    shutil.copytree(src, r / name, ignore=shutil.ignore_patterns('__pycache__'))
                elif src.is_file():
                    shutil.copy(src, r / name)
            return r

        def go_root(r):
            errs, _ = run(r, r / 'site', scratch / 'outroot', extra, full=True,
                          roster=small_roster)
            return errs

        r = fresh_root('r1')
        assert not (r / '.git').exists()
        os.environ.pop('MAUX_REVISION', None)
        errs = go_root(r)
        assert not errs, 'no-.git tree does not pass: %s' % errs[:3]
        home = (scratch / 'outroot' / 'index.html').read_text()
        assert 'Built from revision' not in home, 'revision printed with no .git'
        n_rows += 1
        print('  passes as required: a tree with no .git (repo: links, facts; revision omitted)')
        os.environ['MAUX_REVISION'] = 'abc1234'
        try:
            errs = go_root(r)
            assert not errs
            assert 'Built from revision <code>abc1234</code>' in \
                (scratch / 'outroot' / 'index.html').read_text()
        finally:
            os.environ.pop('MAUX_REVISION', None)
        n_rows += 1
        print('  passes as required: MAUX_REVISION supplies the revision with no .git')

        def break_stub(r):
            p = r / 'site/build.py'
            p.write_text(p.read_text().replace('badge stub', 'badge xx'))

        def break_licence(r):
            p = r / 'docs/man/licenses.1'
            p.write_text(p.read_text().replace('Copyright(C) Caldera International Inc.',
                                               'Copyright(C) Caldera Intl'))

        man_cases = [
            ('man: roster command with no page', 'no page',
             lambda r: (r / 'docs/man/cat.1').unlink()),
            ('man: stub without its badge', 'stub without its badge', break_stub),
            ('man: licences without the required notice', 'required notice', break_licence),
        ]
        for name, expect, plant in man_cases:
            r = fresh_root('r2')
            plant(r)
            errs = go_root(r)
            hit = [e for e in errs if expect in e]
            assert hit, 'defect NOT caught: %s (got %s)' % (name, errs[:3])
            say(name, hit[0])

        # ---- the browser link ------------------------------------------
        d = fresh()
        local = ['--apple2ts-url', 'http://127.0.0.1:9/', '--image-url', 'http://127.0.0.1:9/maux.po']
        errs, _ = run(root, d, scratch / 'out', extra + local, full=False)
        hit = [e for e in errs if 'localhost' in e]
        assert hit, 'localhost build settings accepted without --local-preview: %s' % errs[:3]
        say('localhost --image-url without --local-preview', hit[0])
        errs, _ = run(root, d, scratch / 'out', extra + local, full=False, local_ok=True)
        assert not errs, errs[:3]
        tryp = (scratch / 'out/try/index.html').read_text()
        assert 'class="emustart"' in tryp and 'ramdisk=1024' in tryp \
            and 'capslock=off' in tryp and 'hd1=' in tryp, \
            '/try/ lacks the configured emulator when the image IS hosted'
        page = (scratch / 'out/get/index.html').read_text()
        assert TRY_LABEL in page and '../try/index.html' in page, \
            '/get/ does not send the reader to /try/'
        assert 'apple2ts' not in page, \
            '/get/ links the emulator directly; one page boots maux'
        home = (scratch / 'out/index.html').read_text()
        assert TRY_LABEL in home and 'try/index.html' in home, \
            'the home page lacks the boot button when the image IS hosted'
        errs, _ = run(root, d, scratch / 'out', extra, full=False)
        assert not errs
        assert TRY_LABEL not in (scratch / 'out/get/index.html').read_text(), \
            'button emitted with no absolute image URL'
        assert 'class="emustart"' not in (
            scratch / 'out/try/index.html').read_text(), \
            'the emulator was embedded with no absolute image URL'
        # the home page stays SILENT with no public image: /get/ and /try/
        # carry the "goes live with the release" sentence, the front page
        # promises nothing it cannot do yet.
        home = (scratch / 'out/index.html').read_text()
        assert TRY_LABEL not in home, \
            'home page emitted the button with no absolute image URL'
        assert 'goes live with the release' not in home, \
            'home page emitted a placeholder instead of staying silent'
        for rel in ('get', 'try'):
            assert 'goes live with the release' in (
                scratch / ('out/%s/index.html' % rel)).read_text(), \
                '/%s/ lost its explanation of why there is no emulator yet' % rel
        n_rows += 6
        print('  passes as required: --local-preview embeds the configured '
              'emulator (ramdisk=1024, capslock=off, hd1=) on /try/ and points '
              '/get/ and the home page at it; the default build has neither, '
              'and the home page stays silent rather than promising one')

        # ---- and the teeth of that: one defect at a time, in a build
        # that DOES have an image to boot (the rows above only prove the
        # page is built; these prove a broken page is caught).
        for name, expect, plant in (
            ('a boot URL that has lost capslock=off', 'lacks capslock=off',
             lambda: sub('build.py', "'&capslock=off&hd1=%s'", "'&hd1=%s'")),
            ('a boot URL that has lost the mouse card', 'lacks slot5=mouse',
             lambda: sub('build.py', "&slot4=mockingboard&slot5=mouse'",
                         "&slot4=mockingboard'")),
            ('the facade with no script to animate it', 'lacks static/tryemu.js',
             lambda: sub('build.py',
                         "'<script src=\"/static/tryemu.js\" defer></script>\\n'",
                         "''")),
            ('a script that cannot find the block it wires',
             'lacks querySelectorAll("div.emu")',
             lambda: sub('static/tryemu.js', 'querySelectorAll("div.emu")',
                         'querySelectorAll("div.emuX")')),
            ('a facade that swallows a cmd-click', 'lacks metaKey',
             lambda: sub('static/tryemu.js', 'ev.metaKey || ', '')),
            ('/get/ linking the emulator instead of /try/',
             'bypassing /try/',
             lambda: sub('build.py', '<p><a class="trylink" href="/try/">',
                         '<p><a class="trylink" href="https://apple2ts.com/">')),
            ('a frame that carries the emulator\'s own panels too',
             'frame source lacks appmode=embed',
             lambda: sub('build.py', 'data-frame-src="%s%sappmode=embed"',
                         'data-frame-src="%s%s"')),
            ('the canvas-only build handed to the link OUT',
             'link OUT is the canvas-only build',
             lambda: sub('build.py',
                         "% (href, sep, demo_phos.DEFAULT, DISPLAYS[0][2], href))",
                         "% (href, sep, demo_phos.DEFAULT, DISPLAYS[0][2], "
                         "href + sep + 'appmode=embed'))")),
            ('the chin losing the films\' phosphor key',
             'lacks "maux-phosphor"',
             lambda: sub('static/tryemu.js', 'var PKEY = "maux-phosphor"',
                         'var PKEY = "maux-try-phosphor"')),
            ('a phosphor that tints the canvas instead of the monitor',
             'phosphor is the monitor, not a tint',
             lambda: sub('static/tryemu.js', 'f.className = "emuframe";',
                         'f.className = "emuframe"; f.style.filter = "sepia(1)";')),
            ('a screen with no default phosphor', 'does not name its default',
             # the film player carries the same attribute and comes
             # first in the file, so this names the emulator's own
             lambda: sub('build.py', 'data-phosphor="%s" data-display-name=',
                         'data-phosphor-x="%s" data-display-name=')),
            ('a script that ignores the frame source',
             'lacks getAttribute("data-frame-src")',
             lambda: sub('static/tryemu.js', 'getAttribute("data-frame-src")',
                         'getAttribute("data-frame-srcX")')),
            ('the frame styled out of the stylesheet',
             'lacks .emuframe { display: block',
             lambda: sub('static/style.css', '.emuframe { display: block',
                         '.emuframeX { display: block')),
        ):
            d = fresh()
            plant()
            errs, _ = run(root, d, scratch / 'out', extra + local, full=False,
                          local_ok=True)
            hit = [e for e in errs if expect in e]
            assert hit, 'defect NOT caught: %s (got %s)' % (name, errs[:3])
            say(name, hit[0])
        d = fresh()

        # ---- the dirty marker -------------------------------------------
        spec = importlib.util.spec_from_file_location('site_facts_check', root / 'site/facts.py')
        sitefacts = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sitefacts)
        g = scratch / 'gitrepo'
        g.mkdir()
        env = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t',
                   GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t')
        os.environ.pop('MAUX_REVISION', None)
        for cmd in (['git', 'init', '-q'], ['git', 'add', 'f'], ['git', 'commit', '-qm', 'x']):
            if cmd[1] == 'add':
                (g / 'f').write_text('1\n')
            subprocess.run(cmd, cwd=g, env=env, check=True, capture_output=True)
        clean = sitefacts.revision(g)
        (g / 'f').write_text('2\n')
        dirty = sitefacts.revision(g)
        assert clean and not clean.endswith('-dirty') and dirty == clean + '-dirty', (clean, dirty)
        n_rows += 1
        print('  passes as required: revision gains -dirty when tracked files are modified')

        # ---- the local preview server honours Range (films must seek) ----
        import http.client
        import threading
        sys.path.insert(0, str(root / 'scripts'))
        import functools
        import serve_cors
        sd = scratch / 'serve'
        sd.mkdir()
        (sd / 'f.bin').write_bytes(bytes(range(256)) * 8)
        srv = serve_cors.http.server.ThreadingHTTPServer(
            ('127.0.0.1', 0), functools.partial(serve_cors.Handler,
                                                directory=str(sd)))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            def get(rng):
                c = http.client.HTTPConnection('127.0.0.1', srv.server_port)
                c.request('GET', '/f.bin', headers={'Range': rng} if rng else {})
                r = c.getresponse()
                return r.status, dict(r.getheaders()), r.read()
            st, h, body = get('bytes=1000-1999')
            assert st == 206 and body == (bytes(range(256)) * 8)[1000:2000] \
                and h['Content-Range'] == 'bytes 1000-1999/2048' \
                and h['Accept-Ranges'] == 'bytes', (st, h, len(body))
            st, h, body = get('bytes=2000-')
            assert st == 206 and len(body) == 48, (st, len(body))
            st, h, body = get('bytes=5000-6000')
            assert st == 416 and h['Content-Range'] == 'bytes */2048', (st, h)
            st, h, body = get('bytes=50-10')
            assert st == 200 and len(body) == 2048, ('malformed range', st)
            st, h, body = get(None)
            assert st == 200 and len(body) == 2048, (st, len(body))
        finally:
            srv.shutdown()
        n_rows += 1
        print('  passes as required: serve_cors answers Range with 206, 416 '
              'when unsatisfiable, and the whole file without one')

        print('PASS site gate mutations: %d rows (each planted defect red; the no-.git, '
              'local-preview and dirty-marker rows green)' % n_rows)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--root', default=str(ROOT))
    ap.add_argument('--no-self-test', action='store_true')
    ap.add_argument('--ut', action='store_true',
                    help='the build publishes the UltraTerm films (make '
                         'check-site UT=1)')
    ap.add_argument('--local-preview', action='store_true',
                    help='allow localhost links (a build made with --local-preview)')
    a = ap.parse_args()
    root = Path(a.root).resolve()
    cache = root / 'build/site-cache'
    if not a.no_self_test:
        self_test(root, cache)
    errs, b = run(root, root / 'site', root / 'build/site',
                  ['--cache', str(cache)] + (['--ut'] if a.ut else []),
                  full=True, local_ok=a.local_preview)
    if errs:
        for e in errs:
            print('FAIL site:', e)
        return 1
    n = sum(1 for _ in (root / 'build/site').rglob('index.html'))
    vids = sorted(p.name for p in (root / 'build/site/watch').rglob('*.mp4'))
    print('PASS site: %d pages, %d man pages, every link and fragment resolves, %d facts used%s'
          % (n, len(b.man), len(b.used_facts),
             '; video present: ' + ', '.join(vids) if vids else '; no video in this build'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
