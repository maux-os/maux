# External dependency lock

Status: LIVE, 2026-09-18; two tiers since 2026-10-19 (DEPS-TIER). The
machine-readable lock is `dependencies.lock.json` (schema 4);
`make bootstrap-deps` provisions it and `make check-deps` independently
enforces it.

## The two tiers

| tier | what it is for | what it fetches | what it needs from the operator |
|---|---|---|---|
| **build** | making the disks: `make image play-image full-image` (the 4 MiB play disk and the 32 MB release disk) | PLASMA (public GitHub, builds `xplasm`); a2til 0.9.0 from PyPI into a project-local venv, `pip --require-hashes`; mandoc 1.14.6 source (hash-checked); the tracked `pinned/` objects are in the clone | Python >= 3.10 (pip not required), Git, Make, a C compiler, `merlin32` v1.1.10, ACME 0.97. **No ROMs, no verilogapple, no Verilator, no SDL2, no Forgejo.** |
| **test** | everything the build tier does, plus the emulator gates (`check-*`), `make play`, and `make release` | the build tier's PLASMA and mandoc; a2til and verilogapple from the Forgejo (LAN-only) at their locked commits; builds verilogapple's fast and RTL workers and the SDL2 frontend | the build tier's tools plus Verilator 5.048, SDL2 2.32.72, nlohmann/json 3.12.0, a C++ compiler, and the operator ROM set below (`ROM_DIR`) |

```sh
make bootstrap-deps TIER=build                 # no ROM_DIR, no credentials
make bootstrap-deps ROM_DIR=/path/to/roms      # TIER=test, the default
```

`TIER=test` is the default and generates the same `dependencies.mk`,
`activate` and `provisioned.json` it did before tiers existed. A
build-tier tree records `MAUX_TIER = build` in `dependencies.mk` and
`"tier": "build"` in `provisioned.json`; a test-tier tree records nothing,
and an unrecorded tier is test. `make check-deps` audits the tier the tree
was bootstrapped as. `make check-deps TIER=test` on a build-tier tree fails
and names the tier; so does any emulator gate (its `mcp_supervisor`
prerequisite stops with "this tree was bootstrapped with TIER=build").

**Why the build tier needs no emulator.** Two kinds of file in the build
are made by running real code inside the emulator: the `as` core
objects (real Merlin-8 rebuilding the patched core) and the
`/usr/lib/LIBA` REL objects (`nas` assembling liba). They are committed
under `pinned/` and recorded by length and sha256 in the lock; the build
tier copies them (verified), and the test tier regenerates them as before.
Two gates in the sweep keep the pins honest: `make check-ascore-warm`
(compares the regenerated as-core objects with `pinned/`) and
`make check-liba-pins` (boots nas fresh, never the cache, and requires every
LIBA object to equal its pin); each fails with the exact re-pin command.
Which files are pinned, and their lengths and hashes, are in the lock's
`pinned` block and nowhere else.
See [pinned/README.md](../pinned/README.md). `make -n -B play-image` does
NOT show this dependency -- it names `check_ascore.py`, which imports the
emulator driver -- so the claim "the build needs no emulator" was measured by
building with verilogapple unreachable, not by reading `make -n`.

`make release` stays in the TEST tier: `check-release-image` boots the
packaged disk in MAME and rebuilds liba with nas fresh to prove determinism.

maux is not reproduced by its Git commit alone. Its image builders and gates
consume three sibling source trees plus two host assemblers and private Apple
II ROM dumps. Before this lock, all three sibling trees could move without a
maux commit changing, and the emulator binary could be older than the source
checkout beside it.

## Locked inputs

| input | locked revision/version | fallback location |
|---|---|---|
| a2til, test tier (Forgejo) | `8771012b5f6201d08329d5ead0dc75e95fb7692d` | `~/src/a2til` |
| a2til, build tier (PyPI, hash-pinned) | 0.9.0: wheel `f88bebae...c723`, sdist `f3ffd045...2a8b`; source commit `3a9e88e` (GitHub) | none: a project-local venv |
| PLASMA fork | `1b4d711ad07a75cd615b020a23affc8f30d9ea80` | `~/src/PLASMA` |
| verilogapple | `296d93a5d596e8a093457eae15bd5a5b2b1f1219` | `~/src/verilogapple` |
| merlin32 | v1.1.10 | `PATH` |
| ACME | 0.97 | `PATH` |
| SDL2 | 2.32.72 | `sdl2-config` on `PATH` |
| Verilator | 5.048 | `PATH` |
| nlohmann/json | 3.12.0 | compiler include path |
| Python | >= 3.10 | `PATH` |
| mandoc | 1.14.6 source archive + render probe | provisioned tree or `MANDOC` |
| ffmpeg (OPTIONAL, test tier, `make demos` only) | floor 9.0; encoders `libx264`, `libvpx-vp9`; filters `scale`, `split`, `format` | `PATH` |

**ffmpeg is the one optional tool.** Only `make demos` (the demo screencasts,
docs/RECORDER-NOTES.md) encodes video: no sweep does, the Linux box has none,
and the build tier never needs it. It is in the lock as `tools.ffmpeg` and in
the test tier as `optional_tools`. `make check-deps` treats it as optional
the way no other tool is: ABSENT is fine; PRESENT must meet the lock's floor,
encoders and filters, so a host with an old or half-built ffmpeg is named by
`check-deps` (which the box does not run) before a recording fails minutes in.
`scripts/ffmpeg_probe.py` reads the lock block for both `check-deps` and
`scripts/demo_record.py`, so the numbers live in one place; `make demos` runs
`demo_record.py --check-ffmpeg` BEFORE it builds anything and stops, naming
what is missing. `make check-deps-selftest` plants four faults in the block
(a tier listing an optional tool the lock has no block for, an ffmpeg with no
encoders, a floor that is not `[major, minor]`, ffmpeg listed in the build
tier) and requires each red. Install on the Mac: `brew install ffmpeg`
(Homebrew's build has no `drawtext`; the recorder does not use it, it draws
its overlays itself).

Override the repository locations with `A2TIL`, `PLASMA`, and
`VERILOGAPPLE` (in the build tier `A2TIL` is the venv's `site-packages`). The Makefile exports all three to the build, the Python harness
honours `A2TIL`, and the emulator harness derives `MAUX_SUPERVISOR`,
`VERILOGAPPLE_ROMS`, and `FAST_SDL` from the selected verilogapple tree.

## When a liba or nas change lands

A change to `src/liba`, to `nas` (anything under `src/asm`), to the REL
composer, or to `src/merlin/patches.py` can change a pinned object, and the
sweep will say so: `make check-liba-pins` or `make check-ascore-warm` goes
red naming the file. That is the drift gate working, not a defect. The
workflow, in the test tier:

1. Merge or commit the change. (If it adds a liba module, the new object
   appears as "made by nas but has no pin".)
2. `make repin-liba` (and `make repin-ascore` if the as core moved). Both
   build what they pin first, so a stale `build/` cannot pin objects from an
   old nas. They rewrite `pinned/` and the lock's `pinned` block.
3. Read the diff of `pinned/` and the lock, and commit both with the change.
4. `make check-liba-pins check-ascore-warm check-deps-selftest` green.
5. Redo the build-tier clean-clone compare: `full.po`'s hash has moved, so
   bootstrap `TIER=build` into a scratch clone and compare `build/maux.po`,
   `build/play.po` and `build/full.po` with the test-tier build of the same
   commit (commands: docs/DEPS-TIER-NOTES.md, "The clean-clone proofs").

## The a2til pins

a2til is pinned three ways, and `check-deps` holds them to one content.

* **PyPI (build tier).** `a2til==0.9.0`, installed with `pip --require-hashes
  --only-binary :all:` from a requirements file the bootstrap writes: a
  version alone is not a pin, the hash is. The lock carries the wheel's and
  the sdist's sha256 (read from `https://pypi.org/pypi/a2til/0.9.0/json`)
  and records the GitHub commit they were built from. A hash mismatch is
  final; it never falls back. `check-deps` then verifies the INSTALLED files
  (`installed_manifest_sha256`), so a venv edited after install is red.
* **GitHub (fallback, and the public source).**
  `https://github.com/emdeejay/a2til.git` at `3a9e88e`: if PyPI cannot be
  reached, the bootstrap fetches that commit and copies its `a2til/`
  package into the venv. (`pip install git+URL@3a9e88e` builds the same
  installed files, but it builds with hatchling fetched unpinned from the
  index that just failed, so it is not the fallback.)
* **Forgejo (test tier).** `8771012`, a git checkout, as before.

The GitHub repository is a flat mirror pushed by a2til's
`tools/publish-mirror.sh`: ONE snapshot commit per push with no shared
history, minus a declared exclusion list (`.forgejo/` and three notes). Its
hash can never equal the Forgejo hash, and its git TREE differs from the
Forgejo tree by exactly the excluded files, so the two pins are compared by
a **content manifest**: the sha256 of `mode blob-id path` for every file the
mirror carries (blob ids are content hashes). The lock records the manifest
beside each pin. **If the Forgejo pin moves, someone must run
publish-mirror.sh and re-pin the GitHub hash and the PyPI source commit:**
`make check-deps` fails ("name different trees") when the two manifests
differ, when the Forgejo checkout's content is not the recorded manifest,
or when the PyPI source commit is not the GitHub pin; `make
check-deps-selftest` plants each fault and requires red. A maintainer
re-pinning runs `make verify-mirror` (the bare script finds the provisioned
tree's paths from `.deps/provisioned.json` too, so no sourced
`.deps/activate` is needed),
which fetches the GitHub commit and holds it to the manifest (it needs the
network, so it is not part of the sweep).

## Non-destructive bootstrap

Install the locked host tools for your tier (the table above), plus Git, Make, and a C compiler (C++ for the test tier). The build tier needs no pip and no `python3-venv` package: if the host's Python cannot make a venv with pip (stock Debian), a2til is installed from the locked wheel after its length and sha256 are checked.
The bootstrap downloads the official mandoc 1.14.6 source archive, verifies
its locked SHA-256, and builds it inside the dependency tree. mandoc.bsd.lv
is the only origin, so the download has a 30 s timeout per socket operation
and up to 4 attempts with 2/4/8 s backoff (a wrong-hash transfer is asked for
again too); when they are used up the error names the URL, the lock's sha256
and what each attempt saw (`make check-deps-selftest` exercises this against
a local server). Host package
installation is deliberately not
automated: using a privileged package manager would be wider and less
reversible than provisioning project-local inputs. The exact Debian host seed
used for the independent reproduction is recorded in
`docs/HOST-PROVISIONING.md`.

Obtain the ROM files in the next section, arrange them under one directory,
and run from a clean maux checkout:

```sh
make bootstrap-deps ROM_DIR=/path/to/roms
make check-deps
make vendor-prodos vendor-merlin
make play-image
```

The steps below are the test tier's; the build tier skips 2, clones only
PLASMA, installs a2til into its venv, never touches the network except
GitHub, PyPI and the mandoc/ProDOS/Merlin downloads, and skips verilogapple,
the ROM staging and the emulator checks.

The bootstrap performs these steps:

1. checks all locked host tool versions before writing anything;
2. validates every operator ROM by size and SHA-256 before network access;
3. creates the new destination, clones each locked URL into it, and checks out
   the exact commit in detached-HEAD state;
4. builds the locked mandoc source and checks its rendered probe byte-for-byte;
5. builds PLASMA's `xplasm`, verilogapple's supervisor plus fast/RTL worker,
   and its SDL2 frontend at that permanent path;
6. runs the normal `check-deps` gate against the result; and
7. writes `dependencies.mk` only after the complete audit passes.

Building at the final path is deliberate: Verilator records absolute include
paths in generated depfiles. A failed bootstrap removes only the destination
that the current invocation created; it never modifies a pre-existing path.
The locked verilogapple revision also tracks `sim/mcp/.build-rev` even though
its Makefile regenerates that stamp. The bootstrap marks only that lock-declared
path assume-unchanged so a rebuild does not label itself dirty; `check-deps`
rejects any other assume-unchanged or skip-worktree entry.

The destination must not exist. The script never fetches into, checks out, or
resets an existing tree. To keep several provisioned sets, use (for example)
`make bootstrap-deps DEPS_ROOT=/tmp/maux-deps ROM_DIR=/path/to/roms`, then pass
the same `DEPS_ROOT` to later Make invocations. `.deps/` is ignored by Git.

`make vendor-prodos vendor-merlin` separately downloads the public ProDOS 2.5
and 2.4 disks and the public-domain Merlin validation disk to the ignored
`vendor/` directory. All three inputs have locked lengths and SHA-256
identities. A pre-existing mismatched cache is refused, not replaced, and
Merlin extraction is published atomically or compared byte-for-byte with an
existing extraction. These artifacts are not operator-supplied ROMs.

The old `vendor/prodos-basic.po` was an unproven file copied from an operator's
Downloads directory. It is no longer an input. `vendor-prodos` deterministically
constructs its replacement from ProDOS 2.5's locked `Boot.blocks`, `PRODOS`, and
`BASIC.SYSTEM` files and verifies the generated image's locked SHA-256 before
publishing it. A legacy carrier is refused rather than overwritten; move it
aside explicitly once if upgrading an existing development tree.

## Operator-supplied ROMs

Apple and third-party firmware is not redistributed. The bootstrap requires
this exact directory shape and rejects a different dump rather than silently
building a different test machine. A test-tier `make bootstrap-deps` given a
`ROM_DIR` that lacks any one of these eleven files refuses before it touches
the network, naming the missing file; the build tier takes none of them.

| relative path under `ROM_DIR` | bytes | SHA-256 | fed to |
|---|---:|---|---|
| `iie_cd_ef.rom` | 16384 | `aab38a03ca8deabbb2f868733148c2efd6f655a59cd9c5d058ef3e0b7aa86a1a` | every emulator gate; `make play`; MAME romset |
| `iie_video.rom` | 4096 | `52c3b87900ac939f6525402cab1ccfd8f8259290fc6df54da48fb4c98ae3ed0f` | every emulator gate; `make play`; MAME romset |
| `applemouse.rom` | 2048 | `7f8e50c0e8a409991264201f9300f109b872b68e09c43f3e6c26af35fd8b89af` | every emulator gate (the 60 Hz VBL tick); MAME romset |
| `ultraterm/firmware_v3.bin` | 4096 | `cb17d747d3370723df02504f94bcf72aae9ef6d7419dc1e2edeb2cccfedf4024` | the UltraTerm gates (`check-ultraterm`, `check-ut-bold`, `check-play80`, `check-vi-alt`, the e2e_term ones); `make play`; MAME romset |
| `ultraterm/chargen_v3.bin` | 4096 | `cbbfd3d07be729795d2b5a2bcdb1f1daf01af945f2f80430a5666bb7f0fedcd0` | the same; the `make play` mousetext graft; MAME romset |
| `disk2.rom` | 256 | `de1e3e035878bab43d0af8fe38f5839c527e9548647036598ee6fe7ec74d2a7d` | every gate that mounts a floppy: `check-floppy`, `check-devfs`, `check-unpack`, `check-mount`, `check-devpath`, `check-loop`, `check-dirtyram` |
| `ssc.rom` | 2048 | `4fa1323ba31f4bd562486838397b7744257c126806766e360876720daca6e2aa` | the serial-card gates: `check-ser`, `check-tip`, `check-tip-vim`, `check-vt102` (its serial leg); `scripts/tip_live.sh` |
| `ultraterm/chargen_v1.bin` | 4096 | `d9c3108abb2a21a3807deb992af62c963891f18938f1da945e536f82e4676651` | `make play` and `make play-rec` (their `--ut` is the HQ mode, which pairs v3 firmware with v1's tall chargen); `check-mame` and `check-release-image`, through `make vendor-mame-roms` (the `a2ulttrm` romset's `chs_7859`); the UltraTerm demo films draw the original card with it |
| `ultraterm/pal_u4_v3.jed` | 773 | `e7b25b6be6c220317d4d81a0f538784cc72024821f402d6edaf80b81d9012082` | `check-mame` and `check-release-image`, through `make vendor-mame-roms` (the `a2ultrme` romset's `ult_251c.jed`) |
| `ultraterm/firmware_v1.bin` | 4096 | `8c9888dbc0c5dc8d51493e3f192a09415216ccb96d99e9d94ea29c58dec643e0` | `check-mame` and `check-release-image`, through `make vendor-mame-roms` (the ORIGINAL card's `a2ulttrm` romset, `frm_b537`); the UltraTerm demo films (`check-demos`, `check-recorder`, `make demos`), which boot the original card |
| `ultraterm/pal_u4_v1.jed` | 773 | `9e4e93f9634a058e4cb8dd4ce06aa7987d4ca93eb43d9f47069b95ce36775f85` | `check-mame` and `check-release-image`, through `make vendor-mame-roms` (the `a2ulttrm` romset's `ult_2a313.jed`) |

The system ROM is the combined 16K `$C000-$FFFF` enhanced Apple IIe image;
the video image is the 4K alternate-character-set version used by the locked
test configuration. The rest are the peripherals: the AppleMouse VBL source,
the UltraTerm v3 terminal (and the original v1 card's firmware, chargen and PAL, for `make play` and MAME), the Disk II
boot PROM, the Super Serial Card, and the UltraTerm PAL fuse map MAME wants.
Operators must dump or otherwise obtain these files lawfully. maux supplies
neither download URLs nor copyrighted bytes; the hashes above are not bytes.

**Why this table is the whole list (KFIX12, 2026-10-20).** It used to hold
five files, and a clean clone failed seven floppy gates because verilogapple
loads `disk2.rom` from a path of its own (the peripheral loaders in
`sim/core/loaders.h` never consult `VERILOGAPPLE_ROMS`,
`learning:01M1QYXWW0WXMCY6E20V2BTTZK`) and nobody had written it down. The
list is now held to the emulator's source: `make check-deps` scans every
non-testbench C++ file under verilogapple's `sim/core`, `sim/fast`,
`sim/mcp` and `sim/top`, plus the ROM names maux's own `vendor_mame_roms.py`
asks for, and goes red for any ROM-shaped file name the lock neither
declares in `roms` nor exempts in `roms_exempt`. An exemption carries its
reason and the strings that would select the file; the audit also goes red
when a maux Makefile or script contains one of those strings, or when
nothing reads the exempted file any more. The one exemption, and why (the original UltraTerm's firmware and PAL moved into `roms` with UT-CELL, which boots that card in MAME):

* `~/Downloads/timemaster_ii_ho_rom_v5.bin` -- the authentic AE
  Timemaster ROM, read only from that absolute path or
  `VERILOGAPPLE_TIMEMASTER_AE_ROM`. The clock the gates use is the
  built-in timemaster firmware assembled in-tree (a build product, as is
  the SmartPort firmware), not a dump.


`make check-mame` and `make check-release-image` also need
`vendor/mameroms`. They no longer need a hand step: both depend on
`vendor/mameroms/votrsc01a.zip`, which `make` builds by running
`scripts/vendor_mame_roms.py` from the provisioned verilogapple ROM tree
(hence the jed above) plus four hash-pinned downloads cached in `vendor/`.
It is a Make dependency rather than a bootstrap step because `vendor/` is
the working tree's cache (like `vendor-prodos`), not `DEPS_ROOT`, and
because a build-tier tree has no ROM tree to build it from.
`check-release-image` also checks, before it builds anything (the two image
builds take ~140 s), that `mame` is on `PATH` and the four romsets exist,
and stops in a fraction of a second naming what is missing.

## What the check proves

`scripts/check_dependencies.py` verifies:

- each sibling checkout is at the locked commit and has no tracked source
  modifications (verilogapple's lock-declared generated MCP revision stamp is
  excluded, and no undeclared index-hiding flags are allowed);
- the required tool versions are the locked versions;
- the required ROM files have the locked byte lengths and SHA-256 identities;
- the lock's `roms` table (plus its declared exemptions) covers every ROM
  file name verilogapple's loaders and maux's MAME builder read;
- xplasm and the tracked Apple PLASMA zero-page include exist;
- the SDL2 interactive frontend used by `make play` is executable;
- the running MCP supervisor and its worker both identify themselves as built
  from the locked verilogapple revision.

The last check closed a real hole on the day the lock was added: the checkout
was at `2bd7574`, while both binaries used by every emulator gate reported
`e60be40-dirty`. Presence of `mcp_supervisor` had been treated as fitness, so
the Makefile never rebuilt it.

The pin moved from `2bd7574` to `296d93a` on 2026-10-07 (it should have
moved on 2026-09-28, when `check-floppy` started needing spec-12's sector-image
mounts and the box was rebuilt from that revision; `check-deps` was red on the
Mac for nine days and nobody ran it, because the box set excludes it). The same
day the binary-revision check learned one exception: verilogapple tracks
`sim/mcp/.build-rev` and its build rewrites it, so after the first build the
tree is permanently dirty by that one file and every binary self-reports
`<rev>-dirty`. The check accepts the suffix only when its own dirty check --
which already excludes the lock's `generated_tracked` paths -- found the
checkout clean; a real source edit still fails. The honest fix is upstream:
stop tracking the generated file.

At the locked revision, terminating a freshly queried worker also emits a
libc++ `mutex lock failed` exception during teardown. The revision result has
already been returned and `check-deps` still passes, but the message is not
suppressed: it is a real verilogapple cleanup defect, not evidence of a clean
emulator shutdown.

## Limits

The project-local source bootstrap is reproducible, but the host compiler and
package-manager layer remains part of the trusted seed. On 2026-09-18 a clean
checkout at `a04c49f` was bootstrapped on Debian 12 x86_64 from the lock, using
fresh detached Git checkouts rather than rsynced source. `check-deps`, two
immediate MCP rebuilds with a repeat audit, both `vendor-*` targets,
`play-image`, the SDL frontend launch path, and fast plus RTL `check-boot` all
passed; the source checkout remained clean. This is an independent host proof,
not a claim that the operating-system packages are themselves hermetic.

The two Forgejo repository URLs are access-controlled. The second-host run used
shallow, exact-commit mirrors transferred privately and per-process Git URL
rewrites; neither credentials nor private source are release artifacts. An
operator without access to those repositories cannot recreate the emulator
integration checkout from the public maux tree alone.

ProDOS/vendor downloads carry their own hashes in the vendor scripts. ROM
provenance remains the operator's responsibility.

The PLASMA build previously relied on an untracked
`src/vmsrc/plvmzp.inc`. It is byte-identical to the tracked
`src/vmsrc/apple/plvmzp.inc`; maux now stages that tracked file into its build
scratch directories explicitly. The unrelated untracked `src/maux/hello.*`
experiment in the local PLASMA checkout is not a build input.
