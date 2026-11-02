# NAS: current implementation and build boundary

Status: LIVE, 2026-09-19. NAS is the production assembler for the native
`make` + `nas` + `ld` rebuild. It remains named `nas`; the older `as` is the
Merlin/Sweet16 implementation, not an alias for NAS.

## Use

Inside maux:

```sh
nas -o OUTPUT INPUT.S
```

`-o` precedes the source; without it the output name is `A.OUT`. Successful
assembly returns zero, reported failures return one. Flat output and Merlin
REL objects are supported; the source's directives determine the output form.
This is the dialect implemented and tested in this repository, not a claim
to accept every Merlin macro or historical command-line option. In particular,
the old design's proposed `-l` is not part of the current usage string.

Streams (NAS-STDERR): every diagnostic -- usage, unknown label, branch out of
range, phase error, `pass 1/2 failed`, `cannot write`, `out of memory` -- goes
to fd 2, so `nas x.s 2> ERRS` captures it and leaves the glass silent. The
success line `nas: N bytes -> FILE` stays on stdout (the POSIX convention for
a tool's report; gates and makefile rows read it there). A script that
captured a log with `>> LOG` needs `>> LOG 2>&1` to keep seeing failures. The
writer is `eputc`/`eputs`/`eputi`/`eputln` in nas.pla (one `fileio:write(2,..)`
per byte, failure paths only). rt's own startup messages (`rt: no memory`,
`usage: plasma MODULE`) still use stdout.

## Production source and build

The implementation is `src/asm/nas.pla`: PLASMA plus handwritten inline
6502 assembly. Native control handles the instruction fast path, parsing and
simple values. PLASMA handles services, directives, label management and
general expression fallback. It is neither pure PLASMA nor generated AOT.

Run `make build/nas.cut` on the host. The current chain is:

1. `scripts/nas_inline.sed` transforms a scratch copy in `build/nasmac/`.
2. Locked PLASMA `xplasm -AMOW` emits ACME assembly.
3. ACME creates `build/nas.mod`.
4. `scripts/plascut.py` binds the runtime/module closure, applies NAS's
   constant/immutable-native annotations, and writes `build/nas.cut`.

The cooker prelinks and arranges warm-state restoration; it does not turn
PLASMA bytecode into native instructions. Image builders stage the cooked
binary as `/BASIC/BIN/NAS`. Dependency provisioning is described in
[DEPENDENCIES.md](DEPENDENCIES.md).

NAS streams two source passes and grows stable symbol records, local-name
records, opcode replay pages and deferred records as needed. It does not
retain the whole source or run the former preliminary counting pass. The
private native zero-page contract, including per-invocation initialization,
is in [NAS-TWO-PASS-REFACTOR.md](NAS-TWO-PASS-REFACTOR.md). That window is a
NAS implementation detail, not a general PLASMA extension ABI.

The `nasgrow`, `nasloop`, `nasread`, `nasreplace` and `nasstate` source
fragments and `build_nas_{grow,loop,replace,state}.py` scripts are historical
experiment/oracle material. They are not alternative production build paths.
Do not regenerate production NAS through an old source-transform experiment.

### Which NAS scripts are live, and which are experiment material

The `scripts/` directory now holds three different kinds of NAS tool and the
names do not distinguish them, so they are named once here. Register added
2026-09-19; the Makefile is the executable authority.

**Permanent gates, wired into the ordinary sweep.** Breaking one breaks
`check-all`:

- `check_nas_boundary.py` (in `check-nas`) with its fixtures
  `src/test/asm/{boundary,boundaryfail,boundneg,noxc,passone,passtwo}.s`;
- `check_nas_memory_model.py` (in `check-nas-selfmake-image`);
- `check_nas_grow_guest.py` (in `check-nas-selfmake`).

**Live but opt-in.** `check-nas-native` runs `check_nas_native.py`,
`check_nas_grow_native.py`, `check_nas_line_native.py`,
`check_nas_note_native.py` and `check_nas_commit_native.py` as independent
CPU oracles for the promoted native code. It needs ACME and py65, which the
ordinary build lock deliberately does not require, so it is outside
`check-all` and named in [VERIFICATION.md](VERIFICATION.md).

**Retained reproducers for the current measurements.** Not gates; they are
how a live performance document's numbers get re-derived, so they are kept
whether or not the Makefile calls them:

- `profile_nas_scaling.py` -- the five-size NAS/AS comparison in
  the cumulative progress record, which prints its own
  repeat command;
- `profile_nas_real_paths.py` and `profile_nas_merlin_paths.py` -- the
  source-bound full-cycle traces behind
  the promotion profile and the Merlin path comparison;
- `profile_nas_hotspots.py` -- the reproducible cooked real-source hotspot
  profile;
- `profile_nas_cooked_vs_as.py`, `profile_nas_paired.py` and
  `profile_nas_directives.py` -- flat-output NAS/AS comparisons that the
  chronology cites and that still run against any cooked binary.

**Experiment material, kept as evidence of rejected alternatives.** Nothing
in the build calls these, and the designs they measure are superseded by the
promoted assembler (the loop prototype and the native replacement were both superseded):
`build_nas_{grow,loop,replace,state}.py`, `check_nas_loop.py`,
`check_nas_loop_native.py`, `check_nas_replace_native.py`,
`check_nas_state_native.py`, `check_nas_mode_native.py`,
`check_nas_fused_native.py`, `check_nas_fixed_world.py`, and the five
`nas*.pla` fragments above. Read them for method; do not promote from them
without re-measuring against the current production binary, because their
baselines no longer exist.

## Verification and measurements

For NAS changes, use `check-nas`, `check-nas-rel`, `check-dialect`,
`check-modules` and `check-nas-selfmake-image`; the separate
`check-nas-native` target adds ACME/py65 CPU oracles. Run the full
`check-nas-selfmake` for an integration milestone. Its world is 91 staged
units (88 UTILS -- 89 less `as` -- plus `ld`, `proshimcr`, `proshimpg`) and
the kernel; it replaced the Merlin-window `check-selfmake`, retired
2026-10-18. See
[VERIFICATION.md](VERIFICATION.md) for scope and evidence requirements.

The latest cumulative measurement records
3.04x warm throughput across five fixed real REL pieces and a world rebuild
of 16.50B -> 8.30B cycles against the preserved original baseline. These
are fast-emulator results with explicit input and binary identities, not
physical timings or a promise for arbitrary source.

## What is not self-hosted

The native world rebuild consumes a prebuilt NAS. It does not rebuild
`nas.pla`, the compiler or the cooker. The on-target `plasm` compiler can
compile supported PLASMA source, but its current parser does not accept
NAS's inline `asm` blocks. Host source preparation/splitting and image
construction also remain outside the guest rebuild.

A closed bootstrap would need an on-target compilation and native-helper
assembly/binding route plus executable cooking and source/media preparation.
That is separate work, not an inherent impossibility caused by mixed-language
source. It is deferred during consolidation; see
[PROJECT-STATE.md](PROJECT-STATE.md).
