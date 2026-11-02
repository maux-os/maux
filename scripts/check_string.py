#!/usr/bin/env python3
"""check_string.py -- acceptance gate for src/liba/string.s's 16-bit
walk (`make check-string`).

Runs src/test/strtest.s, which drives STRCMP/STRCMPI/STRCPY over a case
table on the real 6502 and writes 1/0 per case to $0300, with the case
count at $0340. A case that never ran reads $EE, which is neither.

WHY THIS GATE EXISTS SEPARATELY FROM check-fleet. The compare bug is
reachable end-to-end -- check-fleet's TWININ/TWINOUT proves it through
`sort -u`, which silently DELETED a distinct line. But no program in
the tree can hand STRCPY a 256-byte source (every caller is fed from
argv, capped at sh's LINEMAX=127, or from a getline with its own 255
cap), and STRCMPI's only caller compares 15-byte ProDOS filenames. A
gate reaching those through a program would have to invent a caller,
which is how the pre-existing WIDEIN fixture ended up sized to stay
INSIDE a known bug. So they get tested directly instead.

Case 4 is the CONTROL: it differs at byte 254, inside the old 8-bit
walk, and passed before the widening. If it goes red too, the harness
broke rather than the routine.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402

RESULTS, NCASES = 0x0300, 0x0340

LABELS = [
    # -- STRCMP
    'STRCMP 3-byte equal',
    'STRCMP 3-byte A<B',
    'STRCMP 3-byte A>B',
    'STRCMP 300-byte genuinely equal',
    'STRCMP 300-byte differ at 254 (CONTROL, inside old walk)',
    'STRCMP 300-byte differ at 256, A<B (the bug)',
    'STRCMP 300-byte differ at 256, A>B (the bug, other sign)',
    'STRCMP 600-byte differ at 512 (two page carries)',
    'STRCMP 300-byte prefix of 400-byte (parts past the wrap)',
    'STRCMP PTR0/PTR1 restored after a 600-byte compare',
    # -- STRCMPI
    'STRCMPI 300-byte equal but for case, all through',
    'STRCMPI 300-byte real difference at 256 (the bug)',
    'STRCMPI PTR0/PTR1 restored after a 300-byte compare',
    # -- STRCPY
    'STRCPY 300-byte copy is byte-exact incl. terminator',
    'STRCPY 300-byte returns A=$2C (length low)',
    'STRCPY 300-byte returns X=$01 (length high)',
    'STRCPY 600-byte copy is byte-exact incl. terminator',
    'STRCPY 600-byte returns A=$58 (length low)',
    'STRCPY 600-byte returns X=$02 (length high)',
    'STRCPY leaves the byte past the terminator untouched',
    'STRCPY PTR0/PTR1 restored after a 600-byte copy',
]

CONTROL = 4


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else 'build/str.po'
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}',
              file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make str-image first',
              file=sys.stderr)
        return 2

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        client.call_tool('reset', {'backend': 'fast'})
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')
        ran = 0
        for _ in range(120):
            client.call_tool('step', {'cycles': 500_000})
            ran = client.call_tool(
                'peek', {'addr': NCASES, 'count': 1})['bytes'][0]
            if ran and ran != 0xEE:
                break
        res = client.call_tool(
            'peek', {'addr': RESULTS, 'count': len(LABELS)})['bytes']
    finally:
        client.close()

    if ran != len(LABELS):
        print(f'[check-string] FAIL: image reported {ran} cases, expected '
              f'{len(LABELS)} -- did it boot?', file=sys.stderr)
        return 1

    bad = []
    for i, label in enumerate(LABELS):
        if res[i] != 1:
            bad.append(i)
            state = 'wrong result' if res[i] == 0 else 'never ran'
            print(f'  FAIL case {i} {label}: {state}', file=sys.stderr)
    if bad:
        if CONTROL in bad:
            print(f'\n[check-string] NOTE: the control case ({CONTROL}) is '
                  f'red too. It differs at byte 254, inside the old 8-bit '
                  f'walk, so it should pass even on the pre-widening '
                  f'routine -- suspect the harness, not just string.s.',
                  file=sys.stderr)
        print(f'\n[check-string] FAIL ({len(bad)}/{len(LABELS)})',
              file=sys.stderr)
        return 1
    print(f'[check-string] PASS -- 16-bit string walk: {len(LABELS)}/'
          f'{len(LABELS)} (STRCMP/STRCMPI/STRCPY across the 255/256 wrap, '
          f'both signs, two page carries, pointer restore)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
