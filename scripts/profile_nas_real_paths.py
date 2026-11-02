#!/usr/bin/env python3
"""Full-cycle warm NAS real-source trace, bound to matching cooked artifacts.

Frozen corpus bytes/metadata are regression oracles; the native world gate
supplies independent linked-byte oracles. Fetch alignment has independent
100-opcode/phase assertions in profile_nas_merlin_paths.py's lean fixture.
VM IP/Y owner buckets are approximate, phase totals and entry counts are
trace-derived. Kernel/other is not an I/O measurement. Fast emulator only.
"""
import argparse
import json
from pathlib import Path
import shutil
import tempfile

import profile_nas_merlin_paths as paths

hot, pair, paired = paths.hot, paths.pair, paths.paired


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build-dir', type=Path, default=paths.ROOT/'build')
    ap.add_argument('--image', type=Path, required=True)
    ap.add_argument('--compare', type=Path, required=True)
    ap.add_argument('--case', default='GREPM.S')
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    expected = json.loads(args.compare.read_text())
    image_hash = pair.digest(args.image.read_bytes())
    assert image_hash == expected['image_sha256']
    obj = next(c['object'] for c in expected['cases'] if c['case'] == args.case)
    with tempfile.TemporaryDirectory(prefix='nas-real-trace-') as tmpname:
        tmp = Path(tmpname)
        for name in hot.ARTIFACTS:
            shutil.copyfile(args.build_dir/name, tmp/name)
        info = hot.symbolize(tmp)
        nlabels, ptrtag, spans, native = paths.nas_labels(tmp, info)
        info = info[:3] + (native,) + info[4:]
        disk = tmp/'real.po'
        shutil.copyfile(args.image, disk)
        volume = pair.prodos.mount(str(disk))
        try:
            source = '/tmp/LR/' + args.case
            source_hash = pair.digest(pair.prodos.read(source))
            pair.prodos.mkdir(pair.DIRECTORY)
            pair.prodos.write(pair.DIRECTORY+'/NAS', info[0], file_type=6, aux_type=0x800)
        finally:
            pair.prodos.unmount(volume)
        result = paired.run(disk, 'nas', args.case, None, info, b'', [], 2718,
            tmp/'trace.csv', paths.analyzer('nas', None, {}, [], nlabels,
                ptrtag, spans, lean_fixture=False), source_path=source,
            object_metadata=obj)
        report = dict(method=__doc__, case=args.case, image_sha256=image_hash,
            source_sha256=source_hash, object=obj, result=result,
            nas_sha256=pair.digest(info[0]),
            supervisor_sha256=pair.digest(Path(pair.rig.SUPERVISOR).read_bytes()))
        args.output.write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(result['trace']['phase_cycles']), flush=True)
        print('PASS: contiguous warm trace, two pass entries, cold/warm object bytes and metadata')


if __name__ == '__main__':
    main()
