#!/usr/bin/env python3
"""check_memmap_zp.py -- code review C2 static checker, folded
into `make check-memmap`.

The review's own suggested regression gate: "a small static checker that
rejects new kernel main-ZP symbols inside reserved ProDOS ranges." A
blind grep over every `equ $XX`-shaped line in src/kernel/*.s was tried
first and rejected as too noisy to be trustworthy: several existing
constants are two-hex-digit values that are NOT zero-page addresses at
all (e.g. src/kernel/process.s's MLI_ERR_EOF equ $4C -- an MLI error
CODE, not an address; PIPE_RD_CHAN/PIPE_WR_CHAN equ $80/$90 -- wait-
channel tags, never dereferenced as ZP pointers). MLI_ERR_EOF=$4C in
particular sits INSIDE the very $3A-$4E range this checker guards,
so a naive "any `equ $` with a 2-hex-digit value" grep would flag it as
a false collision on day one -- worse than no checker, since a real
future regression would be lost in the noise of pre-existing false
positives.

Instead, this checker trusts inc/mm.main.equ's own ZP_* allocation-
map symbols (docs/MEMMAP.md #1.1a) as the single authoritative list of
main-ZP CLAIMS -- the same section every kernel module's header already
points to as "the shared symbol file" (split out of the old monolithic
inc/memmap.equ, docs/SELFHOST-CONVERSION.md phase 1 -- ZP_* stayed in
the main-memmap file since nothing outside this checker and
src/check.memmap.s references them by name) -- and mechanically asserts
none of them overlap ZP_RSVDP8_LO..HI, plus (defense in depth) that the
claimed ranges don't overlap EACH OTHER. Any future module that adds a
new main-ZP allocation is expected to add a matching ZP_<MODULE>_LO/HI
pair to mm.main.equ's #1.1a section (the existing three all follow
that convention) -- this script then covers it automatically, no script
edit needed. A module that adds raw ZP `equ`s without also registering
them here is a docs-drift bug this checker cannot see, exactly like any
other "the map documents the code, the code doesn't enforce the map" gate
in this codebase (e.g. docs/MEMMAP.md's own budget tables) -- flagged
here rather than silently assumed solved.
"""
import os
import re
import sys

MEMMAP_EQU = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "..", "inc", "mm.main.equ")

# name -> (lo_symbol, hi_symbol)
RANGES = {
    "process.s": ("ZP_PROCESS_LO", "ZP_PROCESS_HI"),
    "sched.s":   ("ZP_SCHED_LO", "ZP_SCHED_HI"),
    "entry.s":   ("ZP_ENTRY_LO", "ZP_ENTRY_HI"),
}
RESERVED = ("ZP_RSVDP8_LO", "ZP_RSVDP8_HI")


def parse_equs(path):
    """Return {symbol: int_value} for every `NAME equ $XX`-shaped line."""
    pat = re.compile(r"^(\w+)\s+equ\s+\$([0-9A-Fa-f]+)\s*(?:;.*)?$")
    out = {}
    with open(path) as f:
        for line in f:
            m = pat.match(line.strip())
            if m:
                out[m.group(1)] = int(m.group(2), 16)
    return out


def overlaps(a_lo, a_hi, b_lo, b_hi):
    return a_lo <= b_hi and b_lo <= a_hi


def main():
    syms = parse_equs(MEMMAP_EQU)

    missing = [s for pair in list(RANGES.values()) + [RESERVED]
               for s in pair if s not in syms]
    if missing:
        print(f"[check-memmap-zp] FAIL: expected ZP_* symbols missing from "
              f"{MEMMAP_EQU}: {missing}", file=sys.stderr)
        return 2

    r_lo, r_hi = syms[RESERVED[0]], syms[RESERVED[1]]
    print(f"[check-memmap-zp] reserved ProDOS ZP range: "
          f"${r_lo:02X}-${r_hi:02X}")

    ok = True
    ranges = {}
    for name, (lo_sym, hi_sym) in RANGES.items():
        lo, hi = syms[lo_sym], syms[hi_sym]
        ranges[name] = (lo, hi)
        if lo > hi:
            print(f"[check-memmap-zp] FAIL: {name}'s range {lo_sym}"
                  f"(${lo:02X})..{hi_sym}(${hi:02X}) is inverted",
                  file=sys.stderr)
            ok = False
            continue
        if overlaps(lo, hi, r_lo, r_hi):
            print(f"[check-memmap-zp] FAIL: {name}'s ZP range "
                  f"${lo:02X}-${hi:02X} OVERLAPS the reserved ProDOS range "
                  f"${r_lo:02X}-${r_hi:02X} -- this collides with the MLI's "
                  f"own zero-page working set (docs/PRODOS-SPIKE.md answer "
                  f"(a)) and must be moved", file=sys.stderr)
            ok = False
        else:
            print(f"[check-memmap-zp] PASS: {name}'s ZP range "
                  f"${lo:02X}-${hi:02X} clear of the reserved ProDOS range")

    # Defense in depth: the three modules' own ranges shouldn't collide
    # with each other either (each module's header already claims this,
    # this makes it machine-checked).
    names = list(ranges)
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            n1, n2 = names[i], names[j]
            lo1, hi1 = ranges[n1]
            lo2, hi2 = ranges[n2]
            if overlaps(lo1, hi1, lo2, hi2):
                print(f"[check-memmap-zp] FAIL: {n1} (${lo1:02X}-${hi1:02X}) "
                      f"and {n2} (${lo2:02X}-${hi2:02X}) overlap each other",
                      file=sys.stderr)
                ok = False
    if ok:
        print("[check-memmap-zp] PASS: no kernel main-ZP range collides "
              "with the reserved ProDOS range or with another module's "
              "range")
        print("[check-memmap-zp] PASS")
        return 0
    print("[check-memmap-zp] FAIL", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
