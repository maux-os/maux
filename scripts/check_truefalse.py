#!/usr/bin/env python3
"""check_truefalse.py -- the `true` / `false` no-ops (`make
check-truefalse`, in check-all-cross).

maux `sh` evaluates a construct's condition by SPAWNING it, so
`true`/`false` have to be real programs on PATH, not shell words --
before they existed `if true` said "command not found". They are the
smallest possible utilities: `lda #0/1 ; jsr SC_EXIT`. This gate drives
the real shell on the fast backend and checks the ONE thing they exist
to provide -- their exit status -- both directly (`$?`) and through the
`&&`/`||` conditionals that are their whole point. All simple commands,
no constructs, so it runs at the interactive prompt (no seekable-stdin
needed).

Teeth: every case is RED before the utilities exist (`true` ->
"command not found", `$?` nonzero, `&&`-RHS never runs), GREEN after.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_vi as V                                    # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR    # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def step(c, n):
    for _ in range(n):
        c.call_tool('step', {'cycles': 200_000})


def rows_nb(c):
    return [r.rstrip() for r in V.rows(c) if r.strip()]


def main():
    if not os.path.exists(os.path.join(ROOT, 'build', 'play.po')):
        print('error: build/play.po missing -- run make play-image',
              file=sys.stderr)
        return 2
    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
    c = MCPClient([SUPERVISOR], env)
    fails = []
    try:
        c.initialize()
        V.boot(c)

        def run(cmd, want, label):
            V.t(c, cmd + '\r')
            step(c, 40)
            scr = rows_nb(c)
            if not any(r.strip() == want for r in scr):
                fails.append(f'{label}: `{cmd}` -> expected a line '
                             f'{want!r}; screen tail {scr[-4:]}')

        run('true ; echo $?', '0', 'true exit status')
        run('false ; echo $?', '1', 'false exit status')
        run('true && echo AYE', 'AYE', 'true && runs RHS')
        run('false || echo NAY', 'NAY', 'false || runs RHS')
        # false must NOT run a && RHS -- assert AYE2 is absent.
        V.t(c, 'false && echo AYE2\r')
        step(c, 40)
        if any(r.strip() == 'AYE2' for r in rows_nb(c)):
            fails.append('false && ran its RHS (AYE2 appeared)')
    finally:
        try:
            c.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        c.close()

    if fails:
        for f in fails:
            print(f'[check-truefalse] FAIL: {f}', file=sys.stderr)
        return 1
    print('[check-truefalse] PASS: true exits 0, false exits 1, and '
          '&&/|| branch on them')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
