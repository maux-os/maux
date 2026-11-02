#!/usr/bin/env python3
"""Boot and verify the `nm` acceptance gate (`make check-nm`).

Companion to src/test/nmtest.s / src/test/nmtestb.s /
scripts/build_nm_image.py.

`sh` (stdin redirected from the staged script) runs six `nm` invocations
against the two REAL REL files build_nm_image.py stages (RTLIB, RTMAIN --
see that module's header for the byte-level provenance), then `EXIT`. The
result files are read back off the disk image and compared BYTE-EXACT
against the EXPECT_* constants below -- the same "read the ProDOS files
back in Python" mechanism scripts/check_sh.py uses for EDITED/CATOUT.

EVERY EXPECT_* CONSTANT IS DERIVED BY HAND FROM THE REL FILES' OWN BYTES,
NOT BY RUNNING nm AND RECORDING WHAT IT PRINTED (task ruling -- that would
enshrine bugs as the contract):

  RTLIB's dictionary (see build_nm_image.py's own header for the exact
  bytes): ENT "LIBUSED" at module-relative offset $0000, ENT "LIBUNUSED"
  at offset $0003. Both are Merlin ENT exports -> nm's type letter X.
  Sorted by name: "LIBUNUSED" < "LIBUSED" (5th char 'N' < 'S', a plain
  ASCII compare) -- LIBUNUSED prints first.

  RTMAIN's dictionary: one EXT reference, "LIBUSED" -- undefined here,
  so ADDR is 4 spaces and the type letter is U.

THE POISON (docs/STICKY.md sec 25/28/37). `nmtestb.s`'s PARENT_PROC
makes exactly ONE direct spawn -- `sh` -- so there is no PARENT_PROC-side
WAIT_GO handshake to add (`sh`, `nm` are both `src/bin` and contended;
this gate cannot and should not add a park to either). `sh` itself is
what spawns `nm` six times, sequentially, waiting for each to exit
before the next -- so the bank-reuse trap (docs/STICKY.md sec 37: "every
run after the first executes WARM in run 1's bank") applies to `nm`
just as it does to a directly-spawned program, only the parent doing
the reuse-preferring spawn is `sh`, not this harness.

So this uses scripts/textaudit.py's TextAuditor instead of a hand-rolled
R_GO park: it stops the CPU at the KERNEL's own LZ_RETAIN entry (reached
once per process exit, BEFORE the kernel decides whether to retain the
bank -- textaudit.py's own header explains why this is race-free where a
step-and-poll driver is not) and identifies which PROGRAM just died and
in which bank from the kernel's own tag table -- no assembly change
needed in nmtestb.s, sh.s, or nm.s. scripts/check_shwarm.py already
established this exact technique for the `sh`-vs-`sh` repeat pair; this
subclasses the same TextAuditor to poison whichever of `sh`/`nm`'s own
`dum` arena (scripts/arena.arena_span(), pre-boot AND at every retire)
matches the program that just died.

Layer 1, PRE-BOOT: liba+`sh`'s arena AND liba+`nm`'s arena are $A5-filled
in every candidate child bank, read back to confirm before stepping.
Layer 2, BETWEEN RUNS: at every process exit textaudit's LZ_RETAIN stop
observes, this re-scribbles THAT program's own arena in the bank that
just died, reads it back, and continues -- so by the time `sh` issues
the SECOND `nm` line, the bank it reuses (a pid IS its bank) already
carries $A5, not the first nm's own leftovers.

Vacuity guards: exactly 7 process exits in order (6 `nm`, then `sh`),
all 6 `nm` exits sharing ONE bank, every poison poke read back, `nm`
runs 2-6 each showing the kernel's LZ_WARM set AT THAT EXIT (nm is a
leaf process -- it spawns nothing itself, so unlike `sh`'s own
warm-reading hazard (check_shwarm.py's spawn_warm() docstring), LZ_WARM
at nm's own exit really does describe nm's own spawn), and every
poisoned bank inside the poisoned range.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from textaudit import SYMS, TextAuditor, boot, load_syms  # noqa: E402
import arena as arenamod  # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')
DISK = os.path.join(BUILD, 'nm.po')
SYMFILE = os.path.join(BUILD, 'MAUXNM.SYSTEM_Output.txt')
SYSBIN = os.path.join(BUILD, 'MAUXNM.SYSTEM')
VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')
SH_PATH = f'/{VOL}/BIN/SH'.upper()
NM_PATH = f'/{VOL}/BIN/NM'.upper()

POISON = 0xA5
# Banks a spawned child can land in on this image. Poisoned wholesale
# rather than predicted, and asserted afterwards against the banks the
# runs actually used (check_ls.py's own vacuity guard).
CAND_BANKS = range(2, 12)


def hitext(s):
    return bytes(ord(c) | 0x80 for c in s)


CR = bytes([0x8D])


def line(s):
    return hitext(s) + CR


# NM1OUT: `nm /mnt/MAUX/RTLIB` -- one file, no "file:" header.
EXPECT_NM1OUT = line('0003 X LIBUNUSED') + line('0000 X LIBUSED')

# NM2OUT: `nm /mnt/MAUX/RTLIB /mnt/MAUX/RTMAIN` -- two files, headers, a
# blank line between blocks (this file's own documented format).
EXPECT_NM2OUT = (
    line('/mnt/MAUX/RTLIB:') +
    line('0003 X LIBUNUSED') +
    line('0000 X LIBUSED') +
    CR +
    line('/mnt/MAUX/RTMAIN:') +
    # 5 leading spaces: the 4-char ADDR field (all spaces, since
    # LIBUSED is undefined here) plus the ADDR/TYPE separator space.
    line('     U LIBUSED')
)

# NM3OUT: `nm -u /mnt/MAUX/RTMAIN` -- RTMAIN's only symbol IS undefined,
# so -u passes it through unchanged (same line as inside NM2OUT).
EXPECT_NM3OUT = line('     U LIBUSED')

# NM4OUT: `nm -g /mnt/MAUX/RTMAIN` -- RTMAIN's only symbol is undefined,
# so -g (global/defined only) filters it out entirely: EMPTY.
EXPECT_NM4OUT = b''

# NM5OUT: `nm -u /mnt/MAUX/RTLIB` -- RTLIB's two symbols are both ENT
# (defined), so -u (undefined only) filters both out: EMPTY.
EXPECT_NM5OUT = b''

# NM6OUT: `nm -g /mnt/MAUX/RTLIB` -- both of RTLIB's symbols are ENT, so
# -g passes both through unchanged: identical to NM1OUT.
EXPECT_NM6OUT = EXPECT_NM1OUT

OUT_FILES = {
    'NM1OUT': EXPECT_NM1OUT,
    'NM2OUT': EXPECT_NM2OUT,
    'NM3OUT': EXPECT_NM3OUT,
    'NM4OUT': EXPECT_NM4OUT,
    'NM5OUT': EXPECT_NM5OUT,
    'NM6OUT': EXPECT_NM6OUT,
}


def read_prodos_files(disk):
    prodos.mount(disk)
    try:
        out = {}
        for name in OUT_FILES:
            try:
                out[name] = prodos.read(f'/mnt/{VOL}/{name}')
            except FileNotFoundError:
                out[name] = None
        return out
    finally:
        prodos.unmount(VOL)


class PoisonAuditor(TextAuditor):
    """TextAuditor plus a poison-and-read-back hook at every exit.

    `arenas` maps DEVICE PATH -> (lo, span) so each program is
    re-scribbled with its OWN arena on its OWN retire -- poisoning `sh`
    with `nm`'s span (or vice versa) would prove nothing about either.
    """

    def __init__(self, *args, arenas, on_exit=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.arenas = arenas
        self.on_exit = on_exit
        self.poisoned = []       # (path, bank, back) for every poke
        self.failed_poison = []  # pokes that did not read back

    def observe_exit(self):
        before = len(self.observations)
        super().observe_exit()
        if len(self.observations) <= before:
            return
        obs = self.observations[-1]
        arena = self.arenas.get(obs.path)
        if arena is not None:
            lo, span = arena
            self.client.call_tool('poke', {
                'addr': lo, 'bytes': [POISON] * span,
                'bank': 'aux', 'aux_bank': obs.bank})
            back = self.peek(lo, 8, bank='aux', aux_bank=obs.bank)
            if any(b != POISON for b in back):
                self.failed_poison.append((obs.path, obs.bank, list(back)))
            self.poisoned.append((obs.path, obs.bank, list(back)))
            print(f'[check-nm] {obs.path} retired in bank {obs.bank}: '
                  f'poisoned ${lo:04X}+{span} with ${POISON:02X}')
        if self.on_exit:
            self.on_exit(obs)


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run `make nm-image` first',
              file=sys.stderr)
        return 2

    syms = load_syms(SYMFILE, names=SYMS, binary=SYSBIN)

    sh_arena = arenamod.arena_span('sh')
    nm_arena = arenamod.arena_span('nm')
    arenas = {SH_PATH: sh_arena, NM_PATH: nm_arena}

    with open(os.path.join(BUILD, 'sh.bin'), 'rb') as f:
        sh_image = f.read()
    with open(os.path.join(BUILD, 'nm.bin'), 'rb') as f:
        nm_image = f.read()
    images = {SH_PATH: ('sh', sh_image), NM_PATH: ('nm', nm_image)}

    warm_by_exit = []

    def on_exit(obs):
        warm_by_exit.append((obs.path, obs.warm))

    client = boot(disk)
    try:
        # -- LAYER 1: the pre-boot poison, read back before stepping at
        # -- all -- both `sh`'s arena and `nm`'s, since either program
        # -- can land in any candidate bank on a cold boot.
        print(f'[check-nm] poisoning liba+sh arena ${sh_arena[0]:04X}+'
              f'{sh_arena[1]} AND liba+nm arena ${nm_arena[0]:04X}+'
              f'{nm_arena[1]} with ${POISON:02X} in aux banks '
              f'{CAND_BANKS.start}-{CAND_BANKS.stop - 1}')
        for bank in CAND_BANKS:
            for lo, span in (sh_arena, nm_arena):
                client.call_tool('poke', {
                    'addr': lo, 'bytes': [POISON] * span,
                    'bank': 'aux', 'aux_bank': bank})
                back = client.call_tool('peek', {
                    'addr': lo, 'count': 8, 'bank': 'aux',
                    'aux_bank': bank})['bytes']
                if any(b != POISON for b in back):
                    raise RuntimeError(
                        f'pre-boot poison poke into bank {bank} at '
                        f'${lo:04X} read back {back} -- it did not land')

        auditor = PoisonAuditor(client, syms, images, label='check-nm',
                                 arenas=arenas, on_exit=on_exit)
        status = auditor.run()
        sh_status = auditor.harness_cell(0x1203)[0]
    finally:
        client.close()

    exits = auditor.observations
    nm_exits = [o for o in exits if o.path == NM_PATH]
    sh_exits = [o for o in exits if o.path == SH_PATH]

    print(f'[check-nm] done=${status["done"]:02X} err=${status["err"]:02X} '
          f'step={status["step"]} sh_status=${sh_status:02X} '
          f'exits={[(o.path, o.bank, o.warm) for o in exits]}')

    failures = []
    if status['done'] != 0xAA:
        failures.append(
            f'test did not finish successfully (done=${status["done"]:02X} '
            f'err=${status["err"]:02X} step={status["step"]})')
    if sh_status != 0:
        failures.append(f'sh exit status expected $00, got ${sh_status:02X}')

    # -- VACUITY GUARDS --
    if len(nm_exits) != 6:
        failures.append(
            f'expected exactly 6 `nm` process exits, saw {len(nm_exits)} '
            f'({[o.bank for o in nm_exits]}) -- the script issues 6 NM '
            f'lines; fewer means one never ran')
    if len(sh_exits) != 1:
        failures.append(
            f'expected exactly 1 `sh` process exit, saw {len(sh_exits)}')
    if exits and exits[-1].path != SH_PATH:
        failures.append(
            f'expected the LAST process exit to be `sh` (it is the '
            f'outer shell, alive until the script finishes); last was '
            f'{exits[-1].path if exits else None}')
    nm_banks = [o.bank for o in nm_exits]
    if nm_banks:
        for i, bank in enumerate(nm_banks, start=1):
            if bank not in CAND_BANKS:
                failures.append(
                    f'nm run {i}: bank {bank} is outside the poisoned '
                    f'range {CAND_BANKS.start}-{CAND_BANKS.stop - 1}, so '
                    f'this run did not exercise nm\'s uncleared arena at '
                    f'all. Widen CAND_BANKS.')
        if len(set(nm_banks)) != 1:
            failures.append(
                f'the 6 nm runs did not share one bank ({nm_banks}) -- a '
                f'pid IS its bank, so this means the retained bank was '
                f'NOT reused and the between-run poison went somewhere '
                f'the next nm invocation never touched. The gate is '
                f'vacuous in that state, not merely weaker.')
    # nm is a leaf process (spawns nothing), so LZ_WARM at ITS OWN exit
    # really does describe its own spawn -- unlike `sh`'s hazard
    # (check_shwarm.py's spawn_warm() docstring). Runs 2-6 are exactly
    # the ones that should have been served from the bank run 1 tagged.
    for i, o in enumerate(nm_exits, start=1):
        if i == 1:
            continue
        if not o.warm:
            failures.append(
                f'nm run {i} (bank {o.bank}) exited with LZ_WARM clear -- '
                f'it was NOT served from a retained bank, so this run\'s '
                f'poison never met a warm respawn')
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
            print(f'[check-nm] FAIL: {failure}', file=sys.stderr)
        return 1

    files = read_prodos_files(disk)
    for name, expected in OUT_FILES.items():
        got = files[name]
        if got is None:
            print(f'[check-nm] FAIL: {name} was never created', file=sys.stderr)
            return 1
        if got != expected:
            print(f'[check-nm] FAIL: {name} expected {expected!r}, '
                  f'got {got!r}', file=sys.stderr)
            return 1

    print('[check-nm] PASS: nm, spawned via sh against two REAL REL '
          'files, printed byte-exact symbol tables -- sorted order, '
          'the ENT->X/EXT->U type mapping, module-relative ADDR, the '
          'multi-file "path:" header with a blank-line separator, '
          'and -u/-g filtering (including both filtered-to-empty '
          f'cases) all matched hand-derived expectations, with liba\'s '
          f'arena AND nm\'s own (${nm_arena[0]:04X}+{nm_arena[1]}) '
          f'pre-filled with ${POISON:02X} in every candidate bank AND '
          f're-scribbled at each of the 6 nm exits into bank '
          f'{nm_banks[0]}, which every nm invocation reused')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
