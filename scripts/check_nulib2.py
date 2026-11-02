#!/usr/bin/env python3
"""check-nulib2 -- `nulib2 -t` lists a real NuFX archive correctly.

Slice 1 of docs/NUFX.md. The tool parses the master header, every record
header and every thread record, checks the two header CRCs, and prints one
row per record. It decompresses nothing; this gate proves the WALK, which
is where a NuFX reader actually breaks.

WHY THE FIXTURES LOOK LIKE THIS. Every case here exists because
learning:01M0KZQJTHDP01FKPNP1HTWDW7 names a specific trap, and a fixture
that does not contain the trap cannot fail on it:

  * `comp_thread_eof` vs `thread_eof` -- ANY archive a2til or nulib2 writes
    has an over-allocated filename thread (eof=9, comp=32) and a comment
    thread that is 200 bytes of pure padding (eof=0, comp=200). A reader
    advancing by the wrong field desyncs at the SECOND record, so the
    multi-record fixture is what catches it and a one-file archive is not.
  * `attrib_count` as the tail authority -- the option-list fixture has a
    record whose header tail is longer than the usual 60 bytes, so a reader
    that hardcodes the filename_length offset reads garbage.
  * the name in a THREAD, not the header -- what every modern writer does.

The ORACLE is a2til's own reader, which is a second independent
implementation cross-checked against NuLib2 upstream. Expected rows are
computed from it in the same run rather than typed in, so the gate cannot
drift from the format; what is typed in is only the COLUMN LAYOUT, which
is maux's own choice.

Never the archive's own CRC alone: learning:01M0M67H5Y79780K1KY69W8PTN is
the case where an archive is self-consistently wrong.
"""
import hashlib
import os
import shutil
import struct
import subprocess


def crc16_xmodem(data, seed):
    """CRC-16/XMODEM: poly $1021, MSB first, no final xor.

    Written out here rather than imported from a2til, so the gate's
    expectation does not come from the same code as the oracle's.
    """
    c = seed
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 \
                else (c << 1) & 0xFFFF
    return c
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import check_vi as V                                      # noqa: E402
import hostoracle as HO                                   # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR     # noqa: E402
from a2til import nufx, prodos                            # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

import datetime                                           # noqa: E402

#: Fixed, because build/play.po is compared byte-for-byte between two
#: builds by check-release-image. A fixture carrying `datetime.now()`
#: would make that comparison fail once a minute.
WHEN = datetime.datetime(2026, 9, 21, 12, 0, 0)

#: (name, file_type, aux_type, body). Types chosen to walk every branch of
#: nulib2's type column: two that have a mnemonic, one that does not.
FILES = [
    ('AAA.TXT', 0x04, 0x0000, b'alpha\r'),
    ('BBB.BIN', 0x06, 0x2000, b'\x01\x02\x03\x04'),
    ('CCC.REL', 0xF8, 0x0000, b'x' * 300),
]

#: What `-a` compresses. Runs and zero padding are what RLE is FOR --
#: Lesson 9: "If more or all of a disk track is empty, RLE is a win,
#: but it just doesn't happen all that often in text files." The $DB
#: run is the escape byte itself, and its length mod 256 is 1: that is
#: exactly the case NufxLib's own encoder gets wrong (a 257-byte run
#: round-trips to 8 bytes through its own tools), so this fixture
#: fails if maux copies the reference's bug.
RLEBODY = (b'Z' * 3000 + b'\xdb' * 257 + b'the quick brown fox. ' * 40
           + b'\x00' * 1500)
RLENAME = 'RLE.BIN'


def _lcg(n, seed=20260921):
    """Incompressible bytes, from an explicit LCG rather than
    random.Random: a gate fixture has to be the same bytes on every
    host and every Python, and `random` promises that only by
    convention."""
    out = bytearray()
    x = seed
    for _ in range(n):
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        out.append((x >> 16) & 0xFF)
    return bytes(out)


def _lzwbody():
    """One thread that reaches all FOUR shapes an LZW/2 chunk has,
    which no fixture taken from a real archive managed.

    The blocks after the first are 4096-aligned on purpose: a chunk
    is what the format switches on, so a block that straddles two of
    them proves nothing about either. Measured with a model of the
    encoder before it was written -- 5 LZW chunks, 1 RLE-only, 1
    stored, and the table filling to 4096 entries once, which is the
    only path that emits a clear code.
    """
    w = [('%s%d' % (s, i)).encode('ascii')
         for i in range(400) for s in ('alpha', 'beta', 'gamma', 'delta')]
    varied = b' '.join(w) + b'\r'
    varied += b'filler line for alignment\r' * 40
    varied = varied[:len(varied) // 4096 * 4096]
    # random bytes carrying a periodic run: RLE gains, LZW cannot,
    # which is the only way an RLE-ONLY chunk survives the choice
    mixed = bytearray()
    src = _lcg(6000, 999)
    i = 0
    while len(mixed) < 4096:
        mixed += src[i:i + 10]
        mixed += bytes([src[i + 10]]) * 8
        i += 11
    return (varied + _lcg(4096) + bytes(mixed[:4096]) + b'Q' * 4096
            + b'the quick brown fox jumps over the lazy dog. ' * 90)


def _rleonly_size(data):
    """What this fixture would cost as an RLE-only LZW/2 thread --
    stage 1's whole output. It is the floor the LZW layer has to beat
    for the `lzw` case to mean anything."""
    total = 2                                   # the stream header
    for off in range(0, len(data), 4096):
        wl = len(data) - off
        wl = 4096 if wl > 4096 else wl
        raw = data[off:off + wl] + b'\x00' * (4096 - wl)
        out, i = 0, 0
        while i < 4096:
            v = raw[i]
            j = i
            while j < 4096 and raw[j] == v and j - i < 256:
                j += 1
            out += 3 if (j - i >= 4 or v == 0xDB) else j - i
            i = j
        total += 2 + (out if out < 4096 else wl)
    return total


def _chunk_census(payload, eof):
    """Walk an LZW/2 stream's chunk headers and count the shapes.

    This is a FRAMING check as much as a census: LZW/1 and LZW/2 do not
    agree about the shape of either header -- LZW/1 spends four bytes on
    a stream header with a CRC and a whole byte on each chunk's flag,
    LZW/2 spends two and puts the flag in bit 15 of rle_len -- so a walk
    that lands exactly on the end of the thread has read the format the
    thread claims to be. It also reports the bytes it did not consume,
    because a walk that ends early is how a wrong shape LOOKS.
    """
    kinds = {'lzw': 0, 'rle': 0, 'stored': 0}
    i, left = 2, eof                       # past disk_volume, rle_escape
    while left > 0 and i + 2 <= len(payload):
        hdr = int.from_bytes(payload[i:i + 2], 'little')
        i += 2
        rlen = hdr & 0x1FFF                # 13 bits; bit 15 is the flag
        wl = 4096 if left > 4096 else left
        if hdr & 0x8000:
            body = int.from_bytes(payload[i:i + 2], 'little') - 4
            i += 2
            kinds['lzw'] += 1
        elif rlen == 4096:
            body = wl                      # stored: only the real bytes
            kinds['stored'] += 1
        else:
            body = rlen
            kinds['rle'] += 1
        i += body
        left -= wl
    return kinds, len(payload) - i


LZWBODY = _lzwbody()
LZWNAME = 'LZW.BIN'
#: sha256 of the compressed thread payload `nulib2 -a` writes for
#: LZWBODY, taken from the binary BEFORE docs/NUFX-LC.md's move
#: (base d6a8bab). The file's own header carries the clock, so the
#: payload is what can be pinned.
LZWP_SHA256 = ('9467985b980f87fdc8d24a5f1670e08b5b9d591271d918b664080a62975b86a6')
ARCPATH = '/mnt/MAUX/T.SHK'
BADPATH = '/mnt/MAUX/BAD.SHK'
BXYPATH = '/mnt/MAUX/B.BXY'
NOTARC = '/mnt/MAUX/NOTARC'
LZPATH = '/mnt/MAUX/L.SHK'

#: An LZW/1 archive, recorded rather than generated, and the reason is
#: independence. a2til reads every ShrinkIt codec but WRITES only LZW/2
#: and stored, so there is no way to build an LZW/1 fixture from the
#: house tools. Writing an encoder here would test the 6502 decoder
#: against a second implementation by the same author on the same day,
#: which proves nothing (the commons' own warning about verifying a
#: local tool against itself).
#:
#: So these bytes come from NufxLib's own encoder, via the `launder`
#: sample that ships with nulib2 -- genuinely independent of everything
#: in this tree -- and a2til, a third implementation, decodes them at
#: gate time to say what the answer is. Reproduce with:
#:
#:   python3 -c "open('LZ.TXT','wb').write(b'abcdefghij'*500 +
#:       b'Q'*3000 + b'the quick brown fox. '*60)"
#:   nulib2 -a -0 b2.shk LZ.TXT
#:   launder -m lzw1 b2.shk L.shk
#:
#: The content is chosen to make the decoder work: 9,260 bytes is THREE
#: chunks with a partial last one (so the final chunk's zero padding is
#: exercised, and with it the stream CRC over padded bytes), the 3,000
#: `Q` bytes force the RLE layer, and the repeated text makes the LZW
#: table fill and the code width grow past 9 bits.
LZ_ARCHIVE_B64 = (
    'TvVG6WzlRyQBAAAABRMRfhQIAAIFExF+FAgAAgIAAAAAAAAAAADBBAAAAAAAAAAA'
    'TvVG2AsxPAADAAMAAAAAADoA4wAAAAAAAAAAAAAAAgAFExF+FAgAAgUTEX4UCAAC'
    'BRMRfhQIAAIAAAAAAwAAAAAAAAAGAAAAIAAAAAAAAAABAAAAAAAAAMgAAAACAAIA'
    'AADQoiwkAAA9AwAATFouVFhUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAMag/tsAEAFhxIwhU8bMGTRp1AQcWPBgwoUEDSJUKDCiQ4oMJT6s2HAixI4b'
    'M178qBGjRY8cS5IcmZKlSJQvQ56UCdJkzZUwZ9pU2TLnzZ40ecbc6VInzqBFfw49'
    'StSnUKNAmyJ1mvSpUqhLozLdqrVr1q9Yw14da7Vs1bNU005dK7UtV7Bk0bJ9K9as'
    'Wrde68rFC9fu3Lxx79IN/Lfv3sF++eoVDDgx4sONIRtmPLnwYsuEFWd+TPmyZseR'
    'O28OjRl05c+SPXMunXr06dWoRZtWTTo2a9mtZ7um/bo27N++g/cezrv47uO6k+de'
    'jrv57ee2owMnjpw59OnGlTuXLjy7de7UtV/vXn079vLjw38/Lx68d/Pk27NfH5++'
    'evj307/Xj959//nw288/+eoL8L8C+SMwvwHtExDABBs8cMEHGTRQQQcR3AlsBAFn'
    '0KRRE0bMGDJlzAQcWPBgwoUEDSJUKDCiQ4oMJT6s2HAixI4bM178qBGjRY8cS5Ic'
    'mZKlSJQvQ56UCdJkzZUwZ9pU2TLnzZ40ecbc6VInzqBFfw49StSnUKNAmyJ1mvSp'
    'UqhLozLdqrVr1q9Yw14da7Vs1bNU005dK7UtV7Bk0bJ9K9asWrde68rFC9fu3Lxx'
    'c26L8m9wYcKGEyNefLix4lt00JQBEadOmjFrQIiR8+aOGxBm3uBxASLy5MqXM2/u'
    '/Dn06NKSKVvGrJmzZ9CiSZuWnbo2a9yvd6Omvfq2a92xh6u23To37NOzl/8+/pw3'
    'cebAkUPvXbx5cMlQBAEg4tRJM2YNCDFy3txxA8LMGzwuQNBBUybgwIIHEy5s+DDi'
    'xIoCCRpEqJChQ4gSKVoUmbEkR5QfV2IkufGkR5UhZ2o02TElyIsjd768+ZMlTZ4w'
    'cQJtWbNnzJxBXdr0KTNq06RFdUp1qtSo0KlPlx4dShUqU6REq54lG9brVqxqx4Lt'
    'qvVqWrNyuWa1iras2K964wKGi3fw3b9vD7u163dx37Z1H9Ply3by2rl7LwcunLhx'
    '5MqZ8xJGzBgyZcyCO5vWPNox6NSlLYtW/Bk159ihDXs+vZm05NyqZetePXs3a9q8'
    'UW4D8G95c+bOo0Of/ry69Gk='
)
LZ_NAME = 'LZ.TXT'

L2PATH = '/mnt/MAUX/M.SHK'

#: An LZW/2 archive, recorded the same way and for the same reason.
#: `launder -m lzw2` is NufxLib's own encoder; a2til decodes at gate
#: time to say what the answer is; `nulib2 -i` accepted it, which makes
#: NufxLib a witness that its own decoder agrees with a2til's.
#:
#:   python3 -c "import random; random.seed(11); w=['alpha','bravo',
#:       'charlie','delta','echo','foxtrot','golf','hotel','india',
#:       'juliet','kilo','lima']; o=[]
#:       ...append random.choice(w) until 30000 bytes..."
#:   nulib2 -a -0 b4.shk W2.TXT
#:   launder -m lzw2 b4.shk L2F.shk
#:
#: THIRTY THOUSAND BYTES, AND THAT NUMBER IS THE WHOLE POINT.
#: learning:01M0KZQJTHDP01FKPNP1HTWDW7 warns that "a corpus of small
#: files exercises LZW/2's clear-code path exactly zero times", and
#: measuring it here confirmed the warning exactly: the same generator
#: at 16,000, 20,000 and 24,000 bytes clears the table ZERO times, and
#: only at 30,000 does it clear once. A fixture below that threshold
#: tests a decoder that cannot see LZW/2's defining feature.
#:
#: What the eight chunks reach, read off the headers: LZW on every
#: chunk, the table carried across all of them, one clear, RLE on the
#: last chunk only (rle_len 1361 expanding to 4096), and a partial
#: final write of 1328 bytes.
L2_ARCHIVE_B64 = (
    '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'
    'tNBI+/wM'
)
L2_NAME = 'W2.TXT'

#: Slice 8 (.SDK): a 280-block ProDOS volume, built with a2til, holding
#: files that reach every chunk shape CHUNKPREP chooses between --
#: text (compressible), all 256 byte values (little redundancy), a
#: long run of one byte (the empty-track case Lesson 9 names) and a
#: file spanning several 4 KB chunks -- with the rest of the volume's
#: blocks left untouched, exactly as a real floppy would look.
SDK_VOLNAME = 'FLOPPY'
SDK_BLOCKS = 280
SDK_IMGNAME = 'FLOP.IMG'
SDK_TEXT = b'the quick brown fox jumps over the lazy dog.\r' * 40
SDK_ALL256 = bytes(range(256)) * 12
SDK_RUN = b'\x00' * 4000
SDK_BIG = _lcg(9000, 20260927)
SDKPATH = '/mnt/MAUX/FLOP.SDK'
SDK0PATH = '/mnt/MAUX/FLOP0.SDK'


def build_floppy_image(path):
    """Write a 280-block ProDOS volume to `path` and return its bytes.

    a2til's `prodos.create` + `Volume.write_file` -- the house tool
    for disk images (HACKING.md: never hand-roll one) -- laid out with
    the same fixture shapes the writer's compressor fixture already
    uses, so this is the fixture that already exists for the writer,
    laid into a volume (docs/NUFX.md slice 8's own words for it).
    """
    prodos.create(path, name=SDK_VOLNAME, blocks=SDK_BLOCKS)
    with prodos.Volume(path) as vol:
        vol.write_file('/TEXT.TXT', SDK_TEXT, file_type=0x04,
                        overwrite=True)
        vol.write_file('/ALL256.BIN', SDK_ALL256, file_type=0x06,
                        overwrite=True)
        vol.write_file('/RUN.BIN', SDK_RUN, file_type=0x06,
                        overwrite=True)
        vol.write_file('/BIG.BIN', SDK_BIG, file_type=0x06,
                        overwrite=True)
    with open(path, 'rb') as f:
        return f.read()


def check_sdk_archive(tmp, arc_bytes, sdk_bytes, label, fails):
    """The host oracles slice 8 names, run against one exported
    archive (a plain '-a' or a '-0' one): a2til's disk_record.read()
    byte-identical, real nulib2 -v shows a Disk row, real nulib2 -x
    extracts the image byte-identical, real nulib2 -i is clean.
    """
    p = os.path.join(tmp, label + '.SDK')
    with open(p, 'wb') as f:
        f.write(arc_bytes)
    print('[check-nulib2] %s: archive is %d bytes for %d bytes of image'
          % (label, len(arc_bytes), len(sdk_bytes)))
    try:
        with nufx.NufxArchive(p) as arc:
            rec = arc.disk_record
            if rec is None:
                fails.append('%s: a2til does not see a single disk '
                             'record in this archive' % label)
                got_img = None
            else:
                got_img = rec.read()
    except Exception as exc:
        fails.append('%s: a2til refuses the archive: %s' % (label, exc))
        got_img = None
    if got_img is not None:
        if got_img != sdk_bytes:
            where = next((i for i in range(min(len(got_img), len(sdk_bytes)))
                          if got_img[i] != sdk_bytes[i]),
                         min(len(got_img), len(sdk_bytes)))
            fails.append('%s: a2til disk_record.read() gave %d bytes, '
                         'expected %d; first difference at %d'
                         % (label, len(got_img), len(sdk_bytes), where))
        else:
            print('[check-nulib2] %s: a2til disk_record.read() is '
                  'byte-identical to the image' % label)
    try:
        r = subprocess.run(['nulib2', '-v', p], capture_output=True,
                           timeout=30)
    except FileNotFoundError:
        HO.skip('check-nulib2', '%s: nulib2(1) not installed, skipping '
                '-v/-x/-i' % label, fails)
        return
    except subprocess.TimeoutExpired:
        fails.append('%s: nulib2 -v HUNG on it' % label)
        return
    out = r.stdout.decode('latin-1')
    if r.returncode != 0 or 'Disk' not in out:
        fails.append('%s: nulib2 -v does not show a Disk row: %r'
                     % (label, out[:300]))
    else:
        print('[check-nulib2] %s: nulib2 -v shows a Disk row' % label)
    xdir = os.path.join(tmp, label + '_x')
    os.makedirs(xdir, exist_ok=True)
    try:
        r = subprocess.run(['nulib2', '-x', os.path.abspath(p)],
                           capture_output=True, timeout=60, cwd=xdir)
        if r.returncode != 0:
            fails.append('%s: nulib2 -x failed: %s'
                         % (label, r.stderr.decode('latin-1')[:200]))
        else:
            xfiles = os.listdir(xdir)
            if len(xfiles) != 1:
                fails.append('%s: nulib2 -x wrote %r, expected one file'
                             % (label, xfiles))
            else:
                with open(os.path.join(xdir, xfiles[0]), 'rb') as f:
                    xgot = f.read()
                if xgot != sdk_bytes:
                    fails.append('%s: nulib2 -x extracted %d bytes, '
                                 'expected %d byte-identical'
                                 % (label, len(xgot), len(sdk_bytes)))
                else:
                    print('[check-nulib2] %s: nulib2 -x extracts the '
                          'image byte-identical' % label)
    except subprocess.TimeoutExpired:
        fails.append('%s: nulib2 -x HUNG on it' % label)
    try:
        r = subprocess.run(['nulib2', '-i', p], capture_output=True,
                           timeout=30)
        if r.returncode != 0:
            fails.append('%s: nulib2 -i rejects it: %s'
                         % (label, r.stderr.decode('latin-1')[:200]))
        else:
            print('[check-nulib2] %s: nulib2 -i verifies it' % label)
    except subprocess.TimeoutExpired:
        fails.append('%s: nulib2 -i HUNG on it' % label)


def build_fixture(path):
    """One archive holding FILES, written by a2til."""
    nufx.create(path, when=WHEN)
    with nufx.NufxArchive(path, readonly=False) as arc:
        for name, ftype, aux, body in FILES:
            arc.write_file('/' + name, body, file_type=ftype, aux_type=aux)


def expected_names(path):
    """What `nulib2 -t` must print: bare names, one per line.

    nulib2's own `-t` is "the filenames, one per line, without any
    truncation or embellishment -- useful for feeding into another
    program", and this is that. The decorated listing is `-v`.
    """
    with nufx.NufxArchive(path) as arc:
        return [e.name for e in arc.scandir('/')]


def expected_rows(path):
    """What `nulib2 -v` must print, derived from a2til rather than typed.

    The COLUMN LAYOUT is maux's own (`TTT SSSSSSSS $AAAA NAME`, ls -l's
    discipline rather than ShrinkIt's); the VALUES come from the oracle.
    """
    mnemonic = {0x04: 'TXT', 0x06: 'BIN', 0x0F: 'DIR', 0xFF: 'SYS',
                0xFC: 'BAS'}
    rows = []
    with nufx.NufxArchive(path) as arc:
        for entry in arc.scandir('/'):
            ttt = mnemonic.get(entry.type, '$%02X' % entry.type)
            rows.append('%-3s %8d $%04X %s'
                        % (ttt, entry.size, entry.aux_type, entry.name))
    return rows


def run(disk, cmds, want, fails, label, disk2=None, unit2=2, steps=600):
    """Type each of `cmds`; require exactly `want` below the LAST one.

    `disk2`, when given, is mounted as a SECOND SmartPort unit (default
    slot/drive 2, i.e. `/dev/s7d2` -- check_devblk.py's own pattern)
    beside `disk`'s unit 1, for the `sdkdev` case: `nulib2 -a` reading
    straight from a device rather than a file.

    `steps` (each 200,000 cycles) widens the wait for a command whose
    own cost scales with the input -- `sdk0`'s stored 140K copy goes
    through XBUFSZ-sized chunks, smaller than a compressed pass's 4096
    bytes (docs/NUFX-SDK-NOTES.md: XBUFSZ was cut for arena room), so
    it needs more of them than the default budget covers.
    """
    c = MCPClient([SUPERVISOR], dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR))
    try:
        c.initialize()
        c.call_tool('reset', {'backend': 'fast', 'aux': 'ramworks'})
        r = c.call_tool('mount_disk', {'path': disk, 'unit': 1})
        if r.get('ok') is False:
            raise RuntimeError('mount_disk failed: %r' % (r,))
        if disk2 is not None:
            r = c.call_tool('mount_disk', {'path': disk2, 'unit': unit2})
            if r.get('ok') is False:
                raise RuntimeError('mount_disk (unit2) failed: %r' % (r,))

        def at(rows):
            nb = [x for x in rows if x.strip()]
            return bool(nb) and nb[-1].strip().endswith('$')

        V.settle(c, at, 'shell prompt', max_steps=3000)

        def below(rows):
            i = -1
            for n, row in enumerate(rows):
                if cmd[:36] in row:
                    i = n
            if i < 0:
                return None
            out = [x.rstrip() for x in rows[i + 1:]]
            return [x for x in out if x.strip() and x.strip() != '$'
                    and not x.strip().endswith('$')]

        for pre in cmds[:-1]:
            V.t(c, pre + '\r')
            for _ in range(steps):
                c.call_tool('step', {'cycles': 200_000})
                if at(V.rows(c)):
                    break
        cmd = cmds[-1]
        V.t(c, cmd + '\r')
        got = None
        prev = object()
        for _ in range(steps):
            c.call_tool('step', {'cycles': 200_000})
            rows = V.rows(c)
            if not at(rows):
                continue
            now = below(rows)
            if now is not None and now == prev:
                got = now
                break
            prev = now
        if got != want:
            fails.append('%s: `%s` printed\n    %r\n  expected\n    %r'
                         % (label, cmd, got, want))
        elif want:
            print('[check-nulib2] %s: %d row(s) match the oracle'
                  % (label, len(want)))
        else:
            print('[check-nulib2] %s: silent, as it must be' % label)
    finally:
        try:
            c.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        if disk2 is not None:
            try:
                c.call_tool('eject_disk', {'unit': unit2})
            except Exception:
                pass
        c.close()


def main():
    fails = []
    tmp = tempfile.mkdtemp(prefix='maux-nulib2-')
    disk = os.path.join(tmp, 'nulib2.po')
    arc = os.path.join(tmp, 'T.SHK')
    shutil.copyfile(V.DISK, disk)
    build_fixture(arc)
    want = expected_rows(arc)
    names = expected_names(arc)
    print('[check-nulib2] oracle (a2til) names: %r' % (names,))
    print('[check-nulib2] oracle (a2til) says:')
    for row in want:
        print('    %s' % row)

    with open(arc, 'rb') as f:
        blob = f.read()

    # -- A DAMAGED COPY, for `-i`. One byte of the last record's data
    # -- fork is flipped, which leaves every header and both header
    # -- CRCs intact and breaks only that record's thread CRC -- so a
    # -- reader that skips the thread CRC finds nothing wrong, which
    # -- is precisely what this case exists to catch.
    bad = bytearray(blob)
    bad[-5] ^= 0xFF
    bad = bytes(bad)

    # -- A .BXY: the same archive behind 128 bytes of Binary II. The
    # -- wrapper's own contents do not matter to this reader; what
    # -- matters is that it does not give up when the master header
    # -- is not at offset 0.
    bxy = b'\x0a\x47\x4c' + bytes(125) + blob
    prodos.mount(disk, replace=True)
    try:
        prodos.write(ARCPATH, blob, file_type=0xE0, aux_type=0x8002,
                     overwrite=True)
        prodos.write(BADPATH, bad, file_type=0xE0, aux_type=0x8002,
                     overwrite=True)
        prodos.write(BXYPATH, bxy, file_type=0xE0, aux_type=0x8000,
                     overwrite=True)
        # -- Not an archive at all. This case exists because the
        # -- source once carried a comment saying a gate enforced
        # -- that the three LISTARC messages shared a page -- and no
        # -- such gate was ever written. Renaming the program added
        # -- one character to each message, pushed two onto the next
        # -- page, and this path printed two bytes of garbage. A
        # -- comment claiming a test is not a test.
        prodos.write(NOTARC, b'this is not a NuFX archive at all\r',
                     file_type=0x04, aux_type=0, overwrite=True)
        prodos.write('/mnt/MAUX/' + RLENAME, RLEBODY, file_type=0x06,
                     aux_type=0x1234, overwrite=True)
        prodos.write('/mnt/MAUX/' + LZWNAME, LZWBODY, file_type=0x06,
                     aux_type=0x4321, overwrite=True)
    finally:
        prodos.unmount('MAUX')

    # Every row is prefixed with one space by nulib2; a record whose header
    # CRC failed gets '!' there instead. The oracle rows carry neither, so
    # the space is added here rather than in expected_rows() -- that column
    # is maux's own signal, not something the format has an opinion about.
    # -- `-t` is the pipe-friendly form and `-v` the decorated one,
    # -- which is the way round nulib2 has them. Checked separately,
    # -- because getting them backwards is invisible to any test that
    # -- only looks at one of the two.
    run(disk, ['nulib2 -t ' + ARCPATH], names, fails, 'names')
    # -- Binary II: the same three names, through 128 bytes of wrapper.
    run(disk, ['nulib2 -t ' + BXYPATH], names, fails, 'binary2')
    # -- `-i` is SILENT on a good archive and names the record on a bad
    # -- one. It must not prompt: nulib2 asks "Archive may be damaged,
    # -- continue anyway? [y]es, [n]o" and a tool that blocks on input
    # -- cannot be used in a pipeline.
    run(disk, ['nulib2 -t ' + NOTARC],
        ['nulib2: not a NuFX archive'], fails, 'not-an-archive')
    run(disk, ['nulib2 -i ' + ARCPATH], [], fails, 'verify-good')
    run(disk, ['nulib2 -i ' + BADPATH],
        ['nulib2: CCC.REL: thread CRC mismatch'], fails, 'verify-bad')
    run(disk, ['nulib2 -v ' + ARCPATH], [' ' + r for r in want], fails,
        'list')

    # -- EXTRACTION, checked against the archive's own bytes rather
    # -- than against anything typed here. `-x` writes into the
    # -- current prefix, so the run cds into a fresh directory; the
    # -- files are then read back off the image with a2til and
    # -- compared byte-for-byte, WITH their ProDOS type and aux.
    # -- Those two are the point: CREAT makes an unlocked TXT
    # -- seedling, so a BIN record that came back $04 would mean
    # -- STAMP never ran -- and on ProDOS the type is where "can
    # -- this be run?" lives, while maux's spawn loads a binary AT
    # -- ITS AUX. An extractor that drops them produces files that
    # -- look right in a listing and cannot be used.
    # -- LZW/1, the ProDOS 8 ShrinkIt case. Same shape: extract on the
    # -- machine, read back with a2til, compare byte-for-byte. The
    # -- expected plaintext is what a2til says the archive holds, not
    # -- anything typed here.
    import base64
    lzblob = base64.b64decode(''.join(LZ_ARCHIVE_B64))
    lzarc = os.path.join(tmp, 'L.SHK')
    with open(lzarc, 'wb') as f:
        f.write(lzblob)
    with nufx.NufxArchive(lzarc) as arc:
        lzwant = arc.read_file('/' + LZ_NAME, fork='data')
    print('[check-nulib2] oracle (a2til) expands the LZW/1 fork to %d '
          'bytes' % len(lzwant))
    prodos.mount(disk, replace=True)
    try:
        prodos.write(LZPATH, lzblob, file_type=0xE0, aux_type=0x8002,
                     overwrite=True)
    finally:
        prodos.unmount('MAUX')

    l2blob = base64.b64decode(''.join(L2_ARCHIVE_B64))
    l2arc = os.path.join(tmp, 'M.SHK')
    with open(l2arc, 'wb') as f:
        f.write(l2blob)
    with nufx.NufxArchive(l2arc) as arc:
        l2want = arc.read_file('/' + L2_NAME, fork='data')
    print('[check-nulib2] oracle (a2til) expands the LZW/2 fork to %d '
          'bytes' % len(l2want))
    prodos.mount(disk, replace=True)
    try:
        prodos.write(L2PATH, l2blob, file_type=0xE0, aux_type=0x8002,
                     overwrite=True)
    finally:
        prodos.unmount('MAUX')

    # -- `-p` concatenates every fork to stdout, exactly as nulib2's
    # -- does: no names, no separators. Redirected to a file so the
    # -- bytes can be compared rather than read off a screen.
    run(disk, ['nulib2 -p ' + ARCPATH + ' > /mnt/MAUX/PIPED'], [], fails,
        'pipe')

    run(disk, ['mkdir /mnt/MAUX/X', 'cd /mnt/MAUX/X',
               'nulib2 -x ' + ARCPATH,
               'nulib2 -x ' + LZPATH,
               'nulib2 -x ' + L2PATH], [], fails, 'extract')
    prodos.mount(disk, replace=True, readonly=True)
    try:
        for name, ftype, aux, body in FILES:
            try:
                got = prodos.read('/mnt/MAUX/X/' + name)
                st = prodos.stat('/mnt/MAUX/X/' + name)
            except Exception as exc:
                fails.append('extract: /mnt/MAUX/X/%s was not written: %s'
                             % (name, exc))
                continue
            if got != body:
                fails.append('extract: %s is %r, expected %r'
                             % (name, got[:40], body[:40]))
            elif st.type != ftype or st.aux_type != aux:
                fails.append('extract: %s came back type $%02X aux $%04X, '
                             'expected $%02X/$%04X -- CREAT makes a TXT '
                             'seedling, so this means STAMP did not run'
                             % (name, st.type, st.aux_type, ftype, aux))
            else:
                print('[check-nulib2] extract: %s %d byte(s), type $%02X '
                      'aux $%04X' % (name, len(got), st.type, st.aux_type))
        try:
            piped = prodos.read('/mnt/MAUX/PIPED')
        except Exception as exc:
            piped = None
            fails.append('pipe: /mnt/MAUX/PIPED was not written: %s' % exc)
        want_pipe = b''.join(body for _n, _t, _a, body in FILES)
        if piped is not None and piped != want_pipe:
            fails.append('pipe: -p wrote %d bytes, expected %d (every '
                         'fork concatenated, which is what nulib2 -p '
                         'does): %r vs %r'
                         % (len(piped), len(want_pipe), piped[:32],
                            want_pipe[:32]))
        elif piped is not None:
            print('[check-nulib2] pipe: -p wrote %d byte(s), every fork '
                  'concatenated' % len(piped))
        try:
            lzgot = prodos.read('/mnt/MAUX/X/' + LZ_NAME)
        except Exception as exc:
            lzgot = None
            fails.append('lzw1: /mnt/MAUX/X/%s was not written: %s'
                         % (LZ_NAME, exc))
        if lzgot is not None and lzgot != lzwant:
            where = next((i for i in range(min(len(lzgot), len(lzwant)))
                          if lzgot[i] != lzwant[i]), min(len(lzgot),
                                                         len(lzwant)))
            fails.append('lzw1: %s is %d bytes, expected %d; first '
                         'difference at offset %d (chunk %d, offset %d '
                         'into it): got %r expected %r'
                         % (LZ_NAME, len(lzgot), len(lzwant), where,
                            where // 4096, where % 4096,
                            lzgot[where:where + 8],
                            lzwant[where:where + 8]))
        elif lzgot is not None:
            print('[check-nulib2] lzw1: %s expanded to %d byte(s), '
                  'byte-identical across %d chunk(s)'
                  % (LZ_NAME, len(lzgot), (len(lzgot) + 4095) // 4096))
        try:
            l2got = prodos.read('/mnt/MAUX/X/' + L2_NAME)
        except Exception as exc:
            l2got = None
            fails.append('lzw2: /mnt/MAUX/X/%s was not written: %s'
                         % (L2_NAME, exc))
        if l2got is not None and l2got != l2want:
            where = next((i for i in range(min(len(l2got), len(l2want)))
                          if l2got[i] != l2want[i]), min(len(l2got),
                                                         len(l2want)))
            fails.append('lzw2: %s is %d bytes, expected %d; first '
                         'difference at offset %d (chunk %d, offset %d '
                         'into it): got %r expected %r'
                         % (L2_NAME, len(l2got), len(l2want), where,
                            where // 4096, where % 4096,
                            l2got[where:where + 8],
                            l2want[where:where + 8]))
        elif l2got is not None:
            print('[check-nulib2] lzw2: %s expanded to %d byte(s), '
                  'byte-identical across %d chunk(s) including a table '
                  'clear' % (L2_NAME, len(l2got),
                             (len(l2got) + 4095) // 4096))
    finally:
        prodos.unmount('MAUX')

    # -- COMPRESSING on the way out. A thread whose chunks are
    # -- run-length coded with the LZW flag clear is a valid LZW/2
    # -- thread; both readers have to expand it to the original bytes,
    # -- and the archive has to be smaller than the input or the verb
    # -- is pointless.
    run(disk, ['cd /mnt/MAUX',
               'nulib2 -a /mnt/MAUX/PACKED.SHK /mnt/MAUX/' + RLENAME],
        [], fails, 'compress')
    prodos.mount(disk, replace=True, readonly=True)
    try:
        packed = prodos.read('/mnt/MAUX/PACKED.SHK')
    except Exception as exc:
        packed = None
        fails.append('compress: /mnt/MAUX/PACKED.SHK not written: %s' % exc)
    finally:
        prodos.unmount('MAUX')
    if packed is not None:
        pp = os.path.join(tmp, 'PACKED.SHK')
        with open(pp, 'wb') as f:
            f.write(packed)
        try:
            with nufx.NufxArchive(pp) as arc:
                back = arc.read_file('/' + RLENAME, fork='data')
        except Exception as exc:
            back = None
            fails.append('compress: a2til refuses it: %s' % exc)
        if back is not None and back != RLEBODY:
            where = next((i for i in range(min(len(back), len(RLEBODY)))
                          if back[i] != RLEBODY[i]),
                         min(len(back), len(RLEBODY)))
            fails.append('compress: expands to %d bytes, expected %d; '
                         'first difference at %d: got %r expected %r'
                         % (len(back), len(RLEBODY), where,
                            back[where:where + 8],
                            RLEBODY[where:where + 8]))
        elif back is not None:
            if len(packed) >= len(RLEBODY):
                fails.append('compress: the archive is %d bytes for %d '
                             'bytes of input -- RLE bought nothing, so '
                             'either the coder is not running or the '
                             'fixture stopped being compressible'
                             % (len(packed), len(RLEBODY)))
            else:
                print('[check-nulib2] compress: %d bytes of input -> a '
                      '%d byte archive, expanding byte-identical'
                      % (len(RLEBODY), len(packed)))
        try:
            r = subprocess.run(['nulib2', '-i', pp], capture_output=True,
                               timeout=30)
            if r.returncode != 0:
                fails.append('compress: `nulib2 -i` rejects it: %s'
                             % r.stderr.decode('latin-1')[:200])
            else:
                print('[check-nulib2] compress: NufxLib verifies it too')
        except FileNotFoundError:
            print('[check-nulib2] compress: nulib2(1) not installed')
        except subprocess.TimeoutExpired:
            fails.append('compress: `nulib2 -i` HUNG on it')

    # -- THE LZW LAYER. Same verb, a fixture chosen to reach all four
    # -- chunk shapes, and an assertion that the codes actually ran
    # -- rather than that the output merely got smaller.
    run(disk, ['cd /mnt/MAUX',
               'nulib2 -a /mnt/MAUX/LZWP.SHK /mnt/MAUX/' + LZWNAME],
        [], fails, 'lzw')
    prodos.mount(disk, replace=True, readonly=True)
    try:
        lzwp = prodos.read('/mnt/MAUX/LZWP.SHK')
    except Exception as exc:
        lzwp = None
        fails.append('lzw: /mnt/MAUX/LZWP.SHK not written: %s' % exc)
    finally:
        prodos.unmount('MAUX')
    if lzwp is not None:
        lp = os.path.join(tmp, 'LZWP.SHK')
        with open(lp, 'wb') as f:
            f.write(lzwp)
        try:
            with nufx.NufxArchive(lp) as arc:
                lback = arc.read_file('/' + LZWNAME, fork='data')
        except Exception as exc:
            lback = None
            fails.append('lzw: a2til refuses it: %s' % exc)
        if lback is not None and lback != LZWBODY:
            where = next((i for i in range(min(len(lback), len(LZWBODY)))
                          if lback[i] != LZWBODY[i]),
                         min(len(lback), len(LZWBODY)))
            fails.append('lzw: expands to %d bytes, expected %d; first '
                         'difference at %d (chunk %d, offset %d in it): '
                         'got %r expected %r'
                         % (len(lback), len(LZWBODY), where, where // 4096,
                            where % 4096, lback[where:where + 8],
                            LZWBODY[where:where + 8]))
        elif lback is not None:
            # -- WHAT PROVES THE CODES RAN. "Smaller than the input"
            # -- does not: stage 1's run-length layer alone already
            # -- beat that. So the floor is what THIS fixture costs
            # -- with run-length coding and nothing else, computed
            # -- here rather than pinned as a number that would go
            # -- quietly stale the day the fixture changed.
            floor = _rleonly_size(LZWBODY)
            if len(lzwp) >= floor:
                fails.append('lzw: %d bytes, but run-length coding alone '
                             'reaches %d -- the LZW layer bought nothing, '
                             'so either it never ran or every chunk lost '
                             'the size comparison' % (len(lzwp), floor))
            else:
                print('[check-nulib2] lzw: %d bytes of input -> a %d byte '
                      'archive, expanding byte-identical (run-length '
                      'coding alone would need %d)'
                      % (len(LZWBODY), len(lzwp), floor))
        # -- WHICH FORMAT DID IT ACTUALLY WRITE. The round trip above
        # -- proves more than it looks: a2til expanded this thread with
        # -- its LZW/2 decoder, which CARRIES THE STRING TABLE ACROSS
        # -- CHUNKS. An encoder that reset its table every chunk -- that
        # -- is, an LZW/1 encoder wearing a $0003 label -- would hand
        # -- that decoder codes resolved against a table it no longer
        # -- has, and chunk two would come out as garbage. Byte-identical
        # -- across seven chunks is the table persisting. The census
        # -- below adds the framing: LZW/1 and LZW/2 disagree about the
        # -- size of both the stream header and every chunk header, so a
        # -- walk that lands exactly on the end of the thread is reading
        # -- the shape the thread declares.
        try:
            with nufx.NufxArchive(lp) as arc:
                th = [t for r in arc.records for t in r.threads
                      if t.thread_class == 2 and t.thread_kind == 0][0]
                fmt, census, slack = (th.thread_format,
                                      *_chunk_census(bytes(th.payload),
                                                     th.thread_eof))
        except Exception as exc:
            fmt = None
            fails.append('lzw: could not walk the thread: %s' % exc)
        if fmt is not None:
            if fmt != 3:
                fails.append('lzw: thread_format $%04X, wanted $0003 '
                             '(LZW/2)' % fmt)
            elif slack:
                fails.append('lzw: the chunk walk left %d byte(s) of a '
                             '%d byte thread unread -- the chunk headers '
                             'are not the shape LZW/2 declares'
                             % (slack, len(th.payload)))
            elif not (census['lzw'] and census['stored'] and census['rle']):
                fails.append('lzw: chunk census %r -- the fixture stopped '
                             'reaching all three shapes, so two of the '
                             'decoder\'s three paths are now untested'
                             % census)
            else:
                print('[check-nulib2] lzw: thread_format $0003, and the '
                      'chunk walk consumed the thread exactly: %d LZW, '
                      '%d RLE-only, %d stored'
                      % (census['lzw'], census['rle'], census['stored']))
        try:
            r = subprocess.run(['nulib2', '-i', lp], capture_output=True,
                               timeout=60)
            if r.returncode != 0:
                fails.append('lzw: `nulib2 -i` rejects it: %s'
                             % r.stderr.decode('latin-1')[:200])
            else:
                print('[check-nulib2] lzw: NufxLib verifies it too')
        except FileNotFoundError:
            print('[check-nulib2] lzw: nulib2(1) not installed')
        except subprocess.TimeoutExpired:
            fails.append('lzw: `nulib2 -i` HUNG on it')
        # -- THE LZW TABLES' HOME (docs/NUFX-LC.md). The encoder's
        # -- chain table lives in the process language card, and a
        # -- table that is wrong there passes a SMALL fixture: this
        # -- one is ~28 KB, fills the 4096-entry table and sends the
        # -- clear code (learning:01M322FJ60GVT1QZG6R41EWJSP), so a
        # -- bad chain shows as a bad archive. Two proofs. (1) The
        # -- compressed STREAM is pinned: the move must change no
        # -- byte of what `-a` writes, and a hash taken from the
        # -- binary BEFORE the move is the only thing that says so.
        # -- It hashes the thread payload and not the file, because
        # -- the first ~100 bytes carry the clock (master and record
        # -- dates, and the CRCs over them) and differ run to run.
        # -- (2) HOST nulib2's own expansion -- a third reader besides
        # -- a2til and `-i` -- must give back the original.
        if os.environ.get('LZWP_DUMP'):
            open(os.environ['LZWP_DUMP'], 'wb').write(lzwp)
        try:
            with nufx.NufxArchive(lp) as arc:
                pth = [t for r in arc.records for t in r.threads
                       if t.thread_class == 2 and t.thread_kind == 0][0]
                got = hashlib.sha256(bytes(pth.payload)).hexdigest()
                plen = len(pth.payload)
        except Exception as exc:
            got = plen = None
            fails.append('lzw: could not read the thread payload: %s' % exc)
        if got is not None and got != LZWP_SHA256:
            fails.append('lzw: thread payload sha256 %s, pinned %s -- `-a` '
                         'no longer writes the stream it wrote before the '
                         'LZW tables moved to the language card (if the '
                         'WRITER changed on purpose, re-pin it)'
                         % (got, LZWP_SHA256))
        elif got is not None:
            print('[check-nulib2] lzw: the %d byte compressed stream '
                  'matches the pinned pre-move sha256' % plen)
        xdir = os.path.join(tmp, 'hostx')
        os.makedirs(xdir, exist_ok=True)
        try:
            r = subprocess.run(['nulib2', '-x', lp], capture_output=True,
                               timeout=60, cwd=xdir)
            xf = os.path.join(xdir, LZWNAME)
            if r.returncode != 0 or not os.path.exists(xf):
                fails.append('lzw: host `nulib2 -x` failed: %s'
                             % r.stderr.decode('latin-1')[:200])
            elif open(xf, 'rb').read() != LZWBODY:
                fails.append('lzw: host `nulib2 -x` expands it to '
                             'something other than the original')
            else:
                print('[check-nulib2] lzw: host nulib2 -x expands it '
                      'byte-identical to the %d byte original'
                      % len(LZWBODY))
        except FileNotFoundError:
            print('[check-nulib2] lzw: nulib2(1) not installed')
        except subprocess.TimeoutExpired:
            fails.append('lzw: host `nulib2 -x` HUNG on it')

    # -- `-0`, nulib2's own letter for "don't use compression". The
    # -- point of the flag is the WORK, not the bytes: coding 28 KB
    # -- costs ~22 seconds on a //e and storing it costs ~2, so a
    # -- version that coded the file and then discarded the answer
    # -- would satisfy every assertion here and miss the entire
    # -- purpose. Hence the check on thread_format, which is the one
    # -- thing that cannot be true unless the coder was skipped.
    run(disk, ['cd /mnt/MAUX',
               'nulib2 -a0 /mnt/MAUX/ZERO.SHK /mnt/MAUX/' + LZWNAME],
        [], fails, 'nocomp')
    prodos.mount(disk, replace=True, readonly=True)
    try:
        zero = prodos.read('/mnt/MAUX/ZERO.SHK')
    except Exception as exc:
        zero = None
        fails.append('nocomp: /mnt/MAUX/ZERO.SHK not written: %s' % exc)
    finally:
        prodos.unmount('MAUX')
    if zero is not None:
        zp = os.path.join(tmp, 'z.shk')
        with open(zp, 'wb') as f:
            f.write(zero)
        try:
            with nufx.NufxArchive(zp) as arc:
                zt = [t for r in arc.records for t in r.threads
                      if t.thread_class == 2 and t.thread_kind == 0][0]
                zfmt, zcomp = zt.thread_format, zt.comp_thread_eof
                zback = arc.read_file('/' + LZWNAME, fork='data')
        except Exception as exc:
            zfmt = None
            fails.append('nocomp: a2til refuses it: %s' % exc)
        if zfmt is not None:
            if zfmt != 0:
                fails.append('nocomp: thread_format $%04X, wanted $0000 '
                             '-- `-0` still ran the coder' % zfmt)
            elif zcomp != len(LZWBODY):
                fails.append('nocomp: comp_thread_eof %d for %d bytes of '
                             'input; a stored thread spends exactly its '
                             'own length' % (zcomp, len(LZWBODY)))
            elif zback != LZWBODY:
                fails.append('nocomp: expands to %d bytes, not the '
                             'original %d' % (len(zback), len(LZWBODY)))
            else:
                print('[check-nulib2] nocomp: `-a0` stored %d bytes as '
                      'thread_format $0000, carrying the same plaintext '
                      'CRC the coded path computes' % zcomp)

    # -- THE PERIOD ORACLE. Every other fixture in this gate was made
    # -- by a2til or NufxLib, both modern host reimplementations of a
    # -- format whose only period writers ran on an Apple II. This one
    # -- was packed by ShrinkIt 3.4 -- Andy Nicholas's own program,
    # -- 1988-92 -- running on an emulated enhanced //e, which is the
    # -- machine maux targets. It is checked IN rather than fetched:
    # -- remaking it needs a human driving ShrinkIt's menus under
    # -- emulation, so no `vendor-` target can. docs/NUFX.md says how.
    # --
    # -- It is not just another LZW/1 stream. It differs structurally
    # -- from what the host tools emit: ShrinkIt writes an empty
    # -- 200-byte MESSAGE thread into every record, which a reader has
    # -- to step over using comp_thread_eof rather than thread_eof --
    # -- exactly the trap this format is known for, and one no
    # -- a2til-made fixture here contains.
    vend = os.path.join(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))), 'fixtures', 'shrinkit34.shk')
    prodos.mount(disk, replace=True)
    try:
        prodos.write('/mnt/MAUX/PERIOD.SHK', open(vend, 'rb').read(),
                     file_type=0xE0, aux_type=0x8002, overwrite=True)
    finally:
        prodos.unmount('MAUX')
    run(disk, ['cd /mnt/MAUX', 'nulib2 -x /mnt/MAUX/PERIOD.SHK'],
        [], fails, 'period')
    prodos.mount(disk, replace=True, readonly=True)
    try:
        pgot = prodos.read('/mnt/MAUX/' + LZWNAME)
    except Exception as exc:
        pgot = None
        fails.append('period: maux extracted nothing from the ShrinkIt '
                     'archive: %s' % exc)
    finally:
        prodos.unmount('MAUX')
    if pgot is not None:
        if pgot != LZWBODY:
            i = next((j for j in range(min(len(pgot), len(LZWBODY)))
                      if pgot[j] != LZWBODY[j]), min(len(pgot), len(LZWBODY)))
            fails.append('period: maux expanded ShrinkIt 3.4\'s own LZW/1 '
                         'to %d bytes, wanted %d; first difference at %d '
                         '(chunk %d)' % (len(pgot), len(LZWBODY), i, i // 4096))
        else:
            print('[check-nulib2] period: maux expanded an archive packed '
                  'by ShrinkIt 3.4 itself (LZW/1, with the 200-byte '
                  'message thread ShrinkIt writes) byte-identically')

    # -- CREATING an archive, judged by the two readers that did not
    # -- write it. maux bundles two files it already has; a2til then
    # -- reads the result back and must agree on names, bytes, type
    # -- and aux. That is the whole point of the verb: getting work
    # -- OFF the machine in a form a host opens.
    run(disk, ['cd /mnt/MAUX',
               'nulib2 -a /mnt/MAUX/MADE.SHK /mnt/MAUX/X/AAA.TXT '
               '/mnt/MAUX/X/BBB.BIN'], [], fails, 'create')
    prodos.mount(disk, replace=True, readonly=True)
    try:
        made = prodos.read('/mnt/MAUX/MADE.SHK')
    except Exception as exc:
        made = None
        fails.append('create: /mnt/MAUX/MADE.SHK was not written: %s' % exc)
    finally:
        prodos.unmount('MAUX')
    if made is not None:
        madep = os.path.join(tmp, 'MADE.SHK')
        with open(madep, 'wb') as f:
            f.write(made)
        try:
            with nufx.NufxArchive(madep) as arc:
                got = [(e.name, e.type, e.aux_type,
                        arc.read_file('/' + e.name, fork='data'))
                       for e in arc.scandir('/')]
        except Exception as exc:
            got = None
            fails.append('create: a2til refuses the archive maux wrote: '
                         '%s' % exc)
        want = [(n, t, a, b) for n, t, a, b in FILES[:2]]
        if got is not None and got != want:
            fails.append('create: a2til reads %r from maux\'s archive, '
                         'expected %r' % (got, want))
        elif got is not None:
            print('[check-nulib2] create: %d byte archive, a2til agrees '
                  'on every name, type, aux and fork' % len(made))
        # -- THE CRC IS CHECKED HERE, NOT DELEGATED. a2til reads a
        # -- STORED thread without verifying its thread_crc, so it
        # -- accepts an archive whose checksum is wrong -- measured:
        # -- seeding the written CRC $0000 instead of $FFFF changed
        # -- nothing it reported. The gate therefore computes the
        # -- checksum itself and asserts the bytes maux wrote carry
        # -- it. A reader that does not check a field cannot be the
        # -- oracle for that field.
        for name, _t, _a, body in FILES[:2]:
            want_crc = crc16_xmodem(body, 0xFFFF)
            if made is None or struct.pack('<H', want_crc) not in made:
                fails.append('create: the data thread for %s does not '
                             'carry CRC $%04X (seed $FFFF over the '
                             'plaintext, which is what a v3 thread_crc '
                             'is) -- a2til will not tell you this, it '
                             'does not verify a stored thread'
                             % (name, want_crc))
        if not fails:
            print('[check-nulib2] create: every data thread carries the '
                  'CRC this gate computed independently')
        # -- NufxLib's own verdict, when it is installed. Not required:
        # -- the box may not carry nulib2, and a gate that silently
        # -- skips is worse than one that says it skipped.
        try:
            r = subprocess.run(['nulib2', '-i', madep],
                               capture_output=True, timeout=30)
            if r.returncode != 0:
                fails.append('create: `nulib2 -i` rejects the archive '
                             'maux wrote: %s'
                             % r.stderr.decode('latin-1')[:200])
            else:
                print('[check-nulib2] create: NufxLib\'s own `nulib2 -i` '
                      'verifies it')
        except FileNotFoundError:
            print('[check-nulib2] create: nulib2(1) not installed, '
                  'skipping its verdict')
        except subprocess.TimeoutExpired:
            fails.append('create: `nulib2 -i` HUNG on the archive maux '
                         'wrote -- which is a verdict, not an absence. '
                         'Reporting a timeout as "not installed" hid a '
                         'real rejection once already.')

    # -- SLICE 8: `.SDK` -- a disk image inside an archive. The
    # -- archive's own NAME says it holds one (docs/NUFX.md); no new
    # -- letter, because real nulib2's command line cannot add a disk
    # -- image at all. The fixture is the compressor's own corpus
    # -- shapes (text/all-256/run/multi-chunk) laid into a real
    # -- 280-block ProDOS volume with a2til, so `-a` sees exactly what
    # -- `dd`-ing a floppy would hand it.
    sdk_img = os.path.join(tmp, 'flop.img')
    sdk_bytes = build_floppy_image(sdk_img)
    print('[check-nulib2] sdk: floppy image built, %d bytes (%d blocks)'
          % (len(sdk_bytes), len(sdk_bytes) // 512))
    prodos.mount(disk, replace=True)
    try:
        prodos.write('/mnt/MAUX/' + SDK_IMGNAME, sdk_bytes, file_type=0x06,
                     aux_type=0, overwrite=True)
    finally:
        prodos.unmount('MAUX')
    run(disk, ['cd /mnt/MAUX',
               'nulib2 -a ' + SDKPATH + ' /mnt/MAUX/' + SDK_IMGNAME],
        [], fails, 'sdk')
    run(disk, ['cd /mnt/MAUX',
               'nulib2 -0 -a ' + SDK0PATH + ' /mnt/MAUX/' + SDK_IMGNAME],
        [], fails, 'sdk0', steps=3000)
    # -- `-v` on the MACHINE shows the `Disk` row: block count where a
    # -- file's aux would go, the plaintext length in PRSIZE (which
    # -- BUILDTHR always writes as thread_eof, coded or not).
    want_v = [' Disk %8d $%04X %s'
             % (len(sdk_bytes), len(sdk_bytes) // 512, SDK_IMGNAME)]
    run(disk, ['nulib2 -v ' + SDKPATH], want_v, fails, 'sdk-v')
    prodos.mount(disk, replace=True, readonly=True)
    try:
        sdk_arc = prodos.read(SDKPATH)
    except Exception as exc:
        sdk_arc = None
        fails.append('sdk: %s was not written: %s' % (SDKPATH, exc))
    try:
        sdk0_arc = prodos.read(SDK0PATH)
    except Exception as exc:
        sdk0_arc = None
        fails.append('sdk0: %s was not written: %s' % (SDK0PATH, exc))
    finally:
        prodos.unmount('MAUX')
    if sdk_arc is not None:
        check_sdk_archive(tmp, sdk_arc, sdk_bytes, 'sdk', fails)
    if sdk0_arc is not None:
        check_sdk_archive(tmp, sdk0_arc, sdk_bytes, 'sdk0', fails)

    # -- FROM THE DEVICE DIRECTLY: the SAME fixture image, mounted as
    # -- a SECOND SmartPort unit (check_devblk.py's own pattern), fed
    # -- to `-a` by device path with no code specific to it -- INFO's
    # -- GET_FILE_INFO fallback and GETLEN's LSEEK(END) (which the
    # -- kernel answers from the volume header for a block fd) are the
    # -- whole story.
    run(disk, ['cd /mnt/MAUX', 'nulib2 -a /mnt/MAUX/DEV.SDK /dev/s7d2'],
        [], fails, 'sdkdev', disk2=sdk_img, unit2=2)
    prodos.mount(disk, replace=True, readonly=True)
    try:
        dev_arc = prodos.read('/mnt/MAUX/DEV.SDK')
    except Exception as exc:
        dev_arc = None
        fails.append('sdkdev: /mnt/MAUX/DEV.SDK was not written: %s' % exc)
    finally:
        prodos.unmount('MAUX')
    if dev_arc is not None:
        check_sdk_archive(tmp, dev_arc, sdk_bytes, 'sdkdev', fails)

    shutil.rmtree(tmp, ignore_errors=True)
    if fails:
        for f in fails:
            print('[check-nulib2] FAIL: %s' % f)
        return 1
    print('[check-nulib2] PASS: `nulib2 -t` gives bare names and '
          '`nulib2 -v` agrees with a2til on every record, having '
          'verified the master and header CRCs itself; '
          '`nulib2 -x` wrote all %d stored fork(s) byte-exact with the '
          "record's own type and aux, and expanded an LZW/1 fork "
          'across %d chunks byte-identical to what a2til reads from '
          'the same archive, and an LZW/2 fork across %d more'
          % (len(FILES), (len(lzwant) + 4095) // 4096,
             (len(l2want) + 4095) // 4096))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
