#!/usr/bin/env python3
"""check_librel.py -- S9 L2's real-Merlin REL check (a library
now, see below): every
liba module's GENERATED REL form assembles clean under real Merlin-8,
and the resulting REL objects are exported as the reference set for
`as`'s side of the byte-identity bar.

    python3 scripts/check_librel.py

RETIRED AS A GATE 2026-10-18 (RULINGS-1): there is no `make
check-librel` target any more; the real-Merlin run modelled the
superseded assemblers' source window and was red outside the sweep
since KFIX4. THIS FILE STAYS as the shared library that
build_nas_librel_image.py and the Makefile's KERNEL_LISTINGS import
(modules(), KERNEL_FLAT, KERNEL_MAINS, kernel_main_segments(),
libk_order(), libk_link_plan()). check-nas-librel is the gate.

SELF-STAGING, from vendor media, every run. The pilot's expensive
lesson (docs/S9-PLAN.md sec 6 L2): ad-hoc staging on another gate's
image dies the moment anything runs `make clean` (check-bytes does it
twice per invocation), and the failure -- 46 FILE NOT FOUND mid-
assembly -- arrives far from the cause. This gate builds its own
image (build/librel.po) from vendor/VALIDATE.PO at every run:
patched PARMS (kills the screen pager that stalls marker-driven
harnesses; also auto-skips the Update-source prompt, though not
deterministically enough to skip ANSWERING it -- the driver handles
both), every equ file the generated forms can put, and all
generated REL sources with their put operands rewritten to the
staged flat names.

Outputs on success: build/lib/<module>.rel -- real Merlin's own
objects, dictionary included -- plus build/lib/meta.json with
each object's ProDOS type/aux and the generator's ENT/EXT counts.
These are the references `as` must match byte-for-byte (the same
two-assembler bar check-as's RELMOD/RELMAIN cases already hold).
"""
import json
import glob
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
import check_rel as cr  # noqa: E402 -- menu-driving helpers
import check_merlin_build as cmb  # noqa: E402 -- wait_quiet()
from gen_rel_module import generate, EQU_ORDER  # noqa: E402
import check_modules as ckm  # noqa: E402 -- scan() for libk_link_plan

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import a2til  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_IMG = os.path.join(ROOT, 'vendor', 'VALIDATE.PO')
BOOT_IMG = os.path.join(ROOT, 'build', 'librel-boot.po')
DATA_IMG = os.path.join(ROOT, 'build', 'librel.po')
# build/lib/, not build/librel/, since 2026-09-16: the guest calls the
# same collection /LIB (docs/LAYOUT.md), and one name for one thing is
# the whole point of that move. The staging VOLUME below is still
# LIBREL -- it is this gate's scratch disk, named after the gate.
OUT_DIR = os.path.join(ROOT, 'build', 'lib')
DATA_VOL = 'LIBREL'
DATA_DIR = f'/{DATA_VOL}/S'

# Flat staged names. Equ files: deterministic, hand-legible, and
# asserted collision-free below. Modules: <BASE>REL.S source with a
# <BASE>R object -- ProDOS's 15-char limit clears the longest
# (CPTREEBSSREL.S, 14).
EQU_FLAT = {
    'inc/mm.procbank.equ': 'MPBEQU',
    'inc/mm.procbnk2.equ': 'MPB2EQU',
    'inc/mm.hw.equ': 'MHWEQU',
    'inc/sc.proc.equ': 'SPEQU',
    'inc/sc.file.equ': 'SFEQU',
    'inc/sc.fd.equ': 'SFDEQU',
    'inc/sc.fdact.equ': 'SFAEQU',
    'inc/sc.status.equ': 'SSTEQU',
    'inc/errno.spawn.equ': 'ESPEQU',
    # -- the kernel's own equ chain (S9 L4). Same rule as above:
    # -- one flat, uppercase, unique name per file, because the
    # -- staged volume is flat and ProDOS names are short.
    'inc/mm.mli.equ': 'MMLIEQU',
    'inc/mm.mlibuf.equ': 'MMLIBEQU',
    'inc/mm.annex.equ': 'MANXEQU',
    'inc/mm.annex2.equ': 'MANXEQU2',
    'inc/mm.main.equ': 'MMAINEQU',
    'inc/mm.kbss0.equ': 'KBSSHEQU',
    'inc/mm.kbss.equ': 'KBSSEQU',
    'inc/mm.lseg.equ': 'LSEGEQU',      # docs/LOOP-S1.md
    'inc/sc.devfd.equ': 'SDFDEQU',
    'inc/errno.krn.equ': 'EKRNEQU',
    'inc/bankcopy.equ': 'BCPYEQU',
    'inc/entry.frame.equ': 'EFRMEQU',
    'inc/sched.equ': 'SCHEQU',
    'inc/kdisp.equ': 'KDSPEQU',
    'inc/sched.zp.equ': 'SCHZPEQU',
    'inc/bankprobe.equ': 'BPRBEQU',
    'inc/mli.const.equ': 'MLICEQU',
    'inc/proc.const.equ': 'PRCCEQU',
    'inc/timer.equ': 'TMREQU',
    'inc/ultraterm.equ': 'ULTEQU',
    'inc/tty.equ': 'TTYEQU',
    'inc/zp.equ': 'ZPEQU',
    'inc/stdio.equ': 'STDIOEQU',
    'inc/startup.equ': 'STARTEQU',
    'inc/mli.equ': 'MLIEQU',
    'inc/readdir.equ': 'RDEQU',
    'inc/cptree.equ': 'CPTEQU',
    'inc/regex.equ': 'REEQU',
    # bye slice 1 (2026-09-25): moved src/kernel/ -> inc/ the same
    # day (check-modules' module-boundary rule only recognizes
    # inc/*.equ as legitimate globals; see gen_rel_module.py's
    # EQU_ORDER comment).
    'inc/byeres.equ': 'BYEREQU',
}
assert set(EQU_FLAT) >= set(EQU_ORDER), 'EQU_ORDER grew; extend EQU_FLAT'
assert len(set(EQU_FLAT.values())) == len(EQU_FLAT), 'flat-name collision'


# THE KERNEL'S 31 MODULES (S9 L4/L5). Flat names are hand-assigned,
# not derived, for two reasons: `mli.s` exists in BOTH src/liba and
# src/kernel, so a basename scheme collides outright; and a ProDOS
# name is 15 characters, which `<base>REL.S` and `<base>R` must both
# fit -- `KPROCSPAWN2REL.S` does not. Asserted unique and short
# below, so a new kernel module cannot quietly collide.
KERNEL_FLAT = {
    'bankcopy': 'KBCPY',      'bankprobe': 'KBPRB',
    'entry': 'KENTRY',        'entry2': 'KENTRY2',
    'ffpage': 'KFFPG',        'kdisp': 'KDISP',
    'lazyfree': 'KLAZY',      'mli': 'KMLI',
    'mouse': 'KMOUSE',        'process': 'KPROC',
    'procfd': 'KPFD',         'procfd2': 'KPFD2',
    'procfile': 'KPFILE',     'procfile2': 'KPFILE2',
    'process2': 'KPROC2',     'procfile3': 'KPFILE3',
    'procfile4': 'KPFILE4',   'procfile5': 'KPFILE5',
    'procfork': 'KPFORK',     'procmli': 'KPMLI',
    'procmli2': 'KPMLI2',     'procmli3': 'KPMLI3',
    'procspawn': 'KPSPWN',    'procspawn2': 'KPSPWN2',
    'procsig': 'KSIG',
    'procsig2': 'KSIG2',
    'procspawn3': 'KPSPWN3',  'sched': 'KSCHED',
    'sched2': 'KSCHED2',      'timer': 'KTIMER',
    'tty': 'KTTY',            'tty2': 'KTTY2',
    'tty3': 'KTTY3',          'tty4': 'KTTY4',
    'tty5': 'KTTY5',
    'tty6': 'KTTY6',      'tty7': 'KTTY7',      'tty8': 'KTTY8',
    'ultraterm': 'KULT',
    'ultraterm2': 'KULT2',
    # posix-sed line's kernel modules, named at the 2026-09-15 merge
    # with main: tty9.s (VT102 slices) and ser.s (the SSC serial
    # driver) -- the nas-librel image stages every kernel module.
    'tty9': 'KTTY9',          'ser': 'KSER',
    # bye slice 1's kernel module. procbye.s is an ordinary `put`
    # module like any other. byeres.s is DELIBERATELY ABSENT here
    # (2026-09-25) -- it is a separate, standalone `org $D100`
    # assembly, never `put` as source by any top-level harness and,
    # since the same day's PT_HOLD ceiling fix, no longer `putbin`'d
    # as data either (procbye.s's PBY_LOAD_RES loads it from
    # /mnt/MAUX/BYERES at `bye` time instead). It is not an input to
    # ANY kernel image any more, built by its own Makefile rule and
    # staged as a plain volume file -- registering it here to
    # satisfy `modules()`'s walker was the wrong fix (a name in an
    # exception list for a mechanism that does not apply to it,
    # the "registering an exceptional artifact to satisfy a generic
    # mechanism" trap this task hit twice already). `modules()`
    # itself now detects a kernel .s file's own literal `org` --
    # byeres.s is the only one -- and excludes it structurally, the
    # same way the src/bin/ generator already treats a literal org
    # as a fact about the file rather than a name to remember
    # (proshimcr.s/proshimpg.s).
    'procbye': 'KPBYE',
    # docs/KSEG.md's kernel cold segment (2026-09-27): byelaunch.s,
    # kbye.s and kdevblk.s are ordinary `put` modules like any other
    # kernel source file -- the SEGMENT split (a separate `org
    # KSEG_ORG` block, later cut into build/MAUXPLAY_KSEG by
    # scripts/split_kseg.py) is a merlin32-manifest-only concept the
    # nas/ld native path does not model yet (]KSEG_WANT scoping is
    # accepted for this landing, docs/DEV-BLOCK.md). The nas-librel
    # image stages every kernel module flat, segment or not, same as
    # tty9/ser above.
    'byelaunch': 'KBYLNCH',  'kbye': 'KBYE',
    'kdevblk': 'KDEVBLK',
    # docs/KSEG.md's module-choice scoping (2026-09-27, coordinator
    # review, DECISION 1 -- do/fin removed, nas has no such directive
    # at all): procdev.s (real) and procdevs.s (stub) replace
    # `do ]KSEG_WANT`. The nas-librel image stages every kernel
    # module flat regardless of which one a given manifest puts.
    'procdev': 'PROCDEV',    'procdevs': 'PROCDEVS',
    # KFIX5: the builtin-image spawn twins (spawnbl.s real, spawnpl.s
    # plain), module choice as procdev.s / procdevs.s above.
    'spawnbl': 'SPAWNBL',    'spawnpl': 'SPAWNPL',
    'vroot': 'VROOT',                      # docs/VROOT.md
    # docs/LOOP-S1.md: the play-only LOW segment (org LSEG_ORG, a
    # third `org` block after KSEG); linked with its own `-s`.
    'loopseg': 'LOOPSEG',
}
assert len(set(KERNEL_FLAT.values())) == len(KERNEL_FLAT), \
    'kernel flat-name collision'
assert all(len(v) <= 9 for v in KERNEL_FLAT.values()), \
    'kernel flat name too long for <name>REL.S in 15 chars'


# ---------------------------------------------------------------
# REL_ORACLE_GAP -- kernel modules real Merlin will not assemble as
# REL forms, pinned so the rest stay gated. It had five entries for
# a fortnight. It has ONE.
#
# THE SYMPTOM was ProDOS error $56, which Merlin's own message table
# (vendor/merlin/INTERPRETER.S) renders as "MEMORY IN USE": BAD
# BUFFER ADDRESS, raised while OPENING a file, followed by a "Hit a
# key" prompt that stalls the driver.
#
# THE CAUSE, found 2026-08-30, is Merlin-8's documented source
# buffer ($0901..$AA00 = 41,215 B) and its budget is
#
#     size(resident manifest) + MAX over puts of size(put)
#
# -- NOT the sum. Applied to all 31 kernel modules that inequality
# separates the five failures from the 26 successes EXACTLY, with
# margin either side: worst passer KTTY at 38,961, best failer
# KPFORK at 41,895.
#
# HOW IT STAYED "UNEXPLAINED" FOR A FORTNIGHT, which is the part
# worth keeping. This note used to list six variables measured
# across all 31 modules -- source size, symbol count, emitted
# object size, emitted `ds`, put count, put file sizes -- and
# concluded none separated them. Five were the wrong quantity. The
# sixth was RIGHT ("put file sizes") and was aggregated as the SUM
# (recorded here as "sum 47,945 passes, 45,466 fails"), which
# genuinely does not separate them. One aggregation function away
# from the answer -- and the formula was already written down, in
# the commons, since 2026-08-17
# (learning:01M051EM2HQ3ZVJTR1W9P3G86J).
#
# THE FIX was the one that learning also predicts ("shared
# inc/equate files are the ones that silently creep toward the
# ceiling"): inc/mm.annex.equ was 19,248 B and was the
# largest put of all five failures and of none of the successes.
# Splitting it into mm.annex.equ + mm.annex2.equ (byte
# neutral -- check-bytes, 58 artifacts) took four of the five under
# the limit, and real Merlin now assembles all four with
# `Errors: 0`, producing objects identical in size and aux type to
# the ones `as` produces. They are byte-gated again.
#
# A REAL REFUTATION IN THE SAME MOVE: the old note reasoned that
# these modules might "need splitting". They did not. The SOURCE
# was never too big; the file it PUT was.
#
# THE ONE THAT REMAINS. KPROC's resident form is 36,863 B, so even
# with a 10,909 B largest put it needs 47,772 -- 6,557 over. It is
# the only module whose own text, not its includes, is the problem,
# and a split at PRC_EXIT is what would fix it. Until then `as` has
# never been asked about it either (it does not fit as's 16,126 B
# window), and scripts/relflat.py (deleted 2026-10-18) -- the second oracle, merlin32's
# flat assembly -- is what will check it when it can be.
#
# Debug hooks: CHECK_LIBREL_ONLY=<names> assembles a subset,
# CHECK_LIBREL_SKIP=<names> the complement, CHECK_LIBREL_ALL
# re-admits this list, CHECK_LIBREL_NODSK=1 drops the object write.
REL_ORACLE_GAP = {}


# ---------------------------------------------------------------
# MERLIN_SOURCE_BUDGET -- the host-side check that should always
# have existed. Real Merlin-8's source buffer is $0901..$AA00 and
# its charge is `resident manifest + MAX over puts`, NOT the sum
# (learning:01M051EM2HQ3ZVJTR1W9P3G86J). Exceeding it aborts the
# assembly with "56 MEMORY IN USE" and a "Hit a key" prompt that
# stalls the driver -- a symptom that names neither size nor file,
# costs an emulator boot to observe, and looks like a disk fault.
#
# Every input to the inequality is known on the host. So it is
# computed here, before anything is staged, and the margin is
# PRINTED for every module rather than only complained about at
# the boundary: five modules sat over this line for a fortnight
# diagnosed as an "unexplained capacity limit", and the tightest
# passing module today has about 1 KB of room. A number nobody
# can see is a number nobody defends.
# WHY THIS GATE STAGES RAW SOURCE, when stripping would give every
# module ~25 KB of margin instead of KSCHED's 1,061 B. It is not an
# oversight and it should not be "fixed" by the next person who reads
# that number:
#
#   `as` is fed SQUEEZED text (build_librelas_image). Real Merlin is
#   fed RAW. The objects come out byte-identical across all 55
#   modules -- which is a DIFFERENTIAL PROOF that the squeeze is
#   semantics-preserving, renewed on every run. Strip both sides and
#   that proof evaporates: a squeeze bug would corrupt both inputs
#   identically and both assemblers would agree on the wrong answer.
#
# The cost is that this path's budget is charged against raw text
# while check_dialect's sec 3 models the SELF-HOSTING path, which
# does strip (build_maux_src_image.py). Two staging paths, two
# budgets, and for months only one of them was modelled -- which is
# exactly how five modules sat over a documented limit and nothing
# saw it coming. check_source_budgets() below models THIS one.
MERLIN_SOURCE_BUDGET = 41215
BUDGET_WARN = 2048        # report modules with less headroom than this


def source_budget(mod, base):
    """(resident, largest_put, put_name) as real Merlin will see it."""
    text, m = generate(mod, dsk=f'{DATA_DIR}/{base}R')
    moddir = os.path.relpath(os.path.dirname(mod), ROOT)
    out = []
    for ln in text.split('\n'):
        if ln.startswith(' put '):
            norm = os.path.normpath(os.path.join(moddir, ln[5:].strip()))
            ln = f' put {DATA_DIR}/{EQU_FLAT[norm]}'
        out.append(ln)
    puts = [(os.path.getsize(os.path.join(ROOT, e)), e) for e in m['equs']]
    worst, wname = max(puts) if puts else (0, '-')
    return len('\n'.join(out)), worst, wname


def check_source_budgets():
    """Fail before booting anything if a module cannot fit."""
    rows = []
    for mod, base in modules():
        res, worst, wname = source_budget(mod, base)
        rows.append((res + worst, res, worst, wname, base))
    # the kernel-main segments answer to the same buffer
    for man, segs, kmeta in kernel_main_segments():
        mandir = os.path.dirname(man)
        for name, text in segs:
            puts = []
            for ln in text.split('\n'):
                if ln.startswith(' put '):
                    norm = os.path.normpath(
                        os.path.join(mandir, ln[5:].strip()))
                    puts.append((os.path.getsize(
                        os.path.join(ROOT, norm)), norm))
            worst, wname = max(puts) if puts else (0, '-')
            rows.append((len(text) + worst, len(text), worst, wname,
                         name))
    rows.sort(reverse=True)
    over = [r for r in rows if r[0] > MERLIN_SOURCE_BUDGET]
    tight = [r for r in rows
             if not r[0] > MERLIN_SOURCE_BUDGET
             and MERLIN_SOURCE_BUDGET - r[0] < BUDGET_WARN]
    print(f'[check-librel] real-Merlin source budget '
          f'(resident + LARGEST put <= {MERLIN_SOURCE_BUDGET})')
    shown = rows[:1] + [r for r in tight if r not in rows[:1]]
    for total, res, worst, wname, base in shown:
        print(f'[check-librel]   {base:10s} {res:6d} + {worst:5d} '
              f'({os.path.basename(wname)}) = {total:6d}  '
              f'margin {MERLIN_SOURCE_BUDGET - total:+6d}')
    if over:
        for total, res, worst, wname, base in over:
            print(f'[check-librel] FAIL: {base} needs {total} B '
                  f'(resident {res} + largest put {worst}, '
                  f'{os.path.basename(wname)}) against a '
                  f'{MERLIN_SOURCE_BUDGET} B buffer -- over by '
                  f'{total - MERLIN_SOURCE_BUDGET}. Real Merlin would '
                  f'abort with "56 MEMORY IN USE". Split the SOURCE if '
                  f'`resident` is the large half, the INCLUDE if the '
                  f'put is.', file=sys.stderr)
        return False
    print(f'[check-librel]   {len(rows)} module(s) fit; tightest margin '
          f'{MERLIN_SOURCE_BUDGET - rows[0][0]} B ({rows[0][4]})')
    return True


def hi(text):
    return bytes((ord(c) | 0x80) if c != '\n' else 0x8D for c in text)


from kernel_mains import KERNEL_MAINS  # noqa: E402 -- pure data; the Makefile reads it at parse time


def kernel_prefixes():
    """Collision-free segment-name prefix per KERNEL_MAINS manifest.
    Starts at the historical alnum[:4]; a COLLIDING group is redone
    from the stem with 'TEST' dropped and widened one character at a
    time until unique (sched.coop/preempt/wake all truncate to
    'SCHE' -- they become SCHEDC/SCHEDP/SCHEDW). Bounded at 7 so
    <prefix>M<n>REL.S stays a legal ProDOS name."""
    stems = {man: ''.join(c for c in os.path.basename(man)[:-2].upper()
                          if c.isalnum())
             for man in KERNEL_MAINS}
    pref = {man: s[:4] for man, s in stems.items()}
    from collections import Counter
    for width in range(4, 8):
        dup = {p for p, n in Counter(pref.values()).items() if n > 1}
        if not dup:
            break
        for man in pref:
            if pref[man] in dup:
                pref[man] = stems[man].replace('TEST', '')[:width]
    assert len(set(pref.values())) == len(pref), \
        f'segment prefixes still collide: {sorted(pref.values())}'
    assert all(len(p) <= 7 for p in pref.values())
    return pref


def kernel_main_segments():
    from gen_rel_module import generate_kernel_main
    prefixes = kernel_prefixes()
    out = []
    for man, cfg in sorted(KERNEL_MAINS.items()):
        segs, kmeta = generate_kernel_main(
            man, KERNEL_FLAT,
            listing=os.path.join(ROOT, cfg['listing']),
            prefix=prefixes[man])
        kmeta.update(cfg)
        out.append((man, segs, kmeta))
    return out


_AMBIGUOUS_GROUPS_CACHE = None
_AMBIGUOUS_DEFAULTS_CACHE = None


def _ambiguous_groups():
    """Partition KERNEL_FLAT names into module-choice FAMILIES: two
    names are in the same family iff their DEFINED-SYMBOL sets
    overlap (transitively), which is exactly the shape a real/stub
    pair takes (docs/KSEG.md's procdev.s/procdevs.s, check_modules.
    KNOWN_DUPLICATES: KSEG_BOOT, PDEV_TRYBLK_G, PRC_BLK_RD_G/WR_G/
    SM_G/GM_G/GE_G, all deliberately defined by BOTH). Returns
    {name: frozenset(family)} for every name whose family has more
    than one member; a name with no overlap is absent. Derived from
    each module's own scanned symbols, not hardcoded, so a FUTURE
    module-choice pair (or a 3-way choice) is caught the same way
    without editing this function."""
    global _AMBIGUOUS_GROUPS_CACHE
    if _AMBIGUOUS_GROUPS_CACHE is not None:
        return _AMBIGUOUS_GROUPS_CACHE
    defs = {}
    for stem, base in KERNEL_FLAT.items():
        path = os.path.join(ROOT, 'src', 'kernel', f'{stem}.s')
        if not os.path.exists(path):
            continue
        d, _u = ckm.scan(path)
        defs[base] = d
    parent = {b: b for b in defs}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb

    bases = list(defs)
    for i in range(len(bases)):
        for j in range(i + 1, len(bases)):
            if defs[bases[i]] & defs[bases[j]]:
                union(bases[i], bases[j])
    families = {}
    for b in bases:
        families.setdefault(find(b), set()).add(b)
    out = {n: frozenset(fam) for fam in families.values()
           if len(fam) > 1 for n in fam}
    _AMBIGUOUS_GROUPS_CACHE = out
    return out


def _ambiguous_kmods():
    """Flat set of every name `_ambiguous_groups()` places in a
    family of more than one -- kept as its own function since most
    callers only need membership, not the family."""
    return set(_ambiguous_groups())


def _ambiguous_defaults(kmains=None):
    """For each module-choice family, the member used by the MOST
    KERNEL_MAINS manifests -- the one `libk_order()` places EARLIEST
    in the shared library's directory order, so an ORDINARY `-l k`
    fixpoint scan satisfies it correctly for every manifest that
    wants it, at zero extra cost. Only a manifest wanting a family's
    NON-default member needs `libk_link_plan`'s explicit-kmod escape
    hatch -- which for a 2-member family (today: PROCDEV/PROCDEVS)
    means exactly one manifest (playtest.s) pays the cost of breaking
    its own `-l k` run, instead of the other ~30 paying it each."""
    global _AMBIGUOUS_DEFAULTS_CACHE
    if _AMBIGUOUS_DEFAULTS_CACHE is not None:
        return _AMBIGUOUS_DEFAULTS_CACHE
    groups = _ambiguous_groups()
    if not groups:
        _AMBIGUOUS_DEFAULTS_CACHE = set()
        return _AMBIGUOUS_DEFAULTS_CACHE
    if kmains is None:
        kmains = kernel_main_segments()
    usage = {n: sum(1 for _man, _segs, km in kmains if n in km['link'])
             for n in groups}
    seen_families = set()
    defaults = set()
    for family in groups.values():
        if family in seen_families:
            continue
        seen_families.add(family)
        defaults.add(max(family, key=lambda n: usage.get(n, 0)))
    _AMBIGUOUS_DEFAULTS_CACHE = defaults
    return defaults


def libk_link_plan(kmeta, kmains=None):
    """One kernel manifest's `-l k` link shape, used by BOTH the
    image builder (to spell the link line) and check_relink (to
    model the closure): the LONGEST contiguous run of kernel
    modules rides the single flag -- a -l takes every wanted
    member at ITS position, so a second flag would find nothing
    left -- and every other name is an explicit operand (kernel
    names outside the run as LIBK paths). A module-choice family's
    NON-DEFAULT member (`_ambiguous_defaults()` -- e.g. PROCDEV,
    since PROCDEVS is the default) never rides the shared flag,
    regardless of position: it always breaks the run and becomes an
    explicit `kmod` operand, resolved by NAME against LIBK's
    directory rather than by symbol availability, so the ONE
    manifest that wants it still gets it -- the DEFAULT member (e.g.
    PROCDEVS) stays an ordinary run member, since `libk_order()`
    places it earliest in directory order and an unbroken `-l k`
    already resolves it correctly for every manifest that wants it.
    Returns (ops, members): ops is the operand list with ('lib',) at
    the flag's place and ('mod', name)/('kmod', name) elsewhere;
    members is the run."""
    link = kmeta['link']
    flat = set(KERNEL_FLAT.values())
    groups = _ambiguous_groups()
    defaults = _ambiguous_defaults(kmains) if groups else set()
    escape = {n for n in flat if n in groups and n not in defaults}
    runnable = flat - escape
    runs, i = [], 0
    while i < len(link):
        if link[i] in runnable:
            j = i
            while j < len(link) and link[j] in runnable:
                j += 1
            runs.append((i, j))
            i = j
        else:
            i += 1
    big = max(runs, key=lambda r: r[1] - r[0]) if runs else (0, 0)
    ops = []
    for i, n in enumerate(link):
        if big[0] <= i < big[1]:
            if i == big[0]:
                ops.append(('lib',))
        elif n in flat:
            ops.append(('kmod', n))
        else:
            ops.append(('mod', n))
    return ops, link[big[0]:big[1]]


def libk_order(kmains=None):
    """/usr/lib/LIBK's member order: playtest's kernel put order,
    then whatever KERNEL_FLAT names no play link carries. LOAD-
    BEARING: ld's -l places taken members in DIRECTORY (= creation)
    order, so the staging order IS the link order, and put-order
    byte-identity for every kernel link rests on it. Members a link
    does not want are skipped in place, which is why one library
    serves manifests with different module subsets.

    Within a module-choice FAMILY (`_ambiguous_groups()` -- two
    names sharing defined symbols, e.g. procdev.s/procdevs.s), the
    family's DEFAULT member (`_ambiguous_defaults()`) is placed at
    the slot the MAJORITY of manifests actually expect it at -- an
    ordinary `-l k` fixpoint scan takes the first directory member
    that satisfies a still-undefined symbol, so whichever member
    sits earliest wins for every manifest that reaches that slot.

    THIS CANNOT simply reuse wherever the family's members happen to
    sit in PLAYTEST's own link order (the base `order` below): if
    playtest is the ONE manifest wanting the NON-default member (the
    common case -- that is what makes it non-default), playtest's
    own list may place that member somewhere the majority's OWN
    order does not share (docs/KSEG-NOTES.md, 2026-09-28: playtest.s
    moved `put procdev.s` to the TAIL of its own kernel block to fix
    a SEPARATE sh-LINEMAX overrun, which left NOTHING of this family
    at playtest's own "right after KPFILE5" slot -- the position
    every OTHER manifest's `put procdevs.s` actually occupies -- so
    a naive same-slot swap put the default at the WRONG position for
    all ~30 of them, corrupting their own `-l k` splice order
    entirely). Instead, find an ANCHOR: the name immediately BEFORE
    the default member in ANY manifest that actually links it (every
    manifest wanting the default agrees on this neighbor, by
    construction -- DECISION 1's mechanical `put procdevs.s`
    insertion after every `put procfile5.s`), and insert the default
    right after that anchor's own position in `order`. The non-
    default member's own position is never touched here: it is
    ALWAYS an explicit `kmod` operand (`libk_link_plan`), so its
    directory position is irrelevant to correctness -- it only needs
    to exist somewhere in the library, which the base `order`
    (playtest's own list, wherever that puts it) already ensures."""
    if kmains is None:
        kmains = kernel_main_segments()
    play = next(k for k in kmains if 'playtest' in k[0])
    flat = set(KERNEL_FLAT.values())
    order = [n for n in play[2]['link'] if n in flat]
    order += sorted(flat - set(order))
    groups = _ambiguous_groups()
    if groups:
        defaults = _ambiguous_defaults(kmains)
        seen_families = set()
        for fam in groups.values():
            if fam in seen_families:
                continue
            seen_families.add(fam)
            default = next(n for n in fam if n in defaults)
            anchor = None
            for _man, _segs, km in kmains:
                link = km['link']
                if default in link and link.index(default) > 0:
                    anchor = link[link.index(default) - 1]
                    break
            if default in order:
                order.remove(default)
            if anchor is not None and anchor in order:
                order.insert(order.index(anchor) + 1, default)
            else:
                order.append(default)
    return order


# A kernel .s file with its OWN literal `org` is a standalone
# assembly, not a `put`-together kernel module -- every REAL kernel
# module gets its address from the top-level harness's single
# `org $2000`, once, and never declares one of its own. Same
# structural test build_nas_librel_image.py's own src/bin/ walker
# already applies to proshimcr.s/proshimpg.s: detect the FACT about
# the file (it cannot be nas-assembled as an ordinary REL module --
# `org`/`typ`/`dsk` are standalone-binary-output directives a REL
# assembly has no use for), not its name. byeres.s (bye slice 1,
# `org $D100`) is the only kernel module this currently matches;
# naming it in KERNEL_FLAT to satisfy this walker was the wrong fix
# -- it is not an input to any kernel image, built by its own
# Makefile rule and staged as a plain volume file
# (procbye.s's PBY_LOAD_RES loads it from /mnt/MAUX/BYERES at `bye`
# time) -- so it is excluded here structurally instead.
KERNEL_OWN_ORG_RE = re.compile(r'^[ \t]+org[ \t]+\S+', re.M)


def _has_own_org(path):
    with open(path) as fh:
        return bool(KERNEL_OWN_ORG_RE.search(fh.read()))


def modules():
    """Every module the linker will ever be handed: liba, then the
    kernel. Returned as (path, flat_base) because the two live in
    different directories and share at least one basename."""
    out = [(p, os.path.basename(p)[:-2].upper())
           for p in sorted(glob.glob(os.path.join(ROOT, 'src/liba/*.s')))]
    for p in sorted(glob.glob(os.path.join(ROOT, 'src/kernel/*.s'))):
        stem = os.path.basename(p)[:-2]
        if _has_own_org(p):
            # standalone blob (its own literal org), not a linkable
            # kernel module -- see KERNEL_OWN_ORG_RE's header.
            print(f'[check-librel] src/kernel/{stem}.s has its own '
                  f'`org` -- excluded from the kernel module set '
                  f'(standalone blob, not a REL-linkable module)')
            continue
        if stem not in KERNEL_FLAT:
            raise SystemExit(
                f'src/kernel/{stem}.s has no KERNEL_FLAT name -- add one '
                f'(<=9 chars, unique) so it can be staged')
        out.append((p, KERNEL_FLAT[stem]))
    if not os.environ.get('CHECK_LIBREL_ALL'):
        out = [(p, b) for p, b in out if b not in REL_ORACLE_GAP]
    skip = os.environ.get('CHECK_LIBREL_SKIP')
    if skip:
        # The complement of CHECK_LIBREL_ONLY, and it exists for one
        # question: CHECK_LIBREL_ALL re-admits the five oracle-gap
        # modules so `as` can be asked what real Merlin refused, but
        # KPROC does not FIT as's 16,126 B window (measured
        # 2026-08-30: staged 16,314 B + memmap-annex 2,752 B) and
        # trips the builder's budget assert before any of the other
        # four gets staged. Skipping it is what lets the other four
        # be asked at all.
        out = [(p, b) for p, b in out if b not in set(skip.split(','))]
    only = os.environ.get('CHECK_LIBREL_ONLY')
    if only:
        # Debug hook: assemble a named subset, so an intrinsic failure
        # can be told from one that depends on the modules assembled
        # before it in the same boot.
        want = set(only.split(','))
        out = [(p, b) for p, b in out if b in want]
        # names not matched here may be SEGMENT names -- stage()
        # filters those with the same hook and validates the union.
    return out


def stage():
    """Two volumes, the check-dual pattern. VALIDATE.PO is FULL --
    Merlin's own sources fill it ('no free blocks' on this gate's
    first single-volume attempt), so the boot copy gains only the
    44-byte PARMS (which must live in the boot volume's MAIN
    directory, and which kills the screen pager + auto-skips the
    Update prompt), while sources, equ files and the assembled
    objects all live on a fresh 800K data volume, in a SUBDIRECTORY
    -- 23 sources + 15 equ files + 23 objects lands over the volume
    directory's hard ~51-slot ceiling, and a subdirectory extends
    like a file."""
    shutil.copyfile(SRC_IMG, BOOT_IMG)
    vol = a2til.open_image(BOOT_IMG)
    sys.path.insert(0, os.path.join(ROOT, 'src', 'merlin'))
    import patches  # noqa: E402
    vol.write_file('/SOURCE/PARMS', bytes(patches.PARMS_BYTES),
                   file_type=0x06, aux_type=0x0000, overwrite=True)
    vol.flush()

    from a2til import prodos
    # 32 MB (65535 blocks, the bigdisk precedent build_librelas_image.py
    # already uses). The 800K volume this started as held 23 liba
    # sources and their objects; carrying the kernel's 31 modules too
    # -- 54 sources, 27 equ files and 54 objects -- overflows it with
    # 'no free blocks on volume', measured 2026-08-30.
    prodos.create(DATA_IMG, name=DATA_VOL, blocks=65535, dir_blocks=4)
    dvol = a2til.open_image(DATA_IMG)
    dvol.mkdir(DATA_DIR)
    for path, flat in EQU_FLAT.items():
        full = os.path.join(ROOT, path)
        if not os.path.exists(full):
            continue
        dvol.write_file(f'{DATA_DIR}/{flat}.S',
                        hi(open(full, encoding='latin-1').read()),
                        file_type=0x04, overwrite=True)
    meta = {}
    for mod, base in modules():
        # debug hook: assemble with no object output, to tell an
        # assembly-capacity failure from one in the DSK write path
        dsk = None if os.environ.get('CHECK_LIBREL_NODSK') \
            else f'{DATA_DIR}/{base}R'
        text, m = generate(mod, dsk=dsk)
        # put operands are emitted relative to the MODULE'S OWN
        # directory, which is src/kernel for half of these now
        moddir = os.path.relpath(os.path.dirname(mod), ROOT)
        out = []
        for ln in text.split('\n'):
            if ln.startswith(' put '):
                op = ln[5:].strip()
                norm = os.path.normpath(os.path.join(moddir, op))
                ln = f' put {DATA_DIR}/{EQU_FLAT[norm]}'
            out.append(ln)
        dvol.write_file(f'{DATA_DIR}/{base}REL.S', hi('\n'.join(out)),
                        file_type=0x04, overwrite=True)
        meta[base] = {'ents': len(m['ents']), 'exts': len(m['exts'])}
    only = os.environ.get('CHECK_LIBREL_ONLY')
    for man, segs, kmeta in kernel_main_segments():
        mandir = os.path.relpath(
            os.path.dirname(os.path.join(ROOT, man)), ROOT)
        for name, text in segs:
            # the ONLY debug hook covers segments too -- a failing
            # segment costs a full-roster boot to reproduce otherwise
            if only and name not in set(only.split(',')):
                continue
            out = []
            for ln in text.split('\n'):
                if ln == ' rel' and not os.environ.get(
                        'CHECK_LIBREL_NODSK'):
                    out.append(ln)
                    out.append(f' dsk {DATA_DIR}/{name}R')
                    continue
                if ln.startswith(' put '):
                    op = ln[5:].strip()
                    norm = os.path.normpath(os.path.join(mandir, op))
                    ln = f' put {DATA_DIR}/{EQU_FLAT[norm]}'
                out.append(ln)
            dvol.write_file(f'{DATA_DIR}/{name}REL.S',
                            hi('\n'.join(out)),
                            file_type=0x04, overwrite=True)
            meta[name] = {
                'ents': sum(1 for l in text.split('\n')
                            if l.endswith(' ent')),
                'exts': sum(1 for l in text.split('\n')
                            if l.endswith(' ext'))}
    dvol.flush()
    if only:
        missing = set(only.split(',')) - set(meta)
        if missing:
            raise SystemExit(
                f'CHECK_LIBREL_ONLY: unknown {sorted(missing)} -- '
                f'neither a module nor a generated segment')
    print(f'[check-librel] staged {len(meta)} generated modules + '
          f'{len(EQU_FLAT)} equ files on {DATA_IMG}; PARMS on boot copy')
    return meta


def drive(meta):
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    c = MCPClient([SUPERVISOR], env)
    banners = {}
    try:
        c.initialize()
        for unit in range(1, 7):
            c.call_tool('eject_disk', {'unit': unit})
        c.call_tool('reset', {'backend': 'fast'})
        c.call_tool('mount_disk', {'path': BOOT_IMG})
        c.call_tool('mount_disk', {'path': DATA_IMG})
        cr.wait(c, cr.MENU_MARKER)
        cr.settle(c)
        cr.set_prefix(c, DATA_DIR + '/')
        for base in sorted(meta):
            c.call_tool('type', {'text': f'L{base}REL\r'})
            cr.wait(c, 'Editor')
            cr.settle(c)
            c.call_tool('type', {'text': 'ASM\r'})
            answered = False
            banner = None
            for _ in range(400):
                c.call_tool('step', {'cycles': 2_000_000})
                s = cr.screen(c)
                if 'Update source' in s and not answered:
                    c.call_tool('type', {'text': 'N'})
                    answered = True
                # 'Errors:', not 'End assembly': the banner prints
                # incrementally and a poll can catch it mid-print --
                # KPFD2 was captured as '--End assembly, 416' with
                # ' bytes, Errors: 0' not yet drawn, which reads as
                # an error verdict; deterministic, because the fast
                # backend lands the step boundary on the same cycle
                # every run, so an unrelated kernel size change
                # turns it on and off. check_dual.py:78 fixed this
                # exact bug 2026-08-20; this loop missed the twin.
                if 'Errors:' in s or 'MEMORY IN USE' in s:
                    banner = next(l.strip() for l in s.splitlines()
                                  if 'End assembly' in l
                                  or 'MEMORY IN USE' in l)
                    break
            if banner is None:
                print(f'[check-librel] {base}: NO END-OF-ASSEMBLY; screen:\n'
                      f'{cr.screen(c)}', file=sys.stderr)
                banners[base] = None
                # try to recover to the menu for the next module
                c.call_tool('type', {'text': '\r'})
                cmb.wait_quiet(c)
                c.call_tool('type', {'text': 'Q\r'})
                cmb.wait_quiet(c)
                continue
            banners[base] = banner
            # a failing banner's ERROR LINES are on this same screen
            # and vanish at the Q below -- print them now, or the
            # diagnosis costs a second boot with a subset run.
            if 'Errors: 0' not in banner:
                print(f'[check-librel] {base}: screen at failure:\n'
                      f'{cr.screen(c)}', file=sys.stderr)
            cmb.wait_quiet(c)
            c.call_tool('type', {'text': 'Q\r'})
            cr.wait(c, cr.MENU_MARKER)
            cr.settle(c, 2)
    finally:
        c.close()
    return banners


def main():
    for need, fix in ((SRC_IMG, 'make vendor-merlin'),
                      (SUPERVISOR, 'build verilogapple')):
        if not os.path.exists(need):
            print(f'error: {need} missing -- {fix}', file=sys.stderr)
            return 2
    # BEFORE ANYTHING BOOTS. Every input to Merlin's source budget is
    # known on the host, and the failure it prevents costs an emulator
    # cycle to observe and names neither the size nor the file.
    if not check_source_budgets():
        return 1
    meta = stage()
    banners = drive(meta)

    os.makedirs(OUT_DIR, exist_ok=True)
    vol = a2til.open_image(DATA_IMG)
    failures = []
    for base in sorted(meta):
        banner = banners.get(base)
        if banner is None:
            failures.append(f'{base}: assembly never completed')
            continue
        if 'Errors: 0' not in banner:
            failures.append(f'{base}: {banner}')
            continue
        try:
            ent = vol.entry_for(f'{DATA_DIR}/{base}R')
            data = bytes(vol.read_file(f'{DATA_DIR}/{base}R'))
        except FileNotFoundError:
            failures.append(f'{base}: clean banner but {DATA_DIR}/{base}R '
                            f'was never written (DSK path?)')
            continue
        if ent.type != 0xF8:
            failures.append(f'{base}: object type ${ent.type:02X}, not the '
                            f'Merlin REL $F8')
        with open(os.path.join(OUT_DIR, f'{base.lower()}.rel'), 'wb') as fh:
            fh.write(data)
        meta[base].update({'type': ent.type, 'aux': ent.aux_type,
                           'len': len(data), 'banner': banner})
        print(f'[check-librel] {base:12s} {banner:44s} '
              f'obj {len(data):5d}B aux ${ent.aux_type:04X}')
    with open(os.path.join(OUT_DIR, 'meta.json'), 'w') as fh:
        json.dump(meta, fh, indent=1, sort_keys=True)

    if failures:
        for f in failures:
            print(f'[check-librel] FAIL: {f}', file=sys.stderr)
        return 1
    print(f'[check-librel] PASS: all {len(meta)} generated liba+kernel '
          f'REL forms '
          f'assemble Errors: 0 under real Merlin-8; references exported '
          f'to build/lib/')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
