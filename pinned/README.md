# pinned/ -- emulator-made build inputs, committed

Two kinds of file in the build are made by running real code inside the
emulator. A host without verilogapple and the operator ROM set cannot make
them, so they are committed here, and `dependencies.lock.json` ("pinned")
records the length and sha256 of every one. **That block is the only place
the file list, the lengths and the hashes are written down**; this page
says what the files are and how to regenerate them, not how big they are.
The **build tier** (`make bootstrap-deps TIER=build`, docs/DEPENDENCIES.md)
copies these; the **test tier** regenerates them through the emulator,
exactly as before, and two gates in the sweep fail when a regeneration
differs from what is here.

Nothing here is a hand edit. Every file is the byte-for-byte output of the
command in its row; `make check-deps` checks the lock's hashes in both
tiers, and a build refuses a pin that does not match the lock.

## The `as` core: `ascore-warm-as.obj`, `ascore-warm-bank1.obj`

What they are: the Merlin-8 2.59 assembler core (public domain, with
source, `learning:01M044DYE1X50A34ZKG3FRRRQA`) as `as.bin` embeds it: the
source from the vendored Merlin validation disk, patched by
`src/merlin/patches.py` (the `warm` variant), rebuilt BY real Merlin-8 in
the emulator, and the two object pieces extracted. `src/bin/as.s` puts them
in with `putbin`.

Test tier regenerates: `make check-ascore-warm` (writes
`build/ascore-warm-as.obj` and `build/ascore-warm-bank1.obj`, then
`scripts/pinned.py compare` requires them equal to these).

## The LIBA objects: `liba/*.rel`

What they are: the REL objects of `/usr/lib/LIBA` on the release disk
(`build/full.po`), each assembled from `src/liba` by `nas` running inside
maux in the emulator (`scripts/build_full_image.py`, the one emulator step
of `make full-image`). ProDOS type `$F8`, auxtype per object (in the lock).
The file name is the ProDOS name plus `.rel`: `ARGVR.rel` is
`/usr/lib/LIBA/ARGVR`.

Test tier regenerates: `make check-liba-pins` boots nas fresh (it bypasses
`build/full-liba`, so a stale cache cannot vouch for a stale pin) and
requires every object to equal its pin.

## When a gate says "re-pin"

A regeneration that differs means the source or the toolchain changed on
purpose (or something is broken: read the diff first). To accept it, in the
test tier:

    make repin-ascore     # the as core; rebuilds it first, then pins it
    make repin-liba       # the LIBA set; rebuilds play and full image and
                          # boots nas fresh, then pins every object

Both build what they need before they pin, so a stale `build/` cannot pin
objects from an old nas. Then commit `pinned/` and `dependencies.lock.json`
together, rerun `make check-ascore-warm check-liba-pins check-deps-selftest`,
and (the full-disk hash moved) redo the build-tier clean-clone compare
(docs/DEPENDENCIES.md, "When a liba or nas change lands").

## What is deliberately not here

`as-stubs.bin` (merlin32 makes it from tracked source), `ascore-process-*`
(only `mld`, outside the play and release disks, embeds them) and anything
the host can build. A file belongs in pinned/ only if the emulator is the
sole thing that can make it.
