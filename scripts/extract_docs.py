#!/usr/bin/env python3
"""extract_docs.py -- move long design-rationale comment blocks out of source
and into Apple II readable text files, leaving a pointer behind.

OPERATOR DECISION (2026-08-16): stop carrying elaborate inline documentation
in source comments. Write the docs to text files the Apple II can read, and
refer to them from the source.

The immediate driver is real Merlin's 64-character line limit
(learning:01M04SAJTJAYXCR3YNFW313FMZ): ~960 over-long lines survived automated
rewrapping because they are hanging-indent prose and tables that line-wrapping
destroys. But the deeper point stands on its own -- src/kernel/bankcopy.s
carried 311 lines of header essay before its first line of code.

KEY REALISATION: 64 characters is an ASSEMBLER constraint, not a display one.
Once the content lives in a text file, tables and diagrams can keep their
natural width; they only have to be readable. So this moves content rather
than mangling it.

Output format:
  * plain ASCII, one file per source module, in docs/a2/
  * ProDOS-legal names: <= 15 chars, start with a letter, A-Z 0-9 and '.'
  * prose reflowed to 64 columns; indented/tabular lines kept verbatim
  * no markdown -- these are read on the machine, not on GitHub

Usage:  python3 scripts/extract_docs.py [--apply] SOURCE...
"""
import os
import re
import sys
import textwrap

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCDIR = os.path.join(ROOT, 'docs', 'a2')
WIDTH = 64
RULE_RE = re.compile(r'^\s*\*[-=*_]{4,}\s*$')
def title_extent(block):
    """How much of the header block is the module's TITLE paragraph.

    Keeping a fixed number of lines cuts mid-sentence and leaves the orphaned
    remainder as the doc's first line. The title is the run up to the first
    blank comment line, so split there instead.
    """
    i = 0
    while i < len(block) and RULE_RE.match(block[i]):
        i += 1
    while i < len(block):
        s = block[i].lstrip()
        if s == '' or (s.startswith('*') and not s[1:].strip()):
            break
        i += 1
    return i


# One letter per source tree, because stems collide across them: mli.s exists
# in BOTH src/kernel and src/liba, and inc/mli.equ makes three. Without a
# prefix all three become MLI.TXT and two are silently lost.
TREE_PREFIX = {'kernel': 'K', 'liba': 'L', 'bin': 'B', 'test': 'T',
               'inc': 'I'}


def prodos_name(src_path):
    """ProDOS-legal doc name: <=15 chars, starts with a letter, A-Z 0-9 '.'"""
    parent = os.path.basename(os.path.dirname(os.path.abspath(src_path)))
    prefix = TREE_PREFIX.get(parent, 'X')
    base = os.path.basename(src_path)
    stem, _, ext = base.rpartition('.')
    stem = re.sub(r'[^A-Za-z0-9]', '', stem).upper()
    if ext.lower() == 'equ':
        stem += 'E'
    budget = 15 - len(prefix) - 1 - 4        # prefix + '.' + name + '.TXT'
    return prefix + '.' + stem[:budget] + '.TXT'


def header_extent(lines):
    """Index of the first non-comment, non-blank line."""
    i = 0
    while i < len(lines) and (lines[i].lstrip().startswith('*')
                              or not lines[i].strip()):
        i += 1
    return i


def to_doc(comment_lines):
    """Strip `*` prefixes and reflow prose, keeping structured lines as-is."""
    out, para = [], []

    def flush():
        if para:
            out.extend(textwrap.wrap(' '.join(para), WIDTH))
            para.clear()

    for raw in comment_lines:
        if RULE_RE.match(raw):
            flush()
            out.append('-' * WIDTH)
            continue
        s = raw.lstrip()
        body = s[1:] if s.startswith('*') else s
        if body.startswith(' '):
            body = body[1:]
        if not body.strip():
            flush()
            out.append('')
            continue
        # Anything with column structure keeps its own shape.
        structured = (body[:1] in (' ', '\t')
                      or re.search(r'\S {2,}\S', body)
                      or re.search(r'[|+]{2,}|\+--', body))
        if structured:
            flush()
            out.append(body.rstrip())
        else:
            para.append(body.strip())
    flush()
    while out and not out[0].strip():
        out.pop(0)
    while out and not out[-1].strip():
        out.pop()
    return out


def process(path, apply):
    lines = open(path, errors='replace').read().split('\n')
    end = header_extent(lines)
    block = lines[:end]
    long_lines = sum(1 for l in block if len(l) > WIDTH)
    if end < 12 or long_lines == 0:
        return None

    doc = prodos_name(path)
    head = title_extent(block)
    body = to_doc(block[head:])
    if not body:
        return None

    kept = [l for l in block[:head]]
    kept.append(f'* Full design notes: {doc} (docs/a2/)')
    kept.append('*' + '-' * (WIDTH - 1))
    kept.append('')
    new = kept + lines[end:]

    if apply:
        os.makedirs(DOCDIR, exist_ok=True)
        title = os.path.basename(path)
        with open(os.path.join(DOCDIR, doc), 'w') as fh:
            fh.write(f'{title} -- design notes\n')
            fh.write('=' * WIDTH + '\n')
            fh.write('Extracted from the source header so the source stays\n')
            fh.write('assemblable by real Merlin (64-char line limit).\n\n')
            fh.write('\n'.join(body) + '\n')
        open(path, 'w').write('\n'.join(new))
    return doc, end - head, long_lines


def main(argv):
    apply = '--apply' in argv
    paths = [a for a in argv if not a.startswith('--')]
    moved = 0
    for path in paths:
        r = process(path, apply)
        if r:
            doc, n, longn = r
            print(f'  {path:<26} -> docs/a2/{doc:<14} '
                  f'{n:>4} lines moved ({longn} over limit)')
            moved += longn
    print(f'{"APPLIED" if apply else "DRY RUN"}: {moved} over-long lines '
          f'relocated to Apple II readable docs')
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
