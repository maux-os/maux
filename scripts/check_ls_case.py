#!/usr/bin/env python3
"""check_ls_case.py -- the runtime-create half of `make check-ls`
(docs/PRODOS-CASE.md): names the maux KERNEL creates or renames carry
GS/OS case flags, so `ls` shows what was typed.

check_ls.py's own five runs stage every name host-side (a2til already
writes the flags), so they cannot see the write side.  This phase boots
the stock play image, runs a shell script that creates and renames
names AT RUNTIME, and reads the raw directory words back off the
write-through image:

  touch Makefile; touch makefile      first spelling wins, no rewrite
  mkdir Src; mv Makefile Src/makeFile cross-dir move (copy+unlink)
  cp Src/makeFile Readme.txt           a create via cp
  echo x > Notes; mv Notes noteS       RENAME to mixed case
  mv Allcaps2 ALLCAPS3                 RENAME to ALL CAPS: the stale
                                       mask 2.4's RENAME keeps must go
  mkdir Dir2; mv Dir2 dIR3             a directory: entry AND header
  nulib2 -x ARC.SHK                    extract a mixed-case member
  touch /mnt/SECOND/otherCase              a NON-boot volume (unit from FCB)
  ls -l Src > lsSrc; ls > lsAll        the listing shows the case

Asserted: the raw `+$1C` word of every entry (mask_for(typed)), the
subdirectory HEADER word equal to its entry word (a2til check() does
not compare them -- measured, docs/PRODOS-CASE-NOTES.md M1), a2til
check() clean, and the captured `ls` text.  Teeth: on a kernel that
does not write the flags every row below reads `$0024` and this phase
fails (shown red on 77b6813 in docs/PRODOS-CASE-NOTES.md).

ASCII only.
"""
import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import casedir  # noqa: E402
from case_rig import Rig, ROOT, BUILD  # noqa: E402
from a2til import convert, prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

SCRIPT = '''\
mkdir /mnt/MAUX/Work
cd /mnt/MAUX/Work
touch Makefile
touch makefile
touch Mixed
touch mixed
mkdir Src
mv Makefile Src/makeFile
cp Src/makeFile Readme.txt
echo x > Notes
mv /mnt/MAUX/Work/Notes /mnt/MAUX/Work/noteS
touch Plain
touch ZZ9
mv /mnt/MAUX/Work/Plain /mnt/MAUX/Work/Allcaps2
mv /mnt/MAUX/Work/Allcaps2 /mnt/MAUX/Work/ALLCAPS3
mkdir Dir2
mv /mnt/MAUX/Work/Dir2 /mnt/MAUX/Work/dIR3
mkdir TOPDIR
nulib2 -x /mnt/MAUX/ARC.SHK
touch /mnt/SECOND/otherCase
ls -l Src > /mnt/MAUX/Work/lsSrc
ls > /mnt/MAUX/Work/lsAll
touch /mnt/MAUX/Big/newCase
echo x > /mnt/MAUX/Big/zzLow
cp /mnt/MAUX/Big/F03 /mnt/MAUX/Big/cpCopy
echo done > /mnt/MAUX/Work/DONE
'''

# (directory, stored upper-case name, the spelling the user TYPED last,
#  is_dir).  typed=None means "all caps / no lowercase": word bit 15
# must be clear (no flags) and the decode is the stored name.
EXPECT = [
    ('/mnt/MAUX/Work', 'MIXED', 'Mixed', False),
    ('/mnt/MAUX/Work', 'SRC', 'Src', True),
    ('/mnt/MAUX/Work', 'README.TXT', 'Readme.txt', False),
    ('/mnt/MAUX/Work', 'NOTES', 'noteS', False),
    ('/mnt/MAUX/Work', 'ZZ9', None, False),
    ('/mnt/MAUX/Work', 'ALLCAPS3', None, False),
    ('/mnt/MAUX/Work', 'DIR3', 'dIR3', True),
    ('/mnt/MAUX/Work', 'TOPDIR', None, True),
    ('/mnt/MAUX/Work', 'LSSRC', 'lsSrc', False),
    ('/mnt/MAUX/Work', 'LSALL', 'lsAll', False),
    ('/mnt/MAUX/Work', 'DONE', None, False),
    ('/mnt/MAUX/Work', 'NUMEMBER.TXT', 'NuMember.Txt', False),
    ('/mnt/MAUX/Work/Src', 'MAKEFILE', 'makeFile', False),
    # a directory PAST its first block (docs/SH-DEFECTS item 0): the new
    # entries land in block 2 of /Big, header+12 files fill block 1
    ('/mnt/MAUX/Big', 'NEWCASE', 'newCase', False),
    ('/mnt/MAUX/Big', 'ZZLOW', 'zzLow', False),
    ('/mnt/MAUX/Big', 'CPCOPY', 'cpCopy', False),
]
# names that must NOT exist any more (moved / renamed away)
GONE = [('/mnt/MAUX/Work', n) for n in
        ('PLAIN', 'ALLCAPS2', 'DIR2')]


def make_shk(tmp):
    """A host-made NuFX archive with ONE mixed-case member (the real
    nulib2(1), as check_nulib2.py does)."""
    import subprocess
    d = os.path.join(tmp, 'shk')
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, 'NuMember.Txt'), 'wb') as f:
        f.write(b'payload\r')
    subprocess.run(['nulib2', '-a', '-0', 'arc.shk', 'NuMember.Txt'],
                   cwd=d, check=True, capture_output=True, timeout=60)
    return open(os.path.join(d, 'arc.shk'), 'rb').read()


def make_stage(shk):
    def stage(vol):
        text = convert.text_from_host(SCRIPT.encode('ascii'),
                                      high_bit=True)
        vol.write_file('/CASE.SH', text, file_type=0x04, aux_type=0,
                       overwrite=True)
        vol.mkdir('/Big')
        for i in range(1, 15):          # header + 14 files: two blocks
            vol.write_file('/Big/F%02d' % i, b'\xc8\x8d', file_type=4,
                           aux_type=0, overwrite=True)
        vol.write_file('/ARC.SHK', shk, file_type=0xE0, aux_type=0x8002,
                       overwrite=True)
    return stage


def text_of(vol, path):
    raw = vol.read_file(path)
    return bytes(b & 0x7F for b in raw).replace(b'\r', b'\n').decode(
        'ascii', 'replace')


def check_image(img_path):
    """Return a list of failure strings for the post-run image."""
    img = open(img_path, 'rb').read()
    bad = []
    seen = {}
    for d, stored, typed, is_dir in EXPECT:
        try:
            ents = {e['stored'].decode(): e for e in casedir.entries(img, d)}
        except FileNotFoundError:
            bad.append(f'{d}: directory missing')
            continue
        e = ents.get(stored)
        if e is None:
            bad.append(f'{d}/{stored}: entry missing (have '
                       f'{sorted(ents)})')
            continue
        seen[(d, stored)] = e
        want = casedir.mask_for(typed) if typed else None
        if typed:
            if e['word'] != want:
                bad.append(f'{d}/{stored}: typed {typed!r} wants word '
                           f'${want:04X}, disk has ${e["word"]:04X} '
                           f'(decodes {e["name"]!r})')
        else:
            if e['word'] & 0x8000:
                bad.append(f'{d}/{stored}: typed all-caps but word '
                           f'${e["word"]:04X} has bit 15 set '
                           f'(decodes {e["name"]!r})')
        if is_dir:
            if (e['stype'] != 0x0D) or e['hdrword'] is None:
                bad.append(f'{d}/{stored}: expected a directory')
            else:
                hw = e['hdrword']
                if typed and hw != want:
                    bad.append(f'{d}/{stored}: header word ${hw:04X} != '
                               f'${want:04X}')
                if not typed and hw & 0x8000:
                    bad.append(f'{d}/{stored}: header word ${hw:04X} '
                               f'carries a mask for an all-caps name')
    for d, stored in GONE:
        ents = {e['stored'].decode() for e in casedir.entries(img, d)}
        if stored in ents:
            bad.append(f'{d}/{stored}: still present')
    # first spelling wins: 'touch makefile' after 'touch Makefile' (and
    # 'touch mixed' after 'touch Mixed') must not have rewritten the word
    vol = prodos.Volume(img_path, readonly=True)
    try:
        for p in vol.check():
            bad.append(f'a2til check: {p}')
        try:
            lssrc = text_of(vol, '/Work/lsSrc')
            lsall = text_of(vol, '/Work/lsAll')
        except FileNotFoundError:
            lssrc = lsall = ''
    finally:
        vol.close()
    if 'makeFile' not in lssrc:
        bad.append(f'ls -l Src does not show makeFile: {lssrc!r}')
    for n in ('Readme.txt', 'Src', 'noteS', 'dIR3', 'Mixed', 'ALLCAPS3'):
        if n not in lsall:
            bad.append(f'ls does not show {n}: {lsall!r}')
    return bad


def big_blocks(img):
    ent = [e for e in casedir.entries(img, '/') if e['stored'] == b'BIG'][0]
    return {n: img[n * 512:(n + 1) * 512]
            for n in casedir.dir_blocks(img, ent['key'])}, ent['key']


def audit_big(before, after):
    """/Big spans two directory blocks.  Every slot that was occupied
    before the run must be byte-identical after it (the header's
    file_count, +$21/+$22 of the entry, is the one legal change), and the
    block chain pointers too.  Catches a case word written into the KEY
    block (header version bytes, or an unrelated entry) instead of into
    the block that holds the new entry."""
    bad = []
    b0, key0 = big_blocks(before)
    b1, key1 = big_blocks(after)
    if sorted(b0) != sorted(b1):
        return [f'/Big block chain changed {sorted(b0)} -> {sorted(b1)}']
    for n in b0:
        if b0[n][:4] != b1[n][:4]:
            bad.append(f'/Big block {n}: chain pointers changed')
        for i in range(13):
            off = 4 + i * 39
            old, new = bytearray(b0[n][off:off + 39]), bytearray(b1[n][off:off + 39])
            if not any(old):
                continue
            if n == key0 and i == 0:
                for j in (0x21, 0x22):
                    old[j] = new[j] = 0
            if old != new:
                d = [j for j in range(39) if old[j] != new[j]]
                bad.append(f'/Big block {n} entry {i + 1}: pre-existing '
                           f'bytes changed at +${d[0]:02X}.. '
                           f'(was {bytes(old).hex()} now {bytes(new).hex()})')
    return bad


def check_second(path):
    """touch /mnt/SECOND/otherCase on a volume that is NOT the boot volume:
    the unit comes from the FCB, so the word must land on unit 2."""
    img = open(path, 'rb').read()
    ent = casedir.find(img, '/mnt/SECOND/OTHERCASE')
    want = casedir.mask_for('otherCase')
    if ent is None:
        return ['/mnt/SECOND/OTHERCASE: entry missing on the second volume']
    if ent['word'] != want:
        return [f'/mnt/SECOND/OTHERCASE: typed otherCase wants ${want:04X}, '
                f'second volume has ${ent["word"]:04X}']
    return []


def run(budget_cycles=240_000_000):
    with tempfile.TemporaryDirectory() as tmp:
        rig = Rig(tmp, second=True, stage=make_stage(make_shk(tmp)))
        try:
            big_before = open(rig.a, 'rb').read()
            rig.c.call_tool('type', {'text': 'sh /mnt/MAUX/CASE.SH\n'})
            done = False
            spent = 0
            while spent < budget_cycles:
                rig.c.call_tool('step', {'cycles': 4_000_000})
                spent += 4_000_000
                img = open(rig.a, 'rb').read()
                try:
                    if casedir.find(img, '/mnt/MAUX/Work/DONE'):
                        done = True
                        break
                except FileNotFoundError:
                    pass
            if not done:
                print('[check-ls] FAIL: case script never finished '
                      f'(no /mnt/MAUX/Work/DONE after {spent} cycles)',
                      file=sys.stderr)
                print('\n'.join(rig.screen()[:24]), file=sys.stderr)
                return 1
            rig.c.call_tool('step', {'cycles': 4_000_000})
            keep = os.environ.get('CHECK_LS_CASE_KEEP')
            if keep:
                shutil.copy(rig.a, keep)
            bad = check_image(rig.a)
            bad += check_second(rig.b)
            bad += audit_big(big_before, open(rig.a, 'rb').read())
        finally:
            rig.close()
    if bad:
        for b in bad:
            print(f'[check-ls] FAIL: runtime-create: {b}', file=sys.stderr)
        return 1
    print(f'[check-ls] PASS: runtime-create -- {len(EXPECT)} names the '
          'kernel created or renamed (touch, mkdir, cp, redirect, mv, mv '
          'of a directory, mv to ALL CAPS) carry the typed case on disk, '
          'subdirectory headers agree with their entries, a2til check '
          'clean, ls shows the case')
    return 0


if __name__ == '__main__':
    raise SystemExit(run())
