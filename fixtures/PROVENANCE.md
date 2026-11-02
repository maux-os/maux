# Fixture provenance: real archives from the wild

These are REAL NuFX archives fetched from public Apple II archives,
committed here byte-for-byte (they are not generated; HACKING.md's
"never commit generated disk images" rule is about build products).
Each is what a stranger actually downloads. Sizes, sources, and the
sha256 of the committed bytes are below; `docs/UNPACK-E2E.md` is the
gate that consumes them.

## fixtures/gem/ -- the GEM CD (Generous Efforts of Many), 1990

Internet Archive item `cdrom-gem-apple2`, file `gemcd.zip`
(89,837,911 B), which holds six 32 MB ProDOS volumes `GEM.CD.A.po`
.. `GEM.CD.F.po` (each 65,536 blocks; ProDOS's own header says 65,535,
so a2til refuses them until truncated by one block). Extracted with
a2til `Volume.read_file` on 2026-09-29. The CD's own archive
information text: "a compilation of software for the Apple // and
IIGS ... collected ... from the public domain libraries of various
user groups ... Some of the programs on this CD are classified as
shareware". Both records below are P8 ShrinkIt disk archives
(`thread_format $0002`, LZW/1), 280-block 5.25" images stored in
ProDOS block order, as every ShrinkIt disk archive is.

- `XMASADV.SDK` (was `GEM.CD.A:/Features/Xmas.Adv.Sdk`, 88,203 B;
  **gate fixture only -- NOT on the public release disk**: no
  distribution terms are recorded for it, so `build_full_image.py` does
  not stage it. DEMOPROG and the two asimov freeware archives do ship):
  record `CHRISTMAS.ADV`, a DOS 3.3 disk (boot sector `01 A5`). Booted
  under verilogapple from the nibblized image on 2026-09-29: its first
  screen is `SKIP THE INTRODUCTION? (YES OR NO)`.
- `DEMOPROG.SDK` (was `GEM.CD.A:/Features/Circ.Plus/Demo.Prog.Sdk`,
  82,013 B): record `DEMO.PROGRAM`, a ProDOS volume of the same name
  (a demonstration version, "freely distributable" per the CD notes).
  Boots into an 80-column program under verilogapple. The disk says so
  itself: its intro program (Applesoft, on the volume) prints
  "COPYABLE Demonstration Package" and "FREE DISTRIBUTION Encouraged",
  "Copyright  1986", "Follett Software Company" (Circulation Plus 6.2,
  Follett Library Software; strings read off the extracted image on
  2026-10-20). The archive itself is dated 02-Apr-90 (a2til
  `disk_record.archived`).

## fixtures/asimov/ -- ftp.apple.asimov.net/images/disk_utils

Mirror `https://mirrors.apple2.org.za/ftp.apple.asimov.net/images/
disk_utils/`, fetched 2026-09-29. Freeware utilities with their own
README/DOC members; both verify clean under a2til and host `nulib2 -i`.

- `VBLSET.SHK` (was `VBL_SetTime.SHK`, 5,277 B): five records dated
  1990, a MIX of LZW/1 (`lz1`) and stored (`unc`) threads -- exactly
  the per-thread format mixing a reader must handle.
  Author: Doug Reeder. VBL.CLOCK.DOC in the archive says "Copyright
  1989,1990 by Doug Reeder.  Free for non-commercial purposes."
  (SET.TIME.DOC: "Copyright 1990 by Doug Reeder"). The film's caption
  names him and 1990, the dating of the records.
- `SLOTSCAN.SHK` (was `Slotscan162.shk`, 13,025 B): three records
  dated 1994, LZW/2 (`lz2`), including a `.SYSTEM` (SYS $2000) and an
  icon file of type $CA.

Names were folded to ProDOS-legal 8.3 uppercase so the same name is
staged on the machine unchanged.

## sha256 of the committed bytes

- `fixtures/asimov/SLOTSCAN.SHK` sha256 `7dd0406e387dc1f7d0aab9d357a2a08407db4320ef042deed28867e2edf115b0`
- `fixtures/asimov/VBLSET.SHK` sha256 `fbd1b69d1d271540e49e8e00bf83f6bef912c0201411cf8e4f6cc0adcf9b7c8d`
- `fixtures/gem/DEMOPROG.SDK` sha256 `a895a8f3e5e1f139004fa54de393a41e3ab4bfbd6be8f13ad8a4bbe8aaaf93d0`
- `fixtures/gem/XMASADV.SDK` sha256 `f8b6db0768ca886970c69ec23131752e1505d6b82242af8d9f1434ce07e2fcf2`
