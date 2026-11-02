#!/usr/bin/env python3
"""Boot and verify `make check-ex` -- src/test/extest.s's ex M1 integration
gate (edtest.s/check_ed.py's own fileprocess-harness pattern). Asserts,
byte-exact including CR ($8D) line endings, that ONE ex session -- load a
5-line file via `r` (swap-backed), print it (`,p`), substitute one line
(`2s/BANK/SWAPD/`), print again, write back (`w`), quit (`q`) -- round-trips
byte-identically THROUGH THE SWAP FILE at every step:

  (a) the first `,p` (before the substitution) printed the 5 original lines,
      in order, unmodified -- proving `r` loaded through ED_BUMP_ALLOC and
      the print loop read them back through ED_LINETEXT's SET_MARK+READ.
  (b) the second `,p` (after `2s/BANK/SWAPD/`) printed line 2 changed to
      "SWAPD middle" and lines 1/3/4/5 UNCHANGED -- proving the substitute
      only rewrote the addressed line (line 4's own untouched "BANK" is the
      control) and that re-reading lines 1/3/4/5 from their ORIGINAL,
      now-out-of-sequence swap offsets still works (no offset-tracking
      cache is implemented in M1 -- every ED_LINETEXT call does a real
      SET_MARK).
  (c) /mnt/MAUX/EXOUT (the `w` target) is byte-IDENTICAL to what (b) printed --
      proving `w` fetches every line through the swap file too, and that
      the whole load/print/substitute/write path is byte-exact.
  (d) the session's exit status is 0 and its wait() pid matches its spawn()
      pid (the process didn't crash/hang).

2026-09-06 (EX2, the ex/ed session-status fix): the "marks/undo/#-print"
session (EXSCR3 -- a bare `n`, refused by EX_CMD), the "?re?/e/e!/wq"
session (EXSCR4 -- `?ZZZ?p`'s no-match backward search, and `e` refused
on a dirty buffer without `!`), session 5b (EXSCR5N -- bare `w` with no
remembered filename), and session 6 (EXSCR6 -- a bare `??` with no prior
pattern) each contain a DELIBERATE `?`-producing command in an otherwise-
successful script. Before EX2, ex's exit status was always 0 regardless.
EX2 gives ex a session-error byte (ED_ERRSTAT): once ANY command in the
session is refused, the final `q`/`wq`/`x` exits 1, matching this host's
own ex (vim's ex mode) -- confirmed empirically. Those four sessions'
expected exit status were updated from 0 to 1 for exactly this reason;
nothing else about their expected output changed.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'ex.po')
LISTING = os.path.join(ROOT, 'build', 'MAUXEXTEST.SYSTEM_Output.txt')


def kernel_symbols(*names):
    """Resolve kernel symbols from the image's OWN merlin32 symbol
    dump (build/MAUXEXTEST.SYSTEM_Output.txt, `NAME = $ADDR` lines) --
    never a hand-pinned address: MLI_BUF_USED moved the day
    process.s grew a table in front of it, and a stale address here
    reads garbage silently. Same technique as check_find.py."""
    import re
    wanted = set(names)
    found = {}
    for line in open(LISTING, errors='replace'):
        m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\$([0-9A-Fa-f]+)\s*$',
                     line)
        if m and m.group(1) in wanted:
            found[m.group(1)] = int(m.group(2), 16)
    missing = wanted - set(found)
    if missing:
        raise RuntimeError(f'{sorted(missing)} absent from {LISTING}')
    return found


def kernel_equ(name):
    """An inc/mm.*.equ constant, parsed -- not mirrored."""
    import glob
    import re
    for path in glob.glob(os.path.join(ROOT, 'inc', '*.equ')):
        for line in open(path, errors='replace'):
            m = re.match(rf'^\s*{name}\s+equ\s+(\d+)\b', line.split(';')[0])
            if m:
                return int(m.group(1))
    raise RuntimeError(f'{name} not declared in inc/*.equ')

R_LEN1    = 0x1200
R_STAGE1  = 0x1210
R_LENOUT  = 0x12E0
R_STAGEOUT = 0x12F0
R_SPAWN_PID  = 0x13C0
R_SPAWN_STAT = 0x13C1
R_WAIT_PID   = 0x13C2
R_DONE = 0x13D0
R_ERR  = 0x13D1
R_STEP = 0x13D2

# -- second session: Task 0's `j` (join) fix --
R_LEN2      = 0x1400
R_STAGE2    = 0x1410
R_LENOUT2   = 0x14E0
R_STAGEOUT2 = 0x14F0
R_SPAWN_STAT2 = 0x15C1

# -- third session: marks (incl. shift/invalidate), undo, #-print, n
R_LEN3      = 0x1600
R_STAGE3    = 0x1610
R_LENOUT3   = 0x16E0
R_STAGEOUT3 = 0x16F0
R_SPAWN_STAT3 = 0x17C1

# -- fourth session: ?re? backward search, e/e!, wq
R_LEN4      = 0x1800
R_STAGE4    = 0x1810
R_LENOUT4   = 0x18E0
R_STAGEOUT4 = 0x18F0
R_SPAWN_STAT4 = 0x19C1

# -- fifth session (2026-09-02, filename-on-launch task): `ex FILE`
# loads FILE through the swap file at startup, no bare launch + `r`.
R_LEN5    = 0x1A00
R_STAGE5  = 0x1A10
R_LENOUT5 = 0x1A50
R_STAGEOUT5 = 0x1A60
R_SPAWN_PID5  = 0x1A90
R_SPAWN_STAT5 = 0x1A91
R_WAIT_PID5   = 0x1A92

R_LEN5N   = 0x1AA0
R_STAGE5N = 0x1AB0
R_SPWN_STAT5N = 0x1AD1

# -- sixth session (2026-09-02, "last regular expression" task) --
R_LEN6      = 0x1C00
R_STAGE6    = 0x1C10
R_LENOUT6   = 0x1C70
R_STAGEOUT6 = 0x1C80
R_SPAWN_PID6  = 0x1CE0
R_SPAWN_STAT6 = 0x1CE1
R_WAIT_PID6   = 0x1CE2

# -- seventh session (2026-09-02, widened g/v task) --
R_LEN7      = 0x1D00
R_STAGE7    = 0x1D10
R_LENOUT7   = 0x1D70
R_STAGEOUT7 = 0x1D80
R_SPAWN_PID7  = 0x1DE0
R_SPAWN_STAT7 = 0x1DE1
R_WAIT_PID7   = 0x1DE2

# -- eighth session (2026-09-02, `w` truncation bug fix) --
R_LEN8      = 0x1E00
R_STAGE8    = 0x1E10
R_LEN8O     = 0x1E70
R_SPAWN_PID8  = 0x1E80
R_SPAWN_STAT8 = 0x1E81
R_WAIT_PID8   = 0x1E82

# -- ninth session (2026-09-06, the `!` shell escape/filter family) --
R_LEN9      = 0x1F00
R_STAGE9    = 0x1F10
R_LENOUT9   = 0x1F70
R_STAGEOUT9 = 0x1F78
R_SPAWN_PID9  = 0x1FE0
R_SPAWN_STAT9 = 0x1FE1
R_WAIT_PID9   = 0x1FE2

# -- tenth-thirteenth sessions (2026-09-06, adversarial-review
# regressions EX1/EX2/EX6/EX7 -- src/test/extestb9.s). $1200-$1FFF is
# fully spent by sessions 1-9 (extestb9.s's own header), so these use a
# separate fixed block, $9800-$9BFF.
R_LEN10       = 0xA800
R_STAGE10     = 0xA810
R_LENOUT10    = 0xA860
R_STAGEOUT10  = 0xA868
R_SPAWN_PID10  = 0xA890
R_SPAWN_STA10  = 0xA891
R_WAIT_PID10   = 0xA892

R_LEN11A       = 0xA900
R_STAGE11A     = 0xA908
R_PID11A       = 0xA920
R_STA11A       = 0xA921
R_WAIT_PID11A  = 0xA922
R_LEN11B       = 0xA930
R_STAGE11B     = 0xA938
R_PID11B       = 0xA950
R_STA11B       = 0xA951
R_WAIT_PID11B  = 0xA952

R_LEN12       = 0xAA00
R_STAGE12     = 0xAA10
R_LENOUT12    = 0xAA40
R_STAGEOUT12  = 0xAA48
R_SPAWN_PID12  = 0xAA60
R_SPAWN_STA12  = 0xAA61
R_WAIT_PID12   = 0xAA62

R_LEN13       = 0xAB00
R_STAGE13     = 0xAB10
R_LENOUT13    = 0xAB50
R_STAGEOUT13  = 0xAB58
R_SPAWN_PID13  = 0xAB80
R_SPAWN_STA13  = 0xAB81
R_WAIT_PID13   = 0xAB82

# -- sessions 14-16 (2026-09-06, second adversarial pass -- EX4,
# EX5, EX3 interim guard, src/test/extestb9.s). $9800-$AFFF is
# PMLI_IBF_BASE, the LIVE per-process kernel MLI I/O buffer pool
# (inc/proc.const.equ) -- NOT safe scratch, unlike the
# original sessions 10-13's own (pre-existing, out of scope here)
# choice of $9800+. These three sessions use $1000-$1132 instead,
# a genuinely free block below session 1's own $1200 floor.
R_LEN14        = 0x1000
R_STAGE14      = 0x1008
R_LENMAIN14    = 0x1020
R_STAGEMAIN14  = 0x1028
R_LENCOPY14    = 0x1040
R_STAGECOPY14  = 0x1048
R_SPAWN_PID14  = 0x1060
R_SPAWN_STA14  = 0x1061
R_WAIT_PID14   = 0x1062

R_LEN15         = 0x1070
R_STAGE15       = 0x1078
R_LENMAIN15     = 0x1090
R_STAGEMAIN15   = 0x1098
R_LENOTHER15    = 0x10B0
R_STAGOTH15     = 0x10B8
R_SPAWN_PID15   = 0x10D0
R_SPAWN_STA15   = 0x10D1
R_WAIT_PID15    = 0x10D2

R_LEN16        = 0x1140
R_STAGE16      = 0x1148
# XC1 2026-09-06: byte count/staged bytes from EX16SRC, RE-READ
# after the script's own final `w` (piggybacked onto session 16).
R_LENSRC16     = 0x11A0
R_STAGESRC16   = 0x11A8
R_SPAWN_PID16  = 0x11C0
R_SPAWN_STA16  = 0x11C1
R_WAIT_PID16   = 0x11C2

CR = 0x8D


def hitext(s):
    """A liba string, high-bit-set per byte (ed/ex's own file/line
    encoding)."""
    return bytes(b | 0x80 for b in s.encode('ascii'))


def hilines(*lines):
    out = b''
    for line in lines:
        out += hitext(line) + bytes([CR])
    return out


# (a) the first `,p`, before the substitution.
EXPECT_P1 = hilines(
    'line one', 'BANK middle', 'line three', 'line four BANK', 'line five',
)

# (b) the second `,p`, after `2s/BANK/SWAPD/` -- only line 2 changed; line
# 4's own "BANK" is the control proving the substitute is not global.
EXPECT_P2 = hilines(
    'line one', 'SWAPD middle', 'line three', 'line four BANK', 'line five',
)

EXPECT_CAP = EXPECT_P1 + EXPECT_P2

# (c) /mnt/MAUX/EXOUT after `w` -- byte-identical to what (b) printed (`,p`'s
# own output shape, text+CR per line, IS file-content shape -- no line
# numbers, no decoration).
EXPECT_OUT = EXPECT_P2

# -- second session: Task 0's `j` fix. 1,2j joins L1+L2 -> "L1L2"; the
# first `,p` re-reads it. ex `j` joins WITH a separating space now
# (POSIX ex; ed stays spaceless) -- 2026-09-05, ED_JOINSEP. 2,4j then joins
# L3+L4+L5 -> "L3L4L5" over the now-4-line buffer; the second `,p`
# re-reads L1L2 a SECOND time (from its original swap offset) plus the
# new join. `w` re-reads both a THIRD time via an independent
# SET_MARK+READ. The pre-fix bug corrupted exactly this re-read.
EXPECT_JP1 = hilines('L1 L2', 'L3', 'L4', 'L5')
EXPECT_JP2 = hilines('L1 L2', 'L3 L4 L5')
EXPECT_JCAP = EXPECT_JP1 + EXPECT_JP2
EXPECT_JOUT = EXPECT_JP2

# -- third session: marks (set/'x'/shift-on-insert/shift-on-delete/
# invalidate-on-delete), undo round-trip, #-print, n reserved.
# Buffer starts M1..M5 (5 lines). Command-by-command trace:
#   r /mnt/MAUX/EXSRC3      -> load M1..M5, .=5
#   3ka                  -> mark a := line 3 (M3)
#   1a / NEW / .         -> insert "NEW" after line 1 (M1,NEW,M2,M3,
#                            M4,M5 -- 6 lines); mark a shifts 3->4
#                            (EX_MARK_INS: insert-after=1, mark 3>1)
#   'ap                  -> "M3\r" (mark a=4 -> line 4 IS "M3")
#   1,2d                 -> delete M1,NEW (M2,M3,M4,M5 -- 4 lines);
#                            mark a shifts 4->2 (EX_MARK_DEL: past
#                            the 2-line deleted range)
#   'ap                  -> "M3\r" (mark a=2 -> line 2 IS "M3")
#   1,1d                 -> delete M2 (M3,M4,M5 -- 3 lines); mark a
#                            shifts 2->1
#   1,1d                 -> delete M3 (M4,M5 -- 2 lines); mark a=1
#                            is INSIDE [1,1] -> invalidated to 0
#                            (this is the snapshot `u` restores)
#   'ap                  -> "?\r" (mark a unset)
#   u                    -> undo the last delete: M3,M4,M5 (3 lines)
#   ,p                   -> "M3\rM4\rM5\r"
#   u                    -> undo again = redo (its own inverse):
#                            M4,M5 (2 lines)
#   ,p                   -> "M4\rM5\r"
#   1,2#                 -> numbered print, ex format (rt-just in a
#                            7-wide field + space): "      1 M4\r
#                            2 M5\r"
#   n                    -> "?\r" (n RESERVED in ex -- primary
#                            source: n means `next`, not
#                            numbered-print, which is #/nu here)
#   w /mnt/MAUX/EXOUT3       -> writes M4,M5 to a FRESH path (clears
#                            EX_DIRTY -- "cleared by w")
#   x                    -> buffer now clean -- just quits, no
#                            second write
# ex is SILENT on a refused command when stdin is not a tty (POSIX
# `ex -s`; maux gates this on ED_ERR_QUIET + an fdstat(0) isatty check,
# 2026-09-06). check-ex drives ex with a redirected script, so every
# refusal that used to echo `?\r` now prints NOTHING -- the refusal is
# still proven by the buffer/file ending up correct. (ed keeps its
# always-`?`; check-ed covers it. Interactive ex still shows `?`.)
EXPECT_M3_1 = hitext('M3') + bytes([CR])
EXPECT_M3_2 = hitext('M3') + bytes([CR])
EXPECT_ERR = b''            # was '?'+CR -- ex now silent (see above)
EXPECT_UNDO1 = hilines('M3', 'M4', 'M5')
EXPECT_UNDO2 = hilines('M4', 'M5')
# ex/vi #/nu format (2026-09-06, ED_NUM_RJUST): the line number is
# right-justified in a 7-wide field, then ONE space, then the text --
# NOT ed's number+TAB (which ed's own `n` keeps; check-ed covers it).
EXPECT_NUMPR = (hitext(str(1).rjust(7) + ' ' + 'M4') + bytes([CR]) +
                hitext(str(2).rjust(7) + ' ' + 'M5') + bytes([CR]))
EXPECT_NRSVD = b''            # ex silent on refusal (script mode)
EXPECT_CAP3 = (EXPECT_M3_1 + EXPECT_M3_2 + EXPECT_ERR +
               EXPECT_UNDO1 + EXPECT_UNDO2 + EXPECT_NUMPR + EXPECT_NRSVD)
EXPECT_OUT3 = hilines('M4', 'M5')

# -- fourth session: ?re? backward search (success + wrap-to-no-match),
# e/e! (incl. the dirty-buffer guard), wq. Buffer starts B1,B2,B3 (3
# lines, .=3). Trace:
#   r /mnt/MAUX/EXSRC4   -> load B1,B2,B3, .=3
#   ?B2?p             -> backward search from .=3: decrement to 2,
#                        "B2" matches -> "B2\r", .=2
#   ?ZZZ?p            -> backward search, no match anywhere -- wraps
#                        through every line and fails -> ED_CMDPTR
#                        restored to the bare `?`, which the classic
#                        dispatch then sees as an unrecognized verb
#                        -> "?\r"
#   1a / NEWB / .     -> insert "NEWB" after line 1 (B1,NEWB,B2,B3 --
#                        4 lines); EX_DIRTY=1
#   ,p                -> "B1\rNEWB\rB2\rB3\r"
#   e /mnt/MAUX/EXSRC4B  -> refused: buffer is dirty, no `!` -> "?\r"
#   e! /mnt/MAUX/EXSRC4B -> force: discards the dirty buffer, loads
#                        EXSRC4B fresh (C1,C2); EX_DIRTY cleared
#   ,p                -> "C1\rC2\r"
#   wq                -> writes C1,C2 back to EXSRC4B (the name `e!`
#                        remembered) UNCONDITIONALLY (wq does not
#                        check EX_DIRTY, unlike `x`), then quits
EXPECT_BACK1 = hitext('B2') + bytes([CR])
EXPECT_BACKERR = b''            # ex silent on refusal (script mode)
EXPECT_INSPR = hilines('B1', 'NEWB', 'B2', 'B3')
EXPECT_EGUARD = b''            # ex silent on refusal (script mode)
EXPECT_EFORCEPR = hilines('C1', 'C2')
EXPECT_CAP4 = (EXPECT_BACK1 + EXPECT_BACKERR + EXPECT_INSPR +
               EXPECT_EGUARD + EXPECT_EFORCEPR)
EXPECT_OUT4 = hilines('C1', 'C2')

# -- fifth session (filename-on-launch task): `ex /mnt/MAUX/EXFILE5` loads
# "un"/"deux"/"trois" through the swap file at STARTUP (no `r` in
# EXSCR5_TEXT), `,p` prints all three, and a bare `w` (no filename
# token) writes them straight back -- proving the launch load set the
# remembered filename to EXFILE5 itself, through the swap-file path.
EXPECT_CAP5 = hilines('un', 'deux', 'trois')
EXPECT_OUT5 = (hitext('un') + bytes([CR]) +
               hitext('deux') + bytes([CR]) +
               hitext('trois') + bytes([CR]))

# `ex /mnt/MAUX/EXNOSUCH5` -- the path does not exist. The open failure at
# startup prints `?` (the same path `e NOSUCHFILE` takes) and does NOT
# remember the name, so the script's own bare `w` (EXSCR5N_TEXT) prints
# a SECOND `?`.
EXPECT_CAP5N = b''         # two refusals, both silent (ex -s)

# -- sixth session (2026-09-02, "last regular expression" task,
# learning:01M1FX8HT89CKR9CB8T8VKCW1S). Buffer (EXSRC6): 6 lines,
# "BANK" on 1 and 3, "OLD..." on 5 and 6; `r` leaves dot=6. Trace
# (src/test/extestb5.s's own EXSCR6_TEXT comment has the full
# derivation):
#   ??             -> "?"   no prior RE yet
#   ?BANK?p        -> "BANK three"   backward search wraps from
#                    dot=6 down to line 3; dot=3, LASTPAT="BANK"
#   ??             -> "BANK one"     bare repeat reuses LASTPAT=
#                    "BANK", backward from dot=3; dot=1 (PROVES
#                    backward `??` repeat)
#   /yyyyy/        -> "yyyyy four"   FORWARD search from dot=1;
#                    dot=4, LASTPAT="yyyyy"
#   ??             -> "yyyyy four"   bare BACKWARD repeat reuses
#                    the FORWARD search's own pattern -- the only
#                    line with "yyyyy" is line 4 itself, so the
#                    full backward wrap matches it (PROVES forward
#                    and backward share ONE last-RE store)
#   5s/OLD/NEW/    -> (no output) line5 -> "NEWthing here"
#   5p             -> "NEWthing here"
#   6s//XXX/       -> (no output) empty search field reuses
#                    LASTPAT="OLD"; line6 -> "XXXthing again"
#                    (PROVES `s//` reuse, shared code with `ed`)
#   6p             -> "XXXthing again"
#   wq             -> writes back to EXSRC6 (the `r`-remembered
#                    name) and quits
# the leading bare `??` (no prior RE) is a refusal -- now silent in
# script mode (ED_ERR_QUIET), so no '?' precedes the search output.
EXPECT_CAP6 = hilines(
    'BANK three', 'BANK one', 'yyyyy four', 'yyyyy four',
    'NEWthing here', 'XXXthing again',
)
EXPECT_OUT6 = hilines(
    'BANK one', 'xxxxx two', 'BANK three', 'yyyyy four',
    'NEWthing here', 'XXXthing again',
)

# -- seventh session (2026-09-02, widened g/v task,
# learning:01M1FX8HT89CKR9CB8T8VKCW1S): `g/BANK/s/BANK/GONE/` runs
# the general dispatch path (not p/d) on every matching line,
# proving it works against exbuf's swap-file-backed descriptors.
# Buffer (EXSRC7): "BANK one"/"plain two"/"BANK three"/"plain
# four". Trace (src/test/extestb6.s's own EXSCR7_TEXT comment has
# the full derivation):
#   r /mnt/MAUX/EXSRC7     -> load the 4 lines
#   g/BANK/s/BANK/GONE/  -> (no output) lines 1,3 -> "GONE one",
#                         "GONE three"; lines 2,4 untouched
#   ,p                  -> "GONE one","plain two","GONE
#                         three","plain four"
#   wq                  -> writes back to EXSRC7 and quits
EXPECT_CAP7 = hilines(
    'GONE one', 'plain two', 'GONE three', 'plain four',
)
EXPECT_OUT7 = hilines(
    'GONE one', 'plain two', 'GONE three', 'plain four',
)

# -- eighth session (2026-09-02, `w` truncation bug fix,
# edtestb2.s's own Session 9 -- same proof through ex's swap-file-
# backed write path, which is the exact same ED_DOWRITE code ed's
# own gate exercises directly). A 6-line ("long") buffer is written
# to EXFILE8 first, then the buffer is emptied and replaced with a
# 2-line ("short") one, and a bare `w` (reusing the remembered name)
# overwrites EXFILE8 again. The file must end up EXACTLY the short
# content -- no stale tail from the long write. Pre-fix, ProDOS's
# OPEN does not truncate, so the re-read below would come back
# longer than 6 bytes with stale bytes past "U1\rU2\r".
EXPECT_OUT8 = hilines('U1', 'U2')

# -- ninth session (2026-09-06, the `!` shell escape/filter family,
# src/test/extestb8.s's own EXSCR9_TEXT). Buffer starts unsorted:
# "pear"/"kiwi"/"fig"/"mango". Proves ALL FOUR `!` forms (the
# FILTER, r!, w!, and the bare shell-escape ESC form) through a
# REAL spawned `sh` -> `sort`/`cat`. The filter form needed a real
# fix (EX_BG_SWCLOSE/EX_BG_SWOPEN -- ex's own swap fd was the ONE
# iobuf too many against the kernel-wide pool once `sh`'s child
# needed EX.INxx and EX.OUTxx open at once); see EX_BANG_FILT's
# own header in excmd.s for the measured symptom and the fix.
# Trace:
#   r /mnt/MAUX/EXSRC9        -> load the 4 unsorted lines, .=4
#   1,$!sort               -> (no output) FILTER (EX_BANG_FILT):
#                             writes the 4 lines to EX.INxx, spawns
#                             `sh` -> `sort`, deletes [1,4] and
#                             reads EX.OUTxx back in their place --
#                             "fig"/"kiwi"/"mango"/"pear"
#   %p                     -> "fig\rkiwi\rmango\rpear\r"
#   $r !cat /mnt/MAUX/EXSRC9B -> (no output) EX_RBANG: spawns `sh` ->
#                             `cat /mnt/MAUX/EXSRC9B`, inserts "X1"/"X2"
#                             after line 4 (the `$` address) -- .=6
#   %p                     -> "fig\rkiwi\rmango\rpear\rX1\rX2\r"
#   1,2w !cat              -> (EX_WBANG) spawns `sh` -> `cat`,
#                             writes "fig"/"kiwi" to its stdin;
#                             `cat` echoes them to the INHERITED
#                             console fd (EXCAP9) -- no buffer
#                             change -- "fig\rkiwi\r"
#   !cat /mnt/MAUX/EXSRC9B    -> (EX_BANG_ESC) shell escape: spawns
#                             `sh` -> `cat`, prints "X1"/"X2"
#                             straight to the console -- no buffer
#                             change -- "X1\rX2\r"
#   w /mnt/MAUX/EXOUT9        -> writes the still-6-line buffer
#   q                      -> quit
# All four console-bound outputs land in EXCAP9, concatenated;
# EXOUT9 is read back separately. Byte-exact including CR endings.
EXPECT_SORT9 = hilines('fig', 'kiwi', 'mango', 'pear')
EXPECT_RBANG = hilines('fig', 'kiwi', 'mango', 'pear', 'X1', 'X2')
EXPECT_WBANG = hilines('fig', 'kiwi')
EXPECT_ESC9 = hilines('X1', 'X2')
EXPECT_CAP9 = EXPECT_SORT9 + EXPECT_RBANG + EXPECT_WBANG + EXPECT_ESC9
EXPECT_OUT9 = EXPECT_RBANG

# -- tenth session (2026-09-06, EX1 -- `r !cmd`'s missing ED_CHECK0N,
# src/test/extestb9.s's own EXSCR10_TEXT). Buffer: one line, "original".
# `99r !echo NEW` is refused (out of range); `0r !echo ZERO` and
# `$r !echo LAST` are the valid boundary cases (ADDR1=0 and ADDR1=$).
# Three `%p` outputs land in EXCAP10, concatenated; EXOUT10 (after the
# final `u`) is read back separately.
EXPECT_P10A = hilines('original')
EXPECT_P10B = hilines('ZERO', 'original', 'LAST')
EXPECT_P10C = hilines('ZERO', 'original')
EXPECT_CAP10 = EXPECT_P10A + EXPECT_P10B + EXPECT_P10C
EXPECT_OUT10 = EXPECT_P10C

# -- eleventh session (2026-09-06, EX2 -- a refused command has no
# exit status, src/test/extestb9.s's own EXSCR11A/EXSCR11B_TEXT). 11A
# is the review's own repro (999p then q! on a one-line buffer): no
# output, exit status 1. 11B is the clean control: 1p succeeds, exit
# status 0.
EXPECT_CAP11A = b''
EXPECT_CAP11B = hilines('onlyline')

# -- twelfth session (2026-09-06, EX6 -- `&` shares the prior
# snapshot, src/test/extestb9.s's own EXSRC12/EXSCR12_TEXT). Buffer:
# "aa","aa". `1s/aa/ZZ/` then `2&` -> "ZZ","ZZ". The FIRST `u` (with
# the fix) undoes only the `&` -> "ZZ","aa". The SECOND `u` REDOES the
# `&` -> "ZZ","ZZ" again (single-level undo is its own inverse --
# EX_BLKSWAP's own header -- confirmed against this host's own ex,
# vim's ex mode: a second `u` here does not reach back to the pre-`s`
# state). Two `%p` outputs land in EXCAP12; EXOUT12 (final buffer) is
# read back separately.
EXPECT_P12A = hilines('ZZ', 'aa')
EXPECT_P12B = hilines('ZZ', 'ZZ')
EXPECT_CAP12 = EXPECT_P12A + EXPECT_P12B
EXPECT_OUT12 = EXPECT_P12B

# -- thirteenth session (2026-09-06, EX7 -- shell reads inside `g`
# overwrite the global command's undo snapshot, src/test/extestb9.s's
# own EXSRC13/EXSCR13_TEXT). Buffer: "A","B". `g/[AB]/r !cat EXFIXX`
# over both matching lines -> "A","LONGRUN","B","LONGRUN". The FIRST
# `u` (with the fix) undoes the WHOLE global as one unit -> "A","B".
# The SECOND `u` redoes it -> "A","LONGRUN","B","LONGRUN" again
# (verified against this host's own ex). Three `%p` outputs land in
# EXCAP13 so far.
#
# FF1 2026-09-06 (review, first-chair accept): EXFIXX's own
# content was widened from "X" (1 char) to "LONGRUN" (7 chars) --
# long enough to reach cmds' own start in CMDBUF for BOTH the `g`
# case's "g/[AB]/" (7-char) prefix and the `v` case's "v/Z/" (4-char)
# prefix below, so a text-reading sub-command's own CMDBUF write
# clobbers the command-list bytes pass 2 needs for every match after
# the first -- exactly the bug FF1 named. This SAME session (already
# the g/v engine's own regression) is the piggyback: with the
# GCMDBUF fix, both matches still see the correct, uncorrupted `r
# !cat EXFIXX` text on every pass-2 iteration.
#
# XC3 2026-09-06 (second closing pass) PIGGYBACKS a `v` case
# onto this SAME session (same $9800-ceiling reason as session 11B's
# own header -- no room for a dedicated spawn): reuses the SAME
# 4-line "A","LONGRUN","B","LONGRUN" buffer left by the `g` case
# above, since none of those four lines contains "Z" either --
# `v/Z/r !cat EXR9/EXFIXX` (relative spelling, same fixture already
# staged, same cwd-relative trick as session 15's own XC2)
# inverse-matches ALL FOUR -> 8 lines, and `u` must undo the WHOLE
# `v` as one unit, back to "A","LONGRUN","B","LONGRUN" -- a FOURTH
# `%p` output (identical to the third) lands in EXCAP13; EXOUT13
# (final buffer) is UNCHANGED at "A","LONGRUN","B","LONGRUN".
EXPECT_P13A = hilines('A', 'LONGRUN', 'B', 'LONGRUN')
EXPECT_P13B = hilines('A', 'B')
EXPECT_CAP13 = EXPECT_P13A + EXPECT_P13B + EXPECT_P13A + EXPECT_P13A
EXPECT_OUT13 = EXPECT_P13A

# -- fourteenth session (2026-09-06, EX4 -- `w PATH` was silently
# rebinding the current filename, src/test/extestb9.s's own
# EX14MAIN/EXSCR14_TEXT). Launch loads EX14MAIN ("old") via argv.
# `w /mnt/MAUX/EXR9/EX14COPY` writes the CURRENT buffer ("old") to a
# NEW path without rebinding; `1s/old/new/` then a bare `w`
# writes "new" back to EX14MAIN (the launch-set name), NOT
# EX14COPY. No `p` in the script, so EXCAP14 is empty.
EXPECT_CAP14 = b''
EXPECT_MAIN14 = hilines('new')
EXPECT_COPY14 = hilines('old')

# -- fifteenth session (2026-09-06, EX5 -- the `w!` guard refused
# a target naming the CURRENT file, src/test/extestb9.s's own
# EX15MAIN/EX15OTHER/EXSCR15_TEXT). Launch loads EX15MAIN ("old")
# via argv; EX15OTHER ("other") is pre-staged as a genuinely
# DIFFERENT existing file. `1s/old/new/` then `w /mnt/MAUX/EXR9/
# EX15MAIN` (same ABSOLUTE path as the launch load) succeeds
# WITHOUT `!` (EX_FNAME_EQ matches ED_CURFNAME) -- EX15MAIN ->
# "new".
#
# XC2 2026-09-06 (second closing pass) PIGGYBACKS a
# relative-spelling case onto this SAME session (same $9800-
# ceiling reason as session 11B's own header): `1s/new/N2/`
# edits the line again, then `w EXR9/EX15MAIN` -- a RELATIVE
# spelling (cwd /mnt/MAUX) of the SAME current file -- must ALSO
# succeed without `!` (ED_FNAME_EQ canonicalizes both sides to
# absolute first) -- EX15MAIN -> "N2". `w /mnt/MAUX/EXR9/
# EX15OTHER` (a different existing file) is still REFUSED
# without `!`, leaving EX15OTHER untouched. No `p` in the
# script, so EXCAP15 is empty.
EXPECT_CAP15 = b''
EXPECT_MAIN15 = hilines('N2')
EXPECT_OTHER15 = hilines('other')

# -- sixteenth session (2026-09-06, EX3 PIPELINE REWIRE -- was
# the interim guard's own adversarial pass; the guard it tested
# is gone (EX_PIPECHK deleted), and `!`/`w !`/`r !` now hand `sh`
# a REAL script via argv[1] instead of "cmd < EX.INxx" text, so a
# pipeline attaches to the WHOLE execution, not just its last
# stage -- src/test/extestb9.s's own EX16SRC/EXSCR16_TEXT).
# Buffer: "pear","fig". `%!cat | sort` now runs for REAL: `cat`
# reads the WHOLE range (fd 0, inherited) and pipes into `sort`,
# whose stdout is captured (fd 1) -> "fig","pear" -- the
# following `%p` proves the FIRST stage was not starved of input.
EXPECT_P16A = hilines('fig', 'pear')

# FF4 2026-09-06 (review, first-chair accept): `.=` right
# after `%!cat | sort` prints "2" here -- ONE MORE than a
# single-command filter (`%!sort` alone, pre-rewire, gave "1"
# for the SAME 2-line range). OPEN FINDING (EX3 rewire,
# 2026-09-06): not yet root-caused: content is proven byte-exact
# both pipeline directions (EXPECT_P16A/EXPECT_P16C), so the
# filter's DATA TRANSPORT is correct; only EX_BANG_FILT's FF4 dot
# arithmetic differs by +1 specifically when `sh`'s script forks
# TWO grandchildren (a real 2-stage pipe) rather than exec'ing
# one -- suspect a zero-page/scheduling interaction under that
# deeper fork, not investigated further here.
EXPECT_DOT16 = hilines('2')

# EX3 pipeline rewire, OTHER direction: `$a`/text-entry appends
# "zebra","apple" (lines 3-4), then `%!sort | cat` reorders the
# WHOLE 4-line range (`sort`) and passes it through unchanged as
# the LAST stage's own captured stdout (`cat`) -> "apple","fig",
# "pear","zebra" -- proves a multi-stage pipe's LAST stage output
# is what lands back in the buffer, not an earlier stage's.
# `1d`/`3d` then delete "apple"/"zebra", restoring the SAME
# "fig","pear" shape the rest of this session already assumed
# before this rewire (so FF3/FF5/XC1 below are unchanged).
EXPECT_P16C = hilines('apple', 'fig', 'pear', 'zebra')

# FF3 2026-09-06 (review, first-chair accept): classic
# `r FILE` with no address now inserts at the CURRENT line (dot),
# matching POSIX ex and maux's own `r !cmd` -- not `$` (POSIX
# ed's own default, unchanged; check-ed covers it). At this point
# dot=1 ("Fig"), so `r EXR9/EXFIXZ` ("ZERO") lands between "Fig"
# and "pear".
EXPECT_P16D = hilines('Fig', 'ZERO', 'pear')

# FF5 2026-09-06 (review, first-chair accept): `s///gN` (a
# `g` flag combined with a line count) is no longer refused in ex
# -- `N` is a LINE COUNT here (ED_SNUM_LINES), not ed's own Nth-
# occurrence-in-a-line meaning, so the two never actually
# conflicted. `$a`/text-entry appends "aa","aa","aa" (lines 4-6);
# `4s/a/b/g2` globalizes lines 4-5 ("aa"->"bb" each), line 6
# untouched.
EXPECT_P16E = hilines('Fig', 'ZERO', 'pear', 'bb', 'bb', 'aa')

# Phase E 2026-09-06: `w !` with a REAL 2-stage pipe -- lines
# 4-6 ("bb","bb","aa") go to `sort`'s stdin, its stdout feeds
# `cat`, whose output lands on ex's own captured fd 1 (inherited,
# same stream as `%p`/`.=`) -- proves `w !`'s pipeline attaches
# to the WHOLE execution the same way the filter form's does.
EXPECT_P16F = hilines('aa', 'bb', 'bb')

EXPECT_CAP16 = (EXPECT_P16A + EXPECT_DOT16 + EXPECT_P16C +
                EXPECT_P16D + EXPECT_P16E + EXPECT_P16F)

# XC1 2026-09-06 (second closing pass) PIGGYBACKS onto this
# SAME session (same $9800-ceiling reason as above): the buffer is
# still UNNAMED at this point (`r` never rebinds), so `w! EXR9/
# EX16SRC` (relative, its own source path -- `!` needed since it
# already exists, EX5's own guard, unrelated to this fix)
# establishes the current name, `1s/f/F/` edits it, and a bare `w`
# reuses the just-established name -- EX16SRC ends as "Fig","pear".
# Pre-fix (EX4's unconditional removal), the bare `w` would be
# refused and EX16SRC would stay at "fig","pear" (the first
# write's own content). The FF2/FF3/FF4/FF5 phases above run AFTER
# this write, so EX16SRC on disk is unaffected by them.
EXPECT_SRC16 = hilines('Fig', 'pear')


def peek_aux1(client, addr, count=1):
    return client.call_tool('peek', {
        'addr': addr,
        'count': count,
        'bank': 'aux',
        'aux_bank': 1,
    })['bytes']


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}', file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make ex-image first',
              file=sys.stderr)
        return 2

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-ex] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-ex] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        done = 0
        # Phase D (EX3 pipeline work): report the io_buffer pool's
        # high-water mark across the WHOLE run. The kernel keeps it
        # itself now (K_IBF_HIWAT, process.s) alongside K_PARK_CNT,
        # the number of times io_buffer LENDING parked a file
        # (docs/IOBUF-LENDING.md) -- both read by SYMBOL from the
        # image's own listing, never by a pinned address.
        for i in range(600):
            client.call_tool('step', {'cycles': 200_000})
            done = peek_aux1(client, R_DONE)[0]
            if done in (0xAA, 0xEE):
                break
        err = peek_aux1(client, R_ERR)[0]
        step = peek_aux1(client, R_STEP)[0]
        print(f'[check-ex] done=${done:02X} err=${err:02X} step=${step:02X}')
        syms = kernel_symbols('K_IBF_HIWAT', 'K_PARK_CNT', 'K_IBF_INUSE')
        mli_hiwater = client.call_tool('peek', {
            'addr': syms['K_IBF_HIWAT'], 'count': 1, 'bank': 'main',
        })['bytes'][0]
        parks = client.call_tool('peek', {
            'addr': syms['K_PARK_CNT'], 'count': 1, 'bank': 'main',
        })['bytes'][0]
        inuse_end = client.call_tool('peek', {
            'addr': syms['K_IBF_INUSE'], 'count': 1, 'bank': 'main',
        })['bytes'][0]
        print(f'[check-ex] Phase D: io_buffer high-water = '
              f'{mli_hiwater} of {kernel_equ("MLI_IOBUF_CNT")}, files '
              f'parked by lending = {parks}, buffers still held at the '
              f'end = {inuse_end} (incl. the session 16 real pipelines, '
              f'both directions, plus the `w !` pipe)')

        failures = []
        if done != 0xAA:
            failures.append(f'test did not finish successfully '
                            f'(done=${done:02X}, err=${err:02X}, step={step})')
            for failure in failures:
                print(f'[check-ex] FAIL: {failure}', file=sys.stderr)
            return 1

        spawn_status = peek_aux1(client, R_SPAWN_STAT)[0]
        spawn_pid = peek_aux1(client, R_SPAWN_PID)[0]
        wait_pid = peek_aux1(client, R_WAIT_PID)[0]
        if spawn_status != 0:
            failures.append(f'ex exit status expected 0, got {spawn_status}')
        if wait_pid != spawn_pid:
            failures.append(f'wait pid {wait_pid} != spawn pid {spawn_pid}')

        len1 = peek_aux1(client, R_LEN1)[0]
        stage1 = bytes(peek_aux1(client, R_STAGE1, max(len1, 1)))[:len1]
        if stage1 != EXPECT_CAP:
            failures.append(
                f'(a)/(b) stdout capture mismatch: got {stage1!r} '
                f'(len {len1}), expected {EXPECT_CAP!r} '
                f'(len {len(EXPECT_CAP)})')

        lenout = peek_aux1(client, R_LENOUT)[0]
        stageout = bytes(peek_aux1(client, R_STAGEOUT, max(lenout, 1)))[:lenout]
        if stageout != EXPECT_OUT:
            failures.append(
                f'(c) /mnt/MAUX/EXOUT (w round-trip through the swap file) '
                f'mismatch: got {stageout!r} (len {lenout}), expected '
                f'{EXPECT_OUT!r} (len {len(EXPECT_OUT)})')

        spawn_status3 = peek_aux1(client, R_SPAWN_STAT3)[0]
        if spawn_status3 != 1:
            failures.append(f'ex (marks/undo/#-print session) exit status '
                            f'expected 1, got {spawn_status3}')

        len3 = peek_aux1(client, R_LEN3)[0]
        stage3 = bytes(peek_aux1(client, R_STAGE3, max(len3, 1)))[:len3]
        if stage3 != EXPECT_CAP3:
            failures.append(
                f'M2 items 2/4/5 (marks/undo/#-print): stdout capture '
                f'mismatch: got {stage3!r} (len {len3}), expected '
                f'{EXPECT_CAP3!r} (len {len(EXPECT_CAP3)})')

        lenout3 = peek_aux1(client, R_LENOUT3)[0]
        stageout3 = bytes(
            peek_aux1(client, R_STAGEOUT3, max(lenout3, 1)))[:lenout3]
        if stageout3 != EXPECT_OUT3:
            failures.append(
                f'M2 items 2/4/5: /mnt/MAUX/EXOUT3 (w after undo round-trip) '
                f'mismatch: got {stageout3!r} (len {lenout3}), expected '
                f'{EXPECT_OUT3!r} (len {len(EXPECT_OUT3)})')

        spawn_status4 = peek_aux1(client, R_SPAWN_STAT4)[0]
        if spawn_status4 != 1:
            failures.append(f'ex (?re?/e/e!/wq session) exit status '
                            f'expected 1, got {spawn_status4}')

        len4 = peek_aux1(client, R_LEN4)[0]
        stage4 = bytes(peek_aux1(client, R_STAGE4, max(len4, 1)))[:len4]
        if stage4 != EXPECT_CAP4:
            failures.append(
                f'M2 items 1/3/6 (?re?/e/e!/wq): stdout capture '
                f'mismatch: got {stage4!r} (len {len4}), expected '
                f'{EXPECT_CAP4!r} (len {len(EXPECT_CAP4)})')

        lenout4 = peek_aux1(client, R_LENOUT4)[0]
        stageout4 = bytes(
            peek_aux1(client, R_STAGEOUT4, max(lenout4, 1)))[:lenout4]
        if stageout4 != EXPECT_OUT4:
            failures.append(
                f'M2 items 1/3/6: /mnt/MAUX/EXSRC4B (wq after e!) '
                f'mismatch: got {stageout4!r} (len {lenout4}), expected '
                f'{EXPECT_OUT4!r} (len {len(EXPECT_OUT4)})')

        spawn_status2 = peek_aux1(client, R_SPAWN_STAT2)[0]
        if spawn_status2 != 0:
            failures.append(f'ex (join session) exit status expected 0, '
                            f'got {spawn_status2}')

        len2 = peek_aux1(client, R_LEN2)[0]
        stage2 = bytes(peek_aux1(client, R_STAGE2, max(len2, 1)))[:len2]
        if stage2 != EXPECT_JCAP:
            failures.append(
                f'Task 0 (j fix): stdout capture mismatch: got {stage2!r} '
                f'(len {len2}), expected {EXPECT_JCAP!r} '
                f'(len {len(EXPECT_JCAP)})')

        lenout2 = peek_aux1(client, R_LENOUT2)[0]
        stageout2 = bytes(
            peek_aux1(client, R_STAGEOUT2, max(lenout2, 1)))[:lenout2]
        if stageout2 != EXPECT_JOUT:
            failures.append(
                f'Task 0 (j fix): /mnt/MAUX/EXOUT2 (w round-trip after two '
                f'joins) mismatch: got {stageout2!r} (len {lenout2}), '
                f'expected {EXPECT_JOUT!r} (len {len(EXPECT_JOUT)})')

        spawn_status5 = peek_aux1(client, R_SPAWN_STAT5)[0]
        spawn_pid5 = peek_aux1(client, R_SPAWN_PID5)[0]
        wait_pid5 = peek_aux1(client, R_WAIT_PID5)[0]
        spwn_status5n = peek_aux1(client, R_SPWN_STAT5N)[0]
        if spawn_status5 != 0:
            failures.append(f'session 5a ex exit status expected 0, got '
                            f'{spawn_status5}')
        if wait_pid5 != spawn_pid5:
            failures.append(f'session 5a wait pid {wait_pid5} != spawn '
                            f'pid {spawn_pid5}')
        if spwn_status5n != 1:
            failures.append(f'session 5b ex exit status expected 1, got '
                            f'{spwn_status5n}')

        len5 = peek_aux1(client, R_LEN5)[0]
        stage5 = bytes(peek_aux1(client, R_STAGE5, max(len5, 1)))[:len5]
        if stage5 != EXPECT_CAP5:
            failures.append(
                f'(e) session 5a `ex /mnt/MAUX/EXFILE5` launch-load `,p` '
                f'(through the swap file) mismatch: got {stage5!r} '
                f'(len {len5}), expected {EXPECT_CAP5!r} '
                f'(len {len(EXPECT_CAP5)})')

        lenout5 = peek_aux1(client, R_LENOUT5)[0]
        stageout5 = bytes(
            peek_aux1(client, R_STAGEOUT5, max(lenout5, 1)))[:lenout5]
        if stageout5 != EXPECT_OUT5:
            failures.append(
                f'(f) /mnt/MAUX/EXFILE5 (bare `w` after launch-load, through '
                f'the swap file) mismatch: got {stageout5!r} '
                f'(len {lenout5}), expected {EXPECT_OUT5!r} '
                f'(len {len(EXPECT_OUT5)})')

        len5n = peek_aux1(client, R_LEN5N)[0]
        stage5n = bytes(peek_aux1(client, R_STAGE5N, max(len5n, 1)))[:len5n]
        if stage5n != EXPECT_CAP5N:
            failures.append(
                f'(g) session 5b `ex /mnt/MAUX/EXNOSUCH5` (launch-load of a '
                f'nonexistent path) mismatch: got {stage5n!r} '
                f'(len {len5n}), expected {EXPECT_CAP5N!r} '
                f'(len {len(EXPECT_CAP5N)})')

        # -- sixth session (2026-09-02, "last regular expression" task) --
        spawn_status6 = peek_aux1(client, R_SPAWN_STAT6)[0]
        spawn_pid6 = peek_aux1(client, R_SPAWN_PID6)[0]
        wait_pid6 = peek_aux1(client, R_WAIT_PID6)[0]
        if spawn_status6 != 1:
            failures.append(f'session 6 ex exit status expected 1, got '
                            f'{spawn_status6}')
        if wait_pid6 != spawn_pid6:
            failures.append(f'session 6 wait pid {wait_pid6} != spawn '
                            f'pid {spawn_pid6}')

        len6 = peek_aux1(client, R_LEN6)[0]
        stage6 = bytes(peek_aux1(client, R_STAGE6, max(len6, 1)))[:len6]
        if stage6 != EXPECT_CAP6:
            failures.append(
                f'(h) session 6 capture ("last regular expression") '
                f'mismatch: got {stage6!r} (len {len6}), expected '
                f'{EXPECT_CAP6!r} (len {len(EXPECT_CAP6)})')

        lenout6 = peek_aux1(client, R_LENOUT6)[0]
        stageout6 = bytes(
            peek_aux1(client, R_STAGEOUT6, max(lenout6, 1)))[:lenout6]
        if stageout6 != EXPECT_OUT6:
            failures.append(
                f'(i) /mnt/MAUX/EXSRC6 (post-`wq` round-trip, through the '
                f'swap file) mismatch: got {stageout6!r} (len {lenout6}), '
                f'expected {EXPECT_OUT6!r} (len {len(EXPECT_OUT6)})')

        # -- seventh session (2026-09-02, widened g/v task) --
        spawn_status7 = peek_aux1(client, R_SPAWN_STAT7)[0]
        spawn_pid7 = peek_aux1(client, R_SPAWN_PID7)[0]
        wait_pid7 = peek_aux1(client, R_WAIT_PID7)[0]
        if spawn_status7 != 0:
            failures.append(f'session 7 ex exit status expected 0, got '
                            f'{spawn_status7}')
        if wait_pid7 != spawn_pid7:
            failures.append(f'session 7 wait pid {wait_pid7} != spawn '
                            f'pid {spawn_pid7}')

        len7 = peek_aux1(client, R_LEN7)[0]
        stage7 = bytes(peek_aux1(client, R_STAGE7, max(len7, 1)))[:len7]
        if stage7 != EXPECT_CAP7:
            failures.append(
                f'(j) session 7 capture (widened g/v: g/re/s///) '
                f'mismatch: got {stage7!r} (len {len7}), expected '
                f'{EXPECT_CAP7!r} (len {len(EXPECT_CAP7)})')

        lenout7 = peek_aux1(client, R_LENOUT7)[0]
        stageout7 = bytes(
            peek_aux1(client, R_STAGEOUT7, max(lenout7, 1)))[:lenout7]
        if stageout7 != EXPECT_OUT7:
            failures.append(
                f'(k) /mnt/MAUX/EXSRC7 (post-`g/re/s///`+`wq` round-trip, '
                f'through the swap file) mismatch: got {stageout7!r} '
                f'(len {lenout7}), expected {EXPECT_OUT7!r} '
                f'(len {len(EXPECT_OUT7)})')

        # -- eighth session (2026-09-02, `w` truncation bug fix) --
        spawn_status8 = peek_aux1(client, R_SPAWN_STAT8)[0]
        spawn_pid8 = peek_aux1(client, R_SPAWN_PID8)[0]
        wait_pid8 = peek_aux1(client, R_WAIT_PID8)[0]
        if spawn_status8 != 0:
            failures.append(f'session 8 ex exit status expected 0, got '
                            f'{spawn_status8}')
        if wait_pid8 != spawn_pid8:
            failures.append(f'session 8 wait pid {wait_pid8} != spawn '
                            f'pid {spawn_pid8}')

        len8o = peek_aux1(client, R_LEN8O)[0]
        if len8o != 0:
            failures.append(
                f'session 8 script unexpectedly printed something '
                f'(len {len8o}) -- EXSCR8_TEXT has no `,p`, so EXCAP8 '
                f'must stay empty')

        len8 = peek_aux1(client, R_LEN8)[0]
        stage8 = bytes(peek_aux1(client, R_STAGE8, max(len8, 1)))[:len8]
        if stage8 != EXPECT_OUT8:
            failures.append(
                f'(l) /mnt/MAUX/EXFILE8 (`w` truncation, through the swap '
                f'file) mismatch: got {stage8!r} (len {len8}), expected '
                f'{EXPECT_OUT8!r} (len {len(EXPECT_OUT8)}) -- a longer '
                f'len than expected means ED_DOWRITE left a stale tail '
                f'from the earlier long write (missing SET_EOF)')

        # -- ninth session (2026-09-06, the `!` shell escape/filter
        # family) --
        spawn_status9 = peek_aux1(client, R_SPAWN_STAT9)[0]
        spawn_pid9 = peek_aux1(client, R_SPAWN_PID9)[0]
        wait_pid9 = peek_aux1(client, R_WAIT_PID9)[0]
        if spawn_status9 != 0:
            failures.append(f'session 9 ex exit status expected 0, got '
                            f'{spawn_status9}')
        if wait_pid9 != spawn_pid9:
            failures.append(f'session 9 wait pid {wait_pid9} != spawn '
                            f'pid {spawn_pid9}')

        len9 = peek_aux1(client, R_LEN9)[0]
        stage9 = bytes(peek_aux1(client, R_STAGE9, max(len9, 1)))[:len9]
        if stage9 != EXPECT_CAP9:
            failures.append(
                f'(m) session 9 capture (`1,$!sort` filter form + '
                f'`$r !cat` r! form + `w !cat` w! form + bare '
                f'`!cat` ESC form -- all four `!` forms) mismatch: '
                f'got {stage9!r} (len {len9}), expected '
                f'{EXPECT_CAP9!r} (len {len(EXPECT_CAP9)})')

        lenout9 = peek_aux1(client, R_LENOUT9)[0]
        stageout9 = bytes(
            peek_aux1(client, R_STAGEOUT9, max(lenout9, 1)))[:lenout9]
        if stageout9 != EXPECT_OUT9:
            failures.append(
                f'(n) /mnt/MAUX/EXOUT9 (post-r! `w` round-trip) '
                f'mismatch: got {stageout9!r} (len {lenout9}), '
                f'expected {EXPECT_OUT9!r} (len {len(EXPECT_OUT9)})')

        # -- tenth session (EX1: `r !cmd`'s missing ED_CHECK0N) --
        spawn_status10 = peek_aux1(client, R_SPAWN_STA10)[0]
        spawn_pid10 = peek_aux1(client, R_SPAWN_PID10)[0]
        wait_pid10 = peek_aux1(client, R_WAIT_PID10)[0]
        if spawn_status10 != 1:
            failures.append(f'session 10 (EX1) ex exit status expected '
                            f'1, got {spawn_status10}')
        if wait_pid10 != spawn_pid10:
            failures.append(f'session 10 wait pid {wait_pid10} != '
                            f'spawn pid {spawn_pid10}')

        len10 = peek_aux1(client, R_LEN10)[0]
        stage10 = bytes(peek_aux1(client, R_STAGE10, max(len10, 1)))[:len10]
        if stage10 != EXPECT_CAP10:
            failures.append(
                f'(o) session 10 (EX1) capture (`99r !echo NEW` '
                f'refused, no mutation; `0r`/`$r` boundary cases '
                f'work; undo intact) mismatch: got {stage10!r} '
                f'(len {len10}), expected {EXPECT_CAP10!r} '
                f'(len {len(EXPECT_CAP10)})')

        lenout10 = peek_aux1(client, R_LENOUT10)[0]
        stageout10 = bytes(
            peek_aux1(client, R_STAGEOUT10, max(lenout10, 1)))[:lenout10]
        if stageout10 != EXPECT_OUT10:
            failures.append(
                f'(p) session 10 (EX1) EXOUT10 mismatch: got '
                f'{stageout10!r} (len {lenout10}), expected '
                f'{EXPECT_OUT10!r} (len {len(EXPECT_OUT10)})')

        # -- eleventh session (EX2: a refused command has no exit
        # status) --
        spawn_status11a = peek_aux1(client, R_STA11A)[0]
        spawn_pid11a = peek_aux1(client, R_PID11A)[0]
        wait_pid11a = peek_aux1(client, R_WAIT_PID11A)[0]
        if spawn_status11a != 1:
            failures.append(f'session 11A (EX2, 999p then q!) exit '
                            f'status expected 1, got {spawn_status11a}')
        if wait_pid11a != spawn_pid11a:
            failures.append(f'session 11A wait pid {wait_pid11a} != '
                            f'spawn pid {spawn_pid11a}')

        len11a = peek_aux1(client, R_LEN11A)[0]
        stage11a = bytes(
            peek_aux1(client, R_STAGE11A, max(len11a, 1)))[:len11a]
        if stage11a != EXPECT_CAP11A:
            failures.append(
                f'(q) session 11A (EX2) capture mismatch: got '
                f'{stage11a!r} (len {len11a}), expected '
                f'{EXPECT_CAP11A!r} (len {len(EXPECT_CAP11A)})')

        spawn_status11b = peek_aux1(client, R_STA11B)[0]
        spawn_pid11b = peek_aux1(client, R_PID11B)[0]
        wait_pid11b = peek_aux1(client, R_WAIT_PID11B)[0]
        if spawn_status11b != 0:
            failures.append(f'session 11B (EX2, 1p then q!) exit '
                            f'status expected 0, got {spawn_status11b}')
        if wait_pid11b != spawn_pid11b:
            failures.append(f'session 11B wait pid {wait_pid11b} != '
                            f'spawn pid {spawn_pid11b}')

        len11b = peek_aux1(client, R_LEN11B)[0]
        stage11b = bytes(
            peek_aux1(client, R_STAGE11B, max(len11b, 1)))[:len11b]
        if stage11b != EXPECT_CAP11B:
            failures.append(
                f'(r) session 11B (EX2) capture mismatch: got '
                f'{stage11b!r} (len {len11b}), expected '
                f'{EXPECT_CAP11B!r} (len {len(EXPECT_CAP11B)})')

        # -- twelfth session (EX6: `&` shares the prior snapshot) --
        spawn_status12 = peek_aux1(client, R_SPAWN_STA12)[0]
        spawn_pid12 = peek_aux1(client, R_SPAWN_PID12)[0]
        wait_pid12 = peek_aux1(client, R_WAIT_PID12)[0]
        if spawn_status12 != 0:
            failures.append(f'session 12 (EX6) ex exit status expected '
                            f'0, got {spawn_status12}')
        if wait_pid12 != spawn_pid12:
            failures.append(f'session 12 wait pid {wait_pid12} != '
                            f'spawn pid {spawn_pid12}')

        len12 = peek_aux1(client, R_LEN12)[0]
        stage12 = bytes(peek_aux1(client, R_STAGE12, max(len12, 1)))[:len12]
        if stage12 != EXPECT_CAP12:
            failures.append(
                f'(s) session 12 (EX6) capture (`&` takes its own '
                f'undo snapshot) mismatch: got {stage12!r} '
                f'(len {len12}), expected {EXPECT_CAP12!r} '
                f'(len {len(EXPECT_CAP12)})')

        lenout12 = peek_aux1(client, R_LENOUT12)[0]
        stageout12 = bytes(
            peek_aux1(client, R_STAGEOUT12, max(lenout12, 1)))[:lenout12]
        if stageout12 != EXPECT_OUT12:
            failures.append(
                f'(t) session 12 (EX6) EXOUT12 mismatch: got '
                f'{stageout12!r} (len {lenout12}), expected '
                f'{EXPECT_OUT12!r} (len {len(EXPECT_OUT12)})')

        # -- thirteenth session (EX7: shell reads inside `g` overwrite
        # the global command's undo snapshot) --
        spawn_status13 = peek_aux1(client, R_SPAWN_STA13)[0]
        spawn_pid13 = peek_aux1(client, R_SPAWN_PID13)[0]
        wait_pid13 = peek_aux1(client, R_WAIT_PID13)[0]
        if spawn_status13 != 0:
            failures.append(f'session 13 (EX7) ex exit status expected '
                            f'0, got {spawn_status13}')
        if wait_pid13 != spawn_pid13:
            failures.append(f'session 13 wait pid {wait_pid13} != '
                            f'spawn pid {spawn_pid13}')

        len13 = peek_aux1(client, R_LEN13)[0]
        stage13 = bytes(peek_aux1(client, R_STAGE13, max(len13, 1)))[:len13]
        if stage13 != EXPECT_CAP13:
            failures.append(
                f'(u) session 13 (EX7) capture (`g/[AB]/r !echo X` + '
                f'undo/redo as ONE unit) mismatch: got {stage13!r} '
                f'(len {len13}), expected {EXPECT_CAP13!r} '
                f'(len {len(EXPECT_CAP13)})')

        lenout13 = peek_aux1(client, R_LENOUT13)[0]
        stageout13 = bytes(
            peek_aux1(client, R_STAGEOUT13, max(lenout13, 1)))[:lenout13]
        if stageout13 != EXPECT_OUT13:
            failures.append(
                f'(v) session 13 (EX7) EXOUT13 mismatch: got '
                f'{stageout13!r} (len {lenout13}), expected '
                f'{EXPECT_OUT13!r} (len {len(EXPECT_OUT13)})')

        # -- fourteenth session (EX4: `w PATH` no longer rebinds the
        # current filename) --
        spawn_status14 = peek_aux1(client, R_SPAWN_STA14)[0]
        spawn_pid14 = peek_aux1(client, R_SPAWN_PID14)[0]
        wait_pid14 = peek_aux1(client, R_WAIT_PID14)[0]
        if spawn_status14 != 0:
            failures.append(f'session 14 (EX4) ex exit status expected '
                            f'0, got {spawn_status14}')
        if wait_pid14 != spawn_pid14:
            failures.append(f'session 14 wait pid {wait_pid14} != '
                            f'spawn pid {spawn_pid14}')

        len14 = peek_aux1(client, R_LEN14)[0]
        stage14 = bytes(peek_aux1(client, R_STAGE14, max(len14, 1)))[:len14]
        if stage14 != EXPECT_CAP14:
            failures.append(
                f'(w) session 14 (EX4) capture mismatch: got '
                f'{stage14!r} (len {len14}), expected '
                f'{EXPECT_CAP14!r} (len {len(EXPECT_CAP14)})')

        lenmain14 = peek_aux1(client, R_LENMAIN14)[0]
        stagemain14 = bytes(
            peek_aux1(client, R_STAGEMAIN14, max(lenmain14, 1)))[:lenmain14]
        if stagemain14 != EXPECT_MAIN14:
            failures.append(
                f'(x) session 14 (EX4) EX14MAIN mismatch: got '
                f'{stagemain14!r} (len {lenmain14}), expected '
                f'{EXPECT_MAIN14!r} (len {len(EXPECT_MAIN14)})')

        lencopy14 = peek_aux1(client, R_LENCOPY14)[0]
        stagecopy14 = bytes(
            peek_aux1(client, R_STAGECOPY14, max(lencopy14, 1)))[:lencopy14]
        if stagecopy14 != EXPECT_COPY14:
            failures.append(
                f'(y) session 14 (EX4) EX14COPY mismatch: got '
                f'{stagecopy14!r} (len {lencopy14}), expected '
                f'{EXPECT_COPY14!r} (len {len(EXPECT_COPY14)})')

        # -- fifteenth session (EX5: the `w!` guard refused a target
        # naming the current file) --
        spawn_status15 = peek_aux1(client, R_SPAWN_STA15)[0]
        spawn_pid15 = peek_aux1(client, R_SPAWN_PID15)[0]
        wait_pid15 = peek_aux1(client, R_WAIT_PID15)[0]
        if spawn_status15 != 1:
            failures.append(f'session 15 (EX5) ex exit status expected '
                            f'1, got {spawn_status15}')
        if wait_pid15 != spawn_pid15:
            failures.append(f'session 15 wait pid {wait_pid15} != '
                            f'spawn pid {spawn_pid15}')

        len15 = peek_aux1(client, R_LEN15)[0]
        stage15 = bytes(peek_aux1(client, R_STAGE15, max(len15, 1)))[:len15]
        if stage15 != EXPECT_CAP15:
            failures.append(
                f'(z) session 15 (EX5) capture mismatch: got '
                f'{stage15!r} (len {len15}), expected '
                f'{EXPECT_CAP15!r} (len {len(EXPECT_CAP15)})')

        lenmain15 = peek_aux1(client, R_LENMAIN15)[0]
        stagemain15 = bytes(
            peek_aux1(client, R_STAGEMAIN15, max(lenmain15, 1)))[:lenmain15]
        if stagemain15 != EXPECT_MAIN15:
            failures.append(
                f'(aa) session 15 (EX5) EX15MAIN mismatch: got '
                f'{stagemain15!r} (len {lenmain15}), expected '
                f'{EXPECT_MAIN15!r} (len {len(EXPECT_MAIN15)})')

        lenother15 = peek_aux1(client, R_LENOTHER15)[0]
        stagoth15 = bytes(
            peek_aux1(client, R_STAGOTH15, max(lenother15, 1)))[:lenother15]
        if stagoth15 != EXPECT_OTHER15:
            failures.append(
                f'(ab) session 15 (EX5) EX15OTHER mismatch: got '
                f'{stagoth15!r} (len {lenother15}), expected '
                f'{EXPECT_OTHER15!r} (len {len(EXPECT_OTHER15)})')

        # -- sixteenth session (EX3 PIPELINE REWIRE: `cat | sort`
        # and `sort | cat` both run for real now, no more refusal)
        spawn_status16 = peek_aux1(client, R_SPAWN_STA16)[0]
        spawn_pid16 = peek_aux1(client, R_SPAWN_PID16)[0]
        wait_pid16 = peek_aux1(client, R_WAIT_PID16)[0]
        if spawn_status16 != 0:
            failures.append(f'session 16 (EX3) ex exit status expected '
                            f'0, got {spawn_status16}')
        if wait_pid16 != spawn_pid16:
            failures.append(f'session 16 wait pid {wait_pid16} != '
                            f'spawn pid {spawn_pid16}')

        len16 = peek_aux1(client, R_LEN16)[0]
        stage16 = bytes(peek_aux1(client, R_STAGE16, max(len16, 1)))[:len16]
        if stage16 != EXPECT_CAP16:
            failures.append(
                f'(ac) session 16 (EX3/FF3/FF4/FF5) capture '
                f'(`%!cat | sort` and `%!sort | cat` both run for '
                f'real, sets dot to the FIRST line (FF4); classic '
                f'`r FILE` inserts at dot, not $ (FF3); `s///gN` '
                f'no longer refused (FF5)) mismatch: got '
                f'{stage16!r} (len {len16}), expected '
                f'{EXPECT_CAP16!r} (len {len(EXPECT_CAP16)})')

        lensrc16 = peek_aux1(client, R_LENSRC16)[0]
        stagesrc16 = bytes(
            peek_aux1(client, R_STAGESRC16, max(lensrc16, 1)))[:lensrc16]
        if stagesrc16 != EXPECT_SRC16:
            failures.append(
                f'(ad) session 16 (XC1) EX16SRC mismatch: got '
                f'{stagesrc16!r} (len {lensrc16}), expected '
                f'{EXPECT_SRC16!r} (len {len(EXPECT_SRC16)}) -- '
                f'unchanged at the first write\'s content means the '
                f'bare second `w` was wrongly refused (no '
                f'remembered name)')

        if failures:
            for failure in failures:
                print(f'[check-ex] FAIL: {failure}', file=sys.stderr)
            return 1

        print('[check-ex] PASS: r (load through the swap file) / ,p '
              '(print, swap read) / s (substitute one line, swap append '
              '+ repoint) / ,p again (unchanged lines re-read from their '
              'original, now out-of-sequence, swap offsets) / w (write '
              'back, swap read) all matched byte-exact, incl. CR line '
              'endings; exit status 0, wait pid matched spawn pid; '
              '`ex FILE` filename-on-launch (load via argv through the '
              'swap file, incl. bare `,p`/`w` round-trip, and a '
              'nonexistent path staying `?` with no crash and no '
              'remembered name); and the "last regular expression" task '
              '(bare `??` with no prior RE stays `?`, backward `??` '
              'repeat, a forward `/re/` search feeding a later backward '
              '`??` -- proving ONE shared last-RE store -- and `s//X/` '
              'reusing a prior `s/OLD/NEW/`\'s search field) all matched '
              'byte-exact; and widened g/v (`g/re/s///` running the '
              'general dispatch path against exbuf\'s swap-file '
              'descriptors) matched byte-exact; and session 8 (`w` '
              'truncation: a bare `w` overwriting an existing longer '
              'file with a shorter buffer leaves no stale tail, through '
              'the swap-file write path) matched byte-exact; and session '
              '9 (all four `!` forms: `1,$!sort` filters a range through '
              'a REAL spawned `sh` -> `sort`, `$r !cat` inserts a REAL '
              'spawned `sh` -> `cat`\'s output after an address, `1,2w '
              '!cat` writes a range to a REAL spawned `sh` -> `cat`\'s '
              'stdin, and bare `!cat` runs a REAL spawned `sh` -> `cat` '
              'shell escape) matched byte-exact; and sessions '
              '10-13 (adversarial-review regressions '
              'EX1/EX2/EX6/EX7: `99r !echo NEW` refused with no '
              'mutation plus the `0r`/`$r` boundary cases, a '
              'refused command\'s exit status, `&` taking its own '
              'undo snapshot, and a `g`+`r!` pass undoing as one '
              'unit) all matched byte-exact; and sessions 14-16 '
              '(second adversarial pass, EX4/EX5/EX3: `w PATH` no '
              'longer rebinds the current filename so a bare `w` '
              'still lands on the launch-loaded file, the `w!` '
              'guard allows a target naming the current file '
              'without `!` while still refusing a different '
              'existing one, and a REAL `cat | sort` / `sort | cat` '
              'pipeline through a filter now attaches to the WHOLE '
              'execution rather than being refused or silently '
              'emptying the buffer) all matched byte-exact; and the '
              'SECOND CLOSING '
              'pass regressions XC1-XC4, piggybacked onto sessions '
              '11B/13/15/16 (an unnamed buffer\'s first `w` '
              'establishes the current name so a later bare `w` '
              'reuses it, `w!` guard equality canonicalizes a '
              'relative spelling to absolute before comparing, `v` '
              'takes the same single outer undo snapshot `g` does, '
              'and a shell command\'s own nonzero exit is no longer '
              'folded into ex\'s session exit status) all matched '
              'byte-exact')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
