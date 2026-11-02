"""gate_race.py -- the MAUX_GATE_RACE perturbation knob, and the waits
that keep a gate from racing its own background fixture.

docs/GATE-RACE-1.md, docs/GATE-RACE-1-NOTES.md, docs/GATE-PREDICATES.md.

A gate that starts a guest background job or timer and then acts on it is
calibrated to ONE guest speed unless it waits for a PROPERTY of the
fixture. Two incidents: WAKE-1 made the guest faster and a
`( sleep 2 ; chvt 2 ; kill N ) &` fired before the harness looked;
TAB-A3 made it slower and `shutdown` overtook the background writer.
This module is the tool for finding the next one BEFORE the guest
changes speed. It is NOT a sweep setting: the sweeps run with the
variable unset.

  MAUX_GATE_RACE=late    after every typed line that arms a background
                         fixture (a lone `&`), the harness steps
                         LATE_LAG extra guest cycles before it goes on.
                         The harness looks LATE: class A (a timer that
                         must not have fired yet) goes red.
  MAUX_GATE_RACE=early   no lag; every prompt/property POLL steps a tenth
                         of its usual quantum (EARLY_DIV) and gets ten
                         times the iterations, so the total timeout is
                         unchanged. The harness acts as soon as it can:
                         class B (a fixture that is not ready yet) goes
                         red.

The key drain in V.t / Clock.typ / Term.press is deliberately NOT
scaled: shrinking it loses keystrokes, which is a third kind of red.
Fixed-length waits (not polls) are not scaled either.

Every poll loop that wants the knob calls polls(); the type hook lives
in mcp_drive.MCPClient.call_tool. A summary line is printed at exit so a
log shows the knob engaged (a count of zero means a loop was missed).
"""
import atexit
import os
import re
import sys

MODE = os.environ.get('MAUX_GATE_RACE', '')
if MODE not in ('', 'early', 'late'):
    raise SystemExit(f'MAUX_GATE_RACE={MODE!r}: expected "early", "late" '
                     'or unset')

# guest cycles, per armed line (~3 s of guest time). MAUX_GATE_LAG
# overrides it to bisect a site's slack: the smallest lag that turns the
# gate red IS that site's class-A slack (docs/GATE-RACE-1-NOTES.md).
LATE_LAG = int(os.environ.get('MAUX_GATE_LAG', '3000000'))
SITE = int(os.environ.get('MAUX_GATE_SITE', '0'))
EARLY_DIV = 10             # poll quantum divisor
EARLY_FLOOR = 1_000        # never step less than this

# a lone `&`: not `&&`, not `>&`/`<&` (fd duplication), not `&>`
_ARM = re.compile(r'(?<![&<>])&(?![&>])')

_stats = {'armed': 0, 'seen': 0, 'fine_polls': 0, 'lines': []}


def armed_lines(buf, text):
    """Feed `text` into the line buffer `buf` (a one-element list, one per
    client: a Term types a line one key at a time). Returns how many
    complete lines in it armed a background fixture."""
    n = 0
    for ch in text:
        if ch == '\r':
            if _ARM.search(buf[0]):
                n += 1
                _stats['lines'].append(buf[0])
            buf[0] = ''
        else:
            buf[0] += ch
    return n


def late_lag(n_armed):
    """Cycles to step after a `type` that completed `n_armed` arming
    lines (0 outside `late`). MAUX_GATE_SITE=n lags only the n-th arming
    line of the run (1-based), so one site's slack can be bisected alone
    with MAUX_GATE_LAG."""
    if MODE != 'late' or not n_armed:
        return 0
    lag = 0
    for _ in range(n_armed):
        _stats['seen'] += 1
        if SITE and _stats['seen'] != SITE:
            continue
        _stats['armed'] += 1
        lag += LATE_LAG
    return lag


def quantum(n=200_000):
    """The step size of one poll whose usual size is `n`."""
    if MODE != 'early':
        return n
    return max(EARLY_FLOOR, n // EARLY_DIV)


def factor(n=200_000):
    """How many polls replace one usual poll of size `n`."""
    return max(1, n // quantum(n))


def polls(c, max_steps, quantum_=200_000):
    """One iteration per poll: steps the guest by the poll quantum, then
    yields. `max_steps` is the gate's own bound in usual-size polls; in
    `early` it becomes factor() times as many finer ones, so the total
    cycle budget is unchanged.

        for _ in GR.polls(c, 600):
            if pred(V.rows(c)):
                break
        else:
            raise AssertionError(...)
    """
    q = quantum(quantum_)
    for _ in range(max_steps * factor(quantum_)):
        c.call_tool('step', {'cycles': q})
        _stats['fine_polls'] += MODE == 'early'
        yield


def count(n, quantum_=200_000):
    """`n` usual polls as a bound for a loop that steps by hand (pair
    with poll_step)."""
    return n * factor(quantum_)


def poll_step(c, quantum_=200_000):
    """One poll step, for a loop that checks BEFORE it steps."""
    c.call_tool('step', {'cycles': quantum(quantum_)})
    _stats['fine_polls'] += MODE == 'early'


def _summary():
    if MODE == 'late':
        print(f'[gate-race] late: {_stats["seen"]} arming line(s) seen, '
              f'{_stats["armed"]} lagged by +{LATE_LAG} guest cycles',
              file=sys.stderr)
        if os.environ.get('MAUX_GATE_TRACE'):
            for i, ln in enumerate(_stats['lines'], 1):
                print(f'[gate-race]   site {i}: {ln}', file=sys.stderr)
    elif MODE == 'early':
        print(f'[gate-race] early: {_stats["fine_polls"]} polls at 1/'
              f'{EARLY_DIV} of their usual quantum (key drain and fixed '
              f'waits unscaled)', file=sys.stderr)


if MODE:
    atexit.register(_summary)
