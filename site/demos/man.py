"""W8 -- man and more (docs/SITE.md sec 4, docs/DEMOS-W1.md).

The manual is on the disk. `man sh` pages with SPACE, `/` searches, `q`
quits, and the shell screen comes back exactly as it was (man pages on
the alternate screen, docs/VI-ALTSCREEN.md).

Every row asserted is computed on the host from the bytes of
/USR/MAN/SH on the image: at each stop the WHOLE screenful (23 rows)
must equal the host's page text, emphasised lines included (the ANSI
sequences of the file are what draw the emphasis; the text under them
is compared). The checkpoint is the raw machine screen, nothing
substituted: the recorder reads the //e's inverse cells as the letters
they are (DemoAPI.screen), as the card's text always is.
"""
import re

import demo_host as H

DEMO = dict(
    name='man',
    title='man and more',
    backends=('text80', 'ut'),
    image='play',
    gate='check-demo-man',
)

PAGE = 23                   # more's screenful: 24 rows less the prompt
WORD = 'trap'
EMPH = re.compile('\x1b\\[[0-9;]*m')


def rows_of(t):
    return [r.rstrip() for r in t.screen()]


def window(page, top):
    """The rows `more` shows from line `top` on: one screenful."""
    return [ln.rstrip() for ln in page[top:top + PAGE]]


def wait_window(t, top, page, label, slices=80):
    """Poll until the screen's pager rows are the host's page from line
    `top` on, then let it hold still and require it again (more
    repaints row by row, and the card repaints faster than the //e)."""
    want = window(page, top)
    for _ in range(slices):
        if rows_of(t)[:len(want)] == want:
            H.still(t, label)
            t.expect(rows_of(t)[:len(want)] == want, label)
            return
        t._slice()
    got = rows_of(t)
    t.expect(False, label + ': first differing row %r vs host %r' % (
        next((g for g, w in zip(got, want) if g != w), None),
        next((w for g, w in zip(got, want) if g != w), None)))


def run(t):
    page = [EMPH.sub('', ln) for ln in H.text('/USR/MAN/SH')]
    t.expect(len(page) > 3 * PAGE and page[PAGE].strip(),
             'host: the page is long and the second screenful is not blank')
    # a search starts below the top row of what is on screen
    hit = next(i for i in range(PAGE + 1, len(page)) if WORD in page[i])

    t.say('Here RTFM is not a brush-off: the whole manual is on the disk.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('man sh', 'man')
    t.wait('--More--', 'the first page is up')
    wait_window(t, 0, page, 'the first screenful is the page\'s first 23 lines')
    t.hold(3.0)

    t.say('SPACE for the next page.')
    t.press(' ')
    wait_window(t, PAGE, page, 'the second screenful is the next 23 lines')
    t.hold(3.0)

    t.say('/ searches, the way it does in ed, ex and vi.')
    t.type_human('/' + WORD + '\r')
    wait_window(t, hit, page, 'the search puts the matching line on top')
    t.expect(WORD in rows_of(t)[0], 'the top row holds the word')
    t.wait('--More--', 'the pager is waiting again')
    H.still(t, 'search result')
    t.poster()
    t.hold(3.0)

    t.say('q, and the shell screen comes back as it was.')
    t.press('q')
    t.wait_prompt('quit')
    shown = [r for r in rows_of(t) if r]
    t.expect(shown == ['$ man sh', '$'],
             'the shell screen is back, untouched')
    t.hold(2.0)
