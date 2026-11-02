#!/usr/bin/env python3
"""check_nas.py -- nas L0 + L1a + :local (`make check-nas`,
docs/AS-PLASMA.md). nas, a native maux assembler written in PLASMA,
assembles THREE fixtures INSIDE maux and diffs each flat output
byte-for-byte against merlin32 reference builds (build/fixture.bin,
build/stress.bin, build/local.bin, produced on the host by the
Makefile's $(NASREF_BIN)/$(NASSTRESSREF_BIN)/$(NASLOCALREF_BIN)
rules):

  - the L0 fixture (src/test/asm/fixture.s) -- kept as a regression
    case now that L1a's heap-backed tables/evaluator/opcode table have
    replaced L0's fixed-cap engine.
  - the L1a stress fixture (src/test/asm/stress.s) -- >128 lines,
    >32 symbols, full 6502+65C02 opcode/addressing-mode coverage,
    every L1a data directive, the expression evaluator's operators,
    and a forward-referencing EQU chain.
  - the :local fixture (src/test/asm/local.s, task #21) -- within-
    zone :local (forward + backward), the same :name reused in a
    different zone, and a cross-zone reference to a file-unique name.
  - the L2 fixture (src/test/asm/l2b.s, task #21 gap-closure batch)
    -- DUM/DEND, a satisfied ERR (both inside and outside the DUM
    block), the `.`/`!`/`&` OR/EOR/AND operators, and a DSK line.

Boots build/nas.po (build_nas_image.py: the play image plus /mnt/MAUX/
PLRT, /mnt/MAUX/PLLIB/{ARGS,FILEIO,NAS,FIXTURE.S,STRESS.S,LOCAL.S,
L2B.S}) and, at the shell:

  ND1 `cd /mnt/MAUX/pllib` -- puts the shell's prefix where nas's own
       relative pathnames (FIXTURE.S, STRESS.S, T.OBJ, S.OBJ) resolve.
  ND2 `plasma NAS -o T.OBJ FIXTURE.S` -- rt (already resident as
       CMDSYS) execmods argv[1] (NAS), which loadmod's recursive
       dependency walk resolves: ARGS, FILEIO (CMDSYS is already
       resident). Unlike plasm.pla, nas.pla does NOT re-strip its own
       invoked name from cmdline (rt's buildcmdln already gives it
       argv[2..] as "-o T.OBJ FIXTURE.S" verbatim) -- so, unlike
       check_plasm.py's `plasma PLASM PLASM ...`, this is a single
       "NAS", not a doubled one. nas prints "nas: N bytes -> T.OBJ" on
       success.
  ND3 `echo NC=$?` -- nas's own top-level `run()` returns 0/1, which
       rt's `exit(rc == 0 ?? 0 :: 1)` turns into the process exit
       status the shell's $? reports.
  ND4 `plasma NAS -o S.OBJ STRESS.S` -- same pattern, the L1a fixture.
  ND5 `echo NC=$?` -- exit status of the stress-fixture run.
  ND6 `ls` -- one more filesystem operation after both objects' create/
       write/close, on the theory (check_plasm.py's PLD3 note) that
       a2til's write-through does not reliably sync the LAST file an
       emulator session wrote back to the host .po; one more directory
       read gives ProDOS's own catalog logic a reason to flush.

Byte comparison happens on the HOST after the emulator session closes:
mount build/nas.po with a2til, read /mnt/MAUX/PLLIB/T.OBJ and .../S.OBJ,
and diff each against its merlin32 reference byte-for-byte.

Boot/type/screen helpers are check_plasm.py's (copied, not imported).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402

PT_F40_ADDR = 0x9FF0        # src/test/playtestb.s PT_F40 (check_play.py)
PT_F40B_ADDR = 0x9FF1
PT_F40_MAG1 = 0xF4
PT_F40_MAG2 = 0x0A

RAN_LINE = 'nas:'

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REF_BIN = os.path.join(ROOT, 'build', 'fixture.bin')
STRESS_REF_BIN = os.path.join(ROOT, 'build', 'stress.bin')
LOCAL_REF_BIN = os.path.join(ROOT, 'build', 'local.bin')
L2B_REF_BIN = os.path.join(ROOT, 'build', 'l2b.bin')


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


def run_fixture(disk, srcname, objname, tag, run_max_steps=8000):
    """Boot a FRESH emulator session, assemble ONE fixture, and return
    (exit_line_seen, exit_zero_seen, list_of_failures). A brand-new
    boot per fixture -- rather than chaining two `plasma NAS ...`
    invocations in one session -- because the second file's write was
    observed to not reliably reach the host .po when run right after
    the first one in the SAME session (even after extra `ls` flush
    nudges); a fresh boot per fixture sidesteps whatever cross-
    invocation state that was.
    """
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
        print(f'[check-nas] [{tag}] shell prompt reached')

        client.call_tool('type', {'text': 'cd /mnt/MAUX/pllib\r'})
        wait_for_screen(client, prompt_ready, f'[{tag}] ND1: prompt after cd')
        print(f'[check-nas] [{tag}] ND1: cd /mnt/MAUX/pllib')

        client.call_tool('type',
                          {'text': f'plasma NAS -o {objname} {srcname}\r'})
        try:
            wait_for_scrolling(client, [RAN_LINE], f'[{tag}] ND2: {RAN_LINE!r}',
                               max_steps=run_max_steps)
            print(f'[check-nas] [{tag}] ND2: {RAN_LINE!r}')
        except RuntimeError as e:
            failures.append(f'[{tag}] ND2: {e}')
        wait_for_screen(client, prompt_ready, f'[{tag}] ND2: prompt',
                        max_steps=4000)

        client.call_tool('type', {'text': 'echo NC=$?\r'})
        try:
            wait_for_scrolling(client, ['NC=0'], f'[{tag}] ND3: exit 0',
                               max_steps=2000)
            print(f'[check-nas] [{tag}] ND3: exit 0')
        except RuntimeError as e:
            failures.append(f'[{tag}] ND3: {e}')
        wait_for_screen(client, prompt_ready, f'[{tag}] ND3: prompt after echo')

        # ND4: one more filesystem op, on the theory that a2til's
        # write-through does not reliably sync the LAST file an
        # emulator session wrote (check_plasm.py's PLD3 note).
        client.call_tool('type', {'text': 'ls\r'})
        wait_for_screen(client, prompt_ready, f'[{tag}] ND4: prompt after ls',
                        max_steps=2000)
        print(f'[check-nas] [{tag}] ND4: ls (flush nudge)')
    finally:
        client.close()
    return failures


def check_one(disk, srcname, objname, tag, ref_bytes, ref_path,
               run_max_steps=8000):
    failures = run_fixture(disk, srcname, objname, tag,
                            run_max_steps=run_max_steps)
    if failures:
        print(f'[check-nas] FAIL ({tag}):')
        for f in failures:
            print('  - ' + f)
        return False

    sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
    from a2til import prodos
    import vpath  # noqa: F401  (docs/VROOT.md)
    vol = prodos.mount(disk, replace=True, readonly=True)
    try:
        obj_bytes = prodos.read(f'/mnt/{vol}/PLLIB/{objname}')
    finally:
        prodos.unmount(vol)

    print(f'[check-nas] {tag} fixture: merlin32 reference '
          f'{len(ref_bytes)} bytes ({ref_path}), nas object '
          f'{len(obj_bytes)} bytes (/mnt/MAUX/PLLIB/{objname})')
    if obj_bytes != ref_bytes:
        n = min(len(obj_bytes), len(ref_bytes))
        first_diff = next((i for i in range(n)
                            if obj_bytes[i] != ref_bytes[i]), n)
        nas_byte = (f'{obj_bytes[first_diff]:02x}'
                    if first_diff < len(obj_bytes) else '--')
        ref_byte = (f'{ref_bytes[first_diff]:02x}'
                    if first_diff < len(ref_bytes) else '--')
        print(f'[check-nas] FAIL ({tag}): byte mismatch at offset '
              f'{first_diff}: nas=${nas_byte} merlin32=${ref_byte}',
              file=sys.stderr)
        print(f'  nas:      {obj_bytes.hex()}', file=sys.stderr)
        print(f'  merlin32: {ref_bytes.hex()}', file=sys.stderr)
        return False

    print(f'[check-nas] PASS ({tag}): nas object is byte-identical to '
          f'merlin32\'s reference build ({len(ref_bytes)} bytes)')
    return True


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    disk = os.path.abspath(sys.argv[1])
    if not os.path.exists(REF_BIN):
        print(f'error: missing oracle {REF_BIN} (make build/fixture.bin)',
              file=sys.stderr)
        return 2
    if not os.path.exists(STRESS_REF_BIN):
        print(f'error: missing oracle {STRESS_REF_BIN} '
              '(make build/stress.bin)', file=sys.stderr)
        return 2
    if not os.path.exists(LOCAL_REF_BIN):
        print(f'error: missing oracle {LOCAL_REF_BIN} '
              '(make build/local.bin)', file=sys.stderr)
        return 2
    if not os.path.exists(L2B_REF_BIN):
        print(f'error: missing oracle {L2B_REF_BIN} '
              '(make build/l2b.bin)', file=sys.stderr)
        return 2
    with open(REF_BIN, 'rb') as f:
        ref_bytes = f.read()
    with open(STRESS_REF_BIN, 'rb') as f:
        stress_ref_bytes = f.read()
    with open(LOCAL_REF_BIN, 'rb') as f:
        local_ref_bytes = f.read()
    with open(L2B_REF_BIN, 'rb') as f:
        l2b_ref_bytes = f.read()

    ok_l0 = check_one(disk, 'FIXTURE.S', 'T.OBJ', 'L0', ref_bytes, REF_BIN)
    ok_stress = check_one(disk, 'STRESS.S', 'S.OBJ', 'stress',
                           stress_ref_bytes, STRESS_REF_BIN,
                           run_max_steps=20000)
    ok_local = check_one(disk, 'LOCAL.S', 'L.OBJ', 'local',
                          local_ref_bytes, LOCAL_REF_BIN)
    ok_l2b = check_one(disk, 'L2B.S', 'B.OBJ', 'l2b',
                        l2b_ref_bytes, L2B_REF_BIN)

    return 0 if (ok_l0 and ok_stress and ok_local and ok_l2b) else 1


if __name__ == '__main__':
    sys.exit(main())
