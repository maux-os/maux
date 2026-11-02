#!/usr/bin/env python3
"""check_vi_bang.py -- vi through a SHELL-OUT (`make check-vi-bang`, in
check-all-cross).

Nothing else drives vi through `!`. Found 2026-09-07 by a human: every
`:!cmd` / `:%!filter` wedged the editor. The cause was not the spawn at
all -- ED_DISPATCH1's `jsr EX_CMD` leaves its return address on the
stack for every EX_CMD-recognized verb (they all end `jmp MAINLOOP`,
never `rts`), harmless for ed/ex (jmp-only top level) but fatal for
vi's `jmp (ED_D1RET)` bridge: VI_REPAINT's `rts` popped the leaked
address, re-entered the dispatcher, and the second `jmp MAINLOOP` fell
into ED_RDCMDLINE's fd-0 read on the raw console, eating every key.
The fix pins S in the bridge (VI_D1SP, vicmd.s), wraps the child in a
cooked console (EX_ONSPAWN/EX_ONSPAWNED, real in vi, no-op in ex), and
keeps glass output readable: any command that writes to the console
(ED_PUTLINE's p/nu/#/=/l, `:!cmd`'s child) marks ED_GLASSOUT and the
`:` landing shows real vi's "[Hit return to continue]" before it
repaints -- so check_vi's `:nu` case, which used to pass only BECAUSE
vi wedged with the print still on the glass, keeps passing honestly.

Cases, each against the REAL kernel + shell on the fast backend:

  bang     `:!echo HI` -- the child's output is VISIBLE (cooked tty
           around the child + real vi's "[Hit return to continue]"),
           RETURN repaints, vi is ALIVE (`1Gx` edits, `:q!` returns to
           the shell).
  filter   `:%!sort` -- the buffer is sorted on the glass and vi is
           alive afterward.
  killed   a vi KILLED mid-session (SIGTERM from a background killer
           armed at the shell) leaves the console cooked+echo -- the
           kernel's PRC_TMD_RST backstop, proven the way check_reset
           proves `reset`: a following `echo BBB` both echoes and runs.

Teeth: bang and filter went RED on the unfixed tree (da420aa) -- vi
wedged at `:!`; the killed case pins the backstop (green before and
after -- the kill path already restored the mode, the brief's "second
gap" did not reproduce).

  pipe_nospace   at the SHELL: `echo HELLO|cat` (no blanks) pipes --
                 the glass shows HELLO, not the literal HELLO|cat;
                 `echo 'a|b'` still prints a|b (quoting gates the
                 split); `echo X||echo Y` prints X alone (`||` stays
                 ONE operator, never shattered into two pipes).
  filter_nospace `:%!sort|uniq` (no blanks) -- the buffer is the
                 sorted, DEDUPED fruit list (6 lines, then `~`), vi
                 alive. docs/SH-PIPE-NOSPACE.md: `sh` used to lex
                 `sort|uniq` as ONE word ("command not found"), so the
                 filter's capture came back empty and ex DELETED the
                 range -- the buffer vanished.

Teeth: pipe_nospace and filter_nospace went RED on 70a49f1 (the
unfixed lexer: HELLO|cat printed literally, `:%!sort|uniq` emptied the
buffer); the quoted `a|b` sub-case is the over-split guard and stays
green both sides.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_vi as V                                    # noqa: E402
import gate_race as GR                                  # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR    # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# A WELL-FORMED job-control notice, `[1]+ Done ...` / `[2]- ...` /
# `[1] 4`. Used by case_killed_midcsi to step past a notice that the
# reprompt race may or may not have printed yet; the leading `[` is
# load-bearing (see that case's docstring).
JOB_NOTICE = re.compile(r'^\[\d+\][-+ ]')
ESC = V.ESC
FRUIT = ['PEAR', 'APPLE', 'MANGO', 'APPLE', 'FIG', 'CHERRY', 'BANANA',
         'FIG']
SORTED = sorted(FRUIT)
UNIQ = sorted(set(FRUIT))          # APPLE BANANA CHERRY FIG MANGO PEAR


def step(c, n):
    for _ in range(n):
        c.call_tool('step', {'cycles': 200_000})


def nonblank(rs):
    return [r.rstrip() for r in rs if r.strip()]


def has_row(rs, text):
    return any(r.strip() == text for r in rs)


def vi_bank(c):
    """vi's physical aux bank, by image signature at LOAD_BASE."""
    with open(os.path.join(ROOT, 'build', 'vi.bin'), 'rb') as f:
        sig = list(f.read(32))
    for b in range(1, 16):
        r = c.call_tool('peek', {'addr': 0x0800, 'count': 32,
                                 'bank': 'aux', 'aux_bank': b})
        if (r.get('bytes') or r.get('data')) == sig:
            return b
    return None


# The PCB array lives in the annex (aux bank 0) at ANNEX_STRCT_A, 16
# bytes per pid: +1 PCB_STATE (0 = unused), +3 PCB_BANK (physical aux
# bank). pid is the slot index; sched.s PCB_PTR_FOR / mm.annex2.equ.
PCB_ARRY_ADDR = 0x0800
PCB_ENT_SIZE = 16
PCB_COUNT = 48


def kernel_sym(name):
    """Address of a kernel symbol in the PLAY kernel, from merlin32's
    own symbol dump for build/MAUXPLAY.SYSTEM (a build artifact of
    `make play-image`; check_du.py's technique, never hardcoded)."""
    import re
    out = os.path.join(ROOT, 'build', 'MAUXPLAY.SYSTEM_Output.txt')
    for line in open(out, errors='replace'):
        m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\$([0-9A-Fa-f]+)\s*$',
                     line)
        if m and m.group(1) == name:
            return int(m.group(2), 16)
    raise RuntimeError(f'{name} absent from the play kernel symbol dump')


def peek_main(c, addr, n=1):
    r = c.call_tool('peek', {'addr': addr, 'count': n, 'bank': 'main'})
    return r.get('bytes') or r.get('data')


def live_proc(c, binpath):
    """(pid, bank) of a LIVE process whose bank holds `binpath`'s image
    -- a used PCB slot (any state) matched by bank signature. A dead
    bank keeps its image (lazy free), so the signature alone is not
    enough -- walk the PCBs first."""
    with open(binpath, 'rb') as f:
        sig = list(f.read(32))
    r = c.call_tool('peek', {'addr': PCB_ARRY_ADDR,
                             'count': PCB_COUNT * PCB_ENT_SIZE,
                             'bank': 'aux', 'aux_bank': 0})
    tbl = r.get('bytes') or r.get('data')
    for pid in range(1, PCB_COUNT):
        e = tbl[pid * PCB_ENT_SIZE:(pid + 1) * PCB_ENT_SIZE]
        if e[1] == 0:
            continue
        got = c.call_tool('peek', {'addr': 0x0800, 'count': 32,
                                   'bank': 'aux', 'aux_bank': e[3]})
        if (got.get('bytes') or got.get('data')) == sig:
            return pid, e[3]
    return None, None


def live_vi(c):
    """(pid, bank) of the LIVE vi -- live_proc against build/vi.bin."""
    return live_proc(c, os.path.join(ROOT, 'build', 'vi.bin'))


# The killer's delay, in seconds, for every case that arms `( sleep N ;
# kill ... ) &` and then watches vi (also read by check_vi_alt). It must
# outlast the HARNESS, not the guest (docs/GATE-RACE-1-NOTES.md, WAKE-1
# sec 15-16). The harness, in GUEST cycles after the arming line: ~1.8M
# typing it (36 keys x 50k drain), ~0.4M on the "Hit return" settle,
# ~0.2M on the Return, ~0.4M on the repaint settle = ~2.8M before it has
# seen vi raw again; MAUX_GATE_RACE=late adds 3M of lag BEFORE all that.
# The guest's side is MEASURED, not assumed: `:!` loads a 34 KB sh, so the
# killer's sleep starts ~6M cycles after the line, and the old `sleep 3`
# only went red at a 12M lag (and stayed vacuously green from ~4M: see
# vi_not_yet_dead). N = 8 fires at ~14M after the line against a harness
# that has seen vi by ~5.8M even when it is late. If a case still loses
# the race, vi_not_yet_dead says so.
KILLER_DELAY = 8


def vi_not_yet_dead(c, pid, label, pred):
    """`pred` wrapped so the race reports itself. Until the harness has
    seen vi repaint, vi (`pid`) must be ALIVE: if it is already dead the
    killer's `kill` fired first, every later poll reads a stale glass
    (`$ AR` over PEAR still satisfies the repaint predicate), and the
    case would go on to 'pass' without ever having killed a vi that
    owned raw tty state. Fail NOW with the cause (learning
    01M5DVRZGJ865JR719VGE24XND: checking at failure time does not work,
    by then the damage is done)."""
    def wrapped(rs):
        if live_vi(c)[0] != pid:
            raise AssertionError(
                f'{label}: the overlap did not happen: the killer\'s kill '
                f'fired before the harness saw vi repaint (guest faster '
                f'than the harness pace, or the harness late; raise '
                f'KILLER_DELAY)')
        return pred(rs)
    return wrapped


def assert_alive_and_quit(c, label):
    """`1Gx` must edit line 1 (PEAR -> EAR or APPLE -> PPLE), then
    `:q!` must return to the shell."""
    before = V.line(V.rows(c), 0)
    V.t(c, '1Gx')
    V.settle(c, lambda rs: V.line_eq(rs, 0, before[1:]),
             f'{label}: 1Gx edits line 1 (vi alive)')
    V.t(c, ':q!\r')
    V.settle(c, V._at_prompt, f'{label}: :q! returns to the shell')


# --------------------------------------------------------------------
def case_bang(c):
    V.open_vi(c, 'DEMO/FRUIT')
    V.t(c, ':!echo HI\r')
    V.settle(c, lambda rs: has_row(rs, 'HI'),
             'bang: the child\'s HI is visible on the glass')
    V.settle(c, lambda rs: any('Hit return' in r for r in rs),
             'bang: [Hit return to continue] prompt')
    V.t(c, '\r')
    V.settle(c, lambda rs: V.line_eq(rs, 0, 'PEAR') and V._in_vi(rs),
             'bang: repaint after RETURN')
    assert_alive_and_quit(c, 'bang')


def case_filter(c):
    V.open_vi(c, 'DEMO/FRUIT')
    V.t(c, ':%!sort\r')
    V.settle(c, lambda rs: all(V.line_eq(rs, i, SORTED[i])
                               for i in range(len(SORTED))),
             'filter: buffer sorted on the glass')
    assert_alive_and_quit(c, 'filter')


def case_pipe_nospace(c):
    """`|` is an operator with or without blanks around it, and quoting
    still wins. Typed at the shell prompt, the form a human types."""
    V.settle(c, V._at_prompt, 'pipe_nospace: shell prompt')
    V.t(c, 'echo HELLO|cat\r')
    V.settle(c, lambda rs: has_row(rs, 'HELLO'),
             'pipe_nospace: echo HELLO|cat prints HELLO (piped, not '
             'the literal word HELLO|cat)')
    V.t(c, "echo 'a|b'\r")
    V.settle(c, lambda rs: has_row(rs, 'a|b'),
             "pipe_nospace: echo 'a|b' prints a|b (a quoted | is not "
             'an operator)')
    V.t(c, 'echo X||echo Y\r')
    V.settle(c, lambda rs: has_row(rs, 'X') and V._at_prompt(rs),
             'pipe_nospace: echo X||echo Y prints X (|| kept whole)')
    rs = V.rows(c)
    if has_row(rs, 'Y'):
        raise AssertionError('pipe_nospace: echo X||echo Y ALSO printed '
                             'Y -- `||` was shattered or not '
                             f'short-circuited: {nonblank(rs)}')
    if any('not found' in r for r in rs):
        raise AssertionError('pipe_nospace: a "not found" diagnostic '
                             f'appeared: {nonblank(rs)}')


def case_filter_nospace(c):
    V.open_vi(c, 'DEMO/FRUIT')
    V.t(c, ':%!sort|uniq\r')
    V.settle(c, lambda rs: all(V.line_eq(rs, i, UNIQ[i])
                               for i in range(len(UNIQ)))
             and V.line(rs, len(UNIQ)) == '~',
             'filter_nospace: :%!sort|uniq leaves the sorted, deduped '
             'buffer (6 lines then ~) on the glass')
    assert_alive_and_quit(c, 'filter_nospace')


def case_killed(c):
    # vi's pid is the allocator's choice (pid == bank; a dead tagged
    # bank is NOT reliably reused), so the killer cannot be armed at
    # the shell before vi exists. vi arms it itself: `:!` runs a
    # background subshell that sleeps, then kills the pid this case
    # read from the PCB table -- vi is back in RAW mode by then (the
    # hit-return prompt is answered), which is exactly the backstop's
    # case: SIGTERM is untrappable, vi restores nothing itself.
    V.open_vi(c, 'DEMO/FRUIT')
    pid, bank = live_vi(c)
    if pid is None:
        raise AssertionError('killed: could not find a live vi in the '
                             'PCB table')
    V.t(c, f':!( sleep {KILLER_DELAY} ; kill {pid} ) &\r')
    V.settle(c, vi_not_yet_dead(
        c, pid, 'killed', lambda rs: any('Hit return' in r for r in rs)),
        'killed: [Hit return to continue] after arming the killer')
    V.t(c, '\r')
    V.settle(c, vi_not_yet_dead(
        c, pid, 'killed',
        lambda rs: V.line_eq(rs, 0, 'PEAR') and V._in_vi(rs)),
        'killed: vi repainted, raw again, killer pending')
    # ~3 s later vi dies; its parent (the login shell) reaps it -- the
    # PCB slot goes unused -- and reprompts ON TOP of vi's stale glass
    # (`$ AR` over PEAR), so the table, not the screen, is the oracle.
    for _ in GR.polls(c, 400):
        if live_vi(c)[0] is None:
            break
    else:
        raise AssertionError(f'killed: vi (pid {pid}, bank {bank}) is '
                             f'still alive after the killer fired')
    step(c, 20)                              # let the shell reprompt
    # tty sanity: cooked (the line runs as one command) + echo (the typed
    # line is visible) -- check_reset's own recover oracle.
    # (the shell writes over vi's stale glass, so BBB lands as e.g.
    # `BBBLE` over APPLE -- match the row START, not the whole row)
    V.t(c, 'echo BBB\r')
    step(c, 30)
    rs = V.rows(c)
    if not any(r.startswith('BBB') for r in rs):
        raise AssertionError('killed: echo BBB did not run as a cooked '
                             'line after vi was killed (ICANON not '
                             f'restored): {nonblank(rs)}')
    if not any('echo BBB' in r for r in rs):
        raise AssertionError('killed: the typed "echo BBB" did not echo '
                             f'after vi was killed (ECHO not restored): '
                             f'{nonblank(rs)}')


def free_pids(c):
    """UNUSED PCB slots, ascending -- the allocator hands out the lowest."""
    r = c.call_tool('peek', {'addr': PCB_ARRY_ADDR,
                             'count': PCB_COUNT * PCB_ENT_SIZE,
                             'bank': 'aux', 'aux_bank': 0})
    tbl = r.get('bytes') or r.get('data')
    return [pid for pid in range(1, PCB_COUNT)
            if tbl[pid * PCB_ENT_SIZE + 1] == 0]


# killed_midcsi's killer delay (seconds). cat must be draining DEMO/ESCS
# when the kill lands, so the delay must outlast what the harness spends
# between arming the killer and seeing cat up: ~0.4M settle + ~0.2M slot
# poll + ~0.8M typing `cat DEMO/ESCS` + ~0.2M to see cat = ~1.6M, plus
# MAUX_GATE_RACE=late's 3M = ~4.6M. It must also end BEFORE cat's own
# drain does (32 KB through the console). 8 s = ~9.6M after the line.
MIDCSI_DELAY = 8


def case_killed_midcsi(c):
    """A FOREGROUND `cat DEMO/ESCS` killed mid-drain must not leave the
    console's escape parser mid-sequence (ccae082). DEMO/ESCS is ONE
    control sequence with no end (build_play_image.py's _escs_probe:
    `ESC [` then `1;` forever; the parser never cancels on length,
    tty2.s TTY_CSI_BYTE), so while cat runs the parser is mid-CSI at
    every instant -- PROVIDED nothing else writes to the console. That
    is why the shape is the vi case's, not a background job: the
    killer `( sleep 2 ; kill N ) &` is armed first, then cat runs in
    the FOREGROUND, the shell waits silently, and the only writer is
    cat (earlier drafts backgrounded cat and the shell's own `[1] n`,
    prompt, or the echoed `kill` closed the sequence before the kill;
    measured, all green under sabotage). N is predicted -- the
    allocator hands out the lowest UNUSED slot, the killer line takes
    the first two -- and VERIFIED once cat is up. The oracle is the
    prompt row after the kill: with the reset it starts with `$`; with
    ccae082 reverted the `$` is eaten as the CSI final and the row
    starts with the space that followed it (cat's leftover parameters,
    if any were queued, drain as `1;1;` text after that). `echo BBB`
    must then run.

    A WELL-FORMED JOB NOTICE IS SKIPPED ON THE WAY TO THAT ROW, and
    the reason is worth stating because this oracle read the FIRST
    non-blank row for months and only ever saw the prompt. The killer
    `( sleep 2 ; kill N ) &` is itself a job, and whether it has been
    reaped and reported by the time the shell reprompts after cat dies
    is a RACE this case does not legislate -- the gap between `kill`
    returning and the killer subshell's own exit is milliseconds, and
    anything that perturbs the shell's startup moves it. Measured
    2026-09-16 at the second-code-segment landing (docs/SH-SUBSET.md
    ruling 7.6): main gives `['$ ...']` here and the segment branch
    gives `['[1]+ Done   ( sleep 2 ; kill 6 )', '$ ...']`, with `$`
    intact in both -- the property this case exists for held, and the
    oracle failed anyway. check-jobctl-c owns the "Done at the next
    prompt" claim; this case owns the `$`.

    THE SKIP KEEPS THE TEETH because it requires the notice to still
    have its own leading `[` (and the signal name its leading `T`). The ccae082 bug eats ONE character --
    whichever one the half-open CSI's final lands on -- so a notice
    printed under it reads `1]+ Done ...`, matches nothing here, and
    is handed to the `startswith('$')` test exactly as the prompt row
    would have been. PROVEN 2026-09-16 by forcing that shape (replace
    the row's first character with a space): the case goes red with
    the notice-skip in place.
    """
    cat_bin = os.path.join(ROOT, 'build', 'cat.bin')
    esc_state = kernel_sym('VC_ESC_STATE')
    V.boot(c)
    V.settle(c, V._at_prompt, 'killed_midcsi: shell prompt')
    free = free_pids(c)
    if len(free) < 3:
        raise AssertionError(f'killed_midcsi: no free PCB slots: {free}')
    target = free[2]
    V.t(c, f'( sleep {MIDCSI_DELAY} ; kill {target} ) &\r')
    V.settle(c, V._at_prompt, 'killed_midcsi: killer armed')
    # The prompt can return before the killer subshell has spawned
    # its `sleep` (a bigger sh image is a slower subshell start --
    # TAB-A2 measured the prompt back with only the subshell up and
    # cat then took the slot the prediction gave to sleep). The
    # prediction needs BOTH killer slots taken before cat is typed.
    for _ in range(GR.count(60)):
        if len(free_pids(c)) <= len(free) - 2:
            break
        GR.poll_step(c)
    else:
        raise AssertionError('killed_midcsi: the killer never spawned '
                             'its sleep (two slots were not taken)')
    before = V.rows(c)
    V.t(c, 'cat DEMO/ESCS\r')
    pid = None
    for _ in GR.polls(c, 30):
        pid, bank = live_proc(c, cat_bin)
        if pid is not None:
            break
    else:
        raise AssertionError('killed_midcsi: cat never showed up as a '
                             'live PCB slot')
    # THE OVERLAP, asserted (GATE-RACE-1): the killer's two slots are
    # still taken, so its kill has not fired and will land on a cat
    # that is draining. A prediction failure (below) is this same race seen
    # from the other side (the killer exited and freed its slots, so
    # cat took a lower one).
    if len(free_pids(c)) > len(free) - 3:
        raise AssertionError('killed_midcsi: the overlap did not happen: '
                             'the killer fired before cat was draining '
                             '(guest faster than the harness pace, or '
                             'the harness late; raise MIDCSI_DELAY)')
    if pid != target:
        raise AssertionError(f'killed_midcsi: harness pid prediction '
                             f'failed (cat is {pid}, killer aims at '
                             f'{target}) -- not a kernel verdict')
    step(c, 2)
    if peek_main(c, esc_state)[0] == 0:
        raise AssertionError('killed_midcsi: the console is NOT mid-CSI '
                             'while cat drains DEMO/ESCS -- the fixture '
                             'lost its teeth')
    for _ in GR.polls(c, 400):
        if live_proc(c, cat_bin)[0] is None:
            break
    else:
        raise AssertionError(f'killed_midcsi: cat (pid {pid}) is still '
                             f'alive after the killer fired')
    step(c, 30)                    # reprompt + leftover drain
    rows = V.rows(c)
    cmd_rows = [i for i, r in enumerate(rows) if 'cat DEMO/ESCS' in r]
    if not cmd_rows:
        raise AssertionError('killed_midcsi: the `cat DEMO/ESCS` row is '
                             'gone from the glass after the kill -- the '
                             'console parser is still mid-sequence '
                             f'(ccae082 reverted shape): {nonblank(rows)}')
    cmd_idx = max(cmd_rows)
    after = [r for r in rows[cmd_idx + 1:] if r.strip()]
    if not after:
        raise AssertionError('killed_midcsi: nothing printed after the '
                             f'kill: {nonblank(rows)}')
    # -- sh names the foreground death now (KFIX3 item 3): `Terminated`
    # -- is the first row after cat dies. Skip it only when it is
    # -- INTACT: the ccae082 bug eats one character, so the reverted
    # -- shape reads `erminated`, is not skipped, and fails the `$`
    # -- test below exactly as the prompt row would have.
    term_seen = False
    while after and (JOB_NOTICE.match(after[0])
                     or after[0].strip() == 'Terminated'):
        term_seen |= after[0].strip() == 'Terminated'
        after.pop(0)
    if not after:
        raise AssertionError('killed_midcsi: only job notices printed '
                             f'after the kill, no prompt: {nonblank(rows)}')
    prompt_row = after[0]
    if not prompt_row.startswith('$'):
        raise AssertionError('killed_midcsi: the prompt\'s "$" was eaten '
                             'by a half-open escape (ccae082 reverted '
                             f'shape): {prompt_row!r} -- {nonblank(rows)}')
    if not term_seen:
        raise AssertionError('killed_midcsi: the overlap did not happen: '
                             'no `Terminated` notice, so cat was not '
                             'killed mid-drain by the TERM (it ended on '
                             f'its own?): {nonblank(rows)}')
    V.t(c, 'echo BBB\r')
    for _ in GR.polls(c, 80):
        if any(r.strip() == 'BBB' for r in V.rows(c)):
            break
    else:
        raise AssertionError('killed_midcsi: "echo BBB" did not run '
                             f'after the kill: {nonblank(V.rows(c))}')


def case_print_prompt(c):
    """`:nu` output stays readable behind [Hit return to continue]
    (ED_GLASSOUT), while a bare `:N` is a MOTION in vi -- no print, no
    prompt (edparse.s :bareaddr under ED_D1FLAG; check_vi's _redraw
    relies on it)."""
    V.open_vi(c, 'DEMO/FRUIT')
    V.t(c, ':3nu\r')
    V.settle(c, lambda rs: any('3' in r and 'MANGO' in r for r in rs)
             and any('Hit return' in r for r in rs),
             'print: :3nu shows "3 MANGO" and the prompt')
    V.t(c, '\r')
    V.settle(c, lambda rs: V.line_eq(rs, 0, 'PEAR') and V._in_vi(rs),
             'print: repaint after RETURN')
    V.t(c, ':4\r')
    step(c, 10)
    if any('Hit return' in r for r in V.rows(c)):
        raise AssertionError('print: bare `:4` prompted -- it must be a '
                             'silent motion in vi')
    V.t(c, 'x')                              # on line 4 (APPLE -> PPLE)
    V.settle(c, lambda rs: V.line_eq(rs, 3, 'PPLE'),
             'print: `:4` moved dot to line 4 (x edited it)')
    V.t(c, ':q!\r')
    V.settle(c, V._at_prompt, 'print: :q! returns to the shell')


CASES = [
    ('bang', ':!echo HI shows HI, RETURN repaints, vi alive', case_bang),
    ('print', ':nu prompts before repaint; bare :N is a silent motion',
     case_print_prompt),
    ('filter', ':%!sort sorts the buffer, vi alive', case_filter),
    ('pipe_nospace', 'sh: echo HELLO|cat pipes; \'a|b\' literal; '
     'X||echo Y keeps ||', case_pipe_nospace),
    ('filter_nospace', ':%!sort|uniq (no blanks) sorts+dedupes, vi alive',
     case_filter_nospace),
    ('killed', 'SIGTERM-killed vi leaves the tty cooked+echo',
     case_killed),
    ('killed_midcsi', 'a foreground `cat` killed mid-CSI leaves the '
     'prompt un-eaten (ccae082, foreground cat)', case_killed_midcsi),
]


def main():
    if not os.path.exists(os.path.join(ROOT, 'build', 'play.po')):
        print('error: build/play.po missing -- run make play-image',
              file=sys.stderr)
        return 2
    only = set(sys.argv[1:])
    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
    c = MCPClient([SUPERVISOR], env)
    fails = []
    try:
        c.initialize()
        V.boot(c)
        for name, desc, fn in CASES:
            if only and name not in only:
                continue
            try:
                fn(c)
                print(f'[check-vi-bang] ok   {name}: {desc}')
            except AssertionError as e:
                fails.append((name, str(e)))
                print(f'[check-vi-bang] FAIL {name}: {e}', file=sys.stderr)
                # a wedged vi cannot be talked out; reboot for the next
                V.boot(c)
    finally:
        try:
            c.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        c.close()

    if fails:
        print(f'[check-vi-bang] FAIL: {len(fails)} of {len(CASES)} cases',
              file=sys.stderr)
        return 1
    print('[check-vi-bang] PASS: vi survives :!cmd and :%!filter; '
          '`|` pipes with or without blanks; a killed vi leaves the tty '
          'cooked')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
