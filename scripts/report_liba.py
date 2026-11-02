#!/usr/bin/env python3
"""What each program pays liba, and how much of it is never reached.

`make report-liba`.  INFORMATIONAL, like report_volumes.py -- it never
fails a build, because there is nothing here to ratchet yet: the waste it
measures is not a defect, it is the documented cost of `put` granularity
(docs/REL-LIBA-SPIKE.md).

WHY IT EXISTS.  The spike proved on real hardware that Merlin's linker
includes WHOLE MODULES and drops nothing (learning:01M04GKF7RA8M22WQ9AW794RDY),
so the inclusion boundary -- today's `put` and tomorrow's REL alike -- is
the FILE.  Its step-4 table measured what that costs per util in
2026-08-18 and its policy says to split a liba file "when a consumer's
byte budget demands it -- measure first".  This is that measurement,
mechanised, because the 2026-08-18 table went stale within days (`echo`
stopped linking num.s and the table still lists 133 dead bytes for it).

METHOD, and its two honest limits:

  * Bytes come from merlin32's own `-v1` listing (build/<u>.bin_Output.txt),
    attributed to the top-level label they fall under.  `dum`/`dend`
    arenas are EXCLUDED -- the listing prints a Size for a `ds` inside
    one, but a dummy section emits no image bytes, and counting
    SIO_STAGE/RD_DIRBUF as text overstates liba's cost by ~1 KB.
  * Reachability is a call graph over operand identifiers, rooted at
    every label the program's OWN (non-liba) files define.  So it
    answers "does any of this program's code, transitively, name this
    routine" -- not "does it execute".  A routine reached only through
    a computed jump would be reported dead; liba has none today, and
    the two `jmp (ptr)` sites in src/bin are program-local.

Read the output as an upper bound on what per-routine linking could
save, not as a promise.
"""
import collections
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')
BINSRC = os.path.join(ROOT, 'src', 'bin')
MERLIN32 = os.environ.get('MERLIN32', 'merlin32')

#: The whole shipped fleet, in Makefile UTILS order.
UTILS = ['echo', 'cat', 'ls', 'cp', 'rm', 'sh', 'ed', 'grep', 'wc', 'mkdir',
         'mv', 'pwd', 'ps', 'as', 'ld', 'nm', 'du', 'df', 'file', 'find',
         'chmod', 'date', 'sum', 'od', 'tail', 'tee', 'tr', 'uniq', 'sort',
         'comm', 'cmp', 'diff', 'sed', 'expr']


def listing_path(util):
    return os.path.join(BUILD, f'{util}.bin_Output.txt')


def ensure_listing(util):
    """merlin32 writes the listing beside the binary under `-v1`.  The
    ordinary build does not pass it, so ask for one here; the emitted
    binary is byte-identical either way (the flag only adds the dump)."""
    src = os.path.join(BINSRC, f'{util}.s')
    if not os.path.exists(src):
        return None
    out = listing_path(util)
    if os.path.exists(out) and os.path.getmtime(out) > os.path.getmtime(src):
        return out
    r = subprocess.run([MERLIN32, '-v1', BINSRC, f'{util}.s'],
                       cwd=BINSRC, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    junk = os.path.join(BINSRC, '_FileInformation.txt')
    if os.path.exists(junk):
        os.remove(junk)
    if r.returncode != 0 or not os.path.exists(out):
        return None
    return out


def is_liba(path):
    return path is not None and path.endswith('.s') and 'liba/' in path


def parse(path):
    """-> (bytes per (file,label), label -> labels it names, label -> file)"""
    sizes = collections.Counter()
    edges = collections.defaultdict(set)
    owner = {}
    cur_file = cur_label = None
    in_dum = False
    for raw in open(path, errors='replace'):
        parts = raw.split('|')
        if len(parts) < 8:
            continue
        fileinfo, ltype, size, src = (parts[1], parts[2].strip(),
                                      parts[5], parts[7])
        if src.startswith(' '):
            src = src[1:]                  # the listing indents column 8
        m = re.match(r'\s*\d+\s+(\S+)\s+\d+\s*$', fileinfo)
        if m and m.group(1) != cur_file:
            cur_file, cur_label = m.group(1), None
        try:
            n = int(size.strip())
        except ValueError:
            n = 0
        if re.match(r'\s*(\S+\s+)?dum\b', src.lower()):
            in_dum = True
        if re.match(r'\s*(\S+\s+)?dend\b', src.lower()):
            in_dum = False
        if in_dum:
            n = 0
        if ltype == 'Comment' or src.startswith('*'):
            continue
        # A label alone on its line (BASE_HI_TABLE, SIO_FLUSHALL) owns
        # what follows it just as much as one with an opcode beside it.
        # merlin32 types such a row `Empty`, so the label test has to
        # run BEFORE the empty-row skip: filing the next line's bytes
        # under the PREVIOUS label is how an `equ` came to look like 8
        # bytes of dead table in this report's own first run.
        m = re.match(r'([A-Z_][A-Z0-9_]*)(?:\s|$)', src.rstrip())
        if m:
            cur_label = m.group(1)
            owner.setdefault(cur_label, cur_file)
        if cur_label is None:
            continue
        sizes[(cur_file, cur_label)] += n
        body = src.split(';', 1)[0]
        m2 = re.match(r'(?:[A-Za-z_:][A-Za-z0-9_.]*)?\s+[a-z]{2,6}\s+(.*)',
                      body)
        if m2:
            for tok in re.findall(r'[A-Z_][A-Z0-9_]*', m2.group(1)):
                if tok != cur_label:
                    edges[cur_label].add(tok)
    return sizes, edges, owner


def measure(util):
    path = ensure_listing(util)
    if path is None:
        return None
    sizes, edges, owner = parse(path)
    seen = set()
    stack = [lbl for lbl, f in owner.items() if not is_liba(f)]
    while stack:
        lbl = stack.pop()
        if lbl in seen:
            continue
        seen.add(lbl)
        stack.extend(edges.get(lbl, ()))
    total = unreached = 0
    rows = []
    for (f, lbl), n in sizes.items():
        if not is_liba(f) or not n:
            continue
        total += n
        if lbl not in seen:
            unreached += n
            rows.append((n, os.path.basename(f), lbl))
    return total, unreached, sorted(rows, reverse=True)


def main():
    wanted = sys.argv[1:] or UTILS
    print('[report-liba] liba bytes per program, and how much of it no '
          'program code names')
    print('[report-liba] method: merlin32 -v1 listings, dum arenas '
          'excluded, reachability from the program\'s own labels')
    print(f'{"util":8} {"liba B":>7} {"unreached":>10} {"%":>4}  '
          f'top unreached routines')
    grand = grand_dead = 0
    worst = collections.Counter()
    for util in wanted:
        got = measure(util)
        if got is None:
            print(f'{util:8} {"--":>7} (no listing)')
            continue
        total, unreached, rows = got
        grand += total
        grand_dead += unreached
        for n, f, lbl in rows:
            worst[f'{f}:{lbl}'] += n
        head = ', '.join(f'{lbl} {n}B' for n, _f, lbl in rows[:3])
        pct = unreached * 100 // total if total else 0
        print(f'{util:8} {total:7} {unreached:10} {pct:3}%  {head}')
    print(f'\n[report-liba] fleet total {grand} B of liba text, '
          f'{grand_dead} B unreached '
          f'({grand_dead * 100 // max(grand, 1)}%)')
    print('[report-liba] most expensive unreached routines, summed over '
          'every program that carries them:')
    for name, n in worst.most_common(8):
        print(f'   {n:6} B  {name}')
    print('[report-liba] splitting a liba file is what recovers these '
          '(docs/REL-LIBA-SPIKE.md policy 2) -- the file is the '
          'inclusion boundary, under put today and REL later.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
