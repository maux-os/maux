#!/usr/bin/env python3
r"""posixutil_cases6.py -- CASES6/KNOWN_GAPS6: the rows the INTERACTIVE
case kind (scripts/posixutil_interactive.py, docs/POSIX-HARNESS.md)
makes possible, plus the byte-fixture and ordering rows that ride with
them. Round 6, same reason as rounds 2-5 for a separate module: one
gate, one summary line, no single file growing past what one person
edits comfortably.

Where a row's TOOL is `tail -f`, `xargs -p` or `find -ok`, the program
either never ends by itself or stops to ask a person something, so the
row carries a `script` (wait for text / type bytes / append to a file)
and is built with IR(). Plain rows (find -depth, xargs -0) use C().

The older rows for the same tools live in posixutil_cases2.py where
they were first written; the ones this stream retired were rewritten IN
PLACE there (their `known_gap` set to None, the finding left in the
text) rather than deleted.
"""
from posixutil_interactive import (IR, WAIT, TYPE, APPEND, CTRL_C)   # noqa: F401,E501


def Q(word):
    return "'" + word + "'"



def C(tool, name, spec, argv, *, files=None, dirs=None, predirs=None,
      stdin=None, results=None, post=None, hand=None, known_gap=None,
      reset=None, norm=None):
    return dict(tool=tool, name=name, spec=spec, argv=list(argv),
                files=files or {}, dirs=dirs or {},
                predirs=list(predirs or []), stdin=stdin,
                results=list(results or []), post=list(post or []),
                hand=hand, known_gap=known_gap, reset=reset, norm=norm,
                meta_equal=[])


#: the chain every find -depth row walks: TREE/SUB/INNER.TXT
DEPTH_DIRS = {'TREE': 'TREE', 'SUB': 'TREE/SUB'}
DEPTH_PRE = ['TREE', 'SUB']

CASES6 = [
    # ==================================================================
    # the harness's own self-check, on a tool that needs no change:
    # a program that never ends is taken down by a typed ^C, the status
    # is 128+SIGINT on both sides, and the shell's prompt comes back
    # exactly once (the `$ $` shape docs/TTY-TYPEAHEAD-BELL.md Part 3
    # fixed would put a second `$` on the row and fail the settle).
    # ==================================================================
    IR('cat', 'a typed ^C ends cat reading the terminal: status 130',
       'EXIT STATUS: the process was terminated by SIGINT -- the shell '
       'reports 128+2. If no file operands are specified, the standard '
       'input shall be used.',
       [],
       [TYPE('hello\r'), WAIT('hello', 2), TYPE(CTRL_C)]),

    # ==================================================================
    # tail -f (src/bin/tail.s, tailin.s). The base row is in
    # posixutil_cases2.py ("-f follows a file that is appended to").
    # ==================================================================
    IR('tail', '-n 1 -f prints the last line, then what is appended',
       '-f ...continue reading and copying bytes as they become '
       'available; -n number: the last number lines.',
       ['-n', '1', '-f', '@F@'],
       [WAIT('charlie'), APPEND('F', ['delta']), WAIT('delta'),
        TYPE(CTRL_C)],
       files={'F': ['alpha', 'bravo', 'charlie']}),
    IR('tail', '-c 6 -f follows from the byte count it printed',
       '-c number: the last number bytes; -f as above.',
       ['-c', '6', '-f', '@F@'],
       [WAIT('bravo'), APPEND('F', ['delta']), WAIT('delta'),
        TYPE(CTRL_C)],
       files={'F': ['alpha', 'bravo']}),
    IR('tail', '-f follows two appends in order',
       '-f ...continue reading and copying bytes as they become '
       'available',
       ['-f', '@F@'],
       [WAIT('bravo'), APPEND('F', ['delta']), WAIT('delta'),
        APPEND('F', ['echo9']), WAIT('echo9'), TYPE(CTRL_C)],
       files={'F': ['alpha', 'bravo']}),
    # OPEN-RW-1 R1: the defect as it was first seen -- `tail -f F` in
    # one place, five DISTINCT `echo sentinel-N >> F` back to back in
    # another (the guest appender's burst=True form: NOT one `cat APPn
    # >> F` per step, which is how this row used to be dodged). Every
    # sentinel exactly once, and no `sh: cannot redirect` on the glass
    # (the appender's stderr is no longer sent to /dev/null).
    IR('tail', '-f follows a burst of five echo >> appends',
       '-f ...continue reading and copying bytes as they become '
       'available',
       ['-f', '@F@'],
       [WAIT('bravo'),
        APPEND('F', ['sentinel-%d' % n for n in range(1, 6)],
               burst=True),
        WAIT('sentinel-5'), TYPE(CTRL_C)],
       files={'F': ['alpha', 'bravo']}),
    # ALIGNED FIXTURES (learning:01M14B7RFG1024FPA330Z9ZNM2). tail reads
    # in 255-byte chunks (BUFSZ), and five 50-character lines with their
    # CR are exactly 255 bytes. The first fixture ends the INITIAL read
    # on a chunk boundary; the second appends exactly one chunk; the
    # third appends a chunk and a bit. An off-by-one in the byte
    # position tail resumes from shows up as a repeated or a missing
    # line here and nowhere in a fixture of irregular sizes.
    IR('tail', '-n 2 -f, an initial file of exactly one read chunk',
       '-f ...continue reading and copying bytes as they become '
       'available',
       ['-n', '2', '-f', '@F@'],
       [WAIT('L5' + '5' * 48), APPEND('F', ['delta']), WAIT('delta'),
        TYPE(CTRL_C)],
       files={'F': ['L%d' % n + str(n) * 48 for n in range(1, 6)]}),
    IR('tail', '-n 1 -f, an append of exactly one read chunk',
       '-f ...continue reading and copying bytes as they become '
       'available',
       ['-n', '1', '-f', '@F@'],
       [WAIT('bravo'), APPEND('F', ['M%d' % n + str(n) * 48
                                    for n in range(1, 6)]),
        WAIT('M5' + '5' * 48), TYPE(CTRL_C)],
       files={'F': ['alpha', 'bravo']}),
    IR('tail', '-n 1 -f, an append that straddles the read chunk',
       '-f ...continue reading and copying bytes as they become '
       'available',
       ['-n', '1', '-f', '@F@'],
       [WAIT('bravo'), APPEND('F', ['N%d' % n + str(n) * 48
                                    for n in range(1, 7)]),
        WAIT('N6' + '6' * 48), TYPE(CTRL_C)],
       files={'F': ['alpha', 'bravo']}),

    # ==================================================================
    # xargs -0 (src/bin/xargs.s, xargstok.s). Byte fixtures: a `bytes`
    # value in files= is staged verbatim on both sides. The base row is
    # in posixutil_cases2.py. NOT HERE, on purpose: an empty item (BSD
    # drops it, GNU passes an empty argument), empty input (BSD runs
    # nothing, GNU runs the utility once) and -E under -0 (BSD honours
    # it, GNU ignores it with a warning) -- the hosts disagree and POSIX
    # is silent, so there is no oracle to hold maux to.
    # ==================================================================
    C('xargs', "-0 quotes and a backslash are ordinary bytes",
      '-0 -- ...arguments ... are delimited only by null bytes. Any '
      '<blank>, <newline>, quote or <backslash> is literal.',
      ['-0', 'echo'], stdin='IN',
      files={'IN': b"'a b'\x00\"c\"\x00x\\y\x00"}),
    C('xargs', '-0 -n 1 makes one invocation per item',
      '-n number -- Invoke utility using as many standard input '
      'arguments as possible, up to number.',
      ['-0', '-n', '1', 'echo'], stdin='IN',
      files={'IN': b'a\x00b\x00c\x00'}),
    C('xargs', '-0 a last item with no NUL is still an item',
      '-0 -- ...arguments in the standard input are delimited only '
      'by null bytes.',
      ['-0', 'echo'], stdin='IN', files={'IN': b'a\x00b'}),
    C('xargs', '-0 a tab inside an item is data',
      '-0 -- Any <blank> is literal.',
      ['-0', 'echo'], stdin='IN', files={'IN': b'a\tb\x00c\x00'}),
    C('xargs', '-0 a newline inside an item is data, not a delimiter',
      '-0 -- Any <newline> is literal.',
      ['-0', '-n', '2', 'echo'], stdin='IN',
      files={'IN': b'a\nb\x00c\x00'},
      hand=dict(stdout=['a\nb c'], rc=0,
                reason="host-oracled to the byte on both hosts "
                       "('a\\nb c' printed as two rows, 'a' and 'b c'), "
                       "but maux_lines() splits a file on CR only, so "
                       "an LF INSIDE one printed argument stays inside "
                       "one row on this side. The expectation is the "
                       "host's bytes under maux's line convention: ONE "
                       "invocation (-n 2 took both items) whose first "
                       "argument holds the LF. A tokenizer that broke "
                       "at the newline would print 'a b' then 'c'.")),
    # ALIGNED FIXTURES (learning:01M14B7RFG1024FPA330Z9ZNM2). xargs reads
    # stdin in 255-byte chunks (BUFSZ). The first fixture's first NUL is
    # the LAST byte of chunk one; the second's is the FIRST byte of chunk
    # two. Items of irregular length make a delimiter on a refill edge a
    # measure-zero event.
    C('xargs', '-0 a NUL as the last byte of a read chunk',
      '-0 -- ...arguments in the standard input are delimited only '
      'by null bytes.',
      ['-0', '-n', '1', 'echo'], stdin='IN',
      files={'IN': b'k' * 254 + b'\x00' + b'second\x00'}),
    C('xargs', '-0 a NUL as the first byte of the next read chunk',
      '-0 -- ...arguments in the standard input are delimited only '
      'by null bytes.',
      ['-0', '-n', '1', 'echo'], stdin='IN',
      files={'IN': b'm' * 255 + b'\x00' + b'second\x00'}),
    C('xargs', '-0 with -I: a NUL ends the line, nothing is stripped',
      '-I replstr ... -0 -- ...arguments ... delimited only by null '
      'bytes.',
      ['-0', '-I', '{}', 'echo', 'x{}'], stdin='IN',
      files={'IN': b'a b\x00 c\x00'}),

    # ==================================================================
    # xargs -p (src/bin/xargs.s, xargsinv.s). INTERACTIVE rows: the
    # compared stream is the merged terminal output, so the prompt and
    # the echo of the typed answer are IN it -- a tool that never asked
    # could not produce it. BSD and GNU agree on all of these. NOT HERE:
    # an empty reply followed by another invocation (GNU then runs a
    # third, empty invocation and waits), and arguments with shell
    # metacharacters (GNU quotes them in the prompt, BSD does not).
    # ==================================================================
    IR('xargs', '-p a y runs the invocation',
       '-p -- ...the user is prompted; an affirmative response '
       'causes the invocation.',
       ['-p', 'echo'],
       [WAIT('?...'), TYPE('y\r')],
       stdin='IN', files={'IN': ['a']}),
    IR('xargs', '-p asks once per invocation and each answer counts',
       '-p -- ...prompted ... at each invocation.',
       ['-p', '-n', '1', 'echo'],
       [WAIT('?...'), TYPE('y\r'), WAIT('?...', 2), TYPE('n\r')],
       stdin='IN', files={'IN': ['a', 'b']}),
    IR('xargs', '-p Y and a word that begins with y are affirmative',
       '-p -- ...an affirmative response ...',
       ['-p', '-n', '1', 'echo'],
       [WAIT('?...'), TYPE('Y\r'), WAIT('?...', 2), TYPE('yes\r')],
       stdin='IN', files={'IN': ['a', 'b']}),
    IR('xargs', '-p an empty reply declines',
       '-p -- ...skip the invocation unless affirmative.',
       ['-p', 'echo'],
       [WAIT('?...'), TYPE('\r')],
       stdin='IN', files={'IN': ['a']}),
    IR('xargs', '-p the prompt is the whole command line',
       '-p -- ...the utility name and arguments ... written to stderr.',
       ['-p', 'echo', 'x'],
       [WAIT('?...'), TYPE('y\r')],
       stdin='IN', files={'IN': ['a', 'b']}),
    IR('xargs', '-p with -I prompts for each substituted line',
       '-p -- ... -I replstr ...',
       ['-p', '-I', '{}', 'echo', 'x{}'],
       [WAIT('?...'), TYPE('y\r'), WAIT('?...', 2), TYPE('n\r')],
       stdin='IN', files={'IN': ['a', 'b']}),
    IR('xargs', '-p with -0 prompts for NUL-separated items',
       '-p -- ... -0 ...',
       ['-p', '-0', 'echo'],
       [WAIT('?...'), TYPE('y\r')],
       stdin='IN', files={'IN': b'a b\x00c\x00'}),

    # ==================================================================
    # find -depth and -ok (src/bin/findtop.s, findexpr.s, findeval.s,
    # findact.s). -depth is an ORDERING rule and never was interactive;
    # it sat in the bundled gap row for a different reason (WALK had no
    # post-order). The fixtures are a CHAIN -- one entry per directory --
    # because the order of SIBLINGS is a property of the host file
    # system (BSD and GNU list T/A and T/B in different orders) and of
    # ProDOS's directory, not of find.
    # ==================================================================
    C('find', 'a tree walked without -depth is listed parent first',
      'The pathname ... of the starting point shall be written before '
      'the entries it contains (the default order).',
      ['@TREE@'],
      dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
      files={'TREE/SUB/INNER.TXT': ['z']}),
    C('find', '-depth lists a directory after its contents',
      '-depth -- Always true; causes descent of the directory '
      'hierarchy to be done so that all entries in a directory are '
      'acted on before the directory itself.',
      ['@TREE@', '-depth'],
      dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
      files={'TREE/SUB/INNER.TXT': ['z']}),
    C('find', '-depth -print is the same order as -depth alone',
      '-depth -- ... all entries in a directory are acted on before '
      'the directory itself.',
      ['@TREE@', '-depth', '-print'],
      dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
      files={'TREE/SUB/INNER.TXT': ['z']}),
    C('find', '-depth -type d lists the directories deepest first',
      '-depth -- ... acted on before the directory itself.',
      ['@TREE@', '-depth', '-type', 'd'],
      dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
      files={'TREE/SUB/INNER.TXT': ['z']}),
    C('find', '-depth after the other primaries is still global',
      '-depth -- Always true ... it applies to the whole walk wherever '
      'it appears in the expression.',
      ['@TREE@', '-type', 'd', '-depth'],
      dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
      files={'TREE/SUB/INNER.TXT': ['z']}),
    C('find', '-depth -name filters a post-order walk',
      '-name pattern ... -depth ...',
      ['@TREE@', '-depth', '-name', Q('SUB')],
      dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
      files={'TREE/SUB/INNER.TXT': ['z']}),
    C('find', '-depth ! negates inside a post-order walk',
      '! expression ... -depth ...',
      ['@TREE@', '-depth', '!', '-name', Q('SUB')],
      dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
      files={'TREE/SUB/INNER.TXT': ['z']}),
    C('find', '-depth makes -prune a no-op',
      '-prune -- ... If the -depth primary is specified, the -prune '
      'primary shall have no effect.',
      ['@TREE@', '-depth', '-name', Q('SUB'), '-prune', '-o', '-print'],
      dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
      files={'TREE/SUB/INNER.TXT': ['z']}),
    C('find', '-prune without -depth still prunes (control)',
      '-prune -- ... shall cause find not to descend the current '
      'pathname if it is a directory.',
      ['@TREE@', '-name', Q('SUB'), '-prune', '-o', '-print'],
      dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
      files={'TREE/SUB/INNER.TXT': ['z']}),
    C('find', '-depth on a plain file operand lists just the file',
      '-depth -- ... applied to a file operand.',
      ['@TREE@/SUB/INNER.TXT', '-depth'],
      dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
      files={'TREE/SUB/INNER.TXT': ['z']}),
    C('find', '-depth on a directory operand with one file',
      '-depth -- ... acted on before the directory itself.',
      ['@TREE@/SUB', '-depth'],
      dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
      files={'TREE/SUB/INNER.TXT': ['z']}),
    C('find', '-depth with -exec runs the command in post-order',
      '-exec ... -depth ...',
      ['@TREE@', '-depth', '-exec', 'echo', '{}', Q(';')],
      dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
      files={'TREE/SUB/INNER.TXT': ['z']}),

    # ------------------------------------------------------------------
    # -ok. redirect=True: the utility's output goes to OUT and is
    # host-oracled byte for byte; the terminal carries only the prompt
    # and the typed answer. BSD and GNU WORD THE PROMPT DIFFERENTLY
    # (BSD `"echo T/A.TXT"? `, GNU `< echo ... T/A.TXT > ? `) and POSIX
    # specifies no text, so the prompt cannot be host-oracled: maux
    # prints the V7 form GNU kept, and `tty_has` pins it. The two hosts
    # agree on every OUT and exit status below, including a declined
    # reply (OUT empty, exit 0) and -ok's truth value (a declined or
    # failing -ok is false: `-ok ... ; -print` prints nothing).
    # ------------------------------------------------------------------
    IR('find', '-ok a y runs the utility',
       '-ok utility_name [argument ...] ; ... the user is asked '
       'whether to execute it; a "y" causes the execution.',
       ['@TREE@', '-type', 'f', '-ok', 'echo', '{}', Q(';')],
       [WAIT('?'), TYPE('y\r')],
       redirect=True, tty_has=['< echo ... TREE/A.TXT > ?'],
       dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
       files={'TREE/A.TXT': ['x']}),
    IR('find', '-ok an n runs nothing and prints nothing',
       '-ok ... an affirmative response is required to execute.',
       ['@TREE@', '-type', 'f', '-ok', 'echo', '{}', Q(';')],
       [WAIT('?'), TYPE('n\r')],
       redirect=True, tty_has=['< echo ... TREE/A.TXT > ?'],
       dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
       files={'TREE/A.TXT': ['x']}),
    IR('find', '-ok Y and a word that begins with y are affirmative',
       '-ok ... an affirmative response ...',
       ['@TREE@', '-type', 'f', '-ok', 'echo', '{}', Q(';')],
       [WAIT('?'), TYPE('Yes\r')],
       redirect=True, tty_has=['< echo ... TREE/A.TXT > ?'],
       dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
       files={'TREE/A.TXT': ['x']}),
    IR('find', '-ok an empty reply declines',
       '-ok ... a reply that is not affirmative does not execute.',
       ['@TREE@', '-type', 'f', '-ok', 'echo', '{}', Q(';')],
       [WAIT('?'), TYPE('\r')],
       redirect=True, tty_has=['< echo ... TREE/A.TXT > ?'],
       dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
       files={'TREE/A.TXT': ['x']}),
    IR('find', '-ok suppresses the implicit -print',
       'If the expression contains none of -exec, -ok, and -print, '
       'the given expression shall be effectively replaced by '
       '( given_expression ) -print.',
       ['@TREE@', '-type', 'f', '-ok', 'echo', '{}', Q(';')],
       [WAIT('?'), TYPE('n\r')],
       redirect=True, tty_has=['> ?'],
       dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
       files={'TREE/A.TXT': ['x']}),
    IR('find', '-ok then -print: a y lets the -print through',
       '-ok ... is true if the utility exits 0.',
       ['@TREE@', '-type', 'f', '-ok', 'echo', '{}', Q(';'), '-print'],
       [WAIT('?'), TYPE('y\r')],
       redirect=True, tty_has=['< echo ... TREE/A.TXT > ?'],
       dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
       files={'TREE/A.TXT': ['x']}),
    IR('find', '-ok then -print: an n makes -ok false, so no -print',
       '-ok ... is false if the user declines.',
       ['@TREE@', '-type', 'f', '-ok', 'echo', '{}', Q(';'), '-print'],
       [WAIT('?'), TYPE('n\r')],
       redirect=True, tty_has=['< echo ... TREE/A.TXT > ?'],
       dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
       files={'TREE/A.TXT': ['x']}),
    IR('find', '-ok of a failing utility is false (-o takes the arm)',
       '-ok ... true if the utility exits with a zero status.',
       ['@TREE@', '-type', 'f', Q('('), '-ok', 'false', '{}', Q(';'),
        '-o', '-print', Q(')')],
       [WAIT('?'), TYPE('y\r')],
       redirect=True, tty_has=['< false ... TREE/A.TXT > ?'],
       dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
       files={'TREE/A.TXT': ['x']}),
    IR('find', '-depth -ok asks in post-order, one answer per path',
       '-ok ... -depth ...',
       ['@TREE@', '-depth', '-ok', 'echo', '{}', Q(';')],
       [WAIT('?'), TYPE('y\r'), WAIT('?', 2), TYPE('n\r'),
        WAIT('?', 3), TYPE('y\r')],
       redirect=True,
       tty_has=['< echo ... TREE/SUB/INNER.TXT > ?',
                '< echo ... TREE/SUB > ?', '< echo ... TREE > ?'],
       dirs=DEPTH_DIRS, predirs=DEPTH_PRE,
       files={'TREE/SUB/INNER.TXT': ['z']}),
]

KNOWN_GAPS6 = [(c['tool'], c['name'], c['known_gap'])
               for c in CASES6 if c['known_gap']]
