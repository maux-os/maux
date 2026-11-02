#!/usr/bin/env python3
"""STATUS 2026-09-13: GREEN -- `make nas-librel-image`, consumed by
`make check-nas-librel` (see check_nas_librel.py's header for the
roster result, what the "hang" turned out to be, and the levers).
Generalised the same day from the pwd pilot to THE ROSTER SWEEP: every
liba REL module and every src/bin util with a build/<util>.bin -- 46
utils staged and byte-identical (the BODY-PUT SPLIT, generate_pieces,
below, on the STREAMING ld), 5 skipped with measured reasons (a
PC-equate span, or not a LOAD_BASE program).

Build build/nas-librel.po -- the check-nas-librel gate image
(docs/AS-LINKER-SPIKE.md / the linker path): COOKED nas assembles each
util's generated REL closure and `ld` links it, the modular route that
sidesteps nas's whole-source memory wall (docs/AS-STREAM.md sec 0) by
splitting liba out of the monolith into REL library modules.

This is the check-librelas sweep (build_librelas_image.py; both
retired 2026-10-18) with nas
swapped in for the Sweet16 `as`: same gen_rel_module.py forms, same
`ld -z`, same build/<util>.bin byte-identity bar. The
kernel-manifest segments and kernel links are staged too (S5, below).

Staged on a play image:
  /bin/NAS    build/nas.cut  -- nas COOKED by plascut (a plain
                                      util; docs/PLASCUT.md), so the
                                      sweep is `nas -o ...`, make-style
  /bin/LD     build/ld.bin   -- maux's native REL linker
  /tmp/LR/<B>RL.S               -- each liba module's REL form
  /tmp/LR/<B>M.S, <B>B.S, ..    -- each util's REL main + extracted
                                     bss module(s); <B>P2.S.. its
                                     further pieces (generate_pieces),
                                     whose objects go to /usr/lib/
                                     LIB<B>/ and link via `-l b`
  /tmp/LR/<B>Q.S                -- the form's merged equ subset
  /tmp/LR/<FLAT>.S              -- the equ files and same-dir body
                                     modules those forms put, plus HEX
                                     put chains for `putbin` blobs
  /tmp/LR/SWEEP                 -- the sh script (`sh SWEEP`): one
                                     `nas`/`ld` line per object, stdout
                                     appended to /tmp/LR/NASLOG, then
                                     `echo SWEEPDONE`
  build/nas-librel-plan.json      -- what was staged, what was skipped
                                     and why, per-util link lists

Everything staged goes through stage_text (comment lines stripped,
blank lines deleted, trailing `;` comments cut) -- that is what makes a
module fit nas's ~16 KB heap at all. A unit whose staged main + its
put closure is PREDICTED over that heap is skipped here with the
number (plan['skipped']), so the sweep spends no cycles proving it;
anything under the prediction is staged and nas gets the last word
(`nas: out of memory` in NASLOG is a real tier-2 reason, recorded by
the checker).

The generated forms carry house-relative `put ../liba/..` / `put
../../inc/..` operands maux cannot resolve; every one is rewritten
to a flat /tmp/LR/<FLATNAME> path and the file staged as <FLATNAME>.S,
the build_nas_real_image.py technique (nas appends '.S' itself). `rel`/
`dsk`/`ent`/`ext` etc. are left alone.
"""
import glob
import json
import collections
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_maux_src_image as bmsi  # noqa: E402 -- flat_name/assign
from gen_rel_module import generate, generate_main, EQU_ORDER  # noqa: E402
from gen_rel_module import generate_split_main, lit_rewrite  # noqa: E402
import check_librel as cl  # noqa: E402 -- modules(), KERNEL_FLAT
import plascut  # noqa: E402
import strip_comments as sc  # noqa: E402
from stage_putbin import blob_to_hex_puts  # noqa: E402
from check_stagebin import _blob_prefix  # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos, convert  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAY_IMG = os.path.join(ROOT, 'build', 'play.po')
# NAS_SELFMAKE=1: the SELF-MAKE variant (S5's last rung -- the nas twin
# of check-selfmake): the same staged tree, but /tmp/LR/SWEEP is
# `make -f MAKEFILE ALL` over a staged MAKEFILE whose rules are every
# nas assembly and ld link the utils and MAUXPLAY.SYSTEM need, then
# `make -n` again (must have nothing to do). Never sharded: make
# drives it. Image and plan get their own names.
SELFMAKE = bool(os.environ.get('NAS_SELFMAKE'))
OUT_IMG = os.path.join(ROOT, 'build',
                       'nas-selfmake.po' if SELFMAKE else 'nas-librel.po')
PLAN = os.path.join(ROOT, 'build',
                    'nas-selfmake-plan.json' if SELFMAKE
                    else 'nas-librel-plan.json')
NAS_BUILD_DIR = os.path.join(ROOT, 'build')
NAS_CUT = os.path.join(NAS_BUILD_DIR, 'nas.cut')
LD_BIN = os.path.join(ROOT, 'build', 'ld.bin')
VOL = 'MAUX'
BINDIR = f'/mnt/{VOL}/BIN'
LRDIR = f'/tmp/LR'
# LIBKDIR -- where the kernel's REL objects (ld's `-l k`/`kmod`
# target) get their FINAL, linkable names. Same physical role in
# both modes, DIFFERENT path: check-nas-librel keeps the readable
# `/usr/lib/LIBK` name (unaffected by SELFMAKE-only changes); SELFMAKE's
# staged MAKEFILE pays for every one of MAUXPLAY's ~44 kernel
# dependencies TWICE -- once as a `-L`-relative link operand, once as
# a full-path MAKEFILE dependency -- and `compose_makefile()`'s own
# MK_DEPBSZ check (native make's per-rule expansion-buffer cap,
# read live from src/bin/make.s) measured MAUXPLAY's dependency list
# at 1108B against a 1024B cap with the `/LIB/LIBK/` (9 extra chars
# over a bare `/K`) prefix repeated ~44 times -- a genuinely NEW
# wall KSEG's own four added kernel-flat modules (PROCDEV, KBYLNCH,
# KBYE, KDEVBLK) pushed an already-tight budget over (the code's own
# comment already records the pre-KSEG 44-module closure at 1,123B,
# right at this same wall). A short directory saves characters per
# entry, comfortably under budget -- SELFMAKE-only, since it
# builds its OWN separate image (nas-selfmake.po) and touches
# nothing check-nas-librel (nas-librel.po) stages or links.
#
# THE SHORT DIRECTORY MUST STILL BE A LIBRARY ld CAN FIND (KFIX4
# item 1). `ld -l k` searches `<each -L path>/LIBK`, then
# `/usr/lib/LIBK` -- the directory is found BY NAME, LIB + k. This
# was `/tmp/K` (and `/{VOL}/K` before the vroot move) from
# 2026-09-28 (fb4626b), so the library ld scanned was
# /usr/lib/LIBK, which holds only the kernel SOURCES in this image
# (type TXT, never a $F8 member): `-l k` took nothing, every symbol
# the explicit modules left undefined stayed undefined, and the
# guest's ld stopped on the first one (`undefined symbol PRC_BRK`,
# KDISPR's). 3 characters dearer than `/tmp/K` and named the way ld
# looks it up; the link line names its PARENT as a second -L so the
# library is found there (SELFMAKE_LIBROOT below).
LIBKDIR = f'/tmp/LIBK' if SELFMAKE else f'/usr/lib/LIBK'
# how many `Mn = ...` module-list macros to define; make.s
# MK_MAXMAC is the hard cap and two are already spent on A/L
MK_MACRO_BUDGET = 48
LOG = f'{LRDIR}/NASLOG'


# FULL (docs/FULLDISK.md): the same self-make composer, re-pointed from
# its test layout to the release disk's. configure_full() is called by
# scripts/build_full_image.py BEFORE main(); nothing here changes the
# two gate variants (librel, selfmake), which keep their /tmp layout.
# What moves: the staged world (LRDIR, where `cd /usr/src/maux; make`
# finds its MAKEFILE) and the link argument files (LNKDIR). What stays
# in /tmp, and why: LIBKDIR. The kernel link names ~44 objects TWICE
# (a dependency list and a recipe); make.s expands a dependency list
# into one MK_DEPBSZ (1,024 B) buffer, and the play kernel's list is
# already ~990 B with the 9-character /tmp/LIBK prefix (the compose
# asserts below read MK_DEPBSZ live). A 17-character /usr/src/maux/LIBK
# would put it ~350 B over the cap. The objects it receives are build
# products, so /tmp is where a person expects them.
FULL = False
# (object leaf, source leaf) of every liba REL assembly the composer
# staged, in script (= directory) order: build_full_image.py runs
# exactly these, once, to make /usr/lib/LIBA.
LIBA_NAS = []


def configure_full(out_img):
    """Switch this module to the release-disk layout, writing to
    out_img (an imglock temp path). Implies SELFMAKE: the MAKEFILE is
    the point."""
    global FULL, SELFMAKE, OUT_IMG, PLAN, LRDIR, LNKDIR, LOG, LIBKDIR
    FULL = True
    SELFMAKE = True
    LIBKDIR = '/tmp/LIBK'
    OUT_IMG = out_img
    PLAN = os.path.join(ROOT, 'build', 'full-plan.json')
    LRDIR = '/usr/src/maux'
    LNKDIR = '/usr/src/maux/LNK'
    LOG = f'{LRDIR}/NASLOG'
# ARGUMENT FILES (KFIX3 item 0, src/bin/ldargf.s). A link line is
# limited by the SPAWNER's argv -- make's MK_MAXARG and sh's MAXARGV,
# 32 slots each, 31 usable after `ld` -- not by ld. A line of more
# than ARGFILE_ABOVE words is therefore staged as a file of its
# words under LNKDIR and run as `ld @/tmp/LNK/UTIL`, which costs two
# argv words however long the list is. The cap used to bound the
# SEGMENT (every piece the planner cut was a word), the bss chunking
# and the nas heap factor together; none of them is a budget any
# more. ARGFILE_ABOVE is below 31 on purpose: a rule that only fired
# at the cap would leave the file path unexercised until the day a
# util needed it, and sh and more were both at 31 with none spare.
# ld's own limits are 1,022 B of words (ARGFLIM is 1,023 and a read
# that fills it is refused as truncated: src/bin/ldargf.s, gated by
# check-ld LDOUT9/LDOUT10) and ARGFMAXW (99 words), asserted below.
LNKDIR = '/tmp/LNK'
ARGFILE_ABOVE = 24
# ... read from ld.s itself so the two cannot drift again (review F6:
# the planner asserted 1,023 while ld refuses a file of 1,023).
ARGF_BYTES = int(re.search(
    r'^ARGFLIM\s+equ\s+(\d+)', open(os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        'src', 'bin', 'ld.s')).read(), re.M).group(1)) - 1
ARGF_WORDS = 99

# nas's heap on this image: build/nas.cut loads at $0800 and the heap
# runs from its end to PRC_BRK_LIM ($BF00). Recomputed from the cooked
# image's actual size in main(); the prediction below skips a unit whose
# staged SOURCE alone would not fit, before tables are even charged.
BRK_LIM = 0xBF00
COOK_BASE = 0x0800
VALIDATED_HEAP = 11647   # the cooked nas heap the budget model was validated against

# Same exclusions as build_librelas_image.py, same reasons: mld is not
# a self-hosting subject (superseded by ld, not in UTILS); `as` is
# pinned by the 2026-09-01 ruling (wraps the vendored Merlin core, slated
# for replacement by nas itself -- assembling it with nas is circular).
SWEEP_EXCLUDE = {'MLD'}
PINNED_SKIPS = {'AS': 'pinned by ruling 2026-09-01: wraps the vendored '
                      'Merlin core; nas is its replacement'}

PUT_RE = re.compile(r'^([ \t]+)(put|use)([ \t]+)(\S+)', re.IGNORECASE)
PUTBIN_RE = re.compile(r'^[ \t]+putbin[ \t]+(\S+)', re.IGNORECASE)


def _strip_trailing_comment(line):
    """Drop a `;comment` tail (and trailing blanks) from a non-comment
    line, quote-aware: a `;` inside a "..."/'...' string operand is
    literal (nas's own parseline rule -- `asc "a;b"` keeps it)."""
    out = []
    quote = None
    for ch in line:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
        elif ch in '"\'':
            quote = ch
            out.append(ch)
        elif ch == ';':
            break
        else:
            out.append(ch)
    return ''.join(out).rstrip()


def _squeeze(line):
    """Collapse runs of spaces to one, outside quotes: nas's parseline
    is whitespace-delimited (any run of spaces is one separator), so
    Merlin's padded columns are pure heap cost -- a third of the
    staged text (measured 2026-09-13). Quote-aware for the same reason
    _strip_trailing_comment is."""
    out = []
    quote = None
    prev = None
    for ch in line:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
        elif ch in '"\'':
            quote = ch
            out.append(ch)
        elif ch == ' ' and prev == ' ':
            continue
        else:
            out.append(ch)
        prev = ch
    return ''.join(out)


def stage_text(text, name):
    """The nas-staging reduction: comment-only lines blanked
    (scripts/strip_comments.py, the tree's ONE strip rule), then blank
    lines DELETED and trailing `;` comments cut. Byte-inert by
    construction -- every line that emits object bytes passes through
    with its label/mnemonic/operand intact -- and it is what makes a
    real liba module fit: a cooked nas has ~16 KB of heap for the
    whole spliced closure plus its tables, and stdio.s's REL form is
    22.7 KB of text before its equ files (2026-09-13 measurement: the
    forms shrink 3-7x; the largest, stdiofl, from 26 KB with its puts
    to 5.7 KB). Line numbers are NOT preserved (unlike the Merlin-8
    staging, which blanks rather than deletes) -- nas reports no line
    numbers, so there is nothing to keep aligned."""
    stripped = sc.strip_text(text, name=name)
    out = []
    for line in stripped.split('\n'):
        line = _squeeze(_strip_trailing_comment(line))
        if line.strip():
            out.append(line)
    return '\n'.join(out) + '\n'


def rewrite_puts(text, src_relpath, names):
    """Rewrite every put/use operand to /tmp/LR/<FLATNAME> (bare).
    `src_relpath` is the ROOT-relative path of the module the form was
    generated FROM -- put operands resolve relative to its directory."""
    src_dir = os.path.dirname(src_relpath)
    out = []
    for line in text.split('\n'):
        m = PUT_RE.match(line)
        if m:
            tgt = os.path.normpath(os.path.join(src_dir, m.group(4)))
            if tgt not in names:
                raise AssertionError(
                    f'{src_relpath}: put target {m.group(4)!r} -> {tgt!r} '
                    'has no flat name (equ closure incomplete)')
            out.append(f'{m.group(1)}{m.group(2)}{m.group(3)}'
                       f'{LRDIR}/{names[tgt]}')
        else:
            out.append(line)
    return '\n'.join(out)


def collect_put_targets(text, src_relpath):
    src_dir = os.path.dirname(src_relpath)
    tgts = []
    for line in text.split('\n'):
        m = PUT_RE.match(line)
        if m:
            tgts.append(os.path.normpath(os.path.join(src_dir, m.group(4))))
    return tgts



# ---- the nas memory model and the equ subset ---------------------
# Production incremental storage, 2026-09-19. No retained source/line
# table and no unconditional retry array. See memory_model below and
# check_nas_memory_model.py; guest OOM and full-world gates stay final.
HEAP_MARGIN = 1024
# Two readers, line + emission buffers, writer, and symbol hash heads.
NAS_FIXED_HEAP = 2 * 512 + 2 * 256 + 512 + 256
# Initial replay page, optional local index and small model slack. The
# complete staged-form estimate below remains the acceptance check.
NAS_SPLIT_RESERVE = NAS_FIXED_HEAP + 260 + 256 + 64
BRANCH_MN = {'bcc', 'bcs', 'beq', 'bmi', 'bne', 'bpl', 'bra', 'bvc', 'bvs'}
DIRECTIVES = {'equ', '=', 'put', 'use', 'ent', 'ext', 'err', 'dum',
              'dend', 'lst', 'xc', 'rel', 'dsk', 'typ', 'tr', 'exp',
              'org', 'ds', 'dfb', 'db', 'asc', 'hex', 'dci', 'str', 'da',
              'dw', 'ddb'}
IDENT_RE = re.compile(r'[A-Za-z_:][A-Za-z0-9_]*')
EQU_LINE_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)[ \t]+(equ|=)[ \t]+(.*)$',
                         re.IGNORECASE)


def _heap_line(line):
    """Staged source only: comments already removed by stage_text."""
    parts = line.split(None, 2 if line[0] not in ' \t' else 1)
    label = parts.pop(0) if line[0] not in ' \t' else ''
    return label, parts[0].lower() if parts else '', parts[1] if len(parts) > 1 else ''


def _fixup_candidates(mn, operand):
    if mn in ('dfb', 'db', 'da', 'dw'):
        # Quoted numeric-list items contribute one item even with commas.
        bare = re.sub(r'"[^"]*"|\x27[^\x27]*\x27', '0', operand)
        return len(bare.split(',')) if operand else 0
    if mn in DIRECTIVES or not mn or not operand or mn in BRANCH_MN:
        return 0
    if mn in ('asl', 'lsr', 'rol', 'ror', 'inc', 'dec') and operand.lower() == 'a':
        return 0
    return 1


def assert_complete_world(utils, kernels, skipped):
    """Minimum release roster; never accept a silently skipped utility."""
    if set(skipped) != set(PINNED_SKIPS) or len(utils) < 85 or not kernels:
        raise AssertionError('incomplete native world roster: ' + str(skipped))


def memory_model(text):
    """Incremental two-pass storage, conservative for staged REL forms.

    Stable symbols cost 9 record + 2 link + counted name; local records
    cost 6 plus a lazy 256-byte index. Replay has 256-byte payloads in
    260-byte pages, including one empty page. Fixups follow noteinst and
    numeric-list pass1 sizing. ERR/retry text is linked, not reserved.
    Repeated labels/local names are overcounted deliberately; 64 bytes
    slack and HEAP_MARGIN cover unmodelled staging/runtime overhead.
    This is not an arbitrary-source assembler or a substitute for OOM.
    """
    code = locs = names = records = fixes = 0
    settled = set()
    for line in text.splitlines():
        if not line.strip():
            continue
        label, mn, operand = _heap_line(line)
        names += 12 + min(13, len(label)) if label else 0
        locs += label.startswith(':')
        code += bool(mn and mn not in DIRECTIVES)
        fixes += _fixup_candidates(mn, operand)
        if mn == 'err':
            records += 7 + min(255, len(operand))
        if mn in ('equ', '='):
            bare = re.sub(r'"[^"]*"|\x27[^\x27]*\x27|\$[0-9a-fA-F]+', '0', operand)
            unresolved = set(IDENT_RE.findall(bare)) - settled
            if unresolved:
                records += 9 + min(65, len(operand))
            elif label:
                settled.add(label)
        elif label:
            settled.add(label)
    replay = 260 * max(1, (code + 255) // 256)
    return (NAS_FIXED_HEAP + names + 6 * locs + (256 if locs else 0)
            + replay + 4 * fixes + 1 + records + 64)


def parse_equ_items(text):
    """A staged equ file as ITEMS: ('equ', {name}, [line], {refs}) for a
    definition line, or ('block', {names}, [lines], {refs}) for a whole
    dum..dend block (mm.procbnk2.equ's $FF00 overlay -- its `ds`
    lines define offsets positionally, so the block is kept or dropped
    as ONE unit). The equ files hold nothing else (measured 2026-09-13:
    406 equ lines, 2 dum blocks, 17 ds lines inside them)."""
    items = []
    block = None
    for line in text.split('\n'):
        if not line.strip():
            continue
        toks = line.split()
        mn = (toks[1] if line[0] not in ' \t' and len(toks) > 1
              else toks[0] if line[0] in ' \t' else '').lower()
        if mn == 'dum':
            block = ['block', set(), [line], set(IDENT_RE.findall(
                ' '.join(toks[toks.index('dum') + 1:]) if 'dum' in toks
                else '')) ]
            continue
        if block is not None:
            block[2].append(line)
            if line[0] not in ' \t':
                block[1].add(toks[0])
                block[3] |= set(IDENT_RE.findall(' '.join(toks[2:])))
            if mn == 'dend':
                items.append(tuple(block))
                block = None
            continue
        m = EQU_LINE_RE.match(line)
        if not m:
            raise AssertionError(f'equ file line not an equate: {line!r}')
        items.append(('equ', {m.group(1)}, [line],
                      set(IDENT_RE.findall(m.group(3)))))
    assert block is None, 'unterminated dum block in an equ file'
    return items


def equ_subset(need_text, item_lists):
    """The merged equ file a form actually needs: every definition
    whose name appears in `need_text` (the form plus its body puts),
    closed transitively over the kept definitions' own references, in
    the original (canonical) order. Unused equates -- ~100 of the 107
    a typical util's closure defines (measured 2026-09-13) -- cost nas
    a 26 B symbol slot, an 11 B line slot and ~30 B of text EACH, so
    this is the single largest saving on the linker path."""
    need = set(IDENT_RE.findall(need_text))
    items = [it for lst in item_lists for it in lst]
    keep = [False] * len(items)
    changed = True
    while changed:
        changed = False
        for i, (_k, names, _lines, refs) in enumerate(items):
            if not keep[i] and names & need:
                keep[i] = True
                need |= refs
                changed = True
    out = []
    for i, (_k, _names, lines, _refs) in enumerate(items):
        if keep[i]:
            out.extend(lines)
    return ('\n'.join(out) + '\n') if out else ''


def _equ_slot(lines):
    """Where the merged equ put goes: after the head directives (rel,
    dsk, lst, tr, exp, xc, typ) -- before any label, ext or code."""
    for i, l in enumerate(lines):
        toks = l.split()
        if not toks:
            continue
        mn = toks[0].lower() if l[0] in ' \t' else None
        if mn in ('rel', 'dsk', 'lst', 'tr', 'exp', 'xc', 'typ'):
            continue
        return i
    return len(lines)


# ---- the body-put split: a util as consecutive REL pieces ---------
# A util's main `put`s same-directory code files (dd: ddparse.s +
# ddcopy.s; ld: six of them) and merlin32 splices them into ONE unit,
# which nas would have to hold whole -- 7-110 KB against a ~15 KB
# heap. generate_pieces turns the spliced stream into consecutive REL
# modules instead (link order = stream order = byte identity), cut at
# global labels by the memory model, the shape gen_rel_module.
# generate_kernel_main uses for the kernel manifests and
# generate_split_main for as.s -- but budget-driven, no listing, and
# the cross-piece symbol rules spelled out:
#   * a LABEL defined in piece j and used in piece i: `SYM ent` in j
#     (the label moved onto the ENT line), `SYM ext` in i;
#   * an EQUATE defined in piece j and used in piece i is COPIED into
#     i (transitively over the equates it references) -- ENT cannot
#     export an equate; a copied equate that leans on a LABEL is
#     refused (its value would become a bare addend);
#   * a SHORT BRANCH may not cross a cut (a relative displacement
#     cannot be relocated), so a cut a branch straddles is skipped;
#   * a `:local` referenced across a cut is refused (global labels
#     are zone boundaries, so only a cut inside a zone could do it,
#     and a cut is never inside a zone);
#   * labels inside a literal `dum $xxxx` block are absolute and
#     cannot ride ENT/EXT (the dictionary is $8000-based); such a
#     block is never cut and a cross-piece use of its labels is
#     refused.
# Every refusal names the unit, the piece and the symbols, and lands
# in the plan file as the unit's skip reason.
#
LOCAL_RE = re.compile(r'(?<![A-Za-z0-9_]):[A-Za-z0-9_]+')
BRANCH_RE = re.compile(r'^\S*\s+b(?:ra|eq|ne|cc|cs|mi|pl|vc|vs)\s+'
                       r'([A-Za-z_][A-Za-z0-9_]*)\s*$', re.IGNORECASE)
EQU_DEF_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s+(equ|=)\s+(.*)$',
                        re.IGNORECASE)
HEAD_RE = re.compile(r'^\s+(lst|xc|org|dsk|typ|tr|exp|rel)\b',
                     re.IGNORECASE)
STRING_MN = {'asc', 'dci', 'str', 'hex'}


def _has_pc_term(opnd):
    """Is `*` used as a TERM (this line's address) in a Merlin operand,
    as opposed to the multiply OPERATOR (`MAXCMD*MAXARGV*2`)? A term is
    a `*` where a term is expected: first, or right after an operator."""
    toks = re.findall(r"\$[0-9A-Fa-f]+|\d+|[A-Za-z_:][A-Za-z0-9_]*|'[^']*'"
                      r'|"[^"]*"|[-+*/.!&<>#]', opnd.split(';')[0])
    want_term = True
    for t in toks:
        if want_term:
            if t in '<>#':
                continue
            if t == '*':
                return True
            want_term = False
        else:
            want_term = True
    return False


def _globalize_unique_locals(stream):
    zone_of = []
    zone = 0
    ldefs = {}
    for i, l in enumerate(stream):
        if re.match(r'^[A-Za-z_]', l):
            zone += 1
        zone_of.append(zone)
        if l[0] == ':':
            ldefs.setdefault(l.split()[0], []).append((zone, i))
    lrefs = {}                  # :name -> [line index of each reference]
    for i, l in enumerate(stream):
        if _mnemonic(l) in STRING_MN:
            continue
        toks = l.split()
        opnd = ' '.join(toks[2:] if l[0] not in ' \t' else toks[1:])
        for name in LOCAL_RE.findall(opnd):
            lrefs.setdefault(name, []).append(i)
    existing = set()
    for l in stream:
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)', l)
        if m:
            existing.add(m.group(1))
    rename = {}
    for name, defs in ldefs.items():
        if len(defs) != 1:
            continue
        dz, di = defs[0]
        if all(zone_of[r] == dz for r in lrefs.get(name, [])):
            continue                    # never referenced cross-zone
        # safety: no OTHER local of zone dz has a def/ref pair on
        # opposite sides of line di
        safe = True
        for other, odefs in ldefs.items():
            if other == name:
                continue
            for oz, oi in odefs:
                if oz != dz:
                    continue
                for r in lrefs.get(other, []):
                    if zone_of[r] == dz and (oi < di) != (r < di):
                        safe = False
        if not safe:
            continue
        newname = 'L_' + name[1:]
        if newname in existing or len(newname) > 13:
            continue
        rename[name] = newname
        existing.add(newname)
    if not rename:
        return stream
    out = []
    for l in stream:
        if _mnemonic(l) in STRING_MN:
            out.append(l)
            continue
        for old, new in rename.items():
            l = re.sub(r'(?<![A-Za-z0-9_])' + re.escape(old)
                       + r'(?![A-Za-z0-9_])', new, l)
        out.append(l)
    return out


class PieceRefusal(Exception):
    pass


def _mnemonic(line):
    toks = line.split()
    if not toks:
        return ''
    return (toks[1] if line[0] not in ' \t' and len(toks) > 1
            else toks[0] if line[0] in ' \t' else '').lower()


def _line_cost(line):
    """Splitter heuristic; memory_model checks complete generated forms."""
    c = 0
    if line[0] not in ' \t':
        c += 12 + min(13, len(line.split()[0]))
        if line[0] == ':':
            c += 6  # Shared lazy index is in NAS_SPLIT_RESERVE.
    _, mn, operand = _heap_line(line)
    if mn == 'err':
        c += 7 + len(operand)
    elif mn and mn not in DIRECTIVES:
        c += 1
    c += 4 * _fixup_candidates(mn, operand)
    return c


def _scan_lines(lines):
    """(defined, used) over staged lines -- check_modules.scan on a
    temp file, the tree's one Merlin-aware symbol scanner."""
    import tempfile
    import check_modules as ckm
    with tempfile.NamedTemporaryFile('w', suffix='.s', delete=False) as tf:
        tf.write('\n'.join(lines) + '\n')
        tp = tf.name
    try:
        d, u = ckm.scan(tp)
    finally:
        os.unlink(tp)
    return set(d), set(u)


def _locals(lines):
    """(defined, used) `:local` names over staged lines."""
    ldef, luse = set(), set()
    for line in lines:
        if line[0] == ':':
            ldef.add(line.split()[0])
        mn = _mnemonic(line)
        if mn in STRING_MN:
            continue
        toks = line.split()
        opnd = ' '.join(toks[2:] if line[0] not in ' \t' else toks[1:])
        luse |= set(LOCAL_RE.findall(opnd))
    return ldef, luse


def generate_pieces(mod_rel, main_text, bss_cells, budget, is_lib=False,
                    body_lits=None):
    """(pieces: [text], refusal_or_None). See the block comment.
    `body_lits` (generate_split_main's): per put file, the line
    numbers whose PC equates become listing literals as the put is
    inlined (plasmavm.s `TMPLEN equ *-INNERTMP`)."""
    body_lits = body_lits or {}
    from gen_rel_module import _liba_defs, _equ_defs
    src_dir = os.path.dirname(mod_rel)
    import check_modules as ckm
    liba_defs = set(_liba_defs(os.path.join(ROOT, mod_rel),
                               peer_dir='src/liba'))
    all_equ = set().union(*_equ_defs().values())
    bss_cells = set(bss_cells)

    equ_puts = []
    stream = []                 # staged lines, in byte order
    in_dum = []                 # parallel: inside a literal dum block
    raw_texts = [main_text]     # for the equate environment (dum blocks)
    dum_block = None            # lines of the literal dum block being read

    def literalize_dum(block):
        """A literal `dum $addr` overlay block (ex.s's EX_SHADOW at
        $D000) as `LABEL equ $addr` lines: its labels are ABSOLUTE
        addresses that must not ride ENT/EXT (the dictionary is
        $8000-based) and that nas, in a REL module, would otherwise
        classify as relocatable and fix up. As equates they are
        constants in every piece -- copied where used, no fixups --
        which is exactly the monolithic build's bytes."""
        from gen_rel_module import _equ_env, _eval_merlin
        env = _equ_env([l for t in raw_texts for l in t.split('\n')])
        head = block[0].split()
        addr = _eval_merlin(head[head.index('dum') + 1]
                            if 'dum' in head else head[-1], env)
        out = []
        for line in block[1:-1]:
            toks = line.split()
            label = toks[0] if line[0] not in ' \t' else None
            if label:
                out.append(f'{label} equ ${addr:04X}')   # was a dum cell
            mn = _mnemonic(line)
            if mn == 'ds':
                addr += _eval_merlin(toks[-1], env)
            elif mn in ('dfb', 'db'):
                addr += len(toks[-1].split(','))
            elif mn in ('da', 'dw', 'ddb'):
                addr += 2 * len(toks[-1].split(','))
            elif mn and mn not in ('equ', '='):
                raise ValueError(f'dum block line not sizeable: {line!r}')
        return out

    # liba-put MARKERS (`* @LIBA name`, generate_main) split the stream
    # into SEGMENTS: a piece from segment k must link AFTER the liba
    # modules up to and including marker k's -- so a boundary is a
    # forced cut and every piece carries its segment.
    seg_bounds = []             # (stream index, liba module name)
    # SEGMENT-RUN MARKERS (`* @SEGORG operand`, generate_main): a
    # manifest's SECOND `org` starts a block that RUNS at another base
    # while its bytes stay contiguous in the flat file (sh.s's $E000
    # language-card segment, docs/SH-SUBSET.md 7.6), and the `org`
    # after it ends the run. Told apart by whether the operand EVALS:
    # a run's base is an absolute equate (PRC_LC_COMMON), while the
    # wind-back is arithmetic over the stream's own labels
    # (SH_SEG_LOW+SH_SEG_END-SH_SEG_BEG) and cannot. Either way the
    # marker is a FORCED cut, so the block is its own piece(s), and
    # the base rides ld's `-s`.
    segorg_bounds = []          # (stream index, base int or None)

    def push(text, origin, top):
        nonlocal dum_block
        if not top:
            raw_texts.append(text)
        if top:
            for m in re.finditer(r'^\* @LIBA (\S+)$', text, re.M):
                pass
        for line in stage_text(text, origin).split('\n'):
            if not line.strip():
                continue
            if dum_block is not None:
                dum_block.append(line)
                if re.match(r'^\s+dend\b', line, re.I):
                    stream.extend(literalize_dum(dum_block))
                    in_dum.extend([False] * (len(stream) - len(in_dum)))
                    dum_block = None
                continue
            if re.match(r'^\s+dum\s+\$', line, re.I):
                dum_block = [line]
                continue
            m = PUT_RE.match(line)
            if m:
                tgt = m.group(4)
                if not top:
                    continue            # nested put: inert in merlin32
                if tgt.endswith('.equ'):
                    equ_puts.append(tgt)
                    fp = os.path.normpath(os.path.join(src_dir, tgt))
                    if os.path.exists(os.path.join(ROOT, fp)):
                        # a same-dir equ file (proshim.equ) is not on
                        # EQU_ORDER; its equates resolve like any other
                        all_equ.update(ckm.scan(os.path.join(ROOT, fp))[0])
                    continue
                fp = os.path.normpath(os.path.join(src_dir, tgt))
                with open(os.path.join(ROOT, fp), errors='replace') as f:
                    ptext = f.read()
                if fp in body_lits:
                    ptext = lit_rewrite(ptext, body_lits[fp])
                push(ptext, fp, False)
                continue
            if HEAD_RE.match(line):
                continue
            if re.match(r'^\s+err\b', line, re.I) and '*' in line:
                continue
            if re.match(r'^[A-Za-z_][A-Za-z0-9_]*\s+ext\s*$', line, re.I):
                # generate_main's / generate_kernel_main's: recomputed
                # per piece, but the NAME is an externally provided
                # symbol (a kernel segment's EXTs are kernel-module
                # exports, not liba's) -- so it joins the resolvable set
                liba_defs.add(line.split()[0])
                continue
            stream.append(line)
            in_dum.append(False)
    try:
        from gen_rel_module import _equ_env as _ee, _eval_merlin as _em
        seg_env = _ee()
        pos = 0
        for m in re.finditer(r'^\* @(LIBA|SEGORG) (\S+)$', main_text, re.M):
            push(main_text[pos:m.start()], mod_rel, True)
            if m.group(1) == 'LIBA':
                seg_bounds.append((len(stream), m.group(2)))
            else:
                try:
                    segorg_bounds.append((len(stream),
                                          _em(m.group(2), seg_env)))
                except (ValueError, KeyError, RecursionError):
                    segorg_bounds.append((len(stream), None))
            pos = m.end()
        push(main_text[pos:], mod_rel, True)
    except ValueError as e:
        return None, f'literal dum block: {e}'
    # a marker with no body text after it (the common case: every
    # liba put after all the body) forces nothing
    seg_bounds = [(i, n) for i, n in seg_bounds if i < len(stream)]
    # ... and a segment that EMITS nothing (vi.s: only the literalised
    # `dum $D000` equates follow its last liba put) forces nothing
    # either -- an equate's position is not a byte's.
    kept = []
    for k, (i, n) in enumerate(seg_bounds):
        j = seg_bounds[k + 1][0] if k + 1 < len(seg_bounds) else len(stream)
        if any(not EQU_DEF_RE.match(l) and _mnemonic(l) not in
               ('ent', 'ext', 'err', 'lst', 'xc', 'tr', 'exp', 'dsk',
                'typ', 'rel', 'put', 'use', 'dum', 'dend')
               for l in stream[i:j]):
            kept.append((i, n))
    seg_bounds = kept
    # a SEGORG bound always forces: it is a base change, not a
    # link-order one, so an empty run would still be a wrong base
    # ... except one that lands at the very END of the stream (sh.s's
    # wind-back `org`, with only the libabss marker behind it): there
    # is no piece after it to cut, and the run is closed by the link
    # line's own `-s 0` before the bss modules.
    forced = {i for i, _n in seg_bounds} | {i for i, _b in segorg_bounds
                                            if i < len(stream)}
    if dum_block is not None:
        return None, 'unterminated literal dum block'

    # A `:local` referenced from OUTSIDE its zone resolves, in merlin32,
    # by whole-file uniqueness -- it internally renames such a label
    # `_name` and treats it as a global (learning:01M0VJF2DXZR55HGJ8PT
    # N1MNJE). sh's `jmp :spawned` is one, 227 lines from its zone,
    # and as a piece-internal span it forced a ~10 KB piece. Do what
    # merlin32 does: rename the unique local to a synthetic GLOBAL
    # (definition and every reference) so it can ride ENT/EXT across
    # a cut. A global label opens a new zone, so the rename is only
    # SAFE when no other local's definition/reference pair in the
    # renamed label's zone straddles its line; otherwise it stays a
    # local and a span. Bytes are unchanged either way: a JMP to a
    # global is the same 3-byte absolute as a JMP to a local.
    stream = _globalize_unique_locals(stream)

    # cut candidates and the branch spans that veto them
    cuts = [i for i, l in enumerate(stream)
            if i > 0 and re.match(r'^[A-Za-z_]', l) and not in_dum[i]]
    gdef = {}                   # global LABEL (not equate) -> line
    dum_syms = set()
    for i, l in enumerate(stream):
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)', l)
        if m and not EQU_DEF_RE.match(l):
            gdef.setdefault(m.group(1), i)
            if in_dum[i]:
                dum_syms.add(m.group(1))
    spans = []
    for i, l in enumerate(stream):
        m = BRANCH_RE.match(l)
        if m and m.group(1) in gdef:
            j = gdef[m.group(1)]
            spans.append((min(i, j), max(i, j)))
    # a `:local` referenced from another zone (merlin32 resolves it by
    # whole-file uniqueness -- learning:01M0VJF2DXZR55HGJ8PTN1MNJE;
    # edparse.s's `bra :parseit` is one) must stay in one piece with
    # its definition; so must a PC equate (`TMPLEN equ *-INNERTMP`)
    # and the label it measures from. Both are spans like a branch's.
    zone_of = []
    zone = 0
    ldefs = {}                  # :name -> [(zone, index)]
    for i, l in enumerate(stream):
        if re.match(r'^[A-Za-z_]', l):
            zone += 1
        zone_of.append(zone)
        if l[0] == ':':
            ldefs.setdefault(l.split()[0], []).append((zone, i))
    equ_at = {}                 # piece-stream equate name -> index
    for i, l in enumerate(stream):
        m = EQU_DEF_RE.match(l)
        if m:
            equ_at.setdefault(m.group(1), i)
    label_equs = set()          # equates that lean on a stream label
    for name, i in equ_at.items():
        m = EQU_DEF_RE.match(stream[i])
        opnd3 = m.group(3).split(';')[0]
        refs = re.findall(r'[A-Za-z_][A-Za-z0-9_]*',
                          re.sub(r"\$[0-9A-Fa-f]+|'[^']*'|\"[^\"]*\"", ' ',
                                 opnd3))
        if _has_pc_term(opnd3) or any(r in gdef for r in refs):
            label_equs.add(name)
            for r in refs:
                if r in gdef:
                    spans.append((min(i, gdef[r]), max(i, gdef[r])))
    for i, l in enumerate(stream):
        mn = _mnemonic(l)
        if mn in STRING_MN:
            continue
        toks = l.split()
        opnd = ' '.join(toks[2:] if l[0] not in ' \t' else toks[1:])
        for name in LOCAL_RE.findall(opnd):
            defs = ldefs.get(name, [])
            if any(z == zone_of[i] for z, _j in defs):
                continue                # its own zone: never cut apart
            if len(defs) == 1:          # merlin32's whole-file-unique case
                j = defs[0][1]
                spans.append((min(i, j), max(i, j)))
        # a use of an equate that leans on a label stays with it (a
        # copy across pieces would turn the label into a bare addend)
        for r in re.findall(r'[A-Za-z_][A-Za-z0-9_]*', opnd):
            if r in label_equs and equ_at[r] != i:
                j = equ_at[r]
                spans.append((min(i, j), max(i, j)))
        # a LABEL-LABEL difference (proshim's `ldx #SVKB_END-SVKB_TBL-1`)
        # is a constant no fixup can express: cut either label into
        # another piece and the reference becomes an EXT low byte
        # ($BF for $12, first nas-route proshim link 2026-09-14). Both
        # definitions stay with the use. The labels need not be
        # adjacent: forktest's `jmp CHILD_SIDE+LOAD_BASE-PARENT_PROC`
        # (an equate between them) cut apart linked $69B3 for $09B9
        # once a smaller nas budget moved the cut (2026-09-14) -- any
        # label subtracted in an operand pins EVERY label in it.
        bare = re.sub(r"\$[0-9A-Fa-f]+|'[^']*'|\"[^\"]*\"", ' ',
                      opnd.split(';')[0])
        signed = re.findall(r'(-?)\s*([A-Za-z_][A-Za-z0-9_]*)', bare)
        labs = [(sg, r) for sg, r in signed if r in gdef]
        if any(sg == '-' for sg, _r in labs) and len(labs) > 1:
            for _sg, r in labs:
                j = gdef[r]
                spans.append((min(i, j), max(i, j)))

    def cut_ok(c):
        return all(not (a < c <= b) for a, b in spans)

    costs = [_line_cost(l) for l in stream]
    # Greedy forward cutting with RESTARTS: when the window opening at
    # `start` has no safe cut -- a span (a cross-zone `:local` such as
    # sh's `jmp :spawned`, a branch, or a label-leaning equate) begins
    # in the zone the piece opens with and runs past the budget -- then
    # `start` is simply not a place a piece may begin. Strike it from
    # the candidate set and cut again from the top; every restart
    # removes one candidate, so the search is bounded by their count
    # (a one-cut-back backtracking tried first thrashed exponentially
    # on sh). A failure at line 0 means the first zone itself does not
    # fit the budget: refuse, naming the span.
    for i in forced:
        if not cut_ok(i) or not re.match(r'^[A-Za-z_]', stream[i]):
            return None, (f'body text after a liba put at stream line '
                          f'{i} ({stream[i][:40]!r}) is not a safe cut')
    forbidden = set()
    while True:
        chunks = []
        start = 0
        failed_at = None
        while start < len(stream):
            acc = 0
            fits = []
            end = len(stream)
            for i in range(start, len(stream)):
                if i in forced and i > start:
                    fits.append(i)      # a segment boundary: cut HERE
                    end = i
                    break
                acc += costs[i]
                if acc > budget:
                    end = i
                    break
                if i in cuts and i > start and i not in forbidden \
                        and cut_ok(i):
                    fits.append(i)
            if end == len(stream):
                chunks.append(stream[start:])
                break
            if not fits:
                failed_at = (start, end)
                break
            chunks.append(stream[start:fits[-1]])
            start = fits[-1]
        if failed_at is None:
            break
        fstart, fend = failed_at
        if fstart == 0:
            veto = [(a, bb) for a, bb in spans if a <= fstart and bb >= fend]
            veto.sort(key=lambda ab: ab[0] - ab[1])
            note = ''
            if veto:
                a, bb = veto[0]
                note = (f'; the window lies inside span {a}-{bb}: '
                        f'{stream[a][:40]!r} .. {stream[bb][:40]!r}')
            return None, (f'no branch-safe global-label cut inside a '
                          f'{budget} B window from line 0 '
                          f'({stream[0][:40]!r}){note}')
        forbidden.add(fstart)

    chunk_start = []
    acc = 0
    for ch in chunks:
        chunk_start.append(acc)
        acc += len(ch)
    # each chunk's segment: how many forced boundaries lie at or
    # before its start; the boundary's liba module names the group
    # the chunk must link after
    chunk_seg = [sum(1 for b, _n in seg_bounds if b <= cs)
                 for cs in chunk_start]
    # each chunk's SEGMENT-RUN base: the last @SEGORG at or before its
    # start, None outside a run (and None for the wind-back marker,
    # which is what ENDS one)
    def _sbase(cs):
        run = [b for i, b in segorg_bounds if i <= cs]
        return run[-1] if run else None
    chunk_sbase = [_sbase(cs) for cs in chunk_start]
    # per-piece symbol surfaces
    scans = [_scan_lines(ch) for ch in chunks]
    equ_lines = {}              # name -> (piece, line) for piece equates
    equ_defined = []
    for k, ch in enumerate(chunks):
        eq = set()
        for l in ch:
            m = EQU_DEF_RE.match(l)
            if m:
                eq.add(m.group(1))
                equ_lines[m.group(1)] = (k, l)
        equ_defined.append(eq)
    label_defs = [d - equ_defined[k] for k, (d, _u) in enumerate(scans)]
    # a liba module's generated form already carries `LABEL ent` lines
    # (its exports to the programs); those labels are defined in their
    # piece and already exported, so a cross-piece use needs no second
    # ENT -- only the EXT on the using side.
    already_ent = [set(l.split()[0] for l in ch
                       if re.match(r'^\w+ ent$', l, re.I)) for ch in chunks]

    base = os.path.basename(mod_rel)[:-2]
    pieces = []
    for k, ch in enumerate(chunks):
        d, u = scans[k]
        suffix = ('' if is_lib else 'M') if k == 0 else f'P{k + 1}'
        ldef, luse = _locals(ch)
        if luse - ldef:
            return None, (f'piece {suffix}: :local referenced across a '
                          f'cut: {sorted(luse - ldef)}')
        need = u - d
        other_labels = set().union(*(label_defs[j] for j in range(len(chunks))
                                     if j != k)) if len(chunks) > 1 else set()
        other_equs = set().union(*(equ_defined[j] for j in range(len(chunks))
                                   if j != k)) if len(chunks) > 1 else set()
        ext_other = need & other_labels
        if ext_other & dum_syms:
            return None, (f'piece {suffix}: uses absolute dum-block '
                          f'labels of another piece: '
                          f'{sorted(ext_other & dum_syms)}')
        # copied equates, transitively over piece equates
        copied = []
        todo = sorted(need & other_equs)
        seen = set()
        while todo:
            name = todo.pop(0)
            if name in seen:
                continue
            seen.add(name)
            _j, line = equ_lines[name]
            m = EQU_DEF_RE.match(line)
            refs = set(re.findall(r'[A-Za-z_][A-Za-z0-9_]*',
                                  re.sub(r"\$[0-9A-Fa-f]+|'[^']*'|\"[^\"]*\"",
                                         ' ', m.group(3).split(';')[0])))
            bad = refs - all_equ - set(equ_lines) - equ_defined[k]
            if _has_pc_term(m.group(3)):
                bad.add('*')
            if bad:
                return None, (f'piece {suffix}: needs equate {name} '
                              f'({m.group(3).strip()!r}) which leans on '
                              f'a label of another piece: {sorted(bad)}')
            copied.append((equ_at.get(name, 0),
                           f'{m.group(1)} equ {m.group(3).split(";")[0].strip()}'))
            todo.extend(sorted(r for r in refs
                               if r in equ_lines and r not in equ_defined[k]))
        # SOURCE ORDER, and on the side of the piece the original sat:
        # nas (like merlin32) sizes an operand in pass 1 with whatever
        # an equate is worth AT THAT LINE -- a chain copied users-first
        # (`TAKEPOOL equ MEMPOOL+MEMPLCAP` ahead of MEMPOOL) evaluated
        # to 0 and `stz TAKEPOOL` came out zero-page, one byte short
        # (LD, the roster's first piece run). Equates the source
        # defined AFTER this piece's lines go at its tail, so a use
        # stays a forward reference and sizes ABS exactly as the
        # monolithic assembly did (the EQU-forward silent-miscompile
        # parity, learning:01M05519PC55WGJNE4PY5HX4TH).
        copied.sort()
        head_equs = [l for i, l in copied if i < chunk_start[k]]
        tail_equs = [l for i, l in copied if i >= chunk_start[k]]
        exts = sorted((need & liba_defs) | (need & bss_cells) | ext_other)
        unresolved = (need - all_equ - liba_defs - bss_cells - other_labels
                      - other_equs - seen)
        if unresolved:
            return None, (f'piece {suffix}: unresolved {sorted(unresolved)}')
        ents = sorted((label_defs[k] - already_ent[k]) & set().union(
            *(scans[j][1] for j in range(len(chunks)) if j != k))) \
            if len(chunks) > 1 else []
        out = [f'* {base}{suffix} -- {mod_rel} REL piece {k + 1}/'
               f'{len(chunks)}, GENERATED',
               f'* (build_nas_librel_image.generate_pieces)',
               ' rel', ' lst off', ' tr', ' exp off', ' xc']
        for tgt in equ_puts:
            out.append(f' put {tgt}')
        for sym in exts:
            out.append(f'{sym} ext')
        out.extend(head_equs)
        ent_set = set(ents)
        for line in ch:
            m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)(\s+)(.*)$', line)
            if m and m.group(1) in ent_set:
                out.append(f'{m.group(1)} ent')
                out.append(f' {m.group(3)}')
                ent_set.discard(m.group(1))
                continue
            m2 = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*$', line)
            if m2 and m2.group(1) in ent_set:
                out.append(f'{m2.group(1)} ent')
                ent_set.discard(m2.group(1))
                continue
            out.append(line)
        if ent_set:
            return None, (f'piece {suffix}: exported symbols never seen '
                          f'as label definitions: {sorted(ent_set)}')
        out.extend(tail_equs)
        pieces.append('\n'.join(out) + '\n')
    seg_after = [None] + [n for _b, n in seg_bounds]   # seg k follows liba n
    return pieces, {'segs': chunk_seg, 'seg_after': seg_after,
                    'sbase': chunk_sbase}


_LIB_BSS_CACHE = {}


def lib_bss_size(mod_base):
    """Emitted bytes of a liba module IF it is a pure-bss module (its
    `ds` cells emit zeros in REL), else 0 -- the bytes it occupies in
    ld's build area ahead of `-z`."""
    if mod_base in _LIB_BSS_CACHE:
        return _LIB_BSS_CACHE[mod_base]
    from gen_rel_module import _equ_env, _eval_merlin
    import check_purity as ckp
    size = 0
    src = f'{mod_base}.s'
    if src == 'libabss.s' or ckp._bss_only_module(src)[0]:
        text, _m = generate(os.path.join(ROOT, 'src/liba', src))
        env = _equ_env(text.split('\n'))
        for line in text.split('\n'):
            m = re.match(r'^\S*\s+ds\s+(\S+)', line.split(';')[0])
            if m:
                size += _eval_merlin(m.group(1), env)
    _LIB_BSS_CACHE[mod_base] = size
    return size


def hexstage(text, src_relpath, W):
    """Rewrite `putbin <blob>` lines into staged HEX put chains
    (stage_putbin -- the maux-src treatment; nas, like real Merlin and
    `as`, lacks the directive). Writes the hex files via W and returns
    (rewritten text, total staged hex bytes)."""
    src_dir = os.path.dirname(src_relpath)
    out, total = [], 0
    for line in text.split('\n'):
        m = PUTBIN_RE.match(line)
        if not m:
            out.append(line)
            continue
        blob = os.path.normpath(os.path.join(ROOT, src_dir, m.group(1)))
        for nm, txt in blob_to_hex_puts(blob, _blob_prefix(blob),
                                        cap=6000):
            W(f'{LRDIR}/{nm}.S', txt)
            total += len(txt)
            out.append(f' put {LRDIR}/{nm}')
    return '\n'.join(out), total


def sh_bytes(lines):
    """A maux `sh SCRIPTFILE`: high-bit ASCII, CR line ends."""
    return bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                 for c in '\r'.join(lines) + '\r')


def grow_play_image(out_img=None):
    """OUT_IMG = the play image's whole tree on a 32 MB volume. The
    800K play.po overflowed ('no free blocks') on the first roster
    staging -- ~50 util mains + their equ/body closures + objects --
    the same reason build_librelas_image.py builds its own big volume.
    Both volumes are named BASIC, so play.po is read into memory,
    unmounted, and replayed onto the fresh volume; blocks 0-1 (the
    ProDOS boot loader, not a file) are spliced across verbatim, as
    build_play_image.py itself does from its carrier. out_img defaults
    to OUT_IMG; build_full_image.py passes its imglock temp path."""
    out_img = out_img or OUT_IMG
    tree = []                          # (path, is_dir, data, type, aux)
    vol = prodos.mount(PLAY_IMG, readonly=True)
    try:
        def walk(d):
            for e in prodos.scandir(d):
                p = f'{d}/{e.name}'
                if e.is_dir():
                    tree.append((p, True, None, 0, 0))
                    walk(p)
                else:
                    tree.append((p, False, prodos.read(p), e.type,
                                 e.aux_type))
        walk(f'/mnt/{vol}')
    finally:
        prodos.unmount(vol)
    with open(PLAY_IMG, 'rb') as f:
        boot = f.read(1024)
    prodos.create(out_img, name=VOL, blocks=65535, dir_blocks=4)
    with open(out_img, 'r+b') as f:
        f.seek(0)
        f.write(boot)
    prodos.mount(out_img)
    try:
        for p, is_dir, data, ft, aux in tree:
            if is_dir:
                prodos.mkdir(p)
            else:
                prodos.write(p, data, file_type=ft, aux_type=aux,
                             overwrite=True)
    finally:
        prodos.unmount(VOL)
    print(f'[build-nas-librel] play tree ({len(tree)} entries) replayed '
          f'onto a 32 MB {out_img}')


def compose_makefile(script, plan, kplan, links, lib_pieces):
    """The staged MAKEFILE (S5 self-make): MACROS and TWO INFERENCE
    RULES over one link rule per program, in place of the longhand
    graph this used to write out (docs/MAKE-POSIX.md sec 4).

    IT USED TO NOT FIT. Written longhand -- a rule header and a recipe
    for each of 512 assemblies, the assembler's pathname repeated in
    every one of them, and each util's eight-to-eighteen liba modules
    spelled out twice, once in the link's dependencies and once in its
    command -- the file was 244 rules / 40,133 B against make.s's
    MK_MAXRULE 240 and MK_TXTSZ 28,672, and `make nas-selfmake-image`
    simply failed (measured 2026-09-18, docs/AS-PROFILE.md). Raising
    the caps was never the fix: the rule tables are X-indexed, so 255
    is the ceiling, and the roster went 46 -> 85 utils in a month.

    What replaces it:

      * `.SR:` and `RL.SR:` -- ALL 512 assemblies. The suffixes here
        carry no leading dot (`R`, not `.R`) because the objects are
        named `CATMR`, not `CATM.R`; make concatenates the pair to
        find the rule and never re-splits it, so the dot is a
        convention rather than a requirement, and not renaming 512
        generated files is worth the one sentence of explanation.
      * `A` and `L` -- the assembler and the linker, written once
        instead of 630 times.
      * `M0..Mn` -- each liba module list that more than one util
        uses, which is most of them.

    The caps are asserted here, with the numbers, so a graph that
    outgrows them fails HERE and not inside the emulator.
    Returns (text, rule count)."""
    asm = {}                       # object -> source
    for l in script:
        m = re.match(r'nas -o (\S+) (\S+)', l)
        if m:
            asm[m.group(1)] = m.group(2)

    def lookup(obj):
        return asm[obj] if obj in asm else asm[f'{LRDIR}/{obj}']

    def inferable(obj):
        """Can the two inference rules make this object? Only if its
        source is its own stem with `.S`/`RL.S` for the `R` -- which,
        since the stem carries the path, also means the two are in the
        same directory."""
        src = lookup(obj)
        return src in (obj[:-1] + '.S', obj[:-1] + 'RL.S')

    # PASS 1 builds the unit table, PASS 2 the rules. The order
    # matters: a unit that inference can make gets NO rule, and its
    # objects then have to be named as dependencies by whoever links
    # them -- otherwise nothing builds them at all. That is not
    # hypothetical. The first make-driven run of this graph
    # (2026-09-18) linked ten utils byte-identically and then died on
    # CSPLIT, because REGEX's own split pieces (REGEXP2R, REGEX2P2R)
    # were on ld's command line and in no rule's dependency list:
    # their unit had been inferred away and nobody named them.
    # A UNIT BUILDS ITS MAIN FIRST, THEN ITS PIECES, and the order is
    # load-bearing rather than tidy: `ld -l` splices a library's taken
    # members in DIRECTORY (= creation) order (src/bin/ldlib.s's own
    # header), the guest CREATES those objects as it builds them, and
    # the script route creates main-then-pieces. Build them in the
    # other order and the kernel links from the same objects in a
    # different order -- 28,921 bytes, identical length, first
    # difference at offset 15. Measured 2026-09-18, the first
    # make-driven run that got as far as the kernel.
    rules = []                     # (target, deps, [cmds])
    pending = []                   # link rules, deps not yet closed
    units = []                     # (target obj, [objs it builds])
    libs_done = set()
    for util in sorted(plan):
        objs = plan[util]['objs']
        main = f'{util}MR'
        pieces = [f'/usr/lib/LIB{util}/{p}' for p in plan[util]['pieces']]
        xpieces = [x[0] for x in plan[util].get('xpieces', [])]
        bss = list(plan[util]['bss'])
        units.append((main, [main] + pieces + xpieces + bss))
        for m_ in plan[util]['mods']:
            if m_ not in libs_done:
                libs_done.add(m_)
                units.append((m_, [m_] + list(lib_pieces.get(m_[:-1], []))))
        # EVERY object the link needs, named directly. It used to name
        # only rule TARGETS, because an object with no rule of its own
        # was refused before its unit had run; inference is exactly
        # what removes that constraint.
        deps = [main] + list(plan[util]['mods']) + bss + xpieces + pieces
        link = plan[util]['link']
        pending.append((util, deps, ['$(L)' + link[2:]]))
    for stem, k in kplan.items():
        deps = []
        for n in k['names']:
            if n in cl.KERNEL_FLAT.values():
                obj = f'{LIBKDIR}/{n}R'
                units.append((obj, [obj] + [f'{LIBKDIR}/{p}'
                                            for p in lib_pieces.get(n, [])]))
            else:
                obj = f'{n}R'
                units.append((obj, [obj] + list(k['segpieces'].get(n, []))))
            deps.append(obj)
        pending.append((k['out'], deps, ['$(L)' + k['link'][2:]]))
    mksrc = open(os.path.join(ROOT, 'src', 'bin', 'make.s')).read()
    caps = {k: int(re.search(rf'{k}\s+equ\s+(\d+)', mksrc).group(1))
            for k in ('MK_TXTSZ', 'MK_MAXRULE', 'MK_MAXDEP', 'MK_MAXARG',
                      'MK_DEPBSZ', 'MK_CMDSZ', 'MK_MAXMAC')}
    ordered, seen = [], set()
    for target, objs in units:
        if target in seen:
            continue
        seen.add(target)
        ordered.append((target, objs))
    extra = {t: [o for o in objs if o != t] for t, objs in ordered
             if all(inferable(o) for o in objs)}

    def close(deps):
        out = []
        for d in deps:
            if d not in out:
                out.append(d)
            for e in extra.get(d, []):
                if e not in out:
                    out.append(e)
        return out

    # A LINK WHOSE CLOSED LIST WILL NOT FIT KEEPS ITS UNITS' RULES.
    # Closing costs dependency-line LENGTH, and make expands the whole
    # list into one MK_DEPBSZ buffer: the play kernel's 44 modules plus
    # their split pieces came to 1,123 B against a 1,024 B buffer. So
    # the units feeding an over-long link go back to having rules of
    # their own, which is what they had before inference existed.
    budget = caps['MK_DEPBSZ'] - 64
    forced = set()
    for tgt, deps, _cmds in pending:
        if len(' '.join(close(deps))) > budget:
            forced.update(d for d in deps if extra.get(d))
    for t in forced:
        extra.pop(t, None)

    inferred = 0
    for target, objs in ordered:
        if target in extra:
            inferred += 1
            continue
        if all(inferable(o) for o in objs) and target not in forced:
            inferred += 1
            continue
        leaves, cmds = [], []
        for o in objs:
            leaves.append(lookup(o))
            cmds.append(f'$(A) -o {o} {lookup(o)}')
        rules.append((target, leaves, cmds))
    for tgt, deps, cmds in pending:
        rules.append((tgt, close(deps), cmds))

    # ---- the macros: every liba module list two or more utils share
    lists = collections.Counter(tuple(plan[u]['mods']) for u in plan)
    macros, defs = {}, []
    for lst, count in lists.most_common():
        if count < 2 or not lst or len(macros) >= MK_MACRO_BUDGET:
            continue
        name = f'M{len(macros)}'
        macros[' '.join(lst)] = f'$({name})'
        defs.append(f'{name} = ' + ' '.join(lst))

    def sub(text):
        for literal, ref in macros.items():
            if literal in text:
                return text.replace(literal, ref)
        return text

    mk = [f'A = {BINDIR}/NAS', f'L = {BINDIR}/LD'] + defs
    # The inference rules go AFTER ALL (below): maux's make takes the
    # first rule that is not a dot-suffix as its default goal, and
    # `RL.SR:` is not one, so with the rules first a bare `make` ran
    # ONE assembly (`nas -o RL.SR`) and stopped. The gates always said
    # `make -f MAKEFILE ALL`, which hides that; the release disk's
    # `cd /usr/src/maux; make` is the bare form (docs/FULLDISK.md).
    suffix_rules = ['.SUFFIXES: R .S RL.S',
                    '.SR:', '\t$(A) -o $@ $<',
                    'RL.SR:', '\t$(A) -o $@ $<']
    LINEMAX = 254
    all_targets = sorted(plan) + [k['out'] for k in kplan.values()]
    groups, cur = [], []
    for t in all_targets:
        gi = len(groups)
        if cur and len(f'ALLG{gi}: ' + ' '.join(cur + [t])) > LINEMAX:
            groups.append(cur)
            cur = [t]
        else:
            cur.append(t)
    if cur:
        groups.append(cur)
    gnames = [f'ALLG{i}' for i in range(len(groups))]
    mk.append('ALL: ' + ' '.join(gnames))
    for gn, members in zip(gnames, groups):
        mk.append(f'{gn}: ' + ' '.join(members))
    mk += suffix_rules
    expanded = {}                  # rule line -> its expanded length
    for tgt, deps, cmds in rules:
        raw = f'{tgt}: ' + sub(' '.join(deps))
        mk.append(raw)
        expanded[raw] = len(' '.join(deps))
        for cmd in cmds:
            raw = '\t' + sub(cmd)
            mk.append(raw)
            expanded[raw] = len(cmd)
    mktext = '\r'.join(mk) + '\r'
    nrules = sum(1 for l in mk if not l.startswith('\t')
                 and ':' in l.split('=')[0])
    assert len(mktext) <= caps['MK_TXTSZ'] - 2, (
        f'MAKEFILE is {len(mktext)} B against make.s MK_TXTSZ '
        f'{caps["MK_TXTSZ"]} (usable {caps["MK_TXTSZ"] - 2})')
    assert nrules <= caps['MK_MAXRULE'], (
        f'{nrules} rules against make.s MK_MAXRULE {caps["MK_MAXRULE"]}')
    assert len(defs) + 2 <= caps['MK_MAXMAC'], (
        f'{len(defs) + 2} macros against make.s MK_MAXMAC '
        f'{caps["MK_MAXMAC"]}')
    # THE BUFFERS BOUND THE EXPANSION, NOT THE LINE. A macro shrinks
    # what is written; make still builds the whole list in
    # MK_DEPBUF/MK_CMDBUF, and the play kernel's own link line is 989
    # characters expanded from 44 modules.
    worst_dep = max(expanded[l] for l in mk
                    if not l.startswith('\t') and l in expanded)
    assert worst_dep <= caps['MK_DEPBSZ'] - 2, (
        f'a dependency list expands to {worst_dep} B against make.s '
        f'MK_DEPBSZ {caps["MK_DEPBSZ"]}')
    worst_cmd = max(expanded[l] for l in mk
                    if l.startswith('\t') and l in expanded)
    assert worst_cmd <= caps['MK_CMDSZ'] - 2, (
        f'a recipe expands to {worst_cmd} B against make.s MK_CMDSZ '
        f'{caps["MK_CMDSZ"]}')
    # over the RULES, not over every line: the macro definitions and
    # the inference-rule headers are not `target: deps` lines
    worst_deps = max([len(d) for _t, d, _c in rules]
                     + [len(g) for g in groups] + [len(gnames)])
    assert worst_deps < caps['MK_MAXDEP'], (
        f'a rule carries {worst_deps} deps against MK_MAXDEP '
        f'{caps["MK_MAXDEP"]}')
    worst_argc = max(len(c.split()) for _t, _d, cs in rules for c in cs)
    assert worst_argc < caps['MK_MAXARG'], (
        f'a recipe spawns {worst_argc} argv tokens against MK_MAXARG '
        f'{caps["MK_MAXARG"]}')
    print(f'[build-nas-librel] MAKEFILE: {len(rules)} rules written, '
          f'{inferred} units inferred, {len(defs)} macros')
    return mktext, nrules


def _equ_value(name):
    """NAME's value from the one inc/*.equ line that defines it
    (`NAME equ $HEX`) -- never a literal copied here (check_kernel_
    images.py's PMLI_IBF_BASE precedent: a moving policy constant is
    read from its one real source)."""
    pat = re.compile(r'^' + re.escape(name) + r'\s+equ\s+\$([0-9A-Fa-f]+)',
                     re.M)
    for fn in sorted(os.listdir(os.path.join(ROOT, 'inc'))):
        if not fn.endswith('.equ'):
            continue
        text = open(os.path.join(ROOT, 'inc', fn),
                    encoding='latin-1').read()
        m = pat.search(text)
        if m:
            return int(m.group(1), 16)
    return None


def _kseg_org():
    """KSEG_ORG's value (docs/KSEG.md's cold segment base)."""
    return _equ_value('KSEG_ORG')


def _kseg_kmod_orgs(manifest_path, kernel_flat):
    """{KERNEL_FLAT name: org symbol} for the kernel modules this
    manifest `put`s AFTER a mid-file `org` change (docs/KSEG.md's cold
    segment, then docs/LOOP-S1.md's low segment) -- the symbol is the
    operand of the `org` in force at that `put`. nas+ld links a whole
    manifest as one contiguous $2000-based image with no automatic
    per-`org` rebasing the way merlin32 does, so the kernel link line
    needs an explicit `-s ORG` override right before the FIRST name of
    each segment (docs/LD-NATIVE.md sec 2, the same mechanism `sh`'s
    own second segment already uses). Empty for a manifest with no
    segment (`org` appears exactly once, for the manifest's own base
    address). Insertion order is file order."""
    names = {}
    norg = 0
    cur = None
    with open(manifest_path, encoding='latin-1') as fh:
        for raw in fh:
            code = raw.split(';')[0]
            m_org = re.match(r'^\s+org\s+(\S+)', code)
            if m_org:
                norg += 1
                cur = m_org.group(1)
                continue
            m_put = re.match(r'^\s+put\s+(\S+)', code)
            if m_put and norg >= 2:
                tgt = m_put.group(1)
                if '/kernel/' in tgt:
                    base = os.path.basename(tgt)[:-2]
                    if base in kernel_flat:
                        names[kernel_flat[base]] = cur
    return names


def main():
    if not os.path.exists(LD_BIN):
        print(f'error: missing {LD_BIN} (make build/ld.bin)',
              file=sys.stderr)
        return 2
    # (Re)cook nas so the image always carries the current nas.mod.
    rc = plascut.cook('NAS', [NAS_BUILD_DIR],
                      os.path.join(NAS_BUILD_DIR, 'plasma.bin'),
                      os.path.join(NAS_BUILD_DIR, 'rt.mod'),
                      NAS_CUT, verbose=False,
                      const_prefix=('NAS',),
                      immutable_native=('NAS',))  # the Makefile's cut flags
    if rc != 0:
        print('error: plascut NAS failed', file=sys.stderr)
        return 2
    blobs = {}
    for key, pth in (('NAS', NAS_CUT), ('LD', LD_BIN)):
        with open(pth, 'rb') as f:
            blobs[key] = f.read()
    if blobs['NAS'][0] != 0x4C or blobs['NAS'][9:11] != b'CK' \
            or blobs['NAS'][11] != 1:
        print('error: nas.cut is not a cooked image', file=sys.stderr)
        return 2
    heap = BRK_LIM - (COOK_BASE + len(blobs['NAS']))
    print(f'[build-nas-librel] cooked nas {len(blobs["NAS"])} B -> '
          f'heap {heap} B')
    # PLASM-FIX: the cooked nas gained ~4 KB of heap when rt stopped
    # carrying a static symbol table. The piece budgets below come from a
    # MODEL (memory_model), validated while the heap was 11,647 B. Fed the
    # larger real heap it picked bigger pieces for the three biggest utils
    # (MAKE, MORE, NULIB2: modelled 13.5-14.8 KB against a 14.8 KB limit)
    # and nas ran out at run time -- "linked binary never written" in
    # check-nas-librel. So the model UNDER-COUNTS those three by at least
    # 1 KB although it calls itself conservative (docs/PLASM-FIX-NOTES.md
    # sec 9: its own task, with those three as fixtures). Until it is
    # fixed the plan is made against the heap it was validated for, so the
    # composed world is identical to the proven one and the real nas has
    # room to spare. The real heap may never be SMALLER than the validated
    # one: that would void the validation, so it is refused here.
    real_heap = heap
    if real_heap < VALIDATED_HEAP:
        print(f'error: the cooked nas heap is {real_heap} B, below the '
              f'{VALIDATED_HEAP} B the budget model was validated against',
              file=sys.stderr)
        return 2
    if heap > VALIDATED_HEAP:
        print(f'[build-nas-librel] planning against {VALIDATED_HEAP} B '
              f'(VALIDATED_HEAP), real heap {real_heap} B')
        heap = VALIDATED_HEAP

    # ---- the forms -----------------------------------------------
    # (kind, staged base, generated text, ROOT-relative source path)
    kernel_flat = set(cl.KERNEL_FLAT.values())
    forms = []
    for mod, base in cl.modules():
        if base in kernel_flat:
            continue
        text, _m = generate(mod)
        forms.append(('lib', base, text, os.path.relpath(mod, ROOT)))
    # THE KERNEL (S5, 2026-09-14): every src/kernel module as a library
    # form into /LIB/LIBK in libk order -- ld's `-l k` takes members
    # at their DIRECTORY (creation) position, and the harvest creates
    # objects in script order, so this order IS every kernel link's
    # module order; a module cut into pieces has them created right
    # after it. All 40 (nas has no oracle gap: check_librel.modules()
    # drops the five real Merlin cannot assemble, so this glob does
    # not go through it).
    kmains = cl.kernel_main_segments()
    korder = cl.libk_order(kmains)
    ksrc = {}
    for mod in sorted(glob.glob(os.path.join(ROOT, 'src/kernel/*.s'))):
        stem = os.path.basename(mod)[:-2]
        if stem in cl.KERNEL_FLAT:
            ksrc[cl.KERNEL_FLAT[stem]] = mod
    for base in korder:
        text, _m = generate(ksrc[base])
        forms.append(('klib', base, text, os.path.relpath(ksrc[base], ROOT)))
    # programs whose REL main needs the monolithic listing's literals
    # (built `-v1` by the Makefile; see generate_split_main)
    LISTINGS = {'PLASMA': 'build/plasma.bin_Output.txt',
                'PROSHIM': 'build/proshim.bin_Output.txt',
                'PROSHIMPG': 'build/proshimpg.bin_Output.txt'}
    plan, skipped = {}, {}
    util_src = {}
    for mod in sorted(glob.glob(os.path.join(ROOT, 'src/bin/*.s'))):
        base = os.path.basename(mod)[:-2].upper()
        if base in SWEEP_EXCLUDE:
            continue
        if not os.path.exists(os.path.join(ROOT, 'build',
                                           f'{base.lower()}.bin')):
            continue
        if base in PINNED_SKIPS:
            skipped[base] = PINNED_SKIPS[base]
            continue
        rel = os.path.relpath(mod, ROOT)
        # An overlay BLOB, not a program: proshimcr.s (`org $E000`) and
        # proshimpg.s (`org $BF00`) are putbin'd into proshim and land
        # wherever their literal org says; `ld -z` links at LOAD_BASE,
        # so the byte compare against build/<base>.bin is meaningless
        # (first roster run: proshimcr differed at offset 2, the org's
        # high byte, $E0 vs $08). Anything with a literal org is skipped
        # by that fact, not by name.
        # ... and since 2026-09-13 they LINK WITH `-a <org>` instead
        # (ld's link-address flag, which also stamps the aux type),
        # the same way build_librelas_image stages them.
        # A unit with MORE THAN ONE `org` has more than one BASE, and
        # `ld`'s $F8 REL format has exactly one: every relocation in a
        # linked image is against the single image base `-a` stamps.
        # sh.s grew a second one on 2026-09-16 (docs/SH-SUBSET.md
        # ruling 7.6 -- `org PRC_LC_COMMON`, a code segment that RUNS
        # from $E000 in the process language card while its bytes ride
        # in the flat file above the low image, plus a third `org`
        # winding the PC back past that copy for the bss arena).
        # MEASURED, not predicted: with sh staged, the sweep came back
        # `SH: byte mismatch at offset 344: nas+ld=$3e merlin32=$2f`
        # -- the low byte of `jsr CHCK_BLTN_GOP`, which merlin32 put
        # at $E22F and nas+ld put at $603E, i.e. laid flat at the
        # continuing low address as though the second `org` were not
        # there. The LENGTHS agree, so this is purely a base question.
        # Skipped by that fact, not by name, exactly like the literal-
        # org rule above. What it would take to unskip is written down
        # in docs/SH-SUBSET.md ruling 7.6's self-hosting paragraph:
        # nas needs `org` to move the EMISSION address without moving
        # the file offset (two counters where it has one), and ld needs
        # a PER-CHUNK base in the REL format rather than one per image.
        src = open(mod).read()
        orgs = re.findall(r'^[ \t]+org[ \t]+(\S+)', src, re.M)
        morg = re.search(r'^[ \t]+org[ \t]+(\S+)', src, re.M)
        aflag = ''
        if morg and morg.group(1).upper() != 'LOAD_BASE':
            assert re.match(r'^\$[0-9A-Fa-f]{1,4}$', morg.group(1)), \
                f'{base}: org {morg.group(1)!r} is not LOAD_BASE or hex'
            aflag = f'-a {morg.group(1)[1:].upper()} '
        try:
            if base in LISTINGS:
                # a PC equate, `ds EXPR-*` pad or `dum *` in the source
                # (plasma, proshim, proshimpg) becomes the monolithic
                # listing's literal -- generate_split_main with no cuts
                # is generate_main plus that rewrite (body_lits carries
                # the put files' share, applied when they are inlined)
                pieces0, bss_texts, meta = generate_split_main(
                    mod, os.path.join(ROOT, LISTINGS[base]), [])
                main_text = pieces0[0][1]
            else:
                main_text, bss_texts, meta = generate_main(mod)
                meta['body_lits'] = {}
        except SystemExit as e:
            skipped[base] = f'generate: {e}'
            continue
        meta['aflag'] = aflag
        # A UNIT WITH MORE THAN ONE `org` HAS A SEGMENT RUN -- code
        # that RUNS at a second base while its bytes stay contiguous
        # in the flat image. This used to be the skip reason ("ld's
        # $F8 REL format has ONE image base", measured on SH as a
        # mismatch at offset 344, $E22F vs $603E). It is not a format
        # limit: every address in a REL module is $8000-based and
        # every reference to it is a fixup, so a module's base was
        # always a LINKER policy -- ld's PASS1 simply had one cursor.
        # It has two since 2026-09-17 (`-s adr`, src/bin/ldsym.s), the
        # marker path carries the base (generate_main's `* @SEGORG`),
        # and nothing in the object format changed.
        meta['segrun'] = len(orgs) > 1
        if isinstance(main_text, list):
            main_text = '\n'.join(main_text)
        bss_texts = ['\n'.join(bt) if isinstance(bt, list) else bt
                     for bt in (bss_texts or [])]
        # ld's BUILD WINDOW ($5600-$BD00, 26,368 B -- src/bin/ld.s) holds
        # the whole image BEFORE -z truncates the bss: a util whose bss
        # arena alone is bigger cannot be linked by ld at all (bpatch:
        # 3.4 KB of code, six bss chunks ~35 KB -- first piece run,
        # "linked binary never written"). generate_main chunks bss at
        # 7,000 B, so chunks-1 of them are full.
        # (The old ld built the whole image in a $5600-$BD00 area
        # before -z truncated it, and units whose code + bss modules
        # exceeded 26,368 B -- sh, ex, vi, bpatch -- were skipped here.
        # ld streams now (src/bin/ldstream.s, 2026-09-13): no image
        # size limit at all, so nothing is predicted against it.)
        util_src[base] = (main_text, bss_texts, meta, rel)
        plan[base] = {'mods': [m.upper() + 'R' for m in meta['modules']],
                      'bss': [f'{base}B' if ci == 0 else f'{base}B{ci + 1}'
                              for ci in range(len(bss_texts))],
                      'aflag': aflag}
        plan[base]['bss'] = [b + 'R' for b in plan[base]['bss']]

    # Put targets split two ways: EQU files (every one on gen_rel_
    # module's canonical EQU_ORDER list) are NOT staged whole -- each
    # form gets ONE merged, need-filtered equ file (equ_subset, below);
    # same-dir BODY modules are staged whole under flat names.
    equ_paths = set(os.path.relpath(os.path.join(ROOT, e), ROOT)
                    for e in EQU_ORDER)
    body_targets = []
    for _k, _b, text, srel in forms:
        for t in collect_put_targets(text, srel):
            if t not in equ_paths and t not in body_targets:
                body_targets.append(t)
    for _base, (mtext, btexts, _meta, rel) in util_src.items():
        for text in [mtext] + btexts:
            for t in collect_put_targets(text, rel):
                if t not in equ_paths and t not in body_targets:
                    body_targets.append(t)
    names = bmsi.assign_flat_names(body_targets)
    equ_items = {}                        # equ path -> parsed items
    body_staged = {}                      # flat -> staged text

    grow_play_image()
    prodos.mount(OUT_IMG)
    try:
        dirs = [BINDIR]
        if FULL:
            dirs.append('/usr/src')         # parent of /usr/src/maux
        dirs += [LRDIR, LNKDIR]
        for d in dirs:
            try:
                prodos.mkdir(d)
            except FileExistsError:
                pass

        def W(path, text):
            prodos.write(path, convert.text_from_host(
                text.encode('latin-1', 'replace')),
                file_type=0x04, aux_type=0x0000, overwrite=True)

        prodos.write(f'{BINDIR}/NAS', blobs['NAS'], file_type=0x06,
                     aux_type=0x0800, overwrite=True)
        prodos.write(f'{BINDIR}/LD', blobs['LD'], file_type=0x06,
                     aux_type=0x0800, overwrite=True)
        for tgt, flat in names.items():
            with open(os.path.join(ROOT, tgt), errors='replace') as f:
                body_staged[flat] = stage_text(f.read(), tgt)
            W(f'{LRDIR}/{flat}.S', body_staged[flat])

        def prepare(kind, base, text, srel):
            """One form -> (leaf, staged text, merged equ text, est,
            detail). est is the memory model's prediction of nas's
            heap use for it; detail the string to print if skipped."""
            src_dir = os.path.dirname(srel)
            equ_used = []                 # equ paths, put order
            out = []
            first_equ_at = None
            for line in text.split('\n'):
                m = PUT_RE.match(line)
                if not m:
                    out.append(line)
                    continue
                tgt = os.path.normpath(os.path.join(src_dir, m.group(4)))
                if tgt in equ_paths:
                    if first_equ_at is None:
                        first_equ_at = len(out)
                        out.append(None)  # the merged put's slot
                    if tgt not in equ_items:
                        with open(os.path.join(ROOT, tgt),
                                  errors='replace') as f:
                            equ_items[tgt] = parse_equ_items(
                                stage_text(f.read(), tgt))
                    equ_used.append(tgt)
                elif tgt in names:
                    out.append(f' put {LRDIR}/{names[tgt]}')
                else:
                    raise AssertionError(f'{srel}: put {tgt!r} unknown')
            rewritten, hexbytes = hexstage('\n'.join(
                l for l in out if l is not None), srel, W)
            staged = stage_text(rewritten, base)
            bodies = ''.join(body_staged[ln.split('/')[-1]]
                             for ln in staged.split('\n')
                             if PUT_RE.match(ln)
                             and ln.split('/')[-1] in body_staged)
            # The subset is closed over the UNIT's whole equ put list
            # (the source at srel), in its put order, not only over the
            # equ files this form's own text happens to put: a bss
            # piece's text puts just the files its cells name directly
            # (xargs's INPUT_BUF ds ARG_MAX -> mm.procbnk2.equ),
            # and ARG_MAX is LOAD_BASE-PRC_ARGV_STR with LOAD_BASE in
            # mm.procbank.equ -- the piece's Q file then carried a
            # definition leaning on a name it never defined, and nas
            # died on the screen with nothing in NASLOG (XARGSBR, the
            # first bss piece to size a cell by a chained equate,
            # 2026-09-15). Unit order keeps every copied definition
            # AFTER what it references, so no equ forward reference
            # is manufactured (learning:01M05519PC55WGJNE4PY5HX4TH).
            unit_equs = []
            with open(os.path.join(ROOT, srel), errors='replace') as f:
                for uline in f.read().split('\n'):
                    um = PUT_RE.match(uline)
                    if not um:
                        continue
                    utgt = os.path.normpath(os.path.join(src_dir,
                                                         um.group(4)))
                    if utgt in equ_paths and utgt not in unit_equs:
                        unit_equs.append(utgt)
            for e in equ_used:
                if e not in unit_equs:
                    unit_equs.append(e)
            for e in unit_equs:
                if e not in equ_items:
                    with open(os.path.join(ROOT, e), errors='replace') as f:
                        equ_items[e] = parse_equ_items(
                            stage_text(f.read(), e))
            merged = equ_subset(staged + bodies,
                                [equ_items[e] for e in unit_equs])
            # ... and only when there IS a subset: the Q file is
            # written iff `merged` is non-empty, and a piece whose
            # lines need no equate (proshim's strings/blob piece)
            # would otherwise put a file that does not exist --
            # "nas: PUT/USE: cannot open a spliced file" (2026-09-14)
            if first_equ_at is not None and merged:
                lines = staged.split('\n')
                # re-find the slot: stage_text dropped nothing but
                # blank/comment lines, so the first surviving line at
                # or after the put's position is where the merged put
                # goes -- put it FIRST after the head directives, i.e.
                # right where the first equ put was
                lines.insert(_equ_slot(lines), f' put {LRDIR}/{base}Q')
                staged = '\n'.join(lines)
            est = memory_model(merged + '\n' + staged + '\n' + bodies) + hexbytes
            leaf = (f'{base}RL.S' if kind in ('lib', 'libpiece', 'klib',
                                              'klibpiece') else f'{base}.S')
            detail = (f'{kind} {len(staged)} B + equ subset '
                      f'{len(merged)} B + body/hex puts '
                      f'{len(bodies) + hexbytes} B -> modelled '
                      f'{est} B against nas heap {heap} B')
            return leaf, staged, merged, est, detail

        script = [f'cd {LRDIR}']
        links = []
        nstaged = 0
        BUDGETS = (1.0, 0.92, 0.85, 0.78, 0.7, 0.6, 0.5)
        # liba modules: the same piece generator (regex2.s alone models
        # 17.8 KB against a 15 KB heap; as two consecutive REL pieces
        # it is 11.5 KB at most). A split module's extra pieces follow
        # it in every util's link list (lib_pieces), spelled out --
        # they are few, and the liba order is per-util put order, which
        # a `-l` directory could not reproduce.
        lib_pieces = {}
        try:
            prodos.mkdir(f'/usr/lib')
        except FileExistsError:
            pass
        prodos.mkdir(f'/usr/lib/LIBK')
        if LIBKDIR != f'/usr/lib/LIBK':
            # SELFMAKE only (LIBKDIR module docstring): objects land
            # HERE, a shorter directory the staged MAKEFILE's own
            # dependency list references; SOURCE stays in LIB/LIBK
            # (the inference-rule naming below still matches on it).
            prodos.mkdir(LIBKDIR)
        for kind, base, text, srel in forms:
            if base in skipped:
                continue
            done = False
            last_detail = ''
            for factor in BUDGETS:
                budget = int((heap - HEAP_MARGIN - NAS_SPLIT_RESERVE) * factor)
                pieces, info = generate_pieces(srel, text, [], budget,
                                               is_lib=True)
                if pieces is None:
                    skipped[base] = f'{base}: {info}'
                    break
                names_ = [base] + [f'{base}P{k + 1}'
                                   for k in range(1, len(pieces))]
                unit_forms = [(kind if k == 0 else kind + 'piece', n, t, srel)
                              for k, (n, t) in enumerate(zip(names_, pieces))]
                prepared = [prepare(*uf) for uf in unit_forms]
                over = [(uf[1], pr) for uf, pr in zip(unit_forms, prepared)
                        if pr[3] > heap - HEAP_MARGIN]
                if over:
                    last_detail = '; '.join(f'{b_}: {pr[4]}'
                                            for b_, pr in over)
                    continue
                for uf, (leaf, staged, merged, est, _d) in zip(unit_forms,
                                                                prepared):
                    # A SOURCE LIVES IN ITS OBJECT'S DIRECTORY. An
                    # inference rule matches on the stem, and the stem
                    # carries the path, so `/LIB/LIBK/KTTYR` can only
                    # be inferred from `/LIB/LIBK/KTTYRL.S` -- not from
                    # the same file sitting in /LR. Moving it is what
                    # lets ONE `.SR:` rule stand in for all 512
                    # assemblies (docs/MAKE-POSIX.md sec 4); it also
                    # splits a directory whose walk IS this build's
                    # turnaround (docs/AS-PROFILE.md). Every `put` in a
                    # staged source is already absolute, so nothing
                    # else cares where the file sits.
                    # the NAMES have to match the way an inference
                    # rule matches: object and source spelled the same
                    # way, bare beside bare (the script CDs to /LR and
                    # the MAKEFILE runs there too) or path beside path
                    if kind == 'klib':
                        srcp = f'/usr/lib/LIBK/{leaf}'
                        objp = f'{LIBKDIR}/{uf[1]}R'
                    else:
                        srcp = leaf
                        objp = f'{uf[1]}R'
                    W(f'{LRDIR}/{leaf}' if srcp is leaf else srcp, staged)
                    if merged:
                        W(f'{LRDIR}/{uf[1]}Q.S', merged)
                    script.append(f'nas -o {objp} {srcp} >> {LOG} 2>&1')
                    LIBA_NAS.append((objp, srcp, uf[0]))
                    nstaged += 1
                lib_pieces[base] = [n + 'R' for n in names_[1:]]
                done = True
                break
            if not done and base not in skipped:
                skipped[base] = (f'{base}: over the heap at every budget '
                                 f'factor; last: {last_detail}')
        # utils: the body-put split (generate_pieces) at the full
        # budget, re-modelled after emission (EXT/ENT lines and the
        # equ subset are only known then); a piece still over the
        # heap sends the whole unit back through at a smaller budget.
        for base, (mtext, btexts, meta, rel) in util_src.items():
            if base in skipped:
                continue
            # The link line's word count is no longer a budget (see
            # ARGFILE_ABOVE): a long line rides an argument file, so
            # the bss chunking below answers the nas heap only.
            # generate_main is re-run inside the walk below and returns
            # a FRESH meta, so the flags this loop set on the first one
            # are held here rather than read back off it.
            # ... and, the other way, a bss chunk whose OWN model is over
            # the heap (the object buffer is the chunk; the cell tables
            # are charged on top) gets chunked smaller: sh's 6,919 B
            # chunk of 153 cells needs ~18 KB.
            def chunk_over(bt):
                for ci, t in enumerate(bt):
                    _l, _s, merged, est, _d = prepare(
                        'bss', f'{base}B' if ci == 0 else f'{base}B{ci + 1}',
                        t, rel)
                    if est > heap - HEAP_MARGIN:
                        return True
                return False
            chunk = 7000
            while chunk_over(btexts) and 3000 < chunk <= 14000:
                chunk -= 1000
                _mt, btexts, meta = generate_main(os.path.join(ROOT, rel),
                                                  bss_chunk=chunk)
                btexts = ['\n'.join(bt) if isinstance(bt, list) else bt
                          for bt in (btexts or [])]
            plan[base]['bss'] = [(f'{base}B' if ci == 0 else
                                  f'{base}B{ci + 1}') + 'R'
                                 for ci in range(len(btexts))]
            bss_cells = meta.get('bss_cells') or []
            done = False
            last_detail = ''
            for factor in BUDGETS:
                budget = int((heap - HEAP_MARGIN - NAS_SPLIT_RESERVE) * factor)
                pieces, info = generate_pieces(rel, mtext, bss_cells, budget,
                                               body_lits=meta.get('body_lits'))
                if pieces is None:
                    skipped[base] = f'{base}: {info}'
                    break
                names_ = [f'{base}M'] + [f'{base}P{k + 1}'
                                         for k in range(1, len(pieces))]
                # a piece from a later SEGMENT (body code the manifest
                # put AFTER some liba modules -- sh.s's segment) is
                # named EXPLICITLY in the link line right after the
                # liba module it follows ('xpiece'); the -l library
                # holds segment 0 only, since a library splices at ONE
                # position. Explicit modules are all seeded before any
                # library is scanned, so a segment-0 piece wanted only
                # by an xpiece is still taken.
                segs = info['segs']
                seg_after = info['seg_after']
                if segs[0] != 0:
                    skipped[base] = f'{base}: main text starts after a liba put'
                    break
                sbase = info['sbase']
                xpieces = [(n + 'R', seg_after[sg], sb)
                           for n, sg, sb in zip(names_, segs, sbase)
                           if sg > 0]
                # ld carries TWO segment runs (SEGCUR and SEGCUR2, the
                # kernel's $D400 and $1300 blocks and sh's $E000 and
                # $D000), so a manifest with a third is refused here
                # rather than mis-linked there. A run is a maximal
                # stretch of pieces at one base; the same base twice
                # is two runs.
                runs, cur = 0, None
                for _n, _a, sb in xpieces:
                    if sb is not None and sb != cur:
                        runs += 1
                    cur = sb
                if runs > 2:
                    skipped[base] = (f'{base}: {runs} segment runs; '
                                     f'ld -s carries two')
                    break
                # a segment piece must be an EXPLICIT operand: the -l
                # library splices at one position and cannot carry the
                # -s brackets
                flat = [n for n, sg, sb in zip(names_, segs, sbase)
                        if sb is not None and sg == 0]
                if flat:
                    skipped[base] = (f'{base}: segment-run piece(s) '
                                     f'{flat} fell in the -l library')
                    break
                unit_forms = [('main' if k == 0 else
                               ('piece' if segs[k] == 0 else 'xpiece'),
                               n, t, rel)
                              for k, (n, t) in enumerate(zip(names_, pieces))]
                for ci, bt in enumerate(btexts):
                    suf = 'B' if ci == 0 else f'B{ci + 1}'
                    unit_forms.append(('bss', f'{base}{suf}', bt, rel))
                prepared = [prepare(*uf) for uf in unit_forms]
                over = [(uf[1], pr) for uf, pr in zip(unit_forms, prepared)
                        if pr[3] > heap - HEAP_MARGIN]
                if over:
                    last_detail = '; '.join(f'{b}: {pr[4]}' for b, pr in over)
                    if os.environ.get('NAS_PLAN_VERBOSE') == base:
                        print(f'[plan] {base} factor {factor}: '
                              f'{len(prepared)} forms, over the heap: '
                              + ', '.join(f'{b} {pr[3]}'
                                          for b, pr in over))
                    continue
                # pieces beyond the first become a per-util LIBRARY
                # directory, /usr/lib/LIB<U> (ld's -l: a fixpoint over
                # a directory's REL members, spliced at the flag's
                # position in CREATION order -- src/bin/ldlib.s), so the
                # link line stays inside sh's 254-char LINEMAX and its
                # 31-token argv (MAXARGV): vi's 29 pieces + 18 liba
                # modules + 5 bss would be 388 chars / 53 tokens spelled
                # out. Creation order = the script's nas order = piece
                # order, and every piece beyond the first exports a
                # label some other piece references (checked when the
                # pieces were generated), so the fixpoint takes them all.
                if any(uf[0] == 'piece' for uf in unit_forms):
                    try:
                        prodos.mkdir(f'/usr/lib')
                    except FileExistsError:
                        pass
                    prodos.mkdir(f'/usr/lib/LIB{base}')
                for uf, (leaf, staged, merged, est, _d) in zip(unit_forms,
                                                                prepared):
                    # same rule as the klib loop above: the source goes
                    # where the object goes, so one inference rule
                    # covers it
                    if uf[0] == 'piece':
                        srcp = f'/usr/lib/LIB{base}/{leaf}'
                        obj = f'/usr/lib/LIB{base}/{uf[1]}R'
                    else:
                        srcp = leaf
                        obj = f'{uf[1]}R'
                    W(f'{LRDIR}/{leaf}' if srcp is leaf else srcp, staged)
                    if merged:
                        W(f'{LRDIR}/{uf[1]}Q.S', merged)
                    script.append(f'nas -o {obj} {srcp} >> {LOG} 2>&1')
                    nstaged += 1
                plan[base]['pieces'] = [uf[1] + 'R' for uf in unit_forms
                                        if uf[0] == 'piece']
                plan[base]['xpieces'] = xpieces
                plan[base]['modelled_bytes'] = max(pr[3] for pr in prepared)
                if os.environ.get('NAS_PLAN_VERBOSE') == base:
                    print(f'[plan] {base} factor {factor}: '
                          f'{len(prepared)} forms, modelled '
                          + ', '.join(f'{uf[1]} {pr[3]}' for uf, pr in
                                      zip(unit_forms, prepared)))
                plan[base]['budget_factor'] = factor
                done = True
                break
            if not done and base not in skipped:
                skipped[base] = (f'{base}: over the heap at every budget '
                                 f'factor {BUDGETS}; last: {last_detail}')
        for util in list(plan):
            if util in skipped:
                plan.pop(util)
                continue
            mods = []
            inrun = False
            curbase = None
            for m in plan[util]['mods']:
                # close an open segment run BEFORE the next liba
                # module: sh's LIBABSS is put after the wind-back
                # `org` and must be based at the flat address the run
                # did not disturb. Closing only at the end of the
                # whole list left `-s0` behind LIBABSSR, which would
                # have based liba's bss arena inside the segment.
                if inrun:
                    mods.append('-s0')
                    inrun = False
                curbase = None
                mods.append(m)
                mods.extend(lib_pieces.get(m[:-1], []))
                # body code the manifest put right after this liba
                # module goes here, spelled out (see 'xpiece' above)
                # ... bracketed by ld's `-s` when it is a SEGMENT-RUN
                # piece: based at the run's address while the file
                # offset keeps running (docs/SH-SUBSET.md 7.6). `-s 0`
                # closes the run before the bss modules, which must be
                # based at the flat address the run did not disturb.
                for xp, after, sb in plan[util].get('xpieces', []):
                    if after.upper() != m[:-1]:
                        continue
                    if inrun and sb != curbase:
                        mods.append('-s0')      # a run ends, or the
                        inrun = False           # next one is elsewhere
                    if sb is not None and not inrun:
                        mods.append(f'-s{sb:04X}')
                        inrun = True
                    curbase = sb
                    mods.append(xp)
            if inrun:
                mods.append('-s0')
                inrun = False
            objs = ([f'{util}MR']
                    + (['-l', util.lower()] if plan[util].get('pieces')
                       else [])
                    + mods + plan[util]['bss'])
            missing = [m for m in plan[util]['mods']
                       if m[:-1] in skipped]
            if missing:
                skipped[util] = (f'links a skipped liba module: '
                                 f'{missing}')
                plan.pop(util)
                continue
            # no `>> NASLOG` on a link line: ld is silent on success and
            # reports on stderr, so the redirect captured nothing and
            # cost two of sh's 31 argv tokens -- vi's streamed link
            # (main, -l vi, 18 liba modules, 5 bss chunks) needs 30.
            link = (f'ld -z {plan[util].get("aflag", "")}-o {util} '
                    + ' '.join(objs))
            if len(link.split()) > ARGFILE_ABOVE:
                # an argument file (ARGFILE_ABOVE): the words in ld's
                # own argv order, one line, run as `ld @FILE`
                words = link.split()[1:]
                body = ' '.join(words)
                assert len(body) <= ARGF_BYTES, \
                    f'{util}: argument file {len(body)} B exceeds ld ' \
                    f'ARGFLIM-1 ({ARGF_BYTES})'
                assert len(words) < ARGF_WORDS, \
                    f'{util}: {len(words)} words exceeds ld ARGFMAXW'
                W(f'{LNKDIR}/{util}', body)
                link = f'ld @{LNKDIR}/{util}'
            assert len(link) <= 254, \
                f'{util}: link line {len(link)} exceeds sh LINEMAX'
            assert len(link.split()) <= 31, \
                f'{util}: link line has {len(link.split())} argv tokens ' \
                f'against sh MAXARGV 32'
            links.append(link)
            plan[util]['link'] = link
            plan[util]['objs'] = objs
        # THE KERNEL LINKS (S5): each KERNEL_MAINS manifest's generated
        # segments (check_librel.kernel_main_segments -- the same texts
        # the `as` route assembles) staged like util mains, cut when
        # over the heap, and linked with the libk plan: the longest
        # kernel run rides `-l k`, everything else is an explicit
        # operand (a kernel name outside the run as its LIBK path), a
        # cut module's or segment's pieces spelled right after it.
        # No KLINK_SKIP: the streaming ld has no build area.
        kplan = {}
        for man, segs, kmeta in kmains:
            stem = os.path.basename(man)[:-2]
            man_rel = os.path.relpath(man, ROOT)
            seg_orgs = _kseg_kmod_orgs(man, cl.KERNEL_FLAT)
            segpieces = {}
            bad = None
            for name, text in segs:
                done = False
                last_detail = ''
                for factor in BUDGETS:
                    budget = int((heap - HEAP_MARGIN - NAS_SPLIT_RESERVE) * factor)
                    pieces, info = generate_pieces(man_rel, text, [], budget)
                    if pieces is None:
                        bad = f'{name}: {info}'
                        break
                    names_ = [name] + [f'{name}P{k + 1}'
                                       for k in range(1, len(pieces))]
                    unit_forms = [('kseg' if k == 0 else 'ksegpiece',
                                   n, t, man_rel)
                                  for k, (n, t) in enumerate(zip(names_,
                                                                 pieces))]
                    prepared = [prepare(*uf) for uf in unit_forms]
                    over = [(uf[1], pr) for uf, pr in zip(unit_forms,
                                                          prepared)
                            if pr[3] > heap - HEAP_MARGIN]
                    if over:
                        last_detail = '; '.join(f'{b_}: {pr[4]}'
                                                for b_, pr in over)
                        continue
                    for uf, (leaf, staged, merged, est, _d) in zip(
                            unit_forms, prepared):
                        W(f'{LRDIR}/{leaf}', staged)
                        if merged:
                            W(f'{LRDIR}/{uf[1]}Q.S', merged)
                        script.append(f'nas -o {uf[1]}R {leaf} >> {LOG} 2>&1')
                        nstaged += 1
                    segpieces[name] = [n + 'R' for n in names_[1:]]
                    done = True
                    break
                if bad:
                    break
                if not done:
                    bad = (f'{name}: over the heap at every budget '
                           f'factor; last: {last_detail}')
                    break
            if bad:
                skipped[kmeta['out']] = f'kernel {stem}: {bad}'
                continue
            ops, _members = cl.libk_link_plan(kmeta)
            has_kmod = any(op[0] == 'kmod' for op in ops)
            parts = []
            cur_seg = None
            for op in ops:
                # docs/KSEG.md's cold segment: the FIRST name this
                # manifest puts after its own mid-file `org` change
                # gets an explicit `-s KSEG_ORG` override right before
                # it (docs/LD-NATIVE.md sec 2, the same mechanism
                # `sh`'s own second segment uses) -- ld bases every
                # module named AFTER `-s` at that address while the
                # FILE OFFSET keeps running, so the output stays one
                # contiguous blob (flat part + segment back to back,
                # exactly as merlin32 emits it, before split_kseg.py
                # ever cuts it) with the segment's own fixups resolved
                # against its REAL $D400-based addresses.
                if (op[0] != 'lib' and op[1] in seg_orgs
                        and seg_orgs[op[1]] != cur_seg):
                    seg_val = _equ_value(seg_orgs[op[1]])
                    assert seg_val is not None, \
                        f'{seg_orgs[op[1]]} not found in inc/*.equ'
                    parts.append(f'-s{seg_val:04X}')
                    cur_seg = seg_orgs[op[1]]
                if op[0] == 'lib':
                    parts.append('-l k')
                elif op[0] == 'kmod':
                    # 2026-09-25 (docs/LD-NATIVE.md sec 2b, NOTES-BYE.md
                    # gap 4): bare names, resolved by ld's own -L search
                    # (below) against LIBK's directory, not a fully-
                    # qualified path per module -- /usr/lib/LIBK/
                    # repeated once per module was most of a kernel
                    # link line's own length (playtest: 16 modules x
                    # 16 characters = 256 of 464). Same FILE either
                    # way (constraint 1: this changes where a module
                    # is found, never what is linked), just found via
                    # -L's own composition (COMPOSEDIR, ldscan.s)
                    # instead of a literal path this generator spelled
                    # out itself.
                    parts.append(f'{op[1]}R')
                    parts.extend(lib_pieces.get(op[1], []))
                else:
                    parts.append(f'{op[1]}R')
                    parts.extend(segpieces.get(op[1], []))
            tflag = (f'-t {kmeta["type"]:X} ' if kmeta['type'] != 0x06
                     else '')
            # attached form (-L/path, not -L /path): one token, not
            # two -- ld.s's own -s precedent for the identical reason,
            # sh's MAXARGV=32 (this is what took playtest's own line
            # from 32 tokens to 31).
            # `-l k` finds `<-L>/LIBK`: when LIBKDIR is not under ld's
            # built-in /usr/lib, its PARENT is named as a -L too (first,
            # so a bare kmod name that misses there falls through to
            # the -L LIBKDIR below it). Either flag alone is the KFIX4
            # defect: -L LIBKDIR resolves the bare names, only the
            # parent makes the `-l k` library findable.
            lflag = ''
            if (any(op[0] == 'lib' for op in ops)
                    and os.path.dirname(LIBKDIR) != '/usr/lib'):
                lflag += f'-L{os.path.dirname(LIBKDIR)} '
            if has_kmod:
                lflag += f'-L{LIBKDIR} '
            link = (f'ld {tflag}{lflag}-a {kmeta["base"]:X} '
                    f'-o {kmeta["out"]} ' + ' '.join(parts))
            assert len(link) <= 254, \
                f'{stem}: kernel link line {len(link)} exceeds sh LINEMAX'
            assert len(link.split()) <= 31, \
                f'{stem}: kernel link line has {len(link.split())} tokens'
            links.append(link)
            kplan[stem] = {
                'out': kmeta['out'],
                'ref': os.path.relpath(os.path.join(ROOT, kmeta['ref']),
                                       ROOT),
                'base': kmeta['base'], 'type': kmeta['type'],
                'link': link, 'names': kmeta['link'],
                'segpieces': segpieces}
        if SELFMAKE:
            # the ruled self-make scope (docs/S9-PLAN.md): the utils and
            # MAUXPLAY.SYSTEM, every rule reachable from ALL and nothing
            # else (an unreachable rule only costs MAKEFILE text)
            kplan = {k: v for k, v in kplan.items() if k == 'playtest'}
            mktext, nrules = compose_makefile(script, plan, kplan, links,
                                              lib_pieces)
            prodos.write(f'{LRDIR}/MAKEFILE',
                         bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                               for c in mktext),
                         file_type=0x04, aux_type=0x0000, overwrite=True)
            print(f'[build-nas-librel] MAKEFILE: {nrules} rules, '
                  f'{len(mktext)} B')
            script = [script[0],
                      f'make -f {LRDIR}/MAKEFILE ALL >> {LOG} 2>&1',
                      f'make -n -f {LRDIR}/MAKEFILE ALL > {LRDIR}/MK2OUT',
                      'echo SWEEPDONE']
        else:
            script.extend(links)
            script.append('echo SWEEPDONE')
        # SHARDS (2026-09-13): the nas lines are independent and one
        # emulator is one core, so they are dealt round-robin over
        # NAS_LIBREL_SHARDS image copies (default 6) that the checker
        # boots IN PARALLEL; the objects are harvested back into THIS
        # image in script order (a -l library splices in creation
        # order) and this image runs only the links. =1 disables.
        nshards = 1 if SELFMAKE else int(os.environ.get('NAS_LIBREL_SHARDS', '6'))
        nas_lines = [l for l in script if l.startswith('nas ')]
        main_script = script if nshards <= 1 else \
            [script[0]] + links + ['echo SWEEPDONE']
        # sh's script reader takes the KEYBOARD's byte convention --
        # high-bit ASCII, CR line ends (build_sh_image.SCRIPT_BYTES) --
        # not the low-ASCII TXT form nas reads happily; staged the
        # other way, the first line came back `sh: command not found`.
        if not FULL:                    # the release disk carries no SWEEP
            prodos.write(f'{LRDIR}/SWEEP', sh_bytes(main_script),
                         file_type=0x04, aux_type=0x0000, overwrite=True)
        listed = sorted(e.name for e in prodos.scandir(LRDIR))
    finally:
        prodos.unmount(VOL)
    shards_json = os.path.join(ROOT, 'build', 'nas-librel-shards.json')
    if SELFMAKE:
        pass                            # make drives it: no shards, and
                                        # the roster's shards.json stays
    elif nshards > 1:
        shard_paths = []
        objs = []
        for i, l in enumerate(nas_lines):
            m = re.search(r'-o\s+(\S+)', l)
            o = m.group(1)
            objs.append([i % nshards, o if o.startswith('/') else f'{LRDIR}/{o}'])
        for k in range(nshards):
            sp = os.path.join(ROOT, 'build', f'nas-librel-shard{k}.po')
            shutil.copyfile(OUT_IMG, sp)
            prodos.mount(sp)
            prodos.write(f'{LRDIR}/SWEEP',
                         sh_bytes([script[0]] + nas_lines[k::nshards]
                                  + ['echo SWEEPDONE']),
                         file_type=0x04, aux_type=0x0000, overwrite=True)
            prodos.unmount(VOL)
            shard_paths.append(sp)
        with open(shards_json, 'w') as fh:
            json.dump({'shards': shard_paths, 'objects': objs}, fh, indent=1)
        print(f'[build-nas-librel] {len(nas_lines)} nas lines dealt over '
              f'{nshards} shard images; {len(links)} links on the main image')
    elif os.path.exists(shards_json):
        os.remove(shards_json)
    if SELFMAKE:
        assert_complete_world(plan, kplan, skipped)
    with open(PLAN, 'w') as fh:
        json.dump({'utils': plan, 'kernels': kplan, 'skipped': skipped,
                   'heap': heap, 'real_heap': real_heap,
                   'validated_heap': VALIDATED_HEAP, 'selfmake': SELFMAKE,
                   'memory_model': 'incremental-two-pass-v1',
                   'assemblies': nstaged, 'links': len(links),
                   'libs': sorted(b for k, b, _t, _s in forms
                                  if k == 'lib' and b not in skipped),
                   'lib_pieces': lib_pieces},
                  fh, indent=1, sort_keys=True)
    print(f'[build-nas-librel] {LRDIR} holds {len(listed)} files; '
          f'{nstaged} nas lines + {len(links)} ld links staged')
    print(f'[build-nas-librel] utils staged: {len(plan)}; kernels '
          f'staged: {len(kplan)}; skipped {len(skipped)}: {sorted(skipped)}')
    print(f'[build-nas-librel] {OUT_IMG} ready (plan: {PLAN})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
