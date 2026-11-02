#!/usr/bin/env python3
"""Import every T4 filesystem-tranche module (CONTRACT sec 5), merge them
through e2e_fs_common.Registry, assign cids in a stable order, and
generate the `sh` script + the host/image staging trees.

MODULE_NAMES below is the CONTRACT sec 5 table, in that order -- cid
assignment is therefore stable across runs regardless of which packages
have landed yet.  A module not present in this worktree is SKIPPED with a
printed note rather than an ImportError (per E1's brief: the other five
packages do not exist yet here), so this script -- and everything that
imports it -- runs today with just the E1 spine + the smoke case.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e_fs_common as FC   # noqa: E402
import e2e_fsmap as FM       # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))

#: CONTRACT sec 5's module table, in order.  Not glob-discovered: cid
#: stability depends on a fixed import order, and a module the TL has not
#: merged yet must be silently absent, not silently reordered in.
MODULE_NAMES = [
    'e2e_fs_ls',          # E2  ls
    'e2e_fs_walk',        # E3  find + du
    'e2e_fs_mutate',      # E4  rm + mv + cp + mkdir
    'e2e_fs_meta',        # E5  chmod + file
    'e2e_invariants',     # E5  ps + pwd + df  (oracle 3)
    'e2e_fs_idiom',       # E6  the form a human types
    # 'e2e_fs_smoke' (E1) DELETED at merge, per its own docstring: all
    # six real packages are present now (E7 integration pass,
    # 2026-08-23), so the pipeline smoke case has nothing left to prove.
]


def load_modules(names=MODULE_NAMES):
    """Import each named module; missing ones are skipped with a printed
    note, never an ImportError -- this tranche's other five packages do
    not exist in every worktree that builds this corpus."""
    mods = []
    for name in names:
        try:
            mod = __import__(name)
        except ImportError as e:
            print(f'[e2e-fs-corpus] note: {name} not present yet, '
                 f'skipping ({e})')
            continue
        mods.append(mod)
    return mods


def build_registry(names=MODULE_NAMES):
    registry = FC.Registry()
    for mod in load_modules(names):
        registry.add_module(mod)
    return registry


REGISTRY = build_registry()
#: ALL_CASES -- the complete, UNFILTERED registry output (129 cases as
#: of 2026-08-23), for anyone who needs the whole set regardless of
#: quarantine (REGISTRY.check_citations()/tree_groups()/divergence
#: bookkeeping all read CORP.REGISTRY directly, never CORP.CASES, so
#: they are unaffected by the filter below -- a DIVERGENCE entry cited
#: only by a quarantined case, e.g. cases 37/38's 'DESTROY succeeds on
#: a directory operand', must still count as cited, not go dead).
ALL_CASES = REGISTRY.cases

#: HANG QUARANTINE (T4 E9, 2026-08-23) -- cases withheld from the
#: GENERATED SCRIPT because running them hangs the guest permanently.
#: Shape mirrors e2e_fs_mutate.DEFECTS (a case+reason keyed table), but
#: this is a DIFFERENT kind of hole: a DEFECTS/KNOWN-DEFECT case still
#: RUNS and is graded against a pinned wrong answer; a case in THIS
#: table never runs at all -- printing it explicitly (every run, by
#: name) is the whole point, since a case that is silently not run is
#: worse than one that fails (task brief, verbatim).
#:
#: MECHANISM, measured on a minimal bisected image (scripts run
#: outside this tree -- build_mini.py/scenarios.py, not committed,
#: T4 E9 rig session 2026-08-23; `make e2efs-image` + this file's own
#: staging reused, only the SCRIPT body and MUT fixtures were hand-
#: written down to 1-2 lines per attempt):
#:
#:   [fact] a SPAWNED CHILD that calls MLI DESTROY (SYS_UNLINK, $C1)
#:   -- every `rm` case, via src/bin/rm.s's own `jsr SC_UNLINK` -- is
#:   never reaped by its parent's wait(): sh blocks forever in
#:   RUN_PIPELINE's :waitloop (src/bin/sh.s ~6299, `jsr SC_WAIT`),
#:   backed by the kernel's PRC_WAIT (src/kernel/process.s:683) which
#:   never observes the child reach PCB_ZOMBIE. Reproduced on the
#:   SIMPLEST possible script -- one line, `RM <file> > <redirect>
#:   2>&1`, nothing after it but the harness's own implicit EXIT --
#:   with a measured boot+exit floor of one 5,000,000-cycle step and
#:   this case alone still not done at 100,000,000+ cycles before the
#:   rig killed the attempt under load. Confirmed independent of: rm's
#:   operand count (1 vs 3 -- both hang); whether the target directory
#:   is emptied to zero files (a 2-file dir with one file removed
#:   hangs identically to a 1-file dir emptied outright, ruling out
#:   the empty-subdirectory theory this investigation started with);
#:   and what (if anything) runs next (bare EXIT, `ECHO $? >> ST`, or
#:   a second external command's own `>` redirect all hang the same
#:   way) -- in every case rm's OWN output file is written correctly
#:   first (its `> Onn` redirect opens and closes fine, and the target
#:   IS removed from the volume), then NOTHING after it ever runs:
#:   exactly the real corpus's own signature, O35 never created after
#:   case 34's rm.
#:
#:   [fact] CONTROL: the same harness with MKDIR in place of RM (a
#:   spawned child that calls MLI CREATE, $C0, instead of DESTROY)
#:   reaps normally in one step -- isolating the trigger to DESTROY
#:   specifically, not "any write-class MLI call from a spawned
#:   child".
#:
#:   [likely] WHERE, not fixed (out of scope for the change that
#:   found it, which was locate-and-quarantine only and did not
#:   touch src/bin or src/kernel): PRC_UNLINK (src/kernel/
#:   procfile.s:96) routes through LZ_INVAL (src/kernel/lazyfree.s:
#:   677, the STICKY lazy-bank-cache invalidation hook shared
#:   VERBATIM with PRC_CREAT/PRC_RENAME) and PML_DSTRY_CLL (src/
#:   kernel/procfd2.s:334, the raw MLI $C1 bracket -- structurally
#:   IDENTICAL to mkdir's own PMLI_CRT_CALL at procfd2.s:290 apart
#:   from the call number). Both of those shared paths were read
#:   side-by-side against their CREATE counterparts and show no
#:   asymmetry, so the actual fork point -- real ProDOS MLI DESTROY's
#:   own behaviour, PRC_UNLINK's PRC_PUSH_BANK-on-a-HELD-tag-match arm
#:   (LZ_INVAL, lazyfree.s:677's header), or PRC_EXIT's SCH_WAKEUP
#:   (process.s ~648) misfiring for a process whose last file op was
#:   a DESTROY -- was NOT chased to a conclusion. A precisely-located
#:   hang with an honest "root cause not chased" beats a confident
#:   guess (task brief, verbatim).
#:
#:   [reported] RISK, not independently confirmed: src/bin/mv.s ALSO
#:   calls SC_UNLINK (grep hit, not traced) -- if any `mv` case
#:   exercises that code path it may hang the same way. No mv case is
#:   quarantined here because none was independently reproduced to
#:   hang; if `make check-e2e-fs` hangs again at an mv case after this
#:   table ships, that is Nth in this series and gets its OWN entry,
#:   per this task's own instructions ("report every distinct hang
#:   separately").
#:
#: WHY ALL NINE, not just 34/35: the FIRST rm case reached in script
#: order (today, cid 34) already hangs the shell PERMANENTLY -- every
#: line after it, not just its rm siblings, would be unreachable if it
#: ran. Cases 36/37/38/56/69/71/125 were never independently exercised
#: on the rig (34 already hangs first in the real corpus) -- they are
#: quarantined by the same-mechanism generalisation above (every one
#: of them calls the same SYS_UNLINK), not by individual reproduction.
#: Withholding all nine is the only way the other 120 cases get a
#: chance to run at all.
# EMPTIED 2026-08-24. The hang is FIXED and these nine cases run.
#
# It was never DESTROY, and never maux's kernel. Two bugs, one behind
# the other, both found by bisecting a 4-second reproducer
# (scripts/probe_rmhang.py):
#
#   1. a2til wrote every subdirectory header's parent_entry_number
#      0-based where ProDOS reads it 1-based (a2til#16, fixed in the
#      tool). Real ProDOS walking up from a subdirectory landed one
#      entry early -- on the directory HEADER when that subdirectory
#      was its parent's first entry -- read two header bytes as a
#      block number, and retried the resulting out-of-range write
#      forever. `rm` of a file two levels deep hung; root and one
#      level were fine, which is why the shape looked like DESTROY.
#
#   2. find/du's SKIPRESUME counted down CURRESN itself -- the level's
#      absolute position -- so any directory holding two or more
#      subdirectories made the walk re-descend into the first one
#      forever.
#
# The entries are DELETED, not commented out, per this file's own
# ratchet convention. The nine cases are back in the generated script
# and their coverage with them -- and their absence had been silently
# drifting the MUT trees, because the cases downstream of a withheld
# `rm` inherit state its removal never happened to.
HANG_QUARANTINE = {}

#: CASES -- the RUNNABLE subset script_lines()/corpus_summary() emit
#: and every gate iterates (CORP.CASES, not CORP.REGISTRY.cases): cid
#: order and cid VALUES are preserved verbatim (a withheld case's O-file
#: number is simply never used, e.g. O34/O35 are absent and O33 is
#: followed by O36) -- only membership is filtered, so nothing
#: downstream has to renumber anything.
CASES = [c for c in ALL_CASES if c.cid not in HANG_QUARANTINE]


def script_lines():
    """The `sh` script body, CONTRACT sec 3.5/8: one line per case, an
    `ECHO $? >> ST` appending its exit status (statuses are an oracle in
    their own right -- see docs/E2E.md sec 1's `diff` bug), and -- for a
    case with cwd='restore' -- a non-case `CD /mnt/MAUX` line immediately
    after that does NOT append to ST (so ST stays exactly len(CASES)
    long)."""
    lines = []
    for case in CASES:
        lines.append(case.sh_line())
        lines.append(f'ECHO $? >> {FM.IMG_CTL}/{FM.STATUS_NAME}')
        if case.cwd == 'restore':
            lines.append(f'CD {FM.IMG_ROOT}')
    lines.append('EXIT')
    return lines


def script_bytes():
    sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
    from a2til import convert
    text = ''.join(line + '\n' for line in script_lines()).encode('ascii')
    return convert.text_from_host(text, high_bit=True)


# ---------------------------------------------------------------------------
# Host + image staging.  RO/MUT go through e2e_fsmap.stage_tree/
# host_stage_tree (the prodos module, per CONTRACT sec 3.0's correction --
# NEVER a2til mirror, which cannot recurse into subdirectories at all).
# CTL/OUT go through `a2til mirror`, exactly like stage 1, because both
# are FLAT (CONTRACT sec 3.1/3.2).
# ---------------------------------------------------------------------------
def write_host_ro(host_ro):
    os.makedirs(host_ro, exist_ok=True)
    files = {k: v for k, v in REGISTRY.ro_files.items()}
    FM.host_stage_tree(host_ro, files, REGISTRY.ro_dirs)


def write_host_mut(host_mut_root):
    os.makedirs(host_mut_root, exist_ok=True)
    for tree, files in REGISTRY.mut_trees.items():
        plain = {k: v for k, v in files.items() if v is not FC.DIR}
        dirs = [k for k, v in files.items() if v is FC.DIR]
        FM.host_stage_tree(os.path.join(host_mut_root, tree), plain, dirs)


def stage_image_ro(root):
    """`root` is the mounted volume root, e.g. '/mnt/MAUX'.  Must be called
    AFTER e2e_fsmap.IMG_RO's parent exists (i.e. after the volume is
    mounted) and BEFORE the two `a2til mirror` passes for CTL/OUT, so
    `mirror`'s own directory listing of `root` never has to reconcile a
    half-built RO/MUT against anything (it never looks at them at all --
    see e2e_fsmap's module docstring -- but staging order still matters
    for prodos.mkdir's own parent-must-exist requirement)."""
    files = {k: v for k, v in REGISTRY.ro_files.items()}
    return FM.stage_tree(FM.IMG_RO, files, REGISTRY.ro_dirs)


def stage_image_mut(root):
    sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
    from a2til import prodos
    import vpath  # noqa: F401  (docs/VROOT.md)
    try:
        prodos.mkdir(FM.IMG_MUT)
    except FileExistsError:
        pass
    written = []
    for tree, files in REGISTRY.mut_trees.items():
        plain = {k: v for k, v in files.items() if v is not FC.DIR}
        dirs = [k for k, v in files.items() if v is FC.DIR]
        written += FM.stage_tree(f'{FM.IMG_MUT}/{tree}', plain, dirs)
    return written


def corpus_summary():
    by_tool = {}
    for c in CASES:
        by_tool[c.tool] = by_tool.get(c.tool, 0) + 1
    return {
        'modules': REGISTRY._modules,
        'cases': len(CASES),
        'by_tool': by_tool,
        'ro_files': len(REGISTRY.ro_files),
        'ro_dirs': len(REGISTRY.ro_dirs),
        'mut_trees': len(REGISTRY.mut_trees),
        'divergence_entries': len(REGISTRY.divergence),
        'defects': len(REGISTRY.defects),
        'invariants': len(REGISTRY.invariants),
        'hang_quarantine': len(HANG_QUARANTINE),
    }


if __name__ == '__main__':
    s = corpus_summary()
    print(f"modules loaded: {s['modules']}")
    print(f"cases: {s['cases']}  by tool: {s['by_tool']}")
    print(f"RO files: {s['ro_files']}  RO dirs: {s['ro_dirs']}  "
         f"MUT trees: {s['mut_trees']}")
    print(f"DIVERGENCE entries: {s['divergence_entries']}  "
         f"DEFECTS: {s['defects']}  INVARIANTS: {s['invariants']}")
    print(f"HANG QUARANTINE: {s['hang_quarantine']} case(s) withheld "
         f"from the generated script (see e2e_fs_corpus.HANG_QUARANTINE)")
    for cid, (tool, reason) in sorted(HANG_QUARANTINE.items()):
        print(f'  HANG QUARANTINE case {cid} ({tool}): {reason}')
    errs, dead = REGISTRY.check_citations()
    print(f'citation errors: {len(errs)}  dead entries: {len(dead)}')
    for line in script_lines():
        print(f'  {line}')
