# make: closing the POSIX gaps, and the self-host limits they hold up

Status: LANDED, 2026-09-18. Numbers here are measured, not
planned.

`docs/POSIX-GAPS.md` has carried one row on `make` since the ledger was
written:

| have | POSIX wants | gap |
|---|---|---|
| `-f -n`, targets, deps, commands | macros, suffix rules, `-kisetqrp` | no macros at all; no `.s.bin:` suffix rules |

That row is not a conformance nicety. It is the reason maux's own
self-rebuild is bounded by numbers in `src/bin/make.s` rather than by
the machine:

* **`make nas-selfmake-image` FAILED on main.** The generated MAKEFILE
  was **244 rules / 40,133 B** against `MK_MAXRULE 240` and
  `MK_TXTSZ 28,672`. Measured 2026-09-18, docs/AS-PROFILE.md.
* Raising the caps is a stopgap and everyone knew it: the rule tables
  are X-indexed, so **255 is the ceiling**, and the roster that went
  46 -> 85 utils in a month is not done growing.

**It is now 98 rules / 18,587 B**, against caps of 192 and 22,528 --
and `MK_MAXRULE` came DOWN, from 240 to 192, because the count is no
longer the thing to watch. Two inference rules stand in for 512
assembly rules; 16 macros carry the assembler, the linker and every
liba module list more than one util shares.

The graph was that big because every one of the 512 assemblies was
written out longhand -- its own rule header, its own recipe, its own
copy of `/BASIC/BIN/NAS`, and its own copy of the eight-to-eighteen
liba modules on the link line beside it, twice (once in the
dependencies, once in the command). **Those are exactly the two things
macros and inference rules exist to remove.** Closing the POSIX gap and
unblocking the self-host build is one piece of work, not two.

## 1. What ships

Against IEEE 1003.1 `make` and V7 `make(1)` (the primary source is in
the commons: UNIX Programmer's Manual 7th Edition, artifact
`93e04c70...`, quoted below where it decides something).

| feature | status |
|---|---|
| macro definition `NAME = value` | yes |
| macro reference `$(NAME)`, `${NAME}`, `$X`, `$$` | yes |
| macros from the environment | yes (lookup fallback) |
| macros on the command line (`make CC=nas`) | yes, highest precedence |
| internal macros `$@` `$<` `$*` `$?` | yes |
| internal macros `$%` (library member) | no -- there is no `ar` |
| inference rules `.s1.s2:` | yes, and the leading dot is optional (sec 3) |
| single-suffix rules `.s1:` | no -- nothing here builds a suffixless target |
| `.SUFFIXES` (accumulate; empty list clears) | yes |
| `.SILENT` `.IGNORE` `.PRECIOUS` `.DEFAULT` `.POSIX` | yes |
| recipe prefixes `@` (silent) `-` (ignore) `+` (run under -n) | yes |
| `target: deps; command` | yes |
| `\`-continued lines | yes |
| `#` comment to end of line | yes on macro and rule lines; see sec 6 |
| `-e -i -k -n -p -q -r -S -s -t` | yes |
| `-f -` (makefile on stdin) | no -- see sec 6 |
| built-in suffixes and rules | none, and none wanted: no cc |
| parallelism, `include`, `::` rules, VPATH | no, and not POSIX |

There is still **no shell between make and the command** (sec 6). That
is a scope decision from the original header, unchanged.

## 2. Where expansion happens, and why it is not the obvious place

The obvious implementation expands the whole makefile once at read time
and parses the result. **It does not fit.** The expanded form of the
nas graph is ~28 KB whether or not the file on disk is 15 KB, and the
arena has 10,051 bytes of headroom above `$97BD` (measured from
`build/make.bin_Output.txt` at `ca2a006`). Expanding eagerly spends the
entire saving that macros just bought.

So expansion is **lazy and three-legged**:

1. **Targets** are expanded at parse time, but only a target containing
   a `$` costs anything: it is expanded into `MK_NAMES`, a 256-byte
   arena, and the rule points there. A target with no `$` -- which is
   every target in a generated makefile -- is still NUL-terminated in
   place in `MKTEXT` exactly as before. This keeps `MK_FINDR` a plain
   `STRCMP` over stored pointers; if targets were expanded at lookup
   time, every name resolution would cost an expansion per rule.
2. **Dependency lines** are stored RAW (a pointer at the text after the
   `:`) and expanded when the rule is walked, into a per-depth buffer
   `MK_DEPBUF`. The walk needs its parent's dep list to survive the
   recursion, so the buffer is indexed by `DEPTH`, like `MK_SAVEI`
   already is. `RULE_NDEP` therefore disappears as a parse-time
   quantity -- a macro can expand to any number of names -- and the
   count comes out of the expansion.
3. **Recipe lines** are stored raw and expanded at execution into
   `MK_CMDBUF`. This is forced rather than chosen: `$@` differs per
   target, so one inference recipe serves many targets and cannot be
   rewritten in place. It also fixes a latent wart -- the old
   `MK_SPAWN` tokenized the recipe IN PLACE, turning spaces into NULs,
   so a recipe was destroyed by its first run. Nothing noticed because
   no recipe ran twice.

Deferring command expansion is also the conforming behaviour: POSIX
evaluates macros in a command line when the command is executed, not
when the line is read.

**Arena arithmetic** (the whole reason the above is worth writing down):

```
  MK_TXTSZ   28672 -> 22528     -6144   raw file, not expanded form
  MK_MAXRULE   240 ->   192      -384   8 bytes of table per rule
  MK_DEPBUF    n/a -> 1024*8   +8192   per-depth expanded dep list
  MK_CMDBUF    n/a -> 1024     +1024   expanded recipe
  MK_NAMES     n/a ->  256      +256    targets that contained a '$'
  macro table  n/a -> 64*5      +320
  RULE_NDEP    240 -> gone      -240
                              --------
                                +3024   plus 3,861 B of code
```

Measured: the arena ended at `$97BD` before and ends at `$B435` after,
leaving 2,763 bytes under the `$BF00` overlay page. `MK_DEPBUF` is 1 KB
per depth because the buffers bound the EXPANSION, not the line: the
play kernel's own link line names 44 modules and expands to 989
characters however short the macro that wrote it is. Code growth pushes
`LIBA_BSSEND` up byte for byte, so the `err */$BF00` at the end of
make.s is the backstop, and it is not decorative -- it is what makes a
bad trade here a build failure instead of a corrupted overlay page.

## 3. Inference

V7 states the rule this design follows, and the ordering clause is the
part an implementation gets wrong:

> Prerequisites are inferred according to selected suffixes listed as
> the 'prerequisites' for the special name '.SUFFIXES': multiple lists
> accumulate; an empty list clears what came before. **Order is
> significant: the first possible name for which both a file and a rule
> as described in the next paragraph exist is inferred.**

So: `MK_BUILD` finds no explicit rule for `CATMR`; it walks
`.SUFFIXES` in order looking for a suffix `s2` that `CATMR` ends with;
for each, it walks `.SUFFIXES` again for an `s1` such that a rule
`s1s2` exists AND `stem + s1` exists as a file or has a rule of its
own. First hit wins. The stem (`CATM`) becomes `$*`, the source
(`CATM.S`) becomes `$<`, the target becomes `$@`.

**THE SUFFIXES NEED NO LEADING DOT, and that is what made this cheap.**
make joins the pair to name the rule and never takes it apart again, so
the period is a convention, not a requirement. maux's generated objects
are named `CATMR`, not `CATM.R`; with `.SUFFIXES: R .S RL.S` and rules
`.SR:` and `RL.SR:`, one pair of inference rules covers all 512
assemblies WITHOUT renaming a single generated file. The alternative --
renaming every object to carry a dotted suffix -- would have touched
the object names in 512 assembly lines, 118 link lines and two plan
files to buy exactly the same thing.

Order still decides: `.SUFFIXES: R .S RL.S` is walked in that order, so
`STRINGR` is tried as `STRING` + `.S` first (no such file) and then as
`STRING` + `RL.S`, which is the one that exists. A miss costs one
`GET_FILE_INFO`; a rule lookup that misses costs nothing at all, which
is why the rule is checked before the file.

An explicit rule with dependencies but **no recipe** also goes through
inference for its commands -- that is the `a.o b.o: incl` form in the
V7 page, and it is why inference is tried from `MK_BUILDI` as well as
from `MK_BUILD`.

Inferred targets get no entry in the rule table and therefore no
`RULE_MADE` memo. Re-deriving one costs a `GET_FILE_INFO`; running it
twice cannot happen, because after the first run it is no longer out of
date. That trade buys back the 240-byte table the memo would need and
keeps the rule count meaning what it says.

**A ProDOS accident worth naming:** a ProDOS filename must begin with a
LETTER (`learning:01M07G8WT2R3G2P87EK1DNPVYP`). So a name beginning
with `.` can never be a real file here, and make's "a target starting
with a dot is special" rule is unambiguous on this system in a way it
is not on Unix. That is also what keeps the dot-less suffix honest:
`.SR` still begins with a dot, because its FIRST suffix does.

## 4. What the generated MAKEFILE becomes

`scripts/build_librelas_image.py` (the `as` route; retired 2026-10-18) and
`scripts/build_nas_librel_image.py` (the nas route) both compose their
MAKEFILE. Both now emit macros and two inference rules instead of a
rule per assembly. Read off the real staged file:

```
A = /BASIC/BIN/NAS
L = /BASIC/BIN/LD
M0 = STRINGR MLIR STDIOR STDIOFLR PRINTR ARGVR GETOPTR SYSCALLSR LIBABSSR
M3 = STRINGR MLIR STDIOR STDIOFLR PRINTR ARGVR SYSCALLSR LIBABSSR
...
.SUFFIXES: R .S RL.S
.SR:
	$(A) -o $@ $<
RL.SR:
	$(A) -o $@ $<
ALL: ALLG0 ALLG1 ...
CAT: CATMR CATBR $(M3)
	$(L) -z -o CAT CATMR $(M3) CATBR
```

512 assembly rules become two inference rules. Each liba module list
is written once instead of twice per util that uses it.
`/BASIC/BIN/NAS` and `/BASIC/BIN/LD` are written once each instead of
630 times. **Not one generated file was renamed** (sec 3).

Two consequences worth stating, because both were found the hard way:

* **A unit that inference makes disappear takes its SIBLINGS with it.**
  A liba module that had to be split (`REGEXR` plus `REGEXP2R`) used to
  be built by one rule naming both. With that rule inferred away,
  nothing built the piece: the first make-driven run linked ten utils
  byte-identically and then died on `CSPLIT`, whose `ld` line named
  `REGEXP2R` and whose dependency list did not. The composer now closes
  every link's dependency list over the units inference removed.
* **Closing a list costs LENGTH, and the buffer is the limit.** The
  play kernel's 44 modules plus their pieces came to 1,123 bytes
  against a 1,024-byte `MK_DEPBUF`. A link whose closed list will not
  fit keeps its units' own rules instead -- which is what they had
  before inference existed -- and the composer asserts the EXPANDED
  length, not the written one.

The sources moved too, and that is a second win rather than a side
effect: a piece's source now sits in the same directory as its object
(`/BASIC/LIB/LIBK/KTTYRL.S` beside `/BASIC/LIB/LIBK/KTTYR`), because an
inference rule matches on the stem and the stem carries the path. That
took `/BASIC/LR` from 1,460 entries to 839, and ProDOS has no directory
index -- the walk of that directory IS this build's turnaround
(docs/AS-PROFILE.md: 470,048 cycles per dependency edge).

## 5. Gates

* **`make check-posixutil`, the 40 `make` rows** (`posixutil_cases5.py`).
  26 of them are DIFFERENTIAL against this host's own GNU make: each
  runs `make -n` over a fixture whose recipe names a command that
  exists on neither system (`ZORK`), so the printed line is a
  byte-exact readout of the whole expansion machinery -- macros, nested
  macros, command-line overrides, the internal macros, which inference
  rule was chosen and with what stem -- and nothing executes. The other
  14 are hand-authored for the reasons that module's docstring gives:
  they run a real recipe (the command differs by system), print the
  `-p` database (no specified format), or test the dot-less suffix form
  GNU make cannot express. 40/40, zero known gaps.

  TEETH. Eight rows went red on a deliberate sabotage (macro lookup
  made to always miss). Nine more were seen red on real bugs during the
  landing and green after the fix, which is the stronger evidence: the
  first dependency of every rule read as the empty string, `$?` walked
  into `PATHBUF` and printed `A.SEFILE`, expansion resumed at the last
  dependency NAME instead of after the `$?`, a continued dependency
  line produced a run of NULs that read as an empty name, `-q` answered
  0 for a build it could not judge, and `; cmd` echoed with its leading
  blank.

* **`make nas-selfmake-image`** -- the composer asserts every cap
  (`MK_TXTSZ`, `MK_MAXRULE`, `MK_MAXDEP`, `MK_MAXARG`, `MK_MAXMAC`, and
  the two expansion buffers) against `make.s`'s own equates, so a graph
  that outgrows them fails on the host, with the numbers, rather than
  inside the emulator. It FAILED on main; it builds now.

* **`make check-nas-selfmake` -- GREEN, 2026-09-18, and this is the
  milestone the rest of the page is in service of.** maux types `make`
  once, over a MAKEFILE of macros and two inference rules, and comes
  back with:

  ```
  MK2OUT empty -- the second make run had nothing to do
  byte-identical: 85 of 85 staged utils
  MAUXPLAY.SYSTEM (KERNEL, nas+ld -l k) 28921B byte-identical
  kernel images byte-identical: 1 of 1
  PASS
  ```

  All three assertions matter and they are different assertions. The
  85 say `make` ordered every one of 512 assemblies and 118 links
  correctly. The kernel says it did so in an order a directory-ordered
  library agrees with (sec 5b). **The empty MK2OUT says the freshness
  logic is real** -- a second `make -n` over the same tree printed
  nothing, so nothing was judged out of date that was not, which is
  the one property a build system exists for and the one a
  "did it run" gate cannot see.

  NOT in `CHECK_ALL_TARGETS`: the run is a world rebuild (21.35
  billion cycles) and does not belong in a sweep that has to stay
  runnable. The IMAGE BUILD half does -- see docs/TASKS.md #24.

* **`make check-selfmake`** (retired 2026-10-18) -- the `as` route's twin. Its bar is
  unchanged and its MAKEFILE is converted the same way, but IT CANNOT
  BE BUILT ON MAIN TODAY for reasons that have nothing to do with make:
  `regex`'s staged REL form is 19,854 B against `as`'s 16,126 B source
  window, and several kernel listings had gone stale enough that
  `generate()` refused them. Both are pre-existing and are recorded in
  docs/TASKS.md rather than fixed here.

## 5a. One byte, and why the byte-identity bar is the gate that matters

The first make-driven rebuild came back 84 of 85 utils byte-identical
to merlin32's. `MAKE` itself differed in **one byte, at offset 1,215:
nas+ld `$8F`, merlin32 `$90`.**

It is worth writing down what that byte was, because the obvious
reading was wrong. The line is

```
            lda   #>MK_NAMES+MK_NAMSZ-1     ; MK_NAMES = $8F13
```

and the obvious reading is a DIALECT divergence -- Merlin's `<`/`>` are
operand prefixes that apply to the whole expression, so "nas applied it
to the first term only" is a plausible story and was one search away
from being deposited as a nas bug. It is not. This is the $F8 REL
format's **external high-byte fixup**, already in the commons as
`learning:01M2PSVAFMJJQN1PMPVS0FPYZP`: the record keeps only
`$80 + high(addend)`, so when `low(SYM) + low(addend)` carries -- here
`$13 + $FF` -- the carry is unrecoverable and the linker computes
`high($8F13)` where a flat assembly computes `high($9012)`.

The fix is to leave the linker nothing to lose: equate the limit so the
prefix applies to a BARE SYMBOL, and do the addition in 6502
arithmetic, where the addend is zero as far as the fixup is concerned.
`make.s` carries `MK_TXTLIM`, `MK_DEPLIM`, `MK_CMDLIM` and `MK_NAMLIM`
for exactly that, and says why. The shape to grep for in any tree that
links REL pieces: `#<SYMBOL+expr` or `#>SYMBOL+expr` where SYMBOL
crosses a module boundary.

Nothing but a byte-for-byte comparison against a second assembler could
have found it. That is what the self-make gate is FOR, and it is the
reason its bar is byte-identity and not "it ran".

## 5b. A make-driven build and a script-driven build are not the same build

The second thing only byte-identity could have caught, and the more
interesting of the two.

`ld`'s `-l` is a real `-l`: a directory of REL objects, members taken
selectively by symbol, and -- `src/bin/ldlib.s`'s own header -- "the
fixpoint decides the SET, the DIRECTORY decides the ORDER". Directory
order on ProDOS is CREATION order. On a self-make image the objects do
not exist yet: **the guest creates them as it builds them, so the build
order IS the link order.**

The script route builds each unit main-first, then its split pieces.
The MAKEFILE's unit recipes were written pieces-first. Every one of the
85 utils still came out byte-identical -- and `MAUXPLAY.SYSTEM`, which
takes 40 members out of `/LIB/LIBK` through `-l k`, came out 28,921
bytes long, exactly the right length, and different from the first
difference at **offset 15**.

So: a graph that is correct, complete and in a legal order can still
produce a different image than the script it replaced, because one of
the tools downstream is order-sensitive in a way nothing declares. The
composer now emits main-then-pieces to match, and says why at the line
that decides it.

The general form, for anyone putting a `make` in front of an existing
build script: **any tool whose behaviour depends on the order things
were CREATED rather than on the order it was ASKED for them turns your
dependency graph's traversal order into part of the output.** A
dependency graph deliberately does not promise one.

## 6. Limits stated rather than discovered

* **No shell.** A recipe is split on spaces and spawned. No pipes, no
  redirection, no globbing, no `cd`. `;` separates a command from the
  target line, not two commands from each other.
* **`#` in a recipe is not a comment.** POSIX strips comments before
  the shell sees a command; with no shell here, the only safe reading
  is "a recipe line is the command". Comments are stripped from macro
  definitions and rule header lines only.
* **`-f -` is not supported.** make reads its makefile with `SC_OPEN`
  on a pathname.
* **Same-minute blind spot, unchanged.** ProDOS mod times have
  one-minute resolution, so a rebuild finished within a minute of its
  source's last write compares equal and is judged up to date. `-t`
  and touch(1) are the escapes; there is still no `-B`.
* **`$?` is computed, not remembered.** It re-stats each dependency at
  expansion time. That is the cheapest correct implementation here (no
  list storage at all), and on a volume where a stat costs 470,048
  cycles it is also the reason not to put `$?` in a hot recipe.
