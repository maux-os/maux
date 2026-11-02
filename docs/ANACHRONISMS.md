# The anachronism register

Status: LIVING DOCUMENT, opened 2026-08-21 at the operator's call.

maux states a **V5/V6 fence** (`docs/FLEET.md`). It has departed from
that fence repeatedly and deliberately. Without a register, each
departure reads as an oversight rather than a decision, and the fence
quietly becomes a lie -- the same failure `docs/PLAN.md` hit when its
queue kept listing shipped work. **A stated constraint that is silently
broken is worse than no constraint**, because it stops carrying
information.

So: every deliberate departure gets a line here, with its reason.

## The governing principle (operator, 2026-08-21)

> "I don't really see the value in recreating Ken's shell historically.
> It was crude. Steve's shell is old school but new enough that it's
> familiar and POSIXy."

**Historical fidelity is not a goal in itself. The fence is a taste
guide, not a museum.** It exists to keep the system small, orthogonal
and legible -- the things early Unix was *right* about. It does not
exist to reproduce early Unix's crudities.

Three tests, applied in order:

1. **Does the old design's CONSTRAINT still apply to us?** If yes, keep
   the old design -- it was shaped by the same pressure we have.
2. **Is the old thing merely CRUDER, with no compensating benefit?**
   Then take the newer one. Familiarity is a real benefit; so is not
   having to explain a wart.
3. **Does this hardware make something different cheap?** Then follow
   the machine, and match neither era.

Recorded so future decisions are made the same way, and so "why isn't
this V6-authentic?" has an answer that isn't a shrug.

---

## Register

### A1. `lseek` (V7), not `seek` (V6)
**Taken.** V6's `seek` took a 16-bit offset, which forced those odd
`ptrname` values 3/4/5 measuring in 512-byte blocks -- 16 bits could not
address a whole file. ProDOS's file mark is **3 bytes** (16MB), so a
long offset is natural here and the block-unit hack has no reason to
exist. Same pressure that made V7 rename it.
*Test 1: the constraint that shaped `seek` does not apply.*
See `docs/FLEET.md`, "`>>` and the seek family".

### A2. Bourne-style control flow (V7), not Thompson's `if`/`goto` (V6)
**Taken, 2026-08-21 -- supersedes `docs/SHELL-SPLIT.md` sec 12.** V5/V6 ran
the *Thompson* shell, which had no control-flow syntax: `if` and `goto`
were external binaries and loops were `goto` backwards past an `if`.
maux could implement that today for two small binaries and zero shell
changes (all three preconditions verified -- see SHELL-SPLIT.md sec 10).

**Declined anyway.** `goto`-structured scripts are genuinely worse to
write, `goto` cannot work interactively at all (a tty cannot seek), and
the Bourne shape is what everyone already knows.
*Test 2: the old thing is merely cruder.*

**Consequence, and it is not free:** `if` moves from a standalone binary
into the shell engine, because `if cmd; then ...; else ...; fi` needs the
shell to parse compound commands. That makes `docs/PLAN.md` wave 5 #1 a
real shell-language change rather than a small binary. `test` stays a
binary (as it is in POSIX), and is now needed alongside `if` rather than
after it.

### A2b. `test` only -- `[` cannot exist on ProDOS
**Forced by the machine, 2026-08-21.** POSIX ships the test builtin
under two names, `test` and `[`. **`[` is impossible here**: ProDOS
filenames may contain only letters, digits and periods and must BEGIN
with a letter, so no binary can be named `[`. Scripts write
`if test -f X`, never `if [ -f X ]`.
*Test 3: follow the machine -- though this one is not a choice at all.*

**RESOLVED 2026-08-21, better than a workaround.** The shell recognises
`[` in command position and drops the trailing `]`, so scripts may
write either form. `bash`/`dash`/`ash` all provide `[` as a builtin
anyway -- `/bin/[` survives on those systems only for POSIX conformance
when exec'd directly -- so this is **mainstream shell behaviour that
ProDOS forces us into early**, not a compromise. Scoping it also
corrected a costing error: `test` itself must be a BUILTIN here, since
spawn is length-driven and `BankCopy` is 75% of even a WARM spawn.
See `docs/SH-SUBSET.md` sec 6.

### A3. `od` defaults to hex bytes, not V6's octal 16-bit words
**Taken.** Octal 16-bit words are a PDP-11 artifact -- its word size and
its front panel. This is a byte machine.
*Test 3: follow the machine.*
Documented in `src/bin/od.s`'s own header.

### A4. `readdir` returns the whole entry, not `dirent`'s name
**Divergent from both eras.** Unix's `dirent` is essentially a name
because on Unix that is all a directory entry HAS -- the rest lives in
the inode, which is why `ls -l` must `stat` every file. ProDOS's entry
carries type, EOF, dates and storage type in the 39 bytes already read.
Copying `dirent` faithfully would force `ls -l` into a per-file stat
storm to recover data it had already discarded.
*Test 3: follow the machine.*
See `docs/FLEET.md`, "`readdir`: build the facade...".

### A5. Buffered stdio in liba
**Taken.** V6 had no stdio library at all; buffered streams arrive with
V7's `stdio.h`. maux's liba full-buffers file fds behind an unchanged
`PUTC` (2.06x on `ls` output).
*Test 2, plus a hardware reason: syscalls here cross a bank boundary,
so per-byte I/O is disproportionately expensive.*
See `docs/PROCIO.md` sec 4. Note this one has bitten twice -- both hazards
sat on the boundary the buffering created (LC-bank state, and
flush-vs-close). Anachronisms have costs; that is why they get recorded.

### A6. Sticky binaries cached automatically
**Exceeds V6.** Classic Unix needed the sticky *bit* set per program by
hand. maux caches any program that has run, no bit required.
*Test 3: cheap here because a bank IS a process image.*
See `docs/STICKY.md`.

### A7. A self-hosted assembler and linker
**Exceeds V6.** V6 shipped `as`/`ld` as fixed binaries; nothing in V6
assembled itself. maux runs a real Merlin-8 core inside its own process
model, byte-identical to the reference toolchain.
*Not a fence question -- a project goal (task #8).*

### A8. Mixed-case filenames
**Exceeds the ProDOS 8 era.** Names go through GS/OS case bitflags, so
`bigFile.BIN` survives as typed. ProDOS 8 proper is upper-case only.
*Test 3: the filesystem already carries the flags; using them cost
"almost nothing" (`docs/USERLAND.md`).*

### A9. `getopt` as a LIBRARY
**Unregistered until 2026-08-21 -- found while writing sec W.** V6 and V7
utilities parsed flags ad hoc, each in its own way; `getopt(3)` is a
System III facility (1980), post-dating both. maux's `src/liba/getopt.s`
is therefore an anachronism nobody had recorded.

**Kept, easily.** Flags themselves are V6-normal -- `ls -l` is period
-correct. What is modern is having ONE parser instead of eleven
hand-rolled ones, and that is exactly test 2: the old way is merely
cruder, with no compensating benefit, and the duplication it produces
is the drift risk this project already writes gates against.

Recorded because an unregistered departure is how a fence quietly stops
meaning anything.

### A10. Command substitution is `$(...)`, not V7's backticks
**Taken, 2026-08-21.** V7 Bourne spelled command substitution with
**backquotes** -- `` `cmd` ``. POSIX added **`$(cmd)`**. maux ships
`$(...)` **only**; a backquote is an ordinary character in a word.

This is the first entry where the fence question is *purely* about
spelling -- both forms name the identical semantics -- so the three tests
are the whole argument.

**Test 1 -- does the old design's constraint still apply?** No. The
backquote exists because the Thompson/Bourne lexer had one character to
spare and no appetite for a two-character opener. Our lexer is a
hand-written scanner in 6502 that already special-cases multi-character
operators (`>>`, `&&`, `||`, `<<-`); a two-character opener costs it
nothing it does not already pay.

**Test 2 -- is the old thing merely CRUDER?** Yes, and measurably:

- **Backquotes cannot nest.** `` `a `b` ` `` is unparseable; you escape
  your way out with `` \` ``, and the escaping rules inside backquotes
  are the single most notorious wart in Bourne syntax. `$( )` nests by
  construction. v1 *refuses* nesting (see below) -- but refusing is a
  budget decision that a later version can simply lift, whereas
  backquotes would have foreclosed nesting permanently. Choosing the
  spelling that can grow is free today.
- **`` ` `` is visually ambiguous** with `'` at 40 columns on a IIe.
  `$(` is not confusable with anything.
- **Familiarity**, which sec 0 explicitly counts as a real benefit: `$( )`
  is what every shell user under about fifty types first.

**Test 3 -- does this machine (this codebase) make something different
cheap?** **Yes, and this is the argument that actually decided it.**
`sh` already has a `$`-expansion pass -- `WORDEXPAND`/`DOEXPAND`, with
`$?`, `$#`, `$0`-`$9` and `$NAME` hanging off one dispatch on the byte
after `$`. Spelling substitution `$(` puts it in that pass, and it
inherits, **with no code written for any of them**:

- `'...'` suppresses it (`WORDEXPAND` returns before the substitution
  scan);
- `"..."` does not;
- an unquoted `<<WORD` here-doc body gets it (`CPTR_HEREDOC` expands
  each body line through `WORDEXPAND`), and a `<<'WORD'` body does not
  (that path never calls `WORDEXPAND`);
- the `EXPBUF` splice, its bump allocation, and its truncation clamp.

A backquote is not a `$`, so it would have needed a **second**
recognition site with **its own** copy of every rule above -- four
behaviours re-derived and re-tested in a second place, in a file whose
own history (`SH-FEATURES.md` sec 11) is a list of rules that reached two
of three consumers. **The newer syntax is the cheaper one here**, which
is not usually how this register goes and is worth recording precisely
because it is the reverse of the expected shape.

**What v1 refuses, loudly:** a nested `$( $( ) )` and a `$(` with no
closing `)` each print `sh: $(): unclosed, or nested`, set a nonzero
`$?`, and abandon the line. Nesting needs a second capture buffer and
argv array live at once, which is the re-entrancy the design avoids by
construction. Recorded as a v1 scope cut, not as a property of the
syntax: the syntax is the one that *can* nest, which is half of why it
was chosen.

**Not taken, and deliberately: backticks as a second accepted spelling.**
Two syntaxes for one meaning is exactly the "explain a wart" cost test 2
exists to avoid, and it would cost the second recognition site anyway.
A script written for V7 will need one edit. That is the correct trade
under sec 0's governing principle: *the fence is a taste guide, not a
museum.*

*Tests 2 and 3, agreeing.* See `docs/SH-FEATURES.md` sec 14.

---

### A11. No current directory in the default search path

V7's default `PATH` is `:/bin:/usr/bin` -- the leading empty field means
**the current directory, searched first**. maux's `PATHTAB`
(`src/liba/pathtab.s`) is `/BASIC/BIN/:/BASIC/` and has no such entry,
and `src/liba/pathres.s` skips an empty entry rather than treating it as
the cwd. That is a divergence and was unrecorded until now.

**The usual modern justification does not apply here, and should not be
offered.** Dropping `.` from `PATH` is a MULTI-USER security measure: it
stops someone leaving a trojan `ls` in a shared directory you might `cd`
into. A single-user Apple II running your own floppies has no such
threat, and citing it here would be borrowing an argument from a machine
this is not.

**Test 3 decides it -- the hardware makes the old design dangerous for a
different reason.** maux's spawn does **no file-type check**: grep the
kernel for `GFI_TYPE` or `STORAGE_TYPE` and there is nothing.
`PRC_LD_FL_IMG` OPENs whatever the path names, reads it, and jumps to
`LOAD_BASE`. So a cwd entry means *any file in the directory you happen
to be working in* whose name matches a command word is loaded and
executed as code -- and the working directory is precisely where the
DATA is: sources, outputs, `ed` scripts.

That is not hypothetical on this machine. 2026-08-26 produced exactly
that failure from the other direction: a one-byte image containing a
lone `rts` was spawned as a program, returned through an empty stack to
`$0000`, and ran zero page as `BRK` opcodes
(`docs/SPAWN-BANK7-CRASH.md`). Executing a non-program is a crash here,
not a permissions question.

**The honest summary:** V7 was right for V7, `.`-first is convenient,
and the reason to leave it out is neither fidelity nor security but that
this kernel will run anything you point it at. If spawn ever learns to
check the file type, this entry should be revisited rather than assumed.

*Test 3.* See `src/liba/pathtab.s`, `src/liba/pathres.s`.

### A13. `command` and `type` -- two builtins V7 Bourne never had

**Taken, 2026-09-16** (`docs/SH-FEATURES.md` sec 29). V7 `sh(1)`'s NAME
line lists its builtins exhaustively and there are twenty-one of them:
`: . break continue cd eval exec exit export login newgrp read readonly
set shift times trap umask wait`
(`learning:01M10WZW2BWWX6X4DYF4E5AD3D`, read from the manual). Four of
the six this pass shipped are on that list. **`command` and `type` are
not.** `type` arrives in System III; `command` is POSIX-era.

*Test 1 -- does the old design's constraint still apply?* There was no
design. V7 simply had no way to ask "what will this word run", and the
answer people used was `ls -l /bin/NAME` -- which on this machine means
knowing `PATHTAB`'s two entries by heart.

*Test 2 -- is the old thing merely cruder?* There is no old thing to be
crude. The gap is a gap.

*Test 3 -- does this machine make something different cheap?* **Yes,
and it is the argument.** maux's shell has more builtins than V7's
(twenty-six, including `test`/`[`/`echo`/`jobs`/`getopts`), and several
of them -- `echo`, `test`, `kill` -- ALSO exist as binaries on the
volume, with the builtin winning. On V7 you could tell by knowing the
list; here the list is longer, the overlap is real, and `type ECHO`
answering "a shell builtin" versus "/BASIC/BIN/ECHO" is the difference
between two genuinely different programs running. The resolver it needs
(`BUILD_PATH`) already exists for the spawn path, so the cost is the
name table and the wording.

**What was NOT taken**, and deliberately: `alias`/`unalias`, `fc`,
`hash` and `umask`. `hash` would report on a cache the shell already
manages correctly by itself; `umask` has no ProDOS meaning
(`docs/ANACHRONISMS.md` W2); `fc` belongs with a real history feature,
under its own name, when that lands.

*Test 3.* See `src/bin/shsgblt.s` (`BLTTAB`, `SB_ISBLTN`, `SB_WHAT`).

---

## sec W. The wishlist -- what to backport, what to forgo

Opened 2026-08-21 at the operator's request: "stick with v6 features and
maybe we start an anachronism wishlist -- things we might backport from
v7 and things we definitely have to forgo as not a good fit."

**The default is V6.** Everything below is a departure argued
individually against sec 0's three tests, not a general licence.

### W1. Backport candidates -- V7 (or later) worth taking

| item | era | test | why |
|---|---|---|---|
| **`2>` / `N>` fd redirect** | V7 Bourne | 2 | V6 has **no way to capture stderr at all**. That is crude rather than principled, and it blocks the quickfix loop `docs/IDE.md` names as the point of the editing arc. ~200 B. Highest value per byte we have found. |
| **Environment variables** | V7 | 2 | **TAKEN AND LANDED 2026-08-22 -- see Pending, below.** The operator's own "environment gap". V6's answer -- pass everything positionally -- does not scale to a system with a search path, and `sh`'s `PATHTAB` ~~is~~ was hardcoded precisely because there was nowhere to put it. |
| **`dup2`** | V7 | 1 | V6 had `dup` alone and the "close then dup to get fd N" idiom, which is racy on a real system and merely awkward here. Cheap, and it makes `2>&1` expressible. |
| **`sed`** | V7 | 2 | **CLOSED 2026-08-23 (p/d/q/s), UPLIFTED TO THE FULL POSIX COMMAND SET 2026-09-11 -- see W5c and `docs/SED.md`.** maux has `ed` and `grep` but nothing that edits a *stream*. In a pipeline-capable system that is a real hole, and it is the tool a build script reaches for most after `grep`. Sizeable; wants the regex engine that already exists. |
| **`make`** | PWB/V7 | 3 | `docs/SELFHOST-CONVERSION.md` splits the tree into 20+ compilation units. A hand-written `sh` build script is fine now and will not stay fine. Revisit once the unit count makes the script unmanageable -- that is the evidence to wait for. |
| **Background jobs (`&`)** | V7/csh | 2 | **MOVED HERE FROM FORGO, 2026-08-21 -- see W4.** The machinery already exists: a process reading the tty with nothing buffered calls `PRC_BLCK_RTRY` on `TTY_RD_CHAN` and the scheduler runs someone else. A human thinking at a prompt is the largest idle-CPU source on any interactive machine. |
| **`tail -f`** | V7 | -- | Needs a concurrent writer to a *file* -- which background jobs now supply. Follows `&`. |
| **Regex `\(`...`\)` + `\1`-`\9`** | V7 | 2 | **CLOSED 2026-09-02 -- see W5.** Landed in `src/liba/regex.s`, the ONE shared engine, so `ed`/`ex`/`grep`/`sed` all got it in one change. |

### W2. Forgo -- a bad fit for THIS machine

Each is declined for a reason specific to maux, not because it is hard.

| item | era | why it does not fit |
|---|---|---|
| **Subshells `( ... )`** | V7 | Need a fork-like spawn. **maux's processes are BANKS, not copies** -- there is no cheap "same program, new address space", because the address space *is* the program's home. This is architectural, not a gap. |
| **Shell functions** | System III | Not V7 anyway, so declining costs nothing in fidelity -- and a script calling a script is what V7 users actually did. |
| **`awk`** | V7 | A full language runtime -- lexer, parser, interpreter, associative arrays -- inside a 46,848 B process image, on a machine whose reason to exist is assembling 6502. The cost/benefit is not close. |
| **Named pipes (FIFOs)** | System III | ProDOS has no directory entry type for them. Would require inventing filesystem semantics the host OS cannot represent, which breaks interoperability with every other ProDOS tool. |
| **The Unix permission model** (`rwx`, owner/group/other) | V6! | **Older than our fence and still wrong here.** ProDOS's access byte is a genuinely different model -- destroy/rename/backup/write/read bits, no ownership at all, because there are no users. Mapping `rwx` onto it would be a lie in both directions. `learning:01M0798FFCHB60SWQDE8NQEQXN` records how GNO/ME faced this and chose the ProDOS model; follow that. |
| **Swapping / virtual memory** | V6 | V6 swapped whole processes to disk. Here the bank IS the process and banks are not pageable; with 14 of them and a 1 MB card there is nothing to relieve. |
| **`termcap` / `terminfo`** | V7 | Two terminals exist on this machine, both known, both already driven directly (`docs/CONSOLE.md`). A database to describe them would be more code than the two drivers. |
| **`tar` / `cpio`** | V7 | Archiving is a host-side concern; `a2til` already does it, and better, from a machine with a filesystem that can hold the archive. |

### W5. The regex ladder, measured

Recorded 2026-08-21 because "how far short are we?" deserved a number
rather than an impression. Read out of `src/liba/regex.s`, not inferred
from its header.

**Have:** literals, `.`, `[...]` with negation and ranges, `*`, `\`
escape, **both anchors** -- `^` at `RE_MATCH`'s entry, `$` in
`RE_MATCHHERE` -- and, as of 2026-09-02, `\(`...`\)` grouping with
`\1`-`\9` backreferences (below).

**Absent** (zero occurrences in source): `\{n,m\}`.

| against | gap |
|---|---|
| **V6** | **none -- level** (V6 never had grouping/backrefs either; this landing is a step AHEAD of V6, not just even). |
| **V7** | **none -- level**, as of the 2026-09-02 landing (below) -- V7 is where grouping/backrefs were documented (W1's original entry), and maux now has them too. |
| **POSIX BRE** | intervals `\{n,m\}`, bracket classes `[[:alpha:]]`/`[[=a=]]`/`[[.a.]]`, + **specified edge-case semantics** |

**The third POSIX item is still the real distance.** Leftmost-longest
overall rather than greedy-per-atom; `*` literal at the start of an
RE; `^` special only at the start; `$` only at the end; `]` first in
a bracket expression being literal. Features are easy to name and
cheap to count; **semantics are where an engine written to work and
an engine written to a specification diverge**, and they are most of
what a conformance corpus tests.

So the honest position, as of 2026-09-08: **V6/V7-complete, three POSIX steps behind --
the third being semantics, not syntax.** (Superseded 2026-09-11: W5d closed the bracket classes and the semantics. See W5d for the label now.)

Intervals and bracket classes sit outside the fence entirely and
would need test 2 argued for them rather than assumed --
`docs/DEMOS.md` sec 8 proposes running a real POSIX corpus to turn all
of this from an estimate into a scoreboard.

**Fence-move ruling, 2026-09-08 (operator): intervals `\{n,m\}` are
ADOPTED as a sanctioned anachronism.** The argument test 2 asked for is
that on THIS axis fidelity buys nothing: period-accuracy is load-bearing
for hardware/firmware (it catches real bugs), but a userland regex
feature honors no era constraint and catches no bug -- v7 strictness here
only withholds a useful feature that is cheap to build (it reuses the
backtracking greedy-star already in `regex.s`; `\+`/`\?` fall out as
`\{1,\}`/`\{0,1\}`). So we take it. **Scope and honesty:** this is
intervals-AS-ANACHRONISM, NOT a POSIX-BRE conformance claim -- the third
POSIX step above (semantics: leftmost-longest, `*`-literal-at-start,
positional `^`/`$`) stays out, so maux becomes **"V7 + intervals,"
labeled as such**, not "POSIX BRE." Bracket classes `[[:alpha:]]` remain
outside the fence (no ruling made for them). Build brief:
`docs/REGEX-BRE-INTERVALS.md`; the landing note is W5b, below.

### W5b. BRE intervals `\{n,m\}` + `\+`/`\?`, landed 2026-09-08

Built to the brief in `docs/REGEX-BRE-INTERVALS.md`, on the same shared
engine (`src/liba/regex.s` + `regex2.s`), as a STRICT SUPERSET: any
pattern that does not use `\{`, `\+` or `\?` matches byte-identically
to before. **The honest label is "V7 + intervals," not POSIX BRE** --
nothing about leftmost-longest, `*`-literal-at-start or positional
`^`/`$` changed (W5's un-ruled third step), and bracket classes
`[[:alpha:]]` remain outside the fence.

**What landed:** `\{n\}` (exactly n), `\{n,\}` (n or more), `\{n,m\}`
(n to m), and the aliases `\+` (= `\{1,\}`) and `\?` (= `\{0,1\}`), on a
single atom (literal, `.`, `[...]`) AND on a `\(...\)` group. BRE
spelling both ways: `\{` is the operator and a bare `{` stays a literal
brace; `\+`/`\?` are the operators and bare `+`/`?` stay literal, as
they always were. Bounds are capped at **RE_DUP_MAX = 255** (POSIX's
floor for it): a bound past 255, `\{,m\}` with no n, `m < n`, or a
missing `\}` makes the pattern a safe no-match -- the same treatment a
malformed `[...]` already gets -- so `\{1,999999\}` is refused, never
attempted. `\{0\}` is a real ceiling of zero (matches the empty
string), not an unbounded sentinel.

**The brief's one open question -- does the per-count backtrack
generalise to a floor/ceiling? -- answered by building it: yes, and more
cleanly than "star with two counters" suggested.** `RE_MATCHSTAR`'s
backtrack loop already walks its candidate pointer DOWN from the greedy
end to a FLOOR pointer, `RE_STARTTXT`, which for a star is the text
position where the atom began (0 reps). An interval only moves that
floor: the counted greedy scan (`:gcount`) stores the position just
past the `RE_RMIN`-th rep into `RE_STARTTXT` as it passes it, and fails
outright if the run ends short of the floor. The ceiling lives entirely
inside the greedy scan (stop growing at `RE_RMAX` reps). So the state
saved across the recursive `RE_MATCHHERE` call did not grow by a byte:
`RE_RMIN`/`RMAX`/`RINF`/`RCNT` are consumed before the first recursion
and never restored. `RE_GSTAR` (the group repeat) generalised the same
way -- its redo loop counts down to the floor instead of to 0, its
greedy scan stops at the ceiling -- with one wrinkle: the group's own
CONTENT goes through `RE_MATCHHERE`, whose operators overwrite
`RE_R*`, so `RE_GSTAR` takes private copies (`RE_GRMIN`/`GRMAX`/`GRINF`)
at entry. Its existing 8-rep greedy cap (`RE_GSCAP`) is unchanged, so a
group interval with a floor above 8 can never be met -- the star's
"possibly-shorter greedy extent" cap, now visible as a floor miss.

**Mechanism:** a new decoder `RE_REPOP` (regex.s) runs after every
atom and after every `\)`: it recognises `*`, `\+`, `\?`, `\{...\}`
(digits via `RE_RDNUM`, an 8-bit reader whose overflow IS the cap),
sets `RE_RMIN`/`RE_RMAX`/`RE_RINF` (RINF = no ceiling) and steps the
pattern pointer past the operator. A bare `*` decodes to floor 0 / no
ceiling and `RE_MATCHSTAR` sends exactly that shape down its
pre-existing specialised loops (`:glit`/`:gdot`/`:greedy`), so a
pattern without the new operators never executes a new instruction in
the greedy scan -- that one branch is the strict-superset argument.
The disjoint-atom fast path gained one guard: a continuation literal
under `\?` or `\{0,..\}` can match zero reps (the same hole a starred
continuation always had), so it backtracks instead. Seven new zero-page
cells at `$D4-$DA`, a third regex window, checked free of every
non-kernel `equ`. Two merlin32 facts met on the way: `#"{"`, `#"}"`
and `#","` cannot be written as character literals (they are `$FB`,
`$FD`, `$AC` -- HIGH-bit, because every `"x"` literal in this tree
assembles high-bit, which is the maux text convention).

**Strict-superset proof:** `check-ed`, `check-ex`, `check-sed`,
`check-e2e` (178 host-differential cases, the pre-existing `a*al`,
`a.*t`, `\(..\)\1`, `^\(ab\)*$` regex cases among them) all stayed
byte-exact green; `check-all-cross` green (75 gates), `check-dialect`
(the static dialect-intersection scan) and `check-modules` (64-char
lines, boundary rules) among them. **Real Merlin has NOT yet assembled
this code, and no runnable gate proves it has:** `check-dual` (green)
byte-compares the KERNEL only (its unit list is PTEST + DIFF, neither
of which puts regex.s), and `check-librel` -- the gate that does
assemble every liba module's REL form under Merlin-8 2.59 -- is in the
parked native cluster and currently refuses at its pre-flight on
`src/kernel/process.s` (`P_PTR3`, a cross-module-used equate, there
since 2026-08-14 -- base content, untouched by this landing). The
dialect discipline in the new code is by inspection: locals <= 12
chars, 64-char lines, `stz` (already used across liba), numeric
`$FB`/`$FD`/`$AC` where merlin32 refused `"{"`/`"}"`/`","` as
character literals. (check-librel was retired 2026-10-18, RULINGS-1: there
is no gate to run; check-nas-librel covers the REL form.) **Gates with teeth:** `check-regex`
(`scripts/check_regex.py`, the forms a human types -- `echo | sed` and
one `ed` session, since ed/ex/vi/grep/sed share the engine) went **9 of
11 RED on `6aca6f0`** (the base without the feature: `\{` was a literal
brace, `\+` a literal plus) and 11/11 green after; its `bigbound` and
`regress` cases are the cap and regression guards, green both sides.
The host-oracled half -- `\{n,m\}` and the bare `{`/`+`/`?` literals,
which macOS's BSD grep/sed agree on -- is nine new cases in
`scripts/e2e_corpus.py` under `check-e2e`. `\+`/`\?` could NOT be
host-oracled: measured 2026-09-08, this host's sed treats them as
literal (`s/ \+/ /g` is a no-op there), so they live in `check-regex`
with hand-authored expectations, said so in that file's header.

**Size:** regex.s stripped 10,720 -> 15,679 B (+4,959; it is now the
largest put -- regex2.s went 11,715 -> 12,214). Object code +322 B in
each of ed/ex/vi/grep/sed. Charged, as the brief predicted, to the
modules already pinned in check-dialect's `as`-window set (ed/ex/vi/
grep/sed -- all `AS_WINDOW_OVER` before this); real Merlin's 41,215 B
buffer is not approached (ed: ~3.7 K main + 15.7 K largest put).

Commons: `learning:01M1Y276TREPF2FK19FQ0AF0AQ` (why the engine is a
backtracker -- the reason intervals are a floor/ceiling on an existing
loop rather than new machinery) shaped the design.

### W5d. The engine is POSIX BRE now (C locale), 2026-09-11

Same day as W5c, operator's call ("OK, let's get it done"): the four
gaps W5's ladder listed are closed on the shared engine
(`src/liba/regex.s` + `regex2.s`), and the honest label moves from
"V7 + intervals" to **POSIX BRE, C locale, minus the per-subexpression
capture rules for equal-length matches**.

- **Bracket classes.** The twelve `[:name:]` classes, plus `[=c=]` and
  `[.c.]` as single characters (all the C locale has), inside
  `RE_CLASS_TEST`; the bracket skippers in `RE_ATOM_PARSE` and sed's
  `CUTRE` no longer take a token's own `]` as the close. An unknown
  name is an empty member, skipped -- undefined in POSIX, nothing worth
  a loud path.
- **Leftmost-longest.** When the pattern holds a `\(` -- the only BRE
  shape where the first greedy success can be shorter than the longest
  (`x*\(xy\)*` on `xxy`: greedy `xx`, POSIX `xxy`) -- the pattern-
  exhausted leaf RECORDS the end and a capture snapshot, then reports
  failure, so every backtracking alternative runs; `RE_MATCH` takes the
  longest at the leftmost start. A pattern without a group executes
  exactly what it did before, so the perf campaign's numbers stand.
  Equal-length matches keep the first found, which in greedy order is
  what POSIX's subexpression rule usually picks; that rule is the one
  thing not claimed.
- **Group repeats.** `RE_GSCAP` 8 -> 255: `\(ab\)\{10\}` was
  unsatisfiable before. The redo loop never had a per-rep buffer, so
  the cap was only ever the count's byte.
- **The star fast path** (`docs/REGEX-FASTPATH-GROUP.md`, open since
  09-08) learned that `\(`, `\)` and `\1`-`\9` are not literals --
  full backtracking there -- and that `\n` is the newline byte.
- **Anchors in groups.** `\(^a\)` and `\(a$\)` anchor, as both hosts
  do; POSIX leaves it open. Bare `*` first, `^` mid and `$` mid were
  already literal and now have cases saying so.

New cells live in `regexbss.s` (RE_PATEND, RE_LONGEST, RE_BESTSET,
RE_BEST, the 36-byte snapshot, RE_GSACT and the group repeat's private
RE_GSS/RE_GCC/RE_GNN), not zero page. Object growth +969 B in each of
grep/ed/ex/sed/vi (grep 4,494 -> 5,463). Alternation (`\|`) is a GNU
extension, not POSIX BRE, and stays out by the operator's own
preference.

**Then the operator: "if we're going to be real posix BRE we better run
the test suite."** `make check-fowler` (`scripts/check_fowler.py`) runs
the two spec-authored corpora through sed: Glenn Fowler's AT&T regex
tests (the `B` rows of basic.dat, nullsubexpr.dat, repetition.dat, in
the copies Go's regexp package carries) and Henry Spencer's (Tcl's
reg.test, the `b`/`&` rows without locale, non-POSIX or mode flags).
Expected match arrays are turned into `prefix{match}|g1..g9suffix`
lines and compared byte-exact. **109/109 runnable rows pass**; 28
regcomp-error rows are reported, not scored (maux has no compile
step: a malformed RE is a safe no-match); 75 rows need a newline,
8-bit byte, locale or mode flag a maux line cannot carry. The first run
was 90/109 and found, beyond a harness bug of mine, FOUR engine bugs:
- `RE_GROUPNUM` walks the pattern from its start and stopped at the
  temporary NUL `RE_GSTAR` plants over a `\)`, so every group AFTER a
  `\(..\)*` numbered as 0 and lost its capture (since W5a).
- `RE_GSTAR` kept its content/continuation/group-number in the `:gopen`
  dispatch's own cells, which a group inside the continuation rewrites
  -- after a failed continuation the count-down redo re-ran the WRONG
  content (since W5a).
- A leading `]` in a bracket expression was skipped as a member, so
  `[]a]` matched only `a` (since the first engine).
- POSIX's empty iteration: `\(a*\)*` must be able to take one more,
  empty, rep so a later `\1` is empty -- `\(a*\)*\(x\)\(\1\)`
  on `ax` is (0,2)(1,1)(1,2)(2,2). GNU sed fails these nullsubexpr
  rows; BSD passes; maux passes now.
check-posixsed's `regex` group (38 rows) and check-regex's grep case
stay green; check-ed/ex/e2e stay byte-exact for every group-free
pattern by construction; the full box sweep is green.

### W5c. sed uplifted to POSIX, and `\n` is the newline, 2026-09-11

`sed` now carries every POSIX.1-2008 command (`docs/SED.md`: `{}` `!`
`a i c` `b t :` `d D g G h H l n N p P q r s w x y =`, `-e`/`-f`, any
delimiter, `\1`-`\9` in a replacement, a 2047-byte pattern and hold
space). Under the W5 fence-move ruling (utility over period fidelity on
userland ergonomics) four GNU/2024 spellings came with it, each a named
DIVERGENCE row in `scripts/check_sed.py`: the one-line `a text`, labels
that stop at `;`, `s///Ng` (the Nth match and every later one), and
`q EXITCODE`. `N` at end of input follows POSIX and BSD (quit without
the autoprint), not GNU.

**One engine change**, in `src/liba/regex2.s`: the `\n` atom and the
`[\n]` bracket member match the pattern space's embedded newline (CR,
the maux text line end) -- POSIX sed's rule, and what a multi-line
`N`/`G` script needs. Before this `\n` was the literal `n`. Shared
engine, so `ed`/`ex`/`vi`/`grep` read it the same way; GNU ed does too,
and no gate corpus carried a `\n`. Strict superset for every other
pattern: `check-ed`/`check-ex`/`check-regex`/`check-e2e` byte-exact.
The honest label is unchanged -- **"V7 + intervals," not POSIX BRE**:
no bracket classes, greedy-per-atom.

### W5a. Grouping + backreferences, landed 2026-09-02

Implemented directly in `RE_MATCH`/`RE_MATCHHERE`/`RE_ATOM_PARSE`
(`src/liba/regex.s`) as a STRICT SUPERSET: any pattern that does not
use `\(`/`\)`/`\1`-`\9` matches byte-identically to before (proven by
`check-ed`/`check-ex`/`check-sed`/`check-e2e` all staying byte-exact
green). **The one deliberate semantic break**: before this change
`\(` matched a literal `(` (the generic `\X` -> literal-`X` escape
rule, same as `\.`/`\*`/`\[`); it is now a grouping operator -- the
same step real BRE-standard Unix took, and the existing gate corpora
were confirmed (by grep) to contain zero `\(`/`\)`/`\[1-9]` sequences
before landing, so nothing relied on the old reading.

**Mechanism** (`RE_ATOM_PARSE` gains AKIND 4=group-open,
5=group-close, 6=backref with `RE_ACHAR`=digit 1-9):
- `\(`/`\)` are NON-CONSUMING markers processed in the SAME
  `RE_MATCHHERE` loop as ordinary atoms -- no recursion for a plain
  (unstarred) group. Group NUMBER is computed FRESH every time by
  counting markers from the pattern start (`RE_GROUPNUM`), never
  kept as running state, because `RE_MATCHSTAR`'s backtrack
  re-enters `RE_MATCHHERE` from a DIFFERENT invocation per retry --
  any stack-based "currently open group" bookkeeping would not
  survive that split (this was checked, not assumed).
- `\(...\)*` (star on a WHOLE group, `RE_GSTAR`) greedily matches
  the subexpression as many times as it can, each attempt bounded by
  planting a temporary NUL at the matching `\)` and restoring it
  after -- so the UNMODIFIED `RE_MATCHHERE` loop supplies "pattern
  exhausted == success" for free, no stop-pointer plumbing added to
  the hot loop every consumer pays for. Backtracks the repetition
  COUNT (not a character) by RE-DERIVING each candidate count's text
  position from scratch rather than caching a checkpoint array -- an
  earlier version kept one and it cost a real size-budget regression
  (below). Capped at 8 repetitions; past the cap the greedy scan
  just stops growing (never a wrong match, only a possibly-shorter
  greedy extent). Nesting `\(...\)*` inside another `\(...\)*` is
  untested territory this feature does not claim.
- `\1`-`\9` (`RE_BKMATCH`) compares the captured
  `[RE_GRPST[n],RE_GRPEND[n])` byte-for-byte against the text at the
  current position. An unset group (never captured) fails safely
  rather than matching anything, via a `$FF` hi-byte sentinel
  `RE_MATCH` primes at its own entry on every call.
- **Known limitation**: `RE_GRPST`/`RE_GRPEND` for a starred group
  reflect the LAST rep of the greedy pass in every case except a
  backtrack to fewer reps, where they stay at the greedy pass's
  values instead of the winning count's own last rep -- stale, not
  wrong-looking. No required test combines that with a later `\N` on
  that group.

**A real size-budget lesson, worth keeping**: the first working
version stored `RE_GRPST`/`RE_GRPEND` (36 B) in `libabss.s`'s shared
`dum` arena, which EVERY program in the tree links -- including
`as.s`, which never links `regex.s` at all. `as.s`'s own `err
*/SYMADR` size tripwire had exactly 26 bytes of headroom before this
feature and needed 36, so `make build/as.bin` broke for a program
that cannot reach the feature. Fixed by moving the storage into a
new `src/liba/regexbss.s` -- a SEPARATE `dum LIBA_BSSEND` block that
only `ed.s`/`ex.s`/`grep.s`/`sed.s` `put` (repointing each of their
own trailing arenas to chain onto it instead of `LIBA_BSSEND`
directly) -- so a program that does not link `regex.s` pays nothing.
`check-modules`'s liba/program-boundary rule (a liba module may not
reference a symbol only a program defines) is what forced the
STORAGE itself to live in `src/liba/`, not inline in each consumer,
even though the SIZE problem was consumer-specific.

Feature teeth: `scripts/e2e_corpus.py` grep cases 111-113
(`\([a-z][a-z]*\) \1` word-doubling, `\(foo\)\1` plain doubling,
`^\(ab\)*$` group-star precedence), each sabotage-proven RED
independently -- reverting `\(`/`\)`/`\1`-`\9` to literal-char parsing
fails all three; disabling `RE_BKMATCH` alone fails only 111/112
(113 needs no backref); disabling the `\)*`->group-star dispatch
alone fails only 113 (111/112 use no star) -- then GREEN restored,
confirmed via `check-e2e` against `/usr/bin/grep` as the oracle.

### W3. How an item leaves this list

A forgo moves to a backport candidate only when its *reason* stops
being true -- not when someone wants it. `make` arrives when the build
script becomes unmanageable; `tail -f` follows background jobs. **Each
has a named trigger**, so the list is falsifiable rather than a matter
of taste.

### W4. Correction: background jobs were wrongly forgone

**Moved from W2 to W1 on the same day they were listed, 2026-08-21.**
The reasoning failed, and how it failed is worth more than the entry.

The operator's original observation was narrow and correct: *serious
parallelisation* buys nothing here, because without async I/O you
cannot overlap many processes for throughput. **I widened it into
"concurrency buys nothing", used that principle to decline a feature,
and propagated it into four documents.** The operator's correction:

> "only disk IO is genuinely synchronous. If my shell is blocked
> waiting on me to think something through, that's a lot of cpu time
> left on the table if there are no background jobs."

**Verified in the source rather than argued.** `src/kernel/tty.s`'s
read path: with nothing buffered it falls to `:block`, loads
`TTY_RD_CHAN` and calls `PRC_BLCK_RTRY` -- the process sleeps on a
channel and `SCH_SLEEP`/`SCH_WAKEUP` hand the CPU to whoever is
runnable. **maux already yields at the prompt.** The dead time is not
merely available, it is already being surrendered to nobody.

The distinction I flattened:

- **Disk I/O is genuinely synchronous** -- a ProDOS MLI call is
  non-reentrant firmware and blocks the machine. Unfixable from above.
- **Terminal reads are not.** A human at a prompt idles for *seconds
  to minutes*, which dwarfs every disk wait on the machine combined.
  Timesharing exists precisely to harvest this.

So `AS BIG.S &` while you keep working is the classic win, and an
assembler is CPU-bound between its disk ends -- exactly the shape that
uses think-time well.

**The real design question is not whether, but output.** A background
job writing to the tty scrambles the foreground display; Unix answered
with job control and `SIGTTOU`, which is a much bigger feature. The
cheap answer is to require background jobs to redirect their output --
`AS BIG.S > LOG &` -- and diagnose a bare `&` with unredirected stdout
rather than allowing the mess. That is a v1 shape worth having, and it
is what `docs/SH-FEATURES.md` should cost.

**Lesson for this register:** a principle derived from one true
observation is not itself observed. This one was stated, generalised,
and applied to a decline without anyone checking the scheduler -- which
takes one grep.

---

## Pending / undecided

- ~~**Environment variables** are V7 (Bourne-era), and the operator has
  flagged their absence as a real obstacle to hierarchical
  organisation. By A2's precedent this is likely to be taken -- but it
  is a bigger job than `if` and is not yet ruled. `docs/FLEET.md`'s
  "two separable steps, and the cheap one comes first" has the
  shape.~~ **RULED AND LANDED
  2026-08-22** (this register lagged the landing by a day; caught by
  the 2026-08-23 status audit, PLAN.md sec 0). The kernel carries an
  environment into the child bank sharing argv's block (`SYSCALL.md`
  item 13c), `sh` grew `export`, liba grew `getenv`, and `PATH`
  demoted the hardcoded `PATHTAB` from the only list to the default
  fallback -- `sh.s` keeps the table deliberately and says so in
  capitals at the definition site: a shell that cannot find `ECHO`
  because a script clobbered `PATH` is unusable, and this machine has
  no other recovery path. A2's precedent held: test 2, taken.
  Two residues stand in PLAN.md's known-bugs register: a nested `sh`
  does not inherit `PATH`, and `find -exec` passes a NULL environment.
- **`#!` interpreter lines** -- not V6, and not yet needed. Revisit when
  something other than `sh` wants to be scripted.

  **Why it is hard HERE, asked and answered 2026-09-20.** Five reasons,
  and only one of them is effort.

  1. **maux has no `ENOEXEC`, which is the hook `#!` hangs on.** On
     Unix, `exec` READS the file, recognises a magic number and
     dispatches; `#!` is one more magic number in a loader that
     already sniffs. maux's `spawn` sniffs nothing. It asks ProDOS for
     the file's `aux_type`, loads the whole file into a fresh aux bank
     at that address, and jumps to `LOAD_BASE` (`$0800`). There is no
     "this is not an executable" verdict to fall back from, because
     there is no verdict at all -- executability is the FILESYSTEM's
     `file_type`, and `src/kernel/procspawn3.s` never reads it. A text
     file happens to be refused, but for an unrelated reason:
     `aux_type` 0 is below `LOAD_BASE`, so `PRC_CHK_BASE` returns
     `ERR_INVAL`. A TXT file whose aux happened to land in
     `$0800`-`$BF00` would be loaded and jumped into. **That is worth
     fixing whether or not `#!` ever lands** -- one `GET_FILE_INFO`
     field the spawn path already fetches, never looked at.

  2. **The sniff costs an I/O on the one path built to have none.** A
     cold spawn already pays two directory walks (a `GET_FILE_INFO`
     for the aux type, then the `OPEN`), so reading the first chunk is
     nearly free THERE. But the warm respawn (`LZ_TRY_WARM`,
     docs/STICKY.md sec 25) never opens the file: it compares mod-date
     from `GET_FILE_INFO` and reuses the text already in the bank. A
     `#!` check on every spawn puts an `OPEN`/`READ`/`CLOSE` back on
     that path, unless the verdict is cached in the sticky tag -- new
     state with its own invalidation rules.

  3. **The path in a `#!` line cannot be true on this machine.**
     `#!/bin/sh` names something ProDOS cannot hold: no `/bin`, names
     upper-cased and at most 15 characters, every path volume-rooted
     (`/BASIC/SH`). So either maux ignores the path and always runs
     `sh` -- in which case it is not a shebang, it is a two-byte flag
     meaning "shell script" -- or it honours it, and every maux script
     carries a line no other Unix can follow while every script from
     elsewhere carries one maux cannot. Portability is the entire
     point of `#!`, and it is the thing that does not survive the
     crossing.

  4. **The magic bytes are not `$23 $21`.** maux text is high-bit
     ASCII; `shlex.s` matches `'#'` as `$A3`. On disk a maux script
     begins `$A3 $A1`. Any sniff has to know that, and any file moved
     between hosts has to be translated by something that also does.

  5. **It belongs to a bigger change that is already scoped.**
     Operator, 2026-08-30 (docs/S9-PLAN.md): past aux-as-metadata the
     destination is the a.out shape -- a magic plus an inline header
     carrying load address, entry and bss size, with `#!` as the OTHER
     branch of the same dispatch. Doing `#!` alone means building the
     file-sniffing loader and throwing away the half that pays for it
     (metadata that travels WITH the bytes, rather than in ProDOS
     type/aux fields that not every transport preserves).

  **And the reason none of it is urgent: the 90% of `#!`'s value costs
  nothing and needs no kernel change.** V7 did it before shebangs
  existed -- when `exec` refused the file, the shell forked a shell on
  it. `sh`'s `:notfound` path in `shblt2.s` already decodes one
  specific spawn error (`ERR_2BIG`, so a too-long argv does not report
  as "command not found"); a second case on `ERR_INVAL` that re-spawns
  `sh` on the pathname would make `./SCRIPT` work today. What `#!`
  buys ON TOP of that is choosing a DIFFERENT interpreter -- and maux
  has about two candidates. Which is exactly the trigger this entry
  has named all along: revisit when something other than `sh` wants to
  be scripted.
- ~~**Job control** (`&`, `jobs`, `fg`) -- csh-era. maux has a scheduler
  and real processes, so it is *possible*; nobody has asked for it.~~
  **SPLIT 2026-08-23 -- half of it HAS been asked for.** Background `&`
  moved to the backport list on 2026-08-21 (W4's recorded reversal)
  and is now queued work: PLAN.md stream S2 holds it behind `fork()`,
  which landed 2026-08-23 (`docs/FORK.md`; not yet wired into the
  shipping system). What remains genuinely unasked-for is the
  csh/POSIX remainder -- `jobs`, `fg`, `SIGTTOU`-style tty arbitration
  -- and that stays here until someone asks; W4 already records the
  cheap v1 answer (a bare `&` with unredirected stdout is diagnosed,
  not allowed).
  **ASKED FOR AND LANDED 2026-09-08** (`docs/JOB-CONTROL.md`,
  Increments A-C): `^Z`, `jobs`, `fg`, `bg`, `[n]+ Stopped` /
  `[n]  Done` notices, `[n] pid` on `&`, and W4's diagnostic (`sh:
  background output not redirected`) are in `sh` -- the csh/POSIX
  shape, taken because the operator asked and because the kernel's
  held-signal model (`docs/SIGNALS.md`) already made `^C` a driver
  sweep, so `^Z` was its twin, not a new mechanism. What is STILL
  here: `SIGTTIN`/`SIGTTOU` tty arbitration (Increment D, deferred
  on W4's redirect-or-diagnose answer), catchable `^Z` (deferred on
  SIGNALS.md's async-handler trigger -- a `^Z`'d full-screen program
  redraws on its next repaint, not before), and `%string` job specs.

## Emulator-side conveniences (not maux's, recorded so nobody "fixes" maux for them)

- **The emulated Super Serial Card's modem is infinitely fast**
  (2026-09-11, verilogapple e60be40). The 6551's guest-visible
  registers are honest -- one byte behind RDRF, one behind TDRE -- but
  the HOST side of each is a queue, so a burst in either direction
  never overruns and TDRE never drops. A real card at 9600 baud would
  overrun maux's 60 Hz poll and hold TDRE clear ~1 ms per byte; maux's
  driver (`SER_POLL` loop-drain, `SER_TXWAIT` busy-poll, no flow
  control) is written for the real card and merely never waits on the
  emulated one. Baud pacing from the CONTROL register is the fidelity
  knob, in the emulator, when a real-timing question needs it.

## What is NOT an anachronism (recorded to stop re-litigation)

- **`cd` as a shell builtin** -- this is V6-correct. `chdir(1)`'s own man
  page gives the same reason maux's `sh` does: a spawned child gets its
  own prefix, so a standalone binary would change its own cwd and exit.
- **Syscall numbers being raw MLI opcodes** -- not a fidelity question at
  all; a deliberate self-hosting decision from task #3.

### A12. Switches follow the MODERN CANONICAL spelling, not V6/V7's

**Taken, 2026-09-01 (operator):** *"grep almost certainly got a bit
different in sys3 and bsd and I'd prefer to choose the modern
canonical switches rather than slavishly mimicking v6/7 and breaking
the principle of least surprise."*

The general form of A10's ruling. Flag surfaces drifted between V7,
System III, BSD and POSIX; the fingers that will actually sit at
maux carry the MODERN muscle memory. Where the eras disagree, maux
ships the spelling a competent user types today, and the FLEET
friction audit RECORDS the V7 form beside it -- the drift is noted,
never silent (this register's own founding rule).

The three tests barely need running: a flag spelling is pure
surface (test 3 -- smallness/orthogonality are untouched), the old
spelling carries no constraint that still applies (test 1), and a
`-y` where every living hand types `-i` is crudity without
compensation (test 2).

Decided instances, recorded with their V7 forms:

| maux ships | V7 shipped | note |
|---|---|---|
| `grep -i` | `-y` | -y may be accepted quietly; -i is documented |
| `sort -k N[,M]` | `+pos1 [-pos2]` | POSIX key syntax; +pos not planned |
| `tail -n N` / `-N` | `+/-Nlbc` suffix forms | the bare `-N` habit survives everywhere; unit suffixes not planned |
| `uniq -f N` / `-s N` | `-n` / `+n` | POSIX field/char skips |
| `head` exists | (no head; `sed 10q`) | BSD-born, modern-universal |
| `more` exists | (no pager; `pr` to print) | same class, already ruled in FLEET |

The boundary: this ruling covers SPELLINGS and additive flags. It
does not import modern SEMANTICS wholesale -- grep stays basic REs
(no -E), ls stays single-column-less simplicity, and every gap is
still a deliberate FLEET verdict, not a GNU checklist.
