#!/usr/bin/env python3
"""check_equ_fwd.py -- EQU forward-reference audit (`make check-equ-fwd`).

BACKGROUND (2026-08-19 real-Merlin divergence, found this round): an
`equ` whose DEFINITION references an equate defined LATER in the same
file assembles SILENTLY WRONG under real Merlin-8 -- the assembler
caches pass-1's (wrong, forward-reference) value for the symbol and
never revisits it, with "Errors: 0" reported. merlin32 resolves the
same source correctly (it iterates until the symbol table settles),
so this divergence is invisible to every gate that only runs
merlin32, and even to `make check-dual`'s byte-compare UNLESS the
byte-compare actually covers the affected file -- which it does for
the kernel (`check-dual` byte-compares every src/kernel/*.s module
against real Merlin's own output, so a forward-ref bug there would
already show up as a mismatch) but covers nothing else in the tree.

SCOPE: everything real Merlin will EVER be asked to assemble that is
NOT already covered by `check-dual`'s byte-compare -- src/kernel/*.s
is deliberately EXCLUDED here for exactly that reason. Everything
else real Merlin can reach is in scope: inc/*.equ, src/liba/*.s,
src/bin/*.s, src/test/*.s.

ANALYSIS -- SAME-FILE ONLY, deliberately conservative: for each file,
every `SYM equ EXPR` line is recorded in source order (Merlin labels
always start in column 1, so the label-then-`equ`-then-expression
shape on ONE line is the only form this tree uses -- verified by
inspection, no file in scope splits a label and its `equ` across
lines). EXPR is then scanned for bare identifier tokens (hex/decimal
literals stripped first so a literal like `$E0` can never masquerade
as a reference to a symbol named `E0`); any token that names a symbol
which is ALSO `equ`'d, but on a LATER line of the SAME file, is
flagged as a forward reference. A token that isn't itself the target
of an `equ` anywhere in the file (an ordinary code label, a kernel
hardware register, etc.) is never flagged -- only equ-to-equ forward
references are the hazard this script exists to catch.

CROSS-FILE LIMITATION (accepted, per the task that added this
script): a `put`-assembled unit can hit the SAME hazard across file
boundaries -- an early-`put` file's `equ` referencing a symbol only
`equ`'d in a file `put` LATER in that unit. This script does NOT
reconstruct each unit's `put` expansion order and does NOT catch that
shape. Same-file analysis catches the overwhelmingly common case (a
block of related equates, one computed from another, TEXTUALLY
reordered by an edit) with no fragile PUT-graph resolution -- see the
task notes for why this tradeoff was accepted rather than deferred
entirely.
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Every unit real Merlin can assemble that isn't already covered by
# check-dual's kernel byte-compare. src/kernel/*.s is intentionally
# absent -- see module docstring.
FILE_GLOBS = [
    'inc/*.equ',
    'src/liba/*.s',
    'src/bin/*.s',
    'src/test/*.s',
]

EQU_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s+equ\s+(.+)$')
IDENT_RE = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
HEX_LIT_RE = re.compile(r'\$[0-9A-Fa-f]+')


def strip_comment(text):
    """Drop a trailing `;...` inline comment. No quoted strings appear
    in this tree's equ EXPRs, so no quote-awareness is needed."""
    idx = text.find(';')
    if idx == -1:
        return text.rstrip()
    return text[:idx].rstrip()


def expr_tokens(expr):
    """Bare identifier tokens in EXPR, hex literals stripped first so
    e.g. `$E0` never reads as a reference to a symbol named `E0`."""
    return set(IDENT_RE.findall(HEX_LIT_RE.sub(' ', expr)))


def find_equs(path):
    """Return [(lineno, sym, expr)] for every `SYM equ EXPR` line in
    the file, in source order. Full-line comments (`*`/`;` in column
    1) are skipped; equ lines never appear inside one in this tree."""
    out = []
    with open(path, encoding='ascii', errors='replace') as f:
        for lineno, line in enumerate(f, start=1):
            if line.startswith('*') or line.startswith(';'):
                continue
            m = EQU_RE.match(line)
            if not m:
                continue
            sym, expr = m.group(1), strip_comment(m.group(2))
            out.append((lineno, sym, expr))
    return out


def check_file(path):
    """Return [(lineno, sym, bad_ref, ref_lineno), ...] -- same-file
    forward-reference findings, source order."""
    equs = find_equs(path)
    def_line = {sym: lineno for lineno, sym, _expr in equs}
    findings = []
    for lineno, sym, expr in equs:
        for tok in sorted(expr_tokens(expr)):
            if tok == sym:
                continue
            tok_def_line = def_line.get(tok)
            if tok_def_line is not None and tok_def_line > lineno:
                findings.append((lineno, sym, tok, tok_def_line))
    return findings



# ---------------------------------------------------------------------
# SECOND AUDIT: the CROSS-`put`, USE-SITE shape -- the one the module
# docstring's "CROSS-FILE LIMITATION" paragraph accepted and deferred.
#
# It bit, on 2026-08-28. `as` running under maux was pointed at real
# maux units for the first time (S9 step 5) and three of nineteen --
# file.s, tee.s, time.s -- failed where merlin32 had always been happy.
# Real Merlin-8 named them: "Illegal forward reference", reported
# against the `equ`'s own DEFINITION line, not the use. Each was an
# `equ` sitting in a file `put` LATE (or below the code in its own
# file) and referenced by an immediate operand assembled EARLIER.
#
# WHAT IS FLAGGED, and why exactly this shape. Merlin-8 must know the
# VALUE of an immediate operand during pass 1 to range-check the byte
# it emits, so a forward `equ` there is fatal. It does NOT need the
# value for `#<SYM` / `#>SYM`, where the byte-select operator says
# which half to take, nor for a bare symbol in an absolute operand,
# where it can assume three bytes. That distinction is not reasoned
# from the manual -- it is what real Merlin-8 actually did on the two
# calibration runs recorded in docs/AS-PUT.md:
#
#   src/bin/du.s          errors on `ldy #RD_STYPE`, `RD_NAME`
#   src/test/processtest.s  CLEAN on `sta SP_TARGET`, `lda #<PAR_PROC_LEN`
#
# The second is the load-bearing one: `check-dual` byte-compares that
# unit against real Merlin every run, so its silence is a measured
# negative and not an absence of evidence. A broader rule that also
# flagged absolute operands would have flagged it, and been wrong.
#
# KNOWN GAP, stated rather than papered over: `lda RD_RECORD+RD_NAME,y`
# in du.s is a real Merlin error this rule does NOT catch (absolute,
# not immediate). Widening to cover it needs more calibration runs
# than the two above, and guessing would cost the false-positive-free
# property that makes this list actionable.
#
# A HARD ZERO since 2026-08-29 -- the burn-down completed the same
# week the ratchet was born (127 -> 109 -> 79 -> 0). The history
# below is kept because the SHAPES recur: hoist pure constants to
# the unit's top block or an earlier-put .equ file; relocate
# `LEN equ *-STR` data blocks above their first use (a put module's
# top is safe -- execution enters via the manifest's jmp; a
# top-level's entry needs a `bra`/`jmp` hop, the bootblock idiom).
# Previously: RATCHET, not a hard zero. The sites are all real and all the same
# shape -- a length/count `equ` written after the code that uses it --
# but several need the constant moved to a DIFFERENT file, not just
# moved up: inc/readdir.equ and inc/cptree.equ were split out
# for exactly that reason, the same fix that closed seek.s and
# libabss.s. They are the measured remainder of S9 step 5: every one is
# a unit real Merlin-8 cannot assemble. NOT verified against `nas`,
# which has its own forward-EQU retry (F_PROV/symprov) and is the
# actual self-host route -- so "cannot self-host" is a claim this
# gate has not earned. docs/NAS-COMMISSIONING.md has the
# measurement that would settle it. Shrink-only: may fall, never
# rise.
#
#   127  2026-08-28, first measurement
#   109  readdir.s's RD_* offsets -> readdir.equ (du/find/ls/cp/mv),
#        cptree/cptreebss's CPT_MAXDEP + CPTE_* -> cptree.equ (cp/mv)
#     0  2026-08-29, same day: the relayout class -- 16 put-body
#        harnesses' string tables to module top, probetest/uttest
#        behind entry hops, prodos.spike behind a jmp-first,
#        sched.common's banner and stickytestb's SCHILD template
#        above their users, UT_ROWS -> inc/ultraterm.equ.
#    79  2026-08-29: src/bin and src/liba are CLEAN -- sh's fifteen
#        cross-module constants hoisted to sh.s's top block,
#        ENV_EQHI/LO -> zp.equ, ld's MODMAX to its own top block.
#        All pure-constant moves: sh.bin/ld.bin/cp.bin byte-identical
#        before and after (cmp'd). What remains is the RELAYOUT class
#        (`LEN equ *-STR` used above the string): 73 harness sites,
#        timer.s x4 + bankprobe.s x1 (kernel, check-dual-gated),
#        bootblock x1 (fixed entry -- take care).
UNIT_IMM_ALLOWANCE = 0

# ...AND THE ROSTER THE COUNT WAS TAKEN OVER, pinned because a count
# alone is gameable in the wrong direction: drop a unit out of the
# top-level manifest set and its bad sites vanish with it, the number
# falls, and the ratchet is satisfied by a LOSS OF COVERAGE. (Adversarial
# review, 2026-08-28.) The roster is derived from the Makefile's own
# merlin32 recipes, so it moves when real units are added or removed --
# which is a deliberate act that should update this line too.
UNIT_ROSTER_EXPECTED = 161       # 159 + 2 (fdatest, fdatestp: DUPFD-1
                                 # phase K, docs/DUPFD-1-NOTES.md);
                                 # 158 + 1 (byetenantr: KFIX2 item 4's
                                 # tenant that rewrites a program,
                                 # src/test/byetenantr.s);
                                 # 157 + 1 (byetenantd: the S4 tenant that
                                 # deletes the loop image, docs/LOOP-S2.md);
                                 # 155 + 2 (mount, umount: docs/VROOT.md,
                                 # 2026-10-09; mntcom.s is a put file).
                                 # 155 = 156 - 1 (docs/KSEG.md, 2026-09-27:
                                 # src/kernel/byelaunch.s retired its
                                 # own org/dsk/typ and its Makefile
                                 # recipe -- it is now `put` into
                                 # src/test/playtest.s's own segment
                                 # block, a MODULE, not a top-level
                                 # unit. This is a loss of a UNIT,
                                 # not of coverage: byelaunch.s is
                                 # still assembled, and forward-ref
                                 # scanned, every time playtest.s is.
                                 # 156 = 154 + 2 (bye slice 2, 2026-09-26:
                                 # src/kernel/byelaunch.s, the
                                 # $D400 launch blob concatenated
                                 # onto byeres.s in byefull.bin,
                                 # and src/test/byetenant.s, the
                                 # real ProDOS .SYSTEM tenant used
                                 # to prove the launch -- both are
                                 # real top-level $(MERLIN32)
                                 # recipes now).
                                 # 154 = 152 + 2 (bye slice 1,
                                 # 2026-09-25: src/bin/bye.s, the
                                 # new util, and src/kernel/
                                 # byeres.s, its own standalone
                                 # $D100 assembly -- both are
                                 # real top-level $(MERLIN32)
                                 # recipes now).
                                 # 152 = 151 + 1 (nulib2, util/nulib2,
                                 # 2026-09-21 -- the NuFX reader;
                                 # its eleven nulib2*.s pieces are
                                 # `put` modules, not units).
                                 # 150 + 1 (chtyp, util/chtyp,
                                 # 2026-09-21 -- the GNO/ME clone;
                                 # ProDOS type and aux).
                                 # 149 + 1 (shutdown, util/
                                 # shutdown, 2026-09-21 -- the
                                 # `shutdown` verb; SYS_HALT is
                                 # the kernel half and is not a
                                 # unit).
                                 # 148 + 1 (patch, util/patch,
                                 # 2026-09-17 -- one more
                                 # single-file top-level unit;
                                 # its six body modules are
                                 # `put`, not units).
                                 # 127 base + 12 from main (dd/
                                 # bpatch/plasma/proshim + nas/
                                 # PLASMA fixtures) + 9 POSIX
                                 # utilities (nohup/timeout/
                                 # realpath/tsort/pr/pathchk/
                                 # split/csplit/join), all landed
                                 # 2026-09-15. Value confirmed by
                                 # this audit's own scan.
                                 # 124 + src/bin/man.s +
                                 # src/bin/cal.s + src/bin/
                                 # strings.s (POSIX man/cal/
                                 # strings, 2026-09-15, posix-
                                 # sed line; all three are
                                 # single-file top-level units,
                                 # no `put` split modules).
                                 # 121 + src/bin/nl.s +
                                 # src/bin/expand.s + src/bin/
                                 # unexpand.s (POSIX nl/expand/
                                 # unexpand, 2026-09-14, posix-
                                 # sed line; all three are
                                 # single-file top-level units,
                                 # no `put` split modules).
                                 # 118 + src/bin/cksum.s +
                                 # src/bin/paste.s + src/bin/
                                 # fold.s (POSIX cksum/paste/
                                 # fold, 2026-09-14, posix-sed
                                 # line; all three are single-
                                 # file top-level units, no
                                 # `put` split modules).
                                 # 115 + src/bin/rmdir.s +
                                 # src/bin/tty.s + src/bin/
                                 # uname.s (POSIX rmdir/tty/
                                 # uname, 2026-09-14, posix-sed
                                 # line; all three are single-
                                 # file top-level units, no
                                 # `put` split modules).
                                 # 113 + src/bin/uuencode.s +
                                 # src/bin/uudecode.s (POSIX
                                 # uuencode/uudecode, 2026-09-14,
                                 # posix-sed line; both are
                                 # single-file top-level units,
                                 # no `put` split modules).
                                 # 110 + src/bin/basename.s +
                                 # src/bin/dirname.s +
                                 # src/bin/env.s (POSIX basename/
                                 # dirname/env, 2026-09-14,
                                 # posix-sed line; all three are
                                 # single-file top-level units,
                                 # no `put` split modules).
                                 # 109 + src/bin/printf.s (POSIX
                                 # printf, 2026-09-14, posix-sed
                                 # line; src/bin/printffmt.s/
                                 # printfnum.s/printfcnv.s are
                                 # `put` targets, not top-level
                                 # units).
                                 # 108 + src/bin/xargs.s (POSIX
                                 # xargs, 2026-09-14, posix-sed
                                 # line; src/bin/xargstok.s is a
                                 # `put` target, not a top-level
                                 # unit).
                                 # 107 + src/bin/cut.s (POSIX cut,
                                 # 2026-09-14, posix-sed line;
                                 # src/bin/cutlist.s is a `put`
                                 # target, not a top-level unit).
                                 # 106 + src/bin/head.s (POSIX head,
                                 # 2026-09-13, posix-sed line).
                                 # 105 + src/test/exprcases.s (2026-09-12);
                                 # 104 + src/bin/tip.s (task #22,
                                 # docs/SERIAL.md sec 3).
                                 # 103 + src/test/sertest.s (the
                                 # /dev/ttya0 serial harness,
                                 # 2026-09-11).
                                 # 102 + src/test/jctest.s (job-
                                 # control B's syscall harness,
                                 # 2026-09-08).
                                 # 100 + src/bin/true.s + false.s
                                 # (POSIX no-ops, 2026-09-07).
                                 # 99 + src/bin/reset.s (terminal
                                 # reinitialise, 2026-09-07).
                                 # 98 + src/bin/vi.s (docs/VI-
                                 # DESIGN.md birth task, 2026-09-02).
                                 # 97 + src/bin/stty.s (stty seed,
                                 # 2026-09-02). 95 + src/bin/ex.s +
                                 # src/test/extest.s
                                 # (swap-file-backed ex, M1, docs/
                                 # EX-DESIGN.md sec 5). 93 + more.s +
                                 # touch.s (the
                                 # pager); 92 + src/bin/kill.s (the
                                 # FLEET friction audit's item 1);
                                 # 91 + src/bin/vidmode.s (video
                                 # mode front-end, 2026-09-01).
                                 # 90 + src/bin/chvt.s (console
                                 # switch front-end, 2026-08-30).
                                 # 89 + src/bin/mld.s: the Merlin
                                 # bridge kept alongside the native
                                 # `ld` that replaced it

# FALSE-NEGATIVE CLASSES, checked against the tree rather than listed
# from imagination (same review). All four are EMPTY today, and the
# measurement is the point -- if any becomes non-empty this analysis
# needs revisiting:
#   macros (`mac`/`eom`/`<<<`)        0 lines
#   conditional assembly (`do`/`fin`) 0 lines
#   `]` variables                     0 lines
#   a unit `put`ting one file twice   0 units
# The last one is why expand_unit() may suppress a repeat visit without
# diverging from Merlin, which would really re-include the text. The
# documented absolute-operand gap (see above) is the one real gap.

IMMEDIATE_RE = re.compile(r'^#\s*([^<>^].*)$')
EQU_ANY_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s+(?:equ|=)\s+(.+)$',
                        re.IGNORECASE)
OPCODE_RE = re.compile(
    r'^(?:[A-Za-z_:\]][A-Za-z0-9_:.\]]*)?\s+([A-Za-z]{2,7})\s*(.*)$')
STRING_RE = re.compile(r"""(['"]).*?\1""")
# Directives whose operand is a filename or literal text, never an
# expression -- tokens inside them are not symbol references.
NON_EXPR_OPS = {'put', 'use', 'putbin', 'dsk', 'asc', 'dci', 'rev',
                'str', 'txt', 'equ'}


def expand_unit(top, graph, seen=None):
    """[(relpath, lineno, text)] in the order real Merlin sees them:
    the manifest's own lines, with each `put`/`use` line followed
    immediately by that file's expansion. Merlin does not nest PUT, so
    this is a flat splice in practice; the recursion is here so a
    future nested chain is expanded rather than silently ignored."""
    seen = seen if seen is not None else set()
    targets = {}
    for edge in graph.get(top, []):
        if edge[0] in ('put', 'use'):
            targets.setdefault(edge[2], edge[1])
    out = []
    with open(top, encoding='ascii', errors='replace') as fh:
        lines = fh.read().split('\n')
    for lineno, line in enumerate(lines, start=1):
        out.append((os.path.relpath(top, ROOT), lineno, line))
        target = targets.get(lineno)
        if target and target not in seen:
            seen.add(target)
            out.extend(expand_unit(target, graph, seen))
    return out


def check_unit_immediates(top, graph):
    """[(file, lineno, symbol, def_file, def_lineno, text)] -- every
    immediate operand referencing an `equ` defined later in this unit's
    own expansion order."""
    stream = expand_unit(top, graph)
    first_equ = {}
    for idx, (_f, _ln, line) in enumerate(stream):
        if not line.strip() or line.startswith(('*', ';')):
            continue
        m = EQU_ANY_RE.match(line)
        if m and m.group(1) not in first_equ:
            first_equ[m.group(1)] = (idx, _f, _ln)
    findings = []
    for idx, (f, lineno, line) in enumerate(stream):
        if not line.strip() or line.startswith(('*', ';')):
            continue
        body = STRING_RE.sub(' ', strip_comment(line))
        m = OPCODE_RE.match(body)
        if not m or m.group(1).lower() in NON_EXPR_OPS:
            continue
        imm = IMMEDIATE_RE.match(m.group(2).strip())
        if not imm:
            continue
        for tok in sorted(expr_tokens(imm.group(1))):
            where = first_equ.get(tok)
            if where is not None and where[0] > idx:
                findings.append((f, lineno, tok, where[1], where[2],
                                 line.strip()[:52]))
    return findings


def unit_immediate_sites():
    """Distinct (file, line, symbol) sites across every top-level unit.
    Distinct, not per-unit: one bad `equ` in a shared liba module is
    ONE thing to fix, however many units `put` it."""
    sys.path.insert(0, os.path.join(ROOT, 'scripts'))
    import check_manifests as cm
    graph, put_targets = cm.build_graph()
    tops = cm.toplevel_manifests(graph, put_targets)
    roster = len(tops)
    seen, rows = set(), []
    for top in sorted(tops):
        for row in check_unit_immediates(top, graph):
            key = (row[0], row[1], row[2])
            if key not in seen:
                seen.add(key)
                rows.append(row)
    return sorted(rows), roster


def main():
    paths = []
    for pattern in FILE_GLOBS:
        paths.extend(sorted(glob.glob(os.path.join(ROOT, pattern))))

    total = 0
    for path in paths:
        rel = os.path.relpath(path, ROOT)
        for lineno, sym, tok, tok_def_line in check_file(path):
            total += 1
            print(f'[check-equ-fwd] FORWARD REF: {rel}:{lineno} '
                  f'`{sym} equ ...` references `{tok}`, which is not '
                  f"equ'd until {rel}:{tok_def_line} -- move {sym} "
                  f'below its dependency (real Merlin caches the '
                  f'wrong pass-1 value here; merlin32 does not)',
                  file=sys.stderr)

    print(f'[check-equ-fwd] scanned {len(paths)} file(s), '
          f'{total} forward reference(s)')
    if total:
        return 1
    print('[check-equ-fwd] PASS: no EQU forward references (same-file '
          'analysis -- see module docstring for the cross-file '
          'limitation)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
