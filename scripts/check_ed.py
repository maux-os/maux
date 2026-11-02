#!/usr/bin/env python3
"""Boot and verify `make check-ed` -- src/test/edtest.s's ed integration
gate (fileprocess harness pattern, scripts/check_fileprocess.py's own
structure). Asserts, byte-exact including CR ($8D) line endings:

  (a) session 1 (`a` three lines -- two containing BANK -- `.`,
      `w /mnt/MAUX/EDFILE`, `q`, fed on fd 0) produced the expected
      /mnt/MAUX/EDFILE content.
  (b) session 2's `g/BANK/p` (fd 1 redirected) printed exactly the two
      BANK lines, in order.
  (c) session 2's `3s/BANK/&X/` + `w /mnt/MAUX/EDFILE2` round-trip produced
      the expected rewritten file (only line 3 changed, "BANK" -> "BANKX").

2026-08-19 audit-fix phases (session 3 = findings 1, 2, 4, 5, 6; session 4
= finding 3's cold/negative case) -- see T.EDTEST.TXT and the task report
for the full per-command trace. Session 3's 31-line capture and session
4's 1-line capture were both derived by running the (believed-correct)
fixed ed.bin once and reading back the real bytes, then hand-verified
line by line against classic ed semantics -- not typed in blind.

  (g)/(h) session 5 (task: "ed grows j and =") -- `j` (join) and `=`
      (print line number), added the same round. Covers a 2-line join,
      a 3-line join, `=` with and without an explicit address (and
      proves `=` never moves `.` or touches the buffer), and a
      single-address `j` (the file header's documented NO-OP case).
      See src/test/edtestb.s's EDSCR5_TEXT for the per-command trace;
      EXPECT_SESSION5/EXPECT_EDFILE5 below were captured the same way
      as sessions 3/4 (run once, read back, hand-verify).

2026-09-06 (EX2, the ex/ed session-status fix): sessions 3, 4, 6b, 7
and 8 each contain a DELIBERATE `?`-producing command (a malformed
`s` flag, a negative-case bare `w`, a launch-load of a nonexistent
path, an empty `//` with no prior pattern, `g` nested inside `g`) in
an otherwise-successful script. Before EX2, `ed`'s exit status was
always 0 regardless -- a refused command had no observable status at
all. EX2 gives `ed` the same session-error byte ex/vi now carry
(edfile.s's ED_CMD_Q, edparse.s's ED_ERR/ED_DOEXIT0): once ANY
command in the session hits `?`, the final `q` exits 1, matching
this host's own `/bin/ed` (confirmed empirically: piping the
equivalent scripts through it also yields a nonzero exit, though
that ed's own value is 2 -- only "nonzero" is asserted here). The
five status checks below were updated from 0 to 1 for exactly this
reason; nothing else about these sessions' expected output changed.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'ed.po')

R_LEN1    = 0x1200
R_STAGE1  = 0x1210
R_SPAWN1_PID    = 0x1250
R_SPAWN1_STATUS = 0x1251
R_WAIT1_PID     = 0x1252

R_LEN2A   = 0x1260
R_STAGE2A = 0x1270
R_LEN2B   = 0x12B0
R_STAGE2B = 0x12C0
R_SPAWN2_PID    = 0x1300
R_SPAWN2_STATUS = 0x1301
R_WAIT2_PID     = 0x1302

R_DONE = 0x12F0
R_ERR  = 0x12F1
R_STEP = 0x12F2

# 2026-08-19 audit-fix phases
R_LEN3    = 0x1310
R_STAGE3  = 0x1320
R_LEN3B   = 0x141A
R_STAGE3B = 0x1420
R_SPAWN3_PID    = 0x1480
R_SPAWN3_STATUS = 0x1481
R_WAIT3_PID     = 0x1482

R_LEN4    = 0x1490
R_STAGE4  = 0x14A0
R_SPAWN4_PID    = 0x14D0
R_SPAWN4_STATUS = 0x14D1
R_WAIT4_PID     = 0x14D2

# Session 5: `j` (join) and `=` (print line number) -- see
# src/test/edtestb.s's EDSCR5_TEXT for the full per-command trace.
R_LEN5    = 0x1500
R_STAGE5  = 0x1510
R_LEN5B   = 0x1590
R_STAGE5B = 0x15A0
R_SPAWN5_PID    = 0x15D0
R_SPAWN5_STATUS = 0x15D1
R_WAIT5_PID     = 0x15D2

# Session 6 (2026-09-02, filename-on-launch task): `ed FILE` loads FILE at
# startup instead of a bare launch + `r` -- see src/test/edtestb.s's own
# Session 6a/6b comments for the full per-command trace.
R_LEN6    = 0x1600
R_STAGE6  = 0x1610
R_LEN6B   = 0x1650
R_STAGE6B = 0x1660
R_SPAWN6_PID    = 0x1690
R_SPAWN6_STATUS = 0x1691
R_WAIT6_PID     = 0x1692

R_LEN6N   = 0x16A0
R_STAGE6N = 0x16B0
R_SPAWN6N_PID    = 0x16D0
R_SPAWN6N_STATUS = 0x16D1
R_WAIT6N_PID     = 0x16D2

# Session 7 (2026-09-02, "last regular expression" task) -- see
# src/test/edtestb2.s's own EDSCR7_TEXT comment for the full
# per-command trace.
R_LEN7    = 0x1700
R_STAGE7  = 0x1710
R_LEN7B   = 0x1780
R_STAGE7B = 0x1790
R_SPAWN7_PID    = 0x17E0
R_SPAWN7_STATUS = 0x17E1
R_WAIT7_PID     = 0x17E2

# Session 8 (2026-09-02, widened g/v task; grown for FF1
# 2026-09-06 -- see src/test/edtestb2.s's own relocation comment)
R_LEN8    = 0x1800
R_STAGE8  = 0x1810
R_LEN8B   = 0x1900
R_STAGE8B = 0x1908
R_SPAWN8_PID    = 0x1970
R_SPAWN8_STATUS = 0x1971
R_WAIT8_PID     = 0x1972

# Session 9 (2026-09-02, `w` truncation bug fix)
R_LEN9    = 0x1A00
R_STAGE9  = 0x1A10
R_LEN9O   = 0x1A70
R_SPAWN9_PID    = 0x1A80
R_SPAWN9_STATUS = 0x1A81
R_WAIT9_PID     = 0x1A82

# Session 10 (XC1, 2026-09-06, second closing pass): an unnamed
# buffer's first `w` must establish the current name so a later bare `w`
# reuses it -- restores the coverage EX4's own test rework (session 9's
# two explicit `w /mnt/MAUX/EDFILE9` lines) dropped.
R_LEN10O  = 0x1B00
R_STAGE10O = 0x1B08
R_LEN10   = 0x1B20
R_STAGE10 = 0x1B28
R_SPAWN10_PID    = 0x1B40
R_SPAWN10_STATUS = 0x1B41
R_WAIT10_PID     = 0x1B42

CR = 0x8D


def hitext(s):
    """A liba string, high-bit-set per byte (ed's own file/line encoding)."""
    return bytes(b | 0x80 for b in s.encode('ascii'))


EXPECT_EDFILE = (hitext('alpha one') + bytes([CR]) +
                  hitext('BANK two') + bytes([CR]) +
                  hitext('BANK three') + bytes([CR]))

EXPECT_GREP = (hitext('BANK two') + bytes([CR]) +
               hitext('BANK three') + bytes([CR]))

EXPECT_EDFILE2 = (hitext('alpha one') + bytes([CR]) +
                   hitext('BANK two') + bytes([CR]) +
                   hitext('BANKX three') + bytes([CR]))


def hilines(*lines):
    """Join hitext(line)+CR for each line -- ed's own print/error output
    shape (every PUTLINE and ED_ERR call ends in one CR, $8D)."""
    out = b''
    for line in lines:
        out += hitext(line) + bytes([CR])
    return out


# Session 3 (findings 1, 2, 4, 5, 6) -- one buffer (`a` xxxxx/alpha/BETA/
# gamma/delta), one capture. Per-command trace (EDSCR3_TEXT,
# src/test/edtestb.s):
#   1s/x/Y/2      -> (no output) line1 "xxxxx" -> "xYxxx" (finding 1: the
#                    2nd occurrence of `x`, not the 1st)
#   1p            -> "xYxxx"
#   1s/x/Y/z      -> "?"   (finding 1: an unrecognized flag is now a
#                    hard error, not silently ignored)
#   3p            -> "BETA"           (marker -- sets dot=3)
#   /zzz/p        -> "?"   (finding 2: no match anywhere -> hard error,
#                    never a phantom `.,.` default)
#   p             -> "BETA"           (finding 2: dot is STILL 3 -- the
#                    failed search didn't move it)
#   3             -> "BETA"           (finding 5: bare address = implicit p)
#   ;p            -> "BETA","gamma","delta"   (finding 6: bare `;` = `.,$`)
#   1,2;3p        -> "?"   (regression guard: an audited case from the
#                    original audit -- a `;` used as leftover garbage
#                    after a REAL two-address parse, not the fully-bare
#                    shorthand, must still be a hard error, not the new
#                    bare-address-implies-p path)
#   4,5t1         -> (no output) copies lines 4,5 ("gamma","delta") to
#                    right after line 1, in order (finding 4, `t`)
#   ,p            -> "xYxxx","gamma","delta","alpha","BETA","gamma","delta"
#                    (finding 6: bare `,` = `1,$`, and proves `t` copied
#                    in order without disturbing the originals)
#   6,7m0         -> (no output) moves the ORIGINAL "gamma","delta"
#                    (now lines 6,7) to before line 1 (finding 4, `m`)
#   ,p            -> "gamma","delta","xYxxx","gamma","delta","alpha","BETA"
#   1,2m1         -> "?"   (finding 4: `m` into its own source range)
#   ,p            -> SAME 7 lines again (proves the erroring `m` left the
#                    buffer untouched)
#   1,2m7         -> (no output) moves lines 1,2 ("gamma","delta") to
#                    right after line 7 -- ED_DOMOVE's OTHER direction
#                    (dest past the block, not before it)
#   ,p            -> "xYxxx","gamma","delta","alpha","BETA","gamma","delta"
#   w /mnt/MAUX/EDFILE3  -> (no output) remembers the name
#   $a / omega / .    -> (no output) appends an 8th line
#   w             -> (no output) bare `w` reuses the remembered name --
#                    finding 3's POSITIVE case, verified via EDFILE3's
#                    own content below (must include "omega", proving it
#                    wrote the CURRENT buffer, not a stale copy)
#   q
EXPECT_SESSION3 = hilines(
    'xYxxx', '?', 'BETA', '?', 'BETA', 'BETA',
    'BETA', 'gamma', 'delta',
    '?',
    'xYxxx', 'gamma', 'delta', 'alpha', 'BETA', 'gamma', 'delta',
    'gamma', 'delta', 'xYxxx', 'gamma', 'delta', 'alpha', 'BETA',
    '?',
    'gamma', 'delta', 'xYxxx', 'gamma', 'delta', 'alpha', 'BETA',
    'xYxxx', 'gamma', 'delta', 'alpha', 'BETA', 'gamma', 'delta',
)

# /mnt/MAUX/EDFILE3 after the bare `w` -- 8 lines, "omega" included (finding
# 3's proof that a bare w writes the CURRENT buffer, not a stale one).
EXPECT_EDFILE3 = hilines(
    'xYxxx', 'gamma', 'delta', 'alpha', 'BETA', 'gamma', 'delta', 'omega',
)

# Session 4 (finding 3's negative case): a FRESH ed process, no prior
# r/w, so nothing is remembered yet -- bare `w` must stay `?`.
EXPECT_SESSION4 = hilines('?')

# Session 5 (task: "ed grows j and ="): 1,2j (2-line join), 2,4j (3-line
# join), = with and without an address, and 1j (single-address j -- the
# file header's chosen NO-OP semantics). Trace in edtestb.s's EDSCR5_TEXT
# comment. Captured once from a believed-correct ed.bin, then hand-
# verified line by line against the trace before being pinned here --
# same posture as EXPECT_SESSION3/EXPECT_SESSION4 above.
EXPECT_SESSION5 = hilines(
    'L1L2', '4', 'L3L4L5', '1', 'L3L4L5', 'L1L2', 'L1L2L3L4L5',
    'L1L2L3L4L5',
)
EXPECT_EDFILE5 = hitext('L1L2L3L4L5') + bytes([CR])

# Session 6a (filename-on-launch, positive case): `ed
# /mnt/MAUX/EDFILE6` loads "first"/"second"/"third" at STARTUP (no
# `r` in EDSCR6_TEXT), `,p` prints all three, and a bare `w`
# (no filename token) writes them straight back -- proving the
# launch load set the remembered filename to EDFILE6 itself.
EXPECT_EDOUT6 = hilines('first', 'second', 'third')
EXPECT_EDFILE6_W = (hitext('first') + bytes([CR]) +
                     hitext('second') + bytes([CR]) +
                     hitext('third') + bytes([CR]))

# Session 6b (filename-on-launch, negative case): `ed
# /mnt/MAUX/EDNOSUCH6` -- the path does not exist. The open failure
# at startup prints `?` (ED_ERR, the same path `e NOSUCHFILE`
# takes) and does NOT remember the name, so the script's own
# bare `w` (EDSCR6N_TEXT) prints a SECOND `?` -- finding 3's cold
# case, reached this time via a failed launch load instead of a
# fresh process with no r/w yet.
EXPECT_EDCAP6N = hilines('?', '?')

# Session 7 (2026-09-02, "last regular expression" task,
# learning:01M1FX8HT89CKR9CB8T8VKCW1S): buffer is 6 lines, "BANK" on
# 1 and 3, "OLD..." on 5 and 6, dot=6 after `a`. Trace (src/test/
# edtestb2.s's own EDSCR7_TEXT comment has the line-by-line derivation):
#   //             -> "?"   no prior RE yet -- NOT a crash, NOT
#                    "empty pattern matches everything"
#   /BANK/p        -> "BANK one"      forward search wraps from dot=6
#                    to line 1; dot=1, LASTPAT="BANK"
#   //             -> "BANK three"    bare repeat reuses LASTPAT=
#                    "BANK", finds the NEXT one from dot=1; dot=3
#                    (PROVES forward `//` repeat)
#   /OLDthing/p    -> "OLDthing here"   forward search from dot=3;
#                    dot=5, LASTPAT="OLDthing"
#   g//p           -> "OLDthing here","OLDthing again"   g's empty
#                    search field reuses LASTPAT="OLDthing" over its
#                    default 1,$ range (PROVES `g//` reuse -- the
#                    fourth call site)
#   5s/OLD/NEW/    -> (no output) line5 -> "NEWthing here"; LASTPAT="OLD"
#   5p             -> "NEWthing here"
#   6s//XXX/       -> (no output) empty search field reuses LASTPAT=
#                    "OLD"; line6 -> "XXXthing again" (PROVES `s//` reuse)
#   6p             -> "XXXthing again"
#   w /mnt/MAUX/EDFILE7, q
EXPECT_SESSION7 = hilines(
    '?', 'BANK one', 'BANK three', 'OLDthing here', 'OLDthing here',
    'OLDthing again', 'NEWthing here', 'XXXthing again',
)
EXPECT_EDFILE7 = hilines(
    'BANK one', 'xxxxx two', 'BANK three', 'yyyyy four',
    'NEWthing here', 'XXXthing again',
)

# Session 8 (2026-09-02, widened g/v task,
# learning:01M1FX8HT89CKR9CB8T8VKCW1S): buffer is 5 lines, "BANK"
# on 1/3/5. Trace (src/test/edtestb2.s's own EDSCR8_TEXT comment
# has the line-by-line derivation):
#   g/BANK/s/BANK/GONE/ -> (no output) general dispatch runs
#                        `s` (not p/d) on lines 1,3,5
#   ,p                  -> "GONE one","plain two","GONE
#                        three","plain four","GONE five"
#   g/plain/d           -> (no output) deletes lines matching
#                        "plain" (renumber-safety)
#   ,p                  -> "GONE one","GONE three","GONE five"
#   v/three/p           -> "GONE one","GONE five"
#   g/GONE/g/x/p        -> "?" (g inside cmds refused, no
#                        mutation)
#   ,p                  -> "GONE one","GONE three","GONE five"
#   g/GONE/u            -> "?" (u inside cmds refused, no
#                        mutation)
#   ,p                  -> "GONE one","GONE three","GONE five"
#   g/GONE/r EDFIX1     -> FF1 2026-09-06 (review,
#                        src/test/edtestb2.s's own EDSCR8_TEXT
#                        comment has the full per-iteration
#                        derivation): (no output) classic `r`
#                        (no address) appends at $, re-evaluated
#                        fresh each pass-2 iteration -- all
#                        THREE inserts land at the growing end,
#                        in order. EDFIX1's own line ("EDFIXLINE",
#                        9 chars) is long enough to reach cmds'
#                        own start in CMDBUF for a "g/GONE/"
#                        (7-char) prefix -- this is the FF1
#                        regression: pre-fix, match 1's own read
#                        clobbers the command-list bytes matches
#                        2/3 still need.
#   ,p                  -> "GONE one","GONE three","GONE five",
#                        "EDFIXLINE","EDFIXLINE","EDFIXLINE"
#   w /mnt/MAUX/EDFILE8, q
EXPECT_SESSION8 = hilines(
    'GONE one', 'plain two', 'GONE three', 'plain four', 'GONE five',
    'GONE one', 'GONE three', 'GONE five',
    'GONE one', 'GONE five',
    '?',
    'GONE one', 'GONE three', 'GONE five',
    '?',
    'GONE one', 'GONE three', 'GONE five',
    'GONE one', 'GONE three', 'GONE five',
    'EDFIXLINE', 'EDFIXLINE', 'EDFIXLINE',
)
EXPECT_EDFILE8 = hilines(
    'GONE one', 'GONE three', 'GONE five',
    'EDFIXLINE', 'EDFIXLINE', 'EDFIXLINE',
)

# Session 9 (2026-09-02, `w` truncation bug fix): a 6-line ("long")
# buffer is written to EDFILE9 first (90 bytes), then the buffer is
# emptied and replaced with a 2-line ("short") one, and a bare `w`
# (reusing the remembered name) overwrites EDFILE9 again. The file
# must end up EXACTLY the short content -- no stale tail from the
# long write. Pre-fix, ProDOS's OPEN does not truncate, so EDFILE9's
# EOF stayed at 90 and the re-read below would come back 90 bytes
# long with 84 stale bytes past "T1\rT2\r".
EXPECT_EDFILE9 = hilines('T1', 'T2')

# Session 10 (XC1, 2026-09-06): ED10FRESH after the unnamed buffer's
# first `w` (establishes the name) and edited bare second `w` (reuses
# it) -- "old" -> "new" via `1s/old/new/`.
EXPECT_ED10FRESH = hilines('new')


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
        print(f'error: {disk} not found -- run make ed-image first',
              file=sys.stderr)
        return 2

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-ed] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-ed] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        done = 0
        for i in range(600):
            client.call_tool('step', {'cycles': 200_000})
            done = peek_aux1(client, R_DONE)[0]
            if done in (0xAA, 0xEE):
                break
        err = peek_aux1(client, R_ERR)[0]
        step = peek_aux1(client, R_STEP)[0]
        print(f'[check-ed] done=${done:02X} err=${err:02X} step=${step:02X}')

        failures = []
        if done != 0xAA:
            failures.append(f'test did not finish successfully '
                            f'(done=${done:02X}, err=${err:02X}, step={step})')
            for failure in failures:
                print(f'[check-ed] FAIL: {failure}', file=sys.stderr)
            return 1

        spawn1_status = peek_aux1(client, R_SPAWN1_STATUS)[0]
        spawn2_status = peek_aux1(client, R_SPAWN2_STATUS)[0]
        spawn1_pid = peek_aux1(client, R_SPAWN1_PID)[0]
        wait1_pid = peek_aux1(client, R_WAIT1_PID)[0]
        spawn2_pid = peek_aux1(client, R_SPAWN2_PID)[0]
        wait2_pid = peek_aux1(client, R_WAIT2_PID)[0]

        if spawn1_status != 0:
            failures.append(f'session 1 ed exit status expected 0, got '
                            f'{spawn1_status}')
        if wait1_pid != spawn1_pid:
            failures.append(f'session 1 wait pid {wait1_pid} != spawn pid '
                            f'{spawn1_pid}')
        if spawn2_status != 0:
            failures.append(f'session 2 ed exit status expected 0, got '
                            f'{spawn2_status}')
        if wait2_pid != spawn2_pid:
            failures.append(f'session 2 wait pid {wait2_pid} != spawn pid '
                            f'{spawn2_pid}')

        len1 = peek_aux1(client, R_LEN1)[0]
        stage1 = bytes(peek_aux1(client, R_STAGE1, max(len1, 1)))[:len1]
        if stage1 != EXPECT_EDFILE:
            failures.append(
                f'(a) /mnt/MAUX/EDFILE mismatch: got {stage1!r} '
                f'(len {len1}), expected {EXPECT_EDFILE!r} '
                f'(len {len(EXPECT_EDFILE)})')

        len2a = peek_aux1(client, R_LEN2A)[0]
        stage2a = bytes(peek_aux1(client, R_STAGE2A, max(len2a, 1)))[:len2a]
        if stage2a != EXPECT_GREP:
            failures.append(
                f'(b) g/BANK/p output mismatch: got {stage2a!r} '
                f'(len {len2a}), expected {EXPECT_GREP!r} '
                f'(len {len(EXPECT_GREP)})')

        len2b = peek_aux1(client, R_LEN2B)[0]
        stage2b = bytes(peek_aux1(client, R_STAGE2B, max(len2b, 1)))[:len2b]
        if stage2b != EXPECT_EDFILE2:
            failures.append(
                f'(c) /mnt/MAUX/EDFILE2 (s/RE/&X/ round-trip) mismatch: got '
                f'{stage2b!r} (len {len2b}), expected {EXPECT_EDFILE2!r} '
                f'(len {len(EXPECT_EDFILE2)})')

        # 2026-08-19 audit-fix phases (findings 1-6)
        spawn3_status = peek_aux1(client, R_SPAWN3_STATUS)[0]
        spawn3_pid = peek_aux1(client, R_SPAWN3_PID)[0]
        wait3_pid = peek_aux1(client, R_WAIT3_PID)[0]
        spawn4_status = peek_aux1(client, R_SPAWN4_STATUS)[0]
        spawn4_pid = peek_aux1(client, R_SPAWN4_PID)[0]
        wait4_pid = peek_aux1(client, R_WAIT4_PID)[0]
        spawn5_status = peek_aux1(client, R_SPAWN5_STATUS)[0]
        spawn5_pid = peek_aux1(client, R_SPAWN5_PID)[0]
        wait5_pid = peek_aux1(client, R_WAIT5_PID)[0]
        if spawn3_status != 1:
            failures.append(f'session 3 ed exit status expected 1, got '
                            f'{spawn3_status}')
        if wait3_pid != spawn3_pid:
            failures.append(f'session 3 wait pid {wait3_pid} != spawn pid '
                            f'{spawn3_pid}')
        if spawn4_status != 1:
            failures.append(f'session 4 ed exit status expected 1, got '
                            f'{spawn4_status}')
        if wait4_pid != spawn4_pid:
            failures.append(f'session 4 wait pid {wait4_pid} != spawn pid '
                            f'{spawn4_pid}')
        if spawn5_status != 0:
            failures.append(f'session 5 ed exit status expected 0, got '
                            f'{spawn5_status}')
        if wait5_pid != spawn5_pid:
            failures.append(f'session 5 wait pid {wait5_pid} != spawn pid '
                            f'{spawn5_pid}')

        len3 = peek_aux1(client, R_LEN3)[0]
        stage3 = bytes(peek_aux1(client, R_STAGE3, max(len3, 1)))[:len3]
        if stage3 != EXPECT_SESSION3:
            failures.append(
                f'(d) session 3 capture mismatch (findings 1/2/4/5/6): '
                f'got {stage3!r} (len {len3}), expected '
                f'{EXPECT_SESSION3!r} (len {len(EXPECT_SESSION3)})')

        len3b = peek_aux1(client, R_LEN3B)[0]
        stage3b = bytes(peek_aux1(client, R_STAGE3B, max(len3b, 1)))[:len3b]
        if stage3b != EXPECT_EDFILE3:
            failures.append(
                f'(e) /mnt/MAUX/EDFILE3 (bare `w` reuse, finding 3 positive '
                f'case) mismatch: got {stage3b!r} (len {len3b}), expected '
                f'{EXPECT_EDFILE3!r} (len {len(EXPECT_EDFILE3)})')

        len4 = peek_aux1(client, R_LEN4)[0]
        stage4 = bytes(peek_aux1(client, R_STAGE4, max(len4, 1)))[:len4]
        if stage4 != EXPECT_SESSION4:
            failures.append(
                f'(f) session 4 capture (finding 3 negative case, cold '
                f'bare `w`) mismatch: got {stage4!r} (len {len4}), '
                f'expected {EXPECT_SESSION4!r} (len {len(EXPECT_SESSION4)})')

        len5 = peek_aux1(client, R_LEN5)[0]
        stage5 = bytes(peek_aux1(client, R_STAGE5, max(len5, 1)))[:len5]
        if stage5 != EXPECT_SESSION5:
            failures.append(
                f'(g) session 5 capture (j/=) mismatch: got {stage5!r} '
                f'(len {len5}), expected {EXPECT_SESSION5!r} '
                f'(len {len(EXPECT_SESSION5)})')

        len5b = peek_aux1(client, R_LEN5B)[0]
        stage5b = bytes(peek_aux1(client, R_STAGE5B, max(len5b, 1)))[:len5b]
        if stage5b != EXPECT_EDFILE5:
            failures.append(
                f'(h) /mnt/MAUX/EDFILE5 (j round-trip) mismatch: got '
                f'{stage5b!r} (len {len5b}), expected {EXPECT_EDFILE5!r} '
                f'(len {len(EXPECT_EDFILE5)})')

        # Session 6 (filename-on-launch task, 2026-09-02)
        spawn6_status = peek_aux1(client, R_SPAWN6_STATUS)[0]
        spawn6_pid = peek_aux1(client, R_SPAWN6_PID)[0]
        wait6_pid = peek_aux1(client, R_WAIT6_PID)[0]
        spawn6n_status = peek_aux1(client, R_SPAWN6N_STATUS)[0]
        spawn6n_pid = peek_aux1(client, R_SPAWN6N_PID)[0]
        wait6n_pid = peek_aux1(client, R_WAIT6N_PID)[0]
        if spawn6_status != 0:
            failures.append(f'session 6a ed exit status expected 0, got '
                            f'{spawn6_status}')
        if wait6_pid != spawn6_pid:
            failures.append(f'session 6a wait pid {wait6_pid} != spawn pid '
                            f'{spawn6_pid}')
        if spawn6n_status != 1:
            failures.append(f'session 6b ed exit status expected 1, got '
                            f'{spawn6n_status}')
        if wait6n_pid != spawn6n_pid:
            failures.append(f'session 6b wait pid {wait6n_pid} != spawn '
                            f'pid {spawn6n_pid}')

        len6 = peek_aux1(client, R_LEN6)[0]
        stage6 = bytes(peek_aux1(client, R_STAGE6, max(len6, 1)))[:len6]
        if stage6 != EXPECT_EDOUT6:
            failures.append(
                f'(i) session 6a `ed /mnt/MAUX/EDFILE6` launch-load `,p` '
                f'mismatch: got {stage6!r} (len {len6}), expected '
                f'{EXPECT_EDOUT6!r} (len {len(EXPECT_EDOUT6)})')

        len6b = peek_aux1(client, R_LEN6B)[0]
        stage6b = bytes(peek_aux1(client, R_STAGE6B, max(len6b, 1)))[:len6b]
        if stage6b != EXPECT_EDFILE6_W:
            failures.append(
                f'(j) /mnt/MAUX/EDFILE6 (bare `w` after launch-load) '
                f'mismatch: got {stage6b!r} (len {len6b}), expected '
                f'{EXPECT_EDFILE6_W!r} (len {len(EXPECT_EDFILE6_W)})')

        len6n = peek_aux1(client, R_LEN6N)[0]
        stage6n = bytes(peek_aux1(client, R_STAGE6N, max(len6n, 1)))[:len6n]
        if stage6n != EXPECT_EDCAP6N:
            failures.append(
                f'(k) session 6b `ed /mnt/MAUX/EDNOSUCH6` (launch-load of a '
                f'nonexistent path) mismatch: got {stage6n!r} '
                f'(len {len6n}), expected {EXPECT_EDCAP6N!r} '
                f'(len {len(EXPECT_EDCAP6N)})')

        # Session 7 ("last regular expression" task, 2026-09-02)
        spawn7_status = peek_aux1(client, R_SPAWN7_STATUS)[0]
        spawn7_pid = peek_aux1(client, R_SPAWN7_PID)[0]
        wait7_pid = peek_aux1(client, R_WAIT7_PID)[0]
        if spawn7_status != 1:
            failures.append(f'session 7 ed exit status expected 1, got '
                            f'{spawn7_status}')
        if wait7_pid != spawn7_pid:
            failures.append(f'session 7 wait pid {wait7_pid} != spawn pid '
                            f'{spawn7_pid}')

        len7 = peek_aux1(client, R_LEN7)[0]
        stage7 = bytes(peek_aux1(client, R_STAGE7, max(len7, 1)))[:len7]
        if stage7 != EXPECT_SESSION7:
            failures.append(
                f'(l) session 7 capture ("last regular expression") '
                f'mismatch: got {stage7!r} (len {len7}), expected '
                f'{EXPECT_SESSION7!r} (len {len(EXPECT_SESSION7)})')

        len7b = peek_aux1(client, R_LEN7B)[0]
        stage7b = bytes(peek_aux1(client, R_STAGE7B, max(len7b, 1)))[:len7b]
        if stage7b != EXPECT_EDFILE7:
            failures.append(
                f'(m) /mnt/MAUX/EDFILE7 (post-s// round-trip) mismatch: got '
                f'{stage7b!r} (len {len7b}), expected {EXPECT_EDFILE7!r} '
                f'(len {len(EXPECT_EDFILE7)})')

        # Session 8 (widened g/v task, 2026-09-02)
        spawn8_status = peek_aux1(client, R_SPAWN8_STATUS)[0]
        spawn8_pid = peek_aux1(client, R_SPAWN8_PID)[0]
        wait8_pid = peek_aux1(client, R_WAIT8_PID)[0]
        if spawn8_status != 1:
            failures.append(f'session 8 ed exit status expected 1, got '
                            f'{spawn8_status}')
        if wait8_pid != spawn8_pid:
            failures.append(f'session 8 wait pid {wait8_pid} != spawn pid '
                            f'{spawn8_pid}')

        len8 = peek_aux1(client, R_LEN8)[0]
        stage8 = bytes(peek_aux1(client, R_STAGE8, max(len8, 1)))[:len8]
        if stage8 != EXPECT_SESSION8:
            failures.append(
                f'(n) session 8 capture (widened g/v) mismatch: got '
                f'{stage8!r} (len {len8}), expected {EXPECT_SESSION8!r} '
                f'(len {len(EXPECT_SESSION8)})')

        len8b = peek_aux1(client, R_LEN8B)[0]
        stage8b = bytes(peek_aux1(client, R_STAGE8B, max(len8b, 1)))[:len8b]
        if stage8b != EXPECT_EDFILE8:
            failures.append(
                f'(o) /mnt/MAUX/EDFILE8 (post-g/re/s+g/re/d round-trip) '
                f'mismatch: got {stage8b!r} (len {len8b}), expected '
                f'{EXPECT_EDFILE8!r} (len {len(EXPECT_EDFILE8)})')

        # Session 9 (`w` truncation bug fix, 2026-09-02)
        spawn9_status = peek_aux1(client, R_SPAWN9_STATUS)[0]
        spawn9_pid = peek_aux1(client, R_SPAWN9_PID)[0]
        wait9_pid = peek_aux1(client, R_WAIT9_PID)[0]
        if spawn9_status != 0:
            failures.append(f'session 9 ed exit status expected 0, got '
                            f'{spawn9_status}')
        if wait9_pid != spawn9_pid:
            failures.append(f'session 9 wait pid {wait9_pid} != spawn '
                            f'pid {spawn9_pid}')

        len9o = peek_aux1(client, R_LEN9O)[0]
        if len9o != 0:
            failures.append(
                f'session 9 script unexpectedly printed something '
                f'(len {len9o}) -- EDSCR9_TEXT has no `p` commands, so '
                f'EDOUT9 must stay empty')

        len9 = peek_aux1(client, R_LEN9)[0]
        stage9 = bytes(peek_aux1(client, R_STAGE9, max(len9, 1)))[:len9]
        if stage9 != EXPECT_EDFILE9:
            failures.append(
                f'(p) /mnt/MAUX/EDFILE9 (`w` truncation) mismatch: got '
                f'{stage9!r} (len {len9}), expected {EXPECT_EDFILE9!r} '
                f'(len {len(EXPECT_EDFILE9)}) -- a longer len than '
                f'expected means ED_DOWRITE left a stale tail from the '
                f'earlier long write (missing SET_EOF)')

        # Session 10 (XC1, 2026-09-06): unnamed buffer, first `w`
        # establishes the current name, bare second `w` reuses it.
        spawn10_status = peek_aux1(client, R_SPAWN10_STATUS)[0]
        spawn10_pid = peek_aux1(client, R_SPAWN10_PID)[0]
        wait10_pid = peek_aux1(client, R_WAIT10_PID)[0]
        if spawn10_status != 0:
            failures.append(f'session 10 (XC1) ed exit status expected '
                            f'0, got {spawn10_status}')
        if wait10_pid != spawn10_pid:
            failures.append(f'session 10 wait pid {wait10_pid} != '
                            f'spawn pid {spawn10_pid}')

        len10o = peek_aux1(client, R_LEN10O)[0]
        if len10o != 0:
            failures.append(
                f'session 10 (XC1) script unexpectedly printed '
                f'something (len {len10o}) -- EDSCR10_TEXT has no `p`')

        len10 = peek_aux1(client, R_LEN10)[0]
        stage10 = bytes(peek_aux1(client, R_STAGE10, max(len10, 1)))[:len10]
        if stage10 != EXPECT_ED10FRESH:
            failures.append(
                f'(q) session 10 (XC1) /mnt/MAUX/ED10FRESH mismatch: got '
                f'{stage10!r} (len {len10}), expected '
                f'{EXPECT_ED10FRESH!r} (len {len(EXPECT_ED10FRESH)}) -- '
                f'unchanged at the first write\'s content means the '
                f'bare second `w` was wrongly refused (no remembered '
                f'name)')

        if failures:
            for failure in failures:
                print(f'[check-ed] FAIL: {failure}', file=sys.stderr)
            return 1

        print('[check-ed] PASS: a/./w/q buffer creation, r + g/BANK/p '
              '(exactly the two matching lines, in order), an '
              's/RE/&X/ + w round-trip, the 2026-08-19 audit-fix '
              'phases (s///N + bad-flag, no-match /re/, m/t incl. '
              'self-range, bare address, bare `,`/`;`, remembered '
              'filename hot+cold), j (2- and 3-line join, default '
              'range, single-address no-op) + = (with and without an '
              'address, dot/buffer left untouched), and `ed FILE` '
              'filename-on-launch (load via argv incl. bare `,p`/`w` '
              'round-trip, and a nonexistent path staying `?` with no '
              'crash and no remembered name), and the "last regular '
              'expression" task (bare `//` with no prior RE stays `?`, '
              '`//` forward repeat re-finds BANK, `s//X/` reuses a '
              'prior `s/OLD/NEW/`\'s search field), and the widened '
              'g/v task (`g/re/s///` running the general dispatch '
              'path, `g/re/d` renumber-safety, `v/re/p`, and `g`/`u` '
              'refused inside cmds with no mutation) all matched '
              'byte-exact, incl. CR line endings, session 9 (`w` '
              'truncation: a bare `w` overwriting an existing longer '
              'file with a shorter buffer leaves no stale tail), and '
              'session 10 (XC1: an unnamed buffer\'s first `w` '
              'establishes the current name so a bare second `w` '
              'reuses it instead of being refused)')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
