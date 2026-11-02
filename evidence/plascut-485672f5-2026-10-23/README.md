# check-plascut at 485672f5 (2026-10-23)

`make check-plascut` on the Mac (verilogapple fast backend), run on the
`demo-plasma` branch at 485672f5 with the DEMO-PLASMA changes uncommitted
(they touch nothing check-plascut runs). Result: PASS. The log here is the
gate's own `[check-plascut]` lines, unedited.

The row the site quotes (docs/SITE.md sec 7.4, site/facts.py) is PC4: one
warm `nas -o T2.OBJ FIXTURE.S`, cooked by plascut, against the same
fixture through `plasma NAS` (warm seed, modular): 1,650,000 against
5,950,000 cycles, +-50k. The fixture assembles to a 34-byte object, so the
figure is the cost of LOADING nas, not of assembling a large file. It
replaces the 25.6 M / 32.5 M figures of 2026-09-13 in docs/PLASCUT.md,
which describe an earlier implementation.
