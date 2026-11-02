#!/usr/bin/env python3
"""check_shmlquote.py -- a quote, or a trailing backslash, continues the
line (`make check-shmlquote`, docs/SH-MLQUOTE.md, docs/SH-MLQUOTE-NOTES.md).

Two parts, one emulator session each.

PART A  (script rows, the check_shnlvar idiom).  Boots the play image
and types each row at the shell: the row's FILES are written line by
line with typed `echo` (so a fixture never needs the feature under
test), then its COMMANDS run -- `sh ./m` (the seekable fast path), and
for the rows marked P also `cat m | sh` (the byte path).

ORACLE.  A row with want=None is also run by the host's dash AND bash 5
(macOS /bin/sh is bash 3.2 and is never the oracle) in a scratch
directory holding the same files; maux must print what they print, and
a RIG line is raised if dash and bash 5 disagree first.  A row with a
WANT list has no POSIX twin -- a deliberate maux refusal or a pinned
gap -- and carries its output.  Every fixture file is length-checked
(`wc -c`) against the bytes the host got, so an `echo` that mangled a
line fails as a RIG line, not as a mystery row.

PART B  (console rows, the check_shedit idiom, text40).  Typed at the
editor prompt one key burst at a time; the glass is cleared with ^L
before each row and compared EXACTLY, so the `> ` prompt, its count and
its place are part of the assertion: PS2, ^C and ^D at PS2, TAB at PS2,
history (whole entry, no fragment, a 200-byte logical line is not
added), console-loop spooling, the alias expander, the unedited console
(`sh -E`).

Rows: docs/SH-MLQUOTE-NOTES.md sec 4.3.  Teeth: scripts/
teeth_shmlquote.py.

ASCII only.  Exit 0 green, 1 red (listed), 2 rig problem.
"""
import argparse
import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_shfd as F  # noqa: E402
import check_devfs as D  # noqa: E402
import e2e_term as E  # noqa: E402
import gate_race as GR  # noqa: E402
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TOOLONG = 'sh: line too long'
HDLONG = 'sh: here-doc: too long'
UNTERM = 'sh: unterminated quote'


def q(s):
    """`s` as one maux word: single quotes unless it holds one, else
    double quotes with \\ \" $ escaped."""
    if "'" not in s:
        return "'" + s + "'"
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace(
        '$', '\\$') + '"'


def file_cmds(name, lines, final_nl=True):
    """The typed commands (each <= 38 columns) that write `lines` to
    `name`, one physical line per element; a long line goes in chunks
    through `echo -n`.  Returns (commands, the file's exact bytes)."""
    cmds, op = [], '>'
    text = ''
    for i, ln in enumerate(lines):
        last_line = (i == len(lines) - 1)
        nl = final_nl or not last_line
        text += ln + ('\n' if nl else '')
        rest = ln
        if rest == '':
            if nl:
                cmds.append(f'echo {op} {name}')
                op = '>>'
            continue
        while rest:
            n = len(rest)
            while True:
                chunk = rest[:n]
                final = (n == len(rest)) and nl
                cmd = (f'echo {"" if final else "-n "}{q(chunk)} '
                       f'{op} {name}')
                if len(cmd) <= 38 and not chunk.startswith('-'):
                    break
                n -= 1
                assert n > 0, f'cannot type {ln!r}'
            cmds.append(cmd)
            op = '>>'
            rest = rest[n:]
    return cmds, text


def host_write(tmp, files):
    for name, text in files.items():
        with open(os.path.join(tmp, name), 'wb') as fh:
            fh.write(text.encode('latin-1'))


def host_run(shell, cmds, tmp):
    """Run `cmds` as a script file under `shell`.  The row's `sh ./m`
    is a shell function that runs `shell` ITSELF, so a script row's
    oracle is each host shell in turn (SH-G21 F4: it used to run dash
    under both, and bash 5 was never asked)."""
    import subprocess
    script = os.path.join(tmp, 'row.sh')
    with open(script, 'w') as fh:
        fh.write('sh() { %s "$@"; }\n' % shell)
        fh.write('\n'.join(cmds) + '\n')
    r = subprocess.run([shell, script], cwd=tmp, stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       timeout=30, check=False)
    return [x.strip() for x in r.stdout.decode('latin-1').split('\n')
            if x.strip() != '']


def rig_selftest(failures):
    """The oracle rig must really ask both shells.  A canary script
    prints $BASH_VERSION, or `dash` where it is unset: with `sh ./m`
    run as each host shell itself the two answers differ; with the old
    `sh() { dash; }` shim both print `dash` and the rig is blind to
    bash 5.  Host-only (no emulator); every gate that uses host_run
    runs it first."""
    import tempfile
    import shutil
    tmp = tempfile.mkdtemp(prefix='maux-rig-')
    try:
        _, text = file_cmds('m', ['echo ${BASH_VERSION-dash}'], True)
        host_files(tmp, {'m': text})
        d = host_run(F.DASH, ['sh ./m'], tmp)
        b = host_run(F.BASH5, ['sh ./m'], tmp)
        if d != ['dash'] or not b or b == ['dash']:
            failures.append(
                f'RIG selftest: a script row ran as dash {d!r} / bash 5 '
                f'{b!r}; the oracle is not asking both shells')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def oracle(tmp, cmds, failures, label):
    d = host_run(F.DASH, cmds, tmp)
    b = host_run(F.BASH5, cmds, tmp)
    if d != b:
        failures.append(f'RIG {label}: dash {d!r} and bash5 {b!r} '
                        f'disagree -- the oracle is not usable')
    return d


# ---------------------------------------------------------------------
# PART A rows: (label, files, cmds, want, pipe).  files: name -> (lines,
# final_newline).  cmds are typed at the console shell (and run by the
# host shells); pipe=True adds the `cat m | sh` twin of every `sh ./m`.
def f1(*lines):
    return {'m': (list(lines), True)}


def sh_s(extra=()):
    return ['sh ./m'] + list(extra)


ORA = None
X244 = 'x' * 244
ROWS_A = [
    ('Q1 single quote across a break',
     f1("echo 'a", "b'"), sh_s(), ORA, True),
    ('Q2 double quote, expansion across the break',
     f1('X=1; echo "a $X', 'b $X"'), sh_s(), ORA, False),
    ('Q3a backslash-newline joins',
     f1('echo one \\', ' two'), sh_s(), ORA, True),
    ('Q3b backslash-newline inside double quotes',
     f1('echo "a\\', 'b"'), sh_s(), ORA, False),
    ('Q3c backslash-newline inside single quotes is data',
     f1("echo 'a\\", "b'"), sh_s(), ORA, False),
    ('Q3d backslash-newline glues words',
     f1('echo a\\', 'b c'), sh_s(), ORA, False),
    ('Q4a a comment with a quote continues nothing',
     f1("echo x # it's", 'echo y'), sh_s(), ORA, False),
    ('Q4d an escaped backslash before the closing quote',
     f1('echo "x\\\\" # it\'s', 'echo z'), sh_s(), ORA, False),
    ('Q4b a hash inside a quote is data',
     f1("echo 'a#b'"), sh_s(), ORA, False),
    ('Q4c a comment backslash continues nothing',
     f1('echo y # tail \\', 'echo z'), sh_s(), ORA, False),
    ('Q5 an empty middle line',
     f1("echo 'a", '', "b'|wc -l"), sh_s(), ORA, False),
    ('Q6a $( ) left open: today\'s refusal, pinned',
     f1("echo $(printf 'a", "echo b')"), sh_s(),
     ['sh: $(): unclosed, or nested', UNTERM], False),
    ('Q6b ( ) left open: today\'s refusal, pinned',
     f1("(echo 'a"), sh_s(), ['sh: (): unclosed'], False),
    ('Q6c backquote: maux has none, it is an ordinary byte',
     f1('echo `echo hi`'), sh_s(), ['`echo hi`'], False),
    ('Q6d case pattern holding a break',
     f1("V='x", "y'", 'case "$V" in', "'x", "y') echo hit;;", 'esac'),
     sh_s(), ORA, False),
    ('Q6e ${U-word} holding a break',
     f1("echo ${U-'a", "b'}"), sh_s(), ORA, False),
    ('Q6f here-doc operator line continued',
     f1('cat \\', '<<EOF', 'body', 'EOF'), sh_s(), ORA, False),
    ('Q6g quoted assignment across a break',
     f1("V='a", "b'", 'echo "$V"'), sh_s(), ORA, False),
    ('Q6h quoted segments glued to a bare word',
     f1("echo x'a", "b'y"), sh_s(), ORA, False),
    ('Q6j an escaped quote opens nothing',
     f1("echo \\'a"), sh_s(), ORA, False),
    ('Q6k a single quote inside double quotes',
     f1('echo "it\'s', 'ok"'), sh_s(), ORA, False),
    ('Q6l a double quote inside single quotes',
     f1("echo 'say \"hi", "there\"'"), sh_s(), ORA, False),
    ('Q6m a continued word before a pipe',
     f1("echo 'a", "b'|cat"), sh_s(), ORA, False),
    # ---- LINEMAX ---------------------------------------------------
    ('Q7a a 255-byte line is accepted',
     f1('echo ' + X244 + '|wc -c'), sh_s(), ORA, True),
    ('Q7b a 256-byte line is refused whole',
     f1('echo ' + X244 + 'x|wc -c', 'echo S$?', 'echo after'), sh_s(),
     [TOOLONG, 'S1', 'after'], True),
    ('Q7c a 255-byte LOGICAL line is accepted',
     f1("echo '" + 'a' * 100, 'b' * 141 + "'|wc -c"), sh_s(), ORA, False),
    ('Q7d a 256-byte LOGICAL line is refused whole',
     f1("echo '" + 'a' * 100, 'b' * 142 + "'|wc -c", 'echo after'),
     sh_s(), [TOOLONG, 'after'], False),
    ('Q7e a quote opened in the discarded tail resynchronises',
     f1("echo '" + 'a' * 260, "echo inner'", 'echo after'), sh_s(),
     [TOOLONG, 'after'], False),
    ('Q7k a quote inside an open $( ) is opaque to the resync',
     f1('echo ' + 'x' * 242 + "$(echo ')", 'echo KEPT', 'echo AFTER'),
     sh_s(), [TOOLONG, 'KEPT', 'AFTER'], False),
    ('Q7l a quote inside a group ( ) is opaque to the resync',
     f1("(echo '" + 'a' * 249, 'echo KEPT', 'echo AFTER'), sh_s(),
     [TOOLONG, 'KEPT', 'AFTER'], False),
    ('Q7f EOF inside a quote',
     f1("echo 'a"), sh_s(['echo S$?']), [UNTERM, 'S1'], True),
    # WANT, not ORA (SH-G21 F4/box): once `sh ./m` really ran under
    # bash 5, the box's bash 5.2.15 printed `a` here (it drops a final
    # backslash with no newline) while dash and bash 5.3.9 (the Mac)
    # print `a\`, which is POSIX and what maux prints. A host-version
    # difference, not a maux one: pinned to the answer both dash and
    # 5.3 give.
    ('Q7g a trailing backslash at EOF, no newline, is literal',
     {'m': (['echo a\\'], False)}, sh_s(['echo S$?']),
     ['a\\', 'S0'], True),
    ('Q7h backslash-newline then EOF',
     f1('echo a \\'), sh_s(['echo S$?']), ORA, False),
    # ---- the seek mark ---------------------------------------------
    ('W1 a while loop whose body holds a multi-line quote',
     f1('N=', 'while [ "$N" != xx ]', 'do', 'echo "i=$N', 'end"',
        'N=${N}x', 'done'), sh_s(), ORA, True),
    ('W1b a while loop whose HEAD line is continued',
     f1('N=', 'while [ "$N" \\', '!= xx ]', 'do', 'echo "i=$N"',
        'N=${N}x', 'done'), sh_s(), ORA, True),
    # ---- here-documents --------------------------------------------
    ('H1 unquoted delimiter: backslash-newline is removed',
     f1('cat <<EOF', 'a\\', 'b', 'EOF'), sh_s(), ORA, False),
    ('H2 quoted delimiter: both bytes stay',
     f1("cat <<'EOF'", 'a\\', 'b', 'EOF'), sh_s(), ORA, False),
    ('H3 the JOINED text equals the delimiter (bash 5 / POSIX 2.7.4)',
     f1('cat <<EOF', 'x', 'EO\\', 'F', 'echo after'), sh_s(),
     ['x', 'after'], False),
    ('H4 quoted delimiter: EO\\<NL>F does not end the body',
     f1("cat <<'EOF'", 'x', 'EO\\', 'F', 'EOF', 'echo after'), sh_s(),
     ORA, False),
    ('H6 a 256-byte body line is refused, never truncated',
     f1('cat <<EOF', 'x' * 256, 'EOF', 'echo S$?', 'echo after'),
     sh_s(), [HDLONG, 'S1', 'after'], False),
    ('H7 a body past the body cap is refused, never truncated',
     f1('cat <<EOF', 'x' * 100, 'x' * 100, 'x' * 100, 'EOF',
        'echo S$?', 'echo after'), sh_s(), [HDLONG, 'S1', 'after'],
     False),
    # the dropped byte is invisible in the body: `$E` (unset) expands
    # to nothing, so only the per-LINE flag can see the 256th byte
    ('H9 a 256-byte body line that EXPANDS short is still refused',
     f1('cat <<EOF', '$E' * 128, 'EOF', 'echo S$?', 'echo after'),
     sh_s(), [HDLONG, 'S1', 'after'], False),
    ('H8 a body of exactly 255 bytes is accepted',
     f1('cat <<EOF', 'x' * 254, 'EOF', 'echo after'),
     ['sh ./m | wc -c'], ORA, False),
    ('H5 a quote in a body never continues',
     f1('cat <<EOF', "it's", 'EOF', 'echo after'), sh_s(), ORA, False),
    # ---- other sources ---------------------------------------------
    ('C1 sh -c with a quoted newline',
     f1('sh -c "echo \'a', 'b\'"'), sh_s(), ORA, False),
    ('C2 eval with a quoted newline',
     f1('eval "echo \'a', 'b\'"'), sh_s(), ORA, False),
    ('C3 an exit trap string with a quoted newline',
     f1('trap "echo \'a', 'b\'" 0'), sh_s(), ORA, False),
    ('A8 a backslash-blank before a hash is not a comment',
     f1('echo a\\ #b'), sh_s(), ORA, False),
    ('N9 the SH-NLVAR crossing',
     f1("V='a", "b'", '(echo "$V")', 'W=$(echo "$V")', 'echo "$W"'),
     sh_s(), ORA, False),
]

# typed at the console, no file: C4/C5 pin the UNQUOTED newline.
ROWS_A2 = [
    ('C4 eval: an unquoted newline separates nothing (pinned)',
     {'k2': (['echo a', 'echo b'], True)},
     ['V=$(cat k2)', 'eval "$V"'], ['a', 'echo b'], False),
    ('C5 sh -c: an unquoted newline separates nothing (pinned)',
     {'k2': (['echo a', 'echo b'], True)},
     ['V=$(cat k2)', 'sh -c "$V"'], ['a', 'echo b'], False),
]


def norm(rows):
    return [r.strip() for r in rows if r.strip() != '']


def run_part_a(client, tmp, failures, only=None):
    F.typed(client, 'cd /tmp', 'fixture', failures)
    for label, files, cmds, want, pipe in ROWS_A + ROWS_A2:
        if only and not label.startswith(only):
            continue
        host_files_ = {}
        for name, (lines, final_nl) in files.items():
            tcmds, text = file_cmds(name, lines, final_nl)
            host_files_[name] = text
            for c in tcmds:
                F.typed(client, c, label + ' fixture', failures)
            got = F.typed(client, f'wc -c < {name}', label + ' fixture',
                          failures)
            if got is None or norm(got) != [str(len(text))]:
                failures.append(f'RIG {label}: {name} is {got!r} bytes on '
                                f'maux, {len(text)} on the host')
        variants = [(label, cmds)]
        if pipe:
            variants.append((label + ' [pipe]',
                             [c.replace('sh ./m', 'cat m | sh')
                              for c in cmds]))
        for lab, cs in variants:
            if want is None:
                host_files(tmp, host_files_)
                w = oracle(tmp, cs, failures, lab)
            else:
                w = want
            got = []
            for line in cs:
                out = F.typed(client, line, lab, failures)
                if out is None:
                    got = None
                    break
                got.extend(out)
            if got is None:
                continue
            D.assert_eq(lab, norm(got), norm(w), failures)


def host_files(tmp, files):
    host_write(tmp, files)


def boot_a(play):
    tmp = tempfile.mkdtemp(prefix='maux-shmlq-')
    boot = os.path.join(tmp, 'play.po')
    shutil.copy(play, boot)
    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
    client = MCPClient([SUPERVISOR], env)
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
    return tmp, client


def part_a(play, failures, only=None):
    tmp, client = boot_a(play)
    try:
        work = os.path.join(tmp, 'host')
        os.mkdir(work)
        run_part_a(client, work, failures, only)
    finally:
        client.close()
        shutil.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------------
# PART B: the console.
CTRL_C, CTRL_D, CTRL_L, TAB = '\\x03', '\\x04', '\\x0c', '\\x09'
UP = '\\x0b'                           # the //e up arrow (^K)


def rows(t):
    return [r.rstrip() for r in t.screen() if r.strip()]


def wait_bare(t, ch, label, changed_from=None):
    """The last row is exactly `ch` ('$' or '>') on two consecutive
    polls, and (if given) the glass differs from `changed_from`."""
    last, stable = None, 0
    for _ in range(GR.count(160, E.KEY_CYC_MAX)):
        r = rows(t)
        cur = r[-1] if r else ''
        if cur == ch and (changed_from is None or r != changed_from) \
                and cur == last:
            stable += 1
            if stable >= 2:
                return r
        else:
            stable = 0
        last = cur
        t._poll()
    raise AssertionError(f'{label}: never saw a bare {ch!r}; glass:\n'
                         + '\n'.join(rows(t)))


def line(t, text, ch, label):
    """Type `text` + Return in one burst; wait for the bare `ch`."""
    before = rows(t)
    t.c.call_tool('type', {'text': text + '\r'})
    t._slice()
    return wait_bare(t, ch, label, before)


def clear(t, label='clear'):
    before = rows(t)
    t.c.call_tool('type', {'text': CTRL_L})
    t._slice()
    return wait_bare(t, '$', label)


def need_eq(got, want, label, failures):
    D.assert_eq(label, got, want, failures)


def b_basic(t, failures):
    t.wait_prompt('ready')
    clear(t)
    # Q1: PS2 shown once, both physical lines echoed, then the output
    line(t, "echo 'a", '>', 'Q1')
    got = line(t, "b'", '$', 'Q1')
    need_eq(got, ['$ echo \'a', "> b'", 'a', 'b', '$'], 'Q1 console PS2',
            failures)
    # Q2
    line(t, 'X=1', '$', 'Q2 setup')
    clear(t)
    line(t, 'echo "a $X', '>', 'Q2')
    got = line(t, 'b $X"', '$', 'Q2')
    need_eq(got, ['$ echo "a $X', '> b $X"', 'a 1', 'b 1', '$'],
            'Q2 console', failures)
    # Q3a / b / c
    clear(t)
    line(t, 'echo one \\', '>', 'Q3a')
    got = line(t, ' two', '$', 'Q3a')
    need_eq(got, ['$ echo one \\', '>  two', 'one two', '$'],
            'Q3a console', failures)
    clear(t)
    line(t, 'echo "a\\', '>', 'Q3b')
    got = line(t, 'b"', '$', 'Q3b')
    need_eq(got, ['$ echo "a\\', '> b"', 'ab', '$'], 'Q3b console',
            failures)
    clear(t)
    line(t, "echo 'a\\", '>', 'Q3c')
    got = line(t, "b'", '$', 'Q3c')
    need_eq(got, ["$ echo 'a\\", "> b'", 'a\\', 'b', '$'], 'Q3c console',
            failures)
    # Q4a: a comment with a quote: runs at once, no PS2
    clear(t)
    got = line(t, "echo x # it's", '$', 'Q4a')
    need_eq(got, ["$ echo x # it's", 'x', '$'], 'Q4a console (no PS2)',
            failures)
    # Q5: an empty middle line
    clear(t)
    line(t, "echo 'a", '>', 'Q5')
    line(t, '', '>', 'Q5')
    got = line(t, "b'|wc -l", '$', 'Q5')
    need_eq(got, ["$ echo 'a", '>', "> b'|wc -l", '3', '$'],
            'Q5 console', failures)
    # A8
    clear(t)
    got = line(t, 'echo a\\ #b', '$', 'A8')
    need_eq(got, ['$ echo a\\ #b', 'a #b', '$'], 'A8 console', failures)
    # R1: the alias expander sees the logical line
    line(t, 'alias e=echo', '$', 'R1 setup')
    clear(t)
    line(t, "e 'a", '>', 'R1')
    got = line(t, "b'", '$', 'R1')
    need_eq(got, ["$ e 'a", "> b'", 'a', 'b', '$'], 'R1 alias', failures)
    # R5: TAB at a PS2 line completes nothing
    clear(t)
    line(t, "echo 'x", '>', 'R5')
    t.c.call_tool('type', {'text': 'ec'})
    t._slice()
    t.c.call_tool('type', {'text': TAB})
    for _ in range(12):
        t._slice()
    r = rows(t)
    need_eq(r[-1], '> ec', 'R5 TAB at PS2 changes nothing', failures)
    got = line(t, "'", '$', 'R5')
    need_eq(got, ["$ echo 'x", "> ec'", 'x', 'ec', '$'], 'R5 finish',
            failures)


def b_interrupt(t, failures):
    t.wait_prompt('ready')
    clear(t)
    line(t, "echo 'a", '>', 'Q7i')
    t.c.call_tool('type', {'text': CTRL_C})
    t._slice()
    got = wait_bare(t, '$', 'Q7i ^C at PS2')
    if 'a' in got:
        failures.append(f'Q7i: the abandoned line ran: {got!r}')
    clear(t)
    got = line(t, 'echo S$?', '$', 'Q7i')
    need_eq(got, ['$ echo S$?', 'S130', '$'], 'Q7i ^C at PS2: 130',
            failures)
    clear(t)
    line(t, "echo 'a", '>', 'Q7j')
    t.c.call_tool('type', {'text': CTRL_D})
    t._slice()
    got = wait_bare(t, '$', 'Q7j ^D at PS2')
    if UNTERM not in got:
        failures.append(f'Q7j: ^D at PS2 gave no {UNTERM!r} row on its '
                        f'own (the `> ` row must end first): {got!r}')
    clear(t)
    got = line(t, 'echo S$?', '$', 'Q7j')
    need_eq(got, ['$ echo S$?', 'S1', '$'], 'Q7j ^D at PS2: shell alive',
            failures)


def b_spool(t, failures):
    t.wait_prompt('ready')
    clear(t)
    line(t, 'N=', '$', 'W2 setup')
    clear(t)
    line(t, 'while [ "$N" != xx ]', '>', 'W2')
    line(t, 'do', '>', 'W2')
    line(t, 'echo "i=$N', '>', 'W2')
    line(t, 'end"', '>', 'W2')
    line(t, 'N=${N}x', '>', 'W2')
    got = line(t, 'done', '$', 'W2')
    need_eq(got[-5:], ['i=', 'end', 'i=x', 'end', '$'],
            'W2 console loop with a multi-line quote', failures)


def b_hist(t, failures):
    t.wait_prompt('ready')
    clear(t)
    # R2: a multi-line entry recalls whole
    line(t, "echo 'a", '>', 'R2')
    line(t, "b'", '$', 'R2')
    t.c.call_tool('type', {'text': UP})
    for _ in range(8):
        t._slice()
    got = line(t, '', '$', 'R2')
    need_eq(got[-3:], ['a', 'b', '$'], 'R2 recalled whole', failures)
    # R3: no fragment is recallable (E1 = two lines, E2 = echo z)
    clear(t)
    line(t, "echo 'p", '>', 'R3')
    line(t, "q'", '$', 'R3')
    line(t, 'echo z', '$', 'R3')
    clear(t)
    t.c.call_tool('type', {'text': UP + UP})
    for _ in range(8):
        t._slice()
    got = line(t, '', '$', 'R3')
    need_eq(got[-3:], ['p', 'q', '$'], 'R3 no fragment in history',
            failures)
    # R4: a 200-byte logical line is not added
    clear(t)
    line(t, 'echo marker', '$', 'R4')
    line(t, "echo '" + 'A' * 94, '>', 'R4')
    line(t, 'B' * 100 + "'|wc -c", '$', 'R4')
    clear(t)
    t.c.call_tool('type', {'text': UP})
    for _ in range(8):
        t._slice()
    got = line(t, '', '$', 'R4')
    need_eq(got[-2:], ['marker', '$'], 'R4 a long logical line is not '
            'in history', failures)


def b_unedited(t, failures):
    t.wait_prompt('ready')
    clear(t)
    line(t, 'sh -E', '$', 'R6 sh -E')
    clear(t)
    line(t, "echo 'a", '>', 'R6')
    got = line(t, "b'", '$', 'R6')
    need_eq(got, ["$ echo 'a", "> b'", 'a', 'b', '$'],
            'R6 unedited console PS2', failures)
    clear(t)
    line(t, "echo 'a", '>', 'R6c')
    t.c.call_tool('type', {'text': CTRL_C})
    t._slice()
    got = wait_bare(t, '$', 'R6c ^C at PS2')
    if 'a' in got:
        failures.append(f'R6c: the abandoned line ran: {got!r}')


CASES_B = [
    ('basic', b_basic), ('interrupt', b_interrupt), ('spool', b_spool),
    ('hist', b_hist), ('unedited', b_unedited),
]


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
    ap.add_argument('--rows', default=None,
                    help='run only the part A rows whose label starts '
                         'with this, or the part B cases whose name does')
    args = ap.parse_args()
    play = os.path.abspath(args.play)
    if not os.path.exists(play):
        print(f'check-shmlquote: {play} missing -- make play-image')
        return 2
    for name, tool in (('dash', F.DASH), ('bash 5+', F.BASH5)):
        if not tool:
            print(f'check-shmlquote: oracle {name} missing on this host')
            return 2
    failures = []
    t0 = time.time()
    rig_selftest(failures)
    if failures:
        print(f'[check-shmlquote] FAIL: {failures[0]}')
        return 1
    try:
        if args.part in ('a', 'all'):
            part_a(play, failures, args.rows)
        if args.part in ('b', 'all'):
            part_b(play, failures, args.rows)
    except (RuntimeError, AssertionError, E.Wedged) as exc:
        failures.append(str(exc))
    if failures:
        print(f'[check-shmlquote] FAIL: {len(failures)} row(s)')
        for x in failures:
            print(f'  - {x}'.replace('\n', '\n    '))
        return 1
    print(f'[check-shmlquote] PASS: a quote or a trailing backslash '
          f'continues the line ({time.time() - t0:.0f} s)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
