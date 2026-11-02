#!/usr/bin/env python3
"""Run existing guest oracles against private native-loop experiment images.

--world additionally composes and executes the complete native self-build.
Does not replace production NAS, images or plans.
"""
import argparse
from pathlib import Path
import subprocess
import sys

from build_nas_loop import ROOT


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build-dir', type=Path, default=ROOT / 'build/nas-loop')
    ap.add_argument('--world', action='store_true')
    args = ap.parse_args()
    out = args.build_dir.resolve()
    if out in (ROOT, ROOT / 'build'):
        raise ValueError('use a private experiment build directory')
    assert (out / 'nas.cut').read_bytes()[9:12] == b'CK\x01'
    import build_nas_image as flat
    flat.OUT_IMG = str(out / 'boundary.po')
    flat.NAS_MOD, flat.NAS_CUT = str(out / 'nas.mod'), str(out / 'nas.cut')
    assert flat.main() == 0
    subprocess.run([sys.executable, str(ROOT / 'scripts/check_nas_boundary.py'), flat.OUT_IMG], check=True)
    import build_nas_rel_image as rel
    rel.OUT_IMG, rel.NAS_MOD = str(out / 'rel.po'), str(out / 'nas.mod')
    assert rel.main() == 0
    subprocess.run([sys.executable, str(ROOT / 'scripts/check_nas_rel.py'), rel.OUT_IMG], check=True)
    if args.world:
        import build_nas_librel_image as world
        world.NAS_BUILD_DIR, world.NAS_CUT = str(out), str(out / 'nas.cut')
        world.OUT_IMG, world.PLAN = str(out / 'world.po'), str(out / 'world-plan.json')
        world.SELFMAKE = True
        assert world.main() == 0
        import check_nas_librel as check
        check.SELFMAKE, check.PLAN, check.MAX_STEPS = True, world.PLAN, 100000
        sys.argv = ['check_nas_librel', world.OUT_IMG]
        assert check.main() == 0


if __name__ == '__main__':
    main()
