#!/usr/bin/env python3
"""check_regex.py -- BRE intervals through the shared regex engine
(`make check-regex`, in check-all-cross). docs/REGEX-BRE-INTERVALS.md,
docs/ANACHRONISMS.md W5b.

Every case is the FORM A HUMAN TYPES at the shell prompt of the play
image -- `echo ... | sed 's/.../.../'` -- plus one `ed` session fed
from a script file, because ed/ex/vi/grep/sed all share
src/liba/regex.s and the sed cases alone would prove only sed's
copy of the entry point. The expectations are hand-authored here (NOT
host-derived): macOS's BSD sed treats `\\+`/`\\?` as LITERAL (measured
2026-09-08: `sed 's/ \\+/ /g'` is a no-op on this host), so the host
cannot oracle the aliases -- the host-differential half of this
feature (`\\{n,m\\}` and the bare-brace/plus/question literals, which
the host DOES agree on) lives in scripts/e2e_corpus.py's grep and sed
sections and runs under check-e2e.

Cases:
  exact     `[0-9]\\{4\\}` matches exactly four digits -- RED on 6aca6f0
            (`\\{` was a literal brace: the echo came back unchanged).
  range     `a\\{2,4\\}` takes 2..4, greedy, and gives back to the
            floor: `aaaaa` -> `Za` (4 taken, the 5th left).
  atleast   `a\\{3,\\}` -- a floor with no ceiling.
  plus      `\\+` collapses runs of blanks (`s/ \\+/ /g`) -- RED on
            6aca6f0 (a literal `+`: no-op).
  question  `\\?` -- `ax\\?b` matches both `axb` and `ab`.
  group     `\\(ab\\)\\{2\\}` -- the interval applies to the WHOLE
            group (RE_GSTAR's floor/ceiling), `ababab` -> `Gab`.
  zero      `b\\{0\\}` -- an explicit ceiling of 0 matches the empty
            string, it is not the unbounded sentinel: `abc` is
            unchanged by `s/ab\\{0\\}c/E/` (host agrees) and `ac` -> `E`.
  literal   OVER-TRIGGER GUARD: bare `{`, `+`, `?` stay literal
            (BRE spelling both ways) -- `a{b}`, `a+b`, `a?b` are matched
            by themselves (green on 6aca6f0, stays green) -- and the
            converse, `\\{2\\}` does NOT match a literal `{2}` (RED on
            6aca6f0, where it did: `a{2}` came back as `X`).
  bigbound  `\\{1,999999\\}` is REFUSED (RE_DUP_MAX 255): the pattern
            is a safe no-match, the line comes back unchanged, and the
            shell prompt returns -- the machine was not run into the
            ground.
  regress   REGRESSION GUARD: a `\\1` backref, a `[a-z]` class and a
            plain `*` still match as before (green on 6aca6f0).
  ed        the SAME engine reached from ed: `1s/[0-9]\\{4\\}/X/` on a
            file holding `12345`, `p` shows `X5`.
  grep      (W5d, 2026-09-11) a `[[:digit:]]` class and a
            `\\(ab\\)\\{10\\}` group interval (past the old 8-rep cap)
            reached from grep -- the class parser and the group
            repeat live in regex2.s, shared by every consumer.

Teeth (measured 2026-09-08 on the 6aca6f0 build, before the engine
change): 9 of 11 RED -- exact, range, atleast, plus, question, group,
zero, literal (its second half), ed; bigbound and regress GREEN there
and after -- they are the cap and regression guards.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_vi as V                                    # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR    # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def has_row(rs, text):
    return any(r.rstrip() == text for r in rs)


def nonblank(rs):
    return [r.rstrip() for r in rs if r.strip()]


def run_line(c, label, line, want):
    """Type `line` at the prompt; the glass must show a row equal to
    `want` AND the prompt must be back. Rejects the echo of the typed
    line itself (a no-op sed would otherwise "pass" on the input text
    when want == input), so `want` must never be a substring of the
    command line typed -- assert that here rather than trust it."""
    if want in line:
        raise AssertionError(f'{label}: expectation {want!r} appears in '
                             f'the typed line {line!r} -- the case cannot '
                             'distinguish output from echo')
    V.settle(c, V._at_prompt, f'{label}: shell prompt')
    V.t(c, line + '\r')
    V.settle(c, lambda rs: has_row(rs, want) and V._at_prompt(rs),
             f'{label}: {line!r} -> {want!r}')


def case_exact(c):
    run_line(c, 'exact', "echo 12345 1234 123 | sed 's/[0-9]\\{4\\}/X/g'",
             'X5 X 123')


def case_range(c):
    run_line(c, 'range', "echo aaa a aaaaa | sed 's/a\\{2,4\\}/Z/g'",
             'Z a Za')


def case_atleast(c):
    run_line(c, 'atleast', "echo aa aaa aaaaa | sed 's/a\\{3,\\}/M/g'",
             'aa M M')


def case_plus(c):
    run_line(c, 'plus', "echo 'a  b   c' | sed 's/ \\+/ /g'", 'a b c')


def case_question(c):
    run_line(c, 'question', "echo axb ab | sed 's/ax\\?b/./g'", '. .')


def case_group(c):
    run_line(c, 'group', "echo ababab | sed 's/\\(ab\\)\\{2\\}/G/'", 'Gab')


def case_zero(c):
    run_line(c, 'zero', "echo abc ac | sed 's/ab\\{0\\}c/E/g'", 'abc E')


def case_literal(c):
    run_line(c, 'literal',
             "echo 'a{b} a+b a?b' | sed 's/a{b}/1/;s/a+b/2/;s/a?b/3/'",
             '1 2 3')
    run_line(c, 'literal', "echo 'a{2}' | sed 's/a\\{2\\}/X/;s/}/W/'",
             'a{2W')


def case_bigbound(c):
    run_line(c, 'bigbound',
             "echo qq | sed 's/q\\{1,999999\\}/N/;s/q/R/'", 'Rq')


def case_regress(c):
    run_line(c, 'regress',
             "echo 'the the quick' | sed 's/\\([a-z]*\\) \\1/<&>/'",
             '<the the> quick')
    run_line(c, 'regress', "echo aaab ab b | sed 's/a*b/S/g'", 'S S S')
    run_line(c, 'regress', "echo 'x1 x22 xa' | sed 's/x[0-9]*/T/g'",
             'T T Ta')


def case_grep(c):
    run_line(c, 'grep', "echo 'x1 y' | grep '[[:digit:]]' | sed 's/^/G:/'",
             'G:x1 y')
    run_line(c, 'grep',
             "echo abababababababababab | grep '^\\(ab\\)\\{10\\}$' "
             "| sed 's/^/R:/'", 'R:abababababababababab')


def case_ed(c):
    V.settle(c, V._at_prompt, 'ed: shell prompt')
    V.t(c, 'echo 12345 > /mnt/MAUX/IVF\r')
    V.settle(c, V._at_prompt, 'ed: fixture written')
    V.t(c, "echo '1s/[0-9]\\{4\\}/X/' > /mnt/MAUX/IVS\r")
    V.settle(c, V._at_prompt, 'ed: script line 1')
    V.t(c, 'echo p >> /mnt/MAUX/IVS\r')
    V.settle(c, V._at_prompt, 'ed: script line 2')
    V.t(c, 'echo w >> /mnt/MAUX/IVS\r')
    V.settle(c, V._at_prompt, 'ed: script line 3')
    V.t(c, 'echo q >> /mnt/MAUX/IVS\r')
    V.settle(c, V._at_prompt, 'ed: script line 4')
    V.t(c, 'ed /mnt/MAUX/IVF < /mnt/MAUX/IVS\r')
    V.settle(c, lambda rs: has_row(rs, 'X5') and V._at_prompt(rs),
             'ed: 1s/[0-9]\\{4\\}/X/ then p prints X5')


CASES = [
    ('exact', '[0-9]\\{4\\} is exactly four digits', case_exact),
    ('range', 'a\\{2,4\\} takes 2..4 greedily', case_range),
    ('atleast', 'a\\{3,\\} is a floor with no ceiling', case_atleast),
    ('plus', '\\+ collapses runs', case_plus),
    ('question', '\\? is zero-or-one', case_question),
    ('group', '\\(ab\\)\\{2\\} repeats the whole group', case_group),
    ('zero', '\\{0\\} matches the empty string', case_zero),
    ('literal', 'bare {, +, ? stay literal (over-trigger guard)',
     case_literal),
    ('bigbound', '\\{1,999999\\} is refused, not attempted', case_bigbound),
    ('regress', '\\1, [a-z], * unchanged (regression guard)', case_regress),
    ('ed', 'the same engine reached from ed', case_ed),
    ('grep', 'W5d: a class and a 10-rep group reached from grep',
     case_grep),
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
                print(f'[check-regex] ok   {name}: {desc}')
            except AssertionError as e:
                fails.append((name, str(e)))
                print(f'[check-regex] FAIL {name}: {e}', file=sys.stderr)
                V.boot(c)
    finally:
        try:
            c.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        c.close()

    if fails:
        print(f'[check-regex] FAIL: {len(fails)} of {len(CASES)} cases',
              file=sys.stderr)
        return 1
    print('[check-regex] PASS: BRE intervals \\{n,m\\} + \\+/\\? through '
          'sed and ed; bare {+? literal; \\1/[a-z]/* unchanged')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
