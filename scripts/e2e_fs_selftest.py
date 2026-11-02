#!/usr/bin/env python3
"""Teeth for the T4 filesystem tranche, host-only (`make check-e2e-fs-host`)
-- no emulator, per CONTRACT sec 7's per-package requirements and
docs/E2E.md's own "a comparator is vacuous until shown otherwise."

Three things this drives, in order:

  1. e2e_fsmap's own four jobs, which own ZERO Cases (E1's brief), so
     their teeth live here directly: a a2til-built SCRATCH volume (pure
     Python, no emulator -- "host-only" is about the emulator, not about
     a2til) proves check_blocks_used() rejects a poked-wrong blocks_used,
     decode_date_raw() survives an Extended-format stamp that would make
     a2til's own Date descriptor raise, and volume_dir_order() actually
     DIFFERS from sorted order on a deliberately non-alphabetical-
     creation fixture (this tranche's own non-degeneracy proof for job
     (d), CONTRACT sec 7.6).
  2. Every case in e2e_fs_corpus.REGISTRY: synthesise-and-accept, then
     mutate-and-reject (CONTRACT sec 7.1/7.2), the defect two-sided
     contract (sec 7.5), and -- for poststate=True cases -- the tree
     comparator's own five-way mutation battery (sec 7.3).
  3. The ratchet's two invariants over the MERGED registry (uncited
     citation, dead entry), via e2e_fs_common.Registry.check_citations --
     the same MECHANISM stage 1 uses, a different table (e2e_divergence.
     check_citations_table's whole reason to exist).
"""
import os
import shutil
import struct
import sys
import tempfile
import types

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e_fs_common as FC     # noqa: E402
import e2e_fs_corpus as CORP   # noqa: E402
import e2e_fsmap as FM         # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)


# ===========================================================================
# 1. e2e_fsmap's own teeth -- a scratch volume, built and mounted with
#    a2til alone (no emulator).
# ===========================================================================
def _scratch_volume():
    tmp = tempfile.mkdtemp(prefix='maux-e2efs-selftest-')
    path = os.path.join(tmp, 'scratch.po')
    prodos.create(path, name='SCRATCH', blocks=280)
    prodos.mount(path)
    root = '/mnt/SCRATCH'
    # A seedling (<=512B) and a sapling (>512B), for the block cross-check.
    prodos.write(f'{root}/SEED', b'x' * 100, file_type=0x04, overwrite=True)
    prodos.write(f'{root}/SAP', b'y' * 600, file_type=0x04, overwrite=True)
    # A directory whose creation order is DELIBERATELY non-alphabetical
    # (CONTRACT sec 7.6 non-degeneracy): 'ZEBRA' first, 'APPLE' second.
    # If volume_dir_order() ever quietly started returning sorted order
    # (e.g. someone "fixed" scandir to sort), this fixture would go
    # degenerate and the assertion below would catch it.
    prodos.mkdir(f'{root}/ORDER')
    prodos.write(f'{root}/ORDER/ZEBRA', b'z\n', file_type=0x04, overwrite=True)
    prodos.write(f'{root}/ORDER/APPLE', b'a\n', file_type=0x04, overwrite=True)
    prodos.unmount('SCRATCH')
    return tmp, path


def _fsmap_teeth():
    problems = []
    tmp, path = _scratch_volume()
    try:
        prodos.mount(path)
        root = '/mnt/SCRATCH'
        try:
            # -- (b) block cross-check accepts the real allocator's answer --
            for name in ('SEED', 'SAP'):
                try:
                    FM.check_blocks_used(f'{root}/{name}')
                except AssertionError as e:
                    problems.append(f'check_blocks_used({name}) rejected a '
                                    f'CORRECT a2til-written file: {e}')

            # -- and REJECTS a poked-wrong blocks_used (the cross-check's
            # own teeth: CONTRACT sec 2b, "a wrong a2til is a loud failure,
            # not a silent oracle").  Entries handed out by scandir/
            # entry_for/stat are READ-ONLY by a2til's own design ("this is
            # the supported way to edit metadata" -- Volume.set_file_info's
            # docstring), and set_file_info has no blocks_used= parameter
            # (nothing legitimate ever needs to lie about it), so proving
            # this cross-check has teeth means reaching past the public API
            # on purpose, via the same private write-intent lookup
            # set_file_info itself uses (_find_entry(..., write=True)).
            vol = prodos._session.get(prodos._foldname('SCRATCH'))
            wentry = vol._find_entry(vol._resolve_dir('/'), 'SEED', write=True)
            real = wentry.blocks_used
            wentry.blocks_used = real + 5
            try:
                FM.check_blocks_used(f'{root}/SEED')
                problems.append('check_blocks_used ACCEPTED a poked-wrong '
                                'blocks_used -- the cross-check has no teeth')
            except AssertionError:
                pass  # correctly rejected
            # restore, so the rest of this function sees a sound volume
            wentry = vol._find_entry(vol._resolve_dir('/'), 'SEED', write=True)
            wentry.blocks_used = real

            # -- (c) date decode never raises on an Extended-format stamp,
            # and correctly calls it blank.  learning:01M07A3XXC1SS5SQYH4CZCPV44's
            # own measured example: date=$8CB3 time=$97E4 decodes under the
            # LEGACY layout to hour 151/minute 228 -- impossible, and a2til's
            # Date descriptor's __get__ calling datetime(...) on that raises
            # ValueError. decode_date_raw must not. --
            extended_raw = bytes([0xB3, 0x8C, 0xE4, 0x97])
            d = FM.decode_date_raw(extended_raw)
            if d['legacy_valid']:
                problems.append(
                    f'decode_date_raw({extended_raw!r}) called an Extended '
                    f'stamp legacy_valid -- expected blank/raw hour>=24 or '
                    f'minute>=60: got {d}')

            # -- and DOES decode a legacy-valid stamp, agreeing with
            # a2til's own Date descriptor once the raw check has cleared it --
            # year_raw=25 -> 2000+25=2025 (a2til's own windowing: raw<40 ->
            # 2000s, raw>=40 -> 1900s -- see a2til/prodos.py's Date.__get__).
            legacy_raw = struct.pack('<HBB', (25 << 9) | (6 << 5) | 15, 30, 14)
            d2 = FM.decode_date_raw(legacy_raw)
            if not d2['legacy_valid']:
                problems.append(f'decode_date_raw({legacy_raw!r}) called a '
                                f'legacy-valid stamp invalid: {d2}')
            elif (d2['year'], d2['month'], d2['day'], d2['hour'],
                 d2['minute']) != (2025, 6, 15, 14, 30):
                problems.append(f'decode_date_raw({legacy_raw!r}) decoded '
                                f'wrong: {d2}')

            # -- (d) ordering: volume_dir_order != sorted order on the
            # deliberately non-alphabetical ORDER fixture (non-degeneracy) --
            vol_order = FM.volume_dir_order(f'{root}/ORDER')
            sorted_order = sorted(vol_order, key=FM.ls_sort_key)
            if vol_order == sorted_order:
                problems.append(
                    f'NON-DEGENERACY FAILURE: volume_dir_order {vol_order} '
                    f'equals sorted order {sorted_order} on a fixture built '
                    f'specifically to differ -- the order oracle would have '
                    f'no teeth')
            if vol_order != ['ZEBRA', 'APPLE']:
                problems.append(f'volume_dir_order returned {vol_order}, '
                                f'expected creation order [ZEBRA, APPLE]')

            # -- read_tree() shape, spot-checked --
            tree = FM.read_tree(root)
            if set(tree) != {'SEED', 'SAP', 'ORDER'}:
                problems.append(f'read_tree({root}) top level = '
                                f'{sorted(tree)}, expected SEED/SAP/ORDER')
            elif tree['SEED']['content'] != b'x' * 100:
                problems.append('read_tree: SEED content mismatch')
            elif not tree['ORDER']['is_dir']:
                problems.append('read_tree: ORDER not reported as a directory')

        finally:
            prodos.unmount('SCRATCH')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # -- (a) names: legal/illegal, independent of any volume --
    for bad in ('my-file', '.profile', '2start', 'foo_bar', 'A' * 16, ''):
        try:
            FM.check_name(bad)
            problems.append(f'check_name({bad!r}) did not raise')
        except ValueError:
            pass
    for good in ('HELLO', 'A.B.C', 'A' * 15, 'A'):
        try:
            FM.check_name(good)
        except ValueError as e:
            problems.append(f'check_name({good!r}) raised on a LEGAL name: {e}')

    # -- CONTRACT sec 3.2: the forbidden-operand-prefix check --
    for bad_op in (FM.IMG_OUT + '/O01', FM.IMG_CTL + '/ST', FM.IMG_CTL):
        try:
            FM.check_operand(bad_op)
            problems.append(f'check_operand({bad_op!r}) did not raise')
        except ValueError:
            pass
    FM.check_operand(FM.IMG_RO + '/FILE')     # must NOT raise

    return problems


# ===========================================================================
# 2. compare_tree/tree_mutants -- proven directly (no real poststate case
#    exists yet; this is the infrastructure's own teeth, and the SAME
#    functions any future poststate=True case's per-case check reuses).
# ===========================================================================
def _tree_teeth():
    problems = []
    want = {
        'A': {'is_dir': False, 'type': 0x04, 'size': 2, 'content': b'a\n',
             'children': None},
        'SUB': {'is_dir': True, 'type': 0x0F, 'size': None, 'content': None,
                'children': {
                    'B': {'is_dir': False, 'type': 0x04, 'size': 2,
                         'content': b'b\n', 'children': None},
                }},
    }
    ok, detail = FC.compare_tree(want, want)
    if not ok:
        problems.append(f'compare_tree rejected an IDENTICAL tree: {detail}')
    for label, mutant in FC.tree_mutants(want):
        ok2, _ = FC.compare_tree(want, mutant)
        if ok2:
            problems.append(f'compare_tree ACCEPTED tree mutant {label!r} '
                            f'-- it is measuring nothing')
    if len(FC.tree_mutants(want)) < 5:
        problems.append(f'tree_mutants produced only '
                        f'{len(FC.tree_mutants(want))} mutants, expected '
                        f'5 (missing/extra/size/type/content, CONTRACT '
                        f'sec 7.3)')
    return problems


# ===========================================================================
# 2b. A REAL scratch volume for the merged corpus's own RO/MUT fixtures.
# E7 integration, 2026-08-23: several VOL-oracle comparators (ls -l's
# type/eof/date columns, file's storage_type/type, chmod's access byte
# and read-modify-write proof, du/find's block counts and directory
# order) need actual GET_FILE_INFO data that no host directory can
# supply -- "no emulator" (CONTRACT/docs/E2E.md's own words) is about
# the 6502 emulator, never about a2til itself, which is pure Python.
# Built exactly the way build_e2efs_image.py stages the real image
# (CONTRACT sec 3.0: prodos.mkdir/write, never a2til mirror), just
# against a throwaway volume instead of build/e2efs.po. Nothing here
# ever boots or mutates via a guest process, so .pre and .post are the
# SAME snapshot -- there is no "run" for them to differ across in this
# context, which is exactly the "nothing mounted" degrade judge()'s own
# docstring anticipates for callers with no real boot, just widened
# here to "a real volume, but no guest run happened to it".
# ===========================================================================
def _build_registry_volume():
    tmp = tempfile.mkdtemp(prefix='maux-e2efs-selftest-corpus-')
    image = os.path.join(tmp, 'e2efstest.po')
    prodos.create(image, name='MAUX', blocks=1600)
    prodos.mount(image)
    root = FM.IMG_ROOT
    try:
        CORP.stage_image_ro(root)
        CORP.stage_image_mut(root)
        pre_snap = FC.VolumeSnapshot(FM.snapshot_volume(root))
        # case.vol_op -- see Case's own docstring on why this exists:
        # applied in cid order over this SAME live mount, so a
        # VOL-oracle case whose comparator reads volume.post (chmod's
        # access byte, rm's DESTROY-gate presence check) has a REAL
        # post-mutation state to be judged against, not just the
        # pristine staged one. A tree_seq= group's vol_ops accumulate
        # naturally because every case in cid order mutates the same
        # live mount.
        #
        # post_by_cid -- FINDING, 2026-08-23 (see the report): an
        # INCREMENTAL snapshot taken right after each vol_op-bearing
        # case's own mutation, keyed by that case's cid, so a
        # mid-sequence case (e.g. e2e_fs_meta.py's chmod_access on
        # M5RWF, unlocked again by a LATER case in the same tree_seq=
        # group) can be judged against its OWN step's state via
        # Volume.post_at(case), not the single whole-corpus-final
        # snapshot -- see post_at()'s own docstring for why the REAL
        # run (check_e2e_fs.py) cannot offer this at all.
        post_by_cid = {}
        for case in CORP.CASES:
            if case.vol_op is not None:
                case.vol_op(root)
                post_by_cid[case.cid] = FC.VolumeSnapshot(
                    FM.snapshot_volume(root))
        post_snap = FC.VolumeSnapshot(FM.snapshot_volume(root))
    except Exception:
        prodos.unmount('MAUX')
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    volume = FC.Volume(pre=pre_snap, post=post_snap, root=root,
                       image_path=image, post_by_cid=post_by_cid)
    return tmp, volume


def _teardown_registry_volume(tmp):
    prodos.unmount('MAUX')
    shutil.rmtree(tmp, ignore_errors=True)


# ===========================================================================
# 3. Per-case teeth, driven off e2e_fs_corpus.REGISTRY.
#
# BUG FOUND DURING INTEGRATION (E7, 2026-08-23): Case.reference() shells
# out to the REAL host tool for oracle='REF'/'REF+VOL' cases -- for a
# MUTATING tool (rm/mv/cp/mkdir, all of e2e_fs_mutate.py's cases) that
# means the host reference invocation actually deletes/renames/creates
# files under `host_mut` for real, exactly like the guest maux run
# mutates the VOLUME. A poststate=True case's own comparison then needs
# a PRISTINE copy of its tree as staged -- reading straight from
# `host_mut` after case.reference() already ran would compare against
# an ALREADY-MUTATED tree and, for `rm` in particular, crash outright
# (FileNotFoundError: ref_op tries to remove a file the host reference
# already removed). check_e2e_fs.py's poststate_verdict has the exact
# same shape of bug against HOSTDIR_MUT -- fixed there too. The fix:
# snapshot `host_mut` ONCE, before any case.reference() call can mutate
# it, and read poststate's `src` from that pristine copy, never from
# the live (and by then possibly mutated) `host_mut`.
# ===========================================================================

# ===========================================================================
# EXEMPTIONS -- E8, 2026-08-23 (task JOB 2), stable-key retrofit
# 2026-08-24. Per (case_id, mutant-label), a ONE-LINE, PROVEN argument
# for why that specific mutation is invisible to that specific case's
# comparator BY DESIGN, not by oversight. Every other mutant kind for
# these cases IS rejected (see the STRENGTHENED comparators above this
# file's own diff: _parse_ps's "exactly one RUNNING row" check and
# cmp_invariant_resolved's termination check each closed several of
# these before this table was needed at all -- this table lists only
# what remained honestly unstrengthenable). A silent skip is forbidden
# (CONTRACT/task rule): run() below PRINTS every one of these, by name,
# with its reason, every run, and the total count. NEVER weakens a
# comparator or a case to make this list shorter -- these are
# DECLARATIONS about what a property provably cannot see, not a way to
# make a real gap disappear.
#
# CID DRIFT (T4 review, 2026-08-23, second occurrence of this exact bug
# in this table): e2e_fs_mutate.py's MUT24/MUT25 (mv directory-SRC and
# mv-onto-existing-empty-dir, the T4 review's own DEFECT 1/2 corpus
# gap) were inserted into mutate's `cases()` between the old ARGBUFSZ
# case and the first `cp` case. cid is assigned by REGISTRATION ORDER
# across ALL modules (ls, find+du, mutate, fs_meta, invariants, idiom),
# so every case registered after that insertion point -- not just
# mutate's own remaining cases, every LATER MODULE's cases too --
# shifted by +2. Every key below this comment that named a cid >= 89
# was silently pointing at a DIFFERENT case after the insertion (the
# EXEMPTIONS-staleness ratchet elsewhere in this file does not catch
# this: the cid still EXISTS, it just means something else now). Re-
# derived by MEASUREMENT, not arithmetic alone: dumped (cid, tool,
# argv) for both e2e_fs_mutate.py@6a21d2b (pre-insertion, 120 cases)
# and the current tree (122 cases), matched each old cid's (tool,
# argv) by RANK among same-shaped duplicates (several cd/[]/ps/[]/
# df/[] cases share tool+argv, so position among same-tool-same-argv
# siblings was the actual proof, not tool+argv alone) -- every match
# came back a uniform +2, confirmed for all eight keys individually,
# not assumed from the first. See the task report for the full
# before/after dump this was checked against.
#
# KEY RETROFIT (2026-08-24, tranche 2): the follow-up is now done.
# Case has an explicit immutable `case_id`, Registry rejects duplicates
# and missing ids, and this table keys on `(case_id, label)`. The old
# temptation, tool+argv, remains explicitly rejected: the measured
# collision class still exists (`cd []`, `ps []`, `df []`), and adding
# a comparator/note tiebreaker after the fact would just move the drift
# risk instead of making the case identity part of the case itself.
# ===========================================================================
EXEMPTIONS = {
    # (69, 'flip one bit') was HERE and is deleted, not commented out.
    # Case 69 is one of the nine `rm` cases E9 withheld into
    # e2e_fs_corpus.HANG_QUARANTINE (MLI DESTROY hangs sh's reap), so
    # the cid no longer exists and the selftest's own staleness check
    # fired on it -- correctly. An exemption table is a ratchet like
    # every other table here: it only tightens, and an entry that
    # stopped being needed is deleted rather than left as cover for
    # the next gap. WHEN THE DESTROY HANG IS FIXED and case 69 comes
    # back, re-derive the exemption then -- do not resurrect this text
    # from history without re-proving that the mutation is still
    # invisible to cmp_rm_status_only. Reconciled at merge by the TL,
    # 2026-08-23, between E8's exemption work and E9's quarantine.
    # -- 2026-08-24. These two became REACHABLE for the first time when
    # -- the ('*', 'dot and dotdot are not resolved outside cd') pin was
    # -- retired: while a case is pinned, the selftest checks the pin's
    # -- two-sided contract INSTEAD of running the comparator's mutants,
    # -- so retiring a pin can expose a comparator nobody had exercised.
    # -- That is the pin machinery hiding a weakness, and it is worth
    # -- knowing it can.
    ('idiom.find-dot', 'reorder two lines'): (
        "cmp_name_multiset compares the SET of names, deliberately -- "
        "this case's oracle is REF, and the HOST walks its directory "
        "in its own order, so line order here is not a property either "
        "side can be held to. ORDER IS STILL CHECKED for this exact "
        "idiom, one module over: fs_walk.find-dot runs `CD FT ; find .` "
        "against a VOL-derived expectation through cmp_find_walk's "
        "dot_root branch, which is an exact byte compare including "
        "order. So the pair is not blind -- the REF twin checks the "
        "NAMES against the host, the VOL twin checks the ORDER against "
        "the volume, and neither alone would."),
    ('idiom.find-dotdot', 'reorder two lines'): (
        "Same as idiom.find-dot above, for the `..` spelling: REF "
        "oracle, so names only; fs_walk.find-dotdot is the VOL twin "
        "that checks order exactly."),
    ('fs_ls.trailing-flag-refused', 'flip one bit'): (
        "cmp_ls_refused (e2e_fs_ls.py) is DELIBERATELY structural-only "
        "(ENTRIES['ls', 'usage-error refusal: wording and exit status "
        "not differential']) -- the operator's own ruling for this "
        "specific case (C10, the usage-contract DEFECT's retirement) "
        "forbids hardcoding maux's own usage text as an oracle, so the "
        "comparator checks only 'something was said' and 'no operand "
        "was printed as a successfully-listed entry', never any exact "
        "byte. A single-bit flip inside the synthetic usage message's "
        "own content changes neither property. 'clear one high bit' is "
        "not exempted (it is rejected generically by decode_maux_text's "
        "ENCODING check, before any comparator runs); 'truncate one "
        "byte' is not exempted either (cmp_ls_refused's own line-"
        "terminator check catches it); 'drop/duplicate/reorder a line' "
        "are not generated at all for this case's single-line output "
        "(FC._mutants requires more than 2/3 \\x8d-separated segments). "
        "Verified, 2026-08-23: flipping bit 0 of the byte immediately "
        "before the terminator (')' -> a different low-ASCII byte in "
        "the message body) leaves both checked properties unchanged."),
    ('inv.failed-cd', 'flip one bit'): (
        "cmp_cd_status (e2e_invariants.py) deliberately does not check "
        "cd's diagnostic WORDING, the same docs/E2E.md sec 9.7 "
        "precedent as case 69 above -- its own property is success/"
        "failure SHAPE (empty vs non-empty, properly terminated), which "
        "a same-length content mutation does not change."),
    # -- (94, 'flip one bit') and (96, 'flip one bit') USED to live here.
    # -- Both argued that a PPID-digit mutation was cmp_ps_parents'
    # -- business and not cmp_ps_ascending's or cmp_ps_spawn's. That was
    # -- true when written and is now FALSE: the adversarial review's
    # -- FINDING 3 moved parent-chain well-formedness INTO _parse_ps,
    # -- which all three ps comparators call, so every one of them now
    # -- rejects this mutant on its own. The gate said so itself --
    # -- "was not actually needed this run ... consider deleting the
    # -- entry" -- and this is that deletion.
    # --
    # -- Deleted at INTEGRATION, not by either author, because neither
    # -- could see it: the strengthening landed in e2e_invariants.py on
    # -- one branch and the table lives in this file on another, so the
    # -- staleness only exists once both are merged. (PM, 2026-08-23.)
    ('idiom.ls-clustered-flag', 'flip one bit'): (
        "cmp_ls_dir_refused (e2e_fs_idiom.py) is the same DELIBERATELY "
        "structural-only shape as case 10's cmp_ls_refused (identical "
        "argument, reused: ENTRIES['ls', 'usage-error refusal: wording "
        "and exit status not differential']) -- it checks 'something "
        "was said', 'no operand printed as a successfully-listed "
        "entry', AND (its own strengthening over case 10, for a "
        "DIRECTORY operand) 'none of IDIOM's real children (A, B, SUB, "
        "PROJECT) printed as a listed entry'. A single-bit flip inside "
        "the synthetic usage message's own content changes none of "
        "these: the message contains no substring that already equals "
        "IDIOM_PATH, its basename, or any child name, so no one-bit "
        "corruption of it can produce one by accident either. 'clear "
        "one high bit'/'truncate one byte'/line-count mutants are not "
        "exempted for the same reasons as case 10 (ENCODING check, "
        "line-terminator check, single-line output respectively)."),
    ('idiom.ls-trailing-flag', 'flip one bit'): (
        "compare='ls_refused' reuses e2e_fs_ls.cmp_ls_refused directly "
        "(imported as LS) -- this is case 10's own comparator, on a "
        "different case, with the identical exemption argument: the "
        "synthetic usage message contains neither 'NOSUCH' nor '-l' as "
        "a substring, so no single-bit flip inside it can produce "
        "either as a standalone output line."),
    ('idiom.find-lower', 'reorder two lines'): (
        "cmp_name_multiset (e2e_fs_idiom.py) is DELIBERATELY order-"
        "insensitive per its own docstring: it tests whether the dot "
        "idiom's `find` reaches the right SET of entries, not what "
        "order they print in. Directory order is e2e_fs_walk.py/E3's "
        "own VOL-oracled domain (cmp_find_tree there DOES check exact "
        "order against the volume's real directory order, with its own "
        "deliberately-non-alphabetical non-degeneracy fixture) -- "
        "checking order here too would duplicate, not strengthen, that "
        "assertion."),
    ('idiom.ps-lower', 'flip one bit'): (
        "cmp_invariant_resolved's property is deliberately narrow (its "
        "own INVARIANTS entry, ('*', 'idiom case word resolved to "
        "something other than sh itself')): did the lowercase word "
        "resolve to the real binary AT ALL, not what it then printed. "
        "ps's actual functional output is e2e_invariants.py/E5's "
        "domain; re-checking exact byte content here would duplicate "
        "that module's ownership and require this one to guess ps's "
        "byte-exact shape, which its own docstring explicitly disclaims."),
    ('idiom.df-lower', 'flip one bit'): (
        "same reasoning as case 123 (cmp_invariant_resolved's narrow "
        "resolved-at-all property), for df."),
    ('idiom.du-dot', 'reorder two lines'): (
        "ADDED 2026-08-24, and NOT the exemption it first looks like. "
        "The per-directory ROW order is asserted now: cmp_du_total "
        "compares every row exactly and positionally, in the "
        "post-order du.s actually emits -- a change made precisely "
        "BECAUSE this mutant appeared and was accepted. What survives "
        "is narrower. The mutation swaps line 0 (the `du: <path>: ...` "
        "DIAGNOSTIC for the over-cap entry) with line 1 (the first "
        "data row), and _split_diags partitions those two into "
        "separate sequences before either is compared, so their "
        "position RELATIVE TO EACH OTHER is the one thing forgiven -- "
        "exactly, and only, what this case's cited ('du', "
        "'stdout/stderr interleave order not checked') STRUCTURAL "
        "entry already declares, CONTRACT sec 9 leaving the merged-"
        "stream interleave unasserted. Both partitions keep SET+ORDER "
        "against their own oracle, so a reorder WITHIN the data rows, "
        "or within the diagnostics, is still caught. Re-derive rather "
        "than copy this if the fence fixture ever stops producing "
        "exactly one diagnostic line: the argument above depends on "
        "there being one, at line 0, to swap."),
    ('idiom.du-lower', 'reorder two lines'): (
        "same reasoning as case 103 (idiom.du-dot) directly above -- "
        "the swapped pair is the over-cap diagnostic and the first "
        "data row, which _split_diags separates before comparing, per "
        "this case's own ('du', 'stdout/stderr interleave order not "
        "checked') entry. Row order within the data partition IS "
        "asserted."),
}


def _case_teeth(host_ro, host_mut, volume):
    problems = []
    accepted = 0
    # TL fix, 2026-08-23 (PM review): a single `rejected` counter used to
    # accumulate at FOUR sites -- the output-mutant battery, the tree-
    # mutant battery, AND the defect dual-proof's "a correct answer
    # un-pins the defect" check below (originally line ~523) -- and the
    # gate's printed total (365 exempt-adjusted output + 85 tree + 14
    # pin-proofs = 464) could not be reconciled against docs/E2E.md sec
    # 10.12's own count (374 + 85 = 459) without knowing that. The third
    # site is not a MUTANT at all: nothing about the input is mutated,
    # it is an EXPIRY check -- does a genuinely correct answer flip a
    # live pin from DEFECT to DEFECT-FIXED. Split into two counters so
    # the printed line and sec 10.12's arithmetic reconcile without a
    # reader having to subtract: `mutant_checks` (output-mutant rejects
    # + tree-mutant rejects, INCLUDING the one tree mutant a defect-
    # pinned poststate case checks at line ~559 -- that one DOES use a
    # real tree_mutants() entry, unlike the stdout dual-proof) and
    # `pin_probes` (the defect stdout dual-proof only).
    mutant_checks = 0
    pin_probes = 0
    exempted = []          # [(case_id, cid, label, reason), ...]
    pristine_mut = host_mut + '.pristine'
    if os.path.isdir(host_mut):
        shutil.copytree(host_mut, pristine_mut)
    for case in CORP.CASES:
        # e2e_invariants.py's ps_spawn comparator degrades to a WEAKER
        # heuristic when case.spawn_pid is unset (CONTRACT EXTENSION 3
        # -- check_e2e_fs.py sets it from a real boot's R_SH_PID; no
        # boot happens here). Set it to 1 -- the pid the module's OWN
        # synth() fixture actually uses for its sleeping shell row --
        # so the selftest exercises the STRONGER, non-degraded check
        # (CONTRACT sec 7 has no "degraded mode is exempt" clause).
        # Harmless for every other case: nothing else reads spawn_pid.
        case.spawn_pid = 1
        ref_out, ref_err, _status, ref_extra = case.reference(host_ro, host_mut)
        out = FC.call_synth(case, ref_out, ref_err, ref_extra, volume, host_ro)
        err = b''   # see FC.call_synth's own docstring: normalised to
                    # ONE merged value; every downstream consumer here
                    # (judge/_mutants) only ever wanted one anyway.
        want = ref_out + ref_err

        # -- poststate tree, computed ONCE per case (whether or not it is
        # defect-pinned) so both the defect dual-sided proof below AND
        # the generic tree-mutant rejection proof reuse the same
        # want_tree/mutants rather than building it twice. --------------
        want_tree = None
        tree_muts = []
        if case.poststate:
            if case.tree is None:
                problems.append(f'case {case.cid}: poststate=True but no '
                               f'tree= -- nothing to read back')
            else:
                src = os.path.join(pristine_mut, case.tree)
                with tempfile.TemporaryDirectory() as scratch:
                    dst = os.path.join(scratch, case.tree)
                    shutil.copytree(src, dst)
                    # TL ruling 2026-08-23: cumulative, in cid order, for
                    # a tree_seq= group -- see FC.apply_tree_seq_ref_op's
                    # own docstring. Degrades to plain case.ref_op(dst)
                    # for an exclusive tree.
                    FC.apply_tree_seq_ref_op(CORP.REGISTRY, case, dst)
                    # CONTRACT sec 7.3's 'changed ProDOS file type'
                    # rejection -- FC.merged_types_for_tree (E8,
                    # 2026-08-23) is types_for_tree()'s pre-state dict
                    # PLUS case.expect_types resolved against that same
                    # pre-state snapshot, so a moved/copied/renamed
                    # destination's type is checked too, not just a
                    # survivor at its original relpath. See
                    # types_for_tree()'s own docstring for the gap this
                    # closes.
                    types = FC.merged_types_for_tree(CORP.REGISTRY, case)
                    # THE ENCODING BOUNDARY (B1, docs/E2E.md sec 9.5):
                    # host bytes are LF low-ASCII, the image holds
                    # high-bit $8D, and compare_tree byte-compares.
                    # EVERY poststate call site must pass kinds= or it
                    # reintroduces the false-red this closes.
                    kinds = FC.merged_kinds_for_tree(CORP.REGISTRY, case)
                    want_tree = FC.host_tree(dst, types=types, kinds=kinds)
                tree_muts = FC.tree_mutants(want_tree)

        if case.defect is not None:
            # Whether stdout is right or wrong, feed judge() a CORRECT
            # poststate_ok (True) here -- this sub-test isolates the
            # stdout assertion, same as before this fix. The NEW,
            # required-by-this-fix proof (stdout right, TREE wrong ->
            # still DEFECT, docs/E2E.md sec 9.9) is below, separately.
            poststate_ok_correct = None
            if case.poststate:
                if want_tree is None:
                    problems.append(
                        f'case {case.cid}: defect-pinned poststate=True but '
                        f'no tree= -- cannot prove poststate folding')
                else:
                    poststate_ok_correct, _ = FC.compare_tree(want_tree, want_tree)
                    if not poststate_ok_correct:
                        problems.append(
                            f'case {case.cid}: poststate tree comparator '
                            f'rejected its own correct answer -- cannot '
                            f'prove the defect pin\'s poststate folding '
                            f'against a broken oracle')

            wrong = FC.judge(case, FC.ENC(b'nonsense\n'), want, volume,
                             host_ro, CORP.REGISTRY.comparators,
                             CORP.REGISTRY.defects,
                             poststate_ok=poststate_ok_correct)
            right = FC.judge(case, out, want, volume, host_ro,
                             CORP.REGISTRY.comparators, CORP.REGISTRY.defects,
                             poststate_ok=poststate_ok_correct)
            if not (wrong.ok and wrong.kind == 'DEFECT'):
                problems.append(f'case {case.cid}: pinned to {case.defect!r} '
                               f'but a wrong STDOUT answer was not absorbed '
                               f'as the defect')
            elif right.ok or right.kind != 'DEFECT-FIXED':
                problems.append(f'case {case.cid}: pinned to {case.defect!r} '
                               f'but a fully CORRECT answer (stdout'
                               + (f'+poststate' if case.poststate else '')
                               + f') did not break the pin')
            else:
                accepted += 1
                # This is the EXPIRY check, not a mutant: `out` is the
                # genuinely correct synthesized answer, unmutated -- the
                # proof is that a live pin releases when its defect is
                # actually fixed, the opposite half of `wrong` above.
                pin_probes += 1

            # THE proof this whole fix exists for (docs/E2E.md sec 9.9,
            # reproducing cases 40/41/48/50's own shape): stdout AGREES
            # (the correct synthetic `out` -- for a silent mutating tool
            # this is trivially b'', which is exactly how the old code
            # was fooled) but the TREE does not. Must stay DEFECT, never
            # DEFECT-FIXED, or a live defect's pin silently retires
            # itself the moment a human trusts the (wrong) 'delete this
            # entry' instruction.
            if case.poststate and want_tree is not None:
                if not tree_muts:
                    problems.append(
                        f'case {case.cid}: defect-pinned poststate tree has '
                        f'no leaf file to mutate -- cannot prove poststate '
                        f'folding')
                else:
                    label, mutant = tree_muts[0]
                    tree_wrong_ok, tree_wrong_detail = FC.compare_tree(
                        want_tree, mutant)
                    treewrong = FC.judge(
                        case, out, want, volume, host_ro,
                        CORP.REGISTRY.comparators, CORP.REGISTRY.defects,
                        poststate_ok=tree_wrong_ok,
                        poststate_detail=tree_wrong_detail)
                    if not (treewrong.ok and treewrong.kind == 'DEFECT'):
                        problems.append(
                            f'case {case.cid}: pinned to {case.defect!r} -- '
                            f'stdout AGREES (silent success) but the '
                            f'POSTSTATE tree mutant ({label}) was NOT '
                            f'absorbed as the defect (got ok={treewrong.ok} '
                            f'kind={treewrong.kind!r}) -- this is EXACTLY '
                            f'the docs/E2E.md sec 9.9 bug this fix exists '
                            f'to close: a silent mutating defect misjudged '
                            f'DEFECT-FIXED before its tree was checked')
                    else:
                        # Uses a REAL tree_muts()[0] mutant (unlike
                        # pin_probes above), so this counts as a mutant
                        # check, not an expiry probe.
                        mutant_checks += 1
        else:
            # Non-defect case: judge() does not read poststate_ok for
            # these (only a defect-pinned case's classification needed
            # the fix) -- the generic poststate tree proof below (shared
            # with the defect branch's want_tree/tree_muts) is what
            # exercises this case's own tree comparator.
            v = FC.judge(case, out, want, volume, host_ro,
                        CORP.REGISTRY.comparators, CORP.REGISTRY.defects)
            if v.ok:
                accepted += 1
            else:
                problems.append(
                    f'case {case.cid} ({case.tool}): comparator REJECTED a '
                    f'correct synthetic answer -- {v.detail}')
            for label, mout, merr in FC._mutants(out, err):
                mv = FC.judge(case, mout, want, volume, host_ro,
                             CORP.REGISTRY.comparators, CORP.REGISTRY.defects)
                reason = EXEMPTIONS.get((case.case_id, label))
                if reason is not None:
                    # Declared exemption (task JOB 2) -- honoured
                    # regardless of mv.ok, but NOTE (not FAIL) when it
                    # turns out not to have been needed this run: that
                    # is a comparator improvement, not a problem, and
                    # is worth a visible signal that the entry could be
                    # deleted rather than a silent no-op.
                    if not mv.ok:
                        print(f'[e2e-fs-selftest] note: EXEMPTIONS entry '
                             f'({case.case_id!r}, {label!r}) was not '
                             f'actually needed this run -- the comparator '
                             f'now REJECTS this mutant on its own; '
                             f'consider deleting the entry')
                    exempted.append((case.case_id, case.cid, label, reason))
                    continue
                if mv.ok:
                    problems.append(
                        f'case {case.cid} ({case.tool}): comparator '
                        f'ACCEPTED a mutant ({label}) -- it is measuring '
                        f'nothing')
                else:
                    mutant_checks += 1

        if case.poststate and want_tree is not None:
            ok, detail = FC.compare_tree(want_tree, want_tree)
            if not ok:
                problems.append(f'case {case.cid}: poststate tree '
                               f'comparator rejected its own correct '
                               f'answer: {detail}')
            else:
                accepted += 1
            # TL fix, 2026-08-23: an empty tree_muts here USED to be a
            # silent no-op -- the for loop below just ran zero times,
            # printing nothing, so 8 poststate cases (every successful
            # mkdir plus every fully-empty want_tree) had zero
            # demonstrated tree teeth and nothing said so. FC.tree_mutants
            # no longer returns [] for any tree this corpus produces
            # (see its own docstring), so this branch should now be
            # unreachable -- it stays as a LOUD backstop, not a silent
            # one, in case a future tree shape slips past both of
            # tree_mutants()'s fallbacks.
            if not tree_muts:
                problems.append(
                    f'case {case.cid}: poststate tree yielded ZERO '
                    f'mutants -- this case\'s tree assertion has no '
                    f'demonstrated teeth (docs/E2E.md TL finding, '
                    f'2026-08-23); FC.tree_mutants() should never '
                    f'return [] now, so this means want_tree has a '
                    f'shape neither its file- nor directory-battery '
                    f'handles')
            for label, mutant in tree_muts:
                ok2, _ = FC.compare_tree(want_tree, mutant)
                if ok2:
                    problems.append(
                        f'case {case.cid}: poststate tree comparator '
                        f'ACCEPTED mutant ({label})')
                else:
                    mutant_checks += 1

    return problems, accepted, mutant_checks, pin_probes, exempted


# ===========================================================================
# 3b. THE ENCODING BOUNDARY's own teeth (docs/E2E.md sec 9.5; TL fix,
# 2026-08-23). _case_teeth()'s poststate loop above compares want_tree
# against ITSELF (FC.compare_tree(want_tree, want_tree)) -- a tautology
# that cannot, by construction, exercise a real image-side read, and so
# would NOT have caught the bug this section proves fixed. This function
# builds a REAL scratch volume (a2til alone, no emulator -- same
# "host-only is about the 6502 emulator, never about a2til" rule
# _build_registry_volume() above already relies on), stages a MIXED
# text/raw fixture tree onto it exactly the way e2e_fsmap.stage_tree()
# stages the real corpus, reads it back with e2e_fsmap.read_tree() (the
# genuine 'got' side any poststate=True case actually compares against),
# and proves three things against that REAL image data:
#
#   1. THE BUG, reproduced: host_tree() WITHOUT kinds= (the pre-fix
#      call shape) false-reds a text file that the volume stored
#      correctly, byte-comparing host-native LF/low-ASCII against
#      image-native $8D/high-bit.
#   2. THE FIX: host_tree() WITH kinds=... (merged_kinds_for_tree's
#      shape) accepts the SAME real image read.
#   3. THE FIX DID NOT WEAKEN ANYTHING: every one of CONTRACT sec 7.3's
#      five tree_mutants() kinds (missing/extra/size/type/content) is
#      still rejected against the real image data, PLUS a sixth --
#      clearing bit 7 on one byte of a text file's real image content
#      (as opposed to tree_mutants()'s XOR $FF, which changes more than
#      just bit 7) -- proving the fix's own encode step did not
#      introduce a bit-7-blind comparison path.
# ===========================================================================
def _tree_encoding_teeth():
    problems = []
    accepted = rejected = 0

    FIXTURES = {
        'KEEP': ('text', b'keep me\n'),
        'RAWFILE': ('raw', bytes(((i % 250) + 1) for i in range(60))),
        'SUB': FC.DIR,
        'SUB/INSIDE': ('text', b'inside content\n'),
    }
    plain = {k: v for k, v in FIXTURES.items() if v is not FC.DIR}
    dirs = [k for k, v in FIXTURES.items() if v is FC.DIR]
    types_map, kinds_map = {}, {}
    for relpath, spec in plain.items():
        kind, _data, ftype, _atype, _set_info = FM.unpack_fixture_spec(spec)
        types_map[relpath] = ftype
        kinds_map[relpath] = kind

    tmp = tempfile.mkdtemp(prefix='maux-e2efs-encoding-selftest-')
    try:
        image = os.path.join(tmp, 'enc.po')
        host_root = os.path.join(tmp, 'host')
        prodos.create(image, name='ENC', blocks=280)
        prodos.mount(image)
        image_root = '/mnt/ENC/TREE'
        try:
            FM.stage_tree(image_root, plain, dirs)
            FM.host_stage_tree(host_root, plain, dirs)
            got_tree = FM.read_tree(image_root)

            # -- 1. THE BUG, reproduced against REAL image bytes --
            broken_want = FC.host_tree(host_root, types=types_map)  # no kinds=
            ok_broken, detail_broken = FC.compare_tree(broken_want, got_tree)
            print('[e2e-fs-selftest] encoding-boundary reproduction '
                 '(host_tree() WITHOUT kinds=, the pre-fix call shape):')
            print(f'[e2e-fs-selftest]   {"ACCEPTED (bug NOT reproduced!)" if ok_broken else "REJECTED (bug reproduced): " + detail_broken}')
            if ok_broken:
                problems.append(
                    'encoding-boundary reproduction: host_tree() without '
                    'kinds= ACCEPTED a real image read -- the bug this '
                    'fix addresses did not reproduce, so the fix is '
                    'unproven')

            # -- 2. THE FIX, against the SAME real image bytes --
            want_tree = FC.host_tree(host_root, types=types_map,
                                     kinds=kinds_map)
            ok, detail = FC.compare_tree(want_tree, got_tree)
            print('[e2e-fs-selftest] encoding-boundary fix (host_tree() '
                 'WITH kinds=):')
            print(f'[e2e-fs-selftest]   {"ACCEPTED (fix works)" if ok else "REJECTED (fix broken): " + detail}')
            if not ok:
                problems.append(
                    f'encoding-boundary fix: compare_tree REJECTED a '
                    f'correct real image read after the fix -- {detail}')
            else:
                accepted += 1

            # -- 3a. CONTRACT sec 7.3's five tree_mutants(), against the
            # REAL image tree (mutating `got`, the image side, not
            # `want` -- proving the comparator still catches a wrong
            # VOLUME, which is the actual thing under test) --
            for label, mutant in FC.tree_mutants(got_tree):
                ok2, _ = FC.compare_tree(want_tree, mutant)
                tag = f'  [{label}] '
                if ok2:
                    problems.append(
                        f'encoding-boundary teeth: compare_tree ACCEPTED '
                        f'a real-image mutant ({label}) -- no teeth')
                    print(f'[e2e-fs-selftest]{tag}ACCEPTED (FAIL: no teeth)')
                else:
                    rejected += 1
                    print(f'[e2e-fs-selftest]{tag}REJECTED (correct)')

            # -- 3b. THE SIXTH TOOTH: bit 7 cleared on one byte of a
            # TEXT file's real image content -- must be rejected, not
            # silently accepted (the regression the fix itself could
            # introduce: an encode step that is accidentally
            # bit-7-tolerant on the COMPARE side). Distinct from
            # tree_mutants()'s 'changed content byte' (XOR $FF, which
            # flips every bit, not just bit 7). --
            import copy as _copy
            bit7_mutant = _copy.deepcopy(got_tree)
            content = bytearray(bit7_mutant['KEEP']['content'])
            content[0] &= 0x7F
            bit7_mutant['KEEP']['content'] = bytes(content)
            ok3, detail3 = FC.compare_tree(want_tree, bit7_mutant)
            tag = '  [bit-7-cleared text byte] '
            if ok3:
                problems.append(
                    'encoding-boundary teeth: compare_tree ACCEPTED a '
                    'text mutant with one byte\'s bit 7 cleared -- the '
                    'exact regression this fix could introduce')
                print(f'[e2e-fs-selftest]{tag}ACCEPTED (FAIL: no teeth)')
            else:
                rejected += 1
                print(f'[e2e-fs-selftest]{tag}REJECTED (correct): {detail3}')
        finally:
            prodos.unmount('ENC')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print(f'[e2e-fs-selftest] encoding-boundary teeth: {accepted} correct '
         f'real-image tree accepted, {rejected} mutants rejected '
         f'(5 CONTRACT sec 7.3 kinds + 1 bit-7 regression tooth)')
    return problems


def _nondegeneracy_teeth():
    """Optional per-module hook, `def nondegeneracy(): -> [str]`, that a
    module MAY define to state and self-check its own CONTRACT sec 7.6
    claims (e.g. "this find case's fixture directory order differs from
    sorted order").  Not in CONTRACT sec 5.1's literal module-interface
    list; documented here and in E1's report as the concrete home sec 7.6
    otherwise has none."""
    problems = []
    claims = 0
    for name in CORP.REGISTRY._modules:
        mod = sys.modules.get(name)
        fn = getattr(mod, 'nondegeneracy', None) if mod else None
        if fn is None:
            continue
        result = fn()
        for line in result:
            claims += 1
            print(f'[e2e-fs-selftest] non-degeneracy ({name}): {line}')
    return problems, claims


# ===========================================================================
# 4. status_ruled= teeth -- TL addition, 2026-08-23 (CONTRACT sec 5.3).
#    Two independent claims, proven separately:
#      (a) the exemption weakens NOTHING about output comparison -- a
#          status_ruled case's mutants must still be rejected exactly
#          like any other case's (proven with a throwaway module/case,
#          since no real package uses the field yet);
#      (b) format_report's OWN reporting rules: a status_ruled mismatch
#          is named, never silently dropped; a pinned defect's status
#          is not double-reported; a VOL/INVARIANT case with neither a
#          reference status nor expect_status= is NOT CHECKED, not
#          silently compared against a sentinel; and an ordinary
#          unexplained mismatch still FAILS.
# ===========================================================================
def _status_ruled_teeth():
    problems = []
    mod = types.SimpleNamespace()
    mod.NAME = 'status_ruled_teeth (E1, synthetic)'
    mod.RO_FILES = {}
    mod.RO_DIRS = []
    mod.MUT_TREES = {}
    mod.ENTRIES = {('synth', 'status exemption'):
                   ('RULED', 'synthetic teeth fixture')}
    mod.DEFECTS = {}
    mod.INVARIANTS = {}
    mod.GLOBALS = {}
    mod.COMPARATORS = {}

    def cases(add):
        add('sort', case_id='self.status-ruled',
           argv=['/mnt/MAUX/RO/X'], oracle='REF', compare='exact',
           status_ruled=('synth', 'status exemption'),
           diverges=[('synth', 'status exemption')])
    mod.cases = cases

    def synth(case, ref_out, ref_err, ref_extra, volume, hostdir):
        return FC.ENC(ref_out), b''
    mod.synth = synth

    reg = FC.Registry()
    reg.add_module(mod)
    case = reg.cases[0]
    if case.status_ruled != ('synth', 'status exemption'):
        problems.append('status_ruled was not stored on the Case')

    ref_out = b'a\nb\nc\n'
    out, err = case.synth_fn(case, ref_out, b'', [], FC.Volume(), None)
    v = FC.judge(case, out, ref_out, FC.Volume(), None,
                reg.comparators, reg.defects)
    if not v.ok:
        problems.append(f'status_ruled synthetic case: comparator '
                        f'rejected its own correct answer: {v.detail}')
    for label, mout, merr in FC._mutants(out, err):
        mv = FC.judge(case, mout, ref_out, FC.Volume(), None,
                     reg.comparators, reg.defects)
        if mv.ok:
            problems.append(
                f'status_ruled synthetic case: comparator ACCEPTED '
                f'mutant ({label}) -- status_ruled must not weaken '
                f'output teeth')

    # (b) format_report's own reporting rules.
    good = FC.Verdict(FC.Case(101, 'sort', 'self.report-good',
                              argv=[], oracle='REF'), True)
    ruled_case = FC.Case(102, 'mv', 'self.report-ruled',
                        argv=[], oracle='REF',
                        status_ruled=('mv', 'ARGBUFSZ path cap'))
    ruled_v = FC.Verdict(ruled_case, True)
    vol_case = FC.Case(103, 'ps', 'self.report-vol',
                       argv=[], oracle='INVARIANT',
                       invariant='k')
    vol_v = FC.Verdict(vol_case, True)

    lines, nfail = FC.format_report([good, ruled_v, vol_v], [0, 2, 5],
                                    [0, None, None])
    if nfail:
        problems.append(f'format_report flagged a clean run as failing '
                        f'({nfail}): {lines}')
    want_ruled = f'STATUS RULED case {102:3d}'
    if not any(want_ruled in ln for ln in lines):
        problems.append(f'a status_ruled mismatch was not reported by '
                        f'name (expected a line containing '
                        f'{want_ruled!r}): {lines}')
    want_nc = f'case {103:3d}: exit status NOT CHECKED'
    if not any(want_nc in ln for ln in lines):
        problems.append(f'a VOL/INVARIANT case with no reference status '
                        f'and no expect_status= was not reported NOT '
                        f'CHECKED (expected a line containing '
                        f'{want_nc!r}): {lines}')

    bad_case = FC.Case(104, 'sort', 'self.report-bad',
                       argv=[], oracle='REF')
    bad_v = FC.Verdict(bad_case, True)
    _lines2, nfail2 = FC.format_report([bad_v], [2], [0])
    if not nfail2:
        problems.append('format_report did NOT flag an ordinary '
                        'unexplained exit-status mismatch (no '
                        'status_ruled, no expect_status)')

    expect_case = FC.Case(105, 'ps', 'self.report-expect',
                         argv=[], oracle='INVARIANT',
                         invariant='k', expect_status=0)
    expect_v = FC.Verdict(expect_case, True)
    _lines3, nfail3 = FC.format_report([expect_v], [1], [None])
    if not nfail3:
        problems.append('format_report did NOT flag an expect_status= '
                        'mismatch on a VOL/INVARIANT case with no '
                        'reference status')

    return problems


# ===========================================================================
# 4a. case_id= teeth -- tranche 2, 2026-08-24. Exemption keys are now
# stable only if every real Case has an explicit immutable id and the
# registry rejects duplicates. These synthetic modules prove both guard
# rails fail closed.
# ===========================================================================
def _case_id_teeth():
    problems = []

    def _mod(cases_fn):
        mod = types.SimpleNamespace()
        mod.NAME = 'case_id_teeth (synthetic)'
        mod.RO_FILES = {}
        mod.RO_DIRS = []
        mod.MUT_TREES = {}
        mod.ENTRIES = {}
        mod.DEFECTS = {}
        mod.INVARIANTS = {}
        mod.GLOBALS = {}
        mod.COMPARATORS = {}
        mod.cases = cases_fn
        mod.synth = lambda *a, **k: b''
        return mod

    def missing(add):
        add('sort', argv=['/mnt/MAUX/RO/X'], oracle='REF')
    try:
        FC.Registry().add_module(_mod(missing))
        problems.append('Registry accepted a case with no case_id= -- '
                        'stable exemption keys would be optional')
    except ValueError as e:
        if 'case_id' not in str(e):
            problems.append(f'missing case_id= raised the wrong error: {e}')

    def duplicate(add):
        add('sort', case_id='self.duplicate',
           argv=['/mnt/MAUX/RO/X'], oracle='REF')
        add('sort', case_id='self.duplicate',
           argv=['/mnt/MAUX/RO/Y'], oracle='REF')
    try:
        FC.Registry().add_module(_mod(duplicate))
        problems.append('Registry accepted two cases with the same '
                        'case_id= -- exemption keys could still drift')
    except ValueError as e:
        if 'duplicate case_id' not in str(e):
            problems.append(f'duplicate case_id= raised the wrong error: {e}')

    return problems


# ===========================================================================
# 3b. KNOWN_DEFECTS membership teeth -- BLOCKING fix, 2026-08-23
# (docs/E2E.md sec 9.9's mechanism, the other half from B2). Before this
# fix, e2e_fs_common.Registry.check_citations() validated case.diverges/
# status_ruled against the merged DIVERGENCE table but never looked at
# case.defect at all, and e2e_fs_common.judge() treated ANY non-None
# case.defect as authorising a DEFECT verdict -- reproduced by hand
# before this fix shipped: a case mutated to defect=('bogus', 'a reason
# that does not exist') made judge() absorb a WRONG answer as a green
# PINNED DEFECT, silently, with check_citations() reporting nothing.
#
# A throwaway module+Registry, same shape _status_ruled_teeth uses above
# -- this does not depend on (or risk mutating) any real corpus case,
# and it lets the 'unregistered key' half of the proof use a DEFECTS
# table that genuinely has nothing named 'bogus' in it, rather than
# hoping no real module ever claims that key by accident.
# ===========================================================================
def _defect_registry_teeth():
    problems = []
    mod = types.SimpleNamespace()
    mod.NAME = 'defect_registry_teeth (synthetic)'
    mod.RO_FILES = {}
    mod.RO_DIRS = []
    mod.MUT_TREES = {}
    mod.ENTRIES = {}
    mod.DEFECTS = {('synth', 'a real, registered defect'):
                   'synthetic teeth fixture -- not a real bug'}
    mod.INVARIANTS = {}
    mod.GLOBALS = {}
    mod.COMPARATORS = {}

    def cases(add):
        add('sort', case_id='self.defect-registry',
           argv=['/mnt/MAUX/RO/X'], oracle='REF', compare='exact',
           defect=('synth', 'a real, registered defect'))
    mod.cases = cases

    def synth(case, ref_out, ref_err, ref_extra, volume, hostdir):
        return FC.ENC(ref_out), b''
    mod.synth = synth

    reg = FC.Registry()
    reg.add_module(mod)
    case = reg.cases[0]
    ref_out = b'a\nb\nc\n'

    # -- 1a. Registry.check_citations() flags a case citing a key its
    #        own merged DEFECTS table does not have -- the SAME shape an
    #        unregistered diverges= citation already gets, just a
    #        different table. Mutated onto the one case this throwaway
    #        registry owns; there is nothing else in it to disturb.
    case.defect = ('bogus', 'a reason that does not exist')
    errs, _dead = reg.check_citations()
    if not any('bogus' in e and 'DEFECTS' in e for e in errs):
        problems.append(
            "Registry.check_citations() did not flag a case citing an "
            "unregistered defect key -- the membership check is vacuous "
            f"(errs={errs!r})")

    # -- 1b. judge() itself refuses too, independent of whether
    #        check_citations ran first -- defense in depth, since
    #        judge() is what actually decides a run's verdict.
    try:
        FC.judge(case, FC.ENC(b'nonsense\n'), ref_out, FC.Volume(), None,
                reg.comparators, reg.defects)
    except ValueError as e:
        if 'bogus' not in str(e):
            problems.append(
                f'judge() raised on an unregistered defect key, but the '
                f'message does not name it: {e}')
    else:
        problems.append(
            "FC.judge() did NOT raise on defect=('bogus', ...) -- an "
            "unregistered defect key was silently absorbed as a valid "
            "pin, which is the exact bug this fix closes")

    # -- 2. A REGISTERED key still works exactly as it did before this
    #       fix: a wrong answer is absorbed as DEFECT, and a correct one
    #       breaks the pin as DEFECT-FIXED.
    case.defect = ('synth', 'a real, registered defect')
    out, err = case.synth_fn(case, ref_out, b'', [], FC.Volume(), None)
    wrong = FC.judge(case, FC.ENC(b'nonsense\n'), ref_out, FC.Volume(), None,
                     reg.comparators, reg.defects)
    right = FC.judge(case, out, ref_out, FC.Volume(), None,
                     reg.comparators, reg.defects)
    if not (wrong.ok and wrong.kind == 'DEFECT'):
        problems.append(
            f'registered-key regression: a WRONG answer was not absorbed '
            f'as DEFECT (got ok={wrong.ok} kind={wrong.kind!r})')
    elif right.ok or right.kind != 'DEFECT-FIXED':
        problems.append(
            f'registered-key regression: a CORRECT answer did not break '
            f'the pin (got ok={right.ok} kind={right.kind!r})')
    return problems


# ===========================================================================
# 4b. tree_seq= teeth -- E7/TL ruling, 2026-08-23 (a merge-blocking
# correction to CONTRACT sec 3.5). Proves, with throwaway synthetic
# modules (since the real registry's own M5LOCK/M5DGATE groups are
# already exercised above, but their SUCCESS alone would not show the
# guard rails actually reject what they should):
#   (a) two cases naming the same tree with NEITHER declaring
#       tree_seq=True still raises (the original rule's teeth,
#       preserved);
#   (b) one case declaring tree_seq=True and a second NOT declaring it
#       still raises (silence means exclusive even for the joiner);
#   (c) a tree_seq= group whose cids are not contiguous raises;
#   (d) a genuine tree_seq= group's ref_ops apply CUMULATIVELY, in cid
#       order, to one host copy -- proven by checking the actual file
#       contents after apply_tree_seq_ref_op, not just that it runs.
# ===========================================================================
def _tree_seq_teeth():
    problems = []

    def _mod(cases_fn, mut_trees=None):
        mod = types.SimpleNamespace()
        mod.NAME = 'tree_seq_teeth (E7, synthetic)'
        mod.RO_FILES = {}
        mod.RO_DIRS = []
        mod.MUT_TREES = mut_trees or {'TSQ': {'F': ('text', b'x\n')}}
        mod.ENTRIES = {}
        mod.DEFECTS = {}
        mod.INVARIANTS = {}
        mod.GLOBALS = {}
        mod.COMPARATORS = {}
        mod.cases = cases_fn
        mod.synth = lambda *a, **k: b''
        return mod

    # (a) exclusive-by-default: neither case opts in -> still rejected.
    def cases_a(add):
        add('sort', case_id='self.tree-a-first',
           argv=['/mnt/MAUX/RO/X'], oracle='REF', tree='TSQ')
        add('sort', case_id='self.tree-a-second',
           argv=['/mnt/MAUX/RO/Y'], oracle='REF', tree='TSQ')
    try:
        FC.Registry().add_module(_mod(cases_a))
        problems.append('two cases sharing a tree with NEITHER declaring '
                        'tree_seq=True were accepted -- the original '
                        'exclusive-by-default rule has no teeth')
    except ValueError:
        pass

    # (b) one-sided opt-in: the FIRST case declares tree_seq=True, the
    # second does not -- silence must still mean exclusive for the
    # joiner, not just the first claimant.
    def cases_b(add):
        add('sort', case_id='self.tree-b-first',
           argv=['/mnt/MAUX/RO/X'], oracle='REF', tree='TSQ',
           tree_seq=True)
        add('sort', case_id='self.tree-b-second',
           argv=['/mnt/MAUX/RO/Y'], oracle='REF', tree='TSQ')
    try:
        FC.Registry().add_module(_mod(cases_b))
        problems.append('a tree_seq=True case followed by a tree_seq=False '
                        'case sharing the same tree was ACCEPTED -- '
                        '"silence still means exclusive" has no teeth on '
                        'the joining case')
    except ValueError:
        pass

    # (c) non-contiguous: a THIRD, unrelated tree's case lands between
    # two tree_seq=True claimants of TSQ (module import/case-add order
    # putting them out of cid sequence) -- must raise.
    def cases_c(add):
        add('sort', case_id='self.tree-c-first',
           argv=['/mnt/MAUX/RO/X'], oracle='REF', tree='TSQ',
           tree_seq=True)
        add('sort', case_id='self.tree-c-middle',
           argv=['/mnt/MAUX/RO/Y'], oracle='REF', tree='TSQ2')
        add('sort', case_id='self.tree-c-last',
           argv=['/mnt/MAUX/RO/Z'], oracle='REF', tree='TSQ',
           tree_seq=True)
    try:
        FC.Registry().add_module(_mod(
            cases_c, mut_trees={'TSQ': {'F': ('text', b'x\n')},
                                'TSQ2': {'F': ('text', b'x\n')}}))
        problems.append('a tree_seq= group whose cids are NOT contiguous '
                        '(another tree\'s case lands between them) was '
                        'ACCEPTED -- CONTRACT/TL: "a sequence whose order '
                        'depends on module import order is not a sequence"')
    except ValueError:
        pass

    # (d) cumulative ref_op: two tree_seq=True cases on one tree, each
    # appending a line to the SAME file; apply_tree_seq_ref_op for the
    # SECOND case must reflect BOTH appends, in order -- not just its
    # own.
    def _append(text):
        def op(d):
            with open(os.path.join(d, 'F'), 'a') as fh:
                fh.write(text)
        return op

    def cases_d(add):
        add('sort', case_id='self.tree-d-first',
           argv=['/mnt/MAUX/RO/X'], oracle='REF', tree='TSQ',
           tree_seq=True, ref_op=_append('one\n'))
        add('sort', case_id='self.tree-d-second',
           argv=['/mnt/MAUX/RO/Y'], oracle='REF', tree='TSQ',
           tree_seq=True, ref_op=_append('two\n'))
    reg = FC.Registry()
    reg.add_module(_mod(cases_d))
    c1, c2 = reg.cases
    with tempfile.TemporaryDirectory() as scratch:
        with open(os.path.join(scratch, 'F'), 'w') as fh:
            fh.write('')
        FC.apply_tree_seq_ref_op(reg, c1, scratch)
        got1 = open(os.path.join(scratch, 'F')).read()
        if got1 != 'one\n':
            problems.append(f'apply_tree_seq_ref_op at the FIRST group '
                            f'member: expected \'one\\n\', got {got1!r}')
    with tempfile.TemporaryDirectory() as scratch:
        with open(os.path.join(scratch, 'F'), 'w') as fh:
            fh.write('')
        FC.apply_tree_seq_ref_op(reg, c2, scratch)
        got2 = open(os.path.join(scratch, 'F')).read()
        if got2 != 'one\ntwo\n':
            problems.append(f'apply_tree_seq_ref_op at the SECOND group '
                            f'member did not apply CUMULATIVELY: expected '
                            f"'one\\ntwo\\n', got {got2!r}")

    if not problems:
        groups = reg.tree_groups()
        if groups != [('TSQ', [c1.cid, c2.cid])]:
            problems.append(f'Registry.tree_groups() did not report the '
                            f'synthetic TSQ group: {groups}')

    return problems


def run():
    problems = []

    problems += _fsmap_teeth()
    problems += _tree_teeth()

    # TL ruling 2026-08-23: print which cases share which tree, in
    # order, so the sharing is visible in the gate log rather than
    # implicit (check_e2e_fs.py prints the same thing for a real run;
    # this is the host-only gate this task can actually execute).
    for tree, cids in CORP.REGISTRY.tree_groups():
        print(f'[e2e-fs-selftest] shared tree {tree}: cases {cids} '
             f'(tree_seq=True, cumulative ref_op, contiguous cid order)')

    tmp = tempfile.mkdtemp(prefix='maux-e2efs-hostcorpus-')
    vol_tmp = None
    try:
        host_ro = os.path.join(tmp, 'ro')
        host_mut = os.path.join(tmp, 'mut')
        CORP.write_host_ro(host_ro)
        CORP.write_host_mut(host_mut)
        vol_tmp, volume = _build_registry_volume()
        case_problems, accepted, mutant_checks, pin_probes, exempted = \
            _case_teeth(host_ro, host_mut, volume)
        problems += case_problems
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        if vol_tmp is not None:
            _teardown_registry_volume(vol_tmp)

    problems += _tree_encoding_teeth()

    problems += _status_ruled_teeth()
    problems += _case_id_teeth()
    problems += _defect_registry_teeth()
    problems += _tree_seq_teeth()

    nd_problems, nd_claims = _nondegeneracy_teeth()
    problems += nd_problems

    errs, dead = CORP.REGISTRY.check_citations()
    problems += [f'divergence citation error: {e}' for e in errs]
    problems += [f'dead divergence entry: {d}' for d in dead]

    # The EXEMPTIONS table's own ratchet: a stale case_id is now a true
    # deletion/rename, not a numeric-cid retarget. Catch it the same way
    # check_citations() catches a dead divergence entry.
    live_case_ids = {c.case_id for c in CORP.CASES}
    # -- NO_OUTPUT_PINS gets the same staleness ratchet, for the same
    # -- reason: it is judged in check_e2e_fs.py against a file that is
    # -- not there, so nothing else would ever notice an entry whose
    # -- case has been renamed or deleted.
    import e2e_invariants as _INV
    for case_id in _INV.NO_OUTPUT_PINS:
        if case_id not in live_case_ids:
            problems.append(
                f'NO_OUTPUT_PINS entry {case_id!r} names a case that no '
                f'longer exists -- delete it')
    for case_id, label in EXEMPTIONS:
        if case_id not in live_case_ids:
            problems.append(
                f'EXEMPTIONS entry ({case_id!r}, {label!r}) names a '
                f'case_id that is not in the current corpus -- stale, '
                f'delete it')

    for tool, resolved in sorted(FC.resolved_ref_tools().items()):
        print(f'[e2e-fs-selftest] reference tool: {tool:8} -> {resolved}')
    print(f'[e2e-fs-selftest] modules: {CORP.REGISTRY._modules}')
    # TL fix, 2026-08-23 (PM review): print mutant checks and defect
    # pin-expiry probes as SEPARATE numbers -- a pin_probes case does
    # not mutate anything (docs/E2E.md sec 10.12's own reconciliation
    # note), so folding it into "mutants rejected" is exactly the kind
    # of unreconcilable total sec 10.12 exists to avoid. A reader can
    # now derive the total from what is printed, with no subtraction:
    # mutant_checks + pin_probes IS the number the old single-counter
    # line used to print.
    print(f'[e2e-fs-selftest] {len(CORP.CASES)} cases: {accepted} correct '
         f'answers accepted, {mutant_checks} mutants rejected, '
         f'{pin_probes} defect pin-expiry probes passed '
         f'({mutant_checks} + {pin_probes} = {mutant_checks + pin_probes} '
         f'total checks), '
         f'{len(CORP.REGISTRY.divergence)} divergence entries, '
         f'{nd_claims} non-degeneracy claim(s) stated')

    # A silent skip is forbidden (task JOB 2) -- every exemption this
    # run actually honoured, printed by name with its reason, plus the
    # total count.
    print(f'[e2e-fs-selftest] EXEMPTIONS ({len(exempted)} honoured this run):')
    for case_id, cid, label, reason in exempted:
        print(f'[e2e-fs-selftest]   {case_id} '
             f'(case {cid:3d})  mutant {label!r}')
        print(f'[e2e-fs-selftest]     {reason}')

    for p in problems:
        print(f'[e2e-fs-selftest] FAIL: {p}', file=sys.stderr)
    if problems:
        return 1
    print('[e2e-fs-selftest] PASS: e2e_fsmap\'s four jobs, the tree '
         'comparator, and every registered case\'s comparator all have '
         'teeth')
    return 0


if __name__ == '__main__':
    raise SystemExit(run())
