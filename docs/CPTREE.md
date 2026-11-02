# `cptree` -- the shared recursive walk behind `mv DIR` and `cp -r`

**Status: BUILT** (`src/liba/cptree.s`, `cptree2.s`, `cptreebss.s`; the
engine behind `cp -r` and `mv DIR`, `docs/man/cp.1`). Design note,
2026-08-25: this file is the implementation contract and the record of
what the build found. Nothing here is re-derivable from the corpus
-- every number was read out of a header or an `.equ` this session.

## 0. The one-paragraph summary

`mv SRC DST` with a directory SRC and a different parent, and `cp -r SRC DST`,
are the same walk with a different ending. Both get it from one new liba
module, `src/liba/cptree.s`, which mirrors a directory tree from SRC to DST.
`mv` then runs a second, separate pass that removes SRC bottom-up. The walk is
`find.s`'s proven iterative DFS -- explicit depth stack, at most **one** open
directory, reopen-and-replay on the way back up -- and it holds **at most one
MLI fd at a time**, which is a hard requirement, not tidiness (sec 3).

## 1. Semantics -- Unix-exact, and where mv and cp legitimately differ

These are the host's rules, checked against `/bin/mv` and `/bin/cp` behaviour,
not invented. The governing rule is the operator's: *maux is like Unix, not
Unix-like -- no avoidable semantic drift.*

### `mv SRC DST`, SRC a directory

`DSTRESOLV` runs first and is unchanged: if DST names an existing directory,
DST becomes `DST/basename(SRC)`. After it, DST is a full target path, and:

| DST after DSTRESOLV | action |
|---|---|
| is SRC, or a descendant of SRC | **refuse**, exit 1 -- moving a directory inside itself |
| absent | CREATE it as a directory, mirror into it |
| exists, is a plain file | **refuse**, exit 1 (host: "cannot overwrite non-directory") |
| exists, is a directory, EMPTY | mirror into it (host: rename over an empty dir succeeds) |
| exists, is a directory, NON-EMPTY | **refuse**, exit 1 (host: "Directory not empty") |

The same-parent rename is untouched and still goes to MLI RENAME via
`SAMEDIR`/`TRYRENAME`. Only the cross-parent case reaches the new code.

### `cp -r SRC DST` / `cp -R SRC DST`

Both spellings accepted (POSIX spells it `-R`, GNU accepts `-r`; every host
`cp` in reach takes both). Flag must be `argv[1]`; `cp` has no option
permutation today and gaining one is not this task.

* `-r` with a **file** SRC -- an ordinary single-file copy. The host does this;
  it is not an error.
* `-r` with a **directory** SRC -- as the mv table, with **one deliberate
  difference**: an existing directory DST is **MERGED into**, not refused,
  empty or not. That is what `cp -r` does and `mv` does not. Not drift -- the
  two tools genuinely differ here.
* **No** `-r`, directory SRC -- refused, unchanged. `/bin/cp` refuses too; the
  `('cp', 'no recursive copy')` entry died on 2026-08-25 for exactly that
  reason and must not come back.

`cp SRC DST` with argc 3 is byte-for-byte the path it is today.

### Errors abort; they do not continue

`find` reports a bad entry and keeps walking. **`mv` and `cp -r` must not.**
A partial copy followed by a teardown loses data, so the first failure of any
kind -- copy, CREATE, a path over the MLI's 64-char cap, depth exhaustion --
closes the directory, reports, and exits 1 with SRC **untouched**. This
preserves `mv.s`'s existing written guarantee ("SRC is unlinked only after a
clean copy") at directory granularity, which is also why the teardown is a
**second pass** and not interleaved with the copy.

## 2. Why the teardown is delete-driven and needs no resume counter

`DESTROY` refuses a non-empty subdirectory with `$4E`
(`learning:01M0T0YSPMJE238VH46CZPDR2V`), so removal is depth-first, deepest
child first. The teardown does **not** reuse the copy pass's resume
bookkeeping. It reopens the directory each iteration and always takes **entry
zero**:

```
RMTREE:                         ; CPT_SRC = root to remove
  DEPTH = 0
loop:
  OPENDIR(CPT_SRC)              ; failure -> abort
  e = READDIR                   ; one entry only
  CLOSEDIR                      ; <-- closed BEFORE anything mutates
  if exhausted:
      DESTROY(CPT_SRC)          ; now provably empty; failure -> abort
      if DEPTH == 0: done
      pop SRCLEN; DEPTH--
      goto loop
  if e is a directory:  push SRCLEN; append "/"+name; DEPTH++; goto loop
  else:                 DESTROY(CPT_SRC + "/" + name); goto loop
```

Progress is guaranteed because every iteration either destroys an entry or
descends one level, and descent is bounded. Deleting *is* the cursor, so
there is nothing to resume. It also means **no entry is ever destroyed while
its parent directory is open** -- a question the commons does not answer
(searched: "DESTROY entry while directory is open", "modify directory during
enumeration" -- nothing), so the design sidesteps it rather than betting on it.

## 3. One fd at a time -- a hard constraint, with a number behind it

**Superseded 2026-09-07 as a CONSTRAINT, kept as a design choice.** The
kernel now lends io_buffers (docs/IOBUF-LENDING.md): an exhausted pool parks
the least-recently-used open file and reopens it on its next use, so holding
the directory open across a copy would no longer fail, it would cost a
directory walk on every resume. The close-and-replay walk below stays because
it is also what keeps "no entry is destroyed while its parent directory is
open" true, which lending does not buy. The numbers that follow are the ones
that shaped it.

`inc/mm.mlibuf.equ:68`: `MLI_IOBUF_CNT equ 6`. Each open file costs a
page-aligned 1024-byte kernel io_buffer and they are **system-wide**, not
per-process. The same file records a **measured high-water of 4** during
`check-shlang`, reached by "outer sh's own script fd + its `2>` capture file +
a NESTED sh's script fd + the spawn loader's transient buffer", and records
that at a ceiling of 4 the symptom was `cat: cannot open <path>` on a file
that plainly exists.

Every `check-e2e-fs` case runs as `MV ... > /BASIC/OUT/Onn 2>&1` under `sh`,
so the walk starts with the pool already partly spent. A walk that held its
directory open across a file copy would want 3 fds of its own and push the
system to 5 of 6.

**So: close the directory before every file copy and before every CREATE, and
reopen + replay afterwards.** Peak usage stays at 2 fds -- exactly what `mv`
and `cp` cost today. The cost is that a level with *n* entries re-reads its
own directory blocks O(n) times. `find.s`'s header already documents and
accepts that same trade for the same singleton reason; trees here are small.

## 4. The module -- as built

`src/liba/cptree.s` (code) + `src/liba/cptreebss.s` (storage), `put` by
`mv.s` and `cp.s` only, alongside `readdir.s` which both now also `put`.

### Where the storage went, and why the first two answers were wrong

The design above proposed that the CONSUMER declare cptree's cells in its
own `dum` arena, by analogy with `find.s` owning `RD_RECORD` for
`readdir.s`. **That analogy is false and the gate says so.** `readdir.s`
never *names* `RD_RECORD` -- the caller passes it in A/X -- whereas cptree
has ~950 bytes of state across a dozen names. `check_modules.check_userland`
fails any liba module that references a symbol only a `src/bin` program
defines: *"A library module reaching up into its caller cannot be assembled
or linked on its own."* Correct, and fatal to that plan.

The second answer was to put the cells in `libabss.s` with every other
liba module's. That assembles, and the argument for it is sound as far as
it goes -- a `dum` arena emits no bytes, so no program's `.bin` grows by one
byte for storage it never touches. **It is also wrong, and the tree
measured it within one build.** `libabss.s` is one monolithic block `put`
by all 40 programs, so a cell added there is reserved by every one of them;
and `as.s` bounds its arena at `SYMADR` ($3C00), not $BF00, because the
assembler's symbol table starts there. It had roughly 540 bytes of
headroom. `make check-userland` failed at `as.s:1302` -- *"The evaluation of
ERR expression is 0x1"* -- which is that program's own ceiling tripwire
doing exactly its job. Shrinking the assembler's symbol table to give `mv`
a directory walk is not a trade worth making, and a shared arena makes
every future liba addition pay it again.

**So the storage is CHAINED**: `cptreebss.s` opens `dum LIBA_BSSEND`,
declares cptree's cells, and closes with `CPT_BSSEND`; `mv.s` and `cp.s`
then open their own arenas at `CPT_BSSEND` rather than `LIBA_BSSEND`. The
38 programs that never call cptree pay nothing at all.

That required teaching a gate. `check_purity.check_arena_anchors()` failed
**any** `put` after `libabss.s`, on the reasoning that "every byte the later
module emits lands on top of liba's storage". True of an emitting module,
vacuous for one that emits nothing -- and `check_purity`'s own `LIBA_DEBT`
note already sketched this exact pattern as the intended route for
`expr.eval.s` and `testeval.s`, so the gate and the note contradicted each
other. The gate now follows the `put`, proves the module is BSS-ONLY
(`_bss_only_module`: every line outside a `dum` block is a comment, an
equate or assembler control; the block opens at `LIBA_BSSEND`; it defines
an end label), and separately proves the program did NOT re-anchor its own
arena at `LIBA_BSSEND` -- which would put the two blocks on the same bytes,
the `dum *` failure one indirection along.

### Entry points

```
CPT_START   mirror CPT_SRC's tree into CPT_DST (caller created DST)
CPT_RMTREE  remove CPT_SRC and everything under it, deepest child first
CPT_MKDIR   CREATE CPT_DST as a subdirectory; $47 on an existing
            DIRECTORY is success (cp -r's merge), on a FILE a failure
CPT_COPY1   copy one regular file, file_type/aux_type preserved
CPT_ISDESC  carry SET if the candidate IS the base or lies beneath it.
            A plain prefix compare is NOT enough -- "/T/AB" starts with
            "/T/A"; the next character must be the separator or the end
CPT_UNPATH  MKPATH's inverse, for cp.s, which builds MLI paths up front
```

Carry set means failure, with a reason in `CPT_ERR`: a real MLI errno
(always < $80), or `CPTE_LONG` ($F0) / `CPTE_DEEP` ($F1) for the two
maux-side refusals, which take values no MLI call can return precisely so
the consumer needs no second flag.

## 5. Findings the implementation turned up

Four things this change discovered that were not in the brief. Each is a
pre-existing defect that the recursive move either exposed or would have
made dangerous.

**1. `mv` was TEXT_IMMUTABLE only by accident of workload.** `mv`'s ten MLI
parmlists were emitted data, and the kernel writes results back into a
parmlist (`check_purity`'s write shape D; `procspawn.s` `PCPO_MLIPARM` does
the copyout) -- `ref_num`, `trans_count`, and `GET_FILE_INFO`'s whole
15-byte result block, all landing in `mv`'s **image**. It measured clean
only because `check-textaudit`'s `mv` pair is a same-directory rename,
which reaches MLI RENAME and nothing else, and RENAME is the one call there
with no result field. `COPYFILE` was never executed by the audit. Adding
`SRCISDIR` -- one stat on every invocation, rename included -- made it
visible immediately: **12 of 4,406 image bytes, both runs, entry head
intact**, so the kernel retains the bank and the next `mv` starts on
mutated text. The fix is not to stop stat'ing; it is to stop writing text.
All ten parmlists are arena cells now, stored by `INITPARMS`, and `mv`
measures `CLEAN` on every path rather than on the one the audit happened to
walk. It retires this file's oldest trap for free: the `GFIPARM_PATH`
warm-bank defect (`learning:01M0T103ZQSAEGQ5D8FS8XZ8V4`) could only bite
because a repointed POINTER survived into the next run, and a cell
rewritten on every entry cannot.

**2. `cp.s` contained a cross-zone local-label reference, which is outside
the dialect intersection.** `jmp :err` appeared eleven times in `START`'s
zone while `:err` was defined in `DSTRESOLV`'s. merlin32 resolved it only
because `:err` happened to be unique in the whole assembly unit; `put`ting
`cptree.s`, which has an `:err` of its own, made it ambiguous and the
assembly failed with *"Can't find format for element ':err'"*. Real
Merlin-8 scopes locals between global labels too, so the construct was
never inside the intersection HACKING.md requires -- the self-hosting
milestone and `check-dual` depend on it. `:err` is the global label `CPERR`
now. **Nothing in the tree gates this**, and it was found by collision
rather than by a check; that is worth a deposit and probably worth a gate.

**3. A trailing slash on SRC silently built the wrong path.** `DSTRESOLV`
takes `basename(SRC)` by scanning for the last `/` and starting one past
it, so for `"/T/DIR1/"` the basename is EMPTY. `mv /T/DIR1/ /T/DIR2` then
appended nothing, DST stayed `/T/DIR2`, and a move-INTO became a
move-ONTO -- exit 0, no output. In `cp.s` the same scan started one byte
PAST the count byte and copied garbage until it hit the 64-character fence.
Both were reachable before this change and harmless only because a
directory SRC was refused outright; the moment `mv` can actually move one,
the same line silently builds the wrong tree. `SRCSLASH` strips it in both
tools and START refuses a trailing slash on a plain file, which is what
POSIX says that slash asserts.

**4. `cp -r DIR DIR/SUB` has no single Unix answer.** Measured
2026-08-25: BSD `cp -r a a/b` exits **0** having copied one level, GNU
warns "cannot copy a directory into itself" and exits **1**. maux takes
GNU's answer, because on ProDOS the alternative is a walk descending into
the destination it is still growing. This is the `ls`-usage-exit-status
shape (BSD 1, GNU 2) -- a classified divergence with no correct answer to
conform to, not drift. It is deliberately NOT given a corpus case: the two
sides differ in stdout, exit status AND post-state, and `status_ruled=`
exempts only the status, so a case could only be made to pass by weakening
it. `mv DIR DIR/SUB`, which both hosts refuse, IS in the corpus.

## 6. Testing -- assert the TREE, not the message

A misplaced `mv` still exits 0 and still prints nothing. That is how a
Y-register clobber shipped on 2026-08-25 and passed a message-only check.

`scripts/probe_mvdir.py` is the reproducer: **31 cases, one image and one
boot each, ~7 s**, every one asserting the resulting tree. Sixteen are new
for this change -- the two formerly-pinned shapes, a two-level tree with
siblings, a level holding TWO subdirectories, both trailing-slash forms,
all five refusals, four `cp -r` shapes, and two WARM-BANK pairs that run
the operation twice in one boot (one invocation per boot always passes;
that is the shape the `GFIPARM_PATH` defect hid behind).

**Sabotage-proven, three ways**, because a test that has never been seen to
fail proves nothing:

| sabotage | caught by |
|---|---|
| `CPT_SKIP` decrements the level's ABSOLUTE position instead of a copy -- `find`'s own ping-pong bug, transplanted | 28/31; the two-level, two-subdirectory and `cp -r` depth cases. **Not** by any single-level case, which is exactly why one level is not a recursion test |
| `CPT_ISDESC` does a plain prefix compare, dropping the separator check its header warns about | 30/31; the move-into-itself refusal |
| the walk forgets `CPT_UNAPP`, so a sibling's path is built onto the previous child's | 30/31 |
