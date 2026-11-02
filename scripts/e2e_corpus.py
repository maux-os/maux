#!/usr/bin/env python3
"""Stage-1 differential corpus: boundary-aware fixtures + the case table.

docs/E2E.md sec 6 stage 1.  Nothing in this file authors an expected
output.  It generates INPUT, and it says how to invoke the host reference
on that same input; the expectation is whatever the reference produces
(oracle 1, docs/E2E.md sec 4).  The one place a maux-specific rule enters
is the divergence ratchet in scripts/e2e_divergence.py, per entry, with
a reason and a name.

FIXTURES ARE BOUNDARY-AWARE, NOT RANDOM (docs/E2E.md sec 5).  Every size
and length below is an expression over scripts/e2e_limits.py, which reads
the tree's own headers.  `sort -u`'s 2026-08-23 bug needed two lines
identical through byte 255 and differing at 256; FTWIN is exactly that,
built from `PAGE`, and FCTRL is its control -- differing INSIDE the 8-bit
walk, so a broken STRCMP must leave FCTRL green while FTWIN goes red.
A corpus where every case fails proves nothing.

TWO ENCODINGS, both explicit:
  * kind='text' -- host-native LF text, encoded for the image by a2til's
    own `convert.text_from_host(high_bit=True)` (LF->CR, bit 7 set on
    every byte).  That is maux's text convention; see the header note in
    scripts/e2e_compare.py for where the inverse happens and what it
    refuses to be generous about.
  * kind='raw'  -- byte-exact both sides.  Used only where the tool's
    semantics are byte-identical on both machines (od, sum, cmp -- NOT
    wc -l, whose line rule is $8D here and $0A there).

DISK BUDGET, measured rather than assumed.  The 280-block carrier every
other gate copies does not have room for the corpus once every result is
written: ProDOS charges at least one block per file and an index block on
top for anything over 512 bytes. scripts/build_e2e_image.py therefore
builds an 800K volume and prints the live staged-byte/free-block counts
each run; the process-window boundary sample intentionally adds about
140 KB of input, so copied historical counts here would go stale.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e_limits as L  # noqa: E402
import e2e_ref as REF  # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import convert  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

#: Where the corpus lives inside the image.  A SUBDIRECTORY, not the
#: volume root: `a2til mirror` syncs a directory in BOTH directions, and
#: pointed at the root it would faithfully pull PRODOS, MAUX.SYSTEM, SH
#: and the nine binaries out onto the host on its first pass.
IMG_DIR = '/mnt/MAUX/E2E'

#: The exit-status log.  `ECHO $? >> ST` after every case: statuses are an
#: oracle in their own right (`diff` calling differing files identical
#: with EXIT 0 is one of the four bugs docs/E2E.md sec 1 opens with).
STATUS_NAME = 'ST'

#: EVERY case redirects as `> Onn 2>&1`, never `> Onn 2> Enn`.
#:
#: FOUND BY THIS HARNESS, first run, 2026-08-23: maux's `sh` keeps ONE
#: output-file slot per pipeline stage, and src/bin/sh.s says so in its
#: own words -- "SET_OUTFILE/SET_TGTFD/SET_APPEND, which each own ONE
#: slot per stage and silently overwrite".  So `CMD > OUT 2> ERR` is not
#: two redirects: the `2>` OVERWRITES the `>`, stdout goes to the
#: console, and nothing says a word.  The first run of this corpus
#: produced 68 statuses, an ERR file, four E-files -- and NOT ONE of the
#: 68 stdout files, because every one of them had been silently
#: annihilated by the `2>>` that followed it.
#:
#: `2>&1` is the form sh DOES implement properly: dups are an ORDERED
#: LIST, and sh.s's SET_DUP header names `CMD > FILE 2>&1` as the
#: supported spelling.  Merging the two streams also makes the "no
#: unexpected diagnostic" assertion per-case instead of aggregate: a
#: stray `sort: cannot open` lands in that case's own output file and
#: fails that case, with its text, rather than in a shared sink.
REDIR_SUFFIX = '2>&1'

# ----------------------------------------------------------------------
# Boundaries, every one of them read from the headers the code reads.
# ----------------------------------------------------------------------
PAGE = L.PAGE                              # 6502 Y wrap -- ARCH, see e2e_limits
SH_LINEMAX = L.limit('sh', 'LINEMAX')      # src/bin/sh.s
UNIQ_LINEMAX = L.limit('uniq', 'LINEMAX')  # src/bin/uniq.s -- forced break
COMM_LINEMAX = L.limit('comm', 'LINEMAX')  # src/bin/comm.s -- forced break
GREP_LINEMAX = L.limit('grep', 'LINEMAX')  # src/bin/grep.s -- truncation
SORT_BUFSZ = L.limit('sort', 'BUFSZ')      # read-chunk boundary
DIFF_MAXLINES = L.limit('diff', 'MAXLINES')
DIFF_BUFSZ = L.limit('diff', 'BUFSZ')
OD_ROWMAX = L.limit('od', 'ROWMAX')
UNIQ_CNTFLD = L.limit('uniq', 'CNTFLD')
SUM_BLOCKSZ = L.limit('sum', 'BLOCKSZ')
MLI_IBF_SIZE = L.kernel_limit('MLI_IBF_SIZE')
PROCESS_WINDOW = (L.kernel_limit('PRC_HEAP_TOP') -
                  L.kernel_limit('LOAD_BASE') + 1)

#: Longest line any fixture fed to uniq/comm may carry.  Their GETLINE
#: returns a line the moment LINEMAX bytes have accumulated and resumes on
#: the next byte, so a line of exactly LINEMAX comes back as a full line
#: plus an EMPTY one -- a real, documented divergence from the host, but
#: not one this stage can build an oracle for (see e2e_divergence's
#: 'linemax forced break' entries).  Stay one byte inside it.
RUNLINE_MAX = min(UNIQ_LINEMAX, COMM_LINEMAX) - 1


def _lines(*items):
    return ''.join(s + '\n' for s in items).encode('ascii')


def build_fixtures():
    """name -> (kind, host bytes).  Every length is an expression over the
    limits above; there are no bare magic sizes."""
    f = {}

    # --- degenerate shapes (docs/E2E.md sec 5's own list) --------------
    f['FEMPTY'] = ('text', b'')
    f['FONE'] = ('text', b'A\n')
    f['FNOEOL'] = ('text', b'ABC')                    # no trailing newline
    f['FRAW1'] = ('raw', b'Z')                         # one byte, byte-stable

    # --- THE Y-WRAP PAIR, and its control -----------------------------
    # Two lines identical through byte PAGE-1 and differing at PAGE: the
    # 8-bit STRCMP walk compares indices 0..PAGE-1, wraps, and declares
    # them EQUAL.  `sort -u` turns "equal" into "drop the line".
    twin_prefix = 'A' * PAGE
    f['FTWIN'] = ('text', _lines(twin_prefix + 'A', twin_prefix + 'B'))
    # Same shape, differing at PAGE-2 -- INSIDE the walk.  A broken
    # STRCMP must leave this case GREEN; that is what proves the corpus
    # is measuring the wrap and not merely long lines.
    ctrl_prefix = 'C' * (PAGE - 2)
    f['FCTRL'] = ('text', _lines(ctrl_prefix + 'A', ctrl_prefix + 'B'))
    # The same pair with the SECOND line altered past byte PAGE: `diff`
    # must call these files different.  Broken STRCMP -> "identical",
    # exit 0, no output at all.
    f['FTWINB'] = ('text', _lines(twin_prefix + 'A', twin_prefix + 'C'))
    # Byte-identical COPIES, under different names.
    #
    # FOUND BY THIS HARNESS, first run, 2026-08-23: `diff X X`, `comm X X`
    # and `cmp X X` all exit 2 with `cannot open X` on maux.  ProDOS
    # refuses a second OPEN of a file that is already open, so a tool
    # that opens both operands at once cannot be handed the same path
    # twice -- a real platform divergence from POSIX, and one the
    # identical-file cases have to be written around rather than
    # through.  check_comm.py's own CADUP fixture is the precedent.
    # See e2e_divergence's ('*', 'the same file cannot be opened twice').
    f['FCTRLCP'] = ('text', f['FCTRL'][1])

    # --- line-length boundaries: PAGE-1 / PAGE / PAGE+1 ---------------
    f['FLONG'] = ('text', _lines(
        'L' * (PAGE - 1),
        'M' * PAGE,
        'N' * (PAGE + 1),
        'S',
    ))
    # FLONG with the OVER-page line sorting FIRST: its PUTS starts at
    # a page-aligned (empty) stdio buffer, so the bulk append copies a
    # full 256-byte chunk and must carry PTR0 across a page with Y
    # wrapped to 0 -- SIO_PUTSB's subtlest path, which FLONG alone
    # never reaches (its 255-char line prints first and de-aligns the
    # buffer). Proven by sabotage 2026-08-28: with the wrap-carry
    # dead, every other case in this corpus stayed green.
    f['FLONG2'] = ('text', _lines(
        'A' * (PAGE + 1),
        'B',
    ))

    # --- read-chunk and block boundaries ------------------------------
    # BUFSZ-1, exactly BUFSZ, and one past it: the per-fd refill seam.
    f['FBUFMIN'] = ('raw', bytes((0x41 + (i % 26))
                                 for i in range(SORT_BUFSZ - 1)))
    f['FBUF'] = ('raw', bytes((0x41 + (i % 26)) for i in range(SORT_BUFSZ)))
    f['FBUF2'] = ('raw', bytes((0x41 + (i % 26))
                               for i in range(SORT_BUFSZ + 1)))
    # 511/512/513: ProDOS block-count seam.
    f['FBLK511'] = ('raw', bytes((i % 251) for i in range(SUM_BLOCKSZ - 1)))
    f['FBLK1'] = ('raw', bytes((i % 251) for i in range(SUM_BLOCKSZ)))
    f['FBLK2'] = ('raw', bytes((i % 251) for i in range(SUM_BLOCKSZ + 1)))
    # Exactly one MLI I/O buffer.
    f['FIOB'] = ('raw', bytes((i % 253) for i in range(MLI_IBF_SIZE)))
    # Process-window -1/exact/+1 ($0800..$BEFF), sampled once through wc.
    f['FPWMIN'] = ('raw', bytes((i % 251)
                                for i in range(PROCESS_WINDOW - 1)))
    f['FPWEXACT'] = ('raw', bytes((i % 251)
                                  for i in range(PROCESS_WINDOW)))
    f['FPWPLUS'] = ('raw', bytes((i % 251)
                                 for i in range(PROCESS_WINDOW + 1)))

    # --- every 8-bit byte value, for the byte-transparent tools -------
    f['FBIN'] = ('raw', bytes(range(256)))
    _b2 = bytearray(range(256))
    _b2[200] ^= 0x01
    f['FBIN2'] = ('raw', bytes(_b2))

    # --- uuencode: boundary sizes over its own chunk sizes (45
    # historical, 57 base64), byte-stable per BYTE_VALUED below.
    # FBIN (256 bytes, every value) already covers the general
    # "arbitrary bytes" case; these cover the line-length seams.
    f['FUU46'] = ('raw', bytes(i % 251 for i in range(46)))   # 45+1
    f['FUU57'] = ('raw', bytes(i % 251 for i in range(57)))   # base64,
                                                              # exact
    f['FUU58'] = ('raw', bytes(i % 251 for i in range(58)))   # +1
    f['FUU135'] = ('raw', bytes(i % 251 for i in range(135)))  # 45*3
    # No uudecode fixture here -- see build_cases()'s own note by
    # where the uudecode section used to be: decode_maux_text()'s
    # unconditional bit-7 strip cannot compare uudecode's real
    # (byte-for-byte passthrough) output against a host reference
    # in this corpus, for any payload.

    # --- tsort ----------------------------------------------------------
    # A plain 3-edge chain: no tie ever needs breaking, so GNU and BSD
    # tsort agree byte for byte (see src/bin/tsort.s's own header on
    # where they do NOT).
    f['FTSORT'] = ('text', _lines('a b', 'b c', 'c d'))

    # --- sort ---------------------------------------------------------
    f['FUNS'] = ('text', _lines(
        'pear', 'Apple', 'banana', 'apple', '10', '9', '2', 'Zebra',
        'zebra', 'BANANA', '~tilde', '!bang', 'Apple', 'fig', 'FIG',
        'date', 'elderberry', 'Cherry', 'cherry', 'grape',
    ))
    f['FDUP2'] = ('text', _lines(
        'aa', 'aa', 'aa', 'bb', 'cc', 'cc', 'dd', 'ee', 'ee', 'ee', 'ee',
        'ff',
    ))
    # -n's edges, each on purpose: negatives; 007 vs 7 (equal value,
    # last-resort decides); a no-number line (counts as 0) vs a bare 0
    # (also 0 -- last-resort again); leading blanks before the digits;
    # and 10 vs 9 vs 2 (the magnitude-length rule, where lexical order
    # is wrong). NO decimals: sort.s documents the dot as unparsed.
    f['FSORTN'] = ('text', _lines(
        '10 ten', '2 two', '-3 neg', 'abc', '007 padded', '7 seven',
        '0', '  42 blankled', '-11 negbig', '9 nine',
    ))
    # -k's edges: a DOUBLE separator space (the second blank belongs
    # to field 2, so "c  1"'s key "  1" sorts before "b 1"'s " 1");
    # 10-vs-2 in field 2 (lexical under -k2, numeric under -k2n);
    # equal field 2 with differing field 3 (separates -k2 from -k2,2
    # AND feeds the last-resort rule under -k2,2).
    f['FSORTK'] = ('text', _lines(
        'b 1', 'a 2', 'c  1', 'a 10', 'x b z', 'y b a',
    ))

    # --- uniq: runs of 1, 2, 3, 9, 10 and 100 -------------------------
    # 1/2 digits exercise CNTFLD's space padding on both sides of the
    # single-digit case; 100 reaches three.
    runs = []
    for tag, n in (('a', 1), ('b', 2), ('c', 3), ('d', 9), ('e', 10),
                   ('f', 100)):
        runs.extend([tag * 3] * n)
    f['FDUP'] = ('text', _lines(*runs))

    # --- comm: two sorted files, no tabs in the content ---------------
    # (the column comparator counts LEADING TABS to identify a column, so
    # a tab inside a line would make it lie -- see e2e_divergence.)
    f['FSA'] = ('text', _lines('APPLE', 'BANANA', 'CHERRY', 'DATE', 'FIG'))
    f['FSB'] = ('text', _lines('BANANA', 'CHERRY', 'EGG', 'FIG', 'GRAPE'))
    f['FSACOPY'] = ('text', f['FSA'][1])         # identical copy, see FCTRLCP

    # --- diff: small and unambiguous, so the minimal edit script is
    # UNIQUE and the two implementations' tie-breaks cannot disagree.
    f['FDA'] = ('text', _lines('one', 'two', 'three', 'four', 'five'))
    f['FDB'] = ('text', _lines('one', 'TWO', 'three', 'four', 'five', 'six'))
    f['FDC'] = ('text', b'one\ntwo\nthree\nfour\nfiv')   # no trailing NL
    f['FDAPRE'] = ('text', b'one\ntwo\n')                # a prefix of FDA
    f['FDACOPY'] = ('text', f['FDA'][1])         # identical copy, see FCTRLCP

    # --- tr / wc word counting ----------------------------------------
    f['FMIX'] = ('text', _lines(
        'HELLO WORLD', 'The Quick Brown Fox', 'aaabbbccc', 'AAABBBCCC',
        '0123456789', 'MISSISSIPPI', 'LLAMA', 'x',
    ))

    # --- grep ---------------------------------------------------------
    f['FGREP'] = ('text', _lines(
        'alpha', 'beta', 'alphabet', 'gamma', 'ALPHA', 'delta',
    ))
    f['FGREP2'] = ('text', _lines(
        'beta', 'alpha two', 'delta', 'alphabet soup',
    ))
    f['FGBIN'] = ('text', b'A\x01B\nZ\x7fQ\nplain\n')

    # --- grep: \( \) \1-\9 grouping + backreferences (W5,
    # docs/ANACHRONISMS.md) -- the regex ENGINE feature, gated
    # here because grep is the natural home for a pattern-only
    # (no replacement side) regex assertion.
    f['FGRPBACK'] = ('text', _lines(
        'the the quick', 'the quick fox', 'foofoo', 'foobar',
    ))
    f['FGRPSTAR'] = ('text', _lines(
        'ababab', 'aba', 'abab', 'abc', 'baba',
    ))

    # --- grep/sed: BRE intervals \{n,m\} (W5b, docs/ANACHRONISMS.md,
    # docs/REGEX-BRE-INTERVALS.md). The host's BSD grep/sed implement
    # \{n\} / \{n,\} / \{n,m\} and treat a bare `{`, `+`, `?` as
    # literal -- measured 2026-09-08 -- so both halves of the BRE
    # spelling rule are host-oracled here. (\+ and \? are NOT: the
    # host reads them as literal, so those live in check_regex.py
    # with hand-authored expectations.)
    f['FINTV'] = ('text', _lines(
        '12345', '1234', '123', 'x1234y', 'a{4}', '1{4}', 'a+b', 'a?b',
    ))
    f['FINTV2'] = ('text', _lines(
        'aaaaa', 'aaa', 'aa', 'a', 'baaab', 'abab', 'ababab', 'ab',
    ))

    # --- cmp -l: RAW on purpose -- the listing prints byte VALUES,
    # and text transport sets bit 7 on the image side, so a text
    # fixture's octal columns could never agree with the host's.
    # Diff positions: offset 2 (both digits printable), offset 5
    # (low bytes -- the leading-zero-as-space lanes "  1"/"  5"),
    # offset 12 (high-bit bytes -- 3-digit octal, 2-digit offset).
    f['FCMPL1'] = ('raw', b'aXcd\x01fghijk\xc1')
    f['FCMPL2'] = ('raw', b'abcd\x05fghijk\x81')
    f['FCMPL3'] = ('raw', b'aXcd\x01fghijk\xc1')
    f['FGLONG'] = ('text', _lines(
        'NEEDLE' + 'A' * (GREP_LINEMAX - 1 - len('NEEDLE')),
        'NEEDLE' + 'B' * (GREP_LINEMAX - len('NEEDLE')),
        'NEEDLE' + 'C' * (GREP_LINEMAX + 1 - len('NEEDLE')),
    ))

    # --- sed: the MULTI-WINDOW read fixture ---------------------------
    # >3 RDCHUNKs (sed.s: 1020-byte reads served as 255-byte windows,
    # 2026-08-28) of irregular line lengths, so CRs land astride both
    # the window and the chunk boundaries and lines straddle a REFILL.
    # check-sed's own inputs are all a single window; without this,
    # NEXTWIN's full-window and tail-window paths had NO fast-gate
    # coverage at all.
    f['FSEDBIG'] = ('text', _lines(*[
        ('alpha' if i % 7 == 0 else 'word') + str(i) + 'x' * (i % 89)
        for i in range(64)]))
    # CRs landing EXACTLY on sed's window AND chunk ends: 254-char
    # lines encode to 255 bytes each, so every line ends precisely at
    # a 255-byte window boundary and every 4th at a 1020-byte chunk
    # boundary -- the alignment FSEDBIG's irregular lines never hit.
    # That alignment is what makes the last line of a chunk be served
    # ZERO-COPY out of CBUF right before the '$'-peek's refill, which
    # is exactly where the 2026-08-29 refill-alias corruption lived
    # (6 of 208 real tree files, zero small fixtures). Eight aligned
    # lines = two full chunks, plus a short tail.
    f['FSEDALN'] = ('text', _lines(*(
        [('alpha' + 'y' * 249) if i % 2 == 0 else 'z' * 254
         for i in range(8)] + ['tail'])))

    # --- tail / tee ---------------------------------------------------
    f['FTAIL'] = ('text', _lines(*[f'L{i:02d}' for i in range(1, 13)]))
    f['FSELF'] = ('text', _lines('one', 'two'))
    # FSELF2 is the self-output case's OWN file: since OPEN-RW-2 tee
    # JOINS the `<` group and truncates its own input (as Unix does), so
    # the case must not share a fixture with a later reader (HEAD FSELF).
    f['FSELF2'] = ('text', _lines('one', 'two'))

    # ---- cut: -f fixtures. Tab is cut's default delimiter; colon
    # exercises -d; FCUTMIX carries one line with NO delimiter at
    # all to exercise -s vs the default passthrough rule.
    f['FCUTTAB'] = ('text', _lines('aa\tbb\tcc', '11\t22\t33',
                                    'x\ty\tz'))
    f['FCUTCOLON'] = ('text', _lines('root:x:0', 'dan:x:501',
                                      'amy:x:502'))
    f['FCUTMIX'] = ('text', _lines('a\tb\tc', 'noDelimHere',
                                    'd\te\tf'))

    # ---- xargs: multi-line, multi-word input for the default/-n
    # batching cases, and a quoted/escaped line for the quoting
    # rules ('...'/"..."/backslash).
    f['FXARGS'] = ('text', _lines('one two three', 'four five',
                                   'six'))
    f['FXARGSQ'] = ('text', _lines(
        "'a b' c \"d e\" f\\ g", "plain"))

    # --- od -c: printable, and NO SPACE bytes (see e2e_divergence's
    # 'od -c whitespace tokenisation' entry for why a space would blind
    # the comparator).
    f['FODC'] = ('text', _lines('ABCdef', '0123456789ABCDEF!', 'zz'))

    # ---- cksum: 'raw' fixtures ONLY -- cksum's whole point is an
    # EXACT byte checksum, and 'text' fixtures deliberately carry
    # DIFFERENT bytes on the two sides (LF->CR, bit 7 set for the
    # image). FEMPTY/FBLK511/FBLK1/FBLK2 above are already 'raw' and
    # reused below; these two are new.
    f['FCKONE'] = ('raw', b'a')
    f['FCKTXT'] = ('raw', b'The quick brown fox jumps over the lazy '
                          b'dog.\nPack my box with five dozen liquor '
                          b'jugs.\n')

    # ---- paste: parallel-merge fixtures of DIFFERENT lengths (3 vs
    # 2 vs 4 lines) so the "shorter file contributes empty fields,
    # rows stop the instant every file is exhausted" rule is actually
    # exercised, plus one with an unterminated final line for -s.
    f['FPASTE1'] = ('text', _lines('a', 'b', 'c'))
    f['FPASTE2'] = ('text', _lines('1', '2'))
    f['FPASTE3'] = ('text', _lines('x', 'y', 'z', 'w'))

    # ---- fold: a long unbroken line for the default width, a
    # tab-crossing-the-boundary line (measured against this host's
    # own fold -w 10 before writing fold.s -- see its own header),
    # an exactly-width line, and a lone empty line.
    f['FFOLDLONG'] = ('text', _lines('x' * 95))
    f['FFOLDTAB'] = ('text', _lines('123456789\tabc'))
    f['FFOLDEXACT'] = ('text', _lines('y' * 10))
    f['FFOLDBLANKLN'] = ('text', _lines(''))
    f['FFOLDWORDS'] = ('text', _lines(
        'I am smart enough to know that I am dumb'))

    # ---- expand: a leading tab, a mid-line tab, a tab past an
    # explicit list's last stop, and a backspace -- each measured
    # against this Mac's own /usr/bin/expand before writing expand.s
    # (see its own header). FEXPTAB0/FEXPTABMID double as -t4 and
    # default-width fixtures; a line with no tabs at all proves the
    # tool is a no-op passthrough on one.
    f['FEXPTAB0'] = ('text', _lines('\ta\tb'))
    f['FEXPTABMID'] = ('text', _lines('ab\tc'))
    f['FEXPPAST'] = ('text', _lines('a\tb\tc\td\te'))
    f['FEXPBS'] = ('text', _lines('abc\bd\te'))
    f['FEXPPLAIN'] = ('text', _lines('no tabs here at all'))

    # ---- unexpand: leading blanks that DO/DO NOT reach a tab stop,
    # an interior run for -a, a single space that falls one short of
    # a stop, and a -t4 interior run -- each measured against this
    # Mac's own /usr/bin/unexpand before writing unexpand.s (see its
    # own header).
    f['FUXLEAD8'] = ('text', _lines('        leading'))
    f['FUXLEAD5'] = ('text', _lines('     x'))
    f['FUXINTER'] = ('text', _lines('1234567  x'))
    f['FUXONESP'] = ('text', _lines('1234567 8'))
    f['FUXT4'] = ('text', _lines('ab  cd  x'))

    # ---- nl: a plain 3-line file, one with a blank middle line (for
    # -b a vs the default -b t), and a page-delimited file (header/
    # body/footer, default two-char delimiter backslash+colon) --
    # each measured against this Mac's own /usr/bin/nl before
    # writing nl.s (see its own header).
    f['FNLPLAIN'] = ('text', _lines('one', 'two', 'three'))
    f['FNLBLANK'] = ('text', _lines('one', '', 'three'))
    f['FNLPAGE'] = ('text', _lines(
        '\\:\\:\\:', 'HEADER', '\\:\\:', 'BODY1', 'BODY2',
        '\\:', 'FOOTER'))
    # TWO pages -- -p only changes anything when a SECOND page's own
    # header delimiter would otherwise reset the counter (measured
    # live: on a single-page file -p and its absence agree).
    f['FNLPAGE2'] = ('text', _lines(
        '\\:\\:\\:', 'H1', '\\:\\:', 'B1', 'B2',
        '\\:\\:\\:', 'H2', '\\:\\:', 'B3'))

    # ---- strings: RAW (byte-exact both sides -- strings' own
    # classification of plain $20-$7E ASCII is byte-identical on
    # both machines, same reasoning as od/sum/cmp above). A short
    # run below the default length-4 threshold, a qualifying run,
    # and a control-byte separator between them -- measured live
    # against this Mac's own /usr/bin/strings before writing
    # strings.s (see its own header). FSTROFS doubles as the -t
    # fixture: "hello" begins at a non-trivial offset (11) so d/o/x
    # print visibly different digit strings.
    f['FSTR1'] = ('raw', b'AB\x01hello world\x02foo')
    f['FSTROFS'] = ('raw', b'zzzzzzzzzz\x01hello')
    f['FSTRM1'] = ('raw', b'hello world')
    f['FSTRM2'] = ('raw', b'goodbye now')

    # ---- split/csplit: both cases below are smoke tests over the
    # OPTION-PARSING/no-crash path -- split writes NO stdout ever, and
    # csplit's own byte-count stdout is suppressed by -s -- PIECE
    # CONTENT is check-posixutil's own richer job (results=), not this
    # comparator's (single stdout stream only). split's own fixture is
    # RAW (byte-exact both sides -- its stdout never depends on the
    # CR-vs-LF encoding either way, so 'raw' sidesteps the question).
    f['FSPLITIN'] = ('raw', b'one\ntwo\nthree\nfour\nfive\n')
    # csplit's own line-number arg needs REAL maux line terminators
    # (CR, $8D) to find "line 3" at all -- 'raw' stages plain LF with
    # none, which made the whole file ONE maux "line" and turned this
    # into a genuine (if unintended) out-of-range case, caught live.
    f['FCSPLITIN'] = ('text', b'aaa\nbbb\nccc\nddd\neee\nfff\n')

    # ---- join: TEXT (real comparable stdout -- unlike split/csplit,
    # join's own output IS its whole job, so this is a genuine content
    # check, not a smoke test). Already sorted on field 1.
    f['FJOIN1'] = ('text', b'a 1\nb 2\nc 3\n')
    f['FJOIN2'] = ('text', b'a X\nb Y\nc Z\n')

    return f


FIXTURES = build_fixtures()


class Ref:
    """A fixture reference inside a case's argv."""

    def __init__(self, name):
        assert name in FIXTURES, name
        self.name = name

    def __repr__(self):
        return f'Ref({self.name})'


class Missing:
    """A path the host and image should both fail to open."""

    def __init__(self, name):
        assert name not in FIXTURES, name
        self.name = name

    def __repr__(self):
        return f'Missing({self.name})'


class Path:
    """A non-fixture image path mapped into the host corpus directory."""

    def __init__(self, name):
        assert name not in FIXTURES, name
        self.name = name

    def __repr__(self):
        return f'Path({self.name})'


class Case:
    """One differential case.

    `mflags`/`operands` are maux's invocation.  `ref_argv`, when given, is
    the HOST invocation that means the same thing -- a divergence in
    spelling, not in expectation (od's `-x` is byte-wise where the host's
    is word-wise, so the host is asked for `-t x1`).  Every such override
    cites a divergence entry.
    """

    def __init__(self, cid, tool, mflags=(), operands=(), stdin=None,
                 ref_argv=None, ref_extra=(), compare='exact',
                 diverges=(), defect=None, status_ruled=None, note=''):
        self.cid = cid
        self.tool = tool
        self.mflags = list(mflags)
        self.operands = list(operands)
        self.stdin = stdin
        self.ref_argv = ref_argv
        self.ref_extra = list(ref_extra)   # extra host runs, for od -bx
        self.compare = compare
        self.diverges = list(diverges)
        self.status_ruled = status_ruled
        #: At most one KNOWN_DEFECTS key.  A case that cites one is
        #: reported as a PINNED DEFECT instead of a failure -- see
        #: e2e_divergence.KNOWN_DEFECTS for why that is a different
        #: table from DIVERGENCE.
        self.defect = defect
        self.note = note

    @property
    def out_name(self):
        return f'O{self.cid:02d}'

    # -- maux side ------------------------------------------------------
    #: A LITERAL OPERAND MUST REACH THE TOOL AS ITSELF. The host side
    #: hands the reference tool its argv directly -- no shell -- so the
    #: maux line has to be QUOTED wherever a word would otherwise mean
    #: something to `sh`. Found 2026-08-29: `sed -n $p FILE` passed only
    #: while `$name` expansion was accidentally uppercase-only; the day
    #: the shell got lowercase names right (Bourne semantics, and what
    #: the operator typed at the console), `$p` correctly expanded to
    #: nothing and sed read the filename as its script. `a*al` was the
    #: same hazard one accident away -- an unquoted glob that only
    #: survives because nothing matches it.
    _SH_SPECIAL = set('$*?[]{}\\"\'`~|&;<>()# \t')

    @staticmethod
    def _sh_quote(word):
        if not set(word) & Case._SH_SPECIAL:
            return word
        # FOUND 2026-09-14 (landing printf, verified live on the
        # emulator): a bare backslash inside SINGLE quotes is NOT
        # always literal on this sh -- `'...\n...'` confuses its own
        # quote/line scanner ("sh: unterminated quote" when the `\n`
        # sits right before the closing quote, "sh: mixed quoting"
        # otherwise), where `'...\z...'` (an unrecognised escape
        # letter) passes through untouched -- so sh's OWN escape table
        # (shared with something like echo/printf's, guessed from the
        # symptom, not read out of shlex.s here) is reachable even
        # inside a single-quoted word. DOUBLE quotes side-step it:
        # POSIX says a backslash before anything other than $ ` " \ or
        # a newline stays literal there, and this sh's C-style escape
        # apparently does not fire inside double quotes either
        # (verified live: `"ab\ncd"` echoes unchanged). Used only when
        # the word carries none of $ ` " itself -- double quotes do
        # not suppress THOSE, unlike single quotes, and a handful of
        # existing regex operands here mix a backslash with a literal
        # `$` anchor ('^a\{2,4\}$') that must stay single-quoted.
        if '\\' in word and not (set(word) & set('$`"')):
            return f'"{word}"'
        if "'" in word:
            raise ValueError(f'cannot single-quote {word!r} for sh')
        return f"'{word}'"

    def sh_line(self):
        words = [self.tool.upper()]
        words += self.mflags
        words += [f'{IMG_DIR}/{o.name}' if isinstance(o, (Ref, Missing, Path))
                  else self._sh_quote(o)
                  for o in self.operands]
        if self.stdin is not None:
            words += ['<', f'{IMG_DIR}/{self.stdin.name}']
        words += ['>', f'{IMG_DIR}/{self.out_name}', REDIR_SUFFIX]
        line = ' '.join(words)
        if len(line) > SH_LINEMAX:
            raise ValueError(
                f'case {self.cid}: sh line is {len(line)} bytes, over '
                f"src/bin/sh.s's LINEMAX of {SH_LINEMAX}: {line}")
        return line

    # -- host side ------------------------------------------------------
    def _host_argv(self, hostdir, argv_spec):
        out = [REF.ref_tool(self.tool)]
        for tok in argv_spec:
            out.append(os.path.join(hostdir, tok.name)
                       if isinstance(tok, (Ref, Missing, Path)) else tok)
        return out

    def reference(self, hostdir):
        """Run the host reference.  Returns (stdout, stderr, status,
        extra_stdouts) as bytes/int, with host paths rewritten to the
        image paths maux would have printed."""
        spec = (self.ref_argv if self.ref_argv is not None
                else self.mflags + self.operands)
        results = []
        for argv_spec in [spec] + self.ref_extra:
            argv = self._host_argv(hostdir, argv_spec)
            stdin_data = b''
            if self.stdin is not None:
                with open(os.path.join(hostdir, self.stdin.name), 'rb') as fh:
                    stdin_data = fh.read()
            env = dict(os.environ)
            # docs/E2E.md sec 4's ('sort', 'locale collation') entry is
            # DISCHARGED HERE, by configuring the oracle rather than by
            # forgiving a difference afterwards: maux compares raw bytes
            # and has no locales, so the reference is asked for the same.
            env['LC_ALL'] = 'C'
            env['LANG'] = 'C'
            # argv[0] = the BARE tool name, the path goes in `executable`:
            # GNU tools echo argv[0] verbatim in diagnostics ("/bin/grep:
            # X: No such file or directory") where BSD tools and maux both
            # print the bare name ("grep: X: ..."). Spawned by full path
            # on Linux, the reference's stderr never matched and the
            # comparator self-test rejected correct answers for every
            # missing-operand case (first box run, 2026-09-05). Same
            # bytes on macOS either way.
            exe = argv[0]
            argv = [os.path.basename(exe)] + argv[1:]
            proc = subprocess.run(argv, executable=exe, input=stdin_data,
                                  env=env, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE)
            results.append(proc)
        head = results[0]
        prefix = hostdir.rstrip('/') + '/'
        def unpath(data):
            return data.replace(prefix.encode(), (IMG_DIR + '/').encode())
        return (unpath(head.stdout), unpath(head.stderr), head.returncode,
                [unpath(p.stdout) for p in results[1:]])


class ShCase(Case):
    """A differential case whose SUBJECT IS `sh` ITSELF.

    Every other case in this file runs one utility and asks the host for
    the same utility's answer.  These run a shell CONSTRUCT and ask a
    host POSIX shell for the same construct's answer -- the oracle is
    `/bin/sh`, not a tool binary.  Section 4's rule is unchanged and is
    what makes this worth building: nothing here authors an expected
    output, so a construct maux gets subtly wrong cannot be blessed by
    my own idea of what it should print.

    WHY THIS EXISTS (2026-08-27).  The stage-1 corpus covered 15
    utilities and ZERO shell language -- not even a pipe.  Meanwhile the
    shell had just grown `$( )`, `( )` grouping, the `${V-w}` family,
    `$*`/`$@` and `$$`, all of which were gated only by `check-shlang`
    (script form) and `check-play` (typed form), both of which compare
    against expectations I wrote by hand.  A construct family with no
    independent oracle is exactly what this harness exists to prevent.

    TWO LINES, WRITTEN OUT, NOT DERIVED.  `maux` is the line maux's `sh`
    runs; `ref` is the equivalent for the host shell.  They differ in
    spelling only -- maux's commands are upper case and its paths are
    image paths.  Deriving one from the other by lower-casing was
    rejected for the same reason `ref_argv` is explicit: a silent
    transform is a place for an expectation to leak in.  Any difference
    beyond spelling must cite a divergence entry, exactly as elsewhere.
    """

    def __init__(self, cid, name, maux, ref, **kw):
        super().__init__(cid, 'sh', **kw)
        self.name = name
        self.maux = maux
        self.ref = ref

    def sh_line(self):
        line = f'{self.maux} > {IMG_DIR}/{self.out_name} {REDIR_SUFFIX}'
        if len(line) > SH_LINEMAX:
            raise ValueError(
                f'case {self.cid} ({self.name}): sh line is {len(line)} '
                f"bytes, over src/bin/sh.s's LINEMAX of {SH_LINEMAX}: "
                f'{line}')
        return line

    def reference(self, hostdir):
        """Run `ref` through a host POSIX shell, with cwd=hostdir so any
        bare fixture name resolves the same way it does on the image.

        THE REDIRECT IS PART OF THE CASE, so the reference must carry it
        too -- it is not enough to capture the host's stdout.  In a `;`
        list, `> FILE` binds to the LAST command only: `echo A ; echo C >
        F` puts `C` in F and leaves `A` on the terminal.  That is correct
        POSIX and maux implements it correctly.  Capturing the host's
        whole stdout instead compares maux's last-command output against
        the host's every-command output, and the difference reads exactly
        like a maux bug.

        It did.  The first run of this section (2026-08-27) reported that
        `${U=asg}` failed to persist its assignment -- maux printing
        `asg` once where the host printed it twice.  maux was right the
        whole time: its 4 bytes WERE the second ECHO's output, which is
        the proof the assignment persisted.  A control case (`ECHO A ;
        ECHO C`, no new features at all) is what exposed the harness
        rather than the shell.

        This is docs/E2E.md sec 4's foundational rule broken from the
        same side as the B4 cwd incident: an expectation synthesised from
        a reference invoked DIFFERENTLY from the subject is not an oracle,
        it is a fabricated expectation wearing the reference's clothes.
        Running the identical redirect on both sides removes the class.
        """
        env = dict(os.environ)
        env['LC_ALL'] = 'C'
        env['LANG'] = 'C'
        out_path = os.path.join(hostdir, f'REF{self.out_name}')
        script = f'{self.ref} > {out_path} {REDIR_SUFFIX}'
        proc = subprocess.run([REF.ref_tool('sh'), '-c', script],
                              input=b'', env=env, cwd=hostdir,
                              stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE)
        try:
            with open(out_path, 'rb') as fh:
                captured = fh.read()
            os.unlink(out_path)
        except FileNotFoundError:
            captured = b''
        prefix = hostdir.rstrip('/') + '/'

        def unpath(data):
            return data.replace(prefix.encode(), (IMG_DIR + '/').encode())

        # Anything the host shell wrote OUTSIDE the redirect (a `;` list's
        # earlier commands) is deliberately dropped, not compared: maux's
        # own console output is not captured either, so comparing it would
        # reintroduce the asymmetry this method exists to remove.
        return (unpath(captured), b'', proc.returncode, [])


def build_cases():
    R = Ref
    M = Missing
    P = Path
    c = []
    n = 0

    def add(*a, **k):
        nonlocal n
        n += 1
        c.append(Case(n, *a, **k))
        return c[-1]

    # ---- sort ---------------------------------------------------------
    add('sort', [], [R('FUNS')])
    add('sort', ['-r'], [R('FUNS')])
    add('sort', ['-u'], [R('FDUP2')])
    add('sort', ['-ru'], [R('FDUP2')], note='clustered flags')
    add('sort', ['-u'], [R('FTWIN')],
        note='THE 2026-08-23 BUG: lines identical through byte PAGE-1, '
             'differing at PAGE. A wrapped compare drops one silently.')
    add('sort', [], [R('FTWIN')])
    add('sort', ['-u'], [R('FCTRL')],
        note='CONTROL for the case above -- differs INSIDE the 8-bit '
             'walk, so it must stay green when that walk is broken.')
    add('sort', [], [R('FEMPTY')])
    add('sort', [], [R('FNOEOL')],
        note='unterminated final line gets a CR on both sides')
    add('sort', ['-n'], [R('FSORTN')],
        note='numeric: negatives, 007==7 and abc==0 resolved by the '
             'last-resort whole-line compare, blank-led digits, and '
             '10>9>2 where lexical order inverts.')
    add('sort', ['-rn'], [R('FSORTN')],
        note='-r composes with -n: the flip happens at the call site, '
             'AFTER the comparator, so it must reverse ties too '
             '(the reference reverses the last-resort as well).')
    add('sort', ['-n'], [R('FUNS')],
        note='-n on mostly WORDS: every word is value 0, so the order '
             'is the last-resort lexical one with 2/9/10 threaded in '
             'front -- a comparator that refuses no-digit lines '
             'instead of valuing them 0 shatters this.')
    add('sort', ['-k2'], [R('FSORTK')],
        note='-k2 runs to END OF LINE and each field OWNS ITS LEADING '
             'BLANKS (measured, /usr/bin/sort): "c  1" (key "  1") '
             'sorts before "b 1" (key " 1"), and "a 10" before "a 2".')
    add('sort', ['-k2,2'], [R('FSORTK')],
        note='-k2,2 stops after field 2: x/y with equal field 2 fall '
             'to the last-resort whole-line compare, where -k2 (to '
             'end of line) already decided on field 3 -- the one '
             'output difference between the two spellings here.')
    add('sort', ['-n', '-k2'], [R('FSORTK')],
        note='-n at a -k start: the numeric parse begins at the key, '
             'so field 2\'s 10 outranks 2 numerically where the -k2 '
             'case above ordered them lexically.')
    add('sort', [], [R('FUNS'), R('FDUP2')], note='two operands, one sort')
    add('sort', [], [], stdin=R('FUNS'), note='no operand -> fd 0')
    add('sort', [], [R('FLONG')], note='PAGE-1 / PAGE / PAGE+1 lines')
    add('sort', [], [R('FLONG2')],
        note='PAGE+1 line sorts FIRST: a 257-char PUTS into an EMPTY '
             'full-buffered stream -- the bulk append\'s 256-byte '
             'chunk with Y wrapped to 0 (SIO_PUTSB wrap-carry teeth)')

    # ---- diff ---------------------------------------------------------
    add('diff', [], [R('FDA'), R('FDB')])
    add('diff', ['-e'], [R('FDA'), R('FDB')])
    add('diff', [], [R('FDA'), R('FDACOPY')],
        diverges=[('*', 'the same file cannot be opened twice')],
        note='identical content in two files -> no output, 0')
    add('diff', [], [R('FTWIN'), R('FTWINB')],
        note='THE 2026-08-23 BUG: differing files reported identical, '
             'exit 0, no output.')
    add('diff', [], [R('FCTRL'), R('FCTRLCP')],
        diverges=[('*', 'the same file cannot be opened twice')],
        note='control: genuinely identical, must stay 0/no output')
    add('diff', [], [R('FDA'), R('FDC')],
        compare='diff_nonewline',
        diverges=[('diff', 'no-newline marker')],
        note='file2 has no trailing newline')
    add('diff', [], [R('FEMPTY'), R('FDA')])
    add('diff', [], [R('FDA'), R('FEMPTY')])

    # ---- tr -----------------------------------------------------------
    add('tr', [], ['A-Z', 'a-z'], stdin=R('FMIX'))
    add('tr', ['-d'], ['AEIOU'], stdin=R('FMIX'))
    add('tr', ['-s'], ['LSP'], stdin=R('FMIX'),
        note='squeeze only, ONE operand -- the 2026-08-23 KNOWN_DEFECT, '
             'FIXED by the :sqonly/IDFILL path (stream S7): LL in WORLD '
             '/ LLAMA, SS and PP in MISSISSIPPI each collapse')
    add('tr', ['-s'], ['a-z', 'A-Z'], stdin=R('FMIX'),
        note='TWO-operand -s: translate to uppercase THEN squeeze the '
             'OUTPUT scoped to string2 (SETUPXLT + MEMBER2) -- a '
             'DIFFERENT code path than the one-operand :sqonly/IDFILL '
             'case above; aaabbbccc/AAABBBCCC -> ABC, LLAMA -> LAMA')
    add('tr', ['-cs'], ['0-9'], stdin=R('FMIX'),
        diverges=[('tr', 'complement set is over high-bit bytes')],
        note='-c and -s together, ONE operand: squeeze scope is the '
             "COMPLEMENT of string1 (every non-digit), built by "
             "SETUPDEL's WANT_C branch at :sqonly -- aaabbbccc -> abc, "
             '0123456789 untouched (excluded from the squeeze set)')
    add('tr', ['-s'], ['XQZ'], stdin=R('FMIX'),
        note='squeeze set matches a byte (Q in Quick) but never two in '
             'a row -- ZERO squeezes fire; any output difference here '
             'is IDFILL leaving XTAB non-identity, not squeeze logic')
    add('tr', ['-cd'], ['A-Za-z'], stdin=R('FMIX'),
        diverges=[('tr', 'complement set is over high-bit bytes')])
    add('tr', ['-c'], ['A-Z', '.'], stdin=R('FMIX'),
        diverges=[('tr', 'complement set is over high-bit bytes')])
    add('tr', [], ['ABC', 'XYZ'], stdin=R('FMIX'))
    add('tr', [], ['AB', 'X'], stdin=R('FMIX'),
        note='string2 shorter -> its last byte repeats')
    add('tr', [], ['A-Z', 'a-z'], stdin=R('FEMPTY'))
    add('tr', ['-ds'], ['AEIOU', 'B'], stdin=R('FMIX'), note='clustered')

    # ---- uniq ---------------------------------------------------------
    add('uniq', [], [R('FDUP')])
    add('uniq', ['-c'], [R('FDUP')], compare='uniq_count',
        diverges=[('uniq', 'count field width')])
    add('uniq', ['-d'], [R('FDUP')])
    add('uniq', ['-u'], [R('FDUP')])
    add('uniq', [], [R('FEMPTY')])
    add('uniq', ['-c'], [R('FSA')], compare='uniq_count',
        diverges=[('uniq', 'count field width')])
    add('uniq', [], [], stdin=R('FDUP'), note='no operand -> fd 0/1')

    # ---- comm -----------------------------------------------------
    # comm.s's OUT2/OUT3 grew POSIX's adaptive <lead> 2026-09-13 (was:
    # a fixed 1/2 tabs regardless of suppression) -- maux and the host
    # now agree byte-for-byte with no re-packing transform needed; the
    # 'comm_cols'/'suppressed columns are not re-packed' divergence
    # these three cases used to cite is retired (e2e_divergence.py).
    add('comm', [], [R('FSA'), R('FSB')])
    add('comm', ['-1'], [R('FSA'), R('FSB')])
    add('comm', ['-12'], [R('FSA'), R('FSB')], note='clustered')
    add('comm', ['-3'], [R('FSA'), R('FSB')])
    add('comm', [], [R('FSA'), R('FEMPTY')])
    add('comm', [], [R('FSA'), R('FSACOPY')],
        diverges=[('*', 'the same file cannot be opened twice')],
        note='identical content -> all column 3')

    # ---- wc -----------------------------------------------------------
    add('wc', [], [R('FUNS')], compare='wc_fields',
        diverges=[('wc', 'field padding')])
    add('wc', ['-l'], [R('FLONG')], compare='wc_fields',
        diverges=[('wc', 'field padding')])
    add('wc', ['-c'], [R('FBIN')], compare='wc_fields',
        diverges=[('wc', 'field padding')])
    add('wc', ['-w'], [R('FMIX')], compare='wc_fields',
        diverges=[('wc', 'field padding')])
    add('wc', ['-c'], [R('FRAW1')], compare='wc_fields',
        diverges=[('wc', 'field padding')],
        note='boundary matrix sample: one byte, byte-stable raw input')
    add('wc', ['-c'], [R('FBUFMIN'), R('FBUF'), R('FBUF2')],
        compare='wc_fields',
        diverges=[('wc', 'field padding')],
        note='boundary matrix sample: SORT_BUFSZ-1 / exact / +1; the '
             '765-byte total is now CHECKED against the host')
    add('wc', ['-c'], [R('FPWMIN'), R('FPWEXACT'), R('FPWPLUS')],
        compare='wc_fields',
        diverges=[('wc', 'field padding'),
                  ('wc', 'totals saturate at 65535')],
        note='boundary matrix sample: process window -1 / exact / +1; '
             'three ~46 KB operands sum to 140,544 -- the only case that '
             'reaches wc\'s 16-bit total ceiling')
    add('wc', ['-lw'], [R('FMIX')], compare='wc_fields',
        diverges=[('wc', 'field padding')], note='clustered')
    add('wc', [], [R('FUNS'), R('FDUP')], compare='wc_fields',
        diverges=[('wc', 'field padding')],
        note='2-operand lines/words/bytes total, CHECKED against the host')
    add('wc', [], [], stdin=R('FUNS'), compare='wc_fields',
        diverges=[('wc', 'field padding')], note='stdin -> no name column')
    add('wc', [], [R('FNOEOL')], compare='wc_fields',
        diverges=[('wc', 'field padding')],
        note='unterminated final line is not a line')

    # ---- od -----------------------------------------------------------
    add('od', [], [R('FBIN')], compare='od_rows',
        ref_argv=['-v', '-t', 'x1', R('FBIN')],
        diverges=[('od', 'default format is byte-wise hex'),
                  ('od', 'offset radix'), ('od', 'hex digit case')])
    add('od', ['-b'], [R('FBUF')], compare='od_rows',
        ref_argv=['-v', '-b', R('FBUF')],
        diverges=[('od', 'offset radix')])
    add('od', ['-c'], [R('FODC')], compare='od_rows',
        ref_argv=['-v', '-c', R('FODC')],
        diverges=[('od', 'offset radix'),
                  ('od', '-c renders every non-printable as a dot'),
                  ('od', '-c whitespace tokenisation')])
    add('od', [], [R('FEMPTY')], compare='od_rows',
        ref_argv=['-v', '-t', 'x1', R('FEMPTY')],
        diverges=[('od', 'offset radix'), ('od', 'hex digit case'),
                  ('od', 'empty input still prints the end offset')])
    add('od', ['-bx'], [R('FBUF2')], compare='od_rows',
        ref_argv=['-v', '-t', 'x1', R('FBUF2')],
        ref_extra=[['-v', '-b', R('FBUF2')]],
        diverges=[('od', 'offset radix'), ('od', 'hex digit case'),
                  ('od', 'default format is byte-wise hex'),
                  ('od', 'combined formats emit one row each')],
        note='clustered; fixed hex-then-octal order')
    add('od', [], [], stdin=R('FBUF'), compare='od_rows',
        ref_argv=['-v', '-t', 'x1'],
        diverges=[('od', 'offset radix'), ('od', 'hex digit case'),
                  ('od', 'default format is byte-wise hex')],
        note='no operand -> fd 0')

    # ---- cmp --------------------------------------------------------
    # The ('cmp', 'diagnostics go to stderr') divergence these cases
    # used to cite is retired 2026-09-13: cmprpt.s's DIFFER now writes
    # the plain differ message to FD_STDOUT (POSIX's own rule, matching
    # BSD cmp), so maux and the host land it on the same descriptor and
    # no forgiveness is needed. compare='cmp_msg' stays -- both sides'
    # stdout+stderr are still merged by REDIR_SUFFIX, and the
    # comparator's plain got==ref_out check is unaffected.
    add('cmp', [], [R('FDA'), R('FDB')], compare='cmp_msg')
    add('cmp', [], [R('FDA'), R('FDACOPY')],
        diverges=[('*', 'the same file cannot be opened twice')],
        note='identical content -> silent, 0')
    add('cmp', ['-s'], [R('FDA'), R('FDB')], note='silent, status only')
    add('cmp', [], [R('FBIN'), R('FBIN2')], compare='cmp_msg',
        diverges=[('cmp', 'line rule is $8D, not $0A')],
        note='binary, difference past the BUFSZ seam')
    add('cmp', [], [R('FDAPRE'), R('FDA')], compare='cmp_msg',
        note='file1 is a prefix of file2 -> EOF message')
    add('cmp', ['-l'], [R('FCMPL1'), R('FCMPL2')],
        note='-l lists EVERY pair as "%6d %3o %3o" (measured BSD '
             'bytes: right-aligned offset, space-padded octal), '
             'continues to EOF, exits 1. No filenames in the output, '
             'so no pathname divergence -- a plain byte compare.')
    add('cmp', ['-l'], [R('FCMPL1'), R('FCMPL3')],
        note='-l on identical content: silence, exit 0 -- DIFFFLG '
             'must not misfire.')
    add('cmp', [], [R('FTWIN'), R('FTWINB')], compare='cmp_msg',
        note='the byte-PAGE difference, seen by a byte comparator')

    # ---- cat ----------------------------------------------------------
    add('cat', [], [R('FONE'), R('FONE')],
        note='boundary matrix sample: duplicate operand, sequential open')

    # ---- sum ----------------------------------------------------------
    add('sum', [], [R('FBLK511'), R('FBLK1'), R('FBLK2')],
        compare='sum_row',
        diverges=[('sum', 'blocks are 512-byte ProDOS blocks')],
        note='boundary matrix sample: 511 / 512 / 513 bytes')
    add('sum', [], [R('FBLK1')], compare='sum_row',
        diverges=[('sum', 'blocks are 512-byte ProDOS blocks')])
    add('sum', [], [R('FBLK2')], compare='sum_row',
        diverges=[('sum', 'blocks are 512-byte ProDOS blocks')],
        note='one byte past a block boundary')
    add('sum', [], [R('FBIN')], compare='sum_row',
        diverges=[('sum', 'blocks are 512-byte ProDOS blocks')])
    add('sum', [], [R('FIOB')], compare='sum_row',
        diverges=[('sum', 'blocks are 512-byte ProDOS blocks')])
    add('sum', [], [], stdin=R('FBIN'), compare='sum_row',
        diverges=[('sum', 'blocks are 512-byte ProDOS blocks')],
        note='stdin -> no name column')
    add('sum', [], [R('FEMPTY'), R('FBUF')], compare='sum_row',
        diverges=[('sum', 'blocks are 512-byte ProDOS blocks')],
        note='two operands; both byte-stable (see check_byte_stable)')

    # ---- sed ----------------------------------------------------------
    add('sed', [], ['s/alpha/beta/', R('FSEDBIG')],
        note='multi-window stream: the substitution is incidental; the '
             'fixture is what matters (see FSEDBIG).')
    add('sed', [], ['s/alpha/beta/', R('FSEDALN')],
        note='every CR on a window boundary, every 4th on a chunk '
             'boundary (see FSEDALN) -- the refill-alias tooth.')
    add('sed', [], ['s/[0-9]\\{4\\}/X/', R('FINTV')],
        note='W5b: the interval on the REPLACEMENT side of the same '
             'engine -- 12345 -> X5 (leftmost four), x1234y -> xXy, '
             'a{4} untouched. RED on 6aca6f0.')
    add('sed', [], ['s/a\\{2,4\\}/Z/g', R('FINTV2')],
        note='W5b: greedy up to the ceiling, then the rest -- aaaaa '
             '-> Za (4 taken, 1 left), a untouched (under the floor).')
    add('sed', ['-n'], ['$p', R('FSEDALN')],
        note='the $ peek right after an ALIGNED chunk drain is the '
             'refill that clobbered a zero-copy pattern space.')
    add('sed', ['-n'], ['$p', R('FSEDBIG')],
        note='the $ address across a window chain -- PEEKEOF must call '
             'a line non-last while three windows are still pending.')

    # ---- grep ---------------------------------------------------------
    add('grep', [], ['alpha', R('FGREP')])
    add('grep', ['-c'], ['alpha', R('FGREP')])
    add('grep', ['-n'], ['alpha', R('FGREP')])
    add('grep', ['-v'], ['alpha', R('FGREP')])
    add('grep', [], ['alpha'], stdin=R('FGREP'),
        note='no file operands -> fd 0')
    add('grep', [], ['alpha', R('FGREP'), R('FGREP2')],
        note='TWO operands -> every selected line carries the operand it '
             'came from, AS TYPED. Pinned as a KNOWN_DEFECT when it was '
             'written; the 2026-08-24 grep.s prefix fix retired the pin.')
    add('grep', ['-n'], ['alpha', R('FGREP'), R('FGREP2')],
        note='FILE:NUM:line -- and the numbering RESTARTS at FGREP2. A '
             'counter that runs on across files is the second bug this '
             'case exists to catch, and it was there.')
    add('grep', ['-c'], ['alpha', R('FGREP'), R('FGREP2')],
        note='-c over two files is ONE COUNT PER FILE under the same '
             'prefix rule, not one total -- the shape the single-file -c '
             'case above cannot distinguish.')
    add('grep', [], ['NEEDLE', R('FGLONG')],
        compare='grep_linemax',
        diverges=[('grep', 'linemax truncates overlong lines')],
        note='GREP_LINEMAX-1 / exact / +1 selected lines')
    add('grep', [], ['A.B', R('FGBIN')],
        note='dot matches a control-byte payload under high-bit image text')
    add('grep', [], ['alpha', M('GNOSUCH'), R('FGREP2')],
        compare='grep_open_continue',
        diverges=[('grep', 'open-failure continuation framing')],
        note='unreadable operand first, readable operand after it. The '
             "host -h that used to isolate this from the prefix defect is "
             'GONE: two operands were given, so both sides prefix the '
             'surviving one, and an operand that failed to open still '
             'counts toward the decision.')
    add('grep', [], ['a.*t', R('FGREP')],
        note='DOT-STAR -- the most common star idiom, and until '
             '2026-08-28 covered by NO fast gate at all (grepped: no '
             '.* in this corpus, the sed runs, or the ed script). '
             'Selects only "alphabet", which needs the greedy dot run '
             'to GIVE BACK down to the final t -- so it exercises the '
             'backtrack loop AND the specialized dot greedy scan '
             '(regex.s :gdot).')
    add('grep', [], ['a*al', R('FGREP')],
        note='NON-DISJOINT star: the atom after a* is a literal the '
             'star itself matches, so "al" in alpha/alphabet is ONLY '
             'reachable by giving back a greedy repetition -- an engine '
             'that tries just the longest run finds no match at all. '
             'Teeth for RE_MATCHSTAR\'s disjoint-atom fast path '
             '(docs/PERF-PLAN.md step 2): proven red against a sabotage '
             'that took the fast path unconditionally, which check-sed '
             'and check-ed both survived (2026-08-28).')
    add('grep', ['-e', 'alpha', '-e', 'beta'], [R('FGREP')],
        note='a pattern SET: either pattern selects. This was a RULED '
             'divergence -- maux held one pattern and refused the second '
             '-e with its banner -- until 2026-09-21, when -e and -f both '
             'landed on PATMAX slots in the `dum` arena. It is an ordinary '
             'differential row now, which is the point of retiring a '
             'ruling rather than deleting the case.')
    add('grep', ['-ealpha'], [R('FGREP')],
        note='-eRE, ATTACHED form. Same selection as the separated one, '
             'and the two share only the OPTLIST entry -- getopt takes a '
             'different branch for each.')
    add('grep', ['-i'], ['alpha', R('FGREP')],
        note='-i folds the LINE: ALPHA joins the selection, and the '
             'printed line is the ORIGINAL (upper) -- a fold-in-place '
             'that prints the folded copy fails this case.')
    add('grep', ['-i'], ['ALPHA', R('FGREP')],
        note='-i folds the PATTERN: an upper-case RE selects the same '
             'three lines. The pattern fold happens AFTER option '
             'parsing, so -e RE -i order works too -- but this case '
             'proves only the fold itself; the line-fold case above is '
             'the other half.')
    add('grep', ['-iv'], ['alpha', R('FGREP')],
        note='-v composes with -i: the inverted selection must also '
             'exclude ALPHA, which a -v that consults the unfolded '
             'match result would keep.')
    add('grep', ['-l'], ['alpha', R('FGREP'), R('FGREP2')],
        note='-l prints each NAME once, first hit, and abandons the '
             'rest of the file -- a -l that keeps reading prints a '
             'name per match.')
    add('grep', ['-l'], ['alpha'], stdin=R('FGREP'),
        note='-l on fd 0 prints "(standard input)", the modern '
             'spelling both sides share (measured, /usr/bin/grep).')
    add('grep', ['-s'], ['alpha', M('GNOSUCH'), R('FGREP2')],
        note='-s: the cannot-open MESSAGE is suppressed on both sides '
             '(so no divergence entry, unlike the noisy twin above), '
             'the surviving operand still prefixes, and the status '
             'stays 2 -- scripts keep the signal, humans lose the '
             'noise (measured, /usr/bin/grep).')
    add('grep', [], ['\\([a-z][a-z]*\\) \\1', R('FGRPBACK')],
        note='W5 (ANACHRONISMS.md): grouping + a \\1 backref, the '
             'doubled-WORD idiom -- classic ed/grep use. Selects '
             '"the the quick" only: "the quick fox" (no repeated '
             'word) is the NEGATIVE control in the SAME invocation, '
             'so a backref that accidentally matches everything '
             'cannot pass silently, and "foofoo"/"foobar" stay '
             'unselected too (no space in either). Reverting '
             'grouping/backref to their pre-feature literal-char '
             'reading turns this pattern into a literal open-paren, '
             'the class, a literal close-paren, a space, and a '
             'literal digit 1 -- RED, matches nothing in the '
             'fixture -- the sabotage-provable half of these teeth.')
    add('grep', [], ['\\(foo\\)\\1', R('FGRPBACK')],
        note='W5: the SIMPLEST group+backref case, no class or star '
             'inside the group -- "foofoo" (doubled) selected, '
             '"foobar" (not doubled) is the negative control in the '
             'same invocation. Isolates the backref mechanism from '
             'the word-doubling idiom above.')
    add('grep', [], ['^\\(ab\\)*$', R('FGRPSTAR')],
        note='W5: grouping does not break PRECEDENCE with the star '
             '-- it applies to the WHOLE GROUP, not just the last '
             'atom before it, so "ababab"/"abab" (the whole line is '
             'some number of "ab" repeats, more than one included) '
             'are selected and "aba"/"abc"/"baba" (odd tail, wrong '
             'content, or wrong start) are not. Anchored both ends: '
             'unanchored, the group-star trivially zero-matches '
             'every line and the case would prove nothing (measured '
             'against /usr/bin/grep while designing this case).')
    add('grep', [], ['[0-9]\\{4\\}', R('FINTV')],
        note='W5b: the interval \\{4\\} is EXACTLY four digits -- '
             'selects 12345, 1234 and x1234y, not 123 and not the '
             'literal-brace lines. RED on 6aca6f0, where \\{ was a '
             'literal brace and the pattern selected nothing.')
    add('grep', [], ['^a\\{2,4\\}$', R('FINTV2')],
        note='W5b: a range, anchored both ends so the ceiling is '
             'observable -- aa/aaa selected, a (under the floor) and '
             'aaaaa (over the ceiling) not.')
    add('grep', [], ['^a\\{3,\\}$', R('FINTV2')],
        note='W5b: a floor with no ceiling -- aaa and aaaaa, not aa.')
    add('grep', [], ['^\\(ab\\)\\{2\\}$', R('FINTV2')],
        note='W5b: the interval on a WHOLE GROUP (RE_GSTAR\'s '
             'floor/ceiling) -- abab only; ab (one rep) and ababab '
             '(three) are the controls.')
    add('grep', [], ['a{4}', R('FINTV')],
        note='W5b OVER-TRIGGER GUARD: a BARE brace is a literal brace '
             '(BRE spelling) -- selects the a{4} line only, never the '
             'four-digit ones. Green before and after.')
    add('grep', [], ['a+b', R('FINTV')],
        note='W5b OVER-TRIGGER GUARD: bare + is literal (the host '
             'agrees) -- selects a+b only.')
    add('grep', [], ['a?b', R('FINTV')],
        note='W5b OVER-TRIGGER GUARD: bare ? is literal -- a?b only.')

    # ---- grep: POSIX -q / -x (2026-09-13) ------------------------------
    add('grep', ['-q'], ['alpha', R('FGREP')],
        note='-q: exit 0 on the first selected line, nothing printed.')
    add('grep', ['-q'], ['nosuch', R('FGREP')],
        note='-q, no match: exit 1, still nothing printed.')
    add('grep', ['-q', '-c'], ['alpha', R('FGREP')],
        note='-q silences -c too -- no count, just exit 0.')
    add('grep', ['-q'], ['alpha', M('GNOSUCH'), R('FGREP2')],
        compare='grep_open_continue',
        diverges=[('grep', 'open-failure continuation framing')],
        note='an unopenable operand, then one that matches: -q exits 0 '
             'even though an earlier operand failed to open -- the '
             'early exit on the FIRST selected line happens before the '
             'ERRFLAG-outranks-MATCHED rule is ever consulted. The '
             'diagnostic for the unopenable operand still goes to '
             'stderr; only stdout is silenced.')
    add('grep', ['-q', '-v'], ['alpha', R('FGREP')],
        note='-q composes with -v: the first line -v SELECTS (beta, '
             'which does not contain alpha) still exits(0) immediately.')

    add('grep', ['-x'], ['alpha', R('FGREP')],
        note='-x: whole-line match -- "alpha" only, not "alphabet" '
             '(longer) and not "ALPHA" (case differs, no -i).')
    add('grep', ['-x', '-i'], ['alpha', R('FGREP')],
        note='-x composes with -i: folding first then anchoring (or '
             'the reverse -- anchors are not letters) selects both '
             '"alpha" and "ALPHA", still not "alphabet".')
    add('grep', ['-x'], ['alph.*', R('FGREP')],
        note='-x anchors, it does not span-check -- "^alph.*$" lets '
             'the backtracking .* run to the true end of each line, '
             'so both "alpha" and "alphabet" (which the unanchored '
             'a.*t case already selects a different way) come out '
             'whole-line matched. Measured against /usr/bin/grep.')
    add('grep', ['-x'], ['^alpha$', R('FGREP')],
        note='already anchored both ends: XANCHOR must recognise both '
             'and add neither, leaving "alpha" selected. A sabotaged '
             'XANCHOR that prepends/appends unconditionally would '
             'build "^^alpha$$" instead -- RE_MATCH only special-cases '
             'a leading `^` at pattern POSITION 0, so the second one '
             'is just a literal caret no line contains, and a `$` '
             'that is not the pattern\'s true last char is literal '
             'too (regex.s :chkdlr), so the doubled form matches '
             'NOTHING -- this case goes from 1 selection to 0 under '
             'that sabotage, not a subtler miscount.')
    add('grep', ['-x', '-v'], ['alpha', R('FGREP')],
        note='-x -v: every line except the exact "alpha" -- "alphabet" '
             'comes BACK under -v because it fails the whole-line test, '
             'unlike plain -v alpha which already excludes it.')
    add('grep', ['-x', '-c'], ['alpha', R('FGREP')],
        note='-x -c: counts only the whole-line match, 1 -- the plain '
             '-c alpha case above counts 3 (alpha/alphabet/ALPHA).')
    add('grep', ['-x'], ['a*', R('FGRPSTAR')],
        note='-x with a pattern that can match a PREFIX of every line '
             'but the WHOLE line of none (no line here is all-"a"s, '
             'and none is empty): selects nothing, exit 1 -- the case '
             'a naive span-check on RE_MSTART/RE_MEND could get wrong '
             'in the other direction by accepting the leading run.')
    add('grep', ['-x', '-n'], ['gamma', R('FGREP')],
        note='-x composes with -n: "4:gamma", the plain-name checks '
             'above cover -c/-v/-i so this is -n\'s own turn.')

    # ---- tee ----------------------------------------------------------
    add('tee', [], [P('TEEOUT')], stdin=R('FMIX'))
    add('tee', ['-a'], [P('TEEAPP')], stdin=R('FONE'),
        note='append spelling; stdout remains a byte-for-byte copy')
    add('tee', [], [P('TEEBIN')], stdin=R('FGBIN'),
        note='control-byte payload through high-bit text transport')
    add('tee', [], [M('NO.DIR/TEEFAIL'), P('TEEOK')], stdin=R('FONE'),
        compare='tee_open_continue',
        diverges=[('tee', 'open-failure continuation framing')],
        note='bad output path first; stdout and later files continue')
    add('tee', [], [R('FSELF2')], stdin=R('FSELF2'),
        compare='tee_self_output',
        diverges=[('tee', 'self-output reopens stdin target')],
        status_ruled=('tee', 'self-output reopens stdin target'),
        note='boundary matrix sample: self-output; the host reference is '
             'fed from a pipe already read from FSELF2, while maux holds '
             'FSELF2 open as fd 0 and tee opens it for output, which '
             'truncates the very file it is reading (Unix does too)')

    # ---- echo ---------------------------------------------------------
    add('echo', [], [])
    add('echo', [], ['HELLO', 'WORLD'])
    add('echo', [], ['-n', 'ALPHA'],
        note='-n suppresses the trailing CR (FLEET F.2, 2026-09-01) '
             '-- this case was a RULED divergence while echo had no '
             'flags; the flag landing RETIRED the entry, and both '
             'sides now emit the bare 5 bytes.')
    add('echo', [], ['ALPHA', '-n'],
        note='-n is argv[1] ONLY: anywhere else it is an operand, '
             'printed literally -- the reference agrees (measured, '
             '/bin/echo).')
    add('echo', [], ['-n'],
        note='`echo -n` alone prints NOTHING -- not a bare CR '
             '(measured, /bin/echo).')

    # ---- expr ---------------------------------------------------------
    add('expr', [], ['2', '+', '3'])
    add('expr', [], ['20', '/', '5', '+', '3'],
        note='operator precedence: division before addition')
    add('expr', [], ['7', '%', '4'])
    add('expr', [], ['3', '=', '3'])
    add('expr', [], ['1', '-', '1'],
        note='prints 0 and exits 1, same as host expr')

    # ---- tail ---------------------------------------------------------
    add('tail', [], [R('FTAIL')])
    add('tail', ['-n', '3'], [R('FTAIL')],
        note='-n N, the POSIX spelling (FLEET F.2 A12, 2026-09-01) -- '
             'feeds the same accumulator as bare -N.')
    add('tail', ['-n3'], [R('FTAIL')],
        note='-nN attached form, through getopt\'s other branch.')
    add('tail', ['-3'], [R('FTAIL')])
    add('tail', [], [], stdin=R('FTAIL'), note='no operand -> fd 0')
    add('tail', ['-0'], [R('FTAIL')])
    add('tail', [], [R('FNOEOL')], compare='tail_noeol',
        diverges=[('tail', 'unterminated final line is normalised')],
        note='maux tail prints a CR after an unterminated final line')

    # ---- head -----------------------------------------------------
    add('head', [], [R('FTAIL')],
        note='default N=10 -- FTAIL has 12 lines, so this proves the '
             'copy actually STOPS rather than draining the file')
    add('head', ['-n', '3'], [R('FTAIL')],
        note='-n N, the POSIX spelling -- feeds the same accumulator '
             'as bare -N (tail\'s own precedent).')
    add('head', ['-3'], [R('FTAIL')])
    add('head', ['-n', '20'], [R('FTAIL')],
        note='N greater than the file\'s line count: prints the whole '
             'file, no error -- head is a prefix copy, not a fenced '
             'ring, so there is no capacity to overflow')
    add('head', [], [R('FSELF'), R('FTAIL')],
        note='two operands: ==> NAME <== headers, blank-line-separated, '
             'never printed for a single file (measured, BSD head)')
    add('head', [], [], stdin=R('FTAIL'), note='no operand -> fd 0')
    add('head', [], [M('HNOSUCH'), R('FTAIL')],
        compare='head_open_continue',
        diverges=[('head', 'open-failure continuation framing')],
        note='unopenable operand first, readable operand after it -- '
             'diagnostic, continue, exit 1')

    # ---- cut ------------------------------------------------------
    add('cut', ['-c', '1-3'], [R('FDA')],
        note='basic column range')
    add('cut', ['-c', '2,4-'], [R('FDA')],
        note='a bare number and an open range in one list -- order '
             'and duplicates in the list do not matter, only the '
             'ascending scan of the line does')
    add('cut', ['-c', '-2'], [R('FDA')],
        note='"-M" defaults the low end to column 1')
    add('cut', ['-b', '1-3'], [R('FDA')],
        note='-b and -c are the SAME operation on this 7-bit-ASCII '
             'machine -- no multibyte characters to split')
    add('cut', ['-f', '2'], [R('FCUTTAB')],
        note='default delimiter is TAB')
    add('cut', ['-f', '1,3', '-d', ':'], [R('FCUTCOLON')],
        note='-d changes the delimiter; the OUTPUT delimiter is the '
             'same byte, joining the two selected non-adjacent '
             'fields')
    add('cut', ['-f', '2', '-s'], [R('FCUTMIX')],
        note='-s suppresses the one line with no delimiter entirely '
             '-- not even its terminator')
    add('cut', ['-f', '2'], [R('FCUTMIX')],
        note='without -s the same delimiterless line passes through '
             'UNCHANGED regardless of which field was asked for '
             '(measured, BSD cut)')
    add('cut', ['-c', '1-3'], [], stdin=R('FDA'),
        note='no operand -> fd 0')
    add('cut', ['-c', '1-3'], [M('CUTNOSUCH'), R('FDA')],
        compare='cut_open_continue',
        diverges=[('cut', 'open-failure continuation framing')],
        note='unopenable operand first, readable operand after it -- '
             'diagnostic, continue, exit 1 (no header: unlike head, '
             'cut has none)')

    # ---- cksum -- XCU cksum.html. 'raw' fixtures only (see FCKONE/
    # FCKTXT's own comment); the CRC ALGORITHM is verified byte-for-
    # byte against this host's own /usr/bin/cksum (see cksum.s's
    # header), so a plain exact comparator is correct here -- no
    # divergence, no custom comparator.
    add('cksum', [], [R('FEMPTY')], note='empty file -> 4294967295 0')
    add('cksum', [], [R('FCKONE')], note='1-byte file')
    add('cksum', [], [R('FBLK511')],
        note='boundary matrix sample: 511 bytes (see sum\'s own '
             'FBLK511/FBLK1/FBLK2 -- cksum has no block column, so '
             'no divergence here, unlike sum_row')
    add('cksum', [], [R('FBLK1')], note='512 bytes, the ProDOS seam')
    add('cksum', [], [R('FBLK2')], note='513 bytes, one past the seam')
    add('cksum', [], [R('FCKTXT')], note='a plain text file')
    add('cksum', [], [R('FCKTXT'), R('FCKONE')],
        note='two files -- both get a NAME column, even the first '
             '(unlike sum.s: cksum names EVERY operand, never only '
             'when there is more than one)')
    add('cksum', [], [], stdin=R('FCKTXT'),
        note='no operand -> fd 0, no NAME column')

    # ---- paste -- XCU paste.html. Every row host-oracled against
    # this Mac's own /usr/bin/paste (measured live before writing
    # paste.s -- see its own header for the algorithm this codifies).
    add('paste', [], [R('FPASTE1'), R('FPASTE2')],
        note='parallel merge, default TAB delimiter, unequal '
             'lengths -- rows keep coming until BOTH files are '
             'exhausted, not until the shorter one is')
    add('paste', [], [R('FPASTE1'), R('FPASTE2'), R('FPASTE3')],
        note='three files, one of them (FPASTE3) the longest -- '
             'proves the row count tracks the LONGEST operand')
    add('paste', ['-d', ','], [R('FPASTE1'), R('FPASTE2')],
        note='-d with a single-character list')
    add('paste', ['-d', '"\\n"'], [R('FPASTE1'), R('FPASTE2')],
        ref_argv=['-d', '\\n', R('FPASTE1'), R('FPASTE2')],
        note='-d escape: \\n means a literal newline delimiter. '
             'MFLAGS bypass Case._sh_quote (only operands go '
             'through it), so this word is hand-quoted with double '
             'quotes for maux\'s sh line -- a bare backslash inside '
             'SINGLE quotes is not literal on this sh, same finding '
             'printf\'s own landing made (posixutil_cases2.py\'s '
             'QQ()). ref_argv hands the HOST the same 2 raw bytes '
             '(backslash, n) directly -- Python subprocess has no '
             "shell to strip the maux-side quoting, so the host's "
             'own argv must skip it rather than re-spell it.')
    add('paste', ['-s'], [R('FPASTE1')],
        note='-s: one row, that file\'s own lines TAB-joined')
    add('paste', ['-s'], [R('FPASTE1'), R('FPASTE2')],
        note='-s with two files: one row PER FILE')
    add('paste', [], ['-', R('FPASTE2')], stdin=R('FPASTE1'),
        note='"-" as an explicit operand means stdin (paste has no '
             'implicit-stdin/no-operand form, unlike cat/head/cut), '
             'mixed with a real file')

    # ---- fold -- XCU fold.html. Every row host-oracled against
    # this Mac's own /usr/bin/fold (measured live before writing
    # fold.s -- see its own header for the column/tab/backspace/-s
    # rules this codifies).
    add('fold', [], [R('FFOLDLONG')],
        note='default width 80 on a 95-column line')
    add('fold', ['-w', '10'], [R('FFOLDTAB')],
        note='a tab that would overshoot column 10 forces an EARLY '
             'break before the tab, not after it (measured live)')
    add('fold', ['-b', '-w', '10'], [R('FFOLDTAB')],
        note='-b: byte count, no tab-stop special-casing at all')
    add('fold', ['-s', '-w', '15'], [R('FFOLDWORDS')],
        note='-s: break after the LAST blank inside the width '
             'window, not at the width boundary itself')
    add('fold', ['-w', '10'], [R('FFOLDEXACT')],
        note='a line exactly at the width: no extra empty row')
    add('fold', ['-w', '5'], [R('FFOLDBLANKLN')],
        note='a lone empty line stays a lone empty line')

    # ---- expand -- XCU expand.html. Every row host-oracled against
    # this Mac's own /usr/bin/expand (measured live before writing
    # expand.s -- see its own header for the periodic-vs-list and
    # backspace rules this codifies).
    add('expand', [], [R('FEXPTAB0')],
        note='a tab at column 0 and another mid-line, default '
             'width-8 stops')
    add('expand', [], [R('FEXPTABMID')],
        note='a tab mid-line, default width-8 stops')
    add('expand', ['-t', '4'], [R('FEXPTABMID')],
        note='-t N (periodic, infinite) -- every tab expands to the '
             'next multiple of 4, not just the first one')
    add('expand', ['-t', '4,10'], [R('FEXPPAST')],
        note='-t list: explicit stops at 4 and 10, then a tab past '
             'the last one becomes exactly ONE space per tab '
             '(measured live)')
    add('expand', [], [R('FEXPBS')],
        note='backspace is written to the output AS ITSELF and '
             'decrements the column for the tab that follows it')
    add('expand', [], [R('FEXPPLAIN')],
        note='a line with no tabs at all: pure passthrough')

    # ---- unexpand -- XCU unexpand.html. Every row host-oracled
    # against this Mac's own /usr/bin/unexpand (measured live before
    # writing unexpand.s -- see its own header for the leading-vs-
    # interior, two-or-more-blanks, and -t-implies-a rules this
    # codifies).
    add('unexpand', [], [R('FUXLEAD8')],
        note='8 leading blanks reach the default column-8 stop -> '
             'one leading tab')
    add('unexpand', [], [R('FUXLEAD5')],
        note='5 leading blanks do NOT reach column 8 -> unchanged')
    add('unexpand', ['-a'], [R('FUXINTER')],
        note='-a converts an INTERIOR run of 2+ blanks that reaches '
             'a stop, not just a leading one')
    add('unexpand', ['-a'], [R('FUXONESP')],
        note='a single space one column short of a stop is never '
             'converted -- one byte for one byte saves nothing')
    add('unexpand', ['-t', '4'], [R('FUXT4')],
        note='-t implies -a (BSD\'s own man page says so, measured '
             'live too): both interior runs convert at width 4')

    # ---- nl -- XCU nl.html. Every row host-oracled against this
    # Mac's own /usr/bin/nl (measured live before writing nl.s --
    # see its own header for the default -b t, the reset-on-ANY-
    # delimiter rule, and the format/width/separator/start/incr
    # options this codifies).
    add('nl', [], [R('FNLPLAIN')],
        note='default: -b t, -n rn, -w 6 -- a plain 3-line file, '
             'all three lines numbered 1-3')
    add('nl', ['-b', 'a'], [R('FNLBLANK')],
        note='-b a numbers EVERY line, including the empty one')
    add('nl', ['-b', 't'], [R('FNLBLANK')],
        note='-b t (also the default): the empty line gets a blank '
             'field, not a number, but keeps the separator')
    add('nl', ['-n', 'rz'], [R('FNLPLAIN')],
        note='-n rz: right justified, zero-padded to -w\'s width')
    add('nl', ['-w', '3'], [R('FNLPLAIN')],
        note='-w 3: a narrower field')
    add('nl', ['-s', '": "'], [R('FNLPLAIN')],
        ref_argv=['-s', ': ', R('FNLPLAIN')],
        note='-s with a multi-character, space-carrying separator -- '
             'hand-quoted for maux\'s sh line (a bare space would '
             'split the word), same shape as paste\'s own -d '
             'escape row; ref_argv hands the host the 2 raw bytes '
             'directly since Python subprocess has no shell to '
             'strip the maux-side quoting')
    add('nl', ['-v', '10', '-i', '5'], [R('FNLPLAIN')],
        note='-v/-i: start at 10, step by 5 -> 10, 15, 20')
    add('nl', [], [R('FNLPAGE')],
        note='header/body/footer sections via the default \\: '
             'delimiter -- the marker lines are consumed, never '
             'printed; only the body is numbered by default')
    add('nl', [], [R('FNLPAGE2')],
        note='two pages: the default resets the counter to 1 at '
             'the SECOND page\'s own header delimiter too, not '
             'just the first page\'s')
    add('nl', ['-p'], [R('FNLPAGE2')],
        note='-p: same two pages, but the second page\'s delimiter '
             'no longer resets the counter -- it keeps counting on '
             'from the first page')

    # ---- cal: XSI cal.html. MONTH YEAR only (cal.s's own header --
    # the bare-YEAR 3-column layout is a documented KNOWN GAP, not
    # byte-matched here). Every row host-oracled against this Mac's
    # own /usr/bin/cal before writing cal.s.
    add('cal', [], ['9', '2026'],
        note='a month needing only 5 body weeks pads a 6th blank row')
    add('cal', [], ['2', '2024'],
        note='February in a leap year has 29 days')
    add('cal', [], ['1', '2000'],
        note='a month starting on Sunday has no leading blank cells')
    add('cal', [], ['12', '2026'],
        note='December, and a month needing exactly 6 body weeks')

    # ---- strings: XSI strings.html. Every row host-oracled against
    # this Mac's own /usr/bin/strings on RAW data fixtures (never
    # Mach-O -- see e2e_ref's own note and strings.s's header).
    add('strings', [], [R('FSTR1')],
        note='default length 4: a 2-char run and a 3-char run are '
             'both discarded, only the 11-char run qualifies')
    add('strings', ['-n', '2'], [R('FSTR1')],
        note='-n 2: all three runs now qualify')
    add('strings', ['-t', 'x'], [R('FSTROFS')],
        note='-t x: hexadecimal offset, no leading zeros')
    add('strings', ['-t', 'd'], [R('FSTROFS')],
        note='-t d: decimal offset')
    add('strings', ['-t', 'o'], [R('FSTROFS')],
        note='-t o: octal offset')
    add('strings', ['-t', 'd'], [R('FSTRM1'), R('FSTRM2')],
        note='two file operands: the offset resets to 0 at the '
             'start of each')

    # ---- nohup: XCU nohup.html. This harness's own capture
    # (Case.run above) redirects the CHILD SHELL's stdout to a
    # real file on BOTH sides, so nohup's own "stdout is a
    # terminal?" check (SC_FDSTAT here, isatty(3) on the host)
    # answers NO on both -- the redirect/notice machinery never
    # fires on either side, and the only thing left to compare is
    # the PASS-THROUGH: the child's own output, unchanged, and
    # nohup's exit status transparently equal to the child's.
    # timeout/realpath are NOT here -- see build_e2e_image.py's
    # own TOOLS comment (no host oracle / no literal-argv shape).
    add('nohup', [], ['echo', 'HELLO'],
        note='stdout not a tty on either side: a pure pass-through '
             "of echo's own output and exit status")
    # ---- tsort: XCU tsort.html. A single chain has no tie to break,
    # so GNU and BSD agree byte for byte (src/bin/tsort.s's own
    # header -- everything else about tie-breaking is `hand=` in
    # check_posixutil.py instead, never here).
    add('tsort', [], [R('FTSORT')],
        note='a plain chain: no tie-break ambiguity, so both hosts '
             'agree with this build')

    # ---- pr: XCU pr.html. -t suppresses header/trailer/pagination
    # entirely, so the output has no wall-clock date in it and is
    # byte-exact against this host's own BSD pr (verified live
    # before writing pr.s; src/bin/pr.s's own header explains why
    # every OTHER pr row lives in check_posixutil.py as a `hand=`
    # shape check instead).
    add('pr', ['-t'], [R('FUNS')],
        note='-t: pure passthrough, no header/trailer/pagination')
    add('pr', ['-t', '-n'], [R('FUNS')],
        note='-t -n: default line numbering (width 5, a tab), no '
             'header')

    # ---- pathchk: XCU pathchk.html. -p on a short portable name is
    # a pure syntax check with no existence check at all, and passes
    # SILENTLY (no stdout, no stderr) on both GNU and BSD regardless
    # of this tree's own smaller default limits -- the one shape
    # this corpus's own byte-for-byte stdout+stderr comparator (this
    # file's own REDIR_SUFFIX captures both) can compare cleanly. A
    # FAILING -p/-P row is deliberately NOT here: both hosts refuse,
    # but each writes its own differently-worded diagnostic to
    # stderr, which this corpus does not tolerate (unlike
    # check_posixutil.py, which never compares stderr at all) --
    # PATHCHK_CASES in scripts/posixutil_cases2.py carries the
    # failing -p/-P rows instead, rc-only, exactly for this reason.
    add('pathchk', ['-p'], ['GOODNAME'],
        note='-p: a short portable name passes silently on both '
             'hosts')
    # ---- split: XCU split.html. RAW fixture (byte-exact both sides
    # -- split's own stdout is empty on success either way, so the
    # encoding is moot); a smoke test over the piece-writing code
    # path, not a piece-content proof (check-posixutil's own results=
    # rows already prove content, and check-e2e's comparator sees
    # only ONE stdout stream). NAME is `P()`-wrapped (a Path, not a
    # bare relative word): every other case in this corpus only ever
    # touches `/mnt/MAUX/E2E/...` absolute paths, and a bare relative
    # NAME resolves against sh's actual cwd instead -- which is NOT
    # /mnt/MAUX/E2E (measured live: a bare NAME failed CREATE, "cannot
    # create output file", almost certainly the ROOT volume
    # directory's own 51-entry cap, already crowded by every staged
    # binary and system file).
    add('split', ['-l', '2'], [R('FSPLITIN'), P('SPE2EX')],
        note='writes its pieces to files, not stdout -- both sides '
             'exit 0 with nothing on stdout to disagree about')

    # ---- csplit: XCU csplit.html. RAW fixture, same reasoning as
    # split above; `-s` suppresses the byte-count stdout that would
    # otherwise need a `hand=` row (check-posixutil's own header
    # explains why), leaving a clean empty-stdout/exit-0 smoke test.
    # `-f`'s VALUE must immediately follow it in argv (GETOPT reads
    # the next word), and mflags/operands concatenate in that fixed
    # order -- so the maux line hardcodes the same `/mnt/MAUX/E2E/...`
    # path `P()` would have computed, and `ref_argv` gives the HOST
    # run the `P()`-wrapped spelling instead (a divergence in
    # SPELLING only, Case's own `ref_argv` contract).
    add('csplit', ['-s', '-f', f'{IMG_DIR}/CSE2E'],
        [R('FCSPLITIN'), '3'],
        ref_argv=['-s', '-f', P('CSE2E'), R('FCSPLITIN'), '3'],
        note='-s suppresses the byte-count stdout; both sides exit '
             '0 with nothing on stdout to disagree about')

    # ---- join: XCU join.html. TEXT fixtures (unlike split/csplit,
    # join\'s stdout IS its whole job, so this is a genuine content
    # comparison, not a smoke test) -- already sorted on field 1.
    add('join', [], [R('FJOIN1'), R('FJOIN2')],
        note='the plain join: field 1 by default, blanks the '
             'separator')

    # ---- printf: XCU printf.html. Every row here is host-oracled
    # (this Mac's own /usr/bin/printf) except the non-numeric-
    # argument row, whose diagnostic WORDING is not maux's (see the
    # printf_numerr divergence entry) -- the VALUE (0), the payload
    # and the exit status still compare exactly.
    #
    # TWO REAL sh BUGS WERE REPORTED landing this section (2026-09-
    # 14), and their actual status as of 2026-09-15 (docs/SH-
    # FEATURES.md sec 22) is not what this comment used to say:
    #
    #  1. A LITERAL '#' ANYWHERE on the typed line broke it --
    #     'sh: unterminated quote' -- EVEN double-quoted, EVEN
    #     backslash-escaped. STRIPCOMMENT scanned for '#' with no
    #     quote-state tracking at all. FIXED (sec 22.2): quote-aware,
    #     and a '#' only starts a comment at the START of a word
    #     (POSIX 2.2/2.3), so a quoted '#' -- or even a bare mid-word
    #     one like `A#B` -- is now plain text. `#`-alternate-form
    #     printf output ('%#o'/'%#x') could now be typed through a
    #     quoted format string; not added here, left for a printf-
    #     specific follow-up rather than widening this pass's scope.
    #  2. A bare backslash inside a SINGLE-quoted word was reported
    #     not always literal (`'...\n...'` supposedly confusing the
    #     quote/line scanner). Did NOT reproduce on re-test with the
    #     actual two keystrokes backslash+letter (sec 22.3) --
    #     shtok.s's quote-squeeze never special-cased `\` for either
    #     quote form. _sh_quote's DOUBLE-quote preference below is
    #     therefore belt-and-suspenders, not a required workaround;
    #     left in place since it changes no output and touching it
    #     is not this pass's job.
    #
    # Every \n/\t below is STILL spelled as its OCTAL escape
    # (\012/\011) rather than re-tested with the letter spelling now
    # that (2) turned out not to reproduce -- these rows already have
    # a clean, unambiguous oracle and changing them buys nothing; the
    # letter spelling IS exercised directly by this section's own
    # 'bslash-1' ShCase row, added 2026-09-15.
    add('printf', [], [r'%s\012', 'hello'],
        note='a plain %s conversion plus the \\012 (newline) escape')
    add('printf', [], [r'%5d|%-5d|%05d|%x|%o\012', '3', '3', '3', '255',
                       '8'],
        note='%d width (right/left-justified, zero-padded) plus %x '
             'and %o in the same format (the %#o/%#x alternate form '
             'is NOT typeable here -- see this section\'s own header)')
    add('printf', [], [r'%5.2s|%-5s|\012', 'abcdef', 'ab'],
        note='%s precision (truncate to 2) and width (left-justified)')
    add('printf', [], [r'[%c]\012', 'hello'],
        note='%c: the argument\'s first character only')
    add('printf', [], [r'a%%b\012'],
        note='%% is a literal percent, consumes no argument')
    add('printf', [], [r'a\011b\011c\012'],
        note='\\011/\\012 (tab/newline) escapes in the format string')
    add('printf', [], [r'%b\012', r'x\0101y\c z'],
        note='%b: its OWN \\0ddd octal escape, and \\c stops ALL '
             'further output -- neither the trailing " z" nor the '
             'format\'s own trailing \\012 is printed')
    add('printf', [], [r'%s\012', 'one', 'two', 'three'],
        note='format reuse: %s\\012 has one conversion and three '
             'arguments, so it runs three times')
    add('printf', [], [r'%s-%d\012', 'onlyone'],
        note='missing arguments: %d has nothing left -- empty '
             'string / 0, per the task\'s own rule')
    add('printf', [], [r'%d\012', 'abc'],
        compare='printf_numerr',
        diverges=[('printf', 'numeric argument diagnostic wording')],
        note='a non-numeric numeric argument: diagnostic to stderr '
             '(merged in by REDIR_SUFFIX, wording not compared), '
             '0 used, exit 1 -- checked live against this host\'s '
             'own /usr/bin/printf, which agrees on the VALUE and '
             'exit status')
    add('printf', [], [r'A\101B\012C\012'],
        note='\\ddd (1-3 octal digits, no leading 0 needed) in the '
             'format string: \\101 is \'A\', \\012 is a newline byte')

    # ---- basename/dirname: XCU basename.html/dirname.html. Pure
    # text arithmetic (no MLI call of either kind), so every row is
    # a plain path string -- no fixture needed, and host-oracled
    # exactly (BSD /usr/bin/basename and /usr/bin/dirname implement
    # the same algorithm; verified live before writing src/bin/
    # basename.s/dirname.s -- see those files' own headers).
    add('basename', [], ['/usr/bin/sort'],
        note='plain: the last pathname component')
    add('basename', [], ['/usr/bin/sort///'],
        note='trailing slashes are stripped before the last '
             'component is found')
    add('basename', [], ['/src/prog.c', '.c'],
        note='a suffix operand, stripped when it is a real trailing '
             'suffix of the base')
    add('basename', [], ['prog.c', 'prog.c'],
        note='a suffix IDENTICAL to the whole base is never '
             'stripped')
    add('basename', [], ['//'],
        note='a string of nothing but slashes prints a single "/" '
             '(matched to this host, which POSIX leaves '
             'implementation-defined for this exact case)')
    add('dirname', [], ['/usr/bin/sort'],
        note='plain: everything but the last component')
    add('dirname', [], ['sort'],
        note='no slash at all -- "."')
    add('dirname', [], ['/usr/bin/'],
        note='trailing slashes stripped before the last component '
             'is removed')
    add('dirname', [], ['///'],
        note='a string of nothing but slashes prints a single "/"')
    add('dirname', [], ['/a/b/c/d'],
        note='nested: strips exactly one component')

    # ---- env: XCU env.html. -i pins a DETERMINISTIC environment on
    # BOTH sides (this host's own environment and maux's are
    # otherwise nothing alike, so a bare `env` with no `-i` cannot
    # be host-oracled at all -- checked live: `/usr/bin/env -i`
    # prints nothing and exits 0, the one shape both machines can
    # agree on exactly). The spawned utility is the bare lowercase
    # word "echo" -- PATH-resolved on EACH side by its own execvp
    # (src/liba/pathres.s here; the host's libc there), the same
    # precedent this file's own xargs cases already rely on for a
    # default utility with no exported PATH (src/liba/pathtab.s's
    # built-in "/bin/:/mnt/MAUX/" default) -- checked live on
    # this host too: `env -i echo HELLO` finds echo via the CALLING
    # process's own PATH, unaffected by the child's just-cleared
    # one, exactly as this build's PATHRSLV also resolves against
    # env's OWN environment before any merge.
    add('env', ['-i'], [],
        note='-i with no operands: an empty environment prints '
             'nothing')
    add('env', ['-i'], ['FOO=BAR'],
        note='-i plus one assignment, no utility: prints the one '
             'entry')
    add('env', ['-i'], ['echo', 'HELLO'],
        note='-i plus a utility: spawns it in an empty environment '
             "(echo does not read its environment, so this proves "
             'the spawn path survives -i rather than the value of '
             'any variable)')
    add('env', ['-i'], ['FOO=BAR', 'echo', 'HELLO'],
        note='-i, an assignment, AND a utility together: the '
             'assignment is merged into the (empty) base before '
             'the spawn')

    # ---- uuencode: XCU uuencode.html. ENCODE direction only --
    # its output is always high-bit-set text (ENCODE6/B64TAB both
    # emit the high bit unconditionally), so the standard text
    # comparator applies regardless of what the SOURCE bytes are.
    # FBIN (256 bytes, every value 0-255) is this corpus's own
    # existing byte-transparent fixture; the rest are this tool's
    # own chunk-size seams (45 historical / 57 base64) plus the
    # empty file. See BYTE_VALUED below -- uuencode's answer
    # depends on byte VALUES, so every source operand here is a
    # 'raw' fixture, never 'text'.
    add('uuencode', [], [R('FEMPTY'), 'E.BIN'],
        note='empty source: header, a lone backquote, "end"')
    add('uuencode', ['-m'], [R('FEMPTY'), 'E.BIN'],
        note='empty source, base64: header then "====" directly')
    add('uuencode', [], [R('FBIN'), 'E.BIN'],
        note='every byte value 0-255 -- historical alphabet, '
             'multiple 45-byte lines plus a short final one')
    add('uuencode', ['-m'], [R('FBIN'), 'E.BIN'],
        note='every byte value 0-255, base64 -- multiple 76-char '
             'lines plus a padded final one')
    add('uuencode', [], [R('FUU46'), 'E.BIN'],
        note='45+1 bytes: one full historical line, one 1-byte line')
    add('uuencode', [], [R('FUU135'), 'E.BIN'],
        note='45*3 bytes exactly: three full historical lines, no '
             'short final line at all')
    add('uuencode', ['-m'], [R('FUU57'), 'E.BIN'],
        note='57 bytes exactly: one full base64 line, NO = padding '
             '(measured live against this host before writing '
             'src/bin/uuencode.s)')
    add('uuencode', ['-m'], [R('FUU58'), 'E.BIN'],
        note='58 bytes: a full base64 line plus a 1-byte remainder '
             '-- "==" padding on the second line')

    # ---- uudecode: XCU uudecode.html. NOT staged as an e2e_corpus
    # case, and it is not a fixture-choice problem -- tried it two
    # ways and scripts/e2e_selftest.py's own mutation check (a
    # PREREQUISITE of `make check-e2e`, catches a comparator that
    # would accept a wrong answer) proved both wrong outright:
    # decode_maux_text() (scripts/e2e_compare.py) UNCONDITIONALLY
    # strips bit 7 from every maux output byte before comparing it
    # against the host's own RAW reference bytes -- correct for
    # every other tool here, whose real output is high-bit TEXT by
    # convention, but uudecode's real output is a byte-for-byte
    # PASSTHROUGH of whatever the original payload was. A payload
    # confined to $80-$FF (so every decoded byte legitimately
    # carries bit 7, hoping to dodge the "missing bit 7" failure
    # mode) does not fix this: the STRIP still fires unconditionally
    # and maps it back down to $00-$7F, which then no longer matches
    # the host's own unstripped $80-$FF reference bytes -- e2e-
    # selftest's case 208/209 reported exactly that ($00 where $80
    # was correct) before either was ever staged as a real case.
    # uudecode's decode correctness is proven elsewhere instead:
    # check-posixutil's hand-computed rows (bit-7-safe payloads,
    # where the strip is a no-op and comparison is exact), check-
    # textaudit's UD pair (self-consistent round trip through this
    # build's own uuencode, byte-for-byte via -o), and the live
    # round trips in this task's own commit message (ECHO/GREP
    # through both algorithms, `cmp` exit 0). uuencode's ENCODE
    # direction has no such conflict -- its real output is always
    # high-bit text by design, so every case above it is a genuine
    # host-oracled differential proof, unrestricted by byte range.

    # ---- xargs: default utility (echo), -n batching, -I with
    # replstr substitution, quoting, -t's stderr trace (REDIR_SUFFIX
    # merges it into the same comparison every other case gets), and
    # the POSIX empty-input rule (checked against THIS host,
    # 2026-09-14: BSD /usr/bin/xargs runs the utility ZERO times on
    # empty stdin -- see xargs.s's own header for the citation).
    add('xargs', [], [], stdin=R('FXARGS'))
    add('xargs', ['-n', '2'], [], stdin=R('FXARGS'))
    add('xargs', ['-n', '1'], [], stdin=R('FXARGS'))
    add('xargs', ['-I', '{}'], ['echo', '[{}]'], stdin=R('FXARGS'))
    add('xargs', [], [], stdin=R('FXARGSQ'),
        note="quoting: '...' groups a blank, \"...\" groups another, "
             'a trailing backslash-space escapes one literal blank')
    # -t is NOT exercised here: it writes real content to stderr, and
    # this corpus's 'exact' comparator (e2e_selftest.py's synth())
    # only ever models an empty stderr -- the shape every OTHER
    # 'exact' case here already has. -t's stderr trace is exercised
    # instead by scripts/posixutil_cases2.py's own, simpler oracle
    # comparison (check_posixutil.py), which has no such assumption.
    add('xargs', [], [], stdin=R('FEMPTY'),
        note='no stdin arguments at all -> utility runs ZERO times, '
             "matching this host's own xargs (not bare POSIX's "
             '"-r not given -> run it once")')

    # ---- sh: the shell LANGUAGE ---------------------------------------
    # The subject here is `sh` itself, not a utility.  See ShCase's
    # header for why these were missing and why the oracle is /bin/sh.
    def addsh(name, maux, ref, **k):
        nonlocal n
        n += 1
        c.append(ShCase(n, name, maux, ref, **k))
        return c[-1]

    # -- pipes.  The stage-1 corpus had NO pipe case at all before
    # 2026-08-27, though `sh` has had pipelines since task #4.
    addsh('creat-trunc',
          f'ECHO AAAAAAAAAAAAAAAA > {IMG_DIR}/OVW ; '
          f'ECHO B > {IMG_DIR}/OVW ; CAT {IMG_DIR}/OVW',
          'echo AAAAAAAAAAAAAAAA > OVW ; echo B > OVW ; cat OVW',
          note='`>` onto an EXISTING LONGER file must truncate. Until '
               '2026-08-29 truncation was implicit (the redirect was '
               'UNLINK+CREATE+OPEN, nothing could survive); liba CREAT '
               'now truncates by handle (SET_EOF 0), so this is the '
               'one case where that call is load-bearing -- no other '
               'case in any gate redirects onto a longer survivor.')
    addsh('tee-trunc',
          f'ECHO AAAAAAAAAAAAAAAA > {IMG_DIR}/TOV ; '
          f'ECHO B | TEE {IMG_DIR}/TOV',
          'echo AAAAAAAAAAAAAAAA > TOV ; echo B | tee TOV',
          note='tee onto an EXISTING LONGER file: host tee truncates; '
               'maux tee\'s old CREATE+OPEN did not (latent tail-'
               'garbage bug, found adopting liba CREAT 2026-08-29).')
    addsh('pipe-1', 'ECHO HI | CAT', 'echo HI | cat')
    addsh('pipe-2', f'CAT {IMG_DIR}/FUNS | SORT | UNIQ',
          'cat FUNS | sort | uniq')
    addsh('pipe-3', f'SORT {IMG_DIR}/FUNS | WC -l', 'sort FUNS | wc -l',
          compare='wc_fields',
          diverges=[('wc', 'field padding')],
          note='a pipeline feeding a counting tool')
    addsh('pipe-find-xargs',
          f'FIND {IMG_DIR} -name FDA -print | XARGS CAT',
          'find . -name FDA -print | xargs cat',
          note="find's own -exec is a real spawn already; this "
               'checks the OTHER classic pairing -- one matching '
               "path (order can't diverge with only one line) piped "
               "into xargs's own tokenizer, which sees find -print's "
               'CR-terminated path as ordinary stdin text')

    # -- $( ) command substitution.
    addsh('subst-1', 'ECHO A$(ECHO B)C', 'echo A$(echo B)C')
    addsh('subst-2', 'ECHO $(ECHO ONE TWO)', 'echo $(echo ONE TWO)',
          note='substitution yielding two words')
    addsh('subst-3', 'ECHO $(ECHO $(ECHO DEEP))',
          'echo $(echo $(echo DEEP))', defect=('sh', 'nested $( ) is refused'),
          note='nested substitution')
    addsh('subst-4', f'ECHO $(CAT {IMG_DIR}/FONE)', 'echo $(cat FONE)',
          note='substitution reading a file')

    # -- ( ) grouping, which runs in a subshell on both machines.
    addsh('group-1', '( ECHO A ; ECHO B )', '( echo A ; echo B )',
          note='a redirected group -- the harness redirect IS the case')
    addsh('group-2', '( ECHO OUT ; ( ECHO IN ) )',
          '( echo OUT ; ( echo IN ) )', note='nested groups, redirected')
    addsh('group-pipe', '( ECHO A ; ECHO B ) | CAT',
          '( echo A ; echo B ) | cat', defect=('sh', 'a ( ) group cannot be a pipeline stage'),
          note='a group as a PIPELINE STAGE -- still refused; the '
               'redirect half of this pin retired 2026-08-27')
    addsh('group-3', 'V=parent ; ( V=child ) ; ECHO $V',
          'V=parent ; ( V=child ) ; echo $V',
          note='POSIX: the subshell assignment must NOT leak out')

    # -- ${...} parameter expansion, the V7 family.
    addsh('brace-1', 'V=x ; ECHO ${V}Y', 'V=x ; echo ${V}Y',
          note='braces delimit the name from a following letter')
    addsh('brace-2', 'ECHO ${U-dflt}', 'echo ${U-dflt}',
          note='unset -> the default word')
    addsh('brace-3', 'V=set ; ECHO ${V-dflt}', 'V=set ; echo ${V-dflt}',
          note='set -> the value, not the default')
    addsh('brace-4', 'V=set ; ECHO ${V+alt}', 'V=set ; echo ${V+alt}')
    addsh('brace-5', 'ECHO ${U+alt}', 'echo ${U+alt}',
          note='unset -> empty, NOT the alternate')
    addsh('brace-6', 'ECHO ${U=asg} ; ECHO $U', 'echo ${U=asg} ; echo $U',
          note='= assigns as a side effect; the second ECHO proves it')

    # -- probes that ISOLATE the failures the first run of this section
    # found (2026-08-27).  Each varies exactly one thing against a case
    # that already passes, so a red one names its own cause.
    addsh('probe-semi', 'ECHO A ; ECHO C', 'echo A ; echo C',
          note='CONTROL: a plain `;` list with the harness redirect')
    addsh('probe-grpmid', 'ECHO A ; ( ECHO B ) ; ECHO C',
          'echo A ; ( echo B ) ; echo C',
          note='REGRESSION PIN for the segment-position bug: the group '
               'span used to be seeded only at token 0 of the LINE, so '
               'this `(` was tokenized as an ordinary word and the line '
               'misparsed. Its partner probe-semi (no group) is what '
               'showed the harness was sound and the shell was not.')
    addsh('probe-brace-eq', 'ECHO ${U=asg}', 'echo ${U=asg}',
          note='the ${V=w} EXPANSION alone, without the second ECHO '
               'that checks the assignment side effect')

    # -- $$.  The VALUE cannot match (maux pid == RamWorks bank number,
    # the host's is a Unix pid), so an exact compare would be wrong.
    # What IS comparable is the SHAPE and the SELF-CONSISTENCY: `$$`
    # twice on one line must print the same digits twice on any correct
    # shell.  The comparator checks exactly that and nothing more.
    addsh('pid-1', 'ECHO $$ $$', 'echo $$ $$', compare='sh_pid_pair',
          diverges=[('sh', 'a pid VALUE cannot agree across machines')],
          note='the two must be equal, non-empty and all digits')

    # -- IFS field splitting and quoted assignment (2026-08-28).  Both
    # landed together because neither is usable alone: `V='a b c'`
    # writes a multi-word value down and `for x in $V` takes it apart,
    # and that pair is the idiom.  They belong HERE and not only in
    # check-shlang for the reason this section exists -- one expectation
    # in the check-shlang work was authored rather than derived and was
    # wrong (`ECHO IL:$C` under IFS=. splits the VALUE, which the host
    # confirms and my hand did not).  These have an oracle.
    #
    # APPENDED, not inserted mid-list: `cid` is positional, and renumbering
    # the cases above would silently repoint every ID this project has
    # already written down (docs cite e2e cases 116/117 by number).
    #
    # EVERY CASE THAT SETS $IFS IS WRAPPED IN `( )`, and that is not
    # tidiness.  maux runs this whole corpus as ONE script in ONE shell,
    # so a bare `IFS=:` would still be in force for every case after it,
    # while the reference runs each case in its OWN `sh -c` and would
    # not -- an asymmetry that reads as a maux bug in unrelated cases
    # dozens of lines later.  The group isolates it on both sides.
    addsh('ifs-1', "V='a b' ; ECHO $V", "V='a b' ; echo $V",
          note='an unquoted expansion splits into two words')
    addsh('ifs-2', "V='a b' ; ECHO \"$V\"", "V='a b' ; echo \"$V\"",
          note='...and quoted it stays one -- the pair is the assertion')
    addsh('ifs-3', 'ECHO $UQ X', 'echo $UQ X',
          note='the implicit-null rule: an unset variable yields NO '
               'argument, so `echo` sees one, not an empty first one. '
               'UQ is a name NO other case touches -- `U` is ASSIGNED by '
               'brace-6\'s ${U=asg} and would still be set here in maux\'s '
               'one long-lived shell while unset in the host\'s fresh one')
    # THE SEPARATOR IS `,` AND NOT `:` FOR A MEASURED REASON, and it is
    # the reference that forced it, not maux.  macOS's /bin/sh is bash
    # 3.2.57 (2007), and with IFS=: it splits a word's LITERAL colons
    # too, not merely its expansions: `IFS=: ; V=ab ; set -- x:$V`
    # yields `x` and `ab` there, where dash, bash 5.3 and maux all yield
    # the single word `x:ab`.  POSIX 2.6.5 is explicit -- the shell
    # scans "the results of expansions and substitutions", not the
    # literal text around them -- so the ancient reference is the
    # outlier and maux is correct.  With `,` (or `.`) all four shells
    # agree, so the case keeps a trustworthy oracle and still tests
    # exactly the rule it means to.
    #
    # Left as a warning rather than only a workaround: anyone who
    # "fixes" maux to match macOS /bin/sh on a colon will be
    # reintroducing a nineteen-year-old bug on the strength of an
    # oracle that is wrong here.
    addsh('ifs-4', "( IFS=, ; V='a,b' ; ECHO $V )",
          "( IFS=, ; V='a,b' ; echo $V )",
          note='$IFS is honoured, not hardwired to whitespace')
    addsh('ifs-5', '( IFS=, ; ECHO a,b )', '( IFS=, ; echo a,b )',
          note='...but a LITERAL separator does NOT split: V7 scans only '
               'the results of substitution. The case with teeth -- an '
               'implementation that splits the finished word passes every '
               'other line here and fails this one')
    addsh('ifs-6', "( IFS=, ; V='a,b' ; ECHO x,$V )",
          "( IFS=, ; V='a,b' ; echo x,$V )",
          note='both rules in ONE word: the literal `,` holds, the '
               'substituted one splits -- the case that caught the '
               'reference shell itself being wrong with `:`')
    addsh('qasg-1', "V='a b' ; ECHO \"$V\"", "V='a b' ; echo \"$V\"",
          note="`V='a b'` -- a SYNTAX ERROR in maux until 2026-08-28")
    addsh('qasg-2', 'V="a b" ; ECHO "$V"', 'V="a b" ; echo "$V"',
          note='the double-quoted form of the same')
    addsh('qasg-3', "W=x ; V='$W' ; ECHO \"$V\"",
          "W=x ; V='$W' ; echo \"$V\"",
          note="`'...'` keeps `$W` literal")
    addsh('qasg-4', 'W=x ; V="$W" ; ECHO "$V"', 'W=x ; V="$W" ; echo "$V"',
          note='...and `"..."` expands it -- qasg-3/4 are the pair that '
               'catches the two forms being implemented identically')
    addsh('qasg-5', "V='*' ; ECHO \"$V\"", "V='*' ; echo \"$V\"",
          note='a glob metacharacter inside quotes stays literal rather '
               'than expanding against the volume at assignment time')

    # -- three prompt-level bugs, 2026-09-15 (docs/SH-FEATURES.md sec
    # 22). `echo -n`'s own live gap; `#` losing everything from the
    # FIRST '#' regardless of quotes (`STRIPCOMMENT` had no idea what
    # a quote was); and a backslash inside single quotes, REPORTED
    # not-always-literal 2026-08-27 but which turned out not to
    # reproduce under a real keystroke re-test -- shtok.s's quote-
    # squeeze never special-cased `\` for either quote form. This
    # section's own rows exercise all three for real, in one shell,
    # against the host oracle -- see sec 22.3 for why the backslash
    # row is here at all rather than a defect pin.
    # `echo -n` has NO row here, deliberately -- ShCase always
    # redirects the LAST command on its line to capture it, and
    # CHCK_BLTN_ECH's OWN header explains why that is fatal to this
    # particular test: ANY `>`/`>>` on an ECHO makes the builtin fall
    # through to the external binary (`echo.s`, which already had
    # `-n` before this pass), so a redirected `ECHO -n A` row would
    # pass whether or not the BUILTIN'S `-n` worked at all -- it
    # never reaches the code under test. A `;`-list sidesteps that
    # only by making the captured command a DIFFERENT one, which
    # proves nothing about `-n` either. The builtin's own `-n` fix
    # is verified live instead (docs/SH-FEATURES.md sec 22.1):
    # typed at the console, unredirected, `ECHO -n HELLO` then
    # `ECHO WORLD` renders `HELLO$` then `HELLOWORLD` with no CR
    # between them, and `/bin/ECHO -n HI` (forced external)
    # renders identically -- the two implementations agree.
    # 'z', not 'n': the host's own /bin/sh builtin `echo` (bash in
    # POSIX mode) interprets `\n` itself as an XSI escape -- that is
    # ECHO'S behaviour, not the SHELL's quoting, and confounds this
    # test (measured: `echo 'a\nb'` on this Mac prints a real
    # newline). `\z` is not a recognised escape letter on EITHER
    # side's echo (verified: `/bin/sh -c "echo 'a\\zb'"` -> `a\zb`
    # here), so a byte-exact match isolates the shell's OWN quote
    # handling, which is what sec 22.3 is actually about. The
    # letter-vs-recognised-escape distinction is exactly what the
    # original 2026-09-14 report itself noticed (its own `\z` case).
    addsh('bslash-1', "ECHO 'a\\zb'", "echo 'a\\zb'",
          note='backslash inside single quotes is NOT special (POSIX '
               '2.2.2) -- prints the four literal characters a \\ z b')
    addsh('hash-dq', 'ECHO "a # b"', 'echo "a # b"',
          note="a '#' inside double quotes is text, not a comment "
               'marker -- the old STRIPCOMMENT truncated the line here '
               'and left an unmatched quote behind')
    addsh('hash-sq', "ECHO 'a#b'", "echo 'a#b'",
          note="same rule inside single quotes; no space either side")
    addsh('hash-mid', 'ECHO A#B', 'echo A#B',
          note="a '#' MID-WORD, with no blank before it, is NOT a "
               'comment marker -- output is the whole word A#B, which '
               'the old "any # not right after $" rule got wrong too')
    # `hash-word` (`ECHO A # comment` -> `A`) has no row here either:
    # ShCase's appended redirect lands INSIDE the very comment being
    # tested (the redirect is on the SAME physical line, after the
    # `#`), so it would be stripped along with the comment and
    # nothing would ever be captured. This shape is UNCHANGED by
    # this pass anyway -- the old "not right after $" rule already
    # truncated it the same way -- and is covered by the live
    # emulator verification in docs/SH-FEATURES.md sec 22.2.

    # -- the two QUOTING gaps sec 22.3 reported but did not fix
    # (2026-09-15, docs/SH-FEATURES.md sec 23): adjacent quoted/bare
    # segments now CONCATENATE into one word (POSIX 2.2) instead of
    # `sh: mixed quoting`, and `"..."` implements POSIX 2.2.3's own
    # backslash table instead of copying every byte verbatim.
    addsh('quotecat-1', "ECHO 'it''s'", "echo 'it''s'",
          note="two ADJACENT single-quoted segments, no bare text "
               "between them -- ONE token, not `sh: mixed quoting`")
    addsh('quotecat-2', 'ECHO "a"\'b\'c', 'echo "a"\'b\'c',
          note='double-quoted + single-quoted + bare, all glued -- '
               'the general case the old per-token flag refused')
    addsh('quotecat-3', 'ECHO x"y"', 'echo x"y"',
          note='bare + double-quoted, no delimiter between them')
    addsh('quotecat-4', "ECHO '' z", "echo '' z",
          note="a QUOTED empty word ('') is still an ARGUMENT of its "
               "own -- ECHO gets two argv words, not one")
    addsh('quotebs-1', 'ECHO "a\\"b"', 'echo "a\\"b"',
          note='POSIX 2.2.3: `\\"` inside "..." strips to a bare '
               '`"` and does NOT close the quote there')
    addsh('quotebs-2', 'ECHO "\\$X"', 'echo "\\$X"',
          note='`\\$` strips to a bare `$` that does NOT then '
               'expand (X is left unset on purpose)')
    # `\\` and `\n` (below) both leave a REAL backslash in the final
    # argument, and this host's own /bin/sh builtin `echo` interprets
    # THAT as an XSI escape of its own (measured: `echo "a\\b"` ->
    # `a<BS>`, `echo "a\nb"` -> a real newline) -- the exact same
    # confound bslash-1's own header already routed around, just from
    # the other quote form. `printf %s` never reinterprets its
    # argument (only a literal escape IN THE FORMAT STRING), so it
    # isolates the SHELL's quoting from the UTILITY's own escaping,
    # verified against this host: `printf %s "a\\b"` -> `a\b`,
    # `printf %s "a\nb"` -> `a\nb` literally, on both sides.
    addsh('quotebs-3', 'PRINTF %s "a\\\\b"', 'printf %s "a\\\\b"',
          note='POSIX 2.2.3: `\\\\` inside "..." strips to ONE `\\`')
    addsh('quotebs-4', 'PRINTF %s "a\\nb"', 'printf %s "a\\nb"',
          note='`\\` before any OTHER byte (here `n`) keeps BOTH -- '
               'the table has four entries (`$ \\` " \\\\`), not a '
               'blanket "backslash is always special"')

    # ---- unset, `<&-`, getopts (docs/SH-FEATURES.md, 2026-09-15) ------
    addsh('unset-1', 'X=1 ; UNSET X ; ECHO "[$X]"',
          'X=1 ; unset X ; echo "[$X]"',
          note='freeing a slot leaves the name genuinely gone, not '
               'just empty-valued -- POSIX draws that distinction')
    addsh('unset-2', 'X=1 ; UNSET -v X ; ECHO "[$X]"',
          'X=1 ; unset -v X ; echo "[$X]"',
          note='-v is the default namespace and is accepted, not '
               'refused as an unknown flag')
    addsh('unset-3', 'UNSET NOSUCHVAR ; ECHO $?',
          'unset NOSUCHVAR ; echo $?',
          note='unsetting a name that was never set is not an error')
    # unset-4 (MAXVARS=8: fill every slot, free one, reuse it) is
    # DELIBERATELY NOT an e2e-corpus row -- found live, twice, the
    # hard way. This whole corpus is ONE continuous shell 322 cases
    # long, so filling all 8 slots means fighting whatever THIS
    # corpus already left set (`U`/`V`/`W` from brace-6/qasg-3/4),
    # and even a `( )` subshell does not start empty -- forking
    # COPIES the table, it does not reset it. Freeing the known
    # offenders first (`UNSET U;V;W`) fixed THAT symptom, but a
    # SECOND one replaced it: this deep into a 322-case boot (289 of
    # 322 tool invocations are already WARM respawns, i.e. lazy-free
    # is holding many banks), the subshell fork this row needs
    # failed outright -- maux never even opened its own output file,
    # and the harness's OWN host-side reference subprocess came back
    # with a bare -1 return code, neither of which reproduces
    # standalone (this exact construct runs clean, `$?`0, output
    # `9`, tried directly against both `/bin/sh` and a fresh maux
    # boot). That shape -- fine in isolation, breaks only after
    # hundreds of PRIOR spawns in the same boot -- is a shared-
    # harness resource question (bank/lazy-free pressure), not a
    # `unset`/subshell correctness one, so it is proven on a FRESH
    # boot instead: the live e2e_term session for this feature
    # (see this task's own report) types the identical construct at
    # the console -- X=1;UNSET X;ECHO "[$X]" -> "[]", then all 8
    # slots filled, D freed, a 9th ("I") created and read back as
    # "9" -- on a boot with nothing else competing for a slot or a
    # bank.

    # -- `<&-` (docs/SH-FEATURES.md, 2026-09-15), the input-side twin
    # of `>&`/`N>&`. `<&0` (dup stdin onto itself) is DELIBERATELY NOT
    # a row here -- found live, the hard way, on THIS harness: this
    # whole corpus boots ONE `sh` that reads its OWN 646-line script
    # off fd 0 (docs/SH-FEATURES.md sec 16.2's "when a script is run
    # as `SH < FILE`, fd 0 IS that file" -- true of THIS boot, not of
    # check-sh's separate argv[1]-script harness), so `CAT <&0` here
    # duplicates the SCRIPT's own fd, and `cat` reads every remaining
    # case as DATA -- the dup shares one file position with the
    # original, so it also ADVANCES that position, and control never
    # returns to a still-live script: sh's own next read finds EOF
    # and the run ends silently `done=$AA`, seven cases short (this
    # one plus every one after it) with no error at all. Correct
    # behaviour, not a bug -- V7's own rule, applied to `<&` instead
    # of `read` for the first time -- but it makes `<&0` unsafe to
    # exercise from INSIDE the very script it would consume. Proven
    # instead on the live emulator session (this feature's own
    # report): `CAT <&0` blocks on real console input and echoes it
    # back, exactly the duplicate this construct promises.
    addsh('redirin-2', 'CAT <&- ; ECHO $?', 'cat <&- ; echo $?',
          compare='sh_closed_fd',
          diverges=[('sh',
                     'a closed-stdin error code is implementation-'
                     'specific')],
          note='the host fails nonzero; maux is a deterministic 0 '
               '(cat/wc/od cannot tell a closed fd from EOF, a '
               'pre-existing gap this feature exposed -- see the '
               'cited divergence entry) -- the close itself is '
               'proven live, by NOT blocking on the console the '
               'way `<&0` does')

    # ---- getopts (docs/SH-FEATURES.md, 2026-09-15) --------------------
    # Explicit ARG... (not the script's own positional parameters) so
    # one line is a complete, self-contained call -- POSIX's OWN
    # example shape. OPTIND/OPTARG are ordinary shell variables here
    # too, so a fresh `sh -c` on each side starts OPTIND at 1 exactly
    # the way a fresh maux spawn does (GOPTLASTOI's own zeroed sentinel,
    # docs/SH-FEATURES.md) -- but this WHOLE corpus is ONE continuous
    # shell, not a fresh spawn per case, so every row after the first
    # explicitly resets `OPTIND=1` itself: found live (both here and
    # on the emulator) that a leftover OPTIND from the PRIOR case's
    # own ARG list desyncs the next one's, since they are different
    # lengths -- the exact hazard GOPTLASTOI's mismatch detection
    # exists for, and each row triggering it on purpose is proof the
    # detection works, not a workaround for a bug.
    # getopts-1/getopts-2 are DELIBERATELY NOT `WHILE ... ; DO ... ;
    # DONE` ONE-LINERS -- a REAL BUG, found here: a `while getopts`
    # loop written as ONE PHYSICAL LINE hangs FOREVER (alternates two
    # options, never advancing) the moment it is read from a real
    # (non-console) script file -- proven live: the IDENTICAL
    # construct typed AT THE CONSOLE works correctly (SPOOL_SPLIT
    # rewrites it onto separate lines before `.`-sourcing it -- see
    # e2e_vi_term.py's shloop_console scenario (l), which is exactly
    # this construct, typed, and green), and the SAME construct
    # written across separate lines in a plain file ALSO works
    # correctly. Only the one-line-from-a-real-file combination
    # hangs. Reported in docs/SH-FEATURES.md sec 24.6 rather than
    # fixed (root cause not isolated further; not this task's
    # `sh.bin` budget to spend chasing it -- 23,500/23,500 B, zero
    # headroom). These two rows use `;`-separated single CALLS
    # instead, each proving one option in isolation, which does not
    # hit the loop-specific hang.
    addsh('getopts-1',
          'OPTIND=1 ; GETOPTS ab:c N -a -b x ; ECHO "$N:$OPTARG" ; '
          'GETOPTS ab:c N -a -b x ; ECHO "$N:$OPTARG"',
          'OPTIND=1 ; getopts ab:c N -a -b x ; echo "$N:$OPTARG" ; '
          'getopts ab:c N -a -b x ; echo "$N:$OPTARG"',
          note='TWO SEQUENTIAL single CALLS against the SAME 3-word '
               'ARG list (not a `while` one-liner -- see this '
               "section's own header): a: (no arg) then b:x "
               '(required arg from the next operand) -- OPTIND '
               'persists correctly across the two separate calls, '
               "the same property getopts-5's own two calls prove")
    addsh('getopts-2',
          'OPTIND=1 ; GETOPTS ab:c N -ab x ; ECHO "$N:$OPTARG" ; '
          'GETOPTS ab:c N -ab x ; ECHO "$N:$OPTARG"',
          'OPTIND=1 ; getopts ab:c N -ab x ; echo "$N:$OPTARG" ; '
          'getopts ab:c N -ab x ; echo "$N:$OPTARG"',
          note='clustered "-ab x" across TWO SEPARATE calls against '
               'the SAME ARG list: a: (OPTIND unchanged, still '
               'mid-word), then b:x (OPTIND advances past the '
               'whole word AND its value)')
    addsh('getopts-3', 'OPTIND=1 ; GETOPTS ab:c N -z ; ECHO "$N"',
          'OPTIND=1 ; getopts ab:c N -z ; echo "$N"',
          note='an unknown option sets NAME to "?" (loud diagnostic '
               'goes to the earlier, uncaptured command in the `;` '
               'list -- REDIR_SUFFIX binds only to the last one)')
    addsh('getopts-4',
          'OPTIND=1 ; GETOPTS :ab:c N -z ; ECHO "$N:$OPTARG"',
          'OPTIND=1 ; getopts :ab:c N -z ; echo "$N:$OPTARG"',
          note='a leading ":" in OPTSTRING is silent mode: NAME="?", '
               'OPTARG is the bad letter, no diagnostic')
    addsh('getopts-5',
          'OPTIND=1 ; GETOPTS ab:c N -a -- -b ; ECHO "$N:$OPTIND" ; '
          'GETOPTS ab:c N -a -- -b ; ECHO "$N:$OPTIND:$?"',
          'OPTIND=1 ; getopts ab:c N -a -- -b ; echo "$N:$OPTIND" ; '
          'getopts ab:c N -a -- -b ; echo "$N:$OPTIND:$?"',
          note='"--" ends option parsing: OPTIND steps past it and '
               'NAME becomes "?" (verified against this host, not '
               'assumed -- it also clears NAME, not just $?)')

    return c


#: Tools whose ANSWER depends on the byte VALUES in the file, not just on
#: its structure.  A 'text' fixture does NOT have the same bytes on the
#: two sides -- the host holds `A\n` where the image holds $C1 $8D -- so
#: feeding one to a byte-valued tool compares two different files and the
#: difference is the harness's, not maux's.
#:
#: This guard exists because the corpus broke its own stated rule on the
#: SECOND rig run: `SUM FEMPTY FONE` reported checksum 33005 against the
#: reference's 32810, and the whole of that gap was $C1 $8D versus
#: `A\n`.  A rule in a docstring is a rule that gets violated; this one
#: raises at import.
#:
#: `od -c` is exempt, and the exemption is earned rather than assumed:
#: od.s's PRCHRDOT strips bit 7 before deciding what to print, so its
#: output is invariant under exactly the encoding this corpus applies.
BYTE_VALUED = {'sum', 'od', 'uuencode'}


def check_byte_stable(cases):
    """Every operand of a byte-valued tool must be byte-identical on both
    sides.  Raises rather than returning: a corpus that compares two
    different files is not a corpus."""
    bad = []
    for case in cases:
        if case.tool not in BYTE_VALUED:
            continue
        if case.tool == 'od' and '-c' in ''.join(case.mflags):
            continue
        for op in list(case.operands) + ([case.stdin] if case.stdin else []):
            if not isinstance(op, Ref):
                continue
            kind, data = FIXTURES[op.name]
            if kind != 'raw' and data != b'':
                bad.append(f'case {case.cid} ({case.tool}) reads '
                           f'{op.name}, a `text` fixture whose bytes '
                           f'DIFFER between the host and the image')
    if bad:
        raise AssertionError(
            'byte-valued tools may only read byte-stable fixtures:\n  '
            + '\n  '.join(bad))


CASES = build_cases()
check_byte_stable(CASES)


def script_bytes():
    """The `sh` script, as maux text.  One line per case plus an `ECHO $?`
    that appends the exit status -- statuses are an oracle in their own
    right (`diff` reporting differing files identical with EXIT 0 is one
    of the four bugs docs/E2E.md sec 1 opens with)."""
    lines = []
    for case in CASES:
        lines.append(case.sh_line())
        lines.append(f'ECHO $? >> {IMG_DIR}/{STATUS_NAME}')
    lines.append('EXIT')
    text = ''.join(line + '\n' for line in lines).encode('ascii')
    return convert.text_from_host(text, high_bit=True)


def to_image_bytes(kind, data):
    """Host bytes -> the bytes that go in the image.  a2til's own
    converter does the text encoding (LF->CR, bit 7 set); raw is raw."""
    if kind == 'text':
        return convert.text_from_host(data, high_bit=True)
    return data


def write_host_corpus(hostdir):
    """Write the fixtures in HOST form -- what the reference reads."""
    os.makedirs(hostdir, exist_ok=True)
    for name, (_kind, data) in FIXTURES.items():
        with open(os.path.join(hostdir, name), 'wb') as fh:
            fh.write(data)
    return hostdir


def write_mirror_stage(stagedir):
    """Write the fixtures + the script in IMAGE form into the directory
    `a2til mirror` will push from.

    The `#040000` suffix is cadius' -- and a2til mirror's -- notation for
    "ProDOS file type $04 (TXT), aux $0000".  `mirror --raw` parses it off
    the host name and stores the bytes verbatim under that type, which is
    exactly what is wanted: maux text is high-bit with $8D line endings,
    NOT the low-ASCII a2til's ProDOS text converter would produce, so the
    translation must not happen twice.  See docs/E2E.md sec 9.
    """
    os.makedirs(stagedir, exist_ok=True)
    written = []
    for name, (kind, data) in FIXTURES.items():
        path = os.path.join(stagedir, f'{name}#040000')
        with open(path, 'wb') as fh:
            fh.write(to_image_bytes(kind, data))
        written.append(path)
    path = os.path.join(stagedir, 'SCRIPT#040000')
    with open(path, 'wb') as fh:
        fh.write(script_bytes())
    written.append(path)
    # The append target is pre-created EMPTY, so `>>` never has to
    # create a file -- one less thing that can differ between the first
    # case and the sixty-eighth.
    for name in (STATUS_NAME,):
        path = os.path.join(stagedir, f'{name}#040000')
        with open(path, 'wb') as fh:
            fh.write(b'')
        written.append(path)
    return written


def corpus_size():
    total = sum(len(to_image_bytes(k, d)) for k, d in FIXTURES.values())
    return total + len(script_bytes())


def resolved_ref_tools():
    return REF.resolved_ref_tools()


if __name__ == '__main__':
    print(f'fixtures: {len(FIXTURES)}  cases: {len(CASES)}  '
          f'staged bytes: {corpus_size()}')
    for where, name, value in L.summary():
        print(f'  limit {name:<16} = {value:<6} ({where})')
    longest = max(len(c.sh_line()) for c in CASES)
    print(f'  longest sh line: {longest} of LINEMAX {SH_LINEMAX}')
    for case in CASES:
        print(f'  {case.cid:3d} {case.sh_line()}')
