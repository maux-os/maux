#!/usr/bin/env python3
"""Compare an experimental NAS on the unchanged production source graph.

Compose with a private snapshot of production NAS (no production writes),
then install the candidate. This deliberately does not use an obsolete
storage estimator to choose different source cuts for the new allocator.
Every staged utility must exist: a skipped utility is not a green world.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile

import build_nas_librel_image as world
import check_nas_librel as check
from profile_nas_hotspots import ARTIFACTS

ROOT=Path(__file__).resolve().parents[1]


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build-dir',type=Path,required=True)
    args=ap.parse_args()
    out=args.build_dir.resolve()
    candidate=(out/'nas.cut').read_bytes()
    with tempfile.TemporaryDirectory(prefix='nas-fixed-world-') as tmp:
        for name in ARTIFACTS:shutil.copyfile(ROOT/'build'/name,Path(tmp)/name)
        world.NAS_BUILD_DIR,world.NAS_CUT=tmp,str(Path(tmp)/'nas.cut')
        world.OUT_IMG,world.PLAN=str(out/'fixed-world.po'),str(out/'fixed-world-plan.json')
        world.SELFMAKE=True
        assert world.main()==0
    plan=json.loads(Path(world.PLAN).read_text())
    assert set(plan['skipped'])=={'AS'},plan['skipped']
    v=world.prodos.mount(world.OUT_IMG)
    try:
        world.prodos.write('/bin/NAS',candidate,file_type=6,aux_type=0x800,overwrite=True)
        assert world.prodos.read('/bin/NAS')==candidate
    finally:world.prodos.unmount(v)
    manifest={'candidate_sha256':hashlib.sha256(candidate).hexdigest(),
              'sizing_baseline_sha256':hashlib.sha256((ROOT/'build/nas.cut').read_bytes()).hexdigest(),
              'method':__doc__}
    (out/'fixed-world-method.json').write_text(json.dumps(manifest,indent=2)+'\n')
    check.SELFMAKE,check.PLAN,check.MAX_STEPS=True,world.PLAN,100000
    sys.argv=['check_nas_librel',world.OUT_IMG]
    assert check.main()==0
    v=world.prodos.mount(world.OUT_IMG,readonly=True)
    try:assert world.prodos.read('/bin/NAS')==candidate
    finally:world.prodos.unmount(v)


if __name__=='__main__':main()
