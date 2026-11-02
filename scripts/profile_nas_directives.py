#!/usr/bin/env python3
"""Compare explicit NAS binaries on STR/HEX loops with literal byte oracles.

Uses private copies of the existing corpus image, not a new image builder.
All results are fast-emulator prompt timings, not physical-hardware timings.
"""
import argparse
import json
from pathlib import Path
import shutil
import tempfile

from profile_nas_corpus import digest, prodos, convert, run_case


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', type=Path, required=True)
    parser.add_argument('--nas', type=Path, nargs='+', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = {'image_sha256': digest(args.image.read_bytes()), 'runs': []}
    cases = (
        ('STR', b' str "AB,CD",\'ef\',$12\n',
         bytes.fromhex('08 c1 c2 ac c3 c4 65 66 12')),
        ('HEX', b' hex 0123,456789,abCDef\n',
         bytes.fromhex('01 23 45 67 89 ab cd ef')),
    )
    with tempfile.TemporaryDirectory(prefix='nas-directives-') as tmp:
        for executable in args.nas:
            code = executable.read_bytes()
            for name, line, emitted in cases:
                disk = Path(tmp) / (executable.stem + '-' + name + '.po')
                shutil.copyfile(args.image, disk)
                source = b' org $2000\n' + line * 150 + b' rts\n'
                expected = emitted * 150 + b'\x60'
                volume = prodos.mount(str(disk))
                try:
                    prodos.write('/bin/NAS', code, file_type=6,
                                 aux_type=0x800, overwrite=True)
                    prodos.mkdir('/mnt/MAUX/NPRF')
                    prodos.write('/mnt/MAUX/NPRF/DIRECT.S',
                                 convert.text_from_host(source), file_type=4)
                finally:
                    prodos.unmount(volume)
                result = run_case(disk, name, '/mnt/MAUX/NPRF/DIRECT.S')
                assert result['object'] == {
                    'sha256': digest(expected), 'bytes': len(expected),
                    'type': 6, 'aux': 0x2000}, result
                result.update(nas=str(executable), nas_sha256=digest(code))
                report['runs'].append(result)
                print(json.dumps(result), flush=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print('PASS: every cold/warm STR/HEX object matches literal byte oracle')


if __name__ == '__main__':
    main()
