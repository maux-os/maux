#!/usr/bin/env python3
"""check_openrw2_k.py -- one writer joins a read-intent group, the
kernel side (`make check-openrw2-k`; docs/OPEN-RW-2.md,
docs/OPEN-RW-2-NOTES.md).

check_openrw2.py drives the shell.  THIS file drives the kernel with a
generated probe program (the check_openro_k.py shape: $FF00 ABI, one
result slot per call in the probe's own bank, the harness peeking the
OFT / lending tables by symbol from the image's own listing and
poking one kernel helper to inject a fault, as check_iobuf.py does).
The probe is a DSL (class Probe): each call records A and P after it;
`sync()` raises a state byte and spins until the harness pokes the
branch OPERAND (never the opcode: a torn write against a live CPU is
the 2026-09-16 bug that cost a day).

Modes (one boot each; the row names are the brief's):

  meas      sec 2 of the notes, ProDOS facts the design leans on:
            SET_EOF below the mark clamps the mark; a failed SET_MARK
            leaves the mark where it was ($4D).
  order     W4: a second WRITER next to a writer+reader group is $50
            with (a) the writer at the lowest matching OFT slot, (b) a
            reader at the lowest, (c) slots freed and reused so scan
            order and open order differ; a third reader joins every
            time.
  trunc     W5: truncation under readers (virtual marks) -- READ 0
            bytes with no error, GET_MARK = the saved mark, GET_EOF
            without $4D, append <= M still EOF, append past M resumes
            at exactly M, recovery by SEEK_END and by seek 0; live EOF
            (C11) before any flush.
  closeA    W6: the writer leaves a group with a reader still in it;
            its FLUSH is made to FAIL (the wrapper is patched): the
            error reaches the explicit close, nothing is quarantined,
            the group lives on and the last close flushes.
  closeB    W6 control: the same without the patch -- the FLUSH really
            ran (the data is on the disk while the reader is open).
  closeC    W6: the last close FAILS: the page and refnum are
            quarantined -- the pool shrinks by EXACTLY one
            (K_IBF_INUSE, MLI_BUF_USED, K_QUAR_CNT), the error
            reaches the close, the entry and fd are gone.
  park      W7 (+ W10, K_ROOWN): pool pressure parks a group whose
            WRITER holds the live mark with a block proven dirty (the
            disk lags until the park); an injected park-time CLOSE
            failure frees and reuses nothing; after the unpark the
            reader and the writer each continue at their own nonzero
            marks, byte-exact.  DESTROY, file RENAME and ancestor
            RENAME of the mixed group are $50, resident and parked.
  truncpark a group is parked while a reader's mark is virtual: the
            unpark leaves the virtual mark in its slot (0 bytes), and
            the append past it resumes at exactly that offset.
  nm4d      review point: a $4D from anything but a group member's
            mark acquire is still an ERROR (a lone parked entry whose
            reopen SET_MARK is made to answer $4D).
  leak1     review finding: the unpark's SET_MARK fails and its cleanup
            CLOSE works -- the page is freed and NOT counted.
  leak2     ... and the cleanup CLOSE ALSO fails -- the page is kept
            and K_QUAR_CNT counts it, once.
  fork      W8: parent and child write through the SAME writer entry
            (one shared mark); a reader keeps its own mark; a
            NON-final close of the writer entry flushes nothing and
            keeps writer status; the FINAL close flushes and releases
            it.  Pool and park counts return to baseline.
  dup       W8: dup2 over the last writer fd with a failing FLUSH: the
            error is LOST to dup2 (documented), the state is safe.
  spawn     W9: exec of a file a RESIDENT group holds is refused; with
            the group PARKED the spawn works and the group unparks
            byte-exact.
  roown     W11: K_ROOWN across two groups held by two processes,
            alternating over scheduler switches; the invariant (0 or
            a RESIDENT group member) holds at every sample; closing
            the owner's group leaves the other group right.

ASCII only.  Exit 0 green, 1 red (listed), 2 rig problem.
"""
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_posixex as E                                # noqa: E402
import check_openro_k as K                               # noqa: E402
import gate_race as GR                                   # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR    # noqa: E402
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import convert, prodos                        # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'build', 'openrw2')
LISTING = K.LISTING
NBUFS = K.NBUFS

ST = 0x7000
WS = 0x70F0
RA, RP, RT, RM, RB = 0x7100, 0x7200, 0x7300, 0x7400, 0x7800
FAULT = 0x27
LDA_SEC_RTS = [0xA9, FAULT, 0x38, 0x60]            # LDA #$27 ; SEC ; RTS
RANGE_BYTES = [0xA9, 0x4D, 0x38, 0x60]             # LDA #$4D ; SEC ; RTS
D = '/mnt/MAUX/IP/D/'


class Probe:
    """A tiny probe assembler (see the module docstring)."""

    def __init__(self):
        self.code = ''
        self.parms = ''
        self.paths = {}
        self.nslot = 0
        self.nlab = 0
        self.nstate = 0
        self.syncs = {}               # state value -> label
        self.files = {}               # name -> (bytes, type, aux)

    # -- plumbing ------------------------------------------------------
    def lab(self, stem):
        self.nlab += 1
        return f'{stem}{self.nlab}'

    def path(self, name):
        self.paths[name] = D + name
        return f'N{name}'

    def call(self, lab, sysname, post=''):
        s = self.nslot
        self.nslot += 1
        assert s < 128, 'too many call slots'
        self.code += f'''            lda #<{lab}
            ldx #>{lab}
            ldy #{sysname}
            jsr $FF00
            sta ${RA + s:04X}
            php
            pla
            sta ${RP + s:04X}
''' + post
        return s

    def raw(self, s):
        self.code += s

    # -- calls ---------------------------------------------------------
    def open(self, name, ro):
        lab = self.lab('P')
        self.parms += f'''{lab}          dfb {'$83' if ro else '3'}
            da {self.path(name)}
            da 0
            dfb 0
'''
        return self.call(lab, 'SYS_OPEN')

    def read(self, fd, n=1):
        """READ n (<=16) bytes: data at RB+slot*16, count at RT+slot."""
        assert n <= 16
        s = self.nslot
        lab = self.lab('RD')
        self.parms += f'''{lab}          dfb 4,{fd}
            da ${RB + s * 16:04X}
            da {n},0
'''
        return self.call(lab, 'SYS_READ', f'''            lda {lab}+6
            sta ${RT + s:04X}
''')

    def write(self, fd, data):
        lab = self.lab('WR')
        dl = self.lab('DT')
        self.parms += f'''{dl}          hex {data.hex()}
{lab}          dfb 4,{fd}
            da {dl}
            da {len(data)},0
'''
        s = self.nslot
        return self.call(lab, 'SYS_WRITE', f'''            lda {lab}+6
            sta ${RT + s:04X}
''')

    def _mk(self, sysname, fd, val=None):
        lab = self.lab('MK')
        v = val or 0
        self.parms += f'''{lab}          dfb 2,{fd}
            dfb {v & 255},{(v >> 8) & 255},{v >> 16}
'''
        s = self.nslot
        post = ''.join(f'''            lda {lab}+{2 + i}
            sta ${RM + s * 4 + i:04X}
''' for i in range(3))
        return self.call(lab, sysname, post)

    def getmark(self, fd):
        return self._mk('SYS_GET_MARK', fd)

    def geteof(self, fd):
        return self._mk('SYS_GET_EOF', fd)

    def setmark(self, fd, v):
        return self._mk('SYS_SET_MARK', fd, v)

    def seteof(self, fd, v):
        return self._mk('SYS_SET_EOF', fd, v)

    def close(self, fd):
        lab = self.lab('CL')
        self.parms += f'''{lab}          dfb 1,{fd}
'''
        return self.call(lab, 'SYS_CLOSE')

    def dup2(self, old, new):
        lab = self.lab('DU')
        self.parms += f'''{lab}          dfb {old},{new}
'''
        return self.call(lab, 'SYS_DUP2')

    def unlink(self, name):
        lab = self.lab('UL')
        self.parms += f'''{lab}          dfb 1
            da {self.path(name)}
'''
        return self.call(lab, 'SYS_UNLINK')

    def rename(self, a, b):
        lab = self.lab('RN')
        self.parms += f'''{lab}          dfb 2
            da {self.path(a)},{self.path(b)}
'''
        return self.call(lab, 'SYS_RENAME')

    def rename_dir(self, a, b):
        """RENAME of the directory IP/D to IP/<b> (an ANCESTOR of G)."""
        lab = self.lab('RD')
        la, lb = self.lab('DA'), self.lab('DB')
        pa, pb = '/mnt/MAUX/IP/D', '/mnt/MAUX/IP/' + b
        self.parms += f'''{lab}          dfb 2
            da {la},{lb}
{la}          dfb {len(pa)}
            asc '{pa}'
{lb}          dfb {len(pb)}
            asc '{pb}'
'''
        return self.call(lab, 'SYS_RENAME')

    def spawn(self, name):
        lab = self.lab('SP')
        av, pa = self.lab('AV'), self.lab('SA')
        full = D + name
        self.parms += f'''{lab}          da {pa},{av},0,{av}+2
{av}          da {pa},0
            da 0
{pa}          hex {convert.text_from_host(full.encode('ascii'), high_bit=True).hex()}00
'''
        return self.call(lab, 'SYS_SPAWN')

    def loop_reads(self, fa, fb, n, ta, tb):
        """n times: READ one byte from fd fa into table ta[i], then from
        fd fb into tb[i] (tables are page addresses in the probe's own
        bank).  Long enough that the scheduler preempts it."""
        lab = self.lab('LP')
        pa, pb = self.lab('LA'), self.lab('LB')
        self.parms += f'''{pa}          dfb 4,{fa}
            da $70F4
            da 1,0
{pb}          dfb 4,{fb}
            da $70F5
            da 1,0
'''
        self.raw(f'''            lda #0
            sta $70F8
{lab}       lda #<{pa}
            ldx #>{pa}
            ldy #SYS_READ
            jsr $FF00
            lda $70F4
            ldx $70F8
            sta ${ta:04X},x
            lda #<{pb}
            ldx #>{pb}
            ldy #SYS_READ
            jsr $FF00
            lda $70F5
            ldx $70F8
            sta ${tb:04X},x
            inc $70F8
            lda $70F8
            cmp #{n}
            bne {lab}
''')

    def wait(self):
        self.raw(f'''            lda #<WP
            ldx #>WP
            ldy #SYS_WAIT
            jsr $FF00
''')

    def fork(self):
        self.raw(f'''            lda #$FF
            tax
            ldy #SYS_FORK
            jsr $FF00
            bcc FORKOK
BAD         lda #$EE
            sta ${ST:04X}
            bra BAD
FORKOK      cmp #0
            bne PARENT
            jmp CHILD
PARENT
''')

    # -- harness handshakes -------------------------------------------
    def sync(self):
        """Raise a new state value and spin; returns the state value."""
        self.nstate += 1
        v = 0x20 + self.nstate
        lab = f'SYN{v:02X}'
        self.syncs[v] = lab
        self.code += f'''            lda #${v:02X}
            sta ${ST:04X}
{lab}       bra {lab}
'''
        return v

    def done(self):
        self.code += f'''            lda #$AA
            sta ${ST:04X}
DONE        bra DONE
'''

    def child(self):
        self.code += 'CHILD\n'

    def exit(self):
        self.code += f'''            lda #<XP
            ldx #>XP
            ldy #SYS_EXIT
            jsr $FF00
CSPIN       bra CSPIN
'''

    def source(self):
        s = f'''            xc
            org $0800
            dsk probe.bin
''' + ''.join(f'            put ../../inc/{f}.equ\n'
              for f in ('sc.proc', 'sc.file', 'sc.fd')) + f'''START       lda #$11
            sta ${ST:04X}
''' + self.code + f'''XP          dfb 0
WP          da ${WS:04X}
''' + self.parms
        for k, p in self.paths.items():
            s += f'''N{k}          dfb {len(p)}
            asc '{p}'
'''
        return s


# ---------------------------------------------------------------------
# staging and the rig
# ---------------------------------------------------------------------
def build(mode, probe, play):
    os.makedirs(OUT, exist_ok=True)
    src = os.path.join(OUT, 'probe.s')
    with open(src, 'w') as f:
        f.write(probe.source())
    subprocess.run(['merlin32', '-v1', src], check=True,
                   stdout=subprocess.DEVNULL, cwd=OUT)
    binp = os.path.join(OUT, 'probe.bin')
    ps = K.symbols(binp + '_Output.txt')
    img = os.path.join(OUT, f'{mode}.po')
    shutil.copy(play, img)
    prodos.mount(img)
    try:
        prodos.mkdir('/mnt/MAUX/IP')
        prodos.mkdir('/mnt/MAUX/IP/D')
        prodos.write('/mnt/MAUX/IP/PROBE', open(binp, 'rb').read(),
                     file_type=6, aux_type=0x800)
        for name, (data, ftype, aux) in probe.files.items():
            prodos.write(f'/mnt/MAUX/IP/D/{name}', data, file_type=ftype,
                         aux_type=aux)
    finally:
        prodos.unmount('MAUX')
    return img, ps


class Ctx:
    """Everything a mode's checker needs."""

    def __init__(self, client, syms, ps, probe, mode):
        self.c = client
        self.syms = syms
        self.ps = ps
        self.p = probe
        self.mode = mode
        self.r = K.Rig(client, syms)
        self.fails = []
        self.pb = None              # the probe's (parent) bank
        self.state = {}             # sync value -> state value

    # -- checks --------------------------------------------------------
    def check(self, cond, msg):
        if not cond:
            self.fails.append(f'{self.mode}: {msg}')
        return bool(cond)

    # -- the probe's cells (default: the parent bank) -------------------
    def ra(self, slot, bank=None):
        return self.r.peek(RA + slot, 1, bank or self.pb)[0]

    def carry(self, slot, bank=None):
        return self.r.peek(RP + slot, 1, bank or self.pb)[0] & 1

    def rt(self, slot, bank=None):
        return self.r.peek(RT + slot, 1, bank or self.pb)[0]

    def rb(self, slot, n, bank=None):
        return bytes(self.r.peek(RB + slot * 16, n, bank or self.pb))

    def rm(self, slot, bank=None):
        b = self.r.peek(RM + slot * 4, 3, bank or self.pb)
        return b[0] | (b[1] << 8) | (b[2] << 16)

    def ok(self, slot, what, bank=None):
        """The call in `slot` succeeded (carry clear)."""
        if self.carry(slot, bank):
            self.fails.append(f'{self.mode}: {what}: refused '
                              f'(A=${self.ra(slot, bank):02X})')
            return False
        return True

    def refused(self, slot, code, what, bank=None):
        c, a = self.carry(slot, bank), self.ra(slot, bank)
        if not c or a != code:
            self.fails.append(f'{self.mode}: {what}: want carry set and '
                              f'A=${code:02X}, got carry {c} A=${a:02X}')
            return False
        return True

    # -- the kernel's cells ----------------------------------------------
    def kb(self, name, n=1):
        return self.r.peek(self.syms[name], n)

    def k1(self, name):
        return self.kb(name)[0]

    def bufused(self):
        return self.kb('MLI_BUF_USED', NBUFS)

    def tables(self):
        t = self.r.tables()
        t['quar'] = self.k1('K_QUAR_CNT')
        t['clserr'] = self.k1('K_CLSERR')
        t['bufused'] = self.bufused()
        t['paths'] = self.r.paths(t['types'])
        return t

    def entries(self, tb, name='G'):
        want = '/MAUX/IP/D/' + name
        return sorted(i for i, p in tb['paths'].items()
                      if p.upper() == want)

    def find_probe(self, steps=400):
        """The probe's bank: the first bank whose state byte is any
        state the probe can be in (a short probe is past $11 already)."""
        ok = {0x11, 0xAA} | set(self.p.syncs)
        for _ in GR.polls(self.c, steps, 200000):
            for b in range(1, 16):
                if self.r.peek(ST, 1, b)[0] in ok:
                    return b
        return None

    # -- sync handshakes --------------------------------------------------
    def wait(self, v, steps=600, quantum=200000):
        for _ in GR.polls(self.c, steps, quantum):
            for b in range(1, 16):
                if self.r.peek(ST, 1, b) == [v]:
                    return b
        self.fails.append(f'{self.mode}: never reached state ${v:02X} '
                          f'(parent bank {self.pb})')
        return None

    def release(self, v, bank):
        K.release(self.r, self.ps[self.p.syncs[v]], bank)

    def patch(self, sym, bytes_=LDA_SEC_RTS):
        """Replace the first bytes of kernel routine `sym`; returns the
        original bytes for restore()."""
        a = self.syms[sym]
        saved = self.r.peek(a, len(bytes_))
        self.r.poke(a, bytes_)
        return (a, saved)

    def restore(self, token):
        a, saved = token
        self.r.poke(a, saved)

    def disk(self, name):
        """The file's bytes as they are ON THE DISK right now."""
        path = os.path.join(OUT, f'{self.mode}-export.po')
        r = self.c.call_tool('image_export', {'unit': 1, 'path': path})
        if r.get('ok') is False:
            self.fails.append(f'{self.mode}: image_export failed: {r}')
            return None
        prodos.mount(path, replace=True, readonly=True)
        try:
            return bytes(prodos.read(f'/mnt/MAUX/IP/D/{name}'))
        finally:
            prodos.unmount('MAUX')


def ch(bs):
    return bytes(bs).decode('latin-1')


def scrub_state(c):
    """Delegates to E.scrub_probe_state; ST here is sh's TRAPTAB base.
    Kept as a name because check_oappend and oappend_cycles drive this
    module's Ctx and call it through K2."""
    E.scrub_probe_state(c, ST)


def run_mode(mode, play):
    spec = MODES[mode]
    probe = Probe()
    spec['build'](probe)
    img, ps = build(mode, probe, play)
    syms = K.symbols(LISTING)
    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
    c = MCPClient([SUPERVISOR], env)
    try:
        c.initialize()
        E.boot_group(c, img)
        scrub_state(c)
        E.V.t(c, '/mnt/MAUX/IP/PROBE\r')
        x = Ctx(c, syms, ps, probe, mode)
        x.pb = x.find_probe()
        if x.pb is None:
            return [f'{mode}: the probe never started']
        spec['check'](x)
        return x.fails
    finally:
        c.close()


# ---------------------------------------------------------------------
# meas -- the two ProDOS facts of notes sec 2
# ---------------------------------------------------------------------
def b_meas(p):
    p.files['P'] = (b'abcdefghijklmnopqrst', 4, 0)
    s = {}
    s['open'] = p.open('P', False)
    s['sm'] = p.setmark(3, 15)
    s['gm0'] = p.getmark(3)
    s['se'] = p.seteof(3, 5)
    s['gm1'] = p.getmark(3)
    s['ge1'] = p.geteof(3)
    s['bad'] = p.setmark(3, 9)
    s['gm2'] = p.getmark(3)
    s['cl'] = p.close(3)
    p.done()
    p.s = s


def c_meas(x):
    if x.wait(0xAA) is None:
        return
    s = x.p.s
    x.ok(s['sm'], 'SET_MARK 15')
    x.check(x.rm(s['gm0']) == 15, f'mark before the cut {x.rm(s["gm0"])}')
    x.ok(s['se'], 'SET_EOF 5 below the mark')
    m1, e1 = x.rm(s['gm1']), x.rm(s['ge1'])
    print(f'[check-openrw2-k] meas: SET_EOF(5) with the mark at 15 -> '
          f'mark {m1}, eof {e1}', flush=True)
    x.check(e1 == 5, f'EOF after SET_EOF(5) is {e1}')
    x.check(m1 == 5, f'ProDOS must CLAMP the mark to the new EOF '
            f'(got {m1}); the design assumes the writer\'s own mark is '
            f'legal after its truncation')
    x.refused(s['bad'], 0x4D, 'SET_MARK past EOF (MLIE_RANGE)')
    m2 = x.rm(s['gm2'])
    print(f'[check-openrw2-k] meas: failed SET_MARK(9) left the mark at '
          f'{m2}', flush=True)
    x.check(m2 == m1, f'a FAILED SET_MARK must leave the mark alone: '
            f'{m1} before, {m2} after')


# ---------------------------------------------------------------------
# order -- W4, admission is a count, not a first-peer test
# ---------------------------------------------------------------------
def b_order(p):
    p.files['G'] = (b'abcdefgh', 4, 0)
    p.files['F1'] = (b'abcdef', 4, 0)
    s = {}
    # (a) writer first: writer at the lowest matching OFT slot
    s['aw'] = p.open('G', False)                 # fd 3
    s['ar'] = p.open('G', True)                  # fd 4
    s['aw2'] = p.open('G', False)                # $50
    s['ar3'] = p.open('G', True)                 # fd 5
    s['a_sync'] = p.sync()
    for fd in (3, 4, 5):
        p.close(fd)
    # (b) reader first: a reader at the lowest matching slot
    s['br'] = p.open('G', True)                  # fd 3
    s['bw'] = p.open('G', False)                 # fd 4
    s['bwr'] = p.write(4, b'x')                  # the JOINED writer writes
    s['bw2'] = p.open('G', False)                # $50
    s['br3'] = p.open('G', True)                 # fd 5
    s['b_sync'] = p.sync()
    for fd in (3, 4, 5):
        p.close(fd)
    # (c) slots freed and reused: the READER sits in a LOWER OFT slot
    # than the writer although it was opened later
    s['cd'] = p.open('F1', False)                # fd 3, OFT slot x
    s['cw'] = p.open('G', False)                 # fd 4, slot x+1
    p.close(3)                                   # slot x is free
    s['cr'] = p.open('G', True)                  # fd 3, reuses slot x
    s['cw2'] = p.open('G', False)                # $50
    s['cr3'] = p.open('G', True)                 # fd 5
    s['c_sync'] = p.sync()
    for fd in (3, 4, 5):
        p.close(fd)
    s['z'] = p.open('G', False)                  # everything is gone
    p.close(3)
    p.done()
    p.s = s


def c_order(x):
    s = x.p.s
    for tag, first_is_writer in (('a', True), ('b', False), ('c', False)):
        if x.wait(s[f'{tag}_sync']) is None:
            return
        tb = x.tables()
        es = x.entries(tb)
        flags = [tb['pipe'][i] for i in es]
        wr = [i for i in es if not tb['pipe'][i] & 0x80]
        print(f'[check-openrw2-k] order ({tag}): G entries {es} flags '
              f'{[hex(f) for f in flags]}', flush=True)
        x.check(len(es) == 3, f'({tag}) want 3 members, found {es}')
        x.check(len(wr) == 1, f'({tag}) want exactly ONE writer entry, '
                f'found {wr}')
        if es and wr:
            if first_is_writer:
                x.check(wr[0] == es[0], f'({tag}) setup: the writer must '
                        f'sit at the LOWEST matching slot ({es}, writer '
                        f'{wr})')
            else:
                x.check(wr[0] != es[0], f'({tag}) setup: a READER must '
                        f'sit at the lowest matching slot ({es}, writer '
                        f'{wr})')
        x.check(len({tb['iobuf'][i] for i in es}) == 1,
                f'({tag}) one shared buffer, got '
                f'{[tb["iobuf"][i] for i in es]}')
        x.release(s[f'{tag}_sync'], x.pb)
    if x.wait(0xAA) is None:
        return
    x.ok(s['aw'], '(a) first writer')
    x.ok(s['ar'], '(a) reader joins the writer')
    x.refused(s['aw2'], 0x50, '(a) a SECOND writer')
    x.ok(s['ar3'], '(a) a third reader joins')
    x.ok(s['br'], '(b) first reader')
    x.ok(s['bw'], '(b) the writer joins the reader')
    x.ok(s['bwr'], '(b) the writer that JOINED a reader can write '
         '(it must not inherit OFTF_RO)')
    x.refused(s['bw2'], 0x50, '(b) a SECOND writer')
    x.ok(s['br3'], '(b) a third reader joins')
    x.ok(s['cd'], '(c) a dummy open')
    x.ok(s['cw'], '(c) the writer')
    x.ok(s['cr'], '(c) a reader in a lower slot joins')
    x.refused(s['cw2'], 0x50, '(c) a SECOND writer')
    x.ok(s['cr3'], '(c) a third reader joins')
    x.ok(s['z'], 'a writer opens once the group is gone')


# ---------------------------------------------------------------------
# trunc -- W5
# ---------------------------------------------------------------------
G32 = b'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef'


def b_trunc(p):
    p.files['G'] = (G32, 4, 0)
    s = {}
    s['r1'] = p.open('G', True)                  # fd 3: R
    s['r2'] = p.open('G', True)                  # fd 4: R2
    s['r3'] = p.open('G', True)                  # fd 5: R3
    s['w'] = p.open('G', False)                  # fd 6: the writer
    s['rd1'] = p.read(3, 12)                     # R at 12
    s['rd2'] = p.read(4, 12)
    s['rd3'] = p.read(5, 12)
    s['eof0'] = p.geteof(6)                      # 32, via the writer
    s['cut'] = p.seteof(6, 0)
    s['eof1'] = p.geteof(3)                      # via R: no $4D
    s['m1'] = p.getmark(3)                       # 12 (virtual)
    s['rv1'] = p.read(3, 1)                      # 0 bytes, no error
    s['wz'] = p.write(6, b'z')
    s['eof2'] = p.geteof(3)                      # 1: live EOF
    s['rv2'] = p.read(3, 1)
    # R2 recovers by lseek(SEEK_END): GET_EOF then SET_MARK
    s['e2'] = p.geteof(4)
    s['sm2'] = p.setmark(4, 1)
    s['m2'] = p.getmark(4)
    s['rd2b'] = p.read(4, 1)                     # EOF: 0 bytes
    # R3 recovers by lseek(0)
    s['sm3'] = p.setmark(5, 0)
    s['rd3b'] = p.read(5, 1)                     # 'z'
    s['t1'] = p.sync()
    s['wq'] = p.write(6, b'qqq')                 # EOF 4 <= 12
    s['rv3'] = p.read(3, 1)
    s['m3'] = p.getmark(3)                       # still 12
    s['wa'] = p.write(6, b'ABCDEFGHIJKLMNOPQRST')   # EOF 24 > 12
    s['rres'] = p.read(3, 4)                     # exactly offset 12
    s['m4'] = p.getmark(3)                       # 16
    s['eof3'] = p.geteof(6)
    for fd in (3, 4, 5, 6):
        p.close(fd)
    p.done()
    p.s = s


def c_trunc(x):
    s = x.p.s
    if x.wait(s['t1']) is None:
        return
    for k in ('r1', 'r2', 'r3', 'w', 'rd1', 'rd2', 'rd3', 'eof0', 'cut',
              'eof1', 'm1', 'wz', 'eof2', 'e2', 'sm2', 'm2', 'sm3'):
        x.ok(s[k], f'step {k}')
    x.check(ch(x.rb(s['rd1'], 12)) == 'ABCDEFGHIJKL' and
            x.rt(s['rd1']) == 12, 'R read the first 12 bytes')
    x.check(x.rm(s['eof0']) == 32, f'EOF before the cut: '
            f'{x.rm(s["eof0"])}')
    x.check(x.rm(s['eof1']) == 0, f'GET_EOF through the reader after the '
            f'cut must be 0 with no $4D, got {x.rm(s["eof1"])}')
    x.check(x.rm(s['m1']) == 12, f'GET_MARK of the virtual reader must '
            f'return its saved mark 12, got {x.rm(s["m1"])}')
    x.ok(s['rv1'], 'READ at a virtual mark (carry clear, no error)')
    x.check(x.rt(s['rv1']) == 0, f'READ at a virtual mark returned '
            f'{x.rt(s["rv1"])} bytes, want 0')
    x.check(x.rm(s['eof2']) == 1, f'live EOF after the write, before any '
            f'flush: {x.rm(s["eof2"])}, want 1')
    x.ok(s['rv2'], 'READ at a virtual mark, EOF 1')
    x.check(x.rt(s['rv2']) == 0, 'READ at a virtual mark, EOF 1: 0 bytes')
    x.check(x.rm(s['e2']) == 1, 'R2 GET_EOF is 1')
    x.check(x.rm(s['m2']) == 1, 'R2 recovered by SEEK_END: mark = EOF')
    x.ok(s['rd2b'], 'R2 read at EOF after recovering')
    x.check(x.rt(s['rd2b']) == 0, 'R2 reads 0 bytes at EOF')
    x.ok(s['rd3b'], 'R3 read after seek 0')
    x.check(ch(x.rb(s['rd3b'], 1)) == 'z' and x.rt(s['rd3b']) == 1,
            f'R3 recovered by seek 0 reads z, got '
            f'{ch(x.rb(s["rd3b"], 1))!r}')
    tb = x.tables()
    es = x.entries(tb)
    print(f'[check-openrw2-k] trunc: at t1 K_ROOWN={tb["owner"]} entries '
          f'{es}', flush=True)
    # entries in open order are r1 r2 r3 w; the reader R (virtual) is
    # es[0] unless slots were reordered (they were not)
    x.check(tb['owner'] != es[0], 'a virtual member must not be named by '
            'K_ROOWN')
    x.release(s['t1'], x.pb)
    if x.wait(0xAA) is None:
        return
    x.ok(s['wq'], 'append qqq')
    x.ok(s['rv3'], 'READ at the virtual mark, EOF 4 <= 12')
    x.check(x.rt(s['rv3']) == 0, 'EOF still <= M: the reader reads EOF')
    x.check(x.rm(s['m3']) == 12, 'GET_MARK still 12')
    x.ok(s['wa'], 'append past M')
    x.ok(s['rres'], 'READ after the append passed M')
    got = ch(x.rb(s['rres'], 4))
    x.check(got == 'IJKL' and x.rt(s['rres']) == 4,
            f'the reader resumes at exactly offset M=12: read {got!r}, '
            f'want IJKL (file is z qqq ABCDEFGHIJKLMNOPQRST)')
    x.check(x.rm(s['m4']) == 16, 'mark after the resumed read is 16')
    x.check(x.rm(s['eof3']) == 24, 'final EOF 24')


# ---------------------------------------------------------------------
# W6 -- close ownership
# ---------------------------------------------------------------------
def b_close(p, final_fail=False):
    p.files['G'] = (b'abcdef', 4, 0)
    p.files['F1'] = (b'abcdef', 4, 0)
    s = {}
    s['s0'] = p.sync()                           # baseline (+ patch)
    if not final_fail:
        s['w'] = p.open('G', False)              # fd 3
        s['r'] = p.open('G', True)               # fd 4
        s['sm'] = p.setmark(3, 6)
        s['wr'] = p.write(3, b'XYZ')             # dirty, EOF 9
        s['a1'] = p.sync()
        s['c1'] = p.close(3)                     # the writer leaves
        s['a2'] = p.sync()
        s['rd'] = p.read(4, 9)
        s['c2'] = p.close(4)                     # the last member
        s['a3'] = p.sync()
    else:
        s['w'] = p.open('G', False)              # fd 3
        s['sm'] = p.setmark(3, 6)
        s['wr'] = p.write(3, b'XYZ')
        s['a1'] = p.sync()
        s['c1'] = p.close(3)                     # the last close FAILS
        s['a2'] = p.sync()
        s['o1'] = p.open('F1', False)            # a normal cycle ...
        s['c3'] = p.close(3)
        s['o2'] = p.open('G', False)             # ProDOS still holds it
        s['a3'] = p.sync()
    p.done()
    p.s = s


def c_closeA(x, inject=True):
    s = x.p.s
    if x.wait(s['s0']) is None:
        return
    base = x.tables()
    x.release(s['s0'], x.pb)
    if x.wait(s['a1']) is None:
        return
    for k in ('w', 'r', 'sm', 'wr'):
        x.ok(s[k], f'step {k}')
    d = x.disk('G')
    x.check(d == b'abcdef', f'setup: the block must be DIRTY (not yet on '
            f'the disk) when the writer leaves, disk holds {d!r}')
    t1 = x.tables()
    tok = x.patch('PMLI_FLSH_CL') if inject else None
    x.release(s['a1'], x.pb)
    if x.wait(s['a2']) is None:
        return
    t2 = x.tables()
    if inject:
        x.refused(s['c1'], FAULT, 'the writer\'s close with a failing '
                  'FLUSH (the error reaches the explicit close)')
        x.check(t2['clserr'] == FAULT, f'K_CLSERR ${t2["clserr"]:02X}')
        x.restore(tok)
    else:
        x.ok(s['c1'], 'the writer\'s close (control)')
        d = x.disk('G')
        x.check(d == b'abcdefXYZ', f'the writer\'s FLUSH must put its data '
                f'on the disk while the reader is still open: {d!r}')
    x.check(t2['quar'] == t1['quar'], 'a failed FLUSH quarantines nothing')
    x.check(t2['inuse'] == t1['inuse'], f'a FLUSH failure frees no buffer '
            f'(inuse {t1["inuse"]} -> {t2["inuse"]})')
    es = x.entries(t2)
    x.check(len(es) == 1 and t2['pipe'][es[0]] & 0x80,
            f'only the reader is left in the group, entries {es}')
    x.release(s['a2'], x.pb)
    if x.wait(s['a3']) is None:
        return
    x.ok(s['rd'], 'the reader reads on')
    x.check(ch(x.rb(s['rd'], 9)) == 'abcdefXYZ' and x.rt(s['rd']) == 9,
            f'the reader sees the live data: {ch(x.rb(s["rd"], 9))!r}')
    x.ok(s['c2'], 'the last member\'s CLOSE')
    d = x.disk('G')
    x.check(d == b'abcdefXYZ', f'after the last close the disk has it: '
            f'{d!r}')
    t3 = x.tables()
    x.check(t3['inuse'] == base['inuse'] and t3['quar'] == base['quar'],
            f'pool back to baseline (inuse {base["inuse"]} -> '
            f'{t3["inuse"]}, quar {base["quar"]} -> {t3["quar"]})')


def c_closeB(x):
    c_closeA(x, inject=False)


def c_closeC(x):
    s = x.p.s
    if x.wait(s['s0']) is None:
        return
    base = x.tables()
    x.release(s['s0'], x.pb)
    if x.wait(s['a1']) is None:
        return
    for k in ('w', 'sm', 'wr'):
        x.ok(s[k], f'step {k}')
    t1 = x.tables()
    es = x.entries(t1)
    x.check(len(es) == 1, f'setup: one open of G, {es}')
    bid = t1['iobuf'][es[0]] if es else 0
    x.check(t1['inuse'] == base['inuse'] + 1, 'setup: the open took one '
            'buffer')
    tok = x.patch('PCLS_RAWREF_A')
    x.release(s['a1'], x.pb)
    if x.wait(s['a2']) is None:
        return
    t2 = x.tables()
    x.refused(s['c1'], FAULT, 'the last close with a failing CLOSE')
    x.restore(tok)
    x.check(t2['clserr'] == FAULT, f'K_CLSERR ${t2["clserr"]:02X}')
    x.check(t2['quar'] == t1['quar'] + 1, f'K_QUAR_CNT must count the '
            f'quarantine: {t1["quar"]} -> {t2["quar"]}')
    x.check(t2['inuse'] == t1['inuse'], f'the failed CLOSE must NOT free '
            f'the page: K_IBF_INUSE {t1["inuse"]} -> {t2["inuse"]}')
    x.check(bid and t2['bufused'][bid - 1] == 1, f'MLI_BUF_USED[{bid}] '
            f'must stay set: {t2["bufused"]}')
    x.check(not x.entries(t2), 'the OFT entry is gone')
    x.release(s['a2'], x.pb)
    if x.wait(s['a3']) is None:
        return
    x.ok(s['o1'], 'a normal open afterwards')
    x.ok(s['c3'], 'and its close')
    x.refused(s['o2'], 0x50, 'ProDOS still holds the quarantined refnum '
              '(the injected fault never reached it)')
    t3 = x.tables()
    drop = (NBUFS - base['inuse']) - (NBUFS - t3['inuse'])
    print(f'[check-openrw2-k] closeC: pool {NBUFS - base["inuse"]} free '
          f'before, {NBUFS - t3["inuse"]} free after (one failed close); '
          f'quar {t3["quar"]}', flush=True)
    x.check(drop == 1, f'the pool must shrink by EXACTLY one buffer, '
            f'shrank by {drop}')
    x.check(t3['quar'] == base['quar'] + 1, 'exactly one quarantine')


# ---------------------------------------------------------------------
# the park scaffold: the parent holds `held` (group fds already open)
# plus nfree others, forks; the child closes its copies, fills the pool
# to full-1, raises READY; the harness releases it and its next open
# is the one that parks.
# ---------------------------------------------------------------------
def park_parent(p, nfree, s):
    for i in range(1, nfree + 1):
        p.files[f'F{i}'] = (b'abcdef', 4, 0)
        p.open(f'F{i}', False)
    for i in range(nfree + 1, NBUFS + 2):
        p.files[f'F{i}'] = (b'abcdef', 4, 0)
    p.fork()


def park_child_fill(p, nfree, nclose=5):
    """Child: drop the inherited copies, open until the pool is FULL."""
    for fd in range(3, 3 + nclose):
        p.close(fd)
    first = nfree + 1
    for i in range(first, first + NBUFS - 1 - nfree):
        p.open(f'F{i}', False)
    return first + NBUFS - 1 - nfree          # the parking file's number


def lru_ok(x, tb, members):
    v = K.lru_victim(x.r, tb)
    return v in members, v


def b_park(p):
    p.files['G'] = (b'abcdefgh', 4, 0)
    s = {}
    s['r'] = p.open('G', True)                   # fd 3
    s['w'] = p.open('G', False)                  # fd 4
    s['rd0'] = p.read(3, 3)                      # R mark 3 ('abc')
    s['sm'] = p.setmark(4, 8)
    s['wr'] = p.write(4, b'XYZ')                 # dirty; W holds the mark
    nfree = 3                                    # fds 5,6,7
    park_parent(p, nfree, s)
    p.wait()
    # after the child is gone: unpark through the saved marks
    s['rd1'] = p.read(3, 3)                      # R from 3: 'def'
    s['wr2'] = p.write(4, b'Q')                  # W from 11
    s['sm0'] = p.setmark(3, 0)
    s['rall'] = p.read(3, 12)                    # the whole file
    s['m_r'] = p.getmark(3)
    s['m_w'] = p.getmark(4)
    p.close(3)
    p.close(4)
    s['end'] = p.sync()
    p.done()
    p.child()
    nxt = park_child_fill(p, nfree)
    # identity, RESIDENT group
    s['u1'] = p.unlink('G')
    s['n1'] = p.rename('G', 'G2')
    s['d1'] = p.rename_dir('D', 'D2')
    s['ready'] = p.sync()
    s['pk_fail'] = p.open(f'F{nxt}', False)      # patched: $27
    s['ready1b'] = p.sync()
    s['pk'] = p.open(f'F{nxt}', False)           # parks the group
    # identity, PARKED group
    s['u2'] = p.unlink('G')
    s['n2'] = p.rename('G', 'G2')
    s['d2'] = p.rename_dir('D', 'D2')
    s['ready2'] = p.sync()
    p.exit()
    p.s = s


def c_park(x):
    s = x.p.s
    pb = x.pb
    cb = x.wait(s['ready'])
    if cb is None:
        return
    for k in ('r', 'w', 'rd0', 'sm', 'wr'):
        x.ok(s[k], f'parent {k}', pb)
    x.check(ch(x.rb(s['rd0'], 3, pb)) == 'abc', 'R read abc')
    tb = x.tables()
    es = x.entries(tb)
    print(f'[check-openrw2-k] park: child bank {cb}, inuse={tb["inuse"]} '
          f'parks={tb["parks"]} G entries {es} flags '
          f'{[hex(tb["pipe"][i]) for i in es]} owner={tb["owner"]}',
          flush=True)
    wr = [i for i in es if not tb['pipe'][i] & 0x80]
    x.check(len(es) == 2 and len(wr) == 1, f'setup: a mixed group {es}')
    x.check(tb['owner'] in wr, f'setup: the WRITER must hold the live '
            f'mark (K_ROOWN={tb["owner"]}, writer {wr})')
    x.check(tb['inuse'] == NBUFS, f'setup: the pool must be FULL '
            f'({tb["inuse"]} of {NBUFS})')
    ok_, v = lru_ok(x, tb, es)
    x.check(ok_, f'setup: the LRU victim (slot {v}) must be a group '
            f'member {es}')
    d = x.disk('G')
    x.check(d == b'abcdefgh', f'setup: the writer\'s block must be DIRTY '
            f'at the moment of the park (disk lags): disk {d!r}')
    # W10 resident: refused $50
    x.refused(s['u1'], 0x50, 'DESTROY of a resident mixed group', cb)
    x.refused(s['n1'], 0x50, 'file RENAME of a resident mixed group', cb)
    x.refused(s['d1'], 0x50, 'ancestor RENAME of a resident mixed group',
              cb)
    # injected park-time CLOSE failure: nothing is freed or reused
    tok = x.patch('PCLS_RAWREF_A')
    x.release(s['ready'], cb)
    if x.wait(s['ready1b']) is None:
        return
    t2 = x.tables()
    x.restore(tok)
    x.refused(s['pk_fail'], FAULT, 'the park-time CLOSE failure reaches '
              'the open that needed the park', cb)
    x.check(t2['parks'] == 0, f'no park recorded: {t2["parks"]}')
    x.check(all(t2['iobuf'][i] for i in es), 'the group stays RESIDENT')
    x.check(t2['inuse'] == NBUFS and t2['bufused'] == [1] * NBUFS,
            f'no buffer freed or reused: inuse {t2["inuse"]} '
            f'{t2["bufused"]}')
    x.check(t2['owner'] == tb['owner'], 'K_ROOWN untouched')
    d = x.disk('G')
    x.check(d == b'abcdefgh', 'and nothing reached the disk')
    x.release(s['ready1b'], cb)
    if x.wait(s['ready2']) is None:
        return
    t3 = x.tables()
    print(f'[check-openrw2-k] park: after: parks={t3["parks"]} iobuf '
          f'{[t3["iobuf"][i] for i in es]} owner={t3["owner"]}',
          flush=True)
    x.check(all(t3['iobuf'][i] == 0 for i in es), 'the whole mixed group '
            'parked together')
    x.check(t3['parks'] == 1, f'one group park: {t3["parks"]}')
    x.check(t3['owner'] == 0, f'K_ROOWN must be 0 after the park, got '
            f'{t3["owner"]}')
    d = x.disk('G')
    x.check(d == b'abcdefghXYZ', f'the park\'s CLOSE put the dirty block '
            f'on the disk: {d!r}')
    x.ok(s['pk'], 'the parking open', cb)
    x.refused(s['u2'], 0x50, 'DESTROY of a PARKED mixed group', cb)
    x.refused(s['n2'], 0x50, 'file RENAME of a PARKED mixed group', cb)
    x.refused(s['d2'], 0x50, 'ancestor RENAME of a PARKED mixed group', cb)
    x.release(s['ready2'], cb)
    if x.wait(s['end']) is None:
        return
    x.ok(s['rd1'], 'R read after the unpark', pb)
    x.check(ch(x.rb(s['rd1'], 3, pb)) == 'def', f'R continues at ITS '
            f'mark 3: {ch(x.rb(s["rd1"], 3, pb))!r}')
    x.ok(s['wr2'], 'W write after the unpark', pb)
    x.check(ch(x.rb(s['rall'], 12, pb)) == 'abcdefghXYZQ' and
            x.rt(s['rall'], pb) == 12,
            f'the file is byte-exact: {ch(x.rb(s["rall"], 12, pb))!r}')
    x.check(x.rm(s['m_r'], pb) == 12 and x.rm(s['m_w'], pb) == 12,
            f'marks {x.rm(s["m_r"], pb)} {x.rm(s["m_w"], pb)}')
    d = x.disk('G')
    x.check(d == b'abcdefghXYZQ', f'closed: the disk has it: {d!r}')


# ---------------------------------------------------------------------
# truncpark -- a virtual mark through a park
# ---------------------------------------------------------------------
def b_truncpark(p):
    p.files['G'] = (b'ABCDEFGHIJKLMNOP', 4, 0)
    s = {}
    s['r'] = p.open('G', True)                   # fd 3
    s['w'] = p.open('G', False)                  # fd 4
    s['rd0'] = p.read(3, 5)                      # R at 5
    s['cut'] = p.seteof(4, 2)                    # R is now virtual
    nfree = 3
    park_parent(p, nfree, s)
    p.wait()
    s['rv'] = p.read(3, 1)                       # unpark: 0 bytes
    s['gm'] = p.getmark(3)                       # 5 (kept in the slot)
    s['ge'] = p.geteof(3)                        # 2
    s['wa'] = p.write(4, b'xxxxxxxx')            # W at 2: EOF 10 > 5
    s['rres'] = p.read(3, 3)                     # offset 5: 'xxx'
    p.close(3)
    p.close(4)
    p.done()
    p.child()
    nxt = park_child_fill(p, nfree)
    s['ready'] = p.sync()
    s['pk'] = p.open(f'F{nxt}', False)
    s['ready2'] = p.sync()
    p.exit()
    p.s = s


def c_truncpark(x):
    s = x.p.s
    cb = x.wait(s['ready'])
    if cb is None:
        return
    tb = x.tables()
    es = x.entries(tb)
    x.check(len(es) == 2, f'setup: a group {es}')
    x.release(s['ready'], cb)
    if x.wait(s['ready2']) is None:
        return
    t3 = x.tables()
    x.check(all(t3['iobuf'][i] == 0 for i in es), 'the group parked')
    x.release(s['ready2'], cb)
    if x.wait(0xAA) is None:
        return
    for k in ('r', 'w', 'rd0', 'cut', 'gm', 'ge', 'wa'):
        x.ok(s[k], f'step {k}')
    x.ok(s['rv'], 'READ through the unpark of a virtual member (carry '
         'clear, no error)')
    x.check(x.rt(s['rv']) == 0, f'0 bytes: {x.rt(s["rv"])}')
    x.check(x.rm(s['gm']) == 5, f'the virtual mark stays in the slot: '
            f'{x.rm(s["gm"])}')
    x.check(x.rm(s['ge']) == 2, f'EOF {x.rm(s["ge"])}')
    x.check(ch(x.rb(s['rres'], 3)) == 'xxx' and x.rt(s['rres']) == 3,
            f'the append past M resumes at exactly M=5: '
            f'{ch(x.rb(s["rres"], 3))!r}')


# ---------------------------------------------------------------------
# nm4d -- a $4D that is not a group member's acquire stays an ERROR
# ---------------------------------------------------------------------
def b_nm4d(p):
    p.files['G'] = (b'abcdefgh', 4, 0)
    s = {}
    s['o'] = p.open('G', False)                  # fd 3: a LONE entry
    s['rd0'] = p.read(3, 2)                      # mark 2
    nfree = 3
    park_parent(p, nfree, s)
    p.wait()
    s['sync_p'] = p.sync()                       # (the patch is in)
    s['bad1'] = p.read(3, 1)                     # unpark: SET_MARK $4D
    s['bad2'] = p.read(3, 1)
    s['sync_q'] = p.sync()                       # (the patch is out)
    s['good'] = p.read(3, 1)                     # 'c'
    p.close(3)
    p.done()
    p.child()
    nxt = park_child_fill(p, nfree)
    s['ready'] = p.sync()
    s['pk'] = p.open(f'F{nxt}', False)
    p.exit()
    p.s = s


def c_nm4d(x):
    s = x.p.s
    cb = x.wait(s['ready'])
    if cb is None:
        return
    tb = x.tables()
    es = x.entries(tb)
    x.check(len(es) == 1 and not tb['pipe'][es[0]] & 0x40,
            f'setup: G is a LONE, non-member entry {es} '
            f'{[hex(tb["pipe"][i]) for i in es]}')
    x.release(s['ready'], cb)
    if x.wait(s['sync_p']) is None:
        return
    t2 = x.tables()
    x.check(all(t2['iobuf'][i] == 0 for i in es), 'setup: G parked')
    tok = x.patch('PMLI_SMARK_CL', RANGE_BYTES)
    x.release(s['sync_p'], x.pb)
    if x.wait(s['sync_q']) is None:
        return
    x.restore(tok)
    x.refused(s['bad1'], 0x4D, 'a lone entry\'s failed reopen SET_MARK '
              '($4D) is still an ERROR, not 0 bytes')
    x.refused(s['bad2'], 0x4D, 'and again (the entry stays parked)')
    x.release(s['sync_q'], x.pb)
    if x.wait(0xAA) is None:
        return
    x.ok(s['good'], 'the read once the patch is out')
    x.check(ch(x.rb(s['good'], 1)) == 'c', 'reads c at mark 2')


# ---------------------------------------------------------------------
# leak1 / leak2 -- the unpark's cleanup CLOSE (review of phase K)
# ---------------------------------------------------------------------
def c_leak(x, both):
    s = x.p.s
    cb = x.wait(s['ready'])
    if cb is None:
        return
    x.release(s['ready'], cb)
    if x.wait(s['sync_p']) is None:
        return
    t1 = x.tables()
    toks = [x.patch('PMLI_SMARK_CL')]
    if both:
        toks.append(x.patch('PCLS_RAWREF_A'))
    x.release(s['sync_p'], x.pb)
    if x.wait(s['sync_q']) is None:
        return
    t2 = x.tables()
    for t in reversed(toks):
        x.restore(t)
    x.refused(s['bad1'], FAULT, 'the failed SET_MARK of the unpark')
    print(f'[check-openrw2-k] leak{2 if both else 1}: inuse {t1["inuse"]}'
          f' -> {t2["inuse"]}, quar {t1["quar"]} -> {t2["quar"]}',
          flush=True)
    if both:
        x.check(t2['quar'] == t1['quar'] + 1, f'a cleanup CLOSE that also '
                f'fails keeps the page AND counts it: quar {t1["quar"]} '
                f'-> {t2["quar"]}')
        x.check(t2['inuse'] == t1['inuse'] + 1, f'the kept page stays in '
                f'use: {t1["inuse"]} -> {t2["inuse"]}')
    else:
        x.check(t2['quar'] == t1['quar'], f'a SUCCESSFUL cleanup frees '
                f'the page and must NOT count: quar {t1["quar"]} -> '
                f'{t2["quar"]}')
        x.check(t2['inuse'] == t1['inuse'], f'the page is freed: inuse '
                f'{t1["inuse"]} -> {t2["inuse"]}')
    x.release(s['sync_q'], x.pb)


# ---------------------------------------------------------------------
# fork -- W8
# ---------------------------------------------------------------------
def b_fork(p):
    p.files['G'] = (b'0123', 4, 0)
    s = {}
    s['s0'] = p.sync()                           # baseline + FLUSH patch
    s['r'] = p.open('G', True)                   # fd 3
    s['w'] = p.open('G', False)                  # fd 4
    s['rd0'] = p.read(3, 1)                      # R at 1: '0'
    s['sm'] = p.setmark(4, 4)
    s['wa'] = p.write(4, b'A')
    p.fork()
    p.wait()
    s['wc'] = p.write(4, b'C')
    s['p1'] = p.sync()
    s['cfin'] = p.close(4)                       # the FINAL close: FLUSH
    s['p2'] = p.sync()                           # (patch out)
    s['w2'] = p.open('G', False)                 # writer status released
    s['rd1'] = p.read(3, 3)                      # R: '123'
    s['c2'] = p.close(4)
    s['sm0'] = p.setmark(3, 0)
    s['rall'] = p.read(3, 7)
    p.close(3)
    s['end'] = p.sync()
    p.done()
    p.child()
    s['wb'] = p.write(4, b'B')
    s['cc'] = p.close(4)                         # NON-final: no FLUSH
    s['w3'] = p.open('G', False)                 # writer status kept
    p.exit()
    p.s = s


def c_fork(x):
    s = x.p.s
    if x.wait(s['s0']) is None:
        return
    base = x.tables()
    tok = x.patch('PMLI_FLSH_CL')
    x.release(s['s0'], x.pb)
    if x.wait(s['p1']) is None:
        return
    for k in ('r', 'w', 'rd0', 'sm', 'wa', 'wc'):
        x.ok(s[k], f'parent {k}')
    tb = x.tables()
    es = x.entries(tb)
    x.check(len(es) == 2, f'after the child is gone: one reader and ONE '
            f'writer entry (fork adds no member): {es}')
    # (the child's own verdicts are read by mode fork2, before it exits)
    x.release(s['p1'], x.pb)
    if x.wait(s['p2']) is None:
        return
    t2 = x.tables()
    x.refused(s['cfin'], FAULT, 'the FINAL close of the writer entry '
              'FLUSHes (the patched FLUSH fails and reaches the close)')
    x.restore(tok)
    x.check(t2['clserr'] == FAULT, f'K_CLSERR ${t2["clserr"]:02X}')
    x.check(t2['quar'] == base['quar'], 'no quarantine')
    x.release(s['p2'], x.pb)
    if x.wait(s['end']) is None:
        return
    x.ok(s['w2'], 'a second writer JOINS once the last writer fd closed '
         '(writer status released even though its FLUSH failed)')
    x.ok(s['c2'], 'close of the second writer (unpatched FLUSH)')
    x.ok(s['rd1'], 'R reads on')
    x.check(ch(x.rb(s['rd1'], 3)) == '123', f'the reader kept its own '
            f'mark: {ch(x.rb(s["rd1"], 3))!r}')
    x.check(ch(x.rb(s['rall'], 7)) == '0123ABC' and x.rt(s['rall']) == 7,
            f'parent and child wrote through ONE shared mark, in order: '
            f'{ch(x.rb(s["rall"], 7))!r}')
    t3 = x.tables()
    x.check(t3['inuse'] == base['inuse'] and t3['parks'] == base['parks']
            and t3['quar'] == base['quar'],
            f'pool and park counts back to baseline: inuse '
            f'{base["inuse"]} -> {t3["inuse"]}, parks {base["parks"]} -> '
            f'{t3["parks"]}')


# the child's two verdicts (non-final close succeeded with the FLUSH
# patched in; its writer open was refused) are read BEFORE it exits, by
# a second mode that holds the child at a sync
def b_fork2(p):
    p.files['G'] = (b'0123', 4, 0)
    s = {}
    s['s0'] = p.sync()
    s['r'] = p.open('G', True)
    s['w'] = p.open('G', False)
    s['sm'] = p.setmark(4, 4)
    s['wa'] = p.write(4, b'A')
    p.fork()
    p.wait()
    p.done()
    p.child()
    s['wb'] = p.write(4, b'B')
    s['cc'] = p.close(4)                         # NON-final: no FLUSH
    s['w3'] = p.open('G', False)                 # writer status kept
    s['c_sync'] = p.sync()
    p.exit()
    p.s = s


def c_fork2(x):
    s = x.p.s
    if x.wait(s['s0']) is None:
        return
    tok = x.patch('PMLI_FLSH_CL')
    x.release(s['s0'], x.pb)
    cb = x.wait(s['c_sync'])
    if cb is None:
        return
    x.ok(s['wb'], 'child write', cb)
    x.ok(s['cc'], 'the NON-final close of the writer entry flushes '
         'nothing (a failing FLUSH would have failed it)', cb)
    x.refused(s['w3'], 0x50, 'writer status is KEPT by a non-final '
              'close: a second writer is still refused', cb)
    x.check(x.k1('K_CLSERR') == 0, 'K_CLSERR clean: no FLUSH ran')
    x.restore(tok)
    x.release(s['c_sync'], cb)


# ---------------------------------------------------------------------
# dup -- W8
# ---------------------------------------------------------------------
def b_dup(p):
    p.files['G'] = (b'abcdef', 4, 0)
    s = {}
    s['s0'] = p.sync()
    s['w'] = p.open('G', False)                  # fd 3
    s['r'] = p.open('G', True)                   # fd 4
    s['sm'] = p.setmark(3, 6)
    s['wr'] = p.write(3, b'X')
    s['d1'] = p.sync()                           # (patch in)
    s['dup'] = p.dup2(4, 3)                      # closes the last writer fd
    s['d2'] = p.sync()                           # (patch out)
    s['w2'] = p.open('G', False)                 # fd 5: joins again
    s['rd'] = p.read(3, 7)
    p.close(3)
    p.close(4)
    p.close(5)
    s['d3'] = p.sync()
    p.done()
    p.s = s


def c_dup(x):
    s = x.p.s
    if x.wait(s['s0']) is None:
        return
    base = x.tables()
    x.release(s['s0'], x.pb)
    if x.wait(s['d1']) is None:
        return
    for k in ('w', 'r', 'sm', 'wr'):
        x.ok(s[k], f'step {k}')
    t1 = x.tables()
    tok = x.patch('PMLI_FLSH_CL')
    x.release(s['d1'], x.pb)
    if x.wait(s['d2']) is None:
        return
    t2 = x.tables()
    x.restore(tok)
    x.ok(s['dup'], 'dup2 over the last writer fd (the close error is LOST '
         'to dup2, as Linux; docs/OPEN-RW-2-NOTES.md sec 3.4)')
    x.check(t2['clserr'] == FAULT, f'K_CLSERR ${t2["clserr"]:02X}: the '
            f'FLUSH really ran and failed')
    x.check(t2['quar'] == t1['quar'] and t2['inuse'] == t1['inuse'],
            'state safe: nothing quarantined or freed')
    es = x.entries(t2)
    x.check(len(es) == 1 and t2['pipe'][es[0]] & 0x80,
            f'only the reader entry is left: {es}')
    x.release(s['d2'], x.pb)
    if x.wait(s['d3']) is None:
        return
    x.ok(s['w2'], 'a new writer joins (writer status was released)')
    x.ok(s['rd'], 'read through the dup')
    x.check(ch(x.rb(s['rd'], 7)) == 'abcdefX' and x.rt(s['rd']) == 7,
            f'the dirty byte survived the failed FLUSH: '
            f'{ch(x.rb(s["rd"], 7))!r}')
    t3 = x.tables()
    x.check(t3['inuse'] == base['inuse'] and t3['quar'] == base['quar'],
            'pool back to baseline')


# ---------------------------------------------------------------------
# spawn -- W9
# ---------------------------------------------------------------------
def b_spawn(p):
    true = open(os.path.join(ROOT, 'build', 'true.bin'), 'rb').read()
    p.files['PG'] = (true, 6, 0x800)
    s = {'true': true}
    s['r1'] = p.open('PG', True)                 # fd 3
    s['r2'] = p.open('PG', True)                 # fd 4
    s['w'] = p.open('PG', False)                 # fd 5
    s['rd1'] = p.read(3, 2)                      # R1 at 2
    s['rd2'] = p.read(4, 5)                      # R2 at 5
    s['sp1'] = p.spawn('PG')                     # RESIDENT group: refused
    nfree = 2                                    # fds 6,7
    park_parent(p, nfree, s)
    p.wait()
    s['rd3'] = p.read(3, 2)                      # R1: bytes 2..3
    s['rd4'] = p.read(4, 2)                      # R2: bytes 5..6
    p.close(3)
    p.close(4)
    p.close(5)
    p.done()
    p.child()
    nxt = park_child_fill(p, nfree, nclose=5)
    s['ready'] = p.sync()
    s['pk'] = p.open(f'F{nxt}', False)           # parks the group
    s['sp2'] = p.spawn('PG')                     # PARKED group: works
    p.wait()
    s['ready2'] = p.sync()
    p.exit()
    p.s = s


def c_spawn(x):
    s = x.p.s
    true = s['true']
    cb = x.wait(s['ready'])
    if cb is None:
        return
    for k in ('r1', 'r2', 'w', 'rd1', 'rd2'):
        x.ok(s[k], f'parent {k}')
    x.refused(s['sp1'], 0x50, 'exec of a file a RESIDENT mixed group '
              'holds (ETXTBSY: stays busy)')
    tb = x.tables()
    es = x.entries(tb, 'PG')
    x.check(len(es) == 3, f'setup: a group of three {es}')
    x.check(tb['inuse'] == NBUFS, f'setup: pool full ({tb["inuse"]})')
    x.release(s['ready'], cb)
    if x.wait(s['ready2']) is None:
        return
    t2 = x.tables()
    print(f'[check-openrw2-k] spawn: parked group iobuf '
          f'{[t2["iobuf"][i] for i in es]} parks={t2["parks"]} '
          f'inuse={t2["inuse"]} (pool {NBUFS})', flush=True)
    x.ok(s['pk'], 'the parking open', cb)
    x.ok(s['sp2'], 'spawn of the file a PARKED group holds', cb)
    x.check(all(t2['iobuf'][i] == 0 for i in es), 'the group is still '
            'parked after the loader\'s transient open')
    # the loader needed a pool buffer in a full pool: it parked ONE more
    # victim (counted), and gave its buffer back
    x.check(t2['parks'] == 2, f'the group park plus ONE for the loader\'s '
            f'buffer: parks {t2["parks"]}')
    x.check(t2['inuse'] == NBUFS - 1, f'the loader\'s buffer is back in '
            f'the pool: inuse {t2["inuse"]}, want {NBUFS - 1}')
    x.check(x.r.peek(WS, 1, cb) == [0], 'the spawned file ran and exited 0')
    x.release(s['ready2'], cb)
    if x.wait(0xAA) is None:
        return
    x.check(bytes(x.rb(s['rd3'], 2)) == true[2:4] and
            x.rt(s['rd3']) == 2, f'R1 continues at its mark 2: '
            f'{x.rb(s["rd3"], 2).hex()} want {true[2:4].hex()}')
    x.check(bytes(x.rb(s['rd4'], 2)) == true[5:7],
            f'R2 continues at its mark 5: {x.rb(s["rd4"], 2).hex()} '
            f'want {true[5:7].hex()}')


# ---------------------------------------------------------------------
# roown -- W11
# ---------------------------------------------------------------------
NR = 100
TA, TB = 0x7A00, 0x7B00


def pat(base, n):
    return ''.join(chr(ord(base) + i % 26) for i in range(n))


def b_roown(p):
    p.files['G'] = (pat('a', 160).encode(), 4, 0)
    p.files['H'] = (pat('A', 160).encode(), 4, 0)
    s = {'pa': []}
    s['ro1'] = p.open('G', True)                 # fd 3
    s['ro2'] = p.open('G', True)                 # fd 4
    p.fork()
    p.loop_reads(3, 4, NR, TA, TB)
    s['p1'] = p.sync()
    for i in range(8):
        s['pa'].append((p.read(3, 1), p.read(4, 1)))
    p.wait()
    p.done()
    p.child()
    p.close(3)
    p.close(4)
    s['co1'] = p.open('H', True)                 # fd 3
    s['co2'] = p.open('H', False)                # fd 4: the WRITER
    p.loop_reads(3, 4, NR, TA, TB)
    s['c1'] = p.sync()
    s['cx'] = p.read(3, 1)                       # makes H's member the owner
    s['c2'] = p.sync()
    p.close(3)
    p.close(4)
    s['c3'] = p.sync()
    p.exit()
    p.s = s


def c_roown(x):
    s = x.p.s
    # sample K_ROOWN while both processes run their loops
    seen = []
    bad = []

    def sample():
        tb = x.tables()
        o = tb['owner']
        if o:
            if tb['types'][o] != 3 or tb['iobuf'][o] == 0:
                bad.append((o, tb['types'][o], tb['iobuf'][o]))
            seen.append(tb['paths'].get(o, '?').upper())
    cb = None
    pbk = None
    for _ in GR.polls(x.c, 6000, 3000):
        sample()
        for b in range(1, 16):
            st = x.r.peek(ST, 1, b)[0]
            if st == s['c1']:
                cb = b
            if st == s['p1']:
                pbk = b
        if cb and pbk:
            break
    if not (cb and pbk):
        x.fails.append(f'{x.mode}: both processes never reached their '
                       f'first sync')
        return
    flips = sum(1 for a, b in zip(seen, seen[1:]) if a != b)
    print(f'[check-openrw2-k] roown: {len(seen)} owner samples, '
          f'{flips} group changes, groups seen {sorted(set(seen))}',
          flush=True)
    x.check(not bad, f'K_ROOWN named a non-resident entry: {bad[:3]}')
    x.check(flips >= 4, f'the two groups must ALTERNATE as owner over '
            f'scheduler switches (saw {flips} changes in {len(seen)} '
            f'samples) or the row proves nothing')
    # both loops: each fd read its own file at its own pace
    for tag, bank, base in (('parent G', pbk, 'a'), ('child H', cb, 'A')):
        for fdi, tab in ((0, TA), (1, TB)):
            got = ''.join(ch(x.r.peek(tab, NR, bank)))
            want = pat(base, NR)
            x.check(got == want, f'{tag} fd {3 + fdi} read {got!r}, '
                    f'want {want!r} (a lost mark would show here)')
    # the owner is the child's H group after it reads once more
    x.release(s['c1'], cb)
    if x.wait(s['c2']) is None:
        return
    tb = x.tables()
    o = tb['owner']
    x.check(o and tb['paths'].get(o, '').upper() == '/MAUX/IP/D/H',
            f'after its read the child\'s group holds the mark: '
            f'K_ROOWN={o} {tb["paths"].get(o)}')
    x.release(s['c2'], cb)
    if x.wait(s['c3']) is None:
        return
    tb = x.tables()
    x.check(tb['owner'] == 0, f'the owner\'s group closed: K_ROOWN must '
            f'be 0, got {tb["owner"]}')
    x.check(not x.entries(tb, 'H'), 'H is gone')
    x.release(s['c3'], cb)
    x.release(s['p1'], pbk)
    if x.wait(0xAA) is None:
        return
    for fdi in (0, 1):
        got = ''.join(ch(x.rb(r[fdi], 1)) for r in s['pa'])
        want = pat('a', NR + 8)[NR:]
        x.check(got == want, f'parent fd {3 + fdi} goes on at its own '
                f'mark after the other group closed: {got!r} want '
                f'{want!r}')


MODES = {
    'meas': {'build': b_meas, 'check': c_meas},
    'order': {'build': b_order, 'check': c_order},
    'trunc': {'build': b_trunc, 'check': c_trunc},
    'closeA': {'build': b_close, 'check': c_closeA},
    'closeB': {'build': b_close, 'check': c_closeB},
    'closeC': {'build': lambda p: b_close(p, True), 'check': c_closeC},
    'park': {'build': b_park, 'check': c_park},
    'truncpark': {'build': b_truncpark, 'check': c_truncpark},
    'nm4d': {'build': b_nm4d, 'check': c_nm4d},
    'leak1': {'build': b_nm4d, 'check': lambda x: c_leak(x, False)},
    'leak2': {'build': b_nm4d, 'check': lambda x: c_leak(x, True)},
    'fork': {'build': b_fork, 'check': c_fork},
    'fork2': {'build': b_fork2, 'check': c_fork2},
    'dup': {'build': b_dup, 'check': c_dup},
    'spawn': {'build': b_spawn, 'check': c_spawn},
    'roown': {'build': b_roown, 'check': c_roown},
}


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--play', default=os.path.join(ROOT, 'build',
                                                   'play.po'))
    ap.add_argument('modes', nargs='*', default=list(MODES))
    args = ap.parse_args()
    if not os.path.exists(LISTING):
        print(f'check-openrw2-k: {LISTING} missing -- make play-image')
        return 2
    allf = []
    for m in args.modes:
        f = run_mode(m, os.path.abspath(args.play))
        for x in f:
            print(f'  - {x}')
        print(f'[check-openrw2-k] {m}: {"PASS" if not f else "FAIL"}',
              flush=True)
        allf += f
    if allf:
        print(f'[check-openrw2-k] FAIL: {len(allf)} row(s)')
        return 1
    print('[check-openrw2-k] PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
