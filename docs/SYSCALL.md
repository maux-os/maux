# maux $FFxx kernel page + JSR $FF00 syscall ABI (task #3)

Status: rulings final for v1, code implemented and mechanically tested
against verilogapple's fast backend. This document is the acceptance
artifact for task #3 as much as `src/kernel/ffpage.s` and
`src/kernel/entry.s` are -- see docs/TASKS.md #3.

**Mid-flight operator ruling (recorded here, not silently absorbed):**
partway through this task the operator ruled that **ProDOS 8 becomes
maux's v1 filesystem layer** -- the V6-flavored fs and the ramdisk are cut
from v1; ProDOS stays resident in main LC + the $BF00 global page (memory
maux wasn't otherwise using), and the kernel delegates file syscalls to
the MLI under a kernel-held lock (MLI is non-reentrant). This resolved
several ABI friction items differently than this document's first draft
had them -- **rulings on items 2/3/4/5-7 below are the POST-ruling
version**; each ruling's text says so explicitly and states what changed.
Task #11 (a separate spike, not this task) proves MLI coexistence and
wires the delegate for real; this task only reserves the dispatch SHAPE
(`PRODOS_DELEGATE` in `src/kernel/entry.s`) and updates the numbering it
implies.

Library handles fetched for this task (HACKING.md's notebook loop): `learning:
01KW1GTYGVYAPQRGS5P7J66RWD` (RAMRD governs instruction fetch in
$0200-$BFFF -- the load-bearing hazard behind every PIC-stub and
copyin/copyout design decision below), `01KYYJ98T5R0M9K1AW2550M132`
(RamWorks bank facts, "every bank has its own $FFFE"), `01KW1GTYGP8MHN9YAE5JTSP62Z`
(Apple II Technical Notes / TRM -- TN #22 no ZP parmlists, and the MLI
call-number table used for the mid-flight ruling, confirmed via two
live artifact searches against the TRM, not from memory), `01KZZ53ZE9QX3W2R3NKC209766`
(verilogapple MCP wire protocol -- extended by `scripts/check_syscall.py`).
Own search sweep (HACKING.md's notebook rules): AppleMouse firmware entry-point
addresses/conventions (found via verilogapple's own `sim/mouse/
tb_mouse_fw.cpp`, a working end-to-end firmware probe -- not a separate
street-library learning, cited as source in the relevant code comments),
Language Card write-enable protocol (confirmed via the ProDOS TRM's own
`BNKBYT1`/`BNKBYT2` listing, "`LDA RAMIN` twice" -- see sec 5).

---

## 1. The trapframe contract (recap, `docs/ARCHITECTURE.md`)

Both doors produce an **identical 6-byte frame** on the process's own
stack, pushed in this order (bottom/earliest to top/latest):

```
[PCH][PCL][P][A][X][Y]
```

- **Syscall door** (`JSR $FF00`): the JSR itself pushes PCH,PCL; the stub
  then does `PHP` (capturing the caller's P, including D, before
  anything else touches flags) `SEI` `CLD`, then `PHA` `TXA PHA` `TYA
  PHA` (A,X,Y).
- **IRQ door** ($FFFE vector, shared with BRK): hardware already pushed
  PCH,PCL,P and set I as part of taking the interrupt (65C02 auto-clears
  D); the stub does only `PHA` `TXA PHA` `TYA PHA`.

Because both produce the same 6-byte, same-order frame, **one `EXIT_TAIL`
serves both** -- `RTI` is valid either way. Immediately after `TSX`
(captures X = the process's SP as of the last push, done while `ALTZP`
is *still* aux), every field is reachable via `base+X` absolute,X
addressing:

| field | address | meaning |
|---|---|---|
| `FRAME_Y` | `$0101,X` | call number (syscall) / stale (IRQ, ignored) |
| `FRAME_X` | `$0102,X` | parms ptr hi (syscall) / stale (IRQ) |
| `FRAME_A` | `$0103,X` | parms ptr lo (syscall, in) -> return value (out) |
| `FRAME_P` | `$0104,X` | caller's P -- carry patched here on exit, nothing else touched |
| `FRAME_PCL/PCH` | `$0105,X` / `$0106,X` | return address |

(Derivation: with push order PCH,PCL,P,A,X,Y and SP pointing one below
the last-pushed byte, Y sits at `$0100+SP+1`, X at `+2`, A at `+3`, P at
`+4`, PCL at `+5`, PCH at `+6` -- same offsets regardless of which door,
because the push order and count are engineered to match exactly.)

---

## 2. ABI rulings (friction items 1-11, 13)

### Item 1 -- argument transport: **RULING: registers** (call# in Y,
parms-pointer in A/X). Ratifies liba's draft.

Cycle-counted against the other two candidates (ARCHITECTURE.md's own
framing), counting only the *marginal* transport cost beyond what the
trapframe save was already going to do:

| candidate | marginal cost | why |
|---|---:|---|
| (i) inline MLI-shape trailer (`.byte call / .word parms` after the JSR) | ~25-35 cycles | kernel must pull PCL/PCH from the frame, compute effective address via a ZP-pointer borrow, indirect-fetch the trailer bytes, then PATCH the frame's PCL/PCH (+3) before RTI -- and this PC-patch requirement means the syscall door can no longer share a trivial RTI tail with the IRQ door without a branch to test "did this frame come with a trailer" |
| (ii) caller pushes call#+parms on the stack | ~18-24 cycles | 3 extra pushes before the JSR (caller side) + 3 matching pulls after it returns (or the door must consume them), PLUS the kernel's own 3-byte read via absolute,X (no ZP borrow, no PC patch -- better than (i), but the pushes/pulls are pure overhead absent in (iii)) |
| (iii) registers | **0 cycles** | A/X/Y are captured by the trapframe's `PHA`/`TXA PHA`/`TYA PHA` **regardless of what's in them** -- loading the call number into Y and the parms pointer into A/X costs the caller nothing beyond what any transport needs (SOMETHING has to load the values), and the kernel reads them via the SAME absolute,X frame access it already needs for A/X/Y anyway |

(iii) wins outright -- free transport, and the ONE-RTI-tail invariant
(both doors, one shared unwind) falls out for free instead of needing a
trailer-vs-no-trailer branch. The inline-MLI shape is **not deleted** --
it retreats to the $BF00 compat overlay's translation layer (opt-in,
paid only by compat processes), exactly as ARCHITECTURE.md already
scoped it.

### Item 2 -- call numbers: **RULING (mid-flight, supersedes the
pre-ruling draft): native call numbers ARE the real ProDOS MLI numbers
for the file-call subset; maux's own process calls (no MLI equivalent)
keep small sequential numbers below the MLI range.**

The MLI table (ProDOS 8 TRM ch. 4, confirmed via two street-library
artifact searches against the TRM -- not from memory):

| call | # | call | # |
|---|---|---|---|
| CREATE | $C0 | WRITE | $CB |
| DESTROY | $C1 | CLOSE | $CC |
| RENAME | $C2 | FLUSH | $CD |
| SET_FILE_INFO | $C3 | SET_MARK | $CE |
| GET_FILE_INFO | $C4 | GET_MARK | $CF |
| ONLINE | $C5 | SET_EOF | $D0 |
| SET_PREFIX | $C6 | GET_EOF | $D1 |
| GET_PREFIX | $C7 | SET_BUF | $D2 |
| OPEN | $C8 | GET_BUF | $D3 |
| NEWLINE | $C9 | QUIT | $65 |
| READ | $CA | | |

maux's v1 file syscalls (`open`/`read`/`write`/`close`/`creat`/`unlink`)
use `$C8`/`$CA`/`$CB`/`$CC`/`$C0`/`$C1` verbatim. `readdir()` is **not** a
separate call number -- it's the standard MLI pattern (TRM ch. 4): open
the directory as a file, then `READ` raw directory blocks with the
SAME `$C8`/`$CA` numbers (see item 7). `QUIT` ($65) exists in the MLI
but isn't part of maux's v1 surface -- there's no "quit back to the OS"
concept in a bank-per-process design where the whole bank *is* the
process; `exit()` tears the bank down instead.

maux's own process calls (`spawn`/`exit`/`wait`/`pipe`/`brk` -- concepts
the MLI has no equivalent for) keep small sequential numbers, 1-8
(`pstat` 6, `clock` 7, `fork` 8 have been added since),
chosen to sit comfortably below `MLI_RANGE_LO` = `$65` (the lowest real
MLI call number that exists at all). `$06-$64` is deliberately left
unassigned -- room to grow the process-call surface without renegotiating
the boundary. `inc/sc.proc.equ` is the machine-checkable table
(split per concern from the call numbers themselves, docs/SELFHOST-
CONVERSION.md phase 1 -- `inc/sc.file.equ` holds the real MLI
file-call numbers).

**Why this ruling and not sequential-everywhere (this task's original
draft):** the ORIGINAL open question (ARCHITECTURE.md: "whether native
call numbers ARE the MLI numbers... decided in task #3") reasoned that
the $BF00 compat overlay could bridge any numbering scheme via a
translation table, so matching MLI numbers natively wasn't strictly
necessary for self-hosting. The ProDOS-delegation ruling changes the
calculus entirely: file calls are no longer maux's own implementation
dispatching to maux's own fs code -- they're **forwarded to the real
MLI**, which only understands its own numbers. Using the MLI's numbers
natively means the $BF00 overlay's file-call path becomes a **near
passthrough** (transport translation only -- register args -> real MLI
inline-trailer shape -- not a call-number translation table at all,
since the numbers already match). This is strictly simpler than
maintaining a translation table both directions, so it's not a "smaller
alternative was available" case -- MLI-native numbering for file calls is
now the *smaller* choice, not the fancier one.

**Dispatch shape** (`src/kernel/entry.s`): `KERNEL_ENTRY` checks
`K_CALLNUM` against `MLI_RANGE_LO`; below it, a 1-based indexed table
lookup (`K_DISPATCH_LO`/`K_DISPATCH_HI`, includer-supplied -- the process
calls); at or above it, `JSR PRODOS_DELEGATE`. `PRODOS_DELEGATE` is a
one-line stub in this task's deliverable -- returns `ERR_PRODOS_UNWIRED`
(a distinct code, never confusable with a real MLI failure) -- task #11
replaces its body with the real MLI call-under-lock, without touching
`KERNEL_ENTRY`'s dispatch logic at all.

**Recorded alternative (rejected):** sequential numbering for
everything, with MLI-range gaps used opportunistically. Simpler to
reason about in isolation, but wrong once file calls forward to a real
MLI that owns its own numbers -- passthrough only works if the numbers
already agree.

### Item 3 -- parameter-block shapes: **RULING (mid-flight, supersedes
the pre-ruling draft): file-call parameter blocks are the ACTUAL MLI
parmlist shapes, verbatim -- so lengths are 2 bytes, not 1.** liba's
255-byte 1-byte-length draft is superseded for file calls (a later
userland round reworks `syscalls.s`'s marshalling to match, not this
task). Process calls (spawn/exit/wait/pipe/brk) keep small,
maux-invented fixed-shape parameter blocks (unaffected by the MLI
ruling, since there's no MLI equivalent to match) -- the register-carried
pointer to that block is still the item-1 transport, unchanged.

**Why 2-byte lengths follow from the MLI ruling, not a separate
re-litigation of the original tradeoff:** the whole point of forwarding
to the real MLI is that maux's kernel does NOT reimplement `READ`/
`WRITE`'s semantics -- it copies the caller-supplied parmlist byte-for-
byte (translating the register-carried pointer into the actual MLI
in-memory parmlist shape) and calls the MLI directly. The MLI's own
`READ`/`WRITE` parmlist has a 2-byte `request_count` field (TRM ch. 4)
-- maux cannot silently truncate that to 8 bits without either lying to
the MLI about what the caller asked for or adding a chunking loop maux's
delegate would have to own. Passing the field through verbatim is
simpler than either, so 2-byte lengths follow automatically once
delegation was ruled -- this is not an independent tradeoff call.

**Recorded alternative (rejected, this task's original lean before the
ruling):** keep liba's 1-byte length choice ("smaller/simpler," matching
the "choose the smaller alternative" default rule) for a native maux fs.
Directly superseded by the ProDOS ruling -- the smaller choice today is
whichever shape the MLI itself already uses, since maux is a passthrough
for these six calls, not an implementor.

### Item 4 -- errno numbering: **RULING (mid-flight, supersedes the
pre-ruling draft): file-call errors are raw MLI error codes, passed
through verbatim; a small maux-specific set covers process-call errors
only, in a range clear of every MLI code.**

MLI error codes (TRM ch. 4) occupy roughly `$01-$05` (system-level: bad
call number, bad parameter count, ...) and `$40-$5A` (file-level:
invalid pathname, file not found, end of file, ...) -- maux does not
re-enumerate that table (ProDOS's own domain, wired for real by task
#11). `inc/errno.krn.equ` (kernel-only codes) and
`inc/errno.spawn.equ` (`ERR_2BIG`, the one code sh.s also needs
directly) define only the process-call codes maux invents, at `$E0+`
-- clear of the entire documented MLI error space (split per concern,
docs/SELFHOST-CONVERSION.md phase 1):

| code | value | meaning |
|---|---|---|
| `ERR_NOMEM` | `$E0` | out of memory / no free banks (spawn image load, brk past a bank's ceiling) |
| `ERR_INVAL` | `$E1` | invalid argument -- bad call number, bad fd range, malformed parms |
| `ERR_NOSYS` | `$E2` | not implemented -- the default for any call number the process-call dispatch table doesn't cover. It was fork()'s code in v1; fork LANDED 2026-08-23 (`SYS_FORK` = 8, `docs/FORK.md`) and now returns `ERR_AGAIN` on bank exhaustion instead. An image whose `K_DISP_COUNT` stops below 8 still answers `ERR_NOSYS` for it |
| `ERR_CHILD` | `$E3` | no child processes -- wait() with none outstanding |
| `ERR_AGAIN` | `$E4` | bank exhaustion on spawn (ARCHITECTURE.md's EAGAIN-style ruling) |
| `ERR_PIPE` | `$E5` | write() to a pipe with no reader |
| `ERR_NFILE` | `$E9` | file table overflow (V7 ENFILE): the system-wide open-file table (`OFT_COUNT`) is full, or the io_buffer pool is empty with nothing lendable in it. Before 2026-09-07 both cases came back as `ERR_AGAIN`, and utilities printed `cannot open` on a file that exists (docs/IOBUF-LENDING.md) |
| `ERR_PRODOS_UNWIRED` | `$E6` | a file-call number reached `PRODOS_DELEGATE`, which task #11 has not yet wired to real MLI |

A caller's error-decoding logic therefore branches once on "is this
above `$DF`?" to know which table to consult -- cheap, and it never needs
updating as the MLI's own error table evolves (maux doesn't own it).

### Item 5 -- fd numbers: **RULING: confirmed V6/Unix convention (0/1/2 =
stdin/stdout/stderr) for the numbers a PROCESS sees; the kernel
translates them to MLI reference numbers via a per-process fd->refnum
table in the PCB.**

MLI reference numbers (returned by `OPEN`) start at 1 and are a
kernel-wide (not per-process) resource the MLI itself allocates --
they're not the small 0/1/2-based numbers Unix processes expect, and
exposing raw refnums to a process would leak MLI's own allocation
policy into the ABI (surprising renumbering as unrelated processes
open/close files) and collide with the 0/1/2 tty convention (nothing
guarantees the MLI never hands back refnum 1 for a real file). The PCB
grows one small table -- `fd -> refnum`, 8 entries matching
`PCB_FDTABLE` (already sized in `inc/memmap.equ`, task #2) -- indices
0/1/2 are kernel-reserved for the tty (never forwarded to the MLI at
all, serviced by the tty driver directly), indices 3+ map to whatever
refnum the MLI returned from the matching `OPEN`. `close()` clears the
table slot and calls MLI `CLOSE` with the stored refnum.

### Item 6 -- open()/creat() flags and mode: **RULING: flags map to the
real MLI access bits (TRM ch. 4: bit0=read, bit1=write -- `O_RDONLY=$01`,
`O_WRONLY=$02`, `O_RDWR=$03`); `creat()`'s mode byte forwards to the
MLI `CREATE` parmlist's access/storage-type/file-type fields (task #11
wires the exact byte layout; this task fixes only that it's a
passthrough, not a maux-invented byte).** Supersedes the pre-ruling
0/1/2 sequential draft -- same NUMBERS liba already used for
`O_RDONLY`/`O_WRONLY`/`O_RDWR` turn out to coincidentally match ($01/$02
vs the old $00/$01), a one-line liba diff, not a redesign.

### Item 6b -- OPEN read intent (OPEN-RO-2, 2026-10-21): `param_count`
`$83` instead of 3 (`OPEN_RO`, inc/sc.file.equ).

The MLI's OPEN parmlist has no mode, so the kernel cannot tell `exec 3<F`
from `exec 3>>F` at OPEN. A caller that only reads says so with the high
bit of the count byte. The kernel tests for EXACTLY `$83` (a `$A5` poison
fill, 0 or 3 is today's open), stores 3 back before the MLI sees it, and:

* the second read-intent open of a path that already has read-intent
  opens joins them: no ProDOS OPEN, no buffer, one shared ProDOS file
  with a mark per descriptor (swapped in on use, ~4k cycles per switch,
  nothing for unshared opens);
* WRITE and SET_EOF through a read-intent descriptor are refused with
  `MLIE_ACCESS` (`$4E`) and nothing reaches ProDOS;
* **OPEN-RW-2 (2026-10-22) changed the next rule.** A group may hold ONE
  no-intent (write-capable) member: an ordinary open of a path a read
  group holds, and a read-intent open of a path one ordinary open holds,
  now JOIN (one shared FCB, so the reader sees the writer's live EOF);
  a SECOND ordinary open of the path is `$50` (`MLIE_FILOPEN`), as
  before (append safety: `>>` seeks to EOF once at open). Admission
  counts every open of the path, resident and parked. Writer = one open
  file DESCRIPTION: fork and dup add no member;
* **OAPPEND-1 (2026-10-22): `param_count` `$23` (`OPEN_APPEND`)
  declares APPEND intent.** The kernel tests for EXACTLY `$23`, stores 3
  back, and marks the entry OFTF_AP: every WRITE and SET_EOF through it
  first does GET_EOF, SET_MARK(EOF) (atomic: nothing in the path
  blocks), so any number of appenders may share a file and no write lands
  anywhere but the end. The count above becomes: a read open joins unless
  two no-intent writers (or a no-intent writer and an appender) are
  there; an append open joins unless a no-intent writer is; a no-intent
  open joins only readers. `$A3` (read + append) is reserved: `ERR_INVAL`.
  Devices, pipes and block devices ignore it. sh `>>`, `exec N>>`,
  `tee -a` and nohup's `nohup.out` declare it; counts 3 and `$83` are
  unchanged;
* a reader whose mark is above the live EOF (the writer truncated) reads
  0 bytes with no error, GET_MARK still returns the mark, GET_EOF works,
  and a legal SET_MARK recovers it;
* the writer leaving a group that still has members FLUSHes; a FAILED
  final CLOSE quarantines the buffer page (counted, never re-lent) and
  the error reaches an explicit close; exit, dup2's implicit close and
  spawn file-action closes lose the error but are safe;
* fork/dup/spawn share a descriptor's mark (one open file description);
  two descriptors of one path never share a mark.

Who sets it: `sh` for `<` (not `>>`, which shares the parmlist), `cmp`,
`comm`, `diff`, `join`, `paste`, `pr`; liba has no `open()`, each program
changes one constant. Design, price and gates: docs/OPEN-RO-2-NOTES.md.

### Item 7 -- readdir() contract: **RULING: no separate call number --
built from MLI `OPEN`+`READ` on the directory file, the standard MLI
pattern (TRM ch. 4).** A directory is an ordinary MLI file of fixed-size
39-byte entries (TRM ch. 4's directory-entry format) that `READ` returns
raw, block at a time; maux's kernel does not need to parse or reshape
them for the delegate path to work -- `read(dirfd, buf, 39)` (or however
many entries the caller's buffer holds, at 39 bytes each) IS `readdir()`
at the kernel-ABI level. A future liba `SC_READDIR` becomes a thin
`SC_OPEN`+`SC_READ`+`SC_CLOSE` wrapper that also strips the 4 leading
storage/type/name-length bytes down to a plain NUL-terminated name if it
wants a friendlier userland shape -- that reshaping is liba's job, not a
kernel call. **Max filename length**: MLI directory entries carry a
15-byte name field (TRM ch. 4) -- this is now a *fact* inherited from the
delegate, not a maux-invented cap (superseding the pre-ruling "V6-style
14-byte" guess).

### Item 8 -- brk(): **RULING: ratify liba's draft -- absolute new-break
address, not a delta.** Unaffected by the ProDOS ruling (no MLI
equivalent; sbrk-style heap growth is maux's own concept, scoped to
`PROC_HEAP_TOP` per MEMMAP sec 3.2). Absolute is simpler for the KERNEL
(one clamp-and-compare against the current watermark) and doesn't
burden the CALLER either, since a userland `sbrk()` wrapper computing
`new = cached_old + delta` before calling `brk(new)` needs a
last-known-break cache regardless of which convention the syscall
itself uses -- so absolute adds no caller-side cost over delta. Recorded
alternative (rejected): delta-based `brk()`, pushing bookkeeping into
the kernel for no offsetting benefit.

### Item 9 -- wait(): **RULING: V6-style wait-any, scoped to the
CALLER's own children (per-process parent-pid tracking in the PCB, not
"any process on the system") -- no pid filter in v1.**

`wait()` searches only the caller's own children (via the PCB's
`PCB_PARENT` field, already in the annex struct per task #2) and reaps
whichever exits/is-exited soonest, returning `(pid, status)`; a process
with no children of its own gets `ERR_CHILD` regardless of what else is
running. This is sufficient for a pipeline, because **`sh` doesn't need
pid-selective reaping -- it needs to block until a KNOWN COUNT of its own
children are all done**, and completion order doesn't matter for that:

```
pipeline of N commands:
    pids = [spawn(cmd, ...) for cmd in commands]   # N children, sh's own
    for _ in range(N):
        wait(&status)         # reaps whichever finishes next; doesn't
                               # matter which, since sh only keeps the
                               # LAST command's status (classic shell
                               # $? semantics -- the pipeline's exit
                               # status is its last stage's)
    report(status)            # the status from the LAST wait() call
                               # happens to be whichever child finished
                               # LAST timewise, not positionally-last in
                               # the pipeline -- ACCEPTABLE for v1: sh
                               # tracks the LAST STAGE's pid explicitly
                               # (not "the last wait() call") and reports
                               # THAT child's status, requiring sh to
                               # match returned pids against its own
                               # pipeline list rather than trusting call
                               # order -- a few bytes of bookkeeping in
                               # sh, not a kernel feature
```

Recorded alternative (rejected, deferred to v2 if ever needed):
`waitpid()`-style pid-filtered wait. Not required for a job-control-free
v1 shell (docs/SH-DESIGN.md's own scope: "no job control"); the count-N
pattern above covers every v1 pipeline shape.

### Item 10 -- spawn()'s fdactions list: **DEFINED.**

Two operations, 3-byte fixed records, `FDACT_END`(0)-terminated list
(a NULL fdactions pointer means "no actions" without needing even one
byte):

```
[opcode: 1][target fd: 1][source fd or 0: 1]

FDACT_DUP   (1): child[target] = dup(PARENT[source])
FDACT_CLOSE (2): child[target] = closed (source byte unused, reserved 0)
```

**Default fd inheritance (SH-DESIGN Q3, closed here):** a spawned
child's fd table starts as a **copy of the parent's fds 0/1/2 only** (a
real dup -- independent close semantics -- not a shared handle), never
the parent's WHOLE table. This makes the trivial case (`ls`, no
redirection) work with an empty/NULL fdactions list, while never leaking
arbitrary fds (a ramdisk fd `sh` itself has open, say) into children by
accident -- the "opt-out, enumerate every close" burden SH-DESIGN worried
about never arises, because nothing beyond 0/1/2 is visible unless
`fdactions` explicitly grants it.

**`FDACT_DUP`'s source is always resolved against the PARENT's fd table
as of `spawn()` time** (SH-DESIGN Q2, closed) -- never a fd a PRIOR
action in the SAME list just created. This is a deliberate simplicity
choice: the kernel never needs to track a partially-built child table to
resolve chained dups, and no fdactions list any v1 shell needs (single
commands, pipelines, redirection) ever requires dup-from-a-just-created-
fd -- every dup source is always something the PARENT already had open
(a pipe end from its own `pipe()` call, or a file it opened for
redirection).

**Ordering vs. image load (SH-DESIGN Q2's other half, closed):**
fdactions apply to the child PCB's fd table as the LAST step of
`spawn()`, after the image is fully loaded and the `$FFxx` page is
stamped, immediately before the child is marked runnable -- fd-table
writes and bank-memory writes touch disjoint kernel structures, so there
is no real ordering constraint; doing fdactions last is simplest (no
"is this half-initialized child's fd table valid yet" question, because
it never runs before this step completes).

**A bad list fails the whole spawn (DUPFD-1, docs/DUPFD-1.md).** The
list is walked IN FULL at the top of `spawn()`, before the pathname is
touched, before `LZ_WANT_SET` and before a bank is allocated
(`PRC_FDA_CHECK`, src/kernel/procfile2.s), so the replay above only ever
sees a list already proven good. `ERR_INVAL` and nothing created -- no
bank, no pid, no refcount, no armed `LZ_WANT` -- when: an opcode is not
END/DUP/CLOSE; a DUP or CLOSE target is >= 8; a DUP source is >= 8 or
is not open in the CALLER's table (the same ruling as the rest of this
item: the parent's table as of the call); a byte of the list cannot be
read (an address >= `$C000`); or 32 records pass without an END. A
CLOSE's third byte is reserved and is not judged. It used to be
otherwise: a dup from a closed source was skipped, so the child kept
whatever it inherited and a shell's `cat <&3` read the wrong file with
status 0.

**Worked example -- `sh` reaping/plumbing a 2-command pipeline** (`cmd1 |
cmd2`):

```
(rfd, wfd) = pipe()                       # rfd/wfd are IN SH's OWN table
fdactions1 = [DUP(target=1, source=wfd),  # cmd1's stdout -> pipe write end
              CLOSE(target=rfd_num)]      # cmd1 never sees the read end
fdactions2 = [DUP(target=0, source=rfd),  # cmd2's stdin -> pipe read end
              CLOSE(target=wfd_num)]      # cmd2 never sees the write end
pid1 = spawn(cmd1.path, cmd1.argv, fdactions1)
pid2 = spawn(cmd2.path, cmd2.argv, fdactions2)
close(rfd); close(wfd)                     # sh's OWN copies -- required
                                            # for cmd2's read() to ever
                                            # see EOF once cmd1 exits
                                            # (the pipe stays "held open"
                                            # by ANY fd pointing at the
                                            # write end, incl. sh's own,
                                            # until every one is closed)
wait(&s1); wait(&s2)                       # count-2 pattern, item 9
```

### Item 11 -- process entry state: **DEFINED -- spawn() synthesizes a
trapframe, so `EXIT_TAIL` launches a fresh process with ZERO special-
casing.**

The elegant consequence of the trapframe design (sec 1): a spawned
process's very first "return" is not actually different from a syscall
return, from `EXIT_TAIL`'s point of view, if `spawn()` fabricates the
SAME 6-byte frame shape at the top of the child's fresh stack:

```
[PCH][PCL][P][A][X][Y]
 =08  =00  =$20 =00 =00 =00
```

- **PC = LOAD_BASE** (`$0800`) -- the process starts executing at the
  exec image's load address; no separate "entry point" field, no
  chain-count byte (that convention is SmartPort-boot-specific, not
  something the kernel's own exec loader needs to replicate -- a
  genuinely different code path).
- **P = $20** -- bit 5 (the "unused," always-1 bit every PHP/hardware
  push sets) and nothing else: N=V=B=D=I=Z=C=0. I=0 is the important
  bit -- fresh processes start INTERRUPTIBLE (preemptible by the VBL
  scheduler), matching every other running process's posture.
- **A=X=Y=0** -- no meaningful convention needs them; argv/argc are
  fetched from the fixed `PROC_LOWFREE` page (item 13), not registers,
  so there's no reason to burn register-transport complexity on a
  one-time setup that already has a simpler channel.
- **SP = $F9** (i.e., `$FF` minus the 6 frame bytes) -- matching exactly
  what SP would be for a REAL suspended process with a 6-byte trapframe
  on top. `EXIT_TAIL`'s `PLA/PLA/PLA/RTI` unwinds this identically to a
  real return, with no first-launch special case anywhere in the exit
  path.

`spawn()` writes these 6 bytes into the child bank's own page 1 via the
SAME RAMWRT+`$C073` bounce the exec loader already uses for the image
itself (see item 13) -- one more small write in the same pass, not a new
mechanism.

### Item 13 -- argv staging (the chicken-and-egg): **DEFINED -- the
kernel writes the argv block into the child bank during spawn, via the
same RAMWRT+`$C073` path the exec loader uses for the image; string
BYTES are re-packed, not copied verbatim (pointer values from the
parent's address space are meaningless in the child's).**

The parent (`sh`) builds argv as an ordinary array of pointers into its
OWN process memory (ordinary liba strings) -- this is fine, because
`spawn()`'s kernel-side implementation reads the PARENT's memory via the
SAME copyin primitive `entry.s` already provides (RAMRD+`$C073`
targeting the parent's bank, the caller of the `spawn()` syscall), no
new access path needed. The chicken-and-egg resolves because the
kernel, not the parent, does the actual placement:

1. Kernel allocates the child bank, loads the image (existing exec-
   loader work, `$C073`+RAMWRT bounce via main).
2. Kernel copies argv's STRING BYTES (not the parent's pointer values,
   which are meaningless once the strings move) into the child's
   `$0300+` region (`PROC_LOWFREE`, right after the pointer array --
   memmap.equ's own 1536-byte reservation covers this comfortably),
   packed back-to-back NUL-terminated, reading each source string via
   copyin from the PARENT's bank and writing via the SAME RAMWRT+
   `$C073` bounce (source bank != dest bank, both reached from main --
   exactly task #4's bank-clone primitive's own bounce-via-main shape,
   reused, not reinvented).
3. Kernel writes the `ARGC`/`ARGV` header at `PROC_LOWFREE` (`$0200`):
   `ARGC` (1 byte), then `argc` 2-byte pointers -- each pointer
   RECOMPUTED to point at the just-written copy's address in the
   CHILD's `$0300+` region (not the parent's original addresses, which
   the child could never dereference).
4. Kernel synthesizes the entry trapframe (item 11) and marks the child
   runnable.

This is real repacking work (the same conceptual step `execve()` does on
a real Unix, copying argv/envp onto the new process's own stack and
rewriting the pointer array) -- not a special case, just one more pass
through the bank-clone primitive's existing bounce-via-main mechanism.

### Item 14 -- SYS_SLPUNTIL (26): **a timed wait, absolute target**
(SLEEP-1, 2026-10-21; the design is docs/SLEEP-1.md, the numbers
docs/SLEEP-1-NOTES.md). The brief calls it SYS_SLEEPUNTIL; the house's
13-character label limit makes it `SYS_SLPUNTIL` / `PRC_SLPUNTIL`.

* **Parameter:** a 4-byte block holding the ABSOLUTE tick count to
  sleep until (little-endian, the K_VBL_TICKS timeline that SYS_TICK
  reports). `/bin/sleep` computes `now + N * 60`.
* **Result:** A = 0 when the target is reached, or already past
  (including `now == target`). Carry set: `ERR_NOSYS` when no tick
  runs (K_TIMER_MODE 0 unprobed or 3 COOP: the counter is frozen, so
  the call would never return); `ERR_INTR` for a held signal, from
  PRC_BLCK_RTRY's one delivery point as for every blocking call.
* **Why absolute:** a blocked call rewinds the user PC and RERUNS the
  whole call on wake, and the kernel keeps no frame for a sleeper. A
  relative sleep(N) would restart its N on every wake, or need
  per-pid state; an absolute target needs neither.
* **The mechanism (V6's, `sys2.c` sslep + `clock.c`):** ONE global
  earliest deadline, `K_SLP_DL`, armed by `K_SLP_ARM`. A sleeper
  that is not yet due lowers the deadline if its target is earlier
  and blocks on channel `SLP_CHAN` ($B0). The tick hook
  (TTY_TICK -> SLP_TICK) clears the flag and wakes the channel when
  the counter reaches the deadline; every sleeper reruns, returns if
  due, else re-arms. V6 wakes on equality once a second; maux wakes
  on `>=`, every tick.
* **Wrap:** both compares are the sign of a 32-bit subtraction (signed
  modular), valid while the two times are under 2^31 ticks (about 414
  days) apart. `/bin/sleep`'s old unsigned compare was wrong across
  `$FFFFFFFF -> 0`.
* **Interrupt contract:** the hook runs from SCH_TICK and from
  MAIN_IRQ_SHIM inside the MLI and TTY windows. The call updates the
  deadline with interrupts masked (entered masked, opens no window,
  stays masked through the block); the hook writes only K_SLP_ARM
  beyond SCH_WAKEUP's own cells, and restores the interrupted bank
  after the wake (SCH_WAKEUP leaves BANKSEL 0).
* **Where it can block:** only where K_TICK_HOOK is TTY_TICK; the
  census is docs/SLEEP-1-NOTES.md sec 11, gated by check-sleep's
  `census` row.
* init does not use it: its back-off stays a bounded SYS_TICK poll,
  because a process blocked on a dead clock cannot run its fallback.

---

## 3. Deferred items (per the task's own scoping)

- **Item 12** (process load base): already answered -- `$0800`
  (`docs/MEMMAP.md` sec 3.1). No action needed here.
- **Items 14-15** (line-ending convention, on-disk text encoding):
  tty/text-encoding scope, deferred to task #10 -- see
  `docs/USERLAND.md`'s "ABI FRICTION" #13/#14 on the userland branch for
  the exact open questions; nothing in this task's kernel-mechanics
  design constrains the answer either way (copyin/copyout move raw
  bytes, uninterpreted).
- **Item 16**: already resolved (the grep-gate self-tripping lesson,
  `docs/USERLAND.md`'s DEPOSIT CANDIDATES) -- no action needed here.

---

## 4. The $FFxx page -- exact stub sequences

`src/kernel/ffpage.s`, `put`-included, assembles to **exactly 256
bytes** at `org $FF00` (`src/test/ffpage.size.s` proves this --
`make check-syscall` asserts `wc -c` == 256). Byte-verified against
`docs/MEMMAP.md` sec 3.3's table (every section pads itself to its exact
budget via `ds SECTION+BUDGET-*`, so offsets are mechanically
guaranteed, not just visually checked):

```
$FF00  SYSCALL_ENTRY  (20B budget, 17B used)
       PHP SEI CLD PHA TXA PHA TYA PHA
       STA RAMRDMAIN  STA RAMWRTMAIN
       JMP KERNEL_ENTRY

$FF14  IRQ_ENTRY      (14B budget, 14B used)
       PHA TXA PHA TYA PHA
       STA RAMRDMAIN  STA RAMWRTMAIN
       JMP KERNEL_IRQ_ENTRY

$FF22  EXIT_TAIL      (12B budget, 12B used)
       STA RAMRDAUX  STA RAMWRTAUX
       PLA TAY  PLA TAX  PLA
       RTI

$FF2E  BANK_ID        (1B)   -- per-bank identity byte, stamped at creation
$FF2F  FFXX_SCRATCH   (5B)   -- reserved, untouched by task #3
$FF34  NMI_TRAP       (2B)   -- BRA * (parks)
$FF36  RESET_STUB     (6B)   -- SEI; LDA #0; STA $C073 (defensive only)
$FF3C  (slack, 190B)  -- unused
$FFFA  NMI/RESET/IRQ vectors (6B, hardware-fixed)
```

**Why the vector table is NOT `da LABEL`:** this file is assembled
TWICE -- once at real `org $FF00` (the byte-budget gate), once embedded
as an inert copy-source blob at whatever address `src/test/
syscalltest.s`'s linear assembly happens to place it (to be copied,
byte-for-byte, into a live bank's `$FF00` at stamp time). `da LABEL`
would emit THIS assembly's address for the label, correct only in the
first context. The vector bytes are instead computed as a page-relative
OFFSET (a label subtraction, independent of assembly base address) added
to the literal `$FF00` target -- correct in both contexts. Every other
instruction in the file is already position-independent for the same
reason (PC-relative branches; JMPs to externally-fixed targets like
`KERNEL_ENTRY` or `BANKSEL` that don't depend on this file's own base
address) -- the vector table is the one place with a genuine internal
self-reference.

---

## 5. copyin/copyout -- LC-resident primitives

Per `docs/ARCHITECTURE.md`'s review A2 ruling ("copyin/copyout primitives
resident in MAIN LC -- fetch-immune to RAMRD"): these routines flip
RAMRD/RAMWRT mid-execution to reach process memory, so their OWN
instruction fetch must be immune to that flip -- code living in ordinary
`$0200-$BFFF` is NOT immune (`learning:01KW1GTYGVYAPQRGS5P7J66RWD`), so
they must live somewhere RAMRD-immune. LC (`$D000-$FFFF`, governed by
the `$C080-$C08F` bank-select/read-write latches, not RAMRD) is the
architecture's chosen home -- bigger than the alternative safe zone
(page 1, ~120 free bytes, already used by the `AUXRD`-style relocatable
stub pattern in `src/kernel/bankprobe.s`), appropriate for routines with
real branch logic (three address-range paths).

**Getting code INTO LC RAM: the classic Language Card write-enable
protocol.** LC starts in ROM-mapped, write-PROTECTED state after reset
-- even after `ALTZP`/`$C073` correctly select "this bank's LC," a plain
`STA $D000` would be silently discarded without first write-enabling.
Confirmed via the ProDOS 8 TRM's own `BNKBYT1`/`BNKBYT2` interrupt-save
listing (fetched live during this task): `LDA RAMIN` (i.e. one of
`$C080-$C08F`) **twice in a row** -- the classic even/odd,
single-vs-double-access LC quirk -- enables RAM read AND write for that
bank; a single access enables read-only. `INSTALL_COPY`
(`src/kernel/entry.s`) does exactly this (`LDA LCBANK2_RAM` x2) before
copying `COPYIN_LC`/`COPYOUT_LC`'s position-independent bytes to their
LC homes (`$D000`/`$D040`).

**Scope implemented vs. specified:**

| range | status |
|---|---|
| `$0200-$BFFF` | **implemented, tested** -- `COPYIN_ENTRY`/`COPYOUT_ENTRY`, flip RAMRD or RAMWRT (never both at once -- the OTHER direction's default state does the right thing for free, see below), copy via `(ptr),Y` indirect addressing through main-owned ZP pointers (`K_CPY_PROC`/`K_CPY_MAIN`) |
| `$C000-$CFFF` | **implemented, tested** -- refused outright: a high-byte range check (`$C0-$CF`) before touching any switch, `K_CPY_ERR=1`, no copy attempted |
| `$D000-$FEFF` (process LC) | **specified, not wired into any v1 call's dispatch** -- see below |

**Why one instruction pair suffices for `$0200-$BFFF`** (a design point
worth recording): copying FROM aux TO main needs `RAMRD=aux` (so the
read side sees the process) and `RAMWRT=main` (so the write side lands
in the kernel's own scratch) -- but `RAMWRT` is ALREADY main (the kernel's
whole steady-state posture, MEMMAP sec 4), so `COPYIN` only ever touches
`RAMRD`; `COPYOUT` (main->aux) only ever touches `RAMWRT`, by the same
argument in reverse. Neither routine needs to save-and-restore the
OTHER switch, because the other switch was already correct.

**The `$D000-$FEFF` path (specified, not exercised by this task's
automated test):** this is a PROCESS's own LC storage -- reaching it
needs `ALTZP=aux` (not just RAMRD/RAMWRT), which is where the design
gets genuinely harder: a `(ptr),Y` indirect read needs its POINTER bytes
in zero page, but zero page is ALSO `ALTZP`-governed -- flipping `ALTZP`
to reach the process's LC would ALSO redirect the pointer read to the
process's zero page, corrupting it. The specified fix: no ZP-indirect
addressing for this path at all -- a **self-modified absolute operand**
(patch the target address directly into the `LDA $nnnn,Y`/`STA $nnnn,Y`
instruction bytes before executing them, a standard 6502 technique for
"arbitrary absolute address, no ZP pointer available"), plus the sec 3.4
bank-2-default discipline (`docs/MEMMAP.md`: always explicitly select
bank 2 before touching `$D000-$DFFF`, never trust ambient latch state).
**No v1 syscall argument needs this path** (process LC storage is not
part of any v1 call's parameter shape -- file calls go to
`PRODOS_DELEGATE`, which has its own, unrelated ZP-footprint concerns
task #11 owns) -- implementing it fully was out of this task's time
budget, and is flagged here rather than silently dropped.

### 5.1 Named discipline: the RAMRD/RAMWRT kernel-data-read corollary

**Architect review finding, alongside the RAMRD-governs-instruction-
fetch learning this whole design already builds on
(`learning:01KW1GTYGVYAPQRGS5P7J66RWD`):**

> Inside a `RAMRD=aux` (or `RAMWRT=aux`) bracket, kernel data reads are
> limited to REGISTERS and ZERO PAGE (ALTZP-governed, immune to RAMRD/
> RAMWRT) -- never an absolute read of anything in `$0200-$BFFF` kernel
> state. RAMRD/RAMWRT steer ALL data access in that window, including a
> kernel global's own address -- there is no way to "read past" the
> switch from inside the bracket.

The bug this closes: `COPYIN_LC_SRC`'s loop originally compared `Y`
against a remembered count via `CPY K_CPY_COUNT` -- a plain absolute read
-- **while `RAMRD=aux` was live**, inside the very bracket the switch was
flipped for. The read landed on the PROCESS bank's byte at that address,
not the kernel's own counter; `Y` then ran to whatever garbage value was
there (bounded only by the 8-bit wraparound, so it terminated after up
to 256 copied bytes) and the copy overran its 4-byte destination into
adjacent kernel state. **Fixed**: the loop bound is hoisted into a
register (`X`) BEFORE the bracket opens, and the loop counts down
(`INY`/`DEX`/`BNE`) instead of comparing against remembered memory --
zero memory reads of kernel state inside either bracket, not merely
zero-page-safe ones (register-only is strictly simpler to audit than
"zero page is safe, absolute isn't," and doesn't depend on a future
edit correctly remembering which zero-page cells are safe where).

**Interrupt-safety assumption this discipline protects** (see sec 7's own
per-window argument): the argument that copyin/copyout's `RAMRD`/
`RAMWRT` brackets don't need `SEI` protection of their own (they run
entirely inside the ALREADY-`SEI`'d kernel critical section, per sec 7.2)
only holds if the bracket's OWN correctness doesn't depend on reading
back kernel state through the very switch it just flipped. This
discipline is what makes that true -- it is now a standing assumption of
sec 7's argument, not just a copyin/copyout implementation detail, and
belongs alongside the RAMRD-governs-fetch rule as something every
future `RAMRD=aux`/`RAMWRT=aux` bracket in this kernel must honor.

A SECOND, related bug found in the same review pass: `COPYIN_LC_SRC`'s
own high-byte range check let addresses `>= $D0` fall through into the
`$0200-$BFFF` copy path -- an attempted copyin from a process's own LC
storage would "succeed" by copying MAIN's LC (this routine's own code)
instead, since RAMRD does not govern `$D000+` at all. **Fixed**: `$D0+`
now refuses with `K_CPY_ERR=2`, DISTINCT from `K_CPY_ERR=1`
($C0-$CF, forbidden forever, per the one-page invariant) -- a caller can
tell "this will never work" from "not wired up yet" (sec 5's own $D000-
$FEFF section is the "not wired up yet" case this distinguishes from).

---

## 6. Main-side kernel entry/exit -- `src/kernel/entry.s`

### `KERNEL_ENTRY` (syscall dispatch)

```
TSX                       ; X = process SP (ALTZP still aux)
LDA FRAME_Y,X : STA K_CALLNUM      ; read frame WHILE ALTZP=aux
LDA FRAME_A,X : STA K_PARMLO       ; (all three MUST happen before the
LDA FRAME_X,X : STA K_PARMHI       ;  ALTZP flip below -- see sec 7)
STX K_CALLER_SP
STA ALTZPMAIN             ; NOW flip ALTZP -> main
LDX #$FF : TXS            ; kernel's own fixed stack -- pushes safe from here
[dispatch: MLI_RANGE_LO check -> PRODOS_DELEGATE or K_DISPATCH_LO/HI table]
JSR K_CALL_VEC             ; -> handler (the "JSR-indirect" trick: JMP
                            ;    (K_VEC), reached via JSR K_CALL_VEC so the
                            ;    handler's own RTS returns to KERNEL_ENTRY)
JMP KERNEL_EXIT
```

### `KERNEL_EXIT` (shared by every handler's return, syscall path only)

```
LDX K_CALLER_SP
STA ALTZPAUX               ; CRITICAL SECTION BEGINS -- no pushes until TXS
LDA K_RESULT : STA FRAME_A,X                ; patch return value
LDA FRAME_P,X : AND #$FE                     ; clear carry bit ONLY --
  [K_RESULT_ERR ? ORA #$01 : nothing]        ; every other flag (incl. D)
STA FRAME_P,X                                ; is the caller's own, untouched
; $C073 intentionally NOT written -- see scope note below
TXS                         ; CRITICAL SECTION ENDS
JMP $FF22                   ; EXIT_TAIL, fixed address, every bank identical
```

**Scope note (task #3 vs. task #6):** this exit path always resumes the
SAME bank that entered -- `$C073` is write-only and untouched since the
door stub ran, so re-selecting "the same bank" is a genuine no-op, and
this file never writes `BANKSEL` at all. A context-switching exit
(task #6's scheduler) inserts exactly one `LDA K_TARGETBANK / STA
BANKSEL` at the marked point in both `KERNEL_EXIT` and
`KERNEL_IRQ_SERVICE`; nothing else in this file changes.

### `KERNEL_IRQ_ENTRY` / `KERNEL_IRQ_SERVICE` (IRQ + BRK door)

```
TSX : STX K_CALLER_SP
LDA FRAME_P,X : AND #$10 : STA K_ISBRK    ; B flag = bit 4
STA ALTZPMAIN
LDX #$FF : TXS
LDA K_ISBRK
BEQ KERNEL_IRQ_SERVICE     ; B=0 -> real hardware IRQ
JMP KERNEL_BRK_TRAP         ; B=1 -> BRK (debugger trap)

KERNEL_IRQ_SERVICE:
JSR K_IRQ_CALL_HOOK         ; -> device driver, via K_IRQ_HOOK (an
                            ;    includer-supplied JMP-indirect vector --
                            ;    this file stays hardware-agnostic)
LDX K_CALLER_SP
STA ALTZPAUX                ; same critical-section discipline
TXS
JMP $FF22                   ; no return-value patch -- IRQ is asynchronous
```

`KERNEL_BRK_TRAP`: V1's entire "debugger" (no real one exists yet, out
of scope for task #3) -- writes a marker byte (`K_BRK_MARKER`), then
parks in a tight `JMP *`-equivalent loop, inspectable via the emulator's
`regs`/`peek` rather than silently falling into the syscall dispatch
path. A real debugger (later task) replaces the halt with inspection;
the discrimination mechanism (reaching this routine AT ALL, distinctly
from `KERNEL_ENTRY`) does not change.

---

## 7. Per-window interrupt-safety argument

This is the deliverable's own explicit requirement: for every
instruction boundary in both doors and the exit tail, state which
memory/stack state an IRQ landing there would see, and why it's safe (or
why it cannot land there).

**The governing fact:** the 65C02's IRQ sequence (and BRK's own
microcode) unconditionally sets `I=1` as part of taking the
interrupt/executing the instruction, BEFORE the vector is even fetched --
this is hardware, not software discipline. So `IRQ_ENTRY`/
`KERNEL_IRQ_ENTRY`/`KERNEL_IRQ_SERVICE`/`KERNEL_BRK_TRAP`/`EXIT_TAIL` are
ALL entered with `I` already 1, and (assuming no code voluntarily clears
it -- see sec 7.4's caveat) stay masked until `RTI` restores whatever `I`
value the frame's P byte carries. The ONLY genuinely vulnerable window
is therefore on the SYSCALL door, between the `JSR $FF00` completing and
the stub's own `SEI` completing -- `IRQ_ENTRY` (hardware-forced I=1
before its first instruction even fetches) and everything downstream of
`SEI`/hardware-I=1 have no vulnerable window AT ALL, by construction.

### 7.1 `SYSCALL_ENTRY` -- the one door with a real window

| after instruction | I state | stack/memory state | IRQ landing here |
|---|---|---|---|
| `JSR $FF00` (before `PHP`) | 0 (caller's) | JSR has pushed PCH,PCL only; nothing else disturbed | **Vulnerable, but safe.** Hardware takes the IRQ: pushes ITS OWN PCH,PCL (pointing at the still-unexecuted `PHP`),P(with I,then sets I=1),vectors to `IRQ_ENTRY`. This is a full, ordinary IRQ service -- LIFO stack discipline means it unwinds via its OWN `RTI`, resuming exactly at `PHP`, with nothing about the pending syscall disturbed (the syscall's own push sequence hasn't started yet). |
| `PHP` (before `SEI`) | 0 (caller's, now ALSO sitting one byte into the syscall's own frame) | frame so far: `[[JSR's PCH,PCL]][caller P]` | **Vulnerable, but safe.** Same argument -- a nested IRQ pushes its OWN 3-byte frame on top of the syscall's partial 1-byte frame, services normally, `RTI`s back to right after `PHP` (i.e., to `SEI`). The syscall's own eventual `PHA/TXA PHA/TYA PHA` haven't run yet, so there's no partial A/X/Y state to corrupt. |
| `SEI` completes | **1** | frame: `[PCH][PCL][P]` (3 of 6 bytes) | **Cannot land here or anywhere downstream in this door** -- `I=1` from this instruction forward, through `CLD`, the three register pushes, the two switch flips, and the `JMP`. |

**Why this window is acceptable, not just "survivable":** the two
vulnerable points are BEFORE any kernel state (main's ZP, the kernel
stack, `$C073`) is touched at all -- the process's OWN stack is the only
thing involved, and it already tolerates arbitrary nested nesting by
ordinary 6502 push/pop LIFO discipline. This is exactly what "IRQ_ENTRY
and SYSCALL_ENTRY produce byte-identical frames" buys: a nested IRQ
here isn't a special case requiring separate reasoning, it's just
another ordinary frame on the same stack.

### 7.2 `IRQ_ENTRY` and downstream in the IRQ door -- no window

Hardware sets `I=1` as part of taking the interrupt/BRK, before
`IRQ_ENTRY`'s first instruction (`PHA`) even fetches. Every instruction
from there through `KERNEL_IRQ_ENTRY`'s B-flag test, `KERNEL_IRQ_SERVICE`
or `KERNEL_BRK_TRAP`, and `EXIT_TAIL`'s `RTI` executes with `I=1`
continuously -- **no landing window exists**, by the same hardware fact.
(sec 7.4 records the one caveat this task's own testing found to this
argument.)

### 7.3 The entry-side hazard: TSX / ALTZP-flip / load-kernel-SP

Not an IRQ-landing question (already covered by sec 7.1/7.2's `I=1`
argument for everything past the doors' own prologues) but a SEPARATE,
real hazard this task's design explicitly calls out: between `STA
ALTZPMAIN` and `LDX #$FF : TXS`, the real SP register still holds the
PROCESS's captured value, but page 1 now resolves to MAIN's own page 1
(the `ALTZP` flip already happened). A push in this window (a stray
`JSR`, for instance) would land at an unpredictable MAIN-page-1 offset
(whatever the process's SP happened to be), not a known-safe kernel
stack slot. **This task's code has zero instructions in this window**
(the flip and the reload are adjacent) -- the hazard is closed by
construction, not by discipline alone, but it's recorded here because a
future edit that inserts ANYTHING between those two lines reopens it.

### 7.4 `KERNEL_EXIT`'s critical section -- no pushes between ALTZP-flip and TXS

Same shape as sec 7.3, mirrored on exit: between `STA ALTZPAUX` and the
final `TXS`, the real SP is still the KERNEL's value, but page 1 now
resolves to the PROCESS's aux page 1. A push here would land in the
process's stack at the KERNEL's OWN offset (`$FF`), clobbering the top
of whatever the process had there. The code performs only `LDA`/`STA`
via absolute,X (patching `FRAME_A`/`FRAME_P`) in this window -- no
`PHA`/`JSR`/`PLA` -- so the hazard is closed the same way, by
construction. This window is `I=1`-protected too (inherited from
whichever door got us here), so it's doubly safe against BOTH an
IRQ-recognition hazard and the register-corruption hazard.

### 7.5 Rig finding: a called-firmware CLI can violate the "no window past SEI" argument -- RESOLVED for v1 by policy

**Original finding (retained -- deposit-grade, unchanged by the
resolution below):** testing `KERNEL_IRQ_SERVICE`'s device-hook call
against the REAL AppleMouse II ROM firmware (`ServeMouse`, called via
the documented Pascal-1.1 entry convention -- verified byte-identical to
verilogapple's own end-to-end firmware probe, `sim/mouse/tb_mouse_fw.cpp`)
showed behavior consistent with `ServeMouse`'s internal PIA handshake
re-enabling interrupts (`CLI`) as part of its own normal operation,
BEFORE returning to `KERNEL_IRQ_SERVICE`. This means sec 7.2's "no landing
window" argument, which assumes NOTHING invoked from inside a kernel
critical section ever clears `I`, does not hold once real, uncontrolled
device firmware is called from that section: a second VBL IRQ can be
recognized WHILE `KERNEL_IRQ_SERVICE` is still inside its `JSR` to the
device hook, and the entry/exit machinery's "always reset SP to `$FF`"
discipline is unsafe under that kind of nesting -- a nested entry
resetting SP to the SAME fixed value collides with and corrupts the
outer invocation's still-pending return addresses.

**ARCHITECT RULING (resolves this for v1): the kernel never calls mouse
firmware -- ServeMouse or any other `$Cn00` ROM entry -- from ANY context
where a stray internal `CLI` could land inside a critical section this
kernel doesn't control.** This task, in the same round, found the hazard
is not actually IRQ-path-specific: the SAME firmware behavior was
observed corrupting `MAIN_ENTRY`'s own boot-time stack when `InitMouse`/
`SetMouse` were called at boot (interrupts nominally masked by `SEI`,
per the architect's original allowance for non-IRQ-context firmware use
-- but "masked by the CALLER" does not stop the CALLEE from internally
`CLI`-ing, exactly the same mechanism as the IRQ-path finding, just at a
different call site sharing the same fixed boot-time `$FF` stack).
Given firmware's internal interrupt discipline is not something this
kernel can audit or control at ANY call site, the resolution adopted
here is broader than "avoid it in the IRQ path": **the mouse card is
brought up ENTIRELY via direct 6821 PIA register pokes -- no ROM call at
all, boot or IRQ.** `src/test/syscalltest.s`'s `MOUSE_SEND_CMD` (shared
by boot-time bring-up and `MOUSE_ISR`) drives the PIA handshake protocol
directly (register model read from `~/src/verilogapple/sim/mouse/
mouse_card.h` for this fix, not from memory): `$C0(8+slot)0-3` =
PRA/DDRA, CRA, PRB/DDRB, CRB; a command byte (M_SET `$09` at boot,
M_SERV `$20` per interrupt) is written to PRA, then Port B's bit 5
(write-clock) is strobed high-then-low via a READ-modify-write of the
LIVE Port B value (never a blind constant -- every other bit, including
the bit6/7 handshake-ready flags and ROM-bank-select bits, round-trips
untouched, the same "acknowledge one thing, disturb nothing else"
discipline as ClearMouse's own narrow clear,
learning:01KWK8F6HFGRWS8SPPQ9MHC6GS). `mouse_card.h`'s `on_command()`
(case `M_SERV`) clears the model's `irq` flag synchronously the moment
the command byte latches -- no response byte needs reading.

**Under this policy, sec 7.2's "no landing window" argument holds
machine-wide again** (no code this kernel ever invokes, in ANY context,
re-enables interrupts on its own initiative), **the fixed-SP-reset
discipline in `KERNEL_IRQ_ENTRY` is correct as specified, and the
depth-indexed reentrancy guard prototyped earlier in this task is
UNNECESSARY under this policy -- it is NOT resurrected.** The guard
itself remains a sound design for the case this policy explicitly rules
out (a genuinely uncontrolled nested source); if task #6's real timer
driver or any future device driver ever needs to call firmware it
doesn't fully control from IRQ context, that task inherits this
finding, this policy, and the (unlanded, but specified in this
document's earlier revision history) guard design as its starting
point -- not an open problem rediscovered from scratch.

**Separate, more consequential finding from implementing the ruling --
a pre-existing zero-page correctness bug, unrelated to mouse timing:**
verifying the fix (and correcting an earlier debugging error -- this
task had been passing `peek`'s `bank` parameter as `"ramworks"`, which
the tool silently ignores; the correct value is `"aux"`, confirmed
against `mcp_server.cpp`'s own tool schema -- every earlier aux-bank
memory inspection in this task's testing was unknowingly reading the
wrong data) surfaced a REAL bug in `entry.s`, present since this task's
first draft and independent of the mouse card entirely: `K_CALLER_SP`,
`K_CALLNUM`, `K_PARMLO`, `K_PARMHI` (`KERNEL_ENTRY`) and `K_ISBRK`
(`KERNEL_IRQ_ENTRY`) were zero-page cells, WRITTEN while `ALTZP=aux`
(correctly, since the frame data being cached lives on the process's
own stack at that point) but READ AFTER `KERNEL_ENTRY`'s own `STA
ALTZPMAIN` flip -- landing the write in the PROCESS's zero page and the
read in MAIN's, two different physical bytes, always reading stale/zero
data. **Fixed** by moving exactly these five cross-flip cells out of
zero page into ordinary (non-ZP) main memory -- `$0200+`-style addresses
are RAMRD/RAMWRT-governed, not `ALTZP`-governed, and RAMRD/RAMWRT are
ALREADY main by the time either door's stub `JMP`s into this file (the
stub's own `STA RAMRDMAIN`/`STA RAMWRTMAIN`), so a write at this point
is correctly bank-stable across the later `ALTZP` flip. Every OTHER
kernel cell (`K_RESULT`, `K_VEC`, the `K_CPY_*` copyin/copyout state)
is only ever touched AFTER the flip and correctly stays in zero page.
A second, smaller dispatch bug was found and fixed in the same pass:
`KERNEL_ENTRY`'s call-number-zero rejection tested equality against
`MLI_RANGE_LO` (a leftover of reordering the MLI-range check ahead of
it) instead of testing zero, letting call# 0 fall through to an
out-of-bounds dispatch-table read (`X=$FF`) instead of `ERR_NOSYS`.

**Current status of test item (e), superseding the paragraph this
replaces:** with the ruling's policy implemented and the bugs above
fixed, item (e) now PASSES cleanly with the mouse VBL genuinely
enabled: `IRQ=$050F` (1295 real 6821-driven mouse-VBL interrupts
serviced) alongside `SYS=$4E20` (the full 20,000-iteration syscall loop
completing exactly on count) in the same run -- both doors coexisting
under sustained genuine hardware interrupt load, as originally
specified. The observed IRQ rate (~1295 interrupts across the full test
run) is a product of the direct-PIA policy's own acknowledge timing and
was not tuned against the model's nominal 60 Hz period; it was not a
blocker for this task and is left as-is.

The 20,000-iteration ECHO loop's earlier failure to complete (an open
finding as of the previous draft of this section) was NOT caused by
IRQ pacing at all -- it was three separate, IRQ-independent correctness
bugs in `entry.s`, found and fixed in a subsequent review pass: the
RAMRD/RAMWRT kernel-data-read corollary violation in `COPYIN_LC_SRC`
(sec 5.1), a merlin32 immediate-mode `#` omission that broke dispatch
entirely, and a missing trapframe `PC += 1` patch that misdirected
every syscall return (sec 7.7 has the full account). None of that is
mouse-related; it is recorded here only to close out this section's
own prior "currently open, handed to task #6" note -- the finding did
not survive to task #6 as an open problem, it was resolved within this
task. sec 8.1 has the complete, final test-by-test account.

### 7.6 The exit tail (`EXIT_TAIL`, `$FF22`) -- no window, both doors

Reached only via `JMP $FF22` from inside a critical section (sec 6), always
with `I=1`. `STA RAMRDAUX`/`STA RAMWRTAUX`/`PLAx3` execute with `I=1`
continuously; `RTI` is the single instruction whose OWN execution
restores `I` (and every other flag) from the frame's `P` byte -- by
definition this is the moment the critical section ends, not a "landing
window" inside it. The very next instruction fetched (in the resumed
caller) executes in whatever interrupt state the frame said the caller
had -- correct, and exactly the point of preserving `P` byte-for-byte
except the deliberately-patched carry bit.

### 7.7 Two more correctness bugs found chasing the ECHO round trip -- both now fixed

Neither is an interrupt-safety hole (both are wrong regardless of
whether an IRQ ever lands), but both directly explain why the ECHO
round trip never completed even once across MANY earlier test sessions,
including ones with the mouse VBL fully disabled -- recorded here
because sec 1's trapframe contract and sec 6's entry/exit sequences, as
originally published, implied both were already handled correctly, and
they were not.

**Bug A -- the trapframe contract's own required `PC += 1` patch was
never implemented.** `docs/ARCHITECTURE.md`'s trapframe contract states
the frame "matches RTI pull order once the kernel patches stacked PC +=
1 (RTI does not increment where RTS does...)" -- `JSR $FF00` pushes
`PCH`/`PCL` as `(return_addr - 1)`, the standard 6502 JSR/RTS
convention where RTS's own microcode adds the `+1` back on return.
`EXIT_TAIL` uses `RTI` for BOTH doors (the entire point of the shared-
frame design) -- and `RTI` does NOT add `+1`. Without the patch, every
syscall return landed exactly one byte into its own `JSR $FF00`
instruction (the target address's high byte, `$FF`, executed as a
stray opcode) instead of the instruction after it. `KERNEL_ENTRY` now
patches `FRAME_PCL`/`FRAME_PCH` by `+1` (with carry into the high byte)
immediately after reading the frame, while `ALTZP=aux` still correctly
addresses it -- the IRQ door needs no such patch (hardware pushes the
true resume address directly, already correct for `RTI` as-is).

**Why earlier testing didn't catch this:** every check performed so far
verified the CALLEE side only -- that dispatch reached the right handler,
that `KERNEL_EXIT` was reached, that a result value was computed
correctly INSIDE the kernel. None of it verified the CALLER correctly
resumed after `RTI` returned control. A test that only checks "did the
callee finish" instead of "did life continue correctly for the caller"
cannot see this class of bug -- exactly the gap the ECHO loop (which
does real work in the caller after each syscall, and only terminates if
that work is intact) was always going to expose, and did.

**Bug B -- `KERNEL_EXIT` read `K_RESULT`/`K_RESULT_ERR` (zero page,
`ALTZP`-governed) AFTER its own `ALTZP=aux` flip**, silently reading the
process's zero page instead of the kernel's -- always `0`, regardless of
what the handler computed. The exact same bug class sec 5.1 documents for
copyin/copyout's `K_CPY_COUNT`, in a different routine the same review
pass didn't originally cover. **Fixed**: `K_RESULT`/`K_RESULT_ERR` are
now cached into `A`/`Y` BEFORE the flip (the switch-trigger `STA`
doesn't disturb `A`, so the cached return value survives into the
`FRAME_A` patch that follows immediately after) -- the same "cache in a
register before crossing the switch" pattern as sec 7.5's zero-page
cross-flip fix and sec 5.1's loop-bound hoist, applied a third time to a
third instance of the identical root cause. **Three independent
instances of the same mistake in one file is itself the strongest
argument for sec 5.1's named discipline** -- this is a pattern that recurs
easily and is worth stating once, generally, rather than re-deriving
per routine.

**UPDATE 2026-08-27 -- the count is now FIVE, and prose was not enough.**
A fifth instance turned up in `PRC_STMP_BANK` (`src/kernel/procspawn.s`):
`lda P_BANK` after the `ALTZP=aux` flip, so **every process bank stamped
itself `BANK_ID = 0`**. It was latent for the entire life of the routine
because nothing ever *read* `BANK_ID` -- implementing the shell's `$$`
made the first reader, and the bug surfaced immediately. Fixed with the
same register-cache idiom (`TAX` before the flip, `TXA` after).

That is the defining property of this class and the reason the named
discipline kept failing to prevent it: **the wrong value is a plausible
zero, not a crash.** A freshly allocated bank is zeroed, so the bad read
succeeds and only a test asserting a *non-zero* value can see it.

So the discipline is now a gate: `make check-altzp`
(`scripts/check_altzp.py`), which walks every `STA ALTZPAUX` bracket in
the tree and fails on any read of an `ALTZP`-governed address that is
not explicitly sanctioned with an `* XBANK(<regions>):` comment.

**Sanctions are per-REGION, and that is the whole point.** `ALTZP`
steers three regions -- `zp $0000-$00FF`, `stack $0100-$01FF`, and
`lc $D000-$FFFF` -- with three different intents. Bug B above is the
proof that per-*bracket* sanctioning would be worthless: `entry.s`
*legitimately* reads `FRAME_P` (`$0104`, stack page) inside that very
bracket, and the bug was an *illegitimate* zero-page read three lines
away in the same window. Sabotage-tested both ways on 2026-08-27 --
reintroducing Bug B passes a per-bracket gate and fails the per-region
one. Commons: `learning:01M11232CZ3JC28XXK6HM7RXHN`.

Both bugs are independently confirmed fixed: `TESTCALL_ARITH` now
returns the CALLER-side-verified correct value (`$7E` for both D=0 and
D=1, read back from the CALLING process's own memory after `RTI`, not
just observed inside the kernel before it), and the full 20,000-
iteration ECHO loop now terminates at exactly its starting count. See
sec 8 for the complete, current test results.

### 7.8 The MLI bracket -- the one DELIBERATE unmasked window (2026-08-18)

The blanket claim above ("`I=1` from `SEI` to `RTI`, kernel-wide") is
now NARROWED, on purpose. Every `PMLI_*` wrapper in procfd2.s runs
`cli` before `jsr MLI` and `sei` after it returns, so interrupts are
live across exactly the MLI call -- the one long, quiescent stretch of
kernel time -- and masked everywhere else. Three facts make this sound
where it would be unsound anywhere else in the kernel:

1. **The state is canonical at that boundary.** ProDOS requires the
   standard memory configuration and a stable stack of its callers;
   none of the half-states sec 7.3/sec 7.4 protect (mid-flip switches, SP/ZP
   from different banks) can exist at a legal `jsr MLI`.
2. **The landing pad schedules nothing.** A main-context tick lands
   DIRECTLY at `MAIN_IRQ_SHIM` (timer.s) via main's **LC `$FFFE`**,
   which `TMR_OWN_03FE` patches at boot (INSTALL_IRQ's idiom): save
   A/X/Y, ack the timer, count, poll the keyboard via the tick hook
   (transparent to interrupted MLI calls), repair the `$C800` latch
   for the disk slot, restore, `RTI`. No `SCH_TICK` -- `K_NOSWITCH` is
   held across the bracket as before, and a context switch cannot be
   taken out from under ProDOS; the quantum stretches during I/O.
3. **The ROM interrupt chain is deliberately BYPASSED (corrected
   2026-08-19).** The first cut received via ROM `$FFFE` -> `$C3FA` ->
   `($03FE)` per the classic contract -- and corrupted disk I/O
   nondeterministically: the //e ROM handler saves the interrupted A
   at ZP **`$45`, which is the HIGH BYTE of the block driver's live
   buffer pointer** (`$44/$45` in ProDOS's `$42-$47` device-driver
   convention; AppleIISd source confirms). Any tick taken while that
   pointer was live sent the rest of the block transfer to a garbage
   page -- and because ticks PEND during the kernel's masked
   stretches, the driver's own unmasked windows acted as magnets for
   exactly the worst-timed delivery. ProDOS's LC image keeps the LC
   read-enabled whenever main code runs unmasked, so the LC `$FFFE`
   is the vector every main-context IRQ actually takes; owning it
   directly means the ROM (and its `$45` stomp, and the `$C3FA`
   slot-3 traversal) never runs. `($03FE)` still points at the shim
   as a lossy fallback for a hypothetical LC-read-off window. A
   main-context BRK now parks visibly in the shim instead of falling
   into the monitor.

**Audit closed (2026-08-19).** A full reentrancy sweep of everything
reachable from `MAIN_IRQ_SHIM` against the AppleIISd firmware SOURCE
(github.com/freitz85/AppleIISd, read at line level) graded the two
remaining suspects SAFE with facts, not hope:

- **ZP is disjoint.** The tick path's kernel scratch (`sched.s`'s
  `$E0-$EE` via `SCH_WAKEUP`, `tty/process` cells at `$D0-$D8`) never
  collides with the interrupted context: the a2sd driver's entire
  zero-page footprint is `$3D-$4C` (`PDZPAREA` `$3D-$41` saved by the
  card itself, `$42-$47` the ProDOS device convention, `$48-$4C`
  Smartport-only), and it references nothing in `$D0-$EF` at all. The
  ROM's `$45` save was the one overlap, and the LC-vector bypass
  removed it.
- **The `$C800` reclaim is load-bearing, not hygiene.** a2sd's block
  read/write loops EXECUTE from `$C800-$CEFF` (its `EXTROM` segment;
  linker config start=$C800) -- every instruction fetch of the copy
  loop depends on the latch pointing at slot 7. The tty echo path
  claims the window for slot 3 (UltraTerm) on every echoed key, so
  the shim's unconditional `$CFFF`-release + `$C700`-reclaim before
  `RTI` is the single thing that lets a tick land inside a block
  transfer and resume it. A bare `$C700` read has no card-side effect
  (plain PROM bytes; dispatch is by execution, not access), and the
  firmware never reads SLOTC3ROM/INTCXROM, so no further state needs
  restoring on its behalf.

One fragility to respect when touching the tick path: `TTY_TICK`'s
save/restore list covers exactly the `P_*`/sched cells the hook chain
touches TODAY. Adding a new scratch cell to anything reachable from
the tick hook without extending that list reopens the `$45` bug class
one address at a time.

WHY: masked MLI *loses* things. The level-held IRQ line pends exactly
ONE tick, so any read longer than 17 ms drops ticks; the IIe keyboard
latches exactly ONE key, so type-ahead beyond the first character died
during every large I/O -- and the interrupt character the console
roadmap needs (`^C` during a runaway `cat`) is impossible without a
poll that runs mid-read. The companion tty change (the raw type-ahead
ring, process.s/tty.s: `TTY_KEYIN` drains the hardware latch into a
64-byte ring on every poll; the cooked editor consumes from the ring
only when the line buffer is free) is what makes the captured
keystrokes durable. Gate: `check-mame` phase 4 types a complete ed
session DURING ed's own 88-block binary load and asserts the file
lands and the shell reprompts; verified to fail against the
unbracketed kernel.

---

## 8. Test harness -- `src/test/syscalltest.s`, `make check-syscall`

### What it builds and how

A multi-block SmartPort boot image (block 0 = a tiny chain-loader, since
the ROM autostart only loads ONE 512-byte block -- `scripts/
build_multiblock_image.py` packs `syscalltest.bin`'s own multiple blocks
sequentially, and the loader reads them back via a signature-checked
SmartPort dispatch adapted from `~/src/malisp/src/bootblock.s`'s
`SP_INIT`/`SP_DISPATCH`, per HACKING.md's sibling-repo-precedent
convention). `src/test/ffpage.size.s` separately proves the 256-byte
budget (sec 4).

### What the test proves, and how each was actually verified

| item | claim | verification method | result |
|---|---:|---|---|
| (a) | kernel skeleton installed, bank 1's `$FFxx` page stamped | `screen_text` shows the `MAUX SYSCALL` boot banner (printed before mouse init even runs); `until_pc $FF00` inside bank 1 confirms `JSR $FF00` from bank 1 reaches the stamped `SYSCALL_ENTRY` | **PASS**, reproducible, fast (~175K cycles) |
| (b) | a fake process enters and runs in its own bank | `until_pc $0800` (bank 1 context, `peek ... bank:"aux"`) hit reproducibly; the process's own writes to `$0900-$0903` observed via single-instruction stepping | **PASS**, reproducible |
| (c) | echo call proves the copyin+copyout round trip | `TESTCALL_ECHO` completes every one of the loop's 20,000 iterations (`SYS=$4E20` -- exactly `LOOPCOUNT`, no overrun, no wraparound); the report line is produced by the CALLER after `RTI`, so this also transitively verifies Bug A's PC+1 patch (sec 7.7) | **PASS**, reproducible, full 20,000-iteration budget |
| (d) | kernel arithmetic undamaged by caller's D; D restored on return | `TESTCALL_ARITH` called with D=0 then D=1 SET; both calls' results read back from the CALLING process's own memory after `RTI` (not just observed inside the kernel): `ARITH D0=$7E7E38` -- `D0=$7E`, `D1=$7E` (both `$79+$05`), `FLAG=$38` with bit3 set confirming the caller's D flag was restored | **PASS**, reproducible, mouse-enabled configuration |
| (e) | both doors coexist under sustained mouse-VBL IRQ load | `make check-syscall`'s full budget with the mouse VBL enabled via the direct-PIA policy (sec 7.5), servicing real 6821-driven VBL interrupts throughout the entire ECHO loop | **PASS**: `IRQ=$050F` -- 1295 real mouse-VBL interrupts serviced during the loop's run, with the syscall loop still completing its full count (`SYS=$4E20`) -- both doors coexist under genuine hardware interrupt load, exactly as originally specified |
| (f) | BRK reaches the debugger trap, not syscall dispatch | full run (mouse VBL enabled, the delivered configuration) completes the ECHO loop, falls through to a genuine end-of-program `brk`, and `K_BRK_MARKER=$42` confirmed via direct `peek` -- no longer confounded by an unterminated loop overrunning into a stray opcode (sec 7.7's Bug A was the actual cause of that earlier ambiguity) | **PASS**, reproducible |

### 8.1 Honest account: two review rounds, five real bugs found and fixed, now genuinely green

Two rounds of architect desk review, each catching real bugs with
precise, reproducible findings, were needed to get here -- recorded
below because the path matters as much as the destination for anyone
building on this code.

**Round 1 (mouse policy, sec 7.5):** replaced all ROM mouse-firmware calls
(boot-time init AND the IRQ-path acknowledge) with direct 6821 PIA
programming, per the architect's ruling that the kernel never calls
firmware from the IRQ path. In verifying this, found and fixed a
zero-page/`ALTZP`-cross-flip bug affecting `K_CALLER_SP`, `K_CALLNUM`,
`K_PARMLO`, `K_PARMHI`, `K_ISBRK` -- cells written under one `ALTZP`
state and read under the other land in two physically different bytes.
Fixed by moving all five to ordinary (non-zero-page) main memory. Also
fixed, same pass: a dispatch off-by-one (call# 0 not rejected), the
`STAMP_BANK1` routine using `RAMWRTAUX`/`RAMWRTMAIN` instead of
`ALTZPAUX`/`ALTZPMAIN` for LC space, and `ENTER_FAKEPROC_STUB`'s page-1
relocation running before the `ALTZP` flip instead of after.

**Round 2 (the ECHO hang, sec 5.1 and sec 7.7):** the architect's desk review
identified, from code inspection alone, that `COPYIN_LC_SRC`'s loop
terminator (`cpy K_CPY_COUNT`) was an absolute read of kernel state
INSIDE a `RAMRD=aux` bracket -- steered to the process bank instead of
the kernel's own counter, overrunning the copy into adjacent kernel
globals and corrupting the test's own loop control. Fixed per the
architect's preferred fix: hoist the count into `X` before the flip,
loop with `INY`/`DEX`/`BNE`, zero memory reads of kernel state inside
either bracket (sec 5.1 -- now a named, deposit-grade discipline). The same
review also caught a second, distinct bug: the LC range check fell
through for addresses `>= $D0`, silently "copying" main-bank LC
(the routine's own code) as process memory; fixed with a distinct
error code (`K_CPY_ERR=2`) so callers can tell "forbidden forever"
($C0-$CF) from "not wired yet" (`$D0+`, until the `ALTZP`-aware LC path
exists).

Applying Round 2's fix alone did not resolve the ECHO test -- it fixed
a real bug, but not the only one. Chasing the residual failure surfaced
three more, all previously undetected because every prior check
verified only the CALLEE side (did dispatch reach the handler, did the
handler compute the right value) and never the CALLER side (did life
resume correctly after `RTI`) -- exactly the gap a loop that does real
work in the caller after each syscall was bound to expose:

1. **`cmp K_DISPATCH_COUNT` was missing its `#`.** merlin32 assembled
   this as an absolute read of address `$0003` (always 0), not an
   immediate compare -- every call number failed the bounds check and
   fell through to `ERR_NOSYS`, meaning no syscall of any kind had ever
   reached its real handler in ANY prior round of testing. Earlier
   claims that `TESTCALL_ARITH` "worked" were based only on observing
   `KERNEL_EXIT` reached quickly, never on verifying the handler
   actually ran.
2. **The trapframe's required `PC += 1` patch (sec 1, sec 7.7 Bug A) was
   never implemented.** `JSR $FF00` pushes `return_addr - 1`; `RTI`
   (used for both doors, the whole point of the shared frame) does not
   auto-increment the way `RTS` does. Every syscall return landed one
   byte inside its own `JSR $FF00` operand. Fixed by patching
   `FRAME_PCL`/`FRAME_PCH` by +1 in `KERNEL_ENTRY` (syscall door only --
   the IRQ door's hardware-pushed address is already correct).
3. **`KERNEL_EXIT` read `K_RESULT`/`K_RESULT_ERR` (zero page) AFTER its
   own `ALTZP=aux` flip** (sec 7.7 Bug B) -- the same cross-flip bug class
   as Round 1's, a third occurrence in the same file. Fixed by caching
   both into `A`/`Y` before the flip.

With all five fixes in place, a clean run with the mouse VBL genuinely
ENABLED (the delivered configuration, not an isolation config) produces
`SYS=$4E20 IRQ=$050F` / `ARITH D0=$7E7E38` / `K_BRK_MARKER=$42` -- every
item in the table above now PASSES under the real, delivered
configuration. `make check-syscall` exits 0. See the final report for
the pasted gate output.

### 8.2 Backend

**FAST backend only** (per HACKING.md's "fast proves behavior, never
hardware fidelity"). `rtl` was not attempted for this specific gate -- at
~14x slower step-unit cost and this test's already-large cycle budgets,
it was not attempted within this task's time budget. `check-boot`,
`check-memmap`, `check-probe`, and `check-userland` (pre-existing gates
this task must not break) were re-run from a clean build and pass -- see
the final report for pasted output, including `check-boot`'s own rtl
pass (unaffected by this task's changes).

---

## 9. Deposit candidates (not deposited -- task rule: report, don't deposit)

- **The RAMRD/RAMWRT kernel-data-read corollary (sec 5.1), architect-
  requested deposit.** Inside a `RAMRD=aux` or `RAMWRT=aux` bracket,
  kernel data reads must be limited to registers and zero page
  (`ALTZP`-governed) -- any absolute read of `$0200-$BFFF` kernel state
  silently redirects to the process bank instead. The commons' existing
  RAMRD learning (`learning:01KW1GTYGVYAPQRGS5P7J66RWD`) covers
  instruction FETCH; this is the DATA-read corollary, a distinct and
  independently-costly mistake (it caused this task's ECHO round trip
  to overrun its own kernel globals -- sec 5.1, sec 7.7) that is not obviously
  implied by the fetch rule alone. Found three separate times in one
  file during this task (`COPYIN_LC_SRC`'s loop bound, and -- the
  ALTZP-governed sibling of the same mistake -- `KERNEL_EXIT`'s
  `K_RESULT`/`K_RESULT_ERR` read after the flip, twice independently).
  Candidate title: "RAMRD/RAMWRT govern ALL data reads in $0200-$BFFF,
  not just instruction fetch -- kernel code must cache state into
  registers or ZP before flipping either switch."
- **verilogapple's `peek`/`poke` `bank` parameter is `"aux"`, not
  `"ramworks"`** -- passing `"ramworks"` is silently accepted (no error)
  and does not read the requested aux bank (confirmed by cross-checking
  against `mcp_server.cpp`'s own tool schema, which documents `bank` as
  one of `'main'|'aux'|'rom1'|'rom2'|'romv'`). This task passed
  `"ramworks"` for a substantial portion of its own debugging before
  catching the mistake, and the resulting false "the write never
  landed anywhere" readings directly cost significant time chasing a
  phantom bug. Worth a deposit specifically warning that this parameter
  name doesn't fail loudly -- a strong candidate for the commons given
  how easy the mistake is to make (the tool's OWN default `aux_banks`
  card is literally named "ramworks" in `reset`'s parameters) and how
  silent the failure is.
- **AppleMouse `ServeMouse`/`InitMouse`/`SetMouse` appear to enable
  interrupts internally** -- unsafe to call from any context sharing a
  fixed-SP-reset kernel stack (IRQ path OR boot-time init before the
  scheduler runs), which is why this task's final policy (sec 7.5) never
  calls mouse firmware from the kernel at all, using direct 6821 PIA
  programming for both init and IRQ-time acknowledge instead. Observed
  via direct emulator inspection, reproducible, and directly relevant to
  any future maux task (or outside project) building an interrupt-driven
  scheduler against verilogapple's AppleMouse model. Candidate title:
  "AppleMouse ROM entry points appear to CLI internally -- unsafe to call
  from a fixed-SP-reset kernel stack in any context, not just IRQ."
- **The Language Card write-enable double-read protocol** (`LDA` the
  same `$C08x` switch twice to get RAM-read+write, once for read-only) --
  confirmed via the ProDOS TRM's `BNKBYT1`/`BNKBYT2` listing during this
  task, and a real, easy-to-get-wrong hazard (this task's own
  `STAMP_BANK1` got the adjacent switch discipline wrong on first draft,
  sec 8.1). Worth a dedicated learning if the commons doesn't already have
  one specifically about the double-vs-single-access distinction (a
  search for this during the task surfaced only the TRM artifact
  snippet itself, not a synthesized learning).
- **merlin32 silently compiles a missing `#` as an absolute-address
  read, not an immediate compare.** `cmp K_DISPATCH_COUNT` (intended:
  compare A against the small literal `K_DISPATCH_COUNT equ 3`)
  assembled as a read of memory address `$0003` instead, because
  merlin32 does not distinguish "symbol defined via `equ` to a small
  literal" from "symbol naming a zero-page location" at the call site --
  only the `#` sigil does. This silently broke ALL syscall dispatch in
  this task for its entire first two rounds of testing (every call
  number failed the bounds check and fell through to `ERR_NOSYS`), and
  was masked because downstream checks only verified `KERNEL_EXIT` was
  reached quickly, not that the intended handler had actually run.
  Candidate title: "merlin32 (and likely other 6502 assemblers):
  omitting `#` on a `cmp`/`lda`/etc against an `equ`'d small-integer
  constant compiles silently as a memory read of that address, not an
  immediate compare -- no assembler warning."
- **A shared-RTI trapframe design requires an explicit `PC += 1` patch
  on the syscall/JSR door, easy to omit entirely.** `JSR` pushes
  `return_addr - 1` (per 6502 convention, normally corrected by `RTS`'s
  own microcode); a kernel that returns via `RTI` from BOTH a `JSR`-
  based syscall door and a hardware-pushed IRQ door must patch the
  syscall door's stacked PC by +1 itself, since `RTI` does not
  auto-increment. This task's own `docs/ARCHITECTURE.md` stated the
  requirement in prose from the start, but the implementation omitted
  it for two full review rounds because every test that would have
  caught it checked only whether the callee finished, never whether the
  caller correctly resumed afterward (sec 7.7). Worth a deposit as a
  general design-pattern warning for anyone building a shared-frame
  syscall+IRQ entry point on 6502/65C02: "if your syscall door is a JSR
  and your exit is a shared RTI, verify a caller-side effect after every
  return, not just kernel-side completion -- the missing PC+1 patch is
  invisible to callee-only checks."

## 10. REFACTOR POINT: the device namespace, when a second introspection call appears

**Trigger: build the device namespace when it would UNIFY several consumers
of kernel state -- not merely when a second one appears.**

The distinction matters, and the first draft of this section got it wrong by
saying "a second call". Two bespoke calls of genuinely different shapes are
fine. The namespace earns its keep only when several things want the SAME
access pattern and composing with `grep`/`wc` actually buys something.

Be honest about what it costs, because the "everything is a file" argument is
the weakest one available here:

* `SYS_PSTAT` is a SIX-BYTE record in a header both sides include. The
  assembler checks it.
* `/DEV/PROC` replaces that with a text format the KERNEL owns and userland
  re-parses -- plus, on this hardware, decimal formatting in the kernel, a
  read position per open fd, and buffering, all in main memory where we are
  not rich.

That is more machinery producing a weaker guarantee. Unix itself is not an
argument against this reading: its file abstraction was a unification worth
real contortion, but where things did not fit it added `ioctl()` rather than
contorting further -- and V6 never treated processes as files at all. `/proc`
arrived from Plan 9 via the 8th edition, a decade later. V6's own answer to
"show me the process table" was `/dev/kmem`: a window onto kernel memory with
a struct layout as the contract, which is exactly the impure thing.

`SYS_PSTAT` is maux's `ioctl`-shaped admission that one table rendered one way
is not a filesystem. That is a fine thing to be.

### Why this is small: most of it already exists

* `FD_DEV_BASE = $80` (syscall.equ) already distinguishes a `PCB_FDTABLE`
  byte that names a CHARACTER DEVICE from one that indexes the OFT.
* `FD_TTY0..FD_TTY3` occupy `$80-$83`; `$84-$FF` is free.
* `PRC_READ` already dispatches on that range (`cmp #FD_DEV_BASE` /
  `cmp #FD_TTY3+1` -> `TTY_READ`).

maux therefore already has device objects behind file descriptors. The only
missing piece is NAMING: today a device reaches an fd table because the kernel
put it there at spawn, and there is no way to `open()` one.

### The change

1. A name -> handle table: `/DEV/PROC` -> `$84`, `/DEV/NULL` -> `$85`,
   `/DEV/TTY` -> `$80`.
2. A check in `PRC_OPEN` BEFORE it delegates to the MLI. A matched name binds
   the handle into the fd table and returns; an unmatched one falls through to
   ProDOS exactly as now.
3. Per-device read generators, hanging off the range check `PRC_READ` already
   performs.

Then `ps` becomes `cat /DEV/PROC`, `SYS_PSTAT` is deleted, its dispatch-table
entry comes back out of six images, and introspection stops costing syscall
numbers forever after.

### Two decisions to make deliberately, not discover

**Namespace shadowing.** `/DEV/` is indistinguishable from a ProDOS volume
named DEV. Checking devices first means shadowing a real volume of that name.
Unix has exactly this property with mount points, so taking it is defensible
-- but it should be a ruling, not an accident.

**Text or binary.** Serving formatted text from `/DEV/PROC` makes `cat` work
and deletes `ps` outright; serving fixed-size records keeps `ps` as the
formatter and stays cheap to parse. V6 would have done binary; `/proc` did
text and the parsing was regretted for decades. Fixed-COLUMN text is the
compromise worth trying first, because `grep` and `wc` then compose with it --
which is the whole argument for having a namespace rather than a syscall.

### Cost of waiting

Retiring `SYS_PSTAT` is cheap while it has one caller. It gets steadily less
cheap; that is the reason this is written down now rather than discovered
later.

### PSTAT modes (PS-ARGS, 2026-10-20)

`ps` gained a COMMAND column without a second call number: the slot byte
(parm 0, 0-47) now also carries a MODE in bits 6-7. Mode 0 is the old call,
byte for byte (sh's job control never sets a mode bit). The other modes move
bytes only the kernel can reach and give them no meaning:

| slot byte | answer in the caller's buffer |
|---|---|
| `slot` | the 6-byte head record, as before |
| `slot or $40` | `PSTAT_BLK` (320) raw bytes of that process's `$0200-$033F`: its argv block as spawn staged it (ruling 13) |
| `slot or $80` | `PSTAT_PTH` (65) bytes: the lazy-free tag for its bank (length byte + canonical pathname); ERR_INVAL when the bank carries no tag |

Modes 1 and 2 refuse an unused slot (ERR_INVAL). Constants:
`PSTAT_M_BLK`, `PSTAT_M_PTH`, `PSTAT_BLK`, `PSTAT_PTH` in `inc/sc.status.equ`.
Validating, joining, truncating and the `(name)` / `?` fallback are `ps`'s
(src/bin/ps.s). The kernel image has no room for a validator (768 B ratchet),
and an old caller must not pay a 320-byte copy or a 70-byte buffer per call.
This is still one call with one caller, so the device-file plan above is
unchanged; it is the same ioctl-shaped admission, with a selector.

`SYS_PSTAT` ($06, added 2026-08-16 for `ps`) is the first call of that shape.
One instance is not a pattern and a bespoke call was the cheap right answer.
A second one is the signal, because the underlying constraint is permanent:

> A maux process sees one bank. Kernel structures live in the annex, outside
> every process's address space, so ANY read of them crosses a bank boundary
> and therefore needs the kernel. V6's answer -- open `/dev/kmem`, find the
> symbol with `nlist()`, read the struct -- is not available to us at all.

So every future `w`/`pstat`/`vmstat`/`lsof`-shaped tool wants the same thing
`ps` wanted, and each would otherwise cost a syscall number, a handler, and an
edit to every image's dispatch table (six of nine, today).

Slot bytes in the old ERR_INVAL range changed meaning, deliberately: `$40-$6F`
are mode 1 and `$80-$AF` mode 2 (slot in the low six bits; PCB_COUNT is 48, so
`$30-$3F` / `$70-$7F` / `$B0-$BF` are still ERR_INVAL), and `$C0-$FF` (mode 3)
is treated like mode 2 -- it returns the tag too -- because the kernel decodes
only "mode bits nonzero, bit 6 clear". Nothing may rely on mode 3. The mask
`and #$3F` in `PRC_PSTAT` (src/kernel/procfile4.s) is guarded at assembly time
by `err PCB_COUNT/$41`, so a PCB_COUNT above `$40` stops the build.

**Ruling (architect, 2026-10-20).** A moded PSTAT stays ONE call and ONE record
family, for one tool (`ps`). The NEXT introspection need, of any shape, triggers
the device-file design described above in this section -- not a further mode.

## ARG_MAX is bytes, not a count (raised AND fixed 2026-08-17)

**Full write-up, the audit of every other count-shaped limit, and what
the implementation actually cost: docs/LIMITS.md. That is the
authoritative version of this section.**

**RESOLVED -- this is an amendment to ruling 13, not a new ruling.** Ruling
13's shape is untouched: the parent still hands `spawn()` an ordinary
NULL-terminated array of pointers to its own strings, and the kernel still
re-packs the string bytes and recomputes the pointers. What changed is the
LIMIT and the FAILURE MODE:

- `ARGV_MAX_CNT = 16` is gone. `ARG_MAX` (1280 bytes of packed strings)
  and `ARGV_PTR_LIM` (255 bytes of pointer array -> 127 entries) are
  derived from `PRC_ARGV_STR`, `PRC_ARGV_PTRS` and `LOAD_BASE` in
  `inc/memmap.equ`, so both move with the map.
- **`spawn()` now FAILS with `ERR_2BIG` ($E7) instead of truncating.** A
  caller that exceeds either ceiling gets carry set and that code; the
  child's bank is freed and no process is created. Callers that used to
  receive a silently short argv now receive an error they can report.
- The per-argument 64-byte cap is gone; a single argument may use the
  whole remaining budget.
- Gate: `make check-argv`, whose load-bearing case is "one byte past the
  ceiling must ERROR". Teeth verified against the pre-fix kernel.

The rest of this section is the original problem statement, kept because
it is the argument for the change.

`ARGV_MAX_CNT = 16` caps argv by ENTRY COUNT. That is the wrong unit and
it is now reachable.

**Why the unit is wrong.** The resource being protected is the 1536-byte
`PRC_LOWFREE` window in the child's bank: `PRC_ARGV_HDR` ($0200) holds
argc, `PRC_ARGV_PTRS` ($0201) the pointer array, `PRC_ARGV_STR` ($0300)
the packed strings. `memmap.equ` derives the count from that budget --
16 entries x `PRC_ARGBUF`'s 64-byte per-arg cap = 1024 bytes of strings.
So the byte budget is the real constraint and the count is a proxy for
it, one that is wrong in both directions:

- **over-constrains:** `echo *` matching 20 short filenames is ~200
  bytes and fits with room to spare, but is refused for having 20
  entries;
- **under-constrains:** 16 entries of 64 bytes is 1024 bytes, the
  actual ceiling, reached at a quarter of the entry count.

**Why it is now reachable.** `memmap.equ` justified the cap as "generous
for a v1 shell with no globbing". sh globs as of today, so that premise
is gone. Worse, the two layers disagree about what to do: **sh errors
the line, the kernel silently truncates** (`PSTG_ARGV` simply stops
staging). A silently short argv is the `rm *` failure mode this project
already rejected one layer up.

**Shape of the fix.**

1. Replace `ARGV_MAX_CNT` with a byte budget, checked in `PSTG_ARGV` as
   strings are packed; the entry count falls out of it rather than being
   declared.
2. **Fail, do not truncate.** Return an error the caller can report --
   the E2BIG role. Truncation must stop being reachable at any layer.
3. Size the budget from the memory map rather than a literal. maux has
   no "% of stack" to borrow from -- each process owns a whole bank --
   so the natural anchor is the break: argv lives above it, bounded by
   `PRC_HEAP_TOP` ($BEFF), so the budget is a property of the layout
   instead of a constant that drifts from it.
4. sh's `MAXARGV` then stops being an independent limit and becomes a
   local buffer size; the authoritative check is the kernel's.

Blast radius: `inc/memmap.equ`, `PSTG_ARGV` in `src/kernel/process.s`,
`inc/startup.equ`'s `ARGC`/`ARGV` layout note, and sh's `MAXARGV`
(now a genuine free parameter -- see `STGOFF`). It is an ABI change in
the sense of docs/SYSCALL.md ruling 13, so it wants its own gate: a
spawn at the byte ceiling, and one past it that must ERROR rather than
arrive short.

## Item 13c -- the environment: it shares argv's block, Unix-style

**RULED 2026-08-22.** A second amendment to ruling 13, for the same
reason 13a and 13b were: the environment is staged by the same
mechanism as argv, so it belongs in the same ruling rather than a new
one.

### There is no environment at all today

Confirmed by search, not assumed: no `ENV`, `ENVIRON` or `getenv`
exists in `inc/`, `src/liba/` or `src/kernel/`. `sh` has no
`export`, and `PATHTAB` is a hardcoded two-entry table
(`/BASIC/BIN/`, then `/BASIC/`). This is the operator's own
"environment gap", and it is the last unblocked Bourne item.

### The layout

`$0200-$07FF` is already the argv block and there is nowhere else to
put an environment: `$0800` is the image, and the heap
(`PCB_BRK`, item 13b / `STICKY.md` sec 23) does not exist until the
program declares it, which is after the kernel has to stage.

So **argv and envp share the block, exactly as they share the stack
region on a Unix**:

```
$0200  argc                     1 byte
$0201  argv pointer array       argc*2
       envc                     1 byte
       envp pointer array       envc*2
$0300  packed NUL-terminated strings -- argv's THEN envp's
```

`ARG_MAX` (1,280 B) becomes a **combined** budget for both string
blocks, and `ARGV_PTR_LIM` (255 B) a combined budget for both pointer
arrays. `spawn()` already returns `ERR_2BIG` rather than staging a
prefix, and that contract extends unchanged to the pair -- **a program
that started at all can still trust that its argv AND its environment
are complete.** That guarantee is the reason the limit is checked in
the kernel rather than in `sh`.

### What inherits

Bourne's rule, unmodified: a child inherits **only exported**
variables. `sh`'s existing variable table (`MAXVARS = 8`) gains an
exported bit per slot; `export NAME` sets it; spawn stages exactly the
set bits. An unexported shell variable never reaches a child, which is
what makes `VAR=x` usable as a scratch local.

### `PATH` replaces `PATHTAB`, but does not delete it

`PATHTAB` becomes the **default when `PATH` is unset**, not dead code.
A shell that cannot find `ECHO` because the environment was clobbered
is unusable, and the machine has no other recovery path. Same
reasoning as `ANACHRONISMS`'s test 1: the old constraint (no
environment) is gone, but the fallback it justified is still cheap
insurance.

### Deliberately NOT in this ruling

- **`env` as a command** -- trivial once `getenv` exists, but it is a
  binary, and the fleet is not what is missing.
- **`unset`** -- needs the exported bit and a table-compaction rule;
  ship `export` first and see whether it is wanted.
- **Environment growth across `fork()`** -- a forked child shares the
  parent's block by construction, so this only becomes a question when
  a child modifies its own environment. Not yet.

### NOTE 2026-08-25 -- what an environment actually costs, and an idea for making spawn stop paying it

Raised by the operator as "adding envp means extending the size of every
process image by at least a page". **Worth pinning precisely, because
the cost is real but it is not image size.**

`PRC_LOWFREE` (`$0200`, 1536 B) is part of the FIXED bank layout -- every
process bank has it whether or not anything is staged there, and argv and
envp share it (the layout above). So an environment costs **no new
memory**. What it costs is:

1. **Shared budget.** `ARG_MAX` (1,280 B) spans argv's strings AND
   envp's; `ARGV_PTR_LIM` (255 B) spans both pointer arrays. A large
   `PATH` -- and the operator is right that `PATH` is usually the big one
   -- is subtracted from what argv may use, and the pair overflowing is
   `ERR_2BIG`, refused whole. Today `PATHTAB` is 21 B and `SH_PSRCSZ` is
   96, so this is comfortable; it stops being comfortable the day the
   tree grows a hierarchical layout and `PATH` grows with it
   (`docs/FLEET.md`'s "settable path" step 1).
2. **Time, on EVERY spawn.** The kernel copies the strings into the
   child's bank at the measured **39.07 cyc/byte** (`docs/PROCIO.md`).
   A 256-byte environment is ~10,000 cycles -- about **10 ms at 1 MHz**,
   paid per spawn, warm or cold. Lazy free's 8.1x warm win comes from
   skipping the ~14 KB IMAGE load; it does not skip staging, because
   argv legitimately differs on every spawn.

So the environment is a per-spawn TIME cost that scales with how much of
it there is, in a system whose whole spawn story is "do not copy what you
do not have to".

**The operator's idea, recorded: let a retained bank keep the environment
it already has.** The environment, unlike argv, is usually IDENTICAL
across sibling spawns from the same shell -- a loop spawning the same
command 100 times re-copies the same bytes 100 times. If the kernel could
tell that a lazily-retained bank already holds the right environment, it
could stage argv alone and skip the envp copy entirely.

A hash makes that test cheap -- Pearson was suggested and is a good fit
for a 6502: one table lookup and an XOR per byte, no multiply, 256-byte
table.

**But an 8-bit Pearson hash alone is not safe here, and the reason is
this project's own standing rule.** A 1-in-256 collision does not
produce a loud failure; it hands a child a DIFFERENT environment that
looks fine -- a silent wrong answer, which is the outcome this tree
refuses everywhere else. Three ways to keep the win and lose the risk,
cheapest first:

* **Generation counter, exact.** Tag the retained bank with
  `(staging_pid, env_generation)`; bump the generation whenever a
  process's environment is rewritten. Equal tag means the bytes are
  equal BY CONSTRUCTION -- no hashing, no collision, one 16-bit compare.
  Needs the pid because two different parents may spawn into the same
  retained bank.
* **Hash as a fast REJECT, then verify.** Differing hashes mean
  definitely-different, so re-stage. Matching hashes trigger a byte
  compare to confirm. The compare is a read-only pass with no
  bank-WRITE traffic, so it is materially cheaper than the copy it
  avoids, and the result is exact.
* **Widen the hash.** Pearson extends to 2-4 bytes by re-running with
  different table seeds -- still probabilistic, but 1-in-4-billion rather
  than 1-in-256. Cheapest to implement, and the only one of the three
  that can still be wrong.

**Recommendation if this is ever built: the generation counter.** It is
exact, it is the least code, and it does not need a hash at all -- the
hash is only attractive if the environment can change without the
kernel noticing, which it cannot, since the kernel is the only thing
that ever stages one.

Not scheduled. Recorded because the measurement (10 ms per spawn per
256 B) is the kind of number that decides a design later, and because
the safety caveat is easier to write down now than to rediscover.

### The gate that matters

Not "does `export` set a bit". It is: **an exported variable reaches a
spawned child's `getenv`, and an unexported one does not.** Both
halves, in one gate -- the second is the one a partial implementation
passes.

And, because `ARG_MAX` is now shared: **a spawn whose argv and
environment together exceed the budget must return `ERR_2BIG`, not
stage a prefix.** `learning:01M07V2D0T25FYD6ASCMPJYNWQ` is the
precedent -- a count-shaped cap that truncated silently one layer below
where anyone looked, and the gate that caught it had to construct the
overflow deliberately.

### LANDED 2026-08-22 -- where each half lives

- **The layout** is staged by `PSTG_ARGV`/`PSTG_LIST`/`PSTG_ENV`
  (`src/kernel/procspawn.s`, `procspawn2.s`). One `PRC_ARGOFF`
  accumulator spans both string blocks and one `PRC_PTROFF` spans both
  pointer arrays, which is what makes `ARG_MAX` and `ARGV_PTR_LIM`
  *shared* rather than doubled. `envc` is reserved before the
  environment is walked (`PRC_ENVCOFF`) and written back once its value
  is known -- so a full 127-entry argv still fits, with `envc` landing
  in the one pointer-array byte that argv could never use.
- **`spawn()`'s parmlist grew 6 -> 8 bytes**: path, argv, fdactions,
  envp. A NULL envp means "no environment", which is what every caller
  that predates this ruling passes -- and every raw-spawn harness in
  `src/test` was updated to say so explicitly rather than to inherit
  whatever byte was in memory.
- **`sh`** gains `VAREXP` (one byte per variable slot, `ds` beside
  `VARNAMES` because it must start clear), `CHCK_BLTN_EXP`, and
  `ENV_STAGE`, which rebuilds the envp array before every spawn.
- **`getenv`** is `src/liba/env.s` -- its own module, since a liba
  module is linked whole and almost nothing needs it. State
  (`GENV_CNT`/`GENV_OFF`) is in `libabss.s`'s uncleared half: both are
  written before they are read, so neither belongs in the kernel's
  zeroed page.
- **`PATH`** is read by `PATH_SRC` (`src/bin/sh.s`) into `SH_PATHSRC`,
  which `BUILD_PATH` walks. `PATHTAB` is copied there verbatim when no
  `PATH` variable exists.
- **Gates**: `make check-env` (the inheritance pair, both halves in one
  `ENVOUT`) and `make check-argv` cases 7-9 (the shared budget: exactly
  `ARG_MAX` across the pair, then one byte past it *in the
  environment*, which a two-budget implementation waves through).

---

## Item 14 -- `GET_PREFIX` is maux semantics now, not a ProDOS pass-through

**RULING, 2026-08-27.** `SYS_GETPFX` keeps its real MLI number and its
place in `inc/sc.file.equ`, but it **no longer always reaches
ProDOS**. When the calling process has a recorded working directory,
`PRC_GETPFX` answers from that instead. This is a deliberate exception
to `sc.file.equ`'s own house rule -- *"REAL MLI call numbers
verbatim... Every one of these routes through `P8_DELEGATE`, never a
maux-invented number"* -- and it is the first one, so it is written down
rather than discovered.

### What forced it

ProDOS keeps **one machine-wide prefix**. `src/kernel/procfile.s` had
recorded the consequence for a long time: *"a real gap for a second
interactive shell, accepted while there is only ever one (sh)."* `( )`
grouping and `$( )` both spawn a nested `sh`, so that condition
expired -- `( cd X ; ... )` moved the CALLER's directory, which is the
single most canonical use of the construct.

Per-process cwd needs three things to agree, and they are in three
different layers:

| layer | who resolves | what it reads |
|---|---|---|
| kernel, delegated file calls | `PRC_ABSPATH` | the per-pid table |
| userland, `.` and `..` | liba `MKPATH`, in **29 programs** | `GET_PREFIX` |
| userland, "where am I" | `pwd` | `GET_PREFIX` |

Pinning ProDOS's prefix to boot (`PRC_PIN_BOOT`) is what stops the
leak, but on its own it would send every dot-path in those 29 programs
to the boot volume. **`GET_PREFIX` is the only join point** where a
per-process answer reaches userland without touching 29 binaries. So
the syscall boundary is where machine-wide becomes per-process.

### Why this is not drift

`getcwd` is per-process in every Unix. The rule this bends exists so
that maux does not *invent* file-call numbers or quietly change what
an MLI call MEANS to ProDOS -- and neither happens here: the number is
real, the parmlist shape is unchanged, and ProDOS's own prefix is
still what a process with no recorded cwd gets. What changed is *whose*
working directory the kernel reports, which was already maux's
question to answer, not ProDOS's. See `docs/CD.md` for the
implementation record and the measurement that reopened it.

### The exception's fence

This applies to **`GET_PREFIX` only**. `SET_PREFIX` still delegates and
still validates the target directory (that validation is why `cd` calls
it at all). No other file call reads or writes the cwd table, and a
second such exception should be argued on its own merits rather than
by pointing at this one -- the same discipline `SYS_PSTAT` set for
process calls in section 10.
