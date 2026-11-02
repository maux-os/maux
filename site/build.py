#!/usr/bin/env python3
"""maux site generator (docs/SITE.md sec 6.4 and 7; docs/SITEGEN.md).

Python stdlib only. Reads site/pages/**/*.html (ASCII fragments with a
small header block), site/templates/page.html, site/static/*, the man
pages in docs/man, the demos in site/demos and, when they exist, the
videos in build/demos. Writes a static tree to build/site/.

Placeholders in a page:
    {{fact:NAME}}    a number from site/facts.py (missing = build error)
    {{svg:NAME}}     inline site/static/diagrams/NAME.svg
    {{demo:NAME}}    names a demo (site/demos/NAME.py must exist)
    {{gen:NAME}}     a generated block (see GEN below)
    {{file:PATH}}    a file of examples/, included verbatim (never retyped)
Links: write them root-relative ("/architecture/"); the build rewrites every one
to a path relative to the page, because the site is served from a
sub-path (https://maux-os.github.io/maux/) and must also open from disk.
"repo:docs/X.md" in an href becomes a link into the release repository
and must name a tracked file.

A page under learn/ is a lesson page: its header names a lesson
(`lesson: l3`), and it is built only if scripts/check_examples.py declares
that lesson (LESSON_IDS, read by ast, like the demos) and has a row for it
(row_l3) and the gate's session file build/examples/l3/session.txt exists.
{{gen:session}} includes that file, so the page shows a session that passed.

Any problem is collected and reported together; exit status 1.
"""
import argparse
import ast
import json
import types
import hashlib
import html
import importlib.util
import re
import shutil
import subprocess
import sys
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

# The film file names are the RECORDER's, read from the recorder rather
# than spelled again here: a site that writes its own copy of the naming
# scheme publishes dead links the day the scheme moves, and the 2 x 3
# phosphor matrix moved it (docs/DEMO-PHOSPHOR.md).
sys.path.insert(0, str(ROOT / 'scripts'))
import demo_phos                                             # noqa: E402
import demo_stamp                                            # noqa: E402

# (key in the markup, the recorder's filename suffix, what to call it)
DISPLAYS = (('e', '', 'Apple IIe 80-column'),
            ('ut', '-ut', 'Videx UltraTerm'))

NAV = [('', 'Home'), ('watch', 'Watch'), ('learn', 'Learn'), ('try', 'Try'),
       ('get', 'Get'),
       ('dev', 'Dev'), ('man', 'Man'), ('architecture', 'Architecture'),
       ('conformance', 'Conformance'), ('about', 'About')]

# The Watch index: groups in order, each demo with one line about it
# (HTML, ASCII only). A demo missing from here is a build error.
GALLERY = (
    ('Unix', (
        ('firstmin', 'Look around: list the disk, count the programs, run a pipeline, and see that every process is a bank.'),
        ('jobs', 'Kill a pipeline with ^C, suspend an editor with ^Z, and bring it back with fg.'),
        ('fedgrep', 'Rebuild grep from ed&rsquo;s g/re/p as a shell script, and check it against the real one on the Federalist Papers.'),
        ('diffed', 'diff -e writes an ed script. Feed it to ed and one file becomes the other.'),
        ('findexec', 'Walk the manual with find and run grep on every page that matches.'),
        ('vi', 'Pipe the buffer through sort, tr and nl without leaving the editor.'),
        ('man', 'Page through sh(1), search it, and get your screen back.'),
        ('twocons', 'Leave a job running on one console, use vi on another, and come back to find it still going.'),
    )),
    ('Developing', (
        ('hello', 'Write it in vi, assemble it with nas, link it with ld, run it.'),
        ('hellopla', 'The same in PLASMA: write it, compile it with plasm, run it.'),
        ('typo', 'Break one letter, read the assembler&rsquo;s error, fix it in vi and rebuild.'),
        ('stopvi', 'Stop vi mid-edit, build in the background, then pick up where you left off.'),
        ('lssys', 'Build a ProDOS 8 program on maux and run it on ProDOS itself with bye.'),
        ('warmstart', 'A program launched again skips loading: the kernel kept its bank.'),
    )),
    ('The Apple II side', (
        ('mount', 'Attach a disk image as a volume, read it, and let it go.'),
        ('unshrink', 'Unpack a real ShrinkIt archive with nulib2 and read the documentation inside.'),
        ('ddshrink', 'Image a floppy with dd straight into a ShrinkIt archive, then prove it matches the original.'),
    )),
)


FILM_IMAGES = FILM_FLOPPIES = None   # self-test hooks (check_films)
FILM_FFMPEG = 'probe'
FILM_ENV = None


class Build:
    def __init__(self, a):
        self.a = a
        self.root = Path(a.root).resolve()
        self.site = Path(a.site).resolve()
        self.out = Path(a.out).resolve()
        self.demos_out = Path(a.demos).resolve()
        self.examples_out = Path(a.examples).resolve()
        self.full_image = Path(a.full_image).resolve()
        self.cache = Path(a.cache).resolve()
        self.errors = []
        self.tryit_refused = False
        self.used_facts = set()
        self.pages = {}          # route dir ('' for home) -> dict
        self.lessons = {}        # lesson id -> route (check_lessons)
        self.cur_lesson = None
        self.man = {}            # name -> dict(kind, desc, ...)
        self.facts = None
        self.fact_values = {}
        self.tracked = None

    def err(self, msg):
        self.errors.append(msg)

    # ------------------------------------------------------------ setup
    def load_facts(self):
        path = self.site / 'facts.py'
        spec = importlib.util.spec_from_file_location('site_facts_' +
                                                      hashlib.md5(str(path).encode()).hexdigest()[:6], path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        self.facts = mod
        cpath = self.site / 'conformance.py'
        cspec = importlib.util.spec_from_file_location(
            'site_conformance_' + hashlib.md5(str(cpath).encode()).hexdigest()[:6], cpath)
        cmod = importlib.util.module_from_spec(cspec)
        cspec.loader.exec_module(cmod)
        self.conf_rows = cmod.ROWS

    def tracked_files(self):
        if self.tracked is None:
            self.tracked = self.facts.tracked(self.root)
        return self.tracked

    def check_ascii_sources(self):
        for p in sorted(self.site.rglob('*')):
            if p.is_file() and '__pycache__' not in p.parts and \
               p.suffix in ('.html', '.css', '.svg', '.py', '.txt', '') \
               and p.parent.name != 'demos':
                data = p.read_bytes()
                bad = [i for i, c in enumerate(data) if c >= 128]
                if bad:
                    line = data[:bad[0]].count(b'\n') + 1
                    self.err('non-ASCII byte in %s line %d'
                             % (p.relative_to(self.site), line))

    # ------------------------------------------------------------ pages
    def load_pages(self):
        pdir = self.site / 'pages'
        for p in sorted(pdir.rglob('*.html')):
            rel = p.relative_to(pdir)
            parts = list(rel.with_suffix('').parts)
            if parts[-1] == 'index':
                parts.pop()
            route = '/'.join(parts)
            text = p.read_text()
            head, sep, body = text.partition('\n---\n')
            if not sep:
                self.err('%s: no "---" line ending the header block' % rel)
                continue
            meta = {}
            for line in head.split('\n'):
                if not line.strip():
                    continue
                k, s, v = line.partition(':')
                if not s:
                    self.err('%s: bad header line %r' % (rel, line))
                    continue
                meta[k.strip()] = v.strip()
            for need in ('title', 'description'):
                if not meta.get(need):
                    self.err('%s: header lacks %s' % (rel, need))
            self.pages[route] = dict(meta=meta, body=body, src=str(rel))

    # ------------------------------------------------------------ demos
    def demo_info(self):
        d = self.site / 'demos'
        info = {}
        for p in sorted(d.glob('*.py')):
            tree = ast.parse(p.read_text())
            consts, demo = {}, None
            for n in tree.body:
                if isinstance(n, ast.Assign) and len(n.targets) == 1 and \
                   isinstance(n.targets[0], ast.Name):
                    name = n.targets[0].id
                    if name == 'DEMO' and isinstance(n.value, ast.Call):
                        demo = {k.arg: ast.literal_eval(k.value)
                                for k in n.value.keywords}
                    else:
                        try:
                            consts[name] = ast.literal_eval(n.value)
                        except (ValueError, SyntaxError):
                            pass
            if demo is None:
                self.err('demo %s: no DEMO = dict(...)' % p.name)
                continue
            run = [n for n in tree.body
                   if isinstance(n, ast.FunctionDef) and n.name == 'run']
            cmds, says, typed = [], [], []
            keyenv = {'t': types.SimpleNamespace(
                CTRL_C='\x03', CTRL_D='\x04', CTRL_Z='\x1a', ESC='\x1b')}
            for node in ast.walk(run[0] if run else tree):
                if isinstance(node, ast.Call) and \
                   isinstance(node.func, ast.Attribute):
                    f = node.func.attr
                    if f == 'enter':
                        typed.append((node.lineno, 'keys', '\r'))
                        continue
                    if f not in ('run_cmd_echoed', 'say', 'type_and_expect_echo',
                                 'type_human', 'press') or not node.args:
                        continue
                    try:
                        val = eval(compile(ast.Expression(node.args[0]),
                                           '<demo>', 'eval'),
                                   {'__builtins__': {}},
                                   dict(consts, **keyenv))
                    except Exception as e:  # noqa
                        if f == 'press':   # a loop variable: not a listing
                            continue
                        if f == 'say':
                            # a caption built at run time (a figure the
                            # film measured): the page takes it from the
                            # published .vtt, see gen_democaptions
                            says.append((node.lineno, None))
                            continue
                        self.err('demo %s: cannot evaluate a %s argument: %s'
                                 % (p.name, f, e))
                        continue
                    if f == 'say':
                        says.append((node.lineno, val))
                    elif f == 'run_cmd_echoed':
                        cmds.append((node.lineno, val))
                        typed.append((node.lineno, 'line', val))
                    elif f == 'type_and_expect_echo':
                        typed.append((node.lineno, 'line', val))
                    else:
                        typed.append((node.lineno, 'keys', val))
            if 'backend' in demo and 'backends' in demo:
                self.err('demo %s: DEMO has both backend and backends' % p.name)
            bk = demo.get('backends', (demo.get('backend'),))
            demo['backends'] = tuple(bk)
            demo['commands'] = [v for _, v in sorted(cmds)]
            demo['says'] = [v for _, v in sorted(says)]
            demo['typed'] = [(k, v) for _, k, v in sorted(typed)]
            demo['script'] = consts.get('SCRIPT')
            demo['doc'] = ast.get_docstring(tree) or ''
            info[demo['name']] = demo
            if demo['name'] != p.stem:
                self.err('demo %s: DEMO name %r != file name' % (p.name, demo['name']))
        heroes = sorted(n for n, d in info.items() if d.get('hero'))
        if info and len(heroes) != 1:
            self.err('exactly one demo must say hero=True in its DEMO dict '
                     '(the Home page plays it); found %d: %s'
                     % (len(heroes), ', '.join(heroes) or 'none'))
        return info

    def ut_on(self):
        """The UltraTerm films are published only with --ut, which the
        Makefile passes by default (UT ?= 1). It was off while the
        console programmed a 16-line cell the glyphs did not fill
        (SH-DEFECTS item 9); that is fixed -- UT_INIT copies the card's
        own format-4 CRTC entry from $CF55 -- and the films were
        re-recorded on the original v1 card, so both displays publish.
        Off (UT=0) means no selector, no link, no sentence about the
        card, no -ut file, and no display.js in the output."""
        return bool(self.a.ut)

    def demo_files(self, name):
        """{(display, kind, phosphor): path} for the files that exist.

        The //e's files carry the bare names and the UltraTerm's carry
        -ut; the video and the poster carry the monitor as well
        (NAME-ut-amber.mp4, poster-amber.png), because a display is
        recorded once and encoded through each phosphor. The captions
        and the transcript are per display only -- the three films of
        one display are the same frames. Names come from
        demo_stamp.out_names; only the transcript, which is not a
        published KIND, is spelled here. docs/DEMO-PHOSPHOR.md."""
        d = self.demos_out / name
        files = {}
        for disp, suffix, _label in DISPLAYS:
            if disp == 'ut' and not self.ut_on():
                continue
            names = dict(demo_stamp.out_names(name, suffix))
            names[('transcript', None)] = 'transcript%s.txt' % suffix
            for (kind, ph), fn in names.items():
                if (d / fn).is_file():
                    files[(disp, kind, ph)] = d / fn
        return files

    # ------------------------------------------------------------ lessons
    def lesson_info(self):
        """(ids, rows) declared by scripts/check_examples.py: the lesson
        ids in LESSON_IDS and the names of its row_* functions."""
        p = self.root / 'scripts/check_examples.py'
        if not p.is_file():
            self.err('scripts/check_examples.py is missing: no lesson has a row')
            return set(), set()
        tree = ast.parse(p.read_text())
        ids = set()
        for n in tree.body:
            if isinstance(n, ast.Assign) and len(n.targets) == 1 and \
               isinstance(n.targets[0], ast.Name) and n.targets[0].id == 'LESSON_IDS':
                try:
                    ids = set(ast.literal_eval(n.value))
                except (ValueError, SyntaxError):
                    self.err('check_examples.py: LESSON_IDS is not a literal')
        rows = {n.name for n in tree.body
                if isinstance(n, ast.FunctionDef) and n.name.startswith('row_')}
        return ids, rows

    def session_path(self, lid):
        return self.examples_out / lid / 'session.txt'

    def session(self, lid):
        """(header, lines) of a lesson's session file. The header is the
        leading `#! key value` lines check-examples wrote (the revision and
        the sha256 of the build/full.po it ran on); the page never shows
        them."""
        head, lines = {}, []
        for ln in self.session_path(lid).read_text().split('\n')[:-1]:
            if not lines and ln.startswith('#! '):
                k, _, v = ln[3:].partition(' ')
                if k == 'full.po':
                    v = v.replace('sha256 ', '', 1)
                head[k] = v
            else:
                lines.append(ln)
        return head, lines

    def current_image_sha(self):
        if not hasattr(self, '_image_sha'):
            self._image_sha = None
            if self.full_image.is_file():
                h = hashlib.sha256()
                with open(self.full_image, 'rb') as f:
                    for chunk in iter(lambda: f.read(1 << 20), b''):
                        h.update(chunk)
                self._image_sha = h.hexdigest()
        return self._image_sha

    def rel_to_root(self, p):
        try:
            return str(Path(p).relative_to(self.root))
        except ValueError:
            return str(p)

    def check_lessons(self):
        """A lesson page exists only for a lesson with a check-examples row
        and a session file; a page under learn/ is a lesson page."""
        ids, rows = self.lesson_info()
        self.lessons = {}
        for route, pg in sorted(self.pages.items()):
            lid = pg['meta'].get('lesson')
            if route.startswith('learn/') and not lid:
                self.err('page %s: under learn/ but has no "lesson:" header'
                         % pg['src'])
                continue
            if not lid:
                continue
            if not route.startswith('learn/'):
                self.err('page %s: a "lesson:" header outside learn/' % pg['src'])
                continue
            if lid not in ids:
                self.err('page %s: lesson %r has no check-examples row '
                         '(not in LESSON_IDS of scripts/check_examples.py)'
                         % (pg['src'], lid))
                continue
            if 'row_' + lid not in rows:
                self.err('page %s: lesson %r is declared but scripts/'
                         'check_examples.py has no row_%s function'
                         % (pg['src'], lid, lid))
                continue
            sp = self.session_path(lid)
            if not sp.is_file() or not sp.read_text().strip():
                self.err('page %s: lesson %r has no session file %s '
                         '(run make check-examples)'
                         % (pg['src'], lid, self.rel_to_root(sp)))
                continue
            head, _ = self.session(lid)
            cur = self.current_image_sha()
            if cur and head.get('full.po') != cur:
                self.err('page %s: stale session for lesson %r: it ran on '
                         'a build/full.po of sha256 %s, not the current %s: '
                         'run make check-examples'
                         % (pg['src'], lid, (head.get('full.po') or 'none')[:12],
                            cur[:12]))
                continue
            if lid in self.lessons:
                self.err('lesson %s: two pages (%s, %s)'
                         % (lid, self.lessons[lid], route))
            self.lessons[lid] = route

    # ------------------------------------------------------------ markup
    def md_inline(self, text):
        """Tiny inline converter for lifted doc text: `code`, **bold**,
        [text](target). Everything else is escaped."""
        text = scrub_handles(text)
        out, i = [], 0
        pat = re.compile(r'`([^`]+)`|\*\*(.+?)\*\*|\[([^\]]+)\]\(([^)]+)\)')
        for m in pat.finditer(text):
            out.append(html.escape(text[i:m.start()], quote=False))
            if m.group(1) is not None:
                out.append('<code>%s</code>' % html.escape(m.group(1), quote=False))
            elif m.group(2) is not None:
                out.append('<strong>%s</strong>' % self.md_inline(m.group(2)))
            else:
                tgt = m.group(4)
                if not re.match(r'https?:', tgt):
                    tgt = 'repo:' + tgt.lstrip('./')
                    tgt = re.sub(r'#.*$', '', tgt)
                out.append('<a href="%s">%s</a>' % (tgt, html.escape(m.group(3), quote=False)))
            i = m.end()
        out.append(html.escape(text[i:], quote=False))
        return ''.join(out)

    @staticmethod
    def md_plain(text):
        text = scrub_handles(text)
        text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'\1', text)
        return text.replace('`', '').replace('**', '')

    def md_table(self, lines, what):
        """Render a pipe table; assert the round trip (learning
        01M0KXP2S11CFQ0HYZVS5P889Z): the rendered text equals the source."""
        rows = []
        for ln in lines:
            cells = [c.strip() for c in ln.strip().strip('|').split(' | ')] \
                if ' | ' in ln else [c.strip() for c in ln.strip().strip('|').split('|')]
            rows.append(cells)
        header, body = rows[0], rows[2:]
        o = ['<div class="tablewrap"><table>', '<thead><tr>']
        o += ['<th>%s</th>' % self.md_inline(c) for c in header]
        o.append('</tr></thead><tbody>')
        for r in body:
            o.append('<tr>' + ''.join('<td>%s</td>' % self.md_inline(c) for c in r) + '</tr>')
        o.append('</tbody></table></div>')
        rendered = '\n'.join(o)
        for r in [header] + body:
            for c in r:
                got = html.unescape(re.sub(r'<[^>]+>', '', self.md_inline(c)))
                if got != self.md_plain(c):
                    self.err('%s: round trip differs for cell %r' % (what, c[:40]))
        return rendered

    def doc_table(self, rel, first_header):
        text = (self.root / rel).read_text()
        lines = text.split('\n')
        start = None
        for i, ln in enumerate(lines):
            if ln.startswith('|') and first_header in ln:
                start = i
                break
        if start is None:
            self.err('%s: no table starting with %r' % (rel, first_header))
            return [], ''
        end = start
        while end < len(lines) and lines[end].startswith('|'):
            end += 1
        tbl = lines[start:end]
        return tbl, self.md_table(tbl, rel)

    # ------------------------------------------------------------ man
    def render_man(self):
        mandoc = self.a.mandoc
        try:
            ver = subprocess.run([mandoc, '-V'], capture_output=True, text=True)
            vtag = (ver.stdout + ver.stderr).strip()
        except OSError:
            self.err('mandoc not found (%s); set MANDOC' % mandoc)
            return
        sys.path.insert(0, str(self.root / 'scripts'))
        try:
            pages, r, stubs, other = self.facts.man_counts(self.root)
        except self.facts.FactError as e:
            self.err('man: %s' % e)
            return
        finally:
            sys.path.pop(0)
        names = sorted(pages)
        if self.a.man_only:
            keep = set(self.a.man_only.split(','))
            names = [n for n in names if n in keep]
        self.cache.mkdir(parents=True, exist_ok=True)
        for n in names:
            src = pages[n]
            kind = 'command' if n in r else ('stub' if n in stubs else 'other')
            m = re.search(r'^\.SH NAME\s*\n(.+)$', src, re.M)
            desc = ''
            if m:
                desc = m.group(1).replace('\\-', '-').replace('\\&', '').strip()
                desc = re.sub(r'^\S+\s*-\s*', '', desc)
            key = hashlib.sha256((vtag + '\0' + src).encode()).hexdigest()
            cf = self.cache / (n + '.' + key[:16] + '.html')
            if cf.is_file():
                frag = cf.read_text()
            else:
                res = subprocess.run([mandoc, '-Thtml', '-Ofragment'],
                                     input=src, capture_output=True, text=True)
                if res.returncode or not res.stdout.strip():
                    self.err('man %s: mandoc failed: %s' % (n, res.stderr[:80]))
                    continue
                frag = res.stdout
                for old in self.cache.glob(n + '.*.html'):
                    old.unlink()
                cf.write_text(frag)
            prov = []
            for ln in src.split('\n'):
                if not ln.startswith('.\\"'):
                    break
                prov.append(ln[3:].strip())
            self.man[n] = dict(kind=kind, desc=desc, frag=frag, prov=prov)

    def man_page_html(self, n):
        d = self.man[n]
        frag = d['frag']
        frag = re.sub(r'<h1 class="Sh"(.*?)</h1>', r'<h2 class="Sh"\1</h2>', frag, flags=re.S)
        frag = re.sub(r'<h2 class="Ss"(.*?)</h2>', r'<h3 class="Ss"\1</h3>', frag, flags=re.S)

        def link_refs(m):
            sec = m.group(0)

            def one(mm):
                name = mm.group(1)
                if name in self.man and name != n:
                    return '<a href="/man/%s/">%s(1)</a>' % (name, name)
                return mm.group(0)
            return re.sub(r'\b([a-z][a-z0-9.]*)\(1\)', one, sec)
        frag = re.sub(r'<section class="Sh">\s*<h2 class="Sh" id="SEE_ALSO".*?</section>',
                      link_refs, frag, flags=re.S)
        badge = ''
        if d['kind'] == 'stub':
            badge = ('<p class="badge stub">stub &mdash; this tool is not provided '
                     'on maux; the page says why. <a href="/man/#stubs">All stubs</a></p>')
        prov = ''
        if d['prov']:
            lines = [html.escape(x) for x in d['prov']
                     if x and not x.startswith('Rendered by')]
            prov = ('<aside class="notice"><h2>Provenance and licence</h2><pre>%s</pre>'
                    '<p>Pages derived from Research UNIX or BSD manuals keep the '
                    'notices their sources require: see <a href="/man/licenses/">licenses(1)</a> '
                    'and <a href="/about/">About</a>.</p></aside>' % '\n'.join(lines))
        return ('<p class="crumb"><a href="/man/">Manual</a> / %s</p>'
                '<h1>%s(1)</h1>%s<div class="man">%s</div>%s'
                % (html.escape(n), html.escape(n), badge, frag, prov))

    def man_index_html(self):
        o = []
        groups = [('command', 'commands', 'Commands',
                   'Every command in the build roster (Makefile UTILS plus nas and ld).'),
                  ('stub', 'stubs', 'Stubs: not provided on maux',
                   'A stub is a decision, not an oversight: it says what is missing and why '
                   '(docs/MAN.md sec 6).'),
                  ('other', 'other', 'Other pages', 'Notices and non-command pages.')]
        o.append('<!-- src: docs/MAN.md sec 2 -->')
        o.append('<p>These pages are the ones shipped on the disk, as '
                 '<code>man</code> shows them there, rendered here by mandoc. '
                 'All are section 1.</p>')
        for kind, ident, title, blurb in groups:
            items = sorted(n for n, d in self.man.items() if d['kind'] == kind)
            o.append('<h2 id="%s">%s (%d)</h2><p>%s</p><ul class="mangrid">' %
                     (ident, title, len(items), blurb))
            for n in items:
                o.append('<li><a href="/man/%s/"><code>%s</code></a> %s</li>'
                         % (n, n, html.escape(self.man[n]['desc'])))
            o.append('</ul>')
        return '\n'.join(o)

    # ------------------------------------------------------------ gen
    def gen(self, name, route):
        fn = getattr(self, 'gen_' + name, None)
        if fn is None:
            self.err('%s: unknown {{gen:%s}}' % (route or 'home', name))
            return ''
        return fn()

    def cssver(self):
        """A short content hash of the stylesheet, for its URL.

        Without it a reader who has the page cached keeps the OLD
        stylesheet after a restyle, and nothing on the page says so --
        which is exactly how a fixed sticky rail went on scrolling for
        everyone who had already visited. Hashing the CONTENT means the
        URL changes when, and only when, the bytes do."""
        if getattr(self, '_cssver', None) is None:
            data = (self.site / 'static' / 'style.css').read_bytes()
            self._cssver = hashlib.sha256(data).hexdigest()[:10]
        return self._cssver

    def video_html(self, name, autoplay=False, base=''):
        """The player. Two axes: the DISPLAY the session was filmed on
        and the PHOSPHOR of the monitor it is shown on
        (docs/DEMO-PHOSPHOR.md). With JavaScript off the page is the
        //e's film on the default monitor, in plain
        <video>/<source>/<track> markup, with a plain link to the
        UltraTerm's. With it, the data-* attributes carry every variant
        and static/display.js adds the two controls, swaps sources,
        poster and captions, keeps the position and remembers both
        choices.

        The captions are per DISPLAY, not per phosphor -- the three
        films of one display are the same frames -- so a vtt attribute
        is two-part (data-e-vtt-src) where a film attribute is
        three-part (data-e-amber-mp4-src)."""
        f = self.demo_files(name)
        b, ph0 = base, demo_phos.DEFAULT

        def url(disp, kind, ph=None):
            p = f.get((disp, kind, ph))
            return (b + p.name) if p else None

        def film(disp, ph):
            """{kind: url} for one cell of the matrix, captions
            included (they belong to the display)."""
            out = {}
            for kind in ('webm', 'mp4', 'poster'):
                u = url(disp, kind, ph)
                if u:
                    out[kind] = u
            u = url(disp, 'vtt')
            if u:
                out['vtt'] = u
            return out

        shown = [d for d, _s, _l in DISPLAYS
                 if url(d, 'mp4', ph0) or url(d, 'webm', ph0)]
        if 'e' not in shown:
            return None
        # a monitor counts only when EVERY shown display has it, so a
        # control can never offer a button that is dead on one of them
        monitors = [p for p in demo_phos.NAMES
                    if all(url(d, 'mp4', p) or url(d, 'webm', p)
                           for d in shown)]
        if ph0 not in monitors:
            monitors = [ph0] + monitors
        e = film('e', ph0)
        pick = len(shown) > 1 or len(monitors) > 1
        data = ''
        if pick:
            for disp in shown:
                v = url(disp, 'vtt')
                if v:
                    data += ' data-%s-vtt-src="%s"' % (disp, v)
                for ph in monitors:
                    cell = film(disp, ph)
                    for kind, key in (('poster', 'poster'),
                                      ('webm', 'webm-src'),
                                      ('mp4', 'mp4-src')):
                        if kind in cell:
                            data += ' data-%s-%s-%s="%s"' % (
                                disp, ph, key, cell[kind])
        o = ['<video controls muted loop playsinline preload="metadata"%s%s%s>'
             % (' autoplay' if autoplay else '',
                ' poster="%s"' % e['poster'] if 'poster' in e else '',
                (' data-display="e" data-phosphor="%s"' % ph0 + data)
                if pick else '')]
        if 'webm' in e:
            o.append('<source src="%s" type="video/webm">' % e['webm'])
        if 'mp4' in e:
            o.append('<source src="%s" type="video/mp4">' % e['mp4'])
        if 'vtt' in e:
            o.append('<track kind="captions" src="%s" srclang="en" '
                     'label="English" default>' % e['vtt'])
        o.append('Your browser cannot play this video; the transcript is below.</video>')
        if 'vtt' in e:
            # the caption overlay (static/captions.js): a dim layer over
            # the picture and the plate the active cue is drawn in
            o.append('<div class="film-dim" aria-hidden="true"></div>'
                     '<div class="film-cap" aria-hidden="true">'
                     '<div class="film-plate"></div></div>')
        o.append('</div>')
        o.insert(0, '<div class="film">')
        if 'ut' in shown:
            ut = film('ut', ph0)
            alt = ut.get('mp4') or ut.get('webm')
            o.append('<p class="display-alt" data-display-alt>Filmed on '
                     'the Apple IIe 80-column display. <a href="%s">The '
                     'same session on the Videx UltraTerm</a>: same '
                     'keys, same text.</p>' % alt)
        # display.js carries the monitor control as well as the display
        # one, so every film loads it
        o.append('<script src="/static/display.js" defer></script>')
        if 'vtt' in e:
            o.append('<script src="/static/captions.js" defer></script>')
        return '\n'.join(o)

    def gen_hero(self):
        info = self.demos
        if not info:
            return ''
        heroes = sorted(n for n, d in info.items() if d.get('hero'))
        name = heroes[0] if heroes else sorted(info)[0]
        v = self.video_html(name, autoplay=True, base='/watch/%s/' % name)
        title = html.escape(info[name]['title'])
        if v:
            return '<figure class="hero">%s</figure>' % v
        cmds = html.escape('\n'.join('$ ' + c for c in info[name]['commands']))
        return ('<figure class="hero"><pre>%s</pre><figcaption>%s. The video of this '
                'session is built at release time; this is what it types. '
                '<a href="/watch/%s/">The demo page</a>.</figcaption></figure>'
                % (cmds, title, name))

    def gen_demogallery(self):
        o, listed = [], set()
        for group, items in GALLERY:
            items = [(n, bl) for n, bl in items if n in self.demos]
            if not items:
                continue
            o.append('<h2>%s</h2>' % html.escape(group))
            o.append('<ol class="cards films">')
            for name, blurb in items:
                listed.add(name)
                f = self.demo_files(name)
                pf = f.get(('e', 'poster', demo_phos.DEFAULT))
                img = ('<img src="/watch/%s/%s" alt="" width="280">'
                       % (name, pf.name) if pf else '')
                o.append('<li><a href="/watch/%s/"><span class="thumb">%s</span>'
                         '<strong>%s</strong><span class="blurb">%s</span></a></li>'
                         % (name, img, html.escape(self.demos[name]['title']), blurb))
            o.append('</ol>')
        left = sorted(set(self.demos) - listed)
        if left:
            self.err('watch: demos missing from GALLERY: %s' % ', '.join(left))
        return '\n'.join(o)

    def demo(self):
        d = self.demos.get(self.cur_demo)
        if d is None:
            self.err('page needs a demo and %r is not in site/demos' % self.cur_demo)
        return d

    def gen_player(self):
        name = self.cur_demo
        if self.demo() is None:
            return ''
        v = self.video_html(name, base='')
        note = ''
        if self.ut_on() and 'ut' in self.demos[name]['backends']:
            note = ('<p class="display-note">The Videx UltraTerm was an '
                    '80-column video card for the Apple IIe, with its '
                    'own video memory and character generator, real '
                    'hardware scrolling and more screen modes than the '
                    'IIe\'s own 80 columns. This demo runs on either '
                    'display; the UltraTerm film shows the original '
                    'Videx UltraTerm, emulated.</p>')
        if v:
            return '<figure class="hero">%s</figure>%s' % (v, note)
        return ('<p class="badge">The video for this demo is built at release time '
                '(<code>make demos</code>); it is not in this build. The transcript '
                'below is what the script types.</p>' + note)

    KEYNAMES = {'\x03': '^C', '\x04': '^D', '\x1a': '^Z', '\x1b': 'ESC',
                '\r': 'RET'}

    def typed_listing(self, typed):
        out, run = [], ''
        for kind, val in typed + [('end', '')]:
            if kind == 'keys':
                if val == '\x0c':
                    continue
                run += '<SPACE>' if val == ' ' else ''.join('<%s>' % self.KEYNAMES[c]
                               if c in self.KEYNAMES else c for c in val)
                continue
            if run:
                out.append('  keys: ' + run)
                run = ''
            if kind == 'line':
                out.append('$ ' + val)
        return '\n'.join(out)

    def gen_democommands(self):
        d = self.demo()
        if d is None:
            return ''
        o = []
        if d.get('script'):
            o.append('<p>The script it writes, line by line:</p><pre>%s</pre>'
                     % html.escape('\n'.join(d['script'])))
        o.append('<p>Everything it types, in order. A line starting with '
                 '<code>$</code> is a command at the shell, RET included; '
                 '<code>keys</code> lines are single keystrokes to a '
                 'program (RET, ESC and the control keys are named).</p>'
                 '<pre>%s</pre>' % html.escape(self.typed_listing(d['typed'])))
        if any('\x0c' in v for k, v in d['typed'] if k == 'keys'):
            o.append('<p>Between steps it presses ^L to clear the screen.</p>')
        return '\n'.join(o)

    @staticmethod
    def vtt_cues(path):
        """The cue texts of a WebVTT file, in order."""
        cues, cur, grab = [], [], False
        for ln in path.read_text(errors='replace').split('\n') + ['']:
            if '-->' in ln:
                grab, cur = True, []
            elif grab and ln.strip():
                cur.append(ln.strip())
            elif grab:
                cues.append(html.unescape(' '.join(cur)))
                grab = False
        return cues

    def gen_democaptions(self):
        """The captions. With the film present they are the PUBLISHED
        cues (NAME.vtt, NAME-ut.vtt), which carry any figure the run
        measured and so can differ between the displays; without it, the
        captions the script spells out."""
        d = self.demo()
        if d is None:
            return ''
        f = self.demo_files(self.cur_demo)
        shown = [(disp, f[(disp, 'vtt', None)]) for disp, _s, _l in DISPLAYS
                 if (disp, 'vtt', None) in f]
        if shown:
            lists = [(k, self.vtt_cues(p)) for k, p in shown]
            if len(lists) == 2 and lists[0][1] == lists[1][1]:
                lists = lists[:1]
            o = []
            for k, cues in lists:
                if len(lists) > 1:
                    o.append('<p>%s</p>' % ('On the IIe\'s own 80 columns:'
                                           if k == 'e' else
                                           'On the UltraTerm:'))
                o.append('<ol>%s</ol>' % ''.join(
                    '<li>%s</li>' % html.escape(c) for c in cues))
            return '\n'.join(o)
        o = '<ol>%s</ol>' % ''.join('<li>%s</li>' % html.escape(s)
                                   for s in d['says'] if s is not None)
        if None in d['says']:
            o += ('<p>Some captions carry a figure the film measures; they '
                  'appear here when the film is recorded.</p>')
        return o

    def gen_demotranscript(self):
        if self.demo() is None:
            return ''
        f = self.demo_files(self.cur_demo)
        if ('e', 'transcript', None) not in f:
            return ('<p>The settled-screen transcript is written when the demo is '
                    'recorded (<code>make demos</code>); it is not in this build.</p>')
        t = f[('e', 'transcript', None)].read_text(errors='replace')
        t = ''.join(c if ord(c) < 128 else '?' for c in t)
        return ('<p>The screen at every checkpoint the test checks, as the recorder '
                'saved it:</p><pre class="transcript">%s</pre>' % html.escape(t))

    def film_measures(self, name):
        """{measure: [value per display]} from the stamps the film's
        gate wrote (t.measure, demo_record.py); {} without the film."""
        out = {}
        d = self.demos_out / name
        for fn in (name + '.stamp.json', name + '-ut.stamp.json'):
            if fn.endswith('-ut.stamp.json') and not self.ut_on():
                continue
            if not (d / fn).is_file():
                continue
            try:
                doc = json.loads((d / fn).read_text())
            except ValueError:
                continue
            for k, v in (doc.get('measures') or {}).items():
                out.setdefault(k, []).append(v)
        return out

    def gen_hellopla_figures(self):
        """The startup figures of the L6 lesson, from the film's own run
        (hellopla.py measures them; the stamp carries them). Without the
        film the sentence has no numbers."""
        m = self.film_measures('hellopla')
        need = ('plasma_first', 'cooked_first', 'cooked_warm')
        if not all(k in m for k in need):
            return ('<p>The film of this lesson times these runs in cycles '
                    'of the emulated machine; its figures appear here when '
                    'the film is recorded.</p>')

        def rng(vals):
            lo, hi = min(vals) / 1e6, max(vals) / 1e6
            if round(lo, 2) == round(hi, 2):
                return '%.2f million' % lo
            return '%.2f to %.2f million' % (lo, hi)
        return ('<p>The film times them, in cycles of the emulated machine, '
                'from the moment RETURN is pressed to the moment the output '
                'appears: <code>plasma hello.mod</code> the first time, '
                '%s; the cut <code>./hello</code> the first time, %s; and '
                '<code>./hello</code> run again, %s. (The first run of '
                'anything pays to bring its file in from the disk. The '
                'figures are to the nearest slice of the recorder\'s clock, '
                'about a sixth of a million cycles.) For this program the cut '
                'file saves %s cycles on the first run.</p>'
                % (rng(m['plasma_first']), rng(m['cooked_first']),
                   rng(m['cooked_warm']),
                   rng([a - b for a, b in zip(m['plasma_first'],
                                              m['cooked_first'])])))

    def gen_warmstart_figures(self):
        """The cold, warm and rewritten startup figures of W19, from the
        film's own run (warmstart.py measures them; the stamp carries
        them). Without the film the sentence has no numbers."""
        m = self.film_measures('warmstart')
        need = ('vi_cold', 'vi_warm', 'asm_cold', 'asm_warm',
                'asm_rewritten')
        if not all(k in m for k in need):
            return ('<p>The film times these launches in cycles of the '
                    'emulated machine; its figures appear here when the '
                    'film is recorded.</p>')

        def rng(vals):
            lo, hi = min(vals) / 1e6, max(vals) / 1e6
            if round(lo, 2) == round(hi, 2):
                return '%.2f million' % lo
            return '%.2f to %.2f million' % (lo, hi)
        def times(cold, warm):
            r = sorted(c / w for c, w in zip(cold, warm))
            lo, hi = round(r[0]), round(r[-1])
            return ('about %d times' % lo if lo == hi
                    else 'about %d to %d times' % (lo, hi))
        return ('<p>The film times each launch, in cycles of the emulated '
                'machine, from the moment RETURN is pressed to the moment '
                'the first output appears: <code>vi</code> the first time, '
                '%s, and again, %s; the copy of <code>nas</code> the first '
                'time, %s, again, %s, and after the file was rewritten, %s. '
                'Warm, <code>vi</code> starts %s faster and the copy of '
                '<code>nas</code> %s faster. (Each figure is to within one '
                'video frame, 34,016 cycles, rounded up, which is a '
                'large share of a warm <code>nas</code> launch; the ratios '
                'are worked out from the figures the stamp holds, and they '
                'can differ between the two displays.)</p>'
                % (rng(m['vi_cold']), rng(m['vi_warm']),
                   rng(m['asm_cold']), rng(m['asm_warm']),
                   rng(m['asm_rewritten']),
                   times(m['vi_cold'], m['vi_warm']),
                   times(m['asm_cold'], m['asm_warm'])))

    def gen_demogate(self):
        d = self.demo()
        if d is None:
            return ''
        return ('<code>make %s</code>' % html.escape(d['gate']))

    def gen_ladder(self):
        text = (self.root / 'docs/SITE.md').read_text()
        sec = text.split('\n## 5. ', 1)[1].split('\n## 6. ', 1)[0]
        items = re.findall(r'^### (L\d)\. (.+)$', sec, re.M)
        if not items:
            self.err('docs/SITE.md sec 5: no ladder headings found')
        o = []
        for a, b in items:
            route = self.lessons.get(a.lower())
            title = self.md_inline(b)
            if route:
                pg = self.pages[route]
                o.append('<li><strong>%s</strong> <a href="/%s/">%s</a> '
                         '&mdash; %s</li>'
                         % (a, route, html.escape(pg['meta']['title']),
                            html.escape(pg['meta']['description'])))
            else:
                o.append('<li><strong>%s</strong> %s <em>(not published)</em></li>'
                         % (a, title))
        return '<ol class="ladder">%s</ol>' % ''.join(o)

    # lesson pages ---------------------------------------------------
    def cur_lid(self):
        lid = self.cur_lesson
        if not lid:
            self.err('a page without a "lesson:" header uses a lesson placeholder')
        return lid

    def gen_session(self):
        lid = self.cur_lid()
        if not lid:
            return ''
        sp = self.session_path(lid)
        if not sp.is_file():
            return ''                      # already reported by check_lessons
        o = []
        for ln in self.session(lid)[1]:
            ln = ''.join(c if ord(c) < 128 else '?' for c in ln)
            e = html.escape(ln, quote=False).replace('{', '&#123;')
            if ln.startswith('$ ') or ln == '$':
                o.append('<span class="typed">%s</span>' % e)
            elif ln.startswith('[ ') and ln.endswith(' ]'):
                o.append('<span class="note">%s</span>' % e)
            else:
                o.append(e)
        return ('<pre class="session" aria-label="the session">%s</pre>'
                % '\n'.join(o))

    def session_out(self, arg, route):
        """{{sessionout:CMD#N}}: the output lines of the Nth typed `$ CMD`
        in this page's session, so a page quotes what the gate saw and never
        types it a second time."""
        lid = self.cur_lesson
        cmd, _, n = arg.partition('#')
        n = int(n or 1)
        if not lid or lid not in self.lessons:
            return ''
        out, hit, seen = [], False, 0
        for ln in self.session(lid)[1]:
            if ln.startswith('$ '):
                if hit:
                    break
                if ln[2:] == cmd:
                    seen += 1
                    hit = seen == n
            elif hit:
                out.append(ln)
        if not hit or not out:
            self.err('%s: {{sessionout:%s}} finds no output' % (route, arg))
            return ''
        return ('<pre>%s</pre>'
                % html.escape('\n'.join(out), quote=False).replace('{', '&#123;'))

    def gen_lessonnav(self):
        lid = self.cur_lid()
        if not lid:
            return ''
        order = sorted(self.lessons)
        if lid not in order:
            return ''                      # refused by check_lessons
        i = order.index(lid)
        bits = []
        if i > 0:
            r = self.lessons[order[i - 1]]
            bits.append('<a href="/%s/">&larr; %s</a>'
                        % (r, html.escape(self.pages[r]['meta']['title'])))
        bits.append('<a href="/learn/">All lessons</a>')
        if i + 1 < len(order):
            r = self.lessons[order[i + 1]]
            bits.append('<a href="/%s/">%s &rarr;</a>'
                        % (r, html.escape(self.pages[r]['meta']['title'])))
        return '<p class="lessonnav">%s</p>' % ' | '.join(bits)

    def file_block(self, path, route):
        """An examples/ file, included verbatim."""
        path = path.strip()
        p = self.root / path
        parts = path.split('/')
        if len(parts) != 3 or parts[0] != 'examples' or not p.is_file():
            self.err('%s: {{file:%s}} is not a file of examples/DIR/NAME'
                     % (route or 'home', path))
            return ''
        data = p.read_bytes()
        if any(b >= 128 for b in data):
            self.err('%s: examples file %s is not ASCII' % (route, path))
        text = data.decode('ascii', 'replace')
        disk = '/usr/src/examples/%s/%s' % (parts[1].upper(), parts[2])
        return ('<figure class="srcfile"><figcaption><a href="repo:%s"><code>%s</code></a>'
                ' &mdash; on the disk as <code>%s</code></figcaption>'
                '<pre><code>%s</code></pre></figure>'
                % (path, html.escape(path), html.escape(disk),
                   html.escape(text, quote=False).replace('{', '&#123;')))

    def gen_syscalls(self):
        rows = self.facts.syscalls(self.root)
        o = ['<div class="tablewrap"><table><thead><tr><th>call</th><th>number</th>'
             '<th>defined in</th></tr></thead><tbody>']
        def val(r):
            return int(r[1][1:], 16) if r[1].startswith('$') else int(r[1])
        for n, v, f in sorted(rows, key=val):
            o.append('<tr><td><code>%s</code></td><td><code>%s</code></td>'
                     '<td><a href="repo:inc/%s"><code>inc/%s</code></a></td></tr>' % (n, v, f, f))
        o.append('</tbody></table></div>')
        return '\n'.join(o)

    def gen_verification(self):
        return self.doc_table('docs/VERIFICATION.md', 'Command')[1]

    def gen_gatelist(self):
        gates = self.facts.makefile_list(self.root, 'CHECK_ALL_TARGETS')
        tbl, _ = self.doc_table('docs/VERIFICATION.md', 'Command')
        described = {}
        for ln in tbl[2:]:
            cells = [c.strip() for c in ln.strip().strip('|').split(' | ')]
            for m in re.findall(r'`make (check-[a-z0-9-]+)', cells[0]):
                described[m] = cells[1]
        o = ['<p>%d targets are in the Makefile\'s <code>CHECK_ALL_TARGETS</code>. '
             'VERIFICATION.md describes some of them; the rest are listed by name.</p>'
             % len(gates), '<ul class="gates">']
        for g in gates:
            d = described.get(g)
            o.append('<li><code>%s</code>%s</li>'
                     % (g, ' &mdash; ' + self.md_inline(d) if d else ''))
        o.append('</ul>')
        return '\n'.join(o)

    # ---- the Conformance page: every number is a {{fact:cf_*}} --------
    def gen_conformance_summary(self):
        """The at-a-glance block at the top of /conformance/: the breadth
        numbers, then every standard utility that was compared, by name.
        The names come from the archived run's own per-tool tally, so the
        list cannot drift from the counts below it."""
        try:
            matched = self.facts.conformance_matched(self.root)
        except self.facts.FactError as e:
            self.err('conformance summary: %s' % e)
            return ''
        self.used_facts.update(['utility_count', 'cf_util_tools', 'cf_util_total',
                                'cf_util_pass', 'cf_util_gaps'])
        o = ['<div class="tablewrap"><table class="glance"><tbody>',
             '<tr><th>Commands on the disk</th>'
             '<td>{{fact:utility_count}}</td></tr>',
             '<tr><th>Standard utilities compared with a real Unix, command by '
             'command</th><td>{{fact:cf_util_tools}}</td></tr>',
             '<tr><th>Tests run on them</th><td>{{fact:cf_util_total}}</td></tr>',
             '<tr><th>Same answer</th><td>{{fact:cf_util_pass}}</td></tr>',
             '<tr><th>Known differences, each named below</th>'
             '<td>{{fact:cf_util_gaps}}</td></tr>',
             '</tbody></table></div>',
             '<p>The shell, <code>sed</code>, <code>vi</code>, <code>ex</code> and the '
             'regular-expression engine have references of their own and are counted '
             'separately in the table further down.</p>']
        return '\n'.join(o)

    def gen_conformance_table(self):
        # Each cell carries its column name: on a phone the CSS turns a
        # row into a card and prints the name before the cell.
        o = ['<div class="tablewrap"><table class="conf"><thead><tr>'
             '<th>Tool</th><th>Where it comes from</th><th>Checked against</th>'
             '<th>Same answer</th><th>Notable differences</th></tr></thead><tbody>']
        for tool, heritage, ref, count, notes, _src in self.conf_rows:
            o.append('<tr><th scope="row">%s</th>'
                     '<td data-label="Where it comes from">%s</td>'
                     '<td data-label="Checked against">%s</td>'
                     '<td data-label="Same answer">%s</td>'
                     '<td data-label="Notable differences">%s</td></tr>'
                     % (tool if ' ' in tool else '<code>%s</code>' % tool,
                        heritage, ref, count, notes))
        o.append('</tbody></table></div>')
        return '\n'.join(o)

    def gen_conformance_gaps(self):
        try:
            gaps = self.facts.conformance_gaps(self.root)
            sh = self.facts.sh_defects(self.root)
        except self.facts.FactError as e:
            self.err('conformance gaps: %s' % e)
            return ''
        self.used_facts.update(['cf_util_gaps', 'cf_sh_defects'])
        o = ['<h3>Utilities</h3>', '<ul class="gaps">']
        for tool, name, head in gaps:
            shown = '' if re.fullmatch(r'[A-Za-z0-9]+', name) else ' ' + name
            if not shown:
                # the log's key is a test-group name (sortk), not an
                # option: the option leads the description, so lift it
                m = re.match(r'(-\S+|%\S+) (.*)$', head)
                if m:
                    shown, head = ' ' + m.group(1), m.group(2)
            o.append('<li><code>%s%s</code> %s</li>'
                     % (html.escape(tool), html.escape(shown),
                        html.escape(head)))
        o.append('</ul>')
        o.append('<h3>The shell</h3>')
        o.append('<ul class="gaps">')
        for d in sh:
            o.append('<li><code>sh</code> %s</li>' % html.escape(d))
        o.append('</ul>')
        return '\n'.join(o)

    def gen_conformance_utils(self):
        try:
            matched = self.facts.conformance_matched(self.root)
        except self.facts.FactError as e:
            self.err('conformance tallies: %s' % e)
            return ''
        o = ['<ul class="tallies">']
        for tool, _a, _b, gaps in matched:
            self.used_facts.update(['cf_u_%s_pass' % tool, 'cf_u_%s_total' % tool])
            note = ''
            if gaps:
                self.used_facts.add('cf_u_%s_gaps' % tool)
                note = (' <span class="gapnote">{{fact:cf_u_%s_gaps}} known '
                        'difference%s</span>' % (tool, '' if gaps == 1 else 's'))
            o.append('<li><code>%s</code> {{fact:cf_u_%s_pass}} of {{fact:cf_u_%s_total}}%s</li>'
                     % (tool, tool, tool, note))
        o.append('</ul>')
        return '\n'.join(o)

    def gen_manindexsummary(self):
        return ('<p><strong>{{fact:man_pages_total}}</strong> pages: '
                '{{fact:man_pages_commands}} commands, {{fact:man_pages_stub}} stubs, '
                '{{fact:man_pages_other}} other. <a href="/man/">Open the index</a>.</p>')

    LOCAL = re.compile(r'(^|[/@.])(localhost|127\.0\.0\.1|\[::1\])([:/]|$)', re.I)

    def tryit_href(self, *, quiet=False):
        """The Apple2TS boot URL, or None when there is no public image to
        hand it. Two pages ask for this; `quiet` keeps the second caller
        from reporting the localhost diagnostic a second time."""
        base = self.a.apple2ts_url
        image = self.a.image_url
        absolute = re.match(r'https?://', image) is not None
        local = bool(self.LOCAL.search(base.split('//', 1)[-1]) or
                     self.LOCAL.search(image.split('//', 1)[-1]))
        if local and not self.a.local_preview:
            if not quiet:
                self.err('--apple2ts-url/--image-url name localhost; pass --local-preview '
                         'to build a page for a local test')
            self.tryit_refused = True
            return None
        self.tryit_refused = False
        if not absolute:
            return None
        self.used_facts.update(['bank_top', 'min_ram_kb'])
        ram = (int(self.facts.FACTS['bank_top']['fn'](self.root)) + 1) * 64
        q = ('machine=apple2ee&ramdisk=%d&slot4=mockingboard&slot5=mouse'
             '&capslock=off&hd1=%s' % (ram, urllib.parse.quote(image, safe='')))
        sep = '&' if '?' in base else '?'
        return '%s%s%s' % (html.escape(base), sep, html.escape(q, quote=True))

    def gen_tryit(self):
        """The button on /get/. It leads to OUR /try/ page, which carries
        the emulator in the page; the link off to apple2ts.com is on that
        page, for a reader who wants it full-window. tryit_href is still
        called for its checks: it is what refuses a localhost build
        without --local-preview, and what decides there is an image to
        boot at all."""
        if self.tryit_href() is None:
            if self.tryit_refused:       # localhost without --local-preview
                return ''
            return ('<p>The browser link goes live with the release, once the disk '
                    'image is hosted at a public address.</p>')
        return ('<p><a class="trylink" href="/try/">Try now in your browser</a></p>')

    def gen_tryhome(self):
        """The same button on the home page, where someone who has just
        arrived will see it. It renders NOTHING until there is a public
        image: a passer-by is better served by no button than by a
        promise, and /get/ is the page that explains the wait."""
        if self.tryit_href(quiet=True) is None:
            return ''
        return ('<p class="tryhome"><a class="trylink" href="/try/">'
                'Try now in your browser</a></p>')

    def gen_tryemu(self):
        """The emulator itself, in the page: Apple2TS with maux's disk and
        the card configuration maux needs.

        A reader who lands here gets a button, not a download. The frame's
        src is empty until the click, because booting costs the release
        image plus the emulator's own bundle and nobody should pay that
        for scrolling past. The button is a plain link to the same
        configured URL, so without JavaScript it opens the emulator in a
        new tab; static/tryemu.js turns it into the embed."""
        href = self.tryit_href(quiet=True)
        if href is None:
            if self.tryit_refused:       # localhost without --local-preview
                return ''
            return ('<p>The emulator goes live with the release, once the disk '
                    'image is hosted at a public address. Until then it runs '
                    'in MAME: see <a href="/get/">Get</a>.</p>')
        # In the frame, the emulator renders its canvas and nothing else
        # (appmode=embed): its own control panel, disk shelf and help
        # pane are a second UI inside ours, and they squeeze the machine
        # into a corner of the box. The link out keeps the full one --
        # that is what it is for.
        # href is already HTML-escaped, so the separator must be too:
        # a bare & in an attribute is an entity waiting to be misread.
        sep = '&amp;' if '?' in href else '?'
        # The same case as a film: .band > figure.hero > .film is the
        # monitor the demos play in (style.css "the phosphor band"), and
        # the chin under it is the same control strip, built by
        # static/tryemu.js the way static/display.js builds a film's.
        # There is one display here -- Apple2TS has no UltraTerm -- so
        # that axis is a label rather than a dead control, and the
        # phosphor axis is real: it picks the monitor the machine comes
        # up on, and it is remembered in the same place as the films'.
        return ('<figure class="hero">\n'
                '<div class="film emu" data-frame-src="%s%sappmode=embed" '
                'data-phosphor="%s" data-display-name="%s">\n'
                '<a class="emustart" href="%s" target="_blank" rel="noopener">'
                '<span class="emubtn">Boot maux</span></a>\n'
                '</div>\n'
                '<script src="/static/tryemu.js" defer></script>\n'
                '</figure>'
                % (href, sep, demo_phos.DEFAULT, DISPLAYS[0][2], href))

    def gen_download(self):
        image = self.a.image_url
        if re.match(r'https?://', image) is None:
            return ('<p>The download link goes live with the release, once the disk '
                    'image is hosted at a public address.</p>')
        self.used_facts.update(['release_bytes', 'release_mb'])
        name = urllib.parse.urlparse(image).path.rsplit('/', 1)[-1]
        sha = self.a.image_sha256
        line = ('SHA-256 <code>%s</code>' % html.escape(sha) if sha else
                'SHA-256 in <code>SHA256SUMS</code>, next to the disk')
        return ('<p><a class="button" href="%s">Download %s</a></p>\n'
                '<p>{{fact:release_mb}} MB ({{fact:release_bytes}} bytes). %s.</p>'
                % (html.escape(image, quote=True), html.escape(name), line))

    def gen_builtrev(self):
        self.used_facts.add('revision')
        return '\0Fbuiltrev\0'

    # ------------------------------------------------------------ render
    PH = re.compile(r'\{\{(\w+)(?::([^}]*))?\}\}')

    def expand(self, text, route, depth=0):
        def sub(m):
            kind, arg = m.group(1), (m.group(2) or '').strip()
            if kind == 'fact':
                self.used_facts.add(arg)
                return '\0F%s\0' % arg
            if kind == 'svg':
                p = self.site / 'static/diagrams' / (arg + '.svg')
                if not p.is_file():
                    self.err('%s: {{svg:%s}} has no file' % (route or 'home', arg))
                    return ''
                svg = p.read_text()
                return re.sub(r'<\?xml.*?\?>\s*', '', svg)
            if kind == 'demo':
                if arg not in self.demos:
                    self.err('%s: names demo %r with no file in site/demos' % (route or 'home', arg))
                return html.escape(arg)
            if kind == 'gen':
                return self.gen(arg, route)
            if kind == 'file':
                return self.file_block(arg, route)
            if kind == 'sessionout':
                return self.session_out(arg, route)
            self.err('%s: unknown placeholder {{%s}}' % (route or 'home', kind))
            return ''
        out = self.PH.sub(sub, text)
        if depth < 3 and self.PH.search(out):
            out = self.expand(out, route, depth + 1)
        return out

    # Two counts of DIFFERENT sets on one page read as an error even
    # when both are true, and the front page shipped exactly that: "all
    # 85 utilities" one line above "91 commands". utility_count is the
    # man roster (Makefile UTILS plus nas and ld); selfrebuild_utils is
    # what ONE archived self-make run staged, which at 52a54cf left out
    # 8 of the roster (AS by ruling, 7 that did not exist yet) and added
    # 2 proshim variants that are not commands. Print either; never
    # both on the same page.
    RIVAL_FACTS = [('utility_count', 'selfrebuild_utils')]

    def finish_facts(self, text, route):
        names = set(re.findall(r'\0F([^\0]+)\0', text))
        for a, b in self.RIVAL_FACTS:
            if a in names and b in names:
                self.err('%s: prints both {{fact:%s}} and {{fact:%s}}, which '
                         'count different sets -- one page, one count'
                         % (route or 'home', a, b))

        def sub(m):
            name = m.group(1)
            if name == 'revision':
                v = self.fact_values.get('revision')
                return 'Built from revision <code>%s</code>. ' % v if v else ''
            if name == 'builtrev':
                v = self.fact_values.get('revision')
                return ' (this site was built from revision <code>%s</code>)' % v if v else ''
            v = self.fact_values.get(name)
            return v if v is not None else ''
        return re.sub(r'\0F([^\0]+)\0', sub, text)

    def rel(self, route, target):
        depth = len(route.split('/')) if route else 0
        pre = '../' * depth
        if target.startswith('repo:'):
            path = target[5:]
            if path not in self.tracked_files() and not (self.root / path).is_dir():
                self.err('%s: repo: link to untracked path %s' % (route or 'home', path))
            return self.a.repo_url.rstrip('/') + '/' + path
        frag = ''
        if '#' in target:
            target, frag = target.split('#', 1)
            frag = '#' + frag
        t = target.lstrip('/')
        if t == '' or t.endswith('/'):
            t += 'index.html'
        return pre + t + frag

    def relink(self, text, route):
        def sub(m):
            attr, q, val = m.group(1), m.group(2), m.group(3)
            if val.startswith('/') and not val.startswith('//'):
                return '%s=%s%s%s' % (attr, q, self.rel(route, val), q)
            if val.startswith('repo:'):
                return '%s=%s%s%s' % (attr, q, self.rel(route, val), q)
            return m.group(0)
        # The player's data-*-src / data-*-poster attributes (the display
        # selector's other films) name files and are rewritten like src.
        return re.sub(r'\b(href|src|poster|data-[a-z0-9-]+-(?:src|poster))'
                      r'=(["\'])([^"\']*)\2', sub, text)

    def repo_root(self):
        """The repository's FRONT PAGE, for the header link. --repo-url
        points into a tree (.../blob/main/) because almost every other
        link is to one file in it; a reader who wants the code wants the
        project, so the ref and the blob come off."""
        u = re.sub(r'/(blob|tree)/[^/]+/*$', '', self.a.repo_url.rstrip('/'))
        return u + '/'

    def render_page(self, route, meta, body, tpl, extra_cls='', raw=False):
        if not raw:
            body = self.expand(body, route)
        body = self.relink(body, route)
        nav = []
        top = route.split('/')[0] if route else ''
        for r, label in NAV:
            href = self.rel(route, '/' + r + ('/' if r else ''))
            cur = ' aria-current="page"' if r == top else ''
            nav.append('<a href="%s"%s>%s</a>' % (href, cur, label))
        title = meta['title']
        full_title = title if not route else '%s - maux' % title
        if not route:
            full_title = 'maux - a Unix for the enhanced Apple IIe'
        page = tpl
        for k, v in (('title', html.escape(full_title)),
                     ('description', html.escape(meta['description'])),
                     ('nav', '\n'.join(nav)),
                     ('content', body),
                     ('static', '../' * (len(route.split('/')) if route else 0) + 'static/'),
                     ('cssver', self.cssver()),
                     ('home', self.rel(route, '/')),
                     ('about', self.rel(route, '/about/')),
                     ('repo', self.repo_root()),
                     ('revision', '\0Frevision\0'),
                     ('class', extra_cls)):
            page = page.replace('[[%s]]' % k, v)
        self.used_facts.add('revision')
        return page

    def write(self, route, text, raw=False):
        left = [] if raw else re.findall(r'\{\{[^}]*\}\}', text)
        if left:
            self.err('%s: unexpanded placeholder %s' % (route or 'home', left[0]))
        d = self.out / route if route else self.out
        d.mkdir(parents=True, exist_ok=True)
        (d / 'index.html').write_bytes(text.encode('ascii', 'xmlcharrefreplace'))

    # ------------------------------------------------------------ main
    def check_films(self):
        """Whenever build/demos holds films, every one the site would
        publish must be the recorder's declared size and stamped from the
        scripts, image and recorder as they are now (scripts/demo_stamp.py,
        docs/RECORDER.md). A build with no films checks nothing. The
        FILM_* module hooks are for check-site's self-test."""
        sys.path.insert(0, str(Path(self.root) / 'scripts'))
        try:
            import demo_stamp
        finally:
            sys.path.pop(0)
        demos = {n: dict(backends=d['backends'], image=d.get('image', 'play'),
                         floppy=d.get('floppy'),
                         path=str(self.site / 'demos' / (n + '.py')))
                 for n, d in self.demos.items()}
        for e in demo_stamp.film_errors(
                self.a.demos, demos, self.ut_on(), root=str(self.root),
                images=FILM_IMAGES, floppies=FILM_FLOPPIES,
                ffmpeg_now=FILM_FFMPEG, env=FILM_ENV):
            self.err(e)

    def run(self):
        self.load_facts()
        self.check_ascii_sources()
        self.load_pages()
        self.demos = self.demo_info()
        tpl_path = self.site / 'templates/page.html'
        if not tpl_path.is_file():
            self.err('missing site/templates/page.html')
            return
        tpl = tpl_path.read_text()
        if not self.a.no_man:
            self.render_man()
        # demo pages exist only for demos, and every demo has a page
        for route, pg in self.pages.items():
            if route.startswith('watch/') and route != 'watch':
                dn = route.split('/', 1)[1]
                if dn not in self.demos:
                    self.err('page %s: no demo file site/demos/%s.py' % (pg['src'], dn))
            dm = pg['meta'].get('demo')
            if dm and dm not in self.demos:
                self.err('page %s: names demo %r with no file in site/demos' % (pg['src'], dm))
        for dn in self.demos:
            if 'watch/' + dn not in self.pages:
                self.err('demo %s has no page site/pages/watch/%s.html' % (dn, dn))
        # lesson pages: a row and a session, or no page
        if self.a.skip_lessons:
            for route in [r for r, pg in self.pages.items()
                          if pg['meta'].get('lesson')]:
                del self.pages[route]
            self.lessons = {}
        else:
            self.check_lessons()
        # render
        if self.out.exists():
            shutil.rmtree(self.out)
        self.out.mkdir(parents=True)
        for route, pg in sorted(self.pages.items()):
            self.cur_demo = pg['meta'].get('demo')
            self.cur_lesson = pg['meta'].get('lesson')
            body = pg['body']
            self.write(route, self.render_page(route, pg['meta'], body, tpl))
        if not self.a.no_man and self.man:
            meta = dict(title='Manual pages',
                        description='Every manual page shipped on the maux disk, rendered from docs/man.')
            body = ('<h1>Manual pages</h1>' + '{{gen:manindexsummary}}' +
                    self.man_index_html())
            self.write('man', self.render_page('man', meta, body, tpl))
            for n in sorted(self.man):
                meta = dict(title='%s(1)' % n,
                            description='maux manual page for %s' % n)
                self.write('man/' + n, self.render_page(
                    'man/' + n, meta, self.man_page_html(n), tpl, raw=True),
                    raw=True)
        self.check_films()
        # static
        # display.js drives BOTH axes now, and the monitor axis has
        # nothing to do with the card, so a UT=0 build still ships it:
        # the kill switch is for the UltraTerm, not for the three
        # monitors (docs/DEMO-PHOSPHOR.md).
        skip = ['diagrams']
        shutil.copytree(self.site / 'static', self.out / 'static',
                        ignore=shutil.ignore_patterns(*skip))
        for dn in self.demos:
            for key, p in self.demo_files(dn).items():
                dest = self.out / 'watch' / dn
                dest.mkdir(parents=True, exist_ok=True)
                shutil.copy(p, dest / p.name)
        # facts
        self.fact_values, ferrs = self.facts.resolve(self.root, self.used_facts)
        self.errors += ferrs
        # facts used by pages exist; re-run the substitution now values are known
        for dirpath in sorted(self.out.rglob('index.html')):
            t = dirpath.read_text()
            rel = str(dirpath.parent.relative_to(self.out))
            t2 = strip_comments(self.finish_facts(
                t, 'home' if rel == '.' else rel + '/'))
            if '\0' in t2:
                self.err('internal: fact marker left in ' + str(dirpath))
            dirpath.write_bytes(t2.encode('ascii', 'xmlcharrefreplace'))
        (self.out / 'FACTS.txt').write_text(''.join(
            '%s = %s   [%s]\n' % (n, self.fact_values.get(n, '?'),
                                  ', '.join(self.facts.FACTS[n]['sources'])
                                  if n in self.facts.FACTS else 'NO FACT')
            for n in sorted(self.used_facts)))


def scrub_handles(text):
    """Lifted doc text may cite an internal knowledge-base handle; the
    published site never shows one."""
    return re.sub(r':?\s*`learning:[0-9A-Z]{26}`', '', text)


_KEEP_OR_COMMENT = re.compile(
    r'(<(script|style)\b.*?</\2\s*>)|(^[ \t]*<!--.*?-->[ \t]*\n)|(<!--.*?-->)',
    re.S | re.I | re.M)


def strip_comments(text):
    """Drop every <!-- ... --> from published HTML (src comments name
    internal sources and stay in the page sources, where check-site reads
    them). <script> and <style> blocks are kept byte for byte."""
    return _KEEP_OR_COMMENT.sub(lambda m: m.group(1) or '', text)


def parse(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--root', default=str(ROOT))
    ap.add_argument('--site', default=None)
    ap.add_argument('--out', default=None)
    ap.add_argument('--demos', default=None)
    ap.add_argument('--cache', default=None)
    ap.add_argument('--examples', default=None,
                    help='where check-examples wrote the sessions (default build/examples)')
    ap.add_argument('--full-image', default=None,
                    help='the disk the sessions must have run on (default build/full.po; '
                         'a session of another disk is stale; ignored if absent)')
    ap.add_argument('--ut', action='store_true',
                    help='publish the UltraTerm films and the display selector '
                         '(the Makefile passes it: UT ?= 1, so `make site` '
                         'publishes both displays; UT=0 for the //e alone)')
    ap.add_argument('--skip-lessons', action='store_true',
                    help='build without the lesson pages (no check-examples run yet)')
    ap.add_argument('--mandoc', default=None)
    ap.add_argument('--apple2ts-url', default='https://apple2ts.com/')
    ap.add_argument('--image-url', default='maux.po')
    ap.add_argument('--image-sha256', default=None,
                    help='SHA-256 of the release disk, shown on /get/ (release and '
                         'preview builds pass it; a plain build says to read SHA256SUMS)')
    ap.add_argument('--repo-url', default='https://github.com/maux-os/maux/blob/main/')
    ap.add_argument('--man-only', default=None, help='comma list (self-test)')
    ap.add_argument('--no-man', action='store_true')
    ap.add_argument('--revision', default=None,
                    help='revision to print (else MAUX_REVISION, else git; omitted if none)')
    ap.add_argument('--local-preview', action='store_true',
                    help='allow localhost URLs for --apple2ts-url/--image-url')
    a = ap.parse_args(argv)
    import os
    if a.revision:
        os.environ['MAUX_REVISION'] = a.revision
    root = Path(a.root)
    a.site = a.site or str(root / 'site')
    a.out = a.out or str(root / 'build/site')
    a.demos = a.demos or str(root / 'build/demos')
    a.examples = a.examples or str(root / 'build/examples')
    a.full_image = a.full_image or str(root / 'build/full.po')
    a.cache = a.cache or str(root / 'build/site-cache')
    a.mandoc = a.mandoc or os.environ.get('MANDOC', 'mandoc')
    return a


def build(argv=None):
    b = Build(parse(argv))
    b.run()
    return b


def main():
    b = build()
    if b.errors:
        for e in b.errors:
            print('FAIL site:', e)
        return 1
    n = sum(1 for _ in b.out.rglob('index.html'))
    print('site: %d pages in %s' % (n, b.out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
