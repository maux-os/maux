"""Named facts for the site (docs/SITE.md sec 7.4).

Every number the site prints is a fact here: a name, the file(s) it is
derived from, a description of how, and an extractor. A fact whose source
file is missing, or whose extractor cannot find its number, is a build
ERROR -- never a blank and never a stale default. Pages use {{fact:NAME}}.

To add a fact: write a function taking the repository root (a Path) and
returning the display string, and decorate it with @fact(name, sources,
how). `sources` are repository-relative paths; each must exist.
"""
import re
import subprocess
import sys

FACTS = {}


class FactError(Exception):
    pass


def fact(name, sources, how):
    def deco(fn):
        FACTS[name] = dict(name=name, sources=list(sources), how=how, fn=fn)
        return fn
    return deco


def num(n):
    return '{:,}'.format(n)


def read(root, rel):
    p = root / rel
    if not p.is_file():
        raise FactError('source file missing: ' + rel)
    return p.read_text(errors='replace')


def need(m, what):
    if not m:
        raise FactError('pattern not found: ' + what)
    return m


def _manifests(root):
    sys.path.insert(0, str(root / 'scripts'))
    try:
        import check_manifests
    finally:
        sys.path.pop(0)
    return check_manifests


def makefile_list(root, var):
    mf = _manifests(root)
    variables = mf.parse_makefile_vars(read(root, 'Makefile'))
    return mf.expand_str(variables, var).split()


def roster(root):
    """The command roster: Makefile UTILS plus the toolchain commands.
    Same definition as scripts/check_man.py
    (learning:01M2WPA3DED7JNEK8H6K868ET3)."""
    return set(makefile_list(root, 'UTILS')) | {'nas', 'ld'}


def man_pages(root):
    d = root / 'docs/man'
    if not d.is_dir():
        raise FactError('source dir missing: docs/man')
    return {p.stem: p.read_text() for p in sorted(d.glob('*.1'))}


def is_stub(src):
    return 'is not provided on maux' in src


def man_counts(root):
    pages = man_pages(root)
    r = roster(root)
    missing = sorted(r - set(pages))
    if missing:
        raise FactError('roster commands with no page: ' + ' '.join(missing))
    stubs = {n for n, s in pages.items() if is_stub(s) and n not in r}
    other = set(pages) - r - stubs
    return pages, r, stubs, other


SKIP_DIRS = ('.git', 'build', 'vendor', '.deps', '__pycache__')


def walk_files(root):
    """Fallback roster when there is no .git (scripts/box_gate.sh rsyncs
    the tree without it; scripts/check_ascii.py does the same)."""
    import os
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for f in filenames:
            out.append(os.path.relpath(os.path.join(dirpath, f), root))
    return sorted(out)


def git_files(root):
    """Tracked files; with no usable git, every file in the tree (stricter
    on what exists, looser on what is tracked)."""
    try:
        out = subprocess.run(['git', '-C', str(root), 'ls-files', '-z'],
                             capture_output=True, text=True)
    except OSError:
        out = None
    if out is not None and out.returncode == 0 and out.stdout:
        return [p for p in out.stdout.split('\0') if p]
    return walk_files(root)


def tracked(root):
    return set(git_files(root))


def revision(root):
    """Short revision, '-dirty' suffixed when the tree has uncommitted
    changes; MAUX_REVISION overrides; None when neither is available."""
    import os
    env = os.environ.get('MAUX_REVISION')
    if env:
        return env
    try:
        r = subprocess.run(['git', '-C', str(root), 'rev-parse', '--short',
                            'HEAD'], capture_output=True, text=True)
        if r.returncode or not r.stdout.strip():
            return None
        rev = r.stdout.strip()
        st = subprocess.run(['git', '-C', str(root), 'status', '--porcelain',
                             '--untracked-files=no'],
                            capture_output=True, text=True)
        if st.returncode == 0 and st.stdout.strip():
            rev += '-dirty'
        return rev
    except OSError:
        return None


@fact('revision', [], 'MAUX_REVISION, else git rev-parse --short HEAD '
      '(+"-dirty" when tracked files are modified); omitted when neither '
      'exists (build.py special-cases it)')
def f_revision(root):
    return revision(root) or ''


@fact('utility_count', ['Makefile', 'scripts/check_man.py'],
      'Makefile UTILS plus the separately built nas and ld (the man roster)')
def f_utils(root):
    return str(len(roster(root)))


@fact('man_pages_total', ['docs/man'], 'count of docs/man/*.1')
def f_man_total(root):
    return str(len(man_pages(root)))


@fact('man_pages_commands', ['docs/man', 'Makefile'],
      'roster commands that have a page (check_man requires all of them)')
def f_man_cmd(root):
    return str(len(man_counts(root)[1]))


@fact('man_pages_stub', ['docs/man', 'Makefile'],
      'pages not in the roster whose text says "is not provided on maux" '
      '(docs/MAN.md sec 6)')
def f_man_stub(root):
    return str(len(man_counts(root)[2]))


@fact('man_pages_other', ['docs/man', 'Makefile'],
      'pages that are neither roster commands nor stubs (e.g. licenses)')
def f_man_other(root):
    return str(len(man_counts(root)[3]))


@fact('asm_lines', ['src'],
      'newline count over every git-tracked src/**/*.s file (blank lines '
      'and comments included, like wc -l)')
def f_asm_lines(root):
    total = 0
    for f in git_files(root):
        if f.startswith('src/') and f.endswith('.s'):
            total += (root / f).read_bytes().count(b'\n')
    if not total:
        raise FactError('no src/**/*.s files')
    return num(total)


@fact('asm_files', ['src'], 'count of git-tracked src/**/*.s files')
def f_asm_files(root):
    n = sum(1 for f in git_files(root)
            if f.startswith('src/') and f.endswith('.s'))
    if not n:
        raise FactError('no src/**/*.s files')
    return num(n)


def _const(root, name):
    text = read(root, 'scripts/build_play_image.py')
    m = need(re.search(r'^%s\s*=\s*(\d+)\b' % name, text, re.M), name)
    return int(m.group(1))


@fact('volume_blocks', ['scripts/build_play_image.py'],
      'FULL_BLOCKS in build_play_image.py (FULLDISK-NOTES sec 8b)')
def f_vol_blocks(root):
    return num(_const(root, 'FULL_BLOCKS'))


@fact('release_blocks', ['scripts/build_play_image.py'],
      'RELEASE_FILE_BLOCKS = FULL_BLOCKS + 1 (FULLDISK-NOTES sec 8b)')
def f_rel_blocks(root):
    text = read(root, 'scripts/build_play_image.py')
    need(re.search(r'^RELEASE_FILE_BLOCKS\s*=\s*FULL_BLOCKS\s*\+\s*1\b',
                   text, re.M), 'RELEASE_FILE_BLOCKS = FULL_BLOCKS + 1')
    return num(_const(root, 'FULL_BLOCKS') + 1)


@fact('release_bytes', ['scripts/build_play_image.py'],
      'release blocks x 512')
def f_rel_bytes(root):
    return num((_const(root, 'FULL_BLOCKS') + 1) * 512)


def syscalls(root):
    d = root / 'inc'
    if not d.is_dir():
        raise FactError('source dir missing: inc')
    out = []
    for f in sorted(d.glob('sc.*.equ')):
        for ln in f.read_text().split('\n'):
            m = re.match(r'^(SYS_[A-Z0-9_]+)\s+equ\s+(\$[0-9A-Fa-f]+|\d+)\b', ln)
            if m:
                out.append((m.group(1), m.group(2), f.name))
    if not out:
        raise FactError('no SYS_ equates in inc/sc.*.equ')
    return out


@fact('syscall_count', ['inc'],
      'count of SYS_NAME equates in inc/sc.*.equ')
def f_syscalls(root):
    return str(len(syscalls(root)))


PROCESS_C = 'src/kernel/process.s'


def _free_list(root):
    text = read(root, PROCESS_C)
    cnt = need(re.search(r'lda\s+#(\d+)\s*\n\s*sta\s+PRC_FREE_CNT', text),
               'lda #N / sta PRC_FREE_CNT in PRC_INIT')
    top = need(re.search(r'lda\s+#(\d+)\s*\n:freelp\s+sta\s+PRC_FREE_LIST,x',
                         text), 'lda #TOP / :freelp sta PRC_FREE_LIST,x')
    return int(cnt.group(1)), int(top.group(1))


@fact('bank_top', [PROCESS_C],
      'the first bank number PRC_INIT puts in PRC_FREE_LIST (a fixed list '
      'counting down; the release kernel does not probe)')
def f_bank_top(root):
    return str(_free_list(root)[1])


@fact('process_max', [PROCESS_C],
      'PRC_FREE_CNT (banks in the fixed list) + 1 (the shell is bank 1)')
def f_process_max(root):
    return str(_free_list(root)[0] + 1)


@fact('min_ram_kb', [PROCESS_C],
      '(highest bank number + 1) x 64 KB: banks $00 to the top of the list')
def f_min_ram(root):
    return num((_free_list(root)[1] + 1) * 64)


@fact('min_ram_mb', [PROCESS_C],
      'min_ram_kb / 1024, for the places that want the round figure')
def f_min_ram_mb(root):
    kb = (_free_list(root)[1] + 1) * 64
    if kb % 1024:
        raise FactError('bank list is not a whole number of megabytes: %d KB' % kb)
    return str(kb // 1024)


@fact('release_mb', ['scripts/build_play_image.py'],
      'release_bytes / 2^20')
def f_release_mb(root):
    return str((_const(root, 'FULL_BLOCKS') + 1) * 512 // (1 << 20))


@fact('gate_count', ['Makefile'],
      'number of targets in the Makefile variable CHECK_ALL_TARGETS')
def f_gates(root):
    return str(len(makefile_list(root, 'CHECK_ALL_TARGETS')))


@fact('demo_count', ['site/demos'], 'count of site/demos/*.py')
def f_demos(root):
    d = root / 'site/demos'
    if not d.is_dir():
        raise FactError('source dir missing: site/demos')
    return str(len(list(d.glob('*.py'))))


# ---- facts from archived sweep evidence (evidence/README.md) -------------
# These name their revision: a number from a run is only true AT a commit.

SELF = 'evidence/candidate-52a54cf-2026-09-21/check-nas-selfmake.log'
CAND = 'evidence/candidate-52a54cf-2026-09-21/README.md'
MACLOG = 'evidence/candidate-52a54cf-2026-09-21/mac-check-all-cross-par.log'
TITLE = r'`([0-9a-f]{7,})`, (\d{4}-\d\d-\d\d)'


@fact('selfrebuild_utils', [SELF],
      'the "byte-identical: N of M staged utils" line of check-nas-selfmake')
def f_sr_utils(root):
    m = need(re.search(r'byte-identical: (\d+) of (\d+) staged utils',
                       read(root, SELF)), 'byte-identical: N of M staged utils')
    if m.group(1) != m.group(2):
        raise FactError('self-rebuild log is not N of N')
    return m.group(1)


@fact('selfrebuild_kernel_bytes', [SELF],
      'the kernel image line of the same log')
def f_sr_kernel(root):
    m = need(re.search(r'KERNEL[^\n]*?\s(\d+)B\s+byte-identical',
                       read(root, SELF)), 'kernel image byte-identical')
    return num(int(m.group(1)))


@fact('selfrebuild_kernel_k', [SELF],
      'the same kernel image size, in thousands of bytes to one decimal')
def f_sr_kernel_k(root):
    m = need(re.search(r'KERNEL[^\n]*?\s(\d+)B\s+byte-identical',
                       read(root, SELF)), 'kernel image byte-identical')
    return '%.1f' % (int(m.group(1)) / 1000.0)


@fact('selfrebuild_rev', [CAND], 'revision in the evidence README title')
def f_sr_rev(root):
    return need(re.search(TITLE, read(root, CAND)), 'revision, date').group(1)


@fact('selfrebuild_date', [CAND], 'date in the evidence README title')
def f_sr_date(root):
    return need(re.search(TITLE, read(root, CAND)), 'revision, date').group(2)


@fact('sweep_pass', [MACLOG],
      'the "sweep_par: N PASS, M FAIL" line that ends the Mac sweep log')
def f_sweep_pass(root):
    m = need(re.search(r'sweep_par: (\d+) PASS, (\d+) FAIL', read(root, MACLOG)),
             'sweep_par summary')
    if m.group(2) != '0':
        raise FactError('archived sweep has failures')
    return m.group(1)


def resolve(root, names, table=None):
    """Return ({name: value}, [errors]) for the given fact names."""
    table = FACTS if table is None else table
    for n in names:
        # per-utility tallies are named for what the archived run printed
        m = re.fullmatch(r'cf_u_(\w+?)_(?:pass|total|gaps|gate)', n)
        if m and n not in table:
            _reg_tally(m.group(1))
    values, errors = {}, []
    for name in sorted(set(names)):
        f = table.get(name)
        if f is None:
            errors.append('placeholder {{fact:%s}} has no fact' % name)
            continue
        missing = [s for s in f['sources'] if not (root / s).exists()]
        if missing:
            errors.append('fact %s: source missing: %s'
                          % (name, ', '.join(missing)))
            continue
        try:
            values[name] = f['fn'](root)
        except FactError as e:
            errors.append('fact %s: %s' % (name, e))
    return values, errors


def check_sources(root, table=None):
    """Errors for EVERY defined fact whose evidence has gone missing,
    whether or not a page cites it today.

    resolve() above only sees the names a page asked for, so a fact
    dropped from the site stopped having its evidence checked -- which
    is how the self-test's 'fact whose source is missing' row went
    silent the day the home page was rewritten. Existence only: no fact
    is computed here, so this costs a stat per source."""
    table = FACTS if table is None else table
    errors = []
    for name in sorted(table):
        missing = [s for s in table[name]['sources']
                   if not (root / s).exists()]
        if missing:
            errors.append('fact %s: source missing: %s'
                          % (name, ', '.join(missing)))
    return errors


# ---- the plasma cutter, from the archived check-plascut run ---------------
PLASCUT_LOG = 'evidence/plascut-485672f5-2026-10-23/check-plascut.log'
PLASCUT_RE = (r'PC4 FIXTURE\.S warm: cooked (\d+) cycles vs modular (\d+) '
              r'cycles')


def _pc4(root):
    m = need(re.search(PLASCUT_RE, read(root, PLASCUT_LOG)),
             'the PC4 line of check-plascut')
    return int(m.group(1)), int(m.group(2))


def _million(n):
    return '%.2f' % (n / 1e6)


@fact('plascut_cooked_mcycles', [PLASCUT_LOG],
      'PC4 of the archived check-plascut run: warm cooked nas, in millions '
      'of cycles')
def f_pc_cooked(root):
    return _million(_pc4(root)[0])


@fact('plascut_modular_mcycles', [PLASCUT_LOG],
      'PC4 of the archived check-plascut run: the same fixture through '
      'plasma NAS, warm, in millions of cycles')
def f_pc_modular(root):
    return _million(_pc4(root)[1])


@fact('plascut_saved_mcycles', [PLASCUT_LOG], 'PC4: modular minus cooked')
def f_pc_saved(root):
    c, m = _pc4(root)
    return _million(m - c)


@fact('plascut_saved_percent', [PLASCUT_LOG],
      'PC4: (modular - cooked) / modular, rounded')
def f_pc_pct(root):
    c, m = _pc4(root)
    return str(round(100 * (m - c) / m))


@fact('plascut_fixture_bytes', [PLASCUT_LOG],
      'the byte count of the object check-plascut builds from its fixture')
def f_pc_bytes(root):
    m = need(re.search(r'PC2 T\.OBJ \(fixture\): byte-identical to '
                       r'merlin32 \((\d+) bytes\)', read(root, PLASCUT_LOG)),
             'PC2 T.OBJ line')
    return m.group(1)


@fact('plascut_rev', ['evidence/plascut-485672f5-2026-10-23/README.md'],
      'revision in the evidence directory name')
def f_pc_rev(root):
    m = need(re.search(r'# check-plascut at ([0-9a-f]{7,}) ',
                       read(root, 'evidence/plascut-485672f5-2026-10-23/'
                                  'README.md')), 'README title')
    return m.group(1)


# ---- conformance, from the archived conformance gate runs -----------------
# One directory of logs (evidence/README.md), one fact per number. The
# Conformance page prints no number that is not one of these.
CONF = 'evidence/conformance-f9a0e021-2026-10-24'
CONF_SUITES = {
    # key: (log, regex whose two groups are matching and total)
    'util': ('check-posixutil.log', r'\[check-posixutil\] TOTAL (\d+)/(\d+)'),
    'sed': ('check-posixsed.log', r'\[check-posixsed\] PASS: (\d+)/(\d+)'),
    'fowler': ('check-fowler.log', r'\[check-fowler\] (\d+)/(\d+) rows match'),
    'vi': ('check-posixvi.log', r'\[check-posixvi\] (\d+)/(\d+) cases passed'),
    'ex': ('check-posixex.log', r'\[check-posixex\] (\d+)/(\d+) cases passed'),
}


def _conf_log(root, name):
    return read(root, CONF + '/' + name)


def _suite(root, key):
    log, rx = CONF_SUITES[key]
    m = need(re.search(rx, _conf_log(root, log)), key + ' summary line')
    return int(m.group(1)), int(m.group(2))


def _reg_suite(key):
    log = CONF + '/' + CONF_SUITES[key][0]

    @fact('cf_%s_pass' % key, [log], 'archived %s: cases matching' % log)
    def f_pass(root):
        return num(_suite(root, key)[0])

    @fact('cf_%s_total' % key, [log], 'archived %s: cases run' % log)
    def f_total(root):
        return num(_suite(root, key)[1])


for _k in CONF_SUITES:
    _reg_suite(_k)


@fact('cf_util_gaps', [CONF + '/check-posixutil.log'],
      'the "(N known gaps" count of the archived utilities run')
def f_cf_gaps(root):
    m = need(re.search(r'TOTAL \d+/\d+ \((\d+) known gaps',
                       _conf_log(root, 'check-posixutil.log')), 'gap count')
    return m.group(1)


@fact('cf_fowler_unscored', [CONF + '/check-fowler.log'],
      'regcomp-error rows the archived regex run reports but does not score')
def f_cf_fw_unscored(root):
    m = need(re.search(r'(\d+) regcomp-error rows not scored',
                       _conf_log(root, 'check-fowler.log')), 'unscored rows')
    return m.group(1)


def conformance_tallies(root):
    """[(tool, matching, total)] from the per-tool tally block of the
    archived utilities run."""
    text = _conf_log(root, 'check-posixutil.log')
    blk = need(re.search(r'per-tool tallies:\n((?:  \w+: \d+/\d+\n)+)',
                         text), 'per-tool tallies')
    return [(m.group(1), int(m.group(2)), int(m.group(3)))
            for m in re.finditer(r'  (\w+): (\d+)/(\d+)', blk.group(1))]


def conformance_matched(root):
    """[(tool, agreed, total, known_gaps)] per utility. The gate's own
    tally counts a known gap as a pass (it passes while the tool still
    DIFFERS from the host, which is the check on a documented gap), so
    "agreed with the reference" is the gate's figure minus the gaps the
    same log lists for that tool. Derived here, never typed."""
    gaps = {}
    for tool, _name, _head in conformance_gaps(root):
        gaps[tool] = gaps.get(tool, 0) + 1
    tallies = conformance_tallies(root)
    known = {t for t, _a, _b in tallies}
    for tool in gaps:
        if tool not in known:
            raise FactError('gap listed for %s, which has no tally' % tool)
    out = []
    for tool, a, b in tallies:
        g = gaps.get(tool, 0)
        if g > a:
            raise FactError('%s: %d gaps exceed %d passing cases' % (tool, g, a))
        out.append((tool, a - g, b, g))
    gate = _suite(root, 'util')[0]
    if sum(a + g for _t, a, _b, g in out) != gate:
        raise FactError('per-tool tallies do not add up to the gate total')
    return out


def _reg_tally(tool):
    log = CONF + '/check-posixutil.log'
    for which, idx in (('pass', 1), ('total', 2), ('gaps', 3), ('gate', 4)):
        def mk(idx):
            def f(root):
                for t, agreed, total, g in conformance_matched(root):
                    if t == tool:
                        return num((None, agreed, total, g, agreed + g)[idx])
                raise FactError('no tally for ' + tool)
            return f
        FACTS['cf_u_%s_%s' % (tool, which)] = dict(
            name='cf_u_%s_%s' % (tool, which), sources=[log],
            how='per-tool tally of the archived utilities run, known '
                'gaps taken out of the matching count',
            fn=mk(idx))


@fact('cf_util_pass', [CONF + '/check-posixutil.log'],
      'utility cases that agreed with the reference: the gate total minus '
      'the known gaps listed in the same log')
def f_cf_util_pass(root):
    return num(sum(a for _t, a, _b, _g in conformance_matched(root)))


@fact('cf_util_gate', [CONF + '/check-posixutil.log'],
      "the gate's own figure, which counts a known gap that stays "
      'different as a pass')
def f_cf_util_gate(root):
    return num(_suite(root, 'util')[0])


@fact('cf_util_hand', [CONF + '/check-posixutil.log'],
      'cases the archived run marks "hand-authored" (expected output '
      'written by hand, not taken from a host run)')
def f_cf_util_hand(root):
    n = len(re.findall(r'^ +hand-authored: ',
                       _conf_log(root, 'check-posixutil.log'), re.M))
    if n <= 0 or n > _suite(root, 'util')[0]:
        raise FactError('implausible hand-authored count %d' % n)
    return num(n)


@fact('cf_util_host', [CONF + '/check-posixutil.log'],
      'matching cases minus the hand-authored ones: compared with a host run')
def f_cf_util_host(root):
    agreed = sum(a for _t, a, _b, _g in conformance_matched(root))
    n = agreed - int(f_cf_util_hand(root).replace(',', ''))
    if n <= 0:
        raise FactError('no host-compared cases')
    return num(n)


@fact('cf_util_tools', [CONF + '/check-posixutil.log'],
      'number of utilities in the per-tool tally of the archived run')
def f_cf_tools(root):
    return str(len(conformance_tallies(root)))


CF_TITLE = r'^# Conformance runs at ([0-9a-f]{7,}) \((\d{4}-\d\d-\d\d)\)'


@fact('cf_rev', [CONF + '/README.md'], 'revision in the evidence title')
def f_cf_rev(root):
    m = need(re.search(CF_TITLE, read(root, CONF + '/README.md'), re.M),
             'README title')
    return m.group(1)


@fact('cf_date', [CONF + '/README.md'], 'date in the evidence title')
def f_cf_date(root):
    m = need(re.search(CF_TITLE, read(root, CONF + '/README.md'), re.M),
             'README title')
    return m.group(2)


# The gate prints maintainer wording; the page says it plainly. Wording
# only: no number or name passes through here.
PLAIN = (
    (' (held red, permanent)', ' (permanent)'),
    (' is a KNOWN GAP', ' is not supported'),
    (' is unimplemented', ' is not supported'),
    (' is not implemented', ' is not supported'),
    (' are not implemented', ' are not supported'),
    ('regular expressions is not supported', 'regular expressions are not supported'),
    ('a malformed BRE is a usage error (exit 2) on the hosts',
     'a malformed regular expression is an error on other systems; here it '
     'quietly matches nothing'),
)
GAP_RE = re.compile(r'^  (\w+)/(\S+) (.*)$')


def conformance_gaps(root):
    """[(tool, name, headline)] from the KNOWN_GAPS block of the archived
    utilities run; the headline is the text before the first ': ' (the
    rest of the line is maintainer detail)."""
    text = _conf_log(root, 'check-posixutil.log')
    blk = need(re.search(r'\[check-posixutil\] KNOWN_GAPS:\n((?:  .*\n)+)',
                         text), 'KNOWN_GAPS block')
    out = []
    for ln in blk.group(1).split('\n'):
        m = GAP_RE.match(ln)
        if not m:
            continue
        head = m.group(3).split(': ', 1)[0]
        head = ' ' + head
        for a, b in PLAIN:
            head = head.replace(a, b)
        head = head.strip()
        out.append((m.group(1), m.group(2), head))
    if len(out) != int(f_cf_gaps(root)):
        raise FactError('gap list has %d entries, summary says %s'
                        % (len(out), f_cf_gaps(root)))
    return out


# ---- the shell, from the archived check-e2e run ---------------------------
E2E_LOG = CONF + '/check-e2e.log'


def sh_defects(root):
    """The shell constructs the archived run pins as known defects."""
    return re.findall(r'^\[check-e2e\] KNOWN DEFECT sh: (.*)$',
                      read(root, E2E_LOG), re.M)


def _sh_total(root):
    m = need(re.search(r'\[check-e2e\] coverage: .*?\bsh (\d+)\b',
                       read(root, E2E_LOG)), 'sh in the coverage line')
    return int(m.group(1))


@fact('cf_sh_total', [E2E_LOG],
      'sh cases in the coverage line of the archived check-e2e run')
def f_cf_sh_total(root):
    return num(_sh_total(root))


@fact('cf_sh_defects', [E2E_LOG],
      'sh cases the archived check-e2e run pins as known defects')
def f_cf_sh_defects(root):
    return str(len(sh_defects(root)))


@fact('cf_sh_pass', [E2E_LOG],
      'sh cases minus the ones pinned as known defects')
def f_cf_sh_pass(root):
    n = _sh_total(root) - len(sh_defects(root))
    if n <= 0:
        raise FactError('no passing sh cases')
    return num(n)
