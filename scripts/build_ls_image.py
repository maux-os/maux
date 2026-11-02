#!/usr/bin/env python3
"""Build the ProDOS-hosted `ls` acceptance-gate image (`make check-ls`).

Companion to src/test/lstest.s / scripts/check_ls.py -- same shape as
scripts/build_catread_image.py (a real userland binary spawned from disk
with a fd redirected to a ProDOS file, byte-exact comparison), extended to
FOUR spawns (plain listing / -l dir listing / -l single-file GET_FILE_INFO
stat / nonexistent-path error) instead of catread's two.

House rule (HACKING.md): disk images via a2til only. Case-flag names go
through a2til's public write_file() (it already reads AND writes GS/OS case
flags off the mixed-case Python string -- see docs/USERLAND.md, "What
mixed-case cost us to support: almost nothing"), so NO manual case-flag
patching is needed here. What a2til's PUBLIC API cannot produce -- a
mod_date/mod_time of all zero, or a deliberately Extended/invalid time
(hour > 23) -- IS patched directly into the built entry's raw bytes below,
via the same low-level FileDescEnt object a2til's own rename()/set_file_info
use internally (a2til.prodos.Volume._find_entry(..., write=True)). This is
the "PATCH the ... word directly in the entry bytes" escape hatch the task
brief anticipates; both patches and why they're needed are called out at
the point they happen.

EVERY expected-output constant scripts/check_ls.py asserts against comes
from this module's compute_expected() (see its docstring for why that's a
function reading the final image back, not a build()-time constant the way
build_catread_image.py's CATSRC_BYTES is) -- it reads the actual on-disk
entry bytes (blocks_used in particular: a sapling file's blocks_used is
data_blocks + 1 index block, not a simple EOF/512 rounding, and hand-
deriving it risked exactly that off-by-one) and the FILES table/format
helpers below, so check_ls.py never hand-computes an expectation twice.
"""
import os
import shutil
import sys
from datetime import datetime

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CARRIER_IMG = os.environ.get('PRODOS_CARRIER_IMG',
                             os.path.join(ROOT, 'vendor', 'prodos-basic.po'))
CARRIER_VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')
KERNEL_BIN = os.environ.get('PRODOS_KERNEL_BIN',
                            os.path.join(ROOT, 'vendor', 'ProDOS-2.4.bin'))
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXLSTEST.SYSTEM')
LS_BIN = os.path.join(ROOT, 'build', 'ls.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'ls.po')

LSDIR = f'/mnt/{CARRIER_VOL}/LSDIR'

# -- The known tree, staged in LSDIR. Every field here is the SAME literal
# scripts/check_ls.py's expectations are built from -- see compute_expected()
# below. Chosen to cover, per file, deliverable 1's four requirements simultaneously
# rather than with four separate one-purpose files:
#   (a) distinct types, including the $F1 oddball forcing the "$xx hex" path
#   (b) sizes straddling the 512-byte block boundary (a seedling and two
#       saplings)
#   (c) one mixed-case name -- 'bigFile.BIN' deliberately starts with a
#       LOWERCASE letter, not just a mixed-case tail: a sort that
#       case-DECODES the name first and then compares it case-SENSITIVELY
#       (ASCII lowercase > uppercase) would shove it to the end of the
#       listing instead of its correct case-insensitive slot between
#       AAATYPE.TXT and ODDTYPE -- see the teeth plan.
#   (d) the three date behaviors: one known-legacy date (reused on two
#       entries), one zero date, one deliberately Extended/invalid time
# DELIBERATELY NOT ALPHABETICAL: files are created in this on-disk
# order, so directory order != sorted order and a sort-less ls cannot
# pass by accident (teeth run 2026-08-19: with alphabetical creation,
# the no-sort sabotage sailed through green). compute_expected() sorts
# independently, so this order can change freely as long as it stays
# unsorted.
FILES = [
    # name,           file_type, size, date_kind
    ('SYSFILE',       0xFF,      1500, 'legacy'),
    ('bigFile.BIN',   0x06,      700,  'zero'),
    ('AAATYPE.TXT',   0x04,      300,  'legacy'),
    ('ODDTYPE',       0xF1,      50,   'invalid'),
]

# The file stat'd via SYS_GFI in run 3 (lstest.s's SPAWN_LS3) -- a sapling
# (>512 bytes), so its blocks_used (2 data blocks + 1 index block = 3) is
# the value that would be WRONG if ls's -l file-arg path printed EOF/512
# rounded instead of the real GET_FILE_INFO blocks_used field.
GFI_TARGET = 'bigFile.BIN'

# The literal argv text lstestb.s passes as run 3's path argument
# (ARG_FILE) -- ALSO the expected NAME column for that line. Confirmed by
# reading the ls.s present in this tree (the parallel rewrite):
# PRINTARGFILE's :long path does `lda ARGIDX / jsr GETARG / ... / jsr PUTS`
# for NAME -- GET_FILE_INFO has no name field to decode case flags from
# (see that file's own header note), so it echoes the ARGUMENT'S OWN PATH
# TEXT verbatim, not a basename. An earlier draft of this gate assumed a
# re-derived basename here; that would have been a gate bug (asserting
# something the implementation never promised) -- fixed by using the full
# argv path as the source of truth for both what's staged and what's
# expected back, and noted in the report as the reconciliation this cross-
# check earned.
GFI_ARGV_PATH = '/mnt/MAUX/LSDIR/bigFile.BIN'

# The known legacy date patched onto 'legacy'-kind entries: 1986-09-15
# 14:30, encoded in the layout the task brief specifies (date word =
# year<<9|month<<5|day, time word = hour<<8|minute) -- year value 86, which
# maux's pivot-78 rule (docs/PRODOS-VERSION.md) and a2til's own TN#28
# pivot-40 encoder AGREE decode to 1986 (86 is in both rules' un-ambiguous
# 78..99 legacy-year band).
LEGACY_DT = datetime(1986, 9, 15, 14, 30)

# The deliberately Extended/invalid time patched onto the 'invalid' entry.
#
# NOT the docs' own captured ProDOS-2.5-stamped bytes ($97E4, "hour 151,
# minute 228") -- those were the first choice here, until cross-checking
# against the ls.s ALREADY IN THIS TREE (the parallel rewrite) found its
# PRINTDATE masks the hour/minute bytes with #$1F/#$3F BEFORE comparing to
# 24/60 (src/bin/ls.s, ~line 905-920), instead of range-checking the raw
# byte the way docs/PRODOS-VERSION.md's own ruling reads ("a legacy date
# has hour<=23 and minute<=59" -- the whole byte, which is what lets the
# check see 2.5's Extended format reusing the time word's spare/reserved
# bits at all). Under that masking, $97 & $1F = 23 and $E4 & $3F = 36 --
# BOTH look valid, so the real captured bytes would NOT reliably print '-'
# there. That masking-vs-raw question is a genuine finding to reconcile
# (see the task report), not something this gate should silently work
# around OR quietly depend on either answer to. So the bytes actually used
# below are docs/PRODOS-VERSION.md's own captured ProDOS 2.5 Extended
# stamp ($8CB3/$97E4): hour byte $97=151, which a RAW hour<=23 check
# rejects but a masked ($97&$1F=23) check would wrongly accept -- ls.s's
# PRINTDATE originally masked before comparing and this exact artifact
# slipped through as "valid"; the raw compare is now the implementation
# AND this gate's teeth for it. minute byte $E4=228 is equally invalid raw.
INVALID_DATE_BYTES = bytes([0xB3, 0x8C, 0xE4, 0x97])  # date_lo,date_hi,minute,hour


def hitext(s):
    return bytes(ord(c) | 0x80 for c in s)


CR = bytes([0x8D])


def type_field(file_type):
    mnemonic = {0x04: 'TXT', 0x06: 'BIN', 0x0F: 'DIR', 0xFF: 'SYS',
                0xFC: 'BAS'}.get(file_type)
    return mnemonic if mnemonic else f'${file_type:02X}'


def decode_maux_date(raw4):
    """4 raw entry bytes (date_lo,date_hi,minute,hour) -> 'YYYY-MM-DD HH:MM'
    or None (zero / Extended-invalid), per docs/PRODOS-VERSION.md's ruling:
    validate hour<=23 && minute<=59 first: it passes -> legacy, pivot-78;
    it fails -> Extended, caller shows '-'."""
    date_lo, date_hi, minute, hour = raw4
    word = date_lo | (date_hi << 8)
    if word == 0 and minute == 0 and hour == 0:
        return None
    if hour > 23 or minute > 59:
        return None
    day = word & 0x1F
    month = (word >> 5) & 0x0F
    year = (word >> 9) & 0x7F
    year += 1900 if year >= 78 else 2000
    return f'{year:04d}-{month:02d}-{day:02d} {hour:02d}:{minute:02d}'


def date_field(raw4):
    s = decode_maux_date(raw4)
    return s if s is not None else '-'.ljust(16)


def eof_field(eof):
    return f'{eof:8d}'


def blocks_field(blocks_used):
    return f'{blocks_used}b'.rjust(8)


def format_l_line(file_type, size_field_str, raw4, name):
    return f'{type_field(file_type)} {size_field_str} {date_field(raw4)} {name}'


def _patch_date(entry, raw4):
    """Write raw4 (date_lo,date_hi,minute,hour) straight into the entry's
    last_mod field ($21-$24), bypassing a2til's Date descriptor -- see
    module header for why (zero and hour>23 cannot round-trip through a
    Python datetime, which is all set_file_info()/the Date descriptor
    accept)."""
    entry._mem[0x21:0x25] = raw4


NOSUCH_PATH = '/mnt/MAUX/NOSUCH'


def compute_expected(image_path=OUT_IMG):
    """Read back the FINAL, already-built image (read-only) and derive every
    expected-output constant from its actual bytes.

    Deliberately NOT computed once at build time and stashed on a module
    global: `make ls-image` and `make check-ls` are two separate `python3`
    processes (see the Makefile fragment), so any module-level state
    build_ls_image.py's build() sets would be gone by the time check_ls.py
    imports this module. Recomputing from the persisted .po file instead
    means check_ls.py's expectations come from the SAME bytes the emulator
    will actually read -- a stronger check than trusting an in-process
    cache would have been, not just a workaround for the process boundary.
    """
    prodos.mount(image_path, readonly=True)
    vol = prodos._session.get(prodos._foldname(CARRIER_VOL))
    root = f'/mnt/{CARRIER_VOL}'
    dir_blockno = vol._resolve_dir(LSDIR[len(root):] or '/')

    built = {}
    for name, _file_type, _size, _date_kind in FILES:
        entry = vol._find_entry(dir_blockno, name.upper())
        assert entry is not None, f'{name} missing from {image_path}'
        raw4 = bytes(entry._mem[0x21:0x25])
        built[name] = dict(file_type=entry.type, eof=entry.eof,
                            blocks_used=entry.blocks_used, raw4=raw4,
                            display_name=name)
    prodos.unmount(CARRIER_VOL)

    # Sort order: case-insensitive by DISPLAY name (docs/USERLAND.md: names
    # are stored uppercase, case is presentation-only -- but the CORRECT
    # sort key is still case-insensitive, so a naive case-sensitive sort of
    # the decoded display string is a distinct, catchable bug; see the
    # teeth plan). Python's key=lower() mirrors that.
    ordered = sorted(FILES, key=lambda f: f[0].lower())

    run1_lines = [name for name, _t, _s, _d in ordered]
    expected_run1 = b''.join(hitext(n) + CR for n in run1_lines)

    run2_lines = []
    for name, _t, _s, _d in ordered:
        e = built[name]
        run2_lines.append(format_l_line(e['file_type'], eof_field(e['eof']),
                                         e['raw4'], e['display_name']))
    expected_run2 = b''.join(hitext(line) + CR for line in run2_lines)

    gfi = built[GFI_TARGET]
    run3_line = format_l_line(gfi['file_type'],
                               blocks_field(gfi['blocks_used']),
                               gfi['raw4'], GFI_ARGV_PATH)
    expected_run3 = hitext(run3_line) + CR

    expected_run4_err = hitext(f'ls: {NOSUCH_PATH}: cannot access') + CR

    return dict(
        run1=expected_run1, run2=expected_run2, run3=expected_run3,
        run4_err=expected_run4_err, run4_status=1,
        built=built, ordered=run1_lines,
    )


def build():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXLSTEST.SYSTEM'),
        (LS_BIN, 'ls userland binary'),
    ]:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2

    shutil.copyfile(CARRIER_IMG, OUT_IMG)
    prodos.mount(OUT_IMG)
    root = f'/mnt/{CARRIER_VOL}'
    removed, kept = [], []

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
    with open(LS_BIN, 'rb') as f:
        lsbin = f.read()

    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    try:                      # docs/VROOT.md: programs live in BIN
        prodos.mkdir(f'{root}/BIN')
    except FileExistsError:
        pass
    prodos.write(f'{root}/BIN/LS', lsbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)

    prodos.mkdir(LSDIR)
    for name, file_type, size, _date_kind in FILES:
        data = bytes((i % 251) + 1 for i in range(size))  # deterministic filler
        prodos.write(f'{LSDIR}/{name}', data, file_type=file_type,
                     overwrite=True)

    # -- Reach into the mounted Volume object for the two things the public
    # API cannot express (see module header): a zeroed mod_date/mod_time,
    # and a deliberately Extended/invalid one. Also read back the REAL
    # blocks_used the allocator gave each file, rather than hand-deriving
    # it (a sapling's blocks_used includes its index block).
    vol = prodos._session.get(prodos._foldname(CARRIER_VOL))
    dir_blockno = vol._resolve_dir(LSDIR[len(root):] or '/')

    built = {}
    for name, file_type, size, date_kind in FILES:
        entry = vol._find_entry(dir_blockno, name.upper(), write=True)
        assert entry is not None, f'{name} missing after write_file'
        if date_kind == 'legacy':
            entry.last_mod = LEGACY_DT       # public API: valid datetime
        elif date_kind == 'zero':
            _patch_date(entry, bytes(4))
        elif date_kind == 'invalid':
            _patch_date(entry, INVALID_DATE_BYTES)
        else:
            raise ValueError(date_kind)
        raw4 = bytes(entry._mem[0x21:0x25])
        built[name] = dict(file_type=entry.type, eof=entry.eof,
                            blocks_used=entry.blocks_used, raw4=raw4,
                            display_name=name)

    prodos.unmount(CARRIER_VOL)

    print(f'[build-ls] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-ls] kept={kept} removed={removed}')
    print(f'[build-ls] LSDIR entries (name, type, eof, blocks_used): '
          f'{[(n, hex(built[n]["file_type"]), built[n]["eof"], built[n]["blocks_used"]) for n, *_ in FILES]}')
    print(f'[build-ls] {OUT_IMG} ready ({os.path.getsize(OUT_IMG)} bytes)')
    return 0


def main():
    rc = build()
    if rc:
        return rc
    expected = compute_expected(OUT_IMG)
    print(f'[build-ls] sorted order: {expected["ordered"]}')
    print(f'[build-ls] run1 expected: {expected["run1"]!r}')
    print(f'[build-ls] run2 expected: {expected["run2"]!r}')
    print(f'[build-ls] run3 ({GFI_TARGET}) expected: {expected["run3"]!r}')
    print(f'[build-ls] run4 expected stderr: {expected["run4_err"]!r} '
          f'status={expected["run4_status"]}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
