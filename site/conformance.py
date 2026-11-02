"""Rows of the Conformance page's table (docs/SITE.md).

Heritage and "notable differences" are prose, taken from the tree (the
manual pages' source headers and BUGS sections, docs/POSIX-GAPS.md,
docs/SED.md, docs/MAKE-POSIX.md, docs/SH-FEATURES.md). Every NUMBER is a
{{fact:cf_*}} placeholder (site/facts.py), never typed here: check-site
fails on a bare number in this file's prose or in the page.

Each row: (tool, heritage, checked against, matching, notes, source).
`source` is for maintainers; it is not published.
"""

P = '{{fact:cf_%s_pass}} of {{fact:cf_%s_total}}'


def pt(key):
    return P % (key, key)


def util(tool):
    return ('{{fact:cf_u_%s_pass}} of {{fact:cf_u_%s_total}}' % (tool, tool))


ROWS = [
    ('vi',
     'Second Berkeley Software Distribution (2BSD). Bill Joy\'s visual '
     'mode for <code>ex</code>, first installed under the name '
     '<code>vi</code>.',
     'macOS vi (Vim in vi mode)',
     pt('vi'),
     'Brought up to the POSIX vi text. No normal-mode filter command (use '
     '<code>:%!cmd</code>), no <code>R</code> replace mode, no crash '
     'recovery; a file holds a limited number of lines.',
     'docs/man/vi.1 header and BUGS; docs/POSIX-GAPS.md. Heritage: BSD ex(1) HISTORY (vi in 2BSD; the tree header names no date)'),
    ('ex',
     'First Berkeley Software Distribution (1BSD), where it shipped as '
     '<code>ex</code>. Bill Joy\'s extended <code>ed</code>; its second version '
     'came with 2BSD.',
     'macOS ex (Vim in ex mode)',
     pt('ex'),
     'Brought up to the POSIX ex text. No tags, no multi-file '
     '<code>next</code> list, no crash recovery.',
     'docs/man/ex.1 header and BUGS. Heritage: BSD ex(1) HISTORY (ex in 1BSD, second version in 2BSD)'),
    ('sed',
     'Version 7 Unix.',
     'macOS sed (BSD sed); only constructs BSD and GNU sed agree on',
     pt('sed'),
     'Rewritten to the POSIX sed text. Very long input lines are cut '
     'short.',
     'docs/SED.md; docs/man/sed.1'),
    ('Regular expressions',
     'POSIX basic regular expressions, as in ed and grep. One engine serves '
     'grep, sed, ed, ex and vi.',
     'the AT&amp;T (Fowler) and Spencer regular-expression test files',
     pt('fowler'),
     'Extended regular expressions are not provided. A malformed pattern '
     'quietly matches nothing instead of being reported as an error '
     '({{fact:cf_fowler_unscored}} test rows expect an error and are not '
     'counted).',
     'docs/POSIX-CONFORMANCE.md; scripts/check_fowler.py'),
    ('sh',
     'Version 7 Bourne shell, by design. <code>eval</code>, '
     '<code>set -e</code> and prefix assignments are Version 7 already. '
     'The POSIX additions that fit: <code>getopts</code>, '
     '<code>$( )</code>, <code>${V%pat}</code>, <code>command</code>.',
     'macOS /bin/sh (bash in POSIX mode), construct by construct',
     '{{fact:cf_sh_pass}} of {{fact:cf_sh_total}}',
     'Not a full POSIX shell. No functions (they came after Version 7), no '
     'backquotes, no <code>$(( ))</code> arithmetic (use <code>expr</code>). '
     'What differs is listed below.',
     'docs/man/sh.1; docs/SH-FEATURES.md; docs/POSIX-GAPS.md sec 3'),
    ('grep',
     'Version 4 Unix, written by Ken Thompson so a colleague could '
     'analyse the Federalist Papers. The manual page maux follows is '
     'the Version 6 one.',
     'macOS grep',
     util('grep'),
     'Basic regular expressions only: <code>grep -E</code> is not '
     'provided, and that counts as a difference, not a match.',
     'docs/man/grep.1 header (V6 page); named gaps. Heritage: BSD grep(1) HISTORY (grep appeared in Version 4)'),
    ('make',
     'Version 7 <code>make</code>, plus the POSIX inference rules and '
     'macros.',
     'macOS make (comparing what each would run), and the POSIX text',
     util('make'),
     'No shell between make and the command, so no pipes, redirection or '
     'globbing in a recipe. No <code>include</code>, no parallel jobs.',
     'docs/MAKE-POSIX.md; POSIX-GAPS make row'),
    ('ed',
     'The original Unix line editor (Version 1), as a small '
     'subset.',
     'not scored against a reference',
     '&mdash;',
     'Smaller than the original <code>ed</code> on purpose. No undo, '
     'marks, backward search or shell escape. Version 1 already had '
     'backward search and the shell escape; <code>ex</code> has them all.',
     'docs/man/ed.1 header (V1 page) and BUGS; the V1 ed page has ?re? and !'),
    ('The other standard utilities',
     'Mostly Research Unix: <code>cat</code>, <code>ls</code>, '
     '<code>cp</code>, <code>mv</code>, <code>rm</code>, <code>wc</code>, '
     '<code>od</code>, <code>sort</code>, <code>find</code>, <code>tr</code>, '
     '<code>uniq</code>, <code>tail</code> and more. <code>csplit</code> '
     'is from PWB/UNIX. Newer ones (<code>cut</code>, <code>paste</code>, '
     '<code>printf</code>, <code>nl</code>, <code>timeout</code>) were '
     'written from the POSIX text.',
     'the host&rsquo;s own utilities (macOS BSD tools); the POSIX text '
     'where those disagree',
     '{{fact:cf_util_pass}} of {{fact:cf_util_total}}, across '
     '{{fact:cf_util_tools}} utilities',
     '{{fact:cf_util_gaps}} known differences are counted as differences, '
     'and listed below. Some can never close because ProDOS has no owners, '
     'groups or modes.',
     'docs/man headers; docs/POSIX-GAPS.md; docs/POSIX-CONFORMANCE.md. Heritage: csplit(1) HISTORY in OpenBSD and FreeBSD (PWB UNIX)'),
    ('man, more',
     '<code>man</code> dates from the Second Edition. '
     '<code>more</code> is BSD; Version 7 had no pager.',
     '<code>man</code>: the POSIX text. <code>more</code>: not scored',
     util('man') + ' (man)',
     'Manual pages are plain text, paged through <code>more</code>.',
     'docs/man/more.1 header; docs/MAN.md. Heritage: BSD man(1) HISTORY (Second Edition)'),
    ('bye, mount, umount, chvt, vidmode, nulib2, tip',
     'maux and Apple II specific. (<code>tip</code> is a BSD tool, '
     'adapted to the serial card.)',
     'nothing: no other Unix has these',
     '&mdash;',
     'They exist because of the machine: running a ProDOS program, '
     'mounting disk images, switching consoles, ShrinkIt archives.',
     'docs/man headers (bye, nulib2, chvt original; tip 4.3BSD)'),
]
