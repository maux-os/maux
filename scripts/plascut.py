#!/usr/bin/env python3
"""plascut.py -- the plasma cutter: cook a PLASMA program into ONE flat,
spawnable maux binary (docs/PLASCUT.md).

    plascut.py [-L DIR ...] [--seed build/plasma.bin] [--rt build/rt.mod]
               -o OUT.cut MODULE

Today `plasma NAS ...` spawns the 3 KB seed, which reads rt (8 KB) into
$2000, whose loadmod then reads, relocates and binds ARGS + FILEIO +
NAS (~19 KB of module files) onto the heap -- every launch, because
none of that is in the spawned image, so lazy free's no-copy warm
respawn (docs/STICKY.md sec 27) can only ever cover the seed. This
tool does loadmod's job ONCE, on the host, and writes the result as
the image: seed + rt + every module already relocated, every import
bound, every def thunk built, plus the small block the cooked rt init
needs (init thunks to call, the heap, the restore table). The kernel
spawns it like `ls`; a warm respawn copies nothing.

WHAT IS COOKED, EXACTLY (this is loadmod, src/plasma/rt.pla 1106-1274,
transcribed -- read that first; every rule below is one of its lines):

  * modules load in DEPENDENCY order, depth-first, each once; CMDSYS is
    rt itself, bound from rt's `exports` table (the cook block's
    `cookexports` pointer, rt.pla), exactly the addresses rt's own init
    registers with addsym;
  * per module: a def table of defcnt*5+1 bytes FIRST (defcnt counts
    the init), then the image (module file minus its header) at the
    next heap byte; modofst = (image addr - header length) - $2000;
  * RLD: $02 entries build `JSR $0806 / da addr` thunks in table order;
    $8x = 16-bit internal fixup (a target at or past the bytecode
    subsegment is replaced by its THUNK -- lookupdef); $4x = high byte
    with the carry from (entry byte 3 + modofst.lo); $0x = low byte;
    $1x = external: the word in place is an ADDEND, the bound export
    address is added to it;
  * ESD exports go into the symbol table (bytecode exports as their
    thunk), imports resolve by the RLD entry's ESD index (low byte);
  * the module's own name maps to its image address (loadmod's
    `addsym(mod, modaddr)`), which is how "already loaded" is decided;
  * the module init (header word 10) gets the LAST thunk in the def
    table and is NOT run -- it cannot be, on the host -- so it is kept
    (loadmod frees a non-modinitkeep init after running it; cooked, rt
    runs every init on every launch, in load order, and exits with the
    last one's return).

WHAT THE HOST CANNOT SEE, and how the cooked rt covers it: module
DATA is in the image and mutated by every run; a warm respawn gets the
dirtied bank back. So after the last module this tool appends a
RESTORE TABLE -- (dst, src, len) triples, 0-terminated -- and pristine
copies of every writable range: rt's [$2003, @symtbl) and each
module's data segment [image, bytecode). rt's cooked init memcpy's
them back before running any init (rt.pla). src/test/plasma/cookt.pla
is the fixture whose second warm launch proves the restore happened.

An explicit --immutable-native MODULE opts into a shorter restore range.
The module must export CKDATAEND at the first byte of an immutable native
suffix (a zero-byte `export asm ckdataend()#0` / `end` before the helpers).
The ESD supplies the boundary; no instruction bytes are scanned. Everything
from that boundary to bytecode must be immutable, including embedded data.
Mutable native code must precede the marker or leave this option disabled.
The author asserts immutability; the cooker verifies the local export and
range, not the absence of writes through arbitrary runtime pointers.

The output is BIN, load address $0800: stage it with
`prodos.write(..., file_type=0x06, aux_type=0x0800)` like any util.
The seed's CKFLAG/CKEND ($080B/$080C, plasma.s) and rt's cook block
(rt.pla, found by its 'CKPL' magic) are patched in the FILE only.
"""
import argparse
import re
import os
import struct
import sys

LOAD_BASE = 0x0800
RELADDR = 0x2000
WINDOW_TOP = 0xBF00
IINTRP = 0x0806
SEED_CK_OFF = 0x0809 - LOAD_BASE      # 'C','K', flag, end.lo, end.hi
COOK_MAGIC = bytes([0x43, 0x4B, 0x50, 0x4C])   # 'C','K','P','L'
COOK_FIELDS = ('cookinits', 'cookheap', 'cookrestore', 'cookargs',
               'cooksysflags', 'cookexports', 'cookdata', 'cookfn')

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class CookError(Exception):
    pass


def r16(b, i):
    return b[i] | (b[i + 1] << 8)


def dci(b, i):
    """Decode a DCI name at b[i]: high bit set on every char but the
    last. Returns (NAME, index past the name)."""
    s = ''
    while b[i] & 0x80:
        s += chr(b[i] & 0x7F)
        i += 1
    s += chr(b[i] & 0x7F)
    return s.upper(), i + 1


class Image:
    def __init__(self, seed, rt):
        self.buf = bytearray(WINDOW_TOP - LOAD_BASE)
        if seed[0] != 0x4C:
            raise CookError('seed does not start with JMP')
        if seed[SEED_CK_OFF:SEED_CK_OFF + 2] != b'CK':
            raise CookError('seed lacks the CK cooked header at $0809 '
                            '(rebuild build/plasma.bin)')
        if rt[0] != 0x4C:
            raise CookError('rt is not a flat -AOW image (no JMP at $2000)')
        if len(seed) > RELADDR - LOAD_BASE:
            raise CookError('seed overlaps $2000')
        self.buf[0:len(seed)] = seed
        self.buf[RELADDR - LOAD_BASE:RELADDR - LOAD_BASE + len(rt)] = rt
        self.heap = RELADDR + len(rt)
        self.rt_end = self.heap
        self.log = []

    def off(self, addr):
        return addr - LOAD_BASE

    def r8(self, a):
        return self.buf[self.off(a)]

    def r16(self, a):
        return r16(self.buf, self.off(a))

    def w8(self, a, v):
        self.buf[self.off(a)] = v & 0xFF

    def w16(self, a, v):
        self.buf[self.off(a)] = v & 0xFF
        self.buf[self.off(a) + 1] = (v >> 8) & 0xFF

    def alloc(self, n, what):
        addr = self.heap
        if addr + n > WINDOW_TOP:
            raise CookError(f'{what}: {n} bytes at ${addr:04X} would pass '
                            f'${WINDOW_TOP:04X}')
        self.heap += n
        self.log.append((addr, n, what))
        return addr

    def write(self, addr, data, what):
        a = self.alloc(len(data), what)
        assert a == addr
        self.buf[self.off(a):self.off(a) + len(data)] = data

    def pstr(self, a):
        n = self.r8(a)
        return bytes(self.buf[self.off(a) + 1:self.off(a) + 1 + n]).decode(
            'latin-1').upper()

    def find_cook_block(self):
        lo = self.off(RELADDR)
        hi = self.off(self.rt_end)
        hits = [i for i in range(lo, hi - 3)
                if self.buf[i:i + 4] == COOK_MAGIC]
        if len(hits) != 1:
            raise CookError(f'rt cook block magic found {len(hits)} times '
                            '(expected exactly 1 -- rebuild build/rt.mod)')
        base = hits[0] + LOAD_BASE + 4
        return {name: base + 2 * k for k, name in enumerate(COOK_FIELDS)}


class Cooker:
    def __init__(self, img, search, const_prefix=(), immutable_native=()):
        self.img = img
        self.search = search
        self.symtab = {}        # NAME -> bound address
        self.inits = []         # init thunk addresses, load order
        self.datasegs = []      # (addr, len) writable ranges
        self.sysflags = 0
        self.loaded = []
        self.const_prefix = {name.upper() for name in const_prefix}
        self.immutable_native = {name.upper() for name in immutable_native}
        self.cook = img.find_cook_block()
        if img.r16(self.cook['cookinits']) != 0:
            raise CookError('rt is already cooked (cookinits != 0)')
        # CMDSYS: rt's export table, exactly what rt's init registers.
        exports = img.r16(self.cook['cookexports'])
        p = exports
        n = 0
        while img.r16(p):
            name = img.pstr(img.r16(p))
            self.symtab[name] = img.r16(p + 2)
            p += 4
            n += 1
        if 'CMDSYS' not in self.symtab:
            raise CookError('rt export table has no CMDSYS entry')
        self.rt_data_end = img.r16(self.cook['cookdata'])
        self.datasegs.append((RELADDR + 3, self.rt_data_end - (RELADDR + 3),
                              'rt data'))

    def find_file(self, name):
        for d in self.search:
            for cand in (name.lower() + '.mod', name + '.mod', name.lower(),
                         name):
                p = os.path.join(d, cand)
                if os.path.exists(p):
                    return p
        raise CookError(f'module {name}: no file in {self.search}')

    def adddef(self, addr, deflast):
        img = self.img
        img.w8(deflast, 0x20)
        img.w16(deflast + 1, IINTRP)
        img.w16(deflast + 3, addr)
        img.w8(deflast + 5, 0)
        return deflast, deflast + 5

    def lookupdef(self, addr, deftbl):
        img = self.img
        p = deftbl
        while img.r8(p) == 0x20:
            if img.r16(p + 3) == addr:
                return p
            p += 5
        raise CookError(f'no def thunk for bytecode address ${addr:04X}')

    def loadmod(self, name):
        name = name.upper()
        if name in self.symtab:
            return
        img = self.img
        path = self.find_file(name)
        with open(path, 'rb') as f:
            b = f.read()
        modsize = r16(b, 0)
        if r16(b, 2) != 0x6502:
            raise CookError(f'{path}: not an EXTended module (no $6502)')
        sysflags = r16(b, 4)
        defofst = r16(b, 6)
        defcnt = r16(b, 8)
        init = r16(b, 10)
        deps = []
        p = 12
        while b[p]:
            d, p = dci(b, p)
            deps.append(d)
        hdrend = p + 1                     # loadmod's moddep + 1
        for d in deps:
            self.loadmod(d)
        deftbl = img.alloc(defcnt * 5 + 1, f'{name} deftbl ({defcnt} defs)')
        img.w8(deftbl, 0)
        deflast = deftbl
        hdrlen = hdrend - 2                # from _SEGBEGIN (file idx 2)
        imgsize = modsize - hdrlen
        if 2 + modsize > len(b):
            raise CookError(f'{path}: modsize {modsize} past EOF')
        modaddr = img.alloc(imgsize, f'{name} image')
        img.buf[img.off(modaddr):img.off(modaddr) + imgsize] = \
            b[hdrend:hdrend + imgsize]
        self.symtab[name] = modaddr
        modfix = modaddr - hdrlen
        modofst = modfix - RELADDR
        bytecode = defofst + modofst
        rld = 2 + modsize
        p = rld
        while b[p]:
            p += 4
        esd = p + 1
        # imports by index (low byte), for the extern fixups
        imports = {}
        exports = []
        q = esd
        while b[q]:
            sym, q = dci(b, q)
            flag = b[q]
            val = r16(b, q + 1)
            q += 3
            if flag & 0x10:
                imports[val & 0xFF] = sym
            if flag & 0x08:
                exports.append((sym, val))
        esdend = q + 1
        if esdend != len(b):
            raise CookError(f'{path}: ESD ends at {esdend}, file is {len(b)}')
        # def dictionary
        p = rld
        ndefs = 0
        while b[p] == 0x02:
            _, deflast = self.adddef(r16(b, p + 1) + modofst, deflast)
            ndefs += 1
            p += 4
        # relocation dictionary
        nfix = {'ext': 0, '16': 0, 'msb': 0, 'lsb': 0, 'thunk': 0}
        while b[p]:
            flag = b[p]
            addr = r16(b, p + 1) + modfix
            b3 = b[p + 3]
            if flag & 0x10:
                sym = imports.get(b3)
                if sym is None:
                    raise CookError(f'{name}: extern fixup with ESD index '
                                    f'{b3} has no import entry')
                if sym not in self.symtab:
                    raise CookError(f'{name}: unresolved import {sym}')
                img.w16(addr, img.r16(addr) + self.symtab[sym])
                nfix['ext'] += 1
            elif flag & 0x80:
                fixup = (img.r16(addr) + modofst) & 0xFFFF
                if fixup >= bytecode:
                    fixup = self.lookupdef(fixup, deftbl)
                    nfix['thunk'] += 1
                img.w16(addr, fixup)
                nfix['16'] += 1
            elif flag & 0x40:
                lo = b3 + (modofst & 0xFF)
                img.w8(addr, img.r8(addr) + (modofst >> 8) + (lo >> 8))
                nfix['msb'] += 1
            else:
                img.w8(addr, img.r8(addr) + (modofst & 0xFF))
                nfix['lsb'] += 1
            p += 4
        # exports
        for sym, val in exports:
            a = (val + modofst) & 0xFFFF
            if a >= bytecode:
                a = self.lookupdef(a, deftbl)
            self.symtab[sym] = a
        # init: the last thunk; kept, run by rt's cooked init
        if init:
            thunk, deflast = self.adddef(init + modofst, deflast)
            self.inits.append(thunk)
        if deflast != deftbl + (ndefs + (1 if init else 0)) * 5:
            raise CookError(f'{name}: def table holds {ndefs}+init but '
                            f'defcnt is {defcnt}')
        if ndefs + (1 if init else 0) != defcnt:
            raise CookError(f'{name}: defcnt {defcnt} != {ndefs} defs + init')
        self.sysflags |= sysflags
        data_start = modaddr
        data_end = bytecode
        what = f'{name} data'
        if name in self.const_prefix:
            # the module declares its CONSTANT tables first and marks
            # the first mutable global with CONST_MARK (4 bytes); only
            # the data from the mark on needs a pristine copy for the
            # warm respawn -- nas's tables were 3.4 KB copied twice
            # (2026-09-15), i.e. the cutter's heap
            seg = bytes(self.img.buf[self.img.off(modaddr):
                                     self.img.off(bytecode)])
            hits = [m.start() for m in re.finditer(re.escape(CONST_MARK),
                                                   seg)]
            if len(hits) != 1:
                raise CookError(f'{name}: --const-prefix needs exactly '
                                f'one CONST_MARK in its data, found '
                                f'{len(hits)}')
            data_start += hits[0]
            what += f' ({hits[0]} B of constant tables not copied)'
        if name in self.immutable_native:
            # Consult this module's ESD, not the global symbol table: an
            # identically named dependency export cannot authorize a cut.
            marks = [val + modofst for sym, val in exports
                     if sym == 'CKDATAEND']
            if len(marks) != 1:
                raise CookError(f'{name}: --immutable-native needs exactly '
                                'one local CKDATAEND export')
            data_end = marks[0]
            minimum = data_start + (len(CONST_MARK)
                                    if name in self.const_prefix else 0)
            if not minimum <= data_end < bytecode:
                raise CookError(f'{name}: CKDATAEND ${data_end:04X} outside '
                                f'restore boundary ${minimum:04X}..'
                                f'${bytecode - 1:04X}')
            what += f' ({bytecode - data_end} B of immutable native not copied)'
        if data_end > data_start:
            self.datasegs.append((data_start, data_end - data_start, what))
        self.loaded.append((name, path, deftbl, modaddr, bytecode,
                            modaddr + imgsize, init + modofst if init else 0,
                            nfix, len(exports), deps))

    def finish(self, main):
        img = self.img
        unused = self.immutable_native - {m[0] for m in self.loaded}
        if unused:
            raise CookError('--immutable-native modules not loaded: '
                            + ', '.join(sorted(unused)))
        # init list
        initlist = img.alloc(2 * len(self.inits) + 2, 'init thunk list')
        for k, t in enumerate(self.inits):
            img.w16(initlist + 2 * k, t)
        img.w16(initlist + 2 * len(self.inits), 0)
        # restore table + pristine copies. A pristine run of zeros is not
        # copied: its entry has src 0 and rt memsets it (PLASM-FIX: plasm's
        # data is more than half zeros, and every pristine byte is a byte
        # of the cooked program's heap). Only runs of ZERO_RUN or more
        # are worth an entry (6 bytes of table).
        pieces = []                 # (dst, src_or_None, n)
        for (dst, n, what) in self.datasegs:
            seg = bytes(img.buf[img.off(dst):img.off(dst) + n])
            i = 0
            while i < n:
                m = ZERO_RUN_RE.search(seg, i)
                z = m.start() if m else n
                if z > i:
                    pieces.append((dst + i, False, z - i))
                if m:
                    pieces.append((dst + z, None, m.end() - z))
                    i = m.end()
                else:
                    i = n
        table = img.alloc(6 * len(pieces) + 2, 'restore table')
        copies = []
        srcs = {}
        for k, (dst, copy, n) in enumerate(pieces):
            src = 0
            if copy is not None:
                src = img.alloc(n, 'pristine data')
                img.buf[img.off(src):img.off(src) + n] = \
                    img.buf[img.off(dst):img.off(dst) + n]
            img.w16(table + 6 * k, dst)
            img.w16(table + 6 * k + 2, src)
            img.w16(table + 6 * k + 4, n)
            srcs[dst] = src
        img.w16(table + 6 * len(pieces), 0)
        self.stat = (sum(n for _d, c, n in pieces if c is not None),
                     sum(n for _d, c, n in pieces if c is None))
        for (dst, n, what) in self.datasegs:
            copies.append((dst, srcs.get(dst, 0), n, what))
        cookheap = img.heap
        # patch rt's cook block
        img.w16(self.cook['cookinits'], initlist)
        img.w16(self.cook['cookheap'], cookheap)
        img.w16(self.cook['cookrestore'], table)
        # a cooked binary's own name is argv[0]: the command line starts
        # THERE, as on a stock PLASMA system (rt.pla buildcmdln)
        img.w16(self.cook['cookargs'], 0)
        img.w16(self.cook['cooksysflags'], self.sysflags)
        # patch the seed
        img.buf[SEED_CK_OFF + 2] = 1
        img.buf[SEED_CK_OFF + 3] = cookheap & 0xFF
        img.buf[SEED_CK_OFF + 4] = cookheap >> 8
        return cookheap, initlist, table, copies


ZERO_RUN = 12
ZERO_RUN_RE = re.compile(b'\\x00{%d,}' % ZERO_RUN)
CONST_MARK = bytes.fromhex('a55a3cc3')   # `word mutmark = $5AA5, $C33C`


def cook(main, search, seed_path, rt_path, out_path, verbose=True,
         const_prefix=(), immutable_native=()):
    with open(seed_path, 'rb') as f:
        seed = f.read()
    with open(rt_path, 'rb') as f:
        rt = f.read()
    img = Image(seed, rt)
    ck = Cooker(img, search, const_prefix, immutable_native)
    ck.loadmod(main)
    cookheap, initlist, table, copies = ck.finish(main)
    data = bytes(img.buf[:img.off(cookheap)])
    # Publish atomically: build/nas.cut is re-cooked by three image
    # builders (nas-librel, nas-selfmake, full-image) that the parallel
    # sweep runs in different lanes, and a reader that opens the file
    # while a truncating `open(.., 'wb')` is half-way through it cooks a
    # short image (the same hazard imglock.py closes for disk images).
    tmp = f'{out_path}.tmp.{os.getpid()}'
    with open(tmp, 'wb') as f:
        f.write(data)
    os.replace(tmp, out_path)
    if verbose:
        print(f'[plascut] {main}: {out_path} = {len(data)} bytes, '
              f'$0800-${cookheap:04X}; heap left '
              f'{WINDOW_TOP - cookheap} bytes')
        print(f'[plascut]   seed {len(seed)} B, rt {len(rt)} B '
              f'($2000-${img.rt_end:04X})')
        for (name, path, deftbl, modaddr, bytecode, end, init, nfix,
             nexp, deps) in ck.loaded:
            print(f'[plascut]   {name:8s} deftbl ${deftbl:04X} data '
                  f'${modaddr:04X}-${bytecode:04X} bytecode '
                  f'${bytecode:04X}-${end:04X} init ${init:04X} '
                  f'fixups {nfix} exports {nexp} deps {deps}')
        print(f'[plascut]   inits {[f"${t:04X}" for t in ck.inits]} at '
              f'${initlist:04X}; sysflags ${ck.sysflags:04X}')
        copied, zeroed = ck.stat
        print(f'[plascut]   restore table ${table:04X}: '
              + ', '.join(f'{w} {n} B' for _, _, n, w in copies)
              + f' = {copied} B of pristine copies + {zeroed} B zero-filled')
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('module', help='main module name (e.g. NAS)')
    ap.add_argument('-o', '--out', required=True)
    ap.add_argument('-L', '--libdir', action='append', default=[],
                    help='module search dir (default build/)')
    ap.add_argument('--seed', default=os.path.join(ROOT, 'build',
                                                   'plasma.bin'))
    ap.add_argument('--rt', default=os.path.join(ROOT, 'build', 'rt.mod'))
    ap.add_argument('-q', '--quiet', action='store_true')
    ap.add_argument('--const-prefix', action='append', default=[],
                    metavar='MODULE',
                    help='MODULE declares its constant tables first and '
                         'marks the first mutable global with `word '
                         'mutmark = $5AA5, $C33C`: no pristine copy of '
                         'the tables (heap for the cooked program)')
    ap.add_argument('--immutable-native', action='append', default=[],
                    metavar='MODULE',
                    help='MODULE asserts that [export CKDATAEND, bytecode) '
                         'is immutable native text/data: omit its pristine '
                         'copy; requires a module-local boundary export')
    a = ap.parse_args(argv)
    search = a.libdir or [os.path.join(ROOT, 'build')]
    try:
        return cook(a.module, search, a.seed, a.rt, a.out,
                    verbose=not a.quiet, const_prefix=a.const_prefix,
                    immutable_native=a.immutable_native)
    except CookError as e:
        print(f'plascut: {e}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
