# `ls /` and `ls /dev`: the pseudo-root and the device space, listable

Status: SHIPPED, 2026-09-30. Operator: "should we make the pseudo-root
filesystem and the dev space listable?" -- then "do it". Gate:
`check-devfs`, in `check-all` (5/5 cases green). `SYS_DEVLIST` (no
device I/O, `/dev`'s full listing) and `SYS_ONLINE` (per-unit only,
unit_num 0 refused) landed per the operator's mid-task "never poll a
5.25-inch drive to list" ruling -- see docs/DEVFS-NOTES.md for the
full record, including the base SHA, the MAUXPLAY headroom accounting
(226 B against a 256 B floor, 30 B short, a pre-existing and
documented gap not fully closed by this slice), and three gate teeth
verified red-then-reverted. The actual `cd ..`-from-a-synthetic-root
fix lives in liba's `MKP_POP` (src/liba/mli.s), not the kernel's
`PRC_DOTDOT` this spec describes below -- `sh`'s `cd` builtin resolves
".." in userland (MKPATH) before the kernel ever sees a raw "..", so
the kernel-side mechanism below is kept as correct, low-cost
defense-in-depth for a future direct `SC_SETPFX` caller, not because
it is what actually runs today.

## Why

`ls /` is the first thing anyone types, and `ls /dev` is how a
stranger with the disk finds out the floppy is `s6d1`. Today both
fail: `/dev/*` names live in a match table (procfile5.s `PDEV_TAB`,
kdevblk.s `PDEV_TRY_BLK`), and ProDOS has no root -- the set of online
volumes is reachable only through `ON_LINE`. `cd /` and `cd /dev`
fail for the same reason (SET_PREFIX refuses them).

## What is true today (read before designing)

- `readdir()` at the kernel ABI IS ProDOS OPEN+READ of a directory's
  raw blocks (docs/SYSCALL.md item 7, ruling); the walk lives in
  liba: `src/liba/readdir.s` `OPENDIR`/`READDIR`/`CLOSEDIR` fill a
  caller-owned 32-byte record (`RD_LEN`, `RD_NAME` case-decoded,
  `RD_FTYPE`, `RD_STYPE`, ...). `ls` and `find` are its consumers.
- The kernel delegates MLI-shaped call numbers (>= `MLI_RANGE_LO`) to
  a fixed list in procfile.s (~38): CREATE/DESTROY/OPEN/READ/WRITE/
  CLOSE/RENAME/SET_FILE_INFO/SET_PREFIX/GET_PREFIX/GET_FILE_INFO/
  SET_MARK/GET_MARK/GET_EOF/SET_EOF. `ON_LINE` (`$C5`) is NOT on it.
  The kernel uses ON_LINE itself only in kbye.s via `PMLI_ONLN_CL`,
  which lives in procdev.s (the play family only).
- `cd` is `SYS_SETPFX`: procfile.s PRC_SETPFX resolves `..`, calls
  SET_PREFIX ("validates the directory exists, for free"), records
  the cwd per pid (PRC_CWD_STORE) and pins ProDOS's own prefix back
  to the boot value (PRC_PIN_BOOT). PRC_ABSPATH builds absolute paths
  from the per-pid cwd.
- ON_LINE with unit_num 0 fills a 256-byte buffer with one 16-byte
  entry per online unit: byte 0 = `DSSS` in the high nibble + name
  length in the low nibble, then the volume name; a unit whose volume
  cannot be read has length 0 and the ERROR CODE in byte 1 (`$52` not
  a ProDOS disk -- a DOS 3.3 floppy; `$28` no device) but STILL
  carries its slot/drive in the high nibble (TRM 4.4.6). So one call
  yields both listings: the volumes for `/`, the units for `/dev`.
- Memory: liba bytes are volume bytes (every gate image); MAUXPLAY has
  261 B of flat headroom (floor 256); the segment has ~1 KB.

## Library notes

- `learning:01KW1GTYH4NRG0F8M7AAT6EG9Z` -- DEVLST's byte is NOT
  ON_LINE's unit_num; `$F0` mask; /RAM's slot (3, drive 2) is absent
  by design.
- `learning:01M3EZBDRMT6MG9X54YM79W3K7` -- verilogapple: SmartPort
  units are slot 7, clean type nibble.
- `learning:01M1B7W9Z76TMAKP7YPG63F7WQ` -- ON_LINE's scan calls every
  driver; under the interrupt-enabled bracket that once wedged on an
  offline /RAM. The kernel's ON_LINE wrapper runs with the bracket
  every sibling uses; /RAM is disconnected at boot.
- `learning:01M3M0YPQBEE9KWG7R0CPRVNFF` -- block devices and the
  media size; `/dev/sNdM` semantics.
- ProDOS 8 TRM 4.4.6 ON_LINE (artifact `d82965d8...`): the entry
  format above; quote it in readdir.s where it is parsed.

## The design

**RULING (operator, 2026-09-30): never poll a 5.25" drive to list
anything.** `ON_LINE` with unit 0 polls EVERY device, and an empty
Disk ][ drive grinds and times out for seconds each time; `ls /` and
`ls /dev` must cost nothing on a machine with floppy drives. So the
device space comes from `DEVLST` (no I/O), and the root polls only
units that answer instantly. Floppy VOLUMES are not enumerated in
`/` at all: a floppy is addressed as `/dev/s6d1` or by its volume
name, which is how a period ProDOS user thinks of it too.

**Kernel, three small pieces (flat glue only; anything cold goes in
the segment where the manifest has one):**

1. `SYS_DEVLIST` (a maux call, below `MLI_RANGE_LO`): copies out
   `DEVCNT+1` bytes, one per `DEVLST` entry, each `DSSS` in the high
   nibble (the `$F0` mask applied, learning 01KW1GTYH4NRG0F8M7AAT6EG9Z)
   and bit 0 set when the unit's driver is the BUILT-IN DISK ][ -- the
   kernel classifies each `DEVADR` at the call: an address inside main
   LC bank 1 `$D000-$D5FF` is that driver (learning
   01M0W5ZCYJQH2A19V5XJW2HZR4); anything else (SmartPort `$Cn00`, a
   RAM disk, a third-party card) is "fast". No device is touched.
2. `SYS_ONLINE` (`$C5`) joins the delegate list, PER UNIT ONLY: the
   kernel refuses unit_num 0 (`ERR_INVAL`) so no caller can trigger
   the all-devices poll; copy in the 3-byte parmlist, run ON_LINE for
   that unit into `PMLI_XFER_BUF`, copy out its 16-byte entry.
   `PMLI_ONLN_CL` moves from procdev.s to procmli.s. Re-pin
   KNOWN_OVERRUN where it moves.
3. `PRC_SETPFX` admits exactly two synthetic directories: a path that
   canonicalises to `/` or `/dev` (7-bit, case-folded like PDEV_FOLD)
   skips SET_PREFIX and records the cwd as `/` or `/dev/` -- no
   ProDOS call, still PRC_PIN_BOOT. `PRC_DOTDOT` from a volume root
   (`/mnt/MAUX/`) yielded `/` (since 2026-10-10 the kernel has no
   `..` at all: liba's MKP_POP pops the virtual text, so it yields
   `/mnt/`, then `/`); from `/` stays `/`; from `/dev/` yields `/`. PRC_ABSPATH already concatenates cwd + relative, so `cd /dev;
   cat tty1` and `cd /; ls BASIC` fall out.
4. Nothing else: `open("/")`, `open("/dev")` keep failing as today;
   `stat` (GET_FILE_INFO) on `/dev/X` keeps failing -- the listing
   is readdir's, not the MLI's.

**liba `readdir.s`:** `OPENDIR` recognises `/` and `/DEV` (7-bit,
case-folded, optional trailing `/`) and switches the singleton into
SYNTHETIC mode. It calls `SYS_DEVLIST` once (a small liba `dum`
buffer; at most 14 bytes). For `/dev`: the fixed names first --
`tty`, `tty1`..`tty4`, `null`, `ttya0` (listed unconditionally like
the kernel's table; open decides presence) -- then `sNdM` for every
DEVLST entry, floppies included: no I/O has happened. For `/`: for
each DEVLST entry NOT flagged Disk ][, one `SYS_ONLINE` for that unit;
an entry whose length nibble is nonzero becomes a record with
`RD_NAME` = the volume name (case-decoded as ProDOS stores it),
`RD_FTYPE $0F`, `RD_STYPE $F`, sizes zero; a unit that answers with an
error (no disk, not ProDOS) is skipped; then one record `dev`,
`RD_FTYPE $0F`, `RD_STYPE $D`. Device records carry `RD_FTYPE $00` and
a storage-type marker ProDOS never emits: `RD_STYPE $B` block, `$A`
character -- declared in readdir.s beside the layout and nowhere
else. Names come back LOWERCASE (they are typed lowercase and they
are not ProDOS files). CLOSEDIR in synthetic mode closes nothing.
Quote TRM 4.4.6's entry format at the parse.

**`ls`:** prints `BLK`/`CHR` in the type column for `RD_STYPE $B/$A`
(lsprint.s's `TXTSTR`.. table gets two rows). `ls /dev/s6d1` -- an
operand that is a device, not a directory -- is synthesised as the one
entry it names rather than GET_FILE_INFO'd (which fails); `ls -l`
shows no size or date for a device.

**Docs/man:** `docs/man/ls.1` (the two synthetic directories),
`docs/DEV-BLOCK.md` ("No `ls /dev`" paragraph replaced), docs/CD.md
if it exists (the two admitted directories), PROJECT-STATE, README
gate list.

## Gate: `check-devfs`

Boots the play family with unit 1 (boot volume `BASIC`), unit 2 (a
second ProDOS volume, `SCRATCH`) and a DOS 3.3 floppy on slot 6
(build_floppy_image.py's machinery; the floppy fixture is
`fixtures/gem/XMASADV.SDK`'s image or any DOS disk), reads the screen
after each command:

1. `ls /` -> `BASIC SCRATCH dev` (DEVLST order, then `dev`) -- and
   NOT the floppy's volume, by the ruling; `ls -l /` shows the two as
   `DIR`. Measure the cycle count of `ls /` with the floppy mounted
   and assert it is the same order of magnitude as without it (no
   Disk ][ access happened: verilogapple's `disk2_state` motor/track
   counters must not move across the command).
2. `ls /dev` -> the fixed names, then `s6d1 s7d1 s7d2`; `s3d2`
   (where /RAM was) absent. `ls -l /dev` shows `BLK` for `sNdM`, `CHR`
   for the ttys and null.
3. `cd /dev; ls s6d1` -> `s6d1`; `cd /; cd mnt/MAUX; pwd` -> `/mnt/MAUX`;
   `cd /mnt/MAUX; cd ..; pwd` -> `/mnt` (was `/`; docs/VROOT.md); `cd /; ls` -> the root listing.
4. Reboot with the floppy NOT mounted: `ls /dev` no longer shows
   `s6d1` (it is DEVLST/ON_LINE-driven, not a table).
5. Negative: `cat /dev` and `cat /` fail with the same errno as today;
   `ls /nosuch` still fails.
Teeth: drop the Disk ][ flag test in the `/` walk and the floppy's
unit gets polled -- `disk2_state`'s motor/track counters move across
`ls /` (red); break the
case-fold in OPENDIR's match and `ls /DEV` must red while `ls /dev`
stays green; drop the `$F0`-style high-nibble read and `s6d1` must
vanish from `/dev`.

Cost to report: liba growth in bytes (x every image -- run `make
report-volumes`), MAUXPLAY headroom after, KNOWN_OVERRUN deltas.

## Not this slice

Reading a DOS 3.3 volume's catalog (no DOS filesystem in maux), a
`/dev` entry for the console's alternate screens, `mknod`.
