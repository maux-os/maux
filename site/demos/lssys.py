"""W17 -- a ProDOS 8 program, written and built on maux, run by ProDOS
itself (docs/SITE.md sec 4 and 5 L7).

A person copies the LSSYS lesson into /tmp, reads its Makefile, and
builds LS.SYSTEM with nas and ld. `ls -l` says SYS: a ProDOS 8 system
file. Then `make test` -- and maux gets out of the way. The farewell
prints, the machine boots the program under real ProDOS 8, the program
lists the directory it is sitting in, waits for a key, and QUITs, which
brings maux back. `sh check` then compares what ProDOS listed against
what maux's own `ls` lists, and they agree.

LS.SYSTEM knows nothing of maux: it calls the MLI at $BF00 and the
monitor's COUT, and it runs on any ProDOS 8 machine (examples/lssys/ls.s
says so, and check-examples proves it on a stock ProDOS 2.4 disk with no
maux on it at all).

ONE DISPLAY, ON PURPOSE. Every other demo here declares both, but this
one is `backends=('text80',)`, because during a `bye` window the card
does not own the glass: byelaunch.s hands the display back to the
motherboard, and MEASURED (docs/DEMO-W17-NOTES.md) the UltraTerm's
`vidsel` is false from the farewell to the restore, its surface frozen
on `Leaving maux for ProDOS...` for the whole tenant run. The
motherboard's 40 columns ARE the tenant's glass. Filming the card would
show a still picture over the one beat this film exists for, and an
assertion taken there would read leftover maux text.

Checks. The copied listing is the lesson directory in the TREE, so the
film cannot drift from the lesson; the Makefile on screen is the
lesson's Makefile, line for line, TABs included; `make` echoes the nas
and ld lines and nothing else; `ls -l` says SYS. Across the window, the
names ProDOS printed are required on the 40-column page. After the
restore the ordinary assertions work again: the maux-side rows of
`make test` in order, `echo $?` is 0, `sort GOT` and `cat WANT` are both
exactly the names. Then the HOST reads the disk the guest wrote
(image_export, a2til) and requires GOT to be maux text -- every byte
with bit 7 set, every line ended by $8D -- which is what ls.s claims to
write and what lets maux's own tools compare it with no conversion.
"""
import os
import tempfile

import demo_host as H

DEMO = dict(
    name='lssys',
    title='a ProDOS 8 program, built on maux',
    backends=('text80',),
    image='full',
    gate='check-demo-lssys',
)

EXAMPLE = os.path.join(H.ROOT, 'examples', 'lssys')
# the lesson's own files, which are what `cp` copies and `ls` prints.
# In `ls`'s order, which is case-INSENSITIVE (lssort.s sorts with
# STRCMPI), so `check` comes before `Makefile`: this directory is the
# first one any demo has listed that holds both cases.
SOURCES = H.ls_order(os.listdir(EXAMPLE))
# what LS.SYSTEM must list: the copies, upper case as ProDOS stores
# them, plus what the build and the harness add before it runs. GOT is
# created only after the directory has been read, so it never lists
# itself (examples/lssys/ls.s).
LISTED = sorted([n.upper() for n in SOURCES] +
                ['LS.O', 'LS.SYSTEM', 'WANT'])
# `make test`, maux's side of it: the recipe lines, the farewell, the
# return, and the check that compares the two listings
TEST_ROWS = ['rm -f GOT', 'sh mkwant', 'bye LS.SYSTEM',
             'Leaving maux for ProDOS...', 'Welcome back.', 'sh check']
NAS_LINE = 'nas -o ls.o ls.s'
LD_LINE = 'ld -t FF -a 2000 -o LS.SYSTEM ls.o'


def lesson(name):
    """A lesson file's lines, exactly as the tree holds them."""
    with open(os.path.join(EXAMPLE, name), 'rb') as f:
        return f.read().decode('ascii').rstrip('\n').split('\n')


def exported_got(t):
    """GOT as the ProDOS program wrote it, read off the disk the guest
    wrote. The mount is a copy, so export it (unit 1) and read the
    export: this is the bytes, not maux's rendering of them."""
    d = tempfile.mkdtemp(prefix='demo-lssys-',
                         dir=os.path.join(H.ROOT, 'build'))
    out = os.path.join(d, 'after.po')
    try:
        r = t.c.call_tool('image_export', {'unit': 1, 'path': out})
        if r.get('ok') is False:
            raise AssertionError('image_export failed: %r' % (r,))
        return H.read('/TMP/lssys/GOT', out)
    finally:
        for f in os.listdir(d):
            os.remove(os.path.join(d, f))
        os.rmdir(d)


def run(t):
    t.say('A ProDOS 8 program, written and built on maux.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('cd /tmp', 'a scratch directory')
    t.run_cmd_echoed('mkdir lssys; cd lssys', 'a directory of our own')
    t.expect_cmp_silent('mkdir prints nothing')
    t.run_cmd_echoed('cp /usr/src/examples/LSSYS/* .', 'copy the lesson')
    t.expect_cmp_silent('cp prints nothing')
    t.run_cmd_echoed('ls', 'what the lesson is')
    t.expect(H.columns_to_names(t.output('ls')) == SOURCES,
             'the copy holds the lesson files: %s' % ' '.join(SOURCES))

    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.say('The Makefile is the test harness.')
    t.run_cmd_echoed('cat Makefile', 'show the Makefile')
    t.expect_lines([x.expandtabs(8) for x in lesson('Makefile')],
                   'the Makefile is the lesson\'s (TAB = 8 columns)')
    t.say('`test` builds it, runs it under ProDOS, then compares.',
          over=True)
    t.hold(3.0)
    t.endcue()

    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('make', 'build it')
    t.say('nas assembles, ld links a SYS file at $2000.', over=True)
    rows = t.output('make runs nas then ld', seconds=180)
    t.expect(len(rows) == 3 and rows[0] == NAS_LINE and
             rows[1].startswith('nas: ') and rows[1].endswith(' -> ls.o')
             and rows[2] == LD_LINE,
             'make echoes the nas line, nas reports, then the ld line')
    t.endcue()
    t.run_cmd_echoed('ls -l LS.SYSTEM', 'what kind of file it is')
    rows = t.output('ls -l LS.SYSTEM')
    f = rows[0].split() if rows else []
    t.expect(len(rows) == 1 and f[0] == 'SYS' and f[-1] == 'LS.SYSTEM',
             'ls -l says SYS: ProDOS 8 will boot it (%r)'
             % (rows[0] if rows else None,))
    t.say('SYS. ProDOS 8 loads it flat at $2000 and jumps there.')

    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.say('Now maux gets out of the way.')
    rows, window = t.run_bye('make test', LISTED, 'make test', key='x')
    # the poster is the screen that tells the whole story: the farewell,
    # the tenant's run, and the shell coming back. The tenant's own
    # 40-column listing is the more dramatic picture but a far worse
    # one at gallery size -- seven short words on a black field.
    t.poster()
    t.expect(sorted(w for w in window if w in LISTED) == LISTED,
             'ProDOS listed the directory: %s' % ' '.join(LISTED))
    t.expect_lines(TEST_ROWS, 'make test: out to ProDOS and back')
    t.run_cmd_echoed('echo $?', 'did the comparison pass')
    t.expect_lines(['0'], 'make test succeeded')

    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.say('GOT is what ProDOS wrote. WANT is what maux\'s ls says.')
    t.run_cmd_echoed('sort GOT', 'what ProDOS listed')
    t.expect_lines(LISTED, 'GOT holds exactly the names')
    t.run_cmd_echoed('cat WANT', 'what maux lists')
    t.expect_lines(LISTED, 'WANT holds exactly the same names')
    got = exported_got(t)
    t.expect(got and all(b & 0x80 for b in got) and
             got.endswith(b'\x8d') and
             sorted(''.join(chr(b & 0x7F) for b in got).split('\r')[:-1])
             == LISTED,
             'on the disk, GOT is maux text (high bit, $8D lines) and '
             'holds the %d names' % len(LISTED))
    t.popover('no maux in there', 4)
