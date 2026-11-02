#!/usr/bin/env python3
"""profile_nas_vs_as.py -- MEASURE nas (PLASMA) vs the warm Merlin-8 `as`
core's assembly THROUGHPUT on verilogapple (docs/AS-PROFILE.md). This is
a MEASUREMENT script, not a gate: no pass/fail, not in
CHECK_ALL_TARGETS. `make profile-nas` runs it.

METHOD (fixed by the architect -- do not "improve" it; see
docs/AS-PROFILE.md sec "The measurement"):

Startup cost differs wildly between the two assemblers (nas loads the
PLASMA VM + rt + deps + nas.mod; `as` loads one 12 KB image), so a
single total-time number would be dominated by startup and would be
MISLEADING. Instead this measures the per-line THROUGHPUT = the SLOPE
between two source sizes, which cancels startup:

    perline = (cyc_large - cyc_small) / (lines_large - lines_small)
    startup = cyc_small - perline * lines_small

Four measurements: {as, nas} x {prof.small.s (N=10 blocks),
prof.large.s (N=100 blocks)}. Each is its own FRESH emulator boot (the
check-nas precedent: a fresh boot per assembly sidesteps whatever
cross-invocation state makes a second same-session write unreliable to
sync back to the host .po). For each: mount build/profile.po, reach the
shell prompt, type the ONE assemble command, then `step` in fixed
50,000-cycle chunks (fast backend: 1 step unit = 1 CPU cycle) --
accumulating the total until the shell prompt genuinely returns.

THE FALSE-PROMPT TRAP (found empirically while building this script,
by booting build/nas.po and dumping screen_text() after each typed
keystroke chunk): the shell's prompt is "$ " and typed
input echoes on the SAME row ("$ cd /mnt/MAUX/pllib"), which ALSO
satisfies a naive `row.startswith('$')` check -- so polling that
predicate immediately after `type()` risks a false "done" the instant
ANY row starts with '$', including the echo-in-progress row itself.
The fix used here: prompt_ready requires the row to be EXACTLY '$'
after stripping trailing whitespace (a genuinely bare prompt, no
echoed text on it) -- and the accumulation runs in two guarded phases,
(1) wait for the row to stop being bare (the command has visibly
started: keystrokes are echoing) then (2) wait for it to become bare
again (the prompt has genuinely returned). Both phases' step counts are
summed into ONE total per run -- this does not change what is measured
(cycles from typing the command to the prompt returning), it only
avoids mis-detecting "returned" at cycle 0. Overshoot is bounded by one
50,000-cycle chunk per phase, identically for all four runs, so it
cancels in the slope exactly as the fixed methodology expects.

Command lines are built so the SMALL and LARGE invocation of the SAME
assembler are the same length, character for character (PROFSM.S /
PROFLG.S, ASOUT1.OBJ / ASOUT2.OBJ, NOUT1.OBJ / NOUT2.OBJ) -- so the
keystroke-echo phase (phase 1 above) costs the identical number of
cycles for small vs large, and that fixed cost cancels in the slope
too rather than leaking into `perline`.

VALIDITY GATE: after all four runs, the two objects nas and `as`
produced for the SAME fixture must be byte-identical to each other AND
(cheaply, on the host) to merlin32's own reference build -- this is
prove that both assemblers did the same work and got the same bytes,
the same discipline check-nas.py already applies to nas alone.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'profile.po')
MERLIN32 = os.environ.get('MERLIN32', 'merlin32')

PT_F40_ADDR = 0x9FF0        # src/test/playtestb.s PT_F40 (check_nas.py precedent)
PT_F40B_ADDR = 0x9FF1
PT_F40_MAG1 = 0xF4
PT_F40_MAG2 = 0x0A

CHUNK = 50_000               # fixed per the methodology (1 chunk = 1 poll)
# nas-small (10 blocks, 78 lines) measured at 51.75M cycles in an early
# probe -- almost all of it PLASMA-VM/module-load startup, per docs/
# AS-PLASMA.md's own framing. check-nas's OWN stress fixture (287
# lines/41 symbols, smaller than prof.large.s) budgets up to 4,000,000,000
# cycles (20000 steps x 200,000). Match that order of magnitude here
# rather than re-guessing low a second time.
MAX_CHUNKS_NAS = 90_000        # 4.5B cycles/run ceiling
MAX_CHUNKS_AS = 8000          # 400M cycles/run ceiling -- Sweet16 is slow
BOOT_MAX_STEPS = 1200         # 200k-cycle chunks while waiting to boot

SMALL_SRC = os.path.join(ROOT, 'src', 'test', 'asm', 'prof.small.s')
LARGE_SRC = os.path.join(ROOT, 'src', 'test', 'asm', 'prof.large.s')
# symbol-LIGHT companions (docs/AS-PROFILE.md "symbol-light experiment"):
# same repeating-block shape, but the block declares no label and
# references no symbol -- symbol-table work stays CONSTANT across N, so
# the small/large slope here is the pure per-line language/VM cost,
# uncontaminated by the symtab algorithm the small/large pair above is
# measuring.
LEAN_SMALL_SRC = os.path.join(ROOT, 'src', 'test', 'asm', 'profleansmall.s')
LEAN_LARGE_SRC = os.path.join(ROOT, 'src', 'test', 'asm', 'profleanlarge.s')


def screen_rows(client):
    return client.call_tool('screen_text', {}).get('main', [])


def live_rows(rows):
    return [r for r in rows if r.strip()]


def screen_blob(rows):
    return '\n'.join(rows)


def bare_prompt(rows):
    """A genuinely EMPTY prompt row -- '$' with no echoed text after
    it. See this file's own module docstring, "THE FALSE-PROMPT TRAP."
    """
    live = live_rows(rows)
    return bool(live) and live[-1].strip() == '$'


def wait_for(client, predicate, label, max_steps, chunk_cycles=200_000):
    """Step in `chunk_cycles`-sized increments (NOT the measured 50,000
    chunk -- this is for untimed boot/cd waits only) until `predicate`
    holds. Returns the number of CPU cycles stepped."""
    rows = []
    total = 0
    for _ in range(max_steps):
        client.call_tool('step', {'cycles': chunk_cycles})
        total += chunk_cycles
        rows = screen_rows(client)
        if predicate(rows):
            return total
    raise RuntimeError(f'timed out waiting for {label}; screen was:\n'
                        f'{screen_blob(rows)}')


def boot_client():
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    client.initialize()
    client.call_tool('reset', {'backend': 'fast'})
    for addr, val in ((PT_F40_ADDR, PT_F40_MAG1), (PT_F40B_ADDR, PT_F40_MAG2)):
        client.call_tool('poke', {'addr': addr, 'bytes': [val], 'bank': 'main'})
    client.call_tool('mount_disk', {'path': DISK})
    wait_for(client, bare_prompt, 'boot shell prompt', BOOT_MAX_STEPS)
    return client


def timed_command(client, cmd_text, tag, max_chunks):
    """Type `cmd_text` (must end '\\r') and accumulate 50,000-cycle
    `step` chunks until the shell prompt genuinely returns. Two guarded
    phases (see module docstring); returns their SUMMED cycle total,
    which is exactly "cycles from typing the command to the prompt
    returning" -- the methodology's own definition."""
    client.call_tool('type', {'text': cmd_text})
    total = 0
    rows = screen_rows(client)
    # Phase 1: wait for the bare prompt to visibly go away (keystrokes
    # echoing / command running) -- guards against mistaking the
    # ALREADY-bare pre-command prompt for a completed run.
    n = 0
    while bare_prompt(rows):
        client.call_tool('step', {'cycles': CHUNK})
        total += CHUNK
        rows = screen_rows(client)
        n += 1
        if n > max_chunks:
            raise RuntimeError(
                f'[{tag}] phase 1 (command never started echoing) timed '
                f'out after {total} cycles; screen was:\n{screen_blob(rows)}')
    # Phase 2: wait for the bare prompt to return.
    n = 0
    while not bare_prompt(rows):
        client.call_tool('step', {'cycles': CHUNK})
        total += CHUNK
        rows = screen_rows(client)
        n += 1
        if n > max_chunks:
            raise RuntimeError(
                f'[{tag}] phase 2 (prompt never returned) timed out after '
                f'{total} cycles; screen was:\n{screen_blob(rows)}')
    return total


def run_as(size_tag, srcname, objname, max_chunks):
    client = boot_client()
    try:
        cmd = f'AS /mnt/MAUX/PLLIB/{srcname} -o /mnt/MAUX/PLLIB/{objname}\r'
        cyc = timed_command(client, cmd, f'as-{size_tag}', max_chunks)
        # flush nudge (check-nas ND6 precedent: a2til write-through may
        # not reliably sync the LAST file an emulator session wrote).
        client.call_tool('type', {'text': 'ls\r'})
        wait_for(client, bare_prompt, f'as-{size_tag} ND: ls flush', 400,
                 chunk_cycles=50_000)
        print(f'[profile-nas] as-{size_tag}: {cyc} cycles')
    finally:
        client.close()
    return cyc


def run_nas(size_tag, srcname, objname, max_chunks):
    client = boot_client()
    try:
        client.call_tool('type', {'text': 'cd /mnt/MAUX/pllib\r'})
        wait_for(client, bare_prompt, f'nas-{size_tag} cd prompt', 400,
                 chunk_cycles=50_000)
        cmd = f'plasma NAS -o {objname} {srcname}\r'
        cyc = timed_command(client, cmd, f'nas-{size_tag}', max_chunks)
        client.call_tool('type', {'text': 'ls\r'})
        wait_for(client, bare_prompt, f'nas-{size_tag} ND: ls flush', 400,
                 chunk_cycles=50_000)
        print(f'[profile-nas] nas-{size_tag}: {cyc} cycles')
    finally:
        client.close()
    return cyc


def read_obj(objname):
    sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
    from a2til import prodos
    import vpath  # noqa: F401  (docs/VROOT.md)
    vol = prodos.mount(DISK, replace=True, readonly=True)
    try:
        return prodos.read(f'/mnt/{vol}/PLLIB/{objname}')
    finally:
        prodos.unmount(vol)


def merlin32_reference(src_path):
    d = os.path.dirname(src_path)
    base = os.path.splitext(os.path.basename(src_path))[0]
    for junk in (base, f'{base}_Output.txt', '_FileInformation.txt'):
        p = os.path.join(d, junk)
        if os.path.exists(p) and junk == base:
            os.remove(p)
    subprocess.run([MERLIN32, os.path.basename(src_path)], cwd=d, check=True,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    out_path = os.path.join(d, base)
    with open(out_path, 'rb') as f:
        data = f.read()
    for junk in (base, f'{base}_Output.txt'):
        p = os.path.join(d, junk)
        if os.path.exists(p):
            os.remove(p)
    fi = os.path.join(d, '_FileInformation.txt')
    if os.path.exists(fi):
        os.remove(fi)
    return data


def count_lines(path):
    with open(path, 'rb') as f:
        return sum(1 for _ in f)


def count_symbols(path):
    n = 0
    with open(path, 'r') as f:
        for line in f:
            if line and (line[0].isalpha()):
                n += 1
    return n


def main():
    if not os.path.exists(DISK):
        print(f'error: missing {DISK} (make build/profile.po first, '
              'scripts/build_profile_image.py)', file=sys.stderr)
        return 2

    lines_small = count_lines(SMALL_SRC)
    lines_large = count_lines(LARGE_SRC)
    syms_small = count_symbols(SMALL_SRC)
    syms_large = count_symbols(LARGE_SRC)
    print(f'[profile-nas] prof.small.s: {lines_small} lines, '
          f'{syms_small} symbols')
    print(f'[profile-nas] prof.large.s: {lines_large} lines, '
          f'{syms_large} symbols')

    cyc_as_small = run_as('small', 'PROFSM.S', 'ASOUT1.OBJ', MAX_CHUNKS_AS)
    cyc_as_large = run_as('large', 'PROFLG.S', 'ASOUT2.OBJ', MAX_CHUNKS_AS)
    cyc_nas_small = run_nas('small', 'PROFSM.S', 'NOUT1.OBJ', MAX_CHUNKS_NAS)
    cyc_nas_large = run_nas('large', 'PROFLG.S', 'NOUT2.OBJ', MAX_CHUNKS_NAS)

    as_small_obj = read_obj('ASOUT1.OBJ')
    as_large_obj = read_obj('ASOUT2.OBJ')
    nas_small_obj = read_obj('NOUT1.OBJ')
    nas_large_obj = read_obj('NOUT2.OBJ')

    ref_small = merlin32_reference(SMALL_SRC)
    ref_large = merlin32_reference(LARGE_SRC)

    ok = True

    def check(label, a, b):
        nonlocal ok
        same = a == b
        print(f'[profile-nas] VALIDITY {label}: {"MATCH" if same else "DIVERGE"} '
              f'({len(a)} vs {len(b)} bytes)')
        if not same:
            ok = False
        return same

    check('small: as == nas', as_small_obj, nas_small_obj)
    check('small: as == merlin32', as_small_obj, ref_small)
    check('small: nas == merlin32', nas_small_obj, ref_small)
    check('large: as == nas', as_large_obj, nas_large_obj)
    check('large: as == merlin32', as_large_obj, ref_large)
    check('large: nas == merlin32', nas_large_obj, ref_large)

    d_lines = lines_large - lines_small
    as_perline = (cyc_as_large - cyc_as_small) / d_lines
    nas_perline = (cyc_nas_large - cyc_nas_small) / d_lines
    as_startup = cyc_as_small - as_perline * lines_small
    nas_startup = cyc_nas_small - nas_perline * lines_small
    ratio = as_perline / nas_perline if nas_perline else float('inf')
    crossover = ((nas_startup - as_startup) / (as_perline - nas_perline)
                 if (as_perline - nas_perline) else float('inf'))

    # ---- symbol-LIGHT experiment (docs/AS-PROFILE.md) -------------------
    lines_lean_small = count_lines(LEAN_SMALL_SRC)
    lines_lean_large = count_lines(LEAN_LARGE_SRC)
    print(f'[profile-nas] profleansmall.s: {lines_lean_small} lines')
    print(f'[profile-nas] profleanlarge.s: {lines_lean_large} lines')

    cyc_as_lean_small = run_as('lean-small', 'PROFLNSM.S', 'ASOUT3.OBJ', MAX_CHUNKS_AS)
    cyc_as_lean_large = run_as('lean-large', 'PROFLNLG.S', 'ASOUT4.OBJ', MAX_CHUNKS_AS)
    cyc_nas_lean_small = run_nas('lean-small', 'PROFLNSM.S', 'NOUT3.OBJ', MAX_CHUNKS_NAS)
    cyc_nas_lean_large = run_nas('lean-large', 'PROFLNLG.S', 'NOUT4.OBJ', MAX_CHUNKS_NAS)

    as_lean_small_obj = read_obj('ASOUT3.OBJ')
    as_lean_large_obj = read_obj('ASOUT4.OBJ')
    nas_lean_small_obj = read_obj('NOUT3.OBJ')
    nas_lean_large_obj = read_obj('NOUT4.OBJ')

    ref_lean_small = merlin32_reference(LEAN_SMALL_SRC)
    ref_lean_large = merlin32_reference(LEAN_LARGE_SRC)

    check('lean-small: as == nas', as_lean_small_obj, nas_lean_small_obj)
    check('lean-small: as == merlin32', as_lean_small_obj, ref_lean_small)
    check('lean-small: nas == merlin32', nas_lean_small_obj, ref_lean_small)
    check('lean-large: as == nas', as_lean_large_obj, nas_lean_large_obj)
    check('lean-large: as == merlin32', as_lean_large_obj, ref_lean_large)
    check('lean-large: nas == merlin32', nas_lean_large_obj, ref_lean_large)

    d_lines_lean = lines_lean_large - lines_lean_small
    as_perline_lean = (cyc_as_lean_large - cyc_as_lean_small) / d_lines_lean
    nas_perline_lean = (cyc_nas_lean_large - cyc_nas_lean_small) / d_lines_lean
    lean_ratio = (nas_perline_lean / as_perline_lean
                  if as_perline_lean else float('inf'))

    print()
    print('[profile-nas] ==================== RESULTS ====================')
    print(f'[profile-nas] fixtures: small {lines_small} lines / '
          f'{syms_small} symbols, large {lines_large} lines / '
          f'{syms_large} symbols')
    print(f'[profile-nas] as:  small={cyc_as_small} cyc  '
          f'large={cyc_as_large} cyc')
    print(f'[profile-nas] nas: small={cyc_nas_small} cyc  '
          f'large={cyc_nas_large} cyc')
    print(f'[profile-nas] as  perline={as_perline:.1f} cyc/line  '
          f'startup={as_startup:.0f} cyc')
    print(f'[profile-nas] nas perline={nas_perline:.1f} cyc/line  '
          f'startup={nas_startup:.0f} cyc')
    print(f'[profile-nas] throughput ratio (as_perline/nas_perline) = '
          f'{ratio:.3f}')
    print(f'[profile-nas] crossover source size = {crossover:.1f} lines')
    print()
    print(f'[profile-nas] -------- symbol-LIGHT (proflean*.s) --------')
    print(f'[profile-nas] as:  lean-small={cyc_as_lean_small} cyc  '
          f'lean-large={cyc_as_lean_large} cyc')
    print(f'[profile-nas] nas: lean-small={cyc_nas_lean_small} cyc  '
          f'lean-large={cyc_nas_lean_large} cyc')
    print(f'[profile-nas] as  lean perline={as_perline_lean:.1f} cyc/line')
    print(f'[profile-nas] nas lean perline={nas_perline_lean:.1f} cyc/line')
    print(f'[profile-nas] SYMBOL-LIGHT per-line ratio '
          f'(nas_perline_lean/as_perline_lean) = {lean_ratio:.3f}x '
          f'-- the honest PLASMA-vs-Merlin cost, uncontaminated by the '
          f'symbol table')
    print(f'[profile-nas] validity gate: {"PASS" if ok else "FAIL"}')

    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
