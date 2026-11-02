#!/usr/bin/env python3
"""check_bpatch.py -- the spec-driven binary patcher `bpatch` applies a
spec correctly (`make check-bpatch`).

Boots build/bpatch.po (the play image plus /mnt/MAUX/B's synthetic
fixtures, scripts/build_bpatch_image.py) and drives three cases at the
shell:

  BPA  `bpatch SPEC T` then `cmp T EXP` -- SPEC's expect/set/flip-lc,
       applied to the crafted target T, must produce EXP byte-for-byte:
       the three real read-ROM LC switches flipped to read-RAM, the two
       controls (a $C1 high byte, a non-opcode) LEFT ALONE, and byte
       $0F set to $EE. BPA=0 proves all of that at once.
  BPB  `bpatch SPECBAD T2` -- SPECBAD's `expect 0F 99` is wrong, so
       bpatch must EXIT 1 (the file-version guard). BPB=1.
  BPC  `cmp T2 TORIG` -- because bpatch bailed on the failed expect
       BEFORE writing anything, T2 must still equal the pristine TORIG.
       BPC=0 proves a refused patch corrupts nothing.

Byte-exactness is the fixtures' job (build_bpatch_image.py); the gate
scrapes BPA=0 / BPB=1 / BPC=0. Teeth: drop flip-lc's $C0 guard and the
$C1-high-byte control flips too, so T != EXP and BPA goes red; drop the
expect check and BPB becomes BPB=0 (bpatch didn't refuse) and, worse,
BPC goes red (the bad patch reached the file).

Boot/type/screen helpers are check_dd.py's, itself check_proshim.py's.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402

PT_F40_ADDR = 0x9FF0        # src/test/playtestb.s PT_F40 (check_play.py)
PT_F40B_ADDR = 0x9FF1
PT_F40_MAG1 = 0xF4
PT_F40_MAG2 = 0x0A

B = '/mnt/MAUX/b'

CASES = [
    ('BPA', [f'bpatch {B}/spec {B}/t', f'cmp {B}/t {B}/exp'], 'BPA=0'),
    ('BPB', [f'bpatch {B}/specbad {B}/t2'], 'BPB=1'),
    ('BPC', [f'cmp {B}/t2 {B}/torig'], 'BPC=0'),
]


def screen_rows(client):
    return client.call_tool('screen_text', {}).get('main', [])


def screen_blob(rows):
    return '\n'.join(rows)


def wait_for_screen(client, predicate, label, max_steps=1200):
    rows = []
    for _ in range(max_steps):
        client.call_tool('step', {'cycles': 200_000})
        rows = screen_rows(client)
        if predicate(rows):
            return rows
    raise RuntimeError(f'timed out waiting for {label}; screen was:\n'
                       f'{screen_blob(rows)}')


def wait_for_scrolling(client, needles, label, max_steps=4000):
    seen = set()
    rows = []
    for _ in range(max_steps):
        client.call_tool('step', {'cycles': 20_000})
        rows = screen_rows(client)
        blob = screen_blob(rows)
        for name in needles:
            if name in blob:
                seen.add(name)
        if seen.issuperset(needles):
            return rows
    missing = sorted(set(needles) - seen)
    raise RuntimeError(
        f'timed out waiting for {label}; never saw {missing}; screen was:\n'
        f'{screen_blob(rows)}')


def prompt_ready(rows):
    live = [r for r in rows if r.strip()]
    return bool(live) and live[-1].startswith('$')


def run_case(client, tag, cmds, needle, failures):
    for cmd in cmds:
        client.call_tool('type', {'text': f'{cmd}\r'})
        wait_for_screen(client, prompt_ready, f'{tag}: prompt after {cmd!r}')
    client.call_tool('type', {'text': f'echo {tag}=$?\r'})
    try:
        wait_for_scrolling(client, [needle], f'{tag}: {needle}',
                           max_steps=2000)
        print(f'[check-bpatch] {tag}: {needle}')
    except RuntimeError as e:
        failures.append(f'{tag}: {e}')
    wait_for_screen(client, prompt_ready, f'{tag}: prompt after echo')


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    disk = os.path.abspath(sys.argv[1])
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    failures = []
    try:
        client.initialize()
        client.call_tool('reset', {'backend': 'fast'})
        for addr, val in ((PT_F40_ADDR, PT_F40_MAG1),
                          (PT_F40B_ADDR, PT_F40_MAG2)):
            client.call_tool('poke', {'addr': addr, 'bytes': [val],
                                      'bank': 'main'})
        client.call_tool('mount_disk', {'path': disk})
        wait_for_screen(client, prompt_ready, 'shell prompt')
        print('[check-bpatch] shell prompt reached')
        for tag, cmds, needle in CASES:
            run_case(client, tag, cmds, needle, failures)
    finally:
        client.close()

    if failures:
        print('[check-bpatch] FAIL:')
        for f in failures:
            print('  - ' + f)
        return 1
    print('[check-bpatch] PASS: set/expect/flip-lc apply byte-exact, the '
          'flip-lc guards hold, and a failed expect writes nothing')
    return 0


if __name__ == '__main__':
    sys.exit(main())
