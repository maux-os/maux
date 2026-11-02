#!/usr/bin/env python3
"""check_oappend.py -- per-write O_APPEND, the kernel side
(`make check-oappend`; docs/OAPPEND-1.md, docs/OAPPEND-1-NOTES.md).

A generated probe program (the check_openrw2_k.py machinery, imported:
its Probe DSL, its Ctx, its rig) opens files with the new
OPEN_APPEND count ($23) and the harness reads the OFT / lending tables
by symbol from the image's own listing.  One boot per mode.  Rows are
the brief's names:

  solo      A7 + the basics: an appender that lseeks to 0 and writes
            still appends; reads through the append fd work; a late
            reader joins a lone appender; K_ROOWN never names a lone
            (non-group) entry.
  abi       A10 + A8: the OLD count 3 is a no-intent writer (a second
            one is $50, an appender beside it is $50); $83 is
            unchanged; $A3 (read + append) is refused ERR_INVAL and
            leaves no entry behind; any other count (an $A5-poisoned
            one) is the MLI's own business ($04).
  order     C2: admission is a COUNT over every entry, in every order
            (appenders first, reader first, no-intent first, slots
            freed and reused so scan order and open order differ);
            A3's late reader; A8 both orders.
  two       A1: two PROCESSES append numbered lines to one file, each
            with its own open (two entries, one group), strictly
            alternated by handshakes across a 512-byte boundary;
            every line of both, each intact, per-writer order kept;
            K_ROOWN names the entry that just wrote.
  trunc     A4: truncation under an appender -- one append entry
            shared by dup, SET_EOF(0) through it, the next append
            lands at 0 (no hole, no stale bytes).
  truncg    A4 in a group: two appenders and a reader; one appender
            truncates, the OTHER one's saved mark is now past EOF and
            its next append must still work (the acquire must not load
            it: $4D) and the reader's virtual mark survives.
  fork6     A6: a fork-shared append entry; the child seeks the shared
            fd to 0 before either writes, then both write; every byte
            lands at the end.
  park5     A5: a parked appender -- SEEK the append fd to 0, force a
            park (K_PARK_CNT moves, OFT_IOBUF 0), write: the bytes
            land at EOF.
  park5g    ... the same with a reader in the group.
  exteof    SET_EOF that EXTENDS the file through an appender (a group
            with a reader): EOF grows, the mark stays, and the next
            append lands at the NEW EOF.
  parkown   PRC_OFT_RES inside the append acquire unparks a LONE
            appender and has to park another entry to get a buffer:
            the victim is the OTHER group, whose entry holds K_ROOWN.
            The park clears K_ROOWN after saving that mark, ROSAVE
            then skips, the unparked append lands at EOF, and the
            parked group's reader still reads from ITS mark.  (The
            holder of the SAME group cannot be the victim: a group
            is all resident or all parked and a parked one holds
            no K_ROOWN -- notes sec 11.)
  rel       H1: RELATIVE paths in a process with no recorded cwd (the
            login shell before any cd): two appenders, a late reader,
            reader + no-intent writer all join, as with absolute ones;
            the entries carry their canonical identity and OFTF_PIN;
            a relative and an absolute appender share one group.
  relpin    a lone RELATIVE (pinned) entry is never a park victim even
            when it is the oldest; a group with a pinned member parks
            WITH its oldest unpinned member and the pinned one comes
            back by its canonical identity, at its own mark.
  parkadm   M3: admission against a PARKED group -- a no-intent writer
            is $50, an appender and a reader join (and work after the
            unpark); the unknown-identity fail-safe ($50 for a path
            that cannot be made canonical, only while something is
            parked; the MLI's own error otherwise).
  holes     M3: free OFT slots between the peers (freed and NOT
            reused) do not hide a peer from the admission scan.
  slash     review re-check: a trailing slash names the same file (ProDOS
            drops an empty final component).  `IP/D/G/` (relative) and
            `/mnt/MAUX/IP/D/G` (absolute) meet in both orders and
            JOIN; a DESTROY or RENAME of the slashed spelling of a
            PARKED holder is refused busy like any other spelling.
  fault     item 3: every MLI call the append path adds is CHECKED
            (learning:01M3PMQ72TCBDCCECQAQ66JN1S).  In a group whose
            live mark belongs to a READER, a failing GET_EOF and a
            failing SET_MARK each fail the append with the exact
            error, K_ROOWN still names the reader (published only
            after both calls worked), no byte is written, and the
            reader reads on from its own mark.
  a9        non-file entries: `>> /dev/null` and `>> /dev/tty1`
            (append count) open, write and report the full count;
            no OFT_FILE entry appears.

ASCII only.  Exit 0 green, 1 red (listed), 2 rig problem.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_openrw2_k as K2                              # noqa: E402
import check_openro_k as K                                # noqa: E402
import check_posixex as E                                 # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR    # noqa: E402

ROOT = K2.ROOT
K2.OUT = os.path.join(ROOT, 'build', 'oappend')
NBUFS = K2.NBUFS
ch = K2.ch
FAULT = K2.FAULT
EINVAL = 0xE1                   # inc/errno.krn.equ ERR_INVAL
EBUSY = 0x50                    # MLIE_FILOPEN
EPCOUNT = 0x04                  # the MLI's bad call parameter count

INTENT = {'none': '3', 'ro': '$83', 'ap': '$23', 'roap': '$A3'}


class P(K2.Probe):
    """The openrw2 probe plus an intent-aware OPEN and device opens."""

    def open(self, name, intent='none'):
        if intent is False or intent is True:    # K2's helpers pass bools
            intent = 'ro' if intent else 'none'
        cnt = INTENT[intent] if intent in INTENT else f'${intent:02X}'
        lab = self.lab('P')
        self.parms += f'''{lab}          dfb {cnt}
            da {self.path(name)}
            da 0
            dfb 0
'''
        return self.call(lab, 'SYS_OPEN')

    def open_rel(self, path, intent):
        """OPEN of a RELATIVE path (ProDOS's prefix resolves it)."""
        key = f'REL{len(self.paths)}'
        self.paths[key] = path
        lab = self.lab('P')
        self.parms += f'''{lab}          dfb {INTENT[intent]}
            da N{key}
            da 0
            dfb 0
'''
        return self.call(lab, 'SYS_OPEN')

    def _raw(self, path):
        key = f'RAW{len(self.paths)}'
        self.paths[key] = path
        return f'N{key}'

    def unlink_raw(self, path):
        lab = self.lab('UL')
        self.parms += f'''{lab}          dfb 1
            da {self._raw(path)}
'''
        return self.call(lab, 'SYS_UNLINK')

    def rename_raw(self, a, b):
        lab = self.lab('RN')
        self.parms += f'''{lab}          dfb 2
            da {self._raw(a)},{self._raw(b)}
'''
        return self.call(lab, 'SYS_RENAME')

    def open_dev(self, path, intent):
        key = f'DEV{len(self.paths)}'
        self.paths[key] = path
        lab = self.lab('P')
        self.parms += f'''{lab}          dfb {INTENT[intent]}
            da N{key}
            da 0
            dfb 0
'''
        return self.call(lab, 'SYS_OPEN')


PIN = 0x10                      # OFTF_PIN, inc/mm.annex2.equ
ID = '/MAUX/IP/D/'


def gents(x, tb, name='G'):
    """OFT entries whose saved IDENTITY is `name`'s canonical path --
    pinned (relative) entries included: the gates' own decoder
    (Rig.paths) reads a pinned entry as '' on purpose."""
    out = []
    for i, t in enumerate(tb['types']):
        if t != 3:
            continue
        base = x.syms.get('OFT_SLOT_BASE', 0xBA00) + 68 * i
        n = x.r.peek(base, 1)[0]
        if not n:
            continue
        b = x.r.peek(base + 1, n)
        if bytes(v & 0x7F for v in b).decode().upper() == \
                (ID + name).upper():
            out.append(i)
    return out


def nfile(tb):
    return sum(1 for t in tb['types'] if t == 3)


def run_mode(mode, play):
    spec = MODES[mode]
    probe = P()
    spec['build'](probe)
    img, ps = K2.build(mode, probe, play)
    syms = K.symbols(K2.LISTING)
    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
    c = MCPClient([SUPERVISOR], env)
    try:
        c.initialize()
        E.boot_group(c, img)
        K2.scrub_state(c)
        E.V.t(c, '/mnt/MAUX/IP/PROBE\r')
        x = K2.Ctx(c, syms, ps, probe, mode)
        x.pb = x.find_probe()
        if x.pb is None:
            return [f'{mode}: the probe never started']
        spec['check'](x)
        return x.fails
    finally:
        c.close()


# ---------------------------------------------------------------------
# solo -- A7, reads through an append fd, a late reader, K_ROOWN
# ---------------------------------------------------------------------
def b_solo(p):
    p.files['G'] = (b'abcdefgh', 4, 0)
    s = {}
    s['a'] = p.open('G', 'ap')                   # fd 3
    s['w1'] = p.write(3, b'X')                   # 'abcdefghX'
    s['sm'] = p.setmark(3, 0)
    s['w2'] = p.write(3, b'Y')                   # A7: still at the end
    s['gm1'] = p.getmark(3)                      # 10
    s['sm2'] = p.setmark(3, 3)
    s['rd'] = p.read(3, 2)                       # 'de': reads work
    s['w3'] = p.write(3, b'Z')                   # 'abcdefghXYZ'
    s['gm2'] = p.getmark(3)                      # 11
    s['s1'] = p.sync()                           # lone: not in K_ROOWN
    s['r'] = p.open('G', 'ro')                   # fd 4: joins the appender
    s['rr'] = p.read(4, 11)
    s['gm3'] = p.getmark(3)                      # the appender's slot: 11
    s['w4'] = p.write(3, b'!')                   # reader in the group
    s['rr2'] = p.read(4, 1)                      # '!'
    p.close(3)
    p.close(4)
    s['end'] = p.sync()
    p.done()
    p.s = s


def c_solo(x):
    s = x.p.s
    if x.wait(s['s1']) is None:
        return
    tb = x.tables()
    es = x.entries(tb)
    x.check(len(es) == 1 and tb['pipe'][es[0]] == 0x20,
            f'a lone appender carries OFTF_AP only: {es} '
            f'{[hex(tb["pipe"][i]) for i in es]}')
    x.check(tb['owner'] == 0, f'a lone (non-group) appender is never '
            f'named in K_ROOWN: {tb["owner"]}')
    x.release(s['s1'], x.pb)
    if x.wait(s['end']) is None:
        return
    for k in ('a', 'w1', 'sm', 'w2', 'gm1', 'sm2', 'rd', 'w3', 'gm2', 'r',
              'rr', 'gm3', 'w4', 'rr2'):
        x.ok(s[k], f'step {k}')
    x.check(x.rm(s['gm1']) == 10, f'the mark after two appends is EOF 10: '
            f'{x.rm(s["gm1"])}')
    x.check(ch(x.rb(s['rd'], 2)) == 'de' and x.rt(s['rd']) == 2,
            f'a read through the append fd: {ch(x.rb(s["rd"], 2))!r}')
    x.check(x.rm(s['gm2']) == 11, f'mark after the third append: '
            f'{x.rm(s["gm2"])}')
    x.check(ch(x.rb(s['rr'], 11)) == 'abcdefghXYZ' and x.rt(s['rr']) == 11,
            f'A7: the lseek(0) write still went to the END, a late reader '
            f'sees: {ch(x.rb(s["rr"], 11))!r}')
    x.check(x.rm(s['gm3']) == 11, f'the appender\'s mark after the reader '
            f'took the FCB: {x.rm(s["gm3"])}')
    x.check(ch(x.rb(s['rr2'], 1)) == '!' and x.rt(s['rr2']) == 1,
            f'an append beside a reader is seen at the reader\'s mark: '
            f'{ch(x.rb(s["rr2"], 1))!r}')
    d = x.disk('G')
    x.check(d == b'abcdefghXYZ!', f'the file on the disk: {d!r}')
    x.check(x.k1('K_ROOWN') == 0, 'K_ROOWN clear after the close')


# ---------------------------------------------------------------------
# abi -- A10, A8, $A3
# ---------------------------------------------------------------------
def b_abi(p):
    p.files['G'] = (b'abcdefgh', 4, 0)
    s = {}
    s['o1'] = p.open('G', 'none')                # fd 3: a no-intent writer
    s['o2'] = p.open('G', 'none')                # A10: $50
    s['ap'] = p.open('G', 'ap')                  # A8: $50
    s['ro'] = p.open('G', 'ro')                  # fd 4 joins
    s['rw'] = p.open('G', 'roap')                # $A3: refused ERR_INVAL
    s['s1'] = p.sync()
    p.close(3)
    p.close(4)
    # the other order: an appender first, then a no-intent open
    s['a1'] = p.open('G', 'ap')                  # fd 3
    s['n1'] = p.open('G', 'none')                # A8: $50
    s['r1'] = p.open('G', 'ro')                  # fd 4 joins
    s['n2'] = p.open('G', 'none')                # still $50
    s['s2'] = p.sync()
    p.close(3)
    p.close(4)
    s['z'] = p.open('G', 'none')                 # everything is gone, and
    p.close(3)                                   # $A3 left nothing behind
    s['bad'] = p.open('G', 0xA5)                 # the MLI's own $04
    p.done()
    p.s = s


def c_abi(x):
    s = x.p.s
    if x.wait(s['s1']) is None:
        return
    x.ok(s['o1'], 'a no-intent writer opens')
    x.refused(s['o2'], EBUSY, 'A10: count 3 twice is $50 (count 3 is NOT '
              'append)')
    x.refused(s['ap'], EBUSY, 'A8: an appender beside a no-intent writer')
    x.ok(s['ro'], 'a reader joins the lone writer ($83 unchanged)')
    x.refused(s['rw'], EINVAL, '$A3 (read + append) is reserved')
    tb = x.tables()
    es = x.entries(tb)
    print(f'[check-oappend] abi: G entries {es} flags '
          f'{[hex(tb["pipe"][i]) for i in es]}', flush=True)
    x.check(len(es) == 2, f'exactly the writer and the reader: {es}')
    x.release(s['s1'], x.pb)
    if x.wait(s['s2']) is None:
        return
    x.ok(s['a1'], 'an appender opens')
    x.refused(s['n1'], EBUSY, 'A8: a no-intent writer beside an appender')
    x.ok(s['r1'], 'a reader joins the appender')
    x.refused(s['n2'], EBUSY, 'A8: still $50 with a reader in the group')
    tb = x.tables()
    es = x.entries(tb)
    x.check(len(es) == 2, f'exactly the appender and the reader: {es}')
    x.release(s['s2'], x.pb)
    if x.wait(0xAA) is None:
        return
    x.ok(s['z'], 'once the group is gone a no-intent open works: no entry '
         'was left behind by $A3 or the refusals')
    x.refused(s['bad'], EPCOUNT, 'a count that is not 3, $83 or $23 is '
              'passed to the MLI as today ($04)')


# ---------------------------------------------------------------------
# order -- C2, A3's late reader, A8
# ---------------------------------------------------------------------
def b_order(p):
    p.files['G'] = (b'abcdefgh', 4, 0)
    p.files['F1'] = (b'abcdef', 4, 0)
    s = {}
    # (a) appenders first and last, a late reader, then no-intent
    s['a1'] = p.open('G', 'ap')                  # fd 3
    s['a2'] = p.open('G', 'ap')                  # fd 4
    s['ar'] = p.open('G', 'ro')                  # fd 5: AFTER two appenders
    s['an'] = p.open('G', 'none')                # $50
    s['a3'] = p.open('G', 'ap')                  # fd 6: a third appender
    s['a_sync'] = p.sync()
    for fd in (3, 4, 5, 6):
        p.close(fd)
    # (b) a reader first, then appenders, then no-intent
    s['br'] = p.open('G', 'ro')                  # fd 3
    s['b1'] = p.open('G', 'ap')                  # fd 4
    s['b2'] = p.open('G', 'ap')                  # fd 5
    s['bn'] = p.open('G', 'none')                # $50
    s['br2'] = p.open('G', 'ro')                 # fd 6
    s['b_sync'] = p.sync()
    for fd in (3, 4, 5, 6):
        p.close(fd)
    # (c) a no-intent writer first: appenders refused, readers join
    s['cn'] = p.open('G', 'none')                # fd 3
    s['c1'] = p.open('G', 'ap')                  # $50
    s['cr'] = p.open('G', 'ro')                  # fd 4
    s['cr2'] = p.open('G', 'ro')                 # fd 5
    s['c2'] = p.open('G', 'ap')                  # $50
    s['cn2'] = p.open('G', 'none')               # $50
    s['c_sync'] = p.sync()
    for fd in (3, 4, 5):
        p.close(fd)
    # (d) slots freed and reused: a reader sits in a LOWER OFT slot than
    # the appender opened before it
    s['dd'] = p.open('F1', 'none')               # fd 3, OFT slot x
    s['da'] = p.open('G', 'ap')                  # fd 4, slot x+1
    p.close(3)                                   # slot x is free
    s['dr'] = p.open('G', 'ro')                  # fd 3, reuses slot x
    s['dn'] = p.open('G', 'none')                # $50
    s['da2'] = p.open('G', 'ap')                 # fd 5: joins
    s['d_sync'] = p.sync()
    for fd in (3, 4, 5):
        p.close(fd)
    # (e) ... and the first-opened appender ends up HIGHER than a later
    # appender
    s['ed'] = p.open('F1', 'none')               # fd 3, slot x
    s['ea'] = p.open('G', 'ap')                  # fd 4, slot x+1
    p.close(3)
    s['ea2'] = p.open('G', 'ap')                 # fd 3, slot x
    s['en'] = p.open('G', 'none')                # $50
    s['er'] = p.open('G', 'ro')                  # fd 5
    s['e_sync'] = p.sync()
    for fd in (3, 4, 5):
        p.close(fd)
    s['z'] = p.open('G', 'none')
    p.close(3)
    p.done()
    p.s = s


def c_order(x):
    s = x.p.s
    # (tag, appenders, readers, writers-no-intent) expected in the group
    want = {'a': (3, 1, 0), 'b': (2, 2, 0), 'c': (0, 2, 1),
            'd': (2, 1, 0), 'e': (2, 1, 0)}
    for tag in 'abcde':
        if x.wait(s[f'{tag}_sync']) is None:
            return
        tb = x.tables()
        es = x.entries(tb)
        fl = [tb['pipe'][i] for i in es]
        print(f'[check-oappend] order ({tag}): G entries {es} flags '
              f'{[hex(f) for f in fl]}', flush=True)
        na = sum(1 for f in fl if f & 0x20)
        nr = sum(1 for f in fl if f & 0x80)
        nn = sum(1 for f in fl if not f & 0xA0)
        x.check((na, nr, nn) == want[tag], f'({tag}) appenders/readers/'
                f'no-intent {(na, nr, nn)} want {want[tag]}')
        x.check(len({tb['iobuf'][i] for i in es}) == 1,
                f'({tag}) one shared buffer: {[tb["iobuf"][i] for i in es]}')
        if tag in 'de':
            # setup: scan order differs from open order
            a_first = [i for i in es if tb['pipe'][i] & 0x20]
            if tag == 'd':
                x.check(min(es) not in a_first, f'(d) setup: a READER must '
                        f'sit at the lowest matching slot: {es} {fl}')
            else:
                x.check(len(a_first) == 2 and a_first[0] < a_first[1],
                        f'(e) setup: two appenders {es}')
        x.release(s[f'{tag}_sync'], x.pb)
    if x.wait(0xAA) is None:
        return
    x.ok(s['a1'], '(a) first appender')
    x.ok(s['a2'], '(a) second appender joins')
    x.ok(s['ar'], '(a) A3: a reader opened AFTER two appenders joins')
    x.refused(s['an'], EBUSY, '(a) A8: a no-intent writer beside appenders')
    x.ok(s['a3'], '(a) a third appender joins')
    x.ok(s['br'], '(b) reader first')
    x.ok(s['b1'], '(b) an appender joins a reader')
    x.ok(s['b2'], '(b) a second appender joins')
    x.refused(s['bn'], EBUSY, '(b) A8: no-intent beside appenders')
    x.ok(s['br2'], '(b) a second reader joins')
    x.ok(s['cn'], '(c) a no-intent writer')
    x.refused(s['c1'], EBUSY, '(c) A8: an appender beside a no-intent '
              'writer')
    x.ok(s['cr'], '(c) a reader joins the no-intent writer')
    x.ok(s['cr2'], '(c) a second reader joins')
    x.refused(s['c2'], EBUSY, '(c) A8: still refused with readers in')
    x.refused(s['cn2'], EBUSY, '(c) two no-intent writers stay $50')
    x.ok(s['dd'], '(d) dummy open')
    x.ok(s['da'], '(d) appender')
    x.ok(s['dr'], '(d) a reader in a lower slot joins')
    x.refused(s['dn'], EBUSY, '(d) no-intent refused (reader first in the '
              'scan)')
    x.ok(s['da2'], '(d) a second appender joins')
    x.ok(s['ed'], '(e) dummy open')
    x.ok(s['ea'], '(e) appender')
    x.ok(s['ea2'], '(e) an appender in a lower slot joins')
    x.refused(s['en'], EBUSY, '(e) no-intent refused')
    x.ok(s['er'], '(e) a reader joins')
    x.ok(s['z'], 'every entry is gone')


# ---------------------------------------------------------------------
# two -- A1, two processes, strictly alternated, across a block
# ---------------------------------------------------------------------
NL = 8                                           # lines per writer
HDR = b'#log\n\n'                                # 6 bytes


def line(w, i):
    return (f'{w}{i:02d} '.encode() + bytes([97 + i]) * 35 + b'\n')


def b_two(p):
    p.files['G'] = (HDR, 4, 0)
    s = {}
    s['a'] = p.open('G', 'ap')                   # fd 3: the parent's entry
    p.fork()
    s['pgo'] = p.sync()
    for i in range(1, NL + 1):
        s[f'pw{i}'] = p.write(3, line('P', i))
        s[f'ps{i}'] = p.sync()
    p.wait()
    s['pc'] = p.close(3)
    s['end'] = p.sync()
    p.done()
    p.child()
    s['cc'] = p.close(3)                         # drop the inherited copy
    s['co'] = p.open('G', 'ap')                  # fd 3: a SECOND entry
    s['cs0'] = p.sync()
    for i in range(1, NL + 1):
        s[f'cw{i}'] = p.write(3, line('C', i))
        s[f'cs{i}'] = p.sync()
    p.close(3)
    p.exit()
    p.s = s


def c_two(x):
    s = x.p.s
    cb = x.wait(s['cs0'])
    if cb is None:
        return
    x.ok(s['co'], 'the child\'s own append open joins the parent\'s '
         '(not $50)', cb)
    tb = x.tables()
    es = x.entries(tb)
    x.check(len(es) == 2 and all(tb['pipe'][i] == 0x60 for i in es),
            f'two appender entries in one group ($60): {es} '
            f'{[hex(tb["pipe"][i]) for i in es]}')
    if x.wait(s['pgo']) is None:
        return
    pe, ce = (es + [0, 0])[:2]
    x.release(s['pgo'], x.pb)
    for i in range(1, NL + 1):
        if x.wait(s[f'ps{i}']) is None:
            return
        x.check(x.k1('K_ROOWN') == pe, f'after the parent\'s line {i} '
                f'K_ROOWN names the PARENT\'s entry {pe}: '
                f'{x.k1("K_ROOWN")}')
        x.release(s['cs0'] if i == 1 else s[f'cs{i - 1}'], cb)
        if x.wait(s[f'cs{i}']) is None:
            return
        x.check(x.k1('K_ROOWN') == ce, f'after the child\'s line {i} '
                f'K_ROOWN names the CHILD\'s entry {ce}: '
                f'{x.k1("K_ROOWN")}')
        x.release(s[f'ps{i}'], x.pb)
    x.release(s[f'cs{NL}'], cb)
    if x.wait(s['end']) is None:
        return
    for i in range(1, NL + 1):
        x.ok(s[f'pw{i}'], f'parent line {i}')
        x.ok(s[f'cw{i}'], f'child line {i}', cb)
    d = x.disk('G')
    want_len = len(HDR) + 2 * NL * 40
    print(f'[check-oappend] two: file is {None if d is None else len(d)} '
          f'bytes (want {want_len}, crossing 512)', flush=True)
    if d is None:
        return
    x.check(len(d) == want_len, f'length {len(d)} want {want_len}')
    x.check(d.startswith(HDR), 'the header is intact')
    body = d[len(HDR):]
    ls = [body[i:i + 40] for i in range(0, len(body), 40)]
    pl = [l for l in ls if l[:1] == b'P']
    cl = [l for l in ls if l[:1] == b'C']
    x.check(pl == [line('P', i) for i in range(1, NL + 1)],
            f'the parent\'s lines are all there, intact, in order: {pl!r}')
    x.check(cl == [line('C', i) for i in range(1, NL + 1)],
            f'the child\'s lines are all there, intact, in order: {cl!r}')
    x.check(len(pl) + len(cl) == len(ls), 'no line is anything else')
    x.check(x.k1('K_ROOWN') == 0, 'K_ROOWN clear after the close')


# ---------------------------------------------------------------------
# trunc / truncg -- A4
# ---------------------------------------------------------------------
def b_trunc(p):
    p.files['G'] = (b'ABCDEFGHIJKL', 4, 0)
    s = {}
    s['a'] = p.open('G', 'ap')                   # fd 3
    s['d'] = p.dup2(3, 4)                        # ONE entry, two fds
    s['wx'] = p.write(3, b'x')
    s['wy'] = p.write(4, b'y')                   # 'ABCDEFGHIJKLxy'
    s['e0'] = p.geteof(4)                        # 14
    s['cut'] = p.seteof(4, 0)                    # through the shared fd
    s['e1'] = p.geteof(3)                        # 0
    s['wz'] = p.write(3, b'Z')                   # lands at 0
    s['e2'] = p.geteof(4)                        # 1: no hole
    s['wq'] = p.write(4, b'QR')
    s['r'] = p.open('G', 'ro')                   # fd 5
    s['rd'] = p.read(5, 8)                       # 'ZQR', 3 bytes
    p.close(3)
    p.close(4)
    p.close(5)
    s['end'] = p.sync()
    p.done()
    p.s = s


def c_trunc(x):
    s = x.p.s
    if x.wait(s['end']) is None:
        return
    for k in ('a', 'd', 'wx', 'wy', 'e0', 'cut', 'e1', 'wz', 'e2', 'wq',
              'r', 'rd'):
        x.ok(s[k], f'step {k}')
    x.check(x.rm(s['e0']) == 14, f'EOF after two appends: {x.rm(s["e0"])}')
    x.check(x.rm(s['e1']) == 0, f'EOF after the cut: {x.rm(s["e1"])}')
    x.check(x.rm(s['e2']) == 1, f'the append after the cut lands at 0 with '
            f'no hole: EOF {x.rm(s["e2"])}')
    x.check(ch(x.rb(s['rd'], 3)) == 'ZQR' and x.rt(s['rd']) == 3,
            f'no stale bytes: {ch(x.rb(s["rd"], 3))!r} '
            f'(count {x.rt(s["rd"])})')
    d = x.disk('G')
    x.check(d == b'ZQR', f'the file on the disk: {d!r}')


G32 = b'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef'


def b_truncg(p):
    p.files['G'] = (G32, 4, 0)
    s = {}
    s['r'] = p.open('G', 'ro')                   # fd 3: R
    s['x'] = p.open('G', 'ap')                   # fd 4: X
    s['y'] = p.open('G', 'ap')                   # fd 5: Y
    s['rd'] = p.read(3, 12)                      # R at 12
    s['wy'] = p.write(5, b'yyyy')                # Y holds; its mark is 36
    s['wx'] = p.write(4, b'xx')                  # X acquires: Y saved at 36
    s['cut'] = p.seteof(4, 0)                    # X cuts: Y's slot is 36 > 0
    s['e1'] = p.geteof(3)                        # 0
    s['wq'] = p.write(5, b'Q')                   # Y: must NOT load mark 36
    s['e2'] = p.geteof(3)                        # 1
    s['rv'] = p.read(3, 1)                       # R at 12 > EOF: 0 bytes
    s['gm'] = p.getmark(3)                       # 12
    s['wa'] = p.write(4, b'ABCDEFGHIJKLMNOPQR')  # X: EOF 19 > 12
    s['rres'] = p.read(3, 4)                     # exactly offset 12
    s['e3'] = p.geteof(5)
    p.close(3)
    p.close(4)
    p.close(5)
    s['end'] = p.sync()
    p.done()
    p.s = s


def c_truncg(x):
    s = x.p.s
    if x.wait(s['end']) is None:
        return
    for k in ('r', 'x', 'y', 'rd', 'wy', 'wx', 'cut', 'e1', 'e2', 'gm',
              'wa', 'rres', 'e3'):
        x.ok(s[k], f'step {k}')
    x.ok(s['wq'], 'the OTHER appender writes after the cut: its saved mark '
         '(36) is past the EOF and the append acquire must not load it')
    x.check(x.rm(s['e1']) == 0, f'EOF after the cut: {x.rm(s["e1"])}')
    x.check(x.rm(s['e2']) == 1, f'the other appender\'s write landed at '
            f'0, no hole: EOF {x.rm(s["e2"])}')
    x.ok(s['rv'], 'the reader\'s read at a virtual mark')
    x.check(x.rt(s['rv']) == 0, f'0 bytes at the virtual mark: '
            f'{x.rt(s["rv"])}')
    x.check(x.rm(s['gm']) == 12, f'GET_MARK of the virtual reader: '
            f'{x.rm(s["gm"])}')
    x.check(ch(x.rb(s['rres'], 4)) == 'LMNO' and x.rt(s['rres']) == 4,
            f'the reader resumes at EXACTLY offset 12: '
            f'{ch(x.rb(s["rres"], 4))!r}')
    x.check(x.rm(s['e3']) == 19, f'EOF {x.rm(s["e3"])}')
    d = x.disk('G')
    x.check(d == b'QABCDEFGHIJKLMNOPQR', f'the file on the disk: {d!r}')


# ---------------------------------------------------------------------
# fork6 -- A6
# ---------------------------------------------------------------------
def b_fork6(p):
    p.files['G'] = (b'HEAD', 4, 0)
    s = {}
    s['a'] = p.open('G', 'ap')                   # fd 3
    s['w1'] = p.write(3, b'1')                   # 'HEAD1'
    p.fork()
    p.wait()
    s['pw'] = p.write(3, b'P')                   # after the child
    s['r'] = p.open('G', 'ro')                   # fd 4
    s['rd'] = p.read(4, 8)
    p.close(3)
    p.close(4)
    s['end'] = p.sync()
    p.done()
    p.child()
    s['csm'] = p.setmark(3, 0)                   # the shared fd -> 0
    s['cw'] = p.write(3, b'C')
    s['cgm'] = p.getmark(3)
    p.exit()
    p.s = s


def c_fork6(x):
    s = x.p.s
    if x.wait(s['end']) is None:
        return
    for k in ('a', 'w1', 'pw', 'r', 'rd'):
        x.ok(s[k], f'parent {k}')
    x.check(ch(x.rb(s['rd'], 7)) == 'HEAD1CP' and x.rt(s['rd']) == 7,
            f'both writes landed at the END: {ch(x.rb(s["rd"], 7))!r} '
            f'(the head must be untouched)')
    d = x.disk('G')
    x.check(d == b'HEAD1CP', f'the file on the disk: {d!r}')


# ---------------------------------------------------------------------
# park5 / park5g -- A5
# ---------------------------------------------------------------------
def b_park5(p, grp):
    p.files['G'] = (b'abcdefgh', 4, 0)
    s = {}
    s['a'] = p.open('G', 'ap')                   # fd 3
    nfds = 1
    if grp:
        s['r'] = p.open('G', 'ro')               # fd 4
        s['rd0'] = p.read(4, 3)                  # R at 3
        nfds = 2
    s['sm'] = p.setmark(3, 0)                    # the appender SEEKS to 0
    nfree = 3
    park_parent(p, nfree, s)
    p.wait()
    s['wr'] = p.write(3, b'XY')                  # lands at the END
    s['gm'] = p.getmark(3)
    if grp:
        s['rd1'] = p.read(4, 3)                  # R continues: 'def'
    s['sm0'] = p.setmark(3, 0)
    s['rall'] = p.read(3, 10)
    for fd in range(3, 3 + nfds):
        p.close(fd)
    s['end'] = p.sync()
    p.done()
    p.child()
    nxt = K2.park_child_fill(p, nfree, nclose=nfds + nfree)
    s['ready'] = p.sync()
    s['pk'] = p.open(f'F{nxt}', 'none')          # parks the LRU victim
    s['ready2'] = p.sync()
    p.exit()
    p.s = s


def park_parent(p, nfree, s):
    for i in range(1, nfree + 1):
        p.files[f'F{i}'] = (b'abcdef', 4, 0)
        p.open(f'F{i}', 'none')
    for i in range(nfree + 1, NBUFS + 2):
        p.files[f'F{i}'] = (b'abcdef', 4, 0)
    p.fork()


def c_park5(x, grp):
    s = x.p.s
    cb = x.wait(s['ready'])
    if cb is None:
        return
    tb = x.tables()
    es = x.entries(tb)
    base_parks = tb['parks']
    print(f'[check-oappend] park5: child bank {cb}, inuse={tb["inuse"]} '
          f'parks={tb["parks"]} G entries {es} flags '
          f'{[hex(tb["pipe"][i]) for i in es]}', flush=True)
    x.check(len(es) == (2 if grp else 1), f'setup: G entries {es}')
    x.check(tb['inuse'] == NBUFS, f'setup: the pool must be FULL '
            f'({tb["inuse"]} of {NBUFS})')
    x.check(all(tb['iobuf'][i] for i in es), 'setup: G is resident')
    ok_, v = K2.lru_ok(x, tb, es)
    x.check(ok_, f'setup: the LRU victim (slot {v}) must be a G entry {es}')
    x.release(s['ready'], cb)
    if x.wait(s['ready2']) is None:
        return
    t2 = x.tables()
    print(f'[check-oappend] park5: after: parks={t2["parks"]} iobuf '
          f'{[t2["iobuf"][i] for i in es]}', flush=True)
    x.check(t2['parks'] > base_parks, f'K_PARK_CNT must move: {base_parks} '
            f'-> {t2["parks"]}')
    x.check(all(t2['iobuf'][i] == 0 for i in es), 'the appender is PARKED '
            '(OFT_IOBUF 0)')
    x.release(s['ready2'], cb)
    if x.wait(s['end']) is None:
        return
    for k in ('a', 'sm', 'wr', 'gm', 'sm0', 'rall'):
        x.ok(s[k], f'parent {k}', x.pb)
    x.check(x.rm(s['gm']) == 10, f'mark after the append: {x.rm(s["gm"])}')
    x.check(ch(x.rb(s['rall'], 10)) == 'abcdefghXY' and
            x.rt(s['rall']) == 10,
            f'A5: the write after the unpark landed at EOF: '
            f'{ch(x.rb(s["rall"], 10))!r}')
    if grp:
        x.ok(s['rd1'], 'reader after the unpark')
        x.check(ch(x.rb(s['rd1'], 3)) == 'def', f'the reader continues at '
                f'ITS mark 3: {ch(x.rb(s["rd1"], 3))!r}')
    d = x.disk('G')
    x.check(d == b'abcdefghXY', f'the file on the disk: {d!r}')


# ---------------------------------------------------------------------
# a9 -- devices ignore append intent
# ---------------------------------------------------------------------
def b_a9(p):
    s = {}
    s['s0'] = p.sync()
    s['n'] = p.open_dev('/dev/null', 'ap')       # fd 3
    s['nw'] = p.write(3, b'hello')
    s['t'] = p.open_dev('/dev/tty1', 'ap')       # fd 4
    s['tw'] = p.write(4, b'.')
    s['s1'] = p.sync()
    p.close(3)
    p.close(4)
    p.done()
    p.s = s


def c_a9(x):
    s = x.p.s
    if x.wait(s['s0']) is None:
        return
    base = nfile(x.tables())
    x.release(s['s0'], x.pb)
    if x.wait(s['s1']) is None:
        return
    for k in ('n', 'nw', 't', 'tw'):
        x.ok(s[k], f'step {k}')
    x.check(x.rt(s['nw']) == 5, f'>> /dev/null reports the whole write: '
            f'{x.rt(s["nw"])}')
    x.check(x.rt(s['tw']) == 1, f'>> /dev/tty1 reports the whole write: '
            f'{x.rt(s["tw"])}')
    x.check(nfile(x.tables()) == base, 'no OFT_FILE entry for a device')

# ---------------------------------------------------------------------
# exteof -- SET_EOF that extends, through an appender
# ---------------------------------------------------------------------
def b_exteof(p):
    p.files['G'] = (b'ABCD', 4, 0)
    s = {}
    s['r'] = p.open('G', 'ro')                   # fd 3
    s['a'] = p.open('G', 'ap')                   # fd 4: joins
    s['w1'] = p.write(4, b'x')                   # 'ABCDx', EOF 5
    s['ext'] = p.seteof(4, 10)                   # EXTEND to 10
    s['e1'] = p.geteof(3)                        # 10
    s['m1'] = p.getmark(4)                       # the mark did not move
    s['w2'] = p.write(4, b'Z')                   # lands at the new EOF
    s['e2'] = p.geteof(3)                        # 11
    s['rd'] = p.read(3, 11)
    p.close(3)
    p.close(4)
    s['end'] = p.sync()
    p.done()
    p.s = s


def c_exteof(x):
    s = x.p.s
    if x.wait(s['end']) is None:
        return
    for k in ('r', 'a', 'w1', 'ext', 'e1', 'm1', 'w2', 'e2', 'rd'):
        x.ok(s[k], f'step {k}')
    x.check(x.rm(s['e1']) == 10, f'EOF after the extending SET_EOF: '
            f'{x.rm(s["e1"])}')
    x.check(x.rm(s['m1']) == 5, f'the appender\'s mark is where its '
            f'write left it (5): {x.rm(s["m1"])}')
    x.check(x.rm(s['e2']) == 11, f'the next append landed at the NEW '
            f'EOF 10: EOF {x.rm(s["e2"])}')
    want = b'ABCDx' + bytes(5) + b'Z'
    got = bytes(x.rb(s['rd'], 11))
    x.check(got == want and x.rt(s['rd']) == 11,
            f'bytes: {got!r} want {want!r}')
    d = x.disk('G')
    x.check(d == want, f'the file on the disk: {d!r}')


# ---------------------------------------------------------------------
# parkown -- the append acquire's unpark parks ANOTHER group's holder
# ---------------------------------------------------------------------
def b_parkown(p):
    p.files['B'] = (b'bbbbbb', 4, 0)
    p.files['A'] = (b'abcdefgh', 4, 0)
    for i in range(1, 6):
        p.files[f'F{i}'] = (b'abcdef', 4, 0)
    s = {}
    s['ob'] = p.open('B', 'ap')                  # fd 3: lone appender
    s['sb'] = p.setmark(3, 0)                    # (its mark is stale)
    s['oa'] = p.open('A', 'ap')                  # fd 4
    s['or'] = p.open('A', 'ro')                  # fd 5: group A
    s['rr'] = p.read(5, 3)                       # R at 3 ('abc')
    p.fork()
    s['p1'] = p.sync()                           # B is parked by now
    s['wa'] = p.write(4, b'W')                   # A.ap holds the mark
    s['p2'] = p.sync()
    s['wb'] = p.write(3, b'Z')                   # unparks B, parks A
    s['p3'] = p.sync()
    s['rd'] = p.read(5, 3)                       # R continues: 'def'
    s['wa2'] = p.write(4, b'Y')
    p.close(3)
    p.close(4)
    p.close(5)
    s['end'] = p.sync()
    p.done()
    p.child()
    for fd in (3, 4, 5):
        p.close(fd)
    for i in range(1, 5):                        # fds 3..6: pool full
        p.open(f'F{i}', 'none')
    s['c1'] = p.sync()
    s['pk'] = p.open('F5', 'none')               # fd 7: parks B (LRU)
    s['c2'] = p.sync()
    for fd in (3, 4, 5, 6, 7):                   # F's are now NEWER
        p.read(fd, 1)                            # than A's last write
    s['c3'] = p.sync()
    p.exit()
    p.s = s


def c_parkown(x):
    s = x.p.s
    cb = x.wait(s['c1'])
    if cb is None:
        return
    tb = x.tables()
    x.check(tb['inuse'] == NBUFS, f'setup: pool full {tb["inuse"]}')
    x.release(s['c1'], cb)
    if x.wait(s['c2']) is None:
        return
    tb = x.tables()
    eb, ea = x.entries(tb, 'B'), x.entries(tb, 'A')
    x.check(len(eb) == 1 and tb['iobuf'][eb[0]] == 0, f'setup: B is '
            f'PARKED: {eb} {[tb["iobuf"][i] for i in eb]}')
    x.check(len(ea) == 2 and all(tb['iobuf'][i] for i in ea),
            f'setup: group A resident: {ea}')
    if x.wait(s['p1']) is None:
        return
    x.release(s['p1'], x.pb)
    if x.wait(s['p2']) is None:
        return
    tb = x.tables()
    ap = [i for i in ea if tb['pipe'][i] & 0x20]
    x.check(tb['owner'] in ap, f'setup: A.ap holds the live mark: owner '
            f'{tb["owner"]} ap {ap}')
    x.release(s['c2'], cb)               # the child touches its F's
    if x.wait(s['c3']) is None:
        return
    base = x.tables()['parks']
    x.release(s['p2'], x.pb)
    if x.wait(s['p3']) is None:
        return
    t3 = x.tables()
    print(f'[check-oappend] parkown: owner {tb["owner"]} -> {t3["owner"]}, '
          f'parks {base} -> {t3["parks"]}, A iobuf '
          f'{[t3["iobuf"][i] for i in ea]}, B iobuf '
          f'{[t3["iobuf"][i] for i in eb]}', flush=True)
    x.check(all(t3['iobuf'][i] == 0 for i in ea), 'group A was the victim: '
            'PARKED together')
    x.check(t3['iobuf'][eb[0]] != 0, 'B is resident again')
    x.check(t3['parks'] > base, f'a park happened inside the unpark: '
            f'{base} -> {t3["parks"]}')
    x.check(t3['owner'] == 0, f'the park cleared K_ROOWN and the lone '
            f'append did not name itself: {t3["owner"]}')
    x.release(s['p3'], x.pb)
    x.release(s['c3'], cb)
    if x.wait(s['end']) is None:
        return
    for k in ('ob', 'sb', 'oa', 'or', 'rr', 'wa', 'wb', 'rd', 'wa2'):
        x.ok(s[k], f'step {k}')
    x.check(ch(x.rb(s['rd'], 3)) == 'def', f'the parked group\'s reader '
            f'continues at ITS mark 3: {ch(x.rb(s["rd"], 3))!r}')
    d = x.disk('B')
    x.check(d == b'bbbbbbZ', f'B: the append landed at EOF: {d!r}')
    d = x.disk('A')
    x.check(d == b'abcdefghWY', f'A: both appends at EOF: {d!r}')


# ---------------------------------------------------------------------
# rel -- H1: relative paths, no recorded cwd
# ---------------------------------------------------------------------
RG = 'IP/D/G'                   # relative to the boot prefix /MAUX/


def b_rel(p):
    p.files['G'] = (b'abcdefgh', 4, 0)
    s = {}
    s['a1'] = p.open_rel(RG, 'ap')               # fd 3
    s['a2'] = p.open_rel(RG, 'ap')               # fd 4: joins
    s['r'] = p.open_rel(RG, 'ro')                # fd 5: after two
    s['n'] = p.open_rel(RG, 'none')              # $50
    s['w1'] = p.write(3, b'x')
    s['w2'] = p.write(4, b'y')
    s['rr'] = p.read(5, 10)                      # 'abcdefghxy'
    s['s1'] = p.sync()
    for fd in (3, 4, 5):
        p.close(fd)
    # reader first, then a no-intent writer (OPEN-RW-2's own hole)
    s['br'] = p.open_rel(RG, 'ro')               # fd 3
    s['bw'] = p.open_rel(RG, 'none')             # fd 4: joins
    s['bw2'] = p.open_rel(RG, 'none')            # $50
    s['bwr'] = p.write(4, b'Z')
    s['s2'] = p.sync()
    p.close(3)
    p.close(4)
    # a relative appender and an ABSOLUTE appender: one group
    s['ma'] = p.open_rel(RG, 'ap')               # fd 3
    s['mb'] = p.open('G', 'ap')                  # fd 4: joins
    s['mw'] = p.write(4, b'q')
    s['s3'] = p.sync()
    p.close(3)
    p.close(4)
    p.done()
    p.s = s


def c_rel(x):
    s = x.p.s
    if x.wait(s['s1']) is None:
        return
    tb = x.tables()
    es = gents(x, tb)
    fl = [tb['pipe'][i] for i in es]
    print(f'[check-oappend] rel (a): G entries {es} flags '
          f'{[hex(f) for f in fl]}', flush=True)
    x.check(sorted(fl) == [0x70, 0x70, 0xD0], f'two appenders + a late '
            f'reader, all PINNED, all in one group: {[hex(f) for f in fl]}')
    x.check(len({tb['iobuf'][i] for i in es}) == 1, 'one shared buffer')
    x.release(s['s1'], x.pb)
    if x.wait(s['s2']) is None:
        return
    tb = x.tables()
    es = gents(x, tb)
    fl = [tb['pipe'][i] for i in es]
    x.check(sorted(fl) == [0x50, 0xD0], f'(b) reader + no-intent writer: '
            f'{[hex(f) for f in fl]}')
    x.release(s['s2'], x.pb)
    if x.wait(s['s3']) is None:
        return
    tb = x.tables()
    es = gents(x, tb)
    fl = sorted(tb['pipe'][i] for i in es)
    x.check(fl == [0x60, 0x70], f'(c) a relative (pinned) and an absolute '
            f'appender: {[hex(f) for f in fl]}')
    x.release(s['s3'], x.pb)
    if x.wait(0xAA) is None:
        return
    x.ok(s['a1'], '(a) first relative appender')
    x.ok(s['a2'], '(a) the SECOND relative appender joins (H1: it was a '
         'ProDOS $50 when the pinned entry had no identity)')
    x.ok(s['r'], '(a) a relative reader after two appenders joins')
    x.refused(s['n'], EBUSY, '(a) a relative no-intent writer beside '
              'appenders')
    x.check(ch(x.rb(s['rr'], 10)) == 'abcdefghxy' and x.rt(s['rr']) == 10,
            f'(a) both appends at EOF: {ch(x.rb(s["rr"], 10))!r}')
    x.ok(s['br'], '(b) relative reader')
    x.ok(s['bw'], '(b) a relative no-intent writer joins the reader '
         '(OPEN-RW-2, same hole)')
    x.refused(s['bw2'], EBUSY, '(b) a second no-intent writer')
    x.ok(s['bwr'], '(b) the joined writer writes')
    x.ok(s['ma'], '(c) relative appender')
    x.ok(s['mb'], '(c) absolute appender joins it')
    x.ok(s['mw'], '(c) write')
    d = x.disk('G')
    # (b)'s no-intent writer is NOT an appender: it wrote 'Z' at its
    # own mark 0; every append ('x', 'y', 'q') went to the end
    x.check(d == b'Zbcdefghxyq', f'the file on the disk: {d!r}')


# ---------------------------------------------------------------------
# relpin -- a RELATIVE (pinned) entry is never itself a park victim;
# one that shares a group is parked WITH it and reopens by its
# canonical identity
# ---------------------------------------------------------------------
def b_relpin(p):
    p.files['G'] = (b'abcdefgh', 4, 0)
    p.files['F9'] = (b'abcdef', 4, 0)
    s = {}
    s['o'] = p.open_rel('IP/D/F9', 'none')       # fd 3: lone PINNED,
    s['a'] = p.open('G', 'ap')                   # the OLDEST entry
    s['r'] = p.open_rel(RG, 'ro')                # fd 5: relative member
    s['rd0'] = p.read(5, 3)
    s['sm'] = p.setmark(4, 0)
    nfree = 1
    park_parent(p, nfree, s)                     # F1 = fd 6
    p.wait()
    s['wr'] = p.write(4, b'XY')                  # unparks G
    s['rd1'] = p.read(5, 3)                      # 'def' via the
    s['ro'] = p.read(3, 1)                       # canonical reopen
    for fd in (3, 4, 5, 6):
        p.close(fd)
    s['end'] = p.sync()
    p.done()
    p.child()
    for fd in (3, 4, 5, 6):
        p.close(fd)
    for i in (2, 3, 4):                          # the pool is FULL
        p.open(f'F{i}', 'none')
    s['ready'] = p.sync()
    s['pk'] = p.open('F5', 'none')               # needs a victim
    s['ready2'] = p.sync()
    p.exit()
    p.s = s


def c_relpin(x):
    s = x.p.s
    cb = x.wait(s['ready'])
    if cb is None:
        return
    tb = x.tables()
    eg, ef = gents(x, tb), gents(x, tb, 'F9')
    base = tb['parks']
    x.check(len(eg) == 2 and len(ef) == 1 and tb['inuse'] == NBUFS,
            f'setup: G group {eg}, F9 {ef}, pool {tb["inuse"]}')
    x.check(all(tb['pipe'][i] & PIN for i in ef) and
            sum(1 for i in eg if tb['pipe'][i] & PIN) == 1,
            f'setup: F9 pinned, exactly one G member pinned: '
            f'{[hex(tb["pipe"][i]) for i in ef + eg]}')
    # F9 is the OLDEST resident entry: without the pin rule it is the
    # LRU victim.  G is the oldest UNPINNED one.
    x.release(s['ready'], cb)
    if x.wait(s['ready2']) is None:
        return
    t2 = x.tables()
    print(f'[check-oappend] relpin: parks {base} -> {t2["parks"]}, G iobuf '
          f'{[t2["iobuf"][i] for i in eg]}, F9 iobuf '
          f'{[t2["iobuf"][i] for i in ef]}', flush=True)
    x.check(t2['iobuf'][ef[0]] != 0, 'the lone PINNED entry is resident: '
            'never a victim, although it is the oldest')
    x.check(all(t2['iobuf'][i] == 0 for i in eg), 'the oldest UNPINNED '
            'entry was the victim: its whole group parked, the pinned '
            'member with it')
    x.check(t2['parks'] == base + 1, f'one park: {base} -> {t2["parks"]}')
    x.release(s['ready2'], cb)
    if x.wait(s['end']) is None:
        return
    for k in ('wr', 'rd1', 'ro'):
        x.ok(s[k], f'parent {k}')
    x.check(ch(x.rb(s['rd1'], 3)) == 'def', f'the PINNED member comes '
            f'back by its canonical identity at ITS mark: '
            f'{ch(x.rb(s["rd1"], 3))!r}')
    x.check(ch(x.rb(s['ro'], 1)) == 'a', 'the pinned lone entry reads')
    d = x.disk('G')
    x.check(d == b'abcdefghXY', f'the file on the disk: {d!r}')


# ---------------------------------------------------------------------
# parkadm -- M3: admission against a PARKED group
# ---------------------------------------------------------------------
LONGREL = 'A' * 60


def b_parkadm(p):
    p.files['G'] = (b'abcdefgh', 4, 0)
    s = {}
    s['long0'] = p.open_rel(LONGREL, 'none')     # nothing parked: the MLI
    s['a'] = p.open('G', 'ap')                   # fd 3
    s['r'] = p.open('G', 'ro')                   # fd 4
    s['rd0'] = p.read(4, 3)
    s['sm'] = p.setmark(3, 0)
    nfree = 3
    park_parent(p, nfree, s)
    p.wait()
    for fd in (5, 6, 7):
        p.close(fd)
    s['p1'] = p.sync()                           # G is PARKED here
    s['n'] = p.open('G', 'none')                 # $50
    s['long1'] = p.open_rel(LONGREL, 'none')     # unknown identity: $50
    s['a2'] = p.open('G', 'ap')                  # fd 5: joins
    s['r2'] = p.open('G', 'ro')                  # fd 6: joins
    s['w'] = p.write(5, b'Z')                    # unparks, lands at EOF
    s['rd1'] = p.read(4, 3)                      # R: 'def'
    s['rall'] = p.read(6, 9)                     # r2 from 0: whole file
    s['p2'] = p.sync()
    for fd in (3, 4, 5, 6):
        p.close(fd)
    s['long2'] = p.open_rel(LONGREL, 'none')     # nothing parked again
    s['end'] = p.sync()
    p.done()
    p.child()
    nxt = K2.park_child_fill(p, nfree, nclose=2 + nfree)
    s['ready'] = p.sync()
    s['pk'] = p.open(f'F{nxt}', 'none')
    s['ready2'] = p.sync()
    p.exit()
    p.s = s


def c_parkadm(x):
    s = x.p.s
    cb = x.wait(s['ready'])
    if cb is None:
        return
    x.release(s['ready'], cb)
    if x.wait(s['ready2']) is None:
        return
    x.release(s['ready2'], cb)
    if x.wait(s['p1']) is None:
        return
    tb = x.tables()
    es = x.entries(tb)
    x.check(len(es) == 2 and all(tb['iobuf'][i] == 0 for i in es),
            f'setup: the group is PARKED: {es} '
            f'{[tb["iobuf"][i] for i in es]}')
    x.release(s['p1'], x.pb)
    if x.wait(s['p2']) is None:
        return
    x.refused(s['n'], EBUSY, 'a no-intent writer beside a PARKED '
              'appender+reader group')
    x.refused(s['long1'], EBUSY, 'unknown identity while something is '
              'parked: refused on ProDOS\'s behalf')
    for k in ('a2', 'r2', 'w', 'rd1', 'rall'):
        x.ok(s[k], f'step {k}')
    x.check(ch(x.rb(s['rd1'], 3)) == 'def', f'R continues at ITS mark: '
            f'{ch(x.rb(s["rd1"], 3))!r}')
    x.check(ch(x.rb(s['rall'], 9)) == 'abcdefghZ' and
            x.rt(s['rall']) == 9, f'the late reader sees the append at '
            f'EOF: {ch(x.rb(s["rall"], 9))!r}')
    x.release(s['p2'], x.pb)
    if x.wait(s['end']) is None:
        return
    # the control: the same open with NOTHING parked is the MLI's error
    for k in ('long0', 'long2'):
        c, a = x.carry(s[k]), x.ra(s[k])
        x.check(c == 1 and a != EBUSY, f'{k}: with nothing parked the '
                f'open fails with the MLI\'s own error, not $50: carry '
                f'{c} A=${a:02X}')


# ---------------------------------------------------------------------
# holes -- M3: free slots between the peers
# ---------------------------------------------------------------------
def b_holes(p):
    p.files['G'] = (b'abcdefgh', 4, 0)
    p.files['F1'] = (b'abcdef', 4, 0)
    p.files['F2'] = (b'abcdef', 4, 0)
    s = {}
    s['d1'] = p.open('F1', 'none')               # fd 3, slot x
    s['a'] = p.open('G', 'ap')                   # fd 4, x+1
    s['d2'] = p.open('F2', 'none')               # fd 5, x+2
    s['a2'] = p.open('G', 'ap')                  # fd 6, x+3
    p.close(3)
    p.close(5)                                   # holes at x and x+2
    s['n'] = p.open('G', 'none')                 # $50 (and no slot used)
    s['h_sync'] = p.sync()
    s['r'] = p.open('G', 'ro')                   # joins, takes slot x
    p.close(4)
    p.close(6)
    p.close(3)
    s['z'] = p.open('G', 'none')
    p.close(3)
    p.done()
    p.s = s


def c_holes(x):
    s = x.p.s
    if x.wait(s['h_sync']) is None:
        return
    tb = x.tables()
    es = x.entries(tb)
    free = [i for i in range(1, 16) if tb['types'][i] == 0]
    inner = [i for i in free if min(es) < i < max(es)]
    x.check(len(es) == 2 and inner, f'setup: a FREE slot between the '
            f'peers {es}: free {free}')
    x.check(min(free) < min(es), f'setup: a free slot BEFORE the first '
            f'peer: free {free} peers {es}')
    x.release(s['h_sync'], x.pb)
    if x.wait(0xAA) is None:
        return
    x.refused(s['n'], EBUSY, 'a no-intent writer across free slots')
    x.ok(s['r'], 'a reader joins across free slots')
    x.ok(s['z'], 'everything gone: a no-intent writer opens')


# ---------------------------------------------------------------------
# slash -- a trailing slash is the same file
# ---------------------------------------------------------------------
GABS = '/mnt/MAUX/IP/D/G'


def b_slash(p):
    p.files['G'] = (b'abcdefgh', 4, 0)
    s = {}
    # (a) absolute first, then the RELATIVE spelling with a slash
    s['aa'] = p.open('G', 'ap')                  # fd 3
    s['ar'] = p.open_rel(RG + '/', 'ap')         # fd 4: must join
    s['a_sync'] = p.sync()
    p.close(3)
    p.close(4)
    # (b) relative first, then the ABSOLUTE spelling with a slash
    s['br'] = p.open_rel(RG, 'ap')               # fd 3
    s['ba'] = p.open_rel(GABS + '/', 'ap')       # fd 4: must join
    s['b_sync'] = p.sync()
    p.close(3)
    p.close(4)
    # (c) a PARKED holder, then DESTROY / RENAME of the slashed spelling
    s['ca'] = p.open('G', 'ap')                  # fd 3
    s['sm'] = p.setmark(3, 0)
    nfree = 3
    park_parent(p, nfree, s)
    p.wait()
    s['p1'] = p.sync()                           # G is PARKED here
    s['u1'] = p.unlink_raw(GABS + '/')
    s['u2'] = p.unlink_raw(RG + '/')
    s['n1'] = p.rename_raw(GABS + '/', GABS + '2')
    s['wz'] = p.write(3, b'Z')                   # still there: unparks
    p.close(3)
    s['end'] = p.sync()
    p.done()
    p.child()
    nxt = K2.park_child_fill(p, nfree, nclose=1 + nfree)
    s['ready'] = p.sync()
    s['pk'] = p.open(f'F{nxt}', 'none')
    s['ready2'] = p.sync()
    p.exit()
    p.s = s


def c_slash(x):
    s = x.p.s
    if x.wait(s['a_sync']) is None:
        return
    tb = x.tables()
    es = gents(x, tb)
    print(f'[check-oappend] slash (a): G entries {es} flags '
          f'{[hex(tb["pipe"][i]) for i in es]}', flush=True)
    x.check(len(es) == 2 and len({tb['iobuf'][i] for i in es}) == 1,
            f'(a) two entries on ONE buffer: {es}')
    x.release(s['a_sync'], x.pb)
    if x.wait(s['b_sync']) is None:
        return
    tb = x.tables()
    es = gents(x, tb)
    x.check(len(es) == 2 and len({tb['iobuf'][i] for i in es}) == 1,
            f'(b) two entries on ONE buffer: {es}')
    x.release(s['b_sync'], x.pb)
    cb = x.wait(s['ready'])
    if cb is None:
        return
    x.release(s['ready'], cb)
    if x.wait(s['ready2']) is None:
        return
    x.release(s['ready2'], cb)
    if x.wait(s['p1']) is None:
        return
    tb = x.tables()
    es = x.entries(tb)
    x.check(len(es) == 1 and tb['iobuf'][es[0]] == 0, f'setup: the holder '
            f'of G is PARKED: {es} {[tb["iobuf"][i] for i in es]}')
    x.release(s['p1'], x.pb)
    if x.wait(s['end']) is None:
        return
    x.ok(s['aa'], '(a) absolute appender')
    x.ok(s['ar'], '(a) the relative `G/` spelling JOINS (it was ProDOS '
         '$50: the identities differed by the slash)')
    x.ok(s['br'], '(b) relative appender')
    x.ok(s['ba'], '(b) the absolute `G/` spelling JOINS')
    x.refused(s['u1'], EBUSY, 'DESTROY of `G/` while a PARKED holder has '
              'G')
    x.refused(s['u2'], EBUSY, 'DESTROY of the relative `G/`')
    x.refused(s['n1'], EBUSY, 'RENAME of `G/`')
    x.ok(s['wz'], 'the holder still writes (G still exists)')
    try:
        d = x.disk('G')
    except FileNotFoundError:
        d = None                         # DESTROYed under its holder
    x.check(d == b'abcdefghZ', f'the file on the disk: {d!r}')


# ---------------------------------------------------------------------
# fault -- the carry of every added MLI call
# ---------------------------------------------------------------------
def b_fault(p):
    p.files['G'] = (b'abcdefgh', 4, 0)
    s = {}
    s['r'] = p.open('G', 'ro')                   # fd 3
    s['rd0'] = p.read(3, 3)                      # 'abc'
    s['x'] = p.open('G', 'ap')                   # fd 4: joins R
    s['rd1'] = p.read(3, 1)                      # 'd': R holds the mark
    s['f1'] = p.sync()                           # (GET_EOF patched)
    s['w1'] = p.write(4, b'Z')                   # fails $27
    s['f2'] = p.sync()                           # (SET_MARK patched)
    s['w2'] = p.write(4, b'Z')                   # fails $27
    s['f3'] = p.sync()                           # (restored)
    s['rd2'] = p.read(3, 1)                      # 'e': R's mark is intact
    s['w3'] = p.write(4, b'Z')                   # works, appends
    s['rd3'] = p.read(3, 4)                      # 'fghZ'
    p.close(3)
    p.close(4)
    s['end'] = p.sync()
    p.done()
    p.s = s


def c_fault(x):
    s = x.p.s
    if x.wait(s['f1']) is None:
        return
    for k in ('r', 'rd0', 'x', 'rd1'):
        x.ok(s[k], f'step {k}')
    tb = x.tables()
    es = x.entries(tb)
    rent = [i for i in es if tb['pipe'][i] & 0x80]
    x.check(len(es) == 2 and len(rent) == 1 and tb['owner'] == rent[0],
            f'setup: the READER holds the live mark: owner '
            f'{tb["owner"]} entries {es} flags '
            f'{[hex(tb["pipe"][i]) for i in es]}')
    tok = x.patch('PMLI_GTF_CALL')
    x.release(s['f1'], x.pb)
    if x.wait(s['f2']) is None:
        return
    x.restore(tok)
    x.refused(s['w1'], FAULT, 'a failing GET_EOF fails the append with the '
              'MLI error')
    x.check(x.k1('K_ROOWN') == rent[0], f'K_ROOWN still the reader after a '
            f'failed GET_EOF: {x.k1("K_ROOWN")}')
    tok = x.patch('PMLI_SMARK_CL')
    x.release(s['f2'], x.pb)
    if x.wait(s['f3']) is None:
        return
    x.restore(tok)
    x.refused(s['w2'], FAULT, 'a failing SET_MARK fails the append with '
              'the MLI error')
    x.check(x.k1('K_ROOWN') == rent[0], f'K_ROOWN still the reader after a '
            f'failed SET_MARK (published only after BOTH calls worked): '
            f'{x.k1("K_ROOWN")}')
    d = x.disk('G')
    x.release(s['f3'], x.pb)
    if x.wait(s['end']) is None:
        return
    x.ok(s['rd2'], 'reader read after the faults')
    x.check(ch(x.rb(s['rd2'], 1)) == 'e', f'the reader\'s mark is intact: '
            f'{ch(x.rb(s["rd2"], 1))!r}')
    x.ok(s['w3'], 'the append works once the faults are gone')
    x.check(ch(x.rb(s['rd3'], 4)) == 'fghZ' and x.rt(s['rd3']) == 4,
            f'no byte was written by the failed appends: '
            f'{ch(x.rb(s["rd3"], 4))!r}')
    d = x.disk('G')
    x.check(d == b'abcdefghZ', f'the file on the disk: {d!r}')


MODES = {
    'solo': {'build': b_solo, 'check': c_solo},
    'abi': {'build': b_abi, 'check': c_abi},
    'order': {'build': b_order, 'check': c_order},
    'two': {'build': b_two, 'check': c_two},
    'trunc': {'build': b_trunc, 'check': c_trunc},
    'truncg': {'build': b_truncg, 'check': c_truncg},
    'fork6': {'build': b_fork6, 'check': c_fork6},
    'park5': {'build': lambda p: b_park5(p, False),
              'check': lambda x: c_park5(x, False)},
    'park5g': {'build': lambda p: b_park5(p, True),
               'check': lambda x: c_park5(x, True)},
    'exteof': {'build': b_exteof, 'check': c_exteof},
    'parkown': {'build': b_parkown, 'check': c_parkown},
    'rel': {'build': b_rel, 'check': c_rel},
    'relpin': {'build': b_relpin, 'check': c_relpin},
    'parkadm': {'build': b_parkadm, 'check': c_parkadm},
    'holes': {'build': b_holes, 'check': c_holes},
    'slash': {'build': b_slash, 'check': c_slash},
    'fault': {'build': b_fault, 'check': c_fault},
    'a9': {'build': b_a9, 'check': c_a9},
}


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--play', default=os.path.join(ROOT, 'build',
                                                   'play.po'))
    ap.add_argument('modes', nargs='*', default=list(MODES))
    args = ap.parse_args()
    if not os.path.exists(K2.LISTING):
        print(f'check-oappend: {K2.LISTING} missing -- make play-image')
        return 2
    allf = []
    for m in args.modes:
        f = run_mode(m, os.path.abspath(args.play))
        for x in f:
            print(f'  - {x}')
        print(f'[check-oappend] {m}: {"PASS" if not f else "FAIL"}',
              flush=True)
        allf += f
    if allf:
        print(f'[check-oappend] FAIL: {len(allf)} row(s)')
        return 1
    print('[check-oappend] PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
