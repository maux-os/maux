#!/usr/bin/env python3
"""strip_comments.py -- blank out comment-only lines, the single definition
of "strip" for every consumer that needs it.

    python3 scripts/strip_comments.py PATH   # or: ... < PATH  (reads stdin)
    python3 scripts/strip_comments.py --selftest

WHY THIS EXISTS. Comment-only lines are 28.6% of this tree BY LINE COUNT
(21,311 / 74,638) but 45.0% BY BYTE COUNT (1,154,266 / 2,566,703 --
measured 2026-08-23 over check_manifests.universe(): comment TEXT runs
longer per line than code does, so the byte share outweighs the line
share) -- the byte share is the one that matters here, since it is
bytes, not lines, that fill the 41,215-byte source buffer below. Real
Merlin-8 holds the file it is assembling as TEXT in a 41,215-byte buffer
($0901..$AA00, learning:01M051EM2HQ3ZVJTR1W9P3G86J) -- a comment costs the
same as code there. The master tree keeps every comment (that is how the
tree stays readable and how docs/PLAN.md's provenance trail works); only the
form STAGED onto the self-hosting disk image gets stripped. This module has
THREE consumers already planned -- build_maux_src_image.py (staging), the
budget gate (check_dialect.py's check_budget, which needs stripped sizes to
judge the real headroom), and a differential sed gate that checks this
module's output against an independent implementation. Three consumers of
one fact is exactly the shape that drifted apart four times in two days in
this tree (see HACKING.md's "Knowing a house tool exists" entry and the
docs/PLAN.md S9 note) -- so the rule lives in exactly one function, here,
and everything else imports it.

THE RULE (operator specification, exact). A line is comment-only iff, after
stripping leading spaces and tabs, the remainder begins with `;` OR the
line's COLUMN-0 character is `*`. (These are different tests on purpose:
`;` comments Merlin-8 anywhere on the line once code has ended, `*` is a
Merlin-8 whole-line-comment directive that is only a comment in column 0 --
see learning:01M04SAJTJAYXCR3YNFW313FMZ's note that even a bare `*` line is
subject to the 64-character limit, which is what put comments in the budget
picture at all.)

WHY BLANK, NOT DELETE. A comment-only line's entire content becomes the
empty string -- the line stays, just empty. Deleting the line would be a
few bytes cheaper (no line stays around to hold just a newline), but it
would shift every following line's number. Real Merlin's own diagnostics
are line-numbered ("Operand too long in line: N", "Bad label in line: N",
the various assembly errors this tree already fights -- learning:
01M04SAJTJAYXCR3YNFW313FMZ, learning:01M050C6KW01MPJ2TQTPMTZXN6). Blanking
keeps the STRIPPED image's line N pointing at the same source line as the
MASTER tree's line N, so a diagnostic against the staged image still tells
a human where to look in the file they actually edit. Blank-substitution
costs about one byte per stripped line -- measured on this tree
2026-08-23: 17,294 column-0 `*` lines + 20 column-0 `;` lines + 3,997
indented `;` lines = 21,311 lines, roughly 21 KB tree-wide, under 1% of the
~1.15 MB those same lines occupy as comment TEXT (938,410 + 724 + 215,132
bytes) -- a trivial price for keeping line numbers load-bearing.

EVERY OTHER LINE PASSES THROUGH BYTE FOR BYTE. No rstrip, no tab expansion,
no newline normalisation. A line that is not comment-only -- including a
line with a trailing `code ;comment` -- is emitted exactly as read. (Only
whole-line comments are in scope; this module does not touch inline
trailing comments, which is a separate, unimplemented reduction.)

THE TRIPWIRE. If a line's first non-blank character is `*` but column 0 is
NOT `*` (i.e. the line is indented), this raises IndentedStarComment rather
than guessing. Measured on this tree 2026-08-23: zero such lines exist
(the column-0-`*` / indented-`;` counts above are exhaustive over
src/**/*.s, src/**/*.equ, inc/*.equ). What an indented `*` means to
Merlin-8 is NOT established -- it could be a whole-line comment (blanking
is safe), it could be an expression starting with the multiply/current-PC
operator (blanking would delete code), and nothing in this tree's measured
dialect facts settles it. Guessing wrong in either direction is a silent
correctness bug reachable only by future code nobody has written yet;
refusing is the only behaviour that is safe to ship now and forces the
question to be answered explicitly if it ever comes up.

INVARIANTS ASSERTED ON EVERY CALL (not just documented): output line count
equals input line count; every line that was not blanked is byte-identical
to its input; total output length never exceeds total input length. These
are cheap to check and are exactly the properties that make "the master
diagnostic still points at the right line" and "this cannot delete code"
true -- see also learning:01M0KXP2S11CFQ0HYZVS5P889Z on why a generator
that touches every line in a tree needs its own render(extract(x))==x
proof rather than a spot check.
"""
import sys


class IndentedStarComment(ValueError):
    """Raised when a line's first non-blank character is '*' but column 0
    is not -- an ambiguous construct this module refuses to guess about.
    See the module docstring's TRIPWIRE section."""


def strip_text(text, name='<text>'):
    """Return `text` with every comment-only line's content replaced by the
    empty string. Line count and line ORDER are preserved exactly; see the
    module docstring for the exact rule and the invariants asserted below."""
    lines_in = text.split('\n')
    lines_out = []
    for lineno, content in enumerate(lines_in, 1):
        stripped = content.lstrip(' \t')
        if stripped[:1] == ';':
            lines_out.append('')
        elif content[:1] == '*':
            lines_out.append('')
        elif stripped[:1] == '*':
            raise IndentedStarComment(
                f'{name}:{lineno}: first non-blank character is "*" but '
                f'column 0 is blank -- an indented "*" comment. Merlin-8 '
                f'dialect semantics for this are NOT established (see '
                f'strip_comments.py\'s TRIPWIRE note); refusing to guess '
                f'whether to blank it (comment) or pass it through '
                f'(possible code). Line as read: {content!r}')
        else:
            lines_out.append(content)

    assert len(lines_out) == len(lines_in), (
        f'{name}: line count changed, {len(lines_in)} -> {len(lines_out)}')
    for lineno, (before, after) in enumerate(zip(lines_in, lines_out), 1):
        if after != '':
            assert after == before, (
                f'{name}:{lineno}: a line not blanked came out changed: '
                f'{before!r} -> {after!r}')

    out = '\n'.join(lines_out)
    assert len(out) <= len(text), (
        f'{name}: output ({len(out)} bytes) grew past input ({len(text)})')
    return out


def strip_file(path):
    """strip_text() over the file at `path`, read the same way the rest of
    this tree's build tooling reads source (build_maux_src_image.py's own
    module loop uses errors='replace' for the same reason)."""
    with open(path, errors='replace') as f:
        text = f.read()
    return strip_text(text, name=path)


def _selftest():
    cases = [
        ('foo\n; comment\nbar\n', 'foo\n\nbar\n'),
        ('*banner\ncode\n', '\ncode\n'),
        ('*\ncode\n', '\ncode\n'),                    # bare '*' line
        (' ; indented semicolon comment\ncode\n', '\ncode\n'),
        ('\t; tab-indented semicolon\n', '\n'),
        ('code ; trailing comment stays\n', 'code ; trailing comment stays\n'),
        ('   \ncode\n', '   \ncode\n'),                # whitespace-only: not comment-only
        ('', ''),
        ('no trailing newline', 'no trailing newline'),
        ('\n\n\n', '\n\n\n'),
    ]
    for src, expect in cases:
        got = strip_text(src, name='<selftest>')
        assert got == expect, (
            f'selftest FAIL: strip_text({src!r}) = {got!r}, want {expect!r}')

    # The tripwire: a SYNTHETIC indented-'*' line, fed here rather than
    # added to the tree (the tree has zero of these, measured 2026-08-23).
    try:
        strip_text('  * indented star, ambiguous\ncode\n', name='<tripwire-test>')
    except IndentedStarComment:
        pass
    else:
        raise AssertionError(
            'selftest FAIL: indented "*" line did not raise IndentedStarComment')

    print(f'[strip_comments] selftest PASS ({len(cases)} cases + tripwire)')
    return 0


def main(argv):
    if argv and argv[0] == '--selftest':
        return _selftest()
    if argv:
        out = strip_file(argv[0])
    else:
        out = strip_text(sys.stdin.read(), name='<stdin>')
    sys.stdout.write(out)
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
