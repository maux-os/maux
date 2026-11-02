#!/usr/bin/env python3
"""Build the ProDOS-hosted `make check-ed` image -- scripts/build_fileprocess_
image.py's own pattern (copy the known-good SmartPort-bootable carrier,
strip everything but PRODOS, write the vendored kernel + this gate's
.SYSTEM + the real ed.bin userland binary as /bin/ED), PLUS every
fixture/script file the harness sessions read (FIXTURES, below)."""
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
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXEDTEST.SYSTEM')
ED_BIN = os.path.join(ROOT, 'build', 'ed.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'ed.po')

# ---------------------------------------------------------------------------
# Fixture and script files, staged at BUILD time.
#
# 2026-09-12: until this date every one of these was TEXT EMBEDDED IN
# THE HARNESS IMAGE (src/test/edtestb.s and edtestb2.s's *_TEXT blocks)
# that PARENT_PROC created and wrote to disk at runtime, 13 times over,
# before spawning each session's `ed`. That text -- plus ~600 B of
# create/open/write/close plumbing around it -- left MAUXEDTEST.SYSTEM
# only 4 bytes under PMLI_IBF_BASE ($9800), per docs/CONSOLE-VT102.md
# sec 7's follow-up note: "the NEXT kernel byte trips it again". Same
# debt shape scripts/build_ex_image.py's FIXTURES table retired for
# MAUXEXTEST.SYSTEM (de7ea88) -- staging the same bytes here instead
# means the harness now only OPENS these files.
#
# BYTE-EXACT with what the harness used to write: high-bit ASCII, a CR
# ($8D) after EVERY line (merlin's `asc "..."` + `dfb $8D`), ProDOS
# file type BIN ($06) aux $0000 -- edtestb2.s's own CRT_BY_PATH CREATE
# parameters (note: NOT ex's TXT $04 -- ed's own harness CRT_BY_PATH
# uses $06, checked against src/test/edtestb2.s directly rather than
# assumed from the ex precedent). The per-command trace that derives
# check_ed.py's expected bytes for each script stays in the harness
# source next to that session's PATH_* labels (edtestb.s/edtestb2.s,
# see each session's own header comment) -- this table is the BYTES,
# those comments are the WHY.
#
# What is NOT here, deliberately: every capture file the spawned `ed`
# writes (EDOUT1-9, EDCAP6N/EDCAP10 -- the harness needs the open fd,
# not content) and every file `ed` itself creates or overwrites via a
# `w` inside a script (EDFILE, EDFILE2, EDFILE3, EDFILE5, EDFILE6 (re-
# written), EDFILE7, EDFILE8, EDFILE9, ED10FRESH) -- those are outputs,
# and a run must start without them. EDNOSUCH6 (session 6b's negative
# launch-load case) is deliberately never staged either -- the whole
# point is that path does not exist.
#
# No subdirectory needed (unlike ex's later sessions): staging these
# 13 files at build time instead of runtime does not change the total
# root-directory entry count -- the harness already created all of
# them (plus its 32 runtime outputs) directly under /mnt/MAUX/ before
# this change, so the carrier's root already had the headroom.
# ---------------------------------------------------------------------------
FIXTURES = [
    # -- session 1 (edtestb.s): `a` three lines (two containing BANK),
    # -- `.`, `w /mnt/MAUX/EDFILE`, `q`.
    ('/mnt/MAUX/EDSCR1', ['a', 'alpha one', 'BANK two', 'BANK three', '.',
                       'w /mnt/MAUX/EDFILE', 'q']),
    # -- session 2 (edtestb.s): `r`, `g/BANK/p`, `3s/BANK/&X/`, `w`,
    # -- `q` -- reads back session 1's own /mnt/MAUX/EDFILE.
    ('/mnt/MAUX/EDSCR2', ['r /mnt/MAUX/EDFILE', 'g/BANK/p', '3s/BANK/&X/',
                       'w /mnt/MAUX/EDFILE2', 'q']),
    # -- session 3 (edtestb.s): 2026-08-19 audit-fix phases (findings
    # -- 1, 2, 4, 5, 6 -- s///N + bad flag, no-match /re/, m/t incl.
    # -- self-range, bare address, bare `,`/`;`). Full per-command
    # -- trace: edtestb2.s's own comment above PATH_EDSCR3.
    ('/mnt/MAUX/EDSCR3', ['a', 'xxxxx', 'alpha', 'BETA', 'gamma', 'delta',
                       '.', '1s/x/Y/2', '1p', '1s/x/Y/z', '3p',
                       '/zzz/p', 'p', '3', ';p', '1,2;3p', '4,5t1',
                       ',p', '6,7m0', ',p', '1,2m1', ',p', '1,2m7',
                       ',p', 'w /mnt/MAUX/EDFILE3', '$a', 'omega', '.',
                       'w /mnt/MAUX/EDFILE3', 'q']),
    # -- session 4 (edtestb.s): finding 3's NEGATIVE case -- a fresh
    # -- ed process, no r/w yet, bare `w` must stay `?`.
    ('/mnt/MAUX/EDSCR4', ['a', 'onlyone', '.', 'w', 'q']),
    # -- session 5 (edtestb.s): `j` (join) and `=` (print line
    # -- number). Full per-command trace: edtestb2.s's own comment
    # -- above PATH_EDSCR5.
    ('/mnt/MAUX/EDSCR5', ['a', 'L1', 'L2', 'L3', 'L4', 'L5', '.', '1,2j',
                       'p', '=', '2,4j', 'p', '1=', 'p', '1p', 'j',
                       'p', '1j', 'p', 'w /mnt/MAUX/EDFILE5', 'q']),
    # -- session 6a (edtestb.s): `ed /mnt/MAUX/EDFILE6` -- filename-on-
    # -- launch. EDFILE6 is the launch-load FIXTURE (read via argv,
    # -- not `r`) -- ed's own bare `w` in EDSCR6 later overwrites it,
    # -- proving ED_CURFNAME was set by the launch load.
    ('/mnt/MAUX/EDFILE6', ['first', 'second', 'third']),
    ('/mnt/MAUX/EDSCR6', [',p', 'w', 'q']),
    # -- session 6b (edtestb.s): `ed /mnt/MAUX/EDNOSUCH6` -- a path that
    # -- does NOT exist (deliberately not staged, see header above).
    # -- bare `w` must stay `?`, same cold case as session 4.
    ('/mnt/MAUX/EDSCR6N', ['w', 'q']),
    # -- session 7 (edtestb2.s): "last regular expression" task -- a
    # -- bare `//` with no prior search is `?`; `/BANK/p` then a bare
    # -- `//` re-finds the NEXT `BANK` (forward repeat); `s/OLD/NEW/`
    # -- then a later `s//X/` reuses OLD as the search field. Full
    # -- trace: edtestb2.s's own comment above PATH_EDFILE7.
    ('/mnt/MAUX/EDSCR7', ['a', 'BANK one', 'xxxxx two', 'BANK three',
                       'yyyyy four', 'OLDthing here', 'OLDthing again',
                       '.', '//', '/BANK/p', '//', '/OLDthing/p',
                       'g//p', '5s/OLD/NEW/', '5p', '6s//XXX/', '6p',
                       'w /mnt/MAUX/EDFILE7', 'q']),
    # -- session 8 (edtestb2.s): widened g/v task. EDFIX1 is the
    # -- classic-`r` fixture `g/GONE/r EDFIX1` reads (FF1 2026-09-06:
    # -- 9 chars, long enough to reach cmds' own start in CMDBUF for a
    # -- "g/GONE/" 7-char prefix). Full trace: edtestb2.s's own
    # -- comment above PATH_EDFIX1.
    ('/mnt/MAUX/EDFIX1', ['EDFIXLINE']),
    ('/mnt/MAUX/EDSCR8', ['a', 'BANK one', 'plain two', 'BANK three',
                       'plain four', 'BANK five', '.',
                       'g/BANK/s/BANK/GONE/', ',p', 'g/plain/d', ',p',
                       'v/three/p', 'g/GONE/g/x/p', ',p', 'g/GONE/u',
                       ',p', 'g/GONE/r /mnt/MAUX/EDFIX1', ',p',
                       'w /mnt/MAUX/EDFILE8', 'q']),
    # -- session 9 (edtestb2.s): `w` truncation proof -- a bare `w`
    # -- overwriting an existing longer file with a shorter buffer
    # -- must leave no stale tail. Full trace: edtestb2.s's own
    # -- comment above PATH_EDFILE9.
    ('/mnt/MAUX/EDSCR9', ['a', 'LLLLLLLLLL one', 'LLLLLLLLLL two',
                       'LLLLLLLLLL three', 'LLLLLLLLLL four',
                       'LLLLLLLLLL five', 'LLLLLLLLLL six', '.',
                       'w /mnt/MAUX/EDFILE9', '1,6d', 'a', 'T1', 'T2', '.',
                       'w /mnt/MAUX/EDFILE9', 'q']),
    # -- session 10 (edtestb2.s, XC1): an unnamed buffer's first `w`
    # -- establishes the current name so a bare second `w` reuses it
    # -- instead of being refused. Full trace: edtestb2.s's own
    # -- comment above SESS10START.
    ('/mnt/MAUX/EDSCR10', ['a', 'old', '.', 'w /mnt/MAUX/ED10FRESH',
                        '1s/old/new/', 'w', 'q']),
]

FIXTURE_FILE_TYPE = 0x06   # BIN, as edtestb2.s's own CRT_BY_PATH
                           # creates them (NOT TXT $04 -- checked
                           # against the harness, not assumed)
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
        (SYS_BIN, 'MAUXEDTEST.SYSTEM'),
        (ED_BIN, 'ed.bin userland binary'),
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
    with open(ED_BIN, 'rb') as f:
        ed = f.read()

    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    try:                      # docs/VROOT.md: programs live in BIN
        prodos.mkdir(f'{root}/BIN')
    except FileExistsError:
        pass
    prodos.write(f'{root}/BIN/ED', ed, file_type=0x06, aux_type=0x0800,
                 overwrite=True)

    fixture_bytes = 0
    for path, lines in FIXTURES:
        data = encode_fixture(lines)
        prodos.write(path, data, file_type=FIXTURE_FILE_TYPE,
                     aux_type=FIXTURE_AUX_TYPE)
        fixture_bytes += len(data)
    prodos.unmount(CARRIER_VOL)

    print(f'[build-ed] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-ed] kept={kept} removed={removed}')
    print(f'[build-ed] wrote MAUX.SYSTEM ({len(system)} bytes), '
          f'ED ({len(ed)} bytes)')
    print(f'[build-ed] staged {len(FIXTURES)} fixture/script files '
          f'({fixture_bytes} bytes)')
    print(f'[build-ed] {OUT_IMG} ready ({os.path.getsize(OUT_IMG)} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
