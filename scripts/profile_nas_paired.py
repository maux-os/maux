#!/usr/bin/env python3
"""Paired warm cooked NAS/AS sampling on the existing flat slope fixtures.

Diagnostic, not a gate or a hardware timing claim. Reuses the cooked
comparison's private images, immediate warm invocation and fresh byte oracle.
Samples are jittered and PC-first; VM IP/Y transitions are approximate.
Whole-command histograms permit large-minus-small marginal attribution.
AS LC code is grouped as native core (not falsely symbolized as frontend).
"""
import argparse
from collections import Counter
import csv
import json
from pathlib import Path
import random
import re
import shutil
import tempfile

import profile_nas_cooked_vs_as as pair
import profile_nas_hotspots as hot
from textaudit import load_syms


def as_symbols(build, binary):
    listing = build / 'as.bin_Output.txt'
    names = []
    defined = set(re.findall(r'^\s*([A-Z][A-Z0-9_]*)\s*=', listing.read_text(), re.MULTILINE))
    # Only actual emitted global labels, never equates/data symbol aliases.
    for line in listing.read_text().splitlines():
        m = re.search(r'\|\s*00/([0-9A-F]{4}) : [0-9A-F ]+\|\s*([A-Z][A-Z0-9_]*)\s+', line)
        if m and m[2] in defined:
            names.append(m[2])
    syms = load_syms(str(listing), names=tuple(set(names)), binary=str(build / 'as.bin'))
    # Bind listing bytes to the binary, not merely its modification time.
    for line in listing.read_text().splitlines():
        m = re.search(r'\|\s*00/([0-9A-F]{4}) : ([0-9A-F ]+)\|', line)
        if m:
            at, data = int(m[1], 16) - 0x800, bytes.fromhex(m[2])
            if 0 <= at < len(binary):
                assert binary[at:at + len(data)] == data, 'AS listing bytes differ'
    return sorted((v, k) for k, v in syms.items() if 0x800 <= v < 0x800 + len(binary))


def as_lookup_range(build, binary):
    # ASS.BNK1.S NXOPS..GETOPC..R2, decoded against its native macro-free
    # source and MERLIN.GP.S equates. A full signature binds this annotation
    # to the actual embedded core; do not carry a naked D651 across builds.
    signature = bytes.fromhex('A901D012A2048512841318A000B112F018C5EAF00C'
                              '8A186512851290EEE613D0E9C8B112C5EBD0EDC860')
    core = (build / 'ascore-warm-bank1.obj').read_bytes()
    at = core.find(signature)
    assert at >= 0 and core.find(signature, at + 1) < 0
    assert binary.find(core) >= 0, 'AS does not embed this core'
    return [0xD000 + at, 0xD000 + at + len(signature)]


def trace_counts(path, initial, final, bank, info):
    """Exact fetch counts; track bank/softswitch writes, not numeric PC alone.

    Fast trace registers/SYNC are post-tick, bus address/data are the cycle
    just executed. PREVIOUS row SYNC gates this row's opcode fetch. A hardware
    IRQ dummy fetch freezes PC, so require PC=address+1 to count execution.
    Verified against cpu65c02_impl.h S_FETCH and mcp_server.cpp fast_tick.
    No until_pc hits or sampled IP values enter these counts.
    """
    cooked, defs, _, native, _, base, _ = info
    entries = {base + lo: 'native:' + n for lo, _, n in native}
    for off, _, name in defs:
        sig = bytes((0x20, 0x06, 0x08)) + (base + off).to_bytes(2, 'little')
        at = cooked.find(sig)
        assert at >= 0 and cooked.find(sig, at + 1) < 0, name
        entries[at + 0x800] = 'VM:' + name
    state = {k: initial[k] for k in ('RAMRD', 'ALTZP', 'ramworks_bank')}
    calls, byphase, dispatch = Counter(), {}, Counter()
    phase, rows, syncs = 'startup', 0, 0
    phasecycles = Counter()
    dispatch_owner, bytecodes = Counter(), Counter()
    previous_sync, previous_pc, ip = False, None, 0
    first, last = None, None
    with path.open() as stream:
        for row in csv.DictReader(stream):
            cycle = int(row['cyc'])
            if first is None:
                first = cycle
            if last is not None:
                assert cycle == last + 1, 'trace gap or overwritten ring'
            last = cycle
            rows += 1
            addr = int(row['addr'], 16)
            pc = int(row['pc'], 16)
            active = state['ALTZP'] and state['ramworks_bank'] == bank
            if active and row['rw'] == 'W' and addr in (0xF2, 0xF3):
                data = int(row['data'], 16)
                ip = (ip & 0xFF00) | data if addr == 0xF2 else (ip & 0xFF) | (data << 8)
            if row['rw'] == 'W':
                if addr == 0xC073:
                    state['ramworks_bank'] = int(row['data'], 16)
                elif addr in (0xC002, 0xC003):
                    state['RAMRD'] = addr == 0xC003
                elif addr in (0xC008, 0xC009):
                    state['ALTZP'] = addr == 0xC009
            if previous_sync:
                assert addr == previous_pc and row['rw'] == 'R', 'SYNC/bus alignment changed'
            if previous_sync and pc == (addr + 1) & 0xFFFF:
                syncs += 1
                if state['RAMRD'] and state['ALTZP'] and state['ramworks_bank'] == bank:
                    name = entries.get(addr)
                    if name:
                        assert int(row['data'], 16) == cooked[addr - 0x800]
                        if name in ('VM:pass0', 'VM:pass1', 'VM:pass2'):
                            phase = name[3:]
                        calls[name] += 1
                        byphase.setdefault(phase, Counter())[name] += 1
                    if addr == 0xF1:
                        dispatch[phase] += 1
                        at = (ip + int(row['y'], 16)) & 0xFFFF
                        owner = hot.symbols.classify_offset(defs, info[2], at - base)
                        if owner:
                            dispatch_owner[owner] += 1
                            bytecodes[f'{cooked[at - 0x800]:02X}'] += 1
            previous_sync, previous_pc = row['sync'] == '1', pc
            phasecycles[phase] += 1
    assert syncs > 0
    assert state == {k: final[k] for k in state}, (state, final)
    return dict(rows=rows, opcode_fetches=syncs, phase_cycles=dict(phasecycles),
                calls=dict(calls), calls_by_phase=byphase, vm_dispatch=dict(dispatch),
                nas_dispatch_by_function=dict(dispatch_owner), nas_bytecode_counts=dict(bytecodes),
                note='Phase spans run from entry thunk to next pass entry; pass2 includes finish-to-prompt.')


def run(disk, tool, name, expected, info, assembler, astable, seed, tracepath=None,
        trace_analyzer=None, source_path=None, object_metadata=None):
    cooked, defs, seglen, native, vm, base, signatures = info
    pair.rig.DISK = str(disk)
    client = pair.rig.boot_client()
    rng = random.Random(seed)
    hist, phases, pcs = Counter(), Counter(), Counter()
    phase, bank, elapsed, started = 'startup', None, 0, False
    try:
        source = source_path or f'{pair.DIRECTORY}/{name}'
        cold = pair.rig.timed_command(client, pair.command(tool, source,
            f'{pair.DIRECTORY}/COLD.O'), tool + '-cold', pair.rig.MAX_CHUNKS_AS)
        if tracepath:
            initial = client.call_tool('softswitches', {})
            client.require_tools('trace_capture')
            client.call_tool('trace_capture', {'action': 'start', 'capacity': 20000000})
        client.call_tool('type', {'text': pair.command(tool, source,
            f'{pair.DIRECTORY}/WARM.O')})
        for _ in range(30000):
            step = rng.randrange(*hot.JITTER)
            client.call_tool('step', {'cycles': step})
            elapsed += step
            sw = client.call_tool('softswitches', {})
            regs = client.call_tool('regs', {})
            pc, live = regs['pc'], sw['ramworks_bank']
            active = bool(live and sw['RAMRD'] and sw['ALTZP'])
            if bank is None and active:
                sigs = [(base + off, sig) for _, off, sig in signatures] if tool == 'nas' else [(0x800, assembler[:32])]
                if all(bytes(client.call_tool('peek', {'addr': at,
                        'count': len(sig), 'bank': 'aux', 'aux_bank': live})['bytes']) == sig
                       for at, sig in sigs):
                    bank = live
            bucket = 'kernel/other'
            if active and live == bank:
                if tool == 'as':
                    if 0xD000 <= pc < 0xFF00:
                        bucket = 'native:LC-core/stubs'
                    elif 0x800 <= pc < 0x800 + len(assembler):
                        owner = next((n for a, n in reversed(astable) if a <= pc), 'unknown')
                        bucket = 'native:' + owner
                    elif pc < 0xBF00:
                        bucket = 'native:other'
                elif vm['DINTRP'] <= pc < vm['START'] or 0xEF <= pc <= 0xF8:
                    zp = client.call_tool('peek', {'addr': vm['IPL'], 'count': 2,
                        'bank': 'aux', 'aux_bank': bank})['bytes']
                    ip = (zp[0] + 256 * zp[1] + regs['y']) & 0xFFFF
                    owner = hot.symbols.classify_offset(defs, seglen, ip - base)
                    bucket = 'VM:' + (owner or 'runtime')
                    if owner in ('pass0', 'pass1', 'pass2'):
                        phase = owner
                    elif owner == 'run' and phase == 'pass2':
                        phase = 'finish'
                elif pc < 0xBF00:
                    owner = next((n for lo, hi, n in native if lo <= pc - base < hi), 'runtime/thunks')
                    bucket = 'native:' + owner
                if bucket != 'kernel/other':
                    pcs[pc] += 1
            hist[bucket] += 1
            phases[phase] += 1
            rows = pair.rig.screen_rows(client)
            if not pair.rig.bare_prompt(rows):
                started = True
            elif started:
                assert bank is not None, 'assembler bank never identified'
                break
        else:
            raise RuntimeError('sample limit reached')
        trace = None
        if tracepath:
            final = client.call_tool('softswitches', {})
            stopped = client.call_tool('trace_capture', {'action': 'stop'})
            assert stopped['count'] == elapsed, (stopped, elapsed)
            client.call_tool('trace_capture', {'action': 'dump', 'path': str(tracepath)})
            trace = (trace_analyzer or trace_counts)(tracepath, initial, final, bank, info)
            # Independent workload counts: lean-large contains 100 groups
            # of four instructions. These assertions also reject the wrong
            # same-row SYNC/address interpretation (which misses the thunks).
            if trace_analyzer is None:
                for name in ('VM:decidemode', 'native:mnlook', 'native:noteinst'):
                    assert trace['calls'][name] == 400, (name, trace['calls'])
                assert trace['calls']['VM:operandvalue'] == 300
                assert trace['calls']['VM:evalexpr'] == 514
                assert trace['calls_by_phase']['pass1']['VM:evalexpr'] == 207
                assert trace['calls_by_phase']['pass2']['VM:evalexpr'] == 307
                assert trace['calls']['native:commitinst'] == 401
        pair.rig.timed_command(client, 'echo CBSTATUS=$?\r', 'status', 1000)
        assert 'CBSTATUS=0' in pair.rig.screen_blob(pair.rig.screen_rows(client))
        pair.rig.timed_command(client, 'ls\r', 'flush', 1000)
    finally:
        client.close()
    volume = pair.prodos.mount(str(disk), readonly=True)
    try:
        entries = {e.name: e for e in pair.prodos.scandir(pair.DIRECTORY)}
        for output in ('COLD.O', 'WARM.O'):
            data = pair.prodos.read(f'{pair.DIRECTORY}/{output}')
            if object_metadata is None:
                pair.compare(data, expected)
                assert (entries[output].type, entries[output].aux_type) == (6, 0x2000 if tool == 'nas' else 0)
            else:
                assert {'sha256': pair.digest(data), 'bytes': len(data),
                        'type': entries[output].type,
                        'aux': entries[output].aux_type} == object_metadata
    finally:
        pair.prodos.unmount(volume)
    return dict(cold_cycles=cold, warm_cycles=elapsed, samples=sum(hist.values()),
                bank=bank, hist=dict(hist.most_common()), phases=dict(phases),
                trace=trace,
                pcs={f'{k:04X}': v for k, v in pcs.most_common()})


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--seed', type=int, default=618)
    ap.add_argument('--trace', action='store_true', help='count every NAS lean-large function entry via full bus trace')
    args = ap.parse_args()
    build = pair.ROOT / 'build'
    nas, assembler = (build / 'nas.cut').read_bytes(), (build / 'as.bin').read_bytes()
    astable = as_symbols(build, assembler)
    report = dict(seed=args.seed, method=__doc__, nas_sha256=pair.digest(nas),
                  as_sha256=pair.digest(assembler), cases=[],
                  image_sha256=pair.digest((build / 'profile.po').read_bytes()),
                  supervisor_sha256=pair.digest(Path(pair.rig.SUPERVISOR).read_bytes()))
    report['as_opcode_lookup_range'] = as_lookup_range(build, assembler)
    with tempfile.TemporaryDirectory(prefix='nas-paired-') as temp:
        tmp = Path(temp)
        for name in hot.ARTIFACTS:
            shutil.copyfile(build / name, tmp / name)
        info = hot.symbolize(tmp)
        template = tmp / 'template.po'
        shutil.copyfile(build / 'profile.po', template)
        volume = pair.prodos.mount(str(template))
        try:
            pair.prodos.mkdir(pair.DIRECTORY)
            for name, data in (('NAS', nas), ('ASX', assembler)):
                pair.prodos.write(f'{pair.DIRECTORY}/{name}', data, file_type=6, aux_type=0x800)
            for _, name, path in pair.FIXTURES:
                pair.prodos.write(f'{pair.DIRECTORY}/{name}', pair.convert.text_from_host(path.read_bytes()), file_type=4)
        finally:
            pair.prodos.unmount(volume)
        for case, name, path in pair.FIXTURES:
            expected = pair.merlin_oracle(path)
            row = dict(case=case, lines=pair.rig.count_lines(path),
                       source_sha256=pair.digest(path.read_bytes()), object_sha256=pair.digest(expected))
            for tool in ('as', 'nas'):
                disk = tmp / (case + tool + '.po')
                shutil.copyfile(template, disk)
                tracepath = tmp / 'trace.csv' if args.trace and case == 'lean-large' and tool == 'nas' else None
                row[tool] = run(disk, tool, name, expected, info, assembler, astable, args.seed, tracepath)
                print(json.dumps(dict(case=case, tool=tool, **{k: v for k, v in row[tool].items() if k != 'pcs'})), flush=True)
            report['cases'].append(row)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print('PASS: all 16 cold/warm outputs match fresh merlin32 bytes and per-tool metadata')


if __name__ == '__main__':
    main()
