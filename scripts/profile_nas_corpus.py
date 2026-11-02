#!/usr/bin/env python3
"""Measure cooked nas on fixed real REL inputs and three local-label sizes.

Use an existing nas-selfmake image as the source corpus. Each case gets an
isolated image copy and a cold/warm assembly pair. --compare checks exact
object bytes (SHA256), type and code length against a previous run on the
SAME image. This is a regression comparison; check-nas-selfmake supplies the
independent merlin32 linked-output oracle. No performance pass threshold.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

import profile_nas_vs_as as rig

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos, convert
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = Path(__file__).resolve().parents[1]
REAL_CASES = ('ECHOM.S', 'SYSCALLSRL.S', 'GREPM.S', 'VIM.S', 'SHM.S')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def stage(image, executable):
    volume = prodos.mount(str(image))
    try:
        prodos.write('/bin/NAS', executable, file_type=6,
                     aux_type=0x0800, overwrite=True)
        prodos.mkdir('/mnt/MAUX/NPRF')
        cases = [(name, '/tmp/LR/' + name) for name in REAL_CASES]
        for count in (16, 64, 128):
            name = f'LOC{count}'
            lines = [' org $2000', 'ROOT nop']
            for i in range(count):
                lines.extend((f':L{i:03d} lda #1', f' bne :L{i:03d}'))
            path = '/mnt/MAUX/NPRF/' + name + '.S'
            prodos.write(path, convert.text_from_host(
                ('\n'.join(lines) + '\n').encode('ascii')), file_type=4)
            cases.append((name, path))
        # Fail before starting an emulator if the supplied image is unsuitable.
        for _, path in cases:
            prodos.read(path)
        return cases
    finally:
        prodos.unmount(volume)


def run_case(image, name, source):
    rig.DISK = str(image)
    client = rig.boot_client()
    times = {}
    try:
        for run in ('COLD', 'WARM'):
            output = '/mnt/MAUX/NPRF/' + run + '.O'
            command = f'/bin/NAS -o {output} {source}\r'
            times[run.lower()] = rig.timed_command(
                client, command, name + '-' + run, 10000)
            rows = rig.screen_blob(rig.screen_rows(client))
            if ' bytes ->' not in rows or 'failed' in rows or 'out of memory' in rows:
                raise RuntimeError(f'{name}/{run}: assembly failed:\n{rows}')
        rig.timed_command(client, 'ls /mnt/MAUX/NPRF\r', name + '-flush', 2000)
    finally:
        client.close()
    volume = prodos.mount(str(image), readonly=True)
    try:
        result = []
        for run in ('COLD', 'WARM'):
            path = '/mnt/MAUX/NPRF/' + run + '.O'
            data = prodos.read(path)
            if name.startswith('LOC'):
                # Independent instruction oracle: NOP, then LDA #1 and
                # BNE four bytes backwards. No assembler lookup logic.
                expected = b'\xEA' + b'\xA9\x01\xD0\xFC' * int(name[3:])
                if data != expected:
                    raise RuntimeError(f'{name}: fixed-instruction oracle mismatch')
            entry = next(e for e in prodos.scandir('/mnt/MAUX/NPRF')
                         if e.name == run + '.O')
            result.append({'sha256': digest(data), 'bytes': len(data),
                           'type': entry.type, 'aux': entry.aux_type})
        if result[0] != result[1]:
            raise RuntimeError(f'{name}: cold/warm object mismatch')
        return {'case': name, 'source': source, 'cycles': times,
                'object': result[0]}
    finally:
        prodos.unmount(volume)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', type=Path,
                        default=ROOT/'build/nas-selfmake.po')
    parser.add_argument('--nas', type=Path, default=ROOT/'build/nas.cut')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--compare', type=Path)
    args = parser.parse_args()
    executable = args.nas.read_bytes()
    old = json.loads(args.compare.read_text()) if args.compare else None
    image_hash = digest(args.image.read_bytes())
    if old and old['image_sha256'] != image_hash:
        raise RuntimeError('comparison requires the identical staged source image')
    report = {'image_sha256': image_hash, 'nas_sha256': digest(executable),
              'nas_bytes': len(executable),
              'heap_bytes': 0xBF00 - 0x0800 - len(executable),
              'method': 'fast emulator; cold/warm prompt intervals; 50k-cycle polls',
              'cases': []}
    with tempfile.TemporaryDirectory(prefix='maux-nas-corpus-') as temp:
        template = Path(temp)/'template.po'
        shutil.copyfile(args.image, template)
        cases = stage(template, executable)
        for name, source in cases:
            disk = Path(temp)/(name+'.po')
            shutil.copyfile(template, disk)
            result = run_case(disk, name, source)
            if old:
                previous = next(c for c in old['cases'] if c['case'] == name)
                if result['object'] != previous['object']:
                    raise RuntimeError(f'{name}: object differs from baseline')
                result['warm_speedup'] = (previous['cycles']['warm'] /
                                          result['cycles']['warm'])
            report['cases'].append(result)
            print(json.dumps(result), flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2)+'\n')
    print(f'PASS: {len(report["cases"])} cold/warm pairs; '
          f'cooked {len(executable)} B, heap {report["heap_bytes"]} B')


if __name__ == '__main__':
    main()
