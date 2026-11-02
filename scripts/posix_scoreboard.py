#!/usr/bin/env python3
"""posix_scoreboard.py -- run every POSIX conformance suite and print ONE
scoreboard. `make check-posix`.

The suites are the record of what maux actually is (operator, 2026-09-13:
"the house wants the posix test suites as a monument to the achievement
this project actually is"), so this runner does not hide anything: each
suite's full output is kept in build/posix/<target>.log, the scoreboard
is written to build/posix/SCOREBOARD.md, and the numbers are whatever the
suites printed -- nothing here computes a score of its own.

TWO KINDS OF SUITE, stated per row:
  gate    -- must exit 0 (check-posixsed, check-posixutil). Their known
             gaps are load-bearing rows that are EXPECTED red; a green run
             means every other row passed AND every gap is still a gap.
  report  -- a conformance REPORT with an exit status (check-posixvi,
             check-posixex, check-fowler): red rows are real divergences
             to read, not ratchets to keep, so a nonzero exit does not
             fail the scoreboard. The score is the record.

Usage:
  posix_scoreboard.py            run all suites, then render
  posix_scoreboard.py --from-logs  render from the logs of the last run
  posix_scoreboard.py check-posixutil ...   run only these
"""
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'build', 'posix')
MAKE = os.environ.get('MAKE', 'make')

#: (target, kind, what it measures, regex -> (passed, total))
SUITES = [
    ('check-posixutil', 'gate',
     'every shipped POSIX utility + test/[ vs XCU text',
     r'\[check-posixutil\] TOTAL (\d+)/(\d+)'),
    ('check-posixsed', 'gate',
     'sed(1) vs the host sed, byte-exact',
     r'\[check-posixsed\] (?:PASS: (\d+)/(\d+)|FAIL: (\d+) of (\d+))'),
    ('check-fowler', 'report',
     'BRE engine vs the AT&T (Fowler) + Spencer regex corpora',
     r'\[check-fowler\] (\d+)/(\d+) rows match'),
    ('check-posixvi', 'report',
     'vi(1) vs vim as oracle',
     r'\[check-posixvi\] (\d+)/(\d+) cases passed'),
    ('check-posixex', 'report',
     'ex(1) vs /usr/bin/ex as oracle',
     r'\[check-posixex\] (\d+)/(\d+) cases passed'),
]
GAPS_RE = r'\[check-posixutil\] (\d+) cases \((\d+) '


def run(target):
    os.makedirs(OUT, exist_ok=True)
    log = os.path.join(OUT, target + '.log')
    print(f'[check-posix] === {target} ===', flush=True)
    t0 = time.time()
    with open(log, 'w') as fh:
        p = subprocess.Popen([MAKE, '-C', ROOT, target],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, errors='replace')
        for line in p.stdout:
            sys.stdout.write(line)
            fh.write(line)
        rc = p.wait()
    print(f'[check-posix] === {target}: exit {rc}, '
          f'{time.time() - t0:.0f} s ===', flush=True)
    return rc


def score(target, rx):
    log = os.path.join(OUT, target + '.log')
    if not os.path.exists(log):
        return None, None, 'no log'
    text = open(log, errors='replace').read()
    m = None
    for m in re.finditer(rx, text):
        pass                                   # last match wins
    if not m:
        return None, None, 'no summary line'
    g = [x for x in m.groups() if x is not None]
    a, b = int(g[0]), int(g[1])
    if 'FAIL:' in m.group(0) and target == 'check-posixsed':
        a = b - a                              # "N of M cases" failed
    extra = ''
    if target == 'check-posixutil':
        gm = re.search(GAPS_RE, text)
        if gm:
            extra = f'{gm.group(2)} named gaps, expected red'
    if 'FAIL' in m.group(0):
        extra = (extra + '; ' if extra else '') + 'summary line says FAIL'
    return a, b, extra


def render(rows, head):
    lines = []
    lines.append('# maux POSIX conformance scoreboard')
    lines.append('')
    lines.append(f'Measured {time.strftime("%Y-%m-%d %H:%M")} at `{head}` '
                 f'by `make check-posix`. Logs: build/posix/*.log.')
    lines.append('')
    lines.append('| suite | kind | measures | score | note |')
    lines.append('|---|---|---|---:|---|')
    for target, kind, what, a, b, extra, rc in rows:
        sc = f'{a}/{b}' if a is not None else 'unparsed'
        status = 'exit 0' if rc == 0 else f'exit {rc}'
        note = '; '.join(x for x in (extra, status) if x)
        lines.append(f'| `{target}` | {kind} | {what} | {sc} | {note} |')
    return '\n'.join(lines) + '\n'


def main(argv):
    from_logs = '--from-logs' in argv
    wanted = [a for a in argv if not a.startswith('--')]
    suites = [s for s in SUITES if not wanted or s[0] in wanted]
    rcs = {}
    for target, kind, what, rx in suites:
        if from_logs:
            rcs[target] = None
        else:
            rcs[target] = run(target)
    rows = []
    bad = []
    for target, kind, what, rx in suites:
        a, b, extra = score(target, rx)
        rc = rcs[target]
        if rc is None:                          # --from-logs: read the log
            rc = 0 if a is not None else 1
            if extra and 'says FAIL' in extra:
                rc = 1
        rows.append((target, kind, what, a, b, extra, rc))
        if a is None or (kind == 'gate' and rc != 0):
            bad.append(target)
    try:
        head = subprocess.check_output(['git', '-C', ROOT, 'rev-parse',
                                        '--short', 'HEAD'], text=True).strip()
    except Exception:                           # noqa: BLE001
        head = 'unknown'
    md = render(rows, head)
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, 'SCOREBOARD.md'), 'w') as fh:
        fh.write(md)
    print()
    print(md)
    if bad:
        print(f'[check-posix] FAIL: {", ".join(bad)}', file=sys.stderr)
        return 1
    print('[check-posix] PASS: every gate suite green; reports rendered')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
