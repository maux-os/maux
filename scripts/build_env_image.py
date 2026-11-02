#!/usr/bin/env python3
"""Build the ProDOS-hosted ENVIRONMENT gate image (`make check-env`).

Companion to src/test/envtest.s / envtestb.s / src/test/envprobe.s /
scripts/check_env.py. Same shape as scripts/build_sh_image.py: stage the
script and the binaries onto a carrier volume copy, boot a hardwired
parent process that spawns `sh` with fd 0 redirected from that script,
and let `sh` write every observable to a real ProDOS file that is then
read back host-side, byte-exact, off the built image.

WHAT THE SCRIPT PROVES, and why it is one script (docs/SYSCALL.md item
13c's own "the gate that matters"):

  1. `ECHO ... > /mnt/MAUX/PATHOUT` runs BEFORE anything sets PATH, so the
     only way ECHO can be found is sh's built-in PATHTAB. PATHTAB is
     the DEFAULT now, not dead code, and this line is what says so.
  2. FOO is assigned and EXPORTED; BAR is assigned and NOT exported.
  3. PATH is set to /mnt/MAUX/TOOLS/ -- a directory that appears in NO
     built-in path -- and exported.
  4. `EP FOO BAR PATH > /mnt/MAUX/ENVOUT` is a BARE command word that can
     only resolve through PATH, and the probe it runs reports each name
     as "NAME=VALUE" or "NAME?".

So ENVOUT carries both halves of the inheritance gate in one file --
FOO arrived, BAR did not -- and the fact that ENVOUT exists at all is
the PATH resolution. A partial implementation that exported everything
fails on BAR; one that exported nothing fails on FOO; one that ignored
PATH never runs EP at all.

Every expected byte string here is THE CONTRACT, not something derived
by running the code -- scripts/check_env.py imports these and never
computes an expectation of its own.
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
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXENV.SYSTEM')
SH_BIN = os.path.join(ROOT, 'build', 'sh.bin')
ECHO_BIN = os.path.join(ROOT, 'build', 'echo.bin')
PROBE_BIN = os.path.join(ROOT, 'build', 'envprobe.bin')
FIND_BIN = os.path.join(ROOT, 'build', 'find.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'env.po')

# The probe lives HERE and nowhere else: a directory named by no
# built-in path entry, so a bare `EP` is unresolvable unless PATH is
# honoured.
TOOLS_DIR = 'TOOLS'
PROBE_NAME = 'EP'
PATH_VALUE = '/mnt/MAUX/TOOLS/'

SCRIPT_TEXT = (
    'ECHO DEFAULTPATH > /mnt/MAUX/PATHOUT\r'
    'FOO=EXPORTED\r'
    'EXPORT FOO\r'
    'BAR=LOCAL\r'
    'PATH=' + PATH_VALUE + '\r'
    'EXPORT PATH\r'
    'EP FOO BAR PATH > /mnt/MAUX/ENVOUT\r'
    # 5. A NESTED SHELL, invoked by ABSOLUTE path on purpose: PATH is
    #    /mnt/MAUX/TOOLS/ by now and SH is not in it, and an absolute
    #    command word bypasses PATH entirely (RSLV_PTH_STG checks the
    #    leading '/' before BUILD_PATH is ever reached). Using a bare
    #    `SH` here would test path resolution a second time instead of
    #    testing import.
    '/bin/sh < /mnt/MAUX/IMPSCR\r'
    # 6. `find -exec` INHERITANCE. find's -exec child used to get a
    #    NULL envp -- the environment stopped dead at the first
    #    -exec. TOOLS holds exactly one file (EP itself), so this
    #    runs the probe exactly once. The ';' is QUOTED because sh
    #    would otherwise eat a bare one as a command separator --
    #    src/bin/find.s's own header says -exec 'only works today
    #    spawned directly by a gate harness (no shell involved)',
    #    which is true of a BARE semicolon and not of a quoted one.
    #    CMD must be an absolute pathname: find does no PATH search
    #    (that is sh's job), so /mnt/MAUX/TOOLS/EP, not EP.
    # 6. `find -exec` INHERITANCE -- the environment crossing a
    #    program that is NOT a shell. TOOLS holds exactly one file
    #    (EP itself), so the probe runs exactly once.
    #
    #    THE ';' IS QUOTED. src/bin/find.s's header says -exec "only
    #    works today spawned directly by a gate harness (no shell
    #    involved)" -- true of a BARE semicolon, which sh eats as a
    #    command separator, and NOT true of a quoted one. Measured
    #    2026-08-25: `ECHO A ';' B` prints "A ; B", so sh already
    #    passes it through as a word and this gate needs no new
    #    quoting support.
    #
    #    NO '{}' HERE, though find supports it: check-find already
    #    proves substitution, and leaving it out keeps this file to
    #    ONE line whose only subject is the environment.
    #
    #    CMD IS A BARE WORD, and that is the second thing this line
    #    proves since 2026-08-26. find -exec PATH-resolves it
    #    (src/liba/pathres.s, the execvp shape) using PATH from the
    #    ENVIRONMENT -- which only exists here because PATH was
    #    exported six lines up. EP lives ONLY in /mnt/MAUX/TOOLS/, so
    #    a bare `EP` running at all means the resolver read the
    #    child's environment. It used to require the absolute path.
    "/bin/FIND /mnt/MAUX/TOOLS -type f -exec EP FOO ';' > /mnt/MAUX/EXOUT\r"
    # 7. THE BUILTIN-TAG REGRESSION (docs/SPAWN-BANK7-CRASH.md).
    #    `EGONE` is a bare word that does not exist anywhere, so
    #    sh's BUILD_PATH exhausts its prefixes and spawns the WORD
    #    ITSELF (:exhausted copies SH_CMDWORD verbatim). That is
    #    the only way a path whose first character is a letter
    #    ever reaches the kernel -- every PATH-resolved candidate
    #    starts with '/'.
    #
    #    'E' is this harness's builtin-image tag for SIMG_EXIT, a
    #    ONE-BYTE image containing a lone `rts`. Until 2026-08-26
    #    the kernel matched builtin tags on the FIRST CHARACTER
    #    ONLY, so this spawned SIMG_EXIT: entered at LOAD_BASE
    #    with a fresh empty stack, its `rts` returns to $0000 and
    #    runs zero page as BRK opcodes into KRN_BRK_TRAP.
    #
    #    Before KBRK this case FAILED AS A TIMEOUT: the regression
    #    is a user BRK and that parked the machine. Now the child
    #    dies of SIGTRAP and the script carries on, so the verdict
    #    is the BLT line below: BLT127 correct, BLT133 the regression
    #    (check_env.py names it). It stays LAST in the script so
    #    every other observable is already written to disk first.
    'EGONE\r'
    # 8. THE CWD-SEARCH REGRESSION (docs/ANACHRONISMS.md A11).
    #    PATH is /mnt/MAUX/TOOLS/ and `echo` lives in /mnt/MAUX/, so a
    #    BARE `ECHO` is not on the search path -- but the prefix IS
    #    /mnt/MAUX/, so until 2026-08-26 sh spawned the bare word and
    #    ProDOS resolved it against the prefix and RAN IT. That is a
    #    current-directory search maux does not have and does not
    #    want, on a kernel that does not check file types.
    #
    #    CWDLEAK MUST NOT APPEAR. Its absence is the assertion; the
    #    status line after it proves the shell carried on. Note this
    #    needs a command that EXISTS in the cwd -- the EGONE case
    #    above cannot catch it, because a word that resolves nowhere
    #    fails identically whether or not the cwd is searched.
    #    ABSOLUTE, and the reason is the fix this case guards.
    #    PATH is /mnt/MAUX/TOOLS/ by now and `echo` is not in it, so a
    #    bare ECHO resolved ONLY through sh spawning the bare word,
    #    which ProDOS then resolved against the prefix -- the
    #    accidental cwd search closed 2026-08-26. This gate was
    #    leaning on the bug it exists to catch.
    "/bin/ECHO BLT$? >> /mnt/MAUX/BLTOUT\r"
    'ECHO CWDLEAK >> /mnt/MAUX/CWDOUT\r'
    "/bin/ECHO CWD$? >> /mnt/MAUX/CWDOUT\r"
    'EXIT\r'
)
SCRIPT_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                     for c in SCRIPT_TEXT)

# The nested shell's own script -- the IMPORT half (V7 sh(1): "the
# shell scans the environment and creates a parameter for each name
# found"). It never assigns or exports anything: every variable it can
# see, it can only have imported.
#
#   IMPOUT proves the import reached the nested shell's own TABLE.
#   `V=$FOO` and not `[$FOO]` because '[' opens a glob character class
#   AND is the `test` builtin's alias -- a marker with no metacharacter
#   in it keeps this line a test of the environment and nothing else.
#
#   GENOUT proves the import is TRANSITIVE, which is the half a
#   plausible implementation gets wrong. V7's second sentence is
#   "executed commands inherit the same environment", so an imported
#   name must reach a GRANDchild without anyone re-exporting it. That
#   only happens if import sets the exported bit.
# ECHO is invoked ABSOLUTELY here for the same reason SH is above,
# and the first draft of this script proved why: with a bare
# `ECHO`, the nested shell searched the IMPORTED PATH
# (/mnt/MAUX/TOOLS/), where echo does not live, and IMPOUT came back
# created-but-empty. That was import working, reported as a
# failure. Absolute words bypass PATH, so this line now tests the
# environment and nothing else -- EP below is the one deliberate
# PATH-resolution probe.
IMPSCRIPT_TEXT = (
    '/bin/ECHO V=$FOO > /mnt/MAUX/IMPOUT\r'
    'EP FOO BAR PATH > /mnt/MAUX/GENOUT\r'
    'EXIT\r'
)
IMPSCRIPT_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                        for c in IMPSCRIPT_TEXT)


def hitext(s):
    return bytes(ord(c) | 0x80 for c in s)


CR = bytes([0x8D])

# echo's own contract: the arguments, one CR.
EXPECT_PATHOUT = hitext('DEFAULTPATH') + CR

# envprobe's own contract, in argument order: NAME=VALUE for a variable
# that reached the child, NAME? for one that did not. BAR is the half a
# partial implementation passes.
EXPECT_ENVOUT = (
    hitext('FOO=EXPORTED') + CR +
    hitext('BAR?') + CR +
    hitext('PATH=' + PATH_VALUE) + CR
)

# The nested shell's echo of a variable it can only have IMPORTED. An
# import that does not happen at all yields 'V=' and a CR -- present
# but empty, which is why the marker is here: an empty file and an
# empty value would otherwise be the same observation.
EXPECT_IMPOUT = hitext('V=EXPORTED') + CR

# The GRANDCHILD's view, and the reason this gate has teeth. Three
# distinct broken implementations are told apart by IMPOUT+GENOUT
# together:
#
#   no import at all        IMPOUT 'V=' AND GENOUT MISSING ENTIRELY --
#                           PATH was never imported either, so the
#                           nested shell cannot resolve EP.
#   import without the      IMPOUT correct, GENOUT exists (PATH_SRC
#   exported bit            reads sh's TABLE, so EP still resolves)
#                           but reads FOO? BAR? PATH? -- nothing was
#                           handed on.
#   import that exports     IMPOUT correct, GENOUT correct, and BAR is
#   everything              WRONGLY present as BAR=LOCAL... except BAR
#                           never entered the nested shell at all, so
#                           this one is caught one level up instead:
#                           BAR? is asserted at BOTH depths.
# `find -exec`'s child, and the reason this line is here at all:
# BEFORE 2026-08-25 src/bin/find.s wrote `stz SPWN_ENVP` and the
# child got NOTHING, so this file would read 'FOO?'. find now calls
# ENVPASS -- the execv/execvp shape, which is what a real find(1)
# reaches exec through.
#
# ONE line, derived from envprobe's own documented behaviour rather
# than from running it: the probe reports one line per NAME argument,
# a hit as NAME=VALUE and a miss as NAME?, and its argv here is just
# [FOO] because the template carries no '{}'.
EXPECT_EXOUT = hitext('FOO=EXPORTED') + CR

# THE BUILTIN-TAG REGRESSION (docs/SPAWN-BANK7-CRASH.md). `EGONE`
# resolves nowhere, so sh spawns the bare WORD, and its first
# character is this harness's SIMG_EXIT tag. The contract is that
# the kernel treats it as a PATHNAME -- a builtin tag must be the
# WHOLE path -- so the spawn fails cleanly and sh reports "not
# found". Before the fix this did not produce a wrong byte: it
# crashed. The status is 127 since KFIX10 item 3 (POSIX; it was 1):
# the row still tells a clean refusal from BLT133, the SIGTRAP death.
EXPECT_BLTOUT = hitext('BLT127') + CR

# The cwd search, closed. A bare `ECHO` off PATH must NOT run, so
# CWDLEAK is absent and only the status line is here (127, "not
# found", since KFIX10 item 3; it was 1).
EXPECT_CWDOUT = hitext('CWD127') + CR

EXPECT_GENOUT = (
    hitext('FOO=EXPORTED') + CR +
    hitext('BAR?') + CR +
    hitext('PATH=' + PATH_VALUE) + CR
)


def main():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXENV.SYSTEM'),
        (SH_BIN, 'sh userland binary'),
        (ECHO_BIN, 'echo userland binary'),
        (PROBE_BIN, 'envprobe test binary'),
        (FIND_BIN, 'find userland binary'),
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
    with open(ECHO_BIN, 'rb') as f:
        echobin = f.read()
    with open(PROBE_BIN, 'rb') as f:
        probebin = f.read()
    with open(FIND_BIN, 'rb') as f:
        findbin = f.read()

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
    prodos.write(f'{root}/BIN/ECHO', echobin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/FIND', findbin, file_type=0x06,
                 aux_type=0x0800, overwrite=True)
    prodos.mkdir(f'{root}/{TOOLS_DIR}')
    prodos.write(f'{root}/{TOOLS_DIR}/{PROBE_NAME}', probebin,
                 file_type=0x06, aux_type=0x0800, overwrite=True)
    prodos.write(f'{root}/SCRIPT', SCRIPT_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/IMPSCR', IMPSCRIPT_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.unmount(CARRIER_VOL)

    print(f'[build-env] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-env] kept={kept} removed={removed}')
    print(f'[build-env] wrote MAUX.SYSTEM ({len(system)} bytes), '
          f'SH ({len(shbin)} bytes), ECHO ({len(echobin)} bytes), '
          f'{TOOLS_DIR}/{PROBE_NAME} ({len(probebin)} bytes), '
          f'SCRIPT ({len(SCRIPT_BYTES)} bytes), '
          f'IMPSCR ({len(IMPSCRIPT_BYTES)} bytes)')
    print(f'[build-env] {OUT_IMG} ready ({os.path.getsize(OUT_IMG)} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
