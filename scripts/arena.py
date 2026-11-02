#!/usr/bin/env python3
"""arena.py -- derive a converted src/bin program's $A5-poison span, so
nobody ever hand-labels its arena end again (docs/STICKY.md sec
PLACEHOLDER, stream T2, `learning:01M0M9R7RT22JEPP2R0Y6J9MBX`).

WHAT A "CONVERTED" PROGRAM IS (docs/STICKY.md sec 21/25/26/28). Its
scratch storage lives in a `dum LIBA_BSSEND` / `dend` block instead of
emitted `ds` bytes -- uncleared, and safe only because every cell in
it is written before it is read. Proving that claim means filling the
whole block with $A5 before the program runs and requiring identical
output; to do that you need the block's START and END addresses.

TODAY, SIX PROGRAMS SPELL THEIR OWN END AS A HAND-WRITTEN LABEL:
`CAT_BSSEND`, `LS_BSSEND`, `DU_BSSEND`, `FIND_BSSEND`, `SED_BSSEND`,
`SH_BSSEND` -- a bare label with no `ds`, placed as the last thing in
the block, so its own address IS the arena end
(scripts/check_ls.py/check_du.py/check_find.py/check_sed.py/
check_shwarm.py/check_catread.py all read it out of merlin32's own
symbol dump, never hardcoded). The other 26 converted programs have no
such label, and the fix is NOT to add 26 more -- it is to stop needing
one at all.

THE DERIVATION. `dum`/`dend` bracket a PC range; merlin32's own `-v1`
listing prints the address of EVERY line it assembles, `dend` included
-- so the address on the PROGRAM's OWN `dend` row already is the arena
end, whether or not a bare label happens to sit there. No `ds` operand
ever needs evaluating (a size like `BUFSZ` or `MAXCDEPTH*3*FORWORDLEN`
is exactly the kind of arithmetic a hand-rolled parser gets wrong twice,
per docs/STICKY.md sec 28's own postmortem) -- merlin32 already placed
every subsequent label at the right address, and the `dend` row's own
address is simply where that placement stopped.

BOTH LAYERS, NOT ONE (`learning:01M0MQDQWCXC1KRABA2VMYARYA`). A span
that starts at `LIBA_BSSEND` covers only the program's own cells and
stops exactly one byte short of the liba cells living BELOW it --
`check-ls`'s poison ran `LIBA_ZPG..LIBA_BSSEND` for exactly that reason
and covered none of `ls`'s own storage the day it was widened. The
span here always starts at `LIBA_ZPG` (the head of liba's whole `dum *`
arena, the kernel's zeroed page included) and runs to the program's own
`dend` -- both layers, every time.

NEVER HARDCODE AN ADDRESS THE ASSEMBLER CAN TELL YOU
(`learning:01M0M9R7RT22JEPP2R0Y6J9MBX`). Both ends of the span are read
fresh from a `merlin32 -v1` run of the program's OWN source on every
call -- `LIBA_ZPG` is LOAD_BASE + image length and moves whenever any
earlier code's size does; the program's own arena end moves whenever
ITS code size does. A cached or hand-copied address would poison
whatever now lives there and pass while proving nothing.
"""
import contextlib
import os
import re
import shutil
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINSRC = os.path.join(ROOT, 'src', 'bin')
BUILD = os.path.join(ROOT, 'build')

# `SYM = $XXXX` lines in merlin32 -v1's trailing symbol table.
SYM_RE = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\$([0-9A-Fa-f]+)\s*$')

# One row of merlin32 -v1's full listing:
#   seq | file# filename lineno | Type | ... | size | 00/ADDR | source
ROW_RE = re.compile(
    r'^\s*\d+\s*\|\s*\d+\s+(\S+)\s+\d+\s*\|\s*(\S+)\s*\|.*?\|\s*'
    r'00/([0-9A-Fa-f]+)\s*\|(.*)$')


# merlin32 writes everything it makes at a path RELATIVE TO THE SOURCE
# FILE'S DIRECTORY (not its cwd; measured by running it from another
# directory, and the same rule resolves `put` paths): the `dsk
# ../../build/X` binary, the `-v1` dump beside it (build/X_Output.txt)
# and an `_FileInformation.txt` next to the source.
# Run in the real tree, a gate that wants only the dump therefore
# rewrites build/X (read by whoever stages X) and the dump (read by
# check-modules' error scan, check-kledger, the nas-librel stager) and
# then deletes both -- under a parallel sweep, from another lane's
# point of view, a file that vanishes mid-read (HYG-3: check-shwarm red
# in a sweep with FileNotFoundError build/sh.bin_Output.txt, green
# alone; sweep_par.sh's third group is the earlier fix of the same
# class, by serial lane). So a gate that assembles only to read
# symbols does it HERE: a private copy of the tree's sources, its own
# build/, removed afterwards. Nothing in the shared tree is written.


def _link_or_copy(src, dst):
    """Hard-link a source file into the private tree (merlin32 only
    reads sources, and a link costs no bytes); copy when the temp dir
    is on another filesystem. A file that vanishes between the
    directory listing and the link (another lane's merlin32 removes
    its _FileInformation.txt on the way out) is not an input: skipped,
    not fatal (SH-FD: check-textaudit red in a sweep, green alone)."""
    try:
        os.link(src, dst)
    except FileNotFoundError:
        return
    except OSError:
        try:
            shutil.copy2(src, dst)
        except FileNotFoundError:
            return


# What merlin32 leaves in a source directory is never an input: its
# scratch file, its error dump and the -v1 listings. Not copied, so a
# lane that is mid-assembly in the shared tree cannot be seen at all.
_SCRATCH = shutil.ignore_patterns('_FileInformation.txt',
                                  'error_output.txt', '*_Output.txt')


_PUTBIN_RE = re.compile(r'^\s+putbin\s+\.\./\.\./build/(\S+)', re.M)


@contextlib.contextmanager
def private_tree():
    """A temp directory holding src/, inc/ (hard links), an empty
    build/ and a COPY of every build/ file a `putbin` in src/ names
    (copied, not linked: those are other gates' products and may be
    rewritten in place). Yields its path; removed on exit."""
    tmp = tempfile.mkdtemp(prefix='maux-asm-')
    try:
        for d in ('src', 'inc'):
            shutil.copytree(os.path.join(ROOT, d), os.path.join(tmp, d),
                            copy_function=_link_or_copy,
                            ignore=_SCRATCH)
        os.mkdir(os.path.join(tmp, 'build'))
        want = set()
        for dirpath, _, names in os.walk(os.path.join(tmp, 'src')):
            for n in names:
                if n.endswith('.s'):
                    with open(os.path.join(dirpath, n),
                              errors='replace') as fh:
                        want.update(_PUTBIN_RE.findall(fh.read()))
        for n in sorted(want):
            real = os.path.join(BUILD, n)
            if os.path.isfile(real):
                shutil.copy2(real, os.path.join(tmp, 'build', n))
        yield tmp
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def private_listing(subdir, source, out_name):
    """Assemble <subdir>/<source> (subdir like 'src/bin' or 'src/test',
    source like 'sh.s') with `-v1` in a private tree and return the
    lines of build/<out_name> -- 'sh.bin_Output.txt' for a userland
    program, 'MAUXLSTEST.SYSTEM_Output.txt' for a kernel manifest (the
    name its `dsk` line gives). The shared tree is not touched.
    """
    with private_tree() as tmp:
        r = subprocess.run(
            [os.environ.get('MERLIN32', 'merlin32'), '-v1', source],
            cwd=os.path.join(tmp, subdir), stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True)
        out = os.path.join(tmp, 'build', out_name)
        if r.returncode != 0 or not os.path.exists(out):
            raise RuntimeError(
                f'merlin32 -v1 {subdir}/{source} did not write '
                f'{out_name} (exit {r.returncode}) -- assembly likely '
                f'failed:\n{r.stdout[-2000:]}')
        with open(out, errors='replace') as fh:
            return fh.readlines()


def _assemble(prog_name):
    """src/bin/<prog_name>.s assembled with `-v1`, full listing as a
    list of lines (private tree -- see above)."""
    return private_listing('src/bin', f'{prog_name}.s',
                           f'{prog_name}.bin_Output.txt')


# merlin32 -v1 prints an equate defined by an expression as
# `NAME = {{$E000}-{$0200}}` or `NAME = OTHER+1`, which SYM_RE (a bare
# `$hex`) does not match, so such a symbol used to be absent from the
# table. SH-ROOM names its segment walls that way (SH_SEG1_LIM,
# SH_SEG2_LIM); the second pass below resolves +/- expressions over
# `$hex`, decimal and already-known names, and ADDS only names the first
# pass did not find.
EXPR_RE = re.compile(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([-+{}$0-9A-Za-z_]+)\s*$')


def _symbol_table(lines):
    syms = {}
    exprs = []
    for line in lines:
        m = SYM_RE.match(line)
        if m:
            syms[m.group(1)] = int(m.group(2), 16)
            continue
        m = EXPR_RE.match(line)
        if m and any(c in m.group(2) for c in '{}+-'):
            exprs.append((m.group(1), m.group(2)))
    for _ in range(3):                    # a few passes: chains resolve
        for name, expr in exprs:
            if name in syms:
                continue
            e = re.sub(r'\$([0-9A-Fa-f]+)', lambda x: str(int(x.group(1), 16)),
                       expr).replace('{', '(').replace('}', ')')
            bad = False

            def sub(x):
                nonlocal bad
                if x.group(0) in syms:
                    return str(syms[x.group(0)])
                bad = True
                return '0'
            e = re.sub(r'[A-Za-z_][A-Za-z0-9_]*', sub, e)
            if not bad and re.fullmatch(r'[-+()0-9]+', e):
                try:
                    syms[name] = eval(e, {'__builtins__': {}})  # noqa: S307
                except SyntaxError:
                    pass
    return syms


def arena_span(prog_name):
    """(start_addr, length) of prog_name's $A5-poison span.

    prog_name is a bare name (e.g. 'ls', not 'ls.s' or 'src/bin/ls.s').
    Raises RuntimeError if the program has no `dum`/`dend` block in its
    own file (it is not a converted program), or if the expected liba
    anchor is missing (the sec-21 layout changed underneath this).
    """
    lines = _assemble(prog_name)
    syms = _symbol_table(lines)
    if 'LIBA_ZPG' not in syms:
        raise RuntimeError(
            f'LIBA_ZPG absent from {prog_name}.bin_Output.txt -- has '
            f'the sec-21 layout (src/liba/libabss.s, `put` last) '
            f'changed, or does {prog_name}.s not link liba at all?')
    start = syms['LIBA_ZPG']

    prog_file = f'{prog_name}.s'
    end = None
    for line in lines:
        m = ROW_RE.match(line)
        if not m:
            continue
        filename, kind, addr_hex, rest = m.groups()
        if filename != prog_file or kind != 'Dum':
            continue
        if rest.strip() == 'dend' and int(addr_hex, 16) > start:
            # `> start`: a program may carry a SECOND, literal-address
            # dum below the bss anchor (sh's TRAPTAB/CSFORWORDS home
            # in the segment tails, KFIX3 item 0); its dend is not the
            # arena's end and must not be taken for it.
            end = int(addr_hex, 16)
            # Keep scanning -- if a file somehow opened more than one
            # dum/dend block, the LAST one textually is the program's
            # own arena (docs/STICKY.md sec 21: `dum`/`dend` is always
            # placed textually last), matching check_purity.py's own
            # "at" == the LAST libabss.s `put` line convention.

    if end is None:
        raise RuntimeError(
            f'{prog_name}.s has no `dum`.../`dend` block of its own in '
            f'{prog_name}.bin_Output.txt -- it is not a converted '
            f'program (arena_span only applies to the 32 that are; '
            f'see scripts/check_poison.py\'s CONVERTED_ROSTER derivation).')
    return start, end - start


def symbol_table(prog_name):
    """Every symbol merlin32 -v1 prints for prog_name, as {name: addr}.

    Same freshness contract as arena_span(): the program is
    re-assembled from its OWN source on every call, because a listing
    address is a property of THAT build and nothing else -- a cached
    or hand-copied one measures a program that no longer exists.
    scripts/check_modules.py's sh low-image/segment tripwires read
    SH_SEG_LOW/SH_SEG_BEG/SH_SEG_END through this.
    """
    return _symbol_table(_assemble(prog_name))


def bssend_symbol(prog_name):
    """The hand-written <PROG>_BSSEND value for one of the six programs
    that still carry one (cat/ls/du/find/sed/sh), or None. Used only by
    the self-check below and by scripts/check_poison.py's reporting --
    arena_span() itself never reads this symbol, which is the whole
    point: the derivation must work identically for the 26 programs
    that have no such label.
    """
    lines = _assemble(prog_name)
    syms = _symbol_table(lines)
    name = f'{prog_name.upper()}_BSSEND'
    return syms.get(name)


# The six programs with a hand-written <PROG>_BSSEND label today
# (docs/STICKY.md sec 21/24/28/32/37) -- used only to self-check the
# derivation above against known-good values, never by arena_span().
KNOWN_BSSEND = ('cat', 'ls', 'du', 'find', 'sed', 'sh')


def self_check():
    """Six-way comparison: does arena_span()'s derived end address
    reproduce every hand-written <PROG>_BSSEND label exactly? Returns
    a list of (prog, derived_end, labeled_end, ok) rows.
    """
    rows = []
    for prog in KNOWN_BSSEND:
        start, length = arena_span(prog)
        derived_end = start + length
        labeled_end = bssend_symbol(prog)
        rows.append((prog, derived_end, labeled_end,
                      derived_end == labeled_end))
    return rows


def main():
    import sys
    rows = self_check()
    ok = True
    print(f'{"prog":<6} {"derived end":>12} {"<PROG>_BSSEND":>14} {"match":>6}')
    for prog, derived, labeled, match in rows:
        print(f'{prog:<6} ${derived:04X} '
              f'{("$%04X" % labeled) if labeled is not None else "MISSING":>14} '
              f'{"OK" if match else "MISMATCH":>6}')
        ok = ok and match
    if not ok:
        print('arena.py: SELF-CHECK FAILED -- derived end did not '
              'reproduce a hand-written <PROG>_BSSEND', file=sys.stderr)
        return 1
    print('arena.py: self-check OK -- all six reproduced exactly')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
