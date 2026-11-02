#!/usr/bin/env python3
"""Build the ProDOS-hosted `tee`/`comm` acceptance-gate image (`make
check-comm`).

Companion to src/test/commtest.s / src/test/commtestb.s /
scripts/check_comm.py. Same shape as scripts/build_shlang_image.py: stage
input files + a script + the userland binaries onto a carrier volume copy,
boot a hardwired parent process that spawns `sh` (stdin redirected from the
script), and let `sh` itself drive `tee`/`comm` through real redirection
and a real pipeline (`CAT | TEE | WC`) -- checked byte-exact, host-side,
off the built image.

Every expected byte string below is THE CONTRACT (the task brief's own
column/tab/append rules), derived BY HAND -- never by running tee/comm and
recording their output, which would enshrine a bug as the spec.
scripts/check_comm.py imports these constants and never hand-computes an
expectation of its own.

CONCURRENT REAL-FILE BUDGET: inc/mm.mlibuf.equ's MLI_IOBUF_CNT is
4 -- a SYSTEM-WIDE cap on real ProDOS files open at once (pipes are exempt,
they never touch this pool; an unredirected stdout going to the console
device is exempt too, same reason). This harness's own parent process
holds /mnt/MAUX/SCRIPT open for `sh`'s whole run (a dup, shared with sh's own
fd 0), which permanently costs 1 of the 4 -- confirmed empirically (not
guessed) when an early draft's two-file tee case (`<` TEEIN, `>`
T2STDOUT, plus tee's own two named files = 4 MORE real opens on top of
SCRIPT's 1 = 5) failed SC_OPEN on its second named file every time. Every
script line below is written to need at most 3 real files of its own on
top of SCRIPT's permanent 1.
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
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXCOMM.SYSTEM')
SH_BIN = os.path.join(ROOT, 'build', 'sh.bin')
CAT_BIN = os.path.join(ROOT, 'build', 'cat.bin')
WC_BIN = os.path.join(ROOT, 'build', 'wc.bin')
TEE_BIN = os.path.join(ROOT, 'build', 'tee.bin')
COMM_BIN = os.path.join(ROOT, 'build', 'comm.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'comm.po')


def hitext(s):
    return bytes(ord(c) | 0x80 for c in s)


CR = bytes([0x8D])
TAB = bytes([0x89])
SP = hitext(' ')


def hilines(*lines):
    return b''.join(hitext(l) + CR for l in lines)


# ---------------------------------------------------------------------
# Staged input files.
# ---------------------------------------------------------------------
TEEIN_BYTES = hilines('ONE', 'TWO', 'THREE')      # 3 lines, 14 bytes
T3PRE_BYTES = hilines('PRE')                       # pre-staged -a target

CA_BYTES = hilines('APPLE', 'BANANA', 'CHERRY', 'DATE', 'FIG')
CB_BYTES = hilines('BANANA', 'CHERRY', 'EGG', 'FIG', 'GRAPE')
CADUP_BYTES = CA_BYTES                             # byte-for-byte copy
CAEMPTY_BYTES = b''                                # one file empty

# ---------------------------------------------------------------------
# The shell script `sh` runs from fd 0 (staged as /mnt/MAUX/SCRIPT).
# Flags LOWERCASE, command names UPPERCASE -- sh.s's own "CASE" ruling,
# matching every other build_*_image.py script here.
# ---------------------------------------------------------------------
SCRIPT_TEXT = (
    # tee -- one file.
    'TEE /mnt/MAUX/T1OUT < /mnt/MAUX/TEEIN > /mnt/MAUX/T1STDOUT\r'
    # tee -- two files. No `>` here (see header's io_buffer budget
    # note): stdout is unredirected (console device, costs no real
    # file), leaving room for SCRIPT + TEEIN + T2A + T2B (4, the
    # MLI_IOBUF_CNT ceiling exactly). stdout content is already
    # proven by the one-file and pipeline cases below.
    'TEE /mnt/MAUX/T2A /mnt/MAUX/T2B < /mnt/MAUX/TEEIN\r'
    # tee -a -- T3OUT is pre-staged with "PRE" below; -a must append
    # after it, not truncate it. Stdout is unaffected by -a.
    'TEE -a /mnt/MAUX/T3OUT < /mnt/MAUX/TEEIN > /mnt/MAUX/T3STDOUT\r'
    # tee in a real pipeline (task brief's own `LS | TEE LOG | WC`
    # shape) -- proves stdout keeps flowing downstream to WC while
    # T4OUT also gets the full copy.
    'CAT /mnt/MAUX/TEEIN | TEE /mnt/MAUX/T4OUT | WC > /mnt/MAUX/T4WC\r'
    # comm -- all three columns non-empty.
    'COMM /mnt/MAUX/CA /mnt/MAUX/CB > /mnt/MAUX/CFULL\r'
    # comm -1/-2/-3 -- each suppresses its own column only.
    'COMM -1 /mnt/MAUX/CA /mnt/MAUX/CB > /mnt/MAUX/CS1\r'
    'COMM -2 /mnt/MAUX/CA /mnt/MAUX/CB > /mnt/MAUX/CS2\r'
    'COMM -3 /mnt/MAUX/CA /mnt/MAUX/CB > /mnt/MAUX/CS3\r'
    # comm -12 -- clustered, both suppressed together.
    'COMM -12 /mnt/MAUX/CA /mnt/MAUX/CB > /mnt/MAUX/CS12\r'
    # comm -- identical files (everything column 3).
    'COMM /mnt/MAUX/CA /mnt/MAUX/CADUP > /mnt/MAUX/CIDENT\r'
    # comm -- one file empty (everything column 1).
    'COMM /mnt/MAUX/CA /mnt/MAUX/CAEMPTY > /mnt/MAUX/CEMPTY2\r'
    'EXIT\r'
)
SCRIPT_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                     for c in SCRIPT_TEXT)

# ---------------------------------------------------------------------
# EXPECTED outputs -- THE CONTRACT, derived by hand from the task brief,
# not from running tee/comm.
# ---------------------------------------------------------------------
EXPECT_T1OUT = TEEIN_BYTES
EXPECT_T1STDOUT = TEEIN_BYTES

EXPECT_T2A = TEEIN_BYTES
EXPECT_T2B = TEEIN_BYTES

EXPECT_T3OUT = T3PRE_BYTES + TEEIN_BYTES          # append, not truncate
EXPECT_T3STDOUT = TEEIN_BYTES                     # -a never touches stdout

EXPECT_T4OUT = TEEIN_BYTES
# wc on TEEIN: 3 lines (3 CR), 3 words ("ONE"/"TWO"/"THREE"), 14 bytes
# ("ONE\r"=4 + "TWO\r"=4 + "THREE\r"=6). No FILE arg (stdin via the
# pipe) -- wc.s's own REPORT prints no trailing name in that case.
EXPECT_T4WC = hitext('3') + SP + hitext('3') + SP + hitext('14') + CR


def commline(col, s, opt1=False, opt2=False):
    """opt1/opt2 = whether -1/-2 was GIVEN on this comm invocation --
    POSIX's adaptive <lead> (fixed 2026-09-13, comm.s's own OUT2/OUT3):
    column 2's lead is one <tab>, or the null string when -1 is
    selected; column 3's lead is two <tab>s, minus one for each of
    -1/-2 selected. A col-1 line never has a lead either way."""
    if col == 1:
        return hitext(s) + CR
    if col == 2:
        lead = b'' if opt1 else TAB
        return lead + hitext(s) + CR
    n = 2 - (1 if opt1 else 0) - (1 if opt2 else 0)  # col 3
    return TAB * n + hitext(s) + CR


# Merge order of CA (APPLE BANANA CHERRY DATE FIG) against
# CB (BANANA CHERRY EGG FIG GRAPE):
#   APPLE(1) BANANA(3) CHERRY(3) DATE(1) EGG(2) FIG(3) GRAPE(2)
EXPECT_CFULL = (
    commline(1, 'APPLE') + commline(3, 'BANANA') + commline(3, 'CHERRY') +
    commline(1, 'DATE') + commline(2, 'EGG') + commline(3, 'FIG') +
    commline(2, 'GRAPE')
)
EXPECT_CS1 = (                                     # -1: col1 omitted,
                                                   # AND -1 was given,
                                                   # so col2's lead is
                                                   # null and col3's
                                                   # drops to 1 tab
    commline(3, 'BANANA', opt1=True) + commline(3, 'CHERRY', opt1=True) +
    commline(2, 'EGG', opt1=True) + commline(3, 'FIG', opt1=True) +
    commline(2, 'GRAPE', opt1=True)
)
EXPECT_CS2 = (                                     # -2: col2 omitted,
                                                   # AND -2 was given,
                                                   # so col3's lead
                                                   # drops to 1 tab
    commline(1, 'APPLE') + commline(3, 'BANANA', opt2=True) +
    commline(3, 'CHERRY', opt2=True) + commline(1, 'DATE') +
    commline(3, 'FIG', opt2=True)
)
EXPECT_CS3 = (                                     # -3: col3 omitted;
                                                   # -1/-2 NOT given,
                                                   # col2's lead stays
                                                   # one tab
    commline(1, 'APPLE') + commline(1, 'DATE') + commline(2, 'EGG') +
    commline(2, 'GRAPE')
)
EXPECT_CS12 = (                                    # -12: only col3,
                                                   # both -1 AND -2
                                                   # given -- null lead
    commline(3, 'BANANA', opt1=True, opt2=True) +
    commline(3, 'CHERRY', opt1=True, opt2=True) +
    commline(3, 'FIG', opt1=True, opt2=True)
)
EXPECT_CIDENT = (                                  # identical files
    commline(3, 'APPLE') + commline(3, 'BANANA') + commline(3, 'CHERRY') +
    commline(3, 'DATE') + commline(3, 'FIG')
)
EXPECT_CEMPTY2 = (                                 # file2 empty
    commline(1, 'APPLE') + commline(1, 'BANANA') + commline(1, 'CHERRY') +
    commline(1, 'DATE') + commline(1, 'FIG')
)


def main():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXCOMM.SYSTEM'),
        (SH_BIN, 'sh userland binary'),
        (CAT_BIN, 'cat userland binary'),
        (WC_BIN, 'wc userland binary'),
        (TEE_BIN, 'tee userland binary'),
        (COMM_BIN, 'comm userland binary'),
    ]:
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
    with open(SH_BIN, 'rb') as f:
        shbin = f.read()
    with open(CAT_BIN, 'rb') as f:
        catbin = f.read()
    with open(WC_BIN, 'rb') as f:
        wcbin = f.read()
    with open(TEE_BIN, 'rb') as f:
        teebin = f.read()
    with open(COMM_BIN, 'rb') as f:
        commbin = f.read()

    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    try:                      # docs/VROOT.md: programs live in BIN
        prodos.mkdir(f'{root}/BIN')
    except FileExistsError:
        pass
    prodos.write(f'{root}/BIN/SH', shbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/CAT', catbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/WC', wcbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/TEE', teebin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/COMM', commbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)

    prodos.write(f'{root}/TEEIN', TEEIN_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    # Pre-stage the -a append target with existing content it must NOT
    # lose (uniq.s/sh.s's own append precedent).
    prodos.write(f'{root}/T3OUT', T3PRE_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)

    prodos.write(f'{root}/CA', CA_BYTES, file_type=0x04, aux_type=0x0000,
                 overwrite=True)
    prodos.write(f'{root}/CB', CB_BYTES, file_type=0x04, aux_type=0x0000,
                 overwrite=True)
    prodos.write(f'{root}/CADUP', CADUP_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/CAEMPTY', CAEMPTY_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)

    prodos.write(f'{root}/SCRIPT', SCRIPT_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.unmount(CARRIER_VOL)

    print(f'[build-comm] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-comm] kept={kept} removed={removed}')
    print(f'[build-comm] wrote MAUX.SYSTEM ({len(system)}B), SH '
          f'({len(shbin)}B), CAT ({len(catbin)}B), WC ({len(wcbin)}B), '
          f'TEE ({len(teebin)}B), COMM ({len(commbin)}B)')
    print(f'[build-comm] {OUT_IMG} ready '
          f'({os.path.getsize(OUT_IMG)} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
