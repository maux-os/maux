#!/usr/bin/env python3
"""check_wait.py -- docs/WAIT-1.md + docs/ORPHAN-1.md: the parent shadow
K_PAR_SHD agrees with the annex PCBs, PRC_WAIT_CORE still answers as it
did, and orphans go to init at death.

The invariant, for every pid p in 0..47 (WAIT-1.md "Then build"):

    shadow[p] == PCB[p].PARENT     while p's slot is occupied
    shadow[p] == 0                 while it is free

(a free slot's PCB_PARENT is 0 too, so this is one comparison; the rows
also read STATE so a violation says which case it was).  It holds at the
STABLE points: every PRC_WAIT_CORE entry and every syscall exit
(KRN_EXIT), plus (ORPHAN-1) the end of each foreground sweep and the BRK
path after its adoption.  At every one of them no occupied non-root
process has an UNUSED or ZOMBIE parent.  It does not hold inside one
masked reap (STATE goes UNUSED before PARENT and the shadow are
cleared), which is why no mid-syscall stop is asserted.

  python3 scripts/check_wait.py               the gate (all rows)
  python3 scripts/check_wait.py --only ROW .. named rows
  python3 scripts/check_wait.py --tree TREE   another built tree

Rows (the ORPHAN-1 ones live in scripts/wait_orphan.py):

  census    static: every store that can write PCB_PARENT is a known
            site, no PPCB_WR_BYTE caller hands it PCB_PARENT, every
            shadow store sits after a RAMWRTMAIN, the writers of
            STATE <- UNUSED are SCH_INIT and PRC_REAP_ONE only; and the
            death-route census (STATE <- ZOMBIE only in PRC_ZOMB, the
            callers of PRC_ZOMB / PRC_DIE, PRC_ADOPT's callers exactly
            the routes, none inside the sweep's per-victim loop,
            PRC_ADOPT MLI-free, PRC_REAP_ORPH gone).
  boot      the shadow's 48 cells are poisoned with $A5 before SCH_INIT;
            at the first prompt none survives and the invariant holds.
  workload  the invariant at every stop over: a spawn child and a
            subshell child with their statuses, three zombies reaped in
            ascending pid order, a `$( )` beside an `&` job, an orphan
            adopted by init and reaped by it, a recipe-running make, the
            measurement set, a `bye` round trip.
  routes    one case per death route (exit, kill, kill-self, BRK, ^C):
            the orphan reads parent 1 at the stop after PRC_ADOPT,
            before any reaper; init reaps it.
  reuse     the reused-shell pid: the job is init's, not the new shell's.
  zombie    a zombie orphan is adopted and init is woken.
  stopped   a stopped orphan takes the default HUP ($81); descriptors
            and banks are reclaimed.
  ignored   HUP ignored / caught: continued, runs, caught one pending.
  grandkids live and stopped P -> C -> G; the HUP death cascades.
  sweepanc  a three-generation foreground tree dies whole; adoption
            starts after the sweep.
  bye       a live adoptee across a `bye` round trip.
  fork      a SYS_FORK child (the only client is check-fork's
            forktest image; the shell never forks) is published and
            reaped with its pid: check_fork.py, via --forkimage.
  stale     a poisoned cell of a FREE slot is filtered by the annex
            re-check: `wait` with no children still answers ECHILD.
  speed     waitjob(WNOHANG) with one running child <= 2,000 cycles a
            call (median and max); the loop nest with one background
            job within 110% of the nest with none.

Needs build/play.po and build/MAUXPLAY.SYSTEM_Output.txt.  Teeth:
scripts/teeth_wait.py, scripts/teeth_orphan.py.  ASCII only.
"""
import os
import re
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR     # noqa: E402
import e2e_term as T                                       # noqa: E402
from pt_f40 import (PT_F40_ADDR, PT_F40B_ADDR,             # noqa: E402
                    PT_F40_MAG1, PT_F40_MAG2)
import check_sleep as CS                                   # noqa: E402
import measure_wait as MW                                  # noqa: E402
import wait_orphan as WO                                   # noqa: E402

ROOT = os.path.dirname(HERE)
TAG = '[check-wait]'
PCB_BASE, PCB_COUNT, PCB_SIZE = 0x0800, 48, 16
OFF_STATE, OFF_PARENT = 1, 4
UNUSED, BLOCKED, ZOMBIE, STOPPED = 0, 3, 4, 5
SLICE = 150_000
POISON = 0xA5
SPEED_CALL_MAX = 2000
SPEED_NEST = 1.10
FORKIMAGE = [None]


class Fail(Exception):
    pass


def die(msg):
    print('%s FAIL: %s' % (TAG, msg), flush=True)
    sys.exit(1)


# ---------------------------------------------------------------
# the source tree, for the census
# ---------------------------------------------------------------
def kernel_sources(tree):
    out = {}
    for sub in ('src/kernel', 'src/test'):
        d = os.path.join(tree, sub)
        for fn in sorted(os.listdir(d)):
            if fn.endswith('.s'):
                with open(os.path.join(d, fn), errors='replace') as fh:
                    out[sub + '/' + fn] = fh.read().split('\n')
    return out


def routines(lines):
    """[(label, first_line_index, last_line_index_exclusive)] of the
    global (column-0, non-comment) labels."""
    marks = [(i, l.split()[0]) for i, l in enumerate(lines)
             if l and l[0] not in ' \t*;:' and not re.match(r'^\S+\s+(equ|ds|dfb|dw|da|dum|dend)\b', l)]
    return [(n, i, marks[k + 1][0] if k + 1 < len(marks) else len(lines))
            for k, (i, n) in enumerate(marks)]


def row_census(tree):
    src = kernel_sources(tree)
    bad = []
    # (1) stores of PCB_PARENT through (K_PCB_PTR),y
    stores = []
    for fn, lines in src.items():
        for i, l in enumerate(lines):
            if re.match(r'\s+ldy\s+#PCB_PARENT\b', l):
                nxt = ' '.join(lines[i:i + 3])
                if re.search(r'sta\s+\(K_PCB_PTR\),y', nxt):
                    stores.append((fn, i))
    known = {('src/kernel/sched.s', 'SCH_CREATE'),
             ('src/kernel/process2.s', 'PRC_REAP_ONE')}
    seen = set()
    for fn, i in stores:
        r = [n for n, a, b in routines(src[fn]) if a <= i < b]
        site = (fn, r[0] if r else '?')
        seen.add(site)
        if site not in known:
            bad.append('unknown PCB_PARENT store %s:%d (%s)' % (fn, i + 1,
                                                                 site[1]))
    if seen != known:
        bad.append('PCB_PARENT store sites %s != %s' % (sorted(seen),
                                                         sorted(known)))
    # (2) the generic writer is never handed PCB_PARENT outside
    #     PPCB_WR_PAR
    for fn, lines in src.items():
        for i, l in enumerate(lines):
            if re.match(r'\s+lda\s+#PCB_PARENT\b', l) and \
                    re.search(r'sta\s+P_TMP\b', ' '.join(lines[i:i + 3])):
                r = [n for n, a, b in routines(lines) if a <= i < b]
                name = r[0] if r else '?'
                if name != 'PPCB_WR_PAR':
                    bad.append('lda #PCB_PARENT outside PPCB_WR_PAR: '
                               '%s:%d (%s)' % (fn, i + 1, name))
    # (3) every shadow store, and what closes the bracket before it
    shd_sites = []
    for fn, lines in src.items():
        for i, l in enumerate(lines):
            if re.match(r'\s+(sta|stz)\s+K_PAR_SHD\b', l):
                r = [n for n, a, b in routines(lines) if a <= i < b][0]
                a0 = [x for n, a, b in routines(lines) if n == r
                      for x in (a,)][0]
                back = None
                for j in range(i - 1, a0 - 1, -1):
                    t = lines[j]
                    if re.search(r'\bRAMWRTMAIN\b', t) and \
                            not t.lstrip().startswith(('*', ';')):
                        back = 'RAMWRTMAIN'
                        break
                    if re.search(r'\bRAMWRTAUX\b', t) and \
                            not t.lstrip().startswith(('*', ';')):
                        back = 'RAMWRTAUX'
                        break
                    if re.match(r'\s+jsr\s+PPCB_WR_BYTE\b', t):
                        back = 'PPCB_WR_BYTE'
                        break
                shd_sites.append((fn, r, back))
                if back not in ('RAMWRTMAIN', 'PPCB_WR_BYTE'):
                    bad.append('shadow store in %s:%s is not after a '
                               'RAMWRTMAIN (nearest: %s)' % (fn, r, back))
    names = sorted((fn.split('/')[-1], r) for fn, r, _ in shd_sites)
    want = [('process2.s', 'PRC_REAP_ONE'), ('procfd.s', 'PPCB_WR_PAR'),
            ('sched.s', 'SCH_INIT')]
    if names != want:
        bad.append('shadow store sites %s != %s' % (names, want))
    # (4) STATE <- UNUSED writers
    unused = []
    for fn, lines in src.items():
        for i, l in enumerate(lines):
            if re.match(r'\s+lda\s+#PCB_UNUSED\b', l):
                r = [n for n, a, b in routines(lines) if a <= i < b]
                unused.append((fn.split('/')[-1], r[0] if r else '?'))
    if sorted(unused) != [('process2.s', 'PRC_REAP_ONE'),
                          ('sched.s', 'SCH_INIT')]:
        bad.append('PCB_UNUSED writers %s' % sorted(unused))
    # (5) PPCB_WR_BYTE callers: the 4 known, none of them a parent write
    callers = []
    for fn, lines in src.items():
        for i, l in enumerate(lines):
            if re.match(r'\s+jsr\s+PPCB_WR_BYTE\b', l):
                r = [n for n, a, b in routines(lines) if a <= i < b]
                callers.append((fn.split('/')[-1], r[0] if r else '?'))
    b2, info2 = WO.census(src)
    bad += b2
    if bad:
        for b in bad:
            print('%s census: %s' % (TAG, b))
        raise Fail('census')
    print('%s census: PCB_PARENT stores %s; PPCB_WR_BYTE callers %d (none '
          'writes the parent); shadow stores %s, each after RAMWRTMAIN; '
          'STATE<-UNUSED %s' % (TAG, sorted(s[1] for s in seen),
                                len(callers),
                                [n[1] for n in names],
                                [u[1] for u in sorted(unused)]))
    print('%s census: %s' % (TAG, info2))


# ---------------------------------------------------------------
# the rig
# ---------------------------------------------------------------
class Rig:
    def __init__(self, tree, poison_boot=False, disk=None, bps=True):
        self.tree = tree
        self.disk = disk or os.path.join(tree, 'build', 'play.po')
        self.sym = CS.read_syms(tree)
        self.shd = self.sym.get('K_PAR_SHD')    # None: the base kernel
        self.env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
        self.c = MCPClient([SUPERVISOR], self.env)
        self.c.initialize()
        # MAUX_GATE_RACE=late: the lag must go through run(), or the
        # breakpoints and the invariant checks lose the cycles it spans
        self.c.gr_lag = lambda n: self.run(n, label='gate-race late lag')
        self.stops = 0
        self.wait_calls = 0
        self.violations = []
        self.reaps = []              # PRC_REAP_ONE entry pids, in order
        self.parent_callers = {}     # PPCB_WR_PAR return -> count
        self.suspend = False
        self.check_inv = True       # False: the contract stops only
        self.names = sorted((a, n) for n, a in self.sym.items()
                            if 0x2000 <= a < 0xA000)
        self.stop_pcs = {self.sym['PRC_WAIT_CORE']: 'PRC_WAIT_CORE',
                         self.sym['KRN_EXIT']: 'KRN_EXIT'}
        self.log_pcs = {self.sym['PRC_REAP_ONE']: 'PRC_REAP_ONE',
                        }
        if 'PPCB_WR_PAR' in self.sym:
            self.log_pcs[self.sym['PPCB_WR_PAR']] = 'PPCB_WR_PAR'
        # the end of PRC_WAIT_CORE's scan (`:done`): the contract row
        done = MW.src_line(tree, 'src/kernel/process2.s', r':done\b')
        self.done_pc = MW.listing_addr(tree, 'process2.s', done)
        self.done_calls = 0
        self.snaps = []
        self.rows = self.listing_rows()
        self.boot(poison_boot)
        if bps:
            for a in (list(self.stop_pcs) + list(self.log_pcs) +
                      [self.done_pc]):
                self.c.call_tool('break_set', {'addr': a})

    def listing_rows(self):
        """{address: 'file.s:line'} for the Code rows of the listing."""
        pat = re.compile(r'\|\s*\d+\s+\S*?([A-Za-z0-9_.]+\.s)\s+(\d+) \|\s*Code\s*\|'
                         r'[^|]*\|[^|]*\|[^|]*\|\s*00/([0-9A-F]{4})')
        out = {}
        path = os.path.join(self.tree, 'build', 'MAUXPLAY.SYSTEM_Output.txt')
        with open(path, encoding='ascii', errors='replace') as fh:
            for row in fh:
                m = pat.search(row)
                if m:
                    out.setdefault(int(m.group(3), 16),
                                   '%s:%s' % (m.group(1), m.group(2)))
        return out

    def where(self, ret):
        """The source line of the jsr whose return address is `ret`."""
        for a in (ret - 2, ret - 1, ret - 3):
            if a in self.rows:
                return self.rows[a]
        return '$%04X' % ret

    # -- boot ------------------------------------------------------
    def boot(self, poison):
        c = self.c
        c.call_tool('reset', {'backend': 'fast', 'aux': 'ramworks'})
        for addr, val in ((PT_F40_ADDR, PT_F40_MAG1),
                          (PT_F40B_ADDR, PT_F40_MAG2)):
            c.call_tool('poke', {'addr': addr, 'bytes': [val],
                                 'bank': 'main'})
        c.call_tool('mount_disk', {'path': self.disk, 'unit': 1,
                                   'copy': True})
        self.t = T.Term(c, 'text40')
        self.poisoned = False
        if poison:
            init = self.sym['SCH_INIT']
            c.call_tool('break_set', {'addr': init})
            for _ in range(400):
                r = c.call_tool('resume', {'max_cycles': 1_000_000})
                if r.get('hit_breakpoint') and r['pc'] == init:
                    break
            else:
                die('boot: SCH_INIT never reached')
            c.call_tool('poke', {'addr': self.shd,
                                 'bytes': [POISON] * (PCB_COUNT + 1),
                                 'bank': 'main'})
            self.poisoned = True
            c.call_tool('break_clear', {'all': True})
        self.t.wait('$', 'boot: shell prompt', timeout_slices=160)

    # -- state (a peek costs the guest nothing) --------------------
    def cycle(self):
        return self.c.call_tool('regs', {})['cycle']

    def peek(self, addr, n, bank='main', aux_bank=0):
        return self.c.call_tool('peek', {'addr': addr, 'count': n,
                                         'bank': bank,
                                         'aux_bank': aux_bank})['bytes']

    def poke(self, addr, data, bank='main'):
        self.c.call_tool('poke', {'addr': addr, 'bytes': list(data),
                                  'bank': bank})

    def snapshot(self):
        raw = self.peek(PCB_BASE, PCB_COUNT * PCB_SIZE, 'aux', 0)
        if self.shd is None:
            cells = [0] * (PCB_COUNT + 1)
            for i in range(PCB_COUNT):
                cells[PCB_COUNT - i] = raw[i * PCB_SIZE + OFF_PARENT]
        else:
            cells = self.peek(self.shd, PCB_COUNT + 1)
        return {'state': [raw[i * PCB_SIZE + OFF_STATE]
                          for i in range(PCB_COUNT)],
                'parent': [raw[i * PCB_SIZE + OFF_PARENT]
                           for i in range(PCB_COUNT)],
                'cell0': cells[0],
                # the shadow is REVERSED: pid p lives in cell 48 - p
                'shd': [cells[PCB_COUNT - p] for p in range(PCB_COUNT)]}

    @staticmethod
    def broken(s):
        out = []
        for p in range(PCB_COUNT):
            free = s['state'][p] == UNUSED
            if s['shd'][p] != (0 if free else s['parent'][p]):
                out.append('pid %d state %d parent %d shadow $%02X'
                           % (p, s['state'][p], s['parent'][p],
                              s['shd'][p]))
        return out

    def nearest(self, addr):
        best = None
        for a, n in self.names:
            if a > addr:
                break
            best = n
        return best

    def in_aux(self):
        return bool(self.c.call_tool('softswitches', {}).get('RAMRD'))

    def prompt(self):
        rows = [x for x in self.t.screen() if x.strip()]
        return len(rows) > 1 and rows[-1].rstrip() == '$'

    def curpid(self):
        return self.peek(self.sym['K_CURPID'], 1)[0]

    # -- STOPS ------------------------------------------------------
    def stop_check(self, where):
        s = self.snapshot()
        self.stops += 1
        for v in self.broken(s):
            if len(self.violations) < 12:
                self.violations.append('%s: %s' % (where, v))
        return s

    def on_hit(self, r, label):
        pc = r['pc']
        if self.suspend or self.in_aux():
            return                  # a process at the same address
        if pc in self.stop_pcs:
            if pc == self.sym['PRC_WAIT_CORE']:
                self.wait_calls += 1
            if self.check_inv:
                self.stop_check('%s @%s cycle %d'
                                % (label, self.stop_pcs[pc], r['cycle']))
        elif pc == self.sym['PRC_REAP_ONE']:
            g = self.c.call_tool('regs', {})
            ret = self.peek(0x0100 + g['s'] + 1, 2)
            site = self.where((ret[0] | ret[1] << 8) + 1)
            self.reaps.append((g['a'], r['cycle'], site))
            if self.on_reap:
                self.on_reap(g['a'])
        elif pc == self.sym.get('PPCB_WR_PAR'):
            s_ = self.c.call_tool('regs', {})['s']
            ret = self.peek(0x0100 + s_ + 1, 2)
            who = self.where((ret[0] | ret[1] << 8) + 1)
            self.parent_callers[who] = self.parent_callers.get(who, 0) + 1
        elif pc == self.done_pc:
            self.done_contract(r)

    on_reap = None

    def done_contract(self, r):
        """At the end of the scan the call has counted its children:
        P_COUNT must be the number of REAL children (annex PARENT ==
        K_CURPID, slot occupied) and PRC_WLIVE those that are neither
        stopped nor zombie (a zombie or an untraced stop returns
        before :done).  A stale shadow cell that the annex re-check
        failed to filter inflates both."""
        self.done_calls += 1
        s = self.snapshot()
        me = self.curpid()
        kids = [p for p in range(1, PCB_COUNT)
                if s['state'][p] != UNUSED and s['parent'][p] == me]
        live = [p for p in kids if s['state'][p] not in (ZOMBIE, STOPPED)]
        pc = self.peek(0xD9, 1)[0]
        wl = self.peek(self.sym['PRC_WLIVE'], 1)[0]
        if any(s['state'][p] == ZOMBIE for p in kids):
            return                  # a zombie child ends the scan early
        if (pc, wl) != (len(kids), len(live)) and len(self.violations) < 12:
            self.violations.append(
                'contract @cycle %d: pid %d P_COUNT %d WLIVE %d but the '
                'annex says children %s (live %s)'
                % (r['cycle'], me, pc, wl, kids, live))

    # -- driving ----------------------------------------------------
    def run(self, cycles, until_prompt=False, label=''):
        start = self.cycle()
        quiet = 0
        polled = start
        while True:
            now = self.cycle()
            left = start + cycles - now
            if left <= 0:
                if until_prompt:
                    raise Fail('%s: no prompt within %d cycles' % (label,
                                                                   cycles))
                return
            r = self.c.call_tool('resume', {'max_cycles': min(SLICE, left)})
            if r.get('hit_breakpoint'):
                self.on_hit(r, label)
            if until_prompt and r['cycle'] - polled >= 100_000:
                polled = r['cycle']
                quiet = quiet + 1 if self.prompt() else 0
                if quiet >= 2:
                    return

    def cmd(self, text, budget=60_000_000):
        self.c.call_tool('type', {'text': text + '\r'})
        self.run(budget, until_prompt=True, label=text)

    def key(self, text, settle=300_000):
        self.c.call_tool('type', {'text': text})
        self.run(settle, label='key')

    def shown(self):
        return [r.rstrip() for r in self.t.screen() if r.strip()]

    def status(self, text, budget=60_000_000):
        """Run `text; echo ST=$?` and return the integer."""
        self.cmd(text + '; echo ST=$?', budget)
        st = [r for r in self.shown() if re.fullmatch(r'ST=\d+', r)]
        if not st:
            raise Fail('no ST= line after %r: %r' % (text, self.shown()[-4:]))
        return int(st[-1][3:])

    def close(self):
        try:
            self.c.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        self.c.close()


# ---------------------------------------------------------------
# rows
# ---------------------------------------------------------------
def row_boot(tree):
    rig = Rig(tree, poison_boot=True)
    try:
        s = rig.snapshot()
        left = [p for p in range(PCB_COUNT) if s['shd'][p] == POISON]
        if left:
            raise Fail('boot: poisoned cells survive SCH_INIT at pids %s'
                       % left)
        bad = rig.broken(s)
        if bad:
            raise Fail('boot: invariant at the first prompt: %s' % bad[:4])
        free = [p for p in range(PCB_COUNT) if s['state'][p] == UNUSED]
        if any(s['shd'][p] for p in free):
            raise Fail('boot: a free slot has a nonzero cell')
        occ = {p: s['shd'][p] for p in range(PCB_COUNT)
               if s['state'][p] != UNUSED}
        print('%s boot: all 49 cells poisoned with $%02X before SCH_INIT; '
              'at the first prompt none of the 48 pids\' cells survives, '
              'the %d free slots read 0, occupied slots read their '
              'parents %s (cell 0, pid 48, does not exist and is never '
              'read)' % (TAG, POISON, len(free), occ))
        print('%s boot: note the brief says "every one reads 0": the '
              'console shell is a child of init, so its cell is its '
              'parent (the invariant), not 0' % TAG)
    finally:
        rig.close()


def routine_lines(tree, fname, name):
    """(first, last) 1-based source lines of routine `name` in
    src/kernel/fname."""
    with open(os.path.join(tree, 'src/kernel', fname), errors='replace') as fh:
        lines = fh.read().split('\n')
    for n, a, b in routines(lines):
        if n == name:
            return a + 1, b
    raise Fail('no routine %s in %s' % (name, fname))


def in_routine(tree, site, fname, name):
    f, _, ln = site.partition(':')
    if f != fname or not ln.isdigit():
        return False
    a, b = routine_lines(tree, fname, name)
    return a <= int(ln) <= b


def pids_where(s, fn):
    return [p for p in range(1, PCB_COUNT) if fn(p)]


def occupied(s):
    return {p for p in range(1, PCB_COUNT) if s['state'][p] != UNUSED}


def row_workload(tree):
    rig = WO.make_rig(sys.modules[__name__], tree,
                      disk=WO.fixture_disk(tree))
    try:
        rig.run(500_000)
        out = []

        def say(msg):
            out.append(msg)
            print('%s workload: %s' % (TAG, msg), flush=True)

        # -- spawn and fork, separately, with their statuses ---------
        st = rig.status('cmp /nofile1 /nofile2')
        if st != 2:
            raise Fail('spawned child (cmp of a missing file): status %d, '
                       'wanted 2' % st)
        st2 = rig.status('( exit 3 )')
        if st2 != 3:
            raise Fail('subshell child: status %d, wanted 3' % st2)
        sites = sorted(rig.parent_callers)
        if not any(x.startswith('process2.s') for x in sites):
            raise Fail('PPCB_WR_PAR callers %s: wanted the spawn site '
                       'in process2.s' % sites)
        if any(x.startswith('procfork.s') for x in sites):
            raise Fail('the shell forked: the fork row below assumed it '
                       'does not (notes sec 4)')
        say('spawn child status %d, subshell child status %d, both '
            'published through %s (the shell never calls SYS_FORK: its '
            '`( )` is a spawned sh; fork is the next row)'
            % (st, st2, sites))

        # -- reap order: three zombies BEFORE the wait ---------------
        rig.reaps = []
        rig.snaps = []
        rig.on_reap = lambda a: rig.snaps.append((a, rig.snapshot()))
        # the foreground sleep is the overlap: the three jobs must be
        # zombies while it is still alive (guarded below). 8 s, not 1:
        # MAUX_GATE_RACE=late runs 3M cycles after this line before the
        # harness goes on (GATE-RACE-1)
        rig.cmd('true & true & true & sleep 8')
        rig.on_reap = None
        order = [a for a, _, _ in rig.reaps]
        if len(order) < 4:
            raise Fail('reap order: %d reaps, wanted 4: %s' % (len(order),
                                                              order))
        first, last = order[:3], order[3]
        snap0 = rig.snaps[0][1]
        if any(snap0['state'][p] != ZOMBIE for p in first):
            raise Fail('reap order: not all three jobs were ZOMBIE at the '
                       'first reap: %s' % [(p, snap0['state'][p])
                                          for p in first])
        if snap0['state'][last] == ZOMBIE:
            raise Fail('reap order: the foreground sleep was already a '
                       'zombie at the first reap; the row proves nothing')
        if first != sorted(first):
            raise Fail('reap order: three zombies reaped %s, not in '
                       'ascending pid order' % first)
        say('three zombie jobs reaped in ascending pid order %s, then the '
            'live foreground sleep (pid %d) after them' % (first, last))

        # -- a $( ) beside an & job on ONE line ----------------------
        st = rig.status('cmp /nofile1 /nofile2 & X=$(ls /bin | wc -l); '
                        'wait %1')
        if st != 2:
            raise Fail('$( ) beside an & job: `wait %%1` status %d, wanted '
                       '2 (0 = the substitution stole it, 1 = no such '
                       'job)' % st)
        say("`$( )` beside an `&` job on one line: the job's status 2 "
            "survives")

        # -- an orphan: adopted by init at its parent's death ----------
        rig.reaps = []
        n0 = len(rig.reap_pids)
        before = occupied(rig.snapshot())
        # the orphan must still be alive when the snapshot is taken (the
        # `orph` precondition below); 8 s leaves room for a late harness
        rig.cmd('( sleep 8 & )')
        s = rig.snapshot()
        orph = pids_where(s, lambda p: s['state'][p] == BLOCKED and
                          p not in before and s['parent'][p] == 1)
        if len(orph) != 1:
            raise Fail('orphan: wanted exactly one live child of init '
                       'that was not there before, got %s' % orph)
        o = orph[0]
        if s['shd'][o] != 1:
            raise Fail('orphan %d: shadow %d != 1' % (o, s['shd'][o]))
        # wait for the orphan's exit as a PROPERTY (its slot is free),
        # not for a duration: the sleep's remaining time depends on how
        # late the harness got here
        for _ in range(80):
            rig.run(500_000, label='orphan idle')
            s = rig.snapshot()
            if s['state'][o] == UNUSED:
                break
        got = [(a, r) for a, r, _ in rig.reap_pids[n0:] if a == o]
        if s['state'][o] != UNUSED or s['shd'][o] != 0 or got != [(o, 1)]:
            raise Fail('orphan %d (adopted by init): state %d shadow %d '
                       'reaps %s' % (o, s['state'][o], s['shd'][o], got))
        say('orphan pid %d (its subshell parent exited): parent 1 in the '
            'annex and the shadow, exited and reaped by init; slot free, '
            'cell 0' % o)

        # -- a recipe-running make ------------------------------------
        rig.cmd("echo 'a:' > Makefile")
        rig.cmd("echo '        echo hi' | unexpand >> Makefile")
        st = rig.status('make')
        if st != 0 or not rig.t.visible('hi'):
            raise Fail('make ran its recipe with status %d' % st)
        say('recipe-running `make`: status 0, recipe ran')

        # -- the measurement set --------------------------------------
        for c in ('cat /bin/sed | wc -c', 'echo $(echo hi)',
                  'echo $(ls /bin | wc -l)', 'make -n',
                  'for a in 1 2 3 4; do for b in 1 2 3 4; do :; done; done'):
            rig.cmd(c)
        rig.cmd('sleep 300 &')
        rig.cmd('for a in 1 2 3 4; do :; done')
        rig.cmd('kill %1')
        rig.cmd('sleep 1 & sleep 1 & sleep 1 & wait')
        say('measurement set, a loop nest with a running job, `wait` with '
            'three background jobs: ran')

        # -- a bye round trip with a live job --------------------------
        # long enough that it cannot exit inside the bye window (an exit
        # there is an untraced store; check_wake.py has the same rule)
        rig.cmd('sleep 120 &')
        rig.suspend = True
        rig.cmd('bye', budget=60_000_000)
        rig.suspend = False
        if not rig.t.visible('Welcome back'):
            raise Fail('bye did not come back')
        rig.stop_check('after bye')
        rig.cmd('kill %1')
        say('`bye` round trip with a background sleeper: the shadow came '
            'back with main and agrees with the PCBs')

        if rig.violations:
            for v in rig.violations:
                print('%s VIOLATION: %s' % (TAG, v))
            raise Fail('%d invariant/contract violation(s)'
                       % len(rig.violations))
        print('%s workload: %d stops (PRC_WAIT_CORE entries and syscall '
              'exits) x 48 pids = %d points checked; %d PRC_WAIT_CORE '
              'entries, %d scans reached their end (contract compared), %d '
              'reaps; PASS' % (TAG, rig.stops, rig.stops * PCB_COUNT,
                               rig.wait_calls, rig.done_calls,
                               len(rig.reaps)), flush=True)
    finally:
        rig.close()


def _echo(rig, expr):
    rig.cmd('echo %s' % expr)
    rows = rig.shown()
    for i in range(len(rows) - 1, -1, -1):
        if rows[i].startswith('$ echo'):
            return rows[i + 1]
    raise Fail('no output for echo %s' % expr)


def row_stale(tree):
    """A cell of a FREE slot (and of someone else's slot) holding the
    shell's pid must be filtered by the annex re-check: at the end of
    every scan P_COUNT/PRC_WLIVE equal the REAL children."""
    rig = Rig(tree)
    try:
        rig.run(500_000)
        shell = int(re.findall(r'\d+', _echo(rig, '$$'))[-1])
        rig.check_inv = False            # the poison breaks the invariant
        poisoned = [20, 30, 47, 1]       # free slots, and init's
        for p in poisoned:
            rig.poke(rig.shd + PCB_COUNT - p, [shell])
        n0 = rig.done_calls
        rig.cmd('sleep 300 &')
        rig.cmd('for a in 1 2 3 4 5 6; do :; done')
        rig.cmd('kill %1')
        rig.cmd('true')
        n = rig.done_calls - n0
        if n < 6:
            raise Fail('stale: only %d scans reached their end' % n)
        # only the contract violations count here: the invariant is
        # deliberately broken by the poison
        bad = [v for v in rig.violations if v.startswith('contract')]
        if bad:
            for v in bad:
                print('%s VIOLATION: %s' % (TAG, v))
            raise Fail('stale: the annex re-check let a stale cell count '
                       'as a child')
        print('%s stale: cells of pids %s poisoned with the shell\'s pid '
              '%d; %d scans ended with P_COUNT/PRC_WLIVE equal to the real '
              'children; PASS' % (TAG, poisoned, shell, n), flush=True)
    finally:
        rig.close()


def row_fork(tree):
    """A child made by SYS_FORK is published (PPCB_WR_PAR's second
    caller) and reaped by wait() with its pid: check-fork's item 5, on
    its own kernel image (src/test/forktest.s).  The shell never forks
    in this tree, so the gate image is the only fork client."""
    img = FORKIMAGE[0]
    if not img or not os.path.exists(img):
        raise Fail('fork: needs --forkimage build/forktest.po (make '
                   'check-wait passes it)')
    cp = subprocess.run([sys.executable, '-I',
                         os.path.join(HERE, 'check_fork.py'), img],
                        capture_output=True, text=True, cwd=ROOT)
    lines = (cp.stdout + cp.stderr).splitlines()
    if cp.returncode != 0:
        print('\n'.join(lines[-12:]))
        raise Fail('fork: check_fork.py failed (a fork child that is not '
                   'published gives wait() ECHILD at its item 5)')
    item5 = [l for l in lines if 'wait' in l.lower() and 'reap' in l.lower()]
    print('%s fork: check_fork.py PASS%s' % (
        TAG, (' -- ' + item5[0].strip()) if item5 else ''), flush=True)


def row_speed(tree):
    m = MW.Meter(tree)
    try:
        m.rig.t.wait_prompt('boot')
        _, t0 = m.run(MW.NEST)
        m.run('sleep 300 &')
        calls, t1 = m.run(MW.NEST)
        m.run('kill %1')
    finally:
        m.close()
    if not calls:
        raise Fail('speed: no PRC_WAIT_CORE call in the nest with a job')
    med, mx = int(statistics.median(calls)), max(calls)
    ratio = t1 / t0
    print('%s speed: %d calls, per call median %d max %d; nest %d with a '
          'job vs %d without = %.1f%%' % (TAG, len(calls), med, mx, t1, t0,
                                          ratio * 100), flush=True)
    if med > SPEED_CALL_MAX or mx > SPEED_CALL_MAX:
        raise Fail('speed: a NOHANG call costs median %d / max %d cycles, '
                   'limit %d' % (med, mx, SPEED_CALL_MAX))
    if ratio > SPEED_NEST:
        raise Fail('speed: the nest with one job is %.1f%% of the nest '
                   'without, limit %.0f%%' % (ratio * 100, SPEED_NEST * 100))


def _wo(fn):
    return lambda tree: fn(sys.modules[__name__], tree)


ROWS = (('census', row_census), ('boot', row_boot),
        ('workload', row_workload),
        ('routes', _wo(WO.row_routes)), ('reuse', _wo(WO.row_reuse)),
        ('zombie', _wo(WO.row_zombie)), ('stopped', _wo(WO.row_stopped)),
        ('ignored', _wo(WO.row_ignored)),
        ('grandkids', _wo(WO.row_grandkids)),
        ('sweepanc', _wo(WO.row_sweepanc)), ('bye', _wo(WO.row_bye)),
        ('fork', row_fork),
        ('stale', row_stale), ('speed', row_speed))


def main():
    args = sys.argv[1:]
    tree = ROOT
    only = []
    if '--forkimage' in args:
        i = args.index('--forkimage')
        FORKIMAGE[0] = os.path.abspath(args[i + 1])
        del args[i:i + 2]
    if '--tree' in args:
        i = args.index('--tree')
        tree = os.path.abspath(args[i + 1])
        del args[i:i + 2]
    if '--only' in args:
        i = args.index('--only')
        only = args[i + 1:]
    failed = []
    for name, fn in ROWS:
        if only and name not in only:
            continue
        try:
            fn(tree)
            print('%s %s: PASS' % (TAG, name), flush=True)
        except (Fail, WO.Fail) as e:
            print('%s %s: FAIL: %s' % (TAG, name, e), flush=True)
            failed.append(name)
    if failed:
        die('rows failed: %s' % ' '.join(failed))
    print('%s PASS' % TAG)
    return 0


if __name__ == '__main__':
    sys.exit(main())
