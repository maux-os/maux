#!/usr/bin/env python3
"""check-sessions-fresh: are the recorded lesson sessions still of THIS disk?

    make check-sessions-fresh

Each build/examples/<lesson>/session.txt, written by `make check-examples`
and nothing else, starts with a `#! full.po sha256 <hex>` header: the disk
the lesson was typed on. Any rebuild of build/full.po (a `make play`, a
`make full-image` after a userland change) changes that hash and stales
every lesson page at once. `make check-site` says so, but it does a full
scratch site build and is in no sweep; this is the cheap probe (one sha256
of the image, one read of each header, well under a second) that
`preflight` and `check-all-host` carry so the staleness is seen the day it
happens.

Exit 0: fresh, or nothing to compare (no build/full.po, or no sessions: a
fresh clone or a box tree has neither, and that is not a defect). Exit 1:
at least one session records another disk, or none. Films are NOT probed
here; check-site still owns them (their stamps hash scripts and recorder
sources as well, which is not a cheap read).

    --examples DIR  --full-image PATH   override the defaults (the self-test)
    --selftest                          plant each defect, require exit 1

Remedy, in this order (HACKING.md): make check-examples demos
"""
import argparse
import hashlib
import os
import re
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HDR = re.compile(r'^#! full\.po sha256 ([0-9a-f]{64})\s*$')


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def probe(examples, image):
    """(errors, note). errors empty means pass."""
    if not os.path.isfile(image):
        return [], 'no %s: nothing to compare' % image
    if not os.path.isdir(examples):
        return [], 'no %s: no sessions recorded' % examples
    cur = sha256_of(image)
    errs, n = [], 0
    for lid in sorted(os.listdir(examples)):
        sp = os.path.join(examples, lid, 'session.txt')
        if not os.path.isfile(sp):
            continue
        n += 1
        got = None
        with open(sp, errors='replace') as f:
            for line in f.readlines()[:4]:
                m = HDR.match(line)
                if m:
                    got = m.group(1)
                    break
        if got != cur:
            errs.append('lesson %r: session ran on a build/full.po of sha256 '
                        '%s, not the current %s' % (lid, (got or 'none')[:12], cur[:12]))
    if errs:
        errs.append('run: make check-examples demos   (examples FIRST, HACKING.md)')
    return errs, '%d session(s) of %s' % (n, cur[:12])


def selftest():
    with tempfile.TemporaryDirectory() as t:
        img = os.path.join(t, 'full.po')
        ex = os.path.join(t, 'examples')
        with open(img, 'wb') as f:
            f.write(b'disk A')
        cur = sha256_of(img)

        def session(lid, header):
            os.makedirs(os.path.join(ex, lid), exist_ok=True)
            with open(os.path.join(ex, lid, 'session.txt'), 'w') as f:
                f.write(('#! revision x\n' + header + '\n' if header else '') + '$ ls\n')

        def code():
            return 1 if probe(ex, img)[0] else 0

        assert code() == 0, 'no examples dir must pass'
        session('l0', '#! full.po sha256 ' + cur)
        session('l1', '#! full.po sha256 ' + cur)
        assert code() == 0, 'fresh sessions rejected'
        with open(img, 'wb') as f:                   # plant: the disk is rebuilt
            f.write(b'disk B')
        assert code() == 1, 'rebuilt full.po not caught'
        session('l0', '#! full.po sha256 ' + sha256_of(img))
        session('l1', '#! full.po sha256 ' + sha256_of(img))
        assert code() == 0, 'fixed sessions still rejected'
        session('l1', '#! full.po sha256 ' + '0' * 64)   # plant: a corrupt sha
        assert code() == 1, 'corrupt recorded sha not caught'
        session('l1', '')                                # plant: no header
        assert code() == 1, 'missing header not caught'
        os.remove(img)
        assert code() == 0, 'no image must pass'
    print('check-sessions-fresh: self-test PASS (5 plants red, 4 controls green)')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--examples', default=os.path.join(ROOT, 'build', 'examples'))
    ap.add_argument('--full-image', default=os.path.join(ROOT, 'build', 'full.po'))
    ap.add_argument('--selftest', action='store_true')
    a = ap.parse_args()
    if a.selftest:
        selftest()
    errs, note = probe(a.examples, a.full_image)
    for e in errs:
        print('check-sessions-fresh: STALE: ' + e)
    if errs:
        print('check-sessions-fresh: FAIL')
        return 1
    print('check-sessions-fresh: PASS (%s)' % note)
    return 0


if __name__ == '__main__':
    sys.exit(main())
