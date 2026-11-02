#!/usr/bin/env python3
"""check-host-sweep -- CHECK_HOST_TARGETS is exactly the emulator-free set.

`make check-all-host` is the promise HACKING.md makes to someone who has
cloned the public tree and has no emulator: these gates run with the
toolchain alone. A hand-maintained list cannot keep that promise -- the
day a gate in it grows an emulator prerequisite, the public sweep dies
with a build error instead of a test failure, and the person reading
HACKING.md concludes the project does not build.

So the list is DERIVED here and compared, which is the same discipline
the leak pins and the rig set use: the Makefile states it, this gate
proves it, and a divergence names the gate and the direction.

Needing no emulator is NOT the same as running alone, and that cost a
red: three gates read build/ artifacts that other gates produce, with the
dependency written in the script rather than in a prerequisite. They are
named in NOT_STANDALONE with their reasons, and the exclusion list is
itself asserted so it cannot go stale.

"Needs the emulator" is transitive and has two forms, because a gate can
reach the supervisor without naming it:

  * $(MCP_SUPERVISOR) somewhere in its prerequisite closure -- the
    Makefile's own way of saying "this boots a machine";
  * a recipe that runs mcp_drive.py, which spawns the supervisor itself.

Both are read out of `make -pn`, make's own rule database, rather than
re-parsing the Makefile: the database is what make will actually do, and
it already has every variable expanded and every target-specific
override applied. scripts/sweep_par.sh partitions its lanes from the
same source.

The answer does not depend on whether gates.mk is present, and getting
that right took two tries. The sweep is read from CHECK_ALL_TARGETS,
which already drops the rig gates in a tree that has no recipes for
them, and a gate with no rule is counted as neither free nor
machine-bound. Reading CHECK_ALL_SEQ instead -- the full ordered list,
including gates this tree may not carry -- made this gate RED in the
published tree, demanding that all 59 withheld gates be added to the
host list, because a target with no rule trivially has no path to an
emulator. The in-house tree and the public tree now agree on what
`make check-all-host` means: 27 gates in both.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAKE = os.environ.get('MAKE', 'make')

#: A recipe naming any of these spawns an emulator, whatever its
#: prerequisites say. The first three reach verilogapple through the
#: supervisor; check_apple2ts drives a SECOND emulator (Apple2TS, under
#: node) and reaches no supervisor at all, so the supervisor-shaped
#: names cannot see it. Without it here the derivation calls the gate
#: emulator-free and demands it join check-all-host, where it would
#: need node, a network clone and a build -- none of which a host sweep
#: is allowed to assume.
SPAWNERS = ('mcp_drive', 'mcp_supervisor', 'MAUX_SUPERVISOR',
            'check_apple2ts')

#: NEEDS NO EMULATOR, BUT STILL CANNOT RUN ALONE. These three read
#: artifacts that OTHER gates build and that make does not know about:
#: the dependency is in the script, not in a prerequisite, so the walk
#: above cannot see it and neither could a reader of the Makefile. Found
#: by running `make check-all-host` on a tree that had only just been
#: built -- all three went red with their own clear messages, which is
#: the only reason this list is short and specific rather than a guess.
#:
#: The exclusions are asserted too: each must still be a gate in the
#: sweep, so one that is renamed or retired shows up here instead of
#: quietly shrinking what check-all-host covers.
NOT_STANDALONE = {
    'check-kernel-images':
        'scans build/MAUXEXTEST.SYSTEM, which only check-ex builds '
        '(the Makefile says so beside CHECK_ALL_SEQ, and this is why '
        'check-ex is in the sweep at all)',
    'check-prodos-version':
        'refuses to report on fewer than 10 images under build/; the '
        'image-building gates put them there',
    'check-volname':
        'same -- it needs 10 boot images before it will call a pass a '
        'pass, and 2 exist after a bare build',
}


def database():
    """make's own rule database: {target: {'pre': [...], 'rec': [...]}}."""
    out = subprocess.run([MAKE, '-pn'], cwd=ROOT, capture_output=True,
                         text=True)
    rules, cur = {}, None
    for line in out.stdout.split('\n'):
        if line.startswith('#') or not line.strip():
            continue
        m = re.match(r'^([^\t=:][^=]*?):($|[^=].*)$', line)
        if m and not line.startswith('\t'):
            for t in m.group(1).split():
                rules.setdefault(t, {'pre': [], 'rec': []})
                rules[t]['pre'].extend(m.group(2).split())
            cur = m.group(1).split()[0]
            continue
        if line.startswith('\t') and cur:
            rules[cur]['rec'].append(line.strip())
    return rules


def value(name):
    """One make variable, expanded by make itself."""
    out = subprocess.run([MAKE, '-f', '-', '-f', 'Makefile', '_print'],
                         cwd=ROOT, text=True, capture_output=True,
                         input=f'_print:\n\t@echo $({name})\n')
    return out.stdout.split()


def needs_emulator(target, rules, supervisor, seen=None):
    """True if reaching `target` reaches a machine. Transitive.

    A target with NO rule answers False, which is right for a
    prerequisite that is just a file on disk and wrong for a gate: an
    absent gate cannot run at all, let alone run without a machine.
    derive() handles that case by name before asking this.
    """
    if seen is None:
        seen = set()
    if target in seen:
        return False
    seen.add(target)
    rule = rules.get(target)
    if rule is None:
        return False
    if supervisor and supervisor in rule['pre']:
        return True
    if any(s in line for line in rule['rec'] for s in SPAWNERS):
        return True
    return any(needs_emulator(p, rules, supervisor, seen)
               for p in rule['pre'])


def derive(rules, supervisor, sequence):
    """Split the sweep into gates that need a machine and gates that do not.

    A gate with no rule in this tree is NEITHER. That is not a corner
    case, it is the published tree: without gates.mk the 59 rig gates
    have no recipe, needs_emulator() answers False for an unknown
    target, and an earlier version of this gate therefore demanded that
    every withheld gate be added to CHECK_HOST_TARGETS -- red, in the
    one tree it was written to keep honest, with 59 lines of nonsense
    advice. Found by building a public clone and running it.
    """
    free, boots, absent = [], [], []
    for t in sequence:
        if t not in rules:
            absent.append(t)
        elif needs_emulator(t, rules, supervisor):
            boots.append(t)
        else:
            free.append(t)
    return [t for t in free if t not in NOT_STANDALONE], boots, absent


def self_test(rules, supervisor, free, boots):
    """The teeth: this gate must be able to tell the two apart."""
    out = []
    if not boots:
        out.append('self-test: NO gate in the sweep was found to need an '
                   'emulator, which cannot be true -- the dependency walk '
                   'is broken, and it would call every gate host-runnable')
    if not free:
        out.append('self-test: EVERY gate was found to need an emulator, '
                   'so check-all-host would be empty')
    # check-boot is the canonical machine gate and check-modules the
    # canonical static one. If either is classified the other way, the
    # walk is measuring something else.
    for t, want in (('check-boot', True), ('check-modules', False),
                    ('check-ascii', False)):
        if t not in rules:
            continue            # check-boot is absent without gates.mk
        got = needs_emulator(t, rules, supervisor)
        if got != want:
            out.append(f'self-test: {t} needs-emulator={got}, expected '
                       f'{want} -- the dependency walk is wrong')
    # A gate that boots a machine must not pass the filter just because
    # its own rule is clean: plant a target that only reaches the
    # supervisor two hops down.
    if supervisor:
        probe = dict(rules)
        probe['_probe_leaf'] = {'pre': [supervisor], 'rec': []}
        probe['_probe_mid'] = {'pre': ['_probe_leaf'], 'rec': []}
        probe['_probe_top'] = {'pre': ['_probe_mid'], 'rec': []}
        if not needs_emulator('_probe_top', probe, supervisor):
            out.append('self-test: a planted two-hop path to the '
                       'supervisor was NOT caught -- the walk is not '
                       'transitive and the host list would include gates '
                       'that boot a machine')
    return out


def main():
    rules = database()
    if not rules:
        print('[check-host-sweep] error: `make -pn` produced no rule '
              'database', file=sys.stderr)
        return 2
    sup = value('MCP_SUPERVISOR')
    supervisor = sup[0] if sup else ''
    # CHECK_ALL_TARGETS, not CHECK_ALL_SEQ: the question is what THIS
    # tree can run, and the two differ by exactly the rig gates in a
    # tree without gates.mk.
    sequence = value('CHECK_ALL_TARGETS')
    declared = value('CHECK_HOST_TARGETS')
    if not sequence:
        print('[check-host-sweep] error: CHECK_ALL_TARGETS is empty',
              file=sys.stderr)
        return 2

    free, boots, absent = derive(rules, supervisor, sequence)
    fails = self_test(rules, supervisor, free, boots)
    # A gate in the host list with no rule would be a sweep that dies on
    # the first target; the sweep list should never name one either.
    for t in declared:
        if t not in rules:
            fails.append(f'CHECK_HOST_TARGETS names {t}, which has no rule '
                         f'in this tree -- `make check-all-host` would die '
                         f'on it')
    if absent:
        fails.append(f'{len(absent)} gate(s) in the sweep have no rule '
                     f'here: {absent[:5]} -- CHECK_ALL_TARGETS should have '
                     f'filtered them out (see CHECK_RIG_TARGETS)')
    # A stale exclusion silently shrinks what check-all-host covers.
    for t in sorted(NOT_STANDALONE):
        if t not in sequence:
            fails.append(f'the NOT_STANDALONE exclusion names {t!r}, which '
                         f'is not in the sweep any more -- drop it, or '
                         f'check-all-host is quietly missing a gate')
        elif needs_emulator(t, rules, supervisor):
            fails.append(f'{t} is excluded as "needs no emulator but not '
                         f'standalone", but it now boots a machine -- the '
                         f'emulator walk already excludes it, so the '
                         f'exclusion is dead weight')
    if fails:
        for f in fails:
            print(f'[check-host-sweep] FAIL: {f}')
        return 1
    print(f'[check-host-sweep] self-test: the walk separates '
          f'{len(boots)} machine gate(s) from {len(free)} toolchain-only '
          f'gate(s), is transitive, and agrees on check-boot/check-modules')

    missing = [t for t in free if t not in declared]
    stale = [t for t in declared if t not in free]
    print(f'[check-host-sweep] {len(free)} of {len(sequence)} sweep gates '
          f'run with no emulator and stand alone; CHECK_HOST_TARGETS '
          f'declares {len(declared)}')
    print(f'[check-host-sweep] {len(NOT_STANDALONE)} gate(s) need no '
          f'emulator but read artifacts another gate builds, each named '
          f'with its reason: {", ".join(sorted(NOT_STANDALONE))}')
    if missing:
        print(f'[check-host-sweep] FAIL: {len(missing)} gate(s) need no '
              f'emulator but are not in CHECK_HOST_TARGETS: {missing} -- '
              f'add them, a public clone can run them')
    if stale:
        print(f'[check-host-sweep] FAIL: {len(stale)} gate(s) in '
              f'CHECK_HOST_TARGETS now reach an emulator: {stale} -- drop '
              f'them, or `make check-all-host` dies on a public clone '
              f'with a build error instead of a test result')
    if missing or stale:
        return 1
    print('[check-host-sweep] PASS: check-all-host is exactly the gates '
          'this tree can run without a machine')
    return 0


if __name__ == '__main__':
    sys.exit(main())
