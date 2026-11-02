#!/usr/bin/env python3
"""check_encoding.py -- maux's text convention, declared in ONE place and
measured against the machine.

WHY THIS EXISTS. maux writes high-bit ASCII with $8D terminators and types
the file $04 -- "ASCII text file", which is seven bits with $0D. That is a
maux RULING (docs/a2/B.SH.TXT, "INPUT ENCODING"), and every justification it
gives is about the KEYBOARD LATCH, the DISPLAY PAGE and Merlin's `asc`
directive: real Apple II facts about hardware registers and one assembler,
none of them a fact about what a $04 file contains. Classic Apple II SOURCE
is high-bit; ProDOS TXT is not; EDASM -- Apple's own assembler -- requires
MSB=0. The two got conflated, repeatedly, in prose and in shipped code.

THE RULING (operator, 2026-09-21): host source is Unix semantics, a2til
translates to ProDOS semantics, and tools should not care what arrives but
should emit the right thing. a2til already defines the target --
`convert.text_from_host()` normalises every line ending to CR and does NOT
set bit 7 -- ProDOS-standard text, what nas reads. high_bit=True
does the same line-ending normalisation and then ORs $80 over EVERY
byte including the CR: $8D-terminated high-bit text, which is exactly
maux's own convention (make, sh, vi), not only DOS 3.3's.

WHY A GATE BEFORE ANY OF THE WORK. Nothing in this tree can currently SEE an
encoding. check_posixsed.maux_lines() does `bytes(b & 0x7F ...)` and splits
on `\r`, so every differential comparison -- all 565 conforming POSIX cases
-- is measured MODULO THE HIGH BIT. A half-finished migration, some tools
flipped and some not, writing volumes of mixed encoding, passes the entire
suite green. On a change that touches this many sites that is the difference
between a bad afternoon and a corrupted volume.

WHAT IT CHECKS

 1. THE MACHINE, not the source: boot, have the shell write a text file,
    read the RAW bytes back from the host, and assert they match the
    DECLARED convention -- byte polarity and line terminator both. This is
    what stops the declaration below from drifting away from reality, which
    is exactly how the original conflation survived.

 2. THE SOURCE, as a shrink-only ratchet. Counting high-bit string literals
    and high-bit character immediates gives the migration a number that can
    only go down. Today's counts are pinned; the flip drives them to zero.
    A count that GROWS fails: new code must not add to the debt.

 3. THE STAGING. build_play_image.py hand-rolls `| 0x80` where a2til's own
    text_from_host() is the house answer -- the "knowing a house tool exists
    is not knowing what it does" trap, on the same tool that has caught this
    project before. Pinned with a named trigger rather than silently
    tolerated.

The self-test at the end plants each failure and requires it to be caught,
the same shape check_ascii.py uses.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_vi as V                                      # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR     # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos                                  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

# ---------------------------------------------------------------------------
# THE DECLARATION. One place. Flipping these two values IS the migration's
# switch, and case 1 below re-measures the machine against them, so they
# cannot quietly disagree with what maux actually writes.
# ---------------------------------------------------------------------------
HIGH_BIT = True          #: bit 7 set on text bytes?  target: False
TERMINATOR = 0x8D        #: end of line.              target: 0x0D

#: RAISED +10 literals (1481 -> 1491), loop device S2-S4 (2026-10-11,
#: docs/LOOP-S2-NOTES.md sec 7): ten console texts printed through
#: PUTS, which takes high-bit text, none of them removable -- mount's
#: ": densified " / " blocks" and the `-r` operand compared against
#: the shell's high-bit argv, mntcom's "disk full", umount's "blocks
#: were not written", and bye's "loop device:" prefix, "error $" and
#: the four reasons a re-attach can fail with. Reused where they
#: could be (the program name and ": " come from mntcom). IMMEDIATES
#: did not move: the unit/name bytes are named constants. Raised, not
#: contorted, per the pins above; the architect may prefer otherwise.
#: RAISED +7 literals (1474 -> 1481) and +6 immediates (1364 -> 1370),
#: loop device S1 (2026-10-10, docs/LOOP-S1-NOTES.md): mount.s's six
#: new refusal reasons (mntcom.s: no such file, sparse image, 2IMG,
#: not a tree file, no free slot, write-protected) and bye.s's "a loop
#: device is attached" print through PUTS, which takes high-bit text;
#: the immediates are mount.s's '/' ('/'+$80) and '?' name bytes and
#: its $B0/$AF compare values, which are console-text or unit
#: constants, not debt.
#: Shrink-only. Counted over tracked *.s; a rise fails. Target for both: 0.
#: RAISED 1356 -> 1359, bye slice 1 (2026-09-25): src/bin/bye.s's
#: LEAVEMSG/BACKMSG/USAGEMSG, three new user-facing console
#: messages a program that suspends the machine genuinely has to
#: print -- real, deliberate, unavoidable growth (this task's
#: OTHER five new high-bit immediates in procbye.s/byeres.s/
#: timer.s were address/count/bitmask values, not text, and are
#: now named constants instead -- IMMEDIATES_MAX did not move).
#: RAISED 1359 -> 1369, bye slice 2 (2026-09-27): src/bin/bye.s's
#: TYPEMSG/BIGMSG/OPENMSG/PINMSG1/PINMSG2/RAWMSG1/RAWMSG2 (seven
#: new refusal/error messages the userland launch genuinely has
#: to print) plus src/test/byetenant.s's own "NO SYSNAME"/"TENANT
#: RAN" (the launch's own worked-example tenant, printing through
#: real ProDOS COUT, not maux's console) -- again real, deliberate
#: text, not debt this ratchet is meant to catch. This round's OWN
#: nine new high-bit IMMEDIATES (byelaunch.s's five MLI command/
#: bitmap/vector bytes, byetenant.s's stack-reset $FF, bye.s's
#: file-type check) were, again, address/command/bitmask values,
#: not text, and are named constants now (MLI_SETPFX/MLI_OPEN/
#: MLI_READ/MLI_CLOSE/BMP_PAGES01/COUT1_LO/COUT1_HI/INV_NORMAL in
#: byelaunch.s, STACKTOP in byetenant.s, FTYPE_SYS -- already
#: named, inc/mli.equ -- in bye.s) -- IMMEDIATES_MAX did not move.
#: RAISED 1369 -> 1395, sh alias/unalias/hash/fc (2026-10-07):
#: src/bin/shalias.s's eleven console diagnostics and shsgali.s's
#: name/keyword compare strings (ALIAS, UNALIAS, HASH, FC, the
#: command-position keywords) -- text sh's own high-bit command line
#: is compared against, so they must match its encoding. Its high-bit
#: immediates were named (ALC_xx in sh.s) and IMMEDIATES_MAX did not
#: move.
#: RAISED +6 literals (1395 -> 1401) and +8 immediates (1320 -> 1328), du/df (2026-10-07,
#: docs/DU-DF-NOTES.md): df's -P header, its usage/diagnostic strings
#: and the '%'/space/CR PUTC immediates print through PUTS/PUTC, which
#: take high-bit text -- real output text, not debt. They replace
#: df's old note strings and du's no-cwd message only in part.
#: RAISED +29 literals (1401 -> 1430) and +4 immediates (1328 -> 1332),
#: ex command names (2026-10-08, docs/EX-BADCMD-NOTES.md): src/bin/
#: exname.s's 26 table names are compared byte for byte against ex's
#: own high-bit command line, and its two refusal messages and vi's
#: "Command failed" print through PUTS -- text in the editor's native
#: encoding, not debt. The four immediates (k = # compared with the
#: command line's first byte) are the same.
#: RAISED +9 literals (1401 -> 1410) and +6 immediates (1328 -> 1334),
#: tail -f / xargs -0 -p / find -ok -depth (2026-10-08, docs/POSIX-HARNESS-
#: NOTES.md): the -ok prompt pieces, the -depth/-ok flag words, tail's and
#: xargs's usage/diagnostic strings and option-letter tables, and "?..." --
#: console text and getopt letters compared against the shell's own
#: high-bit argv. The six immediates are option letters (f, p, 0), the
#: space PUTC and the Y of a reply, same shape as df's above.
#: RAISED +6 literals (1401 -> 1407) and +17 immediates (1328 -> 1345), pr column
#: engine (2026-10-08, docs/POSIX-PR-NOTES.md): the usage line and the five
#: limit diagnostics are stderr text printed through PUTS, and the
#: $A0/$8D/$89/$8C/$AD immediates are the space/CR/tab/FF/dash PUTC and
#: compare bytes of the output stream itself -- output text, not debt.
#: RAISED +14 literals (1401 -> 1415), diff -r (2026-10-08,
#: docs/POSIX-DIFFR-NOTES.md): src/bin/diffrec.s's thirteen output
#: strings (Only in / Common subdirectories / File ... is a ... while
#: file / the `diff` header / two refusals) and the usage line's
#: second half. All print through PUTS, which takes high-bit text --
#: real output, not debt. The one '/' immediate is named DSLASH, so
#: IMMEDIATES_MAX did not move.
#: RE-PINNED at the 2026-10-09 integration of the eight streams above
#: (ex-badcmd, posix-harness, posix-pr, posix-regexlink, posix-diffr,
#: posix-sortk, posix-odt, kspace): each raised the same base pin
#: (1401/1328) on its own; the integrated tree measures 1459/1355, which
#: is exactly the sum of the raises each note declares (+29+9+6+14 /
#: +4+6+17). Nothing undeclared rode in.
#: RAISED +15 literals (1459 -> 1474) and +9 immediates (1355 -> 1364),
#: virtual root (2026-10-10, docs/VROOT-NOTES.md): mount.s/umount.s/
#: mntcom.s print their usage and diagnostics through PUTS (+13 literals,
#: +5 immediates for the option letters and the `y` of a unit digit);
#: the play/sticky/fileproc test bodies grew two literals and four
#: immediates for the new /mnt paths; kdevblk.s compares the two
#: high-bit user bytes of "/mnt"; realpath.s stores the high-bit "/"
#: ($AF) of the virtual root; df.s lost three immediates to the
#: readdir rewrite. Output text and user-byte compares, not debt.
#: RAISED +1 literal (1491 -> 1492), mount's "/bin" (2026-10-11, the
#: listing sort: PHYS of "/bin" names the boot volume) -- a path the
#: kernel compares against its own high-bit table, not debt.
#: RAISED +14 literals (1492 -> 1506), KFIX3 (2026-10-17,
#: docs/KFIX3-NOTES.md): src/bin/shsgsig.s's V7 signal-name table (the
#: names a dead foreground job is announced by, one table for fg and bg;
#: its `Terminated` replaces the old TERM_STR) and ld's `@file` pair
#: (M_ARGF and the usage line's "or: ld @file"). All print through
#: PUTS / JOB_PUTS, which take high-bit text -- output text, not debt.
#: IMMEDIATES_MAX did not move: the new FILE-record bytes, '<', '&',
#: '@' and the argument-file word test are named (FREC_*, OPC_LT,
#: OPC_AMP, ARGF_AT, ARGF_WORD, ALC_A0).
#: RAISED +16 literals (1506 -> 1522), SH-PREFIX (2026-10-21,
#: docs/SH-PREFIX-NOTES.md): src/bin/shpfx.s's table of the thirteen
#: special-builtin names (STRCMPI'd against high-bit argv words) and its
#: "too many assignments" message, shlex.s's `-c` usage message, and
#: shbltn.s's TRUE_STR (the program a redirected `:` runs). Text the
#: shell compares or prints, not debt. IMMEDIATES_MAX did not move.
#: RAISED +1 literal (1522 -> 1523), examples round 1 (2026-10-28):
#: examples/lssys/ls.s's ERRTXT ("MLI ERROR"), a worked example's own
#: error message printed through real ProDOS COUT, which takes high-bit
#: text -- same case as src/test/byetenant.s above, real output text
#: rather than debt this ratchet is meant to catch. IMMEDIATES_MAX did
#: not move (it sits 8 BELOW its pin and is not re-pinned here, because
#: this branch did not touch it).
#: TIGHTENED 1364 -> 1357, the eight-branch landing (2026-10-28), which
#: is the first change since to touch the immediates at all: cmprpt.s
#: loses one to the 24-bit cmp counters (SH-DEFECTS 8) and edparse.s
#: gains two parsing `ex -s` as an option (SH-DEFECTS 14), net +1 over
#: main's 1356. The pin had been loose by 8 since whichever commit
#: removed them without re-pinning, so SEVEN new high-bit immediates
#: could have landed reading green -- the exact failure this file's own
#: header calls worse than no ratchet. Re-pinned to the measured count.
#: RAISED, PS-ARGS landing (2026-11-01): ps's `<defunct>` (V7's own
#: word) and the kernel-made markers `[init]` / `[idle]`, printed
#: through PUTS like every console text. Re-MEASURED after the merge
#: rather than added to the branch's own 1509, which was taken against
#: a 1506 main this tree left behind. IMMEDIATES_MAX did not move: ps's
#: four spaces became one PUTSP, paying for its '?' '(' ')' and
#: separator.
LITERALS_MAX = 1526      #: `asc "..."` and friends -- Merlin sets bit 7 on
                         #: a DOUBLE-quoted string and clears it on a single
IMMEDIATES_MAX = 1356    #: printable high-bit immediates, $A0-$FE
#: Both were first pinned at 271/1032 from a regex anchored `^\s+`, which
#: counts only the literals that carry NO label -- an undercount of nearly
#: 5x, since Merlin's normal style is `USAGEMSG    asc "..."`. The
#: self-test below planted a labelled line and caught it. A ratchet pinned
#: to a broken detector is worse than no ratchet: it reads green while the
#: thing it measures grows.

#: Scripts that still set bit 7 by hand instead of calling a2til's
#: convert.text_from_host(), which already implements BOTH conventions
#: (every line ending to CR; bit 7 untouched = ProDOS-standard text, or
#: high_bit=True = maux text, $8D lines). Shrink-only, like the source
#: pins. First written as a list naming ONE file -- build_play_image.py --
#: which would have let the other fifty pass unnoticed; a count derived
#: from the tree cannot be wrong about its own size that way.
STAGING_MAX = 51
STAGING_RE = re.compile(r'\|\s*0x80')

STR_DIRECTIVE = re.compile(r'^(?:\S+)?\s+(asc|dci|str|inv|fls|rev)\s+"',
                           re.I)
IMMEDIATE = re.compile(
    r'^(?:\S+)?\s+(?:cmp|lda|ldx|ldy)\s+#\$([89A-F][0-9A-F])\b', re.I)


#: Directories the no-git walk must skip: not tracked, but present in a
#: working tree and full of .s files that are nobody's debt.
WALK_SKIP = {'.git', 'build', 'vendor', 'evidence'}


def walk_asm(root):
    """Every *.s under `root`, minus the generated/vendored trees.

    Must agree with `git ls-files '*.s'`. It did not: this walked only
    `src/`, while the git path walks the whole tree, so the seven tracked
    .s files outside src/ (examples/*, docs/loop-s1-m1/*) were counted on
    a developer's Mac and INVISIBLE on the box -- which is where the sweep
    actually runs. A ratchet that counts 1523 in one place and 1522 in the
    other is not a ratchet; the weaker number is the one that governs, and
    a whole directory of assembly could take on encoding debt unseen.
    The self-test below pins the two paths together.
    """
    found = []
    for base, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d not in WALK_SKIP]
        found += [os.path.relpath(os.path.join(base, n), root)
                  for n in names if n.endswith('.s')]
    return sorted(found)


def tracked_asm():
    out = subprocess.run(['git', 'ls-files', '*.s'], cwd=ROOT,
                         capture_output=True, text=True)
    if out.returncode:                       # no .git (the box rsyncs)
        return walk_asm(ROOT)
    return sorted(out.stdout.split())


def count_source(paths):
    lits = imms = 0
    for rel in paths:
        try:
            fh = open(os.path.join(ROOT, rel), encoding='ascii',
                      errors='replace')
        except OSError:
            continue
        with fh:
            for line in fh:
                if STR_DIRECTIVE.match(line):
                    lits += 1
                    continue
                m = IMMEDIATE.match(line.split(';', 1)[0])
                if m and 0xA0 <= int(m.group(1), 16) <= 0xFE:
                    imms += 1
    return lits, imms


def describe(data):
    body = [b for b in data if b not in (TERMINATOR, 0x0D, 0x8D)]
    hi = all(b & 0x80 for b in body) if body else None
    return hi, data[-1] if data else None


def measure_machine():
    """Write a text file ON THE MACHINE and read its raw bytes back."""
    tmp = tempfile.mkdtemp(prefix='maux-enc-')
    disk = os.path.join(tmp, 'enc.po')
    shutil.copyfile(V.DISK, disk)
    c = MCPClient([SUPERVISOR],
                  dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR))
    try:
        c.initialize()
        if not c.call_tool('reset',
                           {'backend': 'fast', 'aux': 'ramworks'}).get('ok'):
            raise RuntimeError('reset failed')
        r = c.call_tool('mount_disk', {'path': disk, 'unit': 1})
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        def at(rows):
            nb = [x for x in rows if x.strip()]
            return bool(nb) and nb[-1].strip().endswith('$')

        V.settle(c, at, 'shell prompt', max_steps=3000)
        V.t(c, 'echo Hi1 > /mnt/MAUX/ENCPROBE\r')
        for _ in range(500):
            c.call_tool('step', {'cycles': 200_000})
            if at(V.rows(c)):
                break
        c.call_tool('eject_disk', {'unit': 1})
        prodos.mount(disk, replace=True, readonly=True)
        try:
            data = prodos.read('/mnt/MAUX/ENCPROBE')
            ftype = prodos.stat('/mnt/MAUX/ENCPROBE').type
        finally:
            prodos.unmount('MAUX')
        return data, ftype
    finally:
        c.close()
        shutil.rmtree(tmp, ignore_errors=True)


#: Tools that must process a file carrying PRODOS semantics -- low
#: ASCII with $0D -- exactly as a2til, `tip` and NuFX deliver one.
#: Each entry is (command, what its output must contain). A tool joins
#: this list when it is made polarity-blind; the list only GROWS.
#:
#: Measured 2026-09-21, before any of this work: `cat` displayed such a
#: file perfectly while `grep b` found NOTHING and `tr` passed the data
#: through untouched. maux could DISPLAY a ProDOS text file and not
#: PROCESS one -- and `cat`, the first thing anyone tries, is the tool
#: that works, so nothing warned them.
#: /mnt/MAUX/LOW  is the one-line fixture: `a1b2c3` + $0D.
#: /mnt/MAUX/LOWM is three lines with a delimiter -- `alpha:1`, `beta:2`,
#: /mnt/MAUX/LOWN is LOWM without its middle line, and /mnt/MAUX/LOWT holds
#: blank-separated pairs (`a b`, `b c`) -- so the tokenisers meet the
#: LOW twin of a space, $20, which no terminator predicate touches.
#: `gamma:3`, each + $0D. It is the harder fixture, and deliberately:
#: a tool can pass LOW by copying bytes through untouched, while LOWM
#: requires it to FIND the line breaks (a $0D its terminator test has
#: to accept) and, for `cut -d:`, to match a delimiter arriving from
#: argv in maux's encoding ($BA) against the file's own ($3A).
#:
#: Each entry is (command, kind, want). `rows` is the EXACT list of
#: non-empty rows the command must leave below its own echo; `fields`
#: is the same thing compared field-wise, for output whose column
#: padding is not worth pinning.
#:
#: EXACT, and that is the whole design of this list. It took two
#: tightenings to get there, each because a probe could not produce a
#: different answer:
#:
#:   1. The first draft asserted only that `one` appeared somewhere on
#:      screen after `cut -d: -f1`. A cut that never finds its delimiter
#:      satisfies that perfectly by echoing `one:1`. All fourteen cases
#:      passed before a line of cut was written.
#:
#:   2. The second asserted that SOME row equalled the answer. That
#:      still passed a deliberately sabotaged `tail -1`, which printed
#:      the whole file -- because the file's embedded $0D bytes reach
#:      the CONSOLE, and the console breaks lines on them. A tool that
#:      never found a line break renders as though it had. This is the
#:      same illusion that let `cat` look healthy while `grep` found
#:      nothing, and it is why row COUNT has to be pinned, not just row
#:      membership.
#:
#: Measured 2026-09-21, before any of this work: `cat` displayed such a
#: file perfectly while `grep b` found NOTHING and `tr` passed the data
#: through untouched. maux could DISPLAY a ProDOS text file and not
#: PROCESS one -- and `cat`, the first thing anyone tries, is the tool
#: that works, so nothing warned them.
FOREIGN_OK = [
    ('cat /mnt/MAUX/LOW', 'rows', ['a1b2c3']),
    ('grep b /mnt/MAUX/LOW', 'rows', ['a1b2c3']),
    ("tr '[:digit:]' '#' < /mnt/MAUX/LOW", 'rows', ['a#b#c#']),
    ('tr a-z A-Z < /mnt/MAUX/LOW', 'rows', ['A1B2C3']),
    ('wc -l < /mnt/MAUX/LOWM', 'rows', ['3']),
    ('head -1 /mnt/MAUX/LOWM', 'rows', ['alpha:1']),
    ('tail -1 /mnt/MAUX/LOWM', 'rows', ['gamma:3']),
    ('sort -r /mnt/MAUX/LOWM', 'rows', ['gamma:3', 'beta:2', 'alpha:1']),
    ('uniq /mnt/MAUX/LOWM', 'rows', ['alpha:1', 'beta:2', 'gamma:3']),
    ('nl /mnt/MAUX/LOWM', 'fields',
     [['1', 'alpha:1'], ['2', 'beta:2'], ['3', 'gamma:3']]),
    ('sed -n 2p /mnt/MAUX/LOWM', 'rows', ['beta:2']),
    ('expand /mnt/MAUX/LOWM', 'rows', ['alpha:1', 'beta:2', 'gamma:3']),
    ('fold -w 4 /mnt/MAUX/LOWM', 'rows',
     ['alph', 'a:1', 'beta', ':2', 'gamm', 'a:3']),
    ('cut -d: -f1 /mnt/MAUX/LOWM', 'rows', ['alpha', 'beta', 'gamma']),
    ('paste -s /mnt/MAUX/LOWM', 'fields',
     [['alpha:1', 'beta:2', 'gamma:3']]),
    ('more /mnt/MAUX/LOWM', 'rows', ['alpha:1', 'beta:2', 'gamma:3']),
    ('tsort /mnt/MAUX/LOWT', 'rows', ['a', 'b', 'c']),
    ('comm -12 /mnt/MAUX/LOWM /mnt/MAUX/LOWN', 'rows', ['alpha:1', 'gamma:3']),
    ('join -t: /mnt/MAUX/LOWM /mnt/MAUX/LOWN', 'rows',
     ['alpha:1:1', 'gamma:3:3']),
]

#: KNOWN-BROKEN: defects that are reproducible TODAY, recorded with the
#: EXACT broken rows they produce, so that fixing the tool turns this
#: gate red and forces the entry out (the census, scripts/encoding_census.txt,
#: requires one entry here per `gap known` line, and names the line to
#: reclassify). A ratchet that only records good news stops being read.
#: Each entry is (command, broken rows, census program).
KNOWN_BROKEN = [
    ('for w in $(cat /mnt/MAUX/LOWT); do echo "<$w>"; done',
     ['<a b', 'b c', '>'], 'sh', False),
]

#: And the OUTPUT must come back in the encoding it went in as, or a
#: filter run over a foreign file produces a MIXED one -- worse than
#: either convention, because nothing can read it whole. Measured
#: 2026-09-21: low in, low out; high in, high out.
FOREIGN_ROUNDTRIP = ('tr a-z A-Z', b'a1b2c3', b'A1B2C3')


def check_foreign():
    """Stage a file the way a2til does, then make the tools read it."""
    fails = []
    tmp = tempfile.mkdtemp(prefix='maux-foreign-')
    disk = os.path.join(tmp, 'foreign.po')
    shutil.copyfile(V.DISK, disk)
    from a2til import convert
    prodos.mount(disk, replace=True)
    try:
        body = convert.text_from_host(b'a1b2c3\n')
        prodos.write('/mnt/MAUX/LOW', body, file_type=0x04, aux_type=0,
                     overwrite=True)
        body3 = convert.text_from_host(b'alpha:1\nbeta:2\ngamma:3\n')
        prodos.write('/mnt/MAUX/LOWM', body3, file_type=0x04, aux_type=0,
                     overwrite=True)
        # LOWN is LOWM minus its middle line, for the two-file tools;
        # LOWT is blank-SEPARATED pairs, so it also exercises the low
        # twin of a space ($20) in a tokeniser, not just a terminator.
        prodos.write('/mnt/MAUX/LOWN',
                     convert.text_from_host(b'alpha:1\ngamma:3\n'),
                     file_type=0x04, aux_type=0, overwrite=True)
        prodos.write('/mnt/MAUX/LOWT',
                     convert.text_from_host(b'a b\nb c\n'),
                     file_type=0x04, aux_type=0, overwrite=True)
    finally:
        prodos.unmount('MAUX')
    if body3 != b'alpha:1\x0dbeta:2\x0dgamma:3\x0d':
        fails.append(f'a2til staged {body3.hex()} for the 3-line fixture '
                     f'-- this gate assumes text_from_host() gives low '
                     f'ASCII with $0D')
    if body != b'a1b2c3\x0d':
        fails.append(f'a2til staged {body.hex()} -- this gate assumes '
                     f'text_from_host() gives low ASCII with $0D')
    c = MCPClient([SUPERVISOR],
                  dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR))
    try:
        c.initialize()
        c.call_tool('reset', {'backend': 'fast', 'aux': 'ramworks'})
        r = c.call_tool('mount_disk', {'path': disk, 'unit': 1})
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        def at(rows):
            nb = [x for x in rows if x.strip()]
            return bool(nb) and nb[-1].strip().endswith('$')

        V.settle(c, at, 'shell prompt', max_steps=3000)
        # the polarity round trip, both directions
        cmd, src, want = FOREIGN_ROUNDTRIP
        V.t(c, f'{cmd} < /mnt/MAUX/LOW > /mnt/MAUX/RTLO\r')
        for _ in range(400):
            c.call_tool('step', {'cycles': 200_000})
            if at(V.rows(c)):
                break
        V.t(c, 'cut -d: -f1 /mnt/MAUX/LOWM > /mnt/MAUX/RTCUT\r')
        for _ in range(400):
            c.call_tool('step', {'cycles': 200_000})
            if at(V.rows(c)):
                break

        def below(rows, cmd):
            """The rows this command produced: everything under the LAST
            row carrying its echo, minus the prompt. Scanning the whole
            screen would let a row left by an EARLIER command satisfy
            this one."""
            i = -1
            for n, r in enumerate(rows):
                if cmd[:36] in r:
                    i = n
            if i < 0:
                return None                  # the echo scrolled away
            out = [r.strip() for r in rows[i + 1:]]
            return [r for r in out if r and r != '$' and not
                    r.endswith('$')]

        def below_raw(rows, cmd):
            """Like below(), but BLANK rows are kept: some defects (a
            tool appending its own terminator to a file that already
            had one) show only as an extra empty row."""
            i = -1
            for n, r in enumerate(rows):
                if cmd[:36] in r:
                    i = n
            if i < 0:
                return None
            out = [r.strip() for r in rows[i + 1:]]
            while out and (not out[-1] or out[-1].endswith('$')):
                if out[-1].endswith('$'):
                    out.pop()
                    break
                out.pop()
            return out

        def run_row(cmd, raw=False):
            V.t(c, cmd + '\r')
            # Run to the prompt, then require the screen to hold still
            # for two consecutive polls before reading it -- a snapshot
            # taken mid-scroll measures the scroll, not the output.
            got = None
            prev = object()
            for _ in range(400):
                c.call_tool('step', {'cycles': 200_000})
                rows = V.rows(c)
                if not at(rows):
                    continue
                now = (below_raw if raw else below)(rows, cmd)
                if now is not None and now == prev:
                    got = now
                    break
                prev = now
            return got

        # KNOWN-BROKEN: assert the FAILURE (see KNOWN_BROKEN). When the
        # tool is fixed the output stops matching and this goes red.
        # CONTROL for the blank-row-preserving measure: a byte pump must
        # show exactly three rows and no blank, or `more`'s extra blank
        # row below proves nothing about `more`.
        ctl = run_row('cat /mnt/MAUX/LOWM', True)
        if ctl != ['alpha:1', 'beta:2', 'gamma:3']:
            fails.append(f'raw-row control `cat /mnt/MAUX/LOWM` gave '
                         f'{ctl!r}; the KNOWN_BROKEN measure is vacuous')
        for cmd, broken, line, raw in KNOWN_BROKEN:
            got = run_row(cmd, raw)
            if got == broken:
                print(f'[check-encoding] KNOWN BROKEN (as recorded): '
                      f'`{cmd}` -> {got}')
            else:
                fails.append(
                    f'`{cmd}` no longer emits its recorded broken output '
                    f'{broken!r}; it emitted {got!r}. If the tool is '
                    f'FIXED: add a FOREIGN_OK row, delete this '
                    f'KNOWN_BROKEN entry, and reclassify `{line}` in '
                    f'scripts/encoding_census.txt from broken to covered.')

        for cmd, kind, want in FOREIGN_OK:
            got = run_row(cmd)
            if kind == 'fields':
                ok = got is not None and [r.split() for r in got] == want
            else:
                ok = got == want
            if not ok:
                fails.append(
                    f'`{cmd}` on a file carrying ProDOS semantics (low '
                    f'ASCII, $0D) emitted {got!r}, expected {kind} '
                    f'{want!r} -- and note a tool that never found a '
                    f'line break still RENDERS as several rows, because '
                    f"the console breaks on the file's own $0D")
            else:
                print(f'[check-encoding] foreign file: `{cmd}` -> {got}')

    finally:
        try:
            c.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        c.close()
    prodos.mount(disk, replace=True, readonly=True)
    try:
        # An OPEN QUESTION, measured and recorded rather than asserted.
        # `tr` is a byte pump, so it preserves the terminator it read and
        # the assertion below pins that. `cut` CONSTRUCTS its output
        # lines, so it terminates them with maux's own newline, $8D,
        # while the field bytes stay low -- measured 2026-09-21 as
        # 61 6c 70 68 61 8d, "alpha" in low ASCII with a high-bit CR.
        #
        # That is what a Unix tool does with a CRLF file (GNU cut keeps
        # the \r in the field and writes \n), so it is defensible, and
        # it is NOT pinned as a defect here. But it does mean a maux
        # filter does not round-trip a ProDOS text file byte-for-byte,
        # which matters for interop with GNO/ME and a2til. Nine tools
        # emit a hardcoded $8D -- cut, fold, nl, sort, comm, join,
        # tsort, paste, sed. Deciding it is a product call, not a gate
        # one; this prints the bytes so the decision has a number.
        try:
            probe = prodos.read('/mnt/MAUX/RTCUT')
            print(f'[check-encoding] OPEN: a CONSTRUCTING filter does not '
                  f'round-trip -- `cut -d: -f1` over a low-ASCII file '
                  f'wrote {probe.hex(" ")} (low content, $8D terminator)')
        except Exception as exc:
            print(f'[check-encoding] OPEN: cut wrote nothing: {exc}')
        out = prodos.read('/mnt/MAUX/RTLO')
    except Exception as exc:
        out = None
        fails.append(f'the round-trip output was not written: {exc}')
    finally:
        prodos.unmount('MAUX')
    if out is not None:
        _cmd, _src, want = FOREIGN_ROUNDTRIP
        expect = want + b'\x0d'
        if out != expect:
            fails.append(
                f'`{_cmd}` over a low-ASCII file wrote {out.hex(" ")}, '
                f'expected {expect.hex(" ")} -- a filter must emit the '
                f'encoding it was given, or it produces a MIXED file')
        else:
            print(f'[check-encoding] foreign file: output follows input '
                  f'({out.hex(" ")} -- low ASCII in, low ASCII out)')
    shutil.rmtree(tmp, ignore_errors=True)
    return fails


def self_test():
    """Plant each condition and require the DETECTOR to catch it. Nothing
    here reads the tree: a self-test that measures the real data cannot
    tell a working detector from a tree that happens to be clean."""
    fails = []
    tmp = tempfile.mkdtemp(prefix='maux-enc-self-')
    try:
        # a high-bit literal and a high-bit immediate must be COUNTED,
        # their low-ASCII twins must not
        probe = os.path.join(tmp, 'probe.s')
        with open(probe, 'w', encoding='ascii') as fh:
            fh.write('MSG         asc   "high"\n'
                     "OK          asc   'low'\n"
                     '            cmp   #$E5\n'
                     "            cmp   #'e'\n"
                     '            cmp   #$8D        ;terminator, not a\n'
                     '            lda   #$C1        ;char\n')
        global ROOT
        real, ROOT = ROOT, tmp
        try:
            lits, imms = count_source(['probe.s'])
        finally:
            ROOT = real
        if lits != 1:
            fails.append(f'the literal detector counted {lits}, expected '
                         f'exactly the one double-quoted `asc`')
        if imms != 2:
            fails.append(f'the immediate detector counted {imms}, expected '
                         f'2 ($E5 and $C1 -- $8D is a terminator, below '
                         f'the $A0 printable floor, and must not count)')

        # the two file-set paths must agree. A planted tree with a .s
        # OUTSIDE src/ catches the walk that only descended into src/,
        # which is the defect this row exists for; the skipped dirs must
        # stay skipped in the same breath.
        for rel in ('src/kernel/a.s', 'examples/demo/b.s',
                    'docs/loop-s1-m1/c.s', 'build/gen.s',
                    'vendor/third/d.s'):
            full = os.path.join(tmp, rel)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, 'w', encoding='ascii') as fh:
                fh.write('            nop\n')
        walked = walk_asm(tmp)
        want = ['docs/loop-s1-m1/c.s', 'examples/demo/b.s', 'probe.s',
                'src/kernel/a.s']
        if walked != want:
            fails.append(f'the no-git walk returned {walked}, expected '
                         f'{want} -- it must see every tracked .s, not '
                         f'only src/, and must skip {sorted(WALK_SKIP)}')

        # the byte classifier
        hi, term = describe(bytes(b | 0x80 for b in b'Hi') + bytes([0x8D]))
        if hi is not True:
            fails.append('describe() did not classify high-bit text')
        hi, term = describe(b'Hi\x0d')
        if hi is not False:
            fails.append('describe() did not classify low-ASCII text')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # the declaration must be internally coherent: the terminator is the
    # SAME byte under the same polarity, which is the whole reason the
    # flip costs nothing at the line ending ($8D & $7F == $0D)
    if HIGH_BIT and TERMINATOR != 0x8D:
        fails.append(f'DECLARATION incoherent: high-bit text with '
                     f'terminator ${TERMINATOR:02X}')
    if not HIGH_BIT and TERMINATOR != 0x0D:
        fails.append(f'DECLARATION incoherent: low-ASCII text with '
                     f'terminator ${TERMINATOR:02X}')
    return fails


def main():
    if not os.path.exists(V.DISK):
        print('error: build/play.po missing -- run make play-image',
              file=sys.stderr)
        return 2
    failures = []
    paths = tracked_asm()

    failures += self_test()

    # 2. the source ratchet
    lits, imms = count_source(paths)
    if lits > LITERALS_MAX:
        failures.append(
            f'high-bit string literals rose to {lits} (pinned '
            f'{LITERALS_MAX}) -- new code must not add to the encoding '
            f'debt; use a single-quoted `asc` for low ASCII')
    if imms > IMMEDIATES_MAX:
        failures.append(
            f'high-bit character immediates rose to {imms} (pinned '
            f'{IMMEDIATES_MAX}) -- same rule')
    print(f'[check-encoding] source: {lits} high-bit string literal(s) '
          f'(pin {LITERALS_MAX}), {imms} high-bit character immediate(s) '
          f'(pin {IMMEDIATES_MAX}) over {len(paths)} tracked .s files')
    if lits < LITERALS_MAX or imms < IMMEDIATES_MAX:
        print(f'[check-encoding]   ... below the pin ({LITERALS_MAX}/'
              f'{IMMEDIATES_MAX}): re-pin in the same commit, the set '
              f'only shrinks')

    # 3. the staging debt, derived rather than listed
    staging = []
    sdir = os.path.join(ROOT, 'scripts')
    for name in sorted(os.listdir(sdir)):
        if not name.endswith('.py'):
            continue
        with open(os.path.join(sdir, name), encoding='ascii',
                  errors='replace') as fh:
            if STAGING_RE.search(fh.read()):
                staging.append(name)
    if len(staging) > STAGING_MAX:
        failures.append(
            f'{len(staging)} scripts set bit 7 by hand (pinned '
            f'{STAGING_MAX}) -- a new one appeared. a2til\'s '
            f'convert.text_from_host() is the house answer; see this '
            f'file\'s header')
    print(f'[check-encoding] staging: {len(staging)} script(s) still '
          f'encode by hand instead of calling a2til (pin {STAGING_MAX})')
    if len(staging) < STAGING_MAX:
        print(f'[check-encoding]   ... below the pin: re-pin in the same '
              f'commit, the set only shrinks')

    # 1b. a file from the OTHER convention
    failures += check_foreign()

    # 1. the machine itself
    data, ftype = measure_machine()
    hi, term = describe(data)
    want = 'high-bit' if HIGH_BIT else 'low ASCII'
    print(f'[check-encoding] machine: `echo Hi1 >` wrote '
          f'{data.hex(" ")} type=${ftype:02X}')
    if hi is None:
        failures.append('the probe file has no body bytes to classify')
    elif hi != HIGH_BIT:
        failures.append(
            f'maux wrote {"high-bit" if hi else "low ASCII"} text but the '
            f'DECLARATION at the top of this file says {want} -- one of '
            f'them is wrong, and the declaration is the one nothing else '
            f'can check')
    if term != TERMINATOR:
        failures.append(
            f'the line terminator is ${term:02X}, declared ${TERMINATOR:02X}')
    if ftype != 0x04:
        failures.append(f'the probe file is type ${ftype:02X}, not $04')
    if not failures:
        print(f'[check-encoding] machine agrees with the declaration: '
              f'{want}, terminator ${TERMINATOR:02X}, type $04')

    if failures:
        print()
        for f in failures:
            print(f'[check-encoding] FAIL: {f}', file=sys.stderr)
        return 1
    print()
    print(f'[check-encoding] PASS: the declared convention ({want}, '
          f'terminator ${TERMINATOR:02X}) is what the machine actually '
          f'writes; the source debt is {lits}+{imms} sites and shrink-only')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
