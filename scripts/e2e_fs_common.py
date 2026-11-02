#!/usr/bin/env python3
"""Case/Tree classes, ratchet mechanics, the module registry, and the teeth
driver -- the spine every one of the six T4 packages plugs its own module
into (CONTRACT sec 5).

REUSE, DO NOT FORK (CONTRACT sec 5): scripts/e2e_limits.py for boundaries,
scripts/e2e_compare.py's decode_maux_text/encode_maux_text for the ONE
place a maux byte is normalised.  This file adds NO second normaliser.

The ratchet mechanism itself is shared with stage 1 via
e2e_divergence.check_citations_table() -- table-driven so this tranche's
own DIVERGENCE/GLOBAL_KEYS merge (built from every module's ENTRIES/
GLOBALS, see Registry below) is checked by the SAME two invariants stage
1's DIVERGENCE is, without the two stages sharing a table.  See
e2e_divergence.py's docstring on check_citations_table for why.
"""
import copy
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e_compare as C       # noqa: E402  decode_maux_text/encode_maux_text
import e2e_divergence as D    # noqa: E402  check_citations_table (shared mechanism)
import e2e_ref as REF         # noqa: E402  explicit /bin + /usr/bin resolver
import e2e_fsmap as FM        # noqa: E402  the mapping
import e2e_limits as L        # noqa: E402  boundaries

SH_LINEMAX = L.limit('sh', 'LINEMAX')          # src/bin/sh.s

#: CONTRACT sec 9: every case's redirect.  Reused, not re-literalled --
#: e2e_corpus.REDIR_SUFFIX is the same string for the same reason (sh.s's
#: SET_OUTFILE/SET_TGTFD/SET_APPEND own one output-file slot per stage, so
#: `CMD > OUT 2> ERR` silently drops the `>`; `2>&1` is a dup, which sh DOES
#: implement as an ordered list).
import e2e_corpus as S1CORP    # noqa: E402
REDIR_SUFFIX = S1CORP.REDIR_SUFFIX

#: CONTRACT sec 5.1: "{relative path: (kind, host_bytes) or DIR}" -- DIR
#: marks a MUT_TREES/RO path as a deliberately empty directory rather than
#: a file to write.  A single shared sentinel object (identity-compared),
#: exported for every producing module to import.
DIR = object()

ORACLES = ('REF', 'VOL', 'REF+VOL', 'INVARIANT')


def ref_tool(name):
    """Resolve a host reference binary by explicit system path."""
    return REF.ref_tool(name)


def resolved_ref_tools():
    """{tool name: resolved absolute path} for every reference binary
    actually invoked so far -- for the gate log's one-line-per-tool
    provenance report (TL, 2026-08-23)."""
    return REF.resolved_ref_tools()


# ===========================================================================
# Compound sh_words support -- B4, 2026-08-23 (T4 review finding, "the
# oracle problem reached from the other side": a compound `sh_words`
# sequence like `CD X ; CAT A` was invisible to the generic reference()
# below, which only ever ran `case.tool` with `case.argv`/`case.ref_argv`
# -- from the HARNESS PROCESS's own cwd, not the cwd the script itself
# establishes.  That produced a reference invoked with the wrong cwd,
# which is not an oracle at all (docs/E2E.md sec 4's rule, reached from
# the reference side rather than the "captured maux output" side the
# rule was written for).
#
# Both helpers work off `sh_words` -- the STRUCTURED word list every
# module already builds the `sh` line from -- never the rendered
# sh_line() string (CONTRACT/task guidance: prefer structure over
# re-parsing text).  A per-case `reference()` override remains available
# (and still used by e2e_fs_idiom.py for the two RULED-divergence `ls`
# cases, which are not a cd/cwd problem at all) for any shape these two
# helpers do not model -- but for the ONE compound shape every module in
# this tranche actually generates (a chain of `CD <target>` segments
# followed by exactly one trailing `<verb> [args...]` segment; verified
# by grep, 2026-08-23: every `';'` in every module's sh_words is exactly
# this), the generic path below now gets it right automatically, so a
# new case does not need to remember to wire a bespoke override -- and a
# compound shape neither helper recognises RAISES instead of silently
# running from the wrong directory.
# ===========================================================================
def _compound_split(sh_words):
    """Split `sh_words` on the literal ';' token into non-empty segments.
    Raises ValueError on an empty segment (a stray leading/trailing/
    doubled ';') -- a malformed compound sequence is a generation-time
    bug, not something reference() should paper over."""
    segments, cur = [], []
    for w in sh_words:
        if w == ';':
            if not cur:
                raise ValueError(
                    f"sh_words {sh_words!r} has an empty ';'-separated "
                    f"segment -- malformed compound sequence")
            segments.append(cur)
            cur = []
        else:
            cur.append(w)
    if not cur:
        raise ValueError(f"sh_words {sh_words!r} ends with a stray ';'")
    segments.append(cur)
    return segments


def _compound_cd_chain_and_tail(sh_words):
    """Returns ([cd_target, ...], [verb, *args]) for a compound sh_words
    sequence -- the CD chain (every segment but the last, each of which
    MUST be a plain two-word 'CD <target>', case-insensitively) and the
    trailing verb segment. RAISES if any leading segment is not exactly
    that shape: a compound form this helper does not model must not
    silently fall through to a reference invoked from the wrong place --
    it must be either widened here (deliberately) or given a per-case
    reference() override, never guessed at."""
    segments = _compound_split(sh_words)
    *leading, tail = segments
    cd_targets = []
    for seg in leading:
        if len(seg) != 2 or seg[0].upper() != 'CD':
            raise ValueError(
                f"sh_words {sh_words!r}: compound segment {seg!r} is not "
                f"a plain 'CD <target>' -- Case.reference()'s compound "
                f"support only models a CD-chain followed by one trailing "
                f"verb; widen _compound_cd_chain_and_tail deliberately or "
                f"give this case its own reference() override rather "
                f"than letting the generic path guess")
        cd_targets.append(seg[1])
    return cd_targets, tail


def _resolve_compound_cwd(cd_targets, host_ro, host_mut):
    """Chains every CD target in `cd_targets` onto a host cwd, in order:
    an IMG_RO/IMG_MUT path (optionally trailing-slashed) resets the cwd
    absolutely via e2e_fsmap.to_host_path (real `cd` semantics -- an
    absolute target does not compose with whatever came before it); a
    literal '..' ascends one directory from whatever the chain has built
    so far (case 105's `cd SUB ; cd ..`, the kernel PRC_DOTDOT shape).
    RAISES on anything else, and on a chain that opens with '..' (no
    base cwd to ascend from) -- a CD target this helper cannot resolve
    on the host must not silently produce a reference run from the
    wrong directory."""
    cwd = None
    for tgt in cd_targets:
        if tgt == '..':
            if cwd is None:
                raise ValueError(
                    f"compound cd chain {cd_targets!r} starts with '..' "
                    f"-- no base host cwd to ascend from")
            cwd = os.path.dirname(cwd.rstrip('/'))
        else:
            try:
                cwd = FM.to_host_path(tgt, host_ro, host_mut)
            except ValueError:
                raise ValueError(
                    f"compound cd target {tgt!r} is neither an IMG_RO/"
                    f"IMG_MUT path nor a literal '..' -- Case.reference() "
                    f"does not know how to resolve it on the host "
                    f"(cd_targets={cd_targets!r})")
    return cwd


# ===========================================================================
# Case
# ===========================================================================
def _check_case_id(case_id, cid, tool):
    if not isinstance(case_id, str) or not case_id:
        raise ValueError(
            f"case {cid} ({tool}): case_id= must be a non-empty string")
    ok = "abcdefghijklmnopqrstuvwxyz0123456789._-"
    bad = [ch for ch in case_id if ch not in ok]
    if bad:
        raise ValueError(
            f"case {cid} ({tool}): case_id={case_id!r} contains "
            f"unsupported character(s) {sorted(set(bad))!r}")


class Case:
    """CONTRACT sec 5.2's shape, verbatim.  `argv`/`sh_words` are plain
    strings in maux spelling (image paths like f'{e2e_fsmap.IMG_RO}/FILE')
    -- unlike stage 1's Case, there is no Ref-wrapper indirection here,
    because RO_FILES/MUT_TREES are owned per-module rather than in one
    shared FIXTURES dict; a module builds its own image paths directly
    from the same relpaths it put in RO_FILES/MUT_TREES."""

    def __init__(self, cid, tool, case_id, argv=(), sh_words=None,
                 oracle='REF', compare='exact', ref_argv=None, tree=None,
                 ref_op=None, poststate=False, cwd=None, diverges=(),
                 defect=None, invariant=None, status_ruled=None,
                 expect_status=None, tree_seq=False, vol_op=None,
                 expect_types=None, note=''):
        _check_case_id(case_id, cid, tool)
        if oracle not in ORACLES:
            raise ValueError(f"case {cid} ({tool}): oracle={oracle!r} must "
                             f"be one of {ORACLES}")
        if oracle == 'INVARIANT' and invariant is None:
            raise ValueError(f"case {cid} ({tool}): oracle='INVARIANT' "
                             f"requires invariant=<an INVARIANTS key>")
        if invariant is not None and oracle != 'INVARIANT':
            raise ValueError(f"case {cid} ({tool}): invariant={invariant!r} "
                             f"is set but oracle={oracle!r}, not 'INVARIANT'")
        if cwd is not None and cwd != 'restore':
            raise ValueError(f"case {cid} ({tool}): cwd={cwd!r} -- only "
                             f"'restore' is defined (CONTRACT sec 5.2/8)")
        if status_ruled is not None and defect is not None:
            raise ValueError(
                f"case {cid} ({tool}): status_ruled={status_ruled!r} and "
                f"defect={defect!r} are mutually exclusive -- CONTRACT sec "
                f"5.3: a status_ruled case is a DELIBERATE design bound "
                f"(the reference has no equivalent), a defect-pinned case "
                f"is a BUG nobody has fixed yet; one case cannot be both.")
        self.cid = cid
        self.case_id = case_id
        self.tool = tool
        self.argv = list(argv)
        self.sh_words = list(sh_words) if sh_words is not None else None
        self.oracle = oracle
        self.compare = compare
        self.ref_argv = ref_argv
        self.tree = tree
        self.ref_op = ref_op
        #: TL ruling, 2026-08-23 (a merge-blocking correction to CONTRACT
        #: sec 3.5): "no other case may name it" is relaxed to an
        #: explicit opt-in. A case sharing tree= with others (E5's
        #: read-modify-write / DESTROY-gate sequences, which must all
        #: act on the SAME staged file to mean anything) must set
        #: tree_seq=True -- silence still means exclusive, and every
        #: case in the group must opt in, not just the first. Enforced
        #: in Registry.add_module: the group must be CONTIGUOUS in cid
        #: order (a sequence whose order depends on module import order
        #: is not a sequence), and ref_op callables for such a group
        #: apply CUMULATIVELY, in cid order, to one host copy of the
        #: tree (see check_e2e_fs.py's poststate_verdict and this
        #: file's tree_group_ref_op()).
        self.tree_seq = tree_seq
        #: E7 integration addition, 2026-08-23: the VOLUME-level analog
        #: of ref_op -- callable(mount_root), applying THIS case's own
        #: correct mutation directly to a LIVE mounted scratch volume
        #: (a2til prodos.set_file_info/destroy/etc), never a host
        #: directory. check_e2e_fs.py never needs this (a real boot
        #: already mutates the real volume for real); it exists purely
        #: so e2e_fs_selftest.py's host-only "synthesise a correct
        #: answer, assert the comparator accepts it" teeth (CONTRACT
        #: sec 7.1) has something for a VOL-oracle comparator that reads
        #: volume.post (e.g. chmod's access byte, rm's DESTROY-gate
        #: presence check) to actually differ from volume.pre on --
        #: without it, .pre and .post are the SAME untouched snapshot
        #: and every such case's "correct answer" is unprovable, not
        #: because the comparator is wrong but because nothing ever
        #: mutated the volume the comparator reads. Applied in cid
        #: order over ONE live mount by
        #: e2e_fs_selftest._build_registry_volume(), so a tree_seq=
        #: group's vol_ops accumulate naturally (same mechanism as
        #: cid-ordered ref_op, just against the volume instead of a
        #: host tree copy).
        self.vol_op = vol_op
        #: E8 addition, 2026-08-23 -- closes the gap types_for_tree()'s
        #: own docstring named: CONTRACT sec 5.2's Case shape had no
        #: field for a case to declare its expected ProDOS type at a
        #: NEW post-mutation path (mv's cross-directory destination,
        #: cp's destination, a file a copy creates). {relpath: type} --
        #: `type` is either an explicit int, or the 2-tuple
        #: ('from', src_relpath) meaning "the type the volume's own
        #: PRE-mutation directory entry at src_relpath had" -- the only
        #: non-guessed answer there is, since the expected type at a
        #: move/copy destination IS, by definition, the type the source
        #: had before the mutation. Resolved lazily against the tree's
        #: own pre-state snapshot by resolve_expect_types()/
        #: merged_types_for_tree() below, not validated here (the
        #: pre-state dict is not available at Case-construction time).
        if expect_types is not None:
            if not isinstance(expect_types, dict):
                raise ValueError(
                    f"case {cid} ({tool}): expect_types={expect_types!r} "
                    f"must be a dict of {{relpath: type}}")
            for relpath, spec in expect_types.items():
                if not isinstance(relpath, str):
                    raise ValueError(
                        f"case {cid} ({tool}): expect_types key {relpath!r} "
                        f"must be a relpath string")
                ok_int = isinstance(spec, int) and not isinstance(spec, bool)
                ok_from = (isinstance(spec, tuple) and len(spec) == 2 and
                          spec[0] == 'from' and isinstance(spec[1], str))
                if not (ok_int or ok_from):
                    raise ValueError(
                        f"case {cid} ({tool}): expect_types[{relpath!r}] = "
                        f"{spec!r} -- must be an int (explicit ProDOS "
                        f"file type) or ('from', src_relpath)")
        self.expect_types = dict(expect_types) if expect_types else {}
        self.poststate = poststate
        self.cwd = cwd
        self.diverges = list(diverges)
        self.defect = defect
        self.invariant = invariant
        #: CONTRACT sec 5.3 (TL addition, 2026-08-23): exempts ONLY the
        #: exit-status equality check, never the output comparator. A
        #: (tool, axis) key that must exist in the merged DIVERGENCE table
        #: at grade RULED or EXCLUDED -- validated in Registry.add_module,
        #: once that module's own ENTRIES are merged in (a case may cite
        #: an entry its OWN module just declared).
        self.status_ruled = status_ruled
        #: TL addition (2026-08-23), CONTRACT sec 5.3: an EXPLICIT
        #: expected exit status for oracle='VOL'/'INVARIANT' cases, which
        #: have no host reference run to compare against. Leaving this
        #: None on a VOL/INVARIANT case means the status is NOT CHECKED --
        #: reported as such by name, never silently skipped (the same
        #: 'say so explicitly rather than pretending' rule docs/E2E.md
        #: sec 7.1 states for INVARIANT oracles generally). A REF/REF+VOL
        #: case may also set this to override its own reference's exit
        #: status in the rare case that is itself the point of a
        #: divergence (uncommon; most REF cases leave it None and are
        #: checked against the reference's real status).
        self.expect_status = expect_status
        self.note = note
        #: set by Registry.add_module -- which module owns this case, and
        #: that module's `synth` function (the teeth driver dispatches
        #: synth per-case, since every module supplies its own).
        self.module = None
        self.synth_fn = None
        #: set by check_e2e_fs.py (never by the selftest, which boots
        #: nothing) after a real boot: the pid SPAWN(SH) returned,
        #: peeked from R_SH_PID (src/test/e2etestb.s:17, aux bank 1,
        #: $1201) -- the ps invariant's second, independent route to the
        #: shell's own pid (TL, 2026-08-23).
        self.spawn_pid = None
        #: B3 addition, 2026-08-23 (the per-case-snapshot finding --
        #: see Volume.post_at's own docstring and terminal_cids()
        #: below): the image path(s), if any, this case's OWN
        #: comparator reads back from `volume.post_at(case)` (a plain
        #: tuple; empty by default). A module whose comparator reads no
        #: post-mutation volume state at all leaves this empty -- most
        #: cases. A module WHOSE comparator DOES (e2e_fs_meta.py's
        #: chmod_access/chmod_rmw/rm_status_only, which read
        #: `case.chmod_path` through `_pre_post()`) should set this to
        #: (that same path,) right where it sets the module-specific
        #: field, so terminal_cids() can tell a case sharing a
        #: tree_seq= GROUP but touching a DIFFERENT file (M5LOCK holds
        #: both M5LOCKF and M5RWF) from one genuinely re-touching the
        #: SAME path later -- PER-PATH granularity, not the coarser
        #: per-TREE rule, because the coarse rule would needlessly
        #: downgrade a case whose own path is never touched again (see
        #: terminal_cids' own docstring for the measured example: cases
        #: 63/64 touch M5LOCKF only and stay fully checkable even
        #: though 65/66/67 mutate the SAME tree's M5RWF afterward).
        #: Left empty (the safe default), a tree_seq= case degrades to
        #: the coarse whole-group rule instead of crashing or silently
        #: trusting a snapshot that may not be its own.
        self.vol_paths = ()

    @property
    def out_name(self):
        return f'O{self.cid:02d}'

    def _words(self):
        return (list(self.sh_words) if self.sh_words is not None
               else [self.tool.upper()] + self.argv)

    def operand_words(self):
        """The words that are OPERANDS/paths, for CONTRACT sec 3.2's
        no-operand-under-OUT-or-E2E check and for path-translation in
        reference().  sh_words cases are typed literally and are exempt
        from this scan's TRANSLATION (idiom cases like `cd D` or
        `find .` do not name RO/MUT paths at all), but are NOT exempt
        from the forbidden-prefix check."""
        return self._words()

    def sh_line(self):
        words = self._words() + ['>', f'{FM.IMG_OUT}/{self.out_name}',
                                 REDIR_SUFFIX]
        line = ' '.join(words)
        if len(line) > SH_LINEMAX:
            raise ValueError(
                f'case {self.cid} ({self.tool}): sh line is {len(line)} '
                f"bytes, over src/bin/sh.s's LINEMAX of {SH_LINEMAX}: {line}")
        return line

    def reference(self, host_ro, host_mut):
        """Run the host reference for REF/REF+VOL cases (translating any
        IMG_RO/IMG_MUT path to its host twin via e2e_fsmap.to_host_path,
        then rewriting the OUTPUT's host paths back to image paths so the
        printed text matches what maux would have printed -- the same
        'pathname' DISCHARGED entry stage 1 uses).  VOL/INVARIANT cases
        have no host tool to run; returns (b'', b'', None, []) for those,
        and their module's synth() must be self-sufficient from
        volume+hostdir alone.

        B4, 2026-08-23: a COMPOUND sh_words sequence (`CD X ; <verb>
        <args>`, `_compound_split`'s own docstring) is run in the cwd
        the sequence itself establishes, not the harness process's own
        cwd -- see this file's compound-support block above for why
        that distinction is the whole point of this fix. `argv`/
        `ref_argv` play no part for a compound case: the trailing
        verb+args come from `sh_words` itself, exactly like the CD chain
        does, never from `argv` (which for a compound case is
        frequently just the CD target, not the trailing verb's
        operands -- e.g. this module's own 'cd' cases, where case.tool
        IS 'cd')."""
        if self.oracle not in ('REF', 'REF+VOL'):
            return b'', b'', None, []

        def unpath(data):
            for hostdir, imgdir in ((host_ro, FM.IMG_RO), (host_mut, FM.IMG_MUT)):
                prefix = hostdir.rstrip('/') + '/'
                data = data.replace(prefix.encode(), (imgdir + '/').encode())
            return data

        env = dict(os.environ)
        env['LC_ALL'] = 'C'
        env['LANG'] = 'C'

        if self.sh_words is not None and ';' in self.sh_words:
            cd_targets, tail = _compound_cd_chain_and_tail(self.sh_words)
            cwd = _resolve_compound_cwd(cd_targets, host_ro, host_mut)
            tool_word, arg_words = tail[0], tail[1:]
            toolname = tool_word.rsplit('/', 1)[-1].lower()
            argv = [ref_tool(toolname)]
            for tok in arg_words:
                if isinstance(tok, str):
                    try:
                        tok = FM.to_host_path(tok, host_ro, host_mut)
                    except ValueError:
                        pass      # not an IMG_RO/IMG_MUT path -- a flag/literal
                argv.append(tok)
            proc = subprocess.run([os.path.basename(argv[0])] + argv[1:], executable=argv[0],
                                  cwd=cwd, env=env,
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE)
            return (unpath(proc.stdout), unpath(proc.stderr),
                   proc.returncode, [])

        spec = self.ref_argv if self.ref_argv is not None else self.argv
        argv = [ref_tool(self.tool)]
        for tok in spec:
            if isinstance(tok, str):
                try:
                    tok = FM.to_host_path(tok, host_ro, host_mut)
                except ValueError:
                    pass          # not an IMG_RO/IMG_MUT path -- a flag/literal
            argv.append(tok)
        # argv[0] = bare tool name, path in `executable` (both call sites):
        # GNU tools echo argv[0] verbatim in diagnostics; BSD tools and
        # maux print the bare name. See e2e_corpus.Case.reference.
        proc = subprocess.run([os.path.basename(argv[0])] + argv[1:], executable=argv[0], env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return unpath(proc.stdout), unpath(proc.stderr), proc.returncode, []


# ===========================================================================
# Verdict + judge -- reuses e2e_compare's decode_maux_text, the ONE place a
# maux byte is normalised (CONTRACT sec 6: "Do not add a second
# normaliser anywhere").
# ===========================================================================
class Verdict:
    def __init__(self, case, ok, detail='', kind='PASS'):
        self.case = case
        self.ok = ok
        self.detail = detail
        self.kind = kind

    def __repr__(self):
        return f'<Verdict {self.case.cid} {"ok" if self.ok else "FAIL"}>'


def status_verdict(case, got_status, ref_status):
    """The ONE place 'does this case's exit status agree with its
    oracle' is decided -- shared between judge()'s defect-pin
    classification and format_report's own status column, so there is
    exactly one comparison rule rather than two that can quietly drift
    apart (the same failure shape this whole fix is about, one level
    down). Returns (checked, ok): checked=False means there is nothing
    to compare against (no expect_status= and no reference exit status
    -- the NOT CHECKED case, docs/E2E.md sec 7.1's 'say so explicitly
    rather than pretending'); checked=True carries the real comparison
    in `ok`. Deliberately does not know about status_ruled= -- whether a
    checked-but-mismatched status is reported as a plain FAIL or as
    'STATUS RULED' is a DISPLAY decision, made once by format_report,
    not a second comparison rule."""
    want = case.expect_status if case.expect_status is not None else ref_status
    if want is None:
        return False, None
    return True, got_status == want


def judge(case, raw_out, ref_out, volume, hostdir, comparators, defects,
          status_ok=None, poststate_ok=None, poststate_detail=''):
    """One case's stdout+stderr verdict.  `comparators` is the merged
    Registry.comparators dict; `defects` is the merged Registry.defects
    dict (both threaded through the same way, table-driven, for the same
    reason: this function knows no corpus-specific table by name).
    `volume` is always a `Volume` instance
    (never a bare path) -- its `.pre`/`.post` VolumeSnapshots for
    before/after metadata assertions (TL, 2026-08-23: chmod's
    read-modify-write proof needs BOTH), and `.root` for a live mounted
    path when one exists (check_e2e_fs.py after a real boot; None in
    e2e_fs_selftest.py, which boots nothing).

    RESTRUCTURING, 2026-08-23 (docs/E2E.md sec 9.9's blocking fix): a
    defect-pinned case's verdict used to be decided from stdout+stderr
    ALONE, before post-state ever ran -- check_e2e_fs.py's old `if
    case.poststate and v.ok:` gate only invoked poststate_verdict when
    THIS function had already returned ok=True/False from the
    comparator. For a mutating tool that is silent on success (rm/mv/
    cp/mkdir), stdout+stderr agree TRIVIALLY whether or not the tree
    mutation was actually correct, so a case pinned to a REAL, still-
    live defect (mv's cross-directory BIN rewrite, cases 40/41/48/50)
    was classified DEFECT-FIXED -- 'delete the entry' -- on every run,
    without the one property that would show the defect is still
    present (the post-state tree) ever being examined. That inverts the
    KNOWN_DEFECTS mechanism: the rule is a defect entry that starts
    AGREEING with the reference should fail and say so; what happened
    instead is a case whose oracle (stdout) never had anything to
    disagree with in the first place quietly recommending its own pin
    be deleted, which is the same 'bug acquires a reason and stops
    being a bug' failure by a different route -- an operator who
    followed that instruction would delete a live defect's pin and the
    real bug would then pass silently forever after.

    Fixed by requiring the CALLER to run poststate/status comparison
    FIRST -- unconditionally, never gated on whether stdout already
    agrees -- and hand the results in. A defect-pinned case's
    classification now considers EVERY assertion the case makes:
    stdout+stderr (`comparators[case.compare]`), post-state
    (`poststate_ok`, required whenever the case is BOTH defect-pinned
    and `poststate=True`), and exit status (`status_ok`, when
    assertable at all) TOGETHER.
    DEFECT-FIXED only when ALL of them agree with the reference; any
    ONE of them disagreeing is absorbed as the pinned defect, exactly
    like a stdout mismatch always was.

    `status_ok`: None means 'not assertable' (status_verdict's
    checked=False) -- an unchecked property cannot prove agreement any
    more than it can prove disagreement, so it does not participate in
    the AND either way. True/False when the caller DID check it
    (status_verdict).

    `poststate_ok`/`poststate_detail`: used ONLY when `case.defect is not
    None and case.poststate` -- that is the ONLY combination whose
    classification depends on it (see above). For that combination the
    caller MUST already have run the post-state tree comparison and
    pass the result here: this function RAISES rather than silently
    defaulting to 'agrees', which is exactly the shape of the bug being
    fixed. For every other case (non-defect, or defect without
    poststate) the parameter is simply ignored if passed -- a caller
    iterating every case uniformly (check_e2e_fs.py's main loop) need
    not special-case which cases care.

    `status_ok` is likewise read only when `case.defect is not None`;
    non-defect cases keep checking status separately, as before.

    MEMBERSHIP, not mere non-None-ness (fix, 2026-08-23, the other half
    of the fix above this docstring describes -- see e2e_divergence.
    check_citations's own docstring for the full reproduction): a
    `case.defect` used to authorise a DEFECT verdict just by being set,
    with no check that the key names anything in `defects` at all. This
    RAISES immediately, before any comparator runs, rather than folding
    the problem into the verdict -- an unregistered defect key is a bug
    in how the case was built, not a differential result, and must stop
    the run loudly rather than surface as a report line a reader might
    skim past (the same judgement stage 1's e2e_compare.judge() makes,
    argued there)."""
    if case.defect is not None and case.defect not in defects:
        raise ValueError(
            f'case {case.cid} ({case.tool}): defect={case.defect!r} is '
            f'not a key of the merged DEFECTS table (Registry.defects) '
            f'-- a wrong answer must never be absorbed as a pinned '
            f'defect that names nothing; register the entry (or fix the '
            f'citation), do not invent a reason at the call site')
    if case.poststate and case.defect is not None and poststate_ok is None:
        raise ValueError(
            f'case {case.cid} ({case.tool}): a defect-pinned poststate=True '
            f'case requires the caller to run the post-state tree '
            f'comparison FIRST and pass poststate_ok= -- judge() no longer '
            f'computes it conditionally on stdout agreeing (docs/E2E.md '
            f'sec 9.9: that ordering is exactly what let a silent mutating '
            f'defect be misclassified DEFECT-FIXED before its tree was '
            f'ever checked)')
    got, problems = C.decode_maux_text(raw_out)
    if problems:
        head = ', '.join(f'offset {o} = ${b:02X}' for o, b in problems[:6])
        return Verdict(case, False,
                       f'{len(problems)} byte(s) in maux output have bit 7 '
                       f'CLEAR -- maux text is high-bit ($8D line endings), '
                       f'so this is not text this system wrote correctly: '
                       f'{head}', kind='ENCODING')
    fn = comparators[case.compare]
    ok, detail = fn(case, got, ref_out, volume, hostdir)

    if case.defect is None:
        return Verdict(case, ok, detail)

    # Defect-pinned: fold in every OTHER assertion this case makes
    # before deciding DEFECT vs DEFECT-FIXED -- see this function's own
    # docstring for why (docs/E2E.md sec 9.9).
    overall_ok = ok
    detail_parts = [] if ok else [detail]
    if case.poststate and not poststate_ok:
        overall_ok = False
        detail_parts.append(f'POSTSTATE: {poststate_detail}')
    if status_ok is False:
        overall_ok = False
        detail_parts.append('EXIT STATUS: does not match the reference')
    combined_detail = '\n'.join(detail_parts)

    if not overall_ok:
        return Verdict(case, True, combined_detail, kind='DEFECT')
    return Verdict(case, False,
                   f'this case is pinned to KNOWN_DEFECTS entry '
                   f'{case.defect!r} but now AGREES with the reference on '
                   f'stdout/stderr, exit status and post-state (every '
                   f'assertion this case makes) -- the defect is fixed; '
                   f'delete the entry and the defect= citation',
                   kind='DEFECT-FIXED')


def format_report(verdicts, statuses, ref_statuses):
    """Per-case failures in full, then the exit-status column -- this
    tranche's OWN version of e2e_compare.format_report, not a reuse of
    it: stage 1's Case has no status_ruled/expect_status, so its status
    loop cannot express either.  Three outcomes per case, mutually
    exclusive:

      * PINNED DEFECT (case.defect, verdict.kind == 'DEFECT') -- status
        is not checked at all; a defect-pinned case's status is part of
        the bug and reported alongside the pin, not as a separate FAIL.
      * STATUS RULED (case.status_ruled) -- the exit status legitimately
        differs from the reference (or has no reference) for a named,
        argued reason; reported BY NAME every run, never silently
        (CONTRACT sec 5.3 -- 'silent exemptions are how a ratchet rots').
        The case's OUTPUT is still checked in full via `verdicts`, so a
        status_ruled case whose output diverges still fails through the
        normal `failed` path above.
      * Ordinary status check: `case.expect_status` if set, else the
        reference's own exit status. A VOL/INVARIANT case with NEITHER
        set has no exit code to compare against and is reported as
        NOT CHECKED, explicitly -- never silently compared against a
        sentinel that would make it fail (or pass) for no stated reason.
    """
    lines = []
    failed = [v for v in verdicts if not v.ok]
    pinned = [v for v in verdicts if v.kind == 'DEFECT']
    for v in failed:
        c = v.case
        lines.append(f'FAIL case {c.cid:3d}  {c.sh_line()}')
        if c.note:
            lines.append(f'    note: {c.note}')
        if c.diverges:
            lines.append(f'    cites: {c.diverges}')
        for line in str(v.detail).splitlines():
            lines.append(f'    {line}')
        lines.append('')
    pinned_cids = {v.case.cid for v in pinned}

    bad_status, ruled_status, not_checked = [], [], []
    for c, got, want in zip([v.case for v in verdicts], statuses, ref_statuses):
        if c.cid in pinned_cids:
            continue
        # status_verdict is the SAME comparison judge() uses to fold a
        # defect-pinned case's exit status into its DEFECT/DEFECT-FIXED
        # classification (docs/E2E.md sec 9.9) -- one rule, not two that
        # can quietly drift apart. `effective_want` is only for the
        # messages below; status_ruled/NOT-CHECKED DISPLAY choices stay
        # here, they are not part of the comparison itself.
        checked, ok = status_verdict(c, got, want)
        effective_want = c.expect_status if c.expect_status is not None else want
        if not checked:
            if c.status_ruled is not None:
                # A status_ruled case with no reference AND no explicit
                # expect_status: the exemption still applies (there is
                # nothing to compare against, which is itself unchecked-
                # by-design), reported the same way as a real mismatch so
                # it stays visible.
                ruled_status.append(
                    f'STATUS RULED case {c.cid:3d} {c.status_ruled} -- '
                    f'maux exits {got}, no reference status to compare '
                    f'({c.sh_line()})')
            else:
                not_checked.append(
                    f'case {c.cid:3d}: exit status NOT CHECKED (oracle='
                    f'{c.oracle}, no reference status and no '
                    f'expect_status=)   ({c.sh_line()})')
            continue
        if ok:
            continue
        if c.status_ruled is not None:
            ruled_status.append(
                f'STATUS RULED case {c.cid:3d} {c.status_ruled} -- maux '
                f'exits {got}, reference {effective_want}   ({c.sh_line()})')
            continue
        bad_status.append(
            f'FAIL case {c.cid:3d}  exit status {got}, reference '
            f'{effective_want}   ({c.sh_line()})')
    lines.extend(bad_status)
    for v in pinned:
        c = v.case
        lines.append(f'PINNED DEFECT case {c.cid:3d}  {c.sh_line()}')
        # A NO_OUTPUT_PINS case carries no `defect=` (its symptom is the
        # MISSING FILE, judged in check_e2e_fs.py rather than judge() --
        # see that table's own header for why it is not a defect pin).
        # Its reason travels in the verdict detail below instead.
        if c.defect is not None:
            lines.append(f'    {c.defect[0]}: {c.defect[1]}')
        for line in str(v.detail).splitlines()[:4]:
            lines.append(f'    {line}')
    lines.extend(ruled_status)
    lines.extend(f'NOTE {line}' for line in not_checked)
    # TL addition, 2026-08-23 (non-blocking review finding, docs/E2E.md
    # sec 7.1's own rule applied to the aggregate, not just each case):
    # every NOT-CHECKED case is already named above by cid with its own
    # reason ('no reference status and no expect_status='), same as the
    # exemption/divergence tables name their entries -- what was missing
    # is the COUNT, printed once so a reader does not have to count NOTE
    # lines to know how many of this run's cases have no status oracle
    # at all. Printed even when 0, so its absence is visible too.
    lines.append(f'NOTE exit status NOT CHECKED for {len(not_checked)} '
                 f'case(s) total (no expect_status=, no reference exit '
                 f'status -- listed by cid above; an expected status is '
                 f'never invented by running maux)')
    return lines, len(failed) + len(bad_status)


# ===========================================================================
# Volume snapshots -- TL addition, 2026-08-23.  A comparator asserting
# "every OTHER GET_FILE_INFO field survived a chmod/mv/cp untouched"
# (learning:01M0HK4EYPWC2H7M9DYHR9QF2A's null_field corruption is exactly
# this shape: invisible until something DECODES the date) needs BOTH a
# before and an after picture -- a post-run read alone cannot prove
# anything did not silently change. `e2e_fsmap.snapshot_volume()` does
# the actual walking/reading (job of "the mapping"); these two classes
# are the comparator-facing shape and its JSON persistence, which is why
# they live here with Case/Registry rather than in e2e_fsmap.py.
# ===========================================================================
class VolumeSnapshot:
    """A flat {path: fields} capture of an entire ProDOS volume (or
    subtree), fields = e2e_fsmap.snapshot_volume()'s per-entry dict
    (is_dir, type, aux_type, eof, blocks_used, access, storage_type,
    creation_raw, last_mod_raw -- RAW date bytes, never decoded, job (c)'s
    own rule). `.entry(path)` / `.exists(path)` are the only access a
    comparator needs; nothing here re-derives anything from a live mount."""

    def __init__(self, entries):
        import vpath  # docs/VROOT.md: keys are a2til (physical) paths
        self._v = vpath
        self._entries = {vpath.phys(k): v for k, v in dict(entries).items()}

    def entry(self, path):
        return self._entries.get(self._v.phys(path))

    def exists(self, path):
        return self._v.phys(path) in self._entries

    def paths(self):
        return list(self._entries)

    def to_json(self):
        return json.dumps(self._entries, sort_keys=True)

    @classmethod
    def from_json(cls, text):
        return cls(json.loads(text))

    @classmethod
    def load(cls, path):
        with open(path, 'r') as fh:
            return cls.from_json(fh.read())

    def save(self, path):
        with open(path, 'w') as fh:
            fh.write(self.to_json())


class Volume:
    """What comparators receive as the `volume` parameter to judge().

    `.pre`  -- VolumeSnapshot taken at build time, after staging and
               BEFORE the boot (build_e2efs_image.py, persisted as JSON
               alongside the image so check_e2e_fs.py loads it rather
               than re-deriving it).
    `.post` -- VolumeSnapshot taken after the guest run, before unmount.
               None in e2e_fs_selftest.py, which never boots anything.
    `.root` -- a LIVE mounted absolute path (e.g. '/mnt/MAUX'), for a
               real-time read (e2e_fsmap.read_tree, check_blocks_used)
               rather than a snapshot comparison. None when nothing is
               mounted (e2e_fs_selftest.py by default).

    A comparator that needs `.pre`/`.post` and finds either None MUST
    degrade with a clear message rather than silently pass (CONTRACT's
    own oracle-integrity rule, applied to this field) -- check_e2e_fs.py
    always supplies `.pre` (loaded from the persisted snapshot) and
    `.post` (taken fresh), so that degrade path should not fire there in
    practice; it exists for e2e_fs_selftest.py and any future host-only
    caller that has no real volume to snapshot.
    """

    def __init__(self, pre=None, post=None, root=None, image_path=None,
                 post_by_cid=None, group_terminal_cids=None):
        self.pre = pre
        self.post = post
        self.root = root
        #: B3 addition, 2026-08-23 -- see post_at()'s own docstring and
        #: terminal_cids() below. {cid, ...} -- cids for which the
        #: single whole-corpus `.post` snapshot IS sound (either no
        #: tree_seq= sharing at all, or this is the last case to touch
        #: its own watched path(s) among the cases that actually run).
        #: None (the default) means "unknown -- trust `.post`
        #: unconditionally", which is check_e2e_fs.py's OLD behaviour
        #: and remains e2e_fs_selftest.py's behaviour too (it always
        #: supplies post_by_cid instead, which post_at() consults
        #: FIRST and which this field never overrides).
        self.group_terminal_cids = group_terminal_cids
        #: E7 integration addition, 2026-08-23 -- see post_at()'s own
        #: docstring for why this exists: {cid: VolumeSnapshot}, an
        #: INCREMENTAL snapshot taken right after each vol_op-bearing
        #: case's own mutation, for the host-only selftest ONLY. None
        #: in check_e2e_fs.py's real run, which has exactly one
        #: whole-corpus .pre and one whole-corpus .post -- there is no
        #: mechanism (short of re-mounting after every shell line,
        #: which this integration pass does not build) to snapshot the
        #: volume between two cases in a real boot.
        self.post_by_cid = post_by_cid
        #: E7 integration addition, 2026-08-23: the .po image file's own
        #: path, when known (check_e2e_fs.py's real run; the scratch
        #: volume e2e_fs_selftest.py builds). e2e_invariants.py's df
        #: comparator (CONTRACT EXTENSION 2) reads os.path.getsize(this)
        #: as its independent ground truth for total_blocks -- a fact
        #: neither maux nor a2til computed, only reported, per that
        #: module's own INVARIANTS['df-total-matches-image-size'] entry.
        #: Named `.path` (not just `.image_path`) because that assumed
        #: interface's own _image_size() tries `.path` FIRST.
        self.image_path = image_path
        self.path = image_path

    # -- E2's assumed volume.readdir()/.gfi(), E3's assumed
    # volume.scandir()/.blocks_used() -- all LIVE reads requiring a
    # mounted volume (.root set). See e2e_fsmap's own docstring on why
    # these are the union of what was actually asked for, not a
    # redesign of either package. --------------------------------------
    def _require_root(self, who):
        if self.root is None:
            raise RuntimeError(
                f'{who} needs a live mounted volume (.root) -- none is '
                f'available in this context (e2e_fs_selftest.py must '
                f'build+mount a scratch volume from the registry\'s own '
                f'RO/MUT fixtures for VOL-oracle cases to have real '
                f'GET_FILE_INFO data; check_e2e_fs.py always has one '
                f'after a real boot)')

    def readdir(self, image_dir):
        self._require_root('volume.readdir()')
        return FM.readdir_entries(image_dir)

    def gfi(self, image_path):
        self._require_root('volume.gfi()')
        return FM.gfi_entry(image_path)

    def scandir(self, image_path):
        self._require_root('volume.scandir()')
        return FM.live_scandir(image_path)

    def blocks_used(self, image_path):
        self._require_root('volume.blocks_used()')
        return FM.live_blocks_used(image_path)

    @property
    def total_blocks(self):
        """E5's e2e_invariants.py CONTRACT EXTENSION (2): a fallback for
        cmp_df_line when .path/.image_path's byte-size read is
        unavailable -- opens a SECOND, read-only handle on the same
        image file via a2til's own public Volume(path, readonly=True)
        API (the same one check_e2e_fs.py's own final free-blocks
        report already uses), never private session internals."""
        if self.image_path is None:
            raise RuntimeError(
                'volume.total_blocks needs image_path= (no way to open '
                'a read-only handle on the image without its path)')
        sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
        from a2til import prodos as _prodos
        import vpath  # noqa: F401  (docs/VROOT.md)
        vol = _prodos.Volume(self.image_path, readonly=True)
        try:
            return vol.total_blocks
        finally:
            vol.close()

    # -- single-snapshot convenience, for E5/E6 call sites that assumed
    # one `volume.entry()`/`.exists()` rather than the pre/post split
    # (TL note, 2026-08-23: "make the single-snapshot users work
    # without pretending a pre-run read happened when it did not").
    # Reads the freshest snapshot available (.post if taken, else
    # .pre) -- sound for every call site that actually uses it, because
    # every one of them reads an RO fixture (immutable, so pre and post
    # necessarily agree) or a MUT path AFTER its own mutation (where
    # .post -- the only thing that could differ -- is exactly what is
    # wanted). Neither caller ever needs a PRE-mutation read through
    # this path -- E5's read-modify-write proof, the one case that
    # genuinely needs both sides, goes through .pre/.post directly
    # (cmp_chmod_rmw), never through this convenience method. --------
    def entry(self, path):
        snap = self.post if self.post is not None else self.pre
        if snap is None:
            raise RuntimeError(
                'volume.entry() needs a snapshot (.pre or .post) -- '
                'neither is available in this context')
        return snap.entry(path)

    def exists(self, path):
        snap = self.post if self.post is not None else self.pre
        if snap is None:
            raise RuntimeError(
                'volume.exists() needs a snapshot (.pre or .post) -- '
                'neither is available in this context')
        return snap.exists(path)

    def post_at(self, case):
        """FINDING, 2026-08-23 (see this integration pass's report): a
        VOL-oracle comparator whose 'correct' answer depends on a
        MID-SEQUENCE mutation state (e.g. e2e_fs_meta.py's chmod_access
        checking M5RWF immediately after its OWN '-dnw' step, when a
        LATER case in the same tree_seq= group unlocks it again with
        '+dnw') cannot be verified against the single whole-corpus
        `.post` snapshot check_e2e_fs.py actually produces -- .post is
        captured ONCE, after the ENTIRE guest run finishes, so it can
        only ever agree with the group's FINAL state, not an
        intermediate step's. This method returns the best snapshot
        available for `case`: the host-only selftest's own
        INCREMENTAL per-case snapshot (post_by_cid) when one exists (at
        or before this case's cid), else the single whole-corpus
        `.post` (real run), else `.pre` (nothing has mutated yet).
        Comparators SHOULD call this instead of `.post` directly when
        their correctness depends on step-ordering within a tree_seq=
        group; e2e_fs_meta.py's _pre_post() has been updated to do so.

        B3 FIX, 2026-08-23 (this task): the docstring above used to end
        there, with "else the single whole-corpus `.post` (real run)"
        as the fallback for every case with no post_by_cid -- which is
        exactly the bug this task fixes. Reproduced host-side (see the
        task report): judged against a single final snapshot, case 65
        (M5LOCK's mid-round-trip chmod_access on M5RWF) FAILS on a
        correct maux (the final snapshot shows the file's access byte
        AFTER the round trip's second step, not case 65's own first
        step), and cases 68/70 (M5DGATE's chmod_access steps) throw
        TypeError on `post_entry['access']` once the group's own later
        `rm` member has deleted the file by the time `.post` is taken
        (post.entry() returns None for a gone file).

        The real run (check_e2e_fs.py) has no post_by_cid -- there is
        no way to snapshot the volume between two lines of a script the
        guest runs in one boot without re-architecting the harness
        (this task's own brief rules that out). What check_e2e_fs.py
        CAN determine, host-side, before the boot: which cid is the
        LAST one -- among the cids that actually run this time,
        HANG_QUARANTINE included -- to touch a given case's own watched
        path(s) (case.vol_paths) within its tree_seq= group. For that
        cid, and only that cid, `.post` is PROVABLY sound: nothing else
        in the run touches that path afterward, so the final snapshot
        genuinely IS that case's own post-mutation state, no matter how
        many other cases (on OTHER files, or later in the SAME script)
        run first or after. `group_terminal_cids`, precomputed by
        `terminal_cids()` below and handed to Volume() at construction,
        is exactly that set.

        For a case NOT in that set (a genuinely mid-sequence step whose
        own path is mutated again by a later case before the volume is
        ever read back) there is NO sound snapshot a real run can offer
        -- returning `.post` anyway is exactly the false-FAIL/crash
        this task exists to fix, and returning `.pre` would be just as
        wrong in the other direction (silently pretending nothing
        happened). This method returns None instead, and it is the
        caller's job to STOP trying to read post-mutation state and
        fall back to whatever IS genuinely real for that step (exit
        status, stdout shape) -- never to guess. See
        e2e_fs_meta.py's _pre_post()/cmp_chmod_access/cmp_chmod_rmw/
        cmp_rm_status_only for the consumer side of this contract, and
        check_e2e_fs.py's own printed REDUCED ASSERTION table for the
        loud, by-name accounting CONTRACT-equivalent to the divergence
        ratchet's citation discipline."""
        if self.post_by_cid:
            candidates = [cid for cid in self.post_by_cid if cid <= case.cid]
            if candidates:
                return self.post_by_cid[max(candidates)]
            return self.pre
        if self.group_terminal_cids is not None and \
                case.cid not in self.group_terminal_cids:
            return None
        return self.post if self.post is not None else self.pre


# ===========================================================================
# terminal_cids -- B3, 2026-08-23.  Precomputes Volume.group_terminal_cids
# for a real run: which cids are safe to judge against the single
# whole-corpus `.post` snapshot check_e2e_fs.py takes after the guest
# finishes.  See post_at()'s own docstring for why this exists at all.
# ===========================================================================
def terminal_cids(registry, runnable_cids=None):
    """{cid, ...} -- every case for which `.post` is a SOUND read of
    that case's own post-mutation state, given which cids actually run
    this time (`runnable_cids`; None means "assume every registered
    case runs" -- the whole registry, HANG_QUARANTINE included, which
    is what a fully-healed run would look like).

    A case with no tree=, or an EXCLUSIVE tree (its own tree_case group
    has at most one member among runnable_cids), is trivially terminal
    -- by far the common case; this function only has real work to do
    for a tree_seq= group.

    PER-PATH, not per-tree, is deliberate and MEASURED, not a
    convenience shortcut. e2e_fs_meta.py's M5LOCK tree holds two
    DIFFERENT files, M5LOCKF (cases 63-64) and M5RWF (cases 65-67).
    Reproduced host-side (see the task report): cases 63/64 (chmod on
    M5LOCKF) pass a real gate's own final-snapshot read TODAY, correctly,
    because nothing after them ever touches M5LOCKF again -- M5RWF's own
    later mutations are a different file in the SAME tree. A per-TREE
    rule ("terminal iff last cid in the whole group") would downgrade
    63/64 anyway, for no reason: an unforced weakening of two currently-
    sound assertions, which the task's own non-negotiable forbids doing
    without a need. So a case that declares `case.vol_paths` (the
    path(s) its own comparator reads back) is judged against ONLY the
    other group members that touch an OVERLAPPING path -- terminal iff
    none of THOSE are later. A case that leaves `vol_paths` empty (the
    field's own default; no module has opted a case out of tracking
    this except by never setting it) is judged conservatively against
    the WHOLE group instead, because this function cannot know what a
    comparator with no declared path actually reads -- guessing "it's
    fine" would be the same unverified-oracle mistake docs/E2E.md sec 4
    forbids, just aimed at a harness fact instead of a maux one."""
    if runnable_cids is None:
        runnable_cids = {c.cid for c in registry.cases}
    out = set()
    for case in registry.cases:
        if case.cid not in runnable_cids:
            continue
        if case.tree is None:
            out.add(case.cid)
            continue
        members = [m for m in registry.tree_group_cases(case.tree)
                  if m.cid in runnable_cids]
        if len(members) <= 1:
            out.add(case.cid)
            continue
        my_paths = set(case.vol_paths)
        if my_paths:
            later_same_path = any(
                m.cid > case.cid and my_paths & set(m.vol_paths)
                for m in members)
            if not later_same_path:
                out.add(case.cid)
                continue
        # No declared vol_paths (conservative fallback), or a later
        # member genuinely shares this case's own watched path(s):
        # sound only if this IS the group's own last runnable member.
        if case.cid == max(m.cid for m in members):
            out.add(case.cid)
    return out


def reduced_assertion_cases(registry, runnable_cids=None):
    """The complement of terminal_cids(), restricted to tree_seq= cases
    only (a case with no tree= is always terminal and never appears
    here) -- for check_e2e_fs.py's own printed REDUCED ASSERTION table
    (task requirement: 'the limitation named explicitly in a table the
    gate prints', never a silent downgrade). Returns
    [(cid, tool, tree, vol_paths), ...] in cid order."""
    term = terminal_cids(registry, runnable_cids)
    if runnable_cids is None:
        runnable_cids = {c.cid for c in registry.cases}
    out = []
    for case in registry.cases:
        if case.cid in runnable_cids and case.tree_seq and \
                case.cid not in term:
            out.append((case.cid, case.tool, case.tree, tuple(case.vol_paths)))
    return sorted(out)


def cmp_exact(case, got, ref_out, volume, hostdir):
    """The default 'exact' comparator, seeded by Registry itself (see
    below) so producing modules do NOT each define their own 'exact' key
    -- 'exact' is common enough that letting every module claim it would
    turn the duplicate-key check into a foot-gun rather than a safety
    net. A module needing a DIFFERENT comparison writes its own, uniquely
    named, key."""
    if got == ref_out:
        return True, ''
    return False, _first_diff(got, ref_out)


def _first_diff(got, want):
    n = min(len(got), len(want))
    for i in range(n):
        if got[i] != want[i]:
            return (f'first difference at byte {i}: maux ${got[i]:02X} vs '
                    f'reference ${want[i]:02X}\n'
                    f'  maux      {got[max(0,i-24):i+24]!r}\n'
                    f'  reference {want[max(0,i-24):i+24]!r}')
    return (f'identical for {n} bytes then length differs: maux {len(got)} '
            f'B, reference {len(want)} B\n'
            f'  maux tail      {got[n:n+64]!r}\n'
            f'  reference tail {want[n:n+64]!r}')


# ===========================================================================
# Tree comparison -- for poststate=True cases.  Both `want` and `got` are
# in e2e_fsmap.read_tree()'s shape.
#
# THE ENCODING BOUNDARY (docs/E2E.md sec 9.5, applied to the filesystem
# tranche) -- TL fix, 2026-08-23. BLOCKER: `want` used to carry HOST-
# native bytes (host_tree() read a host directory verbatim) while `got`
# (e2e_fsmap.read_tree()) carries IMAGE bytes -- high-bit/$8D for any
# 'text'-kind fixture, because e2e_fsmap.stage_tree() encodes the image
# side (encode_fixture -> a2til convert.text_from_host(high_bit=True))
# but e2e_fsmap.host_stage_tree() writes the HOST mirror byte-verbatim
# on purpose (the host reference tool needs ordinary LF text to run
# against). Reproduced on a scratch volume: MUT03/KEEP compared
# b'keep me\n' (host) against b'\xeb\xe5\xe5\xf0\xa0\xed\xe5\x8d' (image)
# -- ANY poststate case with a surviving/copied/moved text file false-
# reds.
#
# CHOSEN SHAPE: compare in IMAGE space, decided HERE, implemented in
# EXACTLY ONE place -- host_tree()'s own `kinds=` parameter, below.
# host_tree() encodes a 'text'-kind file's HOST bytes with the SAME
# encode_fixture() call stage_tree() used to build the image, before
# the byte ever reaches this function. compare_tree() itself is
# UNCHANGED and stays a pure byte compare (`wc != gc` below) -- it does
# not know or care which side was translated, exactly like sec 9.5's
# rule for decode_maux_text keeps normalisation to ONE ungenerous site.
# 'raw'-kind fixtures are untouched on both sides (encode_fixture('raw',
# data) is a no-op), and the transform is length-preserving for 'text'
# (LF -> CR is 1:1), so `size` -- computed from the ALREADY-encoded
# bytes in host_tree() -- still compares directly.  e2e_fsmap.
# host_stage_tree()/read_tree() are NOT touched: the former must stay
# host-native (the host `mv`/`cp`/`rm` reference has to run against real
# text), the latter must stay a raw, unmodified read of what the volume
# actually stores.  See host_tree()'s own docstring for the full
# argument and merged_kinds_for_tree() for how a case's post-mutation
# NEW paths (a cp/mv destination) resolve their kind.
# ===========================================================================
def compare_tree(want, got, path=''):
    missing = sorted(set(want) - set(got))
    extra = sorted(set(got) - set(want))
    if missing:
        return False, f'{path or "/"}: missing {missing}'
    if extra:
        return False, f'{path or "/"}: unexpected {extra}'
    for name in want:
        w, g = want[name], got[name]
        p = f'{path}/{name}'
        if w['is_dir'] != g['is_dir']:
            return False, f'{p}: is_dir {w["is_dir"]} vs {g["is_dir"]}'
        if w.get('type') is not None and w['type'] != g.get('type'):
            return False, (f'{p}: file type ${w["type"]:02X} vs '
                           f'${(g.get("type") or 0):02X}')
        if w['is_dir']:
            ok, detail = compare_tree(w['children'], g['children'], p)
            if not ok:
                return False, detail
        else:
            if w.get('size') is not None and w['size'] != g.get('size'):
                return False, f'{p}: size {w["size"]} vs {g.get("size")}'
            wc, gc = w.get('content') or b'', g.get('content') or b''
            if wc != gc:
                n = min(len(wc), len(gc))
                i = next((k for k in range(n) if wc[k] != gc[k]), n)
                return False, f'{p}: content differs at byte {i}'
    return True, ''


def host_tree(root_dir, types=None, kinds=None):
    """Build a read_tree()-shaped dict from a HOST directory, for
    constructing the 'want' side of a poststate comparison after a
    module's ref_op has mutated a host copy of its tree.  `types`, if
    given, is {relpath: prodos_file_type} for files whose ProDOS type
    must be checked; a file absent from `types` gets type=None (not
    checked -- compare_tree skips a None 'type').  size is left None too
    (derived implicitly via content equality) unless the caller wants to
    assert it explicitly by post-processing the returned dict.

    `kinds` IS THE ENCODING BOUNDARY (docs/E2E.md sec 9.5; see the
    module-level comment above compare_tree() for the full argument and
    the reproduced bug). {relpath: 'text'|'raw'} -- kinds_for_tree() /
    merged_kinds_for_tree() build it from the SAME MUT_TREES fixture
    spec e2e_fsmap.stage_tree() used to write the image side. For a FILE
    relpath found in `kinds`, this function applies
    e2e_fsmap.encode_fixture(kind, data) -- the SAME call stage_tree()
    makes -- to the just-read HOST bytes BEFORE they go into 'content',
    so the returned tree is already in IMAGE encoding and
    compare_tree()'s byte compare needs no normalisation of its own.
    'raw' is a no-op (encode_fixture('raw', data) returns data
    unchanged, so a raw fixture stays byte-exact on both sides); 'text'
    is length-preserving (LF -> CR, 1:1), so `size` -- computed below,
    AFTER the transform -- is still the real post-encoding length.

    kinds=None (the default, not passed at all) applies NO transform --
    full backward compatibility for a hypothetical caller outside the
    poststate machinery. kinds={} or any non-None dict OPTS IN: every
    FILE relpath this walk reaches must then have an entry, or this
    raises ValueError naming the missing relpath -- a caller that opted
    into the encoding boundary but left a path uncovered is exactly how
    MUT03/KEEP false-red, silently, the first time; the fix does not
    reopen that hole through a second, quieter default. Every
    poststate=True call site in this tranche (check_e2e_fs.py's
    poststate_verdict, e2e_fs_selftest.py's per-case teeth) MUST pass
    kinds=merged_kinds_for_tree(registry, case) alongside types=
    merged_types_for_tree(...)."""
    types = types or {}
    strict_kinds = kinds is not None
    kinds = kinds or {}

    def walk(d, rel):
        out = {}
        for name in sorted(os.listdir(d)):
            full = os.path.join(d, name)
            r = f'{rel}/{name}' if rel else name
            if os.path.isdir(full):
                out[name] = {'is_dir': True, 'type': 0x0F, 'size': None,
                            'content': None, 'children': walk(full, r)}
            else:
                with open(full, 'rb') as fh:
                    data = fh.read()
                kind = kinds.get(r)
                if kind is not None:
                    data = FM.encode_fixture(kind, data)
                elif strict_kinds:
                    raise ValueError(
                        f'host_tree(): file {r!r} has no entry in '
                        f'kinds= ({sorted(kinds)}) -- the poststate '
                        f"comparator's encoding boundary (docs/E2E.md "
                        f"sec 9.5) needs to know whether this file is "
                        f"'text' (encode before compare) or 'raw' "
                        f"(byte-exact) before it can be compared "
                        f"against the image side; missing coverage "
                        f'here is exactly how MUT03/KEEP false-red')
                # E7 integration fix, 2026-08-23: `size` is now ALWAYS a
                # real, host-observable fact (len(data)), never None --
                # tree_mutants()'s 'changed size' mutant only ever
                # touches the recorded size FIELD, not the content
                # bytes, so leaving size unset made that whole mutation
                # kind invisible to compare_tree (CONTRACT sec 7.3
                # requires it be rejected). No guessing involved: this
                # is just the file's own length -- computed AFTER the
                # kinds= transform above, so it is the post-encoding
                # length when a transform applied.
                out[name] = {'is_dir': False, 'type': types.get(r),
                            'size': len(data), 'content': data,
                            'children': None}
        return out
    return walk(root_dir, '')


def types_for_tree(registry, tree):
    """{relpath: prodos_file_type} for every FILE fixture staged under
    a MUT_TREES tree, as unpack_fixture_spec would resolve it -- for a
    poststate=True case's host_tree(types=...) argument (CONTRACT sec
    7.3's 'changed ProDOS file type' rejection, which was going
    UNCHECKED: neither check_e2e_fs.py's poststate_verdict nor
    e2e_fs_selftest.py's own poststate teeth ever passed `types=` to
    host_tree() at all, so every file's 'type' stayed None and
    compare_tree's type check never fired).

    LIMITATION, CLOSED (E8, 2026-08-23; originally stated rather than
    guessed at, E7): this only covers a file that survives its case's
    mutation at the SAME relpath (an rm/mv/mkdir FAILURE case leaving a
    fixture untouched, for instance) -- CONTRACT sec 5.2's Case shape
    had no field for a case to declare its own expected type at a NEW
    post-mutation path (mv's cross-directory destination, cp's
    destination, a file a copy creates). That gap is now closed by
    `Case.expect_types` + `resolve_expect_types`/`merged_types_for_tree`
    below, NOT by modelling each tool's own correct-behaviour semantics
    here: a case states, per new relpath, either an explicit type or
    ('from', src_relpath), and the source's type is read out of THIS
    function's own PRE-state dict -- the volume's own directory entry,
    not an authored belief about what mv/cp does. A poststate=True
    case's `types=` argument to host_tree() should be built via
    `merged_types_for_tree(registry, case)`, not this function alone,
    whenever the case's tree has any created/moved/copied destination."""
    out = {}
    for relpath, spec in registry.mut_trees.get(tree, {}).items():
        if spec is DIR:
            continue
        _kind, _data, file_type, _aux, _set_info = FM.unpack_fixture_spec(spec)
        out[relpath] = file_type
    return out


def resolve_expect_types(case, pre_types):
    """Resolve `case.expect_types` (Case's own docstring) into a plain
    {relpath: file_type} dict, against `pre_types` -- types_for_tree()'s
    OWN pre-state dict for the same tree. An int value passes through
    unchanged; ('from', src_relpath) becomes pre_types[src_relpath] --
    raising KeyError with the available keys listed if src_relpath was
    never staged, rather than silently defaulting to None (the exact
    failure mode this whole mechanism exists to remove)."""
    out = {}
    for relpath, spec in case.expect_types.items():
        if isinstance(spec, tuple):
            src = spec[1]
            if src not in pre_types:
                raise KeyError(
                    f"case {case.cid}: expect_types[{relpath!r}] = "
                    f"('from', {src!r}), but {src!r} is not among the "
                    f"pre-state file types for tree {case.tree!r} "
                    f"({sorted(pre_types)}) -- check the source relpath "
                    f"against this tree's own MUT_TREES fixture keys")
            out[relpath] = pre_types[src]
        else:
            out[relpath] = spec
    return out


def merged_types_for_tree(registry, case):
    """types_for_tree()'s pre-state {relpath: file_type} dict for
    `case.tree`, merged with `case.expect_types` resolved against that
    SAME pre-state snapshot (resolve_expect_types) -- what a
    poststate=True case's host_tree(types=...) argument should actually
    be built from (e2e_fs_selftest.py's per-case poststate teeth,
    check_e2e_fs.py's poststate_verdict). case.expect_types wins on a
    key collision with the pre-state dict (a case declaring an explicit
    expectation for a path that also happens to have been staged is
    stating something more specific than the generic derivation)."""
    pre_types = types_for_tree(registry, case.tree)
    merged = dict(pre_types)
    merged.update(resolve_expect_types(case, pre_types))
    return merged


# ---------------------------------------------------------------------------
# kinds_for_tree / resolve_expect_kinds / merged_kinds_for_tree -- TL fix,
# 2026-08-23, THE ENCODING BOUNDARY's other half. Exact siblings of
# types_for_tree / resolve_expect_types / merged_types_for_tree above,
# same reason to exist: a poststate=True case's new post-mutation path
# (a cp/mv destination) has no MUT_TREES entry of its own, so its
# CONTENT KIND ('text' vs 'raw' -- which host_tree()'s kinds= argument
# needs, see its own docstring) is not directly known either, just like
# its ProDOS file TYPE was not (E8's gap, closed by expect_types/
# resolve_expect_types/merged_types_for_tree). Content kind travels with
# the SAME provenance as file type: mv/cp copy a file's bytes UNCHANGED
# (no tool in this tranche re-encodes content in flight), so wherever a
# case's expect_types says a new path's TYPE came from is exactly the
# relpath its CONTENT KIND came from too -- these three functions read
# the SAME case.expect_types dict types_for_tree's trio reads, just
# projecting it onto `kind` instead of `file_type`.
# ---------------------------------------------------------------------------
def kinds_for_tree(registry, tree):
    """{relpath: 'text'|'raw'} for every FILE fixture staged under a
    MUT_TREES tree, as unpack_fixture_spec would resolve it --
    types_for_tree()'s exact sibling, for host_tree()'s `kinds=`
    argument instead of its `types=` argument."""
    out = {}
    for relpath, spec in registry.mut_trees.get(tree, {}).items():
        if spec is DIR:
            continue
        kind, _data, _ftype, _aux, _set_info = FM.unpack_fixture_spec(spec)
        out[relpath] = kind
    return out


def resolve_expect_kinds(case, pre_kinds):
    """case.expect_types's own ('from', src_relpath) entries,
    reinterpreted for CONTENT KIND -- resolve_expect_types's exact
    sibling. An explicit int entry (a bare ProDOS file type, no 'from'
    provenance) carries no kind information at all -- raises KeyError
    naming the relpath, the same ungenerous shape resolve_expect_types
    uses for a missing 'from' source, rather than silently guessing
    'raw' or 'text' for a path nothing ever declared a kind for. (No
    case in this tranche uses an explicit int today -- see
    e2e_fs_common.py's own module docstring on why that is checked here
    rather than assumed.)"""
    out = {}
    for relpath, spec in case.expect_types.items():
        if isinstance(spec, tuple):
            src = spec[1]
            if src not in pre_kinds:
                raise KeyError(
                    f"case {case.cid}: expect_types[{relpath!r}] = "
                    f"('from', {src!r}), but {src!r} is not among the "
                    f"pre-state file kinds for tree {case.tree!r} "
                    f"({sorted(pre_kinds)}) -- check the source relpath "
                    f"against this tree's own MUT_TREES fixture keys")
            out[relpath] = pre_kinds[src]
        else:
            raise KeyError(
                f"case {case.cid}: expect_types[{relpath!r}] = {spec!r} "
                f"is an explicit ProDOS file type with no 'from' "
                f"provenance, so its CONTENT KIND (text/raw) is unknown "
                f"-- host_tree()'s encoding boundary needs one for "
                f"every file it compares; add 'from' provenance to this "
                f"case's expect_types, or extend this function -- never "
                f"guess")
    return out


def merged_kinds_for_tree(registry, case):
    """kinds_for_tree()'s pre-state {relpath: kind} dict for case.tree,
    merged with case.expect_types resolved for kind via
    resolve_expect_kinds -- merged_types_for_tree()'s exact sibling.
    THIS is host_tree()'s kinds= argument at every poststate=True call
    site, paired with merged_types_for_tree()'s own types= argument."""
    pre_kinds = kinds_for_tree(registry, case.tree)
    merged = dict(pre_kinds)
    merged.update(resolve_expect_kinds(case, pre_kinds))
    return merged


# ===========================================================================
# Registry -- merges every module's contributions, cids assigned in the
# order add() is called (module import order x per-module call order),
# duplicate-key checks that RAISE (CONTRACT sec 5.1's closing line).
# ===========================================================================
class Registry:
    def __init__(self):
        self.ro_files = {}
        self.ro_dirs = []
        self.mut_trees = {}
        self.divergence = {}
        self.global_keys = set()
        self.defects = {}
        self.invariants = {}
        #: Seeded, not empty -- see cmp_exact's own docstring on why
        #: 'exact' is pre-claimed rather than left for the first module
        #: that happens to want it.
        self.comparators = {'exact': cmp_exact}
        self.cases = []
        self.case_ids = {}
        self._next_cid = 1
        #: Ownership maps, public -- TL's per-module block-cost report
        #: (build_e2efs_image.py) and the Cnn -> case-id attribution
        #: (check_e2e_fs.py's a2til check() report) both read these.
        self.tree_owner = {}       # tree id -> module name
        self.file_owner = {}       # RO_FILES relpath -> module name
        self.dir_owner = {}        # RO_DIRS relpath -> module name
        #: tree id -> [owning case cid, ...], in cid order. Exclusive
        #: trees (the common case) get a one-element list; a tree_seq=
        #: group (TL ruling 2026-08-23) gets one element per participating
        #: case, contiguous in cid order (enforced in add_module below).
        self.tree_case = {}
        #: tree id -> bool, whether the FIRST case to claim it declared
        #: tree_seq=True. Every later claimant of a shared tree must
        #: also declare tree_seq=True -- silence means exclusive even
        #: from the joining case's own point of view.
        self._tree_is_seq = {}
        self._modules = []

    def _claim(self, table, key, value, kind, modname):
        if key in table:
            raise ValueError(
                f'duplicate {kind} key {key!r}: claimed by an earlier '
                f'module and again by {modname!r} -- CONTRACT sec 5.1: '
                f'"Two modules claiming the same key is a merge error, '
                f'not a last-writer-wins."')
        table[key] = value

    def add_module(self, mod):
        name = mod.NAME if hasattr(mod, 'NAME') else mod.__name__
        self._modules.append(name)

        for relpath, spec in getattr(mod, 'RO_FILES', {}).items():
            relpath = FM.check_path(relpath)
            self._claim(self.ro_files, relpath, spec, 'RO_FILES', name)
            self.file_owner[relpath] = name
        for d in getattr(mod, 'RO_DIRS', []):
            d = FM.check_path(d)
            if d in self.ro_dirs:
                raise ValueError(f'duplicate RO_DIRS entry {d!r}: claimed '
                                f'again by {name!r}')
            self.ro_dirs.append(d)
            self.dir_owner[d] = name
        for tree, files in getattr(mod, 'MUT_TREES', {}).items():
            FM.check_name(tree)
            if tree in self.mut_trees:
                raise ValueError(
                    f'duplicate MUT_TREES id {tree!r}: claimed by both '
                    f'{self.tree_owner.get(tree)!r} and {name!r}')
            for relpath in files:
                FM.check_path(relpath)
            self.mut_trees[tree] = files
            self.tree_owner[tree] = name

        for k, v in getattr(mod, 'ENTRIES', {}).items():
            self._claim(self.divergence, k, v, 'ENTRIES/DIVERGENCE', name)
        for k, v in getattr(mod, 'DEFECTS', {}).items():
            self._claim(self.defects, k, v, 'DEFECTS', name)
        for k, v in getattr(mod, 'INVARIANTS', {}).items():
            self._claim(self.invariants, k, v, 'INVARIANTS', name)
        for k in getattr(mod, 'GLOBALS', {}):
            self.global_keys.add(k)
        for k, v in getattr(mod, 'COMPARATORS', {}).items():
            self._claim(self.comparators, k, v, 'COMPARATORS', name)

        def add(tool, **kw):
            if 'case_id' not in kw:
                raise ValueError(
                    f'case {self._next_cid} ({name}) is missing '
                    f'case_id= -- stable exemption keys must not depend '
                    f'on registration order')
            case = Case(self._next_cid, tool, **kw)
            case.module = name
            case.synth_fn = getattr(mod, 'synth')
            if case.case_id in self.case_ids:
                other = self.case_ids[case.case_id]
                raise ValueError(
                    f'duplicate case_id {case.case_id!r}: cid '
                    f'{other.cid} ({other.module}) and cid {case.cid} '
                    f'({name}) -- case_id is the stable exemption key')
            self.case_ids[case.case_id] = case
            for word in case.operand_words():
                if isinstance(word, str):
                    FM.check_operand(word)
            if case.tree is not None:
                if case.tree not in self.mut_trees:
                    raise ValueError(
                        f'case {case.cid} ({name}) owns tree={case.tree!r} '
                        f'but that id is not a key of {name}.MUT_TREES')
                owners = self.tree_case.get(case.tree)
                if owners is None:
                    self.tree_case[case.tree] = [case.cid]
                    self._tree_is_seq[case.tree] = case.tree_seq
                else:
                    if not (self._tree_is_seq[case.tree] and case.tree_seq):
                        raise ValueError(
                            f"tree {case.tree!r} is claimed by more than "
                            f"one case (cid {owners[0]} and {case.cid}) -- "
                            f"CONTRACT sec 3.5: 'no other case may name "
                            f"it' (TL ruling 2026-08-23: opt into sharing "
                            f"by setting tree_seq=True on EVERY "
                            f"participating case -- silence still means "
                            f"exclusive)")
                    if owners[-1] != case.cid - 1:
                        raise ValueError(
                            f"tree {case.tree!r} is shared by cases "
                            f"{owners + [case.cid]}, which are not "
                            f"CONTIGUOUS in cid order (previous member "
                            f"cid {owners[-1]}, next claim cid {case.cid}) "
                            f"-- TL ruling 2026-08-23: 'a sequence whose "
                            f"order depends on module import order is not "
                            f"a sequence'")
                    owners.append(case.cid)
            if case.status_ruled is not None:
                if case.status_ruled not in self.divergence:
                    raise ValueError(
                        f'case {case.cid} ({name}) cites '
                        f'status_ruled={case.status_ruled!r}, which is not '
                        f'in DIVERGENCE')
                grade = self.divergence[case.status_ruled][0]
                if grade not in ('RULED', 'EXCLUDED'):
                    raise ValueError(
                        f'case {case.cid} ({name}): status_ruled='
                        f'{case.status_ruled!r} has grade {grade!r} -- only '
                        f'RULED or EXCLUDED may exempt a status (CONTRACT '
                        f'sec 5.3: under DISCHARGED/STRUCTURAL the reference '
                        f'still computes the answer, so an unexplained '
                        f'status difference there is a generation-time '
                        f'error, not a design bound)')
            self._next_cid += 1
            self.cases.append(case)
            return case
        mod.cases(add)

    def tree_groups(self):
        """TL ruling 2026-08-23: '[the runner] must PRINT the group --
        which cases share which tree, in order.' Returns [(tree,
        [cid, ...])] for every tree claimed by more than one case (an
        exclusive, single-owner tree is not a 'group' and is omitted),
        in first-claimed order -- so the sharing is visible in the gate
        log rather than implicit. Both check_e2e_fs.py (the real runner)
        and e2e_fs_selftest.py (the host-only one this task can actually
        execute) call this."""
        return [(tree, cids) for tree, cids in self.tree_case.items()
                if len(cids) > 1]

    def case_by_cid(self, cid):
        for c in self.cases:
            if c.cid == cid:
                return c
        raise KeyError(cid)

    def tree_group_cases(self, tree):
        """The Case objects sharing `tree`, in cid order -- for the
        cumulative ref_op application a tree_seq group needs (TL ruling:
        'ref_op callables apply CUMULATIVELY to the host copy of that
        tree, in the same order')."""
        return [self.case_by_cid(cid) for cid in self.tree_case.get(tree, [])]

    def check_citations(self):
        """This tranche's own ratchet, table-driven via the SAME mechanism
        stage 1 uses (e2e_divergence.check_citations_table) but over THIS
        registry's own merged DIVERGENCE/GLOBAL_KEYS -- CONTRACT: 'share
        the mechanism without sharing a table.'

        E7 integration fix, 2026-08-23: `get_cited` also counts
        case.status_ruled= as a citation, not just case.diverges=.
        CONTRACT sec 5.3 requires status_ruled='s key to already exist
        in DIVERGENCE (validated in add_module) -- it IS a citation of
        that entry, just via a different field. The stock default
        (case.diverges only) made e2e_fs_mutate.py's own
        ('mv', 'ARGBUFSZ pathname cap has no host equivalent') entry --
        cited ONLY via status_ruled=, per CONTRACT sec 5.3's own
        example of exactly this shape -- report as a false-positive
        DEAD entry.

        Registry-merge fix, 2026-08-23 (same defect as stage 1's own
        check_citations, see e2e_divergence.check_citations's docstring
        for the full reproduction): this used to validate ONLY
        case.diverges/status_ruled against self.divergence, never
        case.defect against self.defects (the merged KNOWN_DEFECTS-
        shaped table built from every module's own DEFECTS dict --
        Registry.add_module's `self._claim(self.defects, k, v,
        'DEFECTS', name)`). judge() below absorbed ANY non-None
        case.defect as a valid pin, so an unregistered key -- a typo, or
        a key deleted from a module's DEFECTS without updating its
        citations -- silently passed. Now validated with the SAME
        check_citations_table call this method already makes for
        DIVERGENCE, just a second call against self.defects.

        RULING on the dead-entry half, matching e2e_divergence.
        check_citations's own ruling for stage 1: self.defects gets the
        SAME ratchet-only-tightens dead-entry check self.divergence
        gets, and for the same reason -- an uncited defect key is either
        a fix that forgot to delete its own pin, or a pin that was never
        wired up, and either way a green run should say so rather than
        carry it forward silently. Checked over `self.cases` (every case
        Registry.add_module ever registered, HANG_QUARANTINE included --
        the same set self.divergence is already checked over, and the
        same reason: e2e_fs_corpus.py's own ALL_CASES/CASES split exists
        precisely so 'the divergence ratchet's bookkeeping' -- and now
        the defect ratchet's -- never goes dead merely because a case
        citing an entry was withheld from the generated script, not
        deregistered). No GLOBAL_KEYS analogue for defects, same
        reasoning as stage 1: every defect entry here is owned by
        exactly the case(s) that cite it, so the second call's
        global_keys argument is the empty set."""
        def get_cited(case):
            cited = list(case.diverges)
            if case.status_ruled is not None:
                cited.append(case.status_ruled)
            return cited
        errs, dead = D.check_citations_table(
            self.cases, self.divergence, self.global_keys,
            get_cited=get_cited, label='DIVERGENCE')
        d_errs, d_dead = D.check_citations_table(
            self.cases, self.defects, set(),
            get_cited=lambda c: [c.defect] if c.defect is not None else [],
            label='DEFECTS')
        return errs + d_errs, dead + d_dead


def call_synth(case, ref_out, ref_err, ref_extra, volume, hostdir):
    """E7 integration, 2026-08-23: CONTRACT sec 5.1's own prose says
    synth() returns "the (stdout+stderr) bytes" -- ONE merged value,
    matching every case's real /mnt/MAUX/OUT/Onn file (always `> Onn
    2>&1`). Four of the six packages (e2e_fs_ls, e2e_fs_mutate,
    e2e_fs_meta, e2e_invariants) implement it exactly that way. Two
    (e2e_fs_walk, e2e_fs_idiom) return a (stdout, stderr) 2-tuple
    instead (stderr always b'' in practice -- neither module ever
    splits a real diagnostic out of its own merged text). Rather than
    edit either shape's actual intent, this call site accepts both and
    always normalises to one merged bytes value, which is what every
    downstream consumer (judge(), _mutants()) actually wants -- a
    single case produces a single output file, never two."""
    result = case.synth_fn(case, ref_out, ref_err, ref_extra,
                           volume=volume, hostdir=hostdir)
    if isinstance(result, tuple):
        out, err = result
        return out + err
    return result


def apply_tree_seq_ref_op(registry, case, dst):
    """TL ruling 2026-08-23: for a case whose tree is shared (tree_seq=
    True on every participant), the host reference tree at `dst` (an
    ALREADY-COPIED, pristine host mirror of case.tree) must reflect
    every group member's ref_op UP TO AND INCLUDING `case`, applied in
    cid order -- not just this one case's own ref_op in isolation,
    because poststate=True at each step is only well-defined given that
    cumulative ordering. For an exclusive (non-shared) tree this is
    exactly equivalent to calling case.ref_op(dst) alone."""
    if case.tree is None:
        return
    for member in registry.tree_group_cases(case.tree):
        if member.ref_op is not None:
            member.ref_op(dst)
        if member is case:
            return


# ===========================================================================
# Teeth -- CONTRACT sec 7.  Mutation battery (items 2 and 6: five stage-1
# kinds + REORDER, new for this tranche) and the tree-mutation battery
# (item 3).
# ===========================================================================
ENC = C.encode_maux_text


def _mutants(out, err):
    """CONTRACT sec 7.2/7.6: flip one bit, clear one high bit, drop a
    line, duplicate a line, truncate one byte, REORDER two lines.  Same
    shape as scripts/e2e_selftest.py's own _mutants, plus the REORDER
    kind stage 1 never needed (stage 1 has no order-bearing oracle;
    find/du's directory order is exactly the property this tranche adds)."""
    target, is_err = (err, True) if (not out and err) else (out, False)
    muts = []

    def pack(data):
        return (out, data) if is_err else (data, err)

    if target:
        b = bytearray(target)
        i = len(b) - 2 if len(b) >= 2 else 0
        b[i] ^= 0x01
        muts.append(('flip one bit', *pack(bytes(b))))

        b = bytearray(target)
        b[len(b) // 2] &= 0x7F
        muts.append(('clear one high bit', *pack(bytes(b))))

        lines = target.split(b'\x8d')
        if len(lines) > 2:
            muts.append(('drop a line',
                        *pack(b'\x8d'.join(lines[:-2] + lines[-1:]))))
            muts.append(('duplicate a line',
                        *pack(b'\x8d'.join(lines[:1] + lines))))
        if len(lines) > 3:
            reordered = lines[:]
            reordered[0], reordered[1] = reordered[1], reordered[0]
            muts.append(('reorder two lines',
                        *pack(b'\x8d'.join(reordered))))
        muts.append(('truncate one byte', *pack(target[:-1])))
    else:
        muts.append(('spurious output', ENC(b'x\n'), err))
        muts.append(('spurious diagnostic',
                    ENC(b'sort: cannot open /mnt/MAUX/RO/FILE\n'), err))
    return muts


def _first_leaf_path(tree):
    for name, node in tree.items():
        if not node['is_dir']:
            return [name]
        sub = _first_leaf_path(node['children'])
        if sub:
            return [name] + sub
    return None


def _get_node(tree, path):
    node, parent_dict = tree, tree
    for i, name in enumerate(path):
        if i == len(path) - 1:
            return parent_dict[name], parent_dict
        parent_dict = parent_dict[name]['children']
    raise KeyError(path)


def _file_mutants(tree, path):
    """CONTRACT sec 7.3's five FILE-leaf mutants (missing/extra/size/
    type/content), unchanged in shape from before the 2026-08-23 fix --
    factored out of tree_mutants() below so a directory-only or empty
    tree can get its OWN mutant battery instead of silently getting
    none."""
    muts = []

    t = copy.deepcopy(tree)
    _, parent = _get_node(t, path)
    del parent[path[-1]]
    muts.append(('missing file', t))

    t = copy.deepcopy(tree)
    _, parent = _get_node(t, path)
    parent['ZZBOGUS'] = {'is_dir': False, 'type': 0x04, 'size': 1,
                         'content': b'x', 'children': None}
    muts.append(('extra file', t))

    t = copy.deepcopy(tree)
    node, _ = _get_node(t, path)
    node['size'] = (node['size'] or 0) + 1
    muts.append(('changed size', t))

    t = copy.deepcopy(tree)
    node, _ = _get_node(t, path)
    node['type'] = ((node['type'] or 0) ^ 0xFF) & 0xFF
    muts.append(('changed file type', t))

    t = copy.deepcopy(tree)
    node, _ = _get_node(t, path)
    if node['content']:
        b = bytearray(node['content'])
        b[0] ^= 0xFF
        node['content'] = bytes(b)
        muts.append(('changed content byte', t))

    return muts


def _dir_mutants(tree, path):
    """Mutants for a tree that has NO file anywhere but DOES have a
    directory (found at top level, per tree_mutants()'s own search --
    TL fix, 2026-08-23, closing the finding that tree_mutants() returned
    [] for every mkdir poststate case: cases 51/52/55/124's want_tree is
    a bare list of empty directories, so _first_leaf_path() found no
    file and the old code gave up).  compare_tree() checks THREE things
    about a directory node -- membership (is it there at all), is_dir,
    and type (host_tree() always writes $0F for a directory, per its own
    walk()) -- and this supplies one mutant per axis, plus the same
    'missing'/'extra' pair the file case already proves:

      * 'missing directory'      -- delete it (membership, want side)
      * 'extra directory'        -- add a bogus sibling (membership, got
                                     side)
      * 'changed directory type' -- flip its type byte
      * 'directory became a file' -- same name, is_dir flipped to False

    A CONTENT/SIZE mutant makes no sense for a directory (compare_tree
    only reads content/size when w['is_dir'] is False), so this battery
    is four, not five."""
    muts = []

    t = copy.deepcopy(tree)
    _, parent = _get_node(t, path)
    del parent[path[-1]]
    muts.append(('missing directory', t))

    t = copy.deepcopy(tree)
    _, parent = _get_node(t, path)
    parent['ZZBOGUSDIR'] = {'is_dir': True, 'type': 0x0F, 'size': None,
                            'content': None, 'children': {}}
    muts.append(('extra directory', t))

    t = copy.deepcopy(tree)
    node, _ = _get_node(t, path)
    node['type'] = ((node['type'] or 0) ^ 0xFF) & 0xFF
    muts.append(('changed directory type', t))

    t = copy.deepcopy(tree)
    node, parent = _get_node(t, path)
    parent[path[-1]] = {'is_dir': False, 'type': node['type'], 'size': 0,
                        'content': b'', 'children': None}
    muts.append(('directory became a file', t))

    return muts


def tree_mutants(tree):
    """CONTRACT sec 7.3's mutant battery for a poststate=True case's
    want_tree.  TL fix, 2026-08-23 (finding: tree_mutants() silently
    returned [] for 8 of 20 poststate cases -- every successful mkdir
    case, plus every case whose tree ends up fully empty -- because it
    only ever tried the FILE-leaf battery below and gave up the moment
    _first_leaf_path() found no file; e2e_fs_selftest.py's consumer then
    treated the empty list as a no-op with no printed signal, so those
    cases' poststate assertions had ZERO demonstrated teeth).  Three
    shapes, tried in order:

      1. a FILE leaf exists somewhere (depth-first, unchanged from
         before) -- the original five mutants (_file_mutants).
      2. no file, but a DIRECTORY exists at top level (an all-mkdir
         want_tree, e.g. {'NEWDIR': {...}}) -- four directory mutants
         (_dir_mutants).
      3. tree == {} -- a fully empty want_tree (e.g. an mv/cp whose
         SRC was never staged, or a failed mkdir): there is nothing to
         delete or retype, so the only well-formed mutant is adding a
         spurious top-level entry.  compare_tree({}, {}) trivially
         returns True, so 'extra entry' is the ONLY mutation that can
         exercise these cases' assertion at all -- it proves
         compare_tree's `extra = set(got) - set(want)` check actually
         fires when want is {}, which is exactly what those cases
         depend on.

    tree_mutants() therefore never returns [] any more for any tree
    reachable from this corpus; e2e_fs_selftest.py's caller still
    treats an empty return loudly (not silently) as a defensive
    backstop -- see its own comment at the call site."""
    path = _first_leaf_path(tree)
    if path is not None:
        return _file_mutants(tree, path)

    for name, node in tree.items():
        if node['is_dir']:
            return _dir_mutants(tree, [name])

    # Fully empty tree: nothing to mutate but 'add a spurious entry'.
    t = copy.deepcopy(tree)
    t['ZZBOGUS'] = {'is_dir': False, 'type': 0x04, 'size': 1,
                    'content': b'x', 'children': None}
    return [('extra entry at empty root', t)]
