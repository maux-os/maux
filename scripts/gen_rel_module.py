#!/usr/bin/env python3
"""gen_rel_module.py -- derive a liba module's REL form from its
canonical PUT-form source (S9 REL route, docs/S9-PLAN.md sec 6 L2).

    python3 scripts/gen_rel_module.py src/liba/argv.s [--dsk /SOURCE/ARGV]

The tree keeps ONE canonical source form (the PUT form every gate and
the monolithic build consume); the REL form is GENERATED at staging,
the same pattern as the comment strip and the putbin->HEX rewrite --
ruled by the operator 2026-08-29 over converting sources or Merlin
DO/FIN conditionals. What generation adds, all of it emitting nothing
(byte-identity of the assembled code is the gate):

  * ` REL` first (must precede any label -- BAD REL otherwise), then
    ` DSK <path>` when --dsk is given: real Merlin can only write a
    REL object through DSK (SAV is incompatible), while under `as`
    the line is a clean no-op (P7: `DSK JMP RESTART`), so the SAME
    generated text serves both the reference assembly and `as`'s --
    proven byte-identical by check-as's RELMOD/RELMAIN cases.
  * `put` lines for the equ files the module's symbols need --
    resolved TRANSITIVELY (equ files define via each other's
    symbols), in the canonical manifest order, since equates stay
    assembly-time under REL (Merlin-8's ENT cannot export them --
    learning:01M08WQ2HCRMDM46TQCPWXQSKN).
  * `SYM EXT` for every symbol the module uses that another liba
    module defines (the arena cells and cross-module calls).
  * `SYM ENT` before each definition another file references, the
    label moved onto the ENT line (ENT defines the label at the
    current PC; the original line is de-labeled).
  * for the bss module (libabss.s), `dum`/`dend` lines are dropped so
    the cells EMIT -- the pure-bss-module-linked-last pattern
    (learning:01M15S5BTYRKFM1FNC7YJRBS7H): the linker lands it at
    image end, [image][arena] contiguous, and `ld` truncates the
    zeros.

The output is TEXT with house-relative put operands; the staging
layer rewrites paths exactly as it does for manifests.
"""
import argparse
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_modules as ckm  # noqa: E402 -- scan(): (defined, used)
import check_purity as ckp  # noqa: E402 -- _bss_only_module(): the one
                             # bss-module classifier (libabss.s and its
                             # chained companions, cptreebss.s today)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Canonical equ-file order, the order manifests put them (cat.s's own
# sequence; equ files may only reference symbols defined EARLIER in
# this list, which check-modules' EQU-forward-reference ratchet
# already enforces tree-wide).
# ORDER IS THE CONTRACT, not a preference: a Merlin equate may not
# forward-reference, so an equ file that leans on another must follow
# it. This list is not invented -- the inc/ half is the order the
# KERNEL MANIFESTS themselves put (src/test/processtest.s, which
# assembles under real Merlin in check-dual), and the liba half is the
# order every src/bin manifest puts. Anything added here belongs where
# the manifests already put it.
EQU_ORDER = [
    'inc/mm.procbank.equ',
    'inc/mm.procbnk2.equ',
    'inc/mm.hw.equ',
    'inc/mm.mli.equ',
    'inc/mm.mlibuf.equ',
    'inc/mm.annex.equ',
    'inc/mm.annex2.equ',
    'inc/mm.main.equ',
    'inc/mm.kbss0.equ',
    'inc/mm.kbss.equ',
    'inc/mm.lseg.equ',
    'inc/sc.proc.equ',
    'inc/sc.status.equ',
    'inc/sc.file.equ',
    'inc/sc.fd.equ',
    'inc/sc.devfd.equ',
    'inc/sc.fdact.equ',
    'inc/errno.krn.equ',
    'inc/errno.spawn.equ',
    'inc/bankcopy.equ',
    'inc/entry.frame.equ',
    'inc/sched.equ',
    'inc/kdisp.equ',
    # bye slice 1 (2026-09-25): byeres.equ, put right here by every
    # top-level manifest that carries it (forktest.s's own
    # put-list: right after inc/kdisp.equ, before inc/sched.zp.equ
    # -- matched here). MOVED src/kernel/ -> inc/ the same day
    # (check-modules FAIL: check_modules.py's module-boundary rule
    # only recognizes "globals from inc/*.equ" as legitimate --
    # src/kernel/byeres.equ's own directory was never a necessity,
    # just where it happened to land next to byeres.s/procbye.s).
    'inc/byeres.equ',
    'inc/sched.zp.equ',
    'inc/bankprobe.equ',
    'inc/mli.const.equ',
    'inc/proc.const.equ',
    'inc/timer.equ',
    'inc/ultraterm.equ',
    'inc/tty.equ',
    'inc/zp.equ',
    'inc/stdio.equ',
    'inc/startup.equ',
    'inc/mli.equ',
    'inc/readdir.equ',
    'inc/cptree.equ',
    'inc/regex.equ',
]


def _equ_defs():
    """{equ_path: {syms}} for every inc/ and liba equ file."""
    out = {}
    for path in EQU_ORDER:
        full = os.path.join(ROOT, path)
        if os.path.exists(full):
            out[path] = ckm.scan(full)[0]
    return out


def _liba_defs(exclude, peer_dir=None):
    """{sym: module_path} over the LINK PEER directory, minus `exclude`.

    THE DIRECTORY IS THE LIBRARY. A REL module's external references
    resolve against the modules it gets linked with, and #8a's "one
    file = one future module" ruling makes that set exactly the
    directory the module lives in: src/liba for liba, src/kernel for
    the kernel (S9 L4). Globbing src/liba unconditionally -- which is
    what this did until 2026-08-30 -- gave every kernel module an
    EMPTY ext list, because a kernel module references its peers and
    none of them are liba: 24 modules generated "cleanly" with 0 EXT
    apiece and would have failed at assembly with undefined symbols.
    For a liba module the behaviour is unchanged (its own directory
    IS src/liba).
    """
    out = {}
    if peer_dir is None:
        peer_dir = os.path.dirname(os.path.abspath(exclude))
    else:
        peer_dir = os.path.join(ROOT, peer_dir)
    for path in sorted(glob.glob(os.path.join(peer_dir, '*.s'))):
        if os.path.abspath(path) == os.path.abspath(exclude):
            continue
        for sym in ckm.scan(path)[0]:
            out[sym] = path
    return out


def _manifest_equ_defs():
    """Symbols the top-level manifests define as EQUATES (never as a
    label anywhere). Merlin-8's ENT exports code labels only, so a main
    cannot export one of these -- a module referencing it would
    generate happily and fail at LINK time with an unresolved
    external, which is the worst place to find out."""
    equ_def, label_def = set(), set()
    for path in sorted(glob.glob(os.path.join(ROOT, 'src/test/*.s')) +
                       glob.glob(os.path.join(ROOT, 'src/bin/*.s'))):
        for raw in open(path, encoding='latin-1'):
            m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s+(equ|=)\s', raw)
            if m:
                equ_def.add(m.group(1))
                continue
            m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)', raw)
            if m:
                label_def.add(m.group(1))
    return equ_def - label_def


def _manifest_defs():
    """Symbols the TOP-LEVEL MANIFESTS define -- src/test/*.s and
    src/bin/*.s, the files that are compilation units rather than put
    modules.

    A kernel module legitimately references things its includer
    supplies: `K_IRQ_HOOK` is a `ds 2` cell every harness declares and
    src/kernel/{entry2,timer}.s jump through. Under REL that is an
    ordinary external -- the generated MAIN defines the cell and ENTs
    it, the module EXTs it -- so these must not be mistaken for
    unresolved symbols. They are returned separately from the peer
    definitions so `meta['main_exts']` can name them: a symbol that
    only some manifest defines is worth being able to see.
    """
    out = set()
    for path in sorted(glob.glob(os.path.join(ROOT, 'src/test/*.s')) +
                       glob.glob(os.path.join(ROOT, 'src/bin/*.s'))):
        out |= ckm.scan(path)[0]
    return out


def _users_of(module):
    """Symbols `module` defines that any OTHER liba/bin/test file uses."""
    defined = ckm.scan(module)[0]
    used_elsewhere = set()
    for path in sorted(glob.glob(os.path.join(ROOT, 'src/*/*.s'))):
        if os.path.abspath(path) == os.path.abspath(module):
            continue
        used_elsewhere |= ckm.scan(path)[1]
    return defined & used_elsewhere


def _equ_env(extra_lines=()):
    """name -> operand-expression string, from every EQU_ORDER file
    plus the given manifest lines. For bss chunk sizing only."""
    env = {}
    srcs = []
    for path in EQU_ORDER:
        full = os.path.join(ROOT, path)
        if os.path.exists(full):
            srcs.append(open(full, encoding='latin-1').read().split('\n'))
    srcs.append(list(extra_lines))
    for lines in srcs:
        for raw in lines:
            mm = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s+(?:equ|=)\s+(\S+)',
                          raw.split(';')[0])
            if mm and mm.group(1) not in env:
                env[mm.group(1)] = mm.group(2)
    return env


def _eval_merlin(expr, env, _seen=None):
    """Merlin arithmetic: STRICT left-to-right, no precedence, no
    parentheses. Raises on PC terms and unknown names."""
    _seen = _seen or set()
    toks = re.findall(r'[A-Za-z_][A-Za-z0-9_]*|\$[0-9A-Fa-f]+|\d+|[-+*/]',
                      expr)
    if ''.join(toks) != expr.replace(' ', ''):
        raise ValueError(f'unparsable expression {expr!r}')
    val = None
    op = '+'
    expect_value = True
    for t in toks:
        if expect_value:
            if t == '*':
                raise ValueError(f'PC term in {expr!r}')
            if t.startswith('$'):
                v = int(t[1:], 16)
            elif t.isdigit():
                v = int(t)
            else:
                if t in _seen:
                    raise ValueError(f'equ cycle at {t}')
                if t not in env:
                    raise ValueError(f'unknown symbol {t} in {expr!r}')
                v = _eval_merlin(env[t], env, _seen | {t})
            val = v if val is None else \
                (val + v if op == '+' else
                 val - v if op == '-' else
                 val * v if op == '*' else val // v)
            expect_value = False
        else:
            if t not in '+-*/':
                raise ValueError(f'missing operator in {expr!r}')
            op = t
            expect_value = True
    if val is None or expect_value:
        raise ValueError(f'empty/truncated expression {expr!r}')
    return val


def _dum_absolute(code, env):
    """The address of `dum SYMBOL` iff SYMBOL evaluates over the
    equates alone (sh.s's `dum ED_HBASE`, ED_HBASE equ PRC_LC_COMMON-
    ED_HSIZE), else None. Such a block is a LITERAL overlay exactly
    like `dum $addr`: its labels are absolute addresses, so it must
    not be treated as arena bss -- extracted into the companion bss
    module its cells become linker symbols, and a reference from
    another piece links a bss address where merlin32 has the
    constant (TAB-A2: `lda #<ED_HRING` linked $12, merlin32 $00). An
    operand that is a LABEL (dum LIBA_BSSEND, CPT_BSSEND) does not
    evaluate and stays arena-chained bss."""
    m = re.match(r'^\s+dum\s+([A-Za-z_][A-Za-z0-9_]*'
                 r'(?:[-+][A-Za-z0-9_$]+)*)\s*$', code)
    if not m:
        return None
    try:
        return _eval_merlin(m.group(1), env)
    except (ValueError, KeyError, RecursionError):
        return None


def generate_main(manifest, dsk=None, bss_chunk=7000):
    """A src/bin MANIFEST's REL-main form (S9 L3): the program's own
    text as one module, its liba `put`s replaced by EXT declarations
    plus a recorded LINK LIST (link order = put order, which is what
    makes the linked binary byte-identical to the monolithic build),
    and its trailing `dum LIBA_BSSEND` block extracted into a
    companion pure-bss module linked LAST.

    Returns (main_text, bss_text_or_None, meta). meta['modules'] is
    the link list (liba basenames, put order); meta['bss_cells'] the
    extracted cells. `org LOAD_BASE` and the monolithic `dsk` line
    are dropped -- REL forbids ORG (the link address supplies it) and
    the REL dsk is our own.
    """
    manifest = os.path.join(ROOT, manifest) \
        if not os.path.isabs(manifest) else manifest
    rel = os.path.relpath(manifest, ROOT)
    defined, used = ckm.scan(manifest)
    equ_defs = _equ_defs()
    # A MANIFEST'S PEERS ARE THE MODULES IT LINKS, WHICH IS NOT ITS OWN
    # DIRECTORY. src/bin/cat.s lives beside the other programs but links
    # src/liba -- resolving against its own directory drops every liba
    # symbol from the ext list silently (EXIT, GETARG, PUTS, the SC_*
    # calls...), and the generated main then assembles against nothing.
    # Measured 2026-08-30: that is exactly what happened when
    # _liba_defs learned to use the module's own directory for the
    # KERNEL's sake, and 33 of 33 util mains stopped assembling.
    liba_defs = _liba_defs(manifest, peer_dir='src/liba')

    lines = open(manifest, encoding='latin-1').read().split('\n')
    man_env = _equ_env(lines)
    body = []
    modules = []
    org = None                  # the manifest's org operand, verbatim
    body_mods = []
    bss_cells = []
    bss_lines = []
    in_bss = 0
    for raw in lines:
        code = raw.split(';')[0]
        m = re.match(r'^\s+put\s+(\S+)', code)
        if m:
            tgt = m.group(1)
            if tgt.endswith('.equ'):
                # normalized to the generator's own single-space form
                # so staging rewrites need to handle ONE shape
                body.append(f' put {tgt}')
            elif '/liba/' in tgt:
                modules.append(os.path.basename(tgt)[:-2])
                # a MARKER where the liba put stood: a manifest may put
                # body code AFTER liba modules (sh.s's $E000 segment
                # sits between env.s and libabss.s; testeval.s did too
                # until 2026-10-17), and a link that places
                # every piece ahead of every liba module shifts each
                # liba address by that body's size (sh: GETARG +946 B,
                # 2026-09-13). Comment-shaped, so merlin32 and the
                # squeeze both drop it; generate_pieces reads it.
                body.append(f'* @LIBA {os.path.basename(tgt)[:-2]}')
            else:
                body.append(f' put {tgt}')  # same-dir body module
                body_mods.append(os.path.normpath(
                    os.path.join(os.path.dirname(manifest), tgt)))
            continue
        morg = re.match(r'^\s+org\s+(\S+)', code)
        if morg:
            if org is None:
                org = morg.group(1)        # link address supplies this
            else:
                # A SECOND `org` IS A SEGMENT RUN, not a second image.
                # sh.s's `org PRC_LC_COMMON` (docs/SH-SUBSET.md 7.6)
                # starts a block of code that RUNS at $E000 while its
                # bytes ride contiguously in the flat file; the org
                # after it winds the PC back and ends the run. Both
                # become markers here -- comment-shaped, so merlin32
                # and the squeeze drop them -- and generate_pieces
                # turns them into forced cuts so the block is its own
                # module(s), linked with ld's `-s`.
                body.append(f'* @SEGORG {morg.group(1)}')
            continue
        if re.match(r'^\s+dsk\b', code):
            continue                       # the REL dsk is our own
        if re.match(r'^\s+err\b', code) and '*' in code:
            # a PC-expression err (`err */$BF00`-style layout
            # tripwire): REL forbids PC expressions, and feeding one
            # to as HANGS the core rather than erroring (cp's main,
            # measured -- the second input class found to do that,
            # after ds-of-undefined). Monolithic layout tripwires
            # have no meaning at a linker-chosen address; ld's own
            # link-time ERR constraint is the replacement. Absolute-
            # expression errs (sh's MAXTOK coupling) are legal REL
            # and kept.
            continue
        lit = _dum_absolute(code, man_env)
        if lit is not None:
            body.append(f' dum ${lit:04X} ;GEN-LIT {code.split()[1]}')
            continue
        if re.match(r'^\s+dum\s+[A-Za-z_]', code):
            # ANY symbol-anchored trailing dum is arena-chained
            # program bss (LIBA_BSSEND, or a bss module's own end
            # label -- cp chains at CPT_BSSEND, which is undefined
            # at REL main-assembly time and WEDGES the core, hang
            # class #3). Literal dums ($xxxx overlays) stay.
            in_bss = 1
            continue
        if in_bss:
            if re.match(r'^\s+dend\b', code):
                in_bss = 0
                continue
            if re.match(r'^\s+err\b', code):
                # `err */...` tripwires are PC expressions -- illegal
                # in REL; ld's own link-time ERR constraint is the
                # replacement (LD-DESIGN).
                continue
            mm = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s+ds\s', raw)
            if mm:
                bss_cells.append(mm.group(1))
            # a BARE label line followed by its ` ds N` on the next
            # line (sh.s's CMD_TGTFD, 2026-09-13) is the same cell in
            # two lines; it was silently neither a cell nor an EXT
            mm2 = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*$', code)
            if mm2:
                bss_cells.append(mm2.group(1))
            bss_lines.append(raw)
            continue
        body.append(raw)

    # a body module's code left the manifest during the window splits;
    # its liba references (and its own definitions) belong to the MAIN
    # -- scanning only the manifest text produced empty ext lists for
    # every split util (LS/MV/NM/SED/SH/DIFF/ED/EXPR/FIND, the whole
    # missing-object set of the first full sweep).
    defined, used = set(defined), set(used)
    for bp in body_mods:
        bdef, bused = ckm.scan(bp)
        defined |= bdef
        used |= bused
    need = set(used) - set(defined)
    chosen = []
    changed = True
    while changed:
        changed = False
        for path in EQU_ORDER:
            if path not in equ_defs or path in chosen:
                continue
            if equ_defs[path] & need:
                chosen.append(path)
                need |= ckm.scan(os.path.join(ROOT, path))[1]
                changed = True
    chosen.sort(key=EQU_ORDER.index)
    # extracted bss cells count as scan-'defined' in the manifest, so
    # `need` misses them -- they are EXTs of the main now.
    exts = sorted((need & set(liba_defs)) | (set(bss_cells) & used))

    base = os.path.basename(rel)[:-2]
    mod_dir = os.path.dirname(rel)
    head = [f'* {base}.s REL MAIN -- GENERATED,',
            f'* do not edit (gen_rel_module.py; {rel})',
            ' rel']
    if dsk:
        head.append(f' dsk {dsk}')
    head += [' lst off', ' tr', ' exp off']
    for sym in exts:
        head.append(f'{sym} ext')
    main_text = '\n'.join(head + body) + '\n'

    bss_texts = []
    if bss_lines:
        # the bss module's ds operands reference equates -- some from
        # equ files, some defined in the MAIN's own text (cat's BUFSZ).
        # The first kind becomes put lines; the second is COPIED
        # verbatim (values identical by construction). Found the hard
        # way: an undefined symbol in a REL `ds` HANGS as's core
        # rather than erroring -- 30 minutes of pegged CPU on a
        # four-cell module.
        # operand-field refs ONLY -- the first cut collected every
        # identifier on the line, so comment prose pulled equ lines
        # in, and the manifest-wide scan re-copied equs that already
        # sit inside the dum block: du/find each got a SECOND
        # `FPGAP1 equ *-FULLPATH+1` hoisted above FULLPATH (a PC
        # expression, forward-referenced AND duplicated).
        def _refs(raw):
            code = raw.split(';')[0]
            if not code.strip() or code.lstrip().startswith('*'):
                return set()
            parts = code.split()
            idx = 1 if code[:1] in (' ', '\t') else 2
            if len(parts) > idx:
                return set(re.findall(r'[A-Za-z_][A-Za-z0-9_]*',
                                      parts[idx]))
            return set()
        bss_used = set()
        for raw in bss_lines:
            bss_used |= _refs(raw)
        bss_need = bss_used - set(bss_cells)
        # main-defined equ lines (bss block excluded -- `body` is the
        # manifest minus the dum block), closed transitively: ed's
        # LINETBL_SIZE leans on MAXLINES, and the first cut carried
        # only the direct reference. Manifest order is preserved --
        # Merlin equs must not forward-reference.
        # ... AND the same-dir BODY modules' equates: sh's bss sizes six
        # cells by equates defined in shparse.s/shpth2.s/shbltn.s/
        # shsub2.s (FDABUFSZ, MAXCDEPTH, GLOBREC, HDBODYLEN, SUBARGMAX),
        # and a bss module that lacks them assembled 3,572 B SHORT under
        # nas with no error (2026-09-13, the roster sweep's bss audit --
        # nas then sized an unresolved `ds` as 0; it refuses one now).
        # env_lines (below) already reads the body modules for SIZING;
        # the copy must draw from the same text.
        equ_by_sym = {}
        body_order = {}
        body_plus = list(body)
        for bp in body_mods:
            body_plus += open(bp, encoding='latin-1').read().split('\n')
        for i, raw in enumerate(body_plus):
            mm = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s+(equ|=)\s',
                          raw)
            if mm and mm.group(1) not in equ_by_sym:
                equ_by_sym[mm.group(1)] = raw
                body_order[raw] = i
        main_equ_lines = []
        changed = True
        while changed:
            changed = False
            for sym, raw in equ_by_sym.items():
                if sym not in bss_need or raw in main_equ_lines:
                    continue
                parts = raw.split(';')[0].split(None, 2)
                op = parts[2] if len(parts) > 2 else ''
                # `*` is the PC only at a TERM position (start of the
                # expression or right after an operator); between
                # terms it multiplies (MAXLINES*2+2).
                if re.search(r'(?:^|[+\-/,(#<>])\*', op.split()[0] if op else ''):
                    raise SystemExit(
                        f'{rel}: bss needs PC-dependent equ {sym!r} '
                        f'({raw.strip()}) -- make it a dum label '
                        f'(`{sym} ds 0`) so it exports as an ENT')
                main_equ_lines.append(raw)
                bss_need |= _refs(raw)
                changed = True
        main_equ_lines.sort(key=body_order.__getitem__)
        bss_equs = []
        for path in EQU_ORDER:
            if path in equ_defs and equ_defs[path] & bss_need:
                bss_equs.append(path)
        # `ds` in REL EMITS its bytes, and as buffers the object in
        # $A000..$BF00 -- 7936B minus the dictionary. A big program
        # bss (diff: ~17.6KB, DPTABLE alone 10000) must therefore
        # ship as SEVERAL pure-bss modules linked consecutively --
        # ld places modules end-to-end, so the cells stay contiguous,
        # and an oversized single cell is split with unlabeled
        # numeric `ds` continuation pieces nothing references.
        # 7,000 is `as`'s 7,936 B OBJECT cap minus the dictionary; a
        # caller whose assembler has no such cap (nas's streaming
        # route) may pass a larger bss_chunk to keep a big unit's
        # link line inside the shell's argv (vi, 2026-09-13).
        BSS_CHUNK_LIMIT = bss_chunk
        env_lines = list(body) + list(bss_lines)
        for bp in body_mods:
            env_lines += open(bp, encoding='latin-1').read().split('\n')
        env = _equ_env(env_lines)
        items = []          # (emitted_size, [lines])
        pending = None      # a bare cell label awaiting its ` ds` line
        for raw in bss_lines:
            code = raw.split(';')[0]
            mm = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)(\s+)(ds\s+(\S+).*)$',
                          raw)
            mm2 = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*$', code)
            mm3 = re.match(r'^\s+(ds\s+(\S+).*)$', raw)
            if mm and mm.group(1) in bss_cells:
                size = _eval_merlin(mm.group(4), env)
                items.append((size, [f'{mm.group(1)} ent',
                                     f' {mm.group(3)}'], mm.group(1)))
            elif mm2 and mm2.group(1) in bss_cells:
                pending = mm2.group(1)      # its ds follows
            elif mm3 and pending:
                size = _eval_merlin(mm3.group(2), env)
                items.append((size, [f'{pending} ent',
                                     f' {mm3.group(1)}'], pending))
                pending = None
            else:
                items.append((0, [raw], None))
        # ld reads a module's fixup+symbol tail into TAILBUF (TAILCAP
        # 3,584 B, src/bin/ld.s) and refuses a tail that fills it
        # ("ld: dictionary too large", reported on stderr, which is how
        # SH-PREFIX's sh first showed up as "linked binary never
        # written").  A bss module's tail is its dictionary: one ENT
        # record, 3 + len(name) bytes, per labelled cell.  sh's single
        # 4,746 B chunk carried 378 cells = 3,637 B.  So a chunk closes
        # on its dictionary as well as on its bytes.
        BSS_DICT_LIMIT = 3400
        dict_fill = 0
        chunks = [[]]
        chunk_sizes = [0]       # emitted bytes per chunk (meta['bss_sizes'])
        fill = 0
        for size, lns, label in items:
            cost = 3 + len(label) if label else 0
            if dict_fill + cost > BSS_DICT_LIMIT and fill > 0:
                chunks.append([])
                chunk_sizes.append(0)
                fill = 0
                dict_fill = 0
            dict_fill += cost
            if size > BSS_CHUNK_LIMIT:
                # split the cell itself: labeled first piece, bare
                # numeric continuations
                if fill > 0:
                    chunks.append([])
                    chunk_sizes.append(0)
                    fill = 0
                first = BSS_CHUNK_LIMIT
                chunks[-1].append(f'{label} ent')
                chunks[-1].append(f' ds {first}   ;split cell, '
                                  f'{size}B total')
                chunk_sizes[-1] += first
                left = size - first
                while left > 0:
                    piece = min(left, BSS_CHUNK_LIMIT)
                    chunks.append([f' ds {piece}   ;{label} '
                                   f'continuation'])
                    chunk_sizes.append(piece)
                    left -= piece
                fill = piece
                continue
            if fill + size > BSS_CHUNK_LIMIT:
                chunks.append([])
                chunk_sizes.append(0)
                fill = 0
            chunks[-1].extend(lns)
            chunk_sizes[-1] += size
            fill += size
        bss_texts = []
        for ci, chunk in enumerate(chunks):
            part = f' (part {ci + 1}/{len(chunks)})' if len(chunks) > 1 \
                else ''
            bh = [f'* {base}bss REL module -- GENERATED (program '
                  f'bss{part},',
                  f'* was dum LIBA_BSSEND in {rel}); linked LAST',
                  ' rel']
            if dsk:
                suf = 'B' if ci == 0 else f'B{ci + 1}'
                bh.append(f' dsk {dsk}{suf}')
            bh += [' lst off', ' tr', ' exp off']
            for path in bss_equs:
                bh.append(f' put {os.path.relpath(path, mod_dir)}')
            bh += main_equ_lines
            bss_texts.append('\n'.join(bh + chunk) + '\n')

    return main_text, bss_texts, {'modules': modules, 'exts': exts,
                                   'org': org,
                                   'equs': chosen, 'bss_cells': bss_cells,
                                   'bss_sizes': chunk_sizes if bss_lines
                                   else []}


def generate(module, dsk=None):
    module = os.path.join(ROOT, module) if not os.path.isabs(module) \
        else module
    rel = os.path.relpath(module, ROOT)
    defined, used = ckm.scan(module)
    equ_defs = _equ_defs()
    liba_defs = _liba_defs(module)

    # equ closure, transitive: pull an equ file if it defines a needed
    # symbol; its own references may need earlier files.
    need = set(used) - set(defined)
    chosen = []
    # iterate to a fixed point: a late equ file's own references can
    # need an EARLIER file (startup.equ leaning on memmap symbols),
    # which a single ordered pass would already have walked past.
    changed = True
    while changed:
        changed = False
        for path in EQU_ORDER:
            if path not in equ_defs or path in chosen:
                continue
            if equ_defs[path] & need:
                chosen.append(path)
                need |= ckm.scan(os.path.join(ROOT, path))[1]
                changed = True
    chosen.sort(key=EQU_ORDER.index)  # emit in canonical order
    ents = sorted(_users_of(module))
    # an equate CANNOT be exported (Merlin-8 ENT is code labels only);
    # a cross-module-used equate in a .s module must move to an equ
    # file first -- fail loudly with the fix named, never fold ENT
    # onto an equ line (real Merlin dies with "Bad label" there,
    # found by the libabss/RD_BLKSZ pilot).
    equ_defined = set()
    for raw in open(module, encoding='latin-1'):
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s+(equ|=)\s', raw)
        if m:
            equ_defined.add(m.group(1))
    bad = set(ents) & equ_defined
    if bad:
        raise SystemExit(
            f'{rel}: cross-module-used EQUATES cannot be exported under '
            f'REL: {sorted(bad)}. Move each to an equ file (zp.equ is '
            f'the universal home; see the 2026-08-29 moves) and re-run.')
    unresolved = need - set(liba_defs) \
        - set().union(*equ_defs.values()) - set(defined)
    # includer-supplied symbols are externals too -- see _manifest_defs
    main_exts = unresolved & _manifest_defs()
    unresolved -= main_exts
    bad_main = main_exts & _manifest_equ_defs()
    if bad_main:
        raise SystemExit(
            f'{rel}: references {sorted(bad_main)}, which the top-level '
            f'manifests define as EQUATES. A main cannot ENT an equate '
            f'(Merlin-8 exports code labels only), so this would link '
            f'to nothing. Either the constant is the same everywhere '
            f'and belongs in an equ file, or it is per-manifest '
            f'configuration and has to become a CELL the main defines '
            f'and the module reads.')
    exts = sorted((need & set(liba_defs)) | main_exts)
    # symbols neither an equ nor liba defines: caller-side (a program
    # symbol) -- check-modules forbids those for liba, so this is a
    # generator-input error, not a warning.
    if unresolved and (rel.startswith('src/liba/')
                       or rel.startswith('src/kernel/')):
        raise SystemExit(f'{rel}: unresolved symbols {sorted(unresolved)} '
                         f'-- neither an equ file nor another liba module '
                         f'defines them')

    out = [f'* {os.path.basename(rel)} REL form -- GENERATED,',
           f'* do not edit (gen_rel_module.py; {rel})',
           ' rel']
    if dsk:
        out.append(f' dsk {dsk}')
    # TR + EXP OFF: listing suppression, the same lines the relspike
    # fixtures carry -- without them the assembler pages a full symbol
    # table through the screen, which both slows real Merlin and
    # defeats the harness's end-of-assembly marker wait.
    out.append(' lst off')
    out.append(' tr')
    out.append(' exp off')
    # 65C02 opcodes: the manifests carry `xc` once near the top; a
    # standalone REL module must carry its own or real Merlin refuses
    # the first stz/bra with "Bad opcode" (found by the brk.s pilot).
    out.append(' xc')
    mod_dir = os.path.dirname(rel)
    for path in chosen:
        out.append(f' put {os.path.relpath(path, mod_dir)}')
    for sym in exts:
        out.append(f'{sym} ext')

    base = os.path.basename(rel)
    is_bss = base == 'libabss.s' or ckp._bss_only_module(base)[0]
    ent_set = set(ents)
    for raw in open(module, encoding='latin-1'):
        line = raw.rstrip('\n')
        code = line.split(';')[0]
        if is_bss and re.match(r'^\s+(dum|dend)\b', code):
            out.append('* [REL form: %s dropped -- cells emit]'
                       % code.strip().split()[0])
            continue
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)(\s+)(.*)$', line)
        if m and m.group(1) in ent_set:
            out.append(f'{m.group(1)} ent')
            out.append(f' {m.group(3)}' if m.group(3) else '')
            ent_set.discard(m.group(1))
            continue
        # a bare exported label on its own line
        m2 = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*$', line)
        if m2 and m2.group(1) in ent_set:
            out.append(f'{m2.group(1)} ent')
            ent_set.discard(m2.group(1))
            continue
        out.append(line)
    if ent_set:
        raise SystemExit(f'{rel}: exported symbols never seen as label '
                         f'definitions: {sorted(ent_set)}')
    return '\n'.join(out) + '\n', {'ents': ents, 'exts': exts,
                                    'main_exts': sorted(main_exts),
                                   'equs': chosen}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('module')
    ap.add_argument('--dsk', default=None)
    ap.add_argument('-o', dest='out', default=None)
    a = ap.parse_args()
    text, meta = generate(a.module, a.dsk)
    if a.out:
        with open(a.out, 'w', newline='\n') as fh:
            fh.write(text)
        print(f'[gen-rel] {a.out}: {len(text)}B, '
              f'{len(meta["ents"])} ENT, {len(meta["exts"])} EXT, '
              f'equ: {", ".join(meta["equs"]) or "-"}')
    else:
        sys.stdout.write(text)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())


def _listing_rows(listing_path):
    """(source basename, source line) -> emitted size, from a merlin32
    _Output.txt listing. The GENERATED-LITERAL rewrites (S9-PLAN
    sec 6b's three hazards, one answer) read their values here, so the
    literal is re-derived from the fresh listing at every staging
    run and the byte-identity gate catches any staleness."""
    rows = {}
    for ln in open(listing_path, encoding='latin-1'):
        cols = ln.split('|')
        if len(cols) < 7 or 'Code' not in cols[2] and 'Data' not in cols[2] \
                and 'Empty' not in cols[2]:
            continue
        m = re.match(r'\s*\d+\s+(\S+)\s+(\d+)\s*$', cols[1])
        if not m:
            continue
        try:
            size = int(cols[5].strip() or '0')
        except ValueError:
            continue
        rows[(os.path.basename(m.group(1)), int(m.group(2)))] = size
    return rows


def _listing_line_addrs(listing_path):
    """(source basename, source line) -> assembled address.
    Companion to _listing_rows for the PC-equate rewrites
    (`X_LEN equ *-X`): the value of `*` at a line is that line's
    listed address."""
    rows = {}
    for ln in open(listing_path, encoding='latin-1'):
        cols = ln.split('|')
        if len(cols) < 7:
            continue
        m = re.match(r'\s*\d+\s+(\S+)\s+(\d+)\s*$', cols[1])
        am = re.match(r'\s*00/([0-9A-Fa-f]{4})', cols[6])
        if m and am:
            rows[(os.path.basename(m.group(1)), int(m.group(2)))] = \
                int(am.group(1), 16)
    return rows


def _listing_addrs(listing_path):
    """label -> assembled address, from a merlin32 _Output.txt.
    Feeds the hazard-1 GENERATED-LITERAL rewrites: a byte-select of
    a cross-module label DIFFERENCE cannot cross the REL linker, so
    the generator computes the byte here, from the same listing the
    byte-identity gate rebuilds every run."""
    addrs = {}
    for ln in open(listing_path, encoding='latin-1'):
        cols = ln.split('|')
        if len(cols) < 8:
            continue
        m = re.match(r'\s*00/([0-9A-Fa-f]{4})', cols[6])
        if not m:
            continue
        lm = re.match(r'^\s?([A-Za-z_][A-Za-z0-9_:]*)\s', cols[7])
        if lm:
            addrs.setdefault(lm.group(1), int(m.group(1), 16))
    return addrs


def generate_kernel_main(manifest, kernel_names, listing=None,
                         prefix=None):
    """A kernel-bearing test MANIFEST's REL segment forms (S9-PLAN
    sec 6b stage A). Kernel `put`s become LINK-LIST entries via
    `kernel_names` (check_librel.KERNEL_FLAT, passed in -- that
    module imports this one, so the map travels as an argument);
    each run of inline EMITTED text between puts becomes its own
    generated segment module IN POSITION; a same-directory body put
    (the testb harness) becomes a generated segment at its put
    position. Link order = put order = byte order, which is what
    byte-identity against the monolithic merlin32 image means.

    PC-dependent `ds` pads (`ds $0800+512-*`, the raw-boot block
    pad) are rewritten to GENERATION-TIME LITERALS from the
    monolithic `listing` (hazard 2). Cross-module label differences
    (hazard 1, the builtin LEN tables) are REFUSED loudly for now;
    forktest (COUNT=0) is the pilot precisely because it has none.

    Returns (segments: [(name, text)], meta): meta['link'] is the
    full ordered module list (kernel names + segment names).
    """
    manifest = os.path.join(ROOT, manifest) \
        if not os.path.isabs(manifest) else manifest
    rel = os.path.relpath(manifest, ROOT)
    stem = os.path.basename(rel)[:-2]
    # the segment-name prefix must be UNIQUE across every manifest
    # staged together -- three sched.* manifests all truncate to
    # 'SCHE' and overwrite one another's staged segments (caught at
    # the item-2 rollout). check_librel.kernel_main_segments computes
    # a collision-free map and passes it; the [:4] fallback serves
    # single-manifest callers only.
    if prefix is None:
        prefix = ''.join(c for c in stem.upper() if c.isalnum())[:4]
    sizes = _listing_rows(listing) if listing else {}
    lineaddrs = _listing_line_addrs(listing) if listing else {}
    labeladdrs = _listing_addrs(listing) if listing else {}

    # ---- pass 1: split the manifest into ordered events ----------
    events = []          # ('kmod', KNAME) | ('seg', [(srcline, text)])
    cur = []

    def flush():
        if any(_emits(t) for _, t in cur):
            events.append(('seg', list(cur)))
        cur.clear()

    def _emits(text):
        code = text.split(';')[0]
        if not code.strip() or code.lstrip().startswith('*'):
            return False
        if re.match(r'^\s+(lst|xc|org|dsk|typ|tr|exp)\b', code):
            return False
        return True

    def walk(path):
        for n, raw in enumerate(
                open(path, encoding='latin-1').read().split('\n'), 1):
            code = raw.split(';')[0]
            m = re.match(r'^\s+put\s+(\S+)', code)
            if m:
                tgt = m.group(1)
                if tgt.endswith('.equ'):
                    continue          # closures are per-segment
                if '/kernel/' in tgt:
                    flush()
                    base = os.path.basename(tgt)[:-2]
                    if base not in kernel_names:
                        raise SystemExit(
                            f'{rel}: kernel put {tgt} has no name in '
                            f'KERNEL_FLAT -- add it there first')
                    events.append(('kmod', kernel_names[base]))
                    continue
                # same-dir body put: its text is a segment in position
                flush()
                walk(os.path.normpath(
                    os.path.join(os.path.dirname(path), tgt)))
                flush()
                continue
            cur.append(((os.path.basename(path), n), raw))
        # no flush here: trailing text joins the caller's next flush
        # only for the TOP manifest; body puts flush around themselves

    walk(manifest)
    flush()

    # ---- pass 2: per-segment text under the REL line rules -------
    kernel_files = sorted(glob.glob(os.path.join(ROOT, 'src/kernel/*.s')))
    kernel_defs, kernel_used = set(), set()
    for p in kernel_files:
        d, u = ckm.scan(p)
        kernel_defs |= d
        kernel_used |= u

    import tempfile
    _ed0 = _equ_defs()
    all_equ0 = set().union(*_ed0.values()) if _ed0 else set()

    def _eval_pm(expr):
        """Evaluate a +/- expression of $hex, decimal and listing
        labels -- Merlin has no precedence and these operands never
        need more. Returns None when a token is not evaluable, so
        the caller can refuse loudly with the operand named."""
        toks = re.findall(r"[+\-]|\$[0-9A-Fa-f]+|\d+"
                          r"|[A-Za-z_][A-Za-z0-9_]*", expr)
        if ''.join(toks) != expr.replace(' ', ''):
            return None
        val, sign, want_term = 0, 1, True
        for t in toks:
            if want_term:
                if t == '$' or t in '+-':
                    return None
                if t.startswith('$'):
                    v = int(t[1:], 16)
                elif t.isdigit():
                    v = int(t)
                elif t in labeladdrs:
                    v = labeladdrs[t]
                else:
                    return None
                val += sign * v
                want_term = False
            else:
                if t == '+':
                    sign = 1
                elif t == '-':
                    sign = -1
                else:
                    return None
                want_term = True
        return None if want_term else val

    seg_texts = []       # [(name, [lines], defined, used)]
    n_inline = 0
    link = []
    # labels defined inside DUM blocks (literal or GEN-LIT'd): their
    # values are ABSOLUTE addresses, and an absolute symbol cannot
    # ride ENT/EXT -- the dictionary's addresses are module-relative
    # ($8000-based), so the linker would rebase a dum cell as though
    # it were code (SCI_B resolved 3.6 KB low on testevtest, class
    # 14, 2026-09-01: the first manifests to INLINE libabss.s). They
    # become replicated literal equates instead, via seg_equ_lines.
    dum_syms = set()
    for kind, payload in events:
        if kind == 'kmod':
            link.append(payload)
            continue
        name = f'{prefix}M{n_inline}'
        n_inline += 1
        # equates DEFINED in this segment's own text: a fellow equ
        # may reference them symbolically; anything else a same-
        # segment equ leans on is a LABEL and must be literalized
        # (class 13, below).
        seg_equ0 = set()
        for _key, _raw in payload:
            m0 = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s+(?:equ|=)\s',
                          _raw.split(';')[0])
            if m0:
                seg_equ0.add(m0.group(1))
        lines = []
        in_dum = False
        for (src, lineno), raw in payload:
            code = raw.split(';')[0]
            if in_dum:
                if re.match(r'^\s+err\b', code) and '*' in code:
                    continue      # arena tripwires drop here too
                if re.match(r'^\s+dend\b', code):
                    in_dum = False
                else:
                    mlab = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)', code)
                    if mlab:
                        dum_syms.add(mlab.group(1))
                lines.append(raw)
                continue
            if re.match(r'^\s+dum\s+\$', code):
                in_dum = True         # literal-origin overlay block
                lines.append(raw)
                continue
            if re.match(r'^\s+(lst|xc|org|dsk|typ)\b', code):
                continue
            if re.match(r'^\s+err\b', code) and '*' in code:
                continue          # PC tripwire: ld's ERR replaces it
            mdum = re.match(r'^(\s+)dum\s+\*\s*$', code.rstrip())
            if mdum:
                # `dum *`: a PC-anchored dummy origin is illegal
                # under REL ('Illegal relative adrs', EXPRM13/TESTM7
                # 2026-09-01). Same literal answer as the pads: `*`
                # at this line is the listing's address for it, and
                # a dummy block emits nothing, so the labels inside
                # get exactly their monolithic values.
                key = (src, lineno)
                if key not in lineaddrs:
                    raise SystemExit(
                        f'{rel}: dum * at {src}:{lineno} has no '
                        f'listing row -- pass listing=')
                lines.append(f'{mdum.group(1)}dum '
                             f'${lineaddrs[key]:04X} ;GEN-LIT dum *')
                in_dum = True
                continue
            if re.match(r'^\s+dum\s+[A-Za-z_]', code):
                raise SystemExit(
                    f'{rel}: symbol-anchored dum in segment {name} '
                    f'({src}:{lineno}) -- not handled yet; see '
                    f'generate_main\'s bss extraction for the shape')
            meq = re.match(
                r'^([A-Za-z_][A-Za-z0-9_]*)\s+equ\s+(.*?)\s*$', code)
            if meq and '*' in meq.group(2):
                # `X_LEN equ *-X`: PC math is illegal in a REL equ
                # (real Merlin: 'Illegal forward reference', seen on
                # PLAYM2's three *_LEN equates 2026-09-01). Same
                # generated-literal answer as the pads: `*` at this
                # line is the listing's address for it.
                em = re.match(r'^\*\s*-\s*([A-Za-z_][A-Za-z0-9_]*)$',
                              meq.group(2))
                key = (src, lineno)
                if not em or key not in lineaddrs \
                        or em.group(1) not in labeladdrs:
                    raise SystemExit(
                        f'{rel}: PC equate at {src}:{lineno} '
                        f'({meq.group(2)!r}) not of the *-LABEL shape '
                        f'the literal rewrite handles, or missing '
                        f'from the listing')
                val = lineaddrs[key] - labeladdrs[em.group(1)]
                # HOISTED to the segment head (marker consumed in
                # pass 3): as a PC equate it had to sit at its
                # address; as a literal it must sit EARLY, because
                # the module's immediates reference it and real
                # Merlin refuses an equ forward reference --
                # playtestb's #<PAR_PROC_LEN at line 101 vs the
                # definition at 521, latent until the oracle read
                # this text standalone (2026-09-01).
                lines.append(f'@HOIST@{meq.group(1)} equ {val} '
                             f';GEN-LIT {meq.group(2)}')
                continue
            if meq:
                # class 13: an equ leaning on a LABEL (same-segment
                # forward, or a sibling segment's -- an external
                # either way) is refused by real Merlin ('Illegal
                # forward reference', PROCM3/PROCM4 2026-09-01:
                # PAR_PROC_LEN equ PAR_PROC_END-PARENT_PROC). Same
                # literal answer, hoisted like the PC equates.
                opnd = meq.group(2)
                cleaned = re.sub(r"\$[0-9A-Fa-f]+|'[^']*'"
                                 r"|\"[^\"]*\"|%[01]+", ' ', opnd)
                refs = re.findall(r'[A-Za-z_][A-Za-z0-9_]*', cleaned)
                if any(r not in all_equ0 and r not in seg_equ0
                       for r in refs):
                    val = _eval_pm(opnd)
                    if val is None:
                        raise SystemExit(
                            f'{rel}: equ at {src}:{lineno} references '
                            f'a label but {opnd!r} is not a +/- '
                            f'expression the literal rewrite can '
                            f'evaluate from the listing')
                    lines.append(f'@HOIST@{meq.group(1)} equ {val} '
                                 f';GEN-LIT {opnd}')
                    continue
            mds = re.match(r'^(\S*\s+)ds(\s+)(.*)$', code)
            if mds and '*' in mds.group(3):
                key = (src, lineno)
                if key not in sizes:
                    raise SystemExit(
                        f'{rel}: PC-dependent ds at {src}:{lineno} and '
                        f'no listing row for it -- pass listing= the '
                        f'monolithic _Output.txt')
                lines.append(f'{mds.group(1)}ds {sizes[key]} '
                             f';GEN-LIT {mds.group(3).strip()}')
                continue
            lines.append(raw)
        # as's source window binds each STAGED segment (stripped +
        # largest equ put < 16,126). A body segment over ~13.5 KB
        # stripped is split at GLOBAL-LABEL lines -- zone
        # boundaries, so no :local is orphaned by the cut; a :local
        # referenced ACROSS a cut would be refused by the oracle
        # (check-librel assembles every piece). playtestb needed
        # this on day one: 14,595 B squeezed against the window.
        from strip_comments import strip_text
        SEG_SPLIT = 13000
        # per-line stripped cost + global-label cut candidates, so a
        # cut lands at the LAST zone boundary that still fits -- the
        # first draft cut at the first label AFTER the limit and
        # produced a 14,245 B chunk beside a 700 B one.
        costs = [len(strip_text(l)) + 1 for l in (
            x[len('@HOIST@'):] if x.startswith('@HOIST@') else x
            for x in lines)]
        cuts = [i for i, x in enumerate(lines)
                if re.match(r'^[A-Za-z_]',
                            x[len('@HOIST@'):]
                            if x.startswith('@HOIST@') else x)]
        # a SHORT BRANCH may not cross a cut: the pieces are separate
        # REL modules, the target becomes an EXTERNAL, and a relative
        # displacement cannot be relocated -- Merlin refuses with
        # 'Bad external' (the entry.s beq lesson, met again as
        # FILEM3's `bra READ_COMMON` 14 lines above its target). A
        # candidate the branch straddles is skipped for the previous
        # one.
        gdef = {}
        for i, x in enumerate(lines):
            m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)',
                         x[len('@HOIST@'):]
                         if x.startswith('@HOIST@') else x)
            if m:
                gdef.setdefault(m.group(1), i)
        brx = re.compile(r'^\S*\s+b(?:ra|eq|ne|cc|cs|mi|pl|vc|vs)\s+'
                         r'([A-Za-z_][A-Za-z0-9_]*)\s*$')
        spans = []
        for i, x in enumerate(lines):
            m = brx.match(x.split(';')[0].rstrip())
            if m and m.group(1) in gdef:
                j = gdef[m.group(1)]
                spans.append((min(i, j), max(i, j)))

        def cut_ok(c):
            return all(not (a < c <= b) for a, b in spans)

        # class 15: a PURE-DS segment (buffer reservations -- the
        # prodos.spike spike's 16,799 B of ds) overflows `as`'s
        # 7,936 B OBJECT buffer even though its SOURCE is tiny; real
        # Merlin's cap is larger, so the oracle passes what as then
        # refuses (PRODM1, 2026-09-01). Chunk by EMITTED bytes with
        # unlabeled numeric continuation pieces -- the diff-bss
        # precedent -- at <=7,000 per module, linked consecutively.
        OBJ_SPLIT = 7000

        def _bare(l):
            return l[len('@HOIST@'):] if l.startswith('@HOIST@') else l

        def _ds_amt(l):
            m = re.match(r'^(\S*)(\s+)ds\s+(\d+)\b',
                         _bare(l).split(';')[0])
            return m if m else None

        _passive = re.compile(
            r'^\s*($|\*)|^\s+(lst|tr|exp|xc|put|rel|dum|dend)\b')
        _labelonly = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*\s*$')
        _equline = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*\s+(equ|=)\s')
        ds_total = sum(int(m.group(3)) for m in
                       (_ds_amt(l) for l in lines) if m)

        def _passive_line(l):
            cl = _bare(l).split(';')[0]
            if not cl.strip():
                return True             # blank or comment-only
            return bool(_passive.match(cl) or _equline.match(cl)
                        or _labelonly.match(cl.rstrip()))
        pure_ds = ds_total > 0 and all(
            _ds_amt(l) or _passive_line(l) for l in lines)

        chunks = []
        if pure_ds and ds_total > OBJ_SPLIT:
            cur, acc = [], 0
            for l in lines:
                m = _ds_amt(l)
                if not m:
                    cur.append(l)
                    continue
                amt = int(m.group(3))
                lead = f'{m.group(1)}{m.group(2)}'
                first = True
                while amt:
                    take = min(amt, OBJ_SPLIT - acc)
                    if take == 0:
                        chunks.append(cur)
                        cur, acc = [], 0
                        continue
                    label = lead if first else '            '
                    note = ' ;GEN-LIT obj-split' \
                        if take != int(m.group(3)) else ''
                    cur.append(f'{label}ds {take}{note}')
                    acc += take
                    amt -= take
                    first = False
            if cur:
                chunks.append(cur)
        else:
            start = 0
            while start < len(lines):
                acc = 0
                fits = []
                end = len(lines)
                for i in range(start, len(lines)):
                    acc += costs[i]
                    if acc > SEG_SPLIT:
                        end = i
                        break
                    if i in cuts and i > start:
                        fits.append(i)
                if end == len(lines):
                    chunks.append(lines[start:])
                    break
                last_fit = next((c for c in reversed(fits)
                                 if cut_ok(c)), None)
                if last_fit is None:
                    raise SystemExit(
                        f'{rel}: segment {name}: no branch-safe '
                        f'global-label cut point inside the '
                        f'{SEG_SPLIT}B window')
                chunks.append(lines[start:last_fit])
                start = last_fit
        for chunk in chunks:
            if len(chunks) > 1:
                cname = f'{prefix}M{n_inline}'
                n_inline += 1
            else:
                cname = name
            with tempfile.NamedTemporaryFile('w', suffix='.s',
                                             delete=False) as tf:
                tf.write('\n'.join(
                    l[len('@HOIST@'):] if l.startswith('@HOIST@')
                    else l for l in chunk))
                tmp = tf.name
            d, u = ckm.scan(tmp)
            os.unlink(tmp)
            seg_texts.append((cname, chunk, d, u))
            link.append(cname)

    # ---- pass 3: symbol accounting + emission --------------------
    equ_defs = _equ_defs()
    all_equ = set().union(*equ_defs.values()) if equ_defs else set()
    seg_defs_all = {}
    for name, _, d, _u in seg_texts:
        seg_defs_all[name] = d
    # equ-style definitions per segment: a split can separate an
    # equate's definition from its uses, and REL cannot export an
    # equate (Merlin: 'Bad label' on the ent fold, seen on PLAYM3's
    # R_* cells 2026-09-01). Equates emit nothing, so the fix is
    # REPLICATION: inject the line into every segment that needs
    # it, transitively, and keep equates out of ents/exts.
    seg_equ_lines = {}
    for _n, _lines, _d, _u in seg_texts:
        for _l in _lines:
            bare = _l[len('@HOIST@'):] if _l.startswith('@HOIST@')                 else _l
            m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s+(equ|=)\s',
                         bare.split(';')[0])
            if m:
                seg_equ_lines.setdefault(m.group(1), bare)
    # class 14: a dum cell crossing segments travels as a literal
    # equate (its ABSOLUTE address from the listing), never ENT/EXT.
    for s in sorted(dum_syms):
        if s in labeladdrs:
            seg_equ_lines.setdefault(
                s, f'{s} equ {labeladdrs[s]} ;GEN-LIT dum cell')
    segments = []
    for name, lines, defined, used in seg_texts:
        other_defs = set()
        for n2, d2 in seg_defs_all.items():
            if n2 != name:
                other_defs |= d2
        need = set(used) - set(defined)
        inject = []
        queue = sorted(need & set(seg_equ_lines))
        seen = set()
        while queue:
            symq = queue.pop(0)
            if symq in seen or symq in defined:
                continue
            seen.add(symq)
            line = seg_equ_lines[symq]
            inject.append(line)
            need.discard(symq)
            # symbol references only: hex/char/binary literals must
            # go first, or the letter-run INSIDE a hex literal reads
            # as a name -- `equ $10A0` yielded a phantom symbol A0
            # and fileproctest refused with nine such ghosts
            # (conversion class 7, found at the item-2 rollout).
            operand = line.split(';')[0].split(None, 2)[2]
            operand = re.sub(r"\$[0-9A-Fa-f]+|'[^']*'|\"[^\"]*\"|%[01]+",
                             ' ', operand)
            for ref in re.findall(r'[A-Za-z_][A-Za-z0-9_]*', operand):
                if ref in seg_equ_lines and ref not in seen:
                    queue.append(ref)
                elif ref not in defined:
                    need.add(ref)
        chosen = []
        changed = True
        while changed:
            changed = False
            for path in EQU_ORDER:
                if path not in equ_defs or path in chosen:
                    continue
                if equ_defs[path] & need:
                    chosen.append(path)
                    need |= ckm.scan(os.path.join(ROOT, path))[1]
                    changed = True
        chosen.sort(key=EQU_ORDER.index)
        exts = sorted((need - all_equ) & (kernel_defs | other_defs))
        unresolved = need - all_equ - kernel_defs - other_defs
        if unresolved:
            raise SystemExit(f'{rel}: segment {name}: unresolved '
                             f'{sorted(unresolved)}')
        # hazard 1: an emitted operand computing a DIFFERENCE that
        # involves an external cannot cross the REL linker. Rewrite
        # each such item to a GENERATION-TIME LITERAL from the
        # monolithic listing's label addresses -- same honesty
        # argument as the ds pads: the byte-identity gate rebuilds
        # the reference every run, so a stale literal cannot pass.
        addrs = _listing_addrs(listing) if listing else {}
        new_lines = []
        for raw in lines:
            code = raw.split(';')[0]
            m = re.match(r'^(\S*\s+)(dfb|dw|da|ddb)(\s+)(.*?)(\s*)$',
                         code)
            if not m:
                new_lines.append(raw)
                continue
            items = m.group(4).split(',')
            changed = False
            out_items = []
            for expr in items:
                ids = re.findall(r'[A-Za-z_][A-Za-z0-9_]*', expr)
                if '-' in expr and any(i in exts for i in ids):
                    em = re.match(
                        r'^\s*([<>])\s*([A-Za-z_][A-Za-z0-9_]*)\s*-'
                        r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*$', expr)
                    if not em or em.group(2) not in addrs \
                            or em.group(3) not in addrs:
                        raise SystemExit(
                            f'{rel}: segment {name}: cross-module '
                            f'difference {expr.strip()!r} not of the '
                            f'byte-select shape the literal rewrite '
                            f'handles (or labels missing from the '
                            f'listing) -- S9-PLAN 6b hazard 1')
                    diff = addrs[em.group(2)] - addrs[em.group(3)]
                    val = diff & 0xFF if em.group(1) == '<' \
                        else (diff >> 8) & 0xFF
                    out_items.append(f'${val:02X}')
                    changed = True
                else:
                    out_items.append(expr.strip())
            if changed:
                new_lines.append(
                    f'{m.group(1)}{m.group(2)} ' + ','.join(out_items)
                    + f' ;GEN-LIT {m.group(4).strip()}')
            else:
                new_lines.append(raw)
        lines = new_lines
        equ_defined_here = {s2 for s2 in defined
                            if s2 in seg_equ_lines}
        ents = sorted((set(defined) - equ_defined_here)
                      & (kernel_used
                         | set().union(*(u for n2, _, _, u in seg_texts
                                         if n2 != name))))
        out = [f'* {name} -- {rel} segment, GENERATED,',
               f'* do not edit (gen_rel_module.generate_kernel_main)',
               ' rel', ' lst off', ' tr', ' exp off', ' xc']
        mod_dir = os.path.dirname(rel)
        for path in chosen:
            out.append(f' put {os.path.relpath(path, mod_dir)}')
        for sym in exts:
            out.append(f'{sym} ext')
        for line in inject:
            # COMPACT: the original line plus a marker overruns real
            # Merlin's 64-char limit, which refuses the LINE and then
            # reports Unknown label at every USE (10 errors on
            # PLAYM4's first run, none of them pointing here)
            im = re.match(
                r'^([A-Za-z_][A-Za-z0-9_]*)\s+(?:equ|=)\s+(\S+)',
                line.split(';')[0])
            out.append(f'{im.group(1)} equ {im.group(2)} ;REPL')
        for raw in lines:
            if raw.startswith('@HOIST@'):
                out.append(raw[len('@HOIST@'):])
        ent_set = set(ents)
        for raw in lines:
            if raw.startswith('@HOIST@'):
                continue
            line = raw.rstrip('\n')
            m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)(\s+)(.*)$', line)
            if m and m.group(1) in ent_set:
                out.append(f'{m.group(1)} ent')
                out.append(f' {m.group(3)}' if m.group(3) else '')
                ent_set.discard(m.group(1))
                continue
            m2 = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*$', line)
            if m2 and m2.group(1) in ent_set:
                out.append(f'{m2.group(1)} ent')
                ent_set.discard(m2.group(1))
                continue
            out.append(line)
        if ent_set:
            raise SystemExit(f'{rel}: segment {name}: exported symbols '
                             f'never defined: {sorted(ent_set)}')
        segments.append((name, '\n'.join(out) + '\n'))
    return segments, {'link': link}


def generate_split_main(manifest, listing, split_at, dsk=None):
    """A src/bin manifest whose REL MAIN would overflow as's OBJECT
    buffer (S9-PLAN 6b stage C): as.s's single main would emit
    11,053 B against the 7,936 B object cap, so the main is split
    into CONSECUTIVE modules at the named global labels -- for as,
    the two blob boundaries, giving front-end / bank1-blob /
    core+stubs pieces, every one under the cap. Link order is
    [pieces...] + liba modules + bss, which is put order, which is
    byte identity.

    Reuses generate_main for the liba link list and the bss
    extraction; this function re-walks the manifest for the piece
    texts because the split needs per-piece ENT/EXT and equ-put
    closures. PC equates (`X equ *-LABEL`) become GENERATION-TIME
    LITERALS from the monolithic listing, HOISTED into the first
    piece (their users' home; an equate cannot cross the linker,
    and as a PC expression it could not survive REL at all).
    `putbin` lines pass through -- the image builder rewrites them
    into staged HEX put chains (stage_putbin), the same treatment
    the maux-src staging gives them.

    A `split_at` entry spelled `put:NAME.s` cuts BEFORE that body
    put (ld's main is 4,813 B of put code with no label of its own
    to cut at, 2026-09-13); each piece scans the body modules it
    carries for its own ENT/EXT surface. `ds EXPR-*` pads (plasma's
    page-aligned OPTBL, proshimpg's $BFxx table layout) become
    literal `ds N` from the listing, the same GEN-LIT treatment as
    the PC equates; an `err` inside a dum block is a monolithic
    layout tripwire and is dropped (the byte compare is the check).

    Returns (pieces: [(name_suffix, text)], bss_texts, meta)."""
    import tempfile
    manifest = os.path.join(ROOT, manifest) \
        if not os.path.isabs(manifest) else manifest
    rel = os.path.relpath(manifest, ROOT)
    src = os.path.basename(manifest)
    _, bss_texts, meta = generate_main(rel, dsk=None)
    modules = meta['modules']
    bss_cells = set(meta.get('bss_cells') or [])
    lineaddrs = _listing_line_addrs(listing)
    labeladdrs = _listing_addrs(listing)
    liba_defs = _liba_defs(manifest, peer_dir='src/liba')
    equ_defs = _equ_defs()

    hoist = []
    man_equs = []                   # (name, line): the manifest's own
    pieces_lines = [[]]
    body_mods = [[]]                # per piece
    put_cuts = {c[4:] for c in split_at if c.startswith('put:')}
    in_bss = 0
    in_dum = 0
    man_env = _equ_env(
        open(manifest, encoding='latin-1').read().split('\n'))
    for lineno, raw in enumerate(
            open(manifest, encoding='latin-1').read().split('\n'), 1):
        code = raw.split(';')[0]
        m = re.match(r'^\s+put\s+(\S+)', code)
        if m:
            tgt = m.group(1)
            if '/liba/' in tgt and tgt.endswith('.s'):
                continue                    # a link-list module
            if os.path.basename(tgt) in put_cuts:
                pieces_lines.append([])
                body_mods.append([])
            if not tgt.endswith('.equ'):
                body_mods[-1].append(os.path.normpath(os.path.join(
                    os.path.dirname(manifest), tgt)))
            pieces_lines[-1].append(f' put {tgt}')
            continue
        if re.match(r'^\s+(org|dsk|lst|xc|typ)\b', code):
            # the piece head supplies lst/xc once -- a SECOND xc
            # flips Merlin (and as's core) into 65816 mode, which
            # is how ASM.S alone failed while every kernel segment
            # (whose generator filters these) assembled clean.
            continue
        if re.match(r'^\s+err\b', code) and '*' in code:
            continue
        lit = _dum_absolute(code, man_env)
        if lit is not None:
            pieces_lines[-1].append(
                f' dum ${lit:04X} ;GEN-LIT {code.split()[1]}')
            in_dum = 1
            continue
        if re.match(r'^\s+dum\s+[A-Za-z_]', code):
            in_bss = 1
            continue
        if in_bss:
            if re.match(r'^\s+dend\b', code):
                in_bss = 0
            continue                       # generate_main owns bss
        if re.match(r'^\s+dum\s+\*\s*$', code):
            # `dum *` (plasma's trailing cells): REL forbids a
            # relative dum origin ("Illegal relative adrs"), so it
            # becomes the listing's literal -- the cells are then
            # absolute at the addresses the monolithic build gave
            # them, the same way a literal `dum $xxxx` overlay is
            key = (src, lineno)
            if key not in lineaddrs:
                raise SystemExit(f'{rel}: `dum *` at line {lineno} '
                                 f'missing from {listing}')
            pieces_lines[-1].append(
                f' dum ${lineaddrs[key]:04X} ;GEN-LIT *')
            in_dum = 1
            continue
        if re.match(r'^\s+dum\b', code):
            in_dum = 1                     # literal dum: kept
        elif re.match(r'^\s+dend\b', code):
            in_dum = 0
        elif in_dum and re.match(r'^\s+err\b', code):
            continue                       # layout tripwire
        mds = re.match(
            r'^([A-Za-z_][A-Za-z0-9_]*)?\s+ds\s+(\S+)\s*$', code)
        if mds and '*' in mds.group(2):
            key = (src, lineno)
            ed = re.match(r'^(\$[0-9A-Fa-f]+|[A-Za-z_][A-Za-z0-9_]*)'
                          r'-\*$', mds.group(2))
            tgt = None
            if ed:
                t = ed.group(1)
                tgt = int(t[1:], 16) if t.startswith('$') \
                    else labeladdrs.get(t)
            if tgt is None or key not in lineaddrs:
                raise SystemExit(
                    f'{rel}: PC ds at line {lineno} '
                    f'({mds.group(2)!r}) not of the EXPR-* shape, '
                    f'or missing from {listing}')
            n = tgt - lineaddrs[key]
            if n < 0:
                raise SystemExit(f'{rel}: PC ds at line {lineno} '
                                 f'pads backwards ({n})')
            pieces_lines[-1].append(
                f'{mds.group(1) or ""} ds {n} ;GEN-LIT {mds.group(2)}')
            continue
        meq = re.match(
            r'^([A-Za-z_][A-Za-z0-9_]*)\s+equ\s+(.*?)\s*$', code)
        if meq and '*' in meq.group(2):
            em = re.match(r'^\*\s*-\s*([A-Za-z_][A-Za-z0-9_]*)$',
                          meq.group(2))
            key = (src, lineno)
            if not em or key not in lineaddrs \
                    or em.group(1) not in labeladdrs:
                raise SystemExit(
                    f'{rel}: PC equate at line {lineno} '
                    f'({meq.group(2)!r}) not of the *-LABEL shape, '
                    f'or missing from {listing}')
            val = lineaddrs[key] - labeladdrs[em.group(1)]
            hoist.append(f'{meq.group(1)} equ {val} '
                         f';GEN-LIT {meq.group(2)}')
            continue
        if meq:
            man_equs.append((meq.group(1), raw.rstrip('\n')))
        mlbl = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)', code)
        if mlbl and mlbl.group(1) in split_at:
            pieces_lines.append([])
            body_mods.append([])
        # a LABEL-LABEL difference in an operand (proshim's `ldx
        # #SVKB_END-SVKB_TBL-1`) is a link-time constant no fixup can
        # carry; when both labels are in the listing it becomes the
        # number, so a cut may fall between the use and the labels
        raw = _lit_label_diff(raw, labeladdrs)
        pieces_lines[-1].append(raw)

    # per-piece symbol surface (piece text + , for the first piece,
    # its body puts -- the window splits put the front-end code
    # there and its liba/equ references belong to the piece).
    scans = []
    for i, plines in enumerate(pieces_lines):
        with tempfile.NamedTemporaryFile(
                'w', suffix='.s', delete=False) as tf:
            tf.write('\n'.join(plines) + '\n')
            tpath = tf.name
        d, u = ckm.scan(tpath)
        os.unlink(tpath)
        d, u = set(d), set(u)
        for bp in body_mods[i]:
            bd, bu = ckm.scan(bp)
            d |= bd
            u |= bu
        if i == 0:
            d |= {h.split()[0] for h in hoist}
        scans.append((d, u))

    all_equ = set().union(*equ_defs.values()) if equ_defs else set()
    # the manifest's own equates (and the hoisted PC literals) are
    # CONSTANTS: a later piece that uses one gets a COPY in its head,
    # in source order, never an ent/ext -- an exported equate would
    # be relocated by the linker and, for a zero-page one, would
    # assemble its users absolute (3 bytes for 2). Same rule as the
    # nas-route body-put split (build_nas_librel_image).
    man_equs = man_equs + [(h.split()[0], h) for h in hoist]
    equ_names = {n for n, _ in man_equs}
    pieces = []
    body_ents = {}
    for i, plines in enumerate(pieces_lines):
        d, u = scans[i]
        other_d = set()
        for j, (dj, _uj) in enumerate(scans):
            if j != i:
                other_d |= dj
        other_d -= equ_names
        copies = []
        if i > 0:
            want = u & equ_names
            grow = True
            while grow:
                grow = False
                for n, line in man_equs:
                    if n in want:
                        rhs = line.split(';')[0].split(None, 2)[2]
                        for t in re.findall(r'[A-Za-z_][A-Za-z0-9_]*',
                                            rhs):
                            if t in equ_names and t not in want:
                                want.add(t)
                                grow = True
            copies = [line for n, line in man_equs if n in want]
            for line in copies:
                rhs = line.split(';')[0].split(None, 2)[2]
                u |= set(re.findall(r'[A-Za-z_][A-Za-z0-9_]*', rhs))
            d = d | want
        need = u - d
        chosen = []
        changed = True
        while changed:
            changed = False
            for path in EQU_ORDER:
                if path not in equ_defs or path in chosen:
                    continue
                if equ_defs[path] & need:
                    chosen.append(path)
                    need |= ckm.scan(os.path.join(ROOT, path))[1]
                    changed = True
        chosen.sort(key=EQU_ORDER.index)
        exts = sorted((need & set(liba_defs))
                      | (need & other_d) | (bss_cells & u))
        ents = sorted((d - equ_names) & set().union(
            *(uj for j, (_dj, uj) in enumerate(scans) if j != i)))
        base = os.path.basename(rel)[:-2]
        suffix = 'M' if i == 0 else f'M{i + 1}'
        head = [f'* {base}{suffix} -- {rel} REL main piece '
                f'{i + 1}/{len(pieces_lines)}, GENERATED,',
                f'* do not edit (gen_rel_module.generate_split_main)',
                ' rel']
        if dsk:
            head.append(f' dsk {dsk}{suffix}R')
        head += [' lst off', ' tr', ' exp off', ' xc']
        mod_dir = os.path.dirname(rel)
        # the first piece keeps the manifest's own equ-put lines in
        # place; later pieces get their closures prepended
        if i > 0:
            for path in chosen:
                head.append(f' put {os.path.relpath(path, mod_dir)}')
            head += copies
        for sym in exts:
            head.append(f'{sym} ext')
        out = list(head)
        if i == 0:
            out += hoist
        ent_set = set(ents)
        for raw in plines:
            line = raw.rstrip('\n')
            m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)(\s+)(.*)$', line)
            if m and m.group(1) in ent_set:
                out.append(f'{m.group(1)} ent')
                out.append(f' {m.group(3)}' if m.group(3) else '')
                ent_set.discard(m.group(1))
                continue
            m2 = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*$', line)
            if m2 and m2.group(1) in ent_set:
                out.append(f'{m2.group(1)} ent')
                ent_set.discard(m2.group(1))
                continue
            out.append(line)
        # an export defined inside one of this piece's body puts:
        # the staged per-util copy of that put gets the `ent` (the
        # image builder rewrites it -- body_ents), since a piece
        # cannot `ent` a label it does not spell itself
        for bp in body_mods[i]:
            here = ent_set & ckm.scan(bp)[0]
            if here:
                bequ = set(re.findall(
                    r'^([A-Za-z_][A-Za-z0-9_]*)\s+equ\s', open(
                        bp, encoding='latin-1').read(), re.M))
                if here & bequ:
                    raise SystemExit(
                        f'{rel}: piece {suffix}: {sorted(here & bequ)} '
                        f'are equates in {os.path.relpath(bp, ROOT)} '
                        f'used by another piece -- an equate cannot '
                        f'be exported; copy it instead')
                body_ents.setdefault(bp, set()).update(here)
                ent_set -= here
        if ent_set:
            raise SystemExit(f'{rel}: piece {suffix}: exported '
                             f'symbols never defined: {sorted(ent_set)}')
        pieces.append((suffix, '\n'.join(out) + '\n'))
    meta['pieces'] = [s for s, _ in pieces]
    meta['body_ents'] = {os.path.relpath(k, ROOT): sorted(v)
                         for k, v in body_ents.items()}
    # a PC equate INSIDE a body put (plasmavm.s `TMPLEN equ
    # *-INNERTMP`) gets the same listing literal, applied to the
    # staged per-util copy (body_lits: line number -> replacement)
    body_lits = {}
    for mods_ in body_mods:
        for bp in mods_:
            bn = os.path.basename(bp)
            for ln_, raw in enumerate(
                    open(bp, encoding='latin-1').read().split('\n'), 1):
                code = raw.split(';')[0]
                meq = re.match(
                    r'^([A-Za-z_][A-Za-z0-9_]*)\s+equ\s+(.*?)\s*$', code)
                if not meq or '*' not in meq.group(2):
                    continue
                em = re.match(r'^\*\s*-\s*([A-Za-z_][A-Za-z0-9_]*)$',
                              meq.group(2))
                key = (bn, ln_)
                if not em or key not in lineaddrs \
                        or em.group(1) not in labeladdrs:
                    raise SystemExit(
                        f'{os.path.relpath(bp, ROOT)}: PC equate at '
                        f'line {ln_} ({meq.group(2)!r}) not of the '
                        f'*-LABEL shape, or missing from {listing}')
                val = lineaddrs[key] - labeladdrs[em.group(1)]
                body_lits.setdefault(os.path.relpath(bp, ROOT), {})[
                    ln_] = (f'{meq.group(1)} equ {val} '
                            f';GEN-LIT {meq.group(2)}')
    meta['body_lits'] = body_lits
    return pieces, bss_texts, meta


def lit_rewrite(text, lits):
    """Replace the numbered lines of a staged body-put copy with
    their listing literals (generate_split_main's body_lits)."""
    out = text.split('\n')
    for ln_, rep in lits.items():
        out[ln_ - 1] = rep
    return '\n'.join(out)


_STRING_MN = {'asc', 'dci', 'str', 'inv', 'fls', 'rev', 'hex'}


def _lit_label_diff(raw, labeladdrs):
    """Rewrite `A-B` (both listing labels) in a code line's operand
    to its numeric value, tagged ;GEN-LIT. Equates are not in
    labeladdrs, so `X equ *-LABEL` and constant arithmetic pass."""
    code, sep, comment = raw.partition(';')
    m = re.match(r'^(\S*\s+)(\S+)(\s+)(.*?)(\s*)$', code)
    if not m or m.group(2).lower() in _STRING_MN | {'equ', '='}:
        return raw
    opnd = m.group(4)
    if not opnd:
        return raw
    changed = []

    def sub(mm):
        a, b = mm.group(1), mm.group(2)
        if a in labeladdrs and b in labeladdrs:
            changed.append(f'{a}-{b}')
            return str(labeladdrs[a] - labeladdrs[b])
        return mm.group(0)
    new = re.sub(r'(?<![A-Za-z0-9_$])([A-Za-z_][A-Za-z0-9_]*)-'
                 r'([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_])', sub, opnd)
    if not changed:
        return raw
    return (f'{m.group(1)}{m.group(2)}{m.group(3)}{new} ;GEN-LIT '
            f'{" ".join(changed)}')


def ent_rewrite(text, ents):
    """Insert `LABEL ent` ahead of each named label's defining line
    (the split-main export form), for a staged body-put copy."""
    out = []
    left = set(ents)
    for line in text.split('\n'):
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)(\s+)(.*)$', line)
        if m and m.group(1) in left:
            out.append(f'{m.group(1)} ent')
            out.append(f' {m.group(3)}' if m.group(3) else '')
            left.discard(m.group(1))
            continue
        m2 = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*$', line)
        if m2 and m2.group(1) in left:
            out.append(f'{m2.group(1)} ent')
            left.discard(m2.group(1))
            continue
        out.append(line)
    if left:
        raise SystemExit(f'ent_rewrite: {sorted(left)} not defined')
    return '\n'.join(out)
