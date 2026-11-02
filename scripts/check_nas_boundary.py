#!/usr/bin/env python3
"""Focused NAS boundary/differential check.

Run after ``make nas-image``.  The positive fixture is compared byte-for-byte
with a fresh merlin32 assembly in a temporary directory.  Boundary and
forward-small inputs deliberately share one boot with an intervening no-XC
failure, exercising different warm inputs and recovery. Each failure produces a new NAS
diagnostic before its unique non-zero exit marker is accepted.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_plascut import (MCPClient, ROMS_DIR, SUPERVISOR, PT_F40_ADDR,
                           PT_F40B_ADDR, PT_F40_MAG1, PT_F40_MAG2,
                           blob, step_until, at_prompt, run_cmd)

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src/test/asm/boundary.s'
FAIL_SOURCE = ROOT / 'src/test/asm/boundaryfail.s'
FAIL_NEG_SOURCE = ROOT / 'src/test/asm/boundneg.s'
NOXC_SOURCE = ROOT / 'src/test/asm/noxc.s'
FORWARD_SOURCE = ROOT / 'src/test/asm/forward.s'
PASS1_SOURCE = ROOT / 'src/test/asm/passone.s'
PASS2_SOURCE = ROOT / 'src/test/asm/passtwo.s'


def merlin_oracle(fixture=SOURCE):
    with tempfile.TemporaryDirectory(prefix='nas-boundary-oracle-') as tmp:
        work = Path(tmp)
        source = work / fixture.name
        shutil.copyfile(fixture, source)
        result = subprocess.run(
            [os.environ.get('MERLIN32', 'merlin32'), source.name],
            cwd=work, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError('merlin32 boundary oracle failed:\n' +
                               result.stdout + result.stderr)
        return (work / fixture.stem).read_bytes()


def boot(disk):
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    client.initialize()
    client.call_tool('reset', {'backend': 'fast'})
    for addr, val in ((PT_F40_ADDR, PT_F40_MAG1),
                      (PT_F40B_ADDR, PT_F40_MAG2)):
        client.call_tool('poke', {'addr': addr, 'bytes': [val], 'bank': 'main'})
    client.call_tool('mount_disk', {'path': disk})
    step_until(client, at_prompt, 'shell prompt', 1200, chunk=200_000)
    return client


def run_one(client, source, output, tag, want_status, success,
            failure_text='nas: branch out of range'):
    """Run cooked NCUT using the existing warm-session prompt helper."""
    if not success:
        # Remove earlier NAS output so this assertion cannot consume a stale
        # success diagnostic from the same warm session.
        run_cmd(client, 'clear', f'{tag} clear', max_steps=400)
    rows, _ = run_cmd(client, f'/mnt/MAUX/pllib/NCUT -o {output} {source}',
                      f'{tag} NAS', max_steps=10000)
    text = blob(rows)
    if success and f'bytes -> {output}' not in text:
        raise RuntimeError(f'{tag}: NCUT completion missing:\n{text}')
    if not success and failure_text not in text:
        raise RuntimeError(f'{tag}: missing {failure_text!r} diagnostic:\n{text}')
    status_rows, _ = run_cmd(client, f'echo {tag}=$?',
                             f'{tag} status', max_steps=2500)
    marker = f'{tag}={want_status}'
    if marker not in blob(status_rows):
        raise RuntimeError(f'{tag}: exit marker missing:\n{blob(status_rows)}')


def run_session(disk):
    client = boot(disk)
    try:
        run_cmd(client, 'cd /mnt/MAUX/pllib', 'session cd')
        run_one(client, 'BOUNDARY.S', 'BND.OBJ', 'BNDGOOD', 0, True)
        run_one(client, 'NOXC.S', 'BADXC.OBJ', 'NCNOXC', 1, False,
                failure_text='nas: pass 1 failed')
        # Different source, same NAS process image and same emulator boot.
        run_one(client, 'FORWARD.S', 'FWD.OBJ', 'BNDREPLAY', 0, True)
        run_one(client, 'BOUNDFAIL.S', 'BADP.OBJ', 'BNDBADP', 1, False)
        run_one(client, 'BOUNDFAILNEG.S', 'BADN.OBJ', 'BNDBADN', 1, False)
        run_cmd(client, 'ls', 'session flush', max_steps=2000)
    finally:
        client.close()


def compare(actual, expected):
    if actual != expected:
        at = next((i for i, (a, b) in enumerate(zip(actual, expected))
                   if a != b), min(len(actual), len(expected)))
        raise AssertionError(f'boundary object mismatch at byte {at}: '
                             f'{len(actual)}B vs {len(expected)}B; '
                             f'actual {actual[max(0, at-4):at+8].hex()} '
                             f'expected {expected[max(0, at-4):at+8].hex()}')


def stream_fixture():
    """Raw CR source with deliberately placed reader/parse boundaries."""
    source = bytearray(b' org $2000\rLBLONLY\r;LABEL\r*comment\r\r ;comment\r')
    source.extend(b' lda #$11\r')
    for length, value in ((254, 0x22), (255, 0x33), (256, 0x44), (511, 0x55)):
        line = f' lda #${value:02X} ;'.encode('ascii')
        source.extend(line + b'x' * (length - len(line)) + b'\r')

    def align(offset):
        padding = (offset - len(source)) % 512
        if padding < 2:
            padding += 512
        source.extend(b'*' + b'x' * (padding - 2) + b'\r')
        assert len(source) % 512 == offset

    # The preceding comment ends with CR at block offset 511.
    align(0)
    source.extend(b' lda #$66\r')
    # The instruction itself crosses the reader's 512-byte boundary.
    align(508)
    source.extend(b' lda #$77\r dfb \' \'\r dfb \';\'\r put PART.S\r rts')
    # Both the included file and parent end without a CR. The parent must
    # resume after the include, without skipping or duplicating either line.
    child = b'*included\r lda #$88'
    expected = bytes.fromhex('a9 11 a9 22 a9 33 a9 44 a9 55 a9 66 a9 77 20 3b a9 88 60')
    return bytes(source), child, expected


def check_stream(disk):
    """Check real slow/fast reader transitions, beyond the native CPU oracle."""
    from a2til import prodos
    import vpath  # noqa: F401  (docs/VROOT.md)
    source, child, expected = stream_fixture()
    with tempfile.TemporaryDirectory(prefix='nas-stream-boundary-') as tmp:
        image = str(Path(tmp) / 'stream.po')
        shutil.copyfile(disk, image)
        vol = prodos.mount(image, replace=True)
        try:
            for name, data in (('STREAM.S', source), ('PART.S', child)):
                prodos.write(f'/mnt/{vol}/PLLIB/{name}', data, file_type=4,
                             aux_type=0, overwrite=True)
        finally:
            prodos.unmount(vol)
        client = boot(image)
        try:
            run_cmd(client, 'cd /mnt/MAUX/pllib', 'stream cd')
            for tag in ('STRCOLD', 'STRWARM'):
                run_one(client, 'STREAM.S', tag + '.OBJ', tag, 0, True)
            run_cmd(client, 'ls', 'stream flush', max_steps=2000)
        finally:
            client.close()
        vol = prodos.mount(image, replace=True, readonly=True)
        try:
            for tag in ('STRCOLD', 'STRWARM'):
                compare(prodos.read(f'/mnt/{vol}/PLLIB/{tag}.OBJ'), expected)
        finally:
            prodos.unmount(vol)
    print('[check-nas-boundary] PASS: cold/warm streaming literal oracle; '
          '254/255/256/511-byte lines, CR at 511, straddle, PUT, partial EOF')


def check_pass1(disk, executable=None):
    """Independent sizes/modes, including forward data and a constant DUM."""
    from a2til import prodos, convert
    import vpath  # noqa: F401  (docs/VROOT.md)
    expected = merlin_oracle(PASS1_SOURCE)
    # Baseline NAS semantics, deliberately NOT a Merlin differential:
    # quoted word items retain only their first character in NAS, while
    # Merlin can pack two. Empty numeric items occupy their normal width.
    odd = (b' org $2000\n dfb ,1,,2,\n da "AB",\'cd\'\n'
           b' ddb "AB",\'cd\'\n asc "",\'\',$00\n'
           b' str "",\'\',$01\n dci "",\'\',$80\n rts\n')
    odd_expected = bytes.fromhex('00 01 00 02 00 c1 00 63 00 '
                                 '00 c1 00 63 00 01 01 00 60')
    cases = (('PASSONE', PASS1_SOURCE.read_bytes(), expected),
             ('ODDITEM', odd, odd_expected),
             ('PASSTWO', PASS2_SOURCE.read_bytes(), merlin_oracle(PASS2_SOURCE)))
    with tempfile.TemporaryDirectory(prefix='nas-pass1-boundary-') as tmp:
        image = str(Path(tmp) / 'pass1.po')
        shutil.copyfile(disk, image)
        vol = prodos.mount(image, replace=True)
        try:
            if executable is not None:
                prodos.write(f'/mnt/{vol}/PLLIB/NCUT', Path(executable).read_bytes(),
                             file_type=6, aux_type=0x800, overwrite=True)
            for name, source, _ in cases:
                prodos.write(f'/mnt/{vol}/PLLIB/{name}.S',
                             convert.text_from_host(source), file_type=4,
                             overwrite=True)
        finally:
            prodos.unmount(vol)
        client = boot(image)
        try:
            run_cmd(client, 'cd /mnt/MAUX/pllib', 'pass1 cd')
            for index, (name, _, _) in enumerate(cases):
                for run in ('COLD', 'WARM'):
                    tag = f'P{index}{run}'
                    run_one(client, name + '.S', tag + '.OBJ', tag, 0, True)
            run_cmd(client, 'ls', 'pass1 flush', max_steps=2000)
        finally:
            client.close()
        vol = prodos.mount(image, replace=True, readonly=True)
        try:
            for index, (_, _, want) in enumerate(cases):
                for run in ('COLD', 'WARM'):
                    tag = f'P{index}{run}'
                    compare(prodos.read(f'/mnt/{vol}/PLLIB/{tag}.OBJ'), want)
        finally:
            prodos.unmount(vol)
    print(f'[check-nas-boundary] PASS: {len(expected)}B pass1 sizes/modes '
          'cold/warm match fresh merlin32; data, strings, DUM, forward values; '
          f'{len(odd_expected)}B frozen NAS empty/quoted-item oracle')
    print('[check-nas-boundary] PASS: pass2 buffer edges 509/510/511/512, '
          'STR/HEX/DUM; cold/warm bytes match fresh merlin32')


def main():
    if len(sys.argv) != 2:
        print(f'usage: {sys.argv[0]} build/nas.po', file=sys.stderr)
        return 2
    disk = os.path.abspath(sys.argv[1])
    if (not SOURCE.exists() or not FAIL_SOURCE.exists() or
            not FAIL_NEG_SOURCE.exists() or not NOXC_SOURCE.exists() or
            not FORWARD_SOURCE.exists()):
        print('boundary fixtures are missing', file=sys.stderr)
        return 2

    expected = merlin_oracle()
    run_session(disk)
    sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
    from a2til import prodos
    import vpath  # noqa: F401  (docs/VROOT.md)
    vol = prodos.mount(disk, replace=True, readonly=True)
    try:
        actual = prodos.read(f'/mnt/{vol}/PLLIB/BND.OBJ')
    finally:
        prodos.unmount(vol)
    compare(actual, expected)
    print(f'[check-nas-boundary] PASS: {len(actual)}B byte-identical to '
          'fresh merlin32 oracle')

    # Deliberate sabotage: the oracle must reject a wrong result, not merely
    # exercise a success path. This mutates a private copy only.
    sabotaged = bytearray(expected)
    sabotaged[0] ^= 1
    try:
        compare(bytes(sabotaged), expected)
    except AssertionError:
        print('[check-nas-boundary] PASS: deliberate byte sabotage rejected')
    else:
        print('[check-nas-boundary] FAIL: byte oracle accepted sabotage',
              file=sys.stderr)
        return 1

    vol = prodos.mount(disk, replace=True, readonly=True)
    try:
        replay = prodos.read(f'/mnt/{vol}/PLLIB/FWD.OBJ')
    finally:
        prodos.unmount(vol)
    frozen = bytes.fromhex('ad f4 00 60 ea')
    compare(replay, frozen)
    print('[check-nas-boundary] PASS: forward small reference retains '
          'pass-1 absolute sizing (frozen 5B baseline)')

    print('[check-nas-boundary] PASS: cooked NCUT XC -> no-XC -> forward warm '
          'session; unsupported BRA, +128, and -129 failures rejected')
    check_stream(disk)
    check_pass1(disk)
    return 0


if __name__ == '__main__':
    sys.exit(main())
