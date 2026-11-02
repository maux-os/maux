#!/usr/bin/env python3
"""splice_fileio.py -- build the plasm-only FILEIO source.

    splice_fileio.py src/plasma/fileio.pla src/plasma/fileio.frag.pla > out.pla

Replaces each //@INCFB-<NAME>@ marker line of fileio.pla with the matching
section ("//@@ <NAME>") of the snippet file. A marker that is missing, or
one that the snippet has no section for, is an error: the variant must have
every piece or the fallback is half there.
"""
import re
import sys


def sections(text):
    out, cur = {}, None
    for line in text.split('\n'):
        m = re.match(r'//@@ (\w+)$', line)
        if m:
            cur = m.group(1)
            out[cur] = []
        elif cur:
            out[cur].append(line)
    return {k: '\n'.join(v).rstrip('\n') for k, v in out.items()}


def main():
    src = open(sys.argv[1]).read()
    sec = sections(open(sys.argv[2]).read())
    expect = {}
    for line in sec.pop("EXPECT", "").split("\n"):
        if "=" in line and not line.startswith("//"):
            k, v = line.split("=")
            expect[k.strip()] = int(v)
    if set(expect) != set(sec):
        sys.exit(f"splice_fileio: EXPECT counts {sorted(expect)} do not match sections {sorted(sec)}")
    seen = {}
    used = set()
    out = []
    for line in src.split('\n'):
        m = re.match(r'\s*//@INCFB-(\w+)@\s*$', line)
        if m:
            if m.group(1) not in sec:
                sys.exit(f'splice_fileio: no section {m.group(1)}')
            used.add(m.group(1))
            seen[m.group(1)] = seen.get(m.group(1), 0) + 1
            out.append(sec[m.group(1)])
        else:
            out.append(line)
    if used != set(sec):
        sys.exit(f'splice_fileio: markers not found for {sorted(set(sec) - used)}')
    for k, n in expect.items():
        if seen.get(k, 0) != n:
            sys.exit(f'splice_fileio: marker {k} appears {seen.get(k, 0)} time(s), expected {n}')
    sys.stdout.write('\n'.join(out))


main()
