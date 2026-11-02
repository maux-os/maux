"""W9 -- find -exec (docs/DEMOS.md #4, docs/SITE.md sec 4).

"About as canonically Unix as a command line gets": walk a tree, match
names with a glob, and spawn a program for every hit. Here the tree is
the manual, the glob picks the twelve pages that begin with S, and the
program is grep -l, asked which of them mention "expression".

Both answers are computed on the host from the image's own bytes:
the names from the directory, the hits by searching each page's text.
The DEMOS.md caveat ("verify the exact spelling") is this file: the
spelling below is the one that ran, `\\;` and all.
"""
import demo_host as H

DEMO = dict(
    name='findexec',
    title='find -exec',
    backends=('text80', 'ut'),
    image='play',
    gate='check-demo-findexec',
)

GLOB = 'S'
WORD = 'expression'


def run(t):
    pages = [n for n in H.names('/USR/MAN') if n.startswith(GLOB)]
    hits = [n for n in pages
            if any(WORD in ln for ln in H.text('/USR/MAN/' + n))]

    t.say('find: walk a tree, match names, run a program on each hit.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('cd /usr/man', 'cd')
    t.run_cmd_echoed("find . -name '%s*'" % GLOB, 'find')
    t.expect_lines(['./' + n for n in pages],
                   'find lists every page whose name starts with %s'
                   % GLOB)
    t.hold(3.0)

    t.say('Now -exec: grep -l runs once for every page that matched.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed("find . -name '%s*' -exec grep -l %s {} \\;"
                     % (GLOB, WORD), 'find -exec')
    t.expect_lines(['./' + n for n in hits],
                   'only the pages that mention "%s" are named' % WORD,
                   seconds=60)
    t.expect(0 < len(hits) < len(pages), 'host: the filter is selective')
    t.say('A tree walk, a glob, a spawn per hit: on a 1 MHz 65C02.')
    t.say('Ken Thompson, by repute: when in doubt, use brute force.')
    t.poster()
    t.hold(1.0)
