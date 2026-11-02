#!/usr/bin/env python3
"""check_shfd.py -- descriptors across a subshell, and `read <&N`
(`make check-shfd`, docs/SH-FD.md, docs/SH-FD-NOTES.md).

Boots the play image and types each row at the shell, the
check_devpath.py idiom (check_devfs's helpers are imported).  Every
row opens fd 3 (sometimes 4) with `exec` on a file that is neither
the shell's script nor fd 0 -- learning:01M0KCTSJTXA1VVNJN535BWZZZ:
a `read` row is blind otherwise -- and closes it again at the end,
so no row sees another's descriptors.

ORACLE.  A row marked ORACLE is also run, line for line, by the host's
`dash` (script on its own fd, stdin /dev/null) in a scratch directory
holding the same files, and maux must print exactly what dash prints.
dash and bash 5 must agree with each other first (learning:
01M12T689RB7QCEY599F48RY2X: macOS /bin/sh is bash 3.2, so it is
never the oracle).  A row marked WANT has no POSIX twin -- it pins a
deliberate, loud refusal -- and carries its expected output.

Rows:
  A. a subshell inherits the descriptors the user opened
     (XCU 2.12): `( )`, `$( )`, a plain external command, a nested
     sh, and a group inside a nested sh; a group's `>&3`; two fds;
     the offset shared with the parent; a CLOSED fd is not granted
     (a stale grant would hand the body pipe to the child and hang).
  B. `read` honours `<&N` (XCU `read`): the line comes from fd N, not
     the tty or the script; the offset advances; EOF leaves the
     variable alone; the splitting rules are unchanged.
  C. the twins: `.` and the compound commands (`{ }`, `while`, `for`,
     `if`, `case`) with `<&3` (rows C1-C6); a redirect ON a group
     that would take the group's own script pipe is refused, loudly
     (rows D).

Teeth: `--play build-of-main/play.po` must read rows A, B, C and D red
on the base build (shown in docs/SH-FD-NOTES.md).

ASCII only.  Exit 0 green, 1 red (listed), 2 rig problem.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_devfs as D  # noqa: E402
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _find_shells():
    """(dash, bash5) on this host: the Mac's Homebrew bash, or a bash
    whose major version is 5+ on PATH (the Linux box). macOS /bin/sh and
    /bin/bash are bash 3.2 and are never the oracle."""
    dash = shutil.which('dash')
    bash = None
    for cand in ('/opt/homebrew/bin/bash', shutil.which('bash')):
        if cand and os.path.exists(cand):
            out = subprocess.run([cand, '-c', 'echo ${BASH_VERSINFO[0]}'],
                                 stdout=subprocess.PIPE, text=True,
                                 check=False).stdout.strip()
            if out.isdigit() and int(out) >= 5:
                bash = cand
                break
    return dash, bash


DASH, BASH5 = _find_shells()

#: the files every row works on, written at the start (maux lines;
#: dash runs the same ones).  f1: two lines; f2 likewise; f3 one line
#: of four words (the `read` splitting rows); s1: a one-line script.
FIXTURE = [
    'cd /tmp',
    'echo L1 > f1', 'echo L2 >> f1',
    'echo M1 > f2', 'echo M2 >> f2',
    'echo a b c d > f3',
    'echo cat > s1',
    'echo SENT > dd',
]

def script(*text, status=False):
    """The lines that write `text` (one script line per argument) to the
    script c2 and run it in a nested sh, fd 3 on f1 around it.  Each
    typed line stays inside the 40-column glass (typed() asserts it)."""
    first = ["echo '" + text[0] + "' > c2"]
    rest = ["echo '" + t + "' >> c2" for t in text[1:]]
    run = ['sh ./c2'] + (['echo S$?'] if status else [])
    return ['exec 3<f1'] + first + rest + run + ['exec 3<&-']


def sscript(*text):
    """DUPFD-1 rows: fd 3 is NOT opened.  The lines go to the script
    c2 and run as `sh ./c2 < dd` -- fd 0 is the file dd, a sentinel
    ("SENT") that no dup of fd 3 may ever show through: a command that
    wrongly keeps the fd 0 it inherited prints it."""
    first = ["echo '" + text[0] + "' > c2"]
    rest = ["echo '" + t + "' >> c2" for t in text[1:]]
    return first + rest + ['sh ./c2 < dd']


BADFD = 'sh: 3: bad file descriptor'

# (label, lines, want) -- want None = ORACLE (dash decides), else a list.
ROWS = [
    # ---- A. inheritance -------------------------------------------
    ('A1 group', ['exec 3<f1', '(cat <&3)', 'exec 3<&-'], None),
    ('A2 group shares the offset',
     ['exec 3<f1', '(read V <&3; echo in$V)', 'cat <&3', 'exec 3<&-'],
     None),
    ('A3 group, two fds',
     ['exec 3<f1', 'exec 4<f2', '(cat <&3; cat <&4)',
      'exec 3<&-', 'exec 4<&-'], None),
    ('A4 group writes fd 3',
     ['exec 3>o1', '(echo hi >&3)', 'echo M', 'exec 3>&-', 'cat o1'],
     None),
    ('A5 command substitution',
     ['exec 3<f1', 'echo $(cat <&3)', 'exec 3<&-'], None),
    ('A6 external command (nested sh)',
     ['exec 3<f1', "echo 'cat <&3' | sh", 'exec 3<&-'], None),
    ('A7 group inside a nested sh',
     ['exec 3<f1', "echo '(cat <&3)' | sh", 'exec 3<&-'], None),
    ('A8 a closed fd is not granted',
     ['exec 3<f1', 'exec 3<&-', '(echo hi)', 'echo a$(echo b)'], None),
    # A STALE grant hands the child whatever sh later opens on that
    # number: here `.` holds the sourced file on fd 3, so a stale bit 3
    # lets the group's `cat <&3` read (and swallow) the script itself.
    # DUPFD-1: with the fd really closed the group's `cat <&3` is now
    # refused (it used to be skipped in silence), so the row's answer
    # is the child's diagnostic plus `end`; a stale grant would show
    # neither (no refusal, and cat swallows the script).
    ('A8b a closed fd stays closed (no stale grant)',
     ['exec 3<f1', 'exec 3<&-', "echo '(cat <&3 >/dev/null)' > s2",
      "echo 'echo end' >> s2", '. ./s2'],
     ['sh: 3: bad file descriptor', 'end']),
    ('A9 a pipeline stage',
     ['exec 3<f1', 'cat <&3 | cat', 'exec 3<&-'], None),
    # ---- B. read ---------------------------------------------------
    ('B1 read <&3',
     ['exec 3<f1', 'read V <&3', 'echo V=$V', 'cat <&3', 'exec 3<&-'],
     None),
    ('B2 read splits',
     ['exec 3<f3', 'read A B <&3', 'echo $A:$B', 'exec 3<&-'], None),
    ('B3 read at EOF fails',
     ['exec 3<f1', 'cat <&3 > /dev/null', 'read V <&3', 'echo S$?',
      'exec 3<&-'], None),
    ('B4 while read <&3',
     ['exec 3<f1', 'while read V <&3; do echo w$V; done',
      'exec 3<&-'], None),
    ('B5 read 0<&3',
     ['exec 3<f1', 'read V 0<&3', 'echo V=$V', 'exec 3<&-'], None),
    # ---- C. the twins ----------------------------------------------
    # The compound forms need a SEEKABLE script (docs/SH-FEATURES.md
    # sec 18: sh scans to the terminator, opens the redirect, re-reads
    # the head), so each is a one-line script run by a nested `sh`.
    # That nested sh is itself the inheritance test: fd 3 reaches it
    # through the grant.
    ('C1 { } <&3', script('{ cat; } <&3'), None),
    ('C2 while ... done <&3',
     script('while read V; do', 'echo w$V', 'done <&3'), None),
    ('C3 for ... done <&3',
     script('for i in a; do', 'cat', 'done <&3'), None),
    ('C4 if ... fi <&3', script('if true; then', 'cat', 'fi <&3'),
     None),
    ('C5 case ... esac <&3',
     script('case x in', 'x) cat;;', 'esac <&3'), None),
    ('C6 read inside a <&3 loop',
     script('while read V; do', 'read W', 'echo $V$W', 'done <&3'),
     None),
    ('C6b the construct does not close the user fd',
     script('if true; then', 'read V', 'echo $V', 'fi <&3', 'cat <&3'),
     None),
    ('C7 . FILE <&3 refused, nothing sourced',
     ['exec 3<f1', '. ./s1 <&3', 'echo S$?', 'cat <&3', 'exec 3<&-'],
     ['sh: builtin: redirection not supported', 'S1', 'L1', 'L2']),
    ('C8 eval cat <&3 refused (the existing rule)',
     ['exec 3<f1', 'eval cat <&3', 'echo S$?', 'cat <&3', 'exec 3<&-'],
     ['sh: builtin: redirection not supported', 'S1', 'L1', 'L2']),
    ('C9 command cat <&3',
     ['exec 3<f1', 'command cat <&3', 'exec 3<&-'], None),
    # SH-SEQ B (the C10 pin, replaced as it asked): the one-line
    # `case ... esac <&3` in a SEEKABLE script is applied like every
    # other terminator redirect (sec 18), against dash and bash 5.
    # The TYPED form cannot be rescanned (no file to seek): it runs the
    # body, then refuses the redirect loudly -- pinned in check-shseq
    # (row B13) with the other typed-construct gaps.
    ('C10 one-line case ... ;;esac<&3',
     script('case x in *) cat;;esac<&3'), None),
    # ---- E. the stack ----------------------------------------------
    # Every `jmp MAINLOOP` out of a jsr chain (a loop-back, a rescan)
    # used to strand 4 bytes of return addresses; ~60 of them wrapped
    # the 256-byte process stack, where the kernel's frame indexing
    # leaves page 1.  110 loop-backs in one script, then a command.
    ('E1 110 loop-backs do not eat the stack',
     ["echo 'A=\"1 2 3 4 5 6 7 8 9 0\"' > c3",
      "echo 'for j in $A; do' >> c3",
      "echo 'for i in $A; do' >> c3",
      "echo 'echo $i > /dev/null' >> c3", "echo 'done' >> c3",
      "echo 'done' >> c3",
      "echo 'echo ok' >> c3", 'sh ./c3'], ['ok']),
    # ---- S. a dup from a closed fd fails (docs/DUPFD-1.md) ---------
    # Status 1 is a maux ruling (bash 1, dash 2), so no oracle: each row
    # carries its semantic answer -- the diagnostic names the fd, $? is
    # nonzero, the command printed nothing (no SENT, no echoed x).
    ('S1 cat <&3, fd 3 closed',
     sscript('cat <&3', 'echo S$?'), [BADFD, 'S1']),
    ('S2 cat <&3 | cat (a pipe takes fd 3)',
     sscript('cat <&3 | cat', 'echo S$?'), [BADFD, 'S1']),
    ('S2b cat <&3 > oF (oF stays absent)',
     sscript('cat <&3 > oF', 'echo S$?', 'echo oF*'),
     [BADFD, 'S1', 'oF*']),
    ('S3 /bin/echo x >&3',
     sscript('/bin/echo x >&3', 'echo S$?'), [BADFD, 'S1']),
    ('S3b cat 3>&- 0<&3 (closed earlier in the list)',
     sscript('cat 3>&- 0<&3', 'echo S$?'), [BADFD, 'S1']),
    # fd 3 IS the user's here, so only the close earlier in the same
    # list makes `0<&3` bad -- S3b alone cannot tell (fd 3 was never
    # held).  f1 must come out unread: the cat after reads it whole.
    ('S3e exec 3<f1; cat 3>&- 0<&3 (closed in the list)',
     sscript('exec 3<f1', 'cat 3>&- 0<&3', 'echo S$?', 'cat <&3'),
     [BADFD, 'S1', 'L1', 'L2']),
    ('S3c a group: (cat) 2>&3',
     sscript('(cat) 2>&3', 'echo S$?'), [BADFD, 'S1']),
    ('S3d the next line still runs',
     sscript('cat <&3', 'echo next'), [BADFD, 'next']),
    # A list sh's own check cannot see: fd 1 closed by `exec`, and
    # fds 0-2 count as held (DUP_CHECK), so the KERNEL refuses it
    # (phase K) and sh must say so, not "command not found".
    ('S5 kernel backstop: exec 1>&-; cat 2>&1',
     sscript('exec 1>&-', 'cat 2>&1', 'echo S$? >&2'),
     ['sh: bad file descriptor', 'S1']),
    ('S5b kernel backstop, a group',
     sscript('exec 1>&-', '(cat) 2>&1', 'echo S$? >&2'),
     ['sh: bad file descriptor', 'S1']),
    ('S4e positive: cat 4>oG 1>&4 (the first file redirect is held)',
     sscript('cat 4>oG 1>&4', 'cat oG', 'echo S$?'), ['SENT', 'S0']),
    ('S4 positive: exec 3<f1; cat <&3',
     sscript('exec 3<f1', 'cat <&3', 'echo S$?'), ['L1', 'L2', 'S0']),
    ('S4b positive: exec 3<f1; cat <&3 | cat',
     sscript('exec 3<f1', 'cat <&3 | cat'), ['L1', 'L2']),
    ('S4c positive: cat 4<f1 0<&4 (a FILE record is held)',
     sscript('cat 4<f1 0<&4', 'echo S$?'), ['L1', 'L2', 'S0']),
    ('S4d positive: cat 3>&1 0<&3 reads the dup of fd 1',
     sscript('cat 3>&0 0<&3', 'echo S$?'), ['SENT', 'S0']),
    # ---- D. a redirect that would take the group's script pipe -----
    ('D4 (cat) <<EOF refused',
     script('(cat) <<EOF', 'HX', 'EOF', 'echo a', status=True),
     ['sh: (): no redirect|pipe', 'a', 'S0']),
    ('D5 read V <<EOF refused',
     script('read V <<EOF', 'HY', 'EOF', 'echo V=$V', status=True),
     ['sh: read: reads fd 0 -- < FILE not applied', 'V=', 'S0']),
    # KNOWN GAP PIN: a here-doc on a construct's terminator is not
    # applied (only a file or a `<&N` is, sec 18); it is refused at the
    # terminator, loudly, after the body ran.
    ('D6 { } <<EOF refused (known gap)',
     script('{ echo hi; } <<EOF', 'HW', 'EOF', status=True),
     ['hi', 'sh: redirection without a command', 'S1']),
    ('D1 (cat) <&3 refused, f1 untouched',
     ['exec 3<f1', '(cat) <&3', 'echo S$?', 'cat <&3', 'exec 3<&-'],
     ['sh: (): no redirect|pipe', 'S1', 'L1', 'L2']),
    ('D2 (cat) 0<&3 refused, f1 untouched',
     ['exec 3<f1', '(cat) 0<&3', 'echo S$?', 'cat <&3', 'exec 3<&-'],
     ['sh: (): no redirect|pipe', 'S1', 'L1', 'L2']),
    ('D3 (cat) <f1 refused (the existing rule)',
     ['(cat) < f1', 'echo S$?'],
     ['sh: (): no redirect|pipe', 'S1']),
]


def host_run(shell, lines, tmp):
    """Run `lines` as a script file under `shell`; return stdout+stderr
    rows.  The fixture files are rewritten per call.  A nested
    `sh ...` in a row is a function that runs `shell` ITSELF (SH-G21
    F4: it used to run dash under both)."""
    script = os.path.join(tmp, 'row.sh')
    with open(script, 'w') as fh:
        fh.write('sh() { %s "$@"; }\n' % shell)
        fh.write('\n'.join(FIXTURE[1:] + lines) + '\n')
    r = subprocess.run([shell, script], cwd=tmp, stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       timeout=30, check=False)
    return [x for x in r.stdout.decode('latin-1').split('\n') if x != '']


def rig_selftest(failures):
    """The oracle rig must really ask both shells for a NESTED `sh`:
    the canary writes a one-line script and runs it with `sh ./cn`; it
    prints $BASH_VERSION, or `dash` where unset.  With the old
    `sh() { dash; }` shim both print `dash`.  Host-only, runs first."""
    import tempfile
    import shutil
    tmp = tempfile.mkdtemp(prefix='maux-rigfd-')
    try:
        lines = ["echo 'echo ${BASH_VERSION-dash}' > cn", 'sh ./cn']
        d = host_run(DASH, lines, tmp)
        b = host_run(BASH5, lines, tmp)
        if d != ['dash'] or not b or b == ['dash']:
            failures.append(
                f'RIG selftest: a nested sh ran as dash {d!r} / bash 5 '
                f'{b!r}; the oracle is not asking both shells')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def oracle(tmp, lines, failures, label):
    d = host_run(DASH, lines, tmp)
    b = host_run(BASH5, lines, tmp)
    if d != b:
        failures.append(f'RIG {label}: dash {d!r} and bash5 {b!r} '
                        f'disagree -- the oracle is not usable')
    return d


def unwrap(rows, cols=40):
    """Re-join a line the 40-column console wrapped (a row of exactly
    `cols` characters continues on the next)."""
    out, cur = [], ''
    for r in rows:
        cur += r
        if len(r) < cols:
            out.append(cur)
            cur = ''
    if cur:
        out.append(cur)
    return out


def typed(client, line, label, failures):
    """Type one line; if it never returns to the prompt (a builtin
    reading the tty: the very symptom), say so, send ^D, recover."""
    assert len(line) <= 38, f'{label}: {line!r} wraps the 40-column glass'
    mine = []
    out = D.run_cmd(client, line + '\r', label, mine, max_steps=700)
    if mine:
        failures.append(f'{label}: {line!r}: the shell never came back '
                        f'(reading the tty?)')
        for key in ('\x04', '\x04', '\x03'):
            client.call_tool('type', {'text': key})
            try:
                D.wait_for_screen(client, D.prompt_ready, 'recover',
                                  max_steps=300)
                break
            except RuntimeError:
                continue
        return None
    return unwrap(out)


def run_rows(client, tmp, failures, only=None):
    for line in FIXTURE:
        typed(client, line, 'fixture', failures)
    for label, lines, want in ROWS:
        if only and not label.startswith(only):
            continue
        if want is None:
            want = oracle(tmp, lines, failures, label)
        got = []
        for line in lines:
            out = typed(client, line, label, failures)
            if out is None:
                got = None
                break
            got.extend(out)
        # a red row must not leave its descriptors for the next one
        for line in ('exec 3<&-', 'exec 4<&-'):
            typed(client, line, label + ' cleanup', [])
        if got is None:
            continue
        D.assert_eq(label, got, want, failures)


def run(play, failures, only=None):
    tmp = tempfile.mkdtemp(prefix='maux-shfd-')
    try:
        boot = os.path.join(tmp, 'play.po')
        shutil.copy(play, boot)
        env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
        client = MCPClient([SUPERVISOR], env)
        try:
            client.initialize()
            client.call_tool('reset', {'backend': 'fast'})
            r = client.call_tool('mount_disk', {'path': boot, 'unit': 1})
            if r.get('ok') is False:
                raise RuntimeError(f'mount_disk(unit 1) failed: {r}')
            for addr, val in ((D.PT_F40_ADDR, D.PT_F40_MAG1),
                              (D.PT_F40B_ADDR, D.PT_F40_MAG2)):
                client.call_tool('poke', {'addr': addr, 'bytes': [val],
                                          'bank': 'main'})
            D.wait_for_screen(client, D.prompt_ready, 'shell prompt')
            work = os.path.join(tmp, 'host')
            os.mkdir(work)
            run_rows(client, work, failures, only)
        finally:
            client.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--play', default=os.path.join(ROOT, 'build',
                                                   'play.po'))
    ap.add_argument('--rows', default=None,
                    help='run only the rows whose label starts with this '
                         '(teeth_dupfd_sh.py uses S)')
    args = ap.parse_args()
    play = os.path.abspath(args.play)
    if not os.path.exists(play):
        print(f'check-shfd: {play} missing -- make play-image')
        return 2
    for name, tool in (('dash', DASH), ('bash 5+', BASH5)):
        if not tool:
            print(f'check-shfd: oracle {name} missing on this host')
            return 2
    failures = []
    rig_selftest(failures)
    if failures:
        print(f'[check-shfd] FAIL: {failures[0]}')
        return 1
    try:
        run(play, failures, args.rows)
    except RuntimeError as exc:
        failures.append(str(exc))
    if failures:
        print(f'[check-shfd] FAIL: {len(failures)} row(s)')
        for x in failures:
            print(f'  - {x}'.replace('\n', '\n    '))
        return 1
    print('[check-shfd] PASS: descriptors cross a subshell; read and the '
          'compound commands honour <&N')
    return 0


if __name__ == '__main__':
    sys.exit(main())
