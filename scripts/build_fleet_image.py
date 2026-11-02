#!/usr/bin/env python3
"""Build the ProDOS-hosted fleet (`cmp sort uniq tr od file`) acceptance-
gate image (`make check-fleet`).

Companion to src/test/fleettest.s / fleettestb.s / scripts/check_fleet.py.
Same shape as scripts/build_sh_image.py: stage input files + a script + the
userland binaries onto a carrier volume copy, boot a hardwired parent
process that spawns `sh` (stdin redirected from the script) for phase 1,
then spawns `cmp` directly twice for phase 2. Every expected OUTPUT byte
string lives in THIS module (the CONTRACT the task brief specified, not
anything derived by running the code) -- scripts/check_fleet.py imports
them and never hand-computes an expectation of its own.
"""
import os
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
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXFLEET.SYSTEM')
SH_BIN = os.path.join(ROOT, 'build', 'sh.bin')
CMP_BIN = os.path.join(ROOT, 'build', 'cmp.bin')
SORT_BIN = os.path.join(ROOT, 'build', 'sort.bin')
UNIQ_BIN = os.path.join(ROOT, 'build', 'uniq.bin')
TR_BIN = os.path.join(ROOT, 'build', 'tr.bin')
OD_BIN = os.path.join(ROOT, 'build', 'od.bin')
SLEEP_BIN = os.path.join(ROOT, 'build', 'sleep.bin')
# -- `echo` is staged for ONE reason: it is the only way a script can
# -- report `$?`, and sleep's refusal STATUS is what needs gating --
# -- check-textaudit already proves the refusal TEXT is stable. A
# -- refusal that exited 0 would let `sleep 5 && cmd` run cmd at once.
ECHO_BIN = os.path.join(ROOT, 'build', 'echo.bin')
FILE_BIN = os.path.join(ROOT, 'build', 'file.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'fleet.po')

#: An 800K ProDOS volume, not the 280-block carrier.  MEASURED: on
#: 2026-08-23 this image had exactly ZERO free blocks, and the symptom
#: was not a build failure -- the image built fine -- but a RUNTIME
#: `$48` (VOLUME FULL) three steps into the gate, surfacing as
#: `direct SPAWN(CMP) returned pid 0`.  A gate that reports a failed
#: spawn when what actually happened is a full disk costs an hour of
#: looking in the wrong place.
#:
#: It went to zero because S2's MKPATH dot-path fix added 158 bytes to
#: each of the seven binaries staged here, on top of a payload that was
#: already 50KB of deliberately oversized heap/width/compare cases.
#: Those cases exist to exceed old caps and will keep growing; the
#: volume has to grow with them.
#:
#: Recipe and argument from scripts/build_e2e_image.py's own
#: VOL_BLOCKS: a2til's `create` formats an EMPTY volume, so blocks 0
#: and 1 (the ProDOS boot loader, the one thing on the carrier that is
#: not a file) are spliced across verbatim; the loader's only job is to
#: find and load `PRODOS` out of the volume directory, which is
#: size-independent.
VOL_BLOCKS = 1600
BOOT_BYTES = 1024          # blocks 0 and 1: the ProDOS boot loader


def hitext(s):
    return bytes(ord(c) | 0x80 for c in s)


CR = bytes([0x8D])


def hilines(*lines):
    return b''.join(hitext(l) + CR for l in lines)


# ---------------------------------------------------------------------
# Staged input files (task brief's own CONTRACT -- text files are
# high-bit ASCII with $8D CR line endings, exactly like build_sh_image.py's
# SCRIPT_BYTES).
# ---------------------------------------------------------------------
SORTIN_BYTES = hilines('PEAR', 'APPLE', 'MANGO', 'APPLE', 'FIG')
UNIQIN_BYTES = hilines('AAA', 'AAA', 'BBB', 'CCC', 'CCC', 'CCC', 'AAA')
TRIN_BYTES = hilines('hello world')
ODIN_BYTES = bytes(range(0x12))          # $00..$11, 18 raw bytes
CMPA_BYTES = hilines('LINE ONE', 'LINE TWO', 'LINE THREE')
CMPB_BYTES = hilines('LINE ONE', 'LINE TXO', 'LINE THREE')
CMPC_BYTES = CMPA_BYTES                  # byte-for-byte copy

# ---------------------------------------------------------------------
# THE HEAP CASES (2026-08-22). Two inputs that the PREVIOUS `sort` could
# not handle at all, chosen to break each half of its fixed partition
# independently -- this is the gate for docs/STICKY.md sec 20's brk()
# conversion, and it is the whole measurable win.
#
#   BIGIN  4100 lines of one character. The old build capped the line
#          table at MAXLINES=4000 slots and would have exited 2 with
#          "sort: input too large" on line 4001 -- while its 35600-byte
#          arena held 8200 bytes, 77% empty. 4100 lines cost 8200 bytes
#          of text plus 8200 bytes of pointers on the heap.
#
#   WIDEIN 145 lines of 250 characters, 36395 bytes. The old build's
#          arena was ARENA_SIZE=35600 and would have exited 2 at byte
#          35601 -- while 3855 of its 4000 pointer slots, 7710 bytes,
#          sat unused.
#
# 250, not 900: when this case was written, liba's STRLEN walked with an
# 8-bit Y and `iny / bne`, so it returned 0 -- not 256 -- for any string
# of 256 characters or more, and PUTS wrote STRLEN's answer. A
# 900-character line was held by the heap correctly and printed as an
# EMPTY line, so 250 was chosen to keep every line inside the bug. That
# cap is FIXED as of 2026-08-22 (STRLEN is 16-bit, PUTS forwards its
# high byte), and the width it was hiding is now its own case: see
# LONGIN/LONGOUT below. 250 stays here because this case is about
# CAPACITY -- 145 x 250 = 36,395 bytes is what the pre-brk 35,600-byte
# arena could not hold, and changing the width would change the number
# this case exists to exceed.
#
# Both inputs are ALREADY SORTED. The shape being proved here is
# CAPACITY, which is decided in READALL as the bytes arrive, long before
# anything is compared; sorting order has its own byte-exact cases above,
# on data small enough to read. Pre-sorted input also keeps the shell
# sort's cost down to O(n log n) rather than spending emulator time
# re-proving a comparison this gate already checks.
#
# `-u` is what makes the expectations checkable: 4100 lines collapse to
# five distinct ones, 40 identical lines to one.
BIGIN_LINES = 4100
BIGIN_ALPHA = 'ABCDE'
BIGIN_RUN = BIGIN_LINES // len(BIGIN_ALPHA)          # 820 lines each
BIGIN_BYTES = b''.join(hitext(c) + CR
                       for c in BIGIN_ALPHA for _ in range(BIGIN_RUN))

WIDEIN_LINES = 145
WIDEIN_WIDTH = 250
WIDEIN_LINE = 'W' * WIDEIN_WIDTH
WIDEIN_BYTES = (hitext(WIDEIN_LINE) + CR) * WIDEIN_LINES

EXPECT_BIGOUT = hilines(*BIGIN_ALPHA)
EXPECT_WIDEOUT = hitext(WIDEIN_LINE) + CR

# ---------------------------------------------------------------------
# THE WIDTH CASE (2026-08-22): LONGIN/LONGOUT.
#
# Until today liba's STRLEN walked with an 8-bit Y and `iny / bne`, so
# it returned the length MODULO 256 -- 0 for a 256-byte string -- and
# PUTS wrote that answer straight into its MLI request_count. A
# 900-character line held perfectly by sort's heap printed as an EMPTY
# LINE. WIDEIN above is 250 characters wide for exactly that reason:
# the number was picked to stay INSIDE the bug rather than provoke it.
#
# Every string case in this tree was short, which is precisely why
# nothing caught it -- docs/CWD-BANK-BUG.md's recurring shape, a suite
# where every case shares an incidental property cannot see a bug that
# depends on that property. So this input varies width deliberately and
# straddles both boundaries that exist:
#
#     1   the ordinary short line -- must not regress
#   254   comfortably inside the old 8-bit walk
#   255   the last width the old walk got right, exactly
#   256   THE BUG: old STRLEN returned 0, so PUTS wrote NOTHING
#   257   one past -- and old STRLEN returned 0 for this too. It
#         did not wrap to `length mod 256`; it fell out of the
#         loop AT the wrap and stopped measuring, so every width
#         from 256 up measured the same zero. Measured, not
#         reasoned: under the restored 8-bit walk this file's own
#         gate produced a 519-byte LONGOUT whose tail was six
#         bare CRs -- all six wide lines empty, not 0/1/255/...
#   511   \
#   512    | the 512-byte ProDOS block / stdio BUFSIZ boundary, which
#   513   /  PUTS crosses in ONE unbuffered SC_WRITE
#   900   the width from the original report (docs/STICKY.md sec 23)
#
# Each line's FIRST byte is its sort key ('A'..'I', ascending with
# width) and its LAST byte repeats that key, with a 0-9 ruler between:
# ordering is therefore decided on byte 0, and any short write shows up
# at the tail. Deciding on byte 0 is not laziness -- STRCMP still walks
# with an 8-bit Y and would call two 900-byte lines EQUAL if they first
# differed past byte 255. That cap is real, is documented in
# src/liba/string.s, and is NOT fixed here; this case is about PUTS's
# width, so it is kept clear of STRCMP's.
#
# Staged SHUFFLED, so `sort` has to permute: a build that merely copied
# its input through would fail this case.
# ---------------------------------------------------------------------
LONG_KEYS = 'ABCDEFGHI'
LONG_WIDTHS = [1, 254, 255, 256, 257, 511, 512, 513, 900]


def longline(key, width):
    if width == 1:
        return key
    ruler = ''.join(str(i % 10) for i in range(width - 2))
    return key + ruler + key


LONG_LINES = [longline(k, w) for k, w in zip(LONG_KEYS, LONG_WIDTHS)]
LONGIN_ORDER = [3, 8, 0, 5, 2, 7, 1, 6, 4]
LONGIN_BYTES = hilines(*(LONG_LINES[i] for i in LONGIN_ORDER))
EXPECT_LONGOUT = hilines(*LONG_LINES)

# ---------------------------------------------------------------------
# THE COMPARE CASE (2026-08-22): TWININ/TWINOUT/TWINUOUT.
#
# LONGIN above is built so every line differs at BYTE 0 -- deliberately,
# to keep the width case clear of STRCMP's own 255-byte cap while that
# cap was still there. This case is the exact complement: operands that
# are IDENTICAL through byte 255 and differ only after it, which is the
# input LONGIN was constructed to avoid.
#
# The old STRCMP walked with `iny / bne` and fell out of the loop at the
# 255->0 wrap straight into its own :eq, so it reported EQUAL for any
# two strings sharing a 255-byte prefix. That was reachable, and not
# theoretically: sort holds whole file lines in a brk() heap with NO
# per-line cap of any kind (src/bin/sort.s READALL/CHKROOM charge bytes
# against the table floor, never against a line length), so `sort` is a
# program that routinely holds 900-byte lines -- LONGIN proves it.
#
# EQUAL IS AN ACTION, not just an ordering. sort -u's OUTPUT loop does
# `jsr STRCMP / beq :oskip` (sort.s:544), and :oskip jumps past PUTS. So
# a wrongly-equal verdict does not merely mis-order -- it SILENTLY
# DELETES a distinct line from the output. That is why this case runs
# `sort` and `sort -u` over the same input: they fail differently.
#
# Three groups, ordered among themselves by byte 0 so group order is
# decided where no cap can reach, and within each group by the byte
# named below:
#
#   C   differs at byte 254 -- INSIDE the old 8-bit walk. This is the
#       CONTROL: it must pass on the broken code too. A gate whose
#       every case goes red proves the harness broke, not the routine.
#   T   differs at byte 256 -- the first byte the old walk could not
#       reach. Wrong ORDER out of `sort`, and a DROPPED LINE out of
#       `sort -u`.
#   E   two byte-identical 300-char lines. The widening must not turn
#       "genuinely equal past 255" into "unequal": `sort -u` still has
#       to collapse these two to one. Without this case a routine that
#       simply never returned 0 would pass the T case.
#
# Staged shuffled, and E appears twice.
# ---------------------------------------------------------------------
TWIN_WIDTH = 300


def twinline(key, difpos, difbyte):
    """A TWIN_WIDTH-char line: key at byte 0, a 0-9 ruler after it,
    and one byte replaced at difpos to separate it from its twin."""
    body = [key] + [str(i % 10) for i in range(1, TWIN_WIDTH)]
    body[difpos] = difbyte
    return ''.join(body)


TWIN_C1 = twinline('C', 254, 'A')       # control: inside the old walk
TWIN_C2 = twinline('C', 254, 'B')
TWIN_T1 = twinline('T', 256, 'A')       # THE BUG: past the wrap
TWIN_T2 = twinline('T', 256, 'B')
TWIN_E1 = twinline('E', 256, 'A')       # genuinely equal, twice

TWININ_BYTES = hilines(TWIN_T2, TWIN_E1, TWIN_C2,
                       TWIN_T1, TWIN_E1, TWIN_C1)
EXPECT_TWINOUT = hilines(TWIN_C1, TWIN_C2, TWIN_E1, TWIN_E1,
                         TWIN_T1, TWIN_T2)
EXPECT_TWINUOUT = hilines(TWIN_C1, TWIN_C2, TWIN_E1, TWIN_T1, TWIN_T2)

# ---------------------------------------------------------------------
# The shell script `sh` runs from fd 0 (staged as /mnt/MAUX/SCRIPT).
# Flags LOWERCASE, command names UPPERCASE -- sh.s's own "CASE" ruling
# (docs/SH-DESIGN.md) and ls.s's own precedent for flag case.
# ---------------------------------------------------------------------
SCRIPT_TEXT = (
    'SORT /mnt/MAUX/SORTIN > /mnt/MAUX/SORTOUT\r'
    'SORT -r /mnt/MAUX/SORTIN > /mnt/MAUX/SORTROUT\r'
    'SORT -u /mnt/MAUX/SORTIN > /mnt/MAUX/SORTUOUT\r'
    'UNIQ /mnt/MAUX/UNIQIN > /mnt/MAUX/UNIQOUT\r'
    'UNIQ -c /mnt/MAUX/UNIQIN > /mnt/MAUX/UNIQCOUT\r'
    'UNIQ -d /mnt/MAUX/UNIQIN > /mnt/MAUX/UNIQDOUT\r'
    'UNIQ -u /mnt/MAUX/UNIQIN > /mnt/MAUX/UNIQUOUT\r'
    'TR a-z A-Z < /mnt/MAUX/TRIN > /mnt/MAUX/TROUT\r'
    'TR -d aeiou < /mnt/MAUX/TRIN > /mnt/MAUX/TRDOUT\r'
    'OD /mnt/MAUX/ODIN > /mnt/MAUX/ODOUT\r'
    'FILE /mnt/MAUX/SORTIN /mnt/MAUX/ODIN > /mnt/MAUX/FILEOUT\r'
    'SORT /mnt/MAUX/SORTIN > /mnt/MAUX/COMBO\r'
    'UNIQ /mnt/MAUX/UNIQIN >> /mnt/MAUX/COMBO\r'
    'UNIQ /mnt/MAUX/UNIQIN /mnt/MAUX/UNIQFOUT\r'
    'SORT -u /mnt/MAUX/BIGIN > /mnt/MAUX/BIGOUT\r'
    'SORT -u /mnt/MAUX/WIDEIN > /mnt/MAUX/WIDEOUT\r'
    'SORT /mnt/MAUX/LONGIN > /mnt/MAUX/LONGOUT\r'
    'SORT /mnt/MAUX/TWININ > /mnt/MAUX/TWINOUT\r'
    'SORT -u /mnt/MAUX/TWININ > /mnt/MAUX/TWINUOUT\r'
    # -- `sleep` REFUSING, and its STATUS. check-textaudit proves the
    # -- refusal is deterministic and its text immutable; it cannot
    # -- prove the status is right, because a pair-comparison is happy
    # -- with any status so long as both runs agree. This harness links
    # -- no timer either, so SYS_TICK reports mode 0 and the contract
    # -- is exit 1 -- never a poll on a counter that cannot advance.
    '/bin/SLEEP 1\r'
    'ECHO SLP$? >> /mnt/MAUX/SLEEPOUT\r'
    'EXIT\r'
)
SCRIPT_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                     for c in SCRIPT_TEXT)

# ---------------------------------------------------------------------
# EXPECTED phase-1 outputs -- THE CONTRACT (task brief), not derived by
# running the code. If a command disagrees, the command is wrong.
# ---------------------------------------------------------------------
EXPECT_SORTOUT = hilines('APPLE', 'APPLE', 'FIG', 'MANGO', 'PEAR')

# `sleep` on a machine with no tick source: refuses, status 1.
EXPECT_SLEEPOUT = hilines('SLP1')
EXPECT_SORTROUT = hilines('PEAR', 'MANGO', 'FIG', 'APPLE', 'APPLE')
EXPECT_SORTUOUT = hilines('APPLE', 'FIG', 'MANGO', 'PEAR')

# uniq default: collapse ADJACENT runs only -- AAA,AAA / BBB / CCC,CCC,CCC
# / AAA (trailing AAA is a SEPARATE run from the leading one -- teeth for
# "adjacent, not global" dedup).
EXPECT_UNIQOUT = hilines('AAA', 'BBB', 'CCC', 'AAA')

# -c: count right-aligned in a 5-char field (high-bit ASCII, same as the
# rest of the line -- PRCNT's pad/digits go through PUTC like everything
# else), one space, then the line.
def cntline(n, s):
    return hitext(f'{n:5d}') + hitext(' ') + hitext(s) + CR


EXPECT_UNIQCOUT = (
    cntline(2, 'AAA') + cntline(1, 'BBB') + cntline(3, 'CCC') +
    cntline(1, 'AAA')
)
EXPECT_UNIQDOUT = hilines('AAA', 'CCC')       # -d: runs with length > 1
EXPECT_UNIQUOUT = hilines('BBB', 'AAA')       # -u: runs with length == 1

EXPECT_TROUT = hilines('HELLO WORLD')
EXPECT_TRDOUT = hilines('hll wrld')

# od: offset %04X, then up to 16 space-separated two-digit hex bytes (no
# trailing space), then CR; final line is the trailing offset alone. All of
# it is high-bit ASCII (PUTC-emitted, same as every other line here), and
# the hex digits are UPPERCASE: od.s's PRHEXNIB (used for BOTH the offset
# field via PRHEX4 and the byte field via PRHEXBYTE -- one shared routine,
# so the two cannot disagree in case) maps a nibble >= 10 to $C1.."A" and
# up, the same "adc #$C1" convention file.s's own HEXPRINT/PRHEXDIG and
# ls.s's HEXPRINT already use everywhere else in this codebase. Matches
# the task brief's own "%04X" (uppercase) format spec for the offset; the
# brief's inline "0f" example reads as prose-casual lowercase, not a
# byte-exact override of that spec or of the established house convention.
SP = hitext(' ')


def hexrow(offset, byte_range):
    fields = SP.join(hitext(f'{b:02X}') for b in byte_range)
    return hitext(f'{offset:04X}') + SP + fields + CR


EXPECT_ODOUT = (
    hexrow(0x0000, range(0x00, 0x10)) +
    hexrow(0x0010, range(0x10, 0x12)) +
    hitext('0012') + CR
)

EXPECT_FILEOUT = hilines('/mnt/MAUX/SORTIN: ascii text', '/mnt/MAUX/ODIN: binary')

# COMBO: SORTOUT's content followed by UNIQOUT's content (via `>>`).
EXPECT_COMBO = EXPECT_SORTOUT + EXPECT_UNIQOUT

# UNIQFOUT -- the same collapse as UNIQOUT, but produced through
# uniq's OWN second positional operand instead of a shell `>`. That
# distinction is the entire point of this case and it is easy to
# mistake for a duplicate:
#
#   `UNIQ in > out`  -- SH opens the file; uniq writes to fd 1, which
#                       EXIT's SIO_FLUSHALL always flushes. FCLOSE
#                       never runs.
#   `UNIQ in out`    -- UNIQ opens and closes the file itself, so the
#                       buffer must be flushed by FCLOSE before the
#                       close, or the tail is lost.
#
# Added 2026-08-21 after the flush was deliberately removed from
# FCLOSE and this gate stayed GREEN: every uniq line then used `>`,
# so nothing in the tree exercised the path FCLOSE exists for. Without
# this case there is no evidence FCLOSE flushes.
EXPECT_UNIQFOUT = EXPECT_UNIQOUT

# ---------------------------------------------------------------------
# EXPECTED phase-2 (`cmp`, spawned directly) results.
# ---------------------------------------------------------------------
# CMPA/CMPC identical -> exit 0, no output at all (fd 1 captured).
EXPECT_CMP1_STATUS = 0
EXPECT_CMP1_STDERR = b''

# CMPA/CMPB differ. "LINE ONE"+CR is 9 bytes; "LINE T" (6 more) matches,
# so the W/X mismatch is the 16th byte, on line 2 (one CR seen so far).
EXPECT_CMP2_STATUS = 1
# The differ message is on STDOUT (POSIX cmp, fixed 2026-09-13); the
# harness captures fd 1. The constant keeps its historical name.
EXPECT_CMP2_STDERR = (
    hitext('/mnt/MAUX/CMPA') + bytes([0xA0]) + hitext('/mnt/MAUX/CMPB') +
    hitext(' differ: char 16, line 2') + CR
)


def main():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXFLEET.SYSTEM'),
        (SH_BIN, 'sh userland binary'),
        (CMP_BIN, 'cmp userland binary'),
        (SORT_BIN, 'sort userland binary'),
        (UNIQ_BIN, 'uniq userland binary'),
        (TR_BIN, 'tr userland binary'),
        (OD_BIN, 'od userland binary'),
        (SLEEP_BIN, 'sleep userland binary'),
        (ECHO_BIN, 'echo userland binary'),
        (FILE_BIN, 'file userland binary'),
    ]:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2

    prodos.create(OUT_IMG, name=CARRIER_VOL, blocks=VOL_BLOCKS)
    with open(CARRIER_IMG, 'rb') as f:
        boot = f.read(BOOT_BYTES)
    if len(boot) != BOOT_BYTES or boot == bytes(BOOT_BYTES):
        print(f'error: {CARRIER_IMG} has no boot block to copy',
              file=sys.stderr)
        return 2
    with open(OUT_IMG, 'r+b') as f:
        f.write(boot)
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
    with open(CMP_BIN, 'rb') as f:
        cmpbin = f.read()
    with open(SORT_BIN, 'rb') as f:
        sortbin = f.read()
    with open(UNIQ_BIN, 'rb') as f:
        uniqbin = f.read()
    with open(TR_BIN, 'rb') as f:
        trbin = f.read()
    with open(OD_BIN, 'rb') as f:
        odbin = f.read()
    with open(SLEEP_BIN, 'rb') as f:
        sleepbin = f.read()
    with open(ECHO_BIN, 'rb') as f:
        echobin = f.read()
    with open(FILE_BIN, 'rb') as f:
        filebin = f.read()

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
    prodos.write(f'{root}/BIN/CMP', cmpbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/SORT', sortbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/UNIQ', uniqbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/TR', trbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/ECHO', echobin, file_type=0x06,
                 aux_type=0x0800, overwrite=True)
    prodos.write(f'{root}/BIN/SLEEP', sleepbin, file_type=0x06,
                 aux_type=0x0800, overwrite=True)
    prodos.write(f'{root}/BIN/OD', odbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/FILE', filebin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)

    prodos.write(f'{root}/SORTIN', SORTIN_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/UNIQIN', UNIQIN_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/TRIN', TRIN_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/ODIN', ODIN_BYTES, file_type=0x06,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/CMPA', CMPA_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/CMPB', CMPB_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/CMPC', CMPC_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/BIGIN', BIGIN_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/WIDEIN', WIDEIN_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/LONGIN', LONGIN_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/TWININ', TWININ_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/SCRIPT', SCRIPT_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.unmount(CARRIER_VOL)

    print(f'[build-fleet] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-fleet] kept={kept} removed={removed}')
    print(f'[build-fleet] wrote MAUX.SYSTEM ({len(system)}B), SH '
          f'({len(shbin)}B), CMP ({len(cmpbin)}B), SORT ({len(sortbin)}B), '
          f'UNIQ ({len(uniqbin)}B), TR ({len(trbin)}B), OD ({len(odbin)}B), '
          f'FILE ({len(filebin)}B)')
    print(f'[build-fleet] heap cases: BIGIN {BIGIN_LINES} lines '
          f'({len(BIGIN_BYTES)}B -- old MAXLINES cap was 4000), WIDEIN '
          f'{WIDEIN_LINES}x{WIDEIN_WIDTH} ({len(WIDEIN_BYTES)}B -- old '
          f'ARENA_SIZE was 35600)')
    print(f'[build-fleet] width case: LONGIN {len(LONG_LINES)} lines of '
          f'{LONG_WIDTHS} chars ({len(LONGIN_BYTES)}B, shuffled) -- every '
          f'line of 256+ printed EMPTY before STRLEN went 16-bit')
    print(f'[build-fleet] compare case: TWININ 6 lines x {TWIN_WIDTH} '
          f'chars ({len(TWININ_BYTES)}B) -- pairs differing at byte 254 '
          f'(control), 256 (the bug) and not at all; before STRCMP went '
          f'16-bit the 256 pair compared EQUAL and `sort -u` dropped one')
    vol = prodos.Volume(OUT_IMG, readonly=True)
    try:
        free, total = vol.free_blocks, vol.total_blocks
    finally:
        vol.close()
    print(f'[build-fleet] {OUT_IMG} ready '
          f'({os.path.getsize(OUT_IMG)} bytes), '
          f'{free} of {total} blocks free')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
