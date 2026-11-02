"""W10 -- unpack a ShrinkIt archive from the wild (docs/SITE.md sec 4).

VBLSET.SHK is a real archive: Doug Reeder's VBL clock utilities, 1990,
fetched from the asimov.net mirror (fixtures/PROVENANCE.md). maux lists
it, unpacks it with nulib2 onto the hard disk, shows the files, and
reads the documentation out of it with more.

The archive is the oracle. a2til (an independent NuFX reader) lists the
records; the machine's `nulib2 -v` rows, the directory listing after
`nulib2 -x`, and the text `more` prints must all agree with it. The
image is build/demo-unpack.po (scripts/build_demo_images.py): play.po
plus /ARC/VBLSET.SHK, the same bytes check-unpack extracts.
"""
import os
import sys

import demo_host as H

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import nufx  # noqa: E402

DEMO = dict(
    name='unshrink',
    title='Unpack a ShrinkIt archive from the wild',
    backends=('text80', 'ut'),
    image='unpack',
    gate='check-demo-unshrink',
)

ARCHIVE = os.path.join(H.ROOT, 'fixtures', 'asimov', 'VBLSET.SHK')
TYPES = {0x04: 'TXT', 0x06: 'BIN'}
DOC = 'SET.TIME.DOC'      # stored LZW/1, not plain
BIN = 'SET.TIME'          # likewise: 7,438 bytes of program
WIDTH = 80


def records():
    out = []
    with nufx.NufxArchive(ARCHIVE) as arc:
        for r in arc.records:
            name = ''.join(chr(ord(c) & 0x7F) for c in r.pathname)
            out.append((name, TYPES[r.file_type & 0xFF],
                        len(arc.read_file(r.pathname)),
                        '$%04X' % (r.extra_type & 0xFFFF),
                        arc.read_file(r.pathname),
                        r.data_thread.thread_format != 0))
    return out


def screen_rows(data):
    """What `more` shows of a text file: its lines (CR ends, high bit
    set as ProDOS keeps text), each wrapped at the screen width."""
    s = ''.join(chr(b & 0x7F) for b in data).replace('\r', '\n')
    rows = []
    lines = s.split('\n')
    if lines[-1] == '':
        lines.pop()                 # the newline that ended the file
    for line in lines:
        rows.extend([line[i:i + WIDTH] for i in range(0, len(line), WIDTH)]
                    or [''])
    return rows


def run(t):
    recs = records()
    names = sorted(r[0] for r in recs)
    doc = [r for r in recs if r[0] == DOC][0]
    prog = [r for r in recs if r[0] == BIN][0]
    t.expect(doc[5] and prog[5],
             'host: the two files the demo checks are LZW-compressed in '
             'the archive, so only a working decompressor gets them right')

    t.say('Thirty years of Apple II software lives in ShrinkIt archives.')
    t.say('This one is real: Doug Reeder\'s VBL clock utilities, 1990.')
    t.say('Fetched from the wild in 2026.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('cd /mnt/MAUX/OUT', 'cd')
    t.run_cmd_echoed('nulib2 -v /mnt/MAUX/ARC/VBLSET.SHK', 'list')
    rows = [r.split() for r in t.output('list', 60)]
    t.expect(rows == [[ty, str(n), aux, name]
                      for name, ty, n, aux, _, _z in recs],
             'the machine lists the same records, types and sizes as '
             'an independent reader of the archive')
    t.hold(3.0)

    t.say('nulib2 -x unpacks it. LZW decompression on a 6502.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('nulib2 -x /mnt/MAUX/ARC/VBLSET.SHK', 'extract')
    with t.fast(10):
        t.expect_lines(0, 'nulib2 -x says nothing and the prompt is back',
                       seconds=300)
    t.say('ProDOS names run to 15 characters, and not one more.')
    t.run_cmd_echoed('ls', 'ls')
    t.expect(H.columns_to_names(t.output('ls')) == names,
             'ls shows exactly the archive\'s files')
    t.hold(3.0)

    t.say('Two files that came out of the compressor: checksums first.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('cksum %s %s' % (BIN, DOC), 'cksum')
    rows = [r.split() for r in t.output('cksum')]
    want = []
    for rec in (prog, doc):
        crc, n = H.cksum(rec[4])
        want.append([str(crc), str(n), rec[0]])
    t.expect(rows == want, 'cksum of the two unpacked files equals the '
             'host\'s checksum of the archive\'s own bytes')
    t.hold(3.0)

    t.say('And the documentation, straight from the archive.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('more ' + DOC, 'more')
    t.expect_lines(screen_rows(doc[4]), 'the documentation record comes '
                   'out row for row')
    t.poster()
    t.hold(4.0)
