# Known limitations and conformance gaps

Status: LIVE, 2026-10-20 (re-audited against the month's commits: the POSIX
scoreboard, the type-ahead entry, the text convention and the serial section
are new or corrected). This is the release-facing summary; the linked live
documents and gates own the detailed inventories.

## Hardware and protection

- maux is single-user and intentionally has no process memory protection. A
  process can address machine I/O and can corrupt the system.
- The original pre-v3 UltraTerm is not supported: the current driver can leave
  external slot-3 ROM selected across interrupts. The mechanism and proposed
  fix are in `docs/CONSOLE.md` section 13.
- Sparse and aliased auxiliary-memory populations have not been independently
  exercised. The pinned emulator covers the dense/no-alias probe path.
- Physical-hardware coverage is narrower than emulator coverage. See
  `docs/SUPPORT.md`; unmeasured configurations are marked unverified rather
  than inferred from emulation.
- An Apple IIc is a different port, not a configuration, and has not been
  tried: maux is bank-per-process on a RamWorks-family card in the //e's aux
  slot and a //c has no aux slot (Z-RAM, with banks 0-15 and the motherboard's
  aux as bank 0, is the //c's equivalent route). The //c has a built-in 60 Hz
  vertical-blanking interrupt and no clock at all. Its technical reference
  also says any access to `$C070-$C07F` "resets the VBL interrupt flag", and
  Z-RAM's bank-select register is `$C073`, so on a //c every bank switch
  would clear the flag of the machine's only periodic interrupt and ticks
  would be lost in proportion to the context-switch rate; this cannot
  reproduce on a //e or in the emulator. From the Apple //c Technical
  Reference, 2nd ed. (`learning:01M0VVKFVPN74N9YEBEFF5R1GB`) and AE's Z-Ram
  Ultra manual (`learning:01M0J22FXFZK5CF8QJ9KTYC2FY`); not measured.

## Serial line (Super Serial Card, `/dev/ttya0`, `tip`)

Supported on the emulated rig (docs/SUPPORT.md). Named gaps, each a decision
and not an accident (docs/SERIAL.md sec 3d):

- No carrier detect: the line never "hangs up"; only `~.` ends a `tip` session.
- No baud, parity or `stty` control of the line from maux, and no hardware
  handshake: flow control is software XON/XOFF only (the driver sends DC3 at
  192 buffered bytes and DC1 below 64), which a host pty honours and a bare
  RS-232 peer may not.
- `tip` has `~.`, `~?` and `~~` and nothing else: no `~!`, no `~^Z`, no file
  transfer (`~>`/`~<`).
- The receive path is polled from the 60 Hz tick into a 256-byte ring. The
  gates used a modem that is infinitely fast; a real 9600-baud line fills
  about 16 bytes per tick, and its overrun behaviour on real hardware is
  untested.
- The console is a 7-bit VT102: bit 7 from the host is dropped, and
  `serbridge` (the host-side daemon) folds a UTF-8 character it cannot send to
  one `?`.
- No physical Super Serial Card has been run, and the RTL backend and MAME
  have no serial model.

## System scope

- There is no network stack or C compiler. Storage and timestamps inherit
  ProDOS semantics. Text is high-bit-set 7-bit ASCII with carriage-return line
  endings (maux text); `nas` and `make` also read ProDOS-standard low-bit text
  since KFIX10 (680d5a5f), and most other tools read only maux text.
- Self-hosting means the native `make` + `nas` + `ld` assembly-world rebuild.
  Host tools still transform/stage source, build ProDOS media, drive the
  emulator, and compare outputs; this is not a closed bootstrap from bare
  source media.
- Apple and third-party ROMs are required but not distributed. Exact required
  identities and lawful operator responsibilities are in
  `docs/DEPENDENCIES.md`.

## Named software gaps

- `ls` reads a whole directory into memory before sorting it, so there is a
  real cap on how many entries it can show: **255**, raised from 128 on
  2026-09-20 after the operator hit the old one simply by running `ls` on the
  149-page manual directory. Past the cap it lists the first 255 and says so
  on stderr. 255 is the ceiling for the current shape rather than a taste --
  the entry count is one byte and the sort indexes are one byte each -- so
  going further means widening both and the insertion sort with them.
  Gated by `check-lsbig`.

- **OPEN, re-measured 2026-10-20: fast type-ahead can leave blank rows
  between prompts.** The 2026-09-20 report was two prompts on one row plus a
  blank row. Since then the shell reads its prompt line through the userland
  line editor (TAB-A2, fb6bafed); three bursts of six Returns at an idle
  40-column prompt (18 Returns) on 2026-10-20 produced **no row with two
  prompts**, but did still leave blank rows between some of them. The
  mechanism below was written for the 2026-09-20 behaviour and has not been
  re-derived for the blank rows alone. The original report was against `more`
  (paging to EOF with Return rather than quitting with `q`), but `more` is not involved: six
  Returns delivered in one burst at an idle prompt reproduce it exactly, and
  so does type-ahead during `sleep`. The same six Returns typed with gaps are
  clean, one prompt per row.

  The mechanism is an ordering race between the echo and the prompt. The cook
  drains queued keys until a line completes, then stops; the reader consumes
  that line, and the shell prints its prompt. Between the read returning and
  the prompt reaching the glass, the tick can cook the NEXT queued Return and
  echo its CR -- so that newline is spent before the prompt instead of after
  it, and the following prompt lands beside its predecessor. Each occurrence
  costs one blank row and one doubled prompt; six burst Returns produced two.

  It is COSMETIC: nothing is lost, no keystroke is dropped, and the shell
  works normally afterwards. The same shape is already an accepted outcome of
  `^C` (`docs/CONSOLE.md` sec 4, and `check-jobctl-a`'s own `at_prompt`
  matches `$ $`), which is why no gate noticed.

  The principled fix is to echo a completed line's CR when the READER takes
  the line rather than when the cook completes it, which puts the newline
  immediately before the prompt by construction. That is a change to the line
  discipline whose neighbours already carry two review readline findings about
  echo ordering, so it wants its own session rather than a quick patch.

- ~~There is no init, and two ordinary actions end the session.~~ **BOTH
  CLOSED 2026-09-20.** `exit` at the console prompt used to remove the only
  shell and leave a machine that would never run a program again: pid 1
  respawns it now, rate-limited, gated by `check-init`. And `chvt N` used
  to be a one-way trip to a console nobody read -- it echoed what you typed
  and ran none of it, and `chvt 1` typed there did not come back. `chvt`
  now gives that console a shell on the way in, LAZILY (operator ruling:
  four at most, and a shell appears the first time someone actually goes
  there, so the boot topology is unchanged). It asks the new `SYS_VCSTAT`
  first, which reports console attachment from fd 0 rather than who is
  asleep on the tty -- the difference matters precisely when that console's
  shell is busy running a command, which is when people switch away and
  back. Gated by `check-lazyvc`, five cases, teeth proven.

  init also runs `/etc/RC` to completion before it starts the console
  shell, so a disk can come up warmed the way its owner left it -- a `PATH`,
  a `chvt 2`, whatever. It is `rc` and not `profile` because warming the box
  is a once-per-boot job, where a profile would re-run on every console
  `chvt` creates. A disk with no rc pays one failed `open`: a bare spawn
  would have loaded 26 KB of shell on every boot only for it to find no
  script, and `check-init` case 5a gates that cost rather than the feature.

- The ordinary end-to-end registry pins two live shell defects: a parenthesised
  group cannot be a pipeline stage, and nested command substitution is refused.
  The pinning mechanism turns red if either result changes without review.
- ~~An orphaned background subshell can take the kernel into its BRK trap.~~
  **CLOSED 2026-09-20.** It was a language-card write-enable, not a scheduler
  or reaper defect: `sh` installs a second code segment into its own card at
  startup and held the card's machine-wide write-enable across a 4 KB copy,
  so when another process closed its own LC bracket with a write-protect in
  between, the rest of that copy was dropped by the hardware without a fault
  and `sh` then called into a segment that was not there. Write-enable is now
  the steady state tree-wide and nothing protects; the rule, the measurement
  and the two gates are in [LANGUAGE-CARD.md](LANGUAGE-CARD.md).
- ~~The language card's BANK select has the same shape.~~ **CLOSED
  2026-09-20**, in the commit after the write-enable one. The kernel now
  saves a preempted process's LC bank at its doors and restores it on the
  three resume paths; the saved byte lives in the process's own zero page,
  so the storage costs no kernel-image bytes and needs no pid-indexed table.
  Gated by `check-lcbank`, which fault-injects the saved value and checks
  the kernel follows it in both directions (teeth proven by neutralising the
  restores). Details in [LANGUAGE-CARD.md](LANGUAGE-CARD.md). The original
  entry, for the record: Bank-select is global machine state too, and liba stdio
  holds the non-default bank across its buffer copies (up to 512 bytes in the
  flush path) while `ex`/`vi` keep `EX_SHADOW` and `ld`'s core keeps its
  workspace in the bank-sensitive `$D000-$DFFF` window. A process preempted
  inside stdio's window resumes with whichever bank someone else selected --
  and ProDOS selects the default bank on every MLI call, so the kernel
  servicing a tick is enough to do it. The consequence is a handful of
  buffered bytes written into the wrong 4 KB bank: corruption, not a halt.
  Not observed in any gate; found by reading, while fixing the write-enable.
  Unlike write-enable, bank-select IS readable (`$C011`), so this one has two
  possible fixes -- a per-process save/restore in the kernel, or interrupt-
  masked windows in liba -- and both are costed in
  [LANGUAGE-CARD.md](LANGUAGE-CARD.md). Eliminating the second bank is not an
  option: stdio needs all 4 KB of it (8 streams x 512 B) and the bank-agnostic
  common region is already carrying `sh`'s code segment.
- The measured POSIX scoreboard (2026-10-20, kernel of dce613ce): 850 utility
  cases -- 836 conforming and 14 declared gaps held red -- plus 137/137 `sed`
  on a BSD host (138/138 where GNU sed is the oracle: one case is GNU-only and
  skipped on BSD), 109/109 scored regex cases (28 regcomp-error rows reported
  unscored, 75 skipped), 92/92 `ex` and 72/72 `vi`. `check-posixutil` reports
  the utility total as "836/836 cases conform, 14/14 known gaps stayed red": a
  gap that starts PASSING is an error there too, so the number cannot drift in
  either direction without a commit that says so. The gaps in this section
  closed since the 2026-09-21 scoreboard (588 cases, 23 gaps): `od -t`
  (973cb4f8), `sort -k`'s per-key modifiers (397b25af), `diff -r` (a0727f33)
  and the regex engine linked into `expr` and `nl` (1ed81d87), all merged
  2026-10-09; `pr`'s column engine (docs/POSIX-PR-NOTES.md); `tail -f`,
  `xargs -0`/`-p` and `find -ok`/`-depth` (the interactive harness,
  docs/POSIX-HARNESS.md); and vi's named registers and multi-line
  characterwise yank (3b8aa5d9, 2026-10-07; `vi` was 64/66).

  The 14 that remain are mostly not "not yet": no floating point for
  `printf %e/%f/%g/%a`; the BRE-only ruling for `grep -E`; no ProDOS mode for
  `mkdir -m`; no rwx mapping and no user database for `find -perm/-user/-group`;
  a one-page run buffer for `strings -n`; and `sort -k`'s `d`, `i` and `N.C`.
  [POSIX-GAPS.md](POSIX-GAPS.md) sec 6b holds the split and the cost of each.
- `wc`'s counters are 16-bit and SATURATE at 65,535 rather than wrapping: a
  pinned count is visibly wrong where a wrapped one looks right. Per file this
  needs input larger than a process bank; since `wc` grew a totals line
  (2026-09-17) the SUM of ordinary files reaches it, and the end-to-end
  registry pins a case whose three ~46 KB operands total 140,544. Widening the
  counters is the named trigger for retiring that entry.
- Fourteen utility cases are deliberately held red (above) and named in
  `docs/POSIX-GAPS.md`; there are also historical option families and
  operations that have no ProDOS analogue that are not scored at all.
- Important shell divergences include no functions, no arithmetic expansion,
  and no pipeline-fed `while` body. `awk`, `bc`, `m4`, and `pax` are the large
  applicable POSIX utilities not supplied. The utility inventory is
  `docs/POSIX-GAPS.md`; the open shell divergences (G1..G28: a double-quoted
  glob character in a mixed word, a loop in an EXIT trap, a `$( )` left open
  across lines, and the rest) are its sec 3b, each with the input that shows
  it and the gate that pins it.

The locked verilogapple revision also emits a libc++ mutex exception while a
freshly queried MCP worker shuts down. The dependency check has already
received and validated the revision response when this occurs; it remains a
named emulator cleanup defect, not a silent success condition.

## Named follow-ups

- **A typed pathname is capped at 64 characters in its VIRTUAL form,
  not its physical one** (docs/VROOT.md said the cap would move to the
  physical form; it did not, 2026-10-10). The kernel's two pathname
  slots and liba's `MKPATH` buffers are 65 bytes and hold what the user
  typed, so `/mnt/MAUX/RO/<A15>/<B15>/<C15>/DDD` (64) fits while its
  physical form (`/MAUX/RO/...`, 60) has four characters of MLI room
  to spare that no user can reach. docs/VROOT-NOTES.md M3 has the
  numbers. Trigger: a real tree whose deepest path is within four
  characters of 64 under `/mnt`.
- **proshim passes ProDOS paths straight through**: a ProDOS 8
  program run under `bye` or proshim sees PHYSICAL names (`/MAUX/...`),
  never `/mnt/MAUX/...` or `/bin`. That is what such a program expects,
  and it is the only translation boundary this stream left alone.

- **PRC_CANONPATH copies an absolute path verbatim, so `//` reaches
  ProDOS and is rejected** (`procfd2.s`; found 2026-10-07 by `du` with no
  operand, which joined `/mnt/MAUX/` + `/` + name -- `du` and `find` now
  join with one slash themselves). POSIX says a sequence of slashes is
  one slash, so the kernel should collapse them for every caller. Kernel
  flat headroom has one owner right now. Trigger: any tool outside `du`
  that joins a prefix to a name by hand, or the day kernel headroom is
  free (docs/DU-DF.md; docs/DU-DF-NOTES.md has the measurement).

- **`ls` at a console of a segment-less kernel prints one name per line**
  (2026-10-08, docs/TTY-TYPEAHEAD-BELL-NOTES.md "Audit"): SYS_TTYGEO and
  SYS_TTYMODE are cold-segment bodies; the manifests that do not carry the
  segment (every test kernel except MAUXPLAY) answer ERR_NOSYS from
  `procdevs.s`, so `ls`'s column setup sees "not a console" and `ls -C`,
  `more` paging, `stty`, `reset`, `vi` and `tip` get no geometry or mode
  control there. No shipped image is affected (the play image carries the
  segment) and no current gate runs those tools at a console on a
  segment-less kernel (check-textaudit's `more`/`vidmode` rows redirect
  stdout and take the same carry-set path either way). Trigger: any
  harness that runs stty/vi/more/ls-at-a-console on a segment-less kernel
  -- restore the plain bodies in `procdevs.s` (about 210 B per image, which
  is what pushed the pinned test kernels past the io_buffer ceiling).

- **`#!` scripts run only when `sh` spawns them** (2026-10-11,
  docs/EXEC-SHEBANG.md Part 2, docs/EXEC-SHEBANG-NOTES.md): the placement
  is V7's -- the SHELL rewrites argv to `interp [arg] script args...` when
  the kernel answers ERR_NOEXEC (`SHEB_FIX`, sh's cold segment). Every
  program that calls SC_SPAWN itself -- `find -exec`, `xargs`, `env`,
  `nohup`, `time`, `timeout`, `make` recipes, `vi`/`ex` shell-outs that do
  not go through `sh` -- gets ERR_NOEXEC and says so ("cannot execute",
  "exec failed"...). The brief said maux has no such spawner; it has about
  a dozen. Nesting is two rewrites (a script whose interpreter is a
  script); a third is refused. Trigger: any real workflow that needs
  `find -exec script` or `xargs script` -- move SHEB_FIX's rewrite into
  liba behind one `SC_SPAWNX` (about 300 B in each caller), or into the
  kernel (the 4.2BSD placement, about 300 B flat).
- **`sh` takes `-e`, `-x`, `-s` and `-c`** (2026-10-11, `-c` 2026-10-21):
  `sh [-ex] SCRIPT [ARGS]` is V7's form and `$0` is the script path;
  `sh -s [ARGS]` (POSIX) reads commands from stdin with every operand a
  positional parameter; `sh -c STRING [NAME [ARG...]]` (POSIX) runs one
  line (a newline inside STRING separates nothing). The older bare `SH ARG1 ARG2 < SCRIPT` shape
  (argc >= 3, script on fd 0) is gone -- an operand names the script now --
  so the two in-tree users say `-s`: check-shlang's etymology demo and the
  shlang harness's argv (`SCRIPT -s ONE TWO THREE`).
- **Test kernels still hand `/dev` paths to ProDOS** (2026-10-11,
  docs/EXEC-SHEBANG.md Part 3): `VR_DEVCALL` is a cold-segment body, so
  only the play kernel refuses CREATE/DESTROY/RENAME/SET_FILE_INFO/stat on
  `/dev/...` itself; the 27 stub-segment test kernels keep the old
  behaviour (the MLI hunts a volume named DEV). Trigger: a gate that
  creates or removes `/dev` names on a segment-less kernel with a real
  Disk ][ attached.
- **`ls` carries its own `/dev` device test** (`LS_DEVCHK`, lstop.s, about
  280 B): the kernel's GET_FILE_INFO answers for `/dev/NAME` now, so it is a
  second opinion that can be deleted. Not done here (size, not safety).

## PLASMA compiler (`plasm`, PLASM-FIX 2026-10-22)

`/bin/plasm` is Dave's plasm, unchanged except its load address
(RELADDR $2000, patched on a scratch copy by the Makefile), cooked into one
program. Accepted limits (docs/PLASM-FIX-NOTES.md; `man plasm`):

- **It compiles only small programs.** The compiler, its tables and the
  output share one 46 KB process bank; the code-and-data buffer it prints
  (`Data+Code buffer size`) is about 480 bytes. `hello.pla` (23 bytes) and
  `sieve.pla` compile and run; PLASMA's `test.pla` and `rpncalc.pla` stop
  with `overflowed code table`. Trigger to revisit: a lesson or user needs a
  larger program. The one reservoir left is the frame-stack gap
  ($13AC-$1FFF, about 3.1 KB), which needs plasm's frame depth measured
  first; price and plan: PLASM-FIX-NOTES sec 10.
- **plasm exits 0 after a compile error** (Dave's `done`; rt passes a
  nonzero status through). A makefile must not trust it: `rm -f X.mod`
  before and `ls X.mod` after (maux's make runs recipe lines with no shell,
  and the release disk has no `/bin/test`; `ls` fails, stopping make, when
  the module is missing).
- **A source or output name over 31 characters corrupts plasm's own name
  buffers** (`byte[32] srcfile, incfile, relfile, modfile`, upstream).
  Keep names short.
- **The command line is limited to 127 characters** for every PLASMA
  program (`rt: command line too long`, exit 2); the shell's own typed
  line is capped at 127 as well.
- **A PLASMA module chain may export about 40 symbols beyond CMDSYS's own**
  (`rt: symbol table full`, exit 2): the loader's table is 1,280 bytes.
- **The plasma cutter is host-side only, so a program compiled ON maux
  cannot be cooked there.** `plascut` (docs/PLASCUT.md) is
  `scripts/plascut.py`, a host script, and there is no `/bin/plascut`:
  it binds a program's module closure into one spawnable binary at BUILD
  time. `/bin/nas` and `/bin/plasm` are its output and are cooked, which
  is where the measured ~21% per invocation goes. A module you compile on
  the target runs the modular way instead -- `plasma MYPROG`, with rt
  reading, relocating and binding each module on every launch. Trigger to
  revisit: someone developing PLASMA on the target rather than
  cross-compiling for it, or a lesson that wants a cooked program built
  on the disk.
