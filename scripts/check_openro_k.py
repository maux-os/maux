#!/usr/bin/env python3
"""check_openro_k.py -- the read-intent open, kernel side
(`make check-openro-k`; docs/OPEN-RO-2.md, docs/OPEN-RO-2-NOTES.md).

check_openro.py drives the shell; THIS file drives the kernel with a
generated probe program (the check_iobuf.py shape: $FF00 ABI, result
cells in the probe's own bank, the harness peeking OFT/lending tables
by symbol from the image's own listing).  Modes:

  fork   the parent opens G twice with read intent (fd 3, fd 4 -- one
         ProDOS file, two marks), reads fd 3 once, forks.  The child
         reads fd 4 then fd 3 and reports what it saw through its exit
         status.  After the wait the parent reads fd 3 then fd 4.
         Expect: child fd4='a' (its own mark 0), child fd3='b' (the
         PARENT's read already moved this description to 1); parent
         fd3='c' (the child's read moved it to 2), fd4='b' (the
         child's fd4 read moved that one to 1).  Marks per OFT entry,
         shared across the fork, independent between the entries.
  fork2  as fork, but the child reads ONLY fd 4 (twice, 'a' then 'b').
         Expect: the parent's fd 3 mark is UNCHANGED by it (fd3='b',
         the byte after its own first read); the shared fd 4 entry
         moved by both of the child's reads (fd4='c').
  ro     no fork.  Two read-intent opens of G (fd 3, fd 4): WRITE and
         SET_EOF through EITHER fd are refused with MLIE_ACCESS ($4E)
         and the file is intact; the marks are independent; closing
         fd 3 leaves fd 4 reading at its own mark.  OPEN-RW-2 CHANGED
         the rest of this row: ONE writer may join a read group, and a
         read-intent open may join a writer.  A WRITER open of G while
         the read group holds it now SUCCEEDS; a SECOND writer is still
         refused $50 (MLIE_FILOPEN); a read-intent open while the
         writer holds G now succeeds; after the writer closes, the
         read-intent open still works.  (Before OPEN-RW-2 both opens
         were $50 -- docs/OPEN-RW-2-NOTES.md has the before/after
         table.)
  park   group parking.  The parent opens G twice (fd 3, fd 4), reads
         fd 3 once and fd 4 twice (marks 1 and 2; fd 4 holds the live
         ProDOS mark), opens F1..F3 and forks.  The child closes its
         copies and opens F4.. until the pool (MLI_IOBUF_CNT, 6) is
         FULL with the group as the LRU victim (ASSERTED from outside,
         with the kernel's own rule).  The child's last open parks it.
         Expect, from the tables: BOTH group entries parked at once
         (iobuf 0), one park counted, one buffer freed for the group
         of two.  Then the parent reads fd 3, fd 4, fd 3, fd 4:
         'b','c','c','d' -- the saved marks come back per entry, and
         both entries are resident again on one shared buffer.
  park3  as park, but the group is three entries and the first opener
         (the one the others joined) is closed first: the mates must
         still park, unpark and read at their own marks.

ASCII only.  Exit 0 green, 1 red (listed), 2 rig problem.
"""
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_posixex as E                                # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR    # noqa: E402
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos                                 # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'build', 'openro')
LISTING = os.path.join(ROOT, 'build', 'MAUXPLAY.SYSTEM_Output.txt')

MODES = ['fork', 'fork2', 'ro', 'park', 'park3']


def equ(name, rel):
    """One `NAME equ VALUE` from an include (check_iobuf.equ): the
    pool size is policy that has moved before (6 -> 8 -> 6)."""
    src = open(os.path.join(ROOT, rel)).read()
    m = re.search(rf'^{name}\s+equ\s+\$?(\w+)', src, re.M)
    v = m.group(1)
    return int(v, 16) if src[m.start(1) - 1] == '$' else int(v)


NBUFS = equ('MLI_IOBUF_CNT', 'inc/mm.mlibuf.equ')
# park mode holds the group plus F1..F3 in the parent and fills the
# rest of the pool in the child: the shape needs a pool of 5..8.
assert 5 <= NBUFS <= 8, f'MLI_IOBUF_CNT={NBUFS}: probe shape needs 5..8'

ST = 0x7000          # state: $11 parent up, $55 child READY, $66 READY2,
                     # $AA parent DONE, $EE fork failed
RA = 0x7010          # + slot: A after the call
RP = 0x7030          # + slot: P after the call (bit 0 = carry)
RB = 0x7060          # + n: byte read by read call n
WS = 0x7050          # the wait status cell


def symbols(path):
    syms = {}
    for line in open(path, errors='replace'):
        m = re.match(r'\s*(\w+)\s*=\s*\$([0-9a-fA-F]+)\s*$', line)
        if m:
            syms[m.group(1)] = int(m.group(2), 16)
    return syms


class Gen:
    """A tiny probe assembler: code lines plus parmlists collected for
    the tail, so each call site stays one line.  Every call records
    A and P after it in the next result slot (RA/RP) and returns the
    slot number; read() returns the byte cell number instead."""

    def __init__(self):
        self.code = ''
        self.parms = ''
        self.nrd = 0
        self.nslot = 0
        self.nparm = 0
        self.rslot = {}              # read cell n -> its result slot

    def call(self, lab, sysname):
        slot = self.nslot
        self.nslot += 1
        self.code += f'''            lda #<{lab}
            ldx #>{lab}
            ldy #{sysname}
            jsr $FF00
            sta ${RA + slot:04X}
            php
            pla
            sta ${RP + slot:04X}
'''
        return slot

    def label(self, stem):
        self.nparm += 1
        return f'{stem}{self.nparm}'

    def open(self, name, ro):
        """OPEN `name` (read intent when `ro`)."""
        lab = self.label('P')
        self.parms += f'''{lab}          dfb {'$83' if ro else '3'}
            da N{name}
            da 0
            dfb 0
'''
        return self.call(lab, 'SYS_OPEN')

    def read(self, fd):
        """READ one byte from fd into cell RB+n; returns n."""
        n = self.nrd
        self.nrd += 1
        self.parms += f'''RD{n}          dfb 4,{fd}
            da ${RB + n:04X}
            da 1,0
'''
        self.rslot[n] = self.call(f'RD{n}', 'SYS_READ')
        return n

    def write(self, fd):
        """WRITE one byte (the cell XP) to fd."""
        lab = self.label('WR')
        self.parms += f'''{lab}          dfb 4,{fd}
            da XP
            da 1,0
'''
        return self.call(lab, 'SYS_WRITE')

    def seteof(self, fd):
        """SET_EOF fd to 0: the file's whole content, if not refused."""
        lab = self.label('EF')
        self.parms += f'''{lab}          dfb 2,{fd}
            dfb 0,0,0
'''
        return self.call(lab, 'SYS_SET_EOF')

    def close(self, fd):
        lab = self.label('CL')
        self.parms += f'''{lab}          dfb 1,{fd}
'''
        return self.call(lab, 'SYS_CLOSE')

    def state(self, v):
        self.code += f'''            lda #${v:02X}
            sta ${ST:04X}
'''

    def spin(self, label):
        self.code += f'{label}       bra {label}\n'

    def raw(self, s):
        self.code += s


def path_decl(name, path):
    return f'''N{name}          dfb {len(path)}
            asc '{path}'
'''


def probe_source(mode):
    g = Gen()
    g.raw(f'''            xc
            org $0800
            dsk probe.bin
''' + ''.join(f'            put ../../inc/{f}.equ\n'
              for f in ('sc.proc', 'sc.file', 'sc.fd')) + f'''START       lda #$11
            sta ${ST:04X}
''')
    names = {'G': '/mnt/MAUX/IP/D/G'}
    for i in range(1, 9):
        names[f'F{i}'] = f'/mnt/MAUX/IP/D/F{i}'
    fork_asm = f'''            lda #$FF
            tax
            ldy #SYS_FORK
            jsr $FF00
            bcc FORKOK
BAD         lda #$EE
            sta ${ST:04X}
            bra BAD
FORKOK      cmp #0
            beq CHILD
'''
    wait_asm = f'''            lda #<WP
            ldx #>WP
            ldy #SYS_WAIT
            jsr $FF00
'''
    if mode in ('fork', 'fork2'):
        g.open('G', True)
        g.open('G', True)
        g.read(3)                       # RB+0: 'a' (fd 3 mark -> 1)
        g.raw(fork_asm)
        g.raw(wait_asm)
        g.read(3)                       # RB+1: parent fd 3
        g.read(4)                       # RB+2: parent fd 4
        g.state(0xAA)
        g.spin('DONE')
        g.raw('CHILD\n')
        g.read(4)                       # RB+3: child fd 4
        # fork: the child's second read is fd 3; fork2: fd 4 again
        g.read(3 if mode == 'fork' else 4)   # RB+4
        # status = (first & 7) << 3 | (second & 7)
        g.raw(f'''            lda ${RB + 3:04X}
            and #7
            asl
            asl
            asl
            sta XP
            lda ${RB + 4:04X}
            and #7
            ora XP
            sta XP
            lda #<XP
            ldx #>XP
            ldy #SYS_EXIT
            jsr $FF00
CSPIN       bra CSPIN
''')
    elif mode == 'ro':
        g.open('G', True)               # slot 0: fd 3
        g.open('G', True)               # slot 1: fd 4
        g.write(3)                      # slot 2: refused
        g.write(4)                      # slot 3: refused
        g.seteof(3)                     # slot 4: refused
        g.seteof(4)                     # slot 5: refused
        g.read(3)                       # RB+0 'a' (slot 6): intact
        g.read(4)                       # RB+1 'a' (slot 7): own mark
        g.close(3)                      # slot 8
        g.read(4)                       # RB+2 'b' (slot 9)
        g.open('G', False)              # slot 10: a writer joins (fd 3)
        g.close(4)                      # slot 11: the last reader goes
        g.open('G', False)              # slot 12: a SECOND writer: $50
        g.open('G', True)               # slot 13: reader joins the writer
        g.close(3)                      # slot 14: the writer (fd 3)
        g.open('G', True)               # slot 15: reader opens again
        g.state(0xAA)
        g.spin('DONE')
    else:
        n_in_group = 3 if mode == 'park3' else 2
        for _ in range(n_in_group):
            g.open('G', True)           # fd 3, 4 (, 5)
        # marks: fd 3 -> 1, fd 4 -> 2, (fd 5 -> 0)
        g.read(3)                       # RB+0
        g.read(4)                       # RB+1
        g.read(4)                       # RB+2
        if mode == 'park3':
            # the first opener closes: the others must outlive it
            g.close(3)
        nfree = 3         # fds 3..7 hold the group, then F1..F3
        dist = []
        for i in range(1, nfree + 1):
            g.open(f'F{i}', False)
            dist.append(i)
        g.raw(fork_asm)
        g.raw(wait_asm)
        # after the child is gone: unpark through the OLD marks
        if mode == 'park3':
            g.read(4)                   # RB+3 'c'
            g.read(5)                   # RB+4 'a'
            g.read(4)                   # RB+5 'd'
            g.read(5)                   # RB+6 'b'
        else:
            g.read(3)                   # RB+3 'b'
            g.read(4)                   # RB+4 'c'
            g.read(3)                   # RB+5 'c'
            g.read(4)                   # RB+6 'd'
        g.state(0xAA)
        g.spin('DONE')
        g.raw('CHILD\n')
        for fd in range(3, 8):          # (park3: fd 3 is F1's copy now)
            g.close(fd)
        # the child opens until the pool is full, then READY, then
        # the last open, the one that parks
        first = nfree + 1
        for i in range(first, first + NBUFS - 1 - nfree):
            g.open(f'F{i}', False)
        g.state(0x55)
        g.spin('READY')
        g.open(f'F{first + NBUFS - 1 - nfree}', False)
        g.state(0x66)
        g.spin('READY2')
        g.raw(f'''            lda #<XP
            ldx #>XP
            ldy #SYS_EXIT
            jsr $FF00
CSPIN       bra CSPIN
''')
    g.raw(f'''XP          dfb 0
WP          da ${WS:04X}
''')
    s = g.code + g.parms
    for k, p in names.items():
        s += path_decl(k, p)
    return s


def build_probe(mode, play):
    os.makedirs(OUT, exist_ok=True)
    src = os.path.join(OUT, 'probe.s')
    with open(src, 'w') as f:
        f.write(probe_source(mode))
    subprocess.run(['merlin32', '-v1', src], check=True,
                   stdout=subprocess.DEVNULL, cwd=OUT)
    binp = os.path.join(OUT, 'probe.bin')
    ps = symbols(binp + '_Output.txt')
    img = os.path.join(OUT, f'{mode}.po')
    shutil.copy(play, img)
    prodos.mount(img)
    try:
        prodos.mkdir('/mnt/MAUX/IP')
        prodos.mkdir('/mnt/MAUX/IP/D')
        prodos.write('/mnt/MAUX/IP/PROBE', open(binp, 'rb').read(),
                     file_type=6, aux_type=0x800)
        prodos.write('/mnt/MAUX/IP/D/G', b'abcdef\x8d', file_type=4)
        for i in range(1, 9):
            prodos.write(f'/mnt/MAUX/IP/D/F{i}', b'abcdef\x8d',
                         file_type=4)
    finally:
        prodos.unmount('MAUX')
    return img, ps


class Rig:
    def __init__(self, client, syms):
        self.c = client
        self.syms = syms

    def peek(self, a, n=1, bank=None):
        kw = {'addr': a, 'count': n,
              'bank': 'main' if bank is None else 'aux'}
        if bank is not None:
            kw['aux_bank'] = bank
        return self.c.call_tool('peek', kw)['bytes']

    def poke(self, a, bs, bank=None):
        kw = {'addr': a, 'bytes': list(bs),
              'bank': 'main' if bank is None else 'aux'}
        if bank is not None:
            kw['aux_bank'] = bank
        self.c.call_tool('poke', kw)

    def tables(self):
        s = self.syms
        return {
            'types': self.peek(s['OFT_TYPE'], 16),
            'pipe': self.peek(s['OFT_PIPE'], 16),
            'refnum': self.peek(s['OFT_REFNUM'], 16),
            'iobuf': self.peek(s['OFT_IOBUF'], 16),
            'inuse': self.peek(s['K_IBF_INUSE'])[0],
            'parks': self.peek(s['K_PARK_CNT'])[0],
            'owner': self.peek(s['K_ROOWN'])[0],
        }

    def paths(self, types):
        base = self.syms.get('OFT_SLOT_BASE', 0xBA00)
        pipe = self.peek(self.syms['OFT_PIPE'], 16)
        out = {}
        for i, t in enumerate(types):
            if t == 3:
                # OAPPEND-1: a PINNED (relative) entry keeps its
                # canonical identity in the slot, flagged OFTF_PIN
                # ($10) in OFT_PIPE; the gates still call it pinned
                n = 0 if pipe[i] & 0x10 else self.peek(base + 68 * i)[0]
                out[i] = bytes(b & 0x7F for b in
                               self.peek(base + 68 * i + 1, n)).decode() \
                    if n else ''
        return out

    def wait_state(self, bank, want, steps=400):
        for _ in range(steps):
            self.c.call_tool('step', {'cycles': 200000})
            if self.peek(ST, 1, bank) == [want]:
                return True
        return False

    def find_state(self, want, steps=400):
        for _ in range(steps):
            self.c.call_tool('step', {'cycles': 200000})
            for b in range(1, 16):
                if self.peek(ST, 1, b) == [want]:
                    return b
        return None


def release(r, addr, bank):
    """check_iobuf.release: write the branch OPERAND only ($00 = fall
    through), never the opcode -- a torn write against a live CPU is
    the 2026-09-16 bug that cost a day."""
    r.poke(addr + 1, [0x00], bank)


def lru_victim(r, tb):
    """PRC_PARK_ONE's rule from outside: among resident, unpinned
    OFT_FILE entries the largest (K_FTICK - OFT_LRU) mod 256, ties to
    the higher index."""
    s = r.syms
    tick = r.peek(s['K_FTICK'])[0]
    lru = r.peek(s['OFT_LRU'], 16)
    best, best_age = 0, 0
    for i in range(1, 16):
        if tb['types'][i] != 3 or tb['iobuf'][i] == 0:
            continue
        if tb['pipe'][i] & 0x10:                     # pinned (OFTF_PIN)
            continue
        age = (tick - lru[i]) & 0xFF
        if age >= best_age:
            best, best_age = i, age
    return best


def ch(b):
    return chr(b & 0x7F)


def run_mode(mode, syms, play):
    img, ps = build_probe(mode, play)
    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
    c = MCPClient([SUPERVISOR], env)
    fails = []
    try:
        c.initialize()
        E.boot_group(c, img)
        E.scrub_probe_state(c, ST)
        E.V.t(c, '/mnt/MAUX/IP/PROBE\r')
        r = Rig(c, syms)
        # (ro never waits on the harness: it is already DONE, $AA,
        # by the first poll)
        pb = r.find_state(0xAA if mode == 'ro' else 0x11)
        if pb is None:
            return [f'{mode}: the probe never started']
        if mode in ('fork', 'fork2'):
            if not r.wait_state(pb, 0xAA):
                return [f'{mode}: parent never reached DONE '
                        f'(RA={r.peek(RA, 12, pb)} RP={r.peek(RP, 12, pb)} '
                        f'WS={r.peek(WS, 1, pb)})']
            rb = r.peek(RB, 8, pb)
            ws = r.peek(WS, 1, pb)[0]
            tb = r.tables()
            print(f'[check-openro-k] {mode}: parent bytes '
                  f'{[ch(x) for x in rb[:3]]}, child status ${ws:02X}, '
                  f'pipe flags {[hex(x) for x in tb["pipe"] if x]}',
                  flush=True)
            want_ws = ((ord('a') & 7) << 3) | (ord('b') & 7)
            if ws != want_ws:
                fails.append(f'{mode}: child saw status ${ws:02X}, want '
                             f'${want_ws:02X} (first=a from its fd 4, '
                             f'second=b)')
            if mode == 'fork':
                want3, want4 = 'c', 'b'
                why3 = "the child's fd 3 read moved the shared description"
                why4 = "the child's fd 4 read moved it"
            else:
                want3, want4 = 'b', 'c'
                why3 = ("the child read only fd 4: the parent's fd 3 "
                        "mark must be UNCHANGED")
                why4 = "the child's two fd 4 reads moved the shared entry"
            if ch(rb[1]) != want3:
                fails.append(f'{mode}: parent fd 3 read {ch(rb[1])!r}, '
                             f'want {want3!r} ({why3})')
            if ch(rb[2]) != want4:
                fails.append(f'{mode}: parent fd 4 read {ch(rb[2])!r}, '
                             f'want {want4!r} ({why4})')
            return fails
        if mode == 'ro':
            if not r.wait_state(pb, 0xAA):
                return [f'{mode}: parent never reached DONE '
                        f'(RA={r.peek(RA, 16, pb)} '
                        f'RP={r.peek(RP, 16, pb)})']
            ra = r.peek(RA, 16, pb)
            rp = r.peek(RP, 16, pb)
            rb = r.peek(RB, 4, pb)
            print(f'[check-openro-k] ro: A {[hex(x) for x in ra]} '
                  f'carry {[x & 1 for x in rp]} bytes '
                  f'{[ch(x) for x in rb[:3]]}', flush=True)

            def refused(slot, code, what):
                if not (rp[slot] & 1) or ra[slot] != code:
                    fails.append(f'ro: {what}: want carry set and '
                                 f'A=${code:02X}, got carry '
                                 f'{rp[slot] & 1} A=${ra[slot]:02X}')

            def ok(slot, what):
                if rp[slot] & 1:
                    fails.append(f'ro: {what}: refused (A=${ra[slot]:02X})')

            ok(0, 'first read-intent open')
            ok(1, 'second read-intent open')
            for slot, what in ((2, 'WRITE through fd 3'),
                               (3, 'WRITE through fd 4'),
                               (4, 'SET_EOF through fd 3'),
                               (5, 'SET_EOF through fd 4')):
                refused(slot, 0x4E, what + ' (MLIE_ACCESS)')
            ok(6, 'read fd 3')
            ok(7, 'read fd 4')
            if ch(rb[0]) != 'a' or ch(rb[1]) != 'a':
                fails.append(f"ro: marks must be independent and the "
                             f"file intact: fd 3 then fd 4 read "
                             f"{ch(rb[0])!r} {ch(rb[1])!r}, want 'a' 'a'")
            ok(8, 'close fd 3')
            ok(9, 'read fd 4 after fd 3 closed')
            if ch(rb[2]) != 'b':
                fails.append(f"ro: fd 4 must go on reading at its own "
                             f"mark after fd 3 closed: {ch(rb[2])!r}, "
                             f"want 'b'")
            ok(10, 'WRITER open while a read group holds G (OPEN-RW-2: '
                   'one writer joins)')
            ok(11, 'close fd 4')
            refused(12, 0x50, 'a SECOND writer open while a writer holds '
                    'G (MLIE_FILOPEN)')
            ok(13, 'read-intent open while a writer holds G (OPEN-RW-2: '
                   'joins)')
            ok(14, 'close the writer')
            ok(15, 'read-intent open after the writer closed')
            return fails
        # park / park3
        cb = r.find_state(0x55)
        if cb is None:
            return [f'{mode}: the child never reached READY '
                    f'(parent RA={r.peek(RA, 12, pb)} '
                    f'RP={r.peek(RP, 12, pb)})']
        tb = r.tables()
        paths = r.paths(tb['types'])
        grp = sorted(i for i, p in paths.items()
                     if p.upper() == '/MAUX/IP/D/G')
        want_n = 2        # park3 closed the first of its three
        print(f'[check-openro-k] {mode}: child bank {cb}, files '
              f'{sum(1 for t in tb["types"] if t == 3)}, inuse='
              f'{tb["inuse"]} parks={tb["parks"]} group slots {grp} '
              f'iobuf {[tb["iobuf"][i] for i in grp]} '
              f'pipe {[hex(tb["pipe"][i]) for i in grp]} '
              f'owner={tb["owner"]}', flush=True)
        # the group is a group
        if len(grp) != want_n:
            fails.append(f'{mode}: want {want_n} entries on G, found '
                         f'{grp}')
        if len({tb['iobuf'][i] for i in grp}) != 1 or tb['iobuf'][grp[0]] == 0:
            fails.append(f'{mode}: the group must share ONE resident '
                         f'buffer, got {[tb["iobuf"][i] for i in grp]}')
        if tb['inuse'] != NBUFS:
            fails.append(f'{mode}: setup: the pool must be FULL '
                         f'({tb["inuse"]} of {NBUFS}) or the next open '
                         f'never parks')
        if tb['parks'] != 0:
            fails.append(f'{mode}: setup: nothing may be parked yet')
        victim = lru_victim(r, tb)
        if victim not in grp:
            fails.append(f'{mode}: setup: the LRU victim (slot {victim}) '
                         f'must be a member of the group {grp}')
        if fails:
            return fails
        release(r, ps['READY'], cb)
        if not r.wait_state(cb, 0x66):
            return [f'{mode}: the child never finished its parking open '
                    f'(child RA={r.peek(RA, 12, cb)} '
                    f'RP={r.peek(RP, 12, cb)})']
        t2 = r.tables()
        print(f'[check-openro-k] {mode}: after the park: inuse='
              f'{t2["inuse"]} parks={t2["parks"]} group iobuf '
              f'{[t2["iobuf"][i] for i in grp]} owner={t2["owner"]}',
              flush=True)
        if any(t2['iobuf'][i] != 0 for i in grp):
            fails.append(f'{mode}: every member of the group must park '
                         f'together, iobuf {[t2["iobuf"][i] for i in grp]}')
        if t2['parks'] != 1:
            fails.append(f'{mode}: one GROUP park is one park, counted '
                         f'{t2["parks"]}')
        if t2['inuse'] != NBUFS:
            fails.append(f'{mode}: the group freed one buffer, the '
                         f'parking open took it: inuse {t2["inuse"]}, '
                         f'want {NBUFS}')
        if t2['owner'] in grp:
            fails.append(f'{mode}: K_ROOWN {t2["owner"]} still names a '
                         f'parked member')
        release(r, ps['READY2'], cb)
        if not r.wait_state(pb, 0xAA):
            return fails + [f'{mode}: parent never reached DONE '
                            f'(RA={r.peek(RA, 14, pb)} '
                            f'RP={r.peek(RP, 14, pb)})']
        rb = r.peek(RB, 8, pb)
        t3 = r.tables()
        got = ''.join(ch(x) for x in rb[3:7])
        want = 'bccd' if mode == 'park' else 'cadb'
        print(f'[check-openro-k] {mode}: reads after the unpark {got!r} '
              f'(want {want!r}); group iobuf '
              f'{[t3["iobuf"][i] for i in grp if t3["types"][i] == 3]} '
              f'refnum {[t3["refnum"][i] for i in grp if t3["types"][i] == 3]}',
              flush=True)
        if got != want:
            fails.append(f'{mode}: reads after the unpark gave {got!r}, '
                         f'want {want!r}')
        live = [i for i in grp if t3['types'][i] == 3]
        if len({t3['iobuf'][i] for i in live}) != 1 or \
                t3['iobuf'][live[0]] == 0:
            fails.append(f'{mode}: the group must be resident on ONE '
                         f'shared buffer after the unpark, got '
                         f'{[t3["iobuf"][i] for i in live]}')
        if len({t3['refnum'][i] for i in live}) != 1:
            fails.append(f'{mode}: and on one refnum, got '
                         f'{[t3["refnum"][i] for i in live]}')
        return fails
    finally:
        c.close()


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--play', default=os.path.join(ROOT, 'build',
                                                   'play.po'))
    ap.add_argument('modes', nargs='*', default=MODES)
    args = ap.parse_args()
    if not os.path.exists(LISTING):
        print(f'check-openro-k: {LISTING} missing -- make play-image')
        return 2
    syms = symbols(LISTING)
    allf = []
    for m in args.modes:
        f = run_mode(m, syms, os.path.abspath(args.play))
        for x in f:
            print(f'  - {x}')
        print(f'[check-openro-k] {m}: {"PASS" if not f else "FAIL"}',
              flush=True)
        allf += f
    if allf:
        print(f'[check-openro-k] FAIL: {len(allf)} row(s)')
        return 1
    print('[check-openro-k] PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
