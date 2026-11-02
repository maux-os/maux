# io_buffer lending -- the open-file ceiling is gone, not raised

Landed 2026-09-07. Kernel: `src/kernel/procfd2.s` (`PRC_ALLC_IBF`,
`PRC_PARK_ONE`, `PRC_UNPARK`, `PRC_OFT_REF`, `PRC_OFT_SETP`,
`PRC_PARK_SAME`), constants in `inc/proc.const.equ` and
`inc/mm.mlibuf.equ`, errno in `inc/errno.krn.equ`.

## 1. The constraint, stated once

ProDOS 8's OPEN needs a caller-supplied, page-aligned 1 KB `io_buffer`
per open file, held for the file's whole open lifetime, in MAIN memory
below the global page **[fact, TRM 4.5.1]**. ProDOS 8 also allows **at
most eight files open at a time** **[fact, TRM p.13]**. maux's main
memory is the kernel's, not the process's, so every open file anywhere
on the machine draws from one pool, and that pool can never exceed 8.

Before this work the pool was 6 and it was a hard wall: the seventh
OPEN failed with `ERR_AGAIN`, utilities printed `cannot open` on a
file that plainly existed, and a filter spawned three levels deep
produced nothing at all. A live `check-ex` run on 2026-09-07 measured a
high-water of 6 of 6. The shapes that hit it were ordinary:

| shape | buffers |
|---|---|
| `cmd < a > b` at a prompt, cold spawn | 3 |
| harness wrapper `sh < script > out 2> err` | 3 held for the run |
| inner `cmd < a > b` under that wrapper | 6, the old ceiling |
| nested `sh SCRIPTFILE` under that wrapper | 7, failed |
| ex `1,$!sort` under that wrapper | 7, failed |

Three programs had hand-rolled the same workaround -- ex closed and
reopened its swap file around every spawn, cptree closed the directory
before every copy, find kept one directory fd -- and every new spawning
feature was going to rediscover the wall.

## 2. What the kernel does now

**Since 2026-10-21 (B1) the pool is 6, at $A000-$B7FF** -- two of the
eight buffers given back for 2,048 B of flat-image ceiling. Sec 7 below
is the account; everything in this section describes lending, which is
unchanged. The pool was 8 (the ProDOS cap) from 2026-09-07; when
it is empty, `PRC_ALLC_IBF` **parks** the least-recently-used resident
file: `GET_MARK`, `CLOSE`, release its buffer. The next read, write,
seek or EOF call on that file **unparks** it: allocate a buffer (parking
another file if it must), `OPEN` the path saved when the file was first
opened, `SET_MARK` to the saved position. To the process nothing
happened except a directory walk.

Mechanism:

* `OFT_IOBUF[x] == 0` on an `OFT_FILE` entry means *parked*. Every
  refnum consumer goes through `PRC_OFT_REF`, which stamps the LRU tick
  (`OFT_LRU[x] = K_FTICK++`), unparks if needed, and returns the
  refnum. Nothing else reads `OFT_REFNUM` -- that is the whole contract
  and the thing a reviewer should grep for.
* The per-slot store lives at `OFT_SLOT_BASE` ($BA00) in main memory,
  above the buffers ($A000-$B7FF) and the transfer buffer ($B800), NOT
  in the kernel image: `OFT_COUNT` x 68 bytes = 65 path bytes plus a
  3-byte mark. `PRC_OFT_SETP` fills the path at OPEN from
  `PRC_PATHBUF`, which `PRC_ABSPATH` has already made absolute when a
  cwd is recorded.
* A path that stayed relative (no cwd recorded, pid 1 before any `cd`)
  is stored with length 0, which means **pinned**: never a victim. A
  relative reopen would resolve against whatever ProDOS prefix happened
  to be current, i.e. possibly a different file.
* ProDOS refuses a second OPEN, a DESTROY or a RENAME of an open file
  with `$50`. A parked file is closed in ProDOS, so ProDOS would no
  longer refuse -- `PRC_PARK_SAME` refuses on its behalf, case-folded,
  at the same three call sites. Nothing observable changed except that
  the ceiling is gone.
* `PRC_DEC_OBJ` closing a parked file closes nothing in ProDOS and frees
  no buffer.
* **Shared read groups (OPEN-RO-2).** Read-intent opens of one path share
  one ProDOS refnum and one buffer id; they are a *group*, and a group
  parks and unparks AS ONE: `PRC_PARK_ONE` saves the live mark of whichever
  member holds it (`K_ROOWN`), closes once, frees the buffer once and
  zeroes `OFT_IOBUF` of every member; `PRC_UNPARK` reopens once and
  `PRC_ROMATES` hands the new refnum and buffer to the other members (found
  by the canonical path in the slot store). A group is NOT pinned: pinning
  it was measured and rejected, because with six buffers and the loop's one
  a fifth background job holding a group starved the spawn (`sh: command not
  found`), where parking starts them all (docs/OPEN-RO-2-NOTES.md sec 3).
* **One writer in the group (OPEN-RW-2).** A group may hold one no-intent
  member (`OFTF_MG` without `OFTF_RO`); it parks and unparks with the
  rest (the park's CLOSE writes its dirty block). A member whose saved
  mark is above the live EOF (the writer truncated) is *virtual*: unpark
  keeps it in the slot and leaves the reopen at mark 0 (K_ROOWN never
  names it). A failed final CLOSE is not a park: the page is quarantined
  (`K_QUAR_CNT`), see docs/OPEN-RW-2-NOTES.md sec 3.
* Reopen failure (the file was renamed or destroyed by something that
  bypassed the kernel, or the volume went offline) reports the MLI error
  on the read/write that needed it and leaves the entry parked. A
  `SET_MARK` failure after a successful reopen (the file shrank) is
  reported the same way; the entry is resident at mark 0.

Cost: one directory walk per unpark. The victim choice is LRU, so a
process's script fd is parked while its child runs and unparked once,
when the child returns, at the line after the one it was parked on.

## 3. What binds now

* `OFT_COUNT` = 16 system-wide open-file-table entries, 8 fds per
  process. Exhaustion is `ERR_NFILE` ($E9), V7's ENFILE, which is
  distinct from `ERR_AGAIN` on purpose: three misdiagnoses in one month
  came from the two being one code.
* `PRC_ALLC_IBF` can only fail if every resident buffer is pinned, and
  then it also says `ERR_NFILE`.

## 4. Diagnostics

The kernel keeps `K_IBF_INUSE`, `K_IBF_HIWAT` (pool high-water since
boot) and `K_PARK_CNT` (parks since boot). Harnesses read them **by
symbol from the image's own listing** (`build/<image>_Output.txt`),
never by a pinned address -- `check_ex.py` used to peek `$29A9` for
`MLI_BUF_USED`, and that address moved the day `process.s` grew a table
in front of it.

## 5. Gates

* `check-shlang` (second image): `SH < DEEP1 > DEEPOUT 2> DEEPERR`, SIX
  nested `sh SCRIPTFILE` levels (DEEP1..DEEP6), innermost
  `CAT < MGFILE > DEEPF`. Ten files held plus the loader against a pool
  of eight. RESULTS must read `D6:0 D5 D4 D3 D2 D1 DP0 DEEPQUIET` in
  that order -- each nested script's fd was parked while `cat` ran and
  resumed at the right line -- and the harness fails if `K_PARK_CNT` is
  still 0, because a case that no longer reaches the ceiling proves
  nothing. (It was four levels through 2026-09-07; four peaked at
  exactly 8 buffers with zero parks -- warm respawns spent no loader
  buffer -- so it was raised to six.)
* `check-iobuf` (docs sec 6 below, `scripts/check_iobuf.py`) is the
  edge-case gate: a generated probe process reproduces every hazard
  the 2026-09-07 review found (below), against the real kernel and
  resident ProDOS -- duplicate open of the LRU victim (IB1), a relative
  alias of a parked file (IB2), rename of a directory holding a parked
  file (IB3), a failed victim CLOSE (IB4), a failed mark restore (IB5),
  an OPEN of a ZERO-LENGTH pathname while something is parked (IB6,
  2026-09-16 -- an empty path has no identity, so `PRC_CANONPATH` must
  report it with the carry and the unknown-identity rule must refuse;
  it used to return carry CLEAR with length 0, which compares unequal
  to every saved path and so read as "not open"), plus a control that
  unparks at the saved mark and two rename/read controls. IB1 ASSERTS
  its own trigger before testing -- pool full, nothing parked, and the
  target file proven to be the entry `PRC_PARK_ONE`'s own age rule
  would pick -- so the mode cannot go green because the setup drifted.
  The two fault modes patch one kernel helper in emulator RAM
  and restore it; the rest use ordinary syscalls only.
* `check-ex` Phase D reports the pool high-water and the park count.
* `check-kernel-images` checks the three main-memory regions above the
  image (buffers, transfer buffer, lending store, and the canonical-path
  scratch at $BE40) against each other and against $BF00, and refuses a
  count above 8. `check-ibf-ceiling` (B1) plants padding past the old
  ceiling; `check-iobuf` has the `pinfull` and `parksat` rows.

## 5a. Correctness of the park/unpark edges (2026-09-07)

The first cut promised "nothing observable changes except the ceiling";
that was too strong, and a second-chair review (the design review, IB1-IB5)
found five edge cases. All are closed:

* **Identity is compared as the CANONICAL absolute path, not the
  spelling.** Only ABSOLUTE-opened files are parkable; a relatively-
  opened file is PINNED (never parked), exactly as before lending's
  edge-case work -- making relative files parkable (reopen by a
  computed canonical path) regressed the deep nested-shell case, whose
  actively-read fds must stay resident, so it was not done. IB2 is
  caught the other way: `PRC_FILE_BUSY` canonicalises the INCOMING path
  (`PRC_CANONPATH`: absolute as-is, else ProDOS's current prefix via
  GET_PREFIX + the path) before comparing it against every saved
  absolute identity. Since the only parked files are absolute, that
  comparison is complete -- a relative alias of a parked file matches.
* **The open-file exclusion covers resident AND parked entries**
  (`PRC_FILE_BUSY`, called from OPEN/DESTROY/RENAME). ProDOS refuses a
  second open of a *resident* file with $50; a parked file is closed in
  ProDOS, so the kernel refuses on its behalf -- and refusing a resident
  match here too stops the allocator from parking the very file being
  opened and letting a duplicate through (IB1/IB2).
* **RENAME of a directory that holds an open file is refused**
  (`PRC_ANCEST_BUSY`): renaming an ancestor would orphan every
  descendant's saved reopen path, so it is refused $50 rather than
  silently breaking those descriptors (IB3).
* **A park commits only on a clean CLOSE.** `PRC_PARK_ONE` returns the
  victim's GET_MARK/CLOSE error instead of recording a park, and
  `PRC_ALLC_IBF` propagates that error rather than flattening it to
  ERR_NFILE; the victim stays resident and open (IB4).
* **An unpark exposes the descriptor only once SET_MARK succeeds.**
  `PRC_UNPARK` reopens into a held buffer and installs the refnum only
  after the mark is restored; a failed restore closes the reopen and
  leaves the entry parked, so no later access silently runs at position
  zero (IB5).

Two further points a review (2026-09-07) pinned:

* **Saved identities are stored low-ASCII.** `PCPY_PATH_G` masks each
  copied path byte to 7 bits, matching what ProDOS's own GET_PREFIX
  returns, so a file opened with a high-bit pathname and a later
  low-ASCII relative alias of it canonicalise to the same bytes and the
  alias is still caught. `check_iobuf.py` mode `hialias` opens F0 through
  a high-bit path and asserts the saved slot carries no high bit.
* **The IB2 refusal is an identity match, not a blanket rule.** Mode
  `relctl` opens a *distinct* unopened file relatively under the same
  park pressure and requires it to SUCCEED, proving the `relative`
  refusal comes from the canonical path matching a parked file's, not
  from relative opens being refused whenever something is parked.

## 5c. Accepted gaps in the identity guard

Two conservative behaviours are documented in `procfd2.s` and kept on
purpose; both are safe, and neither can alias a parked file:

* **Over-refusal of an unverifiable path (fail-safe).**
  `PRC_CANONPATH` gives up when there is no ProDOS prefix set or the
  absolute form would exceed 64 characters. `PRC_FILE_BUSY` then treats
  the identity as UNKNOWN and refuses the open with $50 *if anything is
  parked* -- so a genuinely distinct long or prefixless relative open can
  be refused while lending is active. It is a false positive (it never
  lets an alias through), it fires only under park pressure, and the
  caller can retry once buffers free. The alternative -- reopening the
  parked victim just to compare paths -- would defeat lending.
* **Ancestor-rename of a resident relatively-opened file is not guarded
  here.** A relatively-opened file is pinned and carries no saved
  identity, so `PRC_ANCEST_BUSY` cannot see it as a descendant. That is
  bounded: a pinned file is by definition RESIDENT (pinning is what keeps
  it resident), so ProDOS still holds its refnum and enforces its own
  open-file rules on the subtree. The kernel only needs to protect the
  reopen paths of PARKED files, which are always absolute.

## 6. Why lending rather than another raise

Because there is no other raise: 8 is ProDOS's number. The only other
way out is per-process io_buffers in aux memory, and ProDOS 8 cannot be
handed one -- the MLI checks the buffer against its main-memory bit map
and does its own transfers with main-memory addressing. Lending turns
the ceiling into a working-set limit, which is what an operating system
is for.

## 7. B1 (2026-10-21): six buffers, the pool at $A000

`PMLI_IBF_BASE` $9800 -> $A000, `MLI_IOBUF_CNT` 8 -> 6, the harness
cell block $97E8-$97FF -> $9FE8-$9FFF (the last 24 bytes below the
pool, the placement rule of learning:01M197TY462D8ZRJHSQ77FGWK9). The
flat kernel image's ceiling, and every image's, rose by exactly 2,048 B
because the ceiling is DERIVED from the equate; MAUXPLAY's headroom
went 777 B -> 2,822 B (the 3 B difference is the saturating park
counter, net of the 2 B `MLI_BUF_USED` table that shrank). The 768 B
headroom ratchet did not move: the room is for the next streams.

What six costs, measured over the whole 152-gate sweep at 8 and at 6
(docs/B1-NOTES.md sec 1): one gate newly parks (check-ex, 3 parks),
nothing thrashes, nothing parks on a per-character path.

What the loop costs: an attached /dev/loop holds one pool buffer for
as long as it is attached (loopseg.s LP_IBF; it is a raw MLI file, not
an OFT entry, so it is never a victim). Five are left for everything
else. `check-loop` and the six-deep `check-shlang` pass with it.

Pin exhaustion is a correctness case, not a slowdown: a relatively
opened file is pinned (sec 2), and if every buffer is pinned the next
OPEN has no victim and fails with ERR_NFILE. `check-iobuf pinfull`
makes all six pinned and requires exactly that, no leaked OFT entry,
no hang. `K_PARK_CNT` saturates at 255 instead of wrapping
(`check-iobuf parksat`); `K_IBF_HIWAT` is the pool high-water.
