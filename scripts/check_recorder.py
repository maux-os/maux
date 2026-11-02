#!/usr/bin/env python3
"""check_recorder.py -- `make check-recorder`: the recorder's own gate.

Runs on the sweep box: it needs no ffmpeg and no Pillow, because every
row works on the frames demo_record.py composes BEFORE the encoder
(`--record --no-encode`), and the two encoder rows use a FAKE ffmpeg
script put first on PATH. Nothing here looks at the host's real ffmpeg:
the gate is the same on every host (R7; `--ffmpeg-only`, which `make
demos` runs, is the Mac-only cross-check against it). Rows
(docs/RECORDER.md "Rows", docs/RECORDER-NOTES.md sec 10-11):

  gate/record      mygrep passes in gate mode and in record mode with
                   the same number of checks
  step length      every step is one 34,016-cycle frame: frames emitted ==
                   emulated duration x 30, within one
  determinism      one seed twice -> identical frame-hash sequences
                   (in-process run vs the CLI's frames.sha256);
                   TEETH: another seed -> the sequence differs
  clock            the Timemaster is pinned off, so a demo that reads
                   the date sees none, and records the same twice (R2)
  key strip        on EVERY frame, strip pixels are present exactly when
                   a key was sent within the last KEY_LINGER frames,
                   and the frame after the first key carries a cap
  overlay          on EVERY frame the picture is the emulator's pixels
                   (an independent decode) and the strip sits below it;
                   the badge never overlaps the key caps (x100, x1000,
                   1e9 cycles); a high-bit key draws a marker
  PNG decode       against an independent decode of a real frame and an
                   independent encoder across all five row filters, each
                   unfilter broken in turn; a bad CRC, interlace, IHDR
                   method byte, any truncation, a missing IEND refused;
                   a split IDAT accepted
  fast(16)         kept frames carry the badge, the cycle count rises
                   16 frames' worth per kept frame, and no other frame
                   has badge pixels
  encoder          a fake ffmpeg receives exactly frames x 720x420x3
                   bytes and the outputs are published; an abort kills
                   it, removes its directory and leaves OUTDIR empty (R6)
  abort            a planted wrong expect_text aborts a recording and
                   leaves nothing in OUTDIR
  popover          the operator's one overlay on the picture (t.popover,
                   docs/RECORDER.md item 4): every frame of its window
                   carries the box's pixels and no other frame does, the
                   picture outside the box is the emulator's own on every
                   frame, the poster is the whole clean picture; gate mode refuses a
                   missing glyph and a popover inside fast(); TEETH: a glyph
                   the font lacks raises, in the box and in the font
  hold/disk/CLI    hold(0) steps no frame, run_demo restores
                   e2e_term.DISK, one demo raising does not hide the next
  demo teeth       mygrep goes red with grep, with cmp, replaced by a
                   copy of cat, and with a grep that drops one line
  phosphor         (docs/DEMO-PHOSPHOR.md) the three monitors are a pure
                   palette remap of the canonical levels: each phosphor's
                   tables injective, its colour set exactly black + its
                   pair, the three sets distinct, the //e's film two
                   colours and the card's three; ONE emulator pass feeds
                   three encoders, each handed the tint of the picture
                   with the strip and the popover box UNtinted; the frame
                   hash is of the canonical frame so one frames.sha256
                   covers the three films; a third grey in the //e's
                   picture is a named error. TEETH: BRIGHT mapped to the
                   normal colour, a tinted strip, a lenient canon, a
                   stale tint cache, a _belongs that reads the phosphor
                   as the display, and a stamp that checks one size for
                   three films each turn their row red

Every row runs; the exit status is 1 if any failed.
"""
import hashlib
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
# A text-mode cell byte's bit 7 is the INVERSE attribute of the UltraTerm
# video RAM -- a display attribute, not a text encoding, so nothing here
# stages text and a2til's converter has no say.
INVERSE_BIT = 0x80
sys.path.insert(0, HERE)
import demo_overlay as ov                                    # noqa: E402
import e2e_term                                              # noqa: E402
import demo_phos                                             # noqa: E402
import demo_png                                              # noqa: E402
import demo_record as dr                                     # noqa: E402

MYGREP = os.path.join(ROOT, 'fixtures', 'demos', 'mygrep.py')
PLANTED = os.path.join(ROOT, 'fixtures', 'demos', 'planted_wrong.py')
FAST16 = os.path.join(ROOT, 'fixtures', 'demos', 'fast16.py')
CLOCKDATE = os.path.join(ROOT, 'fixtures', 'demos', 'clockdate.py')
HOLD0 = os.path.join(ROOT, 'fixtures', 'demos', 'hold0.py')
POPOVER = os.path.join(ROOT, 'fixtures', 'demos', 'popover.py')
POPBAD = os.path.join(ROOT, 'fixtures', 'demos', 'popbad.py')
CAPKEY = os.path.join(ROOT, 'fixtures', 'demos', 'capkey.py')
CAPFAST = os.path.join(ROOT, 'fixtures', 'demos', 'capfast.py')
CAPOVERFAST = os.path.join(ROOT, 'fixtures', 'demos', 'capoverfast.py')
CAPQUIET = os.path.join(ROOT, 'fixtures', 'demos', 'capquiet.py')
CAPOVER = os.path.join(ROOT, 'fixtures', 'demos', 'capover.py')
POPFAST = os.path.join(ROOT, 'fixtures', 'demos', 'popfast.py')
FLOPPY40 = os.path.join(ROOT, 'fixtures', 'demos', 'floppy40.py')
BADFLOPPY = os.path.join(ROOT, 'fixtures', 'demos', 'badfloppy.py')
RAISES = os.path.join(ROOT, 'fixtures', 'demos', 'raises.py')
SEED = 1234
CPU_HZ = 1_020_484

results = []


def row(name):
    """Decorator: run the row now, record PASS/FAIL, never stop."""
    def deco(fn):
        try:
            detail = fn()
            results.append((name, True, detail or ''))
            print(f'PASS  {name}' + (f'  ({detail})' if detail else ''))
        except Exception as e:                      # noqa: BLE001
            results.append((name, False, str(e)))
            print(f'FAIL  {name}\n      ' + str(e).replace('\n', '\n      '))
        sys.stdout.flush()
        return fn
    return deco


def need(cond, msg):
    if not cond:
        raise AssertionError(msg)


def cli(args, env=None):
    """Run demo_record.py as the Makefile does; return (rc, stderr)."""
    return cli2(args, env)[:2]


def cli2(args, env=None):
    p = subprocess.run([sys.executable, os.path.join(HERE, 'demo_record.py')]
                       + args, capture_output=True, text=True, env=env)
    return p.returncode, p.stderr, p.stdout


def hashes_of(outdir, name='mygrep'):
    with open(os.path.join(outdir, name, 'frames.sha256')) as f:
        return f.read().split()


# -- an independent decode ---------------------------------------------------

def ref_decode(png):
    """A second, separate decoder, for what verilogapple really writes:
    8-bit RGB, every row filter type 0. It shares no code with
    demo_png (struct and a streaming zlib object, no UNFILTERS)."""
    assert png[:8] == b'\x89PNG\r\n\x1a\n'
    pos, z, raw, w, h = 8, zlib.decompressobj(), b'', None, None
    while pos < len(png):
        n = int.from_bytes(png[pos:pos + 4], 'big')
        kind, body = png[pos + 4:pos + 8], png[pos + 8:pos + 8 + n]
        pos += 12 + n
        if kind == b'IHDR':
            w, h = (int.from_bytes(body[0:4], 'big'),
                    int.from_bytes(body[4:8], 'big'))
            assert body[8:13] == bytes([8, 2, 0, 0, 0]), body[8:13]
        elif kind == b'IDAT':
            raw += z.decompress(body)
    assert len(raw) == h * (3 * w + 1)
    rows = [raw[y * (3 * w + 1):(y + 1) * (3 * w + 1)] for y in range(h)]
    assert all(r[0] == 0 for r in rows), 'screen_image used a row filter'
    return w, h, b''.join(r[1:] for r in rows)


def ref_encode(w, h, rgb, ftypes):
    """An independent PNG ENCODER with its own five forward filters
    (own Paeth, written from the spec, nothing imported from demo_png),
    so a broken demo_png predictor cannot cancel itself out in a round
    trip. `ftypes` is cycled over the rows."""
    stride = w * 3
    out, prev = bytearray(), bytes(stride)
    for y in range(h):
        cur = rgb[y * stride:(y + 1) * stride]
        t = ftypes[y % len(ftypes)]
        out.append(t)
        for i in range(stride):
            a = cur[i - 3] if i >= 3 else 0
            b = prev[i]
            c = prev[i - 3] if i >= 3 else 0
            if t == 0:
                pred = 0
            elif t == 1:
                pred = a
            elif t == 2:
                pred = b
            elif t == 3:
                pred = (a + b) // 2
            else:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
            out.append((cur[i] - pred) % 256)
        prev = cur

    def chunk(kind, body):
        return (len(body).to_bytes(4, 'big') + kind + body +
                zlib.crc32(kind + body).to_bytes(4, 'big'))
    return (b'\x89PNG\r\n\x1a\n' +
            chunk(b'IHDR', w.to_bytes(4, 'big') + h.to_bytes(4, 'big') +
                  bytes([8, 2, 0, 0, 0])) +
            chunk(b'IDAT', zlib.compress(bytes(out))) +
            chunk(b'IEND', b''))


# -- gate mode and record mode ----------------------------------------------

blank = ov.blank_strip()
meta = []                           # per frame: (strip != blank, badge, has_badge_pixels)
badge_px = bytes(ov.BADGE_BG)
amber = bytes(ov.SPECIAL_BG)


SCREEN_BYTES = ov.SCREEN_W * ov.SCREEN_H * 3       # the //e's own picture
PIC_BYTES = ov.FRAME_W * ov.PIC_H * 3           # ... in the video frame
last_frame = [None]
_picture = {}                       # PNG bytes -> independent decode
_padded = {}                        # PNG bytes -> that, in the frame


# -- the phosphor, independently ------------------------------------------
# The canonical levels the renderers draw, as LITERALS (not read back from
# demo_phos, so a renamed or edited level cannot move the gate with it):
# dark, the normal cell, and the card's highlight.
G_OFF, G_LIT, G_BRIGHT = bytes(3), bytes([0x80] * 3), bytes([0xFF] * 3)
# screen_image gives the //e's text as 0x00 / 0xFF; the film draws its
# white as the NORMAL level (the //e has no highlight attribute).
_E_TO_CANON = bytes(0x80 if b == 0xFF else b for b in range(256))


def canon_e(rgb):
    return rgb.translate(_E_TO_CANON)


def gate_tables(pair):
    """Three per-channel translate tables for a (normal, highlight)
    pair, built from the gate's own literals."""
    out = []
    for ch in range(3):
        t = bytearray(256)
        t[0x00], t[0x80], t[0xFF] = 0, pair[0][ch], pair[1][ch]
        out.append(bytes(t))
    return out


def ind_tint(pic, ph):
    """`pic` (canonical) through the gate's own tables for phosphor
    `ph`'s pair. The pairs are DATA read from demo_phos; the mechanism is
    this file's."""
    tabs = gate_tables(demo_phos.PHOSPHORS[ph])
    out = bytearray(pic)
    for ch in range(3):
        out[ch::3] = pic[ch::3].translate(tabs[ch])
    return bytes(out)


def colours(pic):
    return set(zip(pic[0::3], pic[1::3], pic[2::3]))


class TintWatch:
    """Per frame, from on_frame: every phosphor's encoder picture is the
    independent tint of the canonical picture (with the popover box drawn
    OVER it, in its own colours), and the frame the recorder hashed is
    picture + strip. Remembers which red-channel values each phosphor
    ever showed outside a popover."""

    def __init__(self):
        self.bad = []               # (frame, phosphor, what)
        self.red = {ph: set() for ph in demo_phos.NAMES}
        self.hashes = []            # sha256 of each canonical frame
        self.n = 0
        self.sample = None
        self._pic = self._exp = None
        self._seen = {}

    def see(self, index, frame, info):
        self.n += 1
        self.hashes.append(hashlib.sha256(frame).hexdigest())
        if index == 100:
            self.sample = (frame, info['pics'], info['strip'])
        pics, pic, box = info['pics'], info['pic'], info['popover']
        if pic is not self._pic:
            self._exp = {ph: ind_tint(pic, ph) for ph in demo_phos.NAMES}
            self._pic = pic
        for ph in demo_phos.NAMES:
            want = (ov.blit_box(self._exp[ph], box) if box
                    else self._exp[ph])
            if pics.get(ph) != want:
                self.bad.append((index, ph, 'not the tint of the picture'))
            if not box and self._seen.get(ph) is not pics[ph]:
                self._seen[ph] = pics[ph]
                self.red[ph] |= set(pics[ph][0::3])


tintw = TintWatch()                 # the mygrep recording's
tint_cur = [tintw]                  # whose watch collect() feeds now


def collect(index, frame, info):
    """Per frame: strip pixels?, badge, badge pixels?, amber?, cycle,
    frame == picture + strip?, picture == an INDEPENDENT decode of the
    screen_image PNG of that frame (in the canonical palette)?"""
    strip = info['strip']
    last_frame[0] = frame
    png = info['png']
    tint_cur[0].see(index, frame, info)
    if png not in _picture:
        _picture.clear()
        _padded.clear()
        _picture[png] = ref_decode(png)[2]
        _padded[png] = ov.pad_picture(canon_e(_picture[png]))
    meta.append((strip != blank, info['badge'], badge_px in strip,
                 amber in strip, info['cycle'],
                 len(frame) == PIC_BYTES + len(strip) and
                 frame[PIC_BYTES:] == strip,
                 frame[:PIC_BYTES] == _padded[png] and
                 _picture[png] == info['rgb']))


def ffmpeg_only():
    """`make demos` runs this on the Mac: decode one REAL screen_image
    frame with the host's ffmpeg and require the same pixels as
    demo_png. Not part of the sweep (the box has no ffmpeg; R7)."""
    ff = shutil.which('ffmpeg')
    if not ff:
        print('FAIL  ffmpeg is not on PATH')
        return 1
    d = tempfile.mkdtemp(prefix='check_recorder.ff.')
    try:
        r = dr.run_demo(MYGREP, record=os.path.join(d, 'o'), encode=False,
                        seed=SEED)
        if not r.ok:
            print(f'FAIL  mygrep failed: {r.error}')
            return 1
        p = os.path.join(d, 'real.png')
        with open(p, 'wb') as f:
            f.write(r.last_png)
        raw = subprocess.run([ff, '-v', 'error', '-i', p, '-f', 'rawvideo',
                              '-pix_fmt', 'rgb24', '-'],
                             capture_output=True).stdout
        mine = demo_png.decode_rgb(r.last_png)[2]
        if raw != mine:
            print('FAIL  ffmpeg decodes a real screen_image frame '
                  'differently from demo_png')
            return 1
        print('PASS  ffmpeg decodes a real screen_image frame to the '
              'same pixels as demo_png')
        return 0
    finally:
        shutil.rmtree(d, ignore_errors=True)


if '--ffmpeg-only' in sys.argv:
    sys.exit(ffmpeg_only())


tmp = tempfile.mkdtemp(prefix='check_recorder.')
gate = rec = None
try:
    @row('mygrep passes in gate mode')
    def _():
        global gate
        gate = dr.run_demo(MYGREP, seed=SEED)
        need(gate.ok, f'gate mode failed: {gate.error}')
        need(gate.checks >= 8, f'only {gate.checks} checks ran')
        return f'{gate.checks} checks'

    @row('mygrep passes in record mode, same assertions')
    def _():
        global rec
        rec = dr.run_demo(MYGREP, record=os.path.join(tmp, 'a'),
                          encode=False, seed=SEED, on_frame=collect)
        need(rec.ok, f'record mode failed: {rec.error}')
        need(gate and gate.ok and rec.checks == gate.checks,
             f'record mode ran {rec.checks} checks, gate mode '
             f'{gate.checks if gate else None}')
        for fn in (('mygrep.vtt', 'transcript.txt', 'frames.sha256') +
                   tuple('poster-%s.png' % ph for ph in demo_phos.NAMES)):
            need(os.path.getsize(os.path.join(rec.out_dir, fn)) > 0,
                 f'{fn} missing or empty')
        need(not any(f.endswith(('.mp4', '.webm'))
                     for f in os.listdir(rec.out_dir)),
             '--no-encode left a video')
        need('poster.png' not in os.listdir(rec.out_dir),
             'a bare poster.png: every picture names its monitor')
        return f'{rec.checks} checks, {rec.frames} frames'

    @row('every step is one 34,016-cycle frame: frames == duration x 30')
    def _():
        need(rec and rec.ok, 'no recording')
        want = rec.cycles * dr.FPS / CPU_HZ
        need(abs(rec.frames - want) <= 1,
             f'{rec.frames} frames for {rec.cycles} cycles '
             f'({want:.1f} wanted)')
        need(rec.frames == rec.stepped == len(rec.hashes) == len(meta),
             f'frames {rec.frames}, stepped {rec.stepped}, hashes '
             f'{len(rec.hashes)}, callbacks {len(meta)}')
        return f'{rec.frames} frames, {rec.cycles / CPU_HZ:.1f} s emulated'

    @row('one seed twice: identical frame-hash sequences')
    def _():
        need(rec and rec.ok, 'no recording')
        out = os.path.join(tmp, 'b')
        rc, err = cli([MYGREP, '--record', out, '--no-encode',
                       '--seed', str(SEED)])
        need(rc == 0, f'CLI run failed ({rc}): {err[-300:]}')
        second = hashes_of(out)
        need(len(second) == len(rec.hashes),
             f'{len(second)} frames vs {len(rec.hashes)}')
        need(second == list(rec.hashes), 'frame hashes differ run to run')
        distinct = len(set(second))
        need(distinct > 100, f'only {distinct} distinct frames')
        return f'{len(second)} frames, {distinct} distinct'

    @row('TEETH: another seed gives a different hash sequence')
    def _():
        out = os.path.join(tmp, 'c')
        rc, err = cli([MYGREP, '--record', out, '--no-encode',
                       '--seed', str(SEED + 1)])
        need(rc == 0, f'CLI run failed ({rc}): {err[-300:]}')
        other = hashes_of(out)
        need(other != list(rec.hashes),
             'seed+1 produced the SAME sequence: the seed does not reach '
             'the key gaps, so the determinism row above proves nothing')
        return f'{len(other)} frames vs {len(rec.hashes)}'

    @row('key strip: pixels on a frame exactly when a key is live')
    def _():
        need(rec and rec.ok, 'no recording')
        keyed = set()
        for f, _key in rec.key_log:
            keyed.update(range(f, f + ov.KEY_LINGER))
        bad = [i for i, m in enumerate(meta) if m[0] != (i in keyed)]
        need(not bad, f'{len(bad)} frames disagree, first at {bad[:5]} '
                      f'(strip pixels vs keys sent within '
                      f'{ov.KEY_LINGER} frames)')
        on = sum(1 for m in meta if m[0])
        need(on > 100 and len(meta) - on > 100,
             f'vacuous: {on} frames with a strip, {len(meta) - on} without')
        first = rec.key_log[0]
        need(first[1] == '\x0c', f'first key was {first[1]!r}, not ^L')
        need(meta[first[0] + 1][3],
             'the frame after the first key (^L, a control key) has no '
             'amber cap')
        need(all(not m[1] and not m[2] for m in meta),
             'a badge was drawn outside fast()')
        return f'{on} frames carry keys, {len(meta) - on} do not'

    @row('overlay: the picture is the emulator pixels on EVERY frame, '
         'the strip below it')
    def _():
        need(rec and rec.ok and len(meta) == rec.frames, 'no recording')
        bad = [i for i, m in enumerate(meta) if not m[5]]
        need(not bad, f'{len(bad)} frames are not picture + strip, first '
                      f'at {bad[:5]}')
        bad = [i for i, m in enumerate(meta) if not m[6]]
        need(not bad, f'{len(bad)} frames whose picture is not the '
                      f'screen_image pixels (an independent decode), '
                      f'first at {bad[:5]}: something was drawn over the '
                      f'Apple screen')
        return f'{ov.FRAME_W}x{ov.FRAME_H}: {ov.PIC_H} picture + ' \
               f'{ov.STRIP_H} strip, {len(meta)} frames checked'

    def inked_columns(strip):
        bg = bytes(ov.STRIP_BG)
        return {x for y in range(ov.STRIP_H) for x in range(ov.FRAME_W)
                if strip[(y * ov.FRAME_W + x) * 3:
                         (y * ov.FRAME_W + x) * 3 + 3] != bg}

    @row('overlay: the badge never overlaps the key caps (x100, x1000, 1e9)')
    def _():
        words = ['grep', 'expression', '/usr/man/GREP', 'mygrep',
                 'regular', 'cat', 'abcdefghijklmnopqrstuvwxyz0123456789']
        seen = []
        for n, cyc in ((16, 1), (16, 61_000_000), (100, 10 ** 6),
                       (1000, 10 ** 9), (1000, 10 ** 12)):
            badge = (n, cyc)
            ks = ov.KeyStrip()
            for w in words:
                for ch in w + ' ':
                    ks.press(ch, 0)
            caps = ks.caps(1, ov.keys_avail(badge))
            need(caps, f'x{n} at {cyc:,}: no caps fit at all')
            cc = inked_columns(ov.render_strip(caps, None))
            bc = inked_columns(ov.render_strip([], badge))
            need(bc and min(bc) >= 0 and max(bc) < ov.FRAME_W,
                 f'x{n} at {cyc:,}: the badge leaves the frame')
            need(max(cc) < min(bc),
                 f'x{n} at {cyc:,} cycles: caps reach x={max(cc)} but the '
                 f'badge starts at x={min(bc)}')
            seen.append(f'x{n}/{len(f"{cyc:,}")} digits: gap '
                        f'{min(bc) - max(cc)} px')
        return '; '.join(seen)

    @row('overlay: a high-bit key draws a marker, not a silent ?')
    def _():
        ks = ov.KeyStrip()
        ks.press('\x8d', 0)
        ks.press('\xe9', 1)
        caps = ks.caps(2, ov.keys_avail(None))
        need(caps == [('special', '$8D'), ('special', '$E9')], str(caps))
        need(ov.render_strip(caps, None) !=
             ov.render_strip([('special', '?'), ('special', '?')], None),
             'the marker renders like a question mark')
        return '$8D, $E9'

    @row('PNG decoder agrees with an independent decode of a real frame')
    def _():
        w, h, mine = demo_png.decode_rgb(rec.last_png)
        rw, rh, ref = ref_decode(rec.last_png)
        need((w, h) == (rw, rh), f'{w}x{h} vs {rw}x{rh}')
        need(mine == ref, 'pixels differ between the two decoders')
        need(len(set(ref[i:i + 3] for i in range(0, len(ref), 3))) > 1,
             'the frame is one flat colour: nothing was compared')
        return f'{w}x{h}, every pixel equal'

    def synth(w, h, seed=7):
        r = random.Random(seed)
        return bytes(r.getrandbits(8) for _ in range(w * h * 3))

    @row('PNG decoder round-trips all five row filters')
    def _():
        w, h = 47, 40
        rgb = synth(w, h)
        for ftype in range(5):
            png = ref_encode(w, h, rgb, (ftype,))
            got = demo_png.decode_rgb(png)
            need(got == (w, h, rgb), f'filter type {ftype} does not '
                                     f'round-trip against an independent '
                                     f'encoder')
        mixed = ref_encode(w, h, rgb, (0, 1, 2, 3, 4))
        need(demo_png.decode_rgb(mixed) == (w, h, rgb),
             'mixed-filter image does not round-trip')
        _w, _h, real = demo_png.decode_rgb(rec.last_png)
        crop = real[:ov.SCREEN_W * 3 * 96]
        png = ref_encode(ov.SCREEN_W, 96, crop, (0, 1, 2, 3, 4))
        need(demo_png.decode_rgb(png) == (ov.SCREEN_W, 96, crop),
             'a real frame re-encoded with every filter does not '
             'round-trip')
        # and the other way: demo_png's own encoder must be decodable by
        # the independent decoder when it sticks to filter 0
        own = demo_png.encode_rgb(w, h, rgb)
        need(ref_decode(own) == (w, h, rgb),
             "demo_png.encode_rgb's filter-0 output is not a PNG the "
             "independent decoder reads back")
        return 'synthetic noise, mixed rows, and a real frame'

    def png_parts(png):
        parts, pos = [], 8
        while pos < len(png):
            n = int.from_bytes(png[pos:pos + 4], 'big')
            parts.append((png[pos + 4:pos + 8], png[pos + 8:pos + 8 + n]))
            pos += 12 + n
        return parts

    def png_build(parts):
        out = b'\x89PNG\r\n\x1a\n'
        for kind, body in parts:
            out += (len(body).to_bytes(4, 'big') + kind + body +
                    zlib.crc32(kind + body).to_bytes(4, 'big'))
        return out

    def refused(png, what):
        try:
            demo_png.decode_rgb(png)
        except ValueError:
            return
        except Exception as e:                          # noqa: BLE001
            raise AssertionError(f'{what}: raised {type(e).__name__}, '
                                 f'not ValueError: {e}')
        raise AssertionError(f'{what}: decoded without complaint')

    @row('PNG decoder refuses what it must (CRC, IHDR, truncation, IEND) '
         'and accepts a split IDAT')
    def _():
        w, h = 9, 6
        rgb = synth(w, h, seed=5)
        good = ref_encode(w, h, rgb, (0, 1, 2, 3, 4))
        need(demo_png.decode_rgb(good) == (w, h, rgb), 'baseline')
        parts = png_parts(good)
        # a flipped byte inside IDAT, CRC untouched
        off = 8 + sum(12 + len(b) for k, b in parts[:1]) + 8 + 2
        flipped = bytearray(good)
        flipped[off] ^= 0x40
        refused(bytes(flipped), 'IDAT byte flipped under its CRC')
        # IHDR bytes, CRC recomputed so only the field is wrong
        ihdr = bytearray(parts[0][1])
        for idx, label in ((12, 'interlace'), (10, 'compression method'),
                           (11, 'filter method'), (8, 'bit depth 16'),
                           (9, 'colour type 6')):
            bad = bytearray(ihdr)
            bad[idx] = 16 if idx == 8 else (6 if idx == 9 else 1)
            refused(png_build([(b'IHDR', bytes(bad))] + parts[1:]),
                    f'IHDR {label}')
        refused(png_build([(b'IHDR', bytes(ihdr[:12]))] + parts[1:]),
                'IHDR 12 bytes long')
        # every proper prefix of the file: ValueError, never struct.error
        for cut in range(len(good)):
            refused(good[:cut], f'truncated at byte {cut}')
        refused(png_build(parts[:-1]), 'no IEND chunk')
        refused(png_build([parts[0], parts[2]]), 'no IDAT chunk')
        # a split IDAT is legal and must decode to the same pixels
        z = parts[1][1]
        mid = len(z) // 2
        split = png_build([parts[0], (b'IDAT', z[:mid]),
                           (b'IDAT', z[mid:]), parts[2]])
        need(demo_png.decode_rgb(split) == (w, h, rgb),
             'a PNG whose image data is split across two IDAT chunks '
             'does not decode')
        return f'{len(good)} truncations, 5 IHDR faults, CRC, IEND, IDAT split'

    @row('TEETH: breaking any one unfilter turns the round trip red')
    def _():
        w, h = 47, 40
        rgb = synth(w, h, seed=11)
        saved = dict(demo_png.UNFILTERS)
        survivors = []
        try:
            for ftype in range(5):
                png = ref_encode(w, h, rgb, (ftype,))
                good = saved[ftype]

                def broken(cur, prev, good=good):
                    out = bytearray(good(cur, prev))
                    out[len(out) // 2] ^= 0x01      # one wrong byte
                    return out
                demo_png.UNFILTERS[ftype] = broken
                try:
                    ok = demo_png.decode_rgb(png) == (w, h, rgb)
                except Exception:                   # noqa: BLE001
                    ok = False
                finally:
                    demo_png.UNFILTERS[ftype] = saved[ftype]
                if ok:
                    survivors.append(ftype)
        finally:
            demo_png.UNFILTERS.clear()
            demo_png.UNFILTERS.update(saved)
        need(not survivors, f'broken unfilter(s) {survivors} still round-'
                            f'tripped: those filters have no teeth')
        return 'all five mutants killed'

    @row('fast(16): badge, and cycles rise 16 frames per kept frame')
    def _():
        meta.clear()
        tint_cur[0] = TintWatch()       # mygrep's watch stays as it was
        f16 = dr.run_demo(FAST16, record=os.path.join(tmp, 'd'),
                          encode=False, seed=SEED, on_frame=collect)
        need(f16.ok, f'fast16 failed: {f16.error}')
        kept = [m for m in meta if m[1] is not None]
        need(len(kept) == 15, f'{len(kept)} kept frames, wanted 15 '
                              f'(240 stepped / 16)')
        need(all(m[1][0] == 16 and m[2] for m in kept),
             'a kept frame lacks the x16 badge pixels')
        need(all(not m[2] for m in meta if m[1] is None),
             'badge pixels outside the fast segment')
        cyc = [m[4] for m in kept]
        steps = {b - a for a, b in zip(cyc, cyc[1:])}
        need(steps == {16 * dr.FRAME_CYCLES},
             f'cycle steps {sorted(steps)}, wanted '
             f'{{{16 * dr.FRAME_CYCLES}}}')
        need(f16.frames == f16.stepped - 240 + 15,
             f'{f16.frames} frames from {f16.stepped} stepped')
        return f'15 kept, +{16 * dr.FRAME_CYCLES} cycles each'

    pop_meta = []

    def pop_collect(index, frame, info):
        box = info['popover']
        png = info['png']
        ref = ref_decode(png)[2]
        pop_meta.append((box, frame[:PIC_BYTES],
                         ov.pad_picture(canon_e(ref)), info['rgb'], ref))

    @row('popover: the box is on every frame of its window and no other')
    def _():
        r = dr.run_demo(POPOVER, record=os.path.join(tmp, 'p'),
                        encode=False, seed=SEED, on_frame=pop_collect)
        need(r.ok, f'popover failed: {r.error}')
        need(len(r.popovers) == 1, f'windows: {r.popovers}')
        a, z = r.popovers[0]
        need(z - a + 1 == 60, f'window of {z - a + 1} frames, wanted 60 '
                              f'(2 s at {dr.FPS} fps)')
        bx, by, bw, bh, bpx = ov.render_box('IYKYK ;-)')
        need(bx + bw <= ov.APPLE_X + ov.SCREEN_W and
             by + bh <= ov.APPLE_Y + ov.SCREEN_H and
             bx > ov.APPLE_X + ov.SCREEN_W // 2 and
             by > ov.APPLE_Y + ov.SCREEN_H // 2,
             'the box is not in the lower right of the //e picture')

        def region(pic):
            return b''.join(
                pic[((by + y) * ov.FRAME_W + bx) * 3:
                    ((by + y) * ov.FRAME_W + bx + bw) * 3]
                for y in range(bh))
        inside = outside = 0
        for i, (box, pic, ref, rgb, raw) in enumerate(pop_meta):
            has = region(pic) == bpx
            need(has == (a <= i <= z),
                 f'frame {i}: box pixels {has}, window {a}..{z}')
            need((box is not None) == (a <= i <= z),
                 f'frame {i}: recorder says box {box is not None}')
            need(rgb == raw, f'frame {i}: not the screen_image pixels')
            if has:
                inside += 1
                # everything but the box is the emulator's own picture
                dif = [k for k in range(0, len(pic), 3)
                       if pic[k:k + 3] != ref[k:k + 3]]
                need(dif, f'frame {i}: the box changed no pixel')
                cols = {(k // 3) % ov.FRAME_W for k in dif}
                rows = {(k // 3) // ov.FRAME_W for k in dif}
                need(min(cols) >= bx and max(cols) < bx + bw and
                     min(rows) >= by and max(rows) < by + bh,
                     f'frame {i}: pixels changed outside the box')
            else:
                outside += 1
                need(pic == ref, f'frame {i}: the picture is not the '
                                 f'emulator pixels outside the window')
        # the poster is the CLEAN picture of the first window frame
        # (poster() is called right before the popover), whole, against
        # an independent 2x upscale of the emulator's pixels
        def up2(pic):
            out = bytearray()
            for y in range(ov.PIC_H):
                row = pic[y * ov.FRAME_W * 3:(y + 1) * ov.FRAME_W * 3]
                row = b''.join(row[x:x + 3] * 2
                               for x in range(0, len(row), 3))
                out += row + row
            return bytes(out)
        for phos in demo_phos.NAMES:
            pw, ph, prgb = demo_png.decode_rgb(open(os.path.join(
                r.out_dir, f'poster-{phos}.png'), 'rb').read())
            need((pw, ph) == (2 * ov.FRAME_W, 2 * ov.PIC_H),
                 f'poster-{phos}.png is {pw}x{ph}')
            need(prgb == up2(ind_tint(pop_meta[a][2], phos)),
                 f'poster-{phos}.png is not the {phos} tint of the clean '
                 f'picture of the first popover frame (a box in it, or the '
                 f'wrong frame, or no tint)')
            need(prgb != up2(ov.blit_box(ind_tint(pop_meta[a][2], phos),
                                         (bx, by, bw, bh, bpx))),
                 'vacuous: a boxed poster would equal the clean one')
        for f in ('vtt', 'txt'):
            for fn in os.listdir(r.out_dir):
                if fn.endswith('.' + f):
                    need('IYKYK' not in open(os.path.join(
                        r.out_dir, fn)).read(), f'IYKYK leaked into {fn}')
        return f'{inside} frames carry the box, {outside} do not'

    @row('TEETH: a glyph the font lacks is an error, never a blank or ?')
    def _():
        import demo_font
        seen = []
        for text in ('IYKYK \u00e9', 'IYKYK \u2603', 'IYKYK \t'):
            for what, call in (
                    ('render_box', lambda t=text: ov.render_box(t)),
                    ('glyph', lambda t=text: demo_font.glyph(t[-1], True))):
                try:
                    call()
                except demo_font.MissingGlyph:
                    seen.append(what)
                    continue
                raise AssertionError(f'{what}({text!r}) did not raise')
        for ch in 'IYK ;-)':            # the glyphs the operator's text uses
            need(demo_font.glyph(ch, True), f'no glyph for {ch!r}')
        try:
            ov.render_box('')
        except ValueError:
            seen.append('empty')
        else:
            raise AssertionError('an empty popover did not raise')
        return f'{len(seen)} refusals'

    @row('GATE MODE refuses a popover with a missing glyph (red in the sweep)')
    def _():
        import demo_font
        try:
            dr.run_demo(POPBAD, seed=SEED)
        except demo_font.MissingGlyph as e:
            return str(e)[:60]
        raise AssertionError('a popover with a glyph the font lacks passed '
                             'in gate mode: only `make demos` would see it')

    @row('GATE MODE refuses a popover inside fast() (red in the sweep)')
    def _():
        try:
            dr.run_demo(POPFAST, seed=SEED)
        except dr.RecorderError as e:
            return str(e)[:60]
        raise AssertionError('a popover inside fast() passed in gate mode')

    @row('a key sent during an active cue is refused, in gate mode and in '
         'record mode, naming the demo and the caption')
    def _():
        seen = []
        for kw in ({}, dict(record=os.path.join(tmp, 'ck'), encode=False)):
            try:
                dr.run_demo(CAPKEY, seed=SEED, **kw)
            except dr.RecorderError as e:
                m = str(e)
                need('capkey' in m and 'narrates a wait' in m,
                     f'the refusal does not name demo and caption: {m}')
                seen.append('record' if kw else 'gate')
                continue
            raise AssertionError(
                f'a key under a caption passed in '
                f'{"record" if kw else "gate"} mode')
        return 'refused in ' + ' and '.join(seen)

    def expect_end(text, start):
        """The beat's end, worked out here and not read from the
        recorder's own reading_seconds()."""
        return start + round(dr.reading_seconds(text) * dr.FPS)

    def parse_vtt(path):
        cues = []
        lines = open(path).read().split('\n')
        need(lines[0] == 'WEBVTT', 'not a WebVTT file')

        def fr(t):
            h, m, sec = t.split(':')
            return round((int(h) * 3600 + int(m) * 60 + float(sec)) * dr.FPS)
        for i, ln in enumerate(lines):
            if '-->' in ln:
                a, rest = ln.split(' --> ')
                b, _, settings = rest.partition(' ')
                cues.append((fr(a), fr(b), settings, lines[i + 1]))
        return cues

    cap_run = {}

    @row('say(over=True) allows output but no keys; plain say() waits out '
         'its quiet pause before the next key')
    def _():
        r = dr.run_demo(CAPOVER, record=os.path.join(tmp, 'co'),
                        encode=False, seed=SEED)
        need(r.ok, f'capover failed: {r.error}')
        cap_run['r'] = r
        cues = parse_vtt(os.path.join(r.out_dir, 'capover.vtt'))
        need(len(cues) == 2, f'{len(cues)} cues, wanted 2')
        quiet = round(0.45 * dr.FPS)
        for first, last, _s, text in cues:
            inside = [f for f, _k in r.key_log if first <= f < last]
            need(not inside, f'keys at frames {inside} inside the cue '
                             f'{text!r} ({first}..{last})')
            nxt = [f for f, _k in r.key_log if f >= last]
            need(nxt and min(nxt) >= last + quiet,
                 f'the next key after {text!r} is at {nxt[:1]}, the cue '
                 f'ended {last}, quiet pause {quiet}')
        need(cues[1][0] > cues[0][1], 'over-cue timing')
        return f'{len(cues)} cues, no key inside either'

    @row('VTT cue end times equal the beat ends; every cue carries the '
         'centring settings')
    def _():
        r = cap_run.get('r')
        need(r is not None, 'capover did not record')
        files = [os.path.join(r.out_dir, 'capover.vtt'),
                 os.path.join(rec.out_dir, 'mygrep.vtt')]
        n = 0
        for path in files:
            cues = parse_vtt(path)
            need(cues, f'{path}: no cues')
            for first, last, settings, text in cues:
                need((last - first) / dr.FPS >=
                     max(2.4, 1.2 + 0.055 * len(text)) - 0.02,
                     f'{text!r}: shown {(last - first) / dr.FPS:.2f} s, '
                     f'less than its reading time')
                need(last == expect_end(text, first),
                     f'{text!r}: cue {first}..{last}, beat end '
                     f'{expect_end(text, first)}')
                need(settings == 'line:40% position:50% align:center '
                                 'size:80%',
                     f'{text!r}: cue settings {settings!r}')
                n += 1
        # TEETH: the old guess, max(2 s, 60 ms a character), is not the
        # beat for a 60-character caption
        need(round(max(2.0, 0.06 * 60) * dr.FPS) !=
             expect_end('x' * 60, 0), 'vacuous: old and new rules agree')
        return f'{n} cues'

    @row('say() inside fast(), and fast() under an open over-cue, are '
         'refused in gate mode and in record mode alike')
    def _():
        seen = []
        for fx in (CAPFAST, CAPOVERFAST):
            for kw in ({}, dict(record=os.path.join(tmp, 'cf'),
                                encode=False)):
                try:
                    dr.run_demo(fx, seed=SEED, **kw)
                except dr.RecorderError as e:
                    need('fast()' in str(e), f'unclear refusal: {e}')
                    seen.append(os.path.basename(fx)[:-3] +
                                ('/record' if kw else '/gate'))
                    continue
                raise AssertionError(
                    f'{os.path.basename(fx)} passed in '
                    f'{"record" if kw else "gate"} mode')
        return ', '.join(seen)

    @row('a key at the very end of an over-cue waits out the owed quiet '
         'pause (record), and the gate passes the same demo')
    def _():
        g = dr.run_demo(CAPQUIET, seed=SEED)
        need(g.ok, f'gate: {g.error}')
        r = dr.run_demo(CAPQUIET, record=os.path.join(tmp, 'cq'),
                        encode=False, seed=SEED)
        need(r.ok, f'record: {r.error}')
        cues = parse_vtt(os.path.join(r.out_dir, 'capquiet.vtt'))
        need(len(cues) == 1, f'{len(cues)} cues')
        last = cues[0][1]
        key = min(f for f, _k in r.key_log)
        need(key >= last + round(dr.CUE_QUIET * dr.FPS),
             f'the key landed at frame {key}, the cue ended {last}: no '
             f'quiet pause')
        return f'key at {key}, cue ended {last}'

    @row('no cue is shown for less than its uncapped reading time (the cap '
         'binds only past 150 characters); VTT markup is escaped')
    def _():
        for n in range(1, 151):
            t = 'x' * n
            need(dr.reading_seconds(t) >= max(2.4, 1.2 + 0.055 * n) - 1e-9,
                 f'a {n}-character caption is capped at '
                 f'{dr.reading_seconds(t):.2f} s')
        need(dr.reading_seconds('x' * 400) == dr.CUE_MAX, 'no backstop')
        need(dr.vtt_escape('a & b < c --> d') ==
             'a &amp; b &lt; c --&gt; d', 'vtt_escape')
        return f'cap {dr.CUE_MAX} s'

    @row('a wrong expect_text aborts the recording, nothing left behind')
    def _():
        out = os.path.join(tmp, 'e')
        os.mkdir(out)
        rc, err = cli([PLANTED, '--record', out, '--no-encode'])
        need(rc == 1, f'exit {rc}, wanted 1: {err[-300:]}')
        need('FAIL planted_wrong' in err and 'goodbye' in err,
             f'the failure did not name the row: {err[-300:]}')
        need(os.listdir(out) == [], f'left {os.listdir(out)} in OUTDIR')
        return 'exit 1, OUTDIR empty'

    def teeth(victim, label):
        res = dr.run_demo(MYGREP, seed=SEED,
                          setup=[f'cp /bin/cat /bin/{victim}'])
        need(not res.ok, f'mygrep stayed GREEN with {victim} replaced by '
                         f'cat: the gate has no teeth for it')
        need(label in str(res.error),
             f'red, but not at {label!r}:\n{str(res.error)[:300]}')
        return f'red at {label!r}'

    @row('TEETH: /bin/grep replaced by cat turns mygrep red')
    def _():
        return teeth('grep', 'grep prints the same rows')

    @row('TEETH: /bin/cmp replaced by cat turns mygrep red')
    def _():
        return teeth('cmp', 'cmp says nothing')

    @row('a text40 demo with a floppy comes up 40 columns wide')
    def _():
        res = dr.run_demo(FLOPPY40, seed=SEED)
        need(res.ok, f'floppy40 failed (a floppy mounted after boot()\'s '
                     f'text40 pokes would boot native 80): {res.error}')
        return '%d checks' % res.checks

    @row('an unknown floppy name is refused')
    def _():
        try:
            dr.load_demo(BADFLOPPY)
        except dr.RecorderError as e:
            need('floppy' in str(e), f'refused, but not by name: {e}')
            return str(e)[-60:]
        raise AssertionError('a demo naming an unknown floppy loaded')

    @row('clock pinned: a demo reads no host time, and records the same twice')
    def _():
        out = []
        for i in (1, 2):
            r = dr.run_demo(CLOCKDATE, record=os.path.join(tmp, f'k{i}'),
                            encode=False, seed=SEED)
            need(r.ok, f'clockdate failed (the pin is not in force: its '
                       f'date row expects "no valid clock reading"): '
                       f'{r.error}')
            out.append(r)
        need(out[0].hashes == out[1].hashes and out[0].frames > 100,
             'two pinned recordings differ')
        return f'{out[0].frames} frames, {len(set(out[0].hashes))} distinct'

    def fake_ffmpeg(directory):
        """A stand-in ffmpeg: answers -version/-encoders/-filters like
        the real one's parsed output, and for an encode reads rawvideo
        from stdin, noting its pid, argv and bytes read."""
        os.makedirs(directory)
        path = os.path.join(directory, 'ffmpeg')
        with open(path, 'w') as f:
            f.write(f"#!{sys.executable}\n" + """
import hashlib, json, os, sys
a = sys.argv[1:]
if '-version' in a:
    print('ffmpeg version 9.0.1 Copyright (c) the fake'); sys.exit(0)
if '-encoders' in a:
    print(' V....D libx264              fake\\n V....D libvpx-vp9           fake'); sys.exit(0)
if '-filters' in a:
    print(' T.. scale             V->V       fake\\n ... split             V->N       fake\\n ... format            V->V       fake'); sys.exit(0)
outs = [x for x in a if x.endswith(('.mp4', '.webm'))]
# ONE note per encoder (the recorder runs one per phosphor), named by the
# mp4 it was asked for: NOTE.<stem>
stem = os.path.basename(outs[0]).rsplit('.', 1)[0]
note = os.environ['FAKE_FFMPEG_NOTE'] + '.' + stem
h = hashlib.sha256()
def put(n, done):
    json.dump(dict(pid=os.getpid(), argv=a, outdir=os.path.dirname(outs[0]),
                   bytes=n, done=done, stem=stem, sha=h.hexdigest()),
              open(note, 'w'))
n = 0
put(0, False)
while True:
    b = sys.stdin.buffer.read(65536)
    if not b:
        break
    n += len(b)
    h.update(b)
for o in outs:
    open(o, 'wb').write(b'fake video')
put(n, True)
""")
        os.chmod(path, 0o755)
        return directory

    fake_env = dict(os.environ)
    fake_bin = fake_ffmpeg(os.path.join(tmp, 'fakebin'))
    fake_env['PATH'] = fake_bin + os.pathsep + os.environ.get('PATH', '')
    fake_env['FAKE_FFMPEG_NOTE'] = os.path.join(tmp, 'fake.note')

    def notes_of(base=None):
        """Every encoder's note from the last run, by phosphor stem."""
        base = base or fake_env['FAKE_FFMPEG_NOTE']
        d, b = os.path.split(base)
        return {fn[len(b) + 1:]: json.load(open(os.path.join(d, fn)))
                for fn in sorted(os.listdir(d)) if fn.startswith(b + '.')}

    def clear_notes():
        for fn in list(notes_of()):
            os.unlink(fake_env['FAKE_FFMPEG_NOTE'] + '.' + fn)

    @row('encoder (fake ffmpeg): one encoder per phosphor, each reading '
         'exactly frames x 720x420x3 bytes, outputs published')
    def _():
        out = os.path.join(tmp, 'f')
        clear_notes()
        rc, err, so = cli2([FAST16, '--record', out], fake_env)
        need(rc == 0, f'exit {rc}: {err[-300:]}')
        notes = notes_of()
        need(sorted(notes) == sorted('fast16-' + ph
                                     for ph in demo_phos.NAMES),
             f'encoders {sorted(notes)}: one per phosphor wanted')
        frames = len(hashes_of(out, 'fast16'))
        for stem, note in sorted(notes.items()):
            need(note['done'] and note['bytes'] ==
                 frames * ov.FRAME_W * ov.FRAME_H * 3,
                 f"{stem}: the encoder read {note['bytes']} bytes for "
                 f"{frames} frames of {ov.FRAME_W}x{ov.FRAME_H}x3")
            argv = ' '.join(note['argv'])
            for want in (f'-s {ov.FRAME_W}x{ov.FRAME_H}', '-pix_fmt rgb24',
                         f'-framerate {dr.FPS}', 'libx264', 'libvpx-vp9',
                         'scale=iw*2:ih*2:flags=neighbor'):
                need(want in argv, f'{stem}: {want!r} missing from the '
                                   f'ffmpeg command: {argv}')
        want = {'frames.sha256', 'fast16.vtt', 'transcript.txt',
                'fast16.stamp.json'}
        for ph in demo_phos.NAMES:
            want |= {f'fast16-{ph}.mp4', f'fast16-{ph}.webm',
                     f'poster-{ph}.png'}
        need(set(os.listdir(os.path.join(out, 'fast16'))) == want,
             f'published {sorted(os.listdir(os.path.join(out, "fast16")))}, '
             f'wanted {sorted(want)}')
        return f'3 encoders x {frames} frames'

    def through_fake(plant=None):
        """Record fast16 IN-PROCESS through the fake ffmpeg and return
        why each encoder's stdin is not (that phosphor's tint of the
        picture + the UNtinted strip), frame for frame: [] when it is.
        `plant` is a replacement EncoderSet.write for the teeth."""
        want = {ph: hashlib.sha256() for ph in demo_phos.NAMES}

        def tap(index, frame, info):
            for ph in demo_phos.NAMES:
                want[ph].update(info['pics'][ph] + info['strip'])
        old_path, old_write = os.environ['PATH'], dr.EncoderSet.write
        clear_notes()
        os.environ['PATH'] = fake_bin + os.pathsep + old_path
        os.environ['FAKE_FFMPEG_NOTE'] = fake_env['FAKE_FFMPEG_NOTE']
        if plant:
            dr.EncoderSet.write = plant
        try:
            r = dr.run_demo(FAST16, record=os.path.join(tmp, 'ft'),
                            encode=True, seed=SEED, on_frame=tap)
        finally:
            os.environ['PATH'] = old_path
            dr.EncoderSet.write = old_write
        need(r.ok, f'fast16 failed: {r.error}')
        notes = notes_of()
        out = []
        for ph in demo_phos.NAMES:
            n = notes.get('fast16-' + ph)
            if n is None:
                out.append(f'{ph}: no encoder ran')
            elif n['sha'] != want[ph].hexdigest():
                out.append(f'{ph}: the encoder was not fed that '
                           f'phosphor\'s tinted picture + the untinted '
                           f'strip')
        shas = {n['sha'] for n in notes.values()}
        if len(shas) != len(notes):
            out.append('two phosphors were fed the same bytes')
        return out

    @row('encoder (fake ffmpeg): each phosphor\'s encoder is fed its own '
         'tint of the picture and the UNtinted strip, frame for frame')
    def _():
        bad = through_fake()
        need(not bad, '; '.join(bad))
        return 'paper, green and amber each byte-exact, all three differ'

    @row('TEETH: a tint applied to the strip as well as the picture turns '
         'the encoder row red')
    def _():
        def tinted_strip(self, pics, strip):
            tabs = demo_phos.ALL_TABLES['green']
            for ph, enc in self.encoders.items():
                enc.write(pics[ph] + demo_phos.tint(strip, tabs))
        bad = through_fake(tinted_strip)
        need(bad, 'a tinted strip went unnoticed: the encoder row cannot '
                  'tell furniture from picture')
        return bad[0][:70]

    @row('abort with the encoder running: killed, its directory gone, '
         'OUTDIR empty')
    def _():
        out = os.path.join(tmp, 'g')
        os.mkdir(out)
        clear_notes()
        rc, err, so = cli2([PLANTED, '--record', out], fake_env)
        need(rc == 1 and 'FAIL planted_wrong' in err,
             f'exit {rc}: {err[-300:]}')
        notes = notes_of()
        need(len(notes) == len(demo_phos.NAMES),
             f'{len(notes)} encoders were started, wanted one per phosphor')
        for stem, note in sorted(notes.items()):
            need(not note['done'], f'{stem}: the fake encoder ran to the '
                                   f'end: it was not aborted')
            try:
                os.kill(note['pid'], 0)
                alive = True
            except ProcessLookupError:
                alive = False
            need(not alive, f"{stem}: encoder pid {note['pid']} is still "
                            f"running")
            need(not os.path.exists(note['outdir']),
                 f"the work directory {note['outdir']} was left behind")
        need(os.listdir(out) == [], f'left {os.listdir(out)} in OUTDIR')
        return 'all three killed, reaped, directory removed, OUTDIR empty'

    @row('ffmpeg missing: --record names it, builds nothing')
    def _():
        env = dict(os.environ, PATH=os.path.join(tmp, 'nothing'))
        out = os.path.join(tmp, 'h')
        rc, err, so = cli2([FAST16, '--record', out], env)
        need(rc == 2 and 'ffmpeg' in err, f'exit {rc}: {err[-200:]}')
        need(not os.path.exists(out), 'OUTDIR was created')
        return err.strip().splitlines()[-1][:80]

    @row('hold(0) steps no frame; run_demo restores e2e_term.DISK')
    def _():
        before = e2e_term.DISK
        copy = os.path.join(tmp, 'play-copy.po')
        shutil.copyfile(before, copy)
        r = dr.run_demo(HOLD0, record=os.path.join(tmp, 'i'),
                        encode=False, seed=SEED, image=copy)
        need(r.ok, f'hold0 failed: {r.error}')
        need(r.frames == 0 and r.stepped == 0 and r.cycles == 0,
             f'hold(0) stepped {r.stepped} frames, {r.cycles} cycles')
        need(e2e_term.DISK == before,
             f'e2e_term.DISK left as {e2e_term.DISK}')
        # and on a failing run
        r = dr.run_demo(PLANTED, seed=SEED, image=copy)
        need(not r.ok and e2e_term.DISK == before,
             'DISK not restored after a failed demo')
        return '0 frames; DISK restored after a pass and a failure'

    @row('one demo raising does not hide the next (the CLI goes on)')
    def _():
        rc, err, so = cli2([RAISES, HOLD0])
        need(rc == 1, f'exit {rc}')
        need('FAIL raises' in err and 'RuntimeError' in err and 'boom' in err,
             f'the exception was not reported: {err[-300:]}')
        need('PASS hold0' in so, f'the second demo did not run: {so!r}')
        return 'FAIL raises, then PASS hold0'

    @row('TEETH: a grep that drops one line turns mygrep red')
    def _():
        res = dr.run_demo(MYGREP, seed=SEED, setup=[
            'cp /bin/grep /bin/grep.real', 'rm /bin/grep',
            "echo '#!/bin/sh' > /bin/grep",
            "echo '/bin/grep.real $1 $2 | sed 1d' >> /bin/grep"])
        need(not res.ok, 'mygrep stayed GREEN with a grep that drops a '
                         'line: expect_lines does not compare rows')
        need('grep prints the same rows' in str(res.error),
             f'red, but not there:\n{str(res.error)[:300]}')
        return "red at 'grep prints the same rows'"
    # ---- the UltraTerm display (docs/DEMO-UT.md) ------------------------
    # The renderer is scripts/demo_ut.py. Its rows: a ut record of mygrep
    # is drawn by it (read back by an independent OCR through the card's
    # own character ROM), the attribute register and the cursor are drawn
    # as the manual and the card model say, both displays share one frame
    # size and one file layout, and the two displays must agree on keys
    # and text. TEETH: a wrong character-ROM offset and an ignored
    # inverse attribute each turn a row red.
    import demo_ut

    ut_rom = demo_ut.load_chargen()
    ut_hq = 0x800                    # $C0B3 bit 2 clear: the dense set
    ut_frames = []
    ut_meta = {}

    uttint = TintWatch()

    def ut_collect(index, frame, info):
        ut_frames.append((len(frame), info['png'], index))
        ut_meta['rgb'] = info['rgb']
        uttint.see(index, frame, info)

    def glyph_table(rom, base=ut_hq):
        """16 ROM bytes -> character, for the printable ASCII of a set."""
        return {bytes(rom[base + c * 16:base + c * 16 + 16]): chr(c)
                for c in range(0x20, 0x7F)}

    def ocr(rgb, rom, cols=80, rows=24, base=ut_hq):
        """Read a native card picture back as text, cell by cell, by
        looking each 9x16 block up in the character ROM (the first eight
        dots; the ninth is bit 0 again, checked elsewhere). A cell that is
        not a glyph (the cursor's inverse block) reads as NUL."""
        table = glyph_table(rom, base)
        out = []
        for r in range(rows):
            line = ''
            for c in range(cols):
                rowbytes = []
                for y in range(16):
                    o = ((r * 16 + y) * cols * 9 + c * 9) * 3
                    bits = 0
                    for x in range(8):
                        bits = bits << 1 | (rgb[o + x * 3:o + x * 3 + 3] !=
                                            b'\0\0\0')
                    rowbytes.append(bits)
                line += table.get(bytes(rowbytes), '\0')
            out.append(line)
        return out

    def last_checkpoint_rows(rec):
        return [r for r in rec.transcript[-1][1]]

    @row('ut: mygrep records on the UltraTerm; the frames are the '
         'renderer\'s, read back through the card\'s own ROM')
    def _():
        r = dr.run_demo(MYGREP, record=os.path.join(tmp, 'u1'), encode=False,
                        seed=SEED, backend='ut', on_frame=ut_collect)
        need(r.ok, f'ut record failed: {r.error}')
        ut_meta['res'] = r
        need(r.backend == 'ut' and r.frames > 1000 and
             r.frames == len(ut_frames), f'{r.frames} frames')
        need(all(png is None for _, png, _ in ut_frames),
             'a ut frame came from screen_image')
        need({n for n, _, _ in ut_frames} == {ov.FRAME_W * ov.FRAME_H * 3},
             'a ut frame is not the one frame size')
        rgb = ut_meta['rgb']
        need(len(rgb) == 720 * 384 * 3, f'native picture {len(rgb)} bytes')
        colours = {rgb[i:i + 3] for i in range(0, len(rgb), 3)}
        need(colours <= {b'\0\0\0', bytes(demo_ut.LIT),
                         bytes(demo_ut.BRIGHT)} and len(colours) >= 2,
             f'not the card\'s monochrome: {sorted(colours)[:5]}')
        text = ocr(rgb, ut_rom)
        want = last_checkpoint_rows(r)
        got = [t.replace('\0', ' ').rstrip() for t in text]
        got = [t for t in got if t]
        need(got == want,
             f'the last frame, read back through the character ROM, is not '
             f'the last checkpoint:\n--- read\n' + '\n'.join(got) +
             '\n--- checkpoint\n' + '\n'.join(want))
        # the poster is that picture on the frame, doubled
        for phos in demo_phos.NAMES:
            pw, ph, _ = demo_png.decode_rgb(open(os.path.join(
                r.out_dir, f'poster-ut-{phos}.png'), 'rb').read())
            need((pw, ph) == (2 * ov.FRAME_W, 2 * ov.PIC_H),
                 f'poster-ut-{phos}.png is {pw}x{ph}')
        return f'{r.frames} frames, {len(got)} rows read back equal'

    @row('ut and //e share one frame size; the //e frames are the pillared '
         '560 picture')
    def _():
        need(ut_frames and rec and rec.ok, 'no recordings')
        sizes = {n for n, _, _ in ut_frames}
        need(sizes == {len(last_frame[0])},
             f'ut frame {sizes}, //e frame {len(last_frame[0])}')
        pic = last_frame[0][:PIC_BYTES]
        need(pic[:ov.APPLE_Y * ov.FRAME_W * 3] ==
             bytes(ov.APPLE_Y * ov.FRAME_W * 3) and
             pic[(ov.APPLE_Y + ov.SCREEN_H) * ov.FRAME_W * 3:] ==
             bytes(ov.APPLE_Y * ov.FRAME_W * 3), 'the bands are not black')
        for y in (ov.APPLE_Y, ov.APPLE_Y + 100, ov.APPLE_Y + 383):
            o = y * ov.FRAME_W * 3
            need(pic[o:o + ov.APPLE_X * 3] == bytes(ov.APPLE_X * 3) and
                 pic[o + (ov.APPLE_X + ov.SCREEN_W) * 3:
                     o + ov.FRAME_W * 3] == bytes(ov.APPLE_X * 3),
                 f'row {y}: the pillars are not black')
        return (f'{ov.FRAME_W}x{ov.FRAME_H} both; {ov.APPLE_X}-px pillars, '
                f'{ov.APPLE_Y}-px bands')

    def cell_rows(ch, rom=None, base=ut_hq):
        rom = rom or ut_rom
        return bytes(rom[base + ord(ch) * 16:base + ord(ch) * 16 + 16])

    def one_cell_state(b3, codes, r10=0, r11=15, cur=None, cols=4):
        crtc = [0] * 18
        crtc[1], crtc[6], crtc[9] = cols, 1, 15
        crtc[10], crtc[11] = r10, r11
        ca = 4000 if cur is None else cur
        crtc[14], crtc[15] = ca >> 8, ca & 255
        vram = bytearray(4096)
        vram[:len(codes)] = bytes(codes)
        st = dict(installed=True, crtc=crtc, reg_b3=b3,
                  charset_base=0 if b3 & 4 else 0x800)
        return st, bytes(vram)

    def cell_bits(rgb, col, cols):
        """The 16 dot-bytes of cell `col` of a one-row native picture."""
        out = []
        for y in range(16):
            o = (y * cols * 9 + col * 9) * 3
            bits = 0
            for x in range(8):
                bits = bits << 1 | (rgb[o + x * 3:o + x * 3 + 3] !=
                                    b'\0\0\0')
            ninth = rgb[o + 24:o + 27] != b'\0\0\0'
            need(ninth == bool(bits & 1),
                 'the ninth dot of a cell is not bit 0 repeated')
            out.append(bits)
        return bytes(out)

    def cell_colour(rgb, col, cols):
        o = (col * 8) * 3
        seen = {rgb[(y * cols * 9 + col * 9 + x) * 3:
                    (y * cols * 9 + col * 9 + x) * 3 + 3]
                for y in range(16) for x in range(9)}
        return seen - {b'\0\0\0'}

    def attribute_checks():
        """The $C0B3 attribute register as the manual (chapter 8) and
        the card model have it, against the character ROM's own bytes:
        bit 7 of the latch = the DIP switches' factory look; clear = a
        cell with bit 7 set takes b5 (inverse) and b4 (highlight), one
        without takes b1 and b0. Hand-derived, not read from demo_ut."""
        a = ord('A')
        cases = [          # b3, plain cell (inverse, bright), alt cell
            (0x80, (0, 0), (1, 0)),         # DIPs, factory, dense set
            (0x84, (0, 0), (1, 0)),         # DIPs, standard set
            (0x20, (0, 0), (1, 0)),         # maux's default
            (0x10, (0, 0), (0, 1)),         # bold, no inverse
            (0x31, (0, 1), (1, 1)),         # all bright
            (0x02, (1, 0), (0, 0)),         # plain cells inverse
            (0x00, (0, 0), (0, 0)),
        ]
        for b3, (pinv, pbright), (ainv, abright) in cases:
            base = 0 if b3 & 4 else 0x800   # $C0B3 bit 2 SET = set 0
            plain = cell_rows('A', base=base)
            inv = bytes(b ^ 0xFF for b in plain)
            pb, ab = (inv if pinv else plain), (inv if ainv else plain)
            st, vram = one_cell_state(b3, [a, a | INVERSE_BIT])
            w, h, rgb = demo_ut.render_native(st, vram, ut_rom, False)
            need((w, h) == (36, 16), f'{w}x{h}')
            for col, bits, bright in ((0, pb, pbright), (1, ab, abright)):
                need(cell_bits(rgb, col, 4) == bits,
                     f'$C0B3={b3:#04x}: cell {col} has the wrong dots')
                want = {bytes(demo_ut.BRIGHT if bright
                              else demo_ut.LIT)}
                got = cell_colour(rgb, col, 4)
                need(got == want or (not got and not any(bits)),
                     f'$C0B3={b3:#04x}: cell {col} colour {got}')
        return f'{len(cases)} attribute programs'

    @row('ut: the attribute register is drawn as the manual has it')
    def _():
        return attribute_checks()

    def cursor_checks():
        a = ord('A')
        full = bytes(b ^ 0xFF for b in cell_rows('A'))
        # steady block, scan lines 4..7 only: those rows are inverted
        st, vram = one_cell_state(0x20, [a, a], r10=4, r11=7, cur=0)
        w, h, rgb = demo_ut.render_native(st, vram, ut_rom, True)
        g = cell_rows('A')
        want = bytes(b ^ 0xFF if 4 <= y <= 7 else b
                     for y, b in enumerate(g))
        need(cell_bits(rgb, 0, 4) == want, 'cursor lines 4-7 are wrong')
        need(cell_bits(rgb, 1, 4) == g, 'the cursor leaked to the next cell')
        # R10 bits 6:5 = 01: not displayed
        st, vram = one_cell_state(0x20, [a], r10=0x20, r11=15, cur=0)
        need(cell_bits(demo_ut.render_native(st, vram, ut_rom, True)[2],
                       0, 4) == g, 'a hidden cursor was drawn')
        # blink: 10 = 1/16 field rate, 11 = 1/32; on in the first half
        for mode, period in ((2, 16), (3, 32)):
            st, vram = one_cell_state(0x20, [a], r10=mode << 5, cur=0)
            seq = [demo_ut.cursor_visible(st, f) for f in range(2 * period)]
            need(seq == [True] * (period // 2) + [False] * (period // 2) +
                 [True] * (period // 2) + [False] * (period // 2),
                 f'blink mode {mode} is not 1/{period} of the field rate')
        # a cursor off the displayed area draws nothing
        st, vram = one_cell_state(0x20, [a], r10=0, cur=3999)
        need(cell_bits(demo_ut.render_native(st, vram, ut_rom, True)[2],
                       0, 4) == g, 'an off-screen cursor was drawn')
        # a cursor over an inverse cell un-inverts it (XOR, as the chip)
        st, vram = one_cell_state(0x20, [a | INVERSE_BIT], cur=0)
        need(cell_bits(demo_ut.render_native(st, vram, ut_rom, True)[2],
                       0, 4) == g, 'cursor over inverse is not XOR')
        return 'steady, hidden, blink 1/16 and 1/32, off-screen, XOR'

    @row('ut: the cursor and the CRTC geometry are drawn as the 6845 has them')
    def _():
        r = cursor_checks()
        st, vram = one_cell_state(0x84, [65, 66], cols=2)
        st['crtc'][1], st['crtc'][6], st['crtc'][9] = 132, 24, 11
        w, h, _ = demo_ut.render_native(st, bytes(4096), ut_rom, False)
        need((w, h) == (132 * 9, 24 * 12), f'132x24 cells of 12 lines: {w}x{h}')
        st['crtc'][8] = 3                                 # interlace sync
        w, h, _ = demo_ut.render_native(st, bytes(4096), ut_rom, False)
        need((w, h) == (132 * 9, 24 * 13), f'interlace is R9+2 rasters a row: {w}x{h}')
        try:
            ov.pad_picture(bytes(w * h * 3), w, h)
        except ValueError:
            return r + '; 132x24 and interlace sized; too-big refused'
        raise AssertionError('a picture bigger than the frame was padded')

    def cell_bits_row(rgb, col, cols, row=0):
        out = []
        for y in range(16):
            o = (((row * 16) + y) * cols * 9 + col * 9) * 3
            bits = 0
            for x in range(8):
                bits = bits << 1 | (rgb[o + x * 3:o + x * 3 + 3] !=
                                    b'\0\0\0')
            out.append(bits)
        return bytes(out)

    @row('ut: a cell taller than 16 rasters wraps the glyph line (RA & 15); '
         'the cell is nine dots wide')
    def _():
        st, vram = one_cell_state(0x20, [ord('A')], cols=2)
        st['crtc'][9] = 19                               # 20 rasters a row
        w, h, rgb = demo_ut.render_native(st, vram, ut_rom, False)
        need((w, h) == (18, 20), f'{w}x{h}: nine dots, 20 rasters')
        g = cell_rows('A')
        for y in range(20):
            o = (y * 18) * 3
            bits = 0
            for x in range(8):
                bits = bits << 1 | (rgb[o + x * 3:o + x * 3 + 3] != b'\0\0\0')
            need(bits == g[y & 15], f'raster {y} is not glyph line {y & 15}')
        return 'raster 16 repeats glyph line 0; 18x20 dots for two cells'

    @row('TEETH: man sh patched on the guest\'s image copy (a plain word, and '
         'an emphasised one, of the first screenful -> QQQ...) turns man red '
         'on BOTH displays')
    def _():
        import re
        import demo_host
        from a2til import prodos
        man = os.path.join(ROOT, 'site', 'demos', 'man.py')
        done = []
        # The words to break come from the page itself, not from a phrase
        # remembered here. PLAIN: the first run of 6+ letters in the first
        # screenful (the film's first checkpoint), at its FIRST occurrence
        # in the file, which must therefore be on that screen. EMPHASISED:
        # the first word the page sets in bold or inverse (ESC[1m / ESC[7m)
        # on that screen, so the //e's inverse cells are proven read.
        for variant in ('plain', 'emphasised'):
            copy = os.path.join(tmp, f'play-man-{variant}.po')
            shutil.copyfile(demo_host.PLAY, copy)
            v = prodos.Volume(copy)
            ent = [e for e in v.scandir('/USR/MAN') if e.name == 'SH'][0]
            data = bytes(v.read_file('/USR/MAN/SH'))
            txt = ''.join(chr(c & 0x7F) for c in data).replace('\r', '\n')
            shown = len('\n'.join(txt.split('\n')[:23]))   # more's screenful
            if variant == 'plain':
                m = re.search(r'[A-Za-z]{6,}', txt[:shown])
                need(m is not None, 'no word of 6+ letters on the screen')
                word = m.group(0)
                at = txt.find(word)
                need(at < shown, f'{word!r} first occurs at {at}, past the '
                                 f'screenful')
            else:
                m = re.search(r'\x1b\[(?:1|7)m([A-Za-z]{4,})', txt[:shown])
                need(m is not None, 'no emphasised word on the first screen')
                word, at = m.group(1), m.start(1)
            new = bytes(0x80 | ord('Q') for _ in word)
            v.write_file('/USR/MAN/SH', data[:at] + new + data[at + len(word):],
                         file_type=ent.type, aux_type=ent.aux_type,
                         overwrite=True)
            del v
            for backend in ('text80', 'ut'):
                r = dr.run_demo(man, seed=SEED, image=copy, backend=backend)
                need(not r.ok, f'man stayed GREEN on {backend} with the '
                               f'guest showing QQQ for the {variant} word '
                               f'{word!r}: the screen is not compared as it is')
                need('first screenful' in str(r.error) and
                     'QQQ' in str(r.error),
                     f'red on {backend} ({variant}), but not at the first '
                     f'screenful:\n{str(r.error)[:300]}')
            done.append(f'{variant} {word!r}')
        return 'red on text80 and on ut at the first screenful: ' + ', '.join(done)

    @row('stamp: demo_stamp.settings() resolves the tools exactly as '
         'mcp_drive.py does')
    def _():
        import demo_stamp
        import mcp_drive
        st = demo_stamp.settings()
        need(st['supervisor'] == mcp_drive.SUPERVISOR and
             st['roms'] == mcp_drive.ROMS_DIR and
             st['verilogapple'] == mcp_drive.VERILOGAPPLE,
             f'{st} vs {mcp_drive.SUPERVISOR} {mcp_drive.ROMS_DIR}')
        return 'supervisor, ROM dir and checkout agree'

    @row('stamp: an input edited while the recording runs is refused, not '
         'stamped as fresh')
    def _():
        import demo_stamp
        scr = os.path.join(tmp, 'stampme.py')
        open(scr, 'w').write('x = 1\n')
        snap = demo_stamp.snapshot(scr)
        need(demo_stamp.finish(snap) == [], 'untouched inputs reported moved')
        open(scr, 'a').write('x = 2\n')
        moved = demo_stamp.finish(snap)
        need(moved and moved[0].endswith('stampme.py'),
             f'an edited script was not noticed: {moved}')
        snap = demo_stamp.snapshot(scr)
        key = next(k for k in snap['files'] if k.endswith('demo_overlay.py'))
        snap['files'][key] = '0' * 64          # as if edited since the hash
        need(key in demo_stamp.finish(snap), 'an edited recorder file was '
                                            'not noticed')
        return 'script and recorder file edits both reported'

    def card_state(r9, rows=24, cols=80, text=b'$ ls'):
        crtc = [0] * 18
        crtc[1], crtc[6], crtc[9] = cols, rows, r9
        crtc[10], crtc[11] = 0x20, r9
        st = dict(installed=True, crtc=crtc, reg_b3=0x20, charset_base=0x800)
        vram = bytearray(4096)
        vram[:len(text)] = text
        return st, bytes(vram)

    @row('ut: the FIXED cell (R9=8, the firmware\'s 80x24) is 720x216 native '
         'and fills the 720x432 picture with doubled scan lines')
    def _():
        need((demo_ut.FIT_W, demo_ut.FIT_H) == (ov.FRAME_W, ov.PIC_H),
             'demo_ut.fit and the overlay disagree on the picture area')
        st, vram = card_state(8)
        w, h, rgb = demo_ut.render_native(st, vram, ut_rom, False)
        need((w, h) == (720, 216), f'native {w}x{h}')
        fw, fh, frgb = demo_ut.fit(w, h, rgb)
        need((fw, fh) == (ov.FRAME_W, ov.PIC_H), f'fitted {fw}x{fh}')
        for y in range(h):
            a = frgb[2 * y * fw * 3:(2 * y + 1) * fw * 3]
            need(a == frgb[(2 * y + 1) * fw * 3:(2 * y + 2) * fw * 3] ==
                 rgb[y * w * 3:(y + 1) * w * 3], f'line {y} is not doubled')
        # nine rasters a row, each the glyph's own line (set at ROM $800)
        g = cell_rows('$', base=0x800)
        for y in range(9):
            o = (y * 720) * 3
            bits = 0
            for x in range(8):
                bits = bits << 1 | (rgb[o + x * 3:o + x * 3 + 3] != b'\0\0\0')
            need(bits == g[y], f'raster {y} of the first cell is not glyph line {y}')
        padded = ov.pad_picture(frgb, fw, fh)
        need(padded == frgb, 'a full-frame card picture was padded')
        # the popover sits at the picture's lower right, on the picture
        box = ov.render_box('IYKYK ;-)', fw, fh)
        need(box[1] + box[3] == ov.PIC_H - ov.BOX_MARGIN, 'box not at bottom')
        return '720x216 -> 720x432, glyph lines 0-8, popover on the picture'

    @row('ut: a 384-line card picture (R9=$0F, or the original card\'s '
         'interlaced rows) is not doubled, sits centred, and a card '
         'picture bigger than the frame is cropped')
    def _():
        st, vram = card_state(15)
        w, h, rgb = demo_ut.render_native(st, vram, ut_rom, False)
        need((w, h) == (720, 384), f'native {w}x{h}')
        fw, fh, frgb = demo_ut.fit(w, h, rgb)
        need((fw, fh, frgb) == (w, h, rgb), 'a 384-line picture was altered')
        pad = ov.pad_picture(frgb, fw, fh)
        y0 = (ov.PIC_H - 384) // 2
        need(pad[:y0 * 720 * 3] == bytes(y0 * 720 * 3) and
             pad[y0 * 720 * 3:(y0 + 384) * 720 * 3] == rgb,
             'not centred on black bands')
        st, vram = card_state(11, rows=24, cols=132)    # 1188x288 native
        w, h, rgb = demo_ut.render_native(st, vram, ut_rom, False)
        need(w > 720, f'{w}x{h}: not wider than the frame')
        fw, fh, frgb = demo_ut.fit(w, h, rgb)
        need((fw, fh) == (720, min(h, 432) if 2 * h > 432 else 432) and
             len(frgb) == fw * fh * 3, f'cropped to {fw}x{fh}')
        ov.pad_picture(frgb, fw, fh)                  # fits, no raise
        need(frgb[:720 * 3] == rgb[:720 * 3], 'crop is not the top left')
        return 'no crash: 384 kept and centred; 132 columns cropped to 720'

    @row('TEETH: a character ROM or firmware that is not the pinned one '
         'is refused, by name, for both revisions')
    def _():
        import hashlib
        seen = []
        for rv in demo_ut.REVISIONS.values():
            good = open(rv.chargen_path(), 'rb').read()
            need(hashlib.sha256(good).hexdigest() == rv.chargen_sha,
                 f'the pinned {rv.name} sha256 is not the ROM in use')
            for what, data in (('one bit flipped',
                                bytes([good[0] ^ 1]) + good[1:]),
                               ('short', good[:4095]),
                               ('shifted a glyph row', good[1:] + b'\0')):
                f = os.path.join(tmp, 'chargen-bad.bin')
                open(f, 'wb').write(data)
                try:
                    demo_ut.load_chargen(rv, f)
                except demo_ut.UTError:
                    seen.append(f'{rv.name} {what}')
                    continue
                raise AssertionError(f'a {rv.name} ROM ({what}) was accepted')
            need(bytes(demo_ut.load_chargen(rv)) == good,
                 f'the right {rv.name} ROM was refused')
            # the other revision's ROM is not this one's, by the pins
            other = [o for o in demo_ut.REVISIONS.values() if o is not rv][0]
            f = os.path.join(tmp, 'chargen-other.bin')
            open(f, 'wb').write(open(other.chargen_path(), 'rb').read())
            try:
                demo_ut.load_chargen(rv, f)
            except demo_ut.UTError:
                seen.append(f'{rv.name} given {other.name}\'s ROM')
            else:
                raise AssertionError(f'{rv.name} accepted {other.name}\'s ROM')
            fw = open(rv.firmware_path(), 'rb').read()
            need(hashlib.sha256(fw).hexdigest() == rv.firmware_sha and
                 bytes(demo_ut.load_firmware(rv)) == fw,
                 f'the pinned {rv.name} firmware is not the one in use')
        return f'{len(seen)} wrong ROMs refused, the right ones load'

    @row('ut: the ORIGINAL card (v1) is interlaced, 16 rasters a row, '
         '720x384, drawn through its own tall set; the updated card (v3) '
         'is 720x216')
    def _():
        e1, e3 = demo_ut.format4_entry('v1'), demo_ut.format4_entry('v3')
        need(bytes(e1).hex() == '7a505d381f06181c030e600c',
             f'v1 format 4 is {bytes(e1).hex()}')
        need(bytes(e3).hex() == '7a505d381c01181a00086008',
             f'v3 format 4 is {bytes(e3).hex()}')
        rom1, rom3 = demo_ut.load_chargen('v1'), demo_ut.load_chargen('v3')
        text = b'$ big gypsy ls'
        shapes = {}
        for name, ent, rom in (('v1', e1, rom1), ('v3', e3, rom3)):
            crtc = list(ent) + [0] * 6
            crtc[10] = 0                             # steady cursor
            st = dict(installed=True, crtc=crtc, reg_b3=0x20,
                      charset_base=0x800)
            vram = bytearray(4096)
            vram[:len(text)] = text
            w, h, rgb = demo_ut.render_native(st, bytes(vram), rom, False)
            shapes[name] = (w, h)
            # the glyph rows are the ROM's own bytes at the offset $C0B3
            # bit 2 clear selects ($800), one raster per glyph line
            g = cell_rows('b', rom, base=0x800)
            for y in range(h // 24):
                o = (y * 720 + 2 * 9) * 3             # the 'b' of 'big'
                bits = 0
                for x in range(8):
                    bits = bits << 1 | (rgb[o + x * 3:o + x * 3 + 3] !=
                                        b'\0\0\0')
                need(bits == g[y & 15], f'{name}: raster {y} of "b" is not '
                     f'glyph line {y & 15}')
        need(shapes == {'v1': (720, 384), 'v3': (720, 216)}, f'{shapes}')
        # the v1 set is TALL: 'g' reaches ROM line 11; v3's stops by 8
        g1 = cell_rows('g', rom1, base=0x800)
        g3 = cell_rows('g', rom3, base=0x800)

        def last(g):
            return max(i for i, b in enumerate(g) if b)
        need(last(g1) == 11 and last(g3) <= 8,
             f'g ends {last(g1)} / {last(g3)}')
        return 'v1 720x384 (g to line 11), v3 720x216'

    @row('TEETH: drawing the original card with the updated card\'s '
         'character ROM turns the read-back red, and a CRTC that is not '
         'the revision\'s format-4 entry is refused')
    def _():
        e1 = demo_ut.format4_entry('v1')
        rom1, rom3 = demo_ut.load_chargen('v1'), demo_ut.load_chargen('v3')
        text = 'big gypsy $ ls -l /usr'
        vram = bytearray(4096)
        vram[:len(text)] = text.encode()
        crtc = list(e1) + [0] * 6
        crtc[10] = 0x20                              # no cursor
        st = dict(installed=True, crtc=crtc, reg_b3=0x20, charset_base=0x800)
        w, h, rgb = demo_ut.render_native(st, bytes(vram), rom1, False)
        good = [t.replace('\0', ' ').rstrip() for t in ocr(rgb, rom1)]
        need(good[0] == text, f'control read-back is {good[0]!r}')
        w, h, rgb = demo_ut.render_native(st, bytes(vram), rom3, False)
        bad = [t.replace('\0', ' ').rstrip() for t in ocr(rgb, rom1)]
        need(bad[0] != text, 'the v3 ROM still reads back as the v1 text: '
             'the read-back cannot tell the two cards\' fonts apart')
        # the guest-side half: the CRTC must be the film's revision's
        demo_ut.check_programmed(st, 'v1')
        for rev, entry in (('v1', demo_ut.format4_entry('v3')),
                           ('v3', e1)):
            wrong = dict(st, crtc=list(entry) + [0] * 6)
            try:
                demo_ut.check_programmed(wrong, rev)
            except demo_ut.UTError as e:
                need('format-4' in str(e), str(e))
            else:
                raise AssertionError(f'a {rev} film accepted the other '
                                     f'card\'s CRTC')
        return 'v3 ROM on a v1 screen reads back wrong; mixed CRTC refused'

    @row('ut: the display start (hardware scroll) moves the picture')
    def _():
        st, vram = one_cell_state(0x20, [ord('A')] * 2 + [ord('B')] * 2,
                                  cols=2)
        st['crtc'][6] = 2                               # two rows
        st['crtc'][13] = 2                              # start = row 1
        w, h, rgb = demo_ut.render_native(st, vram, ut_rom, False)
        need(cell_bits_row(rgb, 0, 2) == cell_rows('B'),
             'the top row is not the second row of VRAM after a start bump')
        return 'R12/R13 honoured'

    def with_patch(obj, name, value, fn):
        old = getattr(obj, name)
        setattr(obj, name, value)
        try:
            fn()
        finally:
            setattr(obj, name, old)

    @row('TEETH: a character-ROM offset one glyph row off turns the '
         'read-back red')
    def _():
        r = ut_meta.get('res')
        need(r and r.ok, 'no ut recording')
        shifted = bytes(ut_rom[1:]) + b'\0'          # every glyph row +1
        st = {}
        rgb = None
        want = last_checkpoint_rows(r)
        # render the last screen the transcript knows through a wrong ROM
        rows80 = [(row + ' ' * 80)[:80] for row in want]
        vram = bytearray(4096)
        for i, line in enumerate(rows80):
            for j, ch in enumerate(line):
                vram[i * 80 + j] = ord(ch)
        crtc = [0] * 18
        crtc[1], crtc[6], crtc[9] = 80, len(rows80), 15
        crtc[10] = 0x20
        st = dict(installed=True, crtc=crtc, reg_b3=0x24 & ~4,
                  charset_base=0x800)
        w, h, rgb = demo_ut.render_native(st, bytes(vram), ut_rom, False)
        good = [t.replace('\0', ' ').rstrip()
                for t in ocr(rgb, ut_rom, 80, len(rows80))]
        need([t for t in good if t] == want,
             'the control render does not read back: the tooth proves '
             'nothing')
        w, h, rgb = demo_ut.render_native(st, bytes(vram), shifted, False)
        bad = [t.replace('\0', ' ').rstrip()
               for t in ocr(rgb, ut_rom, 80, len(rows80))]
        need([t for t in bad if t] != want,
             'a ROM offset by a glyph row still reads back as the text: '
             'the OCR row has no teeth')
        return 'right ROM reads back equal; the shifted ROM does not'

    @row('TEETH: a renderer that ignores the inverse attribute turns the '
         'attribute row red')
    def _():
        try:
            with_patch(demo_ut, 'attrs', lambda b3, code: (False, False),
                       attribute_checks)
        except AssertionError as e:
            return str(e)[:70]
        raise AssertionError('the attribute row stayed green with inverse '
                             'ignored')

    @row('TEETH: a renderer whose ninth dot is always lit turns the '
         'attribute row red')
    def _():
        real = demo_ut._row_rgb

        def lit_ninth(bits, lit, cell_w=demo_ut.CELL_W):
            row = real(bits, lit, cell_w)
            if cell_w == 9:
                row = row[:24] + bytes(demo_ut.LIT if lit == 1
                                       else demo_ut.BRIGHT)
            return row
        try:
            with_patch(demo_ut, '_row_rgb', lit_ninth, attribute_checks)
        except AssertionError as e:
            need('ninth dot' in str(e), f'red, but not on the ninth dot: {e}')
            return str(e)[:70]
        raise AssertionError('the attribute row stayed green with an '
                             'always-lit ninth dot')

    @row('TEETH: a renderer that ignores highlight turns the attribute '
         'row red')
    def _():
        real = demo_ut.attrs
        try:
            with_patch(demo_ut, 'attrs',
                       lambda b3, code: (real(b3, code)[0], False),
                       attribute_checks)
        except AssertionError as e:
            return str(e)[:70]
        raise AssertionError('the attribute row stayed green with '
                             'highlight ignored')

    @row('ut: both displays\' files sit side by side; one display '
         'rerecorded leaves the other alone; the card records the same twice')
    def _():
        out = os.path.join(tmp, 'u3')
        rc, err = cli([MYGREP, '--record', out, '--no-encode',
                       '--seed', str(SEED)])
        need(rc == 0, f'CLI run failed ({rc}): {err[-300:]}')
        d = os.path.join(out, 'mygrep')
        want = {'frames.sha256', 'frames-ut.sha256', 'mygrep.vtt',
                'mygrep-ut.vtt', 'transcript.txt', 'transcript-ut.txt',
                'mygrep.stamp.json', 'mygrep-ut.stamp.json'}
        for sfx in ('', '-ut'):
            want |= {f'poster{sfx}-{ph}.png' for ph in demo_phos.NAMES}
        need(set(os.listdir(d)) == want,
             f'files {sorted(os.listdir(d))}, wanted {sorted(want)}')
        # the freshness stamps (scripts/demo_stamp.py): one per display,
        # naming its display, hashing the script and the recorder as they
        # are now, and the image it booted
        import demo_stamp
        for fn, bk in (('mygrep.stamp.json', 'text80'),
                       ('mygrep-ut.stamp.json', 'ut')):
            st = json.load(open(os.path.join(d, fn)))
            need(st['backend'] == bk, f'{fn}: backend {st["backend"]!r}')
            need(tuple(st['film_size']) == demo_stamp.FILM_SIZE and
                 tuple(st['poster_size']) == demo_stamp.POSTER_SIZE,
                 f'{fn}: declared sizes {st["film_size"]} {st["poster_size"]}')
            need(st['inputs']['image'] == demo_stamp.sha256_file(
                     demo_stamp.IMAGES['play']),
                 f'{fn}: the image hash is not the play image\'s')
            now = demo_stamp.inputs_now(st, MYGREP,
                                        demo_stamp.IMAGES['play'])
            why = demo_stamp.stale_reasons(st, now)
            need(not why, f'{fn}: stale at once: {why}')
            # every module the recorder loaded is listed, not a hand list
            for mod in ('scripts/demo_record.py', 'scripts/e2e_term.py',
                        'scripts/mcp_drive.py'):
                need(mod in st['inputs']['files'],
                     f'{fn}: {mod} is not in the stamp\'s files')
            fk = st['inputs']['files']
            need('ext:supervisor' in fk and 'ext:worker_fast' in fk,
                 f'{fn}: the supervisor/worker are not stamped by role')
            need('ext:rom/iie_cd_ef.rom' in fk,
                 f'{fn}: the //e ROM is not stamped')
            need(not any(os.path.isabs(k) for k in fk),
                 f'{fn}: an absolute path in the stamp: '
                 f'{[k for k in fk if os.path.isabs(k)]}')
            need('ext:rom/ultraterm/readme.txt' not in fk and
                 'ext:rom/ssc.rom' not in fk,
                 f'{fn}: a file the machine does not load is stamped')
            card = {'ext:rom/' + demo_stamp.UT_FIRMWARE,
                    'ext:rom/' + demo_stamp.UT_CHARGEN}
            need((card <= set(fk)) == (bk == 'ut') and
                 (st['inputs']['ut_revision'] == demo_stamp.UT_REVISION) ==
                 (bk == 'ut'),
                 f'{fn}: the UltraTerm firmware/chargen/revision belong in '
                 f'the card stamp only')
            need(st['inputs']['setup'] == [] and
                 st['inputs']['host_clock'] is False,
                 f'{fn}: options not stamped')
            need(fn.replace('.stamp.json', '.vtt') in st['outputs'],
                 f'{fn}: no output bound')
            sfx = '-ut' if bk == 'ut' else ''
            need(all(f'poster{sfx}-{ph}.png' in st['outputs']
                     for ph in demo_phos.NAMES),
                 f'{fn}: a phosphor\'s poster is not bound: '
                 f'{sorted(st["outputs"])}')
            need('scripts/demo_phos.py' in st['inputs']['files'],
                 f'{fn}: the palette is not an input of the film')
            bad = dict(now, script='0' * 64)
            need(demo_stamp.stale_reasons(st, bad),
                 f'{fn}: a different script hash was not noticed')
            key = next(k for k in st['inputs']['files']
                       if k.endswith('mcp_drive.py'))
            bad = dict(now, files=dict(now['files'], **{key: '0' * 64}))
            need(any(key in w for w in demo_stamp.stale_reasons(st, bad)),
                 f'{fn}: an edited loaded module ({key}) was not noticed')
        first_ut = open(os.path.join(d, 'frames-ut.sha256')).read()
        first_e = open(os.path.join(d, 'frames.sha256')).read()
        need(first_ut != first_e, 'the two displays hash the same')
        rc, err = cli([MYGREP, '--record', out, '--no-encode', '--backend',
                       'ut', '--seed', str(SEED)])
        need(rc == 0, f'ut-only run failed ({rc}): {err[-300:]}')
        need(open(os.path.join(d, 'frames.sha256')).read() == first_e,
             'rerecording the card changed the //e files')
        need(open(os.path.join(d, 'frames-ut.sha256')).read() == first_ut,
             'the card does not record the same twice')
        need(set(os.listdir(d)) == want,
             f'files after the rerun: {sorted(os.listdir(d))}')
        return f'{len(first_ut.split())} + {len(first_e.split())} frames'

    # ---- the phosphor (docs/DEMO-PHOSPHOR.md) ---------------------------
    # A pure palette remap of the canonical levels, applied at encode
    # time: these rows hold the PALETTE (injective, exact colour sets,
    # three distinct), the PLUMBING (one emulator pass, three encoders,
    # a cached tint that cannot go stale, the strip and the popover box
    # left alone, the hash of the canonical frame) and the NAMES (a
    # file's display is read after its phosphor is taken off). Each has
    # a planted defect that must turn it red.
    import demo_stamp

    def tables_problem(all_tables):
        """Why `all_tables` (phosphor -> three 256-byte translate
        tables) cannot show the three canonical levels as three colours:
        a level lost or two merged."""
        out = []
        for ph, tabs in sorted(all_tables.items()):
            shown = [tuple(tabs[ch][lv] for ch in range(3))
                     for lv in (0x00, 0x80, 0xFF)]
            if len(set(shown)) != 3:
                out.append(f'{ph}: dark/normal/highlight come out as '
                           f'{shown}: two of them are one colour')
            if shown[0] != (0, 0, 0):
                out.append(f'{ph}: dark is {shown[0]}, not black')
        return out

    @row('phosphor: every phosphor\'s tables keep the three levels three '
         'colours (injective), black stays black, the pairs differ')
    def _():
        need(demo_phos.NAMES == ('paper', 'green', 'amber') and
             demo_phos.DEFAULT == 'paper', f'NAMES {demo_phos.NAMES}')
        bad = tables_problem(demo_phos.ALL_TABLES)
        need(not bad, '; '.join(bad))
        need(len({demo_phos.PHOSPHORS[p] for p in demo_phos.NAMES}) == 3,
             'two phosphors share a pair')
        # the tables are the module's own, not a stale copy of the data
        for ph in demo_phos.NAMES:
            need(demo_phos.ALL_TABLES[ph] == demo_phos.tables(ph),
                 f'{ph}: ALL_TABLES is not tables()')
        # green is EXACTLY what the films shipped with
        need(demo_phos.PHOSPHORS['green'][0] == (0x40, 0xFF, 0x30),
             'green\'s normal level is not the colour the films shipped '
             'with')
        return 'paper, green, amber: 3 levels -> 3 colours each'

    @row('TEETH: a table that maps BRIGHT to the normal colour is caught '
         'by the injectivity row')
    def _():
        planted = {}
        for ph in demo_phos.NAMES:
            normal = demo_phos.PHOSPHORS[ph][0]
            tabs = []
            for ch in range(3):
                t = bytearray(demo_phos.ALL_TABLES[ph][ch])
                t[0xFF] = normal[ch]
                tabs.append(bytes(t))
            planted[ph] = tuple(tabs)
        bad = tables_problem(planted)
        need(len(bad) == 3, f'BRIGHT -> normal went unnoticed: {bad}')
        # and a table that loses a level (dark no longer black)
        lost = {ph: (bytes([9]) + t[0][1:], t[1], t[2])
                for ph, t in demo_phos.ALL_TABLES.items()}
        need(tables_problem(lost), 'a dark that is not black went unnoticed')
        return bad[0][:70]

    def level_pic(*levels):
        """A canonical FRAME_W x PIC_H picture holding every level given
        (each in its own band of rows), the rest dark."""
        out = bytearray(ov.FRAME_W * ov.PIC_H * 3)
        for i, lv in enumerate(levels):
            row0 = (i + 1) * 40
            for y in range(row0, row0 + 20):
                o = y * ov.FRAME_W * 3
                out[o:o + ov.FRAME_W * 3] = bytes([lv] * (ov.FRAME_W * 3))
        return bytes(out)

    @row('phosphor: a tinted picture\'s colour set is exactly black + that '
         'phosphor\'s pair, and the three phosphors\' sets differ')
    def _():
        sets = {}
        for ph in demo_phos.NAMES:
            normal, hl = demo_phos.PHOSPHORS[ph]
            one = demo_phos.tint(level_pic(0x80), demo_phos.ALL_TABLES[ph])
            three = demo_phos.tint(level_pic(0x80, 0xFF),
                                   demo_phos.ALL_TABLES[ph])
            need(colours(one) == {(0, 0, 0), normal},
                 f'{ph}: one level gives {sorted(colours(one))}')
            need(colours(three) == {(0, 0, 0), normal, hl},
                 f'{ph}: two levels give {sorted(colours(three))}')
            sets[ph] = frozenset(colours(three))
        need(len(set(sets.values())) == 3,
             'two phosphors show the same colours')
        # positional: a per-pixel loop agrees with the strided translate
        src = level_pic(0x80, 0xFF)[:3 * 2000]
        want = b''.join({G_OFF: bytes(3),
                         G_LIT: bytes(demo_phos.PHOSPHORS['amber'][0]),
                         G_BRIGHT: bytes(demo_phos.PHOSPHORS['amber'][1])}
                        [src[i:i + 3]] for i in range(0, len(src), 3))
        need(demo_phos.tint(src, demo_phos.ALL_TABLES['amber']) == want,
             'tint disagrees with a per-pixel remap')
        return 'black + pair, three distinct sets'

    @row('phosphor: the //e\'s film shows exactly two colours (never the '
         'highlight), the card\'s only black, normal and highlight')
    def _():
        need(rec and rec.ok and tintw.n == rec.frames and not tintw.bad,
             f'{len(tintw.bad)} //e frames whose encoder pictures are not '
             f'the tint of the picture: {tintw.bad[:3]}')
        need(uttint.n > 1000 and not uttint.bad,
             f'{len(uttint.bad)} card frames whose encoder pictures are '
             f'not the tint of the picture: {uttint.bad[:3]}')
        for ph in demo_phos.NAMES:
            normal, hl = demo_phos.PHOSPHORS[ph]
            need(tintw.red[ph] == {0, normal[0]},
                 f'{ph}: the //e shows red values {sorted(tintw.red[ph])}, '
                 f'wanted exactly black + {normal[0]:#x}')
            need({0, normal[0]} <= uttint.red[ph] <= {0, normal[0], hl[0]},
                 f'{ph}: the card shows red values '
                 f'{sorted(uttint.red[ph])}')
        # ... and the card CAN hold three (its attribute register)
        r = demo_phos.tint(level_pic(0x80, 0xFF), demo_phos.ALL_TABLES['green'])
        need(len(colours(r)) == 3, 'a card picture with highlight is not 3')
        return (f'//e {tintw.n} frames, card {uttint.n} frames: every '
                f'encoder picture is the independent tint')

    @row('phosphor: frames.sha256 is of the CANONICAL frame and there is '
         'one per display, whichever monitor shows it')
    def _():
        need(rec and rec.ok and len(tintw.hashes) == len(rec.hashes) and
             tintw.hashes == list(rec.hashes),
             'the recorded hashes are not sha256 of picture + strip')
        # the tinted frame is a different frame: hashing it would differ
        # (a hash taken per phosphor would have tripled a sidecar)
        frame, pics, strip = tintw.sample
        for ph in demo_phos.NAMES:
            need(hashlib.sha256(pics[ph] + strip).hexdigest() !=
                 hashlib.sha256(frame).hexdigest(),
                 f'{ph}: the tinted frame hashes as the canonical one')
        sidecars = sorted(f for f in os.listdir(rec.out_dir)
                          if f.endswith('.sha256'))
        need(sidecars == ['frames.sha256'], f'hash files {sidecars}')
        return f'{len(rec.hashes)} hashes, one file'

    class SynthClient:
        """screen_image writes the next queued PNG to the path asked."""

        def __init__(self, pngs):
            self.q, self.cur = list(pngs), None

        def call_tool(self, name, args):
            need(name == 'screen_image', f'unexpected tool {name}')
            if self.q:
                self.cur = self.q.pop(0)
            with open(args['path'], 'wb') as f:
                f.write(self.cur)
            return {'ok': True}

    class Capture:
        def __init__(self):
            self.calls = []

        def write(self, pics, strip):
            self.calls.append((pics, strip))

        def close(self):
            pass

        def abort(self):
            pass

    def e_png(*, block=(0, 0), grey=None):
        """A black/white 560x384 screen_image, one white block at
        `block` (cells of 20 px), optionally one pixel of `grey`."""
        w, h = ov.SCREEN_W, ov.SCREEN_H
        rgb = bytearray(w * h * 3)
        for y in range(block[1] * 20, block[1] * 20 + 20):
            o = (y * w + block[0] * 20) * 3
            rgb[o:o + 60] = b'\xff' * 60
        if grey is not None:
            rgb[0:3] = bytes([grey] * 3)
        return ref_encode(w, h, bytes(rgb), [0])

    synth = {}

    def synth_rec(pngs, frames):
        cap = Capture()
        r = dr.Recorder(SynthClient(pngs), tmp, cap, None, 'text80')
        r.demo = 'synthdemo'
        for _ in range(frames):
            r._capture()
        return r, cap

    def cache_problem():
        """[] when the tint cache serves each picture its OWN tint and
        reuses the object while the screen holds still."""
        if 'pngs' not in synth:
            synth['pngs'] = (e_png(block=(1, 1)), e_png(block=(5, 3)))
        a, b = synth['pngs']
        r, cap = synth_rec([a, a, b, b, a], 5)
        out = []
        for i, blk in enumerate((1, 1, 5, 5, 1)):
            want = ind_tint(ov.pad_picture(canon_e(
                ref_decode(a if blk == 1 else b)[2])), 'amber')
            if cap.calls[i][0]['amber'] != want:
                out.append(f'frame {i}: the amber picture is not the tint '
                           f'of that frame\'s screen (a stale cache)')
        for ph in demo_phos.NAMES:
            if cap.calls[1][0][ph] is not cap.calls[0][0][ph]:
                out.append(f'{ph}: a still screen was tinted again (the '
                           f'cache is what makes three monitors cost '
                           f'8% of frames, not 100%)')
            if cap.calls[2][0][ph] is cap.calls[1][0][ph]:
                out.append(f'{ph}: a CHANGED screen reused the old tint')
        return out

    @row('phosphor: a still screen reuses its tint, a changed screen gets '
         'its own, and no stale tint is ever served')
    def _():
        bad = cache_problem()
        need(not bad, '; '.join(bad))
        return '5 frames: tint(A) reused, tint(B) fresh, tint(A) again'

    @row('TEETH: a tint cache that never refreshes, and one that never '
         'hits, are both caught')
    def _():
        real = dr.Recorder._tinted
        saved = {}

        def stale(self):
            if 'v' not in saved:
                saved['v'] = real(self)
            return saved['v']

        def never(self):
            self._tint_src = None
            return real(self)
        try:
            dr.Recorder._tinted = stale
            a = cache_problem()
            dr.Recorder._tinted = never
            b = cache_problem()
        finally:
            dr.Recorder._tinted = real
        need(a and any('stale' in x for x in a),
             f'a cache that never refreshes went unnoticed: {a}')
        need(b and any('again' in x for x in b),
             f'a cache that never hits went unnoticed: {b}')
        return a[0][:60]

    @row('phosphor: the popover box is drawn OVER the tint in its own '
         'colours; the strip handed to the encoders is the canonical one')
    def _():
        a, _ = synth.get('pngs') or (e_png(block=(1, 1)), None)
        r = dr.Recorder(SynthClient([a]), tmp, Capture(), None, 'text80')
        r.demo = 'synthdemo'
        r.pop = ov.render_box('IYKYK ;-)')
        r._capture()
        pics, strip = r.encoder.calls[0]
        need(strip == blank, 'the strip handed to the encoders is not the '
                             'canonical one')
        box = r.pop
        for ph in demo_phos.NAMES:
            need(pics[ph] == ov.blit_box(ind_tint(r._pic, ph), box),
                 f'{ph}: not tint-then-box')
            x, y, w, h, px = box
            o = (y * ov.FRAME_W + x) * 3
            need(pics[ph][o:o + w * 3] == px[:w * 3],
                 f'{ph}: the box top row is not the box\'s own colours')
        return 'box and strip keep their own colours on every monitor'

    def encoder_set_problem(write=None):
        """Run a REAL EncoderSet over stub encoders and say why what each
        was handed is not pics[ph] + strip."""
        got = {}

        class Stub:
            def __init__(self, work, name, w, h, ffmpeg='ffmpeg'):
                self.name, self.frames = name, got.setdefault(name, [])
                self.finished = False

            def write(self, frame):
                self.frames.append(frame)

            def close(self):
                self.finished = True

            def abort(self):
                self.finished = True
        real = dr.Encoder
        dr.Encoder = Stub
        try:
            es = dr.EncoderSet(tmp, 'n', 4, 4)
            if write:
                es.write = lambda pics, strip: write(es, pics, strip)
            pics = {ph: bytes([i + 1]) * 12
                    for i, ph in enumerate(demo_phos.NAMES)}
            strip = bytes([0xAB]) * 6
            es.write(pics, strip)
            es.close()
        finally:
            dr.Encoder = real
        out = []
        if sorted(got) != sorted('n-' + p for p in demo_phos.NAMES):
            out.append(f'encoders named {sorted(got)}')
        for ph in demo_phos.NAMES:
            if got.get('n-' + ph) != [pics[ph] + strip]:
                out.append(f'{ph}: handed {got.get("n-" + ph)!r}, wanted '
                           f'its picture + the untinted strip')
        return out

    @row('phosphor: EncoderSet is one encoder per phosphor, named '
         'NAME-phosphor, each handed its picture + the shared strip')
    def _():
        bad = encoder_set_problem()
        need(not bad, '; '.join(bad))
        planted = encoder_set_problem(
            lambda es, pics, strip: [e.write(pics['paper'] + strip)
                                     for e in es.encoders.values()])
        need(planted, 'one picture fed to all three went unnoticed')
        return 'three stubs, three distinct frames'

    def third_grey_problem(canon):
        """[] when a //e picture holding a third grey is REFUSED by
        `canon` and by the recorder, naming the demo."""
        out = []
        bad = ref_decode(e_png(grey=0x55))[2]
        try:
            canon(bad)
            out.append('canon_one_level took a picture with a 0x55 grey')
        except demo_phos.PhosError:
            pass
        saved = demo_phos.canon_one_level
        demo_phos.canon_one_level = canon
        try:
            r = dr.Recorder(SynthClient([e_png(grey=0x55)]), tmp,
                            Capture(), None, 'text80')
            r.demo = 'synthdemo'
            try:
                r._capture()
                out.append('the recorder filmed a picture with a third '
                           'grey')
            except dr.RecorderError as e:
                if 'synthdemo' not in str(e):
                    out.append(f'refused, but not naming the demo: {e}')
        finally:
            demo_phos.canon_one_level = saved
        return out

    @row('phosphor: a //e picture with a third grey is a RecorderError '
         'naming the demo, never a black frame')
    def _():
        bad = third_grey_problem(demo_phos.canon_one_level)
        need(not bad, '; '.join(bad))
        pure = demo_phos.canon_one_level(ref_decode(e_png())[2])
        need(set(pure) == {0x00, 0x80}, 'the //e white is not the NORMAL '
                                         'level')
        return 'refused by name'

    @row('TEETH: a lenient canon_one_level (a third grey tinted to black) '
         'is caught')
    def _():
        def lenient(rgb, what='the picture'):
            return rgb.translate(bytes(0x80 if b == 0xFF else 0
                                       for b in range(256)))
        bad = third_grey_problem(lenient)
        need(len(bad) >= 2, f'a lenient canon went unnoticed: {bad}')
        return bad[0][:70]

    def belongs_problem(belongs):
        out = []
        for fn, name, sfx, want in (
                ('poster-ut-amber.png', 'x', '-ut', True),
                ('poster-ut-amber.png', 'x', '', False),
                ('poster-amber.png', 'x', '', True),
                ('poster-amber.png', 'x', '-ut', False),
                ('x-ut-green.mp4', 'x', '-ut', True),
                ('x-ut-green.webm', 'x', '', False),
                ('x-paper.mp4', 'x', '', True),
                ('x-paper.mp4', 'x', '-ut', False),
                ('x-ut.stamp.json', 'x', '-ut', True),
                ('x.stamp.json', 'x', '-ut', False),
                ('frames-ut.sha256', 'x', '', False),
                ('transcript.txt', 'x', '', True)):
            if bool(belongs(fn, name, sfx)) != want:
                out.append(f'{fn} for display {sfx!r}: {not want}')
        return out

    @row('phosphor: a file\'s display is read AFTER its phosphor is taken '
         'off (poster-ut-amber is the card\'s); a demo named like a '
         'display or a phosphor is refused')
    def _():
        bad = belongs_problem(dr._belongs)
        need(not bad, '; '.join(bad))
        d = os.path.join(tmp, 'names')
        os.mkdir(d)
        refused = []
        for nm in ('okname', 'foo-ut', 'foo-amber', 'foo-paper', 'foo-green'):
            path = os.path.join(d, nm + '.py')
            with open(path, 'w') as f:
                f.write("DEMO = dict(name=%r, title='t', backend='text80', "
                        "image='play', gate='check-demo-%s')\n"
                        "def run(t):\n    pass\n" % (nm, nm))
            try:
                dr.load_demo(path)
                refused.append((nm, False))
            except dr.RecorderError as e:
                refused.append((nm, str(e)))
        need(refused[0][1] is False, f'a good name was refused: {refused[0]}')
        for nm, why in refused[1:]:
            need(why and why is not False and nm in why,
                 f'{nm}: not refused by name ({why})')
        return 'ut and all three phosphors refused as demo names'

    @row('TEETH: a _belongs that does not take the phosphor off first is '
         'caught (poster-ut-amber read as the //e\'s)')
    def _():
        def old(fn, name, suffix):
            stem = fn.split('.', 1)[0]
            if suffix:
                return stem.endswith(suffix)
            return not stem.endswith('-ut')
        bad = belongs_problem(old)
        need(bad, 'the pre-phosphor _belongs passed: the row has no teeth')
        return bad[0]

    def film_fixture(wrong=None):
        """A film directory for demo 'x' (//e only), every file at the
        declared size except `wrong` {file: (w, h)}; returns film_errors."""
        import struct

        def box(t, body):
            return struct.pack('>I4s', 8 + len(body), t) + body

        def mp4(w, h):
            def tkhd(w, h):
                return box(b'tkhd', bytes(40) + struct.pack(
                    '>9i', *demo_stamp.IDENTITY) +
                    struct.pack('>II', w << 16, h << 16))
            avc1 = box(b'avc1', bytes(24) + struct.pack('>HH', w, h) +
                       bytes(50))
            stsd = box(b'stsd', struct.pack('>II', 0, 1) + avc1)
            mdia = box(b'mdia', box(b'minf', box(b'stbl', stsd)))
            return (box(b'ftyp', b'isom\0\0\2\0') +
                    box(b'moov', box(b'trak', tkhd(w, h) + mdia)))

        def webm(w, h):
            def el(i, body):
                return i + (0x10000000 | len(body)).to_bytes(4, 'big') + body
            video = el(b'\xe0', el(b'\xb0', w.to_bytes(2, 'big')) +
                       el(b'\xba', h.to_bytes(2, 'big')))
            return (el(b'\x1a\x45\xdf\xa3', b'') + el(
                b'\x18\x53\x80\x67', el(b'\x16\x54\xae\x6b',
                                        el(b'\xae', video))))

        def png(w, h):
            return (b'\x89PNG\r\n\x1a\n' + struct.pack(
                '>I4sII5s', 13, b'IHDR', w, h, b'\x08\x02\0\0\0'))
        root = os.path.join(tmp, 'film%d' % len(wrong or {}))
        shutil.rmtree(root, ignore_errors=True)
        os.makedirs(os.path.join(root, 'x'))
        for (kind, ph), fn in demo_stamp.out_names('x').items():
            size = (wrong or {}).get(fn)
            if kind == 'mp4':
                body = mp4(*(size or demo_stamp.FILM_SIZE))
            elif kind == 'webm':
                body = webm(*(size or demo_stamp.FILM_SIZE))
            elif kind == 'poster':
                body = png(*(size or demo_stamp.POSTER_SIZE))
            else:
                body = b'WEBVTT\n'
            with open(os.path.join(root, 'x', fn), 'wb') as f:
                f.write(body)
        demos = {'x': {'backends': ('text80',), 'image': 'play',
                       'floppy': None, 'path': MYGREP}}
        return demo_stamp.film_errors(root, demos, False, ffmpeg_now=None)

    @row('stamp: out_names is keyed (kind, phosphor), every film names its '
         'monitor, and EVERY variant gets its own size check')
    def _():
        names = demo_stamp.out_names('x', '-ut')
        need(set(names) == {(k, p) for k in demo_stamp.PHOSPHOR_KINDS
                            for p in demo_phos.NAMES} | {('vtt', None)} and
             names['poster', 'amber'] == 'poster-ut-amber.png' and
             names['mp4', 'green'] == 'x-ut-green.mp4' and
             names['vtt', None] == 'x-ut.vtt', f'keys {sorted(names)}')
        need('demo_phos.py' in demo_stamp.RECORDER_FILES,
             'editing the palette would not make the films stale')
        base = [e for e in film_fixture() if 'frame size' in e or
                'size ' in e or 'coded' in e]
        need(not base, f'declared-size films were refused: {base}')
        wrong = {}
        for fn, size in (('x-amber.mp4', (720, 468)),
                         ('x-green.webm', (1440, 900)),
                         ('poster-amber.png', (1440, 400))):
            errs = [e for e in film_fixture({fn: size}) if fn in e]
            need(errs, f'a mis-sized {fn} was not caught on its own')
            wrong[fn] = errs[0][:60]
        return '; '.join(sorted(wrong))

    def hand_stamp(backend):
        """A stamp and its matching `now`, built by hand from the
        recorder's own file list (no emulator): what stale_reasons reads."""
        import demo_stamp
        files = {'scripts/' + fn: 'a' * 64 for fn in demo_stamp.RECORDER_FILES}
        for n, role in enumerate(r for r in demo_stamp.machine_roles(backend)
                                 if r.startswith('ext:rom/')):
            files[role] = '%x' % (n + 1) * 64      # every ROM the config loads
        st = {'version': demo_stamp.STAMP_VERSION, 'backend': backend,
              'inputs': {'script': 's' * 64, 'image': 'i' * 64,
                         'floppy': None, 'files': files,
                         'ut_revision': (demo_stamp.UT_REVISION
                                         if backend == 'ut' else None)}}
        now = {'script': 's' * 64, 'image': 'i' * 64, 'floppy': None,
               'files': dict(files),
               'ut_revision': st['inputs']['ut_revision']}
        return st, now

    @row('stamp: the -ut stamp names the original card (v1) from the '
         'recorder\'s own pinned table; changing the v1 firmware or '
         'chargen stales the -ut film and not the //e film')
    def _():
        import demo_stamp
        rv = demo_ut.revision()
        need(rv.name == 'v1' and demo_stamp.UT_REVISION == 'v1' and
             demo_stamp.UT_FIRMWARE == 'ultraterm/firmware_v1.bin' and
             demo_stamp.UT_CHARGEN == 'ultraterm/chargen_v1.bin',
             f'the stamp films {demo_stamp.UT_REVISION}, '
             f'{demo_stamp.UT_FIRMWARE}, {demo_stamp.UT_CHARGEN}')
        need(demo_stamp.UT_FIRMWARE == 'ultraterm/' + rv.firmware and
             demo_stamp.UT_CHARGEN == 'ultraterm/' + rv.chargen,
             'the stamp\'s names are not the pinned table\'s')
        ut, ut_now = hand_stamp('ut')
        e, e_now = hand_stamp('text80')
        need(not demo_stamp.stale_reasons(ut, ut_now) and
             not demo_stamp.stale_reasons(e, e_now), 'hand stamps are stale')
        for role in (demo_stamp.UT_FIRMWARE, demo_stamp.UT_CHARGEN):
            k = 'ext:rom/' + role
            need(k in ut['inputs']['files'] and
                 k not in e['inputs']['files'], f'{k} is not ut-only')
            for st, now, stale in ((ut, ut_now, True), (e, e_now, False)):
                bad = dict(now, files=dict(now['files'], **{k: 'e' * 64}))
                why = demo_stamp.stale_reasons(st, bad)
                need(bool(why) == stale and (not stale or
                     any(k in w for w in why)),
                     f'{role} changed: {st["backend"]} stamp says {why}')
        return 'firmware_v1 and chargen_v1 stale the -ut stamp only'

    # The clock a2til stamps files with is datetime.now() (local time, minute
    # resolution). Two builds seconds apart, or in one zone, would hide a
    # clock source that only shows on another day or in another zone, so the
    # child process FAKES the clock (a2til's own datetime, prodos and nufx) at
    # a declared date, under a declared time zone.
    FAKE_CLOCKS = (('2031-03-04T05:06', 'UTC'),
                   ('1999-12-31T23:59', 'Pacific/Honolulu'))

    def build_images(out, fake, tz, names=(), normalise=True):
        """build_demo_images.py into `out`, the clock faked at `fake`
        under time zone `tz`; normalise=False plants the defect (the date
        normalisation is a no-op)."""
        a2til = os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til'))
        code = (
            'import sys, datetime as _dt\n'
            'sys.path.insert(0, %r)\n'
            'from a2til import prodos, nufx\n'
            'when = _dt.datetime.fromisoformat(%r)\n'
            'class D(_dt.datetime):\n'
            '    @classmethod\n'
            '    def now(cls, tz=None): return when\n'
            'prodos.datetime = D; nufx.datetime = D\n'
            'import build_demo_images as b\n'
            '%s'
            'sys.argv = ["b", "--out", %r] + %r\n'
            'sys.exit(b.main())\n'
            % (a2til, fake,
               '' if normalise else
               'b.normalize_image_dates = lambda image: None\n',
               out, list(names)))
        r = subprocess.run([sys.executable, '-c', code],
                           env=dict(os.environ, TZ=tz), cwd=HERE,
                           capture_output=True, text=True)
        need(r.returncode == 0, f'image build failed: {r.stderr[-300:]}')

    DEMO_IMAGE_FILES = ('demo-unpack.po', 'demo-loop.po', 'demo-fed.po',
                        'demo-ddshrink.po', 'demo-ddshrink-floppy.po')

    @row('demo images are byte-deterministic: two builds under two faked '
         'clocks and two time zones, every image (and the GAME volume '
         'inside demo-loop) identical')
    def _():
        outs = []
        for n, (fake, tz) in enumerate(FAKE_CLOCKS):
            out = os.path.join(tmp, f'di-{n}')
            build_images(out, fake, tz)
            outs.append(out)
        for fn in DEMO_IMAGE_FILES:
            x, y = (open(os.path.join(d, fn), 'rb').read() for d in outs)
            need(x == y, f'{fn} differs between the two builds: '
                         f'{sum(p != q for p, q in zip(x, y))} bytes')
        # and the clock-free witness: no entry carries any other date
        import prodos_dates
        for fn in DEMO_IMAGE_FILES[:4]:
            bad = prodos_dates.date_errors(os.path.join(outs[0], fn))
            need(not bad, f'{fn}: entries not at IMAGE_TIMESTAMP: {bad}')
        return ('%d images identical across 2 faked clocks x 2 zones'
                % len(DEMO_IMAGE_FILES))

    @row('release images carry only the one declared timestamp: play.po, '
         'full.po (when built here) and the demo images')
    def _():
        # COST: a read-only walk of each image, about a tenth of a second
        # in all. It checks the built artifact, not a rebuild: a full.po
        # rebuild boots an emulator (nas builds its LIBA objects) and
        # writes build/full.po, so it is left to check-release-image; a
        # clock-stamped entry is the only thing that makes two builds
        # differ, and this finds it in the image the hello film boots.
        import prodos_dates
        seen = []
        for name in ('play.po', 'full.po'):
            img = os.path.join(ROOT, 'build', name)
            if not os.path.exists(img):
                need(name != 'play.po', 'build/play.po is missing')
                continue
            bad = prodos_dates.date_errors(img)
            need(not bad, f'{name}: entries not at IMAGE_TIMESTAMP: {bad}')
            seen.append(name)
        return '%s: every entry at %s' % (', '.join(seen),
                                          prodos_dates.IMAGE_TIMESTAMP)

    @row('TEETH: demo images built without the date normalisation differ '
         'under the two faked clocks, and a clock-stamped entry is found '
         'by the date scan, so both determinism rows have teeth')
    def _():
        import prodos_dates
        outs = []
        for n, (fake, tz) in enumerate(FAKE_CLOCKS):
            out = os.path.join(tmp, f'di-off{n}')
            build_images(out, fake, tz, ('fed', 'loop'), normalise=False)
            outs.append(out)
        diff = [fn for fn in ('demo-fed.po', 'demo-loop.po')
                if open(os.path.join(outs[0], fn), 'rb').read() !=
                open(os.path.join(outs[1], fn), 'rb').read()]
        need(diff, 'unnormalised images are identical across the faked '
                   'clocks: the determinism row proves nothing')
        bad = prodos_dates.date_errors(os.path.join(outs[0], 'demo-fed.po'))
        need(bad, 'the date scan found nothing in an unnormalised image')
        return ('without normalisation %s differ; scan finds %s'
                % (', '.join(diff), bad[0][:40]))

    @row('TEETH: a stamp with its machine-ROM entries removed goes red '
         '(the //e ROM for every film, the card firmware and chargen for -ut)')
    def _():
        import demo_stamp
        seen = []
        for bk in ('text80', 'ut'):
            st, now = hand_stamp(bk)
            need(not demo_stamp.stale_reasons(st, now), f'{bk}: stale at once')
            roms = [k for k in st['inputs']['files']
                    if k.startswith('ext:rom/')]
            need('ext:rom/iie_cd_ef.rom' in roms and
                 ('ext:rom/' + demo_stamp.UT_FIRMWARE in roms) == (bk == 'ut'),
                 f'{bk}: the hand stamp lists {roms}')
            for k in roms:
                gone = {a: b for a, b in st['inputs']['files'].items()
                        if a != k}
                cut = dict(st, inputs=dict(st['inputs'], files=gone))
                why = demo_stamp.stale_reasons(cut, now)
                need(any('machine ROM' in w and k[8:] in w for w in why),
                     f'{bk}: a stamp without {k} was accepted: {why}')
                seen.append((bk, k))
        return f'{len(seen)} dropped ROM entries refused'

    @row('TEETH: a -ut stamp whose ut_revision differs from the '
         'recorder\'s goes red')
    def _():
        import demo_stamp
        ut, now = hand_stamp('ut')
        other = 'v3' if demo_stamp.UT_REVISION == 'v1' else 'v1'
        ut['inputs']['ut_revision'] = other
        why = demo_stamp.stale_reasons(ut, now)
        need(any('UltraTerm revision' in w for w in why),
             f'a {other} film passed for a {demo_stamp.UT_REVISION} '
             f'recorder: {why}')
        # and the recorder's revision follows MAUX_UT_REV
        old = os.environ.get('MAUX_UT_REV')
        os.environ['MAUX_UT_REV'] = other
        try:
            need(demo_ut.revision().name == other, 'MAUX_UT_REV ignored')
        finally:
            if old is None:
                del os.environ['MAUX_UT_REV']
            else:
                os.environ['MAUX_UT_REV'] = old
        return f'a {other} stamp against a {demo_stamp.UT_REVISION} recorder: red'

    @row('ut: the popover sits at the lower right of the card\'s picture '
         'and nowhere else')
    def _():
        boxes = []

        def collect_pop(index, frame, info):
            boxes.append((info['popover'], frame[:PIC_BYTES], info['pic']))
        r = dr.run_demo(POPOVER, record=os.path.join(tmp, 'u4'),
                        encode=False, seed=SEED, backend='ut',
                        on_frame=collect_pop)
        need(r.ok, str(r.error))
        # maux's R9=$0F makes the card's picture 720x384 (not doubled),
        # centred: the box sits at ITS lower right, not in the band
        bottom = (ov.PIC_H + 384) // 2
        box = ov.render_box('IYKYK ;-)', ov.FRAME_W, bottom)
        bx, by, bw, bh, _ = box
        need(bx + bw == ov.FRAME_W - ov.BOX_MARGIN and
             by + bh == bottom - ov.BOX_MARGIN,
             f'the box is at {bx},{by}')
        inside = 0
        for b, frame, pic in boxes:
            if b is None:
                need(frame == pic, 'a box-free frame differs from the '
                                   'card\'s picture')
            else:
                inside += 1
                need(frame == ov.blit_box(pic, box),
                     'the popover frame is not the card picture + the box')
        need(inside == 60, f'{inside} popover frames, wanted 60')
        return '60 frames carry the box, all others the bare card picture'

    @row('the displays must agree: planted different KEYS go red, named')
    def _():
        rc, err, so = cli2([os.path.join(ROOT, 'fixtures', 'demos',
                                         'disagree_keys.py')])
        need(rc == 1, f'exit {rc}: {err[-300:]}')
        need('displays disagree' in err and 'the keys differ' in err,
             f'not named: {err[-300:]}')
        need('PASS disagree_keys [text80]' in so and
             'PASS disagree_keys [ut]' in so,
             f'each display alone should pass: {so!r}')
        return 'each passes alone; together: the keys differ'

    @row('the displays must agree: planted different TEXT goes red, named')
    def _():
        rc, err, so = cli2([os.path.join(ROOT, 'fixtures', 'demos',
                                         'disagree_text.py')])
        need(rc == 1, f'exit {rc}: {err[-300:]}')
        need('displays disagree' in err and
             "the screen at 'vidmode says which console this is'" in err and
             '80X24 HQ VT' in err, f'not named: {err[-300:]}')
        need('PASS disagree_text [text80]' in so and
             'PASS disagree_text [ut]' in so, f'alone: {so!r}')
        return 'each passes alone; the machine says 80X24 VT vs 80X24 HQ VT'

    @row('the displays agree on mygrep: same keys, same text')
    def _():
        a = dr.run_demo(MYGREP, seed=SEED, backend='text80')
        b = dr.run_demo(MYGREP, seed=SEED, backend='ut')
        need(a.ok and b.ok, f'{a.error} {b.error}')
        need(dr.compare_displays([a, b]) == [],
             str(dr.compare_displays([a, b])))
        need(len(a.keys) > 100 and len(a.transcript) >= 8, 'vacuous')
        return f'{len(a.keys)} keys, {len(a.transcript)} checkpoints'
finally:
    shutil.rmtree(tmp, ignore_errors=True)

failed = [n for n, ok, _ in results if not ok]
print()
if failed:
    print(f'check-recorder: {len(failed)} of {len(results)} rows FAILED')
    sys.exit(1)
print(f'check-recorder: all {len(results)} rows pass')
