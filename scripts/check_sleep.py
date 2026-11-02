#!/usr/bin/env python3
"""check_sleep.py -- docs/SLEEP-1.md: a `sleep` that sleeps.

SYS_SLPUNTIL (26) blocks the caller on a kernel wait channel until the
tick counter reaches an ABSOLUTE target.  One global earliest deadline
(K_SLP_DL, K_SLP_ARM); the tick hook (TTY_TICK -> SLP_TICK) wakes
SLP_CHAN when it is reached; every sleeper reruns its call.

  python3 scripts/check_sleep.py                 the gate (all rows)
  python3 scripts/check_sleep.py --only ROW ...  named rows
  python3 scripts/check_sleep.py --measure [TREE]  the before/after
                                                 CPU table (not a gate)

Rows (each prints PASS/FAIL, and the numbers it measured):

  census    static: the only stores to K_TICK_HOOK are SCH_INIT (NOP) and
            PRC_INIT (TTY_TICK); any harness that probes a timer AND has
            the process dispatch table runs PRC_INIT after the probe.
            The deadline check lives only in TTY_TICK, so this is what
            lets the call block.
  hook      the booted play image's K_TICK_HOOK is TTY_TICK.
  usage     `sleep` operands: bad ones keep the usage error and status 1
            and never block; `sleep 0` returns at once.
  timing    `sleep 2`: the sleeper is BLOCKED on SLP_CHAN (shadow and
            PCB agree), takes 120 or 121 ticks, wakes within a tick of
            its target, exits 0.  Time is the TICK COUNTER (a peek),
            never the screen.
  several   three concurrent sleeps, deadlines in either spawn order:
            reruns per sleeper are exactly 2/3/4 (an early wake re-blocks
            and none returns early), completion in deadline order.
  stopcont  ^Z a fg `sleep`; `fg` before the deadline sleeps the rest and
            returns on time; `fg` after it returns at once.
  signals   ^C ends a fg sleep at once ($? 130); `kill` reaps a bg one;
            a CAUGHT signal gives exactly one ERR_INTR (sleep exits 1).
  windows   a deadline forced due on every tick while the CPU is inside
            MLI and TTY interrupt windows: after each wake BANKSEL is
            the current bank and the PCB/shadow invariant holds.
  occupancy the process table filled with sleepers (pid 15, the last),
            pid reuse after a sleeper dies, all on time.
  coop      the kernel refuses (ERR_NOSYS) on a machine whose counter is
            frozen (mode 3 is poked for the one syscall) and never blocks.
  wrap      K_VBL_TICKS poked just below $FFFFFFFF: a sleep whose target
            crosses zero, and two sleepers with ordered deadlines on
            either side of the wrap, in both spawn orders.
  cpu       THE POINT: a CPU-bound foreground job costs the same (within
            2%) with a `sleep 100 &` in the background as with nothing.

Needs build/play.po and build/MAUXPLAY.SYSTEM_Output.txt.  Teeth:
scripts/teeth_sleep.py.  ASCII only.
"""
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR     # noqa: E402
import e2e_term as T                                       # noqa: E402

ROOT = os.path.dirname(HERE)
TAG = '[check-sleep]'
CHUNK = 20_000          # guest cycles per observation step
ORACLE = 'cksum /bin/vi'  # CPU-bound foreground job (see Rig.oracle)
PCB_BASE, PCB_COUNT, PCB_SIZE = 0x0800, 48, 16
OFF_STATE, OFF_WCHAN = 1, 2
BLOCKED = 3
ERR_INTR, ERR_NOSYS = 0xE8, 0xE2
CPU_TOLERANCE = 1.02    # the brief: within 2% of the quiet cost


class Fail(Exception):
    pass


def die(msg):
    print('%s FAIL: %s' % (TAG, msg), flush=True)
    sys.exit(1)


def equ(path, name):
    """Value of `NAME equ $hex|dec` in an inc/ file, never retyped."""
    with open(os.path.join(ROOT, path), errors='replace') as fh:
        m = re.search(r'^' + name + r'\s+equ\s+(\$[0-9A-Fa-f]+|\d+)',
                      fh.read(), re.M)
    if not m:
        die('%s has no %s' % (path, name))
    v = m.group(1)
    return int(v[1:], 16) if v[0] == '$' else int(v)


SLP_CHAN = equ('inc/proc.const.equ', 'SLP_CHAN')
SIG_TBL_ADDR = equ('inc/mm.annex.equ', 'ANNEX_STRCT_C') + 0x1500


def read_syms(tree):
    """{NAME: address} from the MAUXPLAY listing's symbol table."""
    path = os.path.join(tree, 'build', 'MAUXPLAY.SYSTEM_Output.txt')
    sym = {}
    with open(path, encoding='ascii', errors='replace') as fh:
        for line in fh:
            m = re.match(r'^\s*([A-Za-z0-9_]+)\s*=\s*\$([0-9A-Fa-f]+)\s*$',
                         line)
            if m:
                sym[m.group(1)] = int(m.group(2), 16)
                continue
            # a KBSS chain cell prints as its expression
            m = re.match(r'^\s*(K_[A-Z_]+)\s*=\s*([{}$0-9A-Fa-f+]+)\s*$',
                         line)
            if m:
                sym[m.group(1)] = eval(m.group(2).replace('{', '(')
                                       .replace('}', ')')
                                       .replace('$', '0x'),
                                       {'__builtins__': {}})
    return sym


def s32(v):
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v & 0x80000000 else v


class Rig:
    def __init__(self, tree=ROOT):
        self.tree = tree
        self.sym = read_syms(tree)
        self.by_addr = sorted((a, n) for n, a in self.sym.items()
                              if 0x2000 <= a < 0xA000)
        T.DISK = os.path.join(tree, 'build', 'play.po')
        env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
        self.c = MCPClient([SUPERVISOR], env)
        self.c.initialize()
        self.t = T.boot(self.c, 'text40')
        self.log = []
        self.c.gr_lag = self.lag
        self.entry = self.sym['PRC_SLPUNTIL']

    def close(self):
        try:
            self.c.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        self.c.close()

    # -- state, all peeks (a peek costs the guest nothing) --------
    def regs(self):
        return self.c.call_tool('regs', {})

    def cycle(self):
        return self.regs()['cycle']

    def peek(self, addr, n, bank='main', aux_bank=0):
        return self.c.call_tool('peek', {'addr': addr, 'count': n,
                                         'bank': bank,
                                         'aux_bank': aux_bank})['bytes']

    def poke(self, addr, data, bank='main', aux_bank=0):
        a = {'addr': addr, 'bytes': list(data), 'bank': bank}
        if bank == 'aux':
            a['aux_bank'] = aux_bank
        self.c.call_tool('poke', a)

    def step(self, n=CHUNK):
        self.c.call_tool('step', {'cycles': n})

    def le32(self, name):
        b = self.peek(self.sym[name], 4)
        return b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24

    def ticks(self):
        return self.le32('K_VBL_TICKS')

    def set_ticks(self, v):
        self.poke(self.sym['K_VBL_TICKS'],
                  [(v >> (8 * i)) & 0xFF for i in range(4)])

    def shd(self):
        return self.peek(self.sym['K_WAIT_SHD'], PCB_COUNT)

    def sleepers(self):
        return [p for p, v in enumerate(self.shd()) if v == SLP_CHAN]

    def pcbs(self):
        raw = self.peek(PCB_BASE, PCB_COUNT * PCB_SIZE, 'aux', 0)
        return ([raw[i * PCB_SIZE + OFF_STATE] for i in range(PCB_COUNT)],
                [raw[i * PCB_SIZE + OFF_WCHAN] for i in range(PCB_COUNT)])

    def invariant(self):
        """The WAKE-1 wait-shadow invariant over all 48 pids -> the list
        of violations (empty = holds)."""
        st, wc = self.pcbs()
        sh = self.shd()
        bad = []
        for p in range(PCB_COUNT):
            blocked = st[p] == BLOCKED
            if blocked != (sh[p] != 0) or (blocked and sh[p] != wc[p]):
                bad.append('pid %d state %d wchan $%02X shadow $%02X'
                           % (p, st[p], wc[p], sh[p]))
        return bad

    def curbank(self):
        return self.peek(self.sym['K_CURBANK'], 1)[0]

    def curpid(self):
        return self.peek(self.sym['K_CURPID'], 1)[0]

    def ramworks_bank(self):
        return self.c.call_tool('softswitches', {})['ramworks_bank']

    def in_aux(self):
        return bool(self.c.call_tool('softswitches', {}).get('RAMRD'))

    def prompt(self):
        rows = [x for x in self.t.screen() if x.strip()]
        return bool(rows) and rows[-1].rstrip() == '$'

    def nearest(self, addr):
        best = None
        for a, n in self.by_addr:
            if a > addr:
                break
            best = n
        return best

    # -- driving ---------------------------------------------------
    def line(self, text, wait=True):
        """Wait for a settled prompt, type `text` like a person, Enter.
        Returns the tick count just before the Enter."""
        self.t.wait_prompt('prompt before %r' % text)
        self.t.type_human(text)
        t0 = self.ticks()
        if wait:
            self.t.enter()
            self.t.wait_prompt('after %r' % text)
        else:
            # no free-run after the Enter: a watcher must see the whole
            # run, and a warm spawn reaches its syscall inside the
            # slice press() would take
            self.c.call_tool('type', {'text': '\r'})
        return t0

    def until(self, cond, label, max_cycles, chunk=CHUNK):
        c0 = self.cycle()
        while not cond():
            if self.cycle() - c0 > max_cycles:
                raise Fail('%s: not within %d cycles' % (label, max_cycles))
            self.step(chunk)
        return self.cycle() - c0

    def status(self):
        """`echo $?` -> int."""
        self.line('echo $?')
        rows = [r.strip() for r in self.t.screen() if r.strip()]
        digits = [r for r in rows if r.isdigit()]
        if not digits:
            raise Fail('no status line on the screen: %r' % rows[-4:])
        return int(digits[-1])

    # -- the PRC_SLPUNTIL entry log -------------------------------
    def watch(self):
        self.c.call_tool('break_set', {'addr': self.entry})
        self.log = []

    def unwatch(self):
        self.c.call_tool('break_clear', {'all': True})

    def run_logged(self, cond, label, max_cycles, slice_=CHUNK):
        """Free-run until cond(), logging every entry of PRC_SLPUNTIL
        as (cycle, tick, pid, target).  The target is read from the
        caller's own bank through the parameter pointer the dispatcher
        left in K_PARMLO/HI."""
        c0 = self.cycle()
        while True:
            if cond():
                return
            left = max_cycles - (self.cycle() - c0)
            if left <= 0:
                raise Fail('%s: not within %d cycles (entries so far: %s)'
                           % (label, max_cycles, self.summary()))
            self.resume_logged(min(slice_, left))

    def resume_logged(self, n):
        r = self.c.call_tool('resume', {'max_cycles': n})
        if r.get('hit_breakpoint') and r['pc'] == self.entry:
            if self.in_aux():
                return                  # a process at the same address
            pl, ph = self.peek(self.sym['K_PARMLO'], 2)
            pid, bank = self.curpid(), self.curbank()
            tb = self.peek(pl | ph << 8, 4, 'aux', bank)
            tgt = tb[0] | tb[1] << 8 | tb[2] << 16 | tb[3] << 24
            self.log.append((r['cycle'], self.ticks(), pid, tgt))

    def lag(self, n):
        """MAUX_GATE_RACE=late: run n guest cycles THROUGH the logger, or
        the entries the watcher would have logged in them are lost."""
        c0 = self.cycle()
        while self.cycle() - c0 < n:
            self.resume_logged(min(CHUNK, n - (self.cycle() - c0)))

    def per_pid(self):
        out = {}
        for _cyc, tk, pid, tgt in self.log:
            out.setdefault(pid, []).append((tk, tgt))
        return out

    def settled(self, n):
        """n sleepers have been logged, none is asleep and the clock is
        past the last target: a sleeper that is merely RUNNABLE between
        a wake and its re-block does not count as finished."""
        pp = self.per_pid()
        if len(pp) < n or self.sleepers():
            return False
        ref = self.log[0][1]          # targets compared modularly
        last = max(s32(r[0][1] - ref) for r in pp.values())
        return s32(self.ticks() - ref) - last > 3

    def summary(self):
        return ' '.join('pid%d:%d' % (p, len(v))
                        for p, v in sorted(self.per_pid().items()))

    # -- the CPU-share measurement --------------------------------
    def oracle(self, cmd=None, budget=200_000_000):
        """Run a CPU-bound foreground job and return (cycles to
        completion, {bank: samples}, switches).  The job is an
        EXTERNAL program (the shell just waits for it), because an sh
        loop pays for every background job the shell holds -- see
        SLEEP-1-NOTES sec 10.  The bank is sampled from K_CURBANK every
        CHUNK cycles."""
        cmd = cmd or ORACLE
        self.t.wait_prompt('prompt before the oracle')
        self.t.type_human(cmd)
        sw0 = self.peek(self.sym['K_SW_COUNT'], 2)
        c0 = self.cycle()
        self.t.enter()
        banks = {}
        while True:
            self.step()
            b = self.curbank()
            banks[b] = banks.get(b, 0) + 1
            if self.prompt():
                break
            if self.cycle() - c0 > budget:
                raise Fail('oracle: no prompt within %d cycles' % budget)
        c1 = self.cycle()
        sw1 = self.peek(self.sym['K_SW_COUNT'], 2)
        sw = ((sw1[0] | sw1[1] << 8) - (sw0[0] | sw0[1] << 8)) & 0xFFFF
        return c1 - c0, banks, sw


# ---------------------------------------------------------------
# rows
# ---------------------------------------------------------------
def row_census(_):
    """Static.  The deadline check is in TTY_TICK only, so the call may
    block only where K_TICK_HOOK is TTY_TICK."""
    stores = []
    for p in sorted(glob.glob(os.path.join(ROOT, 'src/kernel/*.s')) +
                    glob.glob(os.path.join(ROOT, 'src/test/*.s'))):
        for i, l in enumerate(open(p, errors='replace').read().splitlines()):
            if re.match(r'\s+sta\s+K_TICK_HOOK\b', l):
                stores.append((os.path.relpath(p, ROOT), i + 1))
    names = sorted(s[0] for s in stores)
    want = ['src/kernel/process.s', 'src/kernel/process.s',
            'src/kernel/sched.s', 'src/kernel/sched.s']
    if names != want:
        raise Fail('stores to K_TICK_HOOK are %s, expected exactly the '
                   'SCH_INIT NOP pair and the PRC_INIT TTY_TICK pair'
                   % stores)
    proc = open(os.path.join(ROOT, 'src/kernel/process.s')).read()
    if not re.search(r'lda\s+#<TTY_TICK[^\n]*\n[^\n]*\n\s+sta\s+K_TICK_HOOK\b',
                     proc):
        raise Fail('process.s no longer installs TTY_TICK')
    # every harness that probes a timer and has the dispatch table
    tests = {os.path.basename(p): open(p, errors='replace').read()
             for p in glob.glob(os.path.join(ROOT, 'src/test/*.s'))}
    probers = [n for n, t in tests.items()
               if re.search(r'^\s+jsr\s+TIMER_PROBE', t, re.M)]
    if not probers:
        raise Fail('no harness probes a timer: the census lost its subject')
    reach = []
    for n in sorted(probers):
        tops, todo, seen = set(), [n], set()
        while todo:                  # the top-level units that put it
            f = todo.pop()
            if f in seen:
                continue
            seen.add(f)
            users = [m for m, t in tests.items()
                     if re.search(r'^\s+put\s+\S*' + re.escape(f) + r'\b',
                                  t, re.M)]
            if not users:
                tops.add(f)
            todo.extend(users)
        disp = any('kernel/kdisp.s' in tests[tn] for tn in tops)
        t = tests[n]
        probe = re.search(r'^\s+jsr\s+TIMER_PROBE', t, re.M).start()
        init = re.search(r'^\s+jsr\s+PRC_INIT', t, re.M)
        if disp and not (init and init.start() > probe):
            raise Fail('%s probes a timer, has the dispatch table (via %s) '
                       'and does not run PRC_INIT after the probe: a '
                       'sleeper there would block with the NOP hook'
                       % (n, sorted(tops)))
        reach.append('%s %s' % (n, 'has the dispatch table, PRC_INIT after '
                                'the probe' if disp else 'has no dispatch '
                                'table: syscall 26 is out of range there'))
    print('%s census: K_TICK_HOOK stores: %s' % (TAG, ', '.join(
        '%s:%d' % s for s in stores)))
    print('%s census: timer probers: %s' % (TAG, '; '.join(reach)))


def row_hook(rig):
    hook = rig.peek(rig.sym['K_TICK_HOOK'], 2)
    got = hook[0] | hook[1] << 8
    if got != rig.sym['TTY_TICK']:
        raise Fail('K_TICK_HOOK is $%04X, not TTY_TICK $%04X'
                   % (got, rig.sym['TTY_TICK']))
    mode = rig.peek(rig.sym['K_TIMER_MODE'], 1)[0]
    print('%s hook: K_TICK_HOOK = TTY_TICK ($%04X), timer mode %d'
          % (TAG, got, mode))


def row_usage(rig):
    for cmd, st in (('sleep', 1), ('sleep x', 1), ('sleep 1 2', 1),
                    ('sleep -1', 1), ('sleep 10000', 1), ('sleep 0', 0)):
        c0 = rig.cycle()
        rig.line(cmd)
        if rig.sleepers():
            raise Fail('%r blocked on the sleep channel' % cmd)
        if cmd == 'sleep' and not rig.t.visible('usage: sleep'):
            raise Fail('no usage line for a bare sleep')
        got = rig.status()
        if got != st:
            raise Fail('%r exited %d, wanted %d' % (cmd, got, st))
        if rig.cycle() - c0 > 6_000_000:
            raise Fail('%r took %d cycles' % (cmd, rig.cycle() - c0))
    print('%s usage: six operands, usage/zero behave as before, none '
          'blocked' % TAG)


def row_timing(rig):
    rig.watch()
    try:
        rig.line('sleep 2', wait=False)
        rig.run_logged(lambda: len(rig.log) >= 1, 'first entry', 3_000_000)
        rig.step(30_000)
        sl = rig.sleepers()
        if len(sl) != 1:
            raise Fail('expected one sleeper on SLP_CHAN, shadow says %s'
                       % sl)
        p = sl[0]
        st, wc = rig.pcbs()
        if (st[p], wc[p]) != (BLOCKED, SLP_CHAN):
            raise Fail('pid %d PCB is state %d wchan $%02X, the shadow '
                       'says SLP_CHAN' % (p, st[p], wc[p]))
        if rig.invariant():
            raise Fail('shadow invariant: %s' % rig.invariant())
        arm = rig.peek(rig.sym['K_SLP_ARM'], 1)[0]
        dl = rig.le32('K_SLP_DL')
        rig.run_logged(rig.prompt, 'sleep 2 to return', 4_000_000)
    finally:
        rig.unwatch()
    (pid, rows), = rig.per_pid().items()
    if len(rows) != 2:
        raise Fail('expected 2 entries (block, return), got %s' % rows)
    (t1, tgt), (t2, tgt2) = rows
    start = (tgt - 120) & 0xFFFFFFFF
    if tgt != tgt2 or tgt != dl or not arm:
        raise Fail('target %08X / %08X, deadline cell %08X armed=%d'
                   % (tgt, tgt2, dl, arm))
    wake = (t2 - tgt) & 0xFFFFFFFF
    total = (t2 - start) & 0xFFFFFFFF
    if wake > 1:
        raise Fail('woke %d ticks after its target (want 0 or 1)' % wake)
    if total not in (120, 121):
        raise Fail('slept %d ticks (want 120 or 121)' % total)
    if rig.status() != 0:
        raise Fail('exit status != 0')
    print('%s timing: BLOCKED on $%02X (shadow and PCB agree), target = '
          'sample+120, returned %d ticks after sampling, %d after its '
          'target, status 0' % (TAG, SLP_CHAN, total, wake))


def _several(rig, order, secs):
    rig.watch()
    try:
        rig.line(' '.join('sleep %d &' % s for s in order), wait=False)
        rig.run_logged(lambda: len(rig.sleepers()) == 3, 'three asleep',
                       4_000_000)
        ticks = max(secs) * 60 + 600
        rig.run_logged(lambda: rig.settled(3) and rig.prompt(),
                       'all woken', ticks * 17_000 + 4_000_000)
    finally:
        rig.unwatch()
    return rig.per_pid()


def row_several(rig):
    # 8/10/12 s, not 2/4/6: MAUX_GATE_RACE=late runs 3M guest cycles
    # after the arming line, and the shortest sleeper must still be
    # asleep when the harness counts them (GATE-RACE-1)
    secs = (8, 10, 12)
    for order in (secs, tuple(reversed(secs))):
        ent = _several(rig, order, secs)
        by_target = sorted(ent.items(), key=lambda kv: s32(kv[1][0][1]))
        if len(by_target) != 3:
            raise Fail('three sleepers expected, saw pids %s' % list(ent))
        finish = []
        for rank, (pid, rows) in enumerate(by_target):
            want = rank + 2        # block + one early rerun per earlier
            if len(rows) != want:   # deadline + the return
                raise Fail('spawn order %s: the sleeper with the #%d '
                           'deadline (pid %d) entered %d times, wanted %d '
                           '(an early wake must rerun and block again; '
                           'none may return early)'
                           % (order, rank + 1, pid, len(rows), want))
            tgt = rows[0][1]
            if any(tg != tgt for _, tg in rows):
                raise Fail('pid %d target changed between reruns' % pid)
            for tk, _ in rows[:-1]:
                if s32(tk - tgt) >= 0:
                    raise Fail('pid %d entered at tick %d past its target '
                               '%d and blocked again' % (pid, tk, tgt))
            lag = s32(rows[-1][0] - tgt)
            if not 0 <= lag <= 1:
                raise Fail('pid %d returned %d ticks after its target '
                           '(want 0 or 1)' % (pid, lag))
            finish.append(rows[-1][0])
        if finish != sorted(finish):
            raise Fail('completion not in deadline order: %s' % finish)
        print('%s several: spawn order %s -> entries per sleeper in '
              'deadline order %s (%d early reruns), each returned at its '
              'target (+0/+1 tick), in order'
              % (TAG, order, [len(r) for _, r in by_target],
                 sum(len(r) - 2 for _, r in by_target)))


def row_stopcont(rig):
    # fg before the deadline: sleeps the rest
    rig.watch()
    try:
        rig.line('sleep 6', wait=False)
        rig.run_logged(lambda: len(rig.sleepers()) == 1, 'asleep',
                       3_000_000)
        rig.step(60 * 17_000)                    # ~1 s into the sleep
        rig.t.press('\x1a')
        rig.t.wait_prompt('stopped')
        if rig.sleepers():
            raise Fail('a stopped sleeper is still on SLP_CHAN')
        if rig.invariant():
            raise Fail('invariant after ^Z: %s' % rig.invariant())
        (pid, rows), = rig.per_pid().items()
        tgt = rows[0][1]
        rig.until(lambda: s32(tgt - rig.ticks()) < 120, 'before fg',
                  8_000_000)
        rig.line('fg', wait=False)
        rig.run_logged(rig.prompt, 'fg to return', 6_000_000)
    finally:
        rig.unwatch()
    rows = rig.per_pid()[pid]
    lag = s32(rows[-1][0] - tgt)
    if len(rows) != 3 or s32(rows[1][0] - tgt) >= 0 or not 0 <= lag <= 1:
        raise Fail('fg before the deadline: entries %s (target %d): it '
                   'should rerun once early and then return on time'
                   % (rows, tgt))
    print('%s stopcont: ^Z at ~1 s, fg at ~4 s of 6: reran, slept the '
          'rest, returned %d ticks after the original target' % (TAG, lag))
    # fg after the deadline: returns at once
    rig.watch()
    try:
        rig.line('sleep 3', wait=False)
        rig.run_logged(lambda: len(rig.sleepers()) == 1, 'asleep',
                       3_000_000)
        rig.step(30 * 17_000)
        rig.t.press('\x1a')
        rig.t.wait_prompt('stopped 2')
        (pid2, rows2), = rig.per_pid().items()
        tgt2 = rows2[0][1]
        rig.until(lambda: s32(rig.ticks() - tgt2) > 60, 'past the deadline',
                  8_000_000)
        t_fg = rig.line('fg', wait=False)
        rig.run_logged(rig.prompt, 'fg after the deadline', 4_000_000)
    finally:
        rig.unwatch()
    rows2 = rig.per_pid()[pid2]
    late = s32(rows2[-1][0] - tgt2)
    lag = s32(rows2[-1][0] - t_fg)
    if len(rows2) != 2 or late < 60 or lag > 10:
        raise Fail('fg after the deadline: entries %s, fg typed at tick '
                   '%d (target %d)' % (rows2, t_fg, tgt2))
    if rig.status() != 0:
        raise Fail('fg after the deadline did not exit 0')
    print('%s stopcont: fg after the deadline returned %d ticks after '
          'the command, status 0 (time passed while stopped)'
          % (TAG, lag))


def row_signals(rig):
    # ^C on a foreground sleep
    rig.line('sleep 30', wait=False)
    rig.until(lambda: len(rig.sleepers()) == 1, 'asleep', 3_000_000)
    rig.step(20 * 17_000)
    t0 = rig.ticks()
    rig.t.press('\x03', cyc=1)
    rig.until(rig.prompt, '^C to prompt', 2_000_000)
    dt = rig.ticks() - t0
    if dt > 6:
        raise Fail('^C took %d ticks to reach the prompt' % dt)
    if rig.sleepers() or rig.invariant():
        raise Fail('after ^C: sleepers %s, invariant %s'
                   % (rig.sleepers(), rig.invariant()))
    st = rig.status()
    if st != 130:
        raise Fail('^C status %d, the house value is 130 ($82)' % st)
    print('%s signals: ^C ended a fg sleep in %d ticks, status 130'
          % (TAG, dt))
    # kill of a background sleep
    rig.line('sleep 30 &')
    sl = rig.sleepers()
    if len(sl) != 1:
        raise Fail('bg sleeper not asleep: %s' % sl)
    pid = sl[0]
    rig.line('kill $!')
    rig.line('echo reaped')
    if rig.sleepers() or rig.invariant():
        raise Fail('after kill: sleepers %s invariant %s'
                   % (rig.sleepers(), rig.invariant()))
    st, _ = rig.pcbs()
    if st[pid] != 0:
        raise Fail('pid %d is state %d after kill + prompt, not UNUSED'
                   % (pid, st[pid]))
    print('%s signals: kill reaped the bg sleeper (pid %d freed, '
          'shadow clear)' % (TAG, pid))
    # a CAUGHT signal: exactly one ERR_INTR
    rig.line('sleep 30 &')
    sl = rig.sleepers()
    if len(sl) != 1:
        raise Fail('bg sleeper not asleep')
    pid = sl[0]
    rig.poke(SIG_TBL_ADDR + pid * 8, [0x02], 'aux', 0)   # CATCH signo 2
    fail = rig.sym['PRC_FAIL_A']
    rig.c.call_tool('break_set', {'addr': fail})
    hits = 0
    try:
        rig.line('kill -2 $!', wait=False)
        for _ in range(80):
            r = rig.c.call_tool('resume', {'max_cycles': 100_000})
            if r.get('hit_breakpoint') and r['pc'] == fail \
                    and not rig.in_aux():
                if rig.regs()['a'] == ERR_INTR and rig.curpid() == pid:
                    hits += 1
            if hits and rig.prompt():
                break
    finally:
        rig.c.call_tool('break_clear', {'all': True})
    if hits != 1:
        raise Fail('the caught signal gave %d ERR_INTR returns to pid %d '
                   '(want exactly 1)' % (hits, pid))
    rig.line('echo done')
    if rig.sleepers() or rig.invariant():
        raise Fail('after the caught signal: %s %s'
                   % (rig.sleepers(), rig.invariant()))
    print('%s signals: a caught nonfatal signal -> exactly one ERR_INTR '
          '(sleep exits 1, shadow clear)' % TAG)


def row_windows(rig):
    """Force a deadline due on EVERY tick while the CPU is inside the
    kernel's interrupt windows, then check each wake."""
    sym = rig.sym
    rig.line('sleep 120 &')
    if len(rig.sleepers()) != 1:
        raise Fail('no sleeper to wake')
    shim_lo, shim_hi = sym['MAIN_IRQ_SHIM'], sym['TMR_OWN_03FE']
    entry = sym['SLP_TICK']
    ret = entry + rig.peek(entry, 48).index(0x60)     # SLP_TICK's rts
    rig.c.call_tool('break_set', {'addr': entry})
    rig.c.call_tool('break_set', {'addr': ret})
    stats = {'shim': 0, 'proc': 0}
    where = {}
    bad = []
    pending = None
    events = 0
    rig.t.wait_prompt('windows')
    c_end = rig.cycle() + 150_000_000
    try:
        # MLI windows: file READs; TTY islands: a long write to the glass
        for cmd, quota in (('cat /bin/vi > /dev/null', 60),
                           ('strings /bin/vi', 120), ('ls -l /bin', 60)):
            rig.t.wait_prompt('before ' + cmd)
            rig.t.type_human(cmd)
            rig.t.enter()
            got = 0
            while (rig.cycle() < c_end and got < quota and
                   len(bad) < 6 and not rig.prompt()):
                tk = rig.ticks()          # due NOW: armed, deadline=now
                rig.poke(sym['K_SLP_DL'], [(tk >> (8 * i)) & 0xFF
                                           for i in range(4)])
                rig.poke(sym['K_SLP_ARM'], [1])
                r = rig.c.call_tool('resume', {'max_cycles': 40_000})
                if not r.get('hit_breakpoint') or rig.in_aux():
                    continue
                if r['pc'] == entry:
                    s_ = rig.regs()['s']
                    stk = rig.peek(0x0100 + s_ + 1, 24)
                    # [0,1] return into TTY_TICK, [2..9] its 8 saved
                    # cells, [10,11] TTY_TICK's own return: into the
                    # shim's :hook or into SCH_TICK
                    callret = (stk[10] | stk[11] << 8) + 1
                    shim = shim_lo <= callret < shim_hi
                    pending = None
                    if shim:
                        # then Y, X, the shim's Y, X, A, P, PCL, PCH
                        ipc = stk[18] | stk[19] << 8
                        pending = ('mli' if ipc >= 0xA000 else
                                   rig.nearest(ipc) or '?')
                    stats['shim' if shim else 'proc'] += 1
                elif r['pc'] == ret:
                    if rig.peek(sym['K_SLP_ARM'], 1)[0]:
                        continue              # not due: no wake
                    events += 1
                    got += 1
                    bank, cur = rig.ramworks_bank(), rig.curbank()
                    if bank != cur:
                        bad.append('BANKSEL %d after a wake, K_CURBANK %d '
                                   '(interrupted in %s)'
                                   % (bank, cur, pending))
                    inv = rig.invariant()
                    if inv:
                        bad.append('after a wake in %s: %s'
                                   % (pending, inv[:2]))
                    if pending:
                        where[pending] = where.get(pending, 0) + 1
                    pending = None
            rig.c.call_tool('break_clear', {'all': True})
            if bad:                       # report the first wake that
                break                     # went wrong, not the wedge
            if not rig.prompt():          # quota met: end the workload
                rig.t.press('\x03', cyc=1)
            rig.t.wait_prompt('after ' + cmd, timeout_slices=200)
            rig.c.call_tool('break_set', {'addr': entry})
            rig.c.call_tool('break_set', {'addr': ret})
    finally:
        rig.c.call_tool('break_clear', {'all': True})
    if bad:
        raise Fail('; '.join(bad[:4]))
    mli = where.get('mli', 0)
    tty = sum(n for k, n in where.items()
              if k.startswith(('TTY', 'VC', 'UT_', 'TT9', 'SER')))
    if events < 50 or stats['shim'] < 10 or mli < 3 or tty < 3:
        raise Fail('coverage: %d wakes (%d via the interrupt shim) -- '
                   'MLI-window %d, TTY-window %d (interrupted in %s); '
                   'the rows it exists for did not run'
                   % (events, stats['shim'], mli, tty, where))
    rig.t.wait_prompt('windows end', timeout_slices=400)
    rig.line('echo alive')
    if not rig.t.visible('alive'):
        raise Fail('the machine did not survive the wakes')
    print('%s windows: %d forced wakes, %d inside the interrupt shim '
          '(MLI window %d, TTY window %d; also in %s), BANKSEL == K_CURBANK '
          'and the PCB/shadow invariant held after every one'
          % (TAG, events, stats['shim'], mli, tty,
             ', '.join('%s %d' % kv for kv in sorted(where.items())
                       if kv[0] != 'mli')[:80]))


def row_occupancy(rig):
    pids = []
    for _ in range(20):
        rig.line('sleep 600 &')
        sl = rig.sleepers()
        if len(sl) == len(pids):
            break
        pids = sl
        if rig.invariant():
            raise Fail('invariant at %d sleepers: %s' % (len(pids),
                                                         rig.invariant()))
    if not pids or max(pids) != 15:
        raise Fail('the table filled at pids %s; the last pid should be '
                   '15 (the release kernel limit)' % pids)
    first = pids[0]
    # 2026-10-31: this asserted 'not found'. A spawn refused for want of
    # a process bank used to print `sh: command not found`, which is a
    # lie -- the command exists, the machine is out of banks. sh now
    # decodes ERR_NOMEM and says so, and this row is the ONLY place in
    # the tree that fills the table, so it is the only gate that saw the
    # old text. Asserting the new message keeps that coverage; matching
    # either would quietly re-admit the lie.
    if not rig.t.visible('no more processes'):
        raise Fail('a spawn into a full table did not report ERR_NOMEM: '
                   'expected "sh: no more processes" on screen')
    job15 = [m.group(1) for r in rig.t.screen()
             for m in [re.match(r'\[(\d+)\]\s+15\s*$', r.strip())] if m]
    if not job15:
        raise Fail('no "[n] 15" job line on the screen: %r'
                   % [r.rstrip() for r in rig.t.screen() if r.strip()][-8:])
    rig.line('echo full')
    # nothing can spawn now (not even /bin/kill): free pid 15 by hand,
    # fg the newest job and ^C it
    rig.line('fg %%%s' % job15[-1], wait=False)
    rig.until(lambda: not rig.prompt(), 'fg started', 1_000_000)
    rig.step(10 * 17_000)
    rig.t.press('\x03', cyc=1)
    rig.until(rig.prompt, '^C of the pid-15 sleeper', 2_000_000)
    if 15 in rig.sleepers() or len(rig.sleepers()) != len(pids) - 1:
        raise Fail('pid 15 is still asleep after ^C')
    rig.line('kill %d' % first)
    rig.line('echo gone')
    if first in rig.sleepers():
        raise Fail('pid %d still asleep after kill' % first)
    rig.watch()
    try:
        rig.line('sleep 2 &', wait=False)
        rig.run_logged(lambda: len(rig.log) >= 1, 'new sleeper', 3_000_000)
        newpid = rig.log[0][2]
        rig.run_logged(lambda: len(rig.per_pid().get(newpid, ())) >= 2,
                       'new sleeper returns', 4_000_000)
    finally:
        rig.unwatch()
    if newpid != first:
        raise Fail('the freed pid %d was not reused (got %d)'
                   % (first, newpid))
    rows = rig.per_pid()[newpid]
    lag = s32(rows[-1][0] - rows[0][1])
    if not 0 <= lag <= 1:
        raise Fail('the reused pid returned %d ticks after its target' % lag)
    if rig.invariant():
        raise Fail('invariant: %s' % rig.invariant())
    print('%s occupancy: %d sleepers up to pid 15 (all on SLP_CHAN), '
          'one killed, pid %d reused and woke on time among the rest'
          % (TAG, len(pids), newpid))


def row_coop(rig):
    sym = rig.sym
    entry = sym['PRC_SLPUNTIL']
    body = rig.peek(entry, 120)
    refuse = None
    for i in range(len(body) - 1):             # the arm: lda #ERR_NOSYS
        if body[i] == 0xA9 and body[i + 1] == ERR_NOSYS:
            refuse = entry + i
    if refuse is None:
        raise Fail('PRC_SLPUNTIL has no ERR_NOSYS arm')
    mode_addr = sym['K_TIMER_MODE']
    mode = rig.peek(mode_addr, 1)[0]
    rig.c.call_tool('break_set', {'addr': entry})
    rig.c.call_tool('break_set', {'addr': refuse})
    seen = {'entry': False, 'refused': False}
    poked = None
    c0 = rig.cycle()
    try:
        rig.line('sleep 2', wait=False)
        while rig.cycle() - c0 < 6_000_000 and not rig.prompt():
            r = rig.c.call_tool('resume', {'max_cycles': 50_000})
            if poked and not seen['refused'] and rig.cycle() - poked > 30_000:
                rig.poke(mode_addr, [mode])     # never leave it at 3
                poked = None
            if not r.get('hit_breakpoint') or rig.in_aux():
                continue
            if r['pc'] == entry and not seen['entry']:
                seen['entry'] = True
                rig.poke(mode_addr, [3])        # a frozen-counter machine
                poked = rig.cycle()
            elif r['pc'] == refuse:
                seen['refused'] = True
                rig.poke(mode_addr, [mode])
                poked = None
    finally:
        rig.c.call_tool('break_clear', {'all': True})
        rig.poke(mode_addr, [mode])
    if not seen['entry']:
        raise Fail('the syscall was never entered')
    if not seen['refused']:
        raise Fail('mode 3: the kernel did not refuse -- the call went on '
                   'to block on a counter it would never reach (a real '
                   'COOP machine hangs here; the sleep ran %d cycles)'
                   % (rig.cycle() - c0))
    rig.t.wait_prompt('coop refusal')
    if not rig.t.visible('sleep: no timer'):
        raise Fail('no "sleep: no timer" message')
    if rig.sleepers():
        raise Fail('a COOP sleep blocked')
    if rig.status() != 1:
        raise Fail('refusal status != 1')
    print('%s coop: mode 3 -> ERR_NOSYS from the kernel, "sleep: no timer", '
          'status 1, never blocked (%d cycles)' % (TAG, rig.cycle() - c0))


def row_wrap(rig):
    low = 0xFFFFFF9C                  # 100 ticks below the wrap
    rig.set_ticks(low)
    rig.watch()
    try:
        rig.line('sleep 3', wait=False)
        rig.run_logged(rig.prompt, 'wrapped sleep 3', 6_000_000)
    finally:
        rig.unwatch()
    (pid, rows), = rig.per_pid().items()
    if len(rows) != 2:
        raise Fail('wrapped sleep entered %d times, wanted 2: %s'
                   % (len(rows), rows))
    (t1, tgt), (t2, _) = rows
    if not tgt < t1:
        raise Fail('the target %08X is not below the tick %08X: the row '
                   'did not cross the wrap' % (tgt, t1))
    span = (t2 - ((tgt - 180) & 0xFFFFFFFF)) & 0xFFFFFFFF
    if span not in (180, 181) or not 0 <= s32(t2 - tgt) <= 1:
        raise Fail('wrapped sleep 3 lasted %d ticks (want 180/181)' % span)
    print('%s wrap: sleep 3 from tick %08X, target %08X (past zero) '
          'lasted %d ticks' % (TAG, t1, tgt, span))
    # the wrap comes 450 ticks after the poke; the spawns land 70-100
    # ticks in, so a 4 s sleeper's target (about +310..340) is before it
    # and an 8 s sleeper's (about +550..580) after. 4 s, not 1: with
    # MAUX_GATE_RACE=late the harness looks ~180 ticks after the Enter,
    # and the early sleeper must still be asleep then (GATE-RACE-1)
    for order in ((4, 8), (8, 4)):
        rig.set_ticks(0xFFFFFFFF - 449)
        rig.watch()
        try:
            rig.line(' '.join('sleep %d &' % s for s in order), wait=False)
            rig.run_logged(lambda: len(rig.sleepers()) == 2, 'two asleep',
                           3_000_000)
            rig.run_logged(lambda: rig.settled(2) and rig.prompt(),
                           'both woken', 12_000_000)
        finally:
            rig.unwatch()
        ent = sorted(rig.per_pid().items(),
                     key=lambda kv: s32(kv[1][0][1]))
        if len(ent) != 2:
            raise Fail('order %s: %d sleepers logged, wanted 2: %s'
                       % (order, len(ent), rig.log))
        (_pa, ra), (_pb, rb) = ent
        tga, tgb = ra[0][1], rb[0][1]
        if not (tga > 0x80000000 and tgb < 0x1000):
            raise Fail('deadlines %08X/%08X are not on either side of the '
                       'wrap' % (tga, tgb))
        if len(ra) != 2 or len(rb) != 3:
            raise Fail('order %s: entries %d/%d, wanted 2/3 (the later '
                       'deadline reruns once early)'
                       % (order, len(ra), len(rb)))
        for rows, tg in ((ra, tga), (rb, tgb)):
            if not 0 <= s32(rows[-1][0] - tg) <= 1:
                raise Fail('order %s: returned %d ticks after its target'
                           % (order, s32(rows[-1][0] - tg)))
        print('%s wrap: spawn order %s, deadlines %08X < wrap < %08X: '
              'woke in order on time' % (TAG, order, tga, tgb))


def row_cpu(_):
    res = {}
    sleeper_pid = None
    for n in (0, 1):
        r = Rig()
        try:
            if n:
                # the brief says `sleep 30 &`; three oracle runs take
                # 45 M cycles, longer than 30 s, so the sleeper would
                # expire inside the measurement
                r.line('sleep 100 &')
                if len(r.sleepers()) != 1:
                    raise Fail('the background sleeper is not BLOCKED on '
                               'the sleep channel (shadow %s)'
                               % r.sleepers())
                st, wc = r.pcbs()
                p = sleeper_pid = r.sleepers()[0]
                if (st[p], wc[p]) != (BLOCKED, SLP_CHAN):
                    raise Fail('PCB disagrees with the shadow')
            res[n] = [r.oracle() for _ in range(3)]
        finally:
            r.close()

    def mean(rs):                # the first run is cold in both
        return sum(x[0] for x in rs[1:]) / (len(rs) - 1)
    base, with1 = mean(res[0]), mean(res[1])
    ratio = with1 / base
    ran = sum(x[1].get(sleeper_pid, 0) for x in res[1])
    print('%s cpu: `%s` alone %d cycles (runs %s); with a background '
          'sleep %d (runs %s): %.1f%%; the sleeper (bank %d) was sampled '
          'running %d times in %d samples'
          % (TAG, ORACLE, base, [x[0] for x in res[0]], with1,
             [x[0] for x in res[1]], 100 * ratio, sleeper_pid, ran,
             sum(sum(x[1].values()) for x in res[1])))
    if ran > 2:
        raise Fail('the background sleeper ran %d times while the '
                   'oracle did: it is not blocked' % ran)
    if ratio > CPU_TOLERANCE:
        raise Fail('a blocked background sleep cost the foreground %.1f%% '
                   '(limit %.0f%%)' % (100 * (ratio - 1),
                                        100 * (CPU_TOLERANCE - 1)))


# rows that share one booted machine, in order
SHARED = [('hook', row_hook), ('usage', row_usage), ('timing', row_timing),
          ('several', row_several), ('stopcont', row_stopcont),
          ('signals', row_signals), ('windows', row_windows),
          ('occupancy', row_occupancy)]
OWN_BOOT = [('coop', row_coop), ('wrap', row_wrap)]


def run_rows(only):
    failed = []

    def go(name, fn, rig):
        if only and name not in only:
            return
        try:
            fn(rig)
            print('%s PASS %s' % (TAG, name), flush=True)
        except (Fail, AssertionError, T.Wedged) as e:
            print('%s FAIL %s: %s' % (TAG, name, e), flush=True)
            failed.append(name)

    go('census', row_census, None)
    if not only or only & {n for n, _ in SHARED}:
        rig = Rig()
        try:
            for name, fn in SHARED:
                go(name, fn, rig)
        finally:
            rig.close()
    for name, fn in OWN_BOOT:
        if only and name not in only:
            continue
        rig = Rig()
        try:
            go(name, fn, rig)
        finally:
            rig.close()
    go('cpu', row_cpu, None)
    return failed


def measure(tree=ROOT, counts=(0, 1, 3), secs=300, runs=3):
    print('%s measure (%s): `%s` vs N background `sleep %d &`'
          % (TAG, tree, ORACLE, secs))
    print('%-9s %14s %9s %8s  banks (bank:samples)'
          % ('sleepers', 'oracle cycles', 'vs none', 'switches'))
    base = None
    for n in counts:
        r = Rig(tree)
        try:
            for _ in range(n):
                r.line('sleep %d &' % secs)
            res = [r.oracle() for _ in range(runs)]
        finally:
            r.close()
        mean = sum(x[0] for x in res) / len(res)
        if base is None:
            base = mean
        banks = {}
        for _, bk, _ in res:
            for k, v in bk.items():
                banks[k] = banks.get(k, 0) + v
        print('%-9d %14d %8.1f%% %8d  %s   runs: %s'
              % (n, mean, 100.0 * mean / base,
                 sum(x[2] for x in res) // len(res),
                 ' '.join('%d:%d' % kv for kv in sorted(banks.items())),
                 ' '.join('%d' % x[0] for x in res)), flush=True)


def main():
    if '--measure' in sys.argv:
        i = sys.argv.index('--measure')
        tree = (sys.argv[i + 1] if len(sys.argv) > i + 1 and
                not sys.argv[i + 1].startswith('-') else ROOT)
        measure(tree)
        return 0
    only = set()
    if '--only' in sys.argv:
        only = set(sys.argv[sys.argv.index('--only') + 1:])
    failed = run_rows(only)
    if failed:
        print('%s FAIL: %s' % (TAG, ' '.join(failed)))
        return 1
    print('%s PASS' % TAG)
    return 0


if __name__ == '__main__':
    sys.exit(main())
