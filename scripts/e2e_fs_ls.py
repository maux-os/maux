#!/usr/bin/env python3
"""T4 stage-1b filesystem tranche -- the `ls` package (E2).

docs/E2E.md is the ruling; the T4 CONTRACT (TL's design, shared with the
task) is the binding interface this module implements (CONTRACT sec 5.1).
Read both before touching this file.

WHAT THIS MODULE DOES NOT DO: it does not boot the emulator, does not
build the shared image, does not merge with the other five packages.
E1 owns scripts/e2e_fsmap.py (the mapping: names/blocks/dates/order),
scripts/e2e_fs_common.py (the Case/registry/teeth-driver machinery) and
scripts/build_e2efs_image.py (actual staging).  None of those exist in
this worktree yet, so every place this module talks to them is an
ASSUMED interface, called out explicitly below and in the task report.

ASSUMED INTERFACES (state these are assumptions, not facts):

  * `cases(add)` -- `add` is supplied by e2e_fs_common's registry and
    mirrors CONTRACT sec 5.2's Case shape exactly:
        add(tool, argv=[...], sh_words=None, oracle=..., compare=...,
            ref_argv=None, tree=None, ref_op=None, poststate=False,
            cwd=None, diverges=[], defect=None, invariant=None, note='')

  * COMPARATORS[name](case, got, ref, volume, hostdir) -> (ok, detail),
    per CONTRACT sec 5.1.  `got` is assumed pre-decoded from high-bit
    maux text the same way stage-1's e2e_compare.decode_maux_text does
    it (ASCII, LF line endings) -- this module never touches bit 7.
    `volume` is assumed to expose two calls this module actually needs,
    modelled directly on a2til's own `prodos` module (which is what
    CONTRACT sec 1/sec 2 says VOL ultimately reads through):

        volume.readdir(image_dir_path) -> ordered list of entries, IN
            ON-DISK (creation) ORDER, each exposing .name (display,
            case-decoded), .type (file_type), .storage_type, .eof,
            .raw_date (4 bytes: date_lo, date_hi, minute, hour) -- the
            same fields src/liba/readdir.s's RD_* record carries.
        volume.gfi(image_path) -> one entry with .type, .storage_type,
            .blocks_used, .raw_date -- the GET_FILE_INFO shape.

    If e2e_fsmap ends up shaped differently, the fix is mechanical:
    these two calls are the only place this module touches it.

  * RO_SET_INFO -- NOT in CONTRACT sec 5.1 as written.  One case here
    (OLDDATE, see ENTRIES['ls','legacy year pivot 78 not TN#28 40'])
    needs a deliberately-old mod_date, and the TL's own correction
    said the only way to get one is `prodos.set_file_info(path,
    last_mod=...)` after the write.  RO_FILES/RO_DIRS have no field for
    a post-write patch, so this module adds `RO_SET_INFO: {relpath:
    {kwarg: value}}` and assumes build_e2efs_image.py will call
    `prodos.set_file_info(f'{RO_ROOT}/{relpath}', **kwargs)` once for
    each entry after staging.  Flagged in the task report as a
    contract addition, not assumed silently.

Every fixture below was staged for real, host-side, against a scratch
1600-block ProDOS volume built directly with a2til's own `prodos`
module (`prodos.create`/`mkdir`/`write`/`set_file_info` -- no emulator,
no mirror, matching the TL's correction that RO is staged this way, not
through `a2til mirror`, which does not recurse into subdirectories).
Every number cited in a comment (blocks_used, sorted order, the exact
64-char path) was READ BACK off that real volume, not predicted.
"""
import os
from datetime import datetime
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e_limits as L  # noqa: E402

NAME = 'ls'

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ----------------------------------------------------------------------
# Boundaries -- derived from the headers the code itself reads, never
# copied in (docs/E2E.md sec 5, CONTRACT sec 0.4).
# ----------------------------------------------------------------------

#: The MLI's own pathname-buffer cap.  inc/mli.equ's own comment:
#: "1-byte COUNT, then up to 64 RAW 7-BIT-ASCII characters".
#: src/liba/mli.s's MKPATH copies exactly this many raw bytes and stops
#: -- no diagnostic (see DEFECTS below).
MLI_PTH_MAXLN = L.parse_equs('inc/mli.equ')['MLI_PTH_MAXLN']


def _ls_entries_cap():
    """The cap -- DERIVED, never written down (task brief's instruction).

    src/bin/ls.s now names it once, `LS_MAXENT equ <n>`, and sizes its
    storage from that: `ENTRIES ds LS_MAXENT*<stride>`.  It used to
    declare `ENTRIES ds 4096` with the 128 implied, which is what this
    function parsed; the rewrite to a named constant (2026-09-20, cap
    128 -> 255) broke that regex, LOUDLY, which is the behaviour the
    original author asked for in the message below.

    Both halves are still read fresh on import, and the stride in
    ls.s is still cross-checked against inc/readdir.equ's RD_SIZE
    (that file, not readdir.s: the RD_* equates were split out
    2026-08-28 so they precede the code that uses them -- real
    Merlin-8 rejects a forward `equ`).  So a future resize of either
    changes the corpus with no edit here.
    """
    rd_size = L.parse_equs('inc/readdir.equ')['RD_SIZE']
    with open(os.path.join(ROOT, 'src', 'bin', 'ls.s')) as fh:
        text = fh.read()
    m = re.search(r'^LS_MAXENT\s+equ\s+(\d+)', text, re.M)
    if not m:
        raise RuntimeError(
            "LS_MAXENT equ <n> not found in src/bin/ls.s -- has the "
            "directory cap been renamed or removed? "
            "scripts/e2e_fs_ls.py's cap derivation needs updating, "
            "not a hardcoded number.")
    cap = int(m.group(1))
    st = re.search(r'^ENTRIES\s+ds\s+LS_MAXENT\*(\d+)', text, re.M)
    if not st:
        raise RuntimeError(
            "ENTRIES is no longer sized as LS_MAXENT*<stride> in "
            "src/bin/ls.s -- the cap and its storage have stopped "
            "agreeing by construction, so this derivation cannot "
            "check them against RD_SIZE any more.")
    stride = int(st.group(1))
    if stride != rd_size:
        raise RuntimeError(
            f'ENTRIES is sized LS_MAXENT*{stride} but RD_SIZE is '
            f'{rd_size} -- src/bin/ls.s and inc/readdir.equ disagree '
            f'about the record stride')
    return cap


LS_CAP = _ls_entries_cap()          # 255, as of this writing -- AT this
                                     # count, ls must NOT truncate (C11)
LS_CAP_OVER = LS_CAP + 1            # 129: the first entry that IS capped
                                     # (C12)

# ----------------------------------------------------------------------
# RO fixture tree -- staged once, read-only, never pulled (CONTRACT
# sec 3).  Every name is legal ProDOS (letters/digits/periods, starts
# with a letter, <=15 chars -- learning:01M07G8WT2R3G2P87EK1DNPVYP,
# verified 2026-08-23: "a.b.c" -- multiple periods -- is legal, which is
# why LSDIR/A.TXT is spelled with one).
# ----------------------------------------------------------------------

#: Deep chain for the MLI_PTH_MAXLN boundary (DEFECTS, below).  Three
#: 15-char (max legal) directory names plus a 3-char one bring
#: "/mnt/MAUX/RO/<A15>/<B15>/<C15>/DDD" to EXACTLY 64 raw characters --
#: (docs/VROOT-NOTES.md M3: the TYPED form is capped at 64, the guest's
#: pathname slots are 65 bytes; the physical form is 4 shorter here)
#: measured, not computed by hand: len() on the real string is 64.
_A15, _B15, _C15 = 'A' * 15, 'B' * 15, 'C' * 15
_DEEP_DIR = f'{_A15}/{_B15}/{_C15}/DDD'             # 64 chars w/ "/mnt/MAUX/RO/"
_DEEP_OVER_NAME = 'DDDD'                             # 65 chars -- 1 over,
                                                      # and NOT created on
                                                      # disk (see DEFECTS)

RO_DIRS = [
    'LSDIR',
    'LSDIR/AA',                      # nested subdirectory + a sort-order
                                      # entry at once
    'EMPTYDIR',
    'CAP128',
    'CAP129',
    _A15,
    f'{_A15}/{_B15}',
    f'{_A15}/{_B15}/{_C15}',
    _DEEP_DIR,
]


def _filler(n, seed):
    if n == 0:
        return b''
    return bytes(((i * 7 + seed) % 251) + 1 for i in range(n))


RO_FILES = {
    # -- LSDIR: sort order + type coverage + the two size columns.
    # Staged in a DELIBERATELY non-sorted creation order (CONTRACT sec
    # 7.6 non-degeneracy) -- verified below in NONDEGEN.
    'LSDIR/SYSFILE': ('raw', _filler(30, 1)),               # SYS
    'LSDIR/AA/DEEPFILE': ('raw', b'deep\n'),                 # nested
    'LSDIR/ODDTYPE': ('raw', _filler(10, 2)),                 # $F1 -> "$F1"
    # mixed-case, LOWERCASE-STARTING name -- build_ls_image.py's own
    # precedent (bigFile.BIN): a case-SENSITIVE sort would shove this to
    # the very end (lowercase ASCII > uppercase); the correct
    # case-INSENSITIVE fold puts it between AA and MMMM...
    'LSDIR/bigFile.BIN': ('raw', _filler(1500, 3)),           # sapling:
                                                                # 3 data +
                                                                # 1 index
                                                                # block
    'LSDIR/NNNNNNNNNNNNNNN': ('raw', _filler(5, 4)),          # 15-char name
    'LSDIR/A1': ('raw', _filler(20, 5)),
    'LSDIR/MMMMMMMMMMMMMM': ('raw', _filler(5, 6)),           # 14-char name
    # OLDDATE's deliberately-old stamp now rides IN THE SPEC (the
    # 3-tuple meta form unpack_fixture_spec grew on 2026-08-23). It
    # used to sit in RO_SET_INFO below, WHICH NOTHING EVER APPLIED --
    # the year-pivot fixture was staged with datetime.now() and its
    # divergence entry never saw the date it argues about. Found
    # 2026-09-01 while wiring -t (grep for the consumer before
    # trusting a staging table).
    'LSDIR/OLDDATE': ('raw', _filler(15, 7),
                      {'last_mod': datetime(1955, 6, 15, 10, 30)}),

    # -- TDIR: -t's chronology fixture. Creation order, name order
    # and mtime order all differ; TIE.A/TIE.B share an instant (the
    # name tiebreak); LEGACY is pre-2000 -- under a2til's TN#28
    # pivot-40 writer 1999 stamps year-field 99 and 2026 stamps 126,
    # so a PIVOT-BLIND raw compare calls LEGACY the newest file in
    # the directory, which is exactly the bug BLDKEY's +100 exists
    # to prevent (raw 0..77 lifts above 78..127; both encodings of
    # the 2000s land on the same adjusted value).
    'TDIR/MIDDLE': ('raw', _filler(9, 9),
                    {'last_mod': datetime(2020, 11, 17, 13, 45)}),
    'TDIR/ZNEW': ('raw', _filler(7, 10),
                  {'last_mod': datetime(2026, 8, 30, 21, 5)}),
    'TDIR/LEGACY': ('raw', _filler(5, 11),
                    {'last_mod': datetime(1999, 12, 31, 23, 59)}),
    'TDIR/TIE.B': ('raw', _filler(4, 12),
                   {'last_mod': datetime(2019, 2, 3, 4, 6)}),
    'TDIR/AOLD': ('raw', _filler(6, 13),
                  {'last_mod': datetime(2001, 3, 5, 8, 15)}),
    'TDIR/TIE.A': ('raw', _filler(3, 14),
                   {'last_mod': datetime(2019, 2, 3, 4, 6)}),
    'LSDIR/A.TXT': ('raw', _filler(40, 8)),                   # legal
                                                                # multi-part
                                                                # name

    # -- top-level file operand, for the multi-operand cases.
    'TOPFILE1': ('raw', b'top file one\n'),

    # -- the 128/129-entry cap.  Named E0000000..E0000127/128 (8 chars,
    # legal), staged in DESCENDING order so creation order is the exact
    # REVERSE of sorted order -- not just "different", maximally
    # non-degenerate, and it forces the insertion sort to do real work
    # across the full 128-element array.
    **{f'CAP128/E{i:07d}': ('raw', b'') for i in range(LS_CAP - 1, -1, -1)},
    **{f'CAP129/E{i:07d}': ('raw', b'') for i in range(LS_CAP, -1, -1)},

    # -- MLI_PTH_MAXLN: one file inside the 64-char-deep directory, so
    # `ls` at the boundary has something to list.
    f'{_DEEP_DIR}/DEEPEST': ('raw', b'hi\n'),
}

#: NOT in CONTRACT sec 5.1 -- see module docstring.  relpath (under
#: /mnt/MAUX/RO) -> kwargs for a2til's prodos.set_file_info, applied once
#: after the corresponding RO_FILES write.
#:
#: datetime(1955, 6, 15, 10, 30) encodes to ProDOS year field 55
#: (1955-1900) under a2til's own TN#28 pivot-40 writer.  ls.s decodes
#: legacy years with the pivot at 78, not 40 (docs/PRODOS-VERSION.md's
#: "Standing ruling", learning:01KW1CR53VP3ATCXDYWAMQYB6W is the TN#28
#: side of the argument) -- field 55 < 78, so ls.s prints "2055", not
#: "1955".  Verified empirically against a real a2til-built entry: raw
#: date bytes decode to day=15/month=6/year7=55/hour=10/minute=30 under
#: BOTH rules; only the century differs.  See
#: ENTRIES['ls','legacy year pivot 78 not TN#28 40'].
RO_SET_INFO = {}  # RETIRED 2026-09-01: nothing ever consumed this
                  # table -- the stamps live in the RO_FILES specs'
                  # meta now (see OLDDATE above), which stage_tree()
                  # really does apply via set_meta().

#: This package does not mutate the volume.
MUT_TREES = {}

#: `ls` has REF and VOL oracles for every axis it touches; nothing here
#: needs an oracle-less invariant.
INVARIANTS = {}

#: Nothing in this package is true of every case without being cited --
#: see ENTRIES/DEFECTS below, each attached per-case via `diverges=`/
#: `defect=`.
GLOBALS = {}

# ----------------------------------------------------------------------
# The divergence ratchet -- this package's contributions.  Grades per
# CONTRACT sec 1 / docs/E2E.md sec 4.
# ----------------------------------------------------------------------
ENTRIES = {
    ('ls', 'error path wording'): (
        'EXCLUDED',
        "diagnostic TEXT for an unreachable path is not differential -- "
        "no two implementations agree on wording (BSD ls on this host: "
        "'ls: <path>: No such file or directory'; ls.s: 'ls: <path>: "
        "cannot access', ls.s:1043-1047). Same precedent as stage-1's "
        "('*', 'error paths') EXCLUDED entry (docs/E2E.md sec 9.7). "
        "cmp_ls_nosuch checks structure instead: maux's OWN documented "
        "message text (taken from ls.s's static strings, not invented) "
        "and that the path argument appears verbatim; the reference's "
        "own wording is not byte-compared."),

    ('ls', 'pathname'): (
        'DISCHARGED',
        "maux prints the image path it was given (e.g. /mnt/MAUX/RO/LSDIR); "
        "the host reference prints its own tmp-directory path for the "
        "same operand. A pure textual substitution of the host prefix for "
        "the image prefix before comparison -- nothing about either "
        "side's behaviour is touched. Same mechanism as stage-1's "
        "('*', 'pathname') entry (scripts/e2e_divergence.py); repeated "
        "here because this tranche's ratchet may be a separate table."),

    # ('ls', 'multi-operand groups are argv-order, not sorted') was
    # HERE and is DELETED, 2026-08-25 -- FIXED, not re-ruled. The
    # entry's measurement was right (/bin/ls sorts ALL operands before
    # splitting them into the files-first/directories-second groups)
    # and its verdict was the wrong half: it transformed the REFERENCE
    # back into maux's argv order instead of asking why maux differed.
    # ls.s now sorts its operand list with the same STRCMPI compare it
    # already used inside a directory (SORTPATHS), so the two agree
    # directly and _expected_multi builds in sorted order.


    ('ls', 'directory listing entry cap'): (
        'RULED',
        "src/bin/ls.s's LISTDIR (ls.s:404-452, house rule stated at "
        "ls.s:51-54: 'no silent caps') truncates a directory listing at "
        "the LS_CAP-derived limit (255 as of this writing -- see "
        "_ls_entries_cap() above), printing the first LS_CAP entries "
        "IN ON-DISK DIRECTORY ORDER, sorted, plus 'ls: <path>: "
        "truncated at LS_CAP entries' to stderr and forcing exit 1. "
        "The host reference has no such cap and lists every entry with "
        "exit 0. CORRECTED 2026-08-24, on this case's first-ever run "
        "against a real boot (the emulator half was parked behind the "
        "DESTROY hang until now): this entry used to say 'the first "
        "LS_CAP SORTED names', and derived the expectation from the "
        "reference's sorted list truncated to LS_CAP. That is the "
        "host's answer, not a reachable one -- ENTRIES is 4096 bytes = "
        "128 x RD_SIZE (ls.s:1253), so :rloop stops READDIR at the "
        "128th entry (ls.s:494) and SORTENTRIES only ever sees what "
        "was read. ls TRUNCATES THEN SORTS; it cannot rank a name it "
        "never read. On the deliberately descending-ordered CAP129 "
        "fixture the two models pick different sets (ls keeps "
        "E0000128 and drops E0000000; the old model demanded the "
        "reverse), which is what made the error visible. The "
        "expectation is therefore the VOLUME's own directory order, "
        "first LS_CAP, case-fold-sorted -- and because that on-disk "
        "order is the reverse of the printed order, agreeing proves "
        "ls both truncated at the right place and sorted what it "
        "kept. The diagnostic text and exit 1 are taken "
        "from ls.s's own static strings (ERRPFX/ERRSUF_TRUNC, "
        "ls.s:1043-1050), not invented. The AT-cap case (LS_CAP exactly) "
        "cites no divergence: it is the CONTROL that must still match "
        "the reference exactly, proving the check is a `>` not a `>=`."),

    ('ls', 'case-insensitive sort collation'): (
        'DISCHARGED',
        "src/bin/ls.s sorts with STRCMPI (ls.s:528, string.s:118-143), "
        "which folds 'a'-'z' UP to 'A'-'Z' before comparing; digits/"
        "punctuation pass through. Under a raw byte-order sort (even "
        "with LC_ALL=C) a lowercase-starting name like 'bigFile.BIN' "
        "sorts AFTER every all-uppercase name (ASCII lowercase > "
        "uppercase), which is NOT where maux puts it -- CONTRACT sec 2d "
        "is explicit that the host reference under LC_ALL=C is a direct order "
        "oracle only 'for an all-uppercase name domain'. This corpus "
        "deliberately includes a mixed-case, lowercase-starting name "
        "(build_ls_image.py's own precedent) to catch a sort that "
        "forgets to fold, so it cannot rely on that shortcut. Discharged "
        "by asking the right question of the SAME data instead of "
        "forgiving a difference: the reference still supplies the full "
        "NAME SET (an unsorted `ls -f`-shaped read would do as well as "
        "a sorted one, since content is unaffected by sort order), and "
        "this module's own comparators re-sort that reference-supplied "
        "set with sort_key() (the same case fold, Python's str.lower(), "
        "build_ls_image.py's own equivalence) rather than trusting the "
        "host's byte-order sort. Full oracle strength for the NAME SET; "
        "the order transform is mechanical and shared with the "
        "implementation's own documented fold rule, not authored per "
        "case."),

    ('ls', 'legacy year pivot 78 not TN#28 40'): (
        'RULED',
        "docs/PRODOS-VERSION.md's own 'Standing ruling': maux decodes a "
        "legacy ProDOS year field (hour<=23 && minute<=59, both RAW -- "
        "ls.s:715-810) with the pivot at 78 (78..99 -> 1978..1999, "
        "0..77 -> 2000..2077), a deliberate, argued departure from "
        "ProDOS 8 Technical Note #28's published pivot-40 window "
        "(learning:01KW1CR53VP3ATCXDYWAMQYB6W), on the grounds that the "
        "Apple II had no dated filesystem before 1978 so the bottom of "
        "TN#28's window can never carry a real vintage date. a2til's own "
        "writer/decoder (learning:01KWK8FZM58BFR1M3CA9BS6KAX) follows "
        "TN#28 pivot-40. The two rules AGREE on every value that can "
        "legitimately occur on real media (0-39, 78-99) and on every "
        "'now' date this corpus's own fixtures otherwise carry (year "
        "field 26 means 2026 under both, docs/PRODOS-VERSION.md:99) -- "
        "they DISAGREE only for a deliberately-staged year field in "
        "40-77 (RO_SET_INFO's OLDDATE, field 55: pivot-78 says 2055, "
        "pivot-40 says 1955). VERIFIED against a real a2til-written "
        "entry, 2026-08-23: raw date bytes for datetime(1955,6,15,10,30) "
        "decode identically for day/month/year7/hour/minute under both "
        "rules; only the century printed differs. Expected value: the "
        "volume's raw date bytes decoded by ls.s's OWN pivot-78 "
        "algorithm (this module's decode_date_pivot78, the same "
        "algorithm scripts/build_ls_image.py's decode_maux_date already "
        "uses), NOT a2til's default TN#28 interpretation. Oracle "
        "strength: full for whether the CODE correctly implements its "
        "own documented rule against real on-disk bytes; the choice of "
        "pivot itself is not re-litigated here, per docs/E2E.md's own "
        "'RULED: the transform is ours, keep them few and small'."),

    ('ls', 'usage-error refusal: wording and exit status not '
           'differential'): (
        'EXCLUDED',
        "C10, `ls TOPFILE1 -x` (a dash-prefixed word past argv[1]): "
        "BOTH /bin/ls and maux (fixed 2026-08-23, ls.s commits "
        "3b5dd21/fab0ab3) REFUSE this command -- they agree only on "
        "THAT, not on how. BSD ls treats '-x' as an unrecognised "
        "getopt-style OPTION discovered AFTER already printing "
        "TOPFILE1's own line ('ls: -x: No such file or directory', "
        "exit 1); ls.s's VALIDATE pass catches ANY dash-prefixed word "
        "past argv[1] BEFORE pass 1 ever runs ('usage: ls [-ltr] [path "
        "...]', exit 2, nothing printed first -- ls.s's own header "
        "CONTRACT). Diagnostic wording is not differential -- no two "
        "implementations agree (docs/E2E.md sec 9.7's own precedent, "
        "stage 1's ('*','error paths') EXCLUDED entry, and this "
        "package's own ('ls','error path wording') entry for the "
        "GET_FILE_INFO-failure shape) -- and here the exit-code "
        "SPELLING differs too (2 vs 1), which is not a value either "
        "side chose to match the other, so it is exempted the same way. "
        "DELIBERATELY UNLIKE ('ls','error path wording'): that entry's "
        "own comparator (cmp_ls_nosuch) DOES hardcode maux's documented "
        "message text, which is a defensible STRUCTURAL check for an "
        "ordinary error-path case. C10 is the RETIREMENT of a DEFECT "
        "pin, and the operator's own ruling (2026-08-23) is that "
        "hand-authoring maux's exact bytes here is the same anti-"
        "pattern docs/E2E.md sec 4 forbids for a captured-maux-output "
        "expectation, written out longhand -- it would make C10 pass "
        "forever regardless of what ls.s does. So cmp_ls_refused checks "
        "NEITHER side's wording at all: only the STRUCTURAL fact both "
        "genuinely share (the command is refused, nothing in argv is "
        "ever printed as a successfully-listed entry) is asserted."),

    # DEFINED HERE, not in e2e_fs_idiom.py, even though this replaces
    # a DEFECTS entry that module used to hold and even though the
    # OTHER LONGPATH case citing this key is idiom's own -- see
    # e2e_fs_idiom.py's own comment at this key's old location for the
    # registration-order reason (status_ruled= is validated inline,
    # against whatever the registry has merged so far, and 'ls'
    # registers before 'idiom' in e2e_fs_corpus.py's fixed module
    # order).
    ('*', 'MLI pathname parameter capped at MLI_PTH_MAXLN (64)'): (
        'RULED',
        "ProDOS's MLI bounds a single pathname PARAMETER passed to "
        "OPEN/CREATE/DESTROY/RENAME/GET_FILE_INFO/SET_PREFIX at "
        "MLI_PTH_MAXLN (64) characters -- inc/mli.equ's own "
        "comment: a 1-byte COUNT then up to 64 raw 7-bit-ASCII "
        "characters. This is a PARAMETER ceiling, not a RESOLVED-name "
        "ceiling: a RELATIVE parameter is prefix-concatenated against "
        "the current prefix by ProDOS itself AFTER MKPATH returns, so "
        "the fully-resolved pathname the volume actually matches "
        "against can reach up to 128 characters (P8 TRM) -- what "
        "cannot exceed 64 is the single parameter this liba/kernel "
        "builds and hands to the MLI in ONE call. A liba-built "
        "ABSOLUTE pathname over that ceiling is therefore "
        "UNREPRESENTABLE to maux at all: there is no MLI call this can "
        "ever be turned into that names the real, longer object, so "
        "maux REFUSES where a host filesystem -- which has no such "
        "per-call parameter cap -- would succeed on a genuinely-real "
        "path of that length. src/liba/mli.s's MKPATH (fixed "
        "2026-08-23, branch t4-mkpath-fix) fails this CLOSED on "
        "overflow: it sets carry and corrupts the last of its 64 "
        "copied bytes to $00 (a byte no real ProDOS directory-entry "
        "name can ever contain), so a caller can no longer "
        "coincidentally match a shorter, real, DIFFERENT object the "
        "way a plain truncation used to. This closes the DEFECT (a "
        "confident wrong answer, exit 0) but does not close the GAP: "
        "the platform ceiling itself is what makes maux's own refusal "
        "correct-but-different rather than agreement, and that "
        "ceiling belongs to the MLI's parameter shape, not to any one "
        "version of MKPATH's own internals -- this entry is worded "
        "around the LIMITATION so it survives whichever implementation "
        "(the current fail-closed MKPATH, or a future rewrite) "
        "happens to enforce it. Verified against both packages' own "
        "fixtures, 2026-08-23: this module's own 65-char path (whose "
        "first 64 bytes name a REAL, existing, shorter directory) and "
        "e2e_fs_idiom.py's 67-char LONGPATH (whose first 64 bytes "
        "name a REAL, existing, shorter file) both now refuse cleanly "
        "instead of silently resolving to that wrong, shorter object "
        "-- see each case's own note for what changed. The reference "
        "has no equivalent 64-byte-per-call ceiling, so its own exit "
        "status for a genuinely-absent path may or may not "
        "numerically coincide with maux's own refusal status on any "
        "given fixture; status_ruled= exempts the equality check on "
        "principle rather than relying on that coincidence (measured, "
        "2026-08-23: for both fixtures here the numbers happen to "
        "coincide at exit 1, but the entry does not depend on that)."),
}

#: Both defects this module originally pinned here were FIXED,
#: 2026-08-23: ls.s's usage contract (commits 3b5dd21/fab0ab3) and
#: MKPATH's silent truncation (src/liba/mli.s, branch t4-mkpath-fix
#: commit f915af9). The usage-contract case (C10) is now an ordinary
#: differential case (cmp_ls_refused); the MKPATH case (C14) is now a
#: DIVERGENCE, not a retired defect -- TL ruling, 2026-08-23: MKPATH
#: fails closed instead of silently resolving to a wrong real object,
#: but that is a REFUSAL where the host still succeeds, not agreement.
#: See the ('*', 'MLI pathname parameter capped at MLI_PTH_MAXLN (64)')
#: RULED entry, defined once in e2e_fs_idiom.py (this module cites it;
#: same shared-key precedent the old DEFECTS entry used).
DEFECTS = {}

# ----------------------------------------------------------------------
# Formatting helpers -- mirror scripts/build_ls_image.py's own
# functions exactly (house precedent for `-l` line construction),
# because this is genuinely the same computation on different input.
# ----------------------------------------------------------------------

_TYPE_MNEMONIC = {0x04: 'TXT', 0x06: 'BIN', 0x0F: 'DIR', 0xFF: 'SYS',
                  0xFC: 'BAS'}


def type_field(file_type):
    return _TYPE_MNEMONIC.get(file_type, f'${file_type:02X}')


def eof_field(eof):
    return f'{eof:8d}'


def blocks_field(blocks_used):
    return f'{blocks_used}b'.rjust(8)


def decode_date_pivot78(raw4):
    """ls.s's OWN documented decode (ls.s:709-816, docs/PRODOS-VERSION.md
    'Standing ruling'): validate hour<=23 && minute<=59 on the RAW,
    unmasked bytes; if it fails, or the whole word is zero, there is no
    date. Otherwise pivot the 7-bit year at 78, NOT TN#28's 40 -- see
    ENTRIES['ls', 'legacy year pivot 78 not TN#28 40']."""
    date_lo, date_hi, minute, hour = raw4
    word = date_lo | (date_hi << 8)
    if word == 0 and minute == 0 and hour == 0:
        return None
    if hour > 23 or minute > 59:
        return None
    day = word & 0x1F
    month = (word >> 5) & 0x0F
    year = (word >> 9) & 0x7F
    year = (1900 + year) if year >= 78 else (2000 + year)
    return f'{year:04d}-{month:02d}-{day:02d} {hour:02d}:{minute:02d}'


def date_field(raw4):
    s = decode_date_pivot78(raw4)
    return s if s is not None else '-'.ljust(16)


def format_l_line(file_type, size_field_str, raw4, name):
    return f'{type_field(file_type)} {size_field_str} {date_field(raw4)} {name}'


def sort_key(name):
    """STRCMPI folds 'a'-'z' UP to 'A'-'Z' before comparing; digits and
    punctuation pass through unchanged (src/liba/string.s:118-143). The
    relative order this produces is the ordinary case-insensitive
    alphabetical order regardless of fold direction, so Python's
    str.lower() reproduces it -- same equivalence build_ls_image.py's
    compute_expected() already relies on."""
    return name.lower()


# ----------------------------------------------------------------------
# Cases
# ----------------------------------------------------------------------
RO = '/mnt/MAUX/RO'


def cases(add):
    # C1: bare short listing, sort order + nested-dir + mixed-case name.
    # NON-DEGENERACY: LSDIR's creation order (AA, SYSFILE, ODDTYPE,
    # bigFile.BIN, NNNN..., A1, MMMM..., OLDDATE, A.TXT -- verified
    # against the real staged volume, 2026-08-23) differs from its
    # sorted order (A.TXT, A1, AA, bigFile.BIN, MMMM..., NNNN...,
    # ODDTYPE, OLDDATE, SYSFILE) at every single position.
    add('ls', case_id='fs_ls.names', argv=[f'{RO}/LSDIR'],
        oracle='REF', compare='ls_names',
        diverges=[('ls', 'pathname'),
                  ('ls', 'case-insensitive sort collation')],
        note='sort order distinguishes byte order: A.TXT < A1 < AA '
             "('.'=$2E < '1'=$31 < 'A'=$41); bigFile.BIN's lowercase "
             'start tests that the fold, not raw bytes, decides order; '
             'AA is also a real nested subdirectory')

    # C2: -l on the same directory -- type/size(EOF)/date columns,
    # including the OLDDATE pivot-78-vs-40 divergence and bigFile.BIN's
    # sapling EOF (1500, NOT the blocks_used a FILE ARGUMENT would show).
    add('ls', case_id='fs_ls.long-dir', argv=['-l', f'{RO}/LSDIR'],
        oracle='REF+VOL', compare='ls_l_dir',
        diverges=[('ls', 'pathname'),
                  ('ls', 'legacy year pivot 78 not TN#28 40')],
        note='-l directory listing: TTT/EOF/date columns per entry, '
             'same sort order as C1')

    # C3: -l on a FILE ARGUMENT -- the blocks_used+"b" column, the OTHER
    # half of the size-column trap (ls.s:72-80): bigFile.BIN is a real
    # sapling (3 data blocks + 1 index block = 4), so this is NOT
    # ceil(EOF/512) (which would read 3) -- it is GET_FILE_INFO's own
    # blocks_used, read back off the real staged volume.
    add('ls', case_id='fs_ls.long-file',
        argv=['-l', f'{RO}/LSDIR/bigFile.BIN'], oracle='REF+VOL',
        compare='ls_l_file',
        diverges=[('ls', 'pathname')],
        note='the size column here MUST read "4b", not "1500" and not '
             '"3b" (ceil(1500/512)) -- the trap ls.s:72-80 documents')

    # C4/C5: an empty directory, short and long.
    add('ls', case_id='fs_ls.empty-short', argv=[f'{RO}/EMPTYDIR'],
        oracle='REF', compare='ls_names', diverges=[('ls', 'pathname')],
        note='empty directory, short mode')
    add('ls', case_id='fs_ls.empty-long',
        argv=['-l', f'{RO}/EMPTYDIR'], oracle='REF',
        compare='ls_l_dir', diverges=[('ls', 'pathname')],
        note='empty directory, long mode -- both sides print nothing')

    # C6: nonexistent path.
    add('ls', case_id='fs_ls.nosuch', argv=[f'{RO}/NOSUCH'],
        oracle='REF', compare='ls_nosuch',
        diverges=[('ls', 'pathname'), ('ls', 'error path wording')],
        note='diagnostic wording is not differential (docs/E2E.md sec '
             "9.7's precedent); this checks that BOTH sides call it an "
             'error, and that maux forces exit 1 with its own '
             'documented message, not the reference wording')

    # C7/C8: multiple operands, files and directories interleaved, with
    # the file operand placed in the MIDDLE of argv -- proves the
    # files-always-first grouping is not an accident of argument order.
    add('ls', case_id='fs_ls.multi-short',
        argv=[f'{RO}/LSDIR', f'{RO}/TOPFILE1', f'{RO}/EMPTYDIR'],
        oracle='REF+VOL', compare='ls_multi_short',
        diverges=[('ls', 'pathname'),
],
        note='TOPFILE1 must print FIRST despite being argv[2]; LSDIR '
             "then EMPTYDIR in ARGUMENT order, not the reference's own "
             'alphabetical grouping (EMPTYDIR before LSDIR)')
    add('ls', case_id='fs_ls.multi-long',
        argv=['-l', f'{RO}/LSDIR', f'{RO}/TOPFILE1', f'{RO}/EMPTYDIR'],
        oracle='REF+VOL', compare='ls_multi_long',
        diverges=[('ls', 'pathname'),
                  ('ls', 'legacy year pivot 78 not TN#28 40')],
        note='-l variant of C7: grouping/header/blank-line rule combined '
             'with the per-entry VOL columns')

    # C-T1..C-T4: -t/-r (FLEET F.2 tier 1, 2026-09-01). VOL-oracle
    # where chronology matters -- see cmp_ls_t_names' docstring for
    # why REF cannot judge mtime order.
    add('ls', case_id='fs_ls.t-order', argv=['-t', f'{RO}/TDIR'],
        oracle='VOL', compare='ls_t_names',
        note='newest first: ZNEW MIDDLE TIE.A TIE.B AOLD LEGACY. '
             'TIE.* share an instant (name breaks the tie) and '
             'LEGACY (1999) is the PIVOT tooth: raw year-field 99 '
             'outranks 2026\'s if the compare skips the +100 '
             'adjustment, promoting the oldest file to newest.')
    add('ls', case_id='fs_ls.tr-order', argv=['-tr', f'{RO}/TDIR'],
        oracle='VOL', compare='ls_t_names',
        note='-r composes with -t: the exact reverse, ties included '
             '(the inversion happens after the comparator, so the '
             'name tiebreak flips too -- clustered "-tr" also '
             'exercises the argv[1] cluster parse that replaced the '
             'exactly-"-l" rule).')
    add('ls', case_id='fs_ls.r-names', argv=['-r', f'{RO}/LSDIR'],
        oracle='REF', compare='ls_r_names',
        diverges=[('ls', 'pathname'),
                  ('ls', 'case-insensitive sort collation')],
        note='-r alone: C1\'s order exactly reversed, no chronology '
             'involved, so REF stays the oracle.')
    add('ls', case_id='fs_ls.t-operands',
        argv=['-t', f'{RO}/TDIR/AOLD', f'{RO}/TDIR/ZNEW',
              f'{RO}/TDIR/MIDDLE'],
        oracle='VOL', compare='ls_t_opnds',
        note='-t orders FILE OPERANDS too (OPTKEYS stats before '
             'SORTPATHS): ZNEW MIDDLE AOLD despite argv typing AOLD '
             'first -- the shape a glob expands to, which is where '
             '`ls -t *.s` lives or dies.')

    add('ls', case_id='fs_ls.tr-operands',
        argv=['-tr', f'{RO}/TDIR/AOLD', f'{RO}/TDIR/ZNEW',
              f'{RO}/TDIR/MIDDLE'],
        oracle='VOL', compare='ls_t_opnds',
        note='-tr over operands: AOLD MIDDLE ZNEW -- the one case '
             'that reaches PCMPJI\'s own -r inversion (ENTCMP\'s is '
             'covered by the directory cases; the two comparators '
             'invert independently).')

    # C9: nested subdirectory, listed directly.
    add('ls', case_id='fs_ls.nested-dir', argv=[f'{RO}/LSDIR/AA'],
        oracle='REF', compare='ls_names',
        diverges=[('ls', 'pathname')],
        note='a real nested subdirectory, listed on its own')

    # C10: the usage-contract gap -- FIXED 2026-08-23 (ls.s commits
    # 3b5dd21/fab0ab3: a VALIDATE pass now flags ANY dash-prefixed
    # word past argv[1], "-l" included, before pass 1 does any work).
    # Both /bin/ls and maux now REFUSE `ls TOPFILE1 -x` -- they
    # disagree only on WORDING and the exit-code SPELLING (2, a usage
    # error, vs 1, an open failure on the unrecognised flag once BSD
    # ls has already listed TOPFILE1). Neither side's message text is
    # hardcoded here (see cmp_ls_refused's own docstring for why that
    # would make this case pass regardless of what ls.s does -- the
    # operator's own ruling): the STRUCTURAL fact both genuinely share
    # is that the command is refused and nothing is listed.
    add('ls', case_id='fs_ls.trailing-flag-refused',
        argv=[f'{RO}/TOPFILE1', '-x'], oracle='REF',
        compare='ls_refused',
        diverges=[('ls', 'usage-error refusal: wording and exit status '
                         'not differential')],
        status_ruled=('ls', 'usage-error refusal: wording and exit '
                            'status not differential'),
        note='both sides refuse this command (a dash-prefixed word '
             'past argv[1]) -- cmp_ls_refused checks only that nothing '
             'in argv is ever printed as a successfully-listed entry '
             'and that maux says SOMETHING (not silence); it must '
             'reject a silent success, a listing of TOPFILE1, or exit 0')

    # C11: exactly LS_CAP entries -- the CONTROL. Must match the
    # reference exactly: no truncation, no diagnostic, exit 0.
    add('ls', case_id='fs_ls.cap-control', argv=[f'{RO}/CAP128'],
        oracle='REF', compare='ls_names',
        diverges=[('ls', 'pathname')],
        note=f'exactly LS_CAP ({LS_CAP}) entries -- AT the boundary, '
             'must NOT truncate (proves the check is > not >=)')

    # C12: LS_CAP+1 entries -- truncation + diagnostic + exit 1. The exit
    # STATUS itself has no host equivalent (the reference lists all
    # LS_CAP_OVER entries and exits 0; maux deliberately forces exit 1
    # -- "no silent caps", a house rule, not a bug) so it is exempted
    # from the status check via status_ruled rather than pinned as a
    # defect -- CONTRACT sec 5.3, mutually exclusive with `defect=`.
    # Output (the truncated list + diagnostic text) is still compared in
    # full by compare='ls_capped'.
    add('ls', case_id='fs_ls.cap-overflow', argv=[f'{RO}/CAP129'],
        oracle='REF', compare='ls_capped',
        diverges=[('ls', 'pathname'),
                  ('ls', 'directory listing entry cap')],
        status_ruled=('ls', 'directory listing entry cap'),
        note=f'LS_CAP+1 ({LS_CAP_OVER}) entries -- ONE over the '
             'boundary, must truncate to the first LS_CAP sorted names '
             'plus the diagnostic, exit 1 (host: exit 0 -- see '
             'status_ruled)')

    # C13: MLI_PTH_MAXLN, exactly at the boundary -- the CONTROL.
    add('ls', case_id='fs_ls.mkpath-boundary',
        argv=[f'{RO}/{_DEEP_DIR}'], oracle='REF', compare='ls_names',
        diverges=[('ls', 'pathname')],
        note=f'a real path exactly {MLI_PTH_MAXLN} raw characters long '
             '(with the /mnt/MAUX/RO prefix) -- AT the MLI_PTH_MAXLN cap, '
             'must resolve correctly (proves MKPATH is not off by one)')

    # C14: MLI_PTH_MAXLN, one over -- FIXED 2026-08-23 (src/liba/mli.s,
    # branch t4-mkpath-fix, commit f915af9, merged onto this branch):
    # MKPATH now sets carry AND corrupts the last of its 64 copied
    # bytes to $00 on overflow, so the pathname can never byte-match a
    # real catalog entry at any depth -- ls (one of the 24 callers that
    # never checked MKPATH's own carry) now gets a clean GET_FILE_INFO
    # failure instead of silently resolving to _DEEP_DIR, a REAL,
    # existing, SHORTER directory whose path is exactly this one's
    # first 64 bytes. TL ruling, 2026-08-23: this is a DIVERGENCE, not
    # a retired defect -- the host has no 64-byte-per-MLI-call ceiling
    # and would still resolve a real 65-char path if one existed here;
    # maux now REFUSES cleanly where it used to SUCCEED wrongly, which
    # is the fix, but it still does not AGREE with a host that has no
    # such ceiling at all. See the ('*', 'MLI pathname parameter
    # capped at MLI_PTH_MAXLN (64)') RULED entry (e2e_fs_idiom.py, the
    # entry's single canonical home -- shared with that module's
    # LONGPATH case, same mechanism, same limitation).
    over_path = (f'{RO}/{_A15}/{_B15}/{_C15}/{_DEEP_OVER_NAME}')
    add('ls', case_id='fs_ls.mkpath-overflow', argv=[over_path],
        oracle='REF', compare='ls_mkpath_refused',
        diverges=[('*', 'MLI pathname parameter capped at MLI_PTH_MAXLN '
                        '(64)')],
        status_ruled=('*', 'MLI pathname parameter capped at '
                           'MLI_PTH_MAXLN (64)'),
        note=f'{len(over_path)} raw characters -- ONE over '
             'MLI_PTH_MAXLN; the corrupted pathname can no longer '
             'coincidentally match _DEEP_DIR (a real, shorter, '
             'existing directory whose path is this one\'s first 64 '
             'bytes) -- cmp_ls_mkpath_refused positively checks that '
             "DEEPEST (_DEEP_DIR's own real content) never appears, "
             'not just that some error happened')


# ----------------------------------------------------------------------
# Comparators
# ----------------------------------------------------------------------

def _ref_names_resorted(ref):
    """The reference's own name SET (its lines, order discarded), sorted
    with this module's case-fold key -- see ENTRIES['ls',
    'case-insensitive sort collation']. Full REF oracle strength for
    WHICH names exist; the order is the documented STRCMPI fold, not
    the host's own (case-sensitive-by-byte) sort."""
    names = [ln for ln in ref.decode('ascii').split('\n') if ln]
    return sorted(names, key=sort_key)


def cmp_ls_names(case, got, ref, volume, hostdir):
    """Short-mode listing: sorted display names, one per line. REF
    supplies the name SET; the order is re-derived case-insensitively
    from that same set (ENTRIES['ls','case-insensitive sort
    collation'])."""
    want = ''.join(n + '\n' for n in _ref_names_resorted(ref)).encode('ascii')
    if got == want:
        return True, ''
    return False, _first_diff(got, want)


def _entries_for(volume, image_dir):
    return list(volume.readdir(image_dir))


def cmp_ls_l_dir(case, got, ref, volume, hostdir):
    image_dir = case.argv[-1]
    entries = _entries_for(volume, image_dir)
    ordered = sorted(entries, key=lambda e: sort_key(e.name))
    want_lines = [format_l_line(e.type, eof_field(e.eof), e.raw_date, e.name)
                  for e in ordered]
    want = ''.join(line + '\n' for line in want_lines).encode('ascii')
    if got == want:
        return True, ''
    return False, _first_diff(got, want)


def cmp_ls_l_file(case, got, ref, volume, hostdir):
    image_path = case.argv[-1]
    e = volume.gfi(image_path)
    line = format_l_line(e.type, blocks_field(e.blocks_used), e.raw_date,
                          image_path)
    want = (line + '\n').encode('ascii')
    if got == want:
        return True, ''
    return False, _first_diff(got, want)


def cmp_ls_nosuch(case, got, ref, volume, hostdir):
    """Diagnostic wording is EXCLUDED (docs/E2E.md sec 9.7's own
    precedent for error paths); this checks structure only: maux's own
    documented message (ERRPFX + path + ERRSUF_ACCESS, ls.s:1043-1047),
    the path argument's own text present verbatim, and exit-status
    category. The reference (`ref`) is not byte-compared -- its own exit
    status is checked by the shared runner, outside this function."""
    path = case.argv[-1]
    want = f'ls: {path}: cannot access\n'.encode('ascii')
    if got == want:
        return True, ''
    return False, _first_diff(got, want)


def cmp_ls_refused(case, got, ref, volume, hostdir):
    """C10 -- the usage-contract defect's retirement. STRUCTURAL ONLY
    (ENTRIES['ls', 'usage-error refusal: wording and exit status not
    differential']): neither side's diagnostic wording is checked, and
    neither is maux's own exit-code number -- see that entry for why
    hardcoding maux's own usage text here (the pattern this module's
    OWN cmp_ls_nosuch legitimately uses for an ordinary error-path
    case) would be wrong for a DEFECT RETIREMENT specifically. `ref` is
    unused on purpose.

    What IS asserted, positively: maux said something (a refused
    command is not silence), and none of this case's own path operands
    was ever printed as a successfully-listed entry -- which is
    exactly the shape of the OLD bug (TOPFILE1 got listed, then '-x'
    failed as a bogus second path operand)."""
    if not got:
        return False, ('maux produced no output at all -- a refused '
                       'command must say something (silence is what '
                       'the old defect looked like if -x had been '
                       'silently accepted instead of mis-treated as a '
                       'path)')
    if not got.endswith(b'\n'):
        return False, f'output does not end with a line terminator: {got[-16:]!r}'
    lines = [ln for ln in got.split(b'\n') if ln]
    operand_names = set()
    for a in case.argv:
        if not a.startswith('-'):
            operand_names.add(a.encode('ascii'))
            operand_names.add(a.rsplit('/', 1)[-1].encode('ascii'))
    listed = [ln for ln in lines if ln in operand_names]
    if listed:
        return False, (f'maux printed {listed[0]!r} as a successfully-'
                       f'listed entry -- the command was not refused '
                       f'(this is the OLD bug: a dash-prefixed word '
                       f'past argv[1] fell through as a plain path '
                       f'operand instead of hitting the usage check)')
    return True, ''


def cmp_ls_mkpath_refused(case, got, ref, volume, hostdir):
    """C14 -- the MKPATH silent-truncation defect's retirement,
    reclassified as a DIVERGENCE (TL ruling, 2026-08-23: see ENTRIES
    ['*', 'MLI pathname parameter capped at MLI_PTH_MAXLN (64)'],
    defined in e2e_fs_idiom.py). maux now takes the SAME GET_FILE_INFO
    -failure path C6's cmp_ls_nosuch already covers (the corrupted,
    unmatchable pathname cannot resolve), so the expected text is
    identical in SHAPE to that case -- maux's own documented message,
    for the FULL, untruncated operand exactly as typed. Checked
    POSITIVELY, not just 'an error happened' (TL ruling): 'DEEPEST',
    the one real file inside _DEEP_DIR (the shorter, real directory
    the old bug silently resolved to), must never appear anywhere in
    the output -- the exact positive absence the old defect violated."""
    path = case.argv[-1]
    want = f'ls: {path}: cannot access\n'.encode('ascii')
    if got != want:
        return False, _first_diff(got, want)
    if b'DEEPEST' in got:
        return False, ("'DEEPEST' (the real content of _DEEP_DIR, the "
                       "shorter directory the truncated pathname used "
                       "to coincidentally match) appears in the "
                       "output -- the old MKPATH-truncation defect has "
                       "reproduced")
    return True, ''


def cmp_ls_multi_short(case, got, ref, volume, hostdir):
    want = _expected_multi(case, volume, long=False)
    if got == want:
        return True, ''
    return False, _first_diff(got, want)


def cmp_ls_multi_long(case, got, ref, volume, hostdir):
    want = _expected_multi(case, volume, long=True)
    if got == want:
        return True, ''
    return False, _first_diff(got, want)


def _expected_multi(case, volume, long):
    """Build the multi-operand expectation directly from VOL (file
    lines) and VOL (directory listings), operands in SORTED order --
    files first, then each directory's section, which is what /bin/ls
    does and, since 2026-08-25, what ls.s does too.

    This used to build in ARGUMENT order, applying a RULED transform
    ('ls', 'multi-operand groups are argv-order, not sorted') at
    construction time. That entry is deleted: walking the operands
    literally where the host sorts them is avoidable semantic drift --
    `ls LSDIR TOPFILE1 EMPTYDIR` printed its sections in a different
    ORDER on the two systems, which is exactly the kind a script
    notices because it changes stdout. ls.s grew SORTPATHS and the
    accommodation went with the drift. The files-first/directories-
    second grouping was never the gap: pass 1 prints plain files as it
    stats them and pass 2 lists the deferred directories, which IS the
    host's grouping."""
    paths = sorted((a for a in case.argv if not a.startswith('-')),
                   key=sort_key)
    file_lines = []
    dir_sections = []
    for p in paths:
        e = volume.gfi(p)
        if e.storage_type in (0x0D, 0x0F):
            entries = sorted(_entries_for(volume, p),
                              key=lambda x: sort_key(x.name))
            if long:
                body = ''.join(
                    format_l_line(x.type, eof_field(x.eof), x.raw_date,
                                  x.name) + '\n' for x in entries)
            else:
                body = ''.join(x.name + '\n' for x in entries)
            dir_sections.append((p, body))
        else:
            if long:
                file_lines.append(format_l_line(
                    e.type, blocks_field(e.blocks_used), e.raw_date, p)
                    + '\n')
            else:
                file_lines.append(p + '\n')
    parts = list(file_lines)
    multi = len(paths) > 1
    for i, (p, body) in enumerate(dir_sections):
        if multi:
            if i > 0:
                parts.append('\n')
            parts.append(f'{p}:\n')
        parts.append(body)
    return ''.join(parts).encode('ascii')


def cmp_ls_capped(case, got, ref, volume, hostdir):
    """RULED: the first LS_CAP entries in ON-DISK DIRECTORY ORDER,
    case-fold-resorted, plus ls's own documented diagnostic text
    (ls.s:1043-1050) -- see ENTRIES['ls', '128-entry directory
    listing cap'].

    TRUNCATE-THEN-SORT, NOT SORT-THEN-TRUNCATE. This read
    `_ref_names_resorted(ref)[:LS_CAP]` until 2026-08-24, which is
    the host's answer rather than a reachable one: it sorts all 129
    names and keeps the lowest 128. ls.s cannot do that. ENTRIES is
    4096 bytes = 128 x RD_SIZE (ls.s:1253), so LISTDIR's :rloop stops
    READDIR dead at the 128th entry (ls.s:494) and SORTENTRIES only
    ever sees what was read -- the 129th name is not ranked and
    dropped, it is never looked at.

    The CAP129 fixture is staged in DESCENDING name order on purpose
    (E0000128 first, E0000000 last), so the two models genuinely
    disagree and this case can tell them apart: ls keeps E0000128 and
    drops E0000000, the old model demanded exactly the reverse.
    Measured 2026-08-24 -- this case had never run against a real
    boot, the emulator half having been parked behind the DESTROY
    hang, so the old model was written and never checked.

    Still a real assertion, and a sharper one than matching the host
    would be: since the on-disk order is the REVERSE of the printed
    order, agreeing here proves ls both truncated at the right place
    AND sorted what it kept."""
    image_dir = case.argv[-1]
    ondisk = [e.name for e in _entries_for(volume, image_dir)]
    kept = sorted(ondisk[:LS_CAP], key=sort_key)
    # 128 nine-byte names are ~1152 bytes of STDOUT: fully buffered to
    # the capture file, they flush at each 512-byte fill, and the
    # truncation diagnostic (STDERR, line mode) lands at ITS emission
    # point -- after the names were emitted but with the tail of them
    # still buffered. C.merge_streams is the contract's one spelling
    # (docs/PERF-PLAN.md step 4's probed buffering, 2026-08-28).
    import e2e_compare as C
    want = C.merge_streams(
        [('out', ''.join(n + '\n' for n in kept).encode('ascii')),
         ('err', f'ls: {image_dir}: truncated at {LS_CAP} '
                 f'entries\n'.encode('ascii'))])
    if got == want:
        return True, ''
    return False, _first_diff(got, want)


def cmp_exact(case, got, ref, volume, hostdir):
    if got == ref:
        return True, ''
    return False, _first_diff(got, ref)


def _first_diff(got, want):
    n = min(len(got), len(want))
    for i in range(n):
        if got[i] != want[i]:
            return (f'first difference at byte {i}: maux {got[i]!r} vs '
                     f'expected {want[i]!r}\n'
                     f'  maux     {got[max(0,i-32):i+32]!r}\n'
                     f'  expected {want[max(0,i-32):i+32]!r}')
    return (f'identical for {n} bytes then length differs: maux {len(got)} '
            f'B, expected {len(want)} B\n'
            f'  maux tail     {got[n:n+64]!r}\n'
            f'  expected tail {want[n:n+64]!r}')


def _bldkey(raw4):
    """Python twin of lstop.s's BLDKEY: 5-byte chronology key from the
    raw 4-byte date/time (date_lo, date_hi, minute, hour). Year field
    pivot-adjusted exactly as the 6502 does it (raw 0..77 -> +100, so
    both the TN#28 and pivot-78 encodings of the 2000s land above
    1978..1999); a zero DATE word keys all-zero (oldest)."""
    dlo, dhi, minute, hour = raw4[0], raw4[1], raw4[2], raw4[3]
    if dlo == 0 and dhi == 0:
        return (0, 0, 0, 0, 0)
    year = dhi >> 1
    if year < 78:
        year += 100
    return (year, dhi & 1, dlo, hour, minute)


def _t_ordered(entries, reverse):
    """The order ls -t must print: chronology descending, STRCMPI name
    ascending on an equal instant; -r reverses every decided compare,
    which for a strict total order is a plain reversal."""
    ordered = sorted(
        entries,
        key=lambda e: (tuple(-b for b in _bldkey(e.raw_date)),
                       sort_key(e.name)))
    if reverse:
        ordered.reverse()
    return ordered


def cmp_ls_t_names(case, got, ref, volume, hostdir):
    """-t/-tr short listing of one directory. Oracle is VOL, not REF:
    host_stage_tree ignores fixture mtimes, so the host mirror's
    chronology is staging-time noise -- the volume's own raw date
    words are the only truthful clock here."""
    entries = _entries_for(volume, case.argv[-1])
    want = ''.join(e.name + '\n'
                   for e in _t_ordered(entries, 'r' in case.argv[0]))
    want = want.encode('ascii')
    if got == want:
        return True, ''
    return False, _first_diff(got, want)


def cmp_ls_r_names(case, got, ref, volume, hostdir):
    """-r short listing: cmp_ls_names' resorted reference order,
    reversed."""
    want = ''.join(n + '\n' for n in
                   reversed(_ref_names_resorted(ref))).encode('ascii')
    if got == want:
        return True, ''
    return False, _first_diff(got, want)


def cmp_ls_t_opnds(case, got, ref, volume, hostdir):
    """-t over FILE operands: OPTKEYS stats every operand before
    SORTPATHS, so the lines come out newest first, paths printed AS
    TYPED. Expected order from volume.gfi -- same VOL reasoning as
    cmp_ls_t_names."""
    ops = case.argv[1:]
    keyed = sorted(
        ops,
        key=lambda p: (tuple(-b for b in _bldkey(volume.gfi(p).raw_date)),
                       sort_key(p)))
    if 'r' in case.argv[0]:
        keyed.reverse()
    want = ''.join(p + '\n' for p in keyed).encode('ascii')
    if got == want:
        return True, ''
    return False, _first_diff(got, want)


COMPARATORS = {
    'ls_names': cmp_ls_names,
    'ls_t_names': cmp_ls_t_names,
    'ls_r_names': cmp_ls_r_names,
    'ls_t_opnds': cmp_ls_t_opnds,
    'ls_l_dir': cmp_ls_l_dir,
    'ls_l_file': cmp_ls_l_file,
    'ls_nosuch': cmp_ls_nosuch,
    'ls_multi_short': cmp_ls_multi_short,
    'ls_multi_long': cmp_ls_multi_long,
    'ls_capped': cmp_ls_capped,
    'ls_refused': cmp_ls_refused,
    'ls_mkpath_refused': cmp_ls_mkpath_refused,
    # 'exact' is NOT registered here: e2e_fs_common.Registry seeds it
    # with a byte-identical implementation. Two modules claiming it
    # is a merge error by CONTRACT sec 5.1, and the local cmp_exact
    # below is kept only because this module calls it directly.
}


# ----------------------------------------------------------------------
# synth() -- NEVER used by the gate. Only the host-only selftest uses it,
# to have a correct answer to mutate (CONTRACT sec 7 / docs/E2E.md's
# mutation-testing learning, 01M0P0AE3G3P2VSMYTZ2KEBAKB).
# ----------------------------------------------------------------------

#: E7 integration fix, 2026-08-23: every branch below built plain
#: low-ASCII bytes and returned them AS-IS -- CONTRACT sec 6 requires
#: synth() to return what a CORRECT maux would have emitted, which is
#: high-bit text with $8D line endings (e2e_compare.decode_maux_text
#: rejects anything else, with its offset, as a FAILURE). This module
#: never imported e2e_compare at all. Every return point below is now
#: passed through ENC (=e2e_compare.encode_maux_text) before returning.
import e2e_compare as _C  # noqa: E402
ENC = _C.encode_maux_text


def synth(case, ref_out, ref_err, ref_extra, volume, hostdir):
    k = case.compare
    if k == 'ls_names':
        return ENC(''.join(n + '\n' for n in
                           _ref_names_resorted(ref_out + ref_err)).encode(
                               'ascii'))
    if k == 'ls_l_dir':
        return ENC(_build_l_dir(case.argv[-1], volume))
    if k == 'ls_l_file':
        return ENC(_build_l_file(case.argv[-1], volume))
    if k == 'ls_nosuch':
        path = case.argv[-1]
        return ENC(f'ls: {path}: cannot access\n'.encode('ascii'))
    if k == 'ls_t_names':
        ents = _t_ordered(_entries_for(volume, case.argv[-1]),
                          'r' in case.argv[0])
        return ENC(''.join(e.name + '\n' for e in ents).encode('ascii'))
    if k == 'ls_r_names':
        return ENC(''.join(
            n + '\n' for n in
            reversed(_ref_names_resorted(ref_out + ref_err)))
            .encode('ascii'))
    if k == 'ls_t_opnds':
        ops = sorted(case.argv[1:],
                     key=lambda p: (tuple(-b for b in
                                          _bldkey(volume.gfi(p).raw_date)),
                                    sort_key(p)))
        if 'r' in case.argv[0]:
            ops.reverse()
        return ENC(''.join(p + '\n' for p in ops).encode('ascii'))
    if k == 'ls_multi_short':
        return ENC(_expected_multi(case, volume, long=False))
    if k == 'ls_multi_long':
        return ENC(_expected_multi(case, volume, long=True))
    if k == 'ls_capped':
        # Truncate THEN sort, matching cmp_ls_capped's corrected model
        # (2026-08-24) -- a synthetic "correct" answer built the host's
        # sort-then-truncate way is not a correct answer.
        image_dir = case.argv[-1]
        ondisk = [e.name for e in _entries_for(volume, image_dir)]
        kept = sorted(ondisk[:LS_CAP], key=sort_key)
        # Mirror the comparator's merge_streams interleave (probed
        # buffering, docs/PERF-PLAN.md step 4) or the selftest calls
        # a correct answer wrong.
        import e2e_compare as C
        return C.merge_streams(
            [('out', ENC(''.join(n + '\n' for n in kept)
                         .encode('ascii'))),
             ('err', ENC(f'ls: {image_dir}: truncated at {LS_CAP} '
                         f'entries\n'.encode('ascii')))])
    if k == 'ls_refused':
        # Any correctly-refused output would do -- cmp_ls_refused
        # checks structure, not this exact text (see its own
        # docstring). maux's real usage message is used here only so
        # the selftest has a plausible correct answer to mutate.
        return ENC(b'usage: ls [-ltr] [path ...]\n')
    if k == 'ls_mkpath_refused':
        path = case.argv[-1]
        return ENC(f'ls: {path}: cannot access\n'.encode('ascii'))
    if k == 'exact':
        return ENC(ref_out + ref_err)
    raise AssertionError(f'no synthesiser for compare={k!r}')


def _build_l_dir(image_dir, volume):
    entries = sorted(_entries_for(volume, image_dir),
                      key=lambda e: sort_key(e.name))
    return ''.join(
        format_l_line(e.type, eof_field(e.eof), e.raw_date, e.name) + '\n'
        for e in entries).encode('ascii')


def _build_l_file(image_path, volume):
    e = volume.gfi(image_path)
    line = format_l_line(e.type, blocks_field(e.blocks_used), e.raw_date,
                          image_path)
    return (line + '\n').encode('ascii')


if __name__ == '__main__':
    print(f'[e2e-fs-ls] MLI_PTH_MAXLN={MLI_PTH_MAXLN} LS_CAP={LS_CAP} '
          f'(derived from src/bin/ls.s ENTRIES / src/liba/readdir.s '
          f'RD_SIZE)')
    print(f'[e2e-fs-ls] {len(RO_DIRS)} RO dirs, {len(RO_FILES)} RO files, '
          f'{len(RO_SET_INFO)} post-write metadata patches')
    n = 0

    def _count(*a, **k):
        global n
        n += 1
    cases(_count)
    print(f'[e2e-fs-ls] {n} cases')
