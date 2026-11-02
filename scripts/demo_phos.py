#!/usr/bin/env python3
"""demo_phos.py -- the monitor's tint, as a palette the films are
rendered through.

A maux film is filmed on one of two DISPLAYS (the //e's own 80-column
text, or the Videx UltraTerm, which has its own VRAM and its own monitor
output) and is shown on one of three PHOSPHORS. Those are different
axes: the display is the signal, the phosphor is the glass it lands on,
and the same UltraTerm signal on an amber monitor is a real machine
somebody owned.

WHAT IS AND IS NOT A HARDWARE CLAIM. Nothing here is one. The commons
has the UltraTerm's own manual (learning:01M0J3M2B5DJJ4A3YVX7RNFK6N)
and it names no phosphor: the card's two hardware requirements are a
slot and "a high-resolution video display monitor", full stop. Searched
2026-10-31 for monochrome phosphor chromaticities (P1/P3/P4) across the
commons and it is silent -- what is there is the //e's COLOUR table,
which is a different question. So these six values are a HOUSE
AESTHETIC, chosen to look like the three monitors that were on desks,
and they are not graded as fact because they are not findings. The
green was already this: demo_ut.py carried it as "the colour fast_sdl
draws the card in by default", which is an emulator's choice of tint,
not a measurement of a CRT.

TWO LEVELS, BECAUSE THE CARD HAS TWO. The UltraTerm's attribute
register gives a cell {font, inverse, highlight}, two such sets per
screen chosen by the cell's bit 7 (learning:01M06YDGM1Q52V5TXX3GA8A2FZ),
so its renderer emits three states per pixel: dark, normal and
highlight. The //e has no highlight attribute and emits two -- and
neither does the UltraTerm's own predecessor, whose video path is a
single bit (learning:01M4B4CPHT8QG39WV7QH0S48MF), so the second level
really is this one card's. Each phosphor therefore declares a PAIR, and
a display that never lights the second level never uses it.

HOW THE TINT IS APPLIED, and why it is a palette rather than a filter.
Both displays are strictly monochrome: measured on the shipped posters,
the //e's frame holds exactly two distinct colours and the card's
exactly two, over all 1440x864 pixels (the chrome included). A tint is
therefore an EXACT remap of at most three colours and never an
approximation of luminance -- there is nothing to approximate. So the
renderers draw in the canonical grey levels below and every output
colour comes from one `translate` per channel:

    out[0::3] = pic[0::3].translate(tr)     # and 1::3, 2::3

which is positional by construction (so no three-byte run can straddle
a pixel boundary and corrupt the row, which a `bytes.replace` of an RGB
triple can) and runs at C speed in six passes over the buffer.

The pictures are tinted once per CHANGED screen and the result cached,
so three phosphors cost neither three emulator passes nor three
renders: one pass feeds every encoder. That is cheap for a measured
reason rather than a hoped-for one -- in a 1,800-frame recording only
**8% of frames differ** from the one before
(learning:01M59F3YBYZYAYFHG6J9Y5K1VF), so ~92% of frames reuse a
tinted picture and pay nothing but the ffmpeg write they would pay
anyway. docs/DEMO-PHOSPHOR.md.
"""

# The canonical levels the renderers draw in. Any three values would
# do; these are greys so that an untinted picture (a gate dumping one,
# a debugging aid) is still legible as a picture. They must stay
# DISTINCT PER CHANNEL: the tint is three independent per-byte tables,
# so two levels that share a channel value could not be sent to
# different colours in it. (That is why this is not simply white and
# half-white: the card's highlight and normal both end up 0xFF in green
# and the green channel would have no way to tell them apart.)
OFF = (0x00, 0x00, 0x00)
LIT = (0x80, 0x80, 0x80)        # the card's normal cell; the //e's text
BRIGHT = (0xFF, 0xFF, 0xFF)     # the card's highlight attribute only

# name -> (normal, highlight). Each pair is stated outright rather than
# derived from the other by a rule: the three monitors do not share one.
# The NORMAL level is what the //e's text is drawn in, and what the
# card's ordinary cells are, so it is the colour the monitor is
# recognised by and never a dimmed version of one; the highlight is the
# card's attribute, above normal.
PHOSPHORS = {
    # P4-style white, warmed to the site's own `paper` token (#f8f4ea)
    # rather than pure white: a page and a film of the same machine
    # should not disagree about what white is. Its highlight has
    # nowhere to go but to real white, so the two levels are 7, 11 and
    # 21 apart -- visible side by side and no more than that, which is
    # the honest answer for a white monitor and part of why an
    # attribute-heavy terminal was nicer on green or amber glass.
    'paper': ((0xF8, 0xF4, 0xEA), (0xFF, 0xFF, 0xFF)),
    # P1 green. The normal level is EXACTLY what the films shipped
    # with, so this phosphor reproduces them pixel for pixel; the
    # highlight is that colour pulled halfway to white, which is the
    # rule demo_ut.py used.
    'green': ((0x40, 0xFF, 0x30), (0x9F, 0xFF, 0x97)),
    # P3-style amber.
    'amber': ((0xD8, 0x8A, 0x14), (0xFF, 0xC4, 0x62)),
}
# The order the site offers them in, and the order `make demos` records
# in. First is the default a page shows before anyone picks.
NAMES = ('paper', 'green', 'amber')
DEFAULT = NAMES[0]


class PhosError(Exception):
    """A picture was not in the canonical palette, so tinting it would
    silently corrupt it."""


def tables(name):
    """The three 256-byte `translate` tables for one phosphor: canonical
    level in, that monitor's channel value out."""
    normal, highlight = PHOSPHORS[name]
    out = []
    for ch in range(3):
        t = bytearray(256)
        t[OFF[ch]] = 0
        t[LIT[ch]] = normal[ch]
        t[BRIGHT[ch]] = highlight[ch]
        out.append(bytes(t))
    return tuple(out)


ALL_TABLES = {name: tables(name) for name in NAMES}
# Every byte a canonical picture may hold. A byte outside this set would
# be mapped to 0 by the tables above -- that is, silently blacked out --
# so the paths that build a picture assert against it instead.
CANON_BYTES = frozenset(OFF + LIT + BRIGHT)


def tint(pic, tabs):
    """`pic` (canonical RGB) as one monitor would show it."""
    out = bytearray(pic)
    out[0::3] = pic[0::3].translate(tabs[0])
    out[1::3] = pic[1::3].translate(tabs[1])
    out[2::3] = pic[2::3].translate(tabs[2])
    return bytes(out)


def canon_one_level(rgb, what='the picture'):
    """A two-colour black/white picture (what verilogapple's
    `screen_image` gives for the //e's text) in the canonical palette:
    its white becomes the NORMAL level, not the highlight, because the
    //e has no highlight attribute to draw with.

    Raises rather than guessing if anything else is in there. The //e's
    text video is black and white and the posters measure as exactly
    that, but a demo that reached a graphics mode, or an emulator that
    started shading, would otherwise be tinted by a table that maps
    every unknown byte to zero -- a picture quietly going black is the
    worst way to find out."""
    bad = set(rgb) - {0x00, 0xFF}
    if bad:
        raise PhosError(
            f'{what} is not black and white: {len(bad)} other byte '
            f'value(s), e.g. {sorted(bad)[:4]} -- a monochrome tint '
            f'cannot be applied to it')
    return rgb.translate(bytes(LIT[0] if b else 0 for b in range(256)))
