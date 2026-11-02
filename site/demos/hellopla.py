"""W18 -- hello, world in PLASMA, written, compiled and run on the
machine, then run again as a program cut by the plasma cutter
(docs/SITE.md sec 4 and 5 L6).

A person makes a directory, writes David Schmenk's own hello.pla in vi,
writes a Makefile in vi (a real TAB before each recipe line), runs make,
which compiles it with plasm, and runs the module with plasma. That is
PLASMA's run-time loader: plasma reads the runtime and resolves the
module's imports on every launch. Then make again, and the SAME program as
the plasma cutter (plascut, on the host) made it: one BIN file with the
loading already done, copied from the disk and run, cold and then warm.

Timing. Each run is timed in emulated cycles from RETURN to the output
appearing (to the nearest recorder slice). The figures go into the
captions (so each display's film says what ITS run measured) and, through
t.measure(), into the film's stamp, where the lesson page reads them. They
are never in a checkpoint label: the two displays differ.

Checks. The typed hello.pla is examples/hellopla/hello.pla: the lines are
required to equal the file's, exactly, and `cmp` of the typed file with
the staged lesson file is silent (a trailing space fails it). The Makefile
is compared the same way. The host then reads the disk the guest wrote
(image_export, a2til): hello.mod is a REL file ($FE), the copy of the cut
program a BIN ($06, aux_type $0800), and the module the machine's plasm
wrote equals the one the host's xplasm (-AMW) writes, but for the ESD
numbering of its one import.
"""
import os
import tempfile

import demo_host as H

DEMO = dict(
    name='hellopla',
    title='hello, world, in PLASMA',
    backends=('text80', 'ut'),
    image='full',
    gate='check-demo-hellopla',
)

EXAMPLE = os.path.join(H.ROOT, 'examples', 'hellopla')
HELLO = 'Hello, world.'
REL_TYPE = 0xFE
BIN_TYPE = 0x06
LOAD_ADDR = 0x0800
COOKED = '/usr/src/examples/HELLOPLA/HELLO'

# What each measured figure is, in the caption that states it: the words
# right before "N.NN million". scripts/demo_stamp.py (film_errors) holds
# the stamp's measures to these cues in the published .vtt, and to the
# order below, so a stamp edited to another figure goes red.
MEASURE_CAPTIONS = {
    'plasma_first': 'plasma hello.mod, the first time:',
    'cooked_first': './hello, cut by plascut, the first time:',
    'cooked_warm': './hello again, warm:',
}
MEASURE_ORDER = [('cooked_first', 'plasma_first'),
                 ('cooked_warm', 'cooked_first')]


def example(name):
    with open(os.path.join(EXAMPLE, name), 'rb') as f:
        text = f.read().decode('ascii')
    lines = text.split('\n')
    assert lines.pop() == '', name + ' does not end in a newline'
    return lines


# what vi must have written, and what `cat` prints: THE EXAMPLE'S LINES
SOURCE = example('hello.pla')
MAKEFILE = example('Makefile')

MAKE_ROWS_HEAD = ['rm -f hello.mod', 'plasm hello.pla hello.mod',
                  'PLASMA Compiler v2.21']
MAKE_ROWS_TAIL = ['', '', 'DATA:....1 bytes', 'INIT:22 bytes', '',
                  'Total bytes compiled: 23', 'ls hello.mod', 'hello.mod']


def disk_files(t, path):
    """{name: (type, aux_type, bytes)} of the files in PATH on the disk
    the guest wrote: the mount is a copy, so export it (unit 1) and read
    the export."""
    from a2til import prodos
    d = tempfile.mkdtemp(prefix='demo-hellopla-',
                         dir=os.path.join(H.ROOT, 'build'))
    out = os.path.join(d, 'after.po')
    try:
        r = t.c.call_tool('image_export', {'unit': 1, 'path': out})
        if r.get('ok') is False:
            raise AssertionError('image_export failed: %r' % (r,))
        v = prodos.Volume(out, readonly=True)
        try:
            return {e.name: (e.type, e.aux_type,
                             v.read_file(path + '/' + e.name))
                    for e in v.scandir(path) if e.type != 0x0F}
        finally:
            v.close()
    finally:
        for f in os.listdir(d):
            os.remove(os.path.join(d, f))
        os.rmdir(d)


def same_but_esd(guest, host):
    """The module the machine's plasm wrote and the one the host's xplasm
    wrote (-AMW, no optimizer, as plasm has none) are the same bytes except
    for the ESD numbering of the one import: the index in its relocation
    record and in its ESD entry. Returns the differing offsets, or None
    when anything else differs."""
    if len(guest) != len(host):
        return None
    rld = host.find(b'\x91\x23\x00') + 3     # 91 addr.lo addr.hi ESD
    esd = host.find(b'\xd0\xd5\xd4\x53\x10') + 5  # PUTS, flag $10, index
    diff = [i for i in range(len(host)) if guest[i] != host[i]]
    return diff if set(diff) <= {rld, esd} else None


def vi_write(t, name, lines, prompt_label):
    t.run_cmd_echoed('vi ' + name, 'vi ' + name)
    t.wait('"%s" [' % name, 'vi is up on a new file')
    t.hold(1.0)
    t.type_human('i')
    t.type_human('\r'.join(lines))        # no RET after the last line
    t.hold(1.5)
    t.press(t.ESC)
    t.hold(0.5)
    t.type_human(':wq\r')
    t.wait_prompt(prompt_label)
    t.press('\x0c')
    t.wait_prompt('clear screen')


def cycle(t):
    return t.c.call_tool('step', {'cycles': 0})['cycle']


def startup(t, cmd, label):
    """Type CMD, press RETURN, and count the emulated cycles until the
    output row appears (to the nearest slice, at most about 0.17 million
    cycles: the unit of the recorder's clock). Then settle and require
    exactly the output. Returns the cycles."""
    t.wait_prompt(label + ': prompt before')
    t.type_and_expect_echo(cmd, label)
    t.last_cmd = cmd
    start = cycle(t)
    t.enter()
    end = None
    for _ in range(3000):
        rows = [r.rstrip() for r in t.screen()]
        below = rows[[i for i, r in enumerate(rows)
                      if r.startswith('$ ' + cmd[:t.width - 2])][-1] + 1:]
        if HELLO in below:
            end = cycle(t)
            break
        t._slice()
    assert end is not None, label + ': the output never appeared'
    t.expect_lines([HELLO], label + ' prints ' + HELLO)
    return end - start


def millions(n):
    return "%.2f million" % (n / 1e6)


def caption(t, text, action=None):
    """Say TEXT (a beat: the screen holds, no key, while it is read),
    then run ACTION."""
    t.say(text)
    if action:
        action()


def clear(t):
    t.press('\x0c')
    t.wait_prompt('clear screen')


def run(t):
    caption(t, 'hello, world, in PLASMA, on the machine itself.')
    clear(t)
    t.run_cmd_echoed('cd /tmp', 'a scratch directory')
    t.run_cmd_echoed('mkdir hellopla; cd hellopla', 'a directory of our own')
    t.expect_lines(0, 'mkdir prints nothing')
    clear(t)

    caption(t, "David Schmenk's hello.pla, typed in vi exactly as he "
               "wrote it.",
            lambda: vi_write(t, 'hello.pla', SOURCE, 'vi quit'))
    t.run_cmd_echoed('cat hello.pla', 'show the source')
    t.expect_lines(SOURCE, 'the source reads back as typed')
    t.hold(2.0)
    clear(t)
    t.run_cmd_echoed('cmp hello.pla /usr/src/examples/HELLOPLA/hello.pla',
                     'cmp with the lesson file')
    t.expect_cmp_silent('what vi wrote is the lesson file, byte for byte')

    clear(t)
    caption(t, 'A Makefile. make needs a real TAB before each command.',
            lambda: vi_write(t, 'Makefile', MAKEFILE, 'vi quit'))
    t.run_cmd_echoed('cat Makefile', 'show the Makefile')
    t.expect_lines([x.expandtabs(8) for x in MAKEFILE],
                   'the Makefile reads back as typed (TAB = 8 columns)')
    t.hold(2.5)

    clear(t)
    t.run_cmd_echoed('make', 'make')
    t.say('make runs plasm, the PLASMA compiler, on the machine itself.',
          over=True)
    rows = t.output('make runs plasm', seconds=120)
    t.expect(len(rows) == 12 and rows[:3] == MAKE_ROWS_HEAD and
             rows[3].startswith('Data+Code buffer size = $') and
             rows[4:] == MAKE_ROWS_TAIL,
             'make echoes rm, plasm and ls, and plasm compiles 23 bytes')
    t.endcue()
    t.hold(1.0)

    clear(t)
    t.say('plasma runs the module.')
    t.say('At every launch, plasma loads its runtime first.')
    t.say('Then it resolves the module\'s imports: a run-time loader.')
    plasma_first = startup(t, 'plasma hello.mod', 'plasma hello.mod')
    t.poster()
    caption(t, MEASURE_CAPTIONS['plasma_first'] + ' %s cycles from '
               'RETURN to the output.' % millions(plasma_first))
    t.say('A capital H and a full stop: Schmenk\'s spelling, not K&R\'s.')

    clear(t)
    caption(t, 'make again prints nothing, because hello.mod is no older '
               'than hello.pla.',
            lambda: (t.run_cmd_echoed('make', 'make again'),
                     t.expect_lines([], 'make says nothing')))

    clear(t)
    caption(t, 'The plasma cutter does the loading once, on the host.')
    caption(t, 'HELLO is the same program with that work already done.')
    caption(t, 'plascut makes one file, and the shell runs it.',
            lambda: (t.run_cmd_echoed('ls -l /usr/src/examples/HELLOPLA',
                                      'the lesson files'),
                     check_lesson_listing(t)))
    clear(t)
    t.run_cmd_echoed('cp ' + COOKED + ' hello', 'copy the cooked program')
    t.expect_lines(0, 'cp prints nothing')

    clear(t)
    cooked_first = startup(t, './hello', './hello')
    caption(t, MEASURE_CAPTIONS['cooked_first'] + ' %s cycles.'
               % millions(cooked_first))
    caption(t, 'Against %s for plasma hello.mod: the loading is done.'
            % millions(plasma_first))
    clear(t)
    cooked_warm = startup(t, './hello', './hello again')
    caption(t, MEASURE_CAPTIONS['cooked_warm'] + ' %s cycles.'
            % millions(cooked_warm))
    t.say('The 65C02 is no faster. It is doing less.')

    # what the run measured goes into the film's stamp (t.measure); the
    # lesson quotes it. A plausible range, and the order the story needs.
    for name, n in (('plasma_first', plasma_first),
                    ('cooked_first', cooked_first),
                    ('cooked_warm', cooked_warm)):
        t.measure(name, n)
        assert 100_000 < n < 5_000_000, (name, n)
    for lo, hi in MEASURE_ORDER:
        assert t.measures[lo] < t.measures[hi], (lo, hi, t.measures)

    clear(t)
    t.run_cmd_echoed('cmp hello ' + COOKED, 'cmp with the disk file')
    t.expect_cmp_silent('the copy is the staged program, byte for byte')
    files = disk_files(t, '/TMP/hellopla')
    t.expect(files['hello.mod'][0] == REL_TYPE and
             files['hello'][:2] == (BIN_TYPE, LOAD_ADDR),
             'on the disk, hello.mod is REL ($FE) and hello is a BIN whose '
             'aux_type is $%04X' % LOAD_ADDR)
    with open(os.path.join(H.ROOT, 'build', 'hellopla', 'hello.mod'),
              'rb') as f:
        host = f.read()
    diff = same_but_esd(files['hello.mod'][2], host)
    t.expect(diff is not None,
             'the module plasm wrote on the machine is the one xplasm '
             'writes on the host (-AMW), but for the ESD numbering')
    t.hold(2.0)


def check_lesson_listing(t):
    rows = t.output('ls -l the lesson files')
    got = {}
    for r in rows:
        f = r.split()
        got[f[-1]] = f[0]
    t.expect(len(rows) == 3 and got == {'HELLO': 'BIN', 'hello.pla': 'TXT',
                                        'Makefile': 'TXT'},
             'HELLO is a BIN beside the two text files')
