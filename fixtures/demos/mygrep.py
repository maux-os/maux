"""W3 -- grep, written in ed (docs/DEMOS.md #1, docs/SITE.md sec 4).

grep is named for the ed command g/re/p. Write it again in five lines
-- a here-doc handed to ed -- run it on grep's own manual page, run the
real grep on the same file, capture both to files, and let cmp say
nothing. check-shlang already proves the mechanism (case d); this
proves the film, and fails in the sweep before anyone films a broken
one.
"""
DEMO = dict(
    name='mygrep',
    title='grep, written in ed',
    backends=('text80', 'ut'),
    image='play',
    gate='check-demo-mygrep',
)

# What `cat > mygrep` must have been given, and what `cat mygrep` must
# print back: content and order, so a dropped or doubled key is red.
SCRIPT = ['#!/bin/sh',
          'ed <<EOF',
          'r $2',
          'g/$1/p',
          'q',
          'EOF']
PATTERN = 'regular'
FILE = '/usr/man/GREP'


def run(t):
    t.say('grep is named after an ed command: g/re/p. '
          'Here it is again, in five lines.')
    t.press('\x0c')                       # ^L: a clean screen
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('cd /tmp', 'a scratch directory, not the volume root')
    t.press('\x0c')
    t.wait_prompt('clear screen')

    t.run_cmd_echoed('cat > mygrep', 'start the script')
    for line in SCRIPT:
        t.type_line(line, 'script line ' + line)
    t.press(t.CTRL_D)
    t.wait_prompt('script written')

    t.run_cmd_echoed('cat mygrep', 'show the script')
    t.expect_lines(SCRIPT, 'the script reads back as typed')
    t.hold(2.0)

    t.say("Run it on grep's own manual page, then run the real grep.")
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('./mygrep %s %s' % (PATTERN, FILE), 'mygrep')
    mine = t.output('mygrep prints')
    t.expect(len(mine) >= 2, 'mygrep printed several rows')
    t.expect(all(PATTERN in row for row in mine),
             'every mygrep row holds the pattern')
    t.run_cmd_echoed('grep %s %s' % (PATTERN, FILE), 'grep')
    t.expect_lines(mine, 'grep prints the same rows, in the same order')
    t.hold(2.0)

    t.say('Capture both to files, and compare them.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('./mygrep %s %s > mine' % (PATTERN, FILE), 'capture')
    t.expect_lines(0, 'the capture prints nothing')
    t.run_cmd_echoed('grep %s %s > real' % (PATTERN, FILE), 'capture')
    t.expect_lines(0, 'the capture prints nothing')
    t.run_cmd_echoed('cat real', 'show the capture')
    t.expect_lines(mine, 'the file holds the rows grep printed')
    t.run_cmd_echoed('cmp mine real', 'cmp')
    t.expect_cmp_silent('cmp says nothing')
    t.say('Silence. The machine verified its own joke.')
    t.poster()
    t.hold(3.0)
