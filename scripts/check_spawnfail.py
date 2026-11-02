#!/usr/bin/env python3
"""check_spawnfail.py -- every program that spawns must say WHY a spawn
was refused (`make check-spawnfail`).

THE DEFECT. `sh` has said `sh: no more processes` since dcc16dc5, but it
is not the only program that spawns. Twelve utilities call SC_SPAWN, each
with its own reporting, and audited on 2026-10-31 they said: nothing at
all (`chvt` never tested the carry: the user was switched to a console
with no shell, exit 0), `cannot execute` / `exec failed` / `cannot run
pager` / `cannot invoke utility` (a verdict about a FILE that was fine,
on a machine whose process table was full). A user told "cannot execute"
goes and looks at the file. Since da84271c spawn()'s ERR_NOMEM means bank
exhaustion and nothing else, so naming it is now TRUE.

THE RIG. Boot a private copy of build/play.po, fill the process table
with `sleep 600 &` until the shell reports a refusal, then free exactly
ONE bank (`fg`, ^C). One free bank is the whole trick: the program under
test takes it, so it RUNS, and its own child is the spawn that is
refused. (A completely full table would test nothing: the program under
test could not start.)

ROWS. One per spawner, each asserting the program-prefixed message and
the exit status: 126 for env nohup timeout xargs ("found but could
not be run", per their man pages), 1 for the rest:

  chvt     `chvt 2 > /dev/null` (so the display stays and the message
           can be read), and, LAST, the real `chvt 2`: the glass still
           moves (the VT behaviour is unchanged and is the operator's
           question, not this gate's -- see docs/SPAWNFAIL-AUDIT.md)
  env nohup time timeout xargs find make man
  more     the `!cmd` escape, which prints on the status line

EX IS NOT HERE, ON PURPOSE. ex's whole diagnostic channel is the ed `?`
(ED_ERR), and in script mode it is silent. Naming a cause needs a message
facility ex does not have; it is reported, not forced.

Plus a static row: spawnwhy.s restates ERR_NOMEM/ERR_NFILE rather than
putting the whole kernel errno table (which defines ERR_SRCH at the same
byte as ERR_2BIG) into a dozen programs, so the restated values are
compared with inc/errno.krn.equ here.

Teeth: against the code of 8fcfd57e (the base) every dynamic row is RED;
see docs/SPAWNFAIL-AUDIT.md for the run.

ASCII only.
"""
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import convert, prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(HERE)
TAG = '[check-spawnfail]'
NOPROC = 'no more processes'


def rows(client):
    r = client.call_tool('screen_text', {})
    return r.get('merged') or r.get('main', [])


def blob(rs):
    return '\n'.join(r.rstrip() for r in rs)


def step(client, n=1, cyc=200_000):
    for _ in range(n):
        client.call_tool('step', {'cycles': cyc})


def type_(client, text):
    client.call_tool('type', {'text': text})


def at_prompt(rs):
    nb = [r for r in rs if r.strip()]
    return bool(nb) and re.fullmatch(r'\$( \$)*', nb[-1].strip()) is not None


def wait_for(client, pred, label, max_steps=1500):
    """Poll until pred(rows) holds on TWO consecutive polls (output still
    streaming does not count)."""
    held = False
    rs = []
    for _ in range(max_steps):
        step(client)
        rs = rows(client)
        if pred(rs):
            if held:
                return rs
            held = True
        else:
            held = False
    dump = '\n'.join('%2d|%s' % (i, r.rstrip()) for i, r in enumerate(rs)
                     if r.strip())
    raise AssertionError('timed out waiting for %s; screen:\n%s'
                         % (label, dump))


def rows_below(rs, cmd):
    """Rows between the LAST echo of `cmd` and the final bare prompt;
    None when either is missing."""
    idx = None
    for i, r in enumerate(rs):
        if r.rstrip() == '$ ' + cmd:
            idx = i
    last = None
    for i, r in enumerate(rs):
        if r.strip():
            last = i
    if idx is None or last is None or last <= idx:
        return None
    if rs[last].rstrip() != '$':
        return None
    return [r.rstrip() for r in rs[idx + 1:last]]


def static_row():
    """spawnwhy.s's restated codes must equal errno.krn.equ's."""
    def equ(path, name):
        with open(os.path.join(ROOT, path), errors='replace') as fh:
            m = re.search(r'^' + name + r'\s+equ\s+\$([0-9A-Fa-f]+)',
                          fh.read(), re.M)
        if not m:
            raise AssertionError('%s defines no %s' % (path, name))
        return int(m.group(1), 16)
    bad = []
    for mine, theirs in (('SPW_NOMEM', 'ERR_NOMEM'),
                         ('SPW_NFILE', 'ERR_NFILE')):
        a = equ('src/liba/spawnwhy.s', mine)
        b = equ('inc/errno.krn.equ', theirs)
        if a != b:
            bad.append('%s=$%02X but %s=$%02X' % (mine, a, theirs, b))
    if bad:
        raise AssertionError('; '.join(bad))
    print('%s PASS static: spawnwhy.s SPW_NOMEM/SPW_NFILE match '
          'errno.krn.equ' % TAG)


#: staged on the private image, in BIN/ (the volume root is nearly full)
XARGS_IN = 'BIN/SPFIN'
MAKEFILE = 'BIN/SPFMK'


def stage(disk):
    prodos.mount(disk, replace=True)
    try:
        prodos.write('/mnt/MAUX/' + XARGS_IN,
                     convert.text_from_host(b'1\n', high_bit=True),
                     file_type=0x04, aux_type=0, overwrite=True)
        prodos.write('/mnt/MAUX/' + MAKEFILE,
                     convert.text_from_host(b'all:\n\tsleep 1\n',
                                            high_bit=True),
                     file_type=0x04, aux_type=0, overwrite=True)
    finally:
        prodos.unmount('MAUX')


def fill_table(client):
    """Background sleepers until the shell reports a refusal, then free
    exactly one bank. Returns the number of sleepers that started."""
    started = 0
    for _ in range(20):
        type_(client, 'sleep 600 &\r')
        rs = wait_for(client, at_prompt, 'prompt after sleep 600 &')
        if NOPROC in blob(rs):
            break
        started += 1
    else:
        raise AssertionError('twenty sleepers started and the table was '
                             'never full')
    if started < 5:
        raise AssertionError('only %d sleepers started before the first '
                             'refusal' % started)
    # one bank back: foreground the newest sleeper and ^C it. Nothing
    # else can spawn now (not even /bin/kill), which is why this is the
    # way. `fg` is a builtin.
    type_(client, 'fg\r')
    step(client, 40)
    type_(client, '\x03')
    wait_for(client, at_prompt, 'prompt after ^C of the foreground sleeper')
    return started


def status_is(client, want):
    type_(client, 'echo $?\r')
    rs = wait_for(client, lambda rs: rows_below(rs, 'echo $?') is not None,
                  'status line')
    got = rows_below(rs, 'echo $?')
    if got != [str(want)]:
        return 'exit status %r, want %d' % (got, want)
    return None


def one_row(client, name, cmd, want, status=1):
    """Run `cmd`; the screen below its echo must hold `want` (the cause
    the kernel gave, with the program's own prefix), and `$?` must be `status`.
    Returns None, or a string saying what was wrong."""
    type_(client, cmd + '\r')
    try:
        rs = wait_for(client, lambda rs: rows_below(rs, cmd) is not None,
                      '%s back at the prompt' % name)
    except AssertionError as exc:
        return str(exc)
    got = rows_below(rs, cmd)
    text = '\n'.join(got)
    if want not in text:
        return 'no %r below `%s`; saw %r' % (want, cmd, got)
    return status_is(client, status)


def row_chvt_switch(client):
    """`chvt 2` with no bank for the shell it wants on console 2: the
    glass STILL MOVES. That is the operator's open question (switch
    back? not switch at all?), so the current behaviour is PINNED here,
    not decided. It is the LAST row because there is no way back: the
    keyboard follows the display, console 2 has no process, and the
    Option-1 chord is serviced in process context -- there is nobody
    to service it (measured: the chord brings nothing back)."""
    type_(client, 'echo ONCON1\r')
    wait_for(client, lambda rs: at_prompt(rs) and 'ONCON1' in blob(rs),
             'marker')
    type_(client, 'chvt 2\r')
    try:
        wait_for(client, lambda rs: 'ONCON1' not in blob(rs),
                 'the glass moving to console 2')
    except AssertionError as exc:
        return 'chvt 2 did not move the glass: ' + str(exc)
    return None


def row_more(client):
    """`more`'s !cmd escape: the status line says the cause."""
    type_(client, 'more DEMO/LONG\r')
    try:
        wait_for(client, lambda rs: '--More--' in blob(rs), 'more paging')
    except AssertionError as exc:
        return str(exc)
    type_(client, '!echo hi\r')
    problem = None
    try:
        wait_for(client, lambda rs: 'more: ' + NOPROC in blob(rs),
                 'more: %s on the status line' % NOPROC, max_steps=400)
    except AssertionError as exc:
        problem = str(exc)
    type_(client, 'q')
    try:
        wait_for(client, at_prompt, 'more quit')
    except AssertionError as exc:
        problem = problem or str(exc)
    return problem


# EXIT STATUS. env, nohup, timeout and xargs return 126 ("found but
# could not be run/invoked": their shipped man pages and POSIX) -- a
# spawn refused for want of a bank is exactly that. time, make, man,
# find, more and chvt have no such contract and return 1.
ROWS = [
    # stdout to /dev/null: the escape sequence goes nowhere, so the
    # display stays here and the message and status can be read.
    ('chvt', lambda c: one_row(c, 'chvt', 'chvt 2 > /dev/null',
                               'chvt: ' + NOPROC)),
    ('env', lambda c: one_row(c, 'env', 'env sleep 1', 'env: ' + NOPROC, 126)),
    ('nohup', lambda c: one_row(c, 'nohup', 'nohup sleep 1 > /dev/null',
                                'nohup: ' + NOPROC, 126)),
    ('time', lambda c: one_row(c, 'time', 'time sleep 1',
                               'time: ' + NOPROC)),
    ('timeout', lambda c: one_row(c, 'timeout', 'timeout 5 sleep 1',
                                  'timeout: ' + NOPROC, 126)),
    ('xargs', lambda c: one_row(c, 'xargs', 'xargs sleep < ' + XARGS_IN,
                                'xargs: ' + NOPROC, 126)),
    ('find', lambda c: one_row(c, 'find',
                               'find DEMO -name LONG -exec sleep 1 {} \\;',
                               'find: ' + NOPROC)),
    ('make', lambda c: one_row(c, 'make', 'make -f ' + MAKEFILE,
                               'make: ' + NOPROC)),
    ('man', lambda c: one_row(c, 'man', 'man more', 'man: ' + NOPROC)),
    ('more', row_more),
    ('chvt-switch', row_chvt_switch),     # LAST: there is no way back
]


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    base = os.path.abspath(sys.argv[1])
    try:
        static_row()
    except AssertionError as exc:
        print('%s FAIL static: %s' % (TAG, exc))
        return 1
    tmp = tempfile.mkdtemp(prefix='maux-spawnfail-')
    disk = os.path.join(tmp, 'spawnfail.po')
    shutil.copyfile(base, disk)
    stage(disk)
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    failures = []
    try:
        client.initialize()
        client.call_tool('reset', {'backend': 'fast', 'aux': 'ramworks'})
        client.call_tool('mount_disk', {'path': disk})
        wait_for(client, lambda rs: any(r.startswith('$') for r in rs),
                 'the shell prompt')
        started = fill_table(client)
        print('%s the table was full after %d sleepers; one bank freed'
              % (TAG, started))
        for name, fn in ROWS:
            try:
                bad = fn(client)
            except AssertionError as exc:
                bad = str(exc)
            if bad:
                failures.append((name, bad))
                print('%s FAIL %s: %s' % (TAG, name, bad))
                # a wedged row must not poison the next one
                type_(client, '\x03')
                step(client, 20)
            else:
                print('%s PASS %s' % (TAG, name))
    finally:
        try:
            client.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        client.close()
        shutil.rmtree(tmp, ignore_errors=True)
    if failures:
        print('%s FAIL: %s' % (TAG, ', '.join(n for n, _ in failures)))
        return 1
    print('%s PASS: all %d spawners name the cause of a refused spawn'
          % (TAG, len(ROWS)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
