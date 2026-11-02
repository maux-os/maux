#!/usr/bin/env python3
"""check_lsbig.py -- ls lists a directory with more than 128 entries.

WHY. `ls` reads a whole directory into ENTRIES before sorting it, so the
size of that array is a real cap on what it can show, not a buffer size.
It was 128. The manual directory is 149 pages and growing, so the
operator hit the cap just by running `ls` on it while trying the machine
out: ls listed 128 names, said "truncated at 128 entries" on stderr, and
21 pages were simply invisible.

Raised to 255, which is the ceiling for that shape rather than a taste:
ENTRYCOUNT is one byte and ENTIDX holds one-byte indices, so 255 is the
largest value both can still express. Going further means widening both
and the insertion sort with them. The tables live in ls's `dum` arena,
so the change cost 13 image bytes, not 4 KB.

WHAT THIS ASSERTS, against the real play image:
  1. `ls MAN | wc` counts MORE than the old cap -- the names exist;
  2. no truncation diagnostic is printed;
  3. the alphabetically LAST entry is listed, which is the one a cap
     always eats first and the thing a count alone would not catch.

TEETH (2026-09-20): with LS_MAXENT back at 128 all three fail -- the
count is exactly 128, the diagnostic returns, and the last name is gone.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_vi as V                                      # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR     # noqa: E402

MANDIR = '/usr/man'
OLD_CAP = 128
LAST_NAME = 'ZCAT'          #: sorts last; the first casualty of a cap


def step(c, n=1):
    for _ in range(n):
        c.call_tool('step', {'cycles': 200_000})


def rows(c):
    return [r.rstrip() for r in V.rows(c)]


def run(c, cmd, settle=400):
    V.t(c, cmd + '\r')
    for _ in range(settle):
        step(c)
        r = [x for x in rows(c) if x.strip()]
        if r and r[-1].strip() == '$':
            return rows(c)
    raise AssertionError(f'`{cmd}` never returned to a prompt; screen:\n'
                         + '\n'.join(x for x in rows(c) if x.strip()))


def main():
    if not os.path.exists(V.DISK):
        print('error: build/play.po missing -- run make play-image',
              file=sys.stderr)
        return 2
    c = MCPClient([SUPERVISOR],
                  dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR))
    failures = []
    try:
        c.initialize()
        V.boot(c)
        out = run(c, f'ls {MANDIR} | wc')
        counts = [x.split() for x in out
                  if x.strip() and x.split()[0].isdigit()]
        n = int(counts[-1][0]) if counts else -1
        if n <= OLD_CAP:
            failures.append(
                f'`ls {MANDIR} | wc` counted {n} entries, not more than '
                f'the old {OLD_CAP} cap -- ls is still truncating a '
                f'directory the manual corpus outgrew')
        else:
            print(f'[check-lsbig] {MANDIR}: {n} entries listed '
                  f'(old cap {OLD_CAP})')

        out = run(c, f'ls {MANDIR}')
        blob = '\n'.join(out)
        if 'truncated' in blob:
            failures.append(
                f'ls printed a truncation diagnostic for {MANDIR}:\n'
                + '\n'.join(x for x in out if 'truncated' in x))
        else:
            print('[check-lsbig] no truncation diagnostic')
        if LAST_NAME not in blob:
            failures.append(
                f'{LAST_NAME} is missing from `ls {MANDIR}`. It sorts '
                f'last, so it is the first name a cap eats -- a count '
                f'alone would not have caught this')
        else:
            print(f'[check-lsbig] the last name ({LAST_NAME}) is listed')
    finally:
        try:
            c.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        c.close()
    for f in failures:
        print(f'[check-lsbig] FAIL: {f}', file=sys.stderr)
    if failures:
        return 1
    print('[check-lsbig] PASS: ls lists a directory past the old 128 cap, '
          'with no truncation and the alphabetically last name present')
    return 0


if __name__ == '__main__':
    sys.exit(main())
