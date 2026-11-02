#!/usr/bin/env python3
"""check_exec.py -- spawn inspects the file (`make check-exec`,
docs/EXEC-SHEBANG.md Parts 1 and 2).

Boots the play image with fixtures a2til writes into the boot volume's
/TMP, and types everything at the shell, the check_mount.py idiom (its
helpers are imported).  There is no exec bit: BIN and SYS run, a TXT
runs through its `#!` line (Part 2), everything else is ERR_NOEXEC.

Part 1 rows (the kernel refuses):

  1. A TXT named as a command -- by absolute path and through PATH --
     prints `sh: cannot execute`, `$?` is 126, and the prompt comes
     back whole: the next typed command runs and the row above the
     new prompt is that command's own output (the `$ $` class of bug,
     docs/TTY-TYPEAHEAD-BELL.md Part 3).
  2. A DIRECTORY named as a command is refused the same way.
  3. A BIN still runs (a staged copy of /bin/echo).
  4. WARM: that BIN run twice leaves its bank tagged; `chtyp TXT` on
     it makes the third run refuse -- the freshness test in
     LZ_TRY_WARM must not wave a re-typed file through.

Part 3 (KFIX2 item 1) rows -- an EMPTY file is not a program:

  10. A zero-length BIN with a valid load base (`true > X`), by
      absolute path and through PATH: `sh: cannot execute`, `$?` 126,
      and the console takes the next command.  The loader used to copy
      nothing and run the bank's zeros; a user BRK parked the WHOLE
      machine on the pre-KBRK kernel (now it kills just the process,
      $? 133 -- docs/KBRK.md), so a loader without the refusal is
      still red here: the row wants `cannot execute` and 126.
  11. The same through a retained bank: a BIN run twice (warm), then
      truncated by `true > X` (SET_EOF drops the tag, KFIX item 2),
      is refused cold the same way.

Teeth: `--play build-of-main/play.po` runs the same script against a
build whose spawn loads anything; row 1 and 4 must read red there.
Part 3 on a kernel without the EOF-0 refusal TIMES OUT at row 10 (the
console is dead), reported as the rig's "timed out waiting" failure.

ASCII only.  Exit 0 green, 1 red (listed), 2 rig problem.
"""
import argparse
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import check_devfs as D  # noqa: E402
import check_mount as M  # noqa: E402
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402
from a2til import prodos  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def stage(boot, files):
    """files: {'/TMP/NAME': (bytes, file_type)} written into the copy."""
    v = prodos.Volume(boot)
    for path, (data, ftype) in files.items():
        if data is None:                       # a copy of /BIN/ECHO
            data = v.read_file('/BIN/ECHO')
        v.write_file(path, data, file_type=ftype,
                     aux_type=0x0800)
    v.close()


FIXTURES = {
    '/TMP/NOTCMD': (b'HELLO\r', 0x04),
    '/TMP/E2': (None, 0x06),
    '/TMP/EMPTY': (b'', 0x06),          # BIN, aux $0800, EOF 0
    '/TMP/E3': (None, 0x06),
}


def boot_client(boot):
    env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
    client = MCPClient([SUPERVISOR], env)
    client.initialize()
    client.call_tool('reset', {'backend': 'fast'})
    r = client.call_tool('mount_disk', {'path': boot, 'unit': 1})
    if r.get('ok') is False:
        raise RuntimeError(f'mount_disk(unit 1) failed: {r}')
    for addr, val in ((D.PT_F40_ADDR, D.PT_F40_MAG1),
                      (D.PT_F40B_ADDR, D.PT_F40_MAG2)):
        client.call_tool('poke', {'addr': addr, 'bytes': [val],
                                  'bank': 'main'})
    D.wait_for_screen(client, D.prompt_ready, 'shell prompt')
    return client


def part1(client, f):
    sh, status, eq = M.sh, M.status, M.eq
    # -- 1: a TXT is data, not a program ---------------------------------
    out = sh(client, '/tmp/notcmd', '1 abs', f)
    eq('1: /tmp/notcmd: diagnostic', out, ['sh: cannot execute'], f)
    eq('1: /tmp/notcmd: $?', status(client, f, '1'), '126', f)
    eq('1: the prompt comes back whole',
       sh(client, 'echo ok', '1 echo', f), ['ok'], f)
    sh(client, 'PATH=/tmp:$PATH', '1 path', f)
    out = sh(client, 'notcmd', '1 path run', f)
    eq('1: notcmd through PATH: diagnostic', out,
       ['sh: cannot execute'], f)
    eq('1: notcmd through PATH: $?', status(client, f, '1p'), '126', f)
    sh(client, 'PATH=/bin', '1 path restore', f)
    eq('1: again, the prompt is whole', sh(client, 'echo ok2', '1 e2', f),
       ['ok2'], f)
    # -- 2: a directory is not a program ---------------------------------
    out = sh(client, '/tmp', '2 dir', f)
    eq('2: a directory: diagnostic', out, ['sh: cannot execute'], f)
    eq('2: a directory: $?', status(client, f, '2'), '126', f)
    # -- 3: a BIN still runs ---------------------------------------------
    eq('3: BIN copy runs', sh(client, '/tmp/e2 alive', '3 run', f),
       ['alive'], f)
    # -- 4: warm respawn must not wave a re-typed file through -----------
    eq('4: BIN copy runs again (warm)',
       sh(client, '/tmp/e2 warm', '4 run', f), ['warm'], f)
    sh(client, 'chtyp -t 4 /tmp/e2', '4 chtyp', f)
    eq('4: chtyp exit', status(client, f, '4'), '0', f)
    out = sh(client, '/tmp/e2 gone', '4 run3', f)
    eq('4: re-typed to TXT: refused', out, ['sh: cannot execute'], f)
    eq('4: re-typed to TXT: $?', status(client, f, '4b'), '126', f)


#: scripts are written by maux itself (echo > file), so they carry
#: the shell's own text encoding and no host-side bit twiddling
SCRIPTS = {
    's1': ['#!/bin/sh', 'echo s0=$0 a=$1 b=$2'],
    's2': ['#!/tmp/s1', 'echo never'],
    's3': ['#!/tmp/s2', 'echo never'],
    'sx': ['#!/bin/sh -x', 'echo traced'],
    'sb': ['#!sh', 'echo bare'],
    'sn': ['#!/nope', 'echo never'],
    'se': ['#!', 'echo never'],
}


def part2(client, f):
    sh, status, eq = M.sh, M.status, M.eq
    for name, lines in SCRIPTS.items():
        for i, text in enumerate(lines):
            sh(client, f"echo '{text}' {'>>' if i else '>'} /tmp/{name}",
               'mk ' + name, f)
    # -- 5: #! runs the script through its interpreter -------------------
    eq('5: /tmp/s1 x y: $0 and the args',
       sh(client, '/tmp/s1 x y', '5 s1', f), ['s0=/tmp/s1 a=x b=y'], f)
    eq('5: /tmp/s1: $?', status(client, f, '5'), '0', f)
    eq('5: a bare interpreter goes through PATH',
       sh(client, '/tmp/sb', '5 sb', f), ['bare'], f)
    got = sh(client, '/tmp/sx', '5 sx', f)
    eq('5: the one-argument form runs `sh -x script`',
       'traced' in got and any('echo' in r and r.startswith('+')
                               for r in got), True, f)
    # -- 6: an interpreter that is itself a script nests once ------------
    eq('6: s2 -> s1 -> sh', sh(client, '/tmp/s2 q', '6 s2', f),
       ['s0=/tmp/s1 a=/tmp/s2 b=q'], f)
    eq('6: three deep is refused',
       sh(client, '/tmp/s3', '6 s3', f), ['sh: cannot execute'], f)
    eq('6: $?', status(client, f, '6'), '126', f)
    # -- 7: what is not a #! program stays refused -----------------------
    eq('7: #! naming nothing on disk', sh(client, '/tmp/sn', '7 sn', f),
       ['sh: command not found'], f)
    eq('7: a bare #!', sh(client, '/tmp/se', '7 se', f),
       ['sh: cannot execute'], f)
    eq('7: TXT without #! (NOTCMD)', sh(client, '/tmp/notcmd', '7 nc', f),
       ['sh: cannot execute'], f)
    # -- 8: test -x answers by the same inspection ------------------------
    for path, want in (('/tmp/s1', '0'), ('/tmp/notcmd', '1'),
                       ('/tmp/se', '1'), ('/tmp/e2', '1'),
                       ('/tmp/nope', '1'), ('/bin/ls', '0')):
        sh(client, f'test -x {path}', '8 test', f)
        eq(f'8: test -x {path}', status(client, f, '8'), want, f)
    # -- 9: spawners other than sh do NOT run #! scripts (known
    # -- divergence, docs/EXEC-SHEBANG-NOTES.md): the placement is
    # -- the shell's, and these call SC_SPAWN themselves.  Pinned so
    # -- the day one learns `#!` this row is retired by name.
    for cmd, diag in (
            ('find /tmp -name s1 -exec /tmp/s1 hi \\;',
             ['find: /tmp/s1: exec failed']),
            ('echo hi | xargs /tmp/s1', ['xargs: cannot invoke utility']),
            ('env /tmp/s1 q', ['env: /tmp/s1: cannot execute']),
            ('time /tmp/s1 q', ['time: cannot run command']),
            ('timeout 5 /tmp/s1 q', ['timeout: /tmp/s1: cannot execute'])):
        eq(f'9: {cmd}: refused cleanly', sh(client, cmd, '9 ' + cmd, f),
           diag, f)
        eq('9: the prompt is whole', sh(client, 'echo ok9', '9 e', f),
           ['ok9'], f)


def part3(client, f):
    sh, status, eq = M.sh, M.status, M.eq
    # -- 10: a zero-length BIN is refused, and the console lives ---------
    n0 = len(f)
    out = sh(client, '/tmp/empty', '10 abs', f)
    if len(f) > n0:                  # the machine is parked: stop here
        f.append('10: the console never came back after /tmp/empty '
                 '(a zero-length BIN ran the bank\'s zeros: BRK parks '
                 'the machine on a pre-KBRK kernel); the remaining '
                 'part 3 rows are skipped')
        return
    eq('10: /tmp/empty: diagnostic', out, ['sh: cannot execute'], f)
    eq('10: /tmp/empty: $?', status(client, f, '10'), '126', f)
    eq('10: the console takes the next command',
       sh(client, 'echo ok10', '10 echo', f), ['ok10'], f)
    sh(client, 'PATH=/tmp:$PATH', '10 path', f)
    out = sh(client, 'empty', '10 path run', f)
    eq('10: empty through PATH: diagnostic', out,
       ['sh: cannot execute'], f)
    eq('10: empty through PATH: $?', status(client, f, '10p'), '126', f)
    sh(client, 'PATH=/bin', '10 path restore', f)
    # -- 11: a retained BIN truncated to nothing ---------------------------
    eq('11: BIN copy runs', sh(client, '/tmp/e3 one', '11 run', f),
       ['one'], f)
    eq('11: BIN copy runs again (warm)',
       sh(client, '/tmp/e3 two', '11 run2', f), ['two'], f)
    sh(client, 'true > /tmp/e3', '11 truncate', f)
    out = sh(client, '/tmp/e3 three', '11 run3', f)
    eq('11: truncated to EOF 0: refused', out, ['sh: cannot execute'], f)
    eq('11: truncated to EOF 0: $?', status(client, f, '11'), '126', f)
    eq('11: the console takes the next command',
       sh(client, 'echo ok11', '11 echo', f), ['ok11'], f)


def run(play, failures, parts):
    tmp = tempfile.mkdtemp(prefix='maux-exec-')
    try:
        boot = os.path.join(tmp, 'play.po')
        shutil.copy(play, boot)
        stage(boot, FIXTURES)
        client = boot_client(boot)
        try:
            for p in parts:
                p(client, failures)
        finally:
            client.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--play', default=os.path.join(ROOT, 'build',
                                                   'play.po'))
    args = ap.parse_args()
    play = os.path.abspath(args.play)
    if not os.path.exists(play):
        print(f'check-exec: {play} missing -- make play-image')
        return 2
    failures = []
    try:
        run(play, failures, [part1, part2, part3])
    except RuntimeError as exc:
        failures.append(str(exc))
    if failures:
        print(f'[check-exec] FAIL: {len(failures)} row(s)')
        for x in failures:
            print(f'  - {x}'.replace('\n', '\n    '))
        return 1
    print('[check-exec] PASS: spawn refuses what is not a program')
    return 0


if __name__ == '__main__':
    sys.exit(main())
