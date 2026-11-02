#!/usr/bin/env python3
"""Boundary constants, read out of the headers the code itself reads.

docs/E2E.md sec 5 is the ruling this file implements:

    Every constant that appears in a `check_*` ratchet is a boundary
    generator.  When someone raises `MLI_IOBUF_CNT` or `LINEMAX`, the
    generator picks it up from the same header the code does, rather
    than from a number copied into a test.

So there are **no numeric literals for tree limits below**.  Every limit
the corpus generator uses is parsed out of the `.equ`/`.s` file that
defines it for the assembler, by the same left-to-right expression rule
merlin32 and real Merlin-8 use.  A raised limit changes the corpus on the
next run with no edit here; a *renamed* symbol makes this module raise,
which is the loud failure the copied-constant version could not give.

THE ONE EXCEPTION, stated rather than hidden: `PAGE` (256).  The
`255/256/257` boundary that produced 2026-08-23's `sort -u` and `diff`
bugs is the 6502's Y register wrapping, not a tree constant -- there is
no header to read it from, because it is a property of the CPU.  It is
declared here as ARCH, with that reason, and is the only number in the
file that is not parsed from source.

Merlin expression rules honoured by `_eval`:
  * `$xx` hex, `%..` binary, bare decimal, `'c'` character.
  * `+ - * /` evaluated STRICTLY LEFT TO RIGHT, no precedence -- src/bin/
    sh.s:42 relies on exactly this ("`LINEMAX+1/2` is 127 to one and ...").
  * unary `<` / `>` = low / high byte of the rest of the expression.
Anything else raises rather than guessing.
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --- the one non-parsed number, and why ---------------------------------
#: The 6502 index-register wrap.  Not in any header: it is the CPU's, and
#: it is the boundary docs/E2E.md sec 5 lists first ("the `Y`-wrap boundary
#: that produced today's bugs").
PAGE = 256

_EQU_RE = re.compile(
    r'^([A-Za-z_][A-Za-z0-9_.]*)\s+(?:equ|EQU|=)\s+([^;]*?)\s*$')


def _strip_comment(line):
    """Merlin comments: `*` in column 1, or `;` after code."""
    if not line or line[0] in '*;':
        return ''
    out = []
    in_ch = None
    for ch in line:
        if in_ch:
            out.append(ch)
            if ch == in_ch:
                in_ch = None
            continue
        if ch in "'\"":
            in_ch = ch
            out.append(ch)
            continue
        if ch == ';':
            break
        out.append(ch)
    return ''.join(out).rstrip()


def _tokenize(expr):
    toks, i = [], 0
    while i < len(expr):
        c = expr[i]
        if c.isspace():
            i += 1
        elif c == '$':
            j = i + 1
            while j < len(expr) and expr[j] in '0123456789abcdefABCDEF':
                j += 1
            toks.append(('num', int(expr[i + 1:j], 16)))
            i = j
        elif c == '%':
            j = i + 1
            while j < len(expr) and expr[j] in '01':
                j += 1
            toks.append(('num', int(expr[i + 1:j], 2)))
            i = j
        elif c.isdigit():
            j = i
            while j < len(expr) and expr[j].isdigit():
                j += 1
            toks.append(('num', int(expr[i:j])))
            i = j
        elif c == "'":
            toks.append(('num', ord(expr[i + 1])))
            i += 3 if i + 2 < len(expr) and expr[i + 2] == "'" else 2
        elif c in '+-*/':
            toks.append(('op', c))
            i += 1
        elif c in '<>':
            toks.append(('unary', c))
            i += 1
        elif c.isalpha() or c == '_':
            j = i
            while j < len(expr) and (expr[j].isalnum() or expr[j] in '_.'):
                j += 1
            toks.append(('sym', expr[i:j]))
            i = j
        else:
            raise ValueError(f'unsupported character {c!r} in {expr!r}')
    return toks


def _eval(expr, syms):
    """Merlin's strictly-left-to-right evaluation, no precedence."""
    toks = _tokenize(expr)
    if not toks:
        raise ValueError(f'empty expression {expr!r}')
    unary = None
    if toks[0][0] == 'unary':
        unary, toks = toks[0][1], toks[1:]
    acc, i = None, 0
    while i < len(toks):
        kind, val = toks[i]
        if kind == 'num':
            operand = val
        elif kind == 'sym':
            if val not in syms:
                raise KeyError(f'undefined symbol {val!r} in {expr!r}')
            operand = syms[val]
        else:
            raise ValueError(f'unexpected {kind} {val!r} in {expr!r}')
        if acc is None:
            acc = operand
        i += 1
        if i < len(toks):
            okind, op = toks[i]
            if okind != 'op':
                raise ValueError(f'expected operator in {expr!r}')
            i += 1
            if i >= len(toks):
                raise ValueError(f'trailing operator in {expr!r}')
            nkind, nval = toks[i]
            rhs = nval if nkind == 'num' else syms[nval]
            acc = {'+': lambda a, b: a + b,
                   '-': lambda a, b: a - b,
                   '*': lambda a, b: a * b,
                   '/': lambda a, b: a // b}[op](acc, rhs)
            i += 1
    if unary == '<':
        acc &= 0xFF
    elif unary == '>':
        acc = (acc >> 8) & 0xFF
    return acc


def parse_equs(*relpaths):
    """Parse `NAME equ EXPR` out of merlin sources, in the order given.

    Later files see earlier files' symbols (that is how ARG_MAX, defined
    in mm.procbnk2.equ as `LOAD_BASE-PRC_ARGV_STR`, resolves against
    mm.procbank.equ's LOAD_BASE).  A line whose expression will not
    evaluate -- a forward reference, an operator this evaluator does not
    model -- is SKIPPED rather than guessed at; `limit()` below then
    raises on a symbol nobody could parse, which is the loud failure.
    """
    syms = {}
    for rel in relpaths:
        with open(os.path.join(ROOT, rel), 'r', errors='replace') as fh:
            for raw in fh:
                code = _strip_comment(raw.rstrip('\n'))
                m = _EQU_RE.match(code)
                if not m:
                    continue
                name, expr = m.group(1), m.group(2).strip()
                try:
                    syms[name] = _eval(expr, syms)
                except (KeyError, ValueError, IndexError):
                    continue
    return syms


#: Kernel/process limits.  Order matters: procbank.equ defines LOAD_BASE,
#: which procbank2.equ's ARG_MAX derives from.
#:
#: `inc/mli.equ` is added here (not `inc/mm.mli.equ`, a
#: DIFFERENT file of the same near-name that holds hardware addresses) --
#: it is where `MLI_PTH_MAXLN` (the 64-char MLI pathname fence find.s/
#: du.s's BUILDCHILD enforces, docs/E2E.md sec 5's own "ProDOS: 15-char
#: names, 512-byte blocks, directory entry counts" boundary family) is
#: declared.  T4/E3 (find+du), scripts/e2e_fs_walk.py.
#: `inc/mm.annex.equ` added 2026-08-27 for `PCB_COUNT`, which
#: scripts/check_play.py needs to bound a pid: a pid IS a RamWorks bank
#: number, so `0 < pid < PCB_COUNT` is the only honest range check, and
#: copying 48 into the gate is what this module exists to prevent. It
#: shares no symbol name with the five files above (checked, 40 symbols,
#: zero collisions), so it cannot shadow an existing limit.
KERNEL = parse_equs(
    'inc/mm.procbank.equ',
    'inc/mm.procbnk2.equ',
    'inc/mm.mlibuf.equ',
    'inc/mm.mli.equ',
    'inc/mm.annex.equ',
    'inc/mm.annex2.equ',
    'inc/mli.equ',
)

#: Per-program limits, namespaced by program -- `MAXLINES` means one thing
#: in diff.s and another in comm.s, so they must not share a table.
#:
#: 'find'/'du' added for T4/E3 (scripts/e2e_fs_walk.py): FIND_MAXDEP and
#: DU_MAXDEP are each program's own explicit-depth-stack ceiling (see
#: those files' own headers -- readdir.s is a directory-fd singleton, so
#: descent uses close-on-descend/reopen-and-replay rather than recursion),
#: read here rather than copied, per docs/E2E.md sec 5.
def _unit_files(prog):
    """A program's manifest plus every same-directory module it `put`s.

    S9 (2026-08-28) split ed.s and sh.s into manifests over put modules,
    and an equate can now live in any of them -- EXPBUFLEN moved out of
    sh.s itself and this table went blind to it, failing check-play,
    check-play80n and check-vc at import. Derived from the put lines
    rather than listed, so the next split needs no edit here. liba puts
    carry a path and are already covered by the shared tables above.
    """
    files = [f'src/bin/{prog}.s']
    try:
        with open(os.path.join(ROOT, files[0]), errors='replace') as fh:
            for raw in fh:
                m = re.match(r'\s+put\s+([^/\s;]+\.s)\s*(;.*)?$',
                             raw.rstrip('\n'))
                if m:
                    files.append('src/bin/' + m.group(1))
    except OSError:
        pass
    return files


PROGRAM = {}
for _prog in ('sh', 'ed', 'sort', 'diff', 'tr', 'uniq', 'comm', 'wc', 'od',
              'cmp', 'sum', 'grep', 'find', 'du'):
    PROGRAM[_prog] = parse_equs(*_unit_files(_prog))


def limit(prog, name):
    """A program's declared limit, or a loud KeyError naming the file."""
    table = PROGRAM[prog]
    if name not in table:
        raise KeyError(
            f'{name} is not declared in src/bin/{prog}.s or any module '
            f'it puts -- docs/E2E.md sec 5 '
            f'forbids copying the number in here; find where the code reads '
            f'it now, or the symbol was renamed')
    return table[name]


def kernel_limit(name):
    if name not in KERNEL:
        raise KeyError(f'{name} is not declared in inc/mm.*.equ')
    return KERNEL[name]


def summary():
    """The limits this corpus is generated from, for the gate's log."""
    rows = [
        ('ARCH', 'PAGE (6502 Y wrap)', PAGE),
        ('inc/mm.procbnk2.equ', 'ARG_MAX', kernel_limit('ARG_MAX')),
        ('inc/mm.mlibuf.equ', 'MLI_IOBUF_CNT',
         kernel_limit('MLI_IOBUF_CNT')),
        ('inc/mm.mlibuf.equ', 'MLI_IBF_SIZE',
         kernel_limit('MLI_IBF_SIZE')),
        ('src/bin/sh.s', 'LINEMAX', limit('sh', 'LINEMAX')),
        ('src/bin/sh.s', 'MAXCMD', limit('sh', 'MAXCMD')),
        ('src/bin/sh.s', 'MAXARGV', limit('sh', 'MAXARGV')),
    ]
    return rows


if __name__ == '__main__':
    for where, name, value in summary():
        print(f'{name:<22} = {value:<8} ({where})')
    print()
    for prog in sorted(PROGRAM):
        keys = sorted(PROGRAM[prog])
        print(f'{prog:6} {len(keys):3} equs: {" ".join(keys[:14])}')
