#!/usr/bin/env python3
"""T4 stage-1b, E5's metadata package: chmod + file.

docs/E2E.md sec 4 + CONTRACT.md sec 1: chmod and file have a REAL host
reference on the filesystem, but not one whose ANSWER is trustworthy the
way `sort`/`diff` are -- `/usr/bin/chmod` speaks Unix rwx (a lie on this
filesystem, docs/ANACHRONISMS.md sec W2), and `/usr/bin/file` sniffs
content with an entirely disjoint vocabulary from maux's file_type-only
table. So both tools here use `oracle='VOL'`: the ProDOS volume's OWN
directory entries, read independently by a2til -- a2til WROTE the bytes
(or ProDOS did, and both sides read them), so it is oracle 1, not a
loophole (CONTRACT.md sec 1).

chmod gets a SECOND, stronger assertion per the task brief: the
behavioural CONSEQUENCE of the DESTROY bit (`chmod -d FILE` blocks `rm`;
`chmod +d FILE` un-blocks it) is `oracle='INVARIANT'` -- no host tool's
permission model maps onto ProDOS's D(estroy)/N(rename)/B(ackup) bits
(Unix unlink permission lives on the CONTAINING DIRECTORY, not the
target file -- a structurally different mechanism), so nothing external
computes this answer; it is checked by composing two maux operations
against each other. See INVARIANTS below for the citation docs/E2E.md
sec 7.1 requires.

STREET-LIBRARY LOOP (HACKING.md rule 3) -- handles this module leans on:
  learning:01M0798FFCHB60SWQDE8NQEQXN  GNO/ME: chmod speaks rwdnbi, not
    rwx; FILETYPE is the exec bit. The ruling precedent chmod.s follows,
    verified against src/bin/chmod.s's own header (which cites the same
    learning) and ANACHRONISMS.md sec W2.
  learning:01M0HK4EYPWC2H7M9DYHR9QF2A  SET_FILE_INFO's null_field is 3
    bytes, not 2 -- the exact bug the read-modify-write cases below are
    built to catch (it already bit chmod.s once; chmod.s:286-299 shows
    the FIXED 3-byte SFIPARM_NULL, so this corpus is a regression gate
    on a bug that is currently absent, not a bug hunt).
  learning:01KWK8FZM58BFR1M3CA9BS6KAX / 01KW1CR53VP3ATCXDYWAMQYB6W
    ProDOS date/time packing and the 1940-2039 window -- why a host
    mtime is not comparable and the RAW date bytes are the safer
    primitive (see COMPARATORS['chmod_rmw'] below, which compares the
    4 raw date bytes AND the decoded datetime, per the TL's correction).

CONTRACT EXTENSIONS THIS MODULE ASSUMES (see the final report for the
full list; flagged again at each use site below):

  (1) RO_FILES/MUT_TREES entries are 3- or 4-tuples, not the documented
      2-tuple `(kind, host_bytes)`: `(kind, host_bytes, file_type=None,
      access=None)`. `file` cannot partition by file_type without
      staging distinct file_types (SYS, an out-of-table type, ...), and
      the TL's own correction confirms `prodos.write(file_type=...)` is
      how E1's stager will do this -- `(kind, host_bytes)` alone cannot
      express it. `file_type=None` means "let the stager use the kind's
      default (text->0x04, raw->0x06)"; `access=None` means "leave
      a2til's own write_file/mkdir default of 0xE3" (TL's correction
      point 1) -- chmod deliberately relies on that documented default
      as its own known starting state, matching
      scripts/build_chmod_image.py's STAGED_ACCESS precedent exactly.

  (2) COMPARATORS/synth receive `volume` as an object exposing BOTH a
      pre-run and a post-run read, `volume.pre` and `volume.post`, each
      supporting `.entry(path) -> dict` (access/type/aux_type/eof/
      blocks_used/creation_raw/last_mod_raw/is_dir) -- RAW date bytes
      ONLY, never a decoded datetime (see cmp_chmod_rmw's own docstring
      for why: a2til's Date descriptor RAISES on a genuine ProDOS 2.5
      Extended stamp)
      and `.exists(path) -> bool` (for the DESTROY-bit presence check).
      This is required for chmod's read-modify-write proof: the ONLY
      sound pre-run snapshot is one taken from the STAGED image before
      the emulator ever touches it (scripts/build_chmod_image.py's
      `compute_expectations()`, called on the disk file before
      `check_chmod.py` mounts it in the emulator, is the exact
      precedent). `check_e2e_fs.py` presumably needs to snapshot every
      MUT_TREES path right after staging for this to work -- see the
      report. Every comparator below DEGRADES GRACEFULLY (documents
      what it skips) if only a post-run `volume` is available, so this
      module does not hard-fail if the assumption is wrong, but the
      read-modify-write case is the weaker of its two assertions in
      that case, and the report says so.

  (3) Host tool resolution goes through `_ref_tool()` below, a local
      stand-in for E1's forthcoming `e2e_fsmap.ref_tool()` (resolves
      against an explicit `/bin`, `/usr/bin` list; RAISES rather than
      falling back to a bare-name PATH lookup). TL correction:
      `/usr/bin/chmod` does NOT exist on this host (`/bin/chmod` does)
      -- moot for this module's own cases (neither chmod case uses a
      REF oracle: `/bin/chmod`'s vocabulary, octal/`u+w`, has no
      overlap with `[+-]dnbwr`, so a REF oracle there would be close to
      meaningless -- kept to VOL+INVARIANT only, as instructed).
      `/usr/bin/file` DOES exist and is the one host binary this
      module actually shells out to (the weak cross-check in
      cmp_file_desc), now routed through `_ref_tool('file')` rather
      than a hardcoded path.

Every fixture name in this module is prefixed `M5` to avoid colliding
with another package's RO/MUT names -- RO is a shared namespace across
all six work packages (CONTRACT.md sec 3.1).
"""
import os
import subprocess
from datetime import datetime
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e_limits as L        # noqa: E402
import e2e_compare as C       # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos      # noqa: E402  -- vol_op only (see below)
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

NAME = 'fs_meta'   # chmod + file, for the gate log

def _ref_tool(name):
    """Local stand-in for E1's forthcoming `e2e_fsmap.ref_tool()`
    (CONTRACT EXTENSION (3)). Resolves against an explicit list, never
    a bare-name PATH lookup, and RAISES rather than silently falling
    back -- e2e_corpus.py's own `Case._host_argv` hardcodes
    `/usr/bin/{tool}` and only works today because all nine stage-1
    tools happen to live there; `/usr/bin/chmod` does NOT exist on
    this host (`/bin/chmod` does) -- the exact gap the TL flagged.
    Swap this for `e2e_fsmap.ref_tool` once E1's spine lands; keep the
    RAISE-don't-degrade behaviour if you do."""
    for d in ('/bin', '/usr/bin'):
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
    raise FileNotFoundError(
        f'{name!r} not found in /bin or /usr/bin on this host -- no '
        f'silent PATH fallback (see _ref_tool docstring)')


# ----------------------------------------------------------------------
# ProDOS access-byte bits (inc/mli.equ, chmod.s's own ACC_* names).
# Duplicated here as plain ints rather than parsed from the .equ file:
# these are bit POSITIONS, not tree-tunable limits (docs/E2E.md sec 5's
# "every constant that appears in a check_* ratchet is a boundary
# generator" is about SIZES that change with the tree, not the fixed
# ProDOS 8 TRM access-byte layout, which has been unchanged since 1983).
# ----------------------------------------------------------------------
ACC_DESTROY = 0x80
ACC_RENAME = 0x40
ACC_BACKUP = 0x20
ACC_WRITE = 0x02
ACC_READ = 0x01
ACC_DEFAULT = 0xE3   # a2til's own write_file/mkdir default (D N B W R
                      # all set except the reserved bits) -- TL's
                      # correction point 1; scripts/build_chmod_image.py
                      # asserts this same value as STAGED_ACCESS.

FLAG_BITS = {'d': ACC_DESTROY, 'n': ACC_RENAME, 'b': ACC_BACKUP,
             'w': ACC_WRITE, 'r': ACC_READ}


def _apply_flags(pre_access, flags):
    """The RULED transform this package owns: chmod's flag letters ->
    the resulting access byte, given the PRE-run access byte (read off
    the volume, never invented). `flags` is e.g. '-dnw' or '+dnw'."""
    sign, letters = flags[0], flags[1:]
    mask = 0
    for ch in letters:
        mask |= FLAG_BITS[ch]
    if sign == '+':
        return pre_access | mask
    return pre_access & ~mask & 0xFF


def _chmod_vol_op(path, flags):
    """E7 integration addition (Case.vol_op, e2e_fs_common.py's own
    docstring on why): apply THIS case's own single flags step directly
    to a LIVE mounted scratch volume, via the SAME _apply_flags
    transform cmp_chmod_access checks against -- so
    e2e_fs_selftest.py's host-only run has a real post-mutation access
    byte to judge a 'correct answer' against, not just the untouched
    staged one. Reads the CURRENT (live) access byte rather than a
    remembered pre-run value, so applying every chmod case's vol_op in
    cid order over one mount naturally accumulates -- the same
    cumulative shape tree_seq='s ref_op has, just against the volume."""
    def op(root):
        current = prodos.stat(path).access
        prodos.set_file_info(path, access=_apply_flags(current, flags))
    return op


def _touch_vol_op(path):
    """The selftest's post-mutation model for touch: re-stamp last_mod
    to now, the same field the real tool rewrites via SET_FILE_INFO."""
    def op(root):
        prodos.set_file_info(path, last_mod=datetime.now())
    return op


def _rm_vol_op(path):
    """The other half of the DESTROY-gate pair's simulation: when a
    case's own INVARIANT predicts `rm` SUCCEEDS (chmod-destroy-allows-
    rm), the file must actually be gone from volume.post for
    cmp_rm_status_only's presence check to have anything but a
    trivially-true state to accept. a2til's module-level
    `prodos.remove()` (alias `unlink`) is the MLI DESTROY-equivalent
    for a single file."""
    def op(root):
        prodos.remove(path)
    return op


# ----------------------------------------------------------------------
# file's file_type -> description table.  ONE small RULED vocabulary,
# copied 1:1 from src/bin/file.s:202-224's TYPETBL (11 entries,
# TYPETBL_N asserted against the source below rather than hand-copied).
# This IS the "small RULED entry" the task brief calls for: maux's
# description STRINGS are its own invention (a2til has no such concept),
# so the transform from file_type byte -> label is authored, but the
# PARTITION itself (which files get which label) is read straight off
# the volume's own storage_type/file_type bytes.
# ----------------------------------------------------------------------
_FILE_TABLE = {
    0x0F: 'directory', 0x04: 'ascii text', 0x06: 'binary',
    0xFF: 'system program', 0xFC: 'applesoft program',
    0xFA: 'integer basic program', 0xFB: 'applesoft variables',
    0xFE: 'relocatable object', 0xEF: 'pascal area',
    0xE2: 'appletalk file', 0xB3: 'gs/os application',
}
_STYP_DIR, _STYP_VOLDIR = 0x0D, 0x0F  # file.s:129-132's own two checks

_FSRC = os.path.join(L.ROOT, 'src', 'bin', 'file.s')
try:
    with open(_FSRC) as _fh:
        _file_src = _fh.read()
    assert 'TYPETBL_N   equ   11' in _file_src, (
        'file.s TYPETBL_N is no longer 11 -- _FILE_TABLE above (copied '
        '1:1 from TYPETBL) is now out of sync; update both')
    assert len(_FILE_TABLE) == 11
except FileNotFoundError:
    pass  # tolerate being imported outside the tree (selftest sandboxes)


def _file_description(storage_type, file_type):
    """maux's own DESCRIBE/PRINTDESC logic (file.s:128-179), re-derived
    here from the volume's OWN storage_type/file_type bytes -- this is
    the oracle='VOL' partition, not a hand-typed expectation."""
    if storage_type in (_STYP_DIR, _STYP_VOLDIR):
        return 'directory'
    if file_type in _FILE_TABLE:
        return _FILE_TABLE[file_type]
    return f'unknown type ${file_type:02X}'


# ----------------------------------------------------------------------
# Fixtures.  file's under RO (read-only -- file never mutates anything).
# chmod's under MUT (chmod mutates the access byte in place, and one
# scenario mutates existence via rm, so both need post-run volume reads
# -- CONTRACT.md sec 3.1's MUT_TREES, "read back with prodos.mount/
# scandir/read/unmount").
# ----------------------------------------------------------------------
RO_DIRS = ['M5DIR']

#: NOTE (E7 integration, 2026-08-23): E5 originally wrote these as
#: positional 3-tuples `(kind, host_bytes, file_type_int)` -- its own
#: CONTRACT EXTENSION (1). The spine's actual 3-tuple form (TL
#: integration list item 5, e2e_fsmap.unpack_fixture_spec) is
#: `(kind, host_bytes, meta)` where `meta` is a DICT with optional
#: file_type/aux_type/access/creation/last_mod keys -- reconciled here,
#: same file_type values, no change in fixture intent.
RO_FILES = {
    'M5TXT': ('text', b'file test fixture: seven words on one line\n',
              {'file_type': 0x04}),
    'M5BIN': ('raw', bytes((i * 3 + 7) & 0xFF for i in range(1, 65)),
              {'file_type': 0x06}),
    'M5SYS': ('raw', bytes((0xA9, 0x00, 0x60) * 20), {'file_type': 0xFF}),
    # $19 (AppleWorks ADB, a real Apple type) is outside file.s's
    # 11-entry TYPETBL -- deliberately, to exercise "unknown type $XX".
    # Picked over an arbitrary/unassigned byte because it is a type
    # real Apple II software actually wrote, which is the more honest
    # choice of "a type maux doesn't know" than an invented one.
    'M5UNK': ('raw', bytes((0x11, 0x22, 0x33, 0x44)), {'file_type': 0x19}),
}

MUT_TREES = {
    # Scenario 1: the access-byte transform + the read-modify-write
    # proof.  LOCKFILE takes one chmod (-dnw); RWFILE takes two
    # (-dnw then +dnw), so its OWN final state is a round trip back to
    # the a2til default -- a second, independent check on the same
    # transform in the opposite direction.
    'M5LOCK': {
        'M5LOCKF': ('text', b'this file will be locked\n', {'file_type': 0x04}),
        'M5RWF': ('text', b'this file is locked then unlocked\n', {'file_type': 0x04}),
    },
    # Scenario 2: the DESTROY-bit behavioural consequence.  ONE file,
    # FOUR cases in sequence (-d, rm-must-fail, +d, rm-must-succeed) --
    # check_chmod.py's own two-phase precedent, extended to a full round
    # trip so both directions of the D bit are proven, not just lock.
    'M5DGATE': {
        'M5DFILE': ('text', b'guarded by the destroy bit\n', {'file_type': 0x04}),
    },
    # Scenario 3 (2026-09-01): touch's stamp. Staged with a KNOWN OLD
    # last_mod so "the stamp changed" is decidable from the volume
    # alone; content survival lives in e2e_fs_mutate's twin cases.
    'M5TSTAMP': {
        'M5STAMPF': ('text', b'stamped by touch\n',
                     {'file_type': 0x04,
                      'last_mod': datetime(2001, 3, 5, 8, 15)}),
    },
}

# ----------------------------------------------------------------------
# DIVERGENCE contributions.  Both VOL-oracle cases still get an ENTRIES
# citation: chmod's because the task brief explicitly calls the bit
# transform "a RULED transform -- it is ours"; file's weak /usr/bin/file
# cross-check because comparing to an ACTUAL reference (even a bonus,
# non-authoritative one) needs the same "here is why they differ" ratchet
# as stage 1's DIVERGENCE table, or it is exactly the blanket docs/E2E.md
# sec 4 forbids.
# ----------------------------------------------------------------------
ENTRIES = {
    ('chmod', 'access byte bit arithmetic'): (
        'RULED',
        "chmod's flag letters (d n b w r) map onto the ProDOS access "
        "byte's D=$80/N=$40/B=$20/W=$02/R=$01 bits (src/bin/chmod.s "
        "ACC_DESTROY/ACC_RENAME/ACC_BACKUP/ACC_WRITE/ACC_READ; GNO/ME's "
        "own rwdnbi precedent minus the GS/OS-only i bit, "
        "learning:01M0798FFCHB60SWQDE8NQEQXN). The expected post-chmod "
        "access byte is computed as pre|mask ('+') or pre&~mask ('-'), "
        "where `pre` is the volume's OWN pre-run access byte (also read "
        "via a2til -- never invented, matching "
        "scripts/build_chmod_image.py's STAGED_ACCESS/LOCKED_ACCESS "
        "precedent). This is the one authored transform in this "
        "package; every other assertion reads the volume verbatim."),
    ('file', 'no host correspondence'): (
        'EXCLUDED',
        "/usr/bin/file sniffs file CONTENT with an entirely disjoint "
        "vocabulary ('ASCII text', 'ELF ...', magic-byte matching); "
        "maux's file decides PURELY on the ProDOS file_type/storage_type "
        "bytes (no content sniffing at all -- src/bin/file.s's own "
        "header says so). There is no oracle-1/2 reference for the "
        "STRINGS maux prints; the real oracle is that maux's file "
        "PARTITIONS the tree exactly as the volume's own type bytes do "
        "(oracle='VOL', COMPARATORS['file_desc'] below). One case adds "
        "a WEAK, honestly-graded bonus cross-check against /usr/bin/file "
        "for the plain-text fixture only (both tools should agree it is "
        "text, even though their vocabularies differ) -- see "
        "('file', 'weak host text cross-check')."),
    ('file', 'weak host text cross-check'): (
        'EXCLUDED',
        "For the ascii-text fixture only, /usr/bin/file's output is "
        "expected to contain the substring 'ascii' (case-insensitive) "
        "as a WEAK differential -- both tools independently classify "
        "the same 7-bit, no-control-byte content as text, using "
        "unrelated mechanisms (maux: file_type byte; host: content "
        "sniffing). This is NOT proof of correctness (a wrong maux that "
        "always printed 'ascii text' would still pass), only a sanity "
        "cross-check on top of the real oracle='VOL' assertion. Graded "
        "EXCLUDED rather than RULED because it derives no expected "
        "VALUE from the reference; it only corroborates one already "
        "established by oracle='VOL'."),
}

DEFECTS = {}
#: No KNOWN_DEFECTS entries.  chmod.s's null_field is the fixed 3-byte
#: form (chmod.s:296: `SFIPARM_NULL dfb 0,0,0`) -- the bug
#: learning:01M0HK4EYPWC2H7M9DYHR9QF2A describes is CLOSED in this tree;
#: COMPARATORS['chmod_rmw'] is this package's regression gate against it
#: reappearing, not a pinned-open bug. file.s's TYPETBL/DESCRIBE dispatch
#: was read in full (file.s:1-256) and matches its own header exactly;
#: no divergence between the code and its documented contract was found.

INVARIANTS = {
    'chmod-destroy-blocks-rm': (
        "chmod -d FILE (clearing the DESTROY-enable access bit) causes "
        "a subsequent `rm FILE` to fail (nonzero exit) and FILE remains "
        "present on the volume afterward.",
        "ProDOS's DESTROY-enable access bit has no POSIX/Unix analogue: "
        "Unix unlink(2) permission is governed by the WRITE bit of the "
        "file's CONTAINING DIRECTORY, not a per-file permission bit "
        "(chmod on the target file does not affect whether it can be "
        "rm'd on a host system at all). No host chmod+rm pair can be "
        "run differentially to produce this behaviour, so nothing "
        "external computes the expected answer -- it is checked by "
        "composing two maux operations (chmod, then rm) against each "
        "other and reading the volume's own post-state "
        "(scripts/check_chmod.py's existing rm-vs-locked-file gate is "
        "the precedent this case extends into the e2e corpus)."),
    'chmod-destroy-allows-rm': (
        "chmod +d FILE (re-setting DESTROY-enable on a file previously "
        "locked with -d) causes a subsequent `rm FILE` to succeed (exit "
        "0) and FILE is gone from the volume afterward.",
        "Same reason as chmod-destroy-blocks-rm: no host mechanism maps "
        "onto the ProDOS D bit. This is the OTHER direction of the "
        "same property, run against the SAME file after the same "
        "sequence -- proving +d has a real effect and not merely that "
        "-d did, which a single-direction test could not."),
}

GLOBALS = set()  # nothing here holds for every case unconditionally


# ----------------------------------------------------------------------
# COMPARATORS
# ----------------------------------------------------------------------
def _decode_or_fail(raw):
    got, problems = C.decode_maux_text(raw)
    if problems:
        off, b = problems[0]
        return None, f'{len(problems)} byte(s) with bit 7 clear, first at offset {off} (${b:02X})'
    return got, ''


def _pre_post(volume, case, path):
    """Best-effort adapter over the ASSUMED volume.pre/volume.post
    interface (see the module docstring's CONTRACT EXTENSIONS). Falls
    back to post-only if `volume` turns out to be a plain a2til handle
    instead -- documented, not silent: the caller is told which mode it
    got so it can grade the check honestly.

    E7 integration finding, 2026-08-23: uses `volume.post_at(case)`
    (falls back to plain `.post`/`.pre` if the method is absent) rather
    than `.post` directly -- see Volume.post_at's own docstring. A
    single whole-corpus `.post` snapshot cannot tell cases 65/68 (mid-
    sequence chmod_access checks inside a tree_seq= group) their OWN
    step's expected state, because a LATER case in the same group
    mutates the same file again before the corpus finishes; only
    post_at()'s per-case incremental snapshot (host-only selftest) can.
    This is a genuine limitation of the real run, not merely a selftest
    artifact -- see the final report.

    B3 FIX, 2026-08-23: `post_at()` can now legitimately return None --
    "no sound post-mutation snapshot exists for this case in a real
    run" (see its own docstring) -- rather than silently handing back
    the wrong (whole-corpus-final) one. Returns a 4th value, `have_post`,
    so a comparator can tell "no snapshot was available at all" (degrade
    the METADATA check, but keep whatever is genuinely per-step and
    real) apart from "a snapshot exists and the path is simply absent
    from it" (a real fact -- e.g. a file legitimately deleted by THIS
    case's own terminal rm)."""
    pre = getattr(volume, 'pre', None)
    post_at = getattr(volume, 'post_at', None)
    post = post_at(case) if post_at is not None else getattr(volume, 'post', volume)
    pre_entry = pre.entry(path) if pre is not None else None
    post_entry = post.entry(path) if post is not None else None
    return pre_entry, post_entry, pre is not None, post is not None


def cmp_chmod_access(case, got, ref, volume, hostdir):
    """oracle='VOL': the resulting access byte, against the RULED bit
    transform applied to the volume's OWN pre-run access byte. `case`
    carries the applied flags sequence in `case.chmod_flags` (a list,
    for the two-step round-trip cases).

    B3 FIX, 2026-08-23: `have_post=False` means this case is a
    mid-sequence step in a tree_seq= group whose own watched path
    (case.vol_paths) is touched again by a LATER case before a real
    run's single volume mount ever happens -- see Volume.post_at's own
    docstring for why no sound snapshot exists for it. Degraded, NOT
    failed: the only assertion this comparator can make in that case is
    the one already checked above (chmod's silent-on-success contract),
    which IS genuinely real and per-step (this case's own /mnt/MAUX/OUT/
    Onn file, written when THIS line ran, never touched again). The
    access-byte transform itself goes unverified for this specific
    step -- named explicitly, never silently, via check_e2e_fs.py's own
    printed REDUCED ASSERTION table (e2e_fs_common.reduced_assertion_
    cases), not buried in a passing detail string nobody reads."""
    if got != b'':
        return False, f'chmod must be silent on success; got {got!r}'
    pre_entry, post_entry, have_pre, have_post = _pre_post(
        volume, case, case.chmod_path)
    if not have_pre:
        return False, ('cmp_chmod_access needs a pre-run volume snapshot '
                       '(volume.pre) which this run did not provide -- '
                       'see the module docstring CONTRACT EXTENSION (2)')
    if not have_post:
        return True, ('access-byte transform NOT VERIFIED for this step: '
                      'a real single-final-snapshot run cannot observe it '
                      '(a later case in this tree_seq= group mutates the '
                      'same path again first) -- see check_e2e_fs.py\'s '
                      'REDUCED ASSERTION table; only chmod\'s silent-on-'
                      'success contract, already checked above, is real '
                      'here')
    access = pre_entry['access']
    for flags in case.chmod_flags:
        access = _apply_flags(access, flags)
    got_access = post_entry['access']
    if got_access != access:
        return False, (f'access byte: expected ${access:02X} (from pre '
                       f'${pre_entry["access"]:02X} via {case.chmod_flags}), '
                       f'volume reads ${got_access:02X}')
    return True, ''


_RMW_FIELDS = ('type', 'aux_type', 'eof', 'blocks_used')


def cmp_chmod_rmw(case, got, ref, volume, hostdir):
    """oracle='VOL': every OTHER GET_FILE_INFO field must be
    byte-identical before and after -- the null_field regression gate
    (learning:01M0HK4EYPWC2H7M9DYHR9QF2A).

    RAW BYTES ONLY for the two date fields -- NEVER the decoded
    datetime. TL correction: a2til's `Date` descriptor RAISES
    (`datetime(year, month, day, hour, minute)` throwing ValueError) on
    a genuine ProDOS 2.5 EXTENDED-format stamp, exactly the shape
    learning:01M0BWH5TJAX1FJ6PJ4FZDV7P4 measured ($97E4 -> hour=151).
    Reading `.creation`/`.last_mod` at all on such a volume would crash
    this comparator before it could report anything useful; reading
    ONLY the 4 raw bytes at each field's offset (mod_date at
    GFIPARM+0x18/0x21, matching learning:01M0HK4EYPWC2H7M9DYHR9QF2A's
    own offset table) is format-blind and cannot raise. It is also
    STRICTLY MORE SENSITIVE than a decoded comparison for this specific
    regression: two different raw byte patterns can decode to visually
    identical or even equal-looking datetimes only by accident, never
    the reverse, so raw-byte equality is both necessary and sufficient
    -- a decoded fallback added nothing but a crash risk and was
    removed. `e2e_fsmap.raw_date_bytes()` is presumably E1's home for
    this exact read; `_pre_post()`'s ASSUMED interface only needs
    `creation_raw`/`last_mod_raw` (4 bytes each) from `.entry()`, not
    the decoded `creation`/`last_mod` this module no longer reads.

    E7 integration fix, 2026-08-23: this comparator never checked `got`
    at all, unlike cmp_chmod_access's `if got != b'': FAIL` -- the
    selftest's own mutation battery caught it directly: a synthesised
    'spurious output'/'spurious diagnostic' mutant was ACCEPTED, because
    nothing here ever looked at the bytes chmod actually printed.
    chmod's silent-on-success contract is exactly as much this
    comparator's job to check as cmp_chmod_access's.

    B3 FIX, 2026-08-23: same have_post degrade as cmp_chmod_access --
    see that function's own docstring."""
    if got != b'':
        return False, f'chmod must be silent on success; got {got!r}'
    pre_entry, post_entry, have_pre, have_post = _pre_post(
        volume, case, case.chmod_path)
    if not have_pre:
        return False, ('cmp_chmod_rmw needs a pre-run volume snapshot '
                       '(volume.pre); see CONTRACT EXTENSION (2)')
    if not have_post:
        return True, ('read-modify-write proof NOT VERIFIED for this '
                      'step: a real single-final-snapshot run cannot '
                      'observe it (a later case in this tree_seq= group '
                      'mutates the same path again first) -- see '
                      'check_e2e_fs.py\'s REDUCED ASSERTION table; only '
                      'chmod\'s silent-on-success contract, already '
                      'checked above, is real here')
    problems = []
    for f in _RMW_FIELDS:
        if pre_entry[f] != post_entry[f]:
            problems.append(f'{f}: pre={pre_entry[f]!r} post={post_entry[f]!r}')
    for rawf in ('creation_raw', 'last_mod_raw'):
        if pre_entry.get(rawf) != post_entry.get(rawf):
            problems.append(f'{rawf}: pre={pre_entry.get(rawf)!r} '
                            f'post={post_entry.get(rawf)!r} -- RAW BYTES '
                            f'DIFFER (the null_field-shift shape of bug)')
    if problems:
        return False, 'read-modify-write violated:\n  ' + '\n  '.join(problems)
    return True, ''


def cmp_file_desc(case, got, ref, volume, hostdir):
    """oracle='VOL': maux's `<name>: <description>` lines against the
    partition implied by the volume's OWN storage_type/file_type bytes,
    via the ONE small RULED vocabulary table (_FILE_TABLE)."""
    # Terminator and line count are checked SEPARATELY, on purpose.
    # docs/E2E.md sec 9.6 records exactly this hole: "eleven tokenising
    # comparators accepted a truncated final byte" in stage 1, because
    # blindly stripping one trailing '' after a split cannot distinguish
    # a correctly-terminated multi-line output from one whose final CR
    # was silently dropped. `file` writes ONE trailing $8D per name with
    # no exception, so a missing one is a real, catchable defect.
    if not got.endswith(b'\n'):
        return False, (f'output does not end with a line terminator '
                       f'(a dropped trailing $8D): {got!r}')
    lines = got[:-1].split(b'\n')
    if len(lines) != len(case.argv):
        return False, (f'{len(lines)} lines for {len(case.argv)} '
                       f'names: {lines!r}')
    for name, line in zip(case.argv, lines):
        want_prefix = f'{name}: '.encode('ascii')
        if not line.startswith(want_prefix):
            return False, f'line {line!r} does not start with {want_prefix!r}'
        got_desc = line[len(want_prefix):].decode('ascii')
        entry = volume.post.entry(case.file_paths[name]) \
            if hasattr(volume, 'post') else volume.entry(case.file_paths[name])
        want_desc = _file_description(entry['storage_type'], entry['type'])
        if got_desc != want_desc:
            return False, (f'{name}: maux says {got_desc!r}, volume-derived '
                           f'expectation is {want_desc!r} (storage_type='
                           f'${entry["storage_type"]:02X} type='
                           f'${entry["type"]:02X})')
    # Bonus, honestly-graded weak differential (cites ('file', 'weak
    # host text cross-check')): for the fixture we KNOW is plain text,
    # /usr/bin/file should also call it text, by an unrelated mechanism
    # (content sniffing, not a file_type byte). Self-contained -- writes
    # the fixture's own host bytes to a temp file rather than depending
    # on an assumed hostdir layout for RO fixtures.
    if getattr(case, 'weak_ref_check', False):
        kind, data, _ft = RO_FILES['M5TXT']
        with tempfile.NamedTemporaryFile(suffix='.txt') as tf:
            tf.write(data)
            tf.flush()
            try:
                out = subprocess.run([_ref_tool('file'), '-b', tf.name],
                                     capture_output=True, timeout=5).stdout
            except Exception as e:            # pragma: no cover
                return False, f'weak /usr/bin/file cross-check errored: {e}'
        if b'ascii' not in out.lower():
            return False, (f"weak cross-check: /usr/bin/file said "
                           f"{out!r}, expected it to mention 'ascii' too "
                           f"(EXCLUDED entry ('file','weak host text "
                           f"cross-check') -- this only corroborates, "
                           f"never overrides, the oracle='VOL' check "
                           f"above)")
    return True, ''


def cmp_rm_status_only(case, got, ref, volume, hostdir):
    """Used by the DESTROY-gate rm cases. Deliberately does NOT pin
    rm's diagnostic wording (docs/E2E.md sec 9.7: diagnostic text is
    not differential and this tranche has no reference for it either);
    it asserts only whether output is empty (success shape) or
    non-empty (failure shape), matching `case.expect_status`.

    THE REAL ASSERTION is the post-run volume state: does the file
    still exist (case.expect_present)? A comparator that only checked
    output shape would be nearly vacuous here -- a maux that printed
    nothing AND left the file behind on a "should succeed" case would
    still pass the output-only half. Presence is checked via
    `volume.post_at(case)` (E7 integration fix, 2026-08-23): this
    case's own tree_seq= group has a LATER member that deletes the
    same file, so the single whole-corpus `.post` would show it gone
    even for the EARLIER (blocked) rm -- see Volume.post_at's own
    docstring.

    B3 FIX, 2026-08-23: `volume.post_at(case)` can now return None --
    "no sound post-mutation snapshot for THIS case" (see post_at's own
    docstring) -- rather than the wrong (whole-corpus-final) one, which
    used to make `post.exists(...)` throw AttributeError on a genuinely
    deleted file for a mid-sequence case ('NoneType is not
    subscriptable'-shaped, per the task's own repro). NEVER acceptable,
    per the task brief -- a case asserting a file is gone must assert
    that, not crash. When no snapshot is available, the presence half
    of this assertion is degraded (not verified), and the case still
    passes on the two REAL per-step facts checked above: exit-status
    shape and diagnostic termination, both read straight from this
    case's OWN /mnt/MAUX/OUT/Onn file, untouched by anything that runs
    after it."""
    want_status = case.expect_status
    if want_status == 0:
        if got != b'':
            return False, f'rm should be silent on success; got {got!r}'
    else:
        if got == b'':
            return False, 'rm should have printed a diagnostic on failure'
        # E7 integration fix, 2026-08-23: docs/E2E.md sec 9.6's own
        # named lesson, applied here too -- a comparator that only
        # checks non-emptiness cannot tell a real diagnostic from one
        # whose trailing $8D got silently dropped. Not checking WORDING
        # (still deliberate, per this function's own docstring), only
        # that a diagnostic line is properly terminated.
        if not got.endswith(b'\n'):
            return False, (f'rm diagnostic does not end with a line '
                           f'terminator: {got[-16:]!r}')
        # TEETH, 2026-08-24. Non-emptiness plus a terminator cannot
        # tell a real refusal from one byte of noise -- and for the
        # blocked case the presence half below degrades to None (a
        # later member of the same tree_seq= group deletes the same
        # file), so those two shape checks WERE the whole assertion.
        # The selftest duly walked a 'flip one bit' mutant straight
        # past it the moment the case came out of the hang quarantine.
        #
        # rm's diagnostic is ERRMSG + the argv token VERBATIM + $8D
        # (src/bin/rm.s:69-95 -- it re-fetches the token with GETARG
        # because PUTS clobbered PTR0), so requiring the OPERAND to
        # appear costs nothing, needs no reference, and pins the very
        # byte that mutant flips: it lands on the path's last
        # character. Still NOT a wording pin -- the "rm: cannot unlink"
        # prefix stays deliberately unchecked, per this function's own
        # docstring. What is asserted is that rm named the file it
        # refused, which is what the invariant actually claims.
        if case.argv:
            want_path = case.argv[-1].encode('ascii')
            if want_path not in got:
                return False, (f'rm printed a diagnostic but did not '
                               f'name the file it refused: expected '
                               f'{want_path!r} within {got!r}')
    post_at = getattr(volume, 'post_at', None)
    post = post_at(case) if post_at is not None else (
        volume.post if hasattr(volume, 'post') else volume)
    if post is None:
        return True, ('file-presence check NOT VERIFIED for this step: '
                      'a real single-final-snapshot run cannot observe it '
                      '(a later case in this tree_seq= group mutates the '
                      'same path again first) -- see check_e2e_fs.py\'s '
                      'REDUCED ASSERTION table; only rm\'s exit-status/'
                      'diagnostic shape, already checked above, is real '
                      'here')
    exists = post.exists(case.chmod_path)
    if exists != case.expect_present:
        return False, (f'volume state: {case.chmod_path} exists={exists}, '
                       f'expected exists={case.expect_present} (the whole '
                       f'point of the DESTROY-bit invariant -- output shape '
                       f'alone proves nothing)')
    return True, ''


def cmp_file_partial(case, got, ref, volume, hostdir):
    """oracle='VOL', for the ONE hit-then-miss case: `file` continues
    past a GET_FILE_INFO failure (file.s :next after PRINTFAIL/ERRFLAG)
    and still describes every name that DID stat successfully.
    `case.expect_status` is the whole point of the case (ERRFLAG makes
    it 1 deterministically, straight from file.s's own EXIT call --
    see this function's own note on why `status_ruled` does NOT apply
    here) but the OUTPUT is checked in full too, same discipline as
    every other case: `case.hit_paths` (name -> volume relpath) for the
    names expected to succeed, `case.miss_paths` (the exact argv
    strings expected to fail) for the ones that don't, IN ARGV ORDER --
    file.s processes argv[1..] strictly left to right, one PUTS/PRINTFAIL
    per name, so a hit and a miss interleave in exactly the order typed.

    STATUS_RULED CONSIDERATION (the TL's new CONTRACT sec 5.3 field):
    deliberately NOT used here. `status_ruled` exempts a case from the
    exit-status check when a RULED/EXCLUDED divergence entry explains
    why maux's status legitimately differs from what a NAIVE (usually
    host-convention-derived) expectation would say. This case has no
    REF oracle and no host convention to diverge from -- ERRFLAG's
    value (1, because a GET_FILE_INFO failure occurred) is read
    straight off file.s's own deterministic logic, not overridden or
    ruled away from anything. There is nothing here for status_ruled
    to exempt; forcing it in would be the same shape of misuse as
    manufacturing a REF case just to have one."""
    post = volume.post if hasattr(volume, 'post') else volume
    # Emission order is argv order, but descriptions go to STDOUT
    # (fully buffered to a file) and "cannot stat" to STDERR (line
    # mode) -- the merged capture is what C.merge_streams says it is
    # (docs/PERF-PLAN.md step 4's probed buffering, 2026-08-28).
    events = []
    for name in case.argv:
        if name in case.hit_paths:
            entry = post.entry(case.hit_paths[name])
            desc = _file_description(entry['storage_type'], entry['type'])
            events.append(('out', f'{name}: {desc}\n'.encode('ascii')))
        else:
            events.append(('err', f'{name}: cannot stat\n'.encode('ascii')))
    want = C.merge_streams(events)
    if got != want:
        return False, f'expected {want!r}, got {got!r}'
    return True, ''


def cmp_touch_stamp(case, got, ref, volume, hostdir):
    """oracle='VOL': touch on an existing file is SILENT and rewrites
    last_mod away from the staged 2001 stamp, leaving the content-
    bearing fields alone. RAW BYTES ONLY for the stamp compare, the
    cmp_chmod_rmw precedent -- format-blind, cannot raise. A zero
    post-stamp fails too: the harness machine has a live Timemaster,
    so "touch cleared the date" is a bug, not a clockless truth."""
    if got != b'':
        return False, f'touch must be silent on success; got {got!r}'
    pre_entry, post_entry, have_pre, have_post = _pre_post(
        volume, case, case.touch_path)
    if not have_pre:
        return False, ('cmp_touch_stamp needs a pre-run volume snapshot '
                       '(volume.pre); see CONTRACT EXTENSION (2)')
    if not have_post or post_entry is None:
        return True, ('stamp change NOT VERIFIED for this step (no '
                      'sound post snapshot) -- only the silent-on-'
                      'success contract, checked above, is real here')
    old = pre_entry.get('last_mod_raw')
    new = post_entry.get('last_mod_raw')
    if new == old:
        return False, (f'last_mod unchanged ({old!r}) -- touch '
                       f'stamped nothing')
    if not new or not any(new):
        return False, ('post-run last_mod is zero -- a cleared date '
                       'is not a touch on a clocked machine')
    for f in ('type', 'eof'):
        if pre_entry.get(f) != post_entry.get(f):
            return False, (f'{f} changed: {pre_entry.get(f)!r} -> '
                           f'{post_entry.get(f)!r} -- touch must not '
                           f'rewrite it')
    return True, ''


COMPARATORS = {
    'chmod_access': cmp_chmod_access,
    'touch_stamp': cmp_touch_stamp,
    'chmod_rmw': cmp_chmod_rmw,
    'file_desc': cmp_file_desc,
    'file_partial': cmp_file_partial,
    'rm_status_only': cmp_rm_status_only,
}


# ----------------------------------------------------------------------
# synth() -- what a CORRECT maux would have emitted, for the selftest's
# mutation teeth (CONTRACT.md sec 7). Never used by the real gate.
# ----------------------------------------------------------------------
def synth(case, ref_out, ref_err, ref_extra, volume, hostdir):
    if case.compare == 'chmod_access':
        return b''
    if case.compare == 'touch_stamp':
        return b''
    if case.compare == 'chmod_rmw':
        return b''
    if case.compare == 'rm_status_only':
        # The operand is the argv token verbatim (src/bin/rm.s:69-95),
        # not a placeholder: cmp_rm_status_only now requires the
        # diagnostic to NAME the file rm refused, so a synthetic
        # "correct" answer with a stand-in path is not a correct answer.
        return b'' if case.expect_status == 0 else C.encode_maux_text(
            b'rm: cannot unlink ' + case.argv[-1].encode('ascii') + b'\n')
    if case.compare == 'file_desc':
        lines = []
        for name in case.argv:
            entry = volume.post.entry(case.file_paths[name]) \
                if hasattr(volume, 'post') else volume.entry(case.file_paths[name])
            desc = _file_description(entry['storage_type'], entry['type'])
            lines.append(f'{name}: {desc}')
        text = ''.join(l + '\n' for l in lines)
        return C.encode_maux_text(text.encode('ascii'))
    if case.compare == 'file_partial':
        post = volume.post if hasattr(volume, 'post') else volume
        # Mirror cmp_file_partial's merge exactly (stderr lands before
        # the buffered stdout) or the selftest's teeth go vacuous.
        events = []
        for name in case.argv:
            if name in case.hit_paths:
                entry = post.entry(case.hit_paths[name])
                desc = _file_description(entry['storage_type'], entry['type'])
                events.append(
                    ('out', C.encode_maux_text(
                        f'{name}: {desc}\n'.encode('ascii'))))
            else:
                events.append(
                    ('err', C.encode_maux_text(
                        f'{name}: cannot stat\n'.encode('ascii'))))
        return C.merge_streams(events)
    raise AssertionError(f'no synthesiser for compare={case.compare!r}')


# ----------------------------------------------------------------------
# Cases
# ----------------------------------------------------------------------
def cases(add):
    RO = '/mnt/MAUX/RO'
    MUT = '/mnt/MAUX/MUT'

    # ---- file -----------------------------------------------------
    c = add('file', case_id='fs_meta.file-dir',
            argv=[f'{RO}/M5DIR'], oracle='VOL', compare='file_desc',
            note='storage_type $0D/$0F -> "directory"')
    c.file_paths = {f'{RO}/M5DIR': f'{RO}/M5DIR'}

    c = add('file', case_id='fs_meta.file-text',
            argv=[f'{RO}/M5TXT'], oracle='VOL', compare='file_desc',
            diverges=[('file', 'no host correspondence'),
                      ('file', 'weak host text cross-check')],
            note='file_type $04 TXT -> "ascii text"; carries the weak '
                 '/usr/bin/file cross-check')
    c.file_paths = {f'{RO}/M5TXT': f'{RO}/M5TXT'}
    c.weak_ref_check = True

    c = add('file', case_id='fs_meta.file-bin',
            argv=[f'{RO}/M5BIN'], oracle='VOL', compare='file_desc',
            diverges=[('file', 'no host correspondence')],
            note='file_type $06 BIN -> "binary"')
    c.file_paths = {f'{RO}/M5BIN': f'{RO}/M5BIN'}

    c = add('file', case_id='fs_meta.file-sys',
            argv=[f'{RO}/M5SYS'], oracle='VOL', compare='file_desc',
            diverges=[('file', 'no host correspondence')],
            note='file_type $FF SYS -> "system program"')
    c.file_paths = {f'{RO}/M5SYS': f'{RO}/M5SYS'}

    c = add('file', case_id='fs_meta.file-unknown',
            argv=[f'{RO}/M5UNK'], oracle='VOL', compare='file_desc',
            diverges=[('file', 'no host correspondence')],
            note='file_type $19 (AppleWorks ADB) is outside TYPETBL\'s '
                 '11 entries -> "unknown type $19"')
    c.file_paths = {f'{RO}/M5UNK': f'{RO}/M5UNK'}

    c = add('file', case_id='fs_meta.file-multiple',
            argv=[f'{RO}/M5TXT', f'{RO}/M5BIN', f'{RO}/M5DIR'],
            oracle='VOL', compare='file_desc',
            diverges=[('file', 'no host correspondence')],
            note='multiple names in one call -- ARGIDX loop + ": " '
                 'separator + CR per line, three different partitions '
                 'in one invocation')
    c.file_paths = {f'{RO}/M5TXT': f'{RO}/M5TXT', f'{RO}/M5BIN': f'{RO}/M5BIN',
                    f'{RO}/M5DIR': f'{RO}/M5DIR'}

    # ---- chmod: access-byte transform + read-modify-write ---------
    path = f'{MUT}/M5LOCK/M5LOCKF'
    c = add('chmod', case_id='fs_meta.chmod-lock-access',
            argv=['-dnw', path], tree='M5LOCK', tree_seq=True,
            oracle='VOL', compare='chmod_access',
            diverges=[('chmod', 'access byte bit arithmetic')],
            note='lock: -dnw clears D/N/W, matching the LOCK/UNLOCK '
                 'idiom chmod.s documents in its own header')
    c.chmod_path = f'{MUT}/M5LOCK/M5LOCKF'
    c.vol_paths = (c.chmod_path,)
    c.chmod_flags = ['-dnw']
    c.vol_op = _chmod_vol_op(c.chmod_path, '-dnw')

    c = add('chmod', case_id='fs_meta.chmod-lock-rmw',
            argv=['-dnw', path], tree='M5LOCK', tree_seq=True,
            oracle='VOL', compare='chmod_rmw',
            note='read-modify-write: type/aux_type/eof/blocks_used/'
                 'creation/last_mod byte-identical to the pre-run '
                 'staged state -- the null_field regression gate')
    c.chmod_path = f'{MUT}/M5LOCK/M5LOCKF'
    c.vol_paths = (c.chmod_path,)
    c.vol_op = _chmod_vol_op(c.chmod_path, '-dnw')

    path2 = f'{MUT}/M5LOCK/M5RWF'
    c = add('chmod', case_id='fs_meta.chmod-rw-lock',
            argv=['-dnw', path2], tree='M5LOCK', tree_seq=True,
            oracle='VOL', compare='chmod_access',
            diverges=[('chmod', 'access byte bit arithmetic')],
            note='round trip step 1/2: lock RWFILE')
    c.chmod_path = f'{MUT}/M5LOCK/M5RWF'
    c.vol_paths = (c.chmod_path,)
    c.chmod_flags = ['-dnw']
    c.vol_op = _chmod_vol_op(c.chmod_path, '-dnw')

    c = add('chmod', case_id='fs_meta.chmod-rw-unlock',
            argv=['+dnw', path2], tree='M5LOCK', tree_seq=True,
            oracle='VOL', compare='chmod_access',
            diverges=[('chmod', 'access byte bit arithmetic')],
            note='round trip step 2/2: unlock RWFILE back to the a2til '
                 'default -- proves the SET direction, not only CLEAR')
    c.chmod_path = f'{MUT}/M5LOCK/M5RWF'
    c.vol_paths = (c.chmod_path,)
    c.chmod_flags = ['-dnw', '+dnw']
    c.vol_op = _chmod_vol_op(c.chmod_path, '+dnw')

    c = add('chmod', case_id='fs_meta.chmod-rw-rmw',
            argv=['+dnw', path2], tree='M5LOCK', tree_seq=True,
            oracle='VOL', compare='chmod_rmw',
            note='read-modify-write across the FULL round trip (two '
                 'SET_FILE_INFO calls) -- the stronger of the two RMW '
                 'cases, since a one-byte slip that happened to cancel '
                 'out over two calls would still be caught by the '
                 'per-call access check above')
    c.chmod_path = f'{MUT}/M5LOCK/M5RWF'
    c.vol_paths = (c.chmod_path,)
    c.vol_op = _chmod_vol_op(c.chmod_path, '+dnw')

    # ---- chmod: the DESTROY-bit behavioural consequence ------------
    dpath = f'{MUT}/M5DGATE/M5DFILE'
    c = add('chmod', case_id='fs_meta.chmod-clear-d',
            argv=['-d', dpath], tree='M5DGATE', tree_seq=True,
            oracle='VOL', compare='chmod_access',
            diverges=[('chmod', 'access byte bit arithmetic')],
            note='clear DESTROY only (n/b/w untouched) -- sets up the '
                 'behavioural-consequence pair below')
    c.chmod_path = f'{MUT}/M5DGATE/M5DFILE'
    c.vol_paths = (c.chmod_path,)
    c.chmod_flags = ['-d']
    c.vol_op = _chmod_vol_op(c.chmod_path, '-d')

    c = add('rm', case_id='fs_meta.rm-destroy-blocked',
            argv=[dpath], tree='M5DGATE', tree_seq=True,
            oracle='INVARIANT', invariant='chmod-destroy-blocks-rm',
            compare='rm_status_only',
            note='rm on a -d file must fail; file must survive '
                 '(scripts/check_chmod.py precedent, extended here)')
    c.expect_status = 1
    c.chmod_path = f'{MUT}/M5DGATE/M5DFILE'
    c.vol_paths = (c.chmod_path,)
    c.expect_present = True
    # No vol_op: this rm is predicted to FAIL, so nothing should
    # change -- the file legitimately stays exactly as staged.

    c = add('chmod', case_id='fs_meta.chmod-set-d',
            argv=['+d', dpath], tree='M5DGATE', tree_seq=True,
            oracle='VOL', compare='chmod_access',
            diverges=[('chmod', 'access byte bit arithmetic')],
            note='re-set DESTROY on the SAME file -- proves +d has a '
                 'real effect, not merely that -d did')
    c.chmod_path = f'{MUT}/M5DGATE/M5DFILE'
    c.vol_paths = (c.chmod_path,)
    c.chmod_flags = ['-d', '+d']
    c.vol_op = _chmod_vol_op(c.chmod_path, '+d')

    c = add('rm', case_id='fs_meta.rm-destroy-allowed',
            argv=[dpath], tree='M5DGATE', tree_seq=True,
            oracle='INVARIANT', invariant='chmod-destroy-allows-rm',
            compare='rm_status_only',
            note='rm on the now-+d file must succeed; file must be gone')
    c.expect_status = 0
    c.chmod_path = f'{MUT}/M5DGATE/M5DFILE'
    c.vol_paths = (c.chmod_path,)
    c.expect_present = False
    # This rm is predicted to SUCCEED -- simulate the deletion on
    # the live scratch volume so volume.post genuinely reflects
    # it (see _rm_vol_op's own docstring).
    c.vol_op = _rm_vol_op(c.chmod_path)

    # ---- touch: the stamp itself (2026-09-01, FLEET F.3) -------------
    tpath = f'{MUT}/M5TSTAMP/M5STAMPF'
    c = add('touch', case_id='fs_meta.touch-stamp', argv=[tpath],
            tree='M5TSTAMP', oracle='VOL', compare='touch_stamp',
            note='touch an EXISTING file: last_mod leaves the staged '
                 '2001 stamp (raw-byte compare, format-blind) while '
                 'type/eof survive; silent, exit 0. The created-file '
                 'and content-survival halves live in e2e_fs_mutate.')
    c.touch_path = tpath
    c.vol_paths = (tpath,)
    c.vol_op = _touch_vol_op(tpath)

    # ---- file: continues past a failure, exits 1 (TL's flagged case) --
    RO = '/mnt/MAUX/RO'
    c = add('file', case_id='fs_meta.file-continues-after-miss',
            argv=[f'{RO}/M5TXT', f'{RO}/M5NOSUCH'], oracle='VOL',
            compare='file_partial',
            diverges=[('file', 'no host correspondence')],
            note='one hit, one miss, in argv order -- file.s continues '
                 'past a GET_FILE_INFO failure and still describes the '
                 'name that stat succeeded on; ERRFLAG makes the exit '
                 'status 1 (see cmp_file_partial\'s own docstring for '
                 'why status_ruled does NOT apply -- there is no host '
                 'convention here for it to rule away)')
    c.hit_paths = {f'{RO}/M5TXT': f'{RO}/M5TXT'}
    c.expect_status = 1
