#!/usr/bin/env python3
"""check_carrier.py -- the vendored ProDOS carrier must match the lock.

Every image builder copies vendor/prodos-basic.po and writes into its
volume by NAME (MAUX). `vendor/` is ignored and `make image` does not
rebuild it, so when the lock changed the carrier (VROOT, 2026-10-10:
volume BASIC -> MAUX) main's copy stayed stale for a day and two
engineers who copied vendor/ into their worktrees saw every builder die
with a2til's `No volume named 'MAUX' mounted` -- a message that names
neither the cause nor the fix. This check runs before `image` and
`play-image` (Makefile) and from check-volname; it is one sha256 of a
143,360-byte file.

Exit 0 when vendor/prodos-basic.po matches dependencies.lock.json's
`prodos_carrier` entry (bytes and sha256); otherwise print the cause
and the exact fix and exit 1. Self-test: `--selftest` checks a planted
mismatch is refused.
"""
import hashlib
import json
import os
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCK = os.path.join(ROOT, 'dependencies.lock.json')
FIX = 'rm vendor/prodos-basic.po && make vendor-prodos'


def check(carrier_path, lock_path=LOCK):
    with open(lock_path, encoding='ascii') as fh:
        want = json.load(fh)['artifacts']['prodos_carrier']
    if not os.path.exists(carrier_path):
        return (f'{carrier_path} is missing -- run: make vendor-prodos')
    with open(carrier_path, 'rb') as fh:
        data = fh.read()
    digest = hashlib.sha256(data).hexdigest()
    if len(data) != want['bytes'] or digest != want['sha256']:
        return (f'{carrier_path} does not match dependencies.lock.json '
                f'(have {len(data)} B sha256 {digest[:12]}..., lock wants '
                f'{want["bytes"]} B {want["sha256"][:12]}...): a STALE '
                f'carrier (its volume is probably not MAUX; every image '
                f'builder would fail with "No volume named \'MAUX\' '
                f'mounted"). Fix: {FIX}')
    return None


def selftest():
    with tempfile.NamedTemporaryFile(delete=False, suffix='.po') as fh:
        fh.write(b'\0' * 143360)
        planted = fh.name
    try:
        msg = check(planted)
        if not msg or 'STALE' not in msg:
            print('[check-carrier] SELF-TEST FAIL: a planted mismatch '
                  'was accepted')
            return 1
        if check(planted + '.missing') is None:
            print('[check-carrier] SELF-TEST FAIL: a missing carrier '
                  'was accepted')
            return 1
    finally:
        os.unlink(planted)
    print('[check-carrier] self-test: planted mismatch and missing '
          'carrier both refused: PASS')
    return 0


def main(argv):
    if '--selftest' in argv:
        return selftest()
    path = os.path.join(ROOT, 'vendor', 'prodos-basic.po')
    msg = check(path)
    if msg:
        print(f'[check-carrier] FAIL: {msg}')
        return 1
    print('[check-carrier] PASS: vendor/prodos-basic.po matches the lock')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
