#!/usr/bin/env python3
"""rewrap_comments.py -- bring source lines under real Merlin's 64-character
limit (learning:01M04SAJTJAYXCR3YNFW313FMZ) WITHOUT changing an emitted byte
and without damaging the prose.

Scope is deliberately narrow. It handles only the two MECHANICAL categories:

  1. Banner rules  `*--------...`   truncated to the limit. Zero judgment.
  2. `code ;comment` lines whose CODE fits: the comment is wrapped onto
     continuation lines aligned under the ORIGINAL comment column, which is
     the style this tree already uses.

It deliberately does NOT touch:

  * prose comment blocks -- correct handling means reflowing whole PARAGRAPHS,
    not lines. Wrapping them individually turns an 79-char line into 64 chars
    plus a ragged 15-char orphan and makes good documentation unreadable. A
    first attempt did exactly that and was reverted.
  * preformatted comments -- memory maps, tables, ASCII diagrams and code
    samples live inside `*` blocks here. Reflowing those destroys them, and
    telling prose from a table reliably is judgment, not a regex.
  * code-only long lines.

Everything it skips is reported, so the remainder is visible rather than
silently left. Comments cannot affect object code, so a rebuild after this
must be byte-identical -- that is the check that makes it safe.

Usage:  python3 scripts/rewrap_comments.py [--apply] PATH...
"""
import re
import sys
import textwrap

LIMIT = 64
RULE_RE = re.compile(r'^(\s*)\*([-=*_]{4,})\s*$')
BANNER_TEXT_RE = re.compile(r'^(\s*)\*\s*([-=]{3,})\s*(.*?)\s*[-=]{3,}\s*$')
CONT_RE = re.compile(r'^(\s+);(.*)$')          # aligned comment continuation


def rewrap_line(line):
    if len(line) <= LIMIT:
        return [line], None

    m = RULE_RE.match(line)
    if m:
        indent, fill = m.group(1), m.group(2)[0]
        return [indent + '*' + fill * (LIMIT - len(indent) - 1)], None

    # `* ==== Section title ==========` : keep the title, trim the fill.
    m = BANNER_TEXT_RE.match(line)
    if m:
        indent, opener, title = m.group(1), m.group(2), m.group(3).rstrip()
        head = f'{indent}* {opener} {title} '
        if len(head) < LIMIT:
            return [head + opener[0] * (LIMIT - len(head))], None
        return [head.rstrip()[:LIMIT]], None

    if line.lstrip().startswith('*'):
        return [line], 'prose/preformatted comment'

    m = CONT_RE.match(line)
    if m:
        # A pure continuation line: keep its own indent, wrap at it. The bug
        # that mangled inc/memmap.equ was treating these as `code ;cmt`
        # with empty code, which flattened them to column 1.
        indent, text = m.group(1), m.group(2)
        width = LIMIT - len(indent) - 1
        if width < 12:
            return [line], 'continuation indent too deep'
        return [indent + ';' + p
                for p in textwrap.wrap(text.strip(), width)], None

    if ';' in line:
        code, _, comment = line.partition(';')
        if code.count('"') % 2 or code.count("'") % 2:
            return [line], 'semicolon inside a string literal'
        code_r = code.rstrip()
        if len(code_r) > LIMIT:
            return [line], 'code alone exceeds the limit'
        col = len(code)                       # keep the original column
        width = LIMIT - col - 1
        if width < 12:
            col = max(len(code_r) + 1, LIMIT - 30)
            width = LIMIT - col - 1
        if width < 12:
            return [line], 'no room for a comment column'
        parts = textwrap.wrap(comment.strip(), width)
        if not parts:
            return [line], 'empty comment'
        out = [code_r + ' ' * (col - len(code_r)) + ';' + parts[0]]
        out += [' ' * col + ';' + p for p in parts[1:]]
        return out, None

    return [line], 'code-only long line'


PLAIN_RE = re.compile(r'^\s*\*\s?(\S.*)$')


def is_plain_prose(body):
    """True if a comment line is ordinary prose, safe to reflow.

    Conservative by design. This tree keeps memory maps, register tables,
    ASCII diagrams and code samples inside `*` comment blocks, and reflowing
    any of those destroys them. Anything with column structure -- runs of
    internal spaces, address columns, box/table punctuation, a leading indent
    that implies alignment -- is treated as preformatted and left alone. A
    false "preformatted" only means a line stays long; a false "prose"
    silently wrecks a diagram, so the asymmetry is deliberate.
    """
    if not body.strip():
        return False
    if body[:1] in (' ', '\t'):            # extra indent => aligned/nested
        return False
    if re.search(r'\S {2,}\S', body):      # internal column gap
        return False
    if re.search(r'[|+]{2,}|[-=]{6,}|\+--', body):
        return False
    if re.search(r'\$[0-9A-Fa-f]{2,4}\s{2,}', body):
        return False
    if body.count('$') >= 3:               # address/table-ish
        return False
    return True


def reflow_comment_paragraph(lines):
    """Reflow the PLAIN runs inside a comment block.

    An earlier version required every line in the block to be plain prose and
    declined otherwise -- so a twenty-line explanation containing one table row
    was left entirely alone. Most of the residue after the first pass was
    exactly that. Now the block is split at structured lines: plain runs get
    reflowed, structured lines are emitted verbatim, and the block is only
    declined if nothing in it changed.
    """
    out, run, indent = [], [], None

    def flush():
        if not run:
            return
        prefix = (indent or '') + '* '
        width = LIMIT - len(prefix)
        if width < 24:
            out.extend(run_raw)
        else:
            out.extend(prefix + p
                       for p in textwrap.wrap(' '.join(run), width))
        run.clear()
        run_raw.clear()

    run_raw = []
    for l in lines:
        m = PLAIN_RE.match(l)
        ind = l[:len(l) - len(l.lstrip())]
        if (m and not RULE_RE.match(l) and is_plain_prose(m.group(1))
                and (indent is None or ind == indent)):
            indent = ind
            run.append(m.group(1).strip())
            run_raw.append(l)
        else:
            flush()
            out.append(l)
    flush()
    if out == lines or not any(len(l) > LIMIT for l in lines):
        return None
    return out


def rewrap_block(code_line, continuations):
    """Reflow a `code ;comment` line together with the aligned `;` lines that
    follow it, as ONE paragraph.

    Doing these per-line is what made the first attempt ragged: a 79-char
    continuation became 64 chars plus a 15-char orphan, so a tidy block turned
    into "HALF this," sitting alone on a line. They are one sentence; reflow
    them as one.
    """
    code, _, first = code_line.partition(';')
    if code.count('"') % 2 or code.count("'") % 2:
        return None
    code_r = code.rstrip()
    if len(code_r) > LIMIT:
        return None
    col = len(code)
    width = LIMIT - col - 1
    if width < 12:
        col = max(len(code_r) + 1, LIMIT - 30)
        width = LIMIT - col - 1
    if width < 12:
        return None
    text = ' '.join([first.strip()] + [c.strip() for c in continuations])
    parts = textwrap.wrap(text, width)
    if not parts:
        return None
    out = [code_r + ' ' * (col - len(code_r)) + ';' + parts[0]]
    out += [' ' * col + ';' + p for p in parts[1:]]
    return out


def main(argv):
    apply = '--apply' in argv
    prose = '--prose' in argv
    paths = [a for a in argv if not a.startswith('--')]
    changed = 0
    skipped = {}
    for path in paths:
        src = open(path, errors='replace').read().split('\n')
        out = []
        i = 0
        while i < len(src):
            line = src[i]
            # A code line with a trailing comment, plus any aligned `;`
            # continuations, is one paragraph.
            if (';' in line and not line.lstrip().startswith('*')
                    and not CONT_RE.match(line)):
                j = i + 1
                cont = []
                while j < len(src) and CONT_RE.match(src[j]):
                    cont.append(CONT_RE.match(src[j]).group(2))
                    j += 1
                block = [line] + src[i + 1:j]
                if any(len(b) > LIMIT for b in block):
                    repl = rewrap_block(line, cont)
                    if repl is not None:
                        changed += sum(1 for b in block if len(b) > LIMIT)
                        out.extend(repl)
                        i = j
                        continue
            # A run of `*` comment lines is a paragraph; reflow as a unit.
            if prose and line.lstrip().startswith('*') and not RULE_RE.match(line):
                j = i
                while (j < len(src) and src[j].lstrip().startswith('*')
                       and not RULE_RE.match(src[j])
                       and src[j].rstrip() not in ('*', ' *')):
                    j += 1
                para = src[i:j]
                if any(len(x) > LIMIT for x in para):
                    repl = reflow_comment_paragraph(para)
                    if repl is not None:
                        changed += sum(1 for x in para if len(x) > LIMIT)
                        out.extend(repl)
                        i = j
                        continue
                    skipped['preformatted comment block'] = \
                        skipped.get('preformatted comment block', 0) + 1
                if j > i:
                    out.extend(para)
                    i = j
                else:
                    # A blank `*` separator: the paragraph scan stops ON it,
                    # so emit it verbatim and step past. Without this the
                    # separators vanish and adjacent paragraphs merge.
                    out.append(line)
                    i += 1
                continue
            repl, why = rewrap_line(line)
            if repl != [line]:
                changed += 1
            if why:
                skipped[why] = skipped.get(why, 0) + 1
            out.extend(repl)
            i += 1
        if apply:
            open(path, 'w').write('\n'.join(out))
    print(f'{"APPLIED" if apply else "DRY RUN"}: {changed} lines rewrapped')
    for why, n in sorted(skipped.items(), key=lambda kv: -kv[1]):
        print(f'   left alone: {n:>5}  {why}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
