# maux

maux is a Unix implementation with a native assembly-world rebuild for an
enhanced Apple //e with an Applied Engineering RamWorks-compatible
auxiliary-memory card. Its defining
architecture is one 64K auxiliary bank per process: zero page, hardware stack,
program, and process data all switch together through the RamWorks bank-select
register.

This is an implemented system, not an architecture proposal. It currently has
a preemptive kernel, `fork`/spawn, pipes, signals, job control, a ProDOS-backed
filesystem, 40- and 80-column terminal backends, virtual consoles, `sh`,
`ed`/`ex`/`vi`, a native PLASMA environment, a native `nas` assembler, and 85
staged utilities including `make` and `ld`.

## Self-hosting status

The native milestone is green: the staged graph contains 458 `nas` assembly
recipes and 118 `ld` links. Inside maux, `make` rebuilds all 85 utilities and
the complete kernel module closure byte-for-byte against the cross-built
reference. A second `make -n` has nothing to do.
See [docs/NAS.md](docs/NAS.md) for the build path and the measured timings.

That is a native self-rebuild, not yet a closed bootstrap from bare source
media. Host tools still prepare and split the source graph, cook the staged
`nas` executable, construct ProDOS images, drive the emulator, and compare the
results. The disk carries two assemblers. `as` is Glen Bredon's Merlin running as a
maux process: the full Merlin experience, and the one human programmers will
want. `nas` is maux's own, written in PLASMA in the same dialect: less capable,
but it takes larger source files, and it is the assembler the automated
self-build uses. `as` is not part of the release gate.

See [docs/PROJECT-STATE.md](docs/PROJECT-STATE.md) for the evidence, boundaries,
known risks, and current consolidation priorities.
The [documentation map](docs/README.md) separates live operating guides from
historical design reports. [NAS maintenance](docs/NAS.md) describes the mixed
PLASMA/assembly implementation and the host tools still needed to build NAS.
Exact sibling/tool revisions are recorded in
[dependencies.lock.json](dependencies.lock.json) and explained in
[docs/DEPENDENCIES.md](docs/DEPENDENCIES.md).

## Get it

maux builds in two dependency tiers (docs/DEPENDENCIES.md). Pick the one you
need; say nothing about the other and you get the first.

| tier | gets you | needs |
|---|---|---|
| **build** | `make play-image` (the 4 MiB play disk), `make full-image` (the 32 MB release disk with every program, the native toolchain, the headers, liba, maux's source and the examples) and `make check-all-host` (every gate that needs no emulator) | Python 3.10+ (no pip or `python3-venv` package needed), Git, Make, a C compiler, `merlin32` v1.1.10, ACME 0.97. Fetches only public things: PLASMA and a2til from GitHub/PyPI. **No ROMs, no emulator, no credentials.** |
| **test** | everything above, plus the emulator gates (`make check-all-cross-par`), `make play` (the live window) and `make release` | the build tier's tools, Verilator 5.048, SDL2 2.32.72, nlohmann/json 3.12.0, a C++ compiler, the exact legally obtained Apple II ROM set in docs/DEPENDENCIES.md, and the LAN-only verilogapple repository |

**To build the disk, use the build tier.** The test tier is for people who
run maux's test harnesses: it also needs the Apple II ROM dumps (which maux
does not distribute) and verilogapple, which is hosted on a LAN-only server.

```sh
git clone <this repository> maux && cd maux
make bootstrap-deps TIER=build
make check-deps
make vendor-prodos vendor-merlin
make image play-image full-image     # build/play.po, build/full.po
```

Nothing in that list needs the emulator because the few build inputs that
can only be made by running code inside it (the `as` core objects and the
`/usr/lib/LIBA` REL objects) are committed under [pinned/](pinned/README.md)
and hash-locked; the test tier regenerates them and two gates fail if they
differ. `make release` is a test-tier command: it boots the packaged disk in
MAME and rebuilds liba with nas to prove determinism.

The test tier is the same two steps with the ROMs:

```sh
make bootstrap-deps ROM_DIR=/path/to/roms     # TIER=test is the default
make check-deps
make vendor-prodos vendor-merlin
```

Arrange the ROM directory like verilogapple's `sim/roms/` (the required files
and hashes are in docs/DEPENDENCIES.md). Either bootstrap creates an isolated
`.deps/` tree from `dependencies.lock.json` and never updates or resets an
existing checkout. It also builds the lock's hash-verified mandoc 1.14.6
source for byte-reproducible manual pages. The generated
`.deps/dependencies.mk` makes later `make` invocations use that renderer and
those source trees (and records the tier). Set `DEPS_ROOT` to provision
somewhere else; the command refuses an existing destination, so choose a new
directory. Existing sibling checkouts under `~/src` are still the fallback when
`.deps/` is absent, and `A2TIL`, `VERILOGAPPLE`, and `PLASMA` remain explicit
overrides.

```sh
make full-image          # build build/full.po, the release disk
make play                # launch the interactive verilogapple SDL system on it (test tier)
make play-image          # build build/play.po, the smaller base image the gates boot
```

The release disk (`build/full.po`) is one 32 MB ProDOS block-device volume,
65,535 blocks, ProDOS's ceiling. It carries everything: every program the
tree builds, the native toolchain (`nas`, `ld`, `plasm`), the headers a
program links against (`/usr/inc`), liba as a library (`/usr/lib/LIBA`),
maux's own source with the `MAKEFILE` that rebuilds it (`/usr/src/maux`),
the worked examples (`/usr/src/examples`) and the manual. `make play`
boots it, and `make release` ships it. It is not a floppy image. The 4 MiB
`build/play.po` remains the base the gate suite boots, and `full.po` is
built from it.

In the test tier `make full-image` boots the emulator once to assemble liba
with `nas` (cached under `build/full-liba`); in the build tier it reads the
same objects from `pinned/liba`, and `make check-liba-pins` proves a fresh
nas run produces them byte for byte.

`make play` requires verilogapple's `fast_sdl` frontend. Override `FAST_SDL`,
`VERILOGAPPLE`, or `PLASMA` when the sibling repositories live elsewhere.

## Verification

Useful entry points are:

```sh
make check-all-host           # BUILD TIER: every gate that needs no emulator
make check-all-cross-par J=4  # ordinary parallel cross-toolchain sweep
make check-all                # canonical local sweep, including native paths
make check-deps               # locked source/tool and emulator-binary audit
make check-release-image      # build play.po twice and require identical bytes
make check-posix              # POSIX differential/report suites
make check-nas-selfmake       # full native world rebuild; intentionally slow
```

**On the build tier, `make check-all-host` is the sweep that runs.** It is
every gate that needs no emulator and no ROMs: the assembler dialect, the
column limit, ASCII, the kernel-image size ratchets, two static hardware
lints, and the host side of all three differential gates. The rest of the
sweep boots a machine, which needs the test tier. The list is derived from
make's own rule database rather than written by hand -- see
`scripts/check_host_sweep.py` -- so it cannot quietly grow a gate you
cannot run. A green there means the static rules hold and the tree builds;
it does not mean the kernel works.

`check-nas-selfmake` executes about 8.30 billion emulated CPU cycles and is a
milestone/nightly check, not an edit-compile-test check. The ordinary sweep
builds its self-host image, which catches source-graph and fixed-capacity
regressions without paying for the complete emulated rebuild.

The test strategy includes byte comparison against independent toolchains,
host differential oracles, deliberate mutation/sabotage checks, hostile disk
images, and fast plus RTL emulator tiers. The latest measured conformance
scoreboard is [docs/POSIX-CONFORMANCE.md](docs/POSIX-CONFORMANCE.md).

See [verification and evidence](docs/VERIFICATION.md) for target exclusions,
log capture and the current qualification boundary. The recorded full sweep
at `828309c` had five failures; the later NAS passes are not a replacement
for a fresh complete canonical green on the release candidate.

## Releases and supported machines

`make release VERSION=X.Y.Z` builds a non-overwriting release directory from
an exact `vX.Y.Z` tag after `play-image` succeeds. It includes the bootable
image, a source archive from the same commit, the dependency lock, a manifest,
support/limitations summaries, and SHA-256 hashes. The target refuses a dirty
tree or an untagged commit; see [docs/RELEASE.md](docs/RELEASE.md).

The current [support matrix](docs/SUPPORT.md) distinguishes automated emulator
evidence from physical-hardware evidence. In particular, physical sparse or
aliased auxiliary-memory cards remain unverified, and the original pre-v3
UltraTerm has a named IRQ incompatibility. The release-facing
[known limitations](docs/KNOWN-LIMITATIONS.md) also lists the self-hosting
boundary and current conformance gaps.

## Project map

- `src/kernel/` -- kernel and device/terminal implementation
- `src/liba/` -- native userland support library
- `src/bin/` -- assembly utilities and development tools
- `src/asm/nas.pla` -- assembler written in PLASMA with inline native assembly
- `src/plasma/` -- maux PLASMA runtime adaptations
- `src/test/` -- on-machine test programs
- `scripts/` -- image builders, emulator drivers, differential tests, and audits
- `docs/ARCHITECTURE.md` -- architectural invariants and dated design history
- `docs/PROJECT-STATE.md` -- current status and accepted project risks
- `docs/TASKS.md` and `docs/PLAN*.md` -- chronological design/task record

## Important limits

maux deliberately has no process memory protection. It is single-user, has no
network stack or C compiler, and uses ProDOS storage semantics. Several POSIX
features are inapplicable or explicitly out of scope; the conformance suite
keeps the remaining semantic gaps named rather than normalising them away.

**Text.** maux WRITES high-bit-set 7-bit ASCII terminated by `$8D`, and types
those files `$04`. That is a maux ruling, not a property of the machine:
standard ProDOS text is low ASCII terminated by `$0D`, and the same `$04` type
byte describes both. So the line-oriented tools READ either convention -- a
file delivered by `a2til`, by `tip`, or out of a NuFX archive is processed, not
just displayed -- and a filter emits the encoding its input arrived in, so
running one over a foreign file does not leave you a mixed one. That includes the
build tools: `nas` and `make` read either convention (`check-nas-text`,
`check-cmdword`). `check-encoding` is where the convention is declared and
measured.

The project is licensed under the MIT License. Vendored or externally obtained
ROMs, ProDOS, PLASMA, and emulator components retain their own licensing and
distribution conditions. Merlin-8 is the exception: it is public domain (Glen
Bredon's widow released all of his Apple II software and source on
2000-08-24), so the Merlin core inside `as` ships on the release disk
without conditions.

Historical manual text retains its own grants and notices; see the
[manual source register](docs/man/SOURCES.md) or `man licenses` on the disk.
This product includes software developed or owned by Caldera International,
Inc. This product includes software developed by the University of
California, Berkeley and its contributors.
