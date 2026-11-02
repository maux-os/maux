#!/usr/bin/env python3
"""check_poison.py -- the derived poison-roster gate (docs/STICKY.md sec
PLACEHOLDER, stream T2).

WHY THIS EXISTS. docs/STICKY.md sec 28/32/37 built the $A5-arena-poison
technique (`learning:01M0M9R7RT22JEPP2R0Y6J9MBX`) one gate at a time --
`check-catread` for `cat`, `check-ls` for `ls`, then `check-du`/
`check-find`/`check-sed`/`check-shwarm` -- and each landing was its own
adversarial-review finding, never a tree-wide count. Nobody had asked
"of every program whose storage lives in an uncleared `dum` arena, how
many gates actually prove write-before-read on it?" until this file
asked it. The answer, derived below rather than typed, has moved
twice since -- **6 of 32** the day this file landed, then **13 of 32**
once the detector could see the derived `arena_span('prog')` idiom
(docs/STICKY.md sec 41), then **32 of 32** once it could also see a
FLEET-WIDE poisoner that names its programs through a loop over a
derived roster rather than literally at all (sec 41's own addendum).
That is not one number to remember -- it is why this file exists
instead of a number: run it and read what it says today.

WHAT "DERIVE, NOT ENUMERATE" MEANS HERE, concretely:

  1. THE CONVERTED ROSTER is not a hardcoded list of names. It is
     every top-level `src/bin/*.s` manifest (via
     scripts/check_manifests.py's own build_graph()/toplevel_manifests()
     -- never a second put/use parser) whose OWN file opens a real
     `dum`/`dend` block. That single rule is what already excludes
     `expr.eval.s`/`sedexec.s`/`testeval.s` (they are `put` TARGETS, not
     top-level manifests -- toplevel_manifests() says so on its own),
     `asrom.s` (top-level, but its `dum` only appears inside a COMMENT --
     see has_real_dum_block()'s own line-anchored match) and `expr.s`
     (top-level, genuinely no `dum` block: unconverted). `as.s` USED TO
     be in that last group (docs/STICKY.md sec 28) but stream T5 gave
     it a real `dum LIBA_BSSEND`/`dend` block of its own, so it is now
     IN the converted roster -- and, unlike the 32 that landed there
     before it, arrived with no poisoning gate of its own, which is
     what this file exists to catch.

  2. WHICH GATES POISON is not a hardcoded {gate: program} table either,
     and this rule has ALREADY gone stale once (docs/STICKY.md sec 41):
     it originally recognised only ONE route, and the day after this
     file landed, `check_tail.py`/`check_diff.py`/`check_nm.py`/
     `check_comm.py` were converted to poison via a DIFFERENT idiom this
     detector could not see at all. Both routes are recognised now, and
     BOTH must be kept, because both are live in the tree:

     - **THE LEGACY ROUTE**: the gate's own source mentions a symbol
       matching `<P>_BSSEND` (case-insensitive) -- the arena-end anchor
       six programs still carry as a hand-written label (docs/
       STICKY.md sec 21/24/28/32/37). `check_ls.py`/`check_du.py`/
       `check_find.py`/`check_sed.py`/`check_shwarm.py`/
       `check_catread.py` all use it. **It is fragile in a way this
       stream measured directly**: `check_tail.py` mentions the literal
       string `TAIL_BSSEND` only inside a comment explaining that
       `tail.s` has NO such label -- a true-positive purely by
       coincidence (the mentioned name happens to be the right
       program), which is exactly the shape a FALSE positive would
       take with a different comment. Kept only because the six
       existing gates still use it; do not add a seventh.
     - **THE DERIVED ROUTE, current as of stream T2**: the gate's own
       source calls `arena_span('<prog>')` (via `arena.arena_span(...)`,
       `arenamod.arena_span(...)`, or unqualified -- the CALL is what
       matters, not the import spelling) with a literal string naming a
       roster program. This is what `scripts/arena.py` exists for --
       no label, no `_BSSEND` symbol, needed at either end -- and it is
       the route every gate written AFTER this file landed should use.

     EITHER route only counts alongside (b): the same file must also
     declare `POISON = 0xA5`, the tree's one spelling of the poison
     byte in every gate that uses it. Requiring (b) is what keeps
     `check_fork.py`/`check_ascore.py` excluded even though both poke
     `0xA5` for unrelated reasons (docs/STICKY.md sec 27's fork-copy-
     cleanliness check, and an unrelated ascore assembly-completion
     probe): re-verified after widening to the derived route, since a
     widened predicate is exactly how a false positive gets in --
     neither file calls `arena_span(` or mentions a `_BSSEND` symbol,
     so neither is mistaken for a program-arena poison by either route.

     TWO LAYERS, three mechanisms so far, all derived from tokens
     rather than asserted: a gate that ALSO parks on the `R_GO`/
     `GAP_WAIT_PID` handshake (check_ls.py's own protocol, reused by
     check_du.py/check_find.py/check_sed.py/check_tail.py/
     check_diff.py) re-poisons BETWEEN runs, catching the lazy-free
     hazard docs/STICKY.md sec 25 describes -- a retained bank holds
     the SAME program's own last run, not an unrelated occupant's
     garbage, so a pre-boot-only poison is consumed by run 1 and every
     later run is blind. `check_shwarm.py` proves the same property
     through `until_pc` on `LZ_RETAIN` directly (docs/STICKY.md sec 32)
     rather than `R_GO`; `check_nm.py`/`check_comm.py` prove it through
     a THIRD mechanism, `scripts/textaudit.py`'s shared `TextAuditor`
     class stopping on the same `LZ_RETAIN` entry (so `until_pc` itself
     is inside textaudit.py, not in the gate's own source -- the
     `until_pc`+`LZ_RETAIN` co-occurrence rule alone would have missed
     these two the same way the `_BSSEND` rule missed the arena_span
     route). All three count as "both layers" here, and each is
     recorded by name in GATE_MECHANISM below rather than silently
     merged, because a fourth gate arriving with a fourth mechanism
     should be a naming decision, not a silent miss.

     PER-PROGRAM WITHIN ONE GATE, the layers can differ, and two of the
     four newly-recognised gates prove it on their own fixtures:
     `check_diff.py` poisons `diff` (ten spawns, real between-run
     proof) and `ed` (one spawn, pre-boot only -- its own docstring
     says so) in the SAME file, and the between-run gap-servicing loop
     only re-pokes the arena variable bound to `diff`'s own
     `arena_span()` call, never `ed`'s -- derived here by checking
     whether that SPECIFIC variable name is referenced after the
     `R_GO_REQ` poll begins. `check_comm.py` poisons five programs
     (`sh`/`tee`/`comm`/`cat`/`wc`) from ONE dict-driven retire hook
     that would, read naively, credit all five with "both layers" --
     but its own `REPEATED = (TEE_PATH, COMM_PATH)` tuple says only two
     of them are actually exercised twice, and `cat`/`wc` are each
     spawned once (its own docstring: "there is no between-run claim
     made for either"). `_repeated_via_tuple()` reads that tuple
     structurally, mapped back to program names through the file's own
     `NAME_PATH = f'/mnt/{VOL}/NAME'` constants, rather than trusting the
     prose. `check_nm.py` has no such tuple (nothing here demotes `sh`
     from it, but `sh` is not a debt program either way -- it already
     has its own dedicated gate).

  2c. A THIRD IDIOM neither route above can see: `check_textaudit.py`
     poisons a whole FLEET of programs through `arenas[name] =
     arena_span(name)` -- `name` a LOOP VARIABLE bound to `check_
     purity`'s converted roster, never a literal string anywhere in
     the file. Both `BSSEND_RE` and `ARENA_SPAN_CALL_RE` are text
     patterns for a specific SHAPE of call; a loop over a derived
     roster is a third shape, and this stream's own thesis says a
     fourth regex is not the fix -- ask the module what it declares
     instead. `discover_fleet_poisoners()` imports `build_textaudit_
     image` (the module `GROUP_BINS` is actually defined in) and reads
     its roster, plus `repeat_pairs()`/`unpaired()` per group to tell a
     genuinely-repeated program (real between-run proof) from an
     `ONCE()`-only one (single spawn, no output comparison of any kind
     beyond vacuity). If the import fails for any reason (a missing
     sibling dependency, a built-tree requirement this otherwise-
     static gate must never impose), it falls back to reading
     `GROUP_BINS` off the source text via `ast.literal_eval` -- still
     the object, never a guess -- and says so explicitly in the
     report: credit from a DECLARATION is not credit from a
     MEASUREMENT, and a reader should be able to tell which they are
     looking at.

     STRENGTH, not just coverage
     (`learning:01M0PG8GD5A83BFKWFV0TJCSPP`): `check_textaudit.py`'s
     repeat pairs have NO independent oracle -- run 1 IS the
     expectation -- so a uniform poison value is structurally blind to
     any bug it makes deterministic; it still catches a crash, a hang,
     or a vacuity violation. A program with a DEDICATED gate (anything
     else in this roster) has an independent expected-bytes oracle and
     is reported 'strong'; a program reached ONLY by the fleet-wide
     poisoner is 'weak-repeat' or 'weak-once' (weaker still: no output
     comparison at all). Two programs poisoned identically by the
     letter of "has a gate" can be very differently PROVEN, and
     collapsing that distinction is exactly the kind of gap this
     stream exists to stop making.

  3. WHICH GATE BOOTS WHICH PROGRAM is derived from each gate's own
     image builder (scripts/build_*_image.py) by walking its literal
     Python string/byte constants (the `ast` module, not a hand-rolled
     format-specific regex per file -- these 39 files use at least
     three different conventions: build_v1_system_image.py's list of
     `(name, path)` tuples, build_textaudit_image.py's `GROUP_BINS`
     dict of bare names, and every single-program gate's
     `os.path.join(ROOT, 'build', '<name>.bin')`) and matching every
     `<name>.bin` path component or bare short token against the
     converted roster. THIS IS ADVISORY, not load-bearing for pass/
     fail: it is printed so a human can cross-check it against the
     hand-mapped facts a scout already produced (see BOOT_MAP_SCOUT_
     FACTS below), and any mismatch is reported rather than silently
     reconciled. What DOES gate pass/fail is narrower and firmer: does
     the poisoning gate identified in step 2 actually stage the
     program's own `.bin` at all. See boot_check_poisoners().

  4. THE DEBT SET. Every converted program with no poisoning gate is a
     FAIL, held open by POISON_DEBT below -- a shrink-only ratchet,
     exactly BIN_DEBT's and LIBA_DEBT's shape (check_purity.py) and
     OUT_OF_SCOPE_LINE_DEBT's (check_dialect.py): membership may only
     shrink (a program leaves it by gaining a poisoning gate), a stale
     entry (a name no longer in the converted roster, or one that DOES
     have a poisoning gate now) fails the gate too, and it is sorted
     one name per line so two engineers shrinking it concurrently
     merge cleanly instead of colliding on one edited line.

WHAT THIS DOES NOT DO. It never boots an emulator and never invokes
merlin32 -- purely a source-text derivation, the same constraint
check_purity.py and check_manifests.py already keep, so it can run
under `make check-modules` (which check-modules's own docstring already
promises never needs a build) without depending on build/ artifacts
that may not exist yet (docs/PLAN.md's own from-scratch-`build/`-trips-
a-bootstrap-cycle trap). A program's ACTUAL arena span -- the two
addresses a poisoning gate needs to poke -- is scripts/arena.py's job,
not this file's; this file only asks "does SOME gate do that for this
program", never what the span's numbers are.

ONE EXCEPTION, and it is deliberate: `discover_fleet_poisoners()`
attempts a plain Python `import` of `scripts/build_textaudit_image.py`
to read its live `GROUP_BINS`/`repeat_pairs()`/`unpaired()` rather than
guess at them from text (a fleet-wide poisoner names its roster
through a loop, so there is no literal text left to derive it from --
see item 2c). That import has no emulator, no merlin32, and (verified)
no side effects and no built-tree requirement in this tree today; if
it ever fails in some other environment, the fallback reads `GROUP_
BINS` via `ast.literal_eval` on the source text instead -- still no
import, still not a guess -- and the report says the credit came from
a declaration rather than a measurement.
"""
import ast
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, 'scripts')

sys.path.insert(0, SCRIPTS)
import check_manifests  # noqa: E402 -- build_graph()/toplevel_manifests(),
                         # never a second put/use parser (this file's own
                         # charter: "you may ADD a self-contained block to
                         # check_manifests.py; do not touch toplevel_
                         # manifests()" -- so it is imported, not re-lifted)


# ---------------------------------------------------------------------
# 1. THE CONVERTED ROSTER
# ---------------------------------------------------------------------

DUM_RE = re.compile(r'^\s*dum\s+\S')


def has_real_dum_block(path):
    """True if `path` opens a genuine `dum <anchor>` block -- the
    directive, never a comment that merely mentions the word (asrom.s
    and as.s each have exactly one line matching the substring `dum `,
    and both are prose: `* macro-state DUM block...` /
    `* ... DUM block anchored at ...`). A Merlin comment starts with
    `*` in column 1 or `;` anywhere; DUM_RE anchors at the start of the
    line and requires `dum` to be the FIRST token, which a `*`-led
    comment line can never satisfy regardless of what word follows.
    """
    for line in open(path, errors='replace'):
        if DUM_RE.match(line):
            return True
    return False


def converted_roster():
    """Sorted bare names (no path, no `.s`) of every converted src/bin
    program -- a top-level manifest (check_manifests.toplevel_
    manifests(), never re-derived here) that opens a real `dum` block
    of its own. No hardcoded exclusion list: `expr.eval`/`sedexec`/
    `testeval` fall out because they are `put` TARGETS (not top-level);
    `asrom`/`expr` fall out because they have no real `dum` block.
    `as` used to fall out the same way (docs/STICKY.md sec 28) but is
    IN the roster as of stream T5's `dum LIBA_BSSEND`/`dend` block.
    """
    graph, put_targets = check_manifests.build_graph()
    toplevel = check_manifests.toplevel_manifests(graph, put_targets)
    out = []
    for path in toplevel:
        if os.path.dirname(path) != os.path.join(ROOT, 'src', 'bin'):
            continue
        if has_real_dum_block(path):
            out.append(os.path.splitext(os.path.basename(path))[0])
    return sorted(out)


def all_bin_toplevel():
    """Every top-level src/bin manifest name, converted or not -- for
    reporting how many fell out and why (asrom/expr: no dum; nothing
    else, unless a new program arrives with neither)."""
    graph, put_targets = check_manifests.build_graph()
    toplevel = check_manifests.toplevel_manifests(graph, put_targets)
    return sorted(os.path.splitext(os.path.basename(p))[0]
                  for p in toplevel
                  if os.path.dirname(p) == os.path.join(ROOT, 'src', 'bin'))


# ---------------------------------------------------------------------
# 2. WHICH GATES POISON, AND WHICH LAYER
# ---------------------------------------------------------------------

BSSEND_RE = re.compile(r'\b([A-Za-z][A-Za-z0-9]*)_BSSEND\b')
# THE DERIVED ROUTE (stream T2, added after check_tail.py/check_diff.py/
# check_nm.py/check_comm.py were converted to it and this detector's
# original BSSEND-only rule went stale within one merge -- docs/
# STICKY.md sec 41). Matches `arena_span('prog')` regardless of the
# qualifying prefix (`arena.arena_span(...)`, `arenamod.arena_span(...)`,
# unqualified) -- the CALL is the signal, not the import spelling.
ARENA_SPAN_CALL_RE = re.compile(r"arena_span\(\s*['\"]([a-z][a-z0-9]*)['\"]")
# Binds a specific arena_span() call to the variable name(s) that
# receive it, e.g. `diff_arena, diff_span = arenamod.arena_span('diff')`
# -> ('diff_arena', 'diff'). Used only for the PER-PROGRAM layer split
# on R_GO-style gates (see _rgo_layer_split below) -- comm.py's dict-
# literal `SH_PATH: arenamod.arena_span('sh')` binds no variable at all
# and is handled separately (_repeated_via_tuple).
ARENA_SPAN_ASSIGN_RE = re.compile(
    r"(\w+)(?:\s*,\s*\w+)?\s*=\s*arena(?:mod)?\.arena_span\(\s*"
    r"['\"]([a-z][a-z0-9]*)['\"]")
POISON_BYTE_RE = re.compile(r'^\s*POISON\s*=\s*0x[Aa]5\b', re.M)
LAYER2_GAPWAIT_RE = re.compile(r'\bR_GO_REQ\b|\bGAP_WAIT_PID\b')
LAYER2_TEXTAUDITOR_RE = re.compile(r'\bTextAuditor\b')
RGO_POLL_RE = re.compile(r'peek_aux1\(client,\s*R_GO_REQ\)')
PATH_CONST_RE = re.compile(
    r"^(\w+_PATH)\s*=\s*f'/(?:mnt/)?\{VOL\}/(?:BIN/)?(\w+)'", re.M)
REPEATED_TUPLE_RE = re.compile(r'\bREPEATED\s*=\s*\(([^)]*)\)')

# A poke that VERIFIES it landed reads the byte(s) straight back and
# compares against POISON -- this tree's one idiom for it, `!= POISON`
# (every one of the ten poisoning gates spells it this way; see
# scripts/check_ls.py's own pre-boot loop, fixed 2026-08-23 in the same
# stream as this file, for the gate that used to be the exception).
# One occurrence proves the loop verifies; a gate poisoning BOTH layers
# needs the idiom at BOTH poke sites to be counted as verifying both.
VERIFY_RE = re.compile(r'!=\s*POISON\b')


def gate_scripts():
    """Every scripts/check_*.py except this file itself."""
    return sorted(p for p in glob.glob(os.path.join(SCRIPTS, 'check_*.py'))
                  if os.path.basename(p) != 'check_poison.py')


def _path_to_program(text):
    """{'TEE_PATH': 'tee', ...} from a gate's own `NAME_PATH =
    f'/{VOL}/BIN/NAME'` constant lines -- the same string every device path
    in these gates is built from, read structurally rather than by
    reusing the gate's own device-path CONSTANT NAME as if it were the
    program name (it usually is, but deriving it from the f-string's
    own literal is one fewer assumption)."""
    return {const: prog.lower() for const, prog in PATH_CONST_RE.findall(text)}


def _repeated_via_tuple(text):
    """Program names named in an explicit `REPEATED = (X_PATH, ...)`
    tuple (check_comm.py's shape) -- the structural signal that a
    TextAuditor-style gate uses to say WHICH of the programs it
    registers for retire-time poisoning are actually proven by a repeat
    run, as opposed to merely pre-boot poisoned once. None found ->
    empty set, meaning "no such distinction is made in this file" (see
    _textauditor_layer_split's fallback).
    """
    m = REPEATED_TUPLE_RE.search(text)
    if not m:
        return set()
    path_map = _path_to_program(text)
    consts = re.findall(r'\b(\w+_PATH)\b', m.group(1))
    return {path_map[c] for c in consts if c in path_map}


def _rgo_layer_split(text, progs_here):
    """Per-program layer split for an R_GO/GAP_WAIT_PID gate (docs/
    STICKY.md sec 41's `diff`/`ed` finding): the between-run gap-
    servicing loop re-pokes a SPECIFIC arena variable by name, so a
    program whose `arena_span()`-bound variable never appears after the
    `R_GO_REQ` poll begins has no between-run proof in THIS gate, even
    though the gate as a whole has the mechanism (check_diff.py pokes
    `diff_arena` between runs and never `ed_arena` -- `ed` is spawned
    once, pre-boot poison is its whole proof, exactly as its own
    docstring says). Returns {program: bool} -- True if this specific
    program gets the between-run layer.
    """
    # A single-program gate (check_ls.py/check_du.py/check_find.py/
    # check_sed.py/check_tail.py, the LEGACY-route shape: one hand-
    # rolled local arena helper, no `arena_span()` call to bind a
    # variable name from at all) has nothing else that mechanism could
    # be poisoning between runs -- the gate-level "has R_GO" signal
    # already IS the per-program answer. The variable-tracking split
    # below only has evidence to offer once there are at least two
    # candidate programs sharing one `arena_span()`-based gate.
    if len(progs_here) <= 1:
        return {p: True for p in progs_here}
    m = RGO_POLL_RE.search(text)
    if not m:
        return {p: True for p in progs_here}
    pre, post = text[:m.start()], text[m.start():]
    var_for = {prog: var for var, prog in ARENA_SPAN_ASSIGN_RE.findall(pre)}
    out = {}
    for prog in progs_here:
        var = var_for.get(prog)
        out[prog] = bool(var and re.search(r'\b' + re.escape(var) + r'\b',
                                            post))
    return out


def _textauditor_layer_split(text, progs_here):
    """Per-program layer split for a TextAuditor/LZ_RETAIN gate (docs/
    STICKY.md sec 41's `comm`/{cat,wc} finding): the retire hook re-
    poisons whichever registered program's arena matches the process
    that just died, which -- read from the poke code alone -- would
    credit EVERY registered program with "both layers", `cat`/`wc`
    included, even though each is spawned once in check_comm.py's own
    fixture (its own docstring: "there is no between-run claim... for
    either"). An explicit `REPEATED = (...)` tuple is the structural
    signal for which registered programs are actually proven twice;
    with no such tuple in the file (check_nm.py has none), this falls
    back to crediting every registered program -- a known
    imprecision, stated rather than hidden, that does not risk a false
    POISON_DEBT shrink here because the only program check_nm.py could
    over-credit (`sh`) already has its own dedicated gate.
    """
    repeated = _repeated_via_tuple(text)
    if not repeated:
        return {p: True for p in progs_here}
    return {p: (p in repeated) for p in progs_here}


def discover_poisoning_gates(roster):
    """{program: [(gate_basename, layers, verified)]}, derived from
    every scripts/check_*.py's own source. `layers` is 'pre-boot' or
    'pre-boot+between-run', PER PROGRAM (a single gate can poison one
    program both ways and another pre-boot-only -- see
    _rgo_layer_split/_textauditor_layer_split); `verified` is whether
    the gate's own pokes read the byte back and check it against
    POISON (docs/STICKY.md's own distinction, deliverable 3 of this
    stream's original task: a gate that pokes $A5 and never checks it
    landed can silently poison nothing and no gate would notice --
    scripts/check_ls.py's pre-boot loop was exactly that until this
    same stream fixed it). See this file's module docstring for the
    two ROUTES a program can be named through (legacy `_BSSEND` label,
    or the derived `arena_span()` call) and why it excludes
    check_fork.py/check_ascore.py despite both poking 0xA5.
    """
    roster_lower = {p.lower(): p for p in roster}
    out = {}
    mechanism = {}
    for path in gate_scripts():
        text = open(path, errors='replace').read()
        if not POISON_BYTE_RE.search(text):
            continue
        progs_here = set()
        for m in BSSEND_RE.finditer(text):
            name = m.group(1).lower()
            if name == 'liba':
                continue  # liba's OWN boundary, not a program's arena
            if name in roster_lower:
                progs_here.add(roster_lower[name])
        for m in ARENA_SPAN_CALL_RE.finditer(text):
            name = m.group(1).lower()
            if name in roster_lower:
                progs_here.add(roster_lower[name])
        if not progs_here:
            continue
        gate = os.path.basename(path)
        has_gapwait = bool(LAYER2_GAPWAIT_RE.search(text))
        has_retain_stop = 'until_pc' in text and 'LZ_RETAIN' in text
        has_textauditor = bool(LAYER2_TEXTAUDITOR_RE.search(text)) and \
            'LZ_RETAIN' in text
        if has_gapwait:
            mech = 'R_GO/GAP_WAIT_PID'
            per_prog_both = _rgo_layer_split(text, progs_here)
        elif has_retain_stop:
            mech = 'until_pc(LZ_RETAIN)'
            per_prog_both = {p: True for p in progs_here}
        elif has_textauditor:
            mech = 'TextAuditor(LZ_RETAIN)'
            per_prog_both = _textauditor_layer_split(text, progs_here)
        else:
            mech = None
            per_prog_both = {p: False for p in progs_here}
        verified_both = len(VERIFY_RE.findall(text)) >= 2
        verified_one = len(VERIFY_RE.findall(text)) >= 1
        for prog in progs_here:
            both = per_prog_both.get(prog, False)
            layers = 'pre-boot+between-run' if both else 'pre-boot'
            verified = verified_both if both else verified_one
            out.setdefault(prog, []).append((gate, layers, verified))
            if mech and both:
                mechanism.setdefault(prog, set()).add(mech)
    return out, mechanism


# ---------------------------------------------------------------------
# 2b. THE FLEET-WIDE POISONER: a THIRD idiom neither route above can
# see, because it names no program literally at all.
# ---------------------------------------------------------------------

FLEET_POISON_GATE = 'check_textaudit.py'


def _no_arena_from_source(text):
    """check_textaudit.py's own `NO_ARENA = {...}` constant, read via
    `ast.literal_eval` on the matched assignment rather than importing
    -- used both as the live path's cross-check and the no-import
    fallback's only way to know `as`/`expr` have no arena to credit."""
    m = re.search(r'^NO_ARENA\s*=\s*(\{[^}]*\})', text, re.M)
    if not m:
        return set()
    try:
        return set(ast.literal_eval(m.group(1)))
    except (ValueError, SyntaxError):
        return set()


def _group_bins_from_source(text):
    """`GROUP_BINS` read by parsing THIS file's own AST and literal-
    evaluating the matched assignment -- no import, no regex over the
    dict's contents, for the declaration-only fallback path."""
    tree = ast.parse(text)
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == 'GROUP_BINS'
                for t in node.targets):
            try:
                return ast.literal_eval(node.value)
            except (ValueError, SyntaxError):
                return {}
    return {}


def discover_fleet_poisoners(roster):
    """A gate can poison a whole FLEET of programs through a loop over
    a DERIVED roster -- `check_textaudit.py`'s own `arenas[name] =
    arena_span(name)`, `name` a loop variable, not a literal string.
    Neither `BSSEND_RE` nor `ARENA_SPAN_CALL_RE` can see this: there is
    no label and no string-literal argument anywhere in the file. This
    is deliberately NOT a third regex -- docs/STICKY.md sec 41's own
    addendum says why a static pattern for "does this code do X" is
    itself an enumeration, and a THIRD one would just be the same
    defect with a different shape. Instead: ask the module what it
    declares.

    Tries importing `build_textaudit_image` (the module GROUP_BINS is
    actually DEFINED in, and the more minimal of the two importable
    options -- check_textaudit.py itself pulls in check_purity/
    textaudit/arena and a sibling repo's a2til package too). On success
    this also reads `repeat_pairs()`/`unpaired()` PER GROUP to tell a
    program that is genuinely repeated (real between-run proof) from
    one that is only ever spawned once (`ONCE()` entries -- `mkdir`/
    `rm`/`ps`/`date`/`df`/`chmod` today -- pre-boot poison only, and no
    output comparison of ANY kind beyond "did it exit": weaker even
    than a repeat pair's run1==run2).

    On import failure (a missing sibling dependency, a built-tree
    requirement this otherwise-static gate must not impose) falls back
    to reading `GROUP_BINS` off the SOURCE TEXT via `ast.literal_eval`
    -- still the object, not a guess -- and credits every program in
    it with `pre-boot` ONLY (the between-run distinction needs the live
    `repeat_pairs()`/`unpaired()` call, which cannot be recovered
    without importing). Every entry gained this way is tagged
    `declared_only=True` so the report says plainly that the credit
    came from a declaration, not a measurement.

    Returns ({program: [(gate, layers, verified)]}, {program: strength},
    declared_only) -- `strength` is 'weak-repeat' (a genuine repeat
    pair, no independent oracle -- `learning:01M0PG8GD5A83BFKWFV0TJCSPP`:
    such a gate is structurally blind to any bug a UNIFORM poison value
    makes deterministic, though it still catches a crash, a hang, or a
    vacuity violation) or 'weak-once' (single spawn, no comparison at
    all beyond vacuity). Callers combine this with discover_
    poisoning_gates()'s per-program layers to decide the OVERALL
    (stronger) verdict; this function never claims 'strong' itself --
    see run_all()'s own strength merge for why only a DEDICATED gate
    earns that label.
    """
    path = os.path.join(SCRIPTS, FLEET_POISON_GATE)
    if not os.path.exists(path):
        return {}, {}, False
    text = open(path, errors='replace').read()
    if not POISON_BYTE_RE.search(text):
        return {}, {}, False
    if not re.search(r'^\s*from arena import\b[^\n]*\barena_span\b',
                      text, re.M):
        return {}, {}, False

    roster_lower = {p.lower(): p for p in roster}
    declared_only = False
    repeat_progs = set()
    once_progs = set()
    try:
        import build_textaudit_image as bti
        group_bins = bti.GROUP_BINS
        for group in group_bins:
            repeat_progs |= {p for p, _a, _b in bti.repeat_pairs(group)}
            once_progs |= set(bti.unpaired(group))
    except Exception:
        declared_only = True
        group_bins = _group_bins_from_source(text)

    no_arena = _no_arena_from_source(text)
    all_names = {n for names in group_bins.values() for n in names}
    poisoned_names = {n for n in all_names if n not in no_arena}

    verified = len(VERIFY_RE.findall(text)) >= 2  # both layers verified
                                                   # (preboot_poison's
                                                   # own read-back plus
                                                   # PoisonAuditor's)
    out = {}
    strength = {}
    for name in poisoned_names:
        if name.lower() not in roster_lower:
            continue
        prog = roster_lower[name.lower()]
        if not declared_only and prog in repeat_progs:
            layers = 'pre-boot+between-run'
            strength[prog] = 'weak-repeat'
        elif not declared_only and prog in once_progs:
            layers = 'pre-boot'
            strength[prog] = 'weak-once'
        else:
            # declared_only, or a name in GROUP_BINS that is neither
            # repeated nor explicitly marked ONCE -- treat as
            # unmeasured between-run status, credit pre-boot only.
            layers = 'pre-boot'
            strength[prog] = 'weak-once' if declared_only else 'weak-repeat'
        out.setdefault(prog, []).append(
            (FLEET_POISON_GATE, layers, verified))
    return out, strength, declared_only


def boot_check_poisoners(poisoners):
    """For every (program, gate) pair discovered above, confirm the
    gate's own image builder (scripts/build_<suffix>_image.py, `suffix`
    = the gate's check_<suffix>.py name) actually stages the program's
    `.bin` -- via the same ast-literal walk boot_map() uses, restricted
    to the one builder in question. This is the part of item 3 that IS
    load-bearing: a gate that merely MENTIONS `<P>_BSSEND` in a comment
    without ever booting P would otherwise pass the roster check
    vacuously. Returns a list of failure strings (empty == every
    poisoning claim is backed by a real boot).
    """
    failures = []
    for prog, entries in sorted(poisoners.items()):
        for gate, _layers, _verified in entries:
            suffix = gate[len('check_'):-len('.py')]
            builder = os.path.join(SCRIPTS, f'build_{suffix}_image.py')
            if not os.path.exists(builder):
                failures.append(
                    f'{gate} claims to poison {prog!r} ({prog.upper()}_'
                    f'BSSEND + POISON=0xA5) but scripts/build_{suffix}_'
                    f'image.py does not exist -- cannot confirm it '
                    f'boots {prog}.bin at all. Vacuity guard tripped.')
                continue
            staged = programs_staged(builder)
            if prog not in staged:
                failures.append(
                    f'{gate} claims to poison {prog!r} but its own '
                    f'image builder (build_{suffix}_image.py) does not '
                    f'appear to stage {prog}.bin anywhere in its string '
                    f'literals -- the poison span may be computed for a '
                    f'program that is never actually spawned. Vacuity '
                    f'guard tripped (learning:01M0M9R7RT22JEPP2R0Y6J9MBX\'s '
                    f'own vacuity-guard rule, applied to the gate rather '
                    f'than to the machine).')
    return failures


# ---------------------------------------------------------------------
# 3. WHICH GATE BOOTS WHICH PROGRAM (advisory -- see module docstring)
# ---------------------------------------------------------------------

BIN_PATH_RE = re.compile(r"(?:^|/)([A-Za-z][A-Za-z0-9_]*)\.bin\b")


def _string_literals(path):
    try:
        tree = ast.parse(open(path, errors='replace').read(), filename=path)
    except SyntaxError:
        return []
    out = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            out.append(node.value)
    return out


def programs_staged(builder_path, universe=None):
    """Best-effort set of program names a build_*_image.py stages,
    derived from its own string literals -- never from the gate's
    name. Two signals, both over EVERY string constant in the file
    (ast, not a per-format regex): a `NAME.bin` path component, or a
    bare token that IS a program name outright (catches
    build_v1_system_image.py's `('ls', os.path.join(...))` tuples and
    build_textaudit_image.py's `GROUP_BINS` dict of bare names alike,
    without writing a parser for either shape specifically).
    """
    if universe is None:
        universe = set(all_bin_toplevel())
    found = set()
    for s in _string_literals(builder_path):
        for m in BIN_PATH_RE.finditer(s):
            name = m.group(1).lower()
            if name in universe:
                found.add(name)
        tok = s.strip().lower()
        if tok in universe and len(tok) <= 12:
            found.add(tok)
    # THE DERIVED ROSTER (2026-09-03, first hit by check_play.py's vi
    # poison): build_play_image.py names no program literally -- its
    # UTIL_NAMES is expanded from the Makefile's own UTILS variable
    # minus PLAY_EXCLUDE, exactly so that a program added to UTILS
    # cannot be silently missing from the play image. A literal walk
    # sees nothing there. So a builder that publishes UTIL_NAMES at
    # import (main() guarded) is asked for it directly; anything else
    # keeps the literal walk alone.
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            '_poison_builder_' + os.path.basename(builder_path)[:-3],
            builder_path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        for name in getattr(mod, 'UTIL_NAMES', []):
            tok = str(name).strip().lower()
            if tok in universe:
                found.add(tok)
    except Exception:
        pass  # a builder that cannot be imported is judged by literals
    return found


def boot_map():
    """{gate_check_script: sorted[program, ...]}, ADVISORY (see module
    docstring item 3) -- every scripts/build_*_image.py's derived
    staged-programs set, keyed by its check_*.py counterpart when one
    exists (build_X_image.py <-> check_X.py, the tree's own naming
    convention -- verified rather than assumed by check_manifests.py's
    Makefile-closure gate elsewhere).
    """
    universe = set(all_bin_toplevel())
    out = {}
    for builder in sorted(glob.glob(os.path.join(SCRIPTS,
                                                  'build_*_image.py'))):
        suffix = os.path.basename(builder)[len('build_'):-len('_image.py')]
        gate = f'check_{suffix}.py'
        staged = programs_staged(builder, universe)
        if staged:
            out[gate] = sorted(staged)
    return out


# Hand-mapped facts a scout produced walking the same builders by eye
# (this file's task brief). Used ONLY to validate the derivation above
# against an independent source, per this file's own module docstring
# rule that item 3 is advisory -- never treated as ground truth to
# encode into pass/fail. A mismatch is printed, not silently resolved.
BOOT_MAP_SCOUT_FACTS = {
    'check_textaudit.py': {'count': 34},
    'check_v1_system.py': {'count': 13},
    'check_comm.py': {'only': ['tee']},
    'check_ld.py': {'only': ['ld']},
    'check_nm.py': {'only': ['nm']},
    'check_tail.py': {'only': ['tail']},
}


def validate_boot_map(bmap):
    """Compare boot_map()'s derivation against BOOT_MAP_SCOUT_FACTS.
    Returns a list of human-readable notes (never failures -- item 3
    is advisory, docstring item 3). 'only' facts are checked against
    every OTHER non-fleet-wide gate (excluding the two blanket sweeps
    check_textaudit.py/check_v1_system.py, which the scout's own
    findings already carve out by naming them separately)."""
    notes = []
    for gate, facts in BOOT_MAP_SCOUT_FACTS.items():
        derived = set(bmap.get(gate, []))
        if 'count' in facts:
            if len(derived) != facts['count']:
                notes.append(
                    f'{gate}: scout says {facts["count"]} programs, '
                    f'derived {len(derived)}: {sorted(derived)}')
        if 'only' in facts:
            for prog in facts['only']:
                elsewhere = [g for g, progs in bmap.items()
                             if prog in progs and g != gate
                             and g not in ('check_textaudit.py',
                                           'check_v1_system.py')]
                if elsewhere:
                    notes.append(
                        f'{prog!r}: scout says {gate} only, derived also '
                        f'in {elsewhere}')
    return notes


# ---------------------------------------------------------------------
# 4. THE SHRINK-ONLY DEBT SET
# ---------------------------------------------------------------------

# Every converted program with NO poisoning gate, pinned at TODAY's
# measured state -- the same ratchet shape as check_purity.BIN_DEBT/
# LIBA_DEBT and check_dialect.OUT_OF_SCOPE_LINE_DEBT
# (check_dialect.py:109): membership may only SHRINK, and a STALE
# entry (a name that already has a poisoning gate, or that is no
# longer a converted program at all) fails the gate too, exactly as a
# too-generous LIBA_DEBT entry does.
#
# EMPTY as of 2026-08-23 (docs/STICKY.md sec 41's addendum): once
# check_poison.py could see check_textaudit.py's OWN poisoning (a
# fleet-wide loop over a DERIVED roster, `arenas[name] =
# arena_span(name)` -- invisible to both the legacy `_BSSEND`-label
# route and the literal-`arena_span('prog')`-argument route this file
# already recognised, because it names no program literally at all;
# see discover_fleet_poisoners()), the remaining 19 entries all turned
# out to be covered -- WEAKLY (learning:01M0PG8GD5A83BFKWFV0TJCSPP: a
# repeat pair with no independent oracle, or -- `chmod`/`date`/`df`/
# `mkdir`/`ps`/`rm` -- a single spawn with no output comparison at
# all), not strongly, but covered. `check-poison`'s own STRENGTH
# column (run_all()) is what keeps that distinction visible now that
# this set can no longer carry it. Kept declared and empty for the
# same reason LIBA_DEBT is: a new converted program that gains no
# poisoning gate at all -- fleet-wide or dedicated -- must fail here
# again, not silently pass because the set looked empty by default.
# `mld` is the Merlin bridge -- maux's wrapper around Merlin's own
# LINKER.S, which it embeds. It was `ld` until the native linker
# replaced it, and it kept ld's name in check-textaudit's group c
# only because it WAS ld; group c now audits the native `ld`, which
# is the linker anyone runs.
#
# mld stays buildable and gated for byte-identity (check-ld with
# LD_UNDER_TEST=mld) but is no longer text-audited, so it has no
# poisoning gate. That is the honest state: it is a superseded
# implementation kept for comparison, not a program in the userland.
#
# The `nld` entry that used to sit here is GONE, as it said it must
# be: the native linker is `ld` now and has ld's group-c audit.
# `chvt` was briefly listed here on the grounds that it has no bss
# arena to poison. That was wrong twice over: this gate refused the
# entry the moment chvt joined check-textaudit's group a, because a
# program with a poisoning gate does not belong in the DEBT set --
# and the audit is worth having regardless, since what it actually
# proves is that a repeat run into the same warm bank is byte-
# identical, which is a statement about the program, not about
# whether it happens to own any bss.
# `kill` (2026-09-01): five dum-arena bytes, every one written
# before any read on every path (START stores ERRFLAG/ARGIDX/NPIDS
# before the first branch; PIDVAL/OPSAVE are stored before use in
# their own routines). Debt rather than gate ON ARRIVAL; the named
# trigger is joining a check-textaudit group, where the repeat-pair
# audit subsumes this.
# `more` (2026-09-01): same on-arrival shape and trigger as kill --
# AND the debt bit immediately: the first draft read QUITFLAG
# before writing it and paged nothing (arena garbage read as
# 'quit'). The claim 'every cell written before read' is exactly
# what a poisoning gate proves and a comment cannot; this entry
# upgrades to a gate at the first textaudit opportunity.
# kill/more/touch (2026-09-01): parked here on arrival, REMOVED the
# same day -- check-textaudit's group d poisons all three now (and
# more's QUITFLAG bug bit while its entry still claimed every cell
# was written first: the debt entry's own comment was wrong within
# hours, which is exactly why the ratchet insists on real gates).
#
# `ex` RESOLVED 2026-09-02: folded into check-textaudit GROUP_BINS
# group 'd' with a PAIRX('ex', ...) poison-paired audit mirroring
# `ed`'s (build_textaudit_image.py), which poisons ex's REGEX_BSSEND-
# anchored `dum` arena pre-boot and between the two runs and verifies
# the swap-file-backed session repeats byte-identically. ex passed on
# arrival (no ex-under-poison bug), so the shrink-only ratchet drops
# its debt entry here.
#
# `stty` PARKED 2026-09-02 (stty seed): a tiny one-shot tty-mode setter
# (1819B) with a derivable `dum` arena but no poison gate yet. It sets
# cbreak/-echo and exits; its arena carries no state read across runs,
# so it is low-risk to defer. A real gate is cheap when wanted -- two
# `stty` (report) runs are byte-identical, so a check-textaudit PAIRX
# mirroring ed/ex would pair it. Parked, not gated, for now.
# `reset` PARKED 2026-09-07 (terminal reinitialise): stty's sibling and
# even lower-risk -- it owns NO bss cell at all (the `dum` arena past
# LIBA_BSSEND exists only for the arena-end tripwire, emits nothing and
# is never read/written), so there is no cross-run state a poisoner
# could catch. It sets cooked+echo, writes ESC c, exits. Same trigger
# as stty: a check-textaudit PAIRX pairs it the day it wants a real
# gate. Parked, not gated, for now.
# `true`/`false` PARKED 2026-09-07 (POSIX no-ops): 123 bytes each,
# `lda #0/1 ; jsr SC_EXIT`. Like reset they own NO bss cell at all --
# the `dum` arena past LIBA_BSSEND exists only for the tripwire and is
# never read/written -- so there is no cross-run state a poisoner could
# catch. No check-textaudit pair yet; parked, not gated.
# `tip` PARKED 2026-09-11 (task #22, docs/SERIAL.md sec 3): its own
# gate is check-tip (make check-tip, scripts/check_tip.py), a full
# person-like e2e run of the ONE binary the play image ships -- not a
# repeat-pair (tip forks and blocks on two devices at once, ending
# only by `~.`, so it is not a plain "spawn twice, diff" fit for
# check-textaudit's PAIRX/group harness the way ed/ex/sed are). check-
# tip does not re-spawn tip a second time to prove write-before-read
# on its own warm bank, so it is not a poisoning gate by this file's
# definition; parked here rather than claimed. A PAIRX pair (two tip
# sessions back to back, poisoned between) is the natural upgrade if
# this is ever wanted for real.
POISON_DEBT = {
    # plasma (2026-09-08, TASKS.md #20): the native PLASMA VM seed.
    # Unlike every other converted util it is LIBA-FREE (raw JSR $FF00),
    # so it has no LIBA_ZPG/LIBA_BSSEND arena for the textaudit poison
    # mechanism to derive -- it cannot join a poison group. It is
    # text-immutable BY CONSTRUCTION anyway (INITPARMS stores all six
    # parmlists into its dum arena as START's first act, the def thunk
    # is built in bss, the ZP inner loop is copied fresh from read-only
    # text each run), and check-plasma spawns it. The debt is a
    # dedicated poisoning leg once arena_span learns liba-free layouts;
    # M2's gate will also spawn it twice.
    'plasma',
    'mld', 'stty',
    # proshim + proshimcr (2026-09-07, TASKS.md #19): the host verb and
    # its embedded MLI core. proshim's dum arena is used only DURING
    # load, then the tenant takes the whole bank -- there is no steady
    # state to poison and survive; check-proshim runs it twice and
    # byte-asserts the tenant, which is the reuse proof. proshimcr is a
    # putbin'd blob (not spawnable) whose  dum scratch is
    # write-before-read per call, audited with its parent.
    'proshim', 'proshimcr',
    # reset/true/false/tip (posix-sed line): see the paragraphs
    # above -- no bss cell (reset/true/false) or a one-shot
    # fork-and-block gate (tip), so no repeat-pair yet.
    'reset', 'true', 'false', 'tip',
    # shutdown (2026-09-21): same shape as reset/true/false -- it owns
    # NO bss cell of its own (its `dum` block is the shared liba arena
    # trailer and the arena-end tripwire, nothing more), so there is no
    # cell for a poison to occupy and no repeat-pair to measure. It is
    # also the one program that cannot be measured across a WARM
    # respawn of a successful run: SYS_HALT does not return, so a second
    # run of the same bank cannot happen after a real `shutdown`. Only
    # the refused-operand path exits normally, and that path writes
    # nothing but a message.
    'shutdown',
    # bye (bye slice 1, 2026-09-25): same "no bss cell of its own"
    # shape as reset/true/false/shutdown -- its `dum` block is the
    # shared liba arena trailer and the arena-end tripwire only, and
    # LEAVEMSG/BACKMSG/USAGEMSG are fixed read-only literals, never
    # patched. UNLIKE shutdown, SC_BYE always returns, so a WARM
    # repeat-pair is possible in principle -- just not yet wired
    # into build_textaudit_image.py. Debt is "not yet staged", not
    # "cannot be measured".
    'bye',
}


def run_all():
    failures = []

    roster = converted_roster()
    everything = all_bin_toplevel()
    unconverted = sorted(set(everything) - set(roster))

    print()
    print('[check-poison] converted roster (top-level src/bin manifest '
          'with a real `dum` block, derived via check_manifests.py)')
    print(f'   {len(roster)} converted: {" ".join(roster)}')
    print(f'   {len(unconverted)} top-level, NOT converted (no `dum` '
          f'block): {" ".join(unconverted) or "--"}')

    poisoners, mechanism = discover_poisoning_gates(roster)

    # THE THIRD IDIOM: a fleet-wide poisoner naming its programs
    # through a loop over a derived roster, invisible to both routes
    # above (docs/STICKY.md sec 41's own addendum -- the detector's own
    # pattern for "does this poison" is itself an enumeration). Merged
    # in rather than folded into discover_poisoning_gates() because it
    # is answered by asking a MODULE what it declares, not by scanning
    # text for a third pattern.
    fleet_poisoners, fleet_strength, fleet_declared_only = \
        discover_fleet_poisoners(roster)
    for prog, entries in fleet_poisoners.items():
        poisoners.setdefault(prog, []).extend(entries)

    poisoned = sorted(poisoners)
    unpoisoned = sorted(set(roster) - set(poisoned))

    print()
    print("[check-poison] which gates poison which program (derived: a "
          "`<PROG>_BSSEND` symbol, an `arena_span('prog')` literal call, "
          "or -- for a fleet-wide poisoner naming no program literally at "
          "all -- the module's own declared roster, each gated on "
          "`POISON = 0xA5` in the same file)")
    if fleet_declared_only:
        print(f"   NOTE: {FLEET_POISON_GATE}'s roster below is credited "
              f"from its own DECLARED GROUP_BINS (import unavailable in "
              f"this environment) -- a declaration, not a measurement; "
              f"its between-run layer is withheld pending a live import.")
    for prog in poisoned:
        entries = poisoners[prog]
        # A program can be poisoned by more than one gate (`cat` via
        # check_catread.py AND check_comm.py; `sh` via check_shwarm.py,
        # check_nm.py and check_comm.py) -- report the BEST layer any
        # one of them proves, not arbitrarily the first gate found.
        best_layers = 'pre-boot+between-run' if any(
            l == 'pre-boot+between-run' for _g, l, _v in entries) \
            else 'pre-boot'
        gates = ', '.join(g for g, _l, _v in entries)
        verified = any(v for _g, l, v in entries if l == best_layers)
        mech = ', '.join(sorted(mechanism.get(prog, ()))) or '--'
        # STRENGTH (learning:01M0PG8GD5A83BFKWFV0TJCSPP): a program with
        # a DEDICATED gate (anything but the fleet-wide poisoner) has an
        # independent expected-bytes oracle -- 'strong'. A program ONLY
        # reached by the fleet-wide poisoner is 'weak-repeat' (a repeat
        # pair with no independent oracle -- structurally blind to any
        # bug a uniform poison value makes deterministic; still catches
        # a crash, a hang, or a vacuity violation) or 'weak-once' (a
        # single spawn, no output comparison of any kind).
        dedicated = [g for g, _l, _v in entries if g != FLEET_POISON_GATE]
        strength = 'strong' if dedicated else fleet_strength.get(
            prog, 'weak-repeat')
        print(f'   {prog:<6} {best_layers:<24} {strength:<12} '
              f'{"verified" if verified else "POKES BUT DOES NOT VERIFY"} '
              f'via {gates}  (between-run mechanism: {mech})')
    print(f'   {len(poisoned)} of {len(roster)} converted programs have a '
          f'poisoning gate; {len(unpoisoned)} do not: '
          f'{" ".join(unpoisoned) or "--"}')
    strong_n = sum(1 for p in poisoned if any(
        g != FLEET_POISON_GATE for g, _l, _v in poisoners[p]))
    print(f"   of those, {strong_n} have an independent-oracle (strong) "
          f"gate; {len(poisoned) - strong_n} are proven only by "
          f"{FLEET_POISON_GATE}'s repeat-pair/vacuity checks (weak -- "
          f"learning:01M0PG8GD5A83BFKWFV0TJCSPP)")

    failures += boot_check_poisoners(poisoners)

    print()
    print('[check-poison] boot map (advisory -- scripts/build_*_image.py, '
          'validated against a hand-mapped scout roster, never treated '
          'as ground truth)')
    bmap = boot_map()
    for note in validate_boot_map(bmap):
        print(f'   VALIDATION NOTE: {note}')

    print()
    print('[check-poison] the shrink-only POISON_DEBT ratchet')
    stale_poisoned = sorted(set(POISON_DEBT) & set(poisoned))
    for name in stale_poisoned:
        failures.append(
            f'{name!r} is in POISON_DEBT but has a poisoning gate now '
            f'({", ".join(g for g, _l, _v in poisoners[name])}) -- remove '
            f'the stale entry so the ratchet stays honest.')
    stale_unroster = sorted(set(POISON_DEBT) - set(roster))
    for name in stale_unroster:
        failures.append(
            f'{name!r} is in POISON_DEBT but is not a converted program '
            f'any more (or never was) -- remove the stale entry.')
    new_debt = sorted(set(unpoisoned) - set(POISON_DEBT))
    for name in new_debt:
        failures.append(
            f'{name!r} is a converted program with NO poisoning gate, '
            f'and is NOT in POISON_DEBT -- either give it a poisoning '
            f'gate (docs/STICKY.md sec 25/28/37\'s pattern, using '
            f'scripts/arena.py\'s arena_span()) or add it to '
            f'check_poison.POISON_DEBT with a reason.')
    print(f'   POISON_DEBT: {len(POISON_DEBT)} entries, '
          f'{len(stale_poisoned)} stale-poisoned, '
          f'{len(stale_unroster)} stale-unrostered, '
          f'{len(new_debt)} undeclared')
    if not (stale_poisoned or stale_unroster or new_debt):
        print('   exact match: POISON_DEBT == converted roster - poisoned')

    return failures


def main():
    failures = run_all()
    print()
    for f in failures:
        print(f'[check-poison] FAIL: {f}', file=sys.stderr)
    if failures:
        return 1
    print('[check-poison] PASS')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
