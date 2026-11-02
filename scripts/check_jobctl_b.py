#!/usr/bin/env python3
"""check_jobctl_b.py -- the suspend core at the SYSCALL level
(`make check-jobctl-b`, in check-all-cross). docs/JOB-CONTROL.md,
Increment B: PCB_STOPPED, the ^Z sweep, SYS_CONT, SYS_WAITJOB, and the
orphan reap. No shell UX yet (that is Increment C), so the "shell" is
src/test/jctest.s, staged on build/jobctl.po (a play.po clone) and run
from the real shell's prompt. It spawns `sleep 200`, declares it the
console's foreground job, and reports every step as a `JC ...` line
the gate scrapes off the glass; between steps it waits for a `G` line
so the annex can be peeked while the state holds.

Asserted, in order (annex PCB table peeks + SYS_PSTAT as printed by the
program + the tty mode cell + the glass):

  stop      jctest puts the console in RAW mode, spawns the child and
            blocks in SYS_WAITJOB(WUNTRACED). The gate types ^Z. The
            child's PCB_STATE is PCB_STOPPED (5) -- both in the annex
            and via SYS_PSTAT -- SYS_WAITJOB returned {kind=2, code=0}
            and the child's pid, and VC_TMODE is back to cooked+echo
            (3) from the 0 the program set: PRC_TMD_RST fired on the
            stopped victim.
  cont      SYS_CONT: the child is RUNNABLE/RUNNING/BLOCKED again (the
            sleep polls SYS_TICK, so it really runs), and
            SYS_WAITJOB(WNOHANG) returns 0 -- a running child is not
            "ready", and a poll does not block.
  stop2     a second ^Z reports Stopped again (kind=2, state 5).
  legacy    SYS_WAIT with the only child stopped returns ERR_CHILD
            ($E3) -- it must not sleep on a set nothing can wake.
  tcsetfg   (TAB-A2) SYS_TCSETFG accepts the CALLER's own pid, still
            refuses a pid that is neither a child nor the caller
            (ERR_INVAL, set untouched), takes {self, child}, and {0}
            clears; the declared set is read from the annex.
  reap      jctest EXITS with the child still stopped. Afterwards no
            slot is STOPPED or ZOMBIE, the live set is exactly the
            pre-test set, and the child's bank is not held by any
            PCB: it is back on the free list, or retained as a HELD
            lazy-free tag (src/kernel/lazyfree.s) -- never LIVE.

Teeth: on faad254 (Increment A, no PCB_STOPPED) the same jctest binary
on the same image fails at `stop` -- SYS_WAITJOB is not a dispatch
entry there (K_DISP_COUNT 17), so the program prints `JC FAIL W`, and
the ^Z is inert (it enters the ring as a plain byte; the child keeps
running). Measured before this gate was declared green.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_vi as V                                    # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR    # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'jobctl.po')
SYMFILE = os.path.join(ROOT, 'build', 'MAUXPLAY.SYSTEM_Output.txt')

# inc/mm.annex*.equ -- the PCB array and the foreground table.
PCB_ARRY_ADDR = 0x0800
PCB_ENT_SIZE = 16
with open(os.path.join(ROOT, 'inc', 'proc.const.equ')) as _fh:
    SLP_CHAN = int(re.search(r'^SLP_CHAN\s+equ\s+\$([0-9A-Fa-f]+)',
                             _fh.read(), re.M).group(1), 16)
PCB_COUNT = 48
PCB_STATE = 1
PCB_WCHAN = 2
PCB_BANK = 3
PCB_PARENT = 4
ST_UNUSED, ST_RUNNABLE, ST_RUNNING, ST_BLOCKED, ST_ZOMBIE, ST_STOPPED = \
    0, 1, 2, 3, 4, 5
ST_NAME = {0: 'UNUSED', 1: 'RUNNABLE', 2: 'RUNNING', 3: 'BLOCKED',
           4: 'ZOMBIE', 5: 'STOPPED'}
VC_FGJOB_ADDR = 0x7680
VC_FGJ_STRIDE = 4
TMD_COOKED = 7                    # TMD_ICANON | TMD_ECHO | TMD_OPOST
TMD_RAW = 4                       # TMD_OPOST alone -- vi's raw (VT102 slice 1)
ERR_CHILD = 0xE3
LZ_LIVE, LZ_HELD = 1, 2
LZ_SLOT_CNT = 14                  # inc/mm.annex.equ


def sym_addr(name):
    pat = re.compile(r'^\s*' + re.escape(name) + r'\s*=\s*\$([0-9A-Fa-f]+)\s*$',
                     re.MULTILINE)
    m = pat.search(open(SYMFILE).read())
    if not m:
        raise RuntimeError(f'symbol {name!r} not found in {SYMFILE}')
    return int(m.group(1), 16)


def peek_annex(c, addr, n):
    r = c.call_tool('peek', {'addr': addr, 'count': n, 'bank': 'aux',
                             'aux_bank': 0})
    return r.get('bytes') or r.get('data')


def peek_main(c, addr, n=1):
    r = c.call_tool('peek', {'addr': addr, 'count': n, 'bank': 'main'})
    return r.get('bytes') or r.get('data')


def pcbs(c):
    tbl = peek_annex(c, PCB_ARRY_ADDR, PCB_COUNT * PCB_ENT_SIZE)
    out = {}
    for pid in range(1, PCB_COUNT):
        e = tbl[pid * PCB_ENT_SIZE:(pid + 1) * PCB_ENT_SIZE]
        out[pid] = (e[PCB_STATE], e[PCB_BANK], e[PCB_PARENT])
    return out


def live_pids(c):
    return {pid for pid, (st, _b, _p) in pcbs(c).items()
            if st in (ST_RUNNABLE, ST_RUNNING, ST_BLOCKED)}


def fgset(c, console=0):
    row = peek_annex(c, VC_FGJOB_ADDR + console * VC_FGJ_STRIDE,
                     VC_FGJ_STRIDE)
    # count bit 7 is the SELF flag (TAB-A2 R1): fgself() reads it
    return row[0] & 0x7F, [p for p in row[1:] if p]


def fgself(c, console=0):
    return peek_annex(c, VC_FGJOB_ADDR + console * VC_FGJ_STRIDE, 1)[0] >> 7


def step(c, n=1):
    for _ in range(n):
        c.call_tool('step', {'cycles': 200_000})


def ctrl_z(c):
    # check_play's own idiom: the inject decodes the escape.
    c.call_tool('type', {'text': '\\x1a'})
    step(c, 4)


def at_prompt(rs):
    nb = [r for r in rs if r.strip()]
    return bool(nb) and re.fullmatch(r'\$( \$)*', nb[-1].strip()) is not None


def find_line(rs, prefix):
    """The LAST row starting with `prefix` (strip), or None."""
    hits = [r.strip() for r in rs if r.strip().startswith(prefix)]
    return hits[-1] if hits else None


def wait_line(c, prefix, label, max_steps=900):
    """Settle until a row starts with `prefix`; a `JC FAIL` row first
    is the program's own verdict and fails the case at once."""
    for _ in range(max_steps):
        step(c)
        rs = V.rows(c)
        f = find_line(rs, 'JC FAIL')
        if f:
            raise AssertionError(f'{label}: the harness failed: {f!r}')
        ln = find_line(rs, prefix)
        if ln:
            return ln
    raise AssertionError(f'timed out waiting for {label} ({prefix!r}); '
                         f'screen:\n' + '\n'.join(V.rows(c)))


def field(line, name):
    m = re.search(name + r'=([0-9A-F]{2})', line)
    if not m:
        raise AssertionError(f'no {name}= in {line!r}')
    return int(m.group(1), 16)


def go(c):
    V.t(c, 'G\r')


def describe(c, pids):
    st = pcbs(c)
    return ', '.join(f'{p}:{ST_NAME.get(st[p][0], st[p][0])}'
                     for p in sorted(pids))


class Syms:
    def __init__(self):
        self.vc_tmode = sym_addr('VC_TMODE')
        self.free_cnt = sym_addr('PRC_FREE_CNT')
        self.free_list = sym_addr('PRC_FREE_LIST')
        self.lz_banks = sym_addr('LZ_BANKS')
        self.lz_state = sym_addr('LZ_STATE')


def tmode(c, s):
    return peek_main(c, s.vc_tmode)[0]


def bank_disposition(c, s, bank):
    """Where a bank is now: 'free' (on PRC_FREE_LIST), 'held' (a
    lazy-free HELD tag), 'live' (a LIVE tag), or 'pcb:<pid>' if a
    non-UNUSED PCB still names it; else 'unknown'."""
    for pid, (st, b, _p) in pcbs(c).items():
        if st != ST_UNUSED and b == bank:
            return f'pcb:{pid}'
    n = peek_main(c, s.free_cnt)[0]
    if bank in peek_main(c, s.free_list, max(n, 1))[:n]:
        return 'free'
    banks = peek_main(c, s.lz_banks, LZ_SLOT_CNT)
    states = peek_main(c, s.lz_state, LZ_SLOT_CNT)
    for b, st in zip(banks, states):
        if b == bank and st == LZ_HELD:
            return 'held'
        if b == bank and st == LZ_LIVE:
            return 'live'
    return 'unknown'


# --------------------------------------------------------------------
def run(c, s):
    base = live_pids(c)
    print(f'[check-jobctl-b] baseline live = {describe(c, base)}',
          flush=True)

    # -- stop -----------------------------------------------------
    # The shell declares jctest as ITS foreground job only after
    # spawning it (the spawn window, docs/CONSOLE.md sec 4); jctest
    # waits for a G before it declares its own child, so its
    # declaration is the LAST one on the console.
    V.t(c, 'jctest\r')
    wait_line(c, 'JC READY', 'jctest to start')
    me = None
    for _ in range(300):
        step(c)
        new = live_pids(c) - base
        _n, fg = fgset(c)
        if new and set(fg) & new:
            me = (set(fg) & new).pop()
            break
    if me is None:
        raise AssertionError(f'stop: the shell never declared jctest '
                             f'foreground (fgset={fgset(c)}, live '
                             f'{sorted(live_pids(c))})')
    go(c)
    ln = wait_line(c, 'JC WAIT pid=', 'jctest to spawn and declare')
    child = field(ln, 'pid')
    cnt, fg = fgset(c)
    if child not in fg:
        raise AssertionError(f'stop: foreground set {fgset(c)} does not '
                             f'name the child {child}')
    st = pcbs(c)
    if st[child][0] not in (ST_RUNNABLE, ST_RUNNING, ST_BLOCKED):
        raise AssertionError(f'stop: child {child} is '
                             f'{ST_NAME.get(st[child][0])} before ^Z')
    bank = st[child][1]
    tm = tmode(c, s)
    if tm != TMD_RAW:
        raise AssertionError(f'stop: VC_TMODE is ${tm:02X} before ^Z -- '
                             f'jctest set RAW (TMD_OPOST=4, vi\'s raw), '
                             f'so the restore below would be vacuous')
    if fgself(c):
        raise AssertionError(f'stop: the declared set {fgset(c)} of a '
                             f'CHILD carries the SELF flag -- the sweep '
                             f'would stop at the child and never reach '
                             f'its descendants (the child-of-caller '
                             f'path must not fall into the self path)')
    print(f'[check-jobctl-b] child pid {child} bank {bank} declared '
          f'(fgset={fgset(c)}, no SELF flag), console RAW; typing ^Z',
          flush=True)
    ctrl_z(c)
    ln = wait_line(c, 'JC STOP pid=', 'stop: SYS_WAITJOB(WUNTRACED) '
                   'to return')
    st = pcbs(c)
    if st[child][0] != ST_STOPPED:
        raise AssertionError(f'stop: child {child} is '
                             f'{ST_NAME.get(st[child][0])} in the annex '
                             f'after ^Z, not STOPPED')
    if field(ln, 'st') != ST_STOPPED:
        raise AssertionError(f'stop: SYS_PSTAT read state '
                             f'{field(ln, "st")}, not STOPPED (5): {ln!r}')
    if (field(ln, 'pid'), field(ln, 'kind'), field(ln, 'code')) != \
            (child, 2, 0):
        raise AssertionError(f'stop: SYS_WAITJOB reported {ln!r}, expected '
                             f'pid={child:02X} kind=02 code=00')
    tm = tmode(c, s)
    if tm != TMD_COOKED:
        raise AssertionError(f'stop: VC_TMODE is ${tm:02X} after ^Z -- '
                             f'the sweep did not restore cooked+echo')
    if not any('^Z' in r for r in V.rows(c)):
        raise AssertionError('stop: ^Z was not echoed')
    print(f'[check-jobctl-b] ok   stop   ({ln}; annex STOPPED, tty '
          f'cooked+echo)', flush=True)

    # -- cont -----------------------------------------------------
    go(c)
    ln = wait_line(c, 'JC CONT st=', 'cont: SYS_CONT + PSTAT')
    if field(ln, 'st') not in (ST_RUNNABLE, ST_RUNNING, ST_BLOCKED):
        raise AssertionError(f'cont: child state after SYS_CONT is '
                             f'{field(ln, "st")}: {ln!r}')
    # prove the child RUNS again.  Until SLEEP-1 the child (a /bin/sleep)
    # polled SYS_TICK, so it could be sampled RUNNING.  It now BLOCKS on
    # the kernel's sleep channel, so it is hardly ever RUNNING; the proof
    # is the state a STOPPED process cannot be in: RUNNING, or BLOCKED on
    # SLP_CHAN (STOPPED clears WCHAN; only the rerun of the call after
    # the continue blocks there).  A SYS_CONT that never made it runnable
    # leaves it STOPPED or RUNNABLE and fails here (main 8484f330 passes
    # the old predicate, this tree failed it: A/B, SLEEP-1-NOTES sec 12).
    ran = False
    for _ in range(40):
        step(c)
        st = pcbs(c)[child][0]
        wc = peek_annex(c, PCB_ARRY_ADDR + child * PCB_ENT_SIZE
                        + PCB_WCHAN, 1)[0]
        if st == ST_RUNNING or (st == ST_BLOCKED and wc == SLP_CHAN):
            ran = True
            break
    if not ran:
        raise AssertionError(f'cont: child {child} never observed RUNNING '
                             f'or BLOCKED on the sleep channel after '
                             f'SYS_CONT (annex: '
                             f'{ST_NAME.get(pcbs(c)[child][0])})')
    go(c)
    ln = wait_line(c, 'JC NOHANG rc=', 'cont: SYS_WAITJOB(WNOHANG)')
    if field(ln, 'rc') != 0:
        raise AssertionError(f'cont: WNOHANG returned {ln!r}, expected 0 '
                             f'for a running child')
    print(f'[check-jobctl-b] ok   cont   (resumed and ran; {ln})',
          flush=True)

    # -- stop2 ----------------------------------------------------
    wait_line(c, 'JC WAIT2', 'stop2: the second WUNTRACED wait')
    ctrl_z(c)
    ln = wait_line(c, 'JC STOP2 pid=', 'stop2: the second stop report')
    if (field(ln, 'pid'), field(ln, 'kind'), field(ln, 'st')) != \
            (child, 2, ST_STOPPED):
        raise AssertionError(f'stop2: {ln!r}')
    if pcbs(c)[child][0] != ST_STOPPED:
        raise AssertionError('stop2: annex state is not STOPPED')
    print(f'[check-jobctl-b] ok   stop2  ({ln})', flush=True)

    # -- legacy + reap --------------------------------------------
    go(c)
    ln = wait_line(c, 'JC LEGACY', 'legacy: SYS_WAIT on a stopped-only '
                   'child set')
    if not ln.startswith('JC LEGACY err=') or field(ln, 'err') != ERR_CHILD:
        raise AssertionError(f'legacy: SYS_WAIT returned {ln!r}, expected '
                             f'err={ERR_CHILD:02X} (ERR_CHILD) -- a '
                             f'stopped-only set must not block or reap')
    print(f'[check-jobctl-b] ok   legacy ({ln})', flush=True)

    # -- tcsetfg ABI (TAB-A2): the caller may name ITSELF ---------
    # A raw-mode shell is never a child of itself; without this a
    # ^C/^Z at its prompt reaches it as a bare CR (docs/TAB-A2-
    # NOTES.md, learning:01M56Q7BH2T3B9TPX7FM47Q0VC). Each row's
    # result is the call's rc AND the console's declared set, read
    # from the annex while jctest waits for the G.
    def tc_row(prefix, want_rc, want_set, want_self, what):
        ln = wait_line(c, prefix, f'tcsetfg: {what}')
        rc = field(ln, 'rc')
        got = fgset(c)
        flag = fgself(c)
        if rc != want_rc:
            raise AssertionError(f'tcsetfg {what}: rc=${rc:02X}, '
                                 f'expected ${want_rc:02X}: {ln!r}')
        if got != want_set:
            raise AssertionError(f'tcsetfg {what}: declared set {got}, '
                                 f'expected {want_set}')
        if flag != want_self:
            raise AssertionError(f'tcsetfg {what}: SELF flag {flag}, '
                                 f'expected {want_self} (count bit 7: '
                                 f'the sweep matches a self set '
                                 f'EXACTLY)')
        print(f'[check-jobctl-b] ok   tcsetfg {what} ({ln}; '
              f'set={got} self={flag})', flush=True)
        go(c)

    ERR_INVAL = 0xE1
    tc_row('JC TCSELF rc=', 0, (1, [me]), 1, 'self is accepted')
    tc_row('JC TCNONE rc=', ERR_INVAL, (1, [me]), 1,
           'a non-child non-self pid is refused, set untouched')
    tc_row('JC TCTWO rc=', 0, (2, [me, child]), 1, '{self, child}')
    tc_row('JC TCCLR rc=', 0, (0, []), 0, '{0} clears (flag too)')
    # -- a SELF set matches only itself (review R1) ---------------
    # jctest lets the child run again, catches INT and declares
    # {self}; the gate types ^C. jctest must get the INT and its
    # child -- a child of the declarer, not a member -- must still
    # be alive: the sweep does not walk a self set's subtree.
    tc_row('JC TCSUBA rc=', 0, (1, [me]), 1, 'self set, child running')
    step(c, 6)
    c.call_tool('type', {'text': '\\x03'})
    step(c, 4)
    ln = wait_line(c, 'JC TCSUB sig=', 'tcsub: the report after ^C')
    sig, st = field(ln, 'sig'), field(ln, 'st')
    if sig != 2:
        raise AssertionError(f'tcsub: the declarer got signal {sig}, '
                             f'expected 2 (INT): {ln!r}')
    if st not in (ST_RUNNABLE, ST_RUNNING, ST_BLOCKED):
        raise AssertionError(f'tcsub: the child is {ST_NAME.get(st)} '
                             f'after ^C -- a SELF set swept the '
                             f'declarer\'s subtree: {ln!r}')
    print(f'[check-jobctl-b] ok   tcsub  (^C reached the declarer, its '
          f'child stayed {ST_NAME.get(st)}; {ln})', flush=True)
    go(c)
    wait_line(c, 'JC EXIT', 'reap: jctest to exit')
    V.settle(c, at_prompt, 'reap: the shell prompt back', max_steps=400)
    for _ in range(300):
        step(c)
        if live_pids(c) == base:
            break
    st = pcbs(c)
    bad = {p: ST_NAME.get(v[0]) for p, v in st.items()
           if v[0] in (ST_STOPPED, ST_ZOMBIE)}
    if bad:
        raise AssertionError(f'reap: slots left STOPPED/ZOMBIE after the '
                             f'parent exited: {bad} -- the orphan reap '
                             f'did not run')
    if live_pids(c) != base:
        raise AssertionError(f'reap: live set {sorted(live_pids(c))} != '
                             f'baseline {sorted(base)}')
    disp = bank_disposition(c, s, bank)
    if disp not in ('free', 'held'):
        raise AssertionError(f'reap: the stopped child\'s bank {bank} is '
                             f'{disp} after its parent exited -- a leaked '
                             f'bank')
    print(f'[check-jobctl-b] ok   reap   (child {child} slot UNUSED, bank '
          f'{bank} {disp}; live = {describe(c, live_pids(c))})',
          flush=True)


def main():
    for path, what in ((DISK, 'build/jobctl.po -- run make jobctl-image'),
                       (SYMFILE, 'MAUXPLAY symbol dump -- run make '
                                 'play-image')):
        if not os.path.exists(path):
            print(f'error: {what} ({path})', file=sys.stderr)
            return 2
    s = Syms()
    print('[check-jobctl-b] symbols: ' +
          ' '.join(f'{k}=${v:04X}' for k, v in vars(s).items()))
    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
    c = MCPClient([SUPERVISOR], env)
    V.DISK = DISK                     # boot() mounts this, copy-on-write
    ok = False
    try:
        c.initialize()
        V.boot(c)
        try:
            run(c, s)
            ok = True
        except AssertionError as e:
            print(f'[check-jobctl-b] FAIL: {e}', file=sys.stderr)
    finally:
        try:
            c.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        c.close()
    if not ok:
        return 1
    print('[check-jobctl-b] PASS: ^Z stops the declared foreground job '
          '(state 5, tty restored), SYS_CONT resumes it, SYS_WAITJOB '
          'reports {stopped} twice and polls without blocking, legacy '
          'SYS_WAIT refuses a stopped-only set, and a dying parent\'s '
          'stopped child is reaped with its bank')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
