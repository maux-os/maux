"""W11 -- mount a disk image (docs/SITE.md sec 4, docs/LOOP-S1.md).

A disk image is a file. `mount` attaches it as a block device, and its
volume appears under /mnt like any other disk: list it, read it, copy
out of it. `umount` lets it go and the volume is gone again.

The image is build/demo-loop.po: play.po plus /DISKS/GAME.PO, a
280-block ProDOS volume written by a2til (scripts/build_demo_images.py).
The files the demo expects to find inside it are the ones that builder
wrote, imported from it, not typed here.
"""
import re

import build_demo_images as B
import demo_host as H

DEMO = dict(
    name='mount',
    title='Mount a disk image',
    backends=('text80', 'ut'),
    image='loop',
    gate='check-demo-mount',
)

VOL = 'GAME'
IMAGE = '/mnt/MAUX/DISKS/GAME.PO'
READ_NAME = 'README'     # the site generator reads these literals;
COPY_NAME = 'NOTES'      # run() checks them against the builder


def run(t):
    files = [(n.upper(), t_) for n, t_ in B.GAME_FILES]
    names = sorted(n for n, _ in files)
    read_name, read_text = files[0]
    copy_name, copy_text = files[1]
    t.expect((read_name, copy_name) == (READ_NAME, COPY_NAME),
             'host: the files the demo names are the builder\'s')
    t.expect(re.fullmatch(r'[A-Z]+', VOL) and VOL.encode() in
             H.read('/DISKS/GAME.PO', B.LOOP),
             'host: the image file holds a volume named ' + VOL)

    t.say('A disk image is just a file. What is mounted now?')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('cd /tmp', 'a scratch directory, not the volume root')
    t.run_cmd_echoed('mount', 'mount before')
    before = t.output('mount before')
    t.expect(len(before) == 1 and before[0].endswith(' on /mnt/MAUX'),
             'only the boot disk is mounted')
    t.hold(2.0)

    t.say('mount GAME.PO attaches it as a block device.')
    t.run_cmd_echoed('mount ' + IMAGE, 'attach')
    t.expect_lines(0, 'mount attaches the image silently')
    t.run_cmd_echoed('mount', 'mount after')
    after = t.output('mount after')
    t.expect(len(after) == 2 and after[0] == before[0] and
             re.fullmatch(r'/dev/s\d+d\d+ on /mnt/%s' % VOL, after[1]),
             'the image is now a second device, mounted as /mnt/' + VOL)
    t.hold(2.0)

    t.say('Its volume is just another directory. List it, read it.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('ls /mnt/' + VOL, 'ls')
    t.expect(H.columns_to_names(t.output('ls')) == names,
             'ls shows exactly the files the image was built with')
    t.run_cmd_echoed('cat /mnt/%s/%s' % (VOL, READ_NAME), 'cat')
    t.expect_lines(read_text.rstrip('\n').split('\n'),
                   'cat reads the file out of the image')
    t.hold(2.0)

    t.say('Copy a file out to the boot disk, then let the image go.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('cp /mnt/%s/%s here' % (VOL, COPY_NAME), 'cp out')
    t.expect_lines(0, 'cp prints nothing')
    t.run_cmd_echoed('umount /mnt/' + VOL, 'umount')
    t.expect_lines(0, 'umount detaches silently')
    t.run_cmd_echoed('mount', 'mount last')
    t.expect_lines(before, 'back to the boot disk alone')
    t.run_cmd_echoed('cat here', 'cat copy')
    t.expect_lines(copy_text.rstrip('\n').split('\n'),
                   'the copy survived the image')
    t.say('Two volumes, no second drive, and nobody swapping disks.')
    t.poster()
    t.hold(1.0)
