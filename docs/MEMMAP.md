# maux memory map and bank-ownership spec


NOT PUBLISHED: refs/ -- the notebook snapshot cited below is kept in
the project tree, not in the public repository.

Status: byte-accurate v1 spec (task #2, docs/TASKS.md). Downstream tasks (#3
$FFxx/syscall ABI, #4 bank-clone primitive, #5 allocator, #6 scheduler) cite
this document for addresses -- do not re-derive them independently.

**Task #11 amendment (docs/PRODOS-SPIKE.md, ProDOS MLI coexistence spike):**
the main-budget and annex-budget tables (sec 1.3, sec 2.2) and sec 1.2's `$FF00-
$FFFF` claim are amended in place, marked inline -- the ProDOS ruling
(`docs/ARCHITECTURE.md`'s Filesystem/I-O section, landed before this task)
cut the homegrown V6 fs + ramdisk this document originally budgeted for;
task #11 is the first task to reconcile this document's numbers with that
already-landed ruling, empirically (`make check-mli`), rather than leaving
a silent divergence. Every amendment is marked `**task #11 amendment**` or
`~~struck through~~` in place -- nothing was silently deleted.

**Console/video amendment (2026-08-15, docs/CONSOLE.md):** the old
"V1 ships no graphics, so hires pages are ordinary kernel RAM" ruling is
softened in place. Text-only V1 may temporarily reclaim hires apertures, but
new allocations should avoid them, and the console/graphics/BASIC track must
evacuate them before enabling Apple graphics or display-owner compatibility.
Text page 2 (`$0800-$0BFF`) is only a soft reserve; text page 1 and both hires
pages are the hard reserve.

Every address and size below has a matching symbol in one of the
`inc/mm.*.equ` files. `make check-memmap` proves merlin32 accepts
all of them.

**File split (2026-08-20, docs/SELFHOST-CONVERSION.md phase 1, task #8's
`as` v1 window-arithmetic risk note in that document's sec 7).** The
symbols below used to live in one 35888-byte `inc/memmap.equ`, PUT
whole by every compilation unit regardless of which symbols it actually
used -- and PUT never reclaims its window cost
(`learning:01M0CC62FZ351EBXCAAKX52KAJ`), so the full 35888 bytes were
charged against every unit's source/symtab window, including trivial
userland programs that reference exactly one symbol. Split per concern,
the grouping DERIVED from a reference-set scan (which `src/kernel`,
`src/bin`, `src/liba`, `src/test` files actually name each symbol) rather
than imposed from the section headings below:

| file | docs/MEMMAP.md section | referenced by (representative) |
|---|---|---|
| `inc/mm.procbank.equ` | sec 3 (`LOAD_BASE`, argv header/ptrs only) | every `src/bin/*.s` program (via `inc/startup.equ`), `src/kernel/procspawn*.s` |
| `inc/mm.procbnk2.equ` | rest of sec 3 (argv string/ceilings, heap top, `$BF00` overlay, process LC storage, the `$FFxx` page `dum` block) | `src/kernel/procspawn.s`/`procspawn2.s`, `src/kernel/lazyfree.s`; requires `mm.procbank.equ` PUT first (`ARG_MAX` derives from `LOAD_BASE`). `SB_WINDOW` is gone with the spawn cache (`docs/STICKY.md` sec 27) |
| `inc/mm.hw.equ` | sec 4, sec 4a, sec 4b (softswitch triggers + status registers) | nearly every `src/kernel/*.s` module, plus `src/bin/as.s`/`ld.s` (`LCBANK2_RAM`) |
| `inc/mm.mli.equ` | sec 3b (`MLI`, `MOUSE_*`) | `src/kernel/mli.s`, `mouse.s`, `timer.s`, `procfd*.s` |
| `inc/mm.mlibuf.equ` | sec 1.3 MLI I/O buffer constants | `src/kernel/process.s`, `procfd*.s` |
| `inc/mm.annex.equ` | sec 2.1, sec 2.2, sec 2.2a (annex address bases, PCB/CWD/sticky/pipe/OFT structures) | `src/kernel/sched.s`, `process.s`, `procfd*.s`, `procfile*.s`, `procspawn*.s`, `sticky*.s`, `src/bin/ps.s` |
| `inc/mm.main.equ` | sec 1, sec 1.1, sec 1.1a, sec 1.1b, sec 1.2 (main flat layout + LC region budget/documentation constants) | nothing outside `src/check.memmap.s` -- kept as one file since only that gate PUTs it |

Symbols whose reference sets were disjoint landed in different files;
symbols always used together (e.g. the whole PCB/CWD/OFT/pipe structure
graph, which every one of its referrers touches several fields of at
once) stayed together rather than being split file-per-symbol. A missing
`put` fails loudly at assemble time with an undefined symbol -- deliberate,
not a bug: no manifest PUTs a file "just in case."

Library handles consulted for this task (fetched live, all still `active`,
bodies match `refs/library-snapshot-2026-08-13.md` verbatim):
`learning:01KW1GTYHGXMBZNR6DMQB2F712` (80STORE routing / $C073 unconditional),
`learning:01KYYGZ8C3FQFWCF3S0FQ0DJ7B` (aux bank 0 is not free memory; TN #26),
`learning:01KYYJ98T5R0M9K1AW2550M132` (RamWorks bank numbering, $C073 facts).
Own searches run per HACKING.md's notebook rules (language-card bank selection, 80STORE
steady state, PCB layout, $FFxx/vector conventions) surfaced nothing beyond
those three plus background TN material already covered by
`learning:01KW1GTYGP8MHN9YAE5JTSP62Z` -- no new deposit-worthy gap found
during this task (see DEPOSIT CANDIDATES at the end for one adjacent,
non-blocking finding).

---

## 0. How to read the budget tables

"Judgment call" markers flag sizes this task invented because no earlier
document fixed them (inode struct shape, PCB entry shape, pipe count, kernel
code size). They are explicit so review can challenge the number without
having to reverse-engineer where it came from. Everything else (video-page
locations, $C073 semantics, the one-page invariant, TN #26) is load-bearing
`[fact]` from the cited learnings or `docs/ARCHITECTURE.md`.

All sizes are decimal bytes; addresses are hex.

---

## 1. Main 64K -- kernel home

Per `docs/ARCHITECTURE.md`'s ownership table, main 64K holds: kernel code,
main ZP/stack, LC RAM, video pages, disk buffers. Nothing process-shaped
lives here -- PCBs and the inode cache are annex (aux bank 0), per sec 2.

### 1.1 Flat layout ($0000-$BFFF, 49152 bytes)

| region | size | contents |
|---|---:|---|
| `$0000-$00FF` | 256 | kernel ZP (live only while `ALTZP`=main, i.e. whenever the kernel is actually executing) |
| `$0100-$01FF` | 256 | kernel stack |
| `$0200-$02FF` | 256 | kernel low globals: `curbank` (authoritative current-bank shadow of the write-only `$C073`), VBL tick counter, timer-source-probe result, boot flags (`HAD_RAM`), scratch |
| `$0300-$03FF` | 256 | reset-vector-chain page -- reserves `$03F2`/`$03F4` for the AE-manual-documented `$C073`-reset-persistence intercept (`learning:01KYYJ98T5R0M9K1AW2550M132`: "zeroed on power-up but NOT on reset... manual supplies a `$3F2` patch"); this is the mechanism `docs/ARCHITECTURE.md` calls "reset recovers via kernel-owned main $03F2" |
| `$0400-$07FF` | 1024 | **text page 1 -- HARD video reserve, always main, hardware-fixed.** Apple 40-column console fallback uses this page |
| `$0800-$1FFF` | 6144 | kernel code segment A. Its first 1K overlaps **text/lores page 2 -- SOFT video reserve**; that is acceptable because page 2 has no native console role and is not strategically comparable to hires page 2 |
| `$2000-$3FFF` | 8192 | **hires page 1 -- HARD video reserve / temporary text-only V1 reclaim.** Historically `K_CODE_B` / MLI-buffer slack; new allocations should avoid it, and graphics/BASIC display-owner work must evacuate it first |
| `$4000-$5FFF` | 8192 | **hires page 2 -- HARD video reserve / temporary text-only V1 reclaim.** More important than text page 2 because Apple graphics software actually uses it (`HGR2`, page flipping, future double-hires companion rules) |
| `$6000-$BFFF` | 24576 | kernel code segment C + remaining structures below, preferred non-video main flat space |
| `$C000-$CFFF` | 4096 | **not RAM** -- I/O soft switches `$C0xx` + slot/expansion ROM `$C100-$CFFF`. Always main, never routed to aux by any switch. Excluded from the budget entirely (the one-page invariant, `docs/ARCHITECTURE.md`) |

### 1.1a Main-context kernel zero-page allocation map (task #13, code review C2)

The 256-byte kernel-ZP window (`$0000-$00FF` above) is claimed piecemeal by
whichever kernel module needs main-context ZP scratch while `ALTZP`=main:
task #3's entry/exit machinery, task #6's scheduler, task #12's
process/file-call bridge. Each module's own `equ` statements are the single
source of truth for the exact per-cell addresses (`src/kernel/entry.s`,
`src/kernel/sched.s`, `src/kernel/process.s`) -- this table exists because,
per the second-chair review of the process/ProDOS state
(code review C2), those three modules' allocations had grown
real without ever being collected into one collision map, leaving "don't
casually consume ProDOS's reserved zero page" as a prose warning nobody
could check mechanically. `inc/mm.main.equ` sec 1.1a now names each
module's claimed range as a machine-checkable symbol, and
`make check-memmap` (`scripts/check_memmap_zp.py`) asserts the table below
by construction, every run -- see that script's own header for why a blind
grep over `equ $XX`-shaped lines was tried and rejected (it flags
`src/kernel/process.s`'s `MLI_ERR_EOF equ $4C`, an MLI error CODE and not
an address at all, as a false collision, since it happens to be a
two-hex-digit value inside the reserved range below).

| range | claimed by | symbol pair | contents |
|---|---|---|---|
| `$3A-$4E` | **RESERVED -- never main-ZP kernel** | `ZP_RESERVED_PRODOS_LO/HI` | the ProDOS 8 MLI's own working set (TRM ch 3.3.1: `$3A-$3F` disk-driver, never restored; `$40-$4E` MLI working set, claimed restored but `docs/PRODOS-SPIKE.md` answer (a) found 2 of 15 bytes empirically are NOT, even for the cheapest isolated call). The bright line every future main-ZP allocation must cross explicitly -- see that document's dated correction note for why this fact predates its first appearance as a maux symbol |
| `$D0-$DF` | `src/kernel/process.s` | `ZP_PROCESS_LO/HI` | process syscalls / file-call bridge temporaries (`P_PTR1`/`P_PTR2`/`P_PTR3`, `P_TMP`, `P_TMP2`, `P_IDX`, `P_COUNT`, `P_PID`, `P_BANK`, `P_FD`, `P_PIPE`, `P_OBJ`, `P_CHAN`) |
| `$E0-$EE` | `src/kernel/sched.s` | `ZP_SCHED_LO/HI` | scheduler/PCB-access temporaries (`K_PCB_PTR`, the `SCHED_SWITCH` in/out pointer and SP/bank/pid cache cells, `K_PCB_TMP`/`K_PCB_TMP2`, `K_SW_CHAN`, `K_WAKE_COUNT`) |
| `$EF-$F1` | `src/kernel/sched.s` | -- | `K_CWD_PTR` (2 bytes, computed cwd-table pointer) + `K_CWD_TMP` (`CWD_PTR_FOR` scratch) -- STALE row fixed 2026-09-15: previously listed as unclaimed headroom, but these two cells already lived here |
| `$F2` | *(unclaimed)* | -- | 1 byte of headroom between sched.s's and entry.s's ranges |
| `$F3-$FC` | `src/kernel/entry.s` | `ZP_ENTRY_LO/HI` | syscall entry/exit cross-`ALTZP`-flip cells (`K_RESULT`, `K_RESULT_ERR`, `K_VEC`) + copyin/copyout scratch (`K_CPY_PROC`, `K_CPY_MAIN`, `K_CPY_LEN`, `K_CPY_ERR`) |
| `$FD-$FF` | *(unclaimed)* | -- | 3 bytes of headroom |
| `$00-$39`, `$4F-$CF` | *(unclaimed)* | -- | free, subject to the same reserved-range rule above and the `$00-$1F` ROM/monitor convention entry.s's own header already avoids |

### 1.1b Kernel stack-floor invariant (task #13, code review stack-floor finding)

`src/kernel/entry.s`'s page-1 copy-stub relocation (task #12 handoff:
`COPYIN_ENTRY`/`COPYOUT_ENTRY` moved from main LC to `$0100`/`$0140` so
ProDOS's own LC-resident MLI code isn't corrupted, docs/PRODOS-SPIKE.md
answer (b)) put **resident code in the same physical page as the kernel
stack** (`$0100-$01FF`, `K_STACK` above). The kernel's `LDX #$FF: TXS`
still sets the stack top to `$FF`, but a deep enough call chain now
descends into live code, not just idle bytes -- if `SP` ever reaches or
passes below `$016F` (`COPYOUT_ENTRY`'s last byte), it starts clobbering
the copy-stub code that same syscall may still need before it returns.
the code review's own framing: "the page-1 copy stubs halved the
kernel stack."

| invariant | value | basis |
|---|---:|---|
| kernel-stack floor (`K_STACK_FLOOR`) | `$0180` | 16 bytes of margin above `COPYOUT_ENTRY`'s measured end (`$0170`) -- a round boundary, not a tight fit. Exactly the page's midpoint, matching the "halved" framing precisely |
| usable kernel-stack budget (`K_STACK_BUDGET`) | 128 bytes | `$01FF-K_STACK_FLOOR+1` -- HALF the page-1 window's nominal 256 bytes |
| measured worst-case depth | 11 bytes | static JSR/PHA trace (not just the happy path -- see below), `syscall entry -> spawn -> PROC_LOAD_FILE_IMAGE -> [MLI read error] -> PROC_CLOSE_RAW_REF_A -> PROC_MLI_CLOSE_CALL -> jsr MLI`. `SP` reaches `$F4`, 116 bytes of margin above the `$80` floor |
| MLI's own additional stack-use headroom | >=64 bytes (TRM's own convention) | ProDOS 8 TRM sec 5.2.1 "Using the Stack" (fetched live this task, artifact `d82965d865557730323115a79ec150c5449f13a335c258273dcb0171fa692ff8`): *"the stack is stored in page $01 of memory, from the high byte of the page going down... For maximum interrupt efficiency, a system program should not use more than the upper 3/4 of the stack."* I.e. ProDOS's own convention keeps total stack usage within the top 192 bytes (`SP >= $40`), implying resident system code (the MLI included) is designed to operate within whatever headroom that leaves below the caller's own depth. maux's measured 11-byte consumption at the point it calls into the MLI leaves 181 bytes of margin even under this looser, TRM-stated convention -- vastly more than any plausible internal MLI usage |

**Worst-case path, traced (not the shallow happy-path number):** the
naive "happy path" trace (`spawn -> PROC_LOAD_FILE_IMAGE`'s successful
`MLI READ` then `BankCopy`, sequential not nested) peaks at only 8 bytes.
The TRUE worst case is 3 bytes deeper, reached only on the **read-error
cleanup branch** (`:readerr`/`:eofok`'s failure arms in `PROC_LOAD_FILE_
IMAGE`): `pha` (+1) then `jsr PROC_CLOSE_RAW_REF_A` -> `jsr PROC_MLI_CLOSE_
CALL` -> `jsr MLI` (+6), all while already 4 bytes deep from `KERNEL_
ENTRY`'s dispatch `jsr` + `PROC_SPAWN`'s own `jsr PROC_LOAD_FILE_IMAGE`.
This is a genuinely reachable path (any MLI error mid-load -- a corrupted
or truncated ProDOS file being spawned -- triggers it), so it is the
number that matters for the invariant, not the shallower success case.
This kernel has no recursion anywhere in its call graph, so a static
push-count trace is exact, not an estimate -- cross-checked once against
the emulator (a shallower sibling call, the ordinary `read()` syscall's
own `MLI READ`, measured via `regs`/`until_pc` at `SP=$FB`, 4 bytes
consumed -- matching this trace's methodology exactly at that shallower
point, `S = $FF - 4`).

**Enforcement:** `make check-syscall` (`scripts/check_syscall.py`)
mechanically asserts `COPYOUT_ENTRY + COPYOUT_LC_LEN <= K_STACK_FLOOR` from
the assembled symbol table, every run -- a CHECK-TIME assertion rather
than an assemble-time `ds` guard, because a `ds` expression that must
stay non-negative on the safe side of this invariant would EMIT stray
padding bytes into the live kernel image whenever there is slack (there
currently is, 16 bytes) -- actively harmful as a permanent fixture, not
just unnecessary. The DYNAMIC half of the invariant (no call chain ever
actually descends past the floor) is verified by this task's own trace,
recorded here for the next task to extend rather than silently
re-derive -- it is not, and cannot cheaply be, mechanically re-verified
by a grep the way the static byte-budget half is.

**Console/video amendment (2026-08-15):** `$2000-$3FFF` (hires page 1) and
`$4000-$5FFF` (hires page 2) are no longer treated as ordinary long-term
kernel RAM. Text-only V1 can keep using already-claimed space there while the
console remains text-only, but this is a named debt, not a permanent ownership
ruling. New kernel allocations should prefer `$0800-$1FFF` and `$6000-$BFFF`;
graphics, hosted BASIC display ownership, or virtual-console graphics must
renegotiate and evacuate both hires pages first. Text/lores page 2
(`$0800-$0BFF`) is only a soft reserve: historically much less important than
hires page 2, and not worth distorting the ABI around.

### 1.2 Main LC region ($D000-$FFFF, 16384 bytes -- separate physical RAM banked over the same logical addresses)

| region | size | contents |
|---|---:|---|
| `$D000-$DFFF` bank 1 | 4096 | unallocated -- headroom for kernel code overflow (not needed by V1's estimated footprint, see sec 1.3) |
| `$D000-$DFFF` bank 2 | 4096 | **NO LONGER unallocated (docs/KSEG.md, 2026-09-27)**: `$D000-$D0FF` is ProDOS's own bank-ID byte (untouched); `$D100-$D3FF` is the QUIT window / `bye` resident (docs/BYE.md); `$D400-$DFFF` (3072 B) is the kernel cold segment (docs/KSEG.md) -- code reloaded from `/BASIC/KSEG` on every boot and after every tenant return, selected via `$C083` (`LCBANK1_RAM`) and left write-enabled the same way as bank 1 above |
| `$E000-$FEFF` (LC common) | 7936 | unallocated headroom, **except**: houses the reset-time init trampoline (small, see below) if kernel code segments A-C run short |
| `$FF00-$FFFF` | 256 | main's own hardware vector page. **Not a process-style `$FFxx` stub** -- main is never entered via `JSR $FF00` or a bank-switch IRQ door; it is already "home". Holds only the 6-byte hardware vector table (`$FFFA-$FFFF`: NMI/RESET/IRQ) pointing directly into kernel code segments A-C, plus whatever cold-boot trampoline gets the LC RAM-read/write state and `curbank`/`$C073=0` initialized before the flat kernel code runs. Byte-exact stub content is task #3's deliverable; this page's *shape* (vector table only, no register-frame dance) is fixed here because main never receives the two-door trapframe protocol that process banks do |

Main's LC is not counted in the flat-RAM budget below -- it is genuinely
spare capacity, quantified so review knows it exists and roughly how much
(16128 bytes minus the 256-byte vector page = **15872 bytes of untouched
headroom** if V1's code estimate in sec 1.3 turns out low).

**TASK #11 AMENDMENT -- the `$FF00-$FFFF` row above describes the
ProDOS-LESS boot path only, which is NOT how v1 actually boots.** This
document's original text (and task #3's own working implementation,
`src/test/syscalltest.s`'s `STAMP_MAIN`, which really does copy a full
256-byte template into `$FF00-$FFFF` at boot) assumed main's vector page
starts life BLANK -- true for the raw-SmartPort-block boot path task #1-#6
were built and tested against, but `docs/ARCHITECTURE.md`'s Filesystem/I-O
and Boot/hosted-mode sections (landed the same day as this document, ProDOS
ruling) already supersede it: **"maux always boots via ProDOS 2.4... the A7
lifecycle contract... is the boot contract"** for v1. `docs/PRODOS-SPIKE.md`
(task #11) is the first task to actually MEASURE what that means for this
page: booting genuine ProDOS 2.4 and peeking `$FF00-$FFFF` before touching
it shows **252 of 256 bytes already occupied by ProDOS's own resident
code** -- this page is emphatically NOT free headroom once ProDOS is
resident, and the "whatever cold-boot trampoline" framing above does not
apply to v1's real boot path at all.

**Ruling (task #11, empirically validated by `make check-mli`): under
ProDOS residency, maux's main-context IRQ installation is a SURGICAL
2-byte patch of `$FFFE`/`$FFFF` only** (the IRQ/BRK vector), performed
AFTER ProDOS's own boot completes, via the same LC double-read
write-enable idiom `src/kernel/entry.s`'s `INSTALL_COPY` already uses
(write-enable, patch the 2 bytes, restore write-protect) -- never a
whole-page stamp, never touching NMI/RESET or any of the other 254 bytes,
which remain ProDOS's own. See `docs/PRODOS-SPIKE.md` answer (b) for the
full reasoning (ALLOC_INTERRUPT considered and rejected) and the measured
$252/256$ occupancy figure's provenance. This ruling does not change
sec 3.3's `$FFxx` process-bank page at all -- that page is a DIFFERENT
physical page (inside each aux bank, ALTZP-selected) untouched by ProDOS,
which only ever resides in MAIN.

### 1.3 Main budget total (the MUST-INCLUDE kernel BUDGET)

| item | size | judgment call? |
|---|---:|---|
| kernel text/code (spawn/exit/wait, open/read/write/close/creat/unlink/readdir/pipe delegated to the resident ProDOS MLI under a lock -- task #11 ruling, see below -- plus tty driver, VBL scheduler, BRK trap, boot/probe/allocator glue) | 12288 | **yes** -- no code exists yet to measure; 12 KiB is a working estimate for a "summer project" kernel per `docs/ARCHITECTURE.md`'s V1 scope fence. Task #3+ code that blows this budget eats into the slack below before it needs to renegotiate this document |
| MLI file I/O buffers (4 x 1024-byte, page-aligned) -- **task #11 amendment, replaces the line below** | 4096 | yes -- TRM 4.5.1 fixes the 1024-byte page-aligned SIZE as fact (one buffer per concurrently OPEN file, live for the file's whole open lifetime, not just one call); the COUNT (4) is this task's own judgment call, sized against v1's shell + six utils' worst-case concurrent-open-file count, not a measured requirement. See `docs/PRODOS-SPIKE.md` answer (e) and `inc/memmap.equ`'s `MLI_IOBUF_*` for the full accounting. `make check-mli` exercises ONE such buffer, reused sequentially -- see that answer's own caveat on why >1 is sized by policy, not replayed in the gate. |
| ~~disk/ramdisk I/O staging buffers (2 x 512-byte block buffers)~~ | ~~1024~~ | **REMOVED, task #11 amendment**: obsolete since the ProDOS ruling (commit 32fd146) cut the homegrown V6 fs + ramdisk this line served -- ProDOS's own resident MLI owns disk I/O staging internally, in memory this document makes no claim on (measured empirically at $FF00-$FFFF: 252/256 bytes occupied, `docs/PRODOS-SPIKE.md` answer (b)) |
| bank-clone bounce buffer (sec 4 of ARCHITECTURE: "bounce via main") | 256 | yes -- one page, matches the ~20 cyc/byte page-at-a-time copy shape |
| bank free-list / allocator table (1 byte/bank x 128, dense-modern-card worst case -- $C073 is a 7-bit register, 128 is the hardware ceiling) | 256 | yes -- sized to the hardware max, not the period-card sparse max ($77), so the allocator never needs a second table shape for dense reproductions |
| tty low-level state (cursor row/col, cooked flags, small input line buffer) | 160 | yes -- current first slice uses 136 bytes (`row`, `col`, committed input length/position, edit length, cursor save/visible, EOF-pending flag, 128-byte line buffer); budget rounds up for raw/noecho mode flags |
| MLI transfer/staging buffer (`PMLI_XFER_BUF`, fixed at `$7000`, immediately after the 4 io_buffers at `$6000-$6FFF`) -- **task #16 addition, docs/PROCIO.md K1: never entered in this table before, at either its old 128B or new 512B size** | 512 | yes -- `PMLI_XFR_SIZE`/`PMLI_XFER_BUF` (`src/kernel/process.s`) bounces disk bytes between ProDOS's io_buffer and a process bank via `BankCopy`; K1 raised it 128->512 (one ProDOS block, block-aligned) to cut `PRC_FILE_READ`/`PRC_FILE_WR` and `PRC_LD_FL_IMG`'s MLI-call count 4x per request. Verified empirically (`merlin32 -v1` build of `src/test/fileproctest.s`, 2026-08-20, the exact `KERNEL_PROC_MODS` set `MAUXSH.SYSTEM` ships): this kernel configuration's own code+data ends at `$567F`, and nothing else occupies `$6000-$71FF` -- the 512B buffer fits with ~2.4KB of margin below it, inside `K_CODE_C` (`$6000-$BFFF`) |
| **subtotal allocated** | **17568** | |
| **available flat main space** (`$0800-$BFFF`, including temporary hires reclaim) | **47104** | fact (arithmetic) |
| **text-only slack, including temporary hires reclaim** | **29536** | |
| **available outside HARD video reserve** (`$0800-$1FFF` + `$6000-$BFFF`) | **30720** | console/video amendment -- excludes `$2000-$5FFF`, keeps soft page-2 reserve available |
| **slack outside HARD video reserve** | **13152** | enough for the current budget, but much less generous |
| main LC headroom (sec 1.2, unallocated **except see the task #11 amendment note in that section -- this headroom claim no longer holds for `$FF00-$FFFF` once ProDOS is resident**) | 15872 | additional, not counted above |

**Bottom line: text-only V1 still has 29536 bytes of flat slack if it keeps
borrowing the hires apertures** (was 33152 before the task #11 MLI-buffer swap,
30048 before task #16 finally entered the MLI transfer buffer into this table
-- a net -512 from that addition, not from any new consumption: the buffer
already existed at 128B and was never budgeted here even then). **Without the
hard video reserve (`$2000-$5FFF`), the same budget still fits but slack drops
to 13152 bytes.** That second number is the one console/graphics/BASIC work
should treat as the real target, plus LC headroom outside `$FF00-$FFFF`, which
is now ProDOS's own, not maux's (see sec 1.2's amendment).

**Task #11 amendment summary (docs/PRODOS-SPIKE.md is the full account):**
the ProDOS-coexistence spike (docs/TASKS.md #11) proved MLI/kernel-skeleton
coexistence empirically (`make check-mli`, all checks passing) and, per that
task's own instruction, amends this budget in the same commit rather than
leaving a silent divergence between "the fs plan this document assumed" and
"the fs plan `docs/ARCHITECTURE.md`'s ProDOS ruling and `docs/SYSCALL.md`'s
mid-flight ruling actually adopted" (both already landed on `main` before
this task; this document's budget tables were the one place still describing
the pre-ruling shape). Changes: the disk/ramdisk staging line -> MLI file
buffers (above); the annex inode-cache line removed (sec 2.2 below); sec 1.2's
`$FF00-$FFFF` "free vector-table page" claim corrected for ProDOS residency
(sec 1.2 below); `inc/memmap.equ` updated to match (`MLI_IOBUF_*` added,
`INODE_*`/`K_DISKBUF_SIZE` removed, `PCB_CWDINO`'s comment corrected -- see
that file's own removal notes, and `src/kernel/sched.s`'s still-current
reference to `PCB_CWDINO` for why the SYMBOL NAME did not change even
though its "index into the inode cache" meaning is now stale).

---

## 2. Aux bank 0 -- the kernel annex

Per `learning:01KYYGZ8C3FQFWCF3S0FQ0DJ7B`, aux bank 0 is not free memory in
the *resident-driver-coexisting-with-other-software* sense -- but that
constraint (TN #26's Rule of Auxiliary Memory) binds software that shares a
machine with other ProDOS applications. maux in **native** mode owns the
whole machine outright (no coexistence to protect), and in **hosted** mode
it is the disconnect-`/RAM`-and-restore-on-quit transient pattern the same
learning explicitly exempts ("transient programs... may borrow aux bank 0
and restore it on exit"). So maux is not bound to the $D100-$DFFF
sliver -- it may use all of aux bank 0 as its annex. This is deliberate and
is the judgment call that makes the rest of this section possible; it is
recorded here so review can push back on it specifically.

### 2.1 Flat layout ($0000-$BFFF)

| region | size | contents |
|---|---:|---|
| `$0000-$01FF` | 512 | **inert.** Bank 0 is never scheduled as a process (it is the annex, not a pid), so its ZP/stack are never live under `ALTZP`=aux+`$C073`=0. Physically present, structurally unused |
| `$0200-$03FF` | 512 | annex low globals (small -- see sec 2.2) |
| `$0400-$07FF` | 1024 | **80-column text aux half / double-lores companion -- HARD video reserve.** Video scanner reads aux memory only from bank 0, unconditionally (`learning:01KW1GTYHGXMBZNR6DMQB2F712`), which is *why* the annex has to be bank 0 and not some other bank -- this is the hard constraint driving the whole section |
| `$0800-$1FFF` | 6144 | annex structures (PCB array, etc. -- see sec 2.2). Its first 1K overlaps **text/lores page 2 aux companion -- SOFT video reserve**; usable under pressure because page 2 is less important than DHR pages. `CONFIG_INIT_IN_BANK0` co-residency (`docs/ARCHITECTURE.md`) is **off** by default for this budget -- task's own framing ("48-process max = full sparse RamWorks") implies a >=3 MB card, and the architecture doc says the co-residency trick is "worth it on 256K cards... not on 1MB+ cards" |
| `$2000-$3FFF` | 8192 | **DHR page 1 aux companion -- HARD video reserve / temporary text-only V1 reclaim.** Existing annex budget may borrow it while graphics are out of scope; new allocations should avoid it |
| `$4000-$5FFF` | 8192 | **DHR page 2 aux companion -- HARD video reserve / temporary text-only V1 reclaim.** Must be evacuated with the main-side hires page 2 before double-hires/display-owner work |
| `$6000-$BFFF` | 24576 | annex structures, preferred non-video continuation |
| `$C000-$CFFF` | -- | not addressable as aux memory at all (the one-page invariant: this window is unconditionally main). N/A |

### 2.2 Annex structure budget (PCB array, inode cache, pipe rings -- MUST-INCLUDE items)

**PCB split, per `docs/ARCHITECTURE.md`:** "partly in bank 0 (kernel annex),
plus a per-bank identity/PCB page inside each process bank." The annex half
is the array below; the per-bank half is a handful of scratch bytes *inside*
the $FFxx page (sec 3.3) -- not a separate page, because the $FFxx page is
architecturally "the ONLY kernel claim in a native bank" (`docs/TASKS.md`
#2's own framing), so there is nowhere else for it to go.

| item | count | bytes/entry | size | judgment call? |
|---|---:|---:|---:|---|
| PCB array | 48 | 16 | 768 | **RATIFIED by task #6** (docs/SCHED.md sec 2) -- no longer a placeholder. 48 = the task's directed sizing assumption (full sparse RamWorks, `learning:01KYYJ98T5R0M9K1AW2550M132`: "fully expanded: 48 banks, highest `$77`"). Note bank 0 is itself one of those 48 and is never a process, so only 47 entries are concurrently occupiable on a maxed period card -- the 48th slot is harmless headroom, not a miscount. Ratified 16-byte shape: `PCB_PID`(1) + `PCB_STATE`(1) + `PCB_WCHAN`(1, task #6's addition -- the operator's two-queue scheduler ruling's "everyone else is a SET" design needs a wait-channel byte SEPARATE from the run-state byte) + `PCB_BANK`(1) + `PCB_PARENT`(1) + `PCB_SAVEDSP`(1) + `PCB_EXITSTATUS`(1) + `PCB_CWDINO`(1 -- see the task #11 amendment directly below this table for why its ORIGINAL "inode-cache index" meaning is now stale, and why the field name is unchanged regardless) + `PCB_FDTABLE`(8). See `inc/mm.annex.equ`'s `PCB_ENTRY` `dum` block for the byte-exact offsets and `docs/SCHED.md` sec 2 for the full ratification rationale. |
| ~~inode cache~~ | ~~32 entries~~ | ~~32~~ | ~~1024~~ | **REMOVED, task #11 amendment**: this line (and `PCB_CWDINO`'s original "index into it" purpose) belonged to the homegrown V6-flavored fs, cut by the operator's ProDOS ruling (commit 32fd146, landed before this task) in favor of delegating file calls to the resident ProDOS 8 MLI under a kernel lock. `PCB_CWDINO`'s byte is kept RESERVED (not reclaimed into this table, and not renamed -- `src/kernel/sched.s`, an already-landed file outside this task's scope, references it by name) pending a real per-process-cwd design against MLI's OWN prefix mechanism (which is a single machine-wide global, `PFIXPTR`, not per-process -- see `inc/memmap.equ`'s own note on `PCB_CWDINO`). `docs/PRODOS-SPIKE.md` answer (e) is the task #11 deliverable this removal is part of. |
| pipe rings | 8 | 256 data (+8 meta, budgeted but no longer annex-resident -- see sec 2.2a) | 2112 (2048 actual annex use) | ring size is **fact** -- `docs/ARCHITECTURE.md` V1 scope states "256-byte rings in the bank-0 annex" verbatim. Count (8 concurrent pipes) is a **judgment call** -- generous for V1's job-control-free shell/utility set. **Task #13 amendment (code review C3):** the "8 meta" bytes/pipe in this row describe the ORIGINAL `PIPE_META` struct-per-pipe design (read-ptr+write-ptr+owner-reader-pid+owner-writer-pid+flags+pad); task #12's actual implementation replaced it with the OFT/pipe object graph in sec 2.2a below, whose 6-bytes/pipe control metadata lives in ordinary MAIN kernel memory, not this annex budget at all -- so the annex's REAL pipe footprint is 2048 bytes (rings only), not 2112; the row is left at 2112 as a safe upper bound rather than renegotiating the bottom line for a change that only shrinks real consumption (same reasoning as `inc/memmap.equ`'s `PIPE_TOTAL_SIZE` comment) |
| tty extended state (80-col cursor/mode, beyond sec 1.3's main-side low state) | -- | -- | 32 | yes |
| cwd table (`CWD_TBL_ADDR`, `src/kernel/sched.s`) | 48 | 64 | 3072 | **fact, but never previously entered in THIS table** -- landed 2026-08-17 (judgment call 9a below), documented only in prose until now. `CWD_ENT_SIZE`/`CWD_TBL_SIZE`, `inc/memmap.equ` |
| lazy-free bank-tag pathnames (`LZ_PTH_ADDR`, `docs/STICKY.md` sec 25/sec 27) | 14 | 65 | 910 | **derived, not a judgment call** -- one slot per bank in the process pool (`LZ_SLOT_CNT`), 65 bytes being `PRC_PATHBUF`'s own slot shape; `inc/mm.annex.equ`. Occupies the address the task #15 spawn-cache directory used to (8x75 = 600 B); that cache is deleted (`docs/STICKY.md` sec 27) and `src/kernel/lazyfree.s` owns what replaced it. Only the pathname lives here -- a tag's bank/state/stamp/length/mtime/entry-head fields are main-memory arrays in that module, because the hot paths (find the slot for a bank, pick the LRU) must not pay a `BankCopy` |
| alternate-screen stores (`VCA_STR_A`/`VCA_STR_B`, `docs/VI-ALTSCREEN.md`) | 4 | 1920 | 7680 | **derived** -- one parked main screen per console at the console store's live extent (24 x `VC_STR_COLS`), so `tty4.s`'s `VCS_CLO/CHI` movers serve them as table entries 4-7. Not contiguous: 0/1 sit at `$7700-$8600` (above the signal table), 2/3 at `$A500-$B400` (above the history rings) -- neither gap alone holds four. Reached only by `BankCopy`, like every store |
| per-console foreground job (`VC_FGJOB_ADDR`, `docs/JOB-CONTROL.md` Increment A) | 4 | 4 | 16 | **derived** -- `{count, pid0, pid1, pid2}` per console, `TCSETFG_MAX` = sh's `MAXCMD` = 3 pids (a pipeline's stages), stride 4 so the row is `console<<2`. `$7680-$7690`, the gap above the signal table. Written by `SYS_TCSETFG` (the shell declaring its foreground pipeline), read by the `^C` sweep, a reaped pid scrubbed out at `wait`; zeroed by `PRC_INIT` |
| **subtotal allocated** | | | **6910** | was 6894 before the foreground-job table (16 B); 6584 while the spawn-cache directory held this slot (600 B); lazy free's tag pathnames are 910 B, so the annex gives up 310 more bytes and buys back a whole cache (`docs/STICKY.md` sec 27). Before either, this total read 2912 -- the cwd table and the tty row were real consumption never folded in |
| **available flat annex space** (`$0800-$BFFF`, including temporary DHR reclaim) | | | **47104** | fact |
| **text-only annex slack, including temporary DHR reclaim** | | | **40210** | 310 B lower than the 40520 this read under the spawn cache |
| **available outside HARD video reserve** (`$0800-$1FFF` + `$6000-$BFFF`) | | | **30720** | console/video amendment -- excludes `$2000-$5FFF`, keeps soft page-2 reserve available |
| **annex slack outside HARD video reserve** | | | **23826** | 310 B lower than the 24136 this read under the spawn cache (itself corrected from 27808) -- enough for the current budget, but DHR work should target this number |

### 2.2a Open File Table (OFT) object graph -- task #13 amendment (code review C3)

Task #12 (`src/kernel/process.s`) implements real fork/dup/close-style fd
semantics, replacing the "pipe slots directly in a PCB fd byte" shape
earlier documents (including this one and `inc/memmap.equ`'s
`PIPE_META` block, now commented out in place there) described. The
second-chair review of the process/ProDOS state flagged this as live doc
drift (C3): a reviewer relying on the old description would size limits,
memory budget, and EOF behavior against an object model the kernel no
longer uses. The implemented graph, one fd all the way down to bytes on
the wire:

```
PCB_FDTABLE[fd]  (per-process, 8 bytes, indices 0-7; 0/1/2 reserved
 byte, 0-7          for tty stdin/stdout/stderr, never forwarded to
                     the OFT -- docs/SYSCALL.md item 5)
   |
   v
OFT index        (GLOBAL, not per-process -- 1..OFT_COUNT-1; 0 unused)
(1..15)             OFT_TYPE[idx]    -- OFT_FREE / OFT_PIPE_R /
                                         OFT_PIPE_W / OFT_FILE
                     OFT_REFCNT[idx] -- how many fds (any process,
                                         e.g. after spawn()'s fd
                                         inheritance) reference THIS
                                         OFT entry; close() decrements,
                                         teardown happens at 0
   |
   +-- OFT_PIPE_R / OFT_PIPE_W --> OFT_PIPE[idx] = pipe slot (1..8)
   |         PIPE_USED/RDP/WRP/BYTES/RREFS/WREFS[slot] -- ring cursors,
   |         byte count, and INDEPENDENT reader/writer refcounts (one
   |         level below OFT_REFCNT -- "how many OFT_PIPE_R/W entries
   |         point at THIS slot", which is what write()/EOF and
   |         write()/ERR_PIPE decisions key off)
   |         --> the slot's own 256-byte ring, PROC_PIPE_RING_BASE +
   |             (slot-1)*PIPE_RING_SIZE -- the ONE piece of this graph
   |             still ANNEX-resident (aux bank 0), reached via
   |             COPYIN_ENTRY/COPYOUT_ENTRY with BANKSEL=0
   |
   +-- OFT_FILE --> OFT_REFNUM[idx]  = raw ProDOS MLI reference number
             OFT_IOBUF[idx]   = which MLI_IOBUF_COUNT page-aligned
                                 1024-byte I/O buffer (sec 1.3) this open
                                 file owns for its whole open lifetime
```

All eleven `OFT_*`/`PIPE_*` arrays (`OFT_TYPE`/`OFT_PIPE`/`OFT_REFCNT`/
`OFT_REFNUM`/`OFT_IOBUF`, `PIPE_USED`/`PIPE_RDP`/`PIPE_WRP`/`PIPE_BYTES`/
`PIPE_RREFS`/`PIPE_WREFS`) are struct-of-arrays (parallel-indexed), and --
except for the pipe ring bytes noted above -- live in **ordinary MAIN
kernel memory** (`src/kernel/process.s`'s own `ds` declarations, read via
plain absolute addressing, no `BANKSEL`/`ALTZP` bracket), not the annex.
This is a real placement change from the original design's assumption
that all pipe-related state sits in the annex alongside the PCB array --
recorded here rather than left implicit.

**Hard limits (machine-checked, `make check-memmap`):**

| limit | value | symbol |
|---|---:|---|
| fds per process | 8 | `PCB_FDTABLE` size (sec 2.2 table above; indices 0/1/2 reserved for tty) |
| OFT entries (global) | 16 | `OFT_COUNT` (`inc/mm.annex.equ`, moved here from `src/kernel/process.s` this task) |
| pipe slots (global) | 8 | `PIPE_COUNT` (sec 2.2 above) |
| pipe ring size | 256 bytes/slot | `PIPE_RING_SIZE` (sec 2.2 above) |
| MLI I/O buffers (global) | 6 | `MLI_IOBUF_CNT` (inc/mm.mlibuf.equ; was 4, then 6, then 8 = ProDOS 8's own ceiling, and 6 again since B1 2026-10-21 at `$A000-$B7FF`, docs/B1-NOTES.md) -- one consumed per concurrently-RESIDENT ProDOS file. Since 2026-09-07 a file can be PARKED (closed in ProDOS, reopened at its saved mark on next use) when the pool is empty, so this no longer caps open files -- docs/IOBUF-LENDING.md |

Annex LC (`$D000-$FEFF` + bank 0's own `$FFxx`, same 16384-byte shape as
sec 1.2) is **unallocated** -- not needed by the structures above, kept as
headroom. Bank 0's own `$FFxx` page follows the same "no process, vector
table only" shape as main's (sec 1.2) **as originally written** -- but per
sec 1.2's own task #11 amendment, that shape assumption is now known to be
WRONG for MAIN's `$FF00-$FFFF` once ProDOS is resident (252/256 bytes
occupied, measured). It is NOT known to be wrong here: ProDOS and its MLI
run exclusively in MAIN context (`docs/ARCHITECTURE.md`'s Filesystem/I-O
section) and never touch aux memory at all, so bank 0's own `$FFxx` page
(aux, not main) is NOT subject to the same correction -- it remains
genuinely free headroom as originally described. One added discipline:
kernel code must only touch bank 0's LC region inside `SEI`-protected
windows, so a stray hardware IRQ can never vector through a page that was
never stamped as a real syscall/IRQ door.

**Bottom line: the annex has 40210 bytes of flat slack while text-only V1
borrows the DHR companions** (task #15 amendment: was 44192 before this task
folded the cwd table's pre-existing 3072B and the new 600B sticky-image
directory into the table's own subtotal -- see the table above; neither had
been counted here before, only in prose). **Outside the hard bank-0 video
reserve, annex slack is 23826 bytes.** DHR, virtual-console graphics, or
display-owner compatibility should budget against that second number, plus
~15.5 KiB of untouched LC headroom (bank 0's `$FFxx` included, unlike main's
-- see above), after fitting the full PCB array, 8 pipe rings, the cwd table,
and the sticky-image directory with room to spare. The ramdisk itself does
**not** live here -- and, per the ProDOS ruling, no longer exists at all in v1
(`docs/ARCHITECTURE.md`'s Filesystem/I-O section: "the ramdisk is CUT" --
storage is ProDOS-managed SmartPort blocks now, not aux banks).

---

## 3. Canonical process-bank layout (aux banks != 0)

One bank = one process. Every process sees the identical layout below at
identical addresses -- no relocation, per the one-page invariant.

### 3.1 Load base: `$0800`

**Ruling: process images load at `$0800`.** Justification:

1. **Existing precedent in this tree.** `src/bootblock.s` (task #1) already
   `org $0800`s and is the working boot path; keeping the exec load base at
   the same address means the boot block's own conventions (chain-count
   byte, entry-at-load+1 idiom) generalize instead of needing a second
   convention invented from scratch.
2. **Universal low-load convention.** `$0800` is the traditional small-binary
   / boot-block load address on the Apple II (DOS 3.3's own boot chain uses
   it, `~/src/malisp`'s bootblock.s uses it) -- picking anything else buys
   nothing and costs cross-reference clarity with the existing toolchain
   docs.
3. **No conflict with the rest of the layout.** `$0200-$07FF` (1536 bytes)
   is left as ordinary low process space below the load base -- free for
   process-owned buffers/stdio state, or simply unused slack -- and nothing
   the kernel claims (PCB, $FFxx page, `$BF00` overlay) sits below `$0800`,
   so there's no collision to design around.

### 3.2 Full layout

| region | size | contents |
|---|---:|---|
| `$0000-$00FF` | 256 | process ZP (own, `ALTZP`-selected) |
| `$0100-$01FF` | 256 | process stack |
| `$0200-$07FF` | 1536 | free low process space (no display hole in banks != 0 -- `learning:01KW1GTYHGXMBZNR6DMQB2F712`: "Banks 1+ have no display holes -- confirmed"). **At process entry this window holds argv** -- see sec 3.2a |
| `$0800` | -- | **LOAD_BASE** -- exec entry point |
| `$0800-$BEFF` | 46848 | program image + heap; `sbrk` grows the watermark upward from end-of-image toward `$BEFF` |
| `$BF00-$BFFF` | 256 | **reserved-but-optional** `$BF00` MLI-compat overlay page. Ordinary RAM (RAMRD/RAMWRT-governed, *not* LC) -- chosen to sit exactly where ProDOS's own global page lives, so the opt-in overlay (task #3/#8) can mimic MLI's fake-global-page shape without renegotiating this map. When a process does **not** opt in, this page is ordinary usable memory -- "reserved" means the kernel never assumes it is free, not that it is physically walled off (no hardware protection axiom, `docs/ARCHITECTURE.md`) |
| `$C000-$CFFF` | 4096 | **not process memory, ever.** Always main: I/O + slot/expansion ROM. Refused outright by copyin/copyout (`docs/ARCHITECTURE.md` sec Process model, review finding A2) |
| `$D000-$DFFF` bank 1 | 4096 | process LC storage, bank 1 (switchable -- not simultaneously visible with bank 2) |
| `$D000-$DFFF` bank 2 | 4096 | process LC storage, bank 2 -- **default target of the ALTZP-aware copyin/copyout path, see sec 3.4** |
| `$E000-$FEFF` | 7936 | process LC storage, common (visible regardless of bank 1/2 selection) |
| `$FF00-$FFFF` | 256 | **kernel's only claim in a native bank.** See sec 3.3 |

Total process LC storage (both D-banks + common, not simultaneously
addressable): 4096 + 4096 + 7936 = 16128 bytes. Per the ABI rule
(`docs/ARCHITECTURE.md`, cold-read Q3-2): **not preserved across fork** --
irrelevant to spawn (spawn never copies), relevant only to the v2 `fork()`
slow path.

### 3.2b The break, and who decides where the heap starts (2026-08-22)

`brk` is implemented (`src/kernel/process.s` `PRC_BRK`, syscall 5). Until
2026-08-22 it was an `ERR_NOSYS` stub and no program had ever called it;
every program that wanted a large buffer statically reserved the rest of
the window instead (`docs/STICKY.md` sec 20).

**The break is the address one past the heap: a process owns
`[LOAD_BASE, brk)`.** It is stored as a PAGE NUMBER in `PCB_BRK`, the byte
that used to be `PCB_SPARE` (`inc/mm.annex.equ`). One byte was all
there was -- `PCB_ENT_SIZE` must stay 16 so `PCB_PTR_FOR` can index with
`pid<<4` -- and one byte is enough: `$08..$BF` spans the whole window, and a
bank copy is page-granular anyway. Every `brk` request rounds **up** to a
whole page, so a caller never gets less than it asked for.

**`brk` allocates nothing.** In a bank-per-process design the whole window
is already the process's, there is no MMU and no swap. What `brk` does is
record a boundary and enforce a ceiling. Two parties need that boundary
and neither can supply it alone:

- **the ceiling is the kernel's**, because only the kernel owns
  `PRC_BRK_LIM` (`$BF00` -- `BF00_OVERLAY`, so the heap stops exactly below
  the overlay page). A break above it fails `ERR_NOMEM`; below `LOAD_BASE`,
  `ERR_INVAL`. Neither changes the stored break.
- **the floor is the program's**, because the kernel does not know where a
  program's uncleared `dum` region ends -- only the program knows its own
  last symbol. So the kernel never invents an initial break: a relative
  `sbrk` before any absolute `brk` is `ERR_INVAL`, not a heap that
  silently starts at `$0800` on top of the program's own data.

`PCB_BRK` is **0 until the program sets one**, and `SCH_CREATE` already
zeroed that byte for every new process, so a reused pid cannot inherit the
previous occupant's break. Zero therefore means "extent unknown", not
"empty heap" -- which is the safe reading for the consumer this design is
really for.

**What `fork()` computes from it** (landed 2026-08-23,
`src/kernel/procfork.s`, `docs/FORK.md` -- measured at **38.54 cyc/B**
over a 16,128-byte extent, 1.4% under the model below, after the same
day's extent widening). A `fork()` here is a
bank-to-bank copy of a live process, not a load from a file: without a
break it must copy the whole `$0200-$BEFF` window, 48,384 bytes, ~1.89M
cycles at the measured rate -- about 1.9 seconds per fork at
1MHz. With one it reads `PCB_BRK` (riding along on a `PCB_RD_FIELDS` call
the spawn path already makes) and copies `[PRC_LOWFREE, PCB_BRK*256)` --
the argv/env low window included, per the 2026-08-23 S1b widening ruling
(`docs/FORK.md`) -- stopping there. A shell that has allocated little pays little. If
`PCB_BRK` is 0 the process never declared an extent and the whole window
must be copied -- correct, just not fast, and the reason a program that
wants cheap forking should call `brk` even if it never allocates again.

### 3.2a The argv block inside `$0200-$07FF` (2026-08-17, docs/LIMITS.md)

`spawn()` stages the child's `argc`/`argv` into the low window before the
child is made runnable (`docs/SYSCALL.md` ruling 13). The three addresses
and both ceilings live in `inc/mm.procbank.equ`/`mm.procbnk2.equ`; `src/kernel/procspawn.s`
and `inc/startup.equ` derive from them rather than restating them,
which is what they used to do.

| address | symbol | contents |
|---|---|---|
| `$0200` | `PRC_ARGV_HDR` | `argc`, one byte (`ARGC` in `startup.equ`) |
| `$0201-$02FF` | `PRC_ARGV_PTRS` | pointer array, 2 bytes per entry (`ARGV`) |
| `$0300-$07FF` | `PRC_ARGV_STR` | packed NUL-terminated strings |

**The two limits are derived from this table, not chosen:**

- `ARG_MAX` = `LOAD_BASE-PRC_ARGV_STR` = **1280 bytes** of packed strings,
  NULs included. The strings run up to where the image begins.
- `ARGV_PTR_LIM` = `PRC_ARGV_STR-PRC_ARGV_PTRS` = **255 bytes** of pointer
  array, i.e. **127 entries** -- the entry count is a consequence, not a
  declared constant. There is no per-argument cap: one argument may use
  the whole remaining budget.

Exceeding either fails the spawn with `ERR_2BIG`; nothing truncates. Gate:
`make check-argv`.

Two consequences worth stating here rather than rediscovering:

1. **This is a ceiling, not a reservation.** A typical argv is a few dozen
   bytes, and the window is otherwise ordinary process memory -- free for
   process-owned buffers exactly as sec 3.1 says. The corollary is
   `docs/SH-DESIGN.md` ruling 10: argv is guaranteed valid **at entry
   only**, so a program that reuses `$0200-$07FF` and still wants its
   arguments must copy them first.
2. **Writes into this window from the kernel must go through `BankCopy`.**
   The string region extends past `$03FF`, and with 80STORE set,
   RAMRD/RAMWRT are ignored for `$0400-$07FF` -- PAGE2 alone routes it
   (`learning:01KW1GTYHGXMBZNR6DMQB2F712`). 80STORE-off is the kernel's
   steady state (sec 4), so a hand-rolled `RAMWRTAUX` store would work right
   up until it didn't; the primitive brackets `CLR80STORE` for the whole
   call.

### 3.3 The `$FFxx` page -- internal layout

256 bytes total; `$FFFA-$FFFF` (6 bytes) is hardware-fixed (NMI/RESET/IRQ
vectors), leaving 250 usable bytes, matching `docs/ARCHITECTURE.md`'s own
figure ("~250 usable bytes; the stubs are dozens"). Every bank's copy is
stamped identically at creation ("every bank has its own `$FFFE`" --
`learning:01KYYJ98T5R0M9K1AW2550M132`).

| offset | size | label | contents |
|---|---:|---|---|
| `$FF00` | 20 | `SYSCALL_ENTRY` | syscall door -- `JSR $FF00` lands here. `PHP`(1) `SEI`(1) `CLD`(1) `PHA`(1) `TXA`(1) `PHA`(1) `TYA`(1) `PHA`(1) = 8B register/flag save, then `STA $C002`(3) `STA $C004`(3) flip RAMRD/RAMWRT->main = 6B, then `JMP` kernel entry (3B, main `$0200+`) = 17B counted, 20B budgeted for label/alignment slack |
| `$FF14` | 14 | `IRQ_ENTRY` | IRQ door -- target of the `$FFFE` vector. Hardware already pushed PC+P and set I; 65C02 auto-clears D, so no `PHP`/`SEI`/`CLD` here. `PHA` `TXA` `PHA` `TYA` `PHA` (5B) + same `STA $C002`/`STA $C004` (6B) + `JMP` kernel (3B) = 14B. BRK shares this same hardware vector (6502/65C02 architecture, not a maux choice) -- discrimination via the frame's B flag happens in kernel code after the `JMP`, not in this stub, per `docs/ARCHITECTURE.md`'s "BRK discriminated in kernel" |
| `$FF22` | 12 | `EXIT_TAIL` | shared exit tail, one for both doors (frame layout `[PCH][PCL][P][A][X][Y]` makes one `RTI` valid for either entry). `STA $C003`(3) `STA $C005`(3) flip RAMRD/RAMWRT->aux, `PLA``TAY`(2) `PLA``TAX`(2) `PLA`(1) restore Y/X/A in reverse push order, `RTI`(1) = 12B |
| `$FF2E` | 1 | `BANK_ID` | the per-bank identity byte -- `$C073` is write-only, so each bank must self-report which physical bank number it is (`learning:01KYYJ98T5R0M9K1AW2550M132`: "the program must keep track of the current bank number in a reserved location within each bank"). This one byte, at this fixed offset in every bank, **is** the per-bank half of the PCB split from sec 2.2 |
| `$FF2F` | 5 | `SCRATCH` | reserved per-bank kernel scratch (future use -- e.g. a saved-SP slot if the scheduler ends up wanting one in-bank rather than only in the annex PCB) |
| `$FF34` | 2 | `NMI_TRAP` | NMI is ruled out architecture-wide as a timer source, but the vector must point somewhere valid. `BRA *` (65C02, 2B) -- parks the CPU for debugger visibility rather than silently corrupting state, consistent with the already-conceded SEI-forever DoS class |
| `$FF36` | 6 | `RESET_STUB` | defensive-only: `SEI`, reassert `$C073=0` (`LDA #0` `STA $C073`, 5B) -- **not** the real recovery path (that's main's `$03F2` intercept, sec 1.1); this only guards the edge case of a hardware RESET landing here directly with this bank's LC still mapped |
| `$FF3C-$FFF9` | 190 | *(unused)* | slack. Budgeted stub cost above is 20+14+12+1+5+2+6 = **60 bytes**; this leaves 190 bytes of the 250-byte usable budget for task #3's real implementation, alignment padding, and any `$BF00`-overlay support jump this page needs to carry |
| `$FFFA-$FFFB` | 2 | NMI vector | -> `NMI_TRAP` |
| `$FFFC-$FFFD` | 2 | RESET vector | -> `RESET_STUB` |
| `$FFFE-$FFFF` | 2 | IRQ/BRK vector | -> `IRQ_ENTRY` |

**Budget check:** stub bytes (`SYSCALL_ENTRY` 20 + `IRQ_ENTRY` 14 +
`EXIT_TAIL` 12 + `BANK_ID` 1 + `SCRATCH` 5 + `NMI_TRAP` 2 + `RESET_STUB` 6)
= **60 bytes**, + 190 bytes slack = 250 usable bytes, + 6 bytes hardware
vectors = 256 bytes total = exactly the page. **60 of 250 usable bytes
budgeted, well under the <=250 ceiling**, with 190 bytes free for task #3's
real implementation to grow into. Exact instruction sequences and their
interrupt-safety argument are task #3's deliverable (`docs/SYSCALL.md`) --
this table fixes the *shape and byte budget*, not the final opcodes.

### 3.4 Which `$D000` bank does the ALTZP-aware copy path address? (the cold-read finding)

This is the open question `docs/ARCHITECTURE.md` flagged and pushed to
#2/#3: "`$D000-$FEFF` via the ALTZP-aware LC path, whose spec must name
which of the two `$D000` banks... the selector is part of the address."

**The hazard:** the LC bank-1/bank-2 select latch (driven by the
`$C080-$C08F` soft-switch window) is a single piece of //e MMU hardware
shared by main *and* every aux bank. `ALTZP` selects *which* LC's physical
RAM is currently behind `$D000-$FFFF` (main's own vs. whichever bank
`$C073` currently names) -- but it does **not** select bank 1 vs. bank 2
*within* that LC; that is a separate, `ALTZP`-independent latch. So the
bank-1/2 selection is **not** saved or restored by the `ALTZP` flip the
copyin/copyout primitive performs -- flipping `ALTZP` to reach a process's
LC region lands on whatever bank-1/2 state happened to be left over from
whatever last touched *any* LC, main or aux. A path that assumes "the bank
I last selected is still selected" is reading a hazard, not a fact.

**Ruling: the ALTZP-aware LC path defaults to bank 2, and always writes the
select switch explicitly before every access -- never trusts ambient
state.** Justification:

1. TN #26 already anchors bank 2 as the sanctioned convention for
   resident-style data in the aux LC (`$D100-$DFFF`, **bank 2** --
   `learning:01KYYGZ8C3FQFWCF3S0FQ0DJ7B` quotes it verbatim). Reusing bank 2
   keeps maux aligned with the one outside precedent that exists, rather
   than inventing an unrelated convention.
2. The ProDOS 8 TRM's own language-card interrupt-handling routine (read
   during this task's library search, artifact
   `d82965d865557730323115a79ec150c5449f13a335c258273dcb0171fa692ff8`,
   around `SYS.RTS`) reasserts `BIT RAMIN` (read-enable) as part of
   returning control, consistent with software of that era treating "LC
   read-enabled, settle on a known bank" as the expected resting posture
   rather than an assumption to be second-guessed.
3. It only has to be *a* fixed choice, not *the* uniquely correct one --
   bank 1 would work equally well mechanically. Bank 2 is simply the one
   with outside precedent to point at.

This mirrors the discipline `docs/ARCHITECTURE.md` already rules for
`$C073` itself ("the selection is UNKNOWN at every entry... always written
before any aux-dependent operation; no code ever reads meaning from
persistence") -- same discipline, same reasoning, now applied to the LC
bank-1/2 latch. A process needing bank 1 does so through an explicit
alternate entry point; that entry point's shape is task #3 scope, not
blocking this spec.

---

## 4. Canonical kernel softswitch steady state (invariant table)

**MUST INCLUDE (b), per `docs/TASKS.md` #2's adversarial-review addendum.**
This is the resting state other tasks (#3 syscall ABI, #4 bank-clone, #6
scheduler) may assume holds true except inside an explicitly bracketed
window, and must restore before returning to it.

| switch | steady state | why |
|---|---|---|
| `80STORE` (`$C000`/`$C001`) | **OFF** | Default. With 80STORE off, `RAMRD`/`RAMWRT` + `$C073` route normally across the *entire* `$0200-$BFFF` range (`learning:01KW1GTYHGXMBZNR6DMQB2F712`) -- no primitive needs to special-case the video-hole addresses. This generalizes the discipline `docs/ARCHITECTURE.md` already requires of the bank-clone primitive ("sidestep by keeping 80STORE off in copy primitives") to the *whole kernel*, not just that one routine |
| `PAGE2` (`$C054`/`$C055`) | OFF (page 1) | paired with 80STORE=OFF above |
| `HIRES` (`$C056`/`$C057`) | OFF | text-console steady state; future graphics/display-owner code must bracket its own mode changes and never return to the scheduler with an undocumented display state |
| `RAMRD` (`$C002`/`$C003`) | main (OFF) | except inside an explicit, bracketed process-memory-access window |
| `RAMWRT` (`$C004`/`$C005`) | main (OFF) | ditto |
| `ALTZP` (`$C008`/`$C009`) | main (OFF) | except inside the entry/exit critical section (sec 3.3) or an explicit ZP/stack peek window -- `ALTZP` only steers `$0000-$01FF`, so it is safe to flip briefly from main `$0200+` code (`docs/ARCHITECTURE.md`, review finding A2) |
| `$C073` (bank select) | **UNKNOWN at every entry** -- write-only, not cleared by reset. Always written before any aux-dependent operation; never read for meaning (it can't be read at all) | `learning:01KYYJ98T5R0M9K1AW2550M132`; the "coding discipline" ruling in `docs/ARCHITECTURE.md` |
| LC read/write/bank (`$C080-$C08F`) | RAM read-enabled, **bank 2** selected | kernel's default LC posture, main and aux alike; the ALTZP-aware copyin/copyout path re-asserts this explicitly every time (sec 3.4) rather than trusting it persisted |

**Sanctioned exceptions:** display backends and graphics/display-owner code may
temporarily leave the text-console steady state. Apple 80-col or double-hires
backends bracket `SET80STORE`...hardware access...`CLR80STORE`, holding the
bracket for the minimum instruction count, and -- like the bank-clone
primitive's own bracket -- **never span a context switch or a syscall return**.
No other kernel code may leave 80STORE set when it returns control to a process
or to the scheduler.

---

## Judgment calls made (for review to challenge)

1. Hires page 1 and 2 (main `$2000-$5FFF`) plus their aux bank-0 DHR
   companions are HARD video reserve, but text-only V1 may temporarily keep
   already-claimed bytes there. New allocations should avoid those apertures;
   console graphics, hosted BASIC display ownership, or DHR support must
   evacuate them first (sec 1.1, sec 2.1, `docs/CONSOLE.md`).
2. Kernel code budgeted at 12 KiB, disk buffers at 2x512B, bounce buffer at
   256B, bank free-list at 128 entries (sec 1.3) -- all sizes invented ahead of
   real code.
3. PCB entry shape/size (16 bytes) is now **RATIFIED, not a placeholder**
   (task #6, docs/SCHED.md sec 2 -- see sec 2.2's amended table above); pipe-ring
   count (8) and per-pipe metadata (8 bytes) (sec 2.2) remain placeholders
   pending real structures. (Inode-cache shape/size, formerly listed here,
   is REMOVED -- task #11 amendment, see sec 2.2's table.)
4. `CONFIG_INIT_IN_BANK0` assumed **off** for this budget (large-card
   assumption, per the task's own "48-process max" framing) (sec 2.1).
5. TN #26's `$D100-$DFFF` reservation ruled **not binding** on maux, native
   or hosted, because maux is a whole-machine/transient owner in both modes,
   not a coexisting resident driver (sec 2, opening paragraph) -- this is the
   judgment call the rest of sec 2's roomy annex budget depends on.
6. LC bank 2 chosen (not bank 1) as the default `$D000` bank for the
   ALTZP-aware copyin/copyout path (sec 3.4) -- the actual cold-read finding
   this task was asked to close out.
7. `$0800` chosen as the process load base over alternatives like `$2000`
   (sec 3.1).
8. **(task #11)** MLI file-buffer count (`MLI_IOBUF_COUNT`=4, sec 1.3) is a
   judgment call sized against v1's shell + six utils, not a measured
   requirement -- `make check-mli` exercises one such buffer, reused
   sequentially, not several live at once. See docs/PRODOS-SPIKE.md answer
   (e).
9a. **(2026-08-17, RESOLVED)** `PCB_CWDINO` is now `PCB_SPARE`. The condition
    item 9 below made it wait for -- "a real per-process-cwd design against
    MLI's OWN prefix mechanism" -- exists: cwd strings live in a per-pid annex
    table at `CWD_TBL_ADDR`, the kernel resolves relative paths against the
    caller's entry, children inherit, and ProDOS's single global prefix is
    pinned to the boot value so it cannot mask a broken table. A ProDOS cwd is
    a PATH, so it could never have fitted in this byte at all. The byte is
    SPARE CAPACITY, not reclaimed space: `PCB_ENT_SIZE` stays 16 so
    `PCB_PTR_FOR` can index with `pid<<4` rather than a multiply.

9. **(task #11)** `PCB_CWDINO`'s byte is left reserved, unrenamed, and
   without a resolved per-process-cwd design -- MLI's own prefix mechanism
   is machine-wide, not per-process, and reconciling the two is explicitly
   deferred to task #12+ (sec 2.2's table, `inc/mm.annex.equ`'s own note).

## DEPOSIT CANDIDATES

No street-library deposit made (per task rules, deposits are reported, not
made, by the executing worker). One adjacent finding worth a future
deposit, surfaced incidentally by this task's own search sweep (not
load-bearing for this document, so not blocking):

- The ProDOS 8 TRM's language-card interrupt-save routine (artifact
  `d82965d865557730323115a79ec150c5449f13a335c258273dcb0171fa692ff8`,
  around the `BNKBYT1`/`BNKBYT2`/`SYS.RTS` listing) shows Apple's own MLI
  saving/restoring the LC bank-select state byte-for-byte across an
  interrupt taken while the language card is banked in -- i.e. period
  software already treated "LC bank state does not survive an interrupt
  for free" as a known hazard and coded around it explicitly. This is
  independent, first-party confirmation of the sec 3.4 hazard (LC bank-1/2
  state is not preserved automatically) from a primary Apple source, not
  just inference from the soft-switch mechanism. Worth depositing as a
  named learning the next time someone works `$FFxx`/task #3, since it
  would have made the cold-read finding a five-minute lookup instead of a
  derivation.
