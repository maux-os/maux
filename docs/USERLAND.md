# maux userland: liba + the first five utils (task #10)

Status: **ABI RATIFIED.** Task #3 landed `docs/SYSCALL.md` (the `JSR $FF00`
gate, entry/exit trapframe, and 13 numbered ABI rulings) and a mid-flight
operator ruling made ProDOS 8 the v1 filesystem layer -- file syscalls
(open/read/write/close/creat/unlink) are now real ProDOS MLI calls,
verbatim parmlist shapes, forwarded through the kernel's `PRODOS_DELEGATE`
(wired for real by task #11, a separate spike). This document was
originally written DRAFT, against a syscall ABI that didn't exist yet; this
revision reconciles every liba/util decision against the ratified rulings
and records what changed. The canonical call numbers and error codes live
in `inc/syscall.equ` and `inc/errno.equ` -- liba `use`s them
directly rather than duplicating values.

The organizing principle is unchanged: **`src/liba/syscalls.s` (paired with
`inc/syscall.equ`) is the only file in the entire tree allowed to
mention the `$FF00` gate address or a raw call number.** Every other liba
module and every `src/bin/*.s` util goes through the `SC_*` wrapper
routines. `make check-userland` greps for violations and fails the build
if it finds one outside `src/liba`.

## liba conventions

### String encoding: HIGH-BIT-SET, NUL-terminated

Unchanged from this slice's original ruling, and unaffected by the ABI
rework -- every liba string is stored with bit 7 set on every character
byte, NUL ($00, bit 7 necessarily clear) as the terminator. Three
independent things agree on this, so it's the encoding that requires zero
runtime conversion at every boundary that existed before this round:

1. **merlin32's `asc "..."` literals already emit high-bit-set bytes**
   (`learning:01KW1GTYGZ9TE2ZGCDG0V2CNE0`, confirmed in this repo --
   `src/bootblock.s`'s `MSG asc "MAUX ALIVE"` writes straight to the text
   page with no `ora #$80` step).
2. **The Apple II text page's "normal" (uninverted, non-flashing)
   character encoding IS high-bit-set ASCII.**
3. **A polled keyboard read on the Apple II already returns high-bit-set
   bytes** (malisp precedent, `~/src/malisp/src/console.s`).

NUL-termination is *safe* under this scheme specifically because it's
impossible for $00 to appear as a real character.

**A fourth boundary, discovered THIS round, goes the other way:** ProDOS
MLI pathnames are 7-bit-clean and length-prefixed, NOT high-bit-set or
NUL-terminated (ProDOS 8 TRM ch. 2, "By the Way" note, fetched live this
round: *"On the Apple II, an ASCII character is read from the keyboard and
printed to the screen with its high bit set. ProDOS clears this high
bit."* -- confirmed directly in context, discussing filenames). Liba's own
convention is exactly backwards from what the MLI wants for the ONE place
liba strings cross into ProDOS: pathnames. `src/liba/mli.s`'s `MKPATH` is
the mandatory conversion -- strips the high bit per character and re-packs
as a 1-byte-count-prefixed buffer (TRM ch. 4's pathname-pointer shape) --
used by every file-call util (`cat`/`cp`/`rm`/`ls`) before every
OPEN/CREATE/DESTROY. This is the "explicit text-conversion helper for the
tty/MLI boundary" liba conventions call for (see "Line endings and text
encoding" below) -- not hypothetical, load-bearing from day one.

### Error convention (RATIFIED -- SYSCALL.md ruling 4)

V6-style: **carry clear = success; carry set = failure, A holds an error
code** -- but which TABLE that code belongs to now depends on the call
class, an ABI split that didn't exist in the original draft:

- **Process calls** (spawn/exit/wait/pipe/brk -- no MLI equivalent): a
  small maux-invented code in `inc/errno.equ`'s `$E0+` range
  (`ERR_NOMEM`/`ERR_INVAL`/`ERR_NOSYS`/`ERR_CHILD`/`ERR_AGAIN`/
  `ERR_PIPE`/`ERR_PRODOS_UNWIRED`).
- **File calls** (open/read/write/close/creat/unlink): the RAW ProDOS MLI
  error code, passed through verbatim (TRM ch. 4: roughly `$01-$05`
  system-level, `$40-$5A` file-level). liba does **not** re-enumerate that
  table -- it's ProDOS's own domain, and never needs updating as ProDOS
  evolves. A caller can tell which table applies with one comparison
  against `$DF`/`$E0`.

No v1 util currently DECODES a specific code either way -- every error path
just checks carry and prints a generic message (unchanged limitation from
the original draft; still true, now for a documented reason rather than an
open question -- see "still open" notes under resolution 4 below).

### Register preservation

Unchanged from the original draft -- 6502 doesn't have the register budget
for a universal restore-everything rule:

- **A is always clobbered / is the return value.**
- **X and Y are preserved UNLESS the routine's header lists them under
  CLOBBERS.**
- **PTR0/PTR1/PTR2 (zero page, `inc/zp.equ`) are documented inputs,
  never preserved outputs.** `MKPATH` adds a new wrinkle worth noting
  explicitly: it borrows `PTR2` as pure scratch (computing `PTR1+1` once)
  -- `PTR2` is NOT one of `MKPATH`'s real inputs, just spare zero page.

### Line endings and text encoding (RULING -- liba's own call)

`docs/SYSCALL.md` explicitly deferred these two questions back to liba/tty
scope ("items 14-15... tty/text-encoding scope, deferred to task #10...
nothing in this task's kernel-mechanics design constrains the answer
either way -- copyin/copyout move raw bytes, uninterpreted"). Ruling them
now, since nothing else will:

- **Line endings: CR (`$8D`, high-bit-set), the Apple II/ProDOS
  convention -- not LF.** Every liba/util text-producing routine already
  did this (it's what `docs/ARCHITECTURE.md`'s bootblock precedent and
  every util's `PUTC #$8D` call used from the start); this makes it an
  explicit, citable convention rather than an accident five files happen
  to agree on. Binding on liba and the utils; NOT binding on file
  *contents* -- see below.
- **liba converts NOTHING on `read()`.** File data crossing the
  `SC_READ`/`SC_WRITE` boundary is opaque bytes, verbatim, exactly as
  `copyin`/`copyout` already promise kernel-side. A file's on-disk bytes
  might be 7-bit ASCII, high-bit-set Apple II text, or arbitrary binary --
  `cat` does not inspect or convert any of it. This is the same posture
  real V6 `cat` and ProDOS's own `READ`/`WRITE` calls take (TRM ch. 4:
  transfers are raw byte counts, no character interpretation).
- **The ONE mandatory, non-optional conversion is the MLI pathname
  boundary** (`MKPATH`, above) -- a structural requirement of ProDOS
  pathnames being 7-bit, not a text-encoding POLICY liba is asserting.
  `MAKEHI`/`STRIPHI` (`src/liba/string.s`) remain liba's general-purpose
  boundary-conversion primitives for any OTHER place a future consumer
  needs one (`ls.s`'s directory-entry-name printing is the second
  concrete user, this round -- MLI directory entries are 7-bit too, same
  TRM citation, `MAKEHI`'d per character before `PUTC`).

## The syscall ABI (RATIFIED -- docs/SYSCALL.md)

**Transport (ruling 1, confirms this slice's original draft unchanged):**
call number in Y, pointer to a parameter block in A (low)/X (high), `JSR
$FF00`. No line needs a DRAFT-ABI tag any longer.

**Call numbers (ruling 2) -- canonical, `inc/syscall.equ`:** process
calls (`SYS_SPAWN`=1 .. `SYS_BRK`=5) are small sequential numbers with no
MLI equivalent; file calls (`SYS_CREAT`/`SYS_OPEN`/`SYS_READ`/
`SYS_WRITE`/`SYS_CLOSE`/`SYS_UNLINK`) are the REAL ProDOS MLI call numbers
($C0-$CC), because the kernel forwards them to a real MLI, not a maux
reimplementation -- matching numbers makes the eventual `$BF00` MLI-compat
overlay a near-passthrough instead of needing a translation table.

**2026-08-19 addendum:** the delegated set now also includes `SYS_RENAME`
($C2), `SYS_SETPFX`/`SYS_GETPFX` ($C6/$C7) -- wired since this list was
first written and simply never backfilled here -- and, this round,
`SYS_GFI` ($C4, MLI GET_FILE_INFO), the kernel's `PRC_FILECALL` dispatch
in `src/kernel/process.s`, and a new `SC_GFI` liba wrapper
(`src/liba/syscalls.s`) with a `PCOUNT_GFI`-shaped ($0A-param) static
parmlist convention in `inc/mli.equ`, following `SC_OPEN`'s bare-gate
shape exactly. See "Still missing for a full `ls -l`" below for what this
unblocks and what it doesn't (yet).

**Parameter-block shapes (ruling 3) -- the biggest liba rework this
round:**

- **Process calls** keep small, maux-invented, fixed shapes (unaffected
  by the ProDOS ruling) -- `src/liba/syscalls.s`'s `SC_SPAWN`/`SC_EXIT`/
  `SC_WAIT`/`SC_PIPE`/`SC_BRK` marshal friendly register/`PTR0-2` inputs
  into a shared `PROCPARM` scratch buffer, same spirit as the original
  draft.
- **File calls use the REAL MLI parmlist shapes, verbatim** (transcribed
  from the ProDOS 8 TRM ch. 4 into `inc/mli.equ`, fetched live this
  round -- not from memory). Lengths are **2 bytes** now (`request_count`/
  `trans_count`) -- the original draft's 255-byte 1-byte-length cap is
  GONE. Since the kernel is a byte-for-byte passthrough to the MLI, liba
  has nothing to marshal for these six calls: each util declares its OWN
  static parmlist instance (`dfb`/`da`, matching `mli.equ`'s shapes) and
  loads A/X with a pointer to it directly. `SC_OPEN`/`SC_READ`/
  `SC_WRITE`/`SC_CLOSE`/`SC_CREAT`/`SC_UNLINK` are now BARE gates -- three
  lines each (`ldy #SYS_x`, `jsr $FF00`, `rts`) -- with no marshalling
  code at all. `PUTC`/`PUTS` (`src/liba/print.s`) absorbed the WRITE
  parmlist internally, so their PUBLIC calling convention (`X`=fd,
  `A`=byte or `PTR0`=string) is **unchanged** from the original draft --
  every util call site that only ever used `PUTC`/`PUTS`/`GETARG` needed
  zero source changes.

**Two pointer fields, two different physical meanings (architect review,
merge-blocking finding this round -- the biggest correction in this
revision):** "verbatim MLI parmlist shapes" (ruling 3) means the SHAPES
-- byte offsets, field widths, field order. It does NOT mean every pointer
field in those shapes is a process-bank address just because the MLI
struct defines it as a pointer. Two fields sit side by side in these
parmlists with opposite semantics, and this round's first draft got one
of them wrong:

| field | which calls | meaning | who owns the buffer |
|---|---|---|---|
| `data_buffer` | READ, WRITE | the bytes actually being transferred | the **process** -- an ordinary process-bank address; the kernel `copyin`/`copyout`s through it via bankcopy, the same mechanism every other syscall argument already uses. Each util reserves this normally (`cat.s`/`cp.s`'s `CBUF`, `ls.s`'s `DIRBUF`) |
| `io_buffer` | OPEN | MLI-internal per-file bookkeeping state, dereferenced by ProDOS **continuously for the life of the open file**, not just during the OPEN call itself | the **kernel**, in MAIN memory -- the MLI runs in main and has NO visibility into process banks at all; a process-bank address in this field would point at whatever unrelated byte happens to share that address in main, not at anything the process reserved |

This round's first draft got `io_buffer` wrong -- it reserved a 1024-byte
static buffer in EACH util's own process bank and pointed the field at
it (`cat`/`ls` one buffer, `cp` two -- the dominant driver of that
draft's size growth). Corrected: every util now sets `io_buffer` to
`$0000` and reserves no buffer for it at all -- a **PROPOSED convention**
(kernel-owned MLI buffers, keyed by the same fd->refnum table ruling 5
already requires) that **task #11 ratifies** when it wires
`PRODOS_DELEGATE` for real and has to actually allocate and translate
this field on delegation. This is exactly the same class of "task #11
still owns the real mechanism" flag as the result-in-parmlist finding
below -- both belong on the same list handed to that task.

**Error convention (ruling 4):** see "Error convention" above.

**fd numbers (ruling 5):** confirmed V6/Unix 0/1/2 -- but now with a real
mechanism behind it: the kernel keeps a per-process fd->MLI-refnum table in
the PCB (`inc/memmap.equ`'s `PCB_FDTABLE`), so liba/utils never see a
raw MLI reference number, only small process-local fd integers, at every
point (OPEN's result, READ/WRITE/CLOSE's `ref_num` field).

**open()/creat() flags (ruling 6):** `O_RDONLY`/`O_WRONLY`/`O_RDWR` are
now `$01`/`$02`/`$03` (the real MLI access bits: bit0=read, bit1=write) --
a one-line value change from the original draft's `$00`/`$01`/`$02`, same
names, `inc/syscall.equ`.

**readdir() (ruling 7):** no separate call number -- `ls.s` now does the
real thing: OPEN the directory as a file, READ raw 512-byte directory
blocks, walk 39-byte fixed entries per the ProDOS 8 TRM Appendix
B.2.4/B.2.5 algorithm (transcribed into `ls.s`'s header and code,
citations there). This is the single biggest CODE change this round -- see
"Consumer-reality findings" below.

**brk() (ruling 8):** unchanged -- absolute address, ratifies the original
draft outright.

**wait() (ruling 9):** confirmed V6-style wait-any, scoped to the CALLER's
own children (PCB parent-pid tracking) -- matches the original draft's
`SC_WAIT` shape exactly; no liba code change needed, only the citation.

**spawn()'s fdactions (ruling 10):** now DEFINED -- 3-byte `[opcode][target
fd][source fd]` records, `FDACT_END`-terminated (`inc/syscall.equ`).
`SC_SPAWN` still just forwards an opaque pointer (unaffected code-wise);
`docs/SH-DESIGN.md` is updated with the full worked pipeline example from
the ruling.

**Process entry state (ruling 11):** DEFINED -- `spawn()` synthesizes a
complete 6-byte trapframe (`PC=LOAD_BASE, P=$20, A=X=Y=0, SP=$F9`) so
`EXIT_TAIL` launches a fresh process with zero special-casing. Confirms
every util's original assumption ("no `SEI`/stack setup needed") outright.

**argv staging (ruling 13):** DEFINED, both placement AND content --
`inc/startup.equ` no longer says PROPOSAL; the kernel's actual
`spawn()` implementation matches this slice's original convention almost
exactly (see that file's header for the one addition: HOW the data gets
there -- string bytes re-packed via the same bounce-via-main the exec
loader uses, not copied verbatim as pointers).

## Per-util contracts

Behavior contracts are UNCHANGED from the original draft (same V6-minimal
scope, same flags-are-none policy, same exit codes) -- what changed this
round is entirely internal: how each util talks to the kernel. Two
functional consequences ARE user-visible:

- **cp** now performs the genuine two-step MLI dance (CREATE, then a
  separate OPEN) instead of assuming `creat()` hands back a usable fd --
  see "Consumer-reality findings."
- **ls** now walks real ProDOS directory blocks instead of a placeholder
  one-name-per-call convention. It also decodes GS/OS case bitflags, so
  mixed-case names display as written when the flags are on disk (a2til
  stages them; the kernel writes them per docs/PRODOS-CASE.md).

### Before writing `ls -l`, read docs/PRODOS-VERSION.md

Three decisions are already made and paid for there, and re-deriving them is
a day's work each:

- **Dates are validated, never trusted.** maux boots ProDOS 2.4 by ruling
  (2026-10-08) and 2.4 writes legacy dates; but a 2.5 kernel stamps an
  Extended-format date on every file it creates -- even though every util
  passes `cdate=0` -- and it is not legacy-readable, and such volumes exist. A naive decode yields a plausible year with an impossible
  time (measured: hour 151, minute 228), so `ls -l` written today prints
  garbage rather than erroring. Show `-` for any date that fails the check.
- **The check:** legacy means `hour <= 23 && minute <= 59`. Anything else is
  Extended. Cheap and reliable.
- **Legacy years use a pivot of 78**, not TN#28's 40: `78..99 -> 1978..1999`,
  `0..77 -> 2000..2077`.

`ls -l`'s other columns (name, type, size) have no such hazard -- and the
filetype column is now meaningful, since `sh` redirects and `ed` writes
produce `$04 TXT` rather than everything claiming to be `$06 BIN`.

**Still missing for a full `ls -l`:** `cp` cannot preserve a source file's
type because `GET_FILE_INFO` ($C4) is not exposed as a syscall. That is the
unblocked next step -- the kernel already brokers the `$C0-$CC` MLI range.

**2026-08-19 correction:** `GET_FILE_INFO` is now exposed -- `SYS_GFI`/
`SC_GFI`, see the addendum above. This unblocks `cp` preserving source
file_type/aux_type (and any future `ls -l`/`stat` consumer of
access/storage_type/blocks_used/dates); it does not by itself change `cp`'s
behavior -- `cp.s` still creates every destination as generic BIN as of this
note, since wiring the syscall and rewriting `cp` to call it are separate
pieces of work and only the former was in this round's scope.

**2026-08-19, later the same day:** the second piece landed. `cp.s` now
`SC_GFI`-stats SRC (same `GFIPARM` shape as `ls.s`) before `SC_CREAT`,
and patches `CRPARM_TYPE`/`CRPARM_AUX` from the stat result instead of
the old hardcoded `FTYPE_BIN`/`0`. DST's file_type/aux_type now match
SRC's. Access/storage_type/dates are unaffected (still liba DRAFT-VALUEs
-- task #11) and date preservation stays explicitly out of scope
(`SET_FILE_INFO` is not wired). The "always generic BIN" limitation
described above no longer applies to a fresh `cp`.

Binary sizes grew from the pre-MLI draft this round, mainly from the
2-byte-length parmlists and `cp`'s two-open-file bookkeeping -- but NOT
from `io_buffer`: an earlier draft of this round mistakenly reserved a
1024-byte static buffer per open file (`cp` carried two, 2KB) before
architect review caught that `io_buffer` is kernel-owned, not a process
buffer (see "Two pointer fields, two different physical meanings" above)
-- those buffers are gone. See the final report for the exact size table.

| util | contract |
|---|---|
| `echo` | print `argv[1..]` space-separated, one trailing CR, to stdout. No args -> just a CR. Exit 0 always. (No file calls -- unaffected by this round beyond the new `use` lines.) |
| `cat` | copy each `argv[1..]` file to stdout in order; no args -> copy stdin to stdout. A file that fails to open prints an error to stderr and is skipped. Exit 0 if every named file opened, 1 if any didn't. |
| `ls` | `ls [-l] [path ...]` (REWRITTEN 2026-08-19, this row was stale until 2026-08-20): no args lists the cwd via GET_PREFIX; each path arg is stat'd with `SYS_GFI` and either listed or printed as its own line; entries are collected, sorted case-insensitively on the stored uppercase bytes, and printed case-decoded. `-l` gives `TTT SSSSSSSS YYYY-MM-DD HH:MM NAME` with dates behind a validity check (`-` for zero/invalid/Extended). Truncates loudly past 128 entries. Exit 0, 1 per-path failure, 2 usage. Still no `-t`/`-a`/`-r`. |
| `cp` | `cp SRC DST` -- exactly two args or a usage error (stderr, exit 2). No `-r`, no directory targets. DST is created with SRC's real file_type/aux_type (`SC_GFI`-stated before `SC_CREAT`, since 2026-08-19); access/storage_type/dates are still liba DRAFT-VALUEs. Exit 0/1 on success/error. |
| `rm` | `rm FILE...` -- at least one arg or a usage error (stderr, exit 2). A file that fails to unlink prints an error and rm continues with the rest. Exit 0 if every unlink succeeded, 1 if any failed. |
| `bpatch` | `bpatch SPEC TARGET` -- a spec-driven BINARY patcher (2026-09-07; NOT the text `patch`/diff tool). Reads SPEC, a maux text file of directives (bit 7 masked, so plain or high-bit ASCII), and applies them to TARGET in place: `set OFF B [B...]` overwrites bytes at hex file offset OFF; `expect OFF B` asserts a byte before touching it (the file-version guard); `flip-lc` rewrites read-ROM language-card switches (`AD/2C/8D ... $C0` operands `$81->$83`/`$82->$80`) to read-RAM over the whole file. `#` lines and blanks are comments. Whole target read into a bank buffer (cap 28672 B), applied, written back -- NOTHING is written if any directive fails, so a bad `expect` leaves TARGET untouched. Exit 0; 1 on I/O or a failed directive; 2 on usage. The native, no-host path to patching a ProDOS program for proshim (see `patches/edasm-*.patch`); `dd`, which has no script mode, is the wrong tool for this. |
| `dd` | `dd [if=F] [of=F] [bs=N] [count=N] [skip=N] [seek=N] [conv=notrunc]` -- file-level (2026-09-07). Copies `bs`-byte records from `if=` (default stdin) to `of=` (default stdout); `count=` caps input records, `skip=`/`seek=` position in `bs` units (via LSEEK; a runtime multiply to the 24-bit ProDOS mark, `dd: offset too large` past it). `of=` fresh CREATEs (destroy+create) by default; `conv=notrunc` OPENs the existing file and overwrites in place (the binary byte-poke). Values are DECIMAL only (no k/b/w/xN suffixes; deferred). Reports `R+P records in`/`R+P records out` to stderr. Exit 0; 1 on an I/O/open/seek error; 2 on a bad operand. Block-device imaging waits on a /dev block layer (docs/FLEET.md); the spec-driven binary patcher is `bpatch`. |

Full contracts are in each util's own header comment.

## ABI RESOLUTIONS

Every friction item this slice originally raised, resolved against
`docs/SYSCALL.md`'s rulings (numbers below match that document's ruling
numbers, except 13/14 which SYSCALL.md deferred to liba and are ruled
above under "Line endings and text encoding").

1. **Argument transport** -- RESOLVED, ruling 1: registers, confirms the
   original draft unchanged.
2. **Call numbers** -- RESOLVED, ruling 2: process calls sequential 1-5;
   file calls are the real MLI numbers. `inc/syscall.equ` canonical.
3. **Parameter-block shapes** -- RESOLVED, ruling 3: file calls use
   verbatim MLI shapes (2-byte lengths, no more 255-byte cap); process
   calls keep maux-invented shapes. This round's liba rework, in full.
4. **Errno numbering** -- RESOLVED, ruling 4: raw MLI codes for file
   calls, `inc/errno.equ`'s `$E0+` for process calls. STILL OPEN (not
   a SYSCALL.md gap, a v1-scope choice this round kept unchanged): no
   util decodes a SPECIFIC code yet, every failure path prints one
   generic message regardless of which error occurred. Fine for V6-
   minimal v1; a natural place for a later round to add value.
5. **fd numbers** -- RESOLVED, ruling 5: V6/Unix 0/1/2, kernel-mediated
   fd->refnum translation.
6. **open()/creat() flags and mode** -- RESOLVED, ruling 6: real MLI
   access bits for flags. `creat()`'s mode fields (access/file_type/
   storage_type/dates) are NOT ruled by SYSCALL.md (explicitly deferred
   to task #11) -- this round had to pick concrete DRAFT-VALUEs to have an
   assemblable parmlist (`inc/mli.equ`: `ACCESS_UNLOCKED`=$C3 [TRM's
   own stated usual value], `FTYPE_BIN`=$06, `STYPE_SEEDLING`=$01 [the
   only storage_type CREATE accepts]) -- task #11 owns whatever real
   policy eventually applies.
7. **readdir() contract** -- RESOLVED, ruling 7: no separate call, real
   OPEN+READ on the directory file, 39-byte entries, TRM Appendix B.2.4/
   B.2.5's algorithm. `ls.s` implements it directly (see "Consumer-
   reality findings" for what that actually took).
8. **brk()** -- RESOLVED, ruling 8: absolute address, ratifies the
   original draft outright, zero code change.
9. **wait()** -- RESOLVED, ruling 9: wait-any scoped to caller's children,
   count-N pattern for pipelines. Zero code change; `docs/SH-DESIGN.md`
   updated with the ratified worked example.
10. **spawn()'s fdactions** -- RESOLVED, ruling 10: 3-byte records, DEFINED
    default-inheritance (fds 0/1/2 only, real dups) and dup-source
    resolution (always against the parent's table). `docs/SH-DESIGN.md`
    updated in full -- see that document, now zero open kernel questions.
11. **Process entry state** -- RESOLVED, ruling 11: spawn() synthesizes a
    full trapframe; confirms every util's original assumption.
12. **argv/argc startup page content** -- RESOLVED, ruling 13: both
    placement (already settled last round) and content now DEFINED,
    matching this slice's original proposal almost verbatim.
13. **Line endings** -- RULED (liba's own call, SYSCALL.md deferred it):
    CR `$8D`, see above.
14. **On-disk text encoding** -- RULED (liba's own call, SYSCALL.md
    deferred it): liba converts nothing on read/write; the one mandatory
    conversion (MLI pathnames) is structural, not a text-encoding policy.
    See above.

## Consumer-reality findings (this round -- SYSCALL.md contradictions/gaps liba's implementation surfaced)

These are NOT things SYSCALL.md got wrong -- they're places where being
the ABI's first real consumer surfaced detail the ruling-level document
didn't need to spell out, exactly the role this task is supposed to play.

- **MLI CREATE has NO ref_num result field** (TRM ch. 4.4.1, 12-byte
  parmlist: param_count/pathname/access/file_type/aux_type/storage_type/
  create_date/create_time -- no result field at all). This slice's
  ORIGINAL draft assumed `creat()` returns a usable fd (V6 convention).
  That assumption does not survive contact with the real MLI: `cp.s` now
  does CREATE-then-separate-OPEN, the genuine two-step dance every real
  ProDOS program performs to make a new file usable. Not a SYSCALL.md
  bug -- ruling 6 only promised "creat()'s mode byte forwards to the MLI
  CREATE parmlist," which is still true; it just doesn't discuss the
  return-value shape, and the natural V6-flavored assumption about that
  shape turned out to be wrong.
- **File-call success does not carry a documented result in A.** The
  kernel's generic `KERNEL_EXIT` patches SOME value into frame-A on every
  call (`src/kernel/entry.s`'s `K_RESULT`), but for file calls the REAL
  results live in the MLI parmlist's own result fields (`ref_num`,
  `trans_count`), already visible to the caller with no copy-back needed
  (the caller owns the buffer). liba's file-call wrappers therefore treat
  A as meaningless on success and read results from the parmlist only --
  worth task #11 confirming explicitly when it wires `PRODOS_DELEGATE`
  for real, since nothing currently exercises a genuine MLI success path
  end-to-end (the delegate stub still always returns `ERR_PRODOS_UNWIRED`).
- **OPEN's `io_buffer` is MLI-internal, kernel-owned state -- NOT a
  caller-supplied buffer, despite being a plain pointer field in a
  parmlist liba is otherwise just forwarding verbatim** (architect
  review, merge-blocking finding, corrected in this revision -- see "Two
  pointer fields, two different physical meanings" above for the full
  writeup). This round's FIRST draft got it wrong in exactly the way
  "verbatim MLI parmlist shapes" (ruling 3) invites: it treated `io_buffer`
  the same as `data_buffer` (a process-bank address the caller reserves)
  because both are plain pointer fields in shapes transcribed byte-for-
  byte from the TRM. They are not interchangeable -- the MLI dereferences
  `io_buffer` continuously while the file stays open, from code running in
  MAIN memory with no visibility into process banks, so a process-bank
  address there is meaningless to it. This is precisely the kind of gap a
  ruling-level ABI document doesn't need to spell out and a real consumer
  finds by trying to make the shape actually work -- flagged to task #11
  alongside the result-in-parmlist finding above, since both require the
  same kernel-side mechanism (translating a field on delegation) task #11
  is already the one building.
- **readdir()'s real shape is substantially more work than the original
  draft's placeholder.** The original draft assumed "one NUL-terminated
  filename per kernel call" -- a convenient fiction with no MLI backing.
  The real mechanism (block-level READ, 39-byte packed entries, active/
  inactive discrimination via a zero first byte, header fields read from
  the FIRST block, block-boundary continuation logic) is real, cited,
  non-optional complexity that now lives in `ls.s` directly, per ruling
  7's own framing ("that reshaping is liba's job, not a kernel call").
- **Long CREATE/OPEN/copy-loop routines pushed some branches past the
  6502's +/-127-byte relative range** (`cp.s`, `ls.s` -- merlin32 caught this
  at assemble time with a hard error, not a silent miscompile). Correction
  to an earlier draft of this document: the cause is the amount of CODE
  between an early check and its shared error handler (multiple
  OPEN/CREATE/READ/WRITE call sites feeding one `:err` label), NOT the
  size of any `ds`-reserved data buffer -- buffers are declared textually
  AFTER the code in every util, so they were never physically between a
  branch and its target regardless of their size (confirmed by re-
  checking after this round's `io_buffer` removal shrank both files by
  1-2KB with the branch-range fix still required, unchanged). Fixed with
  an unconditional-`JMP` pattern (`bcc :skip / jmp :target / :skip`)
  everywhere a conditional branch's target ended up too far away. A craft
  note for whoever writes the next MLI-heavy util, not an ABI question.

## DEPOSIT CANDIDATES (not deposited by this task -- see final report)

- The `syscalls.s`/util self-tripping lesson (unchanged from last round --
  still not deposited, still a single observation): a Makefile grep-based
  ABI-choke-point enforcement gate needs its OWN source comments to avoid
  the literal string it's checking for.
- **The MLI CREATE-has-no-ref_num gotcha** (this round): a program
  expecting `creat()`/`CREATE` to behave like a Unix-style "make and open
  in one call" will silently misuse the MLI unless it knows to OPEN
  separately afterward. Plausible commons candidate if a second
  ProDOS-adjacent project hits the same assumption.
