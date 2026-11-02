"""scratchclean -- a gate deletes the images it made when it passes.

check-posixutil copies build/play.po once per boot group (85 x 4 MB)
into a scratch directory keyed on the checkout path, and kept them all:
348 MB per checkout, forever (HYG-1, 2026-10-20: the Mac's data volume
hit 100% in the middle of a sweep with 13 such directories from
checkouts that no longer existed). check-posixsed and check-fowler had
the same shape on a smaller scale.

THE RULE: a gate removes exactly the files IT created, by the names it
recorded when it made them -- never a glob, never the directory. The
scratch directory may be an operator's own (POSIXUTIL_SCRATCH) or a
sibling checkout's, so it is left in place even when empty. On a
failure the images stay, because they are the evidence, and the
directory is printed so nobody has to guess where they went.
"""
import os
import sys


def settle(gate, scratch, made, ok):
    """Delete `made` (explicit paths) if `ok`; else name `scratch`."""
    kept = [p for p in made if os.path.exists(p)]
    if not ok:
        if kept:
            print(f'[{gate}] FAILED: {len(kept)} scratch image(s) kept '
                  f'as evidence in {scratch}', file=sys.stderr)
        return
    for p in kept:
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass
