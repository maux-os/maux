#!/usr/bin/env python3
"""Boot and verify the v1 basic-system suite (`make check-v1-system`)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
from build_v1_system_image import (  # noqa: E402
    EXPECT_AFTERERR,
    EXPECT_GALPHA,
    EXPECT_GCLASS,
    EXPECT_GPIPE,
    EXPECT_MVTEXT,
    EXPECT_ABSCMD,
    EXPECT_CMT,
    EXPECT_CMT2,
    EXPECT_PSOUT,
    EXPECT_PWD1,
    EXPECT_PWD2,
    EXPECT_PWD3,
    EXPECT_PWD4,
    EXPECT_PWD5,
    EXPECT_SEED_FTYPE,
    EXPECT_RELCAT,
    EXPECT_DOTDOTCAT,
    EXPECT_CLAMPCAT,
    EXPECT_FAILCAT,
    EXPECT_BARECAT,
    EXPECT_SUBCAT,
    EXPECT_WCOUT,
    EXPECT_WCPIPE,
    EXPECT_ECHO2,
    EXPECT_EDITED,
    EXPECT_EMPTYE,
    EXPECT_INCAT,
    EXPECT_OUT1,
    EXPECT_OUT2,
    EXPECT_OVR,
    EXPECT_SEED,
)

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'v1_system.po')
VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')

R_SCRIPT_FD = 0x1200
R_SH_PID = 0x1201
R_WAIT_PID = 0x1202
R_SH_STATUS = 0x1203
R_OUT1_TRANS = 0x1205
R_OUT1_DATA = 0x1207
R_OUT2_TRANS = 0x1221
R_OUT2_DATA = 0x1223
R_DONE = 0x1290
R_ERR = 0x1291
R_STEP = 0x1292
# fork() smoke probe (src/test/shtestb.s, R_STEP 7): SYS_FORK is
# dispatched in the shipping image this gate boots.
R_FORK_A = 0x1293
R_FORK_ST = 0x1294
R_FORK_W = 0x1295


EXPECTED_FILES = {
    'OUT1': EXPECT_OUT1,
    'OUT2': EXPECT_OUT2,
    'ECHO2': EXPECT_ECHO2,
    'EMPTYE': EXPECT_EMPTYE,
    'CATSTD': EXPECT_INCAT,
    'CATFILE': EXPECT_SEED,
    'CATMISS': EXPECT_SEED,
    'COPY': EXPECT_SEED,
    'COPYCAT': EXPECT_SEED,
    'PIPE3': EXPECT_SEED,
    'OVR': EXPECT_OVR,
    'EDITED': EXPECT_EDITED,
    'GALPHA': EXPECT_GALPHA,
    'GCLASS': EXPECT_GCLASS,
    'GPIPE': EXPECT_GPIPE,
    'WCOUT': EXPECT_WCOUT,
    'WCPIPE': EXPECT_WCPIPE,
    'SUBCAT': EXPECT_SUBCAT,
    'MVSAME': EXPECT_MVTEXT,
    'MVDIR': EXPECT_MVTEXT,
    'PWD1': EXPECT_PWD1,
    'PWD2': EXPECT_PWD2,
    'RELCAT': EXPECT_RELCAT,
    'SUB/PWD3': EXPECT_PWD3,
    'SUB/DOTDOTCAT': EXPECT_DOTDOTCAT,
    'SUB/PWD4': EXPECT_PWD4,
    'SUB/CLAMPCAT': EXPECT_CLAMPCAT,
    'SUB/FAILCAT': EXPECT_FAILCAT,
    'SUB/PWD5': EXPECT_PWD5,
    'SUB/BARECAT': EXPECT_BARECAT,
    'SUB/PSOUT': EXPECT_PSOUT,
    'SUB/CMT1': EXPECT_CMT,
    'SUB/CMT2': EXPECT_CMT2,
    'SUB/ABSCMD': EXPECT_ABSCMD,
    'GNONE': b'',            # no line matches -- empty output
    'GMISS': b'',            # cannot open -- nothing on stdout
    'CATEDIT': EXPECT_EDITED,
    'AFTERERR': EXPECT_AFTERERR,
    'BADLS': b'',
}

# MVA/MVB are what separates a MOVE from a copy. The first version of mv
# copied correctly and failed to unlink (a wrong param_count on DESTROY), and
# this gate passed anyway because it only compared content. Assert the source
# is gone, both for the rename path and the copy+unlink path.
ABSENT_FILES = ['SEED', 'NOOUT', 'MISSING', 'TOOMANY', 'MVA', 'MVB']

LS_MUST_CONTAIN = [
    'PRODOS',
    'BIN',
    'MAUX.SYSTEM',
    'SCRIPT',
    'EDSCRIPT',
    'INCAT',
    'OUT1',
    'OUT2',
    'ECHO2',
    'EMPTYE',
    'CATSTD',
    'CATFILE',
    'CATMISS',
    'COPY',
    'COPYCAT',
    'PIPE3',
    'OVR',
    'EDLOG',
    'EDITED',
    'CATEDIT',
    'AFTERERR',
    'BADLS',
    'LIST1',
]

LS_MUST_NOT_CONTAIN = ['SEED', 'NOOUT', 'MISSING', 'TOOMANY']


def peek_aux1(client, addr, count=1):
    return client.call_tool('peek', {
        'addr': addr,
        'count': count,
        'bank': 'aux',
        'aux_bank': 1,
    })['bytes']


def lo_text(data):
    return ''.join(chr(b & 0x7F) for b in data)


def ls_names(data):
    return {name for name in lo_text(data).split('\r') if name}


def read_image_files(disk):
    prodos.mount(disk)
    root = f'/mnt/{VOL}'
    try:
        files = {}
        for name in sorted(set(EXPECTED_FILES) | {'LIST1', 'SUB/LISTBIN'}):
            try:
                files[name] = prodos.read(f'{root}/{name}')
            except FileNotFoundError:
                files[name] = None

        entries = list(prodos.scandir(root))
        present = {entry.name.upper() for entry in entries}
        # `cp` (SC_GFI-stats SRC, patches CREATE's file_type from the
        # result -- see src/bin/cp.s) is proved here: COPY was made by
        # `CP /mnt/MAUX/SEED /mnt/MAUX/COPY` from a $04 TXT source, so its
        # OWN directory entry must read $04 too, not cp's old
        # hardcoded $06 BIN. Byte-exact against the on-disk entry, not
        # a hand-computed value -- same posture as check_ls.py's GFI
        # assertions.
        copy_ftype = next(
            (e.type for e in entries if e.name.upper() == 'COPY'), None)
        absent = {}
        for name in ABSENT_FILES:
            try:
                prodos.read(f'{root}/{name}')
                absent[name] = False
            except FileNotFoundError:
                absent[name] = True

        return files, present, absent, copy_ftype
    finally:
        prodos.unmount(VOL)


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    # The shared utility volume (build/bin.po, volume UTILS): the userland
    # binaries live here, not on the boot volume, and the SCRIPT exports
    # PATH=/mnt/UTILS/BIN/ so the shell reaches them. Mounted as a second
    # SmartPort unit below.
    bin_disk = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        os.path.dirname(os.path.abspath(disk)), 'bin.po')
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}', file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make v1-system-image first',
              file=sys.stderr)
        return 2
    if not os.path.exists(bin_disk):
        print(f'error: {bin_disk} not found -- run make bin-image first',
              file=sys.stderr)
        return 2

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-v1-system] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk),
                                            'unit': 1})
        print(f'[check-v1-system] mount_disk -> {r}', file=sys.stderr)
        rb = client.call_tool('mount_disk', {'path': os.path.abspath(bin_disk),
                                             'unit': 2})
        print(f'[check-v1-system] mount_disk(bin) -> {rb}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        done = 0
        for _ in range(4000):
            client.call_tool('step', {'cycles': 200_000})
            done = peek_aux1(client, R_DONE)[0]
            if done in (0xAA, 0xEE):
                break

        err = peek_aux1(client, R_ERR)[0]
        step = peek_aux1(client, R_STEP)[0]
        fork_a = peek_aux1(client, R_FORK_A)[0]
        fork_st = peek_aux1(client, R_FORK_ST)[0]
        fork_w = peek_aux1(client, R_FORK_W)[0]
        script_fd = peek_aux1(client, R_SCRIPT_FD)[0]
        sh_pid = peek_aux1(client, R_SH_PID)[0]
        wait_pid = peek_aux1(client, R_WAIT_PID)[0]
        sh_status = peek_aux1(client, R_SH_STATUS)[0]
        t1 = peek_aux1(client, R_OUT1_TRANS, 2)
        trans1 = t1[0] | (t1[1] << 8)
        data1 = bytes(peek_aux1(client, R_OUT1_DATA, len(EXPECT_OUT1)))
        t2 = peek_aux1(client, R_OUT2_TRANS, 2)
        trans2 = t2[0] | (t2[1] << 8)
        data2 = bytes(peek_aux1(client, R_OUT2_DATA, len(EXPECT_OUT2)))

        print(f'[check-v1-system] done=${done:02X} err=${err:02X} '
              f'step=${step:02X} fork_a={fork_a} fork_st=${fork_st:02X} '
              f'fork_w={fork_w} script_fd={script_fd} sh_pid={sh_pid} '
              f'wait_pid={wait_pid} sh_status=${sh_status:02X} '
              f'trans1={trans1} data1={data1!r} '
              f'trans2={trans2} data2={data2!r}')

        failures = []
        if done != 0xAA:
            failures.append(f'test did not finish successfully '
                            f'(done=${done:02X}, err=${err:02X}, step={step})')
        if err != 0:
            failures.append(f'R_ERR expected $00, got ${err:02X}')
        if fork_a == 0:
            failures.append('fork() smoke probe: parent got pid 0 '
                            '(SYS_FORK not dispatched in this image?)')
        if fork_st != 0xC9:
            failures.append(f'fork() smoke probe: child exit status '
                            f'${fork_st:02X}, expected $C9')
        if fork_w != fork_a:
            failures.append(f'fork() smoke probe: wait reaped pid '
                            f'{fork_w}, fork returned {fork_a}')
        if script_fd == 0:
            failures.append('OPEN(SCRIPT) returned fd 0')
        if sh_pid == 0:
            failures.append('SPAWN(SH) returned pid 0')
        if wait_pid != sh_pid:
            failures.append(f'wait pid {wait_pid} != spawn pid {sh_pid}')
        if sh_status != 0:
            failures.append(f'sh exit status expected $00, got ${sh_status:02X}')
        if trans1 != len(EXPECT_OUT1) or data1 != EXPECT_OUT1:
            failures.append(f'OUT1 mismatch: trans={trans1}, data={data1!r}')
        if trans2 != len(EXPECT_OUT2) or data2 != EXPECT_OUT2:
            failures.append(f'OUT2 mismatch: trans={trans2}, data={data2!r}')

        if failures:
            for failure in failures:
                print(f'[check-v1-system] FAIL: {failure}', file=sys.stderr)
            return 1

        files, present, absent, copy_ftype = read_image_files(disk)
        for name, expected in EXPECTED_FILES.items():
            got = files[name]
            if got != expected:
                failures.append(f'{name} expected {expected!r}, got {got!r}')

        # cp file_type/aux_type preservation (task: "cp preserves file
        # type/auxtype"): COPY's directory entry must carry SEED's
        # real $04 TXT type, not cp's pre-SC_GFI hardcoded $06 BIN.
        if copy_ftype != EXPECT_SEED_FTYPE:
            failures.append(
                f'COPY file_type expected ${EXPECT_SEED_FTYPE:02X} '
                f'(cp should preserve SRC file_type via SC_GFI), '
                f'got {copy_ftype!r}')

        for name in ABSENT_FILES:
            if not absent[name]:
                failures.append(f'{name} should be absent after failure/rm path')

        names = ls_names(files['LIST1'] or b'')
        missing = sorted(name for name in LS_MUST_CONTAIN if name not in names)
        unexpected = sorted(name for name in LS_MUST_NOT_CONTAIN if name in names)
        # sh lives in /bin now (docs/VROOT.md); staged lowercase, and
        # ls decodes the GS/OS case flags, so it shows what was written
        binnames = ls_names(files['SUB/LISTBIN'] or b'')
        if 'sh' not in binnames:
            failures.append(f'LS /bin missing sh; got {sorted(binnames)}')
        if missing:
            failures.append(f'LIST1 missing names: {missing}; got {sorted(names)}')
        if unexpected:
            failures.append(f'LIST1 unexpectedly contains names: {unexpected}')

        # `present` is a scandir of the volume ROOT. A name with a '/' lives
        # in a subdirectory -- newer outputs go there because the root
        # directory is capped at 51 entries and this suite reached it -- and
        # its successful read above already proves it exists.
        for name in EXPECTED_FILES:
            if '/' in name:
                continue
            if name not in present:
                failures.append(f'{name} missing from ProDOS directory')

        if failures:
            for failure in failures:
                print(f'[check-v1-system] FAIL: {failure}', file=sys.stderr)
            return 1

        print('[check-v1-system] PASS: sh drove echo, cat, cp, rm, ed, '
              'grep, wc, mkdir, mv, pwd, ps and ls through redirection/pipes, '
              'real subdirectory, both mv mechanisms and cd changing what a '
              'RELATIVE path resolves to (docs/CD.md: plain relative cd, '
              '"cd ..", "cd ../.." clamped at the volume root, "cd NOSUCH" '
              'failing with the directory provably unchanged, and bare cd '
              'returning to the boot prefix -- each proved by a further '
              'relative read, not just what pwd echoes), and ps reporting '
              'the live process tree with its bank numbers; outputs and '
              'final ProDOS directory state matched byte-exact expectations')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
