# Process I/O: the kernel is pragmatic, liba is elegant

Status: BUILT, with the measurements kept. 2026-08-20 design, written
after measuring the three I/O paths (sec 2) and finding the same answer
Unix found in 1975. Landed and recorded in the results sections: K1
(`PMLI_XFR_SIZE` = `$200`, sec 9), K2/K3 bulk pipe and tty transfer
(sec 10), `BC_CHUNK` 128 -> 254 (sec 12), buffered output streams in
`src/liba/stdio.s` gated by `check-bufio` (sec 13), the tty output path
(sec 14) and the console write floor (sec 15). Sec 7's two questions
and K4 (drop `BankCopy`'s main->bank bounce) are not recorded as built.

## 1. The ruling

**Do not try to make the kernel API the layer that manifests the
application API.** Pragmatic concerns -- blocks, banks, what ProDOS and
the MMU actually want -- drive the syscall interface. The elegant
byte-at-a-time program interface is defined in `liba`.

This is the V6/V7 split exactly. `read(2)`/`write(2)` are raw, unbuffered
and block-oriented; `getc`/`putc` were *macros* in `<stdio.h>` that
touched a buffer in the process's own memory and called `_filbuf`/
`_flsbuf` only at boundaries. A program that reads a character at a time
is not making a system call at a time, and the kernel is never asked to
be convenient.

Two corollaries this document holds to:

- **The kernel API should get COARSER, not finer.** No byte-oriented
  syscalls, no scatter/gather, no "cheap small read" fast path. If a
  syscall is being called too often, that is liba's bug, not the
  kernel's.
- **Every efficiency argument below belongs on exactly one side.** Kernel
  work is about making BULK transfer cheap. Library work is about making
  small operations not become bulk transfers. Mixing them is how you get
  a kernel with a page cache and a stdio that bypasses it.

## 2. What exists today (measured, not inferred)

`PRC_READ`/`PRC_WRITE` copy the 8-byte parmlist in from the process
bank, resolve the fd through the OFT, and dispatch on object type. The
three types then buffer in three unrelated ways.

**Files** must stage through main memory, because ProDOS physically
cannot address an aux bank:

```
disk block -> ProDOS io_buffer   (1024B, main $6000, one per open file)
           -> PMLI_XFER_BUF      (main $7000, PMLI_XFR_SIZE = 128B)
           -> BankCopy           (~20 cyc/byte, bounces via a 256B buf)
           -> caller's buffer, in its own bank
```

`PRC_FILE_READ` loops that whole sequence per 128 bytes. One
`read(fd, buf, 512)` is therefore **4 MLI calls and 4 BankCopy calls**,
and every byte is copied three times.

**Pipes** have no bulk path at all. The pipe branch of `PRC_READ` runs
`PPP_GET_BYTE` (annex ring) then `PWRPAR_BYTE` (a single-byte cross-bank
write: bank select, switch flips, indirect store, restore) **per byte**.

**tty** does the same: the committed line reaches the caller one byte at
a time through `PWRPAR_BYTE`.

The staging size is the load-bearing mistake: **128 is smaller than a
ProDOS block**, so a request can never align with what the filesystem
moves, and every MLI READ is a partial copy out of the io_buffer.

## 3. Kernel side -- make BULK cheap (pragmatic layer)

- **K1. `PMLI_XFR_SIZE` 128 -> 512, block-aligned.** Main has room:
  `$6000-$BFFF` is 24576B of preferred non-video space and the
  io_buffers occupy only `$6000-$6FFF`. Cuts MLI and BankCopy calls 4x
  on every file read, and lets a request correspond to a block.
- **K2. Bulk pipe transfer.** The ring is contiguous annex memory:
  compute the contiguous run(s) and issue one `BankCopy` (two across a
  wrap) instead of N per-byte cross-bank writes.
- **K3. Bulk tty line copy.** Same technique for the committed line.
  Small absolute win (human typing speed) but it is on the `sh <script>`
  and type-ahead paths.
- **K4 (conditional). Drop `BankCopy`'s bounce for main->bank.** With
  write-to-aux enabled you can read main and write the bank in one pass.
  Only if sec 7's question resolves in favour; the 128-byte internal
  chunking that bounds interrupt latency stays regardless.

Note what is NOT here: a kernel-side per-process buffer cache. For the
kernel to copy inside a process bank it must bounce through `BankCopy`
or flip `RAMRD` -- and flipping `RAMRD` from kernel code is forbidden
outright (instruction fetch would come from the process bank,
learning:01KW1GTYGVYAPQRGS5P7J66RWD). A kernel buffer would pay
cross-bank cost on every hit, which is most of what buffering exists to
avoid. **Buffering belongs where the memory and the CPU already agree:
in the process's own bank, addressed by the process.**

## 4. Library side -- make SMALL free (elegant layer)

`liba` gains buffered streams, as its own module (per #8a: a program pays
for every module it links, whole, so `echo` must not carry this).

- Buffer lives in the process's **LC bank 1** (sec 5) -- 4096 bytes that are
  otherwise unallocated in every process.
- `BUFSIZ` = **512**, one ProDOS block, matching K1's staging size. Eight
  streams fit the page. A stream may request the whole page for
  single-file streaming workloads.
- **Full buffering for files; line buffering for the tty.** The classic
  rule, and the reason a prompt appears before the read that follows it.
  maux has no `isatty` yet -- the fd's object type is already known to the
  kernel, so exposing it is the cheap enabling call.
- **Flush on exit is a hard requirement.** Buffered writes not flushed
  are lost writes. `liba`'s exit path must flush every open stream, and a
  program that calls `SC_EXIT` directly bypasses it -- so either `exit()`
  becomes the documented door and `SC_EXIT` the raw one (the Unix
  `exit`/`_exit` split, which is exactly this distinction), or every
  program is a latent data-loss bug.

**One classic hazard maux does not have**: there is no `fork()`, only
`spawn()` (task #4's v1 ruling), so buffered data is never duplicated
into a child that flushes it twice. The single nastiest stdio bug in
Unix history is structurally absent here. Worth not reintroducing when
`fork()` is reconsidered for v2.

## 4a. The error path -- a swallowed write is a lost write (2026-08-24)

sec 4 above says *"buffered writes not flushed are lost writes"* and made
flush-on-exit a hard requirement. It did not say what happens when the
flush itself **fails**, and the answer was *nothing at all*: `SIO_FLUSH`
did `bcs :wdone`, reset the byte count "even on a partial/failed write",
and `PUTS` (unbuffered, writes on its own) dropped `SC_WRITE`'s carry on
the floor. The justification in the source was circular -- *no util checks
`PUTC`'s carry today either* -- and it was load-bearing for three
separate shipped bugs, all found by one gate (`check-writefail`,
`docs/E2E-COVERAGE.md` sec 4 item 4):

| symptom | what the user saw |
|---|---|
| `tee F` onto a locked `F` | exit **0**, no diagnostic, `F` unchanged |
| `ed`'s `w F` onto a locked `F` | **no `?`**, no diagnostic |
| `echo X >> F` on a locked `F` | **`$?` == 0** |

**The rule now: the error is STICKY, per fd, and is delivered where a
program can act on it.**

- `SIO_ERR[fd]` (`src/liba/libabss.s`, in the kernel-zeroed page --
  read-before-written, like `SIO_CNT_LO/HI`) holds the errno of the
  **first** failed write on that fd. First wins: a stream that fails once
  usually fails every flush after it, and the first errno is the one that
  says why.
- Both writers record: `SIO_FLUSH` (buffered) and `PUTS` (unbuffered).
  Two writers, one flag -- otherwise a caller has two places to look.
  **Measured caveat, stated because the gate cannot prove this half:**
  every util ends a line with a `PUTC`'d CR, and on a line-buffered fd
  that CR's flush hits the same failure, so `check-writefail` stays green
  with *either* recorder disabled and goes red only with both. `PUTS`'s
  recorder earns its place on the output that never reaches a CR -- a
  `PUTS` with no trailing terminator leaves nothing buffered for `EXIT`'s
  flush to fail on -- not on anything the fixture currently exercises.
- **`PUTC`'s interface stays silent, deliberately.** Returning a carry
  from `PUTC` would touch every call site in 33 programs to report a
  condition almost none of them can act on per byte.
- `FCLOSE` delivers it: carry set, `A` = errno, and the **write** error
  outranks the close result (a stream whose flush failed did not deliver
  its bytes; a clean close afterwards does not undo that). Delivery
  *clears* the flag -- fd numbers get reused, and a stale flag would make
  the next stream's `EXIT` lie.
- `EXIT` delivers what nobody closed: a **zero** status becomes
  `EXIT_WRFAIL` (1) when any fd still carries an error. In practice that
  is fds 0-2, which nothing closes -- i.e. exactly a shell-redirected
  stdout. A nonzero status the program chose is left alone; it already
  says something went wrong, and the program knows more about what.

This is stdio's own `ferror`/`fclose` shape, and it is why the fix is
~60 bytes of `liba` rather than an edit to every util.

**What the same gate found that was NOT this bug**, worth keeping
straight: `echo X > LOCKED` never reached a write at all. `>` is
UNLINK-then-CREATE (`OPEN_REDIR_WR`), and on a locked target the CREATE
fails, so `sh` printed `sh: cannot redirect` and never spawned the child.
`$?` was 0 because `sh`'s `:redirfail` path left `LASTSTATUS` **stale** --
the wait loop only writes it when a reaped pid matches the last stage --
so the shell was reporting the *previous* command's status. Two bugs, one
symptom, and the pin's stated cause named only the library. The fixture
now runs `>` **and** `>>` at the locked target: `>>` opens fine (a locked
file still permits reads) and fails at the child's write, which makes it
the only line that exercises this section end to end.

## 5. The LC bank 1 invariant -- stated once

`$D000-$DFFF` is double-banked. MEMMAP sec 3.4 makes bank **2** the default
target of the copyin/copyout path (following TN #26), leaving **bank 1
unallocated in every process** -- 4096 bytes, the buffer's home.

Enabling facts: only `$D000-$DFFF` is banked (`$E000-$FFFF` is common),
so flipping never disturbs the `$FFxx` kernel page; selection is a
soft-switch read.

**THE CLAIMED INVARIANT -- and see the correction below it:** the LC
bank latch is machine-global and crosses the syscall boundary; ProDOS
lives in the main LC and requires bank 2; a process entering a syscall
with bank 1 selected hands the kernel a ProDOS with the wrong `$D000`
page mapped.

**CORRECTION 2026-08-20: that hazard is UNDEMONSTRATED.** It was
asserted here from reasoning, never from a run. `check-bufio`'s phase D
was written specifically to prove it -- a deliberate violator selecting
bank 1 and then issuing a real MLI call -- and the violator **returns
cleanly, every time, across every call tried.** The leading hypothesis
is that ProDOS's own MLI dispatch re-establishes its bank, which would
mean the hazard is defended against upstream and this section overstated
it.

The phase is now recorded as CHARACTERISATION, not an assertion: it
prints what happens and fails nothing. It was deliberately NOT inverted
into "the violator must survive", because that would enshrine an
assumption equally unproven in the other direction.

**The bracket stays anyway.** It costs a few cycles, and the absence of
a demonstrated hazard is not a demonstrated absence -- two MLI calls on
one emulator is thin evidence for a machine-global claim. But this
section no longer presents it as established, and anything building on
it should know the difference.

**VINDICATED, DIFFERENTLY -- same day.** Hours after the above was
written, `check-ld` went red and the cause was an LC-bank hazard of
exactly this family, in a place this section never looked. `SIO_PUTC`
flips to bank 1 for its buffer and restores bank 2 **read-only**. But
`ld.s` embeds Merlin's core at `$D000` and holds bank 2
**write-enabled**, because LINKER.S writes into its own `$D000`
workspace throughout a link. So every character `PUTC`'d from inside
the core silently downgraded bank 2 to read-protected, corrupting the
linker's writes until it spun in a non-terminating loop. Proven by
isolation: routing that path through a raw `SC_WRITE` fixed it, and
adding back ONLY the bank-select bracket reproduced the hang
byte-for-byte.

So the instinct was right and the target was wrong. I claimed the
victim was ProDOS -- "hands the kernel a ProDOS with the wrong `$D000`
page" -- and built a gate that tested exactly that, which is why it
found nothing. **The victim is the PROGRAM'S OWN LC state**: any
program holding a non-default bank configuration across a `PUTC` gets
it silently changed underneath. `check-as` never caught it despite
embedding the identical core, because `as` never exercises LINKER.S's
`$D000` write path.

The corrected invariant: **`PUTC` is not LC-transparent. A program that
holds LC state across a call into liba must restore it after.** `ld.s`
now re-selects write-enabled bank 2 after `PUTC` returns. Worth
generalising if a second such program appears -- and worth remembering
that the gate proved the wrong proposition confidently.

So: **select bank 1, use the buffer, restore bank 2 before any syscall.**
A bracket, exactly like the 80STORE bracket around bank copies
(learning:01KW1GTYHGXMBZNR6DMQB2F712). This is the same shape as the
three bugs this project has already paid for -- the `$C800` reclaim, the
escaped `RAMWRT`, the ALTZP assumption -- every one of which was global
state crossing a boundary while the rule lived in someone's head. It
needs a gate (sec 6), not a comment.

Interrupts are safe: the tick handler and the `$FFxx` page live in the
common region and never touch `$D000-$DFFF`.

**`as` must NOT use this.** Both its LC banks hold Merlin's own code
(MACED/MACEXEC/MACASS in one, LINKER+ASS.BNK1 in the other). `as`
instead reads large chunks directly into its own source window, which it
has anyway -- same win, no new mechanism, and the one program that cannot
afford the latch discipline never takes it on.

## 6. Gates

- **K1/K4** -- existing file gates (`check-catread`, `check-sh`,
  `check-v1-system`) cover correctness; the win is a cycle measurement,
  so record before/after the way `check-sticky` records cold vs warm.
- **K2** -- `check-v1-system`'s pipelines already assert byte-exact
  content through pipes, including a 3-stage `cat | cat | cat` crossing
  the 512-byte buffers. That is the correctness net; add a cycle count.
- **Buffered streams** -- a new gate asserting: identical bytes with and
  without buffering; a line-buffered prompt appears BEFORE the read that
  follows; and **exit flushes** (a program that writes without an
  explicit flush and exits must still land its bytes).
- **The sec 5 invariant** -- the gate that matters most: a program that
  selects bank 1 and then makes a syscall must be caught. Assert the
  latch state at syscall entry, or run a deliberate violator and require
  a loud failure. An invariant with no gate is a comment.

## 7. Two questions to settle before building (graded `[likely]`)

1. **Does ProDOS 8's READ transfer whole blocks directly into
   `data_buffer` when the request is block-sized and the mark is
   block-aligned?** If yes, K1 removes a copy per byte, not merely call
   overhead, and is worth more than the arithmetic suggests. The TRM
   should settle it; the commons may already hold it.
2. **Does `BankCopy` already special-case main->bank?** It distinguishes
   `BC_KIND_MAIN` from `BC_KIND_BANK`, but the 256-byte bounce buffer
   suggests everything round-trips. Decides K4.

## 8. Order

K1 first -- it makes big reads cheap. Then the `as` read-size fix (its own
window, no new mechanism). Then K2/K3, which are independent of
everything else. Then buffered streams, which are the design pass: they
make big reads HAPPEN, and landing them before K1 would see every 4K
read chopped into 32 MLI calls on arrival.

## 9. 2026-08-20 results (task #16: K1 landed, `as` reads bigger)

**sec 7 question 1 -- SETTLED, graded `[likely]`.** Measured, not found in the
TRM text via the commons (searched `mcp__street-library__search` across
several phrasings of "READ call data_buffer io_buffer block-aligned
bypass" -- the TRM artifact is indexed but the search snippets never
surfaced the exact algorithm paragraph; this is itself a library gap,
noted below). Measured instead on real vendored ProDOS 2.4 code
(`build/mli_spike.po`, task #11's `src/test/prodos.spike.s`, unmodified)
under verilogapple's fast backend: opened a fresh 2048-byte file (mark=0,
so the very first READ is block-aligned by construction), snapshotted the
file's own 1024-byte `io_buffer` (`mem_diff`, read-only) immediately
before the `JSR MLI` READ call, ran the real call to completion (measured
cost: 448,556 cycles -- matches `scripts/check_mli.py`'s own independently
measured 448,511 for the identical call to within the small variance of a
different single-step nudge count), then diffed `io_buffer`.

**Result: `io_buffer` was touched (124 of 1024 bytes changed), but not by
the file's DATA.** The touched bytes span offsets 0-515 and mostly become
`0`, with a handful of small values (`49, 51, 52, 53`) at low offsets --
the shape of a ProDOS **index block** (low/high split block-number table,
TRM), not of the file's own 4 blocks of content. Meanwhile `data_buffer`
(`READ_DST_BUF`, a separate destination) received the correct 2048-byte
ramp **byte-for-byte** (verified against `WRITE_SRC_BUF`'s known pattern).
**Conclusion: for a block-sized, block-aligned request, ProDOS's READ
call transfers the block DATA directly into the caller's `data_buffer`,
and only touches `io_buffer` for its own index-block bookkeeping -- not as
a staging bounce for the payload.** This matches K1's premise: raising
`PMLI_XFR_SIZE` to one full block removes a byte-for-byte copy through
`io_buffer` on the ProDOS side, not merely MLI call overhead.

Graded `[likely]`, not `[fact]`: one scenario only (a 4-block sapling-ish
file, mark=0), not cross-checked against the TRM's own algorithm text, and
the non-aligned contrast case (a sub-block request, which should show
`io_buffer` filled with real payload bytes) was attempted but the
measurement was unreliable (see "methodology gotchas" below) and is not
reported as data. **Deposit-worthy**: this mechanism (`io_buffer` used for
index-block housekeeping, not data staging, on an aligned READ) does not
appear to be in the commons yet -- reported here per this task's
instruction to report rather than deposit.

**Methodology gotcha, recorded for the next user of this MCP surface:**
calling `until_pc` a second time immediately after a first `until_pc` call
already landed exactly on the target PC returns a bogus near-instant
"hit" (observed: 8 cycles instead of the real ~448K) -- reproduced with
and without intervening `poke` calls, so it is not a poke side effect.
`scripts/check_mli.py`'s own existing pattern (a 30x `step_inst` walk
between the two `until_pc` calls) avoids it; this task's own measurement
scripts adopted the same pattern. Root cause not chased into
verilogapple's own source -- flagged, not fixed.

**K1 landed**: `PMLI_XFR_SIZE` 128->512 (`src/kernel/process.s`), block-
aligned, at its existing fixed address `PMLI_XFER_BUF=$7000` (unmoved).
`PRC_CHUNK` grew 1->2 bytes (a 512 chunk no longer fits a byte) --
`src/kernel/process.s`'s own `ds`. Every consumer checked and updated:

- `PRC_PCK_CHUNK` (`src/kernel/procfd.s`) -- was a 1-byte immediate
  compare (`cmp #PMLI_XFR_SIZE`, silently truncating a >255 constant to
  its low byte); rewritten as a real 16-bit `MIN(PRC_REMAIN,
  PMLI_XFR_SIZE)`.
- `PRC_FILE_READ` / `PRC_FILE_WR` (`src/kernel/procfile.s`) -- the
  `MLI_REQHI` field was hardcoded `stz` (chunk size assumed to fit in
  `MLI_REQLO` alone); now loads `PRC_CHUNK+1`. The short-read/short-write
  "did ProDOS give us the whole chunk" check (`TRANS` vs `CHUNK`) was
  also a 1-byte compare relying on `TRANSHI` always being 0 (true only
  while chunks stayed <=255); rewritten as a 16-bit compare in both
  routines.
- `PRC_LD_FL_IMG` (`src/kernel/procspawn.s`, spawn's file-backed image
  loader) -- same `MLI_REQHI` fix as the read path; it shares
  `PMLI_XFER_BUF`/`PRC_PCK_CHUNK` with `PRC_FILE_READ` and needed the
  identical correction. Its own EOF detection relies on ProDOS's
  `MLI_ERR_EOF` return, not a TRANS-vs-CHUNK compare, so no second fix
  was needed there.
- `sticky.s`'s `SB_STAGE` (spawn-image cache population) reads
  `PMLI_RD_PARMS+MLI_TRANS*` directly, never `PRC_CHUNK` -- unaffected by
  either width change, confirmed by re-reading it, not just grepping.

**Space verified genuinely unclaimed** (docs/MEMMAP.md task #16 addition,
above): `merlin32 -v1` build of `src/test/fileproctest.s` (same
`KERNEL_PROC_MODS` set `MAUXSH.SYSTEM`/`v1_system.po` actually ship) shows
this kernel's real code+data ending at `$567F`; nothing occupies
`$6000-$71FF` (the 4 io_buffers plus the now-512B transfer buffer),
verified by filtering the assembler's own Code/Data address column, not
by inspecting `ds` sizes by hand.

**`as` reads bigger**: `src/bin/as.s`'s source-read loop now reads
**1024 bytes/call directly into its own source window** (`SRC_BASE`,
walking `PTR2` forward), transforming the CR/LF->`$8D` + high-bit-set
translation **in place** instead of staging through a 64-byte `CBUF` and
copying byte-by-byte with an 8-bit `X` index. `CBUF` is gone entirely
(the direct-to-destination read needed no scratch buffer at all -- a net
shrink of this front end's own below-`$2000` footprint, not a growth).
`RPARM_BUF` is now patched to `PTR2` every iteration instead of a fixed
address. A 28KB module: **old ~ 450 syscalls (28672/64), new ~ 28
(28672/1024) -- a ~16x cut**, arithmetic only (see gate status below for
why this could not be measured live this round). Confirmed the file
never uses LC bank 1 either before or after this change (PROCIO.md sec 5) --
the read target is `SRC_BASE`, ordinary process memory, not LC.

**Cycle measurements -- BEFORE/AFTER, with an honest caveat.** The one
real, clean, repeatable number this task obtained is the cost of a single
block-aligned ProDOS MLI READ call in isolation: **448,556 cycles** for
2048 bytes (4 blocks), independently corroborated by
`scripts/check_mli.py`'s own 448,511-cycle measurement of the identical
call. That number is disk-transfer-dominated (real SmartPort block I/O
under the fast backend), not request-size-fixed-overhead-dominated, so it
does **not**, by itself, show K1's win -- K1's win is in *call count*
(4 MLI dispatches + 4 `BankCopy` invocations collapsing to 1 of each for
a 512-byte `read()`), not in per-byte transfer cost, which is the same
either way for the same total bytes moved. **This task could not obtain
a live before/after measurement of maux's own `PRC_FILE_READ` path**
(see the gate-status blocker immediately below) -- every kernel image that
would exercise it failed to assemble for a reason unrelated to K1. In its
place, an ANALYTICAL estimate, clearly labeled as such: `BankCopy` is
documented elsewhere in this file (sec 2) at ~20 cyc/byte, so a 512-byte
`read()` costs approximately `4x(128x20) = 10240` cyc of `BankCopy` time
under the OLD chunking vs `1x(512x20) = 10240` cyc under the NEW one --
**the `BankCopy` byte-copy cost is unchanged** (same total bytes moved
either way); the win is strictly the fixed per-call overhead of 3 fewer
`JSR MLI` dispatches and 3 fewer `BankCopy` invocation/parameter-setup
sequences per 512 bytes read. This estimate should be replaced with a
real measurement once the blocker below clears.

**Gate status -- BLOCKED, root cause identified and is NOT this task's
code.** `make check-catread check-sh check-v1-system check-fileprocess
check-sticky check-as check-ls check-ed` and `make check-all` could not
be run to completion: every one of them assembles
`src/kernel/entry.s` transitively (via `src/test/*.s` -> `put
../kernel/entry.s` -> entry.s's own `put inc/entry.frame.equ`), and
that inner `put` currently fails outright (`FRAME_Y` undefined). Root
cause, isolated with a minimal two-level `put` nesting reproduction in
scratch space (no repo files touched): **merlin32 v1.1.10 does not
process `put` directives found inside a file that was itself brought in
by another file's `put`** -- its own "Loading Sources files" log lists
only the top-level file and its DIRECT puts; a put nested one level
deeper is silently never opened, regardless of the path written (tried
both `inc/entry.frame.equ` and a from-scratch-relative
`../../inc/entry.frame.equ` -- neither loads, confirming it is a
depth limitation, not a path bug). `entry.s`/`sched.s`/`procspawn.s`/
`sticky.s` all added a `put inc/entry.frame.equ` line at HEAD commit
`8a9757f` ("conversion phase 1: hoist cross-file equates into
per-concern includes"), which lands at exactly this nesting depth from
every `src/test/*.s` harness -- so it can never have worked as written for
any of them. **Verified NOT caused by this task's changes**: `git stash`
of every file this task touched, then re-running the identical build,
fails identically on a fully clean tree. This is a merlin32-dialect
finding worth a street-library deposit (the commons currently has zero
Merlin coverage per this project's own conventions) -- reported here per
this task's "report, don't deposit" instruction; entry.s/sched.s are
explicitly outside this task's ownership so no fix was attempted. One
consequence: `make check-mame` phase 4 (the type-ahead/CLI-bracketed MLI
window regression gate this task was told to run if K1 might disturb it)
is **also blocked** by the same root cause and could not be run this
round.

**What WAS verified**, independent of the blocked gates: `src/bin/as.s`
assembles cleanly standalone (`merlin32 src/bin/as.s`, no kernel
dependency); the full `KERNEL_PROC_MODS` set with K1 applied assembled
cleanly at 12:18 on 2026-08-20 (before the entry.s regression landed at
12:20) -- that build is what MEMMAP.md's `$6000-$71FF` unclaimed-space
verification above is drawn from, and its `build/MAUXFILEPROC.SYSTEM`/
`_Output.txt` are still on disk, timestamped before the break, as
evidence K1 assembles correctly with the rest of the kernel.

**Open risks for the next task to pick up**: (1) land the merlin32
nested-`put` fix (flatten `entry.s`/`sched.s`/`procspawn.s`/`sticky.s`'s
`entry.frame.equ` include back to direct top-level `put`s in every
harness, or confirm/fix the assembler's own nesting support) before
re-running the full gate list this task was asked to run; (2) once
unblocked, get a REAL before/after cycle count for `PRC_FILE_READ`/
`PRC_LD_FL_IMG` and for `as`'s own source-read loop, replacing the
analytical estimates above; (3) run `make check-mame` phase 4.

## 10. 2026-08-20 results (task #17: K2/K3 landed, bulk pipe/tty transfer)

**K2 landed** (`src/kernel/procfile.s` / `src/kernel/procfd.s`): `PRC_READ`'s
and `PRC_WRITE`'s pipe branches no longer call `PPP_GET_BYTE`/`PWRPAR_BYTE`
(or `PRDPAR_BYTE`/`PPP_PUT_BYTE`) per byte. Each direction now:

1. computes `N = MIN(requested, available)` -- `PIPE_BYTES[pipe]` for a
   read, `255-PIPE_BYTES[pipe]` for a write (the existing $FF-is-full
   cap, unchanged -- the ring is a 256B page per pipe but the single-byte
   `PIPE_BYTES` counter tops out at 255, so that was always the real
   capacity, K2 did not touch it);
2. splits `N` across the ring's `$xx00` wrap boundary with plain 8-bit
   arithmetic: `RUN1 = MIN(N, 256-RDP_or_WRP)`, `RUN2 = N-RUN1` (0 unless
   the transfer actually crosses the boundary);
3. issues one `BankCopy` per run (bank-to-bank: the ring lives in annex
   bank 0, the caller's buffer in its own process bank -- `BankCopy`
   already supports this via its own bounce buffer, no new mechanism
   needed) -- at most two calls total, matching sec 3's "two across a wrap";
4. advances `PIPE_RDP`/`PIPE_WRP` and `PIPE_BYTES` by `N` in one step
   (an 8-bit `ADC` wraps exactly at the 256-byte page boundary, so no
   explicit modulo is needed), sets `PRC_TRANS = N`, and falls into the
   SAME tail every path already used (`PCPO_MLIPARM`, `SCH_WAKEUP` on the
   other side's wait channel, `PRC_SEL_CRBNK`) -- unchanged.

Semantics preserved exactly: short reads (ring holds less than
requested), EOF (no writers, ring empty), the $FF-full block/retry on
write, and the blocking/wakeup channels are all untouched -- only the
byte-mover between "how many bytes" and "copy them" changed. A `BankCopy`
failure (a bad caller pointer) is handled by failing the whole call
before any ring bookkeeping is touched, rather than the old per-byte
path's partial-consume-then-rollback -- a strictly cleaner failure state
for a case no gate exercises either way.

**K3 landed** (`src/kernel/tty.s`): `TTY_READ`'s committed-line copy to
the caller is the same technique minus the wrap -- `TTY_INBUF` is a plain
128-byte linear buffer (no ring), so it is always exactly one `BankCopy`
of `MIN(requested, TTY_IN_LEN-TTY_IN_POS)` bytes from
`TTY_INBUF+TTY_IN_POS` to the caller's buffer. `TTY_IN_POS` now advances
only AFTER a successful copy (versus the old per-byte loop's advance-
then-roll-back-on-failure), which lands at the identical end state on
the one failure path (a bad caller buffer) without needing the explicit
rollback arithmetic.

**The module-size crisis this caused, and the fix.** Landing K2 grew
`procfile.s` past real Merlin's per-module ceiling
(`MODULE_MAX = 37000`, `scripts/shrink_source.py`, derived in
docs/TOOLCHAIN.md from the 41215-byte source buffer minus the resident
top-level manifest) -- `make check-dual` failed with real Merlin's own
`56 MEMORY IN USE`. Comments could not close a 6KB gap the way
docs/TOOLCHAIN.md's sched.s precedent did with 69 lines; this needed an
actual relocation. Fix, in two moves, both pure text relocation with
zero logic change (kernel modules are one flat symbol space already --
`PPP_REQ_LIMIT` living in `procspawn.s` and being called from
`procfile.s` is the same convention):

- `PRC_READ`/`PRC_WRITE` (K2's new bulk code included) moved from
  `procfile.s` to `procfd.s`, which had the room; the now-dead
  `PPP_GET_BYTE`/`PPP_PUT_BYTE` (K2's only casualties -- nothing else
  called them) were deleted from `procfd.s` in the same pass.
- That overshot `procfd.s`'s own ceiling in turn (37833B), so
  `PRC_FDACTIONS`/`PRDFDA_TARGET`/`PRDFDA_SOURCE` (unrelated to pipes --
  the `dup`/`close` half of `spawn()`'s fd-inheritance table) moved
  the other way, from `procfd.s` to `procfile.s`, which by then had the
  room K2's departure freed up.

Final sizes, all under 37000: `procfile.s` 33898B, `procfd.s` 35662B,
`tty.s` 36503B (unchanged by K3 -- line-count-neutral). `make check-dual`
now passes: real Merlin-8 2.59 and merlin32 produce a byte-identical
14336-byte kernel. (The merlin32 nested-`put` blocker recorded in sec 9 above
was independently fixed by another task, commit `004bd02`, before this
task started -- not this task's fix, just unblocking.)

**K2 gate -- `check-pipewrap`, new** (`src/test/pipewraptest.s` +
`pipewraptestb.s`, `scripts/build_pipewrap_image.py` +
`check_pipewrap.py`, `make check-pipewrap`). sec 6 asked for a test that
deliberately crosses the wrap and asserts byte-exactness; `check-v1-
system`'s `cat | cat | cat` pipeline never pushes anywhere near 256 bytes
through a single pipe stage, so nothing in the existing suite actually
exercised `RUN2 != 0`. The new gate: a single process holding both ends
of one pipe writes 200 bytes (`0..199`), reads 150 back (discarded,
leaving `RDP=150`), writes 200 more (`(200+i) mod 256` -- this write
itself wraps, `WRP` 200->144 crossing `$xx00`), then reads all 250
remaining bytes back (this read ALSO wraps, `RDP` 150->144 crossing
`$xx00`). Because both writes are one continuous mod-256 counting
stream, the expected read-back has a closed form --
`R_DATA[p] = (150+p) mod 256` for `p=0..249` -- checked byte-exact
against the real bytes, not just "some bytes came back." Verified this
is a REAL test of the wrap, not a vacuous one: run against the
PRE-K2 kernel (`git show HEAD:src/kernel/{procfile,procfd,tty}.s`
swapped in, rebuilt, restored after) it also passes byte-exact -- same
ring, same wrap arithmetic, different mover -- confirming the test
checks the RING's correctness, not an artifact of one implementation.

**Cycle measurement -- real numbers, both directions, across the wrap.**
`check_pipewrap.py` polls cumulative cycles at each `R_STEP` transition
(same technique as `check_sticky.py`'s cold/warm phase markers) around
the four transfers above. Measured on verilogapple's fast backend,
before (pre-K2, per-byte `PPP_GET_BYTE`/`PPP_PUT_BYTE`) and after (K2
bulk `BankCopy`), same scenario, same byte counts:

| transfer                    | BEFORE (cyc) | AFTER (cyc) | speedup | before cyc/B | after cyc/B |
|------------------------------|-------------:|------------:|--------:|-------------:|------------:|
| write 200B (no wrap)         |      119,000 |      20,800 |   5.7x  |         595  |         104 |
| read 150B (no wrap)          |       91,800 |      19,200 |   4.8x  |         612  |         128 |
| write 200B (**WRAPS**)       |      118,800 |      21,400 |   5.6x  |         594  |         107 |
| read 250B (**WRAPS**)        |      144,600 |      23,000 |   6.3x  |         578  |          92 |

`pipe()` creation itself (no ring traffic) cost 2,800 cycles both before
and after, as expected -- K2 only touches the data-mover, not pipe
allocation. The wrap-crossing transfers (two `BankCopy` calls instead of
one) cost only marginally more than their non-wrapping same-size
neighbours (21,400 vs 20,800 for the two 200B writes; the extra
`BankCopy` invocation/parameter-setup overhead is small next to the
per-byte savings), confirming sec 3's "at most two calls" design does not
reintroduce a wrap penalty anywhere near the old per-byte cost. Every
number above is a real `step`-polled cycle count from the emulator, not
an analytical estimate -- unlike sec 9's K1 numbers, this task's blocker
(the merlin32 nested-`put` break) had already been fixed before this
task started, so a live measurement was possible throughout.

**Gate status.** `make check-v1-system check-sh check-play check-catread
check-fileprocess check-sticky check-modules check-pipewrap`: all PASS.
`make check-all` (29 targets incl. `check-dual`, `check-pipewrap`): all
PASS. `make check-mame`: see the task's own final report for verbatim
phase output (the tty/type-ahead paths K3 touches are its phase 4).

**Open risks for the next task**: sec 9's K1 items (2) and (3) -- a live
`PRC_FILE_READ`/`PRC_LD_FL_IMG`/`as` cycle count and confirming
`check-mame` phase 4 under K1 specifically -- are still open; this task
only re-confirmed phase 4 passes with K2/K3 also applied, it did not
re-derive K1's own numbers.

## 11. 2026-08-20 results (task: profile `ls` -- where the time actually goes)

**Hypothesis under test** (the operator's, from reading the code after K1-K3
landed): `ls` prints names via liba's `PUTC`, which issues one `SC_WRITE`
per character, so the unchanged visible echo speed of `ls` is explained by
per-character syscall cost dominating. This section MEASURES that, on the
verilogapple fast backend, rather than taking it on faith.

**Rig and method.** `build/play.po` (`make play-image`, unmodified --
real interactive `sh` + `ls` + the rest of `KERNEL_PROC_MODS`, booted from
disk) under `reset {backend: fast}` (verilogapple's default config: NO
UltraTerm card -- `ultraterm` defaults `false` -- matching the rig the
operator actually observed the slowdown on). `ls\r` is typed at the live
`$ ` prompt with the `type` MCP tool, which queues into the emulator's real
keyboard-latch model (drained through the actual `KBD_DATA`/`KBD_STROBE`
hardware path on each `step` -- not a memory poke). Phases and single-call
costs are delimited with `until_pc` breakpoints at addresses pulled from
`build/MAUXPLAY.SYSTEM_Output.txt`'s own symbol table (regenerate with
`cd src/bin && merlin32 -v1 ../test/playtest.s`; not checked in). Every
anchor used is either the fixed common `$FFxx` page (`$FF00`=`FFP_SYSC_ENT`,
the syscall gate; `$FF22`=`FFP_EXIT_TAIL`, the shared return -- byte-
identical in every bank per `src/kernel/ffpage.s`) or a kernel routine
resident in MAIN memory (`entry.s`/`procfd2.s`/`tty.s`/`tty2.s`) -- never a
process-bank-local address, which is what makes repeated `until_pc` safe
against the bank-per-process hazard (a different process's code loaded at
the same numeric address could otherwise false-hit). The documented
same-target-twice-in-a-row `until_pc` bug (sec 9 above) is avoided
throughout by a small `step_inst` walk before ever re-arming a breakpoint
on a PC we might already be sitting on.

Scratch driver scripts (kept under `scripts/`, not gates, not wired into
`make check-all`):
- `scripts/profile_ls_echo.py` -- cold end-to-end phase bracket + syscall
  tally for one `ls` of `/BASIC` (15 entries: `PRODOS`, `MAUX.SYSTEM`, `sh`,
  `echo`, `cat`, `ls`, `cp`, `rm`, `ed`, `grep`, `wc`, `mkdir`, `mv`, `pwd`,
  `ps` -- the real files `make play-image` stages).
- `scripts/profile_putc_decompose.py` -- fine-grained breakpoint chain
  across ONE representative `SC_WRITE` call (the 3rd character written, to
  skip any first-call warm-up quirk).
- `scripts/profile_ls_echo_warm.py` -- repeats the phase bracket for a
  SECOND `ls\r` in the same boot session, to compare against sticky.s's
  (task #15) warm spawn-image cache -- the scenario an operator actually
  experiences typing `ls` more than once.

### 1. End-to-end phases, one cold `ls`

Boundaries (all kernel-side, bank-invariant addresses): keystroke queued
(`type` call) -> sh issues `SPAWN` (`PRC_SPAWN` entry) -> the child's own
directory `OPEN` (`PRC_OPEN` entry) -> its first character reaching the tty
(`TTY_WRITE` entry) -> the child's `SC_EXIT` (`PRC_EXIT` entry).

| phase | cycles | % of total | what it covers |
|---|---:|---:|---|
| keypress -> `SPAWN` | 107,729 | 7.9% | sh drains "ls\r" off the keyboard ring, cooks the line, `READLINE`/tokenize/parse, dispatches `SPAWN` |
| `SPAWN` -> child's `OPEN` | **748,444** | **54.6%** | bank alloc + **cold** load of the 7,746-byte `ls.bin` from disk into the fresh bank (`PRC_LD_FL_IMG`), argv setup, child's own `GETPFX`, path build |
| `OPEN` -> first char written | 226,916 | 16.6% | `OPEN` the directory, 2x 512B `READ` (15 entries x 39B > one block), walk entries into `ENTRIES`, `CLOSE`, `SORTENTRIES` (insertion sort), `PRINTENTRIES` setup |
| first char -> `EXIT` | 286,682 | 20.9% | all 67 `PUTC`-driven `SC_WRITE` calls (one per output byte) + the print loop's own overhead |
| **total** | **1,369,771** | 100% | ~ **1.34 s** at ~1.023 MHz |

**The single biggest contributor is process spawn/load, not output** --
54.6% of the cold total, more than 2.6x the output/echo phase. This is a
real disk-backed cost (loading 7,746 bytes through `PRC_LD_FL_IMG`, itself
built on the same K1-sized 512B `PMLI_XFR_SIZE` chunking as file `read()`)
that the hypothesis did not name at all.

**Warm (repeat) `ls` changes the mix, not the verdict.** A second `ls\r` in
the same session (`profile_ls_echo_warm.py`) hits sticky.s's warm spawn-
image cache: `SPAWN`->`OPEN` drops to 402,773 cycles (1.86x faster than
cold) -- still the largest phase, now 39.3% of a clean (non-scrolling)
warm total. `OPEN`->first-write is **identical both times**, 226,916
cycles exactly (same directory, same bytes, deterministic -- a useful
internal consistency check on the whole method). The measured *warm*
first-write->`EXIT` (673,323 cycles, 2.35x the cold figure) is NOT a
regression in `PUTC` cost: after the first `ls` printed 15 lines, the
cursor sits at screen row 17 of 23 usable body rows, and the second
listing's 16 more lines (15 names + new prompt) run the terminal off the
bottom, forcing real `TTY_SCROLL` work partway through. Using the cold
(non-scrolling) output-phase figure as the fair warm proxy, a clean warm
total is 107,729 + 402,773 + 226,916 + 286,682 = **1,024,100 cycles
(1.00 s)**, genuinely faster than cold thanks to sticky, with spawn/load
still on top. **Screen scrolling is a third, previously unnamed cost
center** -- not raised by the operator's hypothesis, not something K1-K3
touch, and, once the terminal has scrolled a few times, capable of costing
more than either spawn/load or output alone (673,323 cycles measured here,
larger than 748,444's cold spawn/load only by a hair less than 2x). Not
sized further this task -- flagged for whoever picks up terminal-output
work next.

### 2. Cost per character of output (`SC_WRITE` gate to return, one byte)

One clean (no VBL/mouse-IRQ interference) round trip, `$FF00` to `$FF22`,
for the 3rd character of the plain listing:

| hop | cycles | |
|---|---:|---|
| `$FF00` (gate stub: php/sei/cld/3x push/2x softswitch/jmp) -> `KRN_ENTRY` | 31 | fixed, every syscall |
| `KRN_ENTRY` -> `PCPI_CALLPARM` | 107 | frame capture, ALTZP flip, TXS, dispatch compare/table/`jsr` |
| `PCPI_CALLPARM` -> `PRC_CUR_FDOBJ` | **459** | **copies the 8-byte MLI parmlist IN, cross-bank, via `COPYIN_ENTRY`** |
| `PRC_CUR_FDOBJ` -> `PRC_GET_FDOBJ` -> `PCB_PTR_FOR` -> `PCB_RD_FIELDS` -> `TTY_WRITE` | 21+9+97+125 = 252 | fd range check + PCB-array fd-table lookup (device range, no OFT walk for tty) |
| `TTY_WRITE` -> `TTY_CRSR_HIDE` | 31 | `TTY_WRITE`'s own preamble (`P_COUNT`, cursor-hide call) -- **once per call, not per byte** |
| `TTY_CRSR_HIDE` -> `PRDPAR_BYTE` | 49 | cursor-hide body |
| `PRDPAR_BYTE` -> `TTY_SHDW_TAP` | 320 | **the actual 1-byte cross-bank payload copy**, via the same `COPYIN_ENTRY` primitive as above |
| `TTY_SHDW_TAP` -> `TTY_PUT_BYTE` | 58 | `^L`-replay shadow record |
| `TTY_PUT_BYTE` -> `TTY_PUT_NORM` | 28 | esc-state dispatch |
| `TTY_PUT_NORM` -> `TTY_PUT_PRNTB` | 38 | control-byte classification cascade |
| `TTY_PUT_PRNTB` -> `TTY_WR_CELL` | 6 | |
| `TTY_WR_CELL` -> `PCPO_MLIPARM` | 148 | 40-col fold + screen store (`UT_PRESENT` false -- no $C800 claim, see sec 3) + `TTY_PUT_PRNTB`'s column-advance tail + loop exit |
| `PCPO_MLIPARM` -> `KRN_EXIT` | **458** | **copies the 8-byte parmlist (`trans_count` result) back OUT, cross-bank, via `COPYOUT_ENTRY`** |
| `KRN_EXIT` -> `$FF22` | 47 | frame patch, ALTZP/bank flip, TXS, `jmp` |
| **total, `$FF00`->`$FF22`** | **2,032** | one character |

**The two 8-byte cross-bank parmlist copies (`PCPI_CALLPARM` + the
`PCPO_MLIPARM` copy-back) are, together, the single biggest named
contributor: 917 of 2,032 cycles (45%)** -- for a call whose actual
payload is exactly one byte. `PRDPAR_BYTE`'s own payload copy (320 cycles)
and the fd-table lookup (252 cycles, paid on every call even though the fd
never changes) round out the top contributors. Splitting the total into a
**fixed, once-per-call** component (gate/exit, `PCPI_CALLPARM`,
`PCPO_MLIPARM`, fd resolve, `TTY_CRSR_HIDE`, `TTY_WRITE` preamble = 1,582
cycles) and a **repeating, per-byte** component (`PRDPAR_BYTE` through the
`TTY_WR_CELL` call = 450 cycles) is what section 5's projection below is
built from.

Averaged over all 67 real characters written (`profile_ls_echo.py`'s
consecutive-`KRN_ENTRY` deltas), the loop-inclusive per-character cost
clusters tightly at **2,130-2,290 cycles** (mean of the 64 non-outlier
gaps: 2,244 cycles -- close to, and consistent with, the 2,032-cycle clean
gate-to-gate figure above once liba's own `PUTC`/print-loop overhead
between calls, ~150-250 cycles, is added back in). Two of the 66 gaps
(~3%) show a ~70,700-cycle spike each, consistent with the AppleMouse
card's 60 Hz VBL interrupt landing mid-loop -- a real, measured cost of
running under an active periodic IRQ source, reported but not chased
further this task.

### 3. Cost per byte of the directory read (comparison, post-K1)

From the same run: `PRC_OPEN`'s handler body entry (2,456,173) to the first
`READ`'s `KRN_ENTRY` (2,473,673) is 17,500 cycles for the `OPEN` MLI call
itself. The two READs that follow (root directory: 15 entries x 39B > one
512B block, so K1's 512-byte `PMLI_XFR_SIZE` still needs 2 calls here, not
1 -- this directory just doesn't fit in one block regardless of K1):

| call | cycles | bytes requested | cyc/byte |
|---|---:|---:|---:|
| READ #1 | 39,030 | 512 | 76.2 |
| READ #2 | 32,709 | 512 (partial block, 73B of real content) | 63.9 (73.9 vs bytes actually needed) |
| **both READs together** | **71,739** | **1,024 requested** | **70.1** |

This is a different, LARGER quantity than sec 2's original 1
`BankCopy`-only analytical estimate (~20 cyc/byte, sec 2) -- these numbers
include the real MLI/SmartPort disk-transfer cost, not just the in-memory
copy, so they are not directly comparable to that figure; flagged so a
future reader doesn't conflate the two. It IS comparable in kind (bulk
cross-bank/cross-medium transfer, post-bulking) to K2's own measured pipe
rates (sec 10 above: 92-128 cyc/B for `BankCopy`-only pipe transfers) --
similar order of magnitude, with the directory read paying extra for the
real disk round trip pipes don't have.

### 4. Syscall count, one `ls` (measured, not derived)

`ls`'s OWN syscalls, tallied by `K_CALLNUM` at every `KRN_ENTRY` from the
child's first call to its `SC_EXIT` (`profile_ls_echo.py`'s pass 2 --
note the raw per-hit read of `K_CALLNUM` lags the true call by one hit,
since `until_pc` lands ON `KRN_ENTRY`'s first instruction, before its own
`sta K_CALLNUM`; corrected for in the count below and cross-checked
against the independently-measured `PRC_OPEN`/`TTY_WRITE`/`PRC_EXIT`
landing cycles, which all agree to within the ~100-cycle dispatch-overhead
window):

**73 syscalls**: 1 `GETPFX` + 1 `OPEN` + 2 `READ` + 1 `CLOSE` + **67
`WRITE`** (exactly matching the independently-computed 67 output bytes:
52 name characters + 15 CRs across 15 entries) + 1 `EXIT`. `sh`'s own
`SPAWN` and (first attempt at) `WAIT` add 2 more kernel-gate crossings
around the command, for 75 total `$FF00` hits observed in the window; a
second `WAIT` retry (PRC_BLCK_RTRY's rewind-and-reissue) happens after
`ls` wakes it and was not counted here (past this task's window).

**91.8% of `ls`'s own syscalls (67 of 73) are `SC_WRITE` calls for a
single output byte each** -- the hypothesis's premise (one syscall per
character) is exactly confirmed as a COUNT, even though sec 1 shows it is
not the dominant COST.

### 5. Projected buffered-stream win (PROJECTION, not measured)

Using sec 2's measured split -- 1,582 cycles fixed per `SC_WRITE` call,
450 cycles repeating per payload byte inside `TTY_WRITE`'s current
byte-at-a-time loop -- against the real 67-byte, 15-line `ls` output:

- **Current** (67 separate 1-byte calls, liba unbuffered, as shipped):
  67 x 2,032 = **136,144 cycles**.
- **liba buffers per LINE, flushes on `$8D`** (PROCIO.md sec 4's own
  design: line buffering for the tty) -- **kernel `TTY_WRITE` UNCHANGED**
  (still loops per byte internally, so only the syscall COUNT drops, not
  the per-byte rate): 15 flushes x (1,582 + 450 x 4.47 avg bytes/line)
  = 15 x 3,594 ~ **53,880 cycles -- a 2.5x reduction**, from liba-side
  work alone.
- **liba buffers the WHOLE 67-byte run** (one flush, `BUFSIZ`=512 covers
  it easily), kernel still unchanged: 1 x (1,582 + 450 x 67) = 1,582 +
  30,150 = **31,732 cycles -- a 4.3x reduction**.
- **liba buffers the whole run AND `TTY_WRITE` gets the same K2/K3-style
  bulk `BankCopy` treatment its own `TTY_READ` sibling already has**
  (projected per-byte rate ~ K2's measured ~100 cyc/B bulk pipe rate,
  sec 10): 1,582 + 100 x 67 = **8,282 cycles -- a 16.4x reduction**, but
  this last scenario requires a KERNEL change (`TTY_WRITE`'s output loop
  is not currently a K1/K2/K3-style bulk-transfer target anywhere in this
  document's plan) in addition to liba's buffered streams.

Even the smallest of the three (line-buffering, liba-only, no kernel
change) turns the 20.9%-of-total output phase into a minor cost next to
spawn/load -- but per sec 1, spawn/load (748,444 cold / 402,773 warm
cycles) dwarfs ALL three projected output-phase numbers regardless, so
none of them would make the operator's *visible* `ls` feel meaningfully
snappier on their own; buffered streams remain worth building (sec 4's
case stands on its own merits and on every OTHER PUTC-heavy program), but
they are not, by these numbers, where a cold `ls`'s wall-clock time goes.

### 6. The $C800 claim question (checked, not the live bottleneck)

`UT_PUT_CELL` (`src/kernel/ultraterm.s`) calls `UT_CLAIM` -- 2
soft-switch writes (`CLRINTCXROM`, `SETSLOTC3ROM`) + a release read
(`CLRC8ROM`) + the claim read (`UT_SIG`) -- **unconditionally, on every
single cell**, with no "already claimed this run" check anywhere in
`UT_PUT_CELL`'s body. Verified by reading (source, not inference) and by
one direct measurement: rebooting `play.po` with `reset {ultraterm: true}`
and bracketing two consecutive `UT_PUT_CELL` calls during the boot banner
gives **232 cycles cell-to-cell** (`UT_CLAIM` included). But: **this path
is dead code for the problem at hand.** `reset`'s `ultraterm` flag
defaults `false` (verified in `mcp_server.cpp`), `TTY_WR_CELL` branches on
`UT_PRESENT`, and every measurement in sections 1-5 above (default rig,
matching what the operator actually ran) took the 40-column branch --
direct `sta (P_PTR2),y` into text-page memory, no `$C800` claim at all.
**The per-cell `$C800` claim is a real, confirmed, unconditional cost, but
only on a rig with an UltraTerm card attached; it is not part of why `ls`
felt unchanged after K1-K3 on the rig where that was observed.** Worth
fixing (a one-`UT_PRESENT`-run "already claimed" latch, mirroring the
`UT_CLAIM` header's own "release the previous holder FIRST" comment about
shared $C800 real estate with the disk card) if/when UltraTerm becomes the
default test configuration, not before.

### Verdict

**The hypothesis partially held, and the more useful result is the
refutation of its "dominant cost" claim.** `PUTC`'s one-syscall-per-
character design is exactly as expensive per call as it looks from
reading the code (2,032 clean cycles, of which 45% is two 8-byte
cross-bank parmlist copies for one payload byte), and the count (67 of
73 of `ls`'s own syscalls) exactly matches the premise. **But it is not
the single biggest contributor to a real `ls`'s wall-clock time in either
scenario measured**: cold, process spawn/load (loading `ls.bin` from disk)
is 2.6x the output phase and 54.6% of the total; warm, spawn/load is still
the largest phase even after sticky.s's cache cuts it nearly in half, and
in the one warm run measured here, an unrelated third cost (screen
scrolling) outweighed both spawn/load and output combined. Ranked by
measured (not projected) size, cold `ls`, biggest to smallest:

1. **Process spawn/load** -- 748,444 cyc (54.6%) -- disk-backed image load,
   already partly addressed by sticky.s's cache (1.86x warm speedup
   measured) but still the largest phase even warm.
2. **Directory OPEN/READ** -- 226,916 cyc (16.6%) -- post-K1; further work
   here would need bigger directories to matter (this one is 585B, already
   under 2 blocks).
3. **Output/echo (`PUTC`-per-byte)** -- 286,682 cyc cold / 20.9% -- real,
   confirmed by both the syscall count and the per-call decomposition; the
   buffered-stream design (sec 4-5) projects a 2.5x-16.4x win here
   depending on scope, but even the best case doesn't touch #1 or #2.
4. **Screen scrolling** -- not sized as a standalone phase this task, but
   observed to cost 673,323 cyc when it fires mid-listing (warm run) --
   larger than #1-3 individually. New finding, not previously named
   anywhere in this document; worth a dedicated measurement before ranking
   it properly against the above.

## 12. 2026-08-20 results (task: close the spawn/BankCopy gap)

**The finding to explain**: sec 11 measured process spawn/load as the largest
phase of a cold `ls` (748,444 cyc, 54.6%) and still the largest phase warm
(402,773 cyc) through sticky.s's cache -- ~96 cyc/byte cold, ~52 cyc/byte
warm for `ls.bin`, against `BankCopy`'s documented ~20 cyc/byte
(docs/ARCHITECTURE.md). This section decomposes the warm path, measures
`BankCopy`'s ACTUAL rate, explains the gap, and fixes what the measurement
indicts.

**Method**: same rig as sec 11 (`build/play.po`, verilogapple fast backend,
`until_pc` bracketing kernel-resident addresses from
`build/MAUXPLAY.SYSTEM_Output.txt`'s symbol table), extended with a finer
breakpoint chain through `PRC_SPAWN`'s own warm-hit path: `PRC_SPAWN` ->
`PRC_ALLC_BANK` -> `PRC_STMP_BANK` -> `PRC_SYNTH_FRM` -> `PRC_LD_FL_IMG` ->
`SB_TRY_WARM` -> `PMLI_GFI_CALL` -> `BankCopy` -> `BC_RESTORE` ->
`PSTG_ARGV` -> `SCH_CREATE` -> `PRC_DFLT_FDS` -> `PRC_RET_OK_A` -> `ls`'s
own `PRC_OPEN`. Second `ls\r` in one boot session (cache already warm from
the first). Scratch driver, not a gate (not wired into `make check-all`,
per sec 11's own precedent).

### Warm spawn, decomposed (BC_CHUNK=128, before this task's change)

| part | cycles | % of total |
|---|---:|---:|
| parm copy + path byte + builtin-tag search | 218 | 0.1% |
| `PRC_ALLC_BANK` (bank allocation) | 656 | 0.2% |
| `PRC_STMP_BANK` ($FFxx stamp, 256B single-window copy) | 3,764 | 0.9% |
| `PRC_SYNTH_FRM` (frame synth) | 81 | 0.0% |
| `PCPY_SPWN_PTH` (path canonicalize) | 3,748 | 0.9% |
| `SB_LOOKUP` (cache directory scan) | 3,899 | 1.0% |
| `GET_FILE_INFO` MLI call + mtime compare (freshness) | 8,553 | 2.1% |
| **`BankCopy` itself, 7746B image, cache->child bank** | **302,647** | **75.1%** |
| `SB_WRITE_CUR` (entry hit-stamp refresh) + return | 1,804 | 0.4% |
| `PSTG_ARGV` (one arg, "ls") | 4,290 | 1.1% |
| `SCH_CREATE` + cwd copy + parent-PCB write | 3,169 | 0.8% |
| `PRC_DFLT_FDS` + `PRC_FDACTIONS` | 1,556 | 0.4% |
| **total, `PRC_SPAWN` kernel code only (sums exactly)** | **334,385** | 83.0% of window |
| `PRC_RET_OK_A` tail + return to `sh` + `ls`'s own startup up to ITS first syscall (not spawn's own cost -- `sh`/`ls` userland, out of this task's ownership) | 68,388 | 17.0% |
| **total, `PRC_SPAWN` entry -> `ls`'s own `PRC_OPEN`** | **402,773** | 100% |

Matches sec 11's own warm figure (402,773) exactly -- the finer chain is a
true partition of the same window, not a different measurement. **The
dominant term is `BankCopy` itself: 75.1% of the full window, 90.5% of
`PRC_SPAWN`'s own kernel-code cost.** Every other named part is under 2.1%.
`GET_FILE_INFO`'s freshness check -- the part sec 4/STICKY.md's own design
flagged as a per-hit cost -- is real (8,553 cyc) but two orders of
magnitude smaller than `BankCopy`; removing or amortizing it would risk
the staleness gate (`check-sticky`'s whole third phase) for under 2% of
the window. **Not touched.**

### `BankCopy`'s measured rate vs. its documented figure

Bracketing `BankCopy`'s own entry to `BC_RESTORE` (its shared, every-path
tail) gives the ACTUAL cost of the warm-hit's cache-bank -> child-bank
copy: **302,647 cycles for 7746 bytes = 39.07 cyc/byte** -- 2x
`docs/ARCHITECTURE.md`'s documented ~20 cyc/byte, and squarely the "52 is
2.6x that" gap this task was asked to explain.

**Why, read from `src/kernel/bankcopy.s`'s own `BC_LOOP`**: a bank<->bank
copy (both `K_BC_SRCKIND` and `K_BC_DSTKIND` = `BC_KIND_BANK`, exactly
the sticky-cache case) runs **both** windows every chunk -- window 1
(`COPYIN_ENTRY`: src bank -> `K_BOUNCEBUF` in main) AND window 2
(`COPYOUT_ENTRY`: `K_BOUNCEBUF` -> dst bank) -- because only one bank can
be `$C073`-selected at a time, so the source bank's bytes must land in
main memory before the destination bank can even be selected. A copy
where one side is already main (`BC_KIND_MAIN`) skips the OTHER window
entirely (`BC_SKIP1`/`BC_SKIP2`, unconditional on that side's kind) --
**this answers sec 7 question 2 definitively: yes, `BankCopy` already
special-cases main<->bank, has since it was written; nothing to land
there.** The ~20 cyc/byte documented figure describes ONE window/pass;
`ARCHITECTURE.md`'s fork-clone paragraph ("bounces via main... 8K image
approx 160ms") mislabeled a genuine bank<->bank transfer (which needs
BOTH passes) with the single-pass rate, understating it by about half.
This is hardware-inherent, not a `BankCopy` bug: the commons already
holds "bank-to-bank transfers must route via main memory"
(`learning:01KYYJ98T5R0M9K1AW2550M132`) as a bare qualitative fact: this
task's measurement refines it into the quantitative one (deposited as
`learning:01M0FAW65T4K4ZGWHXGJFPKRWC`) -- a real bank<->bank copy on a
single-`BANKSEL` card costs ~2x a single-window copy's rate, not the same
rate plus a fixed detour. **Verdict: the cache is delivering its own
design's arithmetic exactly; `docs/ARCHITECTURE.md`'s ~20 cyc/byte figure
was the error, describing the wrong operation.**

### The fix: `BC_CHUNK` 128 -> 254 (`src/kernel/bankcopy.s`)

The only lever left inside this task's ownership, once the double-pass
itself is confirmed hardware-inherent (fixing it would mean touching
`COPYIN_ENTRY`/`COPYOUT_ENTRY` in `entry2.s`, outside this task's owned
files): chunk size only taxes the FIXED per-`$C073`-selection-window setup
(`php`/`sei`/`BANKSEL` write/address setup/`plp`, paid twice per chunk for
a bank<->bank copy), not the per-byte core loop. `K_BOUNCEBUF` is already
256 bytes; `BC_CHUNK` was 128 ("chosen for the VBL-latency bound, not
[the] ceilings", the file's own comment). Raised to **254**, not 256 or
255: `K_CPY_LEN` is ONE zero-page byte (`inc/entry.frame.equ`), and 0
there means "empty" per `CPILC_SRC`/`CPOLC_SRC`'s `ldx K_CPY_LEN / beq
:emptyok` -- 256 silently wraps to 0 and would skip the copy outright.
255 clears that trap but hits a second one: `BC_LOOP`'s own partial-chunk
test is `cmp #BC_CHUNK+1`, and `255+1=256` is itself not a valid 8-bit
immediate, wrapping the SAME way and turning "remaining < 256" into
"remaining < 0" (never true) -- every non-exact-multiple tail chunk would
wrongly take the full-chunk branch and overrun by up to `BC_CHUNK-1`
bytes. **254 keeps `#BC_CHUNK+1` = 255, a valid immediate, and needs no
change to `BC_LOOP`'s existing compare logic at all** -- one byte short of
the true ceiling, for zero risk.

**Interrupt-latency check** (the other candidate the task raised): the
`php`/`sei` ... `plp` bracket spans exactly ONE window, not the whole
chunk or the whole call -- IRQs are re-enabled between window 1 and
window 2, and between chunks. Worst-case masked span per window grows
from ~128 to ~254 bytes, roughly 2.3ms -> 4.5ms @1MHz (18 cyc/byte core
loop x bytes), still well under the 60Hz (16.7ms) AppleMouse VBL period
this kernel's scheduling depends on. Verified functionally, not just by
arithmetic: `check-bankcopy`'s 2x2x2 softswitch matrix (all 8 combos) and
`check-sticky` (staleness teeth included) both PASS unchanged after the
change -- see Verification below.

### Measured before/after

Two real `BankCopy`-entry-to-`BC_RESTORE` measurements, at the two chunk
sizes, on the SAME rig:

| BC_CHUNK | image | measured cyc | cyc/byte |
|---:|---:|---:|---:|
| 128 (before) | 7746B | 302,647 | 39.07 |
| 254 (after) | 8592B* | 330,280 | 38.44 |

\* `ls.bin` grew from 7746 to 8592 bytes BETWEEN these two runs -- a
concurrent, unrelated team's liba/buffered-stdio work landed on the
shared tree mid-task (see Deviations). The two data points still solve
cleanly for `BankCopy`'s real cost model (`cycles = core*bytes +
overhead*windows`, `windows = 2*ceil(bytes/BC_CHUNK)`, both measurements'
non-`BankCopy` phases -- `PRC_STMP_BANK`, `PSTG_ARGV`, etc. -- landed
identical between runs, confirming the two runs are otherwise apples-to-
apples): **core = 37.80 cyc/byte (both windows), fixed overhead = ~80
cycles/window** -- smaller than this task's initial hand estimate (~195
cyc/window), which is WHY the real win is modest rather than the ~3-4%
first guessed. Applying that solved model to the SAME 7746-byte image at
both chunk sizes: **297,865 cyc at BC_CHUNK=254 vs. 302,647 at
BC_CHUNK=128 -- a 1.6% reduction in `BankCopy`'s own time**, ~1.2% off
the full warm `PRC_SPAWN`->`ls`-`OPEN` window (402,773 -> ~397,991
projected). Real, safe, fully explained -- and honestly small next to the
75% `BankCopy` itself represents, because the true dominant cost (the
double-pass) is structural and out of this task's reach.

### Cold spawn: K1 confirmed landed, what remains

`PMLI_XFR_SIZE equ $200` (512) and `PRC_CHUNK ds 2` are live in
`src/kernel/process.s` today (grepped, not assumed) -- K1 (sec 9) is in
effect on the exact path this task measured; `PRC_LD_FL_IMG` reads
`ls.bin` in 512-byte MLI chunks, not 128. sec 11's cold total (748,444 cyc)
is disk-transfer-dominated, not staging-size-dominated: sec 3's own
directory-READ measurement (post-K1) already showed 70-76 cyc/byte
INCLUDING real MLI/SmartPort disk transfer, an order of magnitude above
`BankCopy`'s in-memory-only rate -- consistent with this task's read of
the cold path (one 512-byte chunk's MLI READ cost ~9-37K cyc against its
paired `BankCopy` calls' ~1.6-10K cyc, an order of magnitude apart every
time it was sampled). `BC_CHUNK`'s fixed-overhead saving applies here too
(every 512-byte cold chunk is copied TWICE -- child bank AND, piggybacked,
the cache bank, both `BC_KIND_MAIN`->`BC_KIND_BANK`, i.e. SINGLE-window
copies, so `BC_CHUNK` only removes overhead paid ONCE per chunk here, not
twice) but is smaller still against a disk-bound total. **What remains is
the disk transfer itself** -- not addressable from `procspawn.s`/
`sticky.s`/`bankcopy.s` alone; a real win here would mean either a faster
underlying block-device model (outside this task's scope entirely, it's
the emulator's/hardware's own disk timing) or avoiding the read
altogether, which is exactly what a warm sticky hit already does.

### Considered and rejected: hand off the cache bank instead of copying it

If a warm hit could give the freshly-allocated child process THE CACHE
BANK ITSELF (skip `BankCopy` completely, since $C073 selection is a
per-process property already) rather than copying bytes out of it, the
dominant 75% would vanish. Rejected without prototyping: STICKY.md
section 2's whole design packs MULTIPLE images per cache bank by bump
pointer ("one bank holds the lot" -- the twelve small utilities fit in
21234B of one bank). Handing that bank to one live process would strand
every OTHER cached program sharing it, defeating the cache for all of
them on every hit -- a correctness-shaped regression this task's
"behaviour must not change" constraint rules out, and a real fix would
need a one-image-per-bank redesign, well outside a performance task's
scope. Flagged for whoever next revisits STICKY.md's design, not
attempted.

### Verification

`check-bankcopy` (8/8 softswitch combos), `check-sticky` (cold<warm/2
teeth AND the staleness/rewrite teeth, both still PASS), `check-process`,
`check-fileprocess` all re-run against the `BC_CHUNK=254` kernel -- see
this task's final report for verbatim output. `check-play`/`check-process`
failures observed during this task were isolated (bankcopy.s reverted,
same failure reproduced) to a DIFFERENT, concurrent team's in-flight
`tty.s`/`liba` edits on the shared tree, not this change -- see
Deviations.

## 13. 2026-08-20 results (task: build buffered output streams for liba, sec 4)

**Delivered**: `src/liba/stdio.s` (new module), `PUTC`/`PUTS`/`GETC`
rewired in `src/liba/print.s`, every `src/bin/*.s` `SC_EXIT` call site
routed through a new `EXIT`, and a new gate (`make check-bufio`)
covering sec 6 gates (c) and (d). sec 6 gates (a) and (b) are NOT new gates
here -- see "Gate outcomes" below for why reusing existing gates is the
correct proof, not a shortcut.

### Design as built

`PUTC`'s interface is byte-for-byte unchanged (`jsr PUTC`, A=byte,
X=fd) -- its body is now `jmp SIO_PUTC` (a tail call, so `SIO_PUTC`'s
own `rts` returns straight to `PUTC`'s caller). `SIO_PUTC` appends the
byte to a per-fd buffer in LC bank 1 (see below), then checks ONE
policy trigger -- **PER-FD and PROBED since 2026-08-28**
(docs/PERF-PLAN.md step 4): `SIO_MODEOF` asks the kernel what the fd
IS via `SYS_FDSTAT` (the isatty-equivalent call "The isatty decision"
below said to revisit for -- it landed for sh's interactive probe). A
DEVICE/tty flushes on `$8D` (CR, line buffering); a FILE or PIPE
flushes at exactly 512 bytes (`BUFSIZ`, one ProDOS block, matching
K1's `PMLI_XFR_SIZE`); fd 2 is pinned to line mode unconditionally
(POSIX's stderr rule, and what keeps `2>&1` merge order
deterministic). The probe result is cached in `SIO_MODE`
(kernel-zeroed page) and invalidated by `FCLOSE`; a failed probe
falls back to line mode -- conservative, but NOTE the failure mode
this masks: a harness kernel missing the syscall behaves exactly like
the old policy, silently (the e2e dispatch-table find,
learning:01M146SY2MHWZN4P05D2V4GRFB).

`PUTS` issues its single, unbuffered `SC_WRITE` only for LINE-mode
fds (flushing the fd's pending `PUTC`-buffered bytes FIRST, or output
would reorder). On a FULL-mode fd it routes through `SIO_PUTSB`
instead -- a bulk append into the fd's LC buffer, one bank bracket per
256-byte chunk -- so a 40-character output line costs a buffer copy,
not an MLI WRITE (and ordering holds by construction: everything goes
through the one buffer). `GETC` flushes EVERY buffered stream before
its blocking `SC_READ` -- this is the entire mechanism behind gate (b):
a prompt like `"$ "` has no trailing CR, so line buffering alone would
never flush it, and `sh`'s `READLINE` calls `GETC` right after printing
the prompt.

**`EXIT`** (`src/liba/stdio.s`) is the new documented door: flushes
every open stream (`SIO_FLUSHALL`, fd 0-7) then calls `SC_EXIT` (the
raw door, `syscalls.s`, byte-for-byte unchanged). `sh`'s own builtin
`EXIT` command (`CHCK_BLTN_EXT`) was also routed through liba's `EXIT`,
not just the ordinary top-of-`main` exits -- a shell that quits via its
own builtin needs its flush too, and the first draft missed this until
grepped for specifically.

**Register contract bug found and fixed mid-task, worth recording
because it is exactly the kind of thing "PUTC's interface does not
change" is supposed to prevent**: the OLD `PUTC` never touched Y at
all. A first draft of `SIO_PUTC` set `Y=0` for its own indexed store
and never restored the caller's Y -- silently breaking any caller using
Y as its own loop index across `jsr PUTC` (exactly what
`src/test/bufwriter.s`, this task's own gate-(c) fixture, does). It
manifested as an infinite loop (Y perpetually reset to 1 by
`iny`-after-`PUTC`) that `scripts/check_bufio.py`'s bounded step budget
caught as a hang, traced via `until_pc`/`step_inst`/`regs` down to the
exact instruction. Fixed by wrapping `SIO_PUTC` in `phy`/`ply` and
doing the same for `GETC`'s new `jsr SIO_FLUSHALL` (the old `GETC` also
never touched Y). Both are now correct AND documented in-line so the
next person doesn't have to re-derive it from a hang.

### The LC-bank-1 decision (sec 5) -- taken, then corrected

Implemented `sec 5` as specified: the buffer lives in the process's own
LC bank 1 -- the escape hatch offered ("place the buffer in ordinary
RAM instead") was not needed. Two things had to be resolved that sec 5
did not spell out:

1. **copyin/copyout refuses `$D000+` outright** (`K_CPY_ERR=2`,
   verified by reading `src/kernel/entry2.s`'s `CPILC_SRC`/`CPOLC_SRC`,
   not guessed) -- so a syscall's `data_buffer` field can never point
   into LC bank 1. Flush therefore copies the pending bytes into ONE
   shared 512-byte ordinary-RAM staging buffer (`SIO_STAGE`, plain
   same-process `(zp),Y` addressing -- no kernel involvement, LC bank 1
   once selected IS this process's own address space) BEFORE issuing
   the real `SC_WRITE`. Cost: 512B of ordinary process RAM beyond the
   "free" 4096B in LC bank 1 -- still a large net win over 8 separate
   512B ordinary-RAM buffers the naive alternative would cost, since
   flush is sequential (never concurrent across fds), so one shared
   stage buffer suffices.
2. **A real bank-1/bank-2 mixup, caught by gate (d) itself.** A first
   draft used $C08B (double-read) for "the process's own free bank"
   and $C080 for "restore before syscalls," on the generic Sather-table
   naming. Both are WRONG relative to this project's own,
   repeatedly-proven convention: `inc/mm.hw.equ`'s
   `LCBANK2_RAM` ($C08B, comment: "STEADY STATE") is where
   `src/kernel/entry.s`'s `INSTALL_COPY`, `src/kernel/mli.s`'s
   `INSTALL_IRQ`, `src/kernel/timer.s`, and `src/kernel/procspawn.s`
   ALL write-enable to patch/use ProDOS's OWN resident code -- `mli.s`'s
   own words: ProDOS "keeps executing FROM this same LC bank." `src/
   bin/as.s` already documents why the confusion is easy: "the two
   codebases' bank-1/bank-2 NAMES are swapped relative to each other (a
   real, documented Apple II LC naming inversion), but the ADDRESS
   matches" (Merlin's own `ASM_ENTRY` calls $C08B "BANK1"; this
   project's own `mm.hw.equ` calls the SAME ADDRESS "LCBANK2").
   **What surfaced it**: gate (d)'s violator (deliberately select-and-
   don't-restore, then a real MLI call) completed CLEANLY on the first
   (wrong) address pair -- which should have been impossible if $C08B
   were genuinely free. That "too clean" result was the tell. Fixed to
   `LC_FREE_RW=$C083`/`LC_KRN_RO=$C088` (`mm.hw.equ`'s
   `LCBANK1_RAM`/`LCBANK2_STORE`), declared locally in `stdio.s` rather
   than `put`ting `mm.hw.equ` (avoids a new put-list edit across
   every `src/bin/*.s` consumer; the tradeoff is two independent
   spellings of the same four addresses now existing in the tree -- a
   drift risk flagged for whoever next touches either).

**The bracket stays narrow on purpose**: bank 1 is selected only for
the single indexed store (`SIO_PUTC`) or the copy loop (`SIO_CPY`
inside `SIO_FLUSH`), and bank 2 is restored immediately after, in the
SAME leaf routine, with no syscall ever issued in between -- see gate
(d) below for whether this is provably load-bearing on this rig.

### The isatty decision

**Superseded 2026-08-28: `SYS_FDSTAT` exists now (built for sh's
interactive probe) and the buffering policy is probed per fd -- see sec 4
above and docs/PERF-PLAN.md step 4. The paragraph below is the
original decision, kept for the record; its "revisit" clause is what
was exercised.**

No isatty-equivalent syscall was built. sec 4 invites "expose it cheaply,"
but wiring a new syscall touches `entry.s`'s shared `K_DISP` table and
`procfd.s` -- the load-bearing shared dispatch surface concurrent teams
were also editing this round (confirmed: `git status` shows `src/
kernel/tty.s`/`tty2.s` under concurrent modification throughout this
task), and outside this task's owned-file list (`src/liba/*`,
`src/bin/*.s`, `docs/PROCIO.md`, gate files only). Classified by FD
NUMBER instead: 0-2 line-buffered, 3+ full-buffered (never wrong,
`SC_OPEN`'s own fd range is always 3+ in this codebase today). Cost: a
program that redirects fd 1/2 to a file (`ls >out`) gets line- instead
of full-buffering on that stream -- fewer syscalls saved than the ideal,
never a correctness loss (line buffering is *conservative*, flushing
MORE often than a real isatty-driven policy would, never less; flush-
on-exit lands every byte regardless). Revisit if/when an isatty
syscall lands.

### exit()/SC_EXIT audit

All 49 `jsr SC_EXIT` call sites across all 15 `src/bin/*.s` files that
call it (`cat cp as grep ld ls mkdir mv ps pwd rm sh wc echo ed`) now
read `jsr EXIT` -- a project-wide `sed` pass, verified by grep (0
remaining `jsr SC_EXIT` sites; the 2 leftover textual matches are
comments, updated separately for accuracy). `src/bin/asrom.s` was
audited and needs no change (a raw ROM-stub source, no `SC_EXIT` call,
no liba link at all). Every one of the 15 files already `put`s
`../liba/print.s`, so all 15 needed (and got) a new
`put ../liba/stdio.s` line alongside it -- **not** `put` from inside
`print.s` itself, because neither merlin32 nor real Merlin nests `PUT`
(`docs/TOOLCHAIN.md`, commit `004bd02`: "INCLUDES ARE A TOP-LEVEL
CONCERN") -- a first draft tried exactly that and merlin32 silently
no-oped it, leaving `SIO_PUTC`/`EXIT` undefined until the first
`jsr EXIT` failed to assemble.

### Gate outcomes (sec 6)

- **(a) byte-identical output with/without buffering.** NOT a new
  gate: `check-ls`, `check-catread`, `check-sh`, and `check-v1-system`
  already assert byte-exact output produced through the now-buffered
  `PUTC`/`PUTS`/`GETC`, and all four still PASS unmodified (see
  Verification below) -- before=old unbuffered code passing these
  fixed byte-exact assertions, after=new buffered code passing the
  SAME assertions, unchanged. `check-ls` in particular exercises `ls`'s
  own character-by-character `PUTC` loop (the exact bottleneck this
  task targets) and is the strongest available proof.
- **(b) a line-buffered prompt appears before the read that follows
  it.** NOT a new gate: `check-play` already asserts `sh`'s `"$ "`
  prompt is visible on screen via `screen_text` polling BEFORE any
  keystroke is sent (a real proof of this exact property -- the old
  unbuffered `PUTC` made it trivially true; the new buffered `PUTC`
  needs `GETC`'s `SIO_FLUSHALL` call to keep it true). Still PASSES.
- **(c) exit flushes.** NEW gate (`make check-bufio`,
  `src/test/bufiotest.s`/`bufiotestb.s`/`bufwriter.s`,
  `scripts/build_bufio_image.py`/`check_bufio.py`): a REAL liba-linked
  program (`bufwriter.s`, not a raw kernel harness) writes 5 bytes via
  `PUTC` to a real, freshly-`SC_OPEN`ed file -- no CR in the payload, well
  under `BUFSIZ`, so NEITHER buffering trigger ever fires -- then calls
  plain `EXIT(0)` with no explicit flush anywhere in the file. The
  parent re-opens the file after the child exits and asserts the bytes
  landed byte-exact. **PASSES.** Teeth proven: commenting out `EXIT`'s
  `jsr SIO_FLUSHALL`, rebuilding, and re-running reproduces the exact
  expected failure (`trans_count expected 5, got 0`,
  `bytes mismatch ... got=b'\x00\x00\x00\x00\x00'`) -- watched failing,
  then reverted.
- **(d) a program entering a syscall with bank 1 selected is caught
  loudly.** NEW gate, same harness: the parent selects `LC_FREE_RW`
  and, WITHOUT restoring `LC_KRN_RO`, issues a real MLI call (tried
  both `SYS_GETPFX` and a real `SYS_OPEN` of the already-created file)
  that must dispatch through ProDOS's own $D000-resident code. **Does
  NOT pass**: the violator completes cleanly every time, on both
  address pairs (the buggy one above, and the corrected one). A
  same-run diagnostic (not kept in the tree -- see git history for this
  task) snapshotting $D000-$D007 in MAIN memory under each bank, taken
  BEFORE any process runs, showed IDENTICAL bytes for both banks at
  that narrow offset -- inconclusive on its own. Leading hypothesis,
  not verified further given time spent: ProDOS's own real MLI call
  path likely re-selects the bank it needs internally as part of
  normal block-driver dispatch (the same write-enable/restore idiom
  `mli.s`'s `INSTALL_IRQ` uses), making it defensively robust to an
  incoming process's ambient bank-select state -- which would mean the
  invariant is real and worth keeping (defense in depth, matching this
  project's own stated reason for the bracket: "the same shape as
  three bugs this project has already paid for") but not observable
  through ProDOS's own call surface with the two operations tried.
  Reported as a gate FAILURE, not silently passed, per sec 6's own
  reasoning: a violator that succeeds silently means the hazard is not
  demonstrated on this rig, which is itself the finding worth
  surfacing. **Open risk for whoever picks this up next**: sweep more
  of $D000-$DFFF for genuine divergence between the two MAIN-memory
  banks, or find an MLI operation that does NOT do its own defensive
  LC housekeeping.

### Measured before/after (`ls` output phase, sec 11's own method, same rig)

`build/play.po`, verilogapple fast backend, `"ls\r"` typed at the live
`$ ` prompt via the `type` MCP tool, `until_pc` bracketing the same
phase boundaries sec 11 used (`build/MAUXPLAY.SYSTEM_Output.txt`'s symbol
table, regenerated fresh this task). `scripts/profile_ls_echo.py`,
unmodified.

| phase | before (sec 11, cold) | after (this task) | change |
|---|---:|---:|---:|
| keypress->SPAWN | 107,729 | 112,832 | ~flat (sh's own overhead, untouched) |
| SPAWN->OPEN (spawn/load) | 748,444 | 815,821 | +9% -- see caveat below |
| OPEN->first write (dir read) | 226,916 | 227,931 | ~flat (unrelated to buffering) |
| **first write->EXIT (output phase)** | **286,682** | **139,187** | **2.06x faster** |
| **total** | **1,369,771** | **1,295,771** | **1.06x faster** |

**`SC_WRITE` count for the SAME 67-byte, 15-line listing: 67 -> 15 (a
4.47x reduction)** -- exactly one flush per line, matching line
buffering's design (fd 1 is line-buffered) and matching sec 11 sec 5's own
"4.47 avg bytes/line" figure almost exactly, since that is where the
number came from. Full syscall tally this run: `{SPAWN:1, WAIT:1,
GETPFX:1, OPEN:1, READ:2, CLOSE:1, WRITE:15, EXIT:1}` = 23 total vs.
sec 11's 73 (`ls`'s own count, a different span) + `sh`'s SPAWN/WAIT.

**Caveat, stated plainly**: this is NOT a fully controlled A/B -- the
shared tree had OTHER teams' concurrent kernel changes land during
this task (sec 12's spawn/`BankCopy` work among them, confirmed by
`docs/PROCIO.md` itself growing a new section mid-task), which plausibly
explains the SPAWN->OPEN phase moving +9% in a direction this task never
touched. The output-phase number (this task's actual target) and the
`SC_WRITE` count are the numbers this task can defend; the total and
the spawn phase carry that confound and are reported for completeness,
not as this task's own result. Matches sec 11's own verdict too: even the
full 2.06x output-phase win does not touch spawn/load, still the
dominant cost of a cold `ls`.

### Verification -- verbatim output

`make check-userland check-catread check-sh check-v1-system check-play
check-ls check-ed check-modules`: all 8 PASS (individually invoked,
full output captured; not re-typed here -- see this task's final report
for the verbatim transcript). `check-modules` required two mechanical
fixes this task's own new files needed: `scripts/rewrap_comments.py`
--apply (mechanical, comments-only, cannot change object code) plus a
manual prose-paragraph reflow for the blocks it correctly declines to
touch, and one 14-character label (`SIO_WPARM_TRNS` -> `SIO_WPRM_TRNS`,
13 chars) real Merlin would have rejected outright.

`make check-all` (29 targets): 26 PASS, 3 FAIL --
`check-bufio` (gate (d), reported above, not silently passed),
`check-as`, `check-ld`. The latter two are OUTSIDE this task's changed-
file footprint entirely (Merlin-core rebuild/divergence-audit
machinery this task never touches) and reproduced with a DIFFERENT
concrete error each time re-run (`mcp_supervisor closed stdout
unexpectedly, exit -9` from one run's log -- traced to a DIFFERENT
concurrent team's isolated worktree at `/private/tmp/maux-isotest`
clobbering the SAME shared `/tmp/maux-check-as.log` filename this
task's own run also writes; `FileNotFoundError:
/SOURCE/ASMOBJ/AS` from a clean re-run in this task's own tree) --
consistent with multi-team resource contention (several teams' own
`mcp_supervisor` processes competing on one machine) rather than a
regression, and both `as.s`/`ld.s` were independently confirmed to
assemble cleanly, standalone, with this task's changes, early in this
task before any gate was touched. Not chased further -- outside
ownership scope, and check-as/check-ld are not this task's own gates.

`make check-mame`: see this task's final report for verbatim phase
output.

## 14. 2026-08-20 results (task: attack the tty output path -- scroll and bulk TTY_WRITE)

sec 11 named two costs it did not size: screen scrolling (673,323 cyc
measured once, warm, conflated with extra output) and the fact
`TTY_WRITE` pays a cross-bank fetch PER BYTE regardless of request
size. This task attacked both, in `src/kernel/tty.s`/`tty2.s` only.

**1. Scrolling.** `TTY_SCROLL` already dispatched to `UT_SCROLL` (one
CRTC register write) when `UT_PRESENT` -- that half of docs/CONSOLE.md
10a's design was already shipped and untouched here. The cost lives
entirely in `TTY_SCROLL40`, the //e 40-column fallback (the rig every
measurement in sec 11 actually used): a row-by-row `(zp),y` byte copy, 22
rows x 40 bytes, PLUS a redundant address lookup -- `TTY_ROW_SRC_A(N)`
for row N and `TTY_ROW_DST_A(N-1)` for row N-1 compute the SAME
address twice across consecutive iterations, once as this row's SRC
and once as the next row's DST. The 6502 has no block-move
instruction, so the byte copy itself has a hard floor; the two things
worth attacking are the redundant lookup and the per-byte loop-test
overhead (`INY`/`CPY`/`BNE` every byte).

Changed: cache the SRC pointer into the DST pointer after each row's
copy instead of a second `TTY_ROW_DST_A` call (one `TTY_ROW_xxx_A` per
row instead of two -- and it leaves the pointer already correct for
the trailing clear, removing that lookup too); unroll the inner copy
4-wide, trading per-byte `CPY`/`BNE` for one test per 4 bytes. Kept
deliberately modest (not a full 40-wide unroll) because of the size
crisis in section 2 below -- a bigger unroll would have blown the
budget outright.

**Measured, real cycles, not analytical.** Direct `until_pc` bracketing
of `TTY_SCROLL`'s own entry-to-return address was tried first and
abandoned: the return address (the caller's next instruction after
`jsr TTY_SCROLL`, reached via `RTS`) never registered a hit even at a
4,000,000-cycle budget, though the routine visibly completed and
control reached the idle loop afterward -- a new tool gotcha, distinct
from the documented same-target-twice bug (these are two DIFFERENT
addresses), not chased into the emulator's own source. Worked instead:
bracket `TTY_SCROLL`'s entry to the FOLLOWING `TTY_WR_CELL` entry (the
very next character write, reached via `JSR` like every other bracket
in this document that has proven reliable) -- same `ls`, `ls` warm
scenario as sec 1, verilogapple fast backend:

| | cycles |
|---|---:|
| BEFORE (`TTY_SCROLL` entry -> next `TTY_WR_CELL`) | 18,199 |
| AFTER | 14,590 |
| reduction | 3,609 cyc (19.8%) |

The BEFORE number reproduced bit-identical across repeated fresh runs
(fully deterministic, as expected -- no randomness in the scenario).
The AFTER number's own repeat runs were inconsistent under this
task's measurement load (several concurrent teams' `mcp_supervisor`
processes contending for the same machine, per sec 12/sec 13's own account
of the identical symptom) -- one clean run succeeded, several
follow-ups timed out waiting for the next `TTY_WR_CELL` even at a
4,000,000-cycle budget. `check-play`'s own "row 0 status line survives
scrolling" assertion, which exercises this exact code path with a real
functional check rather than a cycle count, passed repeatedly and
reliably against the same code (see gate status below) -- so this is
read as measurement-harness timing sensitivity under load, not a
functional regression, but it means the AFTER figure above rests on
one clean run rather than several agreeing ones. Flagged, not hidden.

**2. Bulk TTY_WRITE.** `TTY_WRITE` fetched its payload one byte at a
time via `PRDPAR_BYTE` (a full cross-bank `COPYIN_ENTRY` call per
byte) regardless of how many bytes the caller requested. Changed: for
requests of 2+ bytes, one `BankCopy` pulls up to `TTY_OWBUF_SZ`
(96) bytes at a time into `TTY_OUTBUF`, a new kernel-side staging
buffer in main memory; the VT/escape parser (`TTY_SHDW_TAP`/
`TTY_PUT_BYTE` and everything they call) then runs entirely over that
local buffer. Requests over 96 bytes loop the chunk (mirrors K1's own
`PMLI_XFR_SIZE` chunking for file reads, sec 3) -- P_COUNT's 8-bit width
still caps a single syscall at 255 bytes total, unchanged from before
this task. Parser state (`TTY_ESC_STATE`/`TTY_CSI_ROW`/`TTY_CSI_COL`/
`TTY_CSI_PARAM`) lives in the same fixed cells it always did, untouched
by this change, so an escape sequence split across two `write()` calls
-- or across a chunk boundary inside ONE call -- still resumes exactly
as before.

**A real regression found and fixed before this shipped.** The first
version of this change used ONE BankCopy unconditionally, including
for the (still dominant per sec 11 sec 4, ~92% of a program's own
syscalls) 1-byte `PUTC` case. `BankCopy`'s fixed per-call overhead
(80STORE save/restore, chunk-loop setup, the two-window branch) turned
out to be LARGER than `PRDPAR_BYTE`'s direct single-byte fetch --
measured by `check-play` breaking, not guessed: its "^L redraws the
prompt" assertion (docs/CONSOLE.md section 4) failed because `sh`'s
own prompt-print (two 1-byte `PUTC` calls) got slower under the new
code, which shifted the long-standing race between process-driven
prompt output and tick-driven keyboard echo far enough that a
partially-typed `LS` landed on screen BEFORE the `$ ` prompt instead
of after (`row17: 'LS$'` instead of `'$ LS'`) -- reproduced deterministically
in a clean worktree isolated from other teams' concurrent uncommitted
work (necessary: this repo had four other teams' WIP in the live tree
at the time, and the first two reproductions were confounded by it).
Fixed by special-casing count=1 to skip `BankCopy` entirely and keep
the direct `PRDPAR_BYTE` fetch -- the bulk path now only engages at 2+
bytes, where the amortized win is real. `check-play`'s full sequence
(erase-across-wrap, `^U` kill, `LS` through a child, `^L` prompt+edit-
buffer redraw, `^C` killing a foreground `cat`) passed cleanly and
repeatedly after the fix, in isolation from concurrent work.

**Functional correctness, verified byte-exact across a chunk
boundary.** No existing gate exercises a single `write()` over
96 bytes to the tty (K1-era file/pipe gates cover bulk transfers
elsewhere; tty writes in the corpus are all short strings). Built a
throwaway scenario (not a gate, not checked in): `ed` writes a 4-line,
204-byte file (each line under the 127-byte cooked-input cap, so
typing it doesn't collide with the unrelated `TTY_INBUF` line-length
ceiling), then `cat /BASIC/LONGFILE` streams it to the tty in one
`SC_WRITE` well over `TTY_OWBUF_SZ`. All 4 lines reproduced byte-exact
on screen, including the two-plus-chunk boundary a 204-byte payload
over a 96-byte chunk forces.

**Cycle measurement -- attempted, not obtained cleanly; analytical
projection stands in, per sec 9's own precedent for this exact
situation.** Bracketing `TTY_WRITE` entry to the shared `$FF22`
syscall-return page for a representative 16-byte `echo` call gave
implausible numbers on repeated attempts (55 cycles one run, 366,816
another) that a request-count peek at `PRC_PARM+MLI_REQLO` showed were
not bracketing the intended single 16-byte call at all, most likely
catching an unrelated 1-byte write in flight under the same load
pressure noted above. Not resolved within this task's time budget.
In its place: sec 11 section 5's own projection already computed this
exact scenario ahead of time -- "liba buffers the whole run AND
`TTY_WRITE` gets the same K2/K3-style bulk `BankCopy` treatment ...
projected per-byte rate ~= K2's measured ~100 cyc/B bulk pipe rate".
That is precisely what this task built, using the identical `BankCopy`
primitive K2 already measured on real hardware (sec 10: 92-128 cyc/B for
bulk pipe transfers, same bank-to-main-memory shape as this staging
buffer). The fixed per-call component (1,582 cyc, sec 11 sec 2) is
unchanged by this task -- untouched code (parmlist copy-in/out, fd
resolution). For a 16-byte write: OLD ~= 1,582 + 16x450 = 8,782 cyc
(sec 11 sec 2's own measured per-byte rate for the `PRDPAR_BYTE` path);
NEW ~= 1,582 + 16x(K2's ~100 cyc/B bulk rate + the local parse chain's
own ~130 cyc/B, i.e. no cross-bank fetch) ~= 5,262 cyc -- roughly a
40% reduction at N=16, growing toward sec 11 sec 5's own ~16x figure as N
grows and the fixed cost amortizes further. Labelled analytical, not
measured, exactly as sec 9 labelled its own K1 estimate when a blocker
prevented a live number -- replace with a real measurement once the
tool-contention issue above is chased down.

**The code-size crisis this ran into, and how it was resolved.**
Landing the bulk path (even after the count=1 fast path shrank it)
overflowed `check-dual`'s own `$4000` pad budget in
`src/test/processtestb.s` (`ds $4000-*`, a fixed-size test-image pad
this task does not own and could not touch) by 112 bytes on the first
attempt -- baseline slack was 244 bytes and the new code plus a
255-byte `TTY_OUTBUF` used all of it and then some. Resolved
WITHOUT touching the pad, entirely inside owned files: `TTY_OUTBUF`
shrunk from 255 (matching P_COUNT's own ceiling) to `TTY_OWBUF_SZ`=96
(chosen after checking the corpus's longest observed single string
literal, 28 chars -- 96 covers every real caller with room, and a
chunk loop handles anything longer), and the count=1 fast path was
restructured to share its tail (`TTY_SHDW_TAP`/`TTY_PUT_BYTE`/
`PRC_TRANS` bookkeeping) with the bulk path's own loop instead of
duplicating it. Final slack: 24 bytes on the first working build, then
widened further by shrinking to 96 -- verified via `merlin32 -v1`'s
own listing (`ds $4000-ozunid_NNN`'s resolved value), not inferred
from the padded object's total size, which stays constant at exactly
14336 bytes on ANY successful build regardless of how much slack was
used (the pad absorbs the difference -- a size match between two
successful builds is NOT evidence they used the same slack). **Real
Merlin caught a second bug in the same pass** that merlin32 did not:
`TTY_OWBUF_SIZE` (14 characters) exceeded the 13-character label limit
(learning:01M050C6KW01MPJ2TQTPMTZXN6, cited in check_dual.py's own
header) -- merlin32 accepted it silently, real Merlin-8 rejected it
with "Bad label in line". `check-modules`'s own label-length scanner
(which claims "every symbol in the tree is a legal Merlin-8 label")
did NOT catch this either; worth a look by whoever owns that script
next. Renamed to `TTY_OWBUF_SZ` and both assemblers agree.

**Verification (verbatim, isolated worktrees free of other teams'
concurrent uncommitted work -- necessary throughout this task; see
above).**

```
make check-play check-play80 check-ultraterm check-v1-system \
     check-sh check-ls check-modules check-dual
```
All PASS, repeatedly, across multiple fresh runs.

`make check-all` (30 targets): 27/30 PASS on the cleanest run obtained.
The 3 failures (`check-ascore`, `check-as`, `check-ld`) are the
self-hosting Merlin-core and linker gates -- zero code dependency on
`tty.s`/`tty2.s`/`ultraterm.s` (verified by reading `check_ascore.py`'s
own Make prerequisites) -- and failed with either the same
`mcp_supervisor closed stdout unexpectedly (exit code -9)` signature
seen throughout this task's session (multiple concurrent teams' own
emulator processes contending for one machine) or, per sec 12/sec 13's own
account, cross-contamination between this task's isolated worktree and
another team's shared `/tmp/maux-check-*.log` path. An EARLIER
check-all run additionally failed `check-merlin`/`check-userland`/
`check-sh`/`check-play`/`check-v1-system`/`check-rel`/`check-play80` --
every one of those re-ran clean on retry, and every one of THOSE
targets' own logs showed a trailing `PASS` line when inspected,
consistent with the same shared-log-path contamination rather than a
real failure.

`make check-mame`: all 4 phases PASS, verbatim --
```
[check-mame] PASS: hello image boots, "MAUX ALIVE" on the text page
[check-mame] PASS: play image boots to an interactive shell on the Mockingboard 6522 timer tier
[check-mame] PASS: play image boots to an interactive shell on the AppleMouse VBL tier (real 68705 protocol)
[check-mame] PASS: full ed session typed DURING its own binary load survives -- keystrokes captured, file written, shell reprompts
[check-mame] all green -- maux runs on the second rig, both interrupt sources, responsive under I/O
```
Phase 4 is the type-ahead-under-load gate bc7d3c8 built specifically
because a stale-frame race like the one this task found and fixed
(above) is exactly its own subject matter -- it staying green after
this task's fix is the closest thing to an independent second opinion
on that fix this task has.

**Open risks for the next task.** (1) A clean, repeatable live cycle
measurement for the bulk `TTY_WRITE` path (the analytical projection
above should be replaced once possible); (2) the scroll AFTER number
rests on one clean run, not several agreeing ones -- re-measure once
the tool/load contention eases; (3) the `until_pc`-on-a-return-address
gotcha (scroll entry->return bracketing) is a new, unreported tool
surface issue, distinct from the documented same-target-twice bug --
worth a street-library deposit once a minimal repro is isolated
outside this task's own time budget; (4) `check-modules`'s label-
length scanner missed a real over-13-character label real Merlin
caught -- worth checking why; (5) a full 40-wide unroll of
`TTY_SCROLL40`'s copy loop was considered and rejected purely on size
grounds -- revisit if the `$4000` pad budget is ever widened
(`src/test/processtestb.s`'s own comment already documents this as a
"bump when the kernel grows again" maintenance pattern, task #15's own
precedent) or if a different technique frees enough kernel-wide slack.

## 15. 2026-09-16 results (task: the console write floor, decomposed)

sec 11 sec 2 decomposed a ONE-byte write (2,032 cycles: 1,582 fixed +
450 per byte) and sec 14 shipped the bulk staging path but could not
obtain a clean cycle measurement for it, leaving an analytical
projection in its place ("replace with a real measurement once the
tool-contention issue is chased down" -- sec 14's own open risk 1).
This task replaces it, decomposes a 255-byte write instead of a
1-byte one, and takes the lever the numbers picked.

### 1. Method -- a full cycle trace, not a breakpoint chain

Every earlier pass in this document brackets named hops with
`until_pc`. That attributes only the hops a human thought to name, and
a 255-byte write's cost lives in a per-byte LOOP, not a chain.
`scripts/profile_ttywrite.py` (new) arms verilogapple's
`trace_capture` -- a full per-CPU-cycle bus log, every cycle while
armed -- across each tty `write()` syscall, dumps it, and histograms
every cycle onto the nearest preceding GLOBAL symbol in
`build/MAUXPLAY.SYSTEM_Output.txt`.

The point of the method is that it is EXHAUSTIVE: the buckets sum to
the bracket, and the runs below attribute 99.9-100.0% of it. There is
no unexplained remainder to hide a cost in, which is what made the
`$012B-$0136` entries below findable at all -- nobody would have put
`COPYIN_ENTRY` on a list of hops to bracket, because it is a template
copied to page 1 at boot and has no source file of its own.

Two gotchas for the next user. merlin32's listing DOES dump `:local`
labels (as `_local`) and its own `ozunid_NNN` anchors; bucketing to
the nearest preceding symbol without dropping those gives a table of
`_enc`/`_elp`/`ozunid_168` rather than routines. And an entry count
read as "cycles whose PC equals the entry address" is trustworthy only
where it is corroborated -- `TTY_SHDW_TAP` = 910 against 910 payload
bytes and `UT_ERS_SPAN` = 24 against a 24-row `ESC [ 2 J` are solid,
but `UT_CLR_ROW` = 143 against `UT_ERS_SPAN` = 24 is arithmetically
impossible (it tail-calls it) and is an address that other
instructions' operand bytes also land on.

Workload: `man cut`, then SPACE for page 2 -- a 23-line page, 910
bytes in 5 tty writes, on `build/play.po` under the fast backend.
Bracket is the whole syscall, `$FF00` to `$FF22`. Deterministic: the
BEFORE bracket total reproduced to the cycle across separate boots.

### 2. What a 255-byte write actually costs (UltraTerm, BEFORE)

910 bytes, 5 writes, 254,134 cycles = **279.3 cycles/byte**.

The request sizes are the first result: **255, 255, 255, 132, 13**.
`TTY_WRITE` clamps a request over 255 to `$FF` in the one-byte
`P_COUNT` (sec 14), so liba's 512-byte stdio flush arrives as three
syscalls. That is the shape docs/PERF-PLAN.md step 6 proposed to
widen -- and the table below is why this task did not (sec 4).

| routine | cycles | cyc/B | share | entries | what |
|---|---:|---:|---:|---:|---|
| `TTY_RUN` | 56,711 | 62.3 | 22.3% | 165 | run classify + encode into `UT_ROWBUF` |
| `UT_ERS_SPAN` | 41,450 | 45.5 | 16.3% | 24 | ONE `ESC [ 2 J`, 24 rows x 80 cells |
| `TTY_SHDW_TAP` | 35,521 | 39.0 | 14.0% | **910** | the `^L` replay shadow, once per byte |
| `UT_PUT_SPAN` | 22,240 | 24.4 | 8.8% | 38 | the actual VRAM stores |
| `TTY_JS_COUNT` | 13,723 | 15.1 | 5.4% | 66 | jump-scroll look-ahead |
| `TTY_WRITE` | 10,918 | 12.0 | 4.3% | 5 | chunk loop, `BankCopy` setup, entry/exit |
| `UT_SCR_GO` | 8,884 | 9.8 | 3.5% | 11 | scroll (one CRTC write each) |
| `COPYIN_ENTRY` + `COPYOUT_ENTRY` | ~14,000 | ~15.4 | 5.5% | 18 + 5 | cross-bank payload + parmlist copies |
| `TTY_TICK` + `MAIN_IRQ_SHIM` + `MOUSE_RD_BYTE` | ~8,200 | 9.0 | 3.2% | 43 islands | interrupt service inside the write |
| `TTY_CSI_BYTE` + `TTY_ESC_BYTE` + `TTY_PUT_BYTE` + `TTY_CSI_START` | ~13,600 | 15.0 | 5.4% | 130 | the escape/control parser |
| `UT_ADDR_RC` + `UT_CLAIM` + `UT_SEL_PAGE` | 6,421 | 7.1 | 2.5% | 65/101/- | ring address, `$C800` claim, page nibble |
| everything else | ~22,500 | 24.7 | 8.9% | | |

Read it as three groups.

**The irreducible work is a quarter of the call.** `UT_PUT_SPAN`
(22,240, the 910 cells the page actually paints) plus `UT_ERS_SPAN`
(41,450, the 1,920 cells `more`'s `ESC [ 2 J` actually blanks) is
63,690 cycles, 25%. Both are already span primitives, both already
honour the `UT_EXT` dirty bound, and both run at ~21-24 cycles a
cell, which is close to what a `sta UT_WIN,y` loop with a ring
page-cross check can do.

**The per-byte path is the floor, and it is 4x the work it guards.**
`TTY_RUN`'s encode (62.3 cyc/B) plus `TTY_SHDW_TAP` (39.0 cyc/B) is
101 cycles a byte to move a byte from `TTY_OUTBUF` into `UT_ROWBUF`
and record it, against `UT_PUT_SPAN`'s 24.4 to put it on the card.
Together they are 92,232 cycles, **36% of the whole call**.

**The fixed per-call cost is noise at this size.** `TTY_WRITE` +
both parmlist copies + `TTY_CRSR_HIDE` is roughly 1.6k a call, 8k
over the 5 calls, ~3% -- exactly sec 11 sec 2's 1,582-cycle figure,
unchanged, and now measured to be irrelevant at 255 bytes.

### 3. The same page on native-80 and 40-column (BEFORE)

| backend | bytes | writes | cycles | cyc/byte |
|---|---:|---:|---:|---:|
| UltraTerm | 910 | 5 | 254,134 | 279.3 |
| native-80 (`vidmode 80`) | 910 | 5 | 598,711 | 657.9 |
| 40-column (`vidmode 40`) | 740 | 4 | 312,588 | 422.4 |

The per-byte path costs the SAME on all three -- `TTY_RUN` 62.3 /
62.5 / 82.5 cyc/B and `TTY_SHDW_TAP` 39.0 / 39.1 / 40.9 -- which is
the expected result: both run over `TTY_OUTBUF` in main memory and
neither touches the glass. What differs is scrolling, and the
difference is enormous:

| | UltraTerm | native-80 | 40-column |
|---|---:|---:|---:|
| scroll | `UT_SCR_GO` 8,884 | `N8_SCRL_AUX` 201,750 + `TTY_SCROLL40` 159,866 | `TTY_SCROLL40` 145,201 |
| share of the call | 3.5% | **60.4%** | **46.5%** |
| per scroll (11 each) | ~808 | ~32,900 | ~13,200 |

**On the card a scroll is one CRTC register write; on native-80 it is
~40x the cost of the same scroll on the card, and it dominates
everything else on that backend put together.** The `ESC [ 2 J`
that costs 41,450 on the card does not appear on the text backends
at all (`N8_ERSSPAN` and the 40-column direct row fill are far
cheaper than the card's ring walk) -- so the two families of backend
have their bottleneck in DIFFERENT places, and a single "console is
slow" number describes neither.

This is reported, not fixed: `TTY_SCROLL40` was already attacked once
(sec 14) and a further cut is a different task from this one. It is
named here because it is now measured, and because it is the largest
single number anywhere in this document.

### 4. The lever taken, and the two rejected

**Rejected: widen `P_COUNT` so a 512-byte flush is one syscall**
(docs/PERF-PLAN.md step 6). The table prices it: the fixed per-call
cost is ~1.6k, so collapsing the three 255-byte calls into one saves
~3.2k of 254,134 -- **1.3%** -- for a kernel ABI change to a one-byte
count that every caller and every harness script assumes is `<= 255`.
It also is not free of BEHAVIOUR:
`learning:01M2AQKQ8MX8RP3KT0S4XSKKNM` finding 8 records that the same
bytes scroll differently delivered as one write versus several,
because the jump-scroll look-ahead only sees one chunk. Not worth it
at any price, and the reason is a number rather than a judgement.

**Rejected: batch the plot path harder on the card.** The table
agrees with the standing ruling -- `UT_PUT_SPAN` is 8.8%, already a
span, and the fast backend does not model the `$C800` claim anyway.

**Taken: get the `^L` replay shadow out of the per-byte call.**
`TTY_RUN` did `jsr TTY_SHDW_TAP` once PER BYTE -- 910 entries,
35,521 cycles -- plus the 6 cycles a byte the two encode loops spent
stashing the raw byte in `PRC_BYTE` and reloading it purely to hand
it over. 16% of the call, to maintain an 80-byte buffer.

`TTY_SHDW_SPN` (procfd.s, beside `TTY_RUN`) records the whole run
once, at `:done`. The equivalence is exact rather than approximate,
and the argument is worth keeping because it is what makes the filter
one instruction: the encode loops admit a byte only when
`$20 <= b&$7F <= $7E`, so every byte of a run is in
`[$20,$7E] + [$A0,$FE]`; over that set `TTY_SHDW_TAP`'s accept test
`$A0 <= b < $FF` is exactly "bit 7 set", i.e. one `bpl`. Its other
two guards cannot fire on a run byte either -- `VC_ESC_STATE` is 0
(`TTY_RUN` rejects the batch outright when it is not) and `$8D` folds
to `$0D`, below `$20`, so a CR ends the run before it can be
recorded. The 80-byte cap and the append order are unchanged, and
nothing reads the shadow between bytes, so recording the run at its
end is indistinguishable from recording it byte by byte.
`TTY_SHDW_TAP` itself is untouched and still serves the per-byte and
1-byte paths.

Dropping `PRC_BYTE` let both encode loops shed a store and a reload;
the text-page loop's `lda PRC_BYTE / ora #$80` became a bare
`ora #$80`, since `(b&$7F)|$80 == b|$80`.

### 5. Measured after, same brackets, same workload

| backend | before | after | cyc/byte | delta |
|---|---:|---:|---:|---:|
| UltraTerm | 254,134 | 226,475 | 279.3 -> 248.9 | **-10.9%** |
| native-80 | 598,711 | 573,191 | 657.9 -> 629.9 | -4.3% |
| 40-column | 312,588 | 290,831 | 422.4 -> 393.0 | -7.0% |

The absolute saving is 27,659 / 25,520 / 21,757 cycles -- near-constant
across backends, as a change to a main-memory bookkeeping loop should
be. The percentages differ only because native-80's denominator is
2.3x the card's, for the scrolling reason in sec 3.

On the card, `TTY_SHDW_TAP` 35,521 -> 1,981 (only the per-byte path's
control bytes reach it now) and `TTY_RUN` 56,711 -> 44,323, against
21,832 in the new span form: 92,232 -> 68,136.

Cost: **14 bytes** in every kernel image (`MAUXEXPR.SYSTEM` 30,877 ->
30,891; the pin in `scripts/check_kernel_images.py` raised 157 -> 171
with this reason). The new routine weighs 34 bytes and gave 20 back
from the two encode loops. ~1,976 cycles returned per byte spent,
which is the first entry in that pin table bought with a number.

### 6. Gate and its teeth

`check-play`'s existing `^L` phase covers this, and was PROVEN to
cover it rather than assumed to: the shell's `$ ` prompt reaches the
glass as a 2-byte printable RUN, so it goes through `TTY_RUN` and the
new span tap, not the per-byte path. Both sabotages went red at
exactly the `^L` assertion and nowhere earlier:

- `TTY_SHDW_SPN` replaced by a bare `rts` (shadow never recorded)
- `bpl :snext` inverted to `bmi` (the filter's polarity, i.e. the
  equivalence argument in sec 4 above)

**Coverage gap, stated rather than papered over.** No gate drives a
run that takes the shadow PAST its 80-byte cap from a process write,
because nothing in the corpus emits a cooked-mode partial line longer
than the prompt -- `sh` has no `PS1`, and every `cat`/`ls` line ends
in a CR that resets the shadow. The cap path is argued safe by
inspection instead, and the argument is short: entry refuses when
`VC_OSHDW_LEN >= 80`, so X starts `<= 79`; the store happens before
`inx`; and the `cpx #80 / bcs` after it exits at X == 80. Every store
is therefore at X in `[0,79]`, and the routine leaves
`VC_OSHDW_LEN` = 80 exactly as the per-byte version did. A fixture
file whose last line is over 80 columns with no trailing newline
would close this properly.

### 7. What the table says to do next, in order

1. **`TTY_SCROLL40`/`N8_SCRL_AUX` on native-80** -- 361,616 cycles,
   60% of that backend's console cost, ~32,900 per scroll against the
   card's ~808. Much the largest number in this document.
2. **`TTY_RUN`'s encode loop, still 48.7 cyc/B after this task** --
   it writes `UT_ROWBUF`, then `UT_PUT_SPAN` copies `UT_ROWBUF` to
   VRAM: two passes over the same bytes. Encoding straight into the
   held `$C800` window would merge them, worth perhaps 20 cyc/B on
   the card, at the cost of the per-ROW window discipline
   (`learning:01M0NZFJMX163HFK2CM64Q9GVA`: never hold a window across
   a whole primitive).
3. **The `^L` shadow could stop existing.** It costs 21,832 cycles
   even in span form, and both 80-column backends can READ their own
   glass (`UT_GET_SPAN`, and native-80's aux half) -- `^L` could
   capture the row before it clears instead of maintaining a running
   copy. That deletes a kernel buffer and a routine rather than
   adding any. Not attempted here: it changes `^L` semantics for a
   redirected console, which has no glass to read.
4. **`TTY_JS_COUNT`, 13,723 cycles (5.4%), 66 calls** -- the
   jump-scroll look-ahead re-scans the chunk. Unexamined.

### 8. The one red this leaves, and why it is not this change's bug

> **RESOLVED 2026-09-16, and the conclusion below was half right.** The
> matrix was sound and its verdict -- "not this change's bug" -- was
> correct. Its LOCATION was wrong: the latent fault is not in the
> lending path, it is in `scripts/check_iobuf.py`'s own release of the
> probe. See sec 15.9. Everything from here to the end of this section
> is kept as written, because the reasoning is the reusable part.

`check-iobuf` goes red on `duplicate` (IB1) with this task's commit:
"the open parked the file it was opening (parks 0->1)". It is green at
the base commit. Deterministic: 4 failures in 4 runs with the change, on
the box and locally. It is reported rather than fixed because the
evidence says the fault is a LAYOUT sensitivity in the lending path,
which a kernel of this size happens to trip, and not a defect in the
shadow change. The chain, each step a run:

| experiment | result |
|---|---|
| base commit | PASS |
| this change | **FAIL** |
| this change + `ds 4` before `TTY_RUN` (pure padding, semantics untouched) | PASS |
| this change + `sta PRC_BYTE` restored in both encode loops | PASS |
| this change + `stz PRC_BYTE` instead (same 2 bytes, same 3 cycles, value destroyed) | PASS |
| this change + ~58 cycles/byte burned back inside `TTY_SHDW_SPN` | FAIL |
| base commit + `ds 14` before `TTY_RUN` | PASS |

Read them together. `stz` passing where the store is absent rules out
the VALUE of `PRC_BYTE` -- nothing downstream reads what the encode loop
left there. Burning back more cycles than the change removed, and still
failing, rules out raw SPEED. And four bytes of dead padding, with every
instruction of the change otherwise identical, flipping the gate green
is the decisive one: **a routine's semantics cannot depend on its own
address.** What moved is where the rest of the kernel sits.

What the gate is actually catching, traced with the gate's own
`IOBUF_TRACE_PARK` (which stops at the write to `K_PARK_CNT` and names
the writer): the park is `PRC_PARK_ONE+119`, it happens 8,388 cycles
into the child's duplicate OPEN with the probe's result array still all
zeroes, and the open ends `$50` with no new OFT entry. Since
`procfile3.s`'s `PRC_OPEN` calls `PRC_FILE_BUSY` BEFORE
`PRC_ALLC_IBF` and returns immediately on a match, a park means
`PRC_FILE_BUSY`'s identity scan did NOT match F0 -- so the allocator
parked the child's own F0 entry, and ProDOS then refused the open
anyway because the PARENT still holds F0 open. That is IB1's original
shape, re-armed. The scan compares `PRC_CANON`/`PRC_CANLEN` against each
slot's saved identity, and both read correct (`'/BASIC/IP/D/F0'`, len
14) when the harness peeks them after the fact -- which is as far as
this task took it.

Not taken further here for a reason worth recording: the fault is a
Heisenbug by the table above, so any instrument added inside the kernel
moves the layout and is liable to mask it. It wants an owner who can
work from outside -- `until_write` on `PRC_CANLEN` and on the slot
store, or a `mem_diff` across the scan -- rather than a printf.

There is precedent for this exact fragility in the tree, and it was met
the same way. `scripts/check_kernel_images.py`'s own pin comment records
an earlier change keeping "the ordinary, unswitched syscall path ...
BYTE-FOR-BYTE what it was before this whole fix -- zero cost on the hot
path, so it cannot perturb the nesting window that broke check-iobuf."
So `check-iobuf` has broken on a kernel change before, and the fix then
was to avoid perturbing it rather than to find it. A change whose whole
purpose is to make the console hot path smaller and faster cannot take
that route, which is why it surfaces here.

**A `ds 4` pad is NOT shipped.** It would be green for the wrong reason
and would move again on the next kernel byte anyone adds -- the shape
HACKING.md calls a stated constraint silently broken. The red stands,
with this table, for the operator to rule on.

Rest of the sweep at this commit: `sh scripts/box_gate.sh` gives 94
PASS / 3 FAIL; `check-proshim` and `check-plasm` both PASS on a serial
re-run and are the documented parallel-lane `play-image` driver race,
leaving `check-iobuf` as the only real one. (That race is FIXED as of
2026-09-16 -- the builder stages and publishes atomically under a lock,
scripts/imglock.py; see TOOLCHAIN.md's box-gating section. A
`play-image Bus error` in a sweep after that date is a new bug, not
this one.)

## 15.9. What it actually was: a torn write over a live CPU

sec 15.8 handed its successor two instructions -- work from OUTSIDE the
machine, and make whatever you find explain the `ds 4` row. Both held.
`trace_capture` was armed across the child's whole test OPEN (every CPU
cycle, ~8,400 rows, zero bytes added to the image) and the answer was in
the FIRST TWO ROWS of the dump, before the kernel was ever entered.

**The mechanism.** The probe parks itself at `READY bra READY` -- two
bytes, `$80 $FE` -- and the gate released it by poking `[$EA,$EA]`
(NOP, NOP) over BOTH. That is a torn write against a running CPU. The
65C02 had already fetched the `$80` opcode when the poke landed, so it
read the NEW second byte as the branch offset: `bra $EA` = `bra -22`,
from `$08EA` to `$08D4`. `$08D4` is the middle of the PRECEDING `op()`
block -- its `ldx #>P7` -- so `lda #<P7` never ran and the syscall went
in with **A still holding `$55`**, the constant from the `lda #$55` that
had set the READY marker three instructions earlier.

The rest is dominoes, each one confirmed in the same trace:

| what | traced value |
|---|---|
| `K_PARMLO/HI` written by `KRN_ENTRY` | `$0955` -- high byte from `ldx #>P7`, low byte the stale `$55` |
| where `$0955` points in the probe | the middle of `N3`, the fixture STRING `/BASIC/IP/D/F3` |
| the "parmlist" `PCPI_CALLPARM` copied from it | `42 41 53 49 43 2F` = the characters `BASIC/` |
| so the pathname pointer | `$5341`, unmapped in the child's bank |
| `PRDPAR_BYTE`'s COPYIN of the length byte | reads `$00` |
| `PRC_PATHBUF[0]` | `$00` -- a ZERO-LENGTH path |

**Why that made the identity scan miss** is sec 15.8's real question,
and the answer is a genuine kernel defect that the garbage syscall
merely reached: `PRC_CANONPATH` tested `PRC_PATHBUF+1` without first
testing `PRC_PATHBUF`, the LENGTH byte. For a zero-length path, byte +1
is the PREVIOUS call's leftover -- here a `/` from the F7 open just
before -- so the routine took its ABSOLUTE arm, copied nothing, and
returned **carry CLEAR with `PRC_CANLEN` = 0**. A zero-length identity
compares unequal to every saved path (`cmp PRC_CANLEN` / `bne :next`),
so `PRC_FILE_BUSY` reported NOT BUSY, `PRC_ALLC_IBF` found the pool
full, and `PRC_PARK_ONE` parked F0 -- exactly the park the gate
reported, at exactly `PRC_PARK_ONE+119`. The `$50` the gate ALSO saw,
and passed on, was luck: ProDOS rejecting the garbage open on its own.

**Why it tracked padding bytes.** Whether the poke lands between the
`bra`'s opcode fetch and its operand fetch is a question about the PHASE
of a 3-cycle spin loop at the moment the harness stops stepping -- and
that phase is set by how many cycles the whole boot took, which every
byte of kernel code moves. So the red really was layout-dependent, and
the `ds 4` row really did prove no routine's semantics depended on its
own address. The suspect list was one entry short: **the HARNESS is part
of the layout too.** A gate that drives a live CPU can itself be the
thing the padding is perturbing.

**The two fixes.**

1. `scripts/check_iobuf.py` `release()` writes the branch OPERAND only,
   one byte, `$00` -- "branch to the next instruction". A single byte
   cannot be half-written, and both fetch orderings are correct: a CPU
   that already read `$FE` loops once more and falls through next pass.
   The opcode is never touched. This is what makes the gate
   layout-INDEPENDENT; it is the fix for the red.
2. `PRC_CANONPATH` gains `lda PRC_PATHBUF / beq :cant` -- 5 bytes,
   MAUXEXPR 171 -> 176. This is the fix for the BUG the red exposed,
   and it stands on its own: a zero-length path is legal to hand the
   kernel (bare `cd` is exactly one, `PRC_SETPFX` branches on it, and
   `PCPY_PATH_G` bounds the length only from above), it has no
   identity, and the routine's own header has always promised carry SET
   for an identity it cannot build. `PRC_ABSPATH` (procfd.s) has
   carried the same two instructions for the same reason since it was
   written; this is the routine that forgot them.

**Teeth.** `check-iobuf` gains a `nullpath` mode (IB6): with F0 parked,
OPEN a zero-length pathname and require `$50` and NO new park. On the
unfixed kernel that open sails past the identity scan. `duplicate` now
also ASSERTS its own trigger instead of assuming it -- `lru_victim()`
replays `PRC_PARK_ONE`'s age rule over the peeked tables to prove F0 is
the entry the allocator would pick, the pool is full, and nothing is
parked yet, and afterwards it checks that the scan actually compared
`/BASIC/IP/D/F0`.

And one more, which is the assertion that actually catches THIS fault --
the canon check does not, as a sabotage run proved. After the torn
release the probe re-runs part of an earlier `op()` with a garbage
parmlist, and then **falls through into TEST and performs the real test
open correctly**: `PRC_CANON` ends up holding `/BASIC/IP/D/F0` and the
result cell holds a perfectly correct `$50`. Only the damage done on the
way is visible. So the gate now snapshots the SETUP result cells (slots
0..7, which no mode's TEST ever writes) before the release and compares
them at DONE. With the torn poke restored it reports, first and
instead of anything else: "the probe re-ran part of its SETUP after
release -- A [...0]->[...4] P [...176]->[...177]", naming the re-run F7
open. That is a general guard on every mode, not a special case for this
bug: any release that drops the CPU anywhere but the first instruction
of TEST invalidates everything measured after it, and now says so.

## Library notes

- `learning:01KW1GTYGVYAPQRGS5P7J66RWD` -- RAMRD governs instruction
  fetch; why kernel-side per-process buffering is rejected in sec 3.
- `learning:01KW1GTYHGXMBZNR6DMQB2F712` -- the 80STORE/bank-copy bracket
  discipline sec 5's invariant follows.
- `learning:01KYYGZ8C3FQFWCF3S0FQ0DJ7B` -- TN #26 aux conventions behind
  MEMMAP sec 3.4's bank-2 default.
- `learning:01KYYJ98T5R0M9K1AW2550M132` -- "bank-to-bank transfers must
  route via main memory": why sec 12's `BankCopy` bank<->bank rate is 2x a
  single-window copy, not the same rate plus a fixed detour.
- `learning:01M0FAW65T4K4ZGWHXGJFPKRWC` -- this task's own deposit: the
  quantitative refinement of the above (~2x, measured on `BankCopy`).
- `learning:01M2KR4SK1HCPV5Q691EJZMTJG` -- sec 15's own deposit: the
  full-cycle-trace decomposition method, the per-backend numbers, and
  the two listing gotchas (merlin32 dumps `_local`/`ozunid_NNN`; an
  entry count needs corroborating).
- `learning:01M2KR62JF41H87SYB6YKZFMQC` -- sec 15.8's own deposit: the
  semantics/size/cycles matrix that separates a latent layout-sensitive
  gate fault from a real regression, and why instrumenting one from
  inside the kernel masks it.
- `learning:01M2AW17E0DSGQ917Y3BF7JA66` -- the run-batch printable path
  sec 15's lever sits inside, and its rule that the batched and
  per-byte paths must classify a printable the SAME way: the reason
  sec 15's `bpl` equivalence is argued from the encode loops' own
  accept set rather than assumed.
- `learning:01M2AQKQ8MX8RP3KT0S4XSKKNM` -- finding 8 (the same bytes
  scroll differently as one write versus several) is half of why
  sec 15 rejected widening `P_COUNT`; the 1.3% is the other half.
- `learning:01M0NZFJMX163HFK2CM64Q9GVA` -- per-ROW aux/card windows,
  never one held across a whole primitive: the constraint on sec 15
  sec 7's next lever (encode straight into the card window).
- `learning:01M0ASR4PKGFNSBVCFTZN61DGX` -- the $C08B double-read
  write-enable idiom sec 13's `stdio.s` uses, and (indirectly) the
  provenance check that led to finding the bank-1/bank-2 naming
  mixup: this learning documents `LCBANK2_RAM`/`$C08B` as ProDOS's
  own resident bank via `mli.s`'s `INSTALL_IRQ`, which is the exact
  fact a first draft of sec 13 got backwards.
