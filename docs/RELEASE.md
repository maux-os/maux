# Building a release bundle

Status: tooling implemented; current candidate qualification is pending.
See [verification](VERIFICATION.md) for the recorded sweep failures and the
difference between native rebuild evidence and a complete release green.

## Dependency tiers

The play and release DISKS (`make play-image full-image`) are built by the
**build tier** (docs/DEPENDENCIES.md): no ROMs, no verilogapple, no
credentials. QUALIFYING and PACKAGING a release is the **test tier**:
`make check-all` and the emulator gates, `make check-release-image` (which
boots the packaged disk in MAME and rebuilds liba with nas fresh), and
`make release` (which runs that gate first). A build-tier tree refuses
`make release` and every emulator gate by naming its tier. The build tier's
two emulator-made inputs, `pinned/ascore-warm-*.obj` and `pinned/liba/*.rel`,
ship in the source tarball and are hash-locked in the bundled
`dependencies.lock.json`; the sweep's `check-ascore-warm` and
`check-liba-pins` rows are what prove they equal a fresh emulator build, so a
release's gate evidence includes them.

## Candidate checklist

Before tagging, use one clean candidate commit for all of these:

- Confirm dependency identities with `make check-deps` (the test tier) and
  `make verify-mirror` (needs the network:
  it fetches the GitHub a2til pin and holds it to the lock's content
  manifest, which no sweep gate can) and `make verify-remote` (needs the
  network: every commit the lock pins, and the PyPI files, must be fetchable
  from the lock's URL with no local checkout; RC-1 F1 was a pin that existed
  only on the dev host; `make release` and `make release-candidate` run it
  first, before anything builds), and
  reproduce the build tier on a clean clone: `make bootstrap-deps TIER=build`,
  `make check-deps`, `make vendor-prodos vendor-merlin`, `make image
  play-image full-image`, then compare `build/play.po`, `build/maux.po` and
  `build/full.po` byte for byte with the qualified tree's (the exact commands
  and the 2026-10-19 proof are in docs/DEPS-TIER-NOTES.md).
- Run `make check-all` and retain the outer exit status/summary and each
  target's log in a candidate-specific location.
- Run `make check-nas-selfmake`; retain the composer plan, installed NAS
  hash, utility/kernel byte comparisons and empty dry-rerun result. For the
  promoted native code, also retain `make check-nas-native` results; its
  optional py65 prerequisite is separate from the ordinary build lock.
- Reproduce the clean-checkout build on a second host from the pinned inputs,
  recording the declared host layer and any access-controlled dependency
  mirrors. The earlier `a04c49f` proof is not proof for a later candidate.
- Confirm README, support matrix and known limitations describe that revision.
  An emulator-qualified release must not imply physical-hardware qualification.
- Run `make check-release-image`. This checks image determinism, not a fresh
  rebuild of every cached tool or input.

Fixes after these runs create a new candidate: rerun affected checks and
obtain the final complete gate evidence before claiming the tagged release.
Do not delete unrelated work to satisfy the clean-tree requirement; prepare
a separate clean candidate checkout when needed.

## Package a release CANDIDATE

`make release` refuses an untagged HEAD, and that refusal stays. To package
the exact tree under qualification before any tag exists:

```sh
make release-candidate VERSION=X.Y.Z
```

It needs a clean tree and no tag, runs the same prerequisites as `make
release` (`verify-remote`, then `check-release-image`) and the same packager
code path, and writes `dist/maux-X.Y.Z-rc-<shortsha>/` -- the directory, the
image and the source archive all carry the `-rc-<12-hex-digit commit>` name --
with `MANIFEST.json` saying `"candidate": true, "tag": null`. The packager
never promotes a candidate: the release path refuses a VERSION ending in
`-rc-<hex>`, and `python3 scripts/build_release.py --verify BUNDLE` fails a
bundle whose directory name, manifest and member names disagree (a candidate
renamed to the release name) or whose files do not match `SHA256SUMS`.
`make check-release-pack` holds all of this offline, in a scratch repository.
A release is made by tagging and running `make release` again.

## Package the qualified revision

A release is built only from a clean commit carrying the exact `vVERSION` tag.
After the canonical and native gates pass at that commit:

```sh
git tag -a vX.Y.Z -m "maux X.Y.Z"
make release VERSION=X.Y.Z
```

The target refuses a dirty tree, a missing/mismatched tag, an existing output
directory, or a boot image whose size or ProDOS volume-header block count
does not match the release-disk builder (`build/full.po`, 32 MB, 65,535 blocks:
`FULL_BLOCKS` in `scripts/build_play_image.py`). The bootable image in the
bundle is that disk, with every program, the native toolchain, the
headers, liba, maux's source and the examples on it (docs/FULLDISK.md).
This is a block-device image, not a single 800K floppy image. It writes
`dist/maux-X.Y.Z/` containing:

- the bootable ProDOS image and a `git archive` source tarball from the same
  commit. **The shipped file is one block longer than its volume**: 65,536
  blocks (33,554,432 B), the ProDOS volume header still saying 65,535, one
  zero block appended. MAME's AppleIISd is an SD-card model and refuses a
  65,535-block file (`SD Card image size 65535 blocks of 512 bytes is not
  supported by SD or SDHC`); the padded file boots there. It is also the
  shape the GEM CD ships its 32 MB volumes in. `build/full.po`, which every
  gate and a2til reads, stays 65,535 blocks; only `make release` pads, and
  `validate_release_file` accepts exactly that shape (header 65,535, one
  trailing block, all zero) and nothing looser. a2til refuses the shipped
  file until it is truncated by one block (`head -c 33553920`). **What is
  proven about the padded file: it boots in MAME 0.286's AppleIISd and
  completes a `bye` round trip there (`check-release-image`). It has not
  been run on verilogapple, on AppleWin, or on any physical controller;**

- `dependencies.lock.json`, `MANIFEST.json`, and `SHA256SUMS`;
- the current support matrix and known-limitations summary.

The source archive is `git archive HEAD` **minus every path
`scripts/check_publish.py --list` names** -- the same oracle and the same
subtraction `make public-tree` performs. A bundle is published, so its
source is the PUBLIC tree or it is a leak: measured 2026-11-02, before the
packager did this, the 1.0 tarball carried 1044 of the 1045 not-ship paths
-- the project's internal notes and the withheld gate drivers among them. The packager refuses to build at all if
`check-publish` is red, because subtracting a stale pin list is how a
withheld file reaches a release; `check-release-pack` rows 8-10 hold the
subtraction, that refusal, and the archive's byte-for-byte determinism.
The bundle also deliberately excludes `.deps/`, vendored media, build
directories, and all ROM bytes. A recipient must supply the ROMs documented in
`docs/DEPENDENCIES.md` to run the emulator gates or `make play`.

`check-release-image`, which the release target runs first, constructs the
release disk (and so play.po, which it is built from) twice under deliberately different host time zones and requires the
bytes to match. Build-time ProDOS metadata is normalised to 2000-01-01 00:00;
files created later by the running system still use its live clock.
The same gate checks the packager rejects an old 800K image, truncation and
a mismatched volume-header block count, and the old 4 MiB play image. The
65,535-block enlargement keeps the existing carrier boot blocks; street-library `learning:01KZZ55AZ98V8P0FQASXWQ6K7T`
records the SmartPort block-zero boot contract. Capacity changes do not
require a new boot-entry protocol.

The release operator records the `make check-all` and
`make check-nas-selfmake` results for the tagged commit. A bundle alone is not
evidence that those gates ran.

## Evidence accompanying the bundle

The current packager does not run the canonical/native suites, validate their
logs, or include them automatically. MANIFEST.json identifies the revision
and payload, not test approval. Keep a release evidence record alongside the
bundle identifying the commit/tag, host and emulator versions, dependency-lock
and image hashes, exact gate commands and exit statuses, second-host result,
and every exception or unsupported configuration. Link or archive the logs
from that record; do not rely on temporary paths on the development machine.

Keep the generated bundle immutable after hashing. A documentation repair
does not close a failing gate, and a passing image comparison does not erase
a named emulator shutdown diagnostic.

## Publishing the site

The website (docs/SITE.md) is published as a GitHub Pages tree from the
`main` branch of `maux-os/maux-os.github.io`, at
https://maux-os.github.io/. A repository named `<org>.github.io` is an
ORG page and is served from the root; that is a second repository, and
the source stays in `maux-os/maux`, which every `repo:` link points
into. `maux-os/maux`'s own `gh-pages` keeps a redirect to the root, so
the /maux/ links in the 1.0 release notes still land.
The release disk is served from that tree as `maux-X.Y.Z.po`, because Pages
sends `Access-Control-Allow-Origin: *` and the "Boot maux in Apple2TS" button
on /get/ makes Apple2TS fetch the image from another origin. Nothing below
runs from `make release`; a person with push rights does the last step.

1. Have the bundle: `dist/maux-X.Y.Z/` from `make release VERSION=X.Y.Z`.
2. On the `full.po` that release was cut from, run `make check-examples
   demos`. The lesson sessions record that image's sha256 and the films must
   exist for every demo in `site/demos/`.
3. Look first: `make site-preview`, then `make site-preview-serve`, and open
   http://127.0.0.1:8010/get/ (set `PREVIEW_APPLE2TS=http://127.0.0.1:5317/`
   to use a local Apple2TS checkout). Press the button, wait about 20 s for
   boot, type `ps` a key at a time (about 200 ms apart) and expect the process
   table.
4. `make site-pages VERSION=X.Y.Z` assembles `build/pages/`. It refuses on:
   no bundle; an image whose sha256 differs from its `SHA256SUMS` line; an
   image that is not 65,536 blocks with header 65,535 and a zero last block;
   a demo with no film; a lesson session run on any other disk (compared
   against the bundle image truncated by one block); and anything check-site
   finds. It then prints a size report and the publish commands. Limits
   (docs.github.com, "GitHub Pages limits" and "About large files on
   GitHub"): published site at most 1 GB, deploy timeout 10 minutes, soft
   100 GB/month bandwidth, a pushed file over 50 MiB warns and over 100 MiB
   is blocked. The 32 MiB image is under all of them; about 3000 image
   fetches a month reach the soft bandwidth figure.
5. Publish, from `build/pages/`, as one fresh commit so the 32 MiB image does
   not accumulate in history:

   ```sh
   cd build/pages
   git init -q -b main && git add -A . && git add -f .nojekyll
   git commit -q -m "maux X.Y.Z site"
   git push --force git@github.com:maux-os/maux-os.github.io.git main
   ```

   No settings click: an `<org>.github.io` repository enables Pages from
   `main` / root by itself.
6. Check: `curl -sI https://maux-os.github.io/maux-X.Y.Z.po` shows 200,
   `Content-Length: 33554432` and `Access-Control-Allow-Origin: *`; then press
   the button on the live /get/ page.
