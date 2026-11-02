#!/usr/bin/env python3
"""check_purity.py -- the writable-text audit (docs/STICKY.md sec 21).

WHAT CHANGED 2026-08-22 (sec 21 supersedes sec 17-20). The audit used
to run only on programs that ADOPTED sec 17's `BSS_BEG`/`BSS_END` +
`jsr ZEROBSS` convention, and it failed if nobody had. That convention
is retired -- nothing zeroes a program's storage any more, so there is
nothing to adopt and no adoption marker in any source file. Three
things replaced it:

  1. THE LIBA RATCHET IS NOW TREE-WIDE. It scans every src/bin
     program, not just the one adopter. That is what makes it a gate
     at all now, and it immediately showed the old scope was hiding
     more than it caught: cat.s links six liba modules, so the other
     six (getopt, glob, hex, num, readdir, seek -- 42 more cells) had
     NEVER been audited. Those 42 were converted the same day
     (docs/STICKY.md sec 25), so LIBA_DEBT is now EMPTY and every
     entry in it is an empty set held open as a tripwire.
  2. THE SEC-21 STRUCTURAL CHECKS. src/liba/libabss.s's arena must be
     the LAST thing every program `put`s and nothing may be emitted
     after it, because a `dum` block opened before still-emitted code
     is silently overlaid by it; a program's own arena must anchor at
     LIBA_BSSEND rather than `*`, because two blocks anchored at `*`
     are the same bytes; and the zero-requiring group at the top of
     libabss.s must still fit the kernel's page, whose length is
     spelled in two files that cannot include each other.
  3. A PURITY ROSTER. `cat` is the one program whose own text is
     provably clean (docs/STICKY.md sec 18). That is worth keeping
     enforced, so it is named in PURE_PROGRAMS below -- a script-side
     list, not a marker in the source, because sec 21's whole point
     is that a program declares nothing.

WHY THIS IS NOT IN `ld`. docs/STICKY.md sec 17 asks `ld` to reject
writable text, so the "text is immutable" claim is enforced rather than
asserted. It cannot be, and the reason is structural rather than a
matter of effort:

  * `ld` links REL modules. A REL file is code bytes plus a
    relocation/symbol dictionary (docs/REL-LIBA-SPIKE.md, measured
    against real Merlin-8). The dictionary says which OPERANDS need
    relocating and which names are ENT/EXT. It says nothing about which
    addresses any instruction WRITES -- deciding that means
    disassembling the code stream and classifying every store, at link
    time, on a 1 MHz 6502, and even then indexed and pointer-indirect
    stores do not resolve.
  * `ld`'s output is gated BYTE-IDENTICAL against the stock Merlin-8
    LINK (scripts/check_ld.py), so `ld` may not add anything to an
    image either.
  * And no src/bin binary is built by `ld` at all today: every one is a
    whole-program merlin32 `put` assembly. An `ld`-side check would
    police nothing that currently exists.

So the check lives where the information does -- in the source, before
the assembler, alongside the tree's other structural gates. Run from
scripts/check_modules.py (`make check-modules`); independently runnable
as `python3 scripts/check_purity.py`.

WHAT IT CHECKS. Whether a program's text is immutable, audited across
the WHOLE program: the src/bin file plus every `put ../liba/*.s`
module it names, because a routine in liba writing its own emitted
cell dirties the caller's text just as surely as the caller doing it
inline.

FOUR WRITE SHAPES, because a partial audit is worse than none (the
sweep that produced sec 17's own 603-label figure saw only the first
of these, and would have passed cat.s's PATHBUF -- written by MKPATH
through PTR1 -- as clean):

  A. DIRECT. `sta LABEL`, and equally `sta LABEL,x` / `sta LABEL+3,y`
     / `inc LABEL` / `stz LABEL` / `trb LABEL` / `asl LABEL,x`. The
     base symbol of the operand expression is what matters, not the
     addressing mode.
  B. POINTER-INDIRECT. `sta (ZP),y` cannot name its target, so the
     audit works backwards: it collects every zero-page pair used as an
     indirect STORE destination anywhere in the program, then flags any
     place a text label's address is loaded into one of them
     (`lda #<LABEL` ... `sta ZP`). This is how MKPATH writes PATHBUF,
     how STRCPY writes its destination, and how sec 9's parmlist
     patching reaches print.s's own cells.
  C. KERNEL-WRITTEN BUFFER. A text label named by a `da`/`dw`/`adr`
     data word is an address handed to something -- in this tree,
     overwhelmingly, an MLI parmlist's data_buffer. The kernel's
     copyout writes it. The audit cannot tell a read buffer's pointer
     from a jump table's entry, so it reports these separately and
     treats them as unproven rather than proven-clean.
  D. PARMLIST HANDED TO A SYSCALL. `lda #<BLOCK / ldx #>BLOCK / jsr
     SC_*` gives the kernel a block it writes results back into
     (ref_num, trans_count) via copyout. Nothing in the source stores
     to those fields, so shapes A-C see a perfectly clean, never-
     written datum -- which is exactly the audit-that-misses-a-whole-
     class failure this gate is supposed to avoid. The write is real
     and it is the kernel's.

WHAT IT STILL CANNOT SEE, stated so nobody mistakes a pass for a
proof: a computed store address assembled at runtime from arithmetic
this scan does not follow; a pointer pair loaded from a table rather
than from an immediate; self-modifying code that patches an operand
byte belonging to an instruction rather than to a labelled datum. The
first two would need real dataflow; the third is DECLARED rather than
detected in this tree (docs/STICKY.md sec 9 blocker 3 --
src/bin/asrom.s self-modifies by design and simply never adopts the
convention, so it is never audited).

One more, narrower: a bare label followed by a data line whose OWN
label is different (two names for one datum) registers the datum under
the second name only, so a write through the first name is missed. The
common single-name spelling -- a bare label above an unlabelled data
line -- IS handled; see expand()'s `pending`.
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

IDENT = re.compile(r'[A-Za-z_][A-Za-z0-9_.]*')

# Directives that EMIT bytes into the image. `ds` is here on purpose:
# merlin32 emits its reserved bytes as real zeros (house finding, commit
# b036def, read from Merlin's own source), which is the whole reason
# sec 17 exists. `equ`/`=`/`dum`/`dend`/`org` and the assembler-control
# directives emit nothing and define no storage.
DATA_OPS = {
    'dfb', 'db', 'da', 'dw', 'ddb', 'adr', 'adrl', 'ds', 'hex', 'dfl',
    'asc', 'dci', 'inv', 'fls', 'rev', 'str', 'strl', 'txt', 'putbin',
}

# Opcodes that write memory. asl/lsr/rol/ror/inc/dec only write memory
# when they carry a real operand -- with `a` or nothing they are
# accumulator forms, filtered at the call site.
WRITE_OPS = {'sta', 'stx', 'sty', 'stz', 'trb', 'tsb',
             'inc', 'dec', 'asl', 'lsr', 'rol', 'ror'}

ADDR_WORD_OPS = {'da', 'dw', 'adr', 'adrl', 'ddb'}


class Line:
    __slots__ = ('file', 'no', 'label', 'op', 'operand', 'in_dum')

    def __init__(self, file, no, label, op, operand, in_dum):
        self.file, self.no = file, no
        self.label, self.op, self.operand, self.in_dum = \
            label, op, operand, in_dum

    def where(self):
        return f'{self.file}:{self.no}'


def _fields(raw):
    """Split one Merlin line into (label, opcode, operand).

    Merlin's comment needs no delimiter -- everything past the operand
    field is prose -- so only the first three whitespace-separated
    fields may ever be read, and a field beginning ';' ends the line.
    """
    if not raw.strip() or raw.lstrip()[:1] in ('*', ';'):
        return None
    line = raw.rstrip('\n')
    label = ''
    if line[:1] not in (' ', '\t'):
        m = IDENT.match(line)
        if not m:
            return None
        label = m.group(0)
        line = line[m.end():]
    parts = line.split()
    if not parts or parts[0].startswith(';'):
        return (label, '', '')
    op = parts[0].lower()
    operand = parts[1] if len(parts) > 1 else ''
    if operand.startswith(';'):
        operand = ''
    return (label, op, operand)


def expand(path, seen=None):
    """One program's full source: the file plus every module it `put`s.

    Nested `put` does not exist in either dialect (check_manifests.py
    gates that), so one level of recursion is the whole graph -- but the
    recursion is written anyway so a future violation shows up as a
    cycle guard rather than as silently missing lines.
    """
    seen = seen if seen is not None else set()
    out = []
    rel = os.path.relpath(path, ROOT)
    if rel in seen:
        return out
    seen.add(rel)
    depth = 0
    # A label ALONE on its line names the address of whatever the next
    # line emits -- `CTBN_PTH_TXT` / `dfb $AF,...` is the tree's usual
    # spelling for a table whose bytes would not fit beside the label.
    # Without carrying it forward, that table is invisible to the audit
    # and every write to it reads as clean. Only carried onto a line
    # that has no label of its own.
    pending = ''
    for no, raw in enumerate(open(path, errors='replace'), 1):
        f = _fields(raw)
        if f is None:
            continue
        label, op, operand = f
        if not op:
            # Keep the row (adoption is decided by label NAMES being
            # present) and remember it for the next emitting line.
            if label:
                pending = label
                out.append(Line(rel, no, label, '', '', depth > 0))
            continue
        if op in ('dum', 'dend', 'put', 'use'):
            pending = ''
        elif not label and pending:
            label, pending = pending, ''
        else:
            pending = ''
        if op in ('put', 'use'):
            target = os.path.normpath(
                os.path.join(os.path.dirname(path), operand))
            for ext in ('', '.s', '.equ'):
                if os.path.exists(target + ext):
                    out += expand(target + ext, seen)
                    break
            continue
        if op == 'dum':
            depth += 1
            continue
        if op == 'dend':
            depth = max(0, depth - 1)
            continue
        out.append(Line(rel, no, label, op, operand, depth > 0))
    return out


def base_symbol(operand):
    """The symbol an operand's ADDRESS expression is rooted at.

    `LABEL`, `LABEL,x`, `LABEL+3`, `LABEL+3,y` all root at LABEL. An
    immediate (`#...`) is not an address. `(...)` is indirect and is
    handled separately -- returning its inner symbol here would report a
    ZP pointer name as if it were the write target.
    """
    if not operand or operand[0] in '#(':
        return None
    m = IDENT.match(operand)
    if not m:
        return None
    sym = m.group(0)
    return None if sym.lower() in ('a', 'x', 'y') else sym


def indirect_symbol(operand):
    """The ZP pointer name inside `(SYM),y` / `(SYM,x)` / `(SYM)`."""
    if not operand.startswith('('):
        return None
    m = IDENT.match(operand[1:])
    return m.group(0) if m else None


SHAPES = ('direct', 'indirect', 'addrword', 'syscall')


def find_writes(lines):
    """The four write shapes over one expanded program.

    Returns {shape: [(site, symbol, declaration, extra)]}, where `site`
    is the writing line and `declaration` the line that emitted the
    datum. One implementation, used by both the per-program audit and
    the liba ledger, so the two can never disagree about what a write
    is.
    """
    text_data = {}
    for ln in lines:
        if ln.label and ln.op in DATA_OPS and not ln.in_dum:
            text_data.setdefault(ln.label, ln)

    # (B) prep: every ZP pair used as an indirect STORE destination.
    ptr_dests = set()
    for ln in lines:
        if ln.op in ('sta', 'stx', 'sty'):
            sym = indirect_symbol(ln.operand)
            if sym:
                ptr_dests.add(sym)

    out = {k: [] for k in SHAPES}
    for i, ln in enumerate(lines):
        # (A) direct write to an emitted label.
        if ln.op in WRITE_OPS and ln.operand:
            sym = base_symbol(ln.operand)
            if sym and sym in text_data:
                out['direct'].append((ln, sym, text_data[sym], None))

        # (B)/(D) both start `lda #<SYM`. The window is deliberately
        # short: liba and src/bin both spell these as an adjacent
        # lda/sta or lda/ldx/jsr triple, and widening it would start
        # matching unrelated stores to the same ZP cell.
        if ln.op == 'lda' and ln.operand.startswith(('#<', '#>')):
            m = IDENT.match(ln.operand[2:])
            if m and m.group(0) in text_data:
                sym = m.group(0)
                for nxt in lines[i + 1:i + 4]:
                    if nxt.op == 'sta' and nxt.operand:
                        dst = re.sub(r'\+1$', '', nxt.operand)
                        if dst in ptr_dests:
                            out['indirect'].append(
                                (ln, sym, text_data[sym], dst))
                            break
                    if nxt.op in ('jsr', 'jmp') and \
                            nxt.operand.startswith('SC_'):
                        out['syscall'].append(
                            (ln, sym, text_data[sym], nxt.operand))
                        break

        # (C) a text label's address emitted as a data word.
        if ln.op in ADDR_WORD_OPS and ln.operand:
            sym = base_symbol(ln.operand)
            if sym and sym in text_data:
                out['addrword'].append((ln, sym, text_data[sym], None))
    return out


def audit(program):
    """Audit one src/bin/*.s program's OWN text. Returns findings.

    Findings are narrowed to writes whose SITE or whose DECLARATION is
    in the program's own file: liba's own dirty cells are the library's
    debt, tracked separately by liba_debt_scan() so that one program
    does not present ten modules' worth of shared debt as its failure.
    """
    lines = expand(os.path.join(ROOT, program))
    own = os.path.basename(program)
    findings = find_writes(lines)
    for k in findings:
        findings[k] = [f for f in findings[k]
                       if os.path.basename(f[0].file) == own
                       or os.path.basename(f[2].file) == own]
    return findings


# Programs whose OWN text is proven immutable, and must stay that way.
# GROW-ONLY, the opposite ratchet from LIBA_DEBT: a program leaves this
# list only by being deleted. docs/STICKY.md sec 17 counted 603
# emitted-and-written labels across 41 modules, so this list is short
# by design and converting the rest is its own project (sec 17 step 3),
# NOT a precondition for anything -- under sec 21 an unconverted
# program is merely un-warm-respawnable, never incorrect.
PURE_PROGRAMS = ['src/bin/cat.s']


# ---------------------------------------------------------------------
# THE RUNTIME ROSTER (docs/STICKY.md sec 29). SITS ALONGSIDE
# PURE_PROGRAMS, and does not replace it: the two answer different
# questions and neither implies the other.
#
#   PURE_PROGRAMS is a SOURCE-level claim -- "no instruction in this
#   program's source writes an emitted datum" -- checked by the four
#   write shapes above, over the program plus every liba module it
#   `put`s. It can prove a program clean without ever running it, and
#   it is blind to a computed store address (its own header says so).
#
#   The rosters below are a MEASUREMENT -- "after this program did
#   real work under maux, its image in the bank was/was not still
#   byte-identical to its .bin". scripts/check_textaudit.py stops the
#   kernel on its own retire path (LZ_RETAIN), reads the dying bank's
#   tag for the program and the image length, and diffs. It cannot be
#   fooled by a computed address; it also cannot say anything about an
#   input the audit did not run.
#
# WHY A DECLARATION AT ALL, when the measurement is in front of us:
# docs/STICKY.md sec 9 blocker 3 -- immutability must be DECLARED, not
# assumed -- and the kernel's own guard (sec 27) checks 8 bytes and is
# explicitly not a proof. A roster turns "nobody has looked" into
# "this was measured on this workload", and makes a REGRESSION loud.
#
# THREE CLASSES, because CLEAN/DIRTY is the wrong split
# (learning:01M0MEKF0H8AVAXJG4PZ7P5QXC -- "writes its own text is the
# wrong discriminator"; what breaks a warm respawn is reading a cell
# it did not write this run, which is not statically decidable).
#
# Names are program names (src/bin/<name>.s), not paths: the runtime
# audit knows programs by the pathname the kernel tagged their bank
# with, and mapping that back to a source path is one more place to be
# wrong.
# ---------------------------------------------------------------------

# MEASURED 2026-08-22 by `make check-textaudit`, over the workloads in
# scripts/build_textaudit_image.py's STEPS table. TWO of thirty-three
# spawnable programs came back byte-identical. `cat` is also the one
# program PURE_PROGRAMS proves clean statically, which is the two
# audits agreeing from opposite directions.
#
# `date` CARRIES A CAVEAT, stated so nobody reads more into it. Its
# emitted cells (CLKBUF/HOURV/MINUTEV/DAYV/MONTHV/YEAR7/PR2DONE) are
# filled only on the VALID-CLOCK path, and on the audit rig the
# ProDOS global-page stamp fails date's legacy validity check -- so
# the run measured is the "no valid clock reading" refusal, on which
# those cells keep the zeros `ds` emitted. If that path ever becomes
# reachable here, date will measure dirty and this gate will go red;
# that is a TRUE red (date does write its own text on that path) and
# the fix is to move date into TEXT_MUTABLE, not to silence it.
# check-sumdate gates both of date's paths against a raw $BF90-93.
#
# THIS SET IS GROW-ONLY: measuring one of these dirty is a hard
# failure, and a program joins it only by being measured clean.
TEXT_IMMUTABLE = {
    # -- `nulib2` (2026-09-21), declared on the MEASUREMENT and not on
    # -- the intent: check-textaudit's group-b pair reports 0 bytes
    # -- moved, cold and warm, over a 4,294-byte image. It was written
    # -- with its OPEN/READ/CLOSE parmlists in the `dum` arena from the
    # -- first line BECAUSE of what chtyp's entry below records --
    # -- emitted parmlists are image bytes the MLI writes into, and a
    # -- retained bank hands the next warm respawn the last run's
    # -- values. Its only other per-run state is the record walk's
    # -- counters and buffers, all arena; its text is code, six
    # -- message strings and the two NuFX signature constants.
    'nulib2',
    # -- `kill` and `more` (2026-09-01): every cell they own is in
    # -- the dum arena (kill's PIDVAL/OPSAVE run; more's paging
    # -- state and parmlists -- its OPARM/RPARM/CPARM are STORED by
    # -- INITPARMS, not emitted), so their text is code + message
    # -- strings only. Parked in TEXT_MUTABLE on arrival, promoted
    # -- the day check-textaudit's group-d pairs measured them
    # -- CLEAN.
    'kill',
    'more',
    # -- `chtyp` (2026-09-21), and it EARNED this the hard way. It was
    # -- declared immutable on the assumption that its two MLI
    # -- parmlists, being written field by field from GET_FILE_INFO
    # -- before every SET_FILE_INFO, were not "text" -- but they were
    # -- EMITTED `dfb`/`da` data, so they were image bytes, and
    # -- check-textaudit measured 22 of 2,437 of them mutating across
    # -- two runs. The declaration was wrong and the gate said so.
    # -- The parmlists now live in the `dum` arena with their count
    # -- bytes stored by START (more.s's INITPARMS precedent), which
    # -- is also the right answer on its own terms: a retained bank
    # -- no longer hands the next run the previous run's parmlist.
    'chtyp',
    # -- `mount` / `umount` (2026-10-09, docs/VROOT.md): every parmlist
    # -- and buffer is in the `dum` arena (MNT_OPARM/MNT_VPARM/MNT_ONBUF/
    # -- MNT_NM...), their text is code, messages and read-only tables.
    'mount',
    'umount',
    # -- `cal` (2026-09-15) does no file I/O at all -- no OPARM/
    # -- RPARM/CPARM parmlist, nothing an MLI call writes back
    # -- into. Every cell it owns (CAL_MON/CAL_YEAR/CD_*/NUM/
    # -- DEN/REM/TITLEBUF/etc.) is in the `dum` arena past
    # -- LIBA_BSSEND; its text is code, tables (DAYSTAB/SAKTAB/
    # -- MONNAMES) and message strings only.
    'cal',
    # -- `timeout` (eng-nohup-timeout-realpath, cut from a9034eb)
    # -- does no MLI file I/O at all -- only SC_SPAWN/SC_WAIT/
    # -- SC_WAITJOB/SC_KILL/SC_TICK/SC_SIGNAL, all of which route
    # -- through PROCPARM in libabss.s's own shared `dum` arena,
    # -- not through any parmlist TIMEOUT.S itself emits -- the
    # -- same reason `env`/`time` are here rather than in
    # -- TEXT_MUTABLE. Every cell it owns (TO_*, TICKBUF/TARGET/
    # -- KTARGET/WJSTAT/WSTATUS/TO_ENVLST/ARGVLIST) is in the
    # -- `dum` arena past LIBA_BSSEND; its emitted text is code,
    # -- PERITAB (a read-only constant table, never written) and
    # -- message/name strings only.
    'timeout',
    # -- `chvt` (2026-08-30) writes ESC [ n z with four PUTCs rather
    # -- than patching a digit into an assembled string, which is what
    # -- the first draft did -- so it has no mutable text and no bss
    # -- at all. This gate is why: it refused the patched version by
    # -- name, correctly.
    'chvt',
    # -- `vidmode` (2026-09-01) is chvt's sibling: escapes emitted
    # -- byte-at-a-time through PUTC, never a patched string, and
    # -- every cell it owns (COLSREQ/DISCREQ/ARGN/DIGT/GEOBUF) is in
    # -- the `dum` arena past LIBA_BSSEND -- SYS_TTYGEO writes its
    # -- four bytes there, not into text. Measured by check-textaudit
    # -- group a's repeat pair (the parse + not-a-console refusal
    # -- path; the running path moves the glass and is gated by
    # -- check-play's vidmode phase instead -- sleep's split, below).
    'vidmode',
    # -- `sleep` joined 2026-08-26 by measurement in check-textaudit
    # -- group b, whose harness links NO timer driver: SYS_TICK reports
    # -- mode 0 there and sleep refuses on fd 2, byte-identically across
    # -- a repeat pair into the same warm bank. Its RUNNING path is
    # -- gated separately by check-play, whose harness does link
    # -- src/kernel/timer.s.
    'sleep',
    # -- `time` joined 2026-08-26 on the same measurement, in the
    # -- same group, and for the same reason: it refuses on fd 2
    # -- where no timer driver is linked. Its RUNNING path is
    # -- gated by check-play beside sleep's.
    'time',
    'cat', 'date',
    # dd, bpatch: promoted from TEXT_MUTABLE 2026-09-08 the day
    # check-textaudit's group-b poison pair measured both CLEAN over
    # 2 runs (the kill/more path). Every writable cell is in their
    # dum arenas, write-before-read; their emitted parmlists/keyword
    # table are constant. dd: `DD if=/mnt/MAUX/SEED bs=16 count=1`;
    # bpatch: the PAIRX comparing two patched targets.
    'dd', 'bpatch',
    # Joined 2026-08-22 by measurement, as a SIDE EFFECT of the
    # sec 28 `ds`->`dum` sweep. Each was measured DIRTY before it
    # and CLEAN after: their mutable cells were emitted storage
    # INSIDE the image, and the sweep moved them to arenas past
    # the image end, where a write cannot dirty text. The sweep
    # was undertaken for spawn cost; text purity for eight
    # programs is the part nobody was aiming at.
    'echo', 'ls', 'mkdir', 'mv', 'ps', 'pwd', 'rm', 'tr',
    # `xargs` (2026-09-14): parked in TEXT_MUTABLE on arrival (its
    # RPARM's RPARM_TRANS field is real, kernel-written data), promoted
    # the same day check-textaudit's group-b repeat pair measured it
    # CLEAN over 3 real WARM respawns (not a vacuous pair -- fixed
    # first: the pair's own command needed an absolute utility path,
    # this harness's sh session never exports PATH).
    'xargs',
    # `printf` (2026-09-14): parked in TEXT_UNAUDITED on arrival,
    # promoted the same day check-textaudit's group-b repeat pair
    # (PF/PF2, %s and %d/%x width) measured it CLEAN over 3 real WARM
    # respawns -- 0 dirty bytes, matching its own design (every
    # mutable cell is in the `dum` arena past LIBA_BSSEND; every
    # emitted string is read-only). The SAME respawn chain also
    # caught a real bug fixed the same day: USAGEMSG's own bytes used
    # to sit between `org LOAD_BASE` and START, so every spawn began
    # by executing that string as opcodes -- harmless by luck on a
    # cold load's default registers, but a warm respawn inherits the
    # PREVIOUS run's leftover registers into that same garbage
    # prefix, and one concrete case (a numeric-diagnostic exit 1
    # immediately followed by a warm no-conversion run that should
    # exit 0) reproduced it live before the fix moved USAGEMSG after
    # all real code, the same shape xargs.s's own data already keeps.
    'printf',
    # `basename`/`dirname`/`env` (2026-09-14): parked in
    # TEXT_UNAUDITED on arrival, promoted the same day
    # check-textaudit's group-b PAIR rows (BN, DN, EV, EV2)
    # measured all three CLEAN over real WARM respawns -- 0 dirty
    # bytes each, matching their own design (every mutable cell
    # is in the `dum` arena past LIBA_BSSEND; basename.s/
    # dirname.s emit no writable text at all -- no MLI call of
    # any kind -- and env.s's own SC_SPAWN/SC_WAIT parmlist lives
    # in liba's PROCPARM, not in anything env.s itself emits).
    'basename', 'dirname', 'env',
    # `rmdir`/`tty`/`uname` (2026-09-14): parked in TEXT_UNAUDITED on
    # arrival, promoted the same day check-textaudit's group-c rows
    # measured all three CLEAN -- 0 bytes moved each (rmdir: 1 run,
    # ONCE, mkdir.s's/rm.s's own shape, no output to pair against
    # itself; tty/uname: PAIR, 2 runs each, the SECOND served WARM
    # and still 0 moved). rmdir's DPARM (MLI DESTROY) is EMITTED but
    # DESTROY writes nothing back, rm.s's own precedent; tty makes no
    # MLI call at all and has no bss of its own; uname makes no MLI
    # call either and every mutable cell (SFLAG/NFLAG/RFLAG/VFLAG/
    # MFLAG/NEEDSP) is in the `dum` arena past LIBA_BSSEND.
    'rmdir', 'tty', 'uname',
}

# name -> does the ENTRY HEAD move? The head is the only thing the
# kernel checks (LZ_HEAD_LEN = 8 bytes at LOAD_BASE), so this bit is
# the difference between two very different situations:
#
#   head=True   the kernel REFUSES to retain the bank. The program
#               cold-loads on every spawn, exactly as before lazy
#               free: slower, and safe.
#   head=False  the kernel RETAINS the bank and the next spawn of this
#               program runs on the mutated text. Safe only if every
#               moved cell is written before it is read -- which is
#               not statically decidable
#               (learning:01M0MEKF0H8AVAXJG4PZ7P5QXC) and is tested,
#               per program, by check-textaudit's repeat pairs.
#
# THIS SET MAY ONLY SHRINK. A program leaves it by being measured
# clean, which is a real improvement (its warm respawn stops depending
# on write-before-read); a stale entry fails too.
TEXT_MUTABLE = {
    'as': False,
    'chmod': False, 'cmp': False, 'comm': False, 'cp': False,
    'df': False, 'diff': False, 'du': False, 'ed': False, 'ex': False,
    'expr': False, 'file': False, 'find': False, 'grep': False,
    'ld': False,
    # make: declared on arrival (2026-08-30), same shape as sed and
    # grep -- its three MLI parmlists (MKOPARM/MKRPARM/MKCPARM, the
    # makefile reader's own) are emitted data the kernel writes
    # results back into: MKOPARM_REF on the open, MKRPARM_TRN on
    # every read. Everything else it owns -- the rule table, the
    # makefile text, GFIPARM, the spawn parmlist and argv -- is in
    # the `dum` arena. Its entry head does not move.
    'make': False,
    # kill and more: parked here conservatively on arrival
    # (2026-09-01) and REMOVED the same day -- check-textaudit's
    # group-d pairs measured both CLEAN (all their cells are
    # dum-arena; emitted text is code + messages only).
    # touch stays: its GFIPARM/SFIPARM/CRPARM are EMITTED data the
    # kernel writes results back into (write shape D, chmod's own
    # reason), exercised by group d's ONCE.
    'touch': False,
    'nm': False,
    'od': False, 'sh': False,
    # sed: declared on arrival (2026-08-23) -- its three MLI parmlists
    # are emitted data the kernel writes results into (write shape D),
    # the same reason grep is here; every other cell is `dum`. Its
    # entry head does not move. Measured by check-textaudit's group-d
    # repeat pair from the day it shipped.
    'sed': False,
    'head': False,
    'cut': False,
    'sort': False, 'sum': False, 'tail': False, 'tee': False,
    'uniq': False, 'wc': False,
    'uuencode': False, 'uudecode': False,
    # cksum/paste/fold (2026-09-14): each has the same OPARM_REF/
    # RPARM_TRANS/CPARM_REF emitted MLI parmlist cells as cut.s/
    # head.s/sum.s -- the kernel writes results back into them (an
    # open's own fd, a read's own transfer count), same reason,
    # same False.
    'cksum': False, 'paste': False, 'fold': False,
    # nl/expand/unexpand (2026-09-14): same shape -- each has the
    # same OPARM_REF/RPARM_TRANS/CPARM_REF emitted MLI parmlist
    # cells as cut.s/head.s/fold.s, same reason, same False.
    'nl': False, 'expand': False, 'unexpand': False,
    # man/strings (2026-09-15): same shape -- each has the same
    # OPARM_REF/RPARM_TRANS/CPARM_REF emitted MLI parmlist cells
    # as od.s/head.s, same reason, same False. (`cal` has no
    # file I/O at all and is TEXT_IMMUTABLE instead, above.)
    'man': False, 'strings': False,
    # nohup (eng-nohup-timeout-realpath, cut from a9034eb): the
    # SAME shape tee.s's own `-a` append path has -- NH_CRPARM/
    # NH_OPARM/NH_CPARM are emitted MLI parmlists, and NH_OPARM_RF
    # is written back into by SC_OPEN's own result, same reason,
    # same False.
    'nohup': False,
    # realpath (eng-nohup-timeout-realpath, cut from a9034eb): the
    # SAME shape chmod.s/du.s/file.s/touch.s already have -- an
    # emitted RP_GFI parmlist (testeval.s's own TE_GFI package)
    # whose ACC/FTYP/AUX/STYP/BLKS/MDT/MTM/CDT/CTM fields SC_GFI
    # writes results back into, same reason, same False.
    'realpath': False,
    # tsort/pr (2026-09-15): same shape -- each has the same
    # OPARM_REF/RPARM_TRANS/CPARM_REF emitted MLI parmlist cells
    # as cut.s/head.s/nl.s (a file operand, or stdin); pr also
    # carries GFIPARM's own MDATE/MTIME/STYP fields (GET_FILE_
    # INFO writes results back), the same write shape touch.s's
    # own GFIPARM/SFIPARM already carries. Same reason, same
    # False.
    'tsort': False, 'pr': False,
    # pathchk (2026-09-15): makes NO file open/read/close call at
    # all, but its own GXPARM IS emitted data GET_FILE_INFO
    # writes results back into (ACC/FTYP/AUX/STYP/BLKS/MDATE/
    # MTIME/CDATE/CTIME) whenever the default (non -p) existence
    # check runs -- the same write shape as touch.s's GFIPARM,
    # not the "no MLI call at all" shape `cal`/tty/uname have.
    # Same reason, same False.
    'pathchk': False,
    # split/csplit/join (2026-09-15, eng-split-csplit-join): same
    # shape -- each has the same OPARM_REF/RPARM_TRANS/CPARM_REF
    # emitted MLI parmlist cells as head.s/comm.s, same reason,
    # same False.
    'split': False,
    'csplit': False,
    'join': False,
    # patch (2026-09-17, util/patch): same shape -- IOPARM_REF/
    # RPARM_TRANS/CPARM_REF emitted MLI parmlist cells, plus
    # liba/creat.s's own CR8_* set, which every CREAT caller
    # already carries. Same reason, same False.
    'patch': False,
}

# The two that need more than a bit. Everything else in TEXT_MUTABLE
# is an ordinary program with an MLI parmlist or a buffer inside its
# image -- the same four write shapes this file's static audit already
# reports, seen from the other side.
TEXT_MUTABLE_NOTES = {
    'sh': 'THE ONE THIS AUDIT COULD NOT PAIR, and it was broken. sec '
          '29 measured sh DIRTY-TAIL -- it writes its own image and '
          'its entry head does not move, so the kernel retains its '
          'bank -- with no repeat pair, because nothing in the tree '
          'spawned sh twice in one boot. `make check-shwarm` '
          '(2026-08-23, docs/STICKY.md sec 32) arranges the second '
          'one: the outer sh spawns two NESTED shells adjacently from '
          'byte-identical scripts, and the retained bank\'s arena AND '
          'sh\'s emitted scratch cells are poisoned with $A5 between '
          'them. Run 2 came back with run 1\'s $? and run 1\'s '
          'variables -- LASTSTATUS and VARNAMES are two of the seven '
          'cells sec 28 kept as REAL EMITTED ZEROS because a REPL '
          'reads them on its first pass, and an emitted zero is a '
          'property of the LOADER, which lazy free stopped running. '
          'sh.s establishes them itself now (SH_INIT_ZR, +41 B). It '
          'stays TEXT_MUTABLE: the cells still move, they are simply '
          'no longer read before they are written.',
    'as': 'a port of Merlin 8\'s 1982 assembler core, which uses its '
          'own image as workspace. Stream T5 (docs/FINISH.md item C) '
          'cured the entry-head hazard sec 27 found -- PREEXIT now '
          'funnels every exit through RESTHEAD (restores $0800-$89F to '
          'match the file on disk) then CHKBLOB/STAMPHEAD (the sec-31 '
          'backstop transplanted from `ld`, defense in depth through '
          'the same LZ_RETAIN head check). The head no longer moves, so '
          'LZ_RETAIN now RETAINS the bank -- measured 11,749 B image, '
          '48 B moved (its own `dum LIBA_BSSEND`/`dend` arena, same '
          'idiom as every other converted program), 0 in the entry '
          'head. `check-as` confirms runs 2-5 report WARM and stay '
          'byte-identical against merlin32 on the host.',
    # `ld` IS THE NATIVE LINKER NOW (docs/LD-NATIVE.md). None of the
    # Merlin-core story applies to it: it embeds no core, so it has
    # no sacrificial region and nothing is expected to damage it.
    #
    # THE BRIDGE'S HISTORY, kept because it is why several gates
    # exist: as `ld` it moved ~8,870 of its 20,244 image bytes with
    # its entry head INTACT, so the kernel retained its bank and the
    # SECOND `ld` of a boot died with `internal: exit pad not found`
    # and wrote no output (docs/STICKY.md sec 29). 8,634 of those
    # bytes were the embedded Merlin core, copied to $D000 and then
    # zeroed because the blobs sat where LINKER wants its dictionary;
    # sec 31 moved them above a dedicated window. That program is
    # `mld` now, and it is no longer text-audited.
    'ld': 'the native two-pass linker. What the kernel writes back '
          'into is its MLI parmlists -- OPARM_REF on every open, '
          'RPARM_TRN on every read. Everything it owns is in the '
          '`dum` arena and the image it builds is at BUILDBASE, far '
          'above its own text. It embeds no Merlin core, so unlike '
          'the bridge it replaced it has no sacrificial region.',
}

# PROGRAMS THAT ARE BROKEN BY THEIR OWN WARM RESPAWN, measured.
#
# check-textaudit runs each program TWICE with byte-identical
# arguments, adjacently, so the second run is served out of the bank
# the first run left behind, and requires the two outputs to be
# byte-identical. Everything in the tree passes that except what is
# named here -- and for these the gate asserts the FAILURE, so that
# fixing one turns the gate red and forces the entry out. A ratchet
# that only records good news stops being read.
#
# THIS SET MAY ONLY SHRINK, and every entry is a live defect.
# EMPTY SINCE 2026-08-23, and that is the ratchet working. `ld` was
# its only member, from sec 29 until sec 31 fixed it: the second `ld`
# of a boot inherited its own zeroed core and died in FINDPADS. The
# fix was a layout one -- the embedded core moved above the window
# LINKER writes its dictionary into, and nothing writes it any more --
# not the "let a program decline retention" syscall sec 27 imagined,
# which is still unbuilt and still an operator ruling if it is ever
# wanted. Adding an entry here means a program was MEASURED broken by
# its own warm respawn and the gate asserts that failure until someone
# removes it.
WARM_UNSAFE = {}

TEXT_UNAUDITED = {
    'shutdown': 'STRUCTURALLY unmeasurable on its success path, not '
                'merely unmeasured (2026-09-21). It owns no cell at '
                'all -- a `dum` arena past LIBA_BSSEND for the '
                'tripwire and nothing else -- and its text is code '
                'plus three message strings, so it is immutable by '
                'construction in reset/true/false\'s exact shape. But '
                'check-textaudit proves immutability by running a '
                'program TWICE and comparing its text, and this '
                'program\'s success path ends in SYS_HALT, which does '
                'not return: there is no second run, because there is '
                'no machine left to run it. Only the refused-operand '
                'path exits normally, and a repeat-pair over that path '
                'alone would measure the ARGC check and PUTS while '
                'proving nothing about SIO_FLUSHALL or SC_HALT -- '
                'which is a partial audit wearing a full claim. '
                'TEXT_IMMUTABLE is grow-only BY MEASUREMENT, so this '
                'stays here and says why.',
    'bye': 'genuinely spawnable but not yet MEASURED (bye slice 1, '
           '2026-09-25, docs/BYE-SLICE1.md): its own header says '
           '"Same shape as shutdown: this program owns the words '
           'and nothing else" -- every resource SC_BYE gives up and '
           'reclaims belongs to the kernel (procbye.s), not this '
           'text. UNLIKE shutdown, SC_BYE always returns (A=0 once '
           'the machine has saved/destroyed/QUIT/restored itself), '
           'so a repeat-pair CAN measure the whole success path in '
           'one process -- shutdown\'s "no second run exists" '
           'problem does not apply here. No bss of its own (a `dum` '
           'arena tripwire only); LEAVEMSG/BACKMSG/USAGEMSG are '
           'fixed read-only literals, never patched at runtime. Not '
           'yet wired into build_textaudit_image.py (check-poison\'s '
           'own 11-programs-with-no-gate list still names it). '
           'Promote once measured CLEAN.',
    'stty': 'genuinely spawnable but not yet MEASURED (stty seed, '
            '2026-09-02): it mirrors chvt/vidmode\'s proven-clean '
            'shape by construction -- escapes/state emitted only '
            'through PUTC/SC_TTYMODE, no patched strings, every '
            'mutable cell (OLDVAL/NEWVAL/SAWANY/ARGN) lives in the '
            '`dum` arena past LIBA_BSSEND -- but it has not joined a '
            'check-textaudit repeat-pair group yet, so TEXT_IMMUTABLE '
            'would be an UNVERIFIED claim (that set is grow-only by '
            'measurement, not by resemblance). Promote it once it is '
            'wired into build_textaudit_image.py and measured CLEAN.',
    'reset': 'genuinely spawnable but not yet MEASURED (terminal '
             'reinitialise, 2026-09-07): chvt\'s exact shape -- ESC c '
             'emitted through PUTC, cooked+echo through SC_TTYMODE, no '
             'patched strings, and NO bss of its own at all (a `dum` '
             'arena past LIBA_BSSEND only, for the tripwire). Immutable '
             'by construction, but it has not joined a check-textaudit '
             'repeat-pair group, so TEXT_IMMUTABLE would be an '
             'UNVERIFIED claim. Promote it once wired into '
             'build_textaudit_image.py and measured CLEAN.',
    'true': 'genuinely spawnable but not yet MEASURED (POSIX no-op, '
            '2026-09-07): 123 bytes, `lda #0 / jsr SC_EXIT` -- NO bss '
            'and no writable text of any kind (only the `dum` arena '
            'tripwire, which emits nothing). Immutable by construction; '
            'promote once a check-textaudit pair measures it.',
    'false': 'genuinely spawnable but not yet MEASURED (POSIX no-op, '
             '2026-09-07): true.s with `lda #1`. Same 123-byte '
             'no-bss/no-writable-text shape; promote once measured.',
    'vi': 'genuinely spawnable but not yet MEASURED (docs/VI-DESIGN.md '
          'birth task, 2026-09-02): its manifest mirrors `ex`\'s own '
          'shape by construction -- the SAME `dum REGEX_BSSEND` bss '
          'placement (TEXT_MUTABLE, head=False), the SAME reused '
          'edparse.s/exbuf.s/edfile.s/edfil2.s/edsubst.s/edsub2.s/ '
          'excmd.s, plus its own new viscreen.s/vimotion.s/viinsert.s/ '
          'vicmd.s/visearch.s/viop.s/vicache.s (operators: d c y x D '
          'C Y s p P J r ~, 2026-09-03; vicache.s: repaint-only line '
          'cache, W3, 2026-09-05) -- every cell those seven own '
          '(VI_TOP/VI_CURCOL/VI_MODE/etc, VI_LBUF/VI_GEOBUF/ '
          'VI_RDBUF/VI_MCOL/VI_SCOL/VI_MFLAG/VI_LASTDIR, VI_REG/ '
          'VI_REGTY/VI_REGLCNT/VI_REGLBUF/VI_OPCHAR/VI_OPISCH, '
          'VC_SLOTS/VC_NEXT) lives in the same `dum` arena, none of '
          'it emitted inside the image -- '
          'but it has not joined a check-textaudit repeat-pair group '
          'yet, so TEXT_MUTABLE would be an UNVERIFIED claim there '
          'either. Promote it once it is wired into '
          'build_textaudit_image.py and measured.',
    'tip': 'genuinely spawnable but not yet MEASURED (task #22, '
           'docs/SERIAL.md sec 3, 2026-09-11): its own gate is '
           '`make check-tip` (scripts/check_tip.py), a full '
           'person-like e2e run of the shipped binary through '
           'SC_FORK/SC_TTYMODE/SC_SIGNAL against the simulated '
           'SSC -- but that gate runs tip ONCE per boot (it forks '
           'and blocks on the console AND the line until `~.`, '
           'so it is not the plain "spawn twice back to back" '
           'shape check-textaudit\'s PAIRX/group harness wants, '
           'the same reason it is in POISON_DEBT rather than '
           'claimed poisoned). Every cell it owns (LINEFD, SAVEMD, '
           'CHPID, ATLOL, ESCPEND, PREVCR, CWI, PIDX, BSCRATCH, '
           'RBUF, WBUF, the four MLI parmlists) lives in the `dum` '
           'arena past LIBA_BSSEND, same idiom as kill/touch/more. '
           'Promote once wired into build_textaudit_image.py and '
           'measured CLEAN.',
    'proshim': 'the ProDOS-8 .SYSTEM host verb (TASKS.md #19, '
               '2026-09-07). It never overwrites its own $0800 image: '
               'the tenant is READ high (to $4000) and copied down to '
               '$2000 -- ABOVE proshim\'s code -- as the last act, so '
               'warm reuse re-runs it from LOAD_BASE correctly (no '
               'moving head, no self-modified text). Every cell it owns '
               '(PATHBUF, the four MLI parmlists, CLKBUF, CPLEN) is in '
               'the `dum` arena past LIBA_BSSEND and write-before-read; '
               'the copy-down uses ZP pointers, not bss. TEXT_IMMUTABLE '
               'by construction, but UNAUDITED because it has not joined '
               'a check-textaudit repeat-pair group -- check-proshim '
               'runs it twice and proves the tenant re-runs, which is '
               'the warm-reuse property. Promote once wired into '
               'build_textaudit_image.py.',
    'proshimpg': 'not a spawnable binary -- proshim embeds it via '
                 '`putbin` (build/proshimpg.bin) as the $BF00 shim '
                 'page + fake global page, copied into the tenant bank '
                 'at each invocation. Its emitted `ds` bytes ARE the '
                 'page layout (field offsets, BITMAP, the NEWLINE '
                 'table); proshim re-copies the whole page every run. '
                 'Audited with its parent (proshim).',
    'proshimcr': 'not a spawnable binary -- proshim embeds it via '
                 '`putbin` (build/proshimcr.bin) as the $E000 MLI '
                 'adapter core. It self-modifies BY DESIGN (PS_RDR/ '
                 'PS_RDP/PS_WRP absolute operands patched per call) '
                 'and its scratch is a `dum` arena at $E200, none '
                 'emitted. Audited with its parent (proshim).',
    'asrom': 'not a spawnable binary -- src/bin/as.s `put`s it for the '
             'P6 ROM stubs, and it is assembled on its own only to '
             'produce build/as-stubs.bin. It self-modifies BY DESIGN '
             '(SENDMSG_IMPL runs `lda $FFFF,y` with a patched base, '
             'docs/STICKY.md sec 9 blocker 3) and its bytes are part '
             'of `as`\'s image, which is already TEXT_MUTABLE.',
    'chtypnum': 'not a spawnable binary -- chtyp\'s operand parsers '
                '(PARSETYPE/MATCHMNEM/PARSENUM/MUL10), `put` into '
                'src/bin/chtyp.s. Split 2026-09-21 for the vendored '
                '`as`\'s 16,128-byte source window. Its bytes are '
                'audited as part of `chtyp`.',
    'mntcom': 'not a spawnable binary -- what mount and umount '
              'share (the /dev/sNdM parser, one-unit ON_LINE, the '
              'SYS_VROOT gate, the error line), `put` into '
              'src/bin/mount.s and umount.s (docs/VROOT.md). Its '
              'bytes are audited as part of each.',
    'mntdens': 'not a spawnable binary -- mount\'s densify half '
               '(blocks_used against the tree size, every all-zero '
               'block rewritten), `put` into src/bin/mount.s '
               '(docs/LOOP-S2.md S3). Its bytes are audited as '
               'part of `mount`.',
    'xargssub': 'not a spawnable binary -- xargs\'s -I replstr '
                'substitution, `put` into src/bin/xargs.s. Split out '
                'of xargstok.s 2026-09-21, the SECOND split of this '
                'unit that day for the vendored `as`\'s 16,128-byte '
                'source window. Its bytes are audited as part of '
                '`xargs`.',
    'xargsinv': 'not a spawnable binary -- xargs\'s INVOKE and '
                'TRACEPRINT, `put` into src/bin/xargs.s. Split out of '
                'xargsrun.s 2026-09-21 for the vendored `as`\'s '
                '16,128-byte source window. Its bytes are audited as '
                'part of `xargs`.',
    'timeoutsig': 'not a spawnable binary -- timeout\'s '
                  'signal-name parsing (TO_PARSESIG/TO_NAMEIS), `put` '
                  'into src/bin/timeout.s. Split out of '
                  'timeoutparse.s 2026-09-21 for the vendored `as`\'s '
                  '16,128-byte source window. Its bytes are audited '
                  'as part of `timeout`.',
    'trbody': 'not a spawnable binary -- tr\'s implementation, '
              '`put` into src/bin/tr.s. Split 2026-09-21 for the '
              'vendored `as`\'s 16,128-byte source window. Its bytes '
              'are audited as part of `tr`.',
    'tresc': 'not a spawnable binary -- tr\'s input-set pre-pass '
             '(backslash escapes and [:class:] expansion), `put` into '
             'src/bin/tr.s. Split out of trbody.s the same day and for '
             'the same window. Its bytes are audited as part of `tr`.',
    'grepbody': 'not a spawnable binary -- grep\'s whole '
                'implementation, `put` into src/bin/grep.s, which keeps '
                'only the equate puts, the org/dsk/typ triple, the liba '
                'puts and the `dum` arena. Split 2026-09-21 for real '
                'Merlin\'s source buffer (the manifest plus its largest '
                'single put had reached 42,539 of 41,215). Its bytes are '
                'audited as part of `grep`, which is TEXT_MUTABLE.',
    'expr.eval': 'not a spawnable binary -- the expression engine '
                 '`put` into src/bin/expr.s (and exercised directly by '
                 'check-expr). Its bytes are audited as part of '
                 '`expr`.',
    'uudecdec': 'not a spawnable binary -- the character-level decode '
                'primitives (DECODE6/B64DEC/RECON4/PREFIXCMP/'
                'PARSEHDR), `put` into src/bin/uudecode.s (split for '
                'the as-window budget, 2026-09-14). Its bytes are '
                'audited as part of `uudecode`.',
    'uudecln': 'not a spawnable binary -- the two per-line decode '
               'drivers and the normalized line reader (DECLINEU/'
               'DECLINEB/GETLINE/GETBYTE/REFILL), `put` into src/bin/'
               'uudecode.s (split for the as-window budget, '
               '2026-09-14). Its bytes are audited as part of '
               '`uudecode`.',
    'uuencln': 'not a spawnable binary -- the base64 line driver '
               '(ENCLINEB) and the buffered chunk reader '
               '(READCHNK/GETBYTE/REFILL), `put` into src/bin/'
               'uuencode.s (split for the as-window budget, '
               '2026-09-14). Its bytes are audited as part of '
               '`uuencode`.',
    'morefile': 'not a spawnable binary -- more\'s per-file driver and '
                'copy path, `put` into src/bin/more.s. Its bytes are '
                'audited as part of `more`.',
    'morecmd': 'not a spawnable binary -- more\'s keyboard and '
               'commands, `put` into src/bin/more.s (the POSIX pager, '
               '2026-09-12). Its bytes are audited as part of `more`.',
    'moreio': 'not a spawnable binary -- more\'s line table, scan and '
              'spill, `put` into src/bin/more.s. Its bytes are audited '
              'as part of `more`.',
    'moreshow': 'not a spawnable binary -- more\'s drawing and prompt, '
                '`put` into src/bin/more.s. Its bytes are audited as '
                'part of `more`.',
    'sedexec': 'not a spawnable binary -- sed\'s compiler/execution '
               'engine, `put` into src/bin/sed.s (split for the '
               'check-dialect source-buffer budget). Its bytes are '
               'audited as part of `sed`.',
    'mldload': 'not a spawnable binary -- mld\'s streaming module '
               'loader (LD_JRLOAD and helpers), `put` into '
               'src/bin/mld.s (split for the check-dialect '
               'source-buffer budget). Its bytes are audited as '
               'part of `mld`.',
    # mld -- the Merlin bridge, which was `ld` until the native
    # linker took the name. Kept buildable and byte-gated (check-ld
    # with LD_UNDER_TEST=mld) but no longer in a textaudit group:
    # group c audits the linker anyone actually runs.
    'mld': 'the superseded Merlin-LINKER.S bridge, kept for '
           'comparison and gated for byte-identity via '
           'LD_UNDER_TEST=mld; group c audits the native `ld` '
           'that replaced it (docs/LD-NATIVE.md)',
    'asboot': 'not a spawnable binary -- as\'s BLOBSIG capture and '
              'startup blob copy-out, `put` into src/bin/as.s '
              '(split for as\'s own source window, S9 stage C -- '
              'what lets maux assemble its own assembler). Its '
              'bytes are audited as part of `as`.',
    'asxform': 'not a spawnable binary -- as\'s RDXFORM source '
               'reader, `put` into src/bin/as.s (stage-C window '
               'split). Its bytes are audited as part of `as`.',
    'asdiag': 'not a spawnable binary -- as\'s diagnostic printing '
              '(DIAG2 and friends), `put` into src/bin/as.s '
              '(stage-C window split). Its bytes are audited as '
              'part of `as`.',
    'ldpass': 'not a spawnable binary -- ld\'s first pass and '
               'symbol table, `put` into src/bin/ld.s (split for '
               'as\'s source window, which is what lets maux rebuild '
               'its own linker). Its bytes are audited as part of '
               '`ld`.',
    'ldout': 'not a spawnable binary -- ld\'s output writer, hex '
             'parsing and diagnostics, `put` into src/bin/ld.s '
             '(split for check-dialect\'s window). Its bytes are '
             'audited as part of `ld`.',
    'ldscan': 'not a spawnable binary -- ld\'s library directory '
              'scan: path composition, the member list and the '
              'selective inclusion test, `put` into src/bin/ld.s. '
              'Its bytes are audited as part of `ld`.',
    'ldargf': 'not a spawnable binary -- ld\'s `@FILE` argument '
              'file reader (KFIX3 item 0), `put` into src/bin/ld.s. '
              'Its bytes are audited as part of `ld`.',
    'ldsym': 'not a spawnable binary -- ld\'s dictionary walk, '
              'pass 1 and symbol pool, `put` into src/bin/ld.s '
              '(split for check-dialect\'s flat window). Its '
              'bytes are audited as part of `ld`.',
    'ldlib': 'not a spawnable binary -- ld\'s library search: -L, '
              '-l, the undefined-symbol pool and the member scan, '
              '`put` into src/bin/ld.s. Its bytes are audited as '
              'part of `ld`.',
    'ldpass2': 'not a spawnable binary -- ld\'s fixup resolution '
                '(BLDEXTS/RESOLVE/STORFIX), `put` into src/bin/ld.s '
                'for the same reason. Its bytes are audited as part '
                'of `ld`.',
    'ldstream': 'not a spawnable binary -- ld\'s STREAMING second '
                'pass (the code chunk loop and the fixup cursor), '
                '`put` into src/bin/ld.s. Its bytes are audited as '
                'part of `ld`.',
    'ldzout': 'not a spawnable binary -- ld\'s output side (the -z '
              'pending-zero writer, the output open/finish/abort), '
              '`put` into src/bin/ld.s (split from ldstream.s for '
              'as\'s source window). Its bytes are audited as part '
              'of `ld`.',
    'makeread': 'not a spawnable binary -- make\'s makefile reader '
                'and rule parser, `put` into src/bin/make.s (split '
                'for the check-dialect as-window budget). Its bytes '
                'are audited as part of `make`.',
    'makeargs': 'not a spawnable binary -- make\'s command-line '
                'parsing (the options, the NAME=value macros and the '
                'targets), `put` into src/bin/make.s. Its bytes are '
                'audited as part of `make`.',
    'makehdr': 'not a spawnable binary -- make\'s rule-header parser '
               '(several targets, the raw dependency text, the `;` '
               'inline command), `put` into src/bin/make.s. Its bytes '
               'are audited as part of `make`.',
    'makeprt': 'not a spawnable binary -- make\'s -p printer, `put` '
               'into src/bin/make.s. Its bytes are audited as part of '
               '`make`.',
    'makespn': 'not a spawnable binary -- make\'s recipe runner (the '
               'command prefixes, -t\'s touch, and the argv split '
               'that spawns a command), `put` into src/bin/make.s. '
               'Its bytes are audited as part of `make`.',
    'makeexp': 'not a spawnable binary -- make\'s macro EXPANDER and '
               'the tokenizer that splits what it wrote, `put` into '
               'src/bin/make.s. Its bytes are audited as part of '
               '`make`.',
    'makeinf2': 'not a spawnable binary -- make\'s inference: '
                'choosing a suffix rule and carrying it out, `put` '
                'into src/bin/make.s. Its bytes are audited as part '
                'of `make`.',
    'makedec': 'not a spawnable binary -- make\'s out-of-date '
               'decision (the mod-time compare, the stat, the '
               'internal-macro binding), `put` into src/bin/make.s. '
               'Its bytes are audited as part of `make`.',
    'makemac': 'not a spawnable binary -- make\'s macro table and '
               'the ONE expander every other part of make calls, '
               '`put` into src/bin/make.s. Its bytes are audited as '
               'part of `make`.',
    'makeinf': 'not a spawnable binary -- make\'s inference rules, '
               'special targets and internal macros ($@ $< $* $?), '
               '`put` into src/bin/make.s. Its bytes are audited as '
               'part of `make`.',
    'makerun': 'not a spawnable binary -- make\'s dependency walk, '
               'mod-time comparison and recipe runner, `put` into '
               'src/bin/make.s. Its bytes are audited as part of '
               '`make`.',
    'uniqcmp': 'not a spawnable binary -- uniq\'s comparison and '
               'run-output layer (SAVEPREV/SKIPCMP/SK_ADV/ISBLANK/'
               'PARSENUM8/BUMPRUN/ISDUP/OUTRUN/PRCNT), uniq\'s SECOND '
               '`put` file beside uniqio.s (split for the '
               'check-dialect as-window budget -- uniq.s alone '
               'measured 18,192 B stripped once -f/-s landed, 2,066 '
               'over the 16,128-byte window). Its bytes are audited '
               'as part of `uniq`.',
    'calmon': 'not a spawnable binary -- cal\'s renderers (PRINTMON/'
              'CALPR2/BUILDTTL) and the year form\'s quarter painter '
              '(SLOTBASE/PRINTQTR/PRINT22/PRINTQSEP), cal\'s SECOND '
              '`put` file beside calcalc.s (split for the '
              'check-dialect as-window budget -- cal.s alone measured '
              '19,528 B stripped once the three-column year form '
              'landed, 3,402 over the 16,128-byte window). Its bytes '
              'are audited as part of `cal`.',
    'odrow': 'not a spawnable binary -- od\'s dump engine (PRHEX4 offset '
             'column), its '
             'buffered byte source (GETBYTE/REFILL) and its -j/-N '
             'operand parser (OD_PARSENUM/OD_MUL10ADD), `put` into '
             'src/bin/od.s (split for the check-dialect as-window '
             'budget -- od.s alone measured 17,299 B stripped once '
             '-j/-N landed, 1,173 over the 16,128-byte window). Its '
             'bytes are audited as part of `od`.',
    'odtype': 'not a spawnable binary -- od\'s type engine: the -t '
              'type_string parser, column-width setup, the one row '
              'printer and the field generators, `put` into '
              'src/bin/od.s beside odrow.s. Its bytes are audited '
              'as part of `od`.',
    'tailin': 'not a spawnable binary -- tail\'s input and '
              'accumulation layer (MUL10ADD/BUMPCNT/RDLINE/GETBYTE/'
              'REFILL), `put` into src/bin/tail.s (split for the '
              'check-dialect as-window budget -- tail.s alone measured '
              '17,298 B stripped once -c landed, 1,172 over the '
              '16,128-byte window). Its bytes are audited as part of '
              '`tail`.',
    'uniqio': 'not a spawnable binary -- uniq\'s buffered input '
              'layer, `put` into src/bin/uniq.s (split for the '
              'check-dialect as-window budget, S9-PLAN sec 5 W4). '
              'Its bytes are audited as part of `uniq`.',
    'edparse': 'not a spawnable binary -- ed\'s command input, address '
               'parsing and searches, `put` into src/bin/ed.s (split '
               'for the check-dialect source-buffer budget). Its bytes '
               'are audited as part of `ed`.',
    'nulib2add': 'not a spawnable binary -- CREATING an archive: the '
                 'master header, one record per file operand, and the '
                 'patch-up at the end. `put` into src/bin/nulib2.s. '
                 'Audited as part of `nulib2`.',
    'nulib2af': 'not a spawnable binary -- what -a needs from each '
                'input FILE: its ProDOS metadata, the two passes over '
                'its bytes, the date conversion and the leaf name. '
                '`put` into src/bin/nulib2.s. Audited as part of '
                '`nulib2`.',
    'nulib2arc': 'not a spawnable binary -- the ARCHIVE: master header, '
                 'the Binary II wrapper a .BXY hides it behind, the '
                 'record walk, one record\'s header and the thread array, '
                 'with both header CRCs. `put` into src/bin/nulib2.s. '
                 'Audited as part of `nulib2`.',
    'nulib2lst': 'not a spawnable binary -- LISTING: what -t and -v '
                 'print, and the type, size and 32-bit decimal '
                 'formatters they use. `put` into src/bin/nulib2.s. '
                 'Audited as part of `nulib2`.',
    'nulib2ext': 'not a spawnable binary -- EXTRACTION: one record into '
                 'bytes under -x, -p or -i, sharing a single path, plus '
                 'the ProDOS type and aux stamp. `put` into '
                 'src/bin/nulib2.s. Audited as part of `nulib2`.',
    'nulib2lzw': 'not a spawnable binary -- the COMPRESSED STREAM: '
                 'ShrinkIt\'s 4 KB chunking and the run-length layer that '
                 'rides with it. `put` into src/bin/nulib2.s. Audited as '
                 'part of `nulib2`.',
    'nulib2lzc': 'not a spawnable binary -- the LZW CODEC: the code '
                 'loop, the string table, the decode stack and the bit '
                 'reader. `put` into src/bin/nulib2.s. Audited as part '
                 'of `nulib2`.',
    'nulib2lze': 'not a spawnable binary -- the LZW ENCODER: the '
                 'match loop, the hash index over the shared string '
                 'table, and the bit writer. `put` into '
                 'src/bin/nulib2.s. Audited as part of `nulib2`.',
    'nulib2rle': 'not a spawnable binary -- the RLE ENCODER: the run '
                 'coder -a compresses with, the chunk pricer that '
                 'decides stored-or-coded, and the writer. `put` into '
                 'src/bin/nulib2.s. Audited as part of `nulib2`.',
    'nulib2msg': 'not a spawnable binary -- the option string, the '
                 'diagnostics and the two NuFX signature constants. '
                 '`put` into src/bin/nulib2.s. Audited as part of '
                 '`nulib2`.',
    'nulib2io': 'not a spawnable binary -- PRIMITIVES: a read that '
                'refuses a short count, a seek, and a CRC-16 that never '
                'chooses its own seed. `put` into src/bin/nulib2.s. '
                'Audited as part of `nulib2`.',
    'cutlist': 'not a spawnable binary -- cut\'s LIST-syntax parser '
               'and range test (LISTPARSE/ACCUM/CLAMPN/CKORDER/'
               'APPENDRNG/SELECTED), `put` into src/bin/cut.s (split '
               'for the check-dialect as-window budget, S9-PLAN sec '
               '5). Its bytes are audited as part of `cut`.',
    'pastepar': 'not a spawnable binary -- paste\'s PARALLEL/merge '
               'mode (PARDISP/OPENALL/CLOSEALL/CBUFBASE/LBUFBASE/'
               'GETBYTEM/REFILLM/GETLINEM/EMITFIELDM/MERGERUN), '
               '`put` into src/bin/paste.s (split for the check-'
               'dialect as-window budget -- paste.s alone measured '
               '18,690 B stripped, over the 16,128-byte window). Its '
               'bytes are audited as part of `paste`.',
    'nlopt': 'not a spawnable binary -- nl\'s option-value parsers '
             '(SETPTRO/PARSETY/PARSED/PARSEI/PARSEN/PARSES/PARSEV/'
             'ACCUM16/PARSEW2), `put` into src/bin/nl.s (one of '
             'TWO put files, split for the check-dialect as-'
             'window budget -- nl.s alone measured 24,534 B '
             'stripped, over the 16,128-byte window). Its bytes '
             'are audited as part of `nl`.',
    'nlfmt': 'not a spawnable binary -- nl\'s per-line engine '
             '(BUILDMK/NLRUN/RESETNUM/PRINTONE/PRINTNUM/'
             'PRINTBLANK/ADVANCE/EMITLINE/CHECKHDR/CHECKBODY/'
             'CHECKFOOT/READLINE), `put` into src/bin/nl.s (the '
             'second of the two put files -- see nlopt\'s own '
             'entry above for why two, not one). Its bytes are '
             'audited as part of `nl`.',
    'uxrun': 'not a spawnable binary -- unexpand\'s per-line engine '
             '(UXFD/PENDPUSH/PENDLIT/FLUSHRUN/ISSTOP/NEXTSTOP/'
             'PERSTOP), `put` into src/bin/unexpand.s (split for '
             'the check-dialect as-window budget -- unexpand.s '
             'alone measured 16,572 B stripped, over the '
             '16,128-byte window). Its bytes are audited as part '
             'of `unexpand`.',
    'calcalc': 'not a spawnable binary -- cal\'s operand parsing '
               '(CKYEAR/PARSENUM/ACCUM10) and Sakamoto day-of-week/'
               'leap-year test (CALCDOW/DIV16), `put` into '
               'src/bin/cal.s (split for the check-dialect '
               'as-window budget -- cal.s alone measured 20,869 B '
               'stripped, over the 16,128-byte window). Its bytes '
               'are audited as part of `cal`.',
    'strfmt': 'not a spawnable binary -- strings\'s -t offset '
              'formatters (PRHEXV/PROCTV), `put` into '
              'src/bin/strings.s (split for the check-dialect '
              'as-window budget -- strings.s alone measured '
              '16,739 B stripped, 611 B over the 16,128-byte '
              'window). Its bytes are audited as part of '
              '`strings`.',
    'tsortp': 'not a spawnable binary -- tsort\'s token-parsing '
              'engine (PARSE/SKIPWS/READTOK/LOOKUPADD/NODEPTR/'
              'SLOTCMP/SLOTSET/ADDEDGE), `put` into '
              'src/bin/tsort.s (split for the check-dialect '
              'as-window budget -- tsort.s alone measured '
              '16,435 B stripped, 309 B over the 16,128-byte '
              'window). Its bytes are audited as part of '
              '`tsort`.',
    'prparse': 'not a spawnable binary -- pr\'s +page/option '
               'grammar (OPTPARSE/GETVALWD/PARSEDEC/COPYHDR), '
               '`put` into src/bin/pr.s (split, with prfmt.s, '
               'for the check-dialect as-window budget -- pr.s '
               'alone measured 26,612 B stripped, far over the '
               '16,128-byte window). Its bytes are audited as '
               'part of `pr`.',
    'prfmt': 'not a spawnable binary -- pr\'s page-rendering '
             'engine (VISIBLE/PUTOFS/PRINTPAD/PR2DIG0/PR2DIGSP/'
             'PRDATE/PRINTHDR/EMITLBUF/PRBODY/READLN/PRFILE/'
             'GETBYTE/REFILL), `put` into src/bin/pr.s (split, '
             'with prparse.s, for the same as-window budget). '
             'Its bytes are audited as part of `pr`.',
    'prout': 'not a spawnable binary -- pr\'s output emitter '
             '(EMCH/EMFLUSH/EMPADTO/EMNUM: column tracking and -i '
             'tab contraction), `put` into src/bin/pr.s (a '
             'further split for the as-window budget). Its bytes '
             'are audited as part of `pr`.',
    'prcol': 'not a spawnable binary -- pr\'s multi-column engine '
             '(COLINIT/FILLPAGE/PRFILEC/PRROW), `put` into '
             'src/bin/pr.s. Its bytes are audited as part of `pr`.',
    'prmrg': 'not a spawnable binary -- pr -m (PRMERGE/READK/'
             'STOREM), `put` into src/bin/pr.s. Its bytes are '
             'audited as part of `pr`.',
    'splitpc': 'not a spawnable binary -- split\'s PARSEDEC/ACCUM10/'
               'SHL10/SUFINC/OPENPIECE/CLOSEPIECE plus GETBYTE/'
               'REFILL and its usage/error exits, `put` into '
               'src/bin/split.s (split for the check-dialect '
               'as-window budget -- split.s alone measured 18,865 B '
               'stripped, over the 16,128-byte window). Its bytes '
               'are audited as part of `split`.',
    'csplitrn': 'not a spawnable binary -- csplit\'s NUMBER/regex/'
                'repeat argument handlers, piece open/close/write, '
                'source-line reader, error cleanup and decimal '
                'parsing, `put` into src/bin/csplit.s (split for '
                'real Merlin\'s 41,215-byte source buffer -- '
                'csplit.s links regex.s/regex2.s, MANDATORY, and '
                'without this split measured 43,613 B stripped '
                'resident+largest-put, over that buffer). Its '
                'bytes are audited as part of `csplit`.',
    'joinio': 'not a spawnable binary -- join\'s per-side line/'
              'field readers, `put` into src/bin/join.s (split for '
              'the check-dialect as-window budget -- join.s alone '
              'measured 29,904 B stripped, over the 16,128-byte '
              'window). Its bytes are audited as part of `join`.',
    'joinout': 'not a spawnable binary -- join\'s record-'
               'composition/printing routines, `put` into '
               'src/bin/join.s (split for the same as-window '
               'budget as joinio.s). Its bytes are audited as '
               'part of `join`.',
    'joinopt': 'not a spawnable binary -- join\'s numeric-argument '
               'and `-o` list parsers, `put` into src/bin/join.s '
               '(split for the same as-window budget as joinio.s). '
               'Its bytes are audited as part of `join`.',
    'patchio': 'not a spawnable binary -- patch\'s option parsing, '
               'patch-stream line reader (with the one-line pushback '
               'the three parsers need) and hunk arena, `put` into '
               'src/bin/patch.s (one of five body modules split '
               'against check-dialect\'s 16,128-byte as-window, which '
               'new code must fit from birth). Its bytes are audited '
               'as part of `patch`.',
    'patchtgt': 'not a spawnable binary -- patch\'s target-file read '
                '(whole file into the arena as a line table), '
                'line-by-number lookup and output CREAT, `put` into '
                'src/bin/patch.s. Its bytes are audited as part of '
                '`patch`.',
    'patchwr': 'not a spawnable binary -- patch\'s writers (the '
               'shared line emitter, the -b backup, the .rej file, '
               'the derived-name builder) and its loud exits, `put` '
               'into src/bin/patch.s. Its bytes are audited as part '
               'of `patch`.',
    'patchhnk': 'not a spawnable binary -- patch\'s format detection, '
                'header pathnames, -p stripping and the shared number/'
                'scan helpers, `put` into src/bin/patch.s. Its bytes '
                'are audited as part of `patch`.',
    'patchprs': 'not a spawnable binary -- patch\'s three hunk '
                'parsers (unified, context, normal) and the wrapper '
                'that applies -R and the empty-range rule, `put` into '
                'src/bin/patch.s. Its bytes are audited as part of '
                '`patch`.',
    'patchapp': 'not a spawnable binary -- patch\'s apply half (the '
                'position guess, the offset search, the exact match '
                'and the reject path), `put` into src/bin/patch.s. '
                'Its bytes are audited as part of `patch`.',
    'xargstok': 'not a spawnable binary -- xargs\'s stdin tokenizer, '
                '-I line reader/replstr substitution and PARSEDEC, '
                '`put` into src/bin/xargs.s (split for the same '
                'as-window budget as cutlist.s). Its bytes are '
                'audited as part of `xargs`.',
    'xargsrun': 'not a spawnable binary -- xargs\'s batch/-I '
                'invocation engine (CALCBUDGET, TOOLONG, RUN_NMODE/'
                'BUILD_BATCH/BB_NEED/BUILD_ARGV_N, RUN_IMODE, INVOKE, '
                'TRACEPRINT), `put` into src/bin/xargs.s (2026-09-14, '
                'a second split off the same file -- xargstok.s alone '
                'was not enough as-window headroom). Its bytes are '
                'audited as part of `xargs`.',
    'printffmt': 'not a spawnable binary -- printf\'s %-directive '
                 'parser (flags/width/precision scan, dispatch) and '
                 'HASCONV prescan, `put` into src/bin/printf.s (one '
                 'of a THREE-way split for the as-window budget -- '
                 'see its own header for why two pieces were not '
                 'enough). Its bytes are audited as part of `printf`.',
    'printfnum': 'not a spawnable binary -- printf\'s numeric-'
                 'argument engine (PFNUM, PF_ACC10, the octal/'
                 'decimal/hex digit builders, PF_EMITNUM), `put` '
                 'into src/bin/printf.s (same three-way split as '
                 'printffmt.s). Its bytes are audited as part of '
                 '`printf`.',
    'printfcnv': 'not a spawnable binary -- printf\'s per-'
                 'conversion handlers (PF_DO_D/U/O/X/XU/C/S/PCT/B) '
                 'and %b\'s own escape engine, `put` into '
                 'src/bin/printf.s (same three-way split as '
                 'printffmt.s). Its bytes are audited as part of '
                 '`printf`.',
    'edsub2': 'not a spawnable binary -- ed\'s g/v command half, split from edsubst.s for the as source window (S9 tier 2). Audited with its parent.',
    'shexp2': 'not a spawnable binary -- sh\'s variable-emit half, split from shexpand.s for the as source window (S9 tier 2). Audited with its parent.',
    'shsub2': 'not a spawnable binary -- sh\'s group-check half, split from shsubst.s for the as source window (S9 tier 2). Audited with its parent.',
    'shvar2': 'not a spawnable binary -- sh\'s builtin-read half, split from shvar.s for the as source window (S9 tier 2). Audited with its parent.',
    'shblt2': 'not a spawnable binary -- sh\'s heredoc-tail half, split from shbltn.s for the as source window (S9 tier 2). Audited with its parent.',
    'shrsv2': 'not a spawnable binary -- sh\'s control-handoff half, split from shresv.s for the as source window (S9 tier 2). Audited with its parent.',
    'shpth2': 'not a spawnable binary -- sh\'s arg/state half, split from shpath.s for the as source window (S9 tier 2). Audited with its parent.',
    'shtrap': 'not a spawnable binary -- sh\'s trap builtin + signal pump + exit hook (docs/SIGNALS.md sec 3a, 2026-09-02). Audited with its parent.',
    'shjob': 'not a spawnable binary -- sh\'s job table + jobs/fg/bg + FG_WAIT + the prompt drain (docs/JOB-CONTROL.md Increment C, 2026-09-08). Audited with its parent.',
    # -- sh's SECOND CODE SEGMENT (docs/SH-SUBSET.md ruling 7.6,
    # -- 2026-09-16). These four are `put` by src/bin/sh.s like every
    # -- other body module, so `sh`'s own audit already covers their
    # -- bytes -- but note WHERE those bytes end up: three of them
    # -- assemble under `org PRC_LC_COMMON` and RUN from $E000 in the
    # -- process language card, while the copy of them that lives in
    # -- sh.bin sits above the low image and is read exactly once, by
    # -- SEG_INIT. Text-immutability matters MORE for them, not less:
    # -- lazy free retains the bank, and on a warm respawn the $E000
    # -- copy is not re-installed from disk by anyone.
    'shsegi': 'not a spawnable binary -- SEG_INIT, the low-resident routine that installs sh\'s second code segment into the process language card at $E000 before START does anything else (docs/SH-SUBSET.md ruling 7.6). Audited with its parent.',
    'shsgtrp': 'not a spawnable binary -- sh\'s `trap` builtin, moved into the $E000 code segment 2026-09-16 (docs/SH-SUBSET.md ruling 7.6); its strings stayed in shtrap.s. Audited with its parent.',
    'shsggop': 'not a spawnable binary -- sh\'s `getopts` builtin, moved into the $E000 code segment 2026-09-16 (docs/SH-SUBSET.md ruling 7.6); its strings stayed in shvar2.s. Audited with its parent.',
    'shsgjob': 'not a spawnable binary -- sh\'s wait/kill/jobs/fg/bg builtins and job-report printers, moved into the $E000 code segment 2026-09-16 (docs/SH-SUBSET.md ruling 7.6); their strings stayed in shjob.s. Audited with its parent.',
    'shsgblt': 'not a spawnable binary -- sh\'s `command`/`type`/`eval`/`exec`/`readonly`/`times` builtins, written straight into the $E000 code segment 2026-09-16 (docs/SH-FEATURES.md sec 29); every string a WRITE ever sees stayed in shblt3.s, but the NAME strings and BLTTAB did not have to -- STRCMPI reads them with the process\'s own CPU, never through the kernel\'s copyin. Audited with its parent.',
    'shalias': 'not a spawnable binary -- the LOW-resident message strings for sh\'s alias/unalias/hash/fc builtins and the alias expander (docs/SH-ALIAS-NOTES.md). Audited with its parent.',
    'shsgali': 'not a spawnable binary -- sh\'s alias/unalias/hash/fc builtins and the alias expander, written into the $E000 code segment; its table is CPU-only LC data above the segment (docs/SH-ALIAS-NOTES.md). Audited with its parent.',
    'shsgbl2': 'not a spawnable binary -- the second half of shsgblt.s (readonly, times, BLTTAB, the #! reader), split at a global label for check-dialect\'s source-buffer budget (KFIX3); `put` right after it into the same $E000 segment. Audited with its parent.',
    'shsgsig': 'not a spawnable binary -- the signal-name table and its two printers (SIG_PUTNAME/SIG_FGMSG/SIG_JOBSTATE, KFIX3 item 3), `put` into sh.s\'s $D000 segment. Names are read by the CPU and written byte by byte, never handed to a syscall. Audited with its parent.',
    'shedit': 'not a spawnable binary -- sh\'s line editor for the interactive console prompt, `put` into sh.s\'s $D000 segment (docs/TAB-A2.md). Pure code: its cells are the arena\'s, its history is CPU-only LC data initialised by ED_INIT at START. Audited with its parent.',
    'shtabc': 'not a spawnable binary -- sh\'s TAB completion, `put` into sh.s\'s $E000 segment (docs/TAB-A3.md). Pure code: its cells are the arena\'s. Audited with its parent.',
    'shsgcld': 'not a spawnable binary -- sh\'s cold bundle (PFX_REC, PFX_ISSPEC and its name table, `set`), moved out of the low image into the $D000 segment (SH-ROOM2 step 2b). Pure code: its cells are the arena\'s; the strings a syscall sees stayed low. Audited with its parent.',
    'shedit2': 'not a spawnable binary -- the history half of sh\'s line editor, the tail of shedit.s split off at a global label (SH-SEQ C) for check-dialect\'s source-buffer budget. Audited with its parent.',
    'shlex2': 'not a spawnable binary -- READLINE, the tail of shlex.s split off at a global label (SH-PREFIX) for check-dialect\'s source-buffer budget. Audited with its parent.',
    'shsgrw': 'not a spawnable binary -- sh\'s busy-open retry (OPEN-RW-1), `put` into sh.s\'s $E000 segment. Pure code: its cells are the arena\'s. Audited with its parent.',
    'shsgmlq': 'not a spawnable binary -- the join and the over-long refusal of sh\'s logical-line reader (SH-MLQUOTE), `put` into sh.s\'s $E000 segment. Pure code: its cells are the arena\'s. Audited with its parent.',
    'shrlog': 'not a spawnable binary -- sh\'s logical-line reader (a quote or a trailing backslash continues the line, SH-MLQUOTE), `put` into sh.s\'s low image right after shlex2.s. Pure code: its cells are the arena\'s. Audited with its parent.',
    'shpfx': 'not a spawnable binary -- sh\'s prefix assignments (`NAME=value cmd`), `put` into sh.s\'s low image (docs/SH-PREFIX.md). Pure code: its cells are the arena\'s. Audited with its parent.',
    'shtabc2': 'not a spawnable binary -- the TAB lister, `put` into sh.s\'s low image (docs/TAB-A3.md). Pure code: its cells are the arena\'s. Audited with its parent.',
    'shsgglb': 'not a spawnable binary -- glob\'s result sort (GLOB_SORT/GLOB_CMP), moved out of shpth2.s into the $E000 code segment 2026-10-17 (docs/GLOB-VROOT-NOTES.md). Pure code over sh\'s own arena cells. Audited with its parent.',
    'shblt3': 'not a spawnable binary -- the LOW-resident message strings for shsgblt.s\'s six builtins, kept below $D000 because COPYIN_ENTRY/COPYOUT_ENTRY refuse a process address at or above it (docs/SH-SUBSET.md ruling 7.6). Audited with its parent.',
    'edfil2': 'not a spawnable binary -- ed\'s file-read half, split from edfile.s for the as source window (S9 tier 2). Audited with its parent.',
    'ddparse': 'not a spawnable binary -- dd\'s operand parser (key=value dispatch, PARSENUM, if=/of= opens, skip=/seek=), split from dd.s for the as source window. Audited with its parent (dd).',
    'ddcopy': 'not a spawnable binary -- dd\'s copy engine (CPYLOOP, MULOFF, REPORT, the fatal-error helpers, CRPARM/DPARM), split from dd.s for the as source window. Audited with its parent (dd).',
    'plasmavm': 'not a spawnable binary -- the PLASMA VM seed: OPTBL, DINTRP/IINTRP, the ZP inner-loop template, arithmetic/logic/constant handlers (plvm02.s port), split from plasma.s for the as source window. Audited with its parent (plasma).',
    'plasmals': 'not a spawnable binary -- the PLASMA VM seed: load/store handlers LB..DAW, split from plasmavm.s for the as source window. Audited with its parent (plasma).',
    'plasmaop': 'not a spawnable binary -- the PLASMA VM seed: compares, branches, CALL/ICAL/ENTER/LEAVE/RET/NATV/JUMPs. Audited with its parent (plasma).',
    'plasma': 'the native PLASMA VM seed (TASKS.md #20, 2026-09-08). A '
              'SPAWNABLE util, but placed here (proshim\'s precedent) '
              'because it is LIBA-FREE (raw JSR $FF00): it has no '
              'LIBA_ZPG/LIBA_BSSEND arena, so the textaudit poison group '
              'cannot derive and poison it. It is text-immutable by '
              'construction anyway -- INITPARMS stores all six parmlists '
              'into its dum arena as START\'s first act, the def thunk is '
              'built in bss, and the ZP inner loop is copied fresh from '
              'read-only text each run -- and check-plasma exercises it. '
              'Also in check_poison.POISON_DEBT for the same liba-free '
              'reason. Promote to a real audit when arena_span learns '
              'liba-free layouts (M2 spawns it twice).',
    'plasmald': 'not a spawnable binary -- the PLASMA VM seed: START (argv->MLI path, brk, OPEN/READ/CLOSE, magic check, VM env init, the def thunk), PRINTERR, DOEXIT, messages, parmlists. Audited with its parent (plasma).',
    'bpatchp': 'not a spawnable binary -- bpatch\'s spec parser (line splitter, tokenizer, hex parsing, directive dispatch), split from bpatch.s for the as source window. Audited with its parent (bpatch).',
    'bpatchd': 'not a spawnable binary -- bpatch\'s directive appliers (set/expect/flip-lc), WRITEBACK, the error-exit routines and the keyword table, split from bpatch.s for the as source window. Audited with its parent (bpatch).',
    'difftop': 'not a spawnable binary -- diff\'s front half, extracted from its manifest for the as source window (S9 tier 2 mains). Audited with its parent.',
    'difflpb': 'not a spawnable binary -- diff\'s line-pair buffer machinery, extracted from its manifest for the as source window (S9 tier 2 mains). Audited with its parent.',
    'diffhnk': 'not a spawnable binary -- diff\'s hunk-close and output half, extracted from its manifest for the as source window (S9 tier 2 mains). Audited with its parent.',
    'diffctx': 'not a spawnable binary -- diff\'s -u/-c context output (hunk grouping, the two range printers, both body walkers) and -U/-C\'s decimal parser, `put` into src/bin/diff.s beside difftop/difflpb/diffhnk (2026-09-17). Audited with its parent.',
    'diffcout': 'not a spawnable binary -- diff\'s -c (context) output half, `put` into src/bin/diff.s beside diffctx.s (split from it 2026-09-17 for check-dialect\'s as-window budget). Audited with its parent.',
    'diffrec': 'not a spawnable binary -- diff\'s directory half (`diff -r`, the DIR operand forms, the sorted name lists), `put` into src/bin/diff.s beside diffcout.s (2026-10-08). Audited with its parent.',
    'diffdir': 'not a spawnable binary -- diff\'s listing half for `diff -r` (operand load and stat, path append, the sorted name list and its READDIR loop), split from diffrec.s at a global label, `put` into src/bin/diff.s (2026-10-08). Audited with its parent.',
    'findtop': 'not a spawnable binary -- find\'s front half, extracted from its manifest for the as source window (S9 tier 2 mains). Audited with its parent.',
    'findact': 'not a spawnable binary -- find\'s action half, extracted from its manifest for the as source window (S9 tier 2 mains). Audited with its parent.',
    'findexpr': 'not a spawnable binary -- find\'s expression tokenizer, one of three tier-2 splits alongside findtop.s/findact.s/findeval.s/findtst.s for the as source window. Audited with its parent.',
    'findeval': 'not a spawnable binary -- find\'s expression evaluator (EVAL_EXPR/TERM/FACT), split from findexpr.s for the as source window. Audited with its parent.',
    'findtst': 'not a spawnable binary -- find\'s primitive tests (-name/-newer/-mtime/-size/etc) and the flag dispatch table, split from findexpr.s for the as source window. Audited with its parent.',
    'lstop': 'not a spawnable binary -- ls\'s front half, extracted from its manifest for the as source window (S9 tier 2 mains). Audited with its parent.',
    'lsprint': 'not a spawnable binary -- ls\'s entry-printing half, extracted from its manifest for the as source window (S9 tier 2 mains). Audited with its parent.',
    'lssort': 'not a spawnable binary -- ls\'s sorting half (-t/-r, 2026-09-01), split from lstop.s for the as source window. Audited with its parent.',
    'lsrec': 'not a spawnable binary -- ls\'s -R worklist and path builder, split from lssort.s for the as source window. Audited with its parent.',
    'lscol': 'not a spawnable binary -- ls\'s column layout (-C, 2026-09-04), split from lsprint.s for the as source window. Audited with its parent.',
    'cmprpt': 'not a spawnable binary -- cmp\'s reporting half (-l, 2026-09-01), split from cmp.s for the as source window. Audited with its parent.',
    'sortcmp': 'not a spawnable binary -- sort\'s ordering half (-n/-k, 2026-09-01), split from sort.s for the librelas L3 window. Audited with its parent.',
    'sortkey': 'not a spawnable binary -- sort\'s key-bounds half, sub-split from sortcmp.s (the L3 window charges main + LARGEST put). Audited with its parent.',
    'sortnum': 'not a spawnable binary -- sort\'s numeric-compare half, same sub-split. Audited with its parent.',
    'cpdir': 'not a spawnable binary -- cp\'s resolution half (2026-09-01), split from cp.s for the librelas L3 window. Audited with its parent.',
    'cpcopyd': 'not a spawnable binary -- cp\'s recursive-copy policy, sub-split from cpdir.s. Audited with its parent.',
    'mvtop': 'not a spawnable binary -- mv\'s front half, extracted from its manifest for the as source window (S9 tier 2 mains). Audited with its parent.',
    'mvcopy': 'not a spawnable binary -- mv\'s copy-tail half, extracted from its manifest for the as source window (S9 tier 2 mains). Audited with its parent.',
    'nmtop': 'not a spawnable binary -- nm\'s front half, extracted from its manifest for the as source window (S9 tier 2 mains). Audited with its parent.',
    'nmscan': 'not a spawnable binary -- nm\'s dictionary-scan half, extracted from its manifest for the as source window (S9 tier 2 mains). Audited with its parent.',
    'exbuf': 'not a spawnable binary -- ex\'s swap-file-backed buffer '
             'accessors (ED_LTSLOT/ED_GETSLOT/ED_SETSLOT/ED_LINETEXT/'
             'ED_BUMP_ALLOC/ED_INSRT_AFTR/ED_DLT_RANGE/ED_DOMOVE/'
             'ED_TEXTENTRY/ED_QCLEANUP), forked from edbuf.s (M1, docs/'
             'EX-DESIGN.md sec 5), `put` into src/bin/ex.s. Its bytes '
             'are audited as part of `ex`.',
    'edbuf': 'not a spawnable binary -- ed\'s buffer-management half, '
             'split from edparse.s for the as source window (S9 tier '
             '2). Its bytes are audited as part of `ed`.',
    'excmd': 'not a spawnable binary -- ex\'s M2 command set (q!/wq/x, '
             'marks, ?re? backward search, u undo, e/e!, #/nu, '
             'docs/EX-DESIGN.md sec 5.5), `put` into src/bin/ex.s LAST '
             '(after edsub2.s). Its bytes are audited as part of `ex`.',
    'excmd2': 'not a spawnable binary -- the `!` command family and '
              'EX_BG_* shell-spawn helpers, split out of excmd.s '
              '2026-09-07 so ex.s/vi.s fit real Merlin\'s source '
              'buffer (check-dialect). `put` immediately after '
              'excmd.s; audited as part of `ex`/`vi`, same as excmd.s.',
    'exname': 'not a spawnable binary -- ex\'s command-NAME table and '
              'operand-class check (docs/EX-BADCMD.md): refuses an '
              'unknown word instead of running its first letter. `put` '
              'immediately after excmd2.s; audited as part of '
              '`ex`/`vi`, same as excmd.s.',
    'viscreen': 'not a spawnable binary -- vi\'s screen model '
                '(docs/VI-DESIGN.md sec 2/6: repaint, cursor '
                'placement, the status line), `put` into '
                'src/bin/vi.s. Its bytes are audited as part of `vi`.',
    'vimotion': 'not a spawnable binary -- vi\'s h/j/k/l motions '
                '(docs/VI-DESIGN.md sec 4.1), `put` into '
                'src/bin/vi.s. Its bytes are audited as part of `vi`.',
    'viinsert': 'not a spawnable binary -- vi\'s insert mode '
                '(docs/VI-DESIGN.md sec 3.3/4.1), `put` into '
                'src/bin/vi.s. Its bytes are audited as part of `vi`.',
    'vicmd': 'not a spawnable binary -- vi\'s top-level command '
             'loop, `:` bridge and ZZ/u (docs/VI-DESIGN.md sec '
             '3.1/3.2/5), `put` into src/bin/vi.s LAST. Its bytes '
             'are audited as part of `vi`.',
    'visearch': 'not a spawnable binary -- vi\'s `/`/`?`/`n`/`N` '
                'search (docs/VI-DESIGN.md sec 4.1), `put` into '
                'src/bin/vi.s after vicmd.s. Its bytes are '
                'audited as part of `vi`.',
    'viop': 'not a spawnable binary -- vi\'s operators (d/c/y+ '
            'motion, dd/cc/yy, x D C Y s p P J r ~, docs/VI-'
            'DESIGN.md sec 4.1/4.3/4.4), `put` into src/bin/vi.s '
            'after visearch.s. Its bytes are audited as part of '
            '`vi`.',
    'virep': 'not a spawnable binary -- vi\'s delete/change '
             'REDISPLAY helpers (VI_RP_LWD/CWD/VI_SAVESPAN/'
             'VI_DELCNT/VI_OP_CWCHG, docs/VI-DESIGN.md sec 2.2), '
             'split out of viop.s 2026-09-11 so that file fits '
             'real Merlin\'s source buffer (check-dialect). `put` '
             'into src/bin/vi.s after viop.s. Its bytes are '
             'audited as part of `vi`.',
    'viop2': 'not a spawnable binary -- the rest of vi\'s operators '
             '(r ~ p P J, VI_OP_PCH_AT/VI_OP_PLW), split out of '
             'viop.s 2026-10-06 for real Merlin\'s source buffer. '
             '`put` into src/bin/vi.s after viop.s. Its bytes are '
             'audited as part of `vi`.',
    'vipage': 'not a spawnable binary -- the window-sync tail of '
              'vimotion.s (VI_TOPSYNC/VI_TOPCAP/VI_PAGE), split out '
              '2026-10-06 for real Merlin\'s source buffer. `put` '
              'into src/bin/vi.s after vimotion.s. Its bytes are '
              'audited as part of `vi`.',
    'virg': 'not a spawnable binary -- vi\'s named registers "a-"z '
            '(packed LC arena, VI_RG_STORE/VI_RG_LOAD) and the '
            'multi-line charwise put (VI_OP_PML), docs/VI-GAPS-2.md. '
            '`put` into src/bin/vi.s after virep.s. Its bytes are '
            'audited as part of `vi`.',
    'vicache': 'not a spawnable binary -- vi\'s repaint-only line '
               'cache (W3, docs/VI-DESIGN.md): VI_LTEXTC, a '
               'drop-in for exbuf.s\'s ED_LINETEXT at vi\'s three '
               'repaint call sites only, keyed by the swap\'s '
               '4-byte append-only descriptor. `put` into '
               'src/bin/vi.s LAST, after viop.s. Its bytes are '
               'audited as part of `vi`.',
    'sedparse': 'not a spawnable binary -- sed\'s script compiler, split '
                'out of sedexec.s by the POSIX uplift (docs/SED.md) for '
                'the as source window. Its bytes are audited as part of '
                '`sed`.',
    'sedsel': 'not a spawnable binary -- sed\'s selection/substitution '
              'half, split from sedexec.s for the as source window '
              '(S9 tier 2). Its bytes are audited as part of `sed`.',
    'sedout': 'not a spawnable binary -- sed\'s space/output helpers '
              '(append queue, w files, l, y), split out by the POSIX '
              'uplift (docs/SED.md) for the as source window. Its bytes '
              'are audited as part of `sed`.',
    'sedio': 'not a spawnable binary -- sed\'s stream-io half, split '
             'from sedexec.s for the as source window (S9 tier 2). '
             'Its bytes are audited as part of `sed`.',
    'shtok': 'not a spawnable binary -- sh\'s tokenizer half, split '
             'from shlex.s for the as source window (S9 tier 2). Its '
             'bytes are audited as part of `sh`.',
    'shcls': 'not a spawnable binary -- sh\'s classifier half, split '
             'from shlex.s for the as source window (S9 tier 2). Its '
             'bytes are audited as part of `sh`.',
    'expr.match': 'not a spawnable binary -- expr\'s `:` matching '
                  'operator and its grammar level, `put` into '
                  'src/bin/expr.s (2026-10-08, '
                  'docs/POSIX-REGEXLINK.md). Its bytes are audited '
                  'as part of `expr`.',
    'expr.ops': 'not a spawnable binary -- expr\'s string-prep and '
               'arithmetic engines, split from expr.eval.s for the as '
               'source window (S9 tier 2). Its bytes are audited as '
               'part of `expr`.',
    'edfile': 'not a spawnable binary -- ed\'s filename handling and '
              'file-backed commands, `put` into src/bin/ed.s (same '
              'split). Its bytes are audited as part of `ed`.',
    'edsubst': 'not a spawnable binary -- ed\'s substitute engine and '
               'the commands built on it, `put` into src/bin/ed.s '
               '(same split). Its bytes are audited as part of `ed`.',
    'shlex': 'not a spawnable binary -- the main loop, line input, comment stripping, the tokenizer and CLASSIFY, '
           'put into src/bin/sh.s (split for the check-dialect '
           'source-buffer budget). Its bytes are audited as '
           'part of `sh`.',
    'shexpand': 'not a spawnable binary -- the `$` expansion machinery (DOEXPAND and the EMIT* emitters), '
              'put into src/bin/sh.s (split for the check-dialect '
              'source-buffer budget). Its bytes are audited as '
              'part of `sh`.',
    'shsubst': 'not a spawnable binary -- command substitution and ( ) groups, '
             'put into src/bin/sh.s (split for the check-dialect '
             'source-buffer budget). Its bytes are audited as '
             'part of `sh`.',
    'shparse': 'not a spawnable binary -- PARSE, argv/redirect staging and the first builtins, '
             'put into src/bin/sh.s (split for the check-dialect '
             'source-buffer budget). Its bytes are audited as '
             'part of `sh`.',
    'shresv': 'not a spawnable binary -- reserved words and the construct stack, '
            'put into src/bin/sh.s (split for the check-dialect '
            'source-buffer budget). Its bytes are audited as '
            'part of `sh`.',
    'shvar': 'not a spawnable binary -- shell variables and the environment, '
           'put into src/bin/sh.s (split for the check-dialect '
           'source-buffer budget). Its bytes are audited as '
           'part of `sh`.',
    'shbltn': 'not a spawnable binary -- the remaining builtins, here-docs and fd staging, '
            'put into src/bin/sh.s (split for the check-dialect '
            'source-buffer budget). Its bytes are audited as '
            'part of `sh`.',
    'shpath': 'not a spawnable binary -- PATH resolution, READLINE, IFS splitting and globbing, '
            'put into src/bin/sh.s (split for the check-dialect '
            'source-buffer budget). Its bytes are audited as '
            'part of `sh`.',
    'testeval': 'not a spawnable binary -- the `test`/`[` evaluator '
                '`put` into src/bin/sh.s, because `test` is a shell '
                'BUILTIN (docs/SH-SUBSET.md sec 6.3). Its bytes are '
                'audited as part of `sh`.',
    'nohupfd': 'not a spawnable binary -- nohup\'s NOHUP.OUT '
               'redirection package (NH_ISTTY/NH_APPOPEN/'
               'NH_HOMEPTH/NH_FDADD1/NH_FDADD2, plus every message '
               'string), `put` into src/bin/nohup.s (split for the '
               'check-dialect as-window budget -- nohup.s alone '
               'measured 17,800 B stripped, 1,674 B over the '
               '16,128-byte window). Its bytes are audited as part '
               'of `nohup`.',
    'timeoutaux': 'not a spawnable binary -- timeout\'s error-'
                  'diagnostic tail, tick-sampling package (TO_DECODE/'
                  'SAMPLE/TO_REACHD/TO_REACHK), and every option/'
                  'usage/message string plus PERITAB, `put` into '
                  'src/bin/timeout.s (one of TWO put files, split '
                  'for the check-dialect as-window budget -- '
                  'timeout.s alone measured 24,421 B stripped, '
                  '8,295 B over the 16,128-byte window). Its bytes '
                  'are audited as part of `timeout`.',
    'timeoutparse': 'not a spawnable binary -- timeout\'s duration '
                    'and signal parsers (TO_PARSEDUR/TO_MUL10/'
                    'TO_PARSESIG/TO_NAMEIS), `put` into '
                    'src/bin/timeout.s (the second of the two put '
                    'files -- see timeoutaux\'s own entry above for '
                    'why two, not one). Its bytes are audited as '
                    'part of `timeout`.',
}


def check_text_roster():
    """Gate: every src/bin program is declared in exactly one roster.

    Static and cheap, so it runs in `make check-modules` alongside the
    other structural ratchets -- a new binary that nobody classified
    fails here, before check-textaudit ever boots an emulator. The
    runtime gate then checks the classification against measurement.
    """
    failures = []
    print()
    print('[check-purity] sec 29: the runtime writable-text roster')
    programs = sorted(
        os.path.splitext(os.path.basename(p))[0]
        for p in glob.glob(os.path.join(ROOT, 'src/bin/*.s')))
    declared = {}
    for name in TEXT_IMMUTABLE:
        declared.setdefault(name, []).append('TEXT_IMMUTABLE')
    for name in TEXT_MUTABLE:
        declared.setdefault(name, []).append('TEXT_MUTABLE')
    for name in TEXT_UNAUDITED:
        declared.setdefault(name, []).append('TEXT_UNAUDITED')
    print(f'   {len(TEXT_IMMUTABLE)} immutable '
          f'({" ".join(sorted(TEXT_IMMUTABLE))}), '
          f'{len(TEXT_MUTABLE)} mutable, '
          f'{len(TEXT_UNAUDITED)} unaudited, over {len(programs)} '
          f'programs; {len(WARM_UNSAFE)} warm-unsafe '
          f'({" ".join(sorted(WARM_UNSAFE))})')
    for name in programs:
        where = declared.get(name, [])
        if not where:
            failures.append(
                f'src/bin/{name}.s is in no roster in check_purity.py. '
                f'Every program must be declared TEXT_IMMUTABLE, '
                f'TEXT_MUTABLE or TEXT_UNAUDITED (docs/STICKY.md sec 29) '
                f'-- lazy free reuses its bank without recopying its '
                f'text, so "nobody looked" is not a state this tree may '
                f'be in.')
        elif len(where) > 1:
            failures.append(
                f'src/bin/{name}.s is in {len(where)} rosters '
                f'({", ".join(where)}) -- exactly one.')
    for name in sorted(set(declared) - set(programs)):
        failures.append(
            f'{name!r} is declared in check_purity.py but src/bin/'
            f'{name}.s does not exist -- remove the stale entry so the '
            f'ratchet stays honest.')
    for name, head in sorted(TEXT_MUTABLE.items()):
        if not isinstance(head, bool):
            failures.append(
                f'TEXT_MUTABLE[{name!r}] must be a bool -- does the '
                f'ENTRY HEAD move? That bit decides whether the kernel '
                f'retains the bank at all.')
    for name in sorted(set(TEXT_MUTABLE_NOTES) | set(WARM_UNSAFE)):
        if name not in TEXT_MUTABLE:
            failures.append(
                f'{name!r} has a TEXT_MUTABLE_NOTES/WARM_UNSAFE entry '
                f'but is not in TEXT_MUTABLE -- remove the stale entry.')
    return failures


# Emitted, written cells inside src/liba that every program linking
# the module inherits -- docs/STICKY.md sec 17's "bss wearing a hat" at
# library scope. THIS SET MAY ONLY SHRINK, same ratchet rule as
# check_modules.py's KNOWN_DEBT; a stale entry fails too, so retiring
# one cannot leave a dead allowance behind.
#
# 2026-08-22, sec 21: print.s, stdio.s, string.s and syscalls.s are
# EMPTY -- all 25 of their cells moved into src/liba/libabss.s's `dum`
# arena, and the two that are read before they are written
# (SIO_CNT_LO/HI) sit in the kernel's zeroed page at the top of it.
# Their empty entries are deliberately KEPT: with the set empty a new
# `ds` in one of those four modules fails on the "not in LIBA_DEBT"
# branch, which is exactly the ratchet's job.
#
# 2026-08-22, sec 25: AND SO ARE THE OTHER SIX. The 42 cells sec 24's
# widened scan found in getopt/glob/hex/num/readdir/seek -- recorded
# here as a one-time re-baseline because that pass converted only what
# `cat` links -- are in libabss.s's arena now too. THE LIBA RATCHET IS
# THEREFORE EMPTY: liba emits no cell that anything writes, which is
# what "liba's text is immutable" has to mean. Every module keeps its
# empty entry for the reason the first four kept theirs.
LIBA_DEBT = {
    'src/liba/print.s': set(),
    'src/liba/string.s': set(),
    'src/liba/stdio.s': set(),
    # stdiofl.s (2026-08-29, S9 W2): stdio.s's flush/close/exit half,
    # split out for the as-window budget. Same storage story as its
    # first half -- every cell is in libabss.s's arena -- and the
    # empty entry is kept for the same reason as the others: a new
    # `ds` here must fail, not slip in with the new file.
    'src/liba/stdiofl.s': set(),
    'src/liba/syscalls.s': set(),
    'src/liba/getopt.s': set(),
    'src/liba/glob.s': set(),
    'src/liba/hex.s': set(),
    'src/liba/num.s': set(),
    'src/liba/readdir.s': set(),
    # cptree.s (2026-08-25, recursive mv / cp -r) was written under
    # this rule rather than re-baselined into it: it emits nothing at
    # all bar read-only nothing -- its eight MLI parmlists are cells
    # in libabss.s, stored by CPT_INIT, exactly as readdir.s's three
    # are. `mv` is TEXT_IMMUTABLE and retains its bank, so a parmlist
    # in cptree's text would have dirtied mv's image on every run.
    'src/liba/cptree.s': set(),
    'src/liba/seek.s': set(),
    # env.s (docs/SYSCALL.md item 13c) was written under this rule
    # rather than re-baselined into it: it emits nothing but two
    # `equ`s, and its state is in libabss.s's arena. Its empty entry
    # is here for the same reason every other empty entry is -- a new
    # `ds` in it fails on the "not in LIBA_DEBT" branch.
    'src/liba/env.s': set(),
}


# ---------------------------------------------------------------------
# BIN_DEBT -- emitted `ds` bytes in a src/bin program's OWN source
# (docs/STICKY.md sec 29).
#
# WHY THIS EXISTS, which is the part worth keeping. sec 21 ruled that
# program scratch belongs in an uncleared `dum` arena and only a fixed
# kernel-zeroed page is cleared. sec 24 and sec 26 landed that for liba
# and grew LIBA_DEBT to enforce it -- and LIBA_DEBT only ever looked at
# src/liba. So 12,419 bytes of emitted zeros sat in src/bin across
# fifteen files, through a ruling whose own table cites `sort` and `ed`
# BY NAME as the reason `dum` was safe, and nothing went red. `ls` was
# 58% zeros the day this was found.
#
# That is docs/CWD-BANK-BUG.md's blind-suite shape -- a suite where
# every case shares an incidental property cannot see bugs that depend
# on that property -- with the shared property being "lives in liba".
# The fix is not a better liba gate; it is a gate aimed at the half
# nobody was watching. Hence this one, which is deliberately the same
# ratchet shape as LIBA_DEBT so the two cannot drift.
#
# THE RULE IS EXACT EQUALITY, not "<=". A file that drops below its
# allowance fails too, exactly as a stale LIBA_DEBT entry does, so
# retiring debt cannot leave a dead allowance behind for the next `ds`
# to hide in.
#
# NOT COUNTED: a `ds` whose operand mentions `*`. Those are
# PC-relative address pads (`ds $2000-*`), not storage -- they exist to
# place the next label at a fixed address, their size is not a property
# of the source, and converting one to `dum` would be meaningless.
# They are reported separately so they cannot become a hiding place.
BIN_DEBT = {
    # --- genuinely READ BEFORE WRITTEN: these need a real zero -------
    # sec 21 predicted program-level zero-dependence would be rare, and
    # for the 25 one-shot utilities it was: zero bytes. sh is the
    # counterexample, and the reason is structural rather than sloppy --
    # it is the tree's only REPL, so "written before read" has to mean
    # "on the FIRST pass, before any command has run". Seven cells fail
    # that test (CSPTR, LASTSTATUS, POS_SHIFT, SCAN_ACT, PCR_PEND,
    # VARNAMES, VAREXP), VARVALS is paired with VARNAMES, and CSHEAD /
    # CSRKIND / CSRFD / CSRTGT / PCR_KIND / PCR_FD / PCR_TGT carry
    # their own "deliberately emitted" declarations which this pass
    # re-examined and did not overturn. The rest of sh's residue is
    # write-before-read and a clean follow-up; it is inside this number
    # rather than broken out because the number is what ratchets.
    # -- 775 -> 774 on 2026-08-25: SHELL-GAPS sec 3b deleted BSFLAG
    # -- (`ds 1`), the per-token "this word contained an escape" flag.
    # -- Backslash is per-CHARACTER, so the flag was wrong in both
    # -- directions and the escaped bytes mark themselves now. The
    # -- ratchet is TWO-SIDED and said so: it refused a retired byte
    # -- left in the allowance, which is exactly right -- slack is a
    # -- hiding place for the next one.
    # -- 774 -> 773 on 2026-08-27 (subshell reland): SUBBADOP
    # -- (`ds 1`) died with the `| < > ; &` refusal -- a nested sh
    # -- handles the operators -- and the reland's own new scratch
    # -- (SUBPIPEA/SUBBRFD/SUBBWFD/SUBBI, SH_INTERACT) went straight
    # -- to the dum arena with per-cell write-before-read traces,
    # -- where the original branch had emitted it as text `ds` (that
    # -- branch never faced this gate; this number is where that
    # -- debt got paid).
    # -- 773 -> 517 on 2026-08-27: VARVALS (256 B) moved to the dum
    # -- arena. The proof it never needed emitted zeros was already in
    # -- sh.s -- SH_INIT_ZR zeroes VARNAMES and VAREXP BY NAME and
    # -- does not touch VARVALS, so the shell already relied on
    # -- write-before-read for it. Biggest single reclaim in this
    # -- file's history and it was sitting in plain sight between two
    # -- cells that DO carry their own "deliberately emitted"
    # -- justifications; VARVALS never had one.
    # -- 517 -> 253 on 2026-08-27, second pass: VARNAMES (128),
    # -- VAREXP (8) and EXPBUF (128) followed VARVALS into the arena.
    # -- VARNAMES/VAREXP genuinely MUST start zero -- but SH_INIT_ZR
    # -- has zeroed both by name at every entry since sec 32's
    # -- warm-respawn fix, so the emitted zeros became redundant that
    # -- day and nobody came back. EXPBUF's own note already conceded
    # -- it was "no longer load-bearing... left as ds anyway rather
    # -- than moved, since there is no reason to disturb it"; the
    # -- reason is bytes. 520 B total off sh.bin, and check-shwarm's
    # -- $A5 arena poison is what proves the moves are safe.
    # -- 517 -> 253 -> 337 on 2026-08-28: the number did not grow, it
    # -- absorbed testeval.s's 84 (see the re-attribution note below).
    # -- sh.s's own body is now eight put modules and every one of
    # -- their emitted cells is counted here, in the parent's row.
    # -- 337 -> 346 on 2026-09-15: CSCOND (shrsv2.s, MAXCDEPTH=8
    # -- bytes) and SH_ERREXIT (shblt2.s, 1 byte) for `set -e`
    # -- (docs/SH-FEATURES.md). Both carry CSHEAD's own shape of
    # -- justification, not a fresh one: CSCOND[CSPTR-1] is read
    # -- by ERREXIT_CK only when CSPTR is nonzero, and every push
    # -- site that can leave a frame on top with CS_EFFSKIP clear
    # -- (RW_IF, RW_LOOP_PUSH's :seekable, RW_FOR, RW_CASE) writes
    # -- CSCOND before returning; the one push that does not
    # -- (RW_LOOP_PUSH's :dead) can never become the read frame --
    # -- every command nested under it is short-circuited by the
    # -- same CS_EFFSKIP the dead push itself set, so its CSCOND
    # -- is provably unreached, not merely unwritten. SH_ERREXIT
    # -- is zeroed by name at START, the same shape SH_XTRACE
    # -- already uses two lines above it.
    # -- 346 -> 345 on 2026-09-16: SUBWSTAT (shsub2.s, `ds 1`, "SC_
    # -- WAIT's status byte") died with SUB_WAITST's pid-less reap.
    # -- Its replacement reads sh.s's WJSTAT, which SC_WAITJOB's
    # -- other three callers (FG_WAIT, JOB_DRAIN, CHCK_BLTN_WT)
    # -- already share and which lives in the dum arena. The
    # -- ratchet is two-sided, so the byte is given back here
    # -- rather than left as slack for the next `ds` to hide in --
    # -- the same bookkeeping the 774 -> 773 SUBBADOP entry above
    # -- records for the same file.
    # -- 345 -> 261 on 2026-10-17 (KFIX3 item 0): testeval.s's 84 B of
    # -- cells moved to sh's dum arena when its code moved to the
    # -- $D000 segment (a syscall is never handed an address there,
    # -- so TE_GFI and TE_PATHBUF could not stay beside the code).
    # -- 261 -> 262 later the same day: SEGSTAMP (shsegi.s), one
    # -- emitted byte that MUST arrive 0 from the file and stay
    # -- SEG_MAGIC across a warm respawn -- the cold/warm
    # -- discriminator for SEG_INIT. Read before written by
    # -- construction (REPL_ZERO_CELLS in check_shwarm.py).
    # -- 262 -> 260 (SH-PREFIX): CHCK_BLTN_VAR's VEQPOS and VTMP2
    # -- went with it.
    'src/bin/sh.s': 260,

    # -- proshimpg.s (2026-09-07): the 256-byte $BF00 shim page is a
    # -- fixed-layout DATA image, not a program with scratch. Its
    # -- explicit `ds N` runs (BITMAP fill, the 16-byte NEWLINE
    # -- table, the mark parmlist, the ISHACK gap, the WBUF/RBUF
    # -- bytes) are the page's own defined-zero fields, at their
    # -- ProDOS-mandated offsets; proshim copies the whole page into
    # -- the tenant bank every run, so a stale byte cannot survive.
    # -- The `ds ADDR-*` gaps between fields are structural and not
    # -- counted; this 66 is the explicit-`ds` remainder. proshimrm.s
    # -- (the ROM stubs) uses only computed gap fill and needs none.
    'src/bin/proshimpg.s': 66,

    # --- what is left after the sec 31 relay ------------------------
    # ld.s pads to HARD addresses (`ds $8A0-*`, `ds $2000-*`,
    # `ds $3000-*`) because the Merlin LINKER core it hosts has
    # hardcoded expectations, and those are PC pads, not counted here.
    # The cells BELOW the $2000 pad cost nothing to emit either --
    # removing one just grows the pad by a byte -- so converting them
    # would save ZERO image bytes and is not worth the churn.
    #
    # MODBUF (4,096) was the one that WAS costing bytes, and sec 28
    # left it alone because an arena that size ran past BUILDBASE
    # ($6000), LINKER's own accumulation area. sec 31 had to relay
    # this program anyway -- its embedded core sat at SYMADR, where
    # LINKER writes its dictionary, which is what broke the second
    # `ld` of every boot -- and BUILDBASE is ld.s's own equate, so
    # moving it to $6C00 came free with the relay. 6,666 -> 2,574.
    # 2574 -> 2577 on 2026-08-30: -a/-z joined the CLI (S9 L3) --
    # ZFLAG (1) + LNKADDR (2).
    'src/bin/mld.s': 2577,

    # --- module-scoped storage, needs a companion bss module --------
    # expr.eval.s and testeval.s are `put` MODULES, not programs, and
    # in all four of their includers the `put` lands BEFORE
    # libabss.s -- so neither can open a `dum LIBA_BSSEND` in place.
    # Converting them the liba way means a companion `*bss.s` module
    # put after libabss.s in each includer, plus a check_purity
    # ARENA_USERS entry. Mechanical, but it is a new pattern under
    # src/bin and it touches four files for 169 bytes.
    # -- RE-ATTRIBUTED 2026-08-28 (S9). These two were put-MODULES
    # -- carrying their own allowance, which meant a unit's emitted-ds
    # -- debt was split across as many rows as it had bodies -- and S9
    # -- splits units routinely, so that shape would have scattered
    # -- sh.s's 253 bytes over eight new rows and hidden the total.
    # -- A module's bytes now count against its PARENT (bin_ds_bytes
    # -- takes the whole src/bin put chain; put_modules() derives the
    # -- membership rather than listing it, and bin_debt_check skips
    # -- a module as a program so nothing is counted twice). The
    # -- numbers only MOVED: 253+84 -> sh.s 337, 85 -> expr.s 85,
    # -- tree total 3,091 before and after.
    'src/bin/expr.s': 85,

    # --- self-modifying by design, never audited --------------------
    # as.s is a port of Merlin 8's assembler core and uses its own
    # image as workspace: it differs from its own .bin in 8,686 bytes
    # after ONE run (learning:01M0MEKF0H8AVAXJG4PZ7P5QXC). It is
    # already excluded from the warm-respawn path for that reason, and
    # a `dum` conversion of its scratch would be reasoning about a
    # program that rewrites the ground it stands on.
    #
    # 95 -> 92 on 2026-08-28: AS_GOREAD's RDXFORM factoring retired
    # SRCFD and XFORM_LEFT as emitted cells (they moved into the dum
    # arena as RDX_FD/RDX_LEFT). Lowered rather than left slack --
    # an allowance above the real count is a place for the next three
    # bytes of `ds` to hide.
    'src/bin/as.s': 92,
}


def bin_ds_bytes(program):
    """Emitted `ds` bytes in one src/bin program's OWN file.

    Returns (bytes, [pad_lines]). Only the program's own source counts:
    liba's storage is LIBA_DEBT's business, and double-counting it here
    would make every program look identical and hide the thing this
    gate is for.
    """
    lines = expand(os.path.join(ROOT, program))
    own = os.path.basename(program)
    equs = {}
    for ln in lines:
        if ln.op in ('equ', '=') and ln.label:
            try:
                equs[ln.label] = _expr(ln.operand, equs)
            except ValueError:
                pass
    total, pads = 0, []
    for ln in lines:
        if ln.op != 'ds' or ln.in_dum:
            continue
        # The program's OWN source is the program file plus any
        # same-directory module it `put`s -- sedexec.s, testeval.s,
        # the ed*/sh* bodies S9 split out. Those bytes are the
        # parent's (their rosters in TEXT_UNAUDITED say exactly
        # that), and bin_debt_check below skips them as programs so
        # they are counted once, here. The exclusion this filter
        # exists for is liba, whose storage is LIBA_DEBT's business:
        # counting it here would make every program look identical.
        if not ln.file.replace(os.sep, '/').startswith('src/bin/'):
            continue
        # A PC-relative pad is a `*` in TERM position (`ds $2000-*`);
        # a `*` in OPERATOR position is multiply (`ds MAXCDEPTH*3`).
        # Two wrong ways to tell them apart, both of which this gate
        # was written with first: a plain `'*' in operand` test calls
        # every multiplied array a pad and drops it from the ratchet
        # (it under-counted sh.s by 424 bytes); and splitting on the
        # operator class and testing the even indices fails on `-*`,
        # because `-` and `*` are ADJACENT operators, so the term
        # between them is the empty string and the `*` lands on an odd
        # index (it silently dropped all three of ld.s's pads).
        # A term position is the start of the expression or straight
        # after an operator, which is what this tests.
        _op = ln.operand.strip().replace(' ', '')
        if _op.startswith('*') or re.search(r'[+\-*/]\*', _op):
            pads.append(ln.where())
            continue
        try:
            total += _expr(ln.operand, equs)
        except ValueError:
            raise SystemExit(
                f'check_purity: {ln.where()}: cannot evaluate '
                f'`ds {ln.operand}`. The BIN_DEBT ratchet needs every '
                f'non-pad `ds` operand to be a constant expression.')
    return total, pads


def _expr(tok, equs):
    """A Merlin operand expression: STRICTLY left to right, no
    precedence (learning:01M051DJW89KV4JYM1EC9SDZ5Y). Getting this
    wrong would silently mis-size the ratchet, so it is spelled out
    rather than handed to eval()."""
    parts = re.split(r'([+\-*/])', tok.strip())

    def val(t):
        t = t.strip()
        if not t:
            return 0
        if t.startswith('$'):
            return int(t[1:], 16)
        if t.isdigit():
            return int(t)
        if t in equs:
            return equs[t]
        raise ValueError(t)

    acc, i = val(parts[0]), 1
    while i < len(parts) - 1:
        rhs = val(parts[i + 1])
        acc = {'+': acc.__add__, '-': acc.__sub__,
               '*': acc.__mul__, '/': acc.__floordiv__}[parts[i]](rhs)
        i += 2
    return acc


def put_modules():
    """src/bin files that another src/bin file `put`s -- i.e. bodies of
    a larger unit rather than programs. A bare (no-slash) put operand is
    a same-directory module; a liba put carries a path and is not one.
    Derived, never hand-listed: S9 splits units routinely and a stale
    list here would silently drop a file out of the ratchet."""
    mods = set()
    for path in glob.glob(os.path.join(ROOT, 'src/bin/*.s')):
        for line in open(path, errors='replace'):
            m = re.match(r'\s+put\s+(\S+\.s)\s*(;.*)?$', line.rstrip())
            if not m:
                continue
            # Resolve against the putting file's directory: a module is
            # one that lands back in src/bin (testeval.s is put as
            # ../bin/testeval.s, so a bare-name test would miss it and
            # count its bytes twice -- once here, once standalone).
            tgt = os.path.normpath(
                os.path.join(os.path.dirname(path), m.group(1)))
            rel = os.path.relpath(tgt, ROOT).replace(os.sep, '/')
            if rel.startswith('src/bin/') and rel != os.path.relpath(
                    path, ROOT).replace(os.sep, '/'):
                mods.add(rel)
    return mods


def bin_debt_check():
    """The src/bin emitted-`ds` ratchet. Returns a list of failures."""
    failures = []
    rows = []
    modules = put_modules()
    for path in sorted(glob.glob(os.path.join(ROOT, 'src/bin/*.s'))):
        rel = os.path.relpath(path, ROOT)
        if rel in modules:
            continue        # audited as part of its parent, above
        n, pads = bin_ds_bytes(rel)
        allowed = BIN_DEBT.get(rel, 0)
        rows.append((rel, n, allowed, pads))
        if n > allowed:
            failures.append(
                f'{rel}: {n} bytes of emitted `ds`, but BIN_DEBT allows '
                f'{allowed}. Program scratch belongs in a `dum` arena '
                f'at the file\'s textual end (docs/STICKY.md sec 21/28) '
                f'-- unless the cell is READ BEFORE IT IS WRITTEN, in '
                f'which case it needs a real zero and a named entry in '
                f'check_purity.BIN_DEBT saying so.')
        elif n < allowed:
            failures.append(
                f'{rel}: {n} bytes of emitted `ds` but BIN_DEBT still '
                f'allows {allowed}. Debt was retired without lowering '
                f'the number -- drop it to {n} so the allowance cannot '
                f'become a hiding place.')
    for rel in sorted(BIN_DEBT):
        if not os.path.exists(os.path.join(ROOT, rel)):
            failures.append(
                f'{rel}: in BIN_DEBT but the file does not exist.')
    return rows, failures


def liba_debt_scan(program):
    """Emitted+written liba cells one program carries.

    Reported and ratcheted, not fatal -- see LIBA_DEBT's own comment.
    Same four shapes as the program-level audit, same code.
    """
    dirty = {}
    for shape, hits in find_writes(
            expand(os.path.join(ROOT, program))).items():
        for _, sym, decl, _extra in hits:
            if decl.file.startswith('src/liba/'):
                dirty.setdefault(decl.file, set()).add(sym)
    return dirty


# ---------------------------------------------------------------------
# docs/STICKY.md sec 21's structural rules. All three protect the same
# thing: `dum` computes addresses from the real PC where it opens and
# `dend` restores that PC, so a block in the wrong place is silently
# overlaid and a second block at the same anchor silently aliases the
# first (learning:01M0FNC75R7YSFRNS328WHXMHN). Both failures are
# invisible at assembly time and produce a program that mostly works.
# ---------------------------------------------------------------------
LIBABSS = 'src/liba/libabss.s'
BANKCOPY = 'src/kernel/bankcopy.s'
# Anything on a line AFTER the libabss put that would emit bytes or
# reserve storage outside a dum block. `equ` (PAR_PROC_LEN and friends)
# and the dum/dend pair itself are fine -- they emit nothing.
TAIL_OK = {'', 'dum', 'dend', 'equ', '=', 'lst', 'end'}
# The liba modules whose storage lives in libabss.s. A program that
# `put`s any of them MUST `put` libabss.s too -- otherwise every one of
# that module's cells is an undefined symbol, or worse, resolves to
# something else. Named explicitly rather than matching `../liba/`
# wholesale: a `put ../inc/zp.equ` defines equates and needs no arena.
# The last six joined under sec 25, which is also what pulled
# src/test/globtest.s (a glob.s-only manifest) into the scan below.
# env.s joined 2026-08-22 (docs/SYSCALL.md item 13c): GETENV's cursor
# (GENV_CNT/GENV_OFF) lives in libabss.s's arena like everything else.
# cptree.s joined 2026-08-25 (recursive mv / cp -r): its ~950 bytes,
# the eight MLI parmlists included, are cells in libabss.s for the
# reason recorded there -- a companion `*bss.s` module cannot be `put`
# after libabss.s, because check_arena_anchors() below forbids it.
# readsyn.s joined 2026-10-17 (docs/GLOB-VROOT.md): it writes the
# RD_* cells that readdir.s used to; mount/umount put it WITHOUT
# readdir.s, so the readdir.s entry no longer covers them.
# readsys.s (KFIX8) is the three SC_* gates split out of readsyn.s:
# SC_DEVLIST writes RD_RPARM_REQ, and mount/umount put it ALONE.
ARENA_USERS = ('/string.s', '/stdio.s', '/print.s', '/syscalls.s',
               '/getopt.s', '/glob.s', '/hex.s', '/num.s',
               '/readdir.s', '/seek.s', '/env.s', '/cptree.s',
               '/readsyn.s', '/readsys.s')


def _int(tok):
    tok = tok.strip()
    if tok.startswith('$'):
        return int(tok[1:], 16)
    return int(tok)


def check_zpage_len():
    """Gate: LIBA_ZPGLEN == BC_ZPG_LEN, and the zeroed group fits.

    The kernel zeroes BC_ZPG_LEN bytes at the image end; libabss.s
    lays its read-before-write cells out against LIBA_ZPGLEN. Userland
    cannot `put` a kernel module, so the number is spelled twice and
    nothing but this compares them. If they drift the smaller wins
    silently: cells past the real page start as garbage, which for
    SIO_CNT_LO/HI is not a wrong value but a buffered write landing at
    a random address.
    """
    failures = []
    print()
    print('[check-purity] sec 21: the zeroed page, spelled in two files')
    kern, user = None, None
    for line in open(os.path.join(ROOT, BANKCOPY), errors='replace'):
        m = re.match(r'\s*BC_ZPG_LEN\s+equ\s+(\S+)', line)
        if m:
            kern = _int(m.group(1))
    lines = list(open(os.path.join(ROOT, LIBABSS), errors='replace'))
    for line in lines:
        m = re.match(r'\s*LIBA_ZPGLEN\s+equ\s+(\S+)', line)
        if m:
            user = _int(m.group(1))
    if kern is None or user is None:
        failures.append(
            f'BC_ZPG_LEN ({kern}) or LIBA_ZPGLEN ({user}) not found -- '
            f'{BANKCOPY} and {LIBABSS} must each declare theirs.')
        return failures
    print(f'   BC_ZPG_LEN={kern}  LIBA_ZPGLEN={user}')
    if kern != user:
        failures.append(
            f'BC_ZPG_LEN={kern} in {BANKCOPY} but LIBA_ZPGLEN={user} in '
            f'{LIBABSS}. The kernel zeroes one length and liba lays out '
            f'against another; the shortfall starts as garbage.')

    # Bytes reserved between LIBA_ZPG and the LIBA_ZPGEND marker.
    used, inside = 0, False
    for raw in lines:
        f = _fields(raw)
        if f is None:
            continue
        label, op, operand = f
        if label == 'LIBA_ZPG':
            inside = True
            continue
        if label == 'LIBA_ZPGEND':
            inside = False
            continue
        if inside and op == 'ds':
            used += _int(operand)
    print(f'   zero-requiring cells: {used} B of {user} '
          f'({user - used} spare)')
    if used > user:
        failures.append(
            f'{LIBABSS}: the cells above LIBA_ZPGEND reserve {used} B but '
            f'the kernel only zeroes {user}. Everything past the page '
            f'starts as garbage.')
    return failures


def _bss_only_module(name):
    """A liba module that RESERVES and emits nothing: every line outside
    a dum/dend block is a comment, an equate or assembler control.

    This is the whole distinction check_arena_anchors() cares about. The
    rule it enforces -- nothing after libabss.s -- exists because that
    arena opens at `*` and `dend` restores that PC, so a later module's
    EMITTED bytes land on top of liba's storage. A module that emits
    nothing cannot do that, and chaining one is the only way a liba
    module can own storage without charging it to all 40 programs.

    Measured, 2026-08-25: putting cptree's ~950 bytes in libabss.s
    instead broke `as`, whose arena is bounded at SYMADR ($3C00) rather
    than $BF00 and had ~540 bytes spare -- `make check-userland` failed
    on as.s's own `err */SYMADR`. A shared arena makes every future
    liba addition pay that again.

    Returns (ok, detail).
    """
    path = os.path.join(ROOT, 'src/liba', name)
    if not os.path.exists(path):
        return False, f'src/liba/{name} does not exist'
    depth = 0
    end_labels = set()
    opened_at = None
    for j, raw in enumerate(open(path, errors='replace'), 1):
        f = _fields(raw)
        if f is None:
            continue
        label, op, operand = f
        if op == 'dum':
            if depth == 0:
                opened_at = operand.split(';')[0].strip()
            depth += 1
            continue
        if op == 'dend':
            depth = max(0, depth - 1)
            continue
        if depth == 0 and op not in TAIL_OK:
            return False, (f'src/liba/{name}:{j} emits or reserves '
                           f'({op!r}) OUTSIDE any dum block. A module '
                           f'chained after libabss.s may only declare '
                           f'storage -- anything it emits lands on top '
                           f'of liba\'s arena.')
        if depth and label and not op:
            end_labels.add(label)
    if opened_at != 'LIBA_BSSEND':
        return False, (f'src/liba/{name} opens its arena at '
                       f'{opened_at!r}; a module chained after '
                       f'libabss.s must open at LIBA_BSSEND, or it '
                       f'overlaps liba\'s own storage.')
    if not end_labels:
        return False, (f'src/liba/{name} defines no bare end label '
                       f'inside its dum block, so no program can anchor '
                       f'its own arena past it.')
    return True, end_labels


def check_arena_anchors():
    """Gate: the libabss put is last, and nobody else anchors at `*`."""
    failures = []
    print()
    print('[check-purity] sec 21: liba arena placement (put last, and '
          'the program anchors at LIBA_BSSEND)')
    scanned = 0
    programs = sorted(
        os.path.relpath(p, ROOT)
        for p in glob.glob(os.path.join(ROOT, 'src/bin/*.s')))
    programs += ['src/test/bufwriter.s', 'src/test/seekwr.s',
                 'src/test/exprtest.s', 'src/test/testevtest.s',
                 'src/test/globtest.s', 'src/test/envprobe.s']
    for prog in programs:
        raws = list(open(os.path.join(ROOT, prog), errors='replace'))
        idx = [i for i, l in enumerate(raws) if 'libabss.s' in l
               and re.match(r'\s+(put|use)\s', l)]
        puts = [i for i, l in enumerate(raws)
                if re.match(r'\s+(put|use)\s+\.\./liba/', l)]
        needs = [i for i in puts
                 if any(m in raws[i] for m in ARENA_USERS)]
        if not idx:
            if needs:
                failures.append(
                    f'{prog} `put`s {len(needs)} liba module(s) whose '
                    f'storage lives in ../liba/libabss.s, but does not '
                    f'`put` libabss.s itself.')
            continue
        scanned += 1
        at = idx[-1]
        # A BSS-ONLY module may be CHAINED after libabss.s -- it emits
        # nothing, so there is nothing to land on liba's storage, and
        # chaining is what lets a liba module own arena without charging
        # every program for it (see _bss_only_module). Anything else
        # after the put is the original error.
        chained = []
        anchors = set()
        for p in [p for p in puts if p > at]:
            m = re.match(r'\s+(?:put|use)\s+\.\./liba/(\S+)', raws[p])
            ok, detail = _bss_only_module(m.group(1)) if m else (False, '')
            if not ok:
                failures.append(
                    f'{prog}: {m.group(1) if m else raws[p].strip()!r} is '
                    f'`put` AFTER ../liba/libabss.s and is not a BSS-ONLY '
                    f'module. The arena opens at `*` and `dend` restores '
                    f'that PC, so every byte the later module emits lands '
                    f'on top of liba\'s storage. ' + (detail or ''))
            else:
                chained.append(m.group(1))
                anchors |= detail
        if any(re.match(r'\s+(put|use)\s', l) for l in raws[at + 1:]
               if not re.match(r'\s+(put|use)\s+\.\./liba/', l)):
            failures.append(
                f'{prog}: something that is not a liba module is `put` '
                f'AFTER ../liba/libabss.s.')
        # With a module chained on, the PROGRAM's own arena must open
        # past it. Anchoring at LIBA_BSSEND again would put the two
        # blocks on the same bytes -- the `dum *` failure one screen
        # down, one indirection along.
        if chained:
            own = [_fields(l) for l in raws]
            own = [f for f in own if f and f[1] == 'dum']
            bad = [f[2].split(';')[0].strip() for f in own
                   if f[2].split(';')[0].strip() == 'LIBA_BSSEND']
            if bad:
                failures.append(
                    f'{prog} chains {chained} after libabss.s but still '
                    f'opens its own arena at LIBA_BSSEND -- the same '
                    f'address that module opened at, so the two blocks '
                    f'ARE the same bytes. Anchor at one of {sorted(anchors)}.')
        depth = 0
        for j, raw in enumerate(raws[at + 1:], at + 2):
            f = _fields(raw)
            if f is None:
                continue
            _, op, _o = f
            if op == 'dum':
                depth += 1
                continue
            if op == 'dend':
                depth = max(0, depth - 1)
                continue
            if op in ('put', 'use'):
                continue          # already vetted as BSS-ONLY above
            if depth == 0 and op not in TAIL_OK:
                failures.append(
                    f'{prog}:{j} emits or reserves ({op!r}) after the '
                    f'libabss.s `put`, outside any dum block -- it will '
                    f'overlay liba\'s arena.')
                break
        for j, raw in enumerate(raws, 1):
            if re.match(r'\s+dum\s+\*\s*$', raw.rstrip()):
                failures.append(
                    f'{prog}:{j} anchors its own arena at `dum *`, the '
                    f'same PC src/liba/libabss.s already opened at. Two '
                    f'blocks at `*` are the SAME BYTES -- anchor at '
                    f'LIBA_BSSEND.')
    print(f'   {scanned} program(s) carry liba\'s arena')
    return failures


def run_all():
    """Returns a list of failure strings (empty == pass)."""
    failures = []
    programs = sorted(
        os.path.relpath(p, ROOT)
        for p in glob.glob(os.path.join(ROOT, 'src/bin/*.s')))
    all_debt = {}
    failures += check_zpage_len()
    failures += check_arena_anchors()

    print()
    print('[check-purity] sec 28: emitted `ds` bytes in src/bin '
          'programs (ratchet: must match BIN_DEBT exactly)')
    rows, bin_fail = bin_debt_check()
    failures += bin_fail
    total = sum(r[1] for r in rows)
    npad = sum(len(r[3]) for r in rows)
    for rel, n, allowed, pads in rows:
        if n or allowed or pads:
            note = f'  ({len(pads)} PC-relative pad(s), not counted)' \
                if pads else ''
            print(f'   {os.path.basename(rel):<14} {n:>6}'
                  f'  allowed {allowed}{note}')
    print(f'   {"TOTAL":<14} {total:>6} bytes of emitted `ds` across '
          f'{len(rows)} programs ({npad} pads excluded)')

    failures += check_text_roster()
    print()
    print('[check-purity] writable-text audit (docs/STICKY.md sec 21) -- '
          'programs whose OWN text is claimed immutable')
    for prog in programs:
        for src, syms in liba_debt_scan(prog).items():
            all_debt.setdefault(src, set()).update(syms)
    for prog in PURE_PROGRAMS:
        findings = audit(prog)
        n = sum(len(v) for v in findings.values())
        print(f'   {os.path.basename(prog):<12} '
              f'{"CLEAN" if n == 0 else str(n) + " writable-text cell(s)"}')
        for ln, sym, decl, _x in findings['direct']:
            failures.append(
                f'{prog}: {ln.where()} writes {sym!r}, emitted as text at '
                f'{decl.where()} ({decl.op}). {prog} is on '
                f'check_purity.PURE_PROGRAMS, so its text is claimed '
                f'immutable -- move {sym!r} into its `dum` arena.')
        for ln, sym, decl, dst in findings['indirect']:
            failures.append(
                f'{prog}: {ln.where()} loads the address of {sym!r} (emitted '
                f'as text at {decl.where()}) into {dst}, which is written '
                f'through by an indirect store. Same violation as a direct '
                f'write -- move {sym!r} into the arena.')
        for ln, sym, decl, _x in findings['addrword']:
            failures.append(
                f'{prog}: {ln.where()} emits the address of {sym!r} (text, '
                f'declared {decl.where()}) as a data word. If that is a '
                f'buffer the kernel writes, the text is not immutable; if it '
                f'is a read-only table entry, the audit cannot tell. Move '
                f'{sym!r} into the arena either way.')
        for ln, sym, decl, call in findings['syscall']:
            failures.append(
                f'{prog}: {ln.where()} hands {sym!r} (text, declared '
                f'{decl.where()}) to {call}. The kernel writes results back '
                f'into a parmlist, so this block is mutable even though no '
                f'instruction in the source stores to it -- move {sym!r} '
                f'into the arena.')

    print()
    print('[check-purity] src/liba cells that are emitted AND written, '
          'inherited by every program that links the module '
          '(ratchet: may only shrink)')
    for src in sorted(set(all_debt) | set(LIBA_DEBT)):
        got = all_debt.get(src, set())
        allowed = LIBA_DEBT.get(src, set())
        print(f'   {src:<22} {len(got):>2}  {" ".join(sorted(got)) or "--"}')
        new = got - allowed
        if new:
            failures.append(
                f'{src}: {sorted(new)} are emitted text that gets written, '
                f'and are NOT in check_purity.LIBA_DEBT. liba grew new '
                f'writable text -- every program that links it inherits a '
                f'dirty image. Put them in a `dum` arena, or record them '
                f'here with a reason.')
        stale = allowed - got
        if stale:
            failures.append(
                f'{src}: LIBA_DEBT lists {sorted(stale)} but nothing writes '
                f'them any more -- remove the stale entries so the ratchet '
                f'stays honest.')
    return failures


def main():
    failures = run_all()
    for f in failures:
        print(f'[check-purity] FAIL: {f}', file=sys.stderr)
    if failures:
        return 1
    print('[check-purity] PASS')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
