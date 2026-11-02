#!/usr/bin/env python3
"""T4 STAGE-1b: the MUTATING filesystem tools -- rm, mv, cp, mkdir.

CONTRACT.md sec 5.1 module interface.  Verified against source, not
memory (HACKING.md rule 4): src/bin/rm.s, src/bin/mv.s, src/bin/cp.s,
src/bin/mkdir.s, src/liba/mli.s -- all read in full, all four ratified
by `mcp__street-library__get`/`search` per HACKING.md rule 3 (see the
handles cited inline below).

THE HEADLINE FINDING, confirmed by grep, not inference, ORIGINALLY:
src/bin/mv.s contained the string "GFI" exactly ZERO times.  cp.s
SC_GFI-stats SRC and patches CRPARM_TYPE/CRPARM_AUX from the result
(cp.s:121-131); mv.s's copy path (COPYFILE) had no such call anywhere
in the file and hardcoded `CRPARM_FTYP dfb FTYPE_BIN` (mv.s:393).  So
`mv` across directories silently reassigned a TXT file's ProDOS
file_type to BIN, while `mv` within a directory (the RENAME path) did
not touch file_type at all and `cp` preserved it correctly.  FIXED
2026-08-23 (mv.s commit 1ae0266, cp.s commit e9b5dd7) -- DEFECTS below
is now empty; the four cases that were pinned to it (7, 8, 15, 17)
carry their own retirement notes describing what each case now asserts
in place of the pin.

NONE of these four tools print anything on success (rm.s, mv.s, cp.s,
mkdir.s all confirmed silent-on-success by reading every code path).
So stdout/stderr differencing alone is a weak oracle here; the real
oracle is the POST-STATE OF THE TREE (CONTRACT sec 3, sec 5.2
`poststate=True`), which is why every case below sets it.

ASSUMED SPINE (E1's scripts/e2e_fsmap.py and scripts/e2e_fs_common.py do
not exist in this worktree -- CONTRACT sec 0's instruction is "stub
locally to run your teeth").  Every assumption is stated once, here,
rather than scattered:

  * MUT_TREES values are `(kind, host_bytes)` staged via `prodos.write`
    with file_type TXT ($04) for kind='text', BIN ($06) for kind='raw'
    (matching build_v1_system_image.py's SEED fixture, which is TXT and
    plain LF-text).  A directory entry is the sentinel string 'DIR'.
  * The COMPARATORS signature is exactly `fn(case, got, ref, volume,
    hostdir)` per CONTRACT sec 5.1.  `got`/`ref` are the ALREADY-DECODED
    (low-ASCII, '\\n'-terminated) merged stdout+stderr, matching
    scripts/e2e_compare.judge's contract (it calls decode_maux_text on
    `got` before invoking the comparator).  `volume`/`hostdir` are
    unused by the plain-diagnostic comparator below; the SECOND,
    independent `poststate=True` assertion (CONTRACT sec 5.2, sec 7.3)
    is assumed to be a comparator SHARED across every fs-tranche package
    (since "reject a changed ProDOS file type" is identical logic
    whether the mutation came from `mv`, `chmod`, or the idiom package),
    living in e2e_fs_common.py, not reimplemented per-module.  This
    module supplies the ingredients that comparator needs -- `ref_op`
    and MUT_TREES -- and, because that shared comparator does not exist
    here to import, this file also carries a clearly-labelled STUB of
    it (`_stub_tree_compare`) used ONLY by this file's own `_selftest`,
    never exported as part of the module interface.
  * The tree-state reader is `prodos.mount(image)` once, then
    module-level `prodos.scandir(path)` (yields `DirEntry`, whose
    `is_dir()`/`is_file()` are METHODS -- CONTRACT sec 3.4's trap;
    `Volume.scandir()`'s raw `FileDescEnt` is NOT used anywhere in this
    file) recursively under `/mnt/MAUX/MUT/<tree>`, `prodos.read(path)` for
    file bytes, `prodos.unmount(name)` at the end -- exactly
    scripts/check_v1_system.py:164-196's pattern.  A case's `poststate`
    assertion is assumed to receive that subtree already read into a
    dict keyed by path relative to the tree root.
  * A case's own KNOWN_DEFECTS/DIVERGENCE pin is assumed to cover
    WHICHEVER assertion the case makes (the plain-diagnostic comparator
    for text-only defects, the shared tree comparator for poststate
    ones) -- there being one `defect=`/`diverges=` field per case in
    CONTRACT sec 5.2, not one per assertion.
  * Every case's primary text expectation is computed by THIS module's
    own formula (`_expect()`), from the four tools' EXACT, verified,
    fixed-format diagnostic strings -- NOT from the host reference's
    text, which shares no structure with them at all (rm.s/mv.s/cp.s/
    mkdir.s's ERRMSG constants are quoted and cited below).  This is
    the `GLOBALS`-cited `('mutate', 'diagnostic message text')` entry:
    STRUCTURAL grade, because the underlying fact being checked (did it
    fail, on which operand) still comes from maux's own documented,
    deterministic message shape, not from nothing.

Street-library handles fetched (HACKING.md rule 3) before any of this was
designed:
  learning:01M07G8WT2R3G2P87EK1DNPVYP -- name legality is a PARSER rule;
    every fixture name here is upper-case letters+digits, <=15 chars,
    starts with a letter.
  learning:01M0P08K94TE5DNQ0JWCG885WG -- a ProDOS-hosted tool cannot be
    handed the same open path twice; not directly hit by this package
    (no case aliases an operand against itself), noted for completeness.
  learning:01M04PK5D27KFPMS0EM80FHQ8Y -- subdirectory header +$14 is a
    5-bit POPCOUNT sentinel, not the literal byte $75.  `mkdir` is the
    one case in this package that asks the real MLI CREATE to build a
    fresh subdirectory header; if the emulated ProDOS firmware gets that
    byte wrong, `a2til check` (CONTRACT sec 3.3) is what will catch it,
    not this file -- see the volume-corruption note in the final report.
  learning:01KWK8CC663WNT6WXAYDST777W -- blocks_used/eof semantics for
    forked files (storage_type $5) do NOT apply to the plain
    seedling/sapling files this package creates; eof is the real size.
  learning:01M0P0AE3G3P2VSMYTZ2KEBAKB -- how a harness measures nothing:
    keep "lines" and "was it terminated" apart, and hash staged
    binaries.  Read for method, not because it's cited by a case here.
Own searches run (HACKING.md rule 3a/3): "ProDOS DESTROY directory",
"ProDOS RENAME cross directory", "ProDOS CREATE storage_type seedling
sapling", "ProDOS directory entry file_type aux_type", "ProDOS
blocks_used index block" -- no further learning surfaced beyond the
handles above; the DESTROY-on-a-non-empty-directory question in
particular came back a genuine gap (see DIVERGENCE entry below, marked
[reported] not [fact]).
"""
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e_compare as C   # noqa: E402  -- decode_maux_text/encode_maux_text, reused not forked
import e2e_limits as L    # noqa: E402  -- boundaries read from headers, never copied in
import e2e_fs_common as FC  # noqa: E402  -- E7 integration: the real DIR sentinel

ENC = C.encode_maux_text
DEC = C.decode_maux_text

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

NAME = 'mutate'   # rm + mv + cp + mkdir

# --- boundaries, read from the headers the code itself reads (never a
# --- copied-in literal -- docs/E2E.md sec 5 / CONTRACT sec 0.4) --------
ARGBUFSZ = L.parse_equs('src/bin/mv.s')['ARGBUFSZ']            # 80
_MLI = L.parse_equs('inc/mli.equ')
MLI_PTH_MAXLN = _MLI['MLI_PTH_MAXLN']                            # 64
FTYPE_TXT = _MLI['FTYPE_TXT']                                    # $04
FTYPE_BIN = _MLI['FTYPE_BIN']                                    # $06
FTYPE_DIR = _MLI['FTYPE_DIR']                                    # $0F
STYP_SEEDLING = _MLI['STYP_SEEDLING']                            # $01

assert ARGBUFSZ == 80 and MLI_PTH_MAXLN == 64, (
    'boundary values changed upstream -- re-read mv.s/mli.equ before '
    'trusting the case shapes below')

#: Sentinel for a MUT_TREES entry that is a subdirectory rather than a
#: file.  E7 integration, 2026-08-23: this module originally stubbed a
#: local `DIR = 'DIR'` string (its own stated assumption -- it could not
#: import E1's real spine, which did not exist in that worktree). The
#: real e2e_fs_common.Registry filters MUT_TREES entries by IDENTITY
#: against its own sentinel object (`v is not FC.DIR`), so a distinct
#: string sentinel here would silently fall through as an ordinary
#: (kind, host_bytes) fixture spec instead of a directory -- reconciled
#: to the real sentinel, same meaning, no change in fixture intent.
DIR = FC.DIR

#: MUT_TREES keys are globally unique across all six packages
#: (CONTRACT sec 3.1/3.5: "no other case may name it").  Namespaced
#: with a distinctive prefix so a collision with ls/find/du/chmod/file/
#: idiom's own trees is unlikely.
_T = lambda n: f'MUT{n:02d}'          # noqa: E731 -- tiny, load-bearing only for naming


def _nonzero(n):
    """Deterministic non-NUL byte content of length n. TL's note: a2til
    stores all-zero DATA BLOCKS sparsely (prodos.py:951-998,
    `_write_data_fork`), so a fixture that happens to be NUL-filled would
    make a size/content comparison pass for the wrong reason. Every raw
    fixture below is built through this, never through `bytes(n)`."""
    return bytes(((i % 250) + 1) for i in range(n))


def _padpath(prefix, total_len):
    """A fake, ProDOS-legal-LOOKING (but not staged) pathname of EXACTLY
    total_len characters, built from prefix + nested 14-char segments of
    'Q' padding. Used only for the ARGBUFSZ boundary cases (12/13 below),
    where CPYARG's length check fires before any MLI call is ever made,
    so the path need not correspond to a real file (verified: CPYARG in
    mv.s runs immediately in :haveargs, before SAMEDIR/TRYRENAME/
    COPYFILE ever touch the filesystem)."""
    out = prefix
    seg = 0
    while len(out) < total_len:
        room = total_len - len(out) - 1              # -1 for the '/'
        width = min(14, max(1, room))
        if room - width == 0 or room - width > 1:
            pass
        else:                     # would leave ONE char: no segment
            width -= 1            # is shorter than '/Q'
        out += '/' + ('Q' * width if width > 1 else 'Q')
        seg += 1
        if seg > 20:
            raise AssertionError(f'_padpath could not reach {total_len} '
                                 f'from {prefix!r}')
    assert len(out) == total_len, (len(out), total_len, out)
    return out


# ======================================================================
# Fixtures.  RO_FILES/RO_DIRS are empty: nothing in this package needs a
# SHARED read-only fixture -- rm/mv/cp/mkdir each own an exclusive
# per-case subtree (CONTRACT sec 3.1/3.5), which is the whole point of
# a mutating-tools package.
# ======================================================================
RO_FILES = {}
RO_DIRS = []

MUT_TREES = {
    _T(1): {'FILEA': ('text', b'alpha content\n')},
    _T(2): {'A': ('text', b'a\n'), 'B': ('text', b'b\n'), 'C': ('text', b'c\n')},
    _T(3): {'KEEP': ('text', b'keep me\n')},
    _T(4): {'SUBDIR': DIR},
    _T(5): {'SUBDIR': DIR, 'SUBDIR/INSIDE': ('text', b'inside content\n')},
    _T(6): {'OLDNAME': ('text', b'rename payload\n')},
    _T(7): {'SRC': DIR, 'DST': DIR, 'SRC/DOC': ('text', b'plain text payload\n')},
    #: LENGTHS CHOSEN DELIBERATELY (TL, 2026-08-23): A (the new
    #: content) is 6 bytes; B (the pre-existing DST) is 100 bytes --
    #: B is staged 94 bytes LONGER than what will be written over it.
    #: If A and B were the same length the predicted defect (mv.s:
    #: 294-301's unchecked SC_CREAT carry, no truncate before OPEN+
    #: WRITE onto the pre-existing file) would be byte-for-byte
    #: invisible to the poststate comparator even if it reproduces --
    #: exactly the degenerate case CONTRACT sec 7.6 warns against.
    #: 100 was picked only to comfortably clear BUFSZ-irrelevant
    #: single-chunk copy (mv.s's copy loop moves up to 512 B/call;
    #: both lengths fit in one SC_READ/SC_WRITE, so this is purely a
    #: length-mismatch probe, not a multi-chunk one).
    #:
    #: T4 REVIEW (2026-08-23): B's meta now pins file_type=FTYPE_BIN
    #: explicitly. Without it, both A ('text') and B ('raw') resolve
    #: to e2e_fsmap.DEFAULT_FILE_TYPE (TXT $04) -- B's OWN pre-move
    #: type and A's type would be IDENTICAL, so this case's
    #: expect_types={'B': ('from','A')} could not tell "B kept its
    #: own type" apart from "B acquired A's type" (the exact vacuity
    #: this review flagged in case 15 below, audited here too since
    #: B pre-exists here as well). Now B starts BIN and must arrive
    #: TXT (A's type) for the assertion to mean anything.
        _T(8): {'A': ('text', b'short\n'),
                'B': ('raw', _nonzero(100), {'file_type': FTYPE_BIN})},
    _T(9): {'KEEP': ('text', b'untouched\n')},
    _T(10): {'A': ('text', b'move me\n')},
    _T(11): {},   # ARGBUFSZ-fits: SRC deliberately not staged (see case 11)
    _T(12): {},   # ARGBUFSZ-too-long: same
    _T(13): {'A': ('raw', _nonzero(40))},
    _T(14): {'A': ('text', b'preserve my type\n')},
    #: T4 REVIEW (2026-08-23) -- DEFECT 3's own toothless-gate
    #: finding: B's meta now pins file_type=FTYPE_BIN explicitly.
    #: Before this, A ('text') and B ('raw') both resolved to
    #: e2e_fsmap.DEFAULT_FILE_TYPE (TXT $04) -- "B keeps its own
    #: type" and "B acquires A's type" were BYTE-IDENTICAL outcomes,
    #: so a cp that left B's original type untouched on overwrite
    #: (the exact defect 3 bug: CREATE is skipped on the ERR_DUPFN
    #: path, so the GFI-stat-and-patch of CRPARM_TYPE/AUX was dead
    #: code) still PASSED this assertion by coincidence. Now B
    #: starts BIN and must arrive TXT (A's type) for expect_types to
    #: mean anything -- see the RED/GREEN demonstration in the task
    #: report.
    _T(15): {'A': ('text', b'new\n'),
             'B': ('raw', _nonzero(80), {'file_type': FTYPE_BIN})},
    _T(16): {},
    _T(17): {'SRCDIR': DIR, 'SRCDIR/INSIDE': ('text', b'dir payload\n')},
    _T(18): {},
    _T(19): {},
    _T(20): {'EXIST': ('text', b'already here\n')},
    _T(21): {},
    _T(22): {},
    _T(23): {},   # MLI_PTH_MAXLN robustness: nothing needs staging
    #: T4 REVIEW DEFECT 1 corpus gap: mv's SRC-is-a-directory case
    #: was entirely missing (the review's own finding -- existing
    #: mv cases are all plain-file operands). SUB is a real
    #: directory so the move is forced CROSS-directory (SAMEDIR
    #: compares path PREFIXES: .../MUT24/SRCDIR vs
    #: .../MUT24/SUB/SRCDIR do not match), landing in COPYFILE --
    #: same routine defect 1 lived in, not the RENAME path, which
    #: never opens SRC at all and so could never hit this bug.
    _T(24): {'SRCDIR': DIR, 'SRCDIR/INSIDE': ('text', b'dir payload\n'),
             'SUB': DIR},
    #: T4 REVIEW DEFECT 2 concrete scenario: `mv FILE
    #: EXISTING_EMPTY_DIR`. DIR is a real, EMPTY subdirectory --
    #: DESTROY (P8 TRM 4.4.2) succeeds on exactly this shape, which
    #: is what made the pre-fix blind destroy dangerous.
    _T(25): {'A': ('text', b'move me too\n'), 'DIR': DIR},
    #: `mv DIR1 DIR2` with DIR2 ALREADY PRESENT -- the IMPLICIT
    #: move-into form, and the one a script is most likely to hit by
    #: accident. The same shell line is a RENAME when DIR2 is absent
    #: (which maux does correctly, via MLI RENAME) and a MOVE INTO
    #: when it exists, so which operation runs depends on the state
    #: of the filesystem, not on the text of the command.
    _T(26): {'DIR1': DIR, 'DIR1/INSIDE': ('text', b'dir1 payload\n'),
             'DIR2': DIR},
    #: 2026-08-25, docs/CPTREE.md sec 6's own corpus list -- what the
    #: two DEFECTS-pinned cases above never covered because a ONE-level
    #: tree cannot: the walk's push/pop, its resume replay on the way
    #: back up out of a closed directory (sec 3's "close before every
    #: file copy, reopen + replay"), and the deepest-first teardown
    #: order all only run when a level holds a subdirectory AND a
    #: sibling AFTER it. F3 is that sibling -- it is discovered only
    #: after SUB has been fully descended into, copied, and popped back
    #: off the depth stack, so a walk that lost its resume position
    #: would either re-copy SUB's contents or skip F3 outright, and
    #: either failure is silent (mv prints nothing on success either
    #: way) -- only the poststate tree comparator catches it. DEST is
    #: staged as an EXISTING empty directory so `mv SRC DEST` takes the
    #: move-into branch (DSTRESOLV rewrites DST to DEST/SRC), the
    #: OTHER live code path through MOVEDIR alongside the DST-absent
    #: rename tested by _T(28) below.
    _T(27): {'SRC': DIR, 'SRC/F1': ('text', b'f1 payload\n'),
             'SRC/SUB': DIR, 'SRC/SUB/F2': ('text', b'f2 payload\n'),
             'SRC/F3': ('text', b'f3 payload\n'), 'DEST': DIR},
    #: CPT_ISDESC/resume-counter shape, docs/CPTREE.md sec "CPT_SKIPN
    #: must be a separate cell from CPT_RESN": decrementing the LEVEL's
    #: absolute position during a resume is the exact bug that made
    #: `find` loop forever over any directory holding TWO
    #: subdirectories (find.s:704-714, cited verbatim in CPTREE.md).
    #: SRC here holds SUBA and SUBB side by side -- after SUBA is fully
    #: copied and popped, the walk must resume SRC's own directory at
    #: entry position 1 (SUBB), not entry position 0 (SUBA again); a
    #: transplanted version of the find.s bug demonstrably re-looped on
    #: exactly this shape in cptree during this session (see the task
    #: report's RED/GREEN teeth demonstration). DEST is left ABSENT so
    #: this case exercises MOVEDIR's OTHER branch from _T(27) above:
    #: DST absent -> CPT_MKDIR creates it fresh, no move-into rewrite.
    _T(28): {'SRC': DIR, 'SRC/SUBA': DIR,
             'SRC/SUBA/FA': ('text', b'fa payload\n'),
             'SRC/SUBB': DIR,
             'SRC/SUBB/FB': ('text', b'fb payload\n')},
    #: `mv DIR DEST` where DEST/DIR already exists and is NON-EMPTY --
    #: docs/CPTREE.md sec 1's own table, the one row `mv` refuses
    #: unconditionally (unlike `cp -r`, which MERGES here instead --
    #: _T(33) below is the same shape used the other way). OTHER is
    #: DEST/DIR's own pre-existing content and must survive UNTOUCHED:
    #: a blind destroy-and-recreate (the exact T4 DEFECT 2 shape this
    #: corpus already caught once, case _T(25)) would silently delete
    #: it even though the operation as a whole correctly reports
    #: failure.
    _T(29): {'DIR': DIR, 'DIR/INSIDE': ('text', b'inside payload\n'),
             'DEST': DIR, 'DEST/DIR': DIR,
             'DEST/DIR/OTHER': ('text', b'other payload\n')},
    #: `mv DIR DIR/SUB` -- moving a directory into its own subtree.
    #: SUB is deliberately NOT staged: CPT_ISDESC only needs the two
    #: PATHS (DIR vs DIR/SUB) to detect the descendant relationship
    #: (docs/CPTREE.md's own note that a plain prefix compare is not
    #: enough -- "/T/AB" starts with "/T/A" but is not beneath it; here
    #: the shapes are unambiguous, DIR/SUB IS beneath DIR), so the
    #: refusal must fire before anything ever stats SUB. INSIDE proves
    #: DIR itself is untouched by the refusal.
    _T(30): {'DIR': DIR, 'DIR/INSIDE': ('text', b'inside payload\n')},
    #: `cp -r DIR DEST`, DEST ABSENT -- the copy-only twin of _T(28)'s
    #: rename-shaped move: DEST becomes a fresh copy of DIR (not
    #: DEST/DIR), and unlike every mv case above, DIR itself must
    #: SURVIVE the operation -- cp never unlinks its source.
    _T(31): {'DIR': DIR, 'DIR/INSIDE': ('text', b'inside payload\n')},
    #: `cp -r DIR DEST`, DEST an EXISTING EMPTY directory -- copies
    #: INTO it as DEST/DIR, the same move-into resolution DSTRESOLV
    #: gives `mv`, but DIR survives afterward (cp, not mv).
    _T(32): {'DIR': DIR, 'DIR/INSIDE': ('text', b'inside payload\n'),
             'DEST': DIR},
    #: `cp -r DIR DEST` where DEST/DIR already EXISTS and is
    #: NON-EMPTY -- the shape `mv` refuses at _T(29), `cp -r` accepts:
    #: MERGE, exit 0, DEST/DIR keeps OTHER alongside the freshly-copied
    #: INSIDE. This is a REAL, measured difference between the two
    #: tools (docs/CPTREE.md sec 1: "`cp -r` MERGES into an existing
    #: directory rather than refusing it -- `mv` demands an EMPTY one,
    #: and that is a genuine difference between the two tools"), not
    #: drift -- both are checked against their own host counterpart,
    #: not against each other.
    _T(33): {'DIR': DIR, 'DIR/INSIDE': ('text', b'inside payload\n'),
             'DEST': DIR, 'DEST/DIR': DIR,
             'DEST/DIR/OTHER': ('text', b'other payload\n')},
    # -- rm -r/-f (FLEET F.2, 2026-09-01). T34: a two-level tree plus
    # a bystander that must survive the teardown. T35/T36: bystanders
    # for the -f silence cases.
    _T(34): {'SUBDIR': DIR,
             'SUBDIR/INSIDE': ('text', b'doomed payload\n'),
             'SUBDIR/NEST': DIR,
             'SUBDIR/NEST/DEEP': ('text', b'deep payload\n'),
             'KEEP': ('text', b'bystander\n')},
    _T(35): {'KEEP': ('text', b'bystander\n')},
    _T(36): {'SUBDIR': DIR,
             'SUBDIR/INSIDE': ('text', b'doomed payload\n'),
             'KEEP': ('text', b'bystander\n')},
    # -- cp/mv multi-into-directory (FLEET F.2, 2026-09-01).
    _T(37): {'A': ('text', b'alpha payload\n'),
             'B': ('text', b'beta payload\n'),
             'DEST': DIR},
    _T(38): {'A': ('text', b'alpha payload\n'),
             'B': ('text', b'beta payload\n'),
             'DEST': DIR},
    _T(39): {'A': ('text', b'alpha payload\n'),
             'B': ('text', b'beta payload\n'),
             'NOTADIR': ('text', b'plain file\n')},
    _T(40): {'B': ('text', b'beta payload\n'),
             'DEST': DIR},
    # -- touch (FLEET F.3, 2026-09-01): creation + content survival;
    # the mtime-stamp assertion itself lives in e2e_fs_meta (poststate
    # content comparison cannot see a date).
    _T(41): {'KEEP': ('text', b'bystander\n')},
    _T(42): {'HAVE': ('text', b'existing payload\n')},
    # -- mkdir -p (POSIX -p, 2026-09-13): the walk-rule test suite.
    # T43 empty -- every intermediate is missing. T44 the leaf
    # already exists as a directory. T45 the parent exists, only
    # the child is new. T46/T47 an existing PLAIN FILE blocks the
    # walk, as an intermediate and as the leaf itself. T48 two
    # operands together. T49 mirrors T45's shape (two new
    # components) to prove the absolute-path volume-skip explicitly
    # (mkdir.s's own header: "/mnt/MAUX" is this image's volume name,
    # so EVERY case here already exercises that skip -- T49 is
    # simply the dedicated one).
    _T(43): {},
    _T(44): {'EXISTD': DIR},
    _T(45): {'PARENT': DIR},
    _T(46): {'EXISTF': ('text', b'blocks the walk\n')},
    _T(47): {'EXISTF2': ('text', b'plain file leaf\n')},
    _T(48): {},
    _T(49): {},
}

OUT = '/mnt/MAUX/OUT'


def _p(tree, *rel):
    return '/'.join(['/mnt/MAUX/MUT/' + tree] + list(rel))


# ======================================================================
# Divergence / defect / invariant contributions (CONTRACT sec 5.1).
# ======================================================================
ENTRIES = {
    ('rm', 'DESTROY succeeds on a directory operand'): (
        'DISCHARGED',
        "src/bin/rm.s has no -r/-f (its own header says so) and calls "
        "MLI DESTROY ($C1) unconditionally on every operand -- DESTROY "
        "works on an EMPTY directory as well as a file (docs/FLEET.md's "
        "own note on `rmdir`: 'SYS_UNLINK -> MLI DESTROY already "
        "handles directories'). POSIX rm with no -r/-d refuses ANY "
        "directory operand, empty or not, so for the EMPTY case the "
        "reference is asked the equivalent question -- `rm -d` -- "
        "instead of being forgiven a mismatch afterwards: both sides "
        "then perform the same deletion and the comparison is a real "
        "one, not a documented gap.\n"
        "SCOPE NARROWED 2026-08-24, BY MEASUREMENT. This entry used to "
        "cover the non-empty case too, pairing it with `rm -r` on the "
        "reference, and flagged its own [reported] confidence: whether "
        "ProDOS 8's DESTROY recursively frees a non-empty "
        "subdirectory's contents was unverifiable here (the local TRM "
        "excerpt, docs/a2/L.MLIE.TXT, gives DESTROY's 3-byte parmlist "
        "shape and no prose; a street-library search came back empty), "
        "and it named itself 'the single most likely case in this "
        "package to need revision once run against a real ProDOS "
        "implementation'. It ran on verilogapple for the first time on "
        "2026-08-24 and the guess was WRONG: DESTROY REFUSES a "
        "non-empty subdirectory, returning $4E (ACCESS ERROR), and rm "
        "prints 'rm: cannot unlink <path>' and exits 1. That is what "
        "POSIX rm without -r does as well, so the two sides AGREE and "
        "the non-empty case is no longer a divergence at all -- it "
        "dropped this citation, its `rm -r` reference and its ref_op. "
        "Now [fact], for the empty case as well: DESTROY succeeds on "
        "an EMPTY directory operand and refuses a non-empty one."),
    # ('mv', 'no directory SRC form') was HERE and is DELETED,
    # 2026-08-25 -- RECLASSIFIED, not retired. It described a real
    # difference accurately and then graded it RULED, which reads as
    # "by design". It is not: a cross-directory directory move is
    # avoidable drift that simply is not implemented yet, so it moved
    # to DEFECTS above, where the pin is two-sided and fails the day
    # someone implements it. Its scope was wider than the truth, too:
    # a same-parent directory rename works today.

    # ('cp', 'no recursive copy') was HERE and is DELETED, not
    # commented out, 2026-08-25. It was never a divergence: `cp DIR
    # DST` without -r FAILS on the host too ("cp: DIR is a directory
    # (not copied)", exit 1), exactly as cp.s refuses it. The mismatch
    # was manufactured by this file asking the REFERENCE `cp -r` --
    # a different question -- and then ruling away the exit-status
    # difference that created. The reference is asked plain `cp` now
    # and both sides agree. Measured 2026-08-25.
    #
    # The rm cases two screens up got this right on the same day and
    # this one did not, which is the lesson worth keeping: when a case
    # needs a FLAG on the reference to make it "comparable", check
    # whether the unflagged reference already agrees before writing a
    # ruling. A ruling that exempts a difference the test itself
    # introduced hides real drift behind a green gate.

    # ('mv', 'no directory-destination form') was HERE and is
    # DELETED, 2026-08-25 -- not re-ruled, FIXED. mv.s grew DSTRESOLV
    # and now implements the form: `mv SRC DIR` moves SRC into DIR,
    # `mv SRC DIR/` requires DIR to be a directory. cp.s carries the
    # same routine.
    #
    # The entry claimed the form was out of scope by design, citing
    # mv.s's own header. That header was the argument for keeping the
    # drift, not evidence that the drift was necessary -- ProDOS has
    # every primitive the operation needs, so it was AVOIDABLE, and
    # the rule is that maux IS Unix rather than Unix-like. The two
    # cases that cited this key (`mv A B/` with B absent, `mv A DIR`
    # with DIR an existing directory) now AGREE with the reference:
    # the first fails on both sides, the second succeeds on both.
    #
    # Worth recording about the shape: the intermediate fix, one day
    # earlier, refused a trailing slash unconditionally. That removed
    # the data-loss half (ProDOS resolves "B/" to "B" and CREATE makes
    # a plain file) but introduced NEW drift, because `mv A DIR/`
    # where DIR exists is something every Unix accepts. A refusal is
    # not automatically the safe answer; it is only safe when the host
    # refuses too.

    ('mv', 'ARGBUFSZ pathname cap has no host equivalent'): (
        'RULED',
        "TL RULING 2026-08-23: re-pinned here from DEFECTS onto "
        "status_ruled= -- this is a deliberate safety bound with a "
        "named cause, not a bug, and must not sit in the bug table. "
        "mv.s:87 `ARGBUFSZ equ 80` bounds SRCBUF/DSTBUF, and CPYARG "
        "(mv.s:174-187) refuses any argument >= ARGBUFSZ with exit 2 "
        "BEFORE any MLI call. The bound exists because of a real, fixed "
        "bug (mv.s:148-172's own comment): before 2026-08-22, mv called "
        "STRCPY raw with no length check, so an 80+ char argv[1] wrote "
        "its NUL onto DSTBUF+0 and an 81+ char one wrote real bytes "
        "there, losing SRCBUF's own terminator -- every later reader "
        "(LASTSLASH, SAMEDIR, TRYRENAME, COPYFILE, UNLINKSRC, the error "
        "printer) then saw the CONCATENATION of both arguments, so mv "
        "could 'open, copy and UNLINK a path the user never typed'. "
        "CPYARG's exit-2 refusal is what replaced that. No host mv has "
        "an equivalent length cap, so there is no invocation that makes "
        "the reference exit 2 too -- exempted via status_ruled=, cited "
        "on case 12 (MUT12) only; output is still compared byte-exact "
        "against 'mv: pathname too long' (mv.s:373-374's TOOLONG "
        "message) via the ordinary GLOBAL diagnostic-text mechanism."),
}

#: All four defects this module originally pinned here were FIXED in
#: src/bin/mv.s (commit 1ae0266) and src/bin/cp.s (commit e9b5dd7),
#: 2026-08-23 -- see each retired case's own note below for what the
#: fix now does and what the case asserts in place of the pin. DEFECTS
#: is empty, not removed: an empty dict here (rather than deleting the
#: name) keeps Registry.add_module's `getattr(mod, 'DEFECTS', {})`
#: lookup meaningful and documents that this module is the one that
#: HELD these four, not that it never had any.
#:
#: A FIFTH defect lived here too, from 2026-08-25 until later the same
#: day: ('mv', 'no cross-directory move for a directory SRC'). It was
#: pinned explicitly TWO-SIDED (its own text said so): "implement the
#: recursive copy and this case starts AGREEING with the reference,
#: which FAILS the gate and asks for this entry to be deleted." That
#: is exactly what happened. `mv` grew MOVEDIR/cptree.s (docs/CPTREE.md,
#: docs/RECURSIVE-MV.md) -- a recursive mirror-then-teardown for a
#: directory SRC crossing parents -- and `cp` grew `-r`/`-R` on the
#: same walk. `mut.mv-src-dir` (the explicit `mv DIR SUB/DIR` form) and
#: `mut.mv-dir-onto-existing-dir` (the implicit `mv DIR1 DIR2` form,
#: tree MUT26) both dropped `defect=`, gained real `ref_op`s and
#: `expect_types`, and now assert the tree the host produces. See each
#: case's own retirement note below for the mechanism (DSTRESOLV ->
#: MOVEDIR -> CPT_ISDESC/CPT_MKDIR/CPT_START/CPT_RMTREE) and for the
#: RED/GREEN teeth demonstration in the task report.
DEFECTS = {}

INVARIANTS = {}

#: Applies to every failure-path case's PRIMARY text assertion without
#: per-case citation -- CONTRACT sec 5.1's own GLOBALS field, same
#: pattern as scripts/e2e_divergence.GLOBAL_KEYS.
GLOBALS = {
    ('mutate', 'diagnostic message text'),
}
_GLOBALS_REASON = (
    "STRUCTURAL. rm.s/mv.s/cp.s/mkdir.s each print one fixed, short, "
    "custom diagnostic on failure ('rm: cannot unlink <path>', 'mv: "
    "cannot move <src>', 'cp: error', 'mkdir: cannot create <path>') "
    "that shares no wording, structure, or convention with GNU/BSD "
    "coreutils' messages. Comparing byte-exact against maux's OWN "
    "documented, deterministic format (computed here by _expect(), from "
    "the literal ERRMSG constants read out of each .s file, never from "
    "the host reference's bytes) is a REAL, strong assertion -- it "
    "would catch a wrong operand echoed, a missing/extra CR, a garbled "
    "prefix -- it is just not a comparison against POSIX wording, which "
    "would be meaningless here by design.")


# ======================================================================
# Expected-text formula (see GLOBALS entry above for why this exists).
# Populated once, at case-build time, keyed by cid; the comparator and
# synth() both read it so there is exactly one source of truth.
# ======================================================================
_EXPECT_TEXT = {}


def _expect_ok():
    return b''


def _expect_rm_fail(path):
    return f'rm: cannot unlink {path}\n'.encode()


def _expect_mkdir_fail(path):
    return f'mkdir: cannot create {path}\n'.encode()


def _expect_cp_fail():
    return b'cp: error\n'


def _expect_mv_multi_notdir():
    """mvtop.s's NOTDIRMSG ("mv: DST is not a directory", trailing CR
    via the separate PUTC), printed by the multi-form's up-front
    TGTISDIR gate."""
    return b'mv: DST is not a directory\n'


def _expect_cp_dir_fail():
    """cp.s's DIRMSG (cp.s:316, printed verbatim at :isdir, cp.s:212-
    220) -- NOT parameterised by the actual SRC path (unlike ERRMSG/
    TOOLONG elsewhere in this module), so this takes no argument."""
    return b'cp: SRC is a directory\n'


def _expect_mv_fail(src, errno=0x46):
    """mv.s's ERRMSG + SRCBUF + ERRNOMSG + PRHEX8(LASTERR) (TL commit
    cf744fc, 2026-08-23, merged into this stream mid-review): :failed
    now appends the raw MLI errno as two uppercase hex digits after
    the path -- this formula was STALE (missing the suffix entirely)
    until this review pass. errno=$46 default ('path not found', the
    real OPEN error for a genuinely missing SRC) verified against a
    real verilogapple (fast backend) run of the CURRENT mv.bin,
    2026-08-23, via an out-of-corpus isolation harness (this task's
    own -- the official check-e2e-fs gate is blocked by a pre-existing,
    unrelated hang, see the task report) -- covers cases 9 and 11
    unchanged. Callers with a DIFFERENT verified failure point (this
    review's own MUT25, $47 duplicate-pathname) pass their own value.
    """
    return f'mv: cannot move {src} errno=${errno:02X}\n'.encode()


#: _expect_mv_dir_fail() (mv.s's DIRMSG, "mv: SRC is a directory\n")
#: lived here and was DELETED 2026-08-25 once nothing called it any
#: more. `mut.mv-src-dir` and `mut.mv-dir-onto-existing-dir` were its
#: only two callers (see their retirement notes above) and both now
#: assert success instead of this refusal. The message itself is not
#: dead code -- COPYFILE's own :srcisdir check (mv.s ~line 564) still
#: exists and still prints DIRMSG -- but it is UNREACHABLE from mv's
#: normal argument flow: SRCISDIRF is tested in START, before COPYFILE
#: is ever called (mv.s:186-190 route a true directory SRC to MOVEDIR
#: instead), on every path that reaches COPYFILE at all (the SAMEDIR
#: success fallthrough on a failed TRYRENAME included -- it also
#: checks SRCISDIRF before falling to :docopy). DIRMSG's guard survives
#: only as a defence-in-depth backstop against a future caller that
#: reaches COPYFILE with SRCISDIRF never set; this corpus has no way to
#: construct that argv (nor should it try to -- see this module's rule
#: against manufacturing shapes mv itself cannot reach).
def _expect_mv_toolong():
    return b'mv: pathname too long\n'


def _expect_mv_notempty():
    """mv.s's NOTEMPTMSG (mv.s ~line 970: `asc "mv: DST is not empty"` /
    `dfb $8D,$00` -- the $8D is BAKED INTO the literal, unlike ERRMSG/
    NOTDIRMSG/DIRMSG above), printed by MOVEDIR's :dstdir/DSTEMPTY
    branch (mv.s ~line 922-931) via a single PUTS with NO separate
    PUTC $8D -- confirmed by reading both the message table and the
    print site, not by pattern-matching the other _expect_mv_* helpers
    that DO need a trailing PUTC. Not parameterised by SRC/DST (same
    convention as DIRMSG/SELFMSG/DEEPMSG above)."""
    return b'mv: DST is not empty\n'


def _expect_mv_self():
    """mv.s's SELFMSG (mv.s ~line 972: `asc "mv: cannot move a
    directory into itself"` / `dfb $8D,$00`, $8D baked in same as
    NOTEMPTMSG), printed by MOVEDIR's CPT_ISDESC guard (mv.s ~line
    879-888) via PUTS alone, no separate PUTC."""
    return b'mv: cannot move a directory into itself\n'


# ======================================================================
# Cases.
# ======================================================================
def cases(add):
    # ---- rm --------------------------------------------------------
    t = _T(1)
    c = add('rm', case_id='mut.rm-one', argv=[_p(t, 'FILEA')],
            oracle='REF', compare='diag',
            tree=t, poststate=True,
            ref_op=lambda d: os.remove(os.path.join(d, 'FILEA')),
            note='rm one file')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(2)
    c = add('rm', case_id='mut.rm-several',
            argv=[_p(t, 'A'), _p(t, 'B'), _p(t, 'C')],
            oracle='REF', compare='diag', tree=t, poststate=True,
            ref_op=lambda d: [os.remove(os.path.join(d, n))
                              for n in ('A', 'B', 'C')],
            note='rm several files')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(3)
    c = add('rm', case_id='mut.rm-nosuch', argv=[_p(t, 'NOSUCH')],
            oracle='REF', compare='diag',
            tree=t, poststate=True, ref_op=lambda d: None,
            note='rm a nonexistent file; KEEP proves nothing else moved')
    _EXPECT_TEXT[c] = _expect_rm_fail(_p(t, 'NOSUCH'))

    t = _T(4)
    c = add('rm', case_id='mut.rm-empty-dir', argv=[_p(t, 'SUBDIR')],
            oracle='REF', compare='diag',
            ref_argv=['-d', _p(t, 'SUBDIR')], tree=t, poststate=True,
            ref_op=lambda d: os.rmdir(os.path.join(d, 'SUBDIR')),
            diverges=[('rm', 'DESTROY succeeds on a directory operand')],
            note='rm an EMPTY directory -- the DESTROY divergence')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(5)
    # MEASURED 2026-08-24, and it went the other way. This case was
    # written asking the reference `rm -r` and expecting maux to delete
    # the tree silently, on the [reported]-grade guess that DESTROY
    # recurses. It does not: ProDOS 8 DESTROY REFUSES a non-empty
    # subdirectory with $4E, so maux prints its own diagnostic and
    # exits 1 -- which is what POSIX `rm` with no -r does too. The two
    # sides AGREE here, so the reference is asked the equivalent
    # question (plain `rm`, no flag, nothing removed) and this case
    # stops citing the DESTROY divergence altogether. Only the empty-
    # directory case above still diverges. See the ENTRIES reason,
    # corrected in the same pass.
    c = add('rm', case_id='mut.rm-nonempty-dir',
            argv=[_p(t, 'SUBDIR')], oracle='REF', compare='diag',
            tree=t, poststate=True, ref_op=lambda d: None,
            note='rm a NON-EMPTY directory -- ProDOS DESTROY refuses '
                 'it ($4E), exactly as POSIX rm without -r does; '
                 'SUBDIR and its contents must survive on both sides')
    _EXPECT_TEXT[c] = _expect_rm_fail(_p(t, 'SUBDIR'))

    # ---- mv ----------------------------------------------------------
    t = _T(6)
    c = add('mv', case_id='mut.mv-rename',
            argv=[_p(t, 'OLDNAME'), _p(t, 'NEWNAME')],
            oracle='REF', compare='diag', tree=t, poststate=True,
            ref_op=lambda d: os.rename(os.path.join(d, 'OLDNAME'),
                                       os.path.join(d, 'NEWNAME')),
            # E8, 2026-08-23: NEWNAME is a post-mutation path that never
            # appears in MUT_TREES -- types_for_tree() alone hands it
            # type=None. NEWNAME must carry the type OLDNAME had before
            # the rename (RENAME does not touch file_type at all, per
            # this module's own DEFECTS note on the asymmetry with the
            # copy path below).
            expect_types={'NEWNAME': ('from', 'OLDNAME')},
            note='mv within a directory -- the RENAME path')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(7)
    c = add('mv', case_id='mut.mv-cross-dir',
            argv=[_p(t, 'SRC/DOC'), _p(t, 'DST/DOC')],
            oracle='REF', compare='diag', tree=t, poststate=True,
            ref_op=lambda d: shutil.move(os.path.join(d, 'SRC', 'DOC'),
                                         os.path.join(d, 'DST', 'DOC')),
            # FIXED 2026-08-23 (mv.s commit 1ae0266): COPYFILE now
            # SC_GFI-stats SRC and patches CRPARM_FTYP/CRPARM_AUX
            # before CREATE, same pattern cp.s already used -- see
            # e2e_fs_mutate.py's module docstring for the pre-fix
            # finding this case caught. DST/DOC never appears in
            # MUT_TREES (it is created by this case's own mutation), so
            # without expect_types the tree comparator's type check
            # would be SKIPPED entirely and this case would pass
            # vacuously on stdout alone (both diag text AND type check
            # are real assertions now, not just the former). The
            # expectation is not authored: it is "the type SRC/DOC had
            # before the move", i.e. TXT ($04) -- a still-buggy mv
            # (hardcoded BIN $06) would fail this poststate check
            # immediately; see the retirement proof in the task report
            # for the accept/reject demonstration.
            expect_types={'DST/DOC': ('from', 'SRC/DOC')},
            note='mv across directories -- the copy path. DOC is TXT '
                 '($04) on SRC and must arrive TXT on DST too -- '
                 "checked by the poststate tree comparator's type "
                 "check (expect_types), not by this case's stdout, "
                 'which is silent on success either way')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(8)
    c = add('mv', case_id='mut.mv-over-existing',
            argv=[_p(t, 'A'), _p(t, 'B')], oracle='REF',
            compare='diag', tree=t, poststate=True,
            ref_op=lambda d: os.replace(os.path.join(d, 'A'),
                                        os.path.join(d, 'B')),
            # FIXED 2026-08-23 (mv.s commit 1ae0266): COPYFILE now
            # checks SC_CREAT's carry; on a duplicate-pathname failure
            # (DST already exists) it DESTROYs DST and retries CREATE
            # once, replacing DST cleanly instead of falling through to
            # SC_OPEN on the stale entry at offset 0 with no truncate.
            # SAMEDIR (mv.s) is a pure directory-PREFIX compare, and
            # A/B share one -- so TRYRENAME is attempted first, same as
            # case 6, and RENAME onto an existing name is refused by
            # ProDOS (duplicate pathname), so this case's DST goes
            # through the SAME (now-fixed) COPYFILE routine as case 7's
            # cross-directory move. B is staged 94 bytes LONGER than
            # A's replacement content specifically so a non-truncating
            # overwrite (the old bug) would leave B's trailing bytes
            # behind, visible to the poststate byte comparison -- the
            # size/content check IS the real assertion here, since
            # stdout is silent on success either way. expect_types
            # asserts B carries A's type post-move (the fix's destroy-
            # then-recreate path also patches CRPARM_FTYP, same as case
            # 7). T4 REVIEW (2026-08-23): MUT_TREES[_T(8)] now pins B's
            # PRE-move type to FTYPE_BIN explicitly -- before this, A
            # ('text') and B ('raw') both defaulted to TXT ($04) via
            # e2e_fsmap.DEFAULT_FILE_TYPE, so "B keeps its own type" and
            # "B acquires A's type" were the SAME observed byte, and a
            # buggy mv that never touched B's type at all would still
            # have passed this assertion by coincidence -- exactly the
            # vacuity the review flagged and fixed at its root in case
            # 15 (T4 DEFECT 3). Now the type check is real too, not
            # just the size/content one.
            expect_types={'B': ('from', 'A')},
            note='mv onto an existing name; A=6B, B=100B (94B longer) '
                 "so B's full 100 bytes must be REPLACED by A's 6-byte "
                 'content, not partially overwritten -- the poststate '
                 "byte comparison is this case's real assertion, "
                 'stdout stays empty on success either way')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(9)
    c = add('mv', case_id='mut.mv-nosuch-src',
            argv=[_p(t, 'NOSUCH'), _p(t, 'DST')], oracle='REF',
            compare='diag', tree=t, poststate=True, ref_op=lambda d: None,
            note='mv a nonexistent source; KEEP proves nothing moved')
    _EXPECT_TEXT[c] = _expect_mv_fail(_p(t, 'NOSUCH'))

    t = _T(10)
    c = add('mv', case_id='mut.mv-dir-form',
            argv=[_p(t, 'A'), _p(t, 'B') + '/'], oracle='REF',
            compare='diag', tree=t, poststate=True, ref_op=lambda d: None,
            note='mv A B/ -- B is deliberately NOT staged (see the '
                 'ENTRIES reason on why this only tests the FORM, not '
                 'the full into-an-existing-directory semantics); A '
                 'must survive per mv.s\'s own non-atomicity guarantee '
                 '(mv.s:55-58: unlink only after a clean copy)')
    # A trailing slash is POSIX's assertion that DST already IS a
    # directory, so with B absent BOTH sides fail and this case is no
    # longer a divergence at all -- it lost its citation. mv.s's
    # DSTRESOLV stats the directory, does not find it, and reports the
    # MLI errno through the ordinary :failed path ($46, file not
    # found); /bin/mv fails too ("No such file or directory", exit 1).
    # Only the wording differs, which sec 9.7 already excludes.
    _EXPECT_TEXT[c] = _expect_mv_fail(_p(t, 'A'))

    # E7 integration fix, 2026-08-23: both cases below pad DST out to
    # (near) ARGBUFSZ, which is the load-bearing boundary and must not
    # move -- but with a 6-char 'NOSUCH' SRC, the resulting sh script
    # LINE (MV SRC DST > /mnt/MAUX/OUT/Onn 2>&1) exceeds sh.s's own
    # LINEMAX (127), a failure that only build_e2efs_image.py's real
    # script generation surfaces (e2e_fs_selftest.py never calls
    # Case.sh_line() at all). SRC's own spelling is not the boundary
    # under test (DST's LENGTH is), so it is shortened to 'X' -- still
    # a nonexistent name in MUT11/MUT12's empty fixture trees, freeing
    # exactly the bytes needed with no change to what either case
    # proves.
    t = _T(11)
    fits_dst = _padpath(_p(t), ARGBUFSZ - 1)
    c = add('mv', case_id='mut.mv-argbuf-fits',
            argv=[_p(t, 'X'), fits_dst], oracle='REF',
            compare='diag', tree=t, poststate=True, ref_op=lambda d: None,
            note=f'ARGBUFSZ boundary, FITS ({ARGBUFSZ - 1} bytes): '
                 f'CPYARG passes, falls through to an ordinary '
                 f'nonexistent-source failure')
    _EXPECT_TEXT[c] = _expect_mv_fail(_p(t, 'X'))

    t = _T(12)
    toolong_dst = _padpath(_p(t), ARGBUFSZ)
    c = add('mv', case_id='mut.mv-argbuf-toolong',
            argv=[_p(t, 'X'), toolong_dst], oracle='REF',
            compare='diag', tree=t, poststate=True, ref_op=lambda d: None,
            status_ruled=('mv', 'ARGBUFSZ pathname cap has no host '
                                 'equivalent'),
            note=f'ARGBUFSZ boundary, TOO LONG ({ARGBUFSZ} bytes): '
                 f'CPYARG refuses before any MLI call, exit 2 -- TL '
                 f'ruling 2026-08-23: status_ruled=, not defect= (see '
                 f'the ENTRIES reason). Output is still compared in '
                 f'full: only the exit-status equality check is '
                 f'exempted.')
    _EXPECT_TEXT[c] = _expect_mv_toolong()

    # T4 REVIEW DEFECT 1 corpus gap (2026-08-23): mv's SRC-is-a-
    # directory case was entirely missing from this module -- the
    # review's own finding. SUB is a real directory, forcing the move
    # CROSS-directory (SAMEDIR compares path PREFIXES: MUT24/SRCDIR vs
    # MUT24/SUB/SRCDIR do not match), landing in COPYFILE -- the exact
    # routine defect 1 lived in, not the RENAME path (which never
    # opens SRC and so could never hit this bug).
    # RETIRED 2026-08-25 -- this case used to be PINNED to
    # ('mv', 'no cross-directory move for a directory SRC') (DEFECTS,
    # deleted the same day; see that dict's own retirement comment).
    # Before the fix, T4 DEFECT 1 meant a directory SRC had to be
    # REJECTED (COPYFILE's GFIPARM_STYP check, right after SC_GFI) --
    # there was no recursive-copy code at all, so rejecting was the
    # only safe answer. Now there is: SRCISDIRF is checked in START's
    # own flow BEFORE COPYFILE is ever reached (see mv.s:186-190), and
    # a true directory SRC goes to MOVEDIR -> cptree.s's mirror-then-
    # teardown walk instead. This case now asserts the walk actually
    # ran: SRCDIR is gone (UNLINKSRC's target, torn down bottom-up by
    # CPT_RMTREE) and SUB/SRCDIR/INSIDE exists with SRCDIR/INSIDE's
    # original bytes and type -- the poststate comparator raises if
    # the new path's kind/type were left undeclared, so expect_types
    # is the real assertion here, same as it was for the once-missing
    # cross-directory FILE case (mut.mv-cross-dir, case 7).
    t = _T(24)
    c = add('mv', case_id='mut.mv-src-dir',
            argv=[_p(t, 'SRCDIR'), _p(t, 'SUB/SRCDIR')],
            oracle='REF', compare='diag', tree=t, poststate=True,
            ref_op=lambda d: shutil.move(os.path.join(d, 'SRCDIR'),
                                         os.path.join(d, 'SUB', 'SRCDIR')),
            expect_types={'SUB/SRCDIR/INSIDE': ('from', 'SRCDIR/INSIDE')},
            note='mv a directory SRC across directories, DST absent -- '
                 'the explicit cross-directory form. DSTRESOLV leaves '
                 "SUB/SRCDIR unresolved (it does not exist), SAMEDIR's "
                 'prefix compare disagrees (root vs root/SUB/), so '
                 'START routes to MOVEDIR: CPT_MKDIR creates SUB/SRCDIR, '
                 'CPT_START mirrors INSIDE into it, CPT_RMTREE removes '
                 'the original SRCDIR bottom-up. SRCDIR must be GONE '
                 'post-mutation and SUB/SRCDIR/INSIDE must carry '
                 "SRCDIR/INSIDE's own type -- both checked by the "
                 'poststate tree comparator, not by stdout, which stays '
                 'empty on success either way')
    _EXPECT_TEXT[c] = _expect_ok()

    # T4 REVIEW DEFECT 2 concrete scenario (2026-08-23): `mv FILE
    # EXISTING_EMPTY_DIR`. DIR is a real, EMPTY subdirectory sharing
    # A's own directory prefix -- SAMEDIR is true, so TRYRENAME is
    # attempted first and refused by ProDOS as a duplicate pathname
    # (verified: RENAME onto an existing directory-typed target
    # fails), falling to COPYFILE -- CREATE then fails $47 for the
    # same duplicate-pathname reason, which is exactly the errno the
    # pre-fix blind DESTROY treated as "go ahead and delete it". A
    # real EMPTY subdirectory satisfies ProDOS DESTROY too (P8 TRM
    # 4.4.2), which is what made that blind destroy dangerous.
    t = _T(25)
    c = add('mv', case_id='mut.mv-onto-empty-dir',
            argv=[_p(t, 'A'), _p(t, 'DIR')], oracle='REF',
            compare='diag', tree=t, poststate=True,
            ref_op=lambda d: shutil.move(os.path.join(d, 'A'),
                                         os.path.join(d, 'DIR', 'A')),
            # A lands INSIDE DIR keeping its own ProDOS type -- the
            # same 'from' provenance the cross-directory mv case uses,
            # and it is what makes the poststate check assert the file
            # arrived rather than merely that something did.
            expect_types={'DIR/A': ('from', 'A')},
            note='mv a file onto an EXISTING EMPTY DIRECTORY -- T4 '
                 'DEFECT 2\'s own concrete scenario: DIR must be '
                 'REFUSED (this task\'s ruling: refuse, not move-into) '
                 'rather than DESTROYed and replaced by A; both DIR '
                 '(still a directory) and A (still present) must '
                 'survive untouched (poststate) -- the pre-fix blind '
                 'destroy-on-any-CREATE-failure silently deleted DIR '
                 'and recreated it as a plain file containing A\'s '
                 'bytes')
    # NO LONGER A FAILURE, and no longer a divergence. mv.s's
    # DSTRESOLV (2026-08-25) implements the Unix directory-destination
    # form: DST names an existing directory, so DST is rewritten to
    # DIR/basename(SRC) and the move succeeds silently, exit 0 -- the
    # same thing /bin/mv does, which is why the ref_op above now
    # performs the move instead of asserting nothing happened. The
    # ruling this case used to carry ('refuse, not move-into') was
    # avoidable semantic drift: the operation costs nothing ProDOS
    # cannot do, and a shell line that moves a file into a directory
    # must not mean two different things on the two systems.
    _EXPECT_TEXT[c] = _expect_ok()

    # RETIRED 2026-08-25 -- the implicit twin of mut.mv-src-dir above,
    # and the one the task's own DEFECTS entry called "the likelier
    # accident" (a script that has always worked starts failing the
    # day DIR2 happens to exist). Same DEFECTS entry, same day, same
    # fix. DSTRESOLV now sees DIR2 exists and IS a directory and
    # rewrites DST to DIR2/DIR1 -- previously that rewrite was exactly
    # what made this land in COPYFILE's directory-SRC refusal; now
    # SRCISDIRF sends it to MOVEDIR before COPYFILE is ever reached.
    # MOVEDIR's own CPT_ISDESC guard confirms DIR2/DIR1 is not DIR1 nor
    # beneath it, stats DIR2/DIR1 (absent), and mirrors + tears down
    # exactly as the explicit form does.
    t = _T(26)
    c = add('mv', case_id='mut.mv-dir-onto-existing-dir',
            argv=[_p(t, 'DIR1'), _p(t, 'DIR2')], oracle='REF',
            compare='diag', tree=t, poststate=True,
            ref_op=lambda d: shutil.move(os.path.join(d, 'DIR1'),
                                         os.path.join(d, 'DIR2', 'DIR1')),
            expect_types={'DIR2/DIR1/INSIDE': ('from', 'DIR1/INSIDE')},
            note='mv DIR1 DIR2 with DIR2 ALREADY PRESENT -- the '
                 'IMPLICIT move-into form. DIR1 must be GONE post-'
                 'mutation and DIR2/DIR1/INSIDE must exist carrying '
                 "DIR1/INSIDE's own type -- the SAME shell line with "
                 'DIR2 absent is a rename (mut.mv-rename-style, already '
                 'covered) and maux got that half right from the start; '
                 'this is the half that used to depend on the state of '
                 'the volume rather than the command, and now agrees '
                 'with the host on both halves')
    _EXPECT_TEXT[c] = _expect_ok()

    # 2026-08-25, docs/RECURSIVE-MV.md/docs/CPTREE.md's own corpus
    # brief: the two cases just retired only ever moved a directory
    # ONE level deep (SRCDIR/INSIDE, DIR1/INSIDE) -- neither can tell
    # a walk that forgets its place after the first subdirectory apart
    # from a correct one, because there is no second entry left at
    # that level to prove the walk came BACK. These four cover what
    # they structurally could not.
    t = _T(27)
    c = add('mv', case_id='mut.mv-recursive-two-level',
            argv=[_p(t, 'SRC'), _p(t, 'DEST')], oracle='REF',
            compare='diag', tree=t, poststate=True,
            ref_op=lambda d: shutil.move(os.path.join(d, 'SRC'),
                                         os.path.join(d, 'DEST', 'SRC')),
            expect_types={'DEST/SRC/F1': ('from', 'SRC/F1'),
                          'DEST/SRC/SUB/F2': ('from', 'SRC/SUB/F2'),
                          'DEST/SRC/F3': ('from', 'SRC/F3')},
            note='mv a TWO-LEVEL tree across parents, DEST an existing '
                 'empty directory (the move-into branch): SRC/F1, '
                 'SRC/SUB/F2 and SRC/F3 must all land under DEST/SRC '
                 'with their own types, and F3 -- staged AFTER SUB -- '
                 "proves the walk resumed SRC's own directory rather "
                 'than stopping once it returned from SUB; SRC itself '
                 'must be GONE')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(28)
    c = add('mv', case_id='mut.mv-recursive-two-subdirs',
            argv=[_p(t, 'SRC'), _p(t, 'DEST')], oracle='REF',
            compare='diag', tree=t, poststate=True,
            ref_op=lambda d: shutil.move(os.path.join(d, 'SRC'),
                                         os.path.join(d, 'DEST')),
            expect_types={'DEST/SUBA/FA': ('from', 'SRC/SUBA/FA'),
                          'DEST/SUBB/FB': ('from', 'SRC/SUBB/FB')},
            note='mv a directory holding TWO SUBDIRECTORIES across '
                 'parents, DEST absent (the plain-rename branch through '
                 'MOVEDIR, CPT_MKDIR creating DEST fresh): both SUBA/FA '
                 'and SUBB/FB must land under DEST with their own '
                 'types. This is the resume-counter shape -- '
                 "CPT_SKIPN vs CPT_RESN, docs/CPTREE.md's own citation "
                 'of the find.s bug that looped forever over exactly '
                 'this tree shape (find.s:704-714) -- and a '
                 'transplanted version of that bug was demonstrated to '
                 'make cptree hang/mis-walk on this same case during '
                 'this session; see the RED/GREEN teeth proof in the '
                 'task report')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(29)
    c = add('mv', case_id='mut.mv-dst-notempty',
            argv=[_p(t, 'DIR'), _p(t, 'DEST')], oracle='REF',
            compare='diag', tree=t, poststate=True, ref_op=lambda d: None,
            note='mv DIR DEST where DEST/DIR already exists and is '
                 'NON-EMPTY -- DSTRESOLV rewrites DST to DEST/DIR, '
                 "MOVEDIR's DSTEMPTY finds OTHER still in it and "
                 'refuses (docs/CPTREE.md sec 1\'s table: mv demands an '
                 "EMPTY existing directory; cp -r's DIFFERENT answer "
                 'here is _T(33)/mut.cp-r-merge below). Nothing moves: '
                 'DIR/INSIDE and DEST/DIR/OTHER must both survive '
                 'untouched -- the host says "Directory not empty" for '
                 'the same reason')
    _EXPECT_TEXT[c] = _expect_mv_notempty()

    t = _T(30)
    c = add('mv', case_id='mut.mv-into-own-subtree',
            argv=[_p(t, 'DIR'), _p(t, 'DIR/SUB')], oracle='REF',
            compare='diag', tree=t, poststate=True, ref_op=lambda d: None,
            note='mv DIR DIR/SUB -- moving a directory into its own '
                 'subtree. SUB is deliberately UNSTAGED: CPT_ISDESC '
                 'only compares the two PATHS (DIR is a strict prefix '
                 'of DIR/SUB, ending at a "/") and must refuse before '
                 'DSTRESOLV/MOVEDIR ever stat anything under DIR. DIR '
                 'and INSIDE must both survive untouched')
    _EXPECT_TEXT[c] = _expect_mv_self()

    # ---- cp ------------------------------------------------------------
    t = _T(13)
    c = add('cp', case_id='mut.cp-file',
            argv=[_p(t, 'A'), _p(t, 'COPY')], oracle='REF',
            compare='diag', tree=t, poststate=True,
            ref_op=lambda d: shutil.copy2(os.path.join(d, 'A'),
                                          os.path.join(d, 'COPY')),
            # E8, 2026-08-23: COPY is a new post-mutation path -- was
            # type=None (unchecked) before this pass. NOTE (see report):
            # this fixture's own 'BIN fixture' label is aspirational,
            # not actual -- e2e_fsmap.unpack_fixture_spec's DEFAULT_
            # FILE_TYPE (TXT $04) applies regardless of kind='raw' vs
            # 'text' unless a case's fixture spec sets meta['file_type']
            # explicitly, which this one does not. COPY is therefore
            # expected to be TXT here too, same as A -- correctly, since
            # cp preserves type either way; the label is stale from
            # before E1's real spine existed (see this module's own
            # ASSUMED SPINE docstring), not a bug in cp.
            expect_types={'COPY': ('from', 'A')},
            note='cp a file (BIN fixture, distinct from the type-'
                 'preservation case below)')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(14)
    c = add('cp', case_id='mut.cp-preserve-type',
            argv=[_p(t, 'A'), _p(t, 'COPY')], oracle='REF',
            compare='diag', tree=t, poststate=True,
            ref_op=lambda d: shutil.copy2(os.path.join(d, 'A'),
                                          os.path.join(d, 'COPY')),
            # E8, 2026-08-23: same gap as case 13 -- COPY was type=None.
            expect_types={'COPY': ('from', 'A')},
            note='cp preserving file_type: A is TXT, COPY must arrive '
                 'TXT too (cp.s\'s SC_GFI stat -- cp.s:121-131) -- this '
                 'is the case that proves cp does NOT have mv\'s bug')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(15)
    c = add('cp', case_id='mut.cp-over-existing',
            argv=[_p(t, 'A'), _p(t, 'B')], oracle='REF',
            compare='diag', tree=t, poststate=True,
            ref_op=lambda d: shutil.copy2(os.path.join(d, 'A'),
                                          os.path.join(d, 'B')),
            # FIXED 2026-08-23 (cp.s commit e9b5dd7, T4 DEFECT 1): on
            # CREATE failing with ERR_DUPFN ($47, DST already exists),
            # cp no longer treats CREATE's carry as unconditionally
            # fatal. 'B' pre-exists and is LONGER than A's replacement
            # content (see MUT_TREES[_T(15)]: A=4 bytes text "new\n",
            # B=80 bytes raw) so a non-truncating/non-replacing
            # overwrite would leave B's stale trailing bytes behind,
            # visible to the poststate byte comparison -- that
            # size/content check, not stdout (empty on success either
            # way), is one of this case's assertions.
            #
            # T4 REVIEW FIX (2026-08-23, DEFECT 3): the ORIGINAL fix
            # (SC_SETEOF-truncate DST in place after OPEN) left this
            # case's OWN expect_types VACUOUS -- CREATE is the only
            # MLI call that sets file_type/aux_type and never touches
            # an EXISTING entry, so truncating in place could not also
            # carry A's type onto B, and MUT_TREES[_T(15)]'s B used to
            # default to the SAME TXT type as A (e2e_fsmap.
            # DEFAULT_FILE_TYPE), so a cp that left B's type untouched
            # still passed. Two changes close this: cp.s now destroys
            # DST and retries CREATE (mv.s's own mechanism) so the
            # type patch actually applies, and B's meta now pins
            # file_type=FTYPE_BIN so "B kept BIN" and "B became TXT"
            # are DISTINGUISHABLE outcomes -- see the RED/GREEN
            # demonstration in the task report.
            expect_types={'B': ('from', 'A')},
            note='cp over an existing (longer, differently-typed) '
                 "file -- must be fully replaced by A's content AND "
                 "A's type, not partially overwritten or left BIN; "
                 'the poststate byte+type comparison is this case\'s '
                 'real assertion')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(16)
    c = add('cp', case_id='mut.cp-nosuch-src',
            argv=[_p(t, 'NOSUCH'), _p(t, 'DST')], oracle='REF',
            compare='diag', tree=t, poststate=True, ref_op=lambda d: None,
            note='cp a nonexistent source')
    _EXPECT_TEXT[c] = _expect_cp_fail()

    t = _T(17)
    c = add('cp', case_id='mut.cp-src-dir',
            argv=[_p(t, 'SRCDIR'), _p(t, 'DSTDIR')], oracle='REF',
            compare='diag',
            tree=t, poststate=True,
            ref_op=lambda d: None,
            # FIXED 2026-08-23 (cp.s commit e9b5dd7): cp now tests
            # GFIPARM_STYP against STYP_DIR ($0D) and the volume-dir
            # storage_type ($0F) BEFORE any CREATE/OPEN of DST, prints
            # "cp: SRC is a directory" to stderr, and exits 1 -- SRC is
            # left untouched and DST is never created at all (no
            # garbled file, no misleadingly-typed entry). ref_op is now
            # a no-op: the correct maux behaviour REJECTS the copy, so
            # nothing should exist under DST post-mutation -- the same
            # 'nothing moved/copied' shape this module's own nonexistent-
            # source cases (9, 16) already use. compare stays 'diag'
            # (this case's real assertion is now text + poststate
            # together): _expect_cp_dir_fail() below is maux's own
            # documented rejection message, and expect_types is DROPPED
            # (there is no DSTDIR/INSIDE to check the type of -- DSTDIR
            # itself must not exist post-mutation, which poststate=True
            # checks via 'missing' rather than via a type field).
            note='cp a directory -- now REJECTED before any CREATE/OPEN '
                 'of DST; DSTDIR must not exist afterward (poststate), '
                 'not just print the right diagnostic; -r asked of the '
                 'reference only to align exit status (DISCHARGED-'
                 'style), NOT because maux implements -r semantics')
    _EXPECT_TEXT[c] = _expect_cp_dir_fail()
    # `cp DIR DEST` WITHOUT -r must still be refused -- a regression
    # guard docs/RECURSIVE-MV.md/docs/CPTREE.md both call out
    # explicitly now that `-r` exists as a real flag choice. This IS
    # that case, unchanged since 2026-08-23: argv above carries no
    # '-r', RFLAG is never set, so `:dstok`'s `lda RFLAG / beq :notrec`
    # falls straight to the plain single-file path and hits the SAME
    # SRCISDIRF/DIRMSG refusal as always. No new case added for item
    # (h) of the recursive-mv/cp-r corpus brief -- this one already
    # covers it.

    # 2026-08-25, docs/CPTREE.md sec 1's `cp -r` table and sec 6's own
    # corpus brief: `cp -r`'s three genuinely distinct destination
    # shapes (absent, existing-empty, existing-non-empty-i.e.-MERGE),
    # none of which cp could even attempt before this session (`cp`
    # had no -r at all).
    t = _T(31)
    c = add('cp', case_id='mut.cp-r-new-dest',
            argv=['-r', _p(t, 'DIR'), _p(t, 'DEST')], oracle='REF',
            compare='diag', tree=t, poststate=True,
            ref_op=lambda d: shutil.copytree(os.path.join(d, 'DIR'),
                                             os.path.join(d, 'DEST')),
            expect_types={'DEST/INSIDE': ('from', 'DIR/INSIDE')},
            note='cp -r DIR DEST, DEST absent: DEST becomes a fresh '
                 "copy of DIR's contents (not DEST/DIR -- DSTRESOLV "
                 "leaves an absent DST untouched, same as mv's rename "
                 'branch). Unlike every mv case in this corpus, DIR '
                 'itself -- and DIR/INSIDE -- must SURVIVE: cp never '
                 'unlinks its source')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(32)
    c = add('cp', case_id='mut.cp-r-into-existing-dir',
            argv=['-r', _p(t, 'DIR'), _p(t, 'DEST')], oracle='REF',
            compare='diag', tree=t, poststate=True,
            ref_op=lambda d: shutil.copytree(
                os.path.join(d, 'DIR'), os.path.join(d, 'DEST', 'DIR')),
            expect_types={'DEST/DIR/INSIDE': ('from', 'DIR/INSIDE')},
            note='cp -r DIR DEST, DEST an EXISTING EMPTY directory: '
                 'DSTRESOLV rewrites DST to DEST/DIR (the same '
                 'move-into resolution mv uses), COPYDIR mirrors into '
                 'it. DIR (and DIR/INSIDE) survive -- the only '
                 "difference from mv's own onto-existing-dir case "
                 '(mut.mv-dir-onto-existing-dir) is that SRC is not '
                 'torn down afterward')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(33)
    c = add('cp', case_id='mut.cp-r-merge',
            argv=['-r', _p(t, 'DIR'), _p(t, 'DEST')], oracle='REF',
            compare='diag', tree=t, poststate=True,
            ref_op=lambda d: shutil.copy2(
                os.path.join(d, 'DIR', 'INSIDE'),
                os.path.join(d, 'DEST', 'DIR', 'INSIDE')),
            expect_types={'DEST/DIR/INSIDE': ('from', 'DIR/INSIDE')},
            note='cp -r DIR DEST where DEST/DIR already EXISTS and is '
                 "NON-EMPTY -- the ONE place cp -r's and mv's answers "
                 "genuinely differ (mv refuses this exact shape at "
                 "mut.mv-dst-notempty above; cp -r MERGES), measured "
                 'against /bin/cp and /bin/mv on 2026-08-25, not '
                 "drift. CPT_MKDIR's duplicate-name-that-IS-a-directory "
                 "case is success, so COPYDIR mirrors INSIDE into "
                 'DEST/DIR alongside its own pre-existing OTHER, which '
                 'must SURVIVE (a destroy-and-recreate merge, rather '
                 'than a true merge, would silently lose it -- the '
                 'poststate comparator would flag OTHER as missing)')
    _EXPECT_TEXT[c] = _expect_ok()

    # ---- mkdir ---------------------------------------------------------
    t = _T(18)
    c = add('mkdir', case_id='mut.mkdir-one',
            argv=[_p(t, 'NEWDIR')], oracle='REF', compare='diag',
            tree=t, poststate=True,
            ref_op=lambda d: os.mkdir(os.path.join(d, 'NEWDIR')),
            note='mkdir one')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(19)
    c = add('mkdir', case_id='mut.mkdir-several',
            argv=[_p(t, 'D1'), _p(t, 'D2'), _p(t, 'D3')],
            oracle='REF', compare='diag', tree=t, poststate=True,
            ref_op=lambda d: [os.mkdir(os.path.join(d, n))
                              for n in ('D1', 'D2', 'D3')],
            note='mkdir several')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(20)
    c = add('mkdir', case_id='mut.mkdir-existing',
            argv=[_p(t, 'EXIST')], oracle='REF', compare='diag',
            tree=t, poststate=True, ref_op=lambda d: None,
            note='mkdir an existing name (EXIST is a plain file -- '
                 'either shape of collision must fail)')
    _EXPECT_TEXT[c] = _expect_mkdir_fail(_p(t, 'EXIST'))

    t = _T(21)
    c = add('mkdir', case_id='mut.mkdir-no-parent',
            argv=[_p(t, 'NOPARENT/CHILD')], oracle='REF',
            compare='diag', tree=t, poststate=True, ref_op=lambda d: None,
            note='mkdir a nested path whose parent is missing -- no -p')
    _EXPECT_TEXT[c] = _expect_mkdir_fail(_p(t, 'NOPARENT/CHILD'))

    t = _T(22)
    name15 = 'ABCDEFGHIJKLMNO'
    name14 = 'PQRSTUVWXYZABC'
    assert len(name15) == 15 and len(name14) == 14
    c = add('mkdir', case_id='mut.mkdir-name-boundary',
            argv=[_p(t, name15), _p(t, name14)], oracle='REF',
            compare='diag', tree=t, poststate=True,
            ref_op=lambda d: [os.mkdir(os.path.join(d, n))
                              for n in (name15, name14)],
            note='the 15-char/14-char ProDOS name-length boundary, both '
                 'legal and both must succeed')
    _EXPECT_TEXT[c] = _expect_ok()

    # ---- mkdir -p (POSIX -p, 2026-09-13) ------------------------------
    t = _T(43)
    c = add('mkdir', case_id='mut.mkdir-p-nested',
            argv=['-p', _p(t, 'NEWA/NEWB/NEWC')], oracle='REF',
            compare='diag', tree=t, poststate=True,
            ref_op=lambda d: os.makedirs(
                os.path.join(d, 'NEWA', 'NEWB', 'NEWC')),
            note='mkdir -p NEWA/NEWB/NEWC creates all three missing '
                 'intermediates plus the leaf')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(44)
    c = add('mkdir', case_id='mut.mkdir-p-existing-dir',
            argv=['-p', _p(t, 'EXISTD')], oracle='REF',
            compare='diag', tree=t, poststate=True,
            ref_op=lambda d: None,
            note='mkdir -p on an already-existing DIRECTORY leaf is '
                 'success, silent, tree unchanged (os.makedirs would '
                 'also no-op here; ref_op is a no-op directly since '
                 'EXISTD is already staged)')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(45)
    c = add('mkdir', case_id='mut.mkdir-p-partial',
            argv=['-p', _p(t, 'PARENT/CHILD')], oracle='REF',
            compare='diag', tree=t, poststate=True,
            ref_op=lambda d: os.mkdir(
                os.path.join(d, 'PARENT', 'CHILD')),
            note='PARENT already exists -- only CHILD is new')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(46)
    c = add('mkdir', case_id='mut.mkdir-p-file-in-path',
            argv=['-p', _p(t, 'EXISTF/X')], oracle='REF',
            compare='diag', tree=t, poststate=True,
            ref_op=lambda d: None,
            note='EXISTF is a plain FILE sitting where -p needs to '
                 'walk through a directory -- diagnostic, exit 1, '
                 'tree unchanged (host os.makedirs raises '
                 'NotADirectoryError on the same shape; ref_op is a '
                 'no-op so poststate asserts maux mutated nothing)')
    _EXPECT_TEXT[c] = _expect_mkdir_fail(_p(t, 'EXISTF/X'))

    t = _T(47)
    c = add('mkdir', case_id='mut.mkdir-p-existing-file',
            argv=['-p', _p(t, 'EXISTF2')], oracle='REF',
            compare='diag', tree=t, poststate=True,
            ref_op=lambda d: None,
            note='mkdir -p naming an existing PLAIN FILE is a '
                 'failure -- POSIX -p forgives an existing '
                 'directory, never an existing file')
    _EXPECT_TEXT[c] = _expect_mkdir_fail(_p(t, 'EXISTF2'))

    t = _T(48)
    c = add('mkdir', case_id='mut.mkdir-p-several',
            argv=['-p', _p(t, 'NEWA/NEWB'), _p(t, 'PLAIN')],
            oracle='REF', compare='diag', tree=t, poststate=True,
            ref_op=lambda d: [
                os.makedirs(os.path.join(d, 'NEWA', 'NEWB')),
                os.mkdir(os.path.join(d, 'PLAIN'))],
            note='two operands together: one nested (needs an '
                 'intermediate), one a single new plain component')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(49)
    c = add('mkdir', case_id='mut.mkdir-p-absolute',
            argv=['-p', _p(t, 'AA/BB')], oracle='REF',
            compare='diag', tree=t, poststate=True,
            ref_op=lambda d: os.makedirs(os.path.join(d, 'AA', 'BB')),
            note='an absolute image path (_p, same as every other '
                 'case in this file) needing two new components -- '
                 'the dedicated proof that the volume-name component '
                 '("BASIC") is skipped, not CREATEd, by the walk')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(23)
    deep = _padpath(_p(t), 70)
    c = add('rm', case_id='mut.rm-long-path', argv=[deep],
            oracle='REF', compare='diag', tree=t, poststate=True,
            ref_op=lambda d: None,
            note=f'MLI_PTH_MAXLN ({MLI_PTH_MAXLN}) robustness: a '
                 f'{len(deep)}-char legal-looking but unstaged path -- '
                 f'src/liba/mli.s\'s MKPATH (mli.s:11-33) silently '
                 f'truncates at {MLI_PTH_MAXLN} raw chars with NO '
                 f'diagnostic about the truncation itself; both sides '
                 f'fail (host: ENOENT on the real 70-char path; maux: '
                 f"DESTROY fails on ITS OWN {MLI_PTH_MAXLN}-char-"
                 f'truncated garbage), so this only proves neither side '
                 f'corrupts anything or hangs -- it does NOT prove the '
                 f'truncated path is what a human would expect')
    _EXPECT_TEXT[c] = _expect_rm_fail(deep)

    # ---- rm -r / -f (FLEET F.2 tier 1, 2026-09-01) -------------------
    t = _T(34)
    c = add('rm', case_id='mut.rm-r-tree',
            argv=['-r', _p(t, 'SUBDIR')],
            oracle='REF', compare='diag', tree=t, poststate=True,
            ref_op=lambda d: shutil.rmtree(os.path.join(d, 'SUBDIR')),
            note='rm -r a two-level tree via CPT_RMTREE (the cp -r/'
                 'mv engine\'s third leg); KEEP must survive, and the '
                 'DESTROY-refuses-$4E divergence disappears because '
                 'the teardown IS recursive now')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(35)
    c = add('rm', case_id='mut.rm-f-nosuch',
            argv=['-f', _p(t, 'NOSUCH')],
            oracle='REF', compare='diag', tree=t, poststate=True,
            ref_op=lambda d: None,
            note='-f forgives ABSENCE: no diagnostic, exit 0, KEEP '
                 'untouched -- the not-found errno class $44-$46 and '
                 'nothing else (rm.s\'s :failed)')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(36)
    c = add('rm', case_id='mut.rm-rf-mixed',
            argv=['-rf', _p(t, 'SUBDIR'), _p(t, 'NOSUCH')],
            oracle='REF', compare='diag', tree=t, poststate=True,
            ref_op=lambda d: shutil.rmtree(os.path.join(d, 'SUBDIR')),
            note='clustered -rf: the tree goes, the missing operand '
                 'is silent, exit 0 -- the getopt cluster path and '
                 'both flags in one breath')
    _EXPECT_TEXT[c] = _expect_ok()

    # ---- cp/mv multi-into-directory (FLEET F.2, 2026-09-01) ----------
    t = _T(37)
    c = add('cp', case_id='mut.cp-multi',
            argv=[_p(t, 'A'), _p(t, 'B'), _p(t, 'DEST')],
            oracle='REF', compare='diag', tree=t, poststate=True,
            ref_op=lambda d: [shutil.copy(os.path.join(d, n),
                                          os.path.join(d, 'DEST', n))
                              for n in ('A', 'B')],
            expect_types={'DEST/A': ('from', 'A'),
                          'DEST/B': ('from', 'B')},
            note='cp A B DEST: each source lands under its basename, '
                 'originals intact -- the shape a glob expands to')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(38)
    c = add('mv', case_id='mut.mv-multi',
            argv=[_p(t, 'A'), _p(t, 'B'), _p(t, 'DEST')],
            oracle='REF', compare='diag', tree=t, poststate=True,
            ref_op=lambda d: [os.rename(os.path.join(d, n),
                                        os.path.join(d, 'DEST', n))
                              for n in ('A', 'B')],
            expect_types={'DEST/A': ('from', 'A'),
                          'DEST/B': ('from', 'B')},
            note='mv A B DEST: both moved, sources gone')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(39)
    c = add('mv', case_id='mut.mv-multi-notdir',
            argv=[_p(t, 'A'), _p(t, 'B'), _p(t, 'NOTADIR')],
            oracle='REF', compare='diag', tree=t, poststate=True,
            ref_op=lambda d: None,
            note='3+ operands with a plain-file target: refused UP '
                 'FRONT (TGTISDIR), nothing moves -- without the '
                 'gate the pair loop would move A onto NOTADIR and '
                 'then B onto it, destroying A silently')
    _EXPECT_TEXT[c] = _expect_mv_multi_notdir()

    t = _T(40)
    c = add('cp', case_id='mut.cp-multi-continue',
            argv=[_p(t, 'NOSUCH'), _p(t, 'B'), _p(t, 'DEST')],
            oracle='REF', compare='diag', tree=t, poststate=True,
            ref_op=lambda d: shutil.copy(os.path.join(d, 'B'),
                                         os.path.join(d, 'DEST', 'B')),
            expect_types={'DEST/B': ('from', 'B')},
            note='a failed pair CONTINUES: NOSUCH reports and exits 1 '
                 'but B still arrives -- the POSIX rule the loop '
                 'exists to honour')
    _EXPECT_TEXT[c] = _expect_cp_fail()

    # ---- touch (FLEET F.3, 2026-09-01) -------------------------------
    t = _T(41)
    c = add('touch', case_id='mut.touch-create', argv=[_p(t, 'NEWF')],
            oracle='REF', compare='diag', tree=t, poststate=True,
            ref_op=lambda d: open(os.path.join(d, 'NEWF'), 'wb').close(),
            expect_types={'NEWF': ('from', 'KEEP')},
            note='touch a MISSING file: created empty and TXT -- what '
                 'a shell redirect makes; the (from, KEEP) mapping '
                 'both carries the encoding kind for the poststate '
                 'walk and PINS the TXT choice -- silent, exit 0; '
                 'KEEP untouched')
    _EXPECT_TEXT[c] = _expect_ok()

    t = _T(42)
    c = add('touch', case_id='mut.touch-exists', argv=[_p(t, 'HAVE')],
            oracle='REF', compare='diag', tree=t, poststate=True,
            ref_op=lambda d: os.utime(os.path.join(d, 'HAVE')),
            note='touch an EXISTING file: content byte-identical after '
                 '(SET_FILE_INFO, never a write), silent, exit 0 -- '
                 'the stamp itself is fs_meta.touch-stamp\'s job')
    _EXPECT_TEXT[c] = _expect_ok()


# ======================================================================
# Comparators.
# ======================================================================
def _first_diff(got, want):
    n = min(len(got), len(want))
    for i in range(n):
        if got[i] != want[i]:
            return (f'first difference at byte {i}: maux {got[i]!r} vs '
                    f'expected {want[i]!r}\n  maux     {got[max(0,i-20):i+20]!r}\n'
                    f'  expected {want[max(0,i-20):i+20]!r}')
    return (f'identical for {n} bytes then length differs: maux '
            f'{len(got)} B, expected {len(want)} B\n'
            f'  maux tail     {got[n:n+40]!r}\n'
            f'  expected tail {want[n:n+40]!r}')


def cmp_diag(case, got, ref, volume, hostdir):
    """The plain-diagnostic comparator (GLOBALS's own entry explains why
    `want` comes from _EXPECT_TEXT, a formula, not from `ref`)."""
    want = _EXPECT_TEXT.get(case, b'')
    if got == want:
        return True, ''
    return False, _first_diff(got, want)


COMPARATORS = {
    'diag': cmp_diag,
}


def synth(case, ref_out, ref_err, ref_extra, volume, hostdir):
    """A correct maux's (stdout+stderr) bytes for `case` -- computed
    from the SAME formula the comparator checks against, per the module
    interface's own description ("push the reference through the
    inverse of each divergence entry"); here the "reference" IS the
    formula, since the host's literal bytes carry no comparable
    information for these four tools (see GLOBALS)."""
    return ENC(_EXPECT_TEXT.get(case, b''))


# ======================================================================
# LOCAL SELFTEST -- not part of the module interface (sec 5.1 lists
# exactly NAME/RO_*/MUT_TREES/ENTRIES/DEFECTS/INVARIANTS/GLOBALS/
# COMPARATORS/cases/synth). E1's scripts/e2e_fs_selftest.py does not
# exist in this worktree; CONTRACT sec 0 says to stub locally to prove
# the teeth. Everything below is that stub: a tiny local Case registry
# mirroring sec 5.2's `add()` shape, a host-side fixture materialiser,
# and a STUB of the assumed shared tree comparator (see module
# docstring) -- run standalone with `python3 scripts/e2e_fs_mutate.py`.
# ======================================================================

class _Case:
    """TL ruling 2026-08-23 added a fifth pin field, status_ruled=
    (a (tool, axis) key or None): exempts ONLY the exit-status equality
    check -- output is still compared in full, the runner reports it by
    name every run ('STATUS RULED case NN <entry>'), the cited entry
    must be grade RULED or EXCLUDED, and it is mutually exclusive with
    defect= (asserted below)."""
    __slots__ = ('cid', 'tool', 'argv', 'oracle', 'compare', 'ref_argv',
                'tree', 'ref_op', 'poststate', 'diverges', 'defect',
                'status_ruled', 'note')

    def __init__(self, cid, tool, argv=(), oracle='REF', compare='exact',
                ref_argv=None, tree=None, ref_op=None, poststate=False,
                cwd=None, sh_words=None, diverges=(), defect=None,
                status_ruled=None, invariant=None, note=''):
        del cwd, sh_words, invariant   # unused by this package's cases
        assert defect is None or status_ruled is None, (
            f'case {cid}: defect= and status_ruled= are mutually '
            f'exclusive (TL ruling 2026-08-23)')
        if status_ruled is not None:
            grade = ENTRIES.get(status_ruled, (None,))[0]
            assert grade in ('RULED', 'EXCLUDED'), (
                f'case {cid}: status_ruled={status_ruled!r} must cite a '
                f'RULED or EXCLUDED DIVERGENCE entry, got grade {grade!r}')
        self.cid = cid
        self.tool = tool
        self.argv = list(argv)
        self.oracle = oracle
        self.compare = compare
        self.ref_argv = ref_argv
        self.tree = tree
        self.ref_op = ref_op
        self.poststate = poststate
        self.diverges = list(diverges)
        self.defect = defect
        self.status_ruled = status_ruled
        self.note = note


def _build_cases():
    reg = []

    def add(tool, **kw):
        cid = len(reg) + 1
        reg.append(_Case(cid, tool, **kw))
        return cid

    cases(add)
    return reg


def _stage_tree(root, entries):
    """Materialise a MUT_TREES-shaped dict under host directory `root`."""
    os.makedirs(root, exist_ok=True)
    # Directories first (DIR sentinel), in path-length order so a
    # parent always exists before its child is created.
    dirs = sorted((k for k, v in entries.items() if v == DIR), key=len)
    for d in dirs:
        os.makedirs(os.path.join(root, d), exist_ok=True)
    for k, v in entries.items():
        if v == DIR:
            continue
        kind, data = v
        path = os.path.join(root, k)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'wb') as fh:
            fh.write(data)


def _walk(root):
    """relpath -> ('dir', None) or ('file', bytes) snapshot of a host
    directory tree, POSIX-separated, root-relative."""
    snap = {}
    for dirpath, dirnames, filenames in os.walk(root):
        rel = os.path.relpath(dirpath, root)
        for d in dirnames:
            key = d if rel == '.' else f'{rel}/{d}'
            snap[key] = ('dir', None)
        for fn in filenames:
            key = fn if rel == '.' else f'{rel}/{fn}'
            with open(os.path.join(dirpath, fn), 'rb') as fh:
                snap[key] = ('file', fh.read())
    return snap


def _stub_tree_compare(want, got):
    """STUB of the assumed shared e2e_fs_common tree comparator (see
    module docstring) -- exercises exactly CONTRACT sec 7.3's five
    rejections: missing file, extra file, changed size, changed type,
    changed content. TYPE is out of scope for this pure-host stub (no
    ProDOS volume here); the type-sensitive defect cases (7, 8, 17)
    are proven separately below via `_type_ok`, which encodes the
    SAME lineage rule a real ProDOS-aware version would read off the
    volume's directory entries."""
    missing = sorted(set(want) - set(got))
    extra = sorted(set(got) - set(want))
    if missing:
        return False, f'missing from result: {missing}'
    if extra:
        return False, f'unexpected extra entries: {extra}'
    for k, (wkind, wdata) in want.items():
        gkind, gdata = got[k]
        if wkind != gkind:
            return False, f'{k}: expected {wkind}, got {gkind}'
        if wkind == 'file':
            if len(wdata) != len(gdata):
                return False, (f'{k}: size {len(gdata)}, expected '
                               f'{len(wdata)}')
            if wdata != gdata:
                return False, f'{k}: content differs'
    return True, ''


def _mutate_tree(snap, kind):
    import copy
    m = copy.deepcopy(snap)
    files = [k for k, (t, _) in m.items() if t == 'file']
    if kind == 'missing file' and files:
        del m[files[0]]
    elif kind == 'extra file':
        m['__EXTRA__'] = ('file', b'x')
    elif kind == 'changed size' and files:
        k = files[0]
        m[k] = ('file', m[k][1] + b'X')
    elif kind == 'changed content' and files:
        k = files[0]
        data = bytearray(m[k][1] or b'\x00')
        if not data:
            data = bytearray(b'\x00')
        data[0] ^= 0xFF
        m[k] = ('file', bytes(data))
    elif kind == 'changed type':
        # Modelled here as a directory<->file flip, the strongest stand-
        # in for "ProDOS file_type changed" a pure-host stub can assert.
        if files:
            k = files[0]
            m[k] = ('dir', None)
        else:
            return None
    else:
        return None
    return m


def _mutants_bytes(out):
    muts = []
    if out:
        b = bytearray(out)
        i = len(b) - 2 if len(b) >= 2 else 0
        b[i] ^= 0x01
        muts.append(('flip one bit', bytes(b)))

        b = bytearray(out)
        b[len(b) // 2] &= 0x7F
        muts.append(('clear one high bit', bytes(b)))

        lines = out.split(b'\x8d')
        if len(lines) > 2:
            muts.append(('drop a line',
                         b'\x8d'.join(lines[:-2] + lines[-1:])))
            muts.append(('duplicate a line',
                         b'\x8d'.join(lines[:1] + lines)))
        if len(lines) > 3:
            reordered = lines[:]
            reordered[0], reordered[1] = reordered[1], reordered[0]
            muts.append(('reorder two lines', b'\x8d'.join(reordered)))
        muts.append(('truncate one byte', out[:-1]))
    else:
        muts.append(('spurious output', ENC(b'x\n')))
    return muts


#: TL, 2026-08-23: /usr/bin/rm|mv|cp|mkdir do NOT exist on this host --
#: all four live in /bin. Stage 1's e2e_corpus.Case._host_argv hardcodes
#: /usr/bin/{tool} and gets away with it only because its nine tools
#: happen to live there; this package's four do not. E1 is adding a
#: real `ref_tool(name)` to the spine (search list, raise if missing,
#: never fall back to PATH); this is a local stub of that EXACT
#: contract, used for every host invocation below. `ref_op` callables
#: in `cases()` above do NOT need it -- they call os.remove/os.rename/
#: shutil.move/copy2/copytree/rmtree directly (Python's own syscall
#: wrappers), never a subprocess, so there is no binary path to
#: resolve; only `_run_host` (the exit-status sanity check) shells out.
#:
#: PROVENANCE: this host's /bin is BSD (macOS) coreutils, not GNU --
#: `-d`, `--` end-of-options handling, and every diagnostic's wording
#: differ from a GNU box's. This package never compares literal
#: reference diagnostic TEXT (see the GLOBALS entry: maux's own
#: messages are checked against a formula, not against the host's), so
#: wording drift is harmless here -- but `-d`/`-r` FLAG semantics (cases
#: 4/5/17) are BSD-verified on THIS host only, and a future run on a
#: GNU box should re-verify them, not assume.
REF_SEARCH_PATH = ('/bin', '/usr/bin')


def ref_tool(name):
    """Resolve a reference binary against an explicit search list.
    Raises FileNotFoundError if not found in any of them -- never falls
    back to a bare name and lets $PATH decide."""
    for d in REF_SEARCH_PATH:
        candidate = os.path.join(d, name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise FileNotFoundError(
        f'{name!r} not found in any of {REF_SEARCH_PATH} -- refusing to '
        f'fall back to $PATH (TL ruling 2026-08-23)')


def _run_host(tool, argv, cwd):
    proc = subprocess.run([ref_tool(tool)] + list(argv), cwd=cwd,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return proc.returncode


def _hostpath(hostdir, case_argpath):
    """Map a maux operand like '/mnt/MAUX/MUT/MUT01/FILEA' onto its staged
    host path -- ASSUMED prefix-substitution, mirroring e2e_corpus.py's
    own `unpath`/host-argv construction for stage 1."""
    prefix = '/mnt/MAUX/MUT/'
    assert case_argpath.startswith(prefix), case_argpath
    return os.path.join(hostdir, case_argpath[len(prefix):])


def _selftest():
    reg = _build_cases()
    problems = []
    accepted = rejected = 0
    tree_accepted = tree_rejected = 0
    defect_teeth = 0
    status_ruled = 0

    with tempfile.TemporaryDirectory(prefix='maux-fs-mutate-selftest-') as base:
        for case in reg:
            root = os.path.join(base, f'c{case.cid:02d}', 'MUT')
            _stage_tree(os.path.join(root, case.tree),
                       MUT_TREES.get(case.tree, {}))
            before = _walk(root)

            # ---- text/status assertion --------------------------------
            want = _EXPECT_TEXT[case.cid]
            got_correct = DEC(synth(case.cid, None, None, [], None, None))[0]
            ok, detail = COMPARATORS[case.compare](case.cid, got_correct,
                                                   want, None, root)
            tag = f'case {case.cid} ({case.tool}: {case.note})'
            if case.defect is not None:
                wrong = COMPARATORS[case.compare](
                    case.cid, DEC(ENC(b'nonsense\n'))[0], want, None, root)
                if wrong[0]:
                    problems.append(f'{tag}: pinned defect but a WRONG '
                                    f'answer was not rejected by the '
                                    f'unpinned comparator')
                elif not ok:
                    problems.append(f'{tag}: pinned defect but its own '
                                    f'CORRECT synthetic answer was '
                                    f'rejected -- {detail}')
                else:
                    defect_teeth += 1
            elif not ok:
                problems.append(f'{tag}: comparator REJECTED its own '
                                f'correct synthetic answer -- {detail}')
            else:
                accepted += 1

            correct_bytes = synth(case.cid, None, None, [], None, None)
            for label, mbytes in _mutants_bytes(correct_bytes):
                mgot, problems = DEC(mbytes)
                # e2e_compare.judge() rejects on a bit-7-clear byte
                # BEFORE the comparator ever runs (kind='ENCODING') --
                # replicate that gate here rather than silently
                # stripping it, which is exactly how a comparator can
                # look like it has teeth on this mutation when it does
                # not (the bug this file's own selftest caught on its
                # first run: AND #$7F makes "clear one high bit" and
                # "leave it set" decode to the SAME stripped byte).
                mok = (not problems) and COMPARATORS[case.compare](
                    case.cid, mgot, want, None, root)[0]
                if mok:
                    problems.append(f'{tag}: comparator ACCEPTED a '
                                    f'mutant ({label}) of its own text '
                                    f'-- it has no teeth')
                else:
                    rejected += 1

            # ---- poststate tree assertion ------------------------------
            if case.poststate:
                copy_root = os.path.join(base, f'c{case.cid:02d}', 'REFCOPY')
                shutil.copytree(root, copy_root)
                tree_dir = os.path.join(copy_root, case.tree)
                if case.ref_op is not None:
                    case.ref_op(tree_dir)
                want_snap = _walk(copy_root)

                ok, detail = _stub_tree_compare(want_snap, want_snap)
                if not ok:
                    problems.append(f'{tag}: tree comparator rejected '
                                    f'its OWN correct tree -- {detail}')
                else:
                    tree_accepted += 1

                for mkind in ('missing file', 'extra file', 'changed size',
                             'changed content', 'changed type'):
                    mutant = _mutate_tree(want_snap, mkind)
                    if mutant is None:
                        continue     # no file in this tree to mutate that way
                    mok, _ = _stub_tree_compare(want_snap, mutant)
                    if mok:
                        problems.append(f'{tag}: tree comparator ACCEPTED '
                                        f'a mutant ({mkind}) -- no teeth')
                    else:
                        tree_rejected += 1

            # ---- non-degeneracy / real host-exit-status sanity check --
            if case.ref_op is not None or True:
                hp = [_hostpath(root, a) if a.startswith('/mnt/MAUX/MUT/')
                     else a for a in case.argv]
                host_argv = case.ref_argv if case.ref_argv is not None else hp
                host_argv = [_hostpath(root, a) if isinstance(a, str)
                            and a.startswith('/mnt/MAUX/MUT/') else a
                            for a in host_argv]
                rc = _run_host(case.tool, host_argv, root)
                predicted_ok = (want == b'')
                if case.status_ruled is not None:
                    # TL ruling 2026-08-23: reported by name every run,
                    # exit-status equality exempted; output is NOT --
                    # already fully checked above via cmp_diag.
                    print(f'[e2e-fs-mutate selftest] STATUS RULED case '
                         f'{case.cid:3d} {case.status_ruled}')
                    status_ruled += 1
                elif case.defect is None and (rc == 0) != predicted_ok:
                    problems.append(
                        f'{tag}: host {case.tool} exit {"0" if rc == 0 else rc} '
                        f'but maux is predicted to '
                        f'{"succeed" if predicted_ok else "fail"} -- exit-'
                        f'status classes disagree and this case is '
                        f'neither defect-pinned nor status_ruled= (see '
                        f'report sec 9)')

    print(f'[e2e-fs-mutate selftest] {len(reg)} cases: {accepted} correct '
          f'answers accepted, {rejected} mutants rejected, '
          f'{defect_teeth} defect-pin dual-sided teeth passed, '
          f'{status_ruled} status_ruled= case(s) reported, '
          f'{tree_accepted} correct trees accepted, {tree_rejected} tree '
          f'mutants rejected')
    for p in problems:
        print(f'[e2e-fs-mutate selftest] FAIL: {p}', file=sys.stderr)
    if problems:
        return 1
    print('[e2e-fs-mutate selftest] PASS')
    return 0


if __name__ == '__main__':
    raise SystemExit(_selftest())
