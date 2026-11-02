#!/usr/bin/env python3
"""wait_orphan.py -- the ORPHAN-1 rows of check-wait (docs/ORPHAN-1.md).

check_wait.py owns the parent census; this module is its orphan half and
is imported by it (ROWS).  Orphans go to init, at DEATH, V7 / 4.2BSD:

  * every process whose parent died has PCB_PARENT 1 in the annex and in
    K_PAR_SHD before anything reaps (rows 'census', 'routes');
  * a STOPPED orphan gets SIGHUP then SIGCONT through its own
    disposition ('stopped', 'ignored');
  * a HUP death is a new death, so its children are adopted too
    ('grandkids');
  * a ^C sweep adopts ONCE, after the whole sweep ('sweepanc').

Dynamic stops (all on the play image):

  PRC_WAIT_CORE entry, KRN_EXIT   WAIT-1's stable points
  PRC_ADOPT entry                 window opens: who is an orphan NOW
  the instruction after each      window closes: every orphan reads
  route's `jsr PRC_ADOPT`         parent 1 in annex and shadow, and no
                                  reaper ran since the entry
  $BF00 (the MLI) inside a window violation: PRC_ADOPT is MLI-free

The fixtures are hand-assembled BIN programs (spawn / signal / spin /
exit / BRK / kill-self): the shell cannot BRK, kill itself, or ignore
SIGINT for one child only.  ASCII only.
"""
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import measure_wait as MW                                  # noqa: E402

ROOT = os.path.dirname(HERE)
TAG = '[check-wait]'
PCB_COUNT = 48
OFF_EXIT = 6
UNUSED, RUNNABLE, RUNNING, BLOCKED, ZOMBIE, STOPPED = 0, 1, 2, 3, 4, 5
SIG_TBL = 0x7500                     # inc/mm.annex.equ SIG_TBL_ADDR
MLI_ENTRY = 0xBF00
R_SH_PID, R_RESPAWN = 0x1200, 0x1213  # play init's cells (aux bank 1)
STATUS_HUP, STATUS_INT, STATUS_TERM, STATUS_TRAP = 0x81, 0x82, 0x89, 0x85
CTRL_C, CTRL_Z = '\\x03', '\\x1a'


class Fail(Exception):
    pass


# ---------------------------------------------------------------
# fixtures: tiny BIN programs at $0800
# ---------------------------------------------------------------
SYS = {'spawn': 1, 'exit': 2, 'kill': 13, 'signal': 14}
DATA = 0x0900


def prog(*ops):
    """Hand-assemble a BIN from ops:
         ('spawn', path, [argv...])   SYS_SPAWN
         ('signal', signo, action)    SYS_SIGNAL (0 DFL, 1 IGN, 2 CATCH)
         ('exit', status)             SYS_EXIT
         ('killself', signo)          SYS_KILL on our own pid (BANK_ID)
         ('brk',)                     BRK
         ('spin',)                    jmp *
    """
    code = bytearray()
    data = bytearray()

    def alloc(b):
        a = DATA + len(data)
        data.extend(b)
        return a

    def sysc(n, parm):
        code.extend([0xA9, parm & 0xFF, 0xA2, parm >> 8, 0xA0, n,
                     0x20, 0x00, 0xFF])

    for op in ops:
        if op[0] == 'spawn':
            path = alloc(op[1].encode() + b'\0')
            strs = [alloc(a.encode() + b'\0') for a in op[2]]
            argv = alloc(b''.join(bytes([s & 0xFF, s >> 8]) for s in strs)
                         + b'\0\0')
            parm = alloc(bytes([path & 0xFF, path >> 8, argv & 0xFF,
                                argv >> 8, 0, 0, 0, 0]))
            sysc(SYS['spawn'], parm)
        elif op[0] == 'signal':
            sysc(SYS['signal'], alloc(bytes([op[1], op[2]])))
        elif op[0] == 'exit':
            sysc(SYS['exit'], alloc(bytes([op[1]])))
        elif op[0] == 'killself':
            parm = alloc(bytes([0, op[1]]))
            code.extend([0xAD, 0x2E, 0xFF,             # lda BANK_ID
                         0x8D, parm & 0xFF, parm >> 8])  # sta parm+0
            sysc(SYS['kill'], parm)
        elif op[0] == 'brk':
            code.append(0x00)
        elif op[0] == 'spin':
            a = 0x0800 + len(code)
            code.extend([0x4C, a & 0xFF, a >> 8])
        else:
            raise ValueError(op)
    if len(code) > DATA - 0x0800:
        raise ValueError('code too long')
    out = bytearray(DATA - 0x0800 + len(data))
    out[:len(code)] = code
    out[DATA - 0x0800:] = data
    return bytes(out)


SLEEP = ('spawn', '/bin/sleep', ['SLEEP', '4'])
LONG = ('spawn', '/bin/sleep', ['SLEEP', '300'])
# the kill route arms `killp &` and kills it ~1.5M cycles later, +3M of
# lag under MAUX_GATE_RACE=late (GATE-RACE-1): 4 s would be gone
SLEEP_K = ('spawn', '/bin/sleep', ['SLEEP', '10'])
FIXTURES = {
    # one fixture per death route: the parent dies with a live `sleep 4`
    '/TMP/EXITP': prog(SLEEP, ('exit', 0)),
    '/TMP/KILLP': prog(SLEEP_K, ('spin',)),
    '/TMP/KSELF': prog(SLEEP, ('killself', 9)),
    '/TMP/BRKP': prog(SLEEP, ('brk',)),
    # ^C kills the parent but not the child: INT ignored across the
    # spawn (a child inherits IGN), default again for the parent
    '/TMP/CP': prog(('signal', 2, 1), SLEEP, ('signal', 2, 0), ('spin',)),
    # a parent that never waits: its child becomes a zombie it ignores
    '/TMP/ZP': prog(('spawn', '/bin/true', ['TRUE']), ('spin',)),
    # leaves and middles for the stopped / ignored / caught / ancestry rows
    '/TMP/SPIN': prog(('spin',)),
    '/TMP/HIGN': prog(('signal', 1, 1), ('spin',)),
    '/TMP/HCAT': prog(('signal', 1, 2), ('spin',)),
    '/TMP/P2': prog(('spawn', '/tmp/higndx', ['HIGNDX']),
                    ('spawn', '/tmp/hcatdx', ['HCATDX']), ('spin',)),
    '/TMP/HIGNDX': prog(('signal', 1, 1), ('spin',)),
    '/TMP/HCATDX': prog(('signal', 1, 2), ('spin',)),
    '/TMP/M9': prog(('spawn', '/tmp/spin', ['SPIN']), ('spin',)),
    '/TMP/P9': prog(('spawn', '/tmp/m9', ['M9']), ('spin',)),
    '/TMP/L10': prog(('spin',)),
    '/TMP/M10': prog(('spawn', '/tmp/l10', ['L10']), ('spin',)),
    '/TMP/R10': prog(('spawn', '/tmp/m10', ['M10']), ('spin',)),
}
_disk = [None]


def fixture_disk(tree):
    """A copy of play.po with the fixtures staged; built once per run."""
    if _disk[0] is None or not os.path.exists(_disk[0]):
        import check_exec as X
        tmp = tempfile.mkdtemp(prefix='maux-orphan-')
        d = os.path.join(tmp, 'play.po')
        shutil.copy(os.path.join(tree, 'build', 'play.po'), d)
        X.stage(d, {k: (v, 0x06) for k, v in FIXTURES.items()})
        _disk[0] = d
    return _disk[0]


# ---------------------------------------------------------------
# source anchors (listing addresses by source text, so the same
# script reads the built tree and a sabotaged one)
# ---------------------------------------------------------------
def src_lines(tree, fname):
    with open(os.path.join(tree, 'src/kernel', fname), errors='replace') as fh:
        return fh.read().split('\n')


def routine_span(lines, name):
    start = None
    for i, l in enumerate(lines):
        if l and l[0] not in ' \t*;:' and l.split()[0] == name:
            start = i
        elif start is not None and l and l[0] not in ' \t*;:' and \
                not re.match(r'^\S+\s+(equ|ds|dfb|dw|da|dum|dend)\b', l):
            return start, i
    if start is None:
        raise Fail('no routine %s' % name)
    return start, len(lines)


def anchor(tree, fname, routine, after, want):
    """Listing address of the first line matching `want` after the first
    line matching `after` inside `routine` (after=None: the routine's
    start)."""
    lines = src_lines(tree, fname)
    a, b = routine_span(lines, routine)
    i = a
    if after:
        while i < b and not re.search(after, lines[i]):
            i += 1
        if i == b:
            raise Fail('anchor: %r not in %s' % (after, routine))
        i += 1
    while i < b and not re.search(want, lines[i]):
        i += 1
    if i == b:
        raise Fail('anchor: %r not after %r in %s' % (want, after, routine))
    return MW.listing_addr(tree, fname, i + 1)


def post_addrs(tree):
    """{address: route} of the instruction after each route's ADOPT."""
    return {
        anchor(tree, 'process2.s', 'PRC_EXIT', r'jsr\s+PRC_ZOMB',
               r'lda\s+PRC_PAR_PID'): 'exit',
        anchor(tree, 'procspawn2.s', 'PRC_KILL', r'jsr\s+PRC_DIE',
               r'lda\s+PRC_KILL_PAR'): 'kill',
        anchor(tree, 'procspawn2.s', 'PRC_KILL', r'jsr\s+PRC_ZOMB',
               r'lda\s+PRC_KILL_PAR'): 'killself',
        anchor(tree, 'procspawn2.s', 'PRC_BRK_TRAP', r':untagged',
               r'lda\s+PRC_KILL_PAR'): 'brk',
        anchor(tree, 'procspawn2.s', 'PRC_FG_SWP', None,
               r'^:nodie'): 'sweep',
    }


# ---------------------------------------------------------------
# census (static), called from check_wait.row_census
# ---------------------------------------------------------------
def census(src):
    """src: {'src/kernel/x.s': [lines]}.  Returns (bad, info)."""
    from check_wait import routines
    bad = []

    def callers(target, kinds=('jsr', 'jmp')):
        out = []
        for fn, lines in src.items():
            for i, l in enumerate(lines):
                m = re.match(r'(?::\w+)?\s+(%s)\s+%s\b'
                             % ('|'.join(kinds), target), l)
                if m:
                    r = [n for n, a, b in routines(lines) if a <= i < b]
                    out.append((fn.split('/')[-1], r[0] if r else '?', i))
        return out

    # (a) STATE <- ZOMBIE has one writer
    zw = []
    for fn, lines in src.items():
        for i, l in enumerate(lines):
            if re.match(r'\s+lda\s+#PCB_ZOMBIE\b', l) and \
                    re.search(r'sta\s+\(K_PCB_PTR\),y',
                              ' '.join(lines[i:i + 3])):
                r = [n for n, a, b in routines(lines) if a <= i < b]
                zw.append((fn.split('/')[-1], r[0] if r else '?'))
    if zw != [('process2.s', 'PRC_ZOMB')]:
        bad.append('STATE<-ZOMBIE writers %s, wanted PRC_ZOMB only' % zw)
    # (b) the death routes: who marks, who calls the marker
    zc = sorted({(f, r) for f, r, _ in callers('PRC_ZOMB')})
    if zc != [('procspawn2.s', 'PRC_DIE'), ('procspawn2.s', 'PRC_KILL'),
              ('process2.s', 'PRC_EXIT')] and \
            zc != sorted([('procspawn2.s', 'PRC_DIE'),
                          ('procspawn2.s', 'PRC_KILL'),
                          ('process2.s', 'PRC_EXIT')]):
        bad.append('PRC_ZOMB callers %s' % zc)
    dc = sorted({(f, r) for f, r, _ in callers('PRC_DIE')})
    if dc != [('process2.s', 'PRC_ADOPT'),
              ('procspawn2.s', 'PRC_BRK_TRAP'),
              ('procspawn2.s', 'PRC_FG_SWP'),
              ('procspawn2.s', 'PRC_KILL')]:
        bad.append('PRC_DIE callers %s (PRC_ADOPT\'s is the HUP death, '
                   'which loops back for its children)' % dc)
    # (c) PRC_ADOPT's callers are exactly the routes
    ac = sorted((f, r) for f, r, _ in callers('PRC_ADOPT'))
    want = sorted([('process2.s', 'PRC_EXIT'),
                   ('procspawn2.s', 'PRC_KILL'),
                   ('procspawn2.s', 'PRC_KILL'),
                   ('procspawn2.s', 'PRC_BRK_TRAP'),
                   ('procspawn2.s', 'PRC_FG_SWP')])
    if ac != want:
        bad.append('PRC_ADOPT callers %s, wanted %s' % (ac, want))
    # ... each after its death call, and the sweep's AFTER the loop
    for fn, rname, deaths in (('src/kernel/process2.s', 'PRC_EXIT',
                               ['PRC_ZOMB']),
                              ('src/kernel/procspawn2.s', 'PRC_BRK_TRAP',
                               ['PRC_DIE'])):
        lines = src[fn]
        a, b = [(x, y) for n, x, y in routines(lines) if n == rname][0]
        d = [i for i in range(a, b)
             if re.match(r'(?::\w+)?\s+jsr\s+(%s)\b' % '|'.join(deaths),
                         lines[i])]
        j = [i for i in range(a, b)
             if re.match(r'(?::\w+)?\s+jsr\s+PRC_ADOPT\b', lines[i])]
        if not d or not j or j[0] < d[-1]:
            bad.append('%s: PRC_ADOPT is not after the death call' % rname)
    lines = src['src/kernel/procspawn2.s']
    a, b = [(x, y) for n, x, y in routines(lines) if n == 'PRC_KILL'][0]
    for death in ('PRC_DIE', 'PRC_ZOMB'):
        d = [i for i in range(a, b)
             if re.match(r'\s+jsr\s+%s\b' % death, lines[i])]
        j = [i for i in range(a, b)
             if re.match(r'\s+jsr\s+PRC_ADOPT\b', lines[i])]
        if len(d) != 1 or not any(x > d[0] for x in j):
            bad.append('PRC_KILL: no PRC_ADOPT after its %s' % death)
    a, b = [(x, y) for n, x, y in routines(lines) if n == 'PRC_FG_SWP'][0]
    back = [i for i in range(a, b) if re.match(r'\s+jmp\s+:scan\b', lines[i])]
    j = [i for i in range(a, b) if re.match(r'\s+jsr\s+PRC_ADOPT\b', lines[i])]
    if not back or not j or j[0] < max(back):
        bad.append('PRC_FG_SWP: PRC_ADOPT sits inside the per-victim loop '
                   '(it must follow the `jmp :scan` back edge)')
    # (d) PRC_ADOPT never reaches the MLI: its callees are tick-safe
    ok = {'ADP_STATE', 'PAR_CELL', 'PPCB_WR_PAR', 'PRC_SIG_RD',
          'PRC_DIE', 'PRC_SIG_SND', 'PRC_UNSTOP', 'SCH_WAKEUP',
          'PCB_PTR_FOR', 'PCB_RD_FIELDS', 'RUNQ_PUSH'}
    lines = src['src/kernel/process2.s']
    seen = set()
    for rn in ('PRC_ADOPT', 'ADP_STATE', 'PRC_UNSTOP'):
        a, b = [(x, y) for n, x, y in routines(lines) if n == rn][0]
        for i in range(a, b):
            m = re.match(r'\s+(?:jsr|jmp)\s+([A-Z][A-Z0-9_]+)\b', lines[i])
            if m:
                seen.add(m.group(1))
    if not seen <= ok:
        bad.append('PRC_ADOPT reaches %s (allowed: tick-safe set only)'
                   % sorted(seen - ok))
    # (e) the orphan sweep is gone
    for fn, lines_ in src.items():
        for i, l in enumerate(lines_):
            if re.match(r'\s+(?:jsr|jmp)\s+PRC_REAP_ORPH\b', l) or \
                    re.match(r'PRC_REAP_ORPH\b', l):
                bad.append('PRC_REAP_ORPH is back: %s:%d' % (fn, i + 1))
    # (f) the reap clears no shadow of an orphan: PRC_REAP_ONE keeps its
    #     own-cell stz only (checked by WAIT-1's rows)
    info = ('death routes PRC_EXIT / PRC_KILL x2 / PRC_BRK_TRAP / '
            'PRC_FG_SWP each followed by exactly one PRC_ADOPT '
            '(the sweep\'s after its loop), PRC_ADOPT reaches only '
            'tick-safe callees, STATE<-ZOMBIE only in PRC_ZOMB, no '
            'PRC_REAP_ORPH')
    return bad, info


# ---------------------------------------------------------------
# the rig
# ---------------------------------------------------------------
def make_rig(CW, tree, **kw):
    class ORig(CW.Rig):
        """check_wait's Rig plus the adoption windows."""

        def __init__(self, tree, disk=None):
            super().__init__(tree, disk=disk)
            self.adopt = self.sym['PRC_ADOPT']
            self.posts = post_addrs(tree)
            self.windows = []         # closed windows
            self.win = None
            self.mli_in_win = 0
            self.reap_pids = []       # (reaped pid, reaper pid, cycle)
            self.check_orph = True
            for a in [self.adopt, MLI_ENTRY] + list(self.posts):
                self.c.call_tool('break_set', {'addr': a})

        def snapshot(self):
            s = super().snapshot()
            raw = self.peek(CW.PCB_BASE, PCB_COUNT * CW.PCB_SIZE, 'aux', 0)
            s['exit'] = [raw[i * CW.PCB_SIZE + OFF_EXIT]
                         for i in range(PCB_COUNT)]
            return s

        def broken(self, s):
            out = super().broken(s)
            if self.check_orph:
                for p in range(1, PCB_COUNT):
                    q = s['parent'][p]
                    if s['state'][p] != UNUSED and q and \
                            s['state'][q] in (UNUSED, ZOMBIE):
                        out.append('orphan: pid %d (state %d) has %s '
                                   'parent %d' % (p, s['state'][p],
                                                  'a free' if
                                                  s['state'][q] == UNUSED
                                                  else 'a ZOMBIE', q))
            return out

        def on_hit(self, r, label):
            pc = r['pc']
            if self.suspend or self.in_aux():
                return
            if pc == MLI_ENTRY:
                if self.win is not None:
                    self.mli_in_win += 1
                    if len(self.violations) < 12:
                        self.violations.append(
                            'MLI called inside PRC_ADOPT (cycle %d)'
                            % r['cycle'])
            elif pc == self.adopt:
                s = self.snapshot()
                dead = {p for p in range(1, PCB_COUNT)
                        if s['state'][p] == ZOMBIE}
                orph = [p for p in range(1, PCB_COUNT)
                        if s['state'][p] != UNUSED and
                        s['parent'][p] in dead and s['parent'][p] >= 2]
                self.win = {'cycle': r['cycle'], 'pre': s, 'dead': dead,
                            'orphans': orph, 'reaps0': len(self.reaps),
                            'pids0': len(self.reap_pids),
                            'cur': self.curpid()}
            elif pc in self.posts:
                self.close_window(r, self.posts[pc])
            else:
                if pc == self.sym['PRC_REAP_ONE']:
                    g = self.c.call_tool('regs', {})
                    self.reap_pids.append((g['a'], self.curpid(),
                                           r['cycle']))
                super().on_hit(r, label)

        def close_window(self, r, route):
            w = self.win
            self.win = None
            if w is None:
                if route == 'sweep':      # a ^Z (stop-mode) sweep: no
                    self.stop_check('sweep end, no adoption')   # deaths
                    return
                self.viol('route %s: the post-adoption stop was reached '
                          'without PRC_ADOPT having been entered' % route)
                return
            s = self.snapshot()
            self.stops += 1
            rec = {'route': route, 'orphans': w['orphans'],
                   'dead': sorted(w['dead']), 'pre': w['pre'], 'post': s,
                   'cycles': r['cycle'] - w['cycle'], 'cur': w['cur'],
                   'reaped_inside': len(self.reaps) - w['reaps0']}
            self.windows.append(rec)
            for c in w['orphans']:
                if s['state'][c] == UNUSED:
                    self.viol('route %s: orphan %d was freed inside the '
                              'adoption' % (route, c))
                elif s['parent'][c] != 1 or s['shd'][c] != 1:
                    self.viol('route %s: orphan %d reads parent %d / '
                              'shadow %d, wanted 1 / 1 (adoption missed '
                              'at death)' % (route, c, s['parent'][c],
                                             s['shd'][c]))
            if rec['reaped_inside']:
                self.viol('route %s: a reaper ran inside the adoption '
                          'window' % route)
            for v in self.broken(s):
                self.viol('route %s: %s' % (route, v))

        def viol(self, msg):
            if len(self.violations) < 12:
                self.violations.append(msg)

        def kids(self, s, q):
            return [p for p in range(1, PCB_COUNT)
                    if s['state'][p] != UNUSED and s['parent'][p] == q]

    return ORig(tree, **kw)


# ---------------------------------------------------------------
# helpers for the rows
# ---------------------------------------------------------------
LZ_HELD, LZ_SLOT_CNT = 2, 14


def boot(CW, tree):
    rig = make_rig(CW, tree, disk=fixture_disk(tree))
    rig.run(500_000)
    return rig


def occupied(s):
    return {p for p in range(1, PCB_COUNT) if s['state'][p] != UNUSED}


def wait_for(rig, pred, label, budget=12_000_000, step=100_000):
    """Run until pred(snapshot) holds; Fail with `label` otherwise."""
    start = rig.cycle()
    while rig.cycle() - start < budget:
        rig.run(step)
        s = rig.snapshot()
        if pred(s):
            return s
    raise Fail('timed out waiting for %s' % label)


def init_cells(rig):
    """(R_SH_PID, R_RESPAWN) of play init, in its own bank (pid 1)."""
    b = rig.peek(R_SH_PID, 1, 'aux', 1)[0], rig.peek(R_RESPAWN, 1, 'aux', 1)[0]
    return b


def ledger(rig):
    """The bank ledger and the descriptor ledger, from kernel cells."""
    s = rig.snapshot()
    raw = rig.peek(CW_PCB_BASE, PCB_COUNT * 16, 'aux', 0)
    used = {raw[p * 16 + 3] for p in range(PCB_COUNT)
            if raw[p * 16 + 1] != UNUSED}
    free = rig.peek(rig.sym['PRC_FREE_CNT'], 1)[0]
    lz = rig.peek(rig.sym['LZ_STATE'], LZ_SLOT_CNT)
    held = sum(1 for x in lz if x == LZ_HELD)
    oft = rig.peek(rig.sym['OFT_TYPE'], 16)
    refn = rig.peek(rig.sym['OFT_REFNUM'], 16)
    iob = rig.peek(rig.sym['OFT_IOBUF'], 16)
    pipes = rig.peek(rig.sym['PIPE_USED'], 9)
    return {'banks': free + held + len(used),
            'oft': sum(1 for t in oft if t),
            'refnums': sum(1 for t, n in zip(oft, refn) if t and n),
            'iobufs': sum(1 for t, n in zip(oft, iob) if t and n),
            'pipes': sum(1 for x in pipes if x)}


CW_PCB_BASE = 0x0800


def new_kids(rig, before, parent):
    s = rig.snapshot()
    return sorted(p for p in occupied(s) - before
                  if s['parent'][p] == parent)


def cmd_pid(rig, cmd, shell, wait=1_500_000):
    """Run a background `cmd &` and return (pid, snapshot)."""
    before = occupied(rig.snapshot())
    rig.cmd(cmd)
    rig.run(wait)
    kids = new_kids(rig, before, shell)
    if len(kids) != 1:
        raise Fail('%r: wanted one new child of the shell %d, got %s'
                   % (cmd, shell, kids))
    return kids[0]


def reaped_by_init(rig, pid, since, label):
    """pid's slot is free and the reap was init's (K_CURPID 1), not the
    shell's."""
    s = wait_for(rig, lambda s: s['state'][pid] == UNUSED,
                 '%s: pid %d reaped' % (label, pid), budget=12_000_000)
    who = [r for p, r, _ in rig.reap_pids[since:] if p == pid]
    if who != [1]:
        raise Fail('%s: pid %d was reaped by %s, wanted init (1)'
                   % (label, pid, who))
    if s['shd'][pid] != 0:
        raise Fail('%s: freed pid %d keeps shadow %d' % (label, pid,
                                                        s['shd'][pid]))
    return s


def finish(rig, what):
    if rig.violations:
        for v in rig.violations:
            print('%s VIOLATION: %s' % (TAG, v))
        raise Fail('%s: %d violation(s)' % (what, len(rig.violations)))


# ---------------------------------------------------------------
# rows
# ---------------------------------------------------------------
def row_routes(CW, tree):
    """Rows 3 and 4: one case per death route.  The parent dies holding
    a live `sleep 4`; at the stop right after PRC_ADOPT (before any
    reaper) the child reads parent 1 in annex and shadow, and init, not
    the shell, reaps it when it exits."""
    rig = boot(CW, tree)
    try:
        sh = int(re.findall(r'\d+', CW._echo(rig, '$$'))[-1])
        sh0, rsp0 = init_cells(rig)
        cases = []
        for route, cmd in (('exit', '/tmp/exitp'),
                           ('kill', None), ('killself', '/tmp/kself'),
                           ('brk', '/tmp/brkp'), ('sweep', None)):
            n0 = len(rig.windows)
            r0 = len(rig.reap_pids)
            before = occupied(rig.snapshot())
            if route == 'kill':
                par = cmd_pid(rig, '/tmp/killp &', sh)
                rig.cmd('kill -9 %d' % par)
            elif route == 'sweep':
                rig.c.call_tool('type', {'text': '/tmp/cp\r'})
                rig.run(1_800_000)
                rig.c.call_tool('type', {'text': CTRL_C})
                rig.run(1_500_000, until_prompt=True, label='sweep ^C')
            else:
                rig.cmd(cmd)
            wins = [w for w in rig.windows[n0:] if w['route'] == route]
            if len(wins) != 1:
                raise Fail('%s: %d adoption windows on that route, wanted '
                           'one (all: %s)' % (route, len(wins),
                                              [w['route'] for w in
                                               rig.windows[n0:]]))
            w = wins[0]
            kids = [c for c in w['orphans']
                    if w['post']['state'][c] in (RUNNABLE, RUNNING, BLOCKED)]
            if len(kids) != 1:
                raise Fail('%s: wanted exactly one live orphan (the '
                           'sleep), got %s of %s' % (route, kids,
                                                     w['orphans']))
            c = kids[0]
            reaped_by_init(rig, c, r0, route)
            if rig.windows[n0:] and any(x['route'] != route
                                        for x in rig.windows[n0:]):
                pass
            cases.append('%s: orphan %d parent %d->1 (annex+shadow) at '
                         'death, %d cycles, then reaped by init'
                         % (route, c, w['pre']['parent'][c], w['cycles']))
            rig.run(300_000)
        sh1, rsp1 = init_cells(rig)
        if (sh1, rsp1) != (sh0, rsp0):
            raise Fail('routes: init respawned the shell for an adoptee '
                       '(R_SH_PID %d->%d, R_RESPAWN %d->%d)'
                       % (sh0, sh1, rsp0, rsp1))
        finish(rig, 'routes')
        print('%s routes: %s; init\'s R_SH_PID/R_RESPAWN unmoved; %d '
              'stops, %d MLI calls inside a window'
              % (TAG, ' | '.join(cases), rig.stops, rig.mli_in_win),
              flush=True)
    finally:
        rig.close()


def row_reuse(CW, tree):
    """Row 5: the reused-shell pid.  `sleep 300 &`, `kill -9 $$`: the
    respawn lands in the same pid, and the job is NOT its child."""
    rig = boot(CW, tree)
    try:
        rig.cmd('JCM=old')
        shell1 = int(re.findall(r'\d+', CW._echo(rig, '$$'))[-1])
        job = cmd_pid(rig, 'sleep 300 &', shell1)
        sh0, rsp0 = init_cells(rig)
        rig.c.call_tool('type', {'text': 'kill -9 $$\r'})
        rig.run(10_000_000, until_prompt=True, label='respawn')
        mark = CW._echo(rig, 'M-$JCM-').strip()
        shell2 = int(re.findall(r'\d+', CW._echo(rig, '$$'))[-1])
        if mark != 'M--':
            raise Fail('reuse: the shell was not respawned (marker %r)'
                       % mark)
        if shell2 != shell1:
            raise Fail('reuse: the respawn took pid %d, not %d: the row '
                       'proves nothing about pid reuse' % (shell2, shell1))
        sh1, rsp1 = init_cells(rig)
        s = rig.snapshot()
        if (s['state'][job], s['parent'][job], s['shd'][job]) != \
                (BLOCKED, 1, 1):
            raise Fail('reuse: the job reads state %d parent %d shadow %d, '
                       'wanted BLOCKED 1 1' % (s['state'][job],
                                               s['parent'][job],
                                               s['shd'][job]))
        rig.cmd('ps')
        row = [r.split() for r in rig.shown() if r.split()[:1] == [str(job)]]
        # PPID is the FOURTH column, not the last word: PS-ARGS put a
        # COMMAND column after it (2026-11-01), so `sleep 300 &` ends
        # the line in '300' and [-1] read the argument as the parent.
        if not row or len(row[-1]) < 4 or row[-1][3] != '1':
            raise Fail('reuse: ps shows the job as %s, wanted PPID 1 '
                       '(column 4)' % row)
        r0 = len(rig.reap_pids)
        calls0 = rig.done_calls
        rig.cmd('true')
        rig.cmd('true')
        s = rig.snapshot()
        if s['state'][job] != BLOCKED or any(
                p == job for p, _, _ in rig.reap_pids[r0:]):
            raise Fail('reuse: the new shell touched the adopted job')
        if rig.done_calls == calls0:
            raise Fail('reuse: no wait scan ran in the new shell')
        rig.cmd('kill %d' % job)
        reaped_by_init(rig, job, r0, 'reuse')
        sh2, rsp2 = init_cells(rig)
        if (sh2, rsp2) != (sh1, rsp1):
            raise Fail('reuse: init respawned for the adoptee (R_SH_PID '
                       '%d->%d, R_RESPAWN %d->%d)' % (sh1, sh2, rsp1, rsp2))
        rig.c.call_tool('type', {'text': 'kill -9 $$\r'})
        rig.run(10_000_000, until_prompt=True, label='second respawn')
        sh3, rsp3 = init_cells(rig)
        if rsp3 != rsp2 + 1:
            raise Fail('reuse: killing the real shell cost %d respawns, '
                       'wanted exactly one' % (rsp3 - rsp2))
        finish(rig, 'reuse')
        print('%s reuse: shell %d killed and respawned into pid %d, '
              'marker %s; its `sleep 300 &` (pid %d) read PPID 1 in the '
              'annex, the shadow and `ps`; the new shell\'s scans (%d, '
              'contract-checked) excluded it and reaped nothing; `kill` '
              'made it a zombie and INIT reaped it; R_SH_PID %d and '
              'R_RESPAWN %d did not move for it; killing the real shell '
              'then cost exactly one respawn (R_RESPAWN %d)'
              % (TAG, shell1, shell2, mark, job, rig.done_calls - calls0,
                 sh1, rsp1, rsp3), flush=True)
    finally:
        rig.close()


def row_zombie(CW, tree):
    """Row 6: a child exits while its parent does not wait; the parent
    is killed: the zombie is adopted, init is woken and reaps it."""
    rig = boot(CW, tree)
    try:
        sh = int(re.findall(r'\d+', CW._echo(rig, '$$'))[-1])
        before = occupied(rig.snapshot())
        zp = cmd_pid(rig, '/tmp/zp &', sh, wait=300_000)
        s = wait_for(rig, lambda s: any(
            s['parent'][p] == zp and s['state'][p] == ZOMBIE
            for p in range(1, PCB_COUNT)), 'the child to become a zombie')
        kid = [p for p in range(1, PCB_COUNT)
               if s['parent'][p] == zp and s['state'][p] == ZOMBIE][0]
        n0, r0 = len(rig.windows), len(rig.reap_pids)
        rig.cmd('kill -9 %d' % zp)
        w = [x for x in rig.windows[n0:] if x['route'] == 'kill']
        if len(w) != 1 or kid not in w[0]['orphans']:
            raise Fail('zombie: pid %d was not an orphan of the kill: %s'
                       % (kid, w and w[0]['orphans']))
        if w[0]['post']['state'][kid] != ZOMBIE or \
                w[0]['post']['parent'][kid] != 1:
            raise Fail('zombie: after adoption the zombie reads state %d '
                       'parent %d' % (w[0]['post']['state'][kid],
                                      w[0]['post']['parent'][kid]))
        reaped_by_init(rig, kid, r0, 'zombie')
        finish(rig, 'zombie')
        print('%s zombie: pid %d exited with its parent %d not waiting; '
              '`kill -9 %d` adopted the zombie (parent 1 at death), init '
              'was woken and reaped it' % (TAG, kid, zp, zp), flush=True)
    finally:
        rig.close()


def stopped_job(rig, CW, sh, cmd, nkids, wait=6_000_000):
    """Start `cmd` in the foreground, ^Z it; return its pids (job pid
    first).  The job and all its descendants must read STOPPED."""
    before = occupied(rig.snapshot())
    rig.c.call_tool('type', {'text': cmd + '\r'})
    rig.run(wait)
    rig.c.call_tool('type', {'text': CTRL_Z})
    rig.run(2_000_000, until_prompt=True, label='^Z')
    s = rig.snapshot()
    pids = sorted(occupied(s) - before)
    stopped = [p for p in pids if s['state'][p] == STOPPED]
    if len(stopped) != nkids or set(stopped) != set(pids):
        raise Fail('%r: wanted %d stopped processes, got %s' % (
            cmd, nkids, [(p, s['state'][p]) for p in pids]))
    job = [p for p in pids if s['parent'][p] == sh]
    if len(job) != 1:
        raise Fail('%r: wanted one job pid, got %s' % (cmd, job))
    return job[0], pids, s


def row_stopped(CW, tree):
    """Row 7: a stopped adoptee with the default HUP: status $81 under
    init; its OFT entry, refnum, io_buffer and pipe are reclaimed and its
    bank and slot are free (kernel cells, not ps)."""
    rig = boot(CW, tree)
    try:
        sh = int(re.findall(r'\d+', CW._echo(rig, '$$'))[-1])
        rig.cmd('echo x > /tmp/f7')
        rig.cmd("echo 'tail -f /tmp/f7 | wc' > /tmp/s7")
        base = ledger(rig)
        job, pids, s = stopped_job(rig, CW, sh, 'sh /tmp/s7', 3)
        held = ledger(rig)
        if not (held['oft'] > base['oft'] and held['pipes'] > base['pipes']
                and held['iobufs'] > base['iobufs']):
            raise Fail('stopped: the stopped pipeline holds no OFT/pipe '
                       'entry (%s vs %s): the row proves nothing'
                       % (held, base))
        kids = [p for p in pids if p != job]
        n0, r0 = len(rig.windows), len(rig.reap_pids)
        rig.cmd('kill -9 %d' % job)
        w = [x for x in rig.windows[n0:] if x['route'] == 'kill']
        if len(w) != 1 or set(w[0]['orphans']) != set(kids):
            raise Fail('stopped: orphans %s, wanted %s'
                       % (w and w[0]['orphans'], kids))
        for c in kids:
            if (w[0]['post']['state'][c], w[0]['post']['exit'][c],
                    w[0]['post']['parent'][c]) != (ZOMBIE, STATUS_HUP, 1):
                raise Fail('stopped: adoptee %d reads state %d status $%02X '
                           'parent %d after adoption, wanted ZOMBIE $81 1'
                           % (c, w[0]['post']['state'][c],
                              w[0]['post']['exit'][c],
                              w[0]['post']['parent'][c]))
        for c in kids:
            reaped_by_init(rig, c, r0, 'stopped')
        rig.run(500_000)
        after = ledger(rig)
        if after != base:
            raise Fail('stopped: descriptors/banks not reclaimed: base %s '
                       'after %s' % (base, after))
        finish(rig, 'stopped')
        print('%s stopped: ^Z stopped `sh`, `tail -f` (open file + pipe) '
              'and `wc`; killing the sh adopted both into init and the '
              'default HUP made them $81 zombies at death; init reaped '
              'them; ledger at the stop %s, after %s == before %s'
              % (TAG, held, after, base), flush=True)
    finally:
        rig.close()


def row_ignored(CW, tree):
    """Row 8: HUP ignored and HUP caught: continued and running; the
    caught one sees HUP pending; neither dies $81."""
    rig = boot(CW, tree)
    try:
        sh = int(re.findall(r'\d+', CW._echo(rig, '$$'))[-1])
        job, pids, s = stopped_job(rig, CW, sh, '/tmp/p2', 3, wait=4_000_000)
        kids = [p for p in pids if p != job]
        n0 = len(rig.windows)
        rig.cmd('kill -9 %d' % job)
        w = [x for x in rig.windows[n0:] if x['route'] == 'kill']
        if len(w) != 1 or set(w[0]['orphans']) != set(kids):
            raise Fail('ignored: orphans %s, wanted %s'
                       % (w and w[0]['orphans'], kids))
        post = w[0]['post']
        pend = {c: rig.peek(SIG_TBL + 8 * c + 4, 1, 'aux', 0)[0] & 1
                for c in kids}
        ign = [c for c in kids if pend[c] == 0]
        cat = [c for c in kids if pend[c] == 1]
        if len(ign) != 1 or len(cat) != 1:
            raise Fail('ignored: pending HUP bits %s: wanted one ignorer '
                       '(clear) and one catcher (set)' % pend)
        for c in kids:
            if post['state'][c] in (ZOMBIE, STOPPED, UNUSED) or \
                    post['parent'][c] != 1:
                raise Fail('ignored: adoptee %d reads state %d parent %d '
                           'right after adoption, wanted continued under '
                           'init' % (c, post['state'][c], post['parent'][c]))
        rig.run(1_000_000)
        s = rig.snapshot()
        for c in kids:
            if s['state'][c] not in (RUNNABLE, RUNNING, BLOCKED) or \
                    s['exit'][c] == STATUS_HUP:
                raise Fail('ignored: adoptee %d is state %d status $%02X '
                           'later: it did not run on' % (c, s['state'][c],
                                                         s['exit'][c]))
        for c in kids:
            rig.cmd('kill -9 %d' % c)
        rig.run(1_000_000)
        finish(rig, 'ignored')
        print('%s ignored: stopped HUP-ignorer %d and HUP-catcher %d were '
              'adopted and CONTINUED (states %s), the catcher with HUP '
              'pending, neither $81; they run on' % (
                  TAG, ign[0], cat[0],
                  {c: post['state'][c] for c in kids}), flush=True)
    finally:
        rig.close()


def row_grandkids(CW, tree):
    """Row 9: live P -> C -> G: kill P leaves G with C.  Stopped P -> C
    -> G: C dies $81 and G is adopted by 1 (and, stopped, dies $81 too:
    the cascade)."""
    rig = boot(CW, tree)
    try:
        sh = int(re.findall(r'\d+', CW._echo(rig, '$$'))[-1])
        # (a) live
        p = cmd_pid(rig, '/tmp/p9 &', sh, wait=3_000_000)
        s = rig.snapshot()
        c = [x for x in range(1, PCB_COUNT)
             if s['state'][x] != UNUSED and s['parent'][x] == p]
        if len(c) != 1:
            raise Fail('grandkids: P %d has children %s' % (p, c))
        c = c[0]
        g = [x for x in range(1, PCB_COUNT)
             if s['state'][x] != UNUSED and s['parent'][x] == c]
        if len(g) != 1:
            raise Fail('grandkids: C %d has children %s' % (c, g))
        g = g[0]
        n0 = len(rig.windows)
        rig.cmd('kill -9 %d' % p)
        w = [x for x in rig.windows[n0:] if x['route'] == 'kill'][0]
        if w['orphans'] != [c]:
            raise Fail('grandkids: orphans %s, wanted only C %d'
                       % (w['orphans'], c))
        if (w['post']['parent'][c], w['post']['parent'][g]) != (1, c):
            raise Fail('grandkids: C parent %d, G parent %d, wanted 1 and '
                       '%d (the subtree is not flattened)'
                       % (w['post']['parent'][c], w['post']['parent'][g], c))
        rig.cmd('kill -9 %d' % c)
        rig.cmd('kill -9 %d' % g)
        rig.run(1_000_000)
        finish(rig, 'grandkids (live)')
        # (b) stopped.  The scan visits pids ascending, so a grandchild
        # with a HIGHER pid than its HUP-killed parent is adopted in the
        # same pass and the cascade is never exercised (a tooth that
        # skips the repeat pass stayed green on such a tree).  A fresh
        # boot, and a `spin` bank tagged by an earlier run, give the
        # grandchild the LOW pid: the warm-spawn preference hands the
        # tagged bank to the next `spin`, while P9 and M9 take free ones.
    finally:
        rig.close()
    rig = boot(CW, tree)
    try:
        sh = int(re.findall(r'\d+', CW._echo(rig, '$$'))[-1])
        warm = cmd_pid(rig, '/tmp/spin &', sh, wait=800_000)
        rig.cmd('kill -9 %d' % warm)
        rig.cmd('true')                 # the shell reaps the job here
        wait_for(rig, lambda s: s['state'][warm] == UNUSED,
                 'the priming spin reaped', budget=3_000_000)
        job, pids, s = stopped_job(rig, CW, sh, '/tmp/p9', 3, wait=3_500_000)
        kids = sorted(p_ for p_ in pids if p_ != job)
        mid = [k for k in kids if s['parent'][k] == job][0]
        leaf = [k for k in kids if s['parent'][k] == mid][0]
        if not leaf < mid:
            raise Fail('grandkids: leaf %d is not below its parent %d: the '
                       'repeat pass is not exercised, the row proves '
                       'nothing' % (leaf, mid))
        n0 = len(rig.windows)
        rig.cmd('kill -9 %d' % job)
        w = [x for x in rig.windows[n0:] if x['route'] == 'kill'][0]
        post = w['post']
        for k in (mid, leaf):
            if (post['state'][k], post['exit'][k], post['parent'][k]) != \
                    (ZOMBIE, STATUS_HUP, 1):
                raise Fail('grandkids: stopped descendant %d reads state '
                           '%d status $%02X parent %d, wanted ZOMBIE $81 1'
                           % (k, post['state'][k], post['exit'][k],
                              post['parent'][k]))
        rig.run(2_000_000)
        finish(rig, 'grandkids')
        print('%s grandkids: live P -> C -> G: kill P gave C parent 1 and '
              'left G with C; stopped P -> C -> G with G\'s pid %d BELOW '
              'C\'s %d: C died $81, and only the repeat pass reaches G, '
              'which was adopted by 1 and (stopped) died $81'
              % (TAG, leaf, mid), flush=True)
    finally:
        rig.close()


def row_sweepanc(CW, tree):
    """Row 10: a three-generation foreground tree whose root and middle
    are visited before the leaf: ^C kills the whole ancestry, and the
    adoption starts only after the sweep."""
    rig = boot(CW, tree)
    try:
        sh = int(re.findall(r'\d+', CW._echo(rig, '$$'))[-1])
        before = occupied(rig.snapshot())
        rig.c.call_tool('type', {'text': '/tmp/r10\r'})
        rig.run(4_000_000)
        s = rig.snapshot()
        tree_ = sorted(occupied(s) - before)
        if len(tree_) != 3 or not (s['parent'][tree_[1]] == tree_[0] and
                                   s['parent'][tree_[2]] == tree_[1]):
            raise Fail('sweepanc: the fixture tree is %s (parents %s): not '
                       'a root < middle < leaf chain, the row proves '
                       'nothing' % (tree_, [s['parent'][x] for x in tree_]))
        n0 = len(rig.windows)
        rig.c.call_tool('type', {'text': CTRL_C})
        rig.run(1_500_000, until_prompt=True, label='sweep ^C')
        w = [x for x in rig.windows[n0:] if x['route'] == 'sweep']
        if len(w) != 1:
            raise Fail('sweepanc: %d sweep adoptions, wanted exactly one'
                       % len(w))
        pre = w[0]['pre']
        for x in tree_:
            if pre['state'][x] != ZOMBIE:
                raise Fail('sweepanc: pid %d was %d when adoption began: '
                           'the sweep had not killed the whole ancestry '
                           'first' % (x, pre['state'][x]))
        r, m, l = tree_
        post = w[0]['post']
        for x in tree_:
            if post['exit'][x] != STATUS_INT:
                raise Fail('sweepanc: pid %d status $%02X, wanted $82 (^C)'
                           % (x, post['exit'][x]))
        if (post['parent'][m], post['parent'][l]) != (1, 1):
            raise Fail('sweepanc: middle/leaf parents %d/%d, wanted 1/1'
                       % (post['parent'][m], post['parent'][l]))
        finish(rig, 'sweepanc')
        print('%s sweepanc: root %d < middle %d < leaf %d, ^C: all three '
              'were ZOMBIE ($82) when the single adoption began (after the '
              'sweep); the dead middle and leaf were then adopted by init'
              % (TAG, r, m, l), flush=True)
    finally:
        rig.close()


def row_bye(CW, tree):
    """Row 13: a bye round trip with a live adoptee: annex and shadow
    still read 1 after the resume; it exits and init reaps it."""
    rig = boot(CW, tree)
    try:
        rig.cmd("echo 'sleep 60 &' > /tmp/b13")
        before = occupied(rig.snapshot())
        rig.cmd('sh /tmp/b13')
        rig.run(500_000)
        kid = [p for p in occupied(rig.snapshot()) - before]
        s = rig.snapshot()
        kid = [p for p in kid if s['parent'][p] == 1]
        if len(kid) != 1:
            raise Fail('bye: wanted one adoptee, got %s' % kid)
        kid = kid[0]
        rig.suspend = True
        rig.cmd('bye', budget=60_000_000)
        rig.suspend = False
        if not rig.t.visible('Welcome back'):
            raise Fail('bye did not come back')
        s = rig.stop_check('after bye')
        if (s['state'][kid], s['parent'][kid], s['shd'][kid]) != \
                (BLOCKED, 1, 1):
            raise Fail('bye: the adoptee reads state %d parent %d shadow '
                       '%d after the round trip' % (s['state'][kid],
                                                    s['parent'][kid],
                                                    s['shd'][kid]))
        r0 = len(rig.reap_pids)
        rig.cmd('kill %d' % kid)
        reaped_by_init(rig, kid, r0, 'bye')
        finish(rig, 'bye')
        print('%s bye: adoptee %d kept parent 1 (annex and shadow) across '
              'the round trip, then exited and init reaped it'
              % (TAG, kid), flush=True)
    finally:
        rig.close()


# ---------------------------------------------------------------
# a light watcher for gates that own a raw MCP client (check-jobctl-a)
# ---------------------------------------------------------------
class AdoptWatch:
    """Breakpoints on PRC_ADOPT's entry, each route's post-adoption
    instruction and PRC_REAP_ONE, on a client some other harness drives.
    `run(cycles)` resumes and processes the hits; `windows` collects what
    each adoption looked like at its stop, `reaps` the (pid, reaper)."""

    PCB_BASE = 0x0800

    def __init__(self, c, tree):
        import check_sleep as CS
        self.c = c
        self.sym = CS.read_syms(tree)
        self.posts = post_addrs(tree)
        self.adopt = self.sym['PRC_ADOPT']
        self.reap = self.sym['PRC_REAP_ONE']
        self.shd = self.sym['K_PAR_SHD']
        self.curpid = self.sym['K_CURPID']
        self.windows, self.reaps, self.win = [], [], None
        self.addrs = [self.adopt, self.reap] + list(self.posts)
        for a in self.addrs:
            c.call_tool('break_set', {'addr': a})
        # MAUX_GATE_RACE=late: the lag after an arming line must run
        # through the breakpoints too (GATE-RACE-1, docs/GATE-PREDICATES)
        self.old_lag = c.gr_lag
        c.gr_lag = self.run

    def close(self):
        self.c.gr_lag = self.old_lag
        for a in self.addrs:
            self.c.call_tool('break_clear', {'addr': a})

    def table(self):
        raw = self.c.call_tool('peek', {'addr': self.PCB_BASE,
                                        'count': PCB_COUNT * 16,
                                        'bank': 'aux', 'aux_bank': 0})
        raw = raw.get('bytes') or raw.get('data')
        shd = self.c.call_tool('peek', {'addr': self.shd,
                                        'count': PCB_COUNT + 1,
                                        'bank': 'main'})
        shd = shd.get('bytes') or shd.get('data')
        return {p: {'state': raw[p * 16 + 1], 'parent': raw[p * 16 + 4],
                    'exit': raw[p * 16 + 6], 'shd': shd[PCB_COUNT - p]}
                for p in range(PCB_COUNT)}

    def _main(self):
        r = self.c.call_tool('softswitches', {})
        return not r.get('RAMRD')

    def run(self, cycles):
        """Resume for the whole span, past every breakpoint hit, and
        count it in c.gr_cycles like a step (GATE-RACE-1)."""
        start = cur = self.c.call_tool('regs', {})['cycle']
        while cur < start + cycles:
            cur = self._resume(start + cycles - cur)['cycle']
        self.c.gr_cycles += cur - start

    def _resume(self, cycles):
        r = self.c.call_tool('resume', {'max_cycles': cycles})
        if not r.get('hit_breakpoint') or not self._main():
            return r
        pc = r['pc']
        if pc == self.adopt:
            t = self.table()
            dead = {p for p, e in t.items() if e['state'] == ZOMBIE}
            self.win = {'orph': [p for p, e in t.items()
                                 if e['state'] != UNUSED and
                                 e['parent'] in dead and e['parent'] >= 2],
                        'reaps': len(self.reaps), 'pre': t}
        elif pc in self.posts and self.win is not None:
            w, self.win = self.win, None
            w['post'] = self.table()
            w['route'] = self.posts[pc]
            w['reaped_inside'] = len(self.reaps) - w['reaps']
            self.windows.append(w)
        elif pc == self.reap:
            g = self.c.call_tool('regs', {})
            cur = self.c.call_tool('peek', {'addr': self.curpid, 'count': 1,
                                            'bank': 'main'})
            cur = (cur.get('bytes') or cur.get('data'))[0]
            self.reaps.append((g['a'], cur))
        return r
