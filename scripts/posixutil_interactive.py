#!/usr/bin/env python3
r"""posixutil_interactive.py -- the INTERACTIVE case kind for
check_posixutil.py (docs/POSIX-HARNESS.md).

WHY THIS EXISTS. check_posixutil's ordinary row is "type one command,
redirect its stdout to a file, read the file and `echo $?` back". That
shape cannot watch a program that (a) never exits on its own (`tail
-f`), or (b) stops and asks the person at the keyboard something (`xargs
-p`, `find -ok`). docs/POSIX-GAPS.md sec 6b held those rows red because
the GATE could not observe them, not because the tool was wrong.

THE SHAPE OF A ROW. A row carries a `script`: an ordered list of steps.
The SAME script is run twice and the two results are compared exactly
as every other row is:

  ('wait', b'text')     block until `text` has appeared in the program's
                        output. On the host that is the pty stream; on
                        maux it is the console glass BELOW the echoed
                        command line (a needle that the screen could
                        show before the command ran is no needle --
                        learning:01M3KY2AS0XJ22DY89S7R728GC).
  ('type', b'bytes')    type these bytes at the program. b'\x03' is ^C.
  ('append', 'F', ['line', ...])
                        append lines to file F while the program runs.

and then the program is allowed to finish. The result is
{'stdout': [lines], 'rc': int}: the merged terminal output (what a
person would have SEEN, stdout and stderr and the echo of what they
typed) and the exit status, 128+signo for a signal -- which is also how
maux reports one (docs: `kill signo` ABI, $80|signo).

THE HOST SIDE runs the host binary under a real pty (Python `pty`), so
the program sees a controlling terminal, ISIG delivers a typed ^C as
SIGINT, and a tool that opens /dev/tty (xargs -p) finds one. Its stdin
may be redirected from a file, as `< IN` is on maux, while the tty stays
the controlling terminal. The terminal keeps its default modes, so a
typed answer is echoed and ^C is echoed as "^C" -- the same two things
maux's cooked console does, which is what lets the streams compare
without a normaliser.

ASSERT THE BRANCH, NOT THE BYTES (learning:01M2N39MGAJCG075SDW4XWDFCN).
A row that only compared the final file would pass a tool that never
prompted. Because the compared stream is the merged terminal output, the
prompt text IS in it; and the script's own `wait` steps fail loudly at a
ceiling if the text never arrives.

DO NOT POLL ON A COUNT OR ONE SAMPLE (learnings 01M1AH9XWGC8ZS7HNBJVJ2JHXW,
01M1QY8TDRAX1N92CZQ143Q614). The maux waits require the predicate on two
consecutive polls with an identical region; each has a CYCLE CEILING and
raises with the screen when it is hit. No wait is a fixed cycle budget.
"""
import os
import pty
import select
import signal
import sys
import tempfile
import time

#: wall-clock ceiling for any single host wait or for the program to end.
HOST_CEILING = 20.0


#: a2til keeps ONE process-wide mount table, so two boot groups staging at
#: once collide on the volume name ("a volume named 'BASIC' is already
#: mounted"). check_posixutil's groups run in threads and each stages
#: its image first; it takes this lock around that step. The race was
#: always there -- the hunk is wider than it used to be (more fixtures
#: per group), which is what made it fire (2026-10-08).
import threading
STAGE_LOCK = threading.Lock()


class InteractiveError(RuntimeError):
    pass


# ======================================================================
# step constructors -- tiny, so a row reads as the conversation it is
# ======================================================================
def WAIT(text, nth=1):
    """Block until `text` has appeared `nth` times."""
    return ('wait', text if isinstance(text, bytes) else text.encode(), nth)


def TYPE(data):
    return ('type', data if isinstance(data, bytes) else data.encode())


def APPEND(tag, lines, after=2, burst=False):
    """Append `lines` to file `tag`. On the host that happens at this
    point in the script; on maux, where nothing can type at the shell
    while the program holds the terminal, a pipeline stage started with
    the command (`sh APP | TOOL ...`, see appender_script) sleeps
    `after` seconds and then appends. The maux player checks the
    appended text was NOT yet on the glass when the previous wait
    settled, so a slow start cannot turn the follow path into a
    plain read. burst=True: the guest appends each line with its OWN
    `echo LINE >> F`, back to back (OPEN-RW-1 row R1), instead of one
    `cat APPn >> F` for the whole step."""
    return ('append', tag, list(lines), after, bool(burst))


CTRL_C = b'\x03'


# ======================================================================
# the row constructor -- same dict shape as check_posixutil.C(), plus:
#   script     the steps above
#   redirect   True: the program's stdout goes to OUT (and is compared
#              from the FILE, host-oracled byte for byte); the terminal
#              carries only the prompts. False (default): there is no
#              redirect, the compared "stdout" is the merged terminal
#              output, exactly what a person would have seen.
#   tty_has    substrings the maux terminal stream must contain, in
#              order -- the assertion that the interactive branch ran,
#              hand-authored from the tool's own prompt (use it where
#              the two hosts word the prompt differently, so the
#              terminal stream cannot be host-oracled).
# An `append` step adds the guest appender script as fixture APP.
# ======================================================================
def IR(tool, name, spec, argv, script, *, redirect=False, tty_has=None,
       files=None, dirs=None, predirs=None, stdin=None, results=None,
       hand=None, known_gap=None, reset=None, norm=None):
    files = dict(files or {})
    files.update(appender_files(script))
    return dict(tool=tool, name=name, spec=spec, argv=list(argv),
                files=files, dirs=dirs or {}, predirs=list(predirs or []),
                stdin=stdin, results=list(results or []), post=[],
                hand=hand, known_gap=known_gap, reset=reset, norm=norm,
                meta_equal=[], script=list(script),
                redirect=bool(redirect), tty_has=list(tty_has or []))


# ======================================================================
# stream -> lines
# ======================================================================
def stream_lines(data):
    """A terminal byte stream as rows: CRLF/CR/LF all break a row and
    trailing blanks are dropped from each row and from the end, exactly
    the reduction applied to the maux glass (region_lines)."""
    text = data.decode('latin-1')
    text = text.replace('\r\n', '\n').replace('\r', '\n')
    rows = [r.rstrip() for r in text.split('\n')]
    while rows and not rows[-1]:
        rows.pop()
    return rows


def region_lines(rows):
    """The same reduction for glass rows."""
    out = [r.rstrip() for r in rows]
    while out and not out[-1]:
        out.pop()
    return out


# ======================================================================
# host side
# ======================================================================
def _status(st):
    if os.WIFEXITED(st):
        return os.WEXITSTATUS(st)
    if os.WIFSIGNALED(st):
        return 128 + os.WTERMSIG(st)
    return None


def host_run(argv, steps, workdir, *, stdin_path=None, stdout_path=None,
             env=None, ceiling=HOST_CEILING):
    """Run `argv` under a pty in `workdir` and play `steps`. Returns
    {'stdout': [rows], 'rc': int, 'raw': bytes}. With `stdout_path` the
    program's fd 1 is that file (the row's `> OUT`): the pty then carries
    only stderr, the typed echo and what the program writes to
    /dev/tty, and 'stdout' is still the TERMINAL stream -- the caller
    reads the file."""
    child_env = dict(os.environ, LC_ALL='C')
    if env:
        child_env.update(env)
    pid, fd = pty.fork()
    if pid == 0:                                   # child
        try:
            os.chdir(workdir)
            if stdin_path is not None:
                f = os.open(stdin_path, os.O_RDONLY)
                os.dup2(f, 0)
                os.close(f)
            if stdout_path is not None:
                f = os.open(stdout_path,
                            os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
                os.dup2(f, 1)
                os.close(f)
            os.execve(argv[0], argv, child_env)
        finally:
            os._exit(127)
    buf = bytearray()
    done = False

    def pump(seconds):
        nonlocal done
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.02)
            if not r:
                continue
            try:
                d = os.read(fd, 4096)
            except OSError:
                done = True
                return
            if not d:
                done = True
                return
            buf.extend(d)

    try:
        for step in steps:
            kind = step[0]
            if kind == 'wait':
                end = time.time() + ceiling
                while bytes(buf).count(step[1]) < step[2] and not done:
                    if time.time() > end:
                        raise InteractiveError(
                            f'host wait for {step[1]!r} hit the '
                            f'{ceiling}s ceiling; stream so far: '
                            f'{bytes(buf)!r}')
                    pump(0.05)
                pump(0.15)      # let a following write land
            elif kind == 'type':
                os.write(fd, step[1])
                pump(0.25)
            elif kind == 'append':
                path = os.path.join(workdir, step[1])
                with open(path, 'ab') as f:
                    f.write(''.join(ln + '\n' for ln in step[2])
                            .encode('latin-1'))
                pump(0.25)
            else:
                raise InteractiveError(f'unknown step {step!r}')
        # let the program finish on its own
        end = time.time() + ceiling
        st = None
        while st is None:
            pump(0.05)
            p, s = os.waitpid(pid, os.WNOHANG)
            if p:
                st = s
            elif time.time() > end:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
                raise InteractiveError(
                    f'host program did not end within {ceiling}s; '
                    f'stream: {bytes(buf)!r}')
        pump(0.2)
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
    return {'stdout': stream_lines(bytes(buf)), 'rc': _status(st),
            'raw': bytes(buf)}


# ======================================================================
# maux side
# ======================================================================
#: Poll slice, in CPU cycles, and the ceiling (in polls) for any one wait.
#: 100k cycles x 600 polls = 60M cycles; a wait that has not held by then
#: has hit a bug, and fails with the glass in the message.
POLL_CYCLES = 100_000
WAIT_POLLS = 600

#: filled by play(), read back by check_posixutil: casetag -> result
LIVE = {}


def appender_script(steps):
    """The guest-side script for a row's `append` steps: sleep, then
    append, in order. maux's sh refuses a background job whose output is
    not redirected and cannot pipe a subshell, but it runs a script
    file as a pipeline stage, so the row starts `sh APP | TOOL ...`;
    both stages are in the foreground group and a typed ^C reaches
    them both. Each step's lines are a fixture of their own (APP1,
    APP2, ...; appender_files) appended with ONE `cat >>`, so a step is
    a single open/write/close; a burst=True step is one `echo LINE >> F`
    per line instead.

    THE WINDOW IS CLOSED (OPEN-RW-1, stage A). ProDOS will not share a
    file between a writer and another opener, and tail -f holds F open
    for its once-a-second poll (a few ticks), so a `>>` landing inside
    that hold used to fail its open with MLI $50 and the shell said
    "cannot redirect" and lost the line (observed 2026-10-08; made
    DETERMINISTIC on 2026-10-21 when WAIT-1's cheaper wait changed the
    run-queue order). The shell now retries a $50 open for `>` and `>>`
    (src/bin/shsgrw.s: one tick between tries, at most 30, ^C ends it).
    The WAIT-1 workaround that stood here -- up to four `cat >> F`
    tries chained with `||` and `false`, and the appender's stderr
    sent to /dev/null so the message did not reach the compared
    stream -- is gone: a refusal would now show on the glass and fail
    the row, which is the proof that the shell, not the harness,
    absorbs the collision. A LONG holder still fails, after the
    bound; this closes the transient case only."""
    lines = []
    n = 0
    for st in steps:
        if st[0] != 'append':
            continue
        n += 1
        lines.append('sleep %d' % st[3])
        if len(st) > 4 and st[4]:
            lines += ['echo %s >> %s' % (ln, st[1]) for ln in st[2]]
        else:
            lines.append('cat APP%d >> %s' % (n, st[1]))
    return lines


def appender_files(steps):
    """APP (the script) and APP1.. (each step's lines) as fixtures."""
    script = appender_script(steps)
    if not script:
        return {}
    files = {'APP': script}
    n = 0
    for st in steps:
        if st[0] == 'append':
            n += 1
            files['APP%d' % n] = list(st[2])
    return files


def command_prefix(case):
    return 'sh APP | ' \
        if any(s[0] == 'append' for s in case['script']) \
        else ''


def play(client, casetag, cmd, case, V):
    """Run `case['script']` against the command already typed at the
    shell prompt. `cmd` is the exact text that was typed (the anchor:
    everything the program shows is on the glass BELOW its echo).
    Returns {'stdout': rows | None, 'tty': rows}; 'stdout' is None for a
    row that redirects stdout to OUT (the file is read back as usual)."""
    anchor = '$ ' + cmd
    if len(anchor) > 78:
        raise InteractiveError(
            f'{casetag}: command line {anchor!r} is wider than the 80-col '
            f'glass -- shorten the row so the echo cannot wrap')

    def region(rs):
        idx = None
        for i, r in enumerate(rs):
            if r.rstrip() == anchor:
                idx = i
        if idx is None:
            return None
        return region_lines(rs[idx + 1:])

    def poll():
        client.call_tool('step', {'cycles': POLL_CYCLES})
        rs = V.rows(client)
        return rs, region(rs)

    def back_at_prompt(rs):
        nb = [r for r in rs if r.strip()]
        return bool(nb) and nb[-1].strip() == '$'

    def settle(pred, label, ends_ok=False):
        held = None
        ended = 0
        rs, reg = [], None
        for _ in range(WAIT_POLLS):
            rs, reg = poll()
            if reg is not None and pred(reg, rs):
                txt = '\n'.join(reg)
                if held == txt:
                    return reg
                held = txt
            else:
                held = None
                # the program is gone (shell prompt back) and the text
                # never came: fail now, not 60M cycles from now
                ended = ended + 1 if (not ends_ok and reg is not None
                                      and back_at_prompt(rs)) else 0
                if ended >= 2:
                    blob = '\n'.join(f'{i:2d}|{r.rstrip()}'
                                     for i, r in enumerate(rs))
                    raise AssertionError(
                        f'{casetag}: the program ended (prompt is back) '
                        f'before {label}; screen was:\n{blob}')
        blob = '\n'.join(f'{i:2d}|{r.rstrip()}' for i, r in enumerate(rs))
        raise AssertionError(f'{casetag}: timed out waiting for {label} '
                             f'({WAIT_POLLS} x {POLL_CYCLES} cycles); '
                             f'screen was:\n{blob}')

    last = []
    for step in case['script']:
        kind = step[0]
        if kind == 'wait':
            needle = step[1].decode('latin-1')
            nth = step[2]
            last = settle(
                lambda reg, rs, n=needle, k=nth:
                    '\n'.join(reg).count(n) >= k,
                f'{needle!r} x{nth} in the output')
        elif kind == 'type':
            V.t(client, step[1].decode('latin-1'))
        elif kind == 'append':
            first = step[2][0]
            if first in '\n'.join(last).split():
                raise AssertionError(
                    f'{casetag}: {first!r} was on the glass BEFORE the '
                    f'append step -- the guest appender fired before the '
                    f'previous wait settled, so this row would not '
                    f'exercise the follow path. Raise after=.')
        else:
            raise InteractiveError(f'unknown step {step!r}')

    def at_prompt(reg, rs):
        nb = [r for r in rs if r.strip()]
        return bool(nb) and nb[-1].strip() == '$' and len(reg) >= 1

    reg = settle(at_prompt, 'the shell prompt after the program ended',
                 ends_ok=True)
    # reg's last row is the prompt itself; the program's output is above
    out = [r for r in reg[:-1]]
    while out and not out[-1].strip():
        out.pop()
    res = {'stdout': None if case.get('redirect') else out, 'tty': out}
    LIVE[casetag] = res
    return res


def extra_diffs(case, got):
    """Assertions beyond stdout/rc: the maux terminal stream must carry
    the strings the row's `tty_has` lists, in order -- the harness
    decides which branch ran, so the prompt text is asserted from the
    tool's own output (learning:01M2N39MGAJCG075SDW4XWDFCN)."""
    want = case.get('tty_has') or []
    if not want:
        return []
    blob = '\n'.join(got.get('tty') or [])
    at = 0
    for w in want:
        j = blob.find(w, at)
        if j < 0:
            return [f'tty stream lacks {w!r} (in order): {blob!r}']
        at = j + len(w)
    return []


# ======================================================================
# CLI: measure a host binary, e.g. for the notes
#   posixutil_interactive.py MEASURE <json>
# where json = {"argv":[...], "steps":[[kind, ...]], "files":{name:text},
#               "stdin":"IN"}
# ======================================================================
def _main(argv):
    import json
    spec = json.loads(argv[0])
    wd = tempfile.mkdtemp()
    for name, text in spec.get('files', {}).items():
        os.makedirs(os.path.dirname(os.path.join(wd, name)) or wd,
                    exist_ok=True)
        with open(os.path.join(wd, name), 'w') as f:
            f.write(text)
    steps = []
    for s in spec['steps']:
        if s[0] == 'wait':
            steps.append(('wait', s[1].encode().decode('unicode_escape')
                          .encode('latin-1'), s[2] if len(s) > 2 else 1))
        elif s[0] == 'type':
            steps.append(('type', s[1].encode().decode('unicode_escape')
                          .encode('latin-1')))
        else:
            steps.append(('append', s[1], s[2], 3))
    sp = spec.get('stdin')
    r = host_run(spec['argv'], steps, wd,
                 stdin_path=os.path.join(wd, sp) if sp else None)
    print(json.dumps({'rc': r['rc'], 'stdout': r['stdout'],
                      'raw': r['raw'].decode('latin-1')}))
    return 0


if __name__ == '__main__':
    raise SystemExit(_main(sys.argv[1:]))
