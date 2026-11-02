# POSIX gap analysis: maux's tools against POSIX.1-2024 (Issue 8)

Status: SURVEY, 2026-09-12, with per-row SHIPPED notes added in place
through 2026-10 (a row is current only to the date it carries; the
measured scoreboard is `make check-posix`, docs/POSIX-CONFORMANCE.md).
Operator: "a posix gap analysis across our
tools. include tools that posix mandates but we lack. Let's see what
the work would be to make this thing interestingly useful."

Same caveat as `docs/SH-FEATURES.md`: a survey goes stale the day it is
written. The maux column was measured from the tree (the `UTILS` roster
in the Makefile, each util's `usage:` string or header contract, and the
`*_STR` tables in `src/bin/sh*.s`), not recalled. The POSIX column is the
Open Group's Issue 8 utilities index (155 names, fetched live; the four special builtins `eval exec readonly times` are documented under `sh` and not indexed -- all four shipped 2026-09-16).

## 0. Inventory (as of the survey)

**At survey time two lines were open and neither contained the other**
(since merged; the current roster is the Makefile `UTILS` list). `posix-sed`
(this tree) has `reset`/`true`/`false`, POSIX `sed`, `more`, `tip`, job
control and the SSC. `proshim-maux-work` has `dd`, `bpatch`, `plasma`,
`proshim` and `nas`. Merge-base `874708b`, 46 and 49 commits apart. The
inventory below is the UNION as of 2026-09-12.

**Shipped binaries (82 in the union):** `as basename bpatch cal cat chmod chvt cksum cmp comm cp csplit cut date dd df diff dirname du echo ed env ex expand expr false file find fold grep head join kill ls make man mkdir more mv nl nm nohup od paste patch pathchk plasma pr printf proshim ps pwd realpath reset rm rmdir sed sh sleep sort split strings stty sum tail tee time timeout touch tr true tsort tty uname unexpand uniq uudecode uuencode vi vidmode wc xargs`.

**Shell builtins (24):** `. : bg cd command echo eval exec exit export
fg getopts jobs kill read readonly set shift test/[ times trap type
unset wait`, plus
`if/elif/else/fi while until for case break continue`, `( )`,
`$( )`, `<< <<-`, `>& N>&M >&- <&N <&-`, `${V}` and `${V-=?+w}`,
`$* $@ $# $? $$ $!`, `IFS`.

## 1. Scorecard against the 155

| bucket | count | names |
|---|---:|---|
| **Have** (binary or builtin) | 81 | basename bg cal cat cd chmod cksum cmp comm cp csplit cut date dd df diff dirname du echo ed env ex expand expr false fg file find fold grep head jobs join kill ls make man mkdir more mv nl nm nohup od paste patch pathchk pr printf ps pwd read realpath rm rmdir sed sh sleep sort split strings stty tail tee test time timeout touch tr true tsort tty uname unexpand uniq uudecode uuencode vi wait wc xargs |
| **Missing, small, applicable** | 0 | -- (`command` and `type` SHIPPED 2026-09-16, docs/SH-FEATURES.md sec 29) |
| **Missing, large, applicable** | 4 | awk bc m4 pax (`patch` SHIPPED 2026-09-17 -- in assembly, not PLASMA; see sec 2's own `diff`/`patch` rows. `ar` and `strip` moved to sec 5 the same day, for reasons of their own) |
| **Shell builtins missing** | 1 | fc -- DEFERRED: the command history lives in the console's readline in the KERNEL (VC_HIST_*, tty.s, 8 entries per console) and no syscall exposes it, so `fc` is a kernel task; sh answers `fc` with a loud refusal, status 2. `alias`, `unalias` and `hash` SHIPPED 2026-10-07 (docs/SH-FEATURES.md sec 30). The four SPECIAL builtins under `sh` -- eval exec readonly times -- SHIPPED 2026-09-16 with command and type (sec 29); getopts and unset SHIPPED 2026-09-15 |
| **Not applicable on this machine** | 63 | see sec 5 (`ar`/`strip` moved here 2026-09-17: `ld` links from library directories, not archives, and flat binaries carry no symbol table) |

`sum`, `as`, `chvt`, `vidmode`, `reset`, `bpatch`, `plasma`, `proshim`
are not POSIX names; `sum` was dropped from POSIX in favour of `cksum`.

## 2. Option gaps in the tools we have

Ordered by how soon a script writer hits them. Sizes are what the same
kind of change has measured at in this tree (`SH-FEATURES.md` sec 0:
shell features 150-600 B; a flag on a filter 50-300 B).

| tool | have | POSIX wants | the gap that bites | cost |
|---|---|---|---|---|
| `grep` | `-cilnqsvx -e` | `-EFcefilnqsvx` | **`-F`**, **`-f FILE`**. `-E` is out by ruling (BRE only) and is a recorded POSIX divergence | ~400 B |
| `test` | `-f -d -e -z -n = != -eq..-ge -s -r -w -x -b -c -g -h -L -p -S -u ! -a -o ( )` | (all shipped) | **SHIPPED 2026-09-14**: `!` was already in; this task added `-a`/`-o` (with `-a` binding tighter, historical/BSD precedence -- the live XCU page says Issue 8 removed these as obsolescent, shipped anyway since every real `test` still carries them and this project's own shell already passes a bare `(`/`)` through as an ordinary word) and `( expr )` grouping via a real precedence-climbing grammar (OR_EXPR/AND_EXPR/NOT_EXPR/PRIMARY, replacing the old fixed-arity EVAL_N2/EVAL_N3 dispatch); `-s` (blocks_used > 0 -- GET_FILE_INFO has no byte-exact EOF), `-r`/`-w` (ProDOS access byte's read/write-enable bits), `-x` (file_type SYS or BIN -- ProDOS has no execute bit); and the always-false `-b -c -g -h -L -p -S -u` (no such ProDOS object ever exists, so constant-false is the conformant answer, not a shortcut). Found and fixed a REAL pre-existing bug along the way: `test`/`[` is a shell builtin that dispatches BEFORE `RUN_PIPELINE` applies redirection (the same trap `shbltn.s`'s `CHCK_BLTN_ECH` documents for `echo`), so `TEST ... > FILE` silently created nothing; `TST_REDIR` (src/bin/shparse.s) now opens-then-closes the plain fd-1 target. sh.bin 20678 -> 21109 (+431 B); SH_BUDGET 20736 -> 21160. **SHIPPED 2026-09-17**: negative integer operands -- `STR2NUM` takes an optional leading `-` and two's-complements the magnitude, and `CMP16` became a real SIGNED 16-bit compare (SBC + the N-xor-V overflow-correction rule, not the old unsigned hi-byte-then-lo-byte CMP chain), so `-lt`/`-gt`/`-le`/`-ge` order negatives correctly, not just `-eq`/`-ne`. sh.bin 26,233 -> 26,325 B (+92). | ~300 B (priced), 431 B (actual, `-a`/`-o`/`( )`) + 92 B (actual, negative integers) |
| `sort` | `-bcfmnrtu -kN[,M] -oF` | `-cmoudfinrbtk` | **SHIPPED 2026-09-14**: `-t C` (field separator for `-k`; without it, blank-run fields as before), `-b` (ignore leading blanks in a key), `-f` (fold case for comparison only), `-o FILE` (may name an input -- every byte is read before FILE is opened/truncated), `-c` (check order; first out-of-order line to fd 2, exit 1; sorted input: silent, exit 0), `-m` (accepted; an ordinary sort of the concatenation is POSIX-conformant for already-sorted input). `-k`'s per-key `b`/`f`/`n`/`r` types and multiple `-k` (cap 8) SHIPPED 2026-10-08 (docs/POSIX-SORTK.md, POSIX-SORTK-NOTES.md); `d`, `i` and `-k N.C` character offsets remain usage errors (held-red rows). sort.bin 3,391 -> 4,090 B (+699 B) | 699 B (actual) |
| `find` | `-name -type -print -exec` | + `-newer -mtime -size -prune -path -ok -depth`, operators `! -a -o ( )` | **SHIPPED 2026-09-14**: a real expression grammar (`expr := term { -o term }`, `term := factor { [-a] factor }`, `factor := ! factor \| ( expr ) \| primary`, one JSR level per rule, short-circuit via an explicit software stack so the un-taken side of `-a`/`-o` truly never runs -- src/bin/findexpr.s/findeval.s/findtst.s) replaces the old flag list; default `-print` now applies to the WHOLE expression exactly when POSIX's own `( given expression ) -print` rewrite would (not merely "always print"), and per the XCU text that check is `-exec`/`-print` only, NOT `-prune`. New primaries: `-prune` (real, stops descent, checked against a live fixture proving a pruned subtree's contents are never visited), `-newer` (fresh GET_FILE_INFO compare -- no longer a USAGE_ERR), `-path` (globs the WHOLE walked path, not the basename), `-size N`/`-size Nc` (fresh OPEN+GET_EOF+CLOSE -- the one primitive that answers root and descendant paths alike; blocks default, `c` for bytes), `-links` (every maux file has exactly one link -- no hard-link support exists to measure, so this is an honest constant, not a stub), `-xdev`/`-nouser`/`-nogroup` (constant-true: ProDOS has one device per walk and no user database at all, so these are conformant no-ops, not stubs). `-mtime` computes a CALENDAR-DAY difference (not POSIX's exact 86400-second window -- no epoch-seconds clock exists, only a ProDOS date+time-of-day pair) and is FALSE whenever the clock is absent at boot, same NOCLOCK rule `date`/`ls -l` already use. **UPDATE 2026-10-08: `-ok` and `-depth` SHIPPED** (see the section 6b addendum below); still gaps, and permanently so: `-perm` (docs/ANACHRONISMS.md sec W2 already rules out a Unix rwx mapping onto ProDOS's access byte), `-user`/`-group` (no user database to resolve a name against), find.bin 4,641 -> ~7,090 B | ~2.4 KB (actual) |
| `diff` | `-ceuCU` | `-bcCefruU` | (none; `-r` shipped 2026-10-08, `-b` 2026-09-21) | **`-r` SHIPPED 2026-10-08** (src/bin/diffrec.s, diff.bin 5,454 -> 8,440 B): the directory walk, `diff FILE DIR` / `DIR FILE`, and plain `diff DIR1 DIR2` ("Common subdirectories"); one directory fd at a time (listings are read whole into a 12,000-byte sorted name arena, then closed), byte-order merge like the hosts, `Only in D: N`, the `diff OPTS A B` header with the options as typed, type-mismatch lines (rc 1; BSD says 0, GNU 1), 16 levels, loud refusal when a listing or a path does not fit. Measurements and the rows: docs/POSIX-DIFFR-NOTES.md. **Earlier, 2026-09-17**: `-u` (unified) and `-c` (context), plus `-U n`/`-C n` for a width other than the default 3 (src/bin/diffctx.s + diffcout.s, +1,406 B: diff.bin 3,882 -> 5,288). No second pass and no second algorithm -- the context forms group the SAME HUNKTBL records the existing `-e`/normal output reads, by the overlap rule MEASURED against this host's own diff: two change regions print as ONE hunk exactly while at most 2*context unchanged lines separate them. Three more measured shapes a first-principles implementation gets wrong are in that file's header: a zero-length range prints the line number BEFORE it, a `-c` range is start,END inclusive, and a `-c` section with no changed line of its own prints its header line and NO body. Header lines carry the pathname alone -- POSIX leaves the timestamp text unspecified and a ProDOS file has none worth printing on a clock-less boot, so check_posixutil grew NORMALIZERS (one entry, `diffhdr`) to drop that one field from both sides. **Still gaps**: `-r` needs a directory walk this tool does not have at all, and `-b` needs a white-space-insensitive line compare in DPFILL/BACKTRACE's STRCMP calls -- neither falls out of the context work, so neither was rushed. | ~1.5 KB estimated, 1,406 B actual |
| `date` | `+format` (subset) | `[-u] [+format]` | **SHIPPED 2026-09-17**: `+format` -- `%Y %m %d %H %M %y` (PR2DIG/U2DEC, unchanged from the fixed format's own routines), `%S` (constant "00" -- this clock is minute-resolution, no seconds field to read), `%n %t %%`, and the composites `%D %T %R %F`, dispatched through a `jmp (JTABLE,x)` table (sedparse.s's own idiom -- a 14-way linear if/else chain does not fit 65C02 branch range end to end). date.bin 1,723 -> 2,318 B (+595). Still gap: `%a`/`%b`/`%j` (weekday/month name, day-of-year) need a day-of-week/day-of-year computation this file has never had (cal.s's CALCDOW/Sakamoto, ~80 lines, duplicated not shared per house convention) -- the priced motivating case (`date +%Y%m%d`) needs none of the three. Also: no batch-harness row can assert exact `+format` OUTPUT content (`reset(clock=...)` is boolean, not a settable wall-clock value) -- only the clock-absent refusal path is gated; proving the live-clock text needs check_sumdate.py's own raw-clock-peek mechanism extended to a `+format` call, not done here. | ~600 B (priced), 595 B (actual) |
| `mkdir` | `-p` | `-m -p` | **SHIPPED 2026-09-13**: `-p` walks the length-prefixed pathname, creates each missing component, tolerates `$47` on intermediates, and accepts an existing leaf only if GET_FILE_INFO says directory. `-m` has no ProDOS meaning. 1,507 -> 1,918 B (getopt's first inclusion) | -- |
| `tail` | `-c -n` | `-c -f -n` | **SHIPPED 2026-09-17**: `-c N` -- a second, byte-granularity ring (MODEBYTE/CNBYTES/WBPOS), capped at MAXBYTES=255 (an 8-bit index throughout, no 16-bit ring-offset math) with a loud error past it, same posture as `-N`'s own MAXLINES=64 cap. Reuses the read/print SHAPE of the line ring (wrap-and-count, then print oldest-to-newest) but with a 1-byte slot (`RING,x` direct) and raw-byte output (no PUTS/CR framing). tail.bin 2,285 -> 2,497 B (+212). Still gap: `-f` (W1 wants it; `&` now makes it meaningful) -- a real follow is a poll loop that runs until `^C`, which has no bounded exit for `check_posixutil`'s own "run one command, capture rc" batch shape to observe; needs a harness change, not just a flag, so left red. | ~300 B (priced), 212 B (actual, -c only) |
| `ls` | `-lC1trdFRs` | `-aAcdFgHikLlmnopqrRsStux1C` | **SHIPPED 2026-09-17**: `-d` lists a directory argument itself; `-F` appends `/` only to directories; `-s` prints ProDOS `blocks_used`; `-R` walks subdirectories depth-first through a bounded 16-path worklist and fails loudly on overflow. `RD_BLOCKS` uses the old tail padding in the shared 32-byte readdir record, so no existing ABI offset moved. `-a`/`-i` are no-ops here (no dotfiles, no inodes). ls.bin 4,952 -> 5,713 B (+761). | 761 B (actual) |
| `cp` `mv` `rm` | `-iprR` / `-fi` / `-irf` | `-fipR` / `-fi` / `-fiRr` | **SHIPPED**: `cp -p` preserves ProDOS metadata; `-i` prompts before cp/mv replacement and rm removal, with only y/Y proceeding; `mv -f` suppresses prompting. `cp -f` is its existing default replacement behavior. | measured in landing commits |
| `ed` | `a c d i p n q r w s g m t j =` | + `e E f k l u v G V W ! H h P Q` | **`u`** (undo), `e`/`f`, `k` marks, `l`, `v`, `!`, `w` with a range, `,5`/`1,` half-ranges | ~1 KB |
| `od` | `-bcxjN` | `-AbcdjNostvx` | **SHIPPED 2026-09-17**: `-j skip` (discards `skip` bytes first, seeds the offset column at `skip` rather than 0) and `-N limit` (caps the total dumped, checked before every byte so a limit mid-row ends that row short, same shape EOF mid-row already took). Both parse unsigned decimal only, 16-bit (OD_PARSENUM, tail.s's own MUL10ADD shape). od.bin 2,243 -> 2,559 B (+316). `-A` shipped 2026-09-21. **`-t` SHIPPED 2026-10-08** (docs/POSIX-ODT.md, docs/POSIX-ODT-NOTES.md): the type_string sub-language `a c d[size] o[size] u[size] x[size]` (size 1 2 4 or C S I L, L = 4 on this 16-bit machine, no size = 4; x8 and every other size refused with exit 2), repeatable and combinable (`-t x1c`), one line per type under one offset, columns laid out the way GNU od lays them (measured and cross-checked against GNU on the box and BSD on the Mac on every run); plus `-d -o -s` (XCU: u2 o2 d2), `-v`, and the POSIX `*` collapse of repeated rows (new for the default format too). The legacy -b/-c/-x stay at their ruled widths and order. One printer (src/bin/odtype.s) now serves them all. Divergences kept: hex is UPPER case; `-x` is x1 not the XCU x2; `-c` and `-t c` strip the high bit of a byte whose low seven bits print (maux text is high-bit). od.bin 2,781 -> 4,034 B (+1,253; see the notes for the split) | ~500 B (priced), 316 B (`-j`/`-N`), +1,253 B (`-t` and friends, actual) |
| `tr` | `-cds`, ranges | + `-C`, `[:class:]`, `[=e=]`, `[x*n]` | `[:class:]` | ~300 B |
| `touch` | `-tr` | `-acmrt` | **SHIPPED 2026-09-17**: `-t stamp` (`[[CC]YY]MMDDhhmm[.SS]`, PARSESTAMP -- a century, if given, is consumed and dropped since ProDOS's packed date word has no century field at all; seconds, if given, are parsed then discarded, ProDOS dates being minute-resolution) and `-r ref_file` (GETREFSTAMP: GET_FILE_INFO on ref_file, its mod_date/mod_time copied verbatim). Both funnel into TS_DATE/TS_TIME, the cells the live clock used to occupy outright (CLKBUF is gone; SC_CLOCK now reads there directly when neither flag is given). touch.bin 1,994 -> 2,610 B (+616, mostly getopt.s's own module pull -- touch had no option parsing at all before this). Proven via a `test -f -t`/`test -f 202001010000` absence check (the exact bug the old gap named: those strings used to become real FILE operands) rather than an ls -l date-column match, which LS_CASES documents elsewhere as unreliable in this harness. | ~400 B (priced), 616 B (actual) |
| `uniq` `wc` `du` `tee` | `-cduf s` / `-lwcm` / `-sak` / `-ai` | `-cdfsu` / `-clmw` / `-aHLksx` / `-ai` | **ALL SHIPPED 2026-09-17**: `uniq -f`/`-s` (SKIPCMP: skip SKIPFLD fields then SKIPCHR more chars before the existing STRCMP; the printed COPY is unaffected, only adjacency) uniq.bin 2,507 -> 2,780 B (+273); `wc -m` (sets the same WANT_C cell -c does -- chars==bytes in the C locale) plus a real multi-file totals line (ADDTOT/TOTAL, unpadded like every other wc column) wc.bin 2,262 -> 2,376 B (+114); `du -k` (TOKB: (blocks+1)/2 ceiling, applied only to the printed copy) du.bin 3,578 -> 3,624 B (+46); `tee -i` (SC_SIGNAL(2,SIGA_IGN), nohup.s's own best-effort shape -- pulls in the WHOLE syscallp.s module for one call, which is most of the cost) tee.bin 2,377 -> 2,701 B (+324). | ~100 B each (priced), 114/273/46/324 B actual |
| `make` | macros, inference rules, `$@ $< $* $?`, `.SUFFIXES` `.SILENT` `.IGNORE` `.DEFAULT` `.PRECIOUS` `.POSIX`, `@ - +` recipe prefixes, `;` and `\`, `-eikNnpqrSst` | -- | **ALL SHIPPED 2026-09-18** (docs/MAKE-POSIX.md, gated by 40 `make` rows in `check_posixutil`, 26 of them differential against this host's own make via `-n`). This row was never a conformance nicety: the generated self-rebuild MAKEFILE was **244 rules / 40,133 B** against make.s's `MK_MAXRULE` 240 and `MK_TXTSZ` 28,672, so `make nas-selfmake-image` FAILED outright, and raising the caps was no fix (the rule tables are X-indexed, 255 is the ceiling, and the roster went 46 -> 85 utils in a month). Two inference rules and 16 macros make the same graph **98 rules / 18,587 B**, and `MK_MAXRULE` came DOWN to 192. Expansion is lazy -- targets at parse time, dependency lists per walk depth, recipes at execution -- because expanding the file eagerly costs the whole saving (MAKE-POSIX sec 2). Still out of scope and stated rather than hidden: no shell between make and the command (so no pipes, redirection, globbing or `cd` in a recipe, and `#` in a recipe is a character), no parallelism, no `include`, no `::` rules, no `-f -`. | ~1.5 KB (priced), 3,861 B (actual: make.bin 3,776 -> 7,637) |
| `echo` | binary: `-n`; builtin: `-n` | `-n` | **SHIPPED 2026-09-15**: the shell builtin in `shbltn.s` shadowed `echo.bin` at the prompt and never got the `-n` the binary gained 2026-09-01, so `echo -n` printed `-n`. `CHCK_BLTN_ECH` now runs echo.s's own argv[1]-exactly-"-n" check; the two are byte-for-byte identical again (docs/SH-FEATURES.md sec 22.1). | ~40 B (priced), 82 B (actual, shared with two other fixes -- sec 22) |
| `kill` `stty` `ps` `df` `nm` | small subsets, `kill` now incl. `-l -s` | many | **SHIPPED 2026-10-07 (`df`, docs/DU-DF.md)**: `df` prints the POSIX `-P` report (header + one row per volume) with Used/Available from one GET_FILE_INFO on the volume directory, `-P`/`-k`, no operand = every ONLINE volume (non-floppy units, readdir `/`), an operand = the volume holding it; gated by `check-df` against a2til's bitmap count, plus 2 `check_posixutil` rows. df.bin 2,030 -> 3,931 B (+1,901, mostly readdir.s and getopt.s). Also `du`: no operand now reports `./X` ... `.` (was `/BASIC//X`), a trailing-slash operand is not doubled, and a volume root is no longer double-counted (3,362 for 1,681 blocks of files). **SHIPPED 2026-09-17 (`kill`)**: `-l` (LISTSIGS: the 5 names -s now accepts, HUP/INT/QUIT/KILL/TERM, signal-number order, one space-separated line) and `-s signal_name` (MATCHSIG: the same 5-name table, case-insensitive, reusing timeout.s's own STRCMPI-based name match shape -- timeoutparse.s's TO_PARSESIG -- rather than sharing code across two binaries for a 5-entry table). kill.bin 1,819 -> 2,133 B (+314). Everything else here: fine for a single-user 14-process machine | -- (kill: ~100 B priced, 314 B actual) |
| `ex` `vi` | 35/53, 59/66 in the conformance gates | -- | already tracked in `check_posixex.py` / `check_posixvi.py` | -- |
| `vi` | colon `!` forms | `!motion` (`!!`, `!}`) | **OPEN, found by DEMO-VIBANG 2026-10-20** (docs/DEMO-VIBANG-NOTES.md): no normal-mode `!` command; `!!` and `!}` are ignored and the following keys run as ordinary commands. Also `:w !cmd`: its output is on the glass for a moment and vi repaints, with no hit-return hold (POSIX: a message and a read of a character when an ex command overwrote the screen other than the last line); `:!cmd` holds. Listed in vi.1 BUGS. | not priced |

**Already conformant or near enough:** `cat` (POSIX only mandates
`-u`), `sed` (`-n`, repeatable `-e`, `-f`; the first draft of this
survey misread its two-line usage string and listed `-f` as missing --
operator 2026-09-13: "sed should already be posix"), `cmp`, `comm`, `expr`, `more` (`-ceisun`), `sleep`,
`time`, `true`, `false`, `pwd`, `wait`, `sed` command set (138-case
gate), the regex engine (POSIX BRE, Fowler 109/109).

## 3. The shell against POSIX `sh`

POSIX `sh` is a superset of V7's; `SH-FEATURES.md` measured against V7.
Against POSIX the remaining gaps, measured from `sh*.s`:

(The open divergences in constructs that DO exist -- quoting, `case`,
traps, here-documents, `$( )` -- are the G-ledger in sec 3b below.)

| gap | note | cost |
|---|---|---|
| ~~**prefix assignments** `NAME=value cmd`~~ | **SHIPPED 2026-10-21** (docs/SH-PREFIX.md, SH-PREFIX-NOTES sec 5) -- POSIX 2.9.1: exported for the one command and put back (a builtin sees it too: `IFS=: read a b`), persisting for the special builtins and for a command with no name; per pipeline stage; `A=1 > F` and `: > F` make F. gate `make check-shprefix`. Not taken: `-k` (not V7), eight variables is the limit (a ninth is a loud refusal) | ~1.0 KB low (actual, with `sh -c` and the script-fd work) |
| ~~**`sh -c STRING [NAME [ARG...]]`**~~ | **SHIPPED 2026-10-21** (SH-PREFIX-NOTES sec 6) -- non-interactive, `$0`=NAME, `$1..`=ARGs, exits with the last status; no string is status 2. Limit: the string is one line | ~110 B |
| ~~**a script that `exec 3<F` ate**~~ | **SHIPPED 2026-10-21** (SH-PREFIX-NOTES sec 7) -- the script, a `.` file, a construct redirect and the console loop's spool file sit on the highest free fd; an `exec` onto the descriptor the shell reads from is refused | ~65 B |
| **functions** `name() { ...; }` | POSIX mandates them. `ANACHRONISMS` W2 forgoes them as "System III" -- that ruling predates POSIX being the target for userland and needs re-ruling. Without them a script cannot factor anything except into another file | ~800 B |
| ~~**`getopts`**~~ | **SHIPPED 2026-09-15** (docs/SH-FEATURES.md sec 24) -- clustering, required-arg, `--`, silent (`:`-leading) and loud diagnostics; OPTIND/OPTARG cost two of MAXVARS' eight slots while in use | measured 23,500 B total w/ the other three below |
| ~~`{ list; }`~~ | **SHIPPED 2026-09-15** -- grouping in the CURRENT shell, no subshell fork (`RW_BRACE`/`RW_RBRACE`, shresv.s); reuses the compound-redirect scan-then-rewind machinery unchanged (`CR_ISTERM` gained a `}`-for-CSTYPE-6 case -- a real bug: without it the redirect silently applied to nothing) and SPOOL_ADJNEST's open/close pair so a bare `{` typed at a non-seekable console spools like FOR/WHILE | 109 B |
| ~~`eval`, `exec`, `readonly`, `command`, `type`~~ | **SHIPPED 2026-09-16** (docs/SH-FEATURES.md sec 29), all six of the paused list, all in the $E000 code segment: `command NAME` drops its own word and lets the dispatch chain re-run (so builtins are still found); `type`/`command -v`/`-V` answer builtin/keyword/path/not-found and PROBE a `/`-bearing name rather than PATH-searching it; `eval` joins its operands and re-enters `SH_RUNLINE`, giving POSIX's two expansion passes (and abandoning the rest of its own line, like `.`); `exec >FILE`/`2>&1`/`<FILE` is PERMANENT via `SYS_DUP2`, while `exec CMD` runs it and exits -- maux has no exec syscall, a documented divergence; `readonly` binds `VARSET`/`VARUNSET` so all seven writers refuse. `hash` NOT taken: it would report on a cache the shell already manages itself | **318 B low** (+1,705 B segment) |
| ~~`unset`~~ | **SHIPPED 2026-09-15** -- frees a variable's slot (VARFIND's own "name byte 0" contract), `-v` accepted, `-f` a loud usage error (no functions) | see above |
| ~~`set -e`~~ | **SHIPPED 2026-09-15** -- a failing simple command exits the shell (script) or abandons the line and reprompts (interactive), unless it is the left side of `&&`/`||` or an `if`/`while`/`until` condition (`ERREXIT_CK`/`CSCOND`, shbltn.s/shresv.s); `set +e` restores. `-u -f -n -v -o` still missing | 172 B |
| ~~`<&N`~~ | **SHIPPED 2026-09-15** -- `>&` shipped 2026-08-22, `<&N`/`<&-` shipped 2026-09-15 (reuses `CLS_DUPTAIL` unchanged, target forced to `FD_STDIN`) | see above |
| ~~`$!`~~ | **SHIPPED 2026-09-15** -- the pid of the most recent background command (`SH_BGPID`, `JOB_BG`); `$-` still missing | see above |
| ~~`${V%pat}`, `${V%%pat}`, `${V#pat}`, `${V##pat}`~~ | **SHIPPED 2026-09-15** -- shortest/longest suffix/prefix removal (`VPAT_STRIP`, shexp2.s), reusing `GLOBMATCH` (liba/glob.s) unchanged against candidate substrings rather than a second matcher; `${#V}` (string length) still missing | 343 B |
| `$(( ))` | ruled OUT (`SH-SUBSET` sec 4, `expr` instead). POSIX mandates it; recorded divergence | ~700 B if ever |
| `PS1`/`PS2`/`HOME`/`PWD` | prompt hardcoded; bare `cd` goes to the boot prefix | ~200 B |
| `!` pipeline negation, `return` | with functions | ~100 B |
| `alias`/`unalias`, `fc`, `umask`, `ulimit` | `fc` IS the history item on the COMPLETISH list, worth building as `fc` rather than inventing a spelling; the rest N/A or low value. (`times` SHIPPED 2026-09-16 -- field 1 is the shell's ELAPSED time from `SYS_TICK`, the other three fields are structural zeros, because this kernel has no per-process or child CPU accounting at all: a recorded divergence, sec 29.6) | -- |
| `while` over a pipe | body is re-read by `lseek`, so `cmd \| while read x` cannot work; `continue` unsupported in `for` | design change |

`sh.bin` is 26,233 B as of 2026-09-16 -- but the number that carries the
claim is the LOW resident image, 22,349 of 24,170 (docs/SH-SUBSET.md
7.6/7.7): the rest is the $E000 code segment, and the six builtins above
cost the low image 318 B between them. The ratchet is per-image; every builtin above lands
inside it.

**Not a gap as of 2026-09-15:** `for`/`while`/`until` typed AT THE
CONSOLE (a tty, or a `$( )` pipe -- `CUR_IN_FD` not seekable) used to
print nothing (one line) or refuse with "stdin not seekable"
(spanning lines), since the loop's own re-read is a `lseek`. Fixed by
spooling the construct to a temp file and `.`-sourcing it
(docs/SH-FEATURES.md sec 21) -- the row above about `lseek` still
stands for `cmd | while read x`, which is a different fd, but no
longer for the interactive case.

**Not a gap as of 2026-09-15, and one that never was:**
`STRIPCOMMENT` used to truncate `LINEBUF` at any `#` outside a
`$#`-shaped exception, with no idea what a quote was -- `ECHO
"a # b"` and `ECHO 'a#b'` lost everything from the first `#`
(the double-quoted case even misreported `sh: unterminated
quote`, since the truncation left an unmatched `"` behind), and
`ECHO A#B` was wrongly cut too (POSIX starts a comment only at a
word boundary). Fixed: quote-aware, word-start rule
(docs/SH-FEATURES.md sec 22.2). Separately, a backslash inside
single quotes was REPORTED not-always-literal on 2026-09-14 but
did not reproduce under a live re-test with real keystrokes --
`shtok.s`'s quote-squeeze already had no backslash special-casing
at all, for either quote form (sec 22.3).

**Not a gap as of 2026-09-15 (closed same day as reported, sec
23):** the two gaps sec 22.3's own re-test surfaced. (1) `sh:
mixed quoting` on any form where a quote mark did not sit at a
token's own leading position (`abc"def"ghi`, `'it''s'`, `"a"'b'c`)
-- POSIX 2.2 applies quoting per character, and adjacent quoted/
bare segments now CONCATENATE into one word instead of a blanket
refusal. (2) `"a\$b"` did not suppress `$`-expansion, because
`:doquoted` had no backslash special-casing at all for double
quotes -- it now implements POSIX 2.2.3's own table (`\` loses its
own meaning only before `$ \` " \\`, both stripped; before any
other byte, both stay literal). One narrow, explicitly untested
limitation remains from (1): a double-quoted segment's OWN glob
characters are not protected from a bare sibling's eligibility for
globbing (`"*"x`), because `*`/`?` collide with `$*`/`$?`
expansion and cannot be blanket-cleared the way a single-quoted
segment's can -- see docs/SH-FEATURES.md sec 23.1's own note.

## 3b. Open shell divergences (the G-ledger)

This is the inventory of known divergences between `sh` and dash / bash 5
that are NOT fixed. It moved here on 2026-11-02 from the shell-gap plan
that first listed it (found 2026-10-22/23 by the SH-MLQUOTE, SH-EXECLOOP,
SH-SEQ, SH-CASE2 and SH-G21 streams, whose gates are `check-shmlquote`,
`check-shexecloop`, `check-shseq`, `check-shfd`). The identifiers G1..G28
are stable: a gate comment, a source comment or a later note says "G17"
and means the row below, so a new gap takes the next number and a row is
never renumbered or reused. G1, G2, G12 and G23 are FIXED and stay in the
table so the numbers keep their meaning.

**How "verified" was done (2026-11-02, base main 42256e0f).** Every row
marked LIVE was re-run on a `make play-image` build of that revision under
the verilogapple fast backend, as a script (`sh ./m`) typed through the
`check-shseq` harness, and the maux output is quoted. A row marked
GATE-PINNED has an existing row in the named gate that asserts today's
answer. The two console-only rows (G5, G19) cannot be driven by a script
and were NOT re-run: they are marked, and stand on the original
measurement plus "no `sh` source change in that area since". Between the
measurement (2026-10-23) and the base the only `sh` changes were: too many
arguments refused instead of run, a spawn refused for want of a bank now
says so, the SH-FOREIGN fold of a ProDOS text script, and the stdout flush
before a spawn -- none of them touches the constructs below.

A divergence is only listed when a real script can meet it. Where a limit is
refused loudly (G4, G14) it is still listed: POSIX has no such limit.

| # | gap | status | measured shape |
|---|---|---|---|
| G1 | `if`/`while` with no branch taken leaves `$?` stale | **FIXED** (SH-CASE2 phase A). LIVE: `false; if false; then :; fi; echo r$?` prints `r0` | was `1`; POSIX, dash, bash: 0. The same stream fixed a head skipped by `&&`/`||` running its construct |
| G2 | a case pattern glued to its command is not a pattern | **FIXED** (SH-CASE2 phase B). LIVE: `case x in *)echo hit;; esac` prints `hit` | `a\|b)echo`, `[ab]*)echo`, `x)echo hit;;esac` likewise |
| G3 | `sh -c STRING` and `eval` take one logical line | **OPEN**. LIVE: `sh -c 'echo a<NL>echo b'` prints `a` then `echo b` (the second line is an argument, not a command). Pinned by `check-shmlquote` C4, C5. Stated in sh.1 | a newline in a `-c`/eval string separates nothing |
| G4 | here-doc body capped at 255 B total | **OPEN**. LIVE: a four-line 280 B body prints `sh: here-doc: too long` and the next command runs. Stated in sh.1; pinned by `check-shmlquote` (HDLONG rows) | refused loudly (it used to truncate silently); POSIX has no cap |
| G5 | a here-doc body line `done` ends console loop spooling | **OPEN, not re-run** (console only; a typed loop spooled to a temp file) | `SPOOL_SPLIT` is blind to here-doc bodies |
| G6 | a loop head's or dead code's `$( )` runs twice | **OPEN**. LIVE: `rm -f L; for i in $(echo r >> L; echo a); do echo $i; done; wc -l L` prints `a`, `2 L` (POSIX: 1) | the scan pass PARSEs (and so expands) a seekable construct before running it |
| G7 | `$( )` closes at a case pattern's `)` | **OPEN**. LIVE: `echo $(case x in x) echo s;; esac)` prints `echo s` then `sh: unexpected then/elif/else/fi/do/done` | needs a recursive `$( )` parse |
| G8 | `set -e` and a compound in a tested position | **OPEN**. LIVE: `set -e; case x in x) false;; esac || echo no; echo after` ends the script printing nothing (dash/bash: `no`, `after`). GATE-PINNED: `check-shseq` E6 | `ERREXIT_CK` sees only the failing command's own separator |
| G9 | a loop in an EXIT trap is dropped | **OPEN**. LIVE: `trap 'for i in a b; do echo T$i; done' EXIT; echo body` prints only `body` | the spool is `.`-sourced and `SH_EXITING` exits first |
| G10 | a trap inside a `for` fires late and once | **OPEN**. LIVE: `trap 'echo T' 15; for i in 1 2 3; do kill -15 $$; echo i$i; done` prints `i1 i2 i3 T T` (dash/bash: `T i1 T i2 T i3`). GATE-PINNED: `check-shexecloop` (the trap-in-`for` row; a `while` loop is exact) | a `while` loop delivers each trap on time |
| G11 | empty unquoted expansion right after `then`/`do` in a scanned construct | **OPEN**. LIVE: `E=; if true; then case $E in *) echo s;; esac; fi` prints `sh: unexpected then/elif/else/fi/do/done` and `sh: EOF with a construct still open` | scan-pass syntax noise |
| G12 | `(x)` leading-paren case patterns | **FIXED** (SH-CASE2 phase B). LIVE: `case x in (x) echo hit;; esac` prints `hit` | `(x)echo`, `(a\|b)echo`, first on a line or not |
| G13 | a brace group with a redirect as an `if` condition | **OPEN**. LIVE: `if { true; } 2>/dev/null; then echo y; fi` prints `sh: unexpected then/elif/else/fi/do/done` | a syntax error |
| G14 | `for` takes at most 16 words | **OPEN**. LIVE: a 17-word list prints `sh: for: too many words`. Stated in sh.1 (`FORWORDMAX` = 16 in `sh.s`) | refused loudly |
| G15 | an alias redefined in a loop body changes the replay | **OPEN**. LIVE: `alias a='echo one'; for i in 1 2; do a; alias a='echo two'; done` prints `one`, `two`; a shell that substitutes aliases when it parses the loop prints `one`, `one` | replay assumes the line expands the same way each time |
| G16 | quoted assignment with an embedded quote: `V='it'\''s'` | **OPEN**. LIVE: prints `sh: mixed quoting`. `V='a b'` and `V="a b"` work (one quote span after `NAME=`) | the assignment grammar accepts ONE quote span after `NAME=` |
| G17 | an unquoted `)` is not a control operator outside `case` | **OPEN, a KEPT divergence**. LIVE: `echo a)b` prints `a)b`; dash and bash: syntax error. GATE-PINNED: `check-shseq` K30-K32 as WANT rows | `ISOPCH` excludes parentheses |
| G18 | a sourced file's first command sees `$?` 0 | **OPEN**. LIVE: file X = `echo in$?`; `false; . ./X` prints `in0` (bash: `in1`) | `.` sets 0 before X so `false; . EMPTY && echo OK` is right; bash keeps the caller's status until X's first command (needs a ran-a-command flag, as `CASE_EMPTY`) |
| G19 | ^C at the console does not abandon a sourced file | **OPEN, not re-run** (needs a console and a ^C) | ^C kills the foreground command only; X carries on and the remainder runs (bash abandons X) |
| G20 | a one-line `{ case x in x) echo b;; esac; }` is a syntax error | **OPEN**. LIVE: prints `sh: unexpected then/elif/else/fi/do/done` and `sh: EOF with a construct still open`; the multi-line form works | not understood to the root (the brace-group scan pass and a case in its first segment) |
| G21 | a double-quoted glob character in a MIXED word (a case pattern, `a"*"`) still globs; DEFERRED, priced | **OPEN**. LIVE: with files `ab` and `ac`, `echo a"*"` prints `ab ac` (dash/bash: `a*`). GATE-PINNED: `check-shseq` K42 | see below |
| G22 | blanks around a pattern's parens: `( x ) echo`, `x ) echo` | **OPEN**. LIVE: `case x in ( x ) echo hit;; esac` prints nothing. GATE-PINNED: `check-shseq` K40, K41 | dash and bash accept both; maux splits neither |
| G23 | a trap string holding a loop (or any construct) took a top-level loop's pending hand-off | **FIXED** (SH-CASE2 phase B review). Gate-pinned as oracle rows `check-shseq` Q22-Q22d (not re-run live) | `PUMP_TRAP` fires at depth 0, between the loop's pop and re-push; the pump now hides the hand-off and puts it back when the trap (and any spool) is done |
| G24 | a glued alternation with a `$` or quote before the `)` lexes as a pipeline | **OPEN**. LIVE: `V=b; case b in a\|$V)echo hit;; esac` prints nothing. GATE-PINNED: `check-shseq` K47 (the SPACED forms work) | `a\|"$V")echo` likewise |
| G25 | adjacent double-quoted segments glue a `$` to a `*`: `echo a"$""*"` | **OPEN**. LIVE: prints `a` (dash and bash 5: `a$*`) | the `$` ending the first segment and the `*` starting the second land next to each other as a live pair and `WORDEXPAND` expands `$*` (empty). The G21 plan cures it only if its previous-byte-was-a-live-`$` state is reset at every segment start |
| G26 | a quote inside a `$( )` inside "..." ends the double quote: `echo a"$(echo "*")"` | **OPEN**. LIVE: prints `a` followed by the directory listing (dash and bash 5: `a*`) | `:qloop2` closes at the first quote whatever the span depth (a bare `$( )` already treats a quote in a span as content). Not G21; the G21 plan leaves it as it is |
| G27 | a quoted operand in `${V#"*"}` is still a live pattern | **OPEN**. LIVE: `V="*x"; echo "${V#"*"}"` prints `X` (the live `*x` globbed to a file; with no match it prints `*x`); dash and bash 5 print `x` | the quote inside the outer "..." also ends the outer double quote (cf. G26); a G21 fix that excludes `${ }` leaves this alone |
| G28 | a `$( )` left open at end of line is refused, and nested `$( )` is refused | **OPEN** (added 2026-11-02: recorded before only in prose). LIVE: `echo $(echo a` NL `echo b)` prints `sh: $(): unclosed, or nested`; `echo $(echo $(echo n))` prints the same. Pinned by `check-shmlquote` Q6a, Q6b; stated in sh.1 and in docs/KNOWN-LIMITATIONS.md | the quote scanner does not continue a line inside an open `$( )`; needs the same recursive parse as G7 |

**G21 in detail** (the largest row, kept whole because the plan was priced
and not built). Every row below is dash and bash 5 agreeing, with maux on the
base in a directory holding only `ab` and `ac`: `echo a"*"`, `a"?"`,
`a"[bc]"` print `ab ac` (oracle: the literal); `case x in "*")`, `"[a]")`,
`a"*")`, `x"*")` print BAD (OK); `for f in a"*"; do echo "$f"; done` runs
twice, `ab` then `ac` (once, `a*`); `V=b; echo a"*"$V`, `echo a"*"$(echo b)`,
`V=; echo a"?"$V` and `echo a"$(echo b)*"` glob (rebuild paths and a star
AFTER a closed span; with `V=x` the rows cannot fail, the pattern `a*x`
matches nothing). A WHOLLY double-quoted word is right; one bare byte (even
the `)` of a case pattern) makes the word mixed. CONTROLS, all equal to the
oracle today and which must stay so: `"a*"`, `"$V"` (V=`*`), `"$1"`, `"$?"`,
`"$*"`, `"a"*`, `a*`, `'*'`, `\*`, `x"\$*"`, `x"\$?"`, `"$(echo a*)"`,
`x"$(echo a*)"`, `"${V#a*}"`, `"${V##*}"`, `"${V%?}"`, `"${V#[ab]}"`,
`"${V?msg}"`, `a"\*"`. PLAN (priced, not built): in `:qloop2` store `*?[`
with bit 7 clear except after a LIVE `$` (a one-cell state fed only by the
unescaped path, so `"\$*"` stays literal; `[` never), inside a `$( )` span
and inside `${ }` (a depth counter; `SUB_TRKCH` cannot be reused: a `)` at
depth 0 records the offset), with the previous-byte and depth cells reset at
`\` and at every double-quote segment start. Measured +99 B of low image
(hooks 12, routine 87; cells in the dum arena) against the 62 B ceiling;
narrowing cannot reach 62 and keep the controls. Option O1: split it, front
~50 B into segment 2 (66 B spare) and the span handlers ~45 B into segment 1
(60 B spare), low +12; an estimate that spends nearly all cold room.

## 4. The missing tools, priced

Calibration from what the same shape cost here: `tail` 2,285 B, `tr`
2,075, `tee` 2,377, `uniq` 2,507, `sort` 3,391, `find` 4,641, `grep`
5,666, `sed` 10,364, `more` 11,976, `vi` 23,088. Each new util also
costs a gate, a man page and volume blocks in ~40 gate images
(`liba-bytes-are-volume-bytes`).

### 4a. Small filters, one `put` of liba each (~1.5-3.5 KB)

`head` SHIPPED 2026-09-13 (src/bin/head.s, 2,168 B) -- the most-typed
missing command turned out cheap: it needs no ring buffer at all (a
streaming prefix copy, not tail's "which lines are last" problem), and
landed under tail's own 2,285 B.

`cut` SHIPPED 2026-09-14 (src/bin/cut.s, 2,794 B, plus a split-out
LIST-syntax parser in src/bin/cutlist.s for the check-dialect
as-window budget) -- `-b`/`-c` (the same column selection on this
7-bit-ASCII machine) and `-f`/`-d`/`-s`, with `sort -t` and `uniq`
completing the "columns" toolkit as priced below.

`xargs` SHIPPED 2026-09-14 (src/bin/xargs.s, 4,375 B, plus a
split-out tokenizer/-I/PARSEDEC in src/bin/xargstok.s for the same
as-window budget) -- `-n`/`-s`/`-t`/`-I`, PATH resolution and
spawn/wait copying find.s's `-exec` mechanism, an empty environment
for the child (a v1 simplification, see the header), fd 0 closed
rather than inherited. `-0`/`-E`/`-L`/`-p`/`-r`/`-x` are not
implemented (docs/man/xargs.1's BUGS section, KNOWN_GAPS2 rows).

`printf` SHIPPED 2026-09-14 (src/bin/printf.s, 3,837 B, plus a
THREE-way split -- printffmt.s/printfnum.s/printfcnv.s -- forced by
the `as` source window: the numeric-argument engine alone ran ~22KB
in one file, over budget even after a first split, so the two-piece
shape `cut`/`xargs` use was not enough here) -- `%d %i %o %u %x %X
%c %s %%` and the XSI `%b` extension, flags `- + space #`, field
width and precision, format reuse, and the `\a \b \f \n \r \t \v
\ddd` escapes (`\n`/`\r` both `$8D` -- one line-end byte on this
machine). Arguments are this machine's own 16-bit register: `%d`/
`%i` display it signed, `%u`/`%o`/`%x`/`%X` the same bits unsigned
(the real int16_t/uint16_t pun), and a magnitude too big for either
encoding, or a non-numeric argument, is diagnosed (stderr, value 0,
exit 1) without stopping the rest of the run -- checked live against
this host's own `/usr/bin/printf`. No floating-point conversions
(`%e %f %g %a`) -- this machine has none (KNOWN_GAPS2 rows).

`basename`/`dirname` SHIPPED 2026-09-14 (src/bin/basename.s 1,533 B,
src/bin/dirname.s 1,463 B) -- the XCU string/suffix algorithm
(basename) and string algorithm (dirname), pure text arithmetic, no
MLI call of any kind: not even a filesystem lookup happens, so
neither cares whether the path named actually exists. Verified live
against this host's own `/usr/bin/basename`/`/usr/bin/dirname`
before writing either file. `basename`'s BSD `-a`/`-s` extensions are
not implemented (docs/man/basename.1's BUGS section) -- POSIX's own
SYNOPSIS is the one-string form.

`env` SHIPPED 2026-09-14 (src/bin/env.s, 3,263 B) -- `-i`,
`name=value` operands (added or replacing, last-typed wins), and a
`utility` PATH-resolved and spawned exactly as `find -exec`/`time`
do, exiting with its status unchanged. With no `utility`, prints the
merged environment. A duplicate `name=value` operand on one command
line is resolved by order rather than removed (KNOWN_GAPS row,
docs/man/env.1's BUGS section); "found but not executable" (exit
126) cannot be distinguished from other spawn failures on a machine
with no separate execute-permission bit.

`uuencode`/`uudecode` SHIPPED 2026-09-14 (src/bin/uuencode.s 2,494 B;
src/bin/uudecode.s 3,200 B, `put`-split into uudecdec.s/uudecln.s for
the native assembler's source window) -- both the historical
alphabet and `-m` base64, verified line-for-line against this host's
own `/usr/bin/uuencode`/`/usr/bin/uudecode` before writing either
file. `uudecode` accepts EITHER of this build's two text conventions
on input (high-bit maux text, or the plain 7-bit ASCII that arrives
over `tip` -- docs/SERIAL.md: its line reader strips bit 7 before a
byte ever reaches a redirected file), normalizing every input byte
before use rather than guessing which convention it is looking at.
Round-tripped live through the shipped binaries themselves (`UUENCODE
/BASIC/BIN/GREP G | ... ` -- 5,668 B, both algorithms, byte-identical
via `cmp`) and through `check-posixutil` (18/18, hand-computed rows:
header line, length character, the backquote-for-zero rule, both
trailers, `-m` padding at both remainder widths, `-o`, `-o
/dev/stdout`, a missing "begin" line, and a malformed body, each
keyed to its own XCU sentence). Mode is always the literal `644` in
the header (docs/man/uuencode.1's BUGS section) -- this machine has
no permission bits to report. Review (same day) found the landing's
one red -- check-textaudit's warm uudecode pair decoding 512 B of
1244 -- was the audit's 400-block volume running out (one free block
after the run; ProDOS $48 at the close-time flush), not stdio or the
program; the volume is 800 blocks now. The red carried a second, real
bug: uudecode ignored FCLOSE's carry and exited 0 with a truncated
file. It now prints "uudecode: write error" and exits 1, the posture
tee and sort already take.

`rmdir`/`tty`/`uname` SHIPPED 2026-09-14 (src/bin/rmdir.s 1,864 B;
src/bin/tty.s 1,272 B; src/bin/uname.s 1,671 B). `rmdir [-p]` is one
more caller of the MLI DESTROY call rm.s's own plain (un-`-r`) path
already rests on (street-library learning:01M0T0YSPMJE238VH46CZPDR2V:
DESTROY refuses a non-empty directory with $4E, the TRM's own words)
-- `-p` walks the pathname from the right exactly as far as each
removal succeeds, stopping at the volume name or the first non-empty
component, whichever comes first (measured live against this host's
own `rmdir -p`, including the "stops but still exits >0" shape BSD's
own manual example glosses over). `tty` is `SYS_FDSTAT` (this
system's isatty, already load-bearing in `sh`'s own interactive
check) turned into a NAME: it reverses procfile5.s's device table
(`/dev/tty1`-`/dev/tty4`, `/dev/ttya0`) rather than adding one -- the
current POSIX.1-2024 text dropped the historical `-s` option as
obsolescent, so this ships none. `uname [-snrvma]` has no ProDOS
analogue at all: `sysname` is `maux`, `nodename` a fixed `apple2e`
(no hostname concept exists), `release`/`version` both the
placeholder `1.0` (no kernel version equate exists anywhere in the
tree, grepped), `machine` is `65c02`; the fixed sysname-nodename-
release-version-machine PRINT ORDER (never the SYNOPSIS's own letter
order) is measured live against this host's own `uname -m -s`. A
REAL BUG found and fixed before landing: the field separator between
the FIRST and SECOND printed field was silently skipped (`uname -a`
read "mauxapple2e ..." instead of "maux apple2e ..."), because the
separator's own "needed" flag was armed by its FIRST CALL rather than
by the field-printing routine after it actually printed something --
caught by check-posixutil's own `-a`/`-m -s` rows, both of which
select more than one field. All three measured CLEAN by
check-textaudit (0 bytes moved, group c -- rmdir's own directory is
freshly prepared, mkdir.s's/rm.s's "no output, can't repeat" shape,
so it is ONCE, not a pair).

Review (2026-09-15) of the `nl` landing: two rows were host-oracled
on behaviour the XCU text leaves open and the two hosts decide
differently (an unnumbered line's prefix; a delimiter line's own
output) -- they are spec-authored against BSD now; and `-l num`
(adjacent blank lines counted as one) was not implemented -- a
KNOWN_GAPS row, the 58th.

`nl`/`expand`/`unexpand` SHIPPED 2026-09-14 (src/bin/nl.s 3,359 B,
`put`-split into nlopt.s/nlfmt.s for the check-dialect as-window
budget -- nl.s alone measured 24,534 B stripped, over the 16,128-byte
window, and closing the gap with ONE put file would only have moved
the overrun onto that file, since the gate counts resident + the
SINGLE LARGEST put, not the sum of every put; src/bin/expand.s 2,211
B; src/bin/unexpand.s 2,570 B, `put`-split into uxrun.s for the same
reason, 446 B over on its own). This is the rest of the text-filter
family (`cksum`/`paste`/`fold` shipped the same day, sec 4a above).
`expand`/`unexpand` share one column-arithmetic shape verified live
against this host's own `/usr/bin/expand`/`/usr/bin/unexpand` before
writing either file: `-t N` (a lone number) is PERIODIC and infinite,
`-t list` (two or more numbers) is an EXPLICIT stop set past which a
tab becomes one space; a backspace decrements the column and is
still written to the output as itself. `expand`'s own column does
NOT reset between file operands (measured: an unterminated first
file's trailing column carries into the second file's first tab);
`unexpand`'s DOES reset per operand -- the two were measured
separately and simply differ on this host. `nl` numbers lines inside
logical pages delimited by `\:\:\:`/`\:\:`/`\:` (default two-char
delimiter, changed by `-d`); ANY delimiter line, not just a header's,
resets the counter to `-v`'s start value unless `-p` is given
(measured live -- the XCU prose alone reads as header-only). `-b
pBRE`/`-h pBRE`/`-f pBRE` (number only lines matching a basic regular
expression) SHIPPED 2026-10-08 (sec 6b, docs/POSIX-REGEXLINK.md): nl
links the house BRE engine, each section keeps its own pattern.

TWO REAL BUGS were found live in `unexpand`, not by inspection, in
sequence:

  1. `ISSTOP` (uxrun.s) decided "is this column a tab stop?" with
     `cmp TABSTOPS[0]` in a subtract-to-zero loop, then a bare `bne`
     that tested the LOOP'S OWN EXIT `cmp` (remainder vs the tab
     width) instead of testing the remainder against zero -- for an
     exact multiple the remainder really is 0, but 0 <> the tab
     width, so the zero flag was CLEAR and a genuine stop read as
     "not a stop" on every single call, no exceptions. Symptom: `8
     leading spaces` never converted at all -- the check-posixutil
     row for it, and the analogous e2e row, both went red. Found by
     tracing the compiled listing (merlin32 `-v1`) address by
     address rather than trusting a source re-read, since the source
     itself looked correct. Fixed with an explicit `cmp #0`.

  2. Once (1) was fixed, a second and more specific case still
     failed: `1234567` (column 7) plus two spaces. The FIRST space
     alone already reaches column 8, a stop, with only 1 byte
     accumulated since the run began -- and the predecessor
     `FLUSHPEND` gated conversion on "2 or more accumulated SINCE THE
     LAST conversion", so it never converted a run whose first
     segment was exactly 1 byte, even though this host's own
     `unexpand` does (result: `"\t "`, a tab for that lone first
     space then a literal space for the second, which never reaches
     a further stop). The real rule gates on the run's WHOLE length
     (2, here), decided once, and then converts EVERY crossing inside
     a qualifying run regardless of that crossing's own segment size.
     Fixed by buffering the run in full and replaying it from its own
     start column once the whole length is known -- fold.s's own
     CARRYOVER is the same buffer-then-replay shape -- renamed
     `FLUSHPEND` to `FLUSHRUN` to say so, +102 B.

Review (2026-09-15) of the `man`/`cal`/`strings` landing: the cal
rows and the `strings -t` rows are spec-authored (the box has no cal,
and GNU strings pads offsets where BSD does not -- neither is fixed by
the XSI text); `strings -n` over 255 is now a KNOWN_GAPS row (the run
buffer is one page); `man -k`/`-f` (apropos/whatis) are a gap with no
suite row -- there is no page index and so no conforming output to
pin.

`man`/`cal`/`strings` SHIPPED 2026-09-15 (src/bin/man.s 2,778 B;
src/bin/cal.s 3,245 B; src/bin/strings.s 2,638 B -- all three single-
file top-level units, no `put` split). `man [section] name` locates
`/BASIC/MAN/NAME` (the name upper-cased -- pages are staged there in
upper case at build) and pages it through `more` (`PATHRSLV`/
`ENVPASS`/`SC_SPAWN`/`SC_WAIT`, the same shape `find -exec`/`time`
use) when stdout is a tty (`SC_FDSTAT`, the generic device test
shlex.s's own `SH_INTERACT` probe makes), else copies it through
unpaged -- a leading numeric section is accepted and ignored, and
`-k`/`-f` (apropos/whatis) are a KNOWN GAP: this tree builds no page
index. `cal [[month] year]` matches this host's own BSD `cal MONTH
YEAR` byte-for-byte (22-column trailing-space-padded lines, a wholly
blank 6th week row where a month needs fewer, Sakamoto's algorithm
for the day of the week, ordinary Gregorian leap years); `cal YEAR`
alone is a KNOWN GAP against BSD's three-column full-year layout --
this build prints the twelve months one per block, stacked
vertically, instead (the 16x16 restoring binary divider `DIV16`
needed for `y/4`/`y/100`/`y/400` and the day-of-week `mod 7` left no
budget to add a second layout engine alongside the byte-matched one).
The pre-1752 Julian/Gregorian transition is a further KNOWN GAP,
proleptic Gregorian only, same posture as every other date routine
in this tree. `strings [-a] [-n number] [-t d|o|x] [file...]` prints
runs of `number` (default 4, capped at 255) or more printable bytes;
"printable" is BOTH `$20-$7E` (plain ASCII) AND `$A0-$FE` (this
tree's own high-bit text convention) at once, since a raw file has no
liba string convention of its own -- a divergence from every host
`strings(1)`, which recognises only the low range, verified live and
pinned by hand rather than host-oracled (no fixture built through a
high-bit-forcing test harness can even construct the case). `-a` is
accepted and does nothing: no object-file section table exists to
restrict to.

Review (2026-09-15, eng-nohup-timeout-realpath, cut from a9034eb) of
the `nohup`/`timeout`/`realpath` landing: `timeout` has no host
oracle at all on this Mac, so every check-posixutil row is
hand-authored; `realpath`'s own base directory is per-case
(`/BASIC/PXUT/<K-tag>`), so its rows use `hand`'s CALLABLE form
(`case['hand'](base)`, `base` being the exact maux-side directory
check_posixutil.py already assigned) to compute the expected
absolute path directly, rather than the shell `test "$(...)"`
construction the task brief first proposed. A REAL BUG found and
fixed before landing: `timeout`'s SYS_TICK mode-0 refusal ran AFTER
`SC_SPAWN`, so a machine with no timer (check-textaudit's own
stripped harness) would spawn the child, then exit 125 without ever
reaping it -- a zombie, corrupting that harness's own process
bookkeeping for whatever ran next in the same boot group (found live
via `check-textaudit`'s own `cp` row going dark two commands after
`timeout`'s). Fixed by moving the tick-mode check to BEFORE the
spawn (sleep.s's own rule: "the mode check comes before any
arithmetic"), matching every other timer-refusing tool in this tree.

`nohup`/`timeout`/`realpath` SHIPPED 2026-09-15 (src/bin/nohup.s
2,458 B + `put` nohupfd.s; src/bin/timeout.s 4,161 B + `put`
timeoutaux.s/timeoutparse.s; src/bin/realpath.s 2,458 B, no split
-- nohup.s/timeout.s each split for the check-dialect as-window
budget, 1,674 B and 8,295 B over respectively). `nohup utility
[argument...]` ignores SIGHUP -- a real `SC_SIGNAL(1, IGN)` call
that is a documented no-op today, since nothing in this kernel ever
SENDS a hangup (docs/FLEET.md's own nohup row) -- and appends a
terminal-bound child's stdout/stderr to `NOHUP.OUT` (falling back to
`$HOME/NOHUP.OUT`, then exit 127) via `spawn()`'s fdactions rather
than touching its own fd table, so its own diagnostics stay live.
`timeout [-fp] [-k time] [-s signal] duration utility [argument...]`
polls `SC_WAITJOB(WJ_NOHANG)` against a tick deadline (sleep.s's own
SAMPLE/target-tick shape, no interval timer exists); a fractional
duration (`1.5`) is a KNOWN GAP, refused rather than truncated;
`-s`'s signal-by-name table is shtrap.s's `TRAP_AS_SIG` mechanism,
NOT kill.s's (kill.s parses numbers only, despite the family
resemblance). `realpath [-E|-e] file...` folds `.`/`..` entirely in
liba's own high-bit text domain (MKPATH's own dot-handling only
resolves a LEADING run, and the kernel's `PRC_DOTDOT` is `cd`-only)
before converting the already-absolute result through MKPATH once,
purely as its high-bit-to-7-bit-count-prefixed step; `-E` (last
component may be missing) is the default, since POSIX leaves the
unflagged case unspecified and GNU coreutils' own default matches;
`..` above a volume's own root is a no-op, the same one-level-down
rule `cd`'s own `PRC_DOTDOT` already enforces.

| tool | why it matters here | note |
|---|---|---|
| `split` `csplit` `join` `tsort` `pr` | less often typed; `join` pairs with `sort -t` | ~2-3.5 KB each |
| `pathchk` | the one remaining small/cheap gap in this family | ~1.5 KB |
**`tsort`, `pr`, `pathchk` SHIPPED 2026-09-15** (eng-tsort-pr-pathchk
branch; see sec 4c below for what each does).

| tool | why it matters here | note |
|---|---|---|
| `split` `csplit` `join` | less often typed; `join` pairs with `sort -t` | ~2-3.5 KB each |
| `realpath` `timeout` `nohup` | `timeout` and `nohup` are cheap now that `SYS_KILL`/`SIGNAL` exist and `HUP` is a name | ~1.5 KB each |

### 4c. `tsort`/`pr`/`pathchk`, shipped 2026-09-15

`tsort [file]` reads whitespace/newline-separated token pairs
("a b" means a before b; "a a" declares a lone node) and prints
a topological order, one node per line -- Kahn's algorithm,
scanning from node 0 (first-appearance order) at every step so
ties resolve GNU's way, not BSD's (measured live: this host's
own BSD tsort uses a different, unspecified tie-break and this
tree follows GNU instead, since there is no common oracle for
that choice). A cycle forces the output of the first
still-unresolved node (breaking whichever edge pointed into it,
GNU's own "one edge broken" contract), reports "tsort: cycle in
data" plus the remaining node names to stderr, and exits 1. An
odd token count is a hard refusal (exit 1, nothing printed),
matching this host's own BSD tsort.

`pr [+page] [-t] [-l lines] [-h header] [-n[char][width]] [-d]
[-o offset] [file...]` paginates each file: a 5-line header
(the file's own last-modification date -- or the current time
for stdin -- its name or -h's replacement, and a page number),
up to `lines`-10 content lines, then blank padding to fill the
page even when the file ran short (measured live: BSD pr pads
every page, including the last, to the full page length, not a
fixed 5-line trailer). `-t` suppresses header/trailer/pagination
entirely and is a pure passthrough (measured: BSD pr -t never
breaks pages regardless of `-l`). A `-l` too small to leave room
for one content line under a header falls back to the `-t`
shape, matching BSD's own behaviour at the same boundary.
**SHIPPED 2026-10-08** (branch posix-pr, docs/POSIX-PR-NOTES.md):
`-column`, `-a`, `-m`, `-s[char]`, `-e[char][gap]`, `-i[char][gap]`,
`-F` and `-w width`, composed with the options above. A page of lines
is buffered (pointer table of 1024 lines + a ~38 KB text arena), cells
are cut to (W-(N-1))/N, padding is written as tabs (XCU: -e/-i assumed
for columns), and a page that does not fit is refused loudly (exit 1).
`-m` takes at most five real files: the wall is the 8-entry per-process
fd table, three held by stdin/out/err, not the io_buffer pool. pr.bin
3,686 -> 6,415 B.

`pathchk [-p] [-P] pathname...` checks each pathname against
this tree's OWN limits by default (15 characters per component
-- ProDOS's own directory-entry name_length field -- and 64 for
the whole path, MLI_PTH_MAXLN, the same cap MKPATH enforces
everywhere else in this tree), or the POSIX portable set
(`-p`: `[A-Za-z0-9._-]`, 14/255) with no existence check at all.
`-P` additionally refuses an empty pathname or a component
starting with `-`. A nonexistent intermediate directory is not
an error (the XCU's own text); an existing one that is not
itself a directory is (GET_FILE_INFO's storage_type, the same
test `mkdir -p`'s own MP_ISDIR already uses).
`split`/`csplit`/`join` SHIPPED 2026-09-15 (src/bin/split.s 2,937 B +
splitpc.s put; src/bin/csplit.s 6,705 B + csplitrn.s put, links the
house BRE engine; src/bin/join.s 3,739 B + joinio.s/joinout.s/
joinopt.s put, all three for the check-dialect as-window budget).
`split [-l n | -b n[k|m]] [-a suffixlen] [file [name]]` writes pieces
named `name` (default `x`) plus a generated letter odometer
(`aa`,`ab`,...); a source that divides evenly leaves no trailing
empty piece, an empty source gets exactly one. `csplit [-ks] [-f
prefix] [-n number] file arg...` splits at line numbers, `/bre/
[+-offset]`, `%bre%[+-offset]` (discarded, no piece file) and `{n}`
repeats of the preceding pattern; a `bre` that never matches, or a
non-increasing line number, is an error (pieces removed unless
`-k`). `join [-a n|-v n] [-e s] [-o list] [-t c] [-1 n] [-2 n] file1
file2` joins two files already sorted on a common field. Two real
bugs found live, not by inspection: split's/csplit's own 15-
character ProDOS name-length cap was measured against the WHOLE
NAME operand/`-f` prefix text, refusing an entirely ordinary `split
file /some/dir/x`-shaped invocation whose directory component pushed
the string over 15 characters even though the trailing FILENAME
component alone was short -- fixed to measure only the text after
the last `/`. csplit's own context-line boundary put the MATCHED
line at the end of the current piece instead of the start of the
next one (verified against a live host csplit before writing
RUNSEG, and again after fixing it) -- and a THIRD bug in `{n}`
repeat's own boundary surfaced from that same live comparison: a
repeat re-tested its already-established match line instead of
writing it unconditionally as the new piece's first line, which
would have produced an empty piece where the host produces a real
one (fixed via csplitrn.s's own REPMODE flag). `join`'s single-digit
`-o`/`-1`/`-2` field-number cap and `csplit`'s no-`\/`/`\%`-escape
delimiter scan are v1 simplifications, not gaps discovered live.

| tool | why it matters here | note |
|---|---|---|
| `tsort` `pr` | less often typed | ~2-3.5 KB each |
| `pathchk` `realpath` `timeout` `nohup` | `timeout` and `nohup` are cheap now that `SYS_KILL`/`SIGNAL` exist and `HUP` is a name | ~1.5 KB each |

### 4b. Big programs (PLASMA, per `docs/PLASMA-PORT.md`)

| tool | note |
|---|---|
| **`awk`** | W2 forgoes it *in assembly*; `PLASMA-PORT.md` names it as the reason PLASMA was ported. This is the single largest jump in usefulness on the list: with `awk` the machine can process its own data. POSIX awk is a large spec; a V7-awk subset (patterns, fields, printf, associative arrays, no functions) is the realistic first fence. Order 20-30 KB of module |
| ~~`patch`~~ | **SHIPPED 2026-09-17, in ASSEMBLY** (5,235 B, src/bin/patch.s + six body modules) rather than in PLASMA as this row expected: the awkward part turned out to be smaller than the row assumed, because all three input forms collapse into one triple (the hunk's OLD lines, its NEW lines, the line it claims to start at) and matching, applying, rejecting and `-R` are each written once against that. Reads unified, context AND normal listings, detected rather than declared; `-b -R -p num -i patchfile -o outfile` and the file operand. Named gaps in docs/man/patch.1: no fuzz, no `-l`, no `-N`, and one file per invocation. |
| `bc` | arbitrary precision is the point; `expr` covers integers. Useful for an 8-bit machine only as a curiosity |
| `pax` | W2 forgoes `tar` (a2til does it host-side). Revisit only if files need to move over `tip`; `uuencode` + `pax -w` would be the on-machine transport |
| `m4` | needed only if `as` grows a preprocessor; no |

## 5. Not applicable, and why (record so it is not re-litigated)

| group | names | why |
|---|---|---|
| users and groups | `chgrp chown id logname newgrp who write talk mesg` | one user, no accounts (`ANACHRONISMS` W2, ProDOS access byte) |
| scheduling and IPC | `at batch crontab ipcrm ipcs nice renice fuser logger` | no clock interrupt scheduler for `at`; no SysV IPC; a 14-slot round-robin has no nice |
| network, mail, print | `lp mailx uucp uustat uux` | none of it exists; `tip` is the serial line |
| locale and i18n | `gencat iconv locale localedef gettext msgfmt ngettext xgettext` | C locale only, 7-bit ASCII with bit 7 set |
| filesystem semantics ProDOS lacks | `ln link unlink readlink mkfifo` | no links, no FIFOs (W2); `unlink` is `rm` |
| C toolchain | `c17 cflow ctags cxref lex yacc` | no C compiler; `nas`/`as`/`ld` are the toolchain |
| SCCS | `admin delta get prs rmdel sact sccs unget val what` | version control is host-side |
| compression | `compress uncompress zcat` | LZW on a 1 MHz 6502 is possible (ShrinkIt did it) but nothing needs it |
| terminal databases | `tabs tput getconf ulimit umask` | two known terminals driven directly; no umask model |
| `asa` | Fortran carriage control | no |
| linker/object tooling | `ar strip` | `ld` links from library DIRECTORIES (`/LIB/LIBK`, given `-l k`), not archive files, so there is no archive format for `ar` to manage; maux's binaries are flat, headerless images with no symbol table embedded at all, so there is nothing for `strip` to remove (operator ruling 2026-09-17, moved out of sec 4b's "missing, large" pricing table) |

## 6. What "interestingly useful" costs

Useful means: a person sits at the machine and does a day's text and
file work without reaching for the host. In order of leverage:

1. **Merge the two lines.** Nothing else is honest until `dd`/`plasma`
   and `sed`/`more`/jobs are one tree.
2. **Option gaps that scripts hit first** (sec 2 top rows):
   `date +fmt`, `ed u`. About 5 KB across five binaries;
   `diff -u`/`-c` SHIPPED 2026-09-17 (+1,406 B) and `patch`
   with it (5,235 B), which is the whole change-moving loop
   closed: `diff -u a b > p` here, `patch a < p` there, and
   check-posixutil's own round-trip row proves the two halves
   agree byte for byte. The rest of this item stands;
   each is a day with its gate. `grep -q -x` SHIPPED 2026-09-13
   (~200 B), `mkdir -p` approved 2026-09-13, `test` SHIPPED
   2026-09-14 (+431 B -- see sec 2's own `test` row), `sort -tbfocm`
   SHIPPED 2026-09-14 (+699 B -- see sec 2's own `sort` row; one
   named gap left, `-k`'s per-field type suffixes), and `find`'s
   expression grammar + `-newer -prune -path -size -links -xdev
   -nouser -nogroup` SHIPPED 2026-09-14 (+~2.4 KB -- see sec 2's own
   `find` row; named gaps left: `-ok -perm -user -group -depth`).
3. **The small filters** (sec 4a, bold rows first): `head` (SHIPPED
   2026-09-13), `cut` (SHIPPED 2026-09-14), `xargs` (SHIPPED
   2026-09-14), `printf` (SHIPPED 2026-09-14), `basename`/`dirname`/
   `env` (SHIPPED 2026-09-14), `uuencode`/`uudecode` (SHIPPED
   2026-09-14, both algorithms -- see sec 4a's own former row, folded
   in now that they have landed: 2494/3154 B, the first way to move
   a file over `tip` without a2til on the host), `rmdir`/`tty`/
   `uname` (SHIPPED 2026-09-14, 1864/1272/1671 B -- see sec 4a's own
   former row, folded in now that they have landed), then the rest.
   ~8 utilities, ~23 KB, each a day on the existing add-a-util
   checklist.
4. **Shell to POSIX** (sec 3): functions, `set -e`, `{ }`, `${V%pat}`.
   `getopts`, `unset`, `<&N`/`<&-` and `$!` SHIPPED 2026-09-15
   (docs/SH-FEATURES.md sec 24, `sh.bin` 22,413 -> 23,500 B). ~2 KB
   left inside `sh.bin`; the ratchet and the 8-slot variable table
   (now down two slots whenever `getopts` runs) are the constraints.
   Functions need a ruling to reverse W2.
5. **`awk` in PLASMA.** The one item that changes what the machine is
   for. Sized after `nas` L3 settles the PLASMA memory wall
   (`8387615`).

After 2-4 the machine has about 70 of the 94 POSIX utilities that can
apply here, and a shell that runs an ordinary POSIX script. After 5
it can process its own output. Everything in sec 5 stays off the list.

## 6b. The close-out, 2026-09-21: 40 held-red cases became 23

Status: LIVE. `make check-posixutil` reports **565/565 conforming and
23/23 known gaps holding red** at this revision. Seventeen cases closed
in one pass, and the useful part is WHY each was cheap -- none of them
needed a new subsystem:

| closed | how, in one line |
|---|---|
| `grep -F` | an ESCAPE, not a matcher: quote `. * [ \ ^ $` and the existing BRE engine does it |
| `grep -f`, repeated `-e` | one mechanism, so they landed together: a pattern SET in `dum`-arena slots |
| `tr -C` | a conformant SPELLING of `-c`; the two differ only where a character spans >1 byte |
| `cat -u` | already true -- `COPYFD` never touches buffered stdio |
| `cat -` | stdin, checked before `MKPATH` turns it into a name ProDOS cannot hold |
| `expr ( )` | a parenthesis is the lowest grammar rule calling the highest one |
| `expr` precedence row | added, because parens that do not CHANGE anything prove nothing |
| `head -c` | the copy loop already counted; `-c` counts bytes instead of CRs |
| `xargs -r` | already true -- it has never run the utility on empty input |
| `tr` escapes | a PRE-PASS, so `EXPAND`'s range logic needed no change |
| `tr [:class:]` | a class IS a set of characters; the same pre-pass emits its members |
| `timeout 1.5m` | 60, 3600 and 216000 ticks all divide by 10 EXACTLY -- a table, no division |
| `xargs -E` | one check at FILLPEND, the choke point every token passes through |
| `xargs -L` | the tokenizer records WHICH delimiter ended a token; the batch counts them |
| `diff -b` | one comparison routine, which IS `STRCMP` when `-b` is absent |
| `od -A` | the offset column dispatches on a letter; three small printers, no new liba |
| `xargs -x` | **closed by MEASUREMENT** -- the host refuses it too; the note was wrong |

Three of those nine were flags that **asked for behaviour the tool
already had** (`cat -u`, `xargs -r`, and `tr -C` modulo the locale
argument). Refusing them was not conservatism, it was a wrong answer:
a portable script that passes `-u` for safety failed on a machine that
was already unbuffered.

**UPDATE 2026-10-08 -- `expr :` and `nl`'s pBRE closed** (branch
posix-regexlink, docs/POSIX-REGEXLINK.md, measurements in
docs/POSIX-REGEXLINK-NOTES.md). The price list above said "~4 KB of
image in two more binaries"; the measurement is `expr.bin` 3,146 ->
6,585 B (+3,439) and `nl.bin` 3,515 -> 6,460 B (+2,945), and neither
needed a unit split (the vendored `as`'s 16,128-byte window stopped
being a gate on 2026-09-21; real Merlin's 41,215 holds
manifest + regex2.s for both). `nl`'s five stages are one new file's
worth (NLMATCH) plus a `p` branch in the type parser; `expr`'s is a
new grammar level (`expr.match.s`, `:` binding tighter than `*`).
The close-out also found where the two hosts disagree with each other
and with POSIX, and each is a `hand=` row with the measurement in its
reason: BSD `nl -b 'p^$'` numbers every line (GNU, and the engine,
number only the empty one); BSD `expr` refuses arithmetic on matched
text (`expr 10 : '\(1.\)' + 1` is 11 on GNU) and calls the lone string
`0` true; BSD refuses an empty or leading-`*` pattern. One new
KNOWN GAP is born with it: a MALFORMED BRE is a safe no-match in the
engine (no compile step), so `expr foo : '\('` exits 1 where both
hosts exit 2.

### The 31 that remain, and they are not one kind of thing

**PERMANENT -- the machine or a ruling forbids it (8).** These should
not read as "not yet". They are held red so the divergence from the
host is gated rather than forgotten, and they will still be red at
1.0:

| case(s) | why it can never change here |
|---|---|
| `printf %e %f %g %a` (4) | no floating point on this machine, at all |
| `grep -E` | operator ruling: BRE only, no ERE (docs/REGEX-BRE-INTERVALS.md) |
| `mkdir -m` | ProDOS has no mode to set |
| `find -perm/-user/-group` | no rwx mapping onto the access byte, no user database |
| `strings -n` over 255 | the run buffer is one page, by design |

((`find`'s row used to bundle `-ok` and `-depth` with the three permanent ones; split 2026-10-08, see the addendum.)

**CHEAP -- the last one CLOSED 2026-10-08.** `sort -k`'s per-key
`n`/`r`/`b`/`f` modifiers: threading a per-key flag table through the
comparator was real work, not a flag, and it landed (see
docs/POSIX-SORTK-NOTES.md; `d`/`i`/`N.C` stay held red).

**TWO MORE THE HARNESS CANNOT REACH, and they belong with `tail -f`
rather than with the cheap list.** `xargs -0` needs NUL-delimited
input, and a fixture here is written as LINES -- there is no way to
express a NUL-separated file in the case format. `xargs -p` prompts on
the terminal. In both the blocker is the GATE, not the tool, exactly
as with `find -ok` and with the `tr '\n'` spelling. Shipping either
without a gate would be shipping an unmeasured feature.

**EXPENSIVE -- a subsystem, and the price is the finding (14).**

* **`pr`'s seven** were one feature: multi-column rendering. `-m`, `-a`,
  `-s`, `-e`, `-i`, `-F` and `-column` all wanted the column engine
  `prparse.s`'s header said this budget did not have. **SHIPPED
  2026-10-08** (src/bin/prcol.s, prmrg.s, prout.s; all seven rows
  retired, 17 -> 74 pr rows; docs/POSIX-PR-NOTES.md).
* **`expr :` and `nl`'s pBRE** -- CLOSED 2026-10-08, see the update
  paragraph at the end of this section. They were the same purchase:
  both needed the regex engine LINKED, and neither tool linked it. `regex.s` +

  `regex2.s` is 42 KB of stripped source against real Merlin's
  41,215-byte buffer, so it is not a flag -- it is a unit split plus
  ~4 KB of image in two more binaries.
* **`tail -f` and `xargs -p`** are the same shape as `find -ok`: they
  need an unbounded or interactive read, which `check_posixutil`'s
  run-one-command-capture-status harness cannot observe. The blocker
  is the GATE, not the tool, and pretending otherwise would ship an
  ungated feature.
* **`diff -r`** needed a directory walk `diff` did not have. **SHIPPED 2026-10-08** (docs/POSIX-DIFFR-NOTES.md): 31 new rows, the held row retired.
* ~~**`od -t`** is a type sub-language, not a flag.~~ **SHIPPED 2026-10-08**, and it was: +1,253 B and a new put module (odtype.s) -- see the `od` row in sec 2.

### Addendum 2026-10-08: the interactive harness landed, and what it closed

docs/POSIX-HARNESS.md. `check_posixutil` has a third row kind: a SCRIPT of
wait / type / append steps (scripts/posixutil_interactive.py) played against
a program that does not simply exit, on the maux console and on the host
binary under a pty, comparing the merged terminal stream and the exit
status. A `files=` value that is `bytes` is staged verbatim on both sides.
What that closed, each with the finding that made it cheap or not:

| closed | how, in one line |
|---|---|
| `tail -f` | a poll loop in `tailin.s`: reopen the file each second (a ProDOS FCB keeps its OWN EOF, so an open reader never sees growth), seek to the byte count consumed, copy raw; ends on a typed ^C with status 130 on both sides |
| `xargs -p` | the command line and `?...` to stderr, one reply line read from the terminal (stderr, `more.s`'s rule); `y`/`Y` runs, anything else skips without error |
| `xargs -0` | a branch in `TOKREAD`: only NUL delimits, every other byte is data; `-I` takes it too |
| `find -ok` | `-exec` behind a prompt (`< cmd ... path > ? `, the V7 form GNU kept; BSD words it differently and POSIX gives no text, so the prompt is pinned by `tty_has` rather than host-oracled) |
| `find -depth` | WALK defers a directory's expression to `:unwind` (`DEPTHACT`), root last; `-prune` is a no-op under it, as POSIX says |

Still held red, now each on its own row and each PERMANENT: `find -perm`,
`find -user`, `find -group` (ProDOS has no mode bits, owner or group).
Three findings from doing it: **the hosts disagree where POSIX is silent**
(BSD drops an empty `-0` item and GNU passes it; BSD runs nothing on empty
input and GNU runs the utility once; GNU quotes metacharacters in the `-p`
prompt and BSD does not) and those cases are left out of the rows rather
than picked; **siblings order differently per host file system**, so the
`-depth` fixtures are a chain; and **a2til's mount table is process-wide**,
so the gate's parallel boot groups now take a lock around image staging.

### A THIRD CEILING, and it is the real price of the cheap list

Not the one anybody watches. **FIVE splits across four units in one day, and they did not all hit
the same limit.** (`diff` and `od` both took a flag apiece and stayed
under, so it is not every utility -- but it was more than half of the
ones touched.)
`grep.s` crossed real Merlin's 41,215-byte source buffer. `tr.s`,
`timeout.s` and `xargs.s` crossed the vendored `as`'s **16,128-byte
SOURCE WINDOW** -- a different and much lower number, and the one that
decides whether a unit can be rebuilt by maux ITSELF. `tr` needed two
splits to get under it, and `xargs` needed two -- one for `-E`, then
another when `-L` pushed the manifest up and a DIFFERENT put became
the binding one.

Five in one session is a pattern rather than five coincidences. The
budget is `manifest + largest single put`, and across the utility set
that sum now sits close enough to 16,128 that **adding one flag to a
utility routinely costs a file split.** The split itself is cheap and
mechanical -- find the file's natural seam, move half into a new put,
register it in three places (the Makefile dependency, check_purity's
roster, and nothing else) -- and `check-bytes` proves each one
byte-neutral. But it is not free, and it is not visible in a line like
"`od -A` is a flag on an existing mechanism".

So when pricing the six cheap cases below, assume roughly half of them
land on a unit that is already near the window, and budget a split
apiece -- `xargs` took one per flag. The alternative -- raising the window -- is a change to `as`
itself and belongs to the self-hosting stream, not here.

### What the re-pricing found

Three of the four cases this section originally called cheap WERE
(`diff -b`, `od -A`, `xargs -L`); one was not (`sort -k`); two more
turned out to be harness-blocked rather than unimplemented; and one
(`xargs -x`) was not a gap at all -- the note claimed the host accepts
a flag it in fact refuses, and the row closed the moment it was run
against the oracle instead of read. Two of the day's closures were
corrections to REASONS rather than to code (`timeout`'s "needs a
multiply-then-divide", `xargs -x`'s "the host accepts it"), which is
an argument for running a doubted row before believing its excuse.

So the honest summary for a release note is: **eight cases are
permanent and stated, one is cheap, three are harness-blocked, and
eleven are three named purchases** -- `pr`'s column engine, linking the regex engine
into two more tools, a harness that can watch an interactive read, and
a directory walk for `diff`.

## 7. Conformance suite

**Round 3 (2026-09-14): `test`/`[`, `scripts/posixutil_cases3.py`.**
Same import shape as round 2 (`CASES3`/`KNOWN_GAPS3`, one gate, one
summary line). Oracle is this Mac's own `/bin/test`, which -- unlike
the live XCU page (POSIX.1-2024, Issue 8) -- still implements `-a`/
`-o`/`( )`, so every primary testeval.s carries could be host-oracled
rather than hand-authored, down to the `-a`-binds-tighter-than-`-o`
precedence case (chosen so the two possible groupings actually
disagree, not just happen to agree). **Score: 50/50 non-gap cases
pass, 1/1 KNOWN_GAPS3 stays red** (negative integer operands --
`STR2NUM` is unsigned-only by an explicit documented decision in
src/bin/testeval.s). `-x`'s TRUE branch (a BIN/SYS-typed file) isn't
exercised here -- the shared `stage_batch()` machinery only stages
TXT files -- and is proven instead by check-testev's own unit gate.
Building this round found a real, pre-existing bug: a shell builtin
dispatches before `RUN_PIPELINE` ever wires up redirection, so
`TEST ... > FILE` silently created nothing; fixed with `TST_REDIR`
(src/bin/shparse.s), scoped exactly like `shbltn.s`'s own
`CHCK_BLTN_ECH` guard.

**Round 2 (2026-09-14): 18 more tools, `scripts/posixutil_cases2.py`.**
`check_posixutil.py` now imports `CASES2`/`KNOWN_GAPS2` from a sibling
module (one gate, one summary line, unchanged format -- kept separate
so the original file stays one person's edit) covering `wc`, `tail`,
`uniq`, `tr`, `sort`, `od`, `find`, `diff`, `ls`, `cp`, `mv`, `rm`,
`date`, `touch`, `du`, `tee`, `echo` (the BINARY -- `MAUX_BIN['echo']`
now points at `/BASIC/BIN/ECHO` directly, since the shell builtin
shadows a bare `ECHO`), and `kill`. **Score (2026-09-14, updated after
find's grammar landed): 209/209 non-gap cases pass, 45/45 KNOWN_GAPS
stay red** (was 80/80 + 10/10 before round 2; was 188/188 + 51/51
right after round 2 first landed). Per tool (round 2, as it stands
now): `wc` 9/9 (+2 gaps), `tail` 8/8 (+2), `uniq` 8/8 (+2), `tr` 9/9
(+3), `sort` 14/14 (+6), `od` 10/10 (+4, every row hand-authored --
od.s's hex-byte default is a structural divergence from BSD/GNU's
octal-word default, not a value to translate flags around), `diff`
8/8 (+4), `ls` 7/7 (+3), `cp` 3/3 (+2), `mv` 3/3 (+2), `rm` 3/3 (+1),
`date` 2/2 (+1, `reset={'clock': False}` pins the Timemaster off so
the no-clock refusal path is deterministic), `touch` 3/3 (+2), `du`
3/3 (+1), `tee` 3/3 (+1), `echo` 3/3 (+0 -- no local divergence: this
Mac's own `/bin/echo` doesn't process XSI escapes by default either),
`kill` 5/5 (+2). `find` grew again the SAME day its expression grammar
shipped: 7/7 (+3 gap rows: `-newer`, `-prune`, operators) at round 2's
first landing -> **19/19** (18 real cases, 1 gap row) once the grammar
replaced the flag list -- see sec 2's own `find` row for what shipped and
what is still named as a gap (`-ok -perm -user -group -depth`,
consolidated into ONE row where three separate ones used to name
`-newer`/`-prune`/the operators as missing). `basename` 6/6, `dirname`
5/5, `env` 8/8, `uuencode` 9/9, `uudecode` 10/10 joined the same
module later the same day (each SHIPPED, see sec 4a). **`rmdir` 8/8,
`tty` 3/3, `uname` 9/9 joined 2026-09-14** (see sec 4a's own SHIPPED
paragraph for what each does and the real field-separator bug found
in `uname` before it landed): rmdir's rows include a non-empty
directory, a missing one, `-p` walking a full chain, `-p` stopping at
a non-empty ancestor, the no-operand usage error, and a follow-up-
command side-effect proof (mkdir.s's own precedent) that a failed
operand does not stop the rest; tty's rows include the one host-
oracled shape (redirected, non-tty stdin) and a hand row for the
live interactive console's own name (`/dev/tty1`, this harness's
boot-time console); uname's nine rows are all hand-authored (no host
equivalent for `maux`/`apple2e`/`1.0`/`65c02`) but the FIXED FIELD
ORDER claim is verified against this host's own `uname -m -s`. Suite
total after this addition: **358/358 cases conform, 56/56 known gaps
stay red.**

**`cksum` 4/4, `paste` 6/6, `fold` 4/4 joined the same module
2026-09-14** (see sec 4a for what each does; docs/man/cksum.1,
docs/man/paste.1, docs/man/fold.1). `cksum`'s four rows are ALL
hand-authored, unlike every other tool in this module: this suite's
own `files=` staging writes different bytes on the two sides (host
low-ASCII/LF, maux high-bit ASCII/CR $8D per line) and `cksum`'s
whole subject is an exact byte CRC, so the comparator's usual
line-level decoding (which hides an ENCODING difference) cannot hide
a genuinely different NUMBER computed over genuinely different
bytes -- each expected value is a hand computation of cksum.s's own
algorithm over the exact `hilines()` bytes staged for that case (see
`CKSUM_CASES`'s own module comment). One accepted divergence, named
here because paste.s's header points at this file: `paste -s` on a
file whose last line has no terminator prints a final CR where BSD
prints none (parallel mode agrees with BSD even then, re-measured at
review) -- maux's line tools always terminate the last line, tail's
own `cmp_tail_noeol` shape. `paste`'s six rows are ordinary
host-oracled cases (the default merge, a shorter file's empty
fields, `-d`, `-s`, `-` as stdin) plus one `hand=` row for the
required-operand usage error (exit 2 here, exit 1 on this host,
uname's own precedent for a by-design status difference). `fold`'s
four rows are host-oracled (default width, `-w`, `-b`, `-s`). Suite
total after this addition: **372/372 cases conform, 56/56 known gaps
stay red.**

**`nl` 9/10, `expand` 4/4, `unexpand` 6/6 joined 2026-09-14** (see
sec 4a above for what each does and the two real `unexpand` bugs
found landing it; docs/man/nl.1, docs/man/expand.1,
docs/man/unexpand.1). `expand`'s four rows and `unexpand`'s six are
all ordinary host-oracled cases (default/`-t N`/`-t list`/backspace
for `expand`; leading/interior/single-blank/`-t`/single-byte-segment
for `unexpand`). `nl`'s tenth row (`pBRE` line selection) is the
round's one new KNOWN GAP -- no regex engine is linked into this
tool's budget, rejected as a usage error, exit 2; its ninth row
(`-p` vs. the default page-delimiter reset) is `hand=`, since the
first draft of that row's own expected value under-counted the
header/footer lines nl still prints (unnumbered, per `-h`/`-f`'s
default `n`) before the real bug hunt below was even found -- caught
the same way, by the row going red against a real `nl.s` that turned
out to be RIGHT. Suite total after this addition: **391/391 cases
conform, 57/57 known gaps stay red.**

**`man` 4/4, `cal` 5/6, `strings` 7/8 joined 2026-09-15** (see sec 4
above for what each does; docs/man/man.1, docs/man/cal.1,
docs/man/strings.1). `man`'s four rows are ALL `hand=`: it has no
host equivalent, and its own full PAGE CONTENT is proven elsewhere
(check-play's live pager phase, check-textaudit's `man` PAIR row) --
this module asserts only the deterministic diagnostics (no such
page, a leading numeric section consumed rather than folded into the
name, too many operands, a `-`-leading operand). `cal`'s five
non-gap rows are ordinary host-oracled `MONTH YEAR` invocations
(September/February-leap/January-2000/December, plus a `hand=` row
for the out-of-range-month usage error, which has no common host
construct to oracle against) matched byte-for-byte against this
host's own BSD `cal`; its sixth row (`cal YEAR` alone) is the
round's one new KNOWN GAP against BSD's three-column full-year
layout, described in sec 4 above. `strings`'s seven non-gap rows are
ordinary host-oracled cases (default length-4 threshold, `-n`,
`-t x`/`-t d`/`-t o`, the per-file offset reset) plus one `hand=` row
for the bad-`-t`-argument usage error (this host's own `strings`
silently ignores an unrecognised `-t` argument instead of refusing
it); its eighth row is `hand=` for the high-bit-ASCII-is-printable
divergence described in sec 4 above -- not host-oracled because no
fixture this harness's own always-high-bit `files=` staging can
build actually diverges from the host's own classification (see
`STRINGS_CASES`'s own module comment). Suite total after this
addition, verified live (`python3 scripts/check_posixutil.py
build/play.po`): **410/410 cases conform, 58/58 known gaps stay
red** (`man` 4/4, `cal` 6/6, `strings` 8/8 in the per-tool
tally, which counts a correctly-red known-gap row as passing).
TWO REAL BUGS were found live in this round, not by inspection:
`cal`'s day-name header row (`Su Mo Tu We Th Fr Sa`) was missing
its own trailing CR, so the first week row ran on to the same
line as the header and every month's output was one line short;
and `strings`'s main scan loop tested `ISPRINT`'s carry
BACKWARDS (`bcc` where the routine's own contract says carry

**`split` 4/4, `csplit` 9/9, `join` 10/10 joined 2026-09-15**
(see sec 4 above for what each does; docs/man/split.1,
docs/man/csplit.1, docs/man/join.1). `split`'s rows are all
host-oracled (`-l 2`, `-b 4`, `-a 3`, results= over the piece
files) except suffix exhaustion, which has no common host
construct (BSD/GNU split just add a third letter past `zz`) and
is `hand=`. `csplit`'s rows are ALL `hand=` for stdout (the byte
counts it prints are computed from `hilines()` bytes exactly as
`cksum`'s own rows are, per that module's precedent -- see
`CSPLIT_CASES`'s own header) except `-s`, whose stdout is
trivially empty on both sides and so is host-oracled, piece
contents included; every `hand=` row's own byte counts and piece
boundaries were verified live against this host's own
`/usr/bin/csplit` before being pinned, and two of those live
comparisons found real csplit.s bugs before this landing (see
sec 4's own account: the matched line belonged in the wrong
piece, and a `{n}` repeat re-tested its already-established match
instead of writing it). `join`'s rows are all host-oracled
against this host's own `/usr/bin/join`, including the `-e`
row's SHAPE (the exact substitution text is pinned to the XCU
wording rather than host-compared, since BSD's own `-e` applies
outside `-o` too and this host is BSD). Suite total after this
addition, verified live (`POSIXUTIL_JOBS=4 python3
scripts/check_posixutil.py`): **435/435 cases conform, 60/60
known gaps stay red** (`split` 4/4, `csplit` 9/9, `join` 10/10 in
the per-tool tally; 0 new known-gap rows -- `split`'s suffix-
exhaustion and `csplit`'s never-matches-with/without-`-k` rows
are ordinary hand-authored cases, not gaps, since maux's own
documented behaviour in each case is the thing under test, not a
divergence from what POSIX requires).
CLEAR means printable), so every qualifying byte was treated as
a run terminator and NO string ever printed, on any input,
under any flag -- caught by this same suite's own first run
(`strings` scored 1/8) before either bug ever reached a commit.

**`tsort` 7/7, `pr` 17/17, `pathchk` 9/9 joined 2026-09-15**
(eng-tsort-pr-pathchk branch; see sec 4c above for what each
does; docs/man/tsort.1, docs/man/pr.1, docs/man/pathchk.1).
`tsort`'s rows are host-oracled where GNU and BSD cannot possibly
disagree (a chain, a self-pair node, stdin) and `hand=` wherever
this build's own first-appearance tie-break (GNU's own rule, not
BSD's -- measured live: this host's own BSD tsort visibly ties
differently) or its documented cycle-forcing contract governs (a
diamond, an isolated pair set, an odd token count, a cycle).
`pr`'s `-t` rows (no header/trailer/pagination at all) are
ordinary host-oracled cases; every row that DOES print a header
is `hand=`, because the header's own date is the file's real
last-modification time -- this suite's own staging (a2til's
write_file()) stamps `datetime.now()`, never a fixed or zero
ProDOS date, so no two runs can ever agree on that string on any
host. Each such row overwrites its own OUT with a `GREP -c` count
of a date-free substring (a title, a page-number occurrence)
before the framework's own comparison ever runs, proving the
FEATURE without asserting the date around it -- see
`PR_CASES`'s own module comment for the full mechanism. `pathchk`
mixes both: a good name and the `-p`/`-P` portability checks are
host-oracled (POSIX-precise, host-independent semantics); rows
that depend on this tree's own smaller default limits (15
characters per component, 64 for the whole path, vs. a host
filesystem's much larger NAME_MAX/PATH_MAX) are `hand=`. Suite
total after this addition, verified live (`python3
scripts/check_posixutil.py build/play.po`): **445/445 cases
conform, 67/67 known gaps stay red** (`tsort` 7/7, `pr` 17/17,
`pathchk` 9/9 in the per-tool tally, which counts a correctly-red
known-gap row as passing; `pr` carries 7 of this round's 7 new
known gaps -- `-column`/`-m`/`-a`/`-F`/`-e`/`-i`/`-s`, none
implemented, each refused as a usage error).

A REAL BUG was found live, not by inspection: `pathchk.s` had
its `OPTLIST` data ("pP" + a NUL) declared textually BEFORE
`START` in the source -- the assembler emits bytes in source
order, so those three bytes landed at LOAD_BASE itself and the
kernel's loader jumped straight into them as the first
instructions, crashing (a wild jump into a BRK trap) on every
single invocation, including a bare `PATHCHK` with zero operands
that never even reaches the option parser. Every other tool in
this tree puts `START` immediately after its equates for exactly
this reason; `mkdir.s`'s own layout was the precedent this should
have copied from the start. Found by check-posixutil's own first
run (`pathchk` scored 0/9, every row timing out rather than
failing a comparison) and confirmed with an isolated single-step
session against a private `mcp_supervisor` instance (never the
long-lived shared one interactive tools default to, which turned
out to be genuinely shared with concurrent sessions and produced
misleading cross-talk on the first debugging attempt) -- fixed by
moving `OPTLIST` to just before `USAGEMSG`, after every routine,
matching `mkdir.s`'s convention. A second, smaller bug in the
same round: `pr`'s `-n` line numbering started its counter at 0
instead of 1 (`PRFILE`'s init `stz`'d `LINENOLO` instead of
seeding it with 1), caught by the same suite's own `-t -n`
row before it ever reached a commit.

Two genuine engineering findings from building this round, both
reported rather than fixed per the task brief:

  1. **`kill -9 $$` hangs the console.** Signalling your OWN
     interactive shell with SIGKILL while it sits blocked in
     `SC_WAIT` for the very `kill` child that is about to kill it
     zombifies a process the kernel then tries to `SCH_WAKEUP` --
     which never runs again, so the console gets no further prompt.
     `kill -0 $$` (same target, signal 0) is fine, exit 0: this
     surfaced only because a first draft of the test assumed the
     interactive shell was root-tier-protected (it is not) and tried
     `-9` on it too. Not staged as a running case -- it would hang
     (and poison) whatever boot group it landed in. See
     `scripts/posixutil_cases2.py`'s `KILL_CASES` header comment.
     **RULED 2026-09-14: refused (the cheap one); a `bye` that does
     something useful is a later feature.** `PRC_KILL`
     (procspawn2.s :slotok) now refuses a force-kill of the pid whose
     PARENT is itself a direct child of root tier -- the one process
     the boot image ever hands a console to -- with the same
     `ERR_INVAL` the root tier itself already got; `kill -0 $$`
     (signal 0) is untouched. Gated by `check-jobctl-a`'s
     `shell_protected` case (`scripts/check_jobctl_a.py`), which also
     proves the teeth: reverting the refusal hangs the case's own
     bounded wait rather than the gate itself.
     **SUPERSEDED 2026-10-18 (RULINGS-1): the refusal is lifted -- init
     respawns the shell -- and `shell_protected` is replaced by the
     `shell_kill`/`shell_orphan`/`shell_raw`/`shell_flap` cases of
     `check-jobctl-a` (docs/RULINGS-1-NOTES.md).**
  2. **A stale comment in `src/bin/lsprint.s`.** `PRINTDATE`'s own
     header says a zero/invalid date prints "'-' padded to 16
     chars"; the actual `DASHFIELD` constant is `dfb
     $AD,$A0,$A0,$A0,$A0,$A0` -- six bytes, not sixteen. Behavior is
     unaffected (nothing reads the comment); not gated, just noted
     here per the tree's own "stale comments deter work" lesson.

One planned case was dropped, not shipped flaky: `ls -l`'s date
column was going to be a hand row assuming `a2til`'s staged files
carry no mod-date stamp (PRINTDATE's zero-date branch). They do --
`a2til.prodos.write()` stamps the host's live wall clock with no
override in its public API -- so a byte-exact `-l` row would need to
predict, at comparison time, a clock reading made at staging time:
the same timing-race shape this tree's own memory already warns
about. `TYPE` and `EOF` (size) were confirmed byte-exact against
`PRINTENTLONG`'s field order in the same run; only the `DATE` column
is the open problem, left for whoever wires `Volume.set_file_info`'s
`last_mod=` through a staging hook.

**`nohup` 4/4, `timeout` 10/10, `realpath` 10/10 joined 2026-09-15**
(eng-nohup-timeout-realpath, cut from a9034eb; see sec 4 above for
what each does; docs/man/nohup.1, docs/man/timeout.1,
docs/man/realpath.1). ALL 24 rows across the three tools are
`hand=`: `nohup`'s four (this suite redirects stdout, so the
tty-dependent redirect/notice path never fires here at all -- that
is check-play's own phase instead -- and this suite's own harness
never exports `PATH`, so even the pure pass-through rows are hand-
authored rather than risking a host `nohup` that resolves a bare
child-utility name differently); `timeout`'s ten (no host `timeout`
exists on this Mac at all); `realpath`'s ten (its own base directory
is per-case, so `hand` is used in its CALLABLE form -- `case['hand']
(base)`, `base` being check_posixutil.py's own per-case maux
directory -- to compute the expected absolute path directly in
Python, sidestepping the shell `test "$(...)"` construction this
tool's own task brief first proposed). Suite total after this
addition, verified live (`python3 scripts/check_posixutil.py`):
**436/436 cases conform, 61/61 known gaps stay red** (`nohup` 4/4,
`timeout` 10/10, `realpath` 10/10 in the per-tool tally). This
picks up from this section's own last recorded checkpoint here
(410/410 + 58, the `man`/`cal`/`strings` landing) rather than from
a9034eb's own measured 412/412 + 60 (two cases and two gaps this
file's own narrative never got a paragraph for) -- the delta this
round actually added is +24 cases (+1 known gap, `timeout`'s
fractional-duration row) over whatever the tree held at
a9034eb, and BOTH totals are expected to be renumbered again once
the three sibling branches cut from the same commit land.

`timeout`'s own KNOWN GAP: a fractional duration (`1.5`) is refused
outright (exit 125) rather than parsed or truncated -- `TO_PARSEDUR`
has no decimal-point handling at all, by construction (its own
header).

ONE REAL BUG was found and fixed before landing, live against
check-textaudit rather than check-posixutil (whose own harness
links a real timer, so the bug never manifested there): `timeout`'s
`SYS_TICK` mode-0 refusal ran AFTER `SC_SPAWN`, so on a machine with
no timer (check-textaudit's own stripped harness) the child was
spawned, then `timeout` exited 125 without ever reaping it -- a
zombie left in the process table, which corrupted that harness's
own bookkeeping for whatever ran next in the same boot group (`cp`,
two commands later in group c's own script, stopped being observed
exiting at all). Fixed by moving the tick-mode check to BEFORE the
spawn, sleep.s's own rule ("the mode check comes before any
arithmetic") applied to a case sleep.s itself never had to
consider, since it never spawns anything of its own.

**Round 1** (below, unchanged): a byte-exact
XCU conformance gate for ten small utilities -- `cat`, `cmp`, `comm`,
`expr`, `head`, `grep`, `mkdir`, `pwd`, `sleep`, `true`, `false`. Every
case's spec clause is quoted from the XCU page it comes from; stdout
and exit status (and any named result file) are compared against the
host's own binary wherever BSD/GNU and POSIX can possibly agree, and
hand-authored straight from the spec text where they cannot (a
documented maux gap, `expr`'s 16-bit engine against a 64-bit host, or
a ProDOS pathname with no host analogue).

**Score: 80/80 non-gap cases pass, 10/10 KNOWN_GAPS cases stay red**
(exit 0 requires both; was 15/15 known gaps before 2026-09-13's three
bug fixes below retired five rows -- three named gaps plus the usage
row, which is now hand-authored rather than a gap; see finding 3).
Per tool: cat 6/6 (+2 gaps), cmp 7/7, comm 7/7, expr 23/23 (+2 gaps),
grep 16/16 (+4 gaps), head 8/8 (+1 gap), mkdir 5/5 (+1 gap), pwd 1/1,
sleep 3/3, true 2/2, false 2/2.

Named gaps (all expected-red, verified staying red): `cat -u` and
`cat -`'s stdin operand (cat.s parses no options at all); `expr`'s `:`
match operator and `()` grouping (expr.eval.s's grammar has neither
level, by the task brief that built it); `grep -E`, `-F`, `-f`, and a
second `-e` (grep.s's own header: "not v1"); `mkdir -m` (OPTLIST is
just `"p"`); `head -c` (head.s is a line counter, no byte-count mode).

Three real maux BUGS the suite found, **fixed 2026-09-13** (source
inspection, not just header comments, and confirmed against a live
host binary, then re-verified byte-exact against the host once fixed):

1. **`cmp`'s plain differ message went to the wrong stream.** POSIX's
   STDOUT section gives the `"%s %s differ: char %d, line %d"` format
   and says it is written to standard output; `cmprpt.s`'s `DIFFER`
   routine put it on `FD_STDERR` unconditionally. A live BSD `cmp`
   puts it on stdout. Fix: `DIFFER`'s `PUTS`/`PUTC` calls now target
   `FD_STDOUT`; `cmp.s`'s own CONTRACT comment corrected to match.
2. **`comm`'s column leads were not adaptive.** POSIX's `<lead>` for
   columns 2 and 3 depends on which of `-1`/`-2` are selected (a null
   string when the column before it is suppressed); `comm.s`'s
   `OUT2`/`OUT3` always emitted a fixed one and two tabs. Verified
   against a live BSD `comm` with `-1`, `-2`, and `-12`. Fix: `OUT2`/
   `OUT3` now test `WANT1`/`WANT2` per POSIX's rule before each `<tab>`
   (`make check-comm`'s own fixtures, which had hardcoded the old
   fixed-tab shape as "the contract", were updated to the adaptive one
   and re-verified byte-exact).
3. **`comm`'s usage-error path never terminated its line.** Any wrong
   operand count (0, 1, or 3 files) printed `usage: comm [-123] file1
   file2` with no trailing `$8D` -- unlike every sibling util's usage
   string (`dfb $8D,0` baked into the message) or `cmp.s`'s own
   `USAGERR` (a separate `PUTC` after `PUTS`), `comm.s`'s `:usage` did
   neither, so the shell's next prompt drew its `$` onto the SAME row.
   Driven directly against the emulator: the shell itself is NOT
   hung -- a command typed right after the broken line runs and
   returns a normal prompt with no `^C` needed. What DOES treat it as
   stuck is any automation whose "at the prompt" check requires the
   last screen row to be exactly `$` (this suite's own harness is
   exactly that check), which is what "needs `^C`" was describing: the
   HARNESS recovering from its own stalled wait, not the shell
   recovering from a real hang. Grepped the whole tree for the same
   shape (a usage/error `PUTS` immediately followed by `EXIT`, no CR
   either baked into the string or `PUTC`'d separately) -- every other
   hit already ends its message in `dfb $8D,$00`; `comm.s`'s
   `USAGEMSG` was the only one missing it. Fix: `:usage` now `PUTC`s a
   trailing `$8D` before `EXIT`, matching `cmp.s`'s `USAGERR` shape.
   Retiring this row surfaced a SEPARATE, legitimate divergence the
   hang had been masking (see below): maux's usage exit status is 2
   (this tree's uniform convention, cited in `comm.s`'s own header)
   where BSD `comm` happens to pick 1 for the identical case; POSIX's
   EXIT STATUS clause for `comm` is the generic ">0 An error
   occurred.", not a fixed number, so both are conformant and the row
   is now hand-authored (`rc=2`) rather than host-oracled.

One encoding fact, not a bug, stays hand-authored rather than
host-oracled: `cmp -l`'s raw octal byte dump reflects maux's own
high-bit-set text convention (a live low-bit host file reports `0143
0144` for the same two letters maux reports as `0343 0344`).

Teeth proven 2026-09-13: flipping `head.s`'s `DEFN` from 10 to 9 (one
`equ`), rebuilding, and re-running turned exactly the `head/default is
-n 10` row red (`stdout expected=[...10] got=[...9]`) with every other
row, including the `-c` KNOWN_GAPS row, unchanged; restoring `DEFN` and
rebuilding returned the suite to 80/80 green.

### Round two, 2026-09-14: the remaining eighteen tools

`scripts/posixutil_cases2.py` (imported by the same gate, one summary
line): wc tail uniq tr sort od find diff ls cp mv rm date touch du tee
echo (the BINARY, `/BASIC/BIN/ECHO`, because the shell builtin shadows a
bare `echo`) and kill. Measured at the merge tree (87b5185):

    [check-posixutil] PASS: 188/188 cases conform, 51/51 known gaps stayed red

That is 239 rows: round one's 80 + 10, plus round two's 108 + 41. Every
sec 2 option gap for these tools is a real, expected-red row. Hand-authored
rows and why (the module docstring carries the full reasoning): wc's
column whitespace (BSD pads to 8, maux does not; values agree), od's
default (hex bytes by ruling A3 vs BSD's octal words), date under a
pinned-off clock card (the documented no-clock path; the live-clock
format is check_sumdate's job), and every tree-mutating tool (cp -r, mv,
rm -r, touch) verified by a follow-up command in the same session since
the host oracle runs one process per case.

### Round three, 2026-09-14: `test`/`[` reaches POSIX.1-2024

`scripts/posixutil_cases3.py` (same gate, same one summary line):
50 host-oracled rows covering every primary testeval.s carries --
file tests, string tests, integer comparisons (including a
non-numeric operand's exit 2), `!`, `-a`/`-o` with precedence,
`( expr )` grouping, and the eight always-false primaries -- plus
one hand-explained KNOWN_GAPS3 row. Measured after the fix below:

    [check-posixutil] PASS: 239/239 cases conform, 52/52 known gaps stayed red

That is 290 rows total: the 239 above, plus round three's 51 (50 +
1 gap). Every case's `spec=` quotes the exact XCU sentence it proves;
the oracle is `/bin/test` itself, verified live (2026-09-14) to still
honor the `-a`-binds-tighter-than-`-o` precedence the current XCU page
marks obsolescent-and-removed (Issue 8, Austin Group Defect 1330) --
so this round's rows demonstrate real behavior, not a guess about
what the removed grammar used to mean.

**A real bug found and fixed while building this round, not merely
reported:** every one of the first ~50 rows failed with "OUT: no such
file" -- `TEST args > OUT` created no file at all. `test`/`[` is a
shell BUILTIN (`shparse.s` CHCK_BLTN_TST), and builtins dispatch
BEFORE `RUN_PIPELINE` ever applies redirection (`shbltn.s`'s own
`CHCK_BLTN_ECH` documents this exact trap for `echo`, and falls
through to a real spawn of the external binary when redirected --
`test` has no external binary to fall through to, so it had been
silently swallowing its own output redirection all along, unnoticed
because `test` writes nothing to stdout in the first place). Fixed
with `TST_REDIR` (src/bin/shparse.s): open-then-immediately-close the
plain fd-1 target, scoped exactly like `CHCK_BLTN_ECH`'s own guard
(no `<`, no `N>&M`, fd 1 only) and safe for the reason that guard's
own header names -- no per-stage `CMD_OUTFD`/`CHILDMAP` bookkeeping
is touched, so there is no state left over to corrupt the next
command's own redirect.

Teeth proven 2026-09-14: turning `NOT_EXPR` into an unconditional
`jmp PRIMARY` (a no-op `!`) turned exactly the 6 negation-dependent
rows red in check-testev (`! ""`, `! foo`, `! -f TESTF`, `! -f NOPE`,
`! foo = bar`, `! ( foo -a "" )`) and exactly the 3 negation-dependent
rows red here (236/239: the two plain `!` rows plus the composed
`! ( expr -a expr )` row), with every other row -- including the
`-a`/`-o`/`( )` rows that do NOT touch `!` -- unchanged; restoring
`NOT_EXPR` returned both gates to green (61/61, 239/239).

**Finding, reported not fixed: `kill -9 $$` from the interactive shell
hangs the console.** `kill -0 $$` is an ordinary live-pid probe (exit 0),
so `$$` is not root-tier-protected as first assumed; the -9 force path
marks the shell's PCB zombie while the shell is blocked in SC_WAIT on
kill itself, and kill's exit then wakes a zombie parent. Read from
procspawn2.s's PRC_KILL, reproduced live, not staged as a row because it
takes the whole boot group with it. Without an init to respawn the
console shell, SIGKILL of the console shell needs either refusal or a
respawn; a decision, not a patch.

**RULED 2026-09-14: refused (the cheap one); a `bye` that does
something useful is a later feature.** PRC_KILL's `:slotok` (this same
routine) now refuses a force-kill of the pid whose PARENT is itself a
direct child of root tier -- pid 1 spawns exactly one process ever,
the console shell -- with the ROOT TIER's own `ERR_INVAL`; `kill -0
$$` is unaffected, and a full-screen program the shell spawned (vi,
`more`) is a child of the SHELL, not of pid 1, so it stays killable.
Gated by `check-jobctl-a`'s `shell_protected` case
(`scripts/check_jobctl_a.py`), teeth proven by reverting the check
(the console hangs, bounded by the case's own `settle()` rather than
wedging the gate).

**SUPERSEDED 2026-10-18 (RULINGS-1):** the refusal is lifted (init
respawns the console shell, rate-limited with a back-off since KFIX7)
and `shell_protected` is replaced by `check-jobctl-a`'s `shell_kill`,
`shell_orphan`, `shell_raw` and `shell_flap` cases.

**Not expressible on this host:** echo's XSI escapes. BSD `/bin/echo`
does not interpret `\n` or `-e` either, so there is no local divergence
to demonstrate; it would only show against GNU coreutils on the box.
