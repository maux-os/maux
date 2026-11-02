#!/usr/bin/env python3
"""The mapping between the ProDOS volume and the host mirror directory.

T4 CONTRACT sec 2: this is the ONLY place the volume<->host mapping lives.
It is a piece of the harness (staging + reading back), not a substitution
applied at a comparison site -- every comparator in e2e_fs_*.py routes
name/block/date/order questions through here rather than re-deriving them.

Four jobs, CONTRACT sec 2(a)-(d):

  (a) NAMES -- a generation constraint, not a translation.  check_name()/
      check_path() raise on any illegal ProDOS name, so a module that
      builds an illegal RO_FILES/MUT_TREES key finds out at ITS OWN
      import time (learning:01M07G8WT2R3G2P87EK1DNPVYP: an illegally
      named file sits on disk perfectly formed and is PERMANENTLY
      UNREACHABLE through any MLI pathname -- catching this at generation
      is the only place it can be caught at all).
  (b) BLOCK COUNTS -- prodos_alloc_blocks() is an INDEPENDENT reimplementation
      of ProDOS's own seedling/sapling/tree/directory allocation rule (TRM
      ch 5 sec B.3), so check_blocks_used() can cross-check a2til's stored
      blocks_used against it and raise on disagreement (CONTRACT sec 2b:
      "a wrong a2til is a loud failure, not a silent oracle").  Precedent:
      scripts/build_du_image.py's hand_blocks()/compute_expected().
  (c) TIMESTAMPS -- raw_date_bytes()/decode_date_raw() replicate src/bin/
      ls.s's OWN dash-field rule (ls.s:711-733: blank iff the date word is
      zero, or the RAW hour>=24, or the RAW minute>=60) directly off the
      4 raw bytes, WITHOUT going through a2til's Date descriptor -- whose
      __get__ calls datetime(y,m,d,h,mi) and RAISES for an out-of-range
      hour/minute.  That is not a hypothetical: ProDOS 2.5's Extended date
      format (learning:01M07A3XXC1SS5SQYH4CZCPV44) stamps files with
      exactly such values even when the caller passes cdate=0/ctime=0, and
      a 2.5 kernel was the tree's documented target until 2026-10-08 (it
      boots 2.4 by ruling now; docs/PRODOS-VERSION.md).  a2til's
      own decode (entry.creation/entry.last_mod) is exposed separately, as
      a second independent read, for callers that have already confirmed
      via decode_date_raw() that the stamp is legacy-valid.
  (d) ORDERING -- ls_sort_key() is STRCMPI's order (ls.s:528; case-fold,
      which for this all-uppercase-stored domain is just .upper()) for the
      REF oracle; volume_dir_order() is the volume's own on-disk slot
      order via a2til scandir, for find/du's walk oracle (raw ProDOS
      directory order, which the host does not share).

Plus the tree-state reader (read_tree()) that poststate=True cases use to
compare a mutated subtree against a host reference tree, and the staging
writer (stage_tree()) that builds /mnt/MAUX/RO and /mnt/MAUX/MUT/Cnn.

-- TL CORRECTION 2026-08-23, CONTRACT sec 3 -- ------------------------------
`a2til mirror` does NOT recurse into subdirectories and does NOT create or
mirror directories at all (`~/src/a2til/a2til/mirror.py:232-234`; it does
`if e.is_dir(): continue` on the image side and filters `is_file()` on the
host side).  So /mnt/MAUX/RO and /mnt/MAUX/MUT are staged and read back with the
**`prodos` module** directly (mkdir/write/set_file_info to build, mount/
scandir/read/unmount to read back) -- the same house tool
scripts/build_e2e_image.py's strip_volume() and scripts/check_v1_system.py:
164-196 already use for exactly this "boot, guest mutates, inspect the
volume host-side" shape.  `a2til mirror` is used ONLY for the two FLAT
directories /mnt/MAUX/E2E (SCRIPT, ST) and /mnt/MAUX/OUT (Onn) -- see
scripts/build_e2efs_image.py and scripts/check_e2e_fs.py.

-- TL TRAP #1, CONTRACT sec 3.4 -- ------------------------------------------
`prodos.scandir()` (the SESSION-level module function, used throughout this
file) yields `DirEntry`, whose `is_dir()`/`is_file()` are METHODS.
`prodos.stat()` -- also a session-level function, but it forwards to
`Volume.entry_for()` -- returns the RAW `FileDescEnt`, whose `is_dir`/
`is_extended` are PROPERTIES.  Mixing the calling convention up gives
`bool(bound_method)`, which is always True and never raises.  This file
uses `entry.is_dir()` (parens) ONLY on objects that came from
`prodos.scandir()`/`DirEntry.stat()`'s caller-side check, and `entry.is_dir()`
(no parens) ONLY on objects that came from `prodos.stat()`/`entry_for()`.
Grep this file for `.is_dir()` before adding a third call site.

-- TL TRAP #2, CONTRACT sec 3.4 -- ------------------------------------------
`prodos.write()`/`prodos.mkdir()` hardcode `access=0xE3` and
`creation=last_mod=datetime.now()` (minute-truncated) and take no
access=/date= arguments.  `set_meta()` below is the required follow-up
(`prodos.set_file_info`) for a module that needs a KNOWN starting access
byte (E5's chmod fixtures) or a KNOWN date (so `ls -l`'s date column is a
REAL date, not ls.s's dash-field -- CONTRACT sec 2c's "if a2til can set
one").
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import convert, prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

# ---------------------------------------------------------------------------
# Layout constants -- CONTRACT sec 3.1 (corrected).  IMG_CTL matches
# e2e_corpus.IMG_DIR (both are '/mnt/MAUX/E2E'); the two images are different
# volumes so the reused name is not a collision, but src/test/e2etestb.s:188
# hardwires this exact path, and CORP.IMG_DIR is asserted equal to it by
# build_e2e_image.py -- e2efs shares the same parent process and the same
# hardwired script location.
# ---------------------------------------------------------------------------
IMG_ROOT = '/mnt/MAUX'
IMG_CTL = '/mnt/MAUX/E2E'    # SCRIPT, ST      -- FLAT, mirror pair "ctl"
IMG_OUT = '/mnt/MAUX/OUT'    # O01..Onn        -- FLAT, mirror pair "out"
IMG_RO = '/mnt/MAUX/RO'      # immutable tree  -- prodos module, NEVER mirrored
IMG_MUT = '/mnt/MAUX/MUT'    # Cnn/ per-case   -- prodos module, NEVER mirrored
STATUS_NAME = 'ST'

#: CONTRACT sec 3.2's closing rule, enforced at generation (e2e_fs_common.
#: Registry rejects any case whose argv/sh_words names a path under these):
#: the two mirrored directories must never be an OPERAND a mutating tool
#: could act on, or the "structurally impossible" argument stops holding.
NO_OPERAND_PREFIXES = (IMG_OUT, IMG_CTL)

# ---------------------------------------------------------------------------
# (a) Names
# ---------------------------------------------------------------------------
#: letters, digits, periods; must start with a letter; <=15 chars.
_NAME_RE = re.compile(r'^[A-Za-z][A-Za-z0-9.]{0,14}$')


def check_name(name):
    """Raise ValueError on any name ProDOS's pathname parser would refuse.
    Call this at your MODULE's import time (top-level, over your RO_FILES/
    RO_DIRS/MUT_TREES keys) so an illegal name is a traceback at `import
    e2e_fs_yours`, not a file that silently can never be opened."""
    if not isinstance(name, str) or not _NAME_RE.match(name):
        raise ValueError(
            f'illegal ProDOS name {name!r}: must be 1-15 characters, begin '
            f'with a letter, and contain only letters, digits and periods '
            f'(learning:01M07G8WT2R3G2P87EK1DNPVYP -- ProDOS validates this '
            f'in the PATHNAME PARSER, not just at creation, so an illegally '
            f'named file sits on disk perfectly formed and is permanently '
            f'unreachable, not merely odd)')
    return name


def check_path(path):
    """Validate every '/'-separated component of a relative tree path
    ('SUB/DEEPER/FILE.TXT') -- each component is independently a ProDOS
    directory/file name and independently subject to check_name()."""
    path = str(path).strip('/')
    if not path:
        raise ValueError('empty path')
    for part in path.split('/'):
        check_name(part)
    return path


def check_operand(path):
    """CONTRACT sec 3.2: no case may name a path under /mnt/MAUX/OUT or
    /mnt/MAUX/E2E as an operand -- the one door back into the two-way-mirror
    hazard (a case pointed at its own output file, or at the control
    directory's SCRIPT/ST).  Raises; used by e2e_fs_common.Registry."""
    for prefix in NO_OPERAND_PREFIXES:
        if path == prefix or path.startswith(prefix + '/'):
            raise ValueError(
                f'{path!r} is under {prefix!r}, one of the two MIRRORED '
                f'directories -- CONTRACT sec 3.2 forbids naming it as an '
                f'operand (that is the one way back into the two-way-'
                f'mirror hazard)')
    return path


# ---------------------------------------------------------------------------
# (b) Block counts
# ---------------------------------------------------------------------------
def prodos_alloc_blocks(eof, is_dir=False):
    """ProDOS's OWN block-allocation rule (TRM ch 5 sec B.3), computed
    independently of a2til so it can be used to CROSS-CHECK a2til's own
    stored blocks_used (CONTRACT sec 2b).  Extends scripts/build_du_image.
    py's hand_blocks() (seedling/sapling only) to tree files and to
    directories, which this tranche's larger RO/MUT trees can reach where
    du's small fixture set never did.

    A directory's block chain is a flat doubly-linked list, not a
    seedling/sapling/tree -- no index block, and ProDOS always keeps a
    directory's eof an exact multiple of 512 (one dir block = one chain
    link), so blocks = eof/512 exactly.
    """
    if is_dir:
        if eof % 512 != 0:
            raise ValueError(f'directory eof {eof} is not a multiple of '
                             f'512 -- not a normal ProDOS directory chain')
        return eof // 512
    if eof <= 512:
        return 1                                   # seedling
    data_blocks = -(-eof // 512)                    # ceil
    if data_blocks <= 256:
        return data_blocks + 1                      # sapling: +1 index
    index_blocks = -(-data_blocks // 256)            # ceil
    return data_blocks + index_blocks + 1            # tree: + master index


def check_blocks_used(path):
    """Read a2til's stored blocks_used for `path` (an already-mounted
    absolute ProDOS path) AND independently recompute it via
    prodos_alloc_blocks(); raise AssertionError on disagreement.  Returns
    the (agreed) block count.  Extended (forked) files are out of scope --
    entry.eof is the KEY BLOCK size for those (learning:
    01KWK8CC663WNT6WXAYDST777W), not the data size this formula assumes,
    and this tranche stages no forked files."""
    entry = prodos.stat(path)                # FileDescEnt: .is_dir is a PROPERTY
    if entry.is_extended():
        raise NotImplementedError(
            f'{path}: extended (forked) file -- out of scope for '
            f'check_blocks_used (its eof is the key-block size, not the '
            f'data size; see learning:01KWK8CC663WNT6WXAYDST777W)')
    a2til_blocks = entry.blocks_used
    independent = prodos_alloc_blocks(entry.eof, is_dir=entry.is_dir())
    if a2til_blocks != independent:
        raise AssertionError(
            f'{path}: a2til blocks_used={a2til_blocks} disagrees with the '
            f'independently computed ProDOS allocation rule '
            f'({independent}, from eof={entry.eof} is_dir={entry.is_dir()}) '
            f"-- CONTRACT sec 2b: 'a wrong a2til is a loud failure, not a "
            f"silent oracle.'")
    return a2til_blocks


# ---------------------------------------------------------------------------
# (c) Timestamps
# ---------------------------------------------------------------------------
#: FileDescEnt offsets (a2til/prodos.py:315-330): creation = Date(0x18),
#: last_mod = Date(0x21).  Each Date is 4 bytes: date word (LE u16), then
#: minute, then hour.
_DATE_OFFSET = {'creation': 0x18, 'last_mod': 0x21}


def raw_date_bytes(path, which='last_mod'):
    """The 4 RAW date bytes for `path` (already-mounted absolute path),
    read directly off the entry's backing memory -- NEVER through a2til's
    Date descriptor, whose __get__ calls datetime(y, m, d, h, mi) and
    RAISES for an out-of-range hour/minute.  That is not hypothetical:
    ProDOS 2.5's Extended date format (learning:01M07A3XXC1SS5SQYH4CZCPV44)
    stamps hour>=24/minute>=60 values even when the caller asked for
    cdate=0/ctime=0, and vendor/ProDOS-2.5.bin -- this tree's own vendored
    kernel -- is exactly that release.  learning:01M0BQQ6XN04NQAWE0WAQX1RG5:
    compare raw date/time bytes, never decode.
    """
    off = _DATE_OFFSET[which]
    entry = prodos.stat(path)
    return bytes(entry._mem[off:off + 4])


def decode_date_raw(raw4):
    """Manual decode mirroring src/bin/ls.s's OWN dash-field rule
    (ls.s:711-733) bit for bit: blank iff the date word is zero, or the
    RAW hour byte (offset 3) is >=24, or the RAW minute byte (offset 2) is
    >=60.  Never raises -- that is the entire point over a2til's Date
    descriptor.  Note ls.s's own caveat (ls.s:721-725): a masked Extended
    stamp can still land inside 0..23/0..59 by chance and print a
    PLAUSIBLE GARBAGE DATE rather than a dash; this function reproduces
    that exact blind spot rather than fixing it, because it exists to
    predict what ls.s will print, not to be a better decoder."""
    word = raw4[0] | (raw4[1] << 8)
    minute, hour = raw4[2], raw4[3]
    blank = (word == 0) or (hour >= 24) or (minute >= 60)
    out = {'raw': bytes(raw4), 'word': word, 'raw_hour': hour,
          'raw_minute': minute, 'blank': blank, 'legacy_valid': not blank}
    if not blank:
        out['day'] = word & 0x1f
        out['month'] = (word >> 5) & 0x0f
        out['year_raw'] = (word >> 9) & 0x7f
        out['year'] = out['year_raw'] + (2000 if out['year_raw'] < 40 else 1900)
        out['hour'] = hour
        out['minute'] = minute
    return out


def a2til_decoded_date(path, which='last_mod'):
    """a2til's own Date-descriptor decode, as the SECOND independent read
    the VOL oracle needs (CONTRACT sec 1: 'a2til is a second, independent
    implementation of ProDOS').  Callers MUST check decode_date_raw()'s
    'legacy_valid' first -- this raises ValueError (from datetime()) on
    exactly the Extended-format stamps that check catches.  Deliberately
    not caught here: swallowing it would be the same 'normaliser that
    accepts both encodings' mistake e2e_compare.py's header warns against
    for text, applied to dates instead."""
    entry = prodos.stat(path)
    return entry.last_mod if which == 'last_mod' else entry.creation


def set_meta(path, access=None, creation=None, last_mod=None):
    """TL TRAP #2: prodos.write()/mkdir() hardcode access=0xE3 and
    creation=last_mod=datetime.now(), with no access=/date= parameters.
    This is the required follow-up (prodos.set_file_info) for a module
    that needs a KNOWN starting access byte (chmod fixtures) or a KNOWN
    date (so ls -l's date column is live, not a dash-field, and so E2's
    year-pivot fixture can be a deliberately OLD date -- there is no
    other way to stage one, since prodos.write()'s hardcode is exactly
    what this function exists to override).

    CAUTION (TL, 2026-08-23): `Volume.set_file_info` OVERWRITES every
    field it is given, wholesale, via a2til's own implementation -- this
    function is not exposed to the null_field parmlist bug that class of
    corruption comes from (learning:01M0HK4EYPWC2H7M9DYHR9QF2A: a wrong
    null_field silently corrupts mod_date/mod_time in a way nothing
    notices until something DECODES the date), because it calls a2til's
    code rather than writing the parmlist itself. It IS exposed to
    calling set_file_info when nothing needed changing: an unnecessary
    call here would silently re-stamp mod_date/mod_time to
    datetime.now() and destroy the very fixture a module is staging.
    stage_tree()'s caller below only calls this when the fixture's `meta`
    actually names access/creation/last_mod -- never unconditionally.
    """
    kwargs = {}
    if access is not None:
        kwargs['access'] = access
    if creation is not None:
        kwargs['creation'] = creation
    if last_mod is not None:
        kwargs['last_mod'] = last_mod
    if kwargs:
        prodos.set_file_info(path, **kwargs)


# ---------------------------------------------------------------------------
# (d) Ordering
# ---------------------------------------------------------------------------
def ls_sort_key(name):
    """`ls` sorts case-insensitively via STRCMPI (src/bin/ls.s:528).  This
    fixture domain is entirely uppercase-STORED ProDOS names (job (a): no
    upcasing step, because there is nothing to upcase), so plain
    str.upper() order IS STRCMPI's order; /usr/bin/ls under LC_ALL=C is
    therefore a direct oracle for both order and content."""
    return name.upper()


def volume_dir_order(path):
    """Names at `path` (already-mounted absolute directory path) in RAW
    ProDOS directory (on-disk slot) order, via a2til `prodos.scandir` --
    CONTRACT sec 2d: the oracle for find/du's walk order, which the host
    filesystem does not share (no host directory preserves ProDOS's own
    creation-order slot layout).  a2til's scandir walks a directory
    block's entries in on-disk slot order, which IS what find.s/du.s see
    when they walk the same directory."""
    return [e.name for e in prodos.scandir(path)]


# ---------------------------------------------------------------------------
# Tree state -- the read-back half of staging, used by poststate=True cases
# and by check_e2e_fs.py.  NEVER a2til mirror (CONTRACT sec 3.0/3.2): this
# IS the safe read-back mirror cannot provide for a subtree.
# ---------------------------------------------------------------------------
def read_tree(path):
    """Recursively read the volume subtree at `path` (a mounted absolute
    ProDOS path) into a plain nested dict:

        {name: {'is_dir': bool, 'type': int, 'size': int|None,
                'blocks_used': int, 'content': bytes|None,
                'children': {...}|None}}

    Uses ONLY prodos.scandir/prodos.read (session-level; DirEntry, methods
    -- see the module docstring's TL TRAP #1).  This is what a
    poststate=True case compares the mutated volume subtree against."""
    out = {}
    for entry in prodos.scandir(path):
        is_dir = entry.is_dir()                 # DirEntry: METHOD
        node = {
            'is_dir': is_dir,
            'type': entry.type,
            'blocks_used': entry.stat().blocks_used,
        }
        if is_dir:
            node['size'] = None
            node['content'] = None
            node['children'] = read_tree(entry.path)
        else:
            node['size'] = entry.size
            node['content'] = prodos.read(entry.path)
            node['children'] = None
        out[entry.name] = node
    return out


def snapshot_volume(root):
    """Recursively walk the mounted volume from `root` (e.g. '/mnt/MAUX')
    and capture EVERY entry's full GET_FILE_INFO-equivalent metadata into
    a FLAT {absolute_path: fields} dict -- the backing store for
    e2e_fs_common.VolumeSnapshot.  TL, 2026-08-23: a comparator proving
    a chmod/mv/cp read-modify-write left every OTHER field byte-identical
    (the null_field corruption class, learning:01M0HK4EYPWC2H7M9DYHR9QF2A,
    is invisible until something DECODES the date) needs a BEFORE and an
    AFTER capture of the SAME fields, not a live re-derivation each time.

    fields = {'is_dir', 'type', 'aux_type', 'eof', 'blocks_used',
              'access', 'storage_type', 'creation_raw', 'last_mod_raw'}
    -- the two date fields are the RAW 4-byte lists from raw_date_bytes(),
    never decoded (job (c)'s own rule), so JSON can carry them (a plain
    list of ints) and a comparator can compare them byte-for-byte without
    this module or a2til's Date descriptor getting a chance to raise on
    an Extended-format stamp.

    Uses ONLY prodos.scandir (session-level DirEntry; see the module
    docstring's TL TRAP #1) -- never Volume.scandir()'s raw FileDescEnt.
    """
    out = {}

    def walk(path):
        for entry in prodos.scandir(path):
            is_dir = entry.is_dir()             # DirEntry: METHOD
            fde = entry.stat()                  # the raw FileDescEnt
            out[entry.path] = {
                'is_dir': is_dir,
                'type': fde.type,
                'aux_type': fde.aux_type,
                'eof': fde.eof,
                'blocks_used': fde.blocks_used,
                'access': fde.access,
                'storage_type': fde.storage_type,
                'creation_raw': list(raw_date_bytes(entry.path, 'creation')),
                'last_mod_raw': list(raw_date_bytes(entry.path, 'last_mod')),
            }
            if is_dir:
                walk(entry.path)
    walk(root)
    return out


# ---------------------------------------------------------------------------
# Staging -- builds /mnt/MAUX/RO and /mnt/MAUX/MUT/Cnn with prodos.mkdir/write,
# per CONTRACT sec 3.0's correction.  Never a2til mirror.
# ---------------------------------------------------------------------------
def encode_fixture(kind, data):
    """Host bytes -> image bytes, for a (kind, data) fixture spec.  The
    ONLY encoder used anywhere in this tranche (CONTRACT sec 6: 'Never
    hand-roll the high-bit encoder') -- a2til's own
    convert.text_from_host(high_bit=True), the same function stage 1's
    e2e_corpus.to_image_bytes and its DOS 3.3 path use."""
    if kind == 'text':
        return convert.text_from_host(data, high_bit=True)
    if kind == 'raw':
        return data
    raise ValueError(f'unknown fixture kind {kind!r}; must be "text" or "raw"')


#: A file-spec's default metadata, when the 3-tuple's `meta` dict omits a
#: key or the spec is only a 2-tuple.  file_type=$04 (TXT)/aux_type=$0000
#: are the convention every stage-1 fixture already uses.
DEFAULT_FILE_TYPE = 0x04
DEFAULT_AUX_TYPE = 0x0000

#: The `meta` dict's keys that go through set_meta()'s prodos.set_file_info
#: follow-up rather than prodos.write()'s own arguments -- TL refinement,
#: 2026-08-23: file_type/aux_type are write_file() PARAMETERS (no
#: separate call needed), but access/creation/last_mod are NOT -- and
#: creation/last_mod exist ONLY as this follow-up (prodos.write() hard-
#: codes datetime.now(), no way to ask it for an old date at creation
#: time; E2 needs a deliberately OLD fixture to exercise ls -l's
#: year-pivot decode).
_SET_INFO_KEYS = ('access', 'creation', 'last_mod')


def unpack_fixture_spec(spec):
    """(kind, host_bytes) or (kind, host_bytes, meta) -> (kind, data,
    file_type, aux_type, set_info).  TL addition/refinement, 2026-08-23
    (CONTRACT sec 5.1's RO_FILES/MUT_TREES value shape): `meta` is a
    dict with up to FIVE optional keys -- file_type (E4's mv/BIN case,
    E5's `file` unknown-type case), aux_type, access (E5's chmod
    fixtures), creation, last_mod (E2's year-pivot fixture). `set_info`
    is the SUBSET of {access, creation, last_mod} the spec actually
    named (skipping any key present but None), for the caller to check
    non-empty before ever calling set_meta() -- see set_meta()'s own
    docstring on why an UNNECESSARY call is itself a hazard. A bare
    2-tuple still works (everything defaults) so existing 2-tuple specs
    (this file's own smoke case) are unaffected."""
    kind, data = spec[0], spec[1]
    meta = spec[2] if len(spec) > 2 else {}
    file_type = meta.get('file_type', DEFAULT_FILE_TYPE)
    aux_type = meta.get('aux_type', DEFAULT_AUX_TYPE)
    set_info = {k: meta[k] for k in _SET_INFO_KEYS if meta.get(k) is not None}
    return kind, data, file_type, aux_type, set_info


def stage_tree(image_root, files, extra_dirs=()):
    """Stage `files` (relpath -> (kind, host_bytes) or (kind, host_bytes,
    meta), see unpack_fixture_spec()) plus any deliberately-EMPTY
    `extra_dirs` under `image_root` (already mounted), via
    prodos.mkdir/prodos.write(/set_meta for a `meta['access']`).
    Directories are created depth-first (parents before children, both
    ones implied by a file's own path and ones in extra_dirs). Returns
    the list of image file paths written.

    NEVER a2til mirror -- CONTRACT sec 3.0: mirror does not recurse into
    subdirectories and does not create or mirror directories on either
    side at all, so a directory-tree corpus cannot be staged with it.

    `image_root` itself is created if missing (its OWN parent must
    already exist -- e.g. IMG_MUT before IMG_MUT/C31); idempotent, so a
    second stage_tree() call against an already-created root (IMG_RO,
    shared across every RO-contributing module) is a no-op here.
    """
    try:
        prodos.mkdir(image_root)
    except FileExistsError:
        pass
    dirs = set(check_path(d) for d in extra_dirs)
    for relpath in files:
        check_path(relpath)
        parts = relpath.split('/')
        for i in range(1, len(parts)):
            dirs.add('/'.join(parts[:i]))
    for d in sorted(dirs, key=lambda p: p.count('/')):
        prodos.mkdir(f'{image_root}/{d}')
    written = []
    for relpath, spec in files.items():
        kind, data, ftype, atype, set_info = unpack_fixture_spec(spec)
        img_bytes = encode_fixture(kind, data)
        img_path = f'{image_root}/{relpath}'
        prodos.write(img_path, img_bytes, file_type=ftype, aux_type=atype,
                    overwrite=True)
        if set_info:
            # ONLY when the fixture's meta actually named access/creation/
            # last_mod -- see set_meta()'s docstring: an unconditional call
            # here would silently re-stamp dates prodos.write() already
            # set, destroying the very fixture being staged.
            set_meta(img_path, **set_info)
        written.append(img_path)
    return written


def host_stage_tree(host_root, files, extra_dirs=()):
    """The HOST-side twin of stage_tree(): writes the same relpaths under
    `host_root` in HOST form (kind='text' -> host-native LF bytes
    unchanged; kind='raw' -> unchanged), so /usr/bin/<tool> has an
    identical-looking tree to run against (CONTRACT sec 2a: 'the host
    mirror uses the IDENTICAL names').  `meta` (file_type/access), if a
    spec carries one, has no host-filesystem equivalent and is ignored
    here -- ProDOS type/access are properties this tranche's REF oracle
    never asks the host about. Empty extra_dirs are created too, so a
    host `find`/`du` sees the same empty-directory shape.

    E7 integration fix, 2026-08-23: `host_root` itself is now created
    UNCONDITIONALLY (mirroring stage_tree()'s own unconditional
    `prodos.mkdir(image_root)`), not only as a side effect of having a
    file or extra_dirs entry under it. A MUT_TREES entry that is
    deliberately EMPTY (e2e_fs_mutate.py's cases 11/12: "SRC
    deliberately not staged") previously left NO host directory at all
    while the image side always got one via stage_tree() -- an
    asymmetry that broke every poststate=True comparison for such a
    case (shutil.copytree(pristine_mut/<tree>, ...) raising
    FileNotFoundError, since the tree never existed on the host side)."""
    os.makedirs(host_root, exist_ok=True)
    for d in extra_dirs:
        os.makedirs(os.path.join(host_root, check_path(d)), exist_ok=True)
    for relpath, spec in files.items():
        check_path(relpath)
        kind, data, _ftype, _atype, _set_info = unpack_fixture_spec(spec)
        full = os.path.join(host_root, relpath)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, 'wb') as fh:
            fh.write(data)


def to_host_path(image_path, host_ro, host_mut):
    """Map an image path under IMG_RO or IMG_MUT to its host-mirror twin
    by prefix substitution -- CONTRACT sec 2's mapping job, and the ONLY
    place this substitution happens (a piece of the harness, not a
    substitution at a comparison site: every reference invocation and
    every ref_op routes a path through here).  Pure prefix replacement,
    never a translation -- job (a) means the names are already identical."""
    for prefix, hostdir in ((IMG_RO, host_ro), (IMG_MUT, host_mut)):
        if image_path == prefix or image_path.startswith(prefix + '/'):
            rel = image_path[len(prefix):].lstrip('/')
            return os.path.join(hostdir, rel) if rel else hostdir
    raise ValueError(f'{image_path!r} is not under {IMG_RO} or {IMG_MUT} -- '
                     f'no host mirror twin exists for it')


# ---------------------------------------------------------------------------
# Live per-call reads -- E7 integration addition, 2026-08-23.  E2 (ls) and
# E3 (find/du) each assumed a `volume` object exposing methods this module
# did not originally have (module docstrings: `volume.readdir()`/`.gfi()`
# for E2, `volume.scandir()`/`.blocks_used()` for E3), independently of
# each other and of the VolumeSnapshot shape E5 assumed.  Rather than force
# either package to redesign its comparators, the spine grows the union of
# what was actually asked for -- these are thin, LIVE (mounted-volume)
# reads, used only when a Volume has `.root` set (a real boot in
# check_e2e_fs.py, or a scratch volume e2e_fs_selftest.py builds and mounts
# for exactly this purpose -- there being no other way to hand a VOL-oracle
# comparator real GET_FILE_INFO data with no emulator).
# ---------------------------------------------------------------------------
class _Entry:
    """A plain, read-only stand-in for the per-entry object E2's readdir/
    gfi and E5's file-description comparators expect: `.name`, `.type`,
    `.storage_type`, `.eof`, `.blocks_used`, `.raw_date` (4 RAW last_mod
    bytes -- job (c)'s own rule: never decoded here, same reason
    raw_date_bytes() itself never decodes), `.is_dir()`."""
    __slots__ = ('name', 'type', 'storage_type', 'eof', 'blocks_used',
                'raw_date', 'is_dir')

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)


def gfi_entry(path):
    """GET_FILE_INFO-equivalent read for one already-mounted absolute
    path -- E2's assumed `volume.gfi(image_path)`."""
    entry = prodos.stat(path)                 # FileDescEnt: properties
    return _Entry(name=path.rsplit('/', 1)[-1], type=entry.type,
                 storage_type=entry.storage_type, eof=entry.eof,
                 blocks_used=entry.blocks_used,
                 raw_date=raw_date_bytes(path, 'last_mod'),
                 is_dir=entry.is_dir())


def readdir_entries(path):
    """One level of children of an already-mounted absolute directory
    path, each in gfi_entry()'s shape -- E2's assumed
    `volume.readdir(image_dir_path)`.  Order is on-disk (scandir) order;
    every consumer in e2e_fs_ls.py re-sorts with its own case-fold key,
    so this function does not sort."""
    out = []
    for e in prodos.scandir(path):             # DirEntry: is_dir() METHOD
        fde = e.stat()
        out.append(_Entry(name=e.name, type=fde.type,
                          storage_type=fde.storage_type, eof=fde.eof,
                          blocks_used=fde.blocks_used,
                          raw_date=raw_date_bytes(e.path, 'last_mod'),
                          is_dir=fde.is_dir()))
    return out


def live_scandir(path):
    """Pass-through to `prodos.scandir()` -- E3's assumed
    `volume.scandir(abs_image_path)`, whose whole interface (`.name`,
    `.is_dir()` a METHOD, `.stat().blocks_used`) IS a2til's own DirEntry
    already (CONTRACT sec 3.4's own trap), so no adapter is needed here,
    only the live-mount requirement callers must satisfy."""
    return list(prodos.scandir(path))


def live_blocks_used(path):
    """`prodos.stat(path).blocks_used` for an already-mounted absolute
    path -- E3's assumed `volume.blocks_used(abs_image_path)`."""
    return prodos.stat(path).blocks_used


if __name__ == '__main__':
    # A quick self-report; scripts/e2e_fs_selftest.py has the real teeth
    # (it builds a scratch volume with a2til and proves check_blocks_used/
    # decode_date_raw against it).
    for name in ('HELLO', 'a.b.c', 'MY-FILE', '.profile', '2start',
                'FOURTEENCHR12', 'FIFTEENCHARS12'):
        try:
            check_name(name)
            print(f'  legal   {name!r}')
        except ValueError as e:
            print(f'  illegal {name!r}: {e}')
    print(f'prodos_alloc_blocks(512) = {prodos_alloc_blocks(512)}')
    print(f'prodos_alloc_blocks(513) = {prodos_alloc_blocks(513)}')
    print(f'prodos_alloc_blocks(256*512) = {prodos_alloc_blocks(256*512)}')
    print(f'prodos_alloc_blocks(256*512+1) = {prodos_alloc_blocks(256*512+1)}')
