#!/usr/bin/env python3
"""build_demo_images.py -- the two extra boot images the screencasts
need (docs/DEMOS-W1.md; `make demo-unpack-image`, `make demo-loop-image`).

A demo may name an image other than play.po (DEMO['image'], see
scripts/demo_record.py IMAGES). Each is play.po plus a small, declared
addition, so the film is shot on the same system the person boots; the
addition is the fixture the gate in the sweep already proves.

  build/demo-unpack.po  play.po + /ARC/VBLSET.SHK, a REAL ShrinkIt
      archive from the wild (fixtures/asimov, PROVENANCE.md; the same
      one check-unpack extracts) staged as NuFX type $E0/$8002 with an
      empty /OUT beside it. W10.

  build/demo-loop.po    play.po + /DISKS/GAME.PO, a 280-block ProDOS
      volume named GAME (written by a2til, made dense the way
      loop_fix.py explains, because `mount` refuses a sparse tree file)
      holding a README, a short program listing and a text file. W11.

  build/demo-fed.po     play.po + /FED/NO.01 .. NO.85, the 85 Federalist
      Papers as maux text (DEMO-FEDGREP).

  build/demo-ddshrink.po  play.po + /bin/dd (not on the play roster) +
      /ARC/DEMOPROG.SDK (the 1990 GEM CD disk archive, type $E0/$8002),
      and build/demo-ddshrink-floppy.po, the 143,360-byte disk a2til
      extracts from that same archive: the floppy a demo puts in slot 6
      drive 1 (DEMO['floppy']). DEMO-DDSHRINK.

`build_demo_images.py [--out DIR] [unpack|loop|fed|ddshrink]` builds one or all (make
demo-unpack-image, demo-loop-image, demo-fed-image, demo-ddshrink-image).
All are generated and never
committed. ASCII only.

DETERMINISM. a2til stamps every file it writes with datetime.now() (minute
resolution), so two builds of the same sources differed in ~170 bytes and
every film booted from a demo image went stale at the next rebuild (the
freshness stamps hash the image). Each image, and the GAME.PO volume inside
demo-loop, is therefore passed through prodos_dates.
normalize_image_dates, the mechanism play.po and full.po use: every
directory header and entry gets IMAGE_TIMESTAMP, once, after the last
write. check-recorder builds each image twice and compares.
"""
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import convert, prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)
import imglock  # noqa: E402
import loop_fix as L  # noqa: E402
from prodos_dates import normalize_image_dates  # noqa: E402

PLAY = os.path.join(ROOT, 'build', 'play.po')
UNPACK = os.path.join(ROOT, 'build', 'demo-unpack.po')
LOOP = os.path.join(ROOT, 'build', 'demo-loop.po')
FED = os.path.join(ROOT, 'build', 'demo-fed.po')
DDS = os.path.join(ROOT, 'build', 'demo-ddshrink.po')
DDS_FLOPPY = os.path.join(ROOT, 'build', 'demo-ddshrink-floppy.po')
DD_BIN = os.path.join(ROOT, 'build', 'dd.bin')
DEMOPROG = os.path.join(ROOT, 'fixtures', 'gem', 'DEMOPROG.SDK')
FEDDIR = os.path.join(ROOT, 'fixtures', 'federalist')
ARCHIVE = os.path.join(ROOT, 'fixtures', 'asimov', 'VBLSET.SHK')

#: the files GAME.PO holds; the demo reads them back off the loop and
#: compares with these same strings (scripts/demo_host.GAME_FILES).
GAME_FILES = [
    ('README', 'GAME is a disk image that lives inside a file.\n'
               'mount attached it as a block device;\n'
               'umount lets it go.\n'),
    ('NOTES', 'one\ntwo\nthree\n'),
]


def build_unpack():
    # imglock: a flock on <image>.lock and an atomic rename onto the
    # final path, so two sweep lanes queue instead of colliding
    # (scripts/imglock.py), and no fixed temp name is shared.
    with imglock.publish(UNPACK) as tmp:
        shutil.copyfile(PLAY, tmp)
        _stage_unpack(tmp)
        normalize_image_dates(tmp)
    print('[demo-images] %s' % UNPACK)


def _stage_unpack(tmp):
    prodos.mount(tmp)
    try:
        prodos.mkdir('/mnt/MAUX/ARC')
        prodos.mkdir('/mnt/MAUX/OUT')
        with open(ARCHIVE, 'rb') as f:
            prodos.write('/mnt/MAUX/ARC/VBLSET.SHK', f.read(),
                         file_type=0xE0, aux_type=0x8002, overwrite=True)
    finally:
        prodos.unmount('MAUX')


def build_fed():
    # /FED/NO.01 .. NO.85: the Federalist Papers as maux text (high-bit
    # ASCII, CR line ends, type TXT), from fixtures/federalist
    # (scripts/build_federalist.py, fixtures/federalist/PROVENANCE.md).
    # DEMO-FEDGREP.
    names = sorted(os.listdir(FEDDIR))
    names = [n for n in names if n.startswith('NO.')]
    with imglock.publish(FED) as tmp:
        shutil.copyfile(PLAY, tmp)
        prodos.mount(tmp)
        try:
            prodos.mkdir('/mnt/MAUX/FED')
            for n in names:
                with open(os.path.join(FEDDIR, n), 'rb') as f:
                    data = convert.text_from_host(f.read(), high_bit=True)
                prodos.write('/mnt/MAUX/FED/' + n, data, file_type=0x04,
                             aux_type=0, overwrite=True)
        finally:
            prodos.unmount('MAUX')
        normalize_image_dates(tmp)
    print('[demo-images] %s (%d papers)' % (FED, len(names)))


def floppy_bytes():
    """The 143,360-byte ProDOS-order disk inside the 1990 archive,
    read by a2til (an independent NuFX reader): the floppy in drive 1
    and the oracle the demo compares everything with."""
    from a2til import nufx
    with nufx.NufxArchive(DEMOPROG) as arc:
        return bytes(arc.disk_record.read())


def archive_date():
    """When the 1990 archive says its disk record was archived."""
    from a2til import nufx
    with nufx.NufxArchive(DEMOPROG) as arc:
        return arc.disk_record.archived


def build_ddshrink():
    # DEMO-DDSHRINK: play.po + /bin/dd (PLAY_EXCLUDEd from the shared
    # image, as build_dd_image.py stages it) + /ARC/DEMOPROG.SDK (the
    # real 1990 disk archive, type $E0/$8002); and the floppy that goes
    # in slot 6 drive 1, a host-side extraction of that same archive.
    with open(DD_BIN, 'rb') as f:
        ddbin = f.read()
    with open(DEMOPROG, 'rb') as f:
        sdk = f.read()
    with imglock.publish(DDS) as tmp:
        shutil.copyfile(PLAY, tmp)
        prodos.mount(tmp)
        try:
            prodos.write('/mnt/MAUX/BIN/dd', ddbin, file_type=0x06,
                         aux_type=0x0800, overwrite=True)
            prodos.mkdir('/mnt/MAUX/ARC')
            prodos.write('/mnt/MAUX/ARC/DEMOPROG.SDK', sdk,
                         file_type=0xE0, aux_type=0x8002, overwrite=True)
        finally:
            prodos.unmount('MAUX')
        normalize_image_dates(tmp)
    with imglock.publish(DDS_FLOPPY) as tmp:
        with open(tmp, 'wb') as f:
            f.write(floppy_bytes())
    print('[demo-images] %s, %s' % (DDS, DDS_FLOPPY))


def game_image(work, files):
    """The dense 280-block GAME volume (loop_fix.dense_image's steps, with
    the volume's own dates normalised before the bytes are read)."""
    p = os.path.join(work, 'img-GAME.po')
    prodos.create(p, name='GAME', blocks=280)
    v = prodos.Volume(p)
    for fname, data in files:
        v.write_file(fname, data, file_type=4, aux_type=0)
    v.close()
    normalize_image_dates(p)
    with open(p, 'rb') as f:
        return L.junk_zero_blocks(f.read())


def build_loop():
    work = tempfile.mkdtemp(prefix='demo_images.')
    try:
        files = [('/' + n, convert.text_from_host(t.encode('ascii'),
                                                  high_bit=True))
                 for n, t in GAME_FILES]
        img = game_image(work, files)
        with imglock.publish(LOOP) as tmp:
            shutil.copyfile(PLAY, tmp)
            prodos.mount(tmp)
            try:
                prodos.mkdir('/mnt/MAUX/DISKS')
                prodos.write('/mnt/MAUX/DISKS/GAME.PO', img,
                             file_type=0x06, aux_type=0, overwrite=True)
            finally:
                prodos.unmount('MAUX')
            normalize_image_dates(tmp)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print('[demo-images] %s' % LOOP)


def set_out_dir(out):
    """Write the images into `out` instead of build/ (check-recorder builds
    twice into two scratch directories and compares)."""
    global UNPACK, LOOP, FED, DDS, DDS_FLOPPY
    os.makedirs(out, exist_ok=True)
    UNPACK = os.path.join(out, 'demo-unpack.po')
    LOOP = os.path.join(out, 'demo-loop.po')
    FED = os.path.join(out, 'demo-fed.po')
    DDS = os.path.join(out, 'demo-ddshrink.po')
    DDS_FLOPPY = os.path.join(out, 'demo-ddshrink-floppy.po')


def main():
    args = sys.argv[1:]
    if args[:1] == ['--out'] and len(args) >= 2:
        set_out_dir(args[1])
        args = args[2:]
    if not os.path.exists(PLAY):
        print('error: %s missing -- make play-image' % PLAY,
              file=sys.stderr)
        return 2
    which = args or ['unpack', 'loop', 'fed', 'ddshrink']
    for w in which:
        {'unpack': build_unpack, 'loop': build_loop,
         'fed': build_fed, 'ddshrink': build_ddshrink}[w]()
    return 0


if __name__ == '__main__':
    sys.exit(main())
