#!/usr/bin/env python3
"""Boot and verify the `tee`/`comm` acceptance gate (`make check-comm`).

Companion to src/test/commtest.s / scripts/build_comm_image.py. Same
mechanism as scripts/check_shlang.py/check_fleet.py: boot the maux kernel +
hardwired parent process, spawn `sh` (stdin = staged /mnt/MAUX/SCRIPT), wait
for it, then read every result file back off the built .po image and
compare byte-exact against build_comm_image.py's own EXPECT_* constants
(the task brief's CONTRACT, not anything derived by running the tools).

THE POISON (docs/STICKY.md sec 25/28/37). `commtestb.s`'s PARENT_PROC
makes exactly ONE direct spawn -- `sh` -- and `sh` itself is what runs
the twelve-line script, spawning `tee` FOUR times, `comm` SEVEN times,
and `cat`/`wc` once each (inside the one pipeline case, `CAT | TEE | WC`).
None of sh.s/tee.s/comm.s/cat.s/wc.s can carry a WAIT_GO park (all
src/bin, contended, off limits), so this uses the SAME technique
scripts/check_nm.py and scripts/check_shwarm.py already established:
scripts/textaudit.py's TextAuditor stops the CPU at the kernel's own
LZ_RETAIN entry (once per process exit, BEFORE the kernel decides
whether to retain the bank) and identifies which PROGRAM just died and
in which bank from the kernel's own tag table -- race-free, and no
assembly change needed anywhere.

A subclass of TextAuditor re-poisons whichever of the five programs'
own `dum` arena (scripts/arena.arena_span(), pre-boot AND at every
retire) matches the program that just died, so `tee`'s second
invocation inherits $A5 rather than the first tee's own leftovers, and
likewise for `comm`'s seven. `cat`/`wc` are each spawned only once here
(inside the pipeline case) -- the pre-boot poison alone already covers
their single run; there is no "next run" of either to test residue
against, so no between-run claim is made for them.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from textaudit import SYMS, TextAuditor, boot, load_syms  # noqa: E402
from build_comm_image import (  # noqa: E402
    EXPECT_T1OUT, EXPECT_T1STDOUT,
    EXPECT_T2A, EXPECT_T2B,
    EXPECT_T3OUT, EXPECT_T3STDOUT,
    EXPECT_T4OUT, EXPECT_T4WC,
    EXPECT_CFULL, EXPECT_CS1, EXPECT_CS2, EXPECT_CS3, EXPECT_CS12,
    EXPECT_CIDENT, EXPECT_CEMPTY2,
)
import arena as arenamod  # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')
DISK = os.path.join(BUILD, 'comm.po')
SYMFILE = os.path.join(BUILD, 'MAUXCOMM.SYSTEM_Output.txt')
SYSBIN = os.path.join(BUILD, 'MAUXCOMM.SYSTEM')
VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')
SH_PATH = f'/{VOL}/BIN/SH'.upper()
TEE_PATH = f'/{VOL}/BIN/TEE'.upper()
COMM_PATH = f'/{VOL}/BIN/COMM'.upper()
CAT_PATH = f'/{VOL}/BIN/CAT'.upper()
WC_PATH = f'/{VOL}/BIN/WC'.upper()

POISON = 0xA5
# Banks a spawned child can land in on this image -- widened past
# tail/diff/nm's range(2,10)/(2,12): up to 5 DIFFERENT programs can
# each hold their own tagged bank at once here (tee, comm, cat, wc,
# plus sh's own parent bank 1), and the CAT|TEE|WC pipeline case can
# have three of them alive concurrently.
CAND_BANKS = range(2, 14)

OUT_FILES = {
    'T1OUT': EXPECT_T1OUT, 'T1STDOUT': EXPECT_T1STDOUT,
    'T2A': EXPECT_T2A, 'T2B': EXPECT_T2B,
    'T3OUT': EXPECT_T3OUT, 'T3STDOUT': EXPECT_T3STDOUT,
    'T4OUT': EXPECT_T4OUT, 'T4WC': EXPECT_T4WC,
    'CFULL': EXPECT_CFULL,
    'CS1': EXPECT_CS1, 'CS2': EXPECT_CS2, 'CS3': EXPECT_CS3,
    'CS12': EXPECT_CS12,
    'CIDENT': EXPECT_CIDENT, 'CEMPTY2': EXPECT_CEMPTY2,
}

# expected exit count per program -- the script's own line count (this
# file's own header): tee x4 (T1/T2/T3/the pipeline's T4), comm x7
# (full/-1/-2/-3/-12/identical/one-empty), cat x1 and wc x1 (both only
# inside the pipeline case), sh x1 (the outer shell itself).
EXPECT_COUNTS = {
    TEE_PATH: 4, COMM_PATH: 7, CAT_PATH: 1, WC_PATH: 1, SH_PATH: 1,
}
# programs spawned more than once, whose LATER runs must show the
# kernel's LZ_WARM set at their own exit (a leaf process spawns
# nothing itself, so unlike `sh`'s hazard -- check_shwarm.py's
# spawn_warm() docstring -- LZ_WARM at ITS OWN exit really does
# describe its own spawn, PROVIDED nothing else spawned in between).
REPEATED = (TEE_PATH, COMM_PATH)

# tee's 4th invocation is the one inside `CAT | TEE | WC` -- sh spawns
# all three pipeline legs back-to-back before waiting on any of them,
# so by the time THIS tee exits, `wc`'s own (first-ever, therefore
# COLD) spawn has very likely already overwritten the kernel's global
# LZ_WARM cell -- check_shwarm.py's spawn_warm() names exactly this
# hazard for a shell that spawns more than one thing; it applies here
# to any exit with a LATER sibling spawn in flight, not only to a
# shell's own exit. Measured on this tree: tee run 4 reads LZ_WARM
# clear even though it reused the SAME bank as runs 1-3 (bank-tagging
# itself, read at LZ_RETAIN, is NOT racy -- only the global flag is).
# So the warm-at-exit assertion below is skipped for run 4 specifically;
# the bank-reuse check (which does not depend on LZ_WARM at all) still
# covers it.
WARM_EXEMPT = {(TEE_PATH, 4)}


def read_files(disk):
    prodos.mount(disk)
    try:
        return {name: prodos.read(f'/mnt/{VOL}/{name}') for name in OUT_FILES}
    finally:
        prodos.unmount(VOL)


class PoisonAuditor(TextAuditor):
    """TextAuditor plus a poison-and-read-back hook at every exit.

    `arenas` maps DEVICE PATH -> (lo, span) so each program is
    re-scribbled with its OWN arena on its OWN retire.
    """

    def __init__(self, *args, arenas, **kwargs):
        super().__init__(*args, **kwargs)
        self.arenas = arenas
        self.poisoned = []       # (path, bank, back) for every poke
        self.failed_poison = []  # pokes that did not read back

    def observe_exit(self):
        before = len(self.observations)
        super().observe_exit()
        if len(self.observations) <= before:
            return
        obs = self.observations[-1]
        arena = self.arenas.get(obs.path)
        if arena is None:
            return
        lo, span = arena
        self.client.call_tool('poke', {
            'addr': lo, 'bytes': [POISON] * span,
            'bank': 'aux', 'aux_bank': obs.bank})
        back = self.peek(lo, 8, bank='aux', aux_bank=obs.bank)
        if any(b != POISON for b in back):
            self.failed_poison.append((obs.path, obs.bank, list(back)))
        self.poisoned.append((obs.path, obs.bank, list(back)))
        print(f'[check-comm] {obs.path} retired in bank {obs.bank}: '
              f'poisoned ${lo:04X}+{span} with ${POISON:02X}')


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run `make comm-image` first',
              file=sys.stderr)
        return 2

    syms = load_syms(SYMFILE, names=SYMS, binary=SYSBIN)

    prog_arenas = {
        SH_PATH: arenamod.arena_span('sh'),
        TEE_PATH: arenamod.arena_span('tee'),
        COMM_PATH: arenamod.arena_span('comm'),
        CAT_PATH: arenamod.arena_span('cat'),
        WC_PATH: arenamod.arena_span('wc'),
    }
    bins = {
        SH_PATH: 'sh.bin', TEE_PATH: 'tee.bin', COMM_PATH: 'comm.bin',
        CAT_PATH: 'cat.bin', WC_PATH: 'wc.bin',
    }
    images = {}
    for path, binname in bins.items():
        with open(os.path.join(BUILD, binname), 'rb') as f:
            images[path] = (binname[:-4], f.read())

    client = boot(disk)
    try:
        # -- LAYER 1: the pre-boot poison, read back before stepping at
        # -- all -- every one of the five programs' own arenas, since
        # -- any of them can land in any candidate bank on a cold boot.
        print('[check-comm] poisoning liba+{sh,tee,comm,cat,wc} arenas '
              f'with ${POISON:02X} in aux banks {CAND_BANKS.start}-'
              f'{CAND_BANKS.stop - 1}')
        for bank in CAND_BANKS:
            for path, (lo, span) in prog_arenas.items():
                client.call_tool('poke', {
                    'addr': lo, 'bytes': [POISON] * span,
                    'bank': 'aux', 'aux_bank': bank})
                back = client.call_tool('peek', {
                    'addr': lo, 'count': 8, 'bank': 'aux',
                    'aux_bank': bank})['bytes']
                if any(b != POISON for b in back):
                    raise RuntimeError(
                        f'pre-boot poison poke for {path} into bank '
                        f'{bank} at ${lo:04X} read back {back} -- it '
                        f'did not land')

        auditor = PoisonAuditor(client, syms, images, label='check-comm',
                                 arenas=prog_arenas)
        status = auditor.run()
        sh_status = auditor.harness_cell(0x1203)[0]
    finally:
        client.close()

    exits = auditor.observations
    by_path = {}
    for o in exits:
        by_path.setdefault(o.path, []).append(o)

    print(f'[check-comm] done=${status["done"]:02X} err=${status["err"]:02X} '
          f'step={status["step"]} sh_status=${sh_status:02X} total_exits='
          f'{len(exits)}')
    print(f'[check-comm] exits={[(o.path, o.bank, o.warm) for o in exits]}')

    failures = []
    if status['done'] != 0xAA:
        failures.append(
            f'test did not finish successfully (done=${status["done"]:02X} '
            f'err=${status["err"]:02X} step={status["step"]})')
    if sh_status != 0:
        failures.append(f'sh exit status expected $00, got ${sh_status:02X}')

    # -- VACUITY GUARDS --
    if exits and exits[-1].path != SH_PATH:
        failures.append(
            f'expected the LAST process exit to be `sh` (the outer '
            f'shell, alive until the script finishes); last was '
            f'{exits[-1].path if exits else None}')
    for path, expect_n in EXPECT_COUNTS.items():
        got_n = len(by_path.get(path, []))
        if got_n != expect_n:
            failures.append(
                f'expected exactly {expect_n} process exit(s) for {path}, '
                f'saw {got_n} -- the script issues {expect_n}; fewer '
                f'means one never ran')
    for path in (TEE_PATH, COMM_PATH, CAT_PATH, WC_PATH, SH_PATH):
        for o in by_path.get(path, []):
            if o.bank not in CAND_BANKS:
                failures.append(
                    f'{path} exit in bank {o.bank} is outside the '
                    f'poisoned range {CAND_BANKS.start}-'
                    f'{CAND_BANKS.stop - 1}, so this run did not '
                    f'exercise its uncleared arena at all. Widen '
                    f'CAND_BANKS.')
    for path in REPEATED:
        banks = [o.bank for o in by_path.get(path, [])]
        if banks and len(set(banks)) != 1:
            failures.append(
                f'{path}\'s {len(banks)} runs did not share one bank '
                f'({banks}) -- a pid IS its bank, so the retained bank '
                f'was NOT reused and the between-run poison went '
                f'somewhere a later run never touched. The gate is '
                f'vacuous in that state, not merely weaker.')
        for i, o in enumerate(by_path.get(path, []), start=1):
            if i == 1:
                continue  # run 1 is necessarily cold -- nothing tagged yet
            if (path, i) in WARM_EXEMPT:
                print(f'[check-comm] {path} run {i} (bank {o.bank}): '
                      f'LZ_WARM={o.warm} not asserted -- exempted, see '
                      f'WARM_EXEMPT\'s own comment (concurrent pipeline '
                      f'spawn contaminates the global flag)')
                continue
            if not o.warm:
                failures.append(
                    f'{path} run {i} (bank {o.bank}) exited with '
                    f'LZ_WARM clear -- it was NOT served from a '
                    f'retained bank, so this run\'s poison never met a '
                    f'warm respawn')
    if not auditor.poisoned:
        failures.append(
            'the poison never fired: no process exit was observed at all')
    for path, bank, back in auditor.failed_poison:
        failures.append(
            f'{path} retired in bank {bank}: the ${POISON:02X} poke read '
            f'back {back} -- it did not land, so the run after it proved '
            f'nothing')

    if failures:
        for failure in failures:
            print(f'[check-comm] FAIL: {failure}', file=sys.stderr)
        return 1

    files = read_files(disk)
    for name, expected in OUT_FILES.items():
        got = files[name]
        if got != expected:
            print(f'[check-comm] FAIL: {name} expected {expected!r}, '
                  f'got {got!r}', file=sys.stderr)
            return 1

    tee_bank = by_path[TEE_PATH][0].bank
    comm_bank = by_path[COMM_PATH][0].bank
    print('[check-comm] PASS: tee copied stdin to stdout AND to one '
          'file, to two files, and appended (-a) without truncating '
          'a pre-existing file, all while stdout kept flowing '
          'through a real 3-stage pipeline (CAT|TEE|WC); comm '
          'produced all three columns unsuppressed, each of -1/-2/'
          '-3 suppressed only its own column, -12 left only column '
          '3, identical files landed everything in column 3, and '
          'one empty file landed everything in column 1 -- every '
          'result file byte-exact, with all five programs\' own '
          f'arenas pre-filled with ${POISON:02X} in every candidate '
          f'bank AND re-scribbled at every retire -- tee\'s 4 runs '
          f'all reused bank {tee_bank}, comm\'s 7 runs all reused '
          f'bank {comm_bank}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
