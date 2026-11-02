#!/usr/bin/env python3
"""check_dialect.py -- task #7's dialect gate over the WHOLE maux tree.

    make check-dialect

`make check-dual` is the instrument: real Merlin-8 assembling the kernel
unit and byte-matching merlin32. This gate is the other half task #7 owed:
the DIALECT INTERSECTION enforced over every compilation unit in the tree,
including the parts real Merlin has never been handed yet -- which is most
of them, and is exactly what S9's conversion will feed it.

WHAT LIVES WHERE. Line length, label length, EQU forward references and
manifest truth are gated by `make check-modules`, over a scanned file set
DERIVED from check_manifests.py's put/use closure machinery (every file
reachable from every top-level compilation unit -- see check_modules.py's
scanned_file_set()). That closure now includes src/bootblock.s and
src/check.memmap.s (review finding N3 first found them missing; the fix
was to widen check_manifests.toplevel_manifests() to derive top-level
units from the Makefile's own $(MERLIN32) recipes instead of a directory
glob, not to carry a second hand-written list here -- an earlier version
of this file did exactly that, EXTRA_UNITS/OUT_OF_SCOPE_LINE_DEBT/section
5, and it was the disease, not the cure). Negative `ds` (learning:01M0EDXWRX43PTQNR2WC0JT07F)
needs no gate: merlin32 rejects it loudly at build time ("Evaluation of DS
data size ends up as negative value", verified 2026-08-23), so it cannot
survive the host build to reach real Merlin. This gate carries the five
hazards nothing else watches:

  1. EXPRESSIONS. Merlin-8 evaluates strictly left to right, rejects
     parentheses, and TERMINATES an operand at the first space -- the
     rest of the line is comment (vendor OPCODES.S OPTBL: `") ,"`, space
     is an expression terminator; learning:01M051DJW89KV4JYM1EC9SDZ5Y).
     merlin32 v1.1.10 differs twice, measured 2026-08-23 on this machine:
     (a) it JOINS whitespace-separated operand fragments into one
     expression -- `dfb LEN + 1` emits LEN+1 where Merlin-8 emits LEN,
     `SABW - $04*256` is one expression to merlin32 and just `SABW` to
     Merlin-8 -- and it REJECTS free-form comments outright (`lda #3
     load flag` is a merlin32 error), so in any host-assembled unit an
     interior space in an operand field is ALWAYS an expression join,
     i.e. always a silent divergence. Flag ANY operand field with a
     continuation token (2026-08-23 review finding B1: the earlier
     first-token-only scan modeled Merlin-8's field rule and so never
     saw the joined tail -- one space walked the decisive sabotage
     through green). (b) merlin32 is INTERNALLY INCONSISTENT about
     precedence: inline operands (dfb/da/ds/lda #) evaluate LEFT TO
     RIGHT -- agreeing with Merlin-8 -- but an EQU's right-hand side
     evaluates with C-style PRECEDENCE (`FOO equ 2+3*4` = 14, while
     `dfb 2+3*4` = 20; the deadly shape is the hi/lo idiom
     `LO equ W-HI*256`). Flag any binary `*`/`/` after a `+`/`-` in an
     EQU right-hand side, scanned over the merlin32-JOINED expression;
     flag parens anywhere outside an indirect-addressing form (loud on
     both assemblers, but a file no host gate builds would otherwise
     carry them silently).

  2. DUM PLACEMENT. A symbol- or PC-anchored `dum` block that precedes
     still-emitted code silently overlaps it
     (learning:01M0FNC75R7YSFRNS328WHXMHN). Flag such a block if emitted
     code follows it in its unit's assembly stream. Literal-address dummy
     blocks (`dum $FF00`) are deliberate overlays and exempt.

  3. SOURCE-BUFFER BUDGET. Real Merlin's buffer is $0901..$AA00 = 41215
     bytes and holds the RESIDENT source (top-level manifest plus every
     `use` file -- USE copies below HIMEM and NEVER reclaims) together
     with the `put` file currently loaded. PUT files, by contrast, load
     at ENDSRC+1 and each new PUT reuses the region (ASS.BNK1.S:1336-1364:
     the DECD HIMEM copy loop is guarded by PLP/BEQ WASPUT, i.e. USE-only
     -- verified 2026-08-23 against the PTEST unit, whose 448,518-byte
     40-file PUT chain assembles in the 41,215-byte buffer). Budget per
     unit: manifest + all `use` files + its largest single `put` file.
     RATCHETED ON THE STRIPPED SIZE (strip_comments.strip_file(), the
     single strip rule -- see that module's header), not
     os.path.getsize(): the STAGED form is what actually occupies real
     Merlin's buffer (build_maux_src_image.py stages every unit
     stripped), so it is what the ceiling binds. Review finding B1
     (2026-08-23): the gate measured the raw master tree for months,
     so the strip's entire payoff -- eight of the original ten pinned
     units were pure comment weight -- was invisible and never got
     burned. Both numbers print every run (raw is what the human
     editing the master tree sees); only stripped decides membership.
     Units currently over budget (stripped) are pinned in
     OVER_BUDGET_UNITS below -- a SET ratchet, not a byte ratchet,
     because unit sizes drift daily under parallel streams while the
     membership only changes when a unit is split or a new fat unit
     appears. S9's conversion burns the set to empty; a unit joining
     the set is a regression and fails here. `src/bin/mld.s` and
     `src/bin/as.s` each embed three `putbin` blobs merlin32 accepts
     but real Merlin-8 does not (stage_putbin.py); staging rewrites
     each into HEX-dump PUT files, so their budget models that rewrite
     too -- via check_manifests.build_graph()'s `putbin` edges, never
     re-scanned here -- both the manifest's own shrinkage (the putbin
     line becomes N PUT lines) and the new largest-PUT candidate (a
     HEX file, not necessarily liba/stdio.s any more). The three
     source blobs (build/ascore-process-{bank1,as}.obj,
     build/as-stubs.bin) are build artifacts that may not exist on a
     clean tree; this gate FAILS with the exact build command rather
     than silently skipping the term, which would make the ratchet
     non-deterministic (green on a warm tree, differently green on a
     cold one).

  3b. AS SOURCE WINDOW. The same stripped totals as hazard 3, against
     the ceiling that actually binds S9 step 5: as.s's own
     SRC_BASE..page(HIMEM_VAL) window, ~2.6x tighter than real
     Merlin's buffer and invisible to merlin32. Parsed from as.s's
     equates every run, never restated as a number; bracketed
     empirically 2026-08-29 (a 16,127 B flat source assembles
     byte-identical under `as`, 16,128 is refused -- gen_asbigmod.py
     keeps BIGMOD pinned at that exact boundary so a ceiling
     regression turns check-as red). REPORTED, never enforced, since
     2026-09-21: `as` is kept for humans who want macros, the build
     goes through streaming `nas`, and maux code is not shaped against
     `as`'s window. See hazard 3b's own comment for the ruling.

  4. PARMS. The Merlin PARMS 80-column byte must be $83, never $C3: the
     V-bit relocates ProDOS into aux memory, which maux OWNS -- one bank
     per process (learning:01M041MZER5YQJQYR7JP5N7F01). Asserted in the
     embedded blob (src/merlin/patches.py) always, and in the staged
     /SOURCE/PARMS of build/merlinsrc.po whenever that image exists.
     check_dual.py asserts the staged byte again at run time.

COVERAGE, STATED SO GREEN CANNOT OVERCLAIM: only the units check-dual
actually assembles under real Merlin are byte-verified; everything else
here is statically clean against a MODEL measured from real Merlin. The
gate prints that split every run. When S9 stages more units for real
Merlin, extend check_dual, not this file.
"""
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_manifests as cm  # noqa: E402 -- put/use graph machinery
import check_modules as cmod  # noqa: E402 -- the line and label limits
import strip_comments as sc  # noqa: E402 -- the one strip rule (review B1)
import stage_putbin as sp  # noqa: E402 -- the one putbin->HEX/PUT rule
import check_stagebin as csb  # noqa: E402 -- _blob_prefix(), the one
                               # flat-name-prefix derivation (see
                               # PUTBIN_BLOB_PREFIXES's replacement below)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUFFER = 0xAA00 - 0x0901                # 41215, measured AND derived
MERLINSRC = os.path.join(ROOT, 'build', 'merlinsrc.po')

# Units real Merlin byte-verifies today (check_dual.py's manifest set).
DUAL_VERIFIED = {'src/test/processtest.s'}

# Top-level units OUTSIDE check_manifests.toplevel_manifests()'s
# src/test|src/bin glob -- review finding N3 (2026-08-23): these two are
# real compilation units, one of them the tree's designated dum/dend
# exerciser, and they are ALSO outside check_modules.py's
# LONG_LINE_BASELINE glob set, so section 5 below carries their
# line/label checks that check-modules structurally cannot see.
EXTRA_UNITS = ['src/bootblock.s', 'src/check.memmap.s']

# Section 5's shrink-only ratchet: over-64-char lines in the files no
# other gate scans, counted 2026-08-23. Real dialect debt -- Merlin-8
# rejects each line with "Operand too long" -- pinned rather than fixed
# because the files belong to other streams. May only shrink.
OUT_OF_SCOPE_LINE_DEBT = {
    'src/bootblock.s': 31,
    'src/check.memmap.s': 23,
}

# The set ratchet for hazard 3, ON THE STRIPPED SIZE (see the hazard 3
# docstring above). Until 2026-08-23 this gate measured os.path.getsize()
# on the raw master tree -- a tree the strip never touches -- so it could
# not see the strip's payoff at all. Ten units were pinned; eight of them
# (as.s, du.s, diff.s, find.s, ld.s, ls.s, nm.s, sort.s) turned out to be
# PURE COMMENT WEIGHT, not structural size, and were never re-measured
# because the gate never looked at the stripped form. Re-run against
# strip_comments.strip_file() (review finding B1): all eight clear
# 41,215 comfortably (18,845-34,968 bytes; ld.s/as.s include the
# putbin->HEX/PUT rewrite's largest-file term, see the hazard 3
# docstring) -- burned by the strip landing on 2026-08-23, not by
# conversion work. The two survivors are REAL structural debt, not
# comment weight: ed.s and sh.s are still well over the ceiling after
# stripping every comment they have. Re-measured at merge into main,
# 2026-08-24: ed.s 60,142 and sh.s 141,510 stripped (the branch recorded
# 72,289 and 152,058, measured on its own tree before T3/T4 landed --
# both figures corrected here rather than inherited, since a stale
# number in a ratchet comment is how the next reader gets misled about
# how far there is to go). All eight burned units re-verified against
# strip_comments.strip_file() on the MERGED tree: 13,650-29,410 bytes,
# every one clearing 41,215. These are S9's conversion backlog (docs/PLAN.md S9). Membership
# may only SHRINK; shrink the set here when a unit is split under
# budget.
OVER_BUDGET_UNITS = set()

# AS_WINDOW_OVER is GONE (2026-09-21, operator ruling). It pinned the
# 45 units over `as`'s 16,128-byte source window, shrink-only, because
# a unit over that window "could not self-host". That stopped being
# true when `nas` took the self-host job: nas STREAMS (two 512-byte
# block buffers, nothing resident for text or DS) and check-nas-real
# assembles pwd's whole 115 KB closure.
#
# The ruling, with its reasoning, because this is the sort of thing
# that gets reinstated by someone tidying up: `as` is kept because
# HUMAN programmers want macros and amenities nas does not offer. But
# LLM-written assembly is terse, macro-less and heavily commented --
# it suits nas and compounds against `as`'s window -- so holding maux
# code to that window costs real work and buys nothing. nulib2 was
# split FOURTEEN ways chasing this ceiling before anyone checked
# whether it still bound, and the binary was byte-identical across
# every split.
#
# Hazard 3b still MEASURES the window and prints it, because it is a
# useful proxy for unit size and tells a human which units `as` will
# not open. It no longer fails a build. The 45 pins and their
# individual justifications are in git history at 8f041a7.

_AS_S = os.path.join(ROOT, 'src', 'bin', 'as.s')


def _as_window():
    """(window_bytes, src_base, himem_val) parsed from src/bin/as.s.

    Raises with a named fix if the equates cannot be found -- a gate
    that silently falls back to a constant is the stale-second-copy
    disease this parser exists to prevent.
    """
    vals = {}
    with open(_AS_S, encoding='latin-1') as fh:
        for line in fh:
            m = re.match(r'^(SRC_BASE|HIMEM_VAL)\s+equ\s+\$([0-9A-Fa-f]+)',
                         line)
            if m:
                vals[m.group(1)] = int(m.group(2), 16)
    missing = {'SRC_BASE', 'HIMEM_VAL'} - set(vals)
    if missing:
        raise RuntimeError(
            f'could not parse {sorted(missing)} from {cm.rel(_AS_S)} -- '
            f'hazard 3b derives as\'s source window from those equates '
            f'(literal $hex `equ` lines). If as.s renamed or reformatted '
            f'them, update _as_window() in check_dialect.py to match.')
    window = ((vals['HIMEM_VAL'] >> 8) << 8) - vals['SRC_BASE']
    if not 0x1000 <= window <= 0xC000:
        raise RuntimeError(
            f'parsed an implausible as source window ({window} bytes) '
            f'from {cm.rel(_AS_S)} -- SRC_BASE=${vals["SRC_BASE"]:04X}, '
            f'HIMEM_VAL=${vals["HIMEM_VAL"]:04X}. Check the equates.')
    return window, vals['SRC_BASE'], vals['HIMEM_VAL']

# The merlin32-only `putbin` blobs src/bin/mld.s and src/bin/as.s embed
# (stage_putbin.py) -- hazard 3's HEX-rewrite modeling below needs a
# ProDOS-legal flat-name prefix per blob to call
# stage_putbin.blob_to_hex_puts() with. USED TO be a hand-maintained
# {path: prefix} dict here (three entries, `DLB1`/`DLB2`/`DLB3`),
# independent of check_stagebin.py's own naming on the theory that
# nothing requires the two tables to share VALUES -- true, but a
# literal table of blob PATHS still goes stale the moment a blob is
# renamed, which is exactly what happened: stream T5 moved `as.s` off
# the `ascore-process-{bank1,as}.obj` pair (still `ld.s`'s own, listed
# nowhere near here) onto a new `ascore-warm-{bank1,as}.obj` pair this
# dict had never heard of, and `_putbin_hex_files` KeyError'd on the
# first one it looked up. Derived now instead, via
# _derive_putbin_prefixes() below, from whatever putbin edges the
# graph ACTUALLY carries this run -- reusing check_stagebin.py's own
# _blob_prefix() (one function of record per fact, same principle
# _putbin_hex_files already cites for blob_to_hex_puts itself) so a
# blob renamed, added, or removed in ld.s/as.s is picked up with
# nothing to edit here.
def _derive_putbin_prefixes(graph, tops):
    """{rel_path: prefix} for every DISTINCT putbin target any unit in
    `tops` embeds -- see the block comment above for why this replaced
    a hand-maintained dict. Collision-checked the same way check_
    stagebin.derive_putbin_blobs() checks its own derived prefixes:
    this gate only measures text length (never writes a flat-name
    file), so a collision here cannot corrupt a staged image, but it
    WOULD mean two blobs share one prefix's HEX/PUT-name cache key --
    a silent size-model bug -- so it fails loudly rather than
    guessing."""
    targets = sorted({t for top in tops for d, t, _ in graph[top]
                       if d == 'putbin'})
    prefixes = {cm.rel(t): csb._blob_prefix(t) for t in targets}
    values = list(prefixes.values())
    assert len(set(values)) == len(values), (
        f'derived putbin blob prefixes collide -- extend '
        f'check_stagebin._blob_prefix(): {prefixes}')
    return prefixes

# Directives whose operand is literal text / a filename -- no expression.
SKIP_OPS = {'asc', 'dci', 'inv', 'fls', 'rev', 'str', 'strl', 'txt',
            'put', 'use', 'putbin', 'dsk', 'sav', 'save', 'hex',
            'lst', 'xc', 'kbd', 'ttl', 'tr', 'cyc', 'exp', 'pau', 'ast'}

# Directives that EMIT bytes (for the dum-placement scan). Instructions
# are detected separately; this is the data-emitting pseudo-op set.
EMIT_OPS = {'dfb', 'da', 'dw', 'ddb', 'adr', 'adrl', 'asc', 'dci', 'inv',
            'fls', 'rev', 'str', 'strl', 'hex', 'ds'}
NON_EMIT_OPS = {'equ', '=', 'org', 'dum', 'dend', 'put', 'use', 'putbin',
                'dsk', 'sav', 'save', 'typ', 'lst', 'xc', 'kbd', 'err',
                'ttl', 'obj', 'ast', 'skp', 'pag', 'tr', 'cyc', 'exp',
                'mx', 'pau'}
# -- `lup`/`--^`/`do`/`else`/`fin` REMOVED 2026-09-27 (coordinator
# -- review, DECISION 1): conditional/loop assembly is not in nas's
# -- dialect at all (its own directive table has no D_DO/D_FIN/D_LUP),
# -- and nas is the assembler of record (docs/NAS.md) -- the checked
# -- dialect must equal what nas assembles. Separately, merlin32's own
# -- `do` with a VARIABLE label resolves to that variable's FINAL
# -- value FILE-WIDE, not the value at the `do` site -- measured
# -- directly this round -- so a directive whose meaning depends on
# -- where in the file you look was never something this tree should
# -- lean on regardless of nas. See check_no_cond_asm() below, which
# -- rejects them outright rather than merely misclassifying them for
# -- the dum-placement scan.
COND_ASM_OPS = {'do', 'else', 'fin', 'lup', '--^'}


def split_line(line):
    """(label, opcode, toks) for one maux source line, comment stripped;
    (None, None, []) for blank/comment lines. Field rule matches
    check_manifests.scan_put_use: label iff column 0 is non-blank.
    `toks` is EVERY whitespace-delimited token after the opcode --
    Merlin-8 reads only toks[0] as the operand (space terminates the
    expression), merlin32 joins them all, and that asymmetry is hazard
    1's subject -- with quoted spans (either quote) opaque, so
    `cmp #" "` stays one token and a `;` inside a string does not start
    a comment."""
    if not line.strip() or line.lstrip().startswith('*') and line[:1] == '*':
        return None, None, None
    # Tokenize respecting quotes.
    toks, cur, q, i = [], '', None, 0
    while i < len(line):
        ch = line[i]
        if q:
            cur += ch
            if ch == q:
                q = None
        elif ch in '\'"':
            q = ch
            cur += ch
        elif ch == ';':
            break
        elif ch in ' \t':
            if cur:
                toks.append(cur)
                cur = ''
        else:
            cur += ch
        i += 1
    if cur:
        toks.append(cur)
    if not toks:
        return None, None, []
    label = None
    if line[0] not in ' \t':
        label = toks[0]
        toks = toks[1:]
    if label and label.startswith('*'):
        return None, None, []
    opcode = toks[0].lower() if toks else None
    return label, opcode, toks[1:]


ADDR_FORMS = [re.compile(r'^\((.*)\),[syxSYX]$'),
              re.compile(r'^\((.*),[xsXS]\)$'),
              re.compile(r'^\((.*)\)$')]
ATOM = re.compile(r'\$[0-9A-Fa-f]+|%[01_]+|\d+|[:\]]?[A-Za-z_][A-Za-z0-9_.]*')


def expr_hazards(operand, in_equ=False):
    """Return a list of hazard strings for one operand expression.
    The precedence check applies only when in_equ: inline operands
    evaluate left-to-right under BOTH assemblers (measured 2026-08-23,
    merlin32 v1.1.10 dfb/da/ds/immediate probes), so only an EQU's
    right-hand side can silently diverge."""
    if operand is None:
        return []
    expr = operand
    for form in ADDR_FORMS:
        m = form.match(expr)
        if m:
            expr = m.group(1)
            break
    hazards = []
    for part in re.split(r',', expr):
        # Char literals are atoms; collapse them before scanning.
        part = re.sub(r'([\'"]).\1?', 'C', part)
        if '(' in part or ')' in part:
            hazards.append(f'parenthesis in expression {operand!r} -- '
                           f'real Merlin-8 rejects it ("Illegal char in '
                           f'operand"); merlin32 rejects it in data/equ '
                           f'contexts too (measured 2026-08-23), so this '
                           f'mostly catches files no host gate assembles')
            continue
        ops, expect_operand, i = [], True, 0
        while i < len(part):
            ch = part[i]
            if ch in ' \t':
                i += 1
                continue
            if expect_operand:
                if ch in '#<>^|+-':        # prefixes / unary signs
                    i += 1
                    continue
                if ch == '*':              # PC reference
                    expect_operand = False
                    i += 1
                    continue
                m = ATOM.match(part, i)
                if m:
                    expect_operand = False
                    i = m.end()
                    continue
                i += 1                     # unknown char: skip, stay lenient
            else:
                if ch in '+-*/':
                    ops.append(ch)
                    expect_operand = True
                    i += 1
                    continue
                if ch in '&.!':            # Merlin logical ops, also L-to-R
                    ops.append(ch)
                    expect_operand = True
                    i += 1
                    continue
                i += 1
        if not in_equ:
            continue
        seen_addsub = False
        for op in ops:
            if op in '+-&.!':
                seen_addsub = True
            elif op in '*/' and seen_addsub:
                hazards.append(
                    f'{operand!r}: binary {op!r} after +/- in an EQU -- '
                    f'Merlin-8 evaluates left-to-right, merlin32 resolves '
                    f'EQU definitions by precedence; both assemble with 0 '
                    f'errors, DIFFERENT bytes '
                    f'(learning:01M051DJW89KV4JYM1EC9SDZ5Y)')
                break
    return hazards


def check_expressions():
    print()
    print('[check-dialect] 1. expression divergences (interior spaces, '
          'precedence, parens)')
    failures = []
    scanned = 0
    for path in sorted(cm.universe()):
        for lineno, raw in enumerate(open(path, errors='replace'), 1):
            _label, opcode, toks = split_line(raw.rstrip('\n'))
            if opcode is None or opcode in SKIP_OPS:
                continue
            scanned += 1
            if not toks:
                continue
            if len(toks) > 1:
                # Review finding B1: an interior space is ALWAYS a silent
                # divergence in a host-assembled unit -- Merlin-8 stops
                # the expression at the space (rest is comment), merlin32
                # joins the fragments (and rejects true free comments, so
                # a building line's tail IS expression). Scan the JOINED
                # form below, but the space itself is already the bug.
                failures.append(
                    f'{cm.rel(path)}:{lineno}: interior space in operand '
                    f'field {" ".join(toks)!r} -- Merlin-8 evaluates only '
                    f'{toks[0]!r} and treats the rest as comment; merlin32 '
                    f'joins it into one expression. Both assemble, '
                    f'DIFFERENT bytes. Remove the spaces (or make the tail '
                    f'a real `;` comment).')
            operand = ''.join(toks)
            for h in expr_hazards(operand, in_equ=opcode in ('equ', '=')):
                failures.append(f'{cm.rel(path)}:{lineno}: {h}')
    if failures:
        print(f'   {len(failures)} hazardous expression(s):')
        for f in failures[:12]:
            print(f'     {f}')
    else:
        print(f'   0 hazards in {scanned} operand lines -- every expression '
              f'means the same thing to both assemblers')
    return failures


def unit_stream(graph, top):
    """Yield (path, lineno, line) in real assembly order: the manifest
    with each put/use expanded in place (nesting is banned and gated by
    check-modules, so one level suffices)."""
    for lineno, raw in enumerate(open(top, errors='replace'), 1):
        line = raw.rstrip('\n')
        _label, opcode, toks = split_line(line)
        if opcode in ('put', 'use') and toks:
            tgt = cm.resolve(top, toks[0])
            if os.path.exists(tgt):
                for sub_lineno, sub_raw in enumerate(
                        open(tgt, errors='replace'), 1):
                    yield tgt, sub_lineno, sub_raw.rstrip('\n')
                continue
        yield top, lineno, line


def check_dum_placement(graph, tops):
    print()
    print('[check-dialect] 2. dum placement (symbol-anchored dummy blocks '
          'must follow all emitted code)')
    failures = []
    for top in sorted(tops):
        open_dums = []                    # [(path, lineno, operand)]
        in_dum = False
        for path, lineno, line in unit_stream(graph, top):
            _label, opcode, toks = split_line(line)
            operand = toks[0] if toks else None
            if opcode is None:
                continue
            if opcode == 'dum':
                in_dum = True
                if operand and not operand.startswith('$'):
                    open_dums.append((path, lineno, operand))
                continue
            if opcode == 'dend':
                in_dum = False
                continue
            if in_dum:
                continue
            emits = opcode in EMIT_OPS or opcode not in NON_EMIT_OPS
            if emits and open_dums:
                for dpath, dline, dop in open_dums:
                    failures.append(
                        f'{cm.rel(top)}: dum {dop} at {cm.rel(dpath)}:{dline} '
                        f'precedes emitted code at {cm.rel(path)}:{lineno} '
                        f'({line.strip()[:40]!r}) -- the dummy section '
                        f'silently overlaps it '
                        f'(learning:01M0FNC75R7YSFRNS328WHXMHN)')
                open_dums = []
    if failures:
        print(f'   {len(failures)} misplaced dum block(s):')
        for f in failures[:8]:
            print(f'     {f}')
    else:
        print(f'   0 -- every symbol-anchored dum block in all '
              f'{len(tops)} units sits after its unit\'s emitted code')
    return failures


def _putbin_hex_files(blob_path, prefixes, _cache={}):
    """[(flat_name, source_text), ...] for one putbin blob, via
    stage_putbin.blob_to_hex_puts() -- the SAME function a real staging
    step would call, so this gate's size model cannot silently diverge
    from what actually gets written (HACKING.md's 'do not re-derive the
    strip rule' -- same principle, one function of record per fact).
    Cached per path: ld.s and as.s no longer share every blob (as.s
    moved to `ascore-warm-*`, ld.s kept `ascore-process-*`; `as-stubs.
    bin` is still common to both), but a blob's content cannot change
    mid-run regardless."""
    if blob_path not in _cache:
        prefix = prefixes[cm.rel(blob_path)]
        _cache[blob_path] = sp.blob_to_hex_puts(blob_path, prefix)
    return _cache[blob_path]


def _putbin_replacement_lines(names):
    """stage_putbin.putbin_replacement_lines(), tolerant of either side
    of the in-flight interface change (task brief, 2026-08-23: another
    engineer is adding a `dir_prefix` parameter, default
    '/mnt/MAUXSRC/SRC/', in parallel with this file). Neither form of the
    call changes the HEX file sizes this gate ratchets on -- only the
    PUT line text's own (much smaller) contribution to the manifest
    term."""
    try:
        return sp.putbin_replacement_lines(names, dir_prefix='/mnt/MAUXSRC/SRC/')
    except TypeError:
        return sp.putbin_replacement_lines(names)


def _stripped_manifest_with_putbin(top, putbin_edges, prefixes):
    """Stripped text of `top`, with every `putbin` line -- located by
    the graph's own (directive, target, lineno) edges, never re-scanned
    here -- replaced by the PUT lines real-Merlin staging substitutes
    for it (stage_putbin.py). Comment-stripping never touches a putbin
    line (it is not a comment-only line), so stripping first and
    substituting after is equivalent to the reverse order; stripping
    first is what actually happens at stage time, so that is the order
    modeled here."""
    text = sc.strip_file(top)
    if not putbin_edges:
        return text
    lines = text.split('\n')
    for _directive, blob_path, lineno in putbin_edges:
        names = [n for n, _ in _putbin_hex_files(blob_path, prefixes)]
        lines[lineno - 1] = '\n'.join(_putbin_replacement_lines(names))
    return '\n'.join(lines)


def check_budget(graph, tops):
    print()
    print(f'[check-dialect] 3. source-buffer budget (resident + largest '
          f'put <= {BUFFER}) -- STRIPPED decides the ratchet (what '
          f'actually gets staged for real Merlin); RAW (os.path.getsize '
          f'on the master tree) prints alongside for the human editing '
          f'it. Review finding B1 (2026-08-23): this gate measured RAW '
          f'only for months, so it could never see the strip\'s payoff.')

    # Hazard 3's putbin modeling needs every real build artifact ld.s/
    # as.s embed on disk -- as.s's own now split from ld.s's (T5 moved
    # it onto build/ascore-warm-{bank1,as}.obj; ld.s kept build/ascore-
    # process-{bank1,as}.obj; build/as-stubs.bin stays common to both).
    # NOT optional: silently skipping a missing blob would drop the
    # putbin term and make the ratchet non-deterministic -- green on a
    # warm tree, differently green (under-counted) on a cold one. Fail
    # loudly, before computing anything, naming the exact fix.
    needed_blobs = sorted({cm.rel(t) for top in tops
                            for d, t, _ in graph[top] if d == 'putbin'})
    missing = [b for b in needed_blobs
               if not os.path.exists(os.path.join(ROOT, b))]
    if missing:
        print(f'   {len(missing)} putbin blob(s) missing -- cannot model '
              f'the HEX/PUT rewrite hazard 3 needs: {missing}')
        return [
            f'putbin blob {b} missing (src/bin/mld.s and src/bin/as.s '
            f'embed blobs via `putbin`; real Merlin has no putbin, so '
            f'staging rewrites it into HEX-dump PUT files -- '
            f'stage_putbin.py). Build it: `make build/as-stubs.bin` (as-'
            f'stubs.bin, shared by both), `make check-ascore-process` '
            f'(ld.s\'s ascore-process-{{as,bank1}}.obj), or `make '
            f'check-ascore-warm` (as.s\'s ascore-warm-{{as,bank1}}.obj) '
            f'-- or just `make check-dialect`, which now carries every '
            f'blob it needs as a prerequisite.'
            for b in missing]

    prefixes = _derive_putbin_prefixes(graph, tops)

    failures = []
    over_now = set()
    rows = []                    # (stripped_total, relname, raw_total, worst_f)
    for top in sorted(tops):
        edges = graph[top]
        relname = cm.rel(top)
        putbin_edges = [e for e in edges if e[0] == 'putbin']

        # RAW: os.path.getsize only, exactly the pre-B1 model -- the
        # master tree as a human editing it sees it. putbin is NOT
        # modeled here on purpose: the master tree still has the
        # `putbin` line and no HEX files exist there; raw is not a
        # staging model, it is "what's in the repo today."
        raw_manifest = os.path.getsize(top)
        raw_use = sum(os.path.getsize(t) for d, t, _ in edges
                      if d == 'use' and os.path.exists(t))
        raw_worst = 0
        for d, t, _ in edges:
            if d == 'put' and os.path.exists(t):
                raw_worst = max(raw_worst, os.path.getsize(t))
        raw_total = raw_manifest + raw_use + raw_worst

        # STRIPPED: strip_comments.strip_file() throughout, PLUS the
        # putbin->HEX/PUT rewrite modeled exactly for units that embed
        # one -- both the manifest's own shrinkage (the putbin line
        # becomes N PUT lines) and the new largest-PUT candidate (a HEX
        # file may now be the charged term, not liba/stdio.s). This is
        # what actually lands on the self-hosting image, so it is what
        # the 41215-byte ceiling binds.
        stripped_manifest = len(
            _stripped_manifest_with_putbin(top, putbin_edges, prefixes))
        stripped_use = sum(len(sc.strip_file(t)) for d, t, _ in edges
                            if d == 'use' and os.path.exists(t))
        stripped_worst, worst_f = 0, '-'
        for d, t, _ in edges:
            if d == 'put' and os.path.exists(t):
                s = len(sc.strip_file(t))
                if s > stripped_worst:
                    stripped_worst, worst_f = s, cm.rel(t)
        for _d, blob_path, _lineno in putbin_edges:
            for name, htext in _putbin_hex_files(blob_path, prefixes):
                s = len(htext)
                if s > stripped_worst:
                    stripped_worst, worst_f = \
                        s, f'{cm.rel(blob_path)} (HEX {name}.S)'
        stripped_total = stripped_manifest + stripped_use + stripped_worst

        if stripped_total > BUFFER:
            over_now.add(relname)
        has_put = bool(putbin_edges) or any(d == 'put' for d, _t, _l in edges)
        rows.append((stripped_total, relname, raw_total, worst_f, has_put))

    rows.sort(reverse=True)
    print(f'   {"unit":<24} {"raw":>8} {"stripped":>9}')
    for stripped_total, relname, raw_total, worst_f, _hp in rows:
        mark = '  OVER' if stripped_total > BUFFER else ''
        print(f'   {relname:<24} {raw_total:>8} {stripped_total:>9}{mark}')

    raw_over = {relname for _s, relname, raw_total, _w, _hp in rows
                if raw_total > BUFFER}
    new_over = over_now - OVER_BUDGET_UNITS
    resolved = OVER_BUDGET_UNITS - over_now
    print(f'\n   stripped: {len(over_now)} unit(s) over budget '
          f'({len(OVER_BUDGET_UNITS)} pinned); '
          f'raw: {len(raw_over)} unit(s) over budget (not ratcheted)')
    if new_over:
        failures.append(
            f'unit(s) NEWLY over the {BUFFER}-byte source buffer '
            f'(stripped): {sorted(new_over)}. Real Merlin will die with '
            f'"56 MEMORY IN USE". Split the unit (scripts/shrink_source.py) '
            f'or shrink its manifest; do NOT add it to OVER_BUDGET_UNITS '
            f'-- the set only shrinks.')
    if resolved:
        failures.append(
            f'unit(s) now UNDER budget (stripped) but still pinned: '
            f'{sorted(resolved)} -- good; remove them from '
            f'OVER_BUDGET_UNITS in check_dialect.py so the ratchet holds.')

    # -- 3b: the SAME stripped totals against as's OWN window.
    #
    # INFORMATIONAL ONLY as of 2026-09-21, by operator ruling. It used
    # to FAIL, on the rationale that a unit over this window "cannot
    # self-host" -- true when `as` WAS the self-host route, and false
    # since `nas` took that job. nas STREAMS: two 512-byte block
    # buffers (src/asm/nas.pla RDBUFSZ), PUT folded into the reader,
    # all three passes walking the stream, and a resident model that
    # charges "27 B a label, 17 a local, ~5 a code line, 3.5 KB fixed;
    # nothing for text or DS" (docs/AS-STREAM.md). check-nas-real
    # assembles pwd's whole 115 KB closure. There is no 16 KB ceiling
    # anywhere in the build path.
    #
    # THE RULING, and its reasoning, because this is exactly the sort
    # of thing that gets "fixed" back: `as` stays, because human
    # programmers want macros and the amenities nas does not offer.
    # But LLM-written assembly is terse, macro-less and heavily
    # commented -- which suits nas and compounds against `as`'s window
    # -- so holding maux code to that window costs real work and buys
    # nothing. nulib2 was split FOURTEEN ways chasing this ceiling
    # before anyone checked whether it still bound; the binary was
    # byte-identical across every split.
    #
    # The numbers are still printed: they are a useful proxy for unit
    # size, and a human who wants to open a unit in `as` can see which
    # ones will not fit. They no longer fail a build.
    window, src_base, himem = _as_window()
    print()
    print(f'[check-dialect] 3b. as source window (resident + largest put '
          f'< {window} = page(HIMEM_VAL)*256 - SRC_BASE, parsed from '
          f'{cm.rel(_AS_S)}: SRC_BASE=${src_base:04X} '
          f'HIMEM_VAL=${himem:04X}) -- INFORMATIONAL: `as` is kept for '
          f'humans who want macros, NOT for the build, and nas streams '
          f'(no window). This never fails a build.')
    aswin_now = set()
    fringe = []
    for stripped_total, relname, _raw, _wf, has_put in rows:
        slack = 2 if has_put else 1
        margin = (window - slack) - stripped_total
        if margin < 0:
            aswin_now.add(relname)
        if -512 <= margin < 512:
            fringe.append((margin, relname, stripped_total))
    print(f'   {len(aswin_now)} unit(s) over the window, '
          f'{len(rows) - len(aswin_now)} fit; boundary +/-512 B:')
    for margin, relname, stripped_total in sorted(fringe):
        side = 'over by' if margin < 0 else 'fits by'
        print(f'   {relname:<28} {stripped_total:>6}  {side} '
              f'{abs(margin)}')
    print(f'   {len(aswin_now)} of {len(rows)} unit(s) would not open '
          f'in `as`. Informational: nothing here fails a build, and no '
          f'maux unit is shaped against this ceiling.')
    return failures


def check_no_cond_asm():
    """No `do`/`else`/`fin`/`lup`/`--^` conditional/loop assembly, and no
    merlin32 VARIABLE label (`]name`), anywhere in the tree (2026-09-27,
    coordinator review, DECISION 1). nas has no `do`/`fin` directive at
    all (its own directive table has no D_DO/D_FIN/D_LUP), and nas is
    the assembler of record -- the checked dialect must equal what nas
    assembles, not the other way round. A `]name` variable label is
    rejected too: it exists in this tree ONLY to be redefined across a
    `do` guard's lifetime, and merlin32 itself resolves a `do` on a
    variable to that variable's FINAL value FILE-WIDE (measured
    directly this round), not the value at the `do` site -- a second
    reason, independent of nas, not to lean on either construct."""
    print()
    print('[check-dialect] 5. no conditional/loop assembly '
          '(do/else/fin/lup/--^), no `]variable` labels')
    failures = []
    scanned = 0
    for path in sorted(cm.universe()):
        for lineno, raw in enumerate(open(path, errors='replace'), 1):
            label, opcode, _toks = split_line(raw.rstrip('\n'))
            if opcode is None:
                continue
            scanned += 1
            if opcode in COND_ASM_OPS:
                failures.append(
                    f'{cm.rel(path)}:{lineno}: `{opcode}` is conditional/'
                    f'loop assembly -- not in nas\'s dialect at all '
                    f'(src/asm/nas.pla has no D_DO/D_FIN/D_LUP), and '
                    f'merlin32\'s own `do` on a variable resolves '
                    f'file-wide, not at the `do` site. Scope by module '
                    f'choice (a real module + a stub module, each '
                    f'`put` by the manifests that want that behavior) '
                    f'instead -- src/kernel/procdev.s / procdevs.s is '
                    f'the worked example.')
            if label and label.startswith(']'):
                failures.append(
                    f'{cm.rel(path)}:{lineno}: `{label}` is a merlin32 '
                    f'VARIABLE label -- rejected for the same reason as '
                    f'`do`/`fin` above (it exists only to be redefined '
                    f'across a `do` guard\'s lifetime, and resolves '
                    f'file-wide when read through one). Use a plain '
                    f'`equ` and module-choice scoping instead.')
    if failures:
        print(f'   {len(failures)} conditional-assembly violation(s):')
        for f in failures[:12]:
            print(f'     {f}')
    else:
        print(f'   0 violations in {scanned} lines -- no do/else/fin/lup/'
              f'--^ and no `]variable` label anywhere in the tree')
    return failures


def check_parms():
    print()
    print('[check-dialect] 4. PARMS 80-column byte is $83, not $C3 '
          '(the ProDOS-into-aux V-bit -- maux owns aux)')
    failures = []
    sys.path.insert(0, os.path.join(ROOT, 'src', 'merlin'))
    # patches.py asserts its own PARMS bytes at import time, so a $C3
    # blob would raise there before this check ran (review finding N5)
    # -- catch it and report through the gate's own failure path so the
    # operator gets the explanation, not a bare stack trace.
    try:
        import patches                    # noqa: E402
        blob = patches.PARMS_BYTES[patches.PARMS_SLOT_OFFSET]
    except AssertionError:
        failures.append(
            'src/merlin/patches.py PARMS blob failed its own import-time '
            'assertion -- the 80-column byte is not $83 (a $C3 V-bit '
            'would relocate ProDOS into aux memory, which maux owns)')
        blob = None
    if blob is None:
        pass
    elif blob != 0x83:
        failures.append(f'embedded PARMS blob byte {patches.PARMS_SLOT_OFFSET}'
                        f' is ${blob:02X}, want $83')
    else:
        print('   embedded blob (src/merlin/patches.py): $83')
    if os.path.exists(MERLINSRC):
        sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
        import a2til                      # noqa: E402
        parms = a2til.open_image(MERLINSRC).read_file('/SOURCE/PARMS')
        b = parms[4]
        if b != 0x83:
            failures.append(
                f'build/merlinsrc.po /SOURCE/PARMS byte 4 is ${b:02X}, want '
                f'$83 -- ${0xC3:02X} would relocate ProDOS into aux memory, '
                f'which maux owns (one bank per process); real Merlin would '
                f'then scribble on process banks '
                f'(learning:01M041MZER5YQJQYR7JP5N7F01)')
        else:
            print('   staged /SOURCE/PARMS on build/merlinsrc.po: $83')
    else:
        print('   build/merlinsrc.po not built -- staged byte checked by '
              'check-dual at run time instead')
    return failures


def check_examples_sources():
    """6. examples/*/*.s -- the lesson sources (docs/EXAMPLES.md, SITE.md
    sec 5). They are staged on the release disk and included verbatim on
    the site, so they obey the house dialect and are held to it by the
    SAME rules as src/: line <= 64 chars, label <= 13 chars (a leading
    ':' counts), ASCII only, no tabs, no macros, no conditional
    assembly, no interior-space or precedence hazard in an operand.
    examples/ is in no compilation-unit closure (check_modules derives
    its scanned set from the Makefile's merlin32 recipes, and an example
    is built by nas ON the machine), so none of the other gates saw it;
    hello.s and hellosys/hello.s shipped with 65-character lines for
    that reason."""
    print()
    print('[check-dialect] 6. examples/*/*.s (lines <= 64, labels <= 13, '
          'ASCII, no tabs, no macros, no do/fin, expression hazards)')
    failures = []
    files = sorted(glob.glob(os.path.join(ROOT, 'examples', '*', '*.s')))
    nlines = 0
    for path in files:
        rel = os.path.relpath(path, ROOT)
        raw = open(path, 'rb').read()
        for i, b in enumerate(raw):
            if b >= 128:
                failures.append(f'{rel}: non-ASCII byte at offset {i} '
                                f'(line {raw[:i].count(10) + 1})')
                break
        for lineno, line in enumerate(raw.decode('latin-1').split('\n'), 1):
            nlines += 1
            if len(line) > cmod.MERLIN_LINE_LIMIT:
                failures.append(f'{rel}:{lineno}: {len(line)} characters, '
                                f'over real Merlin\'s '
                                f'{cmod.MERLIN_LINE_LIMIT}-char limit')
            if '\t' in line:
                failures.append(f'{rel}:{lineno}: tab character (the '
                                f'comment strip matches spaces only)')
            label, opcode, toks = split_line(line)
            if label and len(label) > cmod.MERLIN_LABEL_LIMIT:
                failures.append(f'{rel}:{lineno}: label {label} is '
                                f'{len(label)} characters, over '
                                f'{cmod.MERLIN_LABEL_LIMIT}')
            if opcode is None:
                continue
            if opcode in COND_ASM_OPS or (label or '').startswith(']'):
                failures.append(f'{rel}:{lineno}: conditional assembly or '
                                f'a ]variable (not in nas\'s dialect)')
            if opcode in ('mac', 'eom', 'pmc', '<<<', '>>>') or \
                    opcode.startswith('>>>') or \
                    (toks and toks[0].startswith('>>>')):
                failures.append(f'{rel}:{lineno}: a macro (maux uses '
                                f'none)')
            if opcode in SKIP_OPS or not toks:
                continue
            if len(toks) > 1:
                failures.append(f'{rel}:{lineno}: interior space in '
                                f'operand field {" ".join(toks)!r}')
            for h in expr_hazards(''.join(toks),
                                  in_equ=opcode in ('equ', '=')):
                failures.append(f'{rel}:{lineno}: {h}')
    if failures:
        print(f'   {len(failures)} violation(s):')
        for f in failures[:12]:
            print(f'     {f}')
    else:
        print(f'   0 violations in {len(files)} file(s), {nlines} lines')
    return failures


def main():
    graph, put_targets = cm.build_graph()
    # toplevel_manifests() is now derived from the Makefile's own
    # $(MERLIN32) recipes (check_manifests.py), which already includes
    # src/bootblock.s and src/check.memmap.s -- no more hand-added
    # EXTRA_UNITS on top of the glob it used to be.
    tops = cm.toplevel_manifests(graph, put_targets)
    failures = []
    failures += check_expressions()
    failures += check_dum_placement(graph, tops)
    failures += check_budget(graph, tops)
    failures += check_parms()
    failures += check_no_cond_asm()
    failures += check_examples_sources()

    print()
    dual = sorted(DUAL_VERIFIED)
    print(f'[check-dialect] coverage: {len(dual)} of {len(tops)} units '
          f'byte-verified under real Merlin-8 by check-dual ({dual[0]}, '
          f'the kernel); the rest are STATICALLY clean against measured '
          f'dialect facts only. Extend check_dual.py as S9 stages units.')
    print(f'  structural guarantee: the strip NEVER touches the master '
          f'tree -- merlin32 and real Merlin both assemble straight from '
          f'src/** (strip_comments.py\'s only consumers are the disk-image '
          f'stager, this gate\'s budget model, and check-strip\'s own '
          f'differential), so a strip bug cannot reach any merlin32-built '
          f'artifact, whatever this coverage line says.')
    diff_top = os.path.join(ROOT, 'src/bin/diff.s')
    if diff_top in graph:
        diff_closure = cm.closure(graph, diff_top)
        print(f'  caveat: src/bin/diff.s (DIFF) is staged onto the '
              f'self-hosting image (build_maux_src_image.py\'s UNITS '
              f'table) but assembled by NO gate -- its own put/use '
              f'closure is {len(diff_closure)} file(s), none of them '
              f'exercised by check-dual (which assembles only PTEST\'s '
              f'own chain).')
    if failures:
        print(f'\n[check-dialect] FAIL -- {len(failures)} problem(s):',
              file=sys.stderr)
        for f in failures:
            print(f'  * {f}', file=sys.stderr)
        return 1
    print('[check-dialect] PASS')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
