#!/usr/bin/env python3
"""check_altzp.py -- the cross-flip cell-ordering gate.

WHY THIS EXISTS. On a //e, ALTZP steers three regions at once: zero page
($0000-$00FF), the hardware stack ($0100-$01FF), and the language card
($D000-$FFFF). maux is a bank-per-process kernel, so `STA ALTZPAUX` does
not merely change a soft switch -- it swaps the whole of that address
space out from under the running routine, replacing the KERNEL's cells
with the PROCESS's. A cell written before the flip and read after it
returns the other bank's copy.

That is a silent bug in the worst way: the wrong value is almost always
zero, because a freshly allocated bank is zeroed. So the read succeeds,
the value is plausible, and nothing crashes. It is caught only by a test
that asserts a NON-zero value -- which is why every instance so far was
found late, by a feature that finally had a reason to read the cell.

FIVE INSTANCES, ALL THE SAME SHAPE:
  1-2. docs/SYSCALL.md #5.1 and #7.7 -- cross-flip cell-ordering.
  3.   src/kernel/sched.s -- the comment there calls itself "a fourth
       instance in this kernel".
  4.   src/kernel/entry.s:265 -- K_RESULT/K_RESULT_ERR were read after
       `STA ALTZPAUX`, so every syscall return value came back as the
       process's stale zero. Fixed by caching in registers BEFORE the
       flip.
  5.   src/kernel/procspawn.s PRC_STMP_BANK (2026-08-27) -- `LDA P_BANK`
       after the flip, so every bank stamped itself BANK_ID=0. Latent
       for the life of the routine because nothing read BANK_ID until
       `$$` was implemented. Fixed with TAX/TXA across the flip.

A class with five instances and a zero-shaped failure mode is a class
that needs a ratchet, not another comment.

THE RULE. Inside an `STA ALTZPAUX` bracket, reading an ALTZP-governed
address is a defect unless the bracket carries a `* XBANK(<regions>):`
comment line stating why the cross-bank read is the intent. Writes are
NOT flagged: writing the other bank's memory is usually the whole reason
the bracket exists (procfork's ZP/stack copies, procspawn's synthesized
frame).

SANCTIONS ARE PER-REGION, NOT PER-BRACKET, and the distinction is the
whole gate. ALTZP steers three regions with three different intents:

    zp     $0000-$00FF   the kernel's OWN scratch lives here ($D0-$FC)
    stack  $0100-$01FF   where a process's trapframe lives
    lc     $D000-$FFFF   the $FFxx syscall stubs, per-bank

Nearly every legitimate bracket wants `stack` only -- it is patching a
trapframe. A per-BRACKET sanction would bless the zero-page read in the
same window, which is exactly instance 4: entry.s legitimately reads
FRAME_P ($0104) there, and the bug was an illegitimate K_RESULT ($F3)
read three lines away. Proven by sabotage 2026-08-27: with per-bracket
sanctions this gate passed the reintroduced entry.s bug; with per-region
sanctions it fails it. Only procfork's ZP-copy bracket may name `zp`.

Sanctions must also be LIVE: an `XBANK` naming a region the bracket
never reads fails too, so the marker cannot rot into a stale comment
that launders a future bug (cf. the tree's stale-comment rule).

TWO HOLES CLOSED 2026-08-27 BY ADVERSARIAL REVIEW, both of which made
this gate PASS over a real instance of the bug it exists to catch. A
false negative here is worse than no gate: it launders the class.

  * `dum` ARENAS ARE WALKED. The resolver read only `equ` lines, but
    most kernel state is `ds` storage inside a `dum <addr>` block --
    including the whole per-bank $FF00 page (BANK_ID, SYSCALL_ENTRY,
    IRQ_ENTRY, EXIT_TAIL). So `lda BANK_ID` inside an aux bracket,
    reading ANOTHER BANK'S identity byte, resolved to None and was
    skipped, and the `lc` region was largely unreachable -- the one
    governed region whose contents are per-process by construction.

  * A CLOSE THAT A BRANCH CAN JUMP OVER IS NOT A CLOSE. The walk is
    textual, so a `bne` past the `sta ALTZPMAIN` left it scanning as
    though ALTZP were main while at runtime it was aux. Rather than
    pretend to model 6502 control flow, the gate refuses the shape.

SECOND RULE, SAME WALK: NO PUSHES INSIDE THE WINDOW. Because ALTZP also
steers $0100-$01FF, the hardware stack inside an aux bracket IS the
process's own page 1. Any JSR/PHA/PHP/PLA between the flips scribbles
the very frame the bracket usually exists to read or patch -- procfork.s
and entry.s both state this discipline in prose ("no pushes OR reads
until TXS below"), and prose is what failed to prevent the five
instances above. The tree holds it tree-wide today; this keeps it that
way. RTS/RTI are exits, not violations -- they end the bracket.

Static -- no emulator, no merlin32, no prior build.
"""
import glob
import re
import sys

# ALTZP steers ZP+stack and the language card. $C0xx is I/O, never RAM,
# and is deliberately NOT governed.
def region_of(a):
    if a is None:
        return None
    if a <= 0x00FF:
        return 'zp'
    if a <= 0x01FF:
        return 'stack'
    if a >= 0xD000:
        return 'lc'
    return None


REGIONS = ('zp', 'stack', 'lc')


READ_OPS = r'(lda|ldx|ldy|cmp|cpx|cpy|adc|sbc|ora|and|eor|bit)'
READ_RE = re.compile(r'\b' + READ_OPS + r'\s+([^\s;]+)', re.I)
# RTS/RTI are bracket EXITS, not violations -- handled separately.
PUSH_RE = re.compile(r'\b(jsr|pha|php|phx|phy|pla|plp|plx|ply)\b', re.I)
#: Conditional/unconditional branches whose target could jump OVER a
#: bracket's `sta ALTZPMAIN`. `jmp` is deliberately included.
BRANCH_RE = re.compile(
    r'\b(bcc|bcs|beq|bne|bmi|bpl|bvc|bvs|bra|jmp)\s+([^\s;,()]+)', re.I)
LABEL_RE = re.compile(r'^(:?[A-Za-z_][A-Za-z_0-9]*)')
EQU_RE = re.compile(r'^([A-Z_0-9]+)\s+equ\s+\$([0-9A-Fa-f]{1,4})\s*(;.*)?$')


def _expr(tok, sym):
    """Evaluate a Merlin address/size expression, or None.

    Merlin has NO operator precedence -- strictly left to right (commons
    learning 01M051DJW89KV4JYM1EC9SDZ5Y) -- so `1+2*3` is 9, not 7. This
    evaluates the same way rather than deferring to Python's precedence.
    """
    parts = re.split(r'([+\-*])', tok.strip())
    total, op = None, '+'
    for p in parts:
        p = p.strip()
        if p in ('+', '-', '*'):
            op = p
            continue
        m = re.match(r'^\$([0-9A-Fa-f]{1,4})$', p)
        if m:
            v = int(m.group(1), 16)
        elif re.match(r'^\d+$', p):
            v = int(p)
        elif p in sym:
            v = sym[p]
        else:
            return None
        if total is None:
            total = v
        elif op == '+':
            total += v
        elif op == '-':
            total -= v
        else:
            total *= v
    return total


def build_symbols(paths):
    """Map every symbol to a literal address. Later definitions do not
    override earlier ones -- a duplicate name across units would make the
    gate's answer depend on glob order, so first-wins is stable.

    `dum` ARENAS ARE WALKED, NOT JUST `equ` LINES. Most kernel state is
    `ds` storage inside a `dum <addr>` block, not an `equ` -- including
    the ENTIRE per-bank $FF00 page (SYSCALL_ENTRY / IRQ_ENTRY /
    EXIT_TAIL / BANK_ID, inc/mm.procbnk2.equ). An `equ`-only
    resolver therefore could not see a single one of them, which left
    this gate's `lc` region ($D000-$FFFF) largely unreachable: the one
    ALTZP-governed region whose contents are PER PROCESS by construction
    was the region it could not check. `lda BANK_ID` inside an aux
    bracket -- reading another bank's identity byte -- resolved to None
    and was skipped. Found by review 2026-08-27.

    A SIZE IT CANNOT EVALUATE ABANDONS THE REST OF ITS ARENA, on
    purpose. Every later label in that block would be offset by an
    unknown amount, and a confidently WRONG address is worse here than
    no address at all: it can silently move a read out of a governed
    region and hide it.
    """
    sym = {}
    for f in paths:
        try:
            lines = open(f, errors='ignore').read().split('\n')
        except OSError:
            continue
        pc = None                      # current dum address, or None
        for raw in lines:
            line = raw.rstrip()
            if not line or line.lstrip().startswith('*'):
                continue
            code = line.split(';')[0]
            m = EQU_RE.match(line)
            if m:
                sym.setdefault(m.group(1), int(m.group(2), 16))
                continue
            m = re.match(r'^\s+dum\s+([^\s;]+)', code, re.I)
            if m:
                pc = _expr(m.group(1), sym)
                continue
            if re.match(r'^\s+dend\b', code, re.I):
                pc = None
                continue
            if pc is None:
                continue
            m = re.match(r'^([A-Za-z_][A-Za-z_0-9]*)?\s+'
                         r'(ds|db|dfb|dw|da)\s+([^\s;]+)', code, re.I)
            if not m:
                continue
            label, directive, arg = m.group(1), m.group(2).lower(), m.group(3)
            if label:
                sym.setdefault(label, pc)
            if directive == 'ds':
                size = _expr(arg, sym)
            elif directive in ('db', 'dfb'):
                size = len(arg.split(','))
            else:
                size = 2 * len(arg.split(','))
            if size is None or size < 0:
                pc = None              # abandon the arena, see docstring
                continue
            pc += size
    return sym


TERM_RE = re.compile(r'^(?:\$([0-9A-Fa-f]{1,4})|([A-Z_][A-Z_0-9]*)|(\d+))$')


def operand_addr(operand, sym):
    """Resolve an operand to an address, or None if it is not a direct
    memory reference. Immediates (#) are constants, not storage -- this
    is what keeps `LDA #SYS_GET_EOF` ($D1, a ProDOS command byte) from
    being mistaken for a zero-page read.

    OFFSET FORMS MUST RESOLVE, and this is not hypothetical. `K_RESULT`
    is $F3 and `K_RESULT_ERR` is $F4 -- so `LDA K_RESULT+1` IS the
    historical entry.s Bug B, merely spelled differently. An earlier cut
    of this function accepted only a bare `$xx` literal or a bare
    `^[A-Z_0-9]+$` symbol, so every `SYM+n` / `SYM-n` / `<SYM` / `>SYM`
    form silently returned None and skipped the check entirely.
    Sabotage-confirmed 2026-08-27: `lda K_RESULT+1` inside entry.s's aux
    bracket PASSED. That is a false negative in the exact bug this gate
    exists to catch, which is the worst failure mode it can have -- it
    would launder the class rather than stop it.

    Merlin's `<` / `>` (low/high byte) prefixes are stripped rather than
    evaluated: resolving to the base address is the CONSERVATIVE choice,
    since it keeps the operand inside the check instead of dropping it."""
    o = operand.strip()
    if o.startswith('#'):
        return None
    o = o.split(',')[0].strip()
    # indirect ( ) and Merlin's low/high-byte prefixes
    o = re.sub(r'^[\(<>|^]+', '', o).rstrip(')').strip()
    if not o:
        return None
    # Merlin has NO operator precedence: strict left-to-right (see the
    # commons' merlin32 dialect notes). Only + and - appear in address
    # expressions in this tree; anything else is left unresolved.
    parts = re.split(r'([+-])', o)
    total, op = 0, '+'
    for tok in parts:
        tok = tok.strip()
        if tok in ('+', '-'):
            op = tok
            continue
        m = TERM_RE.match(tok)
        if not m:
            return None
        if m.group(1) is not None:
            v = int(m.group(1), 16)
        elif m.group(2) is not None:
            if m.group(2) not in sym:
                return None
            v = sym[m.group(2)]
        else:
            v = int(m.group(3))
        total = total + v if op == '+' else total - v
    return total if 0 <= total <= 0xFFFF else None


def scan(path, sym):
    """Walk one file's ALTZPAUX brackets.

    Returns (violations, stale, bad_region, pushes).

    A bracket closes at `STA ALTZPMAIN` or at any flow exit (RTS/RTI/JMP)
    -- the exit forms matter because the switch-out path deliberately
    never closes its bracket: it flips to aux and JMPs into the process."""
    lines = open(path, errors='ignore').read().split('\n')

    # Where every label in this file is DEFINED. `:local` names repeat
    # across zones, so a name maps to a LIST and any definition at or
    # after the close counts -- conservative on purpose: the question is
    # "could control reach past the close", and a maybe is a yes.
    labels = {}
    for i, raw in enumerate(lines):
        if raw[:1] not in (' ', '\t', '*', ''):
            m = LABEL_RE.match(raw)
            if m:
                labels.setdefault(m.group(1), []).append(i + 1)

    violations, stale, bad_region, pushes = [], [], [], []
    skippable = []
    branches = []       # (line, target) seen since the bracket opened
    open_at = None      # line number of the STA ALTZPAUX
    sanction = None     # (line, {regions}, reason)
    used = set()        # regions a governed read actually touched

    def close(at=None):
        """Close the bracket. `at` is the line of the `sta ALTZPMAIN`,
        when that is what closed it.

        A CLOSE THAT CAN BE BRANCHED OVER IS NOT A CLOSE. The walker is
        textual, so it would resume scanning as though ALTZP were main
        while at runtime a taken branch left it aux -- and every
        governed read after that point becomes invisible. review
        2026-08-27 supplied the shape:

            txa
            bne   :stampid
            sta   ALTZPMAIN
        :stampid  lda   P_BANK      <-- aux for any non-zero bank

        No instance exists in the tree today; this refuses to let the
        first one in silently, rather than trying to model 6502 control
        flow, which a line walker cannot honestly do.
        """
        nonlocal open_at, sanction, used, branches
        if at is not None:
            for bl, target in branches:
                defs = labels.get(target, [])
                if not defs:
                    continue
                # RESOLVE TO THE NEAREST DEFINITION, not to any of them.
                # `:local` names repeat in every zone -- `:rd` and `:wr`
                # each appear in both of procfork's two copy loops -- so
                # "does ANY definition sit past the close" flags every
                # ordinary backward loop whose label happens to recur
                # later in the file. It did: two false positives on
                # FRK_CLN_ZP/FRK_CLN_STK. A branch goes to the label in
                # its own zone, which is the nearest one; ties break
                # forward, the direction that can actually skip a close.
                nearest = min(defs, key=lambda d: (abs(d - bl), -d))
                if nearest >= at:
                    skippable.append((path, open_at, bl, target, at))
        if sanction:
            for r in sorted(sanction[1] - used):
                stale.append((path, sanction[0], r, sanction[2]))
        open_at, sanction, used, branches = None, None, set(), []

    for i, raw in enumerate(lines):
        ln = i + 1
        if raw.lstrip().startswith('*'):
            m = re.match(r'^\*+\s*-*\s*XBANK\(([^)]*)\):\s*(.*)', raw.lstrip())
            if m and open_at:
                named = {r.strip().lower() for r in m.group(1).split(',')}
                for r in sorted(named - set(REGIONS)):
                    bad_region.append((path, ln, r))
                sanction = (ln, named & set(REGIONS), m.group(2).strip())
            continue
        code = raw.split(';')[0]
        if not code.strip():
            continue
        if re.search(r'\bsta\s+ALTZPAUX\b', code, re.I):
            if open_at:
                close()
            open_at, sanction, used, branches = ln, None, set(), []
            continue
        if not open_at:
            continue
        if re.search(r'\bsta\s+ALTZPMAIN\b', code, re.I):
            close(at=ln)
            continue
        b = BRANCH_RE.search(code)
        if b:
            branches.append((ln, b.group(2)))
        p = PUSH_RE.search(code)
        if p:
            pushes.append((path, ln, open_at, p.group(1).upper(),
                           raw.strip()[:48]))
        r = READ_RE.search(code)
        if r:
            a = operand_addr(r.group(2), sym)
            reg = region_of(a)
            if reg:
                used.add(reg)
                if not sanction or reg not in sanction[1]:
                    violations.append(
                        (path, ln, a, reg, raw.strip()[:52], open_at,
                         sanction[1] if sanction else set()))
        if re.search(r'\b(rts|rti|jmp)\b', code, re.I):
            close()
    if open_at:
        close()
    return violations, stale, bad_region, pushes, skippable


def main():
    sources = sorted(glob.glob('src/**/*.s', recursive=True))
    sym = build_symbols(sorted(glob.glob('inc/*.equ')) +
                        sorted(glob.glob('src/**/*.equ', recursive=True)) +
                        sources)

    violations, stale, bad_region, pushes, skippable = [], [], [], [], []
    brackets, sanctioned = 0, 0
    for f in sources:
        text = open(f, errors='ignore').read()
        brackets += len(re.findall(r'\bsta\s+ALTZPAUX\b', text, re.I))
        sanctioned += len([1 for line in text.split('\n')
                           if re.match(r'^\*+\s*-*\s*XBANK\(', line.lstrip())])
        v, s, b, p, k = scan(f, sym)
        violations += v
        stale += s
        bad_region += b
        pushes += p
        skippable += k

    print(f"[check-altzp] {len(sources)} source file(s), {brackets} "
          f"ALTZPAUX bracket(s), {sanctioned} XBANK sanction(s)")

    if violations:
        print(f"[check-altzp] {len(violations)} UNSANCTIONED read(s) of "
              f"ALTZP-governed memory inside an aux bracket:")
        for f, ln, a, reg, txt, sw, have in violations:
            print(f"    {f}:{ln}  ${a:04X} ({reg})  {txt}")
            if have:
                print(f"        bracket at line {sw} is sanctioned for "
                      f"{','.join(sorted(have))} -- NOT for {reg}.")
            else:
                print(f"        bracket opened at line {sw}; unsanctioned.")
            print(f"        This read returns the PROCESS's {reg}, not the "
                  f"kernel's.")
        print("[check-altzp] If the cross-bank read is intended, add")
        print("              `* XBANK(<regions>): <why>` in the bracket.")
        print("              If not: cache the value in a register BEFORE")
        print("              the flip (see PRC_STMP_BANK's TAX/TXA).")

    if stale:
        print(f"[check-altzp] {len(stale)} STALE sanction(s) -- a region "
              f"named by an XBANK that the bracket never reads:")
        for f, ln, reg, reason in stale:
            print(f"    {f}:{ln}  \"{reg}\" unused  ({reason})")
        print("[check-altzp] Drop that region; a marker guarding nothing")
        print("              will launder the next defect into this bracket.")

    if bad_region:
        print(f"[check-altzp] {len(bad_region)} unknown region name(s) "
              f"(expected any of {', '.join(REGIONS)}):")
        for f, ln, r in bad_region:
            print(f"    {f}:{ln}  \"{r}\"")

    if pushes:
        print(f"[check-altzp] {len(pushes)} stack-touching op(s) inside an "
              f"aux bracket -- the stack there is the PROCESS's page 1:")
        for f, ln, sw, op, txt in pushes:
            print(f"    {f}:{ln}  {op}  (bracket opened at {sw})  {txt}")
        print("[check-altzp] This scribbles the frame the bracket exists to")
        print("              handle. Move it outside the flips.")

    if skippable:
        print(f"[check-altzp] {len(skippable)} bracket close(s) that a "
              f"branch can jump OVER -- ALTZP is not provably restored:")
        for f, opened, bl, target, at in skippable:
            print(f"    {f}:{bl}  branches to `{target}`, which is defined "
                  f"at or after the `sta ALTZPMAIN` on line {at}")
            print(f"        (bracket opened at line {opened}) -- if that "
                  f"branch is taken, execution continues with ALTZP=aux")
            print(f"        and every governed read past line {at} stops "
                  f"being checked. Restructure so the close is "
                  f"unconditional.")

    if violations or stale or bad_region or pushes or skippable:
        print("[check-altzp] FAIL")
        return 1
    print("[check-altzp] PASS: every ALTZP-governed read inside an aux "
          "bracket is sanctioned FOR ITS REGION, every sanction is live, "
          "and no bracket touches the stack.")
    return 0


if __name__ == '__main__':
    sys.exit(main())
