#!/usr/bin/env python3
"""Build the ProDOS-hosted v1 basic-system suite image.

Companion to src/test/shtest.s / scripts/check_v1_system.py. This reuses the
same shell launcher as check-sh, but stages a broader script and seed files.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CARRIER_IMG = os.environ.get('PRODOS_CARRIER_IMG',
                             os.path.join(ROOT, 'vendor', 'prodos-basic.po'))
CARRIER_VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')
KERNEL_BIN = os.environ.get('PRODOS_KERNEL_BIN',
                            os.path.join(ROOT, 'vendor', 'ProDOS-2.4.bin'))
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXSH.SYSTEM')
OUT_IMG = os.path.join(ROOT, 'build', 'v1_system.po')

# VOLUME DIRECTORY CEILING -- 51 entries here, and it fails SILENTLY.
#
# Two separate facts, and it is worth not confusing them (an earlier version
# of this comment did):
#
#   * The SIZE is a formatter convention, not a format rule. A ProDOS
#     directory is a linked list of blocks -- each carries prev/next pointers,
#     first prev = 0, last next = 0 (P8 TRM B.2.1) -- so nothing in the format
#     fixes the count. Formatters allocate 4 because that is sensible for
#     280-block 5.25" media: 51 files for 2 KB of overhead. a2til does the
#     same (prodos.format_image hardcodes range(4)), and our carrier image
#     inherited it from whatever wrote it.
#   * ProDOS will not EXTEND the volume directory at runtime, however big it
#     was formatted. Subdirectories it grows on demand. The evidence is that
#     $49 "volume directory full" exists as an error distinct from $48
#     "volume full" -- if the root could grow you would only ever see $48.
#
# So the ceiling is inherited at format time and then immovable. This suite
# sat at exactly 51: the next three outputs never appeared, and every command
# after them failed too, which reads like a shell bug and is not one. New test
# outputs go in /mnt/MAUX/SUB/, which grows.
UTIL_BINS = [
    ('sh', os.path.join(ROOT, 'build', 'sh.bin')),
    ('echo', os.path.join(ROOT, 'build', 'echo.bin')),
    ('cat', os.path.join(ROOT, 'build', 'cat.bin')),
    ('ls', os.path.join(ROOT, 'build', 'ls.bin')),
    ('cp', os.path.join(ROOT, 'build', 'cp.bin')),
    ('rm', os.path.join(ROOT, 'build', 'rm.bin')),
    ('ed', os.path.join(ROOT, 'build', 'ed.bin')),
    ('grep', os.path.join(ROOT, 'build', 'grep.bin')),
    ('wc', os.path.join(ROOT, 'build', 'wc.bin')),
    ('mkdir', os.path.join(ROOT, 'build', 'mkdir.bin')),
    ('mv', os.path.join(ROOT, 'build', 'mv.bin')),
    ('pwd', os.path.join(ROOT, 'build', 'pwd.bin')),
    ('ps', os.path.join(ROOT, 'build', 'ps.bin')),
]


def hitext(s):
    return bytes(ord(c) | 0x80 for c in s)


def script_bytes(text):
    return bytes((ord(c) | 0x80) if c != '\r' else 0x8D for c in text)


SCRIPT_TEXT = (
    # The userland binaries live on the shared UTILS volume (build/bin.po,
    # mounted as a second unit), not on this boot volume -- see
    # build_bin_image.py for why. Point this shell's PATH at them; every
    # bare command below (ECHO, CAT, CP, ...) resolves through it. The
    # global default PATH (src/liba/pathtab.s) is deliberately left alone,
    # so gates that stage their own /bin are unaffected.
    'PATH=/mnt/UTILS/BIN/\r'
    'EXPORT PATH\r'
    'ECHO HELLO > /mnt/MAUX/OUT1\r'
    'ECHO A | CAT > /mnt/MAUX/OUT2\r'
    'ECHO HI BYE > /mnt/MAUX/ECHO2\r'
    'ECHO > /mnt/MAUX/EMPTYE\r'
    'CAT < /mnt/MAUX/INCAT > /mnt/MAUX/CATSTD\r'
    'CAT /mnt/MAUX/SEED > /mnt/MAUX/CATFILE\r'
    'CAT /mnt/MAUX/MISSING /mnt/MAUX/SEED > /mnt/MAUX/CATMISS\r'
    'CP /mnt/MAUX/SEED /mnt/MAUX/COPY\r'
    'CAT /mnt/MAUX/COPY > /mnt/MAUX/COPYCAT\r'
    'CAT /mnt/MAUX/COPY | CAT | CAT > /mnt/MAUX/PIPE3\r'
    'CAT /mnt/MAUX/COPY | CAT | CAT | CAT > /mnt/MAUX/TOOMANY\r'
    'ECHO LONGER > /mnt/MAUX/OVR\r'
    'ECHO S > /mnt/MAUX/OVR\r'
    'ED < /mnt/MAUX/EDSCRIPT > /mnt/MAUX/EDLOG\r'
    'CAT /mnt/MAUX/EDITED > /mnt/MAUX/CATEDIT\r'
    'RM /mnt/MAUX/SEED /mnt/MAUX/MISSING\r'
    'CP /mnt/MAUX/MISSING /mnt/MAUX/NOOUT\r'
    'ECHO AFTER > /mnt/MAUX/AFTERERR\r'
    'LS EXTRA > /mnt/MAUX/BADLS\r'
    'GREP ^alpha /mnt/MAUX/GREPIN > /mnt/MAUX/GALPHA\r'
    'GREP ^[bg] /mnt/MAUX/GREPIN > /mnt/MAUX/GCLASS\r'
    'CAT /mnt/MAUX/GREPIN | GREP ^alpha > /mnt/MAUX/GPIPE\r'
    'GREP zzz /mnt/MAUX/GREPIN > /mnt/MAUX/GNONE\r'
    'GREP ^alpha /mnt/MAUX/MISSING > /mnt/MAUX/GMISS\r'
    'WC /mnt/MAUX/GREPIN > /mnt/MAUX/WCOUT\r'
    'CAT /mnt/MAUX/GREPIN | WC > /mnt/MAUX/WCPIPE\r'
    'MKDIR /mnt/MAUX/SUB\r'
    'ECHO INSIDE > /mnt/MAUX/SUB/F\r'
    'CAT /mnt/MAUX/SUB/F > /mnt/MAUX/SUBCAT\r'
    'ECHO MOVE ME > /mnt/MAUX/MVA\r'
    'MV /mnt/MAUX/MVA /mnt/MAUX/MVB\r'
    'CAT /mnt/MAUX/MVB > /mnt/MAUX/MVSAME\r'
    'MV /mnt/MAUX/MVB /mnt/MAUX/SUB/MVC\r'
    'CAT /mnt/MAUX/SUB/MVC > /mnt/MAUX/MVDIR\r'
    'PWD > /mnt/MAUX/PWD1\r'
    'CD /mnt/MAUX/SUB\r'
    'PWD > /mnt/MAUX/PWD2\r'
    'CAT F > /mnt/MAUX/RELCAT\r'
    'CD ..\r'
    'PWD > /mnt/MAUX/SUB/PWD3\r'
    'CAT OUT1 > /mnt/MAUX/SUB/DOTDOTCAT\r'
    'CD ../..\r'
    'PWD > /mnt/MAUX/SUB/PWD4\r'
    'CAT ECHO2 > /mnt/MAUX/SUB/CLAMPCAT\r'
    'CD NOSUCH\r'
    'CAT ECHO2 > /mnt/MAUX/SUB/FAILCAT\r'
    'CD SUB\r'
    'CD\r'
    'PWD > /mnt/MAUX/SUB/PWD5\r'
    'CAT OUT1 > /mnt/MAUX/SUB/BARECAT\r'
    'CD /mnt/MAUX/\r'
    '# a comment line, and a trailing one below\r'
    'ECHO KEPT > /mnt/MAUX/SUB/CMT1\r'
    'ECHO KEPT2 > /mnt/MAUX/SUB/CMT2  # trailing comment\r'
    '/mnt/UTILS/BIN/ECHO ABSPATH > /mnt/MAUX/SUB/ABSCMD\r'
    'PS > /mnt/MAUX/SUB/PSOUT\r'
    'LS /bin > /mnt/MAUX/SUB/LISTBIN\r'
    'LS > /mnt/MAUX/LIST1\r'
    'EXIT\r'
)
SCRIPT_BYTES = script_bytes(SCRIPT_TEXT)

EDSCRIPT_TEXT = (
    'a\r'
    'ed alpha\r'
    'BANK item\r'
    '.\r'
    '2s/BANK/&X/\r'
    'w /mnt/MAUX/EDITED\r'
    'q\r'
)
EDSCRIPT_BYTES = script_bytes(EDSCRIPT_TEXT)

EXPECT_OUT1 = hitext('HELLO') + bytes([0x8D])
EXPECT_OUT2 = hitext('A') + bytes([0x8D])
EXPECT_ECHO2 = hitext('HI BYE') + bytes([0x8D])
EXPECT_EMPTYE = bytes([0x8D])
EXPECT_INCAT = hitext('stdin from cat') + bytes([0x8D])

# GREPIN: a tiny corpus with known matches, so the expectations below are
# literal rather than computed. Lines chosen to exercise a literal match, a
# character class, an anchor and a non-match in one pass.
GREPIN_LINES = ['alpha one', 'beta two', 'alpha three', 'gamma four']
EXPECT_GREPIN = b''.join(hitext(l) + bytes([0x8D]) for l in GREPIN_LINES)
EXPECT_GALPHA = b''.join(hitext(l) + bytes([0x8D])
                         for l in GREPIN_LINES if l.startswith('alpha'))
EXPECT_GCLASS = b''.join(hitext(l) + bytes([0x8D])
                         for l in GREPIN_LINES if l[0] in 'bg')
EXPECT_GPIPE = EXPECT_GALPHA

# wc over GREPIN: 4 CRs, 8 words, 42 bytes. Fields are separated by one
# space; the name column is the argument as typed, and is absent for stdin.
EXPECT_WCOUT = hitext('4 8 42 /mnt/MAUX/GREPIN') + bytes([0x8D])
EXPECT_WCPIPE = hitext('4 8 42') + bytes([0x8D])
# mkdir makes a REAL ProDOS subdirectory -- proven by writing a file inside
# it and reading it back out, not by trusting the create call's status.
EXPECT_SUBCAT = hitext('INSIDE') + bytes([0x8D])
# mv exercises BOTH mechanisms:
#   MVSAME -- same directory, so MLI RENAME (atomic, no data moved)
#   MVDIR  -- into the subdirectory, which ProDOS RENAME cannot do, so
#             mv must fall back to copy+unlink. Same content either way.
EXPECT_MVTEXT = hitext('MOVE ME') + bytes([0x8D])
# cd/pwd. The prefix starts as the boot volume, so pwd reports /mnt/MAUX/ first;
# after `cd /mnt/MAUX/SUB` it reports /mnt/MAUX/SUB/. The REAL test is the third
# one: a RELATIVE path resolving inside the new directory proves cd changed
# name resolution, not just a string pwd echoes back.
EXPECT_PWD1 = hitext('/mnt/MAUX/') + bytes([0x8D])
EXPECT_PWD2 = hitext('/mnt/MAUX/SUB/') + bytes([0x8D])
EXPECT_RELCAT = hitext('INSIDE') + bytes([0x8D])
# docs/CD.md: `cd ..` from /mnt/MAUX/SUB lands back at /mnt/MAUX/ -- proven the
# same way PWD2/RELCAT proved plain relative cd, not just by trusting pwd's
# own string: a RELATIVE read (OUT1, a root-level file) has to resolve
# there too. `cd ../..` one level above the volume root has nowhere to go
# and CLAMPS at the root (Unix `cd /..` == `/`), not an error -- same
# PWD/relative-read pair proves it landed in the same place as one `cd ..`.
# `cd NOSUCH` must fail leaving the directory untouched: proven by a THIRD
# relative read of the same root file after the failed cd, expected
# byte-identical to the pre-failure one. Bare `cd` returns to the boot
# prefix (the volume root here) -- proven the same way once more from
# inside SUB.
EXPECT_PWD3 = hitext('/mnt/MAUX/') + bytes([0x8D])
EXPECT_DOTDOTCAT = hitext('HELLO') + bytes([0x8D])
EXPECT_PWD4 = hitext('/mnt/MAUX/') + bytes([0x8D])
EXPECT_CLAMPCAT = hitext('HI BYE') + bytes([0x8D])
EXPECT_FAILCAT = hitext('HI BYE') + bytes([0x8D])
EXPECT_PWD5 = hitext('/mnt/MAUX/') + bytes([0x8D])
EXPECT_BARECAT = hitext('HELLO') + bytes([0x8D])
# ps runs as a child of sh, so BOTH must appear. sh is pid 2 (pid 1 is the
# init/harness process); ps gets the next free slot. Banks are physical aux
# bank numbers -- the column that makes this maux's ps and not a generic one.
# The whole table, pinned. The script is deterministic, so this is:
#   pid 1  init/harness, SLEEPING
#   pid 2  sh, SLEEPING -- blocked in wait() on its child
#   pid 6  ps itself, RUNNING, child of sh (earlier commands were
#          already reaped, so their slots read UNUSED)
# COMMAND (PS-ARGS): pid 1 was made by the kernel (`[init]`); the script
# typed SH and PS in capitals, and argv[0] is what was typed.
# The parent chain 0 <- 1 <- 2 <- 6 and those states are the actual
# assertion; BANK is the physical aux bank each process occupies.
# Was pid 5/bank 05 before task #15: the sticky cache's first
# cacheable spawn lazily claims ONE bank from the same pool
# (docs/STICKY.md section 2), shifting every later process's
# bank -- and pid tracks bank -- by one. A deliberate, documented
# shift, not drift.
EXPECT_CMT = hitext('KEPT') + bytes([0x8D])
EXPECT_CMT2 = hitext('KEPT2') + bytes([0x8D])
EXPECT_ABSCMD = hitext('ABSPATH') + bytes([0x8D])
EXPECT_PSOUT = b''.join(hitext(l) + bytes([0x8D]) for l in [
    ' PID S BANK PPID COMMAND',
    '   1 S   01    0 [init]',
    '   2 S   02    1 SH',
    '   6 R   06    2 PS',
])
EXPECT_SEED = bytes(((i * 37 + 11) & 0xFF) for i in range(768))
# SEED is written $04 TXT below (not the $06 BIN CREATE default) --
# `CP /mnt/MAUX/SEED /mnt/MAUX/COPY` in SCRIPT_TEXT is what proves cp
# preserves file_type: COPY's directory entry must also read $04,
# not the hardcoded $06 cp used before SC_GFI landed (2026-08-19).
EXPECT_SEED_FTYPE = 0x04
EXPECT_EDITED = (
    hitext('ed alpha') + bytes([0x8D]) +
    hitext('BANKX item') + bytes([0x8D])
)
EXPECT_OVR = hitext('S') + bytes([0x8D])
EXPECT_AFTERERR = hitext('AFTER') + bytes([0x8D])


def main():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXSH.SYSTEM'),
    ] + [(path, f'{name} userland binary') for name, path in UTIL_BINS]:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2

    shutil.copyfile(CARRIER_IMG, OUT_IMG)
    prodos.mount(OUT_IMG)
    root = f'/mnt/{CARRIER_VOL}'
    removed = []
    kept = []

    def rm_recursive(path, entry):
        if entry.is_dir():
            for child in list(prodos.scandir(path)):
                rm_recursive(f'{path}/{child.name}', child)
            prodos.rmdir(path)
        else:
            prodos.remove(path)

    for entry in list(prodos.scandir(root)):
        if entry.name.upper() == 'PRODOS':
            kept.append(entry.name)
            continue
        rm_recursive(f'{root}/{entry.name}', entry)
        removed.append(entry.name)

    with open(KERNEL_BIN, 'rb') as f:
        kernel = f.read()
    with open(SYS_BIN, 'rb') as f:
        system = f.read()

    sh_path = dict(UTIL_BINS)['sh']
    with open(sh_path, 'rb') as f:
        sh = f.read()

    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    # SH stays on the boot volume -- the kernel image spawns it by absolute
    # path (/bin/sh) before any PATH search exists.
    try:                      # docs/VROOT.md: programs live in BIN
        prodos.mkdir(f'{root}/BIN')
    except FileExistsError:
        pass
    prodos.write(f'{root}/BIN/sh', sh, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    # The OTHER userland binaries used to live in /bin and cost this
    # volume ~78 blocks -- enough that a one-block kernel growth starved the
    # last file the test wrote (LIST1, 2026-09-04): "bin bytes are volume
    # bytes". They now live ONCE on the shared UTILS volume (build/bin.po,
    # scripts/build_bin_image.py), which the gate mounts as a second unit;
    # the SCRIPT exports PATH=/mnt/UTILS/BIN/ so the shell finds them there.
    # /bin stays as an EMPTY directory so the volume-directory-ceiling
    # design (root capped, subdirs grow) and the gate's LS assertion both
    # still hold.

    prodos.write(f'{root}/SCRIPT', SCRIPT_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/EDSCRIPT', EDSCRIPT_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/GREPIN', EXPECT_GREPIN, file_type=0x04,
                 aux_type=0)
    prodos.write(f'{root}/INCAT', EXPECT_INCAT, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/SEED', EXPECT_SEED, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.unmount(CARRIER_VOL)

    print(f'[build-v1-system] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-v1-system] kept={kept} removed={removed}')
    print(f'[build-v1-system] wrote MAUX.SYSTEM ({len(system)} bytes), '
          f'sh ({len(sh)} bytes); other utils on shared UTILS volume '
          f'(build/bin.po)')
    print(f'[build-v1-system] wrote SCRIPT ({len(SCRIPT_BYTES)} bytes), '
          f'EDSCRIPT ({len(EDSCRIPT_BYTES)} bytes), INCAT '
          f'({len(EXPECT_INCAT)} bytes), SEED ({len(EXPECT_SEED)} bytes)')
    print(f'[build-v1-system] {OUT_IMG} ready '
          f'({os.path.getsize(OUT_IMG)} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
