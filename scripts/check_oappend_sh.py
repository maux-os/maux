#!/usr/bin/env python3
"""check_oappend_sh.py -- per-write O_APPEND as the shell sees it
(`make check-oappend-sh`; docs/OAPPEND-1.md, docs/OAPPEND-1-NOTES.md).

Boots the play image and types each row at the shell, the
check_openrw2.py idiom (check_openrw's helpers are imported).  The
kernel rows (ABI, admission orders, truncation, park, K_ROOWN) are
scripts/check_oappend.py.

THE DEFECT.  Two appenders to one file are the oldest logging idiom,

    sh A >> LOG &        # a line a second for a while
    sh B >> LOG

and the second `>>` was refused ($50) -> `sh: cannot redirect`.  sh's
`>>` and `exec N>>`, tee -a and nohup now open with OPEN_APPEND
(`$23`): the kernel seeks to EOF before every write, so every open
joins.

Rows (the brief's names):
  A1   two background shells append numbered lines to one LOG, 8
       lines each, crossing LOG's 512-byte boundary: after both exit
       LOG has every line of both, each intact, per writer in order.
  A1e  `exec 3>>LOG 4>>LOG`: two appenders from one shell, written
       alternately, land in order at the end.
  A1t  `sh A | tee -a LOG &` beside `sh B >> LOG`: tee -a joins.
  A1n  two `nohup sh X &` share nohup.out.
  A2   `sh A >> LOG &` then `sh B >> LOG` in the foreground: B is not
       refused and does not retry (OW_SEEN cleared first, 0 after).
  A3   `tail -f LOG` beside two appenders shows both writers' lines;
       a `cat LOG` opened AFTER both appenders joins.
  A8   a no-intent writer beside an appender, both orders: the same
       `sh: cannot redirect` after the same bound.
  A9   `>> /dev/null`, `>> /dev/tty1`: unchanged output, status 0.
  A1x / A2x  the A1 and A2 idioms in a login shell that never cd'd.
  A5x  the same shell: a reader, then `>>` (joins), a second `>>`
       (joins), and reader + no-intent `>` (OPEN-RW-2's own hole).

ASCII only.  Exit 0 green, 1 red (listed), 2 rig problem.
"""
import argparse
import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_openrw as W  # noqa: E402
import check_devfs as D  # noqa: E402
import gate_race as GR  # noqa: E402
import arena  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DEFAULT = ['A1', 'A1e', 'A1t', 'A1n', 'A2', 'A3', 'A8', 'A9',
           'A1x', 'A2x', 'A5x']
#: rows run in a login shell that NEVER cd'd (H1, review): its
#: relative LOG reaches the kernel as a relative path with no recorded
#: cwd.  Every other row does `cd /tmp` first and so hides that case.
NOCD = {'A1x', 'A2x', 'A5x'}
SUF = ['']
LINE = '01234567890123456789'
N = 8


def run(rig, line, label, failures, **kw):
    out, _ = W.run_line(rig, line, label, failures, **kw)
    return out


def fx(rig, lines, failures):
    return W.fixture_lines(rig, lines, failures)


def eq(label, got, want, failures):
    if got != want:
        failures.append(f'{label}: got {got!r}, want {want!r}')


def seen(rig):
    return max(rig.seen().values(), default=0)


def writer(rig, failures, tag, n=N, sleep=True):
    """Script W<tag>: echo <tag>1 .. <tag>n, one a second."""
    lines = []
    for i in range(1, n + 1):
        if sleep:
            lines.append(f'echo "sleep 1" >> W{tag}')
        lines.append(f'echo "echo {tag}{i}" >> W{tag}')
    return fx(rig, lines, failures)


def pad504(rig, failures):
    """LOG = 504 bytes (12 x 42), so 16 more lines cross 512."""
    return fx(rig, [f'echo {LINE} > L', f'echo {LINE} >> L',
                    'cat L L L L L L > LOG', 'cat L L L L L L >> LOG'],
              failures)


def check_log(rig, lab, failures, size, writers='AB', n=N):
    """After both writers exited: every line of each, intact, in
    order; the byte count (the boundary was crossed)."""
    for w in writers:
        eq(f'{lab}: the {w} lines, intact and in order',
           run(rig, f"grep '^{w}' LOG", lab, failures),
           [f'{w}{i}' for i in range(1, n + 1)], failures)
    eq(f'{lab}: byte count', run(rig, 'wc -c LOG', lab, failures),
       [f'{size} LOG'], failures)


def row_a1(rig, failures):
    lab = 'A1' + SUF[0]
    if not (pad504(rig, failures) and writer(rig, failures, 'A') and
            writer(rig, failures, 'B')):
        return
    rig.clear_seen()
    run(rig, 'sh WA >> LOG &', lab, failures)
    out = run(rig, 'sh WB >> LOG &', lab, failures)
    eq(f'{lab}: the second background `>>` is not refused', [
        x for x in (out or []) if 'cannot' in x], [], failures)
    run(rig, 'wait', lab, failures, q=100_000, polls=4000)
    check_log(rig, lab, failures, 504 + 2 * N * 3)
    eq(f'{lab}: no retry', seen(rig), 0, failures)


def row_a1e(rig, failures):
    lab = 'A1e'
    fx(rig, ['echo a > LOG'], failures)
    rig.clear_seen()
    out = run(rig, 'exec 3>>LOG 4>>LOG', lab, failures)
    eq(f'{lab}: two appenders from one shell', out, [], failures)
    for ln in ('echo p >&3', 'echo q >&4', 'echo r >&3', 'echo s >&4'):
        run(rig, ln, lab, failures)
    run(rig, 'exec 3>&- 4>&-', lab, failures)
    eq(f'{lab}: alternate writes land in order at the end',
       run(rig, 'cat LOG', lab, failures), ['a', 'p', 'q', 'r', 's'],
       failures)
    eq(f'{lab}: no retry', seen(rig), 0, failures)


def row_a1t(rig, failures):
    lab = 'A1t'
    if not (pad504(rig, failures) and writer(rig, failures, 'A') and
            writer(rig, failures, 'B')):
        return
    rig.clear_seen()
    run(rig, 'sh WA | tee -a LOG >/dev/null &', lab, failures)
    out = run(rig, 'sh WB >> LOG &', lab, failures)
    eq(f'{lab}: `>>` beside tee -a is not refused', [
        x for x in (out or []) if 'cannot' in x], [], failures)
    run(rig, 'wait', lab, failures, q=100_000, polls=4000)
    check_log(rig, lab, failures, 504 + 2 * N * 3)
    eq(f'{lab}: no retry', seen(rig), 0, failures)


def row_a1n(rig, failures):
    lab = 'A1n'
    if not (writer(rig, failures, 'A') and writer(rig, failures, 'B')):
        return
    # nohup prints its notice to STDERR, asynchronously and AT the
    # prompt, so it can land in the middle of the next typed line and
    # hide that line's anchor (found under MAUX_GATE_RACE=early and
    # in the default mode): send it to /dev/null
    run(rig, 'nohup sh WA 2>/dev/null &', lab, failures)
    run(rig, 'nohup sh WB 2>/dev/null &', lab, failures)
    run(rig, 'wait', lab, failures, q=100_000, polls=4000)
    for w in 'AB':
        eq(f'{lab}: the {w} lines in nohup.out',
           run(rig, f"grep '^{w}' nohup.out", lab, failures),
           [f'{w}{i}' for i in range(1, N + 1)], failures)


def row_a2(rig, failures):
    lab = 'A2' + SUF[0]
    if not (pad504(rig, failures) and writer(rig, failures, 'A') and
            writer(rig, failures, 'B', sleep=False)):
        return
    rig.clear_seen()
    run(rig, 'sh WA >> LOG &', lab, failures)
    out = run(rig, 'sh WB >> LOG', lab, failures, q=50_000)
    eq(f'{lab}: the foreground `>>` beside a long appender', out, [],
       failures)
    eq(f'{lab}: ... took no retry (OW_SEEN cleared first)', seen(rig), 0,
       failures)
    run(rig, 'wait', lab, failures, q=100_000, polls=4000)
    check_log(rig, lab, failures, 504 + 2 * N * 3)


def row_a3(rig, failures):
    lab = 'A3'
    n = 6
    fx(rig, ['echo hdr > LOG'], failures)
    if not (writer(rig, failures, 'A', n) and
            writer(rig, failures, 'B', n)):
        return
    run(rig, 'sh WA >> LOG &', lab, failures)
    run(rig, 'sh WB >> LOG &', lab, failures)
    eq(f'{lab}: a reader opened AFTER both appenders joins',
       run(rig, 'cat LOG', lab, failures)[:1], ['hdr'], failures)
    anchor = '$ tail -f LOG #A3'
    rig.type('tail -f LOG #A3\r')
    wa = [f'A{i}' for i in range(1, n + 1)]
    wb = [f'B{i}' for i in range(1, n + 1)]
    shown = None
    for _ in GR.polls(rig.c, 3000, 50_000):
        reg = W.below(rig.rows(), anchor)
        if reg is None:
            continue
        if ([r for r in reg if r in wa] == wa and
                [r for r in reg if r in wb] == wb):
            shown = reg
            break
    rig.type('\x03')
    try:
        D.wait_for_screen(rig.c, D.prompt_ready, lab, max_steps=400)
    except RuntimeError:
        W.recover(rig)
    if shown is None:
        failures.append(f'{lab}: tail -f never showed all of both '
                        f'writers; glass: '
                        f'{W.below(rig.rows(), anchor)!r}')
        return
    eq(f'{lab}: tail -f shows the A lines in order',
       [r for r in shown if r in wa], wa, failures)
    eq(f'{lab}: ... and the B lines in order',
       [r for r in shown if r in wb], wb, failures)
    run(rig, 'wait', lab, failures, q=100_000, polls=4000)


def row_a8(rig, failures):
    lab = 'A8'
    # an appender first, then a no-intent writer (`>` is creat)
    fx(rig, ['echo a > LOG', 'exec 3>>LOG'], failures)
    rig.clear_seen()
    out = run(rig, 'echo x > LOG', lab, failures, q=20_000)
    eq(f'{lab}: `>` beside an appender', out, ['sh: cannot redirect'],
       failures)
    eq(f'{lab}: ... after the bound', seen(rig), W.OW_MAX, failures)
    run(rig, 'exec 3>&-', lab, failures)
    eq(f'{lab}: LOG untouched', run(rig, 'cat LOG', lab, failures), ['a'],
       failures)
    # a no-intent writer first, then an appender
    fx(rig, ['exec 3>LOG', 'echo a >&3'], failures)
    rig.clear_seen()
    out = run(rig, 'echo x >> LOG', lab, failures, q=20_000)
    eq(f'{lab}: `>>` beside a no-intent writer', out,
       ['sh: cannot redirect'], failures)
    eq(f'{lab}: ... after the bound', seen(rig), W.OW_MAX, failures)
    run(rig, 'exec 3>&-', lab, failures)
    eq(f'{lab}: LOG untouched', run(rig, 'cat LOG', lab, failures), ['a'],
       failures)


def row_a9(rig, failures):
    lab = 'A9'
    eq(f'{lab}: >> /dev/null', run(rig, 'echo x >> /dev/null', lab,
       failures), [], failures)
    eq(f'{lab}: ... status', run(rig, 'echo S$?', lab, failures), ['S0'],
       failures)
    eq(f'{lab}: >> /dev/null 2>&1', run(rig, 'echo x >> /dev/null 2>&1',
       lab, failures), [], failures)
    eq(f'{lab}: >> /dev/tty1 prints', run(rig, 'echo hi >> /dev/tty1', lab,
       failures), ['hi'], failures)
    eq(f'{lab}: ... status', run(rig, 'echo S$?', lab, failures), ['S0'],
       failures)
    eq(f'{lab}: >> /dev/nope is still refused', run(rig,
       'echo x >> /dev/nope', lab, failures), ['sh: cannot redirect'],
       failures)
    fx(rig, ['echo a > F', 'echo b >> F'], failures)
    eq(f'{lab}: control, a file still appends', run(rig, 'cat F', lab,
       failures), ['a', 'b'], failures)


def nocd(fn, suf='x'):
    def w(rig, failures):
        SUF[0] = suf
        try:
            fn(rig, failures)
        finally:
            SUF[0] = ''
    return w


def row_a5x(rig, failures):
    lab = 'A5x'
    fx(rig, ['echo a > LOG', 'exec 4<LOG'], failures)
    rig.clear_seen()
    eq(f'{lab}: `>>` beside a long reader', run(rig, 'echo x >> LOG', lab,
       failures), [], failures)
    run(rig, 'exec 3>>LOG', lab, failures)
    eq(f'{lab}: a second appender joins', run(rig, 'echo y >> LOG', lab,
       failures), [], failures)
    eq(f'{lab}: no retry', seen(rig), 0, failures)
    run(rig, 'exec 3>&-', lab, failures)
    eq(f'{lab}: the reader sees both', run(rig, 'cat <&4', lab, failures),
       ['a', 'x', 'y'], failures)
    run(rig, 'exec 4<&-', lab, failures)
    fx(rig, ['exec 4<LOG'], failures)
    rig.clear_seen()
    eq(f'{lab}: reader + a no-intent writer (`>`)', run(rig,
       'exec 3>LOG', lab, failures), [], failures)
    eq(f'{lab}: ... no retry', seen(rig), 0, failures)
    run(rig, 'exec 3>&- 4<&-', lab, failures)


ROWS = {'A1x': nocd(row_a1), 'A2x': nocd(row_a2), 'A5x': row_a5x,
        'A1': row_a1, 'A1e': row_a1e, 'A1t': row_a1t, 'A1n': row_a1n,
        'A2': row_a2, 'A3': row_a3, 'A8': row_a8, 'A9': row_a9}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--play', default=os.path.join(ROOT, 'build',
                                                   'play.po'))
    ap.add_argument('rows', nargs='*', help=' '.join(DEFAULT))
    args = ap.parse_args()
    play = os.path.abspath(args.play)
    if not os.path.exists(play):
        print(f'check-oappend-sh: {play} missing -- make play-image')
        return 2
    want = args.rows or DEFAULT
    arena.symbol_table('sh')
    failures = []
    t0 = time.time()
    for tag in want:
        tmp = tempfile.mkdtemp(prefix='maux-oappend-')
        try:
            client = W.boot(play, tmp)
            try:
                rig = W.Rig(client, arena.symbol_table('sh'))
                if tag not in NOCD:
                    W.fixture_lines(rig, ['cd /tmp'], failures)
                n0 = len(failures)
                try:
                    ROWS[tag](rig, failures)
                except RuntimeError as exc:
                    failures.append(f'{tag}: {exc}')
                print(f'[check-oappend-sh] {tag}: '
                      f'{"PASS" if len(failures) == n0 else "FAIL"}',
                      flush=True)
            finally:
                client.close()
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    if failures:
        print(f'[check-oappend-sh] FAIL: {len(failures)} problem(s)')
        for x in failures:
            print(f'  - {x}'.replace('\n', '\n    '))
        return 1
    print(f'[check-oappend-sh] PASS ({time.time() - t0:.0f} s)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
