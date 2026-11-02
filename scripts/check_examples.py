#!/usr/bin/env python3
"""check_examples.py -- the lesson ladder, typed on the machine
(`make check-examples`, docs/EXAMPLES.md, docs/SITE.md sec 5).

Boots build/full.po (a copy-on-write mount: the file is never written) with
e2e_term.Term -- one key at a time, lowercase, as a person types -- once PER
LESSON, so a lesson starts from the same fresh machine its page assumes and a
red names its lesson. Every row types what its page tells the reader to type,
in that order, and asserts what the glass shows: the CONTENT and the ORDER of
every output (learning:01M317VKBTQPCDM2DNMD36N1QV -- a row that only asks
"is this line somewhere on the screen" passes a broken tool), after a prompt
that has SETTLED (learning:01M1AH9XWGC8ZS7HNBJVJ2JHXW; the prompt, never a
bare `$`, learning:01M3KY2AS0XJ22DY89S7R728GC).

The machine is the native 80 columns with the Timemaster clock pinned OFF
(reset clock:false), like the recorder's (site/demos/README): a dated
`ls -l` would be a different session on every run. Dates show as `-`.

A passing row writes the settled session to build/examples/<id>/session.txt.
site/build.py includes that file in the lesson page, so the page shows a
session that passed. Its format (docs/EXAMPLES.md):

    $ cmd                a line the reader types
    output               what the machine printed, one screen row per line
    [ ... ]              a note: keys typed inside vi, a screen ProDOS drew

The ids below are LESSON_IDS; site/build.py reads them (by ast, as it reads
the demos) and refuses a lesson page whose id is not here or that has no
session file. Lesson L6 (PLASMA) is row_l6: Dave Schmenk's hello.pla.

Run one lesson while developing:  check_examples.py build/full.po l3
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SCRIPTS)
sys.path.insert(0, SCRIPTS)
import e2e_term as T                                       # noqa: E402
import check_full as F                                     # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR     # noqa: E402

OUTDIR = os.path.join(ROOT, 'build', 'examples')
TMPDIR = os.path.join(ROOT, 'build', 'examples-tmp')   # scratch disks
EXAMPLES = os.path.join(ROOT, 'examples')
LESSON_IDS = ('l0', 'l1', 'l2', 'l3', 'l4', 'l5', 'l6', 'l7')
# the whole disk boot is ~60M cycles; poll it coarsely, it needs no count
BOOT_POLL = 1_000_000
REVISION = 'unknown'
DISK_SHA = ''


class Sess(F.Session):
    """check_full's Session with two honest changes. rows() keeps BLANK
    rows between the first and the last non-blank one (the parent drops
    them, so `[]` could not tell "no output" from "blank output"), and
    since() finds the echo of the command exactly: the row IS '$ ' + cmd
    unless that would pass the 80th column, when the echo wraps and only
    the first 78 characters can be compared. (The parent matched the first
    36 characters, so `make` could match the echo of `make -n`.)"""

    WIDTH = 80

    def rows(self):
        rows = [r.rstrip() for r in self.t.screen()]
        while rows and not rows[0]:
            rows.pop(0)
        while rows and not rows[-1]:
            rows.pop()
        return rows

    @classmethod
    def since(cls, rows, cmd):
        key = '$ ' + cmd
        exact = len(key) < cls.WIDTH
        if not exact:
            key = key[:cls.WIDTH - 2]
        for i in range(len(rows) - 1, -1, -1):
            if (rows[i] == key) if exact else rows[i].startswith(key):
                return rows[i + 1:]
        return rows


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def revision():
    """The git revision this run is of (and -dirty), or 'unknown'."""
    try:
        def git(*a):
            return subprocess.run(['git'] + list(a), cwd=ROOT, check=True,
                                  capture_output=True, text=True).stdout.strip()
        rev = git('rev-parse', '--short=12', 'HEAD')
        if git('status', '--porcelain', '--untracked-files=no'):
            rev += '-dirty'
        return rev
    except (OSError, subprocess.CalledProcessError):
        return 'unknown'


def example(directory, name):
    """The lines of examples/<directory>/<name>: the bytes the page
    includes and the gate types."""
    with open(os.path.join(EXAMPLES, directory, name), 'rb') as f:
        text = f.read().decode('ascii')
    lines = text.split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    return lines


class Lesson:
    """One lesson's machine and its transcript."""

    def __init__(self, c, lid, disk=None):
        self.disk = disk
        self.c = c
        self.id = lid
        self.s = Sess(c)
        self.t = self.s.t
        self.out = []

    # -- asserting ----------------------------------------------------
    @staticmethod
    def match(rows, want, what):
        """rows must equal want, item for item and in order. An item is
        a string (equality) or a compiled regex (fullmatch)."""
        ok = len(rows) == len(want)
        if ok:
            for r, w in zip(rows, want):
                if isinstance(w, str):
                    ok = ok and r == w
                else:
                    ok = ok and w.fullmatch(r) is not None
        if not ok:
            raise AssertionError(
                f'{what}: the screen shows\n  ' + '\n  '.join(rows) +
                '\nwhere the lesson says\n  ' +
                '\n  '.join(w if isinstance(w, str) else w.pattern
                            for w in want))

    def settled_rows(self):
        """The rows after the settled prompt, the prompt dropped."""
        return None

    # -- one typed command ---------------------------------------------
    def run(self, cmd, want=None, budget=400_000_000):
        rows = self.s.run(cmd, cmd, budget)
        if rows and F.PROMPT.fullmatch(rows[-1].strip()):
            rows = rows[:-1]
        self.out.append('$ ' + cmd)
        self.out += rows
        if want is not None:
            self.match(rows, want, f'`{cmd}`')
        return rows

    def note(self, text):
        self.out.append('[ ' + text + ' ]')

    # -- vi: type into it, leave it ------------------------------------
    def vi(self, name, keys, note):
        """`vi name`, wait until vi has drawn the file (its status line
        names it), type `keys` a key at a time, and wait for the prompt
        the :wq returns to."""
        self.t.wait_prompt(f'vi {name}: prompt before')
        self.t.type_human('vi ' + name)
        self.t.enter()
        self.t.wait('"%s"' % name, f'vi draws {name}', timeout_slices=400)
        for _ in range(8):
            self.t._slice()
        self.t.type_human(keys)
        self.t.wait_prompt(f'vi {name}: back at the prompt',
                           timeout_slices=400)
        self.out.append('$ vi ' + name)
        self.note(note)

    # -- cat > file: type a file, end with ^D ----------------------------
    def cat_to(self, name, lines):
        self.t.wait_prompt(f'cat > {name}: prompt before')
        self.t.type_human('cat > ' + name)
        self.t.enter()
        self.t._slice()
        for ln in lines:
            self.t.type_human(ln)
            self.t.enter()
        self.t.press(self.t.CTRL_D)
        self.t.wait_prompt(f'cat > {name}: back at the prompt')
        self.out.append('$ cat > ' + name)
        self.note('type the file shown above, a line at a time, then '
                  'press ^D')

    # -- bye: the window is the whole point ------------------------------
    def main_rows(self):
        r = self.c.call_tool('screen_text', {})
        return [x.rstrip() for x in (r.get('main') or []) if x.strip()]

    def run_bye(self, cmd, names, key=None, budget_steps=8000):
        """Type `cmd` (it ends in `bye ...`, directly or under make). The
        tenant's screen is polled for DURING the window, on the 40-column
        text page (check_tenant's method: after the restore repaints the
        console it is gone even on a correct build); `names` are the rows
        it must show. If `key`, press it once they are up. Returns
        (the rows after the command, the window rows)."""
        self.t.wait_prompt(f'{cmd}: prompt before')
        self.t.type_human(cmd)
        self.t.enter()
        window = None
        pressed = False
        back = False
        for _ in range(budget_steps):
            self.c.call_tool('step', {'cycles': 20_000})
            rows = self.s.rows()
            if window is None:
                main = self.main_rows()
                if all(n in main for n in names) and \
                        not any('Leaving maux' in r for r in main):
                    window = main
            if window is not None and key and not pressed:
                self.t.press(key)
                pressed = True
            if window is not None and any('Welcome back.' in r
                                          for r in rows):
                back = True
            if back and rows and F.PROMPT.fullmatch(rows[-1].strip()):
                # settled? two identical polls, as Session.run does
                last = rows[-1]
                self.c.call_tool('step', {'cycles': 500_000})
                rows2 = self.s.rows()
                if rows2 and rows2[-1] == last:
                    break
        else:
            raise T.Wedged(f'{cmd}: never came back; window {window!r}; '
                           f'screen:\n' + '\n'.join(self.s.rows()))
        rows = self.s.since(self.s.rows(), cmd)
        if rows and F.PROMPT.fullmatch(rows[-1].strip()):
            rows = rows[:-1]
        if window is None:
            raise AssertionError(f'{cmd}: the tenant never showed '
                                 f'{names!r} on the 40-column page')
        # splice the window into the transcript after the farewell
        shown = []
        for r in rows:
            shown.append(r)
            if 'Leaving maux for ProDOS' in r:
                shown.append('[ ProDOS is running the program. Its screen: ]')
                # the rows the lesson is about; a tenant that does not
                # clear the screen leaves maux's old text beside them
                shown += ['  ' + w for w in window if w.strip() in names]
                if key:
                    shown.append('[ a key is pressed ]')
        self.out.append('$ ' + cmd)
        self.out += shown
        return rows, window

    # -- the session file ------------------------------------------------
    def save(self, disk):
        """Write the session. The first lines, which start `#! `, record
        what it ran on (the git revision and the sha256 of the disk image);
        the page does not show them and check-site compares the hash with
        the current build/full.po (a session of another disk is stale)."""
        d = os.path.join(OUTDIR, self.id)
        os.makedirs(d, exist_ok=True)
        head = ['#! revision ' + REVISION, '#! full.po sha256 ' + DISK_SHA]
        text = '\n'.join(head + self.out) + '\n'
        text = ''.join(ch if ord(ch) < 128 else '?' for ch in text)
        with open(os.path.join(d, 'session.txt'), 'w') as f:
            f.write(text)


def rx(pattern, flags=0):
    return re.compile(pattern, flags)


NAS_OK = rx(r'nas: [1-9]\d* bytes -> \S+')


# ---------------------------------------------------------------------------
# the rows
# ---------------------------------------------------------------------------
def volume_root(disk):
    """The names in the volume's root directory, read from the image's
    raw bytes by a2til (read only), not typed here."""
    sys.path.insert(0, os.path.expanduser('~/src/a2til'))
    from a2til import prodos
    prodos.mount(disk, readonly=True, replace=True)
    try:
        return sorted(e.name for e in prodos.scandir('/MAUX'))
    finally:
        prodos.unmount('MAUX')


def row_l0(L):
    """L0. Find your way around: the virtual root, the volume under /mnt,
    /dev and /usr/man. No files."""
    L.run('pwd', ['/mnt/MAUX/'])
    rows = L.run('ls')
    shown = sorted(w for r in rows for w in r.split())
    want = volume_root(L.disk)
    if shown != want:
        raise AssertionError('`ls` of the volume shows\n  %r\nbut the image '
                             'holds\n  %r' % (shown, want))
    L.run('cd /', [])
    L.run('pwd', ['/'])
    L.run('ls', ['bin  dev  etc  mnt  tmp  usr'])
    L.run('ls /mnt', ['MAUX'])
    rows = L.run('ls /dev')
    if len(rows) != 1 or 'null' not in rows[0].split() or \
            'tty' not in rows[0].split():
        raise AssertionError(f'`ls /dev` is not the devices: {rows!r}')
    L.run('cd /usr/man', [])
    L.run('pwd', [rx('/usr/man/', re.I)])
    L.run('ls | head -3', ['ADMIN', 'AR', 'AS'])
    L.run('head -1 ECHO',
          [rx(r'ECHO\(1\) +General Commands Manual +ECHO\(1\)')])
    # /bin holds one file per roster name, derived as check_full derives it
    L.run('ls /bin | wc -l', [str(len(F.derive_roster()))])


def row_l1(L):
    """L1. hello, world in the shell: vi writes a TXT file, spawn reads
    the #! line. Settles: vi already types the file TXT ($04)."""
    L.run('echo hello, world', ['hello, world'])
    L.run('echo', [''])             # a blank line is output, and seen
    L.run('mkdir /tmp/l1', [])
    L.run('cd /tmp/l1', [])
    src = example('hellosh', 'hello')
    L.vi('hello', 'i' + '\r'.join(src) + '\x1b:wq\r',
         'in vi: press i, type the two lines shown above, press ESC, '
         'then type :wq and press RETURN')
    L.run('cat hello', src)
    L.run('ls -l', [rx(r'TXT +\d+ +- +hello')])
    L.run('./hello', ['hello, world'])
    L.run('cmp hello /usr/src/examples/HELLOSH/hello', [])
    # the spelling, for a file that is not TXT: harmless on this one
    L.run('chtyp -t TXT hello', [])


def row_l2(L):
    """L2. hello, world in assembly, and (W16) a typo caught."""
    L.run('mkdir /tmp/l2', [])
    L.run('cd /tmp/l2', [])
    L.run('cp /usr/src/examples/HELLO/hello.s hello.s', [])
    L.run('nas -o hello.o hello.s', [NAS_OK])
    L.run('ld -o hello hello.o -L /usr/lib -l a', [])
    rows = L.run('ls -l')
    want = [rx(r'BIN +\d+ +- +hello'), rx(r'TXT +\d+ +- +hello\.s'),
            rx(r'\$F8 +\d+ +- +hello\.o')]
    got = sorted(rows)
    if len(rows) != 3 or not all(
            any(w.fullmatch(r) for r in rows) for w in want):
        raise AssertionError(f'`ls -l` after ld: {got!r}')
    L.run('./hello', ['hello, world'])
    # -- W16: a typo, caught. An unknown label, as a reader sees it.
    L.vi('hello.s', ':%s/jsr   PUTS/jsr   PUTZ/\r:wq\r',
         'in vi: type :%s/jsr   PUTS/jsr   PUTZ/ and press RETURN, '
         'then :wq and RETURN')
    # nas writes its diagnostics on standard ERROR (NAS-STDERR): `2>`
    # catches them and leaves the screen silent (docs/EXAMPLES-NOTES.md,
    # finding 2, now closed)
    line = 1 + example('hello', 'hello.s').index(
        next(x for x in example('hello', 'hello.s') if 'jsr   PUTS' in x))
    unknown = ['nas: unknown label PUTZ (hello.s line %d)' % line,
               'nas: pass 2 failed']
    L.run('nas -o hello.o hello.s 2> ERRS', [])
    L.run('cat ERRS', unknown)
    L.run('nas -o hello.o hello.s 2> /dev/null; echo $?', ['1'])
    # -- ... and a syntax error. nas gives no line for this one.
    L.vi('hello.s', ':%s/jsr   PUTZ/jsr   PUTS/\r'
         ':%s/lda   #<MSG/ldq   #<MSG/\r:wq\r',
         'in vi: put PUTS back, then change the first lda to ldq: '
         ':%s/jsr   PUTZ/jsr   PUTS/ and :%s/lda   #<MSG/ldq   #<MSG/, '
         'RETURN after each, then :wq')
    L.run('nas -o hello.o hello.s 2> ERRS', [])
    L.run('cat ERRS', ['nas: pass 1 failed'])
    L.run('grep -n ldq hello.s', [rx(r'3[0-9]:.*ldq +#<MSG')])
    L.vi('hello.s', ':%s/ldq   #<MSG/lda   #<MSG/\r:wq\r',
         'in vi: change ldq back to lda, then :wq')
    L.run('nas -o hello.o hello.s', [NAS_OK])
    L.run('ld -o hello hello.o -L /usr/lib -l a', [])
    L.run('./hello', ['hello, world'])


def row_l3(L):
    """L3. Your own filter: upcase, composed with other programs."""
    L.run('mkdir /tmp/l3', [])
    L.run('cd /tmp/l3', [])
    L.run('cp /usr/src/examples/UPCASE/upcase.s upcase.s', [])
    L.run('nas -o upcase.o upcase.s', [NAS_OK])
    L.run('ld -o upcase upcase.o -L /usr/lib -l a', [])
    L.run('./upcase < /usr/src/examples/HELLOSH/hello',
          ['#!/BIN/SH', 'ECHO HELLO, WORLD'])
    L.run('echo mixed Case 123 | ./upcase', ['MIXED CASE 123'])
    rows = L.run('ls /bin | ./upcase | head -3')
    if len(rows) != 3 or any(not re.fullmatch(r'[A-Z0-9.]+', r)
                             for r in rows) or rows != sorted(rows):
        raise AssertionError(f'`ls /bin | ./upcase | head -3`: {rows!r}')
    # the program composes: upcase's output feeds tr, which undoes it
    L.run('echo Hello | ./upcase | tr A-Z a-z', ['hello'])


def row_l4(L):
    """L4. Shell scripting: count, each, mygrep."""
    L.run('mkdir /tmp/l4', [])
    L.run('cd /tmp/l4', [])
    for name in ('count', 'each', 'mygrep'):
        L.cat_to(name, example('scripts', name))
        L.run(f'cmp {name} /usr/src/examples/SCRIPTS/{name}', [])
    L.run('./count each', ['19 each'])
    L.run('./count', ['usage: count file'])
    L.run('echo $?', ['1'])
    L.run('./count nosuch', ['count: nosuch: no such file'])
    L.run('echo $?', ['1'])
    L.run('./each /usr/src/examples/HELLO',
          ['hello.s is source', 'Makefile is other',
           'listed: hello.s', 'listed: Makefile', '2 files'])
    rows = L.run('./mygrep regular /usr/man/GREP')
    if len(rows) < 2 or any('regular' not in r for r in rows):
        raise AssertionError(f'mygrep rows: {rows!r}')
    mine = rows
    rows = L.run('grep regular /usr/man/GREP')
    L.match(rows, mine, '`grep` prints the rows mygrep printed')
    L.run('ls /tmp | grep mygrep', [])     # the script cleaned up after itself


def row_l5(L):
    """L5. make, on L3's directory."""
    L.run('mkdir /tmp/l5', [])
    L.run('cd /tmp/l5', [])
    L.run('cp /usr/src/examples/UPCASE/* .', [])
    L.run('ls', ['Makefile  upcase.s'])
    L.run('make -n', ['nas -o upcase.o upcase.s',
                      'ld -o upcase upcase.o -L /usr/lib -l a'])
    L.run('make', ['nas -o upcase.o upcase.s', NAS_OK,
                   'ld -o upcase upcase.o -L /usr/lib -l a'])
    L.run('make', [])
    L.run('make -n', [])
    L.run('./upcase < /usr/src/examples/HELLOSH/hello',
          ['#!/BIN/SH', 'ECHO HELLO, WORLD'])
    L.run('make clean', ['rm -f upcase upcase.o'])
    L.run('ls', ['Makefile  upcase.s'])
    L.run('make -n', ['nas -o upcase.o upcase.s',
                      'ld -o upcase upcase.o -L /usr/lib -l a'])


def row_l6(L):
    """L6. hello, world in PLASMA: Dave Schmenk's own hello.pla typed in
    vi, a Makefile around plasm, plasma running the module, then the SAME
    program cooked by plascut on the host and staged on the disk."""
    src = example('hellopla', 'hello.pla')
    mk = example('hellopla', 'Makefile')
    L.run('mkdir /tmp/l6', [])
    L.run('cd /tmp/l6', [])
    L.vi('hello.pla', 'i' + '\r'.join(src) + '\x1b:wq\r',
         'in vi: press i, type the program shown above, press ESC, then '
         'type :wq and press RETURN')
    L.run('cat hello.pla', src)
    L.run('cmp hello.pla /usr/src/examples/HELLOPLA/hello.pla', [])
    L.vi('Makefile', 'i' + '\r'.join(mk) + '\x1b:wq\r',
         'in vi: press i, type the Makefile shown above (each indented '
         'line starts with a TAB), press ESC, then :wq and RETURN')
    L.run('cat Makefile', [x.expandtabs(8) for x in mk])
    # plasm exits 0 after a compile error (man plasm): the Makefile
    # removes the module first and lists it after, so a failure stops make
    L.run('make', ['rm -f hello.mod', 'plasm hello.pla hello.mod',
                   'PLASMA Compiler v2.21',
                   rx(r'Data\+Code buffer size = \$[0-9A-F]{4}'), '', '',
                   'DATA:....1 bytes', 'INIT:22 bytes', '',
                   'Total bytes compiled: 23', 'ls hello.mod',
                   'hello.mod'], 600_000_000)
    rows = L.run('ls -l')
    got = sorted(r.split()[0] + ' ' + r.split()[-1] for r in rows)
    if got != ['$FE hello.mod', 'TXT Makefile', 'TXT hello.pla']:
        raise AssertionError(f'`ls -l` after make: {rows!r}')
    L.run('plasma hello.mod', ['Hello, world.'])
    L.run('make', [])
    # the same program, cooked by plascut on the HOST (docs/PLASCUT.md)
    L.run('/usr/src/examples/HELLOPLA/HELLO', ['Hello, world.'])
    L.run('ls -l /usr/src/examples/HELLOPLA',
          [rx(r'BIN +\d+ +\S+ \S+ +HELLO'), rx(r'TXT +70 .*hello\.pla'),
           rx(r'TXT +%d .*Makefile' % sum(len(x) + 1 for x in mk))])


def row_l7(L):
    """L7. A ProDOS 8 SYSTEM program built on maux, tested with bye."""
    # -- step one: HELLO.SYSTEM
    L.run('mkdir /tmp/l7a', [])
    L.run('cd /tmp/l7a', [])
    L.run('cp /usr/src/examples/HELLOSYS/* .', [])
    L.run('make', ['nas -o hello.o hello.s', NAS_OK,
                   'ld -t FF -a 2000 -o HELLO.SYSTEM hello.o'])
    L.run('rm -f /mnt/MAUX/RESULT', [])
    rows, window = L.run_bye('bye HELLO.SYSTEM', ['HELLO FROM PRODOS'])
    L.match(rows, ['Leaving maux for ProDOS...', 'Welcome back.'],
            '`bye HELLO.SYSTEM`')
    L.run('cat /mnt/MAUX/RESULT', ['HELLO'])
    # -- step two: LS.SYSTEM, and the Makefile that is its test harness
    L.run('mkdir /tmp/l7', [])
    L.run('cd /tmp/l7', [])
    L.run('cp /usr/src/examples/LSSYS/* .', [])
    rows = L.run('ls')
    if sorted(' '.join(rows).split()) != ['Makefile', 'check', 'ls.s',
                                          'mkwant']:
        raise AssertionError(f'`ls` in the LSSYS copy: {rows!r}')
    L.run('make', ['nas -o ls.o ls.s', NAS_OK,
                   'ld -t FF -a 2000 -o LS.SYSTEM ls.o'])
    L.run('ls -l LS.SYSTEM', [rx(r'SYS +\d+b +- +LS\.SYSTEM')])
    # the ProDOS names the program will list, in ls's order, upper case
    expect = ['CHECK', 'LS.O', 'LS.S', 'LS.SYSTEM', 'MAKEFILE', 'MKWANT',
              'WANT']
    rows, window = L.run_bye('make test', expect, key='x')
    L.match(rows, ['rm -f GOT', 'sh mkwant', 'bye LS.SYSTEM',
                   'Leaving maux for ProDOS...', 'Welcome back.',
                   'sh check'], '`make test`')
    L.run('echo $?', ['0'])
    # GOT is what ProDOS wrote; it agrees with what ls says
    got = L.run('cat GOT')
    if sorted(got) != expect or sorted(window) != expect:
        raise AssertionError(f'GOT {got!r} / window {window!r} are not '
                             f'the names {expect!r}')
    L.run('cat WANT', expect)
    # -- the harness must FAIL when the two programs disagree: make the
    # script that writes WANT add a name ProDOS never listed
    L.run("echo 'echo ZZZ >> WANT' >> mkwant", [])
    rows, _ = L.run_bye('make test', expect, key='x')
    L.match(rows, ['rm -f GOT', 'sh mkwant', 'bye LS.SYSTEM',
                   'Leaving maux for ProDOS...', 'Welcome back.',
                   'sh check', rx(r'cmp: EOF on GOT\.S|GOT\.S WANT\.S differ.*'),
                   'make: command failed'], '`make test` on a differing WANT')
    L.run('echo $?', ['1'])
    # -- the same file, on a stock ProDOS 2.4 disk with no maux at all
    stock_row(L, 'LS.SYSTEM')


STOCK_NAMES = (('ALPHA', b'A\r'), ('DELME', b'D\r'), ('BETA', b'B\r'))


def stock_row(L, program):
    """Run `program` as built on maux on a stock ProDOS 2.4 disk. The
    program is read out of the machine's own disk (image_export, then
    a2til), written onto a copy of the vendored ProDOS 2.4 boot disk (no
    BASIC.SYSTEM, so the first .SYSTEM it finds is ours, as on any disk
    with a selector-less startup), and that disk is booted on the same
    emulator: ProDOS 2.4 and nothing of maux. The listing it shows and
    the GOT it writes are checked against the directory the image
    actually holds, and the program must QUIT when a key is pressed."""
    sys.path.insert(0, os.path.expanduser('~/src/a2til'))
    from a2til import prodos
    os.makedirs(TMPDIR, exist_ok=True)
    exported = os.path.join(TMPDIR, 'l7-after.po')
    stock = os.path.join(TMPDIR, 'stock.po')
    after = os.path.join(TMPDIR, 'stock-after.po')
    r = L.c.call_tool('image_export', {'unit': 1, 'path': exported})
    if r.get('ok') is False:
        raise RuntimeError(f'image_export failed: {r}')
    prodos.mount(exported, readonly=True, replace=True)
    try:
        binary = prodos.read('/MAUX/TMP/L7/' + program)
    finally:
        prodos.unmount('MAUX')
    carrier = os.path.join(ROOT, 'vendor', 'prodos-basic.po')
    if not os.path.exists(carrier):
        raise RuntimeError('vendor/prodos-basic.po is missing: make '
                           'vendor-prodos')
    shutil.copyfile(carrier, stock)
    prodos.mount(stock, replace=True)
    try:
        prodos.remove('/MAUX/BASIC.SYSTEM')
        prodos.write('/MAUX/' + program, binary, file_type=0xFF,
                     aux_type=0x2000)
        for n, data in STOCK_NAMES:
            prodos.write('/MAUX/' + n, data, file_type=4, aux_type=0)
        prodos.mkdir('/MAUX/SUB')
        prodos.remove('/MAUX/DELME')           # a deleted entry in the block
        names = sorted(e.name for e in prodos.scandir('/MAUX'))
    finally:
        prodos.unmount('MAUX')
    c = L.c
    r = c.call_tool('reset', {'backend': 'fast', 'aux': 'ramworks',
                              'clock': False})
    r = c.call_tool('mount_disk', {'path': stock, 'unit': 1, 'copy': True})
    if not r.get('ok'):
        raise RuntimeError(f'mount_disk {stock}: {r}')
    window = None
    for _ in range(400):
        c.call_tool('step', {'cycles': 500_000})
        main = L.main_rows()
        if all(n in main for n in names):
            window = main
            break
    if window is None:
        raise AssertionError(f'stock ProDOS never listed {names!r}; '
                             f'screen {L.main_rows()!r}')
    if any('ERROR' in w for w in window):
        raise AssertionError(f'stock ProDOS: {window!r}')
    shown = sorted(w for w in window if w in names)
    if shown != names:
        raise AssertionError(f'stock listing {shown!r} != {names!r}')
    c.call_tool('type', {'text': 'x'})
    gone = False
    for _ in range(200):
        c.call_tool('step', {'cycles': 500_000})
        if not all(n in L.main_rows() for n in names):
            gone = True
            break
    if not gone:
        raise AssertionError('stock ProDOS: the program did not QUIT '
                             'when a key was pressed')
    r = c.call_tool('image_export', {'unit': 1, 'path': after})
    if r.get('ok') is False:
        raise RuntimeError(f'image_export failed: {r}')
    prodos.mount(after, readonly=True, replace=True)
    try:
        got = prodos.read('/MAUX/GOT')
    finally:
        prodos.unmount('MAUX')
    lines = sorted(x for x in got.split(b'\x8d') if x)
    from a2til import convert
    want = sorted(convert.text_from_host(n.encode(), high_bit=True)
                  for n in names)
    if lines != want:
        raise AssertionError(f'stock GOT {lines!r} != {want!r}')
    L.note('the same LS.SYSTEM, copied onto a stock ProDOS 2.4 disk with '
           'no maux, boots and shows:')
    L.out += ['  ' + w for w in names]
    L.note('a key is pressed, it QUITs, and the GOT it wrote holds the '
           'same names')


ROWS = {'l0': row_l0, 'l1': row_l1, 'l2': row_l2, 'l3': row_l3,
        'l4': row_l4, 'l5': row_l5, 'l6': row_l6, 'l7': row_l7}


# ---------------------------------------------------------------------------
def main():
    args = sys.argv[1:]
    if not args or args[0] in ('-h', '--help'):
        print(__doc__, file=sys.stderr)
        return 2
    disk = os.path.abspath(args[0])
    want = args[1:] or list(LESSON_IDS)
    for w in want:
        if w not in ROWS:
            print(f'check_examples: no such lesson {w}', file=sys.stderr)
            return 2
    assert set(ROWS) == set(LESSON_IDS), 'LESSON_IDS and ROWS disagree'
    global REVISION, DISK_SHA
    REVISION = revision()
    DISK_SHA = sha256_of(disk)
    failures = []
    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
    c = MCPClient([SUPERVISOR], env)
    try:
        c.initialize()
        for lid in want:
            stale = os.path.join(OUTDIR, lid, 'session.txt')
            if os.path.exists(stale):
                os.unlink(stale)         # a red row leaves no session
            try:
                F.boot_to_prompt(c, disk, f40=False,
                                 reset_extra={'clock': False},
                                 step=BOOT_POLL)
                L = Lesson(c, lid, disk)
                ROWS[lid](L)
                L.save(disk)
                print(f'[check-examples] {lid}: PASS ({len(L.out)} session '
                      f'lines -> build/examples/{lid}/session.txt)')
            except (T.Wedged, AssertionError, RuntimeError) as e:
                failures.append(lid)
                print(f'[check-examples] {lid}: FAIL: {e}')
    finally:
        c.close()
    if failures:
        print(f'[check-examples] FAIL ({len(failures)}): '
              + ' '.join(failures))
        return 1
    print('[check-examples] PASS: %d lesson(s) typed on the machine, a key '
          'at a time, and read back' % len(want))
    return 0


if __name__ == '__main__':
    sys.exit(main())
