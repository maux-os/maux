#!/usr/bin/env python3
"""demo_png.py -- stdlib PNG decode and encode for the demo recorder.

Why this exists (docs/RECORDER.md): the recorder reads the 560x384 PNGs
verilogapple's `screen_image` writes, composites its overlays into the
raw pixels, and pipes rawvideo to ffmpeg. The box that runs the sweep
has no Pillow and no ffmpeg, so the decode is zlib plus the five PNG
row filters, and nothing else.

verilogapple writes filter type 0 on every row and a stored (BTYPE=00)
zlib stream (sim/mcp/mcp_server.cpp write_png), so the fast path is a
slice copy. The other four filters are here because a PNG is not
allowed to assume the writer, and the decoder is the half that has to
be right the day verilogapple changes its writer. They are gated by
scripts/check_recorder.py against an INDEPENDENT encoder written there
(a round trip through a forward filter sharing this file's predictor
would let a wrong predictor cancel itself out), and UNFILTERS is a module-level
dict on purpose: that check breaks one entry at a time and requires
the round trip to go red (docs/RECORDER.md "Rows").

Only 8-bit RGB (colour type 2), non-interlaced, is accepted; anything
else raises ValueError naming what it saw.
"""
import struct
import zlib

SIGNATURE = b'\x89PNG\r\n\x1a\n'
BPP = 3                     # bytes per pixel, 8-bit RGB


def chunks(data):
    """Yield (type, payload) for every chunk of a PNG byte string,
    checking the signature and every chunk CRC, and requiring IEND.
    Anything malformed is a ValueError (never a struct.error)."""
    if data[:8] != SIGNATURE:
        raise ValueError('not a PNG (bad signature)')
    pos = 8
    while pos < len(data):
        if pos + 12 > len(data):
            raise ValueError('truncated PNG chunk')
        n, = struct.unpack('>I', data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        end = pos + 8 + n
        if end + 4 > len(data):
            raise ValueError(f'truncated PNG chunk {kind!r} '
                             f'(length {n} runs past the data)')
        body = data[pos + 8:end]
        crc, = struct.unpack('>I', data[end:end + 4])
        if zlib.crc32(kind + body) != crc:
            raise ValueError(f'bad PNG chunk {kind!r} (CRC mismatch)')
        yield kind, body
        pos = end + 4
        if kind == b'IEND':
            return
    raise ValueError('PNG has no IEND chunk (truncated)')


# -- the five row filters, reversed (PNG spec sec 9.2) ---------------------

def _unfilter_none(cur, prev):
    return bytearray(cur)


def _unfilter_sub(cur, prev):
    out = bytearray(cur)
    for i in range(BPP, len(out)):
        out[i] = (out[i] + out[i - BPP]) & 255
    return out


def _unfilter_up(cur, prev):
    return bytearray((c + p) & 255 for c, p in zip(cur, prev))


def _unfilter_avg(cur, prev):
    out = bytearray(cur)
    for i in range(len(out)):
        left = out[i - BPP] if i >= BPP else 0
        out[i] = (out[i] + ((left + prev[i]) >> 1)) & 255
    return out


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def _unfilter_paeth(cur, prev):
    out = bytearray(cur)
    for i in range(len(out)):
        a = out[i - BPP] if i >= BPP else 0
        c = prev[i - BPP] if i >= BPP else 0
        out[i] = (out[i] + _paeth(a, prev[i], c)) & 255
    return out


UNFILTERS = {
    0: _unfilter_none,
    1: _unfilter_sub,
    2: _unfilter_up,
    3: _unfilter_avg,
    4: _unfilter_paeth,
}


def decode_rgb(data):
    """Decode an 8-bit RGB PNG. Returns (width, height, rgb_bytes)."""
    width = height = None
    idat = []
    for kind, body in chunks(data):
        if kind == b'IHDR':
            if len(body) != 13:
                raise ValueError(f'IHDR is {len(body)} bytes, wanted 13')
            width, height, depth, ctype, comp, filt, interlace = \
                struct.unpack('>IIBBBBB', body)
            if (depth, ctype, interlace) != (8, 2, 0):
                raise ValueError(
                    f'only 8-bit RGB non-interlaced PNG is supported '
                    f'(depth={depth} colour type={ctype} '
                    f'interlace={interlace})')
            if comp != 0 or filt != 0:
                raise ValueError(
                    f'IHDR compression method {comp} / filter method '
                    f'{filt}: only 0 and 0 exist')
        elif kind == b'IDAT':
            idat.append(body)
    if width is None or not idat:
        raise ValueError('PNG has no IHDR or no IDAT')
    try:
        raw = zlib.decompress(b''.join(idat))
    except zlib.error as e:
        raise ValueError(f'PNG image data does not inflate: {e}')
    stride = width * BPP
    if len(raw) != height * (stride + 1):
        raise ValueError(f'PNG data is {len(raw)} bytes, wanted '
                         f'{height * (stride + 1)}')
    out = bytearray()
    prev = bytes(stride)
    for y in range(height):
        base = y * (stride + 1)
        ftype = raw[base]
        cur = raw[base + 1:base + 1 + stride]
        if ftype not in UNFILTERS:
            raise ValueError(f'PNG row {y}: unknown filter type {ftype}')
        row = UNFILTERS[ftype](cur, prev)
        out += row
        prev = row
    return width, height, bytes(out)


# -- encoder -------------------------------------------------------------

def _chunk(kind, body):
    return (struct.pack('>I', len(body)) + kind + body +
            struct.pack('>I', zlib.crc32(kind + body)))


def encode_rgb(width, height, rgb, level=6):
    """Encode raw 8-bit RGB as a PNG, every row filter type 0 (the
    poster; nothing here needs the other four)."""
    stride = width * BPP
    if len(rgb) != stride * height:
        raise ValueError('rgb length does not match width*height*3')
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        rows += rgb[y * stride:(y + 1) * stride]
    ihdr = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    return (SIGNATURE + _chunk(b'IHDR', ihdr) +
            _chunk(b'IDAT', zlib.compress(bytes(rows), level)) +
            _chunk(b'IEND', b''))


def upscale(width, height, rgb, factor):
    """Nearest-neighbour integer upscale of raw RGB."""
    stride = width * BPP
    out = bytearray()
    for y in range(height):
        row = rgb[y * stride:(y + 1) * stride]
        wide = b''.join(row[x:x + BPP] * factor
                        for x in range(0, stride, BPP))
        out += wide * factor
    return width * factor, height * factor, bytes(out)
