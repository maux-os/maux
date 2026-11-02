# NuFX on the machine: `nulib2`

Status: EIGHT SLICES SHIPPED, 2026-09-28. maux both READS and WRITES
NuFX. `-t`/`-v` list, `-x`/`-p` extract and `-i` verifies stored,
LZW/1 (ProDOS 8 ShrinkIt) and LZW/2 (GS/ShrinkIt) threads -- between
them every archive either ShrinkIt produced -- and `.BXY` is stepped
over without a flag. `-a` writes an archive, compressed with a real
LZW/2 encoder, and now writes a `.SDK` (a disk image inside an
archive) when the archive's own name ends that way, fed from a plain
file or straight from a `/dev/sNdM` block device.

What remains: whole-VOLUME archiving (a directory tree packed as
several records, as opposed to one `.SDK` holding one image), `-d`
(adding to an existing archive), and the codecs no ShrinkIt ever
wrote, which are out of scope rather than missing -- see below.

## Why

A stranger boots maux, and the Apple II software they want is in a `.SHK`.
Every archive on every Apple II site is NuFX. Before this, maux had **no
archive tool at all** -- `ar`, `compress` and `uncompress` are man stubs,
and a grep of `src/` for `nufx|shrinkit|lzw` returned only `tr -s`'s
"squeeze" comments. So the disk was a development system you could not get
software onto except through the host, which contradicts what maux is for
(`maux-is-a-dev-tool-for-aficionados`: a stranger with the disk is the user).

## What already exists, and what this is NOT

**a2til reads and writes NuFX completely, on the host.** Every codec
(Squeeze, LZW/1, LZW/2, LZC-12/16, Deflate, BZip2) on the read side; LZW/2
and stored on the write side; cross-checked byte-for-byte against NuLib2;
`.shk`/`.bxy`/`.sdk` all open as ordinary images. `a2til ls game.shk` works
today and a `.sdk` unwraps to the volume inside it.

So this is **not** a host tool and must not duplicate one. The gap is
strictly on the machine: maux itself cannot open an archive.

## Language: assembly, and the reason is the table

`nas` is PLASMA, so PLASMA is the obvious reach. It is the wrong one here,
and one number settles it:

- The promoted NAS design has **12,069 initial heap bytes**
  (docs/PLASMA-PERFORMANCE-GUIDE.md).
- A 12-bit LZW table is 4096 entries of {prefix u16, suffix u8} = **12,288
  bytes**.

The table alone does not fit in the heap a large PLASMA program has left,
before any I/O buffer. In assembly the table is a `dum` arena in the
process bank's own free span above the code, where ~40 KB is available, and
the decode loop is a tight byte loop of exactly the kind assembly is for.

## The format, from the commons

Both handles are load-bearing and were read in full before this was written.

`learning:01M0KZQJTHDP01FKPNP1HTWDW7` -- NuFX's five CRC conventions and the
traps that desync a reader. The ones that shape this design:

- **CRC-16/XMODEM**, poly `$1021`, MSB-first, no final xor. Five uses, three
  seeds, different covered ranges. `master_crc` and `header_crc` seed
  `$0000`; a **v3** `thread_crc` seeds `$FFFF` over the **uncompressed**
  data; LZW/1's own embedded CRC seeds `$0000` over data **zero-padded to
  the 4 KB chunk boundary**.
- **`thread_eof` is the USED length, `comp_thread_eof` the ALLOCATED one,
  and they differ in practice.** Seek by `comp_thread_eof`, read by
  `thread_eof`. A stock `nulib2 -a` archive holds a filename thread with
  `eof=9, comp=32` and a zero-length comment thread with `eof=0, comp=200`.
  Getting this backwards misaligns every payload after it.
- **`attrib_count` is the authority for the header tail.** `filename_length`
  sits at `attrib_count - 2`, never at a fixed offset, because a v1+ GS/OS
  option list of variable length sits in between. Thread records begin at
  `attrib_count + filename_length`.
- **`file_sys_id` is not reliable** -- nulib2 writes `$0000` while
  separating with `:`. The separator is the **low byte of `file_sys_info`**.
- **Compression is per THREAD.** NufxLib falls back to stored whenever
  compression would expand a thread, so one archive mixes formats and a
  reader must handle that. This is what makes slice 2 genuinely useful on
  real archives rather than only on ones we made.
- **LZW/1 resets its table every 4 KB chunk** and its decode stack stays
  under 100 bytes. **LZW/2 persists the table across chunks** and needs a
  4 KB stack. That is the whole reason LZW/1 is the first fence.
- ProDOS 8 ShrinkIt emits **v1 records with LZW/1**; GS/ShrinkIt emits **v3
  with LZW/2**. Both read either.

`learning:01M0M67H5Y79780K1KY69W8PTN` -- NufxLib's RLE **encoder** corrupts
runs of its own escape byte `$DB` when the run length `% 256` is 1-3. The
**decoder is correct**, so a reader inherits nothing from this; it matters
only as a warning that some archives in the wild are already corrupt on
disk and `nulib2 -i` will not say so, because the thread CRC covers what
the decoder produces. We verify against the original file, never against
the archive's own checksum.

Constants, from a2til's verified reader (`~/src/a2til/a2til/nufx.py`):

    MASTER_ID   4E F5 46 E9 6C E5   "NuFile" with alternating high bits
    RECORD_ID   4E F5 46 D8         "NuFX"   likewise
    MASTER_SIZE 48      RECORD_MIN 58      THREAD_SIZE 16
    BINARY2     128-byte header in front of the NuFX data in a .BXY

    thread_class  0 message, 1 control, 2 data, 3 filename
    thread_kind   in class 2: 0 data fork, 1 disk image, 2 resource fork
    thread_format 0 stored, 1 Squeeze, 2 LZW/1, 3 LZW/2, 4 LZC-12,
                  5 LZC-16, 6 deflate, 7 bzip2, 8 ZX0  (6-8 are NufxLib
                  extensions, not ShrinkIt)

## Slices

Each lands with its own gate and its own teeth proof.

1. **`nulib2 -t` -- list. SHIPPED `9e49762`.** Master header, `master_crc`,
   record walk, `header_crc`, filename thread, type/aux/size per record.
   No decompression at all. Exercises every offset trap above, which is
   where a reader actually breaks, and is useful on its own: a stranger
   can see what is in the archive.
2. **`nulib2 -x` -- extract stored threads** (`thread_format $0000`).
   **SHIPPED.** Writes real ProDOS files carrying the record's own type
   and aux. Every NuFX reader accepts stored threads and NufxLib emits
   them whenever compression would expand one, so this gets real files
   out of real archives.
3. **LZW/1** (`$0002`) -- **SHIPPED.** RLE-then-LZW per 4 KB chunk,
   table reset each chunk, <100-byte decode stack. The P8 ShrinkIt
   case.
4. **LZW/2** (`$0003`) -- **SHIPPED.** Persistent table, explicit clear
   code `$100`, 4 KB stack, and NufxLib's `resetFix` workaround for a
   chunk that ends one character after a clear. The GS/ShrinkIt case.
5. **`nulib2 -a` -- write an archive. SHIPPED.** Master header, one v3
   record per file with its ProDOS type/aux/access and mod date, a
   filename thread and a data thread. Stored, two passes per input.
6. **Compression, stage 1: run-length only. SHIPPED.** Each fork goes
   out as an LZW/2 thread with the LZW flag CLEAR -- see below.
7. **Compression, stage 2: the LZW encoder. SHIPPED.** A real LZW/2
   writer: 4096-entry table, 9-to-12-bit codes, clear on full, and
   per-chunk choice between LZW, run-length and stored.
8. **`.SDK` -- a disk image inside an archive. SHIPPED.** `nulib2 -a
   NAME.SDK IMAGE` archives a whole disk image as a disk-class thread
   (file_type $00, extra_type the block count, storage_type $0200),
   fed from a plain file or a `/dev/sNdM` block device. Reuses the
   LZW/2 writer unchanged except the stream header's `disk_volume`
   byte.

## The remaining codecs are OUT OF SCOPE, not a gap

Worth stating plainly, because a list of unimplemented format numbers
reads like a hole and this one is not. From McFadden's Lesson 9
([[01M31QSJ9K6V389DEVKMW9CBTK]]), what each program actually PACKED
with:

    P8 ShrinkIt    LZW/1      GS/ShrinkIt   LZW/2
    ShrinkIt ][+   LZW/1      NuLib         LZW/1
    YankIt         nothing

**No ShrinkIt ever wrote anything but LZW/1 and LZW/2, and nulib2
expands both.** So it reads every archive any Apple II program could
produce. The other thread formats came from elsewhere and were never
readable on an Apple II:

- **LZC-12/16** (`$0004`/`$0005`) is UNIX compress, and it was NuLib
  that put it into NuFX archives. Lesson 9 on what that means: "yes
  Virginia, you can have files packed with UNIX compress in a ShrinkIt
  archive... you just can't unpack them with anything else." A file
  only the Unix box that wrote it can read, inside an Apple II archive
  format, is not something a //e tool owes anybody.
- **Squeeze** (`$0001`) is the Huffman+RLE of the Binary II era, BLU's
  `.QQ` -- it predates NuFX rather than living inside it.
- **deflate, bzip2, ZX0** (`$0006`-`$0008`) are NufxLib's own
  extensions, and `nulib2 -h` says outright they "can't be unpacked on
  an Apple II".

Genuinely still open, and a different thing from the above: `.SDK`
(a disk image inside an archive), `-d`, adding to an existing archive,
and compressing on the way out. If compression ever lands, **LZW/2 is
the one that matters** -- it is what GS/ShrinkIt writes; LZW/1 would
only be for imitating a P8 ShrinkIt.

## What slice 2 settled that the design did not anticipate

- **The two MLI parameter blocks do not share a layout.**
  `GET_FILE_INFO` returns `storage_type` and `blocks_used` where
  `SET_FILE_INFO` wants three null bytes, so the read-modify-write has
  to copy field by field. A block copy writes a block count into the
  reserved field. `chtyp.s` and `chmod.s` both already do it the long
  way; that is why.
- **`CREAT` makes an unlocked TXT seedling**, which is right for
  `creat(2)` and wrong for an extracted file. The type and aux have to
  be stamped afterwards -- and on ProDOS that is not cosmetic: the type
  is where "can this be run?" lives and maux's `spawn` loads a binary
  AT ITS AUX.
- **A thread CRC is only meaningful on a v3 record.** A v1 record --
  what ProDOS 8 ShrinkIt writes -- keeps its checksum inside the LZW/1
  stream, so testing at thread level would report every P8 archive as
  damaged. `CRCVERIFY` gates on the record version.
- **A fixture of one TXT file cannot test the stamp**, because TXT is
  what `CREAT` leaves anyway. The gate's three records are TXT, BIN
  ($06/$2000) and REL ($F8) precisely so the assertion can fail; with
  `STAMP` removed, `AAA.TXT` still passes and the other two do not.
- **Every split file must be in the make dependency.** `nulib2ext.s`
  was left off, so a sabotage run measured the STALE binary and the
  gate passed -- the one way a teeth proof lies. Caught only because
  the binary's SIZE had not changed.

## What slice 3 settled

- **The two CRCs are different conventions over different bytes, and
  one buffer cannot hold both.** The chunk CRC seeds `$0000` over every
  chunk's full 4096 bytes INCLUDING the final chunk's zero padding; the
  thread CRC seeds `$FFFF` over only the bytes written. The first
  implementation reused one accumulator and the thread CRC came out
  wrong while every byte of output was correct -- exactly the shape the
  format's own note warns about.
- **A gate fixture for LZW/1 cannot be generated by the house tools.**
  a2til reads every codec and writes only LZW/2 and stored, and writing
  an encoder in the gate would test the decoder against a second
  implementation by the same author on the same day. The fixture is
  therefore RECORDED bytes from NufxLib's own `launder -m lzw1`, with
  a2til -- a third implementation -- decoding them at gate time to say
  what the answer is.
- **The fixture has to be chosen to reach the code.** 9,260 bytes is
  three chunks with a partial last one, so the zero padding and the
  stream CRC over it are exercised; 3,000 identical bytes force the RLE
  layer; repeated text fills the table so the code width grows past 9
  bits. A small file reaches none of that.

## What slice 4 settled

- **`nas` does not implement `ds \`**, Merlin's page-align. The LZW
  table was aligned with it so a code could index the arrays by adding
  only its high byte; merlin32 was happy and the binary was correct,
  and the unit simply could not be built by the machine's own
  assembler. `check-nas-librel` is the only gate that would ever have
  said so.
- **The fixture threshold is measurable, and the commons was right.**
  The same generator clears LZW/2's table ZERO times at 16,000, 20,000
  and 24,000 bytes, and once at 30,000. Every fixture below that tests
  a decoder that cannot see the format's defining feature.
- **LZW/2 inherits its table only across COMPRESSED chunks.** A stored
  or RLE-only chunk resets it. Sabotaging the inheritance the other way
  -- clearing at every chunk, as LZW/1 does -- fails at chunk 1; not
  handling the clear code fails at chunk 6, which is exactly where the
  fixture's clear sits.
- **The two formats disagree about where integrity lives.** LZW/1 has a
  stream CRC over every padded chunk and declares nothing per chunk;
  LZW/2 has no stream CRC and instead declares each chunk's compressed
  length, which the decoder must consume exactly. Both are checked.

## The name is nulib2's too

2026-09-21, after the operator asked to make up my mind. The tool
implements nulib2's interface, is verified against nulib2's binary, and
nulib2 is the maintained reference -- so it is called `nulib2`. GNO/ME
shipped the ORIGINAL NuLib, whose syntax is tar-style (`nulib tv
archive`); that is a coherent thing to build, but it is not this, and
calling this `nulib` while it spoke nulib2 was the same drift as the
`-t`/`-v` swap below, one level up.

## What of nulib2 this covers

    -t   table of contents, bare names        DONE
    -v   verbose listing                      DONE (maux columns)
    -x   extract into the current directory   DONE
    -p   extract to standard output           DONE
    -i   test integrity, write nothing        DONE
    .BXY Binary II wrapper                    DONE (detected, no flag)
    -a   create an archive holding named files  DONE (stored)
    -d   delete         not implemented
    -b   force Binary II -- exists in nulib2 because it can read an
         archive from stdin and cannot seek back over the wrapper.
         This always has a file, so it looks; the flag would switch
         nothing.
    modifiers -r -u -f -j -c -l -ll -s -e -ee, and stdin archives:
         not implemented.

Two deliberate differences in `-i`. nulib2 prints per-record progress
and, on damage, ASKS "Archive may be damaged, continue anyway? [y]es,
[n]o" -- a tool that blocks on input cannot be used in a pipeline. This
one is silent on success, names the record on failure, and never
prompts.

## The verb letters are nulib2's, and mean what nulib2 means

Checked against the installed binary rather than assumed, 2026-09-21,
after the operator asked whether the switches matched Andy's -- and
they did not. The listing had been written under `-t`, which is
nulib2's `-v`:

    nulib2 -t   "quick dump of table of contents ... the filenames,
                one per line, without any truncation or embellishment.
                Useful for feeding into another program."
    nulib2 -v   "verbose listing ... multi-column format with summary
                totals. The output is similar to what ShrinkIt
                produces."

So `nulib2 -t` now prints bare names -- byte-identical to `nulib2 -t` on
the same archive -- and the decorated listing moved to `-v`. The COLUMNS
`-v` prints are still maux's own, following `ls -l`'s discipline rather
than ShrinkIt's wider one; what is borrowed is the letter's meaning, not
its layout.

A test that only looked at one of the two could never have caught this,
which is why the gate now checks both.

Deliberately not implemented from nulib2: `-a`, `-d`, `-p`, `-i`,
reading an archive from stdin, the Binary II container (`-b`), and every
modifier letter.

## A comment that claimed a gate, and the bug it then failed to catch

The three LISTARC diagnostics were addressed by their LOW byte only,
with the high byte taken from the first of them -- on the assumption
that they shared a page. The source said so, and added that "the gate
plants a long string here and requires the build to notice". No such
gate was ever written.

Renaming the program from `nulib` to `nulib2` added one character to
each message and pushed two of the three onto the next page. `nulib2 -t`
on a file that is not an archive printed two bytes of garbage. XWARN
carried the same trick over six more messages.

It surfaced only because a SABOTAGE run printed `['M', '*p']` where it
should have printed a diagnosis -- the sabotage was aimed at something
else entirely, and the wrong-looking output was the tell.

Both now pass the whole pointer, four bytes a site, and check-nulib2
exercises the path the comment claimed was covered. A comment asserting
a test is not a test, and it is worse than silence: it stops the next
person looking.

## Writing: what slice 5 settled

- **`GET_FILE_INFO` does not give you a length.** It returns
  `blocks_used`, and `ls.s`'s own header says so outright -- "printing
  blocks_used*512 as if it were EOF would be WRONG". The first version
  took those bytes as the length anyway, under a comment asserting the
  opposite, and every data thread claimed a size of blocks_used with a
  stray date byte on top. `LSEEK(fd, 0, SEEK_END)` reports where it
  landed, which is how you ask an open ProDOS file how long it is.
- **A v3 record forces TWO passes over every input.** The data
  thread's CRC covers the plaintext and sits INSIDE the record header,
  which `header_crc` covers in turn -- so it cannot be patched in after
  the payload is written. Read once to checksum, once to copy.
- **a2til is not an oracle for a stored thread's CRC**, because it does
  not verify one. Seeding the written CRC `$0000` instead of `$FFFF`
  changed nothing it reported. The gate computes the checksum itself
  now. A reader that does not check a field cannot be the oracle for
  that field.
- **A timeout reported as "tool not installed" hides a rejection.** The
  gate skipped `nulib2 -i` on `FileNotFoundError` OR `TimeoutExpired`;
  under the sabotage NufxLib hung on the malformed archive and the gate
  printed "not installed" -- having verified it minutes earlier.

## Writing compressed: what stage 1 settled

- **An RLE-only thread is a FULLY VALID LZW/2 thread, and LZW/2 is
  the easier target of the two.** Each chunk carries a flag byte
  saying whether the LZW layer is on; writing it clear is a legal
  chunk, not a private extension, and a reader that handles LZW/2 at
  all handles one whose chunks never turn LZW on. LZW/2 is easier
  than LZW/1 to WRITE for two reasons that both cut the other way
  from reading: it has no stream-level CRC to fold, and its extra
  per-chunk length word only appears when the LZW flag is SET. So
  the RLE-only writer emits the SHORTER chunk header of the two
  formats.
- **The escape byte must be set in exactly one place.** `MEASURE`
  prices each chunk and `WRITECOMP` writes it, and both run the same
  `RLECHUNK`. The first version set `LZ_ESC` only in the writer, so
  the pricer measured the chunk against escape byte `$00` and the
  writer emitted it against `$DB`; `comp_thread_eof` became a lie and
  both readers failed with an off-by-n INSIDE the chunk
  (`nufxlib: ERROR: RLE input glitch (off by -254)`). It is now set
  once, in `ADDARC`, under a comment saying why.
- **This encoder does not reproduce NufxLib's escape-byte bug.** A run
  shorter than four bytes is cheaper emitted literally -- UNLESS the
  byte IS the escape, which must be coded whatever its length, or the
  reader will take the literal as the start of a code. NufxLib's
  `Lzw.c` emits a short escape run literally. Deleting the three
  instructions that special-case it is this gate's teeth: a2til and
  NufxLib BOTH reject the result, off by exactly the bytes the
  escaped runs cost.
- **Price every chunk, and store the ones that do not pay.** A chunk
  whose coded form is not smaller is written stored, so text comes out
  no larger than it went in.
- **It closed two holes in the DECODER's coverage.** The LZW/2
  fixture's chunks were `LZW x7, LZW+RLE` -- `RLE-only` and `stored`
  were never exercised by any fixture. The encoder emits both, so
  `-x` is now tested on every chunk shape the format has.

## Writing LZW: what stage 2 settled

- **The encoder runs exactly ONE ENTRY AHEAD of the decoder, and the
  code width is derived from that number.** The encoder adds an entry
  when it emits a code; the decoder adds when it reads the NEXT one.
  The decoder's rule is `(ENTRY + 1) >> 8`, so substituting
  `ENTRY = E - 1` leaves the encoder's rule as `E >> 8` -- the high
  byte and nothing else. **The two rules agree except when `E` lands
  exactly on `$xxFF` at an emit**, which is why this is worth stating:
  the stage-1 fixture (table reaches entry 469) passes with the WRONG
  rule, and only the 28 KB fixture, whose table fills to 4096, catches
  it. A small fixture cannot test a width rule.
- **A chunk boundary does not break the string.** LZW/2 carries its
  table across compressed chunks and the decoder carries its previous
  code with it, so the first code of a chunk still extends the last
  code of the one before and an entry is added linking them. The
  encoder cannot add that entry when it flushes -- the byte that
  completes it has not been read -- so it records the debt and pays at
  the top of the next chunk. Sabotaging that one flag is caught by
  both readers on both fixtures.
- **`dum <symbol>` does not survive the REL link when the symbol is in
  a `dum` arena.** The readable way to overlay the encoder's hash
  buckets on the decode stack is `dum LZ_STACK / LZ_HEAD ds 4096 /
  dend`. merlin32 assembles it correctly. Under the nas+ld split that
  arena is a separate bss MODULE, so `LZ_STACK` is an EXTERNAL whose
  value no assembler knows, and a `dum` needs that value at assembly
  time to place its labels -- nas placed them 18 bytes off in silence.
  Same lesson as `#>BUF+n` and a different mechanism; the fix is to
  spell the array by its real name at both use sites.
- **The index is free; only the chains cost memory.** Compression and
  expansion never run in the same process, so the decoder's tables are
  dead during `-a`: the string table IS the decoder's, and the 2048
  hash buckets are the 4096-byte decode stack. Only `LZ_NEXT` (8192 B)
  is new, which took the arena to within ~1.5 KB of its ceiling -- and
  that ceiling had never been declared. `err */$BF00` is there now.
- **The language card was considered and rejected.** It is where `ex`
  put an 8 KB table, and it is the wrong home for this one: holding
  the LC write-enable across a 4096-byte encode is exactly the shape
  that killed the machine on 2026-09-20, and bracketing per access is
  not affordable in this loop.
- **One decision point, not two agreeing ones.** Stage 1's bug was a
  pricer and a writer that each decided for themselves. With LZW the
  exposure is worse, because the encoder carries a table across
  chunks: the passes must not merely reach the same verdict, they must
  mutate the same table the same way in the same order. `CHUNKPREP` is
  the only place a chunk's form is chosen and both passes call it.
- **What the fixture had to be built to reach.** No fixture taken from
  a real archive produced all four chunk shapes. This one is
  constructed to: 4096-aligned blocks of varied text (LZW, and enough
  distinct strings to fill the table and force a clear), LCG bytes
  (stored), LCG bytes carrying a periodic run (RLE-only -- the only
  shape that survives the size comparison once LZW is available), and
  a long run. Measured with a model of the encoder BEFORE it was
  written, which is also what proved the design was sound when the
  6502 came out right first run.

## Grounded against REAL ShrinkIt, 2026-09-22

The format question -- should a //e write LZW/2 at all, when the packer
on that machine writes LZW/1? -- was settled by testing rather than by
argument, on the operator's criterion: *as long as real 8-bit ShrinkIt
can decompress maux's archives, there is no issue.*

**It can, both ways, byte-identically.** ShrinkIt 3.4 (Andy Nicholas,
1988-92) was booted on an emulated enhanced //e -- the machine maux
targets -- with maux's archive on a second SmartPort volume:

- **ShrinkIt reads maux.** It lists the record correctly (`LZW.BIN`,
  `BIN`, `$4321`, Format `ShrinK`, 39%, 28626) and UnShrinks it to
  28,626 bytes byte-identical to the original.
- **maux reads ShrinkIt.** ShrinkIt packed the same file as LZW/1
  (`thread_format $0002`, 11,473 bytes) and `nulib2 -x` expanded it
  byte-identically. That archive is now `fixtures/shrinkit34.shk` and the
  `period` case of check-nulib2 runs it on every sweep.

**Use the right ShrinkIt, and check which one you have.** The first
disk tried was an earlier ShrinkIt, and it showed maux's thread as
`Fmat ???` with a blank name -- which reads exactly like a maux defect
and is not one. Its format-name table has three entries and no LZW/2:

    'ShrinkIt   '   thread_format $0002
    'SQ/USQ     '   thread_format $0001
    '---       ????'

It predates LZW/2 entirely. **A version that cannot know the answer is
not evidence** -- the same shape as `the oracle can be the wrong one`.
3.4 identifies itself as `Copyright 1988-92` on the title line where
the earlier one says `1988-89`.

**What the period oracle caught that no host fixture could.** ShrinkIt
writes an empty 200-byte MESSAGE thread into every record. This project
had attributed that to NufxLib; it is ShrinkIt's own convention and the
format's, and a reader must step over it by `comp_thread_eof` (200) and
not `thread_eof` (0). Every other fixture here was built by a2til or
NufxLib, and none contained one.

**How to remake the fixture.** Fetch a ShrinkIt 3.4 disk (Internet
Archive `LOGIC_AppleII_Disk-P8C001` carries it under `/ShrinkIt3.4/`;
`3d0g_205a_ShrinkIt` is bootable but older), convert DOS to ProDOS
sector order, graft 3.4's `SHRINKIT`/`SHRINKIT.SYSTEM` onto the
bootable one, and drive it with the verilogapple MCP tools: mount the
payload disk as SmartPort unit 2, `N`ew archive, `Files`, TAB to the
other volume, SPACE, Return, name it, then `eject_disk` with
`export_to` to get the volume back. Note the file picker's K/J keys did
not move the cursor under emulation, so put exactly ONE file on the
source volume and take the default selection.

## One pass, 2026-09-22: what the two-pass writer cost

Measured on an emulated //e against the same 28,626-byte fixture, and
against ShrinkIt 3.4 doing the same job on the same machine:

| | cycles | ~seconds at 1 MHz |
| --- | --- | --- |
| `nulib2 -a`, two passes | 50-70M | ~60 |
| `nulib2 -a`, one pass | 33-38M | ~35 |
| ShrinkIt 3.4 | <=14M | ~14 |

**The format was never the lever.** LZW/1 -- the only thing P8 ShrinkIt
packs -- would be SLOWER here, not faster: it mandates a stream CRC
over every chunk's full PADDED 4096 bytes, which LZW/2 does not have
at all, and this CRC is bit-serial (eight shift-and-conditional-EOR
iterations a byte). That is ~1.4M cycles per pass of work LZW/2 simply
never does. The match loop is otherwise the same.

**The lever was that every file was read and CODED TWICE.** A v3
record puts `comp_thread_eof` and the plaintext `thread_crc` inside a
header that precedes the payload, and `header_crc` covers both, so
neither could be patched into a header already written -- hence a
pricing pass and a writing pass, each running the whole RLE and LZW
stack.

ShrinkIt does not do that, and lesson 9 says how: *"it can seek back
and patch the length in before writing."* `ADDONE` now writes a header
of the right SIZE with the two fields it cannot know, writes the
payload once, then seeks back and lays the real header over it. Same
archives, byte for byte, in every gate case.

**Two things the rewrite had to get right.**

- **A file that cannot be opened must still be SKIPPABLE.** Skipping
  is only possible while nothing has been committed, so `GETDLEN` runs
  before the placeholder is written. After that a failure is the
  archive's and stops the run.
- **Rewinding does not shorten a ProDOS file.** When coding loses, the
  writer seeks back over what it wrote and stores instead -- and the
  file keeps its high-water mark, so the archive carried up to 26
  bytes past its own `master_eof`. Every reader here walks by
  `master_eof` and none of them noticed; it surfaced only because one
  gate prints the archive's FILE size. `TRUNCARC` sets the EOF at the
  end.

**The CRC was the biggest single item, and nobody would have looked
there.** A sampling profile (`scripts/profile_nulib2.py`, the house
step-and-read-PC pattern) put the bit-serial CRC-16 at **31.9%** of
`nulib2 -a` -- ahead of the entire LZW family -- at ~200 cycles a byte
for eight shifts and two conditional EORs. Made table-driven, with the
512-byte table BUILT FROM the bit loop at startup so the polynomial has
only one definition, it fell to 6.2% and the run went ~35 s -> ~30 s.

That table had to be paid for: the arena's `err */$BF00` fired, which
is what it is for. `LZ_NEXT` gave the space back -- a chain node is
always a table ENTRY and entries begin at `$0101`, so an array indexed
by raw code wastes its first 512 bytes. `LZENPTR` subtracts `$0100`
first, four cycles an access.

**So 60 s -> 30 s, a 2x, and the profile is now LZW-shaped**: LZELOOK
18.5%, RLECHUNK 16.0%, LZSFX 8.0%, LZTBL 4.7%, and the rest of the
encoder behind them.

**The next candidate, worth ~1.3-1.5x on paper:** every table access
goes through `LZTBL`, which costs a `jsr`/`rts` and a runtime 16-bit
add, and there are several per input byte. An earlier note here said
fixing that needs `ds \` from `nas`; **that was wrong** -- assembler
alignment is one way, but reserving slack and computing a 256-aligned
base ONCE at startup is another, and it needs no assembler feature at
all. With the base's low byte zero, an access becomes a store of the
code's low byte and an add of its high byte to a cached page number.

**Whether that closes the gap to ShrinkIt is not something to promise**
-- it is hand-tuned 1989 assembler whose LZW/1 also clears its table
every chunk, so its hash chains stay short where maux's persist. The
**Three more rounds, all measured: ~30 s -> ~22.5 s.**

- **The run-length scanner cost ~230 cycles a byte, nearly all of it
  spent proving a literal was a literal.** A byte unlike the next one
  is a run of one, which is most bytes of most files -- and it was
  still walking the run counter, the over-256 split and the length
  tests. A fast path for it took `RLECHUNK` + `RLEPUT` from 21.6% to
  8.7%.
- **The LZW table accesses were inlined.** `LZELOOK` was 18.5% and
  `LZTBL` another 4.7%, and most of that was the `jsr`/`rts` and the
  `LZ_TIX` round-trip rather than the address arithmetic, which is
  eight bytes of adds. The addends are ZERO (`#<SYM`, `#>SYM`), which
  the REL link carries exactly.
- **Hashing and addressing the bucket were fused.** Measured first:
  the chains average **1.27** entries and peak at 5, so there is
  barely a walk to pay for and the fixed cost of setting one up
  dominated. `LZEBUCK` produces the address, keeping ONE definition
  of the hash, and `LZEADD` computes it once instead of three times.

**A fourth round, and this is where the knee is.** Skipping the
run-length pass outright when a chunk cannot benefit -- no run of four
and no escape byte means every coded byte would be a literal and the
length would come to exactly 4096, which is the value that already
means "not coded", so it is exact and not a heuristic -- plus inlining
the per-byte input fetch and letting `LZELOOK` hand its bucket to
`LZEADD` rather than have it hash the same pair again. Together those
bought **about 5%**, not the ~15% the profile suggested. The
early-out is defeated on any chunk carrying a stray escape byte, which
random data does roughly sixteen times per 4 KB.

Exact figure for the current build, counted by the profiler from the
command to the prompt rather than bracketed: **19.55M cycles, ~19 s**.
The earlier numbers in this table were bracketed by hand and read
perhaps 10% high; the SHAPE of the trajectory is right, the last digit
is not.

**THE SHRINKIT BASELINE WAS WRONG, AND FLATTERING.** Every "~14 s"
above came from a bracket so loose it could have meant anything from 5
to 15 seconds. Timed properly -- from the keystroke that starts the
pack to the FINISHED box -- ShrinkIt 3.4 does this file in **~10.6M
cycles, 10.4 s**.

maux's own number needed the same care, in the other direction: the
19.5M includes the shell reading the line, forking, and loading a
10.8 KB binary, which ShrinkIt never pays. Measured on a one-byte
input, that overhead is **620k cycles** -- only 3%, so the comparison
was fair after all.

| | cycles | ~s | cycles/byte |
| --- | --- | --- | --- |
| maux, the job | 18.93M | 18.5 | **661** |
| ShrinkIt 3.4 | 10.65M | 10.4 | **372** |

**So the gap is 1.78x, not the 1.4x this file has been claiming.**

## RULING (operator, 2026-09-22): 18.5 s is fine, and the gap is a
## difference in TARGET MACHINE

> "maux users likely have accelerators. shrinkit is hand-tuned to be
> useable by standard apples."

ShrinkIt had to be quick on a stock 1 MHz //e because that was every
machine it would ever run on. maux is a development system for people
who fit cards, and the commons has the figures
([[01M0VWR57JVNNAGYJD2TXYPYKY]], closed 2026-09-20 by the ZIP Chip's
own manual: "up to 30 banks of RAMWORKS style auxiliary memory can be
cached (2 megabytes)" -- so a bank-per-process OS IS accelerated,
which was an open question for weeks). Amdahl over a measured maux
profile gives **2.94x at 4 MHz and 4.35x at 8 MHz**, which puts this
at roughly **6.3 s and 4.3 s**.

**And `-a` is the FAVOURABLE case for that cache, not the average
one.** Those multipliers were measured on a switch-heavy workload --
416 spawns, 25% in MLI -- and the same note flags them as OPTIMISTIC
there, because the Zip's cache is direct-mapped with ONE-BYTE lines
and the index does not include the bank, so processes evict each
other byte-for-byte at identical offsets. A compressor is a single
long-running process in ONE bank running tight inner loops, which is
exactly what that cache is good at and exactly what the profiled
workload was not.

Two things that do not accelerate, for honesty: the ~13% of this run
inside the kernel, and the LZW tables -- ~20 KB of randomly-accessed
data against an 8 KB cache. The win lands on the code loops, which is
where the LZW core is.

The kernel's share collides with nulib2's own code in the same cache
slots because the kernel `.SYSTEM` loads FLAT from `$2000` in main and
runs to `$93A1`, straight through both hires pages. That is declared
debt, not an accident -- `inc/mm.main.equ` calls `$2000` a "HARD video
reserve / temporary text-only V1 reclaim" and says outright that "HARD
video described an intention, not the build", with the stated exit
being to SHRINK the kernel rather than relabel the region.
`check_kernel_images.py` gates the CEILING (nothing may overrun the
MLI buffers at `$9800`); nothing gates the floor, because by design
the image starts there. Worth knowing the size of the debt before
anyone calls it nearly paid: vacating both hires pages means fitting
the kernel into `K_CODE_C`, `$6000-$9800` = 14,336 bytes, against
29,601 today -- a 52% cut, not a trim.

None of which makes ShrinkIt slower -- it would accelerate too. The
point is that 18.5 s on the machine maux is actually built for is not
the number that decides anything.
Part of it is structural and is the price of the better ratio: LZW/1
wipes its table every 4 KB, so ShrinkIt's dictionary never exceeds
about a thousand entries and can be indexed by small, fast,
page-aligned tables, where a persistent 4096-entry table needs 12-bit
indices and collision chains. The rest is inner-loop quality.
The rest is grind, not structure: `LZELOOK` is still the largest item,
then `LZECHUNK`'s per-byte loop, `LZEADD` and `LZEMIT`'s bit shifts.
Note ShrinkIt does strictly MORE checksum work (LZW/1's stream CRC)
and the same RLE-then-LZW passes, so the gap is implementation
quality, not a better algorithm -- though its per-chunk table clear
does keep its structures smaller than a persistent 4096-entry table.

## Oracles

Three, and they are independent of each other:

- **`nulib2 -p archive file`** extracts to stdout for a byte-exact compare.
  Not in Homebrew; it is a plain autoconf build from `fadden/nulib2` (the
  recipe is in `01M0KZQJTHDP01FKPNP1HTWDW7`).
- **a2til**, which is a second independent implementation, already in the
  tree's dependency set, and which also **builds the fixtures**.
- **The archive's own CRCs**, which catch a desynced parse immediately --
  but never as the sole check, per the `$DB` note above.

`launder -m {sq,lzw1,lzw2,...}` turns one hand-built corpus into one
archive per compression format, which is how slices 3 and 4 get their
fixtures without needing period software.

A fixture warning from the same learning, for slice 4: **a corpus of small
files exercises LZW/2's clear-code path exactly zero times.** It needs a
few hundred KB of compressible text.

## Library notes

- `learning:01M0KZQJTHDP01FKPNP1HTWDW7` -- the format: CRC seeds and ranges,
  `thread_eof` vs `comp_thread_eof`, `attrib_count` as the tail authority,
  per-thread compression, LZW/1 vs LZW/2 memory. Everything the reader
  parses.
- `learning:01M0M67H5Y79780K1KY69W8PTN` -- why an archive's own CRC is not
  sufficient evidence, and the `nulib2` vs `launder` encoder difference that
  a differential test has to pick between.
- `learning:01M31QSJ9K6V389DEVKMW9CBTK` -- McFadden's Lesson 9: the 4 KB
  chunk is a 5.25-inch disk track, and every memory property of the two
  LZW formats falls out of that. Why LZW/1 is the easier READ.
- `learning:01M31XNS6N2H4QPDZB7JD0CMR9` -- and why LZW/2 is the easier
  WRITE: an RLE-only thread with the LZW flag clear is fully legal, has
  no stream CRC, and emits the shorter chunk header of the two. Deposited
  from stage 1, and carries stage 2's correction to its own coverage
  claim: once LZW exists, an RLE-only chunk is nearly unreachable.
- `learning:01M322FJ60GVT1QZG6R41EWJSP` -- the ENCODER, deposited from
  stage 2 into the gap Lesson 9 names: the one-entry lead and the code
  width that follows from it, the chunk-boundary debt, and the table
  layout no document gives.
- `learning:01M34341NAR4FXCB6G8K9VHBZ8` -- the Binary II 128-byte header,
  field by field, if anything ever needs to WRITE a `.BXY`. Note its EOF
  is split with the halves 96 bytes apart (`+$14` and `+$74`), and that
  BLU's behaviour rather than the spec defines what a reader must
  tolerate.
- `learning:01M2PSVAFMJJQN1PMPVS0FPYZP` -- `#>BUF+n` on a `dum` cell
  cannot survive the REL link; it cost this tool a one-byte
  `check-nas-librel` miss. Third instance of the same note.
- `learning:01M2CA25W8PYJYCHCGDQ706MHJ` -- if any part of this is ever
  written in PLASMA after all: size the input against the heap BEFORE
  looping on it, or an unchecked `allocheap()==0` scribbles the VM's zero
  page and the tool "hangs" silently.
- `learning:01M197TY462D8ZRJHSQ77FGWK9` -- io_buffers on the floor of the
  free region cap every build; this tool wants a large arena, so it is the
  first new program in a while that could hit that ceiling.

## Slice 8: `.SDK` -- a disk image inside an archive. SHIPPED 2026-09-28

Operator, 2026-09-27: "dd the floppy to a file, sdk it with nulib2".
The blocker named at the top of this file (no block devices) is
closing in the same round (docs/KSEG.md, docs/DEV-BLOCK.md), and the
input this slice takes is a FILE anyway: the 143,360-byte image `dd`
just wrote, or the device itself once `/dev/sNdM` is a file you can
`read(2)` and `lseek(2)`.

### Library notes

- `learning:01M0KZQJTHDP01FKPNP1HTWDW7` -- the format. For a disk
  record: `extra_type` is the BLOCK COUNT and `storage_type` the
  BLOCK SIZE (512), `thread_class 2 / thread_kind 1`, and the v3
  `thread_crc` is over the plaintext image, seed `$FFFF`.
- `learning:01M31QSJ9K6V389DEVKMW9CBTK` -- the 4 KB chunk is a 5.25"
  track; a 140K image is exactly 35 chunks, and RLE was designed for
  empty tracks. This is the workload the format was built for.
- `learning:01M31XNS6N2H4QPDZB7JD0CMR9` and `01M322FJ60GVT1QZG6R41EWJSP`
  -- the LZW/2 writer this slice reuses unchanged; the stream header's
  `disk_volume` byte is the one field it sets differently for a disk.
- `learning:01M33C20C056VGV3BV6S823QRX` -- ShrinkIt 3.4 is the period
  oracle; `nulib2 -v` on the host shows a disk record as `Disk 140k`.
- vendor/ftn/filetypenotes.txt, the NuFX note: "If the file system of
  a particular disk is known, as many of the fields as possible should
  be filled with the correct information. Fields which do not pertain
  to an archived disk should remain set to zero."
- `learning:01M3KSD6H8Y3CT72HV0Z7S0G28` -- deposited from this slice:
  the `disk_volume` byte is `$FE` unconditionally in both a2til and
  NufxLib's `Lzw.c`, for a disk OR a file thread; the file-thread
  choice here (`$00`, unchanged) is a known cosmetic byte difference
  from a real ShrinkIt-family archive, harmless to read.
- `learning:01M3KSEBRD5PPSR1F5E23TKMVC` -- deposited from this slice:
  the `extra_type`/`storage_type` size ladder is unreachable dead code
  against any writer (this one included) that always populates
  `thread_eof` honestly; a `storage_type` teeth-test alone will not go
  red against either oracle, and an unshifted `extra_type` is what
  actually demonstrates the failure.

Measured on the host 2026-09-27 before this was written: a stored
disk record of a 280-block a2til-built volume (`nufx_fixture.record
('FLOPPY', [disk_thread(img, eof=0, ...)], file_type=0, extra_type=
280, storage_type=512)`) lists on host `nulib2 -v` as `FLOPPY  Disk
140k ... unc 100% 143360`, `nulib2 -x` writes it back byte-identical,
and `a2til`'s `NufxArchive.disk_record.read()` returns the image
byte-identical. Those three are this slice's oracles.

### The rule: the archive's NAME says it is a disk archive

`nulib2 -a NAME.SDK IMAGE...` archives each input as a DISK IMAGE
when `NAME` ends in `.SDK` (case-insensitive, the ProDOS way). That is
how the world already tells the two apart -- ShrinkIt writes `.SDK`
for a disk, CiderPress and a2til open `.sdk` as a volume -- and real
`nulib2` has no flag for it because NufxLib's command line cannot add
disk images at all. No new letter; a maux-specific letter would be
one nobody could look up.

An input whose length is not a multiple of 512, or is zero, is
skipped with the `CANTADDM` warning and the run continues, exactly as
a file that cannot be opened is skipped today -- and for the same
reason: the decision is made by `GETDLEN` before anything is
committed to the archive.

### The record

Everything `ADDONE`/`BUILDREC` writes, with these fields different
for a disk record:

- filename thread: the input's basename (`LEAFIN`), same as a file's.
  The spec's own text also allowed the image's own ProDOS volume name
  here (a block-2 read), graded `[likely]` and explicitly not
  load-bearing -- both oracles find the record by its disk thread, not
  its name. **Not implemented**: `nulib2.bin`'s `err */$BF00` arena
  had only 63 bytes of headroom at the base SHA, and the volume-name
  read alone costs ~120. See "The arena wall" below.
- `file_type $00`, `extra_type` = length / 512 (computed by shifting
  the already-block-validated `DLEN` right 9 bits: `lsr`/`ror` on its
  top two bytes), `storage_type $0200`; `access` as the input file's,
  like every other record; dates as today (or the `/dev` fallback's
  zeroed dates, when the input is a device -- see below).
- one data-class thread, `thread_kind $0001`, `thread_format` chosen
  per chunk by the existing `CHUNKPREP`/`WORTHIT` logic (LZW/2, RLE,
  stored), `thread_eof` = the image length (the truth -- `BUILDTHR`
  always writes this from `DLEN`, coded or not), `comp_thread_eof` as
  coded, `thread_crc` seed `$FFFF` over the plaintext.
- the LZW/2 stream header's `disk_volume` byte: `$FE` for a disk
  thread, `$00` for a file thread (unchanged). VERIFIED [fact], not
  [reported]: a2til's `_lzw.py` (`LZW_DEFAULT_VOLUME = 0xFE`, line 81,
  used unconditionally by `compress_lzw2`) and NufxLib's own `Lzw.c`
  (`kNuLZWDefaultVol 0xfe`, line 93, `putc`'d at line 617 for every
  LZW/2 stream) both write `$FE` regardless of thread kind, and both
  decoders discard it on read (NufxLib's own comment: "not really
  used"). Fetched `Lzw.c` with `gh api
  repos/fadden/nulib2/contents/nufxlib/Lzw.c -H "Accept:
  application/vnd.github.raw"`.
- `-0` still means stored, and a stored disk thread is the blocks in
  order, which is what a stored data thread already is -- no special
  case needed.

`-v` on maux prints a disk record with `Disk` in the type column
(breaking the 3-character TTT convention on purpose -- the one column
that is not fixed-width) and the block count where a file's aux would
go (`PRSIZE`/`FAUX` already handle it; `FAUX` is generically
`extra_type` for any record, so no reader change was needed there --
only `RDTHREADS` had to widen its thread_kind test from `== 0` to
`== 0 || == 1`, and `PRROW` had to print `DISKTYP` instead of
`PRTYPE`'s output when the record's data thread was kind 1).

### The arena wall, and what it cost (docs/NUFX-SDK-NOTES.md has the
### round-by-round detail)

`nulib2.bin`'s `err */$BF00` had only **63 bytes** of headroom at
this slice's base SHA (a3fda38) -- far less than the "adds no table,
only a header variant and a block-2 read" cost estimate above assumed,
because that estimate did not budget for `CHKSDK` (detecting `.SDK`
from the archive name), `GETDLEN`'s length validation, `INFO`'s
`/dev` fallback, or the `-v` "Disk" row support, all of which the
"Record" and "Gate" sections above also require. A first complete
implementation overflowed by 285 bytes. What closed the gap, in order:
dropping the block-2 volume-name read (~123 B, see above); tightening
`CHKSDK` to a 4-character fold-and-compare loop exploiting that `'.'
OR $20` is a no-op (~15 B); simplifying `INFO`'s `/dev` fallback to
never itself distinguish a bad path from a device path -- `GETDLEN`'s
own `INOPEN`, one call later, already catches a bad one with the
identical `CANTADDM` warning (~10 B); an `if/else` -> `overwrite`
rewrite of `BUILDREC`'s disk branch (~3 B); `inc FLAG` for a
known-zero flag instead of `lda #1/sta` (~4 B); dropping `GETDLEN`'s
separate "not empty" check, keeping only "multiple of 512" (0 passes
that test arithmetically -- a documented, untriggered gap, no gate
fixture is zero bytes); and, the one lever big enough to matter,
**shrinking `XBUFSZ` (the stored-thread extract / `-0`/`FILECRC` copy
chunk) `$80` -> `$40` and `LZBUFSZ` (the LZW stream's refill window)
`$80` -> `$20`**, together freeing 176 bytes of ARENA directly. Both
are provably correctness-neutral (`LZREFILL` already documents that
it tolerates a short read; `INCHUNK`/`COPYFORK` are byte-generic
chunked-copy loops) and only change how many `SC_READ`/`SC_WRITE`
calls a large stored copy or a long compressed extract costs --
confirmed by measurement: `XBUFSZ=$10` (16) made the `sdk0` gate case
(a stored 140K copy) exceed even a widened step budget outright, while
`$40` (64) passed comfortably, so `$40` is the value shipped. Final
margin: 50 bytes. This is deliberate corner-cutting under a hard
binary-size wall, not a hidden shortcut, and it costs real users a
slower `-x`/`-0` on a large file -- flagged here, at each `equ`, and
in the working notes.

### Gate

`check-nulib2` gains `sdk` and `sdkdev` cases (14 cases total, up from
12). `build_floppy_image` stages a 280-block ProDOS volume with a2til
(`prodos.create` + `Volume.write_file`) holding text, all 256 byte
values, a long run of one byte, and a file spanning several 4 KB
chunks, with the rest of the volume's blocks left untouched -- the
writer's own compressor-fixture shapes, laid into a volume. On the
machine: `nulib2 -a FLOP.SDK FLOP.IMG`, `nulib2 -0 -a FLOP0.SDK
FLOP.IMG`, and `nulib2 -v FLOP.SDK` (asserted against the exact row
`PRROW` must print, computed independently rather than typed loosely:
`' Disk %8d $%04X %s' % (image_len, block_count, name)`). Exported to
the host: `nulib2 -v` shows a `Disk` row (real nulib2 additionally
prints `Disk 140k`); `nulib2 -x` byte-identical; `a2til`
`NufxArchive(path).disk_record.read()` byte-identical; `nulib2 -i`
clean; the `-0` archive passes the same four checks. `sdkdev` mounts
the SAME fixture image as a second SmartPort unit
(`/dev/s7d2`, check_devblk.py's pattern) and runs `nulib2 -a DEV.SDK
/dev/s7d2`, then the same four host checks -- proving the device path
and the kernel's `LSEEK(END)`-via-`SYS_GET_EOF` block-count answer
(`docs/DEV-BLOCK-NOTES.md`'s "never yet exercised by a real consumer"
is now closed). All 14 cases pass; the pre-existing 12 were re-run and
confirmed unaffected by the `XBUFSZ`/`LZBUFSZ` shrinks and the `INFO`
simplification.

**Teeth, both actually run red then reverted, and one did not fail
the way the spec predicted -- a finding worth having.** Writing the
input's raw byte length into `extra_type` UNSHIFTED (143360 instead of
280) is a clean red: real `nulib2 -v` shows `Disk 6144k` / `Un-Length
6291456`, `nulib2 -x`/`-i` crash with `Assertion failed:
(lzwState->dataInBuffer)` in NufxLib's own `Lzw.c`, and a2til raises
"LZW stream ended at a chunk header" -- both readers clearly wrong,
as the spec expected. Writing `storage_type $0001` (a file's) instead
of `$0200`, however, produced **no visible wrongness in either
reader**: `BUILDTHR` always writes the true `thread_eof` (143360), and
NufxLib's own `-v`/`-x` use that directly rather than
`extra_type * storage_type` when it is populated; a2til's
`Record.content_size()` ladder explicitly treats any `storage_type`
outside `{256, 512, 524, 1024}` as implausible and substitutes 512 --
which for this fixture happens to BE the true block size, so the
"wrong" value is silently corrected back to the right answer. The
`extra_type`/`storage_type` ladder this format leans on is reachable
only when a writer leaves `thread_eof` zero (some ShrinkIt versions
do); this writer never does, so that ladder is dead code for every
archive it makes. Measured, not assumed -- see the notes file for the
exact commands and output.

Measured cycle count for `-a` on this slice's 280-block (143,360-byte)
fixture: **42.7M cycles, ~42.7 s at 1 MHz** (`scripts/
measure_sdk_cycles.py`, fast backend, `regs`'s cumulative cycle
counter start/end around a settled command). That is ~298 cycles/byte
-- well under the 661 cycles/byte measured for the general-file
compression benchmark (2026-09-22), because most of a real floppy
image is untouched (zeroed) blocks, which is exactly the RLE case
Lesson 9 says the format was built for ("If more or all of a disk
track is empty, RLE is a win"). The archive itself: 12,424 bytes for
143,360 bytes of image (91.3% smaller).

### From the device directly

`nulib2 -a FLOP.SDK /dev/s7d2` works with no code specific to it,
gated by `sdkdev` above: `INFO`'s `GET_FILE_INFO` fails on a device
path, so `INFO` falls back to type `$00`/no dates for a path the
kernel opens but ProDOS cannot stat -- the one change -- and
`GETLEN`'s `LSEEK(END)` is answered by the kernel via `SYS_GET_EOF`
(liba's own `seek.s`: "SEEK_END is GET_EOF then SET_MARK"), which for
an `OFT_BLK` fd dispatches to `PRC_BLK_GEOF` and returns
`total_blocks << 9` read fresh from the volume header every call
(`kdevblk.s`). No `nulib2` source references `/dev` or `OFT_BLK` at
all; the whole path is generic file I/O.

### Real archives from the wild: two reader bugs this writer's own
### fixtures never triggered

docs/UNPACK-E2E.md's `check-unpack` (2026-09-29) drives `nulib2 -x`
against REAL `.SHK`/`.SDK` archives fetched from public Apple II
archives (`fixtures/PROVENANCE.md`), not this writer's own output --
and found two bugs in the READER (`nulib2arc.s`'s record walk, the
`-x`/`-v`/`-t` side) that every earlier gate, built on maux's own
`nulib2 -a` fixtures, could not have exercised, because this writer's
`-a` always populates the fields those fixtures happened to need:

- **A disk record's in-header name may carry every byte's bit 7 set**
  (the ordinary Apple II high-bit-ASCII display convention). Measured
  on DEMOPROG.SDK (a 1990 GEM CD disk archive with no filename
  thread, name in the header tail): `b'\xc4\xc5\xcd\xcf...'`, which is
  exactly "DEMO.PROGRAM" + `$80` per byte. A high-bit byte is not a
  legal ProDOS pathname character; real ProDOS 8's own `CREATE` would
  refuse it. Real ShrinkIt-family readers (host `nulib2 -x`, checked
  directly) strip it; maux's `RDNAMEHDR`/`RDFNTHRD` did not. Fixed:
  `and #$7F` on both `NAMEBUF` copy loops.
- **A disk thread's own `thread_eof` is exactly as unreliable for a
  READER as the "Grounded against REAL ShrinkIt" section above found
  for a WRITER's `extra_type`/`storage_type` teeth -- just the
  opposite field.** Measured: DEMOPROG.SDK's disk thread has
  `thread_eof=107008` (truncated; the true image is 143,360 bytes) and
  XMASADV.SDK's has `thread_eof=0`. `RDTHREADS` filled `DSIZE`
  straight from `thread_eof`, so `-x` extracted DEMOPROG.SDK's image
  truncated at 107,008 bytes and XMASADV.SDK's LZW/1 expander read
  `REMAIN=0`, never ran a single chunk, and reported a false "damaged
  compressed stream" (the stream-CRC compare fell through with
  `LZ_CCRC` still at its seed value against the archive's real header
  CRC). Fixed: when a thread is the disk kind, `DSIZE` is computed as
  `FAUX (extra_type, the block count) << 9` (multiply by 512, the one
  block size every disk archive here uses) instead of trusted
  `thread_eof` -- the same ladder a2til's own reader already applies
  on the fallback side, done as a shift rather than a general multiply
  to fit the arena.

Both together cost 4 + ~20 bytes of the `$BF00` arena wall this slice
already measured at 50 bytes free; margin is now 11 bytes. Full
measurements, cycle counts and the three teeth transcripts are in
docs/UNPACK-E2E-NOTES.md.
