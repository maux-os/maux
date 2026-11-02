#!/usr/bin/env python3
"""demo_overlay.py -- the recorder's key strip and speed badge.

A small stdlib blitter over raw 8-bit RGB. ffmpeg on the Mac has no
`drawtext` (Homebrew builds it without freetype) and the sweep box has
no ffmpeg at all, so every pixel an overlay adds is drawn here, before
the frame reaches the encoder (docs/RECORDER.md item 4).

The overlay goes in a STRIP BELOW the picture: the frame is
FRAME_W x (PIC_H+STRIP_H), and nothing is ever drawn over the Apple
screen -- with ONE exception, the operator's (2026-10-20): the popover,
a small bordered box in the lower right of the picture (render_box,
blit_box below; t.popover in scripts/demo_record.py). Coordinates are native; the encoder upscales the whole
frame 2x with nearest-neighbour, so a font pixel scaled x2 here is
4x4 pixels in the file.

Two things appear in the strip:

  * KEY CAPS, left to right: every key Term sent, for about a second
    (KEY_LINGER frames, counted in OUTPUT frames, so a `fast` segment
    does not stretch or shrink them). Printable keys group into words
    (a space ends a word and draws nothing); control keys are named
    (RET, ESC, TAB, DEL, ^C, ^Z ...) and drawn in amber.
  * the SPEED BADGE, right-aligned, only inside `fast(n)`: "xN" in a
    red cap and the emulated cycle count since the demo began.

Font: scripts/demo_font.py (original 5x7 glyphs, MIT, no ROM data).
"""
import re

import demo_font

SCREEN_W = 560              # the //e's own picture (screen_image)
SCREEN_H = 384
# The video frame's picture area. 720 wide: the UltraTerm's 80 columns of
# 9 dots. 432 high: the card as the firmware's own 80x24 format programs
# it, R9=8, is 24 rows of 9 rasters = 216 lines, drawn with every scan
# line doubled (as the //e's 192 become 384): 720x432. The //e's 560x384
# sits centred in it (80-pixel pillars, 24-pixel bands). A card picture
# that is not 216 lines (the original card's interlaced 16-raster rows:
# 384) is not doubled, and
# one bigger than the area is cropped (demo_ut.fit).
FRAME_W = 720
PIC_H = 432
APPLE_X = (FRAME_W - SCREEN_W) // 2     # the //e picture's left edge in it
APPLE_Y = (PIC_H - SCREEN_H) // 2       # ... and its top edge
STRIP_H = 36
FRAME_H = PIC_H + STRIP_H
FPS = 30
KEY_LINGER = 30             # output frames a key stays on screen

SCALE = 2
CAP_Y = 5
CAP_H = 26
CAP_PAD = 6
CAP_GAP = 6
MARGIN = 8

STRIP_BG = (24, 24, 28)
CAP_BG = (62, 64, 74)
CAP_FG = (236, 236, 236)
SPECIAL_BG = (200, 138, 24)
SPECIAL_FG = (18, 14, 6)
BADGE_BG = (190, 40, 30)
BADGE_FG = (255, 255, 255)
COUNT_FG = (205, 205, 205)

_NAMES = {'\r': 'RET', '\n': 'RET', '\x1b': 'ESC', '\t': 'TAB',
          '\x7f': 'DEL'}
_ESC = re.compile(r'\\x([0-9a-fA-F]{2})')


def key_label(ch):
    """('special', name) for a control key, ('char', ch) otherwise. A
    byte with the high bit set (the //e keyboard sends none, but `type`
    can) is drawn as its own hex marker, $8D, never as a silent '?'."""
    if ch in _NAMES:
        return 'special', _NAMES[ch]
    if ord(ch) < 32:
        return 'special', '^' + chr(ord(ch) + 64)
    if ord(ch) > 126:
        return 'special', f'${ord(ch):02X}'
    return 'char', ch


def split_keys(key):
    """Term.press takes a char or a raw \\xHH escape string; return the
    list of single-character keys it stands for."""
    out = []
    pos = 0
    while pos < len(key):
        m = _ESC.match(key, pos)
        if m:
            out.append(chr(int(m.group(1), 16)))
            pos = m.end()
        else:
            out.append(key[pos])
            pos += 1
    return out


class Canvas:
    def __init__(self, width, height, color):
        self.w = width
        self.h = height
        self.buf = bytearray(bytes(color) * (width * height))

    def rect(self, x, y, w, h, color):
        x0, x1 = max(0, x), min(self.w, x + w)
        if x1 <= x0:
            return
        run = bytes(color) * (x1 - x0)
        for yy in range(max(0, y), min(self.h, y + h)):
            o = (yy * self.w + x0) * 3
            self.buf[o:o + len(run)] = run

    def text(self, x, y, s, color, scale=SCALE, strict=False):
        for ch in s:
            rows = demo_font.glyph(ch, strict)
            for ry, row in enumerate(rows):
                for rx, bit in enumerate(row):
                    if bit == '#':
                        self.rect(x + rx * scale, y + ry * scale,
                                  scale, scale, color)
            x += demo_font.ADVANCE * scale

    def bytes(self):
        return bytes(self.buf)


def text_width(s, scale=SCALE):
    return len(s) * demo_font.ADVANCE * scale


def cap_width(label):
    return text_width(label) + 2 * CAP_PAD


class KeyStrip:
    """The model behind the key caps: feed it keys with the OUTPUT frame
    index they were sent at, ask it what to show at a later frame."""

    def __init__(self):
        self.tokens = []            # [kind, text, last_frame]
        self.word_open = False

    def press(self, key, frame):
        for ch in split_keys(key):
            kind, name = key_label(ch)
            if kind == 'special':
                self.tokens.append(['special', name, frame])
                self.word_open = False
            elif ch == ' ':
                self.word_open = False
            elif (self.word_open and self.tokens and
                  self.tokens[-1][0] == 'word'):
                self.tokens[-1][1] += ch
                self.tokens[-1][2] = frame
            else:
                self.tokens.append(['word', ch, frame])
                self.word_open = True
        del self.tokens[:-64]

    def caps(self, frame, avail):
        """The (kind, text) caps to draw at `frame`, oldest first, the
        newest ones kept when they do not all fit in `avail` pixels."""
        live = [t for t in self.tokens if frame - t[2] < KEY_LINGER]
        shown = []
        used = 0
        for kind, text, _ in reversed(live):
            w = cap_width(text)
            if used + w > avail:
                if not shown:       # one giant word: keep its tail
                    fit = (avail - 2 * CAP_PAD) // text_width('x')
                    if fit > 0:
                        shown.append((kind, text[-fit:]))
                break
            shown.append((kind, text))
            used += w + CAP_GAP
        shown.reverse()
        return shown


def render_strip(caps, badge=None):
    """The STRIP_H rows under the picture, as raw RGB bytes.
    `badge` is None or (n, cycles): the xN cap and the cycle count."""
    cv = Canvas(FRAME_W, STRIP_H, STRIP_BG)
    if badge is not None:
        n, cycles = badge
        label = f'x{n}'
        count = f'{cycles:,}'
        right = FRAME_W - MARGIN
        # counter, right-aligned, "cyc" in the small size after it
        cyc_w = text_width(' cyc', 1)
        cnt_w = text_width(count)
        cx = right - cyc_w - cnt_w
        cv.text(cx, CAP_Y + 4, count, COUNT_FG)
        cv.text(right - cyc_w, CAP_Y + 12, ' cyc', COUNT_FG, 1)
        bx = cx - CAP_GAP - cap_width(label)
        cv.rect(bx, CAP_Y, cap_width(label), CAP_H, BADGE_BG)
        cv.text(bx + CAP_PAD, CAP_Y + 4, label, BADGE_FG)
    x = MARGIN
    for kind, text in caps:
        w = cap_width(text)
        bg, fg = ((SPECIAL_BG, SPECIAL_FG) if kind == 'special'
                  else (CAP_BG, CAP_FG))
        cv.rect(x, CAP_Y, w, CAP_H, bg)
        cv.text(x + CAP_PAD, CAP_Y + 4, text, fg)
        x += w + CAP_GAP
    return cv.bytes()


def badge_width(badge):
    """Pixels the badge takes from the right edge, from the badge itself
    (the counter grows a digit every decade of cycles, and xN has a
    variable width): the xN cap, the count, ' cyc', and the margin."""
    n, cycles = badge
    return (cap_width(f'x{n}') + CAP_GAP + text_width(f'{cycles:,}') +
            text_width(' cyc', 1) + MARGIN)


def keys_avail(badge):
    """Pixels the key caps may use: all the room, less the actual badge
    and one gap when there is one."""
    if badge is None:
        return FRAME_W - 2 * MARGIN
    return FRAME_W - MARGIN - badge_width(badge) - CAP_GAP


# -- the popover: the ONE overlay allowed over the Apple screen --------------
# The operator's exception (2026-10-20, docs/DEMO-FEDGREP.md, RECORDER.md
# item 4): a small bordered box in the lower right corner of the picture,
# for the last seconds of one demo. Everything else stays in the strip.

BOX_PAD = 8
BOX_BORDER = 2
BOX_MARGIN = 10
BOX_BG = (24, 24, 28)
BOX_FG = (236, 236, 236)
BOX_EDGE = (200, 138, 24)


def render_box(text, right=APPLE_X + SCREEN_W, bottom=APPLE_Y + SCREEN_H):
    """The popover as (x, y, w, h, raw RGB bytes), placed in the lower
    right corner of the display's picture, whose right and bottom edges
    are at `right`, `bottom` in the FRAME_W x PIC_H frame (the //e's by
    default; the card's picture as it is drawn). Raises demo_font.MissingGlyph for a character the font
    lacks, and ValueError for text that does not fit on the picture."""
    w = text_width(text) + 2 * (BOX_PAD + BOX_BORDER)
    h = 7 * SCALE + 2 * (BOX_PAD + BOX_BORDER)
    if not text or w > SCREEN_W // 2:
        raise ValueError(f'popover text {text!r}: empty or too wide')
    cv = Canvas(w, h, BOX_EDGE)
    cv.rect(BOX_BORDER, BOX_BORDER, w - 2 * BOX_BORDER,
            h - 2 * BOX_BORDER, BOX_BG)
    cv.text(BOX_BORDER + BOX_PAD, BOX_BORDER + BOX_PAD, text, BOX_FG,
            strict=True)
    return (right - BOX_MARGIN - w, bottom - BOX_MARGIN - h, w, h,
            cv.bytes())


def blit_box(rgb, box):
    """A copy of the FRAME_W x PIC_H picture `rgb` with the popover
    `box` (from render_box) drawn over it."""
    x, y, w, h, px = box
    out = bytearray(rgb)
    for r in range(h):
        o = ((y + r) * FRAME_W + x) * 3
        out[o:o + w * 3] = px[r * w * 3:(r + 1) * w * 3]
    return bytes(out)


def pad_picture(rgb, width=SCREEN_W, height=SCREEN_H):
    """A width x height display picture centred on the black
    FRAME_W x PIC_H frame picture (the //e's 560x384 get 80-pixel
    pillars and 24-pixel bands). Whole pixels, no scaling. A picture
    bigger than the frame is an error here; demo_ut.fit crops first."""
    if width > FRAME_W or height > PIC_H:
        raise ValueError(f'{width}x{height} does not fit the frame')
    if (width, height) == (FRAME_W, PIC_H):
        return rgb
    x0 = (FRAME_W - width) // 2
    y0 = (PIC_H - height) // 2
    out = bytearray(FRAME_W * PIC_H * 3)
    for y in range(height):
        o = ((y0 + y) * FRAME_W + x0) * 3
        out[o:o + width * 3] = rgb[y * width * 3:(y + 1) * width * 3]
    return bytes(out)


def blank_strip():
    return render_strip([], None)
