# LAYOUT -- one tree, host and guest

Ruling, 2026-09-16: **the host layout and the guest layout are the same
tree, and every file name in it is legal on ProDOS.**

Before this, they were two trees that happened to hold the same bytes.
The host had 27 ABI headers in `include/` and 7 more in `src/liba/*.equ`;
the guest had a FLAT volume whose names came out of a hand-kept
`OVERRIDE_NAMES` table in `scripts/build_maux_src_image.py`, because 35
host names -- 33 with underscores, two simply too long -- could not be
spoken on a ProDOS volume at all. The REL objects lived in
`build/librel/` on the host and `/LIB` on the guest. Every one of those
is a place where a reader has to hold two names for one thing, and where
a table can go stale without anything noticing.

## The rules

1. **Every put-able header lives in `inc/`.** 34 files: the 27 ABI
   equates plus liba's 7. Nothing else is `put` from more than one
   directory.
2. **Every name under `inc/` and `src/` is ProDOS-legal**: first
   character a letter, then letters, digits and periods, at most 15
   characters INCLUDING the extension. Case-insensitive, so no two
   names in a directory may differ only in case.
3. **Put lines stay SOURCE-RELATIVE**, in one of exactly two shapes:

       put   NAME                  -- same directory
       put   (../)+SEG/NAME        -- SEG a tree directory

   merlin32 requires the source-relative form: it resolves `put` and
   `dsk` against the INCLUDING FILE's directory, not the cwd
   (`learning:01KW1GTYGZ9TE2ZGCDG0V2CNE0`).
4. **`build/lib/`** holds the cooked REL objects, mirroring the guest's
   `/LIB`.

Rules 2 and 3 are gate rows in `scripts/check_modules.py`
(`check_prodos_names`, `check_put_shapes`); today they see 455 names and
3,972 put/use operands.

## The host/guest table

| host | guest | what |
|---|---|---|
| `inc/` | `/SRC/INC/` | every put-able header, 34 files |
| `src/kernel/` | `/SRC/KERNEL/` | the kernel |
| `src/liba/` | `/SRC/LIBA/` | the C-less libc |
| `src/bin/` | `/SRC/BIN/` | userland |
| `src/test/` | `/SRC/TEST/` | harnesses and fixtures |
| `src/test/asm/` | `/SRC/ASM/` | assembler fixtures |
| `src/plasma/` | `/SRC/PLASMA/` | PLASMA sources |
| `src/asm/` | `/SRC/ASM/` | `nas` |
| `src/merlin/` | `/SRC/MERLIN/` | real-Merlin patch tables |
| `src/relspike/` | `/SRC/RELSPIKE/` | REL-format fixtures |
| `src/*.s` | `/SRC/*.S` | `bootblock.s`, `check.memmap.s` |
| `build/lib/` | `/LIB/` | cooked REL objects (generated) |

The one asymmetry is deliberate: `inc/` sits at the repo ROOT on the
host and under `/SRC` on the guest, because the host also carries
`docs/`, `scripts/`, `vendor/` and a Makefile that the guest volume
does not. That asymmetry is exactly what the resolution rule absorbs.

## The resolution rule (what the guest must implement)

> **Drop the leading `..` segments; anchor the remainder at `/SRC`.**

    from src/kernel/tty.s:   put ../../inc/tty.equ   ->  /SRC/INC/TTY.EQU
    from src/bin/sh.s:       put ../liba/stdio.s     ->  /SRC/LIBA/STDIO.S
    from src/bin/sh.s:       put ../../inc/zp.equ    ->  /SRC/INC/ZP.EQU
    from src/test/edtest.s:  put edtestb.s           ->  (same directory)
    from src/check.memmap.s: put ../inc/mm.hw.equ    ->  /SRC/INC/MM.HW.EQU

The rule is **insensitive to the NUMBER of `..`**, and it has to be:
`../liba/x.s` from `src/bin/` climbs one level on the host while
`../../inc/x.equ` from the same file climbs two, because `inc/` is one
level higher than `src/bin/` is. The guest has one flat level of
directories under `/SRC`, so both forms land correctly once the dots are
discarded. Rule 3 above is what makes the rule TOTAL -- there is no
third shape for it to fail on, and `check_put_shapes` additionally
verifies that the HOST resolution lands where the guest mapping says it
should, so the two trees cannot drift apart silently.

ProDOS has no parent-directory concept at all: its pathname parser has
no `..`, and maux's own `buildputpath` hands the operand to OPEN
verbatim. So the translation must happen in the assembler's reader, not
in the filesystem. `docs/AS-STREAM.md` sec 2 carries this as a
requirement on the streaming `nas`; it is NOT implemented yet.

`put NAME` with no extension is legal -- real Merlin's PUT appends `.S`
itself, and `buildputpath` does the same unless the operand already
contains a dot. `src/test/asm/relmain.s`'s `PUT relsub` is the fixture
that exercises it. Everywhere else the house rule is to write the `.s`,
because merlin32 does NOT reliably append it
(`learning:01KW1GTYGZ9TE2ZGCDG0V2CNE0`).

## The rename table

### Headers: `include/` + `src/liba/*.equ` -> `inc/`

Hyphens became periods. Two families overflowed 15 characters that way,
so they took a short prefix instead: `memmap-*` -> `mm.*` and
`syscall-*` -> `sc.*`. `errno.kernel.equ` would have been 16, so it is
`errno.krn.equ`; `mm.procbank2.equ` would have been 16, so it is
`mm.procbnk2.equ`. Measured lengths in the right-hand column.

| old | new | len |
|---|---|---|
| `include/bankcopy.equ` | `inc/bankcopy.equ` | 12 |
| `include/bankprobe.equ` | `inc/bankprobe.equ` | 13 |
| `include/entry-frame.equ` | `inc/entry.frame.equ` | 15 |
| `include/errno-kernel.equ` | `inc/errno.krn.equ` | 13 |
| `include/errno-spawn.equ` | `inc/errno.spawn.equ` | 15 |
| `include/kdisp.equ` | `inc/kdisp.equ` | 9 |
| `include/memmap-annex.equ` | `inc/mm.annex.equ` | 12 |
| `include/memmap-annex2.equ` | `inc/mm.annex2.equ` | 13 |
| `include/memmap-hw.equ` | `inc/mm.hw.equ` | 9 |
| `include/memmap-main.equ` | `inc/mm.main.equ` | 11 |
| `include/memmap-mli.equ` | `inc/mm.mli.equ` | 10 |
| `include/memmap-mlibuf.equ` | `inc/mm.mlibuf.equ` | 13 |
| `include/memmap-procbank.equ` | `inc/mm.procbank.equ` | 15 |
| `include/memmap-procbank2.equ` | `inc/mm.procbnk2.equ` | 15 |
| `include/mli-const.equ` | `inc/mli.const.equ` | 13 |
| `include/proc-const.equ` | `inc/proc.const.equ` | 14 |
| `include/sched-zp.equ` | `inc/sched.zp.equ` | 12 |
| `include/sched.equ` | `inc/sched.equ` | 9 |
| `include/syscall-devfd.equ` | `inc/sc.devfd.equ` | 12 |
| `include/syscall-fd.equ` | `inc/sc.fd.equ` | 9 |
| `include/syscall-fdact.equ` | `inc/sc.fdact.equ` | 12 |
| `include/syscall-file.equ` | `inc/sc.file.equ` | 11 |
| `include/syscall-proc.equ` | `inc/sc.proc.equ` | 11 |
| `include/syscall-status.equ` | `inc/sc.status.equ` | 13 |
| `include/timer.equ` | `inc/timer.equ` | 9 |
| `include/tty.equ` | `inc/tty.equ` | 7 |
| `include/ultraterm.equ` | `inc/ultraterm.equ` | 13 |
| `src/liba/cptree.equ` | `inc/cptree.equ` | 10 |
| `src/liba/mli.equ` | `inc/mli.equ` | 7 |
| `src/liba/readdir.equ` | `inc/readdir.equ` | 11 |
| `src/liba/regex.equ` | `inc/regex.equ` | 9 |
| `src/liba/startup.equ` | `inc/startup.equ` | 11 |
| `src/liba/stdio.equ` | `inc/stdio.equ` | 9 |
| `src/liba/zp.equ` | `inc/zp.equ` | 6 |

`src/bin/proshim.equ` stays where it is: it is a bin-LOCAL header, `put`
bare from `src/bin/` the way `shlex.s` is, not an interface anyone else
names. Its name is already legal (12).

### Sources

Underscore became a period. Where that overflowed 15 characters the
separator went away instead; where THAT still overflowed, the longest
word was shortened. The `schedtest_*` family moved to a `sched.*` stem
so the four files read as one family at legal lengths.

| old | new | len |
|---|---|---|
| `src/bin/expr_eval.s` | `src/bin/expr.eval.s` | 11 |
| `src/bin/expr_ops.s` | `src/bin/expr.ops.s` | 10 |
| `src/check_memmap.s` | `src/check.memmap.s` | 14 |
| `src/test/ffpage_size.s` | `src/test/ffpage.size.s` | 13 |
| `src/test/fileprocesstest.s` | `src/test/fileproctest.s` | 14 |
| `src/test/fileprocesstestb.s` | `src/test/fileproctestb.s` | 15 |
| `src/test/prodos_spike.s` | `src/test/prodos.spike.s` | 14 |
| `src/test/sched_common.s` | `src/test/sched.common.s` | 14 |
| `src/test/schedtest_coop.s` | `src/test/sched.coop.s` | 12 |
| `src/test/schedtest_preempt.s` | `src/test/sched.preempt.s` | 15 |
| `src/test/schedtest_wake.s` | `src/test/sched.wake.s` | 12 |
| `src/test/asm/prof_large.s` | `src/test/asm/prof.large.s` | 12 |
| `src/test/asm/prof_small.s` | `src/test/asm/prof.small.s` | 12 |
| `src/test/asm/prof_lean_large.s` | `src/test/asm/profleanlarge.s` | 15 |
| `src/test/asm/prof_lean_small.s` | `src/test/asm/profleansmall.s` | 15 |

Three of those stems are dictionary KEYS elsewhere, derived from the
basename by `splitext`: `check_purity`'s not-spawnable table and
`check_poison`'s program set. `expr_eval` is `expr.eval` in them now.

`src/relspike/RTLIB.S#040000` and `RTMAIN.S#040000` keep their names.
The `#TTAAAA` suffix is an a2til/cadius TYPE annotation, not part of the
name (`learning:01KW1GTYGZ9TE2ZGCDG0V2CNE0`); it never reaches the
volume, where the files are `RTLIB.S` and `RTMAIN.S`. The gate row
strips it before judging.

### `build/librel/` -> `build/lib/`

Generated, never committed, `.gitignore` already covers `build/`. The
staging VOLUME `build/librel.po` keeps its name: it is `check-librel`'s
scratch disk, named after the gate rather than after its contents.
(The gate was retired 2026-10-18, RULINGS-1; nothing writes it now.)

## What did NOT change, and why

**Build artifact names.** `build/schedtest_coop.bin`,
`build/check_memmap.bin`, `build/ffpage_size.bin` keep their
underscores, and the `dsk` directives still name them. `build/` is
generated, host-only, and never a ProDOS volume -- and holding those
names still is what keeps the byte oracle for this whole re-layout a
name-for-name comparison.

**Make target and gate names.** `check-librel`, `check-memmap`,
`librelas-image` were names in the Makefile, not paths (the first and
the last were retired 2026-10-18, RULINGS-1).

**Historical prose.** Comments and docs that discuss the pre-split
`memmap.equ`/`syscall.equ`/`errno.equ` monoliths now spell them
`inc/memmap.equ` and so on. Those files have not existed since the
2026-08-20 split; the directory in the sentence was updated with
everything else so that `include/` appears nowhere in the tree.

## The oracle

This was a pure re-layout: path text never reaches an object, so
**every built object must be byte-identical before and after**, and
every one is. 152 objects compared -- 116 `build/*.bin`, 32
`build/*.SYSTEM`, 4 ascore `.obj` -- plus the 167-file `build/play.po`
file set compared per file (the image itself carries ProDOS timestamps
and is not byte-stable on rebuild; its CONTENTS are).

`build/lib/*.rel` could not be compared: `check-librel` (retired
2026-10-18) was RED before
this work and after it, identically, for a reason that predates it --
ten modules (KTTY, KPSPWN2, KTTY8/9/3/4, KSCHED, KLAZY, REGEX2, KTTY2)
exceed real Merlin-8's 41,215-byte source buffer, so the gate stops on
the static budget before booting anything. Same ten modules, same order,
before and after. Their per-module byte figures move by a few bytes
because `strip_comments` passes an INLINE trailing comment through byte
for byte and some of those now spell a shorter path.

## The guest source image, and the mirror that should replace it

`scripts/build_maux_src_image.py` still stages a FLAT volume through
`OVERRIDE_NAMES`/`flat_name()`. It no longer has to. Every name in the
tree is legal now, and the put operands all resolve under one rule, so
the image could be a straight MIRROR of the host tree -- `a2til mirror
IMAGE:/VOL/DIR LOCALDIR` poll-syncs a host directory into a mounted
volume with translation and transactional passes (see `~/src/a2til`'s
README, Mirror section), one invocation per directory.

Two things keep the flat form alive for now, and they are why the
mirror is documented here rather than built:

* the Merlin-8 image (`check-merlin` / `check-dual`) is PARKED by the
  operator since 2026-09-12 -- Merlin-8's symbol table is full, and
  `build_maux_src_image.py` itself now reports `DUAL` and `PTEST` OVER
  the 17,400 B ceiling. Nothing currently green depends on the staging
  form;
* real Merlin's PUT wants `/MAUXSRC/SRC/NAME` absolute operands, so a
  mirrored tree still needs the reader-side resolution rule above --
  which is `nas`'s job (`docs/AS-STREAM.md`), not a2til's.

So: the mirror form is now POSSIBLE and is the target; the flat form is
kept working and unchanged until the streaming `nas` implements the
resolution rule.
