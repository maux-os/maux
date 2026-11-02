#!/usr/bin/env python3
"""Fetch the locked ProDOS disk and extract its kernel into vendor/.

ACQUISITION NOTE (docs/PRODOS-SPIKE.md carries the full story): this task
first tried reusing ~/Downloads/Apple II/STABLE.32MB.po (malisp's own
PRODOS_SRC_IMG default) -- its /FULL32/ProDOS turned out to be "ProDOS FX
0.9", a modified variant, not stock ProDOS 2.4. Per the task's own
fallback instruction, ProDOS 2.4 was fetched directly from the asimov
mirror linked off prodos8.com/releases/prodos-24/ (143360-byte ProDOS_2_4.dsk,
https://mirrors.apple2.org.za/ftp.apple.asimov.net/images/masters/prodos/ProDOS_2_4.dsk)
into vendor/ProDOS_2_4.dsk -- confirmed genuine via its own embedded banner
string ("Apple II ProDOS 8 V2.4        16-Aug-16Copyright Apple Computer,
Inc.", found by masking the high bit off the extracted PRODOS file's bytes).
Never committed (vendor/ is gitignored).

Usage: python3 scripts/vendor_prodos.py
Env overrides (malisp's own names):
  PRODOS_SRC_IMG   -- source image (default comes from dependencies.lock.json)
  PRODOS_SRC_PATH  -- path to the PRODOS file within it
"""
import hashlib
import json
import os
import sys
import tempfile
import urllib.request

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCK_PATH = os.path.join(ROOT, 'dependencies.lock.json')
# RELEASE picks which vendored disk the locked CARRIER is built from (its
# Boot.blocks/BASIC.SYSTEM); it is NOT the kernel maux boots. Every image
# builder writes PRODOS_KERNEL_BIN over /PRODOS, and the ruling of
# 2026-10-08 (docs/PRODOS-VERSION.md) makes that the 2.4 kernel, with
# GS/OS case flags written by maux itself (docs/PRODOS-CASE.md). The
# carrier is a locked artifact -- do not change this default to "fix"
# the kernel version; check-prodos-version reads it off every image.
RELEASE  = os.environ.get('PRODOS_RELEASE', '2.5')
_DEFAULTS = {
    '2.5': ('/P8.2.5/PRODOS', 'vendor/ProDOS-2.5.bin', b'ProDOS 8 V2.5'),
    '2.4': ('/PRODOS.2.4/PRODOS', 'vendor/ProDOS-2.4.bin', b'ProDOS 8 V2.4'),
}
with open(LOCK_PATH, encoding='ascii') as _lock_file:
    _lock = json.load(_lock_file)
_artifact = _lock['artifacts']['prodos'][RELEASE]
_carrier = _lock['artifacts']['prodos_carrier']
_path, _out, BANNER = _DEFAULTS[RELEASE]
_default_src = os.path.join(ROOT, _artifact['path'])
SRC_IMG = os.environ.get('PRODOS_SRC_IMG', _default_src)
SRC_PATH = os.environ.get('PRODOS_SRC_PATH', _path)
OUT_BIN = os.environ.get('PRODOS_OUT_BIN', os.path.join(ROOT, _out))
CARRIER_IMG = os.environ.get('PRODOS_CARRIER_IMG',
                             os.path.join(ROOT, _carrier['path']))


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def validate_locked_image(path):
    with open(path, 'rb') as source:
        data = source.read()
    if len(data) != _artifact['bytes']:
        raise ValueError(f'{path} is {len(data)} bytes, want '
                         f'{_artifact["bytes"]}')
    digest = sha256(data)
    if digest != _artifact['sha256']:
        raise ValueError(f'{path} sha256 {digest}, want '
                         f'{_artifact["sha256"]}')


def fetch_locked_image(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    print(f'[vendor_prodos] fetching {_artifact["url"]}')
    with urllib.request.urlopen(_artifact['url']) as response:
        data = response.read()
    if len(data) != _artifact['bytes'] or sha256(data) != _artifact['sha256']:
        raise ValueError('downloaded ProDOS image does not match '
                         'dependencies.lock.json')
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=os.path.dirname(path),
                                         prefix='.prodos.', delete=False) as output:
            temporary = output.name
            output.write(data)
        os.replace(temporary, path)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)


def build_carrier(boot, kernel, basic):
    """Create the deterministic SmartPort-bootable carrier used by images."""
    carrier_dir = os.path.dirname(os.path.abspath(CARRIER_IMG))
    os.makedirs(carrier_dir, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.prodos-carrier.', dir=carrier_dir)
    os.close(fd)
    os.unlink(temporary)
    try:
        # a2til correctly gives new volumes/files the current ProDOS minute.
        # This generated seed is a build input, so fix that otherwise-useful
        # metadata at the source rather than patching its on-disk offsets.
        real_datetime = prodos.datetime

        class FixedDateTime(real_datetime):
            @classmethod
            def now(cls, tz=None):
                return cls(2000, 1, 1, tzinfo=tz)

        prodos.datetime = FixedDateTime
        mounted = False
        try:
            prodos.create(temporary, name='MAUX', blocks=280)
            with open(temporary, 'r+b') as output:
                output.write(boot)
            prodos.mount(temporary)
            mounted = True
            prodos.write('/MAUX/PRODOS', kernel,
                         file_type=0xFF, aux_type=0x2000)
            prodos.write('/MAUX/BASIC.SYSTEM', basic,
                         file_type=0xFF, aux_type=0x2000)
        finally:
            if mounted:
                prodos.unmount('MAUX')
            prodos.datetime = real_datetime

        with open(temporary, 'rb') as source:
            built = source.read()
        digest = sha256(built)
        if len(built) != _carrier['bytes'] or digest != _carrier['sha256']:
            raise ValueError(f'generated carrier is {len(built)} bytes, '
                             f'sha256 {digest}; lock expects '
                             f'{_carrier["bytes"]} bytes, '
                             f'{_carrier["sha256"]}')

        if os.path.exists(CARRIER_IMG):
            with open(CARRIER_IMG, 'rb') as source:
                existing = source.read()
            if existing != built:
                raise ValueError(f'refusing to alter non-matching '
                                 f'{CARRIER_IMG}')
        else:
            os.replace(temporary, CARRIER_IMG)
            temporary = None
        print(f'[vendor_prodos] carrier -> {CARRIER_IMG} '
              f'({len(built)} bytes, sha256 {digest})')
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)


def main():
    if not os.path.exists(SRC_IMG):
        if os.path.abspath(SRC_IMG) != os.path.abspath(_default_src):
            print(f'error: operator-specified PRODOS_SRC_IMG does not exist: '
                  f'{SRC_IMG}', file=sys.stderr)
            return 2
        try:
            fetch_locked_image(SRC_IMG)
        except (OSError, ValueError) as exc:
            print(f'error: cannot fetch locked ProDOS {RELEASE} image: {exc}',
                  file=sys.stderr)
            return 2

    if os.path.abspath(SRC_IMG) == os.path.abspath(_default_src):
        try:
            validate_locked_image(SRC_IMG)
        except (OSError, ValueError) as exc:
            print(f'error: refusing mismatched locked ProDOS cache: {exc}',
                  file=sys.stderr)
            return 2

    prodos.mount(SRC_IMG)
    data = prodos.read(SRC_PATH)
    if RELEASE == '2.5':
        boot = prodos.read('/P8.2.5/Boot.blocks')
        basic = prodos.read('/P8.2.5/BASIC.SYSTEM')
    prodos.unmount(SRC_PATH.split('/')[1])

    stripped = bytes(b & 0x7F for b in data)
    banner_ok = BANNER in stripped
    if not banner_ok:
        print(f'warning: {SRC_PATH!r} does not contain the expected '
              f'{BANNER.decode()!r} banner -- vendoring it anyway, but '
              f'verify this is really ProDOS {RELEASE}, not a variant', file=sys.stderr)

    os.makedirs(os.path.dirname(OUT_BIN), exist_ok=True)
    with open(OUT_BIN, 'wb') as f:
        f.write(data)

    if RELEASE == '2.5':
        try:
            build_carrier(boot, data, basic)
        except (OSError, ValueError) as exc:
            print(f'error: cannot publish locked ProDOS carrier: {exc}',
                  file=sys.stderr)
            return 2

    print(f'[vendor_prodos] {SRC_IMG}:{SRC_PATH} -> {OUT_BIN} '
          f'({len(data)} bytes, banner_ok={banner_ok})')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
