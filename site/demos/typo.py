"""W16 -- a typo, caught (docs/SITE.md sec 4).

An old-school build error, read and fixed the Unix way. A person copies
the hello lesson's two files, breaks one letter of hello.s in vi (the
operand of the jsr: PUTS becomes PUTZ), and runs make, which fails. nas's
complaint is on make's screen, but it scrolls away. So: nas hello.s
2> ERRS keeps it in a file, and cat ERRS reads it again, with the label,
the file and the line. vi on
that line (:N, because vi does not take +N), the repair, cmp against the
lesson's file (silence), make, and ./hello.

What is asserted, and why a film that merely looked right would not pass:

  * the line number comes from the HOST reading the lesson's file (the
    line holding `jsr PUTS`), so the film cannot drift from the lesson,
    and the error nas prints must carry exactly that number;
  * make's screen is exactly the nas line, nas's two diagnostics and
    make's own failure line; ERRS holds exactly the two diagnostics
    (so nas wrote them to file descriptor 2) and nas's own screen was
    silent; no hello.o is left behind by this failure;
  * after the repair hello.s is byte for byte the lesson's file (cmp,
    silent), make runs nas and ld, and ./hello says hello, world.

The film's clock card is pinned off (docs/RECORDER.md): every file has
one date. That does not trouble make here, because this failure (an
unknown label, found in pass 2, before any object file is written)
leaves no hello.o to be older or newer than anything; the film shows
that with an ls. No timing-dependent text is in a checkpoint label.
"""
import os

import demo_host as H

DEMO = dict(
    name='typo',
    title='A typo, caught',
    backends=('text80', 'ut'),
    image='full',
    gate='check-demo-typo',
)

EXAMPLE = os.path.join(H.ROOT, 'examples', 'hello')
LESSON = '/usr/src/examples/HELLO/hello.s'
NAS_LINE = 'nas -o hello.o hello.s'
LD_LINE = 'ld -o hello hello.o -L /usr/lib -l a'
#: the line of `jsr PUTS` in the lesson's hello.s; a literal so the page
#: generator can read the keys, and run() asserts it against the file
LINE = 35


def example_lines():
    with open(os.path.join(EXAMPLE, 'hello.s'), 'rb') as f:
        return f.read().decode('ascii').rstrip('\n').split('\n')


def clear(t):
    t.press('\x0c')
    t.wait_prompt('clear screen')


def on_screen(t, line):
    return any(r.rstrip() == line for r in t.screen())


def wait_line(t, line, label, slices=200):
    """Poll until LINE is on the screen (vi repaints at its own pace,
    and an UltraTerm paints later than the //e's own screen)."""
    for _ in range(slices):
        if on_screen(t, line):
            t.expect(True, label)
            return
        t._slice()
    t.expect(False, label)


def run(t):
    lines = example_lines()
    hits = [i for i, x in enumerate(lines)
            if x.split() == ['jsr', 'PUTS']]
    assert len(hits) == 1, 'the lesson has one jsr PUTS line'
    n = hits[0] + 1                       # vi and nas both count from 1
    assert n == LINE, 'the lesson\'s jsr PUTS moved: LINE is %d, file says %d' % (LINE, n)
    good = lines[hits[0]]
    bad = good[:-1] + 'Z'
    assert good.endswith('PUTS') and bad.endswith('PUTZ')
    err = ['nas: unknown label PUTZ (hello.s line %d)' % n,
           'nas: pass 2 failed']

    t.say('A typo in a working program, and the old-school way to find it.')
    clear(t)
    t.run_cmd_echoed('cd /tmp', 'a scratch directory')
    t.run_cmd_echoed('mkdir typo; cd typo', 'a directory of our own')
    t.run_cmd_echoed('cp /usr/src/examples/HELLO/hello.s '
                     '/usr/src/examples/HELLO/Makefile .',
                     'copy the project')
    t.expect_lines(0, 'cp prints nothing')
    clear(t)

    t.say('One wrong letter: PUTS becomes PUTZ.')
    t.run_cmd_echoed('vi hello.s', 'vi')
    t.wait('"hello.s"', 'vi is up on the file')
    t.hold(1.0)
    t.type_human('/jsr\r')
    t.hold(0.5)
    t.type_human('$rZ')
    wait_line(t, bad, 'the jsr line now says PUTZ')
    t.press(t.ESC)
    t.type_human(':wq')
    t.enter()
    t.wait_prompt('vi quit')
    clear(t)

    t.run_cmd_echoed('make', 'make')
    rows = t.output('make fails', seconds=120)
    t.expect(rows == [NAS_LINE] + err + ['make: command failed'],
             'make echoes nas, nas reports the label and the line, then '
             'make says a command failed')
    t.say('nas has said what is wrong, but it will scroll away.')
    t.say('Run it alone, and 2> keeps its complaints in a file you can '
          'read again.')
    clear(t)
    t.run_cmd_echoed('nas hello.s 2> ERRS', 'nas, standard error to a file')
    t.expect_lines(0, 'nas prints nothing to the screen')
    t.say('2> is file descriptor 2, standard error. '
          'Version 7\'s shell already had it.')
    t.run_cmd_echoed('cat ERRS', 'cat ERRS')
    t.expect_lines(err, 'ERRS holds the label, the file and the line')
    t.say('ed answers a bad command with one ?. nas names the label, '
          'the file and the line.')
    t.run_cmd_echoed('ls', 'ls')
    rows = t.output('ls')
    t.expect(sorted(' '.join(rows).split()) ==
             ['ERRS', 'Makefile', 'hello.s'],
             'this failure left no hello.o behind')
    t.say('This failure leaves no hello.o, so make has no stale one to '
          'trust.')

    clear(t)
    t.say('The error says line %d. vi can go straight there: :%d and RET.'
          % (LINE, LINE))
    t.run_cmd_echoed('vi hello.s', 'vi again')
    t.wait('"hello.s"', 'vi is up on the file')
    t.hold(1.0)
    t.type_human(':%d\r' % LINE)
    wait_line(t, bad, 'line %d is on the screen, with the typo' % n)
    t.type_human('$rS')
    wait_line(t, good, 'the line says PUTS again')
    t.expect(not on_screen(t, bad), 'and no line says PUTZ')
    t.press(t.ESC)
    t.type_human(':wq')
    t.enter()
    t.wait_prompt('vi quit')
    clear(t)

    t.run_cmd_echoed('cmp hello.s ' + LESSON, 'cmp with the lesson file')
    t.expect_cmp_silent('cmp says nothing: the file is the lesson\'s')
    t.say('cmp says nothing: the file is the lesson\'s again, byte for '
          'byte.')
    clear(t)
    t.run_cmd_echoed('make', 'make')
    t.say('make assembles with nas, then links with ld.', over=True)
    rows = t.output('make runs nas then ld', seconds=120)
    t.expect(len(rows) == 3 and rows[0] == NAS_LINE and
             rows[1].startswith('nas: ') and rows[1].endswith(' -> hello.o')
             and rows[2] == LD_LINE,
             'make echoes the nas line, nas reports, then the ld line')
    t.endcue()
    clear(t)
    t.run_cmd_echoed('./hello', 'run it')
    t.expect_lines(['hello, world'], 'it prints hello, world')
    t.poster()
    t.say('Edit, assemble, read the errors, edit: the loop, at one '
          'megahertz.')
    t.hold(3.0)
