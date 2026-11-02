#!/usr/bin/env python3
"""check_teeth_patterns.py -- `make check-teeth-patterns` (docs/HYG-4.md).

Runs `--dry` on every scripts/teeth_*.py: STATIC, so no build, no gate,
no emulator and nothing written. A teeth runner is a spec; this proves
the spec still describes the tree -- every edit pattern occurs exactly
as often as it says, its span holds code and not only a comment, the
schema lints. A refactor that moves code a tooth sabotages fails HERE,
in the sweep, instead of at the next stream's teeth run.

A runner that does not import teeth_lib is NOT checked (running it would
edit the tree). While runners are being ported they are named in PENDING
and only warned about; a runner in neither state is a new runner that
must use scripts/teeth_lib.py, and fails. PENDING must be empty when
HYG-4 closes.

  check_teeth_patterns.py             the gate
  check_teeth_patterns.py --selftest  a stale pattern and a comment-only
                                      pattern must fail, a good one pass
"""
import ast
import glob
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

#: runners not yet on teeth_lib (HYG-4 phase 2); empty when it closes
PENDING = set()


def uses_lib(path):
    """True only for a runner that PROVABLY runs on teeth_lib: a real
    top-level `import teeth_lib` (not a comment or a docstring) AND a
    top-level call of its `main`. Nothing else is ever executed."""
    try:
        with open(path) as f:
            tree = ast.parse(f.read(), path)
    except (SyntaxError, ValueError):
        return False
    alias = None
    for node in tree.body:
        if isinstance(node, ast.Import):
            for a in node.names:
                if a.name == 'teeth_lib':
                    alias = a.asname or 'teeth_lib'
    if alias is None:
        return False
    for node in tree.body:
        if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call):
            fn = node.value.func
            if isinstance(fn, ast.Attribute) and fn.attr == 'main' \
                    and isinstance(fn.value, ast.Name) and fn.value.id == alias:
                return True
    return False


def dry(path, cwd=ROOT):
    r = subprocess.run([sys.executable, path, '--dry'], cwd=cwd,
                       capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout + r.stderr


def check(here=HERE, cwd=ROOT, pending=None):
    """-> (problems, pending names, runners linted clean)."""
    pending = PENDING if pending is None else pending
    bad, pend, ok = [], [], 0
    for path in sorted(glob.glob(os.path.join(here, 'teeth_*.py'))):
        name = os.path.basename(path)
        if name == 'teeth_lib.py':
            continue
        if not uses_lib(path):
            if name in pending:
                pend.append(name)
            else:
                bad.append('%s: a teeth runner must use scripts/teeth_lib.py '
                           '(a real `import teeth_lib` and a top-level '
                           'main() call; it was NOT executed)' % name)
            continue
        rc, out = dry(path, cwd)
        if rc != 0:
            bad.append('%s (exit %d):\n%s' % (name, rc, out.rstrip()))
        else:
            ok += 1
    for name in sorted(pending):
        p = os.path.join(here, name)
        if os.path.exists(p) and uses_lib(p):
            bad.append('%s is on teeth_lib: remove it from PENDING' % name)
    return bad, pend, ok


def main():
    bad, pend, ok = check()
    for name in pend:
        print('[check-teeth-patterns] pending: %s is not on teeth_lib yet'
              % name)
    if bad:
        print('[check-teeth-patterns] FAIL: %d problem(s)' % len(bad))
        for b in bad:
            print('  - ' + b.replace('\n', '\n    '))
        return 1
    print('[check-teeth-patterns] PASS: %d runner(s) lint clean, %d pending'
          % (ok, len(pend)))
    return 0


def selftest():
    """The gate must go red on a stale pattern and on a comment-only
    pattern, stay green on a good one, and NEVER execute a file that is
    not provably on teeth_lib (a comment or docstring naming the import)."""
    tmp = tempfile.mkdtemp(prefix='teeth-patterns-')
    src = os.path.join(tmp, 'a.s')
    with open(src, 'w') as f:
        f.write('            lda   #1                ;the marker\n'
                '            sta   $00\n')
    runner = os.path.join(tmp, 'teeth_x.py')

    def write(old):
        with open(runner, 'w') as f:
            f.write(
                'import sys\nsys.path.insert(0, %r)\nimport teeth_lib as T\n'
                'T.main("x", [T.Tooth("X1 t", edits=[T.Edit("a.s", %r, '
                '"zzz")], checks=[T.Check("fake", "aggregate", '
                'T.Aggregate("^x", "no rows"))])], root=%r)\n'
                % (HERE, old, tmp))

    fails = []
    for old, want, label in (
            ('sta   $00', 0, 'a good pattern'),
            ('lda   #9', 1, 'a stale pattern'),
            ('the marker', 1, 'a comment-only pattern')):
        write(old)
        rc, out = dry(runner, tmp)
        if (rc == 0) != (want == 0):
            fails.append('%s: exit %d\n%s' % (label, rc, out))
    # bypasses: naming the import in a comment or a docstring, or
    # importing without calling main, must not make a file "ported" --
    # and the file must not be run (it would write the sentinel)
    sentinel = os.path.join(tmp, 'EXECUTED')
    for label, body in (
            ('a comment', '# import teeth_lib\n'),
            ('a docstring', '"""import teeth_lib"""\n'),
            ('an import without a main() call', 'import teeth_lib\n')):
        with open(os.path.join(tmp, 'teeth_y.py'), 'w') as f:
            f.write(body + 'open(%r, "w").write("ran")\n' % sentinel)
        if os.path.exists(runner):
            os.remove(runner)          # only teeth_y.py is in the dir now
        bad, pend, ok = check(here=tmp, cwd=tmp, pending=set())
        if os.path.exists(sentinel):
            fails.append('%s: the file was EXECUTED' % label)
            os.remove(sentinel)
        if not any('teeth_y.py' in b and 'must use' in b for b in bad):
            fails.append('%s: not reported as unported: %s' % (label, bad))
    for p in glob.glob(os.path.join(tmp, '*')):
        os.remove(p)
    os.rmdir(tmp)
    if fails:
        print('[check-teeth-patterns] FAIL: selftest\n' + '\n'.join(fails))
        return 1
    print('[check-teeth-patterns] selftest: a stale and a comment-only '
          'pattern go red, a good one stays green, a comment or docstring '
          'naming the import is not "ported" and is never executed')
    return 0


if __name__ == '__main__':
    sys.exit(selftest() if sys.argv[1:] == ['--selftest'] else main())
