"""W12 -- a floppy, through dd, into a ShrinkIt archive
(docs/DEMO-DDSHRINK.md).

A 5.25-inch floppy in slot 6, drive 1: DEMO.PROGRAM, a 280-block
volume, the disk inside a 1990 ShrinkIt archive from the
GEM CD (fixtures/gem/DEMOPROG.SDK, fixtures/PROVENANCE.md). maux reads
it with dd, pipes the bytes straight into nulib2, which writes them as
a ShrinkIt DISK record in FLOP.SDK; lists the archive; writes the disk
back out of the archive into a file, mounts that file and lists the
volume; and finally closes the circle: the disk it just imaged is the
same, byte for byte, as the disk inside the 1990 archive (cmp, silent).

The oracle is the 1990 archive, read on the host by a2til, an
independent NuFX reader (scripts/build_demo_images.py floppy_bytes()):
the image in the drive, the archive rows, the cksum of every file the
film makes and the volume's listing are all computed from it. Nothing
about the result is typed in this file.

Everything the film makes goes in /tmp, never the volume root
(docs/SH-DEFECTS-2026-10-20.md item 0).
"""
import os

import build_demo_images as B
import demo_host as H

DEMO = dict(
    name='ddshrink',
    title='A floppy, through dd, into a ShrinkIt archive',
    backends=('text80', 'ut'),
    image='ddshrink',
    floppy='ddshrink',
    gate='check-demo-ddshrink',
)

ORIG_SDK = '/mnt/MAUX/ARC/DEMOPROG.SDK'
# The numbers the captions print. They are literals because the site
# generator reads captions without running the file; run() asserts every
# one of them against the data (a2til on the 1990 archive).
VOL = 'DEMO.PROGRAM'
NBLOCKS = 280
NBYTES = '143,360'
NFILES = 14
SDK_BYTES = '82,013'
YEAR = 1990
SPEED = 30            # fast(n) for the long reads and writes
LONG = 1500           # seconds of emulated time a long command may take


def v_row(name, nbytes):
    """The `nulib2 -v` row of a disk record: type Disk, bytes, blocks
    in hex, the record's name (check_floppy.py's oracle row)."""
    return ' Disk %8d $%04X %s' % (nbytes, nbytes // 512, name)


def run(t):
    disk = B.floppy_bytes()              # a2til, out of the 1990 archive
    crc, n = H.cksum(disk)
    vol, names = volume(disk)

    # host rows: the floppy the drive holds IS the archive's disk (the
    # file the recorder actually mounted: t.floppy), and every number a
    # caption below prints is one of these
    with open(t.floppy, 'rb') as f:
        t.expect(f.read() == disk,
                 'host: the image in drive 1 is the 1990 archive\'s disk')
    t.expect(B.archive_date().year == YEAR,
             'host: the archive record is dated 1990')
    t.expect((len(disk) // 512, format(n, ','), vol) ==
             (NBLOCKS, NBYTES, VOL),
             'host: the captions\' block count, byte count and name')
    t.expect(len(names) == NFILES, 'host: the captions\' file count')
    t.expect(format(os.path.getsize(B.DEMOPROG), ',') == SDK_BYTES,
             'host: the captions\' archive size')

    t.say('A 5.25-inch ProDOS floppy is in drive 1: %s, %d blocks.'
          % (VOL, NBLOCKS))
    t.say('It came from the GEM CD, 1990, as an %s-byte ShrinkIt '
          'archive.' % SDK_BYTES)
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('cd /tmp', 'a scratch directory, not the volume root')
    t.run_cmd_echoed('mount', 'mount: the floppy is not mounted')
    t.expect_lines(['/dev/s7d1 on /mnt/MAUX'],
                   'only the boot disk is mounted; the floppy is just '
                   'a device, /dev/s6d1')
    t.hold(2.0)

    t.say('dd reads the whole floppy as %d blocks and pipes it to '
          'nulib2.' % NBLOCKS)
    t.say('dd borrows its name from the DD statement of IBM job control.')
    t.say('A name ending in .SDK makes it a disk archive.')
    t.say('The x%d badge marks the sped-up read.' % SPEED)
    t.press('\x0c')
    t.wait_prompt('clear screen')
    with t.fast(SPEED):
        t.run_cmd_echoed('dd if=/dev/s6d1 | nulib2 -a FLOP.SDK -', 'dd')
        t.expect_lines(['%d+0 records in' % NBLOCKS,
                        '%d+0 records out' % NBLOCKS],
                       'dd read and wrote every block', seconds=LONG)
    t.hold(2.0)

    t.say('One record, of type Disk, %s bytes: %d blocks.'
          % (NBYTES, NBLOCKS))
    t.say('A disk archive lists as a single record.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('nulib2 -v FLOP.SDK', 'list')
    t.expect_lines([v_row('FLOP', n)],
                   'one Disk record, named for the archive, 280 blocks')
    t.hold(3.0)

    t.say('What is on the disk? nulib2 -p writes it back out, into a '
          'file.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    with t.fast(SPEED):
        t.run_cmd_echoed('nulib2 -p FLOP.SDK > FLOP.PO', 'extract')
        t.expect_lines(0, 'nulib2 -p says nothing', seconds=LONG)
    t.hold(2.0)

    t.say('A disk image is a file: mount it and list the volume.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('mount /tmp/FLOP.PO', 'mount the image')
    t.expect_lines(0, 'mount attaches the image silently', seconds=LONG)
    t.run_cmd_echoed('mount', 'mount after')
    t.expect_lines(['/dev/s7d1 on /mnt/MAUX',
                    '/dev/s3d2 on /mnt/' + VOL],
                   'the image is a second device, mounted by its '
                   'volume name')
    t.run_cmd_echoed('ls /mnt/' + VOL, 'ls')
    t.expect(H.columns_to_names(t.output('ls')) == names,
             'ls shows exactly the files the host finds on the disk')
    t.hold(4.0)
    t.run_cmd_echoed('umount /mnt/' + VOL, 'umount')
    t.expect_lines(0, 'umount detaches silently')
    t.run_cmd_echoed('mount', 'mount last')
    t.expect_lines(['/dev/s7d1 on /mnt/MAUX'],
                   'umount let the image go: the boot disk is alone again')

    t.say('Does the copy match the original?')
    t.say('The 1990 archive is on maux\'s own disk too: one Disk record, '
          '%s.' % VOL)
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('nulib2 -v ' + ORIG_SDK, 'list original')
    t.expect_lines([v_row(VOL, n)],
                   'the 1990 archive holds one Disk record, the same '
                   'size, named DEMO.PROGRAM')
    with t.fast(SPEED):
        t.run_cmd_echoed('nulib2 -p %s > ORIG.PO' % ORIG_SDK, 'unshrink')
        t.expect_lines(0, 'nulib2 -p says nothing', seconds=LONG)
    with t.fast(SPEED):
        t.run_cmd_echoed('cmp FLOP.PO ORIG.PO', 'cmp')
        t.expect_cmp_silent('cmp is silent: the disk imaged through dd '
                            'is the disk inside the 1990 archive',
                            seconds=600)
        t.run_cmd_echoed('cksum FLOP.PO ORIG.PO', 'cksum both')
        t.expect_lines(['%d %d FLOP.PO' % (crc, n),
                        '%d %d ORIG.PO' % (crc, n)],
                       'both files are the host\'s disk, byte for byte',
                       seconds=600)
    t.poster()
    t.say('Silent: same bytes, and the two checksums agree.')
    t.say('Shrunk in 1990, read in 2026, and byte for byte the same.')
    t.hold(1.0)


def volume(disk):
    """(volume name, sorted root file names) of the floppy bytes, read
    by a2til from a scratch copy."""
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, 'f.po')
        with open(p, 'wb') as f:
            f.write(disk)
        v = H.prodos.Volume(p, readonly=True)
        return v.name, sorted(e.name for e in v.scandir('/'))
