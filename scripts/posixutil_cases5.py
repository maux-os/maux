#!/usr/bin/env python3
r"""posixutil_cases5.py -- CASES5/KNOWN_GAPS5 for `make`
(src/bin/make.s + makeread/makemac/makeinf/makerun.s), round 5.

A separate module for the same reason as rounds 2, 3 and 4: one gate,
one summary line, unchanged format, no single file growing past what
one person edits comfortably. check_posixutil.py imports this and
appends CASES5 onto its own CASES.

WHY ALMOST EVERY ROW IS `-n`, AND WHY THAT IS THE STRONG TEST RATHER
THAN THE WEAK ONE.

`make -n` prints the command it WOULD run and runs nothing. That makes
the printed line a byte-exact readout of the whole expansion
machinery -- macros, nested macros, command-line overrides, the
internal macros, which inference rule was chosen and with what stem --
against a host `make` that has to agree with it character for
character. Nothing is executed, so the recipes can name a command that
exists on NEITHER system (`ZORK`), which is what lets one fixture run
unchanged on both sides. A row that executed instead would be
comparing `/bin/ECHO` against `echo` and would have to be
hand-authored, which is a weaker assertion, not a stronger one.

`-r` IS PASSED ON EVERY INFERENCE ROW. GNU make ships a built-in
suffix list and a built-in rule for most of it; maux ships neither
(there is no cc to write one for). -r clears the host's, so both sides
start from the empty list the fixture then fills with `.SUFFIXES:`.
maux's own -r is accepted and does nothing, which is the same state.

THE ROWS THAT CANNOT USE THE ORACLE, and why, once rather than in each
`reason=`:

  * anything that RUNS a recipe -- the command differs by system.
  * -p, whose database format GNU never specified and maux prints in
    its own shape.
  * "nothing to do" paths: GNU writes `make: Nothing to be done for
    'X'.` and `make: 'X' is up to date.` on stdout; maux writes
    nothing at all. Every fixture below is therefore written so the
    requested target HAS work to do, and the two rows that test the
    quiet paths are hand-authored.
"""


def C(tool, name, spec, argv, *, files=None, dirs=None, predirs=None,
      stdin=None, results=None, post=None, hand=None, known_gap=None,
      reset=None, norm=None):
    return dict(tool=tool, name=name, spec=spec, argv=list(argv),
                files=files or {}, dirs=dirs or {},
                predirs=list(predirs or []), stdin=stdin,
                results=list(results or []), post=list(post or []),
                hand=hand, known_gap=known_gap, reset=reset, norm=norm)


#: Every fixture names its recipe command `ZORK`: a word that exists on
#: neither system, so `-n` is the only mode that can be run and the
#: rows cannot silently start depending on a host binary.
def MK(*lines):
    return list(lines)


#: The one sentence every hand-authored row here shares: the row
#: EXECUTES a recipe (or prints a database), so its output names
#: `/bin/...` where the host would name a bare command, and no
#: single expected string can be right on both systems. The expected
#: values below were read off a live run on the fast backend and are
#: checked against what POSIX specifies, not against another make.
_WHY = ('runs a real recipe: the command differs by system, so '
        'there is no shared oracle. Expected values are POSIX\'s own '
        'requirement -- the exit status, and whether anything was '
        'echoed -- read off a live fast-backend run.')
_WHY_STATUS = ('no shared oracle for the STATUS: POSIX pins only '
               '">0" for a make error and GNU uses 2 where this make '
               'uses 1 throughout. The stdout both produce is empty.')
_WHY_DB = ('-p has no specified format. POSIX asks for "the complete '
           'set of macro definitions and target descriptions"; this '
           'is what make.s prints, and the row pins it so the shape '
           'cannot drift unnoticed.')
_WHY_NODOT = (
    'GNU make cannot be the oracle: it requires a suffix to begin '
    'with a period, and this row is exactly the case where maux does '
    'not. make concatenates the pair to name the rule (`.S` + `R` = '
    '`.SR`) and never re-splits it, so the period is a convention '
    'rather than a requirement -- which is what lets the self-host '
    'MAKEFILE infer 512 objects named `CATMR` from sources named '
    '`CATM.S` without renaming a single generated file '
    '(docs/MAKE-POSIX.md sec 4).')
_WHY_JOIN = ('a DELIBERATE divergence, see this row\'s known_gap.')

DASHN = ['-f', 'MAKEFILE', '-n']
DASHRN = ['-r', '-f', 'MAKEFILE', '-n']

CASES5 = [
    # ==================================================================
    # macros -- XCU make.html, "Macros"
    # ==================================================================
    C('make', 'macro expands in a command line',
      'Macros ... $(string1) ... shall be replaced by string2.',
      DASHN + ['ALL'],
      files={'MAKEFILE': MK('CC = ZORK',
                            'ALL:',
                            '\t$(CC) one')}),
    C('make', 'brace form ${name} is the same macro',
      'The macro shall be referenced as $(string1) or ${string1}.',
      DASHN + ['ALL'],
      files={'MAKEFILE': MK('CC = ZORK',
                            'ALL:',
                            '\t${CC} two')}),
    C('make', 'single-character macro needs no parentheses',
      'If string1 is a single character, the parentheses are optional.',
      DASHN + ['ALL'],
      files={'MAKEFILE': MK('C = ZORK',
                            'ALL:',
                            '\t$C three')}),
    C('make', '$$ is a literal dollar sign',
      'The macro $$ shall be replaced by the single character $.',
      DASHN + ['ALL'],
      files={'MAKEFILE': MK('ALL:',
                            '\tZORK $$HOME')}),
    C('make', 'an undefined macro expands to nothing',
      'Macros that are never defined shall evaluate to a null string.',
      DASHN + ['ALL'],
      files={'MAKEFILE': MK('ALL:',
                            '\tZORK $(NOSUCH) four')}),
    C('make', 'a macro value may reference another macro',
      'The macro shall be expanded when the command is used.',
      DASHN + ['ALL'],
      files={'MAKEFILE': MK('A = deep',
                            'B = $(A) $(A)',
                            'ALL:',
                            '\tZORK $(B)')}),
    C('make', 'a macro expands in a dependency list',
      'Macros in the prerequisite list shall be evaluated.',
      DASHRN + ['ALL'],
      files={'MAKEFILE': MK('D = A.S B.S',
                            'ALL: $(D)',
                            '\tZORK $(D)'),
             'A.S': ['a'], 'B.S': ['b']}),
    C('make', 'a macro expands in a target name',
      'Macros shall be evaluated in target names.',
      DASHN + ['ALL'],
      files={'MAKEFILE': MK('T = ALL',
                            '$(T):',
                            '\tZORK five')}),
    C('make', 'a command-line macro overrides the makefile',
      'Macro definitions on the command line shall override '
      'definitions in the makefile.',
      ['-f', 'MAKEFILE', '-n', 'CC=OVERRIDE', 'ALL'],
      files={'MAKEFILE': MK('CC = ZORK',
                            'ALL:',
                            '\t$(CC) six')}),

    # ==================================================================
    # internal macros
    # ==================================================================
    C('make', '$@ is the target being made',
      'The $@ macro shall evaluate to the full target name.',
      DASHN + ['ALL'],
      files={'MAKEFILE': MK('ALL:',
                            '\tZORK $@')}),
    C('make', '$< is the first prerequisite',
      'The $< macro shall evaluate to the prerequisite.',
      DASHRN + ['ALL'],
      files={'MAKEFILE': MK('ALL: A.S B.S',
                            '\tZORK $<'),
             'A.S': ['a'], 'B.S': ['b']}),
    C('make', '$? is every out-of-date prerequisite',
      'The $? macro shall evaluate to the list of prerequisites that '
      'are newer than the target.',
      DASHRN + ['ALL'],
      files={'MAKEFILE': MK('ALL: A.S B.S',
                            '\tZORK $?'),
             'A.S': ['a'], 'B.S': ['b']}),

    # ==================================================================
    # inference rules -- XCU make.html, "Inference Rules"
    # ==================================================================
    C('make', 'a .s1.s2 rule builds a target with no rule of its own',
      'Inference rules ... The target ... .s1.s2 ... shall be used to '
      'build a file ending in s2 from one ending in s1.',
      DASHRN + ['A.R'],
      files={'MAKEFILE': MK('.SUFFIXES: .R .S',
                            '.S.R:',
                            '\tZORK $@ $<'),
             'A.S': ['a']}),
    C('make', '$* is the stem of an inferred target',
      'The $* macro shall evaluate to the current target name with '
      'its suffix deleted.',
      DASHRN + ['A.R'],
      files={'MAKEFILE': MK('.SUFFIXES: .R .S',
                            '.S.R:',
                            '\tZORK $* $@ $<'),
             'A.S': ['a']}),
    C('make', 'inference serves many targets from one rule',
      'The same inference rule shall apply to every target matching '
      'its suffix.',
      DASHRN + ['A.R', 'B.R', 'C.R'],
      files={'MAKEFILE': MK('.SUFFIXES: .R .S',
                            '.S.R:',
                            '\tZORK $@ $<'),
             'A.S': ['a'], 'B.S': ['b'], 'C.S': ['c']}),
    C('make', 'a rule with prerequisites and no recipe infers one',
      'If the target has no commands, the inference rule shall supply '
      'them.',
      DASHRN + ['A.R'],
      files={'MAKEFILE': MK('.SUFFIXES: .R .S',
                            '.S.R:',
                            '\tZORK $@ $<',
                            'A.R: DEP'),
             'A.S': ['a'], 'DEP': ['d']}),
    C('make', 'a suffix needs no leading dot',
      'The rule to create a file with suffix s2 that depends on a '
      'similarly named file with suffix s1 is specified as an entry '
      'for the target s1s2.',
      ['-r', '-f', 'MAKEFILE', '-n', 'AMR'],
      files={'MAKEFILE': MK('A = ZORK',
                            '.SUFFIXES: R .S',
                            '.SR:',
                            '\t$(A) -o $@ $< $*'),
             'AM.S': ['a']},
      hand={'stdout': ['ZORK -o AMR AM.S AM'], 'rc': 0,
            'reason': _WHY_NODOT}),
    C('make', 'an empty .SUFFIXES clears the list, so nothing infers',
      'Multiple lists accumulate; an empty list clears what came '
      'before.',
      ['-r', '-f', 'MAKEFILE', '-n', 'A.R'],
      files={'MAKEFILE': MK('.SUFFIXES: .R .S',
                            '.SUFFIXES:',
                            '.S.R:',
                            '\tZORK inferred'),
             'A.S': ['a']},
      hand={'stdout': [], 'rc': 1, 'reason': _WHY_STATUS}),

    # ==================================================================
    # rule syntax
    # ==================================================================
    C('make', 'the default target is the first NON-special rule',
      'If no target operand is given, the first target in the '
      'makefile shall be used; targets beginning with a period are '
      'not eligible.',
      DASHRN,
      files={'MAKEFILE': MK('.SUFFIXES: .R .S',
                            '.S.R:',
                            '\tZORK inferred',
                            'ALL:',
                            '\tZORK default')}),
    C('make', 'one header, several targets, one recipe',
      'The first line of an entry is a blank-separated list of '
      'targets.',
      DASHN + ['ONE', 'TWO'],
      files={'MAKEFILE': MK('ONE TWO:',
                            '\tZORK $@')}),
    C('make', 'a command after a semicolon on the target line',
      'Text following a semicolon on the target line is a command.',
      DASHN + ['ALL'],
      files={'MAKEFILE': MK('ALL: ; ZORK semi')}),
    C('make', 'a backslash continues a dependency line',
      'A line ending with a backslash shall be continued.',
      DASHRN + ['ALL'],
      files={'MAKEFILE': MK('ALL: A.S \\',
                            ' B.S',
                            '\tZORK $?'),
             'A.S': ['a'], 'B.S': ['b']}),
    C('make', 'a backslash continues a command line',
      'A line ending with a backslash shall be continued.',
      DASHN + ['ALL'],
      files={'MAKEFILE': MK('ALL:',
                            '\tZORK one \\',
                            '\ttwo')},
      hand={'stdout': ['ZORK one two'], 'rc': 0,
            'reason': _WHY_JOIN}),
    C('make', 'an @ command still prints under -n',
      '-n ... shall write the commands ... including lines beginning '
      'with an at-sign.',
      DASHN + ['ALL'],
      files={'MAKEFILE': MK('ALL:',
                            '\t@ZORK quiet')}),
    C('make', 'a whole-line # is a comment',
      'A comment starts with a number sign.',
      DASHN + ['ALL'],
      files={'MAKEFILE': MK('# this line is not a rule',
                            'ALL:',
                            '\tZORK seven')}),
    C('make', 'a # on a rule line is not a dependency',
      'A comment starts with a number sign.',
      DASHRN + ['ALL'],
      files={'MAKEFILE': MK('ALL: A.S # NOSUCH',
                            '\tZORK $<'),
             'A.S': ['a']}),

    # ==================================================================
    # options
    # ==================================================================
    C('make', '-q exits 1 when the target is out of date',
      '-q ... Return a zero exit value if the target file is up to '
      'date; otherwise, return 1.',
      ['-f', 'MAKEFILE', '-q', 'ALL'],
      files={'MAKEFILE': MK('ALL: A.S',
                            '\tZORK eight'),
             'A.S': ['a']}),
    C('make', '-f names the makefile and its name may be attached',
      '-f makefile  Specify a different makefile.',
      ['-fMAKEFILE', '-n', 'ALL'],
      files={'MAKEFILE': MK('ALL:',
                            '\tZORK nine')}),
    C('make', 'an unknown flag is a usage error, exit 2',
      'The make utility shall exit with ... >0 An error occurred.',
      ['-Z', '-f', 'MAKEFILE', '-n', 'ALL'],
      files={'MAKEFILE': MK('ALL:', '\tZORK ten')},
      hand={'stdout': [], 'rc': 2, 'reason': _WHY_STATUS}),
    C('make', '-s runs the recipe without echoing it',
      '-s  Do not write makefile command lines or touch messages to '
      'standard output before executing.',
      ['-f', 'MAKEFILE', '-s', 'ALL'],
      files={'MAKEFILE': MK('ALL:',
                            '\t/bin/TRUE')},
      hand={'stdout': [], 'rc': 0, 'reason': _WHY}),
    C('make', '.SILENT silences the whole makefile',
      'If the special target .SILENT is specified without '
      'prerequisites, commands shall not be written.',
      ['-f', 'MAKEFILE', 'ALL'],
      files={'MAKEFILE': MK('.SILENT:',
                            'ALL:',
                            '\t/bin/TRUE')},
      hand={'stdout': [], 'rc': 0, 'reason': _WHY}),
    C('make', 'a failing command stops the build, exit 1',
      'If a command returns a non-zero status, make shall terminate.',
      ['-f', 'MAKEFILE', '-s', 'ALL'],
      files={'MAKEFILE': MK('ALL:',
                            '\t/bin/FALSE',
                            '\t/bin/TRUE')},
      hand={'stdout': [], 'rc': 1, 'reason': _WHY}),
    C('make', '-i ignores a failing command',
      '-i  Ignore error codes returned by invoked commands.',
      ['-f', 'MAKEFILE', '-s', '-i', 'ALL'],
      files={'MAKEFILE': MK('ALL:',
                            '\t/bin/FALSE',
                            '\t/bin/TRUE')},
      hand={'stdout': [], 'rc': 0, 'reason': _WHY}),
    C('make', '.IGNORE ignores a failing command',
      'If the special target .IGNORE is specified without '
      'prerequisites, error codes shall be ignored.',
      ['-f', 'MAKEFILE', '-s', 'ALL'],
      files={'MAKEFILE': MK('.IGNORE:',
                            'ALL:',
                            '\t/bin/FALSE',
                            '\t/bin/TRUE')},
      hand={'stdout': [], 'rc': 0, 'reason': _WHY}),
    C('make', 'a - prefix ignores that one command',
      'If the command prefix contains a hyphen ... any error found '
      'while executing the command shall be ignored.',
      ['-f', 'MAKEFILE', '-s', 'ALL'],
      files={'MAKEFILE': MK('ALL:',
                            '\t-/bin/FALSE',
                            '\t/bin/TRUE')},
      hand={'stdout': [], 'rc': 0, 'reason': _WHY}),
    C('make', '-k builds the other branch and still exits 1',
      '-k  Continue to update other targets that do not depend on the '
      'current target if a non-ignored error occurs.',
      ['-f', 'MAKEFILE', '-k', 'ALL'],
      files={'MAKEFILE': MK('ALL: BAD GOOD',
                            'BAD:',
                            '\t@/bin/FALSE',
                            'GOOD:',
                            '\t@/bin/ECHO reached')},
      hand={'stdout': ['reached'], 'rc': 1, 'reason': _WHY}),
    C('make', 'without -k the second branch is never reached',
      'Commands returning nonzero status cause make to terminate.',
      ['-f', 'MAKEFILE', 'ALL'],
      files={'MAKEFILE': MK('ALL: BAD GOOD',
                            'BAD:',
                            '\t@/bin/FALSE',
                            'GOOD:',
                            '\t@/bin/ECHO reached')},
      hand={'stdout': [], 'rc': 1, 'reason': _WHY}),
    C('make', '-p writes the macro and target database',
      '-p  Write to standard output the complete set of macro '
      'definitions and target descriptions.',
      ['-f', 'MAKEFILE', '-p', '-n', 'ALL'],
      files={'MAKEFILE': MK('CC = ZORK',
                            'ALL:',
                            '\t$(CC) eleven')},
      hand={'stdout': ['CC = ZORK', 'ALL: ', '\t$(CC) eleven',
                       'ZORK eleven'],
            'rc': 0, 'reason': _WHY_DB}),
    C('make', 'a target with no rule and no file is an error',
      'If no rule and no file exist for a target, make shall report '
      'an error.',
      ['-f', 'MAKEFILE', '-n', 'NOSUCH'],
      files={'MAKEFILE': MK('ALL:', '\tZORK twelve')},
      hand={'stdout': [], 'rc': 1, 'reason': _WHY}),
    C('make', 'a circular dependency is reported, not looped on',
      'make shall not loop on a circular dependency.',
      ['-f', 'MAKEFILE', '-n', 'ALL'],
      files={'MAKEFILE': MK('ALL: BEE',
                            '\tZORK a',
                            'BEE: ALL',
                            '\tZORK b')},
      hand={'stdout': [], 'rc': 1, 'reason': _WHY}),

    # ==================================================================
    # MAKE-FLUSH (2026-10-23): output order into a FILE
    # ==================================================================
    C('make', 'the echoed command precedes its own output in a file',
      'The command line is written to standard output before it is '
      'executed.',
      ['-f', 'MAKEFILE'],
      files={'MAKEFILE': MK('ALL:', '\tECHO hello')},
      hand={'stdout': ['ECHO hello', 'hello'], 'rc': 0,
            'reason': _WHY + ' With stdout a FILE, liba full-buffers '
            'make\'s echo and the child writes through its own '
            'buffer, so order is only right if make flushes first.'}),
    C('make', 'two rules keep echo/output pairs in order in a file',
      'Each command is echoed, then run, in the order of the rules.',
      ['-f', 'MAKEFILE'],
      files={'MAKEFILE': MK('ALL: ONE', '\tECHO two',
                            'ONE:', '\tECHO one')},
      hand={'stdout': ['ECHO one', 'one', 'ECHO two', 'two'], 'rc': 0,
            'reason': _WHY + ' Same buffering order check, two '
            'rules, so a flush that fires only once is caught.'}),

    C('find', '-print output precedes the -exec child output in a file',
      'Each primary is evaluated in order: -print writes the path, '
      'then -exec runs the utility.',
      ['@TREE@', '-name', "'A.TXT'", '-print', '-exec', 'ECHO',
       'hit', '{}', "';'"],
      dirs={'TREE': 'TREE', 'SUB': 'TREE/SUB'}, predirs=['TREE', 'SUB'],
      files={'TREE/A.TXT': ['x']},
      hand=dict(stdout=['TREE/A.TXT', 'hit TREE/A.TXT'], rc=0,
                reason=_WHY + ' find buffers -print on a file fd 1; '
                'the -exec child writes through its own buffer.')),
    C('sh', 'builtin output precedes an external command in a file',
      'Commands run in order; their output reaches the file in order.',
      [], stdin='IN',
      files={'IN': ['alias ZZ=1', 'alias', '/bin/ECHO a1',
                    'type cat', '/bin/ECHO a2']},
      hand=dict(stdout=["alias ZZ='1'", 'a1', 'cat is /bin/cat', 'a2'],
                rc=0,
                reason=_WHY + ' Builtins write through liba\'s buffer '
                '(alias, type: PUTS on a file fd 1); the spawned '
                'command writes through its own.')),
    C('sh', 'builtin output precedes a ( ) subshell in a file',
      'Commands run in order; their output reaches the file in order.',
      [], stdin='IN',
      files={'IN': ['alias ZZ=1', 'alias', '( /bin/ECHO g1 )',
                    'type cat', '/bin/ECHO a2']},
      hand=dict(stdout=["alias ZZ='1'", 'g1', 'cat is /bin/cat', 'a2'],
                rc=0,
                reason=_WHY + ' The subshell spawn (SUB_DOSPAWN) '
                'must flush liba\'s buffer like a plain command.')),
    C('sh', 'builtin output precedes a $( ) capture in a file',
      'Commands run in order; their output reaches the file in order.',
      [], stdin='IN',
      files={'IN': ['alias ZZ=1', 'alias', 'V=$(/bin/ECHO s1)',
                    'type cat', '/bin/ECHO $V']},
      hand=dict(stdout=["alias ZZ='1'", 'cat is /bin/cat', 's1'],
                rc=0,
                reason=_WHY + ' $( ) shares SUB_DOSPAWN; the capture '
                'itself must still arrive intact and in order.')),
    C('sh', 'exec > FILE does not take earlier buffered output',
      'Output written before exec belongs to the old fd 1.',
      [], stdin='IN',
      files={'IN': ['alias ZZ=1', 'alias', 'exec > G', 'type cat']},
      post=[['ECHO', '---', '>>', 'OUT'], ['CAT', 'G', '>>', 'OUT']],
      hand=dict(stdout=["alias ZZ='1'", '---', 'cat is /bin/cat'],
                rc=0,
                reason=_WHY + ' The fd swap must flush fd 1 first or '
                'the buffered alias line lands in G.')),
]

#: Rows this suite records as KNOWN GAPS rather than reds. Both are
#: DELIBERATE DIVERGENCES with the reason on the row itself, not
#: unimplemented POSIX: the command-continuation join (there is no
#: shell to hand a backslash-newline to) and the exit STATUS of a
#: refused target (POSIX pins only ">0"). The entries POSIX-GAPS.md
#: still lists against make -- `-f -`, `::` rules, parallelism,
#: included makefiles -- have no row here at all, because they are
#: out of scope in docs/MAKE-POSIX.md sec 6 rather than written and
#: then excused.
KNOWN_GAPS5 = [(c['tool'], c['name'], c['known_gap'])
               for c in CASES5 if c['known_gap']]
