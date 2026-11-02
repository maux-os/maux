#!/usr/bin/env python3
r"""check_posixsed.py -- POSIX sed conformance gate for maux's sed
(src/bin/sed.s + sedparse.s/sedexec.s/sedsel.s/sedio.s/sedout.s).
`make check-posixsed`; in the box sweep.

THE ORACLE IS THE HOST'S OWN sed (docs/E2E.md sec 4, stage 1): every
CASES row feeds the IDENTICAL script (as a -f file, exactly the form
maux receives) and the IDENTICAL input through the host sed, and the
translated stdout, the exit status, and every file the script wrote
are compared BYTE-EXACT. Nothing here is a hand-authored expectation
and nothing may ever be captured from a maux run.

METHOD (check_posixex.py's, which proved it): every case is staged
with a2til into a FRESH subdirectory of a copy of build/play.po
(/mnt/MAUX/PXSD/ -- the volume root cannot grow, a subdirectory can), the
image is booted once per batch, and each case is TWO lines typed at
the shell prompt,

    SED [args] -f /mnt/MAUX/PXSD/<tag>S /mnt/MAUX/PXSD/<tag>I > <tag>O
    echo $? > /mnt/MAUX/PXSD/<tag>X

so the script travels as a file (multi-line text, labels on their own
lines, w filenames to end of line -- everything a shell word cannot
carry) and the exit status is captured by maux's own shell. A few
rows type -e/-n/bare-operand forms instead, to prove the option layer.

TWO HOST FLAVOURS ORACLE THIS GATE -- BSD sed on the Mac, GNU sed 4.9
on the Linux gate box -- and the cases are restricted to constructs
the two agree on, so a green run means the same bytes under both.
Where they disagree the CASE is written around it (each such choice
is a DIVERGENCE row in check_sed.py, the sibling gate):
  - N with no next line: BSD/POSIX quit silently, GNU prints. Cases
    use $!N, or an even line count.
  - labels: BSD reads a b/t/: label to END OF LINE (a ';' is part
    of it); GNU stops at ';'. Every label sits on its own line.
  - a/i/c: BSD needs `a\` + newline; GNU also takes `a text`. Cases
    use the POSIX form only.
  - `}` must be preceded by ';' or a newline for BSD: `2{p;}`.
  - s///Ng: BSD refuses. Not staged.
  - l on a multi-line space: BSD writes `$` + a line break at the
    embedded newline, GNU writes `\n`. Only single-line l is staged;
    BSD's fold width is the terminal's (COLUMNS), so the host runs
    under COLUMNS=70, GNU's fixed default.
  - `q5`: BSD refuses the exit code. Not staged (check_sed's row).
  - l on a literal backslash: this Mac's sed writes a bare `\` where
    POSIX and GNU write `\\`. FOUND BY THIS GATE (its first BSD run,
    2026-09-11): the backslash case is marked gnu_only and skipped
    when the oracle is not GNU sed, so the box still proves it.

Teeth: on the pre-uplift sed (7a88e52 -- p/d/q/s only, '/' the only
delimiter, no -f) every -f row is a usage error, so the whole table
is red except nothing; the suite is meaningless there by
construction, which is the point of a differential gate.
"""
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_vi as V                                    # noqa: E402
import scratchclean as SC                               # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR    # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import a2til                                             # noqa: E402
from a2til import prodos                                 # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'play.po')
SUBDIR = '/mnt/MAUX/PXSD'
HOST_SED = os.environ.get('HOST_SED', 'sed')
SCRATCH = os.environ.get(
    'POSIXSED_SCRATCH',
    os.path.join(tempfile.gettempdir(), 'maux-posixsed'))
BATCH = 12
#: Scratch images this run made, by name (scratchclean.py).
MADE = []


# ======================================================================
# text/encoding helpers
# ======================================================================
def hi(s):
    return bytes(ord(c) | 0x80 for c in s)


def hilines(lines):
    """A liba text file: high-bit ASCII, CR ($8D) per line, incl. the
    last."""
    return b''.join(hi(ln) + bytes([0x8D]) for ln in lines)


def maux_lines(raw):
    got = bytes(b & 0x7F for b in raw).decode('ascii', errors='replace')
    lines = got.split('\r')
    if lines and lines[-1] == '':
        lines = lines[:-1]
    return lines


def host_lines(text):
    lines = text.split('\n')
    if lines and lines[-1] == '':
        lines = lines[:-1]
    return lines


def render(items, mapping):
    out = []
    for it in items:
        for k, v in mapping.items():
            it = it.replace(f'@{k}@', v)
        out.append(it)
    return out


# ======================================================================
# case table
# ======================================================================
# Each case is a dict:
#   group, name    -- report keys
#   inp            -- lines of the main input (@I@)
#   script         -- lines of the -f script, or None (args carry it)
#   args           -- extra argv words typed BEFORE -f/the input
#                     (e.g. ['-n'], or ['-e', "'p'"] when script is
#                     None); '@I2@'-style words name extra inputs
#   extra          -- {TAG: lines} files staged beside the input (an
#                     r source, a second input); {TAG: None} for a
#                     file the script WRITES (must not pre-exist)
#   results        -- TAGs to compare as files after the run
#   note
def C(group, name, inp, script, args=(), extra=None, results=(), note='',
      gnu_only=False):
    return dict(group=group, name=name, inp=inp, script=script,
                args=list(args), extra=extra or {}, results=list(results),
                note=note, gnu_only=gnu_only)


def host_is_gnu():
    try:
        r = subprocess.run([HOST_SED, '--version'], capture_output=True,
                           text=True, timeout=5)
    except Exception:
        return False
    return r.returncode == 0 and 'GNU' in r.stdout


L4 = ['alpha one', 'hello bell', 'gamma low', 'delta end']
N5 = ['1', '2', '3', '4', '5']
LONG = ''.join(chr(ord('a') + (i % 26)) for i in range(100))

CASES = [
    # ---- substitute --------------------------------------------------
    C('s', 'basic', L4, ['s/l/L/']),
    C('s', 'g flag', L4, ['s/l/L/g']),
    C('s', 'Nth match', L4, ['s/l/L/2']),
    C('s', 'Np with -n', L4, ['s/l/L/2p'], ['-n']),
    C('s', 'null matches under g', ['abc', 'hello'], ['s/x*/-/g']),
    C('s', 'null-adjacent rule', ['hello'], ['s/l*/X/g']),
    C('s', 'anchor with g fires once', ['aaa'], ['s/^a/X/g']),
    C('s', 'groups and backrefs in repl', ['hello world'],
      [r's/\(h[a-z]*\) \(w[a-z]*\)/\2 \1/']),
    C('s', 'escaped ampersand', ['ab'], [r's/a/[\&]/']),
    C('s', 'ampersand', L4, ['s/gamma/[&]/']),
    C('s', 'comma delimiter', ['a/b'], ['s,/,|,']),
    C('s', 'delimiter inside brackets', ['a/b'], ['s/[/]/X/']),
    C('s', 'backslash-newline in repl', ['ab'], ['s/a/&\\', '/']),
    C('s', 'newline escape in repl', ['ab'], [r's/a/1\n2/']),
    C('s', 'interval', ['12345 1234 123'], [r's/[0-9]\{4\}/X/g']),
    C('s', 'empty RE reuses the last', ['foo', 'bar'],
      ['/fo*/s//X/']),
    C('s', 'flags gp with -n', ['aa', 'bb'], ['s/a/X/gp'], ['-n']),
    C('s', 'no match leaves the line', L4, ['s/zzz/Q/']),

    # ---- addresses -----------------------------------------------------
    C('addr', 'line number', N5, ['2p'], ['-n']),
    C('addr', 'last line', N5, ['$p'], ['-n']),
    C('addr', 'numeric range delete', N5, ['2,3d']),
    C('addr', 'regex address', L4, ['/ell/p'], ['-n']),
    C('addr', 'regex range', ['a', 'b', 'c', 'a', 'b'],
      ['/a/,/b/p'], ['-n']),
    C('addr', 'regex range end searched from next line',
      ['a', 'b', 'a', 'b'], ['/a/,/a/p'], ['-n']),
    C('addr', 'regex range delete', ['a', 'b', 'c', 'a', 'b', 'c'],
      ['/a/,/b/d']),
    C('addr', 'regex range whose end never comes', ['x', 'a', 'b', 'c'],
      ['/a/,/zzz/p'], ['-n']),
    C('addr', 'number to regex', N5, ['2,/4/p'], ['-n']),
    C('addr', 'regex to number', N5, ['/2/,4p'], ['-n']),
    C('addr', 'regex range with s inside', ['a', 'b', 'c', 'd'],
      ['/b/,/c/s/^/>/']),
    C('addr', 'range reopens after closing',
      ['a', 'x', 'b', 'y', 'a', 'x', 'b'], ['/a/,/b/p'], ['-n']),
    C('addr', 'addr2 below addr1 selects one line', N5, ['2,1p'], ['-n']),
    C('addr', 'regex then passed number', N5, ['/3/,2p'], ['-n']),
    C('addr', 'custom delimiter address', ['a/b', 'c'],
      [r'\,/,p'], ['-n']),
    C('addr', 'negation', N5, ['2!d']),
    C('addr', 'negated range', N5, ['2,3!d']),
    C('addr', 'negation with a blank', N5, ['2 ! d']),
    C('addr', 'last line of the last file', N5, ['$p'], ['-n', '@I2@'],
      {'I2': ['x', 'y']}),
    C('addr', 'newline in an address RE', ['a', 'b', 'c', 'd'],
      ['$!N', r'/a\nb/p'], ['-n']),

    # ---- text: a i c ---------------------------------------------------
    C('text', 'i', ['z'], ['1i\\', 'INS']),
    C('text', 'a', ['1', '2'], ['1a\\', 'APP']),
    C('text', 'c one line', N5, ['2c\\', 'CHG']),
    C('text', 'c over a range prints once', N5, ['2,3c\\', 'CHG']),
    C('text', 'c to $', ['1', '2', '3'], ['2,$c\\', 'END']),
    C('text', 'c negated', ['1', '2', '3'], ['2!c\\', 'X']),
    C('text', 'multi-line text', ['z'], ['1a\\', 'one\\', 'two']),
    C('text', 'leading blanks kept', ['z'], ['1i\\', '   lead']),
    C('text', 'a on the last line', ['1', '2'], ['$a\\', 'END']),
    C('text', 'a and i print under -n', ['1'],
      ['i\\', 'INS', 'a\\', 'APP'], ['-n']),
    C('text', 'a then q flushes', ['1', '2'], ['1a\\', 'APP', '1q']),
    C('text', 'backslash in text', ['z'], ['a\\', 'x\\\\y\\qz'],
      note='POSIX: a backslash in text is removed and the next char '
           'taken literally. \\t is NOT used: GNU would make it a tab'),

    # ---- hold space ------------------------------------------------------
    C('hold', 'tac', ['1', '2', '3'], ['1!G', 'h', '$!d']),
    C('hold', 'H then x at the end', ['1', '2', '3'],
      ['H', '${x;s/\\n/,/g;p;}'], ['-n']),
    C('hold', 'g from empty hold', ['a', 'b'], ['1g']),
    C('hold', 'G on empty hold', ['a'], ['G']),
    C('hold', 'x on line 1', ['a', 'b'], ['x']),
    C('hold', 'h then G', ['ab'], ['h', 's/a/X/', 'G']),

    # ---- multi-line: N P D ------------------------------------------------
    C('multi', '$!N;P;D', ['1', '2', '3'], ['$!N', 'P', 'D']),
    C('multi', 'N joins pairs', ['1', '2', '3', '4'], ['N', r's/\n/+/']),
    C('multi', '$!N join', ['1', '2', '3'], ['$!N', r's/\n/ /']),
    C('multi', 'N;N on three', ['a', 'b', 'c'], ['N', 'N', r's/\n/,/g']),
    C('multi', 'D without newline is d', ['a', 'b'], ['D']),
    C('multi', 'P without newline', ['ab'], ['P'], ['-n']),
    C('multi', 'bracket newline class', ['a', 'b'], ['N', r's/[^\n]*\n//']),
    C('multi', 'dot spans the newline', ['ab', 'cd'], ['N', 's/b.c/X/']),

    # ---- flow: b t : { } -----------------------------------------------
    C('flow', 'b to label', ['1', '2', '3'],
      ['/2/b skip', 's/^/X/', ':skip']),
    C('flow', 'b to end', ['1', '2'], ['b', 's/./X/']),
    C('flow', 't loop', ['xxxa'], [':a', 's/x//', 'ta']),
    C('flow', 't not taken', ['a', 'b'], ['s/a/A/', 't', 's/$/!/']),
    C('flow', 'block', N5, ['2{p;}'], ['-n']),
    C('flow', 'nested blocks', ['1', '2', '3'],
      ['1,3{/2/{p;};}'], ['-n']),
    C('flow', 'negated block', ['1', '2', '3'], ['2!{p;}'], ['-n']),
    C('flow', 'block with two commands', ['1', '2'],
      ['1{s/1/X/;p;}'], ['-n']),

    # ---- y = l ------------------------------------------------------------
    C('misc', 'y', ['abcabc'], ['y/abc/xyz/']),
    C('misc', 'y with escaped delimiter', ['a/b'], [r'y/\//|/']),
    C('misc', 'y newline', ['a b', 'c'], ['N', r'y/\n /_-/']),
    C('misc', '= on every line', ['a', 'b'], ['=']),
    C('misc', '= last line with -n', ['a', 'b', 'c'], ['$='], ['-n']),
    C('misc', 'l escapes', ['a\tb\x01c\x7fd'], ['l'], ['-n']),
    C('misc', 'l backslash', ['a\\b'], ['l'], ['-n'], gnu_only=True,
      note='POSIX and GNU write \\\\; this Mac\'s BSD sed writes a bare '
           '\\ -- non-conformant, so BSD cannot oracle it'),
    C('misc', 'l folds long lines', [LONG], ['l'], ['-n']),

    # ---- q n -------------------------------------------------------------
    C('cycle', '2q', ['1', '2', '3'], ['2q']),
    C('cycle', 'n;d prints odd lines', N5, ['n', 'd']),
    C('cycle', 'n then s', ['a', 'b', 'c'], ['n', 's/./X/']),

    # ---- r w -------------------------------------------------------------
    C('file', 'r inserts a file', ['1', '2'], ['1r @R@'],
      extra={'R': ['RFILE']}),
    C('file', 'r of a missing file is nothing', ['1', '2'],
      ['1r @NOSUCH@'], extra={'NOSUCH': None}),
    C('file', 'a and r keep order', ['1', '2'],
      ['1r @R@', '1a\\', 'APP'], extra={'R': ['RFILE']}),
    C('file', 'w writes the file', ['a', 'b'], ['w @W@'], ['-n'],
      extra={'W': None}, results=['W']),
    C('file', 's///w', ['a', 'b'], ['s/a/X/w @W@'],
      extra={'W': None}, results=['W']),
    C('file', 'addressed w', ['a', 'b', 'a'], ['/a/w @W@', 'p'], ['-n'],
      extra={'W': None}, results=['W']),

    # ---- options / script forms ------------------------------------------
    C('opt', 'bare script operand', ['1', '2'], None, ["'2d'"]),
    C('opt', '-e twice', ['a'], None, ['-e', "'s/a/b/'", '-e', "'p'"]),
    C('opt', '-n -e', ['a', 'b'], None, ['-n', '-e', "'2p'"]),
    C('opt', '#n first line', ['a', 'b'], ['#n', '2p']),
    C('opt', 'comments', ['a'], ['# a comment', 's/a/X/', '# another']),
    C('opt', 'empty script', ['a', 'b'], ['']),
    C('opt', '-e before -f', ['z'], ['s/Z/Q/'], ['-e', "'s/z/Z/'"]),
    C('opt', 'semicolons and blanks', ['a'], ['s/a/b/ ; p ; s/b/c/'],
      ['-n']),

    # ---- the regex engine: POSIX BRE (W5d) --------------------------------
    # classes, C locale
    C('regex', 'class digit interval', ['a12b'], [r's/[[:digit:]]\{2\}/X/']),
    C('regex', 'class alpha star', ['abc9'], ['s/[[:alpha:]]*/X/']),
    C('regex', 'class space', ['a b\tc'], ['s/[[:space:]]/_/g']),
    C('regex', 'negated class alnum', ['a-b c.d'], ['s/[^[:alnum:]]/_/g']),
    C('regex', 'two classes in one bracket', ['aB3c'],
      ['s/[[:upper:][:digit:]]/X/g']),
    C('regex', 'class beside a member', ['a1b2'], ['s/[a[:digit:]]/X/g']),
    C('regex', 'class then dash', ['a-b'], ['s/[[:alpha:]-]/X/g']),
    C('regex', 'blank punct xdigit', ['a, f\tG'],
      ['s/[[:blank:]]/_/g', 's/[[:punct:]]/P/g', 's/[[:xdigit:]]/H/g']),
    C('regex', 'lower upper cntrl print', ['aB\x01c'],
      ['s/[[:lower:]]/l/g', 's/[[:upper:]]/U/g', 's/[[:cntrl:]]/C/g',
       's/[[:print:]]/./g']),
    C('regex', 'graph', ['a b'], ['s/[[:graph:]]/G/g']),
    C('regex', 'equivalence class', ['bab'], ['s/[[=a=]]/X/']),
    C('regex', 'collating symbol', ['bab'], ['s/[[.a.]]/X/']),
    C('regex', 'collating dash as a member', ['a-b'], ['s/[[.-.]a]/X/g']),
    C('regex', 'class inside a bracket with the delimiter', ['a/b'],
      ['s/[[:alpha:]/]/X/g']),
    # leftmost-longest
    C('regex', 'longest: star then repeated group', ['xxy'],
      [r's/x*\(xy\)*/[&]/']),
    C('regex', 'longest: star then optional group', ['xxy'],
      [r's/x*\(xy\)\{0,1\}/[&]/']),
    C('regex', 'longest: star then group star', ['aabab'],
      [r's/a*\(ab\)*/[&]/']),
    C('regex', 'longest: starred group then literal', ['aab'],
      [r's/\(a*\)*b/[&]/']),
    C('regex', 'longest: captures follow the longest', ['xxy'],
      [r's/x*\(xy\)*/<\1>/']),
    C('regex', 'longest under g', ['xxy xxy'],
      [r's/x*\(xy\)*/[&]/g']),
    C('regex', 'longest with an address', ['xxy', 'zz'],
      [r'/x*\(xy\)*y/d']),
    # the star fast path before a group / backref (REGEX-FASTPATH-GROUP.md)
    C('regex', 'star before a group', ['ab'], [r's/[ab]*\(b\)/X/']),
    C('regex', 'star before a group, capture', ['aab'],
      [r's/[ab]*\(b\)/[\1]/']),
    C('regex', 'star before a group, disjoint control', ['ab'],
      [r's/a*\(b\)/X/']),
    C('regex', 'star before a close paren', ['aab'],
      [r's/\(a*\)ab/[\1]/']),
    C('regex', 'star before a backref', ['aaa'],
      [r's/\(a\)[a]*\1/X/']),
    # group repeats past the old cap of 8
    C('regex', 'group repeated 11 times', ['ababababababababababab'],
      [r's/\(ab\)*/[&]/']),
    C('regex', 'group interval of 10', ['abababababababababababab'],
      [r's/\(ab\)\{10\}/[&]/']),
    # positional rules and anchors inside groups
    C('regex', 'star first is literal', ['*a'], ['s/*a/X/']),
    C('regex', 'caret mid is literal', ['a^b'], ['s/a^b/X/']),
    C('regex', 'dollar mid is literal', ['a$b'], ['s/a$b/X/']),
    C('regex', 'star after caret is literal', ['*a'], ['s/^*a/X/']),
    C('regex', 'caret after group open anchors', ['ab', 'ba'],
      [r's/\(^a\)/X/']),
    C('regex', 'dollar before group close anchors', ['ba', 'ab'],
      [r's/\(a$\)/X/']),
    C('regex', 'bracket leading close', [']a'], ['s/[]a]/X/g']),
    C('regex', 'negated bracket leading close', [']ab'], ['s/[^]a]/X/g']),
    C('regex', 'trailing dash', ['a-'], ['s/[a-]/X/g']),
    C('regex', 'backref of a star group', ['aaaa'],
      [r's/\(a*\)\1/[&]/']),

    # ---- boundaries --------------------------------------------------------
    C('bound', '254-char line', ['x' * 254], ['s/^/>/']),
    C('bound', 'empty lines', ['', 'a', ''], ['s/^$/E/']),
    C('bound', 'many lines', [str(i) for i in range(1, 61)],
      ['$!d']),
]


# ======================================================================
# host oracle
# ======================================================================
def _host_once(case):
    workdir = tempfile.mkdtemp(dir=SCRATCH)
    try:
        mapping = {'I': 'main.txt'}
        for tag in case['extra']:
            mapping[tag] = f'{tag.lower()}.txt'
        with open(os.path.join(workdir, 'main.txt'), 'w') as f:
            f.write(''.join(ln + '\n' for ln in case['inp']))
        for tag, lines in case['extra'].items():
            if lines is None:
                continue
            with open(os.path.join(workdir, mapping[tag]), 'w') as f:
                f.write(''.join(ln + '\n' for ln in lines))
        cmd = [HOST_SED]
        args = case['args']
        # a typed word like 's/a/b/' reaches maux's sh in single
        # quotes; strip them for the host's argv
        cmd += [a[1:-1] if a.startswith("'") and a.endswith("'") else a
                for a in args if not a.startswith('@')]
        if case['script'] is not None:
            with open(os.path.join(workdir, 'script.sed'), 'w') as f:
                f.write(''.join(ln + '\n'
                                for ln in render(case['script'], mapping)))
            cmd += ['-f', 'script.sed']
        cmd.append('main.txt')
        cmd += [mapping[a[1:-1]] for a in args if a.startswith('@')]
        env = dict(os.environ, COLUMNS='70', LC_ALL='C')
        r = subprocess.run(cmd, cwd=workdir, capture_output=True,
                           text=True, timeout=15, env=env)
        files = {}
        for tag in case['results']:
            path = os.path.join(workdir, mapping[tag])
            files[tag] = host_lines(open(path).read()) \
                if os.path.exists(path) else None
        return {'stdout': host_lines(r.stdout), 'rc': r.returncode,
                'files': files, 'stderr': r.stderr}
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def oracle(case):
    a = _host_once(case)
    b = _host_once(case)
    if a != b:
        raise RuntimeError(f'oracle UNSTABLE across two runs: {a!r} != {b!r}')
    if a['rc'] != 0:
        raise RuntimeError(
            f'host sed refused the case (rc={a["rc"]}, '
            f'stderr={a["stderr"]!r}) -- the staged script must be '
            f'portable; fix the CASE, never hand-author the expectation')
    return a


# ======================================================================
# maux side
# ======================================================================
def maux_map(tag, case):
    m = {'I': f'{SUBDIR}/{tag}I'}
    for t in case['extra']:
        m[t] = f'{SUBDIR}/{tag}{t}'
    return m


def stage_batch(img, batch, tags):
    prodos.mount(img)
    try:
        try:
            prodos.mkdir(SUBDIR)
        except Exception:
            pass
        for tag, case in zip(tags, batch):
            m = maux_map(tag, case)
            prodos.write(m['I'], hilines(case['inp']), file_type=0x04,
                         aux_type=0x0000, overwrite=True)
            for t, lines in case['extra'].items():
                if lines is None:
                    continue
                prodos.write(m[t], hilines(lines), file_type=0x04,
                             aux_type=0x0000, overwrite=True)
            if case['script'] is not None:
                prodos.write(f'{SUBDIR}/{tag}S',
                             hilines(render(case['script'], m)),
                             file_type=0x04, aux_type=0x0000,
                             overwrite=True)
    finally:
        try:
            prodos.unmount('MAUX')
        except Exception:
            pass


def boot(client, img):
    r = client.call_tool('reset', {'backend': 'fast', 'aux': 'ramworks'})
    if not r.get('ok'):
        raise RuntimeError(f'reset failed: {r}')
    r = client.call_tool('mount_disk', {'path': img, 'unit': 1})
    if r.get('ok') is False:
        raise RuntimeError(f'mount_disk failed: {r}')
    V.settle(client, V._at_prompt, 'shell prompt after boot',
             max_steps=3000)


def command_line(tag, case):
    m = maux_map(tag, case)
    words = ['SED']
    words += [m[a[1:-1]] if a.startswith('@') else a
              for a in case['args'] if not a.startswith('@')]
    if case['script'] is not None:
        words += ['-f', f'{SUBDIR}/{tag}S']
    words.append(m['I'])
    words += [m[a[1:-1]] for a in case['args'] if a.startswith('@')]
    words += ['>', f'{SUBDIR}/{tag}O']
    return ' '.join(words)


def run_case(client, tag, case):
    V.t(client, command_line(tag, case) + '\r')
    V.settle(client, V._at_prompt, f'{tag} finished', max_steps=2500)
    V.t(client, f'echo $? > {SUBDIR}/{tag}X\r')
    V.settle(client, V._at_prompt, f'{tag} status captured', max_steps=400)


def recover(client):
    V.t(client, '\x03')
    V.settle(client, V._at_prompt, 'recovered to prompt', max_steps=400)


def process_batch(env, batch, idx):
    tags = [f'K{idx * 100 + i:03d}' for i in range(len(batch))]
    img = os.path.join(SCRATCH, f'grp_{idx}.po')
    shutil.copy(DISK, img)
    MADE.append(img)
    stage_batch(img, batch, tags)

    client = MCPClient([SUPERVISOR], env)
    harness_err = {}
    try:
        boot(client, img)
        for tag, case in zip(tags, batch):
            try:
                run_case(client, tag, case)
            except Exception as e:  # noqa: BLE001
                harness_err[tag] = f'{type(e).__name__}: {e}'
                try:
                    recover(client)
                except Exception:
                    break
    finally:
        try:
            client.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        client.close()

    vol = None
    vol_err = None
    try:
        vol = a2til.open_image(img)
    except Exception as e:  # noqa: BLE001
        vol_err = f'{type(e).__name__}: {e}'

    results = []
    for tag, case in zip(tags, batch):
        if tag in harness_err:
            results.append((case, None, harness_err[tag]))
            continue
        if vol is None:
            results.append((case, None, f'a2til open_image failed: {vol_err}'))
            continue
        try:
            got = {}
            got['stdout'] = maux_lines(bytes(vol.read_file(f'{SUBDIR}/{tag}O')))
            st = maux_lines(bytes(vol.read_file(f'{SUBDIR}/{tag}X')))
            got['rc'] = int(st[0]) if st and st[0].strip().isdigit() else None
            got['files'] = {}
            m = maux_map(tag, case)
            for t in case['results']:
                try:
                    got['files'][t] = maux_lines(bytes(vol.read_file(m[t])))
                except Exception:
                    got['files'][t] = None
            results.append((case, got, None))
        except Exception as e:  # noqa: BLE001
            results.append((case, None,
                            f'a2til read-back failed: {type(e).__name__}: {e}'))
    return results


# ======================================================================
# main
# ======================================================================
def main():
    try:
        rc = run()
    except BaseException:
        SC.settle('check-posixsed', SCRATCH, MADE, False)
        raise
    SC.settle('check-posixsed', SCRATCH, MADE, rc == 0)
    return rc


def run():
    global DISK
    only = None
    argv = sys.argv[1:]
    if argv and argv[0].endswith('.po'):
        DISK = os.path.abspath(argv.pop(0))
    if argv:
        only = set(argv)
    if not os.path.exists(DISK):
        print(f'error: {DISK} not found -- run make play-image first',
              file=sys.stderr)
        return 2
    os.makedirs(SCRATCH, exist_ok=True)
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR

    gnu = host_is_gnu()
    cases = [c for c in CASES if only is None
             or c['group'] in only or c['name'] in only]
    skipped = [c for c in cases if c['gnu_only'] and not gnu]
    cases = [c for c in cases if not (c['gnu_only'] and not gnu)]
    for c in skipped:
        print(f'[check-posixsed] skip {c["group"]}/{c["name"]}: needs a '
              f'GNU sed oracle ({c["note"]})')
    batches = [cases[i:i + BATCH] for i in range(0, len(cases), BATCH)]
    print(f'[check-posixsed] {len(cases)} byte-exact cases vs {HOST_SED}, '
          f'{len(batches)} boot groups')
    fails = []
    passed = 0
    for idx, batch in enumerate(batches):
        print(f'[check-posixsed] group {idx + 1}/{len(batches)} '
              f'({len(batch)} cases)')
        for case, got, herr in process_batch(env, batch, idx):
            label = f'{case["group"]}/{case["name"]}'
            try:
                exp = oracle(case)
            except Exception as e:  # noqa: BLE001
                fails.append((label, f'ORACLE: {e}'))
                print(f'[check-posixsed] FAIL {label}: oracle: {e}',
                      file=sys.stderr)
                continue
            if herr:
                fails.append((label, f'HARNESS: {herr}'))
                print(f'[check-posixsed] FAIL {label}: {herr}',
                      file=sys.stderr)
                continue
            diffs = []
            if got['stdout'] != exp['stdout']:
                diffs.append(f'stdout expected={exp["stdout"]!r} '
                             f'got={got["stdout"]!r}')
            if got['rc'] != exp['rc']:
                diffs.append(f'exit expected={exp["rc"]} got={got["rc"]}')
            for t in case['results']:
                if got['files'].get(t) != exp['files'].get(t):
                    diffs.append(f'file {t} expected={exp["files"].get(t)!r} '
                                 f'got={got["files"].get(t)!r}')
            if diffs:
                fails.append((label, '; '.join(diffs)))
                print(f'[check-posixsed] FAIL {label}: ' + '; '.join(diffs),
                      file=sys.stderr)
            else:
                passed += 1
                print(f'[check-posixsed] ok   {label}')

    print()
    if fails:
        print(f'[check-posixsed] FAIL: {len(fails)} of {len(cases)} cases '
              f'differ from the host reference (an unexplained '
              f'difference is a failure, docs/E2E.md sec 4):',
              file=sys.stderr)
        for label, why in fails:
            print(f'  {label}: {why}', file=sys.stderr)
        return 1
    print(f'[check-posixsed] PASS: {passed}/{len(cases)} cases byte-exact '
          f'against {HOST_SED} (stdout, exit status, written files) '
          f'through maux\'s own shell and -f scripts')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
