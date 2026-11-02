#!/usr/bin/env python3
"""Build the `sh` WARM-RESPAWN image (`make check-shwarm`).

Companion to scripts/check_shwarm.py and docs/STICKY.md sec 32.

WHY THIS IMAGE EXISTS. Lazy free (sec 27) hands the next spawn of a
program the bank the previous run left behind, text and all. sec 29
audited the whole fleet against that and gave `sh` the verdict
DIRTY-TAIL: it writes its own image and its entry head does NOT move,
so the kernel RETAINS its bank and a second `sh` would run on the
first one's leftovers. Every other DIRTY-TAIL program in that audit
carries a REPEAT PAIR -- the same command twice, adjacently, outputs
compared -- to prove the leftovers are harmless. `sh` had none, for a
structural reason: it is the login shell, spawned once per boot by the
harness, and nothing in the tree ever spawned it twice
(build_textaudit_image.UNPAIRABLE says exactly that). So the one
program that most needs the evidence was the one the audit could not
gather it for -- and it is the first program that will ever `fork()`.

HOW A SECOND `sh` IS ARRANGED, WITHOUT A LINE OF NEW ASSEMBLY. `sh`
can spawn `sh` -- check-shlang already nests one -- and the command
word is the BARE `SH`, resolved through sh's own PATHTAB. PATHTAB is
`/bin/` then `/mnt/MAUX/`, and this image deliberately leaves `SH`
in the volume ROOT and out of BIN, so BUILD_PATH's probe misses the
first candidate and resolves to `/bin/sh` -- byte for byte the
pathname the harness spawned, which is what makes the harness's shell,
run 1 and run 2 share ONE lazy-free tag (lazy free never tags a
relative spawn, sec 27).

An ABSOLUTE command word would have been the obvious way to say the
same thing and it is NOT USABLE ON THIS TREE: `/bin/sh < ...` spawns
the wrong file. RSLV_PTH_STG returns PTR0 = the argv word for a word
starting `/` (skipping BUILD_PATH), but the spawn site four lines
later re-points PTR0 at SH_PATHFULL unconditionally -- so an absolute
command silently runs whatever the LAST PATHTAB resolution left there.
Measured: with `ECHO` resolved on the line before,
`/bin/CAT /mnt/MAUX/GREPIN > OUT` puts the string `/mnt/MAUX/GREPIN`
in OUT -- `echo` running with `cat`'s argv. With nothing resolved yet
it is "sh: command not found", which is how this gate found it. Not
fixed here; see docs/STICKY.md sec 32 "Found, not fixed".

The outer `sh` stays LIVE throughout -- LZ_MATCH skips live slots --
so the two NESTED shells are the pair:

    SH < /mnt/MAUX/SUB1 > /mnt/MAUX/SH1     <- cold, run 1
    SH < /mnt/MAUX/SUB2 > /mnt/MAUX/SH2     <- WARM, run 2

Nested sh #1 exits, LZ_RETAIN tags and keeps its bank, and nested
sh #2 -- the very next spawn, nothing in between -- is served out of
it with no image copy. ADJACENCY IS LOAD-BEARING for the same reason
check-ld's two `LD` lines must stay adjacent: anything spawned between
them can reclaim the bank and make run 2 cold, which passes while
proving nothing. scripts/check_shwarm.py asserts warmth from the
kernel's own LZ_WARM rather than trusting this comment.

SUB1 AND SUB2 ARE BYTE-IDENTICAL, which is stronger than the fleet
audit's pairs. Those pairs must differ in their output path (`ECHO
HELLO > .../E1` vs `.../E2`); here the output path is on the SPAWN
line and is INHERITED as fd 1, so the two shells receive the same
argv (`SH`) and the same script bytes, and any difference between
SH1 and SH2 is the retained bank and nothing else. Two files rather
than one because ProDOS refuses the second OPEN of an already-open
file (build_textaudit_image's DIFFA/DIFFC carry the same note).

WHAT THE SUB-SCRIPT IS FOR, line by line -- every line is aimed at a
cell that a warm respawn does NOT re-initialise:

  ECHO S0 $?        LASTSTATUS, read BEFORE this shell has run any
                    command. It is one of the seven cells sec 28 kept
                    as REAL EMITTED ZEROS because a REPL reads them on
                    its first pass -- and an emitted zero is exactly
                    what a warm respawn does not restore, because the
                    image is not recopied. The last line below leaves
                    it NONZERO on purpose, so a leak is visible here
                    on the next run.
  ECHO S1 V=$V      VARNAMES/VARVALS, read before any assignment.
                    sec 28 calls VARNAMES "the file's most load-
                    bearing zero": there is no variable counter, a
                    free slot IS a zero name byte.
  V=WARMLEAK        ...and now the slot is occupied, in the IMAGE.
  ECHO S2 V=$V      the same read again, after the write -- so run 1's
                    own output distinguishes "the variable works" from
                    "the variable leaked".
  CAT ... | GREP    a real pipeline: NCMD, CHILDMAP, FDABUF, the pipe
                    fd arrays and the fd-action buffer, which is the
                    arena half of the question (poisoned with $A5 by
                    the gate, not merely left over).
  ECHO S3 $?        the pipeline's status, through the same cell.
  CAT /mnt/MAUX/NOSUCH the deliberate failure that leaves LASTSTATUS
                    nonzero at exit. It is LAST on purpose: `sh`'s own
                    EXIT does not disturb it, so the retained image
                    carries a nonzero status into run 2's first line.

A NOTE ON stderr. `sh` has no `2>` on a spawn line here, so the failing
`CAT`'s diagnostic goes to the harness's own fd 2 and never reaches
SH1/SH2. That is deliberate: the compared files hold stdout only.
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
BUILD = os.path.join(ROOT, 'build')
SYS_BIN = os.path.join(BUILD, 'MAUXSH.SYSTEM')
OUT_IMG = os.path.join(BUILD, 'shwarm.po')

# The programs the sub-script runs, in /bin where sh's own
# PATHTAB looks first -- so every one of them is spawned by an
# ABSOLUTE path and is therefore tagged by lazy free.
BIN_PROGS = ('echo', 'cat', 'grep')

# Run 1's outputs vs run 2's. Named here rather than in the checker so
# one file owns the whole contract.
OUT1 = f'/mnt/{CARRIER_VOL}/SH1'
OUT2 = f'/mnt/{CARRIER_VOL}/SH2'
# SH-ROOM (R5): a COLD start AFTER a warm one. Nested sh #3 is served
# warm out of run 2's retained bank (the only dead `sh` bank there is) and
# is LIVE while it spawns sh #4, which finds no retained `sh` bank and is
# served COLD from a fresh one. SH4 must show the segments installed and
# the alias table empty and working there. check_shwarm.deadcopy_pass
# asserts the cold-after-warm ordering from the kernel, not from this
# comment.
OUT4 = f'/mnt/{CARRIER_VOL}/SH4'


def hitext(s):
    return bytes(ord(c) | 0x80 for c in s)


def lines(*rows):
    return b''.join(hitext(r) + bytes([0x8D]) for r in rows)


def script_bytes(*rows):
    return b''.join(hitext(r) + bytes([0x8D]) for r in rows)


GREPIN = lines('alpha one', 'beta two', 'alpha three', 'gamma four')

# The OUTER script: the harness's `sh` reads this. The two spawn lines
# are ADJACENT and differ only in which byte-identical sub-script they
# read and which file they write.
SCRIPT = script_bytes(
    'CD /mnt/MAUX',
    f'SH < /mnt/{CARRIER_VOL}/SUB1 > {OUT1}',
    f'SH < /mnt/{CARRIER_VOL}/SUB2 > {OUT2}',
    f'SH < /mnt/{CARRIER_VOL}/SUB3',
    'EXIT',
)

# The sub-script, run by BOTH nested shells, byte for byte.
SUB = script_bytes(
    'ECHO S0 $?',
    'ECHO S1 V=$V',
    'V=WARMLEAK',
    'ECHO S2 V=$V',
    f'CAT /mnt/{CARRIER_VOL}/GREPIN | GREP alpha',
    'ECHO S3 $?',
    # -- THE ALIAS TABLE IN THE DEAD COPY (SH-ROOM). It lives in the
    # -- segments' low copy now, so on a COLD start it holds segment
    # -- code bytes and on a WARM one it holds run 1's table (plus
    # -- the gate's $A5 poison): ALI_INIT must empty it either way.
    # -- The first `ALIAS` prints NOTHING when it did -- the checker
    # -- requires exactly ONE `alias ` listing line in run 1's
    # -- output, the one after the definition -- and run 2's output
    # -- must equal run 1's, so a run-2 table that still held ZZ (or
    # -- $A5 garbage) lists extra lines and goes red. ZZ is left
    # -- defined at exit on purpose.
    'ALIAS',
    # -- Unquoted on purpose: `ZZ='...'` is a quoted-assignment word,
    # -- and would move HDX_QCH, a cell this gate has never classified.
    'ALIAS ZZ=ECHO',
    'ZZ S8 ALIASOK',
    'ALIAS',
    # -- THE SECOND CODE SEGMENT (docs/SH-SUBSET.md ruling 7.6,
    # -- 2026-09-16). `trap` and `jobs` do not live in the low image
    # -- any more: they assemble under `org PRC_LC_COMMON` and RUN
    # -- from $E000 in the process language card, installed there by
    # -- SEG_INIT at START. This is the WARM half of that claim's
    # -- coverage and it is the half that can fail alone -- a warm
    # -- respawn reloads NOTHING (docs/STICKY.md sec 25), so the low
    # -- copy SEG_INIT reads from has to have survived run 1 whole.
    # -- Put the arena anchor back at the low image's end instead of
    # -- above the low copy and every COLD gate stays green while
    # -- this line runs $A5 garbage. `getopts`, the segment's third
    # -- module, is covered cold by check-e2e's getopts-1..5 rows.
    "TRAP 'ECHO TRAPPED' INT",
    'TRAP',
    'JOBS',
    'ECHO S4 $?',
    # -- The six POSIX builtins of 2026-09-16 (docs/SH-FEATURES.md sec
    # -- 29) are segment-resident too, in a FOURTH module -- and they
    # -- brought the segment from 2,179 B to 3,884 B, so the warm copy
    # -- this gate protects is now most of an extra kilobyte further
    # -- from SEG_INIT's first byte. `TYPE` reaches SB_ISBLTN and
    # -- BLTTAB (data that lives at $E000 too, unlike the trap/getopts
    # -- strings -- STRCMPI reads it with the process's own CPU, never
    # -- through a syscall, so it did not have to stay low); `EVAL`
    # -- reaches SH_RUNLINE from segment code. Both markers below are
    # -- printed BY the segment, so a warm respawn that lost the copy
    # -- cannot produce either.
    'TYPE ECHO',
    'EVAL ECHO S5 EVALOK',
    # -- THE THIRD COPY, KFIX3 item 0: `test` (TEST_EVAL) runs from
    # -- $D000, the language card's other half, installed by the
    # -- SECOND loop in SEG_INIT. A warm respawn must find it whole
    # -- too; a test that falls through to the shell's own `[` text
    # -- is not what these lines read -- S6 and S7 are printed only
    # -- when the evaluator answered both ways.
    f'TEST -f /mnt/{CARRIER_VOL}/GREPIN && ECHO S6 TESTYES',
    f'TEST -d /mnt/{CARRIER_VOL}/GREPIN || ECHO S7 TESTNO',
    f'CAT /mnt/{CARRIER_VOL}/NOSUCH',
    'EXIT',
)

# SUB3 runs in nested sh #3 (warm); it only spawns sh #4 (cold).
SUB3 = script_bytes(
    f'SH < /mnt/{CARRIER_VOL}/SUB4 > {OUT4}',
    'EXIT',
)

# SUB4 runs in nested sh #4 (cold, after a warm one): the install of
# both segments and of the alias table, from a bank the loader just wrote.
SUB4 = script_bytes(
    'TYPE ECHO',
    'EVAL ECHO S5 EVALOK',
    f'TEST -f /mnt/{CARRIER_VOL}/GREPIN && ECHO S6 TESTYES',
    'ALIAS',
    'ALIAS ZZ=ECHO',
    'ZZ S8 ALIASOK',
    'ALIAS',
    'EXIT',
)
MARKERS4 = ('ECHO is a shell builtin', 'S5 EVALOK', 'S6 TESTYES',
            'S8 ALIASOK', "alias ZZ='ECHO'")

# The markers the checker requires to be present in run 1's output, so
# a boot in which every command failed ("command not found" throughout,
# two identical near-empty files) cannot pass its own repeat pair.
#
# THE SEGMENT ROW. "trap -- '" is TRAPLPFX (src/bin/shtrap.s -- the
# STRING stayed in the low image, because the kernel's copyin/copyout
# refuse a process address >= $D000 and a syscall could never be
# handed one at $E000), and the listing that wraps it is TRAP_LIST,
# which is segment code. 'S4 0' is `jobs`'s own `stz LASTSTATUS`,
# reached through CHCK_BLTN_JOB -- also segment code. Either marker
# missing means the $E000 install did not happen or did not survive.
#
# THE FOURTH-MODULE ROWS, 2026-09-16: 'ECHO is a shell builtin' is
# SB_WHAT's own wording (shsgblt.s) wrapped around BLTTAB, and 'S5
# EVALOK' can only appear if CHCK_BLTN_EVL -- also segment code --
# joined its operands and handed them back to SH_RUNLINE. The segment
# nearly doubled when they landed, so these two also check that the
# copy stays whole further from its start than the trap/jobs rows
# reach.
MARKERS = ('S0 0', 'S1 V=', 'S2 V=WARMLEAK', 'alpha one', 'alpha three',
           'S3 0', "trap -- 'ECHO TRAPPED'", 'S4 0',
           'ECHO is a shell builtin', 'S5 EVALOK',
           'S6 TESTYES', 'S7 TESTNO', 'S8 ALIASOK',
           "alias ZZ='ECHO'")


def build():
    for path, label in ((CARRIER_IMG, 'carrier volume'),
                        (KERNEL_BIN, 'vendored ProDOS kernel'),
                        (SYS_BIN, 'MAUXSH.SYSTEM'),
                        (os.path.join(BUILD, 'sh.bin'), 'sh binary')):
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2
    for name in BIN_PROGS:
        p = os.path.join(BUILD, f'{name}.bin')
        if not os.path.exists(p):
            print(f'error: missing {name} binary: {p}', file=sys.stderr)
            return 2

    shutil.copyfile(CARRIER_IMG, OUT_IMG)
    prodos.mount(OUT_IMG)
    root = f'/mnt/{CARRIER_VOL}'

    def rm_recursive(path, entry):
        if entry.is_dir():
            for child in list(prodos.scandir(path)):
                rm_recursive(f'{path}/{child.name}', child)
            prodos.rmdir(path)
        else:
            prodos.remove(path)

    kept = []
    for entry in list(prodos.scandir(root)):
        if entry.name.upper() == 'PRODOS':
            kept.append(entry.name)
            continue
        rm_recursive(f'{root}/{entry.name}', entry)

    with open(KERNEL_BIN, 'rb') as f:
        prodos.write(f'{root}/PRODOS', f.read(), file_type=0xFF,
                     aux_type=0x2000, overwrite=True)
    with open(SYS_BIN, 'rb') as f:
        prodos.write(f'{root}/MAUX.SYSTEM', f.read(), file_type=0xFF,
                     aux_type=0x2000, overwrite=True)

    # sh in the volume root: the harness spawns /bin/sh by absolute
    # path, and so does the outer script, so both nested shells and the
    # harness's own shell share ONE lazy-free tag.
    with open(os.path.join(BUILD, 'sh.bin'), 'rb') as f:
        try:                      # docs/VROOT.md: programs live in BIN
            prodos.mkdir(f'{root}/BIN')
        except FileExistsError:
            pass
        prodos.write(f'{root}/BIN/SH', f.read(), file_type=0x06,
                     aux_type=0x0800, overwrite=True)
    for name in BIN_PROGS:
        with open(os.path.join(BUILD, f'{name}.bin'), 'rb') as f:
            prodos.write(f'{root}/BIN/{name}', f.read(), file_type=0x06,
                         aux_type=0x0800, overwrite=True)

    prodos.write(f'{root}/GREPIN', GREPIN, file_type=0x04, aux_type=0,
                 overwrite=True)
    prodos.write(f'{root}/SCRIPT', SCRIPT, file_type=0x04, aux_type=0,
                 overwrite=True)
    # TWO copies of one script. ProDOS refuses the second OPEN of an
    # already-open file, and more to the point the two nested shells
    # must be able to hold their own fd 0 without either one's mark
    # depending on the other's.
    for name in ('SUB1', 'SUB2'):
        prodos.write(f'{root}/{name}', SUB, file_type=0x04, aux_type=0,
                     overwrite=True)
    for name, body in (('SUB3', SUB3), ('SUB4', SUB4)):
        prodos.write(f'{root}/{name}', body, file_type=0x04, aux_type=0,
                     overwrite=True)
    # src/test/shtestb.s's PARENT_PROC opens /mnt/MAUX/OUT1 and /mnt/MAUX/OUT2
    # after `sh` exits (its steps 3 and 4) and reports $EE if either is
    # missing. They are staged rather than written by the script so the
    # sub-script's program set stays exactly what this gate is about.
    for name in ('OUT1', 'OUT2'):
        prodos.write(f'{root}/{name}', lines(f'harness {name.lower()}'),
                     file_type=0x04, aux_type=0, overwrite=True)
    prodos.unmount(CARRIER_VOL)
    print(f'[build-shwarm] carrier={CARRIER_IMG} volname={CARRIER_VOL} '
          f'kept={kept}')
    print(f'[build-shwarm] outer script {len(SCRIPT)} B, sub-script '
          f'{len(SUB)} B staged twice, {len(BIN_PROGS)} programs in '
          f'{root}/BIN')
    print(f'[build-shwarm] {OUT_IMG} ready ({os.path.getsize(OUT_IMG)} B)')
    return 0


if __name__ == '__main__':
    raise SystemExit(build())
