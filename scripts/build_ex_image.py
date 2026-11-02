#!/usr/bin/env python3
"""Build the ProDOS-hosted `make check-ex` image -- scripts/build_ed_image.py's
own pattern (copy the known-good SmartPort-bootable carrier, strip everything
but PRODOS, write the vendored kernel + this gate's .SYSTEM + the real
ex.bin userland binary as /bin/EX), PLUS every fixture/script file the
harness sessions read (FIXTURES, below)."""
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
VOL_BLOCKS = 1600          # 800K, was the 280-block carrier
BOOT_BYTES = 1024          # blocks 0 and 1: the ProDOS boot loader
KERNEL_BIN = os.environ.get('PRODOS_KERNEL_BIN',
                            os.path.join(ROOT, 'vendor', 'ProDOS-2.4.bin'))
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXEXTEST.SYSTEM')
EX_BIN = os.path.join(ROOT, 'build', 'ex.bin')
# 2026-09-06: the `!` family's own session 9 (src/test/extestb8.s)
# spawns a REAL `sh`, which in turn spawns `sort`/`cat` -- PATHRSLV
# resolves both against PATHTAB's "/mnt/MAUX/" entry, so all three must
# be ON the image at that path, same as EX itself.
SH_BIN = os.path.join(ROOT, 'build', 'sh.bin')
SORT_BIN = os.path.join(ROOT, 'build', 'sort.bin')
CAT_BIN = os.path.join(ROOT, 'build', 'cat.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'ex.po')

# ---------------------------------------------------------------------------
# Fixture and script files, staged at BUILD time.
#
# 2026-09-08: until this date every one of these was TEXT EMBEDDED IN
# THE HARNESS IMAGE (src/test/extestb3.s's *_TEXT blocks and their
# extestb5..9.s siblings) that PARENT_PROC created and wrote to disk at
# runtime, 37 times over, before spawning each session's `ex`. That
# text -- plus ~1.2 KB of create/open/write/close plumbing around it --
# sat inside the PARENT_PROC span that extestb.s BankCopies into bank
# 1, so its main-memory original was dead once installed and
# MAUXEXTEST.SYSTEM could overrun PMLI_IBF_BASE ($9800) "harmlessly";
# check_kernel_images.py's KNOWN_OVERRUN carried that as a pinned debt
# that every kernel increment inflated (284 -> 581 -> 1026 B in one
# day). Staging the same bytes here instead retires the pin: the
# harness now only OPENS these files.
#
# BYTE-EXACT with what the harness used to write: high-bit ASCII, a
# CR ($8D) after EVERY line (merlin's `asc "..."` + `dfb $8D`), ProDOS
# type TXT ($04) aux $0000 -- CRT_BY_PATH's own CREATE parameters. The
# per-command trace that derives check_ex.py's expected bytes for each
# script stays in the harness source next to that session's driver
# (extestb5.s for EXSCR6, extestb9.s for EXSCR10-16, and so on) --
# this table is the BYTES, those comments are the WHY.
#
# What is NOT here, deliberately: each session's own capture file
# (EXCAPn -- the spawned ex writes it, the harness needs the open fd)
# and every file `ex` itself creates (EXOUTn, EXFILE8, EX14COPY) --
# those are outputs, and a run must start without them.
# ---------------------------------------------------------------------------
# Sessions 10-16 live under ONE subdirectory: the carrier's ROOT is a
# fixed 4-block directory (51 entries) and sessions 1-9 plus the
# binaries already fill most of it (extestb9.s's own header, measured
# 2026-09-06). Created here; the harness used to CREATE it at runtime.
FIXTURE_DIR = '/mnt/MAUX/EXR9'

FIXTURES = [
    # -- session 1 (extestb.s): r / %p / 2s / %p / w / q, every line
    # -- through the swap file. "BANK" on lines 2 AND 4 -- line 4 is
    # -- the control that `2s` only rewrites the addressed line.
    ('/mnt/MAUX/EXSRC', ['line one', 'BANK middle', 'line three',
                      'line four BANK', 'line five']),
    ('/mnt/MAUX/EXSCR1', ['r /mnt/MAUX/EXSRC', '%p', '2s/BANK/SWAPD/', '%p',
                       'w /mnt/MAUX/EXOUT', 'q']),
    # -- session 2 (extestb.s): Task 0's `j` fix -- 1,2j then 2,4j.
    ('/mnt/MAUX/EXSRC2', ['L1', 'L2', 'L3', 'L4', 'L5']),
    ('/mnt/MAUX/EXSCR2', ['r /mnt/MAUX/EXSRC2', '1,2j', '%p', '2,4j', '%p',
                       'w /mnt/MAUX/EXOUT2', 'q']),
    # -- session 3 (extestb2.s): marks / undo / #-print / n reserved.
    ('/mnt/MAUX/EXSRC3', ['M1', 'M2', 'M3', 'M4', 'M5']),
    ('/mnt/MAUX/EXSCR3', ['r /mnt/MAUX/EXSRC3', '3ka', '1a', 'NEW', '.', "'ap",
                       '1,2d', "'ap", '1,1d', '1,1d', "'ap", 'u', '%p',
                       'u', '%p', '1,2#', 'n', 'w /mnt/MAUX/EXOUT3', 'x']),
    # -- session 4 (extestb2.s): ?re? / e / e! / wq. EXSRC4B is
    # -- loaded by `e!` and is `wq`'s write target.
    ('/mnt/MAUX/EXSRC4', ['B1', 'B2', 'B3']),
    ('/mnt/MAUX/EXSRC4B', ['C1', 'C2']),
    ('/mnt/MAUX/EXSCR4', ['r /mnt/MAUX/EXSRC4', '?B2?p', '?ZZZ?p', '1a', 'NEWB',
                       '.', '%p', 'e /mnt/MAUX/EXSRC4B', 'e! /mnt/MAUX/EXSRC4B',
                       '%p', 'wq']),
    # -- session 5 (extestb4.s): filename-on-launch. 5a loads EXFILE5
    # -- via argv (no `r` in the script); 5b launches on a path
    # -- nothing creates (EXNOSUCH5 -- NOT staged, that is the test).
    ('/mnt/MAUX/EXFILE5', ['un', 'deux', 'trois']),
    ('/mnt/MAUX/EXSCR5', ['%p', 'w', 'q']),
    ('/mnt/MAUX/EXSCR5N', ['w', 'q']),
    # -- session 6 (extestb5.s): "last regular expression" -- `??`
    # -- repeats, shared with `//`; `s//` reuse.
    ('/mnt/MAUX/EXSRC6', ['BANK one', 'xxxxx two', 'BANK three',
                       'yyyyy four', 'OLDthing here', 'OLDthing again']),
    ('/mnt/MAUX/EXSCR6', ['r /mnt/MAUX/EXSRC6', '??', '?BANK?p', '??', '/yyyyy/',
                       '??', '5s/OLD/NEW/', '5p', '6s//XXX/', '6p',
                       'w! /mnt/MAUX/EXSRC6', 'q']),
    # -- session 7 (extestb6.s): widened g/v -- `s` on every match.
    ('/mnt/MAUX/EXSRC7', ['BANK one', 'plain two', 'BANK three',
                       'plain four']),
    ('/mnt/MAUX/EXSCR7', ['r /mnt/MAUX/EXSRC7', 'g/BANK/s/BANK/GONE/', '%p',
                       'w! /mnt/MAUX/EXSRC7', 'q']),
    # -- session 8 (extestb7.s): `w` truncation proof -- EXFILE8 is
    # -- created by ex's own first `w`, so it is NOT staged here.
    ('/mnt/MAUX/EXSCR8', ['a', 'LLLLLLLLLL one', 'LLLLLLLLLL two',
                       'LLLLLLLLLL three', 'LLLLLLLLLL four',
                       'LLLLLLLLLL five', 'LLLLLLLLLL six', '.',
                       'w /mnt/MAUX/EXFILE8', '1,6d', 'a', 'U1', 'U2', '.',
                       'w! /mnt/MAUX/EXFILE8', 'q']),
    # -- session 9 (extestb8.s): the `!` family through a real `sh`.
    ('/mnt/MAUX/EXSRC9', ['pear', 'kiwi', 'fig', 'mango']),
    ('/mnt/MAUX/EXSRC9B', ['X1', 'X2']),
    ('/mnt/MAUX/EXSCR9', ['r /mnt/MAUX/EXSRC9', '1,$!sort', '%p',
                       '$r !cat /mnt/MAUX/EXSRC9B', '%p', '1,2w !cat',
                       '!cat /mnt/MAUX/EXSRC9B', 'w /mnt/MAUX/EXOUT9', 'q']),
    # -- session 10 (extestb9.s, EX1): `r !cmd`'s missing ED_CHECK0N.
    # -- EXFIXZ is also session 16's classic `r FILE` fixture.
    (FIXTURE_DIR + '/EXFIXZ', ['ZERO']),
    (FIXTURE_DIR + '/EXFIXL', ['LAST']),
    (FIXTURE_DIR + '/EXSCR10', ['a', 'original', '.', '99r !echo NEW', '%p',
                                '0r !cat /mnt/MAUX/EXR9/EXFIXZ',
                                '$r !cat /mnt/MAUX/EXR9/EXFIXL', '%p', 'u',
                                '%p', 'w /mnt/MAUX/EXR9/EXOUT10', 'q']),
    # -- session 11 (extestb9.s, EX2 + XC4): exit status of a refused
    # -- command (11A) vs the clean control with `!exit 7` (11B).
    (FIXTURE_DIR + '/EXSCR11A', ['a', 'onlyline', '.', '999p', 'q!']),
    (FIXTURE_DIR + '/EXSCR11B', ['a', 'onlyline', '.', '1p', '!exit 7',
                                 'q!']),
    # -- session 12 (extestb9.s, EX6): `&` takes its own snapshot.
    (FIXTURE_DIR + '/EXSRC12', ['aa', 'aa']),
    (FIXTURE_DIR + '/EXSCR12', ['r /mnt/MAUX/EXR9/EXSRC12', '1s/aa/ZZ/', '2&',
                                'u', '%p', 'u', '%p',
                                'w /mnt/MAUX/EXR9/EXOUT12', 'q']),
    # -- session 13 (extestb9.s, EX7 + FF1 + XC3): shell reads inside
    # -- g/v and the global's one undo snapshot. EXFIXX is 7 chars for
    # -- FF1 (long enough to reach cmds' own start in CMDBUF).
    (FIXTURE_DIR + '/EXSRC13', ['A', 'B']),
    (FIXTURE_DIR + '/EXFIXX', ['LONGRUN']),
    (FIXTURE_DIR + '/EXSCR13', ['r /mnt/MAUX/EXR9/EXSRC13',
                                'g/[AB]/r !cat /mnt/MAUX/EXR9/EXFIXX', '%p',
                                'u', '%p', 'u', '%p',
                                'v/Z/r !cat EXR9/EXFIXX', 'u', '%p',
                                'w /mnt/MAUX/EXR9/EXOUT13', 'q']),
    # -- session 14 (extestb9.s, EX4): `w PATH` must not rebind the
    # -- current filename. EX14COPY is created by ex -- not staged.
    (FIXTURE_DIR + '/EX14MAIN', ['old']),
    (FIXTURE_DIR + '/EXSCR14', ['w /mnt/MAUX/EXR9/EX14COPY', '1s/old/new/',
                                'w', 'q!']),
    # -- session 15 (extestb9.s, EX5 + XC2): the `w!` guard and the
    # -- current file's absolute/relative spellings. EX15OTHER must
    # -- EXIST (a different file still needs `!`).
    (FIXTURE_DIR + '/EX15MAIN', ['old']),
    (FIXTURE_DIR + '/EX15OTHER', ['other']),
    (FIXTURE_DIR + '/EXSCR15', ['1s/old/new/', 'w /mnt/MAUX/EXR9/EX15MAIN',
                                '1s/new/N2/', 'w EXR9/EX15MAIN',
                                'w /mnt/MAUX/EXR9/EX15OTHER', 'q!']),
    # -- session 16 (extestb9.s, EX3 + XC1 + FF2-FF5 + Phase E): real
    # -- pipelines both directions, `w !` pipe, classic `r FILE`.
    (FIXTURE_DIR + '/EX16SRC', ['pear', 'fig']),
    (FIXTURE_DIR + '/EXSCR16', ['r /mnt/MAUX/EXR9/EX16SRC', '%!cat | sort',
                                '%p', '.=', '$a', 'zebra', 'apple', '.',
                                '%!sort | cat', '%p', '1d', '3d',
                                'w! EXR9/EX16SRC', '1s/f/F/', 'w',
                                'r EXR9/EXFIXZ', '%p', '$a', 'aa', 'aa',
                                'aa', '.', '4s/a/b/g2', '%p',
                                '4,6w !sort | cat', 'q']),
]

FIXTURE_FILE_TYPE = 0x04   # TXT, as CRT_BY_PATH created them
FIXTURE_AUX_TYPE = 0x0000


def encode_fixture(lines):
    """The exact bytes the harness's `asc "..."` / `dfb $8D` pairs
    emitted: every character with its high bit set, a $8D after each
    line. 7-bit ASCII only -- anything else is a typo, not a fixture."""
    out = bytearray()
    for line in lines:
        raw = line.encode('ascii')
        if any(c < 0x20 for c in raw):
            raise ValueError(f'control character in fixture line {line!r}')
        out += bytes(c | 0x80 for c in raw)
        out.append(0x8D)
    return bytes(out)


def main():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXEXTEST.SYSTEM'),
        (EX_BIN, 'ex.bin userland binary'),
        (SH_BIN, 'sh.bin userland binary'),
        (SORT_BIN, 'sort.bin userland binary'),
        (CAT_BIN, 'cat.bin userland binary'),
    ]:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2

    # A 280-block carrier ran out of room when sh grew by its line editor
    # (TAB-A2: +1.7 KB, ex.po had ONE free block left and the harness's
    # EX.INxx/EX.OUTxx temp files failed to create). The house answer
    # is a bigger disk, not a shorter roster (build_play_image.py's
    # VOL_BLOCKS, build_e2e_image.py's): an empty volume formatted by
    # a2til with the carrier's boot blocks spliced across.
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
    with open(EX_BIN, 'rb') as f:
        ex = f.read()
    with open(SH_BIN, 'rb') as f:
        sh = f.read()
    with open(SORT_BIN, 'rb') as f:
        sort = f.read()
    with open(CAT_BIN, 'rb') as f:
        cat = f.read()

    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    try:                      # docs/VROOT.md: programs live in BIN
        prodos.mkdir(f'{root}/BIN')
    except FileExistsError:
        pass
    prodos.write(f'{root}/BIN/EX', ex, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/SH', sh, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/SORT', sort, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/CAT', cat, file_type=0x06, aux_type=0x0800,
                 overwrite=True)

    # The carrier's volume name is what the harness's absolute paths
    # spell (/mnt/MAUX/...), so the fixture paths are taken literally --
    # a renamed carrier volume would break the harness first anyway.
    prodos.mkdir(FIXTURE_DIR)
    fixture_bytes = 0
    for path, lines in FIXTURES:
        data = encode_fixture(lines)
        prodos.write(path, data, file_type=FIXTURE_FILE_TYPE,
                     aux_type=FIXTURE_AUX_TYPE)
        fixture_bytes += len(data)
    prodos.unmount(CARRIER_VOL)

    print(f'[build-ex] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-ex] kept={kept} removed={removed}')
    print(f'[build-ex] wrote MAUX.SYSTEM ({len(system)} bytes), '
          f'EX ({len(ex)} bytes), SH ({len(sh)} bytes), '
          f'SORT ({len(sort)} bytes), CAT ({len(cat)} bytes)')
    print(f'[build-ex] staged {len(FIXTURES)} fixture/script files '
          f'({fixture_bytes} bytes) incl. {FIXTURE_DIR}/')
    print(f'[build-ex] {OUT_IMG} ready ({os.path.getsize(OUT_IMG)} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
