#!/usr/bin/env python3
"""pt_f40.py -- the ONE copy of the PT_F40 40-column boot-force magic
(src/test/playtestb.s), shared by scripts/check_play.py and
scripts/e2e_term.py so the gate and the person-like harness never drift
into two numbers for one cell.

Before this file existed, check_play.py hardcoded these four values and
e2e_term.py had NO equivalent knob at all -- its 'text40' backend label
cat'd DEMO/VT* fixtures on whatever the play image boots by default
(native-80, docs/CONSOLE-VT102.md sec 7), so check-ildl's and
check-vt102's 'text40' legs silently exercised the N8 backend twice
instead of the 40-column path. Factoring the four bytes here, imported
by both, is deliberately NOT the full docs/E2E.md sec 5 equ-parsing
treatment (src/test/playtestb.s is a test fixture, not a program's own
declared limit) -- it is the narrower fix task #23 asked for: one
constant, two importers, no copy.

playtestb.s's ENTRY checks PT_F40/PT_F40B against these two magic bytes
BEFORE PRC_INIT runs (whose TTY_INIT reads TTY_BKND_REQ exactly once),
so a poke has to land after `reset` and before the machine is allowed
to run past that point -- both callers poke right after `reset`,
before `mount_disk`/stepping, the same as check_play.py's PT_HOLD poke.
"""

PT_F40_ADDR = 0x9FF0
PT_F40B_ADDR = 0x9FF1
PT_F40_MAG1 = 0xF4
PT_F40_MAG2 = 0x0A
