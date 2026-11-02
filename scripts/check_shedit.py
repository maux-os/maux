#!/usr/bin/env python3
"""check_shedit.py -- the shell's own line editor (`make check-shedit`;
src/bin/shedit.s, docs/TAB-A2.md, docs/TAB-A2-NOTES.md).

At the interactive console prompt sh reads raw and edits the line
itself; every other reader (a script, `sh < file`, a $( ) child, a
pipe, cat, ed, read) is untouched. check-play's readline-lite rows,
check-typeahead and check-intr-prompt are the parity oracle for the
bindings and run UNCHANGED against it; this gate adds what only the
userland editor has:

  modes      raw at the prompt (VC_TMODE 4), cooked+echo (7) the moment
             a child runs -- the child never inherits the raw tty
  typeahead  bytes typed while a command runs (cooked) and bytes typed
             in a burst at the prompt (raw) arrive in order, none lost,
             none doubled
  intr_mid   ^C with the cursor MID-line on a WRAPPED line: the line is
             abandoned (never run), the next prompt lands BELOW the
             whole line, the shell lives
  stop       ^Z at the prompt: the line is abandoned and the login
             shell is NOT stopped (TSTP is caught around the read)
  eof        ^D on an empty line leaves the shell; on a non-empty line
             it deletes forward
  switch     Option-2 and back partway through a line keeps the line
  noraw      `sh SCRIPT` and `sh < FILE` never call SYS_TTYMODE (the
             console's mode cell is not written while they run)
  hist       history is per shell: a nested `sh` and a respawned login
             shell start empty, the parent's survives; eight entries,
             the ninth drops the oldest; a walk stashes the line in
             progress and ^N past the newest restores it
  trap_int   a user `trap ... INT` fires on ^C at the idle prompt and
             the half-typed line does not run (sh(1))
  cap        the line stops at 127 characters, as the kernel's does
  column     output without a final newline: the prompt follows it on
             the SAME row (the glass is the kernel editor's) and a
             short edit still works
  bgjob      ^C and ^Z at the idle prompt abandon the line and leave
             EVERY job alone: a running `&` job, and a stopped job
             whose members catch TSTP (a running stage in it): the
             shell is declared as itself only, and the sweep does not
             walk a self set's subtree (review R1; the PCB table is
             read with `ps` before and after)
  stopjob    the stopped-job half of bgjob on its own: no `&` job, only
             the stopped pipeline whose stage ignores TSTP
  esc_cr     ESC [ then Return: the CR is swallowed by the escape and
             the line is still open AND still raw (review R2)
  clear      ^L clears the screen and redraws the prompt and the line
             at the top; output printed before the prompt is gone (the
             kernel's cooked ^L replays it; a process cannot - sh(1),
             review R3a)
  term       a TERM sent to the shell while it sits in the raw read (an
             interactive sh catches TERM with no action, RULINGS-1)
             neither abandons the line nor ends the shell: the console
             stays raw, the line stays open and finishes as typed
  termtrap   a TRAPPED TERM with a line typed (and inside a construct)
             waits: the line runs, then the trap exactly once
  kill9      kill -9 of the shell in the raw read: the console is
             cooked again the instant it dies (PRC_TMD_RST, the shell
             is in its console's SELF foreground set), before the
             successor shell's start-up stamp could do it
  parity     the same key scripts typed at the userland editor and at
             `sh -E` (the kernel's cooked editor) run the same lines

Each case runs in its own emulator session so one red does not hide
another: `check_shedit.py [text40|ut|all] [case ...]`. Sabotage for
each row's teeth is listed in docs/TAB-A2-NOTES.md.
"""
import os
import re
import sys

import e2e_term as E
import gate_race as GR
from split_kseg import _read_symbol

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SYMS = os.path.join(ROOT, 'build', 'MAUXPLAY.SYSTEM_Output.txt')

# Control keys are spelled as the `type` tool's \xHH escapes: a raw
# $0A or $0D would be taken for Return.
CTRL = {c: '\\x%02x' % (ord(c) - 64) for c in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'}
ESC = '\\x1b'
DEL = '\\x7f'
UP, DOWN, RIGHT, LEFT = '\\x0b', '\\x0a', '\\x15', '\\x08'   # //e arrows
OPT = '<OPT:'                      # '<OPT:u>' = Option held, key u
TOKEN = re.compile(r'\\x[0-9a-f]{2}|<OPT:.>|.', re.S)

TM_RAW, TM_COOKED = 4, 7        # TMD_OPOST ; ICANON|ECHO|OPOST


def rows(t):
    return [r.rstrip() for r in t.screen() if r.strip()]


def bare(t, word):
    return sum(1 for r in rows(t) if r == word)


def settle(t, n=8, cyc=None):
    for _ in range(n):
        t._slice(cyc)


def peek_main(t, addr, n=1):
    r = t.c.call_tool('peek', {'addr': addr, 'count': n, 'bank': 'main'})
    return r.get('bytes') or r.get('data')


def tmode(t):
    return peek_main(t, _read_symbol(SYMS, 'VC_TMODE'))[0]


def need(cond, what, t=None):
    if not cond:
        raise AssertionError(what + ('\n' + '\n'.join(rows(t)) if t else ''))


def press_tok(t, tok):
    if tok.startswith(OPT):
        t.c.call_tool('buttons', {'closed_apple': True})
        t.c.call_tool('type', {'text': tok[len(OPT)]})
        settle(t, 3)
        t.c.call_tool('buttons', {'closed_apple': False})
        settle(t, 2)
    else:
        t.press(tok)


def keys(t, s):
    """Type `s` one key at a time (a person): control keys as \\xHH
    escapes, Option+key as <OPT:k>."""
    for tok in TOKEN.findall(s):
        press_tok(t, tok)


def run_line(t, s, label):
    """Type a command, Enter, and wait for the prompt to settle."""
    keys(t, s)
    t.enter()
    t.wait_prompt(label)


def wait_dollar(t, label, polls=60):
    """The prompt is back and settled: the last row ends in `$` (it
    may follow unterminated output) and two polls agree."""
    last, stable = None, 0
    for _ in range(GR.count(polls, E.KEY_CYC_MAX)):
        r = rows(t)
        cur = r[-1] if r else ''
        if cur.endswith('$') and cur == last:
            stable += 1
            if stable >= 2:
                return
        else:
            stable = 0
        last = cur
        t._poll()
    raise AssertionError(label + ': prompt never settled\n'
                         + '\n'.join(rows(t)))


def last_is_prompt(t):
    r = rows(t)
    return bool(r) and r[-1] == '$'


# ---------------------------------------------------------------------
def case_modes(t):
    t.wait_prompt('ready')
    settle(t, 4)
    need(tmode(t) == TM_RAW,
         f'at the idle prompt VC_TMODE is ${tmode(t):02X}, want raw '
         f'(${TM_RAW:02X}: the editor owns the line)', t)
    keys(t, 'sleep 4')
    t.enter()
    settle(t, 14)
    need(tmode(t) == TM_COOKED,
         f'while a child runs VC_TMODE is ${tmode(t):02X}, want cooked+'
         f'echo (${TM_COOKED:02X}): the child inherited the raw tty', t)
    t.wait_prompt('sleep done', timeout_slices=200)
    settle(t, 4)
    need(tmode(t) == TM_RAW, 'the prompt did not take the console back '
         f'(VC_TMODE ${tmode(t):02X})', t)
    # the same after an abandoned line, and after one the editor ran
    keys(t, 'echo x')
    t.press(CTRL['C'])
    t.wait_prompt('after ^C')
    settle(t, 4)
    need(tmode(t) == TM_RAW, f'after ^C VC_TMODE ${tmode(t):02X}', t)
    run_line(t, 'stty', 'stty')
    need('ICANON ECHO OPOST' in rows(t),
         'a child started from the prompt (stty) did not see the '
         'cooked+echo tty', t)


def case_typeahead(t):
    t.wait_prompt('ready')
    # cooked arrival: typed while `sleep` runs
    keys(t, 'sleep 2')
    t.enter()
    settle(t, 3)
    keys(t, 'echo AB')                  # no Enter: cooked edit buffer
    for _ in range(GR.count(300, E.KEY_CYC_MAX)):   # the editor repaints it
        if any(r.endswith('$ echo AB') for r in rows(t)):
            break
        t._poll()
    else:
        raise AssertionError('type-ahead typed during a command never '
                             'reached the next prompt\n'
                             + '\n'.join(rows(t)))
    keys(t, 'CD')                       # raw arrival, the editor's
    t.enter()
    t.wait_prompt('typeahead line')
    need(bare(t, 'ABCD') == 1,
         'type-ahead typed during a command (cooked) + typed at the '
         'prompt (raw) did not run as one line `echo ABCD` -- once', t)
    # a burst at the prompt: 12 keys land faster than the editor paints
    t.c.call_tool('type', {'text': 'echo 123456\r'})
    t.wait_prompt('burst')
    need(bare(t, '123456') == 1, 'a burst at the prompt lost or '
         'doubled a byte', t)


def width(t):
    return {'text40': 40}.get(t.backend, 80)


def intr_wrapped(t, nx, back, label, tag):
    """A line of `nx` X after `echo `, cursor `back` keys right of
    the start (^A then ^F * back) -- mid-line -- then ^C."""
    keys(t, 'echo ' + 'X' * nx)
    t.press(CTRL['A'])
    for _ in range(back):
        t.press(CTRL['F'])
    settle(t, 4)
    t.press(CTRL['C'])
    t.wait_prompt(label)
    r = rows(t)
    need(r[-1] == '$', f'{label}: no clean prompt after ^C', t)
    need(not any(set(x) == {'X'} and len(x) > nx - 1 and 'echo' in x
                 for x in r), f'{label}: the abandoned line RAN', t)
    # the prompt is below the WHOLE line: the line's last row is the
    # row directly above it, intact
    xs = [i for i, x in enumerate(r) if x.endswith('X')]
    need(xs and xs[-1] == len(r) - 2,
         f'{label}: the prompt did not land below the whole wrapped '
         f'line', t)
    need(any('^C' in x for x in r), f'{label}: no ^C on the glass', t)
    n = sum(x.count('X') for x in r)
    need(n >= nx - 2, f'{label}: the line lost more than the two '
         f'cells the kernel\'s ^C paints over ({n} of {nx} X)', t)
    run_line(t, 'echo alive' + tag, label + ' alive')
    need(bare(t, 'alive' + tag) == 1,
         f'{label}: shell did not survive ^C', t)


def case_intr_mid(t):
    t.wait_prompt('ready')
    w = width(t)
    intr_wrapped(t, w + 5, 3, 'two rows, cursor on row 0', 'a')
    intr_wrapped(t, 2 * w, 3, 'three rows, cursor on row 0', 'b')
    intr_wrapped(t, w + 5, w - 2, 'two rows, cursor on row 1', 'c')


def case_stop(t):
    t.wait_prompt('ready')
    keys(t, 'echo zed')
    t.press(CTRL['Z'])
    t.wait_prompt('after ^Z')
    need(bare(t, 'zed') == 0, 'the ^Z-abandoned line RAN', t)
    run_line(t, 'echo alive', 'alive')
    need(bare(t, 'alive') == 1, 'the login shell was STOPPED by ^Z '
         '(TSTP left at default around the read)', t)


def case_eof(t):
    t.wait_prompt('ready')
    run_line(t, 'X=parent', 'set')
    run_line(t, 'sh', 'nested sh')          # an interactive child
    settle(t, 12)
    t.press(CTRL['D'])                      # empty line: it exits
    settle(t, 20)
    run_line(t, 'echo $X', 'back in the parent')
    need(bare(t, 'parent') == 1, '^D on an empty line did not leave the '
         'nested shell (or the parent was lost)', t)
    # non-empty line: delete forward
    keys(t, 'echo ab')
    t.press(CTRL['A'])
    for _ in range(6):
        t.press(CTRL['F'])
    t.press(CTRL['D'])                      # deletes the b
    t.enter()
    t.wait_prompt('after ^D delete')
    need(bare(t, 'a') == 1, '^D on a non-empty line did not delete '
         'forward', t)


def case_switch(t):
    t.wait_prompt('ready')
    run_line(t, 'chvt 2', 'console 2')     # lands on console 2
    settle(t, 30)
    t.c.call_tool('buttons', {'closed_apple': True})     # Option
    t.c.call_tool('type', {'text': '1'})
    settle(t, 10)
    t.c.call_tool('buttons', {'closed_apple': False})
    settle(t, 20)
    need(any('chvt 2' in r for r in rows(t)),
         'Option-1 did not bring console 1 back', t)
    keys(t, 'echo sw')                      # a line in progress
    for hop in ('2', '1'):
        t.c.call_tool('buttons', {'closed_apple': True})
        t.c.call_tool('type', {'text': hop})
        settle(t, 10)
        t.c.call_tool('buttons', {'closed_apple': False})
        settle(t, 20)
    need(any(r.endswith('echo sw') for r in rows(t)),
         'the half-typed line is gone after Option-2 / Option-1', t)
    need(tmode(t) == TM_RAW, 'console 1 lost its raw mode across the '
         f'switch (VC_TMODE ${tmode(t):02X})', t)
    keys(t, 'ok')
    t.enter()
    t.wait_prompt('after the switch')
    need(bare(t, 'swok') == 1, 'the line typed across a console switch '
         'did not run as one', t)


def ttymode_calls(t, cycles):
    """SYS_TTYMODE calls in the next `cycles`: hits on TTY_TMODE_STO,
    the one routine every mode change ends in (SYS_TTYMODE and the
    kill backstop alike), re-armed after each (until_pc stops at the
    first)."""
    pc = _read_symbol(SYMS, 'TTY_TMODE_STO')
    n = 0
    left = cycles
    while left > 0:
        r = t.c.call_tool('until_pc', {'pc': pc, 'max_cycles': left})
        if not r.get('hit'):
            break
        n += 1
        left -= r.get('elapsed', 1) or 1
        t.c.call_tool('step', {'cycles': 1})
    return n


def case_noraw(t):
    t.wait_prompt('ready')
    # a script and a `sh < file` that each take a few seconds
    run_line(t, 'echo "sleep 5" > /tmp/S', 'make script')
    for cmd in ('sh /tmp/S', 'sh < /tmp/S'):
        keys(t, cmd)
        t.enter()
        settle(t, 3)                        # past the editor's own exit
        n = ttymode_calls(t, 1_500_000)
        need(n == 0,
             f'`{cmd}` made {n} SYS_TTYMODE call(s) while it ran -- a '
             f'script and `sh < file` must never enter raw mode', t)
        need(not last_is_prompt(t), f'`{cmd}` was already over', t)
        t.wait_prompt(cmd + ' done', timeout_slices=300)
    # the editor itself IS counted: the same window around a line
    keys(t, 'echo y')
    n = ttymode_calls(t, 100_000)
    t.c.call_tool('type', {'text': '\r'})   # no slice: count from Return
    n += ttymode_calls(t, 400_000)
    need(n >= 1, 'the counter is blind: a line at the prompt made no '
         'SYS_TTYMODE call', t)
    t.wait_prompt('counter line')


def case_hist(t):
    t.wait_prompt('ready')
    # a nested sh starts empty -- even the SECOND one, which lazy free
    # runs in the first one's retained bank (BSS and language card
    # intact): the history is established at START, not inherited
    run_line(t, 'echo H1', 'H1')
    banks = []
    for n in ('N1', 'N2'):
        run_line(t, 'sh', 'nested ' + n)
        settle(t, 12)
        t.press(CTRL['P'])                  # nothing to recall
        t.enter()
        settle(t, 6)
        need(bare(t, 'H1') == 1 and bare(t, 'N1') == (n == 'N2'),
             f'nested sh {n} started with a history (^P recalled a '
             f'line from the parent or from the shell before it)', t)
        # the pid goes in FIRST: the newest history entry must stay
        # `echo N`, the one a stale ring would recall and re-run
        banks.append(shell_pid(t))          # a pid IS its bank
        run_line(t, 'echo ' + n, n)
        need(bare(t, n) == 1, f'nested sh {n} did not run its line', t)
        t.press(CTRL['D'])
        settle(t, 20)
    # SH-ROOM2: the row above is only a WARM-history row if N2 ran in
    # N1's retained bank, where the ring (dead-copy storage since
    # SH-ROOM2) and ED_HN still hold N1's entries. Prove it, so the row
    # cannot go vacuous if a spawn ever stops reusing the bank; the
    # tooth is scripts/teeth_shdead.py H1 (ED_INIT stops clearing
    # ED_HN/ED_HUSED -> this case is red).
    need(len(banks) == 2 and banks[0] == banks[1],
         f'N2 did not run in N1\'s bank (pids {banks}): the warm history '
         f'row would prove nothing', t)
    t.press(CTRL['P'])                      # the parent's newest: `sh`
    settle(t, 4)
    need(any(r.endswith('$ sh') for r in rows(t)[-2:]),
         'the parent\'s history was lost or polluted by the child', t)
    t.press(CTRL['C'])
    t.wait_prompt('abandon')
    # eight entries, the ninth drops the oldest; walk + stash
    for i in range(1, 10):
        run_line(t, f'echo c{i}', f'c{i}')
    keys(t, 'zz')                           # the line in progress
    for _ in range(8):
        t.press(CTRL['P'])
    settle(t, 3)
    need(rows(t)[-1].endswith('$ echo c2'),
         'after 8 ^P the oldest kept entry is not `echo c2`', t)
    t.press(CTRL['P'])                      # at the oldest: stays
    settle(t, 3)
    need(rows(t)[-1].endswith('$ echo c2'), 'the 9th ^P left c2', t)
    for _ in range(8):
        t.press(CTRL['N'])
    settle(t, 3)
    need(rows(t)[-1].endswith('$ zz'),
         '^N past the newest did not restore the line in progress', t)
    t.press(CTRL['C'])
    t.wait_prompt('abandon 2')
    # a respawned login shell (warm bank, LC retained) starts empty
    run_line(t, 'echo W1', 'W1')
    t.press(CTRL['D'])                      # the login shell exits
    settle(t, 40)
    t.wait_prompt('respawned shell')
    t.press(CTRL['P'])
    t.enter()
    settle(t, 6)
    need(bare(t, 'W1') == 1, 'the respawned shell recalled the dead '
         "shell's history (the warm LC ring was not cleared)", t)


def case_histcap(t):
    """The ring holds 512 bytes (ED_HSIZE): three 127-character lines
    (128 B each with their length byte) all fit, so the third ^P back
    reaches the OLDEST. A 256-byte ring keeps two, evicts the first on
    the third add, and the third ^P stays on the second line. SH-ROOM2
    (review L1): the ring's size is pinned statically in
    check-modules, and this is the behavioural twin that can tell 256
    from 512. The lines are comments, so they run as no-ops."""
    t.wait_prompt('ready')
    for n in '123':
        run_line(t, '#' + n + 'x' * 125, 'long ' + n)
    for _ in range(3):
        t.press(CTRL['P'])
    settle(t, 6)
    # the typed lines are still on the glass above: judge the LAST
    # prompt row, the one being edited
    last = [x for x in rows(t) if x.startswith('$ ')][-1]
    need(last.startswith('$ #1x'),
         'after three ^P over three 127-character lines the oldest line '
         f'is not recalled ({last[:6]!r}): the history ring holds fewer '
         'than 512 bytes', t)
    t.press(CTRL['C'])
    t.wait_prompt('abandon')


def case_trap_int(t):
    t.wait_prompt('ready')
    run_line(t, "trap 'echo TRAPPED' INT", 'trap')
    keys(t, 'echo gone')
    t.press(CTRL['C'])
    t.wait_prompt('after ^C')
    need(bare(t, 'TRAPPED') == 1, 'the INT trap did not fire on ^C at '
         'the idle prompt', t)
    need(bare(t, 'gone') == 0, 'the interrupted line ran', t)
    run_line(t, 'echo alive', 'alive')
    need(bare(t, 'alive') == 1, 'shell lost after the trap', t)


def ps_states(t):
    """{pid: (state, ppid)} from a fresh `ps` on a cleared screen."""
    t.press(CTRL['L'])
    settle(t, 6)
    run_line(t, 'ps', 'ps')
    d = {}
    for r in rows(t):
        m = re.match(r'^\s*(\d+) ([A-Z]) +[0-9A-F]+\s+(\d+)(?: .*)?$', r)
        if m:
            d[int(m.group(1))] = (m.group(2), int(m.group(3)))
    need(d, 'ps printed no process rows', t)
    return d


# job_contract's background job must still be running after three `ps`
# runs, two ^C/^Z lines and a `jobs`: ~25M guest cycles of harness (+3M
# under MAUX_GATE_RACE=late). 120 s is ~122M.
BG_SLEEP = 120


def job_contract(t, bg, stopped):
    """^C and ^Z at the idle prompt reach the shell and ONLY the shell.
    Each job pid keeps its state, read from the PCB table (ps): a
    pid that is gone, zombied or changed is a victim. `bg`: a running
    `sleep 120 &`; `stopped`: a stopped pipeline one of whose stages
    ignores TSTP (the review's repro4 shape, where the old sweep killed
    the stage that was not itself stopped)."""
    t.wait_prompt('ready')
    if bg:
        run_line(t, f'sleep {BG_SLEEP} &', 'bg')
    if stopped:
        run_line(t, "echo \"trap '' 14\" > /tmp/T", 'w1')
        run_line(t, 'echo "sleep 100" >> /tmp/T', 'w2')
        before = set(pcb_states(t))
        keys(t, 'sh /tmp/T | cat')
        t.enter()
        # Barrier 1, raised by the guest: the stage that ignores TSTP has
        # run its `trap '' 14` and started `sleep 100` (sh /tmp/T, cat and
        # sleep are live). A fixed settle here let ^Z land BEFORE the trap
        # on a slower shell, stopped both stages, and the row stopped
        # testing what it was written for (HYG-4 notes 10.2).
        wait_pcb(t, lambda st: len(new_pids(st, before)) >= 3,
                 'the pipeline never reached the sleep of the stage that '
                 'ignores TSTP', before)
        t.press(CTRL['Z'])
        # Barrier 2: cat is STOPPED and the other two stages are not.
        wait_pcb(t, lambda st: (
            list(new_pids(st, before).values()).count(ST_STOPPED) == 1 and
            list(new_pids(st, before).values()).count(ST_BLOCKED) >= 2),
            '^Z never left cat STOPPED with the TSTP-ignoring stage and '
            'its sleep still BLOCKED', before)
        # The PCB state is ahead of the glass: the shell prints
        # `[2]+ Stopped ... cat` and then its prompt, and the UltraTerm
        # paints that line late (box sweep 73982754: the screen read
        # `[2]+` and nothing else). Read the row once the prompt is back.
        t.wait_prompt('after the job stopped')
        need(any('Stopped' in r and 'cat' in r for r in rows(t)),
             'the pipeline did not stop on ^Z', t)
    # two ps runs: the one process that exits between them is ps
    # itself (it takes the same slot each time, so a pid present in
    # both is a JOB pid, and one that vanishes later was killed)
    b1, b2 = ps_states(t), ps_states(t)
    jobs = {p: v for p, v in b1.items() if b2.get(p) == v}
    if stopped:
        need('T' in [v[0] for v in jobs.values()],
             f'no stopped (T) process before: {b1} / {b2}', t)
    need(jobs, f'no job pid survived two ps runs: {b1} / {b2}', t)
    for what, key in (('^C', CTRL['C']), ('^Z', CTRL['Z'])):
        keys(t, 'echo gone')
        t.press(key)
        t.wait_prompt('after ' + what)
        need(bare(t, 'gone') == 0, f'the {what}-abandoned line RAN', t)
    after = ps_states(t)
    for pid, (st, ppid) in jobs.items():
        need(pid in after, f'pid {pid} ({st}) is GONE after ^C / ^Z at '
             f'the idle prompt (killed and reaped -- or its `sleep '
             f'{BG_SLEEP}` ran out: raise BG_SLEEP): jobs={jobs} '
             f'after={after}', t)
        need(after[pid][0] != 'Z',
             f'pid {pid} ({st}) was KILLED by ^C / ^Z at the idle '
             f'prompt: before={jobs} after={after}', t)
        if st == 'T':
            need(after[pid][0] == 'T',
                 f'stopped pid {pid} changed state ({after[pid][0]}) '
                 f'by ^C / ^Z at the idle prompt: {after}', t)
    need(not any(v[0] == 'Z' for v in after.values()),
         f'a zombie appeared after ^C / ^Z at the idle prompt: {after}',
         t)
    run_line(t, 'jobs', 'jobs')
    if bg:
        need(any('Running' in r and f'sleep {BG_SLEEP}' in r for r in rows(t)),
             'the & job is not Running after ^C / ^Z at the prompt', t)
    if stopped:
        need(any('Stopped' in r for r in rows(t)),
             'the stopped job is not Stopped after ^C / ^Z at the '
             'prompt', t)
    run_line(t, 'echo alive', 'alive')
    need(bare(t, 'alive') == 1, 'shell lost', t)


def case_bgjob(t):
    job_contract(t, True, True)


def case_stopjob(t):
    job_contract(t, False, True)


def case_esc_cr(t):
    t.wait_prompt('ready')
    keys(t, 'echo a' + ESC + '[')
    t.enter()                    # swallowed by the half-typed escape
    settle(t, 10)
    need(tmode(t) == TM_RAW, 'ESC [ Return left the console in mode '
         f'${tmode(t):02X}, not raw: the editor went cooked with the '
         'line still open', t)
    keys(t, 'bc')
    settle(t, 6)
    need(rows(t)[-1] == '$ echo abc', 'the line is not still open: '
         f'{rows(t)[-1]!r}', t)
    t.enter()
    t.wait_prompt('run')
    need(bare(t, 'abc') == 1, 'the line did not run once, as typed', t)


def case_clear(t):
    t.wait_prompt('ready')
    keys(t, 'printf MARK')
    t.enter()
    wait_dollar(t, 'unterminated')
    need(rows(t)[-1] == 'MARK$', 'no MARK before the prompt', t)
    keys(t, 'echo hi')
    t.press(CTRL['L'])
    settle(t, 10)
    r = rows(t)
    need(r == ['$ echo hi'], 'after ^L the screen is not just the prompt '
         f'and the line at the top (output before the prompt is not '
         f'replayed): {r}', t)
    t.enter()
    t.wait_prompt('run')
    need(bare(t, 'hi') == 1, 'the line did not run after ^L', t)


def case_cap(t):
    t.wait_prompt('ready')
    t.c.call_tool('type', {'text': 'echo ' + 'A' * 130 + '\r'})
    # The bulk type is not acknowledged: until the guest has echoed the
    # first keys the glass still shows the PREVIOUS bare prompt, and
    # wait_prompt's two-poll settle is satisfied by it (MAUX_GATE_RACE=
    # early found this: 0 A on the glass; learning 01M3KY2AS0XJ22DY89S7R728GC).
    t.wait('AAAAAAAA', 'the long line starting to echo')
    t.wait_prompt('long line')
    # 127 characters = `echo ` + 122 A; they show twice (the echoed
    # line and echo's output): 244 A on the glass, not 260
    rs = rows(t)
    top = next((i for i, r in enumerate(rs) if 'echo AAAA' in r), 0)
    n = sum(r.count('A') for r in rs[top:])   # not the boot splash's 'A'
    need(n == 244, f'the line is not capped at 127 characters '
         f'({n} A on the glass, want 244)', t)


def case_column(t):
    t.wait_prompt('ready')
    keys(t, 'printf abc')
    t.enter()
    wait_dollar(t, 'unterminated')
    need(rows(t)[-1] == 'abc$', 'the prompt does not follow unterminated '
         f'output on its own row: {rows(t)[-1]!r}', t)
    keys(t, 'echo xy')
    settle(t, 3)
    need('abc$ echo xy' in rows(t), 'the typed text is not on the '
         "prompt's row (the prompt moved)", t)
    t.press(CTRL['B'])
    keys(t, 'Z')
    t.enter()
    t.wait_prompt('edit')
    need(bare(t, 'xZy') == 1, 'a short edit after unterminated output '
         'went wrong', t)



def shell_pid(t):
    run_line(t, 'echo $$', 'pid')
    ns = [int(r) for r in rows(t) if r.isdigit()]
    need(ns, 'no pid printed by echo $$', t)
    return ns[-1]


def pcb_state(t, pid):
    r = t.c.call_tool('peek', {'addr': 0x0800 + pid * 16 + 1, 'count': 1,
                               'bank': 'aux', 'aux_bank': 0})
    return (r.get('bytes') or r.get('data'))[0]


# The killer's delay (seconds) for every case below. The TERM must land
# in the shell's raw read WITH the line typed, so the timer must outlast
# the harness: ~0.7M typing `echo ab` key by key plus the prompt waits,
# and MAUX_GATE_RACE=late adds 3M after the arming line; the guest starts
# the killer's sleep ~1.4M after that line. 8 s is ~9.6M: >5M of margin.
KILL_AFTER = 8


ST_BLOCKED, ST_ZOMBIE, ST_STOPPED = 3, 4, 5


def pcb_states(t):
    """{pid: PCB state byte} for every pid whose PCB is in use."""
    r = t.c.call_tool('peek', {'addr': 0x0800, 'count': 48 * 16,
                               'bank': 'aux', 'aux_bank': 0})
    tbl = r.get('bytes') or r.get('data')
    return {p: tbl[p * 16 + 1] for p in range(1, 48) if tbl[p * 16 + 1]}


def new_pids(st, before):
    return {p: s for p, s in st.items() if p not in before}


def wait_pcb(t, pred, why, before, limit=3000):
    """Poll the PCB table (bounded, pace-independent) until `pred` holds;
    fail naming the cause and the table if it never does."""
    st = {}
    for _ in range(GR.count(limit, 8000)):
        st = pcb_states(t)
        if pred(st):
            return st
        t._slice(GR.quantum(8000))
    raise AssertionError(f'{why}; new pids {new_pids(st, before)}\n'
                         + '\n'.join(rows(t)))


def live_pids(t):
    """Pids whose PCB is neither UNUSED (0) nor ZOMBIE (4)."""
    r = t.c.call_tool('peek', {'addr': 0x0800, 'count': 48 * 16,
                               'bank': 'aux', 'aux_bank': 0})
    tbl = r.get('bytes') or r.get('data')
    return {p for p in range(1, 48) if tbl[p * 16 + 1] not in (0, 4)}


def arm_killer(t, cmd, label):
    """run_line(`cmd`) and return the pids it left behind: the pending
    killer. The subshell stays alive until its `kill` has been delivered
    (it is a live PCB the whole time), so 'the killer has not fired yet'
    is a property the harness can read, not a duration it must guess."""
    before = live_pids(t)
    run_line(t, cmd, label)
    mine = live_pids(t) - before
    need(mine, f'{label}: the overlap did not happen: the killer already '
         'fired (it is not in the PCB table) before its own prompt was '
         'back (guest faster than the harness pace, or the harness late; '
         'raise KILL_AFTER)', t)
    return mine


def killer_pending(t, mine, when, label):
    need(mine & live_pids(t), f'{label}: the overlap did not happen: the '
         f'killer already fired {when} (guest faster than the harness '
         'pace, or the harness late; raise KILL_AFTER)', t)


def wait_killer_fired(t, mine, label, limit=2000):
    """Until the killer's `kill` has been delivered: its subshell exits
    right after. Then a short bounded settle for the TERM's effect."""
    for _ in range(GR.count(limit, 8000)):
        if not (mine & live_pids(t)):
            settle(t, 12)
            return
        t._slice(GR.quantum(8000))
    raise AssertionError(f'{label}: the killer never fired (pids '
                         f'{sorted(mine)} still live)\n' + '\n'.join(rows(t)))


def case_term(t):
    t.wait_prompt('ready')
    pid = shell_pid(t)
    killer = arm_killer(t, f'( sleep {KILL_AFTER} ; kill {pid} ) &', 'arm')
    keys(t, 'echo ab')
    killer_pending(t, killer, 'before the line was typed', 'term')
    wait_killer_fired(t, killer, 'term')  # the TERM lands in the raw read
    need(tmode(t) == TM_RAW, 'a TERM at the raw prompt left the console '
         f'in mode ${tmode(t):02X}, not raw: the line was abandoned', t)
    need(rows(t)[-1] == '$ echo ab', 'a TERM at the prompt disturbed the '
         f'line: {rows(t)[-1]!r}', t)
    keys(t, 'cd')
    t.enter()
    t.wait_prompt('run')
    need(bare(t, 'abcd') == 1, 'the line a TERM interrupted did not run '
         'once, as typed', t)
    run_line(t, 'echo $$', 'same shell')
    need(bare(t, str(pid)) == 2, f'the shell is not pid {pid} any more '
         '(a TERM ended it and init respawned it)', t)


def case_termtrap(t):
    """A TRAPPED TERM in the raw read: with a line typed it waits for
    the line (the trap runs after it, once); inside a construct (a
    `> ` prompt) it waits too, whatever the line (review T2, T4)."""
    t.wait_prompt('ready')
    pid = shell_pid(t)
    run_line(t, "trap 'echo T' 15", 'trap')
    killer = arm_killer(t, f'( sleep {KILL_AFTER} ; kill {pid} ) &', 'arm')
    keys(t, 'echo ab')
    killer_pending(t, killer, 'before the line was typed', 'termtrap')
    wait_killer_fired(t, killer, 'termtrap')  # the TERM lands in the raw read
    need(tmode(t) == TM_RAW, 'a trapped TERM left the console in mode '
         f'${tmode(t):02X}: the typed line was interrupted', t)
    need(rows(t)[-1] == '$ echo ab', 'a trapped TERM disturbed the typed '
         f'line: {rows(t)[-1]!r}', t)
    need(bare(t, 'T') == 0, 'the trap ran over a typed line', t)
    t.enter()
    t.wait_prompt('run')
    r = rows(t)
    need(bare(t, 'ab') == 1, 'the typed line did not run once', t)
    need(bare(t, 'T') == 1, 'the trap did not run exactly once after '
         f'the line: {r}', t)
    need(r.index('ab') < r.index('T'), 'the trap ran BEFORE the line it '
         f'waited for: {r}', t)
    # inside an open construct (an `if`: CSPTR != 0; a console LOOP is
    # spooled with CSPTR 0 and ends the read like the kernel path does)
    # a longer fuse: the header takes longer to type than `echo ab`
    killer = arm_killer(t, f'( sleep {KILL_AFTER} ; kill {pid} ) &', 'arm2')
    keys(t, 'if true; then')          # CSPTR != 0 from here on
    t.enter()
    settle(t, 10)
    n0 = sum(x.count('$') + x.count('>') for x in rows(t))
    need(rows(t)[-1] in ('$', '>'), 'no prompt after `if true; then`', t)
    killer_pending(t, killer, 'before the construct was open', 'termtrap')
    wait_killer_fired(t, killer, 'termtrap construct')
    n1 = sum(x.count('$') + x.count('>') for x in rows(t))
    need(n1 == n0, 'a trapped TERM at a prompt inside a construct ended '
         f'the read: the shell re-prompted ({n0} -> {n1} prompts)', t)
    need(bare(t, 'T') == 1, 'the trap ran inside an open construct', t)
    keys(t, 'echo in')
    t.enter()
    keys(t, 'fi')
    t.enter()
    t.wait_prompt('construct done')
    need(bare(t, 'in') == 1, 'the construct did not run', t)
    need(bare(t, 'T') == 2, 'the trap did not run once after the '
         'construct', t)


def case_kill9(t):
    t.wait_prompt('ready')
    pid = shell_pid(t)
    killer = arm_killer(t, f'( sleep {KILL_AFTER} ; kill -9 {pid} ) &', 'arm')
    keys(t, 'echo zz')
    need(tmode(t) == TM_RAW, 'not raw before the kill', t)
    killer_pending(t, killer, 'before the shell was in its raw read',
                   'kill9')
    for _ in range(GR.count(3000, 8000)):
        t._slice(GR.quantum(8000))
        if pcb_state(t, pid) in (0, 4):         # UNUSED / ZOMBIE
            break
    else:
        raise AssertionError('the shell never died')
    # THE END STATE, NOT THE FIRST SIGN OF DEATH (learning
    # 01M1AH9XWGC8ZS7HNBJVJ2JHXW: a predicate must name the operation's
    # end state). The loop above leaves on the first poll that sees the
    # PCB UNUSED/ZOMBIE; the console reset runs a little LATER in the
    # same kill, so a read taken at once lands before it or after it by
    # the phase of the 8000-cycle slice -- a function of the sh image
    # size, which is why base passed, +40 B failed, +90 B passed and
    # +143 B failed on the box. Give the reset a bounded window to
    # appear -- 8 slices (16,000 cycles), against the 0-1 observed with
    # the reset in place and the ~86 it takes the SUCCESSOR shell's own
    # startup to cook the console with PRC_TMD_RST sabotaged (a wider
    # window would let that mask the defect; measured, see KFIX10-NOTES).
    extra = 0
    m = tmode(t)
    while m != TM_COOKED and extra < 8:
        t._slice(2000)
        extra += 1
        m = tmode(t)
    if m == TM_COOKED:
        print(f'kill9: console cooked after {extra} extra 2000-cycle '
              f'slice(s)')
    need(m == TM_COOKED, f'the shell died in the raw read and the console '
         f'was left in mode ${m:02X} for {extra * 2000} cycles, not '
         f'cooked+echo (PRC_TMD_RST did not run: the shell must be in its '
         f'own SELF foreground set)', t)
    wait_dollar(t, 'successor shell')
    run_line(t, 'echo alive', 'alive')
    need(bare(t, 'alive') == 1, 'the successor shell does not work', t)


# Each script is typed after a clear screen and ends in Return. Several
# need history from the ones before, so the order is part of the
# script. W is the console's columns.
def parity_scripts(w):
    q = 'Q' * (w - 5)
    n = w + 5                            # a line that wraps once
    boundary = 'X' * (w - 7)              # 'echo ' + this ends col w-1
    return [
        ('del_end', 'echo abcd' + DEL + DEL + 'X'),
        ('left_arrow_ins', 'echo ORLD' + LEFT * 4 + 'W'),
        ('right_arrow', 'echo abc' + LEFT * 2 + RIGHT + 'X'),
        ('home_end', 'cho xy' + CTRL['A'] + 'e' + CTRL['E'] + 'z'),
        ('ctrl_b_f', 'echo abcd' + CTRL['B'] * 3 + CTRL['F'] + 'Q'),
        ('word_fb', 'echo one two three' + ESC + 'b' + ESC + 'b' + 'X'
         + ESC + 'f' + 'Y'),
        ('word_upper', 'echo AB CD' + ESC + 'B' + 'x' + ESC + 'F' + 'y'),
        ('kill_m_k', 'echo AB JUNK' + ESC + 'b' + ESC + 'k'),
        ('kill_opt_k', 'echo AB CD' + CTRL['B'] * 3 + '<OPT:k>'),
        ('kill_opt_u', 'echo foo' + '<OPT:u>' + 'echo bar'),
        ('del_mid', 'echo QCD' + CTRL['B'] * 2 + DEL),
        ('hist_p', 'echo H1'),
        ('hist_p2', 'echo H2'),
        ('hist_ctrl_p', CTRL['P']),
        ('hist_up2', UP + UP),
        ('hist_up_down', UP + UP + DOWN),
        ('hist_edit', UP + UP + UP + CTRL['E'] + '99'),
        ('hist_stash', 'echo ST' + UP + UP + DOWN + DOWN + 'Z'),
        ('hist_deep', UP * 12),
        ('wrap_ctrl_a', 'cho ' + q + 'Z' + CTRL['A'] + 'e'),
        ('wrap_bs_across', 'echo ' + 'W' * n + DEL * 8 + 'v'),
        ('wrap_left_across', 'echo ' + 'W' * n + CTRL['B'] * 12 + 'v'),
        ('wrap_kill', 'echo ' + 'W' * n + CTRL['A'] + CTRL['F'] * 8
         + '<OPT:k>'),
        ('exact_boundary', 'echo ' + boundary + DEL + DEL + 'YY'),
        ('exact_boundary_ins', 'echo ' + boundary + CTRL['A']
         + CTRL['F'] * 5 + 'II'),
        # lines that genuinely CROSS the glass's row boundary at this
        # width (the shapes above are 40-column ones: at 80 columns
        # they never wrap). The boundary is index w-2 (the prompt is
        # two cells): these end 4 cells into row 1.
        ('wrapx_bs', 'echo ' + 'W' * (w - 3) + DEL * 8 + 'v'),
        ('wrapx_left', 'echo ' + 'W' * (w - 3) + CTRL['B'] * 12 + 'v'),
        ('wrapx_kill', 'echo ' + 'W' * (w - 3) + CTRL['A']
         + CTRL['F'] * 8 + '<OPT:k>'),
        ('wrapx_ins', 'echo ' + 'W' * (w - 8) + CTRL['A']
         + CTRL['F'] * 3 + 'II'),
        ('wrapx_home_end', 'echo ' + 'W' * (w - 3) + CTRL['A']
         + CTRL['E'] + 'z'),
        ('esc_unbound', 'echo a' + ESC + 'x' + 'b'),
        ('esc_esc', 'echo a' + ESC + ESC + 'b'),
        ('tab_dropped', 'echo a\\x09b'),
        ('ctrl_dropped', 'echo a\\x07b'),
        ('right_at_end', 'echo ab' + RIGHT + RIGHT + 'c'),
        ('left_at_start', 'echo ab' + CTRL['A'] + LEFT + 'X'),
    ]


def run_parity(t, scripts):
    out = []
    for name, seq in scripts:
        t.press(CTRL['L'])
        settle(t, 6)
        keys(t, seq)
        t.enter()
        settle(t, 14)
        out.append((name, rows(t)))
    return out


def case_parity(t):
    t.wait_prompt('ready')
    w = width(t)
    scripts = parity_scripts(w)
    mine = run_parity(t, scripts)
    t.press(CTRL['L'])
    settle(t, 6)
    keys(t, 'sh -E')
    t.enter()
    t.wait_prompt('kernel-editor shell')
    theirs = run_parity(t, scripts)
    bad = []
    for (name, a), (_, b) in zip(mine, theirs):
        if a != b:
            bad.append(f'--- {name}: userland / kernel\n'
                       + '\n'.join(f'  {x!r}' for x in a)
                       + '\n  ---\n'
                       + '\n'.join(f'  {x!r}' for x in b))
    need(not bad, 'the userland editor and the kernel editor disagree '
         f'({len(bad)} of {len(scripts)} scripts):\n' + '\n'.join(bad))


CASES = [
    ('modes', case_modes),
    ('typeahead', case_typeahead),
    ('intr_mid', case_intr_mid),
    ('stop', case_stop),
    ('eof', case_eof),
    ('switch', case_switch),
    ('noraw', case_noraw),
    ('hist', case_hist),
    ('histcap', case_histcap),
    ('trap_int', case_trap_int),
    ('bgjob', case_bgjob),
    ('stopjob', case_stopjob),
    ('esc_cr', case_esc_cr),
    ('clear', case_clear),
    ('term', case_term),
    ('termtrap', case_termtrap),
    ('kill9', case_kill9),
    ('cap', case_cap),
    ('column', case_column),
    ('parity', case_parity),
]


def main():
    args = sys.argv[1:]
    which = args[0] if args else 'all'
    backs = ['text40', 'text80', 'ut'] if which == 'all' else [which]
    names = args[1:]
    bad = 0
    for b in backs:
        for name, fn in CASES:
            if names and name not in names:
                continue
            ok, err = E.session(b, fn)
            print(('PASS' if ok else 'FAIL'), f'shedit {name} [{b}]')
            if not ok:
                print(err)
                bad += 1
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
