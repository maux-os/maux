#!/usr/bin/env python3
"""casedir.py -- raw ProDOS directory reader for the GS/OS case-flag work
(docs/PRODOS-CASE.md).  Reads a block-ordered (.po) image directly, so it
reports what is ON DISK: the stored upper-case name, the 16-bit word at
entry +$1C (version / min_version / GS/OS case mask), and for a
subdirectory the mask in its OWN header (+$16 of the header = $1A of the
key block).  a2til's scandir hands back decoded names only, which cannot
tell "no flags" ($0024 stamp) from "flags present".

    python3 scripts/casedir.py IMG /PATH      # dump one directory
    entries(img_bytes, '/mnt/MAUX/SRC')          # library use

ASCII only.  Not a gate by itself; check_ls.py and the probes import it.
"""
import sys

import vpath

BLK = 512


def _blk(img, n):
    return img[n * BLK:(n + 1) * BLK]


def decode(stored, word):
    """Apply a GS/OS case word to a stored upper-case name (bytes)."""
    name = stored.decode('ascii')
    if not word & 0x8000:
        return name
    out = []
    bit = 0x4000
    for ch in name:
        out.append(ch.lower() if (word & bit and ch.isalpha()) else ch)
        bit >>= 1
    return ''.join(out)


def mask_for(typed):
    """The word maux must write for the typed last component, or 0 when
    the name has no lowercase letter (no write at all)."""
    mask, bit, any_lower = 0x8000, 0x4000, False
    for ch in typed:
        if 'a' <= ch <= 'z':
            mask |= bit
            any_lower = True
        bit >>= 1
    return mask if any_lower else 0


def dir_blocks(img, key):
    n = key
    seen = []
    while n and n not in seen:
        seen.append(n)
        b = _blk(img, n)
        n = b[2] | (b[3] << 8)
    return seen


def entries(img, path):
    """List the active entries of directory `path` ('/VOL/SUB/...').
    Each: dict(name, stored, word, ver, minver, stype, key, blk, idx,
    hdrword) -- hdrword is the subdirectory's own header mask (None for a
    file)."""
    comps = [c for c in vpath.phys(path).split('/') if c]
    key = 2
    for comp in comps[1:]:
        hit = [e for e in _scan(img, key) if e['stored'].decode() == comp.upper()]
        if not hit:
            raise FileNotFoundError(path)
        key = hit[0]['key']
    return _scan(img, key)


def _scan(img, key):
    out = []
    for bn in dir_blocks(img, key):
        b = _blk(img, bn)
        for i in range(13):
            if bn == key and i == 0:
                continue
            off = 4 + i * 0x27
            e = b[off:off + 0x27]
            st = e[0] >> 4
            if st == 0:
                continue
            ln = e[0] & 0x0F
            stored = bytes(e[1:1 + ln])
            word = e[0x1C] | (e[0x1D] << 8)
            ent = dict(stored=stored, word=word, ver=e[0x1C], minver=e[0x1D],
                       stype=st, key=e[0x11] | (e[0x12] << 8),
                       blk=bn, idx=i, off=off, hdrword=None,
                       eof=e[0x15] | (e[0x16] << 8) | (e[0x17] << 16),
                       acc=e[0x1E], ftype=e[0x10],
                       mod=bytes(e[0x21:0x25]),
                       name=decode(stored, word))
            if st == 0x0D:
                kb = _blk(img, ent['key'])
                ent['hdrword'] = kb[0x1A] | (kb[0x1B] << 8)
            out.append(ent)
    return out


def find(img, path):
    d, _, leaf = path.rstrip('/').rpartition('/')
    for e in entries(img, d or '/'):
        if e['stored'].decode() == leaf.upper():
            return e
    return None


def main():
    img = open(sys.argv[1], 'rb').read()
    for e in entries(img, sys.argv[2]):
        hw = '' if e['hdrword'] is None else ' hdr=$%04X' % e['hdrword']
        print('%-16s stored=%-15s word=$%04X st=%X ty=$%02X acc=$%02X '
              'eof=%d mod=%s blk=%d%s' %
              (e['name'], e['stored'].decode(), e['word'], e['stype'],
               e['ftype'], e['acc'], e['eof'], e['mod'].hex(), e['blk'], hw))


if __name__ == '__main__':
    main()
