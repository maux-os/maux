#!/usr/bin/env python3
"""build_federalist.py -- fixtures/federalist/ from Project Gutenberg #1404.

    python3 scripts/build_federalist.py SOURCE.txt [--check]

SOURCE.txt is pg1404.txt as downloaded (docs/DEMO-FEDGREP.md). The
script keeps only the text between the `*** START` and `*** END`
markers (so no Project Gutenberg name or licence text survives),
makes line ends LF, cuts the text at each `FEDERALIST No. N` line into
fixtures/federalist/NO.NN (85 files), folds the non-ASCII characters
to ASCII and prints every fold. With --check it writes nothing and
exits 1 if the committed fixtures differ from what the source gives.
The 1,024-line table of maux ed is a static limit (src/bin/ed.s) and
is asserted here. ed's TEXT limit is NOT: ed sizes its heap from the
kernel at run time (sbrk up to $BF00; the old 36,480-byte TEXTBUF_SIZE
is retired), so it is measured, not asserted: at 63fb62c2, 462 lines of
No. 83 (28,613 bytes) load and 463 lines (28,682 bytes) print `?`. This
script prints a size table and REPORTS papers above that bound; it
does not fail on them. ASCII only.
"""
import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'fixtures', 'federalist')
SOURCE_SHA256 = (
    '0b92fadc9d7afd767eefd27805a20e44417ff26d1fb2f964229f39dcc7b2a65d')
FOLDS = {'\u00e9': 'e'}             # e acute
ED_LINES = 1024                        # static, ed.s
ED_LOADS_BYTES = 28613                 # measured at 63fb62c2 (see above)
ED_MEASURED_AT = '63fb62c2'
HEAD = re.compile(r'^FEDERALIST No\. (\d+)\s*$')


def papers(src):
    text = src.replace('\r\n', '\n')
    a = text.index('*** START OF')
    a = text.index('\n', a) + 1
    z = text.index('*** END OF')
    lines = text[a:z].split('\n')
    out, cur, num = {}, None, 0
    folds = []
    for ln in lines:
        m = HEAD.match(ln)
        if m:
            num = int(m.group(1))
            assert num not in out, num
            cur = out[num] = []
        if cur is None:
            continue                    # the title page before No. 1
        for ch, rep in FOLDS.items():
            if ch in ln:
                folds.append((num, len(cur) + 1, ln))
                ln = ln.replace(ch, rep)
        cur.append(ln.rstrip())
    res = {}
    for n, ls in out.items():
        while ls and ls[-1] == '':
            ls.pop()
        res[n] = '\n'.join(ls) + '\n'
    return res, folds


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if len(args) != 1:
        print(__doc__)
        return 2
    raw = open(args[0], 'rb').read()
    sha = hashlib.sha256(raw).hexdigest()
    print('source sha256', sha)
    if sha != SOURCE_SHA256:
        print('error: not the pg1404.txt this script was written for')
        return 2
    ps, folds = papers(raw.decode('utf-8'))
    assert sorted(ps) == list(range(1, 86)), sorted(ps)
    for n, body in ps.items():
        body.encode('ascii')
        assert body.count('\n') <= ED_LINES, n
    big = sorted(ps, key=lambda n: -len(ps[n]))
    print('85 papers; largest No. %d: %d bytes, %d lines' %
          (big[0], len(ps[big[0]]), ps[big[0]].count('\n')))
    print('size table, the six largest (bytes, lines):')
    for n in big[:6]:
        print('  No. %2d  %6d  %4d' % (n, len(ps[n]), ps[n].count('\n')))
    over = [n for n in ps if len(ps[n]) > ED_LOADS_BYTES]
    print('REPORT (not an assertion): papers above the %d bytes maux ed '
          'loaded at %s: %s' % (ED_LOADS_BYTES, ED_MEASURED_AT,
                                ', '.join('No. %d' % n for n in sorted(over))
                                or 'none'))
    for n, ln_no, ln in folds:
        print('fold: No. %d line %d: %s' % (n, ln_no, ln))
    bad = 0
    for n, body in sorted(ps.items()):
        p = os.path.join(OUT, 'NO.%02d' % n)
        if '--check' in sys.argv:
            if not os.path.exists(p) or open(p, 'rb').read() != body.encode():
                print('differs:', p)
                bad = 1
        else:
            os.makedirs(OUT, exist_ok=True)
            with open(p, 'wb') as f:
                f.write(body.encode('ascii'))
    return bad


if __name__ == '__main__':
    sys.exit(main())
