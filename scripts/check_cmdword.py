#!/usr/bin/env python3
"""check_cmdword.py -- a command word that contains a slash is a path
(KFIX10 item 3, sh), make finds its commands the way sh -c would
(item 4), and make reads either text convention (item 5).
`make check-cmdword`; the image is a private copy of build/play.po.

sh (item 3).  POSIX: a command word containing a slash is NEVER
searched on PATH, and resolves against the current directory.  maux
looked every such word up as /bin/./hello and said "command not found"
to the first thing the first lesson types
(learning:01M59SNKKXY1C1006WK9CW33F7).  Rows: `./hello`, `dir/hello`,
`../hello`-shaped (the dots resolved by MKPATH, as `cat ./x` does), a
missing `./nope` (rc 127), and a bare word that is NOT on PATH still is
not found even though the file sits in the current directory.  Every
row pins the EXACT rows below its own command echo, so a tool that
never ran cannot pass (learning:01M317VKBTQPCDM2DNMD36N1QV).

make (items 4, 5).  A Makefile naming bare `echo`/`cp`/`rm` (PATH
search) and `./tool` / `sub/tool` (a path); a missing command gives
`make: NAME: not found` and a non-zero exit; `-NAME` goes on.  The same
Makefile in BOTH text conventions (maux text, tab $89 / $8D; ProDOS
standard text, tab $09 / $0D) builds the same BYTES.
"""
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_nas_boundary import boot  # noqa: E402
from check_plascut import blob, run_cmd  # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos, convert  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md)

ROOT = Path(__file__).resolve().parents[1]
DIR = '/mnt/MAUX/K10'


# The Makefile both conventions build from.  Bare `cp` and `rm` are the
# PATH rows; `./tool` and `sub/tool` are the path rows.
#
# The rules start past the first 256-byte page and the second: the
# conversion loops over whole pages and then a tail, and a Makefile
# shorter than a page only ever exercises the tail.
PAD = b''.join(b'# padding line %02d to move the rules past a page\n' % i
               for i in range(14))
MAKEFILE = (PAD +
            b'# a comment\n'
            b'A = cp\n'
            b'all: out1 out2 out3\n'
            b'out1: in1\n'
            b'\t$(A) in1 out1\n'
            b'out2: in1\n'
            b'\t./tool in1 out2\n'
            b'out3: in1\n'
            b'\tsub/tool in1 out3\n'
            b'clean:\n'
            b'\trm -f out1 out2 out3\n')
IN1 = b'PAYLOAD-' + bytes(range(65, 91)) + b'\n'


def standard(text):
    return text.replace(b'\n', b'\r')


def maux(text):
    """maux text: high bit set, a line end is $8D, a tab $89 -- a2til's
    own high_bit form, so no byte is encoded by hand here."""
    return convert.text_from_host(text, high_bit=True)


def mixed(text):
    """One Makefile that changes convention every line: odd lines
    maux text (tab $89, end $8D), even lines ProDOS standard (tab $09,
    end $0D)."""
    out = bytearray()
    for i, line in enumerate(text.splitlines(keepends=True)):
        out += maux(line) if i % 2 else standard(line)
    return bytes(out)


# K5: a resolved path of EXACTLY 64 characters (ProDOS's longest) and
# 65.  The guest's cwd prefix is '/mnt/MAUX/K10/' (14), three 15-char
# directories add 3 x 16 = 48, so a 2-letter file makes 64 and a
# 3-letter one 65.
DEEP = ['D' + c * 13 + '1' for c in 'ABC']
DEEPDIR = '/'.join(DEEP)
CWD_PREFIX = '/mnt/MAUX/K10/'
assert len(CWD_PREFIX) + 16 * 3 + 2 == 64


def stage(image, files):
    vol = prodos.mount(image, replace=True)
    try:
        try:
            prodos.mkdir(f'/mnt/{vol}/K10')
        except FileExistsError:
            pass
        for name, data in files.items():
            parent = name.rsplit('/', 1)[0] if '/' in name else ''
            if parent:
                try:
                    prodos.mkdir(f'/mnt/{vol}/K10/{parent}')
                except FileExistsError:
                    pass
            prodos.write(f'/mnt/{vol}/K10/{name}', data, file_type=4,
                         aux_type=0, overwrite=True)
    finally:
        prodos.unmount(vol)


def after(rows, cmd):
    """The rows below THIS command's own echo, up to the next prompt,
    blanks dropped.  The screen is the glass; the caller pins the
    whole list, not a substring."""
    # a long command wraps at the console's 40 columns: find its first
    # row by prefix, then skip the continuation rows
    head = '$ ' + cmd[:36]
    at = max(i for i, r in enumerate(rows) if r.strip().startswith(head))
    at += (len(cmd) + 2 - 1) // 40
    out = []
    for r in rows[at + 1:]:
        if r.strip() == '$':
            break
        if r.strip():
            out.append(r.rstrip())
    return out


def run(client, cmd, label, max_steps=8000):
    rows, _ = run_cmd(client, cmd, label, max_steps=max_steps)
    return after(rows, cmd)


def status(client, label):
    rows = run(client, 'echo rc=$?', label, max_steps=2500)
    return rows


def main():
    if len(sys.argv) != 2:
        print(f'usage: {sys.argv[0]} build/play.po', file=sys.stderr)
        return 2
    disk = os.path.abspath(sys.argv[1])
    failures = []

    def expect(label, got, want):
        if got != want:
            failures.append(f'{label}: got {got!r}, want {want!r}')
        else:
            print(f'[check-cmdword] {label}: {want!r}')

    with tempfile.TemporaryDirectory(prefix='cmdword-') as tmp:
        image = str(Path(tmp) / 'cmdword.po')
        shutil.copyfile(disk, image)
        # make rows' inputs: two directories, one Makefile per convention
        stage(image, {
            'IN1': IN1,
            'LOW/Makefile': standard(MAKEFILE),
            'LOW/in1': IN1,
            'HIGH/Makefile': maux(MAKEFILE),
            'HIGH/in1': IN1,
            'MIX/Makefile': mixed(MAKEFILE),
            'MIX/in1': IN1,
            # K9: a leading @ suppresses the echo, and the file is built
            'ATSIGN/Makefile': maux(b'out1: in1\n\t@cp in1 out1\n'),
            'ATSIGN/in1': IN1,
            # K5: make with a 64- and a 65-character path
            'LONG64': maux(b'all:\n\t./' + DEEPDIR.encode() +
                           b'/tt R10\n'),
            'LONG65': maux(b'all:\n\t./' + DEEPDIR.encode() +
                           b'/ttt R11\n'),
            # K1: a path that is not there, and one that is a text file
            'BADPATH/Makefile': maux(
                b'all:\n\t./nope\n\techo SECOND\n'),
            'NOEXEC/Makefile': maux(b'all:\n\t./plain\n'),
            'NOEXEC/plain': b'just text, no #! line\r',
            'BADCMD/Makefile': maux(
                b'all:\n\tnosuchcmd x\n\techo SECOND\n'),
            'DASH/Makefile': maux(
                b'all:\n\t-nosuchcmd x\n\techo SECOND\n'),
        })
        client = boot(image)
        try:
            run(client, f'cd {DIR}', 'cd')
            # ---- sh, item 3 ------------------------------------------
            run(client, 'cp /bin/echo hello', 'cp hello')
            expect('./hello', run(client, './hello R1', 'dot'), ['R1'])
            run(client, 'mkdir sub', 'mkdir sub')
            run(client, 'cp /bin/echo sub/hello', 'cp sub/hello')
            expect('sub/hello', run(client, 'sub/hello R2', 'dir'), ['R2'])
            run(client, 'cd sub', 'cd sub')
            expect('../hello', run(client, '../hello R3', 'dotdot'),
                   ['R3'])
            expect('./hello (in sub)', run(client, './hello R4', 'dot2'),
                   ['R4'])
            expect('rc', status(client, 'rc ok'), ['rc=0'])
            missing = run(client, './nope', 'missing')
            if not any('not found' in r for r in missing):
                failures.append(f'./nope: no "not found" row: {missing!r}')
            expect('./nope rc', status(client, 'rc nope'), ['rc=127'])
            run(client, 'cd ..', 'cd up')
            # the current directory is NOT on the search path: a bare
            # `hello` sits right here and must still not be found
            bare = run(client, 'hello R5', 'bare')
            if not any('not found' in r for r in bare):
                failures.append(f'bare hello was found or ran: {bare!r}')
            expect('bare rc', status(client, 'rc bare'), ['rc=127'])
            # a bare word is still searched: echo lives in /bin
            expect('echo (PATH)', run(client, 'echo R6', 'path'), ['R6'])
            # K4: command -v / type / hash treat a slash word as a path
            expect('command -v ./hello',
                   run(client, 'command -v ./hello', 'cv1'), ['./hello'])
            expect('command -v sub/hello',
                   run(client, 'command -v sub/hello', 'cv2'),
                   ['sub/hello'])
            expect('command -v ./nope',
                   run(client, 'command -v ./nope', 'cv3'), [])
            expect('command -v ./nope rc', status(client, 'cv3rc'),
                   ['rc=1'])
            expect('type ./hello', run(client, 'type ./hello', 'ty1'),
                   ['./hello is ./hello'])
            expect('hash ./hello', run(client, 'hash ./hello', 'h1'), [])
            expect('hash ./hello rc', status(client, 'h1rc'), ['rc=0'])
            expect('hash ./nope', run(client, 'hash ./nope', 'h2'),
                   ['hash: ./nope: not found'])
            expect('hash ./nope rc', status(client, 'h2rc'), ['rc=1'])
            # K6: a `.` or `..` INSIDE the word is not resolved (MKPATH
            # handles a leading run only); the kernel refuses it, and sh
            # says "not found", 127 -- a named limit, pinned here
            bad = run(client, 'sub/../hello R', 'inner')
            if not any('not found' in r for r in bad):
                failures.append(f'sub/../hello: {bad!r}')
            expect('sub/../hello rc', status(client, 'innerrc'),
                   ['rc=127'])
            # K5: exactly 64 resolved characters runs (both branches),
            # 65 is refused cleanly and the shell stays up
            run(client, 'mkdir ' + DEEP[0], 'd1')
            run(client, 'mkdir ' + '/'.join(DEEP[:2]), 'd2')
            run(client, 'mkdir ' + DEEPDIR, 'd3')
            run(client, f'cp /bin/echo {DEEPDIR}/tt', 'cp tt')
            expect('./deep/tt (64)',
                   run(client, f'./{DEEPDIR}/tt R7', 'deep1'), ['R7'])
            expect('deep/tt (64)',
                   run(client, f'{DEEPDIR}/tt R8', 'deep2'), ['R8'])
            for form in (f'./{DEEPDIR}/ttt R9', f'{DEEPDIR}/ttt R9'):
                refused = run(client, form, 'deep65')
                if not any('not found' in r for r in refused):
                    failures.append(f'65 chars, {form}: {refused!r}')
                expect('65 rc', status(client, 'deep65rc'), ['rc=127'])
            expect('alive after 65', run(client, 'echo ALIVE', 'alive'),
                   ['ALIVE'])
            lm = run(client, 'make -f LONG64', 'long64')
            if lm[-1:] != ['R10']:
                failures.append(f'make at 64 characters: {lm!r}')
            lm = run(client, 'make -f LONG65', 'long65')
            # (the console wraps at 40 columns: rejoin the rows)
            if not ''.join(lm).endswith(
                    f'make: ./{DEEPDIR}/ttt: not found'):
                failures.append(f'make at 65 characters: {lm!r}')
            # ---- make, items 4 and 5 ---------------------------------
            # ./tool and sub/tool are copies of cp
            run(client, 'cp /bin/cp tool', 'cp tool')
            run(client, 'cp /bin/cp sub/tool', 'cp sub/tool')
            for conv in ('LOW', 'HIGH', 'MIX'):
                run(client, f'cp tool {conv}/tool', f'{conv} tool')
                run(client, f'mkdir {conv}/sub', f'{conv} mkdir')
                run(client, f'cp tool {conv}/sub/tool', f'{conv} sub tool')
                run(client, f'cd {conv}', f'{conv} cd')
                rows = run(client, 'make', f'{conv} make',
                           max_steps=20000)
                text = '\n'.join(rows)
                if 'make:' in text:
                    failures.append(f'{conv}: make reported: {rows!r}')
                for want in ('cp in1 out1', './tool in1 out2',
                             'sub/tool in1 out3'):
                    if want not in text:
                        failures.append(f'{conv}: missing echo {want!r}: '
                                        f'{rows!r}')
                expect(f'{conv} rc', status(client, f'{conv} rc'),
                       ['rc=0'])
                # a second make has nothing to do
                again = run(client, 'make', f'{conv} make2',
                            max_steps=20000)
                if any('cp ' in r or 'tool' in r for r in again):
                    failures.append(f'{conv}: 2nd make still ran: '
                                    f'{again!r}')
                run(client, 'cd ..', f'{conv} cd up')
            # K9: a leading @ suppresses the echo of the command
            run(client, 'cd ATSIGN', 'at cd')
            expect('@ recipe', run(client, 'make', 'at make'), [])
            run(client, 'cd ..', 'at up')
            # K1: a PATH that is not there: make's not-found, a non-zero
            # exit, and the next line NOT run
            run(client, 'cd BADPATH', 'bp cd')
            bp = run(client, 'make', 'bp make')
            expect('missing ./nope', bp[-1:],
                   ['make: ./nope: not found'])
            if any('SECOND' in r for r in bp):
                failures.append(f'./nope did not stop make: {bp!r}')
            if status(client, 'bp rc') == ['rc=0']:
                failures.append('./nope: make exited 0')
            run(client, 'cd ..', 'bp up')
            # K1: a text file with no #! exists and cannot run: "cannot
            # spawn command", NOT "not found"
            run(client, 'cd NOEXEC', 'ne cd')
            ne = run(client, 'make', 'ne make')
            expect('text file', ne[-1:], ['make: cannot spawn command'])
            if any('not found' in r for r in ne):
                failures.append(f'a text file was called not found: {ne!r}')
            run(client, 'cd ..', 'ne up')
            # a missing command: make's "not found", non-zero exit,
            # and the line after it NOT run
            run(client, 'cd BADCMD', 'bad cd')
            bad = run(client, 'make', 'bad make')
            expect('missing cmd', bad[-1:], ['make: nosuchcmd: not found'])
            if any('SECOND' in r for r in bad):
                failures.append(f'missing command did not stop make: '
                                f'{bad!r}')
            if status(client, 'bad rc') == ['rc=0']:
                failures.append('missing command: make exited 0')
            # K8: the whole not-found line is ONE polarity (low, the
            # house rule for new messages): its bytes are read back
            # from the host below, the glass cannot tell
            run(client, 'make 2> ERRS', 'bad errs')
            run(client, 'cd ..', 'bad up')
            # `-` ignores a failed command, "not found" included
            run(client, 'cd DASH', 'dash cd')
            dash = run(client, 'make', 'dash make')
            if not any(r == 'SECOND' for r in dash):
                failures.append(f'-nosuchcmd stopped make: {dash!r}')
            expect('dash rc', status(client, 'dash rc'), ['rc=0'])
            run(client, 'ls', 'flush', max_steps=2000)
        finally:
            client.close()
        vol = prodos.mount(image, replace=True, readonly=True)
        try:
            outs = {}
            for conv in ('LOW', 'HIGH', 'MIX', 'ATSIGN'):
                for n in (('out1',) if conv == 'ATSIGN' else
                          ('out1', 'out2', 'out3')):
                    try:
                        outs[(conv, n)] = prodos.read(
                            f'/mnt/{vol}/K10/{conv}/{n}')
                    except FileNotFoundError:
                        failures.append(f'{conv}/{n}: was not built')
            try:
                errs = prodos.read(f'/mnt/{vol}/K10/BADCMD/ERRS')
            except FileNotFoundError:
                errs = b''
                failures.append('BADCMD/ERRS: was not written')
            if errs != b'make: nosuchcmd: not found\r':
                failures.append(f'the not-found line is not all low '
                                f'ASCII, one line: {errs!r}')
            for (conv, n), data in outs.items():
                if data != IN1:
                    failures.append(f'{conv}/{n}: {data!r} != input')
            if outs and len({bytes(v) for v in outs.values()}) != 1:
                failures.append('the two conventions built different '
                                'bytes')
        finally:
            prodos.unmount(vol)
    if failures:
        print('[check-cmdword] FAIL:', file=sys.stderr)
        for f in failures:
            print('  - ' + f, file=sys.stderr)
        return 1
    print('[check-cmdword] PASS: ./cmd, dir/cmd, ../cmd, missing ./nope '
          '(127), bare word still PATH-searched; make: bare PATH words, '
          'paths, not-found, `-`, and both text conventions build the '
          'same bytes')
    return 0


if __name__ == '__main__':
    sys.exit(main())
