#!/usr/bin/env python3
"""Check nas local-name boundaries not covered by the Merlin dialect gate.

Run after make nas-image. Names over 13 bytes deliberately exercise nas's
existing significance rule, so literal address bytes are the independent
oracle here. check-nas's local.s separately compares hash collisions and
cross-zone/case behavior with merlin32. --module permits a baseline module.
An orphan ambiguous name must stay unresolved. It used to be emitted as
a zero JMP operand with exit 0; since KFIX10 item 1 an undefined symbol is
an error (merlin32 rejects this very case too, learning 01M0VJF2DXZR55HG
case 3), so that row now requires the diagnostic and a failed pass 2.
Each case uses a fresh copy of nas.po inside this worktree's build directory.
"""
import argparse
import os
from pathlib import Path
import shutil
import sys
import tempfile

import profile_nas_vs_as as rig

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import convert, prodos
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = Path(__file__).resolve().parents[1]
CASES = (
    ('long-unique', ''' org $2000
FIRST nop
:ABCDEFGHIJKLfirst dfb $11
SECOND nop
 da :ABCDEFGHIJKLother
''', bytes.fromhex('ea11ea0120')),
    ('long-ambiguous', ''' org $2000
FIRST nop
:ABCDEFGHIJKLfirst dfb $11
 da :ABCDEFGHIJKLother
SECOND nop
:ABCDEFGHIJKLsecond dfb $22
 da :ABCDEFGHIJKLthird
''', bytes.fromhex('ea110120ea220520')),
    ('orphan-ambiguous', ''' org $2000
FIRST nop
:repeat nop
SECOND nop
:repeat nop
THIRD nop
 jmp :repeat
''', None),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', type=Path, default=ROOT/'build/nas.po')
    parser.add_argument('--module', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='nas-locals-',
                                     dir=ROOT/'build') as temp:
        for name, source, expected in CASES:
            disk = Path(temp)/(name + '.po')
            shutil.copyfile(args.image, disk)
            volume = prodos.mount(str(disk))
            try:
                prodos.write('/mnt/MAUX/PLLIB/BOUND.S', convert.text_from_host(
                    source.encode('ascii')), file_type=4, overwrite=True)
                if args.module:
                    prodos.write('/mnt/MAUX/PLLIB/NAS', args.module.read_bytes(),
                                 file_type=0xFE, overwrite=True)
            finally:
                prodos.unmount(volume)
            rig.DISK = str(disk)
            client = rig.boot_client()
            try:
                rig.timed_command(client, 'cd /mnt/MAUX/pllib\r', name, 2000)
                rig.timed_command(client, 'plasma NAS -o BOUND.O BOUND.S\r',
                                  name, 10000)
                rig.timed_command(client, 'echo LX=$?\r', name, 2000)
                rows = rig.screen_blob(rig.screen_rows(client))
                if expected is None:
                    # the inverted row: an unknown label and a failed
                    # pass 2. `plasma NAS` (the module form this gate
                    # drives) reports $?=0 on a failure whatever nas
                    # returns, so the exit status is NOT asserted here;
                    # check-nas-text pins exit 1 on the cooked binary.
                    # The console is 40 columns: rejoin the wrapped row.
                    flat = ''.join(r.rstrip() for r in rows.split('\n'))
                    if ('unknown label :repeat (BOUND.S line 7)'
                            not in flat or 'pass 2 failed' not in flat):
                        raise AssertionError(f'{name}: wanted the '
                                             f'diagnostic\n{rows}')
                elif 'LX=0' not in rows:
                    raise AssertionError(f'{name}: wanted LX=0\n{rows}')
                rig.timed_command(client, 'ls\r', name, 2000)
            finally:
                client.close()
            if expected is None:
                print(f'PASS: {name} (unknown label, pass 2 failed)', flush=True)
                continue
            volume = prodos.mount(str(disk), readonly=True)
            try:
                actual = prodos.read('/mnt/MAUX/PLLIB/BOUND.O')
            finally:
                prodos.unmount(volume)
            if actual != expected:
                raise AssertionError(f'{name}: {actual.hex()} != '
                                     f'{expected.hex()}')
            print(f'PASS: {name}', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
