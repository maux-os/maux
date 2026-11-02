#!/usr/bin/env python3
"""check_glob.py -- acceptance gate for src/liba/glob.s (`make check-glob`).

Runs src/test/globtest.s, which drives GLOBMATCH over a case table on
the real 6502 and writes 1/0 per case to $0300, with the case count at
$0340. A case that never ran reads $EE, which is neither.

This gate exists because writing the matcher produced FOUR bugs, and
only the first two were caught by re-reading: a dead compare in the
class scan, `]` advancing the pattern cursor twice, a n*6 stride in
the test harness itself, and -- the one that mattered -- backtracking
refusing to let `*` eat an entire name, so `*` did not match `foo`.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402

RESULTS, NCASES = 0x0300, 0x0340

LABELS = [
    '* vs foo', '* vs "" (empty name)', '*.txt vs NOTES.TXT (case fold)',
    '*.txt vs notes.bin', '?.txt vs a.txt', '?.txt vs ab.txt',
    'a*b vs ab (star matches empty)', 'a*b vs axxxb', 'a*b vs axxx',
    '[abc]x vs bx', '[abc]x vs dx', '[a-z]x vs Qx (range + fold)',
    '[!a]x vs bx (negated)', '[!a]x vs ax (negated)', '*x*y vs axby',
    'foo vs foo', 'foo vs foobar', '*b vs axxxb (backtrack)',
]


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else 'build/glob.po'
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        client.call_tool('reset', {'backend': 'fast'})
        client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        ran = 0
        for _ in range(60):
            client.call_tool('step', {'cycles': 500_000})
            ran = client.call_tool('peek', {'addr': NCASES, 'count': 1})['bytes'][0]
            if ran and ran != 0xEE:
                break
        res = client.call_tool(
            'peek', {'addr': RESULTS, 'count': len(LABELS)})['bytes']
    finally:
        client.close()

    if ran != len(LABELS):
        print(f'[check-glob] FAIL: image reported {ran} cases, expected '
              f'{len(LABELS)} -- did it boot?', file=sys.stderr)
        return 1
    bad = []
    for i, label in enumerate(LABELS):
        if res[i] != 1:
            bad.append(label)
            state = 'wrong result' if res[i] == 0 else 'never ran'
            print(f'  FAIL {label}: {state}', file=sys.stderr)
    if bad:
        print(f'\n[check-glob] FAIL ({len(bad)}/{len(LABELS)})', file=sys.stderr)
        return 1
    print(f'[check-glob] PASS -- GLOBMATCH: {len(LABELS)}/{len(LABELS)} '
          f'(*, ?, [abc], [a-z], [!a], backtracking, case folding)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
