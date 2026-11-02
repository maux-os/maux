"""W7 -- vi hands its text to other programs (docs/DEMO-VIBANG.md).

vi is a real editor on a real Unix: its `!` commands pipe the buffer
through the rest of the system. On a new file in /tmp:

    :r !ls /usr/man | head -8    a pipeline's output becomes text
    (a little editing: search, dd, p)
    :%!sort -r                   the whole buffer through sort
    :2,4!tr A-Z a-z              a range through tr
    :%!nl                        line numbers from another program
    :w, then :!wc -l notes       a shell escape on the file just
                                 written; its answer is held
    :q, then cat, cksum and ls at the shell

Every expected buffer is computed on the host from the bytes of the
image (the names in /usr/man) and the POSIX behaviour of the tools;
nothing about a result is typed into this file. The file written to
disk is compared by content and order (cat) and by bytes (cksum).

`:w !cmd` (the buffer piped OUT to a command) is NOT filmed: this vi
does not hold its output as POSIX requires (docs/DEMO-VIBANG-NOTES.md).

vi's own normal-mode `!motion` (`!!`, `!}`) does not exist in this vi:
see docs/DEMO-VIBANG-NOTES.md. The ex colon forms above are what the
film shows.
"""
import demo_host as H

DEMO = dict(
    name='vi',
    title='vi hands its text to other programs',
    backends=('text80', 'ut'),
    image='play',
    gate='check-demo-vi',
)

MOVED = 'BASENAME'
HEAD = 8
BANNER = '[Hit return to continue]'


def maux_text(lines):
    """The bytes maux writes for these lines: high bit set, CR ends
    (a tab is $89), so cksum can be compared with the host's own."""
    return b''.join(bytes(ord(c) | 0x80 for c in ln) + b'\x8d'
                    for ln in lines)


def nl(lines):
    """POSIX nl, maux's defaults: right-justified in 6, a tab, the
    line; a blank line is not numbered."""
    out, n = [], 0
    for ln in lines:
        if ln == '':
            out.append('')
        else:
            n += 1
            out.append('%6d\t%s' % (n, ln))
    return out


def glass(lines):
    """What the console paints for these lines: tabs expanded."""
    return [ln.expandtabs(8) for ln in lines]


def diffs(scr, want):
    """(row, col) of every cell where the glass differs from `want`."""
    out = []
    for r, (a, b) in enumerate(zip(scr, want)):
        a, b = a.ljust(80), b.ljust(80)
        out += [(r, c) for c in range(80) if a[c] != b[c]]
    return out


def wait_rows(t, rows, label, slices=300):
    """Poll the glass until its top rows are `rows` and the rows under
    them are all '~' (vi repaints asynchronously; the first look may be
    the stale picture). Every cell of the 23-row window must match
    exactly, the cell under vi's cursor included (the recorder reads the
    //e's inverse cell as the letter it is); the status row is not read.
    The file on disk is checked exactly at the end."""
    n = len(rows)
    want = [r.rstrip() for r in rows] + ['~'] * (23 - n)
    for _ in range(slices):
        full = [r.rstrip() for r in t.screen()]
        scr = full[:23]
        if len(scr) == 23 and not diffs(scr, want):
            t.expect(True, label)          # checkpoints the screen
            return
        t._slice()
    import sys
    print('wait_rows %r: differing cells %r' % (label, diffs(scr, want)),
          file=sys.stderr)
    t.expect(False, label)


def run(t):
    names = H.names('/USR/MAN')[:HEAD]
    assert len(names) == HEAD and MOVED in names, names
    step1 = list(names)                    # after :r !ls | head
    step2 = [n for n in step1 if n != MOVED] + [MOVED]   # dd, G, p
    step3 = sorted(step2, reverse=True)    # :%!sort -r
    step4 = list(step3)                    # :2,4!tr A-Z a-z
    for i in (1, 2, 3):
        step4[i] = step4[i].lower()
    step5 = nl(step4)                      # :%!nl
    count = [str(len(step5))]              # the count :!wc -l shows
    # the moved name is in the lines that tr lowers: the sort puts it
    # third, so the film shows tr changing a name it just moved
    assert step3[2] == MOVED, step3
    assert count == [str(HEAD)], count     # the caption says HEAD lines

    t.say('vi, in 80 columns. On a IIe you once asked for those with PR#3.')
    t.say('vi on a new file in /tmp.')
    t.say('Its ! commands hand text to other programs and take the '
          'answer back.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('cd /tmp', 'a scratch directory, not the volume root')
    t.run_cmd_echoed('vi notes', 'vi')
    t.wait('"notes"', 'vi is up on a new file')
    t.hold(1.5)

    t.say(':r !ls /usr/man | head -8 -- the output of a pipeline '
          'becomes text in the buffer.')
    t.type_human(':r !ls /usr/man | head -%d\r' % HEAD)
    wait_rows(t, [''] + step1, 'the buffer is a blank line and the first '
              '%d names in /usr/man, in order' % HEAD)
    t.hold(2.0)

    t.say('A little editing: delete the blank line, then move %s '
          'to the end.' % MOVED)
    t.type_human('1Gdd')
    wait_rows(t, step1, 'the blank line is gone')
    t.hold(1.0)
    t.type_human('/%s\r' % MOVED)
    t.hold(1.5)
    t.type_human('dd')
    t.hold(1.0)
    t.type_human('Gp')
    wait_rows(t, step2, 'the buffer ends with %s' % MOVED)
    t.hold(2.0)

    t.say(':%!sort -r -- the whole buffer goes through sort, and '
          'comes back.')
    t.type_human(':%!sort -r\r')
    wait_rows(t, step3, 'the buffer is reverse sorted, in order')

    t.say(':2,4!tr A-Z a-z -- only lines 2 to 4 go through tr.')
    t.type_human(':2,4!tr A-Z a-z\r')
    wait_rows(t, step4, 'lines 2 to 4 are lower case, the rest unchanged')
    t.hold(2.5)

    t.say(':%!nl -- line numbers, from another program.')
    t.type_human(':%!nl\r')
    wait_rows(t, glass(step5), 'every line numbered, in order')
    t.hold(2.5)

    t.say(':w writes the file.')
    t.type_human(':w\r')
    t.hold(1.5)
    t.say(':!wc -l notes -- a shell escape runs wc on it and holds the '
          'answer: %d lines.' % HEAD)
    t.type_human(':!wc -l notes\r')
    t.wait(BANNER, 'the shell escape holds its output')
    scr = [r.rstrip() for r in t.screen()]
    at = max(i for i, r in enumerate(scr) if r == BANNER)
    t.expect(scr[at - 2] == ':!wc -l notes' and
             scr[at - 1].split() == [count[0], 'notes'],
             'wc counted exactly the lines of the file: %s' % count[0])
    t.hold(2.5)
    t.press('\r')
    t.wait_gone(BANNER, 'the banner is cleared')
    wait_rows(t, glass(step5), 'back in the editor, buffer unchanged')
    t.hold(1.0)

    t.say('How do you leave vi? Like this. The disk matches the screen.')
    t.type_human(':q\r')
    t.wait_prompt('vi quit')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('cat notes', 'cat')
    t.expect_lines(glass(step5), 'the file on disk is the numbered list')
    t.poster()
    t.hold(2.0)
    t.run_cmd_echoed('cksum notes', 'cksum')
    want_ck = []
    for fname, data in (('notes', maux_text(step5)),):
        crc, n = H.cksum(data)
        want_ck.append([str(crc), str(n), fname])
    t.expect([r.split() for r in t.output('cksum')] == want_ck,
             'cksum of notes equals the host\'s checksum of the expected '
             'bytes')
    t.run_cmd_echoed('ls', 'ls')
    t.expect(H.columns_to_names(t.output('ls')) == ['notes'],
             'no editor temporary file is left behind')
    t.hold(3.0)
