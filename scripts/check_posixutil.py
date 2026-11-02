#!/usr/bin/env python3
r"""check_posixutil.py -- POSIX.1-2024 conformance gate for ten of maux's
small userland utilities: cat, cmp, comm, expr, head, grep, mkdir, pwd,
sleep, true, false (src/bin/{cat,cmp,cmprpt,comm,expr,expr.eval,expr.ops,
head,grep,mkdir,pwd,sleep,true,false}.s). `make check-posixutil`; in the
box sweep (CHECK_ALL_TARGETS), same posture as check-posixsed.

THE ORACLE IS THE HOST'S OWN BINARY (BSD on the Mac, GNU-flavoured
coreutils where the box differs -- verified against the SAME construct
set both agree on) for every case where the two engines can possibly
agree: every CASES row feeds the SAME argv and the SAME staged input
through maux's own shell and through a real host subprocess, and stdout
+ exit status (+ any named result file) are compared BYTE-EXACT. Method
copied from check_posixsed.py (docs there, sec "METHOD"): every case's
files are staged with a2til into a FRESH per-case subdirectory of
/mnt/MAUX/PXUT on a COPY of build/play.po, the image is booted once per
batch, and each case is typed at the shell prompt as

    TOOL [args] [< IN] > <base>/OUT
    echo $? > <base>/OUTX

where <base> is that case's own /mnt/MAUX/PXUT/<K-tag> subdirectory (one
per case, not shared -- a subdirectory grows on demand, unlike the
play image's root; check_posixex.py's own finding). hi()/hilines()/
maux_lines()/host_lines()/render() are check_posixsed.py's helpers,
imported rather than re-typed (this file's own instructions insist on
that, and duplicating a byte-format helper is exactly the kind of skew
that made check_posixsed necessary to write once, correctly, in the
first place).

WHERE THE TWO OSES CANNOT AGREE: some cases hand-author the expectation
straight from the XCU spec text (`hand=` on the case, always with a
`reason`), because either (a) BSD and POSIX diverge and the case is
built around POSIX's own words instead of BSD's behaviour, (b) the
value under test has no host analogue at all (ProDOS pathnames for
`pwd`; a 16-bit-only `expr` engine's overflow/div-by-zero choice vs. a
64-bit host's), or (c) the row is a documented maux GAP -- a construct
POSIX requires and maux's own source says outright it does not
implement (grep -E/-F/-f/multi -e, mkdir -m, expr's `:` and `()`, cat's
-u and its '-' stdin operand, head's -c). Every such row is listed in
KNOWN_GAPS below with the maux-side finding, and the scoring below
requires it to STAY red: a gap that starts passing on its own must be
retired from the table by a human reading this file, never silently
absorbed into the pass count.

DIAGNOSTIC WORDING IS NEVER COMPARED (the spec leaves stderr's exact
text unspecified almost everywhere), so this suite, like
check_posixsed.py before it, compares stdout bytes, exit status, and
named result files ONLY. (maux's sh DOES have `2>` -- docs/SH-FEATURES.md,
shipped 2026-08-21 -- it is simply not used here, by policy.) Where the spec text says a diagnostic "shall
be written", that clause is quoted for provenance but is not gated.

MAUX BUGS THIS SUITE FOUND (read the source, not just the header
comments -- src/bin/cmprpt.s and src/bin/comm.s do NOT match the
contract their own file headers claim):

  1. FIXED 2026-09-13. cmp's plain (no -l/-s) differ message --
     POSIX's own STDOUT section gives its exact format string and
     says it goes to STANDARD OUTPUT. cmprpt.s's DIFFER routine used
     to write it to FD_STDERR unconditionally (found by reading the
     PUTS calls, not the header comment, which claimed stderr
     correctly but never flagged the divergence from POSIX).
     Confirmed against a live BSD cmp: the reference prints "f1 f2
     differ: char N, line M" on stdout, exit 1, nothing on stderr.
     Fix: DIFFER's PUTS/PUTC calls now target FD_STDOUT; cmp.s's own
     CONTRACT comment corrected to match. Formerly KNOWN_GAPS 'cmp',
     'default differ message' -- retired, now an ordinary case.
  2. FIXED 2026-09-13. comm's adaptive <lead> columns (POSIX STDOUT:
     column 2's leading <tab> is a NULL STRING when -1 is selected;
     column 3's leading tabs go 2/1/1/0 depending on which of -1,-2
     are selected) were not adaptive in src/bin/comm.s: OUT2 always
     emitted exactly one TAB ($89) and OUT3 always emitted exactly
     two, regardless of WANT1/WANT2. Verified against a live BSD comm
     with -1, -2, and -12: only the no-flags and -3-only and -123
     cases came out byte-exact; -1, -2, and -12 all differed from the
     adaptive spec. Fix: OUT2/OUT3 now test WANT1/WANT2 per POSIX's
     rule before each <tab>. Formerly KNOWN_GAPS 'comm', '-1
     suppresses column 1 (adaptive lead)' / '-2 suppresses column 2
     (adaptive lead)' / '-12 leaves only the common column' --
     retired, now ordinary cases.
  3. FIXED 2026-09-13. comm's usage-error path (0/1/3 operands) never
     terminated its "usage: comm [-123] file1 file2" line: unlike
     every sibling util's usage string (which bakes a trailing $8D
     into the message via `dfb $8D,0`) OR cmp.s's own USAGERR (which
     PUTCs a separate $8D after PUTS), comm.s's :usage did NEITHER --
     so the shell's next prompt drew its "$" onto the SAME row as the
     unterminated message. This is a real, user-visible rendering
     bug, not a genuine CPU/kernel hang: driven directly against the
     emulator (verilogapple), the shell keeps running underneath it
     fine -- a command typed right after the broken usage line
     executes and returns a normal prompt with no ^C needed. What
     DOES treat it as stuck is any automation whose "at the prompt"
     predicate requires the last non-blank glass row to be exactly
     "$" (this suite's own V._at_prompt, borrowed from check_vi.py,
     is exactly that predicate) -- against that check, the missing
     newline is indistinguishable from a hang until it times out,
     which is what "recovery needs an explicit ^C" was describing: a
     harness recovering from ITS OWN stalled prompt-wait, not the
     shell recovering from an infinite loop. Grepped the whole tree
     for the same shape (a usage/error PUTS immediately followed by
     `lda #status / jsr EXIT`, no CR either baked into the string or
     PUTC'd separately): every other hit (chmod/date/df/du/file/
     findact/grep/kill/ls/make/mv/nm/od/pwd/sed/tail/tee/touch/tr/
     uniq's own usage and error strings) already ends in `dfb
     $8D,$00` -- comm.s's USAGEMSG was the only one missing it
     entirely, so no other util shares this defect. Fix: :usage now
     PUTCs a trailing $8D to FD_STDERR before EXIT, matching cmp.s's
     USAGERR shape exactly. Formerly KNOWN_GAPS 'comm', 'exactly two
     operands required' -- retired, now an ordinary case.

All three were real maux bugs, fixed in this pass (task brief:
root-cause and fix, not just report).

SCORING (check_posixex.py's posture, made load-bearing rather than
purely a report): total = every non-gap case must PASS, AND every
KNOWN_GAPS case must still FAIL its comparison -- exit 0 only if both
hold. A KNOWN_GAPS case that starts passing is printed as an error
("retire it"), not silently folded into the green count.
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_posixsed as PS                              # noqa: E402
import check_vi as V                                      # noqa: E402
import scratchclean as SC                                 # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR      # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import a2til                                               # noqa: E402
from a2til import prodos                                   # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

hi = PS.hi
hilines = PS.hilines
maux_lines = PS.maux_lines
host_lines = PS.host_lines
render = PS.render

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'play.po')
SUBDIR = '/mnt/MAUX/PXUT'
#: The scratch images are keyed on THIS checkout's path: three streams
#: in sibling worktrees (diffr, odt, harness, 2026-10-08) and two more
#: (vroot, loop S1, 2026-10-10) each found another worktree's rows in
#: their own OUT when the default was one shared directory. A worktree
#: gets its own directory without setting POSIXUTIL_SCRATCH; the
#: variable still overrides.
SCRATCH = os.environ.get(
    'POSIXUTIL_SCRATCH',
    os.path.join(tempfile.gettempdir(),
                 'maux-posixutil-' + hashlib.sha1(
                     ROOT.encode('utf-8')).hexdigest()[:10]))
BATCH = 10
#: Every scratch image this run made, by name: a PASS deletes exactly
#: these (scratchclean.py); a FAIL keeps them and names SCRATCH.
MADE = []

MAUX_BIN = {
    'cat': 'CAT', 'cmp': 'CMP', 'comm': 'COMM', 'expr': 'EXPR',
    'head': 'HEAD', 'grep': 'GREP', 'mkdir': 'MKDIR', 'pwd': 'PWD',
    'sleep': 'SLEEP', 'true': 'TRUE', 'false': 'FALSE',
    # 'echo' resolves to the ABSOLUTE path -- shbltn.s's
    # CHCK_BLTN_ECH intercepts a bare "ECHO" word (NCMD==1, no
    # '<', no 'N>&M') before RUN_PIPELINE ever spawns the real
    # /bin/ECHO binary, and this suite's own `> OUT`
    # redirection is exactly the shape the builtin DOES handle
    # (its own header says so) -- so testing the BINARY (the
    # task's own instruction) requires the full path, which
    # STRCMPI never matches against the literal "ECHO" it
    # compares CMD_ARGV[0] to.
    'echo': '/bin/ECHO',
    'wc': 'WC', 'tail': 'TAIL', 'uniq': 'UNIQ', 'tr': 'TR',
    'sort': 'SORT', 'od': 'OD', 'find': 'FIND', 'diff': 'DIFF',
    'ls': 'LS', 'cp': 'CP', 'mv': 'MV', 'rm': 'RM', 'date': 'DATE',
    'touch': 'TOUCH', 'du': 'DU', 'df': 'DF', 'tee': 'TEE',
    'kill': 'KILL',
    # 'test' is a shell BUILTIN (src/bin/shparse.s CHCK_BLTN_TST),
    # never a spawned binary -- 'TEST' at command position dispatches
    # straight into it, same as any other builtin word.
    'test': 'TEST',
    'cut': 'CUT',
    'xargs': 'XARGS',
    'printf': 'PRINTF',
    'basename': 'BASENAME',
    'dirname': 'DIRNAME',
    'env': 'ENV',
    'uuencode': 'UUENCODE',
    'uudecode': 'UUDECODE',
    'rmdir': 'RMDIR', 'tty': 'TTY', 'uname': 'UNAME',
    'cksum': 'CKSUM', 'paste': 'PASTE', 'fold': 'FOLD',
    'nl': 'NL', 'expand': 'EXPAND', 'unexpand': 'UNEXPAND',
    # man (2026-09-15): every case is `hand=` (no host equivalent --
    # see MAN_CASES's own header), so it needs no HOST_BIN entry --
    # _host_once() is never called for a hand-authored case.
    'man': 'MAN', 'cal': 'CAL', 'strings': 'STRINGS',
    # nohup/timeout/realpath (eng-nohup-timeout-realpath, cut from
    # a9034eb): every case is `hand=` for all three -- nohup's
    # stdout-not-a-tty rows have no divergence risk but the tty
    # path is check-play-only; timeout has NO host oracle at all
    # (this Mac has no `timeout`); realpath's base directory is
    # per-case so its rows compare via the shell's own $( ), never
    # a literal -- so none of the three needs a HOST_BIN entry.
    'nohup': 'NOHUP',
    'timeout': 'TIMEOUT',
    'realpath': 'REALPATH',
    'tsort': 'TSORT', 'pr': 'PR', 'pathchk': 'PATHCHK',
    'split': 'SPLIT',
    'csplit': 'CSPLIT',
    'join': 'JOIN',
    'patch': 'PATCH',
    # make: every non-hand row is a `-n` dry run, so the recipe names
    # a command (`ZORK`) that exists on neither system and the
    # comparison is purely of the expansion machinery. See
    # posixutil_cases5.py's own docstring.
    'make': 'MAKE',
    'sh': 'SH',
}
HOST_BIN = {
    # `make` is GNU make on both hosts this suite runs on. Every
    # non-hand make row is a `-n` dry run whose fixture passes -r, so
    # the built-in rule and suffix database GNU has and maux does not
    # is cleared before either side starts (posixutil_cases5.py).
    'make': '/usr/bin/make',
    'cat': '/bin/cat', 'cmp': '/usr/bin/cmp', 'comm': '/usr/bin/comm',
    'expr': '/bin/expr', 'head': '/usr/bin/head', 'grep': '/usr/bin/grep',
    'mkdir': '/bin/mkdir', 'pwd': '/bin/pwd', 'sleep': '/bin/sleep',
    'true': '/usr/bin/true', 'false': '/usr/bin/false',
    'echo': '/bin/echo',
    'wc': '/usr/bin/wc', 'tail': '/usr/bin/tail', 'uniq': '/usr/bin/uniq',
    'tr': '/usr/bin/tr', 'sort': '/usr/bin/sort', 'od': '/usr/bin/od',
    'find': '/usr/bin/find', 'diff': '/usr/bin/diff', 'ls': '/bin/ls',
    'cp': '/bin/cp', 'mv': '/bin/mv', 'rm': '/bin/rm',
    'date': '/bin/date', 'touch': '/usr/bin/touch', 'du': '/usr/bin/du',
    'tee': '/usr/bin/tee', 'kill': '/bin/kill', 'test': '/bin/test',
    'cut': '/usr/bin/cut',
    'xargs': '/usr/bin/xargs',
    'printf': '/usr/bin/printf',
    'basename': '/usr/bin/basename',
    'dirname': '/usr/bin/dirname',
    'env': '/usr/bin/env',
    'uuencode': '/usr/bin/uuencode',
    'uudecode': '/usr/bin/uudecode',
    'rmdir': '/bin/rmdir', 'tty': '/usr/bin/tty', 'uname': '/usr/bin/uname',
    'cksum': '/usr/bin/cksum', 'paste': '/usr/bin/paste',
    'fold': '/usr/bin/fold',
    'nl': '/usr/bin/nl', 'expand': '/usr/bin/expand',
    'unexpand': '/usr/bin/unexpand',
    'cal': '/usr/bin/cal', 'strings': '/usr/bin/strings',
    'tsort': '/usr/bin/tsort', 'pr': '/usr/bin/pr',
    'pathchk': '/usr/bin/pathchk',
    'split': '/usr/bin/split',
    'csplit': '/usr/bin/csplit',
    'join': '/usr/bin/join',
    # patch: present for completeness and for the authoring runs
    # described in posixutil_cases4's docstring -- every shipped patch
    # row is hand-authored, so this path is never actually invoked by
    # the suite (oracle() short-circuits on `hand`).
    'patch': '/usr/bin/patch',
}


# ======================================================================
# case table
# ======================================================================
def C(tool, name, spec, argv, *, files=None, dirs=None, predirs=None,
      stdin=None, results=None, post=None, hand=None, known_gap=None,
      reset=None, norm=None, meta_equal=None):
    """`reset`, when given, is a dict of extra kwargs merged onto this
    batch's `reset` MCP call (e.g. {'clock': False} for date.s's
    no-valid-clock path -- see check_sumdate.py's own header: the
    Timemaster card defaults ON, so a live RTC reading cannot be
    predicted without a peek synchronized to the syscall, which is
    what THAT gate is for; pinning clock:False here instead proves
    the courteous-refusal path deterministically). All cases sharing
    a boot group must agree on `reset` (enforced by process_batch);
    main()'s batching splits a group early rather than mix two."""
    if norm is not None and norm not in NORMALIZERS:
        raise RuntimeError(f'unknown norm {norm!r} -- add it to '
                            f'NORMALIZERS with its own reason')
    return dict(tool=tool, name=name, spec=spec, argv=list(argv),
                files=files or {}, dirs=dirs or {},
                predirs=list(predirs or []), stdin=stdin,
                results=list(results or []), post=list(post or []),
                hand=hand, known_gap=known_gap, reset=reset, norm=norm,
                meta_equal=list(meta_equal or []))


# ======================================================================
# normalizers -- the ONE sanctioned way to compare less than every byte
# ======================================================================
# A `norm=` names a function applied IDENTICALLY to both sides' stdout
# (and to every named result file) before they are compared. It exists
# for exactly one situation: a field POSIX leaves UNSPECIFIED whose
# text the two sides cannot agree on and which no choice of argv can
# suppress on both. It is NOT a place to hide a divergence -- a row
# that needs more than a named unspecified field belongs in `hand=`
# with its reason, the way `ls -C` and `cmp -l` already are.
#
# diffhdr (2026-09-17, diff -u/-c): POSIX's -u and -c output begins
# with two header lines carrying a pathname and that file's
# modification timestamp. The timestamp's TEXT is unspecified, and the
# two engines print different ones by construction: BSD diff prints
# ctime form ("Thu Sep 17 08:55:26 2026") after a <tab>, GNU prints
# ISO form, and maux prints NOTHING (src/bin/diffctx.s's header note:
# a ProDOS file's stamp is the host clock at a2til STAGING time, which
# is exactly the "predict a live clock reading" race that kept `ls -l`
# out of this suite entirely -- see the ls section's own note). So the
# field is dropped from the FIRST TWO LINES ONLY, at the first <tab>,
# on both sides; every other byte of the diff -- including the
# pathname itself, which IS specified -- still compares exactly.
def _norm_diffhdr(lines):
    out = list(lines)
    for i in (0, 1):
        if i < len(out) and out[i][:4] in ('--- ', '+++ ', '*** '):
            out[i] = out[i].split('\t')[0]
    return out


# prhdr (2026-10-08, pr page mode): pr's page header is
# "<date> <name> Page N". The date is the file's mtime -- a2til stamps
# the staged copy at staging time, a different second from the host's
# own copy -- and the layout around it is unspecified and differs by
# host (BSD: "Oct  8 20:33 2026 NAME Page 1"; GNU: ISO date, the name
# centred in padding). Only the header's presence and its PAGE NUMBER
# are gated: each such line becomes "HDR Page N" on both sides. Every
# other byte -- blank lines, body, padding, form feeds -- compares
# exactly.
_PRHDR = re.compile(
    r'^\x0c?(?:[A-Z][a-z]{2} [ 0-9][0-9] [0-9:]{5} [0-9]{4}'
    r'|[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{5}).* Page ([0-9]+)$')


def _norm_prhdr(lines):
    out = []
    for ln in lines:
        m = _PRHDR.match(ln)
        out.append(('\x0c' if ln.startswith('\x0c') else '')
                   + 'HDR Page ' + m.group(1) if m else ln)
    return out


# diffrhdr (2026-10-08, diff -r -u/-c): the same unspecified timestamp
# field, but `diff -r` puts a `diff OPTS A B` line in front of each
# pair's listing, so the two header lines are NOT lines 0 and 1 of
# the output. The field is dropped from the two lines that follow
# EVERY `diff ` line, on both sides; nothing else is touched.
def _norm_diffrhdr(lines):
    out = list(lines)
    for i, ln in enumerate(out):
        if ln[:5] != 'diff ':
            continue
        for j in (i + 1, i + 2):
            if j < len(out) and out[j][:4] in ('--- ', '+++ ', '*** '):
                out[j] = out[j].split('\t')[0]
    return out


NORMALIZERS = {'diffhdr': _norm_diffhdr, 'prhdr': _norm_prhdr,
               'diffrhdr': _norm_diffrhdr}


def Q(word):
    """Wrap a word in single quotes for typing at maux's own shell --
    shtok.s treats |&<>; as operators and glob.s treats *?[ specially,
    so any expr operator/regex metachar must be quoted the same way
    check_posixsed.py already quotes -e scripts."""
    return "'" + word + "'"


L3 = ['alpha', 'bravo', 'charlie']


CASES = [
    # ==================================================================
    # cat -- XCU cat.html
    # ==================================================================
    C('cat', 'basic single file',
      'The cat utility shall read files in sequence and shall write '
      'their contents to the standard output in the same sequence.',
      ['@F@'], files={'F': L3}),
    C('cat', 'multiple files concatenated',
      'The cat utility shall read files in sequence and shall write '
      'their contents to the standard output in the same sequence.',
      ['@F1@', '@F2@'], files={'F1': ['one', 'two'], 'F2': ['three']}),
    C('cat', 'no operands reads stdin',
      "If no file operands are specified, the standard input shall be "
      "used.",
      [], files={'IN': L3}, stdin='IN'),
    C('cat', 'missing file continues, exit>0',
      '>0 An error occurred.',
      ['@F1@', '@NOSUCH@', '@F2@'],
      files={'F1': ['one'], 'NOSUCH': None, 'F2': ['two']}),
    # BOTH SHIPPED 2026-09-21. -u is a no-op that is ALREADY TRUE:
    # COPYFD reads and writes through the MLI parmlists and never
    # touches liba's buffered stdio, so every byte is written as soon
    # as it is read. Refusing the flag made `cat -u F` treat "-u" as
    # a pathname -- right output, wrong exit status. It is accepted
    # only in the LEADING position, which is all POSIX guarantees,
    # so a file genuinely called -u is still reachable as ./-u.
    C('cat', '-u is accepted (output is already unbuffered)',
      "-u Write bytes from the input file to the standard output "
      "without delay as each is read.",
      ['-u', '@F@'], files={'F': ['x']}),
    # The operand list is ['-'] with a REDIRECTED stdin, not a bare
    # ['-']: on this machine a `-` with nothing redirected reads the
    # CONSOLE, which never reaches EOF, so the batch harness waits
    # forever on a case that is working correctly. Same shape as the
    # reason `tail -f` stays a named gap.
    C('cat', "'-' means stdin",
      "If a file is '-', the cat utility shall read from the standard "
      "input at that point in the sequence.",
      ['-'], stdin='IN', files={'IN': ['piped line']}),

    # ==================================================================
    # cmp -- XCU cmp.html
    # ==================================================================
    C('cmp', 'identical files',
      '0 The files are identical.',
      ['@F1@', '@F2@'], files={'F1': L3, 'F2': list(L3)}),
    C('cmp', 'default differ message',
      '"%s %s differ: char %d, line %d\\n", file1, file2, <byte '
      'number>, <line number>',
      ['@F1@', '@F2@'], files={'F1': ['abc'], 'F2': ['abd']}),
    C('cmp', '-l lists every differing byte pair',
      '"%d %o %o\\n", <byte number>, <differing byte>, <differing '
      'byte>',
      ['-l', '@F1@', '@F2@'], files={'F1': ['abc'], 'F2': ['abd']},
      hand=dict(stdout=['     3 343 344'], rc=1,
                reason="-l reports the RAW STORED byte value, and the "
                       "two sides store text in different encodings "
                       "by design: maux's own text-file convention is "
                       "high-bit-set ASCII (hi()/hilines(), the same "
                       "helper check_posixsed.py uses), while this "
                       "harness's host-side fixture file is plain "
                       "low-bit ASCII. A live BSD cmp -l on the "
                       "low-bit pair reports '     3 143 144' (0143 "
                       "='c', 0144='d'); maux's cmp reads its own "
                       "high-bit-set copies of the same two letters "
                       "and correctly reports '     3 343 344' (0343 "
                       "= 0143+0200, 0344 = 0144+0200 -- exactly the "
                       "high bit). Not a maux bug: it is a byte-exact "
                       "encoding fact about how maux stores text, "
                       "which -l's raw octal dump exposes and a line-"
                       "oriented tool's CR/high-bit translation "
                       "(maux_lines()) would normally hide. Expected "
                       "value is the host's own octal digits with "
                       "0200 added to each, not a captured maux run.")),
    C('cmp', '-s is silent, status only',
      'Write nothing to standard output or standard error when files '
      'differ; indicate differing files through exit status only.',
      ['-s', '@F1@', '@F2@'], files={'F1': ['abc'], 'F2': ['abd']}),
    C('cmp', 'EOF on the shorter file',
      '"cmp: EOF on %s%s\\n", <name of shorter file>, <additional '
      'info>',
      ['@F1@', '@F2@'], files={'F1': ['ab'], 'F2': ['ab', 'c']}),
    C('cmp', 'missing file operand is an error',
      '>1 An error occurred.',
      ['@F1@', '@NOSUCH@'], files={'F1': ['abc'], 'NOSUCH': None}),
    C('cmp', '-l with -s is refused',
      '-s Write nothing to standard output or standard error when '
      'files differ...',
      ['-l', '-s', '@F1@', '@F2@'],
      files={'F1': ['abc'], 'F2': ['abd']}),
    # SH-DEFECTS item 8 (2026-10-25). The counters were 16-bit, so a
    # difference past 64 KB reported char N mod 65536. 70,000 EMPTY
    # lines are 70,000 CR bytes, so ONE fixture crosses 65536 on BOTH
    # counters at once: the first difference is at char 66001 / line
    # 66001 (16-bit code printed char 465, line 465). The files are
    # GENERATED here, never committed: ~137 blocks each on the gate
    # image, ~275 for the pair, in one per-case subdirectory.
    C('cmp', 'difference past 64 KB: char and line are 24-bit',
      '"%s %s differ: char %d, line %d\\n", file1, file2, <byte '
      'number>, <line number>',
      ['@F1@', '@F2@'],
      files={'F1': [''] * 70000,
             'F2': [''] * 66000 + ['x'] + [''] * 3999}),
    C('cmp', '-l offset past 64 KB is 24-bit',
      '"%d %o %o\\n", <byte number>, <differing byte>, <differing '
      'byte>',
      ['-l', '@F1@', '@F2@'],
      files={'F1': [''] * 70000,
             'F2': [''] * 66000 + ['x'] + [''] * 3999},
      hand=dict(stdout=[' 66001 215 370'], rc=1,
                reason="-l reports the raw stored byte, and maux "
                       "stores text high-bit-set (CR = 0215, 'x' = "
                       "0370) where the host fixture is low-bit; a "
                       "live BSD cmp -l prints ' 66001  12 170'. "
                       "Expected = the host's offset with each octal "
                       "byte plus 0200. Position 66001 is the point: "
                       "16-bit code printed ' 465'. The two files "
                       "differ in LENGTH by one byte (the host file "
                       "gains the x), so the EOF diagnostic follows "
                       "on stderr, which is not compared.")),

    # The 7-digit rows. The no-pad branch of PRLPAIR (offset >= 7
    # digits) and PR3NUM's 7-digit output need a difference at offset
    # >= 1,000,000. 10,050 lines of 99 'a' + CR are 1,005,000 bytes per
    # file (~1,965 blocks, ~3,930 for the pair); the pair fits a boot
    # group's image (6,347 of 8,192 blocks free) ONLY ALONE, so the two
    # rows are kept in separate boot groups by giving the second a
    # different (default-valued) `reset`, and each row removes its
    # fixtures when it finishes (`post`). First difference: line 10001,
    # column 5 -> char 1,000,005.
    C('cmp', 'difference past 1 MB: 7-digit char',
      '"%s %s differ: char %d, line %d\\n", file1, file2, <byte '
      'number>, <line number>',
      ['@F1@', '@F2@'],
      files={'F1': ['a' * 99] * 10050,
             'F2': ['a' * 99] * 10000 + ['aaaab' + 'a' * 94]
                   + ['a' * 99] * 49},
      post=[['rm', '@F1@'], ['rm', '@F2@']]),
    C('cmp', '-l offset past 1 MB: 7 digits, no pad',
      '"%d %o %o\\n", <byte number>, <differing byte>, <differing '
      'byte>',
      ['-l', '@F1@', '@F2@'],
      files={'F1': ['a' * 99] * 10050,
             'F2': ['a' * 99] * 10000 + ['aaaab' + 'a' * 94]
                   + ['a' * 99] * 49},
      reset={'clock': True},
      post=[['rm', '@F1@'], ['rm', '@F2@']],
      hand=dict(stdout=['1000005 341 342'], rc=1,
                reason="-l reports the raw stored byte; maux stores "
                       "'a' as 0341 and 'b' as 0342 (host 0141/0142 "
                       "plus 0200), as in the other -l rows. Seven "
                       "digits overflow %6d, so there is NO pad: "
                       "this row runs PRLPAIR's no-pad branch.")),

    # ==================================================================
    # comm -- XCU comm.html
    # ==================================================================
    C('comm', 'default: three columns',
      'produce three text columns as output: lines only in file1, '
      'lines only in file2, and lines in both files.',
      ['@F1@', '@F2@'],
      files={'F1': ['a', 'b', 'c'], 'F2': ['b', 'c', 'd']}),
    C('comm', '-3 suppresses the common column',
      'If the -3 option is not selected, lines contained in both '
      'files shall be written...',
      ['-3', '@F1@', '@F2@'],
      files={'F1': ['a', 'b', 'c'], 'F2': ['b', 'c', 'd']}),
    C('comm', '-123 writes nothing',
      'If the -1, -2, and -3 options are all selected, comm shall '
      'write nothing to standard output.',
      ['-1', '-2', '-3', '@F1@', '@F2@'],
      files={'F1': ['a', 'b', 'c'], 'F2': ['b', 'c', 'd']}),
    C('comm', '-1 suppresses column 1 (adaptive lead)',
      "null string -- The -1 option is selected. [column 2's lead]",
      ['-1', '@F1@', '@F2@'],
      files={'F1': ['a', 'b', 'c'], 'F2': ['b', 'c', 'd']}),
    C('comm', '-2 suppresses column 2 (adaptive lead)',
      "<tab> -- Exactly one of the -1 and -2 options is selected. "
      "[column 3's lead]",
      ['-2', '@F1@', '@F2@'],
      files={'F1': ['a', 'b', 'c'], 'F2': ['b', 'c', 'd']}),
    C('comm', '-12 leaves only the common column',
      'null string -- Both the -1 and -2 options are selected. '
      '[column 3\'s lead]',
      ['-1', '-2', '@F1@', '@F2@'],
      files={'F1': ['a', 'b', 'c'], 'F2': ['b', 'c', 'd']}),
    C('comm', 'exactly two operands required',
      'The following operands shall be supported: file1 ... file2',
      ['@F1@'], files={'F1': ['a']},
      hand=dict(stdout=[], rc=2,
                reason="POSIX's EXIT STATUS clause for comm is the "
                       "generic '>0 An error occurred.', not a fixed "
                       "number; BSD comm (this Mac's oracle) happens "
                       "to pick 1 for a wrong operand count (verified "
                       "live: 'usage: comm [-123i] file1 file2' on "
                       "stderr, rc=1), while comm.s's own header "
                       "documents exit 2 for every usage/bad-option "
                       "error, matching cmp.s's own '\"must be "
                       "exactly 2\" shape' and every other util in "
                       "this tree. Both are POSIX-legal; this row "
                       "used to be a KNOWN_GAP for an unrelated "
                       "reason (the usage message's missing trailing "
                       "CR made the harness's own prompt-detection "
                       "time out, not a real hang -- fixed 2026-09-13, "
                       "module docstring bug 3), and retiring it "
                       "surfaced this separate, legitimate exit-code "
                       "divergence that the hang had been masking.")),

    # ==================================================================
    # expr -- XCU expr.html
    # ==================================================================
    C('expr', 'addition', 'expr1 + expr2 -- Addition of decimal '
      'integer-valued arguments.', [Q('2'), Q('+'), Q('3')]),
    C('expr', 'subtraction to zero is falsy',
      'The expression evaluated to null or zero... exit 1.',
      [Q('3'), Q('-'), Q('3')]),
    C('expr', 'multiplication',
      'expr1 * expr2 -- Multiplication of decimal integer-valued '
      'arguments.', [Q('6'), Q('*'), Q('7')]),
    C('expr', 'integer division',
      'expr1 / expr2 -- Integer division of decimal integer-valued '
      'arguments, producing an integer result.',
      [Q('17'), Q('/'), Q('5')]),
    C('expr', 'remainder',
      'expr1 % expr2 -- Remainder of integer division of decimal '
      'integer-valued arguments.', [Q('17'), Q('%'), Q('5')]),
    C('expr', 'numeric equal', 'expr1 = expr2 -- Equal.',
      [Q('4'), Q('='), Q('4')]),
    C('expr', 'numeric not-equal', 'expr1 != expr2 -- Not equal.',
      [Q('4'), Q('!='), Q('5')]),
    C('expr', 'less-than', 'expr1 < expr2 -- Less than.',
      [Q('3'), Q('<'), Q('4')]),
    C('expr', 'less-or-equal', 'expr1 <= expr2 -- Less than or equal.',
      [Q('4'), Q('<='), Q('4')]),
    C('expr', 'greater-than', 'expr1 > expr2 -- Greater than.',
      [Q('5'), Q('>'), Q('4')]),
    C('expr', 'greater-or-equal',
      'expr1 >= expr2 -- Greater than or equal.',
      [Q('4'), Q('>='), Q('4')]),
    C('expr', 'AND both truthy',
      'expr1 & expr2 -- Returns the evaluation of expr1 if neither '
      'expression evaluates to null or zero; otherwise, returns zero.',
      [Q('3'), Q('&'), Q('4')]),
    C('expr', 'AND left falsy yields zero',
      'expr1 & expr2 -- ...otherwise, returns zero.',
      [Q('0'), Q('&'), Q('5')]),
    C('expr', 'OR left truthy',
      'expr1 | expr2 -- Returns the evaluation of expr1 if it is '
      'neither null nor zero...',
      [Q('7'), Q('|'), Q('0')]),
    C('expr', 'OR left falsy falls through',
      'expr1 | expr2 -- ...otherwise, returns the evaluation of '
      'expr2 if it is not null...',
      [Q('0'), Q('|'), Q('9')]),
    C('expr', 'string equality true',
      'Returns the result of a decimal integer comparison if both '
      'arguments are integers; otherwise, returns the result of a '
      'string comparison...',
      [Q('abc'), Q('='), Q('abc')]),
    C('expr', 'string equality false (non-numeric operands)',
      'otherwise, returns the result of a string comparison using '
      'the locale-specific collation sequence.',
      [Q('abc'), Q('='), Q('xyz')]),
    C('expr', 'precedence: * binds tighter than +',
      'The expressions are listed in order of decreasing precedence '
      '... All of the operators shall be left-associative.',
      [Q('2'), Q('+'), Q('3'), Q('*'), Q('4')]),
    C('expr', 'leftover token is a syntax error',
      '2 Invalid expression error.',
      [Q('1'), Q('2')]),
    C('expr', 'division by zero: 16-bit maux vs. 64-bit BSD',
      '>2 Another error occurred.',
      [Q('5'), Q('/'), Q('0')],
      hand=dict(stdout=[], rc=3,
                reason="POSIX permits ANY code >2 for 'another error "
                       "occurred' and 2 for 'invalid expression'; BSD "
                       "expr (this Mac's oracle) picks 2 for div-by-"
                       "zero ('expr: division by zero', verified "
                       "live), while maux's own EX_DODIV/EX_DOMOD "
                       "(src/bin/expr.ops.s) documents and sets "
                       "EX_STATUS=3 specifically for a zero divisor. "
                       "Both are POSIX-legal; they are not the SAME "
                       "code, so BSD cannot oracle this row.")),
    C('expr', 'overflow: 16-bit maux vs. 64-bit BSD',
      '2 Invalid expression error.',
      [Q('60000'), Q('+'), Q('60000')],
      hand=dict(stdout=[], rc=2,
                reason="maux's numbers are unsigned 16-bit only "
                       "(expr.s header: 'NUMBERS: unsigned 16-bit "
                       "only (0-65535)... OVERFLOW CHOICE: LOUD "
                       "ERROR'), so 60000+60000 (120000) overflows "
                       "and EXPR_EXITCD/EX_NPARSE force status 2. A "
                       "64-bit BSD host computes 120000 successfully "
                       "and exits 0 -- not a shared construct, so BSD "
                       "cannot oracle it; the expectation is maux's "
                       "own documented contract, not a captured run.")),
    # ':' SHIPPED 2026-10-08 (docs/POSIX-REGEXLINK.md): expr links the
    # house BRE engine (src/bin/expr.match.s). The row below is the
    # retired known-gap row -- same argv, same oracle, now green.
    # Measured on BOTH hosts (Mac BSD expr, box GNU expr): they agree
    # on every row that stays host-oracled; the rows that follow
    # the `hand=` ones name the six places they do not.
    C('expr', "':' matching operator: length of an anchored match "
              "(retired known-gap row)",
      "expr1 : expr2 -- Matching expression... compare the string "
      "resulting from the evaluation of expr1 with the regular "
      "expression pattern resulting from the evaluation of expr2.",
      [Q('foo'), Q(':'), Q('f.o')]),
    C('expr', "':' a pattern that matches only PART of the string "
              "returns that length",
      "expr1 : expr2 ... the pattern shall be anchored to the "
      "beginning of the string",
      [Q('foo'), Q(':'), Q('f')]),
    C('expr', "':' is anchored: a match further along is no match "
              "(result 0, exit 1)",
      "expr1 : expr2 ... implicitly anchored at the beginning",
      [Q('foo'), Q(':'), Q('o')]),
    C('expr', "':' with .* is the string's length",
      "expr1 : expr2 ... number of characters matched",
      [Q('foo'), Q(':'), Q('.*')]),
    C('expr', "':' of the empty string matches .* with length 0",
      "expr1 : expr2 ... number of characters matched; 0 on failure",
      [Q(''), Q(':'), Q('.*')]),
    C('expr', "':' with a group returns the group's text",
      "...if the pattern contains at least one BRE subexpression "
      "\\(...\\), the string corresponding to \\1 shall be returned",
      [Q('foo'), Q(':'), Q('\\(f\\)')]),
    C('expr', "':' returns the FIRST group of several",
      "...the string corresponding to \\1 shall be returned",
      [Q('abc'), Q(':'), Q('a\\(b\\)\\(c\\)')]),
    C('expr', "':' group inside a longer pattern returns the group "
              "(the tail)",
      "...the string corresponding to \\1 shall be returned",
      [Q('foobar'), Q(':'), Q('foo\\(.*\\)')]),
    C('expr', "':' group that matched empty returns the empty "
              "string, exit 1",
      "...the string corresponding to \\1 shall be returned",
      [Q('foo'), Q(':'), Q('f\\(x*\\)')]),
    C('expr', "':' group in a pattern that does not match: empty "
              "string, exit 1",
      "...or a null string if the pattern does not match",
      [Q('foo'), Q(':'), Q('\\(x\\)')]),
    C('expr', "':' backreference inside the pattern",
      "BRE: \\(...\\) and \\1 are in the basic regular "
      "expression grammar",
      [Q('aa'), Q(':'), Q('\\(a\\)\\1')]),
    C('expr', "':' backreference that fails: empty, exit 1",
      "BRE: \\(...\\) and \\1 are in the basic regular "
      "expression grammar",
      [Q('abc'), Q(':'), Q('\\(a\\)\\1')]),
    C('expr', "':' a leading ^ is the (redundant) anchor",
      "expr1 : expr2 ... implicitly anchored",
      [Q('foo'), Q(':'), Q('^f')]),
    C('expr', "':' a SECOND ^ is a literal one",
      "expr1 : expr2 ... implicitly anchored; a ^ not at the start "
      "of a BRE is an ordinary character",
      [Q('^f'), Q(':'), Q('^^f')]),
    C('expr', "':' a trailing $ anchors the end",
      "BRE: $ anchors at the end of the string",
      [Q('foo'), Q(':'), Q('foo$')]),
    C('expr', "':' a trailing $ that does not reach the end fails",
      "BRE: $ anchors at the end of the string",
      [Q('foo'), Q(':'), Q('fo$')]),
    C('expr', "':' an interval",
      "BRE: \\{m,n\\} intervals",
      [Q('foo'), Q(':'), Q('f\\{1,2\\}')]),
    C('expr', "':' a bracket expression with a class and a group",
      "BRE: bracket expressions with character classes",
      [Q('abc'), Q(':'), Q('[[:alpha:]]*\\(c\\)')]),
    C('expr', "':' a leading ] in a bracket is a member",
      "BRE: a ] first in a bracket expression is a member",
      [Q('a]b'), Q(':'), Q('[]a]*')]),
    C('expr', "':' an escaped dot is a literal dot",
      "BRE: \\. is a literal period",
      [Q('a.b'), Q(':'), Q('a\\.b')]),
    C('expr', "':' a numeric operand matches its text as TYPED "
              "(leading zeros kept)",
      "expr1 : expr2 ... the string resulting from the evaluation "
      "of expr1",
      [Q('007'), Q(':'), Q('0')]),
    C('expr', "':' numeric operands on both sides",
      "expr1 : expr2 ... the string resulting from the evaluation "
      "of expr1",
      [Q('10'), Q(':'), Q('1')]),
    C('expr', "':' group over a zero-padded number, then the tail",
      "...the string corresponding to \\1 shall be returned",
      [Q('007'), Q(':'), Q('0*\\(.*\\)')]),
    C('expr', "':' binds TIGHTER than * (the match is the left "
              "operand of the multiplication)",
      "The expressions are listed in order of decreasing "
      "precedence: expr1 : expr2 ... expr1 * expr2",
      [Q('foo'), Q(':'), Q('f.o'), Q('*'), '2']),
    C('expr', "':' binds tighter than * on the RIGHT as well",
      "The expressions are listed in order of decreasing "
      "precedence: expr1 : expr2 ... expr1 * expr2",
      ['2', Q('*'), Q('3'), Q(':'), Q('3')]),
    C('expr', "':' binds tighter than +",
      "The expressions are listed in order of decreasing "
      "precedence: expr1 : expr2 ... expr1 + expr2",
      ['3', Q('+'), Q('4'), Q(':'), Q('4')]),
    C('expr', "':' is left associative",
      "The expressions are listed in order of decreasing precedence",
      [Q('aaa'), Q(':'), Q('a*'), Q(':'), '3']),
    C('expr', "':' binds tighter than = (its result compares)",
      "The expressions are listed in order of decreasing "
      "precedence: expr1 : expr2 ... expr1 = expr2",
      [Q('foo'), Q(':'), Q('f'), Q('='), '1']),
    C('expr', "':' a parenthesised computed number is the text",
      "( expr ) -- Grouping symbols",
      [Q('('), '1', Q('+'), '2', Q(')'), Q(':'), '3']),
    C('expr', "':' a long group prints WHOLE (no result buffer "
              "to truncate)",
      "...the string corresponding to \\1 shall be returned",
      [Q('a' * 15 + 'b' * 15 + 'c' * 15 + 'd' * 15 + 'e' * 15),
       Q(':'), Q('\\(.*\\)')]),
    C('expr', "':' a literal ( inside a bracket is not a group "
              "(result is the length, not text)",
      "BRE: inside a bracket expression a backslash is an "
      "ordinary character",
      [Q('(x'), Q(':'), Q('[\\(]x')]),
    C('expr', "':' an escaped backslash before ( is not a group",
      "BRE: \\\\ is a literal backslash",
      [Q('\\(x'), Q(':'), Q('\\\\(x')]),
    C('expr', "':' a leading * is a literal star",
      "BRE: a * first in an expression is an ordinary character",
      [Q('*foo'), Q(':'), Q('*f')]),
    C('expr', "':' a '-1' operand is text, not an option",
      "expr1 : expr2",
      [Q('-1'), Q(':'), Q('-1')]),
    # THE SIX PLACES THE TWO HOSTS DISAGREE, each a hand= row from
    # the XCU text with the measurement in its reason.
    C('expr', "':' group text that is a decimal integer takes part "
              "in arithmetic",
      "expr1 + expr2 -- Addition of decimal integer-valued "
      "arguments",
      [Q('10'), Q(':'), Q('\\(1.\\)'), Q('+'), '1'],
      hand=dict(stdout=['11'], rc=0,
                reason="measured: the box's GNU expr prints 11; this "
                       "Mac's BSD expr REFUSES it with 'not a decimal "
                       "number: 10' (exit 2), treating the matched "
                       "text as opaque. The XCU text makes the "
                       "result of ':' an ordinary expression value, "
                       "and a string of decimal digits is an integer "
                       "there. maux follows GNU/XCU: a canonical "
                       "decimal group (no leading zero) is a number.")),
    C('expr', "':' a group of all zeros is zero: exit 1, text kept",
      "Exit status: 1 -- The expression evaluated to null or zero",
      [Q('007'), Q(':'), Q('\\(0*\\)')],
      hand=dict(stdout=['00'], rc=1,
                reason="measured: both hosts print 00; GNU exits 1 "
                       "(zero), BSD exits 0 (it calls any non-empty "
                       "string true except a lone 0). XCU: 'null or "
                       "zero' -> 1. maux follows GNU/XCU, and prints "
                       "the text as the pattern matched it, not as a "
                       "number (EX_FALSCK's all-zeros rule).")),
    C('expr', "':' a group of a lone 0 is zero: exit 1",
      "Exit status: 1 -- The expression evaluated to null or zero",
      [Q('0'), Q(':'), Q('\\(0\\)')],
      hand=dict(stdout=['0'], rc=1,
                reason="measured: GNU exit 1, BSD exit 0 (BSD treats "
                       "the matched string '0' as true). XCU: zero -> "
                       "exit 1.")),
    C('expr', "':' a leading * in the pattern is an ordinary "
              "character: no match",
      "BRE: a * first in an expression is an ordinary character",
      [Q('foo'), Q(':'), Q('*')],
      hand=dict(stdout=['0'], rc=1,
                reason="measured: GNU prints 0 and exits 1; BSD "
                       "refuses with 'syntax error' (exit 2). POSIX "
                       "BRE reads a leading * as a literal, which "
                       "matches nothing in 'foo'.")),
    C('expr', "':' an empty pattern matches the empty prefix: 0, "
              "exit 1",
      "expr1 : expr2 (the XCU text is silent on an empty BRE)",
      [Q('foo'), Q(':'), Q('')],
      hand=dict(stdout=['0'], rc=1,
                reason="measured: GNU prints 0 and exits 1; BSD "
                       "refuses with 'empty (sub)expression' "
                       "(exit 2). An empty BRE matches an empty "
                       "string at the start, whose length is 0.")),
    C('expr', "':' group text times a number",
      "expr1 * expr2 -- Multiplication of decimal integer-valued "
      "arguments",
      ['12', Q(':'), Q('\\([0-9]*\\)'), Q('*'), '2'],
      hand=dict(stdout=['24'], rc=0,
                reason="measured: GNU 24; BSD refuses (exit 2) for "
                       "the same reason as the + row above.")),
    # A MALFORMED BRE: neither host's behaviour is reachable.
    C('expr', "':' a malformed BRE is a usage error (exit 2) on "
              "the hosts",
      "expr1 : expr2 ... > 1 An error occurred.",
      [Q('foo'), Q(':'), Q('\\(')],
      known_gap="regex.s has no compile step (the Fowler/Spencer "
                "report counts 28 regcomp-error rows 'reported but "
                "unscored' for the same reason): a malformed BRE is "
                "a SAFE NO-MATCH, so maux prints an empty line and "
                "exits 1 where BSD ('parentheses not balanced') and "
                "GNU ('Unmatched ( or \\(') both exit 2. The "
                "same holds for an unterminated [. Giving the "
                "engine a validating pass is a change to the "
                "shared library, not to expr."),
    # SHIPPED 2026-09-21. A parenthesis in a recursive-descent parser
    # is the lowest rule calling the highest one, so EX_PRIM now
    # recurses to EX_OR; the precedence chain is untouched. A missing
    # ')' is status 2, not end-of-expression -- `expr ( 1 + 2` must
    # not quietly evaluate to 3.
    C('expr', 'parentheses group',
      '( expr ) -- Grouping symbols. Any expression can be placed '
      'within parentheses.',
      [Q('('), Q('1'), Q('+'), Q('2'), Q(')')]),
    C('expr', 'parentheses override precedence',
      '( expr ) -- Grouping symbols. Any expression can be placed '
      'within parentheses.',
      [Q('('), Q('1'), Q('+'), Q('2'), Q(')'), Q('*'), Q('3')]),

    # ==================================================================
    # head -- XCU head.html
    # ==================================================================
    C('head', 'default is -n 10',
      'If no options are specified, head shall act as if -n 10 had '
      'been specified.',
      ['@F@'], files={'F': [str(i) for i in range(1, 21)]}),
    C('head', '-n N explicit count',
      '-n number -- ...the ending location in the file shall be '
      'measured in lines...',
      ['-n', '2', '@F@'], files={'F': ['a', 'b', 'c', 'd']}),
    C('head', '-N obsolescent form',
      'Earlier versions of this standard allowed a -number option. '
      'This form is no longer specified by POSIX.1-2024 but may be '
      'present in some implementations.',
      ['-2', '@F@'], files={'F': ['a', 'b', 'c', 'd']}),
    C('head', 'short file copied in its entirety',
      'When a file contains less than number bytes or lines, it '
      'shall be copied to standard output in its entirety. This '
      'shall not be an error.',
      ['-n', '5', '@F@'], files={'F': ['a', 'b']}),
    C('head', 'multiple files get ==> NAME <== headers',
      '"\\n==> %s <==\\n", <pathname> -- except that the first header '
      'written shall not include the initial <newline>.',
      ['-n', '1', '@F1@', '@F2@'],
      files={'F1': ['a', 'b'], 'F2': ['x', 'y']}),
    C('head', 'no operands reads stdin',
      "The standard input shall be used if no file operands are "
      "specified...",
      ['-n', '2'], files={'IN': ['p', 'q', 'r']}, stdin='IN'),
    C('head', 'missing file continues, exit>0',
      '>0 An error occurred.',
      ['-n', '1', '@F1@', '@NOSUCH@', '@F2@'],
      files={'F1': ['a'], 'NOSUCH': None, 'F2': ['b']}),
    # SHIPPED 2026-09-21. The copy loop already decremented a counter
    # per CR; -c decrements it per BYTE, and the number is parsed by
    # -n's own digits loop. No per-line storage existed to change.
    C('head', '-c takes a byte count',
      '-c number -- The first number bytes of each input file shall '
      'be copied to standard output.',
      ['-c', '5', '@F@'], files={'F': ['abcdefghij', 'second line']}),

    # ==================================================================
    # grep -- XCU grep.html
    # ==================================================================
    C('grep', 'basic BRE match',
      'an input line shall be selected if any pattern, treated as an '
      'entire basic regular expression (BRE)... matches any part of '
      'the line',
      [Q('an'), '@F@'], files={'F': ['banana', 'kiwi', 'orange']}),
    C('grep', '-c counts selected lines',
      '-c Write only a count of selected lines to standard output.',
      ['-c', Q('an'), '@F@'], files={'F': ['banana', 'kiwi', 'orange']}),
    C('grep', '-i case-insensitive',
      '-i Perform pattern matching in a case-insensitive manner...',
      ['-i', Q('BANANA'), '@F@'], files={'F': ['banana', 'kiwi']}),
    C('grep', '-l names files, once, on multiple operands',
      '-l ... Pathnames shall be written once per file searched.',
      ['-l', Q('an'), '@F1@', '@F2@'],
      files={'F1': ['banana', 'x'], 'F2': ['orange', 'y', 'mango']}),
    C('grep', '-n precedes each line by its number',
      '-n Precede each output line by its relative line number in '
      'the file, each file starting at line 1.',
      ['-n', Q('an'), '@F@'], files={'F': ['banana', 'kiwi', 'mango']}),
    C('grep', '-q exits zero on a later match despite an earlier '
      'open error',
      'If the -q option is specified, the exit status shall be zero '
      'if an input line is selected, even if an error was detected.',
      ['-q', Q('an'), '@NOSUCH@', '@F@'],
      files={'NOSUCH': None, 'F': ['banana']}),
    C('grep', '-s suppresses the open-error message',
      '-s Suppress the error messages ordinarily written for '
      'nonexistent or unreadable files.',
      ['-s', Q('an'), '@NOSUCH@'], files={'NOSUCH': None}),
    C('grep', '-v inverts the match',
      '-v Select lines not matching any of the specified patterns.',
      ['-v', Q('an'), '@F@'], files={'F': ['banana', 'kiwi', 'mango']}),
    C('grep', '-x matches the whole line only',
      "-x Consider only input lines that use all characters in the "
      "line... to match an entire fixed string or regular expression",
      ['-x', Q('kiwi'), '@F@'], files={'F': ['banana', 'kiwi']}),
    C('grep', '-e supplies the pattern as an option-argument',
      '-e pattern_list -- Specify one or more patterns to be used '
      'during the search for input.',
      ['-e', Q('an'), '@F@'], files={'F': ['banana', 'kiwi']}),
    C('grep', 'multiple FILE operands get a FILE: prefix',
      '"%s:", <file> -- ...more than one file argument appears, and '
      '-q is not specified...',
      [Q('an'), '@F1@', '@F2@'],
      files={'F1': ['banana'], 'F2': ['mango']}),
    C('grep', 'unopenable file: exit>1',
      '>1 An error occurred.',
      [Q('an'), '@NOSUCH@'], files={'NOSUCH': None}),
    C('grep', '-E extended regular expressions is unimplemented',
      '-E Match using extended regular expressions.',
      ['-E', Q('ba+na'), '@F@'], files={'F': ['banana']},
      known_gap="grep.s's GETOPT table (GREPOPTS/the option switch "
                "in START) has no 'E' case at all -- 'E' falls "
                "through to :usage, exit 2. BSD grep -E treats '+' "
                "as one-or-more and matches, exit 0."),
    # SHIPPED 2026-09-21. -F is an ESCAPE, not a second matcher:
    # FESCAPE (src/bin/grep.s) quotes . * [ \\ ^ $ in PATBUF and the
    # one BRE engine does the matching unchanged, which is the same
    # "one matcher behind both tools" reasoning that put the engine in
    # liba. It refuses rather than truncates when the quoted form no
    # longer fits, XANCHOR's own posture.
    C('grep', '-F matches a fixed string, not a BRE',
      '-F Match using fixed strings.',
      ['-F', Q('a.c'), '@F@'], files={'F': ['a.c line', 'abc line']}),
    # SHIPPED 2026-09-21 with the pattern SET: -f and a repeated -e
    # are the same mechanism, so they landed together. Patterns live
    # in PATMAX 256-byte slots in the `dum` arena -- which emits no
    # image bytes -- so slot N is >PATTAB+N with no multiply and the
    # table is free. -f reuses GETLINE, the reader the search loop
    # uses, so a pattern file gets the same treatment an input file
    # does, final unterminated line included.
    C('grep', '-f reads patterns from a file',
      '-f pattern_file -- Read one or more patterns from the file '
      'named by the pathname pattern_file.',
      ['-f', '@PATFILE@', '@F@'],
      files={'PATFILE': ['banana'], 'F': ['banana', 'kiwi']}),
    C('grep', 'a second -e accumulates: either pattern selects',
      '-e pattern_list -- Specify one or more patterns... A line '
      'shall be selected if it matches any of the specified patterns.',
      ['-e', Q('alpha'), '-e', Q('beta'), '@F@'],
      files={'F': ['alpha', 'beta', 'gamma']}),

    # ==================================================================
    # mkdir -- XCU mkdir.html
    # ==================================================================
    C('mkdir', '-p accepts an existing directory leaf',
      'Each dir operand that names an existing directory shall be '
      'ignored without error.',
      ['-p', '@D@'], dirs={'D': 'EXIST'}, predirs=['D']),
    C('mkdir', '-p creates missing intermediate components',
      '-p -- Create any missing intermediate pathname components.',
      ['-p', '@D@'], dirs={'D': 'A/B/C', 'PROBE': 'A/B/C/PROBE'},
      post=[['ECHO', 'MARK', '>', '@PROBE@']],
      results=['PROBE'],
      hand=dict(stdout=[], rc=0, files={'PROBE': ['MARK']},
                reason="the assertion is a filesystem side effect "
                       "(the whole A/B/C chain really exists and is "
                       "open()-able), proven by a marker WRITE this "
                       "harness makes into the new leaf directory "
                       "after mkdir returns -- there is no tool "
                       "stdout to diff against a host oracle for "
                       "that; the expected marker content is this "
                       "harness's own choice of literal, not a value "
                       "captured from a maux run.")),
    C('mkdir', 'without -p, a missing parent fails',
      '>0 An error occurred.',
      ['@D@'], dirs={'D': 'NOPARENT/CHILD'}),
    C('mkdir', 'success is exit 0',
      '0 All the specified directories were created successfully...',
      ['@D@'], dirs={'D': 'FRESH'}),
    C('mkdir', '-m mode is unimplemented',
      '-m mode -- Set the file permission bits of the newly-created '
      'directory to the specified mode value.',
      ['-m', '755', '@D@'], dirs={'D': 'MODEDIR'},
      known_gap="mkdir.s's OPTLIST is the single byte \"p\" (grep "
                "OPTLIST in src/bin/mkdir.s) -- '-m' is not a "
                "registered option at all, so GETOPT reports it bad "
                "and mkdir.s takes the :usage exit-2 path before "
                "ever reaching a dir operand. BSD mkdir -m 755 "
                "creates the directory with that mode and exits 0."),

    # ==================================================================
    # pwd -- XCU pwd.html (no host analogue: ProDOS paths, not host cwd)
    # ==================================================================
    C('pwd', 'prints the working directory',
      '"%s\\n", <directory pathname>',
      [],
      # every case's run_case() `cd`s into its own /mnt/MAUX/PXUT/<K-tag>
      # base directory first (so FILE operands can be typed as the
      # SAME bare relative name on both sides -- see command_line()'s
      # docstring); pwd's own expectation must follow that cd rather
      # than assume the boot-time root, so `hand` is a CALLABLE taking
      # the case's `base` and returning the expectation for THIS run.
      hand=lambda base: dict(
          stdout=[base + '/'], rc=0,
          reason="pwd prints a ProDOS prefix, which has no "
                 "relationship to the host's own cwd -- there is no "
                 "host argv this could possibly share. ProDOS "
                 "prefixes are absolute with a trailing slash "
                 "(structural fact, not a maux-run capture, and the "
                 "same convention independently pinned by scripts/"
                 "build_v1_system_image.py's EXPECT_PWD1 and check_"
                 "play.py's own PWD case); the expected VALUE is this "
                 "harness's own per-case /mnt/MAUX/PXUT/<K-tag> "
                 "directory, since run_case() cd's into it before "
                 "typing any measured command, pwd included.")),

    # ==================================================================
    # sleep -- XCU sleep.html
    # ==================================================================
    C('sleep', 'sleep 0 returns promptly, exit 0',
      'The execution was successfully suspended for at least time '
      'seconds... 0.',
      ['0']),
    C('sleep', 'sleep 1 completes, exit 0',
      'The execution was successfully suspended for at least time '
      'seconds...',
      ['1']),
    C('sleep', 'a non-numeric operand is an error',
      '>0 An error occurred.',
      [Q('abc')]),

    # ==================================================================
    # true / false -- XCU true.html, false.html
    # ==================================================================
    C('true', 'returns exit code zero',
      'The true utility shall return with exit code zero.', []),
    C('true', 'ignores operands',
      'OPERANDS -- None.', ['ignored', 'args']),
    C('false', 'returns a non-zero exit code',
      'The false utility shall return with a non-zero exit code.', []),
    C('false', 'ignores operands',
      'OPERANDS -- None.', ['ignored', 'args']),
]

# posixutil_cases2.py: wc, tail, uniq, tr, sort, od, find, diff, ls, cp,
# mv, rm, date, touch, du, tee, echo(binary), kill -- a SEPARATE module
# (not folded into the CASES table above) so this file does not grow
# past what one person edits comfortably; the two files share exactly
# the C()-produced dict shape and the same CASES/KNOWN_GAPS scoring
# contract (module docstring there has the per-tool method notes).
import posixutil_cases2 as PC2                            # noqa: E402
CASES += PC2.CASES2

# posixutil_cases3.py: `test`/`[` (src/bin/testeval.s) -- round 3,
# same reason as round 2: one gate, one summary line, unchanged
# format, kept separate so no single file grows past a comfortable
# edit. See that module's own docstring for its METHOD notes.
import posixutil_cases3 as PC3                            # noqa: E402
CASES += PC3.CASES3

# posixutil_cases4.py: `patch` (src/bin/patch.s and its six body
# modules) plus the one `diff` row that feeds maux's own `diff -u`
# output into it -- round 4, same reason as rounds 2 and 3. See that
# module's own docstring for why every patch row is hand-authored
# (BSD and GNU patch disagree, word for word, on the progress text
# they write to stdout) and where its expected file contents came
# from.
import posixutil_cases4 as PC4                            # noqa: E402
CASES += PC4.CASES4

# posixutil_cases5.py: `make` (src/bin/make.s + makeread/makemac/
# makeinf/makerun.s) -- round 5, the macro, inference-rule, internal-
# macro and option work of docs/MAKE-POSIX.md. Same reason as rounds
# 2-4 for the separate module. Its rows are almost all `make -n`,
# which is what lets a fixture naming a nonexistent command run
# unchanged against this host's own make.
import posixutil_cases5 as PC5                            # noqa: E402
CASES += PC5.CASES5

# posixutil_cases6.py + posixutil_interactive.py: the INTERACTIVE row
# kind (a `script` of wait/type/append steps run against a program that
# does not simply exit -- tail -f, xargs -p, find -ok) and the rows it
# unblocks. docs/POSIX-HARNESS.md. The machinery is in the second
# module; this file only dispatches to it (_host_once, run_case,
# process_batch, main: each marked "interactive").
import posixutil_interactive as PI                        # noqa: E402
import posixutil_cases6 as PC6                            # noqa: E402
CASES += PC6.CASES6

KNOWN_GAPS = [(c['tool'], c['name'], c['known_gap'])
              for c in CASES if c['known_gap']]
assert len(PC2.KNOWN_GAPS2) == len([c for c in PC2.CASES2
                                     if c['known_gap']]), \
    'posixutil_cases2.KNOWN_GAPS2 must list exactly the CASES2 rows ' \
    'that carry known_gap= -- see that module\'s own KNOWN_GAPS2'
assert len(PC3.KNOWN_GAPS3) == len([c for c in PC3.CASES3
                                     if c['known_gap']]), \
    'posixutil_cases3.KNOWN_GAPS3 must list exactly the CASES3 rows ' \
    'that carry known_gap= -- see that module\'s own KNOWN_GAPS3'
assert len(PC4.KNOWN_GAPS4) == len([c for c in PC4.CASES4
                                     if c['known_gap']]), \
    'posixutil_cases4.KNOWN_GAPS4 must list exactly the CASES4 rows ' \
    'that carry known_gap= -- see that module\'s own KNOWN_GAPS4'
assert len(PC5.KNOWN_GAPS5) == len([c for c in PC5.CASES5
                                     if c['known_gap']]), \
    'posixutil_cases5.KNOWN_GAPS5 must list exactly the CASES5 rows ' \
    'that carry known_gap= -- see that module\'s own KNOWN_GAPS5'
assert len(PC6.KNOWN_GAPS6) == len([c for c in PC6.CASES6
                                     if c['known_gap']]), \
    'posixutil_cases6.KNOWN_GAPS6 must list exactly the CASES6 rows ' \
    'that carry known_gap= -- see that module\'s own KNOWN_GAPS6'
# A norm= that names nothing would silently compare every byte (the
# .get() fallback is the identity), i.e. it would LOOK stricter than
# it is and fail for the wrong reason. The case modules cannot import
# NORMALIZERS without a circular import, so the name is validated
# here, once, over every row from every module.
for _c in CASES:
    assert _c.get('norm') is None or _c['norm'] in NORMALIZERS, \
        f'{_c["tool"]}/{_c["name"]}: unknown norm {_c["norm"]!r} -- ' \
        f'add it to NORMALIZERS with its own reason'


# ======================================================================
# tag <-> path mapping
# ======================================================================
def maux_mapping(casetag, case):
    base = f'{SUBDIR}/{casetag}'
    m = {}
    for tag in case['files']:
        m[tag] = f'{base}/{tag}'
    for tag, rel in case['dirs'].items():
        m[tag] = f'{base}/{rel}'
    return base, m


def host_mapping(case):
    m = {}
    for tag in case['files']:
        m[tag] = tag
    for tag, rel in case['dirs'].items():
        m[tag] = rel
    return m


def unquote(word):
    if len(word) >= 2 and word[0] == "'" and word[-1] == "'":
        return word[1:-1]
    # DOUBLE quotes too (posixutil_cases2.QQ()): printf's own format
    # strings carry a backslash that this sh does not treat as fully
    # literal inside SINGLE quotes (found 2026-09-14, landing printf
    # -- verified live on the emulator, not fixed here) -- double
    # quotes side-step it. Safe to add unconditionally: nothing else
    # in this tree hands a double-quoted word through this path yet.
    if len(word) >= 2 and word[0] == '"' and word[-1] == '"':
        return word[1:-1]
    return word


# ======================================================================
# host oracle
# ======================================================================
def _host_once(case):
    workdir = tempfile.mkdtemp(dir=SCRATCH)
    try:
        m = host_mapping(case)
        for tag, lines in case['files'].items():
            if lines is None:
                continue
            path = os.path.join(workdir, m[tag])
            d = os.path.dirname(path)
            if d:
                os.makedirs(d, exist_ok=True)
            if isinstance(lines, bytes):         # byte fixture: verbatim
                with open(path, 'wb') as f:
                    f.write(lines)
                continue
            with open(path, 'w') as f:
                f.write(''.join(ln + '\n' for ln in lines))
        for tag in case['predirs']:
            os.makedirs(os.path.join(workdir, m[tag]), exist_ok=True)

        argv = [HOST_BIN[case['tool']]] + \
            [unquote(w) for w in render(case['argv'], m)]
        # ALWAYS give the child a concrete stdin (default empty) --
        # never let it inherit this script's own stdin, which would
        # either hang or read garbage for a case like cat's bare '-'
        # operand that reads real stdin with no operand staged for it.
        if case.get('script') is not None:       # interactive
            out = os.path.join(workdir, 'OUT') if case['redirect'] else None
            ir = PI.host_run(
                argv, case['script'], workdir,
                stdin_path=(os.path.join(workdir, m[case['stdin']])
                            if case['stdin'] else None),
                stdout_path=out)
            if out is not None:
                with open(out) as f:
                    ir['stdout'] = host_lines(f.read())
            return {'stdout': ir['stdout'], 'rc': ir['rc'], 'files': {}}
        stdin_data = ''
        if case['stdin']:
            with open(os.path.join(workdir, m[case['stdin']])) as f:
                stdin_data = f.read()
        env = dict(os.environ, LC_ALL='C')
        r = subprocess.run(argv, cwd=workdir, input=stdin_data,
                            capture_output=True, text=True, timeout=15,
                            env=env)
        files = {}
        for tag in case['results']:
            path = os.path.join(workdir, m.get(tag, tag))
            files[tag] = host_lines(open(path).read()) \
                if os.path.exists(path) else None
        return {'stdout': host_lines(r.stdout), 'rc': r.returncode,
                'files': files}
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def oracle(case, base=None):
    if case['hand'] is not None:
        h = case['hand'](base) if callable(case['hand']) else case['hand']
        # `contains` is an escape hatch for hand= rows whose full stdout
        # is a rendered man(1) page (mandoc bold-overstrike byte-for-
        # byte reproduction was already judged not worth it -- see the
        # MAN_CASES header) -- it checks a fragment is present in some
        # line of stdout instead of demanding exact line-for-line
        # equality. 'stdout' is not required when 'contains' is given.
        return {'stdout': h.get('stdout'), 'rc': h['rc'],
                'files': h.get('files', {}),
                'contains': h.get('contains')}
    a = _host_once(case)
    b = _host_once(case)
    # The stability check has to ignore exactly what the COMPARISON
    # ignores, or an unspecified field is only half-honoured: GNU diff
    # stamps its -u/-c header with NANOSECONDS, so two runs a
    # microsecond apart are textually different and every such row
    # died here as "oracle UNSTABLE" before its normalizer was ever
    # reached. BSD's stamp has one-second resolution, so the Mac never
    # saw it and the box did (2026-09-17, first box run of these rows).
    nf = NORMALIZERS.get(case.get('norm'), lambda x: x)
    if _normed(a, nf) != _normed(b, nf):
        raise RuntimeError(f'oracle UNSTABLE across two runs: '
                            f'{a!r} != {b!r}')
    return a


def _normed(res, nf):
    """A run's result with `nf` applied to stdout and to every named
    result file -- the same shape main() compares."""
    return {'stdout': nf(res['stdout']), 'rc': res['rc'],
            'files': {k: (nf(v) if v is not None else None)
                      for k, v in res['files'].items()}}


# ======================================================================
# maux side
# ======================================================================
# a2til's prodos.mount()/unmount() keep ONE process-global registry
# keyed by volume name, and every image here is named BASIC: two boot
# groups staging at once (POSIXUTIL_JOBS > 1) collided on it --
# "a volume named 'BASIC' is already mounted" / "Device is 8192 units,
# so no unit N" -- as soon as a group's staging took long enough to
# overlap another's (2026-10-08: the diff -r rows stage 100-720 files
# apiece). Staging is one lock; the emulator runs stay parallel.
_STAGE_LOCK = threading.Lock()


def stage_batch(img, batch, casetags):
    with _STAGE_LOCK:
        _stage_batch(img, batch, casetags)


def _stage_batch(img, batch, casetags):
    prodos.mount(img)
    try:
        try:
            prodos.mkdir(SUBDIR)
        except Exception:
            pass
        for casetag, case in zip(casetags, batch):
            base, m = maux_mapping(casetag, case)
            prodos.mkdir(base)
            # predirs FIRST, files second: find's cases stage FILES
            # inside a pre-built subdirectory (a 'files' tag containing
            # '/', e.g. 'TREE/SUB/A.TXT') -- the old order (files then
            # predirs) wrote into a directory that did not exist yet
            # for any tool that needed one. Every existing mkdir.py
            # case is unaffected: its own files dict is always empty.
            for tag in case['predirs']:
                rel = case['dirs'][tag]
                cur = base
                for part in rel.split('/'):
                    cur = f'{cur}/{part}'
                    try:
                        prodos.mkdir(cur)
                    except Exception:
                        pass
            for tag, lines in case['files'].items():
                if lines is None:
                    continue
                # A `bytes` value is staged RAW: a FOREIGN-polarity
                # file (low ASCII, $0D) for a hand= row, which never
                # reaches the host oracle. Every other value is a
                # list of lines and gets maux's own high-bit shape.
                data = lines if isinstance(lines, (bytes, bytearray)) \
                    else hilines(lines)
                prodos.write(m[tag], data, file_type=0x04,
                             aux_type=0x0000, overwrite=True)
    finally:
        try:
            prodos.unmount('MAUX')
        except Exception:
            pass


def boot(client, img, reset_extra=None):
    params = {'backend': 'fast', 'aux': 'ramworks'}
    params.update(reset_extra or {})
    r = client.call_tool('reset', params)
    if not r.get('ok'):
        raise RuntimeError(f'reset failed: {r}')
    r = client.call_tool('mount_disk', {'path': img, 'unit': 1})
    if r.get('ok') is False:
        raise RuntimeError(f'mount_disk failed: {r}')
    V.settle(client, V._at_prompt, 'shell prompt after boot',
             max_steps=3000)


def command_line(case):
    """The measured line, typed AFTER a `cd` into the case's own base
    directory -- so every FILE/DIR operand is the SAME bare relative
    name typed on the host side (host_mapping()), never the full
    /mnt/MAUX/PXUT/<tag>/... path. This matters for real output, not just
    hygiene: head's multi-file '==> NAME <==' headers and grep's
    FILE: prefixes print the operand AS TYPED, so a full-path operand
    would never byte-match a host oracle that only ever sees a bare
    relative name in its own scratch cwd."""
    m = host_mapping(case)
    words = [MAUX_BIN[case['tool']]] + render(case['argv'], m)
    if case['stdin']:
        words += ['<', m[case['stdin']]]
    if case.get('script') is None or case['redirect']:
        words += ['>', 'OUT']
    if case.get('script') is not None:           # interactive
        return PI.command_prefix(case) + ' '.join(words)
    return ' '.join(words)


def post_lines(case):
    m = host_mapping(case)
    out = []
    for words in case['post']:
        out.append(' '.join(render(words, m)))
    return out


def run_case(client, casetag, case):
    base, _ = maux_mapping(casetag, case)
    V.t(client, f'cd {base}\r')
    V.settle(client, V._at_prompt, f'{casetag} cd', max_steps=400)
    V.t(client, command_line(case) + '\r')
    if case.get('script') is not None:           # interactive
        PI.play(client, casetag, command_line(case), case, V)
    else:
        V.settle(client, V._at_prompt, f'{casetag} finished',
                 max_steps=2500)
    V.t(client, 'echo $? > OUTX\r')
    V.settle(client, V._at_prompt, f'{casetag} status captured',
             max_steps=400)
    for line in post_lines(case):
        V.t(client, line + '\r')
        V.settle(client, V._at_prompt, f'{casetag} post step',
                 max_steps=1500)


def recover(client):
    V.t(client, '\x03')
    V.settle(client, V._at_prompt, 'recovered to prompt', max_steps=400)


def batch_reset_extra(batch):
    """Every case in a boot group must agree on its `reset` override
    (main()'s batching already splits a group rather than mix two --
    this is the safety net, not the mechanism)."""
    extras = [c['reset'] for c in batch if c['reset'] is not None]
    if not extras:
        return None
    first = extras[0]
    for e in extras[1:]:
        if e != first:
            raise RuntimeError(
                f'batch mixes incompatible reset overrides: {first!r} '
                f'vs {e!r} -- main() should have split this group')
    return first


def process_batch(env, batch, idx):
    casetags = [f'K{idx * 100 + i:03d}' for i in range(len(batch))]
    img = os.path.join(SCRATCH, f'grp_{idx}.po')
    shutil.copy(DISK, img)
    MADE.append(img)
    with PI.STAGE_LOCK:                  # a2til's mount table is global
        stage_batch(img, batch, casetags)

    client = MCPClient([SUPERVISOR], env)
    harness_err = {}
    try:
        boot(client, img, batch_reset_extra(batch))
        for casetag, case in zip(casetags, batch):
            try:
                run_case(client, casetag, case)
            except Exception as e:  # noqa: BLE001
                harness_err[casetag] = f'{type(e).__name__}: {e}'
                try:
                    recover(client)
                except Exception:
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
    for casetag, case in zip(casetags, batch):
        base, m = maux_mapping(casetag, case)
        if casetag in harness_err:
            results.append((case, None, harness_err[casetag], base))
            continue
        if vol is None:
            results.append((case, None,
                             f'a2til open_image failed: {vol_err}',
                             base))
            continue
        try:
            got = {}
            live = PI.LIVE.get(casetag)          # interactive
            if live is not None and live['stdout'] is not None:
                got['stdout'] = live['stdout']
            else:
                got['stdout'] = maux_lines(
                    bytes(vol.read_file(f'{base}/OUT')))
            got['tty'] = live['tty'] if live is not None else None
            st = maux_lines(bytes(vol.read_file(f'{base}/OUTX')))
            got['rc'] = int(st[0]) if st and st[0].strip().isdigit() \
                else None
            got['files'] = {}
            for tag in case['results']:
                try:
                    got['files'][tag] = maux_lines(
                        bytes(vol.read_file(m[tag])))
                except Exception:
                    got['files'][tag] = None
            got['meta_equal'] = []
            for left, right, fields in case.get('meta_equal', []):
                def metapath(name):
                    return m.get(name, f'{base}/{name}')
                le = vol.entry_for(metapath(left))
                re = vol.entry_for(metapath(right))
                lv = tuple(getattr(le, field) for field in fields)
                rv = tuple(getattr(re, field) for field in fields)
                got['meta_equal'].append((left, right, fields, lv, rv))
            results.append((case, got, None, base))
        except Exception as e:  # noqa: BLE001
            results.append((case, None,
                             f'a2til read-back failed: '
                             f'{type(e).__name__}: {e}',
                             base))
    return results


def make_batches(cases, size):
    """Chunk `cases` into boot groups of at most `size`, but ALSO start
    a new group whenever `reset` changes -- date.s's clock:False cases
    (see C()'s own docstring) must never share a boot with a case that
    needs the default clock:True. A fixed-size slice of the plain list
    would silently mix them the day case ordering shifted."""
    batches = []
    cur = []
    cur_reset = None
    for c in cases:
        if cur and (len(cur) >= size or c['reset'] != cur_reset):
            batches.append(cur)
            cur = []
        if not cur:
            cur_reset = c['reset']
        cur.append(c)
    if cur:
        batches.append(cur)
    return batches


# ======================================================================
# main
# ======================================================================
def main():
    try:
        rc = run()
    except BaseException:
        SC.settle('check-posixutil', SCRATCH, MADE, False)
        raise
    SC.settle('check-posixutil', SCRATCH, MADE, rc == 0)
    return rc


def run():
    global DISK
    only = None
    argv = sys.argv[1:]
    if argv and argv[0].endswith('.po'):
        DISK = os.path.abspath(argv.pop(0))
    if argv:
        only = set(argv)
    if not os.path.exists(DISK):
        print(f'error: {DISK} not found -- run make play-image first',
              file=sys.stderr)
        return 2
    os.makedirs(SCRATCH, exist_ok=True)
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR

    cases = [c for c in CASES if only is None
             or c['tool'] in only or c['name'] in only]
    batches = make_batches(cases, BATCH)
    print(f'[check-posixutil] {len(cases)} cases ({len(KNOWN_GAPS)} '
          f'known gaps), {len(batches)} boot groups')

    # BOOT GROUPS IN PARALLEL (2026-09-15). process_batch() is
    # self-contained -- its own image copy (grp_<idx>.po), its own
    # supervisor+emulator over a private pipe, its own casetags -- so
    # the groups are independent; the emulator steps in cycles, not
    # wall clock, so results do not depend on how many run at once.
    # This gate was the longest item of the box sweep (83 s of a
    # 274 s run, all of it in the serial play.po lane). Rows are
    # collected in group order so the report reads as before.
    # POSIXUTIL_JOBS=1 gives the old serial run.
    from concurrent.futures import ThreadPoolExecutor
    jobs = max(1, int(os.environ.get('POSIXUTIL_JOBS', '4')))
    print(f'[check-posixutil] {jobs} boot group(s) in flight at once')

    def one_group(idx_batch):
        idx, batch = idx_batch
        print(f'[check-posixutil] group {idx + 1}/{len(batches)} '
              f'({len(batch)} cases)', flush=True)
        out = []
        for case, got, herr, base in process_batch(env, batch, idx):
            try:
                exp = oracle(case, base)
                oerr = None
            except Exception as e:  # noqa: BLE001
                exp = None
                oerr = f'{type(e).__name__}: {e}'
            out.append((case, got, herr, exp, oerr, base))
        return out

    rows = []  # (case, got, herr, exp, oerr, base)
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        for out in pool.map(one_group, list(enumerate(batches))):
            rows.extend(out)

    print()
    by_tool = {}
    for row in rows:
        by_tool.setdefault(row[0]['tool'], []).append(row)

    unexpected_fails = []
    gaps_that_now_pass = []
    tallies = {}
    for tool in sorted(by_tool):
        npass = 0
        ntotal = len(by_tool[tool])
        print(f'== {tool} ({ntotal} cases) ==')
        for case, got, herr, exp, oerr, base in by_tool[tool]:
            diffs = []
            if herr:
                diffs.append(f'HARNESS: {herr}')
            elif oerr:
                diffs.append(f'ORACLE: {oerr}')
            else:
                # .get, not [] -- posixutil_cases3's own miniature C()
                # predates `norm` and does not emit the key at all, so
                # a subscript here is a KeyError on every row of that
                # module (found by the box, 2026-09-17: the local run
                # had only ever been given `diff`/`patch` to filter to).
                nf = NORMALIZERS.get(case.get('norm'), lambda x: x)
                frag = exp.get('contains')
                if frag is not None:
                    if not any(frag in ln for ln in got['stdout']):
                        diffs.append(f'stdout does not contain '
                                     f'{frag!r}: got={got["stdout"]!r}')
                elif nf(got['stdout']) != nf(exp['stdout']):
                    diffs.append(f'stdout expected={exp["stdout"]!r} '
                                 f'got={got["stdout"]!r}')
                if got['rc'] != exp['rc']:
                    diffs.append(f'exit expected={exp["rc"]} '
                                 f'got={got["rc"]}')
                diffs += PI.extra_diffs(case, got)   # interactive
                for tag in case['results']:
                    e = exp['files'].get(tag)
                    g = got['files'].get(tag)
                    if e is not None:
                        e = nf(e)
                    if g is not None:
                        g = nf(g)
                    if e != g:
                        diffs.append(f'file[{tag}] expected={e!r} '
                                     f'got={g!r}')
                for left, right, fields, lv, rv in \
                        got.get('meta_equal', []):
                    if lv != rv:
                        diffs.append(f'metadata {left}/{right} fields '
                                     f'{fields!r}: {lv!r} != {rv!r}')
            comparison_matched = not diffs
            if case['known_gap']:
                status = 'GAP ' if not comparison_matched else 'BAD!'
                if comparison_matched:
                    gaps_that_now_pass.append(
                        (tool, case['name'], case['known_gap']))
                else:
                    npass += 1  # a gap staying red is the PASSING state
            else:
                status = 'PASS' if comparison_matched else 'FAIL'
                if comparison_matched:
                    npass += 1
                else:
                    unexpected_fails.append(
                        (tool, case['name'], case['spec'], diffs))
            print(f'  {status} {case["name"]} -- {case["spec"]}')
            if diffs and not case['known_gap']:
                for d in diffs:
                    print(f'       {d}')
            if case['hand'] is not None:
                h = case['hand'](base) if callable(case['hand']) \
                    else case['hand']
                print(f'       hand-authored: {h["reason"]}')
            if case['known_gap']:
                print(f'       known gap: {case["known_gap"]}')
        tallies[tool] = (npass, ntotal)
        print()

    total_pass = sum(p for p, _ in tallies.values())
    total_all = sum(t for _, t in tallies.values())
    print('[check-posixutil] per-tool tallies:')
    for tool in sorted(tallies):
        p, t = tallies[tool]
        print(f'  {tool}: {p}/{t}')
    print(f'[check-posixutil] TOTAL {total_pass}/{total_all} '
          f'({len(KNOWN_GAPS)} known gaps required to stay red)')

    print()
    print('[check-posixutil] KNOWN_GAPS:')
    for tool, name, reason in KNOWN_GAPS:
        print(f'  {tool}/{name}: {reason}')

    ok = True
    if unexpected_fails:
        ok = False
        print()
        print(f'[check-posixutil] FAIL: {len(unexpected_fails)} '
              f'non-gap case(s) diverged from the oracle:',
              file=sys.stderr)
        for tool, name, spec, diffs in unexpected_fails:
            print(f'  {tool}/{name} -- {spec}', file=sys.stderr)
            for d in diffs:
                print(f'    {d}', file=sys.stderr)
    if gaps_that_now_pass:
        ok = False
        print()
        print(f'[check-posixutil] FAIL: {len(gaps_that_now_pass)} '
              f'KNOWN_GAPS case(s) now PASS and must be retired from '
              f'the table:', file=sys.stderr)
        for tool, name, reason in gaps_that_now_pass:
            print(f'  {tool}/{name}: {reason}', file=sys.stderr)

    if not ok:
        return 1
    print()
    print(f'[check-posixutil] PASS: {total_pass}/{total_all} cases '
          f'conform, {len(KNOWN_GAPS)}/{len(KNOWN_GAPS)} known gaps '
          f'stayed red')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
