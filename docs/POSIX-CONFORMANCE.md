# POSIX conformance: the scoreboard

*"The house wants the posix test suites as a monument to the achievement
this project actually is."* -- operator, 2026-09-13. This file is that
monument's plaque. The suites are the record; this page only states what
they measured, when, and at which commit. **Re-measure before changing a
number here:** `make check-posix` runs every suite, keeps each full log
under `build/posix/`, and renders the table below to
`build/posix/SCOREBOARD.md`.

## Measured 2026-09-17 at `40a9d5b` (main, on the box)

| suite | kind | what it measures | score | gaps |
|---|---|---|---:|---|
| `check-posixutil` | gate | 52 utilities -- cat cmp comm expr head grep mkdir pwd sleep true false (round one), wc tail uniq tr sort od find diff ls cp mv rm date touch du tee echo kill (round two), the `test`/`[` builtin (round three), `cut` (12 rows), `xargs` (16), `printf` (18), `basename` (6), `dirname` (5), `env` (8), `uuencode` (9), `uudecode` (10), `rmdir` (8), `tty` (3), `uname` (9), `cksum` (4), `paste` (6), `fold` (4), `expand` (4), `unexpand` (6), `nl` (11), `man` (6, two of them the not-applicable stub pages), `cal` (6), `strings` (9), `tsort` (7), `pr` (10), `pathchk` (6), `split` (4), `csplit` (9), `join` (10), and `patch` (12, round four); round five, 2026-09-17, retired 18 held-red rows rather than adding utilities -- `wc -m` and its multi-file totals, `tail -c`, `uniq -f`/`-s`, `od -j`/`-N`, `nl -l`, `date +format`, `cal`'s full-year layout, `touch -t`/`-r`, `kill -l`/`-s`, `du -k`, `tee -i`, `env`'s duplicate rule, `timeout`'s fractional seconds and `test`'s negative operands; round six, the same day, retired eight more -- `ls -d`/`-F`/`-s`/`-R`, `cp -p`/`-i`, `mv -i`/`-f` and `rm -i` -- each row keyed to a sentence of its XCU page; host binary as oracle, spec text where BSD/GNU deviate | **518/518** | 40 named rows, held red |
| `check-posixsed` | gate | sed(1) against the host sed, byte-exact, script and input as files | **138/138** | none |
| `check-fowler` | report | the shared BRE engine against the AT&T (Fowler) and Spencer regex corpora | **109/109** | 28 regcomp-error rows fail safe, unscored; 75 rows skipped (newline, 8-bit, mode flags) |
| `check-posixex` | report | ex(1) against /usr/bin/ex | **53/53** | none -- against the MAC's ex; see the note below |
| `check-posixvi` | report | vi(1) against vim | **64/66** | named registers; multi-line charwise yank |

**Where each number was measured.** The first three ran on the Linux
box (`sh scripts/box_gate.sh check-posix`), where the whole sweep runs.
The last two ran on the Mac, and that is a finding rather than a
preference:

* `check-posixvi` drives a real **vim** through a pty. The box has
  `vi` and `vim.tiny` and no `vim` at all, so the harness waits
  forever for a screen that never comes -- a 1,884-second hang, not a
  red. Nothing about maux is being measured there.
* `check-posixex` DOES run on the box and scores **45/53** with the
  box's own `/usr/bin/ex` (a vim.tiny alternative) against 53/53 with
  the Mac's. Neither number is about maux: eight rows are two `ex`
  implementations disagreeing with each other. The suite was authored
  against the Mac's oracle, so that is the score reported.

Both suites' SCRATCH default was a hardcoded
`/private/tmp/<session>/...` path belonging to one past session, which
made `make check-posix` die on the box with `PermissionError: '/private'`
before running a case. It is `build/posix/<suite>` now (fixed on main
the same day, a0b1dad, after the man-stub agent hit it too), which is
how the box could measure any of them.

**Gate** means the target must exit 0 and its known gaps are load-bearing
rows that must STAY red: a gap that starts passing fails the gate until a
human retires it. **Report** means a conformance report with an exit
status: a red row is a real divergence to read, not a ratchet to keep.

## What "conformant" means on this machine

One user, no network, no C compiler, ProDOS underneath, a 64 KB bank per
process, 7-bit ASCII with bit 7 set and CR line endings. Every suite
compares stdout bytes and exit status (and named result files) against a
real host implementation on identical input, translated at the text
boundary and nowhere else. Diagnostic wording is never compared: the
spec leaves it unspecified almost everywhere. Nothing is ever captured
from a maux run and pasted back as an expectation.

The regex engine is one engine: `src/liba/regex.s` serves ed, ex, vi,
grep, sed and more, so the Fowler/Spencer score is the score for all of
them.

## The named gaps, and why each is a gap

### check-posixutil (66)

| row | why |
|---|---|
| `cat -u` | cat.s parses no options; `-u` is a no-op on an unbuffered machine and is not yet accepted |
| `cat -` | a literal `-` operand is opened as a pathname, not read as stdin |
| `expr :` | the regex-match operator is outside expr's grammar by its own header |
| `expr ( )` | no parenthesis level in the grammar |
| `head -c` | head counts lines only |
| `grep -E` | ERE is out by ruling: BRE only (docs/ANACHRONISMS.md, operator 2026-09-11) |
| `grep -F` | fixed-string mode not implemented |
| `grep -f FILE` | pattern file not implemented; one pattern per run |
| `grep -e A -e B` | a second `-e` is refused loudly rather than silently last-one-wins |
| `mkdir -m` | ProDOS has no mode; the flag has no meaning here |

Round two (2026-09-14, 41 rows) added the option gaps docs/POSIX-GAPS.md
sec 2 already listed, now each a real expected-red row: `wc -m` and the
multi-file totals line; `tail -c`/`-f`; `uniq -f`/`-s`; `tr [:class:]`,
`-C`, equivalence classes; `sort -t`/`-o`/`-f`/`-b`/`-c`/`-m`; `od
-A`/`-j`/`-N`/`-t`; `find -newer`/`-prune`/operators; `diff
-u`/`-c`/`-r`/`-b`; `ls -d`/`-R`/`-F`; `cp -p`/`-i`; `mv -i`/`-f`; `rm
-i`; `date +format`; `touch -t`/`-r`; `du -k`; `tee -i`; `kill
-l`/`-s`. The full table with each row's reason is `KNOWN_GAPS2` in
scripts/posixutil_cases2.py. **Two of those retired on 2026-09-17**:
`diff -u` and `diff -c` are shipped and host-oracled now, leaving
`diff -r` and `diff -b`.

Round three (2026-09-14, `test`/`[`, 51 rows): `!`, `-a`/`-o` with `-a`
binding tighter, `( )` grouping, `-s`, `-r`/`-w` (ProDOS access bits),
`-x` (SYS or BIN file type), and `-b -c -g -h -L -p -S -u` constant-false
because ProDOS has none of those objects. One gap: negative integer
operands (the number parser is unsigned by design). Issue 8 lists
`-a`/`-o`/`( )` as removed; shipped anyway because every living `test`
carries them.

Later the same day `sort` closed six of its rows at once (`-t`, `-b`,
`-f`, `-o`, `-c`, `-m`; c66033b), leaving one: per-key modifiers such as
`-k2,2n`. Then `find` (9d33145) became a real POSIX expression -- `!`,
`-a`, `-o`, parentheses, short-circuit, the default `-print` rules --
with `-prune`, `-newer`, `-path`, `-size` and a calendar-day `-mtime`;
its three gap rows became one (`-ok -perm -user -group -depth`), and
the rewrite found `-exec {}` had been substituting nothing. `cut` arrived scored (a7092f4, 12 rows, no gaps); `xargs` (e3a6dd6, 16
rows) brought six named gaps of its own: `-0 -E -L -p -r -x -P`, none
POSIX-mandatory but `-r`, `-p` and `-x`, listed so they are not
forgotten (`-p` and `-x` are hand-authored rows: this host's own xargs
disagrees with the XCU text on both, so the spec is the oracle there).
`printf` (ed133f0, 18 rows) conforms in every conversion this machine
can represent -- `%d %i %o %u %x %X %c %s %%`, XSI `%b`, the flags,
width, precision, format reuse, the `\ddd` escapes -- and holds four
gaps that it cannot: `%e %f %g %a` need floating point, which the
machine does not have. `basename`, `dirname` and `env` (8953ff5, 19
rows) landed together: the two path tools are pure text arithmetic
host-oracled against BSD, and `env` proves the child receives the
merged environment by spawning `env` itself; its one gap is a
duplicate `name=value` on one command line, ordered rather than
removed. `uuencode` and `uudecode` (741d8a4 + 6c7db96, 19 rows, no
gaps) close the transport item: both alphabets, `-m`, `-o`,
`/dev/stdout`, a missing `begin` line and a malformed body each exit
1; their decode of arbitrary bytes is proven outside the text
comparators by round-tripping a binary through an independent
encoder. `rmdir`, `tty` and `uname` (d5e9d69, 20 rows, no gaps):
`rmdir -p` walks a chain and stops at the volume or the first
non-empty ancestor, a failed operand does not stop the rest (proved
by a follow-up `mkdir` in the same session); `tty` names the console
or the serial line from the kernel's own device table; `uname -a`
prints `maux apple2e 1.0 1.0 65c02` in the fixed order, where the
suite caught a missing separator before landing. `cksum`, `paste` and
`fold` (9f022dd, 14 rows, no gaps): the POSIX CRC with the octet
count folded in, verified against the host over the exact high-bit
bytes; parallel and serial paste with a cycling delimiter list;
column-mode fold with tab stops, backspace and `-s`. Their e2e rows
are the real proof (raw fixtures, host byte-exact). `expand`,
`unexpand` and `nl` (0a992a7, 20 rows): tab stops periodic and
explicit, the past-the-last-stop rule, backspace; unexpand's
whole-run rule, where the engineer's own gates caught a branch
reading a stale flag; nl's logical pages, formats, width, separator,
start and increment, with `-b pBRE` the 57th gap (no regex engine
within the tool's budget), and `-l num` the 58th, found at review
reading the page. The same review made two nl rows spec-authored:
BSD and GNU disagree on an unnumbered line's prefix and on whether a
delimiter line prints anything, and the XCU text decides neither.
`man`, `cal` and `strings` (dac2be8 + e40291e, 19 rows): man pages
through more when stdout is a tty and copies otherwise, with a live
pager phase in check-play; cal's month form is byte-exact against BSD
and its full-year three-column layout is the 59th gap; strings scans
both text conventions, and `-n` over 255 is the 60th. The cal and
strings `-t` rows are spec-authored from captured BSD output, since
the box has no cal and GNU strings pads offsets, on details the XSI
pages leave open. Net: 412 rows green, 60 gaps held red.

Round four (2026-09-17, 19 rows, no new gaps): `diff -u`/`-c`
(7 rows -- default width, the merge and the split across a 13-line
gap, `-U 1`, `-C 1`, an empty file1's `0,0` range, and the `-c`
section that prints its header and no body) and `patch` (12 rows --
all three listing forms detected rather than declared, including a
context listing whose second section is header-only; stdin and `-i`;
`-R`, `-b`, `-o`, `-p1`; a two-hunk listing whose first hunk shifts
the second; a hunk that matches nowhere, its reject file and exit 1;
and a patch file with no listing in it at all, exit 2). Every patch
row is hand-authored because patch(1) reports itself on STDOUT in
words BSD and GNU spell differently, so no expected stdout is right
on both hosts -- maux reports on fd 2 and the rows assert the FILES,
which is where POSIX puts the behaviour. A 20th row closes the loop:
maux's own `diff -u` output, fed to maux's own `patch`, must
reproduce the second file.

The seven diff rows are also the first users of `NORMALIZERS`
(scripts/check_posixutil.py): a named, both-sides-identical filter
that erases ONE unspecified field -- here the `--- FILE<tab>TIME`
header's timestamp, which POSIX leaves unspecified, which BSD and GNU
write differently, and which maux does not write at all (a ProDOS file
has no modification time worth quoting on a clock-less boot). Every
other byte, pathname included, still compares exactly. A `norm=` may
only ever name a field the spec leaves open; anything larger belongs
in `hand=` with its reason, as `ls -C` and `cmp -l` already are.

### check-posixvi (2)

Named registers (`"a`), and a charwise yank that spans a line boundary
splicing all of its text on paste. Both documented limits of vi.s.

### check-fowler (unscored, not gaps)

28 corpus rows expect a regcomp ERROR (unbalanced `\(`, `a**`,
`\{0,1`); maux's engine has no compile step and no diagnostic, it simply
fails to match. Reported separately as fail-safe.

## What the suites found, not just measured

Round two (2026-09-14) found that `kill -9 $$` typed at the interactive
shell hangs the console: the force path zombies the shell while it is
blocked waiting on `kill` itself, and `kill`'s exit wakes a zombie. Not
a row (it takes its boot group with it) and not patched: it needs a
ruling, refuse or respawn via an init.

Building `check-posixutil` on 2026-09-13 found three real bugs in tools
the gap survey had called conformant, all fixed the same day (9fce6eb):
cmp's differ message went to stderr where POSIX's STDOUT section puts
it; comm's column leads were fixed at one and two tabs instead of
adapting to `-1`/`-2`; comm's usage message had no line terminator, so
the shell's next prompt drew onto the same row and every at-prompt
predicate in the harnesses waited forever. A suite that only confirmed
what its authors believed would not have earned this page.

## How to read a change

* A gate goes red: either a real regression, or a gap that started
  passing. The output says which. Retire the gap row by hand; never
  widen a comparator.
* A report's score moves: update this table from `build/posix/
  SCOREBOARD.md`, with the commit, and name what changed.
* A new suite: add it to `SUITES` in `scripts/posix_scoreboard.py` with
  its kind and the regex for its summary line, and a row here.

Companion: `docs/POSIX-GAPS.md` (what is missing and what it would cost),
`docs/ANACHRONISMS.md` (what is declined and why).
