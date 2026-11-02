#!/usr/bin/env python3
r"""posixutil_cases3.py -- round 3 of the POSIX.1-2024 conformance
gate: CASES3/KNOWN_GAPS3 for `test`/`[` (src/bin/testeval.s).
check_posixutil.py imports this module and appends CASES3/KNOWN_GAPS3
onto its own CASES/KNOWN_GAPS -- see that file's own docstring for the
shared METHOD, and posixutil_cases2.py's own docstring for why C()/Q()
are duplicated here rather than imported (avoids a circular import).

ORACLE: this Mac's own `/bin/test` (BSD), which happens to still
implement the removed-in-Issue-8 `-a`/`-o`/`( )` (verified live,
2026-09-14: `/bin/test a = a -o a = b -a a = b` -> 0, proving BSD's
`-a` still binds tighter than `-o`, same as testeval.s's own
grammar) -- so every primary testeval.s added can be host-oracled,
not hand-authored, EXCEPT the four named as KNOWN_GAPS3 below.

`-x`'s TRUE branch is NOT exercised here: this harness's own
stage_batch() (check_posixutil.py) always writes staged `files=`
entries as ProDOS file_type TXT ($04) -- there is no lever in the
shared C()/stage_batch() machinery to stage a SYS/BIN file, and
adding one for a single primary is out of proportion (a real
per-tool `files=` file_type override would want its own task). The
TRUE branch (`-x` on a BIN-typed file) is proven instead by
check-testev's own unit gate (src/test/testevtestb.s AV_X_ISBIN),
which pokes ProDOS file types directly. What IS exercised here is
`-x` FALSE on an ordinary (TXT, non-executable-by-default) file and
on a nonexistent path -- both agree with the host, since a freshly
staged file is not chmod +x on either side.

`-b -c -g -h -L -p -S -u`: one ordinary row each, an existing regular
file. Every one of these object types is absent from BOTH ProDOS
(maux's side) and this Mac's own scratch file (the host oracle never
creates a block/char special, a setuid/setgid file, a symlink, a
FIFO or a socket for an ordinary `open()`+`write()`), so the host
agrees with maux's constant-false rule for the RIGHT reason on each
side -- not a coincidence papered over, an actual absence on both.
"""


def C(tool, name, spec, argv, *, files=None, dirs=None, predirs=None,
      stdin=None, results=None, post=None, hand=None, known_gap=None,
      reset=None):
    return dict(tool=tool, name=name, spec=spec, argv=list(argv),
                files=files or {}, dirs=dirs or {},
                predirs=list(predirs or []), stdin=stdin,
                results=list(results or []), post=list(post or []),
                hand=hand, known_gap=known_gap, reset=reset)


def Q(word):
    return "'" + word + "'"


T = 'test'
FBODY = ['test file body']

CASES3 = [
    # ==================================================================
    # test -- XCU test.html / EXTENDED DESCRIPTION -- file primaries
    # ==================================================================
    C(T, '-f on a regular file (true)',
      '-f pathname True if pathname resolves to an existing directory '
      'entry for a regular file.',
      ['-f', '@F@'], files={'F': FBODY}),
    C(T, '-f on a directory (false)',
      '-f pathname ... regular file.',
      ['-f', '@D@'], dirs={'D': 'D'}, predirs=['D']),
    C(T, '-f on a nonexistent path (false)',
      '-f pathname ... regular file.',
      ['-f', '@NOPE@'], files={'NOPE': None}),
    C(T, '-d on a directory (true)',
      '-d pathname True if pathname resolves to an existing directory.',
      ['-d', '@D@'], dirs={'D': 'D'}, predirs=['D']),
    C(T, '-d on a nonexistent path (false)',
      '-d pathname ... existing directory.',
      ['-d', '@NOPE@'], files={'NOPE': None}),
    C(T, '-e on a regular file (true)',
      '-e pathname True if pathname resolves to an existing directory '
      'entry.',
      ['-e', '@F@'], files={'F': FBODY}),
    C(T, '-e on a nonexistent path (false)',
      '-e pathname ... existing directory entry.',
      ['-e', '@NOPE@'], files={'NOPE': None}),
    C(T, '-s on a file with data (true)',
      '-s pathname True if pathname resolves to an existing directory '
      'entry for a file with a size greater than zero.',
      ['-s', '@F@'], files={'F': FBODY}),
    C(T, '-s on a nonexistent path (false)',
      '-s pathname ... size greater than zero.',
      ['-s', '@NOPE@'], files={'NOPE': None}),
    C(T, '-r on a readable file (true)',
      '-r pathname True if pathname resolves to an existing directory '
      'entry for a file for which read permission is granted.',
      ['-r', '@F@'], files={'F': FBODY}),
    C(T, '-r on a nonexistent path (false)',
      '-r pathname ... read permission is granted.',
      ['-r', '@NOPE@'], files={'NOPE': None}),
    C(T, '-w on a writable file (true)',
      '-w pathname True if pathname resolves to an existing directory '
      'entry for a file for which write permission is granted.',
      ['-w', '@F@'], files={'F': FBODY}),
    C(T, '-w on a nonexistent path (false)',
      '-w pathname ... write permission is granted.',
      ['-w', '@NOPE@'], files={'NOPE': None}),
    C(T, '-x on a non-executable file (false)',
      '-x pathname True if pathname resolves to an existing directory '
      'entry for a file for which execute permission is granted. '
      '(TRUE branch proven by check-testev\'s own unit gate -- see '
      'this module\'s header.)',
      ['-x', '@F@'], files={'F': FBODY}),
    C(T, '-x on a nonexistent path (false)',
      '-x pathname ... execute permission is granted.',
      ['-x', '@NOPE@'], files={'NOPE': None}),
    C(T, '-b on a regular file (always false on ProDOS)',
      '-b pathname True if pathname resolves to an existing directory '
      'entry for a block special file. ProDOS has no block specials.',
      ['-b', '@F@'], files={'F': FBODY}),
    C(T, '-c on a regular file (always false on ProDOS)',
      '-c pathname ... character special file. ProDOS has no '
      'character specials.',
      ['-c', '@F@'], files={'F': FBODY}),
    C(T, '-g on a regular file (always false on ProDOS)',
      '-g pathname ... set-group-ID flag is set. ProDOS has no '
      'setgid bit.',
      ['-g', '@F@'], files={'F': FBODY}),
    C(T, '-h on a regular file (always false on ProDOS)',
      '-h pathname ... symbolic link. ProDOS has no symbolic links.',
      ['-h', '@F@'], files={'F': FBODY}),
    C(T, '-L on a regular file (always false on ProDOS)',
      '-L pathname ... symbolic link (same as -h). ProDOS has no '
      'symbolic links.',
      ['-L', '@F@'], files={'F': FBODY}),
    C(T, '-p on a regular file (always false on ProDOS)',
      '-p pathname ... FIFO special file. ProDOS has no FIFOs.',
      ['-p', '@F@'], files={'F': FBODY}),
    C(T, '-S on a regular file (always false on ProDOS)',
      '-S pathname ... socket. ProDOS has no sockets.',
      ['-S', '@F@'], files={'F': FBODY}),
    C(T, '-u on a regular file (always false on ProDOS)',
      '-u pathname ... set-user-ID flag is set. ProDOS has no '
      'setuid bit.',
      ['-u', '@F@'], files={'F': FBODY}),

    # ==================================================================
    # test -- string and integer primaries
    # ==================================================================
    C(T, '-z on a nonempty word (false)',
      '-z string True if the length of string is 0. (An actually '
      "empty operand is not exercised here -- typing a literal "
      "zero-length shell word through maux's own tokenizer is its "
      "own hazard; src/test/testevtestb.s's unit-level case table "
      "calls TEST_EVAL directly with a true empty string and proves "
      "-z there instead.)",
      ['-z', 'x']),
    C(T, '-n on a nonempty word (true)',
      '-n string True if the length of string is not 0.',
      ['-n', 'x']),
    C(T, 'string = string (true)',
      's1 = s2 True if the strings s1 and s2 are identical.',
      ['abc', '=', 'abc']),
    C(T, 'string = string (false)',
      's1 = s2 ... identical.',
      ['abc', '=', 'xyz']),
    C(T, 'string != string (true)',
      's1 != s2 True if the strings s1 and s2 are not identical.',
      ['abc', '!=', 'xyz']),
    C(T, 'string != string (false)',
      's1 != s2 ... not identical.',
      ['abc', '!=', 'abc']),
    C(T, 'n1 -eq n2 (true)',
      'n1 -eq n2 True if the integers n1 and n2 are algebraically '
      'equal.',
      ['3', '-eq', '3']),
    C(T, 'n1 -eq n2 (false)',
      'n1 -eq n2 ... algebraically equal.',
      ['3', '-eq', '4']),
    C(T, 'n1 -ne n2 (true)',
      'n1 -ne n2 True if the integers n1 and n2 are not algebraically '
      'equal.',
      ['3', '-ne', '4']),
    C(T, 'n1 -lt n2 (true)',
      'n1 -lt n2 True if the integer n1 is algebraically less than '
      'the integer n2.',
      ['3', '-lt', '4']),
    C(T, 'n1 -gt n2 (true)',
      'n1 -gt n2 True if the integer n1 is algebraically greater '
      'than the integer n2.',
      ['4', '-gt', '3']),
    C(T, 'n1 -le n2 (true, equal case)',
      'n1 -le n2 True if the integer n1 is algebraically less than '
      'or equal to the integer n2.',
      ['3', '-le', '3']),
    C(T, 'n1 -ge n2 (true, equal case)',
      'n1 -ge n2 True if the integer n1 is algebraically greater '
      'than or equal to the integer n2.',
      ['3', '-ge', '3']),
    C(T, 'non-integer operand is a syntax error (exit 2)',
      "If either n1 or n2 is not a valid integer... the test utility "
      "shall write a diagnostic message to standard error and shall "
      "exit with a status of 2 (diagnostic wording not gated -- BSD's "
      "own reads 'test: abc: bad number').",
      ['abc', '-eq', '3']),

    # ==================================================================
    # test -- `!`, `-a`/`-o` (with precedence), `( expr )` grouping.
    # docs/POSIX-GAPS.md's own `test` row priced these; the live XCU
    # page (fetched for this task) says Issue 8 REMOVED -a/-o/( ) as
    # obsolescent (Austin Group Defect 1330) -- shipped anyway, see
    # src/bin/testeval.s's header PROVENANCE NOTE for the full reason.
    # ==================================================================
    C(T, '! negates a true expression',
      '! expression True if expression is false. False if expression '
      'is true.',
      ['!', 'abc', '=', 'abc']),
    C(T, '! negates a false expression',
      '! expression ... False if expression is true.',
      ['!', 'abc', '=', 'xyz']),
    C(T, '-a is true when both operands are true',
      '(historical/BSD binary primary, removed from Issue 8\'s '
      'normative grammar but shipped -- see file header) e1 -a e2 '
      'True if both e1 and e2 are true.',
      ['abc', '=', 'abc', '-a', 'abc', '=', 'abc']),
    C(T, '-a is false when either operand is false',
      'e1 -a e2 ... both e1 and e2 are true.',
      ['abc', '=', 'xyz', '-a', 'abc', '=', 'abc']),
    C(T, '-o is true when either operand is true',
      '(historical/BSD binary primary, removed from Issue 8) e1 -o e2 '
      'True if either e1 or e2 is true.',
      ['abc', '=', 'abc', '-o', 'abc', '=', 'xyz']),
    C(T, '-o is false when both operands are false',
      'e1 -o e2 ... either e1 or e2 is true.',
      ['abc', '=', 'xyz', '-o', 'abc', '=', 'xyz']),
    C(T, '-a binds tighter than -o (T -o F -a F -> T)',
      "Historical test(1)/BSD precedence note (APPLICATION USAGE: "
      "'-a was specified as having higher precedence than -o'). "
      "T -o (F -a F) reads true; a naive left-to-right pass over "
      "(T -o F) -a F would read false instead -- this row picks "
      "operands where the two groupings DISAGREE, so it actually "
      "proves the precedence rather than being consistent with "
      "either reading by accident.",
      ['a', '=', 'a', '-o', 'a', '=', 'b', '-a', 'a', '=', 'b']),
    C(T, '-a binds tighter than -o (F -o T -a F -> F)',
      'Same precedence, operands rotated so the disagreeing '
      'grouping is exercised from the other side.',
      ['a', '=', 'b', '-o', 'a', '=', 'a', '-a', 'a', '=', 'b']),
    C(T, '( expr ) groups a true sub-expression',
      "(obsolescent XSI grouping, removed from Issue 8's normative "
      'grammar but shipped -- see file header) ( expression ) True '
      'if expression is true.',
      ['(', 'abc', '=', 'abc', ')']),
    C(T, '( expr ) groups a false sub-expression',
      '( expression ) ... True if expression is true.',
      ['(', 'abc', '=', 'xyz', ')']),
    C(T, '! ( expr -a expr ) negates a grouped conjunction',
      'Composes `!`, `( )` and `-a` in one expression: '
      '!(true -a false) reads true.',
      ['!', '(', 'abc', '=', 'abc', '-a', 'abc', '=', 'xyz', ')']),

    # ==================================================================
    # test -- 0/1-argument algorithm (XCU "the following algorithm")
    # ==================================================================
    C(T, '0 arguments is false',
      '0 arguments: Exit false (1).', []),
    C(T, '1 argument, non-null string is true',
      '1 argument: Exit true (0) if $1 is not null; otherwise, exit '
      'false.',
      ['abc']),
]

# ======================================================================
# KNOWN_GAPS3 -- real, named divergences from the host oracle. Every
# one of these documents WHY, and the scoring in check_posixutil.py
# requires each to stay red until the underlying gap closes.
# ======================================================================
CASES3 += [
    C(T, 'negative integer operands (-eq)',
      "test's `n1`/`n2` operands are conventionally signed decimal "
      "integers -- BSD's own test accepts a leading '-' (verified "
      "live: `/bin/test -1 -eq -1` -> 0). SHIPPED 2026-09-17: "
      "STR2NUM now accepts an optional leading '-' and two's-"
      "complements the magnitude; CMP16 became a real SIGNED 16-bit "
      "compare (N-xor-V over a genuine SBC, not the old unsigned "
      "hi-byte-then-lo-byte CMP chain) so `-lt`/`-gt`/etc. order "
      "negatives correctly too, not just `-eq`/`-ne`.",
      ['-1', '-eq', '-1']),
    C(T, 'negative integer operands (-lt, sign matters)',
      "n1 -lt n2 True if n1 is algebraically less than n2 -- proves "
      "CMP16's signed fix, not just STR2NUM's sign parse: -1 is "
      "algebraically LESS than 1, which an unsigned compare (where "
      "-1 reads as 65535) would get backwards.",
      ['-1', '-lt', '1']),
]

KNOWN_GAPS3 = [(c['tool'], c['name'], c['known_gap'])
               for c in CASES3 if c['known_gap']]
