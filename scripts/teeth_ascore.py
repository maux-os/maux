#!/usr/bin/env python3
"""teeth_ascore.py -- prove check-ascore's teeth, reproducibly, on
scripts/teeth_lib.py (HYG-4).

The house rule is that a gate which has never been watched failing
proves nothing. Each tooth builds the ascore image with ONE patch group
excluded (or the source corrupted / the audit sabotaged), runs the gate
with matching flags and requires it RED at the PAIRED assertion -- the
anchored marker `(a)`..`(e)` / `ASEXIT` in a `[check-ascore] FAIL:` line
-- so a sabotage that trips some other assertion first cannot pass for
the intended one. The clean baseline is the gate on the unflagged image;
no image-hash witness: the builder is deterministic only from a clean
build/ (three builds of one image were byte-identical), but a gate run
leaves residue the next build reads (measured: build, gate, rebuild gave
a different image), so a hash can neither prove the flag took effect nor
prove a restore. The anchored marker in the failure line is the evidence,
and the image is regenerated for every tooth anyway.

WHY THE BUILDER AND THE GATE ARE RUN DIRECTLY, NEVER THROUGH MAKE
(bitten 2026-08-19): `make check-ascore` depends on `ascore-image`, which
REBUILDS the image with the full patch set, so the image had every patch
while the gate was told to exclude one, and the (d) audit -- which
correctly re-derives against the exclusion -- reported a mass mismatch.
The teeth looked broken; the gate was right and the harness was wrong.

The image is single-use by construction (the gate's rebuild binds the
patched core over the boot file), so every tooth rebuilds it first.
Exit status: teeth_lib.py (0 all behaved, 1 a tooth did not bite, 2
runner broken).

  python3 scripts/teeth_ascore.py [name ...]    p1 p4 p5 p7 obj aud
  python3 scripts/teeth_ascore.py --dry
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import teeth_lib as T  # noqa: E402

IMAGE = 'build/ascore-teeth.po'
IMG = T.Path(IMAGE, deterministic=False, reason='the builder reads residue '
             'left by a gate run: not reproducible across one')
BUILD = 'python3 scripts/build_ascore_image.py --out ' + IMAGE
GATE = 'python3 scripts/check_ascore.py --image ' + IMAGE
SLOW = 2400

# name, builder flags, gate flags, marker the FAIL output must carry,
# and what the tooth proves if it fails that way.
TEETH = [
    # P11 excluded ALONGSIDE P1 here (2026-08-20, docs/AS-DESIGN.md
    # section 16): P1's own deletions are what keep MACASS.S:403's `DS
    # $F7D0-*` pad non-negative once P5's own +3B ASEXIT landing-pad JMP
    # is added -- the stock, unpatched layout has near-ZERO margin there
    # by design (empirically: excluding P1 alone, WITHOUT P11, lands the
    # JMP at exactly $F7CD, ending at $F7D0, DS=0, still valid). P11's
    # own +1B (ASSMAIN.S:22-24, no 1-byte accumulator op reaches $A0 from
    # the leftover $C0 -- see patches.py's own P11 comment) is exactly
    # enough to push that pre-existing zero margin negative, which real
    # Merlin does NOT flag as an error -- it silently emits PRINTENT's
    # first byte ($A9, LDA#) over the JMP's own high byte, corrupting the
    # self-jump (verified live: byte pattern `4C CE A9` at $F7CE instead
    # of a self-jump). This is orthogonal to what THIS tooth proves (P1's
    # symtab placement), so P11 is excluded here too rather than forcing
    # a byte-neutral encoding that doesn't exist on 6502 for an arbitrary
    # accumulator-to-accumulator immediate transform. P11 gets its OWN
    # tooth (scripts/check_as.py's big-module phase, exclude-P11 proven
    # separately, docs/AS-DESIGN.md section 16) -- this one still proves
    # P1 exactly as before.
    ('p1', ['--exclude', 'P1,P11'], ['--exclude', 'P1,P11'], '(c)',
     'symtab back in aux -- P1 is load-bearing'),
    ('p4', ['--exclude', 'P4'], ['--exclude', 'P4'], '(a)',
     'keyboard polls restored -- the latched poison key parks the run'),
    ('p5', ['--exclude', 'P5'], ['--exclude', 'P5'], 'ASEXIT',
     'no exit redirect -- the drives cannot run, and that is a FAILURE'),
    ('p7', ['--exclude', 'P7'], ['--exclude', 'P7'], '(e)',
     'DSK dispatch alive -- the directive opens a file again'),
    # P9 is DROPPED (2026-08-20, docs/AS-DESIGN.md section 14 -- see
    # src/merlin/patches.py's P9_LABEL_RETRY_NEUTER comment): it never had
    # a check-ascore-visible tooth (PACKOP2.S never exercises ISLOC/
    # FINDLAB0's retry loop), and once bug 4 (PUTBYT's RAMWRT) and the
    # WRITEOBJ/liba PTR1-PTR2 zero-page collision were fixed, `make
    # check-as` passes WITHOUT it too -- re-tested with a process core
    # built `--exclude P9` against both GOODMOD.S and src/test/
    # asmultitest.s (the multi-label/forward-ref/:LOCAL module P9's own
    # comment named as its residual-risk stress test), byte-identical.
    # No entry here: "P9" is no longer a group src/merlin/patches.py
    # knows, by design.
    ('obj', ['--corrupt-packop2'], [], '(b)',
     'a corrupted source stops matching the stock object'),
    ('aud', ['--sabotage-audit'], [], '(d)',
     'an edit outside the named patch set is caught'),
]


def tooth(name, build_flags, gate_flags, marker, proves):
    return T.Tooth(
        name, prep=T.Cmd(' '.join([BUILD] + build_flags), timeout=SLOW),
        artifacts=[IMG], witness=T.Intrinsic(
            'the builder flag is the mutation; the image hash is not '
            'reproducible across a gate run (notes 9.1), the marker is'),
        checks=[T.Check(T.Invocation(' '.join([GATE] + gate_flags),
                                     timeout=SLOW), 'ascore',
                        T.FailureMarker(marker),
                        baseline=T.Invocation(GATE, timeout=SLOW))])


T.main('ascore', [tooth(*t) for t in TEETH], match=T.EXACT,
       prep=T.Cmd(BUILD, timeout=SLOW), artifacts=[IMG])
