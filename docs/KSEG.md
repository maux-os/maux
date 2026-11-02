# The kernel cold segment: LC bank 2, $D400-$DFFF

Status: LIVE. The segment is built and gated (`check-kseg`,
`scripts/split_kseg.py`, loaded by KSEG_LOAD at boot from the `KSEG`
file on the boot volume); `/dev/sNdM` (docs/DEV-BLOCK.md) and the
PRODOS-CASE mask live on it. Written 2026-09-27 as the buildable spec
(operator: "lets do it all"). Every claim names its source; the items
marked MEASURE were the measurements the build had to close before
code depended on them. Current size: 10 B of the segment free after
`PCASE_MASK` (update at the end); the loop device has its own low
segment (docs/LOOP.md sec 7).

## Why

`MAUXPLAY.SYSTEM` ends at `$97E8` -- zero bytes below the harness's
PT_HOLD cell block -- and the last two `bye` fixes were paid for by
scraping `stz`s (docs/PROJECT-STATE.md, 2026-09-27). The /dev
block-device work, written flat, cost +1096 B in every full kernel
image and pushed MAUXPLAY to `$9BE3`, INSIDE the cell block, which
showed as 17 reds in a sweep. The kernel had no room for any further
feature in main RAM.

Main memory is not the only RAM the kernel owns. Apple's language
card "bank 2" (`$C080-$C087` group; this tree's inverted name is
`LCBANK1_RAM`/`$C083`) holds ProDOS's QUIT-code window at
`$D100-$D3FF` and nothing else: `$D400-$DFFF`, 3,072 bytes, is
unused by ProDOS 8 on a 64K machine, and `bye`'s launch half
already lives there (inc/byeres.equ `BYE2_ORG`). This spec makes
that 3 KB a proper kernel segment for COLD code, loaded from disk,
called through a bank-select trampoline.

## Library notes

Fetch every handle before starting (superseded ones forward). Then
run your own searches on your task's nouns; this list is what the
architect found, not everything there is.

- `learning:01M3G46SEZ3D1RCVJGN39VYE43` (deposited 2026-09-27 from
  the TRM listing) -- the MLI reads the caller's inline
  call bytes UNDER BANK 1, so no `jsr MLI` may be issued from segment
  code; its exit restores `$C083` by comparing a `$D000` byte, so
  bank 2's `$D000-$D0FF` is ProDOS's bank-ID byte and is reserved.
- `learning:01M34A439TDASMVQNDCX41QGMN` -- the QUIT window is
  `$D100-$D3FF` of bank 2, `$D100` must be CLD; the resident's
  contract, which the segment must not disturb.
- `learning:01M2Y920F5DM0YKMCFVZDEBR6F` -- write-enable is ONE latch
  with no readback; only `$C083`/`$C08B` are legal (`check-lc`);
  never re-protect, never select read-ROM.
- `learning:01M2MCYEXW7JA7ZPZ4F7GC2217` -- sh's second segment: the
  copyin/copyout template REFUSES process addresses >= `$D000`
  (`K_CPY_ERR=2`), so a segment holds CODE ONLY -- no strings, no
  parmlists, no buffers.
- `learning:01M2MD0W7MY4V04SNT3E60WMHF` -- merlin32 emits a mid-file
  `org` block CONTIGUOUSLY (no padding); the flat output is
  low-part followed by segment bytes.
- `learning:01M1X4K315A16D5ZGCYD54R5VV` -- the kernel cannot copyin
  a parmlist from the language card; MLI parmlists live in main RAM
  below `$C000`.
- `learning:01M0W5ZCYJQH2A19V5XJW2HZR4` -- bank 1 `$D000-$D5FF` is
  ProDOS's Disk ][ driver (what a mis-banked call would execute);
  bank 2 `$D000` is "essentially empty".
- `learning:01KYYGZ8C3FQFWCF3S0FQ0DJ7B` -- TN #26: bank 2 is the
  sanctioned convention for resident-style code; `$D100-$DFFF`.
- `learning:01KW1GTYGZ9TE2ZGCDG0V2CNE0` -- `put`/`putbin` nest ONE
  level; a `putbin` inside a put-ed module embeds zero bytes.
- `learning:01M1B7W9Z76TMAKP7YPG63F7WQ` -- a driver may return with
  RAMRD/RAMWRT on aux; block I/O goes through the MLI, never a
  driver `JSR`.
- `learning:01M3EZBDRMT6MG9X54YM79W3K7` -- verilogapple mounts every
  SmartPort unit on slot 7; a `.woz` mounts on the slot-6 Disk ][.
- `learning:01M197TY462D8ZRJHSQ77FGWK9` -- harness cells parked
  above an image; the `ds N` one-run diagnostic for size-shaped reds.
- `learning:01M3EZABHD4JDEW9SSZ7PPV4M2` -- WRONG, and yours to
  correct once the evidence is in hand: it files check-dd's red on
  the /dev branch as a "pre-existing main-vs-merged regression". It
  is not. check_dd.py pokes `PT_F40` at `$97F0` BEFORE boot
  (scripts/check_dd.py:131), the branch's MAUXPLAY ends at `$9BE3`,
  and ProDOS's load of the .SYSTEM overwrote the poke -- so the
  image booted native-80 and `screen_rows('main')` stayed blank.
  main passes check-dd (115/115 sweep at 62d978d). Once /dev is on
  the segment and MAUXPLAY ends below `$97E8`, run check-dd on the
  merged tree; report the result and the architect will file the
  dated correction on that learning.
- ProDOS 8 TRM (artifact `d82965d8...`, chunk 320): the global-page
  listing quoted in the first note.

## Facts the design rests on

Each with its source. F1-F9 are settled; M1-M3 the engineer closes.

- **F1.** ALTZP selects zero page, stack AND which language card is
  mapped at `$D000-$FFFF`. Code executing from the LC cannot flip
  ALTZP (memory `altzp-selects-the-language-card`, measured twice
  in `bye`). The kernel runs with ALTZP = main
  (docs/ARCHITECTURE.md "Kernel entry/exit"), so MAIN's LC is what
  kernel code sees, and no ALTZP flip is needed to reach the segment.
- **F2.** The kernel's LC steady state is `$C08B` = `LCBANK2_RAM` in
  this tree = Apple's bank 1 = ProDOS's bank (inc/mm.hw.equ; the
  tree's names are inverted relative to Apple's -- memory
  `lc-only-c083-c08b`). The segment lives in the OTHER bank,
  `$C083` = `LCBANK1_RAM`. Every entry into the segment therefore
  selects `$C083`; every return re-selects `$C08B`.
- **F3.** The bank select is per-process state, captured at the
  doors (`KRN_IRQ_ENTRY` reads `RDLCBNK2` into the process's own
  `K_LCBANK`) and restored on the three resume paths (entry.s
  `:lcaltx`, entry2.s `:lcalti`/`:lcalts`; fb9152f, gate
  check-lcbank). Nothing in the kernel trusts the bank at entry;
  every LC-touching path asserts it (docs/MEMMAP.md sec 3.4).
- **F4.** The MLI reads its inline call bytes and dereferences the
  parmlist pointer AFTER `LDA $C08B` x2 (TRM listing, `MLICONT`).
  Its exit re-selects `$C083` only if bank 2's `$D000` differs from
  bank 1's (`EXIT1`, `BNKBYT2`). In-tree proof: byelaunch.s bounces
  every MLI call through page-1 `BL2_TRIG` and reselects the bank in
  `BL2_RET`.
- **F5.** `MAIN_IRQ_SHIM` (timer.s), the vector every main-context
  IRQ takes during an interrupt island, touches no `$C08x` switch
  and no ALTZP (read 2026-09-27). The islands are the `cli`/`sei`
  brackets around `jsr MLI` in procmli.s's `PMLI_*_CALL` wrappers,
  and nowhere else in the segment's call graph.
- **F6.** `bye`'s tenant owns all of main memory including bank 2
  `$D400-$DFFF` (EDASM runs its editor in that bank --
  `learning:01M1X0F064TX9PZD2JFVEX9MJJ`). The save bank covers
  `$0200-$BFFF`, ZP and page 1; it does NOT cover the LC. So the
  segment must be RELOADED from disk on return from a tenant.
- **F7.** `PRC_HALT_CORE` closes files and spins; it never QUITs
  (procfile3.s:932). Nothing but `bye` reaches `$D100`.
- **F8.** `PBY_LOAD_RES` (procbye.s) is a working disk-to-bank-2
  loader: fixed path -> `PRC_ALLC_IBF` -> OPEN -> 256-byte READs
  through `PMLI_XFER_BUF` -> copy under `LCBANK1_RAM` x2 -> CLOSE ->
  free the buffer; failures via `PRC_FAIL_A`. It is linked only in
  images that link procbye.s (the play image).
- **F9.** Every full kernel image links procfile5.s (32 top-level
  manifests in src/test/ do); the four spike images do not. Each
  manifest is a one-level `put` chain ending in its harness
  (playtest.s: 68 puts, `playtestb.s` last). check_manifests.py
  cross-checks the lists.
- **M1 (MEASURE).** `nas` in flat mode computes every output offset
  from the FIRST `org` (`off = curpc - orgbase`, src/asm/nas.pla
  ~3825; `orgbase` is set once, ~4606). A mid-file `org $D400` in a
  flat kernel assembly therefore does NOT emit contiguously the way
  merlin32 does. The native self-rebuild (check-selfmake's staged
  MAKEFILE builds MAUXPLAY.SYSTEM; scripts/build_librelas_image.py
  ~613 -- both retired 2026-10-18, check-nas-selfmake does it now) must still produce byte-identical output. Close this first:
  find out whether the native kernel build goes through `nas` flat
  or `nas` REL + `ld -s` (sh's segment precedent, docs/SH-SUBSET.md
  7.6), and either fix `nas`'s flat-mode second-org emission (a
  separate output cursor -- small, gated by the existing nas byte
  gates) or route the segment through `ld -s`. State which in the
  notes with the gate that proves it.
- **M2 (MEASURE).** The boot-time ProDOS prefix is the boot volume
  when `MAUX.SYSTEM` gets control, and PRC_INIT does not change it
  before the loader runs. Verify by reading PRC_INIT's order and by
  one `GET_PREFIX` peek on the play image.
- **M3 (MEASURE).** Volume headroom. Staging a `KSEG` file costs 1-7
  blocks on ~28 gate volumes (memory `liba-bytes-are-volume-bytes`;
  textaudit's volume was 512 B from full on 2026-09-14). Run `make
  report-volumes` before and after; name any volume that needs
  trimming and trim it in the same round.

## The design

### The file

Each kernel image gets a sibling file, `KSEG`, ProDOS type `$06`
aux `$D400`, holding the raw bytes of `$D400..$D400+len`,
`len <= 3072`. It is produced from the SAME assembly as the image:
the manifest's trailing modules are assembled under `org $D400`,
merlin32 lays them contiguously after the flat part (F9, note
01M2MD0W...), and a build step splits the output at the label
`KSEG_LOW` (defined in the manifest immediately before the first
segment `put`, read from the `-v1` `_Output.txt` symbol dump, the
same dump check_kernel_images.py already parses). The flat part is
the `.SYSTEM`; the tail is `KSEG`. `scripts/split_kseg.py`, called
from the Makefile's image rule for every manifest that carries a
segment; a manifest without `KSEG_LOW` produces no `KSEG` and is
not changed.

Why a separate file and not the `.SYSTEM`'s own tail: the harnesses
poke result cells at fixed addresses above the flat image BEFORE
boot (check_play.py:399, check_dd.py:131, pt_f40.py), and ProDOS's
whole-file load would overwrite them -- the exact failure that put
17 reds on the /dev branch. A separate file keeps the `.SYSTEM`'s
load window what it is today, keeps check_kernel_images.py's
ceiling semantics unchanged, and fails LOUDLY (a halt with a mark)
instead of silently when it is missing.

Staging: every build script that writes a `.SYSTEM` for a manifest
with a segment also writes `KSEG` beside it in the volume root
(`prodos.write(f'{root}/KSEG', ..., file_type=0x06,
aux_type=0xD400)`). 42 scripts use `root = f'/{CARRIER_VOL}'`; add
one shared helper rather than 28 copies of the write if the scripts
already share a module (imglock/check_manifests are imported by
them -- put the helper beside those). A script that misses a
segment-bearing image reds that image's gate at boot, by design.

### The loader

`KSEG_LOAD`, flat, in procfile5.s (linked exactly where the segment
is). It is `PBY_LOAD_RES` generalised: path, destination page,
length come from three cells instead of literals. At boot, PRC_INIT
calls it FIRST among the things that need the MLI (after the
io_buffer pool exists -- read the init order; MEASURE M2) with path
= `GET_PREFIX` result + `KSEG`, destination `$D400`, length = the
file's own EOF (`GET_EOF`, or read until a short read; a length of
zero or > 3072 is a failure). The prefix is captured once into a
kernel cell (`K_BOOTPFX`, 18 B: `/VOLNAME/` is at most 17 B; refuse
longer -- a maux volume name is a ProDOS volume name) so the same
path serves the reload after a tenant (F6). Failure = `PRC_HALT_CORE`
with a new `K_HALT_MARK` value, documented next to the others. An
image whose manifest has no segment has no `KSEG_LOW`; the loader
is still linked (procfile5.s is everywhere) and must be a no-op when
the segment length symbol is zero -- assemble-time, not a runtime
file check, so a MISSING file on a segment-bearing image is always
loud.

`PBY_LOAD_RES` becomes a call into the same routine with the
resident's parameters (`/BASIC/BYERES` today; keep its literal, it is
play-only) loading `BYE_BLOB_LEN` (768) bytes to `$D100`, not
`BYE_COMBO_LEN`. `byefull.bin` and the concatenation go away
(Makefile 468-476, build_play_image.py `BYERES_BIN`); `BYERES` is
`byeres.bin` again. The resident itself is untouched -- it is the
ALTZP-sensitive half and it works.

Reload after a tenant: in the kernel-side return path of `bye`
(procbye.s, after the main-memory restore and the /RAM
redisconnect, before the tick re-arm -- read the order; it must
run before ANY segment call), `jsr KSEG_LOAD`. On failure, halt
with the same mark: a kernel with a missing segment is not a kernel.

### The trampoline

One flat routine, `KSEG_CALL`, and one inline pointer per call site:

```
            jsr   KSEG_CALL
            da    KSEG_ROUTINE       ; the segment label
            ...                      ; resumes here, bank $C08B
```

`KSEG_CALL` pulls its return address, reads the pointer, selects
`LCBANK1_RAM` (one read -- the write-enable latch is already set
and stays set, docs/LANGUAGE-CARD.md), JSRs the target with A/X/Y
intact, re-selects `LCBANK2_RAM` on return WITHOUT disturbing the
carry or A (`lda` sets N/Z only; error returns are carry + A), and
returns past the pointer. Budget: ~30 B once, 5 B per site. The five
/dev dispatch sites (7 B each today as `cmp/beq/jmp`) become
`cmp/beq` + `jsr KSEG_CALL/da` + `rts`, or a branch to one shared
tail; the engineer picks the cheaper shape and records both numbers.

The two block-device MLI wrappers (`PMLI_RDBLK_CL`/`PMLI_WRBLK_CL`,
procmli.s) are the only flat routines the segment calls that open an
interrupt island. After their `sei` they re-select `LCBANK1_RAM`
before `rts` (F4's second half: never trust the MLI's `$D000`
compare; F5 says the island itself is bank-neutral, but the MLI's
own restore is a heuristic). Any future flat routine the segment
calls that runs an MLI call gets the same line.

### Rules for code in the segment

Print these at the top of every segment module. A routine that
cannot obey one stays flat.

1. No `sta ALTZPAUX`/`ALTZPMAIN` (F1). Calling a flat routine that
   flips ALTZP internally (BankCopy) is fine: it flips back before
   it returns, and the return address is on the main stack.
   **Amended 2026-09-27 (coordinator review of commit 5edd6d3,
   "PRC_BYE MOVES"):** if a routine's OWN body needs an ALTZP
   flip for ONLY a small fragment of itself (the rest is ordinary
   flat-safe logic), hoist just that fragment into a small flat
   helper and `jsr` it -- do not disqualify the whole routine from
   moving. `PRC_BYE`'s own trapframe-patch bracket (six lines,
   inside 700+ B of otherwise movable code) is the worked example;
   `PBY_PATCHFRM` (procbye.s) is the extracted helper.
2. No `lda LCBANK*` -- selecting the other bank unmaps yourself.
   RAMRD/RAMWRT flips are legal: LC fetch is ALTZP-governed, not
   RAMRD-governed (`learning:01KW1GTYGVYAPQRGS5P7J66RWD`).
   **Refined 2026-09-27 (same review):** reselecting `$C083`
   (`LCBANK1_RAM`, the SAME bank the segment already runs under)
   from code already running in the segment is a no-op and
   allowed -- `procbye.s`'s old "cheap insurance" reselect before
   stamping the resident is the worked example. Only selecting
   the OTHER bank (`$C08B`/`LCBANK2_RAM`) from inside the segment
   is fatal: that unmaps the very code that is running.
3. No `jsr MLI` with inline bytes (F4). Call the flat `PMLI_*`
   wrappers.
4. No data: no `ds`, no strings, no parmlists, no `dfb` tables that
   the MLI or BankCopy will read (F4, note 01M2MCYE...). Everything
   the segment reads or writes lives in the flat image or in a
   register.
   **Clarified 2026-09-27 (same review), not a new exception:** the
   hazard this rule guards against is a cross-bank dereference by
   something OUTSIDE the segment (the MLI reading inline bytes
   under the wrong bank, F4; BankCopy's own copyin/copyout refusing
   `>= $D000`). Data written by one segment-resident routine and
   read by ANOTHER segment-resident routine, with nothing outside
   the segment ever touching it, is not that hazard -- but it is
   still bound by a REAL constraint rule 4's original text did not
   spell out: it must not need to SURVIVE a `KSEG_RELOAD` between
   the write and the read (the segment is reloaded from disk
   wholesale on every `bye` return, which would overwrite a stray
   `ds` with disk content). `byelaunch.s`'s `BL2_PSTG` (written by
   `PRC_BYE`, read moments later by `BYE2_START`, same `bye` call,
   no reload in between) is the worked example -- and the bug that
   found this: Slice A1 moved it to flat BSS "for rule 4", which
   put it inside `BYE_LEAVE`'s own `$0200-$BEFF` poison range
   between the write and the read, corrupting every tenant launch
   silently. `BL2_REF`/`BL2_DST` (byelaunch.s's OTHER per-call
   scratch) stay flat on purpose: their own lifetime is entirely
   POST-poison and self-contained, so flat placement is genuinely
   safe for them, and moving them into the segment without a
   correctness reason would just be trading a stated rule for a
   handful of bytes -- checked and rejected on that basis.
5. No `cli`. The kernel is masked; islands are the wrappers' job.
6. Return with `rts` to the trampoline. No `jmp` out to `PRC_FAIL_A`
   or `KRN_EXIT`: report errors as carry set + A = errno and let
   the flat caller fail the call. (A routine that today ends in
   `jmp PRC_FAIL_A` is one edit away: `jsr`, then `rts`.)
   **Amended 2026-09-27 (same review):** this rule has ONE
   exception, a routine whose SUCCESS path LEAVES maux entirely --
   `PRC_BYE` issues a real MLI QUIT via `BYE_LEAVE`, IN THE SAME
   BANK (`byeres.s`'s resident occupies `$D100-$D3FF` of the
   identical Apple bank 2 the segment occupies at `$D400-$DFFF`),
   and never returns through its own call chain: the calling
   process's kernel stack is abandoned wholesale, and
   `BYE_BACK -> SCH_RESUME -> ` the next syscall/interrupt door
   re-establishes every LC and bank-select state from scratch. The
   trampoline's own missing `$C08B` reselect on that path is
   therefore moot -- nothing is left waiting for it. This exception
   covers ONLY the success path: every ERROR path in a routine
   built this way must still return with carry set + A = errno and
   go back through `KSEG_CALL` normally, exactly like any other
   segment routine -- `PRC_BYE`'s own error paths do.
7. Never touch `$D000-$D0FF` or `$D100-$D3FF` of bank 2 (F4, F7).
   **Clarified 2026-09-27 (same review):** the hazard is a
   cross-bank write landing in the WRONG bank's copy of that range
   (F4's own bank-identification-byte and QUIT-window concerns).
   `PRC_BYE` (segment-resident) writing the six/nine stamped cells
   at `$D30C+` is not that hazard: the write happens with bank 2
   (`LCBANK1_RAM`) selected -- the SAME bank the segment itself
   runs under, per rule 2's own refinement above -- so it is an
   ordinary same-bank store into the resident it is about to hand
   control to, not a cross-bank corruption. The rule still bans
   anything that could land in `$D100-$D3FF` from the WRONG bank,
   or that touches `$D000-$D0FF` at all (ProDOS's own bank-ID byte,
   F4).
8. No self-modifying code, even though the LC is write-enabled.
9. Every caller of a moved routine goes through `KSEG_CALL`; grep
   for every `jsr`/`jmp` to the label before moving it, tree-wide
   (memory `grep-whole-tree-before-changing-a-contract`).
   **Refined 2026-09-27 (same review):** this applies to callers
   OUTSIDE the segment. A segment-resident routine calling ANOTHER
   segment-resident routine (both in the same bank, e.g. `PRC_BYE`
   calling `PRC_RAMRECONN`, both in kbye.s) needs no `KSEG_CALL` at
   all -- it is an ordinary same-bank `jsr`, no bank switch
   required. `KSEG_CALL` is specifically for the FLAT-to-segment
   direction.

### What moves, in order

1. **`byelaunch.s`** (~360 B real content, `BYE2_ORG`). It is
   already a bank-2 blob at `$D400`; it becomes the first segment
   module in playtest.s's manifest, assembled at its real address
   inside the kernel's own symbol space. The hand-maintained cells
   `BL2_PATH_A` and `BYE2_*` in inc/byeres.equ become labels
   (`byeres.equ`'s "read off the -v1 listing after every edit"
   discipline for those cells retires). Its check_lc.py exemption
   stays: it genuinely selects read-ROM for the tenant, from a
   page-1 stub. Its `org` and its own trailing `ds` cells
   (`BL2_REF`/`BL2_DST`/`BL2_PSTG`, 68 B) violate rule 4 -- move
   them to flat BSS in procbye.s; they are written by procbye.s
   anyway.
2. **The OFT_BLK bodies** from the /dev branch, 1,036 B measured
   (docs/DEV-BLOCK-NOTES.md "Byte breakdown"): `PDEV_TRY_BLK`,
   `PBLK_PREP`, `PBLK_ADVANCE`, `PRC_BLK_READ`, `PRC_BLK_WR`,
   `PRC_BLK_SMARK`, `PRC_BLK_GMARK`, `PRC_BLK_GEOF`, `PALOBJ_BLK`.
   NOT the two MLI wrappers (rule 3 -- they carry the inline bytes),
   not the parmlists, not the 68 B of BSS, not the dispatch glue.
   Audit each body against rules 1-9 before moving it; PRC_BLK_READ
   and PRC_BLK_WR call BankCopy (rule 1's allowed case) and the
   wrappers (rule 3).
3. **Only if needed for the headroom floor below:** cold paths of
   procbye.s that pass the rules (bank allocation orchestration,
   /RAM reconnect and redisconnect logic that calls wrappers, the
   refusal path). PBY_CHK_STAMP/PBY_WR_STAMP flip ALTZP and stay.
   Name what moved and why in the notes.

### Budget and gates

- `KSEG` per image: `<= 3072` B, asserted by split_kseg.py (a
  segment that crosses `$E000` is a build failure, not a warning).
- check_kernel_images.py: the ceiling semantics stay (the `.SYSTEM`
  is the flat part). Re-measure every `KNOWN_OVERRUN`; the /dev
  branch's raises (MAUXEXPR 1742, MAUXEDTEST 1446, and the four new
  entries) come back DOWN to their measured values with the bodies
  gone -- expected on the order of +120 B over main, which is the
  glue + BSS that must stay flat. Record each number.
- **MAUXPLAY.SYSTEM must end at least 512 B below `PT_HOLD`
  (`$97E8`)** after /dev lands. New assertion in
  check_pt_hold_headroom, with the floor named as a constant and
  its reason (docs/PROJECT-STATE.md's "zero headroom" paragraph).
  If the moves in 1-2 do not reach it, do 3. Report the achieved
  number.
- **`check-kseg`** (new gate, box + Mac): boots the play image;
  (a) peeks `$D400..` under bank 2 (verilogapple `peek` with the
  bank-2 LC selected -- if `peek` cannot name the LC bank, read
  through a harness routine that copies 3 KB of bank 2 to a main
  scratch area on request, playtestb.s's own suite mechanism) and
  compares byte-for-byte with `build/KSEG` for that image;
  (b) TEETH: stage a KSEG truncated by one page and require the
  boot to halt with the new mark (peek `K_HALT_MARK`), then restore;
  (c) a process that has bank 2 selected (K_LCBANK bit set --
  check_lcbank.py's fault injection is the precedent) makes a
  segment call and gets the right answer, and its own bank is back
  on resume (check-lcbank already covers the resume half; cover the
  call half here);
  (d) after `bye /BASIC/TENANT.SYSTEM` returns (check_tenant.py's
  flow), (a) holds again, byte-for-byte -- the reload.
- check-devblk, check-dd, check-tenant, check-bye, check-rambye,
  check-oftbye, check-lcbank, check-lc, check-altzp, check-modules,
  check-dialect, check-ascii, check-nas-selfmake, check-nas-* -- all
  green in ONE sweep, on the box.

### Docs to update in the same change

docs/MEMMAP.md sec 1.2 (the bank-2 row: `$D000-$D0FF` ProDOS bank
ID, `$D100-$D3FF` QUIT window/`bye` resident, `$D400-$DFFF` kernel
cold segment), docs/LANGUAGE-CARD.md (a section: the segment and
why the wrappers re-select), inc/byeres.equ (retire `BYE2_*`,
`BYE_COMBO_LEN`, `BL2_PATH_A`), docs/BYE.md item 6 (the escape
hatch is now the segment), docs/DEV-BLOCK.md (status: BUILT, on the
segment; the cost paragraph replaced by the measured numbers),
docs/PROJECT-STATE.md, docs/README.md's gate list. Keep every file
ASCII.

## Landing /dev on it (done)

The `OFT_BLK` bodies moved into the segment per "What moves" item 2,
and the `KNOWN_OVERRUN` raises the flat version needed were replaced by
the re-measured values (the MAUXPLAY entry went away entirely). The
check-dd red the flat version showed was a harness-cell overlap, not a
/dev defect (Library notes, last bullet).

Two gaps the flat version named, still open and not this slice's job: the `$F0` DEVLST mask has no teeth on verilogapple
(clean type nibbles) -- a dirty-byte boot poke like check_ramdis.py's
would give it some; and `SYS_GET_MARK`'s OFT_BLK arm is
code-reviewed, not exercised (nulib2's `.SDK` slice will call it).

## Cells and equates

The equ files below carry only a terse one-line-per-equate comment
now (2026-09-28) -- every unit that `put`s a shared equ file pays for
its raw byte size in `check_librel.py`'s `MERLIN_SOURCE_BUDGET`
accounting (`os.path.getsize()` on the put file, no comment-strip;
`build_librelas_image.py`'s own squeeze-based `as`-window budget DOES
strip full-line comments first, so it is unaffected either way, but
the real-Merlin budget is not the only one and the house convention
is to keep shared includes terse regardless of which gate is
watching this week). The full explanation for each lives here.

- **`inc/mm.annex2.equ` `OFT_BLK equ 4`** -- the OFT_TYPE tag for a
  `/dev/sNdM` block device (docs/DEV-BLOCK.md): carries a `unit_num`
  and a 24-bit byte position, no ProDOS refnum.
- **`inc/mm.hw.equ` `KSEG_ORG equ $D400`** -- the kernel cold
  segment's base (LC bank 2, `$D400-$DFFF`). `KSEG_MAXPG`/
  `K_HALT_KSEG` moved to `src/kernel/procdev.s` 2026-09-27
  (coordinator review, DECISION 1): scoping is by MODULE CHOICE
  (`procdev.s`, real, `put` only by a manifest carrying the segment;
  `procdevs.s`, stub, `put` by every other full-kernel manifest), not
  `do ]KSEG_WANT ... fin` -- nas has no `do`/`fin` directive at all
  (its own directive table has no `D_DO`/`D_FIN`), and nas is the
  assembler of record (docs/NAS.md). `KSEG_ORG` stays in
  `inc/mm.hw.equ`, not with its siblings in `procdev.s`:
  `playtest.s`'s own top-level `org KSEG_ORG` is CROSS-MODULE usage
  from a REL-object point of view, and nas-librel's own export
  checker refuses to export an EQUATE another module (or the
  top-level manifest) references (found the same round,
  check-nas-librel).
- **`inc/proc.const.equ` `PBY_P1BUF equ PMLI_XFER_BUF`** --
  procbye.s's own page-1 stage buffer, aliased onto
  `PMLI_XFER_BUF`'s first 128 bytes. Moved here 2026-09-27 from
  procbye.s: kbye.s also references it, and nas-librel's REL export
  checker refuses a cross-module EQUATE. See procbye.s's own
  `PBY_WR_P1` header for the non-overlap argument that makes the
  alias safe.
- **`inc/proc.const.equ` `SYSNAME280 equ $0280`** -- ProDOS's own
  system-program-name cell; a real `.SYSTEM` launch stamps this the
  same way. Moved here from byelaunch.s 2026-09-27 (coordinator
  review, check-nas-librel): `src/test/byetenant.s` (the tenant
  fixture) also references it, and nas-librel's own export checker
  refuses a cross-module EQUATE.
- **`inc/proc.const.equ` `MLI_BLK_UNIT`/`MLI_BLK_NUMLO`/
  `MLI_BLK_NUMHI`** -- READ_BLOCK/WRITE_BLOCK field offsets
  (procmli.s `PMLI_RDBLK_CL`/`PMLI_WRBLK_CL`, TRM 4.7.1/4.7.2):
  `data_buffer` is always `PMLI_XFER_BUF`, fixed in the parmlist, so
  only `unit_num`/`block_num` need per-call equates.
- **`inc/sc.proc.equ` `FDST_BLK equ 4`** -- docs/DEV-BLOCK.md: a
  `/dev/sNdM` block device (`mm.annex2.equ`'s `OFT_BLK`). `fdstat`
  tells a block fd apart from a file; the block COUNT is a separate
  question, answered by `SYS_GET_EOF` the same way a file's byte
  length is -- see `PRC_GETEOF`'s docs/DEV-BLOCK-NOTES.md entry for
  why fdstat itself stays a 1-byte type tag rather than growing a
  parmlist every existing caller would have to widen.

## What this does NOT do

- No second segment, no overlay, no relocation of the harness cell
  block. 3 KB is the cap; when it is full, the next lever is a
  discussion, not a bigger number.
- No change to the resident (`byeres.s`) or to the `$1000`
  trampoline contract.
- No process-visible change: userland cannot see the segment, and
  `CPILC`/`CPOLC` keep refusing `>= $D000`.

## Update 2026-10-08 (PRODOS-CASE)

`PCASE_MASK` (69 B, kdevblk.s) now lives in the segment: KSEG padding
is 10 B (was 79 B). It reads PRC_PATHBUF and writes the flat cell PC_W
(procdev.s); P_PTR1/P_PTR2 are its only scratch. See
docs/PRODOS-CASE-NOTES.md for the flat cost that could not follow it.
