# Host preparation and trusted seed

Status: VERIFIED 2026-09-18. `make bootstrap-deps` deliberately performs no
privileged package installation. This page records the host layer used for the
independent Linux reproduction so that "second host" does not collapse into an
unnamed workstation state.

## Verified Linux host

- Debian GNU/Linux 12 (bookworm), x86_64; Linux 6.17.2-1-pve
- GCC/G++ 12.2, GNU Make 4.3, Git 2.39.5, Python 3.11.2
- user-local `merlin32` v1.1.10 and ACME 0.97
- Debian development packages included `autoconf`, `automake`, `bison`,
  `flex`, `help2man`, `ninja-build`, `libsdl2-dev`, and `libxtst-dev`

The exact locked tools not supplied at the required version by bookworm were
built into `/home/mdj/opt/maux-locked-tools`, not installed over system files:

| source | version | downloaded source SHA-256 |
|---|---:|---|
| nlohmann/json | 3.12.0 | `4b92eb0c06d10683f7447ce9406cb97cd4b453be18d7279320f7b2f025c10187` |
| Verilator | 5.048 | `02d934b3f972c6d9b792350634d81eadfc9e61f347e3f3bdcaad40960b9fcb53` |
| SDL3 | 3.4.16 | `7322236cd12090c3eb40b9728be4d49c76f66ad17d04369584d4ecad5cf77c68` |
| sdl2-compat | 2.32.72 | `ea85207d11f38d0da8980163eb7bbfd03ce4636c40a8d25112559bb1d381bbca` |
| mandoc | 1.14.6 | `8bf0d570f01e70a6e124884088870cbed7537f36328d512909eb10cd53179d9c` |

SDL3 3.4.16 is the runtime paired with the locked sdl2-compat release; maux
checks the exposed SDL2 compatibility version, which is what verilogapple's
frontend compiles against. The local prefix was exposed only through `PATH`,
`CPATH`, `PKG_CONFIG_PATH`, `CMAKE_PREFIX_PATH`, and `LD_LIBRARY_PATH` for the
bootstrap and gates. Mandoc is now built by `bootstrap-deps` inside the
project-local dependency tree rather than installed into that prefix.

## Independent reproduction result

The source was cloned at `a04c49f40c0d6f9a2939933fa5f44090f0de5b72`.
The locked a2til and verilogapple commits came from private shallow mirrors
because the clean host intentionally had no Forgejo credential. URL rewriting
was supplied through `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_*` for that process
only; no global Git configuration was changed. PLASMA came from its locked
public URL.

The run then performed:

```sh
make bootstrap-deps ROM_DIR=/opt/verilogapple/roms
make check-deps
make -C .deps/verilogapple mcp
make -C .deps/verilogapple mcp
make check-deps
make vendor-prodos vendor-merlin
make play-image
make check-boot
```

`fast_sdl` linked against the local SDL2 compatibility library and `make play`
remained running under SDL's dummy video/audio drivers until an external
five-second timeout terminated it. Git status remained clean. The ROM files
were pre-existing operator-supplied dumps and matched every byte length and
SHA-256 value in `dependencies.lock.json`.

This record does not turn apt, GCC, libc, CMake, or the kernel into locked
inputs. They are the declared trusted host-preparation layer. Replacing that
layer with a hermetic compiler/sysroot is a separate bootstrap-boundary choice,
not something the project-local dependency bootstrap silently claims to do.

## The build tier's host layer (DEPS-TIER, 2026-10-19)

`make bootstrap-deps TIER=build` needs far less than the test tier and no
operator input. Same rule as above: it installs nothing as root and nothing
over system files; the host layer is the declared trusted seed.

- Python >= 3.10. Nothing else about Python: if `python3 -m venv` gives a
  venv with pip, a2til goes into `<DEPS_ROOT>/venv` with `pip
  --require-hashes` (`PIP_CONFIG_FILE` is pointed at /dev/null and user site
  is disabled for that pip, so an operator's pip configuration cannot change
  what is installed); on stock Debian, which has `venv` but no `ensurepip`
  until `python3-venv` is installed as root, the venv is made `--without-pip`
  and the locked wheel is fetched, checked against the lock's length and
  sha256, and unzipped into it. No root, no `apt install` either way.
- Git and Make, and a C compiler (PLASMA's `xplasm`, mandoc 1.14.6 built
  from its hash-checked source).
- `merlin32` v1.1.10 and ACME 0.97 on `PATH`.
- Network: GitHub (PLASMA, and the a2til fallback), PyPI, `mandoc.bsd.lv`
  (mandoc), `releases.prodos8.com` and `mirrors.apple2.org.za` (the public
  ProDOS and Merlin media for `make vendor-prodos vendor-merlin`).
  Nothing else; in particular no Forgejo host and no credential helper.

Not needed, and not checked, in this tier: Verilator, SDL2, nlohmann/json,
a C++ compiler, the ROM set, verilogapple. The 2026-10-19 clean-clone proofs
of this tier are recorded in docs/DEPS-TIER-NOTES.md.

## The ROM set on the gate box (KFIX12, 2026-10-20)

A host runs emulator gates only with the operator ROM set in the lock's
`roms` table (nine files; docs/DEPENDENCIES.md "Operator-supplied ROMs").
Two ways to put it there, and both read the same table:

- `make bootstrap-deps ROM_DIR=...` (a fresh provisioned tree): refuses
  before any network access if `ROM_DIR` lacks, or holds a wrong copy of,
  any file, naming it.
- `sh scripts/box_provision.sh` step 1 (the long-lived gate box): reads
  `dependencies.lock.json`, checks each file in this Mac's
  `$VA_LOCAL/sim/roms` against the lock's length and sha256, sends it to
  `$VA_BOX/roms/`, links it into the in-tree `sim/roms/` (one link per
  file; a leftover whole-directory `ultraterm/` link from the earlier
  version of the script is replaced), and re-checks the hash on the box.
  The file list is not kept in the script. Before 2026-10-20 it was, and
  it named only the mouse and UltraTerm files, so `disk2.rom`, which the
  box carried by hand, never entered any provisioning record.

verilogapple's peripheral loaders read `sim/roms/` relative to the worker's
working directory and ignore `VERILOGAPPLE_ROMS`
(`learning:01M1QYXWW0WXMCY6E20V2BTTZK`), which is why the in-tree links
exist at all.
