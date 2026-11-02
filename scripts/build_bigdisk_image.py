#!/usr/bin/env python3
"""build_bigdisk_image.py -- maux plus its OWN ENTIRE SOURCE TREE on one
32 MB ProDOS volume, so the system can strip and assemble itself with no
host preprocessing at all.

WHY ONE VOLUME, against docs/ARCHITECTURE.md's two. That page rules
"source lives on its OWN volume, mounted as unit 2 ... Do not
consolidate them", and its reason is sound for the hardware it assumes:
800K cannot hold system AND source. It does not survive a bigger disk,
and it does not currently WORK -- measured 2026-08-28:

  * ProDOS registers the second volume ($F0, slot 7 drive 2, present in
    DEVLST) but ProDOS (measured on 2.5; the image boots the tree's
    PRODOS_KERNEL_BIN, 2.4 by ruling) installs NO DRIVER for it: the
    device-driver table at $BF2E holds $E1CC, ProDOS's no-device stub,
    while drive 1 holds a real $FE78. Any maux path on the second volume
    dispatches into that stub and WEDGES in empty slot-2 ROM ($C2xx) --
    a hang, not an error, with zero reads ever reaching the device.
  * It is not the disk size: reproduced identically at 800K.
  * It is not the emulator: under check-dual's pair, booted from the
    MERLIN disk's own ProDOS, BOTH drive 1 and drive 2 hold $C77B (the
    card's own firmware) and the second volume reads fine. The hole is
    in the ProDOS build maux boots, not in the hardware model.

So two volumes is a design maux cannot presently use, and one big volume
sidesteps it entirely. The period argument is real and this does not
settle it -- see docs/S9-PLAN.md.

WHAT THIS PRODUCES. A bootable 32 MB volume (65535 blocks, ProDOS's own
ceiling) named BASIC, carrying PRODOS + MAUX.SYSTEM, the userland
binaries, and all 208 files of every unit's put closure under /mnt/MAUX/SRC
with their put/use operands rewritten to the flat staged namespace --
staged RAW, comments and all, because the point is that maux does the
stripping. Put/use operands (and the script's AS command) reference the
NAME+'X' files the strip writes, so the strip is a single pass with no
rename step (docs/PERF-PLAN.md step 1).

BOOT BLOCKS. a2til's prodos.create() zeroes them on purpose ("a data
volume, not bootable"), so blocks 0-1 are spliced in from the carrier.
That is the whole difference between a data volume and a boot volume
here; without it the machine mounts the image and spins in slot ROM.
"""
import sys, os, re, shutil
ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til'))); sys.path.insert(0, ROOT+'/scripts')
from a2til import prodos
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)
import check_manifests as cm, build_maux_src_image as b

OUT=ROOT+os.environ.get('OUTIMG','/build/mauxbig.po'); VOL='MAUX'; BLOCKS=int(os.environ.get('BLK','65535'))
CARRIER=os.path.join(ROOT,'vendor','prodos-basic.po')

prodos.create(OUT, name=VOL, blocks=BLOCKS, dir_blocks=4)
# a2til's create zeroes the boot blocks on purpose ("a data volume, not
# bootable"). Splice in real ones from the carrier so this can boot.
with open(CARRIER,'rb') as f: boot=f.read(1024)
with open(OUT,'r+b') as f: f.seek(0); f.write(boot)
print(f'boot blocks spliced from {os.path.basename(CARRIER)}')

graph, pt = cm.build_graph(); tops = cm.toplevel_manifests(graph, pt)
files=set()
def walk(p,seen):
    files.add(p)
    for e in graph.get(p,[]):
        if e[0]=='putbin' or e[1] in seen: continue
        seen.add(e[1]); walk(e[1],seen)
for t in tops: walk(t,set())
files=sorted(files)
if os.environ.get('SUBSET'): files=files[:int(os.environ['SUBSET'])]
names=b.assign_flat_names([cm.rel(f) for f in files])
# BUCKETED staging (2026-08-29): ProDOS directory lookup is a LINEAR
# scan of the directory chain, and a measured block trace of the strip
# put 49.7% of ALL block ops in re-reads of one flat 208-entry (then
# 400+ as the X files appear) /SRC chain -- ~60 directory-block reads
# per file stripped, quadratic-ish in file count. Sixteen buckets keep
# every scanned chain at ~26 entries = 2 blocks. The X outputs MUST
# live beside their sources: the strip script's `& > &X` can only
# APPEND to a path, never re-root it.
NBUCKET=16
rels=[cm.rel(f) for f in files]
bucket={rel: i*NBUCKET//len(rels) for i,rel in enumerate(rels)}
def spath(rel):
    return f'/mnt/{VOL}/SRC/S{bucket[rel]}/{names[rel]}'
# The strip writes each file's stripped copy under NAME+'X' and the staged
# put/use operands point at those X names directly (docs/PERF-PLAN.md step
# 1: no rename pass). That is only sound if no X name collides with a raw
# staged name.
clash={n+'X' for n in names.values()} & set(names.values())
assert not clash, f'X-suffixed strip names collide with staged names: {clash}'
def hi(t):
    return bytes((ord(c)|0x80) if c!='\n' else 0x8D
                 for c in t.replace('\r\n','\n').replace('\r','\n'))

prodos.mount(OUT)
prodos.mkdir(f'/mnt/{VOL}/SRC')
for _b in range(NBUCKET):
    prodos.mkdir(f'/mnt/{VOL}/SRC/S{_b}')
def W(p,d,ft=0x04,aux=0x0000):
    prodos.write(p, d, file_type=ft, aux_type=aux, overwrite=True)
KERNEL_BIN = os.environ.get('PRODOS_KERNEL_BIN',
                            os.path.join(ROOT, 'vendor', 'ProDOS-2.4.bin'))
W(f'/mnt/{VOL}/PRODOS', open(KERNEL_BIN,'rb').read(),0xFF,0x2000)
W(f'/mnt/{VOL}/MAUX.SYSTEM', open(os.path.join(ROOT,'build','MAUXAS.SYSTEM'),'rb').read(),0xFF,0x2000)
for nm,bn in (('SH','sh.bin'),('SED','sed.bin'),('FIND','find.bin'),('AS','as.bin'),
              ('LS','ls.bin'),('CAT','cat.bin'),('ECHO','echo.bin'),('MV','mv.bin')):
    p=os.path.join(ROOT,'build',bn)
    try:                      # docs/VROOT.md: programs live in BIN
        prodos.mkdir(f'/mnt/{VOL}/BIN')
    except FileExistsError:
        pass
    if os.path.exists(p): W(f'/mnt/{VOL}/BIN/{nm}', open(p,'rb').read(),0x06,0x0800)
total=0
for f in files:
    rel=cm.rel(f); out=[]
    for line in open(f, errors='replace').read().split('\n'):
        m=re.match(r'^([ \t]+)(put|use)\s+(\S+)', line, re.I)
        if m:
            tgt=os.path.normpath(os.path.join(os.path.dirname(rel), m.group(3)))
            if tgt in names:
                # Operands point at the X (stripped) names the strip will
                # write, so no rename pass is needed (PERF-PLAN step 1).
                out.append(f' {m.group(2).upper()} {spath(tgt)}X'); continue
        out.append(line)
    d=hi('\n'.join(out)); total+=len(d)
    W(spath(rel), d)
# One pass, not two: the strip writes NAME+'X' and every staged put/use
# operand (and the AS command below) already references the X names, so
# the old `MV &X &` rename pass -- 208 more spawns that existed only
# because sed has no -i -- is gone (docs/PERF-PLAN.md step 1). The raw
# files stay on disk beside the stripped ones; on a 32 MB volume holding
# 2.9 MB of source that is free.
PROG_GEN = '''SED "s/^.*/SED 's\\/^\\\\*.*\\/\\/;s\\/^ *;.*\\/\\/' & > &X/"'''
echo_rel=[r for r in rels if names[r]=='BECHO'][0]
# NOAS=1 drops the assembly tail, leaving the pure strip: booting both
# variants and subtracting is how the strip-vs-assembly phase split is
# measured (a PC sample cannot tell sed from as -- every process bank
# shares $0800+).
AS_TAIL=("" if os.environ.get('NOAS') else
         f"AS {spath(echo_rel)}X -o /mnt/{VOL}/ECHO.OBJ\r"
         f"ECHO ASSEMBLED > /mnt/{VOL}/M3\r")
SCRIPT=(f"FIND /mnt/{VOL}/SRC -type f -print > /mnt/{VOL}/LIST\r"
        f"{PROG_GEN} /mnt/{VOL}/LIST > /mnt/{VOL}/GEN1\r"
        f"SH < /mnt/{VOL}/GEN1\r"
        f"ECHO STRIPPED > /mnt/{VOL}/M1\r"
        f"{AS_TAIL}"
        f"EXIT\r")
W(f'/mnt/{VOL}/SCRIPT', bytes((ord(c)|0x80) if c!='\r' else 0x8D for c in SCRIPT))
prodos.unmount(VOL)
print(f'{len(files)} source files, {total:,} B raw -> {OUT} ({os.path.getsize(OUT):,} B)')
