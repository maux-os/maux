#!/usr/bin/env python3
"""Build the ProDOS-hosted interactive maux shell image (`make play-image`)."""
import os
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.dirname(os.path.abspath(__file__))
CARRIER_IMG = os.environ.get('PRODOS_CARRIER_IMG',
                             os.path.join(ROOT, 'vendor', 'prodos-basic.po'))
CARRIER_VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')
KERNEL_BIN = os.environ.get('PRODOS_KERNEL_BIN',
                            os.path.join(ROOT, 'vendor', 'ProDOS-2.4.bin'))
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXPLAY.SYSTEM')
# -- the `bye` resident (docs/BYE-SLICE1.md), NOT putbin'd into
# -- MAUXPLAY.SYSTEM any more (2026-09-25): it is DATA, staged
# -- here as a plain file and loaded by procbye.s's PBY_LOAD_RES
# -- at `bye` time. Embedding it cost every kernel image that
# -- wanted `bye` 768 always-resident bytes for a blob that runs
# -- a few thousand cycles per call -- growth that pushed
# -- MAUXPLAY.SYSTEM's own end past the PT_HOLD ceiling
# -- check_kernel_images.py's check_pt_hold_headroom() gates.
#
# 2026-09-27 (docs/KSEG.md): BYERES_BIN is byeres.bin ALONE again.
# The 2026-09-26 slice 2 concatenation (byeres.bin + byelaunch.bin
# into byefull.bin) retired the same day the launch blob moved into
# the kernel cold segment: byelaunch.s is now `put` directly into
# playtest.s's own `org KSEG_ORG` block and staged as the separate
# `KSEG` file (below), loaded by KSEG_LOAD, not concatenated onto
# BYERES and read by PBY_LOAD_RES's old chunked loop. See
# inc/byeres.equ's own retirement note (BYE2_ORG/BYE_COMBO_LEN/
# BL2_PATH_A) for the full reasoning.
BYERES_BIN = os.path.join(ROOT, 'build', 'byeres.bin')
# -- the kernel cold segment (docs/KSEG.md "The file"): split off
# -- MAUXPLAY.SYSTEM's own build by scripts/split_kseg.py (Makefile,
# -- the $(PLAYTESTBLK) rule) into a SIBLING file, never `putbin`'d
# -- into the .SYSTEM itself -- a whole-file ProDOS load would land
# -- straight on the harness's own poked result cells, the exact
# -- failure the parked /dev branch hit before this design existed.
KSEG_BIN = os.path.join(ROOT, 'build', 'MAUXPLAY_KSEG')
# -- the play-only low segment (docs/LOOP-S1.md), main $1300, staged
# -- beside KSEG and loaded by the same KSEG_LOAD at boot.
LSEG_BIN = os.path.join(ROOT, 'build', 'MAUXPLAY_LSEG')
# -- the `bye PATH.SYSTEM` launch's own worked example and gate
# -- fixture (docs/BYE.md, src/test/byetenant.s) -- a real
# -- ProDOS 8 .SYSTEM, staged at a fixed path so `bye
# -- /mnt/MAUX/BYETENANT.SYSTEM` can name it.
BYETENANT_BIN = os.path.join(ROOT, 'build', 'byetenant.bin')
BYETENANTD_BIN = os.path.join(ROOT, 'build', 'byetenantd.bin')
OUT_IMG = os.path.join(ROOT, 'build', 'play.po')

# -- UTIL_BINS is DERIVED from the Makefile's own UTILS variable, not
# -- hand-enumerated. The two used to drift: this list was hand-written
# -- and carried only 20 of the 33 programs in UTILS, so the one image a
# -- human actually boots was two waves behind the tree it came from
# -- (found 2026-08-23, docs/PLAN.md). Re-parsing the Makefile here would
# -- be a SECOND Makefile parser (the house-precedent rule in HACKING.md
# -- this project has been bitten by four times) -- so this imports
# -- scripts/check_manifests.py's own parse_makefile_vars()/expand_str()
# -- instead of re-implementing them.
sys.path.insert(0, SCRIPTS)
import check_manifests as _cm  # noqa: E402
import imglock  # noqa: E402


def _makefile_utils():
    """The Makefile's UTILS variable, expanded, in its own declared
    order -- ground truth for "which programs exist to ship"."""
    text = open(os.path.join(ROOT, 'Makefile'), errors='replace').read()
    raw_vars = _cm.parse_makefile_vars(text)
    return _cm.expand_str(raw_vars, 'UTILS').split()


# -- Declared exclusions from the play image: name -> reason. Every name
# -- in the Makefile's UTILS that is NOT shipped on this image must
# -- appear here, or scripts/check_manifests.py's derived play-roster
# -- check (CHECK 7) fails -- that is the anti-drift gate for the bug
# -- above: UTILS gaining a program neither shipped nor excluded here is
# -- exactly the shape that went unnoticed for two waves.
#
# `ld` is NOT a member of UTILS at all -- it is built by its own
# Makefile rule ($(BUILD)/ld.bin, not $(UTIL_BINS)) and has its own gate
# (check-ld) and its own image (ld-image). It is out of scope for this
# list, not excluded from it; do not add it here.
#
# Sizes measured directly (`wc -c`) 2026-08-23, this build: as.bin =
# 16,027 B, ld.bin (out of scope, measured for comparison only) =
# 20,123 B.
PLAY_EXCLUDE = {
    'as': '16,027 B -- has its own gate (check-as) and its own image '
          '(as-image); the play image is meant to be usable, not an '
          'exhaustive copy of the whole toolchain.',
    'dd': 'file-level dd (TASKS.md, check-dd). Excluded 2026-09-08: '
          'the play image root is near the ProDOS ~51-entry cap and the '
          'derived proshim/mlival images overflowed it; also its '
          "lowercase name collides case-insensitively with check-play's "
          "own `MKDIR /mnt/MAUX/DD` test. build_dd_image.py stages it.",
    'bpatch': 'the spec-driven binary patcher (check-bpatch). Excluded '
              '2026-09-08 for the same root-cap reason as dd; '
              'build_bpatch_image.py stages it.',
    'plasma': 'the native PLASMA VM seed (TASKS.md #20, check-plasma). '
              'Excluded 2026-09-08 for the root-cap reason; '
              'build_plasma_image.py stages it.',
        'proshim': 'the ProDOS-8 .SYSTEM host verb (TASKS.md #19). Has its '
               'own gate (check-proshim) and image (proshim.po, which '
               'stages the binary itself), and there is no .SYSTEM '
               'tenant on the play volume for it to host -- so it earns '
               'no seat on the LIVE image, same reasoning as `as`.',
}

UTIL_NAMES = [name for name in _makefile_utils() if name not in PLAY_EXCLUDE]
UTIL_BINS = [(name, os.path.join(ROOT, 'build', f'{name}.bin'))
             for name in UTIL_NAMES]

#: A 4 MiB ProDOS block-device volume, enlarged from 800K on 2026-09-19
#: after complete manual coverage left only 46 free blocks. The earlier
#: 800K expansion replaced the 280-block carrier: on 2026-08-23 S2's MKPATH dot-path fix
#: added 158 bytes to each of 26 utilities, and `make play-image` died
#: with `no free blocks on volume` -- the first symptom of the overflow
#: being a mid-sweep FAIL in FOUR gates (check-play, -play80, -play80n,
#: -vc) that have nothing to do with pathnames.  The carrier had been
#: nearly full since the roster went from 20 programs to 31 the same
#: morning, and nothing measured or reported the margin.
#:
#: Same recipe and the same argument as scripts/build_e2e_image.py's own
#: VOL_BLOCKS: a2til's `create` formats an EMPTY volume, so blocks 0 and
#: 1 -- the ProDOS boot loader, the one thing on the carrier that is not
#: a file -- are spliced across verbatim.  The boot loader's only job is
#: to find and load `PRODOS` out of the volume directory, which is
#: size-independent.
#:
#: This is the image a HUMAN sits down at, so the answer to "it does not
#: fit" is a bigger disk, not a shorter list of programs.  Trimming the
#: roster would undo commit 97ed36e, made the same morning precisely
#: because the playground was two waves behind the tree.
VOL_BLOCKS = 8192
#: The RELEASE disk (build_full_image.py, docs/FULLDISK.md) is the same
#: tree on ProDOS's largest volume: a 16-bit block count, 32 MB, a
#: 16-block bitmap. The size lives here beside VOL_BLOCKS so the release
#: packager, the determinism gate and the builder cannot disagree.
FULL_BLOCKS = 65535
#: The release FILE is one zero block longer than the volume it holds
#: (docs/RELEASE.md): MAME's AppleIISd refuses a 65,535-block file and
#: takes a 65,536-block (32 MiB) one, which is also the shape the GEM CD
#: ships its 32 MB volumes in. build/full.po stays FULL_BLOCKS for the gates.
RELEASE_FILE_BLOCKS = FULL_BLOCKS + 1
BOOT_BYTES = 1024          # blocks 0 and 1: the ProDOS boot loader

# ProDOS entry dates: one explicit timestamp for every release image,
# defined in scripts/prodos_dates.py (shared with build_full_image and
# build_demo_images, which must not import this file for it).
from prodos_dates import IMAGE_TIMESTAMP, normalize_image_dates  # noqa: E402,F401

# -- Sample data, so the new tools have something to chew on the
# -- moment the shell comes up. High-bit ASCII, CR-terminated --
# -- maux's own text convention (src/bin/sh.s, "INPUT ENCODING").
def _hilines(*lines):
    out = b''
    for ln in lines:
        out += bytes(ord(c) | 0x80 for c in ln) + b'\x8d'
    return out


def _esc(s):
    """High-bit ASCII bytes for a console control string -- maux's
    escape parser reads ESC/'['/digits/final all with bit 7 set, the
    form vi itself emits (viscreen.s VI_EMIT_SUD, VI_PUT2D)."""
    return bytes(ord(c) | 0x80 for c in s)


def _ildl_probe(final):
    """A raw-escape probe for the card/terminal IL (ESC[nL) and DL
    (ESC[nM) region scroll (tty2.s TTY_CSI_IL/DL). Clears, paints 18
    rows R01..R18 by ABSOLUTE cursor address (no scrolling), then at
    screen row 5 runs `final` (the IL or DL escape), and parks the
    cursor at row 20 so the shell prompt that returns after `cat`
    lands BELOW the asserted region and cannot shift it. check_ildl.py
    cats this and asserts the region moved exactly n rows."""
    out = _esc('\x1b[2J')                       # clear + home
    for r in range(1, 19):                      # R01..R18, absolute
        out += _esc(f'\x1b[{r};1H') + _esc(f'R{r:02d}')
    out += _esc('\x1b[5;1H') + _esc(final)      # the IL/DL at row 5
    out += _esc('\x1b[20;1H')                   # park cursor low
    return out


def _escs_probe(n=16000):
    """check-vi-bang's killed_midcsi case (ccae082: the console's escape
    parser must not survive a force-killed writer mid-CSI): ONE control
    sequence that never ends -- `ESC [` and then `1;` repeated `n`
    times with no final byte (32 KB: it must still be draining when
    the case's two-second killer fires). A `cat` of this file is
    therefore mid-sequence at EVERY point of its drain, so the kill lands
    mid-CSI regardless of phase (the first draft, 400 repeats of a
    complete ESC[1;1H, was only likely to, and its tuned wait broke on
    the box). Any of cat's bytes still queued in the tty when it dies
    drain afterwards as bare `1;1;` parameters -- visible text once the
    parser is reset, never a sequence that could eat the prompt. Raw
    bytes, cat'd like ALTPRIV/ILDL* above: a typed ESC never reaches
    the parser through the cooked line editor."""
    return _esc('\x1b[' + '1;' * n)


def _park(row):
    """Position at `row` (1-based) and ERASE it (ESC[K from col 0)
    before the fixture ends. Just repositioning is not enough: the
    row a fixture parks on may already hold leftover content (an
    ED/EL variant that does not clear that particular row, or the
    background fill), and the shell's prompt -- which resumes
    wherever `cat` left the cursor with NO newline of its own --
    would then merge '$' into that leftover text instead of
    landing on a clean row, breaking the NEXT case's wait_prompt."""
    return _esc(f'\x1b[{row};1H') + _esc('\x1b[K')


def _fill_rows(n=24):
    """Absolute-addressed ROW01..ROWnn, one per physical row -- the
    background pattern check_vt102.py's ED/EL/CUx cases fill the
    screen with before probing (VT102 slice 1, docs/CONSOLE-
    VT102.md)."""
    out = b''
    for r in range(1, n + 1):
        out += _esc(f'\x1b[{r};1H') + _esc(f'ROW{r:02d}')
    return out


def _vt_csr_ind():
    """csr+ind: DECSTBM rows 5-10, cursor at the bottom margin (row
    10), one LF -- region [5,10] scrolls up 1, rows 1-4 and 11-14
    untouched. Margins reset before the shell prompt returns."""
    out = _esc('\x1b[2J')
    for r in range(1, 15):
        out += _esc(f'\x1b[{r};1H') + _esc(f'R{r:02d}')
    out += _esc('\x1b[5;10r')       # region rows 5-10 -- homes 1;1
    out += _esc('\x1b[10;1H')       # bottom margin row
    out += b'\x8a'                  # LF -- IND at the margin
    out += _esc('\x1b[r')           # whole screen again
    out += _park(20)                # park clear of the region
    return out


def _vt_csr_tail():
    """csr_tail: a SHORT row scrolls up over a LONG one inside a
    region -- the long row's tail must be blank afterwards. Rows
    5-8: row 5 'LONGLONGLONGLONG' (16 cols), row 6 'S', row 7
    'MIDMID', row 8 'T'; margins 5-8, cursor at row 8, LF. Expected
    rows 5-8: 'S', 'MIDMID', 'T', ''. The card's region move copies
    only up to the source's dirty bound and blanks the rest of the
    destination (tty8.s UT_MOV_ROW, perf slice 3); a stale tail here
    is exactly what a missing blank leaves."""
    out = _esc('\x1b[2J')
    for r, text in ((5, 'LONGLONGLONGLONG'), (6, 'S'), (7, 'MIDMID'),
                    (8, 'T')):
        out += _esc(f'\x1b[{r};1H') + _esc(text)
    out += _esc('\x1b[5;8r')        # region rows 5-8 -- homes 1;1
    out += _esc('\x1b[8;1H')        # bottom margin row
    out += b'\x8a'                  # LF -- IND at the margin
    out += _esc('\x1b[r')
    out += _park(20)
    return out


def _vt_awm():
    """awm: autowrap OFF (CSI ?7l), 80 'A' then 'XY', autowrap back
    ON. With autowrap off every character past the right edge
    overwrites the LAST column and the cursor stays: row 1 ends
    'A...AY' (the 80th A, then X, then Y all landed on the last
    cell), row 2 is empty -- on 40 AND 80 columns. Then LF and park
    below the assertion rows."""
    out = _esc('\x1b[2J') + _esc('\x1b[1;1H')   # home: ED never moves
    out += _esc('\x1b[?7l')                       # the cursor, and the
    out += _esc('A' * 80) + _esc('XY')            # row must sit ABOVE
                                                  # the park row
    out += _esc('\x1b[?7h')
    out += b'\x8a'
    out += _park(20)
    return out


def _vt_awm_acs():
    """awm_acs: the same autowrap-off overflow through the PER-BYTE
    renderer -- the run path (TTY_RUN) rejects the line-drawing set,
    so under SO every byte reaches TTY_PUT_PRNTB, whose own DECAWM
    check is otherwise invisible to `awm` (every byte there is a
    run). 80 'q' (a horizontal rule) then 'x' then 'j' with autowrap
    off: row 1 = (width-1) '-' and a '+' (x then j both landed on
    the last cell; the ASCII fallback maps q/x/j to - | +), row 2
    empty."""
    out = _esc('\x1b[2J') + _esc('\x1b[1;1H')
    out += _esc('\x1b[?7l') + _esc('\x1b(0') + b'\x8e'      # SO: G1
    out += _esc('q' * 80) + _esc('xj')
    out += b'\x8f' + _esc('\x1b(B') + _esc('\x1b[?7h')    # SI, ASCII
    out += b'\x8a'
    out += _park(20)
    return out


def _vt_smir_past():
    """smir_past: IRM with the cursor PAST the end of the row's text
    -- 'AB' on row 5, cursor to col 10 (1-based 11), CSI 4h, 'X'.
    Nothing left of the cursor may move: row 5 = 'AB' + 8 blanks +
    'X'. The card's insert shift starts at max(dirty bound, cursor)
    (tty9.s TT9_ICHSH, perf slice 4); a shift that starts at the
    bound alone drags 'B' right ('ABB')."""
    out = _esc('\x1b[2J')
    out += _esc('\x1b[5;1H') + _esc('AB')
    out += _esc('\x1b[5;11H') + _esc('\x1b[4h') + _esc('X')
    out += _esc('\x1b[4l')
    out += _park(20)
    return out


def _vt_ri():
    """ri at the top margin scrolls the region DOWN 1 -- row 5 goes
    blank, old R05..R09 shift to rows 6-10, R10 is lost off the
    region's bottom. Rows 1-4/11-14 untouched."""
    out = _esc('\x1b[2J')
    for r in range(1, 15):
        out += _esc(f'\x1b[{r};1H') + _esc(f'R{r:02d}')
    out += _esc('\x1b[5;10r')
    out += _esc('\x1b[5;1H')        # top margin row
    out += _esc('\x1bM')            # ESC M -- RI
    out += _esc('\x1b[r')
    out += _park(20)
    return out


def _vt_acs_all():
    """acs_all (docs/KGAPS.md): every byte of the DEC special-graphics
    range $60-$7E under SO, one write.  _vt_acs above draws six of the
    31 glyphs, so TT9_ACSMAP's table (tty9.s ACSTAB) was read at six
    indexes and 24 of its 31 bytes were never looked at.  The
    expectation is NOT read back out of that table: it is ncurses'
    own ASCII fallback for the VT100 ACS (curses.h ACS_* defaults),
    spelled out by hand in check_vt102.py's case_acs_all."""
    out = _esc('\x1b[2J') + _esc('\x1b[H')
    out += _esc('\x1b(B') + _esc('\x1b)0')
    out += b'\x8e' + _esc(''.join(chr(c) for c in range(0x60, 0x7F)))
    out += b'\x8f'
    out += _park(23)
    return out


def _vt_ri_mid():
    """ri_mid (docs/KGAPS.md): ESC M when the cursor is NOT at the top
    margin moves up one row and scrolls nothing (tty9.s TT9_RI's
    :notmargin arm); at the physical top above a region it stays.
    R01..R14, no margins, cursor on row 5, RI, 'X' -> row 4 reads X04;
    then margins 5-10, cursor row 2 (outside the region, above it),
    RI -> row 1, 'Y'; RI again at row 1 -> stays, 'Z' beside the Y."""
    out = _esc('\x1b[2J')
    for r in range(1, 15):
        out += _esc(f'\x1b[{r};1H') + _esc(f'R{r:02d}')
    out += _esc('\x1b[5;1H') + _esc('\x1bM') + _esc('X')
    out += _esc('\x1b[5;10r')
    out += _esc('\x1b[2;1H') + _esc('\x1bM') + _esc('Y')
    out += _esc('\x1bM') + _esc('Z')
    out += _esc('\x1b[r')
    out += _park(20)
    return out


def _vt_bg_shift():
    """bg_shift (docs/KGAPS.md): DCH and IRM written to a BACKGROUND
    console (cat'd to /dev/tty2 while console 1 holds the glass), so
    the row shift goes through the redirected-store path -- tty9.s
    TT9_ROWRD/TT9_ROWWR -> TT9_RRSTOR/TT9_RWSTOR, one BankCopy each way
    -- which every other VT102 case (all on the live glass) bypasses.
    Row 1: ABCDEF, cursor to column 3, DCH 2 -> ABEF.  Row 2: GHIJ,
    cursor to column 3, IRM on, 'xy', IRM off -> GHxyIJ."""
    out = _esc('\x1b[2J') + _esc('\x1b[1;1H') + _esc('ABCDEF')
    out += _esc('\x1b[1;3H') + _esc('\x1b[2P')
    out += _esc('\x1b[2;1H') + _esc('GHIJ')
    out += _esc('\x1b[2;3H') + _esc('\x1b[4h') + _esc('xy')
    out += _esc('\x1b[4l')
    out += _park(20)
    return out


def _vt_nel():
    """ESC E (NEL): column 0 + advance, whole screen (no margin set
    here) -- identical to maux's own LF deviation. Parked at the
    end: the shell's OWN prompt does not newline on its own -- it
    resumes wherever `cat` left the cursor (learning shape: the
    ILDL probes park too) -- so every probe that paints its last
    glyph must reposition afterward or the next `wait_prompt`
    never sees a clean '$'."""
    out = _esc('\x1b[2J')
    out += _esc('\x1b[3;10H')       # row 3, col 10
    out += _esc('\x1bE')            # ESC E -- NEL
    out += _esc('NELOK')
    out += _park(23)
    return out


def _vt_home():
    """A successful DECSTBM homes the cursor -- park elsewhere
    first, set a region, and the very next glyph must land at
    1;1."""
    out = _esc('\x1b[2J')
    out += _esc('\x1b[10;10H')      # prove it actually moves
    out += _esc('\x1b[5;10r')       # should home to 1;1
    out += _esc('HOMEOK')
    out += _esc('\x1b[r')
    out += _park(20)
    return out


def _vt_il_outside():
    """IL/DL outside the margins is a no-op (VT102 semantics) --
    region 5-10, cursor at row 2 (above it), IL 3 must change
    NOTHING."""
    out = _esc('\x1b[2J')
    for r in range(1, 15):
        out += _esc(f'\x1b[{r};1H') + _esc(f'R{r:02d}')
    out += _esc('\x1b[5;10r')
    out += _esc('\x1b[2;1H')
    out += _esc('\x1b[3L')          # IL 3 -- must be ignored
    out += _esc('\x1b[r')
    out += _park(20)
    return out


def _vt_ed(param, park_row):
    """ED case (param '' / '1' / '2'): 24-row background, row 10
    holds 'HEAD12345' (cols 0-8), cursor parked at col 5 (the '2'),
    then CSI <param> J, then a 4-char marker printed AT THE CURSOR
    -- landing where ED left it (ED never moves the cursor).
    park_row must be OUTSIDE whatever range check_vt102.py asserts
    for this variant (_park() erases the row itself, so it need
    not already be blank) -- parking INSIDE the asserted range
    would show the next shell prompt's own '$' as if ED had failed
    to clear it."""
    out = _esc('\x1b[2J') + _fill_rows()
    out += _esc('\x1b[10;1H') + _esc('HEAD12345')
    out += _esc('\x1b[10;6H')       # col 5 (0-based) -- the '2'
    out += _esc(f'\x1b[{param}J')
    out += _esc('EDOK')
    # -- cleanup, unconditional: 1J leaves rows 11-24 (the fill's
    # -- ROW11..ROW24) untouched, which would otherwise out-rank
    # -- the next case's shell prompt as the screen's LAST non-
    # -- blank row and wedge its wait_prompt. A second, plain 0J
    # -- from row 11 clears them regardless of which variant this
    # -- is -- it runs AFTER the assertion point (row 9/EDOK), so
    # -- it changes nothing check_vt102.py reads.
    out += _esc('\x1b[11;1H') + _esc('\x1b[0J')
    out += _park(park_row)
    return out


def _vt_el(param):
    """EL case (param '1' / '2'): one row '0123456789', cursor at
    col 5 (the '5'), CSI <param> K, then a 1-char marker at the
    cursor."""
    out = _esc('\x1b[2J')
    out += _esc('\x1b[5;1H') + _esc('0123456789')
    out += _esc('\x1b[5;6H')        # col 5 (0-based) -- the '5'
    out += _esc(f'\x1b[{param}K')
    out += _esc('Z')
    out += _park(23)
    return out


def _vt_cur():
    """CUU/CUD/CUF/CUB clamp at the margin when the cursor started
    inside/at it, else at the physical edge. Region rows 5-10;
    U/D/T/B/L/R markers land where each clamp should stop. CUF/CUB
    use HUGE counts from a near-start column rather than a
    hardcoded target column, so the same fixture is backend-width-
    agnostic (40 vs 80) -- check_vt102.py reads the actual row
    width off the returned screen and asserts against that."""
    out = _esc('\x1b[2J')
    out += _esc('\x1b[5;10r')
    out += _esc('\x1b[8;1H') + _esc('\x1b[10A') + _esc('U')   # ->row5
    out += _esc('\x1b[8;1H') + _esc('\x1b[10B') + _esc('D')   # ->row10
    out += _esc('\x1b[2;1H') + _esc('\x1b[10A') + _esc('T')   # ->row1
    out += _esc('\x1b[14;1H') + _esc('\x1b[10B') + _esc('B')  # ->row24
    out += _esc('\x1b[20;3H') + _esc('\x1b[200D') + _esc('L')  # col1
    out += _esc('\x1b[20;3H') + _esc('\x1b[200C') + _esc('R')  # last col
    out += _esc('\x1b[r')
    out += _park(22)
    return out


def _vt_acs():
    """smacs/rmacs with the DEC special graphics set as G1 (enacs =
    ESC ( B ESC ) 0): between ^N and ^O the letters q x j k l m draw
    lines and corners -- rendered as the ASCII fallback `-|++++`
    (V1: no MouseText yet); after ^O the same letters are letters."""
    out = _esc('\x1b[2J') + _esc('\x1b[H')
    out += _esc('\x1b(B') + _esc('\x1b)0')
    out += b'\x8e' + _esc('qxjklm') + b'\x8f' + _esc('qx')
    out += _park(23)
    return out


def _vt_enacs():
    """ESC ( B / ESC ) 0 (enacs, no line-drawing set in V1) paint
    NOTHING -- the designator byte is swallowed, not rendered.
    ESC[2J no longer homes the cursor (VT102 slice 1, ED never
    moves it) -- an explicit ESC[H is needed, or ENACSOK lands
    wherever the PREVIOUS command's cursor was left."""
    out = _esc('\x1b[2J') + _esc('\x1b[H')
    out += _esc('\x1b(B') + _esc('\x1b)0')
    out += _esc('ENACSOK')
    out += _park(23)
    return out


def _vt_kpam():
    """ESC = / ESC > (DECKPAM/DECKPNM) paint nothing either."""
    out = _esc('\x1b[2J') + _esc('\x1b[H')
    out += _esc('\x1b=') + _esc('\x1b>')
    out += _esc('KPOK')
    out += _park(23)
    return out


def _vt_cr():
    """opost ON: 'COOKA'+CR+'COOKB'+CR -- CR is a full newline, two
    adjacent rows (cat under the cooked default)."""
    return _hilines('COOKA', 'COOKB')


def _vt_cr_raw():
    """opost OFF: 'RAWA'+CR+'RAWBBBBBBBBBB'+CR+LF -- CR only returns
    the column, so the second write overwrites the first IN PLACE.
    'RAWA' must never appear; 'RAWBBBBBBBBBB' must. The trailing LF
    (2026-09-12) puts the shell's next prompt on a FRESH row: under
    -opost the prompt's own CR is a column return too, so without
    it "$ " overpainted "RA" at column 0 and check_vt102.py's wait
    for the marker raced the reprompt -- seen red on the box
    ("$ WBBBBBBBBBBCRRAW"), green on the Mac, a slice-phase race."""
    return (bytes(c | 0x80 for c in b'RAWA') + b'\x8d' +
           bytes(c | 0x80 for c in b'RAWBBBBBBBBBB') + b'\x8d\x8a')


def _vt_lf_raw():
    """LF is IND in every mode: down one row, SAME column.
    'LFA'+LF+'LFB'+LF -- LFB lands at column 3 of the next row."""
    return (bytes(c | 0x80 for c in b'LFA') + b'\x8a' +
           bytes(c | 0x80 for c in b'LFB') + b'\x8a')


def _vt_clear():
    """Explicit full-screen clear + a CR-terminated marker. cur's B
    marker sits at the PHYSICAL BOTTOM row by design (it is CUD's
    clamp target) -- nothing can park BELOW it for the next case's
    wait_prompt, so check_vt102.py cats this afterward instead of
    trying to park at all."""
    return _esc('\x1b[2J') + _hilines('CLROK')


def _vt_postok():
    """A plain CR-terminated marker, cat'd AFTER opost is restored
    (check_vt102.py's case_opost) to force a clean, predictable
    newline before the next case's wait_prompt -- see the park
    note on _vt_nel above; this is the same fix applied at the
    LINE-DISCIPLINE level instead of a cursor park, since raw mode
    left the exact cursor column unpredictable."""
    return _hilines('POSTOK')


def _vt_ckm():
    """DECCKM on -- CSI ?1h -- for check_vt102.py's smkx case (SSC/
    tip session, read back over the wire)."""
    return _esc('\x1b[?1h')


def _vt_xenl():
    """xenl measurement fixture (docs/CONSOLE-VT102.md sec 2):
    clear, home, write 'XE' + 90 dots -- enough to overflow EITHER
    a 40- or an 80-column console (the play image's own boot
    default turns out to be native-80 even under e2e_term.py's
    'text40' label -- there is no 40-column force knob in that
    harness, check_play.py's PT_F40 patch is a DIFFERENT one).
    check_vt102.py counts row 0's own length to measure the actual
    width AND the wrap point self-describingly, rather than assume
    one. ESC[2J no longer homes (VT102 slice 1) -- ESC[H makes it
    explicit."""
    out = _esc('\x1b[2J') + _esc('\x1b[H')
    out += _esc('XE' + '.' * 90)
    out += _park(23)                # rows 3-22 were never touched
                                    # (92 chars spans at most 3
                                    # rows even at 40 cols)
    return out


#: A 20-character letter run, cols 0-19 -- fits inside EITHER a
#: 40- or an 80-column row, so one fixture serves all three
#: backends (task #23 deliverable A's gate: "All three backends").
_DCH_ROW = 'ABCDEFGHIJKLMNOPQRST'


def _vt_dch1():
    """dch1 (VT102 slice 2, docs/CONSOLE-VT102.md sec 2/4): paint a
    20-letter row, position at col 3 (0-based), ESC[P (default n=1)
    shifts the tail left one -- col 3's 'D' is deleted, everything
    right of it moves in, the true last column is blanked. A
    trailing 'X' verifies the cursor did NOT move: it overwrites
    whatever DCH shifted INTO col 3 (must be 'E', the old col 4),
    which only holds if DCH left the cursor exactly where it found
    it. Expect row1[:21] == 'ABCXFGHIJKLMNOPQRST'[:20]+pad --
    check_vt102.py has the exact string."""
    out = _esc('\x1b[2J') + _esc('\x1b[2;1H')
    out += _esc(_DCH_ROW)
    out += _esc('\x1b[2;4H')          # 1-based col4 = 0-based col3
    out += _esc('\x1b[P')             # DCH, n defaults to 1
    out += _esc('X')
    out += _park(23)
    return out


def _vt_dch_clamp():
    """dch n clamps at the margin: position at the LAST column via
    an out-of-range CUP (clamped by TTY_CSI_HOME -- width-agnostic,
    works on 40 or 80 cols alike), back up 3 columns (CUB), paint
    'ABCD' so it exactly fills the row's last 4 cells, return to the
    first of those 4, then ESC[50P -- n=50 is far more than the 4
    columns actually remaining, so it must clamp to 4 rather than
    read or write past the row. A trailing 'Z' at the same spot
    (cursor unmoved) proves the whole 4-cell tail was blanked, not
    just clamped-and-ignored."""
    out = _esc('\x1b[2J') + _esc('\x1b[1;999H')   # clamps to last col
    out += _esc('\x1b[3D')                        # back 3
    out += _esc('ABCD')                           # fills the last 4
    out += _esc('\x1b[1;999H') + _esc('\x1b[3D')  # back to 'A'
    out += _esc('\x1b[50P')                       # clamps to 4
    out += _esc('Z')
    out += _park(23)
    return out


def _vt_dch0():
    """dch1 at column 0 -- the whole row shifts left, nothing to
    the left of the cursor to leave alone (there is nothing left of
    column 0)."""
    out = _esc('\x1b[2J') + _esc('\x1b[2;1H')
    out += _esc(_DCH_ROW)
    out += _esc('\x1b[2;1H')          # back to col 0
    out += _esc('\x1b[P')
    out += _esc('Z')
    out += _park(23)
    return out


def _vt_dch_last():
    """dch1 at the LAST column (CUP-clamped, width-agnostic, row 0
    -- the row-1 letter run above is unrelated ballast, untouched):
    only one cell is at or right of the cursor, so the shift
    degenerates to "blank the one cell" -- must not read or write
    past the row end. 'L' then 'M' at the same clamped position
    prove the cell is blanked and the cursor stays put."""
    out = _esc('\x1b[2J') + _esc('\x1b[2;1H')
    out += _esc(_DCH_ROW)
    out += _esc('\x1b[1;999H')
    out += _esc('L')
    out += _esc('\x1b[1;999H')
    out += _esc('\x1b[P')
    out += _esc('M')
    out += _park(23)
    return out


def _vt_irm():
    """smir/rmir (VT102 slice 2): paint a 20-letter row, position
    at col 3, CSI 4h (smir), write 'Z' -- IRM pushes the tail right
    ONE cell before storing, so 'Z' lands at col 3 and the old col-3
    letter ('D') is now at col 4. CSI 4l (rmir), write 'Y' at the
    (advanced) cursor -- an ORDINARY overwrite, no more pushing, so
    'Y' replaces 'D' rather than shoving the rest of the row along
    again. Expect cols 0-20 == 'ABCZYEFGHIJKLMNOPQRST'."""
    out = _esc('\x1b[2J') + _esc('\x1b[2;1H')
    out += _esc(_DCH_ROW)
    out += _esc('\x1b[2;4H')
    out += _esc('\x1b[4h') + _esc('Z')
    out += _esc('\x1b[4l') + _esc('Y')
    out += _park(23)
    return out


def _vt_irm0():
    """smir at column 0: the push has nowhere to come from on the
    left, only somewhere to go on the right -- the whole row shifts
    right by one, dropping whatever was at the true last column
    (background, untouched by this probe)."""
    out = _esc('\x1b[2J') + _esc('\x1b[2;1H')
    out += _esc(_DCH_ROW)
    out += _esc('\x1b[2;1H')
    out += _esc('\x1b[4h') + _esc('Z')
    out += _esc('\x1b[4l') + _esc('Y')
    out += _park(23)
    return out


def _vt_irm_last():
    """smir at the LAST column (CUP-clamped): nothing to push INTO
    (the cursor already IS the last cell), so the insert degenerates
    to an ordinary store -- must not read or write past the row.
    'Z' then, after rmir, 'Y' at the same clamped spot -- Y must
    win, whichever way the pending xenl wrap the first store leaves
    behind gets resolved (ESC clears it without wrapping)."""
    out = _esc('\x1b[2J') + _esc('\x1b[1;999H')
    out += _esc('\x1b[4h') + _esc('Z')
    out += _esc('\x1b[1;999H') + _esc('\x1b[4l') + _esc('Y')
    out += _park(23)
    return out


def _vt_xenl2():
    """xenl ASSERTION fixture (VT102 slice 3, docs/CONSOLE-VT102.md
    sec 2/4, task #23 deliverable B): clear, home, 80 dots -- a
    multiple of BOTH known console widths (40 and 80), so the last
    dot always lands exactly on a width boundary -- then CR, then a
    marker 'M'.

    With xenl (deferred wrap) the 80th dot sets the pending flag
    and leaves the cursor on the LAST row the dots actually filled;
    CR's own newline (cooked/OPOST) is the ONLY one that fires, so M
    lands on row (80/width). Without xenl (immediate wrap) the 80th
    dot already wrapped DURING the burst, so CR's newline is a
    SECOND one and M lands one row further down. check_vt102.py's
    case_xenl measures width separately (from VTXENL, which is
    model-independent -- see its own note) and asserts M's row."""
    out = _esc('\x1b[2J') + _esc('\x1b[H')
    out += _esc('.' * 80)
    out += _esc('\r')
    out += _esc('M')
    out += _park(23)
    return out


def _vt_bs():
    """bs/del are cursor motions, not erasers (VT102 slice 6, review finding
    VT2): 'ABC' BS BS DEL 'x' -> 'AxC' (BS moves left without
    blanking, DEL is ignored); a BS at column 0 stays put, so the
    'Z' after it lands on ITS row, not on the row above's last
    column. Row 0's 'TOP' must survive untouched."""
    out = _esc('\x1b[2J') + _esc('\x1b[H') + _esc('TOP')
    out += _esc('\x1b[2;1H') + _esc('ABC\x08\x08\x7fx')
    out += _esc('\x1b[3;1H') + _esc('\x08Z')
    out += _park(23)
    return out


def _vt_ht():
    """ht is a cursor motion to the next 8-column stop that paints
    nothing and clamps at the last column (review finding VT3): over
    'ABCDEFGHIJK' from col 2 it lands on col 8, so 'X' overwrites
    I and B..H survive. From the last column it stays there: 'Y'
    lands on row 1's last column and row 2 stays empty."""
    out = _esc('\x1b[2J') + _esc('\x1b[H') + _esc('ABCDEFGHIJK')
    out += _esc('\x1b[1;3H') + _esc('\tX')
    out += _esc('\x1b[2;999H') + _esc('\tY')
    out += _park(23)
    return out


def _vt_wrap():
    """a pending wrap survives SGR, BEL, NUL and SO/SI, and DECRC
    restores it (review finding VT4/VT7, wraptest's DEC columns): each
    80-char burst (a multiple of both widths) ends on a width
    boundary with the wrap pending; the control after it must
    leave it pending, so the marker lands at column 0 of the NEXT
    row, never over the burst's last cell. Segment 5 saves the
    pending state with ESC 7, cancels it with CUP, and ESC 8 must
    bring it back. Fill rows start 4 apart (rows 1,5,9,13,17)."""
    out = _esc('\x1b[2J')
    for i, (fill, ctl, mark) in enumerate(_WRAP_SEGS):
        out += _esc(f'\x1b[{4 * i + 1};1H') + _esc(fill * 80)
        out += _esc(ctl) + _esc(mark)
    out += _park(23)
    return out


_WRAP_SEGS = (('A', '\x1b[7m\x1b[0m', 'X'), ('B', '\x07', 'Y'),
              ('C', '\x00', 'Z'), ('D', '\x0e\x0f', 'W'),
              ('E', '\x1b7\x1b[1;1H\x1b8', 'V'))


def _vt_sgr():
    """multi-parameter SGR, and DECSC/DECRC of the rendition and
    the character set (review finding VT5/VT7). check_vt102.py's case_sgr
    (text40) peeks the text page: inverse lowercase is $60-$7F,
    normal lowercase $E0-$FF. Row 0: x (CSI 0;1;7m -> inverse),
    y (CSI 0;1;4;7;5m -- the stock vt102 sgr's five-parameter
    standout -> inverse), z (CSI m -> normal), w (CSI 7m ESC 7
    CSI m ESC 8 -> inverse again), '-' (ESC ( 0 ESC 7 ESC ( B
    ESC 8 q -> the graphics set restored draws q as a dash)."""
    out = _esc('\x1b[2J') + _esc('\x1b[H')
    out += _esc('\x1b[0;1;7mx\x1b[0;1;4;7;5my\x1b[mz')
    out += _esc('\x1b[7m\x1b7\x1b[m\x1b8w\x1b[m')
    out += _esc('\x1b(0\x1b7\x1b(B\x1b8q\x1b(B')
    out += _park(23)
    return out


def _vt_ctl():
    """controls inside a sequence (review finding VT8, DEC VT102 UG 5.5.1):
    NUL is ignored, a fresh ESC restarts, CAN aborts, BEL executes
    and the sequence keeps its parameters. X lands at row 2 col 3
    (1-based), Y at (3,4), Z right after Y (its own sequence was
    cancelled), W at (5,6)."""
    out = _esc('\x1b[2J') + _esc('\x1b[H')
    out += _esc('\x1b[2;\x003HX')
    out += _esc('\x1b[2;\x1b[3;4HY')
    out += _esc('\x1b[4;5\x18Z')
    out += _esc('\x1b[5;\x076HW')
    out += _park(23)
    return out


def _vt_bel():
    """check-vt102's bell case: a page of mixed codes -- upper,
    lower, digits, punctuation, an SGR 7 inverse run -- then ONE BEL,
    then park. The page must invert whole at a tick and come back
    byte-identical."""
    out = _esc('\x1b[2J') + _esc('\x1b[H')
    out += _esc('ABC xyz 0123 !?@[]{}~ Hello, World\r\n')
    out += _esc('\x1b[7mINVERSE\x1b[m plain lower case\r\n')
    out += _esc('the quick brown fox jumps over 13 lazy dogs\r\n')
    out += b'\x07'
    out += _park(23)
    return out


def _vt_rib():
    """ri under a top-zero, bottom-short region (review finding VT9): rows
    R01..R24, DECSTBM 1;23, RI at row 1 -- the region scrolls
    down, R23 falls off ITS bottom, and R24 on the physical bottom
    row is untouched (the card's display-start shortcut is only
    legal for a WHOLE-screen region). Parks on row 1 (blank after
    the RI) so the prompt lands on row 0 -- the surviving R24 IS
    the last row, so check_vt102.py's case_ri_bottom settles on
    the prompt there and cats VTCLEAR afterwards (case_cur's
    idiom)."""
    out = _esc('\x1b[2J')
    for r in range(1, 25):
        out += _esc(f'\x1b[{r};1H') + _esc(f'R{r:02d}')
    out += _esc('\x1b[1;23r') + _esc('\x1b[1;1H') + _esc('\x1bM')
    out += _esc('\x1b[r') + _park(1)
    return out


def _vt_jsraw():
    """jump scroll under raw output (review finding VT1), ONE write: clear,
    23 CR LF lines (R00..R22) put the cursor on the bottom row,
    then LF X CR 'JSY' LF. The look-ahead must count only the LFs
    (a raw CR is a column return): scroll 2, X and JSY share the
    row parked two above the bottom, the last LF steps down for
    the prompt -- R22 on row 20, row 21 blank, JSY on row 22. The
    old count (CR as a newline) scrolled 3 and left JSY on 21."""
    out = _esc('\x1b[2J') + _esc('\x1b[H')
    for r in range(23):
        out += _esc(f'R{r:02d}') + b'\x8d\x8a'
    out += b'\x8a' + _esc('X') + b'\x8d' + _esc('JSY') + b'\x8a'
    return out


def _vt_rsz1():
    """DECRC after a geometry change (review finding VT6): save the cursor at
    the last column of the 40-column console, switch to 80
    columns (clears and homes), restore, print 'XY'. The saved
    cursor is VOID after the switch, so XY lands at home -- not at
    column 39 of the new geometry (and, going 80 -> 40, not at a
    column 79 the 40-column renderer indexes off its row)."""
    return (_esc('\x1b[2J') + _esc('\x1b[1;999H') + _esc('\x1b7') +
            _esc('\x1b[80;24v') + _esc('\x1b8') + _esc('XY') +
            _park(23))


def _vt_rsz2():
    """back to 40 columns after _vt_rsz1 (the switch clears)."""
    return _esc('\x1b[40;24v') + _park(23)


SAMPLES = [
    # sixty numbered lines -- check-play's MORE phase pages this
    # (L01..L22 on page one, `q` before L60 ever prints)
    ('LONG', 0x04, _hilines(*[f'L{i:02d}' for i in range(1, 61)])),
    # unsorted, with a duplicate -- `SORT FRUIT`, `SORT -u FRUIT`
    ('FRUIT', 0x04, _hilines('PEAR', 'APPLE', 'MANGO', 'APPLE', 'FIG',
                             'CHERRY', 'BANANA', 'FIG')),
    # adjacent runs, and a NON-adjacent repeat at the end so
    # `UNIQ RUNS` visibly differs from `SORT -u RUNS`
    ('RUNS', 0x04, _hilines('AAA', 'AAA', 'BBB', 'CCC', 'CCC', 'CCC',
                            'AAA')),
    # for TR: `TR a-z A-Z < GREET`
    ('GREET', 0x04, _hilines('hello world', 'the quick brown fox')),
    # a byte ladder for `OD BYTES`
    ('BYTES', 0x06, bytes(range(0x00, 0x24))),
    # check-play's trap phase runs `SH < DEMO/TRAP` in a nested sh:
    # arm SIGINT + the EXIT trap, self-kill (the pump runs TRAPHIT),
    # then EXIT (the 0-trap runs TRAPBYE). Output goes to the screen.
    ('TRAP', 0x04, _hilines("TRAP 'ECHO TRAPHIT' 2",
                            "KILL -2 $$",
                            "TRAP 'ECHO TRAPBYE' 0",
                            "EXIT")),
    # check-play's `ex` phase (docs/EX-DESIGN.md): a 3-line fixture for
    # the interactive keyboard round trip (r / ,p / 1a append / 3s
    # substitute / w / q). The session's own write target (EXOUT) is
    # created at runtime by the gate, not staged here.
    ('EXFIX', 0x04, _hilines('LINE ONE', 'LINE OLD TWO', 'LINE THREE')),
    # check-vi-alt's unknown-private-mode probe (docs/VI-ALTSCREEN.md):
    # two DEC/xterm private modes maux does not implement (?25l hide
    # cursor, ?9999h nonsense) ahead of a marker word. `cat DEMO/ALTPRIV`
    # must show PRIVOK alone -- the sequences are swallowed, never
    # rendered as "25l"/"9999h" text. Raw bytes: the cooked line editor
    # eats a typed ESC, so the probe cannot be typed at the prompt.
    ('ALTPRIV', 0x04, bytes(c | 0x80 for c in b'\x1b[?25l\x1b[?9999h')
     + _hilines('PRIVOK')),
    # check-play's vi MOTION phase (docs/VI-DESIGN.md sec 4.1): line 1
    # mixes a punctuation run with word runs so w/b/e/0/$/count/f all
    # have unambiguous, hand-computed targets; lines 2-5 exist only so
    # `G` has somewhere real to land.
    ('VIMOTFIX', 0x04, _hilines('FOO.BAR BAZ QUX', 'SECOND LINE HERE',
                                'THIRD LINE HERE TOO', 'FOURTH LINE',
                                'FIFTH LAST LINE')),
    # check-play's vi insert-variant/search phase (docs/VI-DESIGN.md
    # sec 4.1): line 2's leading spaces are for `I` (first non-blank);
    # "APPLE" on lines 1/3/5 gives `/`/`?`/`n`/`N` three occurrences
    # to walk (one match forward, one WRAPPED, one backward on the
    # SAME line) without ever needing to scroll a 5-line file.
    ('VIFIX', 0x04, _hilines('ALPHA APPLE',
                             '  BETA INDENT',
                             'GAMMA APPLE ITEM',
                             'DELTA',
                             'EPSILON APPLE')),
    # check-vi's vicache aligned-fixture phase (learning:01M14B7RFG1024
    # FPA330Z9ZNM2 -- windowed/buffered code needs an EXACT-size fixture,
    # not just irregular ones): lines of exactly 0, 80 (=VI_COLS on this
    # rig), 81, and 254 (the swap descriptor's 1-byte-len max,
    # docs/EX-DESIGN.md sec 2.2/5.2) bytes, each ending in a distinctive
    # digit. Staged as a FILE, not typed via `i` -- vi's own INSERT
    # accumulator VI_LBUFLEN (vi.s) is 250 bytes, 4 short of the 254 a
    # loaded line can carry, so typing a 254-char line silently truncates
    # it before it ever reaches the buffer (found empirically 2026-09-05
    # while building this fixture). Loading from a file goes through
    # ED_LOAD's real up-to-254 path instead.
    ('VILEN', 0x04, _hilines('',
                             'A' * 79 + '1',
                             'B' * 80 + '2',
                             'C' * 253 + '3')),
    # check-ildl (docs/CONSOLE.md sec 4): the terminal's IL/DL region
    # scroll -- ESC[nL opens n blank lines at the cursor row (pushing
    # [row, bottom] down), ESC[nM deletes n (pulling up, blanking the
    # bottom). The card can't use its CRTC display-start bump for a
    # mid-screen region (that moves the whole window), so this is its
    # only test of the VRAM row-move path (tty8.s UT_SRGN_UP/DN); the
    # 40/N8/store backends region their row-copy loops. Raw bytes: a
    # typed ESC is eaten by the cooked line editor, so the probe is a
    # cat'd file, like ALTPRIV above.
    ('ILDLDEL', 0x04, _ildl_probe('\x1b[3M')),   # DL 3 at row 5
    ('ILDLINS', 0x04, _ildl_probe('\x1b[3L')),   # IL 3 at row 5
    # check-vt102 (docs/CONSOLE-VT102.md, task #23 slice 1): raw-
    # escape probes for DECSTBM/IND/RI/NEL/ED/EL/DECCKM/enacs/
    # DECKPAM/opost, one file per terminfo capability. Same reason
    # as the ILDL probes above: a typed ESC never reaches the
    # parser through the cooked line editor.
    ('VTCSR', 0x04, _vt_csr_ind()),
    ('VTCSRT', 0x04, _vt_csr_tail()),
    ('VTAWM', 0x04, _vt_awm()),
    ('VTSMIRP', 0x04, _vt_smir_past()),
    ('VTAWMA', 0x04, _vt_awm_acs()),
    ('VTRI', 0x04, _vt_ri()),
    ('VTNEL', 0x04, _vt_nel()),
    ('VTHOME', 0x04, _vt_home()),
    ('VTILOUT', 0x04, _vt_il_outside()),
    # park_row 20 for all three: outside every ED variant's OWN
    # asserted range (check_vt102.py only checks rows 0-9) --
    # _park() erases whatever row it targets itself, so the row
    # need not be one ED already cleared.
    ('VTED0', 0x04, _vt_ed('', 20)),
    ('VTED1', 0x04, _vt_ed('1', 20)),
    ('VTED2', 0x04, _vt_ed('2', 20)),
    ('VTEL1', 0x04, _vt_el('1')),
    ('VTEL2', 0x04, _vt_el('2')),
    ('VTCUR', 0x04, _vt_cur()),
    ('VTENACS', 0x04, _vt_enacs()),
    ('VTACS', 0x04, _vt_acs()),
    ('VTKPAM', 0x04, _vt_kpam()),
    ('VTCR', 0x04, _vt_cr()),
    ('VTCRRAW', 0x04, _vt_cr_raw()),
    ('VTLFRAW', 0x04, _vt_lf_raw()),
    ('VTCKM', 0x04, _vt_ckm()),
    ('VTXENL', 0x04, _vt_xenl()),
    ('VTPOSTOK', 0x04, _vt_postok()),
    ('VTCLEAR', 0x04, _vt_clear()),
    # check-vt102 (VT102 slice 2/3, task #23 deliverables A/B):
    # DCH/IRM row-shift probes + the xenl assertion, all width-
    # agnostic (CUP-clamped positioning where "the last column"
    # matters) so one fixture serves all three backends.
    ('VTDCH1', 0x04, _vt_dch1()),
    ('VTDCHCLP', 0x04, _vt_dch_clamp()),
    ('VTDCH0', 0x04, _vt_dch0()),
    ('VTDCHLST', 0x04, _vt_dch_last()),
    ('VTIRM', 0x04, _vt_irm()),
    ('VTIRM0', 0x04, _vt_irm0()),
    ('VTIRMLST', 0x04, _vt_irm_last()),
    ('VTXENL2', 0x04, _vt_xenl2()),
    # check-vt102 (VT102 slice 6, the review VT1-VT9 findings,
    # 2026-09-12): BS/DEL as motions, HT as a clamped non-painting
    # motion, the pending wrap across SGR/BEL/NUL/SO-SI + DECRC,
    # multi-parameter SGR + DECSC of rendition/charset, controls
    # inside sequences, RI under a bottom-short region (UT), raw
    # jump scroll, DECRC after a geometry change.
    ('VTBS', 0x04, _vt_bs()),
    ('VTHT', 0x04, _vt_ht()),
    ('VTWRAP', 0x04, _vt_wrap()),
    ('VTSGR', 0x04, _vt_sgr()),
    ('VTCTL', 0x04, _vt_ctl()),
    ('VTBEL', 0x04, _vt_bel()),
    ('VTRIB', 0x04, _vt_rib()),
    ('VTACSALL', 0x04, _vt_acs_all()),
    ('VTRIMID', 0x04, _vt_ri_mid()),
    ('VTBGSH', 0x04, _vt_bg_shift()),
    ('VTJSRAW', 0x04, _vt_jsraw()),
    ('VTRSZ1', 0x04, _vt_rsz1()),
    ('VTRSZ2', 0x04, _vt_rsz2()),
    # check-vi-bang's killed_midcsi case (ccae082): a `cat`-in-the-
    # background fixture that is mostly escape bytes, so a kill mid-
    # drain lands mid-CSI with very high probability -- see
    # _escs_probe()'s own docstring.
    ('ESCS', 0x04, _escs_probe()),
]


MAN_DIR = os.path.join(ROOT, 'build', 'man')


BOLD_ON = bytes([0x9B, 0xDB, 0xB1, 0xED])    # ESC [ 1 m, high-bit
INV_ON = bytes([0x9B, 0xDB, 0xB7, 0xED])     # ESC [ 7 m, high-bit
BOLD_OFF = bytes([0x9B, 0xDB, 0xB0, 0xED])   # ESC [ 0 m


def man_to_maux(raw):
    """mandoc ASCII output (LF lines, bold as X\\bX and underline
    as _\\bX overstrikes) -> maux text: high-bit,
    CR line ends, emphasised runs wrapped in ESC[1m / ESC[7m ... ESC[0m
    and closed at every line end, underline dropped to plain.

    WHICH of the two a run gets is decided here, by its column, and it
    is what the //e reader sees. A run that starts the line is a
    section heading (nroff bolds NAME, SYNOPSIS... from column 0): it
    gets ESC[7m, inverse, which every console can show. A run inside a
    sentence gets ESC[1m, bold, which asks only for BRIGHTNESS -- the
    UltraTerm has it, the //e text page does not and the kernel drops
    it there (TTY_SGR_CLASS, src/kernel/tty2.s). Both were ESC[1m
    until 2026-11-01, so a //e paged the manual with every emphasised
    word as an inverse block mid-line, a ragged column of them down
    the SYNOPSIS; headings standing out and paragraphs clean is the
    same page with the emphasis the display can actually carry. On an
    UltraTerm nothing changes: more arms highlight on the first run of
    either kind (moreshow.s EMITCH) and both read as bright."""
    out = bytearray()
    lines = raw.split(b'\n')
    if lines and lines[-1] == b'':
        lines.pop()
    for line in lines:
        cells = []
        i, n = 0, len(line)
        while i < n:
            chain = [line[i]]
            j = i
            while j + 2 < n and line[j + 1] == 0x08:
                chain.append(line[j + 2])
                j += 2
            marks = [c for c in chain if c != 0x5F]
            final = marks[-1] if marks else chain[-1]
            bold = len(marks) >= 2 and len(set(marks)) == 1
            cells.append((final, bold))
            i = j + 1
        on = False
        for idx, (ch, bold) in enumerate(cells):
            if bold and not on:
                out += INV_ON if idx == 0 else BOLD_ON
                on = True
            elif not bold and on:
                out += BOLD_OFF
                on = False
            if ch in (0x0D, 0x08) or ch >= 0x80:
                continue
            out.append(ch | 0x80)
        if on:
            out += BOLD_OFF
        out.append(0x8D)
    return bytes(out)


def stage_man_pages(prodos, root):
    """Stage the current source roster, never orphaned build/man renders."""
    names = []
    prodos.mkdir(f'{root}/USR/MAN')
    for source in sorted(os.listdir(os.path.join(ROOT, 'docs', 'man'))):
        if not source.endswith('.1'):
            continue
        fn = source[:-2] + '.TXT'
        name = fn[:-4].upper()
        with open(os.path.join(MAN_DIR, fn), 'rb') as f:
            raw = f.read()
        prodos.write(f'{root}/USR/MAN/{name}', man_to_maux(raw),
                     file_type=0x04,
                     aux_type=0x0000, overwrite=True)
        names.append(name)
    return names


def main():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXPLAY.SYSTEM'),
    ] + [(path, f'{name} userland binary') for name, path in UTIL_BINS]:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2

    # -- play-image is PHONY (see the Makefile) and 13 sweep gates reach
    # -- it TRANSITIVELY, outside the parallel sweep's play.po lane -- so
    # -- two lanes used to run this builder on one path at once and the
    # -- loser faulted on its mmap (`play-image Bus error`). Build into a
    # -- temp file under an exclusive lock, publish by rename: readers
    # -- see only whole images. scripts/imglock.py carries the full note.
    with imglock.publish(OUT_IMG) as staged:
        return build(staged)


def build(staged):
    """Build the whole image at `staged`; the caller renames it onto
    OUT_IMG. Nothing below may touch OUT_IMG itself."""
    prodos.create(staged, name=CARRIER_VOL, blocks=VOL_BLOCKS)
    with open(CARRIER_IMG, 'rb') as f:
        boot = f.read(BOOT_BYTES)
    if len(boot) != BOOT_BYTES or boot == bytes(BOOT_BYTES):
        print(f'error: {CARRIER_IMG} has no boot block to copy',
              file=sys.stderr)
        return 2
    with open(staged, 'r+b') as f:
        f.write(boot)

    prodos.mount(staged)
    root = f'/mnt/{CARRIER_VOL}'
    removed = []
    kept = []

    def rm_recursive(path, entry):
        if entry.is_dir():
            for child in list(prodos.scandir(path)):
                rm_recursive(f'{path}/{child.name}', child)
            prodos.rmdir(path)
        else:
            prodos.remove(path)

    for entry in list(prodos.scandir(root)):
        if entry.name.upper() == 'PRODOS':
            kept.append(entry.name)
            continue
        rm_recursive(f'{root}/{entry.name}', entry)
        removed.append(entry.name)

    with open(KERNEL_BIN, 'rb') as f:
        kernel = f.read()
    with open(SYS_BIN, 'rb') as f:
        system = f.read()
    with open(BYERES_BIN, 'rb') as f:
        byeres = f.read()
    with open(KSEG_BIN, 'rb') as f:
        kseg = f.read()
    with open(LSEG_BIN, 'rb') as f:
        lseg = f.read()
    with open(BYETENANT_BIN, 'rb') as f:
        byetenant = f.read()
    with open(BYETENANTD_BIN, 'rb') as f:
        byetenantd = f.read()

    util_data = []
    for name, path in UTIL_BINS:
        with open(path, 'rb') as f:
            util_data.append((name, f.read()))

    # -- Sample data lives in a SUBDIRECTORY, not the root. check-play
    # -- types LS and asserts against the resulting screen, so every
    # -- file added to the root pushes that listing further past 24
    # -- rows and breaks the gate's layout assumptions. Keeping demo
    # -- data one level down means the playground can grow without
    # -- the console gate caring. (Learned the hard way 2026-08-21.)
    prodos.mkdir(f'{root}/DEMO')
    for name, ftype, data in SAMPLES:
        prodos.write(f'{root}/DEMO/{name}', data, file_type=ftype,
                     aux_type=0x0000, overwrite=True)

    # -- NO /etc/RC is shipped, deliberately (the splash is /etc/issue,
    # -- printed by init itself for exactly that reason). pid 1 runs one if
    # -- it finds it (src/test/playtestb.s INIT_RC) and that hook is
    # -- the feature; a SAMPLE rc is not. Shipping one costs every boot
    # -- of this image a whole `sh` spawn before the prompt appears,
    # -- and four gates with fixed boot budgets timed out when it was
    # -- tried (2026-09-20). check-init makes its own writable copy and
    # -- writes an rc into that, which also proves the case a user
    # -- actually lives in: adding one to a disk that had none.
    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    # -- the `bye` resident, at the FIXED absolute path
    # -- procbye.s's PBY_LOAD_RES opens by literal (high-bit
    # -- ASCII) pathname -- see BYERES_BIN's own comment above.
    # -- Plain BIN type: it is never EXECed, only OPENed/READ by
    # -- the kernel's own raw MLI calls, and its 3-byte aux_type
    # -- would otherwise be read as a load address that nothing
    # -- honors here.
    prodos.write(f'{root}/BYERES', byeres, file_type=0x06,
                 aux_type=0x0000, overwrite=True)
    # -- the kernel cold segment, staged beside MAUX.SYSTEM at the
    # -- boot volume's OWN root (K_BOOTPFX + "KSEG", procfile5.s) --
    # -- type $06 (plain BIN, never EXECed), aux_type $D400 (its
    # -- real load address, matching PRODOS/MAUX.SYSTEM's own
    # -- aux_type-as-load-address convention above).
    prodos.write(f'{root}/KSEG', kseg, file_type=0x06,
                 aux_type=0xD400, overwrite=True)
    prodos.write(f'{root}/LSEG', lseg, file_type=0x06,
                 aux_type=0x1300, overwrite=True)
    # -- the `bye PATH.SYSTEM` launch's own worked example and
    # -- gate fixture (docs/BYE.md "Slice 2 launch",
    # -- src/test/byetenant.s): a real ProDOS 8 .SYSTEM, staged
    # -- at a FIXED path so `bye /mnt/MAUX/TENANT.SYSTEM` can name
    # -- it. DEVIATION from the spec's own literal
    # -- "/mnt/MAUX/BYETENANT.SYSTEM": ProDOS names are capped at 15
    # -- characters (TRM) and "BYETENANT.SYSTEM" is 16 -- measured
    # -- directly, a2til's own write_file() refuses it
    # -- ("Invalid ProDOS name"). aux_type = its own load address,
    # -- same convention as PRODOS/MAUX.SYSTEM above.
    prodos.write(f'{root}/TENANT.SYSTEM', byetenant, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    # -- docs/LOOP-S2.md S4: the tenant that deletes the loop image.
    prodos.write(f'{root}/DELTEN.SYSTEM', byetenantd, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    # -- Userland binaries live in /bin, NOT the volume root. The
    # -- default PATH is "/bin/:/mnt/MAUX/" (src/liba/pathtab.s), so
    # -- BIN is probed FIRST on every command lookup: with the bins in
    # -- root the shell scanned an EMPTY /bin, missed, and only
    # -- then found the tool in root -- a wasted directory read per
    # -- command, and a long, slow root `ls`. Every OTHER image already
    # -- stages into /bin (build_bin_image.py, build_shwarm_image.py,
    # -- build_textaudit_image.py); the playground was the straggler.
    # --
    # -- `sh` is the ONE exception and stays in the ROOT: the launcher
    # -- (playtest.s) spawns /bin/sh by ABSOLUTE PATH before any PATH
    # -- search exists (build_bin_image.py's own note), so the shell must
    # -- sit on the boot volume's root. Typing `sh` to nest one still
    # -- works -- PATHTAB misses /bin/SH and resolves /mnt/MAUX/SH.
    # -- Root now holds PRODOS, MAUX.SYSTEM, BYERES, sh, BIN and
    # -- DEMO. BYERES is opened by a fixed literal path (procbye.s
    # -- PBY_LOAD_RES), not looked up, so it does not compete with
    # -- MAN's `ls`-row-count concerns the same way an executable
    # -- would.
    # -- docs/VROOT.md: `sh` moves into BIN with everything else
    # -- (the launcher spawns /bin/sh; nothing in `/` is a binary
    # -- any more), and the virtual root's other directory maps
    # -- (USR, ETC, TMP) must exist on the volume.
    for d in ('BIN', 'USR', 'ETC', 'TMP'):
        prodos.mkdir(f'{root}/{d}')
    # -- /etc/issue: the boot splash. pid 1 prints it before the
    # -- first prompt (INIT_ISSUE, src/test/playtestb.s). Source is
    # -- src/etc/issue (ASCII, LF); staged as maux text -- high-bit,
    # -- $8D line ends, like the man pages -- so cat, grep and vi all
    # -- treat it as one of their own. TXT, <= 255 bytes (init reads
    # -- it in one request).
    with open(os.path.join(ROOT, 'src', 'etc', 'issue'), 'rb') as f:
        issue = f.read()
    assert len(issue) <= 255 and issue.endswith(b'\n')
    prodos.write(f'{root}/ETC/ISSUE', _hilines(*issue.decode('ascii').splitlines()),
                 file_type=0x04, aux_type=0x0000, overwrite=True)
    for name, data in util_data:
        prodos.write(f'{root}/BIN/{name}', data, file_type=0x06,
                     aux_type=0x0800, overwrite=True)
    # -- Manual pages: build/man/NAME.TXT (rendered by the Makefile from
    # -- docs/man/NAME.1, 64 columns) -> /usr/man/NAME as maux text
    # -- (high-bit ASCII, CR line ends), for `more /usr/man/NAME`.
    man_names = stage_man_pages(prodos, root)
    prodos.unmount(CARRIER_VOL)
    normalize_image_dates(staged)

    sizes = ', '.join(f'{name} ({len(data)} bytes)' for name, data in util_data)
    print(f'[build-play] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-play] kept={kept} removed={removed}')
    print(f'[build-play] wrote MAUX.SYSTEM ({len(system)} bytes), {sizes}')
    print(f'[build-play] MAN pages: {", ".join(man_names) or "none"}')
    vol = prodos.Volume(staged, readonly=True)
    try:
        free, total = vol.free_blocks, vol.total_blocks
    finally:
        vol.close()
    print(f'[build-play] {OUT_IMG} ready ({os.path.getsize(staged)} bytes), '
          f'{free} of {total} blocks free')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
