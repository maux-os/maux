#!/usr/bin/env python3
"""check_manifests.py -- cross-check the tree's "which files are involved"
lists against ground truth DERIVED from source (`make check-modules`,
folded in the same way scripts/check_equ_fwd.py is -- see that module's
precedent and check_modules.py's check_equ_forward_refs()).

WHY THIS EXISTS. This tree keeps at least five independent lists of "which
files make up this image/object/embedded-chain": docs/AS-P10-ENUMERATION.txt's
prose file list, scripts/build_ascore_image.py's PRIMARY + PUT_INCLUDED,
scripts/build_maux_src_image.py's MODULES, the Makefile's KERNEL_PROC_MODS,
and every top-level manifest's own `put` chain. Nothing cross-checks them,
and each one fails SILENTLY when wrong -- a missing `put` line means a
module just isn't assembled in, a missing staged file means patches land on
nothing, a stale doc claim means a sweep misses real sites. Four real
instances hit in one day (2026-08-19/20):

  (a) docs/AS-P10-ENUMERATION.txt asserted LINKER.S was not embedded; it
      is (MACASS.S:237-241 PUTs it), so 9 switch sites went unswept.
  (b) build_ascore_image.py's PUT_INCLUDED omitted LINKER.S, so 7 patch
      entries were applied to nothing -- silently inert, 29/36.
  (c) build_maux_src_image.py's MODULES omitted six new include files, so
      real Merlin could not see them and check-dual failed.
  (d) Kernel modules gained `put inc/*.equ` while being themselves PUT
      by every harness -- neither assembler nests PUT, so symbols went
      undefined.

THE RULE: every list here must be checkable against ground truth DERIVED
from the source tree (a file's own `put`/`use` lines, patches.py's own
patch table, MACASS.S's own PUT/USE chain) -- never accepted on report.

SCOPE OF "manifest": a top-level manifest is a source file the Makefile
hands directly to merlin32 (derive_makefile_units(), derived from the
Makefile's own $(MERLIN32) recipes -- NOT a src/test/|src/bin/ directory
glob, which is exactly the hand-enumeration class this file exists to
catch, and which itself missed src/bootblock.s/src/check.memmap.s until
2026-08-23) that is not itself the `put`/`use` TARGET of any other file
in the tree. Its transitive `put`/`use` chain is the true file set for
the image it builds.
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---------------------------------------------------------------------------
# maux-dialect put/use scanning (real newlines, low ASCII). Mirrors
# check_modules.py's scan() field-splitting rule exactly: a line starting
# with whitespace is a bare directive (opcode in field 1); a line starting
# with a non-whitespace character has a LABEL in field 1 and the opcode in
# field 2. Comments start with `;` anywhere, or `*` in column 1.
# ---------------------------------------------------------------------------
DIRECTIVES = ('put', 'use')

# `putbin` is a THIRD, DISTINCT edge kind (merlin32-only -- real Merlin-8
# has no putbin at all, see scripts/stage_putbin.py's header): it embeds a
# binary blob verbatim, not a source file to be assembled. scan_put_use
# recognizes it (BLOB_DIRECTIVES) so build_graph() can record the edge --
# every consumer of `graph` below must still treat it as opaque: it is
# NEVER added to `put_targets` (toplevel_manifests() filters on that set,
# and a putbin target is a build artifact, not a source file) and
# closure() never traverses it (build_maux_src_image.py stages closure()'s
# result as TEXT source; a putbin target is a binary .obj/.bin blob, not
# something to stage as high-bit ASCII).
BLOB_DIRECTIVES = ('putbin',)
SCAN_DIRECTIVES = DIRECTIVES + BLOB_DIRECTIVES


def scan_put_use(path):
    """[(directive, target_token, lineno)] for one maux source file --
    put/use edges AND putbin edges (see BLOB_DIRECTIVES above); callers
    that must not see putbin filter on directive themselves."""
    out = []
    for lineno, raw in enumerate(open(path, errors='replace'), 1):
        if not raw.strip() or raw.lstrip().startswith('*'):
            continue
        line = raw.split(';')[0].rstrip('\n')
        if not line.strip():
            continue
        parts = line.split()
        start = 1 if line[:1] in (' ', '\t') else 2
        if len(parts) >= start and parts[start - 1].lower() in SCAN_DIRECTIVES:
            if len(parts) > start:
                out.append((parts[start - 1].lower(), parts[start], lineno))
    return out


def resolve(including_file, target):
    """put/use targets resolve relative to the INCLUDING file's own
    directory (verified: src/test/*.s use `../kernel/x.s` and
    `../../inc/x.equ`, both directory-relative to src/test/, not
    ROOT-relative; build_maux_src_image.py's rewrite() makes the same
    assumption)."""
    return os.path.normpath(os.path.join(os.path.dirname(including_file),
                                          target))


def universe():
    """Every maux source file that could plausibly contain a put/use
    line -- src/**/*.s, src/**/*.equ, inc/*.equ."""
    pats = ['src/**/*.s', 'src/**/*.equ', 'inc/*.equ']
    out = set()
    for pat in pats:
        out |= set(os.path.normpath(p)
                   for p in glob.glob(os.path.join(ROOT, pat), recursive=True))
    return out


def build_graph():
    """path -> [(directive, resolved_target, lineno)] over the whole tree
    -- put/use edges AND putbin edges (resolved the same directory-
    relative way) -- plus the set of every path that is a put/use TARGET
    somewhere. putbin targets (build/*.obj, build/*.bin blobs -- never
    source) are NEVER added to put_targets: they are a third, distinct
    edge kind, present in `graph` so downstream tooling CAN see them, but
    every existing consumer that keys off put_targets or walks closure()
    must keep ignoring them (see BLOB_DIRECTIVES above and closure()
    below)."""
    graph = {}
    put_targets = set()
    for path in sorted(universe()):
        edges = []
        for directive, tok, lineno in scan_put_use(path):
            tgt = resolve(path, tok)
            edges.append((directive, tgt, lineno))
            if directive in DIRECTIVES:
                put_targets.add(tgt)
        graph[path] = edges
    return graph, put_targets


def closure(graph, start):
    """Transitive file set reachable from `start` via put/use, start
    included. putbin edges are NEVER traversed -- their targets are
    binary blobs (build/*.obj, build/*.bin), not source files, and
    build_maux_src_image.py stages closure()'s result as high-bit ASCII
    text; pulling a blob in here would try to stage it as source."""
    seen = set()
    stack = [os.path.normpath(start)]
    while stack:
        f = stack.pop()
        if f in seen:
            continue
        seen.add(f)
        for directive, tgt, _lineno in graph.get(f, ()):
            if directive not in DIRECTIVES:
                continue
            if tgt not in seen:
                stack.append(tgt)
    return seen


# ---------------------------------------------------------------------------
# Deriving top-level compilation units from the Makefile's own assemble
# recipes, rather than a directory glob. `src/test/*.s` + `src/bin/*.s`
# hand-enumerated two of maux's six src/ subtrees and silently missed
# src/bootblock.s and src/check.memmap.s -- both real compilation units
# the Makefile hands to merlin32 directly, one of which SHIPS IN THE
# IMAGE (docs/PLAN.md: "check-modules claims tree-wide coverage it does
# not have"). check_dialect.py used to patch around the gap with a
# second hand-written list (EXTRA_UNITS) instead of fixing this
# derivation -- that list is gone; this is the fix.
#
# Every line that hands a source file to merlin32 in this Makefile has
# one of three shapes (verified by grep over the whole Makefile,
# 2026-08-23 -- no other invocation form exists):
#   \t$(MERLIN32) [-v1] PATH               -- direct path, vars expanded
#   \tcd DIR && $(MERLIN32) [-v1] PATH     -- PATH resolves under DIR
#   \t$(MERLIN32) $(BINSRC)/$*.s           -- the userland pattern rule;
#                                              $* is Make's automatic
#                                              stem, standing for every
#                                              file $(BINSRC)/*.s matches
# ---------------------------------------------------------------------------
MERLIN_RECIPE_RE = re.compile(
    r'^\t(?:cd\s+(?P<cd>\S+)\s*&&\s*)?'
    r'\$\(MERLIN32\)\s+(?:-v1\s+)?(?P<path>\S+)\s*$', re.MULTILINE)


def derive_makefile_units(raw_vars=None, text=None):
    """Every source file the Makefile hands directly to merlin32 -- ground
    truth for "what does the build actually assemble", derived from the
    Makefile text itself rather than a hand-enumerated directory glob.
    Restricted to paths under src/: a generated, non-committed build
    product reached this way (build/asbigmod.s -- scripts/gen_asbigmod.py
    generates it fresh) is not a tree source file and carries no
    line/label ratchet of its own."""
    if text is None:
        text = open(os.path.join(ROOT, 'Makefile'), errors='replace').read()
    if raw_vars is None:
        raw_vars = parse_makefile_vars(text)
    units = set()
    for m in MERLIN_RECIPE_RE.finditer(text):
        cd_tok, path_tok = m.group('cd'), m.group('path')
        cd_dir = expand_with_funcs(raw_vars, cd_tok) if cd_tok else ''
        path_s = expand_with_funcs(raw_vars, path_tok)
        base = os.path.join(ROOT, cd_dir) if cd_dir else ROOT
        if '$*' in path_s:
            # The userland pattern rule: $* ranges over every file the
            # rule's own prerequisite pattern matches today.
            for p in glob.glob(os.path.join(base, path_s.replace('$*', '*'))):
                units.add(os.path.normpath(p))
        else:
            units.add(os.path.normpath(os.path.join(base, path_s)))
    src_root = os.path.join(ROOT, 'src') + os.sep
    return {u for u in units if u.startswith(src_root)}


def toplevel_manifests(graph, put_targets):
    """Every source file the Makefile assembles directly (derive_makefile_
    units) that is not ITSELF the put/use target of some other file in the
    tree -- the true top-level image sources. Membership is over-inclusive
    on purpose (e.g. every src/bin/*.s the userland pattern rule could
    assemble, whether or not anything actually requests that .bin) and
    the put_targets exclusion below is what narrows it -- exactly the
    same shape the old directory glob relied on."""
    cands = sorted(derive_makefile_units())
    return [c for c in cands if c not in put_targets]


def rel(path):
    return os.path.relpath(path, ROOT)


# ---------------------------------------------------------------------------
# CHECK 1 -- no nested PUT. A hard dialect rule for both assemblers
# (neither merlin32 nor real Merlin-8 nests PUT): no file that is itself
# brought in by a put/use may itself contain a put/use line. Global, not
# per-manifest -- instance (d)'s bug was a property of the FILE, not of any
# one image.
# ---------------------------------------------------------------------------
def check_no_nested_put(graph, put_targets):
    failures = []
    for target in sorted(put_targets):
        # put_targets never names a putbin target (build_graph() excludes
        # them), but filter `edges` to DIRECTIVES anyway: a putbin line
        # embeds a blob, it does not nest an include, so it is not this
        # check's business even if some future file both gets put/used
        # AND carries its own putbin line.
        edges = [e for e in graph.get(target, []) if e[0] in DIRECTIVES]
        if edges:
            includers = sorted(
                rel(p) for p, es in graph.items()
                if any(t == target for _d, t, _l in es))
            for directive, tgt, lineno in edges:
                failures.append(
                    f'{rel(target)}:{lineno}: contains `{directive} '
                    f'{rel(tgt)}\' but {rel(target)} is itself put/used by '
                    f'{", ".join(includers)} -- neither merlin32 nor real '
                    f'Merlin-8 nests PUT/USE, so this cannot assemble under '
                    f'either.')
    return failures


# ---------------------------------------------------------------------------
# CHECK 2 -- Makefile KERNEL_PROC_MODS coverage. Any dependency-list Make
# variable that mentions a process-bearing manifest (one whose put/use
# chain reaches src/kernel/process.s) must, via KERNEL_PROC_MODS and/or its
# own direct src/kernel/*.s tokens, cover every kernel module that
# manifest's chain actually reaches -- a miss means a stale rebuild (the
# Makefile's own KERNEL_PROC_MODS comment records this exact historical
# shape).
# ---------------------------------------------------------------------------
ASSIGN_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*(:=|\+=|=)\s*(.*)$')
VARREF_RE = re.compile(r'\$\(([A-Za-z_][A-Za-z0-9_]*)\)')


def parse_makefile_vars(text):
    """name -> raw (unexpanded) value STRING, handling `\\`-continuation.
    Recipe lines (tab-indented) are skipped -- assignments are only ever
    at column 0 in this Makefile."""
    lines = text.split('\n')
    raw = {}
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith('\t'):
            i += 1
            continue
        m = ASSIGN_RE.match(line)
        if not m:
            i += 1
            continue
        name, op, rest = m.groups()
        pieces = []
        cur = rest
        while cur.rstrip().endswith('\\'):
            pieces.append(cur.rstrip()[:-1])
            i += 1
            cur = lines[i] if i < len(lines) else ''
        pieces.append(cur)
        value = ' '.join(pieces)
        if op == '+=' and name in raw:
            raw[name] = raw[name] + ' ' + value
        else:
            raw[name] = value
        i += 1
    return raw


def expand_str(raw, name, depth=0):
    if depth > 20:
        return raw.get(name, '')
    val = raw.get(name, '')

    def repl(m):
        return expand_str(raw, m.group(1), depth + 1)
    prev = None
    while prev != val:
        prev = val
        val = VARREF_RE.sub(repl, val)
    return val


def makefile_expanded_vars():
    text = open(os.path.join(ROOT, 'Makefile'), errors='replace').read()
    raw = parse_makefile_vars(text)
    return {name: expand_str(raw, name).split() for name in raw}


def check_kernel_proc_mods(graph):
    failures = []
    makefile_text = open(os.path.join(ROOT, 'Makefile'), errors='replace').read()
    raw_vars = parse_makefile_vars(makefile_text)
    if 'KERNEL_PROC_MODS' not in raw_vars:
        return [
            'Makefile: KERNEL_PROC_MODS not found -- cannot check kernel '
            'module coverage for process-bearing manifests.']

    def kernel_toks(name):
        toks = set(os.path.normpath(os.path.join(ROOT, t))
                  for t in expand_str(raw_vars, name).split())
        return {t for t in toks
               if t.startswith(os.path.join(ROOT, 'src', 'kernel') + os.sep)}

    def all_toks(name):
        return set(os.path.normpath(os.path.join(ROOT, t))
                  for t in expand_str(raw_vars, name).split())

    process_s = os.path.normpath(os.path.join(ROOT, 'src/kernel/process.s'))
    put_targets = {t for edges in graph.values()
                   for _d, t, _l in edges if _d in DIRECTIVES}
    manifests = toplevel_manifests(graph, put_targets)
    process_bearing = [m for m in manifests if process_s in closure(graph, m)]

    # Every Make variable, expanded once, with the manifest(s) it names and
    # the src/kernel/*.s tokens it covers (whether via $(KERNEL_PROC_MODS)
    # or listed directly, e.g. PLAYTEST_DEPS' explicit mouse.s/timer.s).
    var_manifests = {}   # varname -> set(resolved tokens)
    var_kernel = {}
    for name in raw_vars:
        toks = all_toks(name)
        if toks & set(manifests):
            var_manifests[name] = toks
            var_kernel[name] = kernel_toks(name)

    for manifest in process_bearing:
        required = {f for f in closure(graph, manifest)
                   if f.startswith(os.path.join(ROOT, 'src', 'kernel') + os.sep)}
        owners = [n for n, toks in var_manifests.items() if manifest in toks]
        if not owners:
            failures.append(
                f'{rel(manifest)}: reaches src/kernel/process.s but no '
                f'Makefile variable lists it as a dependency at all -- '
                f'editing a kernel module it uses will not trigger a '
                f'rebuild.')
            continue
        for name in owners:
            missing = required - var_kernel[name]
            if missing:
                failures.append(
                    f'{rel(manifest)}: Makefile variable {name} is missing '
                    f'{sorted(rel(f) for f in missing)} from its kernel '
                    f'module coverage (KERNEL_PROC_MODS + its own direct '
                    f'src/kernel/*.s tokens) -- {rel(manifest)}\'s put '
                    f'chain reaches them but a rebuild would not notice '
                    f'they changed.')
    return failures


# ---------------------------------------------------------------------------
# CHECK 3 -- build_maux_src_image.py's own staging is graph-derived
# (2026-08-23), so instance (c)'s failure mode (a hand list drifting from
# the true closure) can no longer happen; this now guards the two things
# that CAN still drift -- the OVERRIDE_NAMES flat-name table and UNITS.
# ---------------------------------------------------------------------------
def check_maux_src_image(graph, put_targets):
    """build_maux_src_image.py (2026-08-23 rewrite) stages every unit's
    dependency set by walking THIS SAME put/use graph (`import
    check_manifests as cm`; see that script's own docstring) rather than
    from a hand-maintained list -- so the original failure mode this check
    existed for (instance (c) in this module's docstring: a hand list
    drifting from the true closure) is now structurally impossible, there
    is no second list left to drift. What CAN still go stale: the
    OVERRIDE_NAMES flat-name table (an entry naming a file that no longer
    exists, or two entries claiming the same ProDOS name), and UNITS (an
    entry naming a path that is not actually a real top-level manifest --
    e.g. because it became someone else's put/use target). Check those."""
    failures = []
    sys.path.insert(0, os.path.join(ROOT, 'scripts'))
    sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
    try:
        import build_maux_src_image as bmsi
    except Exception as e:  # pragma: no cover -- environment-dependent
        return [f'build_maux_src_image.py: could not import ({e}); '
                f'skipping OVERRIDE_NAMES/UNITS staleness check.']

    seen_names = {}
    for name, path in bmsi.OVERRIDE_NAMES.items():
        full = os.path.normpath(os.path.join(ROOT, path))
        if not os.path.exists(full):
            failures.append(
                f'build_maux_src_image.py: OVERRIDE_NAMES[{name!r}] names '
                f'{path!r}, which no longer exists on disk -- stale entry.')
        if not re.match(r'^[A-Z][A-Z0-9]{0,12}$', name):
            failures.append(
                f'build_maux_src_image.py: OVERRIDE_NAMES[{name!r}] '
                f'({path}) is not a legal <=13-char ProDOS name.')
        if name in seen_names:
            failures.append(
                f'build_maux_src_image.py: OVERRIDE_NAMES has two entries '
                f'for {name!r}: {seen_names[name]!r} and {path!r}.')
        seen_names[name] = path

    for u in bmsi.UNITS:
        full = os.path.normpath(os.path.join(ROOT, u['path']))
        if full not in graph:
            failures.append(
                f'build_maux_src_image.py: UNITS[{u["name"]!r}] path '
                f'{u["path"]!r} is not a source file this module scans.')
        elif full in put_targets:
            failures.append(
                f'build_maux_src_image.py: UNITS[{u["name"]!r}] path '
                f'{u["path"]!r} is itself a put/use TARGET of another '
                f'file -- it is not a real top-level manifest.')
    return failures


# ---------------------------------------------------------------------------
# CHECK 4 -- build_ascore_image.py's PRIMARY + PUT_INCLUDED must cover
# every file src/merlin/patches.py has active patch entries for (instance
# (b)): a patched-but-unstaged file is an inert patch.
# ---------------------------------------------------------------------------
def check_ascore_image():
    failures = []
    sys.path.insert(0, os.path.join(ROOT, 'src', 'merlin'))
    sys.path.insert(0, os.path.join(ROOT, 'scripts'))
    sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
    try:
        import patches
        import build_ascore_image as bai
    except Exception as e:  # pragma: no cover
        return [f'build_ascore_image.py / patches.py: could not import '
                f'({e}); skipping PUT_INCLUDED coverage check.']

    patched_files = set()
    for name, plist in patches.GROUPS.items():
        for p in plist:
            patched_files.add(p[0])

    staged = set(bai.PRIMARY) | set(bai.PUT_INCLUDED)
    missing = patched_files - staged
    if missing:
        failures.append(
            f'build_ascore_image.py: PRIMARY + PUT_INCLUDED is missing '
            f'{sorted(missing)}, which src/merlin/patches.py has active '
            f'patch entries for (GROUPS) -- those patches would apply to '
            f'nothing staged on the image, silently inert.')
    return failures


# ---------------------------------------------------------------------------
# CHECK 5 -- docs/AS-P10-ENUMERATION.txt's claimed embedded-file set must
# match what MACASS.S's own PUT/USE chain actually reaches (instance (a)).
# Parsed leniently: if the doc's header markers are not found, this check
# is skipped with a note rather than guessed at.
# ---------------------------------------------------------------------------
DOC_PATH = os.path.join(ROOT, 'docs', 'AS-P10-ENUMERATION.txt')
MERLIN_ROOT = os.path.join(ROOT, 'vendor', 'merlin')
MERLIN_NAME_RE = re.compile(r'\b[A-Z][A-Z0-9_.]*(?:/[A-Z0-9_.]+)*\.S\b')


def decode_merlin(path):
    """High-bit ASCII, $8D-delimited -- vendor/merlin/*.S's own format
    (see src/merlin/patches.py's decode_lines(), same algorithm)."""
    raw = open(path, 'rb').read()
    segs = raw.split(b'\x8d')
    return [bytes(b & 0x7F for b in s).decode('ascii', 'replace')
            for s in segs]


def merlin_put_use_chain(root_name):
    """Transitive file set (relative to vendor/merlin/) reachable from
    `root_name` (e.g. 'MACASS') via PUT/USE, filtering the label-vs-
    directive ambiguity: a genuine directive line is INDENTED (leading
    whitespace); `PUT PHP`/`USE DEY` in column 1 are a label named PUT/USE
    followed by a real opcode, not file inclusion (confirmed against
    vendor/merlin/ASS.BNK1.S:1337-1338 -- see docs/AS-P10-ENUMERATION.txt's
    own method note)."""
    seen = set()
    stack = [root_name]
    while stack:
        name = stack.pop()
        if name in seen:
            continue
        seen.add(name)
        path = os.path.join(MERLIN_ROOT, name + '.S')
        if not os.path.exists(path):
            continue
        for text in decode_merlin(path):
            if text[:1] not in (' ', '\t'):
                continue          # column-1 label, not a directive
            m = re.match(r'^\s*(put|use)\s+(\S+)', text, re.IGNORECASE)
            if m:
                stack.append(m.group(2))
    return seen


def parse_doc_claimed_sets(text):
    """Best-effort section parse. Each section has the shape `HEADER
    (explanatory parenthetical -- may itself name files in passing):
    NAME, NAME, ...` up to the next header -- so names are extracted only
    from AFTER that section's OWN closing '):', not from its explanatory
    parenthetical (which can and does mention other files in passing,
    e.g. the "NOT embedded" header's own explanation mentions MACASS.S
    without MACASS.S being one of the not-embedded files). Returns
    (embedded_names, not_embedded_names) or (None, None) if the expected
    headers are not found."""
    headers = ['REAL OBJECT BYTES', "PUT'D BUT ZERO OBJECT BYTES",
              "USE'D MACRO LIBRARY", 'NOT embedded']
    idxs = [text.find(h) for h in headers]
    if any(i == -1 for i in idxs):
        return None, None
    end = text.find('Referenced by', idxs[-1])
    if end == -1:
        end = len(text)
    bounds = idxs + [end]

    def section_names(i):
        start, stop = bounds[i], bounds[i + 1]
        colon = text.find('):', start, stop)
        if colon == -1:
            return set()
        return set(m.group(0)
                  for m in MERLIN_NAME_RE.finditer(text[colon + 2:stop]))

    embedded = section_names(0) | section_names(1) | section_names(2)
    not_embedded = section_names(3)
    return embedded, not_embedded


def check_as_p10_enumeration():
    failures = []
    if not os.path.exists(DOC_PATH):
        return [f'{rel(DOC_PATH)}: not found -- skipping.']
    text = open(DOC_PATH, errors='replace').read()
    claimed, claimed_not = parse_doc_claimed_sets(text)
    if claimed is None:
        return [f'{rel(DOC_PATH)}: expected section headers (REAL OBJECT '
                f'BYTES / PUT\'D BUT ZERO OBJECT BYTES / USE\'D MACRO '
                f'LIBRARY / NOT embedded) not found -- doc format changed, '
                f'cannot reliably parse; check by hand.']
    if not os.path.isdir(MERLIN_ROOT):
        return [f'{rel(MERLIN_ROOT)}: not present (run `make vendor-merlin` '
                f'first) -- cannot derive ground truth for '
                f'{rel(DOC_PATH)}, skipping.']

    actual = merlin_put_use_chain('MACASS')
    actual_names = {n + '.S' for n in actual}

    missing = actual_names - claimed
    extra = claimed - actual_names
    if missing:
        failures.append(
            f'{rel(DOC_PATH)}: MACASS.S\'s PUT/USE chain reaches '
            f'{sorted(missing)}, which the doc\'s embedded-file list does '
            f'not claim -- the doc under-states what a sweep must cover '
            f'(this is exactly instance (a): LINKER.S was omitted this '
            f'way).')
    if extra:
        failures.append(
            f'{rel(DOC_PATH)}: doc claims {sorted(extra)} as embedded, but '
            f'MACASS.S\'s own PUT/USE chain does not reach '
            f'{"them" if len(extra) > 1 else "it"} -- the doc over-states '
            f'the embedded set.')
    bad_not = claimed_not & actual_names
    if bad_not:
        failures.append(
            f'{rel(DOC_PATH)}: doc lists {sorted(bad_not)} under "NOT '
            f'embedded", but MACASS.S\'s PUT/USE chain DOES reach '
            f'{"them" if len(bad_not) > 1 else "it"}.')
    return failures


# ---------------------------------------------------------------------------
# CHECK 6 -- Makefile FULL-closure dependency coverage, EVERY built
# manifest. CHECK 2 audits only manifests whose closure reaches
# src/kernel/process.s, and only their src/kernel/*.s coverage -- which
# exempted 53 of 82 manifests (all three sched.*.s and bankcopytest.s
# among them) and never looked at inc/*.equ at all. Cost of the
# exemption, found 2026-08-23 (S4): $(SCHEDWAKEBLK)'s dep list missed
# sched2.s -- the file holding `dec K_QUANTUM` and SCH_WAKEUP, the other
# half of the C1 mechanism its own gate certifies -- so editing either
# left check-sched running a STALE image, green. Same day, same class:
# $(BANKCOPYBLK) missed inc/bankcopy.equ (BC_KIND_BANK's home) and
# five sibling equ files. This check derives, for every top-level
# manifest named in a Makefile rule's dependencies (explicit or via the
# $(BUILD)/%.bin pattern rule), the manifest's transitive put/use closure
# and requires the rule's expanded dependency list to cover ALL of it --
# .s and .equ alike. Manifests no rule names are listed as a note, not a
# pass: an unchecked manifest is exactly where the next hole hides.
# ---------------------------------------------------------------------------
WILDCARD_RE = re.compile(r'\$\(wildcard\s+([^)]*)\)')
RULE_RE = re.compile(r'^([^\t#][^:=]*):(?!=)([^;]*)$')


def expand_with_funcs(raw, s, depth=0):
    """expand_str over a STRING (not a var name), plus $(wildcard ...)
    -- the one Make function this Makefile uses in dependency position
    (LIBA_SRCS)."""
    if depth > 20:
        return s

    def wrepl(m):
        pats = expand_with_funcs(raw, m.group(1), depth + 1).split()
        out = []
        for p in pats:
            out.extend(sorted(glob.glob(os.path.join(ROOT, p))))
        return ' '.join(os.path.relpath(p, ROOT) for p in out)

    prev = None
    while prev != s:
        prev = s
        # plain $(VAR) refs FIRST: WILDCARD_RE's [^)]* would otherwise
        # stop at a nested ref's own closing paren ($(wildcard
        # $(LIBA)/*.s) truncated to "$(LIBA"). VARREF_RE cannot match
        # the wildcard call itself -- its name must be followed
        # immediately by ')'.
        s = VARREF_RE.sub(
            lambda m: expand_with_funcs(raw, raw.get(m.group(1), ''),
                                        depth + 1), s)
        s = WILDCARD_RE.sub(wrepl, s)
    return s


def parse_makefile_rules(raw_vars, text):
    """[(targets, deps)] with variables and $(wildcard) expanded, `\\`-
    continuations joined, order-only deps (after `|`) dropped. Recipe
    and assignment lines are excluded by RULE_RE's own shape."""
    lines = text.split('\n')
    rules = []
    i = 0
    while i < len(lines):
        line = lines[i]
        while line.rstrip().endswith('\\') and i + 1 < len(lines):
            i += 1
            line = line.rstrip()[:-1] + ' ' + lines[i]
        m = RULE_RE.match(line)
        i += 1
        if not m:
            continue
        tgt_s = expand_with_funcs(raw_vars, m.group(1)).strip()
        dep_s = expand_with_funcs(raw_vars,
                                  m.group(2).split('|')[0]).strip()
        if not tgt_s or tgt_s.startswith('.'):
            continue          # .PHONY etc.
        rules.append((tgt_s.split(), dep_s.split()))
    return rules


def check_makefile_closure(graph):
    failures = []
    text = open(os.path.join(ROOT, 'Makefile'), errors='replace').read()
    raw_vars = parse_makefile_vars(text)
    rules = parse_makefile_rules(raw_vars, text)

    put_targets = {t for edges in graph.values()
                   for _d, t, _l in edges if _d in DIRECTIVES}
    manifests = set(toplevel_manifests(graph, put_targets))

    def norm(tok):
        return os.path.normpath(os.path.join(ROOT, tok))

    # Union prerequisites BY TARGET first -- Make merges the dep lists
    # of every rule naming the same target, so an extra-prerequisites
    # line (`build/foo.bin: src/bin/bar.s`) legitimately augments the
    # pattern rule's own list and must count.
    by_target = {}                    # concrete target -> set(dep paths)
    for targets, deps in rules:
        dep_paths = {norm(t) for t in deps if '%' not in t}
        pattern_srcs = [t for t in deps if '%' in t]
        for tgt in targets:
            if '%' in tgt and pattern_srcs:
                # instantiate the pattern per matching manifest
                dpre, dpost = pattern_srcs[0].split('%', 1)
                tpre, tpost = tgt.split('%', 1)
                for mfst in sorted(manifests):
                    r = os.path.relpath(mfst, ROOT)
                    if r.startswith(dpre) and r.endswith(dpost):
                        stem = r[len(dpre):len(r) - len(dpost)]
                        concrete = tpre + stem + tpost
                        by_target.setdefault(concrete, set()).update(
                            dep_paths | {mfst})
            elif '%' not in tgt:
                by_target.setdefault(tgt, set()).update(dep_paths)

    checked = set()
    for tgt in sorted(by_target):
        dep_paths = by_target[tgt]
        for mfst in sorted(dep_paths & manifests):
            checked.add(mfst)
            required = closure(graph, mfst)
            missing = required - dep_paths - {mfst}
            if missing:
                failures.append(
                    f'Makefile rule(s) for {tgt}: the merged dependency '
                    f'list is missing {sorted(rel(f) for f in missing)} '
                    f'-- all reachable from {rel(mfst)}\'s put/use chain, '
                    f'so editing any of them re-runs the gate on a STALE '
                    f'image, green.')
    unchecked = sorted(rel(m) for m in manifests - checked)
    if unchecked:
        print(f'   note: {len(unchecked)} top-level manifest(s) appear in '
              f'no Makefile rule dependency list and are not checked: '
              f'{", ".join(unchecked)}')
    return failures


# ---------------------------------------------------------------------------
# CHECK 7 -- scripts/build_play_image.py's UTIL_BINS (the play image's
# program roster -- "the one image a human actually sits down and boots")
# must be DERIVED from the Makefile's own UTILS variable, not a second
# hand-maintained list. Found 2026-08-23: UTIL_BINS was a hand-written
# Python list that carried only 20 of the 33 programs in UTILS, so the
# playable image was two waves behind the tree it was built from -- and
# nothing caught it, because nothing compared the two.
#
# build_play_image.py now derives UTIL_BINS = UTILS - PLAY_EXCLUDE
# (PLAY_EXCLUDE is its own declared, reasoned exclusion set -- currently
# just `as`). This check is the anti-drift backstop for that derivation:
# it re-derives the same thing independently (via makefile_expanded_vars(),
# already used above -- no second Makefile parser) and requires the two
# to match member-for-member, in BOTH directions:
#
#   (a) UTILS gains a program that is neither shipped (in UTIL_BINS) nor
#       named in PLAY_EXCLUDE with a reason -- the exact shape of the
#       original bug: a new utility ships to the tree and the playable
#       image never hears about it.
#   (b) UTIL_BINS (or PLAY_EXCLUDE) names something UTILS does not --
#       drift the other way: the image ships, or claims to exclude, a
#       program the Makefile no longer declares a real utility.
# ---------------------------------------------------------------------------
def check_play_image_roster():
    failures = []
    sys.path.insert(0, os.path.join(ROOT, 'scripts'))
    try:
        import build_play_image as bpi
    except Exception as e:  # pragma: no cover -- environment-dependent
        return [f'build_play_image.py: could not import ({e}); skipping '
                f'play-image roster coverage check.']

    utils_vars = makefile_expanded_vars()
    if 'UTILS' not in utils_vars:
        return ['Makefile: UTILS not found -- cannot check the play '
                'image\'s derived roster against it.']
    utils = set(utils_vars['UTILS'])
    shipped = set(name for name, _path in bpi.UTIL_BINS)
    excluded = set(bpi.PLAY_EXCLUDE)

    missing = utils - shipped - excluded
    if missing:
        failures.append(
            f'build_play_image.py: UTIL_BINS ships neither '
            f'{sorted(missing)} nor excludes {"it" if len(missing) == 1 else "them"} '
            f'via PLAY_EXCLUDE, but the Makefile\'s UTILS names '
            f'{"it" if len(missing) == 1 else "them"} -- the play image is '
            f'silently behind the tree it was built from (this is exactly '
            f'the 2026-08-23 bug: UTIL_BINS carried 20 of 33 UTILS entries '
            f'and nothing noticed).')

    extra = shipped - utils
    if extra:
        failures.append(
            f'build_play_image.py: UTIL_BINS ships {sorted(extra)}, which '
            f'the Makefile\'s UTILS does not name -- drift in the other '
            f'direction: the play image contains a program the Makefile '
            f'no longer (or never did) declare as a real utility.')

    stale_exclude = excluded - utils
    if stale_exclude:
        failures.append(
            f'build_play_image.py: PLAY_EXCLUDE names {sorted(stale_exclude)}, '
            f'which the Makefile\'s UTILS does not (or no longer) contain -- '
            f'a stale exclusion is exactly the kind of thing that hides a '
            f'rename or removal from review.')

    contradiction = shipped & excluded
    if contradiction:
        failures.append(
            f'build_play_image.py: {sorted(contradiction)} appear(s) in '
            f'BOTH UTIL_BINS and PLAY_EXCLUDE -- shipped and declared '
            f'excluded at once.')

    return failures


# ---------------------------------------------------------------------------
# CHECK 8 -- the release disk's roster (docs/FULLDISK.md sec 4).
# build_full_image.py ships every program the Makefile builds: UTILS
# minus FULL_EXCLUDE, in /bin, plus nas, ld and plasm. The ruling (SITE.md
# D2, "all the fruit") makes FULL_EXCLUDE empty, and it is declared here
# the way CHECK 7 declares PLAY_EXCLUDE so that a program which is built
# but neither on full.po nor excluded WITH A REASON fails, in both
# directions:
#   (a) UTILS gains a program the release disk neither carries nor
#       excludes -- the 2026-08-23 shape, one image further down;
#   (b) FULL_EXCLUDE names something UTILS no longer has, or a name sits
#       in both lists.
# It also requires every FULL_EXCLUDE reason to be a non-empty sentence
# (an exclusion that does not say why is the thing the ruling forbids),
# and the three extra names to be real build products.
# ---------------------------------------------------------------------------
def check_full_image_roster():
    failures = []
    sys.path.insert(0, os.path.join(ROOT, 'scripts'))
    try:
        import build_full_image as bfi
    except Exception as e:  # pragma: no cover -- environment-dependent
        return [f'build_full_image.py: could not import ({e}); skipping '
                f'full-image roster coverage check.']
    utils_vars = makefile_expanded_vars()
    if 'UTILS' not in utils_vars:
        return ['Makefile: UTILS not found -- cannot check the release '
                'disk\'s roster against it.']
    utils = set(utils_vars['UTILS'])
    shipped = set(bfi.full_util_names())
    excluded = set(bfi.FULL_EXCLUDE)

    missing = utils - shipped - excluded
    if missing:
        failures.append(
            f'build_full_image.py: the release disk ships neither '
            f'{sorted(missing)} nor excludes them via FULL_EXCLUDE, but '
            f'the Makefile\'s UTILS names them')
    extra = shipped - utils
    if extra:
        failures.append(
            f'build_full_image.py: ships {sorted(extra)}, which the '
            f'Makefile\'s UTILS does not name')
    stale = excluded - utils
    if stale:
        failures.append(
            f'build_full_image.py: FULL_EXCLUDE names {sorted(stale)}, '
            f'which UTILS no longer contains')
    both = shipped & excluded
    if both:
        failures.append(f'build_full_image.py: {sorted(both)} are both '
                        f'shipped and excluded')
    for name, why in bfi.FULL_EXCLUDE.items():
        if not (isinstance(why, str) and len(why.split()) >= 4):
            failures.append(f'build_full_image.py: FULL_EXCLUDE[{name!r}] '
                            f'has no reason')
    # THE STAGING ITSELF, not a list it shares: run stage_bins() against a
    # recorder (build_full_image.planned_bin_names) and require /bin to
    # hold exactly UTILS minus FULL_EXCLUDE plus nas/ld/plasm. A name that
    # stage_bins() forgets to write -- the bug this check exists for --
    # shows up here and nowhere in the two UTILS-derived sets above.
    want = ({n.lower() for n in utils} - {n.lower() for n in excluded}) | \
        {n.lower() for n in bfi.FULL_EXTRA_NAMES}
    got = set(bfi.planned_bin_names())
    if want - got:
        failures.append(f'build_full_image.py: stage_bins() leaves '
                        f'{sorted(want - got)} out of /bin')
    if got - want:
        failures.append(f'build_full_image.py: /bin would also hold '
                        f'{sorted(got - want)}, which UTILS does not name')
    # PLAY_EXCLUDE names must all be reachable from the release disk
    # (its reason, the play volume's root cap, does not apply to /bin)
    import build_play_image as bpi
    unshipped = [n for n in bpi.PLAY_EXCLUDE if n not in shipped]
    if unshipped and not all(n in excluded for n in unshipped):
        failures.append(f'PLAY_EXCLUDE {sorted(unshipped)} are on neither '
                        f'the release disk nor FULL_EXCLUDE')
    return failures


# ---------------------------------------------------------------------------
def run_all():
    """Run every check, print detail, return the combined failure list --
    the shape check_modules.py's check_equ_forward_refs() etc. use."""
    failures = []
    graph, put_targets = build_graph()

    print()
    print('[check-manifests] no nested PUT (dialect rule, both assemblers)')
    f1 = check_no_nested_put(graph, put_targets)
    print(f'   {len(f1)} violation(s)' if f1 else '   0 -- no put/use '
          'target itself contains a put/use line')
    failures += f1

    print()
    print('[check-manifests] Makefile KERNEL_PROC_MODS coverage '
          '(process-bearing manifests)')
    f2 = check_kernel_proc_mods(graph)
    print(f'   {len(f2)} gap(s)' if f2 else '   0 -- every process-bearing '
          'manifest\'s kernel modules are covered by its Makefile deps')
    failures += f2

    print()
    print('[check-manifests] build_maux_src_image.py UNITS/OVERRIDE_NAMES '
          'staleness (staging itself is graph-derived, not hand-listed)')
    f3 = check_maux_src_image(graph, put_targets)
    print(f'   {len(f3)} problem(s)' if f3 else '   0 -- every '
          'OVERRIDE_NAMES entry is live and legal, every UNITS path is a '
          'real top-level manifest')
    failures += f3

    print()
    print('[check-manifests] build_ascore_image.py PRIMARY+PUT_INCLUDED '
          'vs. patches.py GROUPS')
    f4 = check_ascore_image()
    print(f'   {len(f4)} gap(s)' if f4 else '   0 -- every patched file is '
          'staged')
    failures += f4

    print()
    print('[check-manifests] docs/AS-P10-ENUMERATION.txt vs. MACASS.S\'s '
          'own PUT/USE chain')
    f5 = check_as_p10_enumeration()
    print(f'   {len(f5)} mismatch(es)' if f5 else '   0 -- doc\'s claimed '
          'embedded-file set matches MACASS.S\'s own PUT/USE chain')
    failures += f5

    print()
    print('[check-manifests] Makefile full-closure dependency coverage '
          '(every built manifest, .s AND .equ)')
    f6 = check_makefile_closure(graph)
    print(f'   {len(f6)} gap(s)' if f6 else '   0 -- every built '
          'manifest\'s Makefile deps cover its full put/use closure')
    failures += f6

    print()
    print('[check-manifests] build_play_image.py UTIL_BINS vs. Makefile '
          'UTILS (play-image roster, both directions)')
    f7 = check_play_image_roster()
    print(f'   {len(f7)} gap(s)' if f7 else '   0 -- UTIL_BINS is exactly '
          'UTILS minus PLAY_EXCLUDE, no more, no less')
    failures += f7

    print()
    print('[check-manifests] build_full_image.py roster vs. Makefile '
          'UTILS (release-disk roster, both directions)')
    f8 = check_full_image_roster()
    print(f'   {len(f8)} gap(s)' if f8 else '   0 -- the release disk '
          'carries UTILS minus FULL_EXCLUDE (empty by ruling), no more, '
          'no less')
    failures += f8

    return failures


def main():
    os.chdir(ROOT)
    failures = run_all()
    if failures:
        print()
        for f in failures:
            print(f'[check-manifests] FAIL: {f}', file=sys.stderr)
        return 1
    print()
    print('[check-manifests] PASS: every file list checked matches ground '
          'truth derived from source')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
