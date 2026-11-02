#!/usr/bin/env python3
"""check_plasma_examples.py -- lesson L6 cannot drift from Dave's files
(`make check-plasma-examples`, docs/SITE.md sec 5 L6).

The L6 example is David Schmenk's own PLASMA sample, byte for byte. Rows
hold it there, with no emulator:

  D1  examples/hellopla/hello.pla == src/samplesrc/hello.pla at the PLASMA
      commit dependencies.lock.json pins (the blob is read from the
      checkout, or from its working tree where it has no .git).
  D2  src/plasma/inc/cmdsys.plh (the tree's copy of the header: the file
      build_full_image.py stages as /usr/inc/cmdsys.plh, and the one the
      cooked HELLO is built against) == src/inc/cmdsys.plh at the pin.
  D3  the cooked HELLO staged on build/full.po (and build/hellopla.cut) ==
      a FRESH cook of the PINNED hello.pla: xplasm (-AMW, as the Makefile),
      acme and plascut run here, on the host, from Dave's bytes -- not from
      our copy -- so the disk file cannot drift from the source either; and
      it is a BIN with aux_type $0800.
  D4  what is ON THE DISK: /usr/inc/cmdsys.plh and
      /usr/src/examples/HELLOPLA/hello.pla, read back from build/full.po,
      equal the pinned bytes in the disk's text convention (bit 7 set,
      $0A -> $8D, nothing else). The image is required: no image, no pass.

Every row prints the sha256 it compared. A mismatch names the row.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SCRIPTS)
HELLO = 'src/samplesrc/hello.pla'
HEADER = 'src/inc/cmdsys.plh'


def sha(b):
    return hashlib.sha256(b).hexdigest()


def plasma_checkout():
    with open(os.path.join(ROOT, 'dependencies.lock.json')) as f:
        lock = json.load(f)['repositories']['plasma']
    d = os.environ.get(lock['env']) or os.path.expanduser(lock['default'])
    return d, lock['commit']


def pinned(path):
    """The bytes of PATH in the pinned PLASMA commit."""
    d, commit = plasma_checkout()
    r = subprocess.run(['git', '-C', d, 'cat-file', 'blob',
                        f'{commit}:{path}'], capture_output=True)
    if r.returncode == 0:
        return r.stdout, f'git {commit[:8]}'
    with open(os.path.join(d, path), 'rb') as f:
        return f.read(), f'working tree (no git object {commit[:8]})'


def read(path):
    with open(os.path.join(ROOT, path), 'rb') as f:
        return f.read()


def row(name, ours, theirs, where, failures):
    ok = ours == theirs
    print(f'[check-plasma-examples] {name}: {"PASS" if ok else "FAIL"} '
          f'ours {sha(ours)[:16]} ({len(ours)} B), Dave {sha(theirs)[:16]} '
          f'({len(theirs)} B) [{where}]')
    if not ok:
        failures.append(name)


def fresh_cook(hello, header):
    """plascut's output for HELLO built from Dave's bytes."""
    xplasm = os.path.join(plasma_checkout()[0], 'src', 'xplasm')
    tmp = tempfile.mkdtemp(prefix='hellopla-')
    try:
        os.makedirs(os.path.join(tmp, 'inc'))
        with open(os.path.join(tmp, 'inc', 'cmdsys.plh'), 'wb') as f:
            f.write(header)
        with open(os.path.join(tmp, 'hello.pla'), 'wb') as f:
            f.write(hello)
        subprocess.run([xplasm, '-AMW', 'hello.pla'], cwd=tmp, check=True,
                       capture_output=True)
        subprocess.run(['acme', '--setpc', '8190', '-o',
                        os.path.join(tmp, 'hello.mod'),
                        os.path.join(tmp, 'hello.a')], check=True,
                       capture_output=True)
        out = os.path.join(tmp, 'hello.cut')
        subprocess.run([sys.executable, os.path.join(SCRIPTS, 'plascut.py'),
                        '-L', tmp, '-L', os.path.join(ROOT, 'build'),
                        '-o', out, 'HELLO'], check=True,
                       capture_output=True)
        with open(out, 'rb') as f:
            return f.read()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def maux_text(data):
    """The disk's text convention (build_full_image.maux_text)."""
    sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL',
                                                          '~/src/a2til')))
    from a2til import convert
    return convert.text_from_host(data, high_bit=True)


def disk_file(disk, path):
    sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL',
                                                          '~/src/a2til')))
    from a2til import prodos
    v = prodos.Volume(disk, readonly=True)
    try:
        return v.read_file(path)
    finally:
        v.close()


def staged_hello(disk):
    sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL',
                                                          '~/src/a2til')))
    from a2til import prodos
    v = prodos.Volume(disk, readonly=True)
    try:
        for e in v.scandir('/usr/src/examples/HELLOPLA'):
            if e.name == 'HELLO':
                return v.read_file('/usr/src/examples/HELLOPLA/HELLO'), \
                    (e.type, e.aux_type)
    finally:
        v.close()
    raise SystemExit('check-plasma-examples: no HELLO in '
                     '/usr/src/examples/HELLOPLA on ' + disk)


def main():
    failures = []
    hello, where = pinned(HELLO)
    header, hwhere = pinned(HEADER)
    row('D1 hello.pla is Dave\'s', read('examples/hellopla/hello.pla'),
        hello, where, failures)
    row('D2 cmdsys.plh is Dave\'s', read('src/plasma/inc/cmdsys.plh'),
        header, hwhere, failures)
    cook = fresh_cook(hello, header)
    print(f'[check-plasma-examples] fresh cook of the pinned hello.pla: '
          f'{len(cook)} B, sha256 {sha(cook)[:16]}')
    row('D3a build/hellopla.cut is the cook', read('build/hellopla.cut'),
        cook, 'build/', failures)
    disk = os.path.join(ROOT, 'build', 'full.po')
    if not os.path.exists(disk):
        print('[check-plasma-examples] FAIL: no build/full.po (make '
              'full-image); the rows that read the disk cannot be skipped')
        return 1
    data, (ftype, aux) = staged_hello(disk)
    row('D3b staged HELLO is the cook', data, cook, 'build/full.po',
        failures)
    if (ftype, aux) != (0x06, 0x0800):
        print(f'[check-plasma-examples] D3c FAIL: HELLO is type '
              f'${ftype:02X} aux ${aux:04X}, want BIN $0800')
        failures.append('D3c')
    row("D4a /usr/inc/cmdsys.plh on the disk is Dave's",
        disk_file(disk, '/usr/inc/cmdsys.plh'), maux_text(header),
        'build/full.po', failures)
    row("D4b HELLOPLA/hello.pla on the disk is Dave's",
        disk_file(disk, '/usr/src/examples/HELLOPLA/hello.pla'),
        maux_text(hello), 'build/full.po', failures)
    if failures:
        print('[check-plasma-examples] FAIL: ' + ', '.join(failures))
        return 1
    print('[check-plasma-examples] PASS: lesson L6 is Dave Schmenk\'s bytes')
    return 0


if __name__ == '__main__':
    sys.exit(main())
