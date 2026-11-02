#!/usr/bin/env python3
"""Compare deployed cooked NAS with AS, cold and immediate warm, on one disk.

Each tool/fixture pair boots a fresh private image; both outputs must equal
a fresh independent merlin32 reference. Metadata is checked against each
tool's existing contract: AS writes BIN/aux=0; NAS writes BIN/aux=ORG.
Reuses the existing profile timer, boot rig and fixtures. No assembler edits.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile

import profile_nas_vs_as as rig
from check_nas_boundary import merlin_oracle, compare
from profile_nas_corpus import prodos, convert

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = '/mnt/MAUX/CBENCH'
FIXTURES = (
    ('symbols-small', 'SMALL.S', Path(rig.SMALL_SRC)),
    ('symbols-large', 'LARGE.S', Path(rig.LARGE_SRC)),
    ('lean-small', 'LSMALL.S', Path(rig.LEAN_SMALL_SRC)),
    ('lean-large', 'LLARGE.S', Path(rig.LEAN_LARGE_SRC)),
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def command(tool, source, output):
    # Equal-length executable aliases/paths and argument strings. Only the
    # argument order differs, preserving each assembler's established CLI.
    binary = 'NAS' if tool == 'nas' else 'ASX'
    operands = f'-o {output} {source}' if tool == 'nas' else f'{source} -o {output}'
    return f'{DIRECTORY}/{binary} {operands}\r'


def run(disk, tool, source, expected):
    rig.DISK = str(disk)
    client = rig.boot_client()
    times = {}
    commands = {}
    try:
        for phase in ('cold', 'warm'):
            output = f'{DIRECTORY}/{phase.upper()}.O'
            cmd = command(tool, source, output)
            assert len(cmd) == len(command('as' if tool == 'nas' else 'nas',
                                           source, output))
            commands[phase] = cmd.rstrip('\r')
            times[phase] = rig.timed_command(client, cmd, tool + '-' + phase,
                                             rig.MAX_CHUNKS_AS)
            # No intervening process before warm. Distinct, initially absent
            # output files plus the byte oracle below validate BOTH runs.
        rig.timed_command(client, 'echo CBSTATUS=$?\r', 'status', 1000)
        if 'CBSTATUS=0' not in rig.screen_blob(rig.screen_rows(client)):
            raise AssertionError('nonzero/missing final status')
        rig.timed_command(client, 'ls\r', 'flush', 1000)
    finally:
        client.close()
    volume = prodos.mount(str(disk), readonly=True)
    try:
        entries = {entry.name: entry for entry in prodos.scandir(DIRECTORY)}
        for phase in ('COLD', 'WARM'):
            name = phase + '.O'
            actual = prodos.read(f'{DIRECTORY}/{name}')
            compare(actual, expected)
            assert (entries[name].type, entries[name].aux_type) == (
                6, 0x2000 if tool == 'nas' else 0), (
                tool, phase, entries[name].type, entries[name].aux_type)
    finally:
        prodos.unmount(volume)
    return {'cycles': times, 'commands': commands,
            'object_bytes': len(expected), 'object_sha256': digest(expected),
            'object_type': 6, 'object_aux': 0x2000 if tool == 'nas' else 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', type=Path, default=ROOT / 'build/profile.po')
    parser.add_argument('--nas', type=Path, default=ROOT / 'build/nas.cut')
    parser.add_argument('--as-bin', type=Path, default=ROOT / 'build/as.bin')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    nas, assembler = args.nas.read_bytes(), args.as_bin.read_bytes()
    assert nas[9:12] == b'CK\x01', 'not a cooked NAS image'
    report = {'method': 'fast emulator; 50k-cycle prompt polls; fresh boot per '
                       'tool/fixture, then immediate warm with distinct output',
              'image_sha256': digest(args.image.read_bytes()),
              'nas_sha256': digest(nas), 'nas_bytes': len(nas),
              'as_sha256': digest(assembler), 'as_bytes': len(assembler),
              'supervisor_sha256': digest(Path(rig.SUPERVISOR).read_bytes()),
              'cases': [], 'slopes': {}}
    with tempfile.TemporaryDirectory(prefix='nas-cooked-comparison-') as tmp:
        template = Path(tmp) / 'template.po'
        shutil.copyfile(args.image, template)
        volume = prodos.mount(str(template))
        try:
            prodos.mkdir(DIRECTORY)
            for name, data in (('NAS', nas), ('ASX', assembler)):
                prodos.write(f'{DIRECTORY}/{name}', data, file_type=6, aux_type=0x800)
                assert prodos.read(f'{DIRECTORY}/{name}') == data
            for _, name, path in FIXTURES:
                prodos.write(f'{DIRECTORY}/{name}',
                             convert.text_from_host(path.read_bytes()), file_type=4)
            assert not {'COLD.O', 'WARM.O'} & {
                entry.name for entry in prodos.scandir(DIRECTORY)}
        finally:
            prodos.unmount(volume)
        for case, name, source in FIXTURES:
            expected = merlin_oracle(source)
            row = {'case': case, 'lines': rig.count_lines(source),
                   'source_sha256': digest(source.read_bytes())}
            for tool in ('as', 'nas'):
                disk = Path(tmp) / (case + '-' + tool + '.po')
                shutil.copyfile(template, disk)
                row[tool] = run(disk, tool, f'{DIRECTORY}/{name}', expected)
                print(json.dumps({'case': case, 'tool': tool, **row[tool]}), flush=True)
            report['cases'].append(row)
    for group in ('symbols', 'lean'):
        small, large = [row for row in report['cases'] if row['case'].startswith(group)]
        delta = large['lines'] - small['lines']
        report['slopes'][group] = {}
        for phase in ('cold', 'warm'):
            values = {tool: (large[tool]['cycles'][phase] - small[tool]['cycles'][phase])
                      / delta for tool in ('as', 'nas')}
            values['nas_over_as'] = values['nas'] / values['as']
            report['slopes'][group][phase] = values
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report['slopes'], indent=2))
    print('PASS: 16 cold/warm objects match fresh merlin32; per-tool metadata valid')


if __name__ == '__main__':
    main()
