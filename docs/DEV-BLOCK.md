# Block devices in `/dev`

Status: LIVE in `MAUXPLAY.SYSTEM` (the play image), 2026-09-28 on.
`/dev/sNdM` is built (`src/kernel/procdev.s` the loader and /dev glue,
`kdevblk.s` the block I/O, in the kernel cold segment, docs/KSEG.md)
and gated by `make check-devblk`. `ls /dev` and `/dev/sNdM` listing
shipped later (docs/DEVFS.md); the loop device (docs/LOOP.md) also
appears as `/dev/s3d2` while an image is mounted. The scoping is by
module CHOICE, not conditional assembly: `procdev.s` is `put` only by
a manifest carrying the segment; `procdevs.s` (a stub) is `put` by
every other full-kernel manifest instead (nas has no `do`/`fin`
directive at all).

**Module-choice scoping -- ACCEPTED for this landing.** The segment
(and therefore `/dev/sNdM`) exists in MAUXPLAY.SYSTEM only; every
other one of the 27 kernel `.SYSTEM` images links `procdevs.s`'s stub
bodies instead of `procdev.s`'s real ones (the shared dispatch glue --
five `cmp`/`beq`/`jmp` sites plus the `PRC_DEVOPEN` hook -- is
unconditional, always-present bytes in every image; only the BODIES
differ by module choice). This is a deliberate, accepted scope
narrowing, not an oversight: widening it to another image is real
work (that image's own manifest needs its own `put procdev.s` in
place of `put procdevs.s`, plus its own `KSEG` file staged wherever
that image's build script puts things, plus a fresh headroom
measurement -- nothing here guarantees another image has MAUXPLAY's
margin). **Named trigger for widening it: another image needing
block devices** (or any other segment-only mechanism) -- until one
does, MAUXPLAY-only is the right scope, not a shortcut owed a
follow-up.

**A gate lesson kept from the landing:** `check-devblk` once timed out
because `scripts/check_devblk.py` read `screen_text()`'s `'merged'`
key; in native 40-column mode `'merged'` interleaves a blank AUX column
ahead of every MAIN character, so the bare-`$` prompt scan never
matched. The gate now reads `'main'`, as `check_dd.py` does. No kernel
code was wrong.

## What it is for

`nulib2 -a` cannot write an `.SDK` and nothing can archive a whole
volume, because there is no file that IS a volume
([NUFX.md](NUFX.md): "maux has no block devices in `/dev` to read a
volume FROM"). `dd` reads files, not disks. Every Unix has `/dev/sd0`;
this one has `/dev/tty1` and `/dev/null` and nothing that names a
disk.

## Library notes

- `learning:01M0W6RW48EWBVGDN3BF5G65TZ` -- ProDOS 8 block I/O from
  the outside: `DEVADR[unit_num >> 4]` in the global page, the
  `$42-$47` driver contract, `unit_num` is `DSSS0000`. The
  interposition design this note describes is NOT what we build; the
  encoding facts are.
- `learning:01KW1GTYH4NRG0F8M7AAT6EG9Z` -- **`DEVLST`'s byte is NOT
  the `unit_num`** (`$BF` vs `$B0`): mask with `$F0` before any MLI
  call. Bitten in practice.
- `learning:01M1B7W9Z76TMAKP7YPG63F7WQ` -- a driver may return with
  RAMRD/RAMWRT on aux (the /RAM driver does). Never `JSR` a driver
  vector from `$0200-$BFFF`; go through the MLI, which lives in the
  language card and puts the switches back.
- `learning:01M0SF1D98YX95Z5HPXJPN14FR` -- what a block-driver call
  looks like in a bus trace, for when a gate needs to prove one ran.
- ProDOS 8 TRM 4.7.1/4.7.2 (artifact `d82965d8...`): `READ_BLOCK $80`
  / `WRITE_BLOCK $81`, `param_count 3`, `unit_num`, `data_buffer`,
  `block_num`; errors `$27` I/O, `$28` no device.
- `learning:01M0PE538GF71R0GXYXHG3MB39` -- capacity is per-MEDIA, from
  a SmartPort `STATUS`, never fixed by the drive.

## The shape

**Names.** `/dev/sNdM` for slot N drive M -- the vocabulary a ProDOS
user already thinks in, and it maps to `unit_num` by arithmetic
(`(M-1) << 7 | N << 4`) with no table. Only units present in `DEVLST`
at boot are openable; anything else is "no such device", the same path
`/dev/ttya0` takes when no SSC was found (`procfile5.s`). /RAM is
never listed -- `PRC_RAMDIS` removed it and the annex lives there.

**Resolution.** Extend `PDEV_TAB`'s matcher in `procfile5.s` with one
patterned entry rather than sixteen literal ones: `S` digit `D` digit,
validated against `DEVLST`. The match returns a marker handle, not a
fixed fd.

**Per-open state.** A tty has no position; a disk does. So a block
device is an **OFT entry of a new type, `OFT_BLK`** (tag 4, after
`OFT_FILE`), carrying `unit_num` and a 24-bit byte position. Reads
and writes go through the MLI -- `READ_BLOCK`/`WRITE_BLOCK` at
`position / 512` -- and partial-block transfers bounce through one
512-byte buffer per open. `lseek` sets the position. Close frees the
slot. No io_buffer is lent or parked: block I/O has no ProDOS refnum.

**Size.** `SYS_FDSTAT` (call 11, `PRC_FDSTAT` in `procfd2.s`, whose
`FDST_*` results already tell a device from a file) on a block fd reports
the block count from the driver's `STATUS`, issued **through the
MLI's own device-call path, never a direct `JSR`** (library note 3).
A driver that reports no size reports zero, and `dd` then reads until
`$27`. State the rule; do not paper over the per-media caveat.

**What it does NOT do.** No write-protect policy beyond what the
driver returns. No caching. (`ls /dev` and `ls /` shipped later,
docs/DEVFS.md, 2026-09-30 -- the name table this section describes is
now also a listable synthetic directory, via `SYS_DEVLIST` rather than
by polling it.)

## Consumers, in order

1. `dd if=/dev/s7d1 of=/BASIC/VOL.IMG` -- the proof that it is a
   device: a whole-volume byte copy through the ordinary read path.
2. `nulib2 -a` learns `.SDK`: a record with `disk_volume` set and the
   thread class the format defines, fed from a block device. This is
   the payoff and it is a separate slice with its own gate.

## Gate

`check-devblk`: open `/dev/s7d1`, read block 2 (the volume directory)
and compare it byte-for-byte against `READ_BLOCK` issued by the gate
harness itself; `lseek` to block 0 and read the boot block; write a
block to a SCRATCH image mounted on a second unit and read it back;
`/dev/s3d2` (where /RAM would be) is "no such device" while no loop image is mounted; a partial read
that straddles a block boundary returns the right bytes. Teeth: break
the position arithmetic and the straddle case must go red; drop the
`$F0` mask and the open must fail with `$28`.

## Cost (the original estimate)

An `OFT_BLK` type touches `procfd*.s`, which every kernel image links.
`MAUXPLAY.SYSTEM` has 77 B of headroom after `bye`; the other images
have `KNOWN_OVERRUN` entries at their measured values. Expect a
baseline raise and say so in the commit, with the measured number.
