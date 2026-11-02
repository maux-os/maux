#!/usr/bin/env python3
"""demo_record.py -- demos as code: one script, a gate AND a screencast.

    python3 scripts/demo_record.py site/demos/fedgrep.py            # gate
    python3 scripts/demo_record.py site/demos/fedgrep.py --record build/demos

A demo (site/demos/NAME.py, docs/SITE.md sec 3.2, site/demos/README)
is a DEMO dict plus run(t), a short script over the person-like
terminal driver scripts/e2e_term.py (class Term). The same file runs
in two modes:

  GATE MODE (the default). `t` is a Term subclass whose say, hold and
  fast are no-ops and whose expect_* methods are the assertions. No
  screen_image call is made and no ffmpeg is needed, so it runs in the
  sweep, on the box.

  RECORD MODE (--record OUTDIR). `t` is a Term subclass whose _slice
  steps the machine in WHOLE VIDEO FRAMES of 34,016 cycles (1/30 s of
  emulated time) and captures one frame after each. Every Term method
  (press, wait, wait_prompt ...) therefore works unchanged. Key gaps
  are a seeded whole number of frames (3-5, 100-167 ms), so a
  recording is a deterministic function of (demo, seed, image,
  verilogapple build). A failed expect_* aborts the recording and
  leaves NO video and no partial file anywhere under OUTDIR.

Output per demo, OUTDIR/NAME/ (never committed), per display (the
//e bare, the UltraTerm with -ut) and per PHOSPHOR (paper, green,
amber; scripts/demo_phos.py, docs/DEMO-PHOSPHOR.md): NAME[-ut]-PH.mp4,
NAME[-ut]-PH.webm, poster[-ut]-PH.png; and once per display
NAME[-ut].vtt, transcript[-ut].txt. --no-encode skips ffmpeg and the
videos, and writes frames.sha256 (one hash per output frame) beside the
rest: that is what scripts/check_recorder.py runs on the sweep box,
which has no ffmpeg. ONE emulator pass feeds one encoder per phosphor:
the frame hash is of the CANONICAL (untinted) frame, so one
frames.sha256 covers the three films and says the phosphor cannot
change the frames. --phosphor NAME (repeatable) films only that one.

Frames: screen_image writes a 560x384 PNG to a path this run owns; it
is decoded in the stdlib (scripts/demo_png.py), the key strip and the
fast badge are drawn into the raw pixels (scripts/demo_overlay.py),
the PNG is deleted, and the composed rawvideo frame goes to ffmpeg's
stdin. A minute of frames is never on disk (1.16 GB, docs/SITE.md
sec 3.4).

Record on the fast backend only. An rtl step is a 14 MHz tick, not a
CPU cycle (learning:01KZZ53ZE9QX3W2R3NKC209766).
"""
import argparse
import contextlib
import hashlib
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import demo_overlay                                          # noqa: E402
import demo_phos                                             # noqa: E402
import demo_png                                              # noqa: E402
import demo_stamp                                            # noqa: E402
import demo_ut                                               # noqa: E402
import e2e_term                                              # noqa: E402
import ffmpeg_probe                                          # noqa: E402
from e2e_term import Term, Wedged, boot                      # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR       # noqa: E402

FPS = 30
FRAME_CYCLES = 34_016           # 1,020,484 cycles/s / 30, the spike's step
KEY_FRAMES = (3, 5)             # a key gap, in frames: 100-167 ms
UPSCALE = demo_stamp.UPSCALE   # the output size is declared in demo_stamp
BACKENDS = ('text40', 'text80', 'ut')
# A demo's files for the //e display carry the bare name (NAME-paper.mp4,
# poster-paper.png ...); the UltraTerm's carry this suffix (NAME-ut-paper
# .mp4, poster-ut-paper.png ...), side by side in OUTDIR/NAME/. The
# phosphor is the LAST component of a film's name (demo_stamp.out_names).
SUFFIX = {'text40': '', 'text80': '', 'ut': '-ut'}
DEFAULT_SEED = demo_stamp.DEFAULT_SEED
SETTLE_SECONDS = 10         # default budget for a command to finish
CYCLES_PER_SEC = 1_020_484

# A caption is a BEAT (docs/RECORDER.md "Captions"): the cue opens, the
# screen holds with no key for the reading time, the cue closes, and a
# quiet pause follows before the next action. No key is ever sent while a
# cue is open.
CUE_QUIET = 0.45                # seconds of quiet after the cue closes
CUE_MAX = 9.5                   # a backstop: split a caption past ~150 chars
CUE_SETTINGS = 'line:40% position:50% align:center size:80%'


def reading_seconds(text):
    """How long a caption stays up: 1.2 s + 55 ms a character, between
    2.4 s and 6.5 s."""
    return min(CUE_MAX, max(2.4, 1.2 + 0.055 * len(text)))


def cue_frames(text):
    return round(reading_seconds(text) * FPS)


def quiet_frames():
    return round(CUE_QUIET * FPS)

# DEMO['image'] names the disk a demo is filmed on: play.po, or one of
# the small additions scripts/build_demo_images.py makes of it (a real
# archive to unpack, a disk image to mount). `--image` still overrides.
_BUILD = demo_stamp.BUILD
IMAGES = demo_stamp.IMAGES
# DEMO['floppy'] (optional) names the 5.25" floppy in slot 6 drive 1,
# read the way DEMO['image'] is; `--floppy` overrides (teeth).
FLOPPIES = demo_stamp.FLOPPIES

# verilogapple seeds the Timemaster clock from the HOST wall clock at
# every cold reset (mcp_server.cpp load_clock_host_time), so a recording
# made a minute later starts from a different BCD time, and a demo that
# creates a file stamps it. The server has no fixed-epoch option, so the
# pin is `clock: false`: no card, a machine whose time is the same on
# every run. Both modes boot this way, so the gate and the film see the
# same machine. (--host-clock unpins it, for the measurements in
# docs/RECORDER-NOTES.md sec 11 R2.)
PINNED_CLOCK = {'clock': False}

# What `make demos` needs from ffmpeg (version floor, encoders, filters)
# is dependencies.lock.json tools.ffmpeg, read by scripts/ffmpeg_probe.py:
# one statement, checked here at the start of --record (never by
# --no-encode, whose sweep rows run where there is no ffmpeg) and by
# check-deps as the test tier's optional tool.


class RecorderError(Exception):
    """The recorder itself failed (not the demo): a bad frame, a dead
    encoder, a malformed DEMO."""


# -- ffmpeg ----------------------------------------------------------------

def ffmpeg_problems(ffmpeg='ffmpeg'):
    """Strings naming what is missing, [] when ffmpeg can run `make
    demos`: the lock's floor, encoders and filters."""
    return ffmpeg_probe.problems(ffmpeg_probe.lock_spec(), ffmpeg)


class Encoder:
    """ffmpeg reading rawvideo rgb24 on stdin, writing the mp4 and the
    webm from one pass. Flags are the sec 3.4 spike's."""

    def __init__(self, work, name, width, height, ffmpeg='ffmpeg'):
        self.mp4 = os.path.join(work, name + '.mp4')
        self.webm = os.path.join(work, name + '.webm')
        # one log PER encoder: the set runs three in one directory
        self.log = open(os.path.join(work, f'ffmpeg.{name}.log'), 'wb')
        graph = (f'[0:v]scale=iw*{UPSCALE}:ih*{UPSCALE}:flags=neighbor,'
                 'format=yuv420p,split=2[a][b]')
        cmd = [ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
               '-f', 'rawvideo', '-pix_fmt', 'rgb24',
               '-s', f'{width}x{height}', '-framerate', str(FPS), '-i', '-',
               '-filter_complex', graph,
               '-map', '[a]', '-c:v', 'libx264', '-crf', '18',
               '-tune', 'animation', '-pix_fmt', 'yuv420p',
               '-movflags', '+faststart', self.mp4,
               '-map', '[b]', '-c:v', 'libvpx-vp9', '-crf', '32',
               '-b:v', '0', '-row-mt', '1', '-pix_fmt', 'yuv420p', self.webm]
        self.finished = False
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE,
                                     stdout=self.log, stderr=self.log)

    def write(self, frame):
        try:
            self.proc.stdin.write(frame)
        except BrokenPipeError:
            raise RecorderError('ffmpeg died mid-recording: ' +
                                self._tail())

    def close(self):
        """Normal end: close stdin so ffmpeg flushes, and require rc 0."""
        self.finished = True
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        rc = self.proc.wait()
        self.log.close()
        if rc != 0:
            raise RecorderError(f'ffmpeg exited {rc}: ' + self._tail())

    def abort(self):
        """Abnormal end. The order is the point: KILL the encoder first
        (it may be mid-write into the directory the caller is about to
        delete), then close its stdin, then reap it. Idempotent."""
        if self.finished:
            return
        self.finished = True
        self.proc.kill()
        try:
            self.proc.stdin.close()
        except OSError:                  # BrokenPipe flushing to a corpse
            pass
        self.proc.wait()
        self.log.close()

    def _tail(self):
        try:
            with open(self.log.name, errors='replace') as f:
                return f.read()[-400:]
        except OSError:
            return '(no log)'


class EncoderSet:
    """One Encoder per phosphor, NAME[-ut]-PH, built in one `work`
    directory and fed from ONE emulator pass. Same contract as Encoder:
    write / close / abort, and abort() KILLS every encoder before the
    caller removes the directory they write into (run_demo's `finally`).

    write() takes the per-phosphor PICTURES (already tinted, popover
    drawn over the tint so the box keeps its own colours) and the strip,
    which is shared and untinted: the picture is the monitor, the strip
    is the film's own furniture."""

    def __init__(self, work, name, width, height, phosphors=None,
                 ffmpeg='ffmpeg'):
        self.phosphors = tuple(demo_phos.NAMES if phosphors is None
                               else phosphors)
        self.encoders = {}
        try:
            for ph in self.phosphors:
                self.encoders[ph] = Encoder(work, f'{name}-{ph}', width,
                                            height, ffmpeg)
        except BaseException:
            self.abort()
            raise

    def write(self, pics, strip):
        for ph, enc in self.encoders.items():
            enc.write(pics[ph] + strip)

    def close(self):
        """Normal end: every encoder is closed and reaped even if one
        failed; the first failure is the one raised."""
        err = None
        for enc in self.encoders.values():
            try:
                enc.close()
            except RecorderError as e:
                err = err or e
        if err:
            raise err

    def abort(self):
        for enc in self.encoders.values():
            enc.abort()


# -- the recorder ----------------------------------------------------------

def vtt_escape(text):
    """Cue text for a WebVTT file: & and < are markup there, and --> would
    end the cue. site/build.py vtt_cues undoes it."""
    return (text.replace('&', '&amp;').replace('<', '&lt;')
            .replace('-->', '--&gt;'))


def vtt_time(sec):
    ms = int(round(sec * 1000))
    return f'{ms // 3600000:02}:{ms // 60000 % 60:02}:' \
           f'{ms // 1000 % 60:02}.{ms % 1000:03}'


class Recorder:
    """Owns the frame clock. Every step the demo's Term takes goes
    through step_frame(); with `enabled` set, a frame is composed and
    emitted for it (subject to fast())."""

    def __init__(self, client, work, encoder=None, on_frame=None,
                 display='text80', phosphors=None):
        self.c = client
        self.work = work
        self.display = display
        self.phosphors = tuple(demo_phos.NAMES if phosphors is None
                               else phosphors)
        self._tint_src = None       # the canonical picture last tinted ...
        self._tint_out = {}         # ... and its tint, by phosphor
        self.png = os.path.join(work, 'frame.png')
        self._ut_rom = None         # the card's character ROM, when 'ut'
        self._ut_key = None         # what the last card picture drew
        self._ut_area = None        # (right, bottom) of that picture
        self._ut_pic = None
        self.encoder = encoder
        self.on_frame = on_frame
        self.enabled = False
        self.cycle = 0              # the machine's own counter
        self.cycle0 = 0             # ... when recording began
        self.stepped = 0            # frames stepped while enabled
        self.out = 0                # frames emitted
        self.fast_n = 1
        self.fast_phase = 0
        self.keys = demo_overlay.KeyStrip()
        self.key_log = []           # (output frame index, key)
        self.hashes = []
        self.pop = None             # the popover box on screen, or None
        self.popovers = []          # [first output frame, last] per popover
        self.cues = []              # [first frame, end frame, text]
        self.cue_end = -1           # the open cue's end frame (cue_open)
        self.cue_text = None
        self.cue_due = False        # a cue's quiet pause is still owed
        self.demo = None            # the demo's name, for refusals
        self.transcript = []        # (seconds, label, rows)
        self.poster_pngs = {}       # phosphor -> the poster PNG
        self._poster_explicit = False
        self._poster_pending = False
        self.last_png = None        # raw bytes of the latest screen_image
        self._rgb = None
        self._pic = None
        self._strips = {}

    # -- the clock ---------------------------------------------------
    def start(self):
        self.cycle = self.c.call_tool('step', {'cycles': 0})['cycle']
        self.cycle0 = self.cycle
        self.enabled = True

    def step_frame(self):
        r = self.c.call_tool('step', {'cycles': FRAME_CYCLES})
        self.cycle = r['cycle']
        if not self.enabled:
            return
        self.stepped += 1
        if self.fast_n > 1:
            self.fast_phase += 1
            if self.fast_phase % self.fast_n:
                return
        self._capture()

    def elapsed_cycles(self):
        return self.cycle - self.cycle0

    # -- demo-facing events ------------------------------------------
    def key(self, key):
        if self.enabled:
            if self.cue_active():
                raise RecorderError(
                    f'{self.demo}: a key ({key!r}) was sent while the '
                    f'caption {self.cue_text!r} was on screen -- say() '
                    f'holds the screen for the reading time; a caption '
                    f'over output only is say(text, over=True) and ends '
                    f'before the next key')
            self.cue_finish()           # the owed quiet pause, if any
            self.keys.press(key, self.out)
            for ch in demo_overlay.split_keys(key):
                self.key_log.append((self.out, ch))

    def cue_active(self):
        return self.enabled and self.out < self.cue_end

    def cue_open(self, text):
        """Open a cue at the next frame; it closes cue_frames(text)
        output frames later (the VTT end is exactly that frame)."""
        if not self.enabled:
            return
        if self.fast_n != 1:
            raise RecorderError(f'{self.demo}: say() inside fast(): the '
                                f'cue would be timed in dropped frames')
        self.cues.append([self.out, self.out + cue_frames(text), text])
        self.cue_end, self.cue_text, self.cue_due = \
            self.cues[-1][1], text, True
        if not self.poster_pngs and not self._poster_explicit:
            self._poster_pending = True

    def cue_finish(self):
        """Step until the open cue has closed and its quiet pause has
        passed (a no-op when none is owed)."""
        if not (self.enabled and self.cue_due):
            return
        target = self.cue_end + quiet_frames()
        while self.out < target:
            self.step_frame()
        self.cue_due = False

    def poster(self):
        if self.enabled:
            self._poster_explicit = True
            self._poster_pending = True

    def popover(self, text, seconds):
        """Hold the machine `seconds` with a bordered box of `text` over
        the lower right of the picture (the operator's one overlay on
        the picture). The box is built first, so a glyph the font lacks
        raises before a single frame carries it."""
        box = demo_overlay.render_box(text, *self._pic_area())
        if self.fast_n != 1:
            raise RecorderError('popover() inside fast(): the box '
                                'would be dropped with the frames')
        if not self.enabled:
            return
        first = self.out
        self.pop = box
        try:
            for _ in range(round(seconds * FPS)):
                self.step_frame()
        finally:
            self.pop = None
        if self.out > first:
            self.popovers.append((first, self.out - 1))

    def checkpoint(self, label, rows):
        if self.enabled:
            self.transcript.append((self.out / FPS, label, rows))

    def set_fast(self, n):
        self.fast_n = n
        self.fast_phase = 0

    # -- one frame ---------------------------------------------------
    def _strip_bytes(self, caps, badge):
        key = (tuple(caps), badge)
        got = self._strips.get(key)
        if got is None:
            if len(self._strips) > 512:
                self._strips.clear()
            got = demo_overlay.render_strip(caps, badge)
            self._strips[key] = got
        return got

    def _capture(self):
        badge = ((self.fast_n, self.elapsed_cycles())
                 if self.fast_n > 1 else None)
        caps = self.keys.caps(self.out, demo_overlay.keys_avail(badge))
        strip = self._strip_bytes(caps, badge)
        self._look()
        pic = (demo_overlay.blit_box(self._pic, self.pop) if self.pop
               else self._pic)
        frame = pic + strip
        # the hash is of the CANONICAL frame, before any tint: one
        # frames.sha256 per display covers all three films
        self.hashes.append(hashlib.sha256(frame).hexdigest())
        if self._poster_pending:
            tinted = self._tinted()
            self.poster_pngs = {ph: self._poster_of(tinted[ph])
                                for ph in self.phosphors}
            self._poster_pending = False
        pics = None
        if self.encoder or self.on_frame:
            pics = self._pics_for(self.pop)
        if self.encoder:
            self.encoder.write(pics, strip)
        if self.on_frame:
            self.on_frame(self.out, frame, dict(
                strip=strip, caps=caps, badge=badge, rgb=self._rgb,
                pic=self._pic, popover=self.pop, pics=pics,
                png=self.last_png,
                cycle=self.elapsed_cycles()))
        self.out += 1

    def _tinted(self):
        """The current canonical picture as each phosphor shows it,
        recomputed only when the picture CHANGED (8% of frames,
        learning:01M59F3YBYZYAYFHG6J9Y5K1VF). Keyed by identity, and the
        key is held, so a picture can never be served another's tint."""
        if self._tint_src is not self._pic:
            self._tint_out = {
                ph: demo_phos.tint(self._pic, demo_phos.ALL_TABLES[ph])
                for ph in self.phosphors}
            self._tint_src = self._pic
        return self._tint_out

    def _pics_for(self, pop):
        """What each encoder is handed as the picture: the tint, with the
        popover box drawn over it AFTER the tint (the box is the film's
        furniture, in its own colours, and the tint table would black
        them out)."""
        tinted = self._tinted()
        if not pop:
            return dict(tinted)
        return {ph: demo_overlay.blit_box(t, pop)
                for ph, t in tinted.items()}

    @staticmethod
    def _poster_of(pic):
        return demo_png.encode_rgb(
            *demo_png.upscale(demo_overlay.FRAME_W,
                              demo_overlay.PIC_H, pic, UPSCALE))

    def _pic_area(self):
        """(right, bottom) of the display's picture in the frame, for the
        popover: the //e's 560x384 sit centred between pillars and
        bands; the card's picture is where its last frame put it."""
        if self.display == 'ut' and self._ut_area:
            return self._ut_area
        return (demo_overlay.FRAME_W if self.display == 'ut'
                else demo_overlay.APPLE_X + demo_overlay.SCREEN_W,
                demo_overlay.PIC_H if self.display == 'ut'
                else demo_overlay.APPLE_Y + demo_overlay.SCREEN_H)

    def _look(self):
        """Fetch the display's picture for this frame into self._rgb (the
        display's own pixels) and self._pic (the FRAME_W x PIC_H
        picture, pillarboxed when narrower)."""
        if self.display == 'ut':
            return self._look_ut()
        r = self.c.call_tool('screen_image', {'path': self.png})
        if not r.get('ok'):
            raise RecorderError(f'screen_image failed: {r}')
        with open(self.png, 'rb') as f:
            data = f.read()
        os.unlink(self.png)
        if data != self.last_png:
            w, h, rgb = demo_png.decode_rgb(data)
            if (w, h) != (demo_overlay.SCREEN_W, demo_overlay.SCREEN_H):
                raise RecorderError(f'screen_image is {w}x{h}, wanted '
                                    f'{demo_overlay.SCREEN_W}x'
                                    f'{demo_overlay.SCREEN_H}')
            try:
                canon = demo_phos.canon_one_level(
                    rgb, f'{self.demo or "the demo"}: the //e picture')
            except demo_phos.PhosError as e:
                raise RecorderError(str(e))
            self.last_png, self._rgb = data, rgb
            self._pic = demo_overlay.pad_picture(canon)

    def _look_ut(self):
        """The UltraTerm's picture, drawn on the host from the card's
        own state (scripts/demo_ut.py): the CRTC registers, the
        attribute latch and the raw VRAM."""
        st = self.c.call_tool('ultraterm_state', {'addr': 0, 'count': 4096})
        if not st.get('installed') or 'vram' not in st:
            raise RecorderError(f'ultraterm_state gave no card: {st}')
        if self._ut_rom is None:
            # the revision the MCP instance was started with (run_demo:
            # demo_ut.mcp_env): its character ROM, and the proof that
            # the guest programmed THAT card's format-4 entry
            try:
                self._ut_rom = demo_ut.load_chargen()
                demo_ut.check_programmed(st)
            except demo_ut.UTError as e:
                raise RecorderError(str(e))
        if not st.get('vidsel'):
            raise RecorderError('the UltraTerm is not driving the monitor '
                                '(VIDSEL clear): a frame of the //e video '
                                'would be filmed as the card')
        lit = demo_ut.cursor_visible(st, 2 * self.out)
        key = demo_ut.state_key(st, st['vram'], lit)
        if key != self._ut_key:
            try:
                w, h, rgb = demo_ut.render_native(st, st['vram'],
                                                  self._ut_rom, lit)
                fw, fh, frgb = demo_ut.fit(w, h, rgb)
                stray = set(frgb) - demo_phos.CANON_BYTES
                if stray:
                    raise RecorderError(
                        f'{self.demo or "the demo"}: the card picture '
                        f'holds non-canonical byte value(s) '
                        f'{sorted(stray)[:4]}; a tint would black them')
                self._pic = demo_overlay.pad_picture(frgb, fw, fh)
                self._ut_area = ((demo_overlay.FRAME_W + fw) // 2,
                                 (demo_overlay.PIC_H + fh) // 2)
            except (demo_ut.UTError, ValueError) as e:
                raise RecorderError(f'UltraTerm frame: {e}')
            self._ut_key, self._rgb = key, rgb

    # -- the sidecar files -------------------------------------------
    def write_sidecars(self, dest, name, suffix=''):
        with open(os.path.join(dest, name + suffix + '.vtt'), 'w') as f:
            f.write('WEBVTT\n\n')
            for first, last, text in self.cues:
                f.write(f'{vtt_time(first / FPS)} --> '
                        f'{vtt_time(last / FPS)} {CUE_SETTINGS}\n'
                        f'{vtt_escape(text)}\n\n')
        with open(os.path.join(dest, 'transcript' + suffix + '.txt'), 'w') as f:
            for sec, label, rows in self.transcript:
                f.write(f'== {label} (t={sec:.1f} s)\n')
                for row in rows:
                    f.write(row.rstrip() + '\n')
                f.write('\n')
        with open(os.path.join(dest, 'frames' + suffix + '.sha256'), 'w') as f:
            f.write(''.join(h + '\n' for h in self.hashes))
        if not self.poster_pngs and self._pic is not None:
            # no say() and no poster(): the last picture, so every demo
            # has its posters
            tinted = self._tinted()
            self.poster_pngs = {ph: self._poster_of(tinted[ph])
                                for ph in self.phosphors}
        for ph, png in self.poster_pngs.items():
            with open(os.path.join(dest, f'poster{suffix}-{ph}.png'),
                      'wb') as f:
                f.write(png)


# -- the demo API ------------------------------------------------------------

class DemoAPI:
    """say / hold / fast / poster and the expect_* assertions, as
    methods over Term. Gate mode uses this class as it stands; record
    mode overrides the video-only half (RecTerm below). The assertions
    are the same code in both modes, and none of them depends on the
    slice size (learning:01M1QY8TDRAX1N92CZQ143Q614)."""

    recording = False
    # the mean emulated time of one slice: gate mode steps 40k-160k
    # cycles, record mode 3-5 whole frames. A `seconds=` budget is
    # turned into slices with this.
    SLICE_SECONDS = 100_000 / CYCLES_PER_SEC

    def screen(self):
        """The glass. On the //e's 80 columns the MCP's screen_text
        decodes an inverse cell wrongly (alternate character set: codes
        $60-$7F are inverse lower case, the letter itself, but it
        reports the code less $40: inverse `sh` reads as `3(`). The
        card's text is the letter. So the //e's cells are read back
        from the text pages (main = odd columns, aux = even, TRM
        interleave) and every code below $80, outside $40-$5F
        (MouseText, left as screen_text has it), is the character its
        code names: $00-$1F inverse upper case = code + $40, the rest
        the code. A cell with bit 7 set is normal text, as before.
        The result is the raw machine screen on both displays."""
        rows = super().screen()
        if self.backend != 'text80' or not rows:
            return rows
        sw = self.c.call_tool('softswitches', {})
        if not (sw.get('ALTCHARSET') and sw.get('COL80')):
            return rows
        main = self.c.call_tool('peek', {'addr': 0x400, 'count': 0x400,
                                         'bank': 'main'})['bytes']
        aux = self.c.call_tool('peek', {'addr': 0x400, 'count': 0x400,
                                        'bank': 'aux'})['bytes']
        out = []
        for r, row in enumerate(rows[:24]):
            cells = list(row.ljust(80))
            base = (r % 8) * 0x80 + (r // 8) * 0x28
            for col in range(80):
                code = (main if col & 1 else aux)[base + col // 2]
                if code >= 0x80 or 0x40 <= code <= 0x5F:
                    continue
                cells[col] = chr(code + 0x40 if code < 0x20 else code)
            out.append(''.join(cells))
        return out + rows[24:]

    def init_demo(self):
        self._fast = 1
        self.floppy = None
        self.last_cmd = None
        self.checks = 0
        self.width = 40 if self.backend == 'text40' else 80
        self.keylog = []            # every key sent, one char each
        self.cp = []                # (label, rows) at every expect_*
        self.measures = {}          # measure(name, value)

    demo_name = None
    _gate_cue = None            # gate mode: (text, end cycle) of an open over-cue

    def _refuse_key(self, key, text):
        raise RecorderError(
            f'{self.demo_name}: a key ({key!r}) was sent while the '
            f'caption {text!r} was on screen -- say() holds the screen '
            f'for the reading time; a caption over output only is '
            f'say(text, over=True) and ends before the next key')

    def press(self, key, cyc=None):
        self._guard_key(key)
        self.keylog.extend(demo_overlay.split_keys(key))
        super().press(key, cyc)

    def _guard_key(self, key):
        """Gate mode: refuse a key while a say(over=True) cue is open
        (emulated cycles; record mode counts output frames)."""
        if self._gate_cue is not None:
            text, end = self._gate_cue
            if self._cycle() < end:
                self._refuse_key(key, text)
            self._cue_finish()          # the owed quiet pause

    def _cycle(self):
        return self.c.call_tool('step', {'cycles': 0})['cycle']

    def say(self, text, over=False):
        """A caption BEAT. The cue opens now; the screen then holds with
        no key for the reading time (reading_seconds), the cue closes,
        and a quiet pause follows before the next action. over=True
        narrates a wait that has no typing in it (a compile, a long
        listing): it returns at once, the cue may overlap output, and a
        key sent before it closes is refused. endcue() waits it out."""
        self.endcue()
        self._cue_open(text)
        if not over:
            self.endcue()

    def endcue(self):
        """Wait out an open cue and its quiet pause (no-op if none)."""
        self._cue_finish()

    def _cue_open(self, text):
        # gate mode: the same emulated time, no video
        if self._fast != 1:
            raise RecorderError(f'{self.demo_name}: say() inside fast(): '
                                f'the cue would be timed in dropped frames')
        self._gate_cue = (text, self._cycle() + cue_frames(text) *
                          FRAME_CYCLES)

    def _cue_finish(self):
        if self._gate_cue is None:
            return
        end = self._gate_cue[1] + quiet_frames() * FRAME_CYCLES
        self._gate_cue = None
        left = end - self._cycle()
        if left > 0:
            self.hold(left / CYCLES_PER_SEC)

    def hold(self, seconds):
        """Dwell: the machine runs `seconds` of emulated time. In record
        mode that is whole video frames; in gate mode it is the same
        emulated time in plain steps, so a key sent after a hold meets
        the same machine in both modes. hold(0) steps nothing."""
        left = int(round(seconds * CYCLES_PER_SEC))
        while left > 0:
            n = min(left, 100_000)
            self.c.call_tool('step', {'cycles': n})
            left -= n

    @contextlib.contextmanager
    def fast(self, n):
        if self._gate_cue is not None:
            raise RecorderError(f'{self.demo_name}: fast() while the '
                                f'caption {self._gate_cue[0]!r} is open: '
                                f'endcue() first')
        self._fast = n
        try:
            yield
        finally:
            self._fast = 1

    def poster(self):
        pass

    def popover(self, text, seconds):
        """The operator's end-of-film box (docs/DEMO-FEDGREP.md). Gate
        mode: it is hold(), after the two refusals record mode makes, so
        the sweep catches them: a glyph the font lacks (render_box is
        pure Python) and a popover inside fast()."""
        demo_overlay.render_box(text)
        if self._fast != 1:
            raise RecorderError('popover() inside fast(): the box '
                                'would be dropped with the frames')
        self.hold(seconds)

    @staticmethod
    def _trim(rows):
        """The screen's rows without the blank ones at the top and the
        bottom; blank rows BETWEEN text rows stay (a transcript that
        drops them misquotes a file that has a blank line)."""
        rows = list(rows)
        while rows and not rows[0]:
            rows.pop(0)
        while rows and not rows[-1]:
            rows.pop()
        return rows

    def measure(self, name, value):
        """Record a figure this run measured (an integer, e.g. emulated
        cycles). It is printed by the gate and written into the film's
        stamp (NAME[-ut].stamp.json, "measures"), so a page can quote what
        the run saw. Never put it in a checkpoint label: the two displays
        differ and the same-text row would go red."""
        self.measures[name] = int(value)

    def _checkpoint(self, label, rows):
        self.cp.append((label, list(rows)))

    # typing
    def run_cmd_echoed(self, cmd, label):
        self.last_cmd = cmd
        super().run_cmd_echoed(cmd, label)

    def type_line(self, text, label):
        """Type `text` a key at a time, require it to echo, press RET."""
        self.type_and_expect_echo(text, label)
        self.enter()

    # observation
    def _dump(self, rows):
        return '\n'.join(r for r in rows if r)

    def type_and_expect_echo(self, s, label, slices=40):
        """Type `s` a key at a time and require the terminal to echo it.
        The echo can lag a slice or two behind the key (a console busy
        with a background job), so poll for it with a timeout rather
        than judging after one slice. A line longer than the screen is
        wrapped, so the rows are also read joined."""
        self.type_human(s)
        for _ in range(slices):
            rows = [r.rstrip() for r in self.screen()]
            if any(s in r for r in rows) or s in ''.join(rows):
                return
            self._slice()
        raise AssertionError(
            f'{label}: typed {s!r} but it did NOT echo -- the terminal '
            f'is not in cooked+echo:\n' +
            '\n'.join(r.rstrip() for r in self.screen() if r.strip()))

    def settled(self, label, seconds=None):
        """The rendered screen once the prompt is back and TWO polls in
        a row are identical (a paused-CPU snapshot can be mid-scroll,
        learning:01M1AH9XWGC8ZS7HNBJVJ2JHXW). Rows are right-stripped."""
        prev, stable = None, 0
        rows = []
        budget = int((seconds or SETTLE_SECONDS) / self.SLICE_SECONDS) + 1
        for _ in range(budget):
            rows = [r.rstrip() for r in self.screen()]
            nonblank = [r for r in rows if r]
            if nonblank and nonblank[-1] == '$' and rows == prev:
                stable += 1
                if stable >= 2:
                    return rows
            else:
                stable = 0
            prev = rows
            self._slice()
        raise Wedged(f'{label}: the screen never settled on a bare '
                     f'prompt; screen:\n{self._dump(rows)}')

    def output(self, label, seconds=None):
        """The settled output rows of the last run_cmd_echoed command:
        the rows below its echo and above the prompt that is back. The
        full settled screen goes to the transcript."""
        rows = self.settled(label, seconds)
        cmd = self.last_cmd
        if cmd is None:
            raise AssertionError(f'{label}: no command has been run')
        head = '$ ' + cmd
        first = None
        for i in range(len(rows) - 1, -1, -1):
            if rows[i].startswith(head[:self.width]):
                first = i
                break
        if first is None:
            raise AssertionError(
                f'{label}: the echo of {cmd!r} is not on the screen '
                f'(scrolled off?); screen:\n{self._dump(rows)}')
        last = max(i for i, r in enumerate(rows) if r)
        self._checkpoint(label, self._trim(rows))
        return rows[first + -(-len(head) // self.width):last]

    # assertions: content and order, never row membership alone
    # (learning:01M317VKBTQPCDM2DNMD36N1QV)
    def expect(self, cond, label):
        """A plain assertion that names itself; the checkpoint is the
        screen as the machine shows it (see screen())."""
        self.checks += 1
        screen = [r.rstrip() for r in self.screen()]
        if not cond:
            raise AssertionError(f'{label}: failed; screen:\n' +
                                 self._dump(screen))
        self._checkpoint(label, self._trim(screen))

    def expect_lines(self, spec, label, seconds=None):
        """Settle, then require the last command's output rows to be
        exactly `spec`: a list of rows (content and order) or an int
        (a row count). Returns the rows."""
        rows = self.output(label, seconds)
        self.checks += 1
        if isinstance(spec, int):
            if len(rows) != spec:
                raise AssertionError(
                    f'{label}: wanted {spec} output rows, got '
                    f'{len(rows)}:\n{self._dump(rows)}')
        elif rows != [s.rstrip() for s in spec]:
            raise AssertionError(
                f'{label}: output rows differ.\n--- wanted\n'
                + ('\n'.join(spec) or '(no rows: silence)')
                + f'\n--- got\n{self._dump(rows) or "(no rows)"}')
        return rows

    def expect_text(self, text, label, seconds=None):
        """Like expect_lines, with the rows given as one string."""
        return self.expect_lines(text.rstrip('\n').split('\n')
                                 if text else [], label, seconds)

    def expect_cmp_silent(self, label, seconds=None):
        """The last command printed NOTHING between its echo and the
        prompt. Silence is only evidence when the echo was found and
        the prompt is back, which output() proves first."""
        return self.expect_lines([], label, seconds)

    # crossing a `bye` window ------------------------------------------
    def main_rows(self):
        """The motherboard's 40-column MAIN text page, right-stripped.

        This is the TENANT's glass during a `bye` window, by `bye`'s own
        design: byelaunch.s step 8 sets TEXTMODEON/PAGE2OFF/HIRESOFF,
        clears 80STORE and COL80, and zeroes UT_PAGE_CTL, so the
        motherboard's 40-column video is what a person sees while a
        ProDOS program owns the machine. Blank rows are dropped, as
        check_examples.py's own main_rows does: the page carries
        whatever the previous owner left on it."""
        r = self.c.call_tool('screen_text', {})
        return [x.rstrip() for x in (r.get('main') or []) if x.strip()]

    def run_bye(self, cmd, names, label, key=' ', dwell=2.0,
                seconds=150):
        """Run `cmd` (a `bye`, directly or under make) and cross the
        window where a ProDOS tenant owns the machine. Returns
        (the rows after the command, the window rows) -- the same
        order as check_examples.py's run_bye, so the two cannot be
        confused at a call site.

        WHY THIS CANNOT BE run_cmd_echoed + expect_lines. Inside the
        window there is no maux prompt to settle on, so every assertion
        in this file would either hang or read the wrong screen. On the
        `ut` backend it is worse than that: MEASURED 2026-10-25,
        `vidsel` is FALSE from the farewell until the restore, so the
        card is not selected and its surface stays frozen on `Leaving
        maux for ProDOS...` for the whole tenant run -- an expect_*
        taken there would pass on leftover maux text that was never the
        tenant's output (docs/DEMO-W17-NOTES.md). That is why a demo
        using this method is filmed on `text80` only.

        The mechanism is copied from check_examples.py `run_bye`, which
        is the proven one: poll the MAIN page for `names` while the
        farewell is NOT showing, press `key` once they are up, wait for
        `Welcome back.`, then require the prompt settled. Copied as a
        MECHANISM, not a spelling, with one deliberate change: it steps
        through `_slice()` and never `call_tool('step')` directly, so
        RECORD mode captures the window as frames instead of jumping
        over the one beat the demo exists to show.

        The window check is row MEMBERSHIP, which this file warns
        against everywhere else (learning:01M317VKBTQPCDM2DNMD36N1QV).
        It is justified here only because an unsettleable screen cannot
        be compared in order -- so treat it as a LIVENESS check, and
        put the correctness proof AFTER the restore, where the ordinary
        expect_* assertions work again (W17 compares the tenant's own
        output against maux's `ls`). `names` must be whole rows, not
        substrings, so it is at least as strong as it can be here.

        `dwell` seconds pass before the key, so a viewer sees the
        tenant's screen rather than a flash of it.
        """
        self.run_cmd_echoed(cmd, label)
        budget = int(seconds / self.SLICE_SECONDS) + 1
        window = None
        pressed = False
        for _ in range(budget):
            if window is None:
                main = self.main_rows()
                if all(n in main for n in names) and \
                        not any('Leaving maux' in r for r in main):
                    window = main
                    self._checkpoint(f'{label} (tenant window)', main)
            if window is not None and key and not pressed:
                # a key sent under an open say(over=True) caption is
                # refused by _guard_key, and the press lands at a time
                # the tenant chooses, so wait the caption out first
                self.endcue()
                # the beat the demo exists to show: let the tenant's
                # own screen stand before the key that quits it. hold()
                # is the same emulated time in both modes, so the key
                # still meets the same machine in the gate.
                self.hold(dwell)
                self.press(key)
                pressed = True
            if window is not None and \
                    any('Welcome back.' in r for r in self.screen()):
                rows = self.settled(f'{label} (back in maux)')
                self.checks += 1
                return rows, window
            self._slice()
        raise Wedged(
            f'{label}: never crossed the bye window. tenant rows '
            f'{"NEVER appeared" if window is None else "appeared"}; '
            f'wanted {names!r}.\nMAIN page now:\n'
            + self._dump(self.main_rows())
            + f'\n{self.backend} glass now:\n'
            + self._dump([r.rstrip() for r in self.screen()]))


class GateTerm(DemoAPI, Term):
    """Gate mode: Term's own jittered slices, no video."""

    def __init__(self, c, backend, seed=DEFAULT_SEED):
        Term.__init__(self, c, backend, seed)
        self.init_demo()


class RecTerm(DemoAPI, Term):
    """Record mode: every slice is whole video frames."""

    recording = True
    SLICE_SECONDS = 4 * FRAME_CYCLES / CYCLES_PER_SEC

    def __init__(self, c, backend, rec, seed=DEFAULT_SEED):
        Term.__init__(self, c, backend, seed)
        self.rec = rec
        self.init_demo()

    def _slice(self, cyc=None):
        if cyc is None:
            n = self.rng.randint(*KEY_FRAMES)
        else:
            n = max(1, round(cyc / FRAME_CYCLES))
        for _ in range(n):
            self.rec.step_frame()

    def press(self, key, cyc=None):
        self.rec.key(key)
        super().press(key, cyc)

    def _guard_key(self, key):
        pass                    # Recorder.key() owns the check

    def _cue_open(self, text):
        self.rec.cue_open(text)

    def _cue_finish(self):
        self.rec.cue_finish()

    def hold(self, seconds):
        for _ in range(round(seconds * FPS)):    # hold(0) steps nothing
            self.rec.step_frame()

    @contextlib.contextmanager
    def fast(self, n):
        if self.rec.enabled and self.rec.cue_due:
            raise RecorderError(f'{self.demo_name}: fast() while the '
                                f'caption {self.rec.cue_text!r} is open: '
                                f'endcue() first')
        self.rec.set_fast(n)
        try:
            yield
        finally:
            self.rec.set_fast(1)

    def poster(self):
        self.rec.poster()

    def popover(self, text, seconds):
        self.rec.popover(text, seconds)

    def _checkpoint(self, label, rows):
        super()._checkpoint(label, rows)
        self.rec.checkpoint(label, rows)


# -- running a demo ----------------------------------------------------------

def load_demo(path):
    spec = importlib.util.spec_from_file_location(
        'demo_' + os.path.splitext(os.path.basename(path))[0], path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    d = getattr(mod, 'DEMO', None)
    if not isinstance(d, dict) or not callable(getattr(mod, 'run', None)):
        raise RecorderError(f'{path}: needs a DEMO dict and a run(t)')
    for k in ('name', 'title', 'image', 'gate'):
        if k not in d:
            raise RecorderError(f'{path}: DEMO has no {k!r}')
    if 'backends' in d and 'backend' in d:
        raise RecorderError(f'{path}: DEMO has both backend and backends')
    bk = d.get('backends', None)
    if bk is None:
        if 'backend' not in d:
            raise RecorderError(f'{path}: DEMO has no backend(s)')
        bk = (d['backend'],)
    if isinstance(bk, str) or not bk or len(set(bk)) != len(bk):
        raise RecorderError(f'{path}: backends {bk!r} must be a tuple of '
                            f'distinct names')
    for b in bk:
        if b not in BACKENDS:
            raise RecorderError(f'{path}: backend {b!r}: only {BACKENDS}')
    d = dict(d, backends=tuple(bk), backend=bk[0])
    if sum(1 for b in bk if b != 'ut') > 1:
        raise RecorderError(f'{path}: {bk}: at most one //e display and '
                            f'the UltraTerm')
    if d['image'] not in IMAGES:
        raise RecorderError(f'{path}: image {d["image"]!r}: only '
                            f'{sorted(IMAGES)} exist to film on')
    if d.get('floppy') is not None and d['floppy'] not in FLOPPIES:
        raise RecorderError(f'{path}: floppy {d["floppy"]!r}: only '
                            f'{sorted(FLOPPIES)} exist')
    if d['gate'] != 'check-demo-' + d['name']:
        raise RecorderError(f'{path}: DEMO gate must be '
                            f'check-demo-{d["name"]}, not {d["gate"]!r}')
    if d['name'] != os.path.splitext(os.path.basename(path))[0]:
        raise RecorderError(f'{path}: DEMO name {d["name"]!r} must match '
                            f'the file name')
    # the display and the phosphor are read off the END of a file's stem
    # (_belongs): a demo named like one would make that ambiguous
    for tail in (SUFFIX['ut'],) + tuple('-' + p for p in demo_phos.NAMES):
        if d['name'].endswith(tail):
            raise RecorderError(f'{path}: DEMO name {d["name"]!r} ends in '
                                f'{tail!r}, which the output file names use '
                                f'for the display and the phosphor')
    return d, mod.run


class Result:
    """What a run leaves behind, for check_recorder.py and the CLI."""
    ok = False
    error = None
    mode = 'gate'
    checks = 0
    frames = 0              # frames emitted
    stepped = 0             # frames stepped (== frames, outside fast())
    cycles = 0              # emulated cycles recorded
    hashes = ()
    key_log = ()
    popovers = ()           # (first, last) output frames per popover
    last_png = None
    out_dir = None
    seconds = 0.0           # video time
    backend = None
    keys = ()               # every key sent, one char each (both modes)
    transcript = ()         # (label, rows) at every expect_* (both modes)
    measures = None         # {name: int} from t.measure() (both modes)


def run_demo(path, record=None, encode=True, seed=DEFAULT_SEED, image=None,
             setup=(), on_frame=None, host_clock=False, floppy=None,
             backend=None, phosphors=None):
    """Run one demo on one of the displays it declares (the first by
    default). record=None is gate mode; record=OUTDIR is record mode.
    Returns a Result; ok False carries .error (the demo failed, nothing
    is left in OUTDIR). A RecorderError propagates."""
    demo, run = load_demo(path)
    backend = backend or demo['backend']
    if backend not in demo['backends']:
        raise RecorderError(f'{path}: declares {demo["backends"]}, not '
                            f'{backend!r}')
    phosphors = tuple(demo_phos.NAMES if phosphors is None else phosphors)
    res = Result()
    res.backend = backend
    res.mode = 'record' if record else 'gate'
    old_disk = e2e_term.DISK
    e2e_term.DISK = os.path.abspath(image or IMAGES[demo['image']])
    work = tempfile.mkdtemp(prefix='demo_record.') if record else None
    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
    if backend == 'ut':
        # the card's revision: the films show the original card (v1)
        env = demo_ut.mcp_env(env)
    c = MCPClient([SUPERVISOR], env)
    rec = enc = None
    try:
        c.initialize()
        c.require_tools('screen_text', 'screen_image', 'step', 'type')
        if record:
            if encode:
                enc = EncoderSet(work, demo['name'] + SUFFIX[backend],
                                 demo_overlay.FRAME_W, demo_overlay.FRAME_H,
                                 phosphors)
            rec = Recorder(c, work, enc, on_frame, backend, phosphors)
        flop = floppy or (FLOPPIES[demo['floppy']]
                          if demo.get('floppy') else None)
        if record:        # hash every input BEFORE the machine boots
            snap = demo_stamp.snapshot(
                os.path.abspath(path), e2e_term.DISK, flop, backend, seed,
                setup, host_clock,
                demo_stamp.ffmpeg_version() if encode else None)
        if flop:
            flop = os.path.abspath(flop)
            if not os.path.exists(flop):
                raise RecorderError(f'floppy {flop} missing -- '
                                    f'make demo-images')
            # Mount BEFORE boot(): boot()'s own `reset` keeps the Disk ][
            # attached, and mounting after a text40 boot's pokes would
            # cold-reset them away (the native-80 console would boot
            # silently). check_floppy.py's call, and its reply check.
            r = c.call_tool('mount_disk', {'path': flop, 'slot': 6,
                                           'copy': True})
            if r.get('ok') is False or r.get('slot') != 6 or \
                    r.get('type') != 'sector' or not r.get('boot_rom'):
                raise RecorderError(f'mount_disk(floppy, slot 6) '
                                    f'failed: {r}')
        plain = boot(c, backend,
                     reset_extra=None if host_clock else PINNED_CLOCK)
        if backend == 'ut':
            try:
                demo_ut.check_programmed(
                    c.call_tool('ultraterm_state', {}))
            except demo_ut.UTError as e:
                raise RecorderError(str(e))
        t = (RecTerm(c, backend, rec, seed) if record
             else GateTerm(c, backend, seed))
        t.rng.seed(seed)
        t.demo_name = demo['name']
        if record:
            rec.demo = demo['name']
        t.floppy = flop            # the file actually in drive 1, or None
        for cmd in setup:               # teeth experiments, not filmed
            t.run_cmd_echoed(cmd, 'setup')
        t.wait_prompt('boot settled')    # `vidmode 80` may still be running
        if backend == 'ut':
            # The //e's boot typed `vidmode 80` and the card's did not, so
            # the first process a demo starts would get a different PID
            # on the two displays (and `ps` shows PIDs): spend the same
            # one. Not filmed.
            t.run_cmd_echoed('true', 'setup')
        t.press('\x0c')            # a clean screen on both, not filmed:
        t.wait_prompt('demo start')  # the //e's still shows `vidmode 80`
        for _ in range(40):          # ... until the clear has happened
            if len([r for r in t.screen() if r.strip()]) == 1:
                break
            t._slice()
        else:
            raise RecorderError(
                'the screen was not cleared before the demo started; '
                'screen:\n' + '\n'.join(r.rstrip() for r in t.screen()
                                         if r.strip()))
        t.keylog.clear()
        t.cp.clear()
        del plain
        if record:
            rec.start()
        run(t)
        t.endcue()                  # a trailing over-cue closes in the film
        res.checks = t.checks
        res.keys = tuple(t.keylog)
        res.transcript = tuple((lab, tuple(rows)) for lab, rows in t.cp)
        res.measures = dict(t.measures)
        res.ok = True
        if record:
            res.frames, res.stepped = rec.out, rec.stepped
            res.cycles = rec.elapsed_cycles()
            res.hashes = tuple(rec.hashes)
            res.key_log = tuple(rec.key_log)
            res.popovers = tuple(rec.popovers)
            res.last_png = rec.last_png
            res.seconds = rec.out / FPS
            if enc:
                enc.close()
            rec.write_sidecars(work, demo['name'], SUFFIX[backend])
            # what this film was recorded from (docs/RECORDER.md
            # "Freshness stamps"): check-site recomputes it
            moved = demo_stamp.finish(snap)
            if moved:
                raise RecorderError('input(s) edited while recording: '
                                    + ', '.join(moved) + ' -- record again')
            demo_stamp.write_stamp(work, demo['name'], SUFFIX[backend],
                                   backend, snap, res.measures)
            res.out_dir = publish(work, record, demo['name'],
                                  SUFFIX[backend])
    except (AssertionError, Wedged) as e:
        res.ok, res.error = False, e
    finally:
        # Order: the encoder dies BEFORE the directory it writes into is
        # removed (EncoderSet.abort kills EVERY encoder, then each closes
        # stdin and is reaped).
        if enc:
            enc.abort()
        try:
            c.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        c.close()
        if work:
            shutil.rmtree(work, ignore_errors=True)
        e2e_term.DISK = old_disk
    return res


def _display_stem(fn):
    """The stem of an output file with its phosphor taken off: the
    display is read from what is left. `poster-ut-amber.png` must come
    out as `poster-ut`, not as a stem that ends in `-amber`."""
    stem = fn.split('.', 1)[0]      # NAME-ut-amber.mp4 -> NAME-ut-amber
    for ph in demo_phos.NAMES:
        if stem.endswith('-' + ph):
            return stem[:-len(ph) - 1]
    return stem


def _belongs(fn, name, suffix):
    """Whether OUTDIR/NAME/fn is one of this display's files: the //e's
    bare names, or the UltraTerm's with the suffix. Every phosphor of a
    display belongs to it."""
    stem = _display_stem(fn)        # NAME-ut.stamp.json -> NAME-ut
    if suffix:
        return stem.endswith(suffix)
    return not stem.endswith(SUFFIX['ut'])


def publish(work, outdir, name, suffix=''):
    """Move the finished files to OUTDIR/NAME/. The staging directory
    is outside OUTDIR, so a failed run never touched it. A stale file
    of THIS display (the //e's bare names, or the UltraTerm's suffixed
    ones) is replaced only now; the other display's files stay."""
    os.makedirs(outdir, exist_ok=True)
    final = os.path.join(outdir, name)
    tmp = os.path.join(outdir, f'.{name}.new.{os.getpid()}')
    shutil.rmtree(tmp, ignore_errors=True)
    os.mkdir(tmp)
    try:
        for fn in os.listdir(work):
            if fn == 'frame.png' or (fn.startswith('ffmpeg.') and
                                     fn.endswith('.log')):
                continue
            shutil.move(os.path.join(work, fn), os.path.join(tmp, fn))
        os.makedirs(final, exist_ok=True)
        for fn in os.listdir(final):
            if _belongs(fn, name, suffix):
                os.unlink(os.path.join(final, fn))
        for fn in os.listdir(tmp):
            os.rename(os.path.join(tmp, fn), os.path.join(final, fn))
        shutil.rmtree(tmp, ignore_errors=True)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    return final


def compare_displays(results):
    """The same keys, the same text: the differences between two
    displays' runs of one demo, as strings ([] when there are none).
    Any difference is a finding, never something to pin."""
    out = []
    a = results[0]
    for b in results[1:]:
        tag = f'{a.backend} vs {b.backend}'
        if a.keys != b.keys:
            n = next((i for i, (x, y) in enumerate(zip(a.keys, b.keys))
                      if x != y), min(len(a.keys), len(b.keys)))
            out.append(f'{tag}: the keys differ at key {n} ({len(a.keys)} '
                       f'vs {len(b.keys)} keys): {a.keys[n:n + 8]!r} vs '
                       f'{b.keys[n:n + 8]!r}')
        la, lb = [x[0] for x in a.transcript], [x[0] for x in b.transcript]
        if la != lb:
            out.append(f'{tag}: the checkpoints differ: {la} vs {lb}')
        else:
            for (lab, ra), (_, rb) in zip(a.transcript, b.transcript):
                if ra != rb:
                    i = next((j for j, (x, y) in enumerate(zip(ra, rb))
                              if x != y), min(len(ra), len(rb)))
                    out.append(f'{tag}: the screen at {lab!r} differs at '
                               f'row {i}: '
                               f'{(ra[i] if i < len(ra) else None)!r} vs '
                               f'{(rb[i] if i < len(rb) else None)!r}')
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(
        description='Run a demo as a gate, or record it as a screencast.')
    ap.add_argument('demos', nargs='*', help='site/demos/NAME.py ...')
    ap.add_argument('--check-ffmpeg', action='store_true',
                    help='only check that ffmpeg can do `make demos` '
                         '(exit 2, naming what is missing, if not)')
    ap.add_argument('--record', metavar='OUTDIR',
                    help='record mode: write OUTDIR/NAME/{NAME-PH.mp4,'
                         'NAME-PH.webm,poster-PH.png,NAME.vtt,'
                         'transcript.txt} for each phosphor PH')
    ap.add_argument('--no-encode', action='store_true',
                    help='with --record: no ffmpeg, no videos; write '
                         'frames.sha256 and the sidecars only')
    ap.add_argument('--backend', choices=BACKENDS,
                    help='run only this display (default: every display '
                         'the demo declares)')
    ap.add_argument('--phosphor', action='append', choices=demo_phos.NAMES,
                    metavar='NAME',
                    help='with --record: film only this monitor (paper, '
                         'green, amber; repeatable; default all three). '
                         'A run with fewer leaves the display with only '
                         'those films, so check-site is red until a full '
                         '`make demos`')
    ap.add_argument('--seed', type=int, default=DEFAULT_SEED)
    ap.add_argument('--image', help='play image to mount (a copy-on-write '
                    'mount; default build/play.po)')
    ap.add_argument('--floppy', help='floppy image for slot 6 '
                    '(overrides DEMO floppy; for teeth experiments)')
    ap.add_argument('--host-clock', action='store_true',
                    help='leave the Timemaster clock on, seeded from the '
                         'host wall clock (a recording then depends on '
                         'when it was made); for measurements only')
    ap.add_argument('--setup', action='append', default=[], metavar='CMD',
                    help='type CMD at the shell before the demo starts '
                         '(not filmed); for teeth experiments')
    args = ap.parse_args(argv)
    if args.check_ffmpeg:
        bad = ffmpeg_problems()
        for b in bad:
            print('demo_record: ' + b, file=sys.stderr)
        return 2 if bad else 0
    if not args.demos:
        ap.error('name at least one demo')
    if args.no_encode and not args.record:
        ap.error('--no-encode needs --record')
    if args.phosphor and not args.record:
        ap.error('--phosphor needs --record')
    # offered order, each once
    phosphors = tuple(p for p in demo_phos.NAMES
                      if p in (args.phosphor or demo_phos.NAMES))
    if not os.path.exists(SUPERVISOR):
        print(f'demo_record: mcp_supervisor not found at {SUPERVISOR}',
              file=sys.stderr)
        return 2
    if args.record and not args.no_encode:
        bad = ffmpeg_problems()
        if bad:
            print('demo_record: ffmpeg cannot do `make demos`:',
                  file=sys.stderr)
            for b in bad:
                print('  ' + b, file=sys.stderr)
            return 2
    failed = 0
    for path in args.demos:
        name = os.path.splitext(os.path.basename(path))[0]
        try:
            declared = load_demo(path)[0]['backends']
        except Exception as e:                    # noqa: BLE001
            failed += 1
            print(f'FAIL {name} ({"record" if args.record else "gate"} '
                  f'mode): {type(e).__name__}: {e}', file=sys.stderr)
            continue
        if args.backend:
            if args.backend not in declared:
                failed += 1
                print(f'FAIL {name}: declares {declared}, not '
                      f'{args.backend!r}', file=sys.stderr)
                continue
            declared = (args.backend,)
        done = []
        for backend in declared:
            tag = f' [{backend}]' if len(declared) > 1 else ''
            try:
                res = run_demo(path, args.record, not args.no_encode,
                               args.seed, args.image, args.setup,
                               host_clock=args.host_clock,
                               floppy=args.floppy, backend=backend,
                               phosphors=phosphors)
            except Exception as e:                # noqa: BLE001
                # one broken demo must not hide the rest of `make demos`
                failed += 1
                print(f'FAIL {name}{tag} ({"record" if args.record else "gate"} '
                      f'mode): {type(e).__name__}: {e}', file=sys.stderr)
                continue
            if res.ok and res.mode == 'gate':
                print(f'PASS {name}{tag} (gate mode, {res.checks} checks)')
                if res.measures:
                    print(f'measures {name}{tag}: ' + ' '.join(
                        f'{k}={v}' for k, v in sorted(res.measures.items())))
                done.append(res)
            elif res.ok:
                print(f'PASS {name}{tag} (record mode, {res.checks} checks): '
                      f'{res.frames} frames, {res.seconds:.1f} s of emulated '
                      f'time -> {res.out_dir}')
                if res.measures:
                    print(f'measures {name}{tag}: ' + ' '.join(
                        f'{k}={v}' for k, v in sorted(res.measures.items())))
                done.append(res)
            else:
                failed += 1
                print(f'FAIL {name}{tag} ({res.mode} mode): {res.error}',
                      file=sys.stderr)
        if len(done) > 1 and len(done) == len(declared):
            diffs = compare_displays(done)
            if diffs:
                failed += 1
                print(f'FAIL {name} (the displays disagree: same keys, same '
                      f'text is the rule):', file=sys.stderr)
                for d in diffs:
                    print('  ' + d, file=sys.stderr)
                for r in done:      # a recording that disagrees is not kept
                    if r.out_dir:
                        for fn in os.listdir(r.out_dir):
                            if _belongs(fn, name, SUFFIX[r.backend]):
                                os.unlink(os.path.join(r.out_dir, fn))
            else:
                print(f'PASS {name} (same keys, same text on '
                      f'{" and ".join(r.backend for r in done)}: '
                      f'{len(done[0].keys)} keys, '
                      f'{len(done[0].transcript)} checkpoints)')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
