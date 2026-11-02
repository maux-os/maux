#!/usr/bin/env python3
"""check-jobctl-e -- cooperative ^Z: vi saves/restores the terminal
across suspend (docs/JOB-CONTROL.md Increment E).

Before E, `^Z`-ing vi direct-stopped it and did NOT restore the shell
screen (PRC_STOP_SWP never fired the alt-screen backstop -- the program
still owns its store), so the shell reprompted ON TOP of vi's frozen
glass, and a second vi collided on the single per-console alt-store.
E makes SIG_TSTP catchable: the ^Z sweep delivers it to a catcher
(pending + ERR_INTR) instead of stopping it, and vi's VI_SUSPEND emits
rmcup (shell screen BACK), SC_STOPs itself, and emits smcup + repaint on
resume. Driven at the real shell's prompt on build/play.po.

Cases:
  suspend    marker on the shell screen; `vi DEMO/FRUIT` HIDES it; ^Z
             brings the marker BACK (shell screen restored) with vi
             STOPPED; `fg` redraws vi (marker hidden); `:q!` restores it.
  nesting    marker; vi#1; ^Z (marker BACK); vi#2; `:q!` (marker BACK);
             `fg` resumes vi#1 (marker hidden); `:q!` (marker BACK) --
             the single alt-store is never contended because each vi
             rmcups before it stops.
  noncatcher `cat` (a filter that does NOT catch TSTP): ^Z direct-stops
             it (DFL path unchanged) -- STOPPED, prompt back.

Teeth (measured on 35cf504, before E): `suspend` goes RED at the ^Z
step -- the marker never comes back (vi's frozen glass stays, the shell
prompt lands on top), and `nesting` orphans the restore.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_vi as V                                    # noqa: E402
import check_vi_alt as A                                # noqa: E402
import check_jobctl_c as C                              # noqa: E402

from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR   # noqa: E402

# Shell-prompt predicate: C.at_prompt tolerates the `$ $` a ^Z leaves
# (the tty completes an empty line the shell reprompts for) and vi's
# rmcup then restores; check_vi's V._at_prompt wants an exact `$` and
# is vi-oriented. Every prompt check here is a SHELL prompt.
at_prompt = C.at_prompt

TAG = '[check-jobctl-e]'
LAUNCH = A.LAUNCH                                        # 'vi DEMO/FRUIT'
MARK = A.MARK                                            # 'ALTMARK7'


def wait(c, pred, label):
    A.settle_rows(c, V.rows, pred, f'{label}')


def mark_up(c, label):
    """Put the marker on the shell screen and settle at the prompt."""
    V.t(c, f'echo {MARK}\r')
    wait(c, lambda rs: A.has_mark(rs) and at_prompt(rs),
         f'{label}: marker on the shell screen')


def launch_vi(c, label):
    """Launch vi; return its pid once it is up with the marker hidden."""
    base = C.live_pids(c)
    V.t(c, LAUNCH + '\r')
    pid = C.new_pid(c, base, label)
    wait(c, lambda rs: V._in_vi(rs) and not A.has_mark(rs),
         f'{label}: vi up, marker HIDDEN (alt screen)')
    return pid


def case_suspend(c):
    mark_up(c, 'suspend')
    pid = launch_vi(c, 'suspend')
    print(f'{TAG} suspend: vi is pid {pid}; typing ^Z', flush=True)
    C.ctrl_z(c)
    # THE TEETH: the shell screen (marker) comes BACK on ^Z, vi STOPPED.
    wait(c, lambda rs: at_prompt(rs) and A.has_mark(rs),
         'suspend: ^Z restores the shell screen (marker BACK)')
    st = C.state(c, pid)
    if st != C.ST_STOPPED:
        raise AssertionError(f'suspend: vi (pid {pid}) is '
                             f'{C.ST_NAME.get(st)} after ^Z, not STOPPED')
    # THE ECHO TEETH: the shell reprompts COOKED+ECHO, so a typed
    # command is visible. VI_SUSPEND must restore VI_SAVEMD before
    # SC_STOP; without it the shell runs in vi's raw+noecho and the
    # typed line never echoes (`no terminal echo after ^Z`, operator
    # 2026-09-08). The `type` tool does NOT fake echo -- a char shows
    # only if the guest echoed it -- so a row holding the typed
    # command proves ECHO is live.
    V.t(c, 'echo SUSPECHO\r')
    wait(c, lambda rs: any('echo SUSPECHO' in r for r in rs),
         'suspend: the shell ECHOES a typed command after ^Z')
    V.t(c, 'fg\r')
    wait(c, lambda rs: V._in_vi(rs) and not A.has_mark(rs),
         'suspend: fg redraws vi (marker HIDDEN)')
    V.t(c, ':q!\r')
    wait(c, lambda rs: at_prompt(rs) and A.has_mark(rs),
         'suspend: :q! restores the marker')
    print(f'{TAG} ok   suspend (^Z restores the shell screen, fg redraws, '
          'vi parked STOPPED)', flush=True)


def case_nesting(c):
    mark_up(c, 'nesting')
    pid1 = launch_vi(c, 'nesting/vi1')
    C.ctrl_z(c)
    wait(c, lambda rs: at_prompt(rs) and A.has_mark(rs),
         'nesting: ^Z vi#1 restores the shell screen')
    if C.state(c, pid1) != C.ST_STOPPED:
        raise AssertionError('nesting: vi#1 not STOPPED after ^Z')
    pid2 = launch_vi(c, 'nesting/vi2')
    if pid2 == pid1:
        raise AssertionError('nesting: vi#2 reused vi#1 (still stopped)')
    V.t(c, ':q!\r')
    wait(c, lambda rs: at_prompt(rs) and A.has_mark(rs),
         'nesting: quit vi#2 restores the shell screen')
    V.t(c, 'fg\r')                       # bare fg = the current job = vi#1
    wait(c, lambda rs: V._in_vi(rs) and not A.has_mark(rs),
         'nesting: fg resumes vi#1 (marker HIDDEN)')
    V.t(c, ':q!\r')
    wait(c, lambda rs: at_prompt(rs) and A.has_mark(rs),
         'nesting: quit vi#1 restores the shell screen')
    print(f'{TAG} ok   nesting (each vi rmcups before it stops; the '
          'alt-store is never contended)', flush=True)


def case_noncatcher(c):
    # cat does NOT catch TSTP -> the ^Z sweep direct-stops it (DFL path,
    # unchanged from before E). No smcup, so the marker is untouched.
    base = C.live_pids(c)
    V.t(c, 'cat\r')
    pid = C.new_pid(c, base, 'noncatcher')
    C.ctrl_z(c)
    C.wait_state(c, pid, {C.ST_STOPPED}, 'noncatcher')
    C.settle(c, C.at_prompt, 'noncatcher: prompt back after ^Z')
    print(f'{TAG} ok   noncatcher (cat direct-stops on ^Z, DFL path)',
          flush=True)


def run(c):
    C.settle(c, C.at_prompt, 'boot: shell prompt')
    case_suspend(c)
    case_nesting(c)
    case_noncatcher(c)


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
    print(f'{TAG} PASS: cooperative ^Z -- vi restores the shell screen on '
          'suspend and redraws on fg, nesting is clean, and a non-catcher '
          'still direct-stops')
    return 0


if __name__ == '__main__':
    sys.exit(main())
