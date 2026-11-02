# `ld`: the native REL linker, STREAMING

> **RETIRED GATES, 2026-10-18 (RULINGS-1).** `check-selfmake`, `check-librelas`, `check-librel` and `check-relink` -- the gates this document names -- no longer exist (targets, `build_librelas_image.py` and the dedicated drivers deleted; `check_librel.py` and `relink.py` stay as a library and a reference model). `check-nas-librel` and `check-nas-selfmake` are the live gates. The text below is history.

**Status 2026-09-13: pass 2 STREAMS.** `ld` no longer builds the
image in memory. Per module it reads the dictionary tail once,
resolves the module's externals from the symbol table, then streams
the code through a 2 KB chunk buffer -- every fixup applied as its
offset passes -- straight to the output file (`src/bin/ldstream.s`).
Across a link only the symbol table is resident (16 KB now); per
module, only its dictionary; of its code, one chunk. The 26,368 B
build area, and the "whole pre-`-z` image must fit" bound it imposed
(make linked 30 B under it; ex, sh, vi, bpatch could not link at
all), is gone. `-z` became a pending-zero-run counter the writer drops
at end of link -- the same trailing-span rule, with nothing
materialised. A 64 KB machine cannot hold a big object and the output
is serial anyway; this is the architecture the linker should have
had from the first cut (operator ruling, docs/AS-LINKER-SPIKE.md).

Two refusals guard the one assumption streaming leans on: fixup
records must be in ascending offset order (`ld: fixups out of order
in <module>`): nas writes them so, real Merlin writes them DESCENDING
(a stack, last fixup first -- measured on check-librelas's objects)
and ld reverses such a list in place before its cursor starts; and
must lie inside the module (`ld: fixup outside module`). A 2-byte
fixup straddling a chunk end holds the chunk's last byte back for the
next read. A failed pass 2 destroys the partial output, so a failed
link never looks linked (check-ld's NOLIB contract).

Gates on the streaming linker: `check-ld` (byte-identical to real
Merlin's LINK, twice in one boot, `-l`/`-L`/fixpoint/`.SYSTEM`/refusal),
`check-nas-librel` (the util roster via nas), `check-librelas` (the
`as` roster and the kernel links), `check-relink` (host model; now
checks the symbol pool, not a build window).

**Status 2026-09-13, later: check-librelas is GREEN on the streaming
linker** -- 46 utils and 31 kernel images byte-identical (`-l k`,
39-45 modules each), sharded over six emulator instances (about
three minutes; it was ~300B cycles on one). Two linker facts it
settled: real Merlin writes a module's fixup list DESCENDING, so
pass 2 reverses a descending tail in place before its ascending
cursor starts (`REVFIX`); and ld's own REL main no longer fits
`as`'s 7,936 B object buffer (4,813 B of code plus dictionary), so
the self-host sweep cuts it in two before `ldzout.s`
(`build_librelas_image.SPLIT_MAINS`, generate_split_main's
`put:` cuts) -- ld builds itself as two REL pieces plus liba, and
links byte-identical. The proshim overlay blobs (`org $E000` /
`$BF00`) link with `-a`, which also stamps the aux type.

**Status 2026-09-01 (the build-area version, superseded above):
IMPLEMENTED and passing, `-l` positional and
under load -- the KERNEL links ride it** (`ld -t FF -a 2000 -o
MAUXPLAY.SYSTEM PLAYM0R <KDISPR> PLAYM1R -l k PLAYM3R PLAYM4R`
inside check-librelas, byte-identical to the monolithic image).
`src/bin/ld.s` + `ldpass.s` + `ldsym.s` + `ldpass2.s` +
`ldlib.s` is a working two-pass linker with library search, in
5,528 bytes against the bridge's 20,657. It passes
`check-ld` (byte-identical to the stock Merlin LINK, warm respawn and
error path included) and links all 34 utils of the `check-librelas`
sweep byte-identically, MV's 13-module link among them.

**It IS `ld` now**; the bridge it replaced is `mld` (the Merlin
linker, which is what it always was), and `LD_UNDER_TEST=mld` runs
either gate against that instead.

**And it fits `as`'s own source window** -- 12,811 B against 16,126,
once its passes were split into separate files. So maux can rebuild its own
linker. The bridge is over that window by 20,136 B and no split
reaches it, which makes this a payoff of the rewrite rather than an
accident: a linker small enough to be self-hosted is a different
object from one that carries a 1982 core inside it.

**`-L`/`-l` and the LIB directory are BUILT and gated** (2026-08-30).
`ld -a 2000 -o OUT RTMAIN -l c` finds `RTLIB` in `/BASIC/LIB/LIBC`
and links byte-identically to naming it explicitly, with a decoy
member present that must be rejected, a `-L` path, the fixpoint
rescan, and `-l` on a library that does not exist. `check-ld`
covers all of it.

Under load since 2026-09-01: the check-librelas KERNEL links pull
their 31/34-module middle runs from `/LIB/LIBK` with one positional
`-l k` each (see the placement section below). The liba lines still
name modules explicitly; converting them to `-lc` is cosmetic now.

---

`src/bin/mld.s` is a *linking loader* -- it embeds Merlin's own
`LINKER.S` and emulates the MLI calls that core makes. This document
is the plan for replacing it with a linker maux actually owns.

Prerequisite, and it is done: `docs/REL-FORMAT.md` records the object
format, and `scripts/relink.py` is a host model that reproduces the
stock Merlin LINK byte-for-byte on the reference link and on all 34
utils `check-librelas` builds. **The algorithm below is not a
proposal; it is a transcription of code that already produces the
right bytes.** (`make check-relink` kept it that way until it was
retired, 2026-10-18; `check-ld` and `check-nas-librel` hold it now.)

## 0. Why replace it at all

The bridge works, and three things about it are permanently awkward:

* **It costs ~9 KB of image** to carry a copy of `LINKER.S` plus the
  P6 ROM stubs, in a 43.5 KB process bank that also needs the build
  area and a dictionary.
* **Its dictionary eats its own image.** `LINKER` grows a symbol
  dictionary up from `SYMADR` through ld's already-executed startup
  code and then through the embedded blobs. That works only because
  the blobs are *sacrificial*, which is why moving them out was
  refuted (docs/S9-PLAN.md L4 item 2) -- the bank survives by
  overlapping live demand with spent memory.
* **It cannot grow features.** Library search, `-l`, better
  diagnostics, and a symbol map all mean patching a vendored 1982
  binary through an MLI shim.

A native linker deletes all three problems at once: no core, no
sacrificial region, and the dictionary is ours to place.

## 1. The algorithm

Two passes over the module list, exactly as `scripts/relink.py`:

**Pass 1 -- place and export.** For each module in link order: read its
code length from the directory entry (**the ProDOS AUX TYPE is the
code length**), assign `base = next_addr`, advance `next_addr` by that
length, then read its symbol list and record every `ENT` as
`base + (addr - $8000)` in the global table. Nothing is emitted.

**Pass 2 -- lay down and fix.** For each module: read its code to
`BUILDBASE + (base - link_addr)`, then walk its fixup list and apply
each record. Then, if `-z`, truncate the trailing zero span and write
the file with the link address in AUX.

Pass 1 needs only each module's *symbol list*; pass 2 needs its code
and *fixup list*. Both live past the code, so both passes stream the
file rather than holding it -- the existing `MODCHUNK` streaming in
`ldload.s` is directly reusable and is already sized for the largest
dictionary in the tree.

### Applying a fixup

`kind, offset_lo, offset_hi, byte3`. Resolve a target, then write it:

| kind | target | write |
|---|---|---|
| `$0F` | `modbase + (byte3 - $8000)` | low byte at `offset` |
| `$4F` | `modbase + ((code[off]<<8 \| byte3) - $8000)` | high byte |
| `$8F` | `modbase + (code16 - $8000)` | 2 bytes |
| `$1F` | `sym[byte3] + code[off]` | low byte |
| `$50` `$51` | `sym[byte3] + ((code[off]-$80)<<8)` | high byte |
| `$9F` | `sym[byte3] + (code16 - $8000)` | 2 bytes |

Two traps, both found by the host model and both silent:

* **Externals carry an ADDEND.** `byte3` is the refnum, so the addend
  lives in the code as `$8000 + n`. Ignoring it mis-links every
  `SYM+n` -- 30 of 34 utils.
* **`$51` exists** and is `$50`'s twin. Four occurrences in 12,965
  records. Treat them identically.

## 2. `-l` and the LIB directory -- the Unix part

Today every module is named on the command line, which is why the
sweep's link lines run to 254 characters and why `sh`'s LINEMAX is a
design constraint. That is not how linking should work.

    ld [-a addr] [-z] [-o out] [-L dir] [-l name] module...

**A library is a DIRECTORY of REL objects.** maux has no archive
format and does not need one: ProDOS directories already are the
archive, and `readdir` already works. `-l c` means "search the
directory `LIBC`", found under each `-L` path in order and then under
the built-in default `/<boot>/LIB`.

**Members are pulled in SELECTIVELY**, which is the part that makes
this a real `-l` and not a glob:

1. Link the explicitly named modules first; some symbols are left
   undefined.
2. For each `-l` in command-line order, scan its directory. Read each
   member's symbol list only. If a member `ENT`s a symbol that is
   currently undefined, mark it for inclusion.
3. Including a member can create new undefined symbols, so repeat the
   scan over that library until a pass adds nothing.
4. Move to the next `-l`. Order matters, exactly as in Unix.

**A constraint liba imposes, which the sketch above missed:** only ONE
`OPENDIR` may be live at a time (`src/liba/readdir.s`'s own header --
it keeps a single block buffer and cursor). Reading a member's symbol
list while walking its directory would be an open FILE during an open
DIRECTORY, which is fine, but the fixpoint loop wants to re-walk, and
nothing may nest. So each pass **collects the member names first,
CLOSEDIRs, and only then opens members** -- which is also cheaper,
since a library's directory is read once per pass rather than held
open across a few dozen file opens.

This gives archive semantics with no archive: no `ranlib`, no index to
go stale, and `ls /LIB/LIBC` tells you what is in it. The cost is a
directory scan per pass, which is a `readdir` plus a short read of
each member's symbol list -- the code is not read at all.

**`liba` becomes `/LIB/LIBC`.** Today `check-librelas` names eight
library modules explicitly on every link line. With `-lc` the line
becomes `ld -z -o CAT CATMR -lc`, which is both shorter than
`LINEMAX` by a wide margin and the first time a maux link line has
looked like a Unix one.

### What is deliberately NOT in v2

No `--start-group`, no version scripts, no shared objects, no `-Map`.
A symbol map is worth wanting later and is cheap once the global table
exists; it is not v2.

## 3. Memory map

**There is no build area (2026-09-13).** From the top of the bank
(`$BD00`) down: the 2 KB code chunk (plus one carried byte), then the
three `-l` resolution pools; everything else -- the arena, the 16 KB
symbol pool, the tail buffer -- lives below `POOLBASE`, and an `err`
guard at the arena's end keeps them apart. The only per-link limit
left is the symbol pool (`SYMNMCAP`), which `check-relink` models on
the host from the objects; the only per-module limit is the
dictionary tail buffer (`TAILCAP`, 3,584 B against a measured
maximum of 2,323).

The build-area history, kept because it explains the old numbers in
the gates' comments: `BLDTOP` was `$BD00` because the bank is
writable up there (the bridge's `$B200` ceiling was its embedded
core's), `BUILDBASE` sat at `$5600`, and the whole PRE-`-z` image --
bss zeros included -- had to fit the 26,368 B between them. `diff`
wrote 3,864 B and needed 23,402 B of it; raising `BUILDBASE` by 3 KB
for the `-l` pools broke exactly that one util. That is the wall the
streaming pass removed.

Nothing in this layout depends on a region being sacrificial, which
is the trap `mld` lives with.

## 4. Order of work

1. **Host model** -- done (`scripts/relink.py`; its gate `check-relink` was
   retired 2026-10-18).
2. **Native pass 1 + 2, no `-l`.** Byte-identity against
   `check-ld`'s stock reference is the gate, and it already exists.
3. **Swap `ld.s`** once `check-ld` and `check-librelas` are green on
   the native one. Develop as a separate binary until then -- every
   other gate links with `ld`, so a broken `ld` stops the tree.
4. **`-L`/`-l` and the LIB directory**, then rewrite the sweep's link
   lines to use `-lc` and prove the output is unchanged.
5. **Retire** the embedded core, `ldload.s`'s bridge halves, and
   `docs/LD-DESIGN.md`'s MLI-shim sections.

Step 3's ordering is the one that matters: **do not develop in place.**
`check-librelas` links 34 utils with `build/ld.bin`, so an `ld` that
half-works takes the whole sweep with it.

## 5. Gaps -- audited, then closed (2026-08-30)

Written after the linker passed its gates, because "it passes" and
"it is finished" are different claims. Each item was checked in the
source, not recalled. **Everything in the first three groups is now
fixed**; what remains is listed at the end.

### Silently wrong -- CLOSED

* **Duplicate symbols** are a link error. They used to link quietly
  with the first definition winning, while `scripts/relink.py` raised
  -- the model and the implementation disagreeing, model right.
* **The dictionary walk is bounded.** `READTAIL` computed `ND_END`
  and nothing read it; `SKIPFIX`/`SYMREC` stop at it now.
* **Pool-full returns are honoured.** `ADDMOD`/`ADDSYM` checked their
  carry, both `ADDUNDEF` sites and `ADDMEMBER` did not -- a full
  member pool silently half-scanned a library.
* **Module type is checked** (`$F8`) before its aux is read as a code
  length.
* **`SEEDUNDEF` ordering**, found while fixing the above: it
  collected undefined EXTs against an EMPTY pool, so every reference
  looked undefined including ones another named module satisfied. Two
  sweeps now -- publish ENTs, then ask what is missing.

### Diagnostics -- CLOSED

Every message names its subject: `ld: undefined symbol QBSYM`, module
errors carry the path. REL names are raw 7-bit and liba's are
high-bit, so `SYMBUF` converts rather than emitting control
characters. Usage lists `-L`, `-l`, `-t`.

### Coverage -- CLOSED

`LDOUT4` exercises a `-L` search path and the fixpoint rescan
together; `SYSOUT` covers `-t`; `NOLIB` covers `-l` on a library
that exists under no search path -- it must refuse, because writing
the output anyway leaves `LIBUSED` unresolved in a file that looks
linked.

**The fixpoint test did not bite at first, and that is the part worth
keeping.** Written with QA created before QB it passed with the
rescan DELETED: ProDOS lists a directory in creation order, so one
sweep took QA and then met QB with `QBSYM` already undefined. The
chain was real and the ordering made it reachable in a single pass.
QB is created FIRST now, so the sweep meets it before it is wanted
and only a rescan returns for it. **A dependency test proves nothing
until the dependency is encountered in the harder order.**

### `.SYSTEM` output -- ADDED, and what it does NOT yet give us

`-t <hex>` sets the output's ProDOS file type (default `$06`).
`-t FF -a 2000` produces a `.SYSTEM` file: type `$FF` loaded at
`$2000` is what ProDOS's system loader wants, and the link address
was already going to aux. The gate checks the bytes AND the type,
because a `.SYSTEM` ProDOS will not load is not one.

**That is the enabling half, not the whole path.** `ld` can now
*stamp* a system file, but maux cannot yet LINK one of its own
kernel images: the 27 `.SYSTEM` images are still whole-tree
merlin32 builds, and REL-converting a kernel manifest is L4's
remaining work (docs/S9-PLAN.md). What `-t` removes is the reason
that could not have worked even once the modules existed -- the
linker had no way to produce anything but a `$06` BIN.

### `-l` is POSITIONAL, and placement is DIRECTORY order (2026-09-01)

The kernel links put `-l` under load and forced the ordering
contract to be stated: **the fixpoint decides the SET, the
directory decides the ORDER, the flag's position among the operands
decides WHERE.** Taken members are spliced into the module list at
the `-l`'s own place (`ldscan.s` `LIBSPLICE`), in directory
(= creation) order -- NOT in discovery order, which varies with
which rescan pass found a member. That is what lets `/LIB/LIBK`,
staged in kernel put order, link `MAUXPLAY.SYSTEM` byte-identical
to the monolithic merlin32 image: the closure takes exactly the
manifest's kernel run (34 members for playtest, 31 for forktest --
KMOUSE/KTIMER correctly left behind, KBPRB/KMLI never taken), and
directory order IS put order. `check-relink` models the closure on
the host and asserts both halves per manifest; `check-ld`'s LDOUT4
chain asserts the placement (QB created first links first even
though only the rescan takes it). Unix precedents disagree among
themselves here (V7's single forward scan could not link this at
all -- the `lorder` problem; GNU appends by discovery), so the
directory-order rule is a choice, made for byte-identity and
determinism, and it is gated.

The resolution pools (`UNDEFPOOL`/`MEMPOOL`/`TAKEPOOL`) moved into
the build-area overlap -- live only during `LIBRESOLVE`, which
returns before pass 2's first write -- because the kernel closure
measured 2,294 B of undefined names and the arena bytes would have
come out of the build window MAUXEXPR needs. `BUILDBASE` is $5A00
(arena end $59C4, measured), window 25,344 B.

### Still open

* **The liba sweep still names all eight modules per line** rather
  than `-lc`; the kernel links are the ones on the flag. Converting
  the util lines is cosmetic now the feature is loaded and gated.
* **`-l` caps are sized to today's tree**, not to headroom:
  `MEMPLCAP` 768 (34 kernel members = 296 B), `UNDPLCAP` 6144
  (was 4096 against 2,294 measured; the playtest kernel link hit
  4,098 on 2026-10-10 with the virtual root's symbols and ADDUNDEF
  and TAKEADD exited 1 with NO message -- the claim below was false
  for those two; they now say `too many symbols` / `too many
  members in`), `LIBDMAX`/`LIBRMAX` are 4. They refuse loudly
  rather than truncating.
* **Deliberately out of scope:** no symbol map, no archive format,
  no `--start-group`, no `-r`. See section 2.
