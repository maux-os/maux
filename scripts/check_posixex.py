#!/usr/bin/env python3
"""check_posixex.py -- POSIX ex (XCU `ex`) conformance suite for maux's ex
(src/bin/ex.s + edparse.s/excmd.s/edsubst.s/edsub2.s/exbuf.s).

The ex analogue of scripts/check_posixvi.py: a table-driven CONFORMANCE
REPORT, not a pass/fail build gate (deliberately NOT in CHECK_ALL_TARGETS,
same posture as check-posixvi). Every CASES row feeds maux's `ex` a
command SCRIPT plus an input file, non-interactively, and checks BOTH the
captured stdout and the resulting file BYTE-EXACT against a real host `ex`
oracle (`/usr/bin/ex -s`). ORACLE PROVENANCE (2026-09-06, review): on this
host `/usr/bin/ex` is a symlink to VIM (vim's ex mode), NOT nvi -- so these
are byte-exact-vs-vim's-ex results on a bounded case set, not a POSIX
certificate and not two independent editors. This suite compares stdout +
files only, NOT the child exit status (the hand-assembled check-ex sessions
do that).

METHOD -- how this differs from check_posixvi.py's mechanism, and why:

  check_ex.py (the existing `make check-ex` gate) drives maux's ex through
  a hand-assembled test harness (src/test/extest*.s) with every script and
  expected value BAKED INTO THE KERNEL IMAGE -- not a generic driver this
  suite could reuse directly without writing new assembly, which the task
  brief forbids. What check_ex.py's header DOES establish, and what this
  suite actually reuses, is the SHAPE: ex is fed a command script and an
  input file, and its stdout/the written file are read back byte-exact
  through the swap-file path. This suite gets the same shape for free,
  generically, by going through maux's own shell (`sh`) and its `<`/`>`
  redirection (already proven generic infrastructure -- see
  scripts/build_v1_system_image.py's `ED < /mnt/MAUX/EDSCRIPT > /mnt/MAUX/EDLOG`
  precedent for `ed`, the sibling editor `ex` was forked from): every case
  is ONE line typed at a booted shell prompt,

      EX /mnt/MAUX/PXEX/<tag> < /mnt/MAUX/PXEX/<tag>S > /mnt/MAUX/PXEX/<tag>O

  where <tag> (the file ex loads, and -- via a bare `w`/`wq`/`x` -- writes
  back to) and <tag>S (the ex command script) are pre-staged on a COPY of
  build/play.po with a2til BEFORE the emulator ever boots it (build_play_
  image.py already ships `ex` at the image's root, since it is in the
  Makefile's UTILS list), and <tag>O captures stdout. Every test file goes
  in a FRESH subdirectory (/mnt/MAUX/PXEX/), never the volume root: ProDOS
  will not grow the root directory past its format-time entry count (see
  build_v1_system_image.py's own comment on this), but a SUBDIRECTORY
  grows on demand -- so, unlike check_posixvi.py (capped at 3 written
  files per boot by the play image's root), this suite can batch many
  cases into ONE boot.

  ORACLE: `/usr/bin/ex -s <mainfile>` fed the SAME script (rendered with
  host-local relative filenames instead of maux ProDOS paths where a
  case references a second file) over stdin. Verified STABLE (run twice,
  scripts/check_posixex.py's own `oracle()` always executes the case
  twice and flags any diff as `oracle unstable` rather than silently
  trusting the first run).

  UNDO HAZARD (see check_posixvi.py's docstring for the vim `normal!`
  finding this suite had to re-derive independently for ex): a BATCHED
  vim macro (`exe "normal! ...multiple edits..."`) merges several edits
  into one undo step, which would get single-level undo WRONG. That
  hazard does NOT apply here: ex's own stdin protocol is already
  "one command per line", the exact granularity real interactive ex/vi
  creates an undo boundary at, so feeding `1s/aa/XX/`, `2s/bb/YY/`, `u`
  as three separate lines to `/usr/bin/ex -s` undoes only the SECOND
  edit, byte-verified against this suite's own probing (2026-09-05) --
  no special-cased "interactive" oracle needed for `u` here, unlike
  check_posixvi.py's vi suite.

  SILENT-REFUSAL FINDING (found while building this suite -- and it
  CORRECTED an earlier, wrong theory of mine that real ex hard-aborts a
  batch script on its first error; it does not, confirmed by re-testing
  with a diagnostic `p` command placed AFTER the erroring line and
  watching it still print): `/usr/bin/ex -s`, run non-interactively,
  keeps reading and executing commands after an out-of-range address
  (`999p`), an `e` refused for a dirty buffer, or `n` (reserved/only one
  file) -- exactly like maux's own MAINLOOP, which never aborts either.
  The two engines end up at the SAME final buffer state in every case
  like this (verified: a trailing `wq` after the error writes identical
  content on both sides). The ACTUAL, narrower divergence is on stdout
  only: maux always echoes a `?` for the refused/erroring command
  (classic interactive ed/ex posture, kept even when stdin is a
  redirected script); real ex's non-interactive mode emits NOTHING to
  stdout or stderr for the same refusal -- it only shows up in the
  process's own nonzero exit status, which this suite's stdout/file
  comparison does not otherwise check. Flagged per-case below.

  BARE `,`/`;` FINDING (found while building this suite, 2026-09-05):
  edparse.s's ED_PARSEADDR comment calls a bare `,` (both sides omitted)
  "the classic `1,$` whole-buffer shorthand" and a bare `;` the classic
  `.,$`. Verified against BOTH `/usr/bin/ex -s` and `vim -es -u NONE`:
  neither implements this. A bare `,` or `;` with both sides omitted is
  just "current line, current line" in real ex (POSIX: an omitted
  address in a two-address command defaults to `.`) -- i.e. `,p`/`;p`
  print ONLY the current line, not the whole buffer. maux's own
  check-ex gate (session (a)) happens not to be discriminating here
  (its fixture's `.`=$ after `r`, so "1,$" and ".,." both start at the
  same line in that ONE case's shape by coincidence for the FIRST print
  only) -- this suite's own bare-`,`/`;` cases below use a fixture where
  the two readings disagree, and both FAIL, documenting a genuine
  divergence from POSIX, not a suite artifact.

  `=` UNRELIABLE ON BOTH ORACLES: `/usr/bin/ex -s` prints the digits
  with NO trailing newline in batch mode (confirmed: a `2=` immediately
  followed by a `p` runs the two outputs together with zero bytes
  between them) -- POSIX's own text requires a trailing <newline>, so
  this is the host ex (vim's ex mode; see the provenance note above) being
  non-conformant, not a suite bug. `vim -es`
  is worse: it emits NOTHING for `=` in batch mode at all (writes to
  vim's message area, which isn't part of the piped stdout stream when
  not a tty). Neither oracle is trustworthy here, so `=` gets a
  STRUCTURAL case (special_eq(), mirroring check_posixvi.py's
  special_qbang() pattern) that computes the expected line number in
  Python instead of trusting either oracle's stdout bytes.

  NUMBERED-PRINT FORMAT DIVERGENCE: real ex's `#`/`nu` right-justifies
  the line number in a field then a SPACE (`      1 M4\n`); maux's own
  convention (established by its own check-ex gate) is a bare number,
  a TAB, then the text (`1<TAB>M4\r`). Both carry the same information;
  the exact bytes differ. Reported as an expected FAIL, not hidden.

  Every case ends with an explicit `wq`/`x`/`q!`/`q` (never relies on
  EOF-implicit-quit) so the final file state is always well-defined on
  both sides.
"""
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_vi as V                                    # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR    # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import a2til                                             # noqa: E402
from a2til import prodos                                 # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'play.po')
SUBDIR = '/mnt/MAUX/PXEX'
EX_ORACLE = '/usr/bin/ex'
# Under build/posix/, where every other suite keeps its logs -- a path the
# box has. The old default named one session's private scratch directory,
# which exists on one Mac only; on the box both report suites died with
# PermissionError before scoring (found 2026-09-17).
SCRATCH = os.environ.get(
    'POSIXEX_SCRATCH', os.path.join(ROOT, 'build', 'posix', 'posixex'))


# ======================================================================
# text/encoding helpers
# ======================================================================
def hi(s):
    return bytes(ord(c) | 0x80 for c in s)


def hilines(lines):
    """A liba text file: high-bit ASCII, CR ($8D) per line, incl. the
    last -- maux's own convention (check_ex.py's hilines/build_v1_system's
    script_bytes)."""
    return b''.join(hi(ln) + bytes([0x8D]) for ln in lines)


def maux_lines(raw):
    """Decode a liba text file/stdout capture read back with a2til into a
    list of lines (bit 7 stripped, split on CR, trailing empty dropped)."""
    got = bytes(b & 0x7F for b in raw).decode('ascii', errors='replace')
    lines = got.split('\r')
    if lines and lines[-1] == '':
        lines = lines[:-1]
    return lines


def oracle_text_lines(text):
    lines = text.split('\n')
    if lines and lines[-1] == '':
        lines = lines[:-1]
    return lines


def render(lines, mapping):
    out = []
    for ln in lines:
        for k, v in mapping.items():
            ln = ln.replace(f'@{k}@', v)
        out.append(ln)
    return out


# ======================================================================
# case table
# ======================================================================
# Each case: group, name, input (MAIN file lines), extra ({tag: lines}
# for secondary files a `r`/`e`/`e!`/`w` command in the script touches),
# script (ex command lines; may reference @TAG@ placeholders resolved
# per-side by render()), results (list of tags to byte-exact-compare
# as FILES after the session -- 'MAIN' plus any @TAG@ used), note.
CASES = [
    # ---- text entry (a/i/c) -----------------------------------------
    ('entry', 'a appends after the addressed line', ['L1', 'L2'],
     {}, ['1a', 'NEW', '.', 'wq'], ['MAIN'], ''),
    ('entry', 'i inserts before the addressed line', ['L1', 'L2'],
     {}, ['2i', 'NEW', '.', 'wq'], ['MAIN'], ''),
    ('entry', 'c changes (replaces) the addressed line', ['OLD1', 'OLD2'],
     {}, ['1c', 'NEW1', '.', 'wq'], ['MAIN'], ''),

    # ---- delete -------------------------------------------------------
    ('delete', 'd deletes the addressed line', ['L1', 'L2', 'L3'],
     {}, ['2d', 'wq'], ['MAIN'], ''),
    ('delete', 'd over an explicit 2,4 range', ['L1', 'L2', 'L3', 'L4', 'L5'],
     {}, ['2,4d', 'wq'], ['MAIN'], 'explicit comma-range addressing'),

    # ---- substitute -----------------------------------------------------
    ('substitute', 's basic', ['OLD text'],
     {}, ['1s/OLD/NEW/', 'wq'], ['MAIN'], ''),
    ('substitute', 's with /g substitutes every match', ['aa aa aa'],
     {}, ['1s/aa/bb/g', 'wq'], ['MAIN'], ''),
    ('substitute', 's with /p prints the result line', ['OLD text'],
     {}, ['1s/OLD/NEW/p', 'wq'], ['MAIN'], 'checks stdout, not just file'),
    ('substitute', 's/re/repl/N means "N LINES", not "the Nth match "'
     'in a line"',
     ['aa 1', 'aa 2', 'aa 3', 'aa 4'], {},
     ['1s/aa/Z/3', 'wq'], ['MAIN'],
     'POSIX ex\'s trailing numeric flag on `s` is a COUNT OF LINES, '
     'starting at the LAST addressed line, over which the (non-g, '
     'first-match-only) substitution runs: `1s/aa/Z/3` on 4 lines '
     'gives Z1/Z2/Z3/aa4. Implemented 2026-09-05 (edsubst.s '
     'ED_S_APPLY sets the range from ED_SNUM via ED_ENDFROMCNT; the '
     'ED_SNUM_LINES build flag is 1 for ex/vi). NOTE the ed/ex split: '
     'POSIX ED keeps the number as "the Nth OCCURRENCE within the '
     'addressed line" (ED_SNUM_LINES=0 in ed.s) -- check-ed exercises '
     'that reading, so the two must not share one behavior'),
    ('substitute', 's//repl/ reuses the last search pattern',
     ['foo bar', 'foo baz'], {},
     ['1s/foo/X/', '2s//Y/', 'wq'], ['MAIN'],
     'an empty search field in s reuses the prior s\'s own pattern'),
    ('substitute', '& repeats the last substitution', ['aa aa', 'bb bb'],
     {}, ['1s/aa/XX/', '2s/bb/YY/', '&', 'wq'], ['MAIN'],
     'POSIX ex `&` repeats the last substitution on the current line, '
     'reusing the last RE + replacement + flags; implemented 2026-09-05 '
     '(ED_CMD_AMP -> ED_S_APPLY)'),

    # ---- global (g/v) ---------------------------------------------------
    ('global', 'g/re/p prints every matching line',
     ['BANK one', 'plain two', 'BANK three'], {},
     ['g/BANK/p', 'wq'], ['MAIN'], ''),
    ('global', 'g/re/s//X/ -- widened g/v running a sub on every match',
     ['BANK one', 'plain two', 'BANK three'], {},
     ['g/BANK/s/BANK/GONE/', 'wq'], ['MAIN'],
     'explicitly requested combination'),
    ('global', 'v/re/p prints every NON-matching line',
     ['BANK one', 'plain two', 'BANK three'], {},
     ['v/BANK/p', 'wq'], ['MAIN'], ''),

    # ---- move / copy / join --------------------------------------------
    ('move', 'm moves a line after the destination address',
     ['L1', 'L2', 'L3', 'L4'], {}, ['1m3', 'wq'], ['MAIN'], ''),
    ('copy', 't copies a line after the destination address',
     ['L1', 'L2', 'L3'], {}, ['1t3', 'wq'], ['MAIN'], ''),
    ('gap', 'j joins two lines WITH a separating space', ['AAA', 'BBB'],
     {}, ['1,2j', 'wq'], ['MAIN'],
     'POSIX ex\'s `j` inserts a single space between the joined lines '
     '(unless one side already ends/begins with whitespace, or the '
     'second line starts with `)`) -- confirmed against real ex: '
     '`1,2j` on AAA/BBB gives "AAA BBB". edsub2.s\'s ED_CMD_J has an '
     'explicit, DELIBERATE fork on this (its own comment: "vi\'s `J` '
     'joins with a SEPARATING SPACE ... ed\'s `j` joins with NOTHING '
     '... ed and standalone ex stay separator-free") -- so maux\'s `ex` '
     '(sharing ed\'s `j`, not vi\'s `J`) gives "AAABBB" -- expected to '
     'FAIL'),
    ('gap', '.,$j joins current line through EOF, same space gap',
     ['L1', 'L2', 'L3', 'L4'], {}, ['2', '.,$j', 'wq'], ['MAIN'],
     'explicitly requested combination; same space-insertion gap as '
     'the plain `j` row above -- expected to FAIL ("L2L3L4" vs POSIX\'s '
     '"L2 L3 L4")'),

    # ---- print family (p / n-number / = / l) ----------------------------
    ('print', 'p prints the addressed line', ['ONLY'],
     {}, ['1p', 'wq'], ['MAIN'], ''),
    ('print', '# numbered-print', ['M4', 'M5'],
     {}, ['1,2#', 'wq'], ['MAIN'],
     'ex `#`: the line number right-justified in a 7-wide field then '
     'a space ("      1 M4"). Implemented 2026-09-06 (ED_NUM_RJUST '
     'build flag: 1 for ex/vi; ed`s own `n` keeps number+TAB, '
     'ED_NUM_RJUST=0, which check-ed covers)'),
    ('print', 'nu is a numbered-print alias', ['M4', 'M5'],
     {}, ['1,2nu', 'wq'], ['MAIN'],
     'same right-justified format as # (ED_NUM_RJUST); `nu` is `#`'),
    ('file', 'n is RESERVED in ex, and refused SILENTLY in script mode',
     ['A', 'B'], {}, ['1s/A/Z/', 'n', 'wq'], ['MAIN'],
     '`n` means `next` (file), not numbered-print (Ex Reference Manual '
     'v1.1). Real ex refuses a bare `n` with one file loaded, but '
     'silently in `-s`, then keeps going (wq still fires). maux now '
     'matches: ex is silent on a refused command when stdin is not a '
     'tty (ED_ERR_QUIET + fdstat(0) isatty check, 2026-09-06) -- no `?` '
     'on stdout, buffer written the same. Interactive ex still shows '
     '`?`; ed always does'),
    ('print', 'l lists a line with a trailing $ (nonprinting marker)',
     ['abc'], {}, ['1l', 'wq'], ['MAIN'],
     'POSIX ex `l` (list): print the range with a literal `$` at end '
     'of line and control bytes in caret notation (^I etc.). '
     'Implemented 2026-09-05 (excmd.s EX_CLIST/EX_LISTLN, ex-only via '
     'EX_CMD so ed is untouched)'),
    ('print', 'z opens a window at the addressed line',
     ['A', 'B', 'C', 'D', 'E'], {}, ['1z3', 'wq'], ['MAIN'],
     'POSIX ex `z` (window): `1z3` prints 3 lines from line 1. '
     'Implemented 2026-09-05 (excmd.s EX_CWIN; the plain [addr]z[count] '
     'form -- the +/-/./= type flags are still unimplemented)'),

    # ---- marks ------------------------------------------------------------
    ('mark', 'kX sets a mark, \'x addresses it (incl. shift-on-delete)',
     ['L1', 'L2', 'L3', 'L4'], {},
     ['3ka', '1,2d', "'ap", 'wq'], ['MAIN'],
     'mark a := line 3; deleting lines 1-2 shifts it to line 1, which '
     'is now L3 -- \'ap must print L3, proving the shift'),

    # ---- file commands (r / e / e! / w / q / q! / wq / x) ----------------
    ('file', 'r reads a file in without rebinding the remembered name',
     ['L1', 'L2'], {'AUX': ['R1', 'R2']},
     ['r @AUX@', 'wq'], ['MAIN', 'AUX'],
     '`r otherfile` inserts otherfile after the addressed line (default '
     '$) but leaves the REMEMBERED filename alone -- only `e`/the '
     'initial load set it (POSIX, verified against ed -s too). So the '
     'trailing bare `wq` writes the joined L1/L2/R1/R2 back to MAIN and '
     '@AUX@ is untouched. Fixed 2026-09-06 (edfil2.s ED_CMD_R no longer '
     'calls ED_RMBR_FNAME); both ed and ex change, since neither POSIX '
     'engine rebinds on `r`'),
    ('file', 'e on a dirty buffer without ! is refused',
     ['B1', 'B2', 'B3'], {'AUX': ['C1', 'C2']},
     ['1a', 'NEWB', '.', 'e @AUX@', 'wq'], ['MAIN'],
     'real ex refuses `e` on a dirty buffer (matches maux) and does '
     'NOT switch files, but keeps processing -- the trailing `wq` then '
     'writes the STILL-DIRTY original buffer back to MAIN on both '
     'sides, landing at the same content. The refusal is now SILENT in '
     'script mode on both (ED_ERR_QUIET, 2026-09-06), so stdout matches '
     'too'),
    ('file', 'e! forces a load, discarding a dirty buffer',
     ['B1', 'B2', 'B3'], {'AUX': ['C1', 'C2']},
     ['1a', 'NEWB', '.', 'e! @AUX@', '1s/C1/ZZZ/', 'wq'], ['AUX'],
     'the original MAIN file must stay untouched; @AUX@ picks up the '
     'edit made AFTER the forced reload'),
    ('file', 'w with no edits persists the buffer unchanged', ['HELLO'],
     {}, ['w', 'q'], ['MAIN'], ''),
    ('file', 'w to an explicit, NEW different path leaves the loaded '
     'file alone', ['X1', 'X2'], {'W': None},
     ['1s/X1/Y1/', 'w @W@', 'q'], ['MAIN', 'W'],
     'MAIN must stay X1/X2 (unwritten); @W@ (a path that does not '
     'exist yet) gets the edited content -- a bare `w path` does not '
     'repoint the remembered filename'),
    ('file', 'w refuses to overwrite an EXISTING different path without !',
     ['X1', 'X2'], {'W': ['OLD1', 'OLD2']},
     ['1s/X1/Y1/', 'w @W@', 'q'], ['MAIN', 'W'],
     'real ex refuses `w path` when path ALREADY EXISTS and differs '
     'from the current file (needs `w!`) -- @W@ stays OLD1/OLD2, silent '
     'refusal. Implemented 2026-09-06 (ED_WGUARD build flag, 1 for '
     'ex/vi): ED_CMD_W parses a leading `!` as force, and ED_DOWRITE '
     'GET_FILE_INFO-probes the target and refuses an existing one '
     'without the bang. ed always overwrites (ED_WGUARD=0; its `!` is '
     'reserved for a future write-to-command)'),
    ('file', 'q quits with no unsaved changes', ['A', 'B'],
     {}, ['q'], ['MAIN'], ''),
    ('file', 'q! force-quits, discarding an unsaved edit', ['A', 'B'],
     {}, ['1s/A/Z/', 'q!'], ['MAIN'], ''),
    ('file', 'wq writes then quits', ['A'],
     {}, ['1s/A/B/', 'wq'], ['MAIN'], ''),
    ('file', 'x writes (buffer dirty) then quits', ['A'],
     {}, ['1s/A/B/', 'x'], ['MAIN'], ''),
    ('file', 'x on a clean buffer still quits', ['A'],
     {}, ['x'], ['MAIN'], 'no edits made -- x must not corrupt anything'),

    # ---- undo ---------------------------------------------------------
    ('undo', 'u undoes only the most recent change (single-level)',
     ['aa', 'bb'], {}, ['1s/aa/XX/', '2s/bb/YY/', 'u', 'wq'], ['MAIN'],
     'ex\'s own one-command-per-stdin-line protocol gives real ex an '
     'undo boundary per command even in batch mode -- verified stable, '
     'no interactive-pty oracle needed here (see module docstring)'),

    # ---- addressing -----------------------------------------------------
    ('address', 'absolute line number', ['L1', 'L2', 'L3'],
     {}, ['2p', 'wq'], ['MAIN'], ''),
    ('address', '. addresses the current line', ['L1', 'L2', 'L3'],
     {}, ['2', '.p', 'wq'], ['MAIN'], ''),
    ('address', '$ addresses the last line', ['L1', 'L2', 'L3'],
     {}, ['$p', 'wq'], ['MAIN'], ''),
    ('address', '% addresses the whole buffer (1,$)', ['a1', 'a2'],
     {}, ['%s/a/b/g', 'wq'], ['MAIN'], 'explicitly requested combination'),
    ('address', '/re/ searches forward', ['foo', 'bar', 'foo'],
     {}, ['1', '/bar/p', 'wq'], ['MAIN'], ''),
    ('address', '?re? searches backward', ['foo', 'bar', 'baz'],
     {}, ['$', '?bar?p', 'wq'], ['MAIN'], ''),
    ('address', '.+N relative address', ['L1', 'L2', 'L3', 'L4'],
     {}, ['2', '.+1p', 'wq'], ['MAIN'],
     'edparse.s\'s ED_PARSE1ADDR recognizes only `.` `$` a digit `/` `\'` '
     '`?` -- no `+`/`-` offset handling anywhere in the file (grep '
     'confirms) -- expected to FAIL'),
    ('address', '.-N relative address', ['L1', 'L2', 'L3', 'L4'],
     {}, ['3', '.-1p', 'wq'], ['MAIN'], 'same gap as .+N -- expected to FAIL'),
    ('address', 'an explicit , range (2,4d)', ['L1', 'L2', 'L3', 'L4', 'L5'],
     {}, ['2,4d', 'wq'], ['MAIN'],
     'same case as the delete group\'s own 2,4d row -- kept here too '
     'since the task asks for one addressing-form case per form'),
    ('address', 'bare , (both sides omitted) is `.,.` in ex, not `1,$`',
     ['line one', 'BANK middle', 'line three'], {},
     [',p', 'wq'], ['MAIN'],
     'POSIX: an omitted address on either side of `,` defaults to `.`, '
     'so a bare `,p` prints only "line three" (dot after load = last '
     'line), NOT the whole buffer. Implemented 2026-09-06 (ED_BARE_CUR '
     'build flag: 1 for ex/vi). ed keeps the `,` = `1,$` shorthand '
     '(ED_BARE_CUR=0; check-ed covers it), and `%` is still `1,$` on '
     'both engines'),
    ('address', 'a non-bare ; range separator',
     ['L1', 'L2', 'L3', 'L4'], {}, ['1;3p', 'wq'], ['MAIN'],
     'real ex treats `addr1;addr2` as a range separator like `,`, but '
     'sets `.` to addr1 before evaluating addr2 (so a relative addr2 '
     'like `.+2` is measured from addr1); `1;3p` prints L1..L3. '
     'Implemented 2026-09-05 (edparse.s ED_PARSEADDR: `;` alongside '
     '`,` after the first address, setting ED_CURLINE=ADDR1 first)'),
    ('address', 'bare ; (both sides omitted) is `.,.` in ex, not `.,$`',
     ['W1', 'W2', 'W3', 'W4'], {}, ['2', ';p', 'wq'], ['MAIN'],
     'after `2` moves dot to line 2, a bare `;` also defaults both '
     'sides to `.` (same POSIX rule as bare `,`), so `;p` prints only '
     '"W2" again. Implemented 2026-09-06 (ED_BARE_CUR; ed keeps `;` = '
     '`.,$`)'),
    ('address', "'x addresses a mark", ['L1', 'L2', 'L3', 'L4'],
     {}, ['3ka', '1,2d', "'ap", 'wq'], ['MAIN'],
     'same case as the mark group\'s own row -- kept here too since the '
     'task asks for one addressing-form case per form'),
    ('address', 'default addressing: a bare command uses the current line',
     ['A', 'B', 'C'], {}, ['2', 'd', 'wq'], ['MAIN'],
     'bare `2` moves dot to B (and prints it, classic ed convention); '
     'bare `d` with no address then deletes the CURRENT line'),
    ('address', 'an out-of-range address is a silent refusal',
     ['A', 'B'], {}, ['1s/A/Z/', '999p', 'wq'], ['MAIN'],
     'the first `s` succeeds on both; `999p` is out of range on a '
     '2-line buffer -- real ex refuses it with NO stdout output (just a '
     'nonzero exit) and keeps going, so `wq` still writes Z/B. maux now '
     'matches: ex is silent on a refused command in script mode '
     '(ED_ERR_QUIET, 2026-09-06)'),
]

# ---- command NAMES (docs/EX-BADCMD.md, 2026-10-08) -------------------
# ex dispatched a command WORD by its FIRST LETTER: `cxyz` ran CHANGE,
# `dxyz` deleted a line, `wxyz` wrote the file, `qxyz` quit. POSIX ex
# reads the NAME and refuses one that is not a command or an
# abbreviation of one. Every row below was measured on BOTH hosts
# (this Mac: vim 9.1; the box: vim.tiny 9.0 -- two vims, one
# lineage, NOT two independent editors) before it was written, and the
# two agreed byte for byte. Refusals are silent on stdout in script
# mode on both sides, and a refused line does NOT abort the script, so
# each negative row keeps going into a visible `1d`/`wq` that proves
# the refused word changed nothing and the session survived.
#
# Host behaviour maux does NOT copy, so no row asserts it (each is a
# refusal in maux, where the host honours an operand maux's handlers
# never had): a count (`2d3`), a register (`2d x`), print flags
# (`2p#`), `j!`, `s` flags past `g`.
_L3 = ['L1', 'L2', 'L3']
_NM_NOTE = ('docs/EX-BADCMD.md: the word is resolved against the POSIX '
            'name table (src/bin/exname.s), not by its first letter')
# SH-DEFECTS 14: maux is launched `EX -s FILE` for these (the oracle is
# always `ex -s`). -s suppresses prompts/informational messages, NOT the
# output of an explicit print command; ex has no autoprint after s.
CASES += [
    ('silent', '-s: 1,2p prints both lines', ['l1', 'l2'], {},
     ['1,2p', 'q!'], ['MAIN'],
     'Base: `-s` was opened as the FILE, buffer empty, p printed nothing'),
    ('silent', '-s: s without p does not echo the line', ['aa'], {},
     ['1s/aa/bb/', 'wq'], ['MAIN'], 'no autoprint; file still edited'),
    ('silent', '-s: s///p still prints', ['aa'], {},
     ['1s/aa/bb/p', 'wq'], ['MAIN'], 'explicit p flag is output'),
    ('silent', '-s: nu prints numbered lines', ['l1', 'l2'], {},
     ['1,2nu', 'q!'], ['MAIN'], ''),
]

CASES += [
    ('badcmd', 'cxyz is refused, not run as change', _L3, {},
     ['cxyz', '1d', 'wq'], ['MAIN'],
     _NM_NOTE + '. Base: `c` ran and swallowed `1d` and `wq` as text, '
     'so nothing was written -- the host deleted line 1'),
    ('badcmd', 'dxyz is refused, not run as delete', _L3, {},
     ['2dxyz', 'wq'], ['MAIN'], _NM_NOTE + '. Base deleted line 2'),
    ('badcmd', 'axyz is refused, not run as append', _L3, {},
     ['1axyz', '1d', 'wq'], ['MAIN'], _NM_NOTE),
    ('badcmd', 'ixyz is refused, not run as insert', _L3, {},
     ['1ixyz', '1d', 'wq'], ['MAIN'], _NM_NOTE),
    ('badcmd', 'pxyz is refused, not run as print', _L3, {},
     ['pxyz', 'wq'], ['MAIN'], _NM_NOTE + '. Base printed line 3'),
    ('badcmd', 'wxyz is refused, not run as write', _L3, {},
     ['1d', 'wxyz', 'q'], ['MAIN'],
     _NM_NOTE + '. Base wrote the file (a bare `w` with the loaded '
     'name remembered), so line 1 was gone from disk; the host quits '
     'with the edit unwritten'),
    ('badcmd', 'qxyz is refused, not run as quit', _L3, {},
     ['qxyz', '1d', 'wq'], ['MAIN'],
     _NM_NOTE + '. Base quit at once; the session carries on here'),
    ('badcmd', 'sxyz is refused, not run as substitute', _L3, {},
     ['1sxyz', 'wq'], ['MAIN'], _NM_NOTE),
    ('badcmd', 'jxyz is refused, not run as join', _L3, {},
     ['1jxyz', 'wq'], ['MAIN'], _NM_NOTE),
    ('badcmd', 'uxyz is refused, not run as undo', _L3, {},
     ['1d', 'uxyz', 'wq'], ['MAIN'], _NM_NOTE),
    ('badcmd', 'nux is refused (nu is the shortest-spelling of number)',
     _L3, {}, ['2nux', 'wq'], ['MAIN'],
     _NM_NOTE + '. Base printed the numbered line'),
    ('badcmd', '= takes no operand', _L3, {}, ['2=x', 'wq'], ['MAIN'],
     'trailing characters after `=` are refused. Base printed 2'),
    ('badcmd', 'p refuses an operand maux has no handler for', _L3, {},
     ['2p x', 'wq'], ['MAIN'],
     'trailing characters after `p` are refused. Base printed line 2'),
    ('badcmd', 'z takes only a count', _L3, {}, ['1zx', 'wq'], ['MAIN'],
     'trailing characters after `z` are refused. Base printed a window'),
    ('badcmd', 'an unknown word with no verb letter is refused', _L3, {},
     ['xyz', '1d', 'wq'], ['MAIN'], 'pin: green before and after'),
]


def _nm(name, script, main=None, extra=None, note=''):
    CASES.append(('names', name, main or _L3, extra or {}, script,
                  ['MAIN'] + sorted(extra or {}), note or _NM_NOTE))


_nm('append / ap', ['2ap', 'NEW', '.', 'wq'])
_nm('insert / in', ['2in', 'NEW', '.', 'wq'])
_nm('change / ch / cha', ['3change', 'NEW', '.', '1ch', 'AA', '.', 'wq'])
_nm('delete / de / dele', ['2de', '1dele', 'wq'])
_nm('print / pr', ['2print', '3pr', 'wq'])
_nm('list / li', ['2li', 'wq'])
_nm('number / nu', ['2number', '3nu', 'wq'])
_nm('copy / co / t, with and without a blank',
    ['1co3', '1t 3', '2copy 1', 'wq'])
_nm('move / mo', ['1mo 3', 'wq'])
_nm('join / jo', ['1,2jo', 'wq'], note=_NM_NOTE + '. The two-address '
    'form: maux\'s one-address `1j` is a no-op (edsub2.s, ed\'s rule) '
    'where POSIX ex joins with the next line -- a separate gap')
_nm('undo / un / und', ['1d', 'und', 'wq'])
_nm('substitute / su / sub', ['1su/L/X/', '2sub/L/Y/', 'wq'])
_nm('write / wr', ['1s/L/X/', 'write', 'q'])
_nm('xit / xi / x!', ['1s/L/X/', 'xi'])
_nm('x! writes like x', ['1s/L/X/', 'x!'])
_nm('wq! writes like wq', ['1s/L/X/', 'wq!'])
_nm('global / gl', ['global/L2/d', 'wq'])
_nm('vglobal / vg', ['vg/L2/d', 'wq'])
_nm('mark / ma / k, a blank before the letter or none',
    ['2ma a', '1d', "'ad", 'wq'])
_nm('mark with the full word', ['2mark a', '1d', "'ad", 'wq'])
_nm('k with a blank before its letter', ['2k a', '1d', "'ad", 'wq'])
_nm('read / re', ['1re @AUX@', 'wq'], extra={'AUX': ['R1']})
_nm('quit / qu on a clean buffer', ['qu'])
_nm('a blank between the address and the command word', ['2 d', 'wq'])


# ======================================================================
# host oracle -- real ex (`/usr/bin/ex -s`)
# ======================================================================
def _run_oracle_once(case):
    group, name, main_lines, extra, script, results, note = case
    workdir = tempfile.mkdtemp(dir=SCRATCH)
    try:
        oracle_map = {tag: tag.lower() + '.txt' for tag in extra}
        main_path = os.path.join(workdir, 'main.txt')
        with open(main_path, 'w') as f:
            f.write('\n'.join(main_lines) + ('\n' if main_lines else ''))
        for tag, lines in extra.items():
            if lines is None:
                continue  # write-only target -- must not pre-exist
            with open(os.path.join(workdir, oracle_map[tag]), 'w') as f:
                f.write('\n'.join(lines) + ('\n' if lines else ''))

        oscript = render(script, oracle_map)
        script_text = '\n'.join(oscript) + '\n'
        r = subprocess.run([EX_ORACLE, '-s', 'main.txt'], cwd=workdir,
                            input=script_text, capture_output=True,
                            text=True, timeout=15)
        stdout_lines = oracle_text_lines(r.stdout)

        files = {}
        for tag in results:
            if tag == 'MAIN':
                path = main_path
            else:
                path = os.path.join(workdir, oracle_map[tag])
            if os.path.exists(path):
                with open(path) as f:
                    files[tag] = oracle_text_lines(f.read())
            else:
                files[tag] = None
        return {'stdout': stdout_lines, 'files': files, 'rc': r.returncode}
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def oracle(case):
    """Run the oracle TWICE (task requirement: verify stability) and
    raise if the two runs disagree -- an unstable oracle is a harness
    finding, not something to silently paper over."""
    a = _run_oracle_once(case)
    b = _run_oracle_once(case)
    if a != b:
        raise RuntimeError(
            f'oracle UNSTABLE across two runs: {a!r} != {b!r}')
    return a


# ======================================================================
# maux side -- stage files, drive the shell, read back
# ======================================================================
def _maux_tag_map(tag, extra):
    """tag prefix ('K001') + placeholder name ('AUX'/'W') -> bare ProDOS
    filename ('K001AUX'). Kept short and unique per case+tag."""
    return {t: f'{tag}{t}' for t in extra}


def stage_batch(img, batch, tags):
    prodos.mount(img)
    try:
        try:
            prodos.mkdir(SUBDIR)
        except Exception:
            pass  # already exists (shouldn't, fresh copy per batch)
        for tag, case in zip(tags, batch):
            group, name, main_lines, extra, script, results, note = case
            maux_map = _maux_tag_map(tag, extra)
            prodos.write(f'{SUBDIR}/{tag}', hilines(main_lines),
                         file_type=0x04, aux_type=0x0000, overwrite=True)
            for t, lines in extra.items():
                if lines is None:
                    continue  # write-only target -- see module note on
                               # the 'w to a NEW path' vs 'w refuses an
                               # EXISTING path' pair of cases
                prodos.write(f'{SUBDIR}/{maux_map[t]}', hilines(lines),
                             file_type=0x04, aux_type=0x0000,
                             overwrite=True)
            mscript = render(script, {t: f'{SUBDIR}/{maux_map[t]}'
                                       for t in extra})
            prodos.write(f'{SUBDIR}/{tag}S', hilines(mscript),
                         file_type=0x04, aux_type=0x0000, overwrite=True)
    finally:
        try:
            prodos.unmount('MAUX')
        except Exception:
            pass


def boot_group(client, img):
    r = client.call_tool('reset', {'backend': 'fast', 'aux': 'ramworks'})
    if not r.get('ok'):
        raise RuntimeError(f'reset failed: {r}')
    r = client.call_tool('mount_disk', {'path': img, 'unit': 1})
    if r.get('ok') is False:
        raise RuntimeError(f'mount_disk failed: {r}')
    V.settle(client, V._at_prompt, 'shell prompt after boot',
             max_steps=3000)


#: The probe rigs (check-openro-k, check-openrw2-k, check-oappend,
#: check-iobuf) park their state byte at $7000 in the process's own
#: bank -- which is exactly sh's TRAPTAB base (src/bin/sh.s:1593).
#: Bank 1, the live shell, is safe by construction: SH_INIT_ZR zeroes
#: TRAPTAB on every spawn, so $7000 reads $00 there and no scan can
#: mistake it for a probe.
#:
#: A FREED bank is not safe. Nothing clears a bank on exit, so it
#: still holds the dead process's loaded segment copy, and the byte
#: at that offset moves with the low image. check-oappend went red on
#: a 47 B sh change for exactly this: bank 3's leftover turned from
#: $85 into $33, a valid child sync value, and find_probe() -- which
#: takes the FIRST matching bank -- polled a corpse while the real
#: parent sat in bank 4. The rig is part of the layout
#: (learning:01M2KR62JF41H87SYB6YKZFMQC, same fault class).
SCRUB_LO = 2
SCRUB_HI = 16


def scrub_probe_state(client, addr, lo=SCRUB_LO, hi=SCRUB_HI):
    """Zero `addr` in every freed aux bank, before a probe is typed.

    Afterwards a sync value in banks `lo`..`hi`-1 can only have been
    written by the live probe, which is what every find/wait scan in
    those rigs already assumes. Bank 1 is left alone on purpose (see
    above); zeroing it would clear the running shell's TRAPTAB.

    The teeth are a decoy, not a layout. "Red before the fix, green
    after" proves nothing the next time the image moves, so this
    plants bytes that look exactly like the collision and insists
    they are gone -- and it proves STEERING before it proves
    clearing, because the silent failure is poke's aux_bank quietly
    ceasing to select: then every poke and peek would hit one bank,
    a zero-check alone would pass, and the scrub would be a no-op
    that nothing noticed until a gate went red years later.

    TEETH MEASURED 2026-10-31, not merely designed: with this
    function's poke forced to `aux_bank=lo` (steering disabled,
    everything else identical) check-oappend exits 2 here rather
    than failing later, reporting `read back ([85], [51])`. The
    second value is the interesting one -- $33 is bank 3's real
    stale byte at this layout, read by an unsabotaged peek, i.e.
    the exact collision value that caused the original red is
    STILL THERE. This scrub is load-bearing today, not a guard
    against a historical accident.
    """
    def poke(a, v, bank):
        client.call_tool('poke', {'addr': a, 'bytes': [v],
                                  'bank': 'aux', 'aux_bank': bank})

    def peek(a, bank):
        return client.call_tool('peek', {'addr': a, 'count': 1,
                                         'bank': 'aux',
                                         'aux_bank': bank})['bytes']

    if hi - lo < 2:
        raise RuntimeError(f'scrub_probe_state: need two banks to '
                           f'prove steering, got {lo}..{hi - 1}')
    poke(addr, 0x33, lo)
    poke(addr, 0x55, lo + 1)
    got = (peek(addr, lo), peek(addr, lo + 1))
    if got != ([0x33], [0x55]):
        raise RuntimeError(
            f'scrub_probe_state: two banks were given different bytes '
            f'at ${addr:04X} and read back {got} instead of '
            f'([0x33], [0x55]) -- poke/peek are not steering by '
            f'aux_bank, so the scrub below would be a silent no-op '
            f'and every probe scan would be trusting a stale byte')
    for b in range(lo, hi):
        poke(addr, 0, b)
    for b in range(lo, hi):
        got = peek(addr, b)
        if got != [0]:
            raise RuntimeError(
                f'scrub_probe_state: bank {b} still reads ${got[0]:02X} '
                f'at ${addr:04X} after being zeroed')


def run_case_maux(client, tag, silent=False):
    opt = '-s ' if silent else ''
    line = f'EX {opt}{SUBDIR}/{tag} < {SUBDIR}/{tag}S > {SUBDIR}/{tag}O\r'
    V.t(client, line)
    V.settle(client, V._at_prompt, f'{tag} finished', max_steps=1500)


def recover_shell(client):
    """Best-effort: Ctrl-C a wedged child, else nothing more we can do
    (the caller abandons the rest of the batch)."""
    V.t(client, '\x03')
    V.settle(client, V._at_prompt, 'recovered to prompt', max_steps=400)


def process_batch(env, batch, idx):
    tags = [f'K{idx * 100 + i:03d}' for i in range(len(batch))]
    img = os.path.join(SCRATCH, f'grp_{idx}.po')
    shutil.copy(DISK, img)
    stage_batch(img, batch, tags)

    client = MCPClient([SUPERVISOR], env)
    harness_err = {}
    try:
        boot_group(client, img)
        for tag, case in zip(tags, batch):
            try:
                run_case_maux(client, tag, case[0] == 'silent')
            except Exception as e:  # noqa: BLE001
                harness_err[tag] = f'{type(e).__name__}: {e}'
                try:
                    recover_shell(client)
                except Exception:
                    # shell truly wedged -- abandon the rest of this
                    # batch's REMAINING cases (already-run ones still
                    # get read back below).
                    break
    finally:
        try:
            client.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        client.close()

    vol = None
    vol_err = None
    try:
        vol = a2til.open_image(img)
    except Exception as e:  # noqa: BLE001
        vol_err = f'{type(e).__name__}: {e}'

    results = []
    for tag, case in zip(tags, batch):
        group, name, main_lines, extra, script, want, note = case
        if tag in harness_err:
            results.append((case, None, None, harness_err[tag]))
            continue
        if vol is None:
            results.append((case, None, None,
                             f'a2til open_image failed: {vol_err}'))
            continue
        try:
            stdout_raw = bytes(vol.read_file(f'{SUBDIR}/{tag}O'))
            stdout_lines = maux_lines(stdout_raw)
            files = {}
            maux_map = _maux_tag_map(tag, extra)
            for t in want:
                path = f'{SUBDIR}/{tag}' if t == 'MAIN' \
                    else f'{SUBDIR}/{maux_map[t]}'
                files[t] = maux_lines(bytes(vol.read_file(path)))
            results.append((case, stdout_lines, files, None))
        except Exception as e:  # noqa: BLE001
            results.append((case, None, None,
                             f'a2til read-back failed: '
                             f'{type(e).__name__}: {e}'))
    return results


# ======================================================================
# `=` -- structural case (neither oracle's stdout bytes are trustworthy
# in batch mode -- see module docstring). Computes the expected line
# number in Python and drives ONE dedicated tiny boot.
# ======================================================================
def special_eq(env):
    case = ('print', 'placeholder', ['L1', 'L2', 'L3'], {},
            ['2=', 'wq'], ['MAIN'], '')
    tag = 'KEQ'
    img = os.path.join(SCRATCH, 'grp_eq.po')
    shutil.copy(DISK, img)
    stage_batch(img, [case], [tag])
    client = MCPClient([SUPERVISOR], env)
    try:
        boot_group(client, img)
        run_case_maux(client, tag)
    finally:
        try:
            client.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        client.close()
    vol = a2til.open_image(img)
    stdout_lines = maux_lines(bytes(vol.read_file(f'{SUBDIR}/{tag}O')))
    expected = ['2']
    passed = stdout_lines == expected
    return passed, stdout_lines, expected


# ======================================================================
# main
# ======================================================================
def main():
    global DISK
    if len(sys.argv) > 1:
        DISK = os.path.abspath(sys.argv[1])
    if not os.path.exists(DISK):
        print(f'error: {DISK} not found -- run make play-image first',
              file=sys.stderr)
        return 2
    os.makedirs(SCRATCH, exist_ok=True)
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR

    report = []
    BATCH = 10
    batches = [CASES[i:i + BATCH] for i in range(0, len(CASES), BATCH)]
    print(f'[check-posixex] {len(CASES)} byte-exact cases, '
          f'{len(batches)} boot groups')
    for idx, batch in enumerate(batches):
        print(f'[check-posixex] group {idx + 1}/{len(batches)} '
              f'({len(batch)} cases)')
        res = process_batch(env, batch, idx)
        for case, got_stdout, got_files, herr in res:
            group, name, main_lines, extra, script, want, note = case
            try:
                exp = oracle(case)
                oerr = None
            except Exception as e:  # noqa: BLE001
                exp = None
                oerr = f'{type(e).__name__}: {e}'
            report.append((group, name, script, note, exp, got_stdout,
                            got_files, herr, oerr))

    print('[check-posixex] special: = (structural -- see module '
          'docstring on why neither oracle is trustworthy for it)')
    try:
        ok, got, expected = special_eq(env)
        eq_err = None
    except Exception as e:  # noqa: BLE001
        ok, got, expected, eq_err = False, None, None, f'{type(e).__name__}: {e}'
    report.append((
        'print', '= prints the addressed line\'s number', ['2=', 'wq'],
        'STRUCTURAL, not byte-exact-vs-oracle: /usr/bin/ex -s emits the '
        'digits with NO trailing newline in batch mode (confirmed by '
        'running `2=` immediately followed by `p` and finding zero '
        'bytes between the two outputs), and vim -es emits nothing at '
        'all for `=` when stdout is not a tty. Expected value (["2"]) '
        'is computed in Python from the case\'s own address, not from '
        'either oracle.',
        expected, got, None, eq_err, None))

    print()
    by_group = {}
    for row in report:
        by_group.setdefault(row[0], []).append(row)
    fails = []
    total = len(report)
    for group in sorted(by_group):
        print(f'== {group} ({len(by_group[group])} cases) ==')
        for (g, name, script, note, exp, got_stdout, got_files, herr,
             oerr) in by_group[group]:
            mismatches = []
            if herr is not None:
                pass
            elif oerr is not None:
                pass
            elif got_files is None:
                # the `=` special row: exp/got_stdout are both plain
                # lists (Python-computed expectation), no per-file dict.
                if got_stdout != exp:
                    mismatches.append(
                        f'stdout: expected {exp!r} got {got_stdout!r}')
            else:
                exp_stdout = exp['stdout']
                if got_stdout != exp_stdout:
                    mismatches.append(
                        f'stdout: expected {exp_stdout!r} got '
                        f'{got_stdout!r}')
                for tag in sorted(got_files):
                    e = exp['files'].get(tag)
                    a = got_files.get(tag)
                    if e != a:
                        mismatches.append(
                            f'file[{tag}]: expected {e!r} got {a!r}')
            passed = herr is None and oerr is None and not mismatches
            status = 'PASS' if passed else 'FAIL'
            if not passed:
                fails.append((g, name, script, note, mismatches, herr,
                              oerr))
            print(f'  {status} {name}')
            if not passed:
                if oerr:
                    print(f'       oracle error: {oerr}')
                if herr:
                    print(f'       harness error: {herr}')
                for m in mismatches:
                    print(f'       {m}')
                if note:
                    print(f'       note: {note}')
    print()
    print(f'[check-posixex] {total - len(fails)}/{total} cases passed, '
          f'{len(fails)} FAILED')
    if fails:
        print(f'[check-posixex] FAIL ({len(fails)}/{total} cases):',
              file=sys.stderr)
        for (g, name, script, note, mismatches, herr, oerr) in fails:
            print(f'  {g}: {name}', file=sys.stderr)
            for m in mismatches:
                print(f'    {m}', file=sys.stderr)
            if herr:
                print(f'    harness error: {herr}', file=sys.stderr)
            if oerr:
                print(f'    oracle error: {oerr}', file=sys.stderr)
        return 1
    print(f'[check-posixex] PASS -- {total} POSIX ex conformance '
          f'cases green')
    return 0


if __name__ == '__main__':
    sys.exit(main())
