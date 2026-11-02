"""W4 -- the diff is the program (docs/DEMOS.md #2, docs/SITE.md sec 4).

`diff -e A B` does not describe the change, it IS the change: a script
for ed. Feed it to ed and A becomes B, byte for byte, and cmp -- which
a moment ago said "differ" -- says nothing. V7's answer to distributing
changes, before there was a patch.

A is grep's manual page; B is A with one line deleted and one word
changed in three more. The edit script's commands are asserted against
the line numbers the host computes from the same bytes, and they must
run bottom-up (so each line number is still true when ed reaches it).
"""
import demo_host as H

DEMO = dict(
    name='diffed',
    title='The diff is the program',
    backends=('text80', 'ut'),
    image='play',
    gate='check-demo-diffed',
)

SRC = '/USR/MAN/GREP'
DELETE = 4                      # the sed script below deletes line 4
WORD = ('regular', 'REGULAR')   # ... and changes this word


def commands():
    """The ed commands `diff -e A B` must print, derived on the host
    from the same bytes: one per changed line, last line first."""
    lines = H.text(SRC)
    out = []
    for n, line in enumerate(lines, 1):
        if n == DELETE:
            out.append('%dd' % n)
        elif WORD[0] in line:
            out.append('%dc' % n)
    return list(reversed(out))


def run(t):
    want = commands()

    t.expect(len(want) == 4, 'host: A and B differ in exactly four lines')
    t.say('A diff is a program for ed. First, two files:')
    t.say('A, and B, which is A with four changes.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('cd /tmp', 'cd')
    t.run_cmd_echoed('cp /usr/man/GREP A', 'A')
    t.run_cmd_echoed("sed 's/%s/%s/;%dd' A > B" % (WORD + (DELETE,)), 'B')
    t.expect_lines(0, 'sed printed nothing')

    t.run_cmd_echoed('cmp A B', 'cmp before')
    rows = t.output('cmp before')
    t.expect(len(rows) == 1 and 'differ' in rows[0],
             'cmp says A and B differ')
    t.hold(2.0)

    t.say('Before Larry Wall\'s patch (1984), a change could travel as '
          'an ed script.')
    t.say('diff -e writes the edit script: ed commands, last line first.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('diff -e A B > S', 'diff -e')
    t.expect_lines(0, 'the script went to the file')
    t.run_cmd_echoed('cat S', 'cat S')
    rows = t.output('cat S')
    got = [r for r in rows if r[:1].isdigit()]
    t.expect(got == want, 'the script holds one command per changed line, '
             'bottom-up: %s' % ' '.join(want))
    t.expect(rows.count('.') == len(want) - 1,
             'each change but the delete ends with a dot')
    t.hold(3.0)

    t.say('Add ed\'s w command, and hand the script to ed.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('echo w >> S', 'w')
    t.expect_lines(0, 'echo printed nothing')
    t.run_cmd_echoed('ed A < S', 'ed')
    t.expect_lines(0, 'ed ran the script quietly')
    t.say('ed says nothing. Raymond\'s Rule of Silence: no news is good news.')

    t.say('Now A and B should be the same file.')
    t.run_cmd_echoed('cmp A B', 'cmp after')
    t.expect_cmp_silent('cmp says nothing')
    t.run_cmd_echoed('diff A B', 'diff after')
    t.expect_cmp_silent('diff says nothing either')
    t.say('Silence. The diff was the program.')
    t.poster()
    t.hold(1.0)
