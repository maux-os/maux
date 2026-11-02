#!/usr/bin/env python3
"""check_iobuf.py -- io_buffer LENDING regressions (`make check-iobuf`).

docs/IOBUF-LENDING.md sec 5. The nested-shell case in check-shlang proves
lending works on the happy path; THIS gate targets the edge cases the
2026-09-07 review found open (the design review, IB1-IB5), each with
the reproduction the review used, against the REAL kernel and resident
ProDOS on the fast backend:

  control    park F0 by opening a ninth file, then read the parked fd
             twice: 'b','c' -- the saved mark is restored (the positive
             case every other mode is measured against)
  duplicate  IB1: a second OPEN of a RESIDENT file that is the LRU
             victim must be refused $50 -- not parked-then-opened.
             The victim is ASSERTED, not assumed: lru_victim() runs
             PRC_PARK_ONE's own age rule over the peeked tables before
             the test, so the mode fails loudly if it is arming some
             other file, and the canonical path the scan compared is
             checked afterwards so a probe that never delivered its
             pathname cannot look like a kernel fault
  nullpath   IB6: an OPEN of a ZERO-LENGTH pathname while something is
             parked must be refused $50 by the unknown-identity rule.
             An empty path is legal to hand the kernel (bare `cd` is
             one) and has no identity, so PRC_CANONPATH must report it
             with the carry; the bug this pins returned carry CLEAR
             with length 0, which compares unequal to every saved path
             and so read as "not open" -- the identity guard silently
             off, and a victim parked for an open that cannot succeed
  relative   IB2: a RELATIVE alias (`IP/D/F0` under prefix /MAUX/) of a
             PARKED file must be refused $50, and PRC_CANON must hold the
             canonicalized incoming path /MAUX/IP/D/F0 (len 13)
  relctl     IB2 control: a RELATIVE open of a DISTINCT unopened file
             (`IP/D/F9`) under the same park pressure must SUCCEED -- the
             refusal is an identity match on the canonical path, not a
             blanket refusal of relative opens while something is parked
  hialias    IB2/F1: F0 is opened with a HIGH-BIT absolute path; its saved
             identity must be stored low-ASCII (PCPY_PATH_G's `and #$7F`),
             so a later low-ASCII relative alias of the same file is still
             refused $50 -- without the mask the high-bit saved path never
             matches the canonical incoming path and the alias slips through
  rename     IB3: RENAME of a directory holding a parked file must be
             refused $50, and the parked fd must still read 'a' after
  renamectl  IB3 control: RENAME of an unrelated directory succeeds and
             the parked fd still reads
  closefail  IB4: PCLS_RAWREF_A patched to fail $27 -- the OPEN that
             needed a park reports $27 (NOT ERR_NFILE), no park is
             recorded, the victim stays resident, K_IBF_INUSE stays at the pool size
  seekfail   IB5: PMLI_SMARK_CL patched to fail $27 -- two reads through
             the parked fd BOTH fail $27 (never a silent read at mark 0),
             the entry stays parked; with the patch removed the next read
             returns 'b'
  pinfull    B1: every buffer in the pool held by a PINNED (relatively
             opened) file, nothing parked: one more OPEN must fail
             LOUDLY with ERR_NFILE ($E9), leak no OFT entry, and not
             hang -- pin exhaustion is a correctness case, not a
             slowdown. Setup asserts all of the pool really is pinned
  parksat    B1: K_PARK_CNT is non-wrapping. Set to $FF, then a park
             must leave it at $FF, not roll it to a false zero

The pool is MLI_IOBUF_CNT (6 since B1, read from the include, not
retyped). Every mode prints the pool high-water (K_IBF_HIWAT) and the
park count; `control` asserts the pool really FILLED before it parks.

The probe process is generated here (build/iobuf/probe-<mode>.s), so the
scenario and the expectation live side by side. It is a test program,
not a src/bin utility, so it speaks the $FF00 ABI directly like every
src/test harness. Nine one-line files F0..F8 ("abcdef") and the probe are
staged on a COPY of build/play.po; the shipping image is never written.

Shape (from the review's reproduction): the parent opens F0..F4 and
forks, keeping those five open while it waits; the child drops its
inherited copies of fd 4..7 (fd 3 = F0 stays, so F0 is the natural LRU
victim), opens F5..F(pool-1) -- the whole pool resident -- then
runs the mode's TEST. Nothing pokes OFT/LRU state; the fault modes patch
exactly one kernel helper in emulator RAM, by symbol from the image's own
listing, and restore it afterwards.
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
OUT = os.path.join(ROOT, 'build', 'iobuf')
PLAY = os.path.join(ROOT, 'build', 'play.po')
LISTING = os.path.join(ROOT, 'build', 'MAUXPLAY.SYSTEM_Output.txt')

MODES = ['control', 'duplicate', 'nullpath', 'relative', 'relctl', 'hialias',
         'rename', 'renamectl', 'closefail', 'seekfail', 'pinfull', 'parksat']

# Child result cells (its own bank). $7000 = state: $55 READY, $66
# READY2 (seekfail's second phase), $AA DONE, $EE fork failed.
ST = 0x7000
RA = 0x7010          # + slot: A after the call
RP = 0x7030          # + slot: P after the call (bit 0 = carry)
RB = 0x7060          # READ target byte
MLIE_FILOPEN = 0x50
FAULT = 0x27


def equ(name, rel):
    """One `NAME equ VALUE` from an include, read rather than retyped --
    the pool size is policy that has already moved once (6 -> 8)."""
    src = open(os.path.join(ROOT, rel)).read()
    m = re.search(rf'^{name}\s+equ\s+\$?(\w+)', src, re.M)
    v = m.group(1)
    return int(v, 16) if src[m.start(1) - 1] == '$' else int(v)


NBUFS = equ('MLI_IOBUF_CNT', 'inc/mm.mlibuf.equ')
# The probe holds five files in the parent and fills the rest of the
# pool in the child, so the pool must be 6..8 for the shape to exist.
assert 6 <= NBUFS <= 8, f'MLI_IOBUF_CNT={NBUFS}: probe shape needs 6..8'
ERR_NFILE = 0xE9
FAULT_BYTES = [0xA9, FAULT, 0x38, 0x60]       # LDA #$27 ; SEC ; RTS


def op(name, slot):
    return f'''            lda #<P{name}
            ldx #>P{name}
            ldy #SYS_OPEN
            jsr $FF00
            sta ${RA + slot:04X}
            php
            pla
            sta ${RP + slot:04X}
'''


def rd(slot):
    return f'''            lda #<RDP
            ldx #>RDP
            ldy #SYS_READ
            jsr $FF00
            sta ${RA + slot:04X}
            php
            pla
            sta ${RP + slot:04X}
'''


def probe_source(mode):
    s = '''            xc
            org $0800
            dsk probe.bin
'''
    for f in ('sc.proc', 'sc.file', 'sc.fd'):
        s += f'            put ../../inc/{f}.equ\n'
    s += f'START       stz ${ST:04X}\n'
    for i in range(5):
        if i == 0 and mode == 'hialias':
            s += op('0H', 0)                  # F0 via a HIGH-BIT path
        elif mode == 'pinfull':
            s += op('RF' + str(i), i)         # relative: PINNED
        else:
            s += op(str(i), i)
        if i == 0 and mode in ('control', 'seekfail', 'parksat'):
            s += rd(15)                       # F0 mark -> 1 ('a' consumed)
    s += f'''            lda #$FF
            tax
            ldy #SYS_FORK
            jsr $FF00
            bcc FORKOK
BAD         lda #$EE
            sta ${ST:04X}
            bra BAD
FORKOK      cmp #0
            beq CHILD
            lda #<WP
            ldx #>WP
            ldy #SYS_WAIT
            jsr $FF00
PWAIT       bra PWAIT
CHILD
'''
    for fd in range(4, 8):
        s += f'''            lda #{fd}
            sta CP+1
            lda #<CP
            ldx #>CP
            ldy #SYS_CLOSE
            jsr $FF00
'''
    for i in range(5, NBUFS):
        s += op(('RF' if mode == 'pinfull' else '') + str(i), i)
    if mode in ('control', 'nullpath', 'relative', 'hialias', 'rename',
                'renamectl', 'seekfail', 'parksat'):
        s += op('8', 9)                       # ninth file: parks F0
    # relctl deliberately does NOT pre-open a ninth file: it leaves the
    # child one free fd, and its own relative open of F9 is the ninth
    # file -- the buffer it needs triggers the park of F0 (LRU).
    s += f'''            lda #$55
            sta ${ST:04X}
READY       bra READY
TEST
'''
    if mode == 'duplicate':
        s += op('0', 8)
    elif mode == 'nullpath':
        s += op('Z', 8)                       # zero-length pathname
    elif mode in ('closefail', 'pinfull'):
        s += op('8', 8)
    elif mode == 'relative':
        s += op('R', 8)
    elif mode == 'relctl':
        s += op('R2', 8)                      # relative open of distinct F9
    elif mode == 'hialias':
        s += op('R', 8)                       # low-ASCII alias of hi-bit F0
    elif mode in ('control', 'seekfail', 'parksat'):
        s += rd(8) + rd(9)
        if mode == 'seekfail':
            s += f'''            lda #$66
            sta ${ST:04X}
READY2      bra READY2
''' + rd(10)
    elif mode in ('rename', 'renamectl'):
        rn = 'RN' if mode == 'rename' else 'RC'
        s += f'''            lda #<{rn}
            ldx #>{rn}
            ldy #SYS_RENAME
            jsr $FF00
            sta ${RA + 8:04X}
            php
            pla
            sta ${RP + 8:04X}
''' + rd(9)
    s += f'''            lda #$AA
            sta ${ST:04X}
DONE        bra DONE
CP          dfb 1,0
WP          da $7050
RDP         dfb 4,3
            da ${RB:04X}
            da 1,0
'''
    for i in range(10):
        path = f'/mnt/MAUX/IP/D/F{i}'
        s += f'''P{i}          dfb 3
            da N{i}
            da 0
            dfb 0
N{i}          dfb {len(path)}
            asc '{path}'
'''
    for i in range(NBUFS):
        s += f'''PRF{i}         dfb 3
            da NRF{i}
            da 0
            dfb 0
NRF{i}         dfb 7
            asc 'IP/D/F{i}'
'''
    s += """PZ          dfb 3
            da NZ
            da 0
            dfb 0
NZ          dfb 0
P0H         dfb 3
            da N0H
            da 0
            dfb 0
N0H         dfb 17
            asc "/mnt/MAUX/IP/D/F0"
PR          dfb 3
            da NR
            da 0
            dfb 0
NR          dfb 7
            asc 'IP/D/F0'
PR2         dfb 3
            da NR2
            da 0
            dfb 0
NR2         dfb 7
            asc 'IP/D/F9'
RN          dfb 2
            da OLD,NEW
OLD         dfb 14
            asc '/mnt/MAUX/IP/D'
NEW         dfb 14
            asc '/mnt/MAUX/IP/E'
RC          dfb 2
            da OLDX,NEWX
OLDX        dfb 14
            asc '/mnt/MAUX/IP/X'
NEWX        dfb 14
            asc '/mnt/MAUX/IP/Y'
"""
    return s


def symbols(path):
    syms = {}
    for line in open(path, errors='replace'):
        m = re.match(r'\s*(\w+)\s*=\s*\$([0-9a-fA-F]+)\s*$', line)
        if m:
            syms[m.group(1)] = int(m.group(2), 16)
    return syms


def build_probe(mode):
    os.makedirs(OUT, exist_ok=True)
    src = os.path.join(OUT, 'probe.s')
    with open(src, 'w') as f:
        f.write(probe_source(mode))
    subprocess.run(['merlin32', '-v1', src], check=True,
                   stdout=subprocess.DEVNULL, cwd=OUT)
    binp = os.path.join(OUT, 'probe.bin')
    ps = symbols(binp + '_Output.txt')
    img = os.path.join(OUT, f'{mode}.po')
    shutil.copy(PLAY, img)
    prodos.mount(img)
    try:
        prodos.mkdir('/mnt/MAUX/IP')
        prodos.mkdir('/mnt/MAUX/IP/D')
        prodos.mkdir('/mnt/MAUX/IP/X')
        prodos.write('/mnt/MAUX/IP/PROBE', open(binp, 'rb').read(),
                     file_type=6, aux_type=0x800)
        for i in range(10):
            prodos.write(f'/mnt/MAUX/IP/D/F{i}', b'abcdef\x8d', file_type=4)
    finally:
        prodos.unmount('MAUX')
    return img, ps


class Rig:
    def __init__(self, client, syms):
        self.c = client
        self.syms = syms

    def peek(self, a, n=1, bank=None):
        kw = {'addr': a, 'count': n, 'bank': 'main' if bank is None else 'aux'}
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
            'iobuf': self.peek(s['OFT_IOBUF'], 16),
            'inuse': self.peek(s['K_IBF_INUSE'])[0],
            'parks': self.peek(s['K_PARK_CNT'])[0],
            'hiwat': self.peek(s['K_IBF_HIWAT'])[0],
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
                               self.peek(base + 68 * i + 1, n)).decode() if n else ''
        return out

    def wait_state(self, bank, want, steps=300):
        for _ in range(steps):
            self.c.call_tool('step', {'cycles': 200000})
            if self.peek(ST, 1, bank) == [want]:
                return True
        return False

    def find_ready(self):
        for _ in range(300):
            self.c.call_tool('step', {'cycles': 200000})
            for b in range(1, 16):
                if self.peek(ST, 1, b) == [0x55]:
                    return b
        return None


def release(r, addr, bank):
    """Let the probe out of a `LABEL bra LABEL` spin -- by writing the
    branch OPERAND only, never the opcode.

    The obvious release (poke [NOP,NOP] over both bytes) is a TORN WRITE
    against a live CPU and it cost a day on 2026-09-16: the 65C02 had
    already fetched the $80 opcode when the poke landed, read the NEW
    second byte as the offset, and took `bra -22` into the middle of the
    preceding `op()` block -- skipping its `lda #<Pn` so the syscall went
    in with a stale A, a parmlist pointer into the middle of a fixture
    STRING, and a zero-length pathname. check-iobuf then reported a park
    it could not explain, and whether the poke landed mid-instruction at
    all depended on the phase of the spin loop -- i.e. on how many cycles
    the whole boot happened to take, i.e. on the KERNEL'S SIZE. That is
    why the red tracked padding bytes and not semantics.

    $00 as the offset means "branch to the next instruction", so both
    orderings are correct: a CPU that already read $FE loops once more
    and falls through on the next pass; one that reads $00 falls through
    now. A single byte cannot be half-written, so there is no third
    outcome."""
    r.poke(addr + 1, [0x00], bank)


def lru_victim(r, types, iobuf):
    """The OFT index PRC_PARK_ONE would pick, computed from outside with
    the kernel's own rule (procfd2.s): among resident, unpinned OFT_FILE
    entries, the largest (K_FTICK - OFT_LRU) mod 256, ties to the higher
    index. Lets a mode ASSERT the victim it is arming rather than trust
    the order the probe happened to open its files in."""
    s = r.syms
    tick = r.peek(s['K_FTICK'])[0]
    lru = r.peek(s['OFT_LRU'], 16)
    pipe = r.peek(s['OFT_PIPE'], 16)
    base = s.get('OFT_SLOT_BASE', 0xBA00)
    best, best_age = 0, 0
    for i in range(1, 16):
        if types[i] != 3 or iobuf[i] == 0:
            continue
        if pipe[i] & 0x10:                           # pinned (OFTF_PIN)
            continue
        age = (tick - lru[i]) & 0xFF
        if age >= best_age:
            best, best_age = i, age
    return best


def run_mode(mode, syms):
    img, ps = build_probe(mode)
    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
    c = MCPClient([SUPERVISOR], env)
    fails = []
    try:
        c.initialize()
        E.boot_group(c, img)
        E.scrub_probe_state(c, ST)
        E.V.t(c, '/mnt/MAUX/IP/PROBE\r')
        r = Rig(c, syms)
        b = r.find_ready()
        if b is None:
            return [f'{mode}: child never reached READY']
        before = r.tables()
        nfiles = sum(1 for t in before['types'] if t == 3)
        paths = r.paths(before['types'])
        f0 = [i for i, p in paths.items() if p.upper() == '/MAUX/IP/D/F0']
        if mode == 'pinfull':
            f0 = sorted(paths)[:1]        # pinned: no saved identity
        if not f0:
            fails.append(f'{mode}: F0 not found in the slot store: {paths}')
            return fails
        f0 = f0[0]
        # The SETUP result cells (slots 0..7), which no mode's TEST ever
        # writes. Snapshotted so the end of the run can prove the probe
        # executed its TEST and nothing else: a release that drops the
        # CPU anywhere but the first instruction of TEST re-runs part of
        # an earlier op() and overwrites one of these. That is not
        # hypothetical -- it is exactly what the 2026-09-16 torn-release
        # bug did (`bra -22` into the middle of the F7 open), and it is
        # invisible in every other cell the gate reads, because the real
        # TEST still runs correctly afterwards and leaves correct-looking
        # results behind the damage.
        setup_a = r.peek(RA, 8, b)
        setup_p = r.peek(RP, 8, b)
        victim = lru_victim(r, before['types'], before['iobuf'])
        print(f'[check-iobuf] {mode}: child in bank {b}, {nfiles} files, '
              f'inuse={before["inuse"]} hiwat={before["hiwat"]} '
              f'parks={before["parks"]} '
              f'F0 slot {f0} iobuf={before["iobuf"][f0]} '
              f'LRU victim slot {victim}', flush=True)

        # The IB1 trigger is ARMED here, not hoped for: the file the
        # test is about to re-open must be resident, the pool must be
        # full, and it must be the entry PRC_PARK_ONE would choose --
        # so the only way the open can avoid parking it is the identity
        # refusal this mode exists to prove. Asserted before the test so
        # a setup that drifts reports itself instead of passing by luck.
        if mode == 'duplicate':
            if before['iobuf'][f0] == 0:
                fails.append('IB1 setup: F0 must be RESIDENT before the '
                             'duplicate open')
            if before['parks'] != 0:
                fails.append(f'IB1 setup: nothing may be parked yet '
                             f'(parks={before["parks"]})')
            if before['inuse'] != NBUFS:
                fails.append(f'IB1 setup: the io_buffer pool must be FULL '
                             f'({before["inuse"]} of {NBUFS} in use) or the '
                             f'open never needs to park at all')
            if victim != f0:
                fails.append(f'IB1 setup: F0 (slot {f0}) must be the LRU '
                             f'victim PRC_PARK_ONE would pick, but that is '
                             f'slot {victim}')
        if mode == 'control' and before['hiwat'] != NBUFS:
            fails.append(f'control setup: the pool never filled (hiwat '
                         f'{before["hiwat"]} of {NBUFS}), so the park '
                         f'below proves nothing about a FULL pool')
        if mode == 'pinfull':
            pinned = [i for i, p in paths.items() if p == '']
            if len(pinned) != NBUFS or nfiles != NBUFS:
                fails.append(f'pinfull setup: all {NBUFS} open files must '
                             f'be PINNED (relative, no saved path), got '
                             f'{len(pinned)} pinned of {nfiles}: {paths}')
            if before['inuse'] != NBUFS or before['parks'] != 0:
                fails.append(f'pinfull setup: the pool must be full of '
                             f'pinned buffers with nothing parked '
                             f'(inuse={before["inuse"]} of {NBUFS}, '
                             f'parks={before["parks"]})')
        if mode == 'nullpath':
            if before['parks'] < 1:
                fails.append('IB6 setup: the pre-open of a ninth file must '
                             'have parked F0 -- the unknown-identity rule '
                             'only refuses while something is parked')
        if fails:
            return fails

        saved = None
        if mode == 'closefail':
            saved = r.peek(syms['PCLS_RAWREF_A'], 4)
            r.poke(syms['PCLS_RAWREF_A'], FAULT_BYTES)
        if mode == 'seekfail':
            saved = r.peek(syms['PMLI_SMARK_CL'], 4)
            r.poke(syms['PMLI_SMARK_CL'], FAULT_BYTES)

        if mode == 'parksat':
            # the counter is non-wrapping: at 255 the next park must
            # leave it at 255, not roll it to a false zero
            r.poke(syms['K_PARK_CNT'], [0xFF])
        release(r, ps['READY'], b)                       # release
        if os.environ.get('IOBUF_TRACE_PARK'):
            # Diagnostic: stop at the next write to K_PARK_CNT and show
            # who parked (kernel return addresses on the process stack).
            hit = c.call_tool('until_write', {'addr': syms['K_PARK_CNT'],
                                              'max_cycles': 20000000})
            regs = c.call_tool('regs', {})
            sp = regs['s']
            stack = r.peek(0x100 + sp + 1, 0xFF - sp, b)
            rev = sorted(((v, k) for k, v in syms.items()))
            def near(a):
                best = None
                for v, k in rev:
                    if v <= a: best = (k, a - v)
                    else: break
                return f'{best[0]}+{best[1]}' if best else '?'
            rets = []
            for i in range(len(stack) - 1):
                a = stack[i] | (stack[i + 1] << 8)
                if 0x2000 <= a < 0xA000: rets.append(f'${a:04X}={near(a)}')
            print(f'[trace] until_write K_PARK_CNT: {hit} regs={regs}', flush=True)
            print(f'[trace] stack words in kernel: {rets}', flush=True)
            print(f'[trace] tables now: {r.tables()}', flush=True)
            print(f'[trace] RA={r.peek(RA,10,b)} RP={[hex(x) for x in r.peek(RP,10,b)]}', flush=True)
        if mode == 'seekfail':
            if not r.wait_state(b, 0x66):
                return [f'{mode}: child never reached READY2']
            mid = r.tables()
            a8, a9 = r.peek(RA + 8, 2, b)
            p8, p9 = r.peek(RP + 8, 2, b)
            if not (p8 & 1) or a8 != FAULT:
                fails.append(f'IB5: first read after a failed SET_MARK '
                             f'expected carry+$27, got A=${a8:02X} P=${p8:02X}')
            if not (p9 & 1) or a9 != FAULT:
                fails.append(f'IB5: SECOND read must fail too (a silent read '
                             f'at mark 0 is the bug), got A=${a9:02X} P=${p9:02X}')
            if mid['iobuf'][f0] != 0:
                fails.append(f'IB5: F0 must remain PARKED after the failed '
                             f'restore, but iobuf={mid["iobuf"][f0]}')
            r.poke(syms['PMLI_SMARK_CL'], saved)
            saved = None
            release(r, ps['READY2'], b)
        if not r.wait_state(b, 0xAA):
            fails.append(f'{mode}: child never reached DONE')
            return fails
        after = r.tables()
        ra = r.peek(RA, 11, b)
        rp = r.peek(RP, 11, b)
        byte = r.peek(RB, 1, b)[0] & 0x7F
        nfiles_after = sum(1 for t in after['types'] if t == 3)
        canon_base = syms.get('PRC_CANON', 0xBE40)
        cl = r.peek(canon_base)[0]
        canon = bytes(x & 0x7F for x in r.peek(canon_base + 1, min(cl, 64))).decode(
            'latin1') if cl else ''
        print(f'[check-iobuf] {mode}: PRC_CANON={canon!r} (len {cl}) '
              f'paths-after={r.paths(after["types"])}', flush=True)
        print(f'[check-iobuf] {mode}: results A={[hex(x) for x in ra[8:11]]} '
              f'P={[hex(x) for x in rp[8:11]]} byte={chr(byte)!r} '
              f'parks {before["parks"]}->{after["parks"]} inuse={after["inuse"]} '
              f'hiwat={after["hiwat"]} '
              f'files {nfiles}->{nfiles_after} F0 iobuf={after["iobuf"][f0]}',
              flush=True)

        def refused(slot, label):
            if not (rp[slot] & 1) or ra[slot] != MLIE_FILOPEN:
                fails.append(f'{label}: expected refusal $50, got '
                             f'A=${ra[slot]:02X} P=${rp[slot]:02X}')

        # Did the probe run its TEST, and only its TEST? Checked FIRST,
        # because every assertion below reads state this would have
        # invalidated, and a resumed-in-the-wrong-place probe presents
        # as a plausible-looking kernel fault (see docs/PROCIO.md 15.9).
        if r.peek(RA, 8, b) != setup_a or r.peek(RP, 8, b) != setup_p:
            fails.append(f'{mode}: the probe re-ran part of its SETUP '
                         f'after release -- A {setup_a}->{r.peek(RA, 8, b)} '
                         f'P {setup_p}->{r.peek(RP, 8, b)}. The release did '
                         f'not land on the first instruction of TEST, so '
                         f'nothing measured after it is about the kernel.')
            return fails

        if mode == 'parksat':
            if after['parks'] != 0xFF:
                fails.append(f'parksat: K_PARK_CNT was set to $FF and a '
                             f'park followed; it must SATURATE at $FF, '
                             f'got ${after["parks"]:02X}')
            if byte != ord('c') or (rp[8] & 1) or (rp[9] & 1):
                fails.append(f'parksat: the reads through the parked fd '
                             f'did not return the saved mark (byte='
                             f'{chr(byte)!r})')
        if mode == 'control':
            if after['parks'] < 1:
                fails.append('control: opening a ninth file never parked')
            if (rp[8] & 1) or (rp[9] & 1):
                fails.append(f'control: reads through the parked fd failed '
                             f'P8=${rp[8]:02X} P9=${rp[9]:02X}')
            if byte != ord('c'):
                fails.append(f'control: after reading a,b,c the last byte '
                             f'should be c, got {chr(byte)!r} -- mark not '
                             f'restored')
        elif mode == 'duplicate':
            refused(8, 'IB1 duplicate open of the resident LRU victim')
            if nfiles_after != nfiles:
                fails.append(f'IB1: a ninth OFT entry appeared ({nfiles}->'
                             f'{nfiles_after})')
            if after['parks'] != before['parks']:
                fails.append(f'IB1: the open parked the file it was opening '
                             f'(parks {before["parks"]}->{after["parks"]})')
            # A probe whose pathname never reached the kernel would show
            # up here as an unexplained park, which is exactly how the
            # 2026-09-16 torn-release bug spent a day looking like a
            # kernel fault. Pin what the identity scan actually compared.
            if canon != '/MAUX/IP/D/F0' or cl != 13:
                fails.append(f'IB1: the scan must have compared the '
                             f'canonical /MAUX/IP/D/F0 (len 13); it saw '
                             f'{canon!r} (len {cl}) -- the open never '
                             f'carried the pathname the mode sent')
        elif mode == 'nullpath':
            refused(8, 'IB6 open of a zero-length pathname while parked')
            if after['parks'] != before['parks']:
                fails.append(f'IB6: an un-canonicalizable open must be '
                             f'refused before the allocator runs, not park '
                             f'a victim (parks {before["parks"]}->'
                             f'{after["parks"]})')
            # PRC_CANLEN, the routine's OWN result cell -- not PRC_CANON's
            # length byte, which the guard leaves holding the previous
            # call's path precisely because it returns before writing it.
            canlen = r.peek(syms['PRC_CANLEN'])[0]
            if canlen != 0:
                fails.append(f'IB6: an empty path has no identity, so '
                             f'PRC_CANLEN must be 0, got {canlen}')
            if nfiles_after != nfiles:
                fails.append(f'IB6: an OFT entry appeared for an empty '
                             f'path ({nfiles}->{nfiles_after})')
        elif mode == 'relative':
            if before['parks'] < 1 or before['iobuf'][f0] != 0:
                fails.append('relative: F0 was not parked before the test')
            refused(8, 'IB2 relative alias of a parked file')
            if nfiles_after != nfiles:
                fails.append(f'IB2: alias created a second OFT entry')
            if canon != '/MAUX/IP/D/F0' or cl != 13:
                fails.append(f'IB2: PRC_CANON must hold the canonicalized '
                             f'incoming path /MAUX/IP/D/F0 (len 13) to match '
                             f'the parked identity, got {canon!r} (len {cl})')
        elif mode == 'relctl':
            # No pre-park: the pool is full (8) but nothing is parked yet,
            # and the child kept one free fd. The relative open of the
            # distinct F9 must SUCCEED and itself trigger the park of F0.
            if before['parks'] != 0 or before['iobuf'][f0] == 0:
                fails.append(f'relctl: expected F0 resident and nothing '
                             f'parked before the test (parks={before["parks"]} '
                             f'F0 iobuf={before["iobuf"][f0]})')
            if (rp[8] & 1) or ra[8] == MLIE_FILOPEN:
                fails.append(f'IB2 control: a relative open of a DISTINCT '
                             f'unopened file (IP/D/F9) under park pressure '
                             f'must SUCCEED, got A=${ra[8]:02X} P=${rp[8]:02X} '
                             f'-- the refusal must be an identity match, not a '
                             f'blanket refusal of relative opens')
            if nfiles_after <= nfiles:
                fails.append(f'IB2 control: the successful relative open must '
                             f'add an OFT entry ({nfiles}->{nfiles_after})')
            if after['parks'] <= before['parks']:
                fails.append(f'IB2 control: opening F9 with the pool full must '
                             f'trigger a park (parks {before["parks"]}->'
                             f'{after["parks"]})')
            # F9 was opened RELATIVELY, so it is PINNED -- it carries no
            # saved identity (length 0). A new pinned type-3 entry (empty
            # saved path) is exactly what a successful relative open adds.
            paths_after = r.paths(after['types'])
            pinned_before = sum(1 for p in paths.values() if p == '')
            pinned_after = sum(1 for p in paths_after.values() if p == '')
            if pinned_after <= pinned_before:
                fails.append(f'IB2 control: a successful relative open must '
                             f'add a PINNED entry (no saved path); pinned '
                             f'entries {pinned_before}->{pinned_after}, '
                             f'paths-after={paths_after}')
            if canon != '/MAUX/IP/D/F9' or cl != 13:
                fails.append(f'IB2 control: PRC_CANON should hold the '
                             f'canonicalized F9 path, got {canon!r} (len {cl})')
        elif mode == 'hialias':
            if before['parks'] < 1 or before['iobuf'][f0] != 0:
                fails.append('hialias: F0 was not parked before the test')
            refused(8, 'IB2/F1 low-ASCII alias of a high-bit-opened file')
            if nfiles_after != nfiles:
                fails.append(f'IB2/F1: alias created a second OFT entry')
            # The fix's actual effect: PCPY_PATH_G stored the high-bit open
            # path low-ASCII, so no raw saved byte has bit 7 set.
            base = syms.get('OFT_SLOT_BASE', 0xBA00)
            slen = r.peek(base + 68 * f0, 1)[0]
            raw = r.peek(base + 68 * f0 + 1, slen) if slen else []
            hib = [i for i, x in enumerate(raw) if x & 0x80]
            if hib:
                fails.append(f'IB2/F1: F0 saved path kept high bits at '
                             f'{hib} ({bytes(raw)!r}) -- PCPY_PATH_G must mask '
                             f'to 7-bit or the alias compare never matches')
            if canon != '/MAUX/IP/D/F0' or cl != 13:
                fails.append(f'IB2/F1: PRC_CANON must hold /MAUX/IP/D/F0 '
                             f'(len 13), got {canon!r} (len {cl})')
        elif mode == 'rename':
            if before['iobuf'][f0] != 0:
                fails.append('rename: F0 was not parked before the test')
            refused(8, 'IB3 rename of a directory holding a parked file')
            if (rp[9] & 1) or byte != ord('a'):
                fails.append(f'IB3: the parked fd must still read a after the '
                             f'refused rename, got P=${rp[9]:02X} '
                             f'byte={chr(byte)!r}')
        elif mode == 'renamectl':
            if rp[8] & 1:
                fails.append(f'IB3 control: renaming an unrelated directory '
                             f'was refused A=${ra[8]:02X}')
            if (rp[9] & 1) or byte != ord('a'):
                fails.append(f'IB3 control: parked fd read failed after the '
                             f'unrelated rename')
        elif mode == 'closefail':
            if not (rp[8] & 1) or ra[8] != FAULT:
                fails.append(f'IB4: the OPEN that needed a park must report '
                             f'the victim CLOSE error $27, got A=${ra[8]:02X} '
                             f'P=${rp[8]:02X} (ERR_NFILE=$E9 is the flattening '
                             f'the review found)')
            if after['parks'] != 0:
                fails.append(f'IB4: a park was recorded despite the failed '
                             f'CLOSE (parks={after["parks"]})')
            if after['inuse'] != NBUFS or after['iobuf'][f0] == 0:
                fails.append(f'IB4: victim lost its buffer (inuse='
                             f'{after["inuse"]}, F0 iobuf={after["iobuf"][f0]})')
        elif mode == 'pinfull':
            if not (rp[8] & 1) or ra[8] != ERR_NFILE:
                fails.append(f'pinfull: with every buffer pinned the OPEN '
                             f'must fail loudly with ERR_NFILE '
                             f'(${ERR_NFILE:02X}), got A=${ra[8]:02X} '
                             f'P=${rp[8]:02X}')
            if after['parks'] != 0 or after['inuse'] != NBUFS:
                fails.append(f'pinfull: nothing may be parked or freed '
                             f'(parks={after["parks"]}, inuse='
                             f'{after["inuse"]} of {NBUFS})')
            if nfiles_after != nfiles:
                fails.append(f'pinfull: the failed OPEN leaked an OFT '
                             f'entry ({nfiles}->{nfiles_after})')
        elif mode == 'seekfail':
            if (rp[10] & 1) or byte != ord('b'):
                fails.append(f'IB5: with the patch removed the read must '
                             f'resume at b, got P=${rp[10]:02X} '
                             f'byte={chr(byte)!r}')
        return fails
    finally:
        try:
            if saved is not None:
                r.poke(syms['PCLS_RAWREF_A' if mode == 'closefail'
                            else 'PMLI_SMARK_CL'], saved)
        except Exception:
            pass
        try:
            c.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        c.close()


def main():
    if not os.path.exists(PLAY):
        print(f'error: {PLAY} missing -- run make play-image', file=sys.stderr)
        return 2
    syms = symbols(LISTING)
    need = ['OFT_TYPE', 'OFT_IOBUF', 'K_IBF_INUSE', 'K_PARK_CNT',
            'K_IBF_HIWAT',
            'PCLS_RAWREF_A', 'PMLI_SMARK_CL']
    missing = [n for n in need if n not in syms]
    if missing:
        print(f'error: {missing} absent from {LISTING}', file=sys.stderr)
        return 2
    modes = sys.argv[1:] or MODES
    allfail = []
    for m in modes:
        allfail += run_mode(m, syms)
    if allfail:
        for f in allfail:
            print(f'[check-iobuf] FAIL: {f}', file=sys.stderr)
        return 1
    print(f'[check-iobuf] PASS: {len(modes)} lending regressions -- '
          f'{", ".join(modes)} -- the review\'s IB1-IB5 reproductions all '
          f'refused, propagated, or stayed parked as required, and the '
          f'control unparked at the saved mark')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
