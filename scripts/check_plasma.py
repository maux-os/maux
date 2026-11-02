#!/usr/bin/env python3
"""check_plasma.py -- the native PLASMA VM seed runs a module
(`make check-plasma`, docs/PLASMA-PORT.md milestone 1).

Boots build/plasma.po (the play image plus /mnt/MAUX/P/HELLO, a compiled
PLASMA module built from src/test/plasma/hello.pla) and, at the shell:

  PLA  `plasma /mnt/MAUX/p/hello` must print `HELLO FROM PLASMA ON MAUX`.
       That one line proves the whole seed: the loader read the module
       to $2000, the interpreter dispatched bytecode from a maux bank
       (the ZP inner loop + OPTBL), CALL reached the module's native
       asm, and a raw maux WRITE syscall from inside a PLASMA module
       landed on the console.
  PLB  `echo PL=$?` must be PL=0 -- the init returned through the thunk
       and the seed exited cleanly.

Teeth (PROVEN 2026-09-08): re-point OPTBL's CALL ($54) entry at ZERO
and both legs go red -- no hello line, and the VM runs away without
ever returning to the prompt (PLB times out too). The same holds for
the $0806 IINTRP vector once the seed's own thunk goes through it, the
OPTBL page alignment, and the ZP inner-loop template.

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

HELLO2_LINE = 'HELLO VIA CMDSYS'

# M2: one module is enough to prove the whole runtime -- hello2
# `import cmdsys` + puts(), so running it exercises seed->rt flat
# load, rt's init through the full interpreter, rt.loadmod relocating
# the module onto the heap, resolving the CMDSYS dependency, binding
# the PUTS import through the ESD, and rt's fd console. (The old raw-
# syscall hello is retired: its inline asm uses absolute self-refs the
# PLASMA compiler does not relocation-fix, so it cannot be loaded
# anywhere but its $2000 assembly base -- fine for M1's raw load, not
# for M2's relocating loadmod. docs/PLASMA-PORT.md.)
CASES = [
    ('PLC', '/mnt/MAUX/p/hello2', HELLO2_LINE, 'PL2'),
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
        print('[check-plasma] shell prompt reached')

        for tag, path, line, ectag in CASES:
            client.call_tool('type', {'text': f'plasma {path}\r'})
            try:
                wait_for_scrolling(client, [line], f'{tag}: {line!r}',
                                   max_steps=4000)
                print(f'[check-plasma] {tag}: {line!r}')
            except RuntimeError as e:
                failures.append(f'{tag}: {e}')
            wait_for_screen(client, prompt_ready, f'{tag}: prompt')
            client.call_tool('type', {'text': f'echo {ectag}=$?\r'})
            try:
                wait_for_scrolling(client, [f'{ectag}=0'],
                                   f'{tag}: exit 0', max_steps=2000)
                print(f'[check-plasma] {tag}: exit 0')
            except RuntimeError as e:
                failures.append(f'{tag}-rc: {e}')
            wait_for_screen(client, prompt_ready, f'{tag}: prompt after echo')
    finally:
        client.close()

    if failures:
        print('[check-plasma] FAIL:')
        for f in failures:
            print('  - ' + f)
        return 1
    print('[check-plasma] PASS: seed flat-loaded rt, rt ran the full '
          'interpreter, rt.loadmod relocated hello2 onto the heap, '
          'resolved its CMDSYS dependency, bound the PUTS import through '
          'the ESD, printed on fd 1, and exited 0')
    return 0


if __name__ == '__main__':
    sys.exit(main())
