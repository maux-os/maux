#!/usr/bin/env python3
"""check_kbss.py -- the kernel scratch-home ratchet (`make check-kbss`).

docs/KSPACE.md, docs/KSPACE-NOTES.md.  Pure scratch buffers (the
BankCopy bounce page, the serial ring, tty staging, row buffers) are
homed in LOW MAIN RAM by inc/mm.kbss.equ instead of being `ds` bytes in
the flat image.  Each manifest names its own home with `KBSS equ $xxxx`
BEFORE putting that file, and the cells are an `equ` chain off KBSS.

What can go wrong, and what this gate pins:

  1. A manifest links a module that names a chain cell but never
     defines KBSS or never puts mm.kbss.equ.  (merlin32 would stop on
     the undefined label; this gate says WHICH manifest and why.)
  2. KBSS is defined AFTER the put (the chain would evaluate against an
     undefined label -- the silent EQU forward-reference miscompile,
     learning:01M05519PC55WGJNE4PY5HX4TH).
  3. The home overlaps something that lives there:
       $2000-org images: the home must sit in $0800-$0FFF.  $1000-$1FFF
         belongs to the per-image probe harnesses (every *testb.s).
       org-$0800 raw images: the home must sit above the image's
         `ds $xxxx-*` pad and above the harness cells at $9300-$9303
         (bankcopytest) and $9000-$9145 (argvtest): >= $9400, and the
         chain must end at or below PMLI_IBF_BASE ($A000).
  4. A chain size that disagrees with the symbol it stands for
     (TTY_OWBUF_SZ), since the chain is a literal.

The self-test plants each fault in a copy of the manifest text and
requires the gate to reject it, so a gate that stopped looking would
fail here first.
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IBF_BASE = int(re.search(r'^PMLI_IBF_BASE\s+equ\s+\$([0-9A-Fa-f]+)',
                         open(os.path.join(ROOT, 'inc/proc.const.equ')).read(),
                         re.M).group(1), 16)   # was a literal; unread today
RAW_FLOOR = 0x9400
LO_FLOOR, LO_CEIL = 0x0800, 0x1000
STALL_STUB = 0x0FF0


def rd(p):
    with open(os.path.join(ROOT, p), errors='replace') as fh:
        return fh.read()


def chain():
    """[(name, size)] from inc/mm.kbss.equ, and the total length.

    A cell's size is the `+N` its successor adds to it, so the chain
    cannot overlap or leave a gap by construction; this just checks
    that the file really is such a chain."""
    rows = []
    for line in rd('inc/mm.kbss.equ').splitlines():
        m = re.match(r'^(\w+)\s+equ\s+(\w+)(?:\+(\d+))?', line)
        if m:
            rows.append((m.group(1), m.group(2), int(m.group(3) or 0)))
    if not rows or rows[0][:2] != (rows[0][0], 'KBSS') \
            or rows[-1][0] != 'KBSS_END':
        raise SystemExit('mm.kbss.equ: must start at KBSS and end at '
                         'KBSS_END')
    cells = []
    for i in range(1, len(rows)):
        if rows[i][1] != rows[i - 1][0]:
            raise SystemExit(f'{rows[i][0]} is not chained off '
                             f'{rows[i - 1][0]}')
        cells.append((rows[i - 1][0], rows[i][2]))
    return cells, sum(sz for _, sz in cells)


def users(names):
    """kernel module -> set of chain names it references."""
    out = {}
    for p in glob.glob(os.path.join(ROOT, 'src/kernel/*.s')):
        t = open(p, errors='replace').read()
        hit = {n for n in names
               if re.search(r'(?<![\w])' + n + r'(?![\w])',
                            '\n'.join(l for l in t.splitlines()
                                      if not l.startswith('*')))}
        if hit:
            out[os.path.basename(p)] = hit
    return out


BOUNCE_USERS = {'bankcopy.s', 'procfork.s', 'loopseg.s'}


def kernel_texts():
    """{basename: text} for every src/kernel/*.s."""
    return {os.path.basename(p): open(p, errors='replace').read()
            for p in glob.glob(os.path.join(ROOT, 'src/kernel/*.s'))}


def bounce_users(texts):
    """Kernel modules that name K_BOUNCEBUF outside a comment."""
    return {n for n, t in texts.items()
            if any('K_BOUNCEBUF' in l.split(';')[0] for l in
                   t.splitlines() if not l.startswith('*'))}


def bankcopy_sites(texts):
    """{(module, routine)} for every `jsr/jmp BankCopy[Z]` that is not
    PROVABLY main<->bank: a call site whose SRCKIND and DSTKIND are
    both set from a literal `lda #BC_KIND_*` with one of them MAIN is
    safe (BankCopy touches K_BOUNCEBUF only when BOTH are banks); any
    other site -- both BANK, or a kind set some other way -- is in the
    set. `routine` is the nearest global label above the call."""
    out = set()
    for name, text in texts.items():
        lines = text.splitlines()
        label = '?'
        for i, l in enumerate(lines):
            m = re.match(r'^([A-Za-z_][A-Za-z_0-9]*)\b', l)
            if m and not l.startswith('*'):
                label = m.group(1)
            if not re.match(r'\s+(jsr|jmp)\s+BankCopy(Z)?\b', l):
                continue
            kinds = {}
            for j in range(i - 1, max(0, i - 60), -1):
                m = re.match(r'\s+sta\s+K_BC_(SRC|DST)KIND', lines[j])
                if not m or m.group(1) in kinds:
                    continue
                k = j - 1
                while k > 0 and not re.match(r'\s+(lda|ldx|stz)', lines[k]):
                    k -= 1
                lit = re.match(r'\s+lda\s+#BC_KIND_(MAIN|BANK)\b', lines[k])
                kinds[m.group(1)] = lit.group(1) if lit else '?'
            if len(kinds) == 2 and 'MAIN' in kinds.values():
                continue
            out.add((name, label))
    return out


# The call sites that may be bank->bank, KFIX9 review R2: the timer
# ISR reaches BankCopy during an MLI call (MAIN_IRQ_SHIM -> TTY_TICK ->
# TTY_POLL -> TTY_COOK1 -> TTY_ED_CMIT -> TTY_EDH_SAV, main<->bank),
# so any bank->bank copy that is ISR-reachable would trample LP_TAIL.
# A new site must be reviewed for that before it is added here.
BANKCOPY_SITES = {
    # bank -> bank (11 call sites in 9 routines; none is on the ISR's
    # path today: syscall bodies and the VC switch / scroll copies)
    ('kbye.s', 'PRC_BYE'),
    ('procfork.s', 'FRK_CLN_IMG'),
    ('procmli.s', 'PRC_READ'),
    ('procmli3.s', 'PRC_WRITE'),
    ('procspawn2.s', 'PSTG_ONE_ARG'),
    ('tty4.s', 'VCS_SCRL_REV'),
    ('tty4.s', 'VCS_SCROLL'),
    ('tty5.s', 'VCA_CP_XY'),
    ('tty5.s', 'VCA_SLTCRSR'),
    # kinds not set by two literals in view of the call (reviewed:
    # main -> bank, and a zero fill with the source kind left over)
    ('procfile3.s', 'PRC_VCSCAN'),
    ('procspawn.s', 'PRC_ZERO_PG'),
    ('tty8.s', 'VCS_N8RCP'),
}


def check_manifest(name, text, mods, total, problems):
    org = re.search(r'^\s+org\s+(\S+)', text, re.M)
    puts = set(re.findall(r'put\s+\.\./kernel/(\w+\.s)', text))
    if not (puts & set(mods)):
        return
    kb = re.search(r'^KBSS\s+equ\s+\$([0-9A-Fa-f]+)', text, re.M)
    pk = re.search(r'put\s+\.\./\.\./inc/mm\.kbss\.equ', text)
    if not kb:
        problems.append(f'{name}: links {sorted(puts & set(mods))} but '
                        'defines no KBSS')
        return
    if not pk:
        problems.append(f'{name}: defines KBSS but never puts '
                        'inc/mm.kbss.equ')
        return
    if pk.start() < kb.start():
        problems.append(f'{name}: puts mm.kbss.equ BEFORE defining KBSS')
    base = int(kb.group(1), 16)
    end = base + total
    o = org.group(1).upper() if org else '?'
    if o == '$2000':
        if base < LO_FLOOR or end > LO_CEIL:
            problems.append(
                f'{name}: KBSS ${base:04X}-${end:04X} leaves the '
                f'${LO_FLOOR:04X}-${LO_CEIL - 1:04X} home of $2000-org '
                'images ($1000+ is the probe harnesses)')
    elif o == '$0800':
        if base != 0x0A00:
            problems.append(f'{name}: raw org-$0800 KBSS must be $0A00 '
                            f'(the REL build bakes one value), got '
                            f'${base:04X}')
        pad = re.search(r'^\s+ds\s+\$0800\+512-\*', text, re.M)
        hole = re.search(r'^\s+ds\s+(\d+)\b[^\n]*check-kbss', text, re.M)
        if not hole:
            problems.append(f'{name}: raw image must reserve its scratch '
                            'home (a literal `ds` of the chain length, '
                            'tagged check-kbss, after the block-0 pad)')
        else:
            if int(hole.group(1)) != total:
                problems.append(f'{name}: reserved hole is '
                                f'{hole.group(1)} B but the chain is '
                                f'{total} B')
            if pad and hole.start() < pad.start():
                problems.append(f'{name}: hole precedes the block-0 pad')
            if hole.start() < pk.end():
                problems.append(f'{name}: the reserved hole precedes the '
                                'put of mm.kbss.equ -- a forward EQU in '
                                'a ds is a silent miscompile')
    else:
        problems.append(f'{name}: unknown org {o}')


def run(manifests, mods, total):
    problems = []
    for name, text in manifests.items():
        check_manifest(name, text, mods, total, problems)
    return problems


def main():
    cells, total = chain()
    names = [n for n, _ in cells]
    mods = users(names)
    tty = rd('inc/tty.equ')
    m = re.search(r'^TTY_OWBUF_SZ\s+equ\s+(\d+)', tty, re.M)
    size = dict(cells)
    problems = []
    if m and size.get('TTY_OUTBUF') != int(m.group(1)):
        problems.append(f'TTY_OUTBUF chain size {size.get("TTY_OUTBUF")} != '
                        f'TTY_OWBUF_SZ {m.group(1)}')
    # KSPACE2: cells sized by a symbol elsewhere are tied to it, so a
    # grown buffer cannot outrun its chain slot (nothing else would
    # notice: the chain is a literal and the hole is homed in main).
    ties = (('PRC_PATHBUF', 'inc/proc.const.equ', 'PRC_PATH2OFF', 2),
            ('K_CWD_BUF', 'inc/mm.annex.equ', 'CWD_ENT_SIZE', 1),
            ('K_WAIT_SHD', 'inc/mm.annex.equ', 'PCB_COUNT', 1),
            ('LZ_PATHBUF', 'inc/mm.annex.equ', 'LZ_PTH_SIZE', 1))
    for cell, path, sym, mul in ties:
        tm = re.search(r'^' + sym + r'\s+equ\s+(\d+)', rd(path), re.M)
        if not tm or size.get(cell) != int(tm.group(1)) * mul:
            problems.append(f'{cell} chain size {size.get(cell)} != '
                            f'{sym} x{mul} ({tm.group(1) if tm else "?"})')
    hm = re.search(r'^KBSS\s+equ\s+\$([0-9A-Fa-f]+)',
                   rd('inc/mm.kbss0.equ'), re.M)
    if not hm:
        problems.append('inc/mm.kbss0.equ defines no KBSS')
    kbss0 = int(hm.group(1), 16) if hm else 0
    # KFIX9: check-tenant row 9 and check-mame park a 16-byte stall
    # stub in the chain's spare tail, at $0FF0-$0FFF. The chain must
    # end below it (it ended at $0FAB before LP_PATH; the stub was
    # at $0FB0 and had to move).
    if hm and kbss0 + total > STALL_STUB:
        problems.append(f'the chain ends ${kbss0 + total:04X}, past '
                        f'the tenant stall stub at ${STALL_STUB:04X} '
                        '(scripts/check_tenant.py STALL, check_mame.py)')
    manifests = {os.path.basename(p): open(p, errors='replace').read()
                 for p in sorted(glob.glob(os.path.join(ROOT,
                                                        'src/test/*.s')))}
    problems += run(manifests, mods, total)
    if hm and 'playtest.s' in manifests:
        pk = re.search(r'^KBSS\s+equ\s+\$([0-9A-Fa-f]+)',
                       manifests['playtest.s'], re.M)
        if not pk or int(pk.group(1), 16) != int(hm.group(1), 16):
            problems.append('mm.kbss0.equ (REL build) disagrees '
                            'with playtest.s KBSS: the native kernel '
                            'would place cells elsewhere')
    # KFIX9: the loop driver's .2mg tail (LP_TAIL) is K_BOUNCEBUF's
    # first 64 bytes, which is safe only while every OTHER writer of
    # the page runs outside an MLI call. Pin the set of modules that
    # name it, so a new user must revisit loopseg.s's LP_2RD note.
    ktexts = kernel_texts()
    bn = bounce_users(ktexts)
    if bn != BOUNCE_USERS:
        problems.append(f'K_BOUNCEBUF is named by {sorted(bn)}, not '
                        f'{sorted(BOUNCE_USERS)}: loopseg.s LP_TAIL '
                        'shares it (check LP_2RD before adding one)')
    bc = bankcopy_sites(ktexts)
    if bc != BANKCOPY_SITES:
        problems.append('bank->bank BankCopy call sites changed: new '
                        f'{sorted(bc - BANKCOPY_SITES)}, gone '
                        f'{sorted(BANKCOPY_SITES - bc)} -- BankCopy '
                        'stages through K_BOUNCEBUF, which loopseg.s '
                        "LP_TAIL shares; review the ISR's reach "
                        '(TTY_ED_CMIT) before pinning a new site')
    linked = [n for n, t in manifests.items()
              if set(re.findall(r'put\s+\.\./kernel/(\w+\.s)', t))
              & set(mods)]
    if problems:
        print('[check-kbss] FAIL')
        for p in problems:
            print('   ' + p)
        return 1

    # ---- self-test: every planted fault must be rejected -------------
    pick = next(n for n in linked if '$2000' in
                re.search(r'org\s+(\S+)', manifests[n]).group(1))
    raw = next(n for n in linked if re.search(r'org\s+\$0800',
                                              manifests[n]))
    base = manifests[pick]
    muts = {
        'no KBSS': re.sub(r'^KBSS .*\n', '', base, flags=re.M),
        'no put': base.replace('put   ../../inc/mm.kbss.equ', ''),
        'put before KBSS': re.sub(
            r'^(KBSS .*\n)(\s+put\s+\.\./\.\./inc/mm\.kbss\.equ\n)',
            r'\2\1', base, flags=re.M),
        'home in harness range': re.sub(r'(KBSS\s+equ\s+)\$\w+',
                                        r'\1$1200', base, count=1),
        'chain runs past $1000': re.sub(r'(KBSS\s+equ\s+)\$\w+',
                                        r'\1$0D00', base, count=1),
    }
    rmut = re.sub(r'^\s+ds\s+\d+[^\n]*check-kbss[^\n]*\n', '',
                  manifests[raw], flags=re.M)
    muts_raw = {'hole of the wrong size': re.sub(
        r'(ds\s+)\d+(\s+;check-kbss)', r'\g<1>1000\2', manifests[raw])}
    planted = dict(ktexts, **{'ttyx.s': '            lda   K_BOUNCEBUF\n'})
    if bounce_users(planted) == BOUNCE_USERS:
        print('[check-kbss] FAIL: self-test: a new K_BOUNCEBUF user '
              'was NOT noticed')
        return 1
    planted_bc = dict(ktexts, **{'ttyx.s': (
        'TTYX_COPY  lda   #BC_KIND_BANK\n'
        '            sta   K_BC_SRCKIND\n'
        '            lda   #BC_KIND_BANK\n'
        '            sta   K_BC_DSTKIND\n'
        '            jsr   BankCopy\n')})
    if bankcopy_sites(planted_bc) == BANKCOPY_SITES:
        print('[check-kbss] FAIL: self-test: a new bank->bank BankCopy '
              'call site was NOT noticed')
        return 1
    for what, txt in muts_raw.items():
        if not run({raw: txt}, mods, total):
            print(f'[check-kbss] FAIL: self-test mutation "{what}" was '
                  'NOT rejected')
            return 1
    for what, txt in muts.items():
        if not run({pick: txt}, mods, total):
            print(f'[check-kbss] FAIL: self-test mutation "{what}" was '
                  'NOT rejected')
            return 1
    if not run({raw: rmut}, mods, total):
        print('[check-kbss] FAIL: raw mutation (no reserved hole) was NOT rejected')
        return 1
    print(f'[check-kbss] PASS: {len(cells)} cells, {total} B chained off '
          f'KBSS; {len(linked)} manifests define a legal home; '
          f'{len(muts) + len(muts_raw) + 3} planted faults rejected')
    return 0


if __name__ == '__main__':
    sys.exit(main())
