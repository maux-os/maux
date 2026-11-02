#!/usr/bin/env python3
"""demo_ut.py -- a host-side picture of the Videx UltraTerm, for the recorder.

verilogapple's `screen_image` draws the motherboard video only, and the
card has its own VRAM, its own character generator and its own monitor
output (docs/RECORDER.md "Out of scope", now lifted by docs/DEMO-UT.md).
This module turns what the MCP tool `ultraterm_state` returns -- the
CRTC register file, the $C0B2/$C0B3 latches and the raw 4 KB of VRAM
(`addr=0, count=4096`) -- into the picture the card's monitor would show.

It is a stdlib port of the card model's own renderer
(verilogapple sim/ultraterm/ultraterm.h `render()`, the one fast_sdl
--ut-v3 draws), so a frame here is checked against fast_sdl pixel for
pixel (docs/DEMO-UT-NOTES.md sec 3). What it reads, and from where:

  geometry    R1 columns, R6 rows, R9 scan lines per cell - 1; each cell
              is 9 dots wide (the card's dot clock gives a 64 us line only
              with nine: MAME set_char_width(9); the character ROM holds
              eight dots and bit 0 is repeated as the ninth), so 80
              columns are 720 dots. The glyph's scan line is the raster
              within the row, RA & $0F, whatever R9 says. R8 bits 1:0 = 11
              is interlace sync+video, where the 6845 is programmed with
              R9 = RN-2: a row is R9+2 rasters of the frame, each glyph
              row drawn once (learning:01M5F6TG7F4X3C1C1VNXZBTST8).
              Nothing here papers over a driver's choice: a driver that
              programs R9=$0F gets 16-line cells with the glyph (7 or 9
              lines tall) at the top of each.
  start       R12/R13 display start (the card scrolls by moving it)
  cursor      R14/R15 address, R10 bits 6:5 mode (00 steady, 01 none,
              10 blink at 1/16 and 11 at 1/32 of the field rate),
              R10/R11 low five bits the first and last scan line
  font        $C0B3 bit 2, INVERTED: set = the standard set (ROM $000),
              clear = the dense "high-quality" set ($800)
              (learning:01M0J3YRZ8A7Y9B4FMED3XFS58)
  attributes  $C0B3 is the CHARACTER ATTRIBUTE REGISTER, not "bit 7 =
              inverse": a cell's bit 7 picks one of TWO attribute sets,
              each {inverse, highlight}. Bit 7 of the latch set = the DIP
              switches' factory look (bit-7 cells inverse, no highlight);
              clear = b5/b4 for cells with bit 7 set and b1/b0 for the
              rest (learning:01M06YDGM1Q52V5TXX3GA8A2FZ). maux programs
              $20 (bit-7 cells inverse) and, for a pager, $10 (bit-7
              cells bright).

Two card revisions exist and the renderer follows the one present
(REVISIONS below). The films show the ORIGINAL card, v1: firmware frm_b537
plus character generator chs_7859, whose format-4 entry is interlaced
with 16-raster rows and a tall set at ROM $800
(learning:01M5F6TG7F4X3C1C1VNXZBTST8, learning:01M0J3YRZ8A7Y9B4FMED3XFS58).
The updated card, v3 (frm_b5c9 and chs_5604: a 9-raster row and a short
set), stays supported. The geometry always comes from the live CRTC; the
revision chooses the character ROM and the firmware the MCP instance is
started with, nothing else. verilogapple's MCP installs the card firmware
named by the environment variable VERILOGAPPLE_ULTRATERM_FW (default v3),
which is how a recording asks for v1 without touching verilogapple
(mcp_env).

The character generators are read from verilogapple's ROM directory at run
time (ultraterm/chargen_vN.bin); they are another company's ROMs and are
not copied into this tree.

Colour: the card is monochrome and the tint is the MONITOR's, which is
a separate axis from the display, so this module draws neither green nor
white. It draws the canonical levels of scripts/demo_phos.py -- dark,
normal, highlight -- and the recorder remaps them to whichever of the
three phosphors (paper, green, amber) it is encoding. Three states and
not two because the card's attribute register gives a cell
{inverse, highlight} and the //e has no such attribute. The green the
films shipped with is demo_phos.PHOSPHORS['green'], unchanged, so it
reproduces them pixel for pixel.
"""
import hashlib
import zlib
import os

import demo_phos
from mcp_drive import ROMS_DIR

CELL_W = 9                      # the card's dot cell; the model draws 8
ROM_CELL_H = 16                 # bytes per glyph in the character ROM
VRAM_SIZE = 4096
# The levels a glyph is drawn in; the monitor's tint is applied later,
# by the recorder, from the same module. demo_phos.py says why.
LIT = demo_phos.LIT             # a normal cell, and all of the //e's text
BRIGHT = demo_phos.BRIGHT       # the card's highlight attribute


class Revision:
    """One UltraTerm revision: its character generator and firmware, each
    pinned by sha256 and by the MAME romset CRC32."""

    def __init__(self, name, card, chargen, chargen_sha, chargen_crc,
                 mame_chr, firmware, firmware_sha, firmware_crc, mame_frm):
        self.name, self.card = name, card
        self.chargen, self.chargen_sha = chargen, chargen_sha
        self.chargen_crc, self.mame_chr = chargen_crc, mame_chr
        self.firmware, self.firmware_sha = firmware, firmware_sha
        self.firmware_crc, self.mame_frm = firmware_crc, mame_frm

    def chargen_path(self):
        return os.path.join(ROMS_DIR, 'ultraterm', self.chargen)

    def firmware_path(self):
        return os.path.join(ROMS_DIR, 'ultraterm', self.firmware)


REVISIONS = {
    # the ORIGINAL card, the one the operator owns
    'v1': Revision(
        'v1', 'original', 'chargen_v1.bin',
        'd9c3108abb2a21a3807deb992af62c963891f18938f1da945e536f82e4676651',
        0xebe8f333, 'chs_7859', 'firmware_v1.bin',
        '8c9888dbc0c5dc8d51493e3f192a09415216ccb96d99e9d94ea29c58dec643e0',
        0x1e85a93e, 'frm_b537'),
    # the UPDATED card (the enhanced-//e kit)
    'v3': Revision(
        'v3', 'updated', 'chargen_v3.bin',
        'cbbfd3d07be729795d2b5a2bcdb1f1daf01af945f2f80430a5666bb7f0fedcd0',
        0x3fb4e90a, 'chs_5604', 'firmware_v3.bin',
        'cb17d747d3370723df02504f94bcf72aae9ef6d7419dc1e2edeb2cccfedf4024',
        0xb71e05e0, 'frm_b5c9'),
}
DEFAULT_REVISION = 'v1'
FMT4_OFFSET = 0xF55             # the firmware's format-4 CRTC entry (R0-R11)


class UTError(Exception):
    """The card cannot be drawn: not installed, not driving the monitor,
    or a geometry that does not fit the frame."""


def revision(name=None):
    """The revision to film: `name`, else $MAUX_UT_REV, else v1."""
    if isinstance(name, Revision):
        return name
    name = name or os.environ.get('MAUX_UT_REV') or DEFAULT_REVISION
    if name not in REVISIONS:
        raise UTError(f'UltraTerm revision {name!r}: wanted one of '
                      f'{sorted(REVISIONS)}')
    return REVISIONS[name]


def _read_pinned(path, sha, crc, what):
    try:
        with open(path, 'rb') as f:
            rom = f.read()
    except OSError as e:
        raise UTError(f'UltraTerm {what} {path}: {e}')
    if len(rom) != 4096:
        raise UTError(f'{path}: {len(rom)} bytes, wanted 4096')
    got = hashlib.sha256(rom).hexdigest()
    if got != sha or zlib.crc32(rom) != crc:
        raise UTError(f'{path}: sha256 {got} crc32 {zlib.crc32(rom):08x}, '
                      f'wanted {what}: sha256 {sha} crc32 {crc:08x}; a '
                      f'different ROM would draw different glyphs and the '
                      f'read-back rows would pass on the wrong ones')
    return rom


def load_chargen(rev=None, path=None):
    """The pinned character generator of revision `rev` (a name or a
    Revision; default per revision()); `path` overrides the file."""
    rev = revision(rev)
    return _read_pinned(path or rev.chargen_path(), rev.chargen_sha,
                        rev.chargen_crc,
                        f'the {rev.card} card\'s character ROM '
                        f'(MAME {rev.mame_chr})')


def load_firmware(rev=None):
    rev = revision(rev)
    return _read_pinned(rev.firmware_path(), rev.firmware_sha,
                        rev.firmware_crc,
                        f'the {rev.card} card\'s firmware '
                        f'(MAME {rev.mame_frm})')


def mcp_env(env, rev=None):
    """`env` (a dict) plus the variable that makes verilogapple's MCP
    install revision `rev`'s card firmware. The pinned file is read
    here, so a wrong or missing ROM fails before the emulator starts."""
    rev = revision(rev)
    load_firmware(rev)
    return dict(env, VERILOGAPPLE_ULTRATERM_FW=rev.firmware_path())


def format4_entry(rev=None):
    """R0-R11 of the firmware's format-4 (80x24 high quality) entry: the
    CRTC values a maux that copies the card's own entry programs."""
    fw = load_firmware(rev)
    return list(fw[FMT4_OFFSET:FMT4_OFFSET + 12])


def check_programmed(st, rev=None):
    """Raise UTError unless the CRTC in `st` holds revision `rev`'s
    format-4 R0-R9 (R10/R11 are the cursor, which a driver sets): the
    card revision the guest ran on is the one being drawn. A v3 table
    on a v1 card, or the reverse, would film the wrong cell."""
    rev = revision(rev)
    want = format4_entry(rev)[:10]
    got = list(st['crtc'][:10])
    if got != want:
        raise UTError(
            f'the CRTC is not the {rev.card} card\'s ({rev.name}) '
            f'format-4 entry: R0-R9 {bytes(got).hex()}, wanted '
            f'{bytes(want).hex()}; the guest ran on a different card '
            f'revision from the one being drawn')


# one glyph row -> RGB, per (dot byte, lit value, cell width)
_ROWS = {}


def _row_rgb(bits, lit, cell_w=CELL_W):
    key = (bits, lit, cell_w)
    got = _ROWS.get(key)
    if got is None:
        on = bytes(LIT if lit == 1 else BRIGHT)
        off = b'\0\0\0'
        dots = [(bits >> (7 - i)) & 1 for i in range(8)]
        if cell_w == 9:
            dots.append(bits & 1)       # bit 0 repeated as the ninth dot
        got = b''.join(on if d else off for d in dots)
        _ROWS[key] = got
    return got


def geometry(st):
    """(cols, rows, rasters per row, interlaced) from a ultraterm_state
    reply; interlace sync+video programs R9 = RN-2, so a row is R9+2."""
    crtc = st['crtc']
    il = (crtc[8] & 3) == 3
    return (crtc[1], crtc[6], crtc[9] + (2 if il else 1), il)


def cursor_visible(st, field):
    """Whether the 6845 cursor is lit in video field `field` (60 per
    emulated second). R10 bits 6:5: 00 steady, 01 not displayed, 10
    blinks at 1/16 of the field rate, 11 at 1/32."""
    mode = (st['crtc'][10] >> 5) & 3
    if mode == 0:
        return True
    if mode == 1:
        return False
    period = 16 if mode == 2 else 32
    return (field // (period // 2)) % 2 == 0


def attrs(reg_b3, code):
    """(inverse, highlight) for a cell, per the attribute register."""
    alt = bool(code & 0x80)
    if reg_b3 & 0x80:
        return alt, False
    if alt:
        return bool(reg_b3 & 0x20), bool(reg_b3 & 0x10)
    return bool(reg_b3 & 0x02), bool(reg_b3 & 0x01)


def render_native(st, vram, rom, cursor_lit=True, model=False):
    """The card's picture at native resolution: (w, h, RGB bytes).
    `st` is the ultraterm_state reply, `vram` the 4096 VRAM bytes.
    model=True draws what verilogapple's own renderer draws instead (8-dot
    cells, interlace as a 2x scale, no RA wrap): the comparison the
    fidelity tool makes against the card model."""
    cols, rows, ch, il = geometry(st)
    cell_w = 8 if model else CELL_W
    if model:
        ch = st['crtc'][9] + 1
    if not st.get('installed') or cols <= 0 or rows <= 0 or ch <= 0:
        raise UTError(f'the card is not drawing: cols={cols} rows={rows} '
                      f'cell_h={ch}')
    crtc = st['crtc']
    base = st['charset_base']
    start = ((crtc[12] & 0x3F) << 8 | crtc[13]) & (VRAM_SIZE - 1)
    cur = ((crtc[14] & 0x3F) << 8 | crtc[15]) & (VRAM_SIZE - 1)
    cs, ce = crtc[10] & 0x1F, crtc[11] & 0x1F
    cur_on = cursor_lit and ((crtc[10] >> 5) & 3) != 1
    b3 = st['reg_b3']
    hout = 2 * ch if (model and il) else ch
    w, h = cols * cell_w, rows * hout
    out = bytearray()
    for row in range(rows):
        cells = []
        for col in range(cols):
            addr = (start + row * cols + col) & (VRAM_SIZE - 1)
            code = vram[addr]
            inv, hl = attrs(b3, code)
            cells.append((base + (code & 0x7F) * ROM_CELL_H, inv,
                          1 + int(hl), cur_on and addr == cur))
        for so in range(hout):
            sl = so // 2 if (model and il) else so
            line = []
            for glyph, inv, lit, is_cur in cells:
                if model:
                    bits = rom[glyph + sl] if sl < ROM_CELL_H else 0
                else:
                    bits = rom[glyph + (sl & 0x0F)]
                if (is_cur and cs <= sl <= ce) ^ inv:
                    bits ^= 0xFF
                line.append(_row_rgb(bits, lit, cell_w))
            out += b''.join(line)
    return w, h, bytes(out)


def state_key(st, vram, lit):
    """Everything the picture depends on, hashable, so a recorder can
    skip re-rendering a repeated frame."""
    return (tuple(st['crtc']), st['reg_b3'], st['charset_base'], lit,
            bytes(vram))


FIT_W, FIT_H = 720, 432      # == demo_overlay.FRAME_W, PIC_H (a row checks)


def fit(w, h, rgb, frame_w=FIT_W, frame_h=FIT_H):
    """A native card picture as the frame's picture area takes it: every
    scan line doubled when that fits (the firmware's 80x24 at R9=8 is
    720x216 and becomes 720x432, the way the //e's 192 lines become 384),
    as it is when it does not (the ORIGINAL card's interlaced 80x24 is
    24 rows of 16 rasters, 720x384, which sits centred with 24-pixel
    black bands), and cropped to the top left corner when it is bigger
    than the area (a 132-column card format, say). Only whole pixels are
    ever scaled: the encoder doubles the finished frame by pixel
    replication, so every dot of either picture becomes an even 2x2
    block (no column is dropped or doubled unevenly, which a fractional
    fit of 384 to 432 lines would do). Returns (w, h, rgb); never
    raises."""
    if 2 * h <= frame_h:
        out = bytearray()
        for y in range(h):
            row = rgb[y * w * 3:(y + 1) * w * 3]
            out += row + row
        h, rgb = 2 * h, bytes(out)
    if w > frame_w or h > frame_h:
        cw, ch = min(w, frame_w), min(h, frame_h)
        rgb = b''.join(rgb[y * w * 3:y * w * 3 + cw * 3] for y in range(ch))
        w, h = cw, ch
    return w, h, rgb
