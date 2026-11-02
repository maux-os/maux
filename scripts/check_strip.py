#!/usr/bin/env python3
"""check_strip.py -- host-only gate for scripts/strip_comments.py
(`make check-strip`).

WHY THIS EXISTS. strip_comments.py's own `--selftest` (10 synthetic cases
+ the indented-`*` tripwire) had teeth but nothing in `make check-all` ran
it. An adversarial review sabotaged strip_text() to a column-0-only rule
and found: --selftest FAILS (good), but build_maux_src_image.py still
exits 0 and prints every unit [OK] at 348.5 KB instead of 255.5 KB, and
`make check-dual` stays green (comments cannot change emitted bytes --
that's the module's own thesis, so byte-identity is blind to a comment
regression by construction). check-all was FULLY GREEN under a 93 KB
regression of this stream's entire purpose. This gate closes that: it
wires --selftest into the gate set (see the Makefile's `check-strip`
target) and adds a check with more teeth than ten synthetic cases --
a tree-wide differential against an INDEPENDENT implementation of the
same operator spec, plus a ratchet over the measured blanked-line count
so a sabotage that keeps both implementations self-consistent (impossible
here, since they share no code) or that just quietly narrows the rule
still shows up as a falling count.

THE INDEPENDENT IMPLEMENTATION. Same operator spec as strip_comments.py's
module docstring (copied verbatim below so this file does not silently
drift from it), but a different mechanism: regex matching against each
raw line rather than strip_text()'s lstrip()-and-branch. Sharing the
control flow would make this a copy, not a check -- see HACKING.md's
"prove the teeth" precedent (a gate not seen to fail on broken code is
not done) and the task brief's own trap: `sed 's/^[*;].*//'` LOOKS
independent but only blanks column-0, silently dropping the 3,997
indented `;` lines the real rule also blanks -- an "independent"
implementation that is simply wrong is worse than no gate at all, so
this one is asserted against every file in the tree, not spot-checked.

THE RULE (operator specification, exact -- see strip_comments.py's
module docstring for the full rationale): a line is comment-only iff,
after stripping leading spaces and tabs, the remainder begins with `;`
OR the line's COLUMN-0 character is `*`. A comment-only line's entire
content becomes the empty string; the line STAYS (blank-substitution,
not deletion -- line numbers must keep matching the master tree for
Merlin's line-numbered diagnostics to point at the right place). Every
other line passes through byte for byte. If a line's first non-blank
character is `*` but column 0 is NOT `*`, that is the ambiguous
indented-star case and a conforming implementation RAISES rather than
guesses.

THE RATCHET. BASELINE_BLANKED_LINES below is the blanked-line count
measured on this tree 2026-08-23 (17,294 column-0 `*` + 20 column-0 `;`
+ 3,997 indented `;` = 21,311). This is a FLOOR, not an equality: the
tree gains comments daily under parallel streams, and ordinary growth
can only RAISE the count (a new file, a new comment, both add blanked
lines; nothing in ordinary development removes them faster than it adds
them). A SHARP DROP is the regression signature specifically -- the
column-0-only sabotage above cut the count by exactly the 3,997 indented
`;` lines it stopped seeing, floor to ceiling, in one commit. So: fail
if the recomputed count ever falls below the floor. If a legitimate
tree-wide change genuinely lowers the true count (e.g. a mass rewrite
converting block comments to code, or deleting a heavily-commented
file), raise BASELINE_BLANKED_LINES down explicitly in the same commit,
with the reason stated -- same discipline as check_dialect.py's
OVER_BUDGET_UNITS set ratchet and check_purity.py's PURE_PROGRAMS
grow-only set.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'scripts'))
import strip_comments as sc  # noqa: E402 -- the module under test
import check_manifests as cm  # noqa: E402 -- universe(), per HACKING.md's
                               # house-tool rule: reuse the file-set
                               # check_manifests.universe() already
                               # defines rather than re-globbing it.

# Measured 2026-08-23 over check_manifests.universe() (src/**/*.s,
# src/**/*.equ, inc/*.equ). See the module docstring's RATCHET note.
BASELINE_BLANKED_LINES = 21311

failures = []


def check(label, cond, detail=''):
    status = 'ok' if cond else 'FAIL'
    print(f'[check-strip] {status}: {label}'
          + (f' -- {detail}' if detail and not cond else ''))
    if not cond:
        failures.append(label)
    return cond


# ---------------------------------------------------------------------
# The independent implementation. Regex-driven, not lstrip()-driven --
# deliberately a different mechanism from strip_comments.strip_text()
# so the two share no code to both get wrong the same way.
# ---------------------------------------------------------------------
SEMI_AFTER_BLANK_RE = re.compile(r'^[ \t]*;')
FIRST_NONBLANK_RE = re.compile(r'^[ \t]*(\S)')


class IndependentIndentedStar(ValueError):
    """The independent implementation's own tripwire -- reimplemented
    from the spec, not imported from strip_comments.IndentedStarComment."""


def independent_strip(text, name='<text>'):
    lines = text.split('\n')
    out = []
    for lineno, line in enumerate(lines, 1):
        if SEMI_AFTER_BLANK_RE.match(line):
            out.append('')
            continue
        if line[:1] == '*':
            out.append('')
            continue
        m = FIRST_NONBLANK_RE.match(line)
        if m is not None and m.group(1) == '*':
            raise IndependentIndentedStar(
                f'{name}:{lineno}: first non-blank character is "*" but '
                f'column 0 is blank (independent regex impl). Line as '
                f'read: {line!r}')
        out.append(line)
    return '\n'.join(out)


# ---------------------------------------------------------------------
# CHECK 1 -- tree-wide differential: strip_comments.strip_text() against
# independent_strip(), over every file check_manifests.universe() names.
# Also re-derives, per file and independently of BOTH implementations'
# own internal asserts, that line count is preserved (blank-SUBSTITUTION,
# never blank-DELETION) and that every non-blanked line is byte-identical
# to its input -- the property that keeps Merlin's line-numbered
# diagnostics pointing at the right master-tree line.
# ---------------------------------------------------------------------
def check_differential():
    paths = sorted(cm.universe())
    mismatches = []
    total_lines = 0
    col0_star = col0_semi = indent_semi = 0

    for path in paths:
        rel = os.path.relpath(path, ROOT)
        with open(path, errors='replace') as f:
            text = f.read()
        lines_in = text.split('\n')

        try:
            got = sc.strip_text(text, name=rel)
            got_exc = None
        except Exception as exc:  # noqa: BLE001 -- report, don't crash
            got, got_exc = None, exc

        try:
            want = independent_strip(text, name=rel)
            want_exc = None
        except Exception as exc:  # noqa: BLE001
            want, want_exc = None, exc

        raised_disagree = (
            isinstance(got_exc, sc.IndentedStarComment)
            != isinstance(want_exc, IndependentIndentedStar))
        if raised_disagree or (got_exc and not want_exc) \
                or (want_exc and not got_exc):
            mismatches.append(
                f'{rel}: strip_comments {"raised " + repr(got_exc) if got_exc else "did not raise"}, '
                f'independent impl {"raised " + repr(want_exc) if want_exc else "did not raise"} '
                f'-- disagreement on the ambiguous indented-"*" case')
            continue
        if got_exc is not None:
            # Both raised on the same (ambiguous) input -- agreement.
            continue

        if got != want:
            lines_got = got.split('\n')
            lines_want = want.split('\n')
            first_diff = next(
                (i for i, (a, b) in enumerate(zip(lines_got, lines_want), 1)
                 if a != b), None)
            mismatches.append(
                f'{rel}: strip_comments and the independent implementation '
                f'DISAGREE'
                + (f' starting at line {first_diff}: strip_comments='
                   f'{lines_got[first_diff - 1]!r} independent='
                   f'{lines_want[first_diff - 1]!r}' if first_diff else ''))
            continue

        # Re-derive line-count preservation ourselves -- catches a
        # sabotage that deletes blanked lines instead of emptying them,
        # even one that also disables strip_text()'s own internal
        # asserts, since this check never looks at those.
        lines_out = got.split('\n')
        if len(lines_out) != len(lines_in):
            mismatches.append(
                f'{rel}: line count changed {len(lines_in)} -> '
                f'{len(lines_out)} -- blank-substitution must preserve '
                f'line count (Merlin\'s diagnostics are line-numbered).')
            continue

        for a, b in zip(lines_in, lines_out):
            if b == '' and a != '':          # actually blanked, not
                                              # already an empty line
                if a[:1] == '*':
                    col0_star += 1
                else:
                    indent_semi += 1 if a[:1] in (' ', '\t') else 0
                    col0_semi += 0 if a[:1] in (' ', '\t') else 1
            elif a != b:
                mismatches.append(
                    f'{rel}: a line not blanked came out changed: '
                    f'{a!r} -> {b!r}')
        total_lines += len(lines_in)

    check(f'strip_comments.strip_text() and the independent regex '
          f'implementation agree on all {len(paths)} file(s) in '
          f'check_manifests.universe()',
          not mismatches,
          '; '.join(mismatches[:5])
          + (f' (+{len(mismatches) - 5} more)' if len(mismatches) > 5 else ''))

    blanked = col0_star + col0_semi + indent_semi
    print(f'[check-strip] blanked-line breakdown: {col0_star} column-0 "*" '
          f'+ {col0_semi} column-0 ";" + {indent_semi} indented ";" '
          f'= {blanked} of {total_lines} total lines '
          f'({100.0 * blanked / total_lines:.2f}% by line, over '
          f'{len(paths)} files)')

    check(f'blanked-line count stays at or above the {BASELINE_BLANKED_LINES}'
          f'-line floor (measured 2026-08-23; ratchet, see module '
          f'docstring -- a drop below this is the sabotage signature, '
          f'ordinary growth only raises it)',
          blanked >= BASELINE_BLANKED_LINES,
          f'{blanked} < {BASELINE_BLANKED_LINES} -- {BASELINE_BLANKED_LINES - blanked} '
          f'fewer blanked lines than the pinned floor: the rule likely '
          f'narrowed (stopped recognising a comment shape it used to).')

    return blanked, total_lines, len(paths)


def main():
    os.chdir(ROOT)

    check_differential()

    print()
    if failures:
        print(f'[check-strip] FAIL: {len(failures)} check(s) failed:')
        for f in failures:
            print(f'    {f}', file=sys.stderr)
        return 1
    print('[check-strip] PASS: strip_comments.strip_text() agrees with an '
          'independent regex implementation of the same operator spec on '
          'every file in check_manifests.universe(), byte for byte, line '
          'count preserved, and the blanked-line count is at or above the '
          'measured floor')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
