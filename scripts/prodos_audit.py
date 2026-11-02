#!/usr/bin/env python3
"""prodos_audit.py -- audit a ProDOS volume image from its raw bytes,
with NO code shared with a2til or with any image builder.

Why it exists (docs/FULLDISK.md sec 2, learning:01M0SF1D98YX95Z5HPXJPN14FR):
a tool-built image whose directory fields are wrong does not fail where
it was built. The builder reads back what it wrote, so every test it has
agrees with it. The disagreement surfaces against real ProDOS, as a
self-feeding READ/WRITE loop that looks like anything but the image. The
full disk is the first maux image where nobody had looked at those
fields at 65,535 blocks (a 16-block bitmap, a 3-level tree for the
biggest files), so this reader checks them from the spec.

What it checks, all from the bytes:
  * the volume header: storage type $F, entry length $27, 13 entries a
    block, bit_map_pointer 6, total_blocks, and a bitmap of the right
    number of blocks;
  * every directory block chain: prev/next pointers agree;
  * every directory header: file_count equals the entries counted;
    a subdirectory header's parent_pointer is the key block of the
    directory holding its entry, parent_entry_number is that entry's
    1-BASED slot in its block (the header is slot 1), and
    parent_entry_length is $27;
  * every file entry: header_pointer is the key block of the directory
    holding it; blocks_used equals the blocks actually reached from its
    key block (seedling, sapling and tree);
  * the bitmap against the walk: every block the walk reaches (boot,
    directory blocks, bitmap, indexes, data) is marked in use, and no
    block the walk did not reach is marked in use (a leak);
  * optionally, that blocks 0-1 equal a reference file's.
Returns a list of problems (empty = clean) so a gate can assert on it,
and prints a one-line summary from the command line.
"""
import struct
import sys

BLK = 512
ENT_LEN = 0x27
PER_BLK = 13


def u16(b, o):
    return b[o] | (b[o + 1] << 8)


def u24(b, o):
    return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16)


class Img:
    def __init__(self, data):
        self.d = data
        self.n = len(data) // BLK

    def blk(self, i):
        if not 0 <= i < self.n:
            raise IndexError(f'block {i} outside the {self.n}-block volume')
        return self.d[i * BLK:(i + 1) * BLK]


def audit(path, ref_boot=None):
    problems = []
    with open(path, 'rb') as f:
        data = f.read()
    if len(data) % BLK:
        return [f'{path}: size {len(data)} is not a multiple of {BLK}']
    im = Img(data)
    used = set([0, 1])                     # boot blocks
    vol = im.blk(2)
    if ref_boot is not None and data[:2 * BLK] != ref_boot:
        problems.append('blocks 0-1 differ from the reference boot blocks')
    if vol[4] >> 4 != 0xF:
        problems.append(f'volume header storage type ${vol[4] >> 4:X}, '
                        f'want $F')
        return problems
    if vol[0x23] != ENT_LEN or vol[0x24] != PER_BLK:
        problems.append(f'volume header entry_length/per_block '
                        f'{vol[0x23]}/{vol[0x24]}, want {ENT_LEN}/{PER_BLK}')
    total = u16(vol, 0x29)
    bitmap_ptr = u16(vol, 0x27)
    if total != im.n:
        problems.append(f'total_blocks {total}, file holds {im.n}')
    nbitmap = (total + 4095) // 4096
    if bitmap_ptr != 6:
        problems.append(f'bit_map_pointer {bitmap_ptr}, want 6')
    for b in range(bitmap_ptr, bitmap_ptr + nbitmap):
        used.add(b)

    def reach_file(storage, key, blocks_used, name):
        got = {key}
        if storage == 1:
            pass
        elif storage == 2:
            ib = im.blk(key)
            for i in range(256):
                p = ib[i] | (ib[256 + i] << 8)
                if p:
                    got.add(p)
        elif storage == 3:
            mb = im.blk(key)
            for i in range(128):
                ip = mb[i] | (mb[256 + i] << 8)
                if not ip:
                    continue
                got.add(ip)
                ib = im.blk(ip)
                for j in range(256):
                    p = ib[j] | (ib[256 + j] << 8)
                    if p:
                        got.add(p)
        else:
            problems.append(f'{name}: storage type ${storage:X} not audited')
            return
        if len(got) != blocks_used:
            problems.append(f'{name}: blocks_used {blocks_used}, '
                            f'{len(got)} reached from the key block')
        for g in got:
            if g in used:
                problems.append(f'{name}: block {g} is used twice')
            used.add(g)

    def walk_dir(key, path_name, parent_key=None, parent_slot=None):
        """Walk one directory's block chain."""
        count = 0
        prev = 0
        b = key
        first = True
        seen = set()
        while b:
            if b in seen:
                problems.append(f'{path_name}: directory chain loops at {b}')
                return None
            seen.add(b)
            if b in used:
                problems.append(f'{path_name}: dir block {b} used twice '
                                f'(a shared or overlapping directory)')
            used.add(b)
            blk = im.blk(b)
            if u16(blk, 0) != prev:
                problems.append(f'{path_name}: block {b} prev pointer '
                                f'{u16(blk, 0)}, want {prev}')
            for slot in range(1, PER_BLK + 1):
                o = 4 + (slot - 1) * ENT_LEN
                stype = blk[o] >> 4
                if first and slot == 1:
                    # the directory header
                    if parent_key is not None:
                        if stype != 0xE:
                            problems.append(f'{path_name}: header storage '
                                            f'${stype:X}, want $E')
                        if u16(blk, 0x27) != parent_key:
                            problems.append(
                                f'{path_name}: parent_pointer '
                                f'{u16(blk, 0x27)}, want {parent_key}')
                        if blk[0x29] != parent_slot:
                            problems.append(
                                f'{path_name}: parent_entry_number '
                                f'{blk[0x29]}, want {parent_slot} '
                                f'(1-based, header is 1)')
                        if blk[0x2A] != ENT_LEN:
                            problems.append(
                                f'{path_name}: parent_entry_length '
                                f'{blk[0x2A]}, want {ENT_LEN}')
                    hdr_count = u16(blk, 0x25)
                    continue
                if stype == 0:
                    continue
                if stype in (0xE, 0xF):
                    problems.append(f'{path_name}: slot {slot} holds a '
                                    f'directory-HEADER storage type '
                                    f'${stype:X}')
                    continue
                name = ''.join(chr(c & 0x7F) for c in
                               blk[o + 1:o + 1 + (blk[o] & 0xF)])
                full = f'{path_name.rstrip("/")}/{name}'
                count += 1
                key_ptr = u16(blk, o + 0x11)
                used_blocks = u16(blk, o + 0x13)
                hp = u16(blk, o + 0x25)
                if hp != key:
                    problems.append(f'{full}: header_pointer {hp}, want '
                                    f'{key}')
                if stype == 0xD:
                    nblk = walk_dir(key_ptr, full, parent_key=b,
                                    parent_slot=slot)
                    if nblk is not None and nblk != used_blocks:
                        problems.append(
                            f'{full}: blocks_used {used_blocks}, the '
                            f'directory chain holds {nblk}')
                elif stype in (1, 2, 3):
                    reach_file(stype, key_ptr, used_blocks, full)
                else:
                    problems.append(f'{full}: storage type ${stype:X} '
                                    f'not audited')
            prev = b
            first = False
            b = u16(blk, 2)
        if count != hdr_count:
            problems.append(f'{path_name}: file_count {hdr_count}, '
                            f'{count} entries counted')
        return len(seen)

    walk_dir(2, '/' + ''.join(chr(c & 0x7F) for c in
                              vol[5:5 + (vol[4] & 0xF)]))

    # the bitmap against the walk: set bit = FREE, MSB first
    bm = b''.join(im.blk(bitmap_ptr + i) for i in range(nbitmap))
    in_use = set()
    for blkno in range(total):
        if not bm[blkno >> 3] & (0x80 >> (blkno & 7)):
            in_use.add(blkno)
    # the bitmap's bits PAST the volume (block 65,535 of a 65,535-block
    # volume sits in the last bitmap block's final bit) must read "in
    # use" (0): a set bit is a block the volume does not have, offered
    # to the allocator
    ghosts = [blkno for blkno in range(total, nbitmap * 4096)
              if bm[blkno >> 3] & (0x80 >> (blkno & 7))]
    if ghosts:
        problems.append(f'{len(ghosts)} bitmap bits past the end of the '
                        f'volume are marked FREE, first {ghosts[:6]}')
    unmarked = sorted(used - in_use)
    leaked = sorted(in_use - used)
    if unmarked:
        problems.append(f'{len(unmarked)} reachable blocks are marked '
                        f'free in the bitmap, first {unmarked[:6]}')
    if leaked:
        problems.append(f'{len(leaked)} blocks are marked in use but '
                        f'unreachable (leak), first {leaked[:6]}')
    audit.last = {'total': total, 'used': len(used), 'free': total - len(used),
                  'bitmap_blocks': nbitmap}
    return problems


def selftest(path):
    """The audit's own teeth: corrupt a copy of `path` in memory three
    ways and require each to be reported. Returns a list of failures
    (empty = the audit can see all three). The mutations are the fields
    learning:01M0SF1D98YX95Z5HPXJPN14FR names: a subdirectory header's
    parent_entry_number, the bitmap against the walk, and file_count."""
    import os
    import tempfile
    with open(path, 'rb') as f:
        data = bytearray(f.read())
    out = []
    vol = 2 * BLK
    sub = None
    for slot in range(2, PER_BLK + 1):
        o = vol + 4 + (slot - 1) * ENT_LEN
        if data[o] >> 4 == 0xD:
            sub = u16(data, o + 0x11)
            break
    if sub is None:
        return ['selftest: no subdirectory in the volume directory']
    bitmap_ptr = u16(data, vol + 0x27)
    cases = []
    c = bytearray(data)
    c[sub * BLK + 0x29] -= 1
    cases.append(('parent_entry_number one early', c, 'parent_entry_number'))
    c = bytearray(data)
    n = u16(c, vol + 0x29)
    first_used = next(b for b in range(22, n)
                      if not c[bitmap_ptr * BLK + (b >> 3)] & (0x80 >> (b & 7)))
    c[bitmap_ptr * BLK + (first_used >> 3)] |= 0x80 >> (first_used & 7)
    cases.append(('a used block marked free', c, 'marked free'))
    c = bytearray(data)
    c[vol + 0x25] += 1
    cases.append(('volume file_count off by one', c, 'file_count'))
    # a directory entry whose blocks_used disagrees with its chain
    c = bytearray(data)
    for slot in range(2, PER_BLK + 1):
        o = vol + 4 + (slot - 1) * ENT_LEN
        if data[o] >> 4 == 0xD:
            c[o + 0x13] += 1
            break
    cases.append(('a directory blocks_used off by one', c,
                  'directory chain holds'))
    # a bitmap bit past the volume's end marked free
    c = bytearray(data)
    n = u16(c, vol + 0x29)
    if n % 4096:
        c[bitmap_ptr * BLK + (n >> 3)] |= 0x80 >> (n & 7)
        cases.append(('a bitmap bit past the volume marked free', c,
                      'past the end'))
    # two directories sharing one key block
    c = bytearray(data)
    subs = [vol + 4 + (sl - 1) * ENT_LEN for sl in range(2, PER_BLK + 1)
            if data[vol + 4 + (sl - 1) * ENT_LEN] >> 4 == 0xD]
    if len(subs) >= 2:
        c[subs[1] + 0x11:subs[1] + 0x13] = data[subs[0] + 0x11:subs[0] + 0x13]
        cases.append(('two directories sharing a key block', c,
                      'used twice'))
    for label, blob, want in cases:
        with tempfile.NamedTemporaryFile(delete=False, suffix='.po') as t:
            t.write(blob)
            name = t.name
        try:
            got = audit(name)
        finally:
            os.remove(name)
        if not any(want in p for p in got):
            out.append(f'selftest: audit missed {label} (got {got[:2]})')
    return out


if __name__ == '__main__':
    probs = audit(sys.argv[1])
    st = getattr(audit, 'last', {})
    if probs:
        print(f'[prodos_audit] {sys.argv[1]}: {len(probs)} problem(s)')
        for p in probs[:40]:
            print('  -', p)
        sys.exit(1)
    print(f'[prodos_audit] {sys.argv[1]}: clean -- {st.get("total")} '
          f'blocks, {st.get("used")} used, {st.get("free")} free, '
          f'{st.get("bitmap_blocks")} bitmap blocks')
