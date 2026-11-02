#!/usr/bin/env python3
r"""posixutil_cases2.py -- round 2 of the POSIX.1-2024 conformance gate:
CASES2/KNOWN_GAPS2 for wc, tail, uniq, tr, sort, od, find, diff, ls, cp,
mv, rm, date, touch, du, tee, echo (the BINARY, /bin/ECHO -- the
shell builtin shadows the bare name) and kill. `check_posixutil.py`
imports this module and appends CASES2/KNOWN_GAPS2 onto its own
CASES/KNOWN_GAPS -- see that file's own docstring for the shared
METHOD (host oracle in a scratch dir, a2til staging, one shell prompt
per case, `hi()`/`hilines()`/`maux_lines()`/`host_lines()`/`render()`
from check_posixsed.py). C()/Q() are duplicated here in miniature
rather than imported, to avoid a circular import (check_posixutil.py
imports THIS module after its own C/Q are defined, but this module
must not import check_posixutil back).

WHERE THIS ROUND'S HAND ROWS COME FROM, so the reasons below aren't
each repeated in every `reason=`:

  wc: every NON-GAP row is hand-authored. BSD wc (this host's oracle)
  right-pads each column to an 8-char field (measured live: `wc
  x.txt` -> "       3       3      20 x.txt"); wc.s's REPORT prints
  PRNUM's plain unpadded decimal with single-space separators. The
  VALUES agree (both count the same CR/newline-terminated fixture the
  same way -- lines=lines, words=whitespace runs, bytes=bytes, and
  this harness stages every fixture CR/newline-terminated on BOTH
  sides, so there is no "final unterminated line" edge to disagree
  over); only the WHITESPACE differs, so every non-gap case is hand-
  authored to wc.s's own documented format string rather than a
  captured host run. The one KNOWN_GAPS row (multiple files: no
  totals line) stays host-oracled on purpose -- see its own comment.

  od: EVERY row is hand-authored. od.s's own header rules the default
  to hex bytes (docs/ANACHRONISMS.md A3) where BSD/GNU od defaults to
  octal 16-bit words with an octal offset column -- not a values
  disagreement to paper over with `-t x1 -A x`-style flag translation
  (od.s doesn't have `-t`/`-A` at all, that's the KNOWN_GAPS half of
  this table), a structurally different DEFAULT. Every hand row is
  computed directly from the fixture's own on-disk bytes (this
  harness's own hi()/hilines() encoding: high-bit ASCII, one CR
  ($8D) per line) via od_expected() below, which mirrors od.s's
  PRROWHEX/PRROWOCT/PRROWCHR/PRHEX4 exactly (src/bin/od.s).

  date: `reset={'clock': False}` (see check_posixutil.C's own
  docstring) pins the Timemaster card OFF so date.s's NOCLOCK path is
  the only reachable one -- deterministic without a peek. This tests
  a real, documented code path (date.s: "the ONE machine feature this
  tool needed... if the clock is ABSENT... a message goes to fd 2 and
  it exits 1"), not the live-clock format shape a synchronized peek
  would need (that is check_sumdate.py's own job, already done).

  cp -r / mv / rm -r / touch: verified through a `post` follow-up
  command in the SAME shell session (mkdir.s's own '-p creates
  missing intermediate components' case set this precedent) --
  necessarily `hand=`, since oracle()'s host path runs exactly ONE
  process per case and never a `post` step (check_posixutil.py's
  `_host_once` has no such hook), so there is no host run to diff a
  `post`-verified side effect against regardless of tool.

  kill: NO $! (docs/POSIX-GAPS.md sec 3: "`$!`... missing"), and
  `jobs` prints no pid (shjob.s: "`[n]<+|-|> <state> <cmd>` per live
  row" -- no pid column) -- so a backgrounded `sleep 30 &`'s pid is
  NOT recoverable from this harness's typed-line/read-back shape
  without a NEW mechanism (a peek synchronized to the spawn, the same
  problem check_sumdate.py solved for the clock, or a generic `pre`
  hook this suite does not have). Per the task's own escape hatch,
  this is documented rather than built: kill IS tested for real,
  against a pid this harness DOES know without a shell handshake --
  `$$` (a supported shell special, docs/POSIX-GAPS.md's "Have" list)
  targets the INTERACTIVE SHELL itself. FIRST DRAFT of this module
  assumed $$ would be root-tier-protected (src/kernel/procspawn2.s's
  "root tier (parent 0) is protected") and hand-authored `kill -0 $$`
  / `kill -9 $$` to both read 'cannot kill'. Running it found that
  assumption WRONG for -0 (measured: exit 0, an ordinary live-pid
  probe) and found something much more interesting for -9: it HANGS
  THE CONSOLE (see KILL_CASES's own header comment for the mechanism
  and why it is reported, not staged as a case). Corrected here rather
  than left to look intentional.

  echo XSI escapes: SKIPPED, not a KNOWN_GAPS2 row -- this Mac's own
  oracle (BSD /bin/echo, verified live) does not interpret `\n`/`-e`
  by default either (`/bin/echo 'a\nb'` -> literal `a\nb`; `/bin/echo
  -e 'a\nb'` -> literal `-e a\nb`), so there is no LOCAL divergence
  this host can demonstrate; it would only show up against GNU
  coreutils' `echo -e` on the box. Documented per the task's own
  "unexpressible" allowance rather than manufactured.
"""

# ======================================================================
# tiny local duplicates of check_posixutil.C()/Q() -- see this file's
# own header for why they are not imported from there.
# ======================================================================
from posixutil_interactive import (IR, WAIT, TYPE, APPEND,     # noqa: E402
                                  CTRL_C)


def C(tool, name, spec, argv, *, files=None, dirs=None, predirs=None,
      stdin=None, results=None, post=None, hand=None, known_gap=None,
      reset=None, norm=None, meta_equal=None):
    """`norm` names a check_posixutil.NORMALIZERS entry -- see that
    module's own NORMALIZERS block for what one is allowed to be. It
    is NOT validated here (this file must not import its parent), so
    a typo surfaces as an unknown-norm RuntimeError the moment
    check_posixutil.C sees the same name; every row below passes a
    name that block defines."""
    return dict(tool=tool, name=name, spec=spec, argv=list(argv),
                files=files or {}, dirs=dirs or {},
                predirs=list(predirs or []), stdin=stdin,
                results=list(results or []), post=list(post or []),
                hand=hand, known_gap=known_gap, reset=reset, norm=norm,
                meta_equal=list(meta_equal or []))


def Q(word):
    return "'" + word + "'"


def QQ(word):
    """Double-quote wrap -- printf's own format strings need this,
    not Q()'s single quotes: a bare backslash inside SINGLE quotes is
    not always literal on this sh (found 2026-09-14, landing printf,
    verified live on the emulator, not fixed here -- out of scope).
    `'...\\n...'` confuses sh's own quote/line scanner ('sh:
    unterminated quote'/'mixed quoting'); double quotes side-step it
    (verified live: `PRINTF "%s\\012" hello` runs clean). check_posix
    util.py's own unquote() strips this same wrap on the host side."""
    return '"' + word + '"'


# ======================================================================
# wc -- hand-computed from the fixture; see module header.
# ======================================================================
def _hi_bytes(lines):
    """The on-disk byte count/shape of a liba text file staged by this
    harness's hilines(): every line + one CR, high bit irrelevant to
    a COUNT (wc) or a byte-VALUE dump (od) -- od needs the bit, wc
    does not; each helper below takes what it needs."""
    return b''.join(bytes(ord(c) | 0x80 for c in ln) + bytes([0x8D])
                     for ln in lines)


def wc_counts(lines):
    nlines = len(lines)
    nwords = sum(len(ln.split()) for ln in lines)
    nbytes = sum(len(ln) + 1 for ln in lines)
    return nlines, nwords, nbytes


def wc_line(lines, name=None, want='lwc'):
    nl, nw, nb = wc_counts(lines)
    vals = []
    if 'l' in want:
        vals.append(str(nl))
    if 'w' in want:
        vals.append(str(nw))
    if 'c' in want:
        vals.append(str(nb))
    s = ' '.join(vals)
    if name:
        s += ' ' + name
    return s


WC_REASON = ('BSD wc pads each column to a fixed field width (measured '
             'live); wc.s\'s PRNUM prints unpadded decimal with single-'
             'space separators. Same VALUES (both fixtures are CR/'
             'newline-terminated on every line, so there is no '
             'unterminated-final-line edge to disagree over) -- hand-'
             'authored to wc.s\'s own documented format, not a host '
             'capture.')

L3W = ['one two', 'three', 'four five six']

WC_CASES = [
    C('wc', 'default: all three columns', 'wc [-lwc] [file...]',
      ['@F@'], files={'F': L3W},
      hand=dict(stdout=[wc_line(L3W, 'F')], rc=0,
                reason=WC_REASON)),
    C('wc', '-l lines only',
      '"%d %d %d %s\\n", <newlines>, <words>, <bytes>, <file>',
      ['-l', '@F@'], files={'F': L3W},
      hand=dict(stdout=[wc_line(L3W, 'F', 'l')], rc=0,
                reason=WC_REASON)),
    C('wc', '-w words only', 'wc [-lwc] [file...]',
      ['-w', '@F@'], files={'F': L3W},
      hand=dict(stdout=[wc_line(L3W, 'F', 'w')], rc=0,
                reason=WC_REASON)),
    C('wc', '-c bytes only', 'wc [-lwc] [file...]',
      ['-c', '@F@'], files={'F': L3W},
      hand=dict(stdout=[wc_line(L3W, 'F', 'c')], rc=0,
                reason=WC_REASON)),
    C('wc', '-lw combination', 'wc [-lwc] [file...]',
      ['-l', '-w', '@F@'], files={'F': L3W},
      hand=dict(stdout=[wc_line(L3W, 'F', 'lw')], rc=0,
                reason=WC_REASON)),
    C('wc', 'no file operand reads stdin, no name column',
      'If no input file operands are specified, no name shall be '
      'written',
      [], files={'IN': L3W}, stdin='IN',
      hand=dict(stdout=[wc_line(L3W)], rc=0, reason=WC_REASON)),
    C('wc', 'stdin with -l, no name column', 'wc [-lwc] [file...]',
      ['-l'], files={'IN': L3W}, stdin='IN',
      hand=dict(stdout=[wc_line(L3W, want='l')], rc=0,
                reason=WC_REASON)),
    C('wc', '-m (bytes==chars in the C locale)',
      '-m The number of characters in each input file shall be '
      'written to the standard output.',
      ['-m', '@F@'], files={'F': L3W},
      hand=dict(stdout=[wc_line(L3W, 'F', 'c')], rc=0,
                reason=WC_REASON + ' -m sets the same WANT_C cell '
                '-c does (chars == bytes in the C locale), so its '
                'output is byte-identical to -c.')),
    C('wc', 'multiple files: totals line',
      'an additional line shall be written...the word total... shall '
      'be written instead of a pathname',
      ['@F1@', '@F2@'], files={'F1': ['a'], 'F2': ['b', 'c']},
      # hand-authored, like every other wc row above -- BSD's column
      # PADDING is a project-wide, already-accepted divergence
      # (WC_REASON): maux prints unpadded values with single-space
      # separators everywhere, and this row does not reopen that.
      # What it DOES check is the real thing that was missing: a
      # third "total" line summing both files' counts.
      hand=dict(stdout=[wc_line(['a'], 'F1'), wc_line(['b', 'c'], 'F2'),
                         wc_line(['a', 'b', 'c'], 'total')], rc=0,
                reason=WC_REASON + ' The totals line sums both '
                'files\' counts (SHIPPED 2026-09-17, ADDTOT/TOTAL '
                'in wc.s) and prints "total" in place of a name.')),
]


# ======================================================================
# tail
# ======================================================================
N10 = [str(i) for i in range(1, 11)]

TAIL_CASES = [
    C('tail', 'default is the last 10 lines',
      '-n 10 shall be assumed... the starting location in the file '
      'shall be measured in lines',
      ['@F@'], files={'F': [str(i) for i in range(1, 26)]}),
    C('tail', '-n N explicit count', '-n number',
      ['-n', '3', '@F@'], files={'F': N10}),
    C('tail', '-N obsolescent bare-number form',
      'Earlier versions of this standard allowed the following forms '
      'in the SYNOPSIS: tail -[number]... These forms are no longer '
      'specified by POSIX.1-2024, but may be present in some '
      'implementations.',
      ['-3', '@F@'], files={'F': N10}),
    C('tail', 'short file copied in its entirety',
      'The tail utility shall copy its input file to the standard '
      'output beginning at the designated point.',
      ['-n', '20', '@F@'], files={'F': ['a', 'b']}),
    C('tail', 'no operand reads stdin',
      'The standard input shall be used if no file operand is '
      'specified',
      ['-n', '2'], files={'IN': N10}, stdin='IN'),
    C('tail', 'multiple file operands are refused',
      'file -- A pathname of an input file.',
      ['@F1@', '@F2@'], files={'F1': ['a'], 'F2': ['b']},
      hand=dict(stdout=[], rc=2,
                reason="tail.s's own :ncheck refuses more than one "
                       "operand outright (`cmp #2; bcs :usage`) -- "
                       "the SYNOPSIS this tool implements is single-"
                       "file only (tail.s header: 'tail [-n N | -N] "
                       "[file]'); BSD tail happens to also take only "
                       "one file operand (its own usage line agrees), "
                       "so this is not a host-vs-maux capability gap "
                       "at all -- it is hand-authored because a THIRD "
                       "argv word makes BSD tail's own parser reject "
                       "it too (ambiguous which of two files it means "
                       "under -r), and the two engine's exact refusal "
                       "shapes (usage text aside) are not guaranteed "
                       "to share an exit code.")),
    C('tail', '-c byte count',
      '-c number -- ...copying begins at a location...measured in '
      'bytes.',
      ['-c', '3', '@F@'], files={'F': ['abcdef']},
      hand=dict(stdout=['ef'], rc=0,
                reason="SHIPPED 2026-09-17: -c routes through a "
                       "second, byte-granularity ring (MODEBYTE/"
                       "CNBYTES/WBPOS in tail.s), capped at "
                       "MAXBYTES=255 so the whole path stays 8-bit. "
                       "File 'abcdef\\r' is 7 raw bytes; the last 3 "
                       "are 'e','f',CR -- maux_lines() strips the "
                       "high bit and the CR becomes the line split, "
                       "leaving one line: 'ef'.")),
    # RETIRED 2026-10-08 (docs/POSIX-HARNESS.md). Was a KNOWN_GAP whose
    # reason, kept here as the finding: "a real -f is a POLLING LOOP
    # that runs until ^C -- it has no bounded exit for this harness's
    # run-one-command-capture-status shape to observe". The shape was
    # the blocker, not the tool: this row is now an INTERACTIVE row
    # (posixutil_interactive.py) -- wait for the first lines, have the
    # file appended to, wait for the new line, type ^C -- and the
    # compared stream is everything a person would have seen, ^C echo
    # and exit status 130 included. Host oracles agree (BSD and GNU:
    # POSIX-HARNESS-NOTES.md).
    IR('tail', '-f follows a file that is appended to',
      '-f ...continue reading and copying bytes as they become '
      'available',
      ['-f', '@F@'],
      [WAIT('bravo'), APPEND('F', ['delta']), WAIT('delta'),
       TYPE(CTRL_C)],
      files={'F': ['alpha', 'bravo']}),
]


# ======================================================================
# uniq
# ======================================================================
UNIQ_RUNS = ['a', 'a', 'b', 'b', 'b', 'c']


def uniq_c_line(n, text):
    """uniq.s's own CNTFLD is 5 (src/bin/uniq.s), NOT the 4 a live BSD
    uniq -c uses (measured: `printf 'a\\na\\nb\\nb\\nb\\nc\\n' | uniq -c`
    -> '   2 a' -- 3 spaces). Same values, different field width -- the
    same shape as WC_REASON, so -c is hand-authored too."""
    return f'{n:>5} {text}'


UNIQ_C_REASON = ("uniq.s's CNTFLD is 5 (src/bin/uniq.s: '-c count field "
                 "width'), right-aligning the count in a 5-char field "
                 "before the one separator space; a live BSD uniq -c "
                 "measured on this Mac pads to 4 instead ('   2 a', "
                 "three spaces, not four). Same VALUES, different "
                 "WIDTH -- hand-authored to uniq.s's own documented "
                 "field width, not a host capture.")

UNIQ_CASES = [
    C('uniq', 'default collapses adjacent runs',
      'The second and succeeding copies of repeated adjacent input '
      'lines shall not be written.',
      ['@F@'], files={'F': UNIQ_RUNS}),
    C('uniq', '-c prefixes the run count',
      'Precede each output line with a count of the number of times '
      'the line occurred in the input.',
      ['-c', '@F@'], files={'F': UNIQ_RUNS},
      hand=dict(stdout=[uniq_c_line(2, 'a'), uniq_c_line(3, 'b'),
                         uniq_c_line(1, 'c')], rc=0,
                reason=UNIQ_C_REASON)),
    C('uniq', '-d only the duplicated runs',
      'Suppress the writing of lines that are not repeated in the '
      'input.',
      ['-d', '@F@'], files={'F': UNIQ_RUNS}),
    C('uniq', '-u only the unique runs',
      'Suppress the writing of lines that are repeated in the input.',
      ['-u', '@F@'], files={'F': UNIQ_RUNS}),
    C('uniq', 'input and output operands',
      'output_file -- A pathname of the output file.',
      ['@F@', '@OUT2@'], files={'F': UNIQ_RUNS, 'OUT2': None},
      results=['OUT2']),
    C('uniq', '-d and -u together: BSD combines, maux refuses',
      '-d ... -u ... (POSIX does not define their combination)',
      ['-d', '-u', '@F@'], files={'F': UNIQ_RUNS},
      hand=dict(stdout=[], rc=2,
                reason="live BSD uniq -d -u on this fixture prints "
                       "'a' (it evaluates the two filters in an if/"
                       "else chain and -d wins), exit 0 -- permissive, "
                       "undefined-by-POSIX behaviour. uniq.s's own "
                       "header states the opposite choice outright: "
                       "'-d and -u together are a usage error: "
                       "message to fd 2, exit 2.' Both are POSIX-"
                       "legal (the spec does not mandate a shape for "
                       "this combination), so this is hand-authored "
                       "to maux's own documented contract rather than "
                       "a captured BSD run.")),
    C('uniq', '-f skip-fields',
      '-f fields -- Ignore the first fields fields on each input '
      'line when doing comparisons.',
      ['-f', '1', '@F@'], files={'F': ['x a', 'y a', 'z b']}),
    C('uniq', '-s skip-chars',
      '-s chars -- Ignore the first chars characters when doing '
      'comparisons.',
      ['-s', '1', '@F@'], files={'F': ['xa', 'ya', 'zb']}),
]


# ======================================================================
# tr
# ======================================================================
TR_CASES = [
    C('tr', 'basic translate (two equal-length strings)',
      'byte i of string1 maps to byte i of string2',
      [Q('abc'), Q('xyz')], stdin='IN', files={'IN': ['cabbage']}),
    C('tr', '-d deletes a set',
      'Delete all occurrences of input characters that are specified '
      'by string1.',
      ['-d', Q('aeiou')], stdin='IN', files={'IN': ['the quick brown']}),
    C('tr', '-s squeezes repeats',
      'Replace instances of repeated characters with a single '
      'character.',
      ['-s', Q(' ')], stdin='IN', files={'IN': ['a    b  c']}),
    C('tr', '-c complements the set',
      'Complement the set of values specified by string1.',
      ['-c', Q('a-z'), Q('_')], stdin='IN', files={'IN': ['ab12cd']}),
    C('tr', 'ascending range expansion',
      'This construct shall represent the range of collating '
      'elements between the range endpoints, inclusive',
      [Q('a-e'), Q('A-E')], stdin='IN', files={'IN': ['abcde fg']}),
    C('tr', 'string2 extended by its last byte',
      'if string2 is shorter it is extended by repeating its last '
      'byte',
      [Q('abcd'), Q('X')], stdin='IN', files={'IN': ['abcde']}),
    # SHIPPED 2026-09-21 as a PRE-PASS (ESCPASS) rather than a case
    # inside EXPAND: EXPAND's range logic looks one and two bytes ahead
    # to spot `c1-c2`, and an escape makes "the next character" a
    # variable number of bytes away. Decoding first leaves EXPAND
    # reading plain bytes and needing no change. `\\n` and `\\r` both
    # give $8D, because the byte a maux text file carries at end of
    # line IS a carriage return. Known corner, stated in the source:
    # `\\-` decodes to a plain '-', so `a\\-z` expands as a range.
    # NO `\\n` ROW, and the reason is the HARNESS, not the tool.
    # ESCPASS decodes the named escapes (\\n \\r \\t \\a \\b \\f \\v \\\\)
    # from the same table as the octal form below, but a case cannot
    # DELIVER a literal backslash-n here: every keystroke reaches the
    # guest through the emulator's `type` tool, and that tool reads
    # "\\n" as a newline and submits the line. Measured 2026-09-21 --
    # typing `echo A\\B` puts a backslash on the glass, and typing
    # "\\n" straight after EXECUTES the line. The octal row exercises
    # the same decode loop and the same output path, so the coverage
    # is real; it is the spelling that cannot be typed.
    C('tr', 'an octal escape names a byte',
      'An octal sequence shall consist of a backslash followed by '
      'the longest sequence of one, two, or three-octal-digit '
      'characters.',
      [Q('\\141'), Q('X')], stdin='IN', files={'IN': ['ab', 'cd']}),
    # SHIPPED 2026-09-21 in the same pre-pass as the escapes: a class
    # IS a set of characters, so emitting its members leaves EXPAND
    # reading the plain bytes it already understands. The ranges are
    # THIS MACHINE'S -- [:digit:] is $B0-$B9, not $30-$39, because
    # every byte in this pipeline is high-bit ASCII -- and [:space:]
    # carries $8D once where a host lists newline and carriage return
    # separately, they being the same byte here.
    C('tr', '[:digit:] expands to the digit characters',
      'Represents all characters belonging to the defined character '
      'class',
      [Q('[:digit:]'), Q('#')], stdin='IN', files={'IN': ['a1b2c3']}),
    C('tr', '[:lower:] to [:upper:] converts case',
      'Represents all characters belonging to the defined character '
      'class',
      [Q('[:lower:]'), Q('[:upper:]')], stdin='IN',
      files={'IN': ['a1b2c3']}),
    # SHIPPED 2026-09-21 as a SPELLING of -c, which is conformance
    # rather than a shortcut: POSIX separates -c (complement the set
    # of VALUES) from -C (complement the set of CHARACTERS), and the
    # two differ only where a character can span more than one byte.
    # This machine is single-byte throughout, so the complements are
    # the same set -- and the host's own tr agrees, which is what
    # this differential row measures.
    C('tr', '-C complements, the same as -c on a single-byte locale',
      '-C Complement the set of characters specified by string1 (see '
      'the RATIONALE)',
      ['-C', Q('a-z'), Q('_')], stdin='IN', files={'IN': ['ab12cd']}),
]


# ======================================================================
# sort
# ======================================================================
SORT_LINES = ['banana', 'apple', 'cherry']
SORT_NUMS = ['30', '5', '100', '5']
SORT_FIELDS = ['b 2', 'a 30', 'c 1']

SORT_CASES = [
    C('sort', 'default ASCII order', 'sort lines of text',
      ['@F@'], files={'F': SORT_LINES}),
    C('sort', '-r reverses the comparison',
      'Reverse the sense of comparisons.',
      ['-r', '@F@'], files={'F': SORT_LINES}),
    C('sort', '-n numeric comparison',
      'Restrict the sort key to an initial numeric string... sorted '
      'by arithmetic value.',
      ['-n', '@F@'], files={'F': SORT_NUMS}),
    C('sort', '-u drops equal-key duplicates',
      'Suppress all but one in each set of lines having equal keys.',
      ['-u', '-n', '@F@'], files={'F': SORT_NUMS}),
    C('sort', '-k N sorts on a field',
      'The keydef argument is a restricted sort key field '
      'definition.',
      ['-k', '2', '@F@'], files={'F': SORT_FIELDS}),
    C('sort', '-k N,M bounds the key to a field range',
      'field_start[type][,field_end[type]]',
      ['-k', '2,2', '-n', '@F@'],
      files={'F': ['x 9 z', 'y 1 a', 'z 5 m']}),
    C('sort', 'no operands reads stdin',
      'If no file operands are specified... the standard input shall '
      'be used.',
      [], files={'IN': SORT_LINES}, stdin='IN'),
    C('sort', 'multiple file operands are concatenated then sorted',
      'file -- A pathname of a file to be sorted, merged, or '
      'checked.',
      ['@F1@', '@F2@'], files={'F1': ['banana'], 'F2': ['apple']}),
    C('sort', '-t: -k2 splits fields on the separator',
      '-t char -- Use char as the field separator character.',
      ['-t', ':', '-k', '2', '@F@'], files={'F': ['bb:2', 'aa:30']}),
    C('sort', '-o writes the result to a named output file',
      '-o output -- Specify the name of an output file.',
      ['-o', '@OUT2@', '@F@'], files={'F': SORT_LINES, 'OUT2': None}),
    C('sort', '-o onto an input reads it all before truncating',
      '-o output ... This file can be the same as one of the '
      'input files.',
      ['-o', '@F@', '@F@'], files={'F': SORT_LINES}, results=['F']),
    C('sort', '-f folds case for comparison, not output',
      '-f -- Consider all lowercase characters... to be the '
      'uppercase equivalent for comparison purposes.',
      ['-f', '@F@'], files={'F': ['banana', 'Apple', 'cherry']}),
    C('sort', '-b ignores leading blanks in a key',
      '-b -- Ignore leading <blank> characters when determining a '
      'sort key.',
      ['-b', '@F@'], files={'F': ['  b', ' a', 'c']}),
    C('sort', '-c on already-sorted input: silent, exit 0',
      '-c -- Check that the single input file is ordered as '
      'specified.',
      ['-c', '@F@'], files={'F': ['a', 'b', 'c']}),
    C('sort', '-c on unsorted input: no output, exit 1',
      'If the input file is not ordered as specified, the sort '
      'utility shall write a diagnostic message... exit 1.',
      ['-c', '@F@'], files={'F': ['b', 'a', 'c']}),
    C('sort', '-m merge (a plain sort of sorted input)',
      '-m -- Merge only; the input file(s) shall be assumed to be '
      'already sorted.',
      ['-m', '@F1@', '@F2@'],
      files={'F1': ['a', 'c'], 'F2': ['b', 'd']}),
    # RETIRED GAP (known_gap=None, 2026-10-08): the finding it held --
    # PARSEKEY read KEYNUM/KEYEND as plain decimal and any type
    # letter was a usage error, exit 2, where BSD/GNU `sort -k2,2n`
    # apply -n to that key alone and exit 0 -- is closed by the
    # per-key table (KT_NUM/KT_END/KT_FLG, docs/POSIX-SORTK.md).
    C('sort', '-k with a per-key n/r/b/f modifier is unimplemented',
      'field_start[type] ... type is one or more of the characters '
      "'b', 'd', 'f', 'i', 'n', or 'r'.",
      ['-k', '2,2n', '@F@'], files={'F': ['x 9', 'y 1']},
      known_gap=None),
    # ---- sort -k per-key modifiers (docs/POSIX-SORTK.md). Every row
    # below is host-oracled and BSD (Mac) == GNU (box), measured
    # 2026-10-08 -- see docs/POSIX-SORTK-NOTES.md. The model they pin:
    # a key with ANY modifier (b counts, even on field_end) takes no
    # global flag; a key with none inherits -n -r -b -f; the
    # last-resort whole-line compare is reversed by GLOBAL -r only.
    C('sort', 'sortk -k2,2nr: numeric AND reversed on that key',
      'type is one or more of b d f i n r.',
      ['-k', '2,2nr', '@F@'],
      files={'F': ['x 9 z', 'y 10 a', 'z 5 m', 'w 5 b']}),
    C('sort', 'sortk -k2n: modifier on field_start alone',
      'field_start[type][,field_end[type]]',
      ['-k', '2n', '@F@'],
      files={'F': ['x 9 z', 'y 10 a', 'z 5 m', 'w 5 b']}),
    C('sort', 'sortk -k2r,2n: types on start and end merge into one set',
      'measured BSD == GNU: -k2r,2n sorts like -k2,2nr',
      ['-k', '2r,2n', '@F@'],
      files={'F': ['x 9 z', 'y 10 a', 'z 5 m', 'w 5 b']}),
    C('sort', 'sortk -k2n,2: type on field_start alone covers the key',
      'measured BSD == GNU: -k2n,2 sorts like -k2,2n',
      ['-k', '2n,2', '@F@'],
      files={'F': ['x 9 z', 'y 10 a', 'z 5 m', 'w 5 b']}),
    C('sort', 'sortk -t: -k2,2n: per-key n with an explicit separator',
      '-t char with a numeric key',
      ['-t', ':', '-k', '2,2n', '@F@'],
      files={'F': ['b:10:x', 'a:9:y', 'c:9:a']}),
    C('sort', 'sortk -k2,2n -k1r: a second key breaks the tie',
      'Multiple -k options... keys are compared in order.',
      ['-k', '2,2n', '-k', '1r', '@F@'],
      files={'F': ['x 9 z', 'y 10 a', 'z 5 m', 'w 5 b']}),
    C('sort', 'sortk -k2,2n -r: global -r reaches only the last resort',
      'a key with its own modifiers is not subject to the global '
      'ordering options',
      ['-k', '2,2n', '-r', '@F@'],
      files={'F': ['x 9 z', 'y 10 a', 'z 5 m', 'w 5 b']}),
    C('sort', 'sortk -n -k2,2r: global -n is NOT inherited by a modified key',
      'If no modifiers are given on any key, the global options apply',
      ['-n', '-k', '2,2r', '@F@'],
      files={'F': ['x 9 z', 'y 10 a', 'z 5 m', 'w 5 b']}),
    C('sort', 'sortk -n -k2,2: an unmodified key inherits -n',
      'a key with no modifiers takes the global options',
      ['-n', '-k', '2,2', '@F@'],
      files={'F': ['x 9 z', 'y 10 a', 'z 5 m', 'w 5 b']}),
    C('sort', 'sortk -r -k2n -k1: only the unmodified key inherits -r',
      'global -r applies to keys that carry no modifier',
      ['-r', '-k', '2n', '-k', '1', '@F@'],
      files={'F': ['a 5', 'b 5', 'c 5', 'd 1']}),
    C('sort', 'sortk -k1,1f -k2n: per-key fold then numeric',
      'f on one key only',
      ['-k', '1,1f', '-k', '2n', '@F@'],
      files={'F': ['B 2', 'a 10', 'b 1', 'A 9', 'a 2']}),
    C('sort', 'sortk -f -k1,1r: global -f is NOT inherited by a modified key',
      'a key with its own modifiers ignores the global ones',
      ['-f', '-k', '1,1r', '@F@'],
      files={'F': ['B 2', 'a 1', 'b 1', 'A 2']}),
    C('sort', 'sortk -f -r -k1,1 -k2,2n: inherited f and r, then own n',
      'unmodified key inherits -f -r; modified key does not',
      ['-f', '-r', '-k', '1,1', '-k', '2,2n', '@F@'],
      files={'F': ['B 2', 'a 1', 'b 1', 'A 2']}),
    C('sort', 'sortk -k2b,2: b on field_start skips the start blanks',
      'b: leading blanks of the field_start field are ignored',
      ['-k', '2b,2', '@F@'], files={'F': ['a  c', 'a b', 'a   a']}),
    C('sort', 'sortk -k2,2b: b on field_end changes nothing',
      'BSD and GNU agree: b on the end field is a no-op without a '
      'character offset',
      ['-k', '2,2b', '@F@'], files={'F': ['a  c', 'a b', 'a   a']}),
    C('sort', 'sortk -k2b,2b: b on both',
      'b on start and end',
      ['-k', '2b,2b', '@F@'], files={'F': ['a  c', 'a b', 'a   a']}),
    C('sort', 'sortk -b -k2,2: an unmodified key inherits -b',
      'global -b applies to a key with no modifier',
      ['-b', '-k', '2,2', '@F@'], files={'F': ['k    b', 'k  a']}),
    C('sort', 'sortk -b -k2,2r: a modified key does NOT inherit -b',
      'global -b is dropped once the key has its own modifier',
      ['-b', '-k', '2,2r', '@F@'], files={'F': ['k    b', 'k  a']}),
    C('sort', 'sortk -b -k2,2f: modified key does not inherit -b (fold)',
      'global -b is dropped once the key has its own modifier',
      ['-b', '-k', '2,2f', '@F@'], files={'F': ['k    b', 'k  a']}),
    C('sort', 'sortk -t: -k2b,2b: b with an explicit separator',
      '-t char with b: blanks after the separator are skipped',
      ['-t', ':', '-k', '2b,2b', '@F@'],
      files={'F': ['a:  c', 'a: b', 'a:   a']}),
    C('sort', 'sortk -k3,3r: field past the end is an empty key',
      'a line with too few fields has an empty key',
      ['-k', '3,3r', '@F@'], files={'F': ['a', 'b c', 'd e f']}),
    C('sort', 'sortk -k2,2n -k1,1r: empty numeric key sorts as 0',
      'no digits parses as zero',
      ['-k', '2,2n', '-k', '1,1r', '@F@'],
      files={'F': ['a', 'b c', 'd e f', 'g 0']}),
    C('sort', 'sortk -k1,1nbfr: all four modifiers on one key',
      'type is any combination of the letters',
      ['-k', '1,1nbfr', '@F@'], files={'F': ['10', '9', ' 100', '2']}),
    C('sort', 'sortk -k1,1rn: modifier letter order does not matter',
      'type is any combination of the letters',
      ['-k', '1,1rn', '@F@'], files={'F': ['10', '9', '100', '2']}),
    C('sort', 'sortk -u -k2,2n -k1,1f: -u drops on equal KEYS',
      '-u: suppress all but one in each set of lines having equal keys',
      ['-u', '-k', '2,2n', '-k', '1,1f', '@F@'],
      files={'F': ['B 2', 'a 1', 'b 1', 'A 2', 'c 3']}),
    C('sort', 'sortk -c -k2,2n: sorted under the per-key order is silent',
      '-c checks the order the keys request',
      ['-c', '-k', '2,2n', '@F@'], files={'F': ['b 2', 'a 10']}),
    C('sort', 'sortk -c -k2,2n: unsorted under the per-key order is exit 1',
      '-c checks the order the keys request',
      ['-c', '-k', '2,2n', '@F@'], files={'F': ['a 10', 'b 2']}),
    C('sort', 'sortk -c -k2,2nr: descending order is accepted',
      '-c checks the order the keys request',
      ['-c', '-k', '2,2nr', '@F@'], files={'F': ['a 10', 'b 2']}),
    C('sort', 'sortk -k2,2 -k3,3n: key ending exactly at line end',
      'fixture boundary: keys that end at the NUL',
      ['-k', '2,2', '-k', '3,3n', '@F@'],
      files={'F': ['x a 9', 'y a 10', 'z a', 'w a 9']}),
    C('sort', 'sortk 300-char key: bytes past 255 decide, per key',
      'learning:01M0MMCZDJCPAAHS1TJTQTV64Y -- no 8-bit key length',
      ['-k', '2,2r', '@F@'],
      files={'F': ['a ' + 'z' * 300 + 'b', 'a ' + 'z' * 300 + 'a',
                   'a ' + 'z' * 299]}),
    C('sort', 'sortk -k2,2q: unknown type letter is a usage error',
      'unknown key type letters are rejected',
      ['-k', '2,2q', '@F@'], files={'F': ['x 1']}),
    C('sort', 'sortk -k2,: empty field_end is a usage error',
      'field_end must be a field number',
      ['-k', '2,', '@F@'], files={'F': ['x 1']}),
    C('sort', 'sortk eight -k keys are accepted',
      'maux caps -k at 8 keys; host has no cap',
      ['-k', '1,1', '-k', '2,2', '-k', '3,3', '-k', '4,4', '-k', '5,5',
       '-k', '6,6', '-k', '7,7', '-k', '8,8n', '@F@'],
      files={'F': ['a a a a a a a 10', 'a a a a a a a 9']}),
    C('sort', 'sortk ninth -k is refused (maux cap 8)',
      'hand: POSIX sets no cap; maux holds 8 keys in a table and '
      'refuses the 9th loudly (exit 2, nothing on stdout) rather '
      'than silently ignoring it',
      ['-k', '1', '-k', '1', '-k', '1', '-k', '1', '-k', '1', '-k', '1',
       '-k', '1', '-k', '1', '-k', '1', '@F@'], files={'F': ['x']},
      hand=dict(stdout=[], rc=2,
                reason='the key table holds 8 entries (src/bin/sort.s '
                       'KTAB); the host has no cap, so this row is '
                       'authored from maux\'s stated contract, not '
                       'measured against the host')),
    C('sort', 'sortk -k2,2d dictionary order is not implemented',
      'd: only blanks and alphanumerics are significant',
      ['-k', '2,2d', '@F@'], files={'F': ['x z,y', 'x A!b', 'x a b']},
      known_gap="sort.s accepts the key types b f n r; d and i are "
                "refused as a usage error (exit 2). Host exit 0."),
    C('sort', 'sortk -k2,2i ignore-nonprinting is not implemented',
      'i: ignore nonprinting characters',
      ['-k', '2,2i', '@F@'], files={'F': ['x z,y', 'x A!b', 'x a b']},
      known_gap="sort.s accepts the key types b f n r; d and i are "
                "refused as a usage error (exit 2). Host exit 0."),
    C('sort', 'sortk -k1.2 character offsets are not implemented',
      'field_start is field_number[.first_character]',
      ['-k', '1.2', '@F@'], files={'F': ['xb', 'ya', 'za']},
      known_gap="PARSEKEY reads field numbers only; '.' after the "
                "number is junk and the usage-error exit 2 is "
                "taken. Not part of the per-key-modifier brief; "
                "recorded so the divergence is gated."),
]


# ======================================================================
# od -- every row hand-authored; see module header.
# ======================================================================
def _od_hex(v):
    return f'{v:02X}'


def _od_oct(v):
    return f'{v:03o}'


def _od_chr(v):
    lo = v & 0x7F
    if 0x20 <= lo <= 0x7E:
        return chr(lo)
    return '.'


def _od_off(off, base):
    """The offset column, in the base -A named. Widths are FIXED per
    base -- 4 hex, 5 decimal, 6 octal, each the widest a 16-bit offset
    can need -- which is what keeps it a column."""
    if base == 'n':
        return ''
    if base == 'd':
        return f'{off:05d}'
    if base == 'o':
        return f'{off:06o}'
    return f'{off:04X}'


def od_expected(raw, want, base='x'):
    """raw = bytes (RAW on-disk values, high bit set for text); want =
    a string subset of 'xbc' in any order -- printed in the FIXED
    hex/octal/char order regardless (od.s's own rule); base = -A's
    letter. Mirrors PRROWHEX/PRROWOCT/PRROWCHR/PRHEX4 (src/bin/od.s)
    exactly."""
    lines = []
    off = 0
    i = 0
    n = len(raw)
    while True:
        chunk = raw[i:i + 16]
        if not chunk:
            lines.append(_od_off(off, base))
            break
        if 'x' in want:
            lines.append(_od_off(off, base) +
                          ''.join(' ' + _od_hex(b) for b in chunk))
        if 'b' in want:
            lines.append(_od_off(off, base) +
                          ''.join(' ' + _od_oct(b) for b in chunk))
        if 'c' in want:
            lines.append(_od_off(off, base) +
                          ''.join(' ' + _od_chr(b) for b in chunk))
        off += len(chunk)
        i += len(chunk)
        if len(chunk) < 16:
            lines.append(_od_off(off, base))
            break
    return lines


OD_REASON = ("od.s's default is HEX BYTES by ruling (docs/ANACHRONISMS"
             ".md A3, the file's own header: a 6502 byte machine, not "
             "a PDP-11 with octal front-panel words) -- a structural "
             "default divergence from BSD/GNU od (octal 16-bit words, "
             "octal offset), not a value to translate flags around. "
             "Hand-computed from the fixture's own on-disk bytes via "
             "od_expected(), which mirrors od.s's row printers "
             "exactly; not a host capture.")


# ----------------------------------------------------------------------
# od -t: the type sub-language (docs/POSIX-ODT.md, 2026-10-08).
#
# THE MODEL BELOW IS CHECKED AGAINST THE HOST ON EVERY RUN. A fixture's
# bytes cannot be run through a host `od` by the harness (these rows are
# hand=, because maux's offset column and default format differ from
# any host's), so od_t_hand() does it itself: it writes the SAME raw
# bytes to a temp file, runs the rig's own /usr/bin/od, and refuses to
# hand the harness an expectation the host does not back.
#   * GNU (the box):  full-text equality, columns and all, against the
#     model in host shape (7-digit octal offsets, no trailing blank).
#   * BSD (the Mac):  the TOKEN stream, whitespace-insensitive. BSD pads
#     every row with trailing blanks, uses wider columns, and GLUES
#     two d1 fields when one is -100 or lower ("119-106"), so BSD can
#     only vouch for the values; GNU vouches for the layout. The
#     agreeing set was MEASURED (docs/POSIX-ODT-NOTES.md sec 1).
# Where the hosts disagree among themselves (`a` on a byte >= $80: GNU
# masks to 7 bits as XCU says, BSD prints the raw byte) the row is
# pinned from the XCU text and BSD is fed pre-masked bytes.
# ----------------------------------------------------------------------
_OD_NAMES = ('nul soh stx etx eot enq ack bel bs ht nl vt ff cr so si '
             'dle dc1 dc2 dc3 dc4 nak syn etb can em sub esc fs gs rs us '
             'sp').split()
_OD_ESC = {0: '\\0', 7: '\\a', 8: '\\b', 9: '\\t', 10: '\\n',
           11: '\\v', 12: '\\f', 13: '\\r'}
_OD_DIG = {'x': {1: 2, 2: 4, 4: 8}, 'o': {1: 3, 2: 6, 4: 11},
           'u': {1: 3, 2: 5, 4: 10}, 'd': {1: 4, 2: 6, 4: 11}}


def _od_digits(kind, size):
    if kind in _OD_DIG:
        return _OD_DIG[kind][size]
    return {'a': 3, 'c': 3, 'k': 1}[kind]


def _od_field(kind, size, unit, cstrip):
    v = int.from_bytes(unit, 'little')
    if kind == 'x':
        return f'{v:0{2 * size}X}'
    if kind == 'o':
        return f'{v:0{_od_digits("o", size)}o}'
    if kind == 'u':
        return str(v)
    if kind == 'd':
        return str(v - (1 << (8 * size)) if v >= 1 << (8 * size - 1)
                   else v)
    b = unit[0]
    lo = b & 0x7F
    if kind == 'a':             # XCU: only the low seven bits count
        return (_OD_NAMES[lo] if lo <= 32 else
                'del' if lo == 127 else chr(lo))
    if kind == 'c':
        if not cstrip and b >= 0x80:
            return f'{b:03o}'
        if lo in _OD_ESC:
            return _OD_ESC[lo]
        return chr(lo) if 0x20 <= lo <= 0x7E else f'{b:03o}'
    return chr(lo) if 0x20 <= lo <= 0x7E else '.'      # 'k': legacy -c


def _od_widths(specs, align):
    """Per spec, the width of each field of one block (the largest
    unit's worth of bytes). With several types GNU stretches every
    type to the widest one's block and spreads the slack with
    ceil(Wb*j/k) boundaries -- measured, 164 random combinations."""
    big = max(s for _, s in specs)
    wb = max((big // s) * (1 + _od_digits(k, s)) for k, s in specs)
    out = []
    for k, s in specs:
        n = big // s
        w = wb if align else n * (1 + _od_digits(k, s))
        b = [(w * j + n - 1) // n for j in range(n + 1)]
        out.append([b[j + 1] - b[j] for j in range(n)])
    return out


def od_t_expected(raw, specs, base='x', align=True, verbose=False,
                  host=False, cstrip=True, start=0):
    """specs = [(kind, size)], kind in a c d o u x (k = legacy -c).
    host=True gives GNU's shape for the cross-check."""
    widths = _od_widths(specs, align)
    offf = (lambda n: f'{n:07o}') if host else (lambda n: _od_off(n, base))
    blank = ' ' * len(offf(0))
    lines, prev, supp, at = [], None, False, start
    for i in range(0, len(raw), 16):
        row = raw[i:i + 16]
        if len(row) == 16 and not verbose and prev == row:
            if not supp:
                lines.append('*')
                supp = True
        else:
            supp = False
            for si, (k, s) in enumerate(specs):
                pad = row + bytes(-len(row) % s)
                txt = offf(at) if (si == 0 or not align) else blank
                for u in range(len(pad) // s):
                    f = _od_field(k, s, pad[u * s:(u + 1) * s], cstrip)
                    txt += f.rjust(widths[si][u % len(widths[si])])
                lines.append(txt)
        prev = row if len(row) == 16 else None
        at += len(row)
    lines.append(offf(at))
    return lines


def _od_run_host(raw, args):
    import os
    import subprocess as sp
    import tempfile
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(raw)
    try:
        r = sp.run(['/usr/bin/od'] + args + [f.name],
                   capture_output=True, env=dict(os.environ, LC_ALL='C'))
        return r.returncode, r.stdout.decode('latin1').split('\n')
    finally:
        os.unlink(f.name)


_OD_CHECKED = {}


def _od_host_agrees(raw, specs, verbose, start=0, hostargs=(),
                    modelraw=None):
    """Raise unless this rig's host od backs the model. Memoised.
    raw is what the HOST is given; modelraw (default raw) is the
    bytes the model dumps, which differs only under -j/-N."""
    key = (raw, tuple(specs), verbose, start, tuple(hostargs))
    mraw = raw if modelraw is None else modelraw
    if key in _OD_CHECKED:
        return
    targs = sum((['-t', f'{k}{s}' if k in 'dou' or k == 'x' else k]
                 for k, s in specs), [])
    targs = list(hostargs) + (['-v'] if verbose else []) + targs
    gnu = _od_run_host(b'', ['--version'])[0] == 0
    kinds = {k for k, _ in specs}
    if gnu:
        rc, got = _od_run_host(raw, targs)
        got = [ln.lower() for ln in got]
        while got and got[-1] == '':
            got.pop()
        exp = [ln.lower() for ln in od_t_expected(
            mraw, specs, verbose=verbose, host=True, cstrip=False,
            start=start)]
        if rc != 0 or got != exp:
            raise RuntimeError(f'model != GNU od for {specs}:\n'
                               + '\n'.join(exp) + '\n--\n' + '\n'.join(got))
    else:
        feed = raw
        if kinds == {'a'}:
            feed = bytes(b & 0x7F for b in raw)
        if 'a' not in kinds or kinds == {'a'}:
            rc, got = _od_run_host(feed, ['-An'] + targs)
            exp = od_t_expected(mraw, specs, base='n', verbose=verbose,
                                cstrip=False, start=start)
            g = ''.join(' '.join(got).split()).lower()
            e = ''.join(' '.join(exp).split()).lower()
            if rc != 0 or g != e:
                raise RuntimeError(f'model != BSD od tokens for {specs}')
    if kinds == {'c'}:
        # the high-bit ruling (od.s header): a byte whose low seven bits
        # are printable, or a named escape, prints as THAT character --
        # so the host must be fed the stripped byte to agree.
        feed = bytes(b & 0x7F if ((b & 0x7F) in _OD_ESC
                                  or 0x20 <= b & 0x7F <= 0x7E) else b
                     for b in raw)
        rc, got = _od_run_host(feed, ['-An'] + targs)
        exp = od_t_expected(mraw, specs, base='n', verbose=verbose,
                            start=start)
        g = ''.join(' '.join(got).split())
        e = ''.join(' '.join(exp).split())
        if rc != 0 or g != e:
            raise RuntimeError(f'strip-ruling model != host for {specs}')
    _OD_CHECKED[key] = True


OD_T_REASON = ("hand-computed by od_t_expected() from the fixture's raw "
               "bytes and CHECKED against this rig's own host od on "
               "every run (od_t_hand: GNU full text on the box, BSD "
               "token stream on the Mac). maux keeps its own offset "
               "column (4 hex / 5 dec / 6 oct) and UPPER-case hex "
               "(the PRHEX8 convention of -x and the offsets), so the "
               "text cannot be byte-compared with a host capture. "
               + "Field layout is GNU's (measured): a type's fields "
               "are 1 + max-digits wide, widened and slack-spread to "
               "the widest type's block when several -t are given; "
               "later types' lines carry a BLANK offset.")


def od_t_hand(raw, specs, base='x', verbose=False, extra='',
              align=True, start=0, hostraw=None, hostargs=()):
    """raw = the bytes od is expected to DUMP (after -j/-N); hostraw +
    hostargs = what the host is given to produce the same dump."""
    def h(_base=None):
        _od_host_agrees(hostraw if hostraw is not None else raw, specs,
                        verbose, start, hostargs, modelraw=raw)
        return dict(stdout=od_t_expected(raw, specs, base=base,
                                         verbose=verbose, align=align,
                                         start=start),
                    rc=0, reason=extra + OD_T_REASON)
    return h


OD_FMIX = bytes([0x00, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1F,
                 0x20, 0x41, 0x7E, 0x7F, 0x80, 0xC1, 0xFF,
                 0x01, 0x02, 0x03, 0x04, 0x05])
OD_FNEG = bytes([0xFF, 0xFF, 0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00,
                 0x7F, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x80])
OD_FNEG1 = OD_FNEG + bytes([0x01])
OD_FDUP = bytes([0x41]) * 48 + bytes([1, 2, 3])


def _odrow(name, argv, raw, specs, base='x', verbose=False, align=True,
           slice_=None):
    data, start, hostargs, hostraw = raw, 0, (), None
    if slice_:
        data = raw[slice_[0]:slice_[1]]
        start = slice_[0]
        hostargs = ('-j', str(slice_[0]), '-N', str(slice_[1] - slice_[0]))
        hostraw = raw
    return C('od', name,
             '-t type_string -- Specify one or more output types.',
             list(argv) + ['@F@'], files={'F': raw},
             hand=od_t_hand(data, specs, base=base, verbose=verbose,
                            align=align, start=start, hostraw=hostraw,
                            hostargs=hostargs))


OD_FIX = ['AB']  # -> on-disk: C1 C2 8D (3 bytes, one short row)

OD_CASES = [
    C('od', 'default is hex bytes (od.s ruling, not V6 octal words)',
      '-x Interpret words (two-byte units) in hexadecimal.',
      ['@F@'], files={'F': OD_FIX},
      hand=dict(stdout=od_expected(_hi_bytes(OD_FIX), 'x'), rc=0,
                reason=OD_REASON)),
    C('od', '-b octal bytes, 3 digits',
      '-b Interpret bytes in octal.',
      ['-b', '@F@'], files={'F': OD_FIX},
      hand=dict(stdout=od_expected(_hi_bytes(OD_FIX), 'b'), rc=0,
                reason=OD_REASON)),
    C('od', '-c printable chars, non-printable as .',
      '-c Interpret bytes as characters.',
      ['-c', '@F@'], files={'F': ['A\x01B']},
      hand=dict(stdout=od_expected(_hi_bytes(['A\x01B']), 'c'), rc=0,
                reason=OD_REASON)),
    C('od', '-x explicit names the default, changes nothing',
      '-x ...ALSO the default (no flags).',
      ['-x', '@F@'], files={'F': OD_FIX},
      hand=dict(stdout=od_expected(_hi_bytes(OD_FIX), 'x'), rc=0,
                reason=OD_REASON)),
    C('od', 'combined -b -c -x print in FIXED hex/octal/char order',
      'EACH format gets its own full row... in the FIXED order hex, '
      'octal, char regardless of the order the flags appeared',
      ['-c', '-b', '-x', '@F@'], files={'F': OD_FIX},
      hand=dict(stdout=od_expected(_hi_bytes(OD_FIX), 'xbc'), rc=0,
                reason=OD_REASON)),
    C('od', 'stdin with no FILE operand',
      'If no file operands are specified, the standard input shall '
      'be used.',
      [], files={'IN': OD_FIX}, stdin='IN',
      hand=dict(stdout=od_expected(_hi_bytes(OD_FIX), 'x'), rc=0,
                reason=OD_REASON)),
    # SHIPPED 2026-09-21. The offset column dispatches on -A's letter:
    # 4 hex digits, 5 decimal, 6 octal, or nothing at all for 'n'.
    # Widths are FIXED per base because that is what keeps it a
    # column; a host `od` pads its decimal offsets the same way.
    C('od', '-A d prints the offset in decimal',
      '-A d  Output offsets in decimal.',
      ['-A', 'd', '@F@'], files={'F': OD_FIX},
      hand=dict(stdout=od_expected(_hi_bytes(OD_FIX), 'x', 'd'), rc=0,
                reason=OD_REASON)),
    C('od', '-A o prints the offset in octal',
      '-A o  Output offsets in octal.',
      ['-A', 'o', '@F@'], files={'F': OD_FIX},
      hand=dict(stdout=od_expected(_hi_bytes(OD_FIX), 'x', 'o'), rc=0,
                reason=OD_REASON)),
    C('od', '-A n prints no offset at all',
      '-A n  Do not print the offset.',
      ['-A', 'n', '@F@'], files={'F': OD_FIX},
      hand=dict(stdout=od_expected(_hi_bytes(OD_FIX), 'x', 'n'), rc=0,
                reason=OD_REASON)),
    C('od', '-j skip',
      '-j skip -- Jump over skip bytes from the beginning of the '
      'input.',
      ['-j', '1', '@F@'], files={'F': OD_FIX},
      hand=dict(stdout=['0001 C2 8D', '0003'], rc=0,
                reason="SHIPPED 2026-09-17: -j discards the first "
                       "byte (C1, 'A') and seeds OFFSET at 1, so the "
                       "printed column reads as a real file "
                       "position -- BSD od does the same. "
                       + OD_REASON)),
    C('od', '-N limit',
      '-N count -- Format no more than count bytes of input.',
      ['-N', '1', '@F@'], files={'F': OD_FIX},
      hand=dict(stdout=['0000 C1', '0001'], rc=0,
                reason="SHIPPED 2026-09-17: -N caps the dump at 1 "
                       "byte (C1, 'A') even though 2 more remain on "
                       "disk. " + OD_REASON)),
    C('od', '-t x1 is the default hex byte row (was KNOWN_GAP: no -t)',
      '-t type_string -- Specify one or more output types.',
      ['-t', 'x1', '@F@'], files={'F': OD_FIX},
      hand=od_t_hand(_hi_bytes(OD_FIX), [('x', 1)],
                     extra="RETIRED 2026-10-08. Was known_gap: ODOPTS "
                           "had no 't' -- usage error, exit 2 (the "
                           "three formats were each their own bare "
                           "letter flag); BSD od -t x1 dumps single-"
                           "byte hex and exits 0. Now one type engine. ")),
    # ------------------------------------------------------------------
    # -t (2026-10-08, docs/POSIX-ODT.md). Every row below was RED on the
    # base (ODOPTS had no 't': usage error, exit 2) before the type
    # engine landed -- docs/POSIX-ODT-NOTES.md sec 3 has the output.
    # Fixture bytes are RAW (check_posixutil stages a bytes value
    # verbatim), so $00-$7F, $0A and $0D are all reachable.
    # ------------------------------------------------------------------
    _odrow('-t x2: little-endian 16-bit units, odd length zero-padded',
           ['-t', 'x2'], OD_FMIX, [('x', 2)]),
    _odrow('-t x4: 32-bit units, the last partial unit zero-padded',
           ['-t', 'x4'], OD_FMIX, [('x', 4)]),
    _odrow('-t o1 / -b agree: three octal digits a byte',
           ['-t', 'o1'], OD_FMIX, [('o', 1)]),
    _odrow('-t o2: six octal digits a 16-bit unit',
           ['-t', 'o2'], OD_FNEG1, [('o', 2)]),
    _odrow('-t o4: eleven octal digits, top digit 0-3',
           ['-t', 'o4'], OD_FNEG1, [('o', 4)]),
    _odrow('-t u1',
           ['-t', 'u1'], OD_FNEG1, [('u', 1)]),
    _odrow('-t u2',
           ['-t', 'u2'], OD_FNEG1, [('u', 2)]),
    _odrow('-t u4: unsigned 32-bit decimal to 4294967295',
           ['-t', 'u4'], OD_FNEG1, [('u', 4)]),
    _odrow('-t d1: signed bytes, -128 included',
           ['-t', 'd1'], OD_FNEG1, [('d', 1)]),
    _odrow('-t d2: signed 16-bit',
           ['-t', 'd2'], OD_FNEG1, [('d', 2)]),
    _odrow('-t d4: signed 32-bit, -1 and -2147483648 and 2147483647',
           ['-t', 'd4'], OD_FNEG1, [('d', 4)]),
    _odrow('-t a: the XCU named characters, low seven bits only',
           ['-t', 'a'], OD_FMIX, [('a', 1)]),
    _odrow('-t c: C escapes, printable as themselves, rest octal',
           ['-t', 'c'], OD_FMIX, [('c', 1)]),
    _odrow('-t xC xS xI xL: letter sizes are 1 2 4 and 4',
           ['-t', 'xC', '-t', 'xS', '-t', 'xI', '-t', 'xL'], OD_FNEG1,
           [('x', 1), ('x', 2), ('x', 4), ('x', 4)]),
    _odrow('-t dL: L is FOUR bytes on this 16-bit machine',
           ['-t', 'dL'], OD_FNEG, [('d', 4)]),
    _odrow('-t d with no size is the host default, 4 bytes',
           ['-t', 'd'], OD_FNEG, [('d', 4)]),
    _odrow('-t x1 -t c: two options, two lines, the offset only once',
           ['-t', 'x1', '-t', 'c'], OD_FMIX, [('x', 1), ('c', 1)]),
    _odrow('-t x1c: two types in one type_string',
           ['-t', 'x1c'], OD_FMIX, [('x', 1), ('c', 1)]),
    _odrow('-t a -t c: both three-wide, so no stretching',
           ['-t', 'a', '-t', 'c'], OD_FMIX, [('a', 1), ('c', 1)]),
    _odrow('-t x1 -t x2 -t x4: every type stretched to the x1 block',
           ['-t', 'x1', '-t', 'x2', '-t', 'x4'], OD_FMIX,
           [('x', 1), ('x', 2), ('x', 4)]),
    _odrow('-t d1 -t d2 -t d4: stretched to the d1 block',
           ['-t', 'd1', '-t', 'd2', '-t', 'd4'], OD_FNEG1,
           [('d', 1), ('d', 2), ('d', 4)]),
    _odrow('-t x1 -t d2 -t x4: slack of 2 over 4 fields lands on 1 and 3',
           ['-t', 'x1', '-t', 'd2', '-t', 'x4'], OD_FNEG1,
           [('x', 1), ('d', 2), ('x', 4)]),
    _odrow('-t x1 -t o2: slack of 1 over 2 fields lands on the first',
           ['-t', 'x1', '-t', 'o2'], OD_FMIX, [('x', 1), ('o', 2)]),
    _odrow('-t o1 -t d4 across a partial last row',
           ['-t', 'o1', '-t', 'd4'], OD_FMIX, [('o', 1), ('d', 4)]),
    _odrow('-t x4 on exactly 16 bytes: no padding, no extra row',
           ['-t', 'x4'], OD_FNEG, [('x', 4)]),
    _odrow('-t x4 on 17 bytes: one byte past the row, padded unit',
           ['-t', 'x4'], OD_FNEG1, [('x', 4)]),
    _odrow('-A d with -t x2',
           ['-A', 'd', '-t', 'x2'], OD_FNEG1, [('x', 2)], base='d'),
    _odrow('-A o with -t c',
           ['-A', 'o', '-t', 'c'], OD_FMIX, [('c', 1)], base='o'),
    _odrow('-A n with two types: no offset on either line',
           ['-A', 'n', '-t', 'd1', '-t', 'x1'], OD_FNEG, [('d', 1),
           ('x', 1)], base='n'),
    _odrow('-j 3 -N 9 with -t x2: offset seeded, units from byte 3',
           ['-j', '3', '-N', '9', '-t', 'x2'], OD_FMIX, [('x', 2)],
           slice_=(3, 12)),
    _odrow('-t x1 collapses repeated rows to a single *',
           ['-t', 'x1'], OD_FDUP, [('x', 1)]),
    _odrow('-v shows every row of a repeated block',
           ['-v', '-t', 'x1'], OD_FDUP, [('x', 1)], verbose=True),
    _odrow('* with two types: one * for the whole block',
           ['-t', 'x1', '-t', 'c'], OD_FDUP, [('x', 1), ('c', 1)]),
    _odrow('the default format collapses repeated rows too',
           [], OD_FDUP, [('x', 1)], align=False),
    _odrow('-d is -t u2 (XCU)',
           ['-d'], OD_FNEG1, [('u', 2)]),
    _odrow('-o is -t o2 (XCU)',
           ['-o'], OD_FNEG1, [('o', 2)]),
    _odrow('-s is -t d2 (XCU)',
           ['-s'], OD_FNEG1, [('d', 2)]),
    _odrow('-b with -t d1: the legacy letter joins the aligned set',
           ['-b', '-t', 'd1'], OD_FNEG, [('o', 1), ('d', 1)]),
    C('od', '-t reads standard input with no FILE',
      'If no file operands are specified, the standard input shall '
      'be used.',
      ['-t', 'x2'], files={'IN': OD_FMIX}, stdin='IN',
      hand=od_t_hand(OD_FMIX, [('x', 2)])),
    C('od', '-t x8: eight-byte types are refused loudly',
      '-t type_string... the number of bytes is implementation-defined '
      'for sizes beyond the C types',
      ['-t', 'x8', '@F@'], files={'F': OD_FNEG},
      hand=dict(stdout=[], rc=2,
                reason="a 6502 has no 64-bit anything: x8/d8/o8/u8 are "
                       "a usage error (exit 2, nothing on stdout) "
                       "rather than a silently narrowed dump. GNU and "
                       "BSD both take 8; this is a stated gap.")),
    C('od', '-t x3: a size that is not 1 2 or 4 is refused',
      '-t type_string... the size is a decimal number of bytes',
      ['-t', 'x3', '@F@'], files={'F': OD_FNEG},
      hand=dict(stdout=[], rc=2,
                reason="both hosts refuse 3 too (GNU: unsupported int "
                       "size 3; BSD: unsupported int size 3).")),
    C('od', '-t z: an unknown type letter is refused',
      '-t type_string',
      ['-t', 'z', '@F@'], files={'F': OD_FNEG},
      hand=dict(stdout=[], rc=2,
                reason="GNU's z (ASCII sidebar) and BSD's f (float) "
                       "are extensions XCU does not have.")),
    C('od', '-t with trailing junk is refused',
      '-t type_string',
      ['-t', 'x1q', '@F@'], files={'F': OD_FNEG},
      hand=dict(stdout=[], rc=2,
                reason="the whole string must parse; nothing is "
                       "dumped on a bad one.")),
]


# ======================================================================
# find -- a small staged tree under TREE/ (never the case's own base,
# which also holds OUT/OUTX -- see module header on find's PATH
# argument for why).
# ======================================================================
FIND_TREE_DIRS = {'TREE': 'TREE', 'SUB': 'TREE/SUB'}
FIND_TREE_PRE = ['TREE', 'SUB']

# -- Second tree, for the -prune/precedence/-o cases below: SUB
# -- carries its OWN file (INNER.TXT) so a -prune case has
# -- something to prove was never visited.
FIND_TREE2_DIRS = {'TREE': 'TREE', 'SUB': 'TREE/SUB'}
FIND_TREE2_PRE = ['TREE', 'SUB']

FIND_CASES = [
    C('find', '-name matches the basename against a glob',
      'true if the basename of the current pathname matches pattern',
      ['@TREE@', '-name', Q('*.TXT')],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE,
      files={'TREE/A.TXT': ['x'], 'TREE/B.BIN': ['y']}),
    C('find', '-type d matches directories only',
      "true if the type of the file is c... 'd'",
      ['@TREE@', '-type', 'd'],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE),
    C('find', '-type f matches plain files only',
      "true if the type of the file is c... 'f'",
      ['@TREE@', '-type', 'f'],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE,
      files={'TREE/A.TXT': ['x']}),
    C('find', '-exec spawns per match with {} substituted',
      'The utility named by the utility... shall be invoked... {} '
      'shall be replaced by the current pathname',
      ['@TREE@', '-name', Q('A.TXT'), '-exec', 'ECHO', '{}', Q(';')],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE,
      files={'TREE/A.TXT': ['x']},
      hand=dict(stdout=['TREE/A.TXT'], rc=0,
                reason="the exec'd command word is 'ECHO', maux's "
                       "own binary name (findact.s's BUILD_EXECV/"
                       "PATHRSLV resolves it via PATH exactly as "
                       "execvp would) -- the host has no such "
                       "binary (only lowercase 'echo'), and argv is "
                       "shared verbatim between the maux and host "
                       "renders, so a host run of this exact case "
                       "would fail on a missing command rather than "
                       "test -exec's own behaviour. Hand-authored to "
                       "findact.s's own ACT_EXEC/BUILD_EXECV: {} "
                       "substitutes the SAME walked-path text a "
                       "plain -print would write, here 'TREE/"
                       "A.TXT', and -exec's child inherits find's "
                       "own stdout unredirected.")),
    C('find', '-newer: no fixture file is ever strictly newer',
      'true if the modification time of the current file is more '
      'recent than the modification time of the file named by '
      'pathname',
      ['@TREE@', '-newer', '@TREE@/A.TXT'],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE,
      files={'TREE/A.TXT': ['x'], 'TREE/B.BIN': ['y']},
      hand=dict(stdout=[], rc=0,
                reason="findexpr.s's TESTNEWER/DTGT do a real "
                       "GET_FILE_INFO compare now (no longer a "
                       "USAGE_ERR) -- but every file this harness "
                       "stages lands in the SAME a2til write() "
                       "call, which timestamps with "
                       "datetime.now().replace(second=0, "
                       "microsecond=0): ProDOS's own mod_time word "
                       "is minute-granularity, so every fixture "
                       "file in one build shares ONE mod_date/"
                       "mod_time (barring the sub-second chance a "
                       "build straddles a minute boundary). '-newer' "
                       "is strict ('more recent than'), so a tie is "
                       "FALSE for every entry, including TREE and "
                       "TREE/B.BIN against the reference TREE/A.TXT "
                       "-- proving the real comparison RUNS (exit 0, "
                       "not 2) without needing a controlled clock to "
                       "prove the TRUE branch too.")),
    C('find', '-prune stops descent but still prints the pruned dir',
      'cause find not to descend the current pathname if it is a '
      'directory',
      ['@TREE@', '-name', Q('SUB'), '-prune'],
      dirs=FIND_TREE2_DIRS, predirs=FIND_TREE2_PRE,
      files={'TREE/SUB/INNER.TXT': ['z'], 'TREE/A.TXT': ['x']},
      hand=dict(stdout=['TREE/SUB'], rc=0,
                reason="findexpr.s's FACT_PRIM/TT_PRUNE sets "
                       "PRUNEFLAG (findtop.s's WALK checks it right "
                       "after EVAL_TOP and skips the descend even "
                       "though SUB is a directory) -- INNER.TXT is "
                       "never visited, proving non-descent, not just "
                       "the print. TREE itself and A.TXT do not "
                       "match '-name SUB' so -prune never runs for "
                       "them (find is still descended into TREE "
                       "itself, since prune's own primary was never "
                       "reached there)."),
    ),
    C('find', 'default -print applies to the WHOLE -o expression',
      'if the given expression does not contain any of the '
      'primaries -exec, -ok, or -print, the given expression '
      'shall be effectively replaced by ( given expression) -print',
      ['@TREE@', '-name', Q('A.TXT'), '-o', '-name', Q('B.BIN')],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE,
      files={'TREE/A.TXT': ['x'], 'TREE/B.BIN': ['y']},
      hand=dict(stdout=['TREE/A.TXT', 'TREE/B.BIN'], rc=0,
                reason="no -exec/-print anywhere in the expression, "
                       "so EVAL_TOP (findexpr.s) prints only when "
                       "the WHOLE '-name A.TXT -o -name B.BIN' came "
                       "back true, regardless of which side of the "
                       "-o decided it -- proving the default-print "
                       "rewrite is not merely 'always print', it is "
                       "gated on the real boolean result.")),
    C('find', '-a binds tighter than -o (no explicit parens)',
      'expr -a expr ... in order of decreasing precedence',
      ['@TREE@', '-name', Q('A.TXT'), '-o', '-name', Q('B.BIN'),
       '-a', '-type', 'd'],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE,
      files={'TREE/A.TXT': ['x'], 'TREE/B.BIN': ['y']},
      hand=dict(stdout=['TREE/A.TXT'], rc=0,
                reason="parses as '-name A.TXT -o (-name B.BIN -a "
                       "-type d)'. TREE/A.TXT: left side true, "
                       "prints regardless of the right. TREE/B.BIN: "
                       "left false, right is '-name B.BIN -a -type "
                       "d' -- B.BIN IS a plain file, so -type d is "
                       "false and the AND is false -- NOT printed. "
                       "If -a bound LOOSER than -o (wrong "
                       "precedence: '(-name A.TXT -o -name B.BIN) "
                       "-a -type d'), TREE/A.TXT would ALSO fail "
                       "-type d and nothing would print at all -- "
                       "this case's non-empty, single-line answer "
                       "is exactly the wrong-precedence tell.")),
    C('find', 'explicit ( expr -o expr ) grouping parses',
      '( expression ) True if expression is true',
      ['@TREE@', Q('('), '-name', Q('A.TXT'), '-o', '-name',
       Q('B.BIN'), Q(')')],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE,
      files={'TREE/A.TXT': ['x'], 'TREE/B.BIN': ['y']},
      hand=dict(stdout=['TREE/A.TXT', 'TREE/B.BIN'], rc=0,
                reason="EVAL_FACT's TT_LPAR branch actually "
                       "consumes '(' ... ')' and recurses into "
                       "EVAL_EXPR for the grouped '-o' -- proving "
                       "the parenthesis tokens parse and evaluate, "
                       "not merely that this particular pair of "
                       "files would print the same without them.")),
    C('find', '! negates a primary',
      '! -- Negation of a primary; the unary NOT operator',
      ['@TREE@', '!', '-name', Q('*.TXT')],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE,
      files={'TREE/A.TXT': ['x']},
      hand=dict(stdout=['TREE', 'TREE/SUB'], rc=0,
                reason="findexpr.s's EVAL_FACT TT_NOT branch EORs "
                       "the sub-factor's result. TREE and TREE/SUB "
                       "(both directories, basenames 'TREE'/'SUB') "
                       "do not match '*.TXT' so '!' makes them "
                       "true and default-print fires; TREE/A.TXT "
                       "DOES match '*.TXT' so '!' makes it false.")),
    C('find', '-exec inside an -o arm only runs when reached',
      '-o ... The second expression shall not be evaluated if the '
      'first expression is true',
      ['@TREE@', '-name', Q('NOPE.TXT'), '-o', '-exec', 'ECHO',
       '{}', Q(';')],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE,
      files={'TREE/A.TXT': ['x'], 'TREE/B.BIN': ['y']},
      hand=dict(stdout=['TREE', 'TREE/SUB', 'TREE/A.TXT',
                         'TREE/B.BIN'], rc=0,
                reason="'-name NOPE.TXT' matches nothing in this "
                       "tree, so the -o's LEFT side is false for "
                       "EVERY visited node and the RIGHT side "
                       "(-exec ECHO {} ;) runs for every one of "
                       "them -- TREE (root) first, then SUB, "
                       "A.TXT, B.BIN in on-disk order -- proving "
                       "an action nested inside an -o arm is "
                       "reachable and fires exactly when the "
                       "grammar says it should (ANYACTION=1 from "
                       "the -exec token, so no default -print "
                       "besides). Same 'ECHO is maux's own binary' "
                       "reasoning as the plain -exec case above.")),
    C('find', '-size N matches exact 512-byte-block count',
      'the file size in bytes, divided by 512 and rounded up... is n',
      ['@TREE@', '-type', 'f', '-size', '1'],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE,
      files={'TREE/A.TXT': ['x'],
             'TREE/B.BIN': ['0123456789ABCDE'] * 40},
      hand=dict(stdout=['TREE/A.TXT'], rc=0,
                reason="TESTSIZE (findtst.s) OPENs+GET_EOFs each "
                       "file fresh. A.TXT is 2 bytes on disk "
                       "('x'+CR) -> ceil(2/512)=1 block, matches "
                       "'-size 1'. B.BIN is 40 lines of 16 bytes "
                       "('0123456789ABCDE'+CR) = 640 bytes -> "
                       "ceil(640/512)=2 blocks, does not match.")),
    C('find', '-size +N and the c (bytes) suffix',
      "If n is followed by the character 'c', the size shall be "
      'in bytes',
      ['@TREE@', '-name', Q('A.TXT'), '-size', '2c'],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE,
      files={'TREE/A.TXT': ['x']},
      hand=dict(stdout=['TREE/A.TXT'], rc=0,
                reason="A.TXT is exactly 2 bytes on disk ('x' + "
                       "one CR) -- '-size 2c' is an exact byte "
                       "match, exercising TESTSIZE's TT_SIZEC path "
                       "(no rounding) rather than the default "
                       "512-byte-block path the case above covers.")),
    C('find', '-links: every maux file has exactly one link',
      'true if the file has n links',
      ['@TREE@', '-type', 'f', '-links', '1'],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE,
      files={'TREE/A.TXT': ['x'], 'TREE/B.BIN': ['y']},
      hand=dict(stdout=['TREE/A.TXT', 'TREE/B.BIN'], rc=0,
                reason="TESTLINKS (findtst.s) never stats anything "
                       "-- ProDOS/maux has no hard-link support at "
                       "all, so the 'measured' link count is the "
                       "constant 1 for every file, compared via the "
                       "same +/-/exact CMPSIGN every numeric "
                       "primary uses. '-links 2' (not staged as its "
                       "own case) would match nothing, for the same "
                       "reason.")),
    C('find', '-path matches the WHOLE walked pathname, not the '
              'basename',
      'true if the current pathname matches pattern',
      ['@TREE@', '-path', Q('*/A.TXT')],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE,
      files={'TREE/A.TXT': ['x'], 'TREE/B.BIN': ['y']},
      hand=dict(stdout=['TREE/A.TXT'], rc=0,
                reason="'*/A.TXT' requires a '/' before the name -- "
                       "'-name' could never match this pattern (it "
                       "globs the bare basename only, never a "
                       "'/'); TESTPATH (findtst.s) globs EVPATH "
                       "(the full walked path) instead of EVBASE, "
                       "proving the two primaries read different "
                       "subjects.")),
    C('find', '-xdev is accepted and changes nothing (single '
              'device)',
      'cause find not to descend below directories that have a '
      'different device ID',
      ['@TREE@', '-xdev', '-name', Q('A.TXT')],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE,
      files={'TREE/A.TXT': ['x']},
      hand=dict(stdout=['TREE/A.TXT'], rc=0,
                reason="ProDOS has no multiple-device-per-tree "
                       "concept find could ever cross within one "
                       "walk, so '-xdev' is accepted as a constant-"
                       "true no-op (TT_XDEV in FACT_PRIM) -- ANDed "
                       "with '-name A.TXT' it must not change the "
                       "result versus that primary alone.")),
    C('find', '-nouser/-nogroup: no user database exists at all',
      'true if the file belongs to a user ID for which getpwuid '
      'returns NULL',
      ['@TREE@', '-nouser', '-a', '-nogroup', '-name', Q('A.TXT')],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE,
      files={'TREE/A.TXT': ['x']},
      hand=dict(stdout=['TREE/A.TXT'], rc=0,
                reason="ProDOS carries no owner/group concept at "
                       "all, so EVERY file's (nonexistent) owner "
                       "has no corresponding name -- '-nouser'/"
                       "'-nogroup' are honestly constant-true "
                       "(TT_NOUSER/TT_NOGROUP), not stubs; ANDed "
                       "with '-name A.TXT' the result must be "
                       "unchanged from that primary alone.")),
    C('find', '-mtime is false when the clock is absent',
      'the file modification time subtracted from the '
      'initialization time, divided by 86400... is n',
      ['@TREE@', '-name', Q('A.TXT'), '-a', '-mtime', '0'],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE,
      files={'TREE/A.TXT': ['x']},
      reset={'clock': False},
      hand=dict(stdout=[], rc=0,
                reason="reset={'clock': False} pins the Timemaster "
                       "card off, the same determinism trick "
                       "date.s's own NOCLOCK-path cases use (see "
                       "this module's header). GETNOW's validity "
                       "check (findtst.s, same rule as date.s/"
                       "ls.s) then leaves CLOCKOK=0, and TESTMTIME "
                       "makes -mtime FALSE for every file -- so "
                       "'-name A.TXT -a -mtime 0' prints NOTHING "
                       "even though the name half matches, per "
                       "this task's own instruction ('if the clock "
                       "is absent make it false'). A live-clock "
                       "day-difference value is NOT exercised here "
                       "(no synchronized-peek mechanism for a bare "
                       "case list, the same gap check_sumdate.py "
                       "exists to close for `date`/`sum` -- see "
                       "TESTMTIME's own header for the calendar-"
                       "day-vs-86400-seconds approximation it would "
                       "measure if it were)."),
    ),
    # SPLIT 2026-10-08 (docs/POSIX-HARNESS.md). The one row that said
    # "-ok/-perm/-user/-group/-depth are unimplemented" bundled two
    # SHIPPED primaries with three that can never ship. -depth (an
    # ordering rule, never interactive) and -ok (needs the interactive
    # harness) are rows in posixutil_cases6.py and go green there. What
    # is left HERE are the three that the MACHINE forbids, one row
    # apiece, held red on purpose so the divergence from the host is
    # gated rather than forgotten. They will still be red at 1.0.
    C('find', '-perm has no ProDOS meaning (held red, permanent)',
      '-perm [-]mode: true if the file permission bits match mode',
      ['@TREE@', '-perm', '755'],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE,
      known_gap="PERMANENT. ProDOS keeps a destroy/rename/backup/write/"
                "read access byte, not rwx for a user, a group and the "
                "world: there is no honest octal mapping to match a "
                "mode against (docs/ANACHRONISMS.md sec W2 rules a "
                "Unix rwx mapping out). -perm is not a row in "
                "findexpr.s's flag table, so TOKENIZE falls through to "
                "TOKBADFLG, exit 2; BSD and GNU find accept it and "
                "exit 0."),
    C('find', '-user has no ProDOS meaning (held red, permanent)',
      '-user uname: true if the file belongs to the user uname',
      ['@TREE@', '-user', 'root'],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE,
      known_gap="PERMANENT. ProDOS files have no owner and this machine "
                "has no user database, so there is no name to resolve "
                "and nothing to compare it with. -user falls through "
                "TOKENIZE to TOKBADFLG, exit 2; BSD and GNU find "
                "accept it."),
    C('find', '-group has no ProDOS meaning (held red, permanent)',
      '-group gname: true if the file belongs to the group gname',
      ['@TREE@', '-group', 'root'],
      dirs=FIND_TREE_DIRS, predirs=FIND_TREE_PRE,
      known_gap="PERMANENT. As -user: ProDOS files have no group and "
                "this machine has no group database. -group falls "
                "through TOKENIZE to TOKBADFLG, exit 2; the hosts "
                "accept it (BSD exit 0, GNU exit 1 when the group "
                "does not exist -- neither is 2)."),
]


# ======================================================================
# diff -- the default/-e forms are both host-oracleable (both BSD and
# GNU still default to the classic ed-script-compatible format POSIX
# fixes, and -e is well-defined on both); -u/-c/-r/-b are gap rows.
# ======================================================================
DIFF_A = ['alpha', 'bravo', 'charlie']
DIFF_B = ['alpha', 'BRAVO', 'charlie', 'delta']
#: Two change regions 13 unchanged lines apart -- far enough that
#: default -u (3 lines of context) writes TWO hunks and -U1 writes
#: two narrower ones, and close enough that nothing else in the file
#: differs. Every line is unique, so the minimal edit script is
#: unique too: there is no second LCS of equal cost for maux's DP
#: backtrace and the host's Myers to disagree over.
DIFF_N = [str(i) for i in range(1, 21)]
DIFF_N2 = ['THREE' if n == '3' else 'SEVENTEEN' if n == '17' else n
           for n in DIFF_N]

DIFF_CASES = [
    C('diff', 'identical files: exit 0, no output',
      '0 No differences were found.',
      ['@F1@', '@F2@'], files={'F1': DIFF_A, 'F2': list(DIFF_A)}),
    C('diff', 'differing files: default ed-script-compatible output',
      '"%dc%d\\n"... "<%s"... "---\\n"... ">%s"; 1 Differences were '
      'found',
      ['@F1@', '@F2@'], files={'F1': DIFF_A, 'F2': DIFF_B}),
    C('diff', 'missing file: exit 2',
      '>1 An error occurred.',
      ['@F1@', '@NOSUCH@'], files={'F1': DIFF_A, 'NOSUCH': None}),
    C('diff', '-e produces a pure ed script',
      'a script shall be produced that shall, when provided as input '
      'to ed... convert file1 into file2',
      ['-e', '@F1@', '@F2@'], files={'F1': DIFF_A, 'F2': DIFF_B}),
    # -u/-c SHIPPED 2026-09-17 (src/bin/diffctx.s). Both were
    # KNOWN_GAPS rows ("difftop.s's OPTS registers only 'e'") until
    # this round; they are ordinary host-oracled rows now, under the
    # `diffhdr` normalizer -- see check_posixutil.NORMALIZERS for why
    # the two header lines' timestamp field, and ONLY that field, is
    # dropped from both sides.
    C('diff', '-u unified context output',
      'The -u or -U options... the context, deleted, and added lines '
      'are shown together, interleaved',
      ['-u', '@F1@', '@F2@'], files={'F1': DIFF_A, 'F2': DIFF_B},
      norm='diffhdr'),
    C('diff', '-u merges change regions closer than 2*context',
      'If the changes are so close that the context lines overlap, '
      'the hunks shall be combined',
      ['-u', '@F1@', '@F2@'], files={'F1': DIFF_N, 'F2': DIFF_N2},
      norm='diffhdr'),
    C('diff', '-U 1 sets the number of context lines',
      '-U lines -- Produce output in a unified format with lines '
      'lines of copied context.',
      ['-U', '1', '@F1@', '@F2@'],
      files={'F1': DIFF_N, 'F2': DIFF_N2}, norm='diffhdr'),
    C('diff', '-u on an empty file1 is a 0,0 range',
      'If the range consists of no lines, the number printed shall '
      'be the line number of the line preceding the range',
      ['-u', '@F1@', '@F2@'], files={'F1': [], 'F2': DIFF_A},
      norm='diffhdr'),
    C('diff', '-c context output',
      'Produce output in a form that provides three lines of copied '
      'context',
      ['-c', '@F1@', '@F2@'], files={'F1': DIFF_A, 'F2': DIFF_B},
      norm='diffhdr'),
    C('diff', '-C 1 sets the number of context lines',
      '-C lines -- Produce output in a context format with lines '
      'lines of copied context.',
      ['-C', '1', '@F1@', '@F2@'],
      files={'F1': DIFF_N, 'F2': DIFF_N2}, norm='diffhdr'),
    C('diff', '-c omits a section with no changed line of its own',
      'If a hunk contains lines that are only deleted, the second '
      'file\'s section is not written',
      ['-c', '@F1@', '@F2@'],
      files={'F1': ['a', 'b', 'c', 'd'], 'F2': ['a', 'd']},
      norm='diffhdr'),
    # RETIRED 2026-10-08 (docs/POSIX-DIFFR.md): `diff -r` is shipped
    # (src/bin/diffrec.s). The finding it held red for -- "no 'r' in
    # OPTS, USAGERR exit 2; diff.s takes exactly two FILE operands
    # and opens them directly" -- is closed; BSD `diff -r` on two
    # empty directories prints nothing and exits 0, and so now does
    # maux. The DIFFR_CASES block after this list carries the rest.
    C('diff', '-r recursive is unimplemented',
      'Apply diff recursively to files and directories of the same '
      'name when file1 and file2 are both directories',
      ['-r', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2']),
    # SHIPPED 2026-09-21. DF_LCMP replaces the two STRCMP sites: it IS
    # STRCMP without -b (tail call, no cost), and with -b it applies
    # the rule in both halves -- trailing white space vanishes, and
    # other white-space runs compare equal TO EACH OTHER.
    #
    # A RUN MUST FACE A RUN, which is the half that is easy to get
    # wrong: "ab" and "a b" stay DIFFERENT under -b. The third row
    # pins that, because a -b that merged them would quietly hide a
    # difference a person can see.
    C('diff', '-b ignores trailing white space',
      'Cause any amount of white space at the end of a line to be '
      'treated as a single <newline>',
      ['-b', '@F1@', '@F2@'],
      files={'F1': ['a line'], 'F2': ['a line   ']}),
    C('diff', '-b makes white-space runs compare equal',
      'Cause any amount of white space at the end of a line to be '
      'treated as a single <newline>',
      ['-b', '@F1@', '@F2@'],
      files={'F1': ['a  b'], 'F2': ['a b']}),
    C('diff', '-b does NOT equate a run with no white space',
      'Cause any amount of white space at the end of a line to be '
      'treated as a single <newline>',
      ['-b', '@F1@', '@F2@'],
      files={'F1': ['ab'], 'F2': ['a b']}),
]


# ======================================================================
# diff -r -- the directory walk (src/bin/diffrec.s, 2026-10-08).
# Measured on BOTH hosts (BSD diff on the Mac, GNU diffutils 3.8 on
# the box) before any row was written; docs/POSIX-DIFFR-NOTES.md has
# the transcripts. They agree byte for byte on stdout for every
# host-oracled row below. They DISAGREE on three things, each of
# which is kept OUT of the host-oracled rows on purpose:
#   * "File A is a directory while file B is a regular file": same
#     text, but BSD exits 0 and GNU exits 1 -> hand= rows (POSIX: a
#     difference is 1).
#   * "Only in D1/: x" for a trailing-slash operand: GNU keeps the
#     slash, BSD drops it -> no row has a trailing slash AND an
#     Only-in line; the trailing-slash row differs only in a file.
#   * the header's option spelling is argv AS TYPED on both
#     (-r -u / -ru / -r -U 1 all echo verbatim) -> host-oracled.
# Names are ProDOS-legal upper case, so byte order of the name (the
# hosts' C-locale collation) is also ls's order.
# ======================================================================
DR_A = ['one', 'two', 'three']
DR_B = ['one', 'TWO', 'three']
DR_WS1 = ['a  b', 'c']
DR_WS2 = ['a b', 'c']


def _deep(n):
    """n nested directories A/A/.../A under each of D1 and D2, a
    differing file F at the bottom; (files, dirs, predirs). The roots
    are tagged D1/D2 because the rows' argv names them @D1@/@D2@ --
    a misspelt tag leaves the literal '@D1@' on BOTH sides and the
    row passes vacuously (it did, in the first draft)."""
    pre = {'D1': 'D1', 'D2': 'D2'}
    path = ''
    for i in range(n):
        path += '/A'
        pre['P1_%d' % i] = 'D1' + path
        pre['P2_%d' % i] = 'D2' + path
    files = {'D1' + path + '/F': DR_A, 'D2' + path + '/F': DR_B}
    return files, pre, sorted(pre)


_DEEP16 = _deep(16)
_DEEP17 = _deep(17)
#: 100 files per directory, staged in DESCENDING name order so the
#: sorted insert has to shift (READDIR returns creation order,
#: learning:01M1DZ3154XGWT70TNHYCBNPV9). F050 differs; D1 has an
#: extra and D2 has an extra.
_BIG1 = {'D1/F%03d' % i: ['n%d' % i] for i in range(100, 0, -1)}
_BIG2 = {'D2/F%03d' % i: (['n%d' % i] if i != 50 else ['changed'])
         for i in range(100, 0, -1)}
_BIG1['D1/G1ONLY'] = ['x']
_BIG2['D2/G2ONLY'] = ['y']
_BIG = dict(_BIG1)
_BIG.update(_BIG2)
#: Two listings of 360 entries: 2 * 360 * 17 = 12,240 > NAMESZ.
_HUGE = {}
for _i in range(360):
    _HUGE['D1/H%03d' % _i] = ['x']
    _HUGE['D2/H%03d' % _i] = ['x']

DIFFR_CASES = [
    C('diff', '-r on two identical trees: exit 0, no output',
      '0 No differences were found.',
      ['-r', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2', 'S1': 'D1/S', 'S2': 'D2/S'},
      predirs=['D1', 'D2', 'S1', 'S2'],
      files={'D1/A': DR_A, 'D1/S/B': DR_B, 'D2/A': list(DR_A),
             'D2/S/B': list(DR_B)}),
    C('diff', '-r names each differing pair with a diff line',
      'diff %s %s %s -- for each pair of files that differ',
      ['-r', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2'],
      files={'D1/F': DR_A, 'D2/F': DR_B}),
    C('diff', '-r prints Only in for a name in one directory only',
      'Only in %s: %s -- a file in one directory and not the other',
      ['-r', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2'],
      files={'D1/ONLY1': ['x'], 'D2/ONLY2': ['y'], 'D1/SAME': ['z'],
             'D2/SAME': ['z']}),
    C('diff', '-r merges the two listings in byte order of the name',
      'the collating sequence of the current locale -- C: bytes',
      ['-r', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2'],
      files={'D1/A': ['1'], 'D1/B.1': ['1'], 'D1/B2': ['1'],
             'D1/ZED': ['1'], 'D2/A': ['1'], 'D2/B.2': ['1'],
             'D2/C': ['1'], 'D2/ZED': ['2']}),
    C('diff', '-r descends: Only in names the SUBDIRECTORY it is in',
      'Only in %s: %s -- %s the directory pathname',
      ['-r', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2', 'S1': 'D1/S', 'S2': 'D2/S',
            'T1': 'D1/S/T', 'T2': 'D2/S/T'},
      predirs=['D1', 'D2', 'S1', 'S2', 'T1', 'T2'],
      files={'D1/S/T/X': ['x'], 'D2/S/T/Y': ['y'],
             'D1/S/T/Z': ['z'], 'D2/S/T/Z': ['z']}),
    C('diff', '-r visits files and subdirectories in one merged order',
      'recursively ... for each pair of files with the same name',
      ['-r', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2', 'S1': 'D1/S', 'S2': 'D2/S'},
      predirs=['D1', 'D2', 'S1', 'S2'],
      files={'D1/A': DR_A, 'D2/A': DR_B, 'D1/S/F': DR_A,
             'D2/S/F': DR_B, 'D1/Z': DR_A, 'D2/Z': DR_B}),
    C('diff', '-r -u: header carries the option as typed',
      'diff -r -u A B, then the unified listing',
      ['-r', '-u', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2'],
      files={'D1/F': DR_A, 'D2/F': DR_B}, norm='diffrhdr'),
    C('diff', '-ru: bundled options are echoed bundled',
      'the <diff options> are the options as specified',
      ['-ru', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2'],
      files={'D1/F': DR_A, 'D2/F': DR_B}, norm='diffrhdr'),
    C('diff', '-r -c: header then the context listing',
      'diff -r -c A B, then the context listing',
      ['-r', '-c', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2'],
      files={'D1/F': DR_A, 'D2/F': DR_B}, norm='diffrhdr'),
    C('diff', '-r -e: header then a pure ed script',
      'diff -r -e A B, then the ed script',
      ['-r', '-e', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2'],
      files={'D1/F': DR_A, 'D2/F': DR_B}),
    C('diff', '-r -U 1: an option with an argument echoes both words',
      'diff -r -U 1 A B',
      ['-r', '-U', '1', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2'],
      files={'D1/F': DIFF_N, 'D2/F': DIFF_N2}, norm='diffrhdr'),
    C('diff', '-r -C 1: context width reaches every pair',
      'diff -r -C 1 A B',
      ['-r', '-C', '1', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2'],
      files={'D1/F': DIFF_N, 'D2/F': DIFF_N2}, norm='diffrhdr'),
    C('diff', '-r -b: white-space-only differences print nothing',
      '-b Cause any amount of white space at the end of a line to be '
      'treated as a single <newline>',
      ['-r', '-b', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2'],
      files={'D1/F': DR_WS1, 'D2/F': DR_WS2}),
    C('diff', '-rb: -r and -b bundled still both take effect',
      'diff -rb: the header echoes the bundle, -b hides the diff',
      ['-rb', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2'],
      files={'D1/F': DR_WS1, 'D2/F': DR_WS2, 'D1/G': DR_A,
             'D2/G': DR_B}),
    C('diff', 'two directories WITHOUT -r: pairs diffed, subdirs named',
      'Common subdirectories: %s and %s',
      ['@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2', 'S1': 'D1/S', 'S2': 'D2/S'},
      predirs=['D1', 'D2', 'S1', 'S2'],
      files={'D1/F': DR_A, 'D2/F': DR_B, 'D1/S/G': DR_A,
             'D2/S/G': DR_B}),
    C('diff', 'two directories WITHOUT -r, only common subdirectories',
      'Common subdirectories: ... exit 0 when nothing else differs',
      ['@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2', 'S1': 'D1/S', 'S2': 'D2/S'},
      predirs=['D1', 'D2', 'S1', 'S2']),
    C('diff', 'FILE DIR compares FILE with DIR/basename, no header',
      'If only one of file1 and file2 is a directory, diff shall be '
      'applied to the non-directory file and the file contained in '
      'the directory file with a filename that is the same as the '
      'last component of the non-directory file.',
      ['@D1/F@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2'],
      files={'D1/F': DR_A, 'D2/F': DR_B}),
    C('diff', 'DIR FILE: the same rule with the directory first',
      'If only one of file1 and file2 is a directory...',
      ['@D2@', '@D1/F@'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2'],
      files={'D1/F': DR_A, 'D2/F': DR_B}),
    C('diff', 'FILE DIR with identical contents: exit 0',
      'If only one of file1 and file2 is a directory...',
      ['@D1/F@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2'],
      files={'D1/F': DR_A, 'D2/F': list(DR_A)}),
    C('diff', 'FILE DIR with no DIR/basename: exit 2',
      '>1 An error occurred.',
      ['@D1/F@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2'],
      files={'D1/F': DR_A}),
    C('diff', 'the same FILE twice is identical (no second open)',
      '0 No differences were found. (ProDOS refuses a second OPEN)',
      ['@F@', '@F@'], files={'F': DR_A}),
    C('diff', '-r on the same directory twice is identical',
      '0 No differences were found.',
      ['-r', '@D1@', '@D1@'],
      dirs={'D1': 'D1'}, predirs=['D1'], files={'D1/F': DR_A}),
    C('diff', '-r with a missing operand: exit 2',
      '>1 An error occurred.',
      ['-r', '@D1@', '@NOSUCH@'],
      dirs={'D1': 'D1'}, predirs=['D1'], files={'NOSUCH': None}),
    C('diff', '-r orders mixed-case names by BYTE, not as ls does',
      'the collating sequence of the current locale -- C: bytes',
      ['-r', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2'],
      files={'D1/apple': ['1'], 'D1/Banana': ['1'], 'D1/ZED': ['1'],
             'D2/cherry': ['1']}),
    C('diff', '-r with a trailing slash prints the same header',
      'diff -r A/F B/F -- the slash is not doubled',
      ['-r', '@D1@/', '@D2@/'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2'],
      files={'D1/F': DR_A, 'D2/F': DR_B}),
    C('diff', '-r at 100 entries per directory, staged out of order',
      'Only in ... and diff lines, all in collating order',
      ['-r', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2'],
      files=_BIG),
    C('diff', '-r at the depth bound: 16 nested levels still compare',
      'a recursive diff has no depth limit; maux bounds it at 16',
      ['-r', '@D1@', '@D2@'],
      files=_DEEP16[0], dirs=_DEEP16[1], predirs=_DEEP16[2]),
    C('diff', '-r one level past the bound is refused loudly',
      'maux bound: DMAXDEP levels; deeper is exit 2, never a '
      'silently shortened walk',
      ['-r', '@D1@', '@D2@'],
      files=_DEEP17[0], dirs=_DEEP17[1], predirs=_DEEP17[2],
      hand=dict(stdout=[], rc=2,
                reason='DMAXDEP is 16 saved levels (diffrec.s). The '
                       'hosts have no such bound; this is a stated '
                       'maux limit, so the expectation is authored '
                       'here: nothing on stdout, exit 2, and the '
                       'differing file at the bottom is NOT reached '
                       '(a partial walk would be a wrong answer).')),
    C('diff', '-r whose listings do not fit the name arena: exit 2',
      'maux bound: NAMESZ; an unlisted directory is never compared',
      ['-r', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2'}, predirs=['D1', 'D2'],
      files=_HUGE,
      hand=dict(stdout=[], rc=2,
                reason='360 + 360 entries at 17 bytes is 12,240 > '
                       'NAMESZ 12,000 (diff.s). The trees are '
                       'IDENTICAL, so a truncated comparison would '
                       'have said exit 0; the loud failure is exit 2 '
                       'with nothing on stdout.')),
    C('diff', 'directory vs file of the same name is reported (rc 1)',
      'File %s is a directory while file %s is a regular file',
      ['-r', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2', 'S1': 'D1/X'}, predirs=['D1', 'D2', 'S1'],
      files={'D2/X': ['file']},
      hand=dict(stdout=['File D1/X is a directory while file D2/X is '
                        'a regular file'], rc=1,
                reason='Both hosts print this line; GNU exits 1 and '
                       'BSD exits 0. POSIX makes any difference 1.')),
    C('diff', 'file vs directory of the same name is reported (rc 1)',
      'File %s is a regular file while file %s is a directory',
      ['-r', '@D1@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2', 'S2': 'D2/X'}, predirs=['D1', 'D2', 'S2'],
      files={'D1/X': ['file']},
      hand=dict(stdout=['File D1/X is a regular file while file D2/X '
                        'is a directory'], rc=1,
                reason='Same hosts divergence as the row above (GNU '
                       '1, BSD 0); the order of the two kinds follows '
                       'the operands.')),
    C('diff', 'FILE DIR whose DIR/basename is a directory is reported',
      'File %s is a regular file while file %s is a directory',
      ['@D1/X@', '@D2@'],
      dirs={'D1': 'D1', 'D2': 'D2', 'S2': 'D2/X'}, predirs=['D1', 'D2', 'S2'],
      files={'D1/X': ['file']},
      hand=dict(stdout=['File D1/X is a regular file while file D2/X '
                        'is a directory'], rc=1,
                reason='GNU 1, BSD 0 on a stat mismatch; POSIX 1.')),
    C('diff', '-r with "." as an operand keeps the typed spelling',
      'diff -r ./SUB/X D2/SUB/X -- "." resolves, the display stays',
      ['-r', '.', '@D2@'],
      dirs={'S1': 'SUB', 'D2': 'D2', 'S2': 'D2/SUB'},
      predirs=['S1', 'D2', 'S2'],
      files={'SUB/X': DR_A, 'D2/SUB/X': DR_B},
      hand=lambda base: dict(
          stdout=['Only in .: D2', 'Only in .: OUT',
                  'diff -r ./SUB/X D2/SUB/X',
                  '2c2', '< two', '---', '> TWO'], rc=1,
          reason="The case's own base holds D2 and OUT (the shell "
                 "created OUT for the redirect before DIFF ran) beside "
                 "SUB, so a host run on a scratch cwd cannot see the "
                 "same tree; the expectation is authored. D2 and OUT "
                 "sort before SUB, so their lines come first.")),
]
DIFF_CASES.extend(DIFFR_CASES)


# ======================================================================
# ls -- stdout is always redirected here (`> OUT`), so SC_TTYGEO fails
# and ls.s's own COLSETUP takes the "not a console" branch: single
# column unless -C is given (lscol.s's own header, ls.s's own COLSETUP
# comment). That default IS host-oracleable (a redirected host `ls`
# is one-per-line too); -l's date/size columns are hand rows keyed to
# structure (a2til-staged files carry no mod-date stamp at all, so
# ls.s's PRINTDATE takes its own documented zero-date "-" branch,
# DASHFIELD = '-' + 5 spaces, six bytes -- NOT the sixteen the routine
# header's comment claims; a stale comment, src/bin/lsprint.s, that
# does not affect behaviour and is reported separately, not gated
# here).
# ======================================================================
LS_NAMES = ['bravo', 'alpha', 'charlie']

LS_CASES = [
    C('ls', 'redirected stdout is one name per line (not a console)',
      'The default format shall be to list one entry per line to '
      'standard output; the exceptions are to terminals or when one '
      'of the -C, -m, or -x options is specified.',
      ['@D@'], dirs={'D': 'D'}, predirs=['D'],
      files={'D/ALPHA': ['x'], 'D/BRAVO': ['y'], 'D/CHARLIE': ['z']}),
    C('ls', '-1 forces one name per line explicitly',
      '-1 Force output to be one entry per line.',
      ['-1', '@D@'], dirs={'D': 'D'}, predirs=['D'],
      files={'D/ALPHA': ['x'], 'D/BRAVO': ['y']}),
    C('ls', '-r reverses the (name) sort order',
      'Reverse the order of the sort to get reverse collating '
      'sequence',
      ['-r', '@D@'], dirs={'D': 'D'}, predirs=['D'],
      files={'D/ALPHA': ['x'], 'D/BRAVO': ['y'], 'D/CHARLIE': ['z']}),
    C('ls', '-C columns even though stdout is not a console',
      'Write multi-text-column output with entries sorted down the '
      'columns',
      ['-C', '@D@'], dirs={'D': 'D'}, predirs=['D'],
      files={'D/A': ['x'], 'D/B': ['y'], 'D/C': ['z']},
      hand=dict(
          stdout=['A  B  C'], rc=0,
          reason="lscol.s's COLSETUP: not a console + -C given -> "
                 "width 80 (its own header: '80 for -C on a file or "
                 "pipe'); LSCOLW = longest name (1) + 2 = 3; NCOLS = "
                 "80/3 = 26; with only 3 entries, NROWS = ceil(3/26) "
                 "= 1, so all three land in row 0 (column-major with "
                 "one row degenerates to left-to-right) padded to "
                 "LSCOLW except the last -- structural, no host "
                 "equivalent for THIS width policy (BSD ls -C sizes "
                 "columns to $COLUMNS or 80 too, but pads "
                 "differently), hand-keyed to lscol.s's own PRINTCOLS "
                 "rather than captured.")),
    # -l ('Write out in long format') is NOT a case here, by finding
    # rather than oversight: it was staged and run once, expecting
    # a2til's mod-date field to read zero (PRINTDATE's own documented
    # ":dateblank" branch, '-' + five spaces). It does NOT -- a2til's
    # prodos.write() stamps the HOST'S OWN CURRENT WALL CLOCK on every
    # write with no override hook in its public API (confirmed: `wc
    # -l x.txt` staged and re-read back showed a live "2026-09-13
    # 22:04", not zero). A byte-exact -l row would therefore have to
    # predict a live clock reading made at STAGING time from code that
    # only runs at COMPARISON time afterward -- exactly the timing
    # race this tree's own memory warns against ("Red tracks image
    # size = timing race": a snapshot race, not alignment). Fixing it
    # properly needs a2til-side plumbing (Volume.set_file_info's own
    # last_mod= datetime, called after staging, threaded through a new
    # per-case hook) that is out of scope for this round; the TYPE and
    # EOF(size) columns were confirmed byte-exact against
    # PRINTENTLONG's own field order in that same run, only the DATE
    # column is the open problem. Documented here rather than shipped
    # flaky.
    C('ls', '-d list the directory itself, not its contents',
      'Do not follow symbolic links... Do not treat directories '
      'differently than other types of files.',
      ['-d', '@D@'], dirs={'D': 'D'}, predirs=['D'],
      files={'D/A': ['x']}),
    C('ls', '-R recursively lists subdirectories',
      'Recursively list subdirectories encountered.',
      ['-R', '@D@'], dirs={'D': 'D', 'SUB': 'D/SUB'},
      predirs=['D', 'SUB']),
    C('ls', '-F appends a slash to a directory',
      "Write a <slash> ('/') immediately after each pathname that is "
      "a directory",
      ['-F', '@D@'], dirs={'D': 'D', 'SUB': 'D/SUB'},
      predirs=['D', 'SUB']),
    C('ls', '-s reports ProDOS blocks used',
      '-s Indicate the total number of file system blocks consumed '
      'by each file displayed.',
      ['-s', '@D@'], dirs={'D': 'D'}, predirs=['D'],
      files={'D/A': ['x']},
      hand=dict(stdout=['1 A'], rc=0,
                reason='a2til stages this one-byte seedling file in '
                       'one ProDOS 512-byte block; maux reports the '
                       'directory entry blocks_used field directly.')),
]


# ======================================================================
# cp / mv / rm -- side effects verified through a `post` follow-up in
# the SAME shell session (hand=, always -- see module header).
# ======================================================================
CPMVRM_CASES = [
    C('cp', 'cp -r copies a directory tree',
      'Copy file hierarchies.',
      ['-r', '@D@', 'DEST'],
      dirs={'D': 'D'}, predirs=['D'],
      files={'D/FILE.TXT': ['hello'], 'PROBE': None},
      post=[['CAT', 'DEST/FILE.TXT', '>', '@PROBE@']],
      results=['PROBE'],
      hand=dict(stdout=[], rc=0, files={'PROBE': ['hello']},
                reason="the assertion is a filesystem side effect (a "
                       "whole tree really landed at DEST) proved by "
                       "a follow-up CAT in the same shell session -- "
                       "oracle()'s host path runs exactly one process "
                       "per case and has no `post` hook to diff "
                       "against, so this is hand-authored to the "
                       "harness's own known fixture content, not a "
                       "captured maux run.")),
    C('mv', 'mv renames within the same directory',
      'shall perform actions equivalent to the rename() function',
      ['@F@', 'RENAMED.TXT'], files={'F': ['hello'], 'PROBE': None},
      post=[['CAT', 'RENAMED.TXT', '>', '@PROBE@']],
      results=['PROBE'],
      hand=dict(stdout=[], rc=0, files={'PROBE': ['hello']},
                reason="side effect verified via a follow-up CAT in "
                       "the same session; see cp -r's own reason.")),
    C('rm', 'rm -r removes a directory tree',
      'Remove file hierarchies.',
      ['-r', '@D@'], dirs={'D': 'D'}, predirs=['D'],
      files={'D/FILE.TXT': ['x'], 'PROBE': None},
      post=[['MKDIR', 'D'], ['echo', '$?', '>', '@PROBE@']],
      results=['PROBE'],
      hand=dict(stdout=[], rc=0, files={'PROBE': ['0']},
                reason="if 'D' really is gone, a plain MKDIR D "
                       "(no -p) recreates it successfully (exit 0); "
                       "if rm -r left anything behind, MKDIR D fails "
                       "(D already exists), exit >0 -- a side-effect "
                       "proof, hand-authored for the same reason as "
                       "cp -r's own case.")),
    C('rm', '-f forgives a nonexistent operand, exit 0',
      'Do not write diagnostic messages or modify the exit status in '
      'the case of ... operands that do not exist.',
      ['-f', '@NOSUCH@'], files={'NOSUCH': None}),
    C('cp', '-p preserves ProDOS attributes and dates',
      'Duplicate... the time of last data modification... the file '
      'permission bits',
      ['-p', '@F@', 'DEST2.TXT'],
      files={'F': ['x']},
      meta_equal=[('F', 'DEST2.TXT',
                   ('access', 'type', 'aux_type', 'creation',
                    'last_mod'))],
      hand=dict(stdout=[], rc=0,
                reason='the harness reads both ProDOS directory '
                       'entries after cp and compares access, type, '
                       'aux, creation, and modification fields.')),
    C('cp', '-i accepts a new destination without prompting',
      'Write a prompt to standard error before copying to any '
      'existing non-directory destination file.',
      ['-i', '@F@', 'DEST3.TXT'], files={'F': ['x']}),
    C('cp', '-i affirmative response replaces destination',
      'If the response is affirmative, cp shall perform the copy.',
      ['-i', '@F@', 'DEST4.TXT'], stdin='IN',
      files={'IN': ['y'], 'F': ['new'], 'DEST4.TXT': ['old'],
             'PROBE': None},
      post=[['CAT', 'DEST4.TXT', '>', '@PROBE@']], results=['PROBE'],
      hand=dict(stdout=[], rc=0, files={'PROBE': ['new']},
                reason='the follow-up CAT proves the affirmative '
                       'response permitted replacement.')),
    C('mv', '-i declines overwrite on end of input',
      'Prompt for confirmation if the destination path exists.',
      ['-i', '@F1@', '@F2@'], stdin='IN',
      files={'IN': [], 'F1': ['x'], 'F2': ['y'],
             'PROBE1': None, 'PROBE2': None},
      post=[['CAT', 'F1', '>', '@PROBE1@'],
            ['CAT', 'F2', '>', '@PROBE2@']],
      results=['PROBE1', 'PROBE2'],
      hand=dict(stdout=[], rc=0,
                files={'PROBE1': ['x'], 'PROBE2': ['y']},
                reason='the two follow-up CATs prove a declined '
                       'overwrite left both operands unchanged.')),
    C('mv', '-f replaces without prompting',
      'Do not prompt for confirmation if the destination path '
      'exists.',
      ['-f', '@F1@', '@F2@'],
      files={'F1': ['x'], 'F2': ['y'], 'PROBE': None},
      post=[['CAT', 'F2', '>', '@PROBE@']], results=['PROBE'],
      hand=dict(stdout=[], rc=0, files={'PROBE': ['x']},
                reason='the follow-up CAT proves replacement.')),
    C('mv', '-i affirmative response replaces destination',
      'If the response is affirmative, mv shall perform the move.',
      ['-i', '@F1@', '@F2@'], stdin='IN',
      files={'IN': ['y'], 'F1': ['new'], 'F2': ['old'], 'PROBE': None},
      post=[['CAT', 'F2', '>', '@PROBE@']], results=['PROBE'],
      hand=dict(stdout=[], rc=0, files={'PROBE': ['new']},
                reason='the follow-up CAT proves the affirmative '
                       'response permitted replacement.')),
    C('rm', '-i declines removal on end of input',
      'Prompt for confirmation as described previously.',
      ['-i', '@F@'], stdin='IN',
      files={'IN': [], 'F': ['x'], 'PROBE': None},
      post=[['CAT', 'F', '>', '@PROBE@']], results=['PROBE'],
      hand=dict(stdout=[], rc=0, files={'PROBE': ['x']},
                reason='the follow-up CAT proves a declined removal '
                       'left the operand intact.')),
    C('rm', '-i affirmative response removes operand',
      'If the response is affirmative, rm shall attempt to remove it.',
      ['-i', '@F@'], stdin='IN',
      files={'IN': ['y'], 'F': ['x'], 'PROBE': None},
      post=[['MKDIR', 'F'], ['echo', '$?', '>', '@PROBE@']],
      results=['PROBE'],
      hand=dict(stdout=[], rc=0, files={'PROBE': ['0']},
                reason='MKDIR F succeeds only if rm removed the file.')),
]


# ======================================================================
# date -- reset={'clock': False}; see module header.
# ======================================================================
DATE_CASES = [
    C('date', 'no clock: refuses rather than print a fabricated date',
      'the output... shall be equivalent to specifying: date "+%a '
      '%b %e %H:%M:%S %Z %Y" -- which requires an actual reading of '
      'the current time',
      [], reset={'clock': False},
      hand=dict(stdout=[], rc=1,
                reason="reset(clock=False) pins the Timemaster card "
                       "OFF (default ON, mcp__verilogapple__reset's "
                       "own doc) so SC_CLOCK reads all zero; date.s's "
                       "own header: 'If the clock is ABSENT... a "
                       "message goes to fd 2 and it exits 1' -- "
                       "diagnostic wording is never compared, only "
                       "stdout (empty: nothing was ever written "
                       "there) and the exit status. check_sumdate.py "
                       "already exercises the REAL-clock path with a "
                       "synchronized peek this batch-oracle harness "
                       "has no hook for; this proves the courteous-"
                       "refusal path deterministically instead.")),
    C('date', '+format with no clock: still refuses (unchanged)',
      'When the format is specified, the output shall be formatted '
      'as if by strftime()',
      [Q('+%Y%m%d')], reset={'clock': False},
      hand=dict(stdout=[], rc=1,
                reason="SHIPPED 2026-09-17: +FORMAT is now REALLY "
                       "parsed (PROCFMT/PFDISPATCH, date.s) -- but "
                       "READCLOCK runs before PROCFMT ever does, and "
                       "with the clock disabled it refuses exactly "
                       "the way the no-operand form always has "
                       "(NOCLOCK, exit 1, nothing on stdout). This "
                       "row cannot assert the FORMATTED content: "
                       "check_posixutil's reset(clock=...) is a "
                       "boolean (present/absent), not a settable "
                       "wall-clock value, so no batch row here can "
                       "pin exact +FORMAT output -- that needs "
                       "check_sumdate.py's own raw-clock-peek "
                       "mechanism extended to a +FORMAT invocation, "
                       "not done in this task (date.s's own header "
                       "names this gap explicitly).")),
]


# ======================================================================
# touch -- side effect verified via a `post` follow-up (hand=).
# ======================================================================
TOUCH_CASES = [
    C('touch', 'creates a missing file, empty, exit 0',
      'If file does not exist: The creat() function is called',
      ['@F@'], files={'F': None, 'PROBE': None},
      post=[['CAT', '@F@', '>', '@PROBE@']], results=['PROBE'],
      hand=dict(stdout=[], rc=0, files={'PROBE': []},
                reason="touch.s's own header: a missing operand is "
                       "CREATEd empty, TXT type -- proved by a "
                       "follow-up CAT (empty output) in the same "
                       "session; see cp -r's own reason for why this "
                       "is hand- not host-authored.")),
    C('touch', '-t explicit timestamp',
      'Use the specified time instead of the current time.',
      ['-t', '202001010000', '@F@'],
      files={'F': None, 'PROBE': None},
      post=[['test', '-f', '-t'], ['echo', '$?', '>', '@PROBE@'],
            ['test', '-f', '202001010000'],
            ['echo', '$?', '>>', '@PROBE@']],
      results=['PROBE'],
      hand=dict(stdout=[], rc=0, files={'PROBE': ['1', '1']},
                reason="SHIPPED 2026-09-17: -t now runs through "
                       "GETOPT (TOPTS='t:r:') and PARSESTAMP, so "
                       "'-t' and its STAMP argument are consumed as "
                       "ONE flag+arg pair instead of two extra FILE "
                       "operands -- the exact bug the ORIGINAL "
                       "known_gap named ('touch creates a file "
                       "literally named -t, then 202001010000 as a "
                       "SECOND file'): neither exists as a file "
                       "afterward (both TEST -f probes read false, "
                       "'1'). PARSESTAMP's own bit-packing (day/"
                       "month/year7 into TS_DATE, hour/minute into "
                       "TS_TIME) was hand-verified against date.s's "
                       "own decode (the exact inverse operation), "
                       "not re-derived from scratch -- the resulting "
                       "STAMP VALUE is not independently re-checked "
                       "here via ls -l, which LS_CASES documents "
                       "elsewhere as unreliable in this harness for "
                       "an unrelated a2til staging-time reason.")),
    C('touch', '-r reference-file timestamp',
      'Use the corresponding time of the file named by the pathname '
      'ref_file instead of the current time.',
      ['-r', '@REF@', '@F@'],
      files={'REF': ['x'], 'F': None, 'PROBE': None},
      post=[['test', '-f', '-r'], ['echo', '$?', '>', '@PROBE@']],
      results=['PROBE'],
      hand=dict(stdout=[], rc=0, files={'PROBE': ['1']},
                reason="SHIPPED 2026-09-17: -r now runs through "
                       "GETOPT and GETREFSTAMP (GET_FILE_INFO on "
                       "REF, copying its own mod_date/mod_time into "
                       "TS_DATE/TS_TIME verbatim), so '-r' is "
                       "consumed as a flag instead of a plain FILE "
                       "operand -- the exact bug the ORIGINAL "
                       "known_gap named: no file literally named "
                       "'-r' exists afterward. GETREFSTAMP's copy "
                       "is a straight register move of GFIPARM's "
                       "already-proven MDATE/MTIME fields (the same "
                       "fields the EXISTS branch of touch's own main "
                       "loop already read/wrote before this task), "
                       "so the resulting VALUE is not independently "
                       "re-verified here -- an ls -l date-column "
                       "check would also hit REF's OWN a2til "
                       "staging-time stamp (the host's live wall "
                       "clock, no override hook -- LS_CASES's "
                       "documented reason, not a new one).")),
]


# ======================================================================
# du -- block counts hand-computed: a2til-staged small text files are
# ProDOS seedlings (<512B, one data block); a directory's own entry
# costs one more (du.s's own header: "a subdirectory's own total "
# SEEDS at its own blocks_used"). Verified empirically against this
# gate's own run rather than assumed if the numbers ever drift.
# ======================================================================
DU_CASES = [
    C('du', '-s summary: one grand total per argument',
      'Instead of the default output, report only the total sum.',
      ['-s', '@D@'], dirs={'D': 'D'}, predirs=['D'],
      files={'D/A': ['x'], 'D/B': ['y']},
      hand=dict(stdout=['3\tD'], rc=0,
                reason="ProDOS block accounting, not a byte count a "
                       "host filesystem shares: each small staged "
                       "file is a seedling (1 data block, <512B), "
                       "and the directory D itself costs its own key "
                       "block (du.s header: a subdirectory's total "
                       "'SEEDS at its own blocks_used') -- 1(D) + "
                       "1(A) + 1(B) = 3. No host `du` reports ProDOS "
                       "block units, so this is hand, not "
                       "host-oracled.")),
    C('du', '-a also lists every plain file',
      'In addition to the default output, report the size of each '
      'file not of type directory.',
      ['-a', '@D@'], dirs={'D': 'D'}, predirs=['D'],
      files={'D/A': ['x'], 'D/B': ['y']},
      hand=dict(stdout=['1\tD/A', '1\tD/B', '3\tD'], rc=0,
                reason="same block accounting as du -s's own case; "
                       "order is du.s's documented deepest-first "
                       "post-order walk (files before their "
                       "enclosing directory's own total), file order "
                       "within D is ProDOS directory-entry (creation) "
                       "order, matching this harness's own staging "
                       "order.")),
    C('du', '-k kilobyte units',
      'Write the files sizes in units of 1024 bytes, rather than the '
      'default 512-byte units.',
      ['-k', '-s', '@D@'], dirs={'D': 'D'}, predirs=['D'],
      files={'D/A': ['x']},
      hand=dict(stdout=['1\tD'], rc=0,
                reason="SHIPPED 2026-09-17: TOKB converts U2DEC_VAL "
                       "to (blocks+1)/2 right before PRLINE prints "
                       "it (ceiling -- an odd 512-byte block is "
                       "still a whole KB once rounded up), leaving "
                       "every accumulator counting real ProDOS "
                       "blocks throughout the walk. D + A is 2 "
                       "512-byte blocks (D's own key block, A's one "
                       "seedling data block, same accounting as the "
                       "-s case above) -> 1 KB unit. No host `du` "
                       "reports ProDOS block units, so this is "
                       "hand, not host-oracled, like every other du "
                       "row here.")),
    C('du', 'a trailing slash on an operand is not doubled',
      'du [-a|-s] [-kx] [file...] -- the path of each entry is the '
      'operand joined to the entry name.',
      ['-a', '@D@/'], dirs={'D': 'D'}, predirs=['D'],
      files={'D/A': ['x'], 'D/B': ['y']},
      hand=dict(stdout=['1\tD/A', '1\tD/B', '3\tD/'], rc=0,
                reason="docs/DU-DF.md: du joined PATH + '/' + name "
                       "unconditionally, so `du D/` printed D//A "
                       "(BSD du still does; GNU du prints D/A). One "
                       "'/' between the parts, and the total line "
                       "echoes the operand as typed, D/. Same "
                       "block accounting as the -a row above. No "
                       "host `du` reports ProDOS block units, so "
                       "this is hand, not host-oracled.")),
]

# ======================================================================
# df -- POSIX -P form (docs/DU-DF.md). Used/Available depend on the
# volume's own state (every staged file moves them), so the rows pin
# what never moves: the -P header, and the row's volume, total and
# shape. check-df pins Used/Available exactly against a2til's bitmap
# count. No host `df` can be the oracle -- it reports the HOST
# filesystem holding the image.
# ======================================================================
DF_CASES = [
    C('df', '-P prints the POSIX header',
      'Filesystem 512-blocks Used Available Capacity Mounted on',
      ['-P', '.'],
      hand=dict(stdout=None, contains='Filesystem 512-blocks Used '
                'Available Capacity Mounted on', rc=0,
                reason="the header text is POSIX's own -P format "
                       "(also what this Mac's `df -P` prints), "
                       "carried by the `contains` form because the "
                       "row under it moves with every staged file.")),
    C('df', '-P . reports the working directory\'s volume',
      'df [-k] [-P] [file...] -- the file system containing each '
      'operand.',
      ['-P', '.'],
      hand=dict(stdout=None, contains='/mnt/MAUX 8192 ', rc=0,
                reason="`.` resolves through liba's MKPATH to the "
                       "prefix, whose volume is /mnt/MAUX, 8192 "
                       "blocks (the 4 MB play carrier); the row "
                       "begins '/mnt/MAUX 8192 '. Used/Available/"
                       "Capacity follow it and are check-df's.")),
]


# ======================================================================
# tee -- host-oracleable (copies stdin to stdout AND the named file).
# ======================================================================
TEE_CASES = [
    C('tee', 'copies stdin to stdout and to the named file',
      'The tee utility shall copy standard input to standard '
      'output, making a copy in zero or more files.',
      ['@W@'], files={'IN': ['line one', 'line two'], 'W': None},
      stdin='IN', results=['W']),
    C('tee', '-a appends instead of truncating',
      'Append the output to the files.',
      ['-a', '@W@'], files={'IN': ['new'], 'W': ['old']}, stdin='IN',
      results=['W']),
    C('tee', '-i ignores SIGINT',
      'Ignore the SIGINT signal.',
      ['-i', '@W@'], files={'IN': ['x'], 'W': None}, stdin='IN',
      results=['W']),
]


# ======================================================================
# echo -- the BINARY, /bin/ECHO (MAUX_BIN['echo'] in
# check_posixutil.py points there so the shell builtin never shadows
# it -- see this module's own header).
# ======================================================================
ECHO_CASES = [
    C('echo', 'arguments joined by single spaces, CR-terminated',
      "A string to be written to standard output.",
      ['one', 'two', 'three']),
    C('echo', 'no arguments prints just a newline',
      'write to standard output... followed by a <newline>.',
      []),
    C('echo', "-n as argv[1] suppresses the trailing newline",
      "the results are implementation-defined (this implementation: "
      "argv[1] exactly '-n' suppresses the trailing newline, matched "
      "against a live /bin/echo -- see echo.s's own header)",
      ['-n', 'ok']),
]


# ======================================================================
# kill -- see module header for why no live background pid is used.
# ======================================================================
KILL_CASES = [
    # NOT a case here, by finding: `kill -9 $$` (signo 9, targeting
    # the INTERACTIVE SHELL that spawned kill) HANGS THE CONSOLE.
    # Reproduced live (this module's own first gate run, 2026-09-13):
    # typed as the shell's OWN foreground command, `KILL -9 $$ > OUT`
    # never returns a prompt (30+ s, this suite's own settle() timeout
    # at max_steps=2500) and cascaded HARNESS failures onto every case
    # staged after it in the same boot group, because nothing was ever
    # typed for them. `kill -0 $$` (the same target, signo 0) is
    # perfectly safe and returns immediately, exit 0 -- proving $$ is
    # an ORDINARY process here, not root-tier-protected as this
    # module first assumed (see the surviving '-0' case below); the
    # divergence is specifically -9's FORCE path. Likely mechanism,
    # read from src/kernel/procspawn2.s's PRC_KILL: the shell is
    # BLOCKED in SC_WAIT for kill (its own child) to finish when kill
    # marks the SAME pid's PCB ZOMBIE via the ':force' branch; kill
    # then exits and calls SCH_WAKEUP on ITS OWN parent -- the very
    # process just zombified -- which is never rescheduled, so the
    # console that was reading from it never gets another prompt. This
    # is a genuine kernel edge case (a child force-killing the parent
    # that is synchronously blocked waiting for it), not merely a
    # test-harness artifact -- reported per the task brief rather than
    # fixed, and NOT staged as a running case because it would hang
    # (and poison) whatever boot group it landed in, defeating the
    # gate's own purpose. See the report for the finding write-up.
    C('kill', '-0 on the interactive shell: a live, ordinary pid',
      "the symbolic name 0 shall be recognized, representing the "
      "signal value zero",
      ['-0', '$$'],
      hand=dict(stdout=[], rc=0,
                reason="$$ names the INTERACTIVE SHELL kill was "
                       "spawned from. Measured live (this module's "
                       "own first gate run): exit 0, not the root-"
                       "tier-protected 'cannot kill' this case first "
                       "assumed -- $$ is an ORDINARY process (see "
                       "this file's own KILL_CASES header comment on "
                       "the -9 finding that corrected this). PRC_KILL "
                       "(src/kernel/procspawn2.s) reads $$'s PCB, "
                       "finds a nonzero, non-root parent, and takes "
                       "the signo==0 probe branch: ':probed', OK, no "
                       "kill. No host process shares this pid space, "
                       "so this stays hand-authored -- to a value "
                       "confirmed by running it, not assumed.")),
    C('kill', '-0 on an out-of-range pid: no such process',
      'if pid is not an existing process, kill shall fail and no '
      'signal shall be sent',
      ['-0', '200'],
      hand=dict(stdout=[], rc=1,
                reason="PCB_COUNT is 48 (inc/mm.annex.equ) -- pid 200 "
                       "fails PRC_KILL's own range check before any "
                       "PCB read, ERR_SRCH ('no such process'). rc 1 "
                       "is what POSIX asks for ('>0 An error "
                       "occurred') and what the host's /bin/kill "
                       "answers for a missing pid (`kill -0 99999` -> "
                       "rc 1, 'No such process'; measured on Darwin "
                       "25.5). THIS ROW PINNED A DEFECT UNTIL KFIX 4: "
                       "kill.s counted only SUCCESSFUL pids toward "
                       "'had operands', so a run in which every pid "
                       "failed fell through to USAGE and exited 2 "
                       "with a usage line after the diagnostic. It "
                       "was a hand= row recording what the binary "
                       "did, not an oracle; it now records the "
                       "correct status. Still hand-authored: no host "
                       "process shares this pid space, and the "
                       "diagnostic goes to stderr.")),
    C('kill', 'no operands is a usage error',
      '>0 An error occurred.',
      [],
      hand=dict(stdout=[], rc=2,
                reason="kill.s's own :done: NPIDS==0 (no WELL-"
                       "FORMED pid operand: none was given, or every "
                       "one was malformed; a well-formed pid that "
                       "then FAILS counts since KFIX 4) is a usage "
                       "error, not a silent no-op -- 'kill -9' "
                       "alone hits the identical path (kill.s's own "
                       "comment: 'a usage error, not a nop'). exit 2 "
                       "is this tree's uniform usage-error "
                       "convention (comm.s/cmp.s/etc.), which "
                       "POSIX's generic '>0' permits.")),
    C('kill', '-l lists signal names',
      'Write all values of signal_name supported by the '
      'implementation, if no operand is given.',
      ['-l'],
      hand=dict(stdout=['HUP INT QUIT KILL TERM'], rc=0,
                reason="SHIPPED 2026-09-17: LISTSIGS (kill.s) prints "
                       "the same 5-name table MATCHSIG's -s now "
                       "accepts, signal-number order (HUP=1 INT=2 "
                       "QUIT=3 KILL=9 TERM=15), space-separated, one "
                       "line, exit 0. Real BSD kill -l lists 30+ "
                       "signals this kernel does not have, so this "
                       "stays hand-authored to maux's own reduced "
                       "set, not host-oracled.")),
    C('kill', '-s signal_name (by name)',
      'Specify the signal to send, using one of the symbolic names '
      'defined in the tables of the signal.h page.',
      ['-s', 'TERM', '200'],
      hand=dict(stdout=[], rc=1,
                reason="SHIPPED 2026-09-17: -s NAME runs through "
                       "MATCHSIG (kill.s), the same 5-name table "
                       "timeout.s's own -s uses (HUP/INT/QUIT/KILL/"
                       "TERM). Pid 200 fails PRC_KILL's range check "
                       "(ERR_SRCH) whichever real signal -s "
                       "resolved to, so the status is the failed-pid "
                       "status, 1 -- proving -s's NAME lookup "
                       "reached SC_KILL at all, not that pid 200 "
                       "exists. Pinned rc=2 until KFIX 4 (the "
                       "every-pid-failed run fell through to USAGE; "
                       "see the '-0 on an out-of-range pid' row). No "
                       "host process shares this pid space, so this "
                       "stays hand-authored.")),
]


# ======================================================================
# cut -- XCU cut.html. Every non-gap row is host-oracled: /usr/bin/cut
# (BSD, this Mac's oracle) already implements the POSIX list syntax and
# the -s/passthrough rule cut.s was built against (verified live before
# writing cut.s at all -- see src/bin/cut.s's own header). The two
# known_gap rows are places this host DIVERGES from the POSIX text
# maux follows instead (measured live, not assumed).
# ======================================================================
CUT_CASES = [
    C('cut', '-c selects a range of character positions',
      'first_number-last_number -- Characters or bytes from '
      'first_number to last_number in the line shall be selected.',
      ['-c', '1-3', '@F@'], files={'F': ['abcdef', '12']}),
    C('cut', "-c 'N-' selects to the end of the line",
      'first_number-  -- ... to the end of the line.',
      ['-c', '3-', '@F@'], files={'F': ['abcdef']}),
    C('cut', "-c '-M' defaults the low end to the first position",
      '-last_number -- ... from the first character/byte in the '
      'line to last_number.',
      ['-c', '-2', '@F@'], files={'F': ['abcdef']}),
    C('cut', 'the list may repeat and overlap; output stays in '
             'line order',
      'The elements of list can be repeated, can overlap, and can '
      'be specified in any order.',
      ['-c', '3,1,2', '@F@'], files={'F': ['abcdef']}),
    C('cut', '-b is the byte form of the same list syntax',
      '-b list -- The list following -b specifies byte positions.',
      ['-b', '1-3', '@F@'], files={'F': ['abcdef']}),
    C('cut', '-f default delimiter is <tab>',
      "-f list -- ... fields ... separated in the input by the "
      "delimiter character (see -d) ... The default ... is <tab>.",
      ['-f', '2', '@F@'], files={'F': ['a\tb\tc', '1\t2\t3']}),
    C('cut', '-d changes the field delimiter',
      "-d delim -- Use the character delim as the field delimiter "
      "character instead of the <tab> character.",
      ['-f', '1,3', '-d', ':', '@F@'], files={'F': ['root:x:0']}),
    C('cut', '-s suppresses a line with no delimiter',
      "-s -- Suppress lines with no delimiter characters.",
      ['-f', '2', '-s', '@F@'],
      files={'F': ['a\tb', 'nodelim', 'c\td']}),
    C('cut', 'without -s a delimiterless line passes through '
             'unchanged',
      'If -s is not specified, ... lines with no delimiter '
      'characters shall be written in their entirety.',
      ['-f', '2', '@F@'],
      files={'F': ['a\tb', 'nodelim', 'c\td']}),
    C('cut', 'missing file continues, exit>0',
      '>0 An error occurred.',
      ['-c', '1', '@F1@', '@NOSUCH@', '@F2@'],
      files={'F1': ['ab'], 'NOSUCH': None, 'F2': ['cd']}),
    C('cut', 'exactly one of -b/-c/-f is required: none is a '
             'usage error here',
      'A -b, -c, or -f option must be specified.',
      ['1-3', '@F@'], files={'F': ['abcdef']},
      hand=dict(stdout=[], rc=2,
                reason="cut.s's START refuses (usage, exit 2) "
                       "when HAVEMODE is never set -- this "
                       "project's uniform usage-error convention "
                       "(grep.s/head.s/etc.), which POSIX's "
                       "generic wording permits. This host's own "
                       "/usr/bin/cut also refuses a mode-less "
                       "invocation, but with its own usage banner "
                       "on exit 1, not 2 -- the STATUS differs, "
                       "so this stays hand-authored rather than "
                       "host-oracled.")),
    C('cut', 'a descending range is a usage error here',
      'If an element ... consist[s] of two numbers separated by a '
      'hyphen ... the first number ... shall be less than the '
      'second number.',
      ['-c', '5-2', '@F@'], files={'F': ['abcdef']},
      hand=dict(stdout=[], rc=2,
                reason="cutlist.s's CKORDER refuses a range whose "
                       "low end exceeds its high end (usage, exit "
                       "2) -- the POSIX text quoted above requires "
                       "first<second. This host's /usr/bin/cut is "
                       "MORE lenient: measured live, '-c 5-2' "
                       "exits 0 with an EMPTY selection rather "
                       "than an error, so this stays hand-"
                       "authored rather than host-oracled.")),
]



# ======================================================================
# xargs -- XCU xargs.html. Non-gap rows are host-oracled: this Mac's
# /usr/bin/xargs (BSD) already implements the split/quote rules and
# the -n batching maux's xargs.s was built against (verified live
# before writing xargs.s -- see src/bin/xargs.s's own header). Exit-
# status rows are hand-authored: BSD's own codes for an abnormal
# child (plain 1, "aborting") differ from the GNU-shaped 123/124/126/
# 127 maux implements (the task's own spec), so a status comparison
# against BSD would fail for the wrong reason. -x and -p are ALSO
# hand-authored (2026-09-14, were plain host-oracled rows): BSD and
# GNU coreutils disagree with each other on both (BSD requires -n/-s
# before accepting -x and falls open on a tty-less -p; GNU accepts a
# bare -x and fails a tty-less -p outright), so oracling either
# against whichever host runs the gate flips the row's outcome by
# platform -- see each case's own comment for the live-checked
# specifics.
# ======================================================================
XARGS_CASES = [
    C('xargs', 'default utility is echo, batching all of stdin',
      'utility ... shall be echo(1p) if utility is omitted.',
      [], stdin='IN', files={'IN': ['one two', 'three']}),
    C('xargs', '-n limits arguments per invocation',
      '-n number -- Invoke utility using as many standard input '
      'arguments as possible, up to number arguments maximum.',
      ['-n', '2'], stdin='IN',
      files={'IN': ['a b c d e']}),
    C('xargs', 'adjacent blanks collapse to one delimiter',
      'arguments in the standard input shall be delimited by ... '
      'unquoted <blank> characters.',
      ['-n', '1'], stdin='IN', files={'IN': ['a    b\tc']}),
    C('xargs', "single quotes group a blank into one argument",
      "single-quote characters ... escape all ... characters "
      "... up to the matching single-quote character.",
      ['-n', '1'], stdin='IN', files={'IN': ["'a b' c"]}),
    C('xargs', 'double quotes group a blank into one argument',
      'double-quote characters ... escape all ... characters '
      '... up to the matching double-quote character.',
      ['-n', '1'], stdin='IN', files={'IN': ['"a b" c']}),
    C('xargs', 'an unquoted backslash escapes one blank',
      'a <backslash> character ... shall escape any character.',
      ['-n', '1'], stdin='IN', files={'IN': ['a\\ b c']}),
    C('xargs', '-I substitutes replstr with one input line',
      '-I replstr -- ... construct the argument list(s) by '
      'replacing ... occurrences of replstr ...',
      ['-I', '{}', Q('[{}]')], stdin='IN',
      files={'IN': ['one', 'two']}),
    C('xargs', 'no stdin arguments: utility is not invoked',
      'If there are no ... arguments ... it is unspecified '
      'whether utility is executed', ['-n', '1'],
      stdin='IN', files={'IN': []},
      hand=dict(stdout=[], rc=0,
                reason='POSIX leaves the no-input case '
                       'unspecified; maux follows this very '
                       "host's own /usr/bin/xargs (checked live, "
                       '2026-09-14): zero invocations, exit 0 -- '
                       'not bare POSIX\'s "-r not given -> run '
                       'it once" reading.')),
    C('xargs', '-t traces the command line to stderr',
      '-t -- ... each command line ... written to the standard '
      'error ... prior to invocation.',
      ['-t', 'echo'], stdin='IN', files={'IN': ['a b']}),
    C('sh', 'xargs -t trace line has no trailing blank (stderr seen)',
      '-t -- ... each command line ... written to the standard '
      'error ... prior to invocation.',
      [], stdin='IN',
      files={'IN': ['XARGS -t -n1 /bin/ECHO < XI 2>&1'],
             'XI': ['a b']},
      hand=dict(stdout=['/bin/ECHO a', 'a', '/bin/ECHO b', 'b'],
                rc=0,
                reason='SH-DEFECTS 13. BSD (macOS) and GNU findutils '
                '4.9.0 xargs -t both print `/bin/echo a` + LF on '
                'stderr, no trailing blank (checked live '
                '2026-10-25). Stdout-only rows cannot see stderr, so '
                'the shell merges it with 2>&1; harness lines are '
                'not stripped, so a trailing blank fails the row.')),
    C('xargs', 'utility not found on PATH: exit 127',
      '127 -- ... utility could not be found.',
      ['@NOSUCHCMD@'], stdin='IN',
      files={'IN': ['a'], 'NOSUCHCMD': None},
      hand=dict(stdout=[], rc=127,
                reason="checked once, before any invocation, "
                       "against src/liba/pathres.s's PATHRSLV -- "
                       "this host's own xargs also reports 127 "
                       "for an unresolvable word, but with its "
                       "own diagnostic text, which this row does "
                       "not compare.")),

    # -- options this build does not implement (task's own scope:
    # -- only -n/-s/-t/-I). Each is a real GETOPT-unrecognised-
    # -- letter usage error on maux (exit 1) where this host's own
    # -- xargs implements the flag -- a real divergence, held red.
    # RETIRED 2026-10-08 (docs/POSIX-HARNESS.md). Was a KNOWN_GAP: "xargs.s's
    # XAOPTS is \"I:n:s:t\" -- no '0'. GETOPT reports it unrecognised,
    # usage to stderr, exit 1". The blocker was the harness: a fixture
    # was written as LINES, so a NUL-separated input could not be
    # expressed. A `files=` value that is `bytes` is now staged
    # verbatim on both sides (a2til writes it unchanged, no CR/high-bit
    # translation), and the row is host-oracled: BSD and GNU agree.
    C('xargs', '-0 items end at a NUL; blanks do not end them',
      '-0 -- ... arguments in the standard input are delimited '
      'only by null bytes.',
      ['-0', 'echo'], stdin='IN', files={'IN': b'a b\x00c d\x00'}),
    # SHIPPED 2026-09-21 at FILLPEND, the single choke point every
    # token passes through, with a latch so everything after the
    # eofstr is ignored rather than merely skipped.
    #
    # IT FOUND A LATENT BUG, which is the part worth keeping. Every
    # path through xargs used to read stdin to EOF, so BUFPOS/BUFLEN
    # were always drained at exit and a warm respawn inherited nothing
    # -- correct BY ACCIDENT. -E is the first way to stop early, and
    # a run that halted at the eofstr left the rest of its chunk in
    # CBUF for the next xargs to serve before reading its own fd.
    # Measured as "b a STOP b". The row below pins that.
    C('xargs', '-E stops reading at the eofstr',
      '-E eofstr  Use eofstr as the logical end-of-file string.',
      ['-E', 'STOP', 'echo'], stdin='IN',
      files={'IN': ['a', 'STOP', 'b']}),
    C('xargs', '-E with no match reads everything',
      '-E eofstr  Use eofstr as the logical end-of-file string.',
      ['-E', 'ZZZ', 'echo'], stdin='IN',
      files={'IN': ['a', 'STOP', 'b']}),
    # SHIPPED 2026-09-21. -L counts LINES where -n counts arguments,
    # so TOKREAD now records WHICH delimiter ended a token and
    # BUILD_BATCH advances a line count only on one that ended a line.
    # The check is AFTER taking the token, never before: POSIX's -L is
    # "at most number lines", and stopping before the token that
    # completes the last line would run a line short and leave the
    # rest for an extra invocation.
    C('xargs', '-L limits lines per invocation',
      '-L number  Call the utility ... for each non-empty number '
      'lines of arguments from standard input.',
      ['-L', '2', 'echo'], stdin='IN',
      files={'IN': ['a', 'b', 'c', 'd']}),
    # RETIRED 2026-10-08 (docs/POSIX-HARNESS.md). Was hand-authored
    # with known_gap: the host runs of -p without a tty were not a
    # stable oracle (BSD fell open and ran it; GNU failed outright
    # for want of /dev/tty), and the gate gave xargs no terminal a
    # human could answer. It is an INTERACTIVE row now: the program
    # runs under a pty on the host and on the maux console, the
    # prompt appears, an `n` is typed, and nothing runs. Measured on
    # BOTH hosts with a controlling terminal: the stream is identical
    # (`echo a?...n`), exit status 0 -- POSIX's own reading, "skip
    # the invocation on anything but an affirmative reply, and that
    # is not an error".
    IR('xargs', '-p (prompt mode) an n declines the invocation',
      '-p -- Prompt mode ... utility ... at each invocation.',
      ['-p', 'echo'],
      [WAIT('?...'), TYPE('n\r')],
      stdin='IN', files={'IN': ['a']}),
    # SHIPPED 2026-09-21 as an accepted flag, which is honesty rather
    # than a stub: xargs.s has never invoked the utility when stdin
    # supplied no arguments (see the "no stdin arguments" row above),
    # so -r asks for the standing behaviour. Refusing it made a script
    # that says -r for portability fail on a machine that already
    # does what -r wants.
    C('xargs', '-r is accepted (no-run-if-empty is the behaviour)',
      '-r  If there are no arguments, do not run the utility.',
      ['-r', 'echo'], stdin='EMPTY', files={'EMPTY': []}),
    # HAND-AUTHORED + KNOWN_GAPS2 (2026-09-14, was a plain host-
    # oracled row, believed host-independent): checked live on BOTH
    # families and they DISAGREE. BSD's own /usr/bin/xargs refuses a
    # bare -x with neither -n nor -s (synopsis: '-n number [-x]'),
    # usage, exit 1 -- which happens to LAND ON maux's own usage-
    # error exit 1 for the same input, since maux's XAOPTS has no
    # 'x' at all and GETOPT rejects it outright. That coincidence is
    # what made this look like a genuine cross-host row. GNU
    # coreutils xargs has no such -n/-s dependency: -x alone is
    # accepted and just forces the (already-default) exit-if-a-
    # single-oversized-line-won't-fit behaviour, so 'a' still runs
    # and prints "a", exit 0 -- on the box, maux's usage error would
    # NOT match that, correctly turning red for the RIGHT reason,
    # but relying on an oracle that flips behaviour by host is
    # exactly the fragility this fix removes. POSIX's own -x text
    # (quoted below) names no dependency on -n/-s either, so the
    # hand-authored expectation follows POSIX/GNU's reading over
    # BSD's extra restriction.
    # CLOSED 2026-09-21 BY MEASUREMENT, not by implementation, and
    # that is the whole story. This row claimed the host ACCEPTS -x
    # while maux refuses it. It does not: the host's own xargs, given
    # -x with neither -n nor -s, EXITS 1 AND PRINTS NOTHING, exactly
    # as maux already did.
    #
    # maux was briefly changed to ACCEPT the flag -- the condition -x
    # guards cannot arise here, since BUILD_BATCH stops at
    # EFFCNT/EFFSIZE and never constructs an over-large list -- and
    # that made it diverge MORE: 'a b' and rc 0 against the host's
    # empty output and rc 1. Reverted. The gap was never a gap; it
    # was a wrong note, and the differential suite said so the moment
    # a row was actually run against the oracle.
    C('xargs', '-x with no -n/-s is refused, as the host refuses it',
      '-x  Terminate if a constructed argument list will not fit.',
      ['-x', 'echo'], stdin='IN', files={'IN': ['a', 'b']}),
]


# ======================================================================
# printf -- XCU printf.html. Non-gap rows are host-oracled: this Mac's
# /usr/bin/printf already implements the escape/conversion rules
# printf.s was built against (verified live before writing it -- see
# src/bin/printf.s's own header). check_posixutil.py's oracle compares
# stdout + exit status ONLY (never stderr, per this module's own
# header), so the non-numeric-argument row needs no special handling
# here even though its diagnostic wording is not maux's -- that text
# never reaches the comparison at all.
#
# EVERY FORMAT OPERAND BELOW IS QQ()-WRAPPED (double quotes), not
# Q()'s single quotes -- a real sh bug found landing this section
# (2026-09-14, verified live on the emulator, not fixed here, out of
# scope for a printf task): a bare backslash inside SINGLE quotes is
# not fully literal on this sh (`'...\n...'` -> 'sh: unterminated
# quote'/'mixed quoting'); double quotes side-step it.
#
# NONE OF THESE ROWS END THE FORMAT IN \n (nor any octal stand-in for
# it), and that is deliberate, not an oversight: this suite's own
# maux_lines()/host_lines() (check_posixsed.py) split on DIFFERENT
# bytes -- maux_lines() on real CR ('\r', what printf's own \n maps
# to, $8D), host_lines() on real LF ('\n', what the host's \n maps
# to) -- exactly matching each side's own native convention when a
# genuine `\n` is used on both. \ddd is NOT a stand-in for that:
# \014 (octal, LF) and \015 (octal, CR) are both real but DIFFERENT
# bytes from what either side's own `\n` produces, so an octal
# substitute here (tried and reverted) desyncs the two splitters
# instead of avoiding the sh bug -- BSD's own \n reaches host_lines()
# correctly where the substitute did not, and check_e2e.py's own
# printf rows (a single byte-exact comparator, not a line splitter)
# is where \n's mapping is actually exercised end to end. These rows
# instead end each format with NO trailing escape at all -- both
# sides then produce one unterminated line, which both splitters
# handle identically (checked live: BSD `printf '%s' onlyone` ends
# with no LF either). \011 (tab) is unaffected -- neither splitter
# treats a tab as a boundary -- so it is used freely mid-format.
# ======================================================================
PRINTF_CASES = [
    C('printf', 'a plain %s conversion, reused across arguments',
      'the format operand shall be reused as often as necessary to '
      'satisfy the argument operands',
      [QQ(r'%s'), 'one', 'two', 'three']),
    C('printf', '%d/%x/%o with field widths and flags',
      '-, 0: the conversion specifications in the C language.',
      [QQ(r'%5d|%-5d|%05d|%x|%o'), '3', '3', '3', '255', '8']),
    C('printf', '%s precision truncates, width pads',
      'A field precision ... specifies the maximum number of '
      'characters to be written.',
      [QQ(r'%5.2s|%-5s|'), 'abcdef', 'ab']),
    C('printf', '%c prints only the first character',
      'c -- The first character of argument shall be printed.',
      [QQ(r'[%c]'), 'hello']),
    C('printf', '%c of an empty/missing argument prints nothing',
      'the corresponding argument ... shall be treated as ... the '
      'null string',
      [QQ(r'[%c]')],
      hand=dict(stdout=['[]'], rc=0,
                reason='The two hosts DISAGREE: BSD printf (this Mac) '
                       'prints nothing for %c of the null string, GNU '
                       'coreutils printf (the Linux box) emits a NUL '
                       'byte (it hands *argument, i.e. the terminating '
                       'zero, to the C library %c). The XCU text says '
                       'the first character of a null string -- there '
                       'is none -- so nothing is printed; the spec is '
                       'the oracle here, not whichever host runs the '
                       'sweep (first seen 2026-09-14, box sweep of '
                       '6eaba19, 299/300).')),
    C('printf', '%% is a literal percent, no argument consumed',
      "'%%' -- Print a '%' character.",
      [QQ(r'a%%b')]),
    C('printf', 'backslash escapes in the format: \\011 (tab)',
      "\\t' Write a <tab> character.",
      [QQ(r'a\011b\011c')]),
    C('printf', '\\ddd: 1-3 octal digits, no leading 0 needed',
      "'\\ddd' -- Write a byte whose value is the 1, 2, or 3-digit "
      'octal number ddd.',
      [QQ(r'A\101B')]),
    C('printf', '%b interprets its OWN backslash escapes',
      "b -- ... <backslash> characters shall be recognized and "
      "removed; any special meaning shall be applied.",
      [QQ(r'%b'), QQ(r'x\0101y')]),
    C('printf', "%b's \\c stops all remaining output",
      "'\\c' -- Ignore the remaining characters in the string "
      'operand containing it, any remaining string operands, and '
      'any additional characters in the format operand.',
      [QQ(r'%b'), QQ(r'x\c stays hidden')]),
    C('printf', 'format reused, missing arguments are empty/0',
      'if the format requires more arguments than there are '
      'argument operands ... the extra conversion specifications '
      '... behave as if ... a null string argument.',
      [QQ(r'%s-%d'), 'onlyone']),
    C('printf', 'a non-numeric numeric argument: diagnosed, 0 used',
      'If the argument cannot be entirely converted into an '
      'internal value ... a diagnostic message shall be written ... '
      'and the utility shall not exit with a zero exit status',
      [QQ(r'%d'), 'abc'],
      hand=dict(stdout=['0'], rc=1,
                reason="check_posixutil's oracle never captures "
                       'stderr (module header), so the diagnostic '
                       "wording -- not maux's -- never enters the "
                       'comparison; only stdout ("0") and the exit '
                       'status (1) are checked, both verified live '
                       "against this host's own /usr/bin/printf.")),
    C('printf', "a leading quote argument takes the char's value",
      "If the leading character is a single-quote or double-quote, "
      'the value shall be the numeric value in the underlying '
      'codeset of the character following the single-quote or '
      'double-quote.',
      # the DOUBLE-quote spelling ("A), not a single quote -- a
      # literal single quote can't survive Q()'s own single-quote
      # wrap (it would close the quoted word early) and printf
      # accepts either leading-quote form identically. No backslash
      # in this operand, so Q() (unaffected by either sh bug) is the
      # right wrap.
      [QQ(r'%d'), Q('"A')]),
    C('printf', 'no format operand at all is a usage error',
      'printf format [argument...]',
      [],
      hand=dict(stdout=[], rc=1,
                reason='POSIX gives no exit status for this case; '
                       "maux's own usage message goes to stderr "
                       '(not compared here) and it exits 1, the '
                       "same posture every other util's usage error "
                       'takes in this suite.')),
    # -- floating point: no such conversions exist on a machine with
    # -- no floating point (src/bin/printf.s's own header) --
    # -- KNOWN_GAPS2 rows, not a gate on behaviour that cannot exist.
    C('printf', '%e is unimplemented (no floating point)',
      'e, E -- ... the argument shall be written in the style '
      '[-]d.ddde+-dd.',
      [QQ(r'%e'), '1.5'],
      known_gap='This machine has no floating point (src/bin/'
                'printf.s\'s own header); %e falls through to the '
                'unknown-conversion diagnostic + BADNUM, unlike a '
                'host printf which formats a real float.'),
    C('printf', '%f is unimplemented (no floating point)',
      'f, F -- ... the argument shall be written in ... decimal '
      'notation.',
      [QQ(r'%f'), '1.5'],
      known_gap='Same reason as %e -- no floating point on this '
                'machine.'),
    C('printf', '%g is unimplemented (no floating point)',
      'g, G -- ... the argument shall be written in style e/E or '
      'f/F.',
      [QQ(r'%g'), '1.5'],
      known_gap='Same reason as %e -- no floating point on this '
                'machine.'),
    C('printf', '%a is unimplemented (no floating point)',
      'a, A -- ... the argument shall be written in ... hexadecimal '
      'notation.',
      [QQ(r'%a'), '1.5'],
      known_gap='Same reason as %e -- no floating point on this '
                'machine.'),
]


# ======================================================================
# basename -- XCU basename.html. Pure text arithmetic (no MLI call of
# any kind), so every row is host-oracled exactly against this
# machine's own /usr/bin/basename (verified live before writing
# src/bin/basename.s -- see its own header).
# ======================================================================
BASENAME_CASES = [
    C('basename', 'no slash at all: the string is its own basename',
      'the last pathname component of a name with no slash is the '
      'name itself',
      ['sort']),
    C('basename', 'trailing slashes are stripped first',
      'the trailing <slash> characters in the string shall be '
      'removed',
      ['/usr/bin/sort///']),
    C('basename', 'a matching suffix is removed',
      'if the suffix operand is present ... and is not identical '
      'to the characters remaining in string ... the suffix ... '
      'shall be removed',
      ['/src/prog.c', '.c']),
    C('basename', 'a suffix identical to the whole base is not '
      'removed',
      'suffix ... is not identical to the characters remaining in '
      'string',
      ['prog.c', 'prog.c']),
    C('basename', 'a suffix at least as long as the base is not '
      'removed',
      'the suffix ... shall be removed',
      ['foo', '.txtlong']),
    C('basename', 'a string of nothing but slashes is "/"',
      "if string is '//', it is implementation-defined whether "
      "steps 2 to 5 are skipped or... string is set to '/'",
      ['///']),
    # -- the empty-string row ("if string is a null string...") is
    # -- NOT staged here: it needs a literal zero-length shell
    # -- argument (`''`), and whether this sh's own line reader
    # -- preserves an empty quoted word at all is untested/unknown
    # -- (out of scope to establish for this task) -- a wrong guess
    # -- risks a HANG on the interactive console, not just a wrong
    # -- answer. Covered instead by code inspection only: START's
    # -- own `bne :nonempty / jmp :printnl` branch on BN_LEN == 0.
]


# ======================================================================
# dirname -- XCU dirname.html. Same posture as basename: pure text
# arithmetic, host-oracled against /usr/bin/dirname.
# ======================================================================
DIRNAME_CASES = [
    C('dirname', 'no slash at all: "."',
      'if string does not contain a slash ... dirname shall write '
      'the string "." ',
      ['sort']),
    C('dirname', 'trailing slashes stripped before the last '
      'component is removed',
      'if string consists of ... trailing slashes, [remove them] '
      'before proceeding',
      ['/usr/bin/']),
    C('dirname', 'plain: everything but the last component',
      'the pathname of the parent directory of that file. Trailing '
      "<slash> characters ... shall be removed",
      ['/usr/bin/sort']),
    C('dirname', 'nested: strips exactly one component',
      'the string shall be modified by removing ... trailing '
      "<slash> characters and ... the last component",
      ['/a/b/c/d']),
    C('dirname', 'a string of nothing but slashes is "/"',
      "if string is composed entirely of <slash> characters ... "
      "dirname shall write '/' ",
      ['///']),
]


# ======================================================================
# env -- XCU env.html. -i pins a DETERMINISTIC environment: this
# host's own environment and maux's are otherwise nothing alike, so
# only the -i-based rows are host-oracled here (checked live: `env
# -i` prints nothing on this Mac, the one shape both machines can
# agree on exactly). The spawned utility is the bare lowercase word
# "echo"/"false" -- PATH-resolved by each side's own execvp, the
# same precedent XARGS_CASES's own default-utility row already
# relies on (src/liba/pathtab.s's "/bin/:/mnt/MAUX/" default).
# ======================================================================
ENV_CASES = [
    C('env', '-i with no operands: an empty environment, printed',
      '-i ... Invoke utility (or write to standard output the '
      'resulting environment) with exactly the environment '
      'specified by the arguments',
      ['-i']),
    C('env', 'a name=value operand, no utility: printed',
      "arguments of the form name=value ... shall be added to the "
      "environment",
      ['-i', 'FOO=BAR']),
    C('env', 'a utility is resolved and spawned',
      'the environment for utility shall be the current '
      'environment ... utility shall be invoked',
      ['-i', 'echo', 'HELLO']),
    C('env', 'a name=value operand is merged before the spawn',
      'options and any arguments to those options ... [then] '
      'arguments of the form name=value ... modify the environment',
      ['-i', 'FOO=BAR', 'echo', 'HELLO']),
    # -- REVIEW ADDITIONS (2026-09-14): the four rows above never
    # -- prove the CHILD receives the merged environment (echo does
    # -- not read its own). env itself is the one utility on both
    # -- machines that prints exactly what it was handed, so it is
    # -- the child here -- `env -i FOO=BAR env` is deterministic on
    # -- both sides (checked live on this host: prints FOO=BAR).
    C('env', 'the spawned utility SEES the merged environment',
      'the environment for utility shall be the current '
      'environment ... modified by the name=value arguments',
      ['-i', 'FOO=BAR', 'env']),
    C('env', 'a duplicate name=value: only the LAST survives',
      'arguments of the form name=value shall be added to the '
      'environment ... [each] shall replace any existing '
      'variable of that name',
      ['-i', 'A=1', 'A=2', 'env']),
    C('env', "exit status is the utility's own",
      'Otherwise, the exit status of env shall be the exit status '
      'of utility',
      ['-i', 'false'],
      hand=dict(stdout=[], rc=1,
                reason="false's own exit status (1) passed through "
                       'unchanged -- checked live against this '
                       "host's own /usr/bin/env, which agrees.")),
    C('env', 'utility not found on PATH: exit 127',
      '127 if utility could not be invoked. Some other value if '
      "utility was invoked but failed",
      ['-i', 'nonexistentcmd12345'],
      hand=dict(stdout=[], rc=127,
                reason='diagnostic wording is not compared here '
                       '(check_posixutil never captures stderr, '
                       "same posture as PRINTF_CASES's own "
                       'numeric-error row); only the exit status '
                       "(127) is checked, matched to this host's "
                       'own /usr/bin/env, which agrees.')),
]


# ======================================================================
# uuencode/uudecode -- XCU uuencode.html/uudecode.html. EVERY row is
# hand-computed, like OD_CASES above and for the same underlying
# reason: the tool's answer depends on the exact BYTES staged for it,
# and this harness's own text-fixture path (hilines(): high-bit ASCII,
# CR $8D per line) does not produce the same on-disk bytes as a host
# reference file would (LF, no high bit) -- host-oracling either tool
# here would compare two different inputs, the same trap OD_REASON
# documents and check_byte_stable's BYTE_VALUED guards against in
# e2e_corpus.py (where the real host-oracled proof lives, on 'raw'
# byte-identical fixtures: FBIN's full 0-255 range, plus the 45/57-byte
# chunk-boundary fixtures). _uu_hist()/_uu_b64() mirror src/bin/
# uuencode.s's SPLIT3/ENCODE6/B64TAB and src/bin/uudecdec.s's DECODE6/
# B64DEC exactly, from the algorithm's own definition (32+group, 0 ->
# backquote; RFC 4648 base64 with '=' padding on the final group only)
# -- not a copy of the implementation under test.
# ======================================================================
def _uu_enc6(v):
    if v == 0:
        return 0x60           # backquote -- see src/bin/uuencode.s
    return 0x20 + v


_UU_B64ALPHA = ('ABCDEFGHIJKLMNOPQRSTUVWXYZ'
                'abcdefghijklmnopqrstuvwxyz'
                '0123456789+/')


def _uu_hist(raw):
    """historical algorithm -> list of PLAIN text lines (this build's
    own high bit stripped, same convention maux_lines() recovers)."""
    lines = []
    i = 0
    n = len(raw)
    while i < n:
        chunk = raw[i:i + 45]
        m = len(chunk)
        chars = [chr(_uu_enc6(m))]
        j = 0
        while j < m:
            b0 = chunk[j]
            b1 = chunk[j + 1] if j + 1 < m else 0
            b2 = chunk[j + 2] if j + 2 < m else 0
            chars.append(chr(_uu_enc6(b0 >> 2)))
            chars.append(chr(_uu_enc6(((b0 & 3) << 4) | (b1 >> 4))))
            chars.append(chr(_uu_enc6(((b1 & 0x0F) << 2) | (b2 >> 6))))
            chars.append(chr(_uu_enc6(b2 & 0x3F)))
            j += 3
        lines.append(''.join(chars))
        i += 45
    lines.append(chr(_uu_enc6(0)))
    lines.append('end')
    return lines


def _uu_b64(raw):
    """base64 algorithm -> list of PLAIN text lines, '=' padding on
    the final group of the final (possibly short) line only."""
    lines = []
    i = 0
    n = len(raw)
    while i < n:
        chunk = raw[i:i + 57]
        m = len(chunk)
        chars = []
        j = 0
        while j < m:
            remain = m - j
            b0 = chunk[j]
            b1 = chunk[j + 1] if remain >= 2 else 0
            b2 = chunk[j + 2] if remain >= 3 else 0
            v0 = b0 >> 2
            v1 = ((b0 & 3) << 4) | (b1 >> 4)
            v2 = ((b1 & 0x0F) << 2) | (b2 >> 6)
            v3 = b2 & 0x3F
            chars.append(_UU_B64ALPHA[v0])
            chars.append(_UU_B64ALPHA[v1])
            chars.append(_UU_B64ALPHA[v2] if remain >= 2 else '=')
            chars.append(_UU_B64ALPHA[v3] if remain >= 3 else '=')
            j += 3
        lines.append(''.join(chars))
        i += 57
    lines.append('====')
    return lines


def _uu_hdr(b64, name, mode='644'):
    kind = 'begin-base64' if b64 else 'begin'
    return f'{kind} {mode} {name}'


UU_REASON = ("hand-computed from the EXACT bytes this harness stages "
             "(_hi_bytes()) via _uu_hist()/_uu_b64() above, mirroring "
             "src/bin/uuencode.s/uudecdec.s from the algorithm's own "
             "definition -- not a host capture (see this section's "
             "own header for why a host oracle would compare two "
             "different files here).")

# raw bytes for a 1-line stdin fixture ['A']: hi('A') + CR -> 2 bytes,
# whose FINAL historical group pads one zero byte (a real backquote,
# not a length-code one) and whose base64 encoding needs ONE '='.
UU_RAW_A = _hi_bytes(['A'])
# raw bytes for a 1-line stdin fixture ['']: just one CR -> 1 byte,
# whose base64 encoding needs TWO '=' (the "==" case).
UU_RAW_EMPTY = _hi_bytes([''])

UUENCODE_CASES = [
    C('uuencode', 'header line: "begin MODE NAME"',
      'uuencode -- Purpose: ... writes ... "begin" line',
      ['A.TXT'], stdin='IN', files={'IN': ['A']},
      hand=dict(stdout=[_uu_hdr(False, 'A.TXT')] + _uu_hist(UU_RAW_A),
                rc=0, reason=UU_REASON)),
    C('uuencode', '-m header line: "begin-base64 MODE NAME"',
      '-m ... uuencode shall use the base64 encoding scheme',
      ['-m', 'A.TXT'], stdin='IN', files={'IN': ['A']},
      hand=dict(stdout=[_uu_hdr(True, 'A.TXT')] + _uu_b64(UU_RAW_A),
                rc=0, reason=UU_REASON)),
    C('uuencode', 'length character is 32 plus the byte count',
      'a length character... representing the number of bytes',
      ['A.TXT'], stdin='IN', files={'IN': ['A']},
      hand=dict(stdout=[_uu_hdr(False, 'A.TXT')] + _uu_hist(UU_RAW_A),
                rc=0, reason=UU_REASON + ' Row cites the length '
                     f'character specifically: {chr(_uu_enc6(2))!r} '
                     '(32+2, this fixture\'s 2 real bytes).')),
    C('uuencode', 'a zero 6-bit group encodes as a backquote',
      "a group of 6 bits... converted... except that a resulting "
      "character of ... a space is replaced by a backquote",
      ['A.TXT'], stdin='IN', files={'IN': ['A']},
      hand=dict(stdout=[_uu_hdr(False, 'A.TXT')] + _uu_hist(UU_RAW_A),
                rc=0, reason=UU_REASON + ' Row cites the final char '
                     'of the data line, from this fixture\'s own '
                     'padding byte (a REAL zero group, not the '
                     'length character): a backquote.')),
    C('uuencode', 'trailer: a zero-length line, then "end"',
      'a final line... indicating zero characters... followed by a '
      'line containing "end"',
      ['A.TXT'], stdin='IN', files={'IN': ['A']},
      hand=dict(stdout=[_uu_hdr(False, 'A.TXT')] + _uu_hist(UU_RAW_A),
                rc=0, reason=UU_REASON)),
    C('uuencode', '-m trailer: a line of four "=" characters',
      "-m ... the trailer... '===='",
      ['-m', 'A.TXT'], stdin='IN', files={'IN': ['A']},
      hand=dict(stdout=[_uu_hdr(True, 'A.TXT')] + _uu_b64(UU_RAW_A),
                rc=0, reason=UU_REASON)),
    C('uuencode', '-m padding: one "=" when one byte is short',
      'the last... group... is padded... with one or two "="',
      ['-m', 'A.TXT'], stdin='IN', files={'IN': ['A']},
      hand=dict(stdout=[_uu_hdr(True, 'A.TXT')] + _uu_b64(UU_RAW_A),
                rc=0, reason=UU_REASON + ' UU_RAW_A is 2 bytes -- one '
                     'short of a full 3-byte group -- so the base64 '
                     'group needs exactly one "=".')),
    C('uuencode', '-m padding: two "=" when two bytes are short',
      'the last... group... is padded... with one or two "="',
      ['-m', 'E.TXT'], stdin='IN', files={'IN': ['']},
      hand=dict(stdout=[_uu_hdr(True, 'E.TXT')] + _uu_b64(UU_RAW_EMPTY),
                rc=0, reason=UU_REASON + ' UU_RAW_EMPTY is 1 byte -- '
                     'two short of a full group -- so the base64 '
                     'group needs "==".')),
    C('uuencode', 'usage error: no decode_pathname operand',
      '>1 ...an error message',
      [], stdin='IN', files={'IN': ['A']},
      hand=dict(stdout=[], rc=2,
                reason='diagnostic wording is not compared here '
                       '(check_posixutil never captures stderr, '
                       "same posture as ENV_CASES's own numeric-"
                       'error rows); only the exit status (2, this '
                       "build's own usage convention) is checked.")),
]


# For UUDECODE_CASES: the ENCODED FILE IS the input operand, so its
# lines are STAGED AS TEXT (this harness's hilines() -> high-bit ASCII,
# CR per line) -- exactly the maux text convention uudecode's own
# GETLINE is built to read (docs/man/uudecode.1: it also reads plain
# 7-bit input, unreachable from THIS harness, which only ever stages
# maux text -- proven instead by e2e_corpus.py's FUUHIENC(M), staged
# as a HOST-form 'text' fixture with LF line ends).
UU_ENC_A = _uu_hist(UU_RAW_A)          # ['"P8T`', '`', 'end']
UU_ENC_A_HDR = [_uu_hdr(False, 'OUT.BIN')] + UU_ENC_A
UU_ENC_A_B64 = [_uu_hdr(True, 'OUT.BIN')] + _uu_b64(UU_RAW_A)
# UU_RAW_A decodes back to the literal bytes hi('A')+CR -- maux_lines()
# strips the high bit and splits on CR, recovering ['A'] exactly.
UU_DEC_A = ['A']

UUDECODE_CASES = [
    C('uudecode', 'decodes the historical alphabet, writes the '
      "header's own pathname",
      'uudecode... shall recreate the original... file',
      ['@ENC@'], files={'ENC': UU_ENC_A_HDR, 'OUT.BIN': None},
      results=['OUT.BIN'],
      hand=dict(stdout=[], rc=0, files={'OUT.BIN': UU_DEC_A},
                reason=UU_REASON)),
    C('uudecode', 'decodes the base64 alphabet',
      '-m ... uudecode shall recognize... base64',
      ['@ENC@'], files={'ENC': UU_ENC_A_B64, 'OUT.BIN': None},
      results=['OUT.BIN'],
      hand=dict(stdout=[], rc=0, files={'OUT.BIN': UU_DEC_A},
                reason=UU_REASON)),
    C('uudecode', '-o names an explicit output file',
      '-o outfile Specify the output file',
      ['-o', '@ALT@', '@ENC@'],
      files={'ENC': UU_ENC_A_HDR, 'ALT': None}, results=['ALT'],
      hand=dict(stdout=[], rc=0, files={'ALT': UU_DEC_A},
                reason=UU_REASON)),
    C('uudecode', '-o /dev/stdout writes to standard output',
      "outfile of '-' ... /dev/stdout... standard output",
      ['-o', '/dev/stdout', '@ENC@'], files={'ENC': UU_ENC_A_HDR},
      hand=dict(stdout=UU_DEC_A, rc=0, reason=UU_REASON)),
    C('uudecode', 'reads stdin when no file operand is given',
      'If no file operand is given... uudecode shall use standard '
      'input',
      ['-o', '/dev/stdout'], stdin='ENC', files={'ENC': UU_ENC_A_HDR},
      hand=dict(stdout=UU_DEC_A, rc=0, reason=UU_REASON)),
    C('uudecode', 'no "begin" line: exit 1, no output file',
      '>0 ...an error occurred',
      ['@BAD@'], files={'BAD': ['this is not a uuencoded file',
                                 'no begin line anywhere in it']},
      hand=dict(stdout=[], rc=1,
                reason='diagnostic wording is not compared here '
                       '(check_posixutil never captures stderr); '
                       'only the exit status (1) is checked -- '
                       'src/bin/uudecode.s: "missing or bad '
                       '\\"begin\\" line".')),
    C('uudecode', 'malformed body (bad length character): exit 1',
      '>0 ...an error occurred',
      ['@BAD@'],
      files={'BAD': [_uu_hdr(False, 'X'), '~bogus', 'end']},
      hand=dict(stdout=[], rc=1,
                reason='diagnostic wording is not compared here; '
                       'only the exit status (1) is checked -- '
                       "'~' ($7E) is outside DECODE6's valid $20-$60 "
                       'range, src/bin/uudecdec.s.')),
    C('uudecode', 'malformed body (bad base64 character): exit 1',
      '>0 ...an error occurred',
      ['@BAD@'],
      files={'BAD': [_uu_hdr(True, 'X'), '!!!!', '====']},
      hand=dict(stdout=[], rc=1,
                reason='diagnostic wording is not compared here; '
                       'only the exit status (1) is checked -- '
                       "'!' is outside the base64 alphabet, src/bin/"
                       'uudecdec.s B64DEC.')),
    C('uudecode', 'missing trailer (EOF): exit 1 ("short file")',
      '>0 ...an error occurred',
      ['@BAD@'], files={'BAD': UU_ENC_A_HDR[:-1]},
      hand=dict(stdout=[], rc=1,
                reason='diagnostic wording is not compared here; '
                       "only the exit status (1) is checked -- "
                       "matched live against this host's own "
                       '/usr/bin/uudecode, which also refuses a '
                       'body with no trailer ("short file"), see '
                       'src/bin/uudecode.s\'s own header.')),
    C('uudecode', 'wrong trailer TEXT (not missing): exit 1',
      '>0 ...an error occurred',
      ['@BAD@'],
      files={'BAD': UU_ENC_A_HDR[:-1] + ['nope']},
      hand=dict(stdout=[], rc=1,
                reason='diagnostic wording is not compared here; '
                       'only the exit status (1) is checked -- a '
                       'distinct code path from the EOF row above: '
                       'GETLINE finds a line here (carry clear), '
                       'so this exercises STRCMP against '
                       "TRLENDLO/\"end\" itself, not GETLINE's own "
                       'short-file detection. Matched live against '
                       "this host's own /usr/bin/uudecode.")),
]


# ======================================================================
# rmdir -- XCU rmdir.html (POSIX.1-2024 text, fetched live 2026-09-14).
# rmdir(2) has no ProDOS analogue -- MLI DESTROY does the whole job
# (street-library learning:01M0T0YSPMJE238VH46CZPDR2V, the same call
# rm.s's own un-`-r` path already rests on) -- so almost every row
# host-oracles cleanly, EXIT CODE INCLUDED: measured live against
# this host's own /bin/rmdir, a non-empty directory, a missing one,
# and a -p chain that unwinds into a non-empty ancestor ALL exit 1 on
# BOTH sides (rmdir.s's own ERRFLAG->EXIT is 1 on any failure), so
# only the argument-COUNT usage error (house convention 2, BSD's own
# banner exits 1) and the "prove the whole -p chain is really gone"
# side effect need `hand=`.
# ======================================================================
RMDIR_CASES = [
    C('rmdir', 'removes an empty directory, exit 0',
      'The rmdir utility shall remove the directory entry specified '
      'by each dir operand.',
      ['@D@'], dirs={'D': 'D'}, predirs=['D']),
    C('rmdir', 'a non-empty directory is an error',
      '>0 An error occurred.',
      ['@D@'], dirs={'D': 'D'}, predirs=['D'], files={'D/F': ['x']}),
    C('rmdir', 'a missing directory is an error',
      '>0 An error occurred.',
      ['@NOSUCH@'], files={'NOSUCH': None}),
    C('rmdir', '-p removes every pathname component in turn',
      '-p ... effects equivalent to the following command shall '
      'occur: rmdir -p $(dirname dir)',
      ['-p', '@D@'], dirs={'D': 'A/B/C'}, predirs=['D']),
    C('rmdir', '-p side effect: the WHOLE chain is gone, not just '
      'the leaf',
      '-p ... effects equivalent to the following command shall '
      'occur: rmdir -p $(dirname dir)',
      ['-p', '@D@'], dirs={'D': 'A/B/C'}, predirs=['D'],
      files={'PROBE': None},
      post=[['MKDIR', 'A'], ['echo', '$?', '>', '@PROBE@']],
      results=['PROBE'],
      hand=dict(stdout=[], rc=0, files={'PROBE': ['0']},
                reason="side effect verified via a follow-up MKDIR "
                       "in the SAME shell session (mkdir.s's own "
                       "'-p creates missing intermediate components' "
                       "precedent, module header's own reasoning) -- "
                       "there is no tool stdout to diff a filesystem "
                       "side effect against; if 'A' really is gone "
                       "all the way up, a plain MKDIR A (no -p) "
                       "recreates it successfully (exit 0); if the "
                       "walk stopped early, MKDIR A fails (A still "
                       "exists), exit >0.")),
    # measured live against this host's own rmdir -p: C and B are
    # removed, A is refused ("Directory not empty", KEEP lives in
    # it) and the WHOLE UTILITY exits 1 for that -- BSD's own
    # "stopping at the first non-empty directory" example is still
    # an ERROR exit, not a silent partial success, so this is a
    # plain host-oracled row, exit code included.
    C('rmdir', '-p stops at the first non-empty ancestor',
      '-p ... effects equivalent to the following command shall '
      'occur: rmdir -p $(dirname dir)',
      ['-p', '@D@'], dirs={'D': 'A/B/C'}, predirs=['D'],
      files={'A/KEEP': ['x']}),
    C('rmdir', 'no operand is a usage error',
      '>0 An error occurred.',
      [],
      hand=dict(stdout=[], rc=2,
                reason="rmdir.s's own :usage path, mkdir.s's "
                       "identical shape -- exit 2 is this tree's "
                       "uniform usage-error convention, which "
                       "POSIX's generic '>0' permits. This host's "
                       "own rmdir with no operand prints its own "
                       "usage banner and exits 1 -- a different but "
                       "also nonzero exit, not host-oracled because "
                       "of that mismatch.")),
    # a failed OPERAND does not stop the REMAINING ones -- mkdir.s's/
    # rm.s's/cat.s's own "skip and continue" shape. stdout/rc alone
    # cannot tell "continued and removed D" from "stopped after
    # NOSUCH" (both are empty stdout, exit 1), so this is `hand=`
    # with a `post` side-effect proof, mkdir -p's own precedent:
    # measured live against this host's own rmdir, `rmdir NOSUCH D`
    # (D real and empty) removes D too, exit 1, one diagnostic.
    C('rmdir', "a failed operand does not stop the remaining ones",
      'rmdir shall remove the directory entry specified by each dir '
      'operand',
      ['@NOSUCH@', '@D@'], dirs={'D': 'D'}, predirs=['D'],
      files={'NOSUCH': None, 'PROBE': None},
      post=[['MKDIR', 'D'], ['echo', '$?', '>', '@PROBE@']],
      results=['PROBE'],
      hand=dict(stdout=[], rc=1, files={'PROBE': ['0']},
                reason="side effect verified via a follow-up MKDIR "
                       "in the same session -- if D really was "
                       "removed despite NOSUCH's earlier failure, a "
                       "plain MKDIR D (no -p) recreates it "
                       "successfully (exit 0); if the loop stopped "
                       "at the first failure, D still exists and "
                       "MKDIR D fails, exit >0. Overall exit 1 "
                       "either way (NOSUCH alone already fails the "
                       "run), which is why stdout/rc cannot "
                       "distinguish the two paths on their own.")),
]


# ======================================================================
# tty -- XCU tty.html (POSIX.1-2024 text, fetched live 2026-09-14 --
# the obsolescent -s option was REMOVED from the current spec, so
# tty.s ships none; see its own header). Only the STDOUT "not a tty"
# row host-oracles: this harness types every command AT THE
# INTERACTIVE PROMPT unless `stdin=` names a staged file, so a case
# with no stdin= runs with fd 0 = the REAL console on the maux side
# while the host side ALWAYS gets a Python-subprocess PIPE
# (check_posixutil.py's own _host_once: "ALWAYS give the child a
# concrete stdin") -- the exact "cannot host-oracle, different
# values" split the task brief itself names for this tool.
# ======================================================================
TTY_CASES = [
    C('tty', 'not a tty: redirected stdin',
      'Otherwise, a message shall be written indicating that '
      'standard input is not connected to a terminal ... the tty '
      'utility shall use the format: "not a tty\\n"',
      [], files={'IN': ['x']}, stdin='IN'),
    # an operand: the SYNOPSIS has none, and the two hosts disagree
    # -- BSD (this Mac) ignores it and answers fd 0 anyway, GNU
    # coreutils (the Linux box) refuses it ('extra operand', exit
    # 2). The first box sweep (2026-09-14) turned a row written
    # against BSD's leniency red against GNU, so this is spec-
    # authored: no operands means an operand is a usage error, the
    # tree's own rule for every no-operand utility (uname's row
    # below takes the same posture), exit 2.
    C('tty', 'an operand is a usage error',
      'SYNOPSIS -- tty (no OPERANDS)',
      ['extra'], files={'IN': ['x']}, stdin='IN',
      hand=dict(stdout=[], rc=2,
                reason='no host is the oracle here: BSD tty ignores '
                       'an operand (exit 1 for the non-tty stdin), '
                       'GNU tty refuses it with exit 2; the XCU '
                       'SYNOPSIS lists no operands, and this tree '
                       'refuses one uniformly (tty.s, uname.s).')),
    C('tty', 'prints the controlling terminal name',
      '"%s\\n", <terminal name>',
      [],
      hand=dict(stdout=['/dev/tty1'], rc=0,
                reason="fd 0 here is the LIVE interactive console "
                       "this harness types at (no stdin= on this "
                       "case, nothing redirects it) -- the host "
                       "oracle always gets a piped, non-tty stdin "
                       "instead (check_posixutil.py's own "
                       "_host_once), so the two engines cannot "
                       "possibly agree on a NAME even though both "
                       "implement isatty correctly. Expected value "
                       "is this suite's own boot-time assumption "
                       "(the interactive session lands on console "
                       "1, FD_TTY0 -> /dev/tty1 per procfile5.s's "
                       "PDEV_TAB) rather than a captured host run --"
                       " if this is wrong the diff names the real "
                       "value.")),
]


# ======================================================================
# uname -- XCU uname.html (POSIX.1-2024 text, fetched live
# 2026-09-14). EVERY row is hand-authored: sysname/nodename/release/
# version/machine are maux-specific strings with no host equivalent
# (this Mac answers "Darwin"/its own hostname/kernel build, never
# "maux"/"apple2e"/"1.0"). The FIXED PRINT ORDER (sysname nodename
# release version machine, regardless of which order the flags were
# given) is verified live against this host's own /usr/bin/uname:
# `uname -s -m` and `uname -m -s` both print "Darwin arm64", never
# "arm64 Darwin" -- confirming the TRADITIONAL field order (not the
# SYNOPSIS's own -amnrsv LETTER order, which the XCU text's cross-
# reference is easy to misread as the print order) is what every
# real implementation, and this one, uses.
# ======================================================================
UNAME_CASES = [
    C('uname', 'no options: sysname only',
      'If no options are specified, uname shall behave as though '
      'the -s option had been specified.',
      [],
      hand=dict(stdout=['maux'], rc=0,
                reason="maux-specific value; the SHAPE (no-args = "
                       "sysname alone) matches this host's own "
                       "uname exactly, only the STRING differs "
                       "('maux' vs 'Darwin'). See module header.")),
    C('uname', '-s writes the operating system name',
      'Write the name of the implementation of the operating '
      'system.',
      ['-s'],
      hand=dict(stdout=['maux'], rc=0,
                reason="maux-specific value; see module header.")),
    C('uname', '-n writes the node name',
      'Write the name of this node within an implementation-'
      'defined communications network.',
      ['-n'],
      hand=dict(stdout=['apple2e'], rc=0,
                reason="maux has no hostname/network concept -- "
                       "uname.s's own header: a constant naming the "
                       "machine class stands in, not an invented "
                       "network name. See module header.")),
    C('uname', '-r writes the release level',
      'Write the current release level of the operating system '
      'implementation.',
      ['-r'],
      hand=dict(stdout=['1.0'], rc=0,
                reason="no kernel version equate exists anywhere in "
                       "inc/ or src/kernel/ (grepped) -- a "
                       "git-less placeholder constant, uname.s's "
                       "own header says so plainly.")),
    C('uname', '-v writes the version level',
      'Write the current version level of this release of the '
      'operating system implementation.',
      ['-v'],
      hand=dict(stdout=['1.0'], rc=0,
                reason="same reasoning as -r -- see module "
                       "header.")),
    C('uname', '-m writes the hardware type',
      'Write the name of the hardware type on which the system is '
      'running.',
      ['-m'],
      hand=dict(stdout=['65c02'], rc=0,
                reason="the CPU maux requires (`xc` throughout the "
                       "tree, e.g. `stz`/`bra`), not the plain 6502 "
                       "this image cannot run on.")),
    C('uname', '-a selects all five fields, fixed order',
      'Behave as though all of the options -mnrsv were specified.',
      ['-a'],
      hand=dict(stdout=['maux apple2e 1.0 1.0 65c02'], rc=0,
                reason="sysname nodename release version machine, "
                       "space-separated on one line -- the "
                       "traditional order, measured against this "
                       "host's own `uname -a` (same five-field "
                       "shape). See module header for the order "
                       "verification.")),
    C('uname', 'multiple flags print in the fixed order, not '
      'argument order',
      'If options are specified to select different combinations '
      'of the symbols, only those symbols shall be written, in the '
      'order shown above for the -a option.',
      ['-m', '-s'],
      hand=dict(stdout=['maux 65c02'], rc=0,
                reason="sysname before machine even though -m was "
                       "typed first -- measured live against this "
                       "host's own `uname -m -s`, which also prints "
                       "'Darwin arm64', not 'arm64 Darwin'. See "
                       "module header.")),
    C('uname', 'an operand is a usage error',
      'OPERANDS -- None.',
      ['extra'],
      hand=dict(stdout=[], rc=2,
                reason="uname.s's own :usage path -- exit 2 is this "
                       "tree's uniform usage-error convention. This "
                       "host's own uname also refuses an operand "
                       "('usage: uname [-amnoprsv]'), exit 1 -- a "
                       "different but also nonzero exit, not host-"
                       "oracled because of that mismatch.")),
]


# ======================================================================
# cksum -- XCU cksum.html. EVERY row is hand-authored, unlike cut/
# head/paste/fold: this suite's own `files=` staging writes DIFFERENT
# BYTES on the two sides (host: low-ASCII, LF; maux: high-bit ASCII,
# CR $8D per line, hilines()) and cksum's whole subject is an EXACT
# byte CRC -- the comparator decodes stdout back to plain line
# strings on both sides (maux_lines()/host_lines()), which hides an
# ENCODING difference but not a genuinely DIFFERENT NUMBER computed
# over genuinely different bytes. Expected values below are computed
# by hand over the EXACT hilines() bytes staged for maux (a Python
# model of cksum.s's own algorithm, cross-checked against this Mac's
# /usr/bin/cksum for the algorithm itself -- see cksum.s's header;
# the NUMBERS here are specific to the high-bit/CR encoding, not to
# be confused with a host run over the same TEXT).
# ======================================================================
CKSUM_CASES = [
    C('cksum', 'prints the CRC, the octet count, and (with an '
              'operand) the pathname',
      '"%d %d %s\\n", <CRC value>, <number of octets>, <pathname>',
      ['@F@'], files={'F': ['abc']},
      hand=dict(
          stdout=['2956154133 4 F'], rc=0,
          reason="hand-computed over hilines(['abc']) = "
                 "$E1 $E2 $E3 $8D (4 bytes) -- 'abc' high-bit ASCII "
                 "plus its own line terminator; the pathname is "
                 "the bare relative name, since command_line() cd's "
                 "into the case's own base directory first and "
                 "types every operand as the SAME bare name used on "
                 "the host side (host_mapping()), never a full "
                 "/mnt/MAUX/PXUT/<K-tag>/... path.")),
    C('cksum', 'no operand: read standard input, no pathname column',
      'If no file operands are specified ... the standard input '
      'shall be used ... the pathname shall not be written.',
      [], files={'IN': ['abc']}, stdin='IN',
      hand=dict(stdout=['2956154133 4'], rc=0,
                reason="same 4-byte hilines(['abc']) content as the "
                       "row above, via stdin instead of an operand "
                       "-- no NAME column, sum.s's own NAMEFLG shape.")),
    C('cksum', 'multiple operands: each gets its own line and '
              'pathname, in argument order',
      'For each file operand ... cksum shall write the CRC and the '
      'octet count of the file, and the pathname.',
      ['@F1@', '@F2@'], files={'F1': ['x'], 'F2': ['y']},
      hand=dict(
          stdout=['3684950470 2 F1', '3665513793 2 F2'], rc=0,
          reason="hand-computed over hilines(['x']) = $F8 $8D and "
                 "hilines(['y']) = $F9 $8D -- 2 bytes each (bare "
                 "relative names -- see the row above's own note). "
                 "Unlike sum.s, cksum names EVERY operand, even a "
                 "single one (the row above), not only when there "
                 "is more than one.")),
    C('cksum', 'an unopenable operand does not stop the remaining '
              'ones',
      '>0 An error occurred.',
      ['@NOSUCH@', '@F@'], files={'NOSUCH': None, 'F': ['y']},
      hand=dict(
          stdout=['3665513793 2 F'], rc=1,
          reason="NOSUCH's diagnostic goes to stderr, never "
                 "compared here (see this file's own module "
                 "docstring); the SURVIVING operand's line is "
                 "hand-computed the same way as the two-file row "
                 "above (hilines(['y']), bare relative name), and "
                 "the overall exit is 1, sum.s's/cut.s's own "
                 "'skip and continue' shape.")),
]


# ======================================================================
# paste -- XCU paste.html. Host-oracled like cut/head: the comparator
# decodes stdout back to plain line strings on both sides, and paste
# does not compute a checksum over raw bytes the way cksum does, so
# the encoding difference between the two sides' staged files is
# invisible to it (unlike CKSUM_CASES above). Every non-gap row is
# verified live against this host's own /usr/bin/paste before
# writing paste.s -- see paste.s's own header.
# ======================================================================
PASTE_CASES = [
    C('paste', 'merges corresponding lines of each file, TAB '
              'by default',
      'The default output ... shall be the concatenation of the '
      'corresponding lines ... separated by a <tab>.',
      ['@F1@', '@F2@'], files={'F1': ['a', 'b'], 'F2': ['1', '2']}),
    C('paste', 'a shorter file contributes an empty field, not a '
              'shorter row',
      'When the end of one file is reached before the end of the '
      'other(s), for each subsequent line, ... a null string shall '
      'be used in place of the missing input.',
      ['@F1@', '@F2@'], files={'F1': ['a', 'b', 'c'], 'F2': ['1']}),
    C('paste', '-d changes the delimiter (single character)',
      '-d list -- Use one or more of the characters in ... list, '
      'instead of the default <tab>.',
      ['-d', ',', '@F1@', '@F2@'],
      files={'F1': ['a', 'b'], 'F2': ['1', '2']}),
    C('paste', "-s serializes each file's own lines into one row",
      '-s -- Concatenate all of the lines from each input file '
      'into one line of output per file.',
      ['-s', '@F1@'], files={'F1': ['a', 'b', 'c']}),
    C('paste', 'at least one file operand is required',
      'SYNOPSIS -- paste [-s] [-d list] file...',
      [],
      hand=dict(stdout=[], rc=2,
                reason="paste.s's own :usageerr2 path -- exit 2 is "
                       "this tree's uniform usage-error convention. "
                       "This host's own paste with no operand also "
                       "refuses, exit 1 -- a different but also "
                       "nonzero exit, not host-oracled because of "
                       "that mismatch.")),
    C('paste', "'-' as an operand means standard input",
      "A <hyphen-minus> ... shall be used to instruct paste to "
      "read from standard input in that position in the list of "
      "file operands.",
      ['-', '@F2@'], files={'F2': ['1', '2'], 'IN': ['a', 'b', 'c']},
      stdin='IN'),
]


# ======================================================================
# fold -- XCU fold.html. Host-oracled like paste (see its own header
# note above); every non-gap row verified live against this host's
# own /usr/bin/fold before writing fold.s.
# ======================================================================
FOLD_CASES = [
    C('fold', 'breaks lines at a default width of 80 columns',
      'fold ... breaking the lines ... The default ... shall be 80.',
      ['@F@'], files={'F': ['x' * 90]}),
    C('fold', '-w width sets an explicit width',
      '-w width -- Specify the maximum line length, in column '
      'positions ..., rather than the default of 80.',
      ['-w', '10', '@F@'], files={'F': ['y' * 25]}),
    C('fold', '-b counts bytes rather than column positions',
      '-b -- Count width in bytes rather than column positions.',
      ['-b', '-w', '5', '@F@'], files={'F': ['abcdefghij']}),
    C('fold', '-s breaks after the last blank within the width',
      '-s -- ... break the line after the last <blank> character '
      'that is within the first width column positions.',
      ['-s', '-w', '10', '@F@'],
      files={'F': ['one two three']}),
]


# ======================================================================
# expand -- XCU expand.html. Host-oracled like paste/fold (see their
# own header notes above); every non-gap row verified live against
# this host's own /usr/bin/expand before writing expand.s.
# ======================================================================
EXPAND_CASES = [
    C('expand', 'tabs are replaced with the spaces needed to reach '
               'the next tab stop; default stops every 8 columns',
      'expand ... writes ... with tabs changed to spaces ... default '
      'tab stops shall be at each column position n such that n '
      'modulo 8 is equal to 1.',
      ['@F@'], files={'F': ['ab\tc']}),
    C('expand', '-t N sets stops every N columns, without limit',
      '-t tablist ... If a single number is given ... tab stops '
      'shall be set that number of column positions apart, instead '
      'of the default 8.',
      ['-t', '4', '@F@'], files={'F': ['ab\tc']}),
    C('expand', '-t list sets explicit stops; past the last one a '
               'tab becomes a single space',
      '-t tablist ... a list ... shall set the tab stops at those '
      'column positions.',
      ['-t', '4,10', '@F@'], files={'F': ['a\tb\tc\td\te']}),
    C('expand', 'a backspace decrements the column and is written '
               'to the output as itself',
      'expand ... [a <backspace>] shall decrement the column count '
      'by 1 ... and shall be copied to the output.',
      ['@F@'], files={'F': ['abc\bd\te']}),
]


# ======================================================================
# unexpand -- XCU unexpand.html. Host-oracled like expand (see its
# own header note above); every non-gap row verified live against
# this host's own /usr/bin/unexpand before writing unexpand.s.
# ======================================================================
UNEXPAND_CASES = [
    C('unexpand', 'by default, only a LEADING run of blanks that '
                 'reaches a tab stop is converted',
      'By default ... only leading <blank> characters ... shall be '
      'replaced.',
      ['@F@'], files={'F': ['        leading']}),
    C('unexpand', 'leading blanks that do not reach a stop are left '
                 'unchanged',
      'a string of <blank> characters ... occupying ... more than '
      'one column position ... shall be replaced by ... <tab> '
      'characters ... aligning with a tab stop',
      ['@F@'], files={'F': ['     x']}),
    C('unexpand', '-a converts a qualifying run anywhere in the '
                 'line, not just a leading one',
      '-a ... Convert all <blank> characters, instead of only '
      'leading <blank> characters.',
      ['-a', '@F@'], files={'F': ['a  b']}),
    C('unexpand', 'a single blank one column short of a stop is '
                 'never converted',
      '... at least two ... characters ... shall be replaced.',
      ['-a', '@F@'], files={'F': ['1234567 8']}),
    C('unexpand', '-t implies -a and sets explicit or periodic '
                 'stops the same way expand(1) does',
      '-t tablist ... The application shall ensure that ... -a is '
      'assumed.',
      ['-t', '4', '@F@'], files={'F': ['ab  cd  x']}),
    C('unexpand', 'a qualifying run still converts a crossing whose '
                 'own segment is a single byte',
      '... at least two ... characters ... shall be replaced.',
      ['-a', '@F@'], files={'F': ['1234567  x']}),
]


# ======================================================================
# nl -- XCU nl.html. Host-oracled against this host's own /usr/bin/nl
# EXCEPT the two rows named `hand=` below (this host resets the
# counter on every delimiter line, not just a header one, and always
# refuses more than one file operand with a NONZERO status but a
# different diagnostic wording -- the exit code itself matches).
# `pbre` is a KNOWN GAP: no regex engine is linked into this tool's
# budget (nl.s's own header, docs/POSIX-GAPS.md).
# ======================================================================
NLB = '      \t'      # BSD's unnumbered-line prefix: width-6 blank + tab
NLP = ['one', 'two', 'three', 'foo', 'food', '', 'bar', 'foo bar']
NL_CASES = [
    C('nl', 'default: only non-empty body lines are numbered, '
           'width 6, right justified, no leading zeros, one tab',
      '-b type ... The default type ... shall be t.',
      ['@F@'], files={'F': ['one', 'two', 'three']}),
    C('nl', '-b a numbers every line, including an empty one',
      '-b type ... a ... Number all lines.',
      ['-b', 'a', '@F@'], files={'F': ['one', '', 'three']}),
    # THE TWO HOSTS DISAGREE on what an UNNUMBERED line's prefix
    # looks like, and the XCU text says nothing about it: BSD (this
    # Mac) prints the blank width-6 field and then the separator
    # (a tab); GNU coreutils (the Linux box) prints the blank field
    # and then the separator's WIDTH in spaces. First box sweep of
    # 0a992a7 turned a host-oracled row red on exactly this, so it is
    # spec-authored against the BSD shape maux measured against.
    C('nl', '-b n numbers no lines at all (still prints the blank '
           'field and separator)',
      '-b type ... n ... No lines shall be numbered.',
      ['-b', 'n', '@F@'], files={'F': ['one', 'two']},
      hand=dict(stdout=['      \tone', '      \ttwo'], rc=0,
                reason='the XCU text does not say what an unnumbered '
                       'line carries in place of its number; BSD nl '
                       'prints the blank field then the separator '
                       '(what nl.s does), GNU nl prints the blank '
                       'field then the separator as spaces. No host '
                       'is the oracle here.')),
    C('nl', '-n rz right-justifies and zero-pads to the field width',
      '-n format ... rz ... Line numbers shall be ... right-'
      'justified ... with leading zeros.',
      ['-n', 'rz', '@F@'], files={'F': ['one', 'two']}),
    C('nl', '-s sep sets the text between the number and the line',
      '-s string ... Add string as a character(s) that shall be '
      'used in place of the default <tab>.',
      ['-s', Q(': '), '@F@'], files={'F': ['one', 'two']}),
    C('nl', '-v/-i set the start value and the increment',
      '-v line_number ... -i incr ...',
      ['-v', '10', '-i', '5', '@F@'], files={'F': ['one', 'two']}),
    # SAME SPLIT for a delimiter line's own output: BSD consumes it
    # silently, GNU prints an empty line in its place; the XCU text
    # only says the line SIGNALS a section start. Spec-authored
    # against the BSD shape (found by the same box sweep).
    C('nl', 'a delimiter line switches sections and is itself '
           'consumed, never printed or numbered',
      'a header ... shall begin with a line containing only the '
      'string \\:\\:\\: ...',
      ['@F@'], files={'F': ['\\:\\:\\:', 'HEADER', '\\:\\:',
                            'BODY1', 'BODY2', '\\:', 'FOOTER']},
      hand=dict(stdout=['      \tHEADER', '     1\tBODY1',
                        '     2\tBODY2', '      \tFOOTER'], rc=0,
                reason='the XCU text says a delimiter line signals '
                       'a section start and nothing about output; '
                       'BSD nl emits nothing for it (what nl.s '
                       'does), GNU nl emits an empty line. No host '
                       'is the oracle here.')),
    C('nl', '-l num (adjacent blank lines counted as one)',
      '-l num -- Specify the number of blank lines to be considered '
      'as one. For example, -l 2 results in only the second adjacent '
      'blank line being numbered',
      ['-b', 'a', '-l', '2', '@F@'],
      files={'F': ['one', '', '', 'four']},
      # hand-, not host-oracled: an unnumbered blank line's own
      # prefix format is the SAME BSD-vs-GNU split the "-b n" and
      # delimiter-line rows above are hand-authored over (this
      # tree follows BSD's blank-field-then-separator shape), and
      # -l's grouping necessarily interleaves unnumbered lines
      # with numbered ones -- keeping it host-oracled would just
      # reopen that same, already-settled format split.
      hand=dict(stdout=['     1\tone', '      \t', '     2\t',
                         '     3\tfour'], rc=0,
                reason="SHIPPED 2026-09-17: BLANKCNT (nlfmt.s's "
                       "PRINTONE) counts blank lines within the "
                       "current run under -b a; only every NLNUM'th "
                       "one is numbered. Verified live against this "
                       "Mac's own nl before writing the mechanism "
                       "(file header) -- the SAME grouping rule, "
                       "since POSIX's own text ('only the second "
                       "adjacent blank line being numbered') is "
                       "unambiguous and BSD/GNU agree on it, unlike "
                       "the surrounding format.")),
    C('nl', 'more than one file operand is a usage error',
      'SYNOPSIS -- nl ... [file]',
      ['@F1@', '@F2@'], files={'F1': ['a'], 'F2': ['b']},
      hand=dict(stdout=[], rc=2,
                reason="nl.s's own usage-error path -- exit 2 is "
                       "this tree's uniform usage-error convention. "
                       "This host's own nl also refuses a second "
                       "operand, but with a different diagnostic "
                       "wording and its own exit status -- not "
                       "host-oracled because of that mismatch, only "
                       "the maux-side behavior is asserted here.")),
    C('nl', 'a header, body, or footer delimiter ALIKE resets the '
           'counter unless -p is given',
      '-p ... do not reset the line number at the start of a '
      'logical page.',
      ['@F@'],
      files={'F': ['\\:\\:\\:', 'H1', '\\:\\:', 'B1', 'B2',
                   '\\:\\:\\:', 'H2', '\\:\\:', 'B3']},
      hand=dict(
          stdout=['      \tH1', '     1\tB1', '     2\tB2',
                  '      \tH2', '     1\tB3'], rc=0,
          reason="measured live against this host's own /usr/bin/nl "
                 "(see nl.s's own header): H1/H2 print with a BLANK "
                 "field (default -h n -- header lines are not "
                 "numbered, but they still print) and the SECOND "
                 "page's own header delimiter resets the counter to "
                 "1 too, not only the first page's -- the XCU prose "
                 "alone reads as header-only, so this row pins the "
                 "measured behavior rather than the narrower "
                 "reading.")),
    # pBRE SHIPPED 2026-10-08 (docs/POSIX-REGEXLINK.md): nl links the
    # house BRE engine. EVERY row below is hand= although the number
    # column agrees with both hosts, because every pBRE row has at
    # least one UNNUMBERED line and that prefix is the same BSD-vs-GNU
    # split the -b n row above names (BSD: blank field + the separator
    # itself; GNU: blank field + the separator's width in spaces).
    # Expectations are this Mac's /usr/bin/nl output EXCEPT where
    # the row says otherwise; the box's GNU nl was run over the same
    # argv and selects/numbers the same lines in every row (compared
    # with the unnumbered prefix stripped) -- the two disagreements,
    # `p^$` and the empty BRE, are the rows that say so. All rows keep
    # to ONE logical-page section or to -p: nl.s resets the counter at
    # every delimiter line, BSD only at a header's, GNU at all three,
    # so a multi-section row without -p would assert a reset policy
    # nobody here is testing.
    C('nl', 'pBRE: a BRE that no line matches numbers nothing '
           '(formerly the KNOWN GAP row)',
      '-b type ... pBRE ... Number only lines that contain a match '
      'for the basic regular expression bre.',
      ['-b', 'pfoo', '@F@'], files={'F': ['one', 'two']},
      hand=dict(stdout=[NLB + 'one', NLB + 'two'], rc=0,
                reason='RETIRED 2026-10-08, not deleted: this row was '
                       'the known gap (exit 2, no engine linked) and is '
                       'now the no-match case. Both hosts print every '
                       'line unnumbered; the prefix shape is the BSD '
                       'one (see the pBRE block comment above).')),
    C('nl', 'pBRE: -b pfoo numbers exactly the lines containing foo',
      '-b type ... pBRE ... Number only lines that contain a match '
      'for the basic regular expression bre.',
      ['-b', 'pfoo', '@F@'], files={'F': NLP},
      hand=dict(stdout=[NLB + 'one', NLB + 'two', NLB + 'three',
                        '     1\tfoo', '     2\tfood', NLB,
                        NLB + 'bar', '     3\tfoo bar'], rc=0,
                reason='unanchored substring match, numbering '
                       'continues across the selected lines only. '
                       'Measured on the Mac (BSD) and the box (GNU): '
                       'same selection and numbers; the two differ '
                       'only in the unnumbered-line prefix.')),
    C('nl', 'pBRE: the BRE follows the p with no separator (-bpfoo)',
      '-b type ... The p ... shall be followed by the BRE',
      ['-bpfoo', '@F@'], files={'F': NLP},
      hand=dict(stdout=[NLB + 'one', NLB + 'two', NLB + 'three',
                        '     1\tfoo', '     2\tfood', NLB,
                        NLB + 'bar', '     3\tfoo bar'], rc=0,
                reason='the glued spelling is the same option; '
                       'measured identical on both hosts.')),
    C('nl', 'pBRE: ^ and $ anchor the BRE to the line',
      '-b type ... pBRE ... basic regular expression bre.',
      ['-b', Q('p^f.*d$'), '@F@'], files={'F': NLP},
      hand=dict(stdout=[NLB + 'one', NLB + 'two', NLB + 'three',
                        NLB + 'foo', '     1\tfood', NLB,
                        NLB + 'bar', NLB + 'foo bar'], rc=0,
                reason='^f.*d$ matches only food: foo does not end '
                       'in d, and foo bar does not.')),
    C('nl', 'pBRE: a group and a backreference',
      '-b type ... pBRE ... basic regular expression bre.',
      ['-b', Q('p\\(o\\)\\1'), '@F@'], files={'F': NLP},
      hand=dict(stdout=[NLB + 'one', NLB + 'two', NLB + 'three',
                        '     1\tfoo', '     2\tfood', NLB,
                        NLB + 'bar', '     3\tfoo bar'], rc=0,
                reason='the group and \\1 spell "oo": a BRE feature '
                       'the engine owes POSIX. Same selection on BSD '
                       'and GNU.')),
    C('nl', 'pBRE: a bracket expression selects',
      '-b type ... pBRE ... basic regular expression bre.',
      ['-b', Q('p[aeiou][aeiou]'), '@F@'], files={'F': NLP},
      hand=dict(stdout=[NLB + 'one', NLB + 'two',
                        '     1\tthree', '     2\tfoo', '     3\tfood',
                        NLB, NLB + 'bar', '     4\tfoo bar'], rc=0,
                reason='two adjacent vowels: three (ee), foo, food, '
                       'foo bar. Same selection on BSD and GNU.')),
    C('nl', 'pBRE: ^$ numbers only the empty line',
      '-b type ... pBRE ... Number only lines that contain a match '
      'for the basic regular expression bre.',
      ['-b', Q('p^$'), '@F@'], files={'F': NLP},
      hand=dict(stdout=[NLB + 'one', NLB + 'two', NLB + 'three',
                        NLB + 'foo', NLB + 'food', '     1\t',
                        NLB + 'bar', NLB + 'foo bar'], rc=0,
                reason='THE ORACLES DISAGREE and the BSD one is the '
                       'wrong one: this Mac numbers ALL EIGHT lines '
                       'for p^$, the box (GNU) numbers only the empty '
                       'line. ^$ matches an empty line and nothing '
                       'else in POSIX BRE, which is GNU\'s answer and '
                       'the engine\'s.')),
    C('nl', 'pBRE: an empty BRE matches every line',
      '-b type ... pBRE ... (the XCU text says nothing about an '
      'empty bre)',
      ['-b', 'p', '@F@'], files={'F': ['one', '', 'three']},
      hand=dict(stdout=['     1\tone', '     2\t', '     3\tthree'],
                rc=0,
                reason='unspecified by XCU. GNU numbers every line, '
                       'the empty one included; BSD refuses with '
                       '"empty (sub)expression". maux follows GNU: '
                       'an empty pattern matches at every line start, '
                       'which is what the engine returns for it.')),
    C('nl', 'pBRE: -n, -w and -s still shape the number field',
      '-b type ... pBRE; -n format; -s string; -w number',
      ['-bpfoo', '-n', 'ln', '-w', '3', '-s', ':', '@F@'],
      files={'F': ['one', 'foo', 'food']},
      hand=dict(stdout=['   :one', '1  :foo', '2  :food'], rc=0,
                reason='BSD shape for the unnumbered line (blank '
                       'field then the separator itself); the '
                       'numbered lines agree on both hosts.')),
    C('nl', 'pBRE: a FOREIGN low-ASCII file selects the same lines',
      '-b type ... pBRE ... Number only lines that contain a match '
      'for the basic regular expression bre.',
      ['-b', 'pfoo', '@F@'],
      files={'F': b'one\rfoo\rfood\r'},
      hand=dict(stdout=[NLB + 'one', '     1\tfoo', '     2\tfood'],
                rc=0,
                reason='the file arrives as ProDOS tools write it -- '
                       'LOW ASCII, $0D -- not as maux does (high bit, '
                       '$8D). The engine reads bit 7 SET, so NLMATCH '
                       'matches a normalised copy (grepbody.s '
                       'NORMLINE\'s rule, learning:01M28FXZHBN4V6T4NT6'
                       'PZZ4M4S is the sibling arena finding); a '
                       'tool that matched the raw bytes would number '
                       'nothing. Staged raw by stage_batch, hand= only '
                       '-- the host oracle never sees a bytes file.')),
    C('nl', 'pBRE: -h selects header lines',
      '-h type ... pBRE ...',
      ['-h', 'pfoo', '@F@'],
      files={'F': ['\\:\\:\\:', 'foo', 'bar', 'food']},
      hand=dict(stdout=['     1\tfoo', NLB + 'bar', '     2\tfood'],
                rc=0,
                reason='the header delimiter is consumed (BSD prints '
                       'nothing for it, GNU prints an empty line -- '
                       'the delimiter-row split above); the numbering '
                       'agrees on both hosts.')),
    C('nl', 'pBRE: -f selects footer lines',
      '-f type ... pBRE ...',
      ['-f', 'pfoo', '@F@'],
      files={'F': ['\\:', 'foo', 'bar', 'food']},
      hand=dict(stdout=['     1\tfoo', NLB + 'bar', '     2\tfood'],
                rc=0,
                reason='the footer twin of the -h row; same split '
                       'over the delimiter line, same numbering.')),
    C('nl', 'pBRE: each section keeps its OWN pattern (-p, no reset)',
      '-h type -b type -f type; -p ... Do not restart the numbering '
      'of lines at logical page delimiters.',
      ['-h', 'pfoo', '-b', 'pbar', '-f', 'pfoo', '-p', '@F@'],
      files={'F': ['\\:\\:\\:', 'h-foo', 'h-bar',
                   '\\:\\:', 'b-foo', 'b-bar',
                   '\\:', 'f-foo', 'f-bar']},
      hand=dict(stdout=['     1\th-foo', NLB + 'h-bar', NLB + 'b-foo',
                        '     2\tb-bar', '     3\tf-foo',
                        NLB + 'f-bar'], rc=0,
                reason='three patterns, one per section: header and '
                       'footer number *foo*, body numbers *bar*. -p '
                       'keeps the count running so the row does not '
                       'depend on the reset policy (BSD resets at '
                       'headers only, GNU at every delimiter, nl.s at '
                       'every delimiter). Measured on both hosts: '
                       'same selection and numbers.')),
]


# ======================================================================
# cal -- XSI cal.html. Hand-authored against this host's own /usr/bin/
# cal (no host on the box shares its layout -- see CAL_REASON): every
# line is byte-exact-matched, including BSD's 22-column trailing-space
# pad and 6-row body. SHIPPED 2026-09-17: `cal YEAR` now renders the
# same 3-column full-year layout too (cal.s's own header).
# ======================================================================
CAL_REASON = ("no host is the oracle on the box: Debian ships no cal at all, and util-linux/ncal cal lay the month out differently (no 22-column pad, no 6th blank row); the XSI page says only 'a calendar'. Lines captured verbatim from this Mac's own /usr/bin/cal (BSD), which cal.s was measured against.")

CAL_CASES = [
    # EVERY cal row is spec-authored with lines captured from this
    # Mac's BSD cal (review, 2026-09-15): the Linux box has no cal
    # binary (Debian: it lives in the ncal package, not installed),
    # and the cal(1)s that exist there lay a month out differently
    # on details the XSI page never fixes. e2e_corpus.py keeps the
    # live Mac oracle for the same four months.
    C('cal', 'a month with 5 body weeks pads a 6th blank row',
      'cal [[month] year] ... a calendar for the specified month',
      ['9', '2026'], files={},
      hand=dict(stdout=['   September 2026     ', 'Su Mo Tu We Th Fr Sa  ', '       1  2  3  4  5  ', ' 6  7  8  9 10 11 12  ', '13 14 15 16 17 18 19  ', '20 21 22 23 24 25 26  ', '27 28 29 30           ', '                      '], rc=0, reason=CAL_REASON)),
    C('cal', 'February in a leap year has 29 days',
      'cal ... Gregorian calendar',
      ['2', '2024'], files={},
      hand=dict(stdout=['   February 2024      ', 'Su Mo Tu We Th Fr Sa  ', '             1  2  3  ', ' 4  5  6  7  8  9 10  ', '11 12 13 14 15 16 17  ', '18 19 20 21 22 23 24  ', '25 26 27 28 29        ', '                      '], rc=0, reason=CAL_REASON)),
    C('cal', 'a month starting on Sunday has no leading blanks',
      'cal ... a calendar for the specified month',
      ['1', '2000'], files={},
      hand=dict(stdout=['    January 2000      ', 'Su Mo Tu We Th Fr Sa  ', '                   1  ', ' 2  3  4  5  6  7  8  ', ' 9 10 11 12 13 14 15  ', '16 17 18 19 20 21 22  ', '23 24 25 26 27 28 29  ', '30 31                 '], rc=0, reason=CAL_REASON)),
    C('cal', 'December, and a month needing exactly 6 body weeks',
      'cal ... a calendar for the specified month',
      ['12', '2026'], files={},
      hand=dict(stdout=['   December 2026      ', 'Su Mo Tu We Th Fr Sa  ', '       1  2  3  4  5  ', ' 6  7  8  9 10 11 12  ', '13 14 15 16 17 18 19  ', '20 21 22 23 24 25 26  ', '27 28 29 30 31        ', '                      '], rc=0, reason=CAL_REASON)),
    C('cal', 'a month outside 1-12 is a usage error',
      'cal [[month] year]',
      ['13', '2026'], files={},
      hand=dict(stdout=[], rc=2,
                reason="month must be 1-12 -- cal.s's own usage "
                       "path, exit 2 by house convention. No "
                       "common host row: this host's own cal reads "
                       "two bare numeric operands as YEAR-only "
                       "followed by a usage error of its own, a "
                       "different construct.")),
    # SHIPPED 2026-09-17: cal.s now renders BSD's own 3-column
    # full-year layout (CALEMITC/CALEMITS/PRINTQTR -- see cal.s's
    # own header). Expected lines unchanged from this row's own
    # earlier KNOWN_GAPS capture: this Mac's `cal 2026`, 36 lines,
    # captured verbatim -- the fixture that PROVED the design (a
    # single empty line between quarters, never two, and every
    # quarter always 6 week rows including a fully blank one).
    C('cal', 'the full-year 3-column BSD layout',
      'cal [[month] year] ... a calendar for the specified year',
      ['2026'], files={},
      hand=dict(stdout=['                            2026', '      January               February               March          ', 'Su Mo Tu We Th Fr Sa  Su Mo Tu We Th Fr Sa  Su Mo Tu We Th Fr Sa  ', '             1  2  3   1  2  3  4  5  6  7   1  2  3  4  5  6  7  ', ' 4  5  6  7  8  9 10   8  9 10 11 12 13 14   8  9 10 11 12 13 14  ', '11 12 13 14 15 16 17  15 16 17 18 19 20 21  15 16 17 18 19 20 21  ', '18 19 20 21 22 23 24  22 23 24 25 26 27 28  22 23 24 25 26 27 28  ', '25 26 27 28 29 30 31                        29 30 31              ', '                                                                  ', '', '       April                  May                   June          ', 'Su Mo Tu We Th Fr Sa  Su Mo Tu We Th Fr Sa  Su Mo Tu We Th Fr Sa  ', '          1  2  3  4                  1  2      1  2  3  4  5  6  ', ' 5  6  7  8  9 10 11   3  4  5  6  7  8  9   7  8  9 10 11 12 13  ', '12 13 14 15 16 17 18  10 11 12 13 14 15 16  14 15 16 17 18 19 20  ', '19 20 21 22 23 24 25  17 18 19 20 21 22 23  21 22 23 24 25 26 27  ', '26 27 28 29 30        24 25 26 27 28 29 30  28 29 30              ', '                      31                                          ', '', '        July                 August              September        ', 'Su Mo Tu We Th Fr Sa  Su Mo Tu We Th Fr Sa  Su Mo Tu We Th Fr Sa  ', '          1  2  3  4                     1         1  2  3  4  5  ', ' 5  6  7  8  9 10 11   2  3  4  5  6  7  8   6  7  8  9 10 11 12  ', '12 13 14 15 16 17 18   9 10 11 12 13 14 15  13 14 15 16 17 18 19  ', '19 20 21 22 23 24 25  16 17 18 19 20 21 22  20 21 22 23 24 25 26  ', '26 27 28 29 30 31     23 24 25 26 27 28 29  27 28 29 30           ', '                      30 31                                       ', '', '      October               November              December        ', 'Su Mo Tu We Th Fr Sa  Su Mo Tu We Th Fr Sa  Su Mo Tu We Th Fr Sa  ', '             1  2  3   1  2  3  4  5  6  7         1  2  3  4  5  ', ' 4  5  6  7  8  9 10   8  9 10 11 12 13 14   6  7  8  9 10 11 12  ', '11 12 13 14 15 16 17  15 16 17 18 19 20 21  13 14 15 16 17 18 19  ', '18 19 20 21 22 23 24  22 23 24 25 26 27 28  20 21 22 23 24 25 26  ', '25 26 27 28 29 30 31  29 30                 27 28 29 30 31        ', '                                                                  '], rc=0, reason=CAL_REASON)),
]


# ======================================================================
# strings -- XSI strings.html. Host-oracled against this host's own
# /usr/bin/strings on plain data fixtures (never Mach-O): every
# fixture staged through `files=` gets liba's own high-bit-ASCII text
# convention on the maux side and plain 7-bit text on the host side
# (this harness's own two-encoding rule -- see its module header) --
# BOTH sides therefore agree on which runs are long enough, since a
# letter is a letter under either convention, and maux_lines() strips
# the high bit back off before comparing. The one row that is NOT
# host-oracled (the high-bit-as-printable convention itself, strings.
# s's own header) is `hand=`: no fixture built through this harness's
# always-high-bit staging can EXERCISE that divergence (any staged
# printable byte is already printable on both sides), so it is
# asserted directly instead.
# ======================================================================
STR_REASON = ("the XSI page fixes the base of the offset, not its width: BSD strings (this Mac) prints it bare, GNU binutils strings (the box) pads it to 7 columns. Lines captured from this Mac's own /usr/bin/strings over the same bytes, which strings.s was measured against; the host-independent rows above keep the live oracle.")

STRINGS_CASES = [
    C('strings', 'default minimum length is 4; shorter runs are '
                 'discarded',
      'A string is any sequence of 4 (the default) or more '
      'printing characters.',
      ['@F@'], files={'F': ['AB\x01hello world\x02foo']}),
    C('strings', '-n overrides the minimum length',
      '-n number Specify the minimum string length.',
      ['-n', '2', '@F@'], files={'F': ['AB\x01hello world\x02foo']}),
    # THE -t ROWS are spec-authored (review, 2026-09-15): GNU
    # strings pads the offset to 7 columns, BSD prints it bare, and
    # the XSI page fixes only the base. Lines captured from this
    # Mac's BSD strings, strings.s's own oracle.
    C('strings', '-t x prefixes each string with its hex offset',
      '-t format ... x The offset shall be written in hexadecimal.',
      ['-t', 'x', '@F@'],
      files={'F': ['zzzzzzzzzz\x01hello']},
      hand=dict(stdout=['0 zzzzzzzzzz', 'b hello'], rc=0, reason=STR_REASON)),
    C('strings', '-t d prefixes each string with its decimal offset',
      '-t format ... d The offset shall be written in decimal.',
      ['-t', 'd', '@F@'],
      files={'F': ['zzzzzzzzzz\x01hello']},
      hand=dict(stdout=['0 zzzzzzzzzz', '11 hello'], rc=0, reason=STR_REASON)),
    C('strings', '-t o prefixes each string with its octal offset',
      '-t format ... o The offset shall be written in octal.',
      ['-t', 'o', '@F@'],
      files={'F': ['zzzzzzzzzz\x01hello']},
      hand=dict(stdout=['0 zzzzzzzzzz', '13 hello'], rc=0, reason=STR_REASON)),
    C('strings', 'the offset resets to 0 at the start of EACH file '
                 'operand',
      'strings ... file...',
      ['-t', 'd', '@F1@', '@F2@'],
      files={'F1': ['hello world'], 'F2': ['goodbye now']},
      hand=dict(stdout=['0 hello world', '0 goodbye now'], rc=0, reason=STR_REASON)),
    C('strings', '-n over 255 is a KNOWN GAP (the run buffer is one '
                 'page)',
      '-n number Specify the minimum string length.',
      ['-n', '300', '@F@'], files={'F': ['hello world']},
      known_gap="strings.s's own header: NUMBER is capped at 255 "
                "(RUNBUF is one page); -n 300 is a usage error, exit "
                "2, where a host strings prints nothing and exits 0."),
    C('strings', 'a bad -t argument is a usage error',
      '-t format ... d ... o ... x',
      ['-t', 'q', '@F@'], files={'F': ['hello world']},
      hand=dict(stdout=[], rc=2,
                reason="strings.s's own usage path -- 'q' is none "
                       "of d/o/x, exit 2 by house convention. No "
                       "host row: this host's own strings silently "
                       "ignores an unrecognised -t argument instead "
                       "of refusing it.")),
    C('strings', 'high-bit ASCII ($A0-$FE) counts as printable too '
                 '-- this build\'s OWN text convention, not just '
                 'plain 7-bit ASCII',
      'maux text convention... $A0-$FE... both conventions count',
      ['-n', '4', '@F@'], files={'F': ['hello world']},
      hand=dict(stdout=['hello world'], rc=0,
                reason="every byte this harness stages is ALREADY "
                       "high-bit ASCII on the maux side (its own "
                       "hilines() convention), so this row's own "
                       "SUCCESS is the divergence: strings.s's "
                       "ISPRINT accepts $A0-$FE, and this host's "
                       "strings(1) never does -- a raw high-bit "
                       "file is not constructible through this "
                       "harness's text-fixture staging at all (it "
                       "forces the high bit on every byte, so there "
                       "is no host-comparable LOW-bit-vs-HIGH-bit "
                       "fixture pair to build), which is exactly "
                       "why this row is pinned by hand instead of "
                       "against the host.")),
]


# ======================================================================
# man -- maux-only, no host equivalent (man.s's own header). Every
# row is `hand=`: diagnostics only for most of them (the paged/
# unpaged FULL PAGE CONTENT is proven by check-play's live MAN phase
# and check-textaudit's PAIR row, not replayed here -- reproducing
# mandoc's own bold-overstrike rendering byte-for-byte in Python was
# judged not worth the cost against what those two other gates
# already cover). The last two rows are the exception: they use
# `contains=` (a fragment-in-stdout check, not exact stdout equality)
# to prove a real page actually renders and pages, without taking on
# the byte-for-byte cost the paragraph above rules out.
# ======================================================================
MAN_CASES = [
    C('man', 'no such page: a message and exit 1',
      'man: no manual entry for NAME',
      ['nosuchpage'], files={},
      hand=dict(stdout=[], rc=1,
                reason="man.s's own :noentry path writes to fd 2 "
                       "(not captured by this harness) and exits "
                       "1; stdout is empty either way.")),
    C('man', 'a leading numeric section is accepted and ignored',
      'man [section] name',
      ['1', 'nosuchpage'], files={},
      hand=dict(stdout=[], rc=1,
                reason="proves the section operand was consumed as "
                       "a section, not folded into the page name -- "
                       "the diagnostic (fd 2, uncaptured) still "
                       "names 'nosuchpage', and the exit status is "
                       "the same 'no manual entry' 1, not a usage "
                       "error.")),
    C('man', 'more than two operands is a usage error',
      'man [section] name',
      ['1', 'ls', 'extra'], files={},
      hand=dict(stdout=[], rc=2,
                reason="man.s's own :usage path, exit 2 by house "
                       "convention.")),
    C('man', 'an operand beginning with - is a usage error',
      'man [section] name',
      ['-k'], files={},
      hand=dict(stdout=[], rc=2,
                reason="-k/-f (apropos/whatis) are KNOWN_GAPS -- "
                       "this tree builds no page index to search "
                       "(man.s's own header) -- so man.s refuses "
                       "any '-'-leading operand as a usage error "
                       "rather than silently ignoring it.")),
    # The two rows below prove a real man(1) page renders and pages
    # (`man/na-stubs`, 2026-09-17): a not-applicable stub (`ar`,
    # docs/man/ar.1) and a pre-existing real page (`tty`,
    # docs/man/tty.1) both still print SOMETHING and exit 0. Neither
    # reproduces the FULL mandoc/nroff rendering byte-for-byte (this
    # module's own header explains why that is not replayed here);
    # `contains=` is check_posixutil.py's escape hatch for exactly
    # this shape -- a fragment that can only appear if the real page
    # content made it to stdout unpaged (stdout here is `> OUT`, a
    # plain file, so man.s's own "not a terminal" branch copies the
    # page through unpaged rather than invoking more(1)).
    C('man', 'a not-applicable stub page renders and exits 0',
      'man [section] name',
      ['ar'], files={},
      hand=dict(rc=0, contains='LIBK',
                reason="docs/man/ar.1's own DESCRIPTION names "
                       "/LIB/LIBK, the library directory ld(1) "
                       "links from instead of an archive format -- "
                       "that fragment can only reach stdout if the "
                       "stub page's real text was rendered and "
                       "copied through, proving the not-applicable "
                       "stub added 2026-09-17 actually pages.")),
    C('man', 'an existing real page still renders and exits 0',
      'man [section] name',
      ['tty'], files={},
      hand=dict(rc=0, contains='ttya0',
                reason="docs/man/tty.1 names /dev/ttya0 (the SSC "
                       "line) in its DESCRIPTION -- proving man's "
                       "ordinary success path (a real, non-stub "
                       "page) still works after the stub pages "
                       "were added, not just the not-applicable "
                       "row above.")),
]


# ======================================================================
# nohup -- XCU nohup.html (eng-nohup-timeout-realpath, cut from
# a9034eb). EVERY row is hand-authored: this suite runs with stdout
# redirected to a real file (`> OUT`), never a tty, so nohup's own
# SC_FDSTAT check always finds "not a terminal" and the redirect/
# notice machinery (NOHUP.OUT, the fd 2 notice) never fires here at
# all -- that path is check-play's own phase instead (live console,
# a real tty). What is left to prove is the PASS-THROUGH and the
# exit-status table, and even those stay hand= rather than host-
# oracled: this suite's own harness never exports PATH (same finding
# xargs's/env's own rows already document), and a bare "ECHO"/"FALSE"
# word run through a REAL host nohup would need a host binary this
# Mac may spell differently case-wise -- not worth the risk for four
# rows this cheap to hand-author directly from the child's own known
# behaviour.
# ======================================================================
NOHUP_CASES = [
    C('nohup', 'pass-through: a quick utility (ECHO), exit 0',
      "the SIGHUP signal ... shall be set to be ignored ... utility "
      "shall be invoked",
      ['ECHO', 'HI'],
      hand=dict(stdout=['HI'], rc=0,
                reason="stdout is redirected to a real file here, "
                       "never a tty -- nohup's own SC_FDSTAT check "
                       "finds no terminal and never touches fd 1/2 "
                       "or creates NOHUP.OUT, so this is a pure "
                       "pass-through of ECHO's own output and exit "
                       "status.")),
    C('nohup', 'pass-through: a failing utility (FALSE), exit 1',
      "the exit status of nohup shall be that of the utility "
      "specified by the utility operand",
      ['FALSE'],
      hand=dict(stdout=[], rc=1,
                reason="FALSE has no stdout; its own exit status (1) "
                       "passes straight through SC_WAIT, untouched "
                       "(env.s's own convention this file's header "
                       "cites).")),
    C('nohup', 'utility not found: exit 127',
      "127 An error occurred in the nohup utility or the utility "
      "specified by the utility operand could not be found",
      ['NOSUCHCMD127'],
      hand=dict(stdout=[], rc=127,
                reason="PATHRSLV fails on every PATHTAB entry -- "
                       "the same 127 env.s/time.s already use for a "
                       "not-found child.")),
    C('nohup', 'no operand is a usage error',
      'nohup utility [argument...]',
      [],
      hand=dict(stdout=[], rc=2,
                reason="this tree's own uniform usage-error "
                       "convention (comm.s/cmp.s/etc: exit 2); GNU "
                       "and BSD nohup each print their own usage "
                       "text and may use a different code for a "
                       "missing operand, so this stays hand-"
                       "authored rather than host-oracled.")),
]


# ======================================================================
# timeout -- XCU timeout.html (eng-nohup-timeout-realpath, cut from
# a9034eb). NO HOST ORACLE EXISTS: this Mac has no `timeout` binary
# at all, so every row is hand-authored from the XCU text and from
# this suite's own play.po harness, which (unlike check-textaudit's
# stripped harness) links a real timer (an AppleMouse VBL or
# Mockingboard tick source) -- sleep.s's own rows already prove that
# live in this same suite, and timeout's own poll loop needs exactly
# the same source.
# ======================================================================
TIMEOUT_CASES = [
    C('timeout', 'a quick utility exits with its own status (TRUE)',
      "otherwise, the exit status of timeout shall be that of "
      "utility",
      ['5', 'TRUE'],
      hand=dict(stdout=[], rc=0,
                reason="TRUE returns well inside the 5 s deadline; "
                       "no signal is ever sent, so timeout's own "
                       "exit is TRUE's own status, unchanged.")),
    C('timeout', 'a quick failing utility still exits with its own '
      'status (FALSE)',
      "otherwise, the exit status of timeout shall be that of "
      "utility",
      ['5', 'FALSE'],
      hand=dict(stdout=[], rc=1, reason="same reasoning, FALSE's 1.")),
    C('timeout', 'a utility that outruns duration is killed, exit 124',
      "124 The utility named by utility timed out",
      ['1', 'SLEEP', '3'],
      hand=dict(stdout=[], rc=124,
                reason="SLEEP has no stdout. The 1 s deadline fires "
                       "well before SLEEP's own 3 s is up; timeout "
                       "sends the default TERM (kill-signo-abi: "
                       "DFL disposition terminates unconditionally, "
                       "no cooperation needed from SLEEP), reaps it, "
                       "and reports 124 -- -p was not given, so the "
                       "child's own $80|signo status is NOT "
                       "preserved.")),
    C('timeout', '-p preserves the child status after a timeout',
      "-p ... the exit status shall be that of utility",
      ['-p', '1', 'SLEEP', '3'],
      hand=dict(stdout=[], rc=143,
                reason="143 = $8F = $80|15 -- SLEEP's own wait "
                       "status after the default TERM, the same "
                       "kill-signo-abi encoding kill.s's own header "
                       "documents ($8F TERM). -p reports this "
                       "instead of the bare 124.")),
    C('timeout', '-s selects the signal by name (KILL)',
      "-s signal ... send that signal ... instead of ... SIGTERM",
      ['-s', 'KILL', '1', 'SLEEP', '3'],
      hand=dict(stdout=[], rc=124,
                reason="signo 9 (KILL, shtrap.s's own name table -- "
                       "see this tool's own header for why this is "
                       "NOT kill.s's mechanism) force-kills "
                       "unconditionally; the exit code is still 124 "
                       "without -p regardless of which signal fired.")),
    C('timeout', '-k follows a signal with a grace period',
      "-k time ... send a KILL signal to the utility if it is still "
      "running",
      ['-k', '1', '1', 'SLEEP', '3'],
      hand=dict(stdout=[], rc=124,
                reason="SLEEP has no disposition of its own (SIGA_"
                       "DFL) so the FIRST signal (default TERM) "
                       "already terminates it -- the -k grace path "
                       "(KTARGET computed, the poll continues) is "
                       "exercised but its own follow-up KILL is "
                       "never NEEDED to fire. Nothing in this tree's "
                       "fleet arms SIGA_IGN for itself, so a row "
                       "that forces the follow-up KILL to actually "
                       "fire cannot be built from existing "
                       "utilities; this row proves -k does not "
                       "break the ordinary case instead.")),
    C('timeout', 'a bad duration is a usage error, exit 125',
      "125 if the duration parameter or the timeout utility itself "
      "is invalid",
      ['abc', 'TRUE'],
      hand=dict(stdout=[], rc=125,
                reason="TO_PARSEDUR's first non-digit character "
                       "('a') matches neither a digit nor s/m/h -- "
                       "bad duration, refused before any spawn.")),
    C('timeout', 'a fractional duration (whole seconds)',
      "a decimal integer ... optionally followed by ... s, m, h, or "
      "d",
      ['1.5', 'TRUE'],
      hand=dict(stdout=[], rc=0,
                reason="SHIPPED 2026-09-17: TO_PARSEDUR now takes "
                       "ONE fractional digit when the unit resolves "
                       "to seconds -- '1.5' is 90 ticks (60 ticks/s "
                       "/ 10 tenths = 6 ticks/tenth, times 5). TRUE "
                       "exits before the 90-tick deadline either "
                       "way, so this row proves the duration PARSED "
                       "(no usage-error 125) rather than the timing "
                       "itself -- same shape as this module's other "
                       "'-k does not break the ordinary case' row.")),
    # SHIPPED 2026-09-21, and the OLD REASON WAS WRONG, which is the
    # part worth recording. This gap said a fraction of a minute could
    # not be a whole tick count "without a real multiply-then-divide
    # this tool has no budget for". There is no division: 60, 3600 and
    # 216000 ticks all divide by 10 EXACTLY, so a three-entry table of
    # tenths (6, 360, 21600 -- TENTHTAB, timeoutaux.s) settles it, and
    # the digit is added that many times, at most nine. The arithmetic
    # was never the obstacle; nobody had divided the constants.
    C('timeout', 'a fractional minute is a duration',
      "a decimal integer ... optionally followed by ... s, m, h, or "
      "d",
      ['1.5m', 'TRUE'],
      hand=dict(stdout=[], rc=0,
                reason="'1.5m' is 5400 ticks: 1 minute (3600) plus "
                       "five tenths of a minute (5 x 360). TRUE "
                       "exits long before that either way, so this "
                       "row proves the duration PARSED -- no "
                       "usage-error 125 -- which is exactly what "
                       "the refusal it replaces used to produce.")),
    C('timeout', 'no utility operand is a usage error, exit 125',
      "125 if ... timeout did not have enough information",
      ['5'],
      hand=dict(stdout=[], rc=125,
                reason="fewer than two operands remain past options "
                       "-- refused before any spawn, same lane as "
                       "the bad-duration row above.")),
    C('timeout', 'utility not found: exit 127',
      "126/127 as nohup",
      ['5', 'NOSUCHCMD127'],
      hand=dict(stdout=[], rc=127,
                reason="PATHRSLV fails on every PATHTAB entry, "
                       "checked AFTER the duration parses and the "
                       "tick mode is confirmed -- the same 127 "
                       "nohup/env/time already use.")),
]


# ======================================================================
# realpath -- XCU realpath.html (eng-nohup-timeout-realpath, cut from
# a9034eb). EVERY row is hand-authored: check_posixutil's own base
# directory is PER-CASE (/mnt/MAUX/PXUT/<K-tag>), assigned at batch time,
# so no literal expected path can be typed into this table -- but
# `hand` MAY BE A CALLABLE receiving that exact directory as `base`
# (check_posixutil.py's own oracle(), `case['hand'](base)`), which is
# used throughout below instead of the shell-substitution trick this
# tool's own task brief suggested: `base` already IS the maux-side
# absolute path GET_PREFIX will report, so the expected stdout is
# computed directly in Python, no `test "$(...)"` construction or
# second shell process needed.
# ======================================================================
REALPATH_CASES = [
    C('realpath', 'a plain file resolves to <cwd>/<name>',
      "canonicalize the specified pathname",
      ['F'], files={'F': ['x']},
      hand=lambda base: dict(
          stdout=[f'{base}/F'], rc=0,
          reason="base is this case's own per-run directory "
                 "(check_posixutil.py's own maux_mapping()), exactly "
                 "what GET_PREFIX reports as cwd -- no host process "
                 "shares this ProDOS path space to compare against.")),
    C('realpath', './A/../F folds through a subdirectory and back',
      "does not contain any components that are dot or dot-dot",
      ['./A/../F'], files={'F': ['x']}, dirs={'A': 'A'}, predirs=['A'],
      hand=lambda base: dict(
          stdout=[f'{base}/F'], rc=0,
          reason="RP_SPLIT folds the leading '.' and the 'A/..' pair "
                 "away entirely -- the result is identical to the "
                 "plain-file row above, proving the fold rather than "
                 "just the pass-through.")),
    C('realpath', 'an absolute operand is returned unchanged',
      "canonicalize the specified pathname",
      ['$(pwd)/F'], files={'F': ['x']},
      hand=lambda base: dict(
          stdout=[f'{base}/F'], rc=0,
          reason="$(pwd) is maux's OWN shell substituting its "
                 "current directory before REALPATH ever runs, so "
                 "the operand is already absolute -- RP_RESOLVE's "
                 "leading-'/' branch, no cwd lookup at all.")),
    C('realpath', '-E allows the last component to be missing '
      '(default)',
      "-E Do not treat it as an error if ... the last component ... "
      "results in ... [ENOENT]",
      ['-E', 'NOSUCH'], files={},
      hand=lambda base: dict(
          stdout=[f'{base}/NOSUCH'], rc=0,
          reason="NOSUCH is never staged; -E checks only the parent "
                 "(this case's own directory, which does exist) and "
                 "prints the folded path regardless of the last "
                 "component's own existence.")),
    C('realpath', '-e requires the last component to exist',
      "-e Treat it as an error if ... the last component ... "
      "results in ... [ENOENT]",
      ['-e', 'NOSUCH'], files={},
      hand=dict(stdout=[], rc=1,
                reason="the same missing NOSUCH as the -E row above, "
                       "but -e checks the FULL path including the "
                       "last component -- GET_FILE_INFO fails, "
                       "nothing is printed, exit 1.")),
    C('realpath', 'a missing middle component fails under the '
      'default (-E)',
      "-E ... [does not exempt] errors other than [ENOENT] on the "
      "last component",
      ['NOSUCHDIR/F'], files={},
      hand=dict(stdout=[], rc=1,
                reason="-E's own parent check is on NOSUCHDIR (the "
                       "component BEFORE the last, F), which does "
                       "not exist -- ENOENT on a non-last component "
                       "is not the exemption -E grants, so this "
                       "fails exactly as -e would.")),
    C('realpath', 'a missing middle component fails under -e too',
      "-e Treat it as an error",
      ['-e', 'NOSUCHDIR/F'], files={},
      hand=dict(stdout=[], rc=1,
                reason="same missing NOSUCHDIR as the default row "
                       "above; -e's own full-path check fails the "
                       "same way, same exit 1 -- this row exists to "
                       "show the -E/-e distinction does not matter "
                       "here, not to find a new failure mode.")),
    C('realpath', 'two operands, one fails: the good one still '
      'prints, exit 1',
      "a pathname to be canonicalized",
      ['F', 'NOSUCHDIR/X'], files={'F': ['x']},
      hand=lambda base: dict(
          stdout=[f'{base}/F'], rc=1,
          reason="each operand is resolved independently (RP_EXIT "
                 "accumulates failures but the loop never stops) -- "
                 "F succeeds and prints before NOSUCHDIR/X is even "
                 "reached, then that second operand fails and sets "
                 "the overall exit status to 1 without erasing what "
                 "F already printed.")),
    C('realpath', 'a directory operand resolves the same as a file',
      "canonicalize the specified pathname",
      ['A'], dirs={'A': 'A'}, predirs=['A'],
      hand=lambda base: dict(
          stdout=[f'{base}/A'], rc=0,
          reason="realpath does not distinguish a directory operand "
                 "from a file one -- GET_FILE_INFO succeeds on "
                 "either storage type, and RP_CHECK never inspects "
                 "STYP at all.")),
    C('realpath', '.. above the volume root stays at the root',
      "canonicalize ... does not contain any components that are "
      "dot or dot-dot",
      ['../../../..'],
      hand=dict(stdout=['/'], rc=0,
                reason="this suite's own base is 3 components below "
                       "the carrier volume (/mnt/MAUX/PXUT/<K-tag>); "
                       "4 levels of '..' pop the K-tag, PXUT, the "
                       "volume and then /mnt itself, which lands on "
                       "the kernel's virtual root (docs/VROOT.md, "
                       "volumes live under /mnt). It used to stop "
                       "at the volume name; the volume is now a "
                       "directory like any other.")),
    C('realpath', '.. above the virtual root stays at the root',
      "canonicalize ... does not contain any components that are "
      "dot or dot-dot",
      ['../../../../..'],
      hand=dict(stdout=['/'], rc=0,
                reason="one more '..' than the row above: the root "
                       "has no parent, so realpath stays on '/' "
                       "(liba MKP_POP refuses to pop it), the same "
                       "answer a POSIX realpath gives.")),
]





# ======================================================================
# tsort -- XCU tsort.html. Host-oracled where GNU and BSD cannot
# possibly disagree (a single chain has no tie to break); `hand=`
# wherever this build's own first-appearance tie-break (see
# src/bin/tsort.s's own header -- this tree follows GNU, not BSD,
# measured live: this host's own BSD tsort visibly uses a different
# order) would diverge from a live BSD run.
# ======================================================================
TSORT_CASES = [
    C('tsort', 'a chain has one order regardless of tie-break',
      'tsort ... write a totally ordered list of items...',
      ['@F@'], files={'F': ['a b', 'b c']}),
    C('tsort', 'a diamond: BSD and this build tie-break differently',
      'Among items with no remaining predecessor, ... order is '
      'unspecified.',
      ['@F@'], files={'F': ['a b', 'a c', 'b d', 'c d']},
      hand=dict(stdout=['a', 'b', 'c', 'd'], rc=0,
                reason="this build scans node 0 upward at every "
                       "step (tsort.s's own FINDFREE), which is "
                       "exactly first-appearance order (GNU's "
                       "tie-break) -- this host's own BSD tsort "
                       "printed 'a c b d' for the identical input "
                       "(measured live), a different, equally "
                       "spec-legal order.")),
    C('tsort', 'a self-pair token declares a lone node',
      '"a a" ... a node with no edge.',
      ['@F@'], files={'F': ['a a']}),
    C('tsort', 'an isolated pair set: two independent chains',
      'Among items with no remaining predecessor, ... order is '
      'unspecified.',
      ['@F@'], files={'F': ['a b', 'c d']},
      hand=dict(stdout=['a', 'b', 'c', 'd'], rc=0,
                reason="same tie-break divergence as the diamond "
                       "row above: this build's scan-from-0 always "
                       "lets a freshly-freed low-index node (b, "
                       "freed by a) cut ahead of an "
                       "always-free-from-the-start higher-index one "
                       "(c) -- this host's own BSD tsort printed "
                       "'c a d b' for the identical input (measured "
                       "live).")),
    C('tsort', 'no operand reads standard input',
      "If no file operands are specified, ... the standard input "
      "shall be used.",
      [], files={'IN': ['a b', 'b c']}, stdin='IN'),
    C('tsort', 'an odd number of tokens is a hard refusal',
      '>0 An error occurred.',
      ['@F@'], files={'F': ['a b c']},
      hand=dict(stdout=[], rc=1,
                reason="tsort.s's own PARSE leaves PENDING set on "
                       "an unpaired trailing token, exit 1, nothing "
                       "printed -- matching this host's own BSD "
                       "tsort ('tsort: odd data count', rc=1, no "
                       "stdout, verified live) even though the "
                       "diagnostic wording differs (never compared "
                       "-- see this suite's own module docstring).")),
    C('tsort', 'a cycle forces an order and exits 1',
      'a cycle ... [POSIX leaves recovery behavior unspecified]',
      ['@F@'], files={'F': ['a b', 'b a']},
      hand=dict(stdout=['a', 'b'], rc=1,
                reason="tsort.s's own forced-pick rule (first "
                       "still-unresolved node in table order) is "
                       "fully deterministic on a 2-node mutual "
                       "cycle: 'a' is forced first (breaking the "
                       "b->a edge), which frees 'b'. This host's "
                       "own BSD tsort printed 'b a' and exited 0 "
                       "for the identical input (measured live) -- "
                       "a different order AND a different exit "
                       "status, so no host can oracle this row; the "
                       "expectation is this build's own documented "
                       "cycle contract (src/bin/tsort.s's header), "
                       "matching the task brief's own GNU-exit-1 "
                       "instruction.")),
]


# ======================================================================
# pr -- XCU pr.html. `-t` rows (no header/trailer/pagination at all)
# are ordinary host-oracled cases, byte-exact against this host's own
# BSD pr (verified live before writing pr.s). Every row that DOES
# print a header is `hand=`, and NEVER against the raw stdout: the
# header's own date is the file's real last-modification time (or
# the current time, for stdin) -- a2til's own write_file() stamps
# datetime.now(), so no two runs of this suite's OWN staging can ever
# agree on that string, on any host. Each such row's `post` OVERWRITES
# OUT with a GREP -c count of a distinctive, DATE-FREE substring
# before the framework's own stdout comparison ever runs, so what
# gets compared is a deterministic shape fact (a title appeared once;
# a skipped page's number never appears; a reset page number appeared
# once per file), not the header's literal text -- see this file's
# own module docstring and src/bin/pr.s's own header for the
# mechanism this proves.
# ======================================================================
PR_CASES = [
    C('pr', '-t suppresses header/trailer/pagination entirely',
      '-t ... Write neither the five-line identifying header ... '
      'nor the five-line trailer ...',
      ['-t', '@F@'], files={'F': ['a', 'b', 'c']}),
    C('pr', '-t -n numbers each line, default width 5 and a tab',
      '-n[char][width] ... provide width digit line numbering ...',
      ['-t', '-n', '@F@'], files={'F': ['a', 'b', 'c']}),
    C('pr', '-t -n:3 sets an explicit separator and width',
      '-n[char][width] ... char ... width ...',
      ['-t', '-n:3', '@F@'], files={'F': ['a', 'b', 'c']}),
    C('pr', '-t -d double-spaces the content',
      '-d ... Produce output that is double spaced ...',
      ['-t', '-d', '@F@'], files={'F': ['a', 'b', 'c']}),
    C('pr', '-t -o 4 indents every line by 4 spaces',
      '-o offset ... Each line of output shall be preceded by '
      'offset <space> characters ...',
      ['-t', '-o', '4', '@F@'], files={'F': ['a', 'b', 'c']}),
    C('pr', '-l 10 on a short file falls back to the -t shape',
      '-l lines ... Override the 66-line default ...',
      ['-l', '10', '@F@'],
      files={'F': [str(i) for i in range(1, 16)]},
      hand=dict(
          stdout=[str(i) for i in range(1, 16)], rc=0,
          reason="a page length of 10 leaves no room for even one "
                 "content line under a 5-line header and a "
                 "same-size trailer (BODYCAP = lines-10 = 0), so "
                 "pr.s falls back to the -t shape entirely -- "
                 "matching this host's own BSD pr EXACTLY at this "
                 "boundary (measured live: `pr -l 10` on the "
                 "identical 15-line file prints no header at all, "
                 "just the 15 lines straight through, rc=0) -- not "
                 "host-oracled only because the harness's own "
                 "comparator re-runs the host oracle live rather "
                 "than trusting a single captured measurement, and "
                 "this exact edge is cheaper to pin by hand than to "
                 "re-justify every run.")),
    C('pr', '-h replaces the filename in the header',
      '-h header ... Use header ... in place of the pathname ...',
      ['-h', 'TITLE', '@F@'], files={'F': ['x']},
      post=[['GREP', '-c', Q('TITLE'), 'OUT', '>', 'OUT2'],
            ['CP', 'OUT2', 'OUT']],
      hand=dict(stdout=['1'], rc=0,
                reason="the header's own date is real wall-clock "
                       "time and cannot be byte-matched across "
                       "runs (see this table's own header); this "
                       "row overwrites OUT with GREP -c's count of "
                       "the TITLE string -h's own text puts in the "
                       "header, proving the substitution happened "
                       "without asserting the date around it.")),
    C('pr', '+page skips every page before N',
      '+page ... Begin output at page number page ...',
      ['+2', '@F@'], files={'F': [str(i) for i in range(1, 61)]},
      post=[['GREP', '-c', Q('Page 2'), 'OUT', '>', 'OUT2A'],
            ['GREP', '-c', Q('Page 1'), 'OUT', '>', 'OUT2B'],
            ['CAT', 'OUT2A', 'OUT2B', '>', 'OUT']],
      hand=dict(stdout=['1', '0'], rc=0,
                reason="60 lines is exactly two default (66-line) "
                       "pages; +2 skips page 1's header/body/"
                       "trailer entirely while still consuming its "
                       "input (page 2's own content is lines 57-60, "
                       "unaffected). Overwrites OUT with two GREP "
                       "-c counts -- 'Page 2' appears once, 'Page "
                       "1' appears zero times -- proving the skip "
                       "without the date.")),
    C('pr', 'multiple FILE operands each start their own page 1',
      'pr ... file ...',
      ['@F1@', '@F2@'], files={'F1': ['hi'], 'F2': ['bye']},
      post=[['GREP', '-c', Q('Page 1'), 'OUT', '>', 'OUT2'],
            ['CP', 'OUT2', 'OUT']],
      hand=dict(stdout=['2'], rc=0,
                reason="each file operand gets its own independent "
                       "pagination (measured live against this "
                       "host's own BSD pr): 'Page 1' appears once "
                       "per file, twice total, proving the reset "
                       "without the date.")),
    C('pr', 'no file operand reads standard input',
      "If no file operands are specified, ... the standard input "
      "shall be used.",
      [], files={'IN': ['x', 'y']}, stdin='IN',
      post=[['GREP', '-c', Q('Page 1'), 'OUT', '>', 'OUT2'],
            ['CP', 'OUT2', 'OUT']],
      hand=dict(stdout=['1'], rc=0,
                reason="proves pr ran its normal paginated path on "
                       "stdin (one page, no crash on the blank "
                       "filename field) without asserting the "
                       "date.")),
    # ------------------------------------------------------------
    # 2026-10-08: the column engine (src/bin/prcol.s, prmrg.s,
    # prout.s). The seven rows that used to be held red here are
    # retired below (known_gap=None; each keeps its old finding in
    # the comment above it). Fixtures are chosen so BSD and GNU
    # AGREE (docs/POSIX-PR-NOTES.md has the measured disagreements:
    # how a short last page is balanced across columns, -m with a
    # short file, -n in columns, -s with an explicit -w); the rows
    # where they cannot agree are `hand=` with the reason.
    # Page-mode rows use norm='prhdr' (header date/layout differ).
    # ------------------------------------------------------------
    # was a KNOWN GAP: "'-3' fell to the usage path, exit 2."
    C('pr', '-column multi-column output (down, then across)',
      '-column ... The number of columns of text to write on each '
      'page ...',
      ['-3', '@F@'], files={'F': ['a', 'b', 'c']}, norm='prhdr'),
    # was a KNOWN GAP: "'m' was not in OPTPARSE's recognized set."
    C('pr', '-m merge: one column per file',
      '-m ... Merge files, one per column ...',
      ['-m', '@F1@', '@F2@'], files={'F1': ['a'], 'F2': ['b']},
      norm='prhdr'),
    # was a KNOWN GAP: "'a' was not in OPTPARSE's recognized set."
    C('pr', '-a across-column ordering',
      '-a ... Modify the effect of the - column option ...',
      ['-a', '-3', '@F@'], files={'F': ['a', 'b', 'c']},
      norm='prhdr'),
    # was a KNOWN GAP: "'F' was not in OPTPARSE's recognized set."
    C('pr', '-F form-feed page separator',
      '-F ... Use a <form-feed> ... rather than the default ...',
      ['-F', '@F@'], files={'F': ['a']}, norm='prhdr'),
    # was a KNOWN GAP: "'e' was not in OPTPARSE's recognized set."
    C('pr', '-e input tab expansion',
      '-e[char][gap] ... Expand ... <tab> characters ...',
      ['-e', '@F@'], files={'F': ['a\tb']}, norm='prhdr'),
    # was a KNOWN GAP: "'i' was not in OPTPARSE's recognized set."
    C('pr', '-i output tab compression',
      '-i[char][gap] ... replace <space> characters with <tab> '
      'characters ...',
      ['-i', '@F@'], files={'F': ['a']}, norm='prhdr'),
    # was a KNOWN GAP: "'s' was not in OPTPARSE's recognized set."
    C('pr', '-s column separator',
      '-s[char] ... separate text columns by ... char ...',
      ['-s', '@F@'], files={'F': ['a']}, norm='prhdr'),

    # ---- down / across, no page furniture (-t) ----
    C('pr', '-t -3 fills columns down (3 x 3)',
      '-column ... written down each column in the order in which '
      'the text is received',
      ['-t', '-3', '@F@'], files={'F': list('abcdefghi')}),
    C('pr', '-t -2 down, uneven halves (4 + 3)',
      '-column ... When used with -t, use the minimum number of '
      'lines to write the output.',
      ['-t', '-2', '@F@'], files={'F': list('abcdefg')}),
    C('pr', '-t -a -3 fills rows across (3 x 3)',
      '-a ... Modify the effect of the -column option so that the '
      'columns are filled across the page',
      ['-t', '-a', '-3', '@F@'], files={'F': list('abcdefghi')}),
    C('pr', '-t -a -3 with a short last row',
      '-a ... filled across the page in a round-robin order',
      ['-t', '-a', '-3', '@F@'], files={'F': list('abcdefg')}),
    C('pr', '-t -3 -a given in the other order',
      '-a ... Modify the effect of the -column option',
      ['-t', '-3', '-a', '@F@'], files={'F': list('abcdefg')}),
    C('pr', '-t -5 -w 20: cells are 3 wide (text width rule)',
      '-w width ... Set the width of the line to width column '
      'positions for multiple text-column output only.',
      ['-t', '-5', '-w', '20', '@F@'],
      files={'F': ['abcdef'] * 10}),
    C('pr', '-t -3 -w 30 truncates every cell, last column too',
      '-column ... lines longer than the column are truncated',
      ['-t', '-3', '-w', '30', '@F@'],
      files={'F': ['abcdefghijklmnopqrstuvwxyz', 'short',
                   '0123456789012345678901234567890123456789']}),
    C('pr', '-t -2 -w 30 truncates (two columns, four lines)',
      '-w width ...',
      ['-t', '-2', '-w', '30', '@F@'],
      files={'F': ['abcdefghijklmnopqrstuvwxyz', 'short',
                   '0123456789012345678901234567890123456789',
                   'last']}),
    C('pr', '-t -3 text of 22, 23, 24 chars: the tab-stop boundary',
      '-column ... column width (line width - separators) / '
      'columns',
      ['-t', '-3', '@F@'],
      files={'F': ['a' * 22, 'b' * 23, 'c' * 24] * 3}),
    C('pr', '-t -2 text of 35 and 36 chars: the cell boundary',
      '-column ...',
      ['-t', '-2', '@F@'],
      files={'F': ['a' * 35, 'b' * 36, 'c' * 34, 'd' * 36]}),
    C('pr', '-t -3 -s: separator replaces the padding',
      '-s[char] ... Separate text columns by the single character '
      'char instead of the appropriate number of <space>s',
      ['-t', '-3', '-s:', '@F@'], files={'F': list('abcdefghi')}),
    C('pr', '-t -3 -s alone separates with a tab',
      '-s[char] ... (default for char is the <tab> character)',
      ['-t', '-3', '-s', '@F@'], files={'F': list('abcdefghi')}),
    C('pr', '-t -a -2 -s, across with a separator',
      '-s[char] ...',
      ['-t', '-a', '-s,', '-2', '@F@'],
      files={'F': list('abcdef')}),
    C('pr', '-t -3 -d double-spaces the rows',
      '-d ... Produce output that is double spaced.',
      ['-t', '-3', '-d', '@F@'], files={'F': list('abcdefghi')},
      hand=dict(
          stdout=['a\t\t\td\t\t\tg', '', 'b\t\t\te\t\t\th', '',
                  'c\t\t\tf\t\t\ti', ''], rc=0,
          reason="a blank line follows EVERY row, the last included "
                 "(BSD, and this tree's single-column -d); GNU "
                 "leaves out the one after the last row (measured "
                 "2026-10-08 on coreutils 9.1), so neither host "
                 "can be the oracle for both rigs.")),
    C('pr', '-t -3 -o 4 indents every row',
      '-o offset ...',
      ['-t', '-3', '-o', '4', '@F@'], files={'F': list('abcdefghi')}),
    C('pr', '-t -3 -l 3: pages of three rows, exact fit (18 lines)',
      '-l lines ... text columns never exceed the page length',
      ['-t', '-3', '-l', '3', '@F@'],
      files={'F': [str(i) for i in range(1, 19)]}),
    C('pr', '-t -3 -l 3: one line over a full page (10 lines)',
      '-l lines ...',
      ['-t', '-3', '-l', '3', '@F@'],
      files={'F': [str(i) for i in range(1, 11)]}),
    C('pr', '-t -3 reads standard input',
      'If no file operands are specified, ... the standard input '
      'shall be used.',
      ['-t', '-3'], files={'IN': list('abcdef')}, stdin='IN'),
    C('pr', '-t -3 with an empty file prints nothing',
      '-column ...',
      ['-t', '-3', '@F@'], files={'F': []}),
    C('pr', '-t -1 is the single-column shape',
      '-column ... (the default shall be 1)',
      ['-t', '-1', '@F@'], files={'F': ['a', 'b']}),

    # ---- page mode with columns ----
    C('pr', '-3 -l 20: 31 lines, a full page and a one-line page',
      '-column ... -l lines ...',
      ['-3', '-l', '20', '-h', 'T', '@F@'],
      files={'F': [str(i) for i in range(1, 32)]}, norm='prhdr'),
    C('pr', '-a -3 -l 20: across, two pages',
      '-a ...',
      ['-a', '-3', '-l', '20', '-h', 'T', '@F@'],
      files={'F': [str(i) for i in range(1, 32)]}, norm='prhdr'),
    C('pr', '-2 -d -l 14: double-spaced rows, two pages',
      '-d ...',
      ['-2', '-d', '-l', '14', '-h', 'T', '@F@'],
      files={'F': list('abcdefg')}, norm='prhdr'),
    C('pr', '-3 -l 11: one row per page',
      '-l lines ...',
      ['-3', '-l', '11', '-h', 'T', '@F@'],
      files={'F': list('abcdefg')}, norm='prhdr'),
    C('pr', '-3 -l 10 falls back to the -t shape',
      '-l lines ...',
      ['-3', '-l', '10', '@F@'], files={'F': list('abcdefghi')}),
    C('pr', '-t -a -2 -o 3: the offset is in every row',
      '-o offset ...',
      ['-t', '-a', '-2', '-o', '3', '@F@'],
      files={'F': list('abcdefg')}),

    # ---- -F ----
    C('pr', '-F -l 12 replaces the page padding with a form feed',
      '-F ... Use a <form-feed> character for new pages, instead '
      'of the default behavior that uses a sequence of <newline> '
      'characters.',
      ['-F', '-l', '12', '-h', 'T', '@F@'],
      files={'F': [str(i) for i in range(1, 6)]}, norm='prhdr'),
    C('pr', '-F ends an exactly full page with its form feed',
      '-F ...',
      ['-F', '-l', '12', '-h', 'T', '@F@'],
      files={'F': ['a', 'b', 'c', 'd']}, norm='prhdr'),
    C('pr', '-F -3 -l 20: columns and form feeds',
      '-F ...',
      ['-F', '-3', '-l', '20', '-h', 'T', '@F@'],
      files={'F': [str(i) for i in range(1, 32)]}, norm='prhdr'),
    C('pr', '-t -F writes no form feed (no pages)',
      '-F ... -t ...',
      ['-t', '-F', '@F@'], files={'F': ['a', 'b', 'c']},
      hand=dict(
          stdout=['a', 'b', 'c'], rc=0,
          reason="-t turns pagination off, so there are no page "
                 "boundaries to put a form feed at. GNU agrees; "
                 "BSD writes a form feed after the last line "
                 "anyway (measured 2026-10-08), so neither host "
                 "can be the oracle for both rigs.")),

    # ---- -e / -i ----
    C('pr', '-t -e expands tabs to every 8th column',
      '-e[char][gap] ... default gap 8',
      ['-t', '-e', '@F@'],
      files={'F': ['a\tb', 'abcdefg\th', 'abcdefgh\ti', '\tz']}),
    C('pr', '-t -e4 expands to every 4th column',
      '-e[char][gap] ...',
      ['-t', '-e4', '@F@'], files={'F': ['a\tb', 'abc\td', 'abcd\te']}),
    C('pr', '-t without -e leaves a tab alone',
      '-e ... (not assumed for a single column)',
      ['-t', '@F@'], files={'F': ['a\tb']}),
    C('pr', '-t -i contracts runs of spaces to tabs',
      '-i[char][gap] ...',
      ['-t', '-i', '@F@'],
      files={'F': ['abcdefg h', 'abcdefg  h', 'abcdefgh i',
                   'x       y', 'a  b   c        d']}),
    C('pr', '-t -i drops trailing spaces',
      '-i[char][gap] ...',
      ['-t', '-i', '@F@'],
      files={'F': ['ab      cd  ', 'ab   ', '   ', 'x y']}),
    C('pr', '-t -i3 contracts to every 3rd column',
      '-i[char][gap] ...',
      ['-t', '-i3', '@F@'], files={'F': ['abcdefg  h', 'ab   cd']}),
    C('pr', '-t -i: uses the given character instead of a tab',
      '-i[char][gap] ...',
      ['-t', '-i:', '@F@'], files={'F': ['a  b   c        d', 'x   y']}),
    C('pr', '-t -e -i together',
      '-e ... -i ...',
      ['-t', '-e', '-i', '@F@'], files={'F': ['a\t\tb', 'abc\td']}),
    C('pr', '-t -3 -e expands before the columns are cut',
      '-e ... Expand ... before ... the columns',
      ['-t', '-3', '-e', '@F@'],
      files={'F': ['a\tb', 'c\td', 'e\tf']}),

    # ---- -m ----
    C('pr', '-t -m two files, equal length',
      '-m ... Merge files, one per column',
      ['-t', '-m', '@F1@', '@F2@'],
      files={'F1': list('abc'), 'F2': ['x1', 'x2', 'x3']}),
    C('pr', '-t -m three files',
      '-m ...',
      ['-t', '-m', '@F1@', '@F2@', '@F3@'],
      files={'F1': list('abc'), 'F2': ['x1', 'x2', 'x3'],
             'F3': ['h1', 'h2', 'h3']}),
    C('pr', '-t -m -s: separator',
      '-s[char] ...',
      ['-t', '-m', '-s:', '@F1@', '@F2@'],
      files={'F1': list('abc'), 'F2': ['x1', 'x2', 'x3']}),
    C('pr', '-t -m -w 30 truncates each cell',
      '-w width ...',
      ['-t', '-m', '-w', '30', '@F1@', '@F2@'],
      files={'F1': ['abcdefghijklmnopqrstuvwxyz', 'short'],
             'F2': ['0123456789012345678901234567890123456789',
                    'tail']}),
    C('pr', '-t -m -n numbers the merged rows once',
      '-n ... -m',
      ['-t', '-m', '-n', '@F1@', '@F2@'],
      files={'F1': list('abc'), 'F2': ['x1', 'x2', 'x3']},
      hand=dict(
          stdout=['    1\ta\t\t\t    x1', '    2\tb\t\t\t    x2',
                  '    3\tc\t\t\t    x3'], rc=0,
          reason="one number per merged row, before the first "
                 "file's text. The second column stays at its own "
                 "column start (72 / 2 = 36); BSD starts it at 37 "
                 "and GNU at 40 (measured 2026-10-08), so neither "
                 "is the oracle.")),
    C('pr', '-m -l 12: merged pages of two rows',
      '-m ... -l lines ...',
      ['-m', '-l', '12', '-h', 'T', '@F1@', '@F2@'],
      files={'F1': list('abcd'), 'F2': ['w', 'x', 'y', 'z']},
      norm='prhdr'),
    C('pr', '-t -m with five files (the cap)',
      '-m ...',
      ['-t', '-m'] + ['@F%d@' % k for k in range(1, 6)],
      files={'F%d' % k: ['f%d' % k] for k in range(1, 6)}),
    C('pr', '-t -m reads standard input for the - operand',
      'A <hyphen-minus> ... shall be taken to be the standard input',
      ['-t', '-m', '@F1@', '-'], files={'F1': list('ab'),
                                          'IN': ['x', 'y']},
      stdin='IN'),
    C('pr', '-m refuses -column (exit 1, nothing written)',
      '-m ... This option should not be used with -column',
      ['-t', '-m', '-2', '@F1@', '@F2@'],
      files={'F1': ['a'], 'F2': ['b']}),

    # ---- rows where BSD and GNU cannot agree: hand= from the XCU ----
    C('pr', '-t -3 over ten lines: columns are filled left first',
      '-column ... Whether or not text columns are produced with '
      'identical vertical lengths is unspecified',
      ['-t', '-3', '@F@'], files={'F': [str(i) for i in range(1, 11)]},
      hand=dict(
          stdout=['1\t\t\t5\t\t\t9', '2\t\t\t6\t\t\t10', '3\t\t\t7',
                  '4\t\t\t8'], rc=0,
          reason="XCU leaves the balance of a short last page "
                 "unspecified, and the hosts differ: BSD fills the "
                 "left columns first (4, 4, 2 -- this row), GNU "
                 "balances (4, 3, 3). Both use 4 rows. maux "
                 "follows BSD; the host-oracled rows above use "
                 "fixtures both agree on.")),
    C('pr', '-t -m with a short file: its cell is absent, the rest '
            'keep their column',
      '-m ... Merge files, one per column',
      ['-t', '-m', '@F1@', '@F2@'],
      files={'F1': list('abcd'), 'F2': ['x1', 'x2']},
      hand=dict(
          stdout=['a\t\t\t\t    x1', 'b\t\t\t\t    x2', 'c', 'd'],
          rc=0,
          reason="XCU does not say what -m writes for a file that "
                 "has run out. BSD stops the row after the last "
                 "present cell (this row); GNU pads the row to "
                 "full width with trailing tabs/spaces. maux "
                 "follows BSD.")),
    C('pr', '-t -m with a short MIDDLE file keeps the later column',
      '-m ...',
      ['-t', '-m', '@F1@', '@F2@', '@F3@'],
      files={'F1': list('ab'), 'F2': ['x'], 'F3': ['h1', 'h2']},
      hand=dict(
          stdout=['a\t\t\tx\t\t\th1', 'b\t\t\t\t\t\th2'], rc=0,
          reason="measured on BSD: an absent middle cell still "
                 "occupies its column, so the third file's text "
                 "stays at its own column start (width 72 / 3 = "
                 "24: 'b' then 23 spaces to column 48 = tabs at "
                 "8, 16, 24, 32, 40, 48 -> six tabs).")),
    C('pr', '-t -n -3 numbers every cell (XCU), tab after the number',
      '-n[char][width] ... In multi-column output the number '
      'occupies the first width positions of each column',
      ['-t', '-n', '-3', '@F@'], files={'F': list('abcdefghi')},
      hand=dict(
          stdout=['    1\ta\t\t    4\td\t\t    7\tg',
                  '    2\tb\t\t    5\te\t\t    8\th',
                  '    3\tc\t\t    6\tf\t\t    9\ti'], rc=0,
          reason="GNU's layout (and the XCU's wording: each column "
                 "of text is numbered). BSD pads the number "
                 "differently after the first column "
                 "('      5 d'), so it cannot be the oracle.")),
    C('pr', '-t -3 -s with -w: the cell width follows the XCU rule',
      '-s[char] ... -w width ...',
      ['-t', '-3', '-s', '-w', '30', '@F@'],
      files={'F': ['abcdefghijklmnopqrstuvwxyz', 'short',
                   '012345678901234567890']},
      hand=dict(
          stdout=['abcdefghi\tshort\t012345678'], rc=0,
          reason="width 30, 3 columns, 2 separators: (30 - 2) / 3 = "
                 "9 text columns (the XCU rule; BSD agrees). GNU "
                 "keeps 10 under -s, so it cannot be the oracle.")),

    # ---- the loud failures (no host analogue: these are OUR limits)
    C('pr', 'a column page over the line table fails loudly',
      'maux limit: one page of columns holds at most 1024 lines',
      ['-t', '-l', '250', '-8', '@F@'], files={'F': ['a', 'b']},
      hand=dict(
          stdout=[], rc=1,
          reason="250 rows x 8 columns = 2000 lines per page, over "
                 "the 1024-line table: exit 1 with a message, "
                 "nothing written. A host prints the two lines.")),
    C('pr', '-m with six files fails cleanly (cap is five)',
      'maux limit: -m takes at most 5 files',
      ['-t', '-m'] + ['@F%d@' % k for k in range(1, 7)],
      files={'F%d' % k: ['f%d' % k] for k in range(1, 7)},
      hand=dict(
          stdout=[], rc=1,
          reason="a process has 8 fd-table entries (PCB_FDTABLE) "
                 "and stdin, stdout and stderr hold three, so five "
                 "FILE operands is what fits; the sixth is refused "
                 "BEFORE anything is opened or written: exit 1, "
                 "nothing on stdout. A host merges all six. ('-' is "
                 "stdin and costs no slot.)")),
    C('pr', '-w 255 without -s is refused (columns are 8-bit)',
      'maux limit: columns are tracked in 8 bits',
      ['-t', '-2', '-w', '255', '@F@'], files={'F': ['a', 'b']},
      hand=dict(
          stdout=[], rc=1,
          reason="-w 255 without -s: exit 1 with a message, nothing "
                 "written (documented in the man page). -s lifts the "
                 "limit because separated columns need no padding.")),
    C('pr', '-w 300 does not fit a number and is a usage error',
      'maux limit: option numbers are 8-bit',
      ['-t', '-2', '-w', '300', '@F@'], files={'F': ['a', 'b']},
      hand=dict(
          stdout=[], rc=2,
          reason="PARSEDEC reports a value past 255 instead of "
                 "wrapping it (300 used to read as 44): usage "
                 "error, exit 2, nothing written. A host accepts it.")),
]


# ======================================================================
# pathchk -- XCU pathchk.html. Rows where this build's own limits
# cannot diverge from the host's (a plain -p/-P portability check, or
# a name well inside every limit on both sides) are host-oracled;
# rows that depend on THIS tree's own smaller limits (15/64 instead
# of a host filesystem's 255/1024-ish NAME_MAX/PATH_MAX) are `hand=`.
# ======================================================================
PATHCHK_CASES = [
    C('pathchk', 'a good name passes with no diagnostic',
      '0 ... every pathname was ... valid.',
      [Q('GOODNAME')]),
    C('pathchk', 'a 16-char component exceeds this tree\'s 15-char '
                'limit',
      '>0 An error occurred.',
      [Q('ABCDEFGHIJKLMNOP')],
      hand=dict(stdout=[], rc=1,
                reason="ProDOS's own directory-entry name_length "
                       "field is 4 bits wide (15 max, PC_COMPMAX in "
                       "src/bin/pathchk.s) -- this host's own "
                       "pathchk has no such limit for the DEFAULT "
                       "check (NAME_MAX is filesystem-dependent and "
                       "far larger; verified live: this exact "
                       "16-character name passes on this Mac, "
                       "rc=0).")),
    C('pathchk', '-P flags a component beginning with a hyphen',
      '-P ... a pathname component that begins with a <hyphen-minus> '
      '... shall generate a diagnostic',
      ['-P', Q('sub/-bad')]),
    C('pathchk', '-P flags an empty pathname',
      '-P ... an empty string ... shall generate a diagnostic',
      ['-P', Q('')]),
    C('pathchk', '-p passes a 14-char portable component, the exact '
                'limit',
      '-p ... _POSIX_NAME_MAX (14) ...',
      ['-p', Q('ABCDEFGHIJKLMN')]),
    C('pathchk', '-p a 15-char component exceeds the portable limit '
                'by one',
      '-p ... _POSIX_NAME_MAX (14) ...',
      ['-p', Q('ABCDEFGHIJKLMNO')]),
    C('pathchk', '-p a space is outside the portable character set',
      '-p ... the portable filename character set ...',
      ['-p', Q('a b')]),
    C('pathchk', 'a nonexistent directory prefix is not an error',
      'It is not considered an error if a pathname argument '
      'contains a nonexistent component as long as a component by '
      'that name could be created.',
      [Q('nosuchdir123/leaf')],
      hand=dict(stdout=[], rc=0,
                reason="the XCU's own sentence, quoted above: a "
                       "MISSING intermediate directory is not a "
                       "failure on either side (verified live "
                       "against this host's own pathchk, rc=0) -- "
                       "hand-authored anyway because pathchk.s's "
                       "own default-mode length/charset checks "
                       "still run over 'nosuchdir123'/'leaf' "
                       "(both comfortably inside this tree's 15/64 "
                       "limits), so the row is really pinning that "
                       "existence and syntax are checked "
                       "independently, not just replaying a host "
                       "measurement that happens to agree.")),
    C('pathchk', 'several operands: one fails under -p, all are '
                'still checked',
      '>0 An error occurred.',
      ['-p', Q('GOOD1'), Q('a b'), Q('GOOD2')]),
]



# ======================================================================
# split -- XCU split.html. Piece CONTENTS are host-oracled via
# `results=` (a2til's own case-insensitive read matches split's
# lowercase odometer against the host's own lowercase suffixes with
# no special-casing needed -- see split.s's own header). Exhaustion
# has no common host construct (BSD/GNU split just keep going past
# 'zz' with a 3rd letter; this v1's fixed-width odometer does not),
# so that row is `hand=`.
# ======================================================================
SPLIT_CASES = [
    C('split', '-l 2 over 5 lines gives 3 pieces with the exact '
              'contents',
      '-l line_count ... Partition the file into files ... line_count '
      'lines each.',
      ['-l', '2', '@F@'],
      files={'F': ['one', 'two', 'three', 'four', 'five'],
             'xaa': None, 'xab': None, 'xac': None},
      results=['xaa', 'xab', 'xac']),
    C('split', '-b splits by raw byte count, a boundary may fall '
              'mid-line',
      '-b n ... Partition the file into ... n bytes each.',
      ['-b', '4', '@F@'],
      files={'F': ['abcdefgh'], 'xaa': None, 'xab': None, 'xac': None},
      results=['xaa', 'xab', 'xac']),
    C('split', '-a sets the suffix length',
      '-a suffix_length ... generated suffixes ... suffix_length '
      'characters',
      ['-l', '1', '-a', '3', '@F@'],
      files={'F': ['L1', 'L2', 'L3'],
             'xaaa': None, 'xaab': None, 'xaac': None},
      results=['xaaa', 'xaab', 'xaac']),
    C('split', 'suffix exhaustion (more pieces than -a can name) is '
              'an error',
      'the utility ... shall write a diagnostic message ... and '
      'exit with a value >0',
      ['-l', '1', '-a', '1', '@F@'],
      files={'F': [f'L{i}' for i in range(27)]},
      hand=dict(stdout=[], rc=1,
                reason="split.s's own SUFFEXHAUSTED path: -a 1 gives "
                       "26 single-letter suffixes ('a'..'z'), and 27 "
                       "lines need a 27th piece -- exit 1, the 26 "
                       "pieces already written stay (no host row: "
                       "BSD/GNU split just grow the suffix another "
                       "letter and keep going past 'zz', which this "
                       "v1's fixed-width odometer does not).")),
]


# ======================================================================
# csplit -- XCU csplit.html. BYTE COUNTS ON STDOUT ARE `hand=` (per
# task instructions, cksum's own precedent): maux's staged lines are
# CR-terminated and decoded before comparison, so a host-computed
# count is not the number this suite would compute either way --
# every row below is hand-computed straight from hilines() byte
# counts, verified against a LIVE /usr/bin/csplit on this host before
# writing csplit.s (each row's own note says what that run showed).
# The one row where stdout is trivially EMPTY on both sides (`-s`) is
# host-oracled instead, piece contents included.
# ======================================================================
CSPLIT_F6 = ['aaa', 'bbb', 'ccc', 'ddd', 'eee', 'fff']  # 4 B/line hilines
CSPLIT_MARK = ['fill0', 'MARK1', 'fill1', 'MARK2', 'fill2', 'MARK3',
               'fill3']                                 # 6 B/line hilines

CSPLIT_CASES = [
    C('csplit', 'a line-number argument splits before that line',
      'line_number ... Create ... up to but not including line_number.',
      ['@F@', '3'],
      files={'F': CSPLIT_F6, 'xx00': None, 'xx01': None},
      results=['xx00', 'xx01'],
      hand=dict(stdout=['8', '16'], rc=0,
                files={'xx00': ['aaa', 'bbb'],
                       'xx01': ['ccc', 'ddd', 'eee', 'fff']},
                reason="hand-computed over hilines(['aaa','bbb']) = "
                       "8 B and hilines(['ccc','ddd','eee','fff']) = "
                       "16 B; verified live against /usr/bin/csplit "
                       "(same split point, same two pieces).")),
    C('csplit', '/bre/ splits at the first line matching bre; the '
              'matched line starts the NEXT piece',
      '/bre/[offset] ... the line ... shall become the first line '
      'of the next section',
      ['@F@', Q('/eee/')],
      files={'F': CSPLIT_F6, 'xx00': None, 'xx01': None},
      results=['xx00', 'xx01'],
      hand=dict(stdout=['16', '8'], rc=0,
                files={'xx00': ['aaa', 'bbb', 'ccc', 'ddd'],
                       'xx01': ['eee', 'fff']},
                reason="hand-computed hilines() byte counts, 16 and "
                       "8; verified live against /usr/bin/csplit -- "
                       "the matched line ('eee') is NOT in xx00, "
                       "confirmed by running the host binary before "
                       "writing csplit.s's RUNSEG (its first cut, "
                       "before this row, put the match in the WRONG "
                       "piece -- fixed to match this).")),
    C('csplit', '/bre/+N shifts the cut N lines past the match',
      '/bre/+offset ... the offset ... from the line ... addressed',
      ['@F@', Q('/ccc/+1')],
      files={'F': CSPLIT_F6, 'xx00': None, 'xx01': None},
      results=['xx00', 'xx01'],
      hand=dict(stdout=['12', '12'], rc=0,
                files={'xx00': ['aaa', 'bbb', 'ccc'],
                       'xx01': ['ddd', 'eee', 'fff']},
                reason="hand-computed hilines() byte counts, 12 and "
                       "12; verified live against /usr/bin/csplit: "
                       "+1 moves the cut one line past the plain "
                       "(offset 0) point, so 'ccc' now ends xx00.")),
    C('csplit', '%bre% discards the span up to the match -- no '
              'piece file for it',
      '%bre%[offset] ... does not create a file for the selected '
      'section',
      ['@F@', Q('%ccc%')],
      files={'F': CSPLIT_F6, 'xx00': None, 'xx01': None},
      results=['xx00', 'xx01'],
      hand=dict(stdout=['16'], rc=0,
                files={'xx00': ['ccc', 'ddd', 'eee', 'fff'],
                       'xx01': None},
                reason="hand-computed hilines() byte count, 16; "
                       "verified live against /usr/bin/csplit -- "
                       "only ONE piece exists (the discarded 'aaa',"
                       "'bbb' span never became a file, and 'xx01' "
                       "does not exist).")),
    C('csplit', '{n} repeats the previous /bre/ n MORE times',
      '{n} ... Repeat the previous pattern n additional times.',
      ['@F@', Q('/MARK/'), Q('{2}')],
      files={'F': CSPLIT_MARK, 'xx00': None, 'xx01': None,
             'xx02': None, 'xx03': None},
      results=['xx00', 'xx01', 'xx02', 'xx03'],
      hand=dict(stdout=['6', '12', '12', '12'], rc=0,
                files={'xx00': ['fill0'],
                       'xx01': ['MARK1', 'fill1'],
                       'xx02': ['MARK2', 'fill2'],
                       'xx03': ['MARK3', 'fill3']},
                reason="hand-computed hilines() byte counts (6 B/"
                       "line here); verified live against /usr/bin/"
                       "csplit -- each repeat's own held match line "
                       "(e.g. 'MARK1') heads its OWN new piece "
                       "rather than being re-tested and held again "
                       "(csplitrn.s's own REPMODE, added after this "
                       "row's live run first showed 4 pieces where "
                       "an untested guess predicted an empty one).")),
    C('csplit', '-f/-n set the piece prefix and digit width',
      '-f prefix ... -n number ... the number of decimal digits',
      ['-f', 'Q', '-n', '3', '@F@', '3'],
      files={'F': CSPLIT_F6, 'Q000': None, 'Q001': None},
      results=['Q000', 'Q001'],
      hand=dict(stdout=['8', '16'], rc=0,
                files={'Q000': ['aaa', 'bbb'],
                       'Q001': ['ccc', 'ddd', 'eee', 'fff']},
                reason="hand-computed hilines() byte counts, 8 and "
                       "16; verified live against /usr/bin/csplit "
                       "(-f Q -n 3 names the pieces Q000/Q001).")),
    C('csplit', '-s suppresses the byte-count stdout',
      '-s ... Suppress ... the size ... of output files.',
      ['-s', '@F@', '3'],
      files={'F': CSPLIT_F6, 'xx00': None, 'xx01': None},
      results=['xx00', 'xx01']),
    C('csplit', 'a regex that never matches is an error; pieces '
              'removed by default',
      'If no line matches ... write a diagnostic message ... and '
      'exit',
      ['@F@', Q('/zzz/')], files={'F': CSPLIT_F6, 'xx00': None},
      results=['xx00'],
      hand=dict(stdout=[], rc=1, files={'xx00': None},
                reason="csplit.s's own REGEXERR/ERRCLEANUP path: "
                       "'zzz' never matches before EOF, so the "
                       "partial piece csplitrn.s's OPENPIECE already "
                       "created is DESTROYed and the run exits 1 -- "
                       "verified live against /usr/bin/csplit "
                       "(prints nothing to stdout, no xx00 survives, "
                       "exit 1).")),
    C('csplit', '-k keeps the partial piece on the same error',
      '-k ... do not remove output files ... created before ... '
      'detected an error',
      ['-k', '@F@', Q('/zzz/')],
      files={'F': CSPLIT_F6, 'xx00': None},
      results=['xx00'],
      hand=dict(stdout=[], rc=1,
                files={'xx00': ['aaa', 'bbb', 'ccc', 'ddd', 'eee',
                                'fff']},
                reason="same error as the row above, but -k: "
                       "verified live against /usr/bin/csplit -- "
                       "xx00 survives holding every line scanned "
                       "before EOF (the whole file, since 'zzz' "
                       "never matched), exit 1.")),
]


# ======================================================================
# join -- XCU join.html. Every row host-oracled against this host's
# own /usr/bin/join on JOININ-shaped fixtures already sorted on the
# join field; every row's fixture keys are unique on at least one
# side (this file's own module docstring note on duplicate-key
# ordering being spec-open).
# ======================================================================
JOIN_F1 = ['1 alpha', '2 beta', '3 gamma']
JOIN_F2 = ['1 uno', '2 dos', '3 tres']

JOIN_CASES = [
    C('join', 'the plain join: field 1 by default, blanks the '
             'separator',
      'join ... the join field ... the DEFAULT ... field one',
      ['@F1@', '@F2@'], files={'F1': JOIN_F1, 'F2': JOIN_F2}),
    C('join', '-t sets a single-character field separator, both '
             'sides',
      '-t char ... Use character ... as ... separator',
      ['-t', ':', '@F1@', '@F2@'],
      files={'F1': ['1:alpha', '2:beta', '3:gamma'],
             'F2': ['1:uno', '2:dos', '3:tres']}),
    C('join', '-1/-2 select a different join field per file',
      '-1 field_number ... -2 field_number',
      ['-1', '2', '-2', '1', '@F1@', '@F2@'],
      files={'F1': ['alpha 1', 'beta 2', 'gamma 3'], 'F2': JOIN_F2}),
    C('join', '-a 1 adds file1\'s unpaired lines to the output',
      '-a file_number ... add ... unpairable line',
      ['-a', '1', '@F1@', '@F2@'],
      files={'F1': ['1 alpha', '2 beta', '3 gamma', '4 delta'],
             'F2': JOIN_F2}),
    C('join', '-a 2 adds file2\'s unpaired lines to the output',
      '-a file_number ... add ... unpairable line',
      ['-a', '2', '@F1@', '@F2@'],
      files={'F1': JOIN_F1,
             'F2': ['1 uno', '2 dos', '3 tres', '4 quattro']}),
    C('join', '-v 1 prints ONLY file1\'s unpaired lines',
      '-v file_number ... produce a line for each unpairable line',
      ['-v', '1', '@F1@', '@F2@'],
      files={'F1': ['1 alpha', '2 beta', '3 gamma', '4 delta'],
             'F2': JOIN_F2}),
    C('join', '-o selects and orders output fields, 0 is the join '
             'field',
      '-o list ... 0 ... the join field',
      ['-o', '1.1,2.2,0', '@F1@', '@F2@'],
      files={'F1': JOIN_F1, 'F2': JOIN_F2}),
    C('join', '-e replaces an EMPTY -o field (the XCU/GNU rule; BSD '
             'differs)',
      '-e string ... replace ... empty ... output field',
      ['-a', '1', '-o', '1.1,2.2,0', '-e', 'X', '@F1@', '@F2@'],
      files={'F1': ['1 alpha', '2 beta', '4 delta'], 'F2': JOIN_F2},
      hand=dict(stdout=['1 uno 1', '2 dos 2', '4 X 4'], rc=0,
                reason="GNU and the XCU both apply -e ONLY through "
                       "-o (join.s's own header); BSD's own -e "
                       "differs (unconditional substitution outside "
                       "-o too), so this row is pinned to the XCU "
                       "wording rather than host-oracled against "
                       "this Mac's BSD join. Verified live against "
                       "this host's own /usr/bin/join for the "
                       "SHAPE (field 2.2 of the unpaired '4 delta' "
                       "record prints 'X') before pinning the exact "
                       "text.")),
    C('join', 'a line with no partner is simply absent (no -a)',
      'join ... without -a ... only paired lines',
      ['@F1@', '@F2@'],
      files={'F1': ['1 alpha', '2 beta', '4 delta'], 'F2': JOIN_F2}),
    C('join', '"-" names stdin for one operand',
      'file1 ... file2 ... A pathname of "-" ... standard input',
      ['-', '@F2@'], files={'F1': JOIN_F1, 'F2': JOIN_F2}, stdin='F1'),
]

CASES2 = (WC_CASES + TAIL_CASES + UNIQ_CASES + TR_CASES + SORT_CASES +
          OD_CASES + FIND_CASES + DIFF_CASES + LS_CASES + CPMVRM_CASES +
          DATE_CASES + TOUCH_CASES + DU_CASES + DF_CASES + TEE_CASES +
          ECHO_CASES +
          KILL_CASES + CUT_CASES + XARGS_CASES + PRINTF_CASES +
          BASENAME_CASES + DIRNAME_CASES + ENV_CASES +
          UUENCODE_CASES + UUDECODE_CASES +
          RMDIR_CASES + TTY_CASES + UNAME_CASES +
          CKSUM_CASES + PASTE_CASES + FOLD_CASES +
          EXPAND_CASES + UNEXPAND_CASES + NL_CASES +
          CAL_CASES + STRINGS_CASES + MAN_CASES +
          NOHUP_CASES + TIMEOUT_CASES + REALPATH_CASES +
          TSORT_CASES + PR_CASES + PATHCHK_CASES +
          SPLIT_CASES + CSPLIT_CASES + JOIN_CASES)

KNOWN_GAPS2 = [(c['tool'], c['name'], c['known_gap'])
               for c in CASES2 if c['known_gap']]
