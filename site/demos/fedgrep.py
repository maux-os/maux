"""W3 -- grep, written in vi, run on the Federalist Papers
(docs/DEMO-FEDGREP.md; it replaces the mygrep film of docs/DEMOS.md #1).

grep is named for the ed command g/re/p. Write it again: a six-line
shell script typed into vi, handing a here-document to ed. Run it on
Madison's No. 10, the paper on faction, and compare it with the real
grep. Then run it over the 26 papers this edition heads MADISON with
xargs, under fast(), and check the bytes with cksum against the host's
checksum of the expected content, with a positive control. (Not all 85:
ed sizes its heap at run time and No. 83, 34,200 bytes, is over what it
loaded at 63fb62c2, 28,613 bytes, so ed answers "?" to `r` there;
docs/DEMO-FEDGREP-NOTES.md.)

The papers are on the demo image as /FED/NO.01 .. NO.85
(scripts/build_demo_images.py fed, fixtures/federalist/PROVENANCE.md).
The expected rows are computed on the host from the bytes of that very
image, so nothing about the result is typed into this file.
"""
import demo_host as H

DEMO = dict(
    name='fedgrep',
    title='grep, written with ed',
    backends=('text80', 'ut'),
    image='fed',
    gate='check-demo-fedgrep',
)

# What vi must have written, and what `cat grep.sh` must print back:
# content and order, so a dropped or doubled key is red.
SCRIPT = ['#!/bin/sh',
          'ed <<EOF',
          'r $2',
          'g/$1/p',
          'q',
          'EOF']
PATTERN = 'faction'
DIR = '/mnt/MAUX/FED'
PAPER = '/mnt/MAUX/FED/NO.10'
IMAGE = H.os.path.join(H.ROOT, 'build', 'demo-fed.po')


def maux_text(lines):
    """The bytes maux writes for these lines: high bit set, CR ends
    (what `grep ... > file` leaves on the disk), so cksum can be compared
    with the host's own checksum of the expected content."""
    return b''.join(bytes(ord(c) | 0x80 for c in ln) + b'\x8d'
                    for ln in lines)


def run(t):
    paper = H.text('/FED/NO.10', IMAGE)
    names = H.names('/FED', IMAGE)
    # the caption below says 85: the image must agree, or this fails
    assert len(names) == 85, 'the image holds %d papers, not 85' % len(names)
    want = [ln for ln in paper if PATTERN in ln]
    # the papers whose own text says MADISON on a line by itself
    mad, many = [], []
    for n in names:
        body = H.text('/FED/' + n, IMAGE)
        if 'MADISON' in body:
            mad.append(n)
            many += [ln for ln in body if PATTERN in ln]

    t.say('grep is named after an ed command, g/re/p. '
          'Here it is again, written in vi.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('cd /tmp', 'a scratch directory, not the volume root')
    t.press('\x0c')
    t.wait_prompt('clear screen')

    t.run_cmd_echoed('vi grep.sh', 'vi')
    t.wait('"grep.sh" [', 'vi is up on a new file')
    t.hold(1.0)
    t.type_human('i')
    t.type_human('\r'.join(SCRIPT))       # no RET after EOF: no 7th line
    t.hold(1.5)
    t.press(t.ESC)
    t.hold(0.5)
    t.type_human(':wq\r')
    t.wait_prompt('vi quit')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('cat grep.sh', 'show the script')
    t.expect_lines(SCRIPT, 'the script reads back as typed')

    t.say('The Federalist Papers: 85 essays, one file each.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('ls %s | wc -l' % DIR, 'count the papers')
    t.expect_lines([str(len(names))], 'wc counts exactly the papers on the disk')
    t.run_cmd_echoed('head -8 %s' % PAPER, 'the head of No. 10')
    t.expect_lines(paper[:8], 'the head of No. 10, as on the disk')
    t.expect(any(r.strip() == 'MADISON' for r in paper[:8]) and
             'Thursday, November 22, 1787' in ' '.join(paper[:8]),
             'No. 10 is Madison, 22 November 1787')
    t.hold(2.5)

    t.say("Madison's No. 10 is about faction. Run the script on it.")
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('./grep.sh %s %s' % (PATTERN, PAPER), 'grep.sh')
    mine = t.expect_lines(want, 'grep.sh prints the lines holding the word',
                          seconds=120)
    t.expect(len(mine) >= 10, 'several lines')
    t.hold(4.0)         # a pause for effect: time to read the 1787 text
    t.say('ed answers every mistake with a ?. This run gave it none.')

    t.say('The real grep, on the same paper.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('grep %s %s' % (PATTERN, PAPER), 'grep')
    t.expect_lines(mine, 'grep prints the same lines, in the same order')
    t.hold(2.5)

    t.say('Capture both to files, and compare them.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('./grep.sh %s %s > mine' % (PATTERN, PAPER), 'capture')
    t.expect_lines(0, 'the capture prints nothing')
    t.run_cmd_echoed('grep %s %s > real' % (PATTERN, PAPER), 'capture')
    t.expect_lines(0, 'the capture prints nothing')
    t.run_cmd_echoed('cmp mine real', 'cmp')
    t.expect_cmp_silent('cmp says nothing')
    t.hold(2.0)

    t.say('In 1964 Mosteller and Wallace counted words to settle the '
          'disputed papers.')
    t.say('Now the 26 papers this edition heads MADISON.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('ls %s | xargs -I {} grep -lx MADISON %s/{} > madison'
                     % (DIR, DIR), 'find the papers headed MADISON')
    with t.fast(32):
        t.expect_lines(0, 'the capture prints nothing', seconds=3000)
    t.run_cmd_echoed('wc -l madison', 'count')
    t.expect_lines(['%d madison' % len(mad)],
                   'the host finds the same number of papers')
    t.say('One grep.sh per paper headed MADISON, sped up.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('xargs -I {} sh grep.sh %s {} < madison > mine'
                     % PATTERN, 'xargs grep.sh')
    with t.fast(32):
        t.expect_lines(0, 'the capture prints nothing', seconds=3000)
    t.run_cmd_echoed('xargs -I {} grep %s {} < madison > real' % PATTERN,
                     'xargs grep')
    with t.fast(32):
        t.expect_lines(0, 'the capture prints nothing', seconds=3000)
    t.run_cmd_echoed('wc -l mine', 'count')
    t.expect_lines(['%d mine' % len(many)],
                   'one line per match, as the host counts them')
    # the bytes, not the counts: cksum of all three files against the
    # host's cksum of what they must hold (maux text form), then a
    # positive control, so a cmp that always says nothing cannot pass
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('cksum madison mine real', 'cksum')
    listing = maux_text([DIR + '/' + n for n in mad])
    body = maux_text(many)
    want_ck = []
    for fname, data in (('madison', listing), ('mine', body),
                        ('real', body)):
        crc, n = H.cksum(data)
        want_ck.append([str(crc), str(n), fname])
    t.expect([r.split() for r in t.output('cksum')] == want_ck,
             'cksum of madison, mine and real equals the host\'s '
             'checksum of the expected bytes')
    t.expect(want_ck[0][:2] != want_ck[1][:2],
             'the listing and the lines are different bytes')
    t.run_cmd_echoed('cmp mine madison', 'cmp, a positive control')
    t.expect([r.startswith('mine madison differ') for r in
              t.output('cmp says they differ')] == [True],
             'cmp says that mine and madison differ')
    t.run_cmd_echoed('cmp mine real', 'cmp')
    t.expect_cmp_silent('cmp says nothing')
    t.poster()
    t.hold(2.0)
    t.popover('IYKYK ;-)', 4)
