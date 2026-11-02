#!/usr/bin/env python3
"""check_modules.py -- enforce the kernel module boundary (task #8a / #8).

WHY THIS EXISTS. maux is heading for separately-assembled REL modules linked
with Merlin's LNK, because a memory-based assembler in a 64K process bank
cannot hold a whole-tree `PUT` chain (docs/SELFHOST.md). REL/LNK requires each
module to declare what it exports (`ENT`) and what it imports (`EXT`). That is
only possible if module boundaries are real.

Today they are not enforced, only described in prose ("PRECONDITION ON THE
INCLUDER" comments). docs/TOOLCHAIN.md asked for REL-linkable modules from
task #1 and the tree drifted anyway -- which is exactly what an unenforced
convention does. This gate is the ratchet.

merlin32 cannot help here: it has no REL/ENT/EXT directives at all (checked
2026-08-16 against its source -- it supports PUT/USE/PUTBIN/DSK and emits OMF
or flat binaries). So the boundary cannot be validated by building. It has to
be validated structurally, which is what this does.

THE RULE. A kernel module may reference only:
  * symbols it defines itself,
  * symbols exported by another kernel module,
  * globals from inc/*.equ,
  * the declared KERNEL_CONFIG interface below (what an image must supply),
  * its own entry in KNOWN_DEBT, which must shrink and never grow.

Anything else means a kernel module reaching up into its includer, which
cannot survive separate assembly.
"""
import fnmatch
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_equ_fwd  # noqa: E402 -- real-Merlin EQU forward-ref audit,
                       # folded in as a section below (see main()).
import check_kernel_images  # noqa: E402 -- kernel .SYSTEM image size
                             # ceiling (docs/PLAN.md "27 .SYSTEM kernel
                             # images"), folded in the same way (see
                             # main()); called right after
                             # check_image_fits() since it is the same
                             # gap for the kernel's own test images.
import check_manifests  # noqa: E402 -- manifest-list cross-check, folded
                         # in the same way (see main()).
import arena  # noqa: E402 -- merlin32 -v1 symbol dumps, read fresh per
               # build (see check_sh_budget's low-image/segment split).
import check_purity  # noqa: E402 -- the writable-text audit
import check_listings  # noqa: E402 -- no gate rewrites another's listing
import report_volumes  # noqa: E402 -- per-volume capacity REPORT, print-only
                        # (see report_volumes.print_summary() below --
                        # never contributes to this gate's failures)
                      # (docs/STICKY.md sec 17), folded in the same way.
                      # Its own docstring explains why it is HERE and
                      # not in src/bin/ld.s, which sec 17 asked for.

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IDENT = re.compile(r'[A-Za-z_][A-Za-z0-9_.]*')

# Directives whose operand is literal text rather than an expression.
STRING_OPS = {'asc', 'dci', 'inv', 'fls', 'rev', 'str', 'strl', 'txt'}

# Directives whose operand is a FILENAME. Without this, `put ../liba/string.s`
# parses into phantom symbols named `liba` and `string.s` -- harmless while
# only src/kernel was scanned (kernel modules `put` nothing) but wrong the
# moment src/bin, which is all `put` lines, is included.
FILE_OPS = {'put', 'use', 'putbin', 'dsk', 'sav', 'save'}

# Tokens that appear in operand position but are not symbol references.
NOISE = {
    'a', 'x', 'y', 's', 'A', 'X', 'Y', 'S',
    'equ', 'EQU', 'ds', 'DS', 'dfb', 'DFB', 'da', 'DA', 'asc', 'ASC',
    'hex', 'HEX', 'org', 'ORG', 'dsk', 'DSK', 'put', 'PUT', 'use', 'USE',
    'lst', 'LST', 'xc', 'XC', 'typ', 'TYP', 'dum', 'DUM', 'dend', 'DEND',
    'ext', 'EXT', 'ent', 'ENT', 'rel', 'REL', 'sav', 'SAV', 'err', 'ERR',
    'off', 'OFF', 'on', 'ON',
}

# The kernel's configuration interface: what a bootable image MUST supply.
# Under REL these become EXT in the kernel and live in a per-image config
# module that gets linked in. This list is the contract; keep it SMALL.
KERNEL_CONFIG = {
    'K_DISP_COUNT': 'number of syscall dispatch entries',
    'K_DISP_LO': 'syscall dispatch table, low bytes',
    'K_DISP_HI': 'syscall dispatch table, high bytes',
    'K_IRQ_HOOK': 'device-driver IRQ vector the image installs',
    # Builtin spawn-image table (added 2026-08-16, retiring the SPAWN_IMG_*
    # debt). PROC_SPAWN used to hardcode three magic path characters pointing
    # at symbols only test harnesses defined; the image supplies a table now.
    # COUNT = 0 is legal and means "every path is a real file".
    'K_BLTN_COUNT': 'number of builtin spawn images (0 is legal)',
    'K_BLTN_TAG': 'builtin table: path first-character tags',
    'K_BLTN_SRC_LO': 'builtin table: image address, low bytes',
    'K_BLTN_SRC_HI': 'builtin table: image address, high bytes',
    'K_BLTN_LEN_LO': 'builtin table: image length, low bytes',
    'K_BLTN_LEN_HI': 'builtin table: image length, high bytes',
    # KSEG (docs/KSEG.md): whether THIS image's manifest carries a
    # real cold segment. A merlin32 VARIABLE label (`]KSEG_WANT`,
    # inc/mm.hw.equ), not a plain `equ` -- redefinition is how a
    # segment-bearing manifest overrides the shared default (0)
    # to 1 after its own `org`/`put` block, and merlin32 refuses a
    # duplicate PLAIN label outright (checked directly). The `]`
    # is stripped by this scanner's own tokenizer, same as every
    # other symbol reference, so the config entry is the bare name.
    'KSEG_WANT': 'segment-bearing override (1) vs the shared '
                 'default (0), inc/mm.hw.equ',
}

# Symbols currently defined by MORE THAN ONE kernel module. Harmless under a
# whole-tree PUT assembly (last definition wins, and they agree); a genuine
# collision once each module is a separately linked REL object. Same ratchet
# rule as KNOWN_DEBT: this list may only shrink.
# WAS empty from 2026-08-16 (all ACCIDENTAL duplicates retired -- MLI and the
# four MOUSE_* PIA registers moved to inc/memmap.equ; MOUSE_SEND_CMD, a
# duplicated ROUTINE, moved to src/kernel/mouse.s which now owns it outright)
# until 2026-09-27 (coordinator review, DECISION 1), which introduces a NEW,
# DELIBERATE duplicate-name category: src/kernel/procdev.s (real) and
# procdevs.s (stub) each define the SAME glue-label set on purpose, because
# no manifest ever `put`s both -- that mutual exclusivity, not last-
# definition-wins, is what makes a whole-tree PUT safe here, module choice
# replacing `do ]KSEG_WANT` (nas has no `do`/`fin` directive at all). This is
# NOT the old "someone re-introduced a collision" shape this list used to
# guard against exclusively; it is still true that entries here need a real
# reason, just not ONLY the "empty" reason any more.
KNOWN_DUPLICATES = {
    'KSEG_BOOT', 'PDEV_TRYBLK_G',
    'PRC_BLK_RD_G', 'PRC_BLK_WR_G', 'PRC_BLK_SM_G', 'PRC_BLK_GM_G',
    'PRC_BLK_GE_G',
    # docs/DEVFS.md, 2026-09-30: the SAME real/stub split, added
    # when MAUXPLAY.SYSTEM ran out of flat headroom for these
    # three (check-kernel-images) -- procdev.s carries the real
    # KSEG_CALL trampoline (playtest.s only), procdevs.s the
    # fallback every other full-kernel manifest links instead.
    'PRC_DEVLIST', 'PRC_SYNAPPLY', 'PRC_ONLINE', 'VR_OTHER',
    'PRC_SYNCLASS',
    # 2026-10-11 EXEC-SHEBANG Part 3: VR_DEVCALL, same real/stub split
    # (procdev.s selects PRC_SYN_DISP's DV arm, procdevs.s clc/rts).
    'VR_DEVCALL',
    # 2026-10-07 TTY-TYPEAHEAD-BELL: SYS_TTYMODE, same real/stub split
    # (flat headroom: procdevs.s keeps the plain body, procdev.s the
    # trampoline into kdevblk.s PRC_TTYMD_SEG).
    'PRC_TTYMODE', 'PRC_TTYGEO',
    # 2026-10-08 PRODOS-CASE: PCASE_CREAT/PCASE_RENAME, the same
    # real/stub split (procdev.s records the typed case; procdevs.s
    # is a 3-byte jmp PRC_RET_MLI_A for every other manifest).
    'PCASE_CREAT', 'PCASE_RENAME',
    # 2026-10-18 KFIX5: the builtin-image spawn path, the same
    # real/plain split (spawnbl.s keeps the lookup, the embedded-
    # image loader and the dispatch for the manifests whose harness
    # spawns builtin images; spawnpl.s is clc/rts and a tail call
    # for every other manifest, MAUXPLAY included).
    'PRC_BLTN', 'PRC_LD_ANY',
    # 2026-10-18 KFIX5: VR_MNTCK, the /mnt name check: loopseg.s (the
    # play-only low segment) real, procdevs.s clc/rts for the rest.
    'VR_MNTCK',
}

# Existing violations, recorded rather than hidden. Each entry is test
# instrumentation welded into a kernel module -- the reason that module cannot
# be assembled standalone today. THIS LIST MUST ONLY SHRINK: a stale entry is
# a failure too, so retiring debt cannot silently leave dead allowances.
KNOWN_DEBT = {
    # RETIRED 2026-08-16: mli.s's nine R_* cells now belong to mli.s itself
    # (MLI_HAD_RAM, MLI_VBL_TICKS, MLI_WAITER_WANT/READY, ...), following
    # sched.s's K_SW_COUNT precedent. The harness reads them instead of
    # owning them.
    # RETIRED 2026-08-16: process.s no longer names harness symbols. It walks
    # the K_BUILTIN_* table the image supplies (see KERNEL_CONFIG above).
}


def operand_refs(operand):
    """Symbols referenced by one operand field.

    Merlin operands mix symbols with literals and expressions. Anything
    starting with '$' or '%' is a hex/binary constant, a leading digit is
    decimal, and ':foo' / ']foo' are file-scoped local labels that can never
    cross a module boundary. Split on the expression operators and accept only
    pieces that are entirely an identifier -- a substring match would read
    'C088' out of '$C088'.
    """
    out = set()
    if operand[:1] in ('"', "'"):
        return out          # a string literal, not an expression
    operand = re.sub(r'"[^"]*"', ' ', operand)
    operand = re.sub(r"'[^']*'", ' ', operand)
    for piece in re.split(r'[+\-*/,()\[\]<>#!^&|=]', operand):
        piece = piece.strip()
        if not piece or piece[0] in '$%' or piece[0].isdigit():
            continue
        if piece.startswith((':', ']')):
            continue
        if IDENT.fullmatch(piece) and len(piece) > 1 and piece not in NOISE:
            out.add(piece)
    return out


def scan(path):
    """Return (defined, referenced) identifier sets for one source file.

    Merlin's line format is `[label] opcode [operand] [free-form comment]` --
    the comment needs NO delimiter, so everything past the operand field must
    be discarded or comment prose gets read as symbol references.
    """
    defined, used = set(), set()
    for raw in open(path, errors='replace'):
        if not raw.strip() or raw.lstrip().startswith('*'):
            continue
        line = raw.split(';')[0].rstrip('\n')
        if not line.strip():
            continue
        if line[:1] not in (' ', '\t'):
            m = IDENT.match(line)
            if m:
                defined.add(m.group(0))
        parts = line.split()
        start = 1 if line[:1] in (' ', '\t') else 2
        # String-emitting directives take text, not expressions -- and
        # whitespace inside the literal defeats naive field splitting
        # (`asc "MOUSE-VBL "` would otherwise yield a symbol named VBL).
        if len(parts) >= start and parts[start - 1].lower() in (STRING_OPS | FILE_OPS):
            continue
        if len(parts) > start:
            used |= operand_refs(parts[start])
    return defined, used


# Real Merlin-8 rejects source lines longer than 64 characters with "Operand
# too long in line: N" -- measured 2026-08-16 by assembling lines of 62..69
# characters and seeing 64 pass and 65 be the first flagged. Merlin's own
# sources top out at 58, comfortably inside.
#
# maux was written against merlin32, which has no such limit, so the tree is
# full of long comment lines. This is a RATCHET, not a gate: the counts below
# are today's baseline and may only go DOWN. Every one has to be rewrapped
# before real Merlin can assemble the tree (task #7), and a hard failure now
# would just be noise.
#
# THE SCANNED FILE SET IS DERIVED, NOT ENUMERATED (docs/PLAN.md: "check-
# modules claims tree-wide coverage it does not have"). This dict used to
# be a hand-picked glob naming four of maux's six src/ subtrees --
# src/merlin/ and src/relspike/ were never named at all, and src/bootblock.s
# + src/check.memmap.s (real compilation units the Makefile assembles
# directly, one of which SHIPS IN THE IMAGE) fell through the same gap.
# scanned_file_set() below derives the actual scanned file set from
# check_manifests.py's put/use closure machinery: every file reachable
# from every top-level compilation unit (check_manifests.toplevel_
# manifests(), itself now derived from the Makefile's own $(MERLIN32)
# recipes rather than a directory glob -- see that module). The keys
# here are still directory+extension BUCKETS, for a stable readable
# ratchet, but bucket MEMBERSHIP is whatever the closure actually
# contains -- see bucket_of(). A newly-derived bucket with no entry here
# fails loudly (see check_line_length) rather than silently scanning as
# zero.
#
# 'src/*.s' is new: src/bootblock.s (31 over) + src/check.memmap.s (23
# over) = 54, measured 2026-08-23 the same day the gap was found. This
# replaces check_dialect.py's former OUT_OF_SCOPE_LINE_DEBT, which pinned
# the same two files in a second, parallel hand-written list -- gone now
# that this one ratchet sees them.  53 since 2026-09-16: the inc/ layout
# move shortened one of check.memmap.s's header lines below 64 by
# spelling a path `inc/memmap.equ` instead of `include/memmap.equ`.
MERLIN_LINE_LIMIT = 64
LONG_LINE_BASELINE = {
    'src/kernel/*.s': 0,
    'src/liba/*.s': 0,
    'src/bin/*.s': 0,
    'src/bin/*.equ': 0,
    'inc/*.equ': 0,
    'src/test/*.s': 0,
    'src/test/asm/*.s': 0,
    'src/*.s': 53,
}


def scanned_file_set():
    """(scanned, orphans) -- the DERIVED replacement for a hand-picked
    glob. `scanned` is every file reachable from every top-level
    compilation unit's put/use closure (check_manifests.toplevel_
    manifests() + closure()): the honest set of "what real Merlin-8 must
    be able to read" for this tree, since a top-level unit's `put`/`use`
    chain is exactly what gets loaded to assemble it.

    `orphans` is check_manifests.universe() minus `scanned` -- tree files
    that are in NO compilation-unit closure at all: neither a top-level
    unit nor reachable from one. That is either dead source or an
    undiscovered top-level unit, and is reported by the caller rather
    than silently folded into or dropped from the ratchet."""
    graph, put_targets = check_manifests.build_graph()
    tops = check_manifests.toplevel_manifests(graph, put_targets)
    scanned = set()
    for top in tops:
        scanned |= check_manifests.closure(graph, top)
    orphans = check_manifests.universe() - scanned
    return scanned, sorted(check_manifests.rel(o) for o in orphans)


def bucket_of(path):
    """Group one scanned file into the directory+extension bucket the
    old hand-written glob keys named (e.g. 'src/kernel/*.s'), purely for
    a stable, readable report and ratchet -- a file in a directory/
    extension pair no earlier bucket covered (src/bootblock.s and
    src/check.memmap.s -> 'src/*.s') gets a new bucket automatically,
    rather than being silently absorbed into or excluded from an
    existing one."""
    d, base = os.path.split(check_manifests.rel(path))
    ext = os.path.splitext(base)[1]
    return f'{d}/*{ext}'


def check_no_tabs():
    """No tab characters anywhere in the scanned tree.

    THIS PINS AN ASSUMPTION THE SELF-HOSTED COMMENT STRIP RESTS ON
    (docs/S9-PLAN.md sec 4). maux strips its own comments with

        sed 's/^\\*.*//;s/^ *;.*//'

    and the second command uses a plain ` *` where the real rule is
    "any leading whitespace", because sed.s's v1 subset has no
    bracket expression. The two are equivalent for exactly as long
    as the tree contains no tabs -- and ONE tab-indented `;` comment
    would silently survive the strip, growing the staged source and
    pushing units back over as's window, with nothing to say why.

    S9-PLAN named this as the first of the three things blocking the
    strip and asked for it here. An assumption a program depends on
    and nothing measures is not an assumption, it is a bug waiting
    for a contributor whose editor inserts tabs.
    """
    scanned, _ = scanned_file_set()
    hits = []
    for path in sorted(scanned):
        try:
            text = open(path, encoding='latin-1').read()
        except OSError:
            continue
        n = text.count('\t')
        if n:
            hits.append((path, n))
    print()
    print(f'[check-modules] tab characters in the scanned tree '
          f'(the self-hosted comment strip\'s ` *` depends on zero)')
    if hits:
        for path, n in hits:
            print(f'[check-modules] FAIL: {os.path.relpath(path, ROOT)} '
                  f'has {n} tab character(s) -- maux\'s own strip '
                  f'program matches leading SPACES only (sed.s has no '
                  f'bracket expression), so a tab-indented `;` comment '
                  f'survives it. Replace the tabs.', file=sys.stderr)
        return [f'{len(hits)} file(s) contain tab characters']
    print(f'   0 -- {len(scanned)} scanned file(s), no tab characters')
    return []


def check_line_length():
    """Ratchet on lines too long for real Merlin-8, over the DERIVED
    scanned file set (scanned_file_set()) -- see LONG_LINE_BASELINE's
    comment above."""
    failures = []
    print()
    print(f'[check-modules] real-Merlin line limit ({MERLIN_LINE_LIMIT} chars) '
          f'-- baseline may only shrink')
    scanned, orphans = scanned_file_set()
    buckets = {}
    for path in scanned:
        buckets.setdefault(bucket_of(path), []).append(path)
    total = 0
    for pattern in sorted(set(LONG_LINE_BASELINE) | set(buckets)):
        paths = buckets.get(pattern, [])
        n = sum(1 for path in paths
                for line in open(path, errors='replace')
                if len(line.rstrip('\n')) > MERLIN_LINE_LIMIT)
        total += n
        baseline = LONG_LINE_BASELINE.get(pattern)
        if baseline is None:
            mark = '  (NEW BUCKET, no baseline)'
            failures.append(
                f'{pattern}: newly-derived bucket ({len(paths)} file(s)) has '
                f'no LONG_LINE_BASELINE entry -- add one pinned at {n} '
                f'(today\'s measured count) so the ratchet covers it.')
        else:
            delta = n - baseline
            mark = '' if delta == 0 else f'  ({delta:+d})'
            if delta > 0:
                failures.append(
                    f'{pattern}: {n} lines exceed real Merlin\'s '
                    f'{MERLIN_LINE_LIMIT}-char limit, up from {baseline}. New '
                    f'over-long lines make the task #7 rewrap bigger; wrap them.')
            elif delta < 0:
                failures.append(
                    f'{pattern}: down to {n} over-long lines from {baseline} -- '
                    f'good, now lower the baseline in check_modules.py so the '
                    f'ratchet holds.')
        print(f'   {pattern:<18} {n:>5} over limit{mark}')
    if orphans:
        print(f'   note: {len(orphans)} tree file(s) are in NO '
              f'compilation-unit closure (dead source, or an undiscovered '
              f'top-level unit) -- not scanned by this ratchet: '
              f'{", ".join(orphans)}')
    if total == 0:
        print('   TOTAL                  0 -- the whole tree is within real '
              'Merlin\'s line limit')
    else:
        print(f'   {"TOTAL":<18} {total:>5} lines still to rewrap')
    return failures


# learning:01M050C6KW01MPJ2TQTPMTZXN6 -- the measured label limit.
# Real Merlin-8 rejects any label field longer than 13 characters with
# "Bad label in line: N". It is a hard rejection, not a truncation, so the
# symbol is never defined and every reference to it fails as well. A leading
# ':' on a local label counts toward the 13, so locals get 12 usable
# characters. Measured 2026-08-16 by assembling labels of 11..17 characters
# under Merlin 2.59 on verilogapple: 13 assembles, 14 does not.
#
# Unlike the line-length ratchet this starts life as a GATE at zero -- the
# tree was brought under the limit in one pass (scripts/shorten_labels.py)
# and there is no reason to ever add a symbol that real Merlin cannot read.
MERLIN_LABEL_LIMIT = 13


# `put ../liba/MODULE.s` lines in a src/bin/*.s program -- the program's
# actual liba dependency list. Shared by check_userland() (cost reporting)
# and check_dead_puts() (the FAT.md sec 9 gate) so there is exactly one
# parser for this, per the task instructions.
PUT_RE = re.compile(r'^\s+put\s+\.\./liba/(\S+)', re.IGNORECASE)


def parse_put_list(path):
    """Ordered list of liba/*.s module basenames one src/bin/*.s `put`s."""
    mods = []
    for line in open(path, errors='replace'):
        m = PUT_RE.match(line.split(';')[0])
        if m and m.group(1).endswith('.s'):
            mods.append(m.group(1))
    return mods


# ---------------------------------------------------------------------
IMAGE_WINDOW = 0xBEFF - 0x0800 + 1      # 46848; inc/mm.procbnk2.equ


def check_image_fits():
    """Gate: a built binary must fit the process image window.

    Added 2026-08-20 after build/ed.bin reached 46855 bytes against a
    46848-byte window -- SEVEN BYTES OVER -- and every gate passed.
    PRC_LD_FL_IMG loads from LOAD_BASE until EOF, so an oversized image
    runs off the end of $0800-$BEFF and into the $BF00 MLI-compat
    overlay page. check-ed stayed green only because `ed` happens not
    to use that page: silent corruption, not a caught error.

    This is the same shape as the manifest-list bugs
    (scripts/check_manifests.py) -- a constraint everybody knows,
    written down in inc/mm.procbnk2.equ, and enforced by
    nothing.
    """
    failures = []
    print()
    print(f'[check-modules] process image window '
          f'({IMAGE_WINDOW}B, $0800-$BEFF)')
    for path in sorted(glob.glob('build/*.bin')):
        n = os.path.getsize(path)
        if n > IMAGE_WINDOW:
            failures.append(f'{path}: {n}B exceeds the {IMAGE_WINDOW}B '
                            f'image window by {n - IMAGE_WINDOW}B -- it '
                            f'will overrun into $BF00 at load')
        elif n > IMAGE_WINDOW * 0.95:
            print(f'   {os.path.basename(path):16} {n:6d}B  '
                  f'{n / IMAGE_WINDOW * 100:.1f}% -- NEAR THE CEILING')
    if not failures:
        print(f'   all {len(glob.glob("build/*.bin"))} built binaries fit')
    return failures


# docs/SH-SUBSET.md sec 1: spawn is length-driven (39.07 cyc/byte,
# src/kernel/procspawn.s), so sh's OWN size is a tax paid at every
# invocation, forever. That doc sets 16384B as a TRIPWIRE -- "a whole
# subsystem arrived unannounced", not a per-feature ledger to agonise
# over -- and asks for it to be gated rather than left in a document
# nobody re-reads. sh.bin was 7938B before Tier 0 ($?, `;`, `&&`/`||`).
#
# RAISED 16384 -> 17408 on 2026-08-27 by operator ruling, recorded in
# docs/SH-SUBSET.md sec 7.1. sh.bin had reached 16,350 (34 free) and
# every remaining named V7 gap -- IFS, `{ list; }`, trap/eval/exec/
# readonly/<& -- was blocked by the tripwire rather than by anything
# real. The ruling: "a few hundred bytes north of the cap isn't
# meaningful; what's meaningful is a Bourne shell in ~16 KB of 6502.
# 24 or 32 is a different conversation."
#
# The cap is entirely self-imposed -- the process window is 46,848 B,
# so sh uses 35% of what it could -- and the only real cost is the
# spawn tax at 39.07 cyc/byte, where 1 KB is ~40k cycles against a
# 673k-cycle screen scroll. Anything approaching 24 KB needs a NEW
# ruling, not this one: that is where the artifact stops being
# describable as a Bourne shell in 16 KB.
# RAISED 17408 -> 17664 on 2026-08-29: the tracked-command cache
# (POSIX `hash` shape, +142B) -- built at the operator's own prompting
# ("re-resolving sed shouldn't happen; the sticky binary thing should
# do its job") after a block trace showed BUILD_PATH's per-spawn
# OPEN+CLOSE probe was most of the remaining volume-directory reads.
# Same spirit as the 2026-08-27 ruling above; still ~37% of the
# process window, still nowhere near the 24 KB new-ruling line.
# RAISED 17664 -> 17792 on 2026-08-29: liba gained creat(2) (the
# UNLINK+CREATE+OPEN retirement -- discussed, same conversation as
# the hash-cache raise above). sh's own OPEN_REDIR_WR SHRANK to a
# tail call, but the linked liba routine outweighs it by 6 bytes.
# RAISED 17792 -> 18560 on 2026-09-02: `trap` (src/bin/shtrap.s,
# docs/SIGNALS.md sec 3a) -- the announced subsystem the tripwire
# asks to be discussed, not trimmed. The builtin, the pump, the
# exit hook and the name table are ~770B; this is the operator's
# named payoff of the held-signal kernel, not a feature that crept
# in. sh.bin measures 18492.
# RAISED 18560 -> 18656 on 2026-09-06: `sh SCRIPTFILE` mode
# (src/bin/shlex.s START, docs/SH-FEATURES.md sec 4) -- ARGC==2
# names a file sh reads its commands from via OPEN_REDIR_RD,
# leaving fd 0/1/2 free for the invoked command's own I/O. This
# is EX3's own announced payoff (docs/TASKS.md, the ex `!`/`w !`/
# `r !` pipeline rewire): `ex` spawns `sh SCRIPTPATH` so a REAL
# pipeline (`cat | sort`) attaches to the whole execution instead
# of just its last stage. +24B over the prior budget for the new
# branch, SCRERR_MSG, and the argv[1]/OPEN_REDIR_RD call --
# sh.bin measures 18584.
# RAISED 18656 -> 18784 on 2026-09-07: `|`/`||` need no blanks
# (src/bin/shtok.s :bpipe + TOK_ENDPAR, docs/SH-PIPE-NOSPACE.md).
# `sort|uniq` used to lex as ONE word -- "command not found", and
# vi's `:%!sort|uniq` emptied the buffer. The announced fix from
# that brief, not a feature that crept in: +144B for the split
# (the operator token is constant text, since an in-place NUL has
# no spare byte between `sort` and `|`), the `$( )`/case-pattern
# content rules, and the two glued-closing-quote cases. Still
# nowhere near the 24 KB new-ruling line. sh.bin measures 18728.
# RAISED 18784 -> 18864 on 2026-09-08: the shell DECLARES its
# console's foreground job (src/bin/shbltn.s FG_DECLARE/FG_CLEAR,
# shblt2.s RUN_PIPELINE's :fgjob/:done, docs/JOB-CONTROL.md
# Increment A) -- the announced kernel+shell subsystem this
# tripwire asks to be discussed, not trimmed: SYS_TCSETFG names the
# live stage pids before the reap loop and an empty set after it,
# so ^C kills the foreground pipeline and no longer a `&` job or
# another console's. +71B: the two routines, the FG_PARM block and
# the two call sites. sh.bin measures 18799.
# RAISED 18864 -> 20384 on 2026-09-08: job control's shell half
# (src/bin/shjob.s, docs/JOB-CONTROL.md Increment C) -- the
# announced subsystem the tripwire asks to be discussed, not
# trimmed, and the operator's own /goal ("suspend, job control").
# The job table (one row per pipeline, in the arena: no image
# bytes), `jobs`/`fg`/`bg`, FG_WAIT's three-mode SC_WAITJOB loop
# that replaces RUN_PIPELINE's SC_WAIT reap so a ^Z comes back
# as a Stopped job, the prompt-time WNOHANG drain with its
# `[n]  Done   cmd` notices, the `&` `[n] pid` line and W4's
# unredirected-output diagnostic. `wait` moved there with the
# table it drains; BG_RECORD/BG_PIDS are gone. +1497B; still ~43%
# of the process window and under the 24 KB new-ruling line.
# sh.bin measured 20332; the `%spec` command shorthand (`%1` =
# `fg %1`, `%1 &` = `bg %1`) took it to 20381 -- 3 B of headroom.
# The next sh feature bumps this line, and says so here.
# RAISED 20384 -> 20736 on 2026-09-08: `kill %n` and `wait %n`
# (src/bin/shjob.s KILL_SPECS + CHCK_BLTN_WT, docs/JOB-CONTROL.md
# Increment C's kill/wait follow-up) -- the last two job-control
# verbs a job spec is for, settled with the operator as PER-
# COMMAND features, not a `%` word expansion (`echo %1` stays
# literal). `kill %n` is a pre-spawn argv rewrite: the spec's slot
# becomes the job's live member pids (one slot each, so a pipeline
# is signalled whole) and /bin/kill stays the one parser of
# -signo/pid/diagnostics -- chosen over a kill builtin because the
# builtin would have to carry kill.s's digit parser and its four
# message strings a second time. +291B: KILL_SPECS (~170), the
# `wait` operand path (~75), KILL_STR, the chain hook. sh.bin
# measures 20672; still ~44% of the process window, under the
# 24 KB new-ruling line.
# RAISED 20736 -> 21120 on 2026-09-14: `test`/`[' brought to
# POSIX.1-2024 (docs/POSIX-GAPS.md sec 2's own `test` row, priced
# there at ~300 B before this task started) -- `!` was already
# shipped; this adds `-a`/`-o`/`( )` (a real precedence-climbing
# grammar: OR_EXPR/AND_EXPR/NOT_EXPR/PRIMARY replace the old
# fixed-arity EVAL_N2/EVAL_N3 dispatch, net smaller per case but
# the grammar itself is new code), `-s -r -w -x` (real ProDOS
# mappings, src/bin/testeval.s decision 4), and the 8 always-false
# primaries `-b -c -g -h -L -p -S -u` (ProDOS has none of these
# object types -- one range check, no operand touched). sh.bin
# measured 21046 at that point.
# RAISED 21120 -> 21160 same day: check-posixutil's own new `test`
# conformance rows (scripts/posixutil_cases3.py) found a REAL bug
# while proving the above -- `TEST ... > OUT` created no file at
# all, because a shell builtin dispatches BEFORE RUN_PIPELINE ever
# applies redirection (shbltn.s CHCK_BLTN_ECH's own header names
# this trap; echo falls through to a real spawn when redirected,
# but test has no spawn to fall through to). Fixed with TST_REDIR
# (src/bin/shparse.s): open-then-immediately-close the plain fd-1
# target, the same guarded scope as CHCK_BLTN_ECH's, safe because
# nothing is left open or touching the next command's own
# per-stage state (that CHCK_BLTN_ECH is the one case study of
# HOW that goes wrong). sh.bin measures 21109; headroom kept
# deliberately small, the ratchet's own point.
# 2026-09-15: console-loop spooling (docs/SH-FEATURES.md) --
# FOR/WHILE/UNTIL read from a non-seekable CUR_IN_FD (a tty or
# a $( ) pipe) now spool the whole construct to a temp file and
# `.`-source it, instead of dying with "stdin not seekable".
# sh.bin measures 21979; headroom kept deliberately small, the
# ratchet's own point (docs/SH-SUBSET.md sec 7).
# Raised AGAIN same day: SPOOL_SPLIT made quote-aware (a `;`
# inside quotes is no longer a false segment boundary) and the
# head line now spools from a pristine pre-TOKENIZE copy
# (RAWLINE) instead of a NUL-to-space fixup, refusing loudly
# when a quote precedes the loop on its own line rather than
# spooling shifted text. sh.bin measures 22098.
# 2026-09-15: three prompt-level bugs -- builtin `echo` grew -n
# (shbltn.s CHCK_BLTN_ECH, matching src/bin/echo.s byte for
# byte); STRIPCOMMENT (shlex.s) made quote-aware so a '#' inside
# '...'/"..." is text, not a truncation point, and only starts a
# comment at the START of a word (POSIX 2.2/2.3) instead of the
# old "not right after '$'" carve-out. A backslash inside single
# quotes was checked and found ALREADY literal (shtok.s's
# :doquoted copies every byte up to the matching quote mark with
# no backslash special-casing) -- no code change there. sh.bin
# measures 22193; headroom kept deliberately small.
# 2026-09-15: the two QUOTING gaps sec 22.3 reported but did not
# fix. (1) Adjacent quoted/bare segments now CONCATENATE into one
# word (POSIX 2.2) instead of `sh: mixed quoting` -- `'it''s'`,
# `"a"'b'c`, `x"y"` are each one token (shtok.s :qsetup/:doquoted/
# :segend, TOKQUOTE built up per-token as the WORST case across
# every segment, per-byte bit-7 marking protecting a quoted
# segment's own '$'/glob characters). (2) `"..."` now implements
# POSIX 2.2.3's backslash table (`\$ \` \" \\` strip to the bare
# character, any other `\X` keeps both bytes) instead of copying
# every byte verbatim -- :qloop2, also clearing '*'/'?'/'[' the
# way ASGMARK already did for a quoted assignment. STRIPCOMMENT
# (shlex.s) and the console-loop spooler's SPOOL_SPLIT (shtrap.s)
# both learned the same "an escaped '\"' does not close a
# double-quoted span" rule, for consistency. sh.bin measures
# 22413 (a `(` GROUP token needed its own TOKGRP latch -- TOKFINAL
# -- once TOKQUOTE's final store moved to the token's real end,
# else `( V=x ; ECHO $V )`-shaped groups silently lost their
# literal marking to whatever bare/quote lexing ran inside them).
# headroom kept deliberately small.
# 2026-09-15: `unset`, `$!`, `<&N`/`<&-`, and `getopts` (docs/
# SH-FEATURES.md sec 24) landed together -- a real subsystem,
# per sec 7's own "a subsystem arrived, let's discuss it" rule.
# sh.bin measures 23457 (getopts alone is most of that: OPTIND/
# OPTARG as ordinary shell variables, cluster-position tracking,
# and both silent and loud POSIX diagnostics). Raised with a
# small margin, same ratchet as every prior raise above.
# 2026-09-15: the one-line-loop-from-a-file fix (CS_MARKHEAD,
# docs/SH-FEATURES.md sec 1) NET SAVED 13 B (23500 -> 23487 --
# two call sites folded into one shared subroutine), then `set
# -e`/`set +e` (sec 2) added 172 B (23487 -> 23659), then `{
# list ; }` brace groups (sec 3, including the CR_ISTERM
# terminator fix and console-spool wiring) added 140 B
# (23659 -> 23799), then `${V%pat}`/`${V%%pat}`/`${V#pat}`/
# `${V##pat}` (sec 4, VPAT_STRIP + the GLOBMATCH-based suffix/
# prefix scan) added 343 B (23799 -> 24142; a real bug found
# and fixed the same day -- a bare TAX where Y->X was meant,
# there being no such direct transfer on 6502 -- cost one byte
# over the first measurement, TYA+TAX). Raised with the same
# small margin.
#
# 2026-09-16 -- THE TRIPWIRE SPLIT IN TWO, because sh stopped being one
# image.  Operator ruling ("segment or overlay? make a sane decision"):
# sh gets a SECOND CODE SEGMENT resident in the process language card's
# common region at $E000, NOT an overlay (docs/SH-SUBSET.md ruling 7.6).
# So `wc -c build/sh.bin` no longer measures the thing the number was
# ever about.  The claim the number carries -- "a Bourne shell whose HOT
# CORE is under 24 KB" -- is a claim about the LOW RESIDENT IMAGE: the
# parser, the expander, the spawn path, the prompt loop, and every
# string a syscall is ever handed.  That is what SH_BUDGET gates now,
# unchanged at 24,170 so the ratchet above keeps its whole history; the
# file itself is REPORTED, not gated, because it is now low + segment
# and the two have different ceilings for different reasons.
#
# SH_SEG_BUDGET is the second one.  PRC_LC_COMMON is 7,936 B
# ($E000-$FEFF, inc/mm.procbnk2.equ) and $FF00 is the kernel's;
# sh.s carries an assembly-time `err */$FF00` against that door already,
# which is the HARD limit.  6,144 is the soft one -- the same shape of
# number as SH_BUDGET: it leaves 1,792 B of real headroom so that
# running out is a conversation and not a crash, and it says the segment
# is for cold builtins rather than a second shell.
#
# BOTH ARE READ FROM THE LISTING, NOT FROM THE FILE.  `merlin32 -v1`
# prints SH_SEG_LOW (the low image's end), SH_SEG_BEG and SH_SEG_END,
# and arena.symbol_table() re-assembles sh.s to get them fresh on every
# run -- a listing address is a property of one build, and a cached one
# measures a program that no longer exists.
SH_BUDGET = 24170
# SH-PREFIX: 24,170 -> 25,000.  Prefix assignments (shpfx.s, ~850 B),
# `sh -c` and the script-fd move (OPEN_HI, UFD_DUP2) are per-command
# paths, not a cold subsystem, and the window is no longer the limit
# (Phase 0 returned 4,255 B of it); the literal base of sh.s's
# dead-copy block moved $6700 -> $6A00 with them.
SH_BUDGET = 25000
# DUPFD-1 phase S: 25,000 -> 25,300.  DUP_CHECK (shblt2.s) judges a
# line's `N>&M` sources before RUN_PIPELINE or SUB_GROUP opens or
# spawns anything, and the bad-fd diagnostics: ~280 B that cannot go
# cold (every pipeline runs it; the $E000 segment is at its hard wall
# and segment 2 is full).  The dead-copy block's literal base moved
# $6A00 -> $6B00 with it (sh.s), as it did for SH-PREFIX.
SH_BUDGET = 25300
# TAB-A3: 6,144 -> 7,424.  The completer (shtabc.s) is 1,2xx B of cold
# interactive code and the alias table moved up to $FD78 (the table
# ends at $FF00, the kernel's door), so the segment's HARD wall is
# now 7,544 B, sh.s's assembly-time `err */ALI_BASE`; 7,424 keeps the
# same kind of 120 B gap behind the soft line.  The window margin is
# the limit that binds (docs/SH-SUBSET.md 7.9): see check below.
SH_SEG_BUDGET = 7424
# OPEN-RW-1: 7,424 -> 7,544 (= sh.s's `err */ALI_BASE` wall, $FD78).
# The busy-open retry and its ^C bracket (shsgrw.s, ~230 B) is cold
# code: it runs only after a `>`/`>>` OPEN has already failed with
# $50, so it belongs in the segment, not in the 54 B-from-full low
# image. It takes the 120 B gap and 3 B more; the next cold feature
# meets the HARD wall, so it goes where SH-PREFIX notes sec 12 says
# (a new segment 1 tenant must first move something out of it).
SH_SEG_BUDGET = 7544
# 2026-10-17 (KFIX3 item 0): the SECOND segment, the language card's
# $C08B bank at $D000 (inc/mm.procbnk2.equ PRC_LC_BANK2). It is a new
# region with its own bound, not more room behind SH_SEG_BUDGET: the
# 4,096 B bank less one byte: the copy takes the page holding the end,
# so an end of exactly $E000 would overwrite the first segment's first
# page (KFIX3 review F1); the far wall is sh.s's `err */SH_SEG2_LIM`.
# Nothing in it may be handed to a syscall (copyin/copyout refuse
# >= $D000, the same rule the first segment lives under).
#
# TAB-A2: the TOP of that bank now holds the line editor's history
# ring (sh.s ED_HBASE, page-aligned), so the code's wall is the ring's
# base, not the bank's top. 4,095 stays the no-ring ceiling.
SH_SEG2_BUDGET = 4061       # SH-ROOM2: measured 4,029 + 32
# SH-ROOM2 (2026-10-23): the cold bundle that moved low -> segment 2 and
# the strings that must NOT move with it. Checked by symbol in
# check_sh_budget; docs/SH-ROOM2-NOTES.md sec 5 has the reason per name.
SH_SEG2_RESIDENT = ('PFX_REC', 'PFX_ISSPEC', 'PFX_SPECS',
                    'CHCK_BLTN_SET', 'SET_ARG1', 'SET_STR', 'SETX_STR',
                    'SETXOFF_STR', 'SETE_STR', 'SETEOFF_STR',
                    'CONT_UNWIND')
SH_LOW_ONLY = ('PFX_MANY_M', 'SETUSAGE_MSG', 'VARNMLONG_MSG',
               'VARVLLONG_MSG', 'CSEOF_MSG', 'SH_CPARM')
# SH-ROOM (2026-10-22): the room it made, written down so the next
# stream sees it and spends it on purpose.  Three moves, NO behaviour
# change (one latent defect fixed on the way, `alias ""`):
#   * the alias table (392 B) left the $E000 card for the segments' dead
#     low copy, where it emits nothing: segment 1's hard wall moved
#     from $FD78 to the kernel's door ($FF00, sh.s SH_SEG1_LIM);
#   * duplicated low code folded onto shared helpers (SB_MATCH for the
#     builtin name match, PR_ERRAX1/1M for the status tails, one fdactions
#     emitter, one redirect-operator front, one seek-to-head): the low
#     image fell 25,284 -> 24,568 B (-716);
#   * SH_BUDGET follows: 25,300 -> 24,600, the measured image plus 32 B
#     (the headroom the past raises left was 16-60 B); the 700 B between
#     here and the old line are available, by a dated raise with a
#     reason, not by silence.  SH_SEG_BUDGET goes to the TAB-A3
#     convention against the new wall: 120 B under it (7,936 - 120).
# SH-MLQUOTE (2026-10-22): the logical-line reader.  The brief
# pre-approved raising SH_BUDGET to at most 25,300 for this stream's
# measured bytes: 24,568 -> 25,087 (+519: docs/SH-MLQUOTE-NOTES.md sec
# 7 accounts for it routine by routine, hot vs cold); the tripwire is
# the measured image plus 32 B again.  The JOIN, the over-long refusal
# and its scanner went to segment 1 (+287 B, 7 B under SH_SEG_BUDGET,
# which is NOT moved).
# review of 0418a9c6 (2026-10-22), findings H2/M1/M2: the refusal
# scanner now follows TOKENIZE's `$( )`/`( )` spans (segment 1 +66 B), a
# here-doc line or body past its cap is refused instead of truncated
# (low +45 B net: STRIPCOMMENT's dq rule shrank), so SH_BUDGET 25,119 ->
# 25,164 (the measured 25,132 + 32, still 136 B under the brief's 25,300)
# and SH_SEG_BUDGET 7,816 -> 7,891 (measured 7,875 + 16), the FIRST move
# of the segment tripwire: the wall behind it ($FF00) leaves 61 B.
# SH-EXECLOOP (2026-10-22): `for ..; do CMD` (POSIX).  The brief pre-
# approved SH_BUDGET up to 25,300: 25,164 -> 25,249, the measured low
# image (25,217) plus 32 B again; segment 1 is UNCHANGED (7,875).  The
# alias table and TRAPTAB literal bases moved up one page ($6B78 /
# $6D00) because the image outgrew $6A78 (SH-ROOM rule).
# review H1 (string sources never read the caller's lines:
# SH_RUNSTR + SPOOL_STREOF, +34 B): 25,249 -> 25,292, the measured 25,260
# plus 32 B, still under the brief's 25,300.
# SH-SEQ B (the one-line case: RW_CASE keeps the residual, the
# CASE route and the nested-residual path in SH_RUNLINE, CASE_STATUS
# and its CASE_EMPTY flag, the dead-head mark): +43 B, 25,268 ->
# 25,311, so 25,292 -> 25,343 (measured + 32), under the brief's
# 25,400 for phases A and B together. Segment 1 did not move.
# SH-SEQ C (the `.` continuation: DOT_SAVE/CONT_POP/SLOT_PTR, the
# EE_TESTED split, the construct floor at ten sites, the PRETOK copy
# and TOKOFF in TOKENIZE, the resume hook, the SH_EOF split):
# +301 B, 25,310 -> 25,611, so 25,343 -> 25,643 (measured + 32;
# the architect allowed up to 25,650 without asking). Segment 1
# took CONT_UNWIND (+34 B, 7,875 -> 7,909) and its tripwire goes to
# the 7,920 ceiling the ruling set (the wall is 7,936). The
# dead-copy bases moved up a page ($6B78 -> $6C78, $6D00 -> $6E00)
# and TOKOFF/PRETOK joined its roster.
# review of C (M1 CASE_EMPTY under a skipping ancestor, M2
# CONT_SEP published after ERREXIT_CK): +11 B, 25,611 -> 25,622, so
# 25,643 -> 25,650, the cap the ruling allowed (measured + 28).
# SH-CASE2 A (`$?` after an untaken `if` or a loop that never ran
# its body: the dead-head mark, CS_POPLIVE, the last-body-status hand-
# off across a loop's pop and re-push; a head that `&&`/`||` skipped
# is dead, for if/while/until/for/`{`): +95 B, 25,622 -> 25,717, so
# 25,650 -> 25,749 (measured + 32; the brief allowed up to 25,780).
# Segment 1 did not move; the dead-copy bases did not either (the image
# ends $6C75, the alias block starts $6C78).
# SH-CASE2 B (glued and parenthesised case patterns: TOKCP and the
# bare-`)` record in TOKENIZE, PAT_CHECK/PAT_SPLIT/PAT_NOEMPTY in PARSE,
# SEP_PAT, CS_CASEBTW, the stop-aware TOKENIZE lookahead, the `;;` and
# backslash fixes in the console spooler): +311 B, 25,717 -> 26,028,
# so 25,749 -> 26,050. review of 4f306140 (the trap pump hides a
# pending loop-back hand-off, empty patterns refused, NCMD test, `|`
# after a pattern, `$(` stop): +70 B, 26,028 -> 26,098, SH_BUDGET 26,100
# (the review's cap; measured + 2).
# The dead-copy bases moved up two pages ($6E00 -> $7000 TRAPTAB,
# $6C78 -> $6E78 ALI_NAMES).
# SH-ROOM2 (2026-10-23), NO behaviour change; docs/SH-ROOM2-NOTES.md
# sec 3 has the step-by-step figures.  Two folds (-25 B low), then the
# history ring left the $D000 bank (segment 2's wall is the bank
# boundary now) for the dead copy directly below ALI_NAMES, and 415 B
# of cold code (PFX_REC, PFX_ISSPEC + PFX_SPECS, `set`) went low ->
# segment 2, then CONT_UNWIND (34 B) segment 1 -> segment 2:
#   low image      26,098 -> 25,658   SH_BUDGET     26,100 -> 25,690
#   segment 1       7,909 ->  7,875   SH_SEG_BUDGET  7,920 ->  7,907
#   segment 2       3,580 ->  4,029   SH_SEG2_BUDGET 3,583 ->  4,061
# every tripwire measured + 32.  The TAB-A3 convention (wall - 120)
# cannot hold for either segment: segment 1 has been over it since
# SH-SEQ C (7,875 against 7,816) and segment 2 is meant to be nearly
# full (66 B under its wall; the 120 B gap would put the line under
# what is already there), so neither is dragged back; the HARD walls
# (`err */SH_SEG1_LIM`, `err */SH_SEG2_LIM`) are the limits that bind.
# The low image now ends $6C39; the history ring starts at $6C78, so
# the low image has 62 B before it meets the ring, and the dead copy's
# top spare is 155 B (high water $9A1F, file end $9ABA): moving the
# blocks up a page would cost 256 B there, so the next low growth past
# ~62 B must come out of the low image again, not move the bases.
# 2026-10-31 -- a spawn refused for want of a process bank said
# `sh: command not found`. The two strings the write syscall takes
# (`no more processes`, `file table full`: 44 B with their CRs) must
# stay LOW (copyin refuses >= $D000); the decoder, PR_SPAWNFAIL, is
# cold and went to the cold bundle. Low image 25,657 -> 25,704 (+47),
# tripwire 25,690 -> 25,720.
#
# NOT "measured + 32" this time, and the convention must not be applied
# here again. The image is based at $0800 and the ED history ring is at
# $6C78, so the HARD ceiling is 27768 - 2048 = 25,720 B exactly
# (docs/SH-G21-NOTES.md sec "The ceiling is the ring"). measured + 32
# would be 25,736 -- SIXTEEN BYTES PAST THE WALL, so the tripwire would
# have gone green on an image that had already run into the ring. The
# ring assertion near ALI_NAMES does NOT catch that: it checks the
# ring's own placement (ED_HRING + ED_HSIZE == ALI_NAMES), not whether
# the low image reached it. This tripwire is the only guard, so it is
# pinned AT the wall. 16 B of room remain; the next low growth must
# come out of the low image.
SH_BUDGET = 25720
SH_SEG_BUDGET = 7907
SH_LOAD_BASE = 0x0800                   # inc/mm.procbank.equ
SH_WINDOW_TOP = 0xBF00                  # the MLI-compat page; sh.s `err`
SH_BIN = 'build/sh.bin'


def check_sh_budget():
    """Gate: sh's LOW image and its $E000 segment each stay under their
    own tripwire; the whole file is reported alongside them."""
    failures = []
    print()
    print(f'[check-modules] sh low-image tripwire ({SH_BUDGET}B) + '
          f'segment tripwire ({SH_SEG_BUDGET}B), docs/SH-SUBSET.md 7.6')
    # SH-ROOM (review M): check-modules is STATIC (Makefile, "The
    # kernel .SYSTEM image-size ratchet": it must not need built
    # artifacts), so every check that reads sh.s's own symbols - the walls,
    # the budgets, the dead-copy containment list, SH_DEADCP_END - runs on
    # a clean tree from arena.symbol_table, which re-assembles sh.s in a
    # private directory. Only the file-size sum (low + segments == the
    # built file) needs sh.bin and sits behind this sentinel; before this
    # an absent sh.bin skipped EVERYTHING and a clean tree passed with the
    # alias block placed outside the dead copy.
    total = os.path.getsize(SH_BIN) if os.path.exists(SH_BIN) else None
    if total is None:
        print(f'   {SH_BIN} not built -- the file-size sum is skipped; '
              f'every symbol-based check below still runs')
    try:
        syms = arena.symbol_table('sh')
    except Exception as exc:                        # noqa: BLE001
        failures.append(
            f'could not read sh.s\'s own merlin32 -v1 symbol dump '
            f'({exc}) -- the low-image/segment split cannot be measured '
            f'from the file size alone, so this is a failure and not a '
            f'skip.')
        return failures
    missing = [s for s in ('SH_SEG_LOW', 'SH_SEG_BEG', 'SH_SEG_END',
                           'SH_SEG2_SRC', 'SH_SEG2_BEG', 'SH_SEG2_END',
                           'SH_FILE_END', 'SH_ARENA_END', 'SH_SEG1_LIM',
                           'SH_SEG2_LIM', 'SH_DEADCP_END')
               if s not in syms]
    if missing:
        failures.append(
            f'src/bin/sh.s no longer defines {", ".join(missing)} -- the '
            f'second code segment (docs/SH-SUBSET.md ruling 7.6) is the '
            f'only reason sh.bin is bigger than its resident image, and '
            f'without those labels this gate would silently start '
            f'measuring nothing.')
        return failures
    low = syms['SH_SEG_LOW'] - SH_LOAD_BASE
    seg = syms['SH_SEG_END'] - syms['SH_SEG_BEG']
    seg2 = syms['SH_SEG2_END'] - syms['SH_SEG2_BEG']
    # SH-ROOM (R3): both walls are EXPLICIT symbols now, independent of
    # whatever lives behind them. sh.s's `err */SH_SEG2_LIM` fires AT
    # the wall's first byte: the segment may end at wall-1, so one byte
    # less than the span. (This was derived from ED_HRING; the table or
    # ring moving out of the card must not move the wall with it.)
    global SH_SEG2_BUDGET
    SH_SEG2_BUDGET = min(SH_SEG2_BUDGET,
                         syms['SH_SEG2_LIM'] - syms['SH_SEG2_BEG'] - 1)
    # review L: pin each wall to its owner. A wrong SH_SEG1_LIM /
    # SH_SEG2_LIM equate would silently widen the budget now that the
    # budget is derived from them.
    if 'FFXX_PAGE' not in syms or syms['SH_SEG1_LIM'] != syms['FFXX_PAGE']:
        failures.append(
            f'SH_SEG1_LIM is ${syms["SH_SEG1_LIM"]:04X}, not FFXX_PAGE '
            f'(${syms.get("FFXX_PAGE", 0):04X}): segment 1 must stop at '
            f'the kernel\'s door and nowhere else')
    # SH-ROOM2 step 2a: the ring left the top of the bank, so the wall is
    # the bank boundary itself (the first segment's base).
    if ('PRC_LC_COMMON' not in syms
            or syms['SH_SEG2_LIM'] != syms['PRC_LC_COMMON']):
        failures.append(
            f'SH_SEG2_LIM is ${syms["SH_SEG2_LIM"]:04X}, not PRC_LC_COMMON '
            f'(${syms.get("PRC_LC_COMMON", 0):04X}): segment 2 must stop '
            f'at the first segment\'s base and nowhere else')
    if total is not None and low + seg + seg2 != total:
        failures.append(
            f'{SH_BIN} is {total}B but the listing says low {low}B + '
            f'segment {seg}B + segment 2 {seg2}B = {low + seg + seg2}B '
            f'-- merlin32 is no longer laying the `org` blocks down '
            f'CONTIGUOUSLY in the flat output, which is the assumption '
            f'SEG_INIT\'s low copy rests on (src/bin/shsegi.s).')
    # TRAPTAB and CSFORWORDS sit inside the segments' low copy (sh.s,
    # "TRAPTAB and CSFORWORDS"): above the low image, below the file's
    # end. The end is an assembly-time `err`; the start cannot be.
    # SH-PREFIX Phase 0 filled the rest of the copy with the arena's
    # write-before-read buffers (sh.s, the block after CSFORWORDS).
    for cell in ('TRAPTAB', 'CSFORWORDS', 'GLOBBUF', 'LINEBUF',
                 'TOKPTR', 'HD_BODY', 'HDLINEBUF', 'RAWLINE', 'EXPBUF',
                 'OPBUF', 'RDBUF', 'RL_BUF', 'SH_PATHSRC',
                 'TOKOFF', 'PRETOK',
                 'ED_HRING',
                 'ALI_NAMES', 'ALI_VALS', 'ALI_END'):
        if cell not in syms or not (
                syms['SH_SEG_LOW'] <= syms[cell] < syms['SH_FILE_END']):
            failures.append(
                f'{cell} (${syms.get(cell, 0):04X}) is not inside the '
                f'segments\' low copy ${syms["SH_SEG_LOW"]:04X}-'
                f'${syms["SH_FILE_END"] - 1:04X}: the low image outgrew '
                f'the literal address sh.s gives it (or the cell moved).')
    # SH-ROOM2 step 3 (C-H3): the history ring lives in the dead copy,
    # directly below the alias table. Its old owner pin (SH_SEG2_LIM <=
    # ED_HRING) is gone with the move, so nothing else says the ring
    # sits where SEG_INIT has already read, nor that it stays clear of
    # the table above it: assert both ends here, as symbols.
    if 'ED_HRING' in syms and 'ED_HSIZE' in syms:
        ring, rend = syms['ED_HRING'], syms['ED_HRING'] + syms['ED_HSIZE']
        if ring < syms['SH_SEG_LOW']:
            failures.append(
                f'ED_HRING (${ring:04X}) is below SH_SEG_LOW '
                f'(${syms["SH_SEG_LOW"]:04X}): the ring would sit on live '
                f'low-image code, not in the segments\' dead copy')
        # SH-ROOM2 (review L1): the size and the exact endpoint,
        # not just "no later than": a ring that shrank (ED_HSIZE $0100)
        # still ended at or before ALI_NAMES and stayed green.
        if syms['ED_HSIZE'] != 0x200:
            failures.append(
                f'ED_HSIZE is ${syms["ED_HSIZE"]:04X}, not $0200: the '
                f'history ring is 512 B by design (eight entries of up '
                f'to 128 B hold three full lines; check-shedit histcap)')
        if rend > syms['ALI_NAMES']:
            failures.append(
                f'the history ring ends at ${rend:04X}, past ALI_NAMES '
                f'(${syms["ALI_NAMES"]:04X}): it overlaps the alias table')
        elif rend != syms['ALI_NAMES']:
            failures.append(
                f'the history ring ends at ${rend:04X}, short of '
                f'ALI_NAMES (${syms["ALI_NAMES"]:04X}): ED_HRING + '
                f'ED_HSIZE must equal ALI_NAMES exactly')
        if rend > syms['SH_FILE_END']:
            failures.append(
                f'the history ring ends at ${rend:04X}, past the file end '
                f'(${syms["SH_FILE_END"]:04X}): it overlaps the arena')
    # SH-ROOM2 step 2b/4: where the cold bundle lives, and which strings
    # stay below $D000. Code moved into a segment keeps a plain `jsr`
    # from the low image, but anything a SYSCALL receives is refused by
    # copyin at >= $D000 (learning:01M2MCYEXW7JA7ZPZ4F7GC2217) and the
    # symptom is a message that silently never prints, so each such
    # string is pinned by symbol, not by the gate that happens to print
    # it. The two lists are the notes' (docs/SH-ROOM2-NOTES.md sec 5).
    for cell in SH_SEG2_RESIDENT:
        if cell not in syms or not (
                syms['SH_SEG2_BEG'] <= syms[cell] < syms['SH_SEG2_END']):
            failures.append(
                f'{cell} (${syms.get(cell, 0):04X}) is not inside segment '
                f'2 (${syms["SH_SEG2_BEG"]:04X}-${syms["SH_SEG2_END"] - 1:04X})'
                f': the cold bundle moved back, or out of the notes\' list')
    for cell in SH_LOW_ONLY:
        if cell not in syms or not (
                SH_LOAD_BASE <= syms[cell] < syms['PRC_LC_BANK2']):
            failures.append(
                f'{cell} (${syms.get(cell, 0):04X}) is not below $D000: a '
                f'syscall (PUTS/PR_ERRAX/an MLI parmlist) receives it and '
                f'copyin refuses a process address >= $D000')
    # SH-ROOM (R1): the dead-copy block emits nothing, so the file end is
    # NOT lowered by anything that moves into it; what it costs is HIGH
    # WATER, which must stay below SH_FILE_END or the block's tail
    # runs into the arena above the file (window cost) -- sh.s's own
    # `err */SH_FILE_ENDP1` is the hard stop, this is the visible figure.
    if syms['SH_DEADCP_END'] > syms['SH_FILE_END']:
        failures.append(
            f'the dead-copy block ends at ${syms["SH_DEADCP_END"]:04X}, '
            f'past the file end ${syms["SH_FILE_END"]:04X}: it overlaps '
            f'the arena')
    else:
        print(f'   dead copy  high water ${syms["SH_DEADCP_END"]:04X} / '
              f'file end ${syms["SH_FILE_END"]:04X}, '
              f'{syms["SH_FILE_END"] - syms["SH_DEADCP_END"]}B spare')
    if syms['SH_SEG2_SRC'] != syms['SH_SEG_LOW'] + seg:
        failures.append(
            f'SH_SEG2_SRC is ${syms["SH_SEG2_SRC"]:04X} but the first '
            f'segment\'s low copy ends at '
            f'${syms["SH_SEG_LOW"] + seg:04X} -- SEG_INIT reads the '
            f'second segment from the wrong place.')
    # -- THE ARENA ANCHOR, asserted rather than trusted. sh.s's THIRD
    # -- `org` (docs/SH-SUBSET.md ruling 7.6) is what puts libabss.s's
    # -- `dum *` ABOVE the segment's low copy instead of on top of it,
    # -- and it is one expression away from being wrong. Get it wrong
    # -- and TWO things break at once: the low copy stops surviving a
    # -- warm respawn (check-shwarm's job to catch), AND LIBA_ZPG stops
    # -- being LOAD_BASE+imagelen, which is where the kernel zeroes its
    # -- page (src/kernel/bankcopy.s BC_ZPAGE) with no metadata at all
    # -- -- so liba's zero-requiring cells silently stop starting at
    # -- zero. MEASURED 2026-09-16 by doing exactly that: `org
    # -- SH_SEG_LOW` alone assembled clean, passed check-purity AND
    # -- this gate, and only died on the emulator. check_purity.py
    # -- checks that the anchor is LIBA_BSSEND-chained and that the two
    # -- spellings of 256 agree; NOTHING checked the address itself.
    if (total is not None and 'LIBA_ZPG' in syms
            and syms['LIBA_ZPG'] != SH_LOAD_BASE + total):
        failures.append(
            f'src/bin/sh.s: LIBA_ZPG is ${syms["LIBA_ZPG"]:04X} but '
            f'LOAD_BASE+imagelen is ${SH_LOAD_BASE + total:04X} -- the '
            f'bss arena is not anchored where the kernel zeroes its '
            f'page. Check sh.s\'s LAST `org` (it must be '
            f'SH_SEG2_SRC+SH_SEG2_END-SH_SEG2_BEG, winding the PC past '
            f'both segments\' low copies), docs/SH-SUBSET.md ruling '
            f'7.6.')
    if low > SH_BUDGET:
        failures.append(
            f'{SH_BIN}: the LOW resident image is {low}B, {low - SH_BUDGET}B '
            f'over the {SH_BUDGET}B tripwire -- docs/SH-SUBSET.md sec 1/7 '
            f'says this means a whole subsystem arrived unannounced; '
            f'discuss it, or move a COLD path into the $E000 segment '
            f'(ruling 7.6), but do not just trim a feature to squeeze '
            f'under.')
    else:
        print(f'   low image  {low:6d}B / {SH_BUDGET}B '
              f'({low / SH_BUDGET * 100:.1f}%)  $0800-'
              f'${syms["SH_SEG_LOW"] - 1:04X}')
    # TAB-A3 condition 3: the segment's size wall is an ASSEMBLY-TIME
    # `err */SH_SEG1_LIM` inside sh.s (learning 01M0MQDQWCXC1KRABA2VMYARYA:
    # an image-size gate cannot see an overrun), and the soft line
    # must sit below it.  Assert both, from the source and the symbol
    # table. SH-ROOM (R3): the wall is an explicit symbol, no longer
    # the address of the alias table that used to sit behind it.
    sh_src = open('src/bin/sh.s').read()
    if not re.search(r'^\s+err\s+\*/SH_SEG1_LIM\b', sh_src, re.M):
        failures.append('src/bin/sh.s: the assembly-time wall '
                        '`err */SH_SEG1_LIM` behind the $E000 segment is '
                        'gone -- a size gate cannot see an overrun')
    if not re.search(r'^\s+err\s+\*/SH_SEG2_LIM\b', sh_src, re.M):
        failures.append('src/bin/sh.s: the assembly-time wall '
                        '`err */SH_SEG2_LIM` behind the $D000 segment is '
                        'gone -- a size gate cannot see an overrun')
    if syms['SH_SEG1_LIM'] - 0xE000 < SH_SEG_BUDGET:
        failures.append(f'SH_SEG_BUDGET {SH_SEG_BUDGET} is past the '
                        f'SH_SEG1_LIM wall')
    if seg > SH_SEG_BUDGET:
        failures.append(
            f'{SH_BIN}: the $E000 segment is {seg}B, '
            f'{seg - SH_SEG_BUDGET}B over the {SH_SEG_BUDGET}B tripwire '
            f'-- PRC_LC_COMMON only has 7936B and sh.s\'s own '
            f'`err */$FF00` is the wall behind this one.')
    else:
        print(f'   segment    {seg:6d}B / {SH_SEG_BUDGET}B '
              f'({seg / SH_SEG_BUDGET * 100:.1f}%)  $E000-'
              f'${syms["SH_SEG_END"] - 1:04X}')
    if seg2 > SH_SEG2_BUDGET:
        failures.append(
            f'{SH_BIN}: the $D000 segment is {seg2}B, '
            f'{seg2 - SH_SEG2_BUDGET}B over the {SH_SEG2_BUDGET}B bank.')
    else:
        print(f'   segment 2  {seg2:6d}B / {SH_SEG2_BUDGET}B '
              f'({seg2 / SH_SEG2_BUDGET * 100:.1f}%)  $D000-'
              f'${syms["SH_SEG2_END"] - 1:04X}')
    print(f'   whole file {low + seg + seg2:6d}B (low + both segments from '
          f'the listing; reported, '
          f'not gated -- the low copies are carried by the same one '
          f'spawn read)')
    # -- THE FIFTH BUDGET: the process window (KFIX3-NOTES 2.2). A byte
    # -- of segment code costs a byte of window exactly like a byte of
    # -- low code (the segments' low copies sit in the file, the arena
    # -- above them), so every other line above can be green and the
    # -- shell still not fit. The hard wall is sh.s's `err */$BF00`;
    # -- this is the margin that wall leaves, printed beside the rest.
    window = SH_WINDOW_TOP - SH_LOAD_BASE
    used = syms['SH_ARENA_END'] - SH_LOAD_BASE
    margin = SH_WINDOW_TOP - syms['SH_ARENA_END']
    if margin < 0:
        failures.append(
            f'{SH_BIN}: the arena ends at ${syms["SH_ARENA_END"]:04X}, '
            f'{-margin}B past ${SH_WINDOW_TOP:04X} -- the process '
            f'window. (sh.s\'s own `err */$BF00` should have stopped '
            f'the assembly first.)')
    else:
        print(f'   window     {used:6d}B / {window}B '
              f'({used / window * 100:.1f}%)  $0800-'
              f'${syms["SH_ARENA_END"] - 1:04X}, margin {margin}B to '
              f'${SH_WINDOW_TOP:04X} (file + arena; segment bytes count, '
              f'docs/SH-SUBSET.md 7.9)')
    return failures


def check_label_length():
    """Gate on symbols too long for real Merlin-8, over the same DERIVED
    scanned file set check_line_length() uses (scanned_file_set()) --
    see LONG_LINE_BASELINE's comment. This is a hard gate at zero, not a
    ratchet: widening coverage can expose a real over-long label in a
    newly-visible file, and that is a bug to fix (see
    scripts/shorten_labels.py), never a reason to add an exemption."""
    failures = []
    print()
    print(f'[check-modules] real-Merlin label limit '
          f'({MERLIN_LABEL_LIMIT} chars, ":" included)')
    scanned, _orphans = scanned_file_set()
    over = []
    for path in sorted(scanned):
        for n, line in enumerate(open(path, errors='replace'), 1):
            # Column 0 is Merlin's label field, so that is the
            # primary form. But merlin32 is LENIENT about the label
            # column where real Merlin-8 is not, so a definition
            # written with leading whitespace assembles on the host
            # and is rejected on the target -- exactly the class
            # this gate exists to catch, and exactly what it used
            # to miss. Found 2026-08-20 when real Merlin rejected a
            # 14-char label that merlin32 AND this scanner both
            # accepted. The tree was clean at the time (the author
            # had already renamed it), so this closes a latent hole
            # rather than a live one.
            m = re.match(r'^(:?[A-Za-z][A-Za-z0-9_.]*)', line) or \
                re.match(r'^\s+(:?[A-Za-z][A-Za-z0-9_.]*)\s+(?:equ|=)\s',
                         line, re.I)
            if m and len(m.group(1)) > MERLIN_LABEL_LIMIT:
                over.append(f'{check_manifests.rel(path)}:{n}: {m.group(1)} '
                            f'({len(m.group(1))} chars)')
    if over:
        print(f'   {len(over)} symbol(s) exceed the limit')
        for o in over[:10]:
            print(f'     {o}')
        failures.append(
            f'{len(over)} symbol(s) exceed real Merlin\'s '
            f'{MERLIN_LABEL_LIMIT}-character label limit; real Merlin would '
            f'reject each with "Bad label in line: N" and then fail every '
            f'reference to it. Shorten them (see scripts/shorten_labels.py '
            f'for the naming conventions).')
    else:
        print('   0 -- every symbol in the tree is a legal Merlin-8 label')
    return failures


def check_equ_forward_refs():
    """Real-Merlin EQU forward-reference audit -- folded in here rather
    than as its own `make` target: check-modules is already the house's
    static real-Merlin-dialect-hazard gate over this exact file scope
    (see check_line_length/check_label_length above), no emulator
    involved, same "static, ratchet-or-gate" posture. A new top-level
    target would also grow check-all's fixed gate count for no reason
    -- this finding is exactly as static and exactly as scoped as its
    two neighbors. scripts/check_equ_fwd.py stays independently
    runnable (`python3 scripts/check_equ_fwd.py`) for a fast, isolated
    re-check; this just reuses its analysis, not a copy of it. See that
    module's docstring for the hazard itself and the documented same-
    file-only (no cross-`put` file) limitation.
    """
    failures = []
    print()
    print('[check-modules] real-Merlin EQU forward-reference audit '
          '(scripts/check_equ_fwd.py; src/kernel/*.s excluded -- '
          'check-dual already byte-compares it)')
    paths = []
    for pattern in check_equ_fwd.FILE_GLOBS:
        paths.extend(sorted(
            glob.glob(os.path.join(check_equ_fwd.ROOT, pattern))))
    total = 0
    for path in paths:
        rel = os.path.relpath(path, check_equ_fwd.ROOT)
        for lineno, sym, tok, tok_def_line in check_equ_fwd.check_file(path):
            total += 1
            failures.append(
                f'{rel}:{lineno}: `{sym} equ ...` references `{tok}`, '
                f"not equ'd until {rel}:{tok_def_line} -- real Merlin "
                f'caches the wrong pass-1 value here (merlin32 does '
                f'not); move {sym} below its dependency.')
    if total == 0:
        print(f'   0 -- no EQU references a same-file symbol equ\'d '
              f'later ({len(paths)} files scanned)')
    else:
        print(f'   {total} forward reference(s) across {len(paths)} '
              f'files scanned')
    return failures


def check_unit_equ_forward_refs():
    """The CROSS-`put` half of the EQU forward-reference hazard, over
    each unit's real expansion order -- scripts/check_equ_fwd.py's
    second audit. See that module's own header for the shape, the two
    calibration runs it is derived from, and the gap it does not cover.

    A RATCHET, not a hard zero: the sites are real (real Merlin-8
    refuses to assemble those units) but several need a constant moved
    to a different file, not merely moved up. Shrink-only -- lower
    UNIT_IMM_ALLOWANCE as they are fixed; it may never rise.
    """
    failures = []
    print()
    print('[check-modules] EQU forward references in IMMEDIATE operands, '
          "over each unit's put-expansion order "
          '(scripts/check_equ_fwd.py)')
    rows, roster = check_equ_fwd.unit_immediate_sites()
    allow = check_equ_fwd.UNIT_IMM_ALLOWANCE
    want_roster = check_equ_fwd.UNIT_ROSTER_EXPECTED
    if roster != want_roster:
        failures.append(
            f'the audit ran over {roster} top-level unit(s), not the '
            f'pinned {want_roster}. A site count is only shrink-only '
            f'while the roster it is counted over holds: a unit '
            f'leaving the set takes its forward references with it '
            f'and LOWERS the number without fixing anything. If the '
            f'roster change is intended, update '
            f'check_equ_fwd.UNIT_ROSTER_EXPECTED in the same commit.')
    if len(rows) > allow:
        for f, ln, sym, df, dln, text in rows[:12]:
            print(f'   {f}:{ln}: #{sym} -- not equ\'d until {df}:{dln}'
                  f'   |{text}|')
        failures.append(
            f'{len(rows)} EQU-forward-reference site(s) in immediate '
            f'operands, up from {allow}. Real Merlin-8 refuses to '
            f'assemble a unit containing one ("Illegal forward '
            f'reference", reported against the equ\'s own line), so '
            f'each is a unit that cannot self-host. Move the `equ` '
            f'above its first use -- into an earlier-`put` file if the '
            f'use is in another module (inc/zp.equ is `put` first '
            f'by all 43 units that `put` libabss.s, which is why the '
            f'seek.s/libabss.s constants moved there). Then lower '
            f'check_equ_fwd.UNIT_IMM_ALLOWANCE to match.')
    elif len(rows) < allow:
        failures.append(
            f'{len(rows)} EQU-forward-reference site(s), DOWN from the '
            f'allowance of {allow}. Lower '
            f'check_equ_fwd.UNIT_IMM_ALLOWANCE to {len(rows)} so the '
            f'slack cannot become a hiding place.')
    else:
        print(f'   {len(rows)} site(s), at the allowance -- shrink-only '
              f'(S9 step 5: each is a unit `as` cannot yet assemble)')
    return failures


def check_manifest_lists():
    """"Which files are involved" cross-check -- folded in here rather
    than as its own `make` target, same reasoning as
    check_equ_forward_refs() above: check-modules is already the house's
    static structural-hazard gate over this exact tree, no emulator
    involved, and a new top-level target would grow check-all's fixed
    gate count for no reason. scripts/check_manifests.py stays
    independently runnable (`python3 scripts/check_manifests.py`). See
    that module's docstring for the four historical instances this
    catches (a bug class that hit four times in one day, 2026-08-19/20:
    docs/AS-P10-ENUMERATION.txt, build_ascore_image.py's PUT_INCLUDED,
    build_maux_src_image.py's MODULES, and a kernel module gaining a
    nested `put` -- see check_manifests.py's module docstring)."""
    print()
    print('[check-modules] manifest-list cross-check '
          '(scripts/check_manifests.py -- "which files are involved" '
          'lists, derived from source, not accepted on report)')
    return check_manifests.run_all()


def check_userland(includes):
    """Boundary rules for src/liba (the library) and src/bin (programs).

    Userland is heading the same way as the kernel -- separately assembled REL
    modules -- but with a sharper reason. `make check-rel` proved Merlin's
    linker includes WHOLE modules: link a module and you pay for every byte of
    it, referenced or not. So a liba module's SIZE is what a program pays, and
    module granularity IS the packaging policy (docs/REL-LIBA-SPIKE.md).

    Rules, mirroring the kernel's:
      * a liba module may reference its own symbols, another liba module's,
        inc/*.equ, or src/liba/*.equ (shared definitions every program
        gets) -- never a symbol only a PROGRAM defines, which is the same
        upward reach that stops a module being assembled on its own;
      * no symbol defined by two liba modules (a link collision once these are
        REL objects);
      * no liba module shadowing a name inc/ or liba/*.equ already owns.
    """
    failures = []
    liba_equ = {}
    for path in sorted(glob.glob('src/liba/*.equ')):
        d, _ = scan(path)
        liba_equ[os.path.basename(path)] = d
    liba_globals = set().union(*liba_equ.values()) if liba_equ else set()

    liba = {p: scan(p) for p in sorted(glob.glob('src/liba/*.s'))}
    bins = {p: scan(p) for p in sorted(glob.glob('src/bin/*.s'))}

    liba_defs = {}
    for path, (d, _) in liba.items():
        for sym in d:
            liba_defs.setdefault(sym, set()).add(os.path.basename(path))
    bin_only = {}
    for path, (d, _) in bins.items():
        for sym in d:
            if sym not in liba_defs and sym not in liba_globals:
                bin_only.setdefault(sym, set()).add(os.path.basename(path))

    for path, (defined, used) in liba.items():
        mod = os.path.basename(path)
        for sym in sorted(used):
            if (sym in defined or sym in includes or sym in liba_globals
                    or sym in liba_defs):
                continue
            if sym in bin_only:
                failures.append(
                    f'liba/{mod}: references {sym!r}, which only a PROGRAM '
                    f'defines ({", ".join(sorted(bin_only[sym]))}). A library '
                    f'module reaching up into its caller cannot be assembled '
                    f'or linked on its own.')
        shadow = defined & (includes | liba_globals)
        if shadow:
            failures.append(
                f'liba/{mod}: re-declares {sorted(shadow)}, already owned by '
                f'inc/*.equ or src/liba/*.equ.')

    for sym in sorted(s for s, owners in liba_defs.items() if len(owners) > 1):
        failures.append(
            f'liba: {sym!r} is defined by more than one module '
            f'({", ".join(sorted(liba_defs[sym]))}) -- a symbol collision once '
            f'these are separately linked REL objects.')

    # What each program actually pays for. `put` lines are the dependency
    # list today; under REL they become the names file `ld` generates.
    print()
    print('[check-modules] userland: what each program pulls in from liba')
    print('[check-modules]   liba cost is CODE LINES (comments and blanks '
          'excluded). Source BYTES are a bad')
    print('[check-modules]   proxy here -- liba is roughly half comment, so '
          'echo pulls ~24KB of source but')
    print('[check-modules]   builds to well under 1KB. The built column is '
          'the truth, once `make` has run.')
    def code_lines(path):
        """Non-blank, non-comment source lines -- what actually assembles."""
        n = 0
        for raw in open(path, errors='replace'):
            t = raw.strip()
            if t and not t.startswith('*') and not t.startswith(';'):
                n += 1
        return n

    for path in sorted(bins):
        mods = parse_put_list(path)
        total = sum(code_lines(os.path.join('src/liba', m)) for m in mods)
        built = os.path.join('build', os.path.basename(path)[:-2] + '.bin')
        built_s = (f'{os.path.getsize(built):>6}B'
                   if os.path.exists(built) else '     --')
        print(f'   {os.path.basename(path):<8} own {code_lines(path):>5} lines'
              f'  +liba {total:>5} lines  built {built_s}  '
              f'{" ".join(sorted(mods))}')

    print('[check-modules] liba modules -- a program pays for ALL of one it '
          'links (see make check-rel)')
    for path in sorted(liba):
        mod = os.path.basename(path)
        exports = set()
        for other, (_, oused) in {**liba, **bins}.items():
            if other != path:
                exports |= (liba[path][0] & oused)
        users = sum(1 for b in bins
                    if f'put   ../liba/{mod}' in open(b, errors='replace').read())
        print(f'   {mod:<12} {code_lines(path):>4} lines  '
              f'{len(exports):>3} symbol(s) used elsewhere  '
              f'pulled by {users} program(s)')
    return failures


def program_refs(path):
    """Every symbol a program's own text references: its source plus
    the source of each BIN-LOCAL put (expr.eval.s, testeval.s,
    sedexec.s), which is part of the program's own text, so ITS
    references are the program's references -- without this, a program
    split into a local module (sed.s/sedexec.s, the first split forced
    by check-dialect's source-buffer budget) reports every liba module
    the split half calls as dead. Found 2026-08-23 when regex.s and
    mli.s -- both reached only from sedexec.s -- were flagged."""
    used = set(scan(path)[1])
    for line in open(path, errors='replace'):
        lm = re.match(r'^\s+put\s+([A-Za-z0-9_.]+\.s)\s*$',
                      line.split(';')[0], re.IGNORECASE)
        if not lm:
            continue
        local = os.path.join(os.path.dirname(path), lm.group(1))
        if os.path.exists(local):
            used |= set(scan(local)[1])
    return used


def check_dead_puts():
    """Gate: FAIL a build that `put`s a liba module none of its code
    transitively needs (docs/FAT.md sec 9).

    `put` is whole-file textual inclusion, not dead-code elimination, so a
    program pays for the full assembled weight of every liba module it
    names -- whether or not it calls a single symbol from it. A one-time
    audit (2026-08-21) found nine such lines costing 1,125 bytes across
    nine utilities; nothing stopped a tenth from drifting back in. This is
    that ratchet, done structurally rather than by hand.

    THE SUBTLETY. A naive per-util check is wrong: a first pass at the
    audit flagged 25 utils, and most were false positives, because a liba
    module can itself depend on another. print.s calls STRLEN at its own
    line 53 (verified by reading the source, not assumed), so any util
    that legitimately needs print.s also needs string.s even though the
    util's own source never names a string routine.

    So "dead" is a TRANSITIVE reachability question, not a per-symbol one.
    Starting from what the program's own source references, follow into
    whichever put-module supplies each referenced symbol, then follow
    THAT module's own references the same way (print.s -> STRLEN pulls in
    string.s even though the program itself never touches string.s). A
    put is dead only if this walk never reaches it.

    The walk is built fresh per program from exactly the modules that
    program's own `put` list names, rather than from a hardcoded
    module-to-module table -- the same liba module is a leaf dependency
    in one program (ps.s and argv.s: ps does not use getopt.s, so nothing
    pulls argv.s in behind it) and an interior one, reached only through
    another module, in the next (cat.s and string.s: cat never names a
    string routine, string.s is reached only because cat also pulls
    print.s, which does). A fixed edge table would have to be kept in
    sync by hand; deriving it from each program's actual put list cannot
    drift the way the table it replaces could.

    FALSE-POSITIVE POSTURE. This reuses scan(), the same operand scanner
    every other section of this file trusts to decide what a line of
    Merlin source references -- a macro invocation, a bare `equ` use, and
    a `jsr` are all "a reference" to it already, consistently across the
    whole gate. So there is no separate, stricter notion of "really used"
    invented here that could cry wolf where the rest of the file would
    stay quiet; anything scan() would count as a reference elsewhere in
    this file also counts as a reference here, keeping a module reachable.
    A tree-wide run below found zero cases needing a manual allowance
    beyond that.
    """
    failures = []
    print()
    print('[check-modules] dead `put` audit (docs/FAT.md sec 9 -- a put '
          'whose module contributes no reachable symbol)')
    liba_scan = {os.path.basename(p): scan(p)
                 for p in sorted(glob.glob('src/liba/*.s'))}
    total_dead = 0
    for path in sorted(glob.glob('src/bin/*.s')):
        mods = parse_put_list(path)
        if not mods:
            continue
        bin_used = program_refs(path)

        # Symbol -> owning module, restricted to modules THIS program
        # actually puts -- a module's role (leaf vs. interior dependency)
        # is a property of the includer's put list, not of the module in
        # isolation, so the map has to be rebuilt per program.
        owner = {}
        for m in mods:
            if m not in liba_scan:
                continue          # a bin-local put (e.g. expr.eval.s)
            for sym in liba_scan[m][0]:
                owner.setdefault(sym, m)

        reached = set()
        seen_syms = set()
        frontier = list(bin_used)
        while frontier:
            sym = frontier.pop()
            if sym in seen_syms:
                continue
            seen_syms.add(sym)
            m = owner.get(sym)
            if m and m not in reached:
                reached.add(m)
                frontier.extend(liba_scan[m][1])  # that module's own refs

        for m in mods:
            if m not in liba_scan or m in reached:
                continue
            total_dead += 1
            failures.append(
                f'{path}: `put   ../liba/{m}` is dead -- neither '
                f'{os.path.basename(path)} nor any liba module it '
                f'transitively needs references a symbol {m} defines. '
                f'Delete the put line (docs/FAT.md sec 9).')
    if total_dead == 0:
        print('   0 dead puts -- every `put ../liba/*.s` line contributes '
              'a reachable symbol')
    else:
        print(f'   {total_dead} dead put(s) found -- see FAIL lines below')
    return failures


# --- Dead ROUTINES in a live module (KFIX8) -------------------------
#
# check_dead_puts() asks about whole files. KFIX7 added RD_CANON to
# readsyn.s, and the ratchet had nothing to say that mount and umount
# carried ~790 bytes of that module they never call, nor that nine
# programs carried its 13-byte RD_FOLD: the FILE was reached (they call
# SC_VROOT in it), the ROUTINES were not. A routine-level audit of every
# liba module would flag the whole tree (string.s, stdio.s and friends
# are general libraries each program uses a corner of), so it is OPT-IN:
# a module is listed here when it is meant to be MINIMAL for everything
# that puts it, and then no routine of it may be dead in any program.
# The cost of being listed is a split like readsyn.s / readsys.s /
# readfold.s: one file per distinct set of callers.
ROUTINE_AUDITED = ('readsyn.s', 'readsys.s', 'readfold.s')
TERMINAL_OPS = {'rts', 'rti', 'jmp', 'bra', 'brk'}
DATA_OPS = {'dfb', 'dw', 'da', 'ddb', 'asc', 'dci', 'ds', 'hex', 'str',
            'strl', 'inv', 'rev', 'fls', 'txt'}
EQU_OPS = {'equ', '='}


def routine_spans(path):
    """[(label, refs, falls)] for each non-equate global label of a
    module, in file order. A span runs to the next global label; its
    refs are the symbols its lines reference (local labels belong to
    the span that holds them). `falls` is true when the span can run
    into the next one: its last opcode is not rts/rti/jmp/bra/brk and it
    is code, not data."""
    spans = []
    cur = None
    for raw in open(path, errors='replace'):
        if not raw.strip() or raw.lstrip().startswith('*'):
            continue
        line = raw.split(';')[0].rstrip('\n')
        if not line.strip():
            continue
        parts = line.split()
        has_label = line[:1] not in (' ', '\t')
        m = IDENT.match(line) if has_label else None
        start = 1 if not has_label else 2
        op = parts[start - 1].lower() if len(parts) >= start else ''
        if m and op in EQU_OPS:
            cur = None
            continue
        if m:
            cur = {'label': m.group(0), 'refs': set(), 'op': '',
                   'data': False}
            spans.append(cur)
        if cur is None or not op:
            continue
        cur['op'] = op
        if op in DATA_OPS:
            cur['data'] = True
        if op in (STRING_OPS | FILE_OPS):
            continue
        if len(parts) > start:
            cur['refs'] |= operand_refs(parts[start])
    return [(c['label'], c['refs'],
             not c['data'] and c['op'] not in TERMINAL_OPS)
            for c in spans]


def dead_routines(path, mods, liba_scan, liba_spans):
    """Routine labels of the ROUTINE_AUDITED modules in `mods` that the
    program at `path` never reaches. Reachability starts at the
    program's own references; a reference into an audited module wakes
    that ONE routine (and the next, if it falls through), a reference
    into any other module wakes the whole module, as in
    check_dead_puts()."""
    owner = {}
    for m in mods:
        if m in liba_scan:
            for sym in liba_scan[m][0]:
                owner.setdefault(sym, m)
    index = {}                 # label -> (module, position in module)
    for m in mods:
        if m in ROUTINE_AUDITED and m in liba_spans:
            for i, (label, _r, _f) in enumerate(liba_spans[m]):
                index.setdefault(label, (m, i))
    reached, mods_seen, seen = set(), set(), set()
    frontier = list(program_refs(path))
    while frontier:
        sym = frontier.pop()
        if sym in seen:
            continue
        seen.add(sym)
        if sym in index:
            m, i = index[sym]
            while True:
                label, refs, falls = liba_spans[m][i]
                if label in reached:
                    break
                reached.add(label)
                frontier.extend(refs)
                if not falls or i + 1 >= len(liba_spans[m]):
                    break
                i += 1
            continue
        m = owner.get(sym)
        if m and m not in ROUTINE_AUDITED and m not in mods_seen:
            mods_seen.add(m)
            frontier.extend(liba_scan[m][1])
    dead = []
    for m in mods:
        if m in ROUTINE_AUDITED and m in liba_spans:
            dead += [(m, label) for label, _r, _f in liba_spans[m]
                     if label not in reached]
    return dead


def check_dead_routines(root=None):
    """Gate: no routine of a ROUTINE_AUDITED liba module is dead in a
    program that puts the module."""
    failures = []
    print()
    print('[check-modules] dead routine audit (KFIX8 -- a routine of '
          f'{", ".join(ROUTINE_AUDITED)} no program that puts it calls)')
    liba_scan = {os.path.basename(p): scan(p)
                 for p in sorted(glob.glob('src/liba/*.s'))}
    liba_spans = {m: routine_spans('src/liba/' + m)
                  for m in ROUTINE_AUDITED
                  if os.path.exists('src/liba/' + m)}
    total = 0
    for path in sorted(glob.glob('src/bin/*.s')):
        mods = parse_put_list(path)
        for m, label in dead_routines(path, mods, liba_scan, liba_spans):
            total += 1
            failures.append(
                f'{path}: {label} (in `put   ../liba/{m}`) is a dead '
                f'routine -- nothing the program reaches calls it. Move '
                f'it to the module only its callers put (KFIX8: '
                f'readsyn.s / readsys.s / readfold.s).')
    if total == 0:
        print('   0 dead routines in the audited modules')
    else:
        print(f'   {total} dead routine(s) -- see FAIL lines below')
    return failures


# --- Private spellings of the motherboard soft switches ---------------
#
# inc/mm.hw.equ owns the $C0xx soft switches. main()'s shadow
# check already catches a KERNEL module re-declaring an include global
# BY NAME -- that is what caught mli.s shadowing LCBANK2_RAM. Two gaps
# survived it, and this closes both:
#
#   1. Non-kernel code -- src/liba, src/bin, src/test -- is outside
#      that check entirely.
#   2. A DIFFERENT name for the SAME address is invisible to any
#      name-based check. src/liba/stdio.s calls $C083/$C08B
#      LC_FREE_RW/LC_KRN_RW; mm.hw.equ calls the same two
#      addresses LCBANK1_RAM/LCBANK2_RAM.
#
# Class 2 is the one with scar tissue, and the danger is not the
# duplication -- it is that the private names encode a POLICY ("KRN_RO"
# = the kernel's page, read-only) rather than a hardware state, and
# that policy is not universal. ld.s needs bank 2 WRITE-ENABLED
# ($C08B) and hung when a syscall restored it read-only. A name that
# asserts a policy is a name that will be believed.
#
# These files deliberately do NOT `put` mm.hw.equ and are not
# forced to: pulling a large .equ into a userland source costs source
# bytes against real Merlin's 41,215-byte buffer, which only
# check-dual sees. So this gate asserts the VALUES still agree rather
# than demanding the include -- docs/PLAN.md wave 5 item 6.
#
# Ratchet, in the house style of KNOWN_DEBT/KNOWN_DUPLICATES: the
# baseline records every private spelling that exists today with the
# reason it is tolerated. The gate fails if one drifts from its
# canonical value, if a NEW one appears, or if a baseline entry goes
# stale.
#
# canonical=None means "names a region BASE that merely collides with
# a switch at the same address" -- $C000 is CLR80STORE, KBD_DATA, and
# the base of the I/O page; naming the region is not aliasing a switch.
SOFTSWITCH_BASELINE = {
    # stdio's LC switch names moved to stdio.equ 2026-08-29 (S9 REL
    # route: a REL module cannot export an equate, and stdiofl.s --
    # stdio's split half -- references both).
    ('inc/stdio.equ', 'LC_FREE_RW'): ('C083', 'LCBANK1_RAM'),
    ('inc/stdio.equ', 'LC_KRN_RW'): ('C08B', 'LCBANK2_RAM'),
    ('src/test/bufiotestb.s', 'LC_FREE_RW'): ('C083', 'LCBANK1_RAM'),
    ('src/test/bufiotestb.s', 'LC_KRN_RW'): ('C08B', 'LCBANK2_RAM'),
    ('src/test/ffpage.size.s', 'RAMRDMAIN'): ('C002', 'RAMRDMAIN'),
    ('src/test/ffpage.size.s', 'RAMRDAUX'): ('C003', 'RAMRDAUX'),
    ('src/test/ffpage.size.s', 'RAMWRTMAIN'): ('C004', 'RAMWRTMAIN'),
    ('src/test/ffpage.size.s', 'RAMWRTAUX'): ('C005', 'RAMWRTAUX'),
    ('src/test/ffpage.size.s', 'BANKSEL'): ('C073', 'BANKSEL'),
    ('inc/mm.main.equ', 'IO_SLOTROM'): ('C000', None),
    ('inc/mm.procbnk2.equ', 'PRC_IO_SLTROM'): ('C000', None),
    # ser.s's SER_ACIA_PG is a $C0-PAGE base for slot-relative indexed
    # access to the 6551 ACIA ($C000,x with x = $88+slot*16, computed at
    # boot by SER_DETECT), NOT an access to the $C000 keyboard switch.
    # The per-slot device window ($C080+N*$10) has no canonical name.
    ('src/kernel/ser.s', 'SER_ACIA_PG'): ('C000', None),
}

# Only $C000-$C08F is mm.hw.equ's territory: $C000-$C07F are the
# motherboard soft switches and $C080-$C08F is the language card
# ("slot 0", which is not a real peripheral slot on the //e).
# $C090-$C0FF is PER-SLOT device space -- slot N lives at $C080+N*$10 --
# and belongs to whichever driver owns that card, not to the memory map.
# Scanning the whole $C0xx page flags src/kernel/ultraterm.s's CRTC
# registers ($C0B0-$C0B3, slot 3) and mm.mli.equ's AppleMouse 6821
# ($C0D0-$C0D3, slot 5), both of which are correctly named where they
# are. A gate that cries wolf about correct code gets switched off.
SOFTSWITCH_EQU = re.compile(
    r'^\s*([A-Za-z_][\w.]*)\s+equ\s+\$(C0[0-7][0-9A-Fa-f]|C08[0-9A-Fa-f])\b',
    re.I)


def check_softswitch_alias():
    """Gate on private spellings of mm.hw.equ's $C0xx switches."""
    failures = []
    print()
    print('[check-modules] private spellings of motherboard soft '
          'switches ($C0xx)')

    canon = {}
    for line in open('inc/mm.hw.equ', errors='replace'):
        m = SOFTSWITCH_EQU.match(line)
        if m:
            canon[m.group(1)] = m.group(2).upper()

    seen = set()
    # src/liba/*.equ joined the scan 2026-08-29 when stdio.equ was
    # split out carrying LC_FREE_RW/LC_KRN_RW -- before that, a liba
    # equ file could hold a private $C0xx spelling this gate never saw.
    paths = sorted(set(glob.glob('src/**/*.s', recursive=True)) |
                   set(glob.glob('inc/*.equ')) |
                   set(glob.glob('src/liba/*.equ')))
    for path in paths:
        if path.endswith('mm.hw.equ'):
            continue
        for n, line in enumerate(open(path, errors='replace'), 1):
            m = SOFTSWITCH_EQU.match(line)
            if not m:
                continue
            name, addr = m.group(1), m.group(2).upper()
            key = (path, name)
            if key not in SOFTSWITCH_BASELINE:
                failures.append(
                    f'{path}:{n}: {name} equ ${addr} is a NEW private '
                    f'spelling of a $C0xx soft switch. inc/mm.hw.equ '
                    f'owns these. Either use the canonical name, or add an '
                    f'entry to SOFTSWITCH_BASELINE saying why this file '
                    f'cannot include it -- deliberately, not by default.')
                continue
            seen.add(key)
            want_addr, canon_name = SOFTSWITCH_BASELINE[key]
            if addr != want_addr.upper():
                failures.append(
                    f'{path}:{n}: {name} is ${addr}, but the baseline '
                    f'records ${want_addr.upper()}. A private spelling '
                    f'moved.')
            elif canon_name is not None:
                if canon_name not in canon:
                    failures.append(
                        f'{path}:{n}: {name} aliases {canon_name}, which '
                        f'mm.hw.equ no longer defines. The alias is now '
                        f'anchored to nothing -- retarget or remove it.')
                elif canon[canon_name] != addr:
                    failures.append(
                        f'DRIFT: {path}:{n} says {name} = ${addr}, but '
                        f'mm.hw.equ now says {canon_name} = '
                        f'${canon[canon_name]}. This is exactly the split '
                        f'this gate exists to catch: the canonical switch '
                        f'was corrected and the private copy did not '
                        f'follow.')

    stale = set(SOFTSWITCH_BASELINE) - seen
    if stale:
        failures.append(
            f'SOFTSWITCH_BASELINE lists {sorted(stale)} but the tree no '
            f'longer declares them -- remove the stale entries so the '
            f'ratchet stays honest.')

    aliases = sum(1 for _, c in SOFTSWITCH_BASELINE.values() if c)
    if not failures:
        print(f'   {len(seen)} private spelling(s), all agreeing with '
              f'mm.hw.equ ({aliases} are same-address ALIASES a '
              f'name-based check cannot see)')
    else:
        print(f'   {len(failures)} problem(s) -- see FAIL lines below')
    return failures



def check_arena_anchor():
    """A program that `put`s a liba module carrying its OWN dum block must
    chain its arena from THAT block's end, not from LIBA_BSSEND.

    regexbss.s is `dum LIBA_BSSEND ... REGEX_BSSEND dend`. A program that
    puts it and anchors its own arena `dum LIBA_BSSEND` has two dum blocks
    at one address: RE_MATCH's group priming ($FF over RE_GRPST, 18 bytes)
    lands on the program's first cells. Nothing in either assembler
    objects. Found 2026-09-12 in the more(1) rewrite: the FIRST search
    landed on the wrong line, the second was right (commons
    learning:01M28FXZHBN4V6T4NT6PZZ4M4S). grep and sed already chain
    from REGEX_BSSEND; this makes the rule a check instead of a comment.
    """
    rules = {'../liba/regexbss.s': 'REGEX_BSSEND'}
    fails = []
    for path in sorted(glob.glob('src/bin/*.s')):
        text = open(path, encoding='latin-1').read()
        puts = set(re.findall(r'^\s+put\s+(\S+)', text, re.M))
        anchors = re.findall(r'^\s+dum\s+(\S+)', text, re.M)
        for mod, end in rules.items():
            if mod in puts and 'LIBA_BSSEND' in anchors:
                fails.append(
                    f'{os.path.relpath(path, ROOT)}: puts {mod} but anchors '
                    f'an arena at LIBA_BSSEND -- that module\'s own dum block '
                    f'starts there too; chain from {end}.')
    print()
    print('[check-modules] arena anchors: a program that puts a liba module '
          'with its own dum block chains from that block\'s end')
    if fails:
        for f in fails:
            print(f'[check-modules] FAIL: {f}', file=sys.stderr)
        return fails
    print('   0 overlapping arenas')
    return []


# The directories a put/use operand may name after its leading `..`
# segments are dropped. `inc` lives at the repo root on the host and at
# /SRC/INC on the guest; the rest are src/ subdirectories and map to
# /SRC/<NAME>. See docs/LAYOUT.md.
PUT_SEGMENTS = ('inc', 'kernel', 'liba', 'bin', 'test', 'plasma', 'asm',
                'merlin', 'relspike')

PUT_LINE = re.compile(r'^[ \t]+(put|use)[ \t]+(\S+)', re.I)


def _resolves(relpath):
    """A put operand resolves if the file exists, or exists with `.S`
    appended. Real Merlin's PUT appends `.S` itself and maux's own
    `buildputpath` does the same unless the operand already has a dot;
    src/test/asm/relmain.s's `PUT relsub` is the fixture that exercises
    exactly that, so the shape is legal and must stay checkable. Writing
    the suffix out is still the house rule for everything else
    (learning:01KW1GTYGZ9TE2ZGCDG0V2CNE0: merlin32 does NOT reliably
    append it)."""
    p = os.path.join(ROOT, relpath)
    return os.path.exists(p) or os.path.exists(p + '.s')


def _ignored():
    """(dir names, root-relative paths, basename globs) from .gitignore.

    Only the three shapes this tree actually uses: a line ending in `/`
    is a directory name, a line containing `/` is a path from the repo
    root, and a bare line is a basename (fnmatch, so `*.pyc` works).
    Anything more elaborate is not in this .gitignore and would be
    guesswork.
    """
    dirs, paths, bases = set(), set(), set()
    p = os.path.join(ROOT, '.gitignore')
    for line in open(p, errors='replace'):
        # A `#` is a comment ONLY in column 0 (git's own rule). Splitting
        # on it anywhere truncated `src/relspike/RTNAMES#068000` -- an
        # a2til type suffix, not a comment -- to `.../RTNAMES`, and the
        # dropping came back into the count.
        line = line.rstrip('\n').strip()
        if not line or line.startswith('#') or line.startswith('!'):
            continue
        if line.endswith('/'):
            dirs.add(line.strip('/').split('/')[-1])
        elif '/' in line:
            paths.add(line.lstrip('/'))
        else:
            bases.add(line)
    return dirs, paths, bases


def tree_files(*roots):
    """Every file the TREE CARRIES under the given roots, ROOT-relative
    and sorted -- a filesystem walk minus everything .gitignore names.

    Not `git ls-files`, which was the first version and was wrong: the
    gate box receives an rsync'd copy with `.git/` excluded, and in a
    worktree `.git` is a FILE pointing at a directory that does not
    exist there, so the gate died with `fatal: not a git repository`
    on the box while passing on the laptop. Not a bare walk either:
    the build drops `_FileInformation.txt` beside every source
    merlin32 assembles (48 Makefile rules `rm -f` it, a few do not),
    plus `src/test/asm/fixture_Output.txt` and
    `src/relspike/RTNAMES#068000` -- and the first two have underscores,
    so the name row below would go red at the next person's `make`, on
    files the tree does not carry. Reading .gitignore keeps ONE
    statement of the line between carried and generated, and it is a
    file the box does receive.
    """
    igdirs, igpaths, igbases = _ignored()
    out = []
    for r in roots:
        for d, dirs, files in os.walk(os.path.join(ROOT, r)):
            dirs[:] = [x for x in dirs if x not in igdirs
                       and os.path.relpath(os.path.join(d, x), ROOT)
                       not in igpaths]
            for f in files:
                rel = os.path.relpath(os.path.join(d, f), ROOT)
                if rel in igpaths or any(fnmatch.fnmatch(f, b)
                                         for b in igbases):
                    continue
                out.append(rel)
    return sorted(out)


def check_put_shapes():
    """Every put/use operand in the tree has one of exactly two shapes.

    THIS IS WHAT MAKES THE GUEST RULE TOTAL. merlin32 resolves a put
    against the INCLUDING FILE's directory, not the cwd
    (learning:01KW1GTYGZ9TE2ZGCDG0V2CNE0), so the operands have to stay
    source-relative on the host. The guest has no `..` at all -- ProDOS's
    pathname parser has no parent-directory concept, and maux's own
    `buildputpath` hands the operand to OPEN verbatim. The bridge is one
    rule: DROP THE LEADING `..` SEGMENTS AND ANCHOR THE REMAINDER AT
    /SRC. It is total only if every operand is one of

        NAME                       -- same directory, no slash
        (../)+ SEG/NAME            -- SEG one of PUT_SEGMENTS

    and nothing else: no deeper path, no `.`, no absolute operand, no
    segment the guest has no directory for. The COUNT of `..` is
    deliberately not checked -- it differs on the host between
    `../liba/x.s` (src/bin -> src/liba) and `../../inc/x.equ` (src/bin
    -> inc, one level higher), and the guest rule drops however many
    there are. What IS checked is that the host resolution lands where
    the guest mapping says it should, so the two trees cannot drift:
    `inc` resolves to inc/NAME at the repo root, every other segment to
    src/SEG/NAME.
    """
    fails = []
    checked = 0
    for rel in tree_files('src', 'inc'):
        if not rel.endswith(('.s', '.equ')):
            continue
        d = os.path.dirname(rel)
        for n, raw in enumerate(open(os.path.join(ROOT, rel),
                                     errors='replace'), start=1):
            m = PUT_LINE.match(raw)
            if not m:
                continue
            checked += 1
            op = m.group(2)
            if '/' not in op:
                if not _resolves(os.path.join(d, op)):
                    fails.append(f'{rel}:{n}: `put {op}` names no file in '
                                 f'{d}/ -- a same-directory put must resolve '
                                 f'there on both host and guest.')
                continue
            rest = op
            while rest.startswith('../'):
                rest = rest[3:]
            if rest.count('/') != 1 or op[:3] != '../':
                fails.append(
                    f'{rel}:{n}: `put {op}` is neither a bare same-directory '
                    f'name nor `(../)+SEG/NAME` -- the guest rule (drop the '
                    f'leading `..`, anchor at /SRC) cannot resolve it. See '
                    f'docs/LAYOUT.md.')
                continue
            seg, name = rest.split('/')
            if seg not in PUT_SEGMENTS:
                fails.append(
                    f'{rel}:{n}: `put {op}` names segment {seg!r}, which is '
                    f'not one of {PUT_SEGMENTS} -- the guest has no '
                    f'directory for it.')
                continue
            want = os.path.join('inc', name) if seg == 'inc' \
                else os.path.join('src', seg, name)
            got = os.path.normpath(os.path.join(d, op))
            if got != want:
                fails.append(
                    f'{rel}:{n}: `put {op}` resolves to {got} on the host, '
                    f'but the guest rule maps it to /SRC/{seg.upper()}/'
                    f'{name.upper()} (host {want}). Host and guest trees '
                    f'would disagree.')
                continue
            if not _resolves(want):
                fails.append(f'{rel}:{n}: `put {op}` names {want}, which '
                             f'does not exist.')
    print()
    print('[check-modules] put/use operand shapes: bare same-directory name, '
          'or (../)+SEG/NAME with SEG in ' + ' '.join(PUT_SEGMENTS))
    if fails:
        for f in fails:
            print(f'[check-modules] FAIL: {f}', file=sys.stderr)
        return fails
    print(f'   {checked} put/use operand(s), all resolvable by the guest rule')
    return []


# ProDOS: first character a letter, then letters, digits and periods, at
# most 15 characters, and the name is case-insensitive (stored upper).
# The rule is enforced by the PATHNAME PARSER, not merely at creation --
# a file with an illegal name can sit on a volume perfectly formed and be
# permanently unreachable (learning:01M07G8WT2R3G2P87EK1DNPVYP).
PRODOS_NAME = re.compile(r'[A-Za-z][A-Za-z0-9.]{0,14}$')
# a2til/cadius encode a ProDOS type and auxtype in a host filename suffix
# `NAME#TTAAAA` (learning:01KW1GTYGZ9TE2ZGCDG0V2CNE0). That suffix is
# metadata and never reaches the volume, so it is stripped before the
# name is judged: src/relspike/RTLIB.S#040000 lands as RTLIB.S.
TYPE_SUFFIX = re.compile(r'#[0-9A-Fa-f]{6}$')


def check_prodos_names():
    """Every file and directory under inc/ and src/ has a name ProDOS
    can speak, and no two collide case-insensitively in one directory.

    The host filesystem accepts `memmap-procbank2.equ` and
    `fileprocesstestb.s`; ProDOS accepts neither -- the hyphen is not a
    legal character and the second is 18 characters against a ceiling of
    15. For years that was papered over by a hand-kept flat-name table in
    build_maux_src_image.py, which is what made the guest tree a
    DIFFERENT tree from the host one. This row is the thing that keeps
    them the same tree: a name that cannot be spoken on a volume cannot
    enter the source tree in the first place.
    """
    fails = []
    seen = {}
    names = set()
    for rel in tree_files('inc', 'src'):
        parts = rel.split('/')
        for i, part in enumerate(parts):      # every directory, then the file
            names.add(('/'.join(parts[:i]), part))
    for rd, name in sorted(names):
        bare = TYPE_SUFFIX.sub('', name)
        if not PRODOS_NAME.fullmatch(bare):
            why = ('over 15 characters' if len(bare) > 15
                   else 'not a letter, digit or period, or does not '
                        'start with a letter')
            fails.append(
                f'{rd}/{name}: {bare!r} is {why} -- ProDOS cannot '
                f'name it, so the guest cannot `put` it. See '
                f'docs/LAYOUT.md.')
        key = (rd, bare.upper())
        if key in seen and seen[key] != name:
            fails.append(
                f'{rd}/{name} and {rd}/{seen[key]} differ only in '
                f'case -- ProDOS stores names uppercase and would '
                f'see one file.')
        seen[key] = name
    n = len(names)
    print()
    print('[check-modules] ProDOS names: every file and directory under '
          'inc/ and src/ is <=15 chars of letters/digits/periods')
    if fails:
        for f in fails:
            print(f'[check-modules] FAIL: {f}', file=sys.stderr)
        return fails
    print(f'   {n} name(s), all legal and collision-free')
    return []


def main():
    os.chdir(ROOT)
    kernel = {p: scan(p) for p in sorted(glob.glob('src/kernel/*.s'))}
    includes = set()
    for p in sorted(glob.glob('inc/*.equ')):
        d, _ = scan(p)
        includes |= d

    kernel_defs = {}
    for path, (d, _) in kernel.items():
        for s in d:
            kernel_defs.setdefault(s, set()).add(os.path.basename(path))

    failures, exports = [], {}
    for path, (defined, used) in kernel.items():
        mod = os.path.basename(path)
        debt = KNOWN_DEBT.get(mod, set())
        used_debt = set()
        for sym in sorted(used):
            if sym in defined or sym in includes or sym in KERNEL_CONFIG:
                continue
            if sym in kernel_defs:
                continue
            if sym in debt:
                used_debt.add(sym)
                continue
            failures.append(
                f'{mod}: references {sym!r}, which no kernel module, '
                f'inc/*.equ, or the KERNEL_CONFIG interface defines. '
                f'A kernel module reaching into its includer cannot survive '
                f'separate assembly.')
        stale = debt - used_debt
        if stale:
            failures.append(
                f'{mod}: KNOWN_DEBT lists {sorted(stale)} but the module no '
                f'longer references them -- remove the stale entries so the '
                f'ratchet stays honest.')

    # A kernel module RE-DECLARING an inc/*.equ global is the same
    # collision class as two modules declaring the same symbol -- and it hid
    # from an earlier version of this gate, which only compared modules
    # against each other. mli.s shadowed LCBANK2_RAM/LCBANK2_STORE that way.
    for path, (defined, _) in kernel.items():
        shadow = defined & includes
        if shadow:
            failures.append(
                f'{os.path.basename(path)}: re-declares {sorted(shadow)}, '
                f'which inc/*.equ already owns. Harmless today, a symbol '
                f'collision once modules are separately linked.')

    # Duplicate definitions across modules -- fine under PUT, fatal under LNK.
    dup_owner = {s: o for s, o in kernel_defs.items() if len(o) > 1}
    for sym in sorted(dup_owner):
        if sym not in KNOWN_DUPLICATES:
            failures.append(
                f'{sym!r} is defined by more than one kernel module '
                f'({", ".join(sorted(dup_owner[sym]))}). Harmless under a '
                f'whole-tree PUT, a symbol collision once these are separate '
                f'REL objects.')
    stale_dups = KNOWN_DUPLICATES - set(dup_owner)
    if stale_dups:
        failures.append(
            f'KNOWN_DUPLICATES lists {sorted(stale_dups)} but they are no '
            f'longer multiply defined -- remove the stale entries.')

    # The export surface: the future ENT list for each module.
    for path, (defined, _) in kernel.items():
        mod = os.path.basename(path)
        ext = set()
        for other, (_, oused) in kernel.items():
            if other == path:
                continue
            ext |= (defined & oused)
        exports[mod] = sorted(ext)

    print('[check-modules] kernel module export surface (the future ENT lists):')
    total = 0
    for mod in sorted(exports):
        syms = exports[mod]
        total += len(syms)
        shown = ' '.join(syms[:8]) + (' ...' if len(syms) > 8 else '')
        print(f'   {mod:<14} {len(syms):>2} export(s)  {shown}')
    print(f'[check-modules] {total} symbols cross kernel module boundaries')
    print(f'[check-modules] KERNEL_CONFIG interface: '
          f'{len(KERNEL_CONFIG)} symbol(s) an image must supply')
    print(f'[check-modules] duplicate definitions across modules: '
          f'{len(dup_owner)} ({", ".join(sorted(dup_owner))})')
    outstanding = sum(len(v) for v in KNOWN_DEBT.values())
    print(f'[check-modules] known debt: {outstanding} test symbol(s) still '
          f'referenced by kernel modules ({", ".join(sorted(KNOWN_DEBT))})')

    failures += check_userland(includes)
    failures += check_dead_puts()
    failures += check_dead_routines()
    failures += check_line_length()
    failures += check_no_tabs()
    failures += check_label_length()
    failures += check_arena_anchor()
    failures += check_image_fits()
    # check_kernel_images.run_all() DELIBERATELY NOT CALLED HERE.
    # It measures built .SYSTEM artifacts, and check-modules is a
    # STATIC gate with no build prerequisites that runs FIRST in
    # CHECK_ALL_TARGETS -- so on a clean tree it reported all 27
    # images missing and went red before anything could build
    # them. It now has its own `check-kernel-images` target,
    # placed after the image builds, with real prerequisites.
    # (T2 adversarial review, 2026-08-23.)
    failures += check_sh_budget()
    failures += check_equ_forward_refs()
    failures += check_unit_equ_forward_refs()
    failures += check_manifest_lists()
    failures += check_softswitch_alias()
    failures += check_put_shapes()
    failures += check_prodos_names()
    failures += check_purity.run_all()
    failures += check_listings.run_all()

    # Volume floppy-headroom REPORT -- print-only, contributes NOTHING
    # to `failures`, and sits after the last gate call so it structurally
    # CANNOT reach the verdict below.
    #
    # The contrast with check_kernel_images.run_all() above is
    # deliberate and worth keeping straight, because the two policies
    # are opposites on purpose:
    #   * the $6000 io_buffer crossing is CORRECTNESS -- that gate FAILS
    #     on an unbuilt image, so it can never pass vacuously;
    #   * the 800K crossing is a GOAL WITH A VISIBLE NUMBER -- an
    #     unbuilt volume here is merely "unmeasured", and nothing this
    #     prints may ever block a build (docs/ARCHITECTURE.md, "Target
    #     hardware", ruling 99ce0d0: hard drives were period-real, so
    #     800K is a floppy worth aiming at, not a ceiling).
    report_volumes.print_summary()

    if failures:
        print()
        for f in failures:
            print(f'[check-modules] FAIL: {f}', file=sys.stderr)
        return 1
    print('[check-modules] PASS: no kernel module reaches outside the '
          'declared boundary')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
