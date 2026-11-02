#!/usr/bin/env python3
"""check_vi_alt.py -- vi's ALTERNATE SCREEN (`make check-vi-alt`, in
check-all-cross). docs/VI-ALTSCREEN.md.

vi emits xterm's smcup/rmcup -- `ESC [ ? 1049 h` at entry, `ESC [ ?
1049 l` at every quit -- and the maux console honours them: the live
screen is parked in a per-console annex alt-store on `h`, and blitted
back (cursor included) on `l`. Quitting vi therefore brings the SHELL
SCREEN BACK instead of leaving a cleared glass. The kernel's
PRC_ALT_RST backstop (tty5.s, PRC_TMD_RST's twin) restores the screen
of a vi that dies without rmcup.

Cases, each against the REAL kernel + shell on the fast backend:

  restore_qbang  a marker word is on the shell screen; `vi DEMO/FRUIT`
                 HIDES it (alt screen, vi's own view); `:q!` brings it
                 BACK, with the new prompt directly below the line that
                 launched vi (the cursor came back too).
  restore_q      same through plain `:q`.
  restore_zz     same through `ZZ` (EX_XCORE's just-quit lane) -- three
                 exits through EX_ONQUIT's one choke.
  killed         a vi KILLED mid-session (background killer armed from
                 `:!`, check_vi_bang's shape) leaves the marker visible
                 again -- the backstop -- and the tty cooked+echo.
  killed_bg      the backstop's BACKGROUND lane: the killer first moves
                 the glass to console 2 (`chvt 2`), kills vi while
                 console 1 is off the glass, then `chvt 1` -- the switch
                 back repaints the shell screen from console 1's store,
                 which the backstop restored alt -> store (cursor too).
  unknown_priv   `cat DEMO/ALTPRIV` (raw `ESC [ ? 25 l` + `ESC [ ? 9999
                 h` ahead of PRIVOK) prints PRIVOK alone: unknown private
                 modes are swallowed, never rendered as text.
  n8             restore_qbang again after `vidmode 80` -- the native
                 80-column backend, whose rows are split main/aux.
  ut             restore_qbang again on the UltraTerm (its VRAM cannot
                 be read back: the park is store->alt, the restore is
                 alt->store + the card repaint), read via ultraterm_state.

Teeth (measured on dbbfd56, the tree without the feature): every
restore case, killed and unknown_priv went RED -- the marker never came
back (vi's ESC [ 2 J left a blank glass), a killed vi left its stale
screen, and the private sequences rendered as `25l9999hPRIVOK`.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_vi as V                                    # noqa: E402
import check_vi_bang as B                               # noqa: E402
import gate_race as GR                                  # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR    # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MARK = 'ALTMARK7'
LAUNCH = 'vi DEMO/FRUIT'


def has_mark(rs):
    return any(MARK in r for r in rs)


def prompt_below(rs, cmd):
    """The row after `$ cmd` starts with `$`: the cursor was restored
    to where vi was launched, so the fresh prompt landed right under
    it -- not on vi's status row, not mid-line."""
    for i, r in enumerate(rs[:-1]):
        if r.strip() == f'$ {cmd}':
            return rs[i + 1].strip().startswith('$')
    return False


def settle_rows(c, rowsfn, pred, label, max_steps=1500):
    """check_vi.settle with a pluggable screen reader (the UltraTerm's
    text comes from ultraterm_state, not screen_text)."""
    held = False
    rs = []
    for _ in GR.polls(c, max_steps):
        rs = rowsfn(c)
        if pred(rs):
            if held:
                return rs
            held = True
        else:
            held = False
    blob = '\n'.join(f'{i:2d}|{r.rstrip()}' for i, r in enumerate(rs))
    raise AssertionError(f'timed out waiting for {label}; screen was:\n'
                         f'{blob}')


def restore_cycle(c, rowsfn, quit_keys, label):
    """marker -> vi hides it -> quit restores it (+ cursor)."""
    settle_rows(c, rowsfn, V._at_prompt, f'{label}: shell prompt')
    V.t(c, f'echo {MARK}\r')
    settle_rows(c, rowsfn, lambda rs: has_mark(rs) and V._at_prompt(rs),
                f'{label}: marker on the shell screen')
    V.t(c, LAUNCH + '\r')
    settle_rows(c, rowsfn, lambda rs: V._in_vi(rs) and not has_mark(rs),
                f'{label}: vi up and the marker HIDDEN (alt screen)')
    V.t(c, quit_keys)
    settle_rows(c, rowsfn,
                lambda rs: V._at_prompt(rs) and has_mark(rs)
                and prompt_below(rs, LAUNCH),
                f'{label}: quit RESTORES the marker, prompt below the '
                f'launch line')


# --------------------------------------------------------------------
def case_restore_qbang(c):
    restore_cycle(c, V.rows, ':q!\r', 'restore_qbang')


def case_restore_q(c):
    restore_cycle(c, V.rows, ':q\r', 'restore_q')


def case_restore_zz(c):
    restore_cycle(c, V.rows, 'ZZ', 'restore_zz')


def case_killed(c):
    V.settle(c, V._at_prompt, 'killed: shell prompt')
    V.t(c, f'echo {MARK}\r')
    V.settle(c, lambda rs: has_mark(rs) and V._at_prompt(rs),
             'killed: marker on the shell screen')
    V.t(c, LAUNCH + '\r')
    V.settle(c, lambda rs: V._in_vi(rs) and not has_mark(rs),
             'killed: vi up and the marker hidden')
    pid, bank = B.live_vi(c)
    if pid is None:
        raise AssertionError('killed: could not find a live vi in the '
                             'PCB table')
    V.t(c, f':!( sleep {B.KILLER_DELAY} ; kill {pid} ) &\r')
    V.settle(c, B.vi_not_yet_dead(
        c, pid, 'killed', lambda rs: any('Hit return' in r for r in rs)),
        'killed: [Hit return to continue] after arming the killer')
    V.t(c, '\r')
    V.settle(c, B.vi_not_yet_dead(
        c, pid, 'killed',
        lambda rs: V.line_eq(rs, 0, 'PEAR') and V._in_vi(rs)),
        'killed: vi repainted, raw again, killer pending')
    for _ in GR.polls(c, 400):
        if B.live_vi(c)[0] is None:
            break
    else:
        raise AssertionError(f'killed: vi (pid {pid}, bank {bank}) is '
                             f'still alive after the killer fired')
    # the backstop: the shell's screen is back, and the shell reprompts
    # on it (the parent reaps the killed child and prompts again)
    V.settle(c, lambda rs: has_mark(rs) and V._at_prompt(rs),
             'killed: the marker is BACK after vi was killed (backstop)')
    rs = V.rows(c)
    if V._in_vi(rs):
        raise AssertionError('killed: vi\'s ~ rows survived the kill -- '
                             f'the alt screen was not torn down: '
                             f'{B.nonblank(rs)}')
    # tty sanity, check_vi_bang's own oracle: cooked + echo
    V.t(c, 'echo BBB\r')
    V.settle(c, lambda rs: any(r.strip() == 'BBB' for r in rs)
             and any('echo BBB' in r for r in rs),
             'killed: echo BBB runs cooked and echoes after the kill')


# case_killed_bg's first killer delay, in seconds. See the comment at its
# use: it must outlast the HARNESS pace on the fastest guest. It is
# check_vi_bang's KILLER_DELAY, whose arithmetic (and MAUX_GATE_RACE=late's
# 3M of extra lag) covers this case too.
KILLER_FIRST_DELAY = B.KILLER_DELAY
RACE_MSG = ('killed_bg: the killer\'s chvt fired before the harness saw vi '
            'repaint (guest faster than the harness pace; raise the first '
            'delay)')


def not_yet_console2(c, pred, pid=None):
    """`pred` wrapped so the race reports itself. Until the harness has
    seen vi repaint, console 2 must NOT be the active console: if it is,
    the killer's `chvt 2` already fired and every later poll reads the
    wrong glass -- fail NOW with the cause, not 300M cycles later with a
    screen dump of an innocent `$`. VC_ACTIVE is 0 for console 1."""
    def wrapped(rs):
        if B.peek_main(c, B.kernel_sym('VC_ACTIVE'))[0] != 0:
            raise AssertionError(RACE_MSG)
        if pid is not None and B.live_vi(c)[0] != pid:
            raise AssertionError(
                'killed_bg: the overlap did not happen: the killer\'s kill '
                'fired before the harness saw vi repaint (guest faster '
                'than the harness pace, or the harness late; raise '
                'KILLER_DELAY)')
        return pred(rs)
    return wrapped


def case_killed_bg(c):
    """PRC_ALT_RST's BACKGROUND lane. vi holds console 1's alt screen;
    a background subshell moves the glass to console 2 (`chvt 2`),
    kills vi while console 1 is NOT on the glass, then `chvt 1` (a
    redirected write: the switch is parked and run by TTY_WR_LEAVE,
    check_play's own chvt leg). The backstop restored alt -> STORE and
    the parked cursor, so the switch back repaints the SHELL screen --
    marker included, prompt below the launch line -- not vi's."""
    V.settle(c, V._at_prompt, 'killed_bg: shell prompt')
    V.t(c, f'echo {MARK}\r')
    V.settle(c, lambda rs: has_mark(rs) and V._at_prompt(rs),
             'killed_bg: marker on the shell screen')
    V.t(c, LAUNCH + '\r')
    V.settle(c, lambda rs: V._in_vi(rs) and not has_mark(rs),
             'killed_bg: vi up and the marker hidden')
    pid, bank = B.live_vi(c)
    if pid is None:
        raise AssertionError('killed_bg: could not find a live vi in the '
                             'PCB table')
    # The first delay must outlast the HARNESS, not the guest: V.t paces
    # its typing at ~3.25M guest cycles and the two settles below add
    # ~0.6M, so vi's repaint is first observed ~4.3M cycles after the
    # guest starts the killer -- and a faster guest starts it EARLIER
    # (WAKE-1 made typed-key echo cheaper: with `sleep 2`, 2.04M cycles,
    # chvt 2 landed ~0.2M cycles BEFORE the observation and the gate
    # read console 2's glass). KILLER_FIRST_DELAY is check_vi_bang's
    # KILLER_DELAY (8 s = 8.2M cycles): that comment has the arithmetic,
    # including MAUX_GATE_RACE=late's 3M of lag, which the old 5 s did
    # NOT survive. The rest of the sequence is unchanged. If a still
    # faster guest loses the race again, not_yet_console2 says so.
    V.t(c, f':!( sleep {KILLER_FIRST_DELAY} ; chvt 2 ; sleep 2 ; '
           f'kill {pid} ; sleep 2 ; chvt 1 ) &\r')
    V.settle(c, not_yet_console2(
        c, lambda rs: any('Hit return' in r for r in rs), pid),
        'killed_bg: [Hit return to continue] after arming the killer')
    V.t(c, '\r')
    V.settle(c, not_yet_console2(
        c, lambda rs: V.line_eq(rs, 0, 'PEAR') and V._in_vi(rs), pid),
        'killed_bg: vi repainted, raw again, killer pending')
    for _ in GR.polls(c, 600):
        if B.live_vi(c)[0] is None:
            break
    else:
        raise AssertionError(f'killed_bg: vi (pid {pid}, bank {bank}) is '
                             f'still alive after the killer fired')
    V.settle(c, lambda rs: has_mark(rs) and V._at_prompt(rs)
             and prompt_below(rs, LAUNCH),
             'killed_bg: back on console 1, the marker is BACK and the '
             'prompt sits below the launch line (backstop, background '
             'lane: alt -> store + parked cursor)')
    rs = V.rows(c)
    if V._in_vi(rs):
        raise AssertionError('killed_bg: vi\'s ~ rows came back with the '
                             f'switch -- the store was not restored: '
                             f'{B.nonblank(rs)}')
    # PRC_TMD_RST's BACKGROUND lane too: the console's slot must have
    # been written cooked+echo while it was off the glass (found
    # 2026-09-08: TTY_TMODE_STO's second BankCopy ran with K_BC_LEN 0
    # -- consumed by the first -- so the slot kept vi's raw mode and
    # the next typed line never echoed).
    V.t(c, 'echo BBB\r')
    V.settle(c, lambda rs: any(r.strip() == 'BBB' for r in rs)
             and any('echo BBB' in r for r in rs),
             'killed_bg: echo BBB runs cooked AND echoes after the '
             'background-lane restore (tty mode slot write)')


def case_unknown_priv(c):
    V.settle(c, V._at_prompt, 'unknown_priv: shell prompt')
    V.t(c, 'cat DEMO/ALTPRIV\r')
    V.settle(c, lambda rs: any(r.strip() == 'PRIVOK' for r in rs)
             and V._at_prompt(rs),
             'unknown_priv: cat DEMO/ALTPRIV prints PRIVOK on its own')
    rs = V.rows(c)
    for stray in ('9999', '25l'):
        if any(stray in r for r in rs):
            raise AssertionError(f'unknown_priv: the private sequence '
                                 f'leaked onto the glass as text '
                                 f'({stray!r}): {B.nonblank(rs)}')


def case_n8(c):
    V.settle(c, V._at_prompt, 'n8: shell prompt')
    V.t(c, 'vidmode 80\r')
    V.settle(c, lambda rs: V._at_prompt(rs) and len(rs[0]) >= 80,
             'n8: vidmode 80 -> the 80-column motherboard console')
    restore_cycle(c, V.rows, ':q!\r', 'n8')


def ut_rows(c):
    st = c.call_tool('ultraterm_state', {})
    if not st.get('installed'):
        return []
    return st.get('text') or []


def case_ut(c):
    c.require_tools('ultraterm_state')
    r = c.call_tool('reset', {'backend': 'fast', 'aux': 'ramworks',
                              'ultraterm': True})
    if not r.get('ok') or not r.get('ultraterm'):
        raise RuntimeError(f'ut: reset with the UltraTerm failed: {r}')
    r = c.call_tool('mount_disk', {'path': V.DISK, 'unit': 1,
                                   'copy': True})
    if r.get('ok') is False:
        raise RuntimeError(f'ut: mount_disk failed: {r}')
    settle_rows(c, ut_rows, lambda rs: len(rs) == 24 and V._at_prompt(rs),
                'ut: shell prompt on the card', max_steps=3000)
    restore_cycle(c, ut_rows, ':q!\r', 'ut')


CASES = [
    ('restore_qbang', 'marker hidden by vi, back after :q!',
     case_restore_qbang),
    ('restore_q', 'marker back after :q', case_restore_q),
    ('restore_zz', 'marker back after ZZ', case_restore_zz),
    ('killed', 'a killed vi leaves the shell screen restored (backstop)',
     case_killed),
    ('killed_bg', 'a vi killed while its console is in the background is '
     'restored in its store (backstop, background lane)', case_killed_bg),
    ('unknown_priv', 'ESC[?25l / ESC[?9999h are swallowed, not rendered',
     case_unknown_priv),
    ('n8', 'marker back after :q! on the native-80 backend', case_n8),
    ('ut', 'marker back after :q! on the UltraTerm', case_ut),
]


def main():
    if not os.path.exists(V.DISK):
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
                print(f'[check-vi-alt] ok   {name}: {desc}')
            except AssertionError as e:
                fails.append((name, str(e)))
                print(f'[check-vi-alt] FAIL {name}: {e}', file=sys.stderr)
                try:
                    V.boot(c)           # a wedged vi cannot be talked out
                except Exception as boot_err:
                    # (a failed `ut` leaves the card attached; the plain
                    # reboot may not reach a prompt -- the verdict is
                    # already recorded, do not mask it with a traceback)
                    print(f'[check-vi-alt] recovery boot failed after '
                          f'{name}: {boot_err}', file=sys.stderr)
                    break
    finally:
        try:
            c.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        c.close()

    if fails:
        print(f'[check-vi-alt] FAIL: {len(fails)} of {len(CASES)} cases',
              file=sys.stderr)
        return 1
    print('[check-vi-alt] PASS: vi parks and restores the shell screen '
          '(smcup/rmcup) on 40/N8/UT; a killed vi is restored by the '
          'kernel; unknown private modes are silent')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
