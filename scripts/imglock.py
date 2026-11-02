"""Serialize a disk-image build and publish the result ATOMICALLY.

Why this exists (2026-09-16): `play-image` is PHONY on purpose -- a gate
boots build/play.po on a WRITE-THROUGH mount and leaves its own files on
the volume, so the image has to be regenerated for every gate rather than
kept by mtime (the same reasoning the Makefile spells out over ed-image
and mli-image).  PHONY means make rebuilds it for EVERY dependent, and
the parallel sweep (scripts/sweep_par.sh) only serializes the gates whose
DIRECT prerequisite line names play-image -- so the 13 gates that reach
it transitively (check-proshim, check-mlival, check-plasm, check-nas*,
check-jobctl-b, ...) each re-ran the builder in their own lane, two at a
time.  Two builders on one path is not a near-miss: the loser's mmap of
the file the winner just truncated faults, and the sweep grew sporadic

    make: *** [Makefile:1800: play-image] Bus error

on gates that never touch play.po themselves.  Measured on the box,
pre-fix: six rounds of two concurrent `make play-image`, six failures --
one Bus error, five `FileExistsError: '/mnt/MAUX/DEMO' already exists` (the
softer shape, two builders staging into one mounted volume).

The fix has two halves and needs both:

  * ATOMIC PUBLISH.  The build goes to a temp file in the same directory
    and is os.replace()d onto the final path, so a reader -- another
    builder, an emulator's mmap, shutil.copyfile in a derived image's
    builder -- only ever sees a COMPLETE image.  A reader that already
    had the file open keeps its own (now unlinked) inode and finishes on
    consistent bytes instead of faulting.  This is the half that stops
    the Bus error.
  * EXCLUSIVE LOCK on <image>.lock, held across the whole build.  Atomic
    publish alone would let N builders do N full builds of identical
    bytes and race to rename; the lock makes them queue, so the work is
    done once per waiting lane instead of N times at once.

Use it from an image builder that more than one sweep lane can reach:

    with imglock.publish(OUT_IMG) as out:
        ... build into `out`, never into OUT_IMG ...

`scripts/sweep_par.sh` names which images qualify and how to find the
next one.
"""
import contextlib
import fcntl
import os


@contextlib.contextmanager
def publish(out_img):
    """Hold <out_img>.lock, yield a temp path to build into, and rename
    that temp onto out_img when the block exits cleanly.  A failed build
    leaves the previous image in place, untouched."""
    directory = os.path.dirname(os.path.abspath(out_img))
    os.makedirs(directory, exist_ok=True)
    tmp = f'{out_img}.tmp.{os.getpid()}'
    # 'a+' so the lock file is created if absent and never truncated:
    # flock lives on the open file description, the file's CONTENT is
    # irrelevant, and truncating it under another waiter is pointless.
    with open(f'{out_img}.lock', 'a+') as lockf:
        fcntl.flock(lockf.fileno(), fcntl.LOCK_EX)
        try:
            if os.path.exists(tmp):
                os.remove(tmp)          # a killed predecessor's leftover
            yield tmp
            os.replace(tmp, out_img)    # atomic within the directory
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)
