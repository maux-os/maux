#!/usr/bin/env python3
"""Manual coverage, render and optional on-image byte checks.

The command roster comes from Makefile UTILS, plus the two separately built
native toolchain commands. Stub pages do not count as command coverage.
This checks packaging and minimum structure, not semantic truth of prose.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

import check_manifests as manifests

ROOT = Path(__file__).resolve().parent.parent
MAN = ROOT / 'docs/man'
RENDER = ROOT / 'build/man'
TOOLCHAIN = {'nas', 'ld', 'plasm'}


def command_roster():
    variables = manifests.parse_makefile_vars((ROOT / 'Makefile').read_text())
    return set(manifests.expand_str(variables, 'UTILS').split()) | TOOLCHAIN


def license_notices():
    caldera = (MAN / 'CALDERA-LICENSE').read_text()
    caldera = caldera.split('Copyright(C)', 1)[1]
    caldera = 'Copyright(C)' + caldera.split('POSSIBILITY OF SUCH DAMAGE.', 1)[0]
    caldera += 'POSSIBILITY OF SUCH DAMAGE.'
    bsd = (MAN / 'BSD-LICENSE').read_text().split('\n\nEX AND TIP\n\n', 1)[1]
    ex, bsd = bsd.split('\n\nRESET\n\n', 1)
    reset, vi = bsd.split('\n\nVI\n\n', 1)
    return {'Caldera': caldera, 'Berkeley ex/tip': ex,
            'Berkeley reset': reset, 'Berkeley vi': vi}


def normalized(text):
    return ' '.join(text.split())


def source_errors(pages, commands, notices=None):
    errors = []
    for name in sorted(commands):
        if name not in pages:
            errors.append(f'{name}: missing command page')
        elif 'is not provided on maux' in pages[name]:
            errors.append(f'{name}: implemented command has an unavailable stub')
    for name, source in sorted(pages.items()):
        if not re.fullmatch(r'[a-z][a-z0-9.]{0,14}', name):
            errors.append(f'{name}: illegal ProDOS page name')
        if not source.isascii():
            errors.append(f'{name}: non-ASCII source')
        if not re.search(r'^\.TH\s+' + re.escape(name.upper()) + r'\s+1\b', source, re.M):
            errors.append(f'{name}: missing/mismatched TH header')
        fields = ['NAME', 'DESCRIPTION']
        if name in commands:
            fields += ['SYNOPSIS', 'FILES', 'DIAGNOSTICS']
        for field in fields:
            if not re.search(r'^\.SH\s+"?' + field + r'"?\s*$', source, re.M):
                errors.append(f'{name}: missing {field}')
        if name in commands and '/usr/man/' + name.upper() not in source:
            errors.append(f'{name}: missing staged FILES path')
        if source.startswith('.\\" Derived from'):
            for token in ('Source: https://', 'SHA256:', 'licenses(1)', 'maux adaptations'):
                if token not in source:
                    errors.append(f'{name}: incomplete provenance ({token})')
    if 'licenses' not in pages:
        errors.append('missing distributable licences page')
    for label, notice in (notices or {}).items():
        if normalized(notice) not in normalized(pages.get('licenses', '')):
            errors.append(f'licenses: incomplete {label} notice')
    return errors


def unformat(raw):
    # Independent plain-text oracle for mandoc overstrikes.
    while b'\x08' in raw:
        replaced = re.sub(rb'.\x08', b'', raw)
        if replaced == raw:
            raise ValueError('unpaired backspace in render')
        raw = replaced
    return raw


def render_errors(pages):
    errors = []
    renderer = os.environ.get('MANDOC', 'mandoc')
    for name in sorted(pages):
        rendered = RENDER / (name + '.TXT')
        if not rendered.is_file():
            errors.append(f'{name}: missing render')
            continue
        result = subprocess.run([renderer, '-Tascii', '-O', 'width=64',
                                 str(MAN / (name + '.1'))], capture_output=True)
        raw = rendered.read_bytes()
        if result.returncode or raw != result.stdout or not raw.strip():
            errors.append(f'{name}: empty, failed or stale render')
        if any(c >= 128 for c in raw):
            errors.append(f'{name}: non-ASCII render')
        plain = unformat(raw)
        if b'NAME' not in plain or b'DESCRIPTION' not in plain:
            errors.append(f'{name}: missing rendered sections')
    return errors


def image_errors(pages, image):
    # Import lazily: source/render checks do not need a disk toolkit.
    import build_play_image as builder
    from a2til import prodos
    import vpath  # noqa: F401  (docs/VROOT.md)
    root = '/' + prodos.mount(str(image), readonly=True)
    errors = []
    expected = {name.upper() for name in pages}
    actual = set(prodos.listdir(root + '/USR/MAN'))
    if actual != expected:
        errors.append(f'image manual roster: missing={sorted(expected-actual)}, '
                      f'extra={sorted(actual-expected)}')
    for name in sorted(pages):
        if name.upper() not in actual:
            continue
        path = root + '/USR/MAN/' + name.upper()
        entry = prodos.stat(path)
        if entry.type != 0x04 or entry.aux_type != 0:
            errors.append(f'{name}: image page is not TXT with auxiliary type 0')
        raw = (RENDER / (name + '.TXT')).read_bytes()
        disk = prodos.read(path)
        if disk != builder.man_to_maux(raw):
            errors.append(f'{name}: image bytes differ from current render')
        # Do not just compare the converter with itself: strip its styling
        # and independently check that all printable prose survives.
        plain = bytes(c & 127 for c in disk).replace(b'\r', b'\n')
        plain = re.sub(rb'\x1b\[[0-9;]*m', b'', plain)
        if plain != unformat(raw):
            errors.append(f'{name}: staging lost or altered rendered prose')
    return errors


def self_test():
    good = ('.TH TOY 1\n.SH NAME\ntoy - a test\n.SH SYNOPSIS\ntoy\n'
            '.SH DESCRIPTION\nA real page.\n.SH FILES\n/usr/man/TOY\n'
            '.SH DIAGNOSTICS\n0 succeeds.\n')
    pages = {'toy': good, 'licenses': '.TH LICENSES 1\n.SH NAME\nlicences\n'
             '.SH DESCRIPTION\nnotices\n'}
    assert not source_errors(pages, {'toy'})
    assert source_errors(pages, {'toy', 'missing'})
    assert source_errors(dict(pages, toy=good.replace('A real page.',
                         'toy is not provided on maux')), {'toy'})
    assert source_errors(dict(pages, toy=good.replace('.SH DIAGNOSTICS',
                         '.SH OPTIONS')), {'toy'})
    assert source_errors(dict(pages, toy=good + '\u2014'), {'toy'})
    assert source_errors({'toy': good}, {'toy'})
    assert source_errors(pages, {'toy'}, {'fixture': 'required full notice'})
    assert not source_errors(dict(pages, licenses=pages['licenses'] +
                             'required full notice'), {'toy'},
                             {'fixture': 'required full notice'})
    assert unformat(b'A\bA _\bB\n') == b'A B\n'
    print('PASS man gate mutations: missing page, false stub, missing section, '
          'non-ASCII, missing/incomplete licences; independent overstrike oracle')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', type=Path)
    parser.add_argument('--source-only', action='store_true')
    args = parser.parse_args()
    self_test()
    pages = {p.stem: p.read_text() for p in MAN.glob('*.1')}
    commands = command_roster()
    notices = license_notices()
    errors = source_errors(pages, commands, notices)
    if not args.source_only:
        errors += render_errors(pages)
        license_render = RENDER / 'licenses.TXT'
        if license_render.is_file():
            rendered_notice = normalized(unformat(license_render.read_bytes()).decode('ascii'))
            for label, notice in notices.items():
                if normalized(notice) not in rendered_notice:
                    errors.append(f'licenses: rendered {label} notice incomplete')
    if args.image and not errors:
        errors += image_errors(pages, args.image)
    if errors:
        for error in errors:
            print('FAIL man:', error)
        return 1
    print(f'PASS man: {len(commands)}/{len(commands)} commands, '
          f'{len(pages)} source pages; '
          + ('source only' if args.source_only else 'current renders verified')
          + ('; image roster and bytes verified' if args.image else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
