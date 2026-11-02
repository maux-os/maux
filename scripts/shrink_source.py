#!/usr/bin/env python3
"""shrink_source.py -- move mid-file comment blocks out of a module and into
its Apple II readable doc, until the module fits Merlin's source buffer.

    python3 scripts/shrink_source.py src/kernel/sched.s [--apply]

WHY. Real Merlin's source buffer is $0901..$AA00 = 41215 bytes, and it holds
the file being assembled as TEXT (learning:01M051EM2HQ3ZVJTR1W9P3G86J). So a
module's COMMENTS count against the same budget as its code. sched.s was 44432
bytes of source for a few hundred bytes of object -- over the buffer purely on
prose.

This is the operator's 2026-08-16 ruling applied where it now pays twice:
design rationale belongs in text files the machine can read, not in inline
comment essays. scripts/extract_docs.py did the file HEADERS; this does the
blocks in the body, which is where the remaining bulk lives.

WHAT IT WILL NOT DO. It only moves runs of whole-line `*` comments of at least
MIN_LINES, and leaves a pointer naming the doc and the section, so nothing
becomes unfindable. Trailing `code ;comment` annotations are never touched --
those are the ones you actually read while following the code.

Renaming or moving comments cannot change emitted code, so `make check-bytes`
is the proof this ran correctly.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCDIR = os.path.join(ROOT, 'docs', 'a2')
BUFFER = 0xAA00 - 0x0901          # 41215: Merlin's source buffer, exactly
#
# The buffer holds the RESIDENT top-level source AND the PUT file currently
# being read -- not one at a time. So the real per-module budget is the buffer
# less the top-level manifest. Measured the hard way: every module fitting
# 41215 individually still died with 56 MEMORY IN USE, because the 13 KB test
# harness stayed resident while a 34 KB equate file loaded beside it.
MANIFEST_MAX = 4096
MODULE_MAX = 37000                # BUFFER - MANIFEST_MAX, rounded down
MIN_LINES = 8
WIDTH = 64
RULE_RE = re.compile(r'^\s*\*[-=*_]{4,}\s*$')
TREE_PREFIX = {'kernel': 'K', 'liba': 'L', 'bin': 'B', 'test': 'T',
               'inc': 'I'}


def doc_name(path):
    parent = os.path.basename(os.path.dirname(os.path.abspath(path)))
    prefix = TREE_PREFIX.get(parent, 'X')
    stem = re.sub(r'[^A-Za-z0-9]', '', os.path.basename(path).rpartition('.')[0]).upper()
    if path.endswith('.equ'):
        stem += 'E'
    return f'{prefix}.{stem[:15 - len(prefix) - 5]}.TXT'


def blocks(lines, skip_header):
    """Contiguous runs of whole-line comments, excluding the file header."""
    out, cur, start = [], [], 0
    for i, l in enumerate(lines):
        if i < skip_header:
            continue
        if l.lstrip().startswith('*'):
            if not cur:
                start = i
            cur.append(l)
        else:
            if len(cur) >= MIN_LINES:
                out.append((start, len(cur)))
            cur = []
    if len(cur) >= MIN_LINES:
        out.append((start, len(cur)))
    return out


def title_of(block, budget):
    """First real line of the block, trimmed to fit -- at a WORD boundary.

    The budget is what is left of the 64-character line limit after the
    pointer text, so the pointer itself never becomes a new violation. A
    first version hard-coded 52 and produced 73-character pointers ending
    mid-word ("...timer tick, fro"); the line-length gate caught it.
    """
    for l in block:
        if RULE_RE.match(l):
            continue
        t = l.lstrip().lstrip('*').strip()
        if not t:
            continue
        if len(t) <= budget:
            return t
        cut = t[:budget].rsplit(' ', 1)[0]
        return (cut or t[:budget]).rstrip(' ,;:-')
    return 'notes'


def main(argv):
    apply = '--apply' in argv
    budget = MODULE_MAX
    for a in argv:
        if a.startswith('--budget='):
            budget = int(a.split('=')[1])
    paths = [a for a in argv if not a.startswith('--')]
    if not paths:
        print(__doc__.split('\n')[2].strip(), file=sys.stderr)
        return 2

    for path in paths:
        full = os.path.join(ROOT, path)
        lines = open(full, errors='replace').read().split('\n')
        size = sum(len(l) + 1 for l in lines)
        if size <= budget:
            print(f'{path}: {size} bytes, already fits ({budget})')
            continue

        # The header block was handled by extract_docs.py; skip past it.
        hdr = 0
        while hdr < len(lines) and (lines[hdr].lstrip().startswith('*')
                                    or not lines[hdr].strip()):
            hdr += 1

        cand = blocks(lines, hdr)
        cand.sort(key=lambda b: -sum(len(lines[b[0] + k]) + 1
                                     for k in range(b[1])))

        need = size - budget
        chosen, saved = [], 0
        for start, n in cand:
            if saved >= need:
                break
            block = lines[start:start + n]
            cost = sum(len(l) + 1 for l in block)
            # NOT `budget` -- that name holds the module size budget, and
            # shadowing it here made the second file in an argv list shrink
            # against 43 bytes instead of 37000.
            title_budget = WIDTH - len(f'* See {doc_name(path)}: ""')
            pointer = f'* See {doc_name(path)}: "{title_of(block, title_budget)}"'
            saved += cost - (len(pointer) + 1)
            chosen.append((start, n, pointer, block))

        if saved < need:
            print(f'{path}: cannot reach {budget} by comment extraction '
                  f'alone -- {size} bytes, need {need}, only {saved} '
                  f'available in blocks of >= {MIN_LINES} lines. This module '
                  f'needs a real source split.', file=sys.stderr)
            continue

        print(f'{path}: {size} -> {size - saved} bytes '
              f'({len(chosen)} block(s) moved, budget {budget})')
        for start, n, pointer, _ in chosen:
            print(f'    line {start + 1:<5} {n:>3} lines -> {pointer}')

        if not apply:
            continue

        # Rewrite back-to-front so earlier indices stay valid.
        doc_add = []
        for start, n, pointer, block in sorted(chosen, key=lambda c: -c[0]):
            doc_add.append((pointer.split('"')[1], block))
            lines[start:start + n] = [pointer]
        open(full, 'w').write('\n'.join(lines))

        os.makedirs(DOCDIR, exist_ok=True)
        doc = os.path.join(DOCDIR, doc_name(path))
        with open(doc, 'a') as fh:
            for title, block in reversed(doc_add):
                fh.write('\n' + '-' * WIDTH + '\n')
                fh.write(title + '\n')
                fh.write('-' * WIDTH + '\n')
                for l in block:
                    body = l.lstrip()
                    body = body[1:] if body.startswith('*') else body
                    fh.write(body.rstrip()[1:] if body.startswith(' ')
                             else body.rstrip())
                    fh.write('\n')
        print(f'    appended {len(doc_add)} section(s) to docs/a2/{doc_name(path)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
