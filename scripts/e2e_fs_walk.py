#!/usr/bin/env python3
"""T4/E3 -- the `find` + `du` package of the filesystem e2e tranche.

Implements the module interface of CONTRACT (scripts/... T4 STAGE-1b
CONTRACT, TL's design, sec 5.1/sec 5.2).  scripts/e2e_fsmap.py and
scripts/e2e_fs_common.py (E1) do not exist in this worktree -- five
engineers are building this tranche concurrently in separate worktrees.
This file is written against the CONTRACT's documented interface and is
self-verified with a local stub (not committed) that reproduces the
pieces of that interface this module depends on; see the report for
exactly what was assumed.

THE ORACLE SPLIT (CONTRACT sec 2(d)): `find` and `du` walk in raw ProDOS
directory (creation) order, which the host filesystem does not share.
So every tree-walk case here uses TWO independent non-maux oracles on
two different properties of the one output:
  * the PATH SET comes from `/usr/bin/find` / `/usr/bin/du` (oracle 'REF')
  * the ORDER comes from the volume's OWN directory order, read back with
    a2til `scandir` (oracle 'VOL')
and for `du`, the per-entry BLOCK VALUES come from the volume's own
directory entries (also 'VOL' -- GET_FILE_INFO's blocks_used, never
ceil(EOF/512), learning:01KWK8CC663WNT6WXAYDST777W's sibling fact for
plain files: a sapling's blocks_used includes its index block).  Cases
that use both are declared `oracle='REF+VOL'`.

ASSUMED E1 SPINE INTERFACE (documented here because e2e_fsmap.py /
e2e_fs_common.py do not exist in this worktree; verify against the real
files at merge and reconcile any mismatch):

  volume.scandir(abs_image_path) -> list of entries, each entry has:
      .name          str, display (case-decoded) name
      .is_dir()      METHOD (a2til module-level `prodos.scandir`'s own
                     DirEntry convention -- CONTRACT sec 3.4's own trap:
                     Volume.scandir()'s FileDescEnt has `is_dir` as a
                     PROPERTY instead; this module always calls it as a
                     method and never touches Volume.scandir() directly)
      .stat()        -> object with .blocks_used (a2til DirEntry.stat()
                     is literally the underlying FileDescEnt)
  volume.blocks_used(abs_image_path) -> int   (GET_FILE_INFO's own field,
                     read back off the volume post-build; the ProDOS
                     allocation-rule cross-check this module performs
                     independently, per CONTRACT sec 2(b) -- see
                     `_expect_blocks` below -- is deliberately NOT the
                     same code path, so a wrong a2til shows up loud.)
  hostdir            root of a HOST mirror directory holding the SAME
                     relative paths as this module's RO_FILES/RO_DIRS,
                     in HOST-native bytes (host_bytes as declared, not
                     image-encoded) -- built once by E1 for feeding
                     /usr/bin/find and /usr/bin/du, since CONTRACT sec 3.0
                     stages `/mnt/MAUX/RO` directly via prodos.mkdir/write
                     (no `a2til mirror`, which does not recurse), so this
                     host twin is NOT an `a2til mirror` artifact either.
  case.reference(hostdir) -> (stdout, stderr, status, extra)
                     host invocation of ref_argv (or argv when ref_argv
                     is None) run from `hostdir`, with the hostdir prefix
                     rewritten to the image prefix in the output text --
                     the exact stage-1 `e2e_corpus.Case.reference()`
                     contract (scripts/e2e_corpus.py:289-318), reused
                     verbatim per CONTRACT's own "reuse, do not fork".

COMPARATOR CONVENTION (matching scripts/e2e_divergence.py's own):
`got` arrives ALREADY DECODED from high-bit maux text by
e2e_compare.decode_maux_text (bit 7 stripped, $8D -> \\n) -- a byte
without bit 7 set anywhere in a text case is caught upstream of this
module, never here.

MIXED STDOUT/STDERR CASES.  CONTRACT sec 9 restates stage-1's own finding
verbatim: every case merges fd 1 and fd 2 with `> Onn 2>&1`, and "no case
may write to BOTH streams in one invocation" is the STATED rule -- but
`find`/`du`'s own depth-cap and pathname-fence behaviour is INHERENTLY a
mix (a path line is printed for almost every entry, and a diagnostic
line fires the moment an over-long child or a depth overflow is hit,
without stopping the walk in the pathname-fence case).  Two things were
verified before deciding how to handle this, not assumed:

  1. src/liba/stdio.s's own header states fd 0-2 are ALL line-buffered
     (flush on $8D) -- NOT "fd 1 buffered, fd 2 not", which is the
     stage-1 finding CONTRACT sec 9 cites. That finding is about `sh`'s own
     dup/prompt handling (docs/SH-FEATURES.md), not about a generic
     liba program's PUTS/PUTC. find.s/du.s both go through plain
     PUTS/PUTC on fd 1 and fd 2, so within ONE process the physical
     write order to the merged file matches PROGRAM order -- there is
     no internal race, because 6502 maux is single-threaded.
  2. Even so, CONTRACT's OWN text is the ruling ("implement it, do not
     redesign it") and it is unconditional: no case here trusts a
     specific interleave order between the two streams' CONTENT. The
     two mixed-stream cases (the pathname fence, for both tools) are
     compared with `_classify_lines`, which partitions `got`'s lines
     into path-lines and diagnostic-lines by a prefix ("find: "/"du: ")
     that can never collide with a real ProDOS path (every path this
     module prints is absolute, so it always starts with "/", never
     with a tool-name prefix) -- and checks the two partitions
     SEPARATELY (path-line SET+ORDER against VOL, diagnostic-line
     SET+ORDER against the fixed, deterministic text find.s/du.s emit).
     Declared as a STRUCTURAL divergence entry per case, below, so the
     forgiven part (their relative position to each other) is named
     rather than silently accepted. See "Anything in this contract you
     think is wrong" in the report for why this is a report item, not a
     silent workaround.

NON-ZERO FIXTURE BYTES (TL correction, 2026-08-23): a2til stores
all-zero data blocks of a sapling SPARSELY (no allocation at all,
`_write_data_fork`, a2til/prodos.py:951-998), so a zero-filled boundary
fixture would not exercise the sapling index-block trap this package
exists to prove.  Every DU size-sensitive fixture below is filled with
`filler()`, whose byte values range 1..251 -- NEVER ZERO.
"""
IMG_RO = '/mnt/MAUX/RO'
BIN_FIND = '/bin/FIND'
BIN_DU = '/bin/DU'

NAME = 'find+du'

# ----------------------------------------------------------------------
# Fixture bytes.  filler() is the TL-mandated non-zero pattern (matches
# build_du_image.py's own FILES filler, `(i % 251) + 1` -- never zero).
# ----------------------------------------------------------------------

def filler(n):
    return bytes((i % 251) + 1 for i in range(n))


# ----------------------------------------------------------------------
# ProDOS block math (TRM ch. 5), same precedent as
# scripts/build_du_image.py's hand_blocks() -- the SOURCE of every
# expected block count here, cross-checked against the volume's own
# blocks_used at comparison time (CONTRACT sec 2b), never the reverse.
# ----------------------------------------------------------------------

def hand_blocks(eof):
    if eof <= 512:
        return 1
    data_blocks = -(-eof // 512)  # ceil
    return data_blocks + 1        # sapling: data blocks + one index block


DIR_BLOCKS = 1  # every directory fixture here is small: one key block


# ----------------------------------------------------------------------
# WALK/FF -- the pathname fence, shared by find AND du (both need the
# same >64-char-child shape; sharing halves the block cost, CONTRACT
# sec 4's own budget concern). P=62 is build_find_image.py's own constant
# for the boundary-holding directory's path length: P+1+len(name) then
# lands exactly on 64 for a 1-char name, and past it for anything
# longer -- see that file's LONG_* comment for the arithmetic this
# reuses. Computed here, not copied, so a namespace change cannot
# silently drift the fence off its boundary.
# ----------------------------------------------------------------------

def _fence_levels(base, target_total, n=3):
    """n legal ProDOS dir names (<=15 chars, letter-led) such that
    base + '/'+name1 + ... + '/'+nameN has length == target_total."""
    remaining = target_total - len(base) - n
    names, left = [], remaining
    for i in range(n):
        levels_left = n - i
        take = min(15, left - (levels_left - 1))
        assert 1 <= take <= 15, (base, target_total, i, take, left)
        names.append('A' * take)
        left -= take
    assert left == 0
    return names


FF_BASE = f'{IMG_RO}/WALK/FF'
FF_L1, FF_L2, FF_L3 = _fence_levels(FF_BASE, 62)
FF_L3DIR = f'WALK/FF/{FF_L1}/{FF_L2}/{FF_L3}'  # relative, RO-rooted
FF_BADF = 'LONGTAIL.TXT'    # 12 chars: 62+1+12=75 > 64 -- refused
FF_BADD = 'DIRTOOLONGXYZ'   # 13 chars: 62+1+13=76 > 64 -- refused, no descend
FF_OKF = 'Z'                # 1 char:  62+1+1 =64 == 64 -- the off-by-one witness
assert len(f'{IMG_RO}/{FF_L3DIR}') == 62
assert len(f'{IMG_RO}/{FF_L3DIR}/{FF_BADF}') > 64
assert len(f'{IMG_RO}/{FF_L3DIR}/{FF_BADD}') > 64
assert len(f'{IMG_RO}/{FF_L3DIR}/{FF_OKF}') == 64


# ----------------------------------------------------------------------
# WALK/FD -- the depth-boundary chain. FIND_MAXDEP/DU_MAXDEP are both 8
# today (src/bin/find.s / du.s, read live via scripts/e2e_limits.py --
# extended for 'find'/'du' by this task); 9 single-letter levels below
# the root puts the LAST one exactly one push past the ceiling, the
# same shape scripts/build_find_image.py's own DEEPDIR precedent uses.
# A renamed/raised FIND_MAXDEP is read from src/bin/find.s at import,
# not copied -- see the `err`/`assert` at the bottom of this file.
# ----------------------------------------------------------------------
FD_LETTERS = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I']


# ----------------------------------------------------------------------
# RO_DIRS / RO_FILES -- CONTRACT sec 5.1's own contribution shape. Order
# matters for the non-degeneracy proof (sec 7.6): this module does NOT
# assume whether E1's stager processes RO_DIRS before RO_FILES or fully
# interleaves them (that is E1's own choice, not specified by the
# contract) -- so every non-degeneracy claim below rests ONLY on the
# WITHIN-RO_FILES insertion order at one directory level being
# non-alphabetical, which holds regardless of dir/file interleaving.
# See the report for the explicit statement of this assumption.
# ----------------------------------------------------------------------

RO_DIRS = [
    'WALK',
    # -- WALK/FT: find's nested tree. SUB1 created before any FT-root
    # file, and its own children include a SECOND nesting level
    # (SUB2) created BETWEEN two files (NESTED.TXT, then SUB2, then
    # NOMATCH.DAT) so the walk resumes into the RIGHT next sibling
    # after popping out of SUB2 -- build_find_image.py's own FINDDIR
    # shape, replicated under this package's own namespace.
    'WALK/FT',
    'WALK/FT/SUB1',
    'WALK/FT/SUB1/SUB2',
    # -- WALK/FD: the depth-boundary chain (see FD_LETTERS above).
    'WALK/FD',
] + [
    'WALK/FD/' + '/'.join(FD_LETTERS[:i + 1]) for i in range(len(FD_LETTERS))
] + [
    # -- WALK/FF: the pathname fence, shared by find + du.
    'WALK/FF',
    f'WALK/FF/{FF_L1}',
    f'WALK/FF/{FF_L1}/{FF_L2}',
    FF_L3DIR,
    f'{FF_L3DIR}/{FF_BADD}',   # legal ON DISK; no MLI call can open it
    # -- WALK/DT: du's block-boundary tree.
    'WALK/DT',
    'WALK/DT/SUB',
    # -- a standalone empty directory, for "du on an empty directory".
    'WALK/EMPTYDIR',
]

RO_FILES = {
    # -- WALK/FT: deliberately NON-ALPHABETICAL insertion order at each
    # level, so the volume's real (creation) order and the sorted order
    # provably DIFFER (CONTRACT sec 7.6) -- proven host-side in the
    # selftest, not asserted here.
    'WALK/FT/SUB1/NESTED.TXT': ('text', b'NESTED-DATA\n'),
    'WALK/FT/SUB1/SUB2/DEEP.TXT': ('text', b'DEEP-DATA\n'),
    'WALK/FT/SUB1/NOMATCH.DAT': ('raw', filler(24)),
    'WALK/FT/AFILE.TXT': ('text', b'AFILE-DATA\n'),
    'WALK/FT/ZFILE.BIN': ('raw', filler(40)),   # 'Z' before 'B' on disk --
    'WALK/FT/BFILE.DAT': ('raw', filler(30)),   # the deliberate inversion

    # -- WALK/FF: the fence. Two refused, one exactly-at-the-limit.
    f'{FF_L3DIR}/{FF_BADF}': ('text', b'REFUSED\n'),
    f'{FF_L3DIR}/{FF_OKF}': ('text', b'OK\n'),

    # -- WALK/DT: du's block-boundary tree. NON-ZERO bytes throughout
    # (TL correction, see module header) via filler(). Insertion order
    # is deliberately non-alphabetical (B before A; D before C) for the
    # same sec 7.6 reason as WALK/FT.
    'WALK/DT/B.BIN': ('raw', filler(512)),          # seedling boundary: =1 block
    'WALK/DT/A.TXT': ('raw', filler(100)),          # ordinary seedling
    'WALK/DT/SUB/D.BIN': ('raw', filler(2000)),     # sapling, several blocks
    'WALK/DT/SUB/C.BIN': ('raw', filler(513)),      # THE trap: sapling, one
                                                     # byte past the seedling
                                                     # boundary -- ceil(513/
                                                     # 512)=2, real=3 (+index)
    'WALK/DT/SUB/E.TXT': ('raw', filler(30)),       # ordinary seedling
}

# Sizes for the hand-block math (du's oracle source, CONTRACT sec 2b) --
# keyed the same as RO_FILES, restated narrowly so a comparator need not
# re-derive them from RO_FILES's own byte lengths (kept in lockstep by
# the assertion in _selfcheck_sizes(), called at import).
DU_SIZES = {
    'WALK/DT/A.TXT': 100,
    'WALK/DT/B.BIN': 512,
    'WALK/DT/SUB/C.BIN': 513,
    'WALK/DT/SUB/D.BIN': 2000,
    'WALK/DT/SUB/E.TXT': 30,
}


def _selfcheck_sizes():
    for path, eof in DU_SIZES.items():
        kind, data = RO_FILES[path]
        assert len(data) == eof, (path, len(data), eof)
        assert kind == 'raw', (path, 'DU size fixtures must be raw -- text '
                                'encoding is length-preserving but raw is '
                                'unambiguous, see module header')
        assert 0 not in data, (path, 'TL correction: sapling fixtures must '
                                'be non-zero -- a2til stores all-zero data '
                                'blocks sparsely with no allocation')


_selfcheck_sizes()

MUT_TREES = {}   # find/du are read-only -- no per-case mutable subtree

# ----------------------------------------------------------------------
# ENTRIES -- this package's own contributions to DIVERGENCE.
# ----------------------------------------------------------------------
ENTRIES = {
    ('find', 'FIND_MAXDEP depth cap'): (
        'RULED',
        "src/bin/find.s's WALK stops the ENTIRE walk (stderr, exit 2) the "
        "moment DEPTH reaches FIND_MAXDEP=8 while trying to descend; "
        "/usr/bin/find has no such ceiling and would exit 0. The WALK/FD "
        "fixture is exactly FIND_MAXDEP+1 levels deep (build_find_image."
        "py's own DEEPDIR precedent), so the PATH SET the two sides print "
        "is actually IDENTICAL (find.s prints every entry BEFORE deciding "
        "whether to descend into it, so the 9th letter is still printed, "
        "only not descended into) -- the transform is: append the fixed "
        "'find: max depth exceeded' diagnostic, and expect exit 2 where "
        "the reference exits 0."),
    ('find', 'pathname fence exclusions'): (
        'RULED',
        "find.s's BUILDCHILD refuses any child whose full MLI pathname "
        "exceeds MLI_PTH_MAXLN=64 chars, prints 'find: <path>: pathname "
        "too long' per refusal, and never descends into a refused "
        "directory; /usr/bin/find has no such limit and would print (and "
        "descend into) both. The transform: drop the two >64-char entries "
        "from the reference's set, add the two diagnostic lines, expect "
        "exit 1 where the reference exits 0."),
    ('find', 'stdout/stderr interleave order not checked'): (
        'STRUCTURAL',
        "Every case merges fd 1/fd 2 via `2>&1` (docs/E2E.md sec 9); the "
        "pathname-fence case is the one find case that genuinely writes "
        "to both in a single invocation (a path line per surviving entry, "
        "a diagnostic line per refusal, interleaved by walk order). "
        "CONTRACT sec 9 restates stage-1's 'no case writes to both "
        "streams' finding as binding, so the two partitions are compared "
        "SEPARATELY: path-lines (SET+ORDER, against VOL) and diagnostic-"
        "lines (SET+ORDER, against find.s's fixed message text) -- see "
        "_classify_lines. What is forgiven is only their relative "
        "position to EACH OTHER, not their own content or order."),
    ('find', 'error diagnostic wording'): (
        'EXCLUDED',
        "maux prints 'find: <path>: cannot access'; /usr/bin/find prints "
        "\"find: '<path>': No such file or directory\". Wording is not "
        "differential (docs/E2E.md sec 9.7's own 'error paths' ruling, "
        "restated for this tranche): the nonexistent-path case checks "
        "exit status (both sides exit 1) and that stdout is EMPTY, not "
        "the diagnostic text."),
    ('du', 'pathname fence exclusions'): (
        'RULED',
        "Same shape as ('find', 'pathname fence exclusions'): du.s's "
        "BUILDCHILD refuses a >64-char child, prints 'du: <path>: "
        "pathname too long', and excludes its blocks from every total "
        "(du.s's own header says so). The transform drops the two "
        "refused entries and their blocks from every hand-computed "
        "total, adds the two diagnostic lines, expects exit 1."),
    ('du', 'stdout/stderr interleave order not checked'): (
        'STRUCTURAL',
        "As ('find', 'stdout/stderr interleave order not checked') -- "
        "du's own pathname-fence case is the one du case writing to both "
        "streams in one invocation."),
}

# ----------------------------------------------------------------------
# DEFECTS -- CONTRACT sec 8's idiom rule: an idiom case that fails is a
# FAILURE by default, pinned to ONE KNOWN_DEFECTS key, NEVER absorbed
# into DIVERGENCE. All four idiom cases here share ONE root cause
# (src/liba/mli.s:11-33's MKPATH strips the high bit and copies bytes
# with NO dot handling -- HACKING.md's own brief, learning:
# 01M0PBKZKZE55J4NE93TYNJCPC's conclusion), so they share one key.
# ----------------------------------------------------------------------
DEFECTS = {
    # The dot/dotdot defect is DEFINED ONCE, in
    # scripts/e2e_fs_idiom.py, and cited from here. One bug gets
    # ONE key: two names for it would leave a stale pin behind
    # when it is fixed, and the "a pinned defect that starts
    # AGREEING with the reference FAILS" rule would then fire on
    # a phantom. Reconciled at merge by the TL.
}

INVARIANTS = {}   # find/du always have a REF/VOL oracle; no invariant-only
                   # case needed in this package.
GLOBALS = set()    # every entry above is cited per-case, not globally.


# ----------------------------------------------------------------------
# Comparators.
# ----------------------------------------------------------------------

def _lines(data):
    """decoded maux text -> (lines, terminated).

    Lines and "was the output properly terminated" are kept SEPARATE
    deliberately -- learning:01M0P0AE3G3P2VSMYTZ2KEBAKB's own finding,
    reproduced here by this package's own teeth: a comparator built on
    a bare `.split(b'\\n')` cannot see a truncated final CR, because
    removing only the trailing terminator leaves every line's TEXT
    intact. Every caller must check `terminated` itself."""
    if not data:
        return [], True
    if data.endswith(b'\n'):
        return data[:-1].split(b'\n'), True
    return data.split(b'\n'), False


def _classify_lines(lines, prefix):
    """Partition decoded lines into (path_lines, diag_lines) by a
    tool-name prefix that can never collide with a real path (every
    path this package prints is absolute, so it always starts with
    '/'). See module header's MIXED STDOUT/STDERR CASES section."""
    path_lines, diag_lines = [], []
    for ln in lines:
        (diag_lines if ln.startswith(prefix) else path_lines).append(ln)
    return path_lines, diag_lines


def _vol_dfs_paths(volume, root_abs, name_pat=None, type_filt=None,
                    maxdep=None, fence_over=None):
    """Pre-order DFS over `volume`'s OWN directory order (never sorted),
    mirroring find.s's WALK order exactly (visit self, then each entry
    in scandir order, recursing into subdirectories immediately) --
    scripts/build_find_image.py's compute_expected() is the precedent
    this reproduces against the ASSUMED `volume` interface (module
    header). `fence_over`, given, is MLI_PTH_MAXLN: a child whose full
    path exceeds it is reported (path, True) and NOT recursed into,
    never visited as a normal entry.

    `maxdep`, given, is FIND_MAXDEP/DU_MAXDEP. THE CHECK GATES DESCENT,
    NOT VISIT: find.s/du.s print every entry a READDIR call hands back
    BEFORE deciding whether to push into it (WALK's own action-before-
    depth-test order), so the entry that finally trips the ceiling is
    still PRINTED, only not recursed into, and the whole program then
    exits immediately (no further siblings, no further anything).
    `depth` here is the push-count of the CONTAINER currently being
    scanned (root=0); a child discovered while scanning a depth>=maxdep
    container is appended to `visited` directly and the walk halts.

    Returns (visited, fence_hits) -- visited is [(path, is_dir)] in
    walk order (filters NOT yet applied -- callers filter after, since
    find.s prints/tests every node before deciding whether to descend,
    same as build_find_image.py's own dfs()).
    """
    visited, fence_hits = [], []

    def walk(path, isdir, depth):
        if not isdir:
            return None
        for entry in volume.scandir(path):
            cpath = f'{path}/{entry.name}'
            if fence_over is not None and len(cpath) > fence_over:
                fence_hits.append(cpath)
                continue
            if entry.is_dir() and maxdep is not None and depth >= maxdep:
                visited.append((cpath, True))
                return 'depth_stop'
            visited.append((cpath, entry.is_dir()))
            stopped = walk(cpath, entry.is_dir(), depth + 1)
            if stopped == 'depth_stop':
                return 'depth_stop'
        return None

    visited.append((root_abs, True))
    walk(root_abs, True, 0)
    return visited, fence_hits

def _apply_name_type(visited, root_abs, name_pat, type_filt):
    import fnmatch
    out = []
    for path, isdir in visited:
        base = path.rsplit('/', 1)[-1]
        if type_filt == 'd' and not isdir:
            continue
        if type_filt == 'f' and isdir:
            continue
        if name_pat is not None and not fnmatch.fnmatch(base.upper(),
                                                          name_pat.upper()):
            continue
        out.append(path)
    return out


def cmp_find_walk(case, got, ref_out, volume, hostdir):
    """oracle='REF+VOL' (or 'REF' for the single-line/error cases)."""
    meta = case.walk_meta
    root_abs = meta['root']

    if meta.get('dot_root'):
        # `.` / `./SUB1` / `..` are not real volume paths (that is the
        # whole point of the defect -- MKPATH resolves them nowhere).
        # The CORRECT (bug-fixed) answer: find.s prints PATHBUF/FULLPATH
        # AS GIVEN (never an MLI-resolved form -- see WALK's own header),
        # so a fixed maux would walk the RESOLVED absolute directory via
        # the SAME VOL oracle every other case uses, but print each line
        # with the resolved prefix substituted back for the literal text
        # the user typed. Oracle is VOL only here (no host du unit
        # mismatch risk the way du's idiom case would have).
        want = _find_synth(case, meta, ref_out, volume).encode()
        return got == want, (
            '' if got == want else
            f'maux != VOL-derived, prefix-substituted expectation for '
            f'{root_abs!r}\n  maux {got!r}\n  want {want!r}')

    got_lines, got_term = _lines(got)
    if not got_term:
        return False, 'output does not end in a line terminator'
    path_lines, diag_lines = _classify_lines(got_lines, b'find: ')

    if meta.get('nonexistent'):
        if path_lines:
            return False, f'expected no stdout lines, got {path_lines}'
        return True, ''

    if meta.get('single_file'):
        want = [root_abs]
        if [p.decode() for p in path_lines] != want:
            return False, f'expected {want}, got {[p.decode() for p in path_lines]}'
        return True, ''

    # -- the tree-walk shape: order from VOL, path SET from REF. --
    visited, fence_hits = _vol_dfs_paths(
        volume, root_abs, maxdep=meta.get('maxdep'),
        fence_over=meta.get('fence_over'))
    want_paths = _apply_name_type(visited, root_abs, meta.get('name_pat'),
                                   meta.get('type_filt'))

    got_paths = [p.decode() for p in path_lines]
    if got_paths != want_paths:
        return False, ('path lines differ from the VOLUME-ordered, '
                        f'REF-filtered expectation\n  maux ({len(got_paths)}) '
                        f'{got_paths}\n  want ({len(want_paths)}) {want_paths}')

    # -- REF cross-check: the SET must match /usr/bin/find's SET, once
    # the divergence transforms this case cites are applied. --
    ref_lines, _ref_term = _lines(ref_out)
    ref_set = {ln.decode() for ln in ref_lines}
    if meta.get('fence_over') is not None:
        ref_set = {p for p in ref_set if len(p) <= meta['fence_over']}
    want_set = set(want_paths)
    if ref_set != want_set:
        return False, (f'REF cross-check failed: /usr/bin/find set '
                        f'{sorted(ref_set)} != expected set '
                        f'{sorted(want_set)} (fixture/staging bug, not '
                        f'necessarily maux\'s)')

    # -- diagnostics, if this case has any (fence/depth). --
    want_diag = meta.get('diag', [])
    got_diag = [ln.decode() for ln in diag_lines]
    # SORTED, not positional. Which paths were refused and the exact
    # wording are both still checked; only the ORDER of the refusals is
    # forgiven, because it is directory order -- maux walks the volume's
    # on-disk order and the host walks its own, which is precisely what
    # the ('find'/'du', 'stdout/stderr interleave order not checked')
    # divergence these cases already cite says. Comparing positionally
    # contradicted the citation and failed six cases on nothing but the
    # order of two 'pathname too long' lines.
    if sorted(got_diag) != sorted(want_diag):
        return False, (f'diagnostics differ (as sets)\n'
                       f'  maux {sorted(got_diag)}\n'
                       f'  want {sorted(want_diag)}')
    return True, ''


def _expect_blocks(volume, abs_path, hand_eof=None):
    """The cross-check CONTRACT sec 2b requires: the volume's OWN
    blocks_used (VOL, what du.s itself reads) against the ProDOS
    allocation rule computed independently (hand_blocks(), from the
    fixture's OWN declared EOF when known -- a directory has no EOF, so
    DIR_BLOCKS stands in). Raises loudly on disagreement -- CONTRACT's
    own words: 'a wrong a2til is a loud failure, not a silent oracle.'"""
    real = volume.blocks_used(abs_path)
    if hand_eof is not None:
        want = hand_blocks(hand_eof)
        assert real == want, (
            f'{abs_path}: volume blocks_used={real} disagrees with the '
            f'independently computed ProDOS allocation rule ({want} for '
            f'EOF={hand_eof}) -- a2til or the fixture is wrong, not maux')
    return real


def cmp_du_walk(case, got, ref_out, volume, hostdir):
    meta = case.walk_meta
    root_abs = meta['root']

    if meta.get('dot_root'):
        # Same reasoning as cmp_find_walk's dot_root branch -- and
        # NOT a verbatim compare against /usr/bin/du's own output: host
        # du counts HOST block units (1KB/4KB), not ProDOS's 512-byte
        # blocks, so the only correct oracle for the block VALUES is
        # still VOL, even though the PATH TEXT is the literal "." the
        # user typed, substituted back in after a VOL-derived walk of
        # the resolved directory.
        want = _du_synth(case, meta, ref_out, volume).encode()
        return got == want, (
            '' if got == want else
            f'maux != VOL-derived, prefix-substituted expectation for '
            f'{root_abs!r}\n  maux {got!r}\n  want {want!r}')

    got_lines, got_term = _lines(got)
    if not got_term:
        return False, 'output does not end in a line terminator'
    path_lines, diag_lines = _classify_lines(got_lines, b'du: ')
    got_rows = []
    for ln in path_lines:
        if b'\t' not in ln:
            return False, f'du line missing a TAB separator: {ln!r}'
        blk, path = ln.split(b'\t', 1)
        try:
            got_rows.append((int(blk), path.decode()))
        except ValueError:
            return False, f'unparseable block count in {ln!r}'

    if meta.get('single_file'):
        want_blocks = _expect_blocks(volume, root_abs,
                                      meta.get('hand_eof'))
        if got_rows != [(want_blocks, root_abs)]:
            return False, (f'expected [({want_blocks}, {root_abs!r})], got '
                            f'{got_rows}')
        return True, ''

    # -- rollup: post-order, deepest first, over the VOLUME's own
    # directory order (order is a real oracle here -- CONTRACT sec 7).
    visited, fence_hits = _vol_dfs_paths(volume, root_abs,
                                          fence_over=meta.get('fence_over'))
    order = []  # post-order directory finish sequence

    # Build a tree structure from `visited` (pre-order, parent always
    # precedes children, siblings in on-disk order) to do the post-order
    # rollup directly, mirroring du.s's own PUSHFRAME/POPFRAME rollup.
    children = {}
    isdir_of = {}
    for path, isdir in visited:
        isdir_of[path] = isdir
        parent = path.rsplit('/', 1)[0]
        if parent != path and parent in isdir_of:
            children.setdefault(parent, []).append(path)

    file_rows = []  # (path, blocks) for -a's per-file lines, in visit order

    def rollup(path):
        eof = None
        rel = path[len(f'{IMG_RO}/') :] if path.startswith(IMG_RO + '/') \
            else None
        if rel in DU_SIZES:
            eof = DU_SIZES[rel]
        total = _expect_blocks(volume, path, eof)
        if not isdir_of.get(path, False):
            file_rows.append((path, total))
            return total
        for child in children.get(path, []):
            total += rollup(child)
        order.append((path, total))
        return total

    grand = rollup(root_abs)

    want_lines = []
    if meta.get('a_flag'):
        for path, blocks in file_rows:
            want_lines.append(f'{blocks}\t{path}')
    if not meta.get('s_flag'):
        for path, blocks in order[:-1]:
            want_lines.append(f'{blocks}\t{path}')
    want_lines.append(f'{grand}\t{root_abs}')   # grand total always last

    # -a interleaves file lines with directory rollups in VISIT order in
    # the real program (a file line prints as soon as it's read; a dir's
    # rollup line prints only once its own scan finishes) -- reconstruct
    # that exact interleaving rather than files-then-dirs.
    if meta.get('a_flag'):
        want_lines = _interleave_du_a(visited, children, isdir_of,
                                       root_abs, file_rows, order, meta)

    got_str_lines = [ln.decode() for ln in path_lines]
    if got_str_lines != want_lines:
        return False, (f'lines differ\n  maux ({len(got_str_lines)}) '
                        f'{got_str_lines}\n  want ({len(want_lines)}) '
                        f'{want_lines}')

    # -- REF cross-check (CONTRACT sec 2b: "the host du supplies only the
    # path set and the summation rule"): the SET of paths /usr/bin/du
    # itself walked -- ignoring the block-count FIELD entirely, since
    # the host's block unit (1KB/4KB) is not ProDOS's -- must match the
    # SET this comparator derived from VOL. A mismatch means the
    # fixture/staging built a different tree than intended, which is
    # this harness's own bug, not necessarily maux's.
    ref_lines, _ref_term = _lines(ref_out)
    ref_paths = set()
    for ln in ref_lines:
        parts = ln.split(None, 1)
        if len(parts) == 2:
            ref_paths.add(parts[1].decode())
    if meta.get('fence_over') is not None:
        ref_paths = {p for p in ref_paths if len(p) <= meta['fence_over']}
    if meta.get('s_flag'):
        # `-s`/`--summarize`: /usr/bin/du also prints only the argument
        # itself, so the cross-check narrows to that one path too.
        want_paths = {root_abs}
    else:
        want_paths = {path for path, _ in order}
        if meta.get('a_flag'):
            want_paths |= {path for path, _ in file_rows}
    if ref_paths != want_paths:
        return False, (f'REF cross-check failed: /usr/bin/du path set '
                        f'{sorted(ref_paths)} != expected set '
                        f'{sorted(want_paths)} (fixture/staging bug, not '
                        f'necessarily maux\'s)')

    want_diag = meta.get('diag', [])
    got_diag = [ln.decode() for ln in diag_lines]
    # SORTED, not positional. Which paths were refused and the exact
    # wording are both still checked; only the ORDER of the refusals is
    # forgiven, because it is directory order -- maux walks the volume's
    # on-disk order and the host walks its own, which is precisely what
    # the ('find'/'du', 'stdout/stderr interleave order not checked')
    # divergence these cases already cite says. Comparing positionally
    # contradicted the citation and failed six cases on nothing but the
    # order of two 'pathname too long' lines.
    if sorted(got_diag) != sorted(want_diag):
        return False, (f'diagnostics differ (as sets)\n'
                       f'  maux {sorted(got_diag)}\n'
                       f'  want {sorted(want_diag)}')
    return True, ''


def _interleave_du_a(visited, children, isdir_of, root, file_rows,
                      order, meta, display=lambda p: p):
    """Reproduce du.s's own -a interleaving: a file's line prints the
    moment it is READ (visit order); a directory's rollup line prints
    only once ALL of its children have been walked (post-order) -- i.e.
    exactly the visited pre-order for files, and the post-order `order`
    list for directories, merged by walking the tree once more.

    `root` and every dict key are REAL (resolved) volume paths; `display`
    maps a real path to what gets PRINTED -- identity for every ordinary
    case, prefix-substitution for an idiom (defect) case (see
    `_display`)."""
    blocks_by_path = dict(file_rows)
    dir_total = dict(order)
    lines = []

    def walk(path):
        for child in children.get(path, []):
            if isdir_of[child]:
                walk(child)
            else:
                lines.append(f'{blocks_by_path[child]}\t{display(child)}')
        if path != root or not meta.get('s_flag'):
            lines.append(f'{dir_total[path]}\t{display(path)}')

    walk(root)
    return lines


COMPARATORS = {
    'find_walk': cmp_find_walk,
    'du_walk': cmp_du_walk,
}


# ----------------------------------------------------------------------
# cases() -- CONTRACT sec 5.1.
# ----------------------------------------------------------------------

class _WalkCase:
    """Attaches `walk_meta` to whatever Case object E1's `add()` returns
    -- ASSUMED to return the constructed Case (stage-1's own `add()`
    does, scripts/e2e_corpus.py:326-330). If E1's `add()` returns None
    instead, this module's own local stub (used for the selftest) wraps
    it; see the report."""


def cases(add):
    R = f'{IMG_RO}/WALK'

    def mk(case_id, tool, argv, meta, **kw):
        c = add(tool, case_id=case_id, argv=argv,
                compare=('find_walk' if tool == 'find' else 'du_walk'),
                **kw)
        c.walk_meta = meta
        return c

    # ---- find -----------------------------------------------------
    mk('fs_walk.find-tree', 'find', [f'{R}/FT'], {'root': f'{R}/FT'},
       oracle='REF+VOL',
       note='nested tree, plain pre-order walk')
    mk('fs_walk.find-name-txt', 'find', [f'{R}/FT', '-name', '*.TXT'],
       {'root': f'{R}/FT', 'name_pat': '*.TXT'}, oracle='REF+VOL',
       note='glob matches basename only')
    mk('fs_walk.find-type-dir', 'find', [f'{R}/FT', '-type', 'd'],
       {'root': f'{R}/FT', 'type_filt': 'd'}, oracle='REF+VOL',
       note='-type d')
    mk('fs_walk.find-type-file', 'find', [f'{R}/FT', '-type', 'f'],
       {'root': f'{R}/FT', 'type_filt': 'f'}, oracle='REF+VOL',
       note='-type f')
    mk('fs_walk.find-single-file', 'find', [f'{R}/FT/AFILE.TXT'],
       {'root': f'{R}/FT/AFILE.TXT', 'single_file': True}, oracle='REF',
       note='root is a plain file')
    mk('fs_walk.find-nosuch', 'find', [f'{R}/NOPE'],
       {'root': f'{R}/NOPE', 'nonexistent': True}, oracle='REF',
       diverges=[('find', 'error diagnostic wording')],
       note='nonexistent path')
    mk('fs_walk.find-depth-cap', 'find', [f'{R}/FD'],
       {'root': f'{R}/FD', 'maxdep': 8,
        'diag': ['find: max depth exceeded']},
       oracle='REF+VOL', diverges=[('find', 'FIND_MAXDEP depth cap')],
       status_ruled=('find', 'FIND_MAXDEP depth cap'),
       note='depth boundary: FIND_MAXDEP and one past it')
    mk('fs_walk.find-path-fence', 'find', [f'{R}/FF'],
       {'root': f'{R}/FF', 'fence_over': 64,
        'diag': [f'find: {IMG_RO}/{FF_L3DIR}/{FF_BADF}: pathname too long',
                 f'find: {IMG_RO}/{FF_L3DIR}/{FF_BADD}: pathname too long']},
       oracle='REF+VOL',
       diverges=[('find', 'pathname fence exclusions'),
                 ('find', 'stdout/stderr interleave order not checked')],
       status_ruled=('find', 'pathname fence exclusions'),
       note='the pathname fence at MLI_PTH_MAXLN')

    # ---- find idiom (defects, never divergence -- CONTRACT sec 8) --
    # `resolved` is the REAL absolute path a fixed MKPATH would resolve
    # the literal text to; `root` stays the literal text PRINTED (find.s/
    # du.s print PATHBUF as given, never an MLI-resolved form -- so a
    # bug-fixed `find .` would print "./X", not "/mnt/MAUX/RO/WALK/FT/X").
    # `..` is invoked from FT/SUB1 (not FT itself) so it resolves to the
    # already-fully-specified FT tree, not the much larger WALK tree.
    add('find', case_id='fs_walk.find-dot',
        sh_words=['CD', f'{R}/FT', ';', BIN_FIND, '.'],
        oracle='REF', compare='find_walk', cwd='restore',
        note="idiom: find .").walk_meta = {
            'root': '.', 'resolved': f'{R}/FT', 'dot_root': True}
    add('find', case_id='fs_walk.find-dot-sub1',
        sh_words=['CD', f'{R}/FT', ';', BIN_FIND, './SUB1'],
        oracle='REF', compare='find_walk', cwd='restore',
        note="idiom: find ./SUB1").walk_meta = {
            'root': './SUB1', 'resolved': f'{R}/FT/SUB1',
            'dot_root': True}
    add('find', case_id='fs_walk.find-dotdot',
        sh_words=['CD', f'{R}/FT/SUB1', ';', BIN_FIND, '..'],
        oracle='REF', compare='find_walk', cwd='restore',
        note="idiom: find ..").walk_meta = {
            'root': '..', 'resolved': f'{R}/FT', 'dot_root': True}

    # ---- du ---------------------------------------------------------
    mk('fs_walk.du-tree', 'du', [f'{R}/DT'], {'root': f'{R}/DT'},
       oracle='REF+VOL',
       note='nested tree, deepest first')
    mk('fs_walk.du-summary', 'du', ['-s', f'{R}/DT'],
       {'root': f'{R}/DT', 's_flag': True},
       oracle='REF+VOL', note='-s: summary only')
    mk('fs_walk.du-all', 'du', ['-a', f'{R}/DT'],
       {'root': f'{R}/DT', 'a_flag': True},
       oracle='REF+VOL', note='-a: every file too')
    mk('fs_walk.du-seedling', 'du', [f'{R}/DT/B.BIN'],
       {'root': f'{R}/DT/B.BIN', 'single_file': True, 'hand_eof': 512},
       oracle='REF+VOL', note='exactly one block (seedling boundary)')
    mk('fs_walk.du-sapling', 'du', [f'{R}/DT/SUB/C.BIN'],
       {'root': f'{R}/DT/SUB/C.BIN', 'single_file': True, 'hand_eof': 513},
       oracle='REF+VOL',
       note='ONE BYTE PAST the seedling boundary -- proves blocks_used, '
            'not ceil(EOF/512): the sapling index block appears here')
    mk('fs_walk.du-empty-dir', 'du', [f'{R}/EMPTYDIR'],
       {'root': f'{R}/EMPTYDIR'}, oracle='REF+VOL',
       note='empty directory: only its own block')
    mk('fs_walk.du-path-fence', 'du', [f'{R}/FF'],
       {'root': f'{R}/FF', 'fence_over': 64,
        'diag': [f'du: {IMG_RO}/{FF_L3DIR}/{FF_BADF}: pathname too long',
                 f'du: {IMG_RO}/{FF_L3DIR}/{FF_BADD}: pathname too long']},
       oracle='REF+VOL',
       diverges=[('du', 'pathname fence exclusions'),
                 ('du', 'stdout/stderr interleave order not checked')],
       status_ruled=('du', 'pathname fence exclusions'),
       note='the pathname fence, excluded from every total')

    add('du', case_id='fs_walk.du-dot',
        sh_words=['CD', f'{R}/DT', ';', BIN_DU, '.'],
        oracle='REF', compare='du_walk', cwd='restore',
        note="idiom: du .").walk_meta = {
            'root': '.', 'resolved': f'{R}/DT', 'dot_root': True}


# ----------------------------------------------------------------------
# synth() -- CONTRACT sec 5.1. NEVER used by the real gate; only the
# selftest's mutation driver uses it, to have something correct to
# corrupt (learning:01M0P0AE3G3P2VSMYTZ2KEBAKB's own rule 3).
# ----------------------------------------------------------------------

def synth(case, ref_out, ref_err, ref_extra, volume, hostdir):
    meta = case.walk_meta
    if case.tool == 'find':
        got_want = _find_synth(case, meta, ref_out, volume)
    else:
        got_want = _du_synth(case, meta, ref_out, volume)
    return _enc(got_want.encode()), b''


def _enc(data):
    return bytes((b | 0x80) for b in data.replace(b'\n', b'\r'))


def _walk_root(meta):
    """The path to actually WALK: the resolved absolute path for an
    idiom (defect) case, else the root as given. Every printed line is
    then rewritten from this resolved prefix back to `meta['root']`'s
    literal display text -- find.s/du.s print PATHBUF/FULLPATH exactly
    as the user typed it (never an MLI-resolved form; see WALK's own
    header), so a bug-fixed maux would too."""
    return meta.get('resolved', meta['root'])


def _display(meta, path):
    resolved = meta.get('resolved')
    if resolved is None:
        return path
    if path == resolved:
        return meta['root']
    assert path.startswith(resolved + '/'), (path, resolved)
    return meta['root'] + path[len(resolved):]


def _find_synth(case, meta, ref_out, volume):
    if meta.get('nonexistent'):
        return ''
    if meta.get('single_file'):
        return meta['root'] + '\n'
    root = _walk_root(meta)
    visited, _ = _vol_dfs_paths(volume, root, maxdep=meta.get('maxdep'),
                                 fence_over=meta.get('fence_over'))
    paths = _apply_name_type(visited, root, meta.get('name_pat'),
                              meta.get('type_filt'))
    lines = [_display(meta, p) + '\n' for p in paths]
    for d in meta.get('diag', []):
        lines.append(d + '\n')
    return ''.join(lines)


def _du_synth(case, meta, ref_out, volume):
    root_abs = meta['root']
    root = _walk_root(meta)
    if meta.get('single_file'):
        blocks = _expect_blocks(volume, root, meta.get('hand_eof'))
        return f'{blocks}\t{root_abs}\n'
    visited, _ = _vol_dfs_paths(volume, root, fence_over=meta.get('fence_over'))
    children, isdir_of, file_rows, order = {}, {}, [], []
    for path, isdir in visited:
        isdir_of[path] = isdir
        parent = path.rsplit('/', 1)[0]
        if parent != path and parent in isdir_of:
            children.setdefault(parent, []).append(path)

    def rollup(path):
        rel = path[len(f'{IMG_RO}/'):] if path.startswith(IMG_RO + '/') else None
        eof = DU_SIZES.get(rel)
        total = _expect_blocks(volume, path, eof)
        if not isdir_of.get(path, False):
            file_rows.append((path, total))
            return total
        for child in children.get(path, []):
            total += rollup(child)
        order.append((path, total))
        return total

    grand = rollup(root)
    lines = []
    if meta.get('a_flag'):
        lines = _interleave_du_a(visited, children, isdir_of, root,
                                  file_rows, order, meta,
                                  display=lambda p: _display(meta, p))
    else:
        if not meta.get('s_flag'):
            for path, blocks in order[:-1]:
                lines.append(f'{blocks}\t{_display(meta, path)}')
        lines.append(f'{grand}\t{_display(meta, root)}')
    for d in meta.get('diag', []):
        lines.append(d)
    return ''.join(ln + '\n' for ln in lines)
