#!/usr/bin/env python3
"""check_plasm_full.py -- the native PLASMA compiler on the release disk
compiles a program written on maux (`make check-plasm-full`,
docs/PLASM-FIX-NOTES.md).

Boots build/full.po (copy-on-write, never written) and uses it the way
the hello-world lesson does: Dave Schmenk's OWN samplesrc/hello.pla,
byte for byte, read from the pinned PLASMA checkout (the one the lock
names), typed on the machine with `cat >` one key at a time, so it lands
as `vi` would write it -- high-bit ASCII, $8D line ends. Rows:

  PF1 the file on the glass is Dave's: its byte count equals his
      (an $8D for his $0A is the same length).
  PF2 `plasm hello.pla hello.mod` -- NO throwaway first argument, NO
      inc/ directory (fileio falls back to /usr/inc) -- compiles it
      (`Total bytes compiled`), no `Error`.            [defects 1, 3, 5]
  PF3 `plasma hello.mod` prints `Hello, world.` and exits 0.
  PF4 the same compile with a local inc/ (`mkdir inc; cp
      /usr/inc/cmdsys.plh inc`, the lesson's other form) writes a
      BYTE-IDENTICAL module -- cmp; and /usr/inc/cmdsys.plh is Dave's
      cmdsys.plh with only the text convention changed (cmp against a
      masked copy planted on a derived image).          [defect 5]
  PF5 the LOW-ASCII form -- a ProDOS-standard source and header
      (bare $0D, bit 7 clear; what a modern tool's TXT mode writes),
      which `cat >` cannot produce on this machine, so a derived COPY
      of the image is given them from the host (a2til) -- compiles to a
      module cmp-identical to PF2's and runs.  [defect 2: the cooked
      plasm ran out of heap on exactly this input]
  PF6 an argument of 100 bytes reaches a COOKED tool without wrecking
      rt's data: `plasm` on a 100-byte name prints its banner and an
      error and the prompt returns, and the very next compile still
      works.                                             [defect 4]

  PF7 NEWLINE mode dies with the file: a text read, CLOSE, then a BINARY
      read on the very same refnum returns all 16 bytes, bit 7 intact.
                                                         [round 1, S1]
  PF8 the command line: exactly 127 characters arrives whole (the NUL
      argFirst writes after it is inside the buffer); one more is
      refused with `rt: command line too long`, exit 2.   [round 1, S5]
  PF9 a module with more exports than the symbol table holds is refused
      with `rt: symbol table full`, exit 2, not run on into rt's data.
  PF10 a 100-byte argument to a cooked NAS (defect 4 was first measured
      on nas) neither wedges nor corrupts: the next assembly is right.
  PF11 /usr/inc is not writable through plasm's include fallback, and
      nas keeps the base behaviour: `plasm src inc/cmdsys.plh` and
      `nas -o inc/stdio.equ` leave the system headers unchanged, and a
      nas `put inc/zp.equ` with no local inc/ still fails.   [B2]
  PF12 the code buffer plasm prints is POSITIVE (a $FFxx/$FExx size is
      the overflow check disabled by a shortage).        [round 1, S2]
  The header on /usr/inc is Dave's cmdsys.plh to the byte once the text
  convention is undone (checked from the image, unmasked).  [round 1, S4]

  PF13 a lesson Makefile on the machine: `rm -f X.mod`, `plasm X.pla
      X.mod`, `ls X.mod` (maux's make spawns recipe lines with no shell
      and full.po has no /bin/test; plasm exits 0 after a compile error,
      so `ls` after is the check): a good program makes, rc 0; an
      overflowing one stops make with a nonzero status.
  PF11b a write through the inc/ fallback fails LOUDLY: `plasm src
      inc/cmdsys.plh` from a directory with no inc/ reports the open of
      its output failing (it used to print `Total bytes compiled`, rc 0,
      and write nothing).
  HV2 (host) the FILEIO splice refuses a marker count other than the one
      fileio.frag.pla declares (one STOP hook of two removed).
  HV1 (host) the build refuses a cooked nas whose heap is below
      VALIDATED_HEAP: with it raised one byte above the real heap,
      build_nas_librel_image.main() returns 2 with the refusal.

Rows are independent: a failure is recorded and the rest still run, so
the base (before PLASM-FIX) shows every defect at once.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SCRIPTS)
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import check_full as CF                                    # noqa: E402
import e2e_term as T                                       # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR      # noqa: E402

PLASMA = os.path.expanduser(os.environ.get('PLASMA', '~/src/PLASMA'))
HELLO_PLA = os.path.join(PLASMA, 'src', 'samplesrc', 'hello.pla')
CMDSYS_PLH = os.path.join(PLASMA, 'src', 'inc', 'cmdsys.plh')
LONG_NAME = 'a' * 100
XPLASM = os.path.join(PLASMA, 'src', 'xplasm')
BUILD = os.path.join(ROOT, 'build')
CMDLN_MAX = 127          # rt.pla CMDLN_MAX
BIN16 = bytes([0xC1, 0x0D, 0xFF, 0x8D, 0x41, 0x00, 0x8D, 0x0D,
               0xC2, 0xC3, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06])

ARGECHO_PLA = '''include "inc/cmdsys.plh"
include "inc/args.plh"
puts("LEN="); puti(^cmdsys:cmdline); putln
puts("["); puts(cmdsys:cmdline); puts("]"); putln
return 0
done
'''
NLTEST_PLA = '''include "inc/cmdsys.plh"
include "inc/fileio.plh"
byte buf[16]
word ref, n, i
ref = fileio:open("T.TXT")
fileio:newline(ref, $7F, $0D)
n = fileio:read(ref, @buf, 16)
puts("TXT ref="); puti(ref); puts(" n="); puti(n); putln
fileio:close(ref)
ref = fileio:open("B.BIN")
n = fileio:read(ref, @buf, 16)
puts("BIN ref="); puti(ref); puts(" n="); puti(n); putln
for i = 0 to n - 1
    putb(buf[i]); putc(' ')
next
putln
fileio:close(ref)
return 0
done
'''


def bigexp_pla(n=150):
    lines = ['include "inc/cmdsys.plh"']
    for i in range(n):
        lines.append(f'export word exportedsym{i:04d} = {i}')
    lines += ['puts("BIGEXP RAN\\n")', 'done']
    return '\n'.join(lines) + '\n'
COMPILED = re.compile(r'Total bytes compiled: (\d+)')


def fail(failures, msg):
    failures.append(msg)
    print(f'[check-plasm-full] FAIL: {msg}')


def host_compile(tmp, name, text):
    """Compile `text` as tmp/name.pla with the host xplasm + acme, the way
    the Makefile builds a module (-AMOW, --setpc 8190)."""
    os.makedirs(os.path.join(tmp, 'inc'), exist_ok=True)
    for h in ('cmdsys.plh', 'args.plh', 'fileio.plh'):
        shutil.copy(os.path.join(ROOT, 'src', 'plasma', 'inc', h),
                    os.path.join(tmp, 'inc', h))
    with open(os.path.join(tmp, name + '.pla'), 'w') as f:
        f.write(text)
    for cmd in ([XPLASM, '-AMOW', name + '.pla'],
                ['acme', '--setpc', '8190', '-o', name + '.mod',
                 name + '.a']):
        r = subprocess.run(cmd, cwd=tmp, capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError(f'{cmd}: {r.stdout}{r.stderr}')
    with open(os.path.join(tmp, name + '.mod'), 'rb') as f:
        return f.read()


def maux_text(data):
    """maux text (bit 7 set, $8D line ends) via a2til's converter: this
    is what maux's own make/sh/vi write and what the read layer under
    test must cope with. high_bit=True is NOT DOS-3.3-only; its bytes
    are exactly maux's convention."""
    import vpath                                           # noqa: F401
    from a2til import convert
    return convert.text_from_host(data, high_bit=True)


def derive(full, out, tmp):
    """A copy of `full` plus what the machine itself cannot make:
    /MAUX/LO (Dave's hello.pla and cmdsys.plh as ProDOS-standard text,
    bare $0D, bit 7 clear), and /MAUX/X: host-compiled fixtures
    (argecho, nltest, bigexp as modules; ae as a COOKED tool made by
    plascut from the same module), a text and a binary data file.
    Also the one check that needs the image's own bytes: /usr/inc/
    cmdsys.plh is Dave's cmdsys.plh to the byte once the text convention
    is undone, UNMASKED (bit 7 on, $8D line ends, nothing else).
    Returns a list of problems."""
    import vpath                                           # noqa: F401
    from a2til import prodos, convert
    import plascut
    mods = {n: host_compile(tmp, n, t) for n, t in
            (('argecho', ARGECHO_PLA), ('nltest', NLTEST_PLA),
             ('bigexp', bigexp_pla()))}
    for m in ('args', 'fileio'):
        shutil.copy(os.path.join(BUILD, m + '.mod'),
                    os.path.join(tmp, m + '.mod'))
    ae = os.path.join(tmp, 'ae.cut')
    rc = plascut.cook('ARGECHO', [tmp], os.path.join(BUILD, 'plasma.bin'),
                      os.path.join(BUILD, 'rt.mod'), ae, verbose=False)
    if rc:
        raise RuntimeError('plascut failed on argecho')
    shutil.copyfile(full, out)
    prodos.mount(out)
    problems = []
    try:
        prodos.mkdir('/mnt/MAUX/LO')
        prodos.mkdir('/mnt/MAUX/LO/inc')
        for src, dst in ((HELLO_PLA, '/mnt/MAUX/LO/hello.pla'),
                         (CMDSYS_PLH, '/mnt/MAUX/LO/inc/cmdsys.plh')):
            with open(src, 'rb') as f:
                data = convert.text_from_host(f.read())
            prodos.write(dst, data, file_type=0x04, aux_type=0,
                         overwrite=True)
        x = '/mnt/MAUX/X'
        prodos.mkdir(x)
        for n, d in mods.items():
            prodos.write(f'{x}/{n}.mod', d, file_type=0xFE, aux_type=0,
                         overwrite=True)
        with open(ae, 'rb') as f:
            prodos.write('/mnt/MAUX/BIN/ae', f.read(), file_type=0x06,
                         aux_type=0x0800, overwrite=True)
        prodos.write(f'{x}/T.TXT', maux_text(b'HELLO\nWORLD\n'),
                     file_type=0x04, aux_type=0, overwrite=True)
        prodos.write(f'{x}/B.BIN', BIN16, file_type=0x06, aux_type=0,
                     overwrite=True)
        prodos.write(f'{x}/t.s', maux_text(b' org $2000\n lda #1\n rts\n'),
                     file_type=0x04, aux_type=0, overwrite=True)
        prodos.write(f'{x}/u.s',
                     maux_text(b' put inc/zp.equ\n org $2000\n rts\n'),
                     file_type=0x04, aux_type=0, overwrite=True)
        mk = ('all:\n\trm -f x.mod\n\tplasm x.pla x.mod\n\tls x.mod\n')
        with open(HELLO_PLA, 'rb') as f:
            hello = f.read()
        prodos.mkdir(f'{x}/mk')
        for sub, src in (('ok', hello),
                         ('bad', b'include "inc/cmdsys.plh"\n'
                                 b'byte big[1500]\ndone\n')):
            prodos.mkdir(f'{x}/mk/{sub}')
            prodos.write(f'{x}/mk/{sub}/Makefile',
                         maux_text(mk.encode()),
                         file_type=0x04, aux_type=0, overwrite=True)
            prodos.write(f'{x}/mk/{sub}/x.pla', maux_text(src),
                         file_type=0x04, aux_type=0, overwrite=True)
        got = bytes(prodos.read('/mnt/MAUX/USR/inc/cmdsys.plh'))
        with open(CMDSYS_PLH, 'rb') as f:
            want = f.read()
        want = maux_text(want)
        if got != want:
            problems.append('/usr/inc/cmdsys.plh is not Dave\'s file '
                            f'(staged {len(got)} B, expected {len(want)} B)')
    finally:
        prodos.unmount('MAUX')
    return problems


def type_file(s, name, lines):
    """`cat > name`, the lines one key at a time, ^D."""
    s.t.wait_prompt(f'{name}: prompt before cat')
    s.t.type_human('cat > ' + name)
    s.t.enter()
    for line in lines:
        s.t.type_human(line)
        s.t.enter()
    s.t.press(s.t.CTRL_D)
    s.t.wait_prompt(f'{name}: prompt after ^D')


def compile_ok(rows):
    text = '\n'.join(rows)
    m = COMPILED.search(text)
    return (m is not None and 'Error' not in text), text


def buffer_size(rows):
    m = re.search(r'Data\+Code buffer size = \$([0-9A-F]{1,4})',
                  '\n'.join(rows))
    return int(m.group(1), 16) if m else None


def run_hello(s, failures, label, mod):
    rows = s.run(f'plasma {mod}')
    if not any(r.strip() == 'Hello, world.' for r in rows):
        fail(failures, f'{label}: `plasma {mod}` did not print '
                       f'`Hello, world.`; screen {rows[-4:]!r}')
        return False
    rows = s.run('echo rc=$?')
    if not any(r.strip() == 'rc=0' for r in rows):
        fail(failures, f'{label}: `plasma {mod}` exit status {rows[-2:]!r}')
        return False
    return True


def row_high(s, failures, dave):
    s.run('mkdir /tmp/pa')
    s.run('cd /tmp/pa')
    type_file(s, 'hello.pla', dave.split('\n')[:-1])
    n = len(dave)
    rows = s.run('wc -c hello.pla')
    if not any(re.search(rf'\b{n}\b', r) for r in rows):
        fail(failures, f'PF1: hello.pla on the machine is not {n} bytes '
                       f'(Dave\'s); wc said {rows[-2:]!r}')
    # PF2 -- the lesson's exact line, no inc/ here
    rows = s.run('plasm hello.pla hello.mod')
    ok, text = compile_ok(rows)
    if not ok:
        fail(failures, 'PF2: `plasm hello.pla hello.mod` did not compile '
                       f'Dave\'s hello.pla: {rows[-6:]!r}')
        return
    print('[check-plasm-full] PF2: `plasm hello.pla hello.mod` (high-bit '
          f'source, no inc/ here): {COMPILED.search(text).group(0)}')
    bs = buffer_size(rows)
    if bs is None or bs >= 0x8000 or bs < 64:
        fail(failures, 'PF12: plasm\'s Data+Code buffer size is '
                       f'{bs if bs is None else hex(bs)} -- a size >= $8000 '
                       'is negative: the overflow check is disabled by a '
                       'shortage of heap')
    else:
        print(f'[check-plasm-full] PF12: code buffer ${bs:04X} bytes '
              '(positive)')
    # PF3
    if run_hello(s, failures, 'PF3', 'hello.mod'):
        print('[check-plasm-full] PF3: `plasma hello.mod` printed '
              '`Hello, world.`, exit 0')
    # PF4 -- local inc/, same bytes
    s.run('mkdir inc')
    s.run('cp /usr/inc/cmdsys.plh inc')
    rows = s.run('plasm hello.pla hello2.mod')
    ok, text = compile_ok(rows)
    if not ok:
        fail(failures, f'PF4: compile with a local inc/ failed: {rows[-6:]!r}')
        return
    rows = [r for r in s.run('cmp hello.mod hello2.mod')
            if not CF.PROMPT.fullmatch(r.strip())]
    if rows:
        fail(failures, 'PF4: local inc/ and /usr/inc fallback built '
                       f'different modules: {rows!r}')
        return
    print('[check-plasm-full] PF4: a local inc/ builds a byte-identical '
          'module (cmp)')


def row_low(s, failures):
    s.run('cd /mnt/MAUX/LO')
    rows = s.run('plasm hello.pla low.mod')
    ok, text = compile_ok(rows)
    if not ok:
        fail(failures, 'PF5: the low-ASCII source with a low-ASCII local '
                       f'inc/ did not compile: {rows[-6:]!r}')
        return
    rows = [r for r in s.run('cmp low.mod /tmp/pa/hello.mod')
            if not CF.PROMPT.fullmatch(r.strip())]
    if rows:
        fail(failures, 'PF5: the low-ASCII source built a different module '
                       f'from the high-bit one: {rows!r}')
        return
    if run_hello(s, failures, 'PF5', 'low.mod'):
        print('[check-plasm-full] PF5: low-ASCII source and header compile '
              'to the identical module, which runs')


def cksum_of(s, path):
    rows = s.run(f'cksum {path}')
    for r in rows:
        m = re.match(r'\s*(\d+)\s+(\d+)\s', r)
        if m:
            return (m.group(1), m.group(2))
    return None


def row_newline(s, failures):
    s.run('cd /mnt/MAUX/X')
    rows = s.run('plasma nltest.mod')
    txt = [r for r in rows if r.startswith('TXT ')]
    binr = [r for r in rows if r.startswith('BIN ')]
    if not txt or not binr:
        fail(failures, f'PF7: nltest printed {rows[-5:]!r}')
        return
    mt = re.match(r'TXT ref=(\d+) n=(\d+)', txt[0])
    mb = re.match(r'BIN ref=(\d+) n=(\d+)', binr[0])
    want = ''.join(f'{b:02X}' for b in BIN16)
    # the 16 bytes print as 48 columns: two rows on the 40-column glass
    got = ''.join(rows[rows.index(binr[0]) + 1:][:-1]).replace(' ', '')
    if not (mt and mb and mt.group(1) == mb.group(1)):
        fail(failures, f'PF7: the two opens did not reuse a refnum: {rows!r}')
    elif int(mt.group(2)) != 6:
        fail(failures, f'PF7: the text read returned {mt.group(2)}, not 6')
    elif int(mb.group(2)) != 16 or got != want:
        fail(failures, 'PF7: a binary read on a REUSED refnum was cut or '
                       f'bit-stripped by the old newline mode: n={mb.group(2)}'
                       f' bytes {got!r} (want 16: {want})')
    else:
        print('[check-plasm-full] PF7: a binary read on the refnum a text '
              'read just closed returns all 16 bytes, bit 7 intact')


def row_cmdline(s, failures):
    s.run('cd /tmp')
    # `ae` is a cooked argecho: its command line is the typed line
    # itself, program name first. 127 characters in all:
    arg = 'b' * (CMDLN_MAX - len('ae '))
    rows = s.run(f'ae {arg}')
    blob = ''.join(r.rstrip() for r in rows)     # 40-column rows wrap
    if f'LEN={CMDLN_MAX}' not in blob or f'[ae {arg}]' not in blob:
        fail(failures, f'PF8: a {CMDLN_MAX}-character command line did not '
                       f'arrive whole: {rows[-5:]!r}')
    else:
        print(f'[check-plasm-full] PF8: a {CMDLN_MAX}-character command line '
              'arrives whole')
    # one more. A typed line is itself capped at 127, so build it from
    # five shell variables (a value holds only a few dozen characters):
    n = CMDLN_MAX + 1 - len('ae ')
    parts = [25] * (n // 25)
    assert sum(parts) == n
    for name, k in zip('ABCDE', parts):
        s.run(f'{name}={"c" * k}')
    rows = s.run('ae $A$B$C$D$E')
    if not any('rt: command line too long' in r for r in rows):
        fail(failures, 'PF8: a 128-character command line was not refused '
                       f'with `rt: command line too long`: {rows[-4:]!r}')
        return
    rows = s.run('echo rc=$?')
    if not any(r.strip() == 'rc=2' for r in rows):
        fail(failures, f'PF8: the refusal did not exit 2: {rows[-2:]!r}')
    else:
        print('[check-plasm-full] PF8: 128 characters is refused, '
              '`rt: command line too long`, exit 2')


def row_symfull(s, failures):
    s.run('cd /mnt/MAUX/X')
    rows = s.run('plasma bigexp.mod')
    if not any('rt: symbol table full' in r for r in rows):
        fail(failures, f'PF9: 150 exports did not hit `rt: symbol table '
                       f'full`: {rows[-4:]!r}')
        return
    rows = s.run('echo rc=$?')
    if not any(r.strip() == 'rc=2' for r in rows):
        fail(failures, f'PF9: symbol table full did not exit 2: {rows[-2:]!r}')
        return
    print('[check-plasm-full] PF9: more exports than the table holds: '
          '`rt: symbol table full`, exit 2')


def row_nas_long(s, failures):
    s.run('cd /mnt/MAUX/X')
    rows = s.run(f'nas -o t.o {LONG_NAME}')
    if not rows or not CF.PROMPT.fullmatch(rows[-1].strip()):
        fail(failures, 'PF10: a 100-byte argument to nas left no prompt')
        return
    rows = s.run('nas -o t.o t.s')
    if not any(re.search(r'nas: [1-9]\d* bytes -> t\.o', r) for r in rows):
        fail(failures, f'PF10: the assembly AFTER a 100-byte argument to '
                       f'nas failed: {rows[-4:]!r}')
        return
    print('[check-plasm-full] PF10: a 100-byte argument to a cooked nas: '
          'clean error, and the next assembly is right')


def row_protect(s, failures):
    s.run('cd /mnt/MAUX/X')                  # no inc/ here
    h1 = cksum_of(s, '/usr/inc/cmdsys.plh')
    h2 = cksum_of(s, '/usr/inc/stdio.equ')
    if not h1 or not h2:
        fail(failures, 'PF11: cannot cksum the system headers')
        return
    rows = s.run('plasm /tmp/pa/hello.pla inc/cmdsys.plh')
    text = '\n'.join(rows)
    # plasm prints `Total bytes compiled` BEFORE it opens the output, so
    # the proof of a loud failure is the open error, not that line's absence
    loud = 'Error opening: inc/cmdsys.plh' in text
    s.run('nas -o inc/stdio.equ t.s')
    ok = True
    if cksum_of(s, '/usr/inc/cmdsys.plh') != h1:
        fail(failures, 'PF11: `plasm src inc/cmdsys.plh` wrote over '
                       '/usr/inc/cmdsys.plh')
        ok = False
    if cksum_of(s, '/usr/inc/stdio.equ') != h2:
        fail(failures, 'PF11: `nas -o inc/stdio.equ` wrote over '
                       '/usr/inc/stdio.equ')
        ok = False
    if not loud:
        fail(failures, 'PF11b: a write through the inc/ fallback was not '
                       f'refused loudly: {rows[-4:]!r}')
        ok = False
    rows = s.run('nas -o u.o u.s')
    text = '\n'.join(rows)
    if re.search(r'nas: [1-9]\d* bytes -> u\.o', text):
        fail(failures, 'PF11: nas `put inc/zp.equ` with no local inc/ '
                       'assembled from /usr/inc -- the fallback leaked '
                       f'into nas: {rows[-3:]!r}')
        ok = False
    if ok:
        print('[check-plasm-full] PF11: no write reaches /usr/inc through '
              'plasm or nas, and nas gets no fallback')


def row_makefile(s, failures):
    for sub, good in (('ok', True), ('bad', False)):
        s.run(f'cd /mnt/MAUX/X/mk/{sub}')
        rows = s.run('make')
        text = '\n'.join(rows)
        rows2 = s.run('echo rc=$?')
        m = [re.match(r'rc=(\d+)', r.strip()) for r in rows2]
        rc = next((int(x.group(1)) for x in m if x), None)
        if good:
            if rc != 0 or 'x.mod' not in text:
                fail(failures, f'PF13: a good program did not make: rc={rc}'
                               f' {rows[-4:]!r}')
                return
        else:
            if rc in (0, None) or 'overflowed' not in text:
                fail(failures, 'PF13: an overflowing program did not stop '
                               f'make: rc={rc} {rows[-4:]!r}')
                return
    print('[check-plasm-full] PF13: a lesson Makefile (rm -f, plasm, ls): '
          'a good program makes, rc 0; an overflow stops make, nonzero')


def host_splice_counts(failures):
    """HV2: the FILEIO splice refuses a fileio.pla whose marker counts are
    not the ones fileio.frag.pla declares (one of two STOP hooks gone
    used to splice with rc 0 and leave half a fallback)."""
    src = os.path.join(ROOT, 'src', 'plasma', 'fileio.pla')
    snip = os.path.join(ROOT, 'src', 'plasma', 'fileio.frag.pla')
    tool = os.path.join(SCRIPTS, 'splice_fileio.py')
    d = tempfile.mkdtemp(prefix='hv2-')
    try:
        text = open(src).read()
        ok = subprocess.run([sys.executable, tool, src, snip],
                            capture_output=True, text=True)
        i = text.index('//@INCFB-STOP@')
        j = text.index('\n', i)
        broken = os.path.join(d, 'fileio.pla')
        with open(broken, 'w') as f:
            f.write(text[:i] + text[j:])
        bad = subprocess.run([sys.executable, tool, broken, snip],
                             capture_output=True, text=True)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    if ok.returncode != 0:
        fail(failures, f'HV2: the real splice failed: {ok.stderr!r}')
    elif bad.returncode == 0 or 'expected 2' not in bad.stderr:
        fail(failures, 'HV2: a fileio.pla with ONE of two STOP markers '
                       f'spliced anyway: rc={bad.returncode} {bad.stderr!r}')
    else:
        print('[check-plasm-full] HV2: the FILEIO splice refuses a marker '
              'count other than the declared one')


def host_validated_heap(failures):
    """HV1: the VALIDATED_HEAP refusal has teeth."""
    import contextlib
    import io
    import build_nas_librel_image as bnl
    with open(os.path.join(BUILD, 'nas.cut'), 'rb') as f:
        real = 0xBF00 - 0x0800 - len(f.read())
    old = bnl.VALIDATED_HEAP
    old_cut = bnl.NAS_CUT
    scratch = tempfile.mkdtemp(prefix='hv1-')
    bnl.VALIDATED_HEAP = real + 1
    # the composer re-cooks nas before it checks the heap: point it at a
    # scratch file so build/nas.cut is neither rewritten nor touched
    bnl.NAS_CUT = os.path.join(scratch, 'nas.cut')
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err), \
                contextlib.redirect_stdout(io.StringIO()):
            rc = bnl.main()
    finally:
        bnl.VALIDATED_HEAP = old
        bnl.NAS_CUT = old_cut
        shutil.rmtree(scratch, ignore_errors=True)
    if rc != 2 or 'below the' not in err.getvalue():
        fail(failures, f'HV1: VALIDATED_HEAP {real + 1} (real heap {real}) '
                       f'was not refused: rc={rc} {err.getvalue()!r}')
    else:
        print(f'[check-plasm-full] HV1: a validated heap of {real + 1} B '
              f'against a real {real} B is refused, rc 2')


def row_longarg(s, failures):
    s.run('cd /tmp/pa')
    rows = s.run(f'plasm {LONG_NAME}')
    text = '\n'.join(rows)
    if 'PLASMA Compiler' not in text:
        fail(failures, 'PF6: a 100-byte argument stopped plasm before its '
                       f'banner: {rows[-4:]!r}')
        return
    rows = s.run('plasm hello.pla after.mod')
    ok, _ = compile_ok(rows)
    if not ok:
        fail(failures, 'PF6: the compile AFTER a 100-byte argument '
                       f'failed: {rows[-5:]!r}')
        return
    print('[check-plasm-full] PF6: a 100-byte argument reached the cooked '
          'tool; the prompt came back and the next compile worked')


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    disk = os.path.abspath(sys.argv[1])
    with open(HELLO_PLA, 'rb') as f:
        raw = f.read()
    dave = raw.decode('ascii')
    low = os.path.join(ROOT, 'build', 'plasm-full-low.po')
    failures = []
    tmp = tempfile.mkdtemp(prefix='plasm-full-')
    host_validated_heap(failures)
    host_splice_counts(failures)
    for p_ in derive(disk, low, tmp):
        fail(failures, 'PF4: ' + p_)
    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
    c = MCPClient([SUPERVISOR], env)
    try:
        c.initialize()
        CF.boot_to_prompt(c, low)
        s = CF.Session(c)
        for label, fn in (('high-bit', lambda: row_high(s, failures, dave)),
                          ('low-ascii', lambda: row_low(s, failures)),
                          ('long arg', lambda: row_longarg(s, failures)),
                          ('newline', lambda: row_newline(s, failures)),
                          ('cmdline', lambda: row_cmdline(s, failures)),
                          ('symtbl', lambda: row_symfull(s, failures)),
                          ('nas long', lambda: row_nas_long(s, failures)),
                          ('protect', lambda: row_protect(s, failures)),
                          ('makefile', lambda: row_makefile(s, failures))):
            try:
                fn()
            except (T.Wedged, AssertionError, RuntimeError) as e:
                fail(failures, f'{label}: {str(e).splitlines()[0]}')
                break
    finally:
        c.close()
        if os.path.exists(low) and not os.environ.get('PLASM_FULL_KEEP'):
            os.unlink(low)
        shutil.rmtree(tmp, ignore_errors=True)
    if failures:
        print(f'[check-plasm-full] FAIL ({len(failures)}):')
        for f in failures:
            print('  - ' + f.splitlines()[0])
        return 1
    print('[check-plasm-full] PASS: Dave\'s own hello.pla, typed on the '
          'machine, compiles with `plasm hello.pla hello.mod` and runs, in '
          'either text convention')
    return 0


if __name__ == '__main__':
    sys.exit(main())
