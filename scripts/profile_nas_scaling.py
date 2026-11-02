#!/usr/bin/env python3
"""Measure preserved/current cooked NAS and AS over five fixture sizes.

Extends the existing lean/symbol fixture blocks without changing their
semantics. Each tool/size has an isolated boot and immediate cold/warm
pair; both objects must match fresh merlin32 bytes and tool metadata.
No source or binary under test is modified. Fast-emulator cycles only.
"""
import argparse
import json
from pathlib import Path
import shutil
import tempfile

import profile_nas_cooked_vs_as as pair

COUNTS = (10, 25, 50, 100, 150)


def fixture(template, kind, count):
    first = 'START       ' if kind == 'lean' else 'L0001       '
    head = template[:template.index(first)]
    tail = template[template.index('*\n* ---- data section'):]
    lines = []
    for i in range(1, count + 1):
        if kind == 'lean':
            label = 'START       ' if i == 1 else '            '
            lines += [label + 'lda   #$01', '            sta   $10',
                      '            inc   $11', '            nop']
        else:
            lines += [f'L{i:04d}       lda   #$01', '            sta   $10',
                      '            dex', f'            bne   L{i:04d}']
    return head + '\n'.join(lines) + '\n' + tail


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline', type=Path, required=True)
    ap.add_argument('--nas', type=Path, default=pair.ROOT/'build/nas.cut')
    ap.add_argument('--as-bin', type=Path, default=pair.ROOT/'build/as.bin')
    ap.add_argument('--image', type=Path, default=pair.ROOT/'build/profile.po')
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    if args.output.exists():
        raise SystemExit('Refusing to overwrite an existing measurement')
    binaries = {name: path.read_bytes() for name, path in
                (('baseline', args.baseline), ('current', args.nas), ('as', args.as_bin))}
    for name in ('baseline', 'current'):
        assert binaries[name][9:12] == b'CK\x01', name
    templates = {'lean': Path(pair.rig.LEAN_SMALL_SRC).read_text(),
                 'symbols': Path(pair.rig.SMALL_SRC).read_text()}
    # At the existing size, the generator must reproduce the actual fixture.
    for kind, text in templates.items():
        assert fixture(text, kind, 10) == text, kind
    report = {'method': __doc__, 'poll_quantum': 50000,
              'image_sha256': pair.digest(args.image.read_bytes()),
              'supervisor_sha256': pair.digest(Path(pair.rig.SUPERVISOR).read_bytes()),
              'artifacts': {name: {'sha256': pair.digest(data), 'bytes': len(data)}
                            for name, data in binaries.items()}, 'cases': []}
    with tempfile.TemporaryDirectory(prefix='nas-scaling-') as td:
        tmp = Path(td)
        for kind, template in templates.items():
            for count in COUNTS:
                text = fixture(template, kind, count)
                src = tmp/'CURVE.S'
                src.write_text(text)
                expected = pair.merlin_oracle(src)
                block = bytes.fromhex('a9018510e611ea' if kind == 'lean' else 'a9018510cad0f9')
                assert expected[:count*7] == block*count
                row = {'family': kind, 'blocks': count, 'instructions': 4*count,
                       'source_lines': len(text.splitlines()), 'source_bytes': len(text),
                       'source_sha256': pair.digest(text.encode()), 'tools': {}}
                for name, binary in binaries.items():
                    disk = tmp/f'{kind}-{count}-{name}.po'
                    shutil.copyfile(args.image, disk)
                    volume = pair.prodos.mount(str(disk))
                    try:
                        pair.prodos.mkdir(pair.DIRECTORY)
                        leaf = 'ASX' if name == 'as' else 'NAS'
                        pair.prodos.write(pair.DIRECTORY+'/'+leaf, binary, file_type=6, aux_type=0x800)
                        assert pair.prodos.read(pair.DIRECTORY+'/'+leaf) == binary
                        pair.prodos.write(pair.DIRECTORY+'/CURVE.S',
                                          pair.convert.text_from_host(text.encode()), file_type=4)
                    finally:
                        pair.prodos.unmount(volume)
                    row['tools'][name] = pair.run(disk, 'as' if name == 'as' else 'nas',
                                                  pair.DIRECTORY+'/CURVE.S', expected)
                    print(json.dumps({'family': kind, 'blocks': count, 'tool': name,
                                      **row['tools'][name]}), flush=True)
                report['cases'].append(row)
                args.output.write_text(json.dumps(report, indent=2)+'\n')
    report['adjacent_cycles_per_instruction'] = []
    for kind in templates:
        rows = [r for r in report['cases'] if r['family'] == kind]
        for small, large in zip(rows, rows[1:]):
            delta = large['instructions'] - small['instructions']
            report['adjacent_cycles_per_instruction'].append({
                'family': kind, 'from': small['instructions'], 'to': large['instructions'],
                'rates': {name: {phase: (large['tools'][name]['cycles'][phase] -
                           small['tools'][name]['cycles'][phase]) / delta
                           for phase in ('cold', 'warm')} for name in binaries}})
    args.output.write_text(json.dumps(report, indent=2)+'\n')
    print('PASS: 60 cold/warm outputs, five sizes, three tools, fresh merlin32 and literal-block oracles')


if __name__ == '__main__':
    main()
