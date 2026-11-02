#!/usr/bin/env python3
"""e2e_fs_idiom.py -- E6's package: THE FORM A HUMAN TYPES.

CONTRACT (scratchpad/CONTRACT.md) sec 8 is this module's charter. Both
bugs the operator found by booting the image -- lowercase `cd`, and
`find .` -- got past 56 gates, a differential harness and a fleet audit,
because every gate types what its author knew would work. This module
types what nobody has typed: case variants of every command word, the
dot idiom gated by a WALK (never a probe -- learning:01M0PBKZKZE55J4NE93
TYNJCPC's own conclusion), `..` composed across cd vs. typed literally,
bare command words before and after `cd`, trailing slashes, and flag
spellings a human actually uses.

RULE THAT GOVERNS THIS WHOLE FILE: an idiom case that fails is a FAILURE
by default. It may be pinned to a KNOWN_DEFECTS key that names the bug
and cites file:line. It may NEVER be folded into DIVERGENCE -- that is
the blanket docs/E2E.md sec 4 forbids, and it is exactly how a bug
acquires a reason and stops being a bug.

FIXTURES: everything this module needs lives under /mnt/MAUX/RO/IDIOM,
namespaced so it cannot collide with any other package's RO_DIRS/
RO_FILES:

    /mnt/MAUX/RO/IDIOM/A          text, "first\\n"
    /mnt/MAUX/RO/IDIOM/B          text, "second\\n"
    /mnt/MAUX/RO/IDIOM/SUB/C      text, "third\\n"

Five tiny MUT_TREES, one per mutating tool's case-typing case, each
below 2 blocks (CMKD/CRM/CMV/CCP/CCHM).

ASSUMED SIGNATURES (E1's e2e_fs_common.py does not exist in this
worktree -- built concurrently, per the task brief). This module is
written strictly against CONTRACT sec 5.1/5.2's prose. Where the prose
left a gap, the assumption is stated here and again in the final report:

  * `sh_words` is the BARE command words for one script line (tool +
    args, `;`-joined statements included as separate list elements with
    `;` as its own token). The harness appends `> /mnt/MAUX/OUT/Onn 2>&1`
    itself (matching stage-1's Case.sh_line() and CONTRACT sec 9's
    "every case uses ...", stated as a harness-level rule, not a per-
    case one).
  * `argv` is the maux-spelling operand list used only to help E1 derive
    a host reference invocation when `ref_argv` is not given; every case
    below that needs a non-obvious reference supplies `ref_argv`
    explicitly or (for defect/divergence cases) relies entirely on this
    module's own `synth()`, which is the actual authority for what
    "correct" means here.
  * `cwd='restore'` is set on the LAST case of a contiguous cd'd run.
    Because CONTRACT sec 9 also allows `;`-joined statements on one
    line, and `;` needs spaces around it, EVERY case below that needs a
    `cd` composes the whole `cd ... ; verify ...` sequence into ONE
    `sh_words` list and marks that ONE case `cwd='restore'` -- this
    sidesteps any ambiguity about whether 'restore' fires before or
    after a later case in the same region.
"""
import os

#: T4 review fix, 2026-08-23: reused directly by cmp_ls_refused's own
#: STRUCTURAL "refused" check (see the FLAG SPELLINGS group's cases()
#: comment and cmp_ls_dir_refused below) -- 'ls' registers before
#: 'idiom' in e2e_fs_corpus.MODULE_NAMES, so this module already
#: depends on e2e_fs_ls.py's ENTRIES being merged first (see the
#: MLI-pathname-entry comment below); importing its COMPARATORS
#: function the same way is the same dependency, not a new one.
import e2e_fs_ls as LS

NAME = 'idiom'

# ----------------------------------------------------------------------
# Fixtures -- namespaced under IDIOM/ so no other package's RO_DIRS or
# RO_FILES choice can collide with this module's.
# ----------------------------------------------------------------------
RO_DIRS = [
    'IDIOM', 'IDIOM/SUB',
    # a genuinely deep, human-plausible nesting for the MKPATH
    # silent-truncation defect (TL, 2026-08-23, from E2's fleet survey)
    'IDIOM/PROJECT',
    'IDIOM/PROJECT/REPORTS',
    'IDIOM/PROJECT/REPORTS/QUARTER',
    'IDIOM/PROJECT/REPORTS/QUARTER/ARCHIVE2026',
]

RO_FILES = {
    'IDIOM/A':     ('text', b'first\n'),
    'IDIOM/B':     ('text', b'second\n'),
    'IDIOM/SUB/C': ('text', b'third\n'),
    # /mnt/MAUX/RO/IDIOM/PROJECT/REPORTS/QUARTER/ARCHIVE2026/FINALFILE
    # is EXACTLY 64 characters -- MLI_PTH_MAXLN (inc/mli.equ:66) --
    # and is the literal first-64-byte PREFIX of FINALFILE.V2's own path
    # below (67 chars). This is deliberate, not coincidence: it is what
    # lets the truncation defect case below demonstrate the SCARY half
    # TL asked for -- the truncated pathname landing on a REAL, DIFFERENT
    # file, not merely failing to open.
    'IDIOM/PROJECT/REPORTS/QUARTER/ARCHIVE2026/FINALFILE': (
        'text', b'stale Q3 draft -- superseded\n'),
    'IDIOM/PROJECT/REPORTS/QUARTER/ARCHIVE2026/FINALFILE.V2': (
        'text', b'the real, current final report\n'),
}

#: One tiny tree per mutating tool's lowercase-typing case. Each is
#: below 2 blocks (a directory + at most one 1-block file); mkdir's own
#: tree starts EMPTY because the case creates the new entry itself.
MUT_TREES = {
    'CMKD': {},
    'CRM':  {'DOOMED':   ('text', b'gone\n')},
    'CMV':  {'OLDNAME':  ('text', b'moved\n')},
    'CCP':  {'SRC':      ('text', b'copied\n')},
    'CCHM': {'LOCKME':   ('text', b'locked\n')},
}

IDIOM_PATH = '/mnt/MAUX/RO/IDIOM'
SUB_PATH = IDIOM_PATH + '/SUB'

#: 67 characters -- 3 over MLI_PTH_MAXLN (64). Its first 64 bytes are
#: EXACTLY LONGPATH_TRUNCATED below (see RO_FILES's own comment).
LONGPATH = (IDIOM_PATH +
            '/PROJECT/REPORTS/QUARTER/ARCHIVE2026/FINALFILE.V2')
LONGPATH_TRUNCATED = LONGPATH[:64]
assert len(LONGPATH) == 67, len(LONGPATH)
assert LONGPATH_TRUNCATED == (
    IDIOM_PATH + '/PROJECT/REPORTS/QUARTER/ARCHIVE2026/FINALFILE')


# ----------------------------------------------------------------------
# DIVERGENCE contributions (ENTRIES). Kept deliberately few -- see the
# module docstring's rule. Both entries below cite a CONTRACT PINNED IN
# THE TOOL'S OWN SOURCE HEADER, not an unexamined omission, which is
# the line this module draws between "divergence" and "defect": ls.s's
# file header states its own restriction outright, in contrast with
# cd's STRCMP or MKPATH's total silence on dots, which nothing in the
# tree ever decided on purpose.
# ----------------------------------------------------------------------
ENTRIES = {
    ('ls', 'a flag must be the sole first argument'): (
        'RULED',
        "src/bin/ls.s's own file header, lines 1-9: \"-l, if present, "
        "MUST be the first argument. Any other argument beginning with "
        "'-' is an unknown option: usage to stderr, exit 2.\" ls.s:129-146 "
        "(START) checks ONLY argv[1] for being exactly \"-l\" (two-byte "
        "compare, dfb-terminated) -- if argv[1] does not itself begin "
        "with '-' at all, EVERY later argument, `-l` included, is fed "
        "to GET_FILE_INFO as a path and fails as an illegal ProDOS name "
        "(\"ls: -l: cannot access\", ls.s:317-334 PRINTACCESERR / "
        "ls.s:1043-1047 ERRPFX/ERRSUF_ACCESS). This is a documented, "
        "intentional restriction (v1 has exactly one flag; there is no "
        "getopt-style clustering or reordering for ls specifically -- "
        "contrast src/liba/getopt.s, which DOES support clustering, "
        "'--', and a bare '-' as an operand, and which ls.s does not "
        "use), not an oversight -- so it is divergence, not a defect."),

    # ('*', 'MLI pathname parameter capped at MLI_PTH_MAXLN (64)') --
    # the MKPATH-overflow divergence this module's own LONGPATH case
    # cites (below, via status_ruled=) -- is DEFINED in e2e_fs_ls.py,
    # not here, even though this module used to hold the DEFECTS entry
    # it replaces. Registration-order requirement, not a style choice:
    # status_ruled= is validated INLINE, at case-creation time, against
    # whatever the registry has merged SO FAR (e2e_fs_common.Registry.
    # add_module) -- modules register in the fixed order 'ls', 'find+du',
    # 'mutate', 'fs_meta', 'invariants', 'idiom' (e2e_fs_corpus.py), so
    # an entry only idiom.py defines is invisible to e2e_fs_ls.py's own
    # C14, which cites the SAME key and registers first. Defining it in
    # ls.py (first-registered) makes it visible to every later module,
    # idiom.py included -- ordinary diverges= citations have no such
    # constraint (checked only by the final, whole-registry
    # check_citations() pass), which is why every OTHER shared entry in
    # this file did not need to move.
}

# ----------------------------------------------------------------------
# KNOWN_DEFECTS -- owned by src/bin/sh.s and src/liba/mli.s, which this
# harness does not edit. Each is cited by at least one case below.
# ----------------------------------------------------------------------
DEFECTS = {
    # ('cd', 'builtin name is case-sensitive') RETIRED 2026-08-24:
    # FIXED. sh.s's CHCK_BLTN_CD compares case-insensitively now, so
    # `cd D` and `Cd D` change the prefix like `CD D` -- and sh.s's own
    # comment records the shape it closed ("it went unnoticed for every
    # builtin that ALSO ships as a binary -- lowercase `echo` missed the
    # builtin and then found `ECHO` on disk, because ProDOS's pathname
    # parser folds case"). Both cases that pinned it (lowercase `cd`,
    # mixed-case `Cd`) started AGREEING with the reference the first
    # time this corpus ever ran to the end, and the ratchet said so by
    # name rather than a human noticing.
    # ('sh', 'absolute command word can spawn a stale PATH-resolved
    # binary') was HERE and is deleted, not commented out: FIXED
    # 2026-08-23, sh.s's RSLV_PTH_STG :absolute branch now writes
    # SH_PATHFULL before returning. The case that pinned it (the
    # absolute `/bin/CAT` case, above in cases()) lost its defect=
    # citation and is now an ordinary REF/exact case.
    #
    # ('*', 'MKPATH silently truncates a pathname over 64 characters')
    # was HERE too and is also deleted, not commented out: FIXED
    # 2026-08-23 (src/liba/mli.s, branch t4-mkpath-fix commit f915af9,
    # merged onto this branch) -- but NOT retired to nothing. TL
    # ruling, 2026-08-23: MKPATH now fails CLOSED on overflow (sets
    # carry, corrupts its own truncated output with a byte no real
    # ProDOS name can contain) instead of silently resolving to a
    # wrong-but-real shorter object -- strictly safer, but the host
    # filesystem has no such 64-byte-per-MLI-parameter ceiling at all,
    # so maux still does not AGREE with it: it REFUSES where the host
    # would succeed on a genuinely 65+-character real path. That is a
    # platform LIMITATION, not a bug, so it moves to DIVERGENCE below
    # (('*', 'MLI pathname parameter capped at MLI_PTH_MAXLN (64)')),
    # not out of the ratchet entirely. The two cases that cited this
    # key (e2e_fs_ls.py's C14, this module's own LONGPATH case below)
    # now cite that DIVERGENCE entry instead.
    # ('*', 'dot and dotdot are not resolved outside cd') RETIRED
    # 2026-08-24: FIXED by the S2 dot-path work in MKPATH (the merge
    # commit's own summary: "dot paths and background jobs, and MKPATH
    # carries both contracts"). All ELEVEN cases that pinned it -- `ls
    # .`, `ls ./SUB`, `ls ..`, `cat ./A`, `cat ../A`, `find .`,
    # `find ./SUB1`, `find ..`, `du .` and the two walk-module twins --
    # now agree with the reference on stdout, exit status and poststate.
    #
    # The walk comparators keep their dot-path branch, renamed
    # `dot_root` (it was `idiom_defect`): it never meant "the defect is
    # present". It means "this case's root is a literal dot path", and
    # its expectation was always written for a FIXED maux -- a VOL walk
    # of the resolved directory with the literal prefix substituted back
    # in, because find.s and du.s print the path AS GIVEN. That is
    # exactly what maux now produces, which is why those cases pass.

}

# ----------------------------------------------------------------------
# INVARIANTS (oracle='INVARIANT') -- ps and df have no host reference
# (docs/E2E.md sec 7.1: say so explicitly). This module's only use of
# them is a light case-typing check, NOT their functional behaviour
# (e2e_invariants.py, E5, owns that). The property is deliberately weak
# but genuinely testable: a lowercase-typed external tool that resolved
# and ran at all must NOT have produced sh's own "command not found"
# text, which is the one string ONLY sh itself (never ps/df) emits.
# ----------------------------------------------------------------------
INVARIANTS = {
    ('*', 'idiom case word resolved to something other than sh itself'): (
        "output is non-empty and its first line is not sh's own "
        "\"sh: command not found\" diagnostic (src/bin/sh.s:7161, "
        "CMDNTFND_MSG)",
        "ps and df have no host reference at all (docs/E2E.md sec 7.1; "
        "df's own header notes there is no /usr/bin equivalent for a "
        "ProDOS volume's block layout, and ps's PID/BANK columns "
        "describe a process model no host tool models). What this "
        "package needs to know about them is narrower than their full "
        "functional correctness (e2e_invariants.py, E5, owns that): "
        "only whether the lowercase-typed WORD resolved to the real "
        "binary via ProDOS's own pathname upcasing, at all -- which the "
        "one string sh itself emits on a resolution failure answers "
        "directly, with no reference needed."),
}

GLOBALS = {}


# ----------------------------------------------------------------------
# Comparators: fn(case, got, ref, volume, hostdir) -> (ok, detail), per
# CONTRACT sec 5.1 exactly. `got`/`ref` are already decoded to host
# bytes (LF lines) by the harness per CONTRACT sec 6. `volume` is the
# e2e_fsmap-shaped VOL snapshot (an object with `.entry(relpath)` ->
# dict incl. 'blocks_used'/'type'/'access', and `.exists(relpath)`,
# matching the adapter every sibling package's own local proof harness
# already implements -- e2e_fs_ls_selftest.py's VolumeAdapter/Entry,
# local_teeth.py's Snap/VolumeView) for VOL-oracle cases; `ref` alone
# carries the host reference bytes for REF-oracle cases.
# ----------------------------------------------------------------------
def _lines(data):
    if not data:
        return []
    return data.split(b'\n')[:-1] if data.endswith(b'\n') else data.split(b'\n')


def cmp_exact(case, got, ref, volume, hostdir):
    if got == ref:
        return True, ''
    n = min(len(got), len(ref))
    for i in range(n):
        if got[i] != ref[i]:
            return False, (f'first difference at byte {i}: got '
                           f'{got[max(0,i-20):i+20]!r} vs want '
                           f'{ref[max(0,i-20):i+20]!r}')
    return False, (f'identical for {n} bytes then length differs: got '
                   f'{len(got)} B, want {len(ref)} B')


def cmp_name_multiset(case, got, ref, volume, hostdir):
    """Compare the MULTISET of FULL LINES (whole paths, exactly as
    `find` prints them) produced by a directory walk.

    Deliberately ORDER-INSENSITIVE -- see this module's non-degeneracy
    notes for why that is a stated exemption, not an oversight: these
    cases test whether the dot idiom reaches the right ENTRIES, not
    what order they print in (raw ProDOS directory order is
    e2e_fs_walk.py/E3's own, VOL-oracled, domain). A Counter (not a bare
    set) so a duplicated line is still caught -- it changes an entry's
    count, not just set membership.

    FINDING 1 fix, 2026-08-23 (adversarial review): this used to throw
    away everything but the BASENAME (`ln.rsplit(b'/', 1)[-1]`) before
    comparing -- `find`'s entire product IS the path it prints, and
    discarding the directory component left it unasserted. That let
    every path get rewritten to a wrong prefix (`/mnt/MAUX/...` ->
    `/WRONG/...`), or the whole hierarchy get replaced by any other
    tree with the same basenames, pass as a green PASS. Case 116 (`find
    /mnt/MAUX/RO/IDIOM`, absolute form) is oracle=REF with defect=None --
    an ordinary case nobody else backstops (it is NOT one of
    e2e_fs_walk.py's own tree-comparator cases) -- so nothing was
    checking the one thing `find` produces. Fixed by comparing whole
    LINES (full paths) as the multiset instead of just their
    basenames -- order-insensitivity is kept (that is what the case 116
    EXEMPTIONS entry legitimately argues for), but the path itself is
    no longer discarded.

    E7 integration fix, 2026-08-23: this comparator never checked
    whether `got` was properly terminated -- docs/E2E.md sec 9.6's own
    named lesson, reproduced here by the selftest's mutation battery: a
    'truncate one byte' mutant that only drops the final $8D leaves
    every NAME's own bytes untouched, so the multiset compares equal
    even though the real output was truncated.
    """
    from collections import Counter

    if got and not got.endswith(b'\n'):
        return False, f'output does not end with a line terminator: {got[-16:]!r}'

    def paths(data):
        return Counter(ln for ln in _lines(data) if ln)

    # THE MLI_PTH_MAXLN FENCE (2026-08-24). find prints a path it
    # built in PATHBUF, so it reports -- and cannot print -- exactly
    # those entries whose path AS SPELLED overflows MLI_PTH_MAXLN.
    # "As spelled" is the whole point, and is why this is derived from
    # the reference's own lines rather than from absolute paths: the
    # SAME file is reachable or not depending on the operand form.
    # /mnt/MAUX/RO/IDIOM/PROJECT/REPORTS/QUARTER/ARCHIVE2026/
    # FINALFILE.V2 is 67 characters and is diagnosed by case 118's
    # absolute `find`, while cases 102/106 reach and print it happily
    # as ./PROJECT/... (52) and ../PROJECT/... (53). Both behaviours
    # are correct and this rule predicts both; a fixed list of
    # "unreachable" paths could not.
    # See ENTRIES['*', 'MLI pathname parameter capped at
    # MLI_PTH_MAXLN (64)'].
    got_lines = [ln for ln in _lines(got) if ln]
    data_lines, diag_lines = _split_diags(got_lines, b'find: ')
    r = paths(ref)
    over = [ln for ln in r if len(ln) > MLI_PTH_MAXLN]
    bad = _check_diags(diag_lines, [p.decode('ascii') for p in over],
                       'find')
    if bad:
        return False, bad
    for p in over:
        del r[p]

    g = Counter(data_lines)
    if g == r:
        return True, ''
    missing = r - g
    extra_ = g - r
    return False, f'missing {dict(missing)}, extra {dict(extra_)}'


#: relative-to-/mnt/MAUX/RO paths making up each dot-idiom target this
#: module resolves -- used by cmp_du_total/synth to sum REAL blocks_used
#: off the `volume` snapshot rather than guessing. Keyed by the LAST
#: word of the case's typed argument, which is unique across every du/
#: find case this module adds (".", "./SUB", "..", "IDIOM", the two
#: absolute forms).
#: E7 integration, 2026-08-23: these were originally written as paths
#: relative to /mnt/MAUX/RO ('IDIOM', 'IDIOM/A', ...) -- but the spine's
#: actual VolumeSnapshot (e2e_fsmap.snapshot_volume) keys every entry
#: by its FULL absolute image path ('/mnt/MAUX/RO/IDIOM/A', ...), which is
#: also what volume.entry()'s single-snapshot convenience method looks
#: up directly. Reconciled to absolute paths -- same five fixtures,
#: same members, just the keys volume.entry() actually understands.
_IDIOM_MEMBERS = [IDIOM_PATH, f'{IDIOM_PATH}/A', f'{IDIOM_PATH}/B',
                  SUB_PATH, f'{SUB_PATH}/C']
_SUB_MEMBERS = [SUB_PATH, f'{SUB_PATH}/C']
_TARGET_MEMBERS = {
    '.': _IDIOM_MEMBERS,
    '..': _SUB_MEMBERS,           # `find ..`/`ls ..` run from within SUB
    'IDIOM': _IDIOM_MEMBERS,
    IDIOM_PATH: _IDIOM_MEMBERS,
}


def _target_key(case):
    tok = case.argv[-1] if case.argv else (case.sh_words[-1] if case.sh_words else '.')
    return tok


#: MLI_PTH_MAXLN (inc/mli.equ) -- the same 64 LONGPATH above is
#: deliberately built to overshoot by three.
MLI_PTH_MAXLN = 64


def _members_below(volume, top):
    """Every path at or under `top` that a maux walk can actually
    REACH, `top` itself first, in the volume's own directory order.

    ADDED 2026-08-24, replacing the hand-written _TARGET_MEMBERS lists
    for everything below the target itself. Those lists named five
    paths (IDIOM, A, B, SUB, SUB/C) and were written before the
    PROJECT/REPORTS/QUARTER/ARCHIVE2026 chain was staged under
    IDIOM to carry LONGPATH -- so `du`/`find` correctly walked four
    directories the expectation had never heard of, and every idiom
    case over IDIOM was being measured against a model that short.
    Deriving from the volume is what e2e_fs_walk.py already does
    (_vol_dfs_paths) and cannot go stale the next time a fixture grows.

    THE FENCE. A child whose absolute path exceeds MLI_PTH_MAXLN is
    not a member: maux cannot pass it to an MLI call at all, so it
    reports the path and moves on. Those are asserted separately, by
    _over_cap_below + _check_diags -- see ENTRIES['*', 'MLI pathname
    parameter capped at MLI_PTH_MAXLN (64)']."""
    out = [top]

    def walk(d):
        for ent in volume.readdir(d):
            p = d.rstrip('/') + '/' + ent.name
            if len(p) > MLI_PTH_MAXLN:
                continue
            out.append(p)
            if volume.entry(p)['is_dir']:
                walk(p)

    walk(top)
    return out


def _over_cap_below(volume, top):
    """The paths at or under `top` OVER the MLI_PTH_MAXLN fence --
    exactly the ones _members_below drops, and exactly the ones du.s
    and find.s must each emit one diagnostic line for."""
    out = []

    def walk(d):
        for ent in volume.readdir(d):
            p = d.rstrip('/') + '/' + ent.name
            if len(p) > MLI_PTH_MAXLN:
                out.append(p)
                continue
            if volume.entry(p)['is_dir']:
                walk(p)

    walk(top)
    return out


def _split_diags(lines, prefix):
    """Partition output lines into (data, diagnostics) by a tool-name
    prefix. Safe because every path these tools print starts with '/'
    or '.', never with 'du: ' or 'find: ' -- the same argument and the
    same mechanism as e2e_fs_walk.py's _classify_lines, which this
    module should have adopted at the same time and did not."""
    data, diag = [], []
    for ln in lines:
        (diag if ln.startswith(prefix) else data).append(ln)
    return data, diag


def _check_diags(diag_lines, want_paths, tool):
    """Assert the diagnostic lines: one per over-cap path, each NAMING
    its own path, and nothing else. Returns None if satisfied.

    Wording is deliberately not pinned -- ENTRIES['find', 'error
    diagnostic wording'] is EXCLUDED for exactly this reason, and the
    two spellings maux emits here differ by FORM anyway: 'pathname too
    long' for an absolute operand (MKPATH's own length check fires
    first) versus 'cannot access' for the cwd-relative one (the
    shorter text passes MKPATH and the MLI call itself refuses). What
    IS pinned is that the tool reported the right NUMBER of
    unreachable paths and named each one -- a diagnostic naming the
    wrong file, and a walk that silently skipped an over-cap entry,
    both fail here."""
    if len(diag_lines) != len(want_paths):
        return (f'{tool}: expected {len(want_paths)} diagnostic line(s), '
                f'one per path over MLI_PTH_MAXLN, got '
                f'{len(diag_lines)}: {diag_lines!r}')
    for want in want_paths:
        hit = [ln for ln in diag_lines if want.encode('ascii') in ln]
        if len(hit) != 1:
            return (f'{tool}: expected exactly one diagnostic naming '
                    f'{want!r}, got {len(hit)}: {diag_lines!r}')
    return None


def _blocks_for(volume, members):
    return sum(volume.entry(m)['blocks_used'] for m in members)


def _du_children(members):
    """Direct-child map among `members` -- members[0] is always this
    target's own top/argument path (see _IDIOM_MEMBERS/_SUB_MEMBERS'
    own construction: the target itself is always element 0)."""
    top = members[0]
    mset = set(members)
    kids = {}
    for m in members:
        if m == top:
            continue
        parent = m.rsplit('/', 1)[0]
        if parent in mset:
            kids.setdefault(parent, []).append(m)
    return kids


def _du_rollup(volume, members):
    """{path: rolled-up blocks_used} for every DIRECTORY among
    `members` (members[0], the target itself, always included) --
    a directory's own blocks_used plus every child's (recursively for
    child directories), the same rollup rule du.s's own header
    documents ("A subdirectory's own total SEEDS at its own
    blocks_used ... then accumulates every child")."""
    top = members[0]
    kids = _du_children(members)
    totals = {}

    def total_of(m):
        if m in totals:
            return totals[m]
        t = volume.entry(m)['blocks_used']
        for c in kids.get(m, []):
            t += total_of(c) if volume.entry(c)['is_dir'] \
                else volume.entry(c)['blocks_used']
        totals[m] = t
        return t

    total_of(top)
    return totals


def _du_lines(volume, prefix, members, s_flag):
    """The exact line-by-line text du.s prints for `prefix <target>`
    (or `prefix -s <target>`), derived from `members` alone -- PRLINE's
    own format is "<blocks><TAB><path>" for EVERY line, subdirectory
    rollups included, with the argument's own grand total always last
    (du.s's header, both properties). A subdirectory's printed path is
    `prefix` with the target's own absolute path replaced by the
    literal argv text -- exactly what du.s's PATHBUF-based
    BUILDCHILD does (it appends '/childname' to whatever text the
    argument itself was, never to a canonicalised absolute path)."""
    top = members[0]
    totals = _du_rollup(volume, members)

    def disp(m):
        return prefix + m[len(top):]

    lines = []
    if not s_flag:
        # POST-ORDER, deepest first (2026-08-24). du.s can only print a
        # directory's rollup once it has finished summing that
        # directory's children, so the rows come out children-before-
        # parent over the volume's own readdir order -- not the
        # pre-order `members` happens to be in. The two agree on the
        # SET, which is why a multiset comparison never noticed; see
        # cmp_du_total's own note on why order is asserted now.
        kids = _du_children(members)

        def postorder(d):
            for c in kids.get(d, []):
                if volume.entry(c)['is_dir']:
                    postorder(c)
                    lines.append(f'{totals[c]}\t{disp(c)}')

        postorder(top)
    lines.append(f'{totals[top]}\t{disp(top)}')   # grand total, ALWAYS last
    return lines


def cmp_du_total(case, got, ref, volume, hostdir):
    """Compare the WHOLE output -- every line, not just the grand total
    on the last one.

    FINDING 2 fix, 2026-08-23 (adversarial review): the old version did
    `last = lines[-1]` and parsed only that -- for case 115 (`du -s`,
    single line expected) AND case 117 (`du`, no -s, whose per-
    directory lines ARE its entire product), a wrong answer with junk
    lines prepended before a coincidentally-correct total
    (`b'999 junk\\n-1 more junk\\n5\\n'`) passed GREEN. du.s's own header:
    every line -- per-directory rollup or the final grand total -- has
    the same PRLINE format "<blocks><TAB><path>", and the grand total
    always prints LAST. Per-directory line ORDER is not re-checked here
    (order-insensitive multiset) -- exact directory-visit order is
    e2e_fs_walk.py/E3's own VOL-oracled domain (cmp_du_walk), the same
    division of labour cmp_name_multiset's own EXEMPTIONS entry argues
    for `find`; what this comparator owns is that EVERY line's block
    count (and path) is asserted, not just the last one.

    The expected block counts come from the REAL, volume-read
    `blocks_used`/`is_dir` fields for this target's known members
    (oracle='VOL', CONTRACT sec 2b's own du precedent) -- never a
    number read back from maux, never host `du` (whose 1024-byte block
    unit maux does not share; `ref`/`hostdir` are unused here on
    purpose).

    Checks the terminator SEPARATELY from the parsed fields -- stage 1's
    own lesson (docs/E2E.md sec 9.6): "3 3 14" and "3 3 14\\n" tokenise
    identically, so a maux that dropped its trailing $8D would pass a
    comparator that only ever looks at parsed fields. du.s always
    terminates its last line, so a `got` that does not end in the line
    terminator is rejected before any field is even parsed.
    """
    if not got or got[-1:] != b'\n':
        return False, f'output is not newline-terminated: {got[-8:]!r}'
    lines = _lines(got)
    if not lines:
        return False, 'no output at all'

    # Diagnostics are not data rows. Split them off BEFORE parsing --
    # they carry no TAB, so the row parser below used to reject the
    # whole output on the first one and never reach the real
    # comparison (2026-08-24).
    prefix = _target_key(case)
    top = _TARGET_MEMBERS.get(prefix, _IDIOM_MEMBERS)[0]
    data_lines, diag_lines = _split_diags(lines, b'du: ')
    over = [prefix + p[len(top):] for p in _over_cap_below(volume, top)]
    bad = _check_diags(diag_lines, over, 'du')
    if bad:
        return False, bad

    got_rows = []
    for ln in data_lines:
        if b'\t' not in ln:
            return False, f'line missing a TAB separator: {ln!r}'
        blk, path = ln.split(b'\t', 1)
        try:
            got_rows.append((int(blk), path))
        except ValueError:
            return False, f'unparseable block count in {ln!r}'

    members = _members_below(volume, top)
    s_flag = any(a == '-s' for a in case.argv)
    want_lines_str = _du_lines(volume, prefix, members, s_flag)
    want_rows = []
    for wl in want_lines_str:
        wblk, wpath = wl.split('\t', 1)
        want_rows.append((int(wblk), wpath.encode()))

    if s_flag:
        if got_rows != want_rows:
            return False, f'want {want_rows} (single -s line), got {got_rows}'
        return True, ''

    # Non -s: every row checked EXACTLY and POSITIONALLY, grand total
    # included (du.s's own "prints last, ALWAYS").
    #
    # ORDER IS CHECKED HERE NOW (2026-08-24). This used to compare the
    # per-directory rows as an order-insensitive multiset, arguing that
    # visit order was e2e_fs_walk.py/E3's domain -- but E3's du cases
    # walk the WALK fixture, not this one, so nothing was checking the
    # order of these. The argument was also self-fulfilling: with the
    # stale member model these cases produced only two rows (SUB and
    # the total), too few for the selftest to even generate a 'reorder
    # two lines' mutant. Deriving members from the volume gave them six
    # rows, the mutant appeared, and the comparator accepted it --
    # which is how this got noticed at all.
    #
    # The expected order is not guesswork: du.s prints a directory's
    # rollup only once its children are done, so the rows come out in
    # POST-ORDER over the volume's own readdir order, deepest first,
    # with the argument itself last. That is exactly what maux emits
    # (ARCHIVE2026, QUARTER, REPORTS, PROJECT, SUB, IDIOM) and what
    # _du_lines now builds.
    if got_rows != want_rows:
        if got_rows[-1] != want_rows[-1]:
            return False, (f'grand total (must be the LAST line) is '
                           f'{got_rows[-1]} vs expected {want_rows[-1]}')
        for i, (g_, w_) in enumerate(zip(got_rows, want_rows)):
            if g_ != w_:
                return False, (f'row {i} differs: got {g_}, expected '
                               f'{w_} (rows are post-order, deepest '
                               f'first)\n  got  {got_rows}\n  want '
                               f'{want_rows}')
        return False, (f'row count differs: got {len(got_rows)}, '
                       f'expected {len(want_rows)}\n  got  {got_rows}'
                       f'\n  want {want_rows}')
    return True, ''


def cmp_invariant_resolved(case, got, ref, volume, hostdir):
    if not got:
        return False, 'no output at all -- word did not resolve to anything'
    # E8, 2026-08-23: docs/E2E.md sec 9.6's own named lesson, applied
    # here too (this file's own cmp_name_multiset and e2e_invariants.
    # py's _parse_ps already do this) -- non-emptiness alone cannot
    # tell real output from output whose trailing $8D was silently
    # dropped. This is still a SHAPE check, not the functional-content
    # check this comparator's own docstring explicitly disclaims owning.
    if not got.endswith(b'\n'):
        return False, (f'output does not end with a line terminator: '
                       f'{got[-16:]!r}')
    first_line = _lines(got)[0] if _lines(got) else got
    if first_line.startswith(b'sh: command not found'):
        return False, 'sh itself reported "command not found"'
    return True, ''


#: TXT-type description exactly per file.s's own documented table
#: (header comment, "$04 TXT -> ascii text").
_FILE_TYPE_DESC = {0x04: b'ascii text', 0x06: b'binary'}


def cmp_file_desc(case, got, ref, volume, hostdir):
    """VOL-oracled: the expected description comes from file.s's own
    documented type table applied to the REAL storage_type/type this
    module staged (volume.entry()), never from host `file` (which
    prints an unrelated MIME-style description for the same bytes).
    volume.entry() is keyed by the FULL absolute image path (E7
    integration, 2026-08-23) -- case.argv[-1] already IS that path, no
    /mnt/MAUX/RO/ prefix strip needed."""
    path = case.argv[-1]
    ent = volume.entry(path)
    desc = _FILE_TYPE_DESC.get(ent['type'], f"unknown type ${ent['type']:02X}".encode())
    want = path.encode() + b': ' + desc + b'\n'
    return cmp_exact(case, got, want, volume, hostdir)


def _pwd_expected(case):
    """B4, 2026-08-23 (case 120's own bug): the correct answer for a
    `CD X ; pwd` case, derived from case.sh_words's OWN cd target --
    never from ref_out, which is unconditionally empty for oracle='VOL'
    (Case.reference()'s contract: no host `pwd` exists to run). docs/
    CD.md ruling 3: GET_PREFIX's answer always carries a trailing slash,
    so the expected text is the cd target, slash-terminated, one line."""
    words = case.sh_words
    cd_idx = next(i for i, w in enumerate(words) if w.upper() == 'CD')
    target = words[cd_idx + 1]
    if not target.endswith('/'):
        target += '/'
    return target.encode() + b'\n'


def cmp_pwd_prefix(case, got, ref, volume, hostdir):
    """VOL-oracled, like cmp_file_desc/cmp_du_total above -- `ref` (== an
    always-empty case.reference() result) plays NO part; the expectation
    comes entirely from _pwd_expected(case)."""
    return cmp_exact(case, got, _pwd_expected(case), volume, hostdir)


#: cat.s's own OPEN-failure message (cat.s:254, ERRMSG, printed at
#: :openerr with the operand's own text appended, NO colon separator --
#: see cat.s:121-145). NOT parameterised the way ls's ERRPFX/
#: ERRSUF_ACCESS is (a prefix AND suffix around the path); cat's is a
#: single prefix string with the path appended directly.
def cmp_cat_mkpath_refused(case, got, ref, volume, hostdir):
    """LONGPATH case -- the MKPATH silent-truncation defect's
    retirement, reclassified as a DIVERGENCE (TL ruling, 2026-08-23;
    ENTRIES['*', 'MLI pathname parameter capped at MLI_PTH_MAXLN
    (64)']). MKPATH's now-corrupted, unmatchable pathname makes cat's
    own OPEN fail (cat.s:108-121), taking the SAME open-failure path as
    any nonexistent-file case -- so the expected text is maux's own
    documented message (cat.s:254's ERRMSG) for the FULL, untruncated
    operand exactly as typed. Checked POSITIVELY (TL ruling): FINALFILE
    -- the real, shorter, stale file the truncated pathname used to
    coincidentally match -- must never leak its content into the
    output; 'an error happened' alone would not distinguish a clean
    refusal from the old defect reproducing with a mangled message."""
    path = case.argv[-1]
    want = f'cat: cannot open {path}\n'.encode('ascii')
    if got != want:
        n = min(len(got), len(want))
        for i in range(n):
            if got[i] != want[i]:
                return False, (f'first difference at byte {i}: got '
                               f'{got[max(0,i-20):i+20]!r} vs want '
                               f'{want[max(0,i-20):i+20]!r}')
        return False, (f'identical for {n} bytes then length differs: '
                       f'got {len(got)} B, want {len(want)} B')
    if b'stale Q3 draft' in got:
        return False, ("FINALFILE's own stale content ('stale Q3 "
                       "draft -- superseded') appears in the output -- "
                       "the old MKPATH-truncation defect has "
                       "reproduced")
    return True, ''


def cmp_poststate_tree(case, pre, post, expect_relpaths, hostdir):
    """Shared tree-mutation checker for the five mutating-tool cases
    below (mkdir/rm/mv/cp/chmod), called directly by this module's own
    local proof harness rather than through COMPARATORS (poststate is a
    SECOND, independent assertion per CONTRACT sec 5.2, not the stdout
    comparator). `pre`/`post` are volume snapshots (see module note
    above); `expect_relpaths` is {relpath: True|False} for existence,
    plus an optional access-byte/content check the caller supplies via
    `case._expect_access`/`case._expect_content` when present."""
    problems = []
    for rp, should_exist in expect_relpaths.items():
        exists = post.exists(rp)
        if exists != should_exist:
            problems.append(f'{rp}: exists={exists}, expected {should_exist}')
    expect_access = getattr(case, '_expect_access', None)
    if expect_access is not None:
        rp, want_access = expect_access
        got_access = post.entry(rp)['access']
        if got_access != want_access:
            problems.append(f'{rp}: access ${got_access:02X}, '
                            f'expected ${want_access:02X}')
    expect_content = getattr(case, '_expect_content', None)
    if expect_content is not None:
        rp, want_bytes = expect_content
        got_bytes = post.entry(rp).get('content')
        if got_bytes != want_bytes:
            problems.append(f'{rp}: content {got_bytes!r}, '
                            f'expected {want_bytes!r}')
    if problems:
        return False, '; '.join(problems)
    return True, ''


def _immediate_children(prefix):
    """The immediate child basenames of `prefix` (an RO_DIRS/RO_FILES-
    relative directory path, no leading/trailing slash) -- derived
    purely from THIS module's own fixture tables above, never from a
    volume read and never from maux's output. cmp_ls_dir_refused (below)
    uses this for the STRUCTURAL fact a successful `ls <dir>` would
    print: not the directory's own name (that's cmp_ls_refused's own
    operand check, e2e_fs_ls.py), but its CHILDREN's."""
    want_len = len(prefix.split('/')) + 1
    names = set()
    for relpath in list(RO_DIRS) + list(RO_FILES):
        if not relpath.startswith(prefix + '/'):
            continue
        if len(relpath.split('/')) == want_len:
            names.add(relpath.rsplit('/', 1)[-1])
    return names


def cmp_ls_dir_refused(case, got, ref, volume, hostdir):
    """T4 review fix, 2026-08-23 (docs/E2E.md sec 4/10.9 B4) -- the
    `-la` case's replacement for a `c.reference = lambda ...` override
    that hand-authored maux's own bytes. Same approach as e2e_fs_ls.py's
    cmp_ls_refused (ENTRIES['ls', 'usage-error refusal: wording and exit
    status not differential'], EXCLUDED: diagnostic wording and exit-
    code spelling are not differential, docs/E2E.md sec 9.7), reused
    directly for the base check, but STRENGTHENED for a DIRECTORY
    operand: cmp_ls_refused's own operand-name check is sufficient for a
    FILE operand (a successful `ls FILE` can only ever print FILE's own
    name), but a successful `ls DIR` prints DIR's CHILDREN, not DIR's
    own name -- so this also asserts none of IDIOM_PATH's real children
    (_immediate_children, above -- fixture data, not a volume read or
    maux's output) appear as a listed line. `ref` (the live host `ls
    -la` result -- a REAL, RECOGNISED pair of flags to BSD ls, an
    unrelated full permission listing) is unused on purpose, same as
    cmp_ls_refused itself."""
    ok, detail = LS.cmp_ls_refused(case, got, ref, volume, hostdir)
    if not ok:
        return ok, detail
    lines = {ln for ln in got.split(b'\n') if ln}
    children = {c.encode('ascii') for c in _immediate_children('IDIOM')}
    leaked = lines & children
    if leaked:
        return False, (
            f"maux printed {sorted(leaked)!r} as (a) listed "
            f"director{'y' if len(leaked) == 1 else 'ies/files'} entr"
            f"{'y' if len(leaked) == 1 else 'ies'} -- IDIOM's real "
            f"directory contents appear in the output, so the command "
            f"was not refused (a listing was produced, which is "
            f"exactly the OLD bug's shape: a dash-prefixed word past "
            f"argv[1] silently accepted instead of hitting the usage "
            f"check)")
    return True, ''


COMPARATORS = {
    # 'exact' is NOT registered here: e2e_fs_common.Registry seeds it
    # with a byte-identical implementation. Two modules claiming it
    # is a merge error by CONTRACT sec 5.1, and the local cmp_exact
    # below is kept only because this module calls it directly.
    # 'ls_refused' is NOT registered here either: it is e2e_fs_ls.py's
    # own key, reused as-is (compare='ls_refused') by this module's
    # `NOSUCH -l` case above -- claiming it a second time here would be
    # the same COMPARATORS merge error CONTRACT sec 5.1 forbids for
    # 'exact'.
    'ls_dir_refused': cmp_ls_dir_refused,
    'name_multiset': cmp_name_multiset,
    'du_total': cmp_du_total,
    'invariant_resolved': cmp_invariant_resolved,
    'idiom_file_desc': cmp_file_desc,
    'pwd_prefix': cmp_pwd_prefix,
    'cat_mkpath_refused': cmp_cat_mkpath_refused,
}


# ----------------------------------------------------------------------
# Cases.
# ----------------------------------------------------------------------
def cases(add):
    # === Group CD: builtin case-sensitivity -- THE flagship defect ===
    add('cd', case_id='idiom.cd-upper',
        sh_words=['CD', IDIOM_PATH, ';', '/bin/CAT', 'A'],
        argv=[IDIOM_PATH], oracle='REF', compare='exact',
        cwd='restore',
        note='sanity: UPPERCASE CD, composed with a relative read that '
             'proves the prefix really moved (docs/CD.md gate-coverage '
             'discipline: not just what pwd would echo)')

    c = add('cd', case_id='idiom.cd-lower',
        sh_words=['cd', IDIOM_PATH, ';', '/bin/CAT', 'A'],
        argv=[IDIOM_PATH], oracle='REF', compare='exact',
        cwd='restore',
        note='lowercase `cd` -- STRCMP is case-sensitive, this is not '
             'recognised as the builtin at all')

    c = add('cd', case_id='idiom.cd-mixed',
        sh_words=['Cd', IDIOM_PATH, ';', '/bin/CAT', 'A'],
        argv=[IDIOM_PATH], oracle='REF', compare='exact',
        cwd='restore',
        note='mixed-case `Cd` -- same STRCMP defect, different byte')

    # === Group DOT: the idiom, gated by a WALK not a probe ===
    # learning:01M0PBKZKZE55J4NE93TYNJCPC's own conclusion: never gate
    # `.` with test -d/-e (ProDOS's GET_FILE_INFO resolves a bare '.'
    # on its own, which would pass vacuously). Every case below opens
    # or walks a directory, or reads a file through one.
    c = add('ls', case_id='idiom.ls-dot',
        sh_words=['CD', IDIOM_PATH, ';', '/bin/LS', '.'],
        argv=['.'], oracle='REF', compare='exact', cwd='restore',
        note='`ls .` from within IDIOM -- a WALK (OPENDIR/READDIR via '
             'src/liba/readdir.s), not a probe; GET_FILE_INFO would '
             'have answered "." just fine, which is exactly the trap '
             'the cited learning documents')

    c = add('ls', case_id='idiom.ls-dot-sub',
        sh_words=['CD', IDIOM_PATH, ';', '/bin/LS', './SUB'],
        argv=['./SUB'], oracle='REF', compare='exact', cwd='restore',
        note='`ls ./SUB` -- a dot-prefixed relative path with a further '
             'component, the exact shape 319aecb\'s commit message '
             'names ("ls ./sed... fail identically")')

    c = add('find', case_id='idiom.find-dot',
        sh_words=['CD', IDIOM_PATH, ';', '/bin/FIND', '.'],
        argv=['.'], oracle='REF', compare='name_multiset', cwd='restore',
        note='`find .` -- the operator\'s OWN bug report (319aecb): '
             '"find: .: cannot access", exit 1')

    add('du', case_id='idiom.du-dot',
        sh_words=['CD', IDIOM_PATH, ';', '/bin/DU', '.'],
        argv=['.'], oracle='VOL', compare='du_total', cwd='restore',
        diverges=[('du', 'stdout/stderr interleave order not checked'),
                  ('*', 'MLI pathname parameter capped at '
                        'MLI_PTH_MAXLN (64)')],
        note='`du .` -- same MKPATH choke point, third consumer of '
             'readdir.s; its walk also meets LONGPATH, which no du '
             'form can stat (the ABSOLUTE path is 67), so one '
             'diagnostic line is expected here even though the '
             'RELATIVE spelling `find .` prints happily')

    c = add('cat', case_id='idiom.cat-dot-a',
        sh_words=['CD', IDIOM_PATH, ';', '/bin/CAT', './A'],
        argv=['./A'], oracle='REF', compare='exact', cwd='restore',
        note='`cat ./A` -- 319aecb\'s "cat . ... fail identically", '
             'with a further component the way `ls ./sed` had one')

    c = add('ls', case_id='idiom.ls-dotdot',
        sh_words=['CD', SUB_PATH, ';', '/bin/LS', '..'],
        argv=['..'], oracle='REF', compare='exact', cwd='restore',
        note='`ls ..` from within SUB -- a literal ".." typed as an '
             'ARGUMENT (not via cd), which PRC_DOTDOT never sees: that '
             'special case lives inside CHCK_BLTN_CD/PRC_SETPFX only')

    c = add('find', case_id='idiom.find-dotdot',
        sh_words=['CD', SUB_PATH, ';', '/bin/FIND', '..'],
        argv=['..'], oracle='REF', compare='name_multiset', cwd='restore',
        note='`find ..` from within SUB -- recursive walk starting from '
             'a literal ".." argument')

    # === Group SEAM: cd .. (kernel special case) vs ".." typed as a
    # plain argument -- the composed case docs/CD.md's own "Scope
    # cost, explicit" section predicts will diverge. ===
    c = add('cd', case_id='idiom.cd-dotdot',
        sh_words=['CD', SUB_PATH, ';', 'CD', '..', ';', '/bin/CAT', 'A'],
        argv=[IDIOM_PATH], oracle='REF', compare='exact', cwd='restore',
        note='`cd ..` (kernel PRC_DOTDOT, real GET_PREFIX/SET_PREFIX) '
             'composed with a RELATIVE read proving the prefix really '
             'is back at IDIOM -- not just what pwd would echo, the '
             'same discipline docs/CD.md\'s own gate-coverage section '
             'uses. This is NOT pinned: ruling 2 in docs/CD.md says '
             'this exact path is shipped and works.')

    c = add('cat', case_id='idiom.cat-dotdot-a',
        sh_words=['CD', SUB_PATH, ';', '/bin/CAT', '../A'],
        argv=['../A'], oracle='REF', compare='exact', cwd='restore',
        note='the seam itself: `cd ..` (above) works, but typing ".." '
             'directly as an operand to a non-cd command does not -- '
             'docs/CD.md\'s own words, "a plain cat ../x does not '
             'resolve". Only a COMPOSED case (this one, next to the '
             'one above) shows the difference; either alone looks like '
             'a coincidence.')

    # === Group RELATIVE-NO-DOT and PATH-after-cd (TL request,
    # 2026-08-23: both directions, same target so the pair is clean) ===
    add('ls', case_id='idiom.ls-absolute',
        sh_words=['LS', IDIOM_PATH],
        argv=[IDIOM_PATH], oracle='REF', compare='exact',
        note='bare UPPERCASE tool word, absolute operand -- baseline '
             'for the PATH-resolution mechanism BUILD_PATH uses '
             '(sh.s:6746-6812), and the first half of the SH_PATHFULL '
             'defect pair below: this resolves "LS" to "/bin/LS" and '
             'is what the very next case inherits')

    add('cat', case_id='idiom.cat-absolute-command',
        sh_words=['/bin/CAT', IDIOM_PATH + '/A'],
        argv=[IDIOM_PATH + '/A'], oracle='REF', compare='exact',
        # FIXED 2026-08-23 (sh.s commit in b7089df's merge):
        # RSLV_PTH_STG's :absolute branch now writes SH_PATHFULL
        # before returning, so the spawn site's unconditional reload
        # (sh.s:6207-6213) picks up THIS case's own resolved path
        # instead of whatever the previous bare-word case left behind.
        # No pin needed: this is now an ordinary REF/exact case --
        # maux runs CAT (not the previous case's LS) against this
        # file's own argv, and the assertion is real, ordinary stdout
        # content ("first\n"), not a shape check.
        note='ABSOLUTE command word, placed immediately after the bare '
             '"LS" case above in this module\'s own case order -- '
             'exactly the shape that used to trigger the stale-'
             'SH_PATHFULL bug; now an ordinary content check')

    add('ls', case_id='idiom.ls-after-cd',
        sh_words=['CD', IDIOM_PATH, ';', 'LS'],
        argv=[], oracle='REF', compare='exact', cwd='restore',
        note='TL request 2026-08-23: bare `LS` (no operand, no dot) '
             'after `cd` into IDIOM. PREDICTED TO PASS, contradicting '
             'the established fact this package was briefed with -- '
             'see this module\'s final report for the full citation '
             '(PATHTAB has TWO absolute entries, sh.s:6859-6864, and '
             'this volume\'s binaries live directly under /mnt/MAUX/ per '
             'CONTRACT sec 3.1, which is exactly the shape the second '
             'entry\'s own comment names as its reason to exist)')

    add('ls', case_id='idiom.ls-abs-after-cd',
        sh_words=['CD', IDIOM_PATH, ';', '/bin/LS'],
        argv=[], oracle='REF', compare='exact', cwd='restore',
        note='TL request 2026-08-23: the paired "working form", '
             'absolute `/bin/LS` after the same `cd`. PREDICTED TO '
             'PASS for the same reason as the bare form above -- if '
             'both predictions hold, the pair is NOT a contrast in '
             'this specific volume, and that is itself the finding')

    # === Group TRAILING SLASH ===
    add('ls', case_id='idiom.ls-trailing-slash',
        sh_words=['LS', IDIOM_PATH + '/'],
        argv=[IDIOM_PATH + '/'], oracle='REF', compare='exact',
        note='trailing slash on a bare absolute operand -- '
             'docs/CD.md ruling 3: ProDOS accepts it, GET_PREFIX '
             'always answers with one anyway')

    add('cd', case_id='idiom.cd-trailing-slash',
        sh_words=['CD', IDIOM_PATH + '/', ';', '/bin/CAT', 'A'],
        argv=[IDIOM_PATH + '/'], oracle='REF', compare='exact',
        cwd='restore',
        note='trailing slash on a `cd` target, composed with a '
             'relative read proving it actually moved')

    # === Group FLAG SPELLINGS a human uses ===
    #
    # T4 review fix, 2026-08-23 (docs/E2E.md sec 4/10.9 B4): both cases
    # in this group used to override Case.reference() with a lambda
    # returning HARDCODED BYTES equal to maux's own documented output --
    # an authored expectation wearing the reference's clothes, the exact
    # anti-pattern sec 4 forbids (a suite whose expectation came from
    # maux is a change detector, and hand-typing the identical bytes is
    # the same mistake written out longhand). Replaced with the honest
    # structure e2e_fs_ls.py's cmp_ls_refused/cmp_ls_dir_refused (below)
    # already use for exactly this shape (ls.py's own C10 case): assert
    # the STRUCTURAL fact both sides genuinely share -- the command is
    # REFUSED, nothing is listed -- and carry the wording/exit-code
    # difference as an EXCLUDED divergence (diagnostic text is not
    # differential, docs/E2E.md sec 9.7) rather than an authored byte
    # string. `oracle='REF'` is kept and case.reference() now runs the
    # REAL host `ls`, exactly like ls.py's own C10 -- its result is
    # unused by the structural comparator (both comparators' own
    # docstrings say so), which is fine: what matters is that no case
    # here manufactures an expectation out of maux's own bytes any more.
    c = add('ls', case_id='idiom.ls-clustered-flag',
        sh_words=['LS', '-la', IDIOM_PATH],
        argv=['-la', IDIOM_PATH], oracle='REF', compare='ls_dir_refused',
        diverges=[('ls', 'a flag must be the sole first argument'),
                  ('ls', 'usage-error refusal: wording and exit status '
                         'not differential')],
        status_ruled=('ls', 'usage-error refusal: wording and exit '
                            'status not differential'),
        note='clustered `-la`: ls has no -a at all and no clustering '
             '(only a bare, exact "-l" is ever recognised) -- ls.s\'s '
             'own pinned contract, not a bug (the RULED entry). '
             'cmp_ls_dir_refused checks only that the command is '
             'REFUSED: maux says something, and neither IDIOM_PATH '
             'itself nor any of its real children (A/B/SUB/PROJECT, '
             'read from this module\'s own RO_DIRS/RO_FILES, never '
             'from maux) is ever printed as a listed entry -- wording '
             'and the exit-code SPELLING (2 vs a real host ls -la\'s 0) '
             'are excluded, not asserted (the EXCLUDED entry)')

    c = add('ls', case_id='idiom.ls-trailing-flag',
        sh_words=['LS', 'NOSUCH', '-l'],
        argv=['NOSUCH', '-l'], oracle='REF', compare='ls_refused',
        diverges=[('ls', 'a flag must be the sole first argument'),
                  ('ls', 'usage-error refusal: wording and exit status '
                         'not differential')],
        status_ruled=('ls', 'usage-error refusal: wording and exit '
                            'status not differential'),
        note='a flag AFTER the operand: -l is only recognised as '
             'argv[1] exactly. FIXED 2026-08-23 (ls.s: ANY dash-'
             'prefixed word past argv[1] is now a usage error, -l '
             'included, same as the -x case ls.py\'s own C10 retires) '
             '-- this case used to assert the OLD two-"cannot access"-'
             'line shape as a hand-copied lambda, which is now simply '
             'WRONG (a usage error is what actually prints). Reuses '
             'e2e_fs_ls.cmp_ls_refused directly (imported as LS below): '
             'both operands are deliberately nonexistent (NOSUCH is not '
             'a real path; -l is excluded from the operand scan because '
             'it starts with "-"), so there is nothing a successful '
             'listing could ever print but NOSUCH\'s own name -- the '
             'same "operand never appears as a listed line" check as '
             'ls.py\'s C10, with no directory involved and so no need '
             'for the extra children check cmp_ls_dir_refused adds')

    add('du', case_id='idiom.du-separated-flag',
        sh_words=['DU', '-s', IDIOM_PATH],
        argv=['-s', IDIOM_PATH], oracle='VOL', compare='du_total',
        diverges=[('du', 'stdout/stderr interleave order not checked'),
                  ('*', 'MLI pathname parameter capped at '
                        'MLI_PTH_MAXLN (64)')],
        note='separated single flag before the operand -- the '
             'documented, supported form (src/liba/getopt.s), and a '
             'clean control against the two ls flag-spelling cases '
             'above: THIS tool\'s parser is a real getopt and handles '
             'it correctly')

    # === Group CASE SWEEP: every fs-tranche tool, typed lowercase.
    # Not testing each tool's full semantics (that is E2-E5's job) --
    # only whether the bare WORD resolves at all, via ProDOS's own
    # pathname upcasing (confirmed [fact] against the ProDOS 8 TRM,
    # street-library artifact d82965d8...f5cc3a1, chunk 55: "Lowercase
    # letters are automatically converted to uppercase"). ===
    add('find', case_id='idiom.find-lower',
        sh_words=['find', IDIOM_PATH],
        argv=[IDIOM_PATH], oracle='REF', compare='name_multiset',
        diverges=[('find', 'stdout/stderr interleave order not checked'),
                  ('*', 'MLI pathname parameter capped at '
                        'MLI_PTH_MAXLN (64)')],
        status_ruled=('*', 'MLI pathname parameter capped at '
                           'MLI_PTH_MAXLN (64)'),
        note='lowercase `find`')

    add('du', case_id='idiom.du-lower',
        sh_words=['du', IDIOM_PATH],
        argv=[IDIOM_PATH], oracle='VOL', compare='du_total',
        diverges=[('du', 'stdout/stderr interleave order not checked'),
                  ('*', 'MLI pathname parameter capped at '
                        'MLI_PTH_MAXLN (64)')],
        note='lowercase `du`')

    add('cat', case_id='idiom.cat-lower',
        sh_words=['cat', IDIOM_PATH + '/B'],
        argv=[IDIOM_PATH + '/B'], oracle='REF', compare='exact',
        note='lowercase `cat`')

    add('file', case_id='idiom.file-lower',
        sh_words=['file', IDIOM_PATH + '/A'],
        argv=[IDIOM_PATH + '/A'], oracle='VOL', compare='idiom_file_desc',
        note='lowercase `file` -- oracle is VOL, not REF: host `file` '
             'prints an unrelated MIME-style description; the '
             'expectation is file.s\'s OWN documented type table '
             '(header comment, "$04 TXT -> ascii text") applied to '
             'this fixture\'s known ProDOS type, which is the volume\'s '
             'own ground truth for a file this module staged itself')

    add('pwd', case_id='idiom.pwd-lower',
        sh_words=['CD', IDIOM_PATH, ';', 'pwd'],
        argv=[], oracle='VOL', compare='pwd_prefix', cwd='restore',
        note='lowercase `pwd` after a known cd -- expectation is the '
             'prefix this case itself set, decoded per pwd.s\'s own '
             'contract (trailing slash always present). B4, 2026-08-23 '
             '(case 120\'s own bug): NOT compare=\'exact\' -- the spine\'s '
             'cmp_exact compares `got` against case.reference()\'s raw '
             'ref_out, which is UNCONDITIONALLY empty for oracle=\'VOL\' '
             '(no host pwd to run), so exact would silently require an '
             'EMPTY line regardless of what this case\'s own note says '
             'the expectation is. \'pwd_prefix\' derives its expectation '
             'from case.sh_words\'s own cd target instead, independent '
             'of ref_out, exactly like du_total/idiom_file_desc already '
             'do for their own VOL cases in this module')

    add('ps', case_id='idiom.ps-lower',
        sh_words=['ps'],
        argv=[], oracle='INVARIANT', compare='invariant_resolved',
        invariant=('*', 'idiom case word resolved to something other '
                        'than sh itself'),
        note='lowercase `ps` -- see INVARIANTS entry for why this is '
             'the narrow, honest thing to assert about it here')

    add('df', case_id='idiom.df-lower',
        sh_words=['df'],
        argv=[], oracle='INVARIANT', compare='invariant_resolved',
        invariant=('*', 'idiom case word resolved to something other '
                        'than sh itself'),
        note='lowercase `df`')

    add('ls', case_id='idiom.ls-mixed',
        sh_words=['Ls', IDIOM_PATH],
        argv=[IDIOM_PATH], oracle='REF', compare='exact',
        note='MIXED case `Ls` -- ProDOS upcasing does not care where '
             'the capital letter falls')

    # -- mutating tools: one lowercase-typed case each, own MUT_TREE,
    # poststate=True so the mutation itself is checked, not just that
    # something ran. ref_op mirrors the same mutation on the host tree.
    add('mkdir', case_id='idiom.mkdir-lower',
        sh_words=['mkdir', '/mnt/MAUX/MUT/CMKD/NEWDIR'],
        argv=['/mnt/MAUX/MUT/CMKD/NEWDIR'], oracle='VOL', compare='exact',
        tree='CMKD', poststate=True,
        ref_op=lambda hostdir: os.mkdir(os.path.join(hostdir, 'NEWDIR')),
        note='lowercase `mkdir`')

    add('rm', case_id='idiom.rm-lower',
        sh_words=['rm', '/mnt/MAUX/MUT/CRM/DOOMED'],
        argv=['/mnt/MAUX/MUT/CRM/DOOMED'], oracle='VOL', compare='exact',
        tree='CRM', poststate=True,
        ref_op=lambda hostdir: os.remove(os.path.join(hostdir, 'DOOMED')),
        note='lowercase `rm`')

    add('mv', case_id='idiom.mv-lower',
        sh_words=['mv', '/mnt/MAUX/MUT/CMV/OLDNAME', '/mnt/MAUX/MUT/CMV/NEWNAME'],
        argv=['/mnt/MAUX/MUT/CMV/OLDNAME', '/mnt/MAUX/MUT/CMV/NEWNAME'],
        oracle='VOL', compare='exact', tree='CMV', poststate=True,
        ref_op=lambda hostdir: os.rename(
            os.path.join(hostdir, 'OLDNAME'), os.path.join(hostdir, 'NEWNAME')),
        # E8, 2026-08-23: NEWNAME is a new post-mutation path -- see
        # e2e_fs_mutate.py's case 6 (same shape, same reasoning).
        expect_types={'NEWNAME': ('from', 'OLDNAME')},
        note='lowercase `mv`')

    add('cp', case_id='idiom.cp-lower',
        sh_words=['cp', '/mnt/MAUX/MUT/CCP/SRC', '/mnt/MAUX/MUT/CCP/DST'],
        argv=['/mnt/MAUX/MUT/CCP/SRC', '/mnt/MAUX/MUT/CCP/DST'],
        oracle='VOL', compare='exact', tree='CCP', poststate=True,
        ref_op=lambda hostdir: _host_copy(hostdir, 'SRC', 'DST'),
        # E8, 2026-08-23: DST is a new post-mutation path -- see
        # e2e_fs_mutate.py's cases 13/14 (same shape, same reasoning).
        expect_types={'DST': ('from', 'SRC')},
        note='lowercase `cp`')

    add('chmod', case_id='idiom.chmod-lower',
        sh_words=['chmod', '+d', '/mnt/MAUX/MUT/CCHM/LOCKME'],
        argv=['+d', '/mnt/MAUX/MUT/CCHM/LOCKME'],
        oracle='VOL', compare='exact', tree='CCHM', poststate=True,
        ref_op=lambda hostdir: None,  # access byte is a ProDOS-only
                                       # concept; poststate access-byte
                                       # check is against a literal
                                       # expected value, not a host
                                       # mutation
        note='lowercase `chmod` -- poststate is an access-byte check, '
             'which has no host filesystem equivalent, so ref_op is a '
             'no-op and the expected access byte is asserted directly '
             '(matches this module\'s VOL oracle: the volume\'s own '
             "post-mutation directory entry, not anything maux said)")

    # === Group LONG PATH: MKPATH's silent truncation -- FIXED
    # 2026-08-23 (src/liba/mli.s, branch t4-mkpath-fix commit f915af9,
    # merged onto this branch), reclassified as a DIVERGENCE, not
    # retired to nothing (TL ruling, 2026-08-23 -- see the ('*', 'MLI
    # pathname parameter capped at MLI_PTH_MAXLN (64)') RULED entry
    # above, this entry's single canonical home). A genuinely deep,
    # human-plausible nested path, not a synthetic long string. ===
    add('cat', case_id='idiom.cat-longpath',
        sh_words=['/bin/CAT', LONGPATH],
        argv=[LONGPATH], oracle='REF', compare='cat_mkpath_refused',
        diverges=[('*', 'MLI pathname parameter capped at MLI_PTH_MAXLN '
                        '(64)')],
        status_ruled=('*', 'MLI pathname parameter capped at '
                           'MLI_PTH_MAXLN (64)'),
        note='a real 67-character nested path (mkdir one level at a '
             'time is exactly how a person builds this) whose first 64 '
             'bytes are DELIBERATELY the complete path of a different, '
             'real, shorter file (FINALFILE, no .V2). MKPATH now sets '
             'carry and corrupts its own truncated output on overflow, '
             'so it can no longer coincidentally match FINALFILE -- cat '
             '(one of the 24 callers that never checked MKPATH\'s carry) '
             'now gets an ordinary OPEN failure instead. '
             'cmp_cat_mkpath_refused positively checks that FINALFILE\'s '
             'own stale content never leaks through, not just that some '
             'error happened')


def _host_copy(hostdir, src, dst):
    with open(os.path.join(hostdir, src), 'rb') as fh:
        data = fh.read()
    with open(os.path.join(hostdir, dst), 'wb') as fh:
        fh.write(data)


# ----------------------------------------------------------------------
# synth() -- what a CORRECT maux would have emitted. Never used by the
# real gate; only by the selftest, to have something correct to
# corrupt (CONTRACT sec 7 / this module's own __main__ block below,
# since scripts/e2e_fs_selftest.py -- E1's -- does not exist in this
# worktree either).
#
# B4, 2026-08-23 (T4 review finding -- see the fix's own report): this
# module used to carry a PER-MODULE _compound_reference/
# _compound_case_reference pair, wired onto individual cases via a
# `c.reference = lambda ...` override, to work around case.reference()
# (e2e_fs_common.py, the spine) having no notion of a compound
# `CD X ; <verb> <arg>` sh_words sequence. That override was wired to
# nine of this module's cases but MISSED five more with the identical
# shape (cases 95, 105, 109, 110, 112 -- the flagship "sanity: UPPERCASE
# CD" case among them), because remembering to wire a bespoke override
# onto every new compound case is exactly the kind of thing a corpus
# author forgets. The fix widened case.reference() ITSELF to detect and
# correctly run any compound sh_words sequence shaped like this
# module's own (a CD chain, then one trailing verb) -- see
# e2e_fs_common.py's compound-support block and Case.reference()'s own
# docstring -- so this module no longer needs (or has) any override for
# that shape at all; every compound case below just works through the
# generic path now. Two OTHER overrides remained after this fix (the
# `-la` and `NOSUCH -l` RULED-divergence cases), UNRELATED to cd/cwd --
# they stood in for a real host `ls` invocation whose OWN flags mean
# something different from maux's pinned contract. A LATER T4 review
# fix (2026-08-23, docs/E2E.md sec 4/10.9 B4) removed those two as
# well, for a different reason: both overrides returned HARDCODED BYTES
# equal to maux's own documented output, the same "expectation wearing
# the reference's clothes" mistake sec 4/B4 names, just typed by hand
# instead of captured. See the FLAG SPELLINGS group's cases() comment
# for that fix; this module has no `c.reference = lambda ...` override
# left at all, for either reason.
# ----------------------------------------------------------------------
def synth(case, ref_out, ref_err, ref_extra, volume, hostdir):
    import e2e_compare as C
    ENC = C.encode_maux_text
    k = case.compare

    if k == 'ls_refused' or k == 'ls_dir_refused':
        # T4 review fix, 2026-08-23 (docs/E2E.md sec 4/10.9 B4): this
        # used to be a branch under 'exact' returning FIXED, hand-typed
        # maux bytes -- the same hardcoded-reference anti-pattern the
        # `c.reference = lambda ...` overrides these two cases used to
        # carry (see the FLAG SPELLINGS group's cases() comment). Both
        # comparators (e2e_fs_ls.cmp_ls_refused, this module's own
        # cmp_ls_dir_refused) check STRUCTURE only and say so in their
        # own docstrings -- any correctly-refused output is accepted,
        # so the selftest just needs *a* plausible one to mutate, the
        # same reasoning e2e_fs_ls.py's own synth() uses for its
        # 'ls_refused' branch.
        return ENC(b'usage: ls [-l] [path ...]\n'), b''

    if k == 'exact':
        # Divergence-governed cases with FIXED, documented maux text
        # (not derived from a live host run at all -- ls's own pinned
        # contract dictates the answer regardless of what /usr/bin/ls
        # would print).
        # The two dot-path/`cd`-case branches that used to sit here
        # (pinned to defects RETIRED 2026-08-24, see DEFECTS above)
        # both returned ENC(ref_out) -- exactly what the generic
        # REF/REF+VOL branch below returns -- so retiring the pins
        # deleted the branches rather than leaving them unreachable.
        # The absolute-command-word sh case (formerly pinned to
        # ('sh', 'absolute command word can spawn a stale PATH-
        # resolved binary'), FIXED 2026-08-23) needs no special
        # branch here any more: case.tool=='cat', case.argv is the
        # absolute IMG_RO path, exactly what case.reference()
        # translates correctly with no cd/relative-path involved, so
        # it now falls straight through to the generic REF/REF+VOL
        # branch immediately below, same as any other ordinary case.
        if case.oracle in ('REF', 'REF+VOL'):
            # Every remaining REF/REF+VOL 'exact' case (compound or not)
            # is correctly derived from ref_out -- case.reference()
            # (the spine) now runs a compound sh_words sequence from the
            # cwd it establishes itself, so this is sound for the
            # flagship "sanity: UPPERCASE CD" case and every other
            # non-defect compound case here too, not just the
            # defect-pinned ones handled explicitly above.
            return ENC(ref_out), b''
        if case.oracle in ('VOL', 'INVARIANT') and case.tool in (
                'mkdir', 'rm', 'mv', 'cp', 'chmod'):
            # None of these five tools prints anything on success (this
            # module's own docstring) -- the REAL oracle for them is the
            # poststate=True tree comparison, not this stdout check.
            # Empty is the correct, EXPLICITLY stated answer here, never
            # ref_out's accidental emptiness (ref_out is ALWAYS empty for
            # a VOL/INVARIANT oracle, by Case.reference()'s own
            # contract -- falling through to ENC(ref_out) would have
            # been right by coincidence, not by reasoning, which is
            # exactly how case 120's pwd bug was written).
            return ENC(b''), b''
        raise AssertionError(
            f"case {case.cid} ({case.tool}): compare='exact' with "
            f"oracle={case.oracle!r} has no explicit branch above, so it "
            f"would fall through to ENC(ref_out) -- and ref_out is "
            f"ALWAYS empty for a VOL/INVARIANT oracle (Case.reference()'s "
            f"own contract: no host tool exists to run). That silent "
            f"fallthrough is case 120's exact bug (pwd's real output "
            f"expected as empty because nobody had to say what the "
            f"answer really was). Add an explicit branch stating this "
            f"case's correct answer; never let a VOL/INVARIANT 'exact' "
            f"case fall through to ref_out.")

    if k == 'name_multiset':
        # Every 'name_multiset' case here is REF-oracled (find), compound
        # or not -- the spine's Case.reference() models the compound
        # `CD X ; <verb> <args>` shape directly, so ref_out is already
        # correct for the dot/dotdot defect family too -- EXCEPT for
        # the MLI_PTH_MAXLN fence (2026-08-24): the host prints a path
        # maux cannot even build, so a reference line over the cap
        # becomes a `find: <path>: ...` diagnostic instead. Cases
        # 102/106 spell the same file relatively and stay under the
        # cap, so they are untouched by this and still synthesise to
        # ref_out verbatim. See cmp_name_multiset's own fence comment.
        keep, over = [], []
        for ln in _lines(ref_out):
            if not ln:
                continue
            (over if len(ln) > MLI_PTH_MAXLN else keep).append(ln)
        if not over:
            return ENC(ref_out), b''
        text = b''.join(
            b'find: ' + p + b': pathname too long\n' for p in over)
        text += b''.join(p + b'\n' for p in keep)
        return ENC(text), b''

    if k == 'du_total':
        # oracle='VOL': the expected lines (per-directory rollups plus
        # the grand total, ALWAYS last -- FINDING 2 fix, 2026-08-23)
        # come from the REAL blocks_used/is_dir this module's own
        # fixtures carry on the volume, never a number read back from
        # maux, never host `du` (whose 1024-byte block unit maux does
        # not share -- CONTRACT sec 2b). See cmp_du_total/_du_lines'
        # own docstrings -- this must build the SAME multi-line answer
        # that comparator now checks, or the selftest's own "accept a
        # correct synthetic answer" proof would fail against its own
        # fix.
        # Members come from the VOLUME now (2026-08-24), not the
        # hand-written list -- see _members_below. The over-cap
        # diagnostic line comes FIRST, as du.s emits it: it reports the
        # entry the moment the walk meets it, before any rollup can be
        # printed. A synthetic "correct" answer without it would not be
        # a correct answer under cmp_du_total's fence check.
        prefix = _target_key(case)
        top = _TARGET_MEMBERS.get(prefix, _IDIOM_MEMBERS)[0]
        members = _members_below(volume, top)
        s_flag = any(a == '-s' for a in case.argv)
        head = ''.join(
            f'du: {prefix}{p[len(top):]}: pathname too long\n'
            for p in _over_cap_below(volume, top))
        text = head + ''.join(
            l + '\n' for l in _du_lines(volume, prefix, members, s_flag))
        return ENC(text.encode()), b''

    if k == 'idiom_file_desc':
        path = case.argv[-1]
        ent = volume.entry(path)
        desc = _FILE_TYPE_DESC.get(ent['type'],
                                   f"unknown type ${ent['type']:02X}".encode())
        return ENC(path.encode() + b': ' + desc + b'\n'), b''

    if k == 'pwd_prefix':
        # case 120's own bug: derived from case.sh_words's own cd
        # target (_pwd_expected), NEVER from ref_out -- see
        # cmp_pwd_prefix's own docstring for why 'exact' could not
        # express this.
        return ENC(_pwd_expected(case)), b''

    if k == 'invariant_resolved':
        return ENC(b'anything, as long as it is not the shell\'s own '
                   b'not-found line\n'), b''

    if k == 'cat_mkpath_refused':
        path = case.argv[-1]
        return ENC(f'cat: cannot open {path}\n'.encode('ascii')), b''

    raise AssertionError(f'no synthesiser for compare={k!r}')
