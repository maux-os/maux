#!/usr/bin/env python3
"""The runtime writable-text gate (`make check-textaudit`).

Companion to scripts/textaudit.py (the observer -- read its header for
the method and the three outcome classes), scripts/build_textaudit_
image.py (the workloads), and docs/STICKY.md sec 29.

TWO QUESTIONS, and the second is the one that matters.

  (1) DOES THE PROGRAM WRITE ITS OWN TEXT? Measured by stopping the
      kernel on its own retire path (LZ_RETAIN) at every process exit
      and diffing the dying bank's image against the .bin on disk.
      Answer, 2026-08-22: thirty-one of thirty-three do. That is not
      the disaster it sounds like -- `ls` has written its own image
      since long before lazy free -- but it does mean the entry-head
      check is the ONLY thing between the fleet and a stale image, and
      it covers 8 bytes.

  (2) DOES THE PROGRAM STILL WORK WHEN ITS BANK COMES BACK? Measured
      by running each command TWICE, byte-identical arguments,
      adjacently, and requiring the two outputs to match. Run 1 is the
      expectation, so this needs no per-program golden data and cannot
      rot the way one would. It is the repeat-with-identical-arguments
      shape from learning:01M0MEKF0H8AVAXJG4PZ7P5QXC, applied to the
      whole fleet instead of to `ls` alone.

WHAT IT ASSERTS, in the order that matters:

  0. VACUITY FIRST. Every program the image staged must have been
     observed exiting; every paired program must have been observed
     WARM at least once (otherwise the repeat ran cold and proved
     nothing); the harness must report $AA.
  1. Every repeat pair matches -- except the programs in
     check_purity.WARM_UNSAFE, which must still DIFFER, so that fixing
     one turns this gate red and forces the entry out.
  2. The measured text verdict matches the DECLARATION in
     scripts/check_purity.py (TEXT_IMMUTABLE / TEXT_MUTABLE, and the
     entry-head bit), in both directions.

THE POISON (2026-08-23, docs/STICKY.md sec 25/28/37, the technique
check_ls.py/check_find.py already prove out -- learning:
01M0M9R7RT22JEPP2R0Y6J9MBX). Until this pass, this gate ran every
program functionally and never poisoned anything: a freshly spawned
bank may already be zero, and zero is exactly the value a read-
before-write bug needs to look correct. Twenty-three converted
programs had a repeat pair and no poison; this closes that in the one
place that already boots the whole fleet, rather than as 23 separate
per-program gates.

TWO LAYERS, same shape as check_ls.py/check_find.py:

  LAYER 1 (pre-boot): every candidate bank's uncleared region is
  filled with $A5 before the machine boots at all -- see
  preboot_poison()'s own docstring for why ONE broad range per bank
  is provably equivalent to poisoning each program's own span
  separately (a cold spawn always recopies its own text fresh, no
  matter which program lands in the bank).

  LAYER 2 (between runs): lazy free prefers a bank already tagged
  with the program being spawned, so every run after a program's
  FIRST executes WARM in the bank its own previous run left behind --
  a pre-boot poison alone is consumed by that first run, and run 2
  proves nothing (docs/STICKY.md sec 37's own measurement,
  `spawn_pid=[2,2,...]`). This gate does not need a new WAIT_GO
  handshake to land the between-run poison strictly between two runs:
  textaudit.TextAuditor already stops the CPU dead on the kernel's own
  LZ_RETAIN retire path once per process exit (`until_pc`, not a
  step-and-poll race), which is exactly the rendezvous point check_
  shwarm.py uses for the same purpose. PoisonAuditor below hooks that
  stop and scribbles the JUST-RETIRED bank's arena before stepping
  off the breakpoint and letting anything else run.

WHICH PROGRAMS. Every program with a derivable `dum` arena --
scripts/arena.py's arena_span(), the general derivation this stream
exists to make possible instead of hand-adding 26 more `<PROG>_
BSSEND` labels. `as` and `expr` have NO `dum` arena at all (genuinely
unconverted) and are skipped EXPLICITLY -- see NO_ARENA below -- not
silently: they are still audited for text mutation, just never
poisoned.

VACUITY GUARDS, mandatory (learning:01M0M9R7RT22JEPP2R0Y6J9MBX's own
rule -- a gate that inspects memory nobody touched passes forever):
every poke, pre-boot AND between-run, is read back and a mismatch
FAILS loudly (check_ls.py's own pre-boot poke has no such read-back;
this gate does not repeat that gap); every retiring bank must be
inside CAND_BANKS; the between-run poison list must be non-empty per
group.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from arena import arena_span  # noqa: E402
from textaudit import TextAuditor, boot, load_syms, runs_of  # noqa: E402
from build_textaudit_image import (  # noqa: E402
    EMPTY_OUTPUT_OK, GROUP_BINS, expected_paths, image_path, repeat_pairs,
    unpaired)
from check_purity import (  # noqa: E402
    TEXT_IMMUTABLE, TEXT_MUTABLE, TEXT_MUTABLE_NOTES, TEXT_UNAUDITED,
    WARM_UNSAFE)

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')
SYMFILE = os.path.join(BUILD, 'MAUXSH.SYSTEM_Output.txt')
SYSBIN = os.path.join(BUILD, 'MAUXSH.SYSTEM')
VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')

POISON = 0xA5
# Banks a spawned child can land in on these images -- bank 1 is the
# parent (shtestb.s's PARENT_PROC), bank 0 the lazy-free path annex.
# `reset` defaults to 16 aux banks (mcp_server.cpp), so 2-15 is every
# bank a child CAN land in -- unlike check_ls.py/check_shwarm.py's
# single spawned child, one of these groups' scripts tags a distinct
# bank per DISTINCT PROGRAM (13 in group a alone), so the narrower
# ranges those single-program gates use are not wide enough here;
# measured banks up to 15 on a real run before this was widened.
# Poisoned wholesale rather than predicted, and asserted afterwards
# against the banks the runs actually used (check_ls.py's own
# vacuity guard).
CAND_BANKS = range(2, 16)
# `$BF00` is PRC_BRK_LIM, the top of the process window every
# converted program's own `err */$BF00` (or `err */BUILDBASE`, `ld`'s
# variant) tripwire enforces. Never hardcoded past this one spot --
# see preboot_poison()'s docstring for why a single constant ceiling
# is safe here even though it is not read from a symbol table: it is
# the same architectural ceiling every program's OWN assembly-time
# assertion already depends on, not a fact about any one binary.
PROC_WINDOW_TOP = 0xBF00
# `expr` WAS here: genuinely unconverted, no `dum` arena. It got one
# 2026-10-08 (expr.match.s's scratch, chained at REGEX_BSSEND) and so
# left this set: a program with an arena is poisoned like any other.
#
# `as` USED TO be here too (docs/STICKY.md sec 28's own finding), but
# stream T5 gave it a real `dum LIBA_BSSEND`/`dend` block (BLOBSIG,
# CHKBLOB/STAMPHEAD's own backstop cell) so its warm respawn could be
# proven safe the same way every other converted program's is. Its
# entry head no longer moves either (check_purity.TEXT_MUTABLE['as']
# is now False) -- both changes are the SAME landing, not a
# coincidence: the arena is what CHKBLOB reads to decide whether to
# force a cold reload.
NO_ARENA = set()


def program_arenas(names):
    """{name: (start, length)} for every program with a `dum` arena,
    via scripts/arena.py's arena_span() -- never hand-maintained.
    Returns (arenas, skipped) so a caller can log the skip loudly.
    """
    arenas = {}
    skipped = sorted(n for n in names if n in NO_ARENA)
    for name in sorted(names):
        if name in NO_ARENA:
            continue
        arenas[name] = arena_span(name)
    return arenas, skipped


def poke_span(client, bank, addr, length, value, chunk=4096):
    """$A5-fill `length` bytes at `addr` in `bank`, chunked so no
    single `poke` call carries an enormous byte array (the pre-boot
    layer's span can run past 40 KB)."""
    remaining = length
    a = addr
    while remaining > 0:
        n = min(chunk, remaining)
        client.call_tool('poke', {
            'addr': a, 'bytes': [value] * n, 'bank': 'aux', 'aux_bank': bank,
        })
        a += n
        remaining -= n


def preboot_poison(client, arenas):
    """LAYER 1 -- fill every candidate bank with $A5 before boot.

    ONE range per bank, MIN_START..PROC_WINDOW_TOP, rather than one
    poke per program's own span. The two are provably equivalent for
    this gate's purpose: a COLD spawn always recopies its OWN text
    fresh, from LOAD_BASE up to its OWN LIBA_ZPG -- so for ANY program
    that ends up in a poisoned bank, every byte below that program's
    own LIBA_ZPG is inside ITS OWN text and gets overwritten regardless
    of what this poke left there, and every byte from its own LIBA_ZPG
    up to PROC_WINDOW_TOP is inside ITS OWN arena and stays exactly
    what this poke wrote. MIN_START (the smallest LIBA_ZPG across every
    program this gate knows about) is the lowest address any program's
    arena can start at, so the single range covers all of them without
    knowing in advance which program lands in which bank.
    """
    start = min(s for s, _ in arenas.values())
    length = PROC_WINDOW_TOP - start
    for bank in CAND_BANKS:
        poke_span(client, bank, start, length, POISON)
    return start, length


def verify_preboot(client, start, length):
    """Read back the head AND tail of the pre-boot span in every
    candidate bank -- a poke that silently did not land must not pass
    (learning:01M0M9R7RT22JEPP2R0Y6J9MBX's vacuity rule; check_ls.py's
    own pre-boot poke skips exactly this check, which this gate does
    not repeat)."""
    failures = []
    for bank in CAND_BANKS:
        head = client.call_tool('peek', {
            'addr': start, 'count': 8, 'bank': 'aux', 'aux_bank': bank,
        })['bytes']
        if any(b != POISON for b in head):
            failures.append(
                f'pre-boot poison into bank {bank} at ${start:04X} read '
                f'back as {list(head)} -- it did not land')
        tail_addr = start + length - 8
        tail = client.call_tool('peek', {
            'addr': tail_addr, 'count': 8, 'bank': 'aux', 'aux_bank': bank,
        })['bytes']
        if any(b != POISON for b in tail):
            failures.append(
                f'pre-boot poison into bank {bank} at ${tail_addr:04X} '
                f'(near the process window top) read back as '
                f'{list(tail)} -- it did not land')
    return failures


class PoisonAuditor(TextAuditor):
    """textaudit's observer plus THE BETWEEN-RUN POISON (LAYER 2).

    Hooked at the same LZ_RETAIN stop textaudit.TextAuditor.run()
    already uses to observe every process exit -- the CPU is dead
    stopped there, before the kernel decides whether to retain the
    bank and before anything else can touch it, so the scribble lands
    strictly between this run's death and whatever spawns next
    (check_shwarm.py's own justification for the same rendezvous). No
    WAIT_GO handshake and no new assembly are needed: `until_pc` on a
    real kernel address already IS the rendezvous.
    """

    def __init__(self, *args, arenas, poison_log, **kwargs):
        super().__init__(*args, **kwargs)
        self.arenas = arenas
        self.poison_log = poison_log

    def observe_exit(self):
        before = len(self.observations)
        super().observe_exit()
        if len(self.observations) <= before:
            return
        obs = self.observations[-1]
        name = self.images[obs.path][0]
        span = self.arenas.get(name)
        if span is None:
            return                       # as/expr -- NO_ARENA, skip
        start, length = span
        poke_span(self.client, obs.bank, start, length, POISON)
        back = self.peek(start, 8, bank='aux', aux_bank=obs.bank)
        landed = all(b == POISON for b in back)
        self.poison_log.append((name, obs.bank, landed, list(back)))


class Verdict:
    __slots__ = ('name', 'runs', 'length', 'dirty', 'head_moved', 'diffs',
                 'warm', 'broken')

    def __init__(self, name):
        self.name = name
        self.runs = 0
        self.length = 0
        self.dirty = 0
        self.head_moved = False
        self.diffs = set()
        self.warm = 0
        self.broken = []


def read_outputs(disk, wanted):
    """The paired output files, straight off the mutated .po."""
    out = {}
    prodos.mount(disk)
    try:
        for path in wanted:
            try:
                out[path] = prodos.read(path)
            except FileNotFoundError:
                out[path] = None
    finally:
        prodos.unmount(VOL)
    return out


def audit_group(group, verdicts, failures, arenas, poison_totals):
    disk = image_path(group)
    if not os.path.exists(disk):
        raise RuntimeError(f'{disk} not found -- run make textaudit-image')
    syms = load_syms(SYMFILE, binary=SYSBIN)
    paths = expected_paths(group)
    images = {}
    for path, name in paths.items():
        with open(os.path.join(BUILD, f'{name}.bin'), 'rb') as f:
            images[path] = (name, f.read())
    client = boot(disk)
    try:
        # -- LAYER 1: the pre-boot poison (this file's header).
        pre_start, pre_len = preboot_poison(client, arenas)
        print(f'[check-textaudit] group {group}: pre-boot poisoned aux '
              f'banks {CAND_BANKS.start}-{CAND_BANKS.stop - 1} at '
              f'${pre_start:04X}+{pre_len} (effective '
              f'{pre_len - 256} past the kernel-zeroed page) with '
              f'${POISON:02X}', file=sys.stderr)
        failures.extend(verify_preboot(client, pre_start, pre_len))

        # -- LAYER 2: the between-run poison, fired at every process
        # -- exit via PoisonAuditor.observe_exit() (this file's
        # -- header explains the LZ_RETAIN rendezvous).
        poison_log = []
        auditor = PoisonAuditor(client, syms, images,
                                label=f'check-textaudit {group}',
                                arenas=arenas, poison_log=poison_log)
        status = auditor.run()
    finally:
        client.close()

    bad_poison = [(n, b, back) for n, b, ok, back in poison_log if not ok]
    for name, bank, back in bad_poison:
        failures.append(
            f'group {group}: the ${POISON:02X} arena poke into bank {bank} '
            f'after {name} retired read back as {back} -- it did not land, '
            f'so whatever ran next in that bank proved nothing about '
            f'uninitialised reads')
    off_range = sorted({(n, b) for n, b, ok, back in poison_log
                        if b not in CAND_BANKS})
    for name, bank in off_range:
        failures.append(
            f'group {group}: {name} retired in bank {bank}, outside the '
            f'poisoned range {CAND_BANKS.start}-{CAND_BANKS.stop - 1} -- '
            f'this exit was never poisoned pre-boot either. Widen '
            f'CAND_BANKS.')
    if not poison_log:
        failures.append(
            f'group {group}: the between-run poison never fired -- no '
            f'arena-bearing program was observed exiting at all')
    print(f'[check-textaudit] group {group}: between-run poison fired at '
          f'{len(poison_log)} exit(s) ({len(bad_poison)} failed read-back)')
    poison_totals[group] = poison_log

    seen = set()
    for obs in auditor.observations:
        name = images[obs.path][0]
        v = verdicts.setdefault(name, Verdict(name))
        seen.add(name)
        v.runs += 1
        if obs.warm:
            v.warm += 1
        if obs.diffs is None:
            v.broken.append(
                f'group {group}: the kernel tagged {obs.path} with an image '
                f'length of {obs.length} B but build/{name}.bin is '
                f'{len(images[obs.path][1])} B -- the audit would be '
                f'comparing against the wrong bytes')
            continue
        v.length = obs.length
        if obs.diffs:
            v.dirty += 1
            v.diffs.update(obs.diffs)
            v.head_moved = v.head_moved or obs.head_moved

    if status['done'] != 0xAA:
        failures.append(
            f'group {group}: the harness did not finish (done='
            f'${status["done"]:02X} err=${status["err"]:02X} '
            f'step={status["step"]}). Nothing this run measured can be '
            f'trusted.')
    missing = sorted(set(paths.values()) - seen)
    if missing:
        failures.append(
            f'group {group}: {missing} were staged but never observed '
            f'exiting. Either the script does not run them or the audit '
            f'stopped early -- an unrun program is not a clean one.')
    if auditor.unknown_paths:
        failures.append(
            f'group {group}: banks were retired holding programs the audit '
            f'has no image for: {sorted(set(auditor.unknown_paths))}')
    if auditor.untagged:
        print(f'[check-textaudit] group {group}: {auditor.untagged} untagged '
              f'bank retire(s) -- a spawn that never got a tag (reported, '
              f'not fatal)')

    # -- the warm repeat --------------------------------------------
    pairs = repeat_pairs(group)
    outputs = read_outputs(disk, sorted({p for _, a, b in pairs
                                         for p in (a, b)}))
    print(f'[check-textaudit] group {group}: {len(pairs)} repeat pair(s) '
          f'-- the same command twice, adjacently, second run served warm')
    for name, first, second in pairs:
        a, b = outputs[first], outputs[second]
        broken = name in WARM_UNSAFE
        if a is None:
            failures.append(
                f'group {group}: {name}\'s FIRST run produced no {first} at '
                f'all -- the workload is wrong, not the program')
            continue
        same = (a == b)
        if same and broken:
            failures.append(
                f'{name} is in check_purity.WARM_UNSAFE but its warm repeat '
                f'now reproduces the cold run byte for byte ({first} == '
                f'{second}, {len(a)} B). If it was fixed, remove the entry; '
                f'a ratchet that records only bad news that is no longer '
                f'true is a lie.')
        elif not same and not broken:
            got = 'no output file at all' if b is None else f'{len(b)} B'
            failures.append(
                f'{name}: the SECOND run of `{name}` -- same arguments, '
                f'served warm out of the bank the first run left behind -- '
                f'did not reproduce the first. {first} is {len(a)} B, '
                f'{second} is {got}. This is docs/STICKY.md sec 27\'s '
                f'residual arriving: the program\'s text was reused without '
                f'being recopied and it read a cell it did not write this '
                f'run.')
        elif not same and broken:
            got = 'no output file' if b is None else f'{len(b)} B'
            print(f'   {name:<10} WARM-UNSAFE as declared: {first} '
                  f'{len(a)} B vs {second} {got}')
    # EVERY PAIRED PROGRAM MUST PRODUCE SOMETHING SOMEWHERE. Two empty
    # files compare equal, so a command that never ran at all -- a
    # typo, or a pipeline whose first stage is "command not found",
    # which still spawns the second stage -- passes its pair silently.
    # An empty output can be legitimate for ONE case (`grep zzz`,
    # `cmp` on identical files), so the rule is per PROGRAM, not per
    # pair: at least one of a program's first runs wrote bytes.
    produced = {}
    for name, first, _ in pairs:
        produced[name] = produced.get(name, 0) + len(outputs[first] or b'')
    for name, total in sorted(produced.items()):
        if total == 0 and name in EMPTY_OUTPUT_OK:
            print(f'   {name:<10} empty output by design: '
                  f'{EMPTY_OUTPUT_OK[name]}')
        elif total == 0:
            failures.append(
                f'group {group}: every first run of `{name}` produced an '
                f'EMPTY file. Two empty files compare equal, so its repeat '
                f'pair is passing vacuously -- check the command line '
                f'actually runs.')

    for name in sorted(set(paths.values()) | {'sh'}):
        if name in {p for p, _, _ in pairs}:
            continue
        why = unpaired(group).get(name)
        if why is None:
            failures.append(
                f'group {group}: {name} runs but has no repeat pair and no '
                f'stated reason. Every program either proves its warm '
                f'respawn or says why it cannot -- add a PAIR or an ONCE '
                f'to build_textaudit_image.STEPS.')
        else:
            print(f'   {name:<10} not paired: {why}')
    for name in sorted({p for p, _, _ in pairs}):
        v = verdicts.get(name)
        if v and v.head_moved:
            # A program whose entry head moves is REFUSED retention by
            # LZ_RETAIN, so it can never be warm and this guard would
            # be unsatisfiable. Its repeat pair is still worth running
            # -- it proves the cold path survives the previous run's
            # leftovers in the same bank -- but the warm claim is not
            # one it can make. Nothing in the tree is declared
            # head=True any more as of stream T5 (`as` was the one
            # program in this case; its entry head no longer moves --
            # see check_purity.TEXT_MUTABLE_NOTES['as']), so this
            # branch is dead today and kept for the next program that
            # earns it.
            print(f'   {name:<10} never warm by construction: the entry '
                  f'head moves, so the kernel refuses to retain its bank')
            continue
        if v and not v.warm:
            failures.append(
                f'group {group}: {name} has a repeat pair but was never '
                f'observed running WARM -- the second run cold-loaded, so '
                f'the comparison proved nothing. The pair\'s two lines must '
                f'be adjacent and nothing may reclaim the bank between '
                f'them.')


def main():
    groups = sys.argv[1:] or sorted(GROUP_BINS)
    if not os.path.exists(SYMFILE):
        print(f'error: {SYMFILE} not found -- build/MAUXSH.SYSTEM must be '
              f'assembled with merlin32 -v1', file=sys.stderr)
        return 2

    # -- derive every program's arena ONCE, up front, rather than per
    # -- group (arena_span() reassembles the program with `-v1`; no
    # -- need to pay that four times for a program in only one group,
    # -- and `sh` is in every group's own image already).
    all_names = {n for names in GROUP_BINS.values() for n in names}
    all_names.add('sh')
    arenas, no_arena = program_arenas(all_names)
    print(f'[check-textaudit] {len(arenas)} program(s) have a derivable '
          f'`dum` arena (scripts/arena.py) and will be poisoned both '
          f'pre-boot and between every run; {no_arena} skipped '
          f'EXPLICITLY -- no `dum` arena at all (genuinely unconverted)')

    verdicts = {}
    failures = []
    poison_totals = {}
    for group in groups:
        audit_group(group, verdicts, failures, arenas, poison_totals)

    print()
    print('[check-textaudit] runtime writable-text audit '
          '(docs/STICKY.md sec 29) -- each program\'s image in its bank at '
          'the moment the kernel retired it, against its .bin')
    print(f'   {"program":<10} {"runs":>4} {"warm":>4} {"image":>7} '
          f'{"moved":>7}  verdict')
    for name in sorted(verdicts):
        v = verdicts[name]
        if v.dirty == 0:
            verdict = 'CLEAN'
        elif v.head_moved:
            verdict = 'DIRTY-HEAD (kernel refuses the bank)'
        else:
            verdict = 'DIRTY-TAIL (bank retained, warm respawn sees this)'
        if name in WARM_UNSAFE:
            verdict += ' -- WARM-UNSAFE'
        print(f'   {name:<10} {v.runs:>4} {v.warm:>4} {v.length:>7} '
              f'{len(v.diffs):>7}  {verdict}')
        if v.diffs:
            all_runs = runs_of(sorted(v.diffs))
            for (a, b) in all_runs[:6]:
                print(f'        ${0x0800 + a:04X}-${0x0800 + b:04X} '
                      f'({b - a + 1} B)')
            if len(all_runs) > 6:
                print(f'        ... {len(all_runs)} runs total')
        failures.extend(v.broken)

    # -- measurement vs declaration --------------------------------
    for name, v in sorted(verdicts.items()):
        declared_pure = name in TEXT_IMMUTABLE
        declared_dirty = name in TEXT_MUTABLE
        if not declared_pure and not declared_dirty:
            failures.append(
                f'{name} was measured but is in no runtime roster '
                f'(check_purity.TEXT_IMMUTABLE / TEXT_MUTABLE). Declare it '
                f'-- docs/STICKY.md sec 9 blocker 3.')
            continue
        if v.dirty and declared_pure:
            head = ('and its ENTRY HEAD moved, so the kernel refuses the '
                    'bank and it cold-loads forever'
                    if v.head_moved else
                    'with its entry head INTACT, so the kernel RETAINS the '
                    'bank and the next run of it starts on mutated text')
            failures.append(
                f'{name} is declared TEXT_IMMUTABLE but wrote '
                f'{len(v.diffs)} of its {v.length} image bytes over '
                f'{v.dirty} of {v.runs} run(s) -- {head}. Either the '
                f'program grew writable text (move it into the `dum` arena) '
                f'or the declaration is wrong.')
        if not v.dirty and declared_dirty:
            failures.append(
                f'{name} is declared TEXT_MUTABLE but measured CLEAN over '
                f'{v.runs} run(s). Remove the stale entry -- a dead '
                f'allowance makes the ratchet a lie.')
        if v.dirty and declared_dirty:
            want = TEXT_MUTABLE[name]
            if bool(v.head_moved) != bool(want):
                failures.append(
                    f'{name} is declared TEXT_MUTABLE with head={want} but '
                    f'measured head_moved={v.head_moved}. head=True means '
                    f'the kernel refuses the bank; head=False means it '
                    f'RETAINS it and the program runs on its own leftovers. '
                    f'The two have different consequences and must not be '
                    f'confused.')

    for name in sorted(set(TEXT_IMMUTABLE) | set(TEXT_MUTABLE)):
        if name not in verdicts:
            failures.append(
                f'{name} is declared in check_purity.py but the audit never '
                f'ran it. A declaration nothing exercises is an assumption '
                f'-- add it to a group in build_textaudit_image.py or move '
                f'it to TEXT_UNAUDITED with a reason.')

    for name in sorted(WARM_UNSAFE):
        if name not in verdicts:
            failures.append(
                f'{name} is in check_purity.WARM_UNSAFE but the audit never '
                f'ran it -- a recorded defect nothing exercises stops being '
                f'a defect and starts being folklore.')

    print()
    for name in sorted(TEXT_MUTABLE_NOTES):
        print(f'[check-textaudit] {name}: {TEXT_MUTABLE_NOTES[name]}')
    print(f'[check-textaudit] {len(TEXT_UNAUDITED)} program(s) deliberately '
          f'unaudited: {", ".join(sorted(TEXT_UNAUDITED))}')

    total_poison_events = sum(len(v) for v in poison_totals.values())
    print()
    print(f'[check-textaudit] POISON (docs/STICKY.md sec 25/28/37): '
          f'{len(arenas)} program(s) with a derivable `dum` arena '
          f'poisoned pre-boot in every candidate bank AND re-poisoned '
          f'between every run, {total_poison_events} between-run poison '
          f'event(s) fired across {len(poison_totals)} group(s); '
          f'{no_arena} skipped explicitly (no `dum` arena at all)')

    if failures:
        for f in failures:
            print(f'[check-textaudit] FAIL: {f}', file=sys.stderr)
        return 1
    clean = sorted(n for n, v in verdicts.items() if not v.dirty)
    dirty = sorted(n for n, v in verdicts.items() if v.dirty)
    print(f'[check-textaudit] PASS: {len(verdicts)} program(s) run under '
          f'maux on real work. {len(clean)} measured byte-identical '
          f'({", ".join(clean)}); {len(dirty)} write their own text and are '
          f'declared; every repeat pair reproduced its first run except the '
          f'declared-broken {sorted(WARM_UNSAFE)}; every one poisoned both '
          f'pre-boot and between runs')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
