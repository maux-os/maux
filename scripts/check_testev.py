#!/usr/bin/env python3
"""check_testev.py -- acceptance gate for src/bin/testeval.s
(`make check-testev`).

Boots src/test/testevtest.s (a single maux process synthesized into
aux bank 1, real syscalls live -- see that file's header for why
this cannot be as light as check_glob.py's bare-ProDOS harness) and
drives testevtestb.s's 61-row case table straight against TEST_EVAL,
same peek-the-results-table shape as check_glob.py: 1 (pass) / 0
(fail) per case at R_RESULTS, case count at R_NCASES, done flag at
R_DONE ($AA success). A case that never ran leaves $EE.

Rows 41-61 (2026-09-14) cover the primaries testeval.s added to
reach POSIX.1-2024 (docs/POSIX-GAPS.md sec 2's `test` row): -x -s
-r -w, the always-false -b/-c/-g/-h/-L/-p/-S/-u group, -a/-o with
-a's tighter precedence, and `( expr )` grouping.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402

R_RESULTS, R_NCASES, R_DONE = 0x1200, 0x1240, 0x1241

LABELS = [
    '-f on a regular file (true)',
    '-f on a directory (false)',
    '-f on a nonexistent path (false)',
    '-d on a directory (true)',
    '-d on a regular file (false)',
    '-d on a nonexistent path (false)',
    '-e on a regular file (true)',
    '-e on a nonexistent path (false)',
    '-z on an empty string (true)',
    '-z on "foo" (false)',
    '-n on "foo" (true)',
    '-n on an empty string (false)',
    'foo = foo (true)',
    'foo = bar (false)',
    'foo != bar (true)',
    'foo != foo (false)',
    '3 -eq 3 (true)',
    '3 -eq 4 (false)',
    '3 -ne 4 (true)',
    '3 -ne 3 (false)',
    '3 -lt 4 (true)',
    '4 -lt 3 (false)',
    '4 -gt 3 (true)',
    '3 -gt 4 (false)',
    '3 -le 3 (true)',
    '4 -le 3 (false)',
    '3 -ge 3 (true)',
    '3 -ge 4 (false)',
    'abc -eq 3 (non-numeric left, error)',
    '3 -eq abc (non-numeric right, error)',
    '! "" (bare-word negate, true)',
    '! foo (bare-word negate, false)',
    '! -f TESTF (unary negate, false)',
    '! -f NOPE (unary negate, true)',
    '! foo = bar (binary negate, true)',
    'foo (bare word, true)',
    '"" (bare word, false)',
    '-q foo (unknown unary op, error)',
    'foo bar baz (malformed 3-arg, error)',
    '0 args (false)',
    '-x on a BIN file (true)',
    '-x on a TXT file (false)',
    '-x on a nonexistent path (false)',
    '-s on a file with data (true)',
    '-s on a nonexistent path (false)',
    '-r on an existing file (true)',
    '-r on a nonexistent path (false)',
    '-w on an existing file (true)',
    '-w on a nonexistent path (false)',
    '-b on an existing file (always false)',
    '-u on a nonexistent path (always false)',
    'foo -a bar (true)',
    '"" -a foo (false)',
    'foo -o "" (true)',
    '"" -o "" (false)',
    'foo -a "" -o bar (-a binds tighter, true)',
    '"" -o foo -a "" (-a binds tighter, false)',
    '( foo ) (grouping, true)',
    '( "" ) (grouping, false)',
    '( foo -- missing close paren (error)',
    '! ( foo -a "" ) (negated group, true)',
]


def peek_aux1(client, addr, count=1):
    return client.call_tool('peek', {
        'addr': addr,
        'count': count,
        'bank': 'aux',
        'aux_bank': 1,
    })['bytes']


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else 'build/testev.po'
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}',
              file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make testev-image first',
              file=sys.stderr)
        return 2

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-testev] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-testev] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        done = 0
        for _ in range(300):
            client.call_tool('step', {'cycles': 200_000})
            done = peek_aux1(client, R_DONE)[0]
            if done == 0xAA:
                break
        ncases = peek_aux1(client, R_NCASES)[0]
        res = peek_aux1(client, R_RESULTS, len(LABELS))
        print(f'[check-testev] done=${done:02X} ncases={ncases}',
              file=sys.stderr)

        if done != 0xAA:
            print(f'[check-testev] FAIL: harness never finished '
                  f'(done=${done:02X}) -- did it boot?', file=sys.stderr)
            return 1
        if ncases != len(LABELS):
            print(f'[check-testev] FAIL: image reported {ncases} cases, '
                  f'expected {len(LABELS)}', file=sys.stderr)
            return 1

        bad = []
        for i, label in enumerate(LABELS):
            if res[i] != 1:
                bad.append(label)
                state = 'wrong result' if res[i] == 0 else 'never ran'
                print(f'  FAIL {label}: {state}', file=sys.stderr)
        if bad:
            print(f'\n[check-testev] FAIL ({len(bad)}/{len(LABELS)})',
                  file=sys.stderr)
            return 1

        print(f'[check-testev] PASS -- TEST_EVAL: {len(LABELS)}/'
              f'{len(LABELS)} (file/-z/-n/=/!=/-eq/-ne/-lt/-gt/-le/-ge, '
              f'-s/-r/-w/-x, always-false -b/-c/-g/-h/-L/-p/-S/-u, '
              f'!/-a/-o/( ), bare word, missing paths, non-numeric '
              f'operands, malformed expressions)')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
