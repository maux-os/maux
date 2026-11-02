#!/usr/bin/env python3
"""check_jobctl_c.py -- the shell half of job control (`make
check-jobctl-c`, in check-all-cross). docs/JOB-CONTROL.md, Increment C:
the job table, `jobs` / `fg` / `bg`, the SC_WAITJOB foreground reap, and
the prompt-time `[n]  Done   cmd` notices. Driven at the REAL shell's
prompt on build/play.po (the image whose playtest.s installs the ^C and
^Z sweeps), asserted on the glass and on the annex PCB table.

Cases, in order (each leaves the table empty for the next):

  stop      `sleep 20`, ^Z: the prompt comes back with `[1]+ Stopped
            sleep 20` above it, the sleep's PCB is STOPPED (5), and the
            console's foreground set is EMPTY again (FG_CLEAR ran).
            `jobs` lists the same row. Increment B's shell simply
            reprompted here: the legacy reap loop got ERR_CHILD and the
            job was parked with no name.
  fg        `fg`: the row's command text is echoed, the kernel's
            foreground set names the pid again (SYS_TCSETFG), the sleep
            is RUNNABLE/RUNNING/BLOCKED once more (SYS_CONT), and it runs
            to completion -- slot UNUSED, prompt back, `$?` = 0.
  bg        `sleep 5`, ^Z, `bg`: `[1]+ sleep 5 &`, the prompt returns AT
            ONCE while the sleep runs on (annex: not STOPPED); when it
            exits, the NEXT prompt -- an empty line typed after the PCB
            is ZOMBIE -- prints `[1]+ Done   sleep 5` (still the current
            job, so `+`) and the slot is
            reaped (UNUSED). V7's "reported at the next prompt".
  amp       `sleep 8 &`: `[1] <pid>` (and W4's unredirected-output
            diagnostic), `$?` = 0, and the same Done notice at the next
            prompt once it finishes.
  badspec   `fg %9` / `bg %9` (no such row) and a bare `fg` with no jobs
            at all: `sh: no such job`, `$?` = 1, the prompt back, nothing
            spawned or continued.
  pct       the `%spec` COMMAND shorthand (POSIX/csh): `sleep 20`, ^Z,
            then `%1` alone is `fg %1` -- declared, resumed, echoed, run
            to completion, `$?` = 0; `sleep 5`, ^Z, `%1 &` is `bg %1` --
            `[1]+ sleep 5 &`, prompt back at once, Done at the next
            prompt; `sleep 20`, ^Z, a bare `%` is the current job, same
            as `%+`; and `%9` with no such row is `sh: no such job`,
            `$?` = 1, nothing spawned.
  kill      `kill %n` resolves the job spec to the job's LIVE member
            pids before /bin/kill is spawned (shjob.s KILL_SPECS -- a
            per-command rewrite, not a word expansion): `sleep 20 |
            sleep 20 &` then `kill %1` kills BOTH stages (maux has no
            process groups), `$?` = 0, `[1]+ Terminated   sleep 20 |
            sleep 20` at the next prompt; `kill -9 %1` likewise (the
            signo passes through untouched); `kill <pid>` still works
            (no regression -- the rewrite leaves plain operands alone);
            `kill %9` is `sh: no such job`, `$?` = 1, nothing signalled.
  wait      `wait %n` (CHCK_BLTN_WT): `sleep 12 &`, then `echo %1` prints
            `%1` LITERALLY (proves there is no general `%` expansion),
            then `wait %1` BLOCKS -- the prompt does not come back
            while the sleep lives -- and returns once it exits: `$?` = 0
            (the job's own status), the pid reaped, the row freed
            silently (no Done notice); `wait %9` is `sh: no such job`,
            `$?` = 1; and `wait 5` (a plain pid) stays refused with the
            usage line, `$?` = 1.

Teeth (measured on dc19977, Increment B's tip): `stop` goes RED -- the
^Z reprompts without a Stopped notice (the shell's reap loop was
SC_WAIT), and `jobs` is `sh: command not found`. GREEN here. `pct`
measured on de7ea88 (Increment C's tip): `%1` alone is `sh: command not
found` and the job stays parked -- RED; GREEN with the shorthand.
`kill`/`wait` measured on 77376d1 (the `%spec` shorthand's tip): `kill
%1` reaches /bin/kill with a literal `%1` -- `kill: %1: bad pid`,
`$?` = 1, both stages live -- RED; GREEN with KILL_SPECS.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_race as GR                                  # noqa: E402
import check_vi as V                                    # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR    # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# inc/mm.annex*.equ -- the PCB array and the foreground table.
PCB_ARRY_ADDR = 0x0800
PCB_ENT_SIZE = 16
PCB_COUNT = 48
PCB_STATE = 1
PCB_PARENT = 4
ST_UNUSED, ST_RUNNABLE, ST_RUNNING, ST_BLOCKED, ST_ZOMBIE, ST_STOPPED = \
    0, 1, 2, 3, 4, 5
ST_NAME = {0: 'UNUSED', 1: 'RUNNABLE', 2: 'RUNNING', 3: 'BLOCKED',
           4: 'ZOMBIE', 5: 'STOPPED'}
LIVE = (ST_RUNNABLE, ST_RUNNING, ST_BLOCKED)
VC_FGJOB_ADDR = 0x7680
VC_FGJ_STRIDE = 4

TAG = '[check-jobctl-c]'


def at_prompt(rs):
    """The last non-blank row is a prompt (`$ $` after a ^Z/^C: the
    tty completes an empty line the shell then reprompts for)."""
    nb = [r for r in rs if r.strip()]
    return bool(nb) and re.fullmatch(r'\$( \$)*', nb[-1].strip()) is not None


def peek_annex(c, addr, n):
    r = c.call_tool('peek', {'addr': addr, 'count': n, 'bank': 'aux',
                             'aux_bank': 0})
    return r.get('bytes') or r.get('data')


def pcbs(c):
    tbl = peek_annex(c, PCB_ARRY_ADDR, PCB_COUNT * PCB_ENT_SIZE)
    out = {}
    for pid in range(1, PCB_COUNT):
        e = tbl[pid * PCB_ENT_SIZE:(pid + 1) * PCB_ENT_SIZE]
        out[pid] = (e[PCB_STATE], e[PCB_PARENT])
    return out


def live_pids(c):
    return {pid for pid, (st, _) in pcbs(c).items() if st in LIVE}


def state(c, pid):
    return pcbs(c)[pid][0]


def fgset(c, console=0):
    row = peek_annex(c, VC_FGJOB_ADDR + console * VC_FGJ_STRIDE,
                     VC_FGJ_STRIDE)
    return row[0] & 0x7F, [p for p in row[1:] if p]   # bit 7: SELF


def shell_pid(c):
    """The console shell: init's child, past idle (pid 2)."""
    for pid, (st, par) in sorted(pcbs(c).items()):
        if par == 1 and pid > 2 and st in LIVE:
            return pid
    raise AssertionError('no console shell found')


def fg_jobs(c):
    """The declared foreground set MINUS the shell itself: while sh reads
    its prompt it declares itself (SYS_TCSETFG {1, self}, TAB-A2) so ^C
    and ^Z reach it as signals. That is not a job; no JOB may be left."""
    cnt, pids = fgset(c)
    return [p for p in pids if p != shell_pid(c)]


def step(c, n=1):
    for _ in range(n):
        c.call_tool('step', {'cycles': 200_000})


def ctrl_z(c):
    c.call_tool('type', {'text': '\\x1a'})
    step(c, 4)


def rows_after(rs, cmd):
    """The rows below the LAST echoed `$ cmd` line (or all rows)."""
    pat = re.compile(r'\$ ' + re.escape(cmd) + r'\s*$')
    idx = [i for i, r in enumerate(rs) if pat.search(r)]
    return rs[idx[-1] + 1:] if idx else rs


def has(rs, regex):
    return any(re.search(regex, r) for r in rs)


def settle(c, pred, label, max_steps=600):
    try:
        return V.settle(c, pred, label, max_steps=max_steps)
    except AssertionError as e:
        raise AssertionError(f'{label}: {e}')


def new_pid(c, base, label, max_steps=300):
    for _ in GR.polls(c, max_steps):
        new = live_pids(c) - base
        if new:
            return new.pop()
    raise AssertionError(f'{label}: no new process appeared; screen:\n'
                         + '\n'.join(V.rows(c)))


def wait_declared(c, pid, label, max_steps=300):
    for _ in GR.polls(c, max_steps):
        if pid in fgset(c)[1]:
            return
    raise AssertionError(f'{label}: the shell never declared pid {pid} '
                         f'foreground (fgset={fgset(c)})')


def wait_state(c, pid, states, label, max_steps=600):
    for _ in GR.polls(c, max_steps):
        if state(c, pid) in states:
            return
    raise AssertionError(f'{label}: pid {pid} is {ST_NAME.get(state(c, pid))}'
                         f', wanted {[ST_NAME[s] for s in states]}')


def echo_status(c, want, label):
    V.t(c, 'echo $?\r')
    settle(c, lambda rs: at_prompt(rs) and
           any(r.strip() == str(want) for r in rows_after(rs, 'echo $?')),
           f'{label}: `echo $?` prints {want}')


def stop_job(c, cmd, label):
    """Run `cmd` foreground, ^Z it once declared. Returns the pid; the
    prompt is back with the Stopped notice and the fg set is empty."""
    base = live_pids(c)
    V.t(c, cmd + '\r')
    pid = new_pid(c, base, label)
    wait_declared(c, pid, label)
    print(f'{TAG} {label}: `{cmd}` is pid {pid}, declared '
          f'{fgset(c)}; typing ^Z', flush=True)
    ctrl_z(c)
    settle(c, lambda rs: at_prompt(rs) and
           has(rows_after(rs, cmd), r'\[\d+\]\+ Stopped\s+' + re.escape(cmd)),
           f'{label}: `[n]+ Stopped   {cmd}` and the prompt back')
    st = state(c, pid)
    if st != ST_STOPPED:
        raise AssertionError(f'{label}: pid {pid} is {ST_NAME.get(st)} after '
                             f'^Z, not STOPPED')
    if fg_jobs(c):
        raise AssertionError(f'{label}: a job is still in the foreground '
                             f'set at the prompt: {fgset(c)}')
    return pid


def wait_done_notice(c, pid, cmd, label):
    """Let the job finish (PCB ZOMBIE), then an empty line: the next
    prompt reports it Done and the slot is reaped."""
    wait_state(c, pid, (ST_ZOMBIE, ST_UNUSED), f'{label}: `{cmd}` to '
               f'finish')
    V.t(c, '\r')
    settle(c, lambda rs: at_prompt(rs) and
           has(rs, r'\[\d+\][+ -] Done\s+' + re.escape(cmd)),
           f'{label}: `[n]<flag> Done   {cmd}` at the next prompt')
    st = state(c, pid)
    if st != ST_UNUSED:
        raise AssertionError(f'{label}: pid {pid} is {ST_NAME.get(st)} after '
                             f'the Done notice -- not reaped')


# --------------------------------------------------------------------
def case_stop(c):
    pid = stop_job(c, 'sleep 20', 'stop')
    V.t(c, 'jobs\r')
    settle(c, lambda rs: at_prompt(rs) and
           has(rows_after(rs, 'jobs'), r'\[1\]\+ Stopped\s+sleep 20'),
           'stop: `jobs` lists `[1]+ Stopped   sleep 20`')
    print(f'{TAG} ok   stop   (pid {pid} STOPPED, fg set empty, jobs '
          f'lists it)', flush=True)
    return pid


def resume_fg(c, pid, cmd, label):
    """Type `cmd` (`fg`, `%1`, `%`...): the stopped sleep-20 `pid` is
    declared, resumed, its text echoed, and it runs to completion with
    `$?` = 0 and the foreground set empty again."""
    V.t(c, cmd + '\r')
    wait_declared(c, pid, label)
    wait_state(c, pid, LIVE, f'{label}: SYS_CONT resumed the sleep',
               max_steps=100)
    settle(c, lambda rs: has(rows_after(rs, cmd), r'^sleep 20\s*$'),
           f'{label}: the command text echoed', max_steps=100)
    settle(c, lambda rs: at_prompt(rs) and state(c, pid) == ST_UNUSED,
           f'{label}: the sleep ran to completion and was reaped',
           max_steps=1500)
    if fg_jobs(c):
        raise AssertionError(f'{label}: a job is still in the foreground '
                             f'set after it completed: {fgset(c)}')
    echo_status(c, 0, label)


def resume_bg(c, pid, cmd, label):
    """Type `cmd` (`bg`, `%1 &`): the stopped sleep-5 `pid` runs on in
    the background, `[1]+ sleep 5 &`, prompt back at once, then the Done
    notice at the next prompt."""
    V.t(c, cmd + '\r')
    settle(c, lambda rs: at_prompt(rs) and
           has(rows_after(rs, cmd), r'\[1\]\+ sleep 5 &'),
           f'{label}: `[1]+ sleep 5 &` and the prompt back at once',
           max_steps=60)
    st = state(c, pid)
    if st == ST_STOPPED:
        raise AssertionError(f'{label}: the sleep is still STOPPED after '
                             f'`{cmd}`')
    if fg_jobs(c):
        raise AssertionError(f'{label}: `{cmd}` must not take the '
                             f'foreground: {fgset(c)}')
    print(f'{TAG} {label}: resumed in the background ({ST_NAME.get(st)}), '
          f'prompt back', flush=True)
    wait_done_notice(c, pid, 'sleep 5', label)


def case_fg(c, pid):
    resume_fg(c, pid, 'fg', 'fg')
    print(f'{TAG} ok   fg     (resumed, declared, completed, $?=0)',
          flush=True)


def case_bg(c):
    pid = stop_job(c, 'sleep 5', 'bg')
    resume_bg(c, pid, 'bg', 'bg')
    print(f'{TAG} ok   bg     (ran on, Done at the next prompt, reaped)',
          flush=True)


# The background jobs below must still be RUNNING when the harness first
# looks. The harness spends ~1M guest cycles between typing the line and
# its first poll (and MAUX_GATE_RACE=late adds 3M), and a job that has
# already finished is invisible to new_pid. 8 s is ~8.2M: >4M of margin.
AMP_LEN = 8
WAIT_LEN = 12          # `wait %1` must still BLOCK ~4M cycles after typing


def case_amp(c):
    base = live_pids(c)
    V.t(c, f'sleep {AMP_LEN} &\r')
    pid = new_pid(c, base, 'amp')
    settle(c, lambda rs: at_prompt(rs) and
           has(rows_after(rs, f'sleep {AMP_LEN} &'),
               r'\[1\] ' + str(pid) + r'\s*$')
           and has(rs, r'sh: background output not redirected'),
           f'amp: `[1] {pid}` + the W4 diagnostic and the prompt back')
    echo_status(c, 0, 'amp')
    wait_done_notice(c, pid, f'sleep {AMP_LEN}', 'amp')
    print(f'{TAG} ok   amp    (`[1] {pid}`, $?=0, Done at the next '
          f'prompt)', flush=True)


def case_badspec(c):
    base = live_pids(c)
    for cmd in ('fg %9', 'bg %9', 'fg'):
        V.t(c, cmd + '\r')
        settle(c, lambda rs: at_prompt(rs) and
               has(rows_after(rs, cmd), r'sh: no such job'),
               f'badspec: `{cmd}` -> `sh: no such job`', max_steps=60)
        echo_status(c, 1, f'badspec {cmd}')
    if live_pids(c) != base:
        raise AssertionError(f'badspec: the live set changed: '
                             f'{sorted(base)} -> {sorted(live_pids(c))}')
    print(f'{TAG} ok   badspec (fg %9 / bg %9 / bare fg refused, $?=1)',
          flush=True)


def case_pct(c):
    """The `%spec` command shorthand -- the fg/bg paths under a different
    spelling, so the same assertions as `fg`/`bg` above."""
    pid = stop_job(c, 'sleep 20', 'pct %1')
    resume_fg(c, pid, '%1', 'pct %1')
    pid = stop_job(c, 'sleep 5', 'pct %1 &')
    resume_bg(c, pid, '%1 &', 'pct %1 &')
    pid = stop_job(c, 'sleep 20', 'pct %')
    resume_fg(c, pid, '%', 'pct %')
    base = live_pids(c)
    V.t(c, '%9\r')
    settle(c, lambda rs: at_prompt(rs) and
           has(rows_after(rs, '%9'), r'sh: no such job'),
           'pct: `%9` -> `sh: no such job`', max_steps=60)
    echo_status(c, 1, 'pct %9')
    if live_pids(c) != base:
        raise AssertionError(f'pct: `%9` changed the live set: '
                             f'{sorted(base)} -> {sorted(live_pids(c))}')
    print(f'{TAG} ok   pct    (`%1` = fg %1, `%1 &` = bg %1, `%` = the '
          f'current job, `%9` refused $?=1)', flush=True)


def bg_job(c, cmd, nstages, label):
    """Type `cmd &`: `nstages` new live pids appear, `[1] <tail>` and
    the prompt come back. Returns the set of new pids."""
    base = live_pids(c)
    V.t(c, cmd + ' &\r')
    pids = set()
    for _ in GR.polls(c, 400):
        pids = live_pids(c) - base
        if len(pids) >= nstages:
            break
    if len(pids) != nstages:
        raise AssertionError(f'{label}: `{cmd} &` spawned {sorted(pids)}, '
                             f'wanted {nstages} stages; screen:\n'
                             + '\n'.join(V.rows(c)))
    settle(c, lambda rs: at_prompt(rs) and
           has(rows_after(rs, cmd + ' &'), r'\[1\] \d+\s*$'),
           f'{label}: `[1] pid` and the prompt back')
    return pids


def wait_gone(c, pids, label, max_steps=300):
    """Every pid in `pids` leaves the live set (ZOMBIE or reaped)."""
    for _ in GR.polls(c, max_steps):
        if not (pids & live_pids(c)):
            return
    raise AssertionError(f'{label}: {sorted(pids & live_pids(c))} still '
                         f'live; screen:\n' + '\n'.join(V.rows(c)))


def kill_job(c, cmd, nstages, killcmd, label):
    """`cmd &` (nstages live), then `killcmd`: every stage dies, `$?` =
    0, and the next prompt reports `[1]+ Terminated   cmd`."""
    pids = bg_job(c, cmd, nstages, label)
    V.t(c, killcmd + '\r')
    settle(c, lambda rs: at_prompt(rs), f'{label}: prompt after `{killcmd}`',
           max_steps=100)
    rs = rows_after(V.rows(c), killcmd)
    if has(rs, r'kill: |sh: '):
        raise AssertionError(f'{label}: `{killcmd}` diagnosed something:\n'
                             + '\n'.join(rs))
    wait_gone(c, pids, f'{label}: `{killcmd}` killed {sorted(pids)}',
              max_steps=60)
    echo_status(c, 0, label)
    settle(c, lambda rs: at_prompt(rs) and
           has(rs, r'\[1\][+ -] Terminated\s+' + re.escape(cmd)),
           f'{label}: `[1]+ Terminated   {cmd}` at the next prompt',
           max_steps=60)
    for pid in pids:
        st = state(c, pid)
        if st != ST_UNUSED:
            raise AssertionError(f'{label}: pid {pid} is {ST_NAME.get(st)} '
                                 f'after the Terminated notice -- not reaped')
    print(f'{TAG} {label}: `{killcmd}` killed {sorted(pids)}, $?=0, '
          f'Terminated at the next prompt', flush=True)


def refused(c, cmd, regex, label):
    """`cmd` prints `regex`, `$?` = 1, and the live set is unchanged."""
    base = live_pids(c)
    V.t(c, cmd + '\r')
    settle(c, lambda rs: at_prompt(rs) and has(rows_after(rs, cmd), regex),
           f'{label}: `{cmd}` -> `{regex}`', max_steps=60)
    echo_status(c, 1, f'{label} {cmd}')
    if live_pids(c) != base:
        raise AssertionError(f'{label}: `{cmd}` changed the live set: '
                             f'{sorted(base)} -> {sorted(live_pids(c))}')


def case_kill(c):
    kill_job(c, 'sleep 20 | sleep 20', 2, 'kill %1', 'kill %1')
    kill_job(c, 'sleep 20', 1, 'kill -9 %1', 'kill -9 %1')
    pids = bg_job(c, 'sleep 20', 1, 'kill pid')
    pid = pids.pop()
    V.t(c, f'kill {pid}\r')
    wait_gone(c, {pid}, f'kill pid: `kill {pid}` killed it', max_steps=60)
    echo_status(c, 0, 'kill pid')
    settle(c, lambda rs: at_prompt(rs) and
           has(rs, r'\[1\][+ -] Terminated\s+sleep 20\s*$'),
           'kill pid: `[1]+ Terminated   sleep 20` at the next prompt',
           max_steps=60)
    refused(c, 'kill %9', r'sh: no such job', 'kill badspec')
    kill_failures(c)
    print(f'{TAG} ok   kill   (`kill %1` killed both stages, `kill -9 %1`, '
          f'`kill {pid}` plain, `kill %9` refused $?=1, a failed pid is '
          f'exit 1 and never a usage line)', flush=True)


def kill_failures(c):
    """KFIX 4: kill's exit status when pids FAIL. POSIX: >0 if any
    failed; the usage line is for a usage error only. Before, kill.s
    counted only the pids it had killed as 'operands', so `kill 200`
    printed `kill: 200: no such process`, then the usage line, exit 2.
      * every pid failed  : the diagnostic, exit 1, NO usage line;
      * a mixed run       : the live pid IS signalled (it dies, and
                            is reaped as Terminated), the dead one is
                            diagnosed, exit 1."""
    base = live_pids(c)
    V.t(c, 'kill 200\r')
    settle(c, lambda rs: at_prompt(rs) and
           has(rows_after(rs, 'kill 200'), r'kill: 200: no such process'),
           'kill failures: `kill 200` diagnosed', max_steps=60)
    rs = rows_after(V.rows(c), 'kill 200')
    if has(rs, r'usage: '):
        raise AssertionError('kill failures: `kill 200` printed the usage '
                             'line after its diagnostic:\n' + '\n'.join(rs))
    echo_status(c, 1, 'kill failures: every pid failed')
    if live_pids(c) != base:
        raise AssertionError('kill failures: `kill 200` changed the live '
                             'set')
    pids = bg_job(c, 'sleep 20', 1, 'kill mixed')
    pid = next(iter(pids))
    cmd = f'kill {pid} 200'
    V.t(c, cmd + '\r')
    settle(c, lambda rs: at_prompt(rs) and
           has(rows_after(rs, cmd), r'kill: 200: no such process'),
           f'kill failures: `{cmd}` diagnosed the dead pid', max_steps=100)
    rs = rows_after(V.rows(c), cmd)
    if has(rs, r'usage: '):
        raise AssertionError(f'kill failures: `{cmd}` printed a usage '
                             f'line:\n' + '\n'.join(rs))
    wait_gone(c, {pid}, f'kill failures: `{cmd}` signalled the live pid',
              max_steps=60)
    echo_status(c, 1, 'kill failures: a mixed run')
    settle(c, lambda rs: at_prompt(rs) and
           has(rs, r'\[1\][+ -] Terminated\s+sleep 20\s*$'),
           'kill failures: the live pid was Terminated', max_steps=60)
    print(f'{TAG} ok   killfail (`kill 200` -> diagnostic, $?=1, no usage; '
          f'`{cmd}` -> the live pid died, the dead one diagnosed, $?=1)',
          flush=True)


def case_wait(c):
    pids = bg_job(c, f'sleep {WAIT_LEN}', 1, 'wait')
    pid = next(iter(pids))
    # No general expansion: `echo %1` is literal while job 1 exists.
    V.t(c, 'echo %1\r')
    settle(c, lambda rs: at_prompt(rs) and
           any(r.strip() == '%1' for r in rows_after(rs, 'echo %1')),
           'wait: `echo %1` prints `%1` literally', max_steps=60)
    V.t(c, 'wait %1\r')
    # It must BLOCK: several polls in, the sleep still lives and no
    # prompt has come back below the echoed command.
    step(c, 6)
    rs = V.rows(c)
    if state(c, pid) not in LIVE:
        raise AssertionError(f'wait: the sleep is {ST_NAME.get(state(c, pid))}'
                             f' already -- the probe cannot see blocking')
    if at_prompt(rows_after(rs, 'wait %1')) or \
            has(rows_after(rs, 'wait %1'), r'sh: |usage: '):
        raise AssertionError('wait: `wait %1` returned (or was refused) '
                             'while the sleep still lives:\n'
                             + '\n'.join(rows_after(rs, 'wait %1')))
    settle(c, lambda rs: at_prompt(rs) and state(c, pid) == ST_UNUSED,
           'wait: `wait %1` returned once the sleep exited, pid reaped',
           max_steps=200)
    if has(rows_after(V.rows(c), 'wait %1'), r'\[1\].*Done'):
        raise AssertionError('wait: `wait %1` printed a Done notice -- it '
                             'must free the row silently')
    echo_status(c, 0, 'wait')
    refused(c, 'wait %9', r'sh: no such job', 'wait badspec')
    refused(c, 'wait 5', r'usage: wait', 'wait pid')
    print(f'{TAG} ok   wait   (`echo %1` literal, `wait %1` blocked then '
          f'returned $?=0 with no notice, `wait %9` refused, `wait 5` '
          f'refused)', flush=True)


def run(c):
    pid = case_stop(c)
    case_fg(c, pid)
    case_bg(c)
    case_amp(c)
    case_badspec(c)
    case_pct(c)
    case_kill(c)
    case_wait(c)


def main():
    if not os.path.exists(V.DISK):
        print('error: build/play.po missing -- run make play-image',
              file=sys.stderr)
        return 2
    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
    c = MCPClient([SUPERVISOR], env)
    ok = False
    try:
        c.initialize()
        V.boot(c)
        try:
            run(c)
            ok = True
        except AssertionError as e:
            print(f'{TAG} FAIL: {e}', file=sys.stderr)
    finally:
        try:
            c.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        c.close()
    if not ok:
        return 1
    print(f'{TAG} PASS: ^Z parks a Stopped job the shell names, fg '
          'resumes it to completion, bg runs it on without the console, '
          'finished jobs are reported Done at the next prompt, a bad '
          'job spec is refused, `kill %n` signals every stage of a job, '
          'and `wait %n` blocks on one job')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
