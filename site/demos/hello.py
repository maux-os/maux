"""W15 -- hello, world in assembly, written and built on the machine
(docs/SITE.md sec 4).

A person makes a directory, writes hello.s in vi, writes a Makefile in
vi (make needs a real TAB before each recipe line, and vi inserts one),
runs make, which assembles with nas and links with ld, and runs the
program. Then make again: nothing to do. ls -l shows hello as a BIN.

The film types a SHORT hello.s: the code, the two ext lines, the two put
lines, a comment. examples/hello/hello.s is the lesson's file, with its
long header; the code lines here are checked against it on the host
(the code and data lines must be the example's, in order), so the film
cannot drift from the lesson. The Makefile is compared the same way
(its non-comment lines, exactly, TABs included). And the host reads the
disk the guest wrote (image_export, a2til) and requires hello to be a
BIN file whose aux_type is the load address, $0800.
"""
import os
import tempfile

import demo_host as H

DEMO = dict(
    name='hello',
    title='hello, world, in assembly',
    backends=('text80', 'ut'),
    image='full',
    gate='check-demo-hello',
)

# the film's hello.s: what vi must have written, and what `cat` prints
SOURCE = ['* hello, world in 6502 assembly',
          '        rel',
          '        lst   off',
          'PUTS    ext',
          'EXIT    ext',
          '        put   /usr/inc/sc.fd.equ',
          '        put   /usr/inc/zp.equ',
          '',
          'START   lda   #<MSG',
          '        sta   PTR0',
          '        lda   #>MSG',
          '        sta   PTR0+1',
          '        ldx   #FD_STDOUT',
          '        jsr   PUTS',
          '        lda   #0',
          '        jsr   EXIT',
          '',
          "MSG     asc   'hello, world',0D,00"]

MAKEFILE = ['hello: hello.o',
            '\tld -o hello hello.o -L /usr/lib -l a',
            'hello.o: hello.s',
            '\tnas -o hello.o hello.s',
            'clean:',
            '\trm -f hello hello.o']
BIN_TYPE = 0x06
LOAD_ADDR = 0x0800
NAS_LINE = 'nas -o hello.o hello.s'
LD_LINE = 'ld -o hello hello.o -L /usr/lib -l a'
EXAMPLE = os.path.join(H.ROOT, 'examples', 'hello')


def squeeze(line):
    """A source line with its column spacing removed: the tokens, which
    is what the film must share with the lesson's file."""
    return ' '.join(line.split())


def example_code():
    """The lesson's code and data lines, without its comment block."""
    with open(os.path.join(EXAMPLE, 'hello.s'), 'rb') as f:
        lines = f.read().decode('ascii').split('\n')
    return [squeeze(x) for x in lines if x.strip() and
            not x.startswith('*')]


def example_makefile():
    """The lesson's Makefile without its comment lines, exactly."""
    with open(os.path.join(EXAMPLE, 'Makefile'), 'rb') as f:
        lines = f.read().decode('ascii').split('\n')
    return [x for x in lines if x.strip() and not x.startswith('#')]


def disk_entry(t, path, name):
    """(type, aux_type) of NAME in PATH on the disk the guest wrote:
    the mount is a copy, so export it (unit 1) and read the export."""
    from a2til import prodos
    d = tempfile.mkdtemp(prefix='demo-hello-', dir=os.path.join(H.ROOT,
                                                               'build'))
    out = os.path.join(d, 'after.po')
    try:
        r = t.c.call_tool('image_export', {'unit': 1, 'path': out})
        if r.get('ok') is False:
            raise AssertionError('image_export failed: %r' % (r,))
        v = prodos.Volume(out, readonly=True)
        for e in v.scandir(path):
            if e.name == name:
                return e.type, e.aux_type
        raise AssertionError('%s is not in %s on the disk' % (name, path))
    finally:
        for f in os.listdir(d):
            os.remove(os.path.join(d, f))
        os.rmdir(d)


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


def run(t):
    # the film's source is the lesson's source, less its header
    film = [squeeze(x) for x in SOURCE if x.strip() and
            not x.startswith('*')]
    assert film == example_code(), 'the film\'s hello.s is not the example'
    assert MAKEFILE == example_makefile(), \
        'the film\'s Makefile is not the example\'s'

    t.say('hello, world, in 6502 assembly, on the machine itself.')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('cd /tmp', 'a scratch directory')
    t.run_cmd_echoed('mkdir hello; cd hello', 'a directory of our own')
    t.expect_lines(0, 'mkdir prints nothing')
    t.press('\x0c')
    t.wait_prompt('clear screen')

    t.say('The source, in vi.')
    vi_write(t, 'hello.s', SOURCE, 'vi quit')
    t.run_cmd_echoed('cat hello.s', 'show the source')
    t.expect_lines(SOURCE, 'the source reads back as typed')
    t.say('ext names two routines in liba, a libc with no C in it.')
    t.say('put pulls in the equates.')

    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.say('A Makefile. make needs a real TAB before each command.')
    t.say('make is Stuart Feldman\'s, 1976. The TAB stuck once a dozen '
          'users had it.')
    vi_write(t, 'Makefile', MAKEFILE, 'vi quit')
    t.run_cmd_echoed('cat Makefile', 'show the Makefile')
    t.expect_lines([x.expandtabs(8) for x in MAKEFILE],
                   'the Makefile reads back as typed (TAB = 8 columns)')
    t.hold(2.5)

    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('make', 'make')
    t.say('make assembles with nas, then links with ld.', over=True)
    rows = t.output('make runs nas then ld', seconds=120)
    t.expect(len(rows) == 3 and rows[0] == NAS_LINE and
             rows[1].startswith('nas: ') and rows[1].endswith(' -> hello.o')
             and rows[2] == LD_LINE,
             'make echoes the nas line, nas reports, then the ld line')
    t.endcue()

    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.run_cmd_echoed('./hello', 'run it')
    t.expect_lines(['hello, world'], 'it prints hello, world')
    t.poster()
    t.say('Lower case, a comma, no exclamation mark: the K&R spelling.')

    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.say('Nothing changed, so make has nothing to do.')
    t.run_cmd_echoed('make', 'make again')
    t.expect_lines([], 'make says nothing: hello is up to date')
    t.press('\x0c')
    t.wait_prompt('clear screen')
    t.say('hello is a BIN file; its aux_type is the load address, $0800.')
    t.run_cmd_echoed('ls -l', 'ls -l')
    rows = t.output('ls -l')
    # directory order is the volume's, not ours: one row per file, by
    # name, its type and (for the two text files) its exact size
    got = {}
    for r in rows:
        f = r.split()
        got[f[-1]] = (f[0], f[1])
    src = len(''.join(x + '\n' for x in SOURCE))
    mk = len(''.join(x + '\n' for x in MAKEFILE))
    t.expect(len(rows) == 4 and
             set(got) == {'hello', 'hello.o', 'hello.s', 'Makefile'} and
             got['hello'][0] == 'BIN' and got['hello'][1].isdigit() and
             got['hello.o'][0] == '$F8' and got['hello.o'][1].isdigit() and
             got['hello.s'] == ('TXT', str(src)) and
             got['Makefile'] == ('TXT', str(mk)),
             'ls -l: hello is BIN, hello.o is REL ($F8), and the two '
             'text files have exactly the bytes typed')
    ty, aux = disk_entry(t, '/TMP/hello', 'hello')
    t.expect(ty == BIN_TYPE and aux == LOAD_ADDR,
             'on the disk, hello is a BIN file whose aux_type is $%04X '
             '(type $%02X, aux $%04X)' % (LOAD_ADDR, ty, aux))
    t.hold(4.0)
