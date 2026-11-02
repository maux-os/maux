#!/usr/bin/env python3
"""ffmpeg_probe.py -- what `make demos` needs from ffmpeg, read from the lock.

dependencies.lock.json `tools.ffmpeg` is the ONE statement of the version
floor, the encoders and the filters (docs/DEPENDENCIES.md, "ffmpeg"). Two
callers hold a host to it: scripts/demo_record.py (at the start of
--record, and --check-ffmpeg, which `make demos` runs before it builds
anything) and scripts/check_dependencies.py (the test tier's optional
tool, Mac only in practice because check-deps is not a box gate). Neither
keeps its own copy of the numbers.

stdlib only.
"""
import json
import os
import re
import shutil
import subprocess

LOCK = os.environ.get('MAUX_LOCK') or os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    'dependencies.lock.json')


def lock_spec(lock=None):
    """The lock's tools.ffmpeg block: {min: [major, minor], encoders,
    filters, needed_by}. `lock` is a loaded lock; default reads the file."""
    if lock is None:
        with open(LOCK) as f:
            lock = json.load(f)
    return lock['tools']['ffmpeg']


def installed(ffmpeg='ffmpeg'):
    return shutil.which(ffmpeg) is not None


def problems(spec, ffmpeg='ffmpeg'):
    """Strings naming what is missing or too old, [] when `ffmpeg` can do
    what `spec` asks. A binary that cannot run at all is one problem."""
    floor = tuple(spec['min'])
    try:
        ver = subprocess.run([ffmpeg, '-version'], capture_output=True,
                             text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as e:
        return [f'{ffmpeg}: cannot run ({e}); `make demos` needs ffmpeg '
                f'{floor[0]}.{floor[1]}+ with '
                f'{", ".join(spec["encoders"])}']
    found = []
    m = re.search(r'ffmpeg version n?(\d+)\.(\d+)', ver.stdout)
    if not m:
        found.append('ffmpeg version not recognised from '
                     f'{ver.stdout.splitlines()[:1]!r} (a git build?)')
    elif (int(m.group(1)), int(m.group(2))) < floor:
        found.append(f'ffmpeg {m.group(1)}.{m.group(2)} is below the '
                     f'floor {floor[0]}.{floor[1]}')
    for flag, names, label in (('-encoders', spec['encoders'], 'encoder'),
                               ('-filters', spec['filters'], 'filter')):
        out = subprocess.run([ffmpeg, '-hide_banner', flag],
                             capture_output=True, text=True).stdout
        have = {ln.split()[1] for ln in out.splitlines()
                if len(ln.split()) > 1}
        for n in names:
            if n not in have:
                found.append(f'ffmpeg has no {label} {n!r}')
    return found
