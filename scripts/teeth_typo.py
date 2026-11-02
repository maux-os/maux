#!/usr/bin/env python3
"""teeth_typo.py -- the sabotage runner behind the W16 film's teeth
(site/demos/typo.py), on scripts/teeth_lib.py. NOT a gate and in no sweep:
it breaks the film's SUBJECT (nas) by --setup commands typed at the shell
on the gate's own copy-on-write image, or the film's expected line, runs
site/demos/typo.py through the CLI, and requires the failure to name the
intended label on the CLI's own FAIL line. Exit status: teeth_lib.py
(0 all behaved, 1 a tooth did not bite, 2 runner broken).

NOT covered, and why: the film's own fd-2 rows ("nas prints nothing to
the screen", "ERRS holds ...") have no tooth. They fail only if nas writes
its diagnostics to stdout, and a guest-side stand-in cannot do that: make
will not run a #! wrapper for nas ("cannot spawn command", so the make row
goes red first, for the wrong reason), and a shell alias cannot move nas's
fd 2 because the film's own later `2> ERRS` overrides it. The evidence is
the probe made before NAS-STDERR (ERRS empty, the messages on the screen),
which these rows would have refused; a tooth needs a pre-fix nas.

  python3 scripts/teeth_typo.py              # all
  python3 scripts/teeth_typo.py nas-is-true  # by name prefix
  python3 scripts/teeth_typo.py --dry
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import teeth_lib as T  # noqa: E402

FILM = 'site/demos/typo.py'
CLI = ('python3', 'scripts/demo_record.py', FILM, '--backend', 'text80')

MAKE_ROW = ('make echoes nas, nas reports the label and the line, then '
            'make says a command failed')


# (name, --setup commands, label the failure must name)
GUEST = [
    ('nas-is-true', ['cp /bin/true /bin/nas'], MAKE_ROW),
    # the lesson's file gains a line at the top: nas then reports line
    # n + 1, and the film (which reads n off the example) must go red
    ('lesson-shifted-one-line',
     ['echo "*" > /tmp/top',
      'cat /tmp/top /usr/src/examples/HELLO/hello.s > /tmp/shifted',
      'cp /tmp/shifted /usr/src/examples/HELLO/hello.s'], MAKE_ROW),
]
# (name, [(file, old, new)], label): the film's expected line is wrong
SOURCE = [
    ('film-expects-another-line',
     [(FILM, "(hello.s line %d)' % n,", "(hello.s line %d)' % (n + 1),")],
     MAKE_ROW),
]


def tooth(name, setup, label, edits=None):
    argv = CLI
    for c in setup:
        argv = argv + ('--setup', c)
    kw = dict(edits=edits, witness=T.SourceOnly()) if edits else dict(
        witness=T.CommandMutation(
            'the mutation is the --setup commands typed into the guest by '
            'demo_record.py; the FAIL line naming the label it breaks at '
            'is its only evidence'))
    return T.Tooth(name, checks=[T.Check(T.Invocation(argv), 'demo',
        T.Aggregate(r'^FAIL typo \(gate mode\): ' + label,
                    'demo_record.py prints one PASS/FAIL line, no rows'),
        baseline=T.Invocation(CLI))], **kw)


T.main('typo', [tooth(n, s, l) for n, s, l in GUEST] +
       [tooth(n, [], l, e) for n, e, l in SOURCE])
