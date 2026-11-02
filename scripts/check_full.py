#!/usr/bin/env python3
"""check_full.py -- the release disk, booted and used the way a person
would use it (`make check-full`, docs/FULLDISK.md sec 3).

Boots build/full.po (a copy-on-write mount: the file is never written)
with e2e_term.Term -- one key at a time, lowercase, as a person types --
and asserts:

  0. THE IMAGE, from its raw bytes, by a reader that shares no code with
     the builder or with a2til (prodos_audit.py): every directory field
     at 65,535 blocks, the 16-block bitmap against the walk, the boot
     blocks equal to play.po's. Host-side and fast, so it runs first.
  1. BOOT to a shell prompt on the fast backend; the cycles to the prompt
     are measured against play.po's, boot code for boot code, and
     printed. A 65,535-block volume has a 16-block bitmap; this is where
     the boot would pay for it.
  2. THE ROSTER: every name in the Makefile's UTILS, plus nas, ld and
     plasm, is on the disk and resolves on PATH. The list is derived
     (build_full_image.full_util_names), never typed here. A name the
     shell treats as a builtin (echo, test, ...) is held to the file in
     /bin instead, since `type` would answer "builtin" either way.
  3. HELLO, WORLD FROM THE DISK ALONE: cd /usr/src/examples/HELLO, nas,
     ld -L /usr/lib -l a, run it as `./hello` (KFIX10 item 3: a word
     with a slash is a path), `hello, world` on the glass. Nothing
     is staged by the host except what is on the disk. The sources and
     /usr/inc are MAUX TEXT (high bit, $8D) since KFIX10 item 2.
  4. A PROSDOS SYSTEM PROGRAM BUILT ON MAUX, RUN WITH `bye` (SITE.md
     6.3, the first natively built tenant ever gated): nas, then
     `ld -t FF -a 2000`, then `bye HELLO.SYSTEM`. Its line is polled for
     on the 40-column page DURING the window (check_tenant.py's method:
     after the restore repaints the screen it is gone even on a correct
     build), then `Welcome back.`, a prompt, and the file it wrote.
  4a. THE EXAMPLE MAKEFILES: `make clean`, `make`, a second `make` with
     nothing to do, `cmp` against the raw build, run -- HELLO, and
     HELLOSYS under `bye` again. Shipped files a lesson hands the reader
     are files a gate runs. The Makefiles name bare `nas`, `ld` and
     `rm` (KFIX10 item 4: make searches PATH) and are maux text.
  5. THE WORLD REBUILD IS REACHABLE: cd /usr/src/maux; make -n lists the
     whole graph (every nas and the kernel link) and exits 0. The real
     rebuild is check-nas-selfmake's (10.55 billion cycles) and is not
     repeated here. `make -n` is not free: it stats ~1,300 targets in a
     900-file directory, ~1 billion cycles.

Row 6 (determinism: two builds, identical bytes) is check-release-image.

Teeth, each seen red before this gate counted: docs/FULLDISK-NOTES.md.
"""
import os
import re
import sys

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SCRIPTS)
sys.path.insert(0, SCRIPTS)
import e2e_term as T                                       # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR     # noqa: E402
from pt_f40 import (PT_F40_ADDR, PT_F40B_ADDR,             # noqa: E402
                    PT_F40_MAG1, PT_F40_MAG2)
import prodos_audit                                        # noqa: E402

PLAY = os.path.join(ROOT, 'build', 'play.po')
PROMPT = re.compile(r'\$( \$)*$')
#: the prompt must appear within this many cycles on either disk
BOOT_LIMIT = 60_000_000
BOOT_STEP = 25_000
#: full.po may take no more than this much longer than play.po to reach
#: the prompt. The fast backend is deterministic in cycles, so this is a
#: tripwire on a measured number, not a flake guard.
BOOT_SLACK = 1.10
#: `make -n` over the staged world, in cycles (measured ~1.04 billion)
MAKE_N_LIMIT = 4_000_000_000
RESULT_NAME = 'RESULT'


def derive_roster():
    import build_full_image as bf
    return bf.full_util_names() + list(bf.FULL_EXTRA_NAMES)


def boot_to_prompt(c, disk, f40=True, reset_extra=None, step=BOOT_STEP):
    """Cold boot `disk` (copy-on-write) and return the cycles to the
    shell prompt, at `step` resolution. The defaults are this gate's:
    the 40-column boot, the host's clock. check_examples.py boots the
    native 80 columns (f40=False) with the clock card pinned off
    (reset_extra={'clock': False}) so a session reads the same on
    every run, and polls coarsely (step) since it needs no cycle count."""
    args = {'backend': 'fast', 'aux': 'ramworks'}
    if reset_extra:
        args.update(reset_extra)
    c.call_tool('reset', args)
    if f40:
        c.call_tool('poke', {'addr': PT_F40_ADDR, 'bytes': [PT_F40_MAG1],
                             'bank': 'main'})
        c.call_tool('poke', {'addr': PT_F40B_ADDR, 'bytes': [PT_F40_MAG2],
                             'bank': 'main'})
    r = c.call_tool('mount_disk', {'path': disk, 'unit': 1, 'copy': True})
    if not r.get('ok'):
        raise RuntimeError(f'mount_disk {disk}: {r}')
    cyc = 0
    while cyc < BOOT_LIMIT:
        c.call_tool('step', {'cycles': step})
        cyc += step
        r = c.call_tool('screen_text', {})
        rows = [x.strip() for x in (r.get('merged') or r.get('main') or [])
                if x.strip()]
        if rows and PROMPT.fullmatch(rows[-1]):
            return cyc
    raise RuntimeError(f'{disk}: no shell prompt within {BOOT_LIMIT} cycles')


class Session:
    """A booted Term with a person-like `run`."""

    def __init__(self, c):
        self.c = c
        self.t = T.Term(c, 'text40')

    def rows(self):
        return [r.rstrip() for r in self.t.screen() if r.strip()]

    @staticmethod
    def since(rows, cmd):
        """The rows after the LAST echo of `cmd` -- the output of this
        command alone, not of every earlier one still on the glass (a
        stale `ld: undefined symbol` line from the hello row must not
        be read as the tenant row's). If the echo has scrolled away the
        whole screen is returned."""
        key = '$ ' + cmd[:36]
        for i in range(len(rows) - 1, -1, -1):
            if rows[i].startswith(key):
                return rows[i + 1:]
        return rows

    def run(self, cmd, label=None, budget_cycles=400_000_000):
        """Wait for a settled prompt, type `cmd` a key at a time, Enter,
        and wait for the prompt again (checked every 1M cycles, so a
        slow command is waited for, not abandoned). Returns the rows."""
        label = label or cmd
        self.t.wait_prompt(label + ' (prompt ready)')
        self.t.type_human(cmd)
        self.t.enter()
        self.t._slice()
        spent = 0
        stable = 0
        last = None
        while spent < budget_cycles:
            rows = self.rows()
            cur = rows[-1].strip() if rows else ''
            if PROMPT.fullmatch(cur) and cur == last:
                stable += 1
                if stable >= 2:
                    return self.since(rows, cmd)
            else:
                stable = 0
            last = cur
            self.c.call_tool('step', {'cycles': 1_000_000})
            spent += 1_000_000
        raise T.Wedged(f'{label}: no prompt within {budget_cycles} cycles;'
                       f' screen:\n' + '\n'.join(self.rows()))


def fail(failures, msg):
    failures.append(msg)
    print(f'[check-full] FAIL: {msg}')


def row_roster(s, failures):
    names = derive_roster()
    builtin = []
    seen = {}
    for i in range(0, len(names), 8):
        batch = names[i:i + 8]
        rows = s.run('type ' + ' '.join(batch), f'type roster {i // 8}')
        text = '\n'.join(rows)
        for n in batch:
            m = re.search(rf'^{re.escape(n)} is (.+)$', text, re.M)
            if not m:
                fail(failures, f'roster: `type {n}` printed no "is" line')
                continue
            where = m.group(1).strip()
            seen[n] = where
            if where == 'a shell builtin':
                builtin.append(n)
            elif where.lower() != f'/bin/{n}'.lower():
                fail(failures, f'roster: {n} resolves to {where!r}, '
                               f'not /bin/{n}')
    # a builtin still has to be on the disk, in /bin
    for i in range(0, len(builtin), 8):
        batch = builtin[i:i + 8]
        rows = s.run('ls ' + ' '.join('/bin/' + n for n in batch),
                     f'ls builtin {i // 8}')
        text = '\n'.join(rows)
        for n in batch:
            if not re.search(rf'(^|\s)/?(bin/)?{re.escape(n)}(\s|$)',
                             text, re.I) or 'No such' in text \
                    or 'cannot' in text:
                fail(failures, f'roster: builtin {n} is not in /bin')
    print(f'[check-full] roster: {len(names)} names resolved '
          f'({len(builtin)} are shell builtins and were held to /bin: '
          f'{" ".join(builtin)})')
    return seen


def row_hello(s, failures):
    s.run('cd /usr/src/examples/HELLO')
    rows = s.run('nas -o hello.o hello.s')
    m = re.search(r'nas: (\d+) bytes -> hello\.o', '\n'.join(rows))
    if not m or int(m.group(1)) == 0:
        fail(failures, 'hello: nas did not assemble hello.s '
                       f'(screen tail {rows[-4:]!r})')
        return
    rows = s.run('ld -o hello hello.o -L /usr/lib -l a')
    if any(re.search(r'ld: ', r) for r in rows):
        fail(failures, f'hello: ld reported {rows[-3:]!r}')
        return
    rows = s.run('ls -l')
    if not any(re.match(r'BIN\s+\d+.*\bhello$', r.strip()) for r in rows):
        fail(failures, f'hello: no BIN `hello` after ld; ls: {rows[-6:]!r}')
        return
    rows = s.run('./hello')
    if not any(r.strip() == 'hello, world' for r in rows):
        fail(failures, f'hello: no `hello, world` line; screen {rows[-5:]!r}')
        return
    print('[check-full] hello: nas -> ld -L /usr/lib -l a -> run printed '
          '`hello, world` (all from the disk)')


def row_stderr(s, failures):
    """NAS-STDERR: nas diagnostics are on fd 2. `nas bad.s 2> E` leaves
    the file and line in E and NOTHING on the glass; the success line
    stays on stdout and leaves its E empty."""
    s.run('cd /tmp')
    s.run("echo ' jsr PUTZ' > bad.s")
    rows = s.run('nas -o bad.o bad.s 2> E')
    if any('nas:' in r or 'PUTZ' in r for r in rows):
        fail(failures, f'stderr: `nas bad.s 2> E` still wrote a diagnostic '
                       f'to stdout: {rows!r}')
        return
    rows = s.run('cat E')
    text = '\n'.join(rows)
    if not re.search(r'nas: unknown label PUTZ \(bad\.s line 1\)', text) \
            or 'nas: pass 2 failed' not in text:
        fail(failures, f'stderr: E lacks the diagnostic with file and '
                       f'line: {rows!r}')
        return
    s.run("echo ' nop' > ok.s")
    rows = s.run('nas -o ok.o ok.s 2> E2')
    if not any(re.search(r'nas: [1-9]\d* bytes -> ok\.o', r) for r in rows):
        fail(failures, f'stderr: the success line left stdout: {rows!r}')
        return
    rows = [r for r in s.run('cat E2') if not PROMPT.fullmatch(r.strip())]
    if rows:
        fail(failures, f'stderr: a clean run wrote to fd 2: {rows!r}')
        return
    print('[check-full] stderr: `nas bad.s 2> E` -> unknown label with file '
          'and line in E, stdout silent; the success line stays on stdout')


def row_tenant(s, failures):
    s.run('cd /usr/src/examples/HELLOSYS')
    rows = s.run('nas -o hello.o hello.s')
    if not re.search(r'nas: [1-9]\d* bytes -> hello\.o', '\n'.join(rows)):
        fail(failures, f'tenant: nas failed; screen {rows[-4:]!r}')
        return
    rows = s.run('ld -t FF -a 2000 -o HELLO.SYSTEM hello.o')
    if any('ld:' in r for r in rows):
        fail(failures, f'tenant: ld reported {rows[-3:]!r}')
        return
    rows = s.run('ls -l')
    if not any(re.match(r'SYS\s+\d+', r.strip()) for r in rows):
        fail(failures, f'tenant: no SYS HELLO.SYSTEM; ls {rows[-6:]!r}')
        return
    if not bye_roundtrip(s, failures, 'tenant'):
        return
    print('[check-full] tenant: HELLO FROM PRODOS seen during the bye '
          f'window, Welcome back., and /mnt/MAUX/{RESULT_NAME} reads HELLO')


def bye_roundtrip(s, failures, label):
    """`bye HELLO.SYSTEM` in the current directory: the farewell, the
    tenant's line polled for DURING the window on the 40-column page,
    `Welcome back.` and a prompt, then the file it wrote."""
    s.t.wait_prompt(f'{label}: prompt before bye')
    s.t.type_human('bye HELLO.SYSTEM')
    s.t.enter()
    saw_farewell = saw_line = saw_prompt = False
    for _ in range(6000):
        s.c.call_tool('step', {'cycles': 20_000})
        rows = s.rows()
        if any('Leaving maux for ProDOS' in r for r in rows):
            saw_farewell = True
        # the tenant's line, polled DURING the window: it must be on
        # the 40-column page while ProDOS 8 is the one running
        if saw_farewell and any('HELLO FROM PRODOS' in r for r in rows):
            saw_line = True
        if saw_line and any('Welcome back.' in r for r in rows) \
                and rows and PROMPT.fullmatch(rows[-1].strip()):
            saw_prompt = True
            break
    if not saw_farewell:
        fail(failures, f'{label}: `bye HELLO.SYSTEM` printed no farewell')
        return False
    if not saw_line:
        fail(failures, f'{label}: HELLO FROM PRODOS never appeared on the '
                       f'40-column page during the window -- the tenant '
                       f'did not run')
        return False
    if not saw_prompt:
        fail(failures, f'{label}: no `Welcome back.` and prompt after the '
                       f'tenant; screen {s.rows()[-5:]!r}')
        return False
    rows = s.run(f'cat /mnt/MAUX/{RESULT_NAME}')
    if not any(r.strip() == 'HELLO' for r in rows):
        fail(failures, f'{label}: the file it wrote ({RESULT_NAME}) does '
                       f'not read back HELLO; screen {rows[-4:]!r}')
        return False
    return True


def row_makefiles(s, failures):
    """The two example Makefiles, which a lesson hands the reader: from a
    clean directory `make` builds the program, a second `make` has nothing
    to do, and the program is byte-identical to the one the raw nas/ld
    commands built (rows 3 and 4) and runs the same."""
    # -- HELLO
    s.run('cd /usr/src/examples/HELLO')
    s.run('cp hello /tmp/hello.raw')
    s.run('make clean')
    rows = s.run('ls')
    if any(r.split()[:1] == ['hello'] or 'hello.o' in r for r in rows):
        fail(failures, f'makefiles: `make clean` left hello behind: {rows!r}')
        return
    rows = s.run('make')
    text = '\n'.join(rows)
    if not re.search(r'nas: [1-9]\d* bytes -> hello\.o', text) \
            or 'make:' in text:
        fail(failures, f'makefiles: `make` in HELLO did not build it: '
                       f'{rows[-5:]!r}')
        return
    rows = s.run('make')
    if any('nas:' in r or '/bin/' in r for r in rows):
        fail(failures, f'makefiles: a second `make` in HELLO still ran '
                       f'commands: {rows[-4:]!r}')
        return
    rows = [r for r in s.run('cmp hello /tmp/hello.raw')
            if not PROMPT.fullmatch(r.strip())]
    if rows:
        fail(failures, f'makefiles: make built a different hello than the '
                       f'raw nas/ld commands: {rows!r}')
        return
    rows = s.run('./hello')
    if not any(r.strip() == 'hello, world' for r in rows):
        fail(failures, f'makefiles: the make-built hello printed '
                       f'{rows[-3:]!r}')
        return
    # -- HELLOSYS (its clean removes the file the tenant really writes)
    s.run('cd /usr/src/examples/HELLOSYS')
    s.run('cp HELLO.SYSTEM /tmp/hs.raw')
    s.run('make clean')
    rows = s.run('cat /mnt/MAUX/' + RESULT_NAME)
    if any(r.strip() == 'HELLO' for r in rows):
        fail(failures, '`make clean` in HELLOSYS left /mnt/MAUX/RESULT')
        return
    rows = s.run('make')
    text = '\n'.join(rows)
    if not re.search(r'nas: [1-9]\d* bytes -> hello\.o', text) \
            or 'make:' in text or 'ld:' in text:
        fail(failures, f'makefiles: `make` in HELLOSYS did not build it: '
                       f'{rows[-5:]!r}')
        return
    rows = [r for r in s.run('cmp HELLO.SYSTEM /tmp/hs.raw')
            if not PROMPT.fullmatch(r.strip())]
    if rows:
        fail(failures, f'makefiles: make built a different HELLO.SYSTEM '
                       f'than the raw nas/ld commands: {rows!r}')
        return
    if not bye_roundtrip(s, failures, 'makefiles'):
        return
    print('[check-full] makefiles: `make clean`, `make` (then nothing to do), '
          'cmp against the raw build, run -- both examples; the make-built '
          'HELLO.SYSTEM ran under bye')


def row_demo(s, failures):
    """The archives on the public disk: DEMOPROG (freely distributable
    per the CD notes) and the two asimov freeware archives, with
    PROVENANCE beside them. XMASADV.SDK has no recorded distribution
    terms, so it must NOT be here (it stays a gate fixture)."""
    rows = s.run('ls /mnt/MAUX/DEMO/*.S?K')
    text = ' '.join(rows)
    for want in ('DEMOPROG.SDK', 'SLOTSCAN.SHK', 'VBLSET.SHK'):
        if want not in text:
            fail(failures, f'demo: {want} is not on the disk; ls: {rows!r}')
    if 'XMASADV' in text:
        fail(failures, 'demo: XMASADV.SDK is on the public disk, and no '
                       'distribution terms are recorded for it '
                       '(fixtures/PROVENANCE.md)')
    rows = s.run('grep -c XMASADV /mnt/MAUX/DEMO/PROVENANCE')
    if not any(r.strip().isdigit() and int(r.strip()) > 0 for r in rows):
        fail(failures, 'demo: PROVENANCE is missing or does not explain '
                       f'XMASADV; {rows!r}')
        return
    print('[check-full] demo: DEMOPROG.SDK, SLOTSCAN.SHK, VBLSET.SHK and '
          'PROVENANCE are on the disk; XMASADV.SDK (no recorded terms) is not')


def row_make_n(s, failures):
    s.run('cd /usr/src/maux')
    rows = s.run('make -n > /tmp/MKN', budget_cycles=MAKE_N_LIMIT)
    rows = s.run('echo rc=$?')
    if not any(r.strip() == 'rc=0' for r in rows):
        fail(failures, f'make -n did not exit 0; screen {rows[-3:]!r}')
        return
    counts = {}
    for key, pat in (('nas', 'BIN/NAS -o'), ('ld', 'BIN/LD'),
                     ('kernel', 'MAUXPLAY.SYSTEM')):
        rows = s.run(f'grep -c "{pat}" /tmp/MKN')
        got = [r.strip() for r in rows if re.fullmatch(r'\d+', r.strip())]
        counts[key] = int(got[-1]) if got else 0
    import json
    with open(os.path.join(ROOT, 'build', 'full-plan.json')) as fh:
        plan = json.load(fh)
    want_ld = len(plan['utils']) + 1          # every util + MAUXPLAY.SYSTEM
    if counts['nas'] < 500 or counts['ld'] < want_ld or counts['kernel'] < 1:
        fail(failures, f'make -n lists too little work: {counts} (want '
                       f'>= 500 nas, >= {want_ld} ld, the kernel link)')
        return
    print(f'[check-full] make -n: rc 0; lists {counts["nas"]} nas lines, '
          f'{counts["ld"]} ld lines, the MAUXPLAY.SYSTEM link '
          f'({counts["kernel"]} line)')


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    disk = os.path.abspath(sys.argv[1])
    failures = []

    # -- 0. the image, from its bytes
    with open(PLAY, 'rb') as f:
        boot = f.read(1024)
    # the audit's own teeth first: it must SEE a corrupted copy
    for p in prodos_audit.selftest(disk):
        fail(failures, p)
    if failures:
        return report(failures)
    problems = prodos_audit.audit(disk, ref_boot=boot)
    st = getattr(prodos_audit.audit, 'last', {})
    if problems:
        for p in problems[:20]:
            fail(failures, f'image audit: {p}')
        return report(failures)
    print(f'[check-full] image audit (raw bytes, independent reader): '
          f'clean -- {st["total"]} blocks, {st["used"]} used, '
          f'{st["free"]} free, {st["bitmap_blocks"]}-block bitmap')

    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
    c = MCPClient([SUPERVISOR], env)
    try:
        c.initialize()
        # -- 1. boot, against play.po's
        play_cyc = boot_to_prompt(c, PLAY)
        full_cyc = boot_to_prompt(c, disk)
        delta = full_cyc - play_cyc
        print(f'[check-full] boot to prompt (fast backend, resolution '
              f'{BOOT_STEP} cycles): play.po {play_cyc:,}, full.po '
              f'{full_cyc:,} ({delta:+,}, {100.0 * delta / play_cyc:+.2f}%)')
        if full_cyc > play_cyc * BOOT_SLACK:
            fail(failures, f'boot: full.po took {full_cyc:,} cycles to the '
                           f'prompt, {BOOT_SLACK:.2f}x play.po\'s {play_cyc:,}')
        s = Session(c)
        for label, fn in (('roster', row_roster), ('hello', row_hello),
                          ('stderr', row_stderr),
                          ('tenant', row_tenant),
                          ('makefiles', row_makefiles), ('demo', row_demo),
                          ('make -n', row_make_n)):
            try:
                fn(s, failures)
            except (T.Wedged, AssertionError, RuntimeError) as e:
                fail(failures, f'{label}: {e}')
                break
    finally:
        c.close()
    return report(failures)


def report(failures):
    if failures:
        print(f'[check-full] FAIL ({len(failures)}):')
        for f in failures:
            print('  - ' + f.splitlines()[0])
        return 1
    print('[check-full] PASS: the disk audits clean, boots as fast as '
          'play.po, carries the whole roster, builds and runs hello '
          'world and a bye tenant itself, and its world rebuild is '
          'reachable')
    return 0


if __name__ == '__main__':
    sys.exit(main())
