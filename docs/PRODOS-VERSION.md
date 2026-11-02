# Which ProDOS maux targets, and why

**Ruling (2026-10-08, operator): maux boots the ProDOS 2.4 kernel
(`vendor/ProDOS-2.4.bin`, banner `ProDOS 8 V2.4 16-Aug-16`), keeps the
legacy 7-bit date layout with the year pivoted at 78 (below), and writes
GS/OS case-preserving names ITSELF (docs/PRODOS-CASE.md). Nothing else
from 2.5.** In the operator's words: "2.5 is the wrong thing. I want
something part way between 2.4 and 2.5 that gives us GS/OS filename case
preservation. but that's about all i want." and "2.5 does the new date
storage thing, which if you ask me makes the filesystem no longer ProDOS
[...] The right answer, if people still want to play with Apple II's in
2107 is to supercede ProDOS."

What that withdraws from the 2026-08-17 ruling below: the 2.5 kernel,
its growable root directory, its Extended dates, its alpha. What it
keeps: the case-flag mechanism (GS/OS TN #8), which 2.4 already READS
correctly in maux (readdir decodes it) and which the kernel will now
WRITE on create/rename/mkdir instead of relying on 2.5's MLI to do it.

Enforcement: `check-prodos-version` (in `check-all`) reads the banner
off every built image. Why it exists: from 2026-08-19 to 2026-10-08 this
file said 2.5 and every image booted 2.4 -- a spike's global
`PRODOSBIN :=` in the Makefile beat the `?=` default -- and nothing
noticed until a /dev/loop measurement dumped a kernel. Measured cost of
actually booting 2.5, for the record: docs/PRODOS25-NOTES.md (Mac 118/10,
box 116/7; Extended dates, case expectations, DEVLST `$B0`, and one real
MLI difference -- ON_LINE after a disconnect returns `$00`, not `$28`).

The 2026-08-17 reasoning is kept below as history; its facts about 2.5
still hold, its conclusion does not.

---

**Superseded ruling (2026-08-17): maux targets ProDOS 2.5 (currently 2.5.0a8).**

## Why not 2.4.3, which is the stable release

Two limits that are usually quoted as facts about ProDOS are in fact facts
about *ProDOS <= 2.4*, and both bite maux directly:

| | 2.4.x | 2.5 |
|---|---|---|
| filenames | UPPERCASE, 15 chars | **mixed case**, 15 chars |
| root directory | **51 entries** | unlimited |
| year field | 7 bits, windowed 1940-2039 | 10 bits, to 2924 -- **see the warning below; this one is not a free win** |

The 51-entry cap is not theoretical -- `scripts/check_v1_system.py` already
carries a comment noting the suite *reached* it and had to move outputs into a
subdirectory. And a Unix that cannot name a file `Makefile` is a Unix with a
1978 accent.

The cost is that 2.5 is an **alpha**. Mitigations: `PRODOS_RELEASE=2.4` in
`scripts/vendor_prodos.py` falls back, every image builder honours
`PRODOS_KERNEL_BIN`, and the whole gate suite runs against whichever is
vendored. Note the alpha is dated **02-Nov-2019** -- it has been unchanged for
years, which cuts both ways: not churning, but never promoted either.

## What mixed-case cost us to support: almost nothing

Measured, not assumed (2026-08-17):

* **Writing** -- ProDOS 2.5's MLI does the encoding itself. Typing
  `ECHO hi > /BASIC/Makefile` at the maux prompt produced a directory entry
  with `MAKEFILE` in the name field and `$BFDF` in `$1C/$1D`, decoding back to
  `Makefile`. **No kernel change.**
* **Opening** -- 2.5 matches case-insensitively. `CAT` of `Makefile`,
  `MAKEFILE` and `makefile` all opened the same file. **No kernel change.**
* **Host-side tooling** -- a2til already reads *and writes* the case flags.
  Writing `/P8.2.5/Makefile` produced stored `MAKEFILE` + `$BF80`. **No change.**
* **Reading a directory** -- the one place maux had to change, because `ls`
  walks raw directory entries itself. See below.

## WARNING: 2.5's dates are NOT legacy-readable, and it stamps them on us

**Do not treat the wider year as a free upgrade.** Measured 2026-08-17, on our
own image:

`ECHO x > /BASIC/stamp.txt` at the maux prompt -- with maux passing
`cdate=0, ctime=0`, as every util still does -- produced a directory entry
holding `date=$8CB3 time=$97E4`. Decoded with the legacy layout
(`yyyyyyy mmmm ddddd` / `000hhhhh 00mmmmmm`) that is **hour 151, minute 228**:
impossible. The same pattern is all over 2.5's own boot disk (`PRODOS` carries
`create[1B7B,C7E3]` -> hour 199, minute 227).

The global page corroborates it: `$BF8E-$BF93` reads `00 2B B3 8C E4 97`, where
`00 2B` is 2.5's new seconds/milliseconds field and `B3 8C E4 97` is precisely
the little-endian date/time pair copied into the entry.

So:

* **ProDOS 2.5 stamps every file we create with an Extended-format date**, no
  matter that we pass zero -- this is not opt-in from our side.
* **The exact Extended bit layout is NOT pinned.** It plainly reuses the spare
  bits of the legacy time word (minute has 2 unused bits, hour has 3), but the
  packing has not been confirmed against a spec, and it is an *alpha* format.
* A naive legacy reader does not fail loudly -- it yields a plausible-looking
  year with an absurd time. `ls -l` written today would print garbage.

**Cheap discriminator, and it is reliable:** a legacy date has `hour <= 23` and
`minute <= 59`. Anything outside that is Extended. Use it rather than assuming.

**Ruling until the layout is pinned:** dates are OPAQUE. `ls -l` reports name,
type and size, and shows `-` for a date it cannot validate. Nothing in maux
writes a nonzero date. When `ls -l` is built, pin the Extended layout from the
2.5 source or a spec first, and gate it behind a validity check either way.

**This does not undermine the 2.5 decision.** The two things 2.5 was adopted
for -- mixed-case names and the removed 51-entry root cap -- are independent of
the date field, and both are verified working. Dates were never in use here:
every util passes 0 today. What changed is that this is now a *known* unknown
with a detector, instead of a silent corruption waiting for `ls -l`.

## Standing ruling: the legacy year window pivots at 78, not 40

For **legacy-format** dates (see the validity check above), maux interprets the
7-bit year with the pivot at **78**, not TN#28's 40:

```
year value 78..99  ->  1978..1999
year value  0..77  ->  2000..2077
```

**Why this is free.** TN#28 windows 1940-2039: values 40-99 mean 1940-1999,
values 0-39 mean 2000-2039. The bottom of that window is dead weight -- the
Apple II had no dated filesystem before the Disk II in 1978 -- so roughly forty
values can never carry a real date. Moving the pivot spends them at the top
instead. TN#28 and pivot-78 **agree on every value that can legitimately
occur** (0-39 and 78-99), so this reads every existing disk correctly,
including images a2til writes host-side (which are TN#28 and must keep
decoding right -- the year field `26` in `build/play.po` means 2026 under both).

**Why 78 and not 83.** The floor is NOT ProDOS's 1983 release. Two corrections
worth keeping:

* **The ProDOS filesystem is SOS's filesystem.** ProDOS 8 TRM, Appendix C.2,
  verbatim: *"SOS and ProDOS use the same directory structure: no exceptions."*
  The Apple III shipped SOS in **1980**, so genuinely-dated files on ProDOS
  media can predate ProDOS itself by three years.
* **Apple Pascal (UCSD, 1979) stores dates too**, and Pascal files can be moved
  onto ProDOS media carrying them.
* **DOS 3.3 did get timestamps -- but not in a date field.** Stock DOS 3.3 has
  none, and its 35-byte catalog entry has no room for one; clock-card vendors
  patched around that. Thunderware's **DOS-DATER** upgraded non-copy-protected
  DOS 3.3 to stamp files from the ThunderClock, with *"the current date and
  time stored in the CATALOG with the file's name"* -- i.e. written into the
  30-character **filename**, the only space available. Applied Engineering
  shipped comparable patches for the Timemaster. Such a stamp does not convert
  into a ProDOS date field (it converts into a mangled 15-character name), and
  clock cards are early-1980s anyway, so this cannot push the floor below 1978
  either.

1978 clears SOS, Pascal, and the Disk II itself, and it puts the ceiling on
**2077 -- the Apple II's centenary**, which is a fitting place to leave the can.
The whole argument for spending the dead range is that if anyone is still
reading these dates when the machine is a hundred years old, they can move the
pivot again; the cost of being wrong is a cosmetic mis-year on foreign media.

**Not implemented yet, deliberately** -- nothing in maux reads a date. This is
recorded so whoever builds `ls -l` inherits the decision instead of re-deriving
it. Decode order there: validate `hour <= 23 && minute <= 59`; if it passes it
is legacy, apply pivot-78; if it fails it is Extended, show `-`.

## Considered and rejected: stealing a spare bit for a century flag

The idea: find one benign bit in the 39-byte directory entry, use it as a
century flag, buy another 100 years without breaking anything. It does not
work, for two independent reasons, and both are worth writing down so nobody
re-derives the idea in six months.

**1. There are no spare bits. The entry is fully spoken for.**

| candidate | verdict |
|---|---|
| `version`/`min_version` `$1C/$1D` | **spent on GS/OS case flags** -- the mixed-case names we adopted 2026-08-17 |
| time-word spares (3 bits in the hour byte, 2 in the minute byte) | **spent by 2.5's Extended date format** -- that is what `$97E4` was |
| `access` `$1E` bit 5 | **backup-needed.** TRM: *"ProDOS sets bit 5 ... whenever the file is changed (after a CREATE, RENAME, CLOSE after WRITE, or SET_FILE_INFO)"*, and it *"should be reset to 0 whenever the file is duplicated by a backup program"*. A live two-party protocol between the OS and backup utilities |
| `access` `$1E` bit 2 | **file-invisible** -- a GS/OS addition, and the `i` in the GNO `chmod` vocabulary this project already adopted |
| `access` `$1E` bits 3-4 | documented *used internally*, not merely reserved |
| `aux_type` `$1F/$20` | meaningful per filetype (record length for TXT, load address for BIN) |

Note the trap in how that reads: the TRM's *"the reserved bits are always 0"*
is a statement about what **ProDOS 8** writes, not a grant of free space. GS/OS
subsequently took bit 2, and the era's utilities used the rest. **"Reserved and
observed zero" is not the same as "free."**

**2. Even with a free bit, it would go stale immediately.** ProDOS rewrites
`mod_date`/`mod_time` from the global page on every write -- that is how
`stamp.txt` got a date despite maux passing zero. A century flag only works if
whoever writes the date also maintains the flag; ProDOS does not know about
ours, so the pair desynchronises on the first write. A stale century bit is
worse than none: it is confidently wrong. **On ProDOS you can choose how to
READ a date; you cannot choose what gets WRITTEN.**

And the whole exercise is moot on 2.5, whose Extended format already carries a
10-bit year to 2924, authored coherently by the OS itself. The outstanding work
is pinning that layout, not inventing a bit. The idea would only have legs in a
maux-owned filesystem where we author every byte.

## The mechanism (GS/OS TN #8), verified against 2.5's own disk

`version`/`min_version` at entry offsets **`$1C`/`$1D`** are one little-endian
16-bit word:

* **bit 15 set** = this word carries case flags;
* character *n* (1-based) reads **bit 15-n**; **set means lowercase**;
* the name in the filename field **stays UPPERCASE**, which is exactly why
  every pre-2.5 tool keeps working -- case is presentation metadata.

Decoded off the shipped 2.5 disk, independently of a2til, and it reproduces:

```
QUIT.SYSTEM    $B9FF -> Quit.System
NOSLOTCLK.IIE  $AEC7 -> NoSlotClk.IIe
COPYIIPLUS.8.5 $B8E0 -> CopyIIPlus.8.5
BOOT.BLOCKS    $BBFB -> Boot.blocks
```

**Two traps found by doing this, both silent:**

1. **The VOLUME (root) directory entry is different** -- it keeps
   version/min_version and puts the case flags at **`$16`/`$17`** instead.
   One entry, wrong offsets, no error.
2. **Flag bits are set PAST the name length.** `PRODOS` carries `$8102`; the
   low bits map to characters 7 and 14 of a 6-character name. A decoder must
   stop at `name_length` -- and must fold **letters only**, or a set stray bit
   would corrupt a digit or `.` into punctuation. `src/bin/ls.s` range-checks
   `$C1..$DA` before folding for exactly this reason.

## Provenance of the vendored kernel

`releases.prodos8.com` is GitHub Pages with an unconfigured custom-domain
certificate -- it serves a valid Let's Encrypt cert for `*.github.io`, so HTTPS
fails the hostname check. No archive.org mirror of the 2.5 alpha exists, so
there is no independent copy to diff against.

**Provenance therefore rests on the artifact, not the transport**, which is
what `scripts/vendor_prodos.py` asserts: the extracted kernel must contain its
own banner, and this one reads
`ProDOS 8 V2.5.0a8  02-Nov-2019Copyright Apple Computer, Inc., 1983-93`.
It then has to boot and pass the full gate suite. Do not "fix" the download by
adding `curl -k`; the check that matters is the banner assertion plus the
gates, and quietly disabling certificate verification would only hide a future
change of hosting.

Library notes: `learning:01M07A3XXC1SS5SQYH4CZCPV44` (2.4 vs 2.5 for builders --
the limits, the case mechanism, the version currency),
`learning:01M0798FFCHB60SWQDE8NQEQXN` (GNO/ME's precedent for mapping Unix onto
Apple filesystem metadata), `learning:01KW1CR53VP3ATCXDYWAMQYB6W` (the legacy
7-bit windowed year, which still describes a 2.4 target).

## The filename namespace we inherit, and why we cannot widen it

Measured on 2.5, creating from guest code through the MLI:

| name | result |
|---|---|
| `a.b.c` | **accepted** -- multiple periods are legal |
| `my-file`, `foo_bar` | rejected |
| `.profile`, `2start` | rejected -- must begin with a letter |

So 2.5 did **not** relax the character set, only the case. Letters, digits and
periods; must begin with a letter; 15 characters.

**And it is a parser rule, not a creation check** -- which kills the obvious
workaround of writing the directory entry ourselves. Proved by isolating the
two: a working `README` had *only its name bytes* rewritten to `MY-FILE`, every
other field left intact. A host-side scan listed it; `CAT /BASIC/MY-FILE`
could not open it. **An illegal name can sit on disk perfectly formed and be
permanently unreachable.**

Consequence for maux: while we go through ProDOS's MLI we inherit the namespace
wholesale. `Makefile` is fine. `.profile` never will be. Widening it means
patching ProDOS, and then those files are unreachable from stock ProDOS, 2.4
and GS/OS -- lost, not merely degraded.

Worth holding onto the principle, because it explains 2.5's apparent
inconsistency: **names are keys, dates are values.** A wrong date displays
wrong; a wrong name means the file cannot be opened at all. That is why the
case work is a scrupulous backward-compatible hack and the date change is a
clean break. It also explains why storage stays uppercase -- case-insensitive
matching keeps working for free, whereas real lowercase would make `Makefile`
and `MAKEFILE` different files to every existing byte-comparison.

Library note: `learning:01M07G8WT2R3G2P87EK1DNPVYP`.
