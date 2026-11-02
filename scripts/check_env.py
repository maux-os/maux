#!/usr/bin/env python3
"""Boot and verify the ENVIRONMENT gate (`make check-env`,
docs/SYSCALL.md item 13c).

Companion to src/test/envtest.s / scripts/build_env_image.py.

THE VERDICT IS ENVOUT'S THREE LINES, and the middle one is the whole
point: an exported variable reaches a spawned child's getenv AND an
unexported one does not. A partial implementation -- one that stages
the whole variable table -- passes the first line and fails the second,
which is exactly why both are asserted from the same run rather than
from two.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
from build_env_image import (CR, EXPECT_BLTOUT, EXPECT_CWDOUT,  # noqa: E402
                             EXPECT_ENVOUT,
                             EXPECT_EXOUT,
                             EXPECT_GENOUT, EXPECT_IMPOUT,
                             EXPECT_PATHOUT, PATH_VALUE, hitext)

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'env.po')
VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')

R_SCRIPT_FD = 0x1200
R_SH_PID = 0x1201
R_WAIT_PID = 0x1202
R_SH_STATUS = 0x1203
R_DONE = 0x1290
R_ERR = 0x1291
R_STEP = 0x1292


def peek_aux1(client, addr, count=1):
    return client.call_tool('peek', {
        'addr': addr,
        'count': count,
        'bank': 'aux',
        'aux_bank': 1,
    })['bytes']


def read_prodos_files(disk):
    prodos.mount(disk)
    try:
        out = {}
        for name in ('PATHOUT', 'ENVOUT', 'IMPOUT', 'GENOUT',
                     'EXOUT', 'BLTOUT', 'CWDOUT'):
            try:
                out[name] = prodos.read(f'/mnt/{VOL}/{name}')
            except Exception as e:              # never written at all
                out[name] = f'<missing: {e}>'
        return out
    finally:
        prodos.unmount(VOL)


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}',
              file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make env-image first',
              file=sys.stderr)
        return 2

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-env] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-env] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        done = 0
        # sh spawns two children of its own (echo, the probe) and reads
        # a whole script one byte at a time -- same budget as check-sh.
        # RAISED for the import case: a NESTED sh is a whole second
        # shell image load plus two more children of its own.
        for _ in range(2400):
            client.call_tool('step', {'cycles': 200_000})
            done = peek_aux1(client, R_DONE)[0]
            if done in (0xAA, 0xEE):
                break
        err = peek_aux1(client, R_ERR)[0]
        step = peek_aux1(client, R_STEP)[0]
        sh_pid = peek_aux1(client, R_SH_PID)[0]
        wait_pid = peek_aux1(client, R_WAIT_PID)[0]
        sh_status = peek_aux1(client, R_SH_STATUS)[0]
        print(f'[check-env] done=${done:02X} err=${err:02X} step=${step:02X} '
              f'sh_pid={sh_pid} wait_pid={wait_pid} '
              f'sh_status=${sh_status:02X}')

        failures = []
        if done != 0xAA:
            failures.append(f'test did not finish successfully '
                            f'(done=${done:02X}, err=${err:02X}, step={step})')
            # NAME THE CRASH RATHER THAN REPORT A TIMEOUT. The
            # builtin-tag regression (docs/SPAWN-BANK7-CRASH.md) runs
            # zero page as BRK opcodes. Before KBRK that parked the
            # machine in KRN_BRK_TRAP (A=$42) and the run timed out;
            # now the child dies of SIGTRAP and the script carries on,
            # so the same regression shows as BLTOUT=BLT133 (below).
            # This branch is the ROOT-TIER case only -- a BRK in pid 1
            # or idle still parks. Address-independent: no symbol.
            regs = client.call_tool('regs', {})
            if regs.get('a') == 0x42:
                failures.append(
                    f'  the CPU is parked in KRN_BRK_TRAP (A=$42, '
                    f'PC=${regs.get("pc", 0):04X}) -- the kernel took a '
                    f'BRK, it did not merely run out of steps. The known '
                    f'cause is a spawn path whose FIRST CHARACTER matches '
                    f'a builtin-image tag being loaded as that builtin: '
                    f'see docs/SPAWN-BANK7-CRASH.md and the EGONE case in '
                    f'build_env_image.py.')
        if err != 0:
            failures.append(f'R_ERR expected $00, got ${err:02X}')
        if sh_pid == 0:
            failures.append('SPAWN(SH) returned pid 0')
        if wait_pid != sh_pid:
            failures.append(f'wait pid {wait_pid} != spawn pid {sh_pid}')
        if sh_status != 0:
            failures.append(f'sh exit status expected $00, got '
                            f'${sh_status:02X}')

        files = read_prodos_files(disk)
        for _n in ('PATHOUT', 'ENVOUT', 'IMPOUT', 'GENOUT', 'EXOUT',
                   'BLTOUT', 'CWDOUT'):
            print(f'[check-env] {_n}={files[_n]!r}')
        if files['PATHOUT'] != EXPECT_PATHOUT:
            failures.append(
                f'PATHOUT expected {EXPECT_PATHOUT!r}, got '
                f'{files["PATHOUT"]!r} -- with PATH unset, sh must still '
                f'resolve ECHO through its built-in PATHTAB')
        def cmp_lines(name, got, want):
            """Name the line that broke -- "bytes differ" on a
            three-line file is a worse report than it needs to be."""
            if got == want:
                return
            failures.append(f'{name} expected {want!r}, got {got!r}')
            if isinstance(got, bytes):
                for i, (g, w) in enumerate(zip(got.split(b'\x8d'),
                                               want.split(b'\x8d'))):
                    if g != w:
                        failures.append(
                            f'  {name} line {i + 1}: expected {w!r}, '
                            f'got {g!r}')

        cmp_lines('ENVOUT', files['ENVOUT'], EXPECT_ENVOUT)
        cmp_lines('BLTOUT', files['BLTOUT'], EXPECT_BLTOUT)
        if files['BLTOUT'] == hitext('BLT133') + CR:
            failures.append(
                '  BLT133: the EGONE child died of SIGTRAP ($85): the '
                'kernel spawned the bare word as a builtin image (a lone '
                '`rts` into zero page = BRK). The builtin-tag regression '
                'of docs/SPAWN-BANK7-CRASH.md -- a builtin tag must be '
                'the WHOLE path.')
        cmp_lines('CWDOUT', files['CWDOUT'], EXPECT_CWDOUT)

        # THE IMPORT HALF (V7 sh(1), built 2026-08-25). The nested
        # shell assigns and exports NOTHING, so anything it can see it
        # imported.
        cmp_lines('IMPOUT', files['IMPOUT'], EXPECT_IMPOUT)
        if not isinstance(files['IMPOUT'], bytes):
            failures.append(
                'IMPOUT missing entirely -- the nested sh never ran, so '
                'this is a spawn/redirect failure, not an import one')
        # EMPTY, not missing: `> /mnt/MAUX/GENOUT` creates the file
        # before the command word is resolved, so a nested sh that
        # cannot find EP leaves a ZERO-LENGTH file behind. Sabotage A
        # (2026-08-25) proved the missing-file branch this replaced was
        # unreachable in the failure it was written for.
        if not isinstance(files['GENOUT'], bytes) or files['GENOUT'] == b'':
            failures.append(
                'GENOUT empty/missing -- the nested sh could not resolve '
                'EP, which lives only in ' + PATH_VALUE + '. That means '
                'PATH was not imported: sh scanned no environment at '
                'all. (The file exists but is empty because the redirect '
                'is opened before the command word is resolved.)')
        else:
            cmp_lines('GENOUT', files['GENOUT'], EXPECT_GENOUT)
            # HIGH-BIT text: b'FOO?' would never match. Proven by
            # sabotage 2026-08-25 -- the diagnostic below was written
            # with a plain-ASCII literal and stayed silent through
            # the exact failure it exists to explain.
            if files['GENOUT'] != EXPECT_GENOUT and \
                    hitext('FOO?') in files['GENOUT']:
                failures.append(
                    '  GENOUT reports FOO? while IMPOUT shows FOO was '
                    'imported: import ran but did not set the exported '
                    'bit, so inheritance stops one generation deep. See '
                    "ENV_IMPORT's header -- an imported variable IS an "
                    'exported one.')

        # `find -exec` INHERITANCE. Separate from the sh chain above:
        # this one crosses a program that is not a shell, which is the
        # whole point -- the environment must survive a hop through
        # find, not just through another sh.
        if not isinstance(files['EXOUT'], bytes) or files['EXOUT'] == b'':
            failures.append(
                'EXOUT empty/missing -- find never ran the -exec child. '
                'That is a find/quoting failure, not an inheritance one: '
                "check that sh passed the quoted ';' through as a word.")
        else:
            cmp_lines('EXOUT', files['EXOUT'], EXPECT_EXOUT)
            if hitext('FOO?') in files['EXOUT']:
                failures.append(
                    '  EXOUT reports FOO? -- find ran the -exec child but '
                    'handed it no environment. That is the `stz '
                    'SPWN_ENVP` this fix removed: SC_SPAWN is the execve '
                    'shape and every caller had to opt IN, so the '
                    'environment stopped at the first -exec. See ENVPASS '
                    'in src/liba/env.s.')

        if failures:
            for failure in failures:
                print(f'[check-env] FAIL: {failure}', file=sys.stderr)
            return 1

        print('[check-env] PASS: with PATH unset sh found ECHO through '
              'PATHTAB; `export FOO` reached the spawned probe\'s getenv '
              'as FOO=EXPORTED; the UNexported BAR did not reach it at '
              'all (BAR?); the probe itself was only findable '
              'through the exported PATH; a NESTED sh that assigns '
              'nothing IMPORTED both FOO and PATH (it resolved EP at '
              'all, and echoed V=EXPORTED); and what it imported it '
              'handed on to its OWN child, while BAR stayed absent at '
              'both depths; and `find -exec` handed find\'s own '
              'environment to its child, across a program that is '
              'not a shell')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
