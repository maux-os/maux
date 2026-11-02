#!/usr/bin/env python3
"""STATUS 2026-09-13: GREEN, wired as `make check-nas-librel` (in
CHECK_ALL_TARGETS beside check-nas-rel; on the box like every PLASMA
gate). THE ROSTER SWEEP on the STREAMING ld: 46 of 46 staged utils
BYTE-IDENTICAL to merlin32's monolithic builds -- every LOAD_BASE
program except plasma/proshim (a PC-equate span no cut may enter) and
as/proshimcr/proshimpg -- 275 nas spawns + 46 links in ~46B cycles
(~25 min wall on the fast backend). build/nas-librel-plan.json carries
every skip's measured reason and every staged unit's pieces.
docs/AS-LINKER-SPIKE.md has the table, the split's rules, and the
streaming linker that removed ld's build area (docs/LD-NATIVE.md).

The compare's teeth: the pwd pilot's deliberate sabotage (relpatch
storing $8000 without the addend -> `byte mismatch`); organically, LD's
first piece run (copied equates out of source order -> one byte short
at offset 1), EXPR (DFB byte-select fixups missing -> offset 738), and
proshimcr (its $E000 org vs the link address). What the compare CANNOT
see -- a trailing bss module sized wrong, since `ld -z` truncates the
zeros -- the bss audit found (sh's chunk 1, 3,572 B short); nas now
refuses an unresolved `ds` operand.

What the ORIGINAL "hang" was: NOT a loop in nas's REL directives. A
cooked nas leaves ~15 KB of heap and the raw syscalls REL form splices
12.9 KB of equ files on top of its own 6.4 KB, so heapalloc returned 0
for the expansion buffer, unchecked, and appendbytes() wrote the source
through the PLASMA VM's own zero page -- measured: the same raw staging
stops at ~25M cycles with `nas: out of memory`. Fixed on both sides:
nas checks every allocation, expands PUT in place, gives comment/blank
lines no line-table slot, sizes its tables exactly (src/asm/nas.pla,
the "memory diet" comments); the staging strips comments, blank lines
and trailing `;` comments, single-spaces the columns, and gives each
form ONE merged equ file holding only the equates it references
(build_nas_librel_image.equ_subset). REL fidelity found on the way:
`SYM+n` addends on relocatable/EXT terms, `da LABEL` and `dfb <LABEL`
fixups (nas.pla classifyoperand/relpatch).

check_nas_librel.py -- the linker-path gate (`make check-nas-librel`,
docs/AS-LINKER-SPIKE.md): COOKED nas, inside maux, assembles every liba
REL module and every util's generated REL main + bss, and `ld -z` links
each util -- the modular route that sidesteps nas's whole-source memory
wall by splitting liba out of the monolith into REL modules. This is
the check-librelas sweep (retired 2026-10-18) with nas swapped in for
the Sweet16 `as`.

Boots build/nas-librel.po (build_nas_librel_image.py) and types ONE
command, `sh /tmp/LR/SWEEP`: the staged script runs every `nas` and
`ld` line with stdout appended to /tmp/LR/NASLOG and ends with `echo
SWEEPDONE`, which this checker polls the screen for. Then, on the host,
it reads the image back: NASLOG (every nas/ld report, `nas: out of
memory` included), and each util's linked binary, compared BYTE-FOR-BYTE
against build/<util>.bin -- merlin32's own flat monolithic build. Type
$06 / aux $0800 are asserted on the linked file.

THE RATCHET (the check-librelas TIER2_BASELINE shape): NAS_TIER2 pins
the utils known NOT to convert yet, each with its measured reason. The
gate FAILS on any util outside that set that is missing or differs, and
FAILS (loudly, so the pin gets removed) when a pinned util converts --
the set may only shrink. Units skipped at staging time (predicted over
the heap; build/nas-librel-plan.json) are reported, not failed: the
prediction is the plan file's, and the plan is printed.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402

PT_F40_ADDR = 0x9FF0
PT_F40B_ADDR = 0x9FF1
PT_F40_MAG1 = 0xF4
PT_F40_MAG2 = 0x0A

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SELFMAKE = bool(os.environ.get('NAS_SELFMAKE'))
PLAN = os.path.join(ROOT, 'build',
                    'nas-selfmake-plan.json' if SELFMAKE
                    else 'nas-librel-plan.json')

# Utils staged (under the heap prediction) that nas+ld still cannot
# reproduce, pinned with the measured reason. Empty is the goal; a
# member that converts fails the gate until it is removed here.
NAS_TIER2 = {}

# Budget: one sh script drives the whole sweep. Measured 2026-09-13:
# the 46-unit roster takes ~46B cycles; 50B is the headroom left --
# raise STEP budget before the roster grows again; the >1.7x
# rule check_librelas.py states (a failure should be a byte diff, never
# a budget guess). The `not found`/prompt check inside the loop keeps a
# script that never starts from spending the budget.
STEP_CYCLES = 2_000_000
# 50B cycles for a shard or the links; the self-make boot runs ~250
# assemblies and 51 links in ONE boot (~75B measured 2026-09-14)
MAX_STEPS = 100000 if SELFMAKE else 25000


def rows_of(client):
    return client.call_tool('screen_text', {}).get('main', [])


def blob(rows):
    return '\n'.join(rows)


def at_prompt(rows):
    live = [r for r in rows if r.strip()]
    return bool(live) and live[-1].strip() in ('$', ']')


def step_until(client, pred, label, max_steps, chunk=50_000):
    rows = []
    for _ in range(max_steps):
        client.call_tool('step', {'cycles': chunk})
        rows = rows_of(client)
        if pred(rows):
            return rows
    raise RuntimeError(f'timed out waiting for {label}; screen:\n{blob(rows)}')


def run_sweep(disk, label, script='/tmp/LR/SWEEP', max_steps=None):
    """Boot `disk`, run its `script` (default /tmp/LR/SWEEP) to
    SWEEPDONE, flush. Returns the step count, or None on a failure
    (already printed). scripts/build_full_image.py runs its own script
    through here, so there is one copy of the boot-and-poll code."""
    max_steps = max_steps or MAX_STEPS
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    steps = 0
    try:
        client.initialize()
        client.call_tool('reset', {'backend': 'fast'})
        for addr, val in ((PT_F40_ADDR, PT_F40_MAG1),
                          (PT_F40B_ADDR, PT_F40_MAG2)):
            client.call_tool('poke', {'addr': addr, 'bytes': [val],
                                      'bank': 'main'})
        client.call_tool('mount_disk', {'path': disk})
        step_until(client, at_prompt, 'shell prompt', 1200, chunk=200_000)
        print(f'[check-nas-librel] {label}: shell prompt reached')
        # sh lives in the volume root, not on PATH (memory: "sh stays
        # in root, booted by abs path") -- a bare `sh` is `command not
        # found`. The early screen check below turns that class of
        # failure into seconds.
        client.call_tool('type', {'text': f'/bin/sh {script}\r'})
        rows = []
        for steps in range(1, max_steps + 1):
            client.call_tool('step', {'cycles': STEP_CYCLES})
            if steps % 25 == 0 or steps < 10:
                rows = rows_of(client)
                if 'SWEEPDONE' in blob(rows):
                    break
                if 'not found' in blob(rows) or at_prompt(rows):
                    print(f'[check-nas-librel] FAIL: {label}: the sweep '
                          f'script did not start; screen:\n{blob(rows)}')
                    return None
        else:
            print(f'[check-nas-librel] FAIL: {label}: sweep did not finish '
                  f'within {max_steps * STEP_CYCLES} cycles; screen:\n'
                  f'{blob(rows)}')
            return None
        print(f'[check-nas-librel] {label}: done in ~{steps * STEP_CYCLES:,} '
              'cycles')
        step_until(client, at_prompt, 'prompt after sweep', 200,
                   chunk=200_000)
        client.call_tool('type', {'text': 'ls\r'})     # flush nudge
        step_until(client, at_prompt, 'ls', 200, chunk=200_000)
        return steps
    finally:
        client.close()


def harvest(sh, disk):
    """Copy every shard's objects into `disk` in the ORIGINAL script
    order (a -l library splices its members in creation order), and
    concatenate the shards' NASLOGs so `nas: out of memory` lines are
    still reported."""
    sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
    from a2til import prodos
    import vpath  # noqa: F401  (docs/VROOT.md)
    logs = []
    data = {}
    for k, sp in enumerate(sh['shards']):
        v = prodos.mount(sp, replace=True, readonly=True)
        try:
            try:
                logs.append(prodos.read(f'/{v}/TMP/LR/NASLOG'))
            except Exception:  # noqa: BLE001
                pass
            for kk, path in sh['objects']:
                if kk != k:
                    continue
                try:
                    ent = next(e for e in prodos.scandir(path.rsplit('/', 1)[0])
                               if e.name == path.rsplit('/', 1)[1])
                    data[path] = (prodos.read(path), ent.type, ent.aux_type)
                except StopIteration:
                    pass                # nas failed it: reported via NASLOG
        finally:
            prodos.unmount(v)
    v = prodos.mount(disk, replace=True)
    try:
        n = 0
        for _k, path in sh['objects']:
            if path in data:
                d, ft, aux = data[path]
                prodos.write(path, d, file_type=ft, aux_type=aux,
                             overwrite=True)
                n += 1
        prodos.write(f'/{v}/TMP/LR/NASLOG', b''.join(logs), file_type=0x04,
                     aux_type=0, overwrite=True)
    finally:
        prodos.unmount(v)
    print(f'[check-nas-librel] harvested {n} of {len(sh["objects"])} '
          f'objects from {len(sh["shards"])} shards')
    missing = [f'shard{k}:{path.rsplit("/", 1)[1]}'
               for k, path in sh['objects'] if path not in data]
    if missing:
        print(f'[check-nas-librel] NOT assembled: {missing}')


def main():
    # progress lines must reach a pipe as they happen: through
    # `| grep | tail` a block-buffered stdout shows NOTHING until exit,
    # and a 25-minute sweep was twice mistaken for a hang (2026-09-13)
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except (AttributeError, ValueError):
        pass
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    disk = os.path.abspath(sys.argv[1])
    with open(PLAN) as fh:
        plan = json.load(fh)
    utils = plan['utils']
    if SELFMAKE:
        # A skipped utility must never silently shrink the release gate.
        from build_nas_librel_image import assert_complete_world
        assert_complete_world(utils, plan.get('kernels'), plan['skipped'])
    refs = {}
    for base in utils:
        p = os.path.join(ROOT, 'build', f'{base.lower()}.bin')
        with open(p, 'rb') as f:
            refs[base] = f.read()

    # SHARDS (build_nas_librel_image.py): boot every shard image in
    # parallel, harvest their objects (and NASLOGs) into `disk` in
    # script order, then run the links on `disk`.
    shards_json = os.path.join(ROOT, 'build', 'nas-librel-shards.json')
    if os.path.exists(shards_json) and not SELFMAKE:
        sh = json.load(open(shards_json))
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(len(sh['shards'])) as ex:
            results = list(ex.map(
                lambda kp: run_sweep(kp[1], f'shard{kp[0]}'),
                enumerate(sh['shards'])))
        if any(r is None for r in results):
            return 1
        harvest(sh, disk)
    if run_sweep(disk, 'links') is None:
        return 1

    sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
    from a2til import prodos
    import vpath  # noqa: F401  (docs/VROOT.md)
    vol = prodos.mount(disk, replace=True, readonly=True)
    try:
        try:
            log = prodos.read(f'/tmp/LR/NASLOG')
            log = bytes(b & 0x7F for b in log).decode('latin-1')
            log = log.replace('\r', '\n')
        except Exception as e:  # noqa: BLE001
            log = ''
            print(f'[check-nas-librel] no NASLOG: {e}')
        got = {}
        for base in utils:
            try:
                ent = next(e for e in prodos.scandir(f'/tmp/LR')
                           if e.name == base)
                got[base] = (prodos.read(f'/tmp/LR/{base}'),
                             ent.type, ent.aux_type)
            except Exception:  # noqa: BLE001
                got[base] = None
        mk2 = None
        if SELFMAKE:
            try:
                mk2 = bytes(b & 0x7F for b in prodos.read(f'/tmp/LR/MK2OUT'))
            except Exception:  # noqa: BLE001
                mk2 = None
        kgot = {}
        for stem, k in plan.get('kernels', {}).items():
            try:
                # ProDOS stores names uppercase: argvtest.bin is
                # ARGVTEST.BIN on the volume
                ent = next(e for e in prodos.scandir(f'/tmp/LR')
                           if e.name.upper() == k['out'].upper())
                kgot[stem] = (prodos.read(f'/tmp/LR/{ent.name}'),
                              ent.type, ent.aux_type)
            except Exception:  # noqa: BLE001
                kgot[stem] = None
    finally:
        prodos.unmount(vol)

    # make's echoed command and the child's independently buffered stdout
    # can interleave: '/bin/NAS -o Nnas: 129 bytes -> NUMR'.
    # Requiring a physical line start silently undercounts assemblies.
    nas_lines = re.findall(r'nas:[^\n]*', log)
    ld_lines = re.findall(r'ld:[^\n]*', log)
    print(f'[check-nas-librel] NASLOG: {len(nas_lines)} nas lines, '
          f'{len(ld_lines)} ld lines')
    for ln in nas_lines + ld_lines:
        if 'bytes ->' not in ln:
            print(f'    {ln}')

    def want_aux(base):
        # the link address: LOAD_BASE for a program, the manifest's
        # literal org for the proshim overlay blobs (linked `-a`)
        msrc = open(os.path.join(ROOT, 'src', 'bin', f'{base.lower()}.s'),
                    encoding='latin-1').read()
        m = re.search(r'^\s+org\s+(\$[0-9A-Fa-f]{1,4})\b', msrc, re.M)
        return int(m.group(1)[1:], 16) if m else 0x0800

    failures, converted, pinned_ok = [], [], []
    if SELFMAKE:
        # the -n rerun must have had nothing to do (check_selfmake's
        # freshness contract): a non-empty MK2OUT names what make
        # thought stale after building everything once
        if mk2 is None:
            failures.append('MK2OUT never written -- the `make -n` rerun '
                            'did not happen')
        elif mk2.strip():
            failures.append('the -n rerun would still run commands:\n'
                            + mk2.decode("latin-1")[:400])
        else:
            print('[check-nas-librel] MK2OUT empty -- the second make run '
                  'had nothing to do')
    for base in sorted(utils):
        ref = refs[base]
        g = got[base]
        if g is None:
            why = 'linked binary never written'
        elif g[1] != 0x06 or g[2] != want_aux(base):
            why = (f'type ${g[1]:02X} aux ${g[2]:04X}, want '
                   f'$06/${want_aux(base):04X}')
        elif g[0] != ref:
            n = min(len(g[0]), len(ref))
            i = next((j for j in range(n) if g[0][j] != ref[j]), n)
            gb = f'{g[0][i]:02x}' if i < len(g[0]) else '--'
            rb = f'{ref[i]:02x}' if i < len(ref) else '--'
            why = (f'byte mismatch at offset {i}: nas+ld=${gb} '
                   f'merlin32=${rb} (nas {len(g[0])} B, ref {len(ref)} B)')
        else:
            why = None
        if why is None:
            converted.append(base)
            if base in NAS_TIER2:
                pinned_ok.append(base)
        elif base in NAS_TIER2:
            print(f'[check-nas-librel] tier-2 {base}: {why} '
                  f'(pinned: {NAS_TIER2[base]})')
        else:
            failures.append(f'{base}: {why}')

    print(f'[check-nas-librel] byte-identical: {len(converted)} of '
          f'{len(utils)} staged utils -- {" ".join(converted)}')
    # THE KERNEL IMAGES (S5): every KERNEL_MAINS image linked inside
    # maux from nas-assembled kernel modules via `-l k`, against the
    # host's monolithic merlin32 image, type and aux included.
    kok = 0
    for stem, k in sorted(plan.get('kernels', {}).items()):
        # docs/KSEG.md's cold segment: nas+ld links a segment-bearing
        # manifest as ONE contiguous $2000-based blob (flat part +
        # segment back to back, ld's own `-s KSEG_ORG` override just
        # rebases the fixups, the FILE OFFSET keeps running) -- the
        # SAME shape merlin32 emits BEFORE split_kseg.py cuts it into
        # the `.SYSTEM` the harnesses load plus a separate `_KSEG`
        # file. `split_kseg.py` keeps that pre-split form at
        # `<ref>.full` for exactly this comparison; a manifest with no
        # segment has no such file, so `k['ref']` (the ordinary,
        # never-split `.SYSTEM`) is already the right reference.
        ref_path = os.path.join(ROOT, k['ref'])
        full_path = ref_path + '.full'
        if os.path.exists(full_path):
            ref_path = full_path
        ref = open(ref_path, 'rb').read()
        g = kgot.get(stem)
        if g is None:
            why = 'never written -- its assembly or link failed'
        elif g[1] != k['type'] or g[2] != k['base']:
            why = (f'type/aux ${g[1]:02X}/${g[2]:04X} != '
                   f'${k["type"]:02X}/${k["base"]:04X}')
        elif g[0] != ref:
            n = min(len(g[0]), len(ref))
            i = next((j for j in range(n) if g[0][j] != ref[j]), n)
            why = (f'byte mismatch at offset {i} (nas {len(g[0])} B, '
                   f'ref {len(ref)} B)')
        else:
            why = None
        nmod = len(k['link'].split()) - 5
        print(f'[check-nas-librel] {k["out"]:16s} (KERNEL, nas+ld -l k) '
              f'{len(ref):6d}B  {why or "byte-identical"}')
        if why is None:
            kok += 1
        else:
            failures.append(f'kernel {k["out"]}: {why}')
    if plan.get('kernels'):
        print(f'[check-nas-librel] kernel images byte-identical: {kok} of '
              f'{len(plan["kernels"])}')
    if plan['skipped']:
        print(f'[check-nas-librel] not staged ({len(plan["skipped"])}):')
        for base, why in sorted(plan['skipped'].items()):
            print(f'    {base}: {why}')
    if pinned_ok:
        failures.append(f'pinned tier-2 utils now CONVERT -- remove from '
                        f'NAS_TIER2: {pinned_ok}')
    if failures:
        print('[check-nas-librel] FAIL:')
        for f in failures:
            print('  - ' + f)
        return 1
    print('[check-nas-librel] PASS: every staged util is BYTE-IDENTICAL '
          'to merlin32\'s monolithic build via nas REL modules + ld'
          + (f', and every kernel image ({kok}) links byte-identical '
             f'from nas-assembled kernel modules via -l k'
             if plan.get('kernels') else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
