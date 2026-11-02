#!/usr/bin/env python3
"""check_shexecloop.py -- `for` takes `do CMD` (`make check-shexecloop`,
docs/SH-EXECLOOP.md, docs/SH-EXECLOOP-NOTES.md).

Two parts, one emulator session each (the check_shmlquote idiom).

PART A  (script rows).  Boots the play image and types each row at the
shell: the row's script is written line by line with typed `echo`, then
`sh ./m` runs it and `echo S$?` reports the status.  Every script ends
in a sentinel line after the loop (`echo END`), so a premature exit is
not a green, and the status is part of the answer.  Every row uses its
OWN scratch file names (F1, F2, ...): a row never sees another's bytes.

ORACLE.  A row with want=None is also run, line for line, by the host's
dash AND bash 5 (macOS /bin/sh is bash 3.2 and is never the oracle);
maux must print what they print, and a RIG line is raised if the two
disagree first.  A row with a WANT list has no POSIX twin -- an alias
(bash needs expand_aliases), uppercase keywords, or a deliberate maux
refusal -- and carries its output.

COUNTERS.  Before and after each row the kernel's buffer cells are read
from the image's own symbol dump (K_IBF_INUSE, K_QUAR_CNT, MLI_BUF_USED,
and the number of used OFT entries): a row that leaves an open file
behind (F held, a leaked buffer) is red by name.

Every typed line is bounded (check_shfd.typed: 140 M guest cycles, then
^D/^C and a named failure), so a hang is a red, never a stalled sweep.

PART B  (the console, text40).  The typed one-line loop and its recall
from history: maux's own output only (the host oracle runs every row as
a script).

Teeth: scripts/teeth_shexecloop.py.  ASCII only.  Exit 0 green, 1 red
(listed), 2 rig problem.
"""
import argparse
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_shfd as F  # noqa: E402
import check_devfs as D  # noqa: E402
import check_shmlquote as M  # noqa: E402
import e2e_term as E  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LISTING = os.path.join(ROOT, 'build', 'MAUXPLAY.SYSTEM_Output.txt')

ORA = None
END = 'echo END'

#: closed-fd probe: a CHILD shell writes to fd 3 and the parent
#: silences it.  (The group form `{ echo x >&3; } 2>/dev/null` is not
#: usable as an `if` condition in maux, and a same-command `2>/dev/null`
#: loses to the bad-fd check, DUPFD-1.)  The child inherits fd 3 only
#: if the loop left it open.
CLOSED3 = ("if sh -c 'echo x >&3' 2>/dev/null; then echo OPEN; "
           "else echo CLOSED; fi")


def row(label, lines, want=ORA, cmds=None, extra=None):
    """A script row.  `lines` is the script (END is appended); `cmds`
    default to running it and reporting the status; `extra` = more
    files, name -> lines."""
    files = {'m': (list(lines) + [END], True)}
    for name, ls in (extra or {}).items():
        files[name] = (list(ls), True)
    return (label, files, cmds or ['sh ./m', 'echo S$?'], want)


def loop(n, tag, inner):
    words = ' '.join(str(i) for i in range(1, n + 1))
    return [f'for i in {words}'] + inner


# reproducer bodies (the brief's, parameterised on the F name)
def repro(fname, do_cmd):
    """7 iterations, `exec 3>>F`, echo $i >&3, close; then F is cat,
    and fd 3 is closed.  do_cmd: True = `do exec ...` on the do line."""
    head = ['for i in 1 2 3 4 5 6 7']
    if do_cmd:
        head += [f'do exec 3>>{fname}']
    else:
        head += ['do', f'exec 3>>{fname}']
    return head + ['echo $i >&3', 'exec 3>&-', 'done',
                   f'cat {fname}', CLOSED3]


ROWS = [
    # ---- the layout of the for head (every shape) -------------------
    row('L1 for / do alone / body / done',
        ['for i in 1 2 3', 'do', 'echo $i', 'done']),
    row('L2 for ; do at the end of the line',
        ['for i in 1 2 3; do', 'echo $i', 'done']),
    row('L3 for / do CMD / done',
        ['for i in 1 2 3', 'do echo $i', 'done']),
    row('L4 the one-line loop in a file',
        ['for i in 1 2 3; do echo $i; done']),
    row('L5 for ; do CMD / done',
        ['for i in 1 2 3; do echo $i', 'done']),
    row('L6 do CMD ; CMD',
        ['for i in 1 2 3', 'do echo $i; echo x', 'done']),
    row('L7 one word',
        ['for i in only; do echo $i; done']),
    row('L8 body goes on over several lines after do CMD',
        ['for i in 1 2; do echo a$i', 'echo b$i', 'done']),
    row('L9 the loop variable after the loop',
        ['for i in 1 2 3; do echo $i; done', 'echo last=$i']),
    row('L10 uppercase FOR/DO CMD (no POSIX twin)',
        ['FOR I IN 1 2 3', 'DO ECHO $I', 'DONE'],
        want=['1', '2', '3', 'END', 'S0']),
    # ---- the reproducer, both shapes ---------------------------------
    row('X1 the brief literal (do exec 3>>F, false, sleep 1) x7',
        ['for i in 1 2 3 4 5 6 7', 'do exec 3>>F1', 'false', 'false',
         'exec 3>&-', 'sleep 1', 'done']),
    row('X2 do exec 3>>F on the do line: F = 1..7, fd 3 closed',
        repro('F2', True)),
    row('X3 do alone, exec on its own line: F = 1..7, fd 3 closed',
        repro('F3', False)),
    # ---- compounds on one line ---------------------------------------
    row('N1 for inside while, one physical line',
        ['I=', 'while test "$I" != xx; do for x in a b; do echo $I$x; '
         'done; I=${I}x; done']),
    row('N2 while inside for, one physical line',
        ['for x in a b; do I=; while test "$I" != xx; do echo $x$I; '
         'I=${I}x; done; done']),
    row('N3 for inside for, one physical line',
        ['for x in a b; do for y in 1 2; do echo $x$y; done; done']),
    row('N4 if / then for / fi, one physical line',
        ['if true; then for x in a b; do echo $x; done; fi']),
    row('N5 do alone outside, a one-line loop inside',
        ['for x in a b', 'do', 'for y in 1 2; do echo $x$y; done',
         'done']),
    row('N6 an inner multi-line loop under a one-line outer',
        ['for x in a b; do for y in 1 2', 'do echo $x$y', 'done',
         'done']),
    # ---- break / continue ---------------------------------------------
    row('B1 break from a do-CMD loop',
        ['for i in 1 2 3; do echo $i; break; done', 'echo after']),
    row('B2 break 2 out of a nested one-line loop',
        ['for i in a b; do for j in 1 2; do echo $i$j; break 2; done; '
         'done', 'echo after']),
    row('B3 break 1 leaves only the inner loop',
        ['for i in a b; do for j in 1 2; do echo $i$j; break; done; '
         'done']),
    row('B4 break after a second command on the do line',
        ['for i in 1 2 3; do echo $i; test $i = 2 && break; done']),
    # the documented v1 gap, pinned as it is today (shrsv2.s CONTFOR)
    row('B5 continue in a for is refused, loudly (documented gap)',
        ['for i in 1 2; do echo $i; continue; echo no; done'],
        # the refusal is exactly 40 columns: the 40-column glass joins
        # it with the next line (F.unwrap), so `no` rides on it
        want=['1', 'sh: continue: not supported in for loopsno',
              '2', 'sh: continue: not supported in for loopsno',
              'END', 'S0']),
    # ---- a redirection on done -----------------------------------------
    row('R1 done > FILE, one-line loop',
        ['for i in 1 2; do echo $i; done > Fo1', 'cat Fo1']),
    row('R2 done > FILE, do alone',
        ['for i in 1 2', 'do', 'echo $i', 'done > Fo2', 'cat Fo2']),
    row('R3 a redirection inside the body',
        ['for i in 1 2; do echo $i >> Fo3; done', 'cat Fo3']),
    # ---- continuation, quotes, aliases ---------------------------------
    row('C1 backslash-continued head',
        ['for i in a b; \\', 'do echo $i; done']),
    row('C2 backslash inside the word list',
        ['for i in a \\', 'b; do echo $i; done']),
    row('C2b three backslash-newlines in the word list (the byte '
        'offset drifts by six)',
        ['for i in a \\', 'b \\', 'c \\', 'd; do echo $i; done']),
    row('C3 a quote-continued word in the list',
        ["for i in 'a", "b' c; do echo \"$i\"; done"]),
    row('C4 backslash-newline inside the body',
        ['for i in a b; do echo \\', '$i; done']),
    row('C5 an alias expanded BEFORE do (no POSIX twin: bash needs '
        'expand_aliases)',
        ["alias e='echo pre;'", 'e for i in a b; do echo $i; done'],
        want=['pre', 'a', 'b', 'END', 'S0']),
    row('C6 an alias before do AND a continued list',
        ["alias e='echo pre;'", 'e for i in a \\', 'b; do echo $i; done'],
        want=['pre', 'a', 'b', 'END', 'S0']),
    row('C7 a command substitution before the for runs ONCE',
        ['A=$(echo SUBST >&2); for x in a b c; do echo $x; done']),
    row('C8 a here-doc in the DO segment replays',
        ['for i in a b; do cat <<EOF', 'x$i', 'EOF', 'done']),
    row('C9 a here-doc BEFORE do is refused, loudly (no POSIX twin)',
        ['cat <<EOF; for i in a b; do echo $i; done', 'body', 'EOF'],
        want=['body', 'sh: for: here-doc before do', 'END', 'S0']),
    # H3: the refusal poisons its own frame and the textual `done`
    # closes THAT frame; the outer loop must neither advance nor close
    row('C10 an inner for refused (here-doc before do) unwinds, the '
        'outer loop is undisturbed',
        ['for x in a b', 'do', 'cat <<EOF; for y in 1 2; do echo $x$y; '
         'done', 'body', 'EOF', 'echo after$x', 'done'],
        want=['body', 'sh: for: here-doc before do', 'aftera', 'body',
              'sh: for: here-doc before do', 'afterb', 'END', 'S0']),
    # ---- other places a line comes from --------------------------------
    row('S1 eval of a one-line loop',
        ["eval 'for i in a b; do echo $i; done'", 'echo after']),
    row('S2 a signal trap string holding a loop',
        ["trap 'for i in a b; do echo $i; done' 15", 'kill -15 $$',
         'sleep 1', 'echo after']),
    # review finding H1: a string source never reads past its own text.  The
    # lines after the eval/trap belong to the CALLER and run as the
    # caller's (STOLEN once, `done` its own error, AFTER).  dash dies
    # on the syntax error; bash refuses the eval (status 2) and goes
    # on: so WANT rows, pinned to bash's semantics.
    row('S5 an eval whose loop lacks its done is refused; the '
        'caller keeps its lines',
        ["eval 'for i in a b; do echo $i'", 'echo S$?', 'echo STOLEN',
         'done', 'echo AFTER'],
        # the caller's `done` error is exactly 40 columns: the glass
        # joins it with the next line (F.unwrap), so AFTER rides on it
        want=['sh: EOF with a construct still open', 'S2', 'STOLEN',
              'sh: unexpected then/elif/else/fi/do/doneAFTER',
              'END', 'S0']),
    row('S6 a trap string whose loop lacks its done is refused; the '
        'caller keeps its lines',
        ["trap 'for i in a b; do echo $i' 15", 'kill -15 $$', 'sleep 1',
         'echo STOLEN', 'done', 'echo AFTER'],
        want=['sh: EOF with a construct still open', 'STOLEN',
              'sh: unexpected then/elif/else/fi/do/doneAFTER',
              'END', 'S0']),
    # review finding M1: the here-doc refusal poisons the frame until ITS done;
    # a second `do` must not revive it
    row('C11 a second do on a refused frame stays dead',
        ['cat <<EOF; for i in a b; do echo BAD; do echo LIVE; done',
         'body', 'EOF'],
        want=['body', 'sh: for: here-doc before do', 'END', 'S0']),
    # review finding (spool reuse): in a SCRIPT the outer loop is seekable and
    # never spools; the string loop spools once, alone -- pinned with
    # the POSIX oracle
    row('S7 a complete eval loop inside a script loop',
        ['for i in a b', 'do', 'echo L$i',
         "eval 'for j in x y; do echo $i$j; done'", 'done']),
    # (a trap inside a `for` loop is delivered late and once, on the
    # base too: sibling S10 in the notes; a while loop is exact)
    row('S8 a complete-loop trap pumped inside a script loop',
        ["trap 'for j in x; do echo T$j; done' 15", 'I=',
         'while test "$I" != xx', 'do', 'echo L$I', 'kill -15 $$',
         'sleep 1', 'I=${I}x', 'done']),
    row('S3 `.`-sourced file holding a one-line loop',
        ['. ./k1', 'echo after'],
        extra={'k1': ['for i in a b; do echo $i; done']}),
    row('S4 the script on stdin (sh < m)',
        ['for i in a b; do echo $i; done'],
        cmds=['sh < m', 'echo S$?']),
]


#: --selftest only: a row that LEAKS a descriptor in the parent shell
#: (`exec 5>>Fz1`, never closed).  The counter check must name it; the
#: teeth runner requires that failure.  Not part of the gate proper.
SELFTEST_ROWS = [
    row('Z1 leaked descriptor (self-test)',
        ['for i in 1; do echo $i; done'],
        want=['1', 'END', 'S0'],
        cmds=['exec 5>>Fz1', 'sh ./m', 'echo S$?']),
]


# ---------------------------------------------------------------------
def kernel_symbols(*names):
    wanted = set(names)
    found = {}
    for line in open(LISTING, errors='replace'):
        m = re.match(r'\s*(\w+)\s*=\s*\$([0-9a-fA-F]+)\s*$', line)
        if m and m.group(1) in wanted:
            found[m.group(1)] = int(m.group(2), 16)
    missing = wanted - set(found)
    if missing:
        raise RuntimeError(f'{sorted(missing)} absent from {LISTING}')
    return found


class Counters:
    NAMES = ('K_IBF_INUSE', 'K_QUAR_CNT', 'MLI_BUF_USED', 'OFT_TYPE')

    def __init__(self, client):
        self.c = client
        self.s = kernel_symbols(*self.NAMES)

    def peek(self, name, n):
        return tuple(self.c.call_tool('peek', {
            'addr': self.s[name], 'count': n, 'bank': 'main'})['bytes'])

    def snap(self):
        return {'inuse': self.peek('K_IBF_INUSE', 1)[0],
                'quar': self.peek('K_QUAR_CNT', 1)[0],
                'mlibuf': self.peek('MLI_BUF_USED', 6),
                'oft': sum(1 for b in self.peek('OFT_TYPE', 16) if b)}


def fresh_oracles(tmp, host_files, cmds):
    """[dash's output, bash 5's output], each host shell in an EMPTY
    directory with only the row's fixture files: `>>` must not see the
    other shell's bytes (the row's scratch files are fresh for each of
    the three shells)."""
    import glob
    outs = []
    for shell in (F.DASH, F.BASH5):
        for f in glob.glob(os.path.join(tmp, '*')):
            os.remove(f)
        M.host_files(tmp, host_files)
        outs.append(M.host_run(shell, cmds, tmp))
    return outs


def fresh_oracle(tmp, host_files, cmds, failures, label):
    """M.oracle over fresh_oracles: dash's answer, and a RIG line when
    bash 5 disagrees."""
    outs = fresh_oracles(tmp, host_files, cmds)
    if outs[0] != outs[1]:
        failures.append(f'RIG {label}: dash {outs[0]!r} and bash5 '
                        f'{outs[1]!r} disagree -- the oracle is not '
                        f'usable')
    return outs[0]


def run_part_a(client, tmp, failures, only=None, selftest=False):
    ctr = Counters(client)
    F.typed(client, 'cd /tmp', 'fixture', failures)
    for label, files, cmds, want in (SELFTEST_ROWS if selftest else ROWS):
        if only and not label.startswith(only):
            continue
        host_files = {}
        for name, (lines, final_nl) in files.items():
            tcmds, text = M.file_cmds(name, lines, final_nl)
            host_files[name] = text
            for c in tcmds:
                F.typed(client, c, label + ' fixture', failures)
        if want is None:
            w = fresh_oracle(tmp, host_files, cmds, failures, label)
        else:
            w = want
        before = ctr.snap()
        got = []
        for line in cmds:
            out = F.typed(client, line, label, failures)
            if out is None:
                got = None
                break
            got.extend(out)
        if got is None:
            continue
        D.assert_eq(label, M.norm(got), M.norm(w), failures)
        after = ctr.snap()
        if after != before:
            failures.append(f'{label}: buffers/OFT before {before} '
                            f'after {after} (a file was left open)')


def part_a(play, failures, only=None, selftest=False):
    import shutil
    tmp, client = M.boot_a(play)
    try:
        work = os.path.join(tmp, 'host')
        os.mkdir(work)
        run_part_a(client, work, failures, only, selftest)
    finally:
        client.close()
        shutil.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------------
# PART B: the console.
def b_typed(t, failures):
    t.wait_prompt('ready')
    M.clear(t)
    got = M.line(t, 'for i in a b; do echo $i; done', '$', 'T1')
    M.need_eq(got, ['$ for i in a b; do echo $i; done', 'a', 'b', '$'],
              'T1 the typed one-line loop', failures)
    M.clear(t)
    t.c.call_tool('type', {'text': M.UP})
    for _ in range(8):
        t._slice()
    got = M.line(t, '', '$', 'T2')
    M.need_eq(got, ['$ for i in a b; do echo $i; done', 'a', 'b', '$'],
              'T2 the loop recalled from history runs again, once',
              failures)
    # a typed loop whose body is a command with a variable and a
    # second command on the do line
    M.clear(t)
    got = M.line(t, 'for i in 1 2; do echo $i; echo x; done', '$', 'T3')
    M.need_eq(got, ['$ for i in 1 2; do echo $i; echo x; done',
                    '1', 'x', '2', 'x', '$'],
              'T3 do CMD ; CMD typed', failures)


NESTED = 'sh: for/while: too many nested sources'


def b_nested(t, failures):
    """One spool at a time (review).  At the console the outer loop is
    SPOOLED (fd 0 cannot seek); a string loop started inside it by
    eval, or by a trap pumped while it runs, would re-create the spool
    file under it.  Each is refused, loudly, per iteration; the outer
    loop is unharmed (its own output is all there) and the console
    gets its prompt back."""
    t.wait_prompt('ready')
    M.clear(t)
    M.line(t, 'for i in a b', '>', 'N1')
    M.line(t, 'do', '>', 'N1')
    M.line(t, 'echo L$i', '>', 'N1')
    M.line(t, "eval 'for j in x y; do echo $i$j; done'", '>', 'N1')
    got = M.line(t, 'done', '$', 'N1')
    M.need_eq(got[-5:], ['La', NESTED, 'Lb', NESTED, '$'],
              'N1 an eval loop inside a spooled loop is refused',
              failures)
    M.clear(t)
    M.line(t, "trap 'for j in x; do echo T$j; done' 15", '$', 'N2')
    M.line(t, 'I=', '$', 'N2')
    M.line(t, 'while test "$I" != xx', '>', 'N2')
    M.line(t, 'do', '>', 'N2')
    M.line(t, 'echo L$I', '>', 'N2')
    M.line(t, 'kill -15 $$', '>', 'N2')
    M.line(t, 'sleep 1', '>', 'N2')
    M.line(t, 'I=${I}x', '>', 'N2')
    got = M.line(t, 'done', '$', 'N2')
    M.need_eq(got[-5:], ['L', NESTED, 'Lx', NESTED, '$'],
              'N2 a complete-loop trap pumped inside a spooled loop is '
              'refused', failures)
    # the console still spools a loop afterwards (the guard is not stuck)
    M.clear(t)
    M.line(t, 'for i in p q', '>', 'N3')
    got = M.line(t, 'do echo $i; done', '$', 'N3')
    M.need_eq(got[-3:], ['p', 'q', '$'],
              'N3 a plain console loop after the refusals', failures)


CASES_B = [('typed', b_typed), ('nested', b_nested)]


def part_b(play, failures, only=None):
    E.DISK = play
    for name, fn in CASES_B:
        if only and not name.startswith(only):
            continue
        mine = []

        def run(t, fn=fn, mine=mine):
            fn(t, mine)
        ok, err = E.session('text40', run)
        if not ok:
            failures.append(f'console {name}: {err}')
        failures.extend(mine)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--play', default=os.path.join(ROOT, 'build',
                                                   'play.po'))
    ap.add_argument('--part', default='all', choices=['a', 'b', 'all'])
    ap.add_argument('--selftest', action='store_true',
                    help='run only the planted-leak row (teeth)')
    ap.add_argument('--rows', default=None,
                    help='run only the part A rows whose label starts '
                         'with this, or the part B cases whose name does')
    args = ap.parse_args()
    play = os.path.abspath(args.play)
    if not os.path.exists(play):
        print(f'check-shexecloop: {play} missing -- make play-image')
        return 2
    for name, tool in (('dash', F.DASH), ('bash 5+', F.BASH5)):
        if not tool:
            print(f'check-shexecloop: oracle {name} missing on this host')
            return 2
    failures = []
    t0 = time.time()
    M.rig_selftest(failures)
    if failures:
        print(f'[check-shexecloop] FAIL: {failures[0]}')
        return 1
    try:
        if args.part in ('a', 'all') or args.selftest:
            part_a(play, failures, args.rows, args.selftest)
        if args.part in ('b', 'all') and not args.selftest:
            part_b(play, failures, args.rows)
    except (RuntimeError, AssertionError, E.Wedged) as exc:
        failures.append(str(exc))
    if failures:
        print(f'[check-shexecloop] FAIL: {len(failures)} row(s)')
        for x in failures:
            print(f'  - {x}'.replace('\n', '\n    '))
        return 1
    print(f'[check-shexecloop] PASS: `for` takes do CMD in every layout, '
          f'replays through continuations and aliases, and leaves no '
          f'file open ({time.time() - t0:.0f} s)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
