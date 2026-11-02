#!/usr/bin/env python3
"""measure_wait.py -- docs/WAIT-1.md "Measure first". NOT a gate; not in
check-all.  Notes: docs/WAIT-1-NOTES.md.  Ported from measure_wake.py.

  python3 scripts/measure_wait.py [TREE] [--only NAME ...]

For each workload, bracket every PRC_WAIT_CORE call from its entry to the
end of its scan (the instruction after the 47-slot loop), RAMRD checked so
a process at the same address is not counted, and report call count and
exact entry-to-end-of-scan cycles (min / median / max) beside the command
total (Enter to settled prompt, 10k-cycle observation grain).  A call that
blocks still reaches the end of its scan, so blocking reruns are counted
the way the kernel runs them.

The two bracket addresses are read off the MAUXPLAY listing by SOURCE LINE
(process2.s: the `PRC_WAIT_CORE` label and the line of its `:done`), so the
same script measures the base and the built tree.

Workloads (fixed before any timing, WAIT-1.md step 1):
  nest0     SLEEP-1's loop nest, 144 `:` commands, no background job
  nest1     the same with one `sleep 300 &` running
  pipe      cat /bin/sed | wc -c
  subst     echo $(echo hi)   (echo is a builtin: no reap at all)
  subst2    echo $(ls /bin | wc -l)   (a real $( ) reap)
  make-n    make -n on a one-rule Makefile
  wait3     `cksum /bin/vi > /dev/null & cksum /bin/vi > /dev/null & cksum /bin/vi > /dev/null & wait`

Needs build/play.po and build/MAUXPLAY.SYSTEM_Output.txt.  ASCII only.
"""
import os
import re
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import check_sleep as CS                                   # noqa: E402

ROOT = os.path.dirname(HERE)
SLICE = 10_000

NEST = ('for a in 1 2 3 4 5 6 7 8 9 10 11 12; do '
        'for b in 1 2 3 4 5 6 7 8 9 10 11 12; do :; done; done')


def src_line(tree, rel, pattern):
    """1-based line number of the first line of `rel` matching `pattern`
    AFTER the PRC_WAIT_CORE label."""
    path = os.path.join(tree, rel)
    seen = False
    with open(path, errors='replace') as fh:
        for i, line in enumerate(fh, 1):
            if line.startswith('PRC_WAIT_CORE'):
                seen = True
            elif seen and re.match(pattern, line):
                return i
    raise SystemExit('measure_wait: %r not found after PRC_WAIT_CORE in %s'
                     % (pattern, rel))


def listing_addr(tree, fname, lineno):
    """Address of the listing row for `fname` source line `lineno`."""
    path = os.path.join(tree, 'build', 'MAUXPLAY.SYSTEM_Output.txt')
    pat = re.compile(r'\|\s*\d+\s+\S*%s\s+%d \|\s*(?:Code|Empty)\s*\|'
                     r'[^|]*\|[^|]*\|[^|]*\|\s*00/([0-9A-F]{4})'
                     % (re.escape(fname), lineno))
    with open(path, encoding='ascii', errors='replace') as fh:
        for row in fh:
            m = pat.search(row)
            if m:
                return int(m.group(1), 16)
    raise SystemExit('measure_wait: no listing row for %s:%d'
                     % (fname, lineno))


class Meter:
    def __init__(self, tree):
        self.tree = tree
        self.rig = CS.Rig(tree)
        sym = self.rig.sym
        self.entry = sym['PRC_WAIT_CORE']
        done = src_line(tree, 'src/kernel/process2.s', r':done\b')
        self.end = listing_addr(tree, 'process2.s', done)
        self.rig.c.call_tool('break_set', {'addr': self.entry})
        self.rig.c.call_tool('break_set', {'addr': self.end})

    def close(self):
        self.rig.close()

    def run(self, cmd, human=True):
        """Type `cmd`, press Enter, run to a settled prompt.  Returns
        (per-call cycle list, command total)."""
        r = self.rig
        r.t.wait_prompt('prompt before %r' % cmd)
        if human:
            r.t.type_human(cmd)
        else:
            r.c.call_tool('type', {'text': cmd})
            r.step(200_000)
        c0 = r.cycle()
        r.c.call_tool('type', {'text': '\r'})
        calls, t_e, quiet, total = [], None, 0, None
        while True:
            res = r.c.call_tool('resume', {'max_cycles': SLICE})
            if res.get('hit_breakpoint'):
                quiet = 0
                if r.in_aux():
                    continue
                if res['pc'] == self.entry:
                    t_e = res['cycle']
                elif res['pc'] == self.end and t_e is not None:
                    calls.append(res['cycle'] - t_e)
                    t_e = None
                continue
            if r.prompt():
                quiet += 1
                if quiet >= 3:
                    total = res['cycle'] - c0 - 2 * SLICE
                    return calls, total
            else:
                quiet = 0
            if res['cycle'] - c0 > 200_000_000:
                raise SystemExit('measure_wait: %r: no prompt' % cmd)


def row(name, calls, total):
    n = len(calls)
    if not n:
        print('%-8s calls %4d  total %10d' % (name, n, total))
        return
    print('%-8s calls %4d  per call min %6d med %6d max %6d  sum %9d'
          '  total %10d' % (name, n, min(calls), int(statistics.median(calls)),
                            max(calls), sum(calls), total))


def main():
    args = sys.argv[1:]
    only = []
    if '--only' in args:
        i = args.index('--only')
        only = args[i + 1:]
        args = args[:i]
    tree = os.path.abspath(args[0]) if args else ROOT
    m = Meter(tree)
    want = (lambda n: not only or n in only)
    try:
        m.rig.t.wait_prompt('boot')
        if want('nest0'):
            row('nest0', *m.run(NEST))
        if want('pipe'):
            row('pipe', *m.run('cat /bin/sed | wc -c'))
        if want('subst'):
            row('subst', *m.run('echo $(echo hi)'))
        if want('subst2'):
            row('subst2', *m.run('echo $(ls /bin | wc -l)'))
        if want('make-n'):
            m.run("printf 'a:\\n\\techo hi\\n' > Makefile")
            row('make-n', *m.run('make -n'))
        if want('nest1'):
            m.run('sleep 300 &')
            row('nest1', *m.run(NEST))
            m.run('kill %1')
        if want('wait3'):
            row('wait3', *m.run('cksum /bin/vi > /dev/null & cksum /bin/vi > /dev/null & cksum /bin/vi > /dev/null & wait'))
    finally:
        m.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
