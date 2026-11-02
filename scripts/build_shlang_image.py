#!/usr/bin/env python3
"""Build the ProDOS-hosted `sh` LANGUAGE (Tier 0 + `test`/`[`) acceptance-
gate image (`make check-shlang`).

Companion to src/test/shlangtest.s / shlangtestb.s / scripts/check_shlang.py.
Same shape as scripts/build_sh_image.py: stage input files + a script + the
userland binaries onto a carrier volume copy, boot a hardwired parent
process that spawns `sh` (stdin redirected from the script), and let `sh`
itself write every observable result to /mnt/MAUX/RESULTS via explicit `>>`
appends -- checked byte-exact, host-side, off the built image (same
mechanism build_sh_image.py's own EDITED/CATOUT use).

Every expected byte string is THE CONTRACT (docs/SH-SUBSET.md sec 3/6), not
anything derived by running the code -- scripts/check_shlang.py imports
EXPECT_RESULTS and never hand-computes an expectation of its own.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CARRIER_IMG = os.environ.get('PRODOS_CARRIER_IMG',
                             os.path.join(ROOT, 'vendor', 'prodos-basic.po'))
CARRIER_VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')
KERNEL_BIN = os.environ.get('PRODOS_KERNEL_BIN',
                            os.path.join(ROOT, 'vendor', 'ProDOS-2.4.bin'))
SYS_BIN = os.path.join(ROOT, 'build', 'MAUXSHLANG.SYSTEM')
SH_BIN = os.path.join(ROOT, 'build', 'sh.bin')
ECHO_BIN = os.path.join(ROOT, 'build', 'echo.bin')
CAT_BIN = os.path.join(ROOT, 'build', 'cat.bin')
CMP_BIN = os.path.join(ROOT, 'build', 'cmp.bin')
GREP_BIN = os.path.join(ROOT, 'build', 'grep.bin')
KILL_BIN = os.path.join(ROOT, 'build', 'kill.bin')
SLEEP_BIN = os.path.join(ROOT, 'build', 'sleep.bin')
ED_BIN = os.path.join(ROOT, 'build', 'ed.bin')  # Tier 3 here-doc's
                                                 # motivating case
OUT_IMG = os.path.join(ROOT, 'build', 'shlang.po')
OUT_IMG2 = os.path.join(ROOT, 'build', 'shlang-hd.po')

# FREE-BLOCK MARGINS (KFIX6 item 3). All three images are copies of the
# 280-block (140 KB) carrier, and a gate row that creates a file spends
# blocks from what staging left. When the volume fills the row fails
# with `cannot redirect` / a short write -- a red that reads as a code
# defect and is a full disk (measured in KFIX3: 25 new files mid-script).
# TWO guards, one on each side of the run:
#   * HERE, at staging: the spare blocks must not fall under a floor,
#     so a new staged file that eats the room fails the BUILD with the
#     number. Measured on 71175a2 after staging: shlang.po 25 free,
#     shlang-hd.po 41, shlang-b.po 56.
#   * in check_shlang.py, after a GREEN run: the spare blocks left once
#     every row has created its files must still clear END_MARGIN there
#     (measured: 11, 13, 25 -- the blt image's rows spend 31 blocks), so
#     erosion shows up while the gate is still green.
# The carrier cannot be grown in place (a2til has no resize), so the
# answer to "no room" is a NEW bigger volume (new_volume below, boot
# blocks copied across), or stage less, or move a row, never delete one. SHLANG_FREE_MARGIN_<KEY> overrides the
# floor, for the teeth.
FREE_MARGIN = {'shlang': 20, 'hd': 35, 'blt': 50}


VOL_BLOCKS = 1600          # 800K, was the 280-block carrier
BOOT_BYTES = 1024          # blocks 0 and 1: the ProDOS boot loader


def new_volume(path):
    """An empty VOL_BLOCKS volume formatted by a2til with the carrier's
    boot blocks spliced across (the house answer to a full 140 KB
    carrier, as build_ex_image.py / build_play_image.py). TAB-A2: sh
    grew by its line editor and the END margins below (8/10/20 spare
    blocks after a green run) fell to 7/9/21 on the 280-block carrier;
    the margins themselves are unchanged."""
    prodos.create(path, name=CARRIER_VOL, blocks=VOL_BLOCKS)
    with open(CARRIER_IMG, 'rb') as f:
        boot = f.read(BOOT_BYTES)
    if len(boot) != BOOT_BYTES or boot == bytes(BOOT_BYTES):
        raise SystemExit(f'error: {CARRIER_IMG} has no boot block to copy')
    with open(path, 'r+b') as f:
        f.write(boot)


def check_free_margin(img, key):
    margin = int(os.environ.get(f'SHLANG_FREE_MARGIN_{key.upper()}',
                                FREE_MARGIN[key]))
    vol = prodos.Volume(img)
    try:
        free, total = vol.free_blocks, vol.total_blocks
    finally:
        vol.close()
    print(f'[build-shlang] {os.path.basename(img)}: {free} of {total} '
          f'blocks free after staging (floor {margin})')
    if free < margin:
        print(f'error: {img}: only {free} blocks free after staging, '
              f'the floor is {margin} -- a gate row that creates a file '
              f'would fail for want of blocks, not code. Stage less (see '
              f'FREE_MARGIN in {os.path.basename(__file__)}).',
              file=sys.stderr)
        return 1
    return 0


def hitext(s):
    return bytes(ord(c) | 0x80 for c in s)


CR = bytes([0x8D])


def hilines(*lines):
    return b''.join(hitext(l) + CR for l in lines)


# ---------------------------------------------------------------------
# `cmp`'s three operands, staged. F1/F2 are byte-for-byte identical
# (`cmp` gate-proven silent exit 0, check-fleet); F3 differs (`cmp`
# gate-proven exit 1, docs/FLEET.md/check_fleet.py) -- reusing that
# proven behavior as the status GENERATOR the task brief specifies,
# rather than inventing a new one.
# ---------------------------------------------------------------------
F1_BYTES = hilines('SAMETEXT')
TDF1_BYTES = hilines('TDCAT')      # lives in /mnt/MAUX/TDIR
F2_BYTES = F1_BYTES                      # byte-for-byte identical
F3_BYTES = hilines('DIFFTEXT')            # differs from F1 at byte 1

# ---------------------------------------------------------------------
# `cat /mnt/MAUX/NOSUCHF`'s own stderr diagnostic (cat.s: "cat: cannot
# open <name>", fd 2 ONLY, exit 1), reused below as the fd-redirection
# gate's (docs/SH-FEATURES.md sec 3) generator. It used to be cmp's
# differ message until 2026-09-13, when cmp was made POSIX-conformant
# and that message moved to STDOUT (check-posixutil found it) -- a
# generator for a `2>` gate has to write to fd 2 and nothing else.
# ---------------------------------------------------------------------
DIFFMSG = 'cat: cannot open /mnt/MAUX/NOSUCHF'
DIFFMSGR = 'cat: cannot open /mnt/MAUX/NOSUCHR'

# ---------------------------------------------------------------------
# `grep` targets for the QUOTING gate (docs/SH-SUBSET.md sec 8): F4/F5
# each carry one line that a REGEX (liba/regex.s BRE, not a glob) can
# select and one that it cannot, so a correct quoted pattern proves
# selectivity, not just "grep ran". 'NOPE' contains no A, B or C at
# all, so it is the negative control for BOTH `"A*B"` (needs a literal
# B somewhere) and `"[ABC]"` (needs any of the three) at once.
# ---------------------------------------------------------------------
F4_BYTES = hilines('XAAABX', 'NOPE')
F5_BYTES = hilines('FOOTBALL', 'THE FOO BAR IS HERE')

# ---------------------------------------------------------------------
# `for f in *.S` glob target (docs/SH-FEATURES.md sec 4, Tier 2): three
# files whose NAMES sort deterministically -- content is irrelevant, the
# `for` case only ever reads the matched FILENAMES.
# ---------------------------------------------------------------------
GLOB_S_FILES = ['GFA.S', 'GFB.S', 'GFC.S']

# ---------------------------------------------------------------------
# Tier 1 `while`/`until` counters (docs/SH-FEATURES.md sec 4): each
# loop grows an initially-EMPTY file one "Z\r" at a time (`ECHO Z >>`)
# and tests it against one of these fixed targets with `cmp` -- no
# variables exist yet (Tier 2), so file growth compared byte-for-byte
# IS the counter. TGT2/TGT3 are read-only and shared across every
# loop case that needs a 2- or 3-iteration bound; each loop's own
# growing file (WA/UA/IA/... below) is unique so no two loops ever
# share mutable state.
# ---------------------------------------------------------------------
TGT2_BYTES = hilines('Z', 'Z')
TGT3_BYTES = hilines('Z', 'Z', 'Z')
# Every growing file starts at 0 bytes -- pre-staged empty, same as a
# fresh `> FILE` truncate would leave it. HDWA is Tier 3's own (the
# here-doc-inside-a-`while`-loop case) -- same shape, its own file so
# it shares no state with any Tier 1 loop above.
GROWING_FILES = ['WA', 'UA', 'IA', 'SA', 'BA', 'OA', 'IA2', 'CA', 'PA', 'QA',
                  'HDWA', 'HDWA2']

# ---------------------------------------------------------------------
# Tier 3 script fragments (docs/SH-FEATURES.md sec 4/6):
# - DOTFILE: `.`'s own case -- a single assignment, re-using FOO's
#   slot (see SCRIPT_TEXT's own comment on why).
# - HDBAD: the unterminated-here-doc case -- exactly ONE line, a
#   here-doc opened with no body and no terminator at all, so the
#   sourced file's own true EOF is what triggers HD_UNTERM.
# ---------------------------------------------------------------------
DOTFILE_TEXT = 'FOO=DOTVAL\r'
DOTFILE_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                      for c in DOTFILE_TEXT)
HDBAD_TEXT = 'CAT <<NOTERM\r'
HDBAD_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                    for c in HDBAD_TEXT)

# ---------------------------------------------------------------------
# The Tier 0 language script `sh` runs from fd 0 (staged as
# /mnt/MAUX/SCRIPT). `;`/`&&`/`||` are each their OWN whitespace-delimited
# token (docs/SH-SUBSET.md sec 6.1's "one rule, applied consistently",
# extended in sh.s's CLASSIFY to these three the same way it already
# applies to `<`/`>`/`|`).
# ---------------------------------------------------------------------
SCRIPT_TEXT = (
    # `;` sequencing: both commands run, in order.
    'ECHO A >> /mnt/MAUX/RESULTS ; ECHO B >> /mnt/MAUX/RESULTS\r'
    # `;` combined with a pipeline.
    'ECHO X | CAT >> /mnt/MAUX/RESULTS ; ECHO Y >> /mnt/MAUX/RESULTS\r'
    # `&&`: identical files -> CMP succeeds -> SAME1 DOES print.
    'CMP /mnt/MAUX/F1 /mnt/MAUX/F2 && ECHO SAME1 >> /mnt/MAUX/RESULTS\r'
    # `&&`: differing files -> CMP fails -> SAME2 must NOT print.
    'CMP /mnt/MAUX/F1 /mnt/MAUX/F3 && ECHO SAME2 >> /mnt/MAUX/RESULTS\r'
    # `||`: differing files -> CMP fails -> DIFF1 DOES print.
    'CMP /mnt/MAUX/F1 /mnt/MAUX/F3 || ECHO DIFF1 >> /mnt/MAUX/RESULTS\r'
    # Three-term left-associative chain: ((CMP && CHAINA) || CHAINB).
    # CMP fails -> CHAINA short-circuited -> CHAINB runs (proves
    # left-to-right precedence, not "|| always wins" or similar).
    'CMP /mnt/MAUX/F1 /mnt/MAUX/F3 && ECHO CHAINA >> /mnt/MAUX/RESULTS'
    ' || ECHO CHAINB >> /mnt/MAUX/RESULTS\r'
    # `$?` after success (standalone token).
    'CMP /mnt/MAUX/F1 /mnt/MAUX/F2\r'
    'ECHO $? >> /mnt/MAUX/RESULTS\r'
    # `$?` after failure (standalone token).
    'CMP /mnt/MAUX/F1 /mnt/MAUX/F3\r'
    'ECHO $? >> /mnt/MAUX/RESULTS\r'
    # `$?` embedded mid-token (not just a whole-token match) --
    # proves WORDEXPAND's scan is a substring scan.
    'CMP /mnt/MAUX/F1 /mnt/MAUX/F2\r'
    'ECHO STAT$? >> /mnt/MAUX/RESULTS\r'
    # -----------------------------------------------------------
    # `test`/`[` builtin (docs/SH-SUBSET.md sec 6). `test` MUST be
    # a shell builtin, not a binary (sec 6.3) -- there is no
    # TEST.bin on this image at all, so a wrong dispatch (falling
    # through to RUN_PIPELINE) would fail with "command not
    # found", not merely disagree on output.
    # -----------------------------------------------------------
    # `test -f`: true branch (existing file) and false branch
    # (missing file), each made visible via `&&`/`||`.
    'TEST -f /mnt/MAUX/F1 && ECHO TF1 >> /mnt/MAUX/RESULTS\r'
    'TEST -f /mnt/MAUX/NOPE || ECHO TF2 >> /mnt/MAUX/RESULTS\r'
    # `[ ... ]` alias -- same two results, proving both the `-f`
    # true/false split AND `-d` through the SAME code path.
    '[ -f /mnt/MAUX/F1 ] && ECHO BF1 >> /mnt/MAUX/RESULTS\r'
    '[ -d /mnt/MAUX/TDIR ] && ECHO BD1 >> /mnt/MAUX/RESULTS\r'
    # `$?` after a true test, then after a false test.
    'TEST -f /mnt/MAUX/F1\r'
    'ECHO TSTAT$? >> /mnt/MAUX/RESULTS\r'
    'TEST -f /mnt/MAUX/NOPE\r'
    'ECHO TSTAT$? >> /mnt/MAUX/RESULTS\r'
    # `[ -f X` with NO closing `]` -- usage error, status 2,
    # observed via `$?` (TEST_EVAL is never even reached for this
    # one -- CHCK_BLTN_TEST catches the missing `]` itself).
    '[ -f /mnt/MAUX/F1\r'
    'ECHO BSTAT$? >> /mnt/MAUX/RESULTS\r'
    # Command-position rule: `TEST`/`[` as a plain ECHO ARGUMENT
    # (not argv[0]) must NOT be treated as the builtin -- if it
    # were, sh would try to evaluate ECHO's own argv as a test
    # expression instead of printing it.
    'ECHO TEST >> /mnt/MAUX/RESULTS\r'
    'ECHO [ >> /mnt/MAUX/RESULTS\r'
    # -----------------------------------------------------------
    # Quoting (docs/SH-SUBSET.md sec 8). This is the motivating
    # case: `sh` globs any word holding `*`/`?`/`[`, and those are
    # ALSO regex metacharacters, so an unquoted pattern is glob-
    # mangled before `grep` ever sees it. A double-quoted word
    # must reach `grep` byte-exact, un-globbed.
    # -----------------------------------------------------------
    'GREP "A*B" /mnt/MAUX/F4 >> /mnt/MAUX/RESULTS\r'
    'GREP "[ABC]" /mnt/MAUX/F4 >> /mnt/MAUX/RESULTS\r'
    # Two words inside one pair of quotes arrive as ONE argument
    # -- if they had not, "BAR" would be read as a second FILE
    # operand instead of half the pattern.
    'GREP "FOO BAR" /mnt/MAUX/F5 >> /mnt/MAUX/RESULTS\r'
    # `"*"`/`'*'` -- globbing suppressed for BOTH quote forms; a
    # literal `*` prints, not a directory listing.
    'ECHO "*" >> /mnt/MAUX/RESULTS\r'
    "ECHO '*' >> /mnt/MAUX/RESULTS\r"
    # `"$?"` expands (double quotes only suppress globbing);
    # `'$?'` does not (single quotes suppress everything) -- these
    # two together prove the flag actually reaches WORDEXPAND, not
    # just GLOB_APPEND.
    'CMP /mnt/MAUX/F1 /mnt/MAUX/F2\r'
    'ECHO "$?" >> /mnt/MAUX/RESULTS\r'
    'CMP /mnt/MAUX/F1 /mnt/MAUX/F3\r'
    "ECHO '$?' >> /mnt/MAUX/RESULTS\r"
    # Backslash escaping a single glob metacharacter, no quotes at
    # all needed for it.
    'ECHO \\* >> /mnt/MAUX/RESULTS\r'
    # An unterminated quote never reaches PARSE -- nothing this
    # line would have written to RESULTS shows up at all -- and
    # sets a nonzero $?, read back on the NEXT line.
    # SH-MLQUOTE (2026-10-22): a SCRIPT line with an open quote now
    # CONTINUES onto the next line, as in every Bourne shell, so a
    # bare `ECHO "OOPS` here would swallow the rest of this script.
    # The error a quote can still raise inside one source is EOF
    # (check-shmlquote Q7f). A STRING source never continues, so
    # `sh -c` keeps the old detection path under test: TOKENIZE
    # refuses the open quote, the child exits 1, and the expected
    # RESULTS below are unchanged.
    "SH -c 'ECHO \"OOPS'\r"
    'ECHO $? >> /mnt/MAUX/RESULTS\r'
    # 2026-09-15: a quote reached MID-bare-token used to be
    # rejected from a DIFFERENT detection path than an unterminated
    # quote (a quote span that never closed, tested just above) --
    # `sh: mixed quoting`, unconditionally. It now CONCATENATES
    # instead (docs/SH-FEATURES.md sec 23): bare + double-quoted +
    # bare segments glue into ONE word, `abcdefghi`, and the
    # command succeeds ($?=0, not the old refusal's nonzero).
    'ECHO abc"def"ghi >> /mnt/MAUX/RESULTS\r'
    'ECHO $? >> /mnt/MAUX/RESULTS\r'
    # Regression: a BARE word still globs AND still expands --
    # quoting must not have disturbed the CURQFLAG==0 path. F1-F5
    # are the only two-character `F?` matches on this volume.
    'ECHO F? >> /mnt/MAUX/RESULTS\r'
    # -----------------------------------------------------------
    # fd-specific redirection (docs/SH-FEATURES.md sec 3): `2>`,
    # `N>`, `N>>`. `cmp` on F1/F3 (differing, `SAME2`/`DIFF1`
    # above already prove it fails on them) is the generator --
    # the task brief's own pick: it writes its "differ:"
    # diagnostic ONLY to fd 2, and nothing at all to fd 1.
    # -----------------------------------------------------------
    # AS-like stderr capture -- the motivating case (docs/IDE.md's
    # quickfix loop): `2>` catches what plain `sh` could never
    # redirect before this task.
    'CAT /mnt/MAUX/NOSUCHF 2> /mnt/MAUX/ERRS1\r'
    'CAT /mnt/MAUX/ERRS1 >> /mnt/MAUX/RESULTS\r'
    # `2>>` appends rather than truncates -- seed the target with
    # a marker line via a PLAIN `>` first, then `2>>` onto it.
    'ECHO MARK1 > /mnt/MAUX/ERRS2\r'
    'CAT /mnt/MAUX/NOSUCHF 2>> /mnt/MAUX/ERRS2\r'
    'CAT /mnt/MAUX/ERRS2 >> /mnt/MAUX/RESULTS\r'
    # `>` does NOT capture stderr: CAT's cannot-open diagnostic goes
    # ONLY to fd 2, so a PLAIN `>` target must come back EMPTY --
    # if `>` had grabbed fd 2 as well, this CAT would inject the
    # diff message into RESULTS and the byte-exact compare below
    # would catch it.
    'CAT /mnt/MAUX/NOSUCHF > /mnt/MAUX/OUTA\r'
    'CAT /mnt/MAUX/OUTA >> /mnt/MAUX/RESULTS\r'
    # `2>` does NOT capture stdout: ECHO writes ONLY to fd 1, so a
    # `2>` target must ALSO come back EMPTY -- this is the exact
    # shape of the "2> silently redirects fd 1" sabotage: if that
    # regressed, OUTB would hold "HELLOFD2" instead of nothing.
    'ECHO HELLOFD2 2> /mnt/MAUX/OUTB\r'
    'CAT /mnt/MAUX/OUTB >> /mnt/MAUX/RESULTS\r'
    # `1> FILE` behaves identically to `> FILE`.
    'ECHO SAMEAS1 > /mnt/MAUX/OUTC\r'
    'ECHO SAMEAS1 1> /mnt/MAUX/OUTD\r'
    'CAT /mnt/MAUX/OUTC >> /mnt/MAUX/RESULTS\r'
    'CAT /mnt/MAUX/OUTD >> /mnt/MAUX/RESULTS\r'
    # Quoting still wins: `"2>"` is a LITERAL two-character word,
    # never the fd-redirect operator (CLASSIFY never even runs on
    # a quoted token -- PARSE's new CURQFLAG guard, sh.s).
    'ECHO "2>" >> /mnt/MAUX/RESULTS\r'
    # -----------------------------------------------------------
    # Tier 1: if/elif/else/fi, while/until/do/done, break/
    # continue (docs/SH-FEATURES.md sec 4, docs/SHELL-SPLIT.md
    # sec 15). No `test`/`[` binary exists on this image either,
    # so every builtin call below proves the SAME thing sec 6.3
    # already established for Tier 0: it never spawns.
    # -----------------------------------------------------------
    # `if`/`fi`, true and false branches -- ONE LINE with `;`.
    'IF TEST -f /mnt/MAUX/F1 ; THEN ECHO IFTRUE1 >> /mnt/MAUX/RESULTS ; FI\r'
    'IF TEST -f /mnt/MAUX/NOPE ; THEN ECHO IFTRUE2 >> /mnt/MAUX/RESULTS ; FI\r'
    # `if`/`else`, both branches, same one-line shape.
    'IF TEST -f /mnt/MAUX/F1 ; THEN ECHO IFT >> /mnt/MAUX/RESULTS ; ELSE ECHO IFE >> /mnt/MAUX/RESULTS ; FI\r'
    'IF TEST -f /mnt/MAUX/NOPE ; THEN ECHO IFT2 >> /mnt/MAUX/RESULTS ; ELSE ECHO IFE2 >> /mnt/MAUX/RESULTS ; FI\r'
    # `elif` chain, SPANNING LINES -- first branch false, elif
    # true.
    'IF TEST -f /mnt/MAUX/NOPE\r'
    'THEN ECHO E1 >> /mnt/MAUX/RESULTS\r'
    'ELIF TEST -f /mnt/MAUX/F1\r'
    'THEN ECHO E2 >> /mnt/MAUX/RESULTS\r'
    'ELSE ECHO E3 >> /mnt/MAUX/RESULTS\r'
    'FI\r'
    # `elif` chain -- first branch TRUE suppresses the elif's own
    # condition entirely (RW_ELIF/RW_THEN's CSTAKEN guard; a
    # regression here would either run M2/M3 too or -- the sneakier
    # bug -- flip CSSKIP back open from stale $?).
    'IF TEST -f /mnt/MAUX/F1\r'
    'THEN ECHO M1 >> /mnt/MAUX/RESULTS\r'
    'ELIF TEST -f /mnt/MAUX/F1\r'
    'THEN ECHO M2 >> /mnt/MAUX/RESULTS\r'
    'ELSE ECHO M3 >> /mnt/MAUX/RESULTS\r'
    'FI\r'
    # `if` spanning lines, `then`/`fi` each their own line.
    'IF TEST -f /mnt/MAUX/F1\r'
    'THEN\r'
    'ECHO SPANIF >> /mnt/MAUX/RESULTS\r'
    'FI\r'
    # `while` -- grows a file it compares against a 3-line
    # target, terminating once they match: THREE iterations, each
    # one producing an observable RESULTS line -- proves the body
    # actually RE-EXECUTES (SHELL-SPLIT sec 15's seek trick), not
    # just runs once.
    'WHILE CMP /mnt/MAUX/WA /mnt/MAUX/TGT3 ; TEST $? -ne 0 ; DO ECHO WLOOP >> /mnt/MAUX/RESULTS ; ECHO Z >> /mnt/MAUX/WA ; DONE\r'
    # `until` -- inverted sense, same growth trick against a
    # 2-line target -- a loop CONTAINING AN IF in its body.
    'UNTIL CMP /mnt/MAUX/UA /mnt/MAUX/TGT2\r'
    'DO\r'
    'ECHO ULOOP >> /mnt/MAUX/RESULTS\r'
    'IF TEST -f /mnt/MAUX/F1 ; THEN ECHO INNERIF >> /mnt/MAUX/RESULTS ; FI\r'
    'ECHO Z >> /mnt/MAUX/UA\r'
    'DONE\r'
    # `if` CONTAINING A `while` -- true branch actually loops.
    'IF TEST -f /mnt/MAUX/F1\r'
    'THEN\r'
    'WHILE CMP /mnt/MAUX/IA /mnt/MAUX/TGT2 ; TEST $? -ne 0\r'
    'DO\r'
    'ECHO IFWLOOP >> /mnt/MAUX/RESULTS\r'
    'ECHO Z >> /mnt/MAUX/IA\r'
    'DONE\r'
    'FI\r'
    # `if` CONTAINING A `while` -- false branch. ZQ1/ZQ2 do not
    # exist on this volume at all: if the construct-stack's
    # OR-across-frames guard ever regressed and let a while
    # nested in a false branch actually evaluate its condition,
    # CMP would fail loudly and the loop WOULD run and print.
    'IF TEST -f /mnt/MAUX/NOPE\r'
    'THEN\r'
    'WHILE CMP /mnt/MAUX/ZQ1 /mnt/MAUX/ZQ2 ; TEST $? -ne 0\r'
    'DO\r'
    'ECHO SHOULDNOTRUN >> /mnt/MAUX/RESULTS\r'
    'DONE\r'
    'FI\r'
    # `while` SPANNING MULTIPLE LINES -- the loop head is the
    # line the WHILE token itself is on (CAP_LINE_MARK); DONE
    # seeks back to it and re-reads every intervening line fresh
    # on each of the two iterations.
    'WHILE CMP /mnt/MAUX/SA /mnt/MAUX/TGT2\r'
    'TEST $? -ne 0\r'
    'DO\r'
    'ECHO SPANLOOP >> /mnt/MAUX/RESULTS\r'
    'ECHO Z >> /mnt/MAUX/SA\r'
    'DONE\r'
    # `break` (default count 1) -- exits after the FIRST
    # iteration although the target needs three to match on its
    # own; AFTERBREAK proves the shell kept going past the loop.
    'WHILE CMP /mnt/MAUX/BA /mnt/MAUX/TGT3 ; TEST $? -ne 0 ; DO ECHO BLOOP >> /mnt/MAUX/RESULTS ; BREAK ; DONE\r'
    'ECHO AFTERBREAK >> /mnt/MAUX/RESULTS\r'
    # `break 2` -- from a NESTED loop, exits BOTH at once.
    # OUTERBODY must never print: break skips the rest of the
    # OUTER body too, not just the inner loop.
    'WHILE CMP /mnt/MAUX/OA /mnt/MAUX/TGT2 ; TEST $? -ne 0\r'
    'DO\r'
    'WHILE CMP /mnt/MAUX/IA2 /mnt/MAUX/TGT2 ; TEST $? -ne 0\r'
    'DO\r'
    'ECHO NEST >> /mnt/MAUX/RESULTS\r'
    'BREAK 2\r'
    'DONE\r'
    'ECHO OUTERBODY >> /mnt/MAUX/RESULTS\r'
    'DONE\r'
    'ECHO AFTERNEST >> /mnt/MAUX/RESULTS\r'
    # `continue` (default count 1) -- skips the rest of EACH
    # iteration's own body (CBOTTOM never prints) but the loop
    # still terminates normally, since the growth step runs
    # BEFORE the `continue`.
    'UNTIL CMP /mnt/MAUX/CA /mnt/MAUX/TGT2\r'
    'DO\r'
    'ECHO CTOP >> /mnt/MAUX/RESULTS\r'
    'ECHO Z >> /mnt/MAUX/CA\r'
    'CONTINUE\r'
    'ECHO CBOTTOM >> /mnt/MAUX/RESULTS\r'
    'DONE\r'
    # `continue 2` -- from a NESTED loop, restarts the OUTER
    # loop's own condition. SHOULDSKIP/OUTERSKIP never print
    # (QA is never modified, so the inner loop's own condition
    # would run forever if `continue 2` only unwound one level).
    'WHILE CMP /mnt/MAUX/PA /mnt/MAUX/TGT2 ; TEST $? -ne 0\r'
    'DO\r'
    'ECHO Z >> /mnt/MAUX/PA\r'
    'WHILE CMP /mnt/MAUX/QA /mnt/MAUX/TGT2 ; TEST $? -ne 0\r'
    'DO\r'
    'ECHO INNERC >> /mnt/MAUX/RESULTS\r'
    'CONTINUE 2\r'
    'ECHO SHOULDSKIP >> /mnt/MAUX/RESULTS\r'
    'DONE\r'
    'ECHO OUTERSKIP >> /mnt/MAUX/RESULTS\r'
    'DONE\r'
    # `break`/`continue` OUTSIDE a loop -- diagnostic to fd 2
    # (uncaptured here), nonzero $?, and the shell keeps running
    # rather than unwinding anything (there is nothing to unwind).
    'BREAK\r'
    'ECHO BRKSTAT$? >> /mnt/MAUX/RESULTS\r'
    'CONTINUE\r'
    'ECHO CONSTAT$? >> /mnt/MAUX/RESULTS\r'
    # Command-position rule, extended to the NEW reserved words:
    # `IF`/`WHILE` as a plain ECHO ARGUMENT (not argv[0]) print
    # literally, and quoting still wins too.
    'ECHO IF >> /mnt/MAUX/RESULTS\r'
    'ECHO "WHILE" >> /mnt/MAUX/RESULTS\r'
    # -----------------------------------------------------------
    # Tier 2: $1-$9/$0/$#, `shift`, `VAR=value`/`$VAR`, `for`/
    # `in`/`do`/`done` (docs/SH-FEATURES.md sec 4). `sh` is
    # spawned with a REAL argv this time (shlangtestb.s's
    # SH_ARGV): "SCRIPT" "ONE" "TWO" "THREE" -- $0="SCRIPT",
    # $1-$3 the rest, $4-$9 UNSET (empty), $# starts at 3.
    # -----------------------------------------------------------
    'ECHO $0 >> /mnt/MAUX/RESULTS\r'
    'ECHO $1 >> /mnt/MAUX/RESULTS\r'
    'ECHO $2 >> /mnt/MAUX/RESULTS\r'
    'ECHO $3 >> /mnt/MAUX/RESULTS\r'
    # $4 is past argc -- unset, same as an unset variable: empty,
    # not an error.
    'ECHO $4 >> /mnt/MAUX/RESULTS\r'
    'ECHO $# >> /mnt/MAUX/RESULTS\r'
    # `shift` moves $2->$1 etc; $0 and the COUNT both track it.
    'SHIFT\r'
    'ECHO $1 >> /mnt/MAUX/RESULTS\r'
    'ECHO $# >> /mnt/MAUX/RESULTS\r'
    'SHIFT\r'
    'ECHO $1 >> /mnt/MAUX/RESULTS\r'
    'ECHO $# >> /mnt/MAUX/RESULTS\r'
    'SHIFT\r'
    # Every positional parameter now shifted away -- $# is 0, but
    # $0 is UNAFFECTED (POSIX: shift never touches $0).
    'ECHO $# >> /mnt/MAUX/RESULTS\r'
    'ECHO $0 >> /mnt/MAUX/RESULTS\r'
    # One shift too many: loud diagnostic (fd 2, uncaptured here)
    # + nonzero $?, same "fail loudly" shape as the variable-table
    # -full case below, not a silent no-op.
    'SHIFT\r'
    'ECHO SHSTAT$? >> /mnt/MAUX/RESULTS\r'
    # -----------------------------------------------------------
    # Variables: `VAR=value` (command position ONLY), `$VAR`
    # expansion, re-assignment (overwrite, not a second slot),
    # `$UNSET` empty, `'$VAR'` literal vs `"$VAR"` expanded, and
    # `ECHO VAR=value` staying LITERAL (argv[1], not command
    # position).
    # -----------------------------------------------------------
    'FOO=BAR\r'
    'ECHO $FOO >> /mnt/MAUX/RESULTS\r'
    'FOO=BAZ\r'
    'ECHO $FOO >> /mnt/MAUX/RESULTS\r'
    'ECHO $UNSET >> /mnt/MAUX/RESULTS\r'
    "ECHO '$FOO' >> /mnt/MAUX/RESULTS\r"
    'ECHO "$FOO" >> /mnt/MAUX/RESULTS\r'
    'ECHO FOO=LITERAL >> /mnt/MAUX/RESULTS\r'
    # -----------------------------------------------------------
    # Tier 3 `.` (source, docs/SH-FEATURES.md sec 4): DOTFILE
    # re-assigns the SAME FOO slot (last set to BAZ, above) --
    # deliberately reusing it rather than a brand-new name, so
    # this case costs no extra variable-table slot AND is the
    # sharpest possible proof of CURRENT-SHELL execution: a
    # spawned CHILD would have its OWN empty variable table in
    # its OWN bank, could never touch the parent's FOO at all, and
    # $FOO would still read BAZ afterward, not DOTVAL.
    '. /mnt/MAUX/DOTFILE\r'
    'ECHO $FOO >> /mnt/MAUX/RESULTS\r'
    # -----------------------------------------------------------
    # `for`/`in`/`do`/`done` (docs/SH-FEATURES.md sec 4). DO must
    # end its own line (RW_DO_FOR's own v1 constraint, sh.s) --
    # every case below follows that shape.
    # -----------------------------------------------------------
    # Literal word list -- three iterations, and the loop variable
    # keeps its FINAL value once the loop ends (Bourne).
    'FOR X IN A B C\r'
    'DO\r'
    'ECHO FORX$X >> /mnt/MAUX/RESULTS\r'
    'DONE\r'
    'ECHO AFTERFOR$X >> /mnt/MAUX/RESULTS\r'
    # LOWERCASE loop variable + lowercase assignment + $lower
    # expansion -- the form a human types. The first human to
    # type `for x in ...` at the console got `sh: for: syntax
    # error` (2026-08-30): every gate spelled its variables
    # uppercase while the whole name pipeline admitted only A-Z.
    # Names are case-SENSITIVE (Bourne): x and X are distinct,
    # proven by reading BOTH after the loop.
    'for x in lo1 lo2\r'
    'DO\r'
    'ECHO LC$x >> /mnt/MAUX/RESULTS\r'
    'DONE\r'
    'ECHO CASE$x$X >> /mnt/MAUX/RESULTS\r'
    'lv=set\r'
    'ECHO ASGN$lv >> /mnt/MAUX/RESULTS\r'
    # `for f in *.S` -- glob-expanded BEFORE `for` ever sees the
    # word list (PARSE's ordinary token pipeline, sh.s), in
    # SORTED order. GFA.S/GFB.S/GFC.S are the only `*.S` files on
    # this volume.
    'FOR GF IN *.S\r'
    'DO\r'
    'ECHO GLOB$GF >> /mnt/MAUX/RESULTS\r'
    'DONE\r'
    # `for` containing an `if`.
    'FOR Y IN P Q\r'
    'DO\r'
    'IF TEST -f /mnt/MAUX/F1 ; THEN ECHO FORIF$Y >> /mnt/MAUX/RESULTS ; FI\r'
    'DONE\r'
    # `break` inside a `for` -- one iteration only, although the
    # word list has three; AFTERFORBRK proves execution resumed
    # past DONE rather than stopping dead.
    'FOR Z IN M N O\r'
    'DO\r'
    'ECHO FORBRK$Z >> /mnt/MAUX/RESULTS\r'
    'BREAK\r'
    'DONE\r'
    'ECHO AFTERFORBRK >> /mnt/MAUX/RESULTS\r'
    # -----------------------------------------------------------
    # Variable table full (docs/SH-FEATURES.md sec 4's own "fail
    # loudly when full"). MAXVARS is 8; FOO/X/GF/Y/Z above already
    # claimed 5 slots, so V1-V3 claim the last 3 (exactly 8) and
    # V4 is the 9th distinct name -- refused, loudly, $? nonzero.
    # -----------------------------------------------------------
    'V1=A\r'
    'V2=A\r'
    'V3=A\r'
    'V4=A\r'
    'ECHO VARSTAT$? >> /mnt/MAUX/RESULTS\r'
    # -----------------------------------------------------------
    # Tier 3: `:`, `<<`/`<<-` here-docs, `set -x`/`set +x`
    # (docs/SH-FEATURES.md sec 4/6). `.` is proven above, folded
    # into the FOO variable block it reuses.
    # -----------------------------------------------------------
    # `:` -- null command, always succeeds, extra args ignored.
    ': IGNOREDARG\r'
    'ECHO CLNSTAT$? >> /mnt/MAUX/RESULTS\r'
    # A plain here-doc feeding `cat` -- the GLUED form, `<<WORD`,
    # no space (v1 only supports this form, see this task's own
    # report).
    'CAT <<PLAINEOF >> /mnt/MAUX/RESULTS\r'
    'PLAINLINE1\r'
    'PLAINLINE2\r'
    'PLAINEOF\r'
    # `<<-` strips leading TABS from BOTH body lines and the
    # terminator line itself.
    'CAT <<-TABEOF >> /mnt/MAUX/RESULTS\r'
    '\tTABBED LINE\r'
    '\t\tTABEOF\r'
    # The motivating case (docs/SH-FEATURES.md sec 6, HACKING.md's
    # own example): a here-doc scripts an `ed` edit, no separate
    # .ED file at all -- `ed` reads its whole COMMAND SCRIPT from
    # stdin. (2026-09-02: `ed FILE`/`ex FILE` now load a FILE TO
    # EDIT via argv[1] at startup -- a different thing from this
    # heredoc, which feeds ed's own command language, not file
    # content; this phase deliberately still uses bare `ED` here
    # so the heredoc's `a`/text/`.`/`w`/`q` lines are read as
    # COMMANDS, not mistaken for a filename argument.)
    'ED <<EDEOF\r'
    'a\r'
    'HDLINE ONE\r'
    'HDLINE TWO\r'
    '.\r'
    'w /mnt/MAUX/HDOUT\r'
    'q\r'
    'EDEOF\r'
    'CAT /mnt/MAUX/HDOUT >> /mnt/MAUX/RESULTS\r'
    # A here-doc INSIDE a `while` loop -- the loop re-reads its
    # body by SEEKING (SHELL-SPLIT sec 15), so the here-doc must
    # be re-captured fresh each iteration; HDLOOP printing TWICE
    # (not once, not a hang) IS that proof.
    'WHILE CMP /mnt/MAUX/HDWA /mnt/MAUX/TGT2\r'
    'TEST $? -ne 0\r'
    'DO\r'
    'CAT <<LOOPEOF >> /mnt/MAUX/RESULTS\r'
    'HDLOOP\r'
    'LOOPEOF\r'
    'ECHO Z >> /mnt/MAUX/HDWA\r'
    'DONE\r'
    # -----------------------------------------------------------
    # This task's own gate case (c): a here-doc INSIDE a `while`
    # loop whose BODY references a variable the loop itself
    # reassigns each pass -- IT1 then IT2, not IT1 twice (a one-
    # shot expansion, captured only once when the loop's OWN line
    # is first read) and not IT2 twice (expanding at WRITE time,
    # against whatever FOO happens to hold when HD_WRITE_BODY
    # finally runs, well after both loop bodies have already
    # executed). Two DISTINCT values, in order, is the only
    # outcome capture-time-per-iteration expansion can produce.
    # Reuses FOO (last set to DOTVAL, above) -- overwrite, not a
    # new variable-table slot, same precedent FOO's own reuse
    # already sets; HDWA2 is its own growing file so this loop
    # shares no state with HDLOOP's, just above.
    # -----------------------------------------------------------
    'FOO=IT1\r'
    'WHILE CMP /mnt/MAUX/HDWA2 /mnt/MAUX/TGT2\r'
    'TEST $? -ne 0\r'
    'DO\r'
    'CAT <<ITEOF >> /mnt/MAUX/RESULTS\r'
    '$FOO\r'
    'ITEOF\r'
    'FOO=IT2\r'
    'ECHO Z >> /mnt/MAUX/HDWA2\r'
    'DONE\r'
    # An unterminated here-doc, and `set -x`/`set +x` (fd 2's own
    # trace) BOTH need their target sh's stderr captured -- and
    # that trace is written to whichever fd 2 THAT sh process
    # itself has, never a per-command `2>` target on its own
    # dispatch. Wiring the MAIN script's own top-level sh's fd 2
    # to a file for its WHOLE run (one early draft of this gate
    # tried exactly that, in shlangtestb.s's SPAWN_SH) turned out
    # to be the wrong tool: that sh has ALREADY spawned ~25
    # children by this point in the script, and rewiring one of
    # its OWN default fds for its entire lifetime -- a shape no
    # other gate in this project had ever exercised -- broke an
    # UNRELATED, already-passing `cmp ... 2>` test downstream
    # (`cmp: cannot open /mnt/MAUX/F3` where the differ-diagnostic was
    # expected). Reverted; root cause not chased further, since
    # `sh`'s own fd 2 is out of this task's scope to rewire at
    # process-launch time and the FIX available in-scope is
    # better anyway: spawn a FRESH, otherwise-idle `sh` and
    # capture ITS stderr the ORDINARY way, with a per-command `2>`
    # on the FRESH sh's own spawn line -- the exact mechanism
    # dozens of `cmp`/`echo` cases elsewhere in this same script
    # already prove works. TR3SCRIPT is that fresh sh's own
    # script (stdin redirected from it, `<`), sourcing HDBAD
    # (isolating the missing terminator to THAT sub-shell's own
    # sub-sourced file, not this one) and running the `set -x`
    # pair -- both diagnostics land in /mnt/MAUX/SHERR, captured by
    # `2>` on the SH spawn itself.
    # -----------------------------------------------------------
    # THE TWO BUGS A HUMAN FOUND IN NINETY SECONDS (2026-08-23,
    # docs/SH-CASE.md and docs/SH-DOTPATH.md). EVERY LINE BELOW IS
    # TYPED THE WAY A HUMAN TYPES IT -- lowercase, and with dots.
    #
    # That is the whole point of the block, not a stylistic
    # choice. Both bugs walked past 56 gates, a differential
    # harness against /usr/bin, and a fleet audit, because every
    # other case in this file types what its author already knew
    # would resolve. A gate that only ever shouts cannot see a
    # shell that only answers to shouting.
    # -----------------------------------------------------------
    # `cd` in lowercase, then a RELATIVE access to prove the
    # directory really MOVED -- the same discipline docs/CD.md's
    # own gate insisted on, and the reason echoing `pwd` would
    # not be a test. Before the fix `cd` fell through to
    # RUN_PIPELINE, printed `sh: command not found` (there is no
    # CD binary, on this image or any other), and TDCAT never
    # appeared.
    'cd /mnt/MAUX/TDIR\r'
    'cat TDF1 >> /mnt/MAUX/RESULTS\r'
    # "./X" and "../X" resolved by a SPAWNED program, not by the
    # shell -- MKPATH is liba's, so these two lines are the whole
    # fleet's fix being exercised through the one binary this
    # image happens to carry.
    'cat ./TDF1 >> /mnt/MAUX/RESULTS\r'
    'cat ../F1 >> /mnt/MAUX/RESULTS\r'
    # A bare "." and a bare ".." as WHOLE arguments, through the
    # `test -d` builtin -- sh's own MKPATH call site.
    #
    # THESE TWO PASSED BEFORE THE FIX TOO, and they are kept
    # BECAUSE of that, not in spite of it. Sabotaging MKPATH's
    # dot branch (2026-08-23) killed every other case in this
    # block and left DOTDIR/DDDIR standing, which is how the
    # three control lines below came to be written: they say
    # that `-d` is not simply always-true (a NOSUCH directory is
    # false), that a leading dot is not blanket-accepted
    # (`.NOSUCH` is false), and that `.` is a DIRECTORY rather
    # than merely something (`test -f .` is false).
    #
    # What is left, once those three are false and DOTDIR is
    # true, is a measured fact about ProDOS and not about maux:
    # GET_FILE_INFO resolves a bare "." and ".." on its own.
    # That is exactly why this bug could hide -- `test -d .`
    # answered correctly all along while `find .` could not
    # access the same directory. The teeth for a bare "." live
    # in check-find, on the command the bug report named.
    'test -d . && echo DOTDIR >> /mnt/MAUX/RESULTS\r'
    'test -d .. && echo DDDIR >> /mnt/MAUX/RESULTS\r'
    'test -d /mnt/MAUX/NOSUCH && echo NOTADIR >> /mnt/MAUX/RESULTS\r'
    'test -d .NOSUCH && echo DOTNOSUCH >> /mnt/MAUX/RESULTS\r'
    'test -f . && echo DOTISFILE >> /mnt/MAUX/RESULTS\r'
    'echo DOTCTL >> /mnt/MAUX/RESULTS\r'
    # `cd ..` and `cd ../..`. The second is a REGRESSION case, not
    # a new feature: it already worked through the kernel's
    # PRC_DOTDOT, and MKPATH now resolves the leading run before
    # SET_PREFIX ever sees it -- so a one-shot pop here would hand
    # the kernel "/mnt/MAUX/.." and break a passing case. Each is
    # followed by a relative read that only succeeds from the
    # directory the `cd` claimed to reach.
    'cd ..\r'
    'cat ./F1 >> /mnt/MAUX/RESULTS\r'
    # `cd /mnt/MAUX/TDIR/SUB` then `cd ../..`, NOT `cd /mnt/MAUX/TDIR`:
    # docs/DEVFS.md (2026-09-30) made "/" a REAL pseudo-root ABOVE
    # every volume, so two pops from /mnt/MAUX/TDIR would now land at
    # "/" (a SYNTHETIC directory with no F1 to `cat`) instead of
    # clamping at /mnt/MAUX/ the way this case originally assumed --
    # see docs/CD.md's 2026-09-30 addendum. One level deeper keeps
    # this case's actual intent (`cd ../..` genuinely moves, proved
    # by a relative read) without also exercising devfs's own
    # cat-on-synthetic-path behaviour, which check-devfs already
    # covers.
    'cd /mnt/MAUX/TDIR/SUB\r'
    'cd ../..\r'
    'cat ./F1 >> /mnt/MAUX/RESULTS\r'
    # Lowercase reserved words and lowercase builtins that have NO
    # binary twin, so a missed dispatch cannot be masked by ProDOS
    # folding the name of a program on disk. `test`, `if`/`then`/
    # `fi`, `for`/`in`/`do`/`done`, `set -x`/`set +x`, `break`.
    'if test -f /mnt/MAUX/F1\r'
    'then\r'
    'echo LCIF >> /mnt/MAUX/RESULTS\r'
    'fi\r'
    # Z, not a fresh name: MAXVARS is 8 and this script has
    # already spent them, so a ninth would expand to nothing and
    # the case would pass for the wrong reason.
    'for Z in P Q\r'
    'do\r'
    'echo LCFOR$Z >> /mnt/MAUX/RESULTS\r'
    'break\r'
    'done\r'
    'set -x\r'
    'set +x\r'
    'echo LCSET$? >> /mnt/MAUX/RESULTS\r'
    # Command position is still what decides: `echo cd` is a word,
    # never the builtin, in lowercase exactly as in upper.
    'echo cd >> /mnt/MAUX/RESULTS\r'
    # -----------------------------------------------------------
    # BACKGROUND `&` AND `wait` (docs/SH-BG.md). Held out of v1
    # by SH-SUBSET sec 4 and released by ANACHRONISMS sec W4's
    # recorded reversal: idle at the prompt is harvestable, and
    # `AS BIG.S > LOG &` is the operator's own motivating line.
    # -----------------------------------------------------------
    # `cmp` on DIFFERING files exits 1. Backgrounded, `$?` must
    # be 0 anyway -- POSIX gives an asynchronous list an exit
    # status of zero. That is the sharpest assertion available
    # that sh did NOT wait: the real status exists, it is 1, and
    # the shell must not have it yet. Making `&` a plain word
    # again gives `cmp` a third operand and $? becomes 2;
    # making RUN_PIPELINE wait anyway gives $? = 1. Neither is
    # 0, so both sabotages are visible in one character.
    'cat /mnt/MAUX/NOSUCHF 2> /mnt/MAUX/BGOUT &\r'
    'echo BG$? >> /mnt/MAUX/RESULTS\r'
    'wait\r'
    'echo WAITED$? >> /mnt/MAUX/RESULTS\r'
    # The child really ran, and `wait` really reaped it: after a
    # reap the child has EXITed, so its buffered output is
    # flushed and closed and this `cat` cannot race it.
    'cat /mnt/MAUX/BGOUT >> /mnt/MAUX/RESULTS\r'
    # A `wait` with nothing outstanding is a no-op returning 0,
    # not an ERR_CHILD and not a hang.
    'wait\r'
    'echo NOWAIT$? >> /mnt/MAUX/RESULTS\r'
    # `&` SEQUENCES like `;`: the next segment on the same line
    # runs unconditionally. The background half writes to its own
    # file rather than RESULTS, because which of two concurrent
    # appends lands first is exactly the thing a byte-exact gate
    # must not depend on.
    'echo SEQA > /mnt/MAUX/BGOUT2 & echo SEQB >> /mnt/MAUX/RESULTS\r'
    'wait\r'
    'cat /mnt/MAUX/BGOUT2 >> /mnt/MAUX/RESULTS\r'
    # And `&&` is still `&&` -- one `&` changing meaning must not
    # have changed two.
    'cmp /mnt/MAUX/F1 /mnt/MAUX/F2 && echo STILLAND >> /mnt/MAUX/RESULTS\r'
    # `wait PID` is REFUSED, loudly, rather than quietly reaping
    # everything: SC_WAIT takes no pid, so there is no honest way
    # to honour the operand. Nonzero $? IS the assertion -- the
    # diagnostic itself goes to this sh's own fd 2, which is the
    # console here and not captured (docs/SH-BG.md).
    'wait 5\r'
    'echo WARG$? >> /mnt/MAUX/RESULTS\r'
    # -----------------------------------------------------------
    # BACKGROUND-ZOMBIE vs FOREGROUND STATUS (docs/SH-BG.md B1/B2).
    # Recovered 2026-09-16 from the unlanded `s2/eng-a-bgfix`
    # adversarial review; the sh.s half of that branch is
    # superseded by job control (shjob.s: SC_WAITJOB + JOB_REAP
    # demux), but nothing gates the defect it found, so the CASES
    # land even though the fix did not.
    #
    # The `&` block above CANNOT discriminate it: `echo BG$?`
    # reads $? on its OWN line, after BG_RECORD has already left
    # LASTSTATUS 0 with no intervening FOREGROUND reap, and both
    # of its background children are explicitly `wait`ed before
    # anything else runs.
    # CONTROL -- no background job outstanding. $? must be 1.
    # Without this, a red below cannot be told from `cmp` simply
    # not exiting 1 any more.
    'cmp /mnt/MAUX/F1 /mnt/MAUX/F3\r'
    'echo BGCTRL$? >> /mnt/MAUX/RESULTS\r'
    # CONTROL -- a background job outstanding but explicitly
    # reaped BEFORE the foreground command. Still 1.
    'cmp /mnt/MAUX/F1 /mnt/MAUX/F2 &\r'
    'wait\r'
    'cmp /mnt/MAUX/F1 /mnt/MAUX/F3\r'
    'echo BGCTRLW$? >> /mnt/MAUX/RESULTS\r'
    # THE REGRESSION, and the row with the teeth. A background job
    # zombies almost immediately (`cmp` on IDENTICAL files, exits
    # 0) and is left un-waited. A foreground command with a KNOWN
    # NONZERO status runs next. If any reaped child can answer for
    # the foreground one, the older, already-dead background job
    # satisfies the wait and $? comes back 0. It MUST be 1.
    #
    # TEETH, MEASURED 2026-09-16 on the box: `clc` -> `sec` in
    # shjob.s's JOB_ISFG (its not-the-foreground-row exit), which
    # makes FG_WAIT accept whichever row it just reaped, turns
    # THIS LINE AND ONLY THIS LINE red -- `BGFGSTAT1` ->
    # `BGFGSTAT0`. Both controls above and BGNINEOK below stay
    # green under that sabotage, which is what makes the red
    # readable: it is specifically "a background zombie answered
    # for the foreground child", not "cmp stopped exiting 1".
    'cmp /mnt/MAUX/F1 /mnt/MAUX/F2 &\r'
    'cmp /mnt/MAUX/F1 /mnt/MAUX/F3\r'
    'echo BGFGSTAT$? >> /mnt/MAUX/RESULTS\r'
    # NINE background jobs -- one past the old, false BGMAX of 8,
    # nine of the real fourteen-bank ceiling -- then `wait`, then
    # a `>>` redirect. When the cap was 8 the ninth spawn's pid
    # was silently dropped, `wait` could never reap it, its bank
    # leaked for the life of the boot, and the NEXT `>>` redirect
    # failed with its output silently discarded.
    #
    # THIS ROW IS A SMOKE ROW, NOT A DISCRIMINATING ONE, and that
    # was measured rather than assumed: reverting `BGMAX equ 14`
    # to `8` on the box (2026-09-16) left the WHOLE gate green.
    # The reason is job control -- JOB_DRAIN frees Done rows
    # before every line and `cmp` on identical files exits at
    # once, so these nine never hold nine rows at the same time
    # and the cap is never reached. The row is kept for what it
    # does assert end to end (nine `&` spawns, a `wait` that
    # drains them, and a later `>>` that still works), but a red
    # here would not by itself mean BGMAX regressed. Restoring
    # the old monotonic BG_CNT is what that defect needed, and
    # that code no longer exists to regress.
    'cmp /mnt/MAUX/F1 /mnt/MAUX/F2 &\r'
    'cmp /mnt/MAUX/F1 /mnt/MAUX/F2 &\r'
    'cmp /mnt/MAUX/F1 /mnt/MAUX/F2 &\r'
    'cmp /mnt/MAUX/F1 /mnt/MAUX/F2 &\r'
    'cmp /mnt/MAUX/F1 /mnt/MAUX/F2 &\r'
    'cmp /mnt/MAUX/F1 /mnt/MAUX/F2 &\r'
    'cmp /mnt/MAUX/F1 /mnt/MAUX/F2 &\r'
    'cmp /mnt/MAUX/F1 /mnt/MAUX/F2 &\r'
    'cmp /mnt/MAUX/F1 /mnt/MAUX/F2 &\r'
    'wait\r'
    'echo BGNINEOK >> /mnt/MAUX/RESULTS\r'
    # -----------------------------------------------------------
    # A `$( )` CHILD MUST BE REAPED BY PID (docs/SH-BG.md). This
    # is the SECOND half of the `s2/eng-a-bgfix` review, the half
    # c475246 recorded as open and did not gate: shsubst.s's
    # SUB_WAITST reaped with a pid-LESS wait and took whatever
    # came back as the substitution's `$?`. The argument it stood
    # on lives in shexp2.s's CMDSUBST header -- "this runs during
    # PARSE ... always BEFORE RUN_PIPELINE has spawned anything,
    # so SUB_RUN's SC_WAIT can only ever reap its own child" --
    # and it is true of THIS line's children and false of an
    # EARLIER `&` job's.
    #
    # WHY ONE LINE AND NOT THREE, which is the whole reason this
    # case took a shape rather than being written the obvious
    # way. JOB_DRAIN (shjob.s) polls at the top of MAINLOOP, once
    # per LINE, and would reap the background job LEGITIMATELY
    # before a substitution on the next line ever ran -- the bug
    # is unreachable across a line boundary. The `:seg` loop does
    # NOT drain between segments, so the `&` and the substitution
    # must share a line for the zombie to still be outstanding;
    # and `wait %1` must share it too, or that same drain frees
    # the row before it can be asked.
    #
    # THE TIMING IS A MARGIN, NOT A COINCIDENCE. The background
    # `cmp` is spawned FIRST and cannot open its first operand,
    # so it exits almost immediately and with status 2. The
    # substitution body carries a `|`, so its child is a NESTED
    # SH -- a 24 KB binary load before its own two `cat`s even
    # start. The background child is a zombie long before the
    # capture reaches EOF and SUB_WAITST is called.
    #
    # STATUS 2, NOT 1, and that is deliberate: `wait %1` on a job
    # number that does not resolve is a DIAGNOSTIC with `$?` = 1,
    # which is exactly the value a 1 here would have to be. Three
    # distinct answers instead: SW2 correct, SW0 the defect (the
    # status consumed and thrown away), SW1 "no such job" -- so a
    # green cannot be bought by the row not running.
    #
    # THREE assertions over two RESULTS lines:
    #   SC:SAMETEXT:  the capture, intact -- a CONTROL, since
    #                 SUB_WAITST runs after EOF and the defect
    #                 cannot touch it
    #   SQ0           `$?` at the substitution is the
    #                 SUBSTITUTION's status, not the background
    #                 job's 2
    #   SW2           and the background job's own status is
    #                 still there for `wait %1` to report
    'cmp /mnt/MAUX/NOSUCHF /mnt/MAUX/F1 & echo SC:$(cat /mnt/MAUX/F1 | cat): SQ$? '
    '>> /mnt/MAUX/RESULTS ; wait %1 ; echo SW$? >> /mnt/MAUX/RESULTS\r'
    # CONTROL -- the IDENTICAL substitution with no background job
    # outstanding. Without it, a red above cannot be told from
    # `$( )` simply having stopped reporting 0.
    'echo SC2:$(cat /mnt/MAUX/F1 | cat): SQ2$? >> /mnt/MAUX/RESULTS\r'
    # -----------------------------------------------------------
    # BACKSLASH QUOTING (docs/SHELL-GAPS.md sec 3). PROBE RUN
    # 2026-08-25 -- expectations below are MEASURED FIRST, then
    # ruled on, because the question is what the CURRENT tokenizer
    # does to each of these, and sec 3's own table does not cover
    # the `\\$` case at all.
    # CONTROL, and it is not optional. The first draft of this
    # probe assigned a FRESH name here and every $-case came
    # back empty -- MAXVARS is 8, this script's for/read cases
    # create variables too, the table was FULL and the
    # assignment failed. An unset variable and a suppressed
    # expansion produce identical output, so without this line
    # the measurement was meaningless. FOO is set far above
    # (FOO=IT2) and is already in the table.
    'ECHO CTL$FOO >> /mnt/MAUX/RESULTS\r'
    # (a) escape then a later expansion in the same word. sec 3
    #     says maux prints xyV$V and bash prints xyVhello.
    'ECHO x\\yV$FOO >> /mnt/MAUX/RESULTS\r'
    # (b) escaped '$' -- must stay LITERAL. This is the case that
    #     the blanket suppression currently gets right BY
    #     ACCIDENT, and the one a move to quote level 2 would
    #     break, since level 2 runs expansion.
    'ECHO A\\$FOO >> /mnt/MAUX/RESULTS\r'
    # (c) escaped backslash.
    'ECHO P\\\\Q >> /mnt/MAUX/RESULTS\r'
    # (d) escaped space -- one token, not two.
    'ECHO R\\ S >> /mnt/MAUX/RESULTS\r'
    # (e) THE GLOBBING HALF, which no token-level fix could reach.
    #     An escaped ORDINARY character next to a LIVE wildcard:
    #     the '\G' must stay a plain G that still MATCHES, while
    #     the '*' must still expand. GFA.S/GFB.S/GFC.S are the
    #     only *.S files on this volume.
    #
    #     THIS IS THE CASE THAT PROVES GFOLD'S `ora #$80`. The
    #     escaped G is stored with bit 7 clear ($47); the
    #     directory holds $C7. Without the normalisation those
    #     compare unequal, the glob matches nothing, and the
    #     pattern passes through literally as 'G*.S'.
    'ECHO \\G*.S >> /mnt/MAUX/RESULTS\r'
    # (f) An escaped WILDCARD: '*' must stop being one, for that
    #     character only. HASMETA never sees the low-bit form, so
    #     the word is appended literally -- bash prints A*B.
    'ECHO A\\*B >> /mnt/MAUX/RESULTS\r'
    # -----------------------------------------------------------
    # `case`/`esac` (docs/SHELL-GAPS.md sec 4). FOO is IT2 here.
    # (1) literal pattern matches; a later pattern must NOT run.
    'CASE HELLO IN\r'
    'HELLO) ECHO CASE1 >> /mnt/MAUX/RESULTS ;;\r'
    'WORLD) ECHO CASENO1 >> /mnt/MAUX/RESULTS ;;\r'
    'ESAC\r'
    # (2) `*)` default, reached only because nothing above matched.
    'CASE ZZZ IN\r'
    'ALPHA) ECHO CASENO2 >> /mnt/MAUX/RESULTS ;;\r'
    '*) ECHO CASEDEF >> /mnt/MAUX/RESULTS ;;\r'
    'ESAC\r'
    # (3) alternation, with the hit in the MIDDLE so neither a
    #     first-only nor a last-only loop can pass by luck.
    'CASE ABC IN\r'
    'X|ABC|Y) ECHO CASEALT >> /mnt/MAUX/RESULTS ;;\r'
    'ESAC\r'
    # (4) a GLOB pattern, and FIRST-MATCH-WINS: both patterns
    #     match ABC, only the first branch may run.
    'CASE ABC IN\r'
    'AB*) ECHO CASEGLOB >> /mnt/MAUX/RESULTS ;;\r'
    'ABC) ECHO CASENO3 >> /mnt/MAUX/RESULTS ;;\r'
    'ESAC\r'
    # (5) the word is EXPANDED before matching.
    'CASE $FOO IN\r'
    'IT2) ECHO CASEVAR >> /mnt/MAUX/RESULTS ;;\r'
    'ESAC\r'
    # (6) NO branch matches: nothing runs, and the shell carries
    #     on to the next line rather than hanging or erroring.
    'CASE QQQ IN\r'
    'A) ECHO CASENO4 >> /mnt/MAUX/RESULTS ;;\r'
    'ESAC\r'
    'ECHO CASEAFTER >> /mnt/MAUX/RESULTS\r'
    # (7) NESTED case: the inner ESAC must pop the inner frame
    #     only, and the outer branch must still be running after
    #     it -- CASEOUT proves the outer frame survived.
    'CASE A IN\r'
    'A) CASE B IN\r'
    'B) ECHO CASENEST >> /mnt/MAUX/RESULTS ;;\r'
    'ESAC\r'
    'ECHO CASEOUT >> /mnt/MAUX/RESULTS ;;\r'
    'ESAC\r'
    # (8) a `case` INSIDE an if, and a body with TWO commands --
    #     `;;` ends the branch, not the first command in it.
    # CASE opens on its OWN line, not glued after THEN. A reserved
    # word following ANOTHER reserved word in the same segment is
    # a pre-existing sh limitation (CHCK_RESERVED looks at argv[0]
    # once), unrelated to `case` -- `THEN IF` has the same shape.
    'IF TEST -f /mnt/MAUX/F1 ; THEN ECHO CASETWO0 >> /mnt/MAUX/RESULTS\r'
    'CASE K IN\r'
    'K) ECHO CASETWO1 >> /mnt/MAUX/RESULTS\r'
    'ECHO CASETWO2 >> /mnt/MAUX/RESULTS ;;\r'
    'ESAC\r'
    'FI\r'
    # SH-SEQ B (appended; nothing above changes): the ONE-LINE case.
    # (9) first pattern matches, ESAC on the same line.
    'CASE ONE IN ONE) ECHO CASEL1 >> /mnt/MAUX/RESULTS ;; ESAC\r'
    # (10) no match on one line: CASENO5 must not appear, and the
    #      next line still runs.
    'CASE ONE IN TWO) ECHO CASENO5 >> /mnt/MAUX/RESULTS ;; ESAC\r'
    'ECHO CASEL2 >> /mnt/MAUX/RESULTS\r'
    # (11) the first pattern misses, the second hits.
    'CASE B IN A) ECHO CASENO6 >> /mnt/MAUX/RESULTS ;; B) ECHO CASEL3 '
    '>> /mnt/MAUX/RESULTS ;; ESAC\r'
    # (12) two commands in the one-line branch.
    'CASE K IN K) ECHO CASEL4 >> /mnt/MAUX/RESULTS ; ECHO CASEL5 '
    '>> /mnt/MAUX/RESULTS ;; ESAC\r'
    # (13) a one-line case inside an if.
    'IF TEST -f /mnt/MAUX/F1 ; THEN ECHO CASEL6 >> /mnt/MAUX/RESULTS\r'
    'CASE K IN K) ECHO CASEL7 >> /mnt/MAUX/RESULTS ;; ESAC\r'
    'FI\r'
    'SH < /mnt/MAUX/TR3SCRIPT 2> /mnt/MAUX/SHERR\r'
    'EXIT\r'
)

# ---------------------------------------------------------------------
# TR3SCRIPT (Tier 3, docs/SH-FEATURES.md sec 4/6): run under a FRESH,
# nested `sh` (see SCRIPT_TEXT's own comment on why) so its fd 2 can be
# captured with an ORDINARY `2>` on the spawn itself. RESULTS lines it
# writes land in the SAME /mnt/MAUX/RESULTS the outer script uses -- a
# ProDOS path, not an inherited fd, so which `sh` process does the
# appending does not matter.
# ---------------------------------------------------------------------
TR3SCRIPT_TEXT = (
    # An unterminated here-doc: EOF before the terminator is a
    # diagnostic (fd 2) and nonzero $?, never a hang. Isolated in
    # its OWN sourced file (HDBAD, via `.`) so the missing
    # terminator only swallows THAT file's own remainder, not the
    # rest of THIS (already tiny) script -- `.`'s own EOF handling
    # (Tier 3, sh.s MAINLOOP) is what lets this script resume
    # right after.
    '. /mnt/MAUX/HDBAD\r'
    'ECHO UNTSTAT$? >> /mnt/MAUX/RESULTS\r'
    # `set -x`/`set +x` -- the trace lands on THIS sh's own fd 2,
    # captured by the outer script's `2>` on the spawn that runs
    # this whole file -- checked by scripts/check_shlang.py as a
    # substring, not byte-exact (this here-doc diagnostic lands in
    # the same SHERR too).
    'SET -X\r'
    'ECHO TRACEME >> /mnt/MAUX/RESULTS\r'
    'SET +X\r'
    'ECHO NOTRACE >> /mnt/MAUX/RESULTS\r'
    'EXIT\r'
)
TR3SCRIPT_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                        for c in TR3SCRIPT_TEXT)
SCRIPT_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                     for c in SCRIPT_TEXT)

# ---------------------------------------------------------------------
# EXPECTED /mnt/MAUX/RESULTS -- THE CONTRACT, byte-exact, in script order.
# SAME2/CHAINA's absence IS the assertion for the `&&` short-circuit
# and left-associativity cases -- there is no separate "did NOT run"
# check; a byte-exact whole-file compare covers it for free.
# ---------------------------------------------------------------------
EXPECT_RESULTS = (
    hilines('A', 'B') +
    hilines('X', 'Y') +
    hilines('SAME1') +
    hilines('DIFF1') +
    hilines('CHAINB') +
    hilines('0') +
    hilines('1') +
    hilines('STAT0') +
    hilines('TF1') +
    hilines('TF2') +
    hilines('BF1') +
    hilines('BD1') +
    hilines('TSTAT0') +
    hilines('TSTAT1') +
    hilines('BSTAT2') +
    hilines('TEST') +
    hilines('[') +
    hilines('XAAABX') +               # GREP "A*B" -- NOPE excluded
    hilines('XAAABX') +               # GREP "[ABC]" -- NOPE excluded
    hilines('THE FOO BAR IS HERE') +  # GREP "FOO BAR" -- FOOTBALL excluded
    hilines('*') +                    # ECHO "*"
    hilines('*') +                    # ECHO '*'
    hilines('0') +                    # ECHO "$?" (expands)
    hilines('$?') +                   # ECHO '$?' (literal)
    hilines('*') +                    # ECHO \*
    hilines('1') +                    # $? after the unterminated quote
    hilines('abcdefghi') +            # bare+"..."+bare CONCATENATE
    hilines('0') +                    # ...and it succeeded ($?=0)
    hilines('F1 F2 F3 F4 F5') +       # bare `F?` still globs
    hilines(DIFFMSG) +                # CAT ERRS1 -- `2>` caught it
    hilines('MARK1') +                # CAT ERRS2 -- `2>>` kept the
    hilines(DIFFMSG) +                #   seed AND appended (no trunc)
    # CAT OUTA: EMPTY -- `>` did not also catch cmp's stderr
    # CAT OUTB: EMPTY -- `2>` did not also catch echo's stdout
    hilines('SAMEAS1') +              # CAT OUTC -- plain `>`
    hilines('SAMEAS1') +              # CAT OUTD -- `1>`, identical
    hilines('2>') +                   # ECHO "2>" -- quoting still
                                       # wins over the new operator
    # ---------------- Tier 1: if/while/until/break/continue ---
    hilines('IFTRUE1') +              # `if`/`fi` true branch
                                       # (IFTRUE2's absence IS the
                                       # false-branch assertion)
    hilines('IFT') +                  # `if`/`else` true branch
    hilines('IFE2') +                 # `if`/`else` false branch
    hilines('E2') +                   # `elif` chain -- matched
    hilines('M1') +                   # `elif` chain -- first
                                       # branch taken, elif's own
                                       # condition never evaluated
    hilines('SPANIF') +               # `if` spanning lines
    hilines('WLOOP', 'WLOOP', 'WLOOP') +  # `while`, 3 iterations
    hilines('ULOOP', 'INNERIF', 'ULOOP', 'INNERIF') +
                                       # `until` containing an `if`,
                                       # 2 iterations
    hilines('IFWLOOP', 'IFWLOOP') +   # `if` containing a `while`,
                                       # true branch, 2 iterations
    # (SHOULDNOTRUN's absence IS the false-branch assertion --
    # the while nested in it never even evaluates its condition)
    hilines('SPANLOOP', 'SPANLOOP') + # `while` spanning lines,
                                       # 2 iterations
    hilines('BLOOP') +                # `break` -- one iteration,
                                       # not the three the target
                                       # would otherwise need
    hilines('AFTERBREAK') +           # execution resumed past it
    hilines('NEST') +                 # `break 2` -- one inner
                                       # iteration only
    hilines('AFTERNEST') +            # (OUTERBODY's absence IS
                                       # the "both loops" assertion)
    hilines('CTOP', 'CTOP') +         # `continue` -- 2 iterations
                                       # (CBOTTOM's absence IS the
                                       # "skips the rest" assertion)
    hilines('INNERC', 'INNERC') +     # `continue 2` -- 2 outer
                                       # iterations, each restarted
                                       # from the inner (SHOULDSKIP/
                                       # OUTERSKIP's absence IS the
                                       # "unwinds two levels" proof)
    hilines('BRKSTAT1') +             # `break` outside a loop --
                                       # diagnostic + nonzero $?
    hilines('CONSTAT1') +             # `continue` outside a loop
                                       # -- same
    hilines('IF') +                   # ECHO IF -- argv[1], not
                                       # command position
    hilines('WHILE') +                # ECHO "WHILE" -- ditto,
                                       # quoted too
    # ---------------- Tier 2: positional params, shift --------
    hilines('SCRIPT') +               # $0
    hilines('ONE') +                  # $1
    hilines('TWO') +                  # $2
    hilines('THREE') +                # $3
    hilines('') +                     # $4 -- unset, empty line
    hilines('3') +                    # $#
    hilines('TWO') +                  # $1 after 1 shift
    hilines('2') +                    # $# after 1 shift
    hilines('THREE') +                # $1 after 2 shifts
    hilines('1') +                    # $# after 2 shifts
    hilines('0') +                    # $# after 3 shifts (none
                                       # left)
    hilines('SCRIPT') +               # $0 -- shift never
                                       # touched it
    hilines('SHSTAT1') +              # one shift too many --
                                       # loud failure, not a
                                       # silent no-op
    # ---------------- Tier 2: variables -------------------------
    hilines('BAR') +                  # $FOO after FOO=BAR
    hilines('BAZ') +                  # $FOO after FOO=BAZ --
                                       # overwrite, not a new slot
    hilines('') +                     # $UNSET -- empty, not an
                                       # error
    hilines('$FOO') +                 # '$FOO' -- literal
    hilines('BAZ') +                  # "$FOO" -- expands
    hilines('FOO=LITERAL') +          # ECHO FOO=LITERAL -- argv
                                       # [1], not command position
    # ---------------- Tier 3: `.` (source) ------------------------
    hilines('DOTVAL') +               # $FOO after `. DOTFILE` --
                                       # DOTFILE's own FOO=DOTVAL
                                       # is visible in THIS shell
    # ---------------- Tier 2: for/in/do/done ---------------------
    hilines('FORXA', 'FORXB', 'FORXC') +  # literal word list
    hilines('AFTERFORC') +            # loop var keeps its FINAL
    hilines('LClo1', 'LClo2') +       # lowercase loop variable
    hilines('CASElo2C') +             # x and X are DISTINCT names
    hilines('ASGNset') +              # lowercase assignment + $lv
                                       # value after the loop
    hilines('GLOBGFA.S', 'GLOBGFB.S', 'GLOBGFC.S') +
                                       # `for f in *.S`, sorted
    hilines('FORIFP', 'FORIFQ') +     # `for` containing an `if`
    hilines('FORBRKM') +              # `break` -- one iteration
                                       # of three
    hilines('AFTERFORBRK') +          # execution resumed past
                                       # DONE
    # ---------------- Tier 2: variable table full ----------------
    hilines('VARSTAT1') +             # V4 is the 9th distinct
                                       # name -- table (8) is full
    # ---------------- Tier 3: `:`, here-docs, `set -x` -----------
    hilines('CLNSTAT0') +             # `:` -- always succeeds,
                                       # extra args ignored
    hilines('PLAINLINE1', 'PLAINLINE2') +  # `<<` feeding `cat`
    hilines('TABBED LINE') +          # `<<-` -- leading tabs
                                       # stripped from the body
                                       # AND the terminator line
    hilines('HDLINE ONE', 'HDLINE TWO') +  # `<<` scripting `ed`
                                       # -- the motivating case
                                       # (HACKING.md's own example)
    hilines('HDLOOP', 'HDLOOP') +     # here-doc INSIDE a `while`
                                       # -- re-captured fresh on
                                       # EACH of the two
                                       # iterations (the loop's
                                       # own seek trick surviving
                                       # it, not just running once)
    hilines('IT1', 'IT2') +           # gate case (c): heredoc
                                       # INSIDE a loop, body reads
                                       # a variable the loop itself
                                       # reassigns -- each
                                       # iteration's OWN value, not
                                       # one value twice
    # ---------- typed lowercase, and with dots ----------------
    hilines('TDCAT') +                # `cd /mnt/MAUX/TDIR` in
                                       # lowercase, proved by a
                                       # RELATIVE `cat TDF1`
    hilines('TDCAT') +                # `cat ./TDF1`
    hilines('SAMETEXT') +             # `cat ../F1`
    hilines('DOTDIR') +               # `test -d .`
    hilines('DDDIR') +                # `test -d ..`
                                       # NOTADIR / DOTNOSUCH /
                                       # DOTISFILE are all ABSENT
                                       # -- the three controls
                                       # that make the two above
                                       # mean what they say
    hilines('DOTCTL') +               # ...and the anchor that
                                       # proves the controls ran
    hilines('SAMETEXT') +             # `cd ..` then `cat ./F1`
    hilines('SAMETEXT') +             # `cd /mnt/MAUX/TDIR/SUB; cd
                                       # ../..` (lands at the
                                       # volume root, one level
                                       # below the pseudo-root)
                                       # then the same
    hilines('LCIF') +                 # lowercase if/then/fi
    hilines('LCFORP') +               # lowercase for/in/do/break
                                       # (Q's absence is `break`'s
                                       # own assertion)
    hilines('LCSET0') +               # lowercase `set -x`/`set +x`
    hilines('cd') +                   # `echo cd` -- command
                                       # position still decides,
                                       # and the word is passed
                                       # through UNFOLDED
    # ---------------- background `&` and `wait` ---------------
    hilines('BG0') +                  # `cat NOSUCHF &` -- $? is 0
                                       # although cat exits 1
    hilines('WAITED0') +              # `wait` returns 0
    hilines(DIFFMSG) +                # ...and the child really
                                       # ran, to completion
    hilines('NOWAIT0') +              # `wait` with nothing
                                       # outstanding: a no-op
    hilines('SEQB') +                 # `A & B` ran B too...
    hilines('SEQA') +                 # ...and A, in background
    hilines('STILLAND') +             # `&&` is still `&&`
    hilines('WARG1') +                # `wait PID` refused loudly
    # -- background zombie vs foreground status (docs/SH-BG.md) --
    hilines('BGCTRL1') +              # control: nothing backgrounded
    hilines('BGCTRLW1') +             # control: backgrounded, then
                                      # explicitly `wait`ed first
    hilines('BGFGSTAT1') +            # a background zombie must not
                                      # answer for the foreground
                                      # child -- 1, not a stale 0
    hilines('BGNINEOK') +             # nine background jobs, past the
                                      # old false BGMAX of 8: `wait`
                                      # and the next `>>` still work
    # -- a `$( )` child is reaped BY PID (docs/SH-BG.md) --------
    hilines('SC:SAMETEXT: SQ0') +     # the capture is intact (a
                                      # control), and `$?` at the
                                      # substitution is the
                                      # SUBSTITUTION's own status --
                                      # not the outstanding `&`
                                      # job's 2
    hilines('SW2') +                  # ...and that job's real status
                                      # is still there to be waited
                                      # for: not consumed by the
                                      # substitution's reap. SW0 is
                                      # the defect, SW1 would be
                                      # `wait %1` failing to resolve
    hilines('SC2:SAMETEXT: SQ20') +   # control: the same
                                      # substitution with nothing
                                      # backgrounded
    # -- BACKSLASH QUOTING (docs/SHELL-GAPS.md sec 3), measured
    # -- against bash on the identical bare words, 2026-08-25.
    # -- FOO is IT2 by this point in the script.
    hilines('CTLIT2') +               # control: FOO is set and a
                                      # plain $FOO expands. Without
                                      # this an unset variable and a
                                      # suppressed expansion are the
                                      # same observation -- the first
                                      # draft used a fresh name, hit
                                      # the full 8-slot table, and
                                      # measured nothing.
    # -- WAS PINNED WRONG (xyV$FOO) until sec 3b landed 2026-08-25.
    # -- The pin flipped exactly as its note said it would: one
    # -- backslash used to force the whole token to quote level 1,
    # -- suppressing expansion and globbing for every OTHER character
    # -- in the word. Now only the escaped byte is marked.
    hilines('xyVIT2') +
    # -- CORRECT, and the reason 3a ("just use quote level 2") was
    # -- MEASURED AND REJECTED rather than landed: at level 2
    # -- expansion runs, so this becomes AIT2 -- an escaped '$'
    # -- silently expanding. Level 1 gets this right and the line
    # -- above wrong; level 2 gets the line above right and this
    # -- wrong. No constant can serve both, because TOKQUOTE is
    # -- per-TOKEN and backslash is per-CHARACTER. Only 3b fixes it.
    hilines('A$FOO') +
    hilines('P\\Q') +                 # escaped backslash
    hilines('R S') +                  # escaped space: ONE token,
                                      # matching bash's argc=1
    hilines('GFA.S GFB.S GFC.S') +    # (e) escaped letter still
                                      # matches, live '*' still
                                      # expands, sorted -- the
                                      # GFOLD normalisation proof
    hilines('A*B') +                  # (f) escaped '*' is not a
                                      # wildcard, and is not a
                                      # failed glob either
    # -- `case`/`esac`. Each ECHO named CASENO* is one that MUST
    # -- NOT run: their absence is the assertion, which a
    # -- byte-exact whole-file compare gives for free.
    hilines('CASE1') +                # (1) literal match
    hilines('CASEDEF') +              # (2) `*)` default
    hilines('CASEALT') +              # (3) alternation, middle
    hilines('CASEGLOB') +             # (4) glob + first wins
    hilines('CASEVAR') +              # (5) word expanded
    hilines('CASEAFTER') +            # (6) no match: shell
                                      # carries on
    hilines('CASENEST') +             # (7) nested inner branch
    hilines('CASEOUT') +              # outer branch survived
    hilines('CASETWO0') +             # (8) the `if` branch runs
    hilines('CASETWO1', 'CASETWO2') + # two commands in one
                                      # branch, inside an `if`
    hilines('CASEL1') +               # (9) SH-SEQ B: one line
    hilines('CASEL2') +               # (10) no match, one line
    hilines('CASEL3') +               # (11) second pattern hits
    hilines('CASEL4', 'CASEL5') +     # (12) two commands
    hilines('CASEL6', 'CASEL7') +     # (13) inside an `if`
                                      # wildcard, and is not a
                                      # failed glob either
                                      # matching bash's argc=1
    hilines('UNTSTAT1') +             # unterminated here-doc,
                                       # isolated inside a sourced
                                       # (`.`) file -- diagnostic +
                                       # nonzero $?, never a hang,
                                       # and the OUTER script still
                                       # resumes right after
    hilines('TRACEME') +              # `set -x` ... -- the trace
                                       # itself lands on SHERR, not
                                       # here (see check_shlang.py)
    hilines('NOTRACE')                # `set +x` -- tracing
                                       # stopped; this line's own
                                       # trace (if any) would also
                                       # be on SHERR, not here
)

# ===========================================================================
# SECOND, SEPARATE image (`build/shlang-hd.po`) -- this task's own gate
# cases (a)/(b)/`<<-'WORD'` and (d) (the etymology demo, docs/DEMOS.md sec
# 1). A SECOND boot, not more lines appended to SCRIPT_TEXT above: found the
# hard way, this project's `sh: cannot redirect` diagnostic (BLD_FDCTS_STG,
# sh.s) starts firing once the FIRST image's already-long script (40+ prior
# spawns, docs/SH-FEATURES.md sec 4's own "step" comment) picks up even ONE
# more here-doc-plus-outfile command -- MLI_IOBUF_CNT is only 4 io_buffers,
# SYSTEM-WIDE (inc/mm.mlibuf.equ's own "judgment call"), and this
# first image is ALREADY running close enough to that ceiling that adding
# these cases anywhere in it, in ANY position, reliably breaks something
# that was ALREADY passing (proven empirically -- moving the new lines
# around only moved WHICH existing case broke, never fixed it). Nothing
# sh.s-side is wrong; this is a real, pre-existing, OUT-OF-SCOPE kernel
# resource ceiling this task has no business widening. A fresh boot means a
# fresh kernel -- the SAME MAUXSHLANG.SYSTEM/kernel/carrier as the first
# image, just a different /mnt/MAUX/SCRIPT and its own small set of staged
# files, verified by its own reset+mount+run+verify pass in
# check_shlang.py, alongside (not instead of) the first image's.
# ===========================================================================

# ---------------------------------------------------------------------
# MGSCRIPT -- the etymology demo (docs/DEMOS.md sec 1, this task's own
# gate case (d)): `grep` implemented by feeding `ed` a here-doc whose
# PATTERN is a shell argument -- `g/$1/p`, unquoted, so it has to
# expand. Run under its own nested `sh` (`SH -s CAT /mnt/MAUX/MGFILE <
# /mnt/MAUX/MGSCRIPT`, below; -s is POSIX "commands from stdin" -- an
# operand otherwise names the script now, docs/EXEC-SHEBANG.md) so `$1`="CAT"/`$2`="/mnt/MAUX/MGFILE" are real,
# controlled values -- argv[0] of a spawned command line is always the
# literal first word ("SH"), so `$1` is the word AFTER it, not the
# first argument after the program name as it might look.
#
# MGFILE is the searched text: two lines contain "CAT" (selective on
# purpose, same shape F4/F5's own selectivity design uses), two do
# not. `ED $2` passes $2 as a real argv filename and LOADS it at
# launch, same as real `ed FILE` -- so `g/$1/p` finds MGFILE's
# contents straight off the initial buffer, no `r $2` needed. That is
# a CHANGE from an earlier draft of this script: `ed.s` used to ignore
# its filename argument entirely, and this script carried an explicit
# `r $2` line to load the buffer itself; once `ed.s` gained real
# argv-load, the two loads DOUBLED the buffer (`ED $2` loads it, then
# `r $2` appended a second copy), which doubled MGOUT and broke the
# CMP below against GREPOUT. Dropping `r $2` also means this case
# exercises the argv-load path, not just `r`. `$1`/`$2` still do all
# the same expansion work docs/DEMOS.md sec 1's own script is about.
# `grep` on the identical pattern/file (HDXSCRIPT_TEXT, below) is the
# independent check: CMP silent (MYGREPMATCH prints) iff the two
# outputs are byte-for-byte identical, not just "both non-empty".
# ---------------------------------------------------------------------
MGFILE_BYTES = hilines('CATFISH', 'DOGWOOD', 'CATNIP', 'BIRD')

# ---------------------------------------------------------------------
# TNL -- the command-substitution trailing-newline target
# (docs/SH-FEATURES.md sec 14). THREE trailing CRs, not one: a
# stripper that removes exactly one (or that only looks like it works
# because the result lands at the end of an output line anyway) gets
# caught. The gate wraps the capture in `T:` ... `:` so the removed
# bytes are observable in the MIDDLE of a line rather than at its end,
# where a stray CR would be invisible in the expectation.
# ---------------------------------------------------------------------
TNL_BYTES = hitext('TNLVAL') + CR + CR + CR

# ---------------------------------------------------------------------
# CDATA / CAPP -- compound redirection's own data files
# (docs/SH-FEATURES.md sec 18).
#
# CDATA is what `WHILE READ CL ; DO ... ; DONE < /mnt/MAUX/CDATA` reads.
# THREE lines, none a prefix of another: two lines cannot tell a fd
# that ADVANCES from one that alternates, and identical-length lines
# cannot tell a short read from a correct one. It is deliberately NOT
# MGFILE -- MGFILE is fd 0's neighbour in half a dozen other cases
# here, and a `read` that fell back to fd 0 would then be reading the
# script, whose next lines are `DO`/`ECHO`/`DONE` and would be visibly
# wrong rather than accidentally plausible.
#
# CAPP is staged with a line ALREADY IN IT so that `DONE >> CAPP`
# appending (rather than truncating) is observable: a construct
# redirect that dropped CMD_APPEND would erase CAPPBASE.
# ---------------------------------------------------------------------
CDATA_BYTES = hilines('LINEONE', 'SECOND LINE HERE', 'III')
# IFSDATA -- the IFS-aware `read` case's own input (RDCASES' IR case).
# ONE line, holding BOTH a `.` (the custom separator in force by then)
# and a space (a separator under the DEFAULT set and not under this
# one), so the line can only split one way per set and the two answers
# are visibly different.
IFSDATA_BYTES = hilines('P.Q R')
CAPP_BYTES = hilines('CAPPBASE')
MGSCRIPT_TEXT = (
    'ED $2 <<EOF > /mnt/MAUX/MGOUT\r'
    'g/$1/p\r'
    'q\r'
    'EOF\r'
    # Explicit `EXIT`, not left to implicit true-EOF-after-heredoc:
    # found the hard way, a heredoc capture immediately followed by
    # true EOF with NOTHING else in the file hung this fresh `sh`
    # rather than exiting cleanly -- a narrow, pre-existing edge case
    # (EOF detection right after CPTR_HEREDOC's own GETC-based body
    # read) that nothing before this task ever exercised, since every
    # other heredoc script in this project's gates has more lines
    # after its own terminator. Worth a follow-up, out of THIS task's
    # scope (sh.s's heredoc EXPANSION semantics) to chase further --
    # the explicit `EXIT` sidesteps it entirely and is good practice
    # regardless (every other script file in this gate already ends
    # this way).
    'EXIT\r'
)
MGSCRIPT_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                       for c in MGSCRIPT_TEXT)

# NESTSCRIPT -- the exact shape that FAILED at MLI_IOBUF_CNT=4 and is
# the reason it was raised to 6. Run as `SH < NESTSCRIPT > NESTOUT`,
# the concurrent opens are: the outer script fd + NESTSCRIPT +
# NESTOUT + the MGFILE this `cat` reads + the NESTF it writes = 5.
# (An earlier version of this case omitted NESTF and needed only 4 --
# it passed at MLI_IOBUF_CNT=4, i.e. for the wrong reason, and the
# sabotage run is what exposed that.) At 4 the
# symptom was `cat: cannot open /mnt/MAUX/MGFILE` on a file that plainly
# exists. This case exists so that regression cannot come back
# silently.
NESTSCRIPT_TEXT = (
    'CAT /mnt/MAUX/MGFILE > /mnt/MAUX/NESTF\r'
    'EXIT\r'
)
NESTSCRIPT_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                         for c in NESTSCRIPT_TEXT)

# DEEP1..DEEP4 -- the io_buffer LENDING case's nest (see the
# HDXSCRIPT_TEXT banner where it is invoked). Each level's ECHO runs
# AFTER its nested sh returns, i.e. after this script's own fd has
# been parked and reopened, so the line it lands on is the assertion.
#
# SIX levels, not four: the first cut (four levels) measured a pool
# high-water of exactly 8 and ZERO parks -- sh and cat were both warm
# respawns by then (no loader buffer) and one of the nine files in the
# hand count was not held where the count said. Two more levels put
# the shape at 10 held against 8, which parks at least two files, and
# the harness FAILS on a park count of 0 so this can never regress to
# "passes for the wrong reason" again.
DEEP_TEXTS = {
    'DEEP1': 'SH /mnt/MAUX/DEEP2\rECHO D1 >> /mnt/MAUX/RESULTS\rEXIT\r',
    'DEEP2': 'SH /mnt/MAUX/DEEP3\rECHO D2 >> /mnt/MAUX/RESULTS\rEXIT\r',
    'DEEP3': 'SH /mnt/MAUX/DEEP4\rECHO D3 >> /mnt/MAUX/RESULTS\rEXIT\r',
    'DEEP4': 'SH /mnt/MAUX/DEEP5\rECHO D4 >> /mnt/MAUX/RESULTS\rEXIT\r',
    'DEEP5': 'SH /mnt/MAUX/DEEP6\rECHO D5 >> /mnt/MAUX/RESULTS\rEXIT\r',
    'DEEP6': ('CAT < /mnt/MAUX/MGFILE > /mnt/MAUX/DEEPF\r'
              'ECHO D6:$? >> /mnt/MAUX/RESULTS\rEXIT\r'),
}
DEEP_BYTES = {k: bytes((ord(c) | 0x80) if c != '\r' else 0x8D for c in v)
              for k, v in DEEP_TEXTS.items()}

# OPS -- an operator-bearing $( ) run under a nested `sh` whose
# STDERR is captured. This case's job FLIPPED on 2026-08-27: it used
# to assert the `| < > ; &` refusal's exact diagnostic; now that a
# $( ) body goes to a nested sh and the operators WORK, it asserts
# the opposite -- that a non-interactive sh's stderr is BYTE-EMPTY.
# That is the script-form prompt-suppression gate (SH_INTERACT,
# sh.s): before SYS_FDSTAT, every sh prompted, and OPE came back
# holding "$ $ $ " -- the CMP against a staged empty file is what
# would catch that regression.
OPS_TEXT = (
    'ECHO $(CAT /mnt/MAUX/MGFILE | GREP CAT)\r'
    'EXIT\r'
)
OPS_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                  for c in OPS_TEXT)

# The `2>&1` ordering pair lives INLINE below rather than in a nested
# script, and the reason is a hard resource limit worth stating here.
#
# The obvious design -- run the pair under `SH < DUPSCRIPT > DUPOUT` so
# that "the old fd 1" in case B is a file we can read back -- DOES NOT
# FIT. MLI_IOBUF_CNT is 4 (inc/mm.mlibuf.equ) and the outer
# script fd + its `2>` capture + a nested sh's script fd + that sh's
# redirected stdout is ALREADY 4 before the command inside opens
# anything. Tried it: the symptom was `cat: cannot open /mnt/MAUX/MGFILE`
# on a file that plainly exists.
#
# A PIPE is the way out. Pipes are in-memory ring buffers governed by
# PIPE_COUNT and cost no io_buffer at all, so routing case B's stdout
# into one makes "the old fd 1" a readable destination for free.

# ---------------------------------------------------------------------
# HDXSCRIPT -- this task's own gate cases (a)/(b)/`<<-'WORD'`, plus the
# demo invocation. Runs as THIS image's own /mnt/MAUX/SCRIPT, in the SAME
# top-level `sh` shlangtestb.s's PARENT_PROC spawns with argv "SCRIPT"
# "ONE" "TWO" "THREE" (identical hardwired argv to the first image --
# same compiled MAUXSHLANG.SYSTEM) -- so $1="ONE" here, a real value,
# with no `shift` anywhere in this small script to consume it first.
#
# `<<WORD` (unquoted) expands `$1`/`$?`/`$VAR` in the body exactly
# like an ordinary word; `<<'WORD'` (quoted terminator) -- rejected by
# TOKENIZE before this task, now squeezed and flagged the same as any
# other quoted token -- leaves the IDENTICAL body text completely
# literal, proving the difference rather than assuming it. `$?` is 1
# (`test -f` on a file that does not exist); `$HDVAR` is this image's
# own first (and only) variable. `<<-'WORD'` proves quoting and
# `<<-`'s own tab-stripping COMPOSE -- tabs gone from body AND
# terminator line, `$1` still literal despite the dash.
# ---------------------------------------------------------------------
HDXSCRIPT_TEXT = (
    'HDVAR=HDVARVAL\r'
    'TEST -f /mnt/MAUX/NOPE\r'
    'CAT <<HDXEOF >> /mnt/MAUX/RESULTS\r'
    'P=$1 S=$? V=$HDVAR\r'
    'HDXEOF\r'
    "CAT <<'HDXEOF2' >> /mnt/MAUX/RESULTS\r"
    'P=$1 S=$? V=$HDVAR\r'
    'HDXEOF2\r'
    "CAT <<-'HDXEOF3' >> /mnt/MAUX/RESULTS\r"
    '\tP=$1 TABQUOTE\r'
    '\t\tHDXEOF3\r'
    'SH -s CAT /mnt/MAUX/MGFILE < /mnt/MAUX/MGSCRIPT\r'
    'GREP CAT /mnt/MAUX/MGFILE > /mnt/MAUX/GREPOUT\r'
    'CMP /mnt/MAUX/MGOUT /mnt/MAUX/GREPOUT && ECHO MYGREPMATCH >> /mnt/MAUX/RESULTS\r'
    # -----------------------------------------------------------
    # Command substitution, `$(COMMAND)` (docs/ANACHRONISMS.md
    # A10, docs/SH-FEATURES.md sec 14). These cases are APPENDED
    # -- deliberately after every pre-existing case above, so no
    # already-passing case changes position (build_shlang_image
    # .py's own OUT_IMG2 banner records why position matters on
    # this project).
    # -----------------------------------------------------------
    # Spliced INTO a word, not merely replacing one: `A` and `C`
    # are ordinary text either side of the substitution, so a
    # whole-token implementation would print `B` and fail here.
    'ECHO A$(ECHO B)C >> /mnt/MAUX/RESULTS\r'
    # A substituted command WITH ARGUMENTS, unquoted -- the space
    # inside `$( )` must not split the token (TOKENIZE's SUBDEPTH
    # span). Also the interior-newline half of the stripping rule:
    # grep emits TWO lines, so the CR BETWEEN them must survive
    # while the one after the last is removed.
    'ECHO $(GREP CAT /mnt/MAUX/MGFILE) >> /mnt/MAUX/RESULTS\r'
    # Trailing newlines: TNL ends in THREE CRs, and the `T:`/`:`
    # bracket makes their removal observable mid-line.
    'ECHO T:$(CAT /mnt/MAUX/TNL): >> /mnt/MAUX/RESULTS\r'
    # `VAR=$(cmd)` -- the assignment form.
    'CSV=$(ECHO CAPVAL)\r'
    'ECHO V:$CSV >> /mnt/MAUX/RESULTS\r'
    # Inside a DOUBLE-quoted word: substitution runs.
    'ECHO "Q:$(ECHO DQVAL)" >> /mnt/MAUX/RESULTS\r'
    # Inside a SINGLE-quoted word: it must NOT. Same text as the
    # line above's inner command, so the pair proves the
    # difference rather than asserting it.
    "ECHO '$(ECHO NOPE)' >> /mnt/MAUX/RESULTS\r"
    # A command that matches nothing: EMPTY capture, not an
    # error and not a stray byte -- `N::` is the proof.
    'NOTHING=$(GREP ZZZZ /mnt/MAUX/MGFILE)\r'
    'ECHO N:$NOTHING: >> /mnt/MAUX/RESULTS\r'
    # An UNQUOTED here-doc body expands it (the body is expanded
    # like an ordinary word) ...
    'CAT <<SUBEOF >> /mnt/MAUX/RESULTS\r'
    'S=$(ECHO HDSUB)\r'
    'SUBEOF\r'
    # ... and a `<<'WORD'` body does not, on the IDENTICAL text.
    "CAT <<'SUBEOF2' >> /mnt/MAUX/RESULTS\r"
    'S=$(ECHO HDSUB)\r'
    'SUBEOF2\r'
    # ---- POSIX semantics: the body is the SUBSHELL's, not ours ----
    # docs/SHELL-GAPS.md sec 2's divergence table, all three rows,
    # in the SCRIPT form (check-play types the same three). Until
    # 2026-08-27 WORDEXPAND expanded through the parentheses, so
    # the parent evaluated the body and every one of these was
    # wrong in a different way.
    # CSV, NOT a new name: MAXVARS is 8 and this image is at its
    # budget (see RDCASES's own note below). Spending one more slot
    # made `READ A B C`'s THIRD variable fail to allocate -- VARSET
    # returns carry-set on a full table and the `read` builtin drops
    # it SILENTLY, so R2/R7 lost their remainders while every other
    # case stayed green. CSV's own assertion (V:CAPVAL) is long past
    # by here, and re-assignment overwriting rather than allocating
    # is what VARSET promises.
    'CSV=one\r'
    # An UNEXPORTED variable still reaches the subshell -- now
    # because the parent SERIALISES it ahead of the body, not
    # because it was pre-substituted.
    'ECHO PA:$(ECHO $CSV) >> /mnt/MAUX/RESULTS\r'
    # A body that SETS a variable sees its OWN value (bash: 2).
    # Impossible under pre-expansion, which had already replaced
    # $V with the parent's value before the child existed.
    'ECHO PB:$(CSV=2 ; ECHO $CSV) >> /mnt/MAUX/RESULTS\r'
    # ...and the subshell's assignment does NOT leak back.
    'ECHO PC:$CSV >> /mnt/MAUX/RESULTS\r'
    # Quotes inside the body belong to the subshell (bash: $PV).
    "ECHO PD:$(ECHO '$CSV') >> /mnt/MAUX/RESULTS\r"
    # `$*` and `$@` -- every positional parameter, space-separated.
    # V7 treats the two IDENTICALLY (the `"$@"` word-preserving
    # split is later), so asserting both against the SAME expected
    # text is the faithful check, not a lazy one. `$#` is asserted
    # beside them because EMITSTAR derives its count the same way
    # EMITHASH does, and the two must not be able to disagree.
    'ECHO SA:$* >> /mnt/MAUX/RESULTS\r'
    'ECHO SB:$@ >> /mnt/MAUX/RESULTS\r'
    'ECHO SC:$# >> /mnt/MAUX/RESULTS\r'
    # ---- `( commands )`, the grouping construct, in a SCRIPT ----
    # The typed form is check-play's; this is the same construct fed
    # from a file, which is the form a script uses.
    # The redirects here are INSIDE the group. A redirect ON the
    # group is exercised two lines down and, since 2026-08-27, is
    # HONOURED: SUB_GROUP stages it through the same STG_OUTFILE /
    # EMIT_DUPS routines an ordinary command uses. It used to be
    # refused, and this gate is what locked that refusal down -- it
    # went red the moment the gap closed, which is the whole point
    # of pinning a limitation rather than only documenting it.
    '( ECHO GA >> /mnt/MAUX/RESULTS ; ECHO GB >> /mnt/MAUX/RESULTS )\r'
    'ECHO GS$? >> /mnt/MAUX/RESULTS\r'
    '( ECHO GX ) >> /mnt/MAUX/RESULTS\r'
    'ECHO GR$? >> /mnt/MAUX/RESULTS\r'
    # KFIX3 item 1: the PAIR on a group. `( ... ) > A 2> B` kept only
    # the last of the two (one slot per stage); both are staged now.
    'ECHO RGF > /mnt/MAUX/RGF\r'
    '( CAT /mnt/MAUX/RGF /mnt/MAUX/RGNO ) > /mnt/MAUX/RGA '
    '2> /mnt/MAUX/RGB\r'
    'CAT /mnt/MAUX/RGA >> /mnt/MAUX/RESULTS\r'
    'CAT /mnt/MAUX/RGB >> /mnt/MAUX/RESULTS\r'
    # KFIX3 item 4: the first word of a subshell is in command
    # position, so an alias there expands -- `(pl1)`, `(pl1;pl1)` and
    # the parenthesis glued to the word on either side. The QUOTED
    # copy stays a word, and the spaced form (which always worked) is
    # the control. The expansion happens in THIS shell's alias pass,
    # on the line, before the group's text reaches its child.
    "alias pl1='ECHO PL1'\r"
    '(pl1) >> /mnt/MAUX/RESULTS\r'
    '(pl1;pl1) >> /mnt/MAUX/RESULTS\r'
    '( pl1 ) >> /mnt/MAUX/RESULTS\r'
    # review F8: a DOUBLED parenthesis is two words, not the `((`
    # pair the doubled-operator rule kept whole
    '((pl1);pl1) >> /mnt/MAUX/RESULTS\r'
    "ECHO '(pl1)' >> /mnt/MAUX/RESULTS\r"
    'unalias pl1\r'
    # `( ... ) &` BACKGROUNDS the group. `&` is a separator PARSE
    # records in PARSE_SEPOP, and RUN_PIPELINE used to be the only
    # reader -- so a group ignored it SILENTLY and ran in the
    # foreground (measured 2026-08-27: `( SLEEP 3 ; ... ) &` held
    # the prompt three seconds). Asserting ORDER is what makes
    # this test background rather than "it ran": GBGA is written
    # by a group that sleeps first, GBGB by the NEXT line, so a
    # FOREGROUND group puts GBGA before GBGB and a backgrounded
    # one puts GBGB first. `wait` then reaps it, which is also the
    # assertion that the pid reached BG_PIDS at all.
    # The group writes its OWN file, NOT RESULTS: the first draft
    # had both the group and the next line appending to RESULTS
    # concurrently, and the parent's open took a stale EOF and
    # wrote OVER the group's line -- GBGA vanished entirely. Two
    # processes appending to one ProDOS file have independent
    # marks; that is a real hazard, and a test must not create it
    # to measure something else.
    #
    # The discriminator is "did `&` background it": `$!` is the pid
    # of the last background job and 0 when there was none, so
    # `TEST "$!" = 0` is TRUE (status 0, GBGP0) for a group that ran
    # in the foreground -- the pre-2026-08-27 behaviour, `&` silently
    # ignored -- and FALSE (status 1, GBGP1) for a backgrounded one.
    #
    # It used to be "probe the group's output file BEFORE waiting:
    # `CAT GBGF` must FAIL because the group is still in SLEEP". This
    # image has no sleep binary, so the group ran at once and the
    # probe only passed because cat's open of a file the group was
    # still holding for write was refused ($50) -- a RACE that
    # OPEN-RW-2 (2026-10-22) turned red, because cat now declares
    # read intent and JOINS a file one writer holds (it reads the
    # half-written file, status 0: Unix behaviour). Found by the box
    # sweep (RESULTS line 35 GBGP0, expected GBGP1); a probe whose
    # answer depends on which side of an open() the child is on
    # proves nothing about backgrounding.
    '( SLEEP 2 ; ECHO GBGA > /mnt/MAUX/GBGF ) &\r'
    'TEST "$!" = 0\r'
    'ECHO GBGP$? >> /mnt/MAUX/RESULTS\r'
    'WAIT\r'
    'CAT /mnt/MAUX/GBGF >> /mnt/MAUX/RESULTS\r'
    # NESTED groups run, inner first (review 2026-08-27: the
    # outer span used to close at the inner `)`, truncating the body
    # AND running the tail in the parent).
    '( ( ECHO GNA >> /mnt/MAUX/RESULTS ) ; ECHO GNB >> /mnt/MAUX/RESULTS )\r'
    # A group inside a FALSE branch must NOT run. CHCK_GROUP sits
    # below both skip gates (SH_SKIP and CS_EFFSKIP) in MAINLOOP's
    # dispatch chain; placed above them it would run its body here
    # and every other case would still pass. The absence of GSKIP
    # from RESULTS IS the assertion, so the line after it reads
    # something back to prove the script kept going.
    'IF TEST -f /mnt/MAUX/NOPE ; THEN ( ECHO GSKIP >> /mnt/MAUX/RESULTS ) ; FI\r'
    'ECHO GKON >> /mnt/MAUX/RESULTS\r'
    # The group READS a parent variable it does not set (sabotage
    # found that a body setting its own value proves nothing about
    # where the value came from), then SHADOWS it without leaking.
    'ECHO GC:$(ECHO $CSV) >> /mnt/MAUX/RESULTS\r'
    'ECHO GD:$CSV >> /mnt/MAUX/RESULTS\r'
    # NESTING is refused LOUDLY (v1, sh.s SUB_GRAB): diagnostic
    # to fd 2, nonzero $?, and the whole line abandoned -- so
    # nothing at all reaches RESULTS from the line itself, and
    # the NEXT line reads the status back.
    'ECHO $(ECHO $(ECHO X)) >> /mnt/MAUX/RESULTS\r'
    'ECHO NST$? >> /mnt/MAUX/RESULTS\r'
    # A `$(` with no closing `)` -- same treatment, different
    # detection path (ran off the end of the word rather than
    # meeting a second `(`).
    'ECHO $(ECHO X >> /mnt/MAUX/RESULTS\r'
    'ECHO UNC$? >> /mnt/MAUX/RESULTS\r'
    # A shell OPERATOR inside `$( )` -- WORKS since 2026-08-27: the
    # body goes to a nested sh, which is a whole shell, so `|` means
    # what it says. (It used to be refused loudly, and before that a
    # `|` reached the single spawned child as a literal argument.)
    # The interior CR between the two matched lines must survive
    # while the trailing one is stripped -- same rule the plain GREP
    # case above already proves without an operator.
    'ECHO $(CAT /mnt/MAUX/MGFILE | GREP CAT) >> /mnt/MAUX/RESULTS\r'
    'ECHO OPP$? >> /mnt/MAUX/RESULTS\r'
    # A nested NON-INTERACTIVE sh (fd 0 = a file) must keep its
    # stderr BYTE-EMPTY: no prompts (SH_INTERACT), no diagnostics.
    # CMP against a staged zero-length file has teeth a grep does
    # not -- ONE stray byte in OPE flips OPM.
    'SH < /mnt/MAUX/OPS 2> /mnt/MAUX/OPE\r'
    'CMP /mnt/MAUX/OPE /mnt/MAUX/EMPTYF\r'
    'ECHO OPM$? >> /mnt/MAUX/RESULTS\r'
    # `echo` as a builtin -- compared BYTE-FOR-BYTE against the
    # external binary it replaces, because two implementations of
    # one command is exactly how they drift. `/bin/ECHO` does not
    # match the builtin's argv[0] test, so it runs the real binary:
    # the same line, twice, one each way.
    # The external binary is reached through the PIPELINE fall-
    # through, not by an absolute path: sh resolves argv[0] against
    # PATHTAB unconditionally (BUILD_PATH), so `/bin/ECHO` becomes
    # `/bin//bin/ECHO` and is not found. That also makes this
    # case a direct test of the fall-through itself.
    # BUILTIN vs EXTERNAL, byte-for-byte. The builtin only ever
    # writes to fd 1 or to an enclosing construct's redirect (a
    # command's own `>` falls through), so the construct form is
    # how its output is captured -- which makes this a test of the
    # CR_FIND path too. The external side is reached through the
    # pipeline fall-through.
    'IF TEST -f /mnt/MAUX/MGFILE ; THEN ECHO A B C ; FI > /mnt/MAUX/EB\r'
    'ECHO A B C | CAT > /mnt/MAUX/EX\r'
    'CMP /mnt/MAUX/EB /mnt/MAUX/EX\r'
    'ECHO EC$? >> /mnt/MAUX/RESULTS\r'
    # A bare ECHO prints just the CR -- the edge case most likely
    # to differ, and invisible in any case that passes arguments.
    'IF TEST -f /mnt/MAUX/MGFILE ; THEN ECHO ; FI > /mnt/MAUX/EB\r'
    'ECHO | CAT > /mnt/MAUX/EX\r'
    'CMP /mnt/MAUX/EB /mnt/MAUX/EX\r'
    'ECHO EN$? >> /mnt/MAUX/RESULTS\r'
    # A PIPELINE still falls through to the external binary and
    # still works -- the fall-through is the safety property.
    'ECHO PIPED | CAT >> /mnt/MAUX/RESULTS\r'
    # REGRESSION, and the reason this line is here rather than
    # in some other gate: TWO expanding words on ONE line. Every
    # pre-existing case in this tree had exactly one, which is
    # why EXP_FINISH's off-by-one (EXPCUR published as the index
    # OF the terminator, so the next word's slice overwrote it)
    # survived undetected -- `ECHO $1 $2` printed `ONETWO TWO`.
    # sh's argv here is "SCRIPT" "ONE" "TWO" "THREE".
    'ECHO $1 $2 >> /mnt/MAUX/RESULTS\r'
    # CASE A -- `> D1 2>&1`: fd 1 moves to the file FIRST, then fd 2
    # is duped from it, so BOTH streams land in D1. `cat` is the
    # producer because it writes the failing name to fd 2 and CARRIES
    # ON to the next file, so one command emits on both streams.
    'CAT /mnt/MAUX/NOSUCH /mnt/MAUX/MGFILE > /mnt/MAUX/D1 2>&1\r'
    # CASE B -- `2>&1 > D2`: the SAME two redirections, opposite
    # order. fd 2 is duped from fd 1 while fd 1 is still the PIPE, and
    # only then does fd 1 move to the file. So the diagnostic must
    # come out of the pipe into DUPOUT, and must NOT be in D2.
    # Split across two commands, NOT because the semantics need it
    # but because one command doing both needs 4 io_buffers (script +
    # SHERR + D2 + DUPOUT) and that is the whole budget -- D2's
    # creation silently failed. Each line below needs 3.
    #
    # B-a is the ordering assertion proper: if `> D2` were applied
    # before the dup, the diagnostic WOULD be in D2.
    'CAT /mnt/MAUX/NOSUCH 2>&1 > /mnt/MAUX/D2\r'
    # B-b is the positive half: with no file redirect to move fd 1,
    # `2>&1` must put the diagnostic wherever fd 1 already points --
    # here a pipe, which costs no io_buffer.
    'CAT /mnt/MAUX/NOSUCH 2>&1 | CAT > /mnt/MAUX/DUPOUT\r'
    # Assertions go through GREP and $? rather than a byte-exact
    # compare ON PURPOSE: fd 1 is BUFFERED and fd 2 is not, so the
    # INTERLEAVING of data and diagnostic inside D1 is a flush-order
    # detail this gate has no business pinning down. WHICH STREAM
    # REACHED WHICH FILE survives any interleaving.
    # Five concurrent io_buffers -- impossible before the raise.
    'SH < /mnt/MAUX/NESTSCRIPT > /mnt/MAUX/NESTOUT\r'
    'GREP CATFISH /mnt/MAUX/NESTF > /mnt/MAUX/NUL\r'
    'ECHO NB$? >> /mnt/MAUX/RESULTS\r'
    # ===========================================================
    # COMPOUND REDIRECTION -- a redirect applied to a CONSTRUCT
    # (docs/SH-FEATURES.md sec 18).
    #
    # TWO SPELLING TRAPS, both already paid for once:
    #
    # 1. `-f` is LOWERCASE. `test` spells its flags lowercase
    #    (src/bin/testeval.s S_DASHF); `-F` is a USAGE ERROR
    #    returning 2, so the condition is never true and the body
    #    never runs -- a case that passes for the wrong reason.
    #
    # 2. `;` MUST BE SPACED. TOKENIZE splits on whitespace only,
    #    so `MGFILE;` is one ordinary word, not a word plus a
    #    separator. The version of this very case that shipped as
    #    the sec 17 `CR2` limitation was spelled
    #    `... /mnt/MAUX/MGFILE; THEN ECHO INSIDE; FI > /mnt/MAUX/CRT`
    #    and was therefore ONE segment whose argv, after `IF` is
    #    shifted off, is `TEST -f /mnt/MAUX/MGFILE; THEN ECHO
    #    INSIDE; FI`. `test` returned its usage error 2, no `FI`
    #    terminator segment ever existed, and the case measured
    #    nothing about compound redirection at all. That is where
    #    sec 17's "a plain IF ... FI line returns $? = 2,
    #    pre-existing and unexplained" came from too.
    #
    # The body is ECHO, deliberately not CAT: a `cat` with no
    # argument reads fd 0, which -- if a redirect were NOT applied
    # -- is this script, and it would swallow the rest of it.
    #
    # CR: `FI > FILE`. Was CR2 (the sec 17 limitation, locked
    # deliberately so implementing this would force the update);
    # it is CR0 now.
    'IF TEST -f /mnt/MAUX/MGFILE ; THEN ECHO INSIDE ; FI > /mnt/MAUX/CRT\r'
    'GREP INSIDE /mnt/MAUX/CRT > /mnt/MAUX/NUL\r'
    'ECHO CR$? >> /mnt/MAUX/RESULTS\r'
    # CC: the CONTROL -- the identical redirect on a SIMPLE
    # command, same position and same io_buffer budget. Without
    # it, CR could not distinguish "the compound works" from
    # "everything here works".
    'ECHO INSIDE > /mnt/MAUX/CRT2\r'
    'GREP INSIDE /mnt/MAUX/CRT2 > /mnt/MAUX/NUL\r'
    'ECHO CC$? >> /mnt/MAUX/RESULTS\r'
    # RL: THE MOTIVATING IDIOM (sec 16.7's "what `read` is not
    # usable for yet"). `read` must take its lines from CDATA,
    # NOT from fd 0 -- which is this script -- and the assertion
    # is the CONTENT it read, in order, not merely that the loop
    # ran. Three lines, deliberately: two would not distinguish
    # "advances" from "alternates", and the third line's text is
    # not a prefix of the others.
    'WHILE READ CL\r'
    'DO\r'
    'ECHO RL:$CL >> /mnt/MAUX/RESULTS\r'
    'DONE < /mnt/MAUX/CDATA\r'
    # CS/CN: a redirect on a construct whose condition is FALSE.
    # Real sh still applies it -- the file is created (CS0) and
    # left EMPTY (CN1: grep opened it and matched nothing, which
    # is status 1; status 2 would mean it could not open it at
    # all). This is the case that proves the redirect is
    # established on ENTRY rather than by the body running.
    'IF TEST -f /mnt/MAUX/NOSUCH ; THEN ECHO NEVER ; FI > /mnt/MAUX/CSKIP\r'
    'TEST -f /mnt/MAUX/CSKIP\r'
    'ECHO CS$? >> /mnt/MAUX/RESULTS\r'
    'GREP NEVER /mnt/MAUX/CSKIP > /mnt/MAUX/NUL\r'
    'ECHO CN$? >> /mnt/MAUX/RESULTS\r'
    # F:/CAPP -- a FOR loop, and `>>` rather than `>`. Two axes
    # no other case here varies: the construct TYPE (the third of
    # three), and APPEND vs truncate. CAPP is staged with a line
    # already in it, so a construct redirect that silently
    # dropped CMD_APPEND would erase it and be visible.
    #
    # The loop variable is CL -- the SAME scratch name the
    # `WHILE READ CL` case above uses, not a `CW` of its own, and
    # that is now load-bearing rather than tidy. MAXVARS is 8;
    # this image's script creates HDVAR, CSV, NOTHING and CL,
    # RDCASES adds A/B/C, and `IFS` -- a shell variable like any
    # other since 2026-08-28 -- needs the eighth. With a separate
    # CW the table is FULL at the IFS cases and `IFS=.` fails
    # LOUDLY (status 1, measured), which is the right behaviour
    # from a full table and the wrong shape for a gate. Reuse is
    # what RDCASES' own banner already prescribes.
    'FOR CL IN ONE TWO\r'
    'DO\r'
    'ECHO F:$CL\r'
    'DONE >> /mnt/MAUX/CAPP\r'
    'CAT /mnt/MAUX/CAPP >> /mnt/MAUX/RESULTS\r'
    # NESTING, and INNERMOST WINS. The outer WHILE sends its body
    # to COUTER; the inner IF, three lines in, sends ITS body to
    # CINNER. OUTER and OUTER2 must be in COUTER and INNER must
    # NOT be -- an implementation that kept only one construct
    # redirect, or that let the outer one win, fails on exactly
    # that. `BREAK` ends the loop after one pass and also
    # exercises closing a construct fd on an unwind.
    'WHILE TEST -f /mnt/MAUX/MGFILE\r'
    'DO\r'
    'ECHO OUTER\r'
    'IF TEST -f /mnt/MAUX/MGFILE\r'
    'THEN\r'
    'ECHO INNER\r'
    'FI > /mnt/MAUX/CINNER\r'
    'ECHO OUTER2\r'
    'BREAK\r'
    'DONE > /mnt/MAUX/COUTER\r'
    'CAT /mnt/MAUX/COUTER >> /mnt/MAUX/RESULTS\r'
    'CAT /mnt/MAUX/CINNER >> /mnt/MAUX/RESULTS\r'
    # CD: `FI 2> FILE` -- the TARGET fd, which every case above
    # leaves at the default. `cat` is the producer because it
    # writes the failing name to fd 2; it is given an ARGUMENT so
    # it never reads fd 0.
    'IF TEST -f /mnt/MAUX/MGFILE\r'
    'THEN\r'
    'CAT /mnt/MAUX/NOSUCH\r'
    'FI 2> /mnt/MAUX/CERR\r'
    'GREP cannot /mnt/MAUX/CERR > /mnt/MAUX/NUL\r'
    'ECHO CD$? >> /mnt/MAUX/RESULTS\r'
    # CP: the body is a PIPELINE, not a simple command. A
    # construct's `>` catches the LAST stage, the same way a
    # simple command's own `>` does -- so CPIPE holds grep's
    # output, not cat's.
    'WHILE TEST -f /mnt/MAUX/MGFILE\r'
    'DO\r'
    'CAT /mnt/MAUX/MGFILE | GREP CATFISH\r'
    'BREAK\r'
    'DONE > /mnt/MAUX/CPIPE\r'
    'CAT /mnt/MAUX/CPIPE >> /mnt/MAUX/RESULTS\r'
    # CM: the DOCUMENTED LIMIT, locked so it cannot be widened by
    # accident. A construct opened as a LATER segment of its line
    # is not scanned (sh.s CR_STARTSCAN/SEG_FIRST) -- the rewind
    # seeks to the start of the LINE, and replaying `ECHO PRE`
    # would be worse than refusing. So the redirect stays
    # orphaned: refused loudly (CM1), and CMID is never created.
    'ECHO PRE >> /mnt/MAUX/RESULTS ; IF TEST -f /mnt/MAUX/MGFILE ; '
    'THEN ECHO MID >> /mnt/MAUX/RESULTS ; FI > /mnt/MAUX/CMID\r'
    'ECHO CM$? >> /mnt/MAUX/RESULTS\r'
    'TEST -f /mnt/MAUX/CMID\r'
    'ECHO CX$? >> /mnt/MAUX/RESULTS\r'
    # CE: a redirect with NO command word at all -- no construct
    # anywhere in sight. Still refused loudly (sec 17), and this
    # is what keeps the sec 18 work from having quietly turned
    # CK_ORPHRDIR off.
    '< /mnt/MAUX/MGFILE\r'
    'ECHO CE$? >> /mnt/MAUX/RESULTS\r'
    # A syntax error must SET $?, not leave the previous command's.
    'ECHO ONE\r'
    'ECHO A | CAT | CAT | CAT | CAT > /mnt/MAUX/NUL\r'
    'ECHO SY$? >> /mnt/MAUX/RESULTS\r'
    'GREP cannot /mnt/MAUX/D1 > /mnt/MAUX/NUL\r'
    'ECHO A1$? >> /mnt/MAUX/RESULTS\r'
    'GREP CATFISH /mnt/MAUX/D1 > /mnt/MAUX/NUL\r'
    'ECHO A2$? >> /mnt/MAUX/RESULTS\r'
    'GREP cannot /mnt/MAUX/D2 > /mnt/MAUX/NUL\r'
    'ECHO B1$? >> /mnt/MAUX/RESULTS\r'
    'GREP cannot /mnt/MAUX/DUPOUT > /mnt/MAUX/NUL\r'
    'ECHO B3$? >> /mnt/MAUX/RESULTS\r'
    # -----------------------------------------------------------
    # `read` (docs/SH-FEATURES.md sec 16). THE WHOLE POINT OF THIS
    # SHAPE: `.` sources RDCASES, so from here on the shell reads
    # its SCRIPT from the RDCASES fd (CUR_IN_FD) while fd 0 is
    # still THIS file. Every `READ` in RDCASES therefore consumes
    # one of the DATA lines below, and the two streams advance
    # independently. That separation is the assertion an
    # implementation that reached for CUR_IN_FD instead of
    # FD_STDIN could not survive: it would eat RDCASES' own next
    # command line and every result below would shift.
    #
    # There is deliberately NO trailing `EXIT` on this file. The
    # data lines must be the LAST bytes in it, so that once they
    # run out fd 0 is genuinely at EOF -- which is what the
    # `WHILE READ` loop terminates on and what the final `READ`
    # ===========================================================
    # io_buffer LENDING (docs/IOBUF-LENDING.md, 2026-09-07). The
    # deepest open-file shape this tree has ever run, on purpose:
    # `SH < DEEP1 > DEEPOUT 2> DEEPERR`, DEEP1 runs `SH DEEP2`
    # (SCRIPTFILE mode), and so on down to DEEP6, which runs
    # `CAT < MGFILE > DEEPF`. Held open at the moment `cat` runs:
    # this SCRIPT, DEEP1, DEEPOUT, DEEPERR, DEEP2..DEEP6, MGFILE
    # and DEEPF -- TEN by the hand count (MEASURED: the four-level
    # cut peaked at exactly 8 with no parks, see DEEP_TEXTS) --
    # against a pool of EIGHT that is ProDOS 8's hard ceiling.
    # Only lending makes this work.
    # THE TEETH: every nested sh's script fd is a lending victim
    # while `cat` runs, and each must resume at exactly the line
    # after the one it was parked on -- D6:0/D5/../D1 in RESULTS
    # in that order is the saved-mark restore proving itself.
    # DEEPERR byte-empty = no `sh: cannot ...` anywhere. And the
    # harness fails outright if K_PARK_CNT reads 0 afterwards.
    'SH < /mnt/MAUX/DEEP1 > /mnt/MAUX/DEEPOUT 2> /mnt/MAUX/DEEPERR\r'
    'GREP CATFISH /mnt/MAUX/DEEPF > /mnt/MAUX/NUL\r'
    'ECHO DP$? >> /mnt/MAUX/RESULTS\r'
    'CMP /mnt/MAUX/DEEPERR /mnt/MAUX/EMPTYF && ECHO DEEPQUIET >> /mnt/MAUX/RESULTS\r'
    '. /mnt/MAUX/RDCASES\r'
    # R1: one word, one variable.
    'ALPHA\r'
    # R2: THE splitting case -- three variables, five words, so
    # the LAST one has to absorb "THREE AND FOUR" spaces and all.
    'ONE TWO THREE AND FOUR\r'
    # R3: leading whitespace (tab AND spaces), a TAB as the
    # separator, an interior run of spaces that must SURVIVE
    # inside the last variable, and trailing spaces that must not.
    '\t  LEAD\tMID   TRAIL  \r'
    # R5: FEWER words than variables -- the surplus goes empty.
    'SOLO\r'
    # R6: an EMPTY line. This is data, NOT end-of-file: status 0,
    # variable set to "". Conflating the two is the classic `read`
    # bug and no other case here can see it.
    '\r'
    # R7: a data line that LOOKS like a command, aimed at the very
    # file the assertions are appended to. If any of it were ever
    # executed rather than read, `WRONGLY` would appear in RESULTS
    # on its own line and the byte-exact compare would catch it.
    'ECHO WRONGLY >> /mnt/MAUX/RESULTS\r'
    # R9: the `WHILE READ A` loop's two iterations, then EOF.
    'L1\r'
    'L2\r'
)
HDXSCRIPT_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                        for c in HDXSCRIPT_TEXT)

# ---------------------------------------------------------------------
# RDCASES -- the `read` gate's own script, `.`-sourced by HDXSCRIPT
# above so that the shell's script fd and its fd 0 are DIFFERENT open
# files. Assertions are ordinary `ECHO ... >> /mnt/MAUX/RESULTS` lines, so
# the deepest shape here is script fd + this fd + RESULTS + the spawn
# loader = 4 io_buffers, the same ceiling every other case in this image
# already runs at (MLI_IOBUF_CNT, docs/SH-FEATURES.md sec 15 Finding 1).
# Nothing here opens a fifth.
#
# Only A/B/C are used, reused across cases: MAXVARS is 8 and this image
# already spends HDVAR/CSV/NOTHING, so three new names leaves two slots
# spare. Reuse is not a compromise -- re-assignment overwriting rather
# than allocating is itself the behaviour VARSET promises.
# ---------------------------------------------------------------------
RDCASES_TEXT = (
    # R0: no arguments at all -- usage error, nonzero status, and
    # CRUCIALLY no line consumed. Nothing asserts that directly; R1
    # reading ALPHA (rather than the line after it) is what proves it,
    # and every case after R1 depends on the same alignment.
    'READ\r'
    'ECHO R0:$? >> /mnt/MAUX/RESULTS\r'
    # R0B: a name that cannot start a variable. Same no-line-consumed
    # property, through the OTHER refusal path -- and this one is
    # checked BEFORE the read for exactly that reason (sh.s :nameck).
    'READ 9BAD\r'
    'ECHO R0B:$? >> /mnt/MAUX/RESULTS\r'
    'READ A\r'
    'ECHO R1:$A >> /mnt/MAUX/RESULTS\r'
    'READ A B C\r'
    'ECHO R2:$A:$B:$C >> /mnt/MAUX/RESULTS\r'
    'READ A B\r'
    'ECHO R3:$A:$B: >> /mnt/MAUX/RESULTS\r'
    'READ A B\r'
    'ECHO R5:$A:$B: >> /mnt/MAUX/RESULTS\r'
    'READ A\r'
    'ECHO R6:$?:$A: >> /mnt/MAUX/RESULTS\r'
    'READ A B C\r'
    'ECHO R7:$A:$B:$C >> /mnt/MAUX/RESULTS\r'
    # R8: `read VAR < FILE` is REFUSED, loudly and without reading
    # anything -- builtins dispatch before RUN_PIPELINE applies
    # redirection, so the `<` could never have taken effect and
    # silently reading fd 0 instead would be a quiet wrong answer.
    # A is pre-set so "untouched" is observable, not merely absent,
    # and the refusal consuming no line is proven by R9 below still
    # finding L1.
    'A=KEEPA\r'
    'READ A < /mnt/MAUX/MGFILE\r'
    'ECHO R8:$?:$A: >> /mnt/MAUX/RESULTS\r'
    # R9: `read` as a loop CONDITION, which is what it is FOR. This
    # is not the `DONE < FILE` shape (out of scope, sec 15 Finding
    # 2): fd 0 is already the data stream, so no redirection is
    # applied to a compound at all. The loop head is seeked on
    # CUR_IN_FD each pass while fd 0 advances monotonically -- two
    # iterations, then the read at EOF ends it.
    'WHILE READ A\r'
    'DO\r'
    'ECHO R9:$A >> /mnt/MAUX/RESULTS\r'
    'DONE\r'
    # R4: EOF returns nonzero AND leaves the variable alone. B is
    # set immediately before, so a `read` that wrote an empty string
    # (or a partial one) on EOF would be visible rather than merely
    # suspected. Both halves are one contract: a loop that stops on
    # the status must not also have to defend against a stale write.
    'B=KEEPME\r'
    'READ B\r'
    'ECHO R4:$?:$B: >> /mnt/MAUX/RESULTS\r'
    # Command-position rule, same as `ECHO TEST`/`ECHO IF` above:
    # READ as argv[1] is a literal word, not the builtin.
    'ECHO READ >> /mnt/MAUX/RESULTS\r'
    # -----------------------------------------------------------
    # IFS FIELD SPLITTING (2026-08-28). Placed at the END of this
    # sourced file deliberately: the custom-$IFS cases below
    # CHANGE the separator set for the rest of the shell's life,
    # and there is no `unset`, so nothing may run after them that
    # depends on the default. RDCASES' own `EXIT` is the fence.
    #
    # A `for` loop is the observable, and it has to be: `echo`
    # rejoins its argv with single spaces, so `ECHO $A` prints
    # the same bytes whether the word split into three arguments
    # or stayed as one. Only something that acts PER ARGUMENT can
    # tell those apart, and `for` is the one this shell has.
    # -----------------------------------------------------------
    # IF: an unquoted substitution splits into separate words --
    # two loop iterations off ONE variable. The value is built
    # with `$( )` because maux has no quoted-assignment form
    # (docs/SHELL-GAPS.md sec 2), and that makes this case carry
    # a second assertion for free: the ASSIGNMENT itself did NOT
    # split, or A would have been `ONE` alone.
    'A=$(ECHO ONE TWO)\r'
    'FOR C IN $A\r'
    'DO\r'
    'ECHO IF:$C >> /mnt/MAUX/RESULTS\r'
    'DONE\r'
    # IQ: `"$A"` -- the SAME variable, quoted -- is ONE word, one
    # iteration. The pair is the proof; either line alone could
    # pass with splitting hardwired on or off.
    'FOR C IN "$A"\r'
    'DO\r'
    'ECHO IQ:$C >> /mnt/MAUX/RESULTS\r'
    'DONE\r'
    # IZ: the implicit-null rule -- a variable that expands to
    # NOTHING yields no argument at all, so the loop runs ONCE,
    # over X. A `IZ:` line here would mean an empty argument was
    # manufactured, which is the classic wrong answer.
    'FOR C IN $NOTHING X\r'
    'DO\r'
    'ECHO IZ:$C >> /mnt/MAUX/RESULTS\r'
    'DONE\r'
    # -----------------------------------------------------------
    # QUOTED ASSIGNMENT (2026-08-28). `V='a b'` was a SYNTAX
    # ERROR in maux until this landed -- `sh: mixed quoting`,
    # typed by a human -- so there was no way to write a
    # multi-word value down at all. Placed here, under the
    # DEFAULT separator set, deliberately: QB is the half that
    # pairs with IFS, and the pair is the canonical Bourne idiom.
    # -----------------------------------------------------------
    # QA: single quotes hold a space, and the value survives whole
    # when read back QUOTED.
    "A='P Q'\r"
    'ECHO "QA:$A" >> /mnt/MAUX/RESULTS\r'
    # QB: ...and UNQUOTED, that same value splits into two words.
    # This is the whole point of doing both features together:
    # `V='a b c'` writes the value, `for x in $V` takes it apart,
    # and neither half is usable alone.
    'FOR C IN $A\r'
    'DO\r'
    'ECHO QB:$C >> /mnt/MAUX/RESULTS\r'
    'DONE\r'
    # QC: DOUBLE quotes do the same holding-together job.
    'B="R S"\r'
    'ECHO "QC:$B" >> /mnt/MAUX/RESULTS\r'
    # QD/QE: ...and the two forms DIFFER exactly where V7 says --
    # the same body text, `$B`, literal under `'` and expanded
    # under `"`. Either line alone would pass with both forms
    # implemented identically; the pair is the assertion.
    "A='$B'\r"
    'ECHO "QD:$A" >> /mnt/MAUX/RESULTS\r'
    'A="$B"\r'
    'ECHO "QE:$A" >> /mnt/MAUX/RESULTS\r'
    # QF: a glob metacharacter inside the quotes stays LITERAL --
    # it must not expand against the volume at assignment time.
    #
    # ONE quote form, not both, and the deleted second case is
    # worth a note. A `A="*"` case was written here and then
    # REMOVED because it could not fail: sabotaging ASGMARK's
    # double-quote glob-marking left it green. An assignment word
    # can never glob-match on this volume -- a ProDOS name holds
    # only letters, digits and `.`, so nothing matches a pattern
    # containing `=`, and an unmatched pattern passes through
    # literally -- so the whole glob half of ASGMARK is
    # unobservable here (see its own header). A case that cannot
    # produce a different answer is not evidence, and this suite
    # is not the place to keep one.
    "A='*'\r"
    'ECHO "QF:$A" >> /mnt/MAUX/RESULTS\r'
    # QW: the word of `CASE word IN` is matched WHOLE, never split
    # -- Bourne's rule, and the third branch of SPLIT_APPEND that
    # nothing else here can see. The existing CASEVAR case uses a
    # single-word value, so it passes whether or not the case word
    # splits; only a value with a separator in it can tell. The
    # pattern is a GLOB rather than a quoted `"C D")` because a
    # quoted pattern trips the tokenizer's mixed-quoting rule:
    # `C*D` matches the whole value and cannot match the first
    # field alone, so WHOLE and SPLIT are distinguishable without
    # quoting anything. bash prints QW:WHOLE.
    "A='C D'\r"
    'CASE $A IN\r'
    'C*D) ECHO QW:WHOLE >> /mnt/MAUX/RESULTS ;;\r'
    'C) ECHO QW:SPLIT >> /mnt/MAUX/RESULTS ;;\r'
    'ESAC\r'
    # IC: $IFS is honoured, not hardwired -- `.` splits here.
    'IFS=.\r'
    'B=$(ECHO M.N)\r'
    'FOR C IN $B\r'
    'DO\r'
    'ECHO IC:$C >> /mnt/MAUX/RESULTS\r'
    'DONE\r'
    # IL: and a LITERAL separator in the source text does NOT
    # split, even now that `.` is a separator -- V7 scans only
    # the RESULTS of substitution. This is the case that fails if
    # the split is done on the finished word without tracking
    # where its bytes came from, and the failure mode is severe:
    # every path in every command line would fragment.
    'FOR C IN LIT.ERAL\r'
    'DO\r'
    # QUOTED on purpose. Unquoted, `ECHO IL:$C` prints
    # `IL:LIT ERAL` -- and that is CORRECT: C's value came from
    # a substitution at that point, so the dot inside it splits
    # exactly as bash's does (verified on the host, both forms).
    # An authored expectation of `IL:LIT.ERAL` for the unquoted
    # form is what this case first shipped with, and the gate
    # caught it. Quoting isolates the assertion this case is
    # FOR: whether the literal split at `for` time, visible as
    # one iteration with the value intact.
    'ECHO "IL:$C" >> /mnt/MAUX/RESULTS\r'
    'DONE\r'
    # IP: THE case with teeth, and the one IL alone does not
    # give. `LIT.$B` holds a literal `.` AND a substituted one in
    # the SAME word: the literal must not split, the substituted
    # must, so the words are `LIT.M` and `N`. bash prints exactly
    # that. IL cannot see this -- its word has no substitution at
    # all, so it never reaches the split path, and an
    # implementation that splits the finished word with no idea
    # where its bytes came from passes IL and every other case
    # here. Measured: with the marking removed, the whole suite
    # was still green until this line existed.
    'FOR C IN LIT.$B\r'
    'DO\r'
    'ECHO "IP:$C" >> /mnt/MAUX/RESULTS\r'
    'DONE\r'
    # IR: `read` splits on the SAME set -- the builtin's old
    # hardwired space/tab test is gone. With IFS=`.` the split is
    # at the dot, so B absorbs `Q R` -- SPACE included, which
    # under the default set would have been THE separator.
    #
    # The input is its own file via the compound `DONE < FILE`
    # form, NOT another data line appended to the outer script:
    # that script's data is already fully consumed by R9's
    # `WHILE READ` loop and R4's EOF read, and one more line
    # there would be eaten as a third R9 iteration and rob R4 of
    # the EOF it exists to assert. Caught before running it; the
    # dedicated file has no such coupling.
    'WHILE READ A B\r'
    'DO\r'
    'ECHO IR:$A:$B: >> /mnt/MAUX/RESULTS\r'
    'DONE < /mnt/MAUX/IFSDATA\r'
    'EXIT\r'
)
RDCASES_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                      for c in RDCASES_TEXT)

# ---------------------------------------------------------------------
# IFSCR -- the IFS field-splitting gate (2026-08-28), run as its own
# `SH < /mnt/MAUX/IFSCR` child rather than inline, for two structural
# reasons: (1) `IFS=:` cannot be un-set afterwards (maux has no unset,
# and the default set -- space+tab+CR -- cannot be retyped as an
# assignment), so the custom-IFS half would poison every later case in
# the parent script; (2) the parent's variable table is already at six
# of MAXVARS=8 slots and these cases need four more names -- the child
# gets a fresh table and a fresh IFS both. Every expectation below is
# bash's own output for the identical words (derivation run recorded
# in the case comments).
#
# The FOR loops are the observable: `echo $Q` re-joins fields with
# single spaces, so its output cannot distinguish two arguments from
# one -- an iteration COUNT can.
IFSCR_TEXT = (
    # Default IFS. Q holds two words (escaped-space assignment);
    # unquoted $Q must yield TWO loop iterations...
    'Q=A\\ B\r'
    'FOR F IN $Q\r'
    'DO\r'
    'ECHO IF:$F >> /mnt/MAUX/RESULTS\r'
    'DONE\r'
    # ...and quoted "$Q" exactly ONE -- quoting suppresses splitting.
    'FOR F IN "$Q"\r'
    'DO\r'
    'ECHO IQ:$F >> /mnt/MAUX/RESULTS\r'
    'DONE\r'
    # Implicit null removal: $NOSUCH contributes NO argument, so echo
    # gets one arg and prints `IN1`, no leading space. (Before IFS
    # landed, an empty argv[1] made this ` IN1` -- bash prints `IN1`.)
    'ECHO $NOSUCH IN1 >> /mnt/MAUX/RESULTS\r'
    # ...but glued to literal text the word survives: `IE::`.
    'ECHO IE:$NOSUCH: >> /mnt/MAUX/RESULTS\r'
    # Custom IFS. Substituted colons split...
    'IFS=:\r'
    'P=A:B:C\r'
    'FOR F IN $P\r'
    'DO\r'
    'ECHO IC:$F >> /mnt/MAUX/RESULTS\r'
    'DONE\r'
    # ...literal colons do NOT (V7 sh(1): only the RESULTS of
    # substitution are scanned) -- in a word with no substitution...
    'ECHO IL:A:B >> /mnt/MAUX/RESULTS\r'
    # ...and in a word WITH one (EMITB_LIT's low-marking: the literal
    # `IM:A:B` prefix must not split even though $V made the word
    # split-eligible). bash: `IM:A:BX`.
    'V=X\r'
    'ECHO IM:A:B$V >> /mnt/MAUX/RESULTS\r'
    # `read` splits on $IFS too: one colon-separated line, two names.
    'READ X Y\r'
    'AA:BB\r'
    'ECHO IR:$X.$Y >> /mnt/MAUX/RESULTS\r'
    'EXIT\r'
)
IFSCR_BYTES = bytes((ord(c) | 0x80) if c != '\r' else 0x8D
                    for c in IFSCR_TEXT)

EXPECT_RESULTS2 = (
    hilines('P=ONE S=1 V=HDVARVAL') +  # gate case (a): `<<WORD`
                                       # expands $1, $?, $VAR all
                                       # on one line
    hilines('P=$1 S=$? V=$HDVAR') +   # gate case (b): `<<'WORD'`,
                                       # SAME body text, expands
                                       # NONE of it -- the pair
                                       # proves the difference
                                       # rather than assuming it
    hilines('P=$1 TABQUOTE') +        # gate case: `<<-'WORD'` --
                                       # tab-stripping and quoting
                                       # compose (tabs gone, `$1`
                                       # still literal)
    hilines('MYGREPMATCH') +          # gate case (d), docs/DEMOS
                                       # .md sec 1: `ed` scripted by
                                       # an expanding here-doc whose
                                       # pattern is $1 matches real
                                       # `grep` byte-for-byte on the
                                       # same pattern/file
    # ---------------- command substitution `$( )` ----------------
    hilines('ABC') +                  # spliced INTO a word
    hilines('CATFISH CATNIP') +       # arguments survive the token
                                       # split; the CR BETWEEN the
                                       # two matched lines is an
                                       # IFS separator (2026-08-28)
                                       # -- the unquoted capture
                                       # splits into TWO echo args,
                                       # joined by one space. bash
                                       # agrees: echo $(printf
                                       # 'A\nB\n') prints `A B`.
                                       # (Until IFS landed the CR
                                       # survived into the single
                                       # argument -- that was the
                                       # divergence, not this.)
    hilines('T:TNLVAL:') +            # THREE trailing CRs removed,
                                       # proven mid-line
    hilines('V:CAPVAL') +             # `VAR=$(cmd)`
    hilines('Q:DQVAL') +              # `"...$(cmd)..."` expands
    hilines('$(ECHO NOPE)') +         # `'...'` does not -- same
                                       # inner command as the line
                                       # above
    hilines('N::') +                  # a no-match command captures
                                       # EMPTY, cleanly
    hilines('S=HDSUB') +              # `<<WORD` body substitutes
    hilines('S=$(ECHO HDSUB)') +      # `<<'WORD'` body does not,
                                       # on identical text
    # ---- the body is the SUBSHELL's (SHELL-GAPS sec 2's table) ----
    hilines('PA:one') +               # an UNEXPORTED variable
                                       # crosses -- serialised as
                                       # an assignment ahead of
                                       # the body, not pre-
                                       # substituted
    hilines('PB:2') +                 # a body assignment shadows
                                       # the parent (bash agrees;
                                       # pre-expansion made this 1)
    hilines('PC:one') +               # ...and does not leak back
    hilines('PD:$CSV') +               # body quotes are the
                                       # subshell's (bash agrees;
                                       # this used to print empty)
    hilines('SA:ONE TWO THREE') +     # `$*`
    hilines('SB:ONE TWO THREE') +     # `$@` -- identical in V7
    hilines('SC:3') +                 # ...and `$#` agrees
    # ---- `( )` grouping, script form ----
    hilines('GA', 'GB') +             # a `;` body runs in order
    hilines('GS0') +                  # ...and its status propagates
    hilines('GX') +                   # a redirect ON the group is
    hilines('GR0') +                  # HONOURED since 2026-08-27:
                                       # GX reaches RESULTS through
                                       # the group's own `>>` and $?
                                       # is 0. Was GR1-and-no-GX
                                       # while CHCK_GROUP refused
                                       # it; e2e cases 116/117 went
                                       # DEFECT-FIXED in the same
                                       # change
    hilines('RGF') +                  # the PAIR on a group (KFIX3 1):
    hilines('cat: cannot open /mnt/MAUX/RGNO') +  # A / B
    hilines('PL1') +                  # `(pl1)`: the alias expands
    hilines('PL1') + hilines('PL1') + # `(pl1;pl1)`
    hilines('PL1') +                  # `( pl1 )`, the spaced control
    hilines('PL1') + hilines('PL1') + # `((pl1);pl1)`: both expand
    hilines('(pl1)') +                # quoted: a word, not an alias
    # (a group in a FALSE branch writes NOTHING -- the absence of
    #  GSKIP here IS that assertion)
    # `&` on a group: the probe BEFORE `wait` fails because the
    # group is still sleeping (a foreground group would have
    # finished and made it succeed), then `wait` reaps it and its
    # output is there.
    hilines('GBGP1') +
    hilines('GBGA') +
    hilines('GNA', 'GNB') +           # nested group: inner first,
                                       # nothing leaking to the
                                       # parent
    hilines('GKON') +                 # ...and the script
                                       # demonstrably kept going.
                                       # A LITERAL, not `$?`:
                                       # measured 2026-08-27, `$?`
                                       # after a false `if` with no
                                       # ELSE is 1 here (the
                                       # CONDITION's status) where
                                       # POSIX says 0. That is a
                                       # real pre-existing
                                       # divergence, out of this
                                       # feature's scope, and
                                       # asserting it either way
                                       # from a `( )` case would
                                       # be pinning someone else's
                                       # semantics by accident
    hilines('GC:one') +               # a parent variable reaches a
                                       # subshell
    hilines('GD:one') +               # ...and is unchanged after
    # (the nested `$(...)` line writes NOTHING -- refused loudly,
    #  line abandoned; its absence IS that assertion)
    hilines('NST1') +                 # ... and $? is nonzero
    # (the unclosed `$(` line likewise writes nothing)
    hilines('UNC1') +
    hilines('CATFISH CATNIP') +       # `|` inside `$( )` runs --
                                       # the body is a whole nested
                                       # sh -- and the interior CR,
                                       # having survived the
                                       # trailing strip, is then an
                                       # IFS field separator like
                                       # the plain-GREP case above
    hilines('OPP0') +                 # ...and $? is the pipeline's
    hilines('OPM0') +                 # nested sh 2> OPE: OPE is
                                       # BYTE-EMPTY (no prompts, no
                                       # diagnostics) -- CMP against
                                       # the staged empty EMPTYF
    hilines('EC0') +                  # builtin `echo` byte-exact
                                       # against the external one,
                                       # `>` and `>>` both
    hilines('EN0') +                  # ...including a bare ECHO,
                                       # which prints only the CR
    hilines('PIPED') +                # a pipeline still uses the
                                       # external binary and still
                                       # works
                 # (the orphaned comment that
                                       # stood here described the
                                       # operator-refusal
                                       # diagnostic, gone with the
                                       # refusal itself -- see the
                                       # OPP/OPM cases above)
    hilines('ONE TWO') +              # TWO expanding words on one
                                       # line -- `ONETWO TWO` is
                                       # the pre-fix output
    # ---------------- `2>&1` fd duplication ----------------------
    # A = `> D1 2>&1`, B = `2>&1 > D2`. A1/B1 is the whole point:
    # the SAME two redirections, opposite order, opposite result.
    hilines('NB0') +                  # the 5-io_buffer shape:
                                       # `SH < script > out` whose
                                       # inner command opens a file.
                                       # FAILED at MLI_IOBUF_CNT=4
                                       # with `cat: cannot open` on a
                                       # file that exists; works at 6
    # ------- compound redirection (docs/SH-FEATURES.md sec 18) ----
    hilines('CR0') +                  # `FI > FILE` -- the construct's
                                       # output IS in CRT. Was CR2,
                                       # locked as sec 17's "silently
                                       # discarded" limitation; that
                                       # case was also MISSPELLED
                                       # (`;` glued to the preceding
                                       # word), so it measured a
                                       # `test` usage error, not the
                                       # compound at all
    hilines('CC0') +                  # CONTROL: the IDENTICAL
                                       # redirect on a SIMPLE command,
                                       # same position and budget --
                                       # without it CR0 cannot
                                       # distinguish "the compound
                                       # works" from "everything here
                                       # works"
    hilines('RL:LINEONE') +           # THE motivating idiom: `WHILE
    hilines('RL:SECOND LINE HERE') +  # READ ... DONE < FILE`, and
    hilines('RL:III') +               # the assertion is the CONTENT
                                       # read, in order, off a file
                                       # that is NOT fd 0
    hilines('CS0') +                  # a FALSE condition still
                                       # applies the redirect: CSKIP
                                       # exists ...
    hilines('CN1') +                  # ... and is empty (grep opened
                                       # it and matched nothing --
                                       # status 2 would mean it could
                                       # not open it at all)
    hilines('CAPPBASE') +             # `DONE >> FILE` on a FOR loop:
    hilines('F:ONE') +                # the staged line survives ...
    hilines('F:TWO') +                # ... and both iterations append
    hilines('OUTER') +                # NESTING: the outer WHILE's
    hilines('OUTER2') +               # body went to COUTER, and the
                                       # inner IF's did NOT -- INNER
                                       # is absent here, which is the
                                       # innermost-wins assertion
    hilines('INNER') +                # ... and IS in CINNER
    hilines('CD0') +                  # `FI 2> FILE` -- the TARGET fd
                                       # travels with the redirect
    hilines('CATFISH') +              # a PIPELINE body: the
                                       # construct's `>` caught the
                                       # LAST stage (grep's output),
                                       # not the first's
    hilines('PRE') +                  # the documented limit: a
    hilines('MID') +                  # construct opened as a LATER
                                       # segment is not scanned ...
    hilines('CM1') +                  # ... so its redirect stays
                                       # orphaned and is REFUSED ...
    hilines('CX1') +                  # ... and CMID is never created
    hilines('CE1') +                  # sec 17: a bare `< FILE`
                                       # with no command word at all
                                       # is still REFUSED (nonzero $?
                                       # plus a diagnostic on fd 2) --
                                       # sec 18 must not have turned
                                       # CK_ORPHRDIR off wholesale
    hilines('SY1') +                 # a syntax error sets $?
                                       # -- it used to leave the
                                       # PREVIOUS command's status
    hilines('A10') +                  # diagnostic IS in D1 (grep
                                       # found it -- status 0)
    hilines('A20') +                  # ... and so is the data
    hilines('B11') +                  # diagnostic is NOT in D2
                                       # (grep status 1) -- stderr
                                       # was duped from fd 1 BEFORE
                                       # fd 1 was moved to the file
    hilines('B30') +                  # ... and the diagnostic came
                                       # out on the OLD fd 1, i.e.
                                       # DUPOUT. This is what makes
                                       # B a positive assertion
                                       # rather than an absence.
    # ---------------- io_buffer lending (IOBUF-LENDING.md) --------
    hilines('D6:0', 'D5', 'D4', 'D3', 'D2', 'D1') +  # six nested
                                       # sh scripts, parked while
                                       # `cat` ran, each resumed at
                                       # the right line (saved mark)
    hilines('DP0') +                  # DEEPF holds MGFILE's text:
                                       # `cat` opened both files
                                       # past the 8-buffer ceiling
    hilines('DEEPQUIET') +            # and no sh diagnosed anything
    # ---------------- `read` (docs/SH-FEATURES.md sec 16) --------
    hilines('R0:1') +                 # no arguments -- usage error,
                                       # nonzero, no line consumed
    hilines('R0B:1') +                # a name that cannot start a
                                       # variable -- refused BEFORE
                                       # the read, so also no line
    hilines('R1:ALPHA') +             # one word, one variable
    hilines('R2:ONE:TWO:THREE AND FOUR') +
                                       # THE splitting case: the
                                       # LAST variable takes the
                                       # whole remainder, spaces
                                       # included. A suite that only
                                       # read single-word lines could
                                       # not see this go wrong.
    hilines('R3:LEAD:MID TRAIL:') +   # leading tab+spaces skipped,
                                       # TAB honoured as a separator,
                                       # trailing spaces gone. The
                                       # interior run IS kept in $B
                                       # -- but `ECHO R3:$A:$B:` is
                                       # an unquoted expansion, so
                                       # IFS splitting (2026-08-28)
                                       # collapses the run to one
                                       # space in the OUTPUT. bash
                                       # prints the identical line
                                       # for the identical words
    hilines('R5:SOLO::') +            # fewer words than variables --
                                       # the surplus is empty, not
                                       # stale and not an error
    hilines('R6:0::') +               # an EMPTY line is DATA: status
                                       # 0 and an empty value, NOT
                                       # end-of-file
    hilines('R7:ECHO:WRONGLY:>> /mnt/MAUX/RESULTS') +
                                       # a data line shaped like a
                                       # command is read, never run
                                       # (a bare `WRONGLY` line
                                       # anywhere here would be the
                                       # failure)
    hilines('R8:1:KEEPA:') +          # `read VAR < FILE` refused
                                       # loudly; the variable keeps
                                       # its old value and no input
                                       # line was consumed
    hilines('R9:L1', 'R9:L2') +       # `WHILE READ A` -- two
                                       # iterations off fd 0 while
                                       # the loop head seeks on
                                       # CUR_IN_FD, then EOF ends it
    hilines('R4:1:KEEPME:') +         # EOF: nonzero status AND the
                                       # variable untouched -- one
                                       # contract, both halves
    hilines('READ') +                 # ECHO READ -- argv[1] is not
                                       # command position
    # ---------------- IFS field splitting (2026-08-28) -----------
    hilines('IF:ONE', 'IF:TWO') +     # an unquoted substitution
                                       # splits into TWO words --
                                       # two loop iterations off one
                                       # variable. The assignment
                                       # that BUILT it did not split
    hilines('IQ:ONE TWO') +           # ...and quoted it is ONE word,
                                       # same variable, one iteration
    hilines('IZ:X') +                 # implicit null: an empty
                                       # expansion yields NO argument
                                       # (an `IZ:` line here would be
                                       # a manufactured empty one)
    # -------------- quoted assignment (2026-08-28) ---------------
    hilines('QA:P Q') +               # `V='a b'` -- a syntax error
                                       # in this shell until now
    hilines('QB:P', 'QB:Q') +         # ...and the value splits when
                                       # read back unquoted: the two
                                       # halves of one Bourne idiom
    hilines('QC:R S') +               # `V="a b"` holds too
    hilines('QD:$B') +                # `'...'` keeps `$B` literal
    hilines('QE:R S') +               # `"..."` expands it -- the
                                       # pair is the assertion
    hilines('QF:*') +                 # a glob metacharacter stays
                                       # literal, never expanded
                                       # against the volume...
    hilines('QW:WHOLE') +             # a `case` word is matched
                                       # WHOLE, never split -- the
                                       # third never-split rule, and
                                       # the one CASEVAR cannot see
    hilines('IC:M', 'IC:N') +         # $IFS is honoured, not
                                       # hardwired -- `.` splits
    hilines('IL:LIT.ERAL') +          # ...but a LITERAL `.` in the
                                       # source text does NOT split:
                                       # V7 scans only the results of
                                       # substitution. ONE iteration
                                       # with the value whole (the
                                       # echo is quoted -- see the
                                       # script's own note on why)
    hilines('IP:LIT.M', 'IP:N') +     # both rules in ONE word: the
                                       # literal `.` holds, the
                                       # substituted `.` splits.
                                       # This is the only case that
                                       # fails when the literal/
                                       # substituted distinction is
                                       # dropped -- sabotage-proven
    hilines('IR:P:Q R:')              # `read` splits on the same set
                                       # -- the dot separates, and the
                                       # SPACE (a default separator)
                                       # is absorbed into B
)


# ===========================================================================
# THIRD image (`build/shlang-b.po`) -- the six POSIX builtins of
# 2026-09-16: `command`, `type`, `eval`, `exec`, `readonly`, `times`
# (docs/SH-FEATURES.md sec 29).
#
# A THIRD BOOT, FOR THE SECOND IMAGE'S OWN STATED REASON. Both existing
# scripts run close to the io_buffer ceiling on purpose -- the first is
# 40+ spawns deep before its here-doc cases, and the second ends with
# the DEEP1-DEEP6 lending case that is DESIGNED to peak the pool -- so
# appending five more nested-shell cases to either would be testing this
# task's builtins against that ceiling rather than against themselves.
# A fresh boot costs one more emulator process and buys an assertion
# that means what it says.
#
# AND THE NESTING IS NOT DECORATION, for three separate reasons:
#   * `exec >FILE` changes the SHELL's own fd 1 for the rest of its
#     life. Run in the top-level shell it would capture every later
#     line of the gate script; run in a child it is exactly the
#     construct a script uses, and the child's own later commands are
#     the proof that it STUCK.
#   * `exec CMD` EXITS the shell. Nothing after it in that shell runs,
#     which is the whole assertion -- so it needs a shell of its own.
#   * `type`/`command -v`/`readonly`'s listing print to stdout and
#     REFUSE a redirect of their own (SB_NOREDIR, shsgblt.s). The only
#     way to capture them is to redirect the SPAWN -- `SH < BLTSCR >>
#     RESULTS` -- which is also the shape a user reaches for.
# THE DIAGNOSTICS NEED A SPAWN OF THEIR OWN, and finding out why cost a
# run: check_shlang.py's own comment said "sh's OWN fd 2 is duped to
# /mnt/MAUX/SHERR for the whole run (shlangtestb.s SPAWN_SH)" and that is
# STALE -- read the file and SPAWN_SH wires exactly one fdaction, fd 0
# from the script, nothing else. /mnt/MAUX/SHERR on the first image is made
# by that image's own script, with an ordinary `2>` on a nested spawn.
# And this shell cannot carry BOTH a `>` and a `2>` on one command --
# the second silently overwrites the first, one output slot per stage
# (scripts/e2e_corpus.py's own header records the measurement) -- so a
# case whose STDOUT is captured cannot also have its stderr captured.
# ERRSCR below is the stderr twin: the same refusals, run again in a
# shell whose stdout goes nowhere interesting and whose fd 2 is a file.
# ===========================================================================
OUT_IMG3 = os.path.join(ROOT, 'build', 'shlang-b.po')

# ---------------------------------------------------------------------
# BLTSCR -- `type`, `command`, `eval` and `readonly`. Its stdout is the
# RESULTS file (the spawn's own `>>`), so everything below prints into
# the byte-exact contract; its stderr is SHERR.
# ---------------------------------------------------------------------
BLTSCR_TEXT = (
    # `type`: the three answers, in the three wordings. ECHO is a
    # BUILTIN in this shell and also a binary on this volume -- the
    # builtin has to win, which is what makes it the interesting one.
    'TYPE ECHO\r'
    'TYPE CAT\r'
    'TYPE IF\r'
    # Several operands in one call, and the status after an all-found
    # call is 0.
    'TYPE CMP GREP\r'
    'ECHO TY0:$?\r'
    # A name that resolves to nothing: the diagnostic is on stderr
    # (SHERR), stdout stays empty, and the status is 1.
    'TYPE NOSUCHCMD\r'
    'ECHO TY1:$?\r'
    # A name WITH a '/' is probed, not PATH-searched -- without that
    # check BUILD_PATH would build /mnt/MAUX//bin/CAT and call every
    # absolute path missing.
    'TYPE /bin/CAT\r'
    'TYPE /mnt/MAUX/NOSUCHF\r'
    'ECHO TY2:$?\r'
    # `command -V` is `type`'s wording; `command -v` is the terse one
    # -- a builtin prints as its own name, a command as its path. The
    # two spellings differ only in case, which is why they are compared
    # with STRCMP and not STRCMPI.
    'COMMAND -V CD\r'
    'COMMAND -v CAT\r'
    'COMMAND -v ECHO\r'
    # Silent on failure (POSIX), status 1.
    'COMMAND -v NOSUCHCMD\r'
    'ECHO CM1:$?\r'
    # The PLAIN form runs the command, builtins included: this reaches
    # the ECHO BUILTIN through the shifted argv, not /mnt/MAUX/ECHO.
    'COMMAND ECHO CMDRAN\r'
    'ECHO CM2:$?\r'
    # The refusal, asserted rather than assumed: a builtin that prints
    # cannot take a redirect, so this must NOT create /mnt/MAUX/NUL and
    # must NOT print to stdout -- status 1 and nothing else.
    'TYPE ECHO > /mnt/MAUX/NUL\r'
    'ECHO TY3:$?\r'
    # `eval`, and the TWO expansion passes that define it. The first
    # line's `$X` is expanded by the ordinary argument pass; the
    # second's is quoted, survives pass 1 as the literal text `$X`, and
    # is expanded only because eval re-parses the joined line.
    'X=EVX\r'
    'EVAL ECHO EV1 $X\r'
    "EVAL ECHO EV2 '$X'\r"
    # The documented divergence, gated so it cannot change silently:
    # eval abandons the REST of its own line, exactly as `.` does.
    # NOTREACHED must not appear.
    'EVAL ECHO EV3 ; ECHO NOTREACHED\r'
    # `readonly`: the flag has to bind every writer, so both an
    # assignment and an `unset` are refused, each leaving the ORIGINAL
    # value in place and $? at 1.
    'R=RV1\r'
    'READONLY R\r'
    'R=RV2\r'
    'ECHO RO1:$R.$?\r'
    'UNSET R\r'
    'ECHO RO2:$R.$?\r'
    # NAME=VALUE assigns and marks in one operand.
    'READONLY S=SV1\r'
    'ECHO RO3:$S\r'
    # ...and the bare form lists what is marked, in a form that reads
    # back in.
    'READONLY\r'
    'EXIT\r'
)

# ---------------------------------------------------------------------
# ERRSCR -- the stderr twin of BLTSCR's three refusals, run as
# `SH < ERRSCR 2> BLTERR`. Every line here is chosen to print NOTHING on
# stdout, so the only thing the run produces is the diagnostics. The
# statuses are asserted in BLTSCR (TY1/TY3/RO1/RO2); this file asserts
# that each refusal SAYS something -- a builtin that returned 1 in
# silence would pass one half and fail the other.
# ---------------------------------------------------------------------
ERRSCR_TEXT = (
    'TYPE NOSUCHCMD\r'
    'TYPE ECHO > /mnt/MAUX/NUL\r'
    'R=RV1\r'
    'READONLY R\r'
    'R=RV2\r'
    'UNSET R\r'
    'EXIT\r'
)

# ---------------------------------------------------------------------
# XSCR -- `exec >FILE` PERSISTENCE, which is the form scripts actually
# use. TWO later commands write to the file, and neither carries a
# redirect of its own: one would prove the open, two prove that the
# shell's fd 1 itself moved.
# ---------------------------------------------------------------------
XSCR_TEXT = (
    'EXEC > /mnt/MAUX/XOUT\r'
    'ECHO XO1\r'
    'ECHO XO2\r'
    'EXIT\r'
)

# ---------------------------------------------------------------------
# XSCR2 -- `exec COMMAND`. maux has no exec syscall, so this runs the
# command and then leaves the shell with its status (docs/SH-FEATURES.md
# sec 29). The assertion is the SECOND line never running.
# ---------------------------------------------------------------------
XSCR2_TEXT = (
    'EXEC ECHO XEXEC\r'
    'ECHO NOTREACHED\r'
)

# ---------------------------------------------------------------------
# XSCR3 -- `exec 2>&1`, the dup half. Run as `SH < XSCR3 > XERR`, so
# fd 1 is XERR before the shell starts; the `exec` then points fd 2 at
# it too, and `cat`'s own diagnostic -- a CHILD's stderr, inherited
# through the shell's changed table -- is what lands in the file.
# ---------------------------------------------------------------------
XSCR3_TEXT = (
    'EXEC 2>&1\r'
    'CAT /mnt/MAUX/NOSUCHF\r'
    'EXIT\r'
)

# ---------------------------------------------------------------------
# TMSCR -- `times`. Its first field is ELAPSED time and therefore not
# byte-stable, so it goes to its OWN file and check_shlang.py matches
# the SHAPE (two lines, four "NmSS.HHs" fields, children structurally
# zero) rather than a literal. That is the whole of what maux promises
# here; see docs/SH-FEATURES.md sec 29.
# ---------------------------------------------------------------------
TMSCR_TEXT = (
    # Burn some measurable time FIRST. Three spawns plus three file
    # copies is tens of milliseconds of emulated 1 MHz, which is the
    # difference between a `times` whose arithmetic is exercised and
    # one that prints its zero path and proves nothing about
    # SB_DIV60/SB_HUND at all -- check_shlang.py asserts the first
    # field is NOT 0m0.00s for exactly that reason.
    'CAT /mnt/MAUX/BLTSCR > /mnt/MAUX/NUL2\r'
    'CAT /mnt/MAUX/BLTSCR > /mnt/MAUX/NUL2\r'
    'CAT /mnt/MAUX/BLTSCR > /mnt/MAUX/NUL2\r'
    'TIMES\r'
    'EXIT\r'
)

# ---------------------------------------------------------------------
# ALISCR / ALI2SCR / ALIERRS -- `alias`, `unalias`, `hash`, `fc`
# (docs/SH-ALIAS-NOTES.md). Lowercase on purpose: alias names are
# CASE-SENSITIVE (the builtin VERBS are folded, the names are not).
# ALISCR and ALI2SCR print into RESULTS; ALIERRS is the stderr twin,
# run as `SH < ALIERRS 2> ALIERRF`. Each is its own nested shell, so
# each starts with an empty alias table.
# ---------------------------------------------------------------------
ALISCR_TEXT = (
    'echo FILEBODY > /mnt/MAUX/QF\r'
    "alias e1='echo ONE'\r"
    'alias\r'
    'e1 two\r'
    'alias e1\r'
    # Trailing blank: the NEXT word is checked too (POSIX 2.3.1).
    "alias x='echo '\r"
    'alias y=hi2\r'
    'x y\r'
    # A QUOTED word is never an alias: 'cat' and \cat are the real cat.
    "alias cat='echo ALIASED'\r"
    'cat /mnt/MAUX/QF\r'
    "'cat' /mnt/MAUX/QF\r"
    '\\cat /mnt/MAUX/QF\r'
    # A name being expanded is not expanded again.
    "alias echo='echo REC'\r"
    'echo a\r'
    'unalias echo\r'
    'echo A2\r'
    # A value's own quote is listed in a form that reads back in.
    'alias q="echo it\'s"\r'
    'alias q\r'
    'alias nosuch\r'
    'echo AN:$?\r'
    'unalias nosuch\r'
    'echo UN:$?\r'
    'unalias e1\r'
    'echo UE:$?\r'
    'alias\r'
    'unalias -a\r'
    'alias\r'
    'echo UA:$?\r'
    # A subshell is a fresh process: it does NOT see the parent's alias.
    'alias sx=echo\r'
    'echo SUB:$(sx hi)\r'
    # hash: bare is silent, -r flushes the real cache, a name resolves.
    'hash\r'
    'echo H0:$?\r'
    'hash -r\r'
    'echo H1:$?\r'
    'hash cat\r'
    'echo H2:$?\r'
    'hash nosuchcmd\r'
    'echo H3:$?\r'
    # fc is a loud refusal, status 2.
    'fc\r'
    'echo FC:$?\r'
    'EXIT\r'
)
ALI2SCR_TEXT = (
    'alias a1=1\r'
    'alias a2=2\r'
    'alias a3=3\r'
    'alias a4=4\r'
    'alias a5=5\r'
    'alias a6=6\r'
    'alias a7=7\r'
    'alias a8=8\r'
    # The ninth is refused, loudly, status 1 -- never dropped.
    'alias a9=9\r'
    'echo FULL:$?\r'
    # Redefining an existing name needs no free slot.
    'alias a1=0123456789012345678901234567890\r'
    'echo RE:$?\r'
    # Eight expansions of 31 bytes cannot fit LINEMAX (255): an
    # error, the line is dropped, nothing is truncated.
    'a1 ; a1 ; a1 ; a1 ; a1 ; a1 ; a1 ; a1 ;\r'
    'echo LONG:$?\r'
    'alias a1\r'
    'EXIT\r'
)
ALIERRS_TEXT = (
    'alias if=x\r'
    'alias nosuch\r'
    'unalias nosuch\r'
    'unalias\r'
    # SH-ROOM: an EMPTY name is absent, not a free slot. It used to
    # match slot 0's zero first byte and print that slot's UNWRITTEN
    # value (`alias =' ...garbage'`); the table now lives in the
    # segments' dead copy, where that garbage would be code bytes.
    'alias ""\r'
    'unalias ""\r'
    'hash nosuchcmd\r'
    'fc\r'
    'alias a/b=x\r'
    'alias v=0123456789012345678901234567890X\r'
    'alias a1=1\r'
    'alias a2=2\r'
    'alias a3=3\r'
    'alias a4=4\r'
    'alias a5=5\r'
    'alias a6=6\r'
    'alias a7=7\r'
    'alias a8=8\r'
    'alias a9=9\r'
    'alias a1=0123456789012345678901234567890\r'
    'a1 ; a1 ; a1 ; a1 ; a1 ; a1 ; a1 ; a1 ;\r'
    'EXIT\r'
)


# ---------------------------------------------------------------------
# NSPSCR -- operators WITHOUT BLANKS (KFIX 5, docs/KFIX-NOTES.md; the
# `|` half is docs/SH-PIPE-NOSPACE.md). Every line is the unspaced
# spelling of one the rest of this file already types with blanks, so
# the expectation is the spaced form's result. Redirects first (`>`,
# `>>`, `<`, `2>`, a word ending in a digit before `>`, and a glued
# `>&2` after a target word), then `;` `&&` `||` `&`, then the quoted
# and escaped controls that must stay LITERAL: a quoted operator is
# content, not a split.
# ---------------------------------------------------------------------
NSPSCR_TEXT = (
    'ECHO hi>/mnt/MAUX/NSF1\r'
    'CAT /mnt/MAUX/NSF1\r'
    'ECHO ap>>/mnt/MAUX/NSF1\r'
    'CAT </mnt/MAUX/NSF1\r'
    'CAT /mnt/MAUX/NOSUCHF 2>/mnt/MAUX/NSF2\r'
    'CAT /mnt/MAUX/NSF2\r'
    'ECHO a2>/mnt/MAUX/NSF3\r'
    'CAT /mnt/MAUX/NSF3\r'
    'ECHO dupd 2>/mnt/MAUX/NSF4>&2\r'
    'CAT /mnt/MAUX/NSF4\r'
    'ECHO s1;ECHO s2\r'
    'ECHO a1&&ECHO a2\r'
    'ECHO x||ECHO y\r'
    'ECHO bgx>/mnt/MAUX/NSF5&\r'
    'WAIT\r'
    'CAT /mnt/MAUX/NSF5\r'
    "ECHO 'q>r'\r"
    'ECHO "s;t"\r'
    'ECHO u\\>v\r'
    'ECHO w\\;x\r'
    "ECHO '<y' 'z&&z'\r"
    # a glued word that ends in `)` is a case pattern ONLY before a
    # `|`; after `;` and `>` it is a command substitution's end
    'ECHO /mnt/MAUX/NSF6>/mnt/MAUX/NSNAME\r'
    'X=1;Y=$(CAT</mnt/MAUX/NSNAME)\r'
    'ECHO $X\r'
    'ECHO $Y\r'
    'ECHO sub>$(CAT</mnt/MAUX/NSNAME)\r'
    'CAT /mnt/MAUX/NSF6\r'
    # KFIX2 5: alias expansion splits words at the same operator bytes
    # TOKENIZE does, so a command-position alias is expanded when `;`
    # `&&` `>` follow it with no blank (it used to be one word,
    # `ll;pwd`, found by no table). An alias in ARGUMENT position, and
    # a quoted one, stay literal.
    "alias nl1='ECHO N1'\r"
    'nl1;ECHO N2\r'
    'nl1>/mnt/MAUX/NSF7\r'
    'CAT /mnt/MAUX/NSF7\r'
    'ECHO z;nl1\r'
    'nl1&&nl1\r'
    'nl1|CAT\r'
    'ECHO nl1;ECHO nl1\r'
    "ECHO 'nl1;nl1'\r"
    # KFIX3 item 2: a glued ALL-DIGIT word before an operator that is
    # not `<`/`>` is a word (KFIX2 5(c) refused it: `ECHO 1;ECHO 2`
    # printed `sh: cannot redirect`)
    'ECHO 1;ECHO 2\r'
    'ECHO 3|CAT\r'
    'ECHO 4&&ECHO 5\r'
    'EXIT\r'
)

# NSPERRS -- the unspaced forms that must be REFUSED, not silently
# mis-lexed (KFIX2 5). stderr is NSPERRF, stdout joins RESULTS. A glued
# all-digit word before `>`/`<` is POSIX's IO_NUMBER: this shell holds
# fds 0-7 and `N>` only, so `8>F`, `10>F` and `2<F` are refused (they
# used to write the digits into F, or redirect stdin of a command that
# printed `2`). A full operator pool and a line past MAXTOK tokens are
# TOK_ERR too (they used to drop the rest of the line and run the
# head). Controls: the SPACED `8 >F` is the word 8. Results append to
# RESULTS BY THEIR OWN `>>`, a habit from when sh kept only one of a
# command's `>`/`2>` pair (docs/KFIX2-NOTES.md; fixed in KFIX3 item 1,
# the RDRSCR rows below), so `SH < S >> R 2> F` lost the stdout.
NSPPOOL_LINE = 'ECHO HEAD ' + ';;' * 84 + ' ECHO TAIL\r'
NSPTOK_LINE = 'ECHO HEAD;' + ':;' * 66 + 'ECHO TAIL\r'
# SH-DEFECTS 12: MAXARGV is 32 slots and argv[0] takes one, so 31
# arguments run and 32 are REFUSED -- nothing runs, `$?` is 1, the rest
# of the line is abandoned. Before the fix the 32nd word was dropped
# and the command RAN with 31 (rc 0); in a pipeline stage 1's argv was
# full (no terminator) so it read on into stage 2's slots. "Nothing
# ran" is asserted POSITIVELY: the redirect target of a refused line
# (NSG1/NSG2, already checked absent by check_shlang) must not exist --
# a command that ran would have created it. Targets are REUSED names:
# two more files in the volume root broke unrelated rows (`exec:
# cannot redirect`, the K rows).
NSPW31 = ' '.join('W%d' % i for i in range(1, 32))
NSPW32 = NSPW31 + ' W32'
NSPA31 = (
    'ECHO ' + NSPW31 + ' >/mnt/MAUX/NSG5\r'
    'ECHO E31:$? >> /mnt/MAUX/RESULTS\r'
    'CAT /mnt/MAUX/NSG5 >> /mnt/MAUX/RESULTS\r'
    'ECHO ' + NSPW31 + ' | CAT >/mnt/MAUX/NSG5\r'
    'ECHO E31P:$? >> /mnt/MAUX/RESULTS\r'
    'CAT /mnt/MAUX/NSG5 >> /mnt/MAUX/RESULTS\r'
    'ECHO ' + NSPW32 + ' >/mnt/MAUX/NSG1\r'
    'ECHO E32:$? >> /mnt/MAUX/RESULTS\r'
    'ECHO ' + NSPW32 + ' | CAT >/mnt/MAUX/NSG2\r'
    'ECHO E32P:$? >> /mnt/MAUX/RESULTS\r'
)

# FULLSCR -- the process table FULL. Banks 2-15 are the free list and
# the shell is bank 1, so twenty background sleeps cannot all start.
# A refused spawn must say WHY (`sh: no more processes`), not
# `sh: command not found` -- it printed the latter until 2026-10-31,
# to the first person who filled the machine. The count of refusals is
# not pinned (the gate harness and the nested sh own banks too); the
# gate wants at least one refusal and at least five sleeps that DID
# start, so a shell that refuses everything cannot pass.
# Both files live in BIN/: the volume ROOT directory is nearly full and
# two more root entries broke unrelated rows (`exec: cannot redirect`).
FULLSCR_TEXT = 'SLEEP 5 &\r' * 20 + 'WAIT\r'

NSPERRS_TEXT = (
    'ECHO 8 >/mnt/MAUX/NSG5\r'
    'CAT /mnt/MAUX/NSG5 >> /mnt/MAUX/RESULTS\r'
    'ECHO 8>/mnt/MAUX/NSG1\r'
    'ECHO E8:$? >> /mnt/MAUX/RESULTS\r'
    'ECHO 10>/mnt/MAUX/NSG2\r'
    'ECHO E10:$? >> /mnt/MAUX/RESULTS\r'
    'ECHO 2</mnt/MAUX/NSG5\r'
    'ECHO E2L:$? >> /mnt/MAUX/RESULTS\r'
    'ECHO 8</mnt/MAUX/NSG5\r'
    'ECHO E8L:$? >> /mnt/MAUX/RESULTS\r'
    # `N<<` is NOT a redirect and never was (review F3 believed the
    # base refused it; measured on the 2d39648 sh.bin, it is one
    # ordinary word, as here): pinned so item 2 cannot change it.
    'ECHO 2<<EOF >> /mnt/MAUX/RESULTS\r'
    'ECHO 2<<-EOF >> /mnt/MAUX/RESULTS\r'
    + NSPPOOL_LINE +
    'ECHO EPOOL:$? >> /mnt/MAUX/RESULTS\r'
    + NSPTOK_LINE +
    'ECHO ETOK:$? >> /mnt/MAUX/RESULTS\r'
    + NSPA31 +
    'EXIT\r'
)

# NSPXSCR -- `exec >F` with no blank, the form the brief names: it used
# to be `command not found`. Its own nested shell, like XSCR, because the
# redirect sticks for the rest of the script.
NSPXSCR_TEXT = (
    'EXEC >/mnt/MAUX/XOUT2\r'
    'ECHO XU1\r'
    'EXIT\r'
)

# ---------------------------------------------------------------------
# RDRSCR -- THE REDIRECT PAIR AND ITS ORDER (KFIX3 item 1). A command
# with `> A 2> B` used to keep only the last file redirect it met
# (one slot per stage), so A was never created and B took fd 1 or fd 2
# depending on how the pair was typed. Every file redirect is kept now,
# applied left to right (POSIX XCU 2.7), and so is every dup between
# them. Each row writes its files and reads them back, the nested
# shell's stdout is RESULTS. Rows: the pair in both orders, `>>` with
# a `2>`, both `>F 2>&1` (both streams in F) and `2>&1 >F` (stderr to
# the OLD stdout -- here the pipe -- and stdout to F), the pair on a
# piped stage (`2>F | next`: stderr in F while stdout rides the pipe),
# two redirects of ONE stream (the last file wins, the first is still
# created), three, the pair on a `( )` group, and `exec` with a pair.
# ---------------------------------------------------------------------
RDRSCR_TEXT = (
    'ECHO RDF1 > /mnt/MAUX/RDF\r'
    'CAT /mnt/MAUX/RDF /mnt/MAUX/NOSUCHR > /mnt/MAUX/RDA '
    '2> /mnt/MAUX/RDB\r'
    'ECHO RA:$?\r'
    'CAT /mnt/MAUX/RDA\r'
    'CAT /mnt/MAUX/RDB\r'
    'CAT /mnt/MAUX/RDF /mnt/MAUX/NOSUCHR 2> /mnt/MAUX/RDA '
    '> /mnt/MAUX/RDB\r'
    'CAT /mnt/MAUX/RDA\r'
    'CAT /mnt/MAUX/RDB\r'
    'ECHO RDF2 >> /mnt/MAUX/RDB 2> /mnt/MAUX/RDC\r'
    'CAT /mnt/MAUX/RDB\r'
    'CAT /mnt/MAUX/RDF /mnt/MAUX/NOSUCHR > /mnt/MAUX/RDA 2>&1\r'
    'CAT /mnt/MAUX/RDA\r'
    'CAT /mnt/MAUX/RDF /mnt/MAUX/NOSUCHR 2>&1 > /mnt/MAUX/RDB | CAT\r'
    'CAT /mnt/MAUX/RDB\r'
    'CAT /mnt/MAUX/RDF /mnt/MAUX/NOSUCHR 2> /mnt/MAUX/RDC | CAT\r'
    'CAT /mnt/MAUX/RDC\r'
    'ECHO g1 > /mnt/MAUX/RDA > /mnt/MAUX/RDB\r'
    'CAT /mnt/MAUX/RDA\r'
    'CAT /mnt/MAUX/RDB\r'
    'CAT /mnt/MAUX/RDF /mnt/MAUX/NOSUCHR > /mnt/MAUX/RDA '
    '2> /mnt/MAUX/RDB 3> /mnt/MAUX/RDN\r'
    'CAT /mnt/MAUX/RDA\r'
    'CAT /mnt/MAUX/RDB\r'
    'TEST -f /mnt/MAUX/RDN && ECHO N3YES\r'
    # the trio: `< I > O 2> E`. E was truncated by the redirect, so
    # a command that never made it leaves the last row's text there.
    'CAT < /mnt/MAUX/RDF > /mnt/MAUX/RDA 2> /mnt/MAUX/RDB\r'
    'CAT /mnt/MAUX/RDA\r'
    'CAT /mnt/MAUX/RDB\r'
    # `0<F` is `<F`
    'CAT 0</mnt/MAUX/RDF\r'
    # TEST is a builtin that never reaches RUN_PIPELINE; every file
    # redirect of it must still create/truncate its file (review F2:
    # `TEST X > A > B` made neither, the base made B). Three files,
    # each holding a line first; all must be EMPTY afterwards.
    # (RDB/RDC/RDN: RDXSCR3 below still reads RDA.)
    'ECHO q1 > /mnt/MAUX/RDB\r'
    'ECHO q2 > /mnt/MAUX/RDC\r'
    'ECHO q3 > /mnt/MAUX/RDN\r'
    'TEST X > /mnt/MAUX/RDB > /mnt/MAUX/RDC 2> /mnt/MAUX/RDN\r'
    'CAT /mnt/MAUX/RDB\r'
    'CAT /mnt/MAUX/RDC\r'
    'CAT /mnt/MAUX/RDN\r'
    'ECHO T1\r'
    'EXIT\r'
)

# The `exec` rows are nested shells of their own (the redirect sticks
# for the rest of the script, as XSCR's does). RDXSCR1: the pair on
# exec -- stdout in Q, stderr in R. RDXSCR2 (run with its stdout on
# RESULTS): `exec 2>&1 > T` is POSIX's "stderr to the OLD stdout,
# then stdout to T" -- the diagnostic lands in RESULTS and only `et`
# in T. (SB_EXECRD used to apply the file first and every dup after
# it, which sent the diagnostic into T.) The group rows are in the
# main script, next to `( ECHO GX )`: this image has no /sh in the
# root for a subshell to spawn.
RDXSCR1_TEXT = (
    'EXEC > /mnt/MAUX/RDQ 2> /mnt/MAUX/RDR\r'
    'ECHO eq\r'
    'CAT /mnt/MAUX/NOSUCHR\r'
    'EXIT\r'
)
RDXSCR2_TEXT = (
    'EXEC 2>&1 > /mnt/MAUX/RDT\r'
    'ECHO et\r'
    'CAT /mnt/MAUX/NOSUCHR\r'
    'EXIT\r'
)
# RDXSCR3 -- `N<F` (KFIX3 item 2): RDF and RDA (both hold `RDF1`
# by now) open for reading on fds 3 and 4, read back through the
# existing `<&M` and the new `N<&M` forms. Two DIFFERENT files: the
# kernel will not open a file a second time while a read of it is
# still held (`exec 3<F 4<F` is `exec: cannot redirect`, measured).
RDXSCR3_TEXT = (
    'EXEC 3</mnt/MAUX/RDF 4</mnt/MAUX/RDA\r'
    'CAT <&3\r'
    'CAT 0<&4\r'
    'EXIT\r'
)

# ---------------------------------------------------------------------
# RDXSCR4 -- A LATER FILE REDIRECT MUST NOT CLOSE AN EARLIER ONE'S TARGET
# (KFIX3 review B1). The shell opens each redirect's file on the lowest
# free fd, dups it onto the named fd in the child, then closes the
# child's inherited copy of the fresh number. When an EARLIER redirect
# in the same command had named that very number as its TARGET, the
# close shut it. The child is a nested `SH` reading its script from the
# pipe (ECHO '...' | SH ...): the pipe takes fds 3 and 4 in the parent,
# so the first file opens on 5, the second on 6, the third on 7, and
# every row below lands one on the other's target:
#   1. `6<A 7>B 3>C`: B opens on 6 (A's target), C opens on 7 (B's).
#      The child reads A and writes B and C -- AAA, w7, w3.
#   2. `6>A 2>B`: B opens on 6, A's target. The child writes to fd 6
#      and to stderr -- w6 in A, w2 in B. (The M markers separate
#      what the child printed from what CAT reads back: a write that
#      fell on the tty looks the same as one read from the file.)
#   3. `5>N 6>&2 6>C`: C opens on 6, the number `6>&2` already
#      installed. The old shortcut (the open landed on its own target,
#      so skip) left fd 6 on stderr. d6 must be in C.
# The helper's fds are 3, 6 and 7: a child `SH` uses 4 and 5 itself
# (measured: `4<F` and `5<F` reach it with the script's own bytes).
# Reuses RDA/RDB/RDC/RDN: a fourth file name costs a block this image
# does not have.
# ---------------------------------------------------------------------
RDXSCR4_TEXT = (
    'ECHO AAA > /mnt/MAUX/RDA\r'
    "ECHO 'CAT <&6;ECHO w7 >&7;ECHO w3 >&3' | SH "
    '6</mnt/MAUX/RDA 7>/mnt/MAUX/RDB 3>/mnt/MAUX/RDC\r'
    'ECHO M0\r'
    'CAT /mnt/MAUX/RDB\r'
    'ECHO M1\r'
    'CAT /mnt/MAUX/RDC\r'
    "ECHO 'ECHO w6 >&6;ECHO w2 >&2' | SH "
    '6>/mnt/MAUX/RDA 2>/mnt/MAUX/RDB\r'
    'ECHO M2\r'
    'CAT /mnt/MAUX/RDA\r'
    'ECHO M3\r'
    'CAT /mnt/MAUX/RDB\r'
    "ECHO 'ECHO d6 >&6' | SH "
    '5>/mnt/MAUX/RDN 6>&2 6>/mnt/MAUX/RDC\r'
    'CAT /mnt/MAUX/RDC\r'
    'EXIT\r'
)

# ---------------------------------------------------------------------
# SIGSCR / KSCR -- a FOREGROUND death by signal is NAMED (KFIX3 item
# 3). KSCR kills the shell that runs it (`KILL -$1 $$`, so `SH -s N <
# KSCR` dies of signal N); SIGSCR runs it six times and echoes `$?`.
# The name goes to the parent's stderr (SIGERR) the way V7's await()
# prints it: `Killed`, `Terminated`, `Trace/BPT trap`, `Hangup` -- and
# NOTHING for 2 (the interrupt, `^C` already shows) and 13 (the broken
# pipe). The statuses are $80|signo, unchanged.
# ---------------------------------------------------------------------
KSCR_TEXT = (
    'KILL -$1 $$\r'
    'EXIT\r'
)
SIGSCR_TEXT = (
    'SH -s 9 < /mnt/MAUX/KSCR\r'
    'ECHO K9:$?\r'
    'SH -s 15 < /mnt/MAUX/KSCR\r'
    'ECHO K15:$?\r'
    'SH -s 5 < /mnt/MAUX/KSCR\r'
    'ECHO K5:$?\r'
    'SH -s 2 < /mnt/MAUX/KSCR\r'
    'ECHO K2:$?\r'
    'SH -s 13 < /mnt/MAUX/KSCR\r'
    'ECHO K13:$?\r'
    'SH -s 1 < /mnt/MAUX/KSCR\r'
    'ECHO K1:$?\r'
    'EXIT\r'
)

# ---------------------------------------------------------------------
# BLTMAIN -- the third image's own /mnt/MAUX/SCRIPT. Every case is a
# nested shell; see this section's banner for why each one needs its
# own.
# ---------------------------------------------------------------------
BLTMAIN_TEXT = (
    'SH < /mnt/MAUX/BLTSCR >> /mnt/MAUX/RESULTS\r'
    'ECHO BLTDONE >> /mnt/MAUX/RESULTS\r'
    'SH < /mnt/MAUX/XSCR\r'
    'CAT /mnt/MAUX/XOUT >> /mnt/MAUX/RESULTS\r'
    'SH < /mnt/MAUX/XSCR2 >> /mnt/MAUX/RESULTS\r'
    'ECHO XE:$? >> /mnt/MAUX/RESULTS\r'
    'SH < /mnt/MAUX/XSCR3 > /mnt/MAUX/XERR\r'
    'CAT /mnt/MAUX/XERR >> /mnt/MAUX/RESULTS\r'
    'SH < /mnt/MAUX/TMSCR > /mnt/MAUX/TIMESOUT\r'
    'SH < /mnt/MAUX/ERRSCR 2> /mnt/MAUX/BLTERR\r'
    'SH < /mnt/MAUX/ALISCR >> /mnt/MAUX/RESULTS\r'
    'ECHO ALIDONE >> /mnt/MAUX/RESULTS\r'
    'SH < /mnt/MAUX/ALI2SCR >> /mnt/MAUX/RESULTS\r'
    'ECHO ALI2DONE >> /mnt/MAUX/RESULTS\r'
    'SH < /mnt/MAUX/ALIERRS 2> /mnt/MAUX/ALIERRF\r'
    'SH < /mnt/MAUX/BIN/FULLSCR 2> /mnt/MAUX/BIN/FULLERF\r'
    'SH < /mnt/MAUX/NSPSCR >> /mnt/MAUX/RESULTS\r'
    'SH < /mnt/MAUX/NSPERRS 2> /mnt/MAUX/NSPERRF\r'
    'SH < /mnt/MAUX/NSPXSCR\r'
    'CAT /mnt/MAUX/XOUT2 >> /mnt/MAUX/RESULTS\r'
    'ECHO NSPDONE >> /mnt/MAUX/RESULTS\r'
    'SH < /mnt/MAUX/RDRSCR >> /mnt/MAUX/RESULTS\r'
    'SH < /mnt/MAUX/RDXSCR1\r'
    'CAT /mnt/MAUX/RDQ >> /mnt/MAUX/RESULTS\r'
    'CAT /mnt/MAUX/RDR >> /mnt/MAUX/RESULTS\r'
    'SH < /mnt/MAUX/RDXSCR2 >> /mnt/MAUX/RESULTS\r'
    'CAT /mnt/MAUX/RDT >> /mnt/MAUX/RESULTS\r'
    'SH < /mnt/MAUX/RDXSCR3 >> /mnt/MAUX/RESULTS\r'
    'SH < /mnt/MAUX/RDXSCR4 >> /mnt/MAUX/RESULTS\r'
    'ECHO RDRDONE >> /mnt/MAUX/RESULTS\r'
    'SH < /mnt/MAUX/SIGSCR >> /mnt/MAUX/RESULTS 2> /mnt/MAUX/SIGERR\r'
    'ECHO SIGDONE >> /mnt/MAUX/RESULTS\r'
    'ECHO BLTEND >> /mnt/MAUX/RESULTS\r'
    'EXIT\r'
)


def _hb(text):
    return bytes((ord(c) | 0x80) if c != '\r' else 0x8D for c in text)


BLTSCR_BYTES = _hb(BLTSCR_TEXT)
ERRSCR_BYTES = _hb(ERRSCR_TEXT)
XSCR_BYTES = _hb(XSCR_TEXT)
XSCR2_BYTES = _hb(XSCR2_TEXT)
XSCR3_BYTES = _hb(XSCR3_TEXT)
TMSCR_BYTES = _hb(TMSCR_TEXT)
BLTMAIN_BYTES = _hb(BLTMAIN_TEXT)
ALISCR_BYTES = _hb(ALISCR_TEXT)
ALI2SCR_BYTES = _hb(ALI2SCR_TEXT)
ALIERRS_BYTES = _hb(ALIERRS_TEXT)
NSPSCR_BYTES = _hb(NSPSCR_TEXT)
NSPERRS_BYTES = _hb(NSPERRS_TEXT)
FULLSCR_BYTES = _hb(FULLSCR_TEXT)
NSPXSCR_BYTES = _hb(NSPXSCR_TEXT)
RDRSCR_BYTES = _hb(RDRSCR_TEXT)
RDXSCR1_BYTES = _hb(RDXSCR1_TEXT)
RDXSCR2_BYTES = _hb(RDXSCR2_TEXT)
RDXSCR3_BYTES = _hb(RDXSCR3_TEXT)
RDXSCR4_BYTES = _hb(RDXSCR4_TEXT)
KSCR_BYTES = _hb(KSCR_TEXT)
SIGSCR_BYTES = _hb(SIGSCR_TEXT)

EXPECT_RESULTS3 = (
    hilines('ECHO is a shell builtin') +   # the builtin beats the
                                           # binary of the same name
    hilines('CAT is /bin/CAT') +         # PATHTAB's second entry
    hilines('IF is a shell keyword') +     # CHCK_RESERVED's own table
    hilines('CMP is /bin/CMP') +         # two operands, one call
    hilines('GREP is /bin/GREP') +
    hilines('TY0:0') +                     # all found -> 0
    hilines('TY1:1') +                     # NOSUCHCMD -- nothing on
                                           # stdout, SHERR carries the
                                           # diagnostic, status 1
    hilines('/bin/CAT is /bin/CAT') +  # a '/' name is PROBED
    hilines('TY2:1') +                     # ...and a missing one is
                                           # still "not found"
    hilines('CD is a shell builtin') +     # `command -V` == `type`
    hilines('/bin/CAT') +                # `command -v`, terse
    hilines('ECHO') +                      # a builtin prints as its
                                           # own word, not a path
    hilines('CM1:1') +                     # silent failure, status 1
    hilines('CMDRAN') +                    # the plain form reached the
    hilines('CM2:0') +                     # ECHO BUILTIN
    hilines('TY3:1') +                     # `type ... > FILE` refused
    hilines('EV1 EVX') +                   # pass 1 expanded $X
    hilines('EV2 EVX') +                   # '$X' survived pass 1 and
                                           # pass 2 expanded it
    hilines('EV3') +                       # ...and `; ECHO NOTREACHED`
                                           # did NOT run: eval replaces
                                           # the rest of its own line
    hilines('RO1:RV1.1') +                 # assignment refused, old
                                           # value intact, $? 1
    hilines('RO2:RV1.1') +                 # `unset` refused the same
    hilines('RO3:SV1') +                   # NAME=VALUE assigns+marks
    hilines('readonly R=RV1') +            # the listing, in slot order
    hilines('readonly S=SV1') +
    hilines('BLTDONE') +
    hilines('XO1') +                       # `exec > FILE` stuck across
    hilines('XO2') +                       # TWO later commands
    hilines('XEXEC') +                     # `exec CMD` ran it...
    hilines('XE:0') +                      # ...and left the shell 0,
                                           # with NOTREACHED absent
    hilines(DIFFMSG) +                     # `exec 2>&1`: a CHILD's
                                           # stderr followed fd 1
    hilines("alias e1='echo ONE'") +       # bare `alias` lists
    hilines('ONE two') +                   # first word expanded
    hilines("alias e1='echo ONE'") +       # `alias NAME` prints one
    hilines('hi2') +                       # trailing blank: `y` too
    hilines('ALIASED /mnt/MAUX/QF') +         # unquoted cat IS the alias
    hilines('FILEBODY') +                  # 'cat' is not expanded
    hilines('FILEBODY') +                  # \cat is not expanded
    hilines('REC a') +                     # recursion stops at once
    hilines('A2') +                        # unalias removed it
    hilines("alias q='echo it'\\''s'") +   # a value's quote reads back
    hilines('AN:1') +
    hilines('UN:1') +
    hilines('UE:0') +
    hilines("alias x='echo '") +           # slot order, e1 is gone
    hilines("alias y='hi2'") +
    hilines("alias cat='echo ALIASED'") +
    hilines("alias q='echo it'\\''s'") +
    hilines('UA:0') +                      # `unalias -a` emptied it
    hilines('SUB:') +                      # a subshell has no aliases
    hilines('H0:0') +
    hilines('H1:0') +
    hilines('H2:0') +
    hilines('H3:1') +
    hilines('FC:2') +
    hilines('ALIDONE') +
    hilines('FULL:1') +                    # ninth alias refused
    hilines('RE:0') +                      # redefinition needs no slot
    hilines('LONG:1') +                    # LINEMAX overflow: error
    hilines("alias a1='0123456789012345678901234567890'") +
    hilines('ALI2DONE') +
    hilines('hi') +                        # NSPSCR: `ECHO hi>F`
    hilines('hi') + hilines('ap') +        # `>>F`, then `CAT <F`
    hilines(DIFFMSG) +                     # `CAT X 2>F`: fd 2 only
    hilines('a2') +                        # `a2>F`: word a2, fd 1
    hilines('dupd') +                      # `2>F>&2`: a glued dup
    hilines('s1') + hilines('s2') +        # `;`
    hilines('a1') + hilines('a2') +        # `&&`
    hilines('x') +                         # `||` skips the right
    hilines('bgx') +                       # `...F&` then WAIT
    hilines('q>r') +                       # quoted/escaped operators
    hilines('s;t') +                       # are CONTENT, not splits
    hilines('u>v') +
    hilines('w;x') +
    hilines('<y z&&z') +
    hilines('1') +                         # `X=1;Y=$(...)`: two
    hilines('/mnt/MAUX/NSF6') +            # assignments, not one
    hilines('sub') +                       # `>$(...)` redirects
    hilines('N1') + hilines('N2') +        # `nl1;ECHO N2`: the alias
    hilines('N1') +                        # `nl1>F`, then CAT F
    hilines('z') + hilines('N1') +         # `ECHO z;nl1`
    hilines('N1') + hilines('N1') +        # `nl1&&nl1`
    hilines('N1') +                        # `nl1|CAT` (the old form)
    hilines('nl1') + hilines('nl1') +      # an ARGUMENT is no alias
    hilines('nl1;nl1') +                   # a quoted one is content
    hilines('1') + hilines('2') +          # `1;ECHO 2`, `3|CAT`,
    hilines('3') +                         # `4&&ECHO 5`: a lone digit
    hilines('4') + hilines('5') +          # before them is a WORD
    hilines('8') +                         # NSPERRS: `ECHO 8 >F`
    hilines('E8:1') + hilines('E10:1') +   # `8>F` `10>F`: refused
    hilines('E2L:0') +                     # `2<F`: fd 2 from F, since
                                           # KFIX3 item 2 (was refused)
    hilines('E8L:1') +                     # `8<F`: no such fd, refused
    hilines('2<<EOF') + hilines('2<<-EOF') +   # `2<<W`: a plain word
    hilines('EPOOL:1') + hilines('ETOK:1') +   # full pool / MAXTOK
    hilines('E31:0') + hilines(NSPW31) +       # 31 args run whole
    hilines('E31P:0') + hilines(NSPW31) +      #   ... and piped
    hilines('E32:1') + hilines('E32P:1') +     # 32 refused: no run
    hilines('XU1') +                       # `EXEC >F`: no blank
    hilines('NSPDONE') +
    hilines('RA:1') +                      # RDRSCR: `> A 2> B`
    hilines('RDF1') +                      # A holds the stdout
    hilines(DIFFMSGR) +                    # B holds the stderr
    hilines(DIFFMSGR) +                    # `2> A > B`: A the stderr
    hilines('RDF1') +                      # B the stdout
    hilines('RDF1') + hilines('RDF2') +    # `>> B 2> C` appended
    hilines('RDF1') + hilines(DIFFMSGR) +  # `> A 2>&1`: both in A
    hilines(DIFFMSGR) +                    # `2>&1 > B | CAT`: the pipe
    hilines('RDF1') +                      # gets stderr, B stdout
    hilines('RDF1') +                      # `2> C | CAT`: the pipe
    hilines(DIFFMSGR) +                    # gets stdout, C stderr
    hilines('g1') +                        # `> A > B`: A made EMPTY
                                           # (nothing printed for it),
                                           # B holds the output
    hilines('RDF1') + hilines(DIFFMSGR) +  # `> A 2> B 3> N`: three
    hilines('N3YES') +
    hilines('RDF1') +                      # `< I > O 2> E`: O has it,
                                           # E is empty (no line)
    hilines('RDF1') +                      # `0<F` is `<F`
    hilines('T1') +                        # `TEST X >A >B 2>C`: all
                                           # three emptied, no q-line
    hilines('eq') + hilines(DIFFMSGR) +    # `exec > Q 2> R`
    hilines(DIFFMSGR) +                    # `exec 2>&1 > T`: stderr
    hilines('et') +                        # went to the OLD stdout,
                                           # only `et` is in T
    hilines('RDF1') + hilines('RDF1') +    # `exec 3<F 4<F`, then
                                           # `<&3` and `0<&4`
    hilines('AAA') +                       # RDXSCR4 row 1: the child
                                           # read A (it prints at once)
    hilines('M0') + hilines('w7') +        # ... and wrote B
    hilines('M1') + hilines('w3') +        # ... and C
    hilines('M2') + hilines('w6') +        # row 2: `6>A 2>B`; a w6
    hilines('M3') + hilines('w2') +        # that printed BEFORE M2
                                           # went to the tty instead
    hilines('d6') +                        # row 3: `6>&2 6>C`
    hilines('RDRDONE') +
    hilines('K9:137') + hilines('K15:143') +   # SIGSCR: the statuses
    hilines('K5:133') + hilines('K2:130') +    # are $80|signo
    hilines('K13:141') + hilines('K1:129') +   # (the NAMES are in
    hilines('SIGDONE') +                       #  SIGERR, not here)
    hilines('BLTEND')
)


def build_blt_image():
    """Third, minimal image -- see the big banner comment above."""
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXSHLANG.SYSTEM'),
        (SH_BIN, 'sh userland binary'),
        (ECHO_BIN, 'echo userland binary'),
        (CAT_BIN, 'cat userland binary'),
        (CMP_BIN, 'cmp userland binary'),
        (GREP_BIN, 'grep userland binary'),
        (KILL_BIN, 'kill userland binary'),
        (SLEEP_BIN, 'sleep userland binary'),
    ]:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2

    new_volume(OUT_IMG3)
    prodos.mount(OUT_IMG3)
    root = f'/mnt/{CARRIER_VOL}'

    def rm_recursive(path, entry):
        if entry.is_dir():
            for child in list(prodos.scandir(path)):
                rm_recursive(f'{path}/{child.name}', child)
            prodos.rmdir(path)
        else:
            prodos.remove(path)

    for entry in list(prodos.scandir(root)):
        if entry.name.upper() == 'PRODOS':
            continue
        rm_recursive(f'{root}/{entry.name}', entry)

    for name, path, ftype, atype in [
        ('PRODOS', KERNEL_BIN, 0xFF, 0x2000),
        ('MAUX.SYSTEM', SYS_BIN, 0xFF, 0x2000),
        ('BIN/SH', SH_BIN, 0x06, 0x0800),
        ('BIN/ECHO', ECHO_BIN, 0x06, 0x0800),
        ('BIN/CAT', CAT_BIN, 0x06, 0x0800),
        ('BIN/CMP', CMP_BIN, 0x06, 0x0800),
        ('BIN/GREP', GREP_BIN, 0x06, 0x0800),
        ('BIN/KILL', KILL_BIN, 0x06, 0x0800),
        ('BIN/SLEEP', SLEEP_BIN, 0x06, 0x0800),
    ]:
        if name.startswith('BIN/') and name == 'BIN/SH':
            prodos.mkdir(f'{root}/BIN')
        with open(path, 'rb') as f:
            prodos.write(f'{root}/{name}', f.read(), file_type=ftype,
                         aux_type=atype, overwrite=True)

    for name, data in [
        ('SCRIPT', BLTMAIN_BYTES),
        ('BLTSCR', BLTSCR_BYTES),
        ('ERRSCR', ERRSCR_BYTES),
        ('XSCR', XSCR_BYTES),
        ('XSCR2', XSCR2_BYTES),
        ('XSCR3', XSCR3_BYTES),
        ('TMSCR', TMSCR_BYTES),
        ('ALISCR', ALISCR_BYTES),
        ('ALI2SCR', ALI2SCR_BYTES),
        ('ALIERRS', ALIERRS_BYTES),
        ('NSPSCR', NSPSCR_BYTES),
        ('NSPERRS', NSPERRS_BYTES),
        ('BIN/FULLSCR', FULLSCR_BYTES),
        ('NSPXSCR', NSPXSCR_BYTES),
        ('RDRSCR', RDRSCR_BYTES),
        ('RDXSCR1', RDXSCR1_BYTES),
        ('RDXSCR2', RDXSCR2_BYTES),
        ('RDXSCR3', RDXSCR3_BYTES),
        ('RDXSCR4', RDXSCR4_BYTES),
        ('KSCR', KSCR_BYTES),
        ('SIGSCR', SIGSCR_BYTES),
    ]:
        prodos.write(f'{root}/{name}', data, file_type=0x04,
                     aux_type=0x0000, overwrite=True)
    prodos.unmount(CARRIER_VOL)

    print(f'[build-shlang-b] {OUT_IMG3} ready '
          f'({os.path.getsize(OUT_IMG3)} bytes)')
    return check_free_margin(OUT_IMG3, 'blt')


def build_hd_image():
    """Second, minimal image -- see the big banner comment above."""
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXSHLANG.SYSTEM'),
        (SH_BIN, 'sh userland binary'),
        (ECHO_BIN, 'echo userland binary'),
        (CAT_BIN, 'cat userland binary'),
        (CMP_BIN, 'cmp userland binary'),
        (GREP_BIN, 'grep userland binary'),
        (ED_BIN, 'ed userland binary'),
    ]:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2

    new_volume(OUT_IMG2)
    prodos.mount(OUT_IMG2)
    root = f'/mnt/{CARRIER_VOL}'

    for entry in list(prodos.scandir(root)):
        if entry.name.upper() == 'PRODOS':
            continue

        def rm_recursive(path, entry):
            if entry.is_dir():
                for child in list(prodos.scandir(path)):
                    rm_recursive(f'{path}/{child.name}', child)
                prodos.rmdir(path)
            else:
                prodos.remove(path)
        rm_recursive(f'{root}/{entry.name}', entry)

    with open(KERNEL_BIN, 'rb') as f:
        kernel = f.read()
    with open(SYS_BIN, 'rb') as f:
        system = f.read()
    with open(SH_BIN, 'rb') as f:
        shbin = f.read()
    with open(ECHO_BIN, 'rb') as f:
        echobin = f.read()
    with open(CAT_BIN, 'rb') as f:
        catbin = f.read()
    with open(CMP_BIN, 'rb') as f:
        cmpbin = f.read()
    with open(GREP_BIN, 'rb') as f:
        grepbin = f.read()
    with open(ED_BIN, 'rb') as f:
        edbin = f.read()

    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    try:                      # docs/VROOT.md: programs live in BIN
        prodos.mkdir(f'{root}/BIN')
    except FileExistsError:
        pass
    prodos.write(f'{root}/BIN/SH', shbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/ECHO', echobin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/CAT', catbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/CMP', cmpbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/GREP', grepbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/ED', edbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/SCRIPT', HDXSCRIPT_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/MGSCRIPT', MGSCRIPT_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/NESTSCRIPT', NESTSCRIPT_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/EMPTYF', b'', file_type=0x04,
                 aux_type=0x0000)
    prodos.write(f'{root}/OPS', OPS_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/MGFILE', MGFILE_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/TNL', TNL_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    for name, data in DEEP_BYTES.items():
        prodos.write(f'{root}/{name}', data, file_type=0x04,
                     aux_type=0x0000, overwrite=True)
    # Compound redirection's own inputs (sec 18) -- see their own
    # headers above for why CDATA has three unequal lines and why
    # CAPP is staged non-empty.
    prodos.write(f'{root}/CDATA', CDATA_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/CAPP', CAPP_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    # The `read` gate's own script (sec 16). Sourced with `.` from
    # SCRIPT so that CUR_IN_FD and fd 0 are different open files --
    # see RDCASES_TEXT's own header for why that is the assertion.
    prodos.write(f'{root}/IFSDATA', IFSDATA_BYTES, file_type=0x04,
                 aux_type=0x0000)
    prodos.write(f'{root}/RDCASES', RDCASES_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.unmount(CARRIER_VOL)

    print(f'[build-shlang-hd] {OUT_IMG2} ready '
          f'({os.path.getsize(OUT_IMG2)} bytes)')
    return check_free_margin(OUT_IMG2, 'hd')


def main():
    for path, label in [
        (CARRIER_IMG, 'carrier volume'),
        (KERNEL_BIN, 'vendored ProDOS kernel'),
        (SYS_BIN, 'MAUXSHLANG.SYSTEM'),
        (SH_BIN, 'sh userland binary'),
        (ECHO_BIN, 'echo userland binary'),
        (CAT_BIN, 'cat userland binary'),
        (CMP_BIN, 'cmp userland binary'),
        (GREP_BIN, 'grep userland binary'),
        (ED_BIN, 'ed userland binary'),
    ]:
        if not os.path.exists(path):
            print(f'error: missing {label}: {path}', file=sys.stderr)
            return 2

    new_volume(OUT_IMG)
    prodos.mount(OUT_IMG)
    root = f'/mnt/{CARRIER_VOL}'
    removed = []
    kept = []

    def rm_recursive(path, entry):
        if entry.is_dir():
            for child in list(prodos.scandir(path)):
                rm_recursive(f'{path}/{child.name}', child)
            prodos.rmdir(path)
        else:
            prodos.remove(path)

    for entry in list(prodos.scandir(root)):
        if entry.name.upper() == 'PRODOS':
            kept.append(entry.name)
            continue
        rm_recursive(f'{root}/{entry.name}', entry)
        removed.append(entry.name)

    with open(KERNEL_BIN, 'rb') as f:
        kernel = f.read()
    with open(SYS_BIN, 'rb') as f:
        system = f.read()
    with open(SH_BIN, 'rb') as f:
        shbin = f.read()
    with open(ECHO_BIN, 'rb') as f:
        echobin = f.read()
    with open(CAT_BIN, 'rb') as f:
        catbin = f.read()
    with open(CMP_BIN, 'rb') as f:
        cmpbin = f.read()
    with open(GREP_BIN, 'rb') as f:
        grepbin = f.read()
    with open(ED_BIN, 'rb') as f:
        edbin = f.read()

    prodos.write(f'{root}/PRODOS', kernel, file_type=0xFF, aux_type=0x2000,
                 overwrite=True)
    prodos.write(f'{root}/MAUX.SYSTEM', system, file_type=0xFF,
                 aux_type=0x2000, overwrite=True)
    try:                      # docs/VROOT.md: programs live in BIN
        prodos.mkdir(f'{root}/BIN')
    except FileExistsError:
        pass
    prodos.write(f'{root}/BIN/SH', shbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/ECHO', echobin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/CAT', catbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/CMP', cmpbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/GREP', grepbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)
    prodos.write(f'{root}/BIN/ED', edbin, file_type=0x06, aux_type=0x0800,
                 overwrite=True)

    prodos.write(f'{root}/F1', F1_BYTES, file_type=0x04, aux_type=0x0000,
                 overwrite=True)
    prodos.write(f'{root}/F2', F2_BYTES, file_type=0x04, aux_type=0x0000,
                 overwrite=True)
    prodos.write(f'{root}/F3', F3_BYTES, file_type=0x04, aux_type=0x0000,
                 overwrite=True)
    prodos.write(f'{root}/F4', F4_BYTES, file_type=0x04, aux_type=0x0000,
                 overwrite=True)
    prodos.write(f'{root}/F5', F5_BYTES, file_type=0x04, aux_type=0x0000,
                 overwrite=True)
    prodos.write(f'{root}/SCRIPT', SCRIPT_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/DOTFILE', DOTFILE_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/HDBAD', HDBAD_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/TR3SCRIPT', TR3SCRIPT_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    # /mnt/MAUX/SHERR is NOT pre-staged -- the outer script's own `2>` on
    # the nested `SH < TR3SCRIPT` spawn creates it fresh (OPEN_REDIR_WR:
    # unlink-if-exists then create), same as ERRS1/ERRS2 never are.
    # `test -d` / `[ -d ]` target -- a real directory, so TE_GFI's
    # storage_type check has something to say yes to.
    prodos.mkdir(f'{root}/TDIR')
    # A file INSIDE TDIR, so `cd`'s claim can be checked by a
    # relative read rather than by what `pwd` echoes back.
    prodos.write(f'{root}/TDIR/TDF1', TDF1_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    # TDIR/SUB: one level DEEPER, so `cd ../..` from here lands at
    # the volume root (a real ProDOS directory) rather than at the
    # pseudo-root "/" one level ABOVE it (docs/DEVFS.md,
    # 2026-09-30) -- see the `cd ../..` comment below for why this
    # moved.
    prodos.mkdir(f'{root}/TDIR/SUB')

    prodos.write(f'{root}/TGT2', TGT2_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    prodos.write(f'{root}/TGT3', TGT3_BYTES, file_type=0x04,
                 aux_type=0x0000, overwrite=True)
    for name in GROWING_FILES:
        prodos.write(f'{root}/{name}', b'', file_type=0x04,
                     aux_type=0x0000, overwrite=True)
    for name in GLOB_S_FILES:
        prodos.write(f'{root}/{name}', b'', file_type=0x04,
                     aux_type=0x0000, overwrite=True)
    prodos.unmount(CARRIER_VOL)

    print(f'[build-shlang] carrier={CARRIER_IMG} volname={CARRIER_VOL}')
    print(f'[build-shlang] kept={kept} removed={removed}')
    print(f'[build-shlang] wrote MAUX.SYSTEM ({len(system)}B), '
          f'SH ({len(shbin)}B), ECHO ({len(echobin)}B), '
          f'CAT ({len(catbin)}B), CMP ({len(cmpbin)}B), '
          f'GREP ({len(grepbin)}B), ED ({len(edbin)}B)')
    print(f'[build-shlang] {OUT_IMG} ready '
          f'({os.path.getsize(OUT_IMG)} bytes)')
    return check_free_margin(OUT_IMG, 'shlang')


if __name__ == '__main__':
    rc = main()
    if rc:
        raise SystemExit(rc)
    rc = build_hd_image()
    if rc:
        raise SystemExit(rc)
    raise SystemExit(build_blt_image())
