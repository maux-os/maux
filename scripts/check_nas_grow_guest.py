#!/usr/bin/env python3
"""Exhaust each incremental arena, then verify a different warm assembly."""
import argparse
from pathlib import Path
import shutil
import tempfile

import check_nas_boundary as gate
import profile_nas_cooked_vs_as as pair


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build-dir',type=Path,default=gate.ROOT/'build')
    ap.add_argument('--image',type=Path,default=gate.ROOT/'build/nas-selfmake.po')
    args=ap.parse_args()
    # The fixup arenas live in nas's HEAP, so these two fixtures must be
    # sized from the REAL cooked heap, never from a number that was right
    # once: they were 2600 / 7000 lines for the old 11,647 B heap, and when
    # PLASM-FIX gave nas 15,848 B the 2600-line case fitted and the gate
    # went red (OOM5: `nas: 7801 bytes`). The old pair was calibrated
    # against 11,647 B; scale by the heap, with a margin of 30%, and the
    # run itself asserts the case exceeds the heap (it must fail with
    # `nas: out of memory`).
    cut=(args.build_dir/'nas.cut').read_bytes()
    heap=0xBF00-0x0800-len(cut)
    scale=max(1.0,heap/11647.0)*1.3
    nfix=int(2600*scale)
    nwrap=int(7000*scale)
    print(f'[check-nas-grow] real nas heap {heap} B -> FIXUPS {nfix} lines, WRAP {nwrap} lines')
    cases={
        'SYMBOL': ' org $2000\n'+''.join(f'S{i:04d} equ {i}\n' for i in range(1400)),
        'EXTERN': ' rel\n'+''.join(f'E{i:04d} ext\n' for i in range(1400)),
        'LOCAL': ' org $2000\nROOT nop\n'+''.join(f':L{i:04d} nop\n' for i in range(1400)),
        'REPLAY': ' org $2000\n'+' nop\n'*14000,
        'ERRORS': ' org $2000\n'+' err 0\n'*2200,
        'FIXUPS': ' rel\nTARGET nop\n'+' sta TARGET\n'*nfix,
        'WRAP': ' rel\nTARGET nop\n'+' sta TARGET\n'*nwrap,
    }
    good=' org $2000\n'+' nop\n'*513+' dfb $55,$AA\n'
    expected=b'\xEA'*513+b'\x55\xAA'
    retry=' org $2000\n'+''.join(f'R{i:02d} equ '+(f'R{i+1:02d}' if i<15 else 'Z')+'+1\n' for i in range(16))
    retry+='Z equ 0\n dfb '+','.join(f'R{i:02d}' for i in range(16))+'\n'
    excess=' org $2000\n'+''.join(f'R{i:02d} equ Z+1\n' for i in range(17))+'Z equ 0\n'
    with tempfile.TemporaryDirectory(prefix='nas-grow-oom-') as tmp:
        disk=Path(tmp)/'test.po'
        shutil.copyfile(args.image,disk)
        v=pair.prodos.mount(str(disk))
        try:
            pair.prodos.mkdir('/mnt/MAUX/GROW')
            if 'PLLIB' not in {e.name for e in pair.prodos.scandir('/mnt/MAUX')}:
                pair.prodos.mkdir('/mnt/MAUX/PLLIB')
            pair.prodos.write('/mnt/MAUX/PLLIB/NCUT',(args.build_dir/'nas.cut').read_bytes(),
                              file_type=6,aux_type=0x800,overwrite=True)
            for name,text in [*cases.items(),('GOOD',good),('RETRY',retry),('EXCESS',excess)]:
                pair.prodos.write('/mnt/MAUX/GROW/'+name+'.S',pair.convert.text_from_host(text.encode()),file_type=4)
        finally:pair.prodos.unmount(v)
        client=gate.boot(str(disk))
        try:
            for i,name in enumerate(cases):
                gate.run_one(client,'/mnt/MAUX/GROW/'+name+'.S',f'/mnt/MAUX/GROW/BAD{i}',
                             f'OOM{i}',1,False,failure_text='nas: out of memory')
                gate.run_one(client,'/mnt/MAUX/GROW/GOOD.S',f'/mnt/MAUX/GROW/GOOD{i}',f'GOOD{i}',0,True)
            gate.run_one(client,'/mnt/MAUX/GROW/RETRY.S','/mnt/MAUX/GROW/RETRY.O','RETRYOK',0,True)
            gate.run_one(client,'/mnt/MAUX/GROW/EXCESS.S','/mnt/MAUX/GROW/EXCESS.O','RETRYBAD',1,False,
                         failure_text='nas: too many forward equates')
            gate.run_one(client,'/mnt/MAUX/GROW/RETRY.S','/mnt/MAUX/GROW/RETRY2.O','RETRYWARM',0,True)
            gate.run_cmd(client,'ls /mnt/MAUX/GROW','flush',max_steps=2000)
        finally:client.close()
        v=pair.prodos.mount(str(disk),readonly=True)
        try:
            names={e.name for e in pair.prodos.scandir('/mnt/MAUX/GROW')}
            for i in range(len(cases)):
                assert f'BAD{i}' not in names
                assert pair.prodos.read(f'/mnt/MAUX/GROW/GOOD{i}')==expected
            assert 'EXCESS.O' not in names
            for name in ('RETRY.O','RETRY2.O'):
                assert pair.prodos.read('/mnt/MAUX/GROW/'+name)==bytes(range(16,0,-1))
        finally:pair.prodos.unmount(v)
    print(f'PASS: {len(cases)} allocation-exhaustion/wrap paths, no failed objects, warm 513-opcode and 16-EQU chain byte oracles; 17-EQU refusal')


if __name__=='__main__':main()
