#!/usr/bin/env python3
"""check_dd.py -- file-level `dd` runs correctly under maux (`make
check-dd`).

Boots build/dd.po (the play image plus /mnt/MAUX/D's four raw fixtures,
scripts/build_dd_image.py) and drives three cases at the shell, each a
`dd` followed by a `cmp` against the fixture that says what dd SHOULD
have produced, then `echo <TAG>=$?` -- so a green tag means dd's bytes
matched exactly (cmp is silent + exit 0 on a match, loud + nonzero on a
difference or a missing file):

  DDA  skip=/count=/bs= slicing: `dd if=A of=S bs=16 skip=1 count=1`
       must extract A's second 16-byte block, byte-equal to K.
  DDB  a plain block copy: `dd if=A of=C bs=16 count=3` must reproduce
       all 48 bytes of A into a fresh C.
  DDC  the load-bearing case -- an IN-PLACE poke: `dd if=P of=C bs=1
       seek=5 conv=notrunc` must overwrite ONLY byte 5 of the copy C
       (with P's $EE) and leave every other byte intact, byte-equal to
       Q. DDC runs after DDB, on the C that DDB created.

Byte-exactness is the fixtures' job (build_dd_image.py); this gate only
scrapes DDA=0 / DDB=0 / DDC=0. Teeth: break dd's skip multiply and DDA
goes red; break the conv=notrunc path (so the poke truncates or lands
at the wrong offset) and DDC goes red -- neither the copy nor the slice
can mask it, because each case cmps against its OWN fixture.

Boot/type/screen helpers are check_proshim.py's, itself check_play.py's
(copied, not imported: check_play is a 2,700-line program, not a
library).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402

PT_F40_ADDR = 0x9FF0        # src/test/playtestb.s PT_F40 (check_play.py)
PT_F40B_ADDR = 0x9FF1
PT_F40_MAG1 = 0xF4
PT_F40_MAG2 = 0x0A

D = '/mnt/MAUX/d'

# (tag, [commands typed in order], needle that proves it)
CASES = [
    ('DDA',
     [f'dd if={D}/a of={D}/s bs=16 skip=1 count=1',
      f'cmp {D}/s {D}/k'],
     'DDA=0'),
    ('DDB',
     [f'dd if={D}/a of={D}/c bs=16 count=3',
      f'cmp {D}/c {D}/a'],
     'DDB=0'),
    ('DDC',
     [f'dd if={D}/p of={D}/c bs=1 seek=5 conv=notrunc',
      f'cmp {D}/c {D}/q'],
     'DDC=0'),
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


def wait_for_scrolling(client, needles, label, max_steps=8000):
    """Accumulate needles across polls -- output scrolls early lines off
    before late ones appear (check_play.py's own note)."""
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
        print(f'[check-dd] {tag}: dd output matched its fixture ({needle})')
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
        print('[check-dd] shell prompt reached')
        for tag, cmds, needle in CASES:
            run_case(client, tag, cmds, needle, failures)
    finally:
        client.close()

    if failures:
        print('[check-dd] FAIL:')
        for f in failures:
            print('  - ' + f)
        return 1
    print('[check-dd] PASS: copy, skip/count slice, and in-place '
          'seek+notrunc poke all byte-exact')
    return 0


if __name__ == '__main__':
    sys.exit(main())
