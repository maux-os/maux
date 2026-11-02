#!/usr/bin/env python3
r"""check_fowler.py -- the POSIX regex test suites, run against maux's
shared BRE engine (src/liba/regex.s + regex2.s) through sed.
`make check-fowler` (a conformance REPORT: prints the score, exits 1
on any failure; `make vendor-fowler` fetches the corpora).

TWO CORPORA, BOTH AUTHORED FROM THE SPEC, NOT FROM AN IMPLEMENTATION:

  * Glenn Fowler's AT&T regex test suite (basic.dat, nullsubexpr.dat,
    repetition.dat -- the copies Go's regexp package carries, which
    drop the collation rows). Each row: flags, pattern, string, and
    the expected match array as (start,end) pairs per group, or
    NOMATCH, or a regcomp error code. Rows whose flags include `B`
    (basic RE) are taken; `$` expands C escapes; rows that need a
    newline or a byte outside ASCII cannot be one maux text line and
    are skipped, counted.
  * Henry Spencer's regex tests (Tcl's tests/reg.test -- Spencer wrote
    POSIX's regex chapter). Rows `expectMatch`/`expectNomatch`/
    `expectError` whose flags say BRE (`b`, or `&` = ARE and BRE) and
    carry no non-POSIX (`P`), locale (`L`), machine (`M`) or
    backslash-alnum (`A`) construct and no match-mode flag (`^ $ + %
    * i o p w n x t q`) are taken. Expected: the matched text and the
    subexpression texts.

THE VEHICLE: sed. Cases are batched twelve to a script,

    k{
    s<d>RE<d>{&}|\1|\2|\3|\4|\5|\6|\7|\8|\9<d>p
    =
    }

over an input file whose line k is case k's string, run under -n
through maux's own shell exactly as check_posixsed.py does. A matched
case prints `prefix{match}|g1|...|g9suffix` then its line number; an
unmatched case prints the number alone. <d> is a delimiter absent from
the pattern. Expected lines are BUILT from the corpus's positions, so
the comparison is byte-exact -- with one known blind spot: an UNSET
group and an EMPTY group both print as nothing, so `(?,?)` is not
distinguished from `(3,3)`.

Rows whose expected outcome is a regcomp ERROR (BADBR, EBRACK, ...,
Spencer's expectError) are reported separately: maux's engine has no
compile step -- a malformed RE is a safe no-match -- so sed neither
refuses nor matches. They count as neither pass nor fail here; they
are the diagnostics story, not the matching story.
"""
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_vi as V                                    # noqa: E402
import check_posixsed as P                              # noqa: E402
import scratchclean as SC                               # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR    # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import a2til                                             # noqa: E402
from a2til import prodos                                 # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'play.po')
CORPUS = os.path.join(ROOT, 'vendor', 'fowler')
SUBDIR = '/mnt/MAUX/FW'
SCRATCH = os.environ.get(
    'FOWLER_SCRATCH', os.path.join(tempfile.gettempdir(), 'maux-fowler'))
#: Scratch images this run made, by name (scratchclean.py).
MADE = []
PER_SCRIPT = int(os.environ.get('FOWLER_PER_SCRIPT', '12'))
                         # 4 sed commands per case, SED_MAXCMD = 48
DUMP = os.environ.get('FOWLER_DUMP') == '1'
DELIMS = '/,@#!%:~+='
REPL_TAIL = '|\\1|\\2|\\3|\\4|\\5|\\6|\\7|\\8|\\9'


# ======================================================================
# a case
# ======================================================================
class Case:
    def __init__(self, src, name, regex, string, kind, match=None,
                 groups=None, note=''):
        self.src = src            # 'fowler:basic.dat' / 'spencer'
        self.name = name          # file:line or test number
        self.regex = regex
        self.string = string
        self.kind = kind          # 'match' | 'nomatch' | 'error'
        self.match = match        # (start, end) for fowler; text for spencer
        self.groups = groups or []  # fowler: [(s,e)|None]; spencer: [text]
        self.note = note
        self.delim = None
        for d in DELIMS:
            if d not in regex:
                self.delim = d
                break

    def label(self):
        return f'{self.src} {self.name}: /{self.regex}/ on {self.string!r}'


def one_line(s):
    """Can this be a maux text line? (no newline, no NUL, 7-bit)"""
    return all(0x01 <= ord(c) < 0x80 and c != '\n' and c != '\r' for c in s)


# ======================================================================
# Fowler .dat loader
# ======================================================================
def c_unescape(s):
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c != '\\' or i + 1 >= len(s):
            out.append(c)
            i += 1
            continue
        n = s[i + 1]
        i += 2
        if n == 'n':
            out.append('\n')
        elif n == 't':
            out.append('\t')
        elif n == 'r':
            out.append('\r')
        elif n == 'x':
            hexd = ''
            while i < len(s) and len(hexd) < 2 and s[i] in '0123456789abcdefABCDEF':
                hexd += s[i]
                i += 1
            out.append(chr(int(hexd, 16)) if hexd else 'x')
        elif n in '01234567':
            octd = n
            while i < len(s) and len(octd) < 3 and s[i] in '01234567':
                octd += s[i]
                i += 1
            out.append(chr(int(octd, 8)))
        else:
            out.append('\\' + n)   # a regex escape, not a C one
    return ''.join(out)


def parse_positions(res):
    """'(0,3)(1,2)(?,?)' -> [(0,3),(1,2),None]"""
    pos = []
    s = res
    while s:
        if s[0] != '(':
            return None
        close = s.find(')')
        if close < 0:
            return None
        a, _, b = s[1:close].partition(',')
        if a == '?' or b == '?':
            pos.append(None)
        else:
            try:
                pos.append((int(a), int(b)))
            except ValueError:
                return None
        s = s[close + 1:]
    return pos


def load_fowler(path):
    cases, skipped = [], []
    last_regex = ''
    src = 'fowler:' + os.path.basename(path)
    for lineno, raw in enumerate(open(path, encoding='latin-1'), 1):
        line = raw.rstrip('\n')
        if not line or line.startswith('#') or line.startswith('NOTE'):
            continue
        fields = line.split('\t')
        fields = [f for f in fields if f != '']
        if len(fields) < 4:
            continue
        flags = fields[0]
        if flags[0] in '?&|;{}':          # Go's "disabled" markers
            skipped.append((f'{src}:{lineno}', 'disabled in this copy'))
            continue
        if flags[0] in 'CNT0123456789:':  # control lines
            continue
        if 'B' not in flags:
            continue
        if any(c.islower() for c in flags):
            skipped.append((f'{src}:{lineno}', f'mode flag {flags!r}'))
            continue
        regex, string, result = fields[1], fields[2], fields[3]
        if '$' in flags:
            regex, string = c_unescape(regex), c_unescape(string)
        if regex == 'SAME':
            regex = last_regex
        last_regex = regex
        if string == 'NULL':
            string = ''
        if not one_line(regex) or not one_line(string):
            skipped.append((f'{src}:{lineno}', 'newline/NUL/8-bit'))
            continue
        name = f'{lineno}'
        if result == 'NOMATCH':
            cases.append(Case(src, name, regex, string, 'nomatch'))
        elif result and result[0].isupper():
            cases.append(Case(src, name, regex, string, 'error', note=result))
        else:
            pos = parse_positions(result)
            if not pos or pos[0] is None:
                skipped.append((f'{src}:{lineno}', f'result {result!r}'))
                continue
            cases.append(Case(src, name, regex, string, 'match',
                              match=pos[0], groups=pos[1:]))
    return cases, skipped


# ======================================================================
# Spencer reg.test loader
# ======================================================================
def tcl_words(s):
    """Split a Tcl command line into words: {braces} literal, "quotes"
    and bare words with \\-escapes. Good enough for reg.test."""
    words = []
    i, n = 0, len(s)
    while i < n:
        while i < n and s[i] in ' \t':
            i += 1
        if i >= n:
            break
        if s[i] == '{':
            depth, j = 0, i
            while j < n:
                if s[j] == '{':
                    depth += 1
                elif s[j] == '}':
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            words.append(s[i + 1:j])
            i = j + 1
            continue
        quoted = s[i] == '"'
        if quoted:
            i += 1
        out = []
        while i < n:
            c = s[i]
            if quoted and c == '"':
                i += 1
                break
            if not quoted and c in ' \t':
                break
            if c == '\\' and i + 1 < n:
                nx = s[i + 1]
                i += 2
                out.append({'n': '\n', 't': '\t', 'r': '\r'}.get(nx, nx))
                continue
            out.append(c)
            i += 1
        words.append(''.join(out))
    return words


SPENCER_SKIP_UPPER = set('PLMAHTU')
SPENCER_SKIP_MODE = set('^$+%*iopwnxtqea')


def load_spencer(path):
    cases, skipped = [], []
    src = 'spencer'
    for lineno, raw in enumerate(open(path, encoding='latin-1'), 1):
        line = raw.rstrip('\n')
        if not line.startswith('expect'):
            continue
        words = tcl_words(line)
        if len(words) < 4:
            continue
        verb, num, flags = words[0], words[1], words[2]
        if 'b' not in flags and '&' not in flags:
            continue
        if set(flags) & SPENCER_SKIP_UPPER or set(flags) & SPENCER_SKIP_MODE:
            skipped.append((f'{src} {num}', f'flags {flags!r}'))
            continue
        regex = words[3]
        if verb == 'expectError':
            cases.append(Case(src, num, regex, '', 'error',
                              note=words[4] if len(words) > 4 else ''))
            continue
        if len(words) < 5:
            continue
        string = words[4]
        if not one_line(regex) or not one_line(string):
            skipped.append((f'{src} {num}', 'newline/NUL/8-bit'))
            continue
        if verb == 'expectNomatch':
            cases.append(Case(src, num, regex, string, 'nomatch'))
        elif verb == 'expectMatch':
            if len(words) < 6:
                continue
            cases.append(Case(src, num, regex, string, 'match',
                              match=words[5], groups=words[6:]))
    return cases, skipped


# ======================================================================
# expectations
# ======================================================================
def fowler_expected_line(c):
    s, e = c.match
    st = c.string
    g = []
    for i in range(9):
        if i < len(c.groups) and c.groups[i] is not None:
            a, b = c.groups[i]
            g.append(st[a:b])
        else:
            g.append('')
    return st[:s] + '{' + st[s:e] + '}' + '|' + '|'.join(g) + st[e:]


def spencer_expected_lines(c):
    """Every position where the expected match text occurs."""
    st, m = c.string, c.match
    g = [c.groups[i] if i < len(c.groups) else '' for i in range(9)]
    tail = '|' + '|'.join(g)
    lines = []
    i = st.find(m)
    while i >= 0:
        lines.append(st[:i] + '{' + m + '}' + tail + st[i + len(m):])
        i = st.find(m, i + 1)
    return lines


# ======================================================================
# the maux run
# ======================================================================
def script_for(batch):
    lines = []
    for k, c in enumerate(batch, 1):
        d = c.delim
        lines.append(f'{k}{{')
        lines.append(f's{d}{c.regex}{d}{{&}}{REPL_TAIL}{d}p')
        lines.append('=')
        lines.append('}')
    return lines


def stage(img, batches, tags):
    prodos.mount(img)
    try:
        try:
            prodos.mkdir(SUBDIR)
        except Exception:
            pass
        for tag, batch in zip(tags, batches):
            prodos.write(f'{SUBDIR}/{tag}I',
                         P.hilines([c.string for c in batch]),
                         file_type=0x04, aux_type=0x0000, overwrite=True)
            prodos.write(f'{SUBDIR}/{tag}S', P.hilines(script_for(batch)),
                         file_type=0x04, aux_type=0x0000, overwrite=True)
    finally:
        try:
            prodos.unmount('MAUX')
        except Exception:
            pass


def run_batches(env, batches, tags, img):
    client = MCPClient([SUPERVISOR], env)
    err = {}
    try:
        P.boot(client, img)
        for tag in tags:
            try:
                V.t(client, f'SED -n -f {SUBDIR}/{tag}S {SUBDIR}/{tag}I '
                            f'> {SUBDIR}/{tag}O\r')
                V.settle(client, V._at_prompt, f'{tag} finished',
                         max_steps=4000)
            except Exception as e:  # noqa: BLE001
                err[tag] = f'{type(e).__name__}: {e}'
                try:
                    P.recover(client)
                except Exception:
                    break
    finally:
        try:
            client.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        client.close()
    return err


def parse_output(lines):
    """[(k, result-or-None)] from the p/= stream."""
    got = {}
    pending = None
    for ln in lines:
        if ln.isdigit():
            got[int(ln)] = pending
            pending = None
        else:
            pending = ln
    return got


# ======================================================================
# main
# ======================================================================
def main():
    try:
        rc = run()
    except BaseException:
        SC.settle('check-fowler', SCRATCH, MADE, False)
        raise
    SC.settle('check-fowler', SCRATCH, MADE, rc == 0)
    return rc


def run():
    global DISK
    argv = sys.argv[1:]
    if argv and argv[0].endswith('.po'):
        DISK = os.path.abspath(argv.pop(0))
    if not os.path.exists(DISK):
        print(f'error: {DISK} not found -- run make play-image first',
              file=sys.stderr)
        return 2
    files = [os.path.join(CORPUS, f) for f in
             ('basic.dat', 'nullsubexpr.dat', 'repetition.dat')]
    spencer = os.path.join(CORPUS, 'reg.test')
    for f in files + [spencer]:
        if not os.path.exists(f):
            print(f'error: {f} missing -- run make vendor-fowler',
                  file=sys.stderr)
            return 2

    cases, skipped = [], []
    for f in files:
        c, s = load_fowler(f)
        cases += c
        skipped += s
    c, s = load_spencer(spencer)
    cases += c
    skipped += s
    nodelim = [c for c in cases if c.delim is None]
    cases = [c for c in cases if c.delim is not None]
    errors = [c for c in cases if c.kind == 'error']
    runnable = [c for c in cases if c.kind != 'error']
    print(f'[check-fowler] {len(runnable)} runnable rows '
          f'({sum(1 for c in runnable if c.src.startswith("fowler"))} Fowler, '
          f'{sum(1 for c in runnable if c.src == "spencer")} Spencer), '
          f'{len(errors)} regcomp-error rows reported separately, '
          f'{len(skipped) + len(nodelim)} skipped (newline/8-bit/mode flags)')

    batches = [runnable[i:i + PER_SCRIPT]
               for i in range(0, len(runnable), PER_SCRIPT)]
    tags = [f'F{i:03d}' for i in range(len(batches))]
    os.makedirs(SCRATCH, exist_ok=True)
    img = os.path.join(SCRATCH, 'fowler.po')
    shutil.copy(DISK, img)
    MADE.append(img)
    stage(img, batches, tags)
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    err = run_batches(env, batches, tags, img)

    vol = a2til.open_image(img)
    passed, failed, harness = [], [], []
    for tag, batch in zip(tags, batches):
        if tag in err:
            harness += [(c, err[tag]) for c in batch]
            continue
        try:
            out = P.maux_lines(bytes(vol.read_file(f'{SUBDIR}/{tag}O')))
        except Exception as e:  # noqa: BLE001
            harness += [(c, f'read-back: {e}') for c in batch]
            continue
        got = parse_output(out)
        if DUMP:
            print(f'[check-fowler] {tag} raw: {out!r}')
        for k, c in enumerate(batch, 1):
            if k not in got:
                harness.append((c, 'no line-number marker in the output'))
                continue
            res = got[k]
            if c.kind == 'nomatch':
                ok = res is None
                want = 'NOMATCH'
            elif c.src == 'spencer':
                want = spencer_expected_lines(c)
                ok = res in want
                want = want[0] if want else '?'
            else:
                want = fowler_expected_line(c)
                ok = res == want
            (passed if ok else failed).append((c, want, res))

    for c, want, res in failed:
        print(f'[check-fowler] FAIL {c.label()}\n'
              f'    expected {want!r}\n    got      {res!r}')
    for c, why in harness:
        print(f'[check-fowler] HARNESS {c.label()}: {why}')
    print()
    print(f'[check-fowler] {len(passed)}/{len(passed) + len(failed)} rows '
          f'match the corpus expectations '
          f'({len(harness)} harness errors, {len(errors)} regcomp-error rows '
          f'not scored, {len(skipped) + len(nodelim)} skipped)')
    if errors:
        print('[check-fowler] regcomp-error rows (maux fails safe, no '
              'diagnostic): ' + ', '.join(f'{c.src} {c.name} /{c.regex}/'
                                          for c in errors[:20])
              + (' ...' if len(errors) > 20 else ''))
    if skipped or nodelim:
        why = {}
        for _, w in skipped:
            why[w] = why.get(w, 0) + 1
        if nodelim:
            why['no free delimiter'] = len(nodelim)
        print('[check-fowler] skipped: ' +
              ', '.join(f'{k} x{v}' for k, v in sorted(why.items())))
    return 1 if (failed or harness) else 0


if __name__ == '__main__':
    raise SystemExit(main())
