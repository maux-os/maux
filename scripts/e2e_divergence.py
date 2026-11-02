#!/usr/bin/env python3
"""The divergence ratchet, and the comparators the entries authorise.

docs/E2E.md sec 4:

    A blanket "we differ from POSIX" defeats the whole exercise, because
    every real bug hides in it.  So divergence is a **ratchet, per entry,
    with a reason** ... An unexplained difference is a **failure**, not a
    diff to eyeball.  A difference someone has argued for is an entry.
    Adding an entry is a decision with a name on it; that is the point.

Same shape as `scripts/check_purity.py`'s BIN_DEBT/LIBA_DEBT: a dict
nobody can add to silently.  Two invariants the runner enforces
(scripts/check_e2e.py):

  * a case citing a key that is not in DIVERGENCE is an ERROR -- you
    cannot invent a reason at the call site;
  * a non-global key that no case cites is reported as DEAD -- the
    ratchet only tightens, and an entry that stopped being needed should
    be deleted rather than left as cover for the next difference.

Three grades of entry, and the grade matters because they buy different
amounts of oracle:

  DISCHARGED  the difference is removed by asking the reference the right
              question in the first place (LC_ALL=C for collation, `od -t
              x1` for a byte-wise hex dump).  Full oracle strength: the
              host still computes the answer.
  STRUCTURAL  the two outputs carry the SAME information in different
              framing, so the comparator parses both and compares the
              information (wc's integers, od's rows, uniq's counts).
              Full oracle strength for the values; the framing is no
              longer checked, which is why each entry says so.
  RULED       maux's documented behaviour genuinely differs, and the
              expectation is derived from the reference by a named,
              minimal transform (comm's column re-packing, diff's
              no-newline marker).  Weaker: the transform is ours.  Keep
              these few and keep them small.
"""
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e_limits as L  # noqa: E402

GREP_LINEMAX = L.limit('grep', 'LINEMAX')

#: (tool, axis) -> (grade, reason).  '*' is every tool.
DIVERGENCE = {
    # ---- global: true of every case, not cited individually ----------
    ('*', 'text encoding'): (
        'DISCHARGED',
        "maux text is high-bit ASCII with $8D line endings; the host's is "
        "low-ASCII with $0A. scripts/e2e_compare.decode_maux_text is the "
        "ONE place this is normalised, and it is deliberately ungenerous: "
        "a byte WITHOUT bit 7 set in a text output is reported as a "
        "failure with its offset rather than passed through, because a "
        "normaliser that accepts both encodings cannot see uninitialised "
        "state -- which is exactly `tr`'s 2026-08-23 bug."),
    ('*', 'pathname'): (
        'DISCHARGED',
        "maux prints the ProDOS path it was given (/mnt/MAUX/E2E/FDA); the "
        "reference prints the host temp path. The reference's output has "
        "its own temp-directory prefix rewritten to the image prefix "
        "before comparison -- a pure textual substitution of the argv the "
        "two sides were handed, nothing about their behaviour."),
    ('sort', 'locale collation'): (
        'DISCHARGED',
        "byte order only; no locales (docs/ANACHRONISMS.md). The "
        "reference is run under LC_ALL=C/LANG=C so it collates by byte "
        "too. maux's bytes are the host's with bit 7 set, which is a "
        "monotonic map, so the orders coincide."),

    # ---- structural: same information, different framing -------------
    ('sh', 'a pid VALUE cannot agree across machines'): (
        'STRUCTURAL',
        "maux's pid IS the process's RamWorks bank number (one 64K aux "
        "bank per process, docs/ARCHITECTURE.md); the host's is a Unix "
        "pid from a global counter. No correct implementation of either "
        "could make the two agree, so an exact compare would be asserting "
        "something false. Compared by cmp_sh_pid_pair, which checks only "
        "what IS true of any correct shell: `$$` twice on one line gives "
        "two equal, non-empty, all-digit, NON-ZERO fields. Non-zero is "
        "load-bearing rather than fussy -- the BANK_ID cross-flip bug "
        "fixed in 336fe38 made every bank report exactly `0`, and `0 0` "
        "satisfies every other property in that list."),
    ('sh', 'a closed-stdin error code is implementation-specific'): (
        'STRUCTURAL',
        "`CAT <&-` (docs/SH-FEATURES.md, 2026-09-15): this host's own "
        "cat checks its read() return and exits 1 ('Bad file "
        "descriptor'); maux's cat/wc/od share a REFILL idiom (wc.s) "
        "that folds a READ ERROR into the same branch as ZERO BYTES "
        "TRANSFERRED, so a closed fd 0 reads EXACTLY like ordinary "
        "EOF -- $? is a deterministic 0, a real, separate, pre-"
        "existing gap this feature EXPOSED rather than caused. "
        "Compared by cmp_sh_closed_fd, which checks the reference is "
        "nonzero (POSIX; the construct means something to a correct "
        "shell) and maux is EXACTLY 0 (this gap, not a flaky answer) "
        "-- proof the `<&-` close itself took effect belongs to the "
        "live emulator session instead, where a closed fd 0 visibly "
        "does not block waiting on the console the way `<&0` does."),
    ('wc', 'field padding'): (
        'STRUCTURAL',
        "liba has no printf and PRNUM suppresses leading zeros with no "
        "padding (src/liba/num.s), so wc emits `3 3 14` where BSD wc "
        "emits width-8 right-aligned columns. Compared as parsed "
        "whitespace-separated fields; the COLUMN WIDTHS are not checked, "
        "the counts and their order are."),
    ('wc', 'totals saturate at 65535'): (
        'RULED',
        "wc.s GREW its totals line on 2026-09-17, so the old entry here "
        "-- 'no totals line', which dropped the reference's final `total` "
        "row and said in its own text 'delete this entry when wc grows "
        "one' -- outlived the code by two days and turned three cases "
        "RED (58/59/61) while looking like a wc defect. It is deleted; "
        "58 and 61 now check the totals line against the host with no "
        "entry at all. WHAT SURVIVES is narrower and has a NEW trigger: "
        "wc's counters are 16-bit and SATURATE at 65535 (wc.s's own "
        "COUNTER WIDTH note -- a pinned count is visibly wrong where a "
        "wrapped one looks right). That used to be unreachable, because "
        "it needed a file bigger than a process bank; the totals line "
        "makes it reachable by SUMMING ordinary files, and this case's "
        "three ~46 KB operands total 140,544. So the transform is: clamp "
        "each of the reference's `total` fields at 65535, per-file rows "
        "untouched. TRIGGER for deleting this entry: widen the counters. "
        "Nothing gates a CITED entry against its code -- only an uncited "
        "one is reported DEAD -- which is exactly how the old one hid."),
    ('uniq', 'count field width'): (
        'STRUCTURAL',
        "uniq's own PRCNT right-aligns in CNTFLD=5 then one space; BSD "
        "uniq uses width 4. Compared as (count, text) pairs parsed off "
        "each line, so the count VALUE is still the reference's."),
    ('od', 'offset radix'): (
        'STRUCTURAL',
        "src/bin/od.s prints a 4-digit uppercase HEX offset; BSD od "
        "prints a 7-digit octal one. Compared as parsed integers, so the "
        "offsets are still checked -- in the radix each side chose."),
    ('od', 'default format is byte-wise hex'): (
        'DISCHARGED',
        "od.s's own ruling: V6 od defaulted to octal 16-bit WORDS, a "
        "PDP-11 artifact; maux is a byte machine and defaults to hex "
        "BYTES, which is what V6's own -x named. The reference is asked "
        "for `od -t x1`, the byte-wise hex it already implements, rather "
        "than being forgiven a word-wise answer afterwards."),
    ('od', 'hex digit case'): (
        'STRUCTURAL',
        "src/liba/hex.s's PRHEX8 emits UPPERCASE hex digits ('print A as "
        "2 uppercase hex digits'); BSD od emits lowercase. Hex fields are "
        "compared case-insensitively. Applied ONLY to hex/octal formats "
        "-- `od -c` fields are characters, where case is the payload, and "
        "are compared verbatim."),
    ('od', 'combined formats emit one row each'): (
        'STRUCTURAL',
        "`od -bx` prints a full hex row AND a full octal row for the same "
        "16 bytes, in the fixed order hex, octal, char. The reference is "
        "run once per format and the rows interleaved in that order; "
        "every field value still comes from the host."),
    ('sum', 'blocks are 512-byte ProDOS blocks'): (
        'STRUCTURAL',
        "sum.s counts ceil(bytes/512) because 512 is a ProDOS block, this "
        "project's own unit; BSD sum counts 1024-byte blocks. The "
        "CHECKSUM is compared against the host's exactly (both are the "
        "V7/BSD ROR16 algorithm -- sum(1) algorithm 1). The block count "
        "is compared against ceil(size/BLOCKSZ) taken from the host "
        "FILESYSTEM's own size for that file, not from anything maux "
        "said and not from a number written down here."),
    ('*', 'the same file cannot be opened twice'): (
        'RULED',
        "FOUND BY THIS HARNESS, 2026-08-23, first run: `diff X X`, "
        "`comm X X` and `cmp X X` each exit 2 with `cannot open X`. "
        "ProDOS refuses a second OPEN of a file that is already open, so "
        "a tool holding both operands at once cannot be handed the same "
        "path twice. This is the PLATFORM, not the program -- and it is a "
        "real difference a user would hit, which is why it is written "
        "down rather than merely avoided. The identical-file cases use "
        "byte-identical COPIES under different names (check_comm.py's "
        "CADUP is the precedent), so the tools' identical-input "
        "behaviour is still covered."),

    ('cmp', 'line rule is $8D, not $0A'): (
        'DISCHARGED',
        "cmp's `line L` counts maux line endings ($8D) before the first "
        "differing byte; the host counts $0A. For a TEXT fixture the two "
        "coincide by construction (the encoder maps one to the other). "
        "For the BINARY fixture they do not in general, so FBIN is built "
        "as bytes(range(256)) -- exactly one $8D and exactly one $0A, "
        "both before the injected difference at offset 200 -- and the two "
        "rules agree on the answer. Move that difference earlier than "
        "offset 11 and this stops being true; the entry is here so the "
        "next person knows."),

    # ---- ruled: a named, minimal transform on the reference ----------
    ('diff', 'no-newline marker'): (
        'RULED',
        "BSD diff emits `\\ No newline at end of file`; src/bin/diff.s "
        "has no such marker. Those lines are dropped from the reference. "
        "Nothing else about the hunk is forgiven."),
    ('tr', 'complement set is over high-bit bytes'): (
        'RULED',
        "tr indexes its 256-entry tables by the RAW byte and its argv "
        "arrives high-bit-set, so `tr -c A-Z` complements {$C1..$DA} "
        "where the host complements {$41..$5A}. The two complements are "
        "isomorphic under the high-bit map ONLY while string2 is a single "
        "byte or absent -- with a multi-byte string2 the ascending "
        "pairing would land differently. The corpus therefore restricts "
        "-c cases to that form; a multi-byte -c case is out of scope for "
        "stage 1, not silently wrong."),
    ('od', '-c renders every non-printable as a dot'): (
        'RULED',
        "od.s's PRCHRDOT strips bit 7, prints $20-$7E, else a `.`; BSD od "
        "-c prints C escapes (\\n, \\0) and 3-digit octal. The corpus "
        "feeds -c printable text only, so the ONLY reference field this "
        "transform touches is `\\n` -> `.`; any other escape fails the "
        "case loudly rather than being mapped."),
    ('od', '-c whitespace tokenisation'): (
        'STRUCTURAL',
        "od -c rows are compared as whitespace-separated tokens, which "
        "cannot see a SPACE glyph (it tokenises away). The -c fixture "
        "therefore contains no space bytes. A space-carrying -c case "
        "needs a column-oriented parser; stage 2."),
    ('od', 'empty input still prints the end offset'): (
        'RULED',
        "od.s always prints the trailing offset line, `classic V6 od's "
        "own end-of-dump marker`, so empty input yields `0000`; BSD od "
        "prints nothing at all. The expected row for an empty reference "
        "is the end offset, which for empty input is 0."),
    ('grep', 'linemax truncates overlong lines'): (
        'RULED',
        "src/bin/grep.s declares LINEMAX=255 and its GETLINE drops bytes "
        "past that limit until the next CR. The reference still selects "
        "the matching lines; the comparator applies exactly that documented "
        "line truncation to the reference output and checks the result."),
    ('grep', 'open-failure continuation framing'): (
        'STRUCTURAL',
        "The behaviour under test is that grep reports an unopenable "
        "operand, continues with a later readable operand, and exits 2. "
        "BSD grep's diagnostic wording and fd ordering are not maux's, and "
        "the host is invoked with -h to isolate continuation from the "
        "separate filename-prefix defect. The comparator checks the "
        "reference-selected payload lines and requires one maux diagnostic "
        "naming the missing image path; it does not compare wording beyond "
        "the tool's own constant prefix."),
    ('tee', 'open-failure continuation framing'): (
        'STRUCTURAL',
        "The behaviour under test is that tee reports one destination it "
        "cannot open, still copies stdin to stdout, keeps later destinations "
        "eligible, and exits 1. BSD tee's diagnostic wording and stream "
        "ordering are not maux's. The comparator checks the stdout payload "
        "against the reference and requires one maux diagnostic naming the "
        "bad image path."),
    ('head', 'open-failure continuation framing'): (
        'STRUCTURAL',
        "The behaviour under test is that head reports one operand it "
        "cannot open, still prints the header and content of a later "
        "operand that DOES open, and exits 1. BSD head's diagnostic "
        "wording is not maux's ('head: PATH: No such file or directory' "
        "vs. 'head: cannot open PATH'). The comparator checks the "
        "reference-selected payload -- headers and file content alike -- "
        "and requires one maux diagnostic naming the missing image "
        "path; it does not compare wording beyond the tool's own "
        "constant prefix."),
    ('cut', 'open-failure continuation framing'): (
        'STRUCTURAL',
        "The behaviour under test is that cut reports one operand it "
        "cannot open, still prints the selected columns of a later "
        "operand that DOES open, and exits 1. BSD cut's diagnostic "
        "wording is not maux's ('cut: PATH: No such file or directory' "
        "vs. 'cut: cannot open PATH') -- and unlike head, cut has no "
        "per-file header to compare either way. The comparator checks "
        "the reference-selected payload and requires one maux "
        "diagnostic naming the missing image path; it does not compare "
        "wording beyond the tool's own constant prefix."),
    ('printf', 'numeric argument diagnostic wording'): (
        'STRUCTURAL',
        "The behaviour under test is that a non-numeric numeric "
        "argument (XCU's own example) is diagnosed, the value 0 is "
        "used in its place, and the run's own exit status is 1 -- "
        "with the rest of the format and any later arguments still "
        "processed. Both sides agree on the VALUE (0) and the exit "
        "status; only the diagnostic's own wording differs ('printf: "
        "abc: expected numeric value' on BSD, phrased identically by "
        "coincidence here but not guaranteed to stay that way, so it "
        "is not relied on). The comparator checks the non-diagnostic "
        "payload lines against the reference and requires exactly one "
        "line starting with the tool's own 'printf:' prefix on each "
        "side; it does not compare wording beyond that prefix."),
    ('tee', 'self-output reopens stdin target'): (
        'RULED',
        "The self-output sample intentionally runs `tee F < F`. The host "
        "harness has already read stdin into a pipe before tee opens its "
        "output, so BSD tee prints the original payload and exits 0. On "
        "maux the shell holds F open as fd 0 with READ intent, and since "
        "OPEN-RW-2 (2026-10-22) tee's output open JOINS that group as the "
        "one writer and truncates F -- the file it is reading -- so tee "
        "copies an empty stdin: no output, F emptied, exit 0. That is "
        "what a real Unix does with `tee F < F` (O_TRUNC before the first "
        "read); the reference differs only because the harness feeds it "
        "from a pipe read in advance. (Before OPEN-RW-2 ProDOS refused "
        "the second OPEN, tee printed `tee: cannot open PATH`, copied "
        "stdin and exited 1: the old ruling.) The case runs on its own "
        "fixture FSELF2 because it destroys it."),
    # ('echo', 'option-like arguments are literal') RETIRED 2026-09-01
    # BY THE FIX: echo.s grew -n (argv[1] only, exactly "-n") and the
    # two sides agree byte-for-byte; the case comparing them is plain
    # differential now. cmp_echo_literal went with it.
    ('tail', 'unterminated final line is normalised'): (
        'RULED',
        "src/bin/tail.s's OUTPUT POLICY appends one CR to every stored line, "
        "including a final source line without a terminator. BSD tail "
        "preserves the missing final newline, so the comparator adds exactly "
        "that terminator to the reference output."),

    # ---- coverage exclusions: named, so the gap is visible -----------
    ('uniq', 'linemax forced break'): (
        'EXCLUDED',
        "uniq.s's GETLINE returns a line the moment LINEMAX=255 bytes "
        "have accumulated and resumes on the next byte, so a 255-byte "
        "line comes back as a full line PLUS an empty one where the host "
        "sees one line. Real divergence, but stage 1 has no oracle for it "
        "(the host has no such break), so uniq/comm fixtures are capped "
        "at LINEMAX-1. Stage 2's hand-written tables are where this "
        "belongs."),
    ('comm', 'linemax forced break'): (
        'EXCLUDED',
        "as ('uniq', 'linemax forced break') -- comm.s cross-references "
        "uniq's GETLINE policy explicitly and shares LINEMAX=255."),
}

#: KNOWN DEFECTS -- deliberately NOT part of DIVERGENCE, and the
#: distinction is the point.
#:
#: A divergence entry says "maux is different here and here is the
#: argument".  A defect entry says "maux is WRONG here, this is what the
#: reference does, and nobody has fixed it yet".  Folding the second into
#: the first is exactly the blanket docs/E2E.md sec 4 forbids: it would
#: let a bug acquire a reason and stop being a bug.
#:
#: A case may cite ONE defect key.  The gate then reports that case as a
#: PINNED DEFECT rather than a failure -- loudly, by name, every run --
#: and the run stays green so the other 67 cases keep their signal.  When
#: the defect is fixed the case starts failing against this table, which
#: is the prompt to delete the entry.
#:
#: Entries are OWNED BY src/bin, which this harness does not edit.
KNOWN_DEFECTS = {
    # ('grep', 'multiple-file matches lack file-name prefixes') and
    # ('grep', '-e pattern option is not implemented') RETIRED 2026-08-24,
    # BY THE FIX, not by a re-reading: src/bin/grep.s now prefixes every
    # selected line (and every -c count) with the operand AS TYPED when
    # two or more FILEs are given, and GREPOPTS spells the -e entry so it
    # takes the RE through getopt's OPTARG. Both pinned cases started
    # AGREEING with /usr/bin/grep, which is the DEFECT-FIXED verdict, and
    # check_citations' dead-entry check is what would have caught leaving
    # these two behind. The fix also exposed a THIRD bug neither pin
    # named -- -n's line numbers and -c's count ran on across files
    # instead of restarting -- now covered by its own cases.
    # ('tr', '-s without string2 is a usage error') RETIRED 2026-08-23:
    # src/bin/tr.s now accepts a single operand under -s (the :sqonly
    # path, stream S7's getopt/tr commit) as well as under -d, so `tr -s
    # SET` squeezes and exits 0 like /usr/bin/tr. The pinned case (23)
    # started AGREEING with the reference the moment the fix landed, and
    # e2e_compare.judge's own DEFECT-FIXED verdict is what said so --
    # the registry's escape hatch caught its own expiry rather than
    # someone noticing by eye. See docs/E2E.md sec 9.9 item 2.

    ('sh', 'a ( ) group cannot be a pipeline stage'): (
        "CHCK_GROUP (src/bin/sh.s) refuses a group with NCMD != 1, i.e. "
        "one that has a `|` on its line. This path does not go through "
        "RUN_PIPELINE, which is where a stage's fd 1 is wired to the "
        "pipe, and IGNORING that is the silent wrong answer "
        "docs/SH-FEATURES.md sec 17 rules against -- measured before the "
        "check existed, `( ECHO GPIPE ) | WC` printed GPIPE and no "
        "counts, the `|` simply vanishing. LOUD refusal, never a wrong "
        "answer; pinned rather than excluded because POSIX and V7 both "
        "allow it.\n"
        "\n"
        "THIS ENTRY HAS NOW BEEN NARROWED TWICE IN ONE DAY, which is the "
        "part worth reading.\n"
        "\n"
        "It first claimed a group was refused in any COMPOUND line, on "
        "the strength of `X ; ( A ) ; Y` producing nothing. That was a "
        "DIFFERENT defect and not a refusal at all: the group span was "
        "seeded only at token 0 of the LINE, and `;` does not split "
        "before TOKENIZE, so a `(` after a separator was tokenized as an "
        "ordinary word and the line silently misparsed -- CHCK_GROUP "
        "never saw a group. Fixed in sh.s; cases 118 and 126 went "
        "DEFECT-FIXED.\n"
        "\n"
        "It then covered REDIRECTS too, on the reasoning that honouring "
        "`( ... ) > F` 'needs RUN_PIPELINE's staging'. Half true: it "
        "needs THE STAGING, not RUN_PIPELINE. Extracting STG_OUTFILE and "
        "INIT_CHLDMAP from BLD_FDCTS_STG made the identical routines "
        "reachable from SUB_GROUP for +25 bytes, and cases 116 and 117 "
        "went DEFECT-FIXED -- redirected and nested-redirected groups now "
        "agree with /bin/sh byte for byte, `2>&1` included.\n"
        "\n"
        "So a pin's stated reason is a claim about the code, and two of "
        "the three claims this one made did not survive being checked. "
        "What is left is the pipeline half, which is genuinely different: "
        "the group would have to BE a stage, not merely carry a "
        "redirect. `< FILE` is refused separately and permanently -- a "
        "group's fd 0 is the body pipe the child sh reads its script "
        "from, so there is no fd 0 to redirect."),

    ('sh', 'nested $( ) is refused'): (
        "One level of command substitution works (this section's "
        "subst-1/2/4 pass); `$(ECHO $(ECHO DEEP))` is refused and writes "
        "no output file. SUB_TRKCH counts parens without knowing the "
        "child shell's quoting or nesting depth, the same machinery "
        "behind docs/TASKS.md #18(f)'s quoted-paren limit. Closing it "
        "costs bytes sh.bin does not have (16,332 of 16,384), so it is "
        "pinned here rather than fixed -- and pinned, not excluded, "
        "because the case is legal V7 and legal POSIX."),
}

#: Entries that hold for every case and are therefore not cited per case.
GLOBAL_KEYS = {
    ('*', 'text encoding'),
    ('*', 'pathname'),
    ('sort', 'locale collation'),
    ('uniq', 'linemax forced break'),
    ('comm', 'linemax forced break'),
}


def check_citations_table(cases, table, global_keys, get_cited=None,
                          label=None):
    """Both ratchet invariants (docs/E2E.md sec 4), TABLE-DRIVEN so a
    second corpus (scripts/e2e_fs_common.py's own DIVERGENCE-shaped merge
    of the T4 filesystem tranche's per-module ENTRIES dicts) can share
    this MECHANISM without sharing this stage's TABLE -- two independent
    ratchets, same two invariants:

      * a case citing a key that is not in `table` is an ERROR -- you
        cannot invent a reason at the call site;
      * a non-global key in `table` that no case cites is DEAD -- the
        ratchet only tightens; an entry that stopped being needed should
        be deleted, not left as cover for the next difference.

    `get_cited` extracts the list of cited keys from a case (default:
    `case.diverges`, which both this stage's Case and e2e_fs_common's
    Case expose under the same attribute name -- but the extractor is a
    parameter, not an assumption, so a shape change in either Case does
    not have to stay in lockstep with the other).

    `label`, if given, names `table` in the error/dead messages (e.g.
    'DIVERGENCE', 'KNOWN_DEFECTS') so a caller checking MORE THAN ONE
    table over the same cases (check_citations()/Registry.
    check_citations() below, which now validate diverges= against a
    DIVERGENCE-shaped table AND defect= against a KNOWN_DEFECTS-shaped
    one) can tell which table an error or a dead entry came from,
    without this shared mechanism knowing either table's name itself --
    that stays the caller's business, same as `table` and `global_keys`
    already are.
    """
    if get_cited is None:
        get_cited = lambda c: c.diverges  # noqa: E731
    name = label or 'the table'
    errors, cited = [], set()
    for case in cases:
        for key in get_cited(case):
            if key not in table:
                errors.append(f'case {case.cid} ({case.tool}) cites '
                              f'{key!r}, which is not a key of {name}')
            cited.add(key)
    dead = [f'{name} {k!r}' for k in table
           if k not in global_keys and k not in cited]
    return errors, dead


def check_citations(cases):
    """This stage's own ratchet: DIVERGENCE/GLOBAL_KEYS above, PLUS
    KNOWN_DEFECTS.

    A `case.defect` pin used to be validated nowhere: `judge()` treated
    ANY non-None `case.defect` as authorising a DEFECT verdict, so a
    case mutated (or authored) with `defect=('bogus', 'no such entry')`
    silently absorbed a WRONG answer and the gate stayed green -- the
    exact blanket docs/E2E.md sec 4 forbids for `diverges=`, reached
    from the other table. Fixed the same way `diverges=` already is:
    `case.defect` must name a key of KNOWN_DEFECTS, checked with the
    SAME `check_citations_table` mechanism, over the SAME cases, just a
    different table and a different (single-value, not list) extractor.

    RULING, 2026-08-23, on the dead-entry half: KNOWN_DEFECTS gets the
    SAME ratchet-only-tightens treatment DIVERGENCE gets. An entry
    nothing cites is ambiguous cover the same way an uncited DIVERGENCE
    entry is -- either the bug it names was fixed and the entry should
    have been deleted with it, or it was never wired to a case and is
    lying about being pinned to anything. Both are failures a green run
    should surface, not silently carry forward. KNOWN_DEFECTS has no
    GLOBAL_KEYS analogue -- unlike a DIVERGENCE entry, no defect is true
    'of every case' the way text encoding or locale collation are; every
    entry here is owned by exactly the case(s) that cite it -- so its
    global_keys argument is the empty set, not GLOBAL_KEYS.

    Kept as a zero-argument-shape wrapper so every existing caller
    (check_e2e.py, e2e_selftest.py) is untouched by the table-driven
    refactor."""
    def divergence_keys(c):
        out = list(c.diverges)
        if getattr(c, 'status_ruled', None) is not None:
            out.append(c.status_ruled)
        return out

    errs, dead = check_citations_table(cases, DIVERGENCE, GLOBAL_KEYS,
                                       get_cited=divergence_keys,
                                       label='DIVERGENCE')
    d_errs, d_dead = check_citations_table(
        cases, KNOWN_DEFECTS, set(),
        get_cited=lambda c: [c.defect] if c.defect is not None else [],
        label='KNOWN_DEFECTS')
    return errs + d_errs, dead + d_dead


# ======================================================================
# Comparators.  Each returns (ok, detail).  `got` is maux's output,
# already decoded from high-bit text by e2e_compare.decode_maux_text.
# ======================================================================

def _lines(data):
    if not data:
        return []
    return data.split(b'\n')[:-1] if data.endswith(b'\n') \
        else data.split(b'\n')


def _split(data):
    """Lines PLUS whether the output was newline-terminated.

    The two must stay apart.  A comparator that tokenises -- wc's fields,
    od's rows, sum's columns -- sees `3 3 14` and `3 3 14\\n` as the same
    thing, so a maux that dropped its final $8D would pass.  The
    harness's own mutation test (scripts/e2e_selftest.py) caught exactly
    that, on eleven cases, before any of this ran on a IIe."""
    if not data:
        return [], True
    if data.endswith(b'\n'):
        return data[:-1].split(b'\n'), True
    return data.split(b'\n'), False


def cmp_exact(case, got, ref_out, extra, hostdir):
    if got == ref_out:
        return True, ''
    return False, _first_diff(got, ref_out)


def _first_diff(got, want):
    n = min(len(got), len(want))
    for i in range(n):
        if got[i] != want[i]:
            return (f'first difference at byte {i}: maux ${got[i]:02X} '
                    f'vs reference ${want[i]:02X}\n'
                    f'  maux      {got[max(0,i-24):i+24]!r}\n'
                    f'  reference {want[max(0,i-24):i+24]!r}')
    return (f'identical for {n} bytes then length differs: maux '
            f'{len(got)} B, reference {len(want)} B\n'
            f'  maux tail      {got[n:n+64]!r}\n'
            f'  reference tail {want[n:n+64]!r}')


def wc_saturate(ref_lines):
    """Clamp the reference's `total` row at wc.s's 16-bit ceiling."""
    if not ref_lines or ref_lines[-1].split()[-1:] != [b'total']:
        return ref_lines
    fields = ref_lines[-1].split()
    clamped = [f if not f.isdigit() else str(min(int(f), 65535)).encode()
               for f in fields]
    return ref_lines[:-1] + [b' '.join(clamped)]


def cmp_wc_fields(case, got, ref_out, extra, hostdir):
    ref_lines, ref_term = _split(ref_out)
    if ('wc', 'totals saturate at 65535') in case.diverges:
        ref_lines = wc_saturate(ref_lines)
    got_lines, got_term = _split(got)
    g = [ln.split() for ln in got_lines]
    r = [ln.split() for ln in ref_lines]
    if g == r and got_term == ref_term:
        return True, ''
    if g == r:
        return False, ('fields match but the line terminator does not: '
                       f'maux terminated={got_term}, reference '
                       f'terminated={ref_term}')
    return False, f'fields differ\n  maux      {g}\n  reference {r}'


_UNIQC_RE = re.compile(rb'^ *(\d+) (.*)$', re.S)


def cmp_uniq_count(case, got, ref_out, extra, hostdir):
    def parse(data, who):
        lines, term = _split(data)
        out = []
        for ln in lines:
            m = _UNIQC_RE.match(ln)
            if not m:
                return None, term, f'{who}: unparseable -c line {ln!r}'
            out.append((int(m.group(1)), m.group(2)))
        return out, term, ''
    g, gt, err = parse(got, 'maux')
    if g is None:
        return False, err
    r, rt, err = parse(ref_out, 'reference')
    if r is None:
        return False, err
    if g == r and gt == rt:
        return True, ''
    if g == r:
        return False, (f'counts match but the line terminator does not: '
                       f'maux terminated={gt}, reference terminated={rt}')
    return False, f'counts differ\n  maux      {g}\n  reference {r}'


def cmp_comm_cols(case, got, ref_out, extra, hostdir):
    suppressed = set()
    for flag in case.mflags:
        for ch in flag.lstrip('-'):
            suppressed.add(int(ch))
    unsup = [c for c in (1, 2, 3) if c not in suppressed]
    want = []
    for ln in _lines(ref_out):
        k = 0
        while k < len(ln) and ln[k:k + 1] == b'\t':
            k += 1
        if k >= len(unsup):
            return False, (f'reference line {ln!r} has {k} leading tabs '
                           f'but only {len(unsup)} columns are printed')
        col = unsup[k]
        want.append(b'\t' * (col - 1) + ln[k:])
    want_bytes = b''.join(ln + b'\n' for ln in want)
    if got == want_bytes:
        return True, ''
    return False, _first_diff(got, want_bytes)


def cmp_diff_nonewline(case, got, ref_out, extra, hostdir):
    kept = [ln for ln in _lines(ref_out)
            if not ln.startswith(b'\\ No newline')]
    want = b''.join(ln + b'\n' for ln in kept)
    if got == want:
        return True, ''
    return False, _first_diff(got, want)


def cmp_grep_linemax(case, got, ref_out, extra, hostdir):
    ref_lines, ref_term = _split(ref_out)
    want = b''.join(ln[:GREP_LINEMAX] + b'\n' for ln in ref_lines)
    if got == want and ref_term:
        return True, ''
    if got == want:
        return False, 'reference grep output was not line-terminated'
    return False, _first_diff(got, want)


#: HAND CONSTANT, copied from src/bin/grep.s's USAGE, not derived from
#: it -- deriving would make grep its own oracle for the one string this
#: case checks. If the banner changes, this goes red and a human decides
#: whether the change was intended. Same posture as e2e_fs_ls.py's
def cmp_grep_open_continue(case, got, ref_out, extra, hostdir):
    got_lines, got_term = _split(got)
    ref_lines, ref_term = _split(ref_out)
    if not got_term:
        return False, 'grep output does not end in a line terminator'
    if not ref_term:
        return False, 'reference grep output does not end in a terminator'

    missing = [f'/mnt/MAUX/E2E/{o.name}'.encode()
               for o in case.operands
               if o.__class__.__name__ == 'Missing']
    if len(missing) != 1:
        return False, (f'grep_open_continue needs one Missing operand: '
                       f'{case.operands!r}')
    miss = missing[0]

    def is_ref_diag(ln):
        return ln.startswith(b'grep: ') and miss in ln

    def is_maux_diag(ln):
        return ln.startswith(b'grep: cannot open ') and miss in ln

    ref_payload = [ln for ln in ref_lines if not is_ref_diag(ln)]
    got_payload = [ln for ln in got_lines if not is_maux_diag(ln)]
    got_diag = [ln for ln in got_lines if is_maux_diag(ln)]
    if got_payload != ref_payload:
        return False, (f'payload lines differ\n  maux      {got_payload}\n'
                       f'  reference {ref_payload}')
    if len(got_diag) != 1:
        return False, (f'expected exactly one grep open diagnostic naming '
                       f'{miss!r}, got {got_diag!r}')
    return True, ''


def cmp_tee_open_continue(case, got, ref_out, extra, hostdir):
    got_lines, got_term = _split(got)
    ref_lines, ref_term = _split(ref_out)
    if not got_term:
        return False, 'tee output does not end in a line terminator'
    if not ref_term:
        return False, 'reference tee output does not end in a terminator'

    missing = [f'/mnt/MAUX/E2E/{o.name}'.encode()
               for o in case.operands
               if o.__class__.__name__ == 'Missing']
    if len(missing) != 1:
        return False, (f'tee_open_continue needs one Missing operand: '
                       f'{case.operands!r}')
    miss = missing[0]

    def is_ref_diag(ln):
        return ln.startswith(b'tee: ') and miss in ln

    def is_maux_diag(ln):
        return ln.startswith(b'tee: cannot open ') and miss in ln

    ref_payload = [ln for ln in ref_lines if not is_ref_diag(ln)]
    got_payload = [ln for ln in got_lines if not is_maux_diag(ln)]
    got_diag = [ln for ln in got_lines if is_maux_diag(ln)]
    if got_payload != ref_payload:
        return False, (f'payload lines differ\n  maux      {got_payload}\n'
                       f'  reference {ref_payload}')
    if len(got_diag) != 1:
        return False, (f'expected exactly one tee open diagnostic naming '
                       f'{miss!r}, got {got_diag!r}')
    return True, ''


def cmp_tee_self_output(case, got, ref_out, extra, hostdir):
    if case.stdin is None or len(case.operands) != 1:
        return False, 'tee_self_output requires one operand and stdin'
    operand = case.operands[0]
    if getattr(operand, 'name', None) != getattr(case.stdin, 'name', None):
        return False, 'tee_self_output operand must be the stdin fixture'
    got_lines, got_term = _split(got)
    ref_lines, ref_term = _split(ref_out)
    if not ref_term:
        return False, 'reference tee output does not end in a terminator'
    if not ref_lines:
        return False, 'the reference must carry the original payload'
    # OPEN-RW-2: tee joins the `<` group and truncates its own input, so
    # maux prints NOTHING (no diagnostic, no payload); the reference
    # carries the payload only because its stdin was read in advance.
    if got_lines or got:
        return False, (f'tee F < F must emit nothing (it truncates F '
                       f'before reading it), got {got_lines!r}')
    return True, ''


def cmp_sh_pid_pair(case, got, ref_out, extra, hostdir):
    """`ECHO $$ $$` -- compare the SHAPE, never the value.

    A pid cannot agree across machines: maux's is the process's RamWorks
    bank number, the host's is a Unix pid.  So this asserts the three
    properties that ARE true of any correct shell, and refuses to assert
    anything else:

      1. exactly two fields,
      2. both non-empty and entirely digits,
      3. the two EQUAL each other.

    Property 3 is the load-bearing one and it is why this case is worth
    having: the bug that shipped in `PRC_STMP_BANK` made every bank
    report `0`, and `0 0` would satisfy (1) and (2).  So (2) also
    requires a NON-ZERO value -- pid 0 is not a process maux can run,
    and accepting it would re-bless exactly the defect this construct
    first exposed.  `ref_out` is deliberately unused: the host's answer
    proves the CONSTRUCT parses there, and its shape is checked the same
    way, but its digits are not an expectation for maux.
    """
    def shape(data, who):
        fields = data.split()
        if len(fields) != 2:
            return None, (f'{who}: expected two fields from `$$ $$`, '
                          f'got {len(fields)}: {data!r}')
        for f in fields:
            if not f.isdigit():
                return None, f'{who}: {f!r} is not all digits'
            if int(f) == 0:
                return None, (f'{who}: pid 0 -- no process has it, and '
                              f'it is the value the BANK_ID cross-flip '
                              f'bug produced for every bank')
        if fields[0] != fields[1]:
            return None, (f'{who}: `$$` gave two DIFFERENT values on one '
                          f'line: {fields[0]!r} vs {fields[1]!r}')
        return fields[0], ''

    _, err = shape(ref_out, 'reference')
    if err:
        return False, err
    _, err = shape(got, 'maux')
    if err:
        return False, err
    return True, ''


def cmp_head_open_continue(case, got, ref_out, extra, hostdir):
    got_lines, got_term = _split(got)
    ref_lines, ref_term = _split(ref_out)
    if not got_term:
        return False, 'head output does not end in a line terminator'
    if not ref_term:
        return False, 'reference head output does not end in a terminator'

    missing = [f'/mnt/MAUX/E2E/{o.name}'.encode()
               for o in case.operands
               if o.__class__.__name__ == 'Missing']
    if len(missing) != 1:
        return False, (f'head_open_continue needs one Missing operand: '
                       f'{case.operands!r}')
    miss = missing[0]

    def is_ref_diag(ln):
        return ln.startswith(b'head: ') and miss in ln

    def is_maux_diag(ln):
        return ln.startswith(b'head: cannot open ') and miss in ln

    ref_payload = [ln for ln in ref_lines if not is_ref_diag(ln)]
    got_payload = [ln for ln in got_lines if not is_maux_diag(ln)]
    got_diag = [ln for ln in got_lines if is_maux_diag(ln)]
    if got_payload != ref_payload:
        return False, (f'payload lines differ\n  maux      {got_payload}\n'
                       f'  reference {ref_payload}')
    if len(got_diag) != 1:
        return False, (f'expected exactly one head open diagnostic naming '
                       f'{miss!r}, got {got_diag!r}')
    return True, ''


def cmp_cut_open_continue(case, got, ref_out, extra, hostdir):
    got_lines, got_term = _split(got)
    ref_lines, ref_term = _split(ref_out)
    if not got_term:
        return False, 'cut output does not end in a line terminator'
    if not ref_term:
        return False, 'reference cut output does not end in a terminator'

    missing = [f'/mnt/MAUX/E2E/{o.name}'.encode()
               for o in case.operands
               if o.__class__.__name__ == 'Missing']
    if len(missing) != 1:
        return False, (f'cut_open_continue needs one Missing operand: '
                       f'{case.operands!r}')
    miss = missing[0]

    def is_ref_diag(ln):
        return ln.startswith(b'cut: ') and miss in ln

    def is_maux_diag(ln):
        return ln.startswith(b'cut: cannot open ') and miss in ln

    ref_payload = [ln for ln in ref_lines if not is_ref_diag(ln)]
    got_payload = [ln for ln in got_lines if not is_maux_diag(ln)]
    got_diag = [ln for ln in got_lines if is_maux_diag(ln)]
    if got_payload != ref_payload:
        return False, (f'payload lines differ\n  maux      {got_payload}\n'
                       f'  reference {ref_payload}')
    if len(got_diag) != 1:
        return False, (f'expected exactly one cut open diagnostic naming '
                       f'{miss!r}, got {got_diag!r}')
    return True, ''


def cmp_tail_noeol(case, got, ref_out, extra, hostdir):
    want = ref_out if ref_out.endswith(b'\n') else ref_out + b'\n'
    if got == want:
        return True, ''
    return False, _first_diff(got, want)


def _od_rows(data, radix, who):
    lines, term = _split(data)
    if not term:
        return None, f'{who}: od output does not end in a line terminator'
    rows = []
    for ln in lines:
        toks = ln.split()
        if not toks:
            return None, f'{who}: blank od row {ln!r}'
        try:
            off = int(toks[0], radix)
        except ValueError:
            return None, f'{who}: unparseable od offset {toks[0]!r}'
        rows.append((off, toks[1:]))
    return rows, ''


def _od_c_map(fields):
    """Reference `od -c` fields -> the glyph src/bin/od.s would print.
    Only the mapping the ('od', '-c renders every non-printable as a
    dot') entry authorises; anything else fails loudly."""
    out = []
    for f in fields:
        if f == b'\\n':
            out.append(b'.')
        elif len(f) == 1 and 0x20 <= f[0] <= 0x7E:
            out.append(f)
        else:
            return None, (f'od -c reference field {f!r} is outside the '
                          f'authorised \\n -> . mapping; the fixture must '
                          f'not contain that byte at stage 1')
    return out, ''


def cmp_od_rows(case, got, ref_out, extra, hostdir):
    is_c = '-c' in ''.join(case.mflags)
    g, err = _od_rows(got, 16, 'maux')
    if g is None:
        return False, err
    ref_sets = []
    for data in [ref_out] + list(extra):
        r, err = _od_rows(data, 8, 'reference')
        if r is None:
            return False, err
        ref_sets.append(r)

    if not ref_sets[0]:
        # Empty reference: the ('od', 'empty input still prints the end
        # offset') entry -- maux still emits the end-of-dump offset,
        # which for empty input is 0.
        want = [(0, [])]
    elif len(ref_sets) == 1:
        want = ref_sets[0]
    else:
        # Combined formats: one full row per format per 16-byte block,
        # in od.s's fixed hex-then-octal order, then ONE end offset.
        bodies = [rs[:-1] for rs in ref_sets]
        tail = ref_sets[0][-1]
        want = []
        for row_group in zip(*bodies):
            want.extend(row_group)
        want.append(tail)

    if is_c:
        mapped = []
        for off, fields in want:
            m, err = _od_c_map(fields)
            if m is None:
                return False, err
            mapped.append((off, m))
        want = mapped
    else:
        # ('od', 'hex digit case') -- PRHEX8 is uppercase, BSD od is not.
        want = [(o, [f.upper() for f in fs]) for o, fs in want]
        g = [(o, [f.upper() for f in fs]) for o, fs in g]

    if g == want:
        return True, ''
    for i, (a, b) in enumerate(zip(g, want)):
        if a != b:
            return False, (f'od row {i} differs\n  maux      {a}\n'
                           f'  reference {b}')
    return False, (f'od row count differs: maux {len(g)}, reference '
                   f'{len(want)}\n  maux tail      {g[len(want):][:3]}\n'
                   f'  reference tail {want[len(g):][:3]}')


_SUM_RE = re.compile(rb'^(\d+) +(\d+)(?: (.*))?$', re.S)


def cmp_sum_row(case, got, ref_out, extra, hostdir):
    def parse(data, who):
        lines, term = _split(data)
        if not term:
            return None, (f'{who}: sum output does not end in a line '
                          f'terminator')
        out = []
        for ln in lines:
            m = _SUM_RE.match(ln)
            if not m:
                return None, f'{who}: unparseable sum line {ln!r}'
            out.append((int(m.group(1)), int(m.group(2)),
                        m.group(3) or b''))
        return out, ''
    g, err = parse(got, 'maux')
    if g is None:
        return False, err
    r, err = parse(ref_out, 'reference')
    if r is None:
        return False, err
    if len(g) != len(r):
        return False, (f'sum printed {len(g)} rows, reference {len(r)}\n'
                       f'  maux      {g}\n  reference {r}')
    from e2e_corpus import Ref, SUM_BLOCKSZ
    operands = [o for o in case.operands if isinstance(o, Ref)]
    problems = []
    for i, ((gc, gb, gn), (rc, rb, rn)) in enumerate(zip(g, r)):
        if gc != rc:
            problems.append(f'row {i}: checksum {gc} vs reference {rc}')
        if gn != rn:
            problems.append(f'row {i}: name {gn!r} vs reference {rn!r}')
        # Block count: the ('sum', 'blocks are 512-byte ProDOS blocks')
        # entry.  The oracle is the host FILESYSTEM's size for that same
        # file, not a number written down anywhere.
        if operands:
            size = os.path.getsize(os.path.join(hostdir, operands[i].name))
        else:
            size = os.path.getsize(os.path.join(hostdir, case.stdin.name))
        want_blocks = math.ceil(size / SUM_BLOCKSZ)
        if gb != want_blocks:
            problems.append(f'row {i}: blocks {gb}, but the file is '
                            f'{size} B = {want_blocks} x {SUM_BLOCKSZ}')
    if problems:
        return False, '\n  '.join([''] + problems)
    return True, ''


def cmp_printf_numerr(case, got, ref_out, extra, hostdir):
    """A non-numeric numeric argument: both sides print a 'printf:'
    diagnostic line (wording differs, not compared) and use 0 in the
    conversion's place; payload lines and exit status still compare
    exactly -- see the DIVERGENCE citation."""
    got_lines, got_term = _split(got)
    ref_lines, ref_term = _split(ref_out)
    if not got_term:
        return False, 'printf output does not end in a line terminator'
    if not ref_term:
        return False, 'reference printf output does not end in a terminator'

    def is_diag(ln):
        return ln.startswith(b'printf:')

    got_diag = [ln for ln in got_lines if is_diag(ln)]
    ref_diag = [ln for ln in ref_lines if is_diag(ln)]
    got_payload = [ln for ln in got_lines if not is_diag(ln)]
    ref_payload = [ln for ln in ref_lines if not is_diag(ln)]
    if got_payload != ref_payload:
        return False, (f'payload lines differ\n  maux      {got_payload}\n'
                       f'  reference {ref_payload}')
    if len(got_diag) != 1 or len(ref_diag) != 1:
        return False, (f'expected exactly one printf diagnostic line on '
                       f'each side, got maux={got_diag!r} '
                       f'reference={ref_diag!r}')
    return True, ''


def cmp_sh_closed_fd(case, got, ref_out, extra, hostdir):
    """`CAT <&- ; ECHO $?` -- NOT a "both sides fail" comparator.

    POSIX guarantees a closed-fd read fails (nonzero $?), and this
    HOST's cat does: it checks its own read() return and reports
    "Bad file descriptor", exit 1. maux's cat cannot make the same
    promise, for a reason that has nothing to do with `<&-` itself --
    docs/SH-FEATURES.md (2026-09-15) names it a pre-existing, separate
    bug found WHILE landing this feature: cat/wc/od's shared REFILL
    idiom (see wc.s) treats `SC_READ` returning an ERROR and `SC_READ`
    returning zero bytes TRANSFERRED as the SAME `:eof` branch, so a
    closed fd 0 is completely indistinguishable from ordinary EOF to
    every liba-style consumer in this tree -- maux's own $? is a
    DETERMINISTIC 0 here, not a flaky one. So this asserts what is
    actually true of each side rather than a shared shape: the
    reference must be non-empty, all-digit and NON-ZERO (the construct
    means something to a correct shell); maux must be EXACTLY "0"
    (proving the close genuinely took effect -- with no blocking
    console read, verified separately, live, on the emulator -- and
    is not silently a no-op that would leave some OTHER stale status
    behind).
    """
    ref_s = ref_out.strip()
    if not ref_s or not ref_s.isdigit() or int(ref_s) == 0:
        return False, f'reference: {ref_s!r} is not a nonzero digit status'
    got_s = got.strip()
    if got_s != b'0':
        return False, (f'maux: {got_s!r}, expected the DETERMINISTIC '
                       f"'0' cat/wc/od's shared EOF-vs-error gap "
                       f'produces here (see this comparator\'s own '
                       f'docstring) -- a different value means either '
                       f'that gap closed or something else changed')
    return True, ''


def cmp_cmp_msg(case, got, ref_out, extra, hostdir):
    """cmp writes nothing to stdout; its message is checked against the
    host's stdout+stderr by the runner (see check_e2e), which passes it
    in as `ref_out`."""
    if got == ref_out:
        return True, ''
    return False, _first_diff(got, ref_out)


COMPARATORS = {
    'exact': cmp_exact,
    'wc_fields': cmp_wc_fields,
    'uniq_count': cmp_uniq_count,
    'comm_cols': cmp_comm_cols,
    'diff_nonewline': cmp_diff_nonewline,
    'grep_linemax': cmp_grep_linemax,
    'grep_open_continue': cmp_grep_open_continue,
    'tee_open_continue': cmp_tee_open_continue,
    'tee_self_output': cmp_tee_self_output,
    'head_open_continue': cmp_head_open_continue,
    'cut_open_continue': cmp_cut_open_continue,
    'tail_noeol': cmp_tail_noeol,
    'sh_pid_pair': cmp_sh_pid_pair,
    'sh_closed_fd': cmp_sh_closed_fd,
    'od_rows': cmp_od_rows,
    'sum_row': cmp_sum_row,
    'cmp_msg': cmp_cmp_msg,
    'printf_numerr': cmp_printf_numerr,
}


if __name__ == '__main__':
    import sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from e2e_corpus import CASES
    errs, dead = check_citations(CASES)
    for grade in ('DISCHARGED', 'STRUCTURAL', 'RULED', 'EXCLUDED'):
        print(f'== {grade} ==')
        for (tool, axis), (g, reason) in sorted(DIVERGENCE.items()):
            if g != grade:
                continue
            tag = ' [global]' if (tool, axis) in GLOBAL_KEYS else ''
            print(f'  {tool}/{axis}{tag}\n    {reason}')
    print()
    print(f'{len(DIVERGENCE)} entries, {len(errs)} citation errors, '
          f'{len(dead)} dead')
    for e in errs:
        print(f'  ERROR {e}')
    for d in dead:
        print(f'  DEAD  {d}')
