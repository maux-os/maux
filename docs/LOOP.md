# /dev/loop: a ProDOS FILE as a block device

Status: LIVE (slices S1-S4 landed 2026-10-11). Design A is built as
`src/kernel/loopseg.s`, gated by `make check-loop` (194 rows) and
`check-lseg`; user surface is `mount IMAGE` / `mount -r` / `umount`
(`docs/man/mount.1`). This document is the design and its evidence;
section 7 records where the build differs from it. Written 2026-10-08
from a deep-research pass (103 agents, primary sources, 3-vote
verification; journal wf_c7fca9e8-905) plus the commons and the tree.
Scope ruled by the operator: read-write; .po/.hdv and .2mg (header
honoured, read-only); visible to maux only.

## 1. Facts the design stands on (all verified against primary sources)

F1. **The driver contract** (TRM "Adding routines to ProDOS", TN #21,
`learning:01M0W6RW48EWBVGDN3BF5G65TZ`, ADTPro vdrive.asm): `$42` command
(0 STATUS, 1 READ, 2 WRITE, 3 FORMAT), `$43` unit (bit 7 drive, 6-4
slot, low nibble ignored), `$44/$45` buffer, `$46/$47` block. Success:
carry clear (STATUS also A=0, X/Y = block count). Failure: carry set,
A = `$27` I/O, `$28` no device, `$2B` write-protected. Entered with LC
bank 1 switched in. A loop driver returns STATUS's REAL count: maux's
SYS_FDSTAT reads it (VSDRIVE's $FFFF is the precedent NOT to copy).

F2. **Reaching the host unit** (TN #20/#21, ProDOS 2.0.3 XDOSMLI.S):
validate against DEVLST (`AND #$F0` the low nibble under 2.x), `LSR`
three times, `LDA DEVADR,X / DEVADR+1,X`. Never `$CnFF`-construct it:
2.x's MirrorDevEntry puts non-ROM vectors in the table. The tree
already has RD_DEVLST/RD_DEVCNT/RD_NODEV (inc/mm.hw.equ).

F3. **The MLI is single-threaded by mechanism** (2.0.3 mliCont sets
MLIACTV, one CMDADR cell, no check): a DEVADR driver cannot call the
MLI. **Only WRITE allocates blocks** (TRM: WRITE "allocates additional
data and index blocks"; SET_EOF upward "no blocks are allocated"; TN
#30: "write the 512 bytes of zeroes"). READ_BLOCK/WRITE_BLOCK are
disclaimed for applications but are what the tree already uses.

F4. **Attach/detach procedure** (TRM RAMIN/RAMOUT, TN #23): `SEI`;
store the vector in DEVADR; `INC DEVCNT`; insert the unit FIRST in
DEVLST (a user-installed driver "may assume it is still the last");
FORMAT. Detach: inverse plus ON_LINE on the removed unit (expect `$28`)
to free its VCB. 14 entries max; check room (the /RAM driver does not).
maux's PRC_RAMDIS already does the disconnect half (docs/DEV-BLOCK.md).

F5. **Index blocks** (TRM App. B): 256 low pointer bytes then 256 high
bytes; a tree's master index holds up to 128 index-block pointers; a
zero pointer is an unallocated (sparse) block; READ of a hole returns
zeros. A 140 KB .po is 280 blocks: every floppy image is a TREE with a
two-entry master index, not a sapling.

F6. **2IMG header** (CiderPress TwoImg.h/.cpp,
`learning:01KWKAKF76NENH0HC0MCB211RQ`): 64 bytes; magic `2IMG`,
creator, headerLen(2), version(2), imageFormat(4: 0 DOS, 1 ProDOS, 2
nibble), flags(4: bit 31 = byte `$13` bit 7 = locked; bit 8 = bits 0-7
hold a DOS volume number), numBlocks(4, format 1 only), dataOffset(4),
dataLen(4), comment/creator offset+len, 16 spare. Seek by dataOffset
(`$18`), never headerLen (52 in the original spec, 64 in the wild).
**Consequence the brief missed: with dataOffset = 64 every .2mg block
straddles two file blocks** (bytes 64-511 of block k, 0-63 of k+1), so
a .2mg loop cannot pass the caller's buffer through: a read is two host
reads plus a 448-byte move; a write is a two-block read-modify-write.

F7. **Prior art maps the file nowhere on the Apple II.** ADTPro VSDRIVE
(DEVADR driver, no MLI call) ships a 5-byte envelope to a PC that does
the mapping. MountIt (GS/OS, Brutal Deluxe 2024) reads the WHOLE image
into a memory handle at mount, serves blocks as memory copies, and
writes back only on an explicit menu command (eject discards). Both
solve re-entrancy by never touching the filesystem on the I/O path.
Nothing period or modern walks index blocks in a driver.

F8. **Tree facts** (docs/DEV-BLOCK.md, docs/KSEG.md,
`learning:01M1B7W9Z76TMAKP7YPG63F7WQ`): /dev/sNdM do ALL I/O through
the MLI's own device path; a driver vector is never JSRed from
`$0200-$BFFF` (a driver may return with RAMRD/RAMWRT pointed at aux);
/RAM is disconnected at boot and aux bank 0 is maux's annex; the cold
segment is bank 2 `$D400-$DFFF` with 79 B free; flat headroom 361 B.
Once a loop unit is in DEVLST it is automatically `/dev/sNdM` for dd
and nulib2 with no new fd code -- and its volume mounts like any other.

## 1a. What S0 measured (2026-10-08, docs/LOOP-S0-NOTES.md; all [fact] on
## verilogapple 296d93a unless graded otherwise)

M1. **The /RAM driver body is 155 bytes at `$FF00-$FF9A` in the main
    LC's COMMON page**, not bank 1; byte-identical in ProDOS 2.0.1,
    2.4 and 2.5; reached only via DEVADR slot 3 drive 2 ([fact] for
    the DEVADR path and 2.0.3's source, [likely] beyond an operand
    scan for 2.4/2.5). Under maux it is intact and dead. `bye`
    restores the VECTOR only (PRC_RAMRECONN, kbye.s), never the body.
    Commons: learning:01M4DA2FRQVZEX4RK2TA6MXT0T.
M2. **OPEN alone leaves the CURRENT level-2 index block in the upper
    512 B of the file buffer; the master is never there.** Index
    block NUMBERS are only in the undocumented FCB (+$0C key, +$0E
    current index). Seek + read 1 byte per 128 KB yields every index
    block's contents with no directory walk. Commons:
    learning:01M4DA50TWGNMSWQ72M6H1B5F4.
M3. **One SmartPort READ_BLOCK through the MLI is 4.3k cycles (2.4) /
    4.7k (2.5)**, 86%/82% inside the card firmware (the emulator's
    card answers in zero device time, so this is the CPU-side floor);
    the built-in Disk ][ is ~206k per sequential block (rotation).
    maux's own per-block OFT_BLK + dd path adds ~22.5k on top.
M4. **Neither host driver (SmartPort card model, built-in Disk ][)
    touches RAMRD/RAMWRT/ALTZP/80STORE or any `$C08x`**; both return
    with every switch as entered. The post-JSR restore is defensive.
    (The SmartPort half is a statement about verilogapple's model.)
M5. Side finding: `Makefile:3094` overrides PRODOSBIN to ProDOS 2.4, so
    every image boots 2.4 despite docs/PRODOS-VERSION.md's 2.5 ruling.
    Fixed separately (its own commit and sweep).

## 2. The designs, ranked

### A (recommended) -- "the index block IS the block map"

Observation no prior art uses: a ProDOS index block is already the
bmap a Unix loop driver computes, laid out for the 6502 -- low bytes
then high bytes, so `physical = (IDX_LO),Y : (IDX_HI),Y` with
`Y = loop_block & $FF`. No multiply, no table build, no map memory
beyond the filesystem's own.

- Cache, sized for TREES (operator 2026-10-08: a loopback image is a
  tree by construction -- 280 blocks already exceeds a sapling; the
  seedling/sapling cases are not worth a branch): three 512-byte
  blocks in the annex (aux bank 0). (1) The master index, always
  resident. (2) Index block 0, PINNED: every ProDOS volume's boot
  blocks, directory (blocks 2-5) and bitmap (from 6) sit under it, so
  any metadata touch maps without a miss. (3) ONE LRU slot for the
  data region, tagged by `loop_block >> 8`. Without the pin, a `cp`
  into the volume alternates directory writes (index 0) with data
  writes (index k) and would miss on every flip; with it, the
  alternation is free and a miss is ONE extra host read, once per
  128 KB of sequential data. 1.5 KB, not 1 KB.
- READ/WRITE: tag check; two indexed loads; `$43` := host unit, `$46/
  $47` := physical block, `$44/$45` passes through UNTOUCHED (zero-copy
  for .po/.hdv); JSR the host DEVADR (cached at attach) from LC-
  resident code; restore RAMRD/RAMWRT and `$43/$46/$47`; return the
  host's carry/A. Zero pointer: `$27` (stricter than zero-fill; relax
  only when a gate shows a use). Locked unit or `-r`: `$2B` before
  touching the host. STATUS: the real block count.
- Cost: ~300-400 driver bytes, 16 B per unit, 1.5 KB annex cache; a
  hit adds tens of cycles to the host's own transfer; a miss adds one
  host block read. A volume larger than 32 MB (master index full,
  128 index blocks) is ProDOS's own limit, so the master never spills.

### A' -- WHERE A LIVES (revised after S0)

The driver must execute under ProDOS's BANK 1 (the host vectors are
bank-1 or common code) and flat main code may not JSR a driver. S0
settled the candidates:

1. **The 155 B at `$FF00-$FF9A` (M1) hold A's HOT PATH, not the whole
   driver.** Hot path = unit check, tag compare, two indexed loads
   from the annex (RAMRD on/off around them -- LC code fetch is not
   RAMRD-governed), swap `$43/$46/$47`, JSR the cached host vector,
   restore `$43/$46/$47`, return the host's carry/A. M4 removes the
   switch-restore bytes. Budget it at <= 155 B with the error exits.
   The MISS path (fetch index block k from the host into the annex
   slot: borrow the caller's buffer for the host read, then copy
   512 B main -> aux, ~9.2k cycles, once per 128 KB) and attach/
   detach live in the flat kernel (361 B headroom; the miss path is
   ~100 B) and are reached from the hot path by a JSR -- flat code
   never JSRs the host itself. The unit is slot 3 drive 2 (`$B0`,
   DEVADR[$B], a real table entry on 2.4 and 2.5).
2. S4's restore has a named hook: PRC_RAMRECONN must copy the 155-byte
   constant back to `$FF00` (identical in every vendored version; from
   PRODOS file offset `$0D00` or a table) BEFORE a tenant runs, and
   PRC_RAMREDISC re-installs the loop hot path after. Detach the loop
   unit first.
3. The LC common region elsewhere and a `$C083` flip into bank 2 are
   both out: the former has no measured gap, the latter cannot JSR a
   bank-1 host and the segment is 79 B from full regardless.

Attach (M2): `losetup` reads every index block's CONTENTS by seek +
1-byte reads (no walker) to count holes and densify; for the block
NUMBERS the driver's cache needs, it reads the master through
READ_BLOCK(key_block) with key_block from a directory walk from block
2 (contract-clean; the readdir code exists) -- the FCB shortcut is
noted and declined, it is an implementation detail.

Cost picture (M3): a hit adds tens of cycles to a 4.3k-cycle host
read that maux already wraps in ~22.5k of its own; a miss adds one
host read + a 9.2k copy once per 128 KB. The .2mg straddle (two reads
+ 448-byte move, ~10k) is why .2mg stays read-only in v1.

### B -- zero-cache read-only loop (byte-minimal)

Same pass-through, NO cache: read the master index, then the index
block, INTO THE CALLER'S OWN BUFFER, extract the two pointer bytes to
ZP, then issue the data read over the same buffer. 3 host reads per
block on every image (all trees, F5), ~150-200 B, 16 B per unit.
Read-only by construction (the caller's buffer is the scratch space),
which is also the right answer for a locked .2mg. Novel in the same
way A is; ranked second because 3x the I/O of A for every image that
matters.

### C -- MountIt-style RAM-banked loop

Attach reads the whole image into spare RamWorks banks (128 blocks per
bank); the driver serves by `$C073` select plus a 512-byte copy
(~9.2k cycles at 18 cycles/byte); write-back on detach with a dirty
bitmap (an improvement on MountIt, which flushes only by menu and
discards on eject). Fastest per block and immune to the .2mg straddle,
but every bank is one fewer process, the Zip Chip tag caps the machine
at 32 banks, and a crash loses every unflushed write. Ranked third: it
is what the prior art shipped, not the novel one; keep for a future
tmpfs.

## 3. Sparse holes and write-protect (policy for A)

`losetup FILE` is an ordinary MLI client: walk the master index and
index blocks over READ_BLOCK (<= 1 + 128 reads even for a 16 MB
tree), count zero pointers below EOF; if none, attach read-write; if
holes and no `-r`, densify by SET_MARK + WRITE of 512 zero bytes per
hole (TN #30; WRITE is the only allocator; ProDOS 8 never
re-sparsifies written zeros), re-walk, attach; if the 2IMG lock bit or
`-r`, attach read-only, no densify. The driver never allocates.
Images written sequentially (a2til mirror, CiderPress, nulib2 -x) are
dense in practice; host-staged BSS objects are the known sparse case
(`learning:01M2QVZG4RVTNB8RJZHF33DBJP` -- rewriting one killed ProDOS,
attribution open, so densify BEFORE attaching, never write through a
hole).

## 4. .2mg policy

Format 1 only (refuse 2; optionally reorder a 280-block format 0);
honour `$13` bit 7 as `$2B`; seek by dataOffset. Because of the
straddle (F6): v1 serves .2mg READ-ONLY through a 64-byte stash path
(two host reads, one 448-byte move) and documents "convert to .po for
read-write" (a2til does it on the host; a maux `2mg2po` is a trivial
dd with skip=64 once dd takes byte offsets). Read-write .2mg is not
worth a 2-block read-modify-write per block.

## 5. Open questions -- each with the measurement that settles it

Q1. ANSWERED (M1): 155 B at $FF00, common page; hot path only. Still
    open: prove nothing reads $FF00-$FF9A at runtime on 2.4/2.5 with a
    windowed trace_capture over a long workload (trigger: S1).
Q2. ANSWERED (M2): contents yes (current level-2 block, never the
    master); numbers need the directory walk or the FCB.
Q3. ANSWERED on the emulator (M3); real hardware still open (trigger:
    S1 shipping a driver whose ranking depends on it).
Q4. ANSWERED (M4): defensive for both; MAME/hardware confirmation of
    the SmartPort half is still open (same trigger).

## 6. Slice plan (all four slices landed; see section 7)

S0. DONE 2026-10-08 (docs/LOOP-S0-NOTES.md, scripts/measure_loop_*.py).
S1. `losetup` attach/detach tool (built as `mount`/`umount`, see sec 7) + the driver for .po/.hdv read-write,
    design A in home A' (or 2), unit at slot 3 drive 2; gates: mount an
    image, ls/cat/cp into it, dd the loop device, nulib2 -a of it, dirty
    data visible on the host via a2til; disk2_state proves no floppy
    poll; sabotage per gate.
S2. .2mg read-only via the stash path; lock bit -> `$2B`.
S3. Sparse policy in losetup (densify, -r), with a host-staged sparse
    fixture that MUST fail to attach read-write without densify.
S4. bye interplay: the loop detached and ProDOS's body restored before
    a tenant runs; reattached after.

Headroom: the hot path is the 155 common-page bytes; the miss path,
attach/detach and the bye hooks are flat (~150-200 B of the 361 B);
the attach tool is userland. Budget the flat part first.

## 7. As built -- where the code differs from the design above

Verified against `src/kernel/loopseg.s`, `docs/man/mount.1` and
`scripts/check_loop.py`. The design's mechanism (the index block IS the
block map, zero-copy pass-through to the host DEVADR vector, pinned
index block 0, one LRU slot) is what shipped; these points moved:

- **There is no `losetup`.** `mount IMAGE` attaches and `umount`
  detaches (both go through `SYS_VROOT` ops 4 and 5, docs/VROOT.md).
  The unit is fixed at `$B0` (slot 3 drive 2, `/dev/s3d2`), one image
  at a time; a second mount, or an image living inside the loop, is
  refused `busy`.
- **Home is a play-only low segment, not the 155 B common page.** The
  driver, cache, attach and detach live in LSEG (`$1300-$1FFF`, loaded
  by KSEG_LOAD beside KSEG): ordinary main-RAM code that may call the
  flat MLI wrappers. `$FF00` holds only a 13-byte host-call
  trampoline (the one instruction that must run from the LC after the
  host returns is the one that turns RAMRD/RAMWRT off). Cost: 0 flat
  kernel bytes for S2-S4.
- **The cache is in main RAM, not the annex.** The master index and
  index block 0 are resident and one 512 B slot (`LP_SLOT`, `$1E00`)
  holds the data-region index block, tagged by `loop_block >> 8`, as
  designed -- but in LSEG, not aux bank 0.
- **A hole is handled by policy, not by the driver.** `mount`
  densifies a sparse image first ("densified N blocks"); under `-r`
  holes read as zeros and nothing is written. The driver itself never
  allocates.
- **Write-failure hazard found by S2a:** ProDOS 2.4's dirty
  volume-bitmap buffer (bmaStat `$FE99`, owner bmaDev `$FE9A`) is
  discarded when a WRITE through the loop fails and again at detach;
  attach verifies 2.4's UpdateBitMap bytes and refuses any other
  ProDOS; `umount` reports "N blocks were not written" and exits 1.
- **.2mg is read-only** (ProDOS order, dataOffset 1-64) through the
  two-read stash path; measured 18,022 cycles a request against 4,067
  for a .po. Lock bit and `-r` give `$2B`.
- **`bye` interplay (S4):** `bye` detaches the loop before the /RAM
  vector and body are restored, and the `bye` tool re-attaches the
  same image afterwards or says why not; it does not refuse.
- Design B and C were not built; C remains the idea for a future tmpfs.
