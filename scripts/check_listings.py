#!/usr/bin/env python3
"""check_listings.py -- no gate deletes or rewrites a listing another
gate reads (HYG-3, docs/HYG-3.md; run by check-modules).

THE CLASS. merlin32 `-v1` writes build/<name>_Output.txt (and the
`dsk` binary beside it) at a path relative to its cwd. A script that
assembles in the real tree to read the dump, and then deletes it,
rewrites and removes files that other gates read at the same moment in
another sweep lane: check-shwarm went red in a sweep (FileNotFoundError
build/sh.bin_Output.txt), green alone, because another lane
reassembled sh.s between its assemble and its read. The fix is that a
gate which assembles only for symbols does it in a private tree
(arena.private_listing); this gate keeps the next script from doing it
the old way.

TWO RULES, both over scripts/*.py (AST) and scripts/*.sh (text):

  1. DELETE/REWRITE. No call that removes, renames or opens for
     writing a path naming `_Output.txt` -- directly, or through a
     variable assigned from an expression that names it. (The old
     idiom was `out = os.path.join(ROOT, 'build', 'X_Output.txt')` then
     `os.remove(out)`.) Exempt files are listed with a reason in
     DELETE_EXEMPT.
  2. WHO MAY RUN merlin32. A script that runs merlin32 at all is a
     writer of build/ listings unless it works elsewhere, so every such
     script is named in MERLIN_ROSTER with where its output lands. A
     new script that runs merlin32 fails until someone says where it
     writes -- the question this class of bug is made of.

Grep-grade on purpose: a declared roster, not a dataflow proof. The
self-test plants a defect of each form and requires red.
"""
import ast
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Scripts allowed to delete/rewrite an `_Output.txt` path, with why.
DELETE_EXEMPT = {}

# Scripts that run merlin32, and where each puts what it writes.
MERLIN_ROSTER = {
    'scripts/arena.py':
        'private tree (private_tree: mkdtemp, removed after); the one '
        'helper the symbol-reading gates use',
    'scripts/check_bye.py':
        'its own directory build/byee2e (a generated probe)',
    'scripts/check_iobuf.py':
        'its own directory build/iobuf (a generated probe)',
    'scripts/check_oftbye.py':
        'its own directory build/oftbye (a generated probe)',
    'scripts/check_openro_k.py':
        'its own directory build/openro (a generated probe)',
    'scripts/check_openrw2_k.py':
        'its own directory build/openrw2 (a generated probe)',
    'scripts/check_nas_boundary.py':
        'tempfile.TemporaryDirectory oracle',
    'scripts/check_nas_rel.py':
        'tempfile.TemporaryDirectory oracle',
    'scripts/profile_nas_vs_as.py':
        'profile target (make profile-nas), not in any sweep',
    'scripts/profile_zpage.py':
        'profile script, not in any sweep; reads build/MAUXCATREAD '
        'listing, assembles nothing shared that a gate reads',
    'scripts/report_liba.py':
        'report target (make report-liba), not in any sweep; never '
        'fails a build',
}

#: Roster entries this tree does not carry, filled per run by
#: run_checks() and printed by run_all(). In-house it is empty; in the
#: published tree it is the withheld merlin32 runners.
SKIPPED = []


def withheld_rig():
    """The rig set, from check_publish -- the gate that owns it.

    Returns an empty set if that import ever fails, which keeps this gate
    strict rather than permissive: every roster entry is then required to
    exist, exactly as before this function was added.
    """
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from check_publish import WITHHELD_RIG
        return set(WITHHELD_RIG)
    except ImportError:
        return set()


LISTING = '_Output.txt'
REMOVERS = {'remove', 'unlink', 'rename', 'replace', 'rmtree', 'move',
            'truncate', 'write_text', 'write_bytes'}


def _names(node):
    return {n.id for n in ast.walk(node) if isinstance(n, ast.Name)}


def _mentions_listing(node):
    for n in ast.walk(node):
        if isinstance(n, ast.Constant) and isinstance(n.value, str) \
                and LISTING in n.value:
            return True
    return False


def _own_nodes(scope):
    """Nodes of one scope, not descending into nested functions or
    classes (their names are their own)."""
    stack = list(ast.iter_child_nodes(scope))
    while stack:
        n = stack.pop()
        yield n
        if not isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef,
                              ast.ClassDef, ast.Lambda)):
            stack.extend(ast.iter_child_nodes(n))


def _tainted_names(scope, inherited=frozenset()):
    """Names bound in this scope from an expression that names
    `_Output.txt`, closed under further assignment. Scoped per
    function (plus module-level constants like `LISTING = '...'`):
    a module-wide name set tainted every `d` and `args` in a script
    that mentions a listing anywhere."""
    tainted = set(inherited)
    changed = True
    while changed:
        changed = False
        for n in _own_nodes(scope):
            if isinstance(n, ast.Assign):
                value, targets = n.value, n.targets
            elif isinstance(n, ast.AnnAssign) and n.value is not None:
                value, targets = n.value, [n.target]
            else:
                continue
            if _mentions_listing(value) or (_names(value) & tainted):
                for t in targets:
                    for nm in _names(t):
                        if nm not in tainted:
                            tainted.add(nm)
                            changed = True
    return tainted


def _is_write_open(call):
    f = call.func
    if not (isinstance(f, ast.Name) and f.id == 'open'):
        return False
    mode = None
    if len(call.args) > 1 and isinstance(call.args[1], ast.Constant):
        mode = call.args[1].value
    for kw in call.keywords:
        if kw.arg == 'mode' and isinstance(kw.value, ast.Constant):
            mode = kw.value.value
    return isinstance(mode, str) and any(c in mode for c in 'wax+')


def _is_remover(call):
    """A call that removes, renames or writes a path: os.remove and
    friends, shutil.rmtree/move, Path.unlink/write_text/write_bytes,
    or open(..., 'w'). `str.replace` is not one of them."""
    f = call.func
    if isinstance(f, ast.Attribute):
        if isinstance(f.value, ast.Name) and f.value.id in ('os', 'shutil'):
            return f.attr in REMOVERS
        return f.attr in ('unlink', 'write_text', 'write_bytes',
                          'truncate')
    return _is_write_open(call)


def scan_python(rel, text):
    """Rule 1 failures for one script's source."""
    try:
        tree = ast.parse(text)
    except SyntaxError as e:
        return [f'{rel}: does not parse ({e.msg}), cannot be scanned']
    modtaint = _tainted_names(tree)
    scopes = [(tree, modtaint)]
    for n in ast.walk(tree):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
            scopes.append((n, _tainted_names(n, modtaint)))
    out = []
    seen = set()
    for scope, tainted in scopes:
        for n in _own_nodes(scope):
            if not isinstance(n, ast.Call) or not _is_remover(n):
                continue
            f = n.func
            name = f.attr if isinstance(f, ast.Attribute) else f.id
            # The path may be an argument or, for Path.unlink() and
            # friends, the receiver.
            parts = list(n.args) + [k.value for k in n.keywords]
            if isinstance(f, ast.Attribute):
                parts.append(f.value)
            hit = any(_mentions_listing(p) or (_names(p) & tainted)
                      for p in parts)
            if hit and n.lineno not in seen:
                seen.add(n.lineno)
                out.append(
                    f'{rel}:{n.lineno}: {name}() on a path naming '
                    f'`{LISTING}` -- a gate must not delete or rewrite '
                    f'a listing another gate reads; assemble in a '
                    f'private tree (arena.private_listing) instead, or '
                    f'declare the script in check_listings.'
                    f'DELETE_EXEMPT with a reason')
    return out


def scan_shell(rel, text):
    out = []
    for i, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if s.startswith('#'):
            continue
        if LISTING in s and re.search(r'(\brm\b|\bmv\b|\btruncate\b|>)', s):
            out.append(f'{rel}:{i}: removes or rewrites a path naming '
                       f'`{LISTING}`: {s[:80]}')
    return out


def runs_merlin(text):
    """True if the script runs merlin32 (subprocess call, or the shell
    spelling), not merely mentions it in prose."""
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return False
    for n in ast.walk(tree):
        if not isinstance(n, ast.Call):
            continue
        seg = ast.get_source_segment(text, n) or ''
        if not re.match(r'(subprocess\.|check_output|Popen|run\()', seg):
            continue
        head = seg[:300]
        if re.search(r"""['"]merlin32['"]|MERLIN32""", head):
            return True
    return False


def run_checks(root=ROOT, delete_exempt=None, roster=None):
    delete_exempt = DELETE_EXEMPT if delete_exempt is None else delete_exempt
    roster = MERLIN_ROSTER if roster is None else roster
    failures = []
    pys = sorted(glob.glob(os.path.join(root, 'scripts', '*.py')))
    for p in pys:
        rel = os.path.relpath(p, root)
        with open(p, errors='replace') as fh:
            text = fh.read()
        if rel not in delete_exempt:
            failures += scan_python(rel, text)
        if rel not in roster and runs_merlin(text):
            failures.append(
                f'{rel}: runs merlin32 but is not in '
                f'check_listings.MERLIN_ROSTER -- say where its output '
                f'lands (a private tree, or a directory only it uses); '
                f'in the shared build/ it races every other gate that '
                f'reads the listing')
    for p in sorted(glob.glob(os.path.join(root, 'scripts', '*.sh'))):
        rel = os.path.relpath(p, root)
        with open(p, errors='replace') as fh:
            failures += scan_shell(rel, fh.read())
    # A roster entry whose file is absent is STALE in this tree and merely
    # NOT CARRIED in the published one: three of these scripts are
    # withheld as rig (NOT PUBLISHED: docs/PUBLISH-RIG-CUT.md), so it turned
    # check-modules red in a public clone -- found by building one and
    # running `make check-all-host` in it. The rig set is owned by
    # check_publish, which ships, so there is one list and not two.
    unpublished = withheld_rig()
    absent_rig = []
    for rel in sorted(set(roster) | set(delete_exempt)):
        if os.path.exists(os.path.join(root, rel)):
            continue
        if rel in unpublished:
            absent_rig.append(rel)
            continue   # reported by run_all -- never skipped in silence
        failures.append(f'{rel}: named in check_listings but gone -- '
                        f'remove the stale entry')
    SKIPPED[:] = absent_rig
    for rel in sorted(delete_exempt):
        p = os.path.join(root, rel)
        if os.path.exists(p):
            with open(p, errors='replace') as fh:
                if not scan_python(rel, fh.read()):
                    failures.append(
                        f'{rel}: in DELETE_EXEMPT but nothing in it '
                        f'trips rule 1 any more -- remove the entry')
    for rel in sorted(roster):
        p = os.path.join(root, rel)
        if os.path.exists(p):
            with open(p, errors='replace') as fh:
                if not runs_merlin(fh.read()):
                    failures.append(
                        f'{rel}: in MERLIN_ROSTER but no longer runs '
                        f'merlin32 -- remove the stale entry')
    return failures


# Each planted defect must be red. (name, source) -- rule 1 forms.
PLANTS = (
    ('direct remove of a literal listing path',
     "import os\nBUILD = 'build'\n"
     "os.remove(BUILD + '/sh.bin_Output.txt')\n"),
    ('the old idiom: variable from join(), then remove',
     "import os\nROOT = '.'\n"
     "out = os.path.join(ROOT, 'build', 'ls.bin_Output.txt')\n"
     "lines = open(out).readlines()\nos.remove(out)\n"),
    ('f-string listing path, Path.unlink()',
     "import pathlib\nn = 'sh'\n"
     "pathlib.Path(f'build/{n}.bin_Output.txt').unlink()\n"),
    ('rewrite by open(..., "w")',
     "p = 'build/MAUXPLAY.SYSTEM_Output.txt'\nopen(p, 'w').write('')\n"),
)
# A clean read of a listing must stay green.
CLEAN = ("import os\nout = os.path.join('build', 'x.bin_Output.txt')\n"
         "lines = open(out).readlines()\n")


def self_test():
    """Teeth: every planted defect is reported, a plain read is not,
    and a merlin32 runner outside the roster is reported."""
    failures = []
    for what, src in PLANTS:
        if not scan_python('plant.py', src):
            failures.append(f'self-test: planted defect not caught: {what}')
    if scan_python('clean.py', CLEAN):
        failures.append('self-test: a plain read of a listing was flagged')
    runner = ("import subprocess\n"
              "subprocess.run(['merlin32', '-v1', 'x.s'], check=True)\n")
    if not runs_merlin(runner):
        failures.append('self-test: a merlin32 runner was not detected')
    if runs_merlin("# merlin32 is mentioned in prose only\nx = 1\n"):
        failures.append('self-test: prose mention taken for a runner')
    return failures


def run_all(root=ROOT):
    print()
    print('[check-listings] no gate deletes or rewrites a listing '
          'another gate reads (HYG-3)')
    failures = self_test() + run_checks(root)
    if not failures:
        print(f'   0 -- scripts/*.py and *.sh scanned; '
              f'{len(MERLIN_ROSTER)} merlin32 runners declared, '
              f'{len(PLANTS)} planted defects caught')
    if SKIPPED:
        print(f'   note: {len(SKIPPED)} declared runner(s) are not in this '
              f'tree because they are withheld as rig, so their entries '
              f'are not checked for staleness here: {", ".join(SKIPPED)}')
    return failures


def main():
    failures = run_all()
    for f in failures:
        print(f'[check-listings] FAIL: {f}', file=sys.stderr)
    if failures:
        return 1
    print('[check-listings] PASS')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
