#!/usr/bin/env python3
r"""Sample cold cooked nas on GREPM.S and SYSCALLSRL.S without changing inputs.

Example (build artifacts must all describe the same nas):
  python3 scripts/profile_nas_hotspots.py --build-dir build \
      --image build/nas-selfmake.po --output build/nas-hotspots.json

--compare accepts profile_nas_corpus.py JSON from the identical source image.
It checks object hashes/type/code length, not performance. Sampling starts at
the first observed pass0/pass1/pass2 VM instruction and ends at the shell
prompt. Native code is classified by PC before consulting the VM's IP/Y.
IP attribution during VM pointer transitions remains approximate. This is a
fast-emulator diagnostic, not a hardware timing claim or linked-byte oracle.
"""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import tempfile

import plascut
import profile_f2 as symbols
import profile_nas_vs_as as rig
from textaudit import load_syms

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = Path(__file__).resolve().parents[1]
CASES = ('GREPM.S', 'SYSCALLSRL.S')
ARTIFACTS = ('nas.cut', 'nas.mod', 'nas.a', 'plasma.bin',
             'plasma.bin_Output.txt', 'rt.mod', 'args.mod', 'fileio.mod')
LOAD = 0x0800
JITTER = (3500, 8500)  # Upper bound exclusive.


def digest(data):
    return hashlib.sha256(data).hexdigest()


def native_ranges(report, defs):
    """Keep the LAST label before emitted bytes; zero-byte aliases own none."""
    starts = {}
    pending = None
    for line in report.splitlines():
        label = re.search(r'\s_A\d+\s*;\s*(\w+)\(\)', line)
        if label:
            pending = label[1]
        emitted = re.match(r'\s*\d+\s+([0-9a-f]{4})\s+[0-9a-f]+\s', line)
        if pending and emitted:
            starts[int(emitted[1], 16) - 0x2000] = pending
            pending = None
    ordered = sorted(starts)
    ranges = [(lo, ordered[i + 1] if i + 1 < len(ordered) else defs[0][0],
               starts[lo]) for i, lo in enumerate(ordered)]
    if not ranges or any(lo >= hi for lo, hi, _ in ranges):
        raise RuntimeError('invalid or empty native function ranges')
    return ranges


def validate_vm(snapshot, cooked):
    listing = snapshot / 'plasma.bin_Output.txt'
    vm = load_syms(str(listing), names=('DINTRP', 'START', 'NEXTOP', 'IPL', 'IPH'))
    seed = (snapshot / 'plasma.bin').read_bytes()
    if not LOAD <= vm['DINTRP'] < vm['START'] <= LOAD + len(seed):
        raise RuntimeError('VM symbol range is outside plasma.bin')
    if (vm['NEXTOP'], vm['IPL'], vm['IPH']) != (0xF0, 0xF2, 0xF3):
        raise RuntimeError('unsupported VM zero-page IP layout')
    covered = set()
    continuation = None
    for line in listing.read_text().splitlines():
        match = re.search(r'\|\s*00/([0-9A-F]{4}) : ([0-9A-F ]+)\|', line)
        tail = re.search(r'\|\s+((?:[0-9A-F]{2}\s+)+)\|$', line)
        if match:
            addr = int(match[1], 16)
            data = bytes.fromhex(match[2])
        elif continuation is not None and tail:
            addr = continuation
            data = bytes.fromhex(tail[1])
        else:
            continuation = None
            continue
        continuation = addr + len(data)
        for offset, byte in enumerate(data):
            at = addr + offset
            if vm['DINTRP'] <= at < vm['START']:
                if seed[at - LOAD] != byte or cooked[at - LOAD] != byte:
                    raise RuntimeError(f'VM listing/seed/cooked mismatch at ${at:04X}')
                covered.add(at)
    if len(covered) != vm['START'] - vm['DINTRP']:
        raise RuntimeError('VM listing does not cover the complete interpreter')
    # Bind named entry points to their listing rows as well as the symbol table.
    for name in ('DINTRP', 'START'):
        pattern = rf'00/{vm[name]:04X} :[^|]+\|\s*{name}\s'
        if not re.search(pattern, listing.read_text()):
            raise RuntimeError(f'{name} symbol disagrees with its listing row')
    return vm


def symbolize(snapshot):
    # Existing helper writes an ACME report and binary; redirect BOTH to temp.
    symbols.NAS_A = str(snapshot / 'nas.a')
    symbols.NAS_MOD = str(snapshot / 'nas.mod')
    symbols.NAS_REPORT = str(snapshot / 'nas.report')
    symbols.NAS_REPORT_MOD_SCRATCH = str(snapshot / 'assembled.mod')
    defs, seglen = symbols.build_def_table()
    module = (snapshot / 'nas.mod').read_bytes()
    if (snapshot / 'assembled.mod').read_bytes() != module:
        raise RuntimeError('nas.a does not assemble to the supplied nas.mod')
    if not defs or seglen != int.from_bytes(module[:2], 'little'):
        raise RuntimeError('def table disagrees with module length')
    cooked = (snapshot / 'nas.cut').read_bytes()
    vm = validate_vm(snapshot, cooked)
    # Reconstruct relocated resident bytes, without finish() or restore copies.
    # This works with either restore policy: neither changes resident placement.
    img = plascut.Image((snapshot / 'plasma.bin').read_bytes(),
                        (snapshot / 'rt.mod').read_bytes())
    cooker = plascut.Cooker(img, [str(snapshot)])
    cooker.const_prefix = set()
    cooker.loadmod('NAS')
    for name, _, deftbl, _, _, end, *_ in cooker.loaded:
        if cooked[deftbl - LOAD:end - LOAD] != bytes(img.buf[deftbl - LOAD:end - LOAD]):
            raise RuntimeError(f'cooked {name} bytes disagree with the supplied modules')
    nas = next(row for row in cooker.loaded if row[0] == 'NAS')
    base = nas[4] - (int.from_bytes(module[6:8], 'little') - 0x2000)
    matches = []
    for name, off, signature in symbols.build_signatures(defs):
        at = cooked.find(signature)
        if at < 0:  # A candidate with relocations is not position-independent.
            continue
        if cooked.find(signature, at + 1) >= 0 or LOAD + at - off != base:
            raise RuntimeError(f'ambiguous/inconsistent cooked signature: {name}')
        matches.append((name, off, signature))
    if len(matches) < 2:
        raise RuntimeError('fewer than two independent cooked signatures match')
    # Macro-led functions start before the first non-macro report row.
    # Use actual ACME labels, bound to a byte-identical module.
    labels = snapshot / 'native-labels.txt'
    checked = snapshot / 'native-labels.mod'
    subprocess.run(['acme', '--setpc', '8190', '-l', str(labels),
                    '-o', str(checked), str(snapshot / 'nas.a')], check=True)
    if checked.read_bytes() != module:
        raise RuntimeError('native-label reassembly differs from nas.mod')
    syms = {k: int(v, 16) for k, v in re.findall(
        r'(\w+)\s*=\s*\$([0-9a-fA-F]+)', labels.read_text())}
    starts = {syms[label] - 0x2000: name for label, name in re.findall(
        r'^(_A\d+)\s+;\s*(\w+)\(\)', (snapshot / 'nas.a').read_text(), re.M)}
    ordered = sorted(starts)
    native = [(lo, ordered[i+1] if i+1 < len(ordered) else defs[0][0], starts[lo])
              for i, lo in enumerate(ordered)]
    if not native or any(lo >= hi for lo, hi, _ in native):
        raise RuntimeError('invalid native label ranges')
    return cooked, defs, seglen, native, vm, base, matches


def stage(template, cooked, cases=CASES):
    volume = prodos.mount(str(template))
    try:
        # These fixed sources and their EQU includes must be present before boot.
        sources = {name: digest(prodos.read('/tmp/LR/' + name)) for name in
                   (*cases, 'GREPMQ.S', 'SYSCALLSQ.S')}
        # Refuse collisions: no stale objects may satisfy post-run checks.
        prodos.mkdir('/mnt/MAUX/NHSP')
        prodos.write('/mnt/MAUX/NHSP/NAS', cooked, file_type=6, aux_type=LOAD)
    finally:
        prodos.unmount(volume)
    return sources


def sample_case(disk, name, info, seed, max_samples):
    cooked, defs, seglen, native, vm, base, signatures = info
    rig.DISK = str(disk)
    client = rig.boot_client()
    hist, vm_pc, raw_ip = Counter(), Counter(), Counter()
    rng = random.Random(seed)
    bank = None
    begun = None
    elapsed = 0
    saw_command = False
    success = False
    try:
        client.call_tool('type', {'text':
            f'/mnt/MAUX/NHSP/NAS -o /mnt/MAUX/NHSP/OUT.O /tmp/LR/{name}\r'})
        for i in range(max_samples):
            step = rng.randrange(*JITTER)
            client.call_tool('step', {'cycles': step})
            elapsed += step
            sw = client.call_tool('softswitches', {})
            regs = client.call_tool('regs', {})
            pc = regs['pc']
            live = sw['ramworks_bank']
            on_aux = live and sw['RAMRD'] and sw['ALTZP'] and pc < 0xBF00
            if bank is None and on_aux:
                # Check every signature in the live physical bank, without
                # advancing the CPU between probes. No PID==bank assumption.
                if all(bytes(client.call_tool('peek', {
                        'addr': base + off, 'count': len(sig), 'bank': 'aux',
                        'aux_bank': live})['bytes']) == sig
                       for _, off, sig in signatures):
                    bank = live
            ip = None
            if not on_aux or live != bank:
                bucket = 'kernel/other'
            elif vm['DINTRP'] <= pc < vm['START'] or 0xEF <= pc <= 0xF8:
                zp = client.call_tool('peek', {'addr': vm['IPL'], 'count': 2,
                    'bank': 'aux', 'aux_bank': bank})['bytes']
                ip = (zp[0] + 256 * zp[1] + regs['y']) & 0xFFFF
                owner = symbols.classify_offset(defs, seglen, ip - base)
                bucket = 'VM:' + (owner or 'runtime')
                if begun is None and owner in ('pass0', 'pass1', 'pass2'):
                    begun = elapsed
            else:
                owner = next((n for lo, hi, n in native if lo <= pc - base < hi),
                             'runtime/thunks')
                if 0x70 <= pc < 0x8E and any(n == 'initloop' for _, _, n in native):
                    owner = 'call-gates'
                bucket = 'native:' + owner
            if begun is not None:
                hist[bucket] += 1
                if ip is not None:
                    vm_pc[pc] += 1
                    raw_ip[ip] += 1
            # Poll every sample: exclude an unbounded post-assembly shell tail.
            rows = rig.screen_rows(client)
            text = rig.screen_blob(rows)
            success |= ' bytes -> ' in text
            if not rig.bare_prompt(rows):
                saw_command = True
            elif saw_command:
                if begun is None or bank is None or not success:
                    raise RuntimeError(f'{name}: no successful sampled assembly:\n{text}')
                break
        else:
            raise RuntimeError(f'{name}: exceeded {max_samples} samples')
        rig.timed_command(client, 'ls /mnt/MAUX/NHSP\r', name + '-flush', 2000)
    finally:
        client.close()
    volume = prodos.mount(str(disk), readonly=True)
    try:
        data = prodos.read('/mnt/MAUX/NHSP/OUT.O')
        entry = prodos.stat('/mnt/MAUX/NHSP/OUT.O')
        if not data or entry.type != 0xF8 or not 0 < entry.aux_type < len(data):
            raise RuntimeError(f'{name}: missing, empty or invalid REL object')
        obj = {'sha256': digest(data), 'bytes': len(data), 'type': entry.type,
               'aux': entry.aux_type}
    finally:
        prodos.unmount(volume)
    return {'case': name, 'source': '/tmp/LR/' + name, 'bank': bank,
            'samples': sum(hist.values()), 'command_cycles': elapsed,
            'first_pass_cycle': begun, 'sampled_cycles': elapsed - begun,
            'hist': dict(hist.most_common()), 'vm_pc': dict(sorted(vm_pc.items())),
            'raw_ip': dict(sorted(raw_ip.items())), 'object': obj}


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--build-dir', type=Path, default=ROOT / 'build',
                        help='matching nas.cut/mod/a, plasma.bin/listing, rt/args/fileio.mod')
    parser.add_argument('--image', type=Path, default=ROOT / 'build/nas-selfmake.po',
                        help='read-only source template; only temporary copies are mounted')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--compare', type=Path, help='expected profile_nas_corpus.py JSON')
    parser.add_argument('--seed', type=int, default=618)
    parser.add_argument('--max-samples', type=int, default=100000)
    parser.add_argument('--cases', nargs='+', default=CASES,
                        help='source leaves under /tmp/LR in the frozen image')
    args = parser.parse_args()
    inputs = [args.build_dir / name for name in ARTIFACTS] + [args.image]
    if args.compare:
        inputs.append(args.compare)
    if args.output.resolve() in {path.resolve() for path in inputs}:
        raise RuntimeError('--output must not overwrite an input')
    if args.max_samples <= 0:
        raise RuntimeError('--max-samples must be positive')
    expected = json.loads(args.compare.read_text()) if args.compare else None
    with tempfile.TemporaryDirectory(prefix='maux-nas-hotspots-') as tmp:
        temp = Path(tmp)
        snapshot = temp / 'build'
        snapshot.mkdir()
        hashes = {}
        for name in ARTIFACTS:
            data = (args.build_dir / name).read_bytes()
            hashes[name] = digest(data)
            (snapshot / name).write_bytes(data)
        info = symbolize(snapshot)
        template = temp / 'template.po'
        shutil.copyfile(args.image, template)
        image_hash = digest(template.read_bytes())
        if expected and expected['image_sha256'] != image_hash:
            raise RuntimeError('--compare requires the identical source image')
        sources = stage(template, info[0], args.cases)
        staged_hash = digest(template.read_bytes())
        report = {'image_sha256': image_hash, 'artifacts': hashes,
                  'source_sha256': sources, 'seed': args.seed,
                  'jitter_cycles': {'min': JITTER[0], 'max_exclusive': JITTER[1]},
                  'method': 'cold; first observed assembly pass to prompt; PC before IP',
                  'backend': 'fast',
                  'supervisor_sha256': digest(Path(rig.SUPERVISOR).read_bytes()),
                  'limitations': 'fast emulator; approximate IP/Y transition attribution; '
                                 'kernel/other includes other processes and prompt return',
                  'load_base': info[5], 'vm': info[4],
                  'signatures': [{'name': name, 'offset': off, 'bytes': len(sig),
                                  'sha256': digest(sig)}
                                 for name, off, sig in info[6]],
                  'native_ranges': info[3], 'bytecode_ranges': info[1],
                  'object_comparison': str(args.compare) if args.compare else None,
                  'cases': []}
        for name in args.cases:
            disk = temp / (name + '.po')
            shutil.copyfile(template, disk)
            result = sample_case(disk, name, info, args.seed, args.max_samples)
            if expected:
                previous = next(c for c in expected['cases'] if c['case'] == name)
                if result['object'] != previous['object']:
                    raise RuntimeError(f'{name}: object differs from expected corpus')
            report['cases'].append(result)
            print(json.dumps({k: v for k, v in result.items()
                              if k not in ('vm_pc', 'raw_ip')}), flush=True)
        if digest(template.read_bytes()) != staged_hash:
            raise RuntimeError('staged template changed during sampling')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f'PASS: {len(report["cases"])} cold profiles -> {args.output}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
