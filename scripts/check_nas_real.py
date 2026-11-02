#!/usr/bin/env python3
"""check_nas_real.py -- the L2->L3 REPORT gate (docs/AS-PLASMA.md,
task #21 follow-on): nas assembling a REAL maux util (`pwd`) plus its
full recursive PUT closure (14 files, ~115 KB combined source -- see
build_nas_real_image.py's header), diffed byte-for-byte against
merlin32's own reference build (build/pwd.bin).

Deliberately NOT a pass/fail gate in the CHECK_ALL_TARGETS sense (not
wired into CHECK_ALL_TARGETS): this is a DIAGNOSIS run. Two outcomes
are both a successful USE of this script:

  (a) nas's object is byte-identical to merlin32's -- the L3 milestone.
  (b) nas fails in some way -- the script tries hard to say EXACTLY
      how: a shell error message, a nonzero/missing exit status, a
      hung emulator (no forward progress for a long stretch, in which
      case it dumps PC/registers before giving up), or a byte mismatch
      at a specific offset.

Boots build/nas-real.po (build_nas_real_image.py) and, at the shell:

  cd /mnt/MAUX/pllib
  plasma NAS -o P.OBJ PWD.S
  echo NC=$?
  ls

Same shape as check_nas.py's run_fixture, but budgeted for a source
~14x check-nas's own stress fixture (2549 combined lines / ~115 KB vs
287 lines / 8 KB) -- more steps, more cycles/step (matching
check_shlang.py's 2,000,000-cycle-per-step convention for bigger
jobs), and a stall detector: if the screen stops changing for a long
stretch (no scrolling, no new prompt), this dumps PC/A/X/Y/S and the
top of the 6502 stack before giving up, since a heap-exhaustion
scribble (docs/AS-PLASMA.md sec 3, nas.pla's own comment on
heapalloc's unchecked failure return) is expected to manifest as
either a silent hang or a wild jump, not a clean error message.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402

PT_F40_ADDR = 0x9FF0
PT_F40B_ADDR = 0x9FF1
PT_F40_MAG1 = 0xF4
PT_F40_MAG2 = 0x0A

RAN_LINE = 'nas:'

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REF_BIN = os.path.join(ROOT, 'build', 'pwd.bin')
STEP_CYCLES = 2_000_000
MAX_STEPS = 3000                 # 6B cycles ceiling, generous


def screen_rows(client):
    return client.call_tool('screen_text', {}).get('main', [])


def screen_blob(rows):
    return '\n'.join(rows)


def dump_stall_state(client, label):
    """Best-effort diagnostic dump when the screen stops changing --
    a heap-exhaustion scribble is expected to either hang or wander
    the PC, not print a clean error."""
    try:
        regs = client.call_tool('regs', {})
        print(f'[check-nas-real] STALL DIAGNOSTIC ({label}): regs = {regs}')
    except Exception as e:
        print(f'[check-nas-real] STALL DIAGNOSTIC ({label}): '
              f'regs call failed: {e}')


def wait_for_screen(client, predicate, label, max_steps=1200,
                     stall_after=400):
    rows = []
    last_blob = None
    stable_for = 0
    for i in range(max_steps):
        client.call_tool('step', {'cycles': STEP_CYCLES})
        rows = screen_rows(client)
        blob = screen_blob(rows)
        if predicate(rows):
            return rows
        if blob == last_blob:
            stable_for += 1
        else:
            stable_for = 0
        last_blob = blob
        if stable_for == stall_after:
            print(f'[check-nas-real] {label}: screen unchanged for '
                  f'{stall_after} steps ({stall_after * STEP_CYCLES:,} '
                  f'cycles) -- possible hang, dumping state')
            dump_stall_state(client, label)
    raise RuntimeError(f'timed out waiting for {label}; screen was:\n'
                       f'{screen_blob(rows)}')


def wait_for_scrolling(client, needles, label, max_steps=3000,
                        stall_after=400):
    seen = set()
    rows = []
    last_blob = None
    stable_for = 0
    for i in range(max_steps):
        client.call_tool('step', {'cycles': STEP_CYCLES})
        rows = screen_rows(client)
        blob = screen_blob(rows)
        for name in needles:
            if name in blob:
                seen.add(name)
        if seen.issuperset(needles):
            return rows
        if blob == last_blob:
            stable_for += 1
        else:
            stable_for = 0
        last_blob = blob
        if stable_for == stall_after:
            print(f'[check-nas-real] {label}: screen unchanged for '
                  f'{stall_after} steps ({stall_after * STEP_CYCLES:,} '
                  f'cycles) -- possible hang, dumping state')
            dump_stall_state(client, label)
    missing = sorted(set(needles) - seen)
    raise RuntimeError(
        f'timed out waiting for {label} after {max_steps * STEP_CYCLES:,} '
        f'cycles; never saw {missing}; screen was:\n{screen_blob(rows)}')


def prompt_ready(rows):
    live = [r for r in rows if r.strip()]
    return bool(live) and live[-1].startswith('$')


def run(disk, srcname, objname):
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    failures = []
    t0 = time.time()
    try:
        client.initialize()
        client.call_tool('reset', {'backend': 'fast'})
        for addr, val in ((PT_F40_ADDR, PT_F40_MAG1),
                          (PT_F40B_ADDR, PT_F40_MAG2)):
            client.call_tool('poke', {'addr': addr, 'bytes': [val],
                                      'bank': 'main'})
        client.call_tool('mount_disk', {'path': disk})
        wait_for_screen(client, prompt_ready, 'shell prompt')
        print('[check-nas-real] shell prompt reached')

        client.call_tool('type', {'text': 'cd /mnt/MAUX/pllib\r'})
        wait_for_screen(client, prompt_ready, 'ND1: prompt after cd')
        print('[check-nas-real] ND1: cd /mnt/MAUX/pllib')

        client.call_tool('type',
                          {'text': f'plasma NAS -o {objname} {srcname}\r'})
        try:
            wait_for_scrolling(client, [RAN_LINE], f'ND2: {RAN_LINE!r}',
                               max_steps=MAX_STEPS)
            print(f'[check-nas-real] ND2: {RAN_LINE!r} seen after '
                  f'{time.time() - t0:.0f}s wall')
        except RuntimeError as e:
            failures.append(f'ND2: {e}')
            rows = screen_rows(client)
            print('[check-nas-real] ND2 FAILED -- final screen:\n' +
                  screen_blob(rows))
            dump_stall_state(client, 'ND2 final')
            return failures, None

        wait_for_screen(client, prompt_ready, 'ND2: prompt',
                        max_steps=1000)

        client.call_tool('type', {'text': 'echo NC=$?\r'})
        exit_status = None
        try:
            rows = wait_for_scrolling(client, ['NC='], 'ND3: exit status',
                                       max_steps=500)
            blob = screen_blob(rows)
            for line in blob.split('\n'):
                if 'NC=' in line:
                    tail = line.split('NC=', 1)[1].strip()
                    exit_status = tail.split()[0] if tail else None
            print(f'[check-nas-real] ND3: NC={exit_status}')
        except RuntimeError as e:
            failures.append(f'ND3: {e}')
        wait_for_screen(client, prompt_ready, 'ND3: prompt after echo',
                        max_steps=500)

        client.call_tool('type', {'text': 'ls\r'})
        wait_for_screen(client, prompt_ready, 'ND4: prompt after ls',
                        max_steps=500)
        print('[check-nas-real] ND4: ls (flush nudge)')
    finally:
        client.close()
    return failures, exit_status


def main():
    root = ROOT
    disk = os.path.join(root, 'build', 'nas-real.po')
    if len(sys.argv) > 1:
        disk = os.path.abspath(sys.argv[1])
    if not os.path.exists(disk):
        print(f'error: missing {disk} (python3 scripts/'
              f'build_nas_real_image.py)', file=sys.stderr)
        return 2
    if not os.path.exists(REF_BIN):
        print(f'error: missing oracle {REF_BIN} (merlin32 assembling '
              f'src/bin/pwd.s -> build/pwd.bin)', file=sys.stderr)
        return 2
    with open(REF_BIN, 'rb') as f:
        ref_bytes = f.read()

    failures, exit_status = run(disk, 'PWD.S', 'P.OBJ')
    if failures:
        print('[check-nas-real] REPORT: nas did not complete cleanly:')
        for f in failures:
            print('  - ' + f)
        return 1

    sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
    from a2til import prodos
    import vpath  # noqa: F401  (docs/VROOT.md)
    vol = prodos.mount(disk, replace=True, readonly=True)
    try:
        try:
            obj_bytes = prodos.read('/mnt/MAUX/PLLIB/P.OBJ')
        except Exception as e:
            print(f'[check-nas-real] REPORT: P.OBJ never appeared on the '
                  f'image ({e}) -- nas exit status was {exit_status}')
            return 1
    finally:
        prodos.unmount(vol)

    print(f'[check-nas-real] merlin32 reference: {len(ref_bytes)} bytes '
          f'({REF_BIN})')
    print(f'[check-nas-real] nas object:         {len(obj_bytes)} bytes '
          f'(/mnt/MAUX/PLLIB/P.OBJ), nas exit status {exit_status}')

    if obj_bytes != ref_bytes:
        n = min(len(obj_bytes), len(ref_bytes))
        first_diff = next((i for i in range(n)
                            if obj_bytes[i] != ref_bytes[i]), n)
        nas_byte = (f'{obj_bytes[first_diff]:02x}'
                    if first_diff < len(obj_bytes) else '--')
        ref_byte = (f'{ref_bytes[first_diff]:02x}'
                    if first_diff < len(ref_bytes) else '--')
        print(f'[check-nas-real] REPORT: byte mismatch at offset '
              f'{first_diff} (of {n} compared; nas {len(obj_bytes)}B vs '
              f'merlin32 {len(ref_bytes)}B): nas=${nas_byte} '
              f'merlin32=${ref_byte}')
        ctx = 16
        lo = max(0, first_diff - ctx)
        print(f'  nas      [{lo}:{lo+ctx*2}]: '
              f'{obj_bytes[lo:lo+ctx*2].hex()}')
        print(f'  merlin32 [{lo}:{lo+ctx*2}]: '
              f'{ref_bytes[lo:lo+ctx*2].hex()}')
        return 1

    print(f'[check-nas-real] PASS: nas assembled a REAL maux util (pwd, '
          f'plus its full 14-file liba/inc PUT closure) '
          f'byte-identical to merlin32\'s reference build '
          f'({len(ref_bytes)} bytes) -- L3 milestone')
    return 0


if __name__ == '__main__':
    sys.exit(main())
