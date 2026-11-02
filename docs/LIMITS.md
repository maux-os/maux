# Resource limits: count the bytes, not the things

**Status: RULED AND IMPLEMENTED for argv, 2026-08-17 (raised the same
day). `ARG_MAX` is now a byte budget derived from the memory map, spawn
fails instead of truncating, and `make check-argv` holds it. The
remaining count-shaped limits are audited in the table below -- three are
now derived, the rest are correct as counts. See "What was actually
built" for the implementation and what it cost.**

## The ruling being asked for

**A limit should be expressed in the unit of the resource it protects.**
maux's limits are almost all expressed as *counts of things*, while the
resource in every case is *bytes of a fixed region*. A count is a proxy,
and a proxy is wrong in both directions at once:

- it **over-constrains** the common case -- twenty short filenames are
  about 200 bytes and fit with room to spare, yet are refused for being
  twenty;
- it **under-constrains** the worst case -- sixteen arguments at the
  64-byte per-argument cap is 1024 bytes, the real ceiling, reached at a
  quarter of the entry count.

So the count is simultaneously too small for the traffic that actually
occurs and too large for the traffic that would hurt.

## The worked example: `ARGV_MAX_CNT`

`ARGV_MAX_CNT = 16` (`inc/memmap.equ`) caps argv by entry count. Read
its own comment: the 16 is *derived* from a byte budget -- 16 entries x
`PRC_ARGBUF`'s 64-byte per-arg cap = 1024 bytes of packed strings, inside
`PRC_LOWFREE`'s 1536-byte window. **The byte budget was always the real
constraint.** The count is a number someone computed from it once, and
which has since been treated as the limit itself.

The child's layout it protects:

```
$0200  PRC_ARGV_HDR    argc
$0201  PRC_ARGV_PTRS   pointer array
$0300  PRC_ARGV_STR    packed strings
       ...             within PRC_LOWFREE, 1536 bytes total
```

### Two things went wrong on 2026-08-17, and they are the argument

**1. The premise expired without anyone noticing.** The comment justifies
16 as *"generous for a v1 shell with no globbing"*. sh gained globbing
that afternoon. Nothing flagged it; the justification simply became
false while the constant stayed.

**2. The layers disagree about failure.** The same comment says excess
entries are *"silently TRUNCATED (extra entries never staged) rather
than rejected"*. sh, written later, **errors the line** instead. So
today: sh refuses to run a too-large command, but any other caller that
reaches `PSTG_ARGV` directly gets a **silently short argv**.

That second one matters beyond argv. A short argv is `rm *` deleting
some of what you asked for -- the exact hazard sh was written to avoid.
It was not eliminated, it was pushed one layer down where nothing looks
at it. **Silent truncation must not be reachable at any layer.**

## Shape of the fix

1. Replace `ARGV_MAX_CNT` with a **byte budget**, checked in `PSTG_ARGV`
   as strings are packed. The entry count falls out of it rather than
   being declared.
2. **Fail, never truncate.** Return an error the caller can report -- the
   `E2BIG` role.
3. **Anchor the budget to the memory map, not a literal.** maux has no
   "percentage of the stack" to borrow: each process owns a whole 64K
   bank. The natural anchor is the program break, with `PRC_HEAP_TOP`
   ($BEFF) as the ceiling, so the budget is a property of the layout and
   cannot drift away from it the way a constant does.
4. sh's `MAXARGV` stops being an independent limit and becomes a local
   buffer size. The kernel holds the authoritative check.

Blast radius: `inc/memmap.equ`, `PSTG_ARGV` in `src/kernel/process.s`,
`inc/startup.equ`'s `ARGC`/`ARGV` layout, `src/bin/sh.s`. This is an
ABI change in the sense of `docs/SYSCALL.md` ruling 13.

**It needs its own gate**, and the second case is the whole point:

- a spawn whose argv sits exactly at the byte ceiling -- must arrive whole;
- a spawn one byte past it -- must **ERROR**, not arrive short.

A gate that only tests the first passes by accident on truncating code.

## What was actually built (2026-08-17, same day)

Implemented as specified above, with one correction to item 3 and two
findings the work turned up.

**Item 3's anchor was wrong, and the right one is better.** The break is
not where argv lives -- argv sits in `PRC_LOWFREE` at `$0200-$07FF`, well
*below* `LOAD_BASE`, so `PRC_HEAP_TOP` has nothing to do with it. The
honest anchor is the argv block's own two neighbours in the map, and
both ceilings now fall out of addresses rather than being chosen
(`inc/memmap.equ`):

| symbol | derivation | value | what it bounds |
|---|---|---:|---|
| `ARG_MAX` | `LOAD_BASE-PRC_ARGV_STR` | 1280 | bytes of packed strings, NULs included |
| `ARGV_PTR_LIM` | `PRC_ARGV_STR-PRC_ARGV_PTRS` | 255 | bytes of pointer array -> **127 entries**, the count that used to be declared |

Move any of `PRC_ARGV_HDR` / `PRC_ARGV_PTRS` / `PRC_ARGV_STR` /
`LOAD_BASE` and both budgets follow. Those three addresses also stopped
being declared twice: they were in `src/kernel/process.s` *and* derived
separately in `inc/startup.equ`, which is the mechanism by which two
layers came to disagree in the first place. They live in `memmap.equ`
now, and both sides derive from them.

`ERR_2BIG` ($E7, `inc/errno.equ`) is the E2BIG role. `PRC_SPAWN`
frees the child's bank and returns it; sh decodes this one code and says
"too many arguments" instead of "command not found".

**The per-arg cap went with it.** `PRC_ARGBUF`'s 64 bytes were not merely
double-counting the same resource, as the audit table suspected -- they
were silently cutting every argument at **63** characters, so a maximal
64-character ProDOS path (`MLI_PTH_MAXLN`, the MLI's own limit) arrived
one character short. There is now no per-argument cap at all: an argument
may be as long as the remaining budget, and the budget is the only thing
that says no.

**Strings are now copied by `BankCopy`, and that turned out to be
load-bearing rather than tidy.** Raising the ceiling to 1280 bytes pushes
the string region past `$03FF` for the first time -- and with 80STORE set,
RAMRD/RAMWRT are *ignored* for `$0400-$07FF`, where PAGE2 alone routes
the access (`learning:01KW1GTYHGXMBZNR6DMQB2F712`). `PSTG_ONE_ARG`'s
hand-rolled `RAMWRTAUX` stores had no 80STORE bracket, so a long argv
would have landed in the motherboard text page instead of the child.
80STORE-off is the kernel's documented steady state, which is exactly
what would have made this a rare and mystifying failure rather than an
obvious one. The house primitive already brackets `CLR80STORE`; every
write into another bank on this path goes through it now, `ARGC` and the
pointer entries included.

**A pre-existing hole closed on the way past.** `PSTG_ARGV`'s
copyin-refusal path already returned with `K_RESULT_ERR` set -- and
`PRC_SPAWN` ignored it and ran `PRC_RET_OK_A`, which cleared it again. A
parent got a *successful* spawn whose child held a half-staged argv. The
truncation policy was hiding a second route to the same outcome.

### The gate: `make check-argv`

`src/test/argvtest.s` + `argvtestb.s` + `scripts/check_argv.py`. Seven
spawns of one argv-verifying child, which does not know any case's
numbers and checks *invariants* instead: every argument ends with a
sentinel byte (so nothing was truncated), and every `argv[i]` points
exactly where `argv[i-1]`'s string ended (so pointers and packed strings
agree). It exits with `argc`, or `$EE` on any violation.

| case | asserts |
|---|---|
| 3 short args | ordinary argv still works |
| one 100-byte arg | the old 63-byte per-arg cut is gone |
| 20 x 64B = **exactly `ARG_MAX`** | arrives **whole** |
| **`ARG_MAX` + 1 byte** | **`ERR_2BIG`** -- the case the whole page is about |
| 127 args | pointer array exactly full, only 254B of strings |
| 128 args | one pointer past -> `ERR_2BIG`, still far inside `ARG_MAX` |
| 3 short args again | no bank leaked by either failure |

"One byte past" is expressed as a trailing **empty** argument: it
contributes its single NUL and nothing else, so the case lands on
`ARG_MAX+1` exactly rather than overshooting comfortably -- an off-by-one
in the check is precisely what a coarse test would wave through.

**Teeth verified, not assumed.** Run against the pre-fix kernel, cases
1, 2, 4 fail and -- the point -- cases 3 and 5 come back as **successful
spawns reporting `argc` 16**: the silent truncation, reproduced live as
the `rm *` hazard this page described. Against the fixed kernel, all
seven pass.

One note for whoever writes the next such gate: the first draft put the
child's spawn path immediately above the string buffer, so case 4's
deliberate one-byte overrun wrote that byte onto the path, and every
later case spawned an empty path and returned `ERR_INVAL`. It reproduced
identically on the pre-fix kernel, which made it look like a kernel
finding. **A test whose overflow case overflows into the test's own
fixtures cannot report on anything** -- leave slack above any buffer whose
job is to be overfilled.

## The other count-shaped limits, for the same audit

Not all of these are wrong -- several count genuinely discrete resources
(PCB slots, pipes, open files) and are fine as counts. Listed so the
audit is explicit rather than assumed:

| limit | where | unit is right? |
|---|---|---|
| ~~`ARGV_MAX_CNT` 16~~ | memmap.equ | **FIXED** -- now `ARG_MAX` bytes + `ARGV_PTR_LIM`, both derived from the map |
| `MAXARGV` 32 | sh.s | **FIXED** -- a buffer size now, not a limit; the kernel holds the check. Raised 16->32 because 16 was only ever the kernel's old count. Its real ceiling (42, where `CMD_ARGV`'s 8-bit index runs out) is asserted with `err`, not commented |
| `MAXGLOB` | sh.s | **FIXED** -- now literally `MAXARGV-1`, so it cannot drift from it again |
| `MAXTOK` 64 | sh.s | **FIXED** -- derived from `LINEMAX` (a token costs >=2 bytes of line), with an `err` that fires if `LINEMAX` changes without it |
| ~~`PRC_ARGBUF` 64/arg~~ | process.s | **GONE** -- and it was worse than "double-counts": it cut every argument at 63 bytes, one short of a maximal ProDOS path |
| `PCB_COUNT` 48 | memmap.equ | yes -- process slots are discrete |
| `PIPE_COUNT` 8 | memmap.equ | yes -- discrete kernel objects |
| `OFT_COUNT` 16 | memmap.equ | yes -- discrete |
| `MLI_IOBUF_CNT` 8 | mm.mlibuf.equ | yes -- each is a fixed 1 KB buffer, and 8 is ProDOS 8's own open-file ceiling. No longer a hard limit on open files: the kernel LENDS buffers (docs/IOBUF-LENDING.md), so what binds past 8 is `OFT_COUNT` |
| `MAXCMD` 3 | sh.s | yes -- pipeline stages are discrete |
| `MLI_PTH_MAXLN` 64 | mli.equ | yes -- already bytes, and ProDOS's own |

The pattern to watch for: **a limit whose comment explains it by
multiplying it by a size.** That multiplication is the real budget, and
the constant is a stale cache of it.

## Why this is urgent rather than tidy

Every consumer written against a count makes the change more expensive,
and they are appearing quickly -- `MAXGLOB` was derived from `MAXARGV`
the same day `MAXARGV` was raised. The `ARGV_MAX_CNT` comment already
carried the words *"flagged here, not silently assumed sufficient
forever"*. It was, in fact, silently assumed sufficient, for exactly as
long as it took someone to add a feature the comment had named as the
thing that would break it.
