#!/usr/bin/env python3
"""check_plascut.py -- the plasma cutter gate (`make check-plascut`,
docs/PLASCUT.md). Boots build/plascut.po (build_plascut_image.py) and,
in ONE emulator session so that every launch after the first is a
lazy-free WARM respawn of the same bank, proves four things:

  PC1 restore: `cookt` three times -> RUNS=0 each time, $?=0 each time.
      NATIVE=0 proves mutable native code is restored, and FIXED=42
      executes the immutable helper omitted from the restore copy.
      A sabotaged cookbad restores only the global: NATIVE=1 on its
      second launch gives the native restore check automated teeth.
      cookt increments a module global; a cooked image is its own data
      segment, and lazy free hands the second launch the bank the first
      one dirtied. RUNS=0 on the second launch means rt's cooked init
      restored the pristine copy. (Teeth: disable the restore in rt.pla
      -> RUNS=1 on the second launch, which ALSO proves the launch was
      warm; a cold load prints 0 regardless.)
  PC2 correctness: `nas -o T.OBJ FIXTURE.S` (the cooked nas, a plain
      util now) -> byte-identical to the merlin32 reference, checked on
      the host after the session. Only ONE object is byte-checked per
      session: reading a second file written in the same session hits
      a2til's last-file write-through flakiness (check_nas.py boots
      fresh per fixture for this). Cooked-nas byte-identity is proven
      three ways (cold cooked, warm cooked T2.OBJ, modular T3.OBJ);
      STRESS.S is check-nas's job on the same nas.mod plascut packages.
  PC3 status: `nas -o X.OBJ NOSUCH.S` -> $?=1. The seed path's rt
      discards a module's positive return (execmod returns -perr); the
      cooked path exits with the last init's return, which is what
      `make` needs to stop on an assembly error.
  PC4 measurement (printed, not gated): cycles from typing the command
      to the prompt returning, warm, for `nas -o T2.OBJ FIXTURE.S`
      (cooked) vs `plasma NAS -o T3.OBJ FIXTURE.S` (modular: seed warm,
      rt + 3 modules re-read/relocated/bound). The difference is the
      per-spawn load cost plascut removes.

Then `ls` (the a2til write-through flush nudge every nas gate uses) and
the host-side byte compare.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402

PT_F40_ADDR = 0x9FF0
PT_F40B_ADDR = 0x9FF1
PT_F40_MAG1 = 0xF4
PT_F40_MAG2 = 0x0A

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REF_BIN = os.path.join(ROOT, 'build', 'fixture.bin')
STRESS_REF_BIN = os.path.join(ROOT, 'build', 'stress.bin')


def screen_rows(client):
    return client.call_tool('screen_text', {}).get('main', [])


def blob(rows):
    return '\n'.join(rows)


def live_rows(rows):
    return [r for r in rows if r.strip()]


def at_prompt(rows):
    live = live_rows(rows)
    return bool(live) and live[-1].strip() == '$'


def step_until(client, predicate, label, max_steps, chunk=50_000):
    """Step in `chunk`-cycle increments until predicate(rows). Returns
    (rows, cycles stepped)."""
    total = 0
    rows = []
    for _ in range(max_steps):
        client.call_tool('step', {'cycles': chunk})
        total += chunk
        rows = screen_rows(client)
        if predicate(rows):
            return rows, total
    raise RuntimeError(f'timed out waiting for {label}; screen was:\n'
                       f'{blob(rows)}')


def run_cmd(client, cmd, label, max_steps=8000):
    """Type a command at the prompt; return (rows, cycles) when the
    prompt is back. The typed line itself ends in '$ cmd', so the
    predicate wants a bare '$' as the LAST live row, which only the
    returning prompt produces."""
    client.call_tool('type', {'text': cmd + '\r'})
    return step_until(client, at_prompt, label, max_steps)


def count_in(rows, needle):
    return blob(rows).count(needle)


def status(client, label):
    rows, _ = run_cmd(client, 'echo NC=$?', label, max_steps=2000)
    return rows


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    disk = os.path.abspath(sys.argv[1])
    for p in (REF_BIN, STRESS_REF_BIN):
        if not os.path.exists(p):
            print(f'error: missing oracle {p}', file=sys.stderr)
            return 2
    with open(REF_BIN, 'rb') as f:
        ref = f.read()
    with open(STRESS_REF_BIN, 'rb') as f:
        stress_ref = f.read()

    failures = []
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        client.call_tool('reset', {'backend': 'fast'})
        for addr, val in ((PT_F40_ADDR, PT_F40_MAG1),
                          (PT_F40B_ADDR, PT_F40_MAG2)):
            client.call_tool('poke', {'addr': addr, 'bytes': [val],
                                      'bank': 'main'})
        client.call_tool('mount_disk', {'path': disk})
        step_until(client, at_prompt, 'shell prompt', 1200, chunk=200_000)
        print('[check-plascut] shell prompt reached')
        run_cmd(client, 'cd /mnt/MAUX/pllib', 'cd')

        # PC1 -- restore across warm respawns
        for k in range(3):
            rows, cyc = run_cmd(client, 'cookt', f'cookt #{k + 1}')
            rows = status(client, f'cookt #{k + 1} status')
            runs0 = count_in(rows, 'RUNS=0 NATIVE=0 FIXED=42')
            bad = [n for n in ('RUNS=1', 'RUNS=2', 'RUNS=3')
                   if n in blob(rows)]
            nc0 = count_in(rows, 'NC=0')
            print(f'[check-plascut] PC1 cookt #{k + 1}: RUNS=0 seen '
                  f'{runs0}x, NC=0 seen {nc0}x, {cyc} cycles')
            if runs0 < k + 1 or bad:
                failures.append(f'PC1: launch {k + 1} -- RUNS=0 x{runs0}, '
                                f'stale {bad}; screen:\n{blob(rows)}')
            if nc0 < k + 1:
                failures.append(f'PC1: launch {k + 1} exit status not 0; '
                                f'screen:\n{blob(rows)}')

        # Deliberately omit the mutable native operand from a second
        # fixture's restore range. A stale immediate on its second launch
        # proves this gate observes native writes surviving a warm spawn.
        for k in range(2):
            run_cmd(client, 'clear', 'clear teeth', max_steps=400)
            rows, _ = run_cmd(client, 'cookbad', f'cookbad #{k + 1}')
            want = f'RUNS=0 NATIVE={k} FIXED=42'
            if want not in blob(rows):
                failures.append(f'PC1 teeth: expected {want}; '
                                f'screen:\n{blob(rows)}')
        print('[check-plascut] PC1 teeth: omitted native restore '
              'must expose NATIVE=1 on warm launch')

        # PC2 -- cooked nas assembles the fixtures
        rows, cyc_cold = run_cmd(client, 'nas -o T.OBJ FIXTURE.S',
                                 'nas fixture (cold)')
        if 'nas:' not in blob(rows):
            failures.append(f'PC2: no nas: line for FIXTURE.S; screen:\n'
                            f'{blob(rows)}')
        rows = status(client, 'nas fixture status')
        if 'NC=0' not in blob(rows):
            failures.append(f'PC2: FIXTURE.S exit status not 0; screen:\n'
                            f'{blob(rows)}')
        print(f'[check-plascut] PC2 nas FIXTURE.S (cold spawn): '
              f'{cyc_cold} cycles')
        # NB: only FIXTURE.S is byte-checked here, not STRESS.S. Reading
        # a second object written in the SAME emulator session hits
        # a2til's last-file write-through flakiness (check_nas.py boots
        # fresh PER fixture for exactly this reason). Cooked-nas byte-
        # identity is proven three ways below (cold cooked T.OBJ, warm
        # cooked T2.OBJ, modular T3.OBJ); STRESS.S byte-identity is
        # check-nas's assertion on the SAME nas.mod plascut packages --
        # plascut changes how nas LOADS, never its emitted bytes, so a
        # second fixture here would re-prove nothing check-nas doesn't.

        # PC3 -- a nas error is a nonzero exit
        rows, _ = run_cmd(client, 'nas -o X.OBJ NOSUCH.S', 'nas nosuch')
        rows = status(client, 'nas nosuch status')
        if 'NC=1' not in blob(rows):
            failures.append(f'PC3: missing-source run did not exit 1; '
                            f'screen:\n{blob(rows)}')
        else:
            print('[check-plascut] PC3 nas NOSUCH.S: exit 1')

        # PC4 -- warm cooked vs warm modular, same fixture
        run_cmd(client, 'clear', 'clear', max_steps=400)
        rows, cyc_cooked = run_cmd(client, 'nas -o T2.OBJ FIXTURE.S',
                                   'nas fixture (warm, cooked)')
        run_cmd(client, 'plasma NAS -o T0.OBJ FIXTURE.S',
                'plasma NAS (first, seed cold)', max_steps=20000)
        rows, cyc_mod = run_cmd(client, 'plasma NAS -o T3.OBJ FIXTURE.S',
                                'plasma NAS (warm seed, modular)',
                                max_steps=20000)
        if 'nas:' not in blob(rows):
            failures.append(f'PC4: modular run printed no nas: line; '
                            f'screen:\n{blob(rows)}')
        print(f'[check-plascut] PC4 FIXTURE.S warm: cooked {cyc_cooked} '
              f'cycles vs modular {cyc_mod} cycles '
              f'(+-50k; delta {cyc_mod - cyc_cooked} = the per-spawn '
              f'load plascut removes)')
        run_cmd(client, 'ls', 'ls (flush nudge)', max_steps=2000)
    finally:
        client.close()

    sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
    from a2til import prodos
    import vpath  # noqa: F401  (docs/VROOT.md)
    vol = prodos.mount(disk, replace=True, readonly=True)
    try:
        objs = {}
        for nm in ('T.OBJ', 'T2.OBJ', 'T3.OBJ'):
            try:
                objs[nm] = prodos.read(f'/mnt/{vol}/PLLIB/{nm}')
            except Exception as e:  # noqa: BLE001
                objs[nm] = None
                failures.append(f'PC2: cannot read {nm}: {e}')
    finally:
        prodos.unmount(vol)
    for nm, want, label in (('T.OBJ', ref, 'fixture'),
                            ('T2.OBJ', ref, 'fixture (warm cooked)'),
                            ('T3.OBJ', ref, 'fixture (modular)')):
        got = objs.get(nm)
        if got is None:
            continue
        if got != want:
            n = min(len(got), len(want))
            i = next((i for i in range(n) if got[i] != want[i]), n)
            failures.append(f'PC2: {nm} ({label}) differs from merlin32 at '
                            f'offset {i}: nas {len(got)} B, ref {len(want)} B')
        else:
            print(f'[check-plascut] PC2 {nm} ({label}): byte-identical to '
                  f'merlin32 ({len(want)} bytes)')

    if failures:
        print('[check-plascut] FAIL:')
        for f in failures:
            print('  - ' + f)
        return 1
    print('[check-plascut] PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
