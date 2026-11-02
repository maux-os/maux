#!/usr/bin/env python3
"""pinned.py -- the tracked, hash-locked emulator-made build inputs.

Three things in the build are made by running real code INSIDE the
emulator: the two `as` core objects (real Merlin-8 rebuilding the patched
core, `make check-ascore-warm`) and the /usr/lib/LIBA REL objects
(nas assembling liba, `make full-image`). A host without verilogapple and
the ROM set cannot make them, so they are committed under pinned/ and
recorded, by length and sha256, in dependencies.lock.json ("pinned").
The BUILD tier copies them; the TEST tier regenerates them through the
emulator as before, and the sweep's pin gates require that the two agree
(docs/DEPS-TIER.md, pinned/README.md).

    pinned.py verify          every pin present, right length and sha256,
                              nothing extra in pinned/
    pinned.py copy BUILD_PATH copy the verified pin for build/X to build/X
    pinned.py compare         build/X (just regenerated) equals pinned/X,
                              else the re-pin command
    pinned.py repin           re-hash pinned/ into the lock's pinned block
                              (make repin-ascore / repin-liba rebuild first)

Importable: audit(), read_liba(), copy_to(), write_liba(), current_tier().
"""
import hashlib
import json
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCK = os.path.join(ROOT, 'dependencies.lock.json')
README = 'README.md'
BLOCK_HEAD = '  "pinned": '


def current_tier():
    """The tier this process was told it is in (the Makefile exports
    MAUX_TIER from the generated dependencies.mk; absent = test)."""
    return os.environ.get('MAUX_TIER') or 'test'


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def load_block(lock_path=LOCK):
    with open(lock_path) as f:
        return json.load(f)['pinned']


def _dir_files(path):
    try:
        return sorted(n for n in os.listdir(path)
                      if os.path.isfile(os.path.join(path, n)))
    except OSError:
        return []


def audit(root=ROOT, lock_path=None):
    """Return a list of failures; empty means every pin is exactly what
    the lock says. Cheap (about 28 KB), so check-deps runs it in BOTH
    tiers."""
    block = load_block(lock_path or os.path.join(root, 'dependencies.lock.json'))
    failures = []
    want = {}
    for ent in block['files']:
        want[ent['path']] = ent
    liba = block['liba']
    for obj in liba['objects']:
        want[f"{liba['dir']}/{obj['name']}{liba['suffix']}"] = obj
    for rel, ent in sorted(want.items()):
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            failures.append(f'pinned: missing {rel}')
            continue
        data = open(path, 'rb').read()
        if len(data) != ent['bytes']:
            failures.append(f'pinned: {rel} is {len(data)} bytes, lock says '
                            f'{ent["bytes"]}')
        elif sha256_bytes(data) != ent['sha256']:
            failures.append(f'pinned: {rel} sha256 {sha256_bytes(data)}, '
                            f'lock says {ent["sha256"]}')
    for d in sorted({os.path.dirname(r) for r in want}):
        have = {f'{d}/{n}' for n in _dir_files(os.path.join(root, d))}
        for extra in sorted(have - set(want) - {f'{d}/{README}'}):
            failures.append(f'pinned: {extra} is not in the lock')
    return failures


def read_liba(root=ROOT):
    """[(name, bytes, type, aux)] in directory order, each verified
    against the lock before it is handed out."""
    failures = audit(root)
    if failures:
        raise SystemExit('pinned: the pins do not match the lock:\n  - '
                         + '\n  - '.join(failures))
    block = load_block(os.path.join(root, 'dependencies.lock.json'))
    liba = block['liba']
    out = []
    for obj in liba['objects']:
        path = os.path.join(root, liba['dir'], obj['name'] + liba['suffix'])
        out.append((obj['name'], open(path, 'rb').read(), liba['type'],
                    obj['aux']))
    return out


def _entry_for_build(block, build_path):
    for ent in block['files']:
        if ent['build'] == build_path:
            return ent
    raise SystemExit(f'pinned: no pin is recorded for {build_path}')


def copy_to(build_path, root=ROOT):
    """Verify the pin for build/X and copy it to build/X."""
    block = load_block(os.path.join(root, 'dependencies.lock.json'))
    ent = _entry_for_build(block, build_path)
    failures = [f for f in audit(root) if ent['path'] in f]
    if failures:
        raise SystemExit('\n'.join(failures))
    dest = os.path.join(root, build_path)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.copyfile(os.path.join(root, ent['path']), dest)


def compare(root=ROOT):
    block = load_block(os.path.join(root, 'dependencies.lock.json'))
    bad = []
    for ent in block['files']:
        built = os.path.join(root, ent['build'])
        if not os.path.isfile(built):
            bad.append(f'{ent["build"]} was not regenerated (run '
                       f'{ent["regenerate"]})')
            continue
        got = open(built, 'rb').read()
        pin = open(os.path.join(root, ent['path']), 'rb').read()
        if got != pin:
            bad.append(f'{ent["build"]} ({len(got)} B) differs from '
                       f'{ent["path"]} ({len(pin)} B) -- the emulator now '
                       f'makes different bytes.\n    re-pin: cp {ent["build"]}'
                       f' {ent["path"]} && python3 scripts/pinned.py repin'
                       f'   (or `make repin-ascore`, which rebuilds first)')
    return bad


def render_block(block):
    """The pinned block as lock text: one line per pin, so a re-pin is a
    small diff and the lock stays readable."""
    def one(d):
        return json.dumps(d, separators=(', ', ': '))
    lines = ['{', '    "comment": ' + json.dumps(block['comment']) + ',',
             '    "files": [']
    lines += [f'      {one(e)}' + (',' if i < len(block['files']) - 1 else '')
              for i, e in enumerate(block['files'])]
    lines += ['    ],', '    "liba": {']
    liba = block['liba']
    for k in ('comment', 'dir', 'suffix', 'type', 'regenerate'):
        lines.append(f'      "{k}": {json.dumps(liba[k])},')
    lines.append('      "objects": [')
    objs = liba['objects']
    lines += [f'        {one(o)}' + (',' if i < len(objs) - 1 else '')
              for i, o in enumerate(objs)]
    lines += ['      ]', '    }', '  }']
    return '\n'.join(lines)


def write_block(block, lock_path=LOCK):
    """Replace the lock's "pinned" block (which must be its last key)."""
    text = open(lock_path).read()
    at = text.index('\n' + BLOCK_HEAD) + 1
    new = text[:at] + BLOCK_HEAD + render_block(block) + '\n}\n'
    json.loads(new)                      # still valid JSON, or stop
    with open(lock_path, 'w') as f:
        f.write(new)


def write_liba(objs, root=ROOT):
    """Re-pin /usr/lib/LIBA: objs is [(name, bytes, type, aux)]."""
    block = load_block(os.path.join(root, 'dependencies.lock.json'))
    liba = block['liba']
    d = os.path.join(root, liba['dir'])
    for n in _dir_files(d):
        if n != README:
            os.remove(os.path.join(d, n))
    entries = []
    for name, data, ftype, aux in objs:
        if ftype != liba['type']:
            raise SystemExit(f'pinned: {name} is type ${ftype:02X}')
        with open(os.path.join(d, name + liba['suffix']), 'wb') as f:
            f.write(data)
        entries.append({'name': name, 'aux': aux, 'bytes': len(data),
                        'sha256': sha256_bytes(data)})
    liba['objects'] = entries
    write_block(block, os.path.join(root, 'dependencies.lock.json'))


def repin(root=ROOT):
    block = load_block(os.path.join(root, 'dependencies.lock.json'))
    for ent in block['files']:
        data = open(os.path.join(root, ent['path']), 'rb').read()
        ent['bytes'] = len(data)
        ent['sha256'] = sha256_bytes(data)
    liba = block['liba']
    for obj in liba['objects']:
        data = open(os.path.join(root, liba['dir'],
                                 obj['name'] + liba['suffix']), 'rb').read()
        obj['bytes'] = len(data)
        obj['sha256'] = sha256_bytes(data)
    write_block(block, os.path.join(root, 'dependencies.lock.json'))


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ''
    if cmd == 'verify':
        failures = audit()
        for f in failures:
            print(f'[pinned] FAIL: {f}', file=sys.stderr)
        if not failures:
            print('[pinned] PASS: every pin matches the lock')
        return 1 if failures else 0
    if cmd == 'copy' and len(argv) == 3:
        copy_to(argv[2])
        return 0
    if cmd == 'compare':
        bad = compare()
        for b in bad:
            print(f'[check-pinned] FAIL: {b}', file=sys.stderr)
        if not bad:
            print('[check-pinned] PASS: the regenerated as-core objects '
                  'equal pinned/')
        return 1 if bad else 0
    if cmd == 'repin':
        repin()
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
