#!/usr/bin/env python3
"""gen_asbigmod.py -- generate build/asbigmod.s, the task #8 P11 proof
module (docs/AS-DESIGN.md section 15/16, requirement 5): a source LARGER
than as.s's OLD (pre-P11) achievable source-window capacity, to prove the
+8K P11 buys is real and USED, not just claimed.

NOT committed (like every other build/ artifact): deterministic and
mechanical, so there is nothing to keep in sync by hand -- re-running this
script always produces byte-identical output.

Sizing (derived from as.s's RDXFORM, read 2026-08-29, and verified by
running this fixture at the boundary -- see docs/S9-PLAN.md section 5):
SRC_BASE $6000, HIMEM_VAL $9FFF, and RDX_BOUND is HIMEM_VAL's PAGE, so
the ceiling is $9F00 with the per-byte check erroring the moment the
write pointer REACHES it -- window $6000..$9EFF = 16,128 bytes of which
the LAST is unusable (exact-fill errors). Max flat source = 16,127 B,
and TARGET pins this fixture at exactly that -- the aligned-boundary
fixture check_dialect.py's hazard 3b models against: if as's ceiling
ever regresses by even one byte, BIGMOD stops assembling and check-as
goes red. (The old fixture was ~14,021 B, 2,107 B of slack -- proof the
P11 widening was real, but blind to a one-page regression.)
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'build', 'asbigmod.s')

TARGET = 16127     # max flat source under as's window -- see header
NOP_COUNT = 3221   # total NOPs, one of them on the START line


def generate():
    lines = [' org $2000', 'START nop']
    lines.extend([' nop'] * (NOP_COUNT - 1))
    lines.append(' rts')
    text = '\n'.join(lines) + '\n'
    # pad to the EXACT boundary with blank lines (1 byte each) -- a
    # blank line assembles to nothing on both assemblers.
    text += '\n' * (TARGET - len(text))
    assert len(text) == TARGET, len(text)
    return text


def main():
    text = generate()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'w', newline='\n') as fh:
        fh.write(text)
    print(f'[gen-asbigmod] {OUT}: {len(text)}B, {NOP_COUNT} NOPs, '
          f'1 label (START)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
