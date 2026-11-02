#!/usr/bin/env python3
"""Boot and verify the interactive maux shell image (`make check-play`)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
import noissue  # noqa: E402  -- boot without the /etc/issue splash
import arena as arenamod  # noqa: E402  -- vi's poison span
import e2e_limits as L  # noqa: E402 -- read limits from the tree's own
                        # headers; docs/E2E.md sec 5 forbids copying them

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'play.po')

#: A pid IS a RamWorks bank number (spawn stores one PRC_ALLC_BANK value
#: into both PRC_CHLD_BANK and PRC_CHILD_PID), so this bounds `$$`.
PCB_COUNT = L.kernel_limit('PCB_COUNT')
VARVALLEN = L.limit('sh', 'VARVALLEN')
EXPBUFLEN = L.limit('sh', 'EXPBUFLEN')

R_SH_PID = 0x1200
R_WAIT_PID = 0x1201
R_SH_STATUS = 0x1202
R_DONE = 0x1210
R_ERR = 0x1211
R_STEP = 0x1212

PROMPT = '$ '
# The LAST page of the listing, not its first: since ls buffers fully
# (2026-09-03) a write paints ~40 names in one burst and the early ones
# are scrolled off inside the same syscall -- no poll can see 'cat'. What
# survives, with the prompt below, is the tail of the alphabet.
# The listing is now of /bin (the 43 userland binaries live there,
# 2026-09-07 -- see build_play_image.py), NOT the root; `sh` is the one
# tool that stays in the root, so it is NOT a BIN needle.
LS_NEEDLES = ['sort', 'tail', 'vi', 'wc']
SPLASH_NEEDLES = ['Apple II', 'ProDOS', 'Copyright Apple']
# Row 0 was a reserved status/banner line until the 2026-09-03 row-0
# reclaim (docs/CONSOLE.md sec 6): playtestb.s no longer writes a boot
# banner to $0400, and the CSI row parameter is decremented like the
# column now, so ESC[1;1H is the top-left, physical row 0. Every
# constant below shifted up one physical row from what it used to be.
INITIAL_CURSOR_CELL = 0x0402
WRAP_ROW1 = 0x0400
WRAP_ROW2 = 0x0480
# Apple II text-page row bases: $0400 + (row/8)*$28 + (row%8)*$80.
# Named by the CSI ROW PARAMETER each TTY_VT_SUITE case uses (e.g.
# VT_ROW3 = ESC[3;...H), which now lands one physical row EARLIER
# than the parameter (ESC[3;...H -> physical row 2).
VT_ROW3 = 0x0500
VT_ROW4 = 0x0580
VT_ROW5 = 0x0600
VT_ROW6 = 0x0680
VT_ROW7 = 0x0700
VT_ROW8 = 0x0780
VT_ROW9 = 0x0428
VT_ROW10 = 0x04A8
VT_ROW21 = 0x0650
VT_ROW22 = 0x06D0
VT_ROW23 = 0x0750

# HOLD/READY/GO handshake (src/test/playtestb.s, docs/CONSOLE.md 11b,
# 2026-08-19): playtestb.s's ENTRY runs the TTY_VT_SUITE battery, then --
# before Fix 1's boot clear and the shell spawn -- checks PT_HOLD. Nonzero
# pauses: ENTRY writes PT_READY=$55 and busy-waits on PT_GO=$5A, which is
# the window this script uses to assert the battery cell by cell before
# the clear erases them. All three addresses are MAIN memory (ENTRY runs
# before any aux-bank/process switch, same as TTY_VT_SUITE itself) and
# must be poked before the FIRST step -- verified empirically for this
# image's full-ProDOS boot path (poked before mount_disk's first step,
# they still read back unchanged at the shell prompt; the raw block-0
# loader precedent in check_bankcopy.py/experiment_writelanding.py does
# NOT establish this for a ProDOS-hosted SYSTEM file, so it was re-checked
# here rather than assumed). HOLD engages only on the exact TWO-BYTE
# magic $C5/$AA at $9300/$9303 -- not "nonzero" -- so cold hardware or an
# emulator with randomized RAM cannot wander into the GO-less spin
# (1/65536 per boot instead of a coin flip per bit pattern).
#
# MOVED, 2026-09-20: the WHOLE harness result block, $9300-$9317 ->
# $97E8-$97FF, same relative offsets (and 2026-10-21, B1, on to
# $9FE8-$9FFF when the pool moved to $A000). MAUXPLAY.SYSTEM loads flat from
# $2000 and its ceiling is PMLI_IBF_BASE ($9800); $9300 was 107 bytes
# above where the image happened to END, i.e. these cells were squatting
# in the image's own growth room with nothing gating the overlap. ~100
# bytes of new code in src/test/playtestb.s loaded straight over them
# and fifteen gates went red on BOTH hosts.
#
# The block is DECLARED in five places -- PT_HOLD/READY/GO here, PT_N80
# in check_play80n.py, PT_VC/R_VC_* in check_vc.py, PT_F40 in pt_f40.py,
# and all fifteen in src/test/playtestb.s -- and then hand-COPIED into
# fourteen more scripts, because the note at the top of this file
# ("copied, not imported: check_play is a 2,700-line program, not a
# library") is true of its constants too. So the relocation took three
# passes and each miss wore a different face: four moved left eleven
# behind and the battery read BLANK (the image was sitting on the
# battery's verdict cells, which looks like a console regression);
# fifteen moved left fourteen copies of PT_F40 behind and eleven gates
# showed a blank screen with no prompt at all. If you move these, move
# ALL of them -- check_kernel_images.py's check_pt_hold_headroom() now
# enforces the declared span AND sweeps every script for a literal left
# in the vacated range, which is the only check that sees an unnamed
# copy.
#
# The commons had this, with the symptom and the diagnostic:
# learning:01M197TY462D8ZRJHSQ77FGWK9 -- "a ProDOS .SYSTEM program's
# real size ceiling is whatever it allocates ABOVE itself", whose last
# section is about test harnesses parking result cells at fixed main
# addresses specifically. Replacing the new code with `ds N` of the
# same size reproduced it identically, which is that learning's own
# one-run diagnostic and is what proved the code innocent here.
PT_HOLD_ADDR = 0x9FE8
PT_READY_ADDR = 0x9FE9
PT_GO_ADDR = 0x9FEA
PT_HOLD2_ADDR = 0x9FEB
PT_HOLD_MAG1 = 0xC5
PT_HOLD_MAG2 = 0xAA

# The boot-time escape-sequence battery (TTY_VT_SUITE in
# src/test/playtestb.s), asserted case by case at the READY checkpoint --
# BEFORE the post-battery clear -- so a failure names the escape that
# misbehaved rather than "the screen looks wrong". 'B' under ESC[7m must
# be $02 -- the ALTCHRSET inverse display code. $42 (a bare `and #$7F`)
# is MouseText under ALTCHRSET and the flashing block without it; it is
# never inverse. Verified on verilogapple 2026-08-15, see TTY_INVERSE_A
# in src/kernel/process.s.
VT_CASES = [
    ('ESC[r;cH absolute position', VT_ROW3 + 4, [0xC1, 0xC2]),
    ('ESC[r;cf as an alias for H', VT_ROW3 + 20, [0xE6]),
    ('ESC[nD cursor left', VT_ROW4 + 6, [0xCC]),
    ('ESC[nC cursor right', VT_ROW4 + 9, [0xD2]),
    ('ESC[nD clamps at column 0', VT_ROW5 + 0, [0xC3]),
    ('ESC[nB cursor down', VT_ROW7 + 10, [0xC4]),
    ('ESC[nA cursor up', VT_ROW6 + 11, [0xD5]),
    ('ESC[K keeps text before the cursor', VT_ROW8 + 0,
     [0xB0, 0xB1, 0xB2, 0xB3]),
    ('ESC[K erases from the cursor to end of line', VT_ROW8 + 4,
     [0xA0] * 6),
    ('ESC[0;7m applies BOTH SGR parameters', VT_ROW9 + 0, [0x09]),
    ('ESC[27m turns inverse back off', VT_ROW9 + 1, [0xCE]),
    ('TAB advances to the next 8-column stop', VT_ROW10 + 8, [0xD4]),
    ('an unknown CSI final byte does not wedge the parser',
     VT_ROW10 + 16, [0xCF, 0xCB]),
    ('ESC[7m inverse then ESC[0m reset', VT_ROW22, [0xC1, 0x02, 0xC3]),
    ('ESC[K on a fresh row', VT_ROW23, [0xDA, 0xA0, 0xA0, 0xA0]),
    # ESC 8 must restore the ESC 7 position even though a CSI ran in
    # between and reset the parameter accumulators.
    ('ESC 7 / ESC 8 survives an intervening CSI', VT_ROW21, [0xD3]),
]

# Fix 1's new post-clear assert: a representative sample of the battery
# cells above (not all 16 -- these four are enough to prove the clear
# ran) must read BLANK ($A0, the 40-column backend's blank-cell store,
# TTY_BLNK_CELL) once the prompt appears.
VT_BLANK_CHECK = [
    ('ESC[r;cH absolute position', VT_ROW3 + 4, 2),
    ('ESC[K keeps text before the cursor', VT_ROW8 + 0, 4),
    ('ESC[7m inverse then ESC[0m reset', VT_ROW22, 3),
    ('ESC 7 / ESC 8 survives an intervening CSI', VT_ROW21, 1),
]


# vi's POISON (docs/STICKY.md sec 25/28/37; scripts/check_tail.py the
# exemplar): vi is a converted program whose `dum` arena starts EMPTY,
# so a read-before-write bug in it reads zeros -- exactly the value
# such a bug needs to look correct. Layer 1 only (pre-boot): vi's whole
# arena is $A5-filled in every bank a spawned child can land in and
# READ BACK before the machine is stepped; the vi phase below then
# runs on that. Layer 2 (re-poison between runs) is not built here --
# the vi phase spawns vi once. check_poison.py derives this gate from
# the arena_span() call and the `!= POISON` read-back.
POISON = 0xA5
VI_CAND_BANKS = range(2, 10)

# F40: auto boots the best surface present (2026-09-03 ruling), and this
# gate asserts 40-column rows -- pin them (src/test/playtestb.s PT_F40).
# The four magic bytes live in pt_f40.py now (task #23 deliverable C),
# the ONE copy scripts/e2e_term.py's own text40 force also imports --
# see that module's docstring for why this file used to hardcode them.
from pt_f40 import (PT_F40_ADDR, PT_F40B_ADDR,  # noqa: E402
                    PT_F40_MAG1, PT_F40_MAG2)

def poke_main(client, addr, byte):
    r = client.call_tool('poke', {'addr': addr, 'bytes': [byte], 'bank': 'main'})
    if r.get('ok') is False:
        raise RuntimeError(f'poke failed at ${addr:04X}: {r}')


def peek_aux1(client, addr, count=1):
    return client.call_tool('peek', {
        'addr': addr,
        'count': count,
        'bank': 'aux',
        'aux_bank': 1,
    })['bytes']


def peek_main(client, addr, count=1):
    return client.call_tool('peek', {
        'addr': addr,
        'count': count,
        'bank': 'main',
    })['bytes']


def screen_rows(client):
    return client.call_tool('screen_text', {}).get('main', [])


def screen_blob(rows):
    return '\n'.join(rows)


def wait_for_screen(client, predicate, label, max_steps=1200):
    rows = []
    for _ in range(max_steps):
        client.call_tool('step', {'cycles': 200_000})
        rows = screen_rows(client)
        if predicate(rows):
            return rows
    raise RuntimeError(f'timed out waiting for {label}; screen was:\n'
                       f'{screen_blob(rows)}')


def _row_eq(rs, n, text):
    """Row n equals `text`, TOLERATING the one cell under the cursor.

    screen_text renders the cursor cell as a different glyph for a
    lowercase letter (the //e inverse fold: 'a' -> '!', 't' -> '4'), so
    a strict == on the row the cursor sits on is unreliable. Accept the
    same length with at most one differing position; a length change is
    a real edit and is NEVER tolerated (check_vi.py's line_eq is the
    same rule). The strict compares this replaces passed only while vi
    wrote a row's text and the cursor position in SEPARATE writes and a
    poll landed in the gap -- a repaint is one write since 2026-09-05.
    Rows the cursor is provably NOT on should stay strict.
    """
    got = rs[n].rstrip()
    return (len(got) == len(text)
            and sum(x != y for x, y in zip(got, text)) <= 1)


def wait_for_screen_settled(client, predicate, label, max_steps=1200):
    """wait_for_screen, but the predicate must hold on TWO CONSECUTIVE
    polls -- for predicates that COUNT text, which a single poll can
    satisfy with a MID-SCROLL TEAR.

    step() pauses the CPU wherever the cycle budget runs out, and
    screen_text reads the text page raw -- so a poll landing inside
    TTY_SCROLL's row copy sees the SAME line at both its old and new
    position. Found 2026-08-31, and it had teeth: the fast backend is
    deterministic, so the ^C phase's count('HELLOCAT') >= 2 fired on
    exactly such a tear EVERY run -- one poll before cat's own write
    existed, while the shell was still LOADING cat -- and the ^C that
    followed swept a process table with nothing yet in it to kill.
    The tear cannot survive a second poll: the scroll loop finishes
    within any 200k-cycle step, and the duplicate row is gone.
    """
    held = False
    rows = []
    for _ in range(max_steps):
        client.call_tool('step', {'cycles': 200_000})
        rows = screen_rows(client)
        if predicate(rows):
            if held:
                return rows
            held = True
        else:
            held = False
    raise RuntimeError(f'timed out waiting for {label}; screen was:\n'
                       f'{screen_blob(rows)}')



def screen_merged(client):
    """The 80-column view when the glass is 80 wide, else main.

    `main` alone renders an N8 screen as every second character --
    the aux half holds the even columns -- so any assertion made
    while the glass is 80-col must read `merged`. It is empty when
    80-col video is off, which is itself an assertable signal.
    """
    r = client.call_tool('screen_text', {})
    return r.get('merged') or r.get('main', [])


def wait_for_merged_settled(client, predicate, label, max_steps=1200):
    """wait_for_screen_settled over screen_merged (same tear rules)."""
    held = False
    rows = []
    for _ in range(max_steps):
        client.call_tool('step', {'cycles': 200_000})
        rows = screen_merged(client)
        if predicate(rows):
            if held:
                return rows
            held = True
        else:
            held = False
    raise RuntimeError(f'timed out waiting for {label}; screen was:\n'
                       f'{screen_blob(rows)}')


def wait_for_scrolling(client, needles, label, max_steps=12000):
    """Like wait_for_screen, but for output LONGER THAN THE SCREEN.

    A 24-row screen cannot hold a listing that scrolls, so a predicate
    over the CURRENT screen can never see a name that has already
    scrolled off the top -- it waits forever for a condition that was
    briefly true and is now unreachable. Accumulate across polls
    instead: a needle counts once it has been seen at any point.

    Added 2026-08-21 after exactly that failure. `build_play_image.py`
    gained the wave-3 fleet (cmp/sort/uniq/tr/od/file) plus four sample
    data files, which pushed the root listing past one screen; the
    alphabetically-early needles (cat, cp, echo, ed, ls) scrolled away
    before the late ones appeared and this gate hung. The gate was
    RIGHT that something changed and WRONG about what -- it reported a
    timeout, which reads like a hang, not like "your listing grew".
    """
    # 20k-cycle polls (2026-09-03): a fully buffered `ls` plus jump
    # scroll paints ~20 names per pass and the next pass replaces them
    # ~60k cycles later, so a 200k poll could miss a whole page of
    # needles. Same total budget.
    seen = set()
    rows = []
    for _ in range(max_steps):
        client.call_tool('step', {'cycles': 20_000})
        rows = screen_rows(client)
        blob = screen_blob(rows)
        for name in needles:
            if name in blob:
                seen.add(name)
        if seen.issuperset(needles):
            return rows
    missing = sorted(set(needles) - seen)
    raise RuntimeError(
        f'timed out waiting for {label}; never saw {missing} '
        f'(saw {sorted(seen)}); last screen was:\n{screen_blob(rows)}')


def wait_for_done(client):
    for _ in range(1200):
        client.call_tool('step', {'cycles': 200_000})
        done = peek_aux1(client, R_DONE)[0]
        if done in (0xAA, 0xEE):
            return done
    return peek_aux1(client, R_DONE)[0]


def wait_for_main_byte(client, addr, value, label, max_steps=1200):
    got = None
    for _ in range(max_steps):
        client.call_tool('step', {'cycles': 20_000})
        got = peek_main(client, addr)[0]
        if got == value:
            return got
    raise RuntimeError(f'timed out waiting for {label}; '
                       f'last byte was ${got:02X}')


def wait_for_blank_region(client, max_steps=1200):
    """Step until the wrapped-input region is fully erased.

    Returns the final (row1_tail, row2_head) reads either way, so the caller
    reports what was still on screen when it gave up.
    """
    row1_tail, row2_head = [], []
    for _ in range(max_steps):
        client.call_tool('step', {'cycles': 20_000})
        row1_tail = peek_main(client, WRAP_ROW1 + 3, 37)
        row2_head = peek_main(client, WRAP_ROW2, 7)
        if all(b == 0xA0 for b in row1_tail + row2_head):
            break
    return row1_tail, row2_head



def console2_dirty(rows):
    """Indexes of the rows of console 2's glass that should not be
    there. Allowed: ONE row that is exactly BGMARK (echo's output) and
    ONE bare `$` prompt on the row directly under it (the shell that
    `CHVT 2` starts on a console that has none -- it prompts once it has
    loaded; a person-visible `$ ` with its trailing blank strips to
    `$`). Anything else non-blank is a leak: a clear or store that
    wrote the wrong byte, a second prompt, a prompt anywhere else."""
    marks = [i for i, row in enumerate(rows) if row.strip() == 'BGMARK']
    bad = []
    for i, row in enumerate(rows):
        text = row.strip()
        if not text:
            continue
        if text == 'BGMARK' and marks.index(i) == 0:
            continue
        if text == '$' and marks and i == marks[0] + 1:
            continue
        bad.append(i)
    return bad


def _console2_dirty_selftest():
    """The rule has teeth on its own: each shape below must be judged as
    written, so loosening the function to the point of passing anything
    fails the gate before an emulator is booted."""
    blank = [''] * 24
    cases = (
        ('BGMARK alone (sampled before the prompt)',
         {0: 'BGMARK'}, []),
        ('BGMARK and the shell prompt under it',
         {0: 'BGMARK', 1: '$ '}, []),
        ('a prompt TWO rows under',
         {0: 'BGMARK', 2: '$'}, [2]),
        ('two prompts', {0: 'BGMARK', 1: '$', 2: '$'}, [2]),
        ('a prompt above BGMARK', {0: '$', 1: 'BGMARK'}, [0]),
        ('BGMARK twice', {0: 'BGMARK', 1: 'BGMARK'}, [1]),
        ('a leaked row of bank-number glyphs',
         {0: 'BGMARK', 5: 'EEEEEEEE'}, [5]),
        ('garbage with no BGMARK at all', {3: 'XYZ'}, [3]),
    )
    for what, put, want in cases:
        rows = list(blank)
        for i, text in put.items():
            rows[i] = text
        got = console2_dirty(rows)
        assert got == want, (f'console2_dirty self-test: {what}: got '
                             f'{got}, want {want}')


def main():
    _console2_dirty_selftest()
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    # geometry gate: the prompt must land on row 0, so boot without the
    # /etc/issue splash (scripts/noissue.py; check-issue covers the splash)
    disk = noissue.copy_without_issue(disk)
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}', file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make play-image first',
              file=sys.stderr)
        return 2

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-play] reset -> {r}', file=sys.stderr)
        # Poke HOLD nonzero BEFORE the first step (docs/CONSOLE.md 11b,
        # PT_HOLD/READY/GO comment in src/test/playtestb.s): playtestb.s's
        # ENTRY checks it right after TTY_VT_SUITE, before Fix 1's boot
        # clear, so this must land before ENTRY ever runs -- and PT_HOLD
        # survives the intervening full ProDOS boot (verified separately;
        # see the module-level comment above).
        poke_main(client, PT_HOLD_ADDR, PT_HOLD_MAG1)
        poke_main(client, PT_HOLD2_ADDR, PT_HOLD_MAG2)
        poke_main(client, PT_F40_ADDR, PT_F40_MAG1)
        poke_main(client, PT_F40B_ADDR, PT_F40_MAG2)
        # vi's arena poison, pre-boot, every candidate child bank,
        # verified landed (see the POISON note above).
        vi_arena, vi_span = arenamod.arena_span('vi')
        for bank in VI_CAND_BANKS:
            client.call_tool('poke', {
                'addr': vi_arena, 'bytes': [POISON] * vi_span,
                'bank': 'aux', 'aux_bank': bank})
            back = client.call_tool('peek', {
                'addr': vi_arena, 'count': vi_span,
                'bank': 'aux', 'aux_bank': bank})['bytes']
            if any(b != POISON for b in back):
                raise RuntimeError(f'vi arena poison did not land in '
                                   f'bank {bank}')
        print(f'[check-play] vi arena ${vi_arena:04X}+{vi_span} '
              f'poisoned ${POISON:02X} in banks '
              f'{VI_CAND_BANKS.start}-{VI_CAND_BANKS.stop - 1}, read back',
              file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-play] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        wait_for_main_byte(client, PT_READY_ADDR, 0x55,
                           'TTY_VT_SUITE checkpoint (READY)')
        print('[check-play] paused at the TTY_VT_SUITE checkpoint, '
              'battery still on screen')

        # The boot-time escape-sequence battery (TTY_VT_SUITE in
        # src/test/playtestb.s), asserted case by case at THIS checkpoint
        # -- before Fix 1's boot clear erases it -- so a failure names the
        # escape that misbehaved rather than "the screen looks wrong".
        vt_failed = False
        for label, addr, want in VT_CASES:
            got = peek_main(client, addr, len(want))
            if got != want:
                print(f'[check-play] FAIL: {label}: at ${addr:04X} expected '
                      f'{[hex(b) for b in want]}, got {[hex(b) for b in got]}',
                      file=sys.stderr)
                vt_failed = True
        if vt_failed:
            print(screen_blob(screen_rows(client)), file=sys.stderr)
            return 1
        print(f'[check-play] VT escape battery: {len(VT_CASES)} cases pass')

        # Release the boot into the clear + sh spawn.
        poke_main(client, PT_GO_ADDR, 0x5A)

        rows = wait_for_screen(client,
                               lambda rs: any(PROMPT in row for row in rs),
                               'shell prompt')
        blob = screen_blob(rows)
        leftovers = [needle for needle in SPLASH_NEEDLES if needle in blob]
        if leftovers:
            print('[check-play] FAIL: splash text left on tty screen: '
                  f'{leftovers}', file=sys.stderr)
            print(blob, file=sys.stderr)
            return 1
        # Row 0 IS the terminal now (2026-09-03 row-0 reclaim, docs/
        # CONSOLE.md sec 6): the very first thing the shell prints,
        # its own prompt, must land on physical row 0 -- there is no
        # reserved status line ahead of it any more.
        if not rows[0].startswith(PROMPT):
            print(f'[check-play] FAIL: the shell prompt did not land '
                  f'on row 0 -- row 0 = {rows[0]!r}, row 0 is ordinary '
                  f'terminal content now, not a reserved line',
                  file=sys.stderr)
            print(blob, file=sys.stderr)
            return 1
        print('[check-play] the shell prompt lands on row 0 -- no '
              'reserved status line')
        cursor = wait_for_main_byte(client, INITIAL_CURSOR_CELL, 0x20,
                                    'initial inverse-space cursor')
        if cursor != 0x20:
            print(f'[check-play] FAIL: initial cursor cell expected inverse '
                  f'space $20, got ${cursor:02X}', file=sys.stderr)
            print(blob, file=sys.stderr)
            return 1
        print('[check-play] shell prompt reached')

        # Fix 1's whole point: the clear must have actually run. Assert a
        # representative sample of the battery cells checked above are now
        # BLANK ($A0) -- proving TTY_CLR_SCRN erased them rather than the
        # battery having silently not run, or check-play just not looking.
        blank_failed = False
        for label, addr, length in VT_BLANK_CHECK:
            got = peek_main(client, addr, length)
            want = [0xA0] * length
            if got != want:
                print(f'[check-play] FAIL: post-clear blank check ({label}): '
                      f'at ${addr:04X} expected all $A0, got '
                      f'{[hex(b) for b in got]}', file=sys.stderr)
                blank_failed = True
        if blank_failed:
            print(screen_blob(screen_rows(client)), file=sys.stderr)
            return 1
        print('[check-play] boot clear erased the VT battery before sh '
              'spawned')

        # Cooked-mode erase must cross a line wrap. The prompt leaves the
        # cursor at row 0 col 2 (2026-09-03 row-0 reclaim -- there is no
        # more reserved status line), so 45 typed chars fill row 0 cols
        # 2-39 and spill onto row 1 cols 0-6. Erasing all 45 must clear
        # BOTH rows: a backspace that stops dead at column 0 would empty
        # the edit buffer while leaving row 0 covered in X, so the buffer
        # and the screen would disagree about what the user typed.
        #
        # DEL ($7F), not the left arrow (2026-09-02): left-arrow is now
        # MOTION (TTY_ED_LEFT, see the new assertion just below this one)
        # -- it used to alias :bs, which is what this test originally
        # exercised. DEL still erases; ^U line-kill is the other erase
        # key (docs/CONSOLE.md sec 4b).
        client.call_tool('type', {'text': 'X' * 45})
        wait_for_main_byte(client, WRAP_ROW2 + 6, 0xD8,
                           'typed input to wrap onto row 1')
        client.call_tool('type', {'text': '\\x7f' * 45})
        # Cooked mode consumes one key per VBL tick, so all 45 backspaces take
        # many ticks to drain. Wait for the whole typed region to go blank
        # rather than any single cell -- column 39 clears on the 8th erase and
        # would report success while 37 characters were still on screen.
        row1_tail, row2_head = wait_for_blank_region(client)
        stray = [b for b in row1_tail + row2_head if b != 0xA0]
        if stray:
            print('[check-play] FAIL: erase did not cross the line wrap; '
                  f'{len(stray)} cell(s) still set: row1_tail={row1_tail} '
                  f'row2_head={row2_head}', file=sys.stderr)
            return 1
        print('[check-play] cooked-mode erase crosses a line wrap')

        # DEL is cooked mode's erase key now (2026-09-02): left-arrow
        # used to alias :bs too, but is MOTION as of this session (the
        # assertion right below this one) -- ^U line-kill is the other
        # erase mechanism, but stays untyped here same as before this
        # change: $15 reaches the keyboard ONLY as the right arrow
        # (Sather), and TTY_KEYIN emits the arrows as VT/ANSI CSI now,
        # so ^U is reachable only as Option-U, a PUSHBUTTON this rig
        # has no way to hold down.
        client.call_tool('type', {'text': 'BOGUS\x7f\x7f\x7f\x7f\x7fLS BIN\r'})
        rows = wait_for_scrolling(client, LS_NEEDLES, 'LS output')
        blob = screen_blob(rows)
        if 'BOGUS' in blob:
            print('[check-play] FAIL: the erase key did not clear the '
                  'input line', file=sys.stderr)
            print(blob, file=sys.stderr)
            return 1
        print('[check-play] LS output visible')

        # wait_for_scrolling only proves LS_NEEDLES were seen SOMEWHERE
        # across polls -- it does not prove `ls` has actually FINISHED.
        # Every LS_NEEDLES member sits ahead of the fleet's alphabetically
        # -late entries (sort/tr/uniq/wc) in the post-2026-08-21 root
        # listing, so the listing can still be mid-write the instant this
        # returns. The very next phase types "LS" with no CR right after
        # -- if `ls` is still appending rows at that moment, the fresh
        # keystrokes land on the SAME row as the tail of the listing and
        # interleave with it (observed: a stray "wc" merged into "LS" as
        # "LSwc"). Wait for the PROMPT to actually come back -- the
        # bottom-most non-blank row reads "$" -- before any further
        # "before" snapshot is taken. Same fix shape, same root cause, as
        # check_play80.py's `_prompt_at_bottom` (that file's own 2026-08-21
        # comment); this spot was missed when that one was hardened.
        def _prompt_back(rs):
            nonblank = [r for r in rs if r.strip()]
            return bool(nonblank) and nonblank[-1].startswith('$')

        wait_for_screen(client, _prompt_back, 'shell prompt after LS output')

        # Left-arrow is MOTION now (2026-09-02: tty3.s's :escfin CSI-D
        # dispatch jumps to TTY_ED_LEFT, not :bs -- see the DEL-only
        # erase test just above, which used to exercise this same key
        # as erase). Same shape as the C-b mid-line-insert test later
        # in the readline-lite suite, run here instead, right next to
        # the erase fix it pairs with: type ORLD, walk the cursor back
        # 4 with the ARROW (not ^B), insert W. Only a cursor that
        # actually MOVED lands W before O -- if left-arrow still
        # erased, ORLD would already be gone and this would commit a
        # bare "W" instead of "WORLD".
        client.call_tool('type', {'text': 'ECHO ORLD'})
        client.call_tool('type', {'text': '\\x08\\x08\\x08\\x08W\r'})
        wait_for_screen(client,
                        lambda rs: any(r.strip() == 'WORLD' for r in rs),
                        'left-arrow mid-line insert to execute (WORLD)')
        print('[check-play] left-arrow moves the cursor left instead '
              'of erasing')

        # ^L redraws the prompt too, 2026-08-19 (docs/CONSOLE.md section 4,
        # Fix 2): TTY_OUTSHDW records printable PROCESS WRITE-path bytes
        # since the last CR, and the ^L handler replays that shadow before
        # re-echoing the edit buffer. Type a partial command with NO
        # carriage return, wait for it to actually echo (cooked mode drains
        # the raw ring a tick at a time), then send ^L and check the top
        # row (row 0 -- no more reserved status line as of the 2026-09-03
        # reclaim, docs/CONSOLE.md section 6) reads exactly "$ LS" from
        # column 0 with the rest of the screen cleared.
        # count(), not a bare membership test: the previous phase's own
        # "$ LS" (from "BOGUS...LS\r") is still on screen at this point --
        # nothing has scrolled yet -- so a plain "'$ LS' in blob" check
        # would pass on stale text before this LS is even fully echoed.
        before_ls = screen_blob(screen_rows(client)).count('$ LS BIN')
        client.call_tool('type', {'text': 'LS BIN'})
        wait_for_screen(client,
                        lambda rs: screen_blob(rs).count('$ LS BIN') > before_ls,
                        '"LS BIN" typed but not yet committed')
        client.call_tool('type', {'text': '\\x0c'})

        def row0_redrawn(rs):
            return len(rs) > 0 and rs[0].startswith('$ LS BIN')

        rows = wait_for_screen(client, row0_redrawn,
                               '^L to redraw the prompt + partial command '
                               'at row 0')
        row0_rest = rows[0][8:]
        if row0_rest.strip(' '):
            print(f'[check-play] FAIL: ^L left stray content on row 0 after '
                  f'"$ LS BIN": {row0_rest!r}', file=sys.stderr)
            print(screen_blob(rows), file=sys.stderr)
            return 1
        dirty = [i for i, row in enumerate(rows) if i != 0
                and row.strip(' ')]
        if dirty:
            print('[check-play] FAIL: ^L did not clear the rest of the '
                  f'screen; non-blank rows: {dirty}', file=sys.stderr)
            print(screen_blob(rows), file=sys.stderr)
            return 1
        print('[check-play] ^L redrew "$ LS BIN" at row 0 and cleared the rest '
              'of the screen')

        client.call_tool('type', {'text': '\r'})
        # Same "listing outgrows one screen" hazard as the FIRST `ls`
        # above (this comment's neighbor) -- `wait_for_scrolling`, not a
        # single-snapshot `all(...)`, for the same reason.
        wait_for_scrolling(client, LS_NEEDLES, 'LS output after ^L '
                           '(edit buffer survived)')
        print('[check-play] LS output appears after ^L -- the edit buffer '
              'survived the clear')

        # Blank Enters then ^L, 2026-09-16 (found live 2026-09-03: '$ $ $ $'
        # on one row). The shadow used to reset only on an OUTPUT CR; a
        # blank line's break is the ECHOED input CR, so every reprompt
        # appended and ^L replayed them all. tty3.s now resets the shadow
        # at both line commits. Three empty lines, then ^L: row 0 must
        # read exactly '$' and nothing else. ONE Enter at a time, each
        # waited for: a burst through the one-key latch is type-ahead
        # (the prompts land on one row) and not what a person does.
        def prompts(rs):
            return sum(1 for r in rs if r.rstrip() == '$')
        # ...and only once the shell HAS reprompted after the listing: the
        # phase above returns on the listing's needles, and an Enter typed
        # before the prompt is type-ahead (its echo lands first, then two
        # prompts share a row) -- what the first run of this case saw.
        wait_for_screen(client,
                        lambda rs: bool([r for r in rs if r.strip()])
                        and [r for r in rs if r.strip()][-1].rstrip() == '$',
                        'the prompt after the LS listing')
        for i in range(3):
            before_blank = prompts(screen_rows(client))
            client.call_tool('type', {'text': '\r'})
            wait_for_screen(client,
                            lambda rs, n=before_blank: prompts(rs) > n,
                            f'blank Enter {i + 1} to reprompt')
        client.call_tool('type', {'text': '\x0c'})
        rows = wait_for_screen(client,
                               lambda rs: len(rs) > 0 and rs[0].startswith('$')
                               and not any(r.strip() for r in rs[1:]),
                               '^L after blank Enters to redraw at row 0')
        if rows[0].rstrip() != '$':
            print(f'[check-play] FAIL: ^L after blank Enters stacked the '
                  f'prompt: row 0 = {rows[0].rstrip()!r}', file=sys.stderr)
            return 1
        print('[check-play] ^L after three blank Enters redrew a single "$"')

        # A line change ends the ^L shadow's line (KFIX9; found by the
        # review of KFIX8: init's back-off line ends in ESC E, and TT9_NEL
        # did not reset the shadow the way TT9_CR does, so ^L at the next
        # shell's prompt repainted the dead shell's text before the `$`).
        # EVERY row below types `printf 'JUNK<X>MARK'`: JUNK is printed
        # before the operation X and MARK after it, with no CR anywhere,
        # and the shell's prompt follows MARK. The shadow is the
        # printable run since the glass last stopped being an append of
        # it, so after ^L row 0 must read `MARK$` where X is a line
        # break (LF, ESC D, ESC E, ESC M), a cursor motion, an erase or
        # an edit (the CSI finals that cancel a pending wrap), a cursor
        # restore (ESC 8) or a reset (ESC c); and `JUNKMARK$` where it is
        # not (SGR, and a wrap -- the replay re-wraps it the same way).
        # The wait is on the SHADOW ending in `MARK$ `, in the kernel's
        # own cells: MARK is printed after X, so the cell cannot say
        # "done" before the command ran (a bare `$ ` could: it is also
        # what the shadow holds before the Enter).
        from split_kseg import _read_symbol
        sym_out = os.path.join(ROOT, 'build', 'MAUXPLAY.SYSTEM_Output.txt')
        shlen_a = _read_symbol(sym_out, 'VC_OSHDW_LEN')
        shbuf_a = _read_symbol(sym_out, 'VC_OUTSHDW')

        def shadow_text():
            n = peek_main(client, shlen_a)[0]
            if not n:
                return ''
            raw = peek_main(client, shbuf_a, n)
            return ''.join(chr(b & 0x7F) for b in raw)

        def shadow_case(label, body, want_rows):
            client.call_tool('type', {'text': "printf '" + body + "'\r"})
            for _ in range(2000):
                client.call_tool('step', {'cycles': 200_000})
                if shadow_text().endswith('MARK$ '):
                    break
            else:
                raise RuntimeError(f'shadow {label}: MARK never reached '
                                   f'the shadow: {shadow_text()!r}')
            for _ in range(5):
                client.call_tool('step', {'cycles': 200_000})
            client.call_tool('type', {'text': '\x0c'})

            def repainted(rs):
                live = [r.rstrip() for r in rs if r.strip()]
                return live == want_rows

            try:
                wait_for_screen_settled(client, repainted,
                                        f'^L after {label}')
            except RuntimeError:
                got = [r.rstrip() for r in screen_rows(client)
                       if r.strip()]
                print(f'[check-play] FAIL: ^L after {label}: shadow '
                      f'{shadow_text()!r}, glass {got!r}, want '
                      f'{want_rows!r}', file=sys.stderr)
                return False
            print(f'[check-play] ^L after {label}: {want_rows!r}')
            # one blank Enter resets the shadow for the next case
            client.call_tool('type', {'text': '\r'})
            for _ in range(20):
                client.call_tool('step', {'cycles': 200_000})
            return True

        # (octal escapes only: the `type` tool turns a typed backslash-r
        # into a real CR, which ends the command line early. The SGR row
        # ends with ESC [ 0 m: bold stays on for every phase after it
        # otherwise, and the phase that reads `time`'s lowercase output
        # sees inverse glyphs.)
        wrap_x = 'X' * 45          # 40 columns: wraps once
        shadow_cases = (
            ('CR (control)', 'JUNK\\015MARK', ['MARK$']),
            ('LF', 'JUNK\\012MARK', ['MARK$']),
            ('IND (ESC D)', 'JUNK\\033DMARK', ['MARK$']),
            ('NEL (ESC E)', 'JUNK\\033EMARK', ['MARK$']),
            ('RI (ESC M)', 'JUNK\\033MMARK', ['MARK$']),
            ('CUP', 'JUNK\\033[5;1HMARK', ['MARK$']),
            ('ED 2', 'JUNK\\033[2JMARK', ['MARK$']),
            ('ED 0', 'JUNK\\033[JMARK', ['MARK$']),
            ('EL', 'JUNK\\033[KMARK', ['MARK$']),
            ('CUF', 'JUNK\\033[CMARK', ['MARK$']),
            ('ESC 8 (DECRC)', 'JUNK\\0337ZZ\\0338MARK', ['MARK$']),
            ('ESC c (RIS)', 'JUNK\\033cMARK', ['MARK$']),
            ('SGR (control)', 'JUNK\\033[1mMARK\\033[0m', ['JUNKMARK$']),
            ('a wrap (control)', wrap_x + 'MARK',
             [wrap_x[:40], wrap_x[40:] + 'MARK$']),
        )
        # RE-POINTED at the kernel editor (TAB-A2): the shell's own line
        # editor (src/bin/shedit.s) owns ^L at ITS prompt and cannot
        # replay the output of a child it never saw, so these rows --
        # which test the KERNEL's ^L output shadow (VC_OUTSHDW) -- run in
        # a nested `sh -E` (no line editor: the kernel's cooked editor
        # reads), exactly as they ran when the login shell was the
        # cooked reader. Every expected value is unchanged.
        client.call_tool('type', {'text': 'sh -E\r'})
        wait_for_screen(client,
                        lambda rs: any(r.strip() == '$ sh -E' for r in rs)
                        and [r for r in rs if r.strip()][-1].rstrip()
                        == '$',
                        'the nested `sh -E` (kernel editor) prompt')
        for label, body, want_rows in shadow_cases:
            if not shadow_case(label, body, want_rows):
                return 1
        client.call_tool('type', {'text': 'exit\r'})
        wait_for_screen(client,
                        lambda rs: any(r.strip() == '$ exit' for r in rs),
                        'the nested `sh -E` to exit')
        for _ in range(40):
            client.call_tool('step', {'cycles': 200_000})
        # leave the glass as the phases after this expect it: row 0 `$`
        client.call_tool('type', {'text': '\x0c'})
        wait_for_screen_settled(
            client, lambda rs: len(rs) > 0 and rs[0].rstrip() == '$'
            and not any(r.strip() for r in rs[1:]),
            '^L to leave row 0 as the bare prompt')
        print('[check-play] ^L repaints only the current line: a line '
              'break, cursor motion, erase, edit, restore or reset ends '
              'the shadow; SGR and a wrap do not')

        # Row 0 USED TO BE a reserved status line (docs/CONSOLE.md
        # section 6) that TTY_CLR_BODY, TTY_SCROLL and TTY_TERM_RESET
        # all had to leave alone -- gone as of the 2026-09-03 row-0
        # reclaim: row 0 is ordinary terminal content now, all 24 rows
        # scroll the same way.
        #
        # Scrolling must be PROVEN, not assumed. An earlier version of
        # this check waited for "bottom row non-empty", which goes true
        # when output first reaches row 23 -- before any scroll -- so it
        # passed against the very bug it was written to catch. Instead:
        # plant a marker, then wait for it to scroll off the top. It can
        # only leave the screen by being scrolled away, so reaching the
        # assertion means ~24 scrolls have happened.
        client.call_tool('type', {'text': 'ECHO SCROLLMARK\r'})
        wait_for_screen(client,
                        lambda rs: 'SCROLLMARK' in screen_blob(rs),
                        'scroll marker to appear')
        client.call_tool('type', {'text': '\r' * 40})
        wait_for_screen(
            client,
            lambda rs: 'SCROLLMARK' not in screen_blob(rs),
            'scroll marker to scroll off the top',
        )
        # This is the opposite assertion from the one that used to
        # live here (which proved a boot banner SURVIVED scrolling):
        # prove row 0 is NOT immune, and prove it with CONTENT, not
        # just presence. Bare CRs are the wrong tool for this part --
        # an empty command's echo is cheap and lands unevenly relative
        # to the shell's own reprompt, so which physical rows end up
        # blank is not predictable command by command. Distinctly
        # numbered `echo` lines, ONE AT A TIME with a settled prompt
        # between each (same discipline `_typed_case` below uses --
        # typing ahead of a still-settling prompt interleaves the
        # echo, seen live while developing this very check), are
        # deterministic: each is exactly one echoed-input row plus one
        # output row, so N commands are a KNOWN N*2 rows of scroll.
        # Idle when the bottom non-blank row is nothing but shell
        # prompt(s). The `\r`*40 above drains as a burst, and the shell
        # can stack more than one idle prompt on the final row ("$ $")
        # before it quiesces -- harmless (each is an empty-command
        # reprompt), but a strict `== '$'` never matches it and hangs.
        # Only the shell being IDLE matters here; the real assertions
        # (ZROW01 scrolled off, row 0 holds ZROW output) still catch a
        # genuinely broken shell below.
        def _rowzero_idle(rs):
            nonblank = [r for r in rs if r.strip()]
            return bool(nonblank) and all(tok == '$'
                                          for tok in nonblank[-1].split())

        for n in range(1, 15):
            wait_for_screen_settled(client, _rowzero_idle,
                                    f'settled prompt before ZROW{n:02d}')
            client.call_tool('type', {'text': f'ECHO ZROW{n:02d}\r'})
        # One more settle for ZROW14's own idle prompt -- a plain
        # wait_for_screen/wait_for_scrolling snapshot here risks the
        # same mid-tear read wait_for_screen_settled's own header
        # warns about (a poll landing while a row is still being
        # written renders it truncated).
        rows = wait_for_screen_settled(client, _rowzero_idle,
                                       "ZROW14's own idle prompt")
        if 'ZROW01' in screen_blob(rows):
            print('[check-play] FAIL: ZROW01 has not scrolled off yet '
                  '-- the fixture assumption (14 lines > 1 screen) is '
                  'wrong', file=sys.stderr)
            return 1
        if 'ZROW' not in rows[0]:
            print(f'[check-play] FAIL: row 0 does not hold ordinary '
                  f'scrolled command output -- row 0 = {rows[0]!r}, '
                  f'row 0 is no longer a reserved line', file=sys.stderr)
            return 1
        print('[check-play] row 0 scrolls like any other row -- no '
              'reserved status line (row 0 now reads '
              f'{rows[0].strip()!r})')

        # -----------------------------------------------------------
        # THE BAD-VOLUME WEDGE (docs/BADVOL-WEDGE.md, 2026-08-31).
        # `LS /NOPE` -- the form a human types, and the first one a
        # human DID type the day the playpen opened -- must error and
        # REPROMPT, not wedge the machine. Before the polite-citizen
        # /RAM disconnect (PRC_RAMDIS), ProDOS's ON_LINE volume scan
        # entered the /RAM driver's RAMRD=aux window with interrupts
        # enabled and the next tick executed the process bank's zeros
        # at MAIN_IRQ_SHIM's address.
        # 1. The kernel actually removed /RAM: DEVCNT (count-1) says
        #    one device and DEVLST holds no $Bx family unit.
        devcnt = peek_main(client, 0xBF31)[0]
        devlst = peek_main(client, 0xBF32, devcnt + 1)
        rammy = [b for b in devlst if (b & 0xF3) == 0xB3]
        if rammy:
            print(f'[check-play] FAIL: /RAM still in DEVLST '
                  f'(cnt-1={devcnt}, lst={[hex(b) for b in devlst]}) -- '
                  f'PRC_RAMDIS did not run or did not match',
                  file=sys.stderr)
            return 1
        print(f'[check-play] /RAM disconnected at boot '
              f'(DEVLST: {[hex(b) for b in devlst]})')
        # 2. The wedge itself: bad volume -> error -> prompt -> the
        #    machine still EXECUTES (a follow-up command's output is
        #    the liveness proof; the wedge died precisely here).
        # The echo was TYPED AHEAD during the volume scan, so when sh
        # reprompts and consumes the pending line its output lands on
        # the prompt row: '$ RAMOK', not a bare row. Accept both.
        client.call_tool('type', {'text': 'LS /NOPE\r'})
        client.call_tool('type', {'text': 'ECHO RAMOK\r'})
        wait_for_screen(client,
                        lambda rs: any(r.strip() in ('RAMOK', '$ RAMOK')
                                       for r in rs),
                        'the machine to SURVIVE a nonexistent volume '
                        '(bad-volume wedge, docs/BADVOL-WEDGE.md)')
        print('[check-play] a nonexistent volume errors and reprompts '
              '-- the bad-volume wedge is dead')

        # -----------------------------------------------------------
        # READLINE-LITE + HISTORY (docs/CONSOLE.md sec 4b). Runs
        # right after the scroll phase ON PURPOSE: the prompt sits at
        # the bottom row, so inserts and back-walks here also cross
        # the scroll-and-wrap geometry.
        #
        # EVERY assertion is on EXECUTED OUTPUT (a bare row that only
        # echo's run can produce), never the glass: the classic
        # editor sabotage repaints the screen correctly while editing
        # the wrong buffer cell, and only the committed line convicts
        # it.
        #
        # Key spellings honor the IIe keyboard's folds (Sather; sec
        # 4b): ^K IS the up arrow and ^U IS the right arrow -- both
        # rewritten to CSI by TTY_KEYIN before the cook -- so
        # kill-to-end is typed as M-k (ESC k) and history as up-arrow
        # CSI or raw ^P. ESC-prefixed letters are ALSO the OA-meta
        # encoding (OA+key -> ESC key at capture): when
        # verilogapple#16 lands a held-PB0 leg belongs here.
        def _bare(word):
            return lambda rs: any(r.strip() == word for r in rs)

        def _bare_n(word, n):
            return lambda rs: sum(1 for r in rs
                                  if r.strip() == word) >= n

        # 1. Mid-line insert via C-b motion: the W lands INSIDE the
        # buffer, not at the cursor's old end.
        client.call_tool('type', {'text': 'ECHO ORLD'})
        client.call_tool('type', {'text': '\\x02\\x02\\x02\\x02W\r'})
        wait_for_screen(client, _bare('WORLD'),
                        'C-b mid-line insert to execute (WORLD)')

        # 2. C-a across a WRAP: the typed line spans two screen rows
        # (2-col prompt + 40 chars on a 40-col glass), so the C-a
        # back-walk and the insert repaint both cross the row
        # boundary -- the exact-boundary fixture buffer code needs.
        wrap_tail = 'Q' * 35 + 'Z'
        client.call_tool('type', {'text': 'CHO ' + wrap_tail})
        client.call_tool('type', {'text': '\\x01E\r'})
        # TWO CONSECUTIVE IDENTICAL POLLS (docs/GATE-PREDICATES.md): the
        # output row shows up while the console is still scrolling it
        # into place, and a read in that window sees a torn glass (a
        # stray 31-Q row between the echo's tail and the output, box
        # only, once WAIT-1 and a 1 KB larger sh moved the phase).
        seen = [None]

        def _wrap_settled(rs):
            cur = [r.rstrip() for r in rs]
            ok = _bare(wrap_tail)(rs) and cur == seen[0]
            seen[0] = cur
            return ok
        rows = wait_for_screen(client, _wrap_settled,
                               'C-a insert at start of a WRAPPED line')
        # SCREEN-CURSOR PLACEMENT, not just buffer truth (review
        # readline finding 5): the CR must be echoed from the END of
        # the wrapped line, so the echo's own tail row ('QQZ')
        # survives directly above the output row. A commit from the
        # mid-line cursor overwrites that tail row with the output --
        # the executed bytes are right and the glass is wrong, which
        # the bare-row assert alone cannot see.
        idx = next(i for i, r in enumerate(rows)
                   if r.strip() == wrap_tail)
        if idx == 0 or rows[idx - 1].strip() != 'QQZ':
            print(f'[check-play] FAIL: the wrapped echo\'s tail row '
                  f'should sit directly above the output; got '
                  f'{rows[idx - 1]!r} -- the CR was echoed from a '
                  f'mid-line screen cursor and overwrote the tail',
                  file=sys.stderr)
            return 1

        # 3. M-b + M-k: word-back over JUNKJUNK, kill the tail.
        client.call_tool('type', {'text': 'ECHO AB JUNKJUNK'})
        client.call_tool('type', {'text': '\\x1bb\\x1bk\r'})
        wait_for_screen(client, _bare('AB'),
                        'M-b + M-k to drop the last word (AB)')

        # 4. Mid-line DEL: delete the Q, not the char at the end.
        client.call_tool('type', {'text': 'ECHO QCD'})
        client.call_tool('type', {'text': '\\x02\\x02\\x7f\r'})
        wait_for_screen(client, _bare('CD'),
                        'mid-line DEL to execute (CD)')

        # 5. History: C-p recalls the newest line and CR re-runs it
        # -- a SECOND bare CD can only come from the recalled buffer.
        client.call_tool('type', {'text': '\\x10\r'})
        wait_for_screen(client, _bare_n('CD', 2),
                        'C-p + CR to re-execute the last command')

        # 6. Deep walk via the up arrow's CSI, then EDIT the recall:
        # three ups reach 'ECHO AB ' (CD, CD, AB from newest -- M-k
        # left its trailing space), C-e is a no-op at end, append
        # 99. Only the edited RECALLED buffer can print 'AB 99' --
        # this leg dies if the walk loads the wrong ring slot or the
        # recalled line is display-only.
        client.call_tool('type',
                         {'text': '\\x1b[A\\x1b[A\\x1b[A\\x0599\r'})
        wait_for_screen(client, _bare('AB 99'),
                        'up-arrow walk + edit of a recalled line')

        # 7. OA IS META, end to end -- gateable since
        # verilogapple#16 landed its `buttons` tool: hold PB0, type
        # k, and TTY_KEYIN must push ESC ahead of it at capture, so
        # OA+k arrives at the cook as M-k and kills the tail M-b
        # walked back over. The button must be HELD across the
        # capture (steps between type and release), and typing after
        # the release must self-insert again -- the CR arrives
        # unprefixed.
        client.call_tool('type', {'text': 'ECHO OK DROPME'})
        client.call_tool('type', {'text': '\\x1bb'})
        # DRAIN BEFORE HOLDING. Every key captured while PB0 is down
        # gets the ESC prefix -- hold too early and the K of OK is
        # itself M-k (observed: the line committed as 'ECHO O').
        # Wait for the echo, then a few steps for the ESC b pair.
        wait_for_screen(client,
                        lambda rs: any('ECHO OK DROPME' in r
                                       for r in rs),
                        'the typed line to finish echoing')
        for _ in range(6):
            client.call_tool('step', {'cycles': 200_000})
        client.call_tool('buttons', {'open_apple': True})
        client.call_tool('type', {'text': 'k'})
        for _ in range(6):
            client.call_tool('step', {'cycles': 200_000})
        client.call_tool('buttons', {'open_apple': False})
        client.call_tool('type', {'text': '\r'})
        wait_for_screen(client, _bare('OK'),
                        'OA+k to act as Meta-k (held PB0 -> ESC '
                        'prefix at capture)')
        print('[check-play] readline-lite: motion, wrap-crossing '
              'insert, word ops, mid-line delete, an edited history '
              'recall, and OA-as-Meta all EXECUTED correctly')

        # ^C (docs/CONSOLE.md section 4): kill a foreground child stuck
        # reading stdin, get the prompt back, and prove nothing leaked.
        # cat with no args copies stdin->stdout, so the typed line shows
        # twice (tty echo + cat's own write) -- proof cat was really
        # running -- and then blocks in read, the worst case for a kill.
        #
        # SETTLED, not single-poll (wait_for_screen_settled's header has
        # the mechanism): a poll landing inside TTY_SCROLL's row copy
        # shows the ECHO's row twice, which satisfies the count while
        # the shell is still LOADING cat -- and a ^C typed then finds
        # nothing at spawn depth 3 to kill, because the child's PCB
        # does not exist yet. The kill sweep consumes K_INTR_PEND
        # either way (a ^C with nothing to kill is the DESIGNED idle
        # case, docs/CONSOLE.md sec 4), so the late-spawning cat then
        # runs unmolested and the phase times out -- which is exactly
        # how this WIP sat parked as "^C broken, no diagnosis" when
        # the kernel was fine.
        client.call_tool('type', {'text': 'CAT\r'})
        client.call_tool('type', {'text': 'HELLOCAT\r'})
        wait_for_screen_settled(client,
                                lambda rs:
                                screen_blob(rs).count('HELLOCAT') >= 2,
                                'cat to echo the line back')
        client.call_tool('type', {'text': '\\x03'})
        wait_for_screen(client,
                        lambda rs: '^C' in screen_blob(rs),
                        '^C echo')
        # A row that is EXACTLY "ALIVE" means echo ran as a COMMAND --
        # i.e. sh reaped the dead cat and reprompted. A live cat would
        # instead copy the whole line ("ECHO ALIVE") to stdout, which
        # contains ALIVE but never as a bare row -- teeth verified
        # against a sweep-less kernel, where the weaker 'ALIVE in blob'
        # form passed by exactly that route.
        client.call_tool('type', {'text': 'ECHO ALIVE\r'})
        wait_for_screen(client,
                        lambda rs: any(r.strip() == 'ALIVE' for r in rs),
                        'shell prompt back after ^C (child killed, '
                        'reaped, no leak)')
        print('[check-play] ^C killed the foreground cat; shell reprompted')

        # -----------------------------------------------------------
        # stty seed (SYS_TTYMODE/PRC_TTYMODE tty7.s, the raw fork in
        # tty3.s TTY_COOK1 + TTY_COOK_RAW, the NOECHO gates in
        # tty6.s, the crash-safety backstop PRC_TMD_RST in
        # procspawn2.s). `stty raw -echo; cat` typed as ONE compound
        # line is deliberate: the SHELL's own read() must never
        # observe the raw console, or its OWN line editing breaks
        # mid-test -- it is busy running the `;`-sequenced commands,
        # not blocked reading, until cat starts. stty's own SYS_EXIT
        # is voluntary and must NOT trip the backstop (see PRC_
        # TMD_RST's call-site notes) -- the mode it set has to
        # outlive it for this very idiom to work at all.
        client.call_tool('type', {'text': 'STTY RAW -ECHO ; CAT\r'})
        # let stty run and cat reach its blocking read before typing
        # anything raw mode is supposed to change the handling of
        for _ in range(10):
            client.call_tool('step', {'cycles': 200_000})
        # (a)+(b): a marker typed with NO trailing CR must appear
        # from CAT'S OWN COPY ALONE, exactly once. Cooked mode could
        # never deliver an uncommitted (no-CR) line to cat at all --
        # simple PRESENCE already proves ICANON is off (each
        # keystroke reaches read() immediately). An EXACT count of 1
        # (not 0, not 2+) proves ECHO is off too: if the driver were
        # still painting, the marker would show up twice (echo +
        # cat's copy) somewhere in the blob, contiguous or
        # interleaved -- either shape fails a strict ==1 check, so
        # this is sabotage-provable both directions at once.
        RAWMARK = 'QK9Z'
        client.call_tool('type', {'text': RAWMARK})
        wait_for_screen_settled(
            client,
            lambda rs: screen_blob(rs).count(RAWMARK) == 1,
            'a no-CR keystroke run to reach cat immediately, '
            'painted from cat\'s copy alone, exactly once '
            '(raw+noecho: ICANON off delivers it without CR, '
            'ECHO off means the driver never painted it too)')
        print('[check-play] stty raw -echo: keystrokes reach cat '
              'without CR and paint exactly once (no driver echo)')

        # (c): ^C still interrupts in raw mode -- it is intercepted
        # upstream of the ring (tty3.s TTY_KEYIN), unconditionally,
        # never gated by VC_TMODE. Same idiom as the cooked-mode ^C
        # phase above: kill cat, confirm the shell reaped it and
        # reprompted.
        client.call_tool('type', {'text': '\\x03'})
        wait_for_screen(client,
                        lambda rs: '^C' in screen_blob(rs),
                        '^C echo even in raw+noecho mode')
        client.call_tool('type', {'text': 'ECHO STILLALIVE\r'})
        wait_for_screen(
            client,
            lambda rs: any(r.strip() == 'STILLALIVE' for r in rs),
            'shell prompt back after ^C in raw mode (child killed, '
            'reaped, no leak)')
        print('[check-play] ^C still interrupts a raw+noecho reader')

        # (d): the CRASH-SAFETY BACKSTOP -- cat died by SIGNAL (^C),
        # never got to restore its own mode, and PRC_TMD_RST reset
        # the console it was reading from back to cooked+echo as
        # part of the kill sweep. Prove it with the SAME doubling
        # signature the very first cooked-mode ^C phase used: a
        # fresh `cat` sees the committed line TWICE (driver echo +
        # cat's own copy) only if BOTH ICANON and ECHO are back.
        client.call_tool('type', {'text': 'CAT\r'})
        client.call_tool('type', {'text': 'BACKTOCOOKED\r'})
        wait_for_screen_settled(
            client,
            lambda rs: screen_blob(rs).count('BACKTOCOOKED') >= 2,
            'a post-backstop cat to double-echo (cooked+echo '
            'restored automatically after the raw reader was '
            'killed)')
        client.call_tool('type', {'text': '\\x03'})
        wait_for_screen(client,
                        lambda rs: '^C' in screen_blob(rs),
                        '^C echo (cleanup: kill the second cat)')
        client.call_tool('type', {'text': 'ECHO CLEANEDUP\r'})
        wait_for_screen(
            client,
            lambda rs: any(r.strip() == 'CLEANEDUP' for r in rs),
            'shell prompt back after the cleanup ^C')
        print('[check-play] crash-safety backstop: the console came '
              'back to cooked+echo on its own after the raw reader '
              'was killed, with no process ever restoring it itself')

        # -----------------------------------------------------------
        # `sleep` ACTUALLY SLEEPS (docs/SHELL-GAPS.md sec 5). THIS is
        # the harness that can prove it: src/test/playtest.s links
        # src/kernel/timer.s, so TIMER_PROBE finds the AppleMouse VBL
        # on slot 5 and SYS_TICK reports a real, ADVANCING counter.
        # check-textaudit gates the other half -- the refusal on a
        # machine with no timer at all -- and neither harness can do
        # both, because the mode is whatever the probe finds.
        #
        # TWO-SIDED ON PURPOSE. A `sleep` that returned immediately
        # would satisfy "the prompt came back", so `SLEEP 0` fixes
        # what promptly MEANS on this machine and `SLEEP 1` has to be
        # visibly slower than it. Asserting elapsed CYCLES rather than
        # ticks keeps this independent of any kernel symbol address.
        # A BARE prompt, not `startswith('$')`. Right after typing, the
        # last non-blank row is the ECHO of the command -- `$ SLEEP 1`
        # -- which starts with '$' too, so the loose form returns TRUE
        # IMMEDIATELY and times the echo instead of the sleep. That is
        # the same before-snapshot trap `_prompt_back` above documents;
        # measured here as `SLEEP 1` finishing in 400k cycles while a
        # hand-driven `SLEEP 5` was still running at 5M.
        def _prompt_now(rs):
            nonblank = [r for r in rs if r.strip()]
            return bool(nonblank) and nonblank[-1].strip() == '$'

        def _timed(cmd, label):
            client.call_tool('type', {'text': cmd})
            for n in range(1, 1201):
                client.call_tool('step', {'cycles': 200_000})
                if _prompt_now(screen_rows(client)):
                    return n
            raise RuntimeError(f'timed out waiting for {label}')

        zero_steps = _timed('SLEEP 0\r', 'SLEEP 0 to return')
        one_steps = _timed('SLEEP 1\r', 'SLEEP 1 to return')
        # 200k cycles per step, ~1.02 MHz: one second is ~5 steps. The
        # floor is deliberately loose (4) and the ceiling generous (60)
        # -- this asserts that time PASSED, not the tick rate, which is
        # check-sched's job.
        if one_steps < 4:
            failures_early = (f'SLEEP 1 returned after {one_steps} steps '
                              f'(~{one_steps * 200_000} cycles) -- too fast '
                              f'to have waited a second. It did not sleep.')
            print(f'[check-play] FAIL: {failures_early}', file=sys.stderr)
            return 1
        if one_steps <= zero_steps:
            print(f'[check-play] FAIL: SLEEP 1 ({one_steps} steps) was not '
                  f'slower than SLEEP 0 ({zero_steps}) -- the operand is '
                  f'being ignored', file=sys.stderr)
            return 1
        print(f'[check-play] SLEEP 0 returned in {zero_steps} step(s); '
              f'SLEEP 1 took {one_steps} (~{one_steps * 200_000 / 1e6:.1f}M '
              f'cycles) -- it waited on a real VBL tick source')

        # -----------------------------------------------------------
        # `time` MEASURES (docs/SHELL-GAPS.md sec 5). Same harness,
        # same reason: playtestb.s calls TIMER_PROBE and the machine
        # has an AppleMouse, so the tick is real. check-textaudit
        # gates the refusal on a machine with no timer at all.
        #
        # THE INTEGER SECONDS ARE THE ASSERTION, not the tenth: spawn
        # and load cost real time on top of the sleep, so pinning
        # "2.0" exactly would be pinning this build's overhead. Both
        # values are checked so a `time` that printed a constant
        # cannot pass -- 0 and 2 have to come out different.
        def _timed_cmd(cmd, want):
            client.call_tool('type', {'text': cmd})
            for _ in range(1200):
                client.call_tool('step', {'cycles': 200_000})
                blob = screen_blob(screen_rows(client))
                if want in blob:
                    return blob
            raise RuntimeError(
                f'timed out waiting for {want!r} after {cmd!r}; '
                f'screen was:\n{screen_blob(screen_rows(client))}')

        _timed_cmd('TIME SLEEP 0\r', 'real 0.')
        print('[check-play] `time sleep 0` reported real 0.x')
        _timed_cmd('TIME SLEEP 2\r', 'real 2.')
        print('[check-play] `time sleep 2` reported real 2.x -- the '
              'operand reaches the measurement')


        # -----------------------------------------------------------
        # Command substitution, TYPED THE WAY A HUMAN TYPES IT
        # (docs/SHELL-GAPS.md sec 2; goal: gate the typed form).
        # These exist because the whole $( ) failure of 2026-08-27
        # was invisible to every script-fed gate in the tree and its
        # SYMPTOM was a screen row: `$ AC` where `ABC` belonged --
        # an empty capture with $?=0, prefixed by the child shell's
        # OWN prompt escaping to the console. So each case here
        # asserts EXACT ROWS: the echoed command, then output rows
        # byte-exact, then the next prompt -- a stray child prompt,
        # a missing capture byte, or interleaved output all land IN
        # one of the asserted rows and fail loudly. Teeth verified
        # 2026-08-27 against both regressions: bare-close instead of
        # FCLOSE turns ABC into AC (rows[i+1] mismatch), and an
        # always-prompting child turns it into `$ $ ABC` (ditto).
        def _typed_case(cmd, out_rows, label):
            # Type only at a SETTLED prompt (bare '$' is the last
            # non-blank row), the way a human does. Typing ahead
            # while the prompt is still in liba's line buffer makes
            # the flush interleave with the keystroke echo ("ECH$ O
            # ..."), which is type-ahead display behavior, not a
            # shell defect -- and it would corrupt the echoed row
            # this case anchors its assertions on.
            wait_for_screen(client, _prompt_now,
                            f'settled prompt before {cmd!r}')
            client.call_tool('type', {'text': cmd + '\r'})
            echoed = '$ ' + cmd
            for _ in range(1200):
                client.call_tool('step', {'cycles': 200_000})
                rows = screen_rows(client)
                stripped = [r.rstrip() for r in rows]
                if echoed not in stripped:
                    continue
                i = len(stripped) - 1 - stripped[::-1].index(echoed)
                need = stripped[i + 1:i + 1 + len(out_rows)]
                after = stripped[i + 1 + len(out_rows):i + 2 + len(out_rows)]
                if need == out_rows and after and after[0] == '$':
                    return
            print(f'[check-play] FAIL: {label}: after {cmd!r} expected '
                  f'rows {out_rows!r} then a bare prompt; screen was:',
                  file=sys.stderr)
            print(screen_blob(screen_rows(client)), file=sys.stderr)
            raise RuntimeError(label)

        # The canonical splice, the exact line the bug was found on.
        _typed_case('ECHO A$(ECHO B)C', ['ABC'],
                    'typed splice $(ECHO B) inside a word')
        # Assignment form is SILENT (no output row, no child prompt
        # between the echo and the next prompt), then expands.
        _typed_case('X=$(PWD)', [],
                    'typed assignment X=$(PWD) stays silent')
        _typed_case('ECHO [$X]', ['[/mnt/MAUX/]'],
                    'typed $X carries the captured cwd')
        # Arguments survive the token split, typed.
        _typed_case('Z=$(ECHO ONE TWO)', [],
                    'typed assignment with arguments stays silent')
        _typed_case('ECHO [$Z]', ['[ONE TWO]'],
                    'typed capture keeps its interior space')
        # A pipe INSIDE $( ) -- the body is a whole nested sh.
        _typed_case('ECHO X$(ECHO P | CAT)Y', ['XPY'],
                    'typed | inside $( ) runs as a pipeline')
        # Empty capture splices to nothing, and $? is 0.
        _typed_case('ECHO N:$(ECHO):', ['N::'],
                    'typed empty capture, cleanly')
        _typed_case('ECHO S$?', ['S0'],
                    'typed $? after a substitution is 0')
        # Nesting is still refused LOUDLY at the tty: diagnostic row,
        # then $? reads 1.
        _typed_case('ECHO $(ECHO $(ECHO W))',
                    ['sh: $(): unclosed, or nested'],
                    'typed nested $( ) refused with its diagnostic')
        _typed_case('ECHO E$?', ['E1'],
                    'typed $? after the refusal is 1')
        # -----------------------------------------------------------
        # ---- quoted assignment + IFS splitting (2026-08-28) -------
        # TYPED, because `V='a b'` is a form a HUMAN reaches for and
        # this shell answered it with `sh: mixed quoting` until the
        # day these landed. That refusal was invisible to every
        # script-fed gate in the tree for months -- the scripts were
        # written by someone who already knew it did not work, which
        # is the failure shape docs/SH-FEATURES.md's own "typed the
        # way a human types it" block exists to prevent.
        #
        # THE VALUE HAS A DOUBLE SPACE, and that is the whole design
        # of the pair: `[$V]` unquoted splits into two fields and
        # `echo` rejoins them with ONE space, while `"[$V]"` keeps
        # the run intact. A single-spaced value prints identically
        # both ways and would assert nothing. Derived from bash on
        # the identical words, not authored.
        _typed_case("V='A  B'", [],
                    'typed quoted assignment is silent and accepted')
        _typed_case('ECHO [$V]', ['[A B]'],
                    'typed unquoted expansion splits -- the run of '
                    'spaces collapses to one on rejoin')
        _typed_case('ECHO "[$V]"', ['[A  B]'],
                    'typed quoted expansion does NOT split -- the '
                    'double space survives')
        # -----------------------------------------------------------
        # ---- `$$` -- this shell's process number -----------------
        # NOT pinned to a literal. The shell's `$$` is checked
        # against R_SH_PID, which the HARNESS recorded from its own
        # SC_SPAWN -- an independent source, so a `$$` stuck at any
        # constant fails unless that constant happens to be the pid
        # the kernel actually handed out. Then a `$( )` subshell's
        # `$$` must DIFFER, which is the property that makes `$$`
        # usable for unique temp names at all.
        #
        # This case is why the feature exists in this shape: `$$`
        # reads BANK_ID ($FF2E), the per-bank identity byte, because
        # a pid IS its RamWorks bank (spawn stores one PRC_ALLC_BANK
        # value into both PRC_CHLD_BANK and PRC_CHILD_PID). It also
        # found that BANK_ID had NEVER been stamped correctly -- see
        # procspawn.s PRC_STMP_BANK.
        harness_pid = peek_aux1(client, R_SH_PID)[0]
        wait_for_screen(client, _prompt_now, 'settled prompt before $$')
        client.call_tool('type', {'text': 'ECHO P:$$ S:$(ECHO $$)\r'})
        pidrow = None
        for _ in range(1200):
            client.call_tool('step', {'cycles': 200_000})
            for r in (x.rstrip() for x in screen_rows(client)):
                if r.startswith('P:') and ' S:' in r:
                    pidrow = r
                    break
            if pidrow:
                break
        if not pidrow:
            print('[check-play] FAIL: no `$$` output row; screen was:',
                  file=sys.stderr)
            print(screen_blob(screen_rows(client)), file=sys.stderr)
            return 1
        try:
            ppid = int(pidrow.split('P:')[1].split()[0])
            spid = int(pidrow.split('S:')[1].split()[0])
        except (ValueError, IndexError):
            print(f'[check-play] FAIL: unparseable `$$` row {pidrow!r}',
                  file=sys.stderr)
            return 1
        if ppid != harness_pid:
            print(f'[check-play] FAIL: `$$` is {ppid}, but the harness '
                  f'recorded the shell as pid {harness_pid} -- the shell '
                  f'does not know its own process number',
                  file=sys.stderr)
            return 1
        if spid == ppid:
            print(f'[check-play] FAIL: a `$( )` subshell reported the '
                  f'SAME `$$` ({spid}) as its parent -- a per-process '
                  f'value that never varies is not one', file=sys.stderr)
            return 1
        # `spid != ppid` ALONE IS NOT ENOUGH, and the hole is not
        # theoretical: `P:3 S:99` satisfies it while 99 is not a pid
        # any process could have. A pid IS a RamWorks bank number, so
        # it must be non-zero (0 is the kernel's own bank, never a
        # child) and inside PCB_COUNT. Found by review
        # 2026-08-27, which supplied exactly that passing-but-wrong
        # output.
        if not 0 < spid < PCB_COUNT:
            print(f'[check-play] FAIL: a `$( )` subshell reported `$$` = '
                  f'{spid}, which is not a pid any process can hold -- a '
                  f'pid is its RamWorks bank, so 0 < pid < {PCB_COUNT}',
                  file=sys.stderr)
            return 1
        print(f'[check-play] `$$` = {ppid}, matching the pid the harness '
              f'spawned; the subshell reported {spid} -- distinct, and '
              f'a bank a process can actually hold')

        # ---- `${...}` and V7's four conditional forms ------------
        # All five are V7 (confirmed against the manual, not
        # recalled: learning:01M10WZW2BWWX6X4DYF4E5AD3D). The
        # braces case is the reason the form exists -- `${V}X` is
        # unwritable without them. Three bugs were found HERE and
        # only here, all silent: a stray `}` (EMITSTRP clobbers Y),
        # a stale-carry branch (`ror` shifts bit 0 OUT into carry),
        # and a truncated word (VARSET clobbers PTR0, which its own
        # header does not list).
        _typed_case('BV=set', [], 'a variable to reference')
        _typed_case('ECHO [${BV}X]', ['[setX]'],
                    'braces separate the name from what follows')
        _typed_case('ECHO [${BV-d}] [${BU-d}]', ['[set] [d]'],
                    '${x-word}: value if set, else the word')
        _typed_case('ECHO [${BV+p}] [${BU+p}]', ['[p] []'],
                    '${x+word}: the word only if SET')
        _typed_case('ECHO [${BQ=made}] [${BQ}] [${BQ=no}]',
                    ['[made] [made] [made]'],
                    '${x=word} assigns once, then reads back')
        _typed_case('ECHO [${BZ?}]', ['sh: ${?}: parameter not set'],
                    '${x?} diagnoses and abandons the line')
        _typed_case('ECHO AFTER$?', ['AFTER1'],
                    '...with a nonzero status')
        print('[check-play] typed ${...}: braces, and all four V7 '
              'conditional forms (- + = ?)')

        # ---- `$$` AT THE EXPANSION-BUFFER BOUNDARY ----------------
        # EMITPID reserves 4 bytes (up to 3 digits AND U2DEC's own
        # NUL) and skips when EXPX + 4 >= EXPBUFLEN. But EXPBUF is
        # indexed 0..EXPBUFLEN-1, so EXPX + 4 == EXPBUFLEN still
        # FITS: digits at 124/125/126, terminator at 127. The plain
        # `>=` therefore drops `$$` ONE BYTE EARLY, silently, with
        # room to spare -- a wrong answer, not a refusal.
        #
        # 93 literal + a 31-byte value (VARVALLEN) puts EXPX at
        # exactly 124 in a 102-char line, well inside LINEMAX 127.
        # Four 31-byte variables (the obvious repro) cannot be set up
        # inside one line, which is why this lives here and not in
        # the e2e corpus: that harness is one line per case.
        lit, val = 'Z' * 93, 'Y' * VARVALLEN
        _typed_case(f'BQ={val}', [], 'a 31-byte value, the max')
        wait_for_screen(client, _prompt_now, 'settled prompt before $$ edge')
        client.call_tool('type', {'text': f'ECHO {lit}$BQ$$\r'})
        want = lit + val + str(ppid)
        seen = None
        for _ in range(1200):
            client.call_tool('step', {'cycles': 200_000})
            # Join UNSTRIPPED: the answer is 124+ chars, so it wraps
            # at column 80 and rstripping would eat the wrap column.
            blob = ''.join(screen_rows(client))
            # The echoed command also contains the literal, so anchor
            # on the one followed by the VALUE -- only the output is.
            i = blob.find(lit + val)
            if i >= 0:
                seen = blob[i:i + len(want)]
                if seen == want:
                    break
        if seen != want:
            print(f'[check-play] FAIL: `$$` at the expansion-buffer edge. '
                  f'Expected {len(want)} chars ending in the pid '
                  f'{ppid!r}; got {seen!r}.', file=sys.stderr)
            if seen is not None and seen.rstrip() == (lit + val).rstrip():
                print('[check-play]   -- the pid is MISSING entirely: '
                      '`$$` was dropped at EXPX=124 though it fits.',
                      file=sys.stderr)
            return 1
        print(f'[check-play] `$$` survives at EXPX={len(lit) + len(val)} '
              f'of EXPBUFLEN -- the last position where it still fits')

        # THE POSIX SEMANTICS, typed: the three rows of
        # docs/SHELL-GAPS.md sec 2's own divergence table, where
        # maux disagreed with bash because the PARENT expanded the
        # body before the child saw it. All three agree with bash
        # since 2026-08-27 (expander skips the span + unexported
        # variables serialise + TOKENIZE stops judging the outer
        # token by the body's quotes).
        _typed_case('V=one', [], 'unexported V set in the parent')
        # 1. An UNEXPORTED variable still reaches the subshell --
        #    not by pre-expansion (which is gone) but because the
        #    parent serialises it as an assignment ahead of the body.
        _typed_case('ECHO [$(ECHO $V)]', ['[one]'],
                    'unexported variable crosses into the subshell')
        # 2. A body that SETS a variable sees its OWN value. This is
        #    the row that could not work at all under pre-expansion:
        #    bash [2], maux was [1].
        _typed_case('ECHO [$(V=2 ; ECHO $V)]', ['[2]'],
                    'body assignment shadows the parent, V7-style')
        # 3. ...and the parent's V is untouched by it.
        _typed_case('ECHO [$V]', ['[one]'],
                    "the subshell's assignment did not leak back")
        # 4. Quotes inside the body belong to the SUBSHELL. bash
        #    prints [$V]; maux printed [] (pre-expansion ate them),
        #    then briefly `sh: mixed quoting` (the outer token judged
        #    by the inner body's quotes) before TOKENIZE learned that
        #    a quote inside a $( ) span is content.
        _typed_case("ECHO [$(ECHO '$V')]", ['[$V]'],
                    'quotes inside the body are the subshell\'s')
        # A value holding a SPACE crosses too, backslash-escaped --
        # this is the case that decides whether the serialiser is
        # usable at all. Before escaping was used, one spaced
        # variable poisoned EVERY later substitution in the session
        # (the serialiser refused, so nothing could be captured
        # again), which is why it is gated with a substitution that
        # does not mention it: the poisoning was collateral.
        # `SP=x\ y`, the way a human writes a spaced assignment here
        # -- an unescaped `SP=x y` assigns `x` and RUNS `y`, which
        # is the shell being right, not a bug.
        _typed_case('SP=x\\ y', [], 'a spaced value assigns')
        _typed_case('ECHO [$(ECHO $SP)]', ['[x y]'],
                    'a value with a space crosses, escaped')
        _typed_case('ECHO M$(ECHO ok)N', ['MokN'],
                    'an unrelated substitution still works after it')
        print('[check-play] POSIX $( ) semantics typed: unexported '
              'variables cross, a body assignment shadows without '
              'leaking back, and body quotes belong to the subshell')

        # -----------------------------------------------------------
        # `( commands )` -- the GROUPING construct, typed.
        # -----------------------------------------------------------
        # The body survives its own `;` (TOKENIZE keeps a leading-`(`
        # span together the way it already does for `$( )`), output
        # is NOT captured -- it goes straight to the tty -- and the
        # exit status is the child's.
        _typed_case('( ECHO A ; ECHO B )', ['A', 'B'],
                    'typed group runs both commands in order')
        _typed_case('ECHO G$?', ['G0'],
                    "the group's exit status reaches the parent")
        # VARIABLES ISOLATE, which is the half of subshell semantics
        # maux can actually deliver: the child gets the parent's
        # unexported variables (serialised, same as `$( )`) and its
        # own assignment does not travel back.
        _typed_case('GV=parent', [], 'parent sets an unexported var')
        # The group READS a parent variable it does not set. This
        # case exists because its absence was caught by sabotage:
        # with the serialisation removed, the shadowing case below
        # stayed GREEN -- its body sets GV itself, so it never
        # needed the parent's value at all. A case that supplies
        # its own answer cannot test where the answer came from.
        _typed_case('( ECHO SEE:$GV )', ['SEE:parent'],
                    "the parent's unexported variable reaches the group")
        _typed_case('( GV=child ; ECHO IN:$GV )', ['IN:child'],
                    'the group shadows it locally')
        _typed_case('ECHO OUT:$GV', ['OUT:parent'],
                    "the group's assignment did not leak back")
        # An unclosed group is refused LOUDLY, not run.
        _typed_case('( ECHO A', ['sh: (): unclosed'],
                    'an unclosed group is refused with a diagnostic')
        # NESTED groups. Found by adversarial review, not by a gate:
        # the outer span used to close at the INNER `)`, so the child
        # got a truncated body AND `ECHO OUTER )` then ran in the
        # PARENT -- a wrong answer wearing a diagnostic. Asserting
        # BOTH lines in order is what makes this a nesting test
        # rather than a "something ran" test.
        _typed_case('( ( ECHO INNER ) ; ECHO OUTER )', ['INNER', 'OUTER'],
                    'a nested group runs, inner first, nothing leaking')
        # A group cannot be a PIPELINE STAGE -- refused, not
        # silently run. Third instance of the same hole (redirect,
        # `&`, `|`): everything RUN_PIPELINE does that CHCK_GROUP
        # bypasses must be honoured or refused. Measured before the
        # check existed: this printed GPIPE and no counts, i.e. the
        # `|` vanished and WC never saw the group's output. The
        # NEXT case reads $? back, because a diagnostic alone does
        # not prove the group did not also run.
        _typed_case('( ECHO GPIPE ) | WC', ['sh: (): no redirect|pipe'],
                    'a group as a pipeline stage is refused')
        _typed_case('ECHO PP$?', ['PP1'],
                    'and the refusal set a nonzero status')
        print('[check-play] typed ( ) group: ran a `;` body in order, '
              'propagated its status, isolated its variables, and '
              'refused an unclosed group loudly')

        # ---- `cd ..` lands in the PARENT, not the volume root ----
        # Added BEFORE the per-process-cwd work that could break it.
        # The pre-existing `..` cases assert only the ROOT CLAMP
        # (`cd ..` at /mnt/MAUX stays at /mnt/MAUX), which a `..` resolved
        # against the WRONG BASE would satisfy too -- so nothing in
        # the tree could tell correct dot-dot from dot-dot popping
        # from the boot prefix. This case can.
        _typed_case('MKDIR /mnt/MAUX/DD', [], 'a directory to descend into')
        _typed_case('MKDIR /mnt/MAUX/DD/E', [], 'and one below it')
        _typed_case('CD /mnt/MAUX/DD/E', [], 'descend two levels')
        _typed_case('CD ..', [], 'up one')
        _typed_case('PWD', ['/mnt/MAUX/DD/'],
                    '`cd ..` landed in the PARENT, not the root')
        _typed_case('CD ..', [], 'up one more')
        _typed_case('PWD', ['/mnt/MAUX/'], 'and again')
        _typed_case('CD ..', [], 'up from the volume root')
        _typed_case('PWD', ['/mnt/'],
                    'docs/VROOT.md: volumes live under /mnt, so `cd ..` '
                    'from a volume root lands in /mnt (docs/CD.md\'s '
                    '2026-09-30 addendum, MKP_POP, on the virtual text)')
        _typed_case('CD ..', [], 'and up from /mnt')
        _typed_case('PWD', ['/'],
                    'docs/DEVFS.md, 2026-09-30: "/" is a REAL '
                    'pseudo-root ABOVE every volume, so `cd ..` '
                    'actually moves, same as from any other directory')

        # ---- THE CWD ISOLATES, which is what `( )` is FOR --------
        # This was a KNOWN DEFECT PIN until 2026-08-27: it asserted
        # the LEAK (the parent's cwd moving with the child's) so
        # that fixing it would go RED and announce itself. It did
        # exactly that when per-process cwd landed, and the pin is
        # retired here into the assertion it was holding a place
        # for. Kept as a pair on purpose: the child must SEE its own
        # cd, and the parent must NOT.
        # CD /mnt/MAUX first: the `cd ..` sequence just above now
        # legitimately leaves the shell at "/" (docs/DEVFS.md's
        # pseudo-root, not the old volume-root clamp), and this
        # block's own point is cwd ISOLATION, not chained `..`
        # state -- give it a known starting directory.
        _typed_case('CD /mnt/MAUX', [], 'a known starting directory')
        _typed_case('MKDIR /mnt/MAUX/GRPD', [],
                    'a directory to cd into')
        _typed_case('( CD /mnt/MAUX/GRPD ; PWD )', ['/mnt/MAUX/GRPD/'],
                    'the group cds and reports its OWN cwd')
        _typed_case('PWD', ['/mnt/MAUX/'],
                    "the PARENT's cwd is untouched -- the whole "
                    'point of a subshell')
        # ...and a relative open in the parent must agree with what
        # PWD just said. That is the half a pwd-only check misses:
        # until the syscall answered from the per-process table,
        # those two could disagree.
        _typed_case('ECHO PCWD > PF1', [],
                    'parent writes a file relatively')
        _typed_case('CAT /mnt/MAUX/PF1', ['PCWD'],
                    "and it landed in the PARENT cwd, not the group's")
        print('[check-play] ( ) cwd ISOLATES: the group sees its own '
              "cd, the parent keeps its own, and the parent's "
              'relative opens agree with its own PWD')


        print('[check-play] typed $( ) cases: splice, silent assignment, '
              'argument capture, pipeline body, empty capture, $? both '
              'ways, nesting refusal -- all byte-exact rows with no '
              'stray child prompt')

        # THE VIRTUAL CONSOLES, end to end, and BEFORE THE ^D
        # SHUTDOWN, which must stay the finale (docs/CONSOLE.md sec
        # 13). The first cut of this phase sat AFTER the shutdown
        # block below -- typing at a machine whose shell had already
        # exited and been reaped -- and the redirect "hanging" there
        # was this WIP's parked no-diagnosis bug. Per-fd routing
        # means the shell is bound to console 1 (PRC_DFLT_FDS seeds
        # fd 0/1/2 to FD_TTY0), so switching the GLASS does not drag
        # the shell along -- which is why the chvt leg below is ONE
        # COMPOUND COMMAND that comes back by itself: after a bare
        # `CHVT 2` the keyboard feeds console 2 while the shell reads
        # console 1, and nothing could ever type the ^D. The shell
        # needs no keyboard BETWEEN commands of a compound, so
        # `CHVT 2 ; SLEEP 2 ; CHVT 1` shows console 2's glass for ~2
        # real seconds (the timer is proven by the sleep phase above)
        # and restores console 1, leaving the session two-way again.
        #
        # The phase exercises the whole of sec 13 at once:
        #
        #   1. `> /dev/tty2` opens the SECOND console by name (the
        #      /dev namespace) and writes to it. The glass must NOT
        #      show it -- if the handle were still being discarded,
        #      as it was before this work, the text would land on
        #      screen and this assertion fails.
        #   2. `chvt 2` brings that console to the glass, and the
        #      text must appear -- which only the console store can
        #      do, since the write never touched the glass at all.
        #   3. `chvt 1` runs while console 2 holds the glass, so its
        #      ESC [ 1 z travels the REDIRECTED write path -- the
        #      case that used to shred both consoles' structs until
        #      TTY_CSI_VT learned to park the switch for
        #      TTY_WR_LEAVE. Console 1's screen coming back intact
        #      is the assertion that the parked switch runs clean.
        #
        # COUNTED, not merely absent, and only once the prompt is back.
        # BGMARK is on screen once no matter what -- the shell echoes
        # the command line as it is typed -- so "did the OUTPUT land
        # here too" is a question about the SECOND occurrence. An
        # earlier version asserted absence and read the screen straight
        # after typing: it raced echo's own output and passed against
        # the sabotage it was written to catch.
        # The prompt-back wait is the BARE-ROW form (the sleep phase's
        # _prompt_now trap, same reason): the screen is full of '$ '
        # from every earlier phase, so a count of PROMPT is true before
        # the command even runs -- and a count sampled that early would
        # miss a second BGMARK still in flight, passing against the
        # exact sabotage this phase exists to catch. SETTLED because
        # the count below must not read a mid-scroll tear either
        # (wait_for_screen_settled's header).
        # A NEW FILE IN /mnt/MAUX, then a retained `sh`, BEFORE the phase
        # (docs/KFIX-NOTES.md item 3): the `( )` group runs in a child
        # sh whose bank is kept when it exits, so the shell `CHVT 2`
        # starts on console 2 is a warm spawn and prompts ~0.6M cycles
        # after the glass reaches it instead of ~2.8M. That is a timing
        # the phase's cleanliness check below must be indifferent to
        # (it is -- console2_dirty allows that shell's prompt), and with
        # this row in front of it every run exercises it. The two file
        # names are absolute: the shell's cwd here is `/`.
        _typed_case('( ECHO a > /mnt/MAUX/VCW )', [],
                    'a new file is created by a child sh before the '
                    'virtual-consoles phase')
        _typed_case('RM /mnt/MAUX/VCW', [], 'and removed again')
        client.call_tool('type', {'text': 'ECHO BGMARK > /dev/tty2\r'})

        def _idle_prompt(rs):
            nonblank = [r for r in rs if r.strip()]
            return bool(nonblank) and nonblank[-1].strip() == '$'

        rows = wait_for_screen_settled(
            client, _idle_prompt,
            'the prompt to come back after the redirect')
        seen = screen_blob(rows).count('BGMARK')
        if seen != 1:
            print(f'[check-play] FAIL: BGMARK appears {seen}x on console 1, '
                  f'expected exactly 1 (the echoed command line). A second '
                  f'copy is echo\'s OUTPUT landing on the glass -- the '
                  f'fd\'s console handle is being discarded, so every '
                  f'console is the same console', file=sys.stderr)
            return 1
        print('[check-play] a write to /dev/tty2 stayed off console 1')
        client.call_tool('type', {'text': 'CHVT 2 ; SLEEP 2 ; CHVT 1\r'})
        # SETTLED: the cleanliness assert below reads these rows, and a
        # single poll can land mid-blit with console 1 rows lingering.
        rows = wait_for_screen_settled(
            client,
            # NOT just "BGMARK is present": console 1 already shows it
            # in the echoed command line, so that would be true before
            # the switch and wait for nothing. Console 2's screen holds
            # echo's OUTPUT and nothing else -- no command line, so no
            # "/dev/tty2" on it. That pair only becomes true after the
            # glass actually changes.
            lambda rs: ('BGMARK' in screen_blob(rs)
                        and '/dev/tty2' not in screen_blob(rs)),
            "console 2's stored screen to reach the glass",
        )
        # Console 2 holds echo's output and its OWN shell's prompt and
        # NOTHING else (console2_dirty). `CHVT 2` starts a shell on a
        # console that has none (check-lazyvc), so console 2 legitimately
        # grows a `$` one row under the BGMARK row a moment after the
        # glass reaches it; this used to assert "BGMARK and nothing
        # else" and passed only when the sample landed before that
        # prompt -- a race against a cold load of sh, which an earlier
        # row that merely leaves a retained sh bank (`( ECHO a > X )`)
        # turns from ~2.2M cycles into ~0.6M (docs/KFIX-NOTES.md 3).
        # Every other row, INCLUDING row 0, must be blank. Row 0
        # used to be excused here (a globally shared reserved status
        # line, not per-console); as of the 2026-09-03 reclaim it is
        # ordinary per-console content like every other row, so this is
        # also the "row 0 really is per-console now" proof. Teeth
        # against a real corruption, not a hypothetical: the first cut
        # of TTY_STORE_Y returned with the caller's BANK NUMBER in A, so
        # the redirected clear filled the store with rows of inverse
        # letters -- and this phase PASSED over it, because it only
        # asked whether BGMARK was present (review findings 1 and
        # 6, 2026-08-31).
        dirty = console2_dirty(rows)
        if dirty:
            print(f'[check-play] FAIL: console 2 should hold only the '
                  f'BGMARK row and, at most, its own shell\'s prompt '
                  f'directly under it; offending rows {dirty}: '
                  f'{[rows[i] for i in dirty[:3]]!r} -- the redirected '
                  f'clear or store writes are leaking garbage',
                  file=sys.stderr)
            return 1
        wait_for_screen_settled(
            client,
            # Console 1 restored AND idle: its echoed command lines
            # (which contain "/dev/tty2") are back on the glass and
            # the shell has reprompted -- the parked chvt-1 switch
            # ran clean and the session is two-way again.
            lambda rs: '/dev/tty2' in screen_blob(rs) and _idle_prompt(rs),
            "console 1's screen to be RESTORED from the console store",
        )
        print('[check-play] virtual consoles: a write reached a background '
              'console, chvt showed its store on the glass, and the round '
              'trip restored console 1')

        # ---- sh's $D000 segment across the console switch (KFIX3
        # item 0). `test` is TEST_EVAL, code in the process language
        # card's $C08B bank at $D000. Console 1's shell sat through
        # two switches, ticks and another shell's whole life (CHVT 2
        # started one); its bank select and write-enable are the
        # machine's, not its own. A `test` that answers both ways
        # proves the segment is still there and still executes.
        client.call_tool('type', {'text': 'TEST -d /bin && ECHO TD-YES\r'})
        wait_for_screen_settled(
            client,
            lambda rs: any(r.strip() == 'TD-YES' for r in rs)
            and _idle_prompt(rs),
            "sh's $D000 segment (TEST_EVAL) to answer after the switch",
        )
        client.call_tool('type', {'text': 'TEST -f /bin || ECHO TF-NO\r'})
        wait_for_screen_settled(
            client,
            lambda rs: any(r.strip() == 'TF-NO' for r in rs)
            and _idle_prompt(rs),
            "sh's $D000 segment (TEST_EVAL) to answer 'no' too",
        )
        print('[check-play] sh $D000 segment: test answered yes and no '
              'after the console round trip')

        # ---- SYS_DUP2, from the shell's own `exec` (docs/KGAPS.md) --
        # PRC_DUP2 (procmli2.s) was the one kernel syscall body NO play
        # gate reached: sh's per-command redirections go through
        # spawn's fdactions (PRC_DUP2_SET), and the only userland
        # caller of SYS_DUP2 itself is `exec`'s no-command form
        # (shsgblt.s SB_EXECRD), which check-shlang types on ITS image,
        # not this one. Typed here the way a person writes it, inside
        # a `( )` so the group's child moves ITS fds and the console
        # shell keeps its own (the child's table is the CALLER's table
        # -- that is the whole difference from fdactions). Cwd is
        # /mnt/MAUX from the block above; every file is removed again.
        _typed_case('( exec > DUPO ; ECHO via-dup2 )', [],
                    'dup2 onto fd 1: the group\'s stdout moved to a file')
        _typed_case('CAT DUPO', ['via-dup2'],
                    'and the bytes landed in the file, not on the glass')
        # dup2 onto an fd that is ALREADY open closes it first: fd 3 is
        # pointed at DUPA, then re-pointed at DUPB; the write through
        # fd 3 must land in DUPB and DUPA must stay empty.
        # (40 columns: the echoed command must fit ONE row, so the
        # names are one letter and the text one digit. It fills the row
        # exactly, which parks the cursor in the pending-wrap column and
        # the Enter's newline then leaves one blank row before the next
        # prompt -- hence the single '' below.)
        _typed_case('( exec 3> A ; exec 3> B ; ECHO 2 >&3 )',
                    [''], 'dup2 onto an open fd re-points it')
        _typed_case('CAT A', [],
                    'the first target got nothing (its fd was replaced)')
        _typed_case('CAT B', ['2'],
                    'the second target got the write through fd 3')
        # oldfd CLOSED: PRC_CUR_FDOBJ refuses it, the kernel reports
        # it, sh says so and the status is 1 -- not a silent success.
        _typed_case('( exec 4>&3 ; ECHO st$? )',
                    ['sh: exec: cannot redirect', 'st1'],
                    'dup2 from a closed fd is refused loudly')
        _typed_case('RM DUPO A B', [], 'the dup2 fixtures go away')
        print('[check-play] SYS_DUP2 via `exec`: onto fd 1 (bytes in the '
              'file, none on the glass), onto an open fd 3 (re-pointed, '
              'the old target untouched) and from a closed fd (refused, '
              'status 1)')

        # ---- a program rewritten after it ran does not run STALE ---
        # (docs/KGAPS.md, lazyfree.s LZ_INVAL.) A finished process's
        # bank is retained, tagged with its program's absolute path,
        # and the next spawn of the same path reuses it with NO load.
        # ProDOS mtimes have MINUTE resolution, so a rewrite seconds
        # after a run is invisible to the mtime compare: the write
        # path (SYS_CREAT/UNLINK/RENAME) must drop the tag, and LZ_INVAL's
        # match arm -- the bank-releasing HELD arm -- had NEVER run
        # under any play gate. The cwd was set above (`CD /mnt/MAUX`),
        # so `LZP` resolves to the same absolute key the spawn tagged.
        # (A shell that has never chdir'd leaves a relative path
        # relative and the key never matches: docs/KGAPS-NOTES.md.)
        # The two programs are told apart by what they PRINT: echo
        # prints its argument, true prints nothing, so a stale image
        # shows up as the wrong output, not as a flag.
        _typed_case('CP /BIN/ECHO LZP', [], 'a program to run')
        _typed_case('/mnt/MAUX/LZP one', ['one'],
                    'it runs (and its bank is retained, tagged)')
        _typed_case('RM LZP', [], 'unlink it: the tag must go')
        _typed_case('CP /BIN/TRUE LZP', [], 'a DIFFERENT program, same name')
        _typed_case('/mnt/MAUX/LZP one', [],
                    'the new program ran (true: no output) -- a stale '
                    "echo image would print 'one'")
        _typed_case('CP /BIN/ECHO LZP', [],
                    'cp overwrites it (CREATE hits the name, then unlink)')
        _typed_case('/mnt/MAUX/LZP two', ['two'],
                    'the rewritten program ran, not the retained one')
        _typed_case('CP /BIN/TRUE LZP', [], 'and rewritten once more')
        _typed_case('/mnt/MAUX/LZP three', [],
                    'again the NEW image (true), same minute')
        _typed_case('RM LZP', [], 'the lazy-free fixture goes away')
        print('[check-play] lazy free: a program unlinked or overwritten '
              'after it ran never runs from its retained bank (three '
              'rewrites in one minute, each showing the new image)')

        # ---- a pipe writer whose reader is gone is told so ---------
        # (docs/KGAPS.md, procmli3.s PRC_WRITE's pipe arms.) `true`
        # never reads. `cat` fills the pipe's 255 bytes and BLOCKS in
        # the full-pipe arm (PRC_BLCK_RTRY on PIPE_WR_CHAN); when `true`
        # exits the reader count drops to zero, the writer wakes, its
        # retried write meets the no-readers arm and gets ERR_PIPE, and
        # cat stops. The observable is the prompt coming back: if either
        # arm let the writer carry on, cat would spin or sleep forever
        # on a pipe nobody drains and the row would time out. Neither
        # `cat` nor sh prints anything for the dead pipe, so the
        # expected rows are none. /BIN/SH is 28 KB, far over 255.
        _typed_case('CAT /BIN/SH | TRUE', [],
                    'a writer to a pipe whose reader exited is released')
        _typed_case('CAT /BIN/SH | SLEEP 1', [],
                    'a writer blocked on a full pipe is released when '
                    'its reader exits')
        print('[check-play] pipe writers: cat into a reader that never '
              'reads (true, sleep) is released with EPIPE once the '
              'reader exits -- the full-pipe and no-readers arms of '
              'SYS_WRITE both ran, and the prompt came back')

        # ---- the spawn loader's refusals (docs/KGAPS.md) -----------
        # PRC_LD_FL_IMG (procspawn3.s) has an error arm for every
        # step, and four of them are provokable by TYPING: a command
        # that names a path that is not there (GET_FILE_INFO fails,
        # then the OPEN does -- sh spawns an absolute path without
        # looking first), an image whose load base is outside the
        # process window (PRC_CHK_BASE), and an image over 64 KB
        # (the EOF's high byte). What the rows prove is that the
        # loader REFUSES (a loader that tried to load 68 KB into a
        # 46 KB window would corrupt the machine, and the next row
        # would not run) and that the shell and the volume are
        # intact afterwards -- and, since the messages diverged,
        # that it refuses each for the RIGHT REASON.
        #
        # They used to read `command not found` across the board,
        # which this comment called "sh reports every spawn failure
        # the same way" and treated as a liveness proxy. It was a
        # defect standing in for an assertion: the 68 KB file is
        # right there, and `not found` was false about it. When sh
        # learned to name a refused spawn, the oversized arm began
        # claiming a full process table on a machine with fourteen
        # free banks, so the kernel now answers ERR_NOEXEC for it
        # (procspawn3.s) -- found, not executable, which is the
        # same verdict a wrong file type and an empty file get. The
        # load-base arm still earns ERR_INVAL and still prints
        # `command not found`; that one is unchanged and is its own
        # question.
        #
        # The big file is four copies of PRODOS (4 x 17,128 B =
        # 68,512 > 65,536); chtyp gives it BIN type and an
        # aux_type (the load base) of $0800 (2048), then of 0.
        _typed_case('/mnt/MAUX/NOSUCH', ['sh: command not found'],
                    'an absolute path that is not there is refused')
        _typed_case('ECHO NS$?', ['NS127'],
                    'with status 127 (POSIX "not found"; it was 1 until '
                    'KFIX10 item 3)')
        _typed_case('CAT PRODOS PRODOS PRODOS PRODOS > BIG', [],
                    'a 68 KB file')
        _typed_case('CHTYP -t BIN -a 2048 BIG', [],
                    'typed BIN, load base $0800')
        _typed_case('/mnt/MAUX/BIG', ['sh: cannot execute'],
                    'an image over 64 KB is refused as not '
                    'executable, not as a full process table')
        _typed_case('ECHO BG$?', ['BG126'],
                    'with POSIX\'s 126, "found but not executable"')
        _typed_case('RM BIG', [], 'the 68 KB fixture goes away')
        # the load-base refusal needs a SMALL image, or the 64 KB arm
        # above would answer first and hide a broken base check: a copy
        # of true (123 B) typed BIN with load base 0 -- zero page.
        _typed_case('CP /BIN/TRUE LOWB', [], 'a small program')
        _typed_case('CHTYP -t BIN -a 0 LOWB', [], 'load base 0')
        _typed_case('/mnt/MAUX/LOWB', ['sh: command not found'],
                    'a load base below the window is refused')
        _typed_case('RM LOWB', [], 'the fixture goes away')
        _typed_case('ECHO ALIVE', ['ALIVE'], 'and the machine is intact')
        print('[check-play] spawn loader: a missing path (127), a '
              '68 KB image (126) and a load base of 0 are each '
              'refused, each for its own stated reason, and the '
              'shell carries on')


        # VIDMODE (docs/VIDMODE.md sec 8, V1.6). The verb is its own
        # verifier -- it reads the mode BACK via SYS_TTYGEO after
        # setting it and prints what it found -- so most legs assert
        # on the printed report, which is one syscall away from the
        # kernel's live cells. The GLASS assertions are the part the
        # verb cannot see: merged-vs-main is the emulator's own
        # rendering of 80STORE+COL80, so `80X24 VT` appearing in
        # MERGED rows is proof TTY_HW_SET moved real soft switches,
        # not just struct bytes (the check-vc lesson: pixels, not
        # struct bytes).
        def _idle_prompt_m(rs):
            nonblank = [r for r in rs if r.strip()]
            return bool(nonblank) and nonblank[-1].strip() == '$'

        client.call_tool('type', {'text': 'VIDMODE\r'})
        wait_for_screen_settled(
            client,
            lambda rs: '40X24 VT' in screen_blob(rs) and _idle_prompt(rs),
            'the boot-mode report (40X24 VT)')
        print('[check-play] vidmode reports the boot mode')

        # 40 -> 80. Geometry changes clear the WHOLE body now, row 0
        # included (the 2026-09-03 reclaim removed the separate row-0
        # reflow step, TTY_ST_RFLW -- there is nothing left to reflow),
        # and home to row 0 -- so vidmode's own report, the first thing
        # printed after the clear, must be the FIRST line on the glass.
        client.call_tool('type', {'text': 'VIDMODE 80\r'})
        rows = wait_for_merged_settled(
            client,
            lambda rs: ('80X24 VT' in screen_blob(rs)
                        and _idle_prompt_m(rs)),
            'the 80-column report on the MERGED glass')
        if '80X24 VT' not in rows[0]:
            print(f'[check-play] FAIL: the vidmode report did not land '
                  f'on row 0 after 40->80: merged row 0 = {rows[0]!r} -- '
                  f'row 0 is no longer a reserved line', file=sys.stderr)
            return 1
        print('[check-play] vidmode 80: report lands on row 0, now '
              'ordinary terminal content')

        # 80 -> 40 and a discipline switch in one breath; then VT
        # restored. The APPLE report proves the third CSI parameter
        # travelled; the second `40X24 VT` (counted -- the body was
        # cleared at the 80->40 hop, so exactly the VT-restore run
        # plus vidmode's own report line) proves discipline moves
        # without geometry.
        client.call_tool('type', {'text': 'VIDMODE 40 APPLE\r'})
        rows = wait_for_screen_settled(
            client,
            lambda rs: '40X24 APPLE' in screen_blob(rs) and _idle_prompt(rs),
            'the 40-column APPLE report back on main')
        if '40X24 APPLE' not in rows[0]:
            print(f'[check-play] FAIL: the vidmode report did not land '
                  f'on row 0 after 80->40: row 0 = {rows[0]!r}',
                  file=sys.stderr)
            return 1
        client.call_tool('type', {'text': 'VIDMODE VT\r'})
        wait_for_screen_settled(
            client,
            lambda rs: screen_blob(rs).count('40X24 VT') >= 1
            and _idle_prompt(rs),
            'the VT-restore report')
        print('[check-play] vidmode 40 apple / vidmode vt: geometry and '
              'discipline round trip')

        # Refusal: a redirected stdout is refused BEFORE any escape is
        # written -- the probe comes first in vidmode itself.
        client.call_tool('type', {'text': 'VIDMODE > VMDUMP\r'})
        wait_for_screen_settled(
            client,
            lambda rs: 'not a console' in screen_blob(rs)
            and _idle_prompt(rs),
            'the not-a-console refusal')
        # ...and the refusal must come BEFORE anything is written:
        # the shell created VMDUMP when it opened the redirect, so
        # `wc` finding it empty is the proof no report or escape
        # bytes reached stdout (review V1 finding 6: without this,
        # a vidmode that wrote first and refused second would pass).
        client.call_tool('type', {'text': 'WC VMDUMP\r'})
        wait_for_screen_settled(
            client,
            lambda rs: '0 0 0 VMDUMP' in screen_blob(rs)
            and _idle_prompt(rs),
            'the redirected stdout file to be EMPTY')
        print('[check-play] vidmode refuses a redirected stdout, '
              'writing nothing to it first')

        # A BACKGROUND console's mode, set through /dev/tty2 -- the
        # path that shredded kernel text at $2000+ on its first live
        # run (TTY_CSI_MODE called the glass-shaped clear under
        # redirect; V1.5 commit). The prompt coming back AT ALL is
        # the anti-wedge assertion; `80X24` staying off console 1 is
        # the routing one.
        client.call_tool('type', {'text': 'VIDMODE 80 > /dev/tty2\r'})
        # '/dev/tty2' is REQUIRED in the blob, not just the bare
        # prompt: the geometry hops above cleared console 1's body,
        # so the string can only be this leg's own echoed command --
        # without it, a poll landing before the shell even echoes
        # sees the OLD bare prompt and the settled wait passes
        # against a wedge it never observed.
        rows = wait_for_screen_settled(
            client,
            lambda rs: '/dev/tty2' in screen_blob(rs) and _idle_prompt(rs),
            'the prompt after a background mode change (the leg that '
            'used to shred the kernel and wedge PRC_WAIT)')
        if '80X24' in screen_blob(rows):
            print(f'[check-play] FAIL: the background report leaked onto '
                  f'console 1', file=sys.stderr)
            return 1
        # Bring console 2 to the glass. Its geometry change cleared
        # its store (VCS_CLR_BODY -- full store width, banked, all 24
        # rows including row 0 as of the 2026-09-03 reclaim), so
        # BGMARK from the earlier VC phase must be GONE and the report
        # -- the first thing written after that clear -- must be the
        # first LINE, row 0 of the store (there is no separate row-0
        # reflow step any more; VC_SWITCH's ordinary blit covers it).
        client.call_tool('type', {'text': 'CHVT 2 ; SLEEP 2 ; CHVT 1\r'})
        rows = wait_for_merged_settled(
            client,
            lambda rs: ('80X24 VT' in screen_blob(rs)
                        and '/dev/tty2' not in screen_blob(rs)),
            "console 2's 80-column stored screen on the glass")
        if '80X24 VT' not in rows[0]:
            print(f'[check-play] FAIL: console 2\'s background geometry '
                  f'change did not land its report on row 0 -- merged '
                  f'row 0 = {rows[0]!r}', file=sys.stderr)
            return 1
        if 'BGMARK' in screen_blob(rows):
            print(f'[check-play] FAIL: console 2 still shows BGMARK after '
                  f'its geometry change -- the redirected clear did not '
                  f'clear the store', file=sys.stderr)
            return 1
        rows = wait_for_screen_settled(
            client,
            lambda rs: '/dev/tty2' in screen_blob(rs) and _idle_prompt(rs),
            "console 1 restored, 40-col")
        # A COLD console's geometry: /dev/tty3 has never been touched,
        # so its annex slot is garbage -- SYS_TTYGEO must answer with
        # the boot inherit (what VC_RESET will give it), not the slot
        # (review V1 finding 2: without the VC_INITED check this leg
        # shows `00X00 VT` -- the play annex is zeros at boot).
        client.call_tool('type', {'text': 'VIDMODE > /dev/tty3\r'})
        wait_for_screen_settled(
            client,
            lambda rs: '/dev/tty3' in screen_blob(rs) and _idle_prompt(rs),
            'the cold-console probe to complete')
        client.call_tool('type', {'text': 'CHVT 3 ; SLEEP 2 ; CHVT 1\r'})
        wait_for_screen_settled(
            client,
            lambda rs: ('40X24 VT' in screen_blob(rs)
                        and '/dev/tty3' not in screen_blob(rs)),
            "console 3's boot-inherit report (40X24 VT, not slot "
            "garbage) on the glass")
        wait_for_screen_settled(
            client,
            lambda rs: '/dev/tty3' in screen_blob(rs) and _idle_prompt(rs),
            'console 1 restored after the cold-console round trip')
        print('[check-play] a cold console reports its boot-inherit '
              'mode, not annex garbage')

        # Console 1's OWN mode must be untouched by console 2's -- the
        # cells are per-console struct state, not globals.
        client.call_tool('type', {'text': 'VIDMODE\r'})
        wait_for_screen_settled(
            client,
            lambda rs: screen_blob(rs).count('40X24 VT') >= 2
            and _idle_prompt(rs),
            "console 1's own mode surviving console 2's change")
        print('[check-play] vidmode: background console set to 80, shown, '
              'and console 1 came back 40-col with its own mode intact')

        # -- MORE pages, holds, pages on SPACE, and quits on q
        # (FLEET F.3; POSIX more since 2026-09-12: raw single keys,
        # no RETURN after a command -- RETURN itself is "one line").
        # DEMO/LONG (cwd-relative: the volume is /mnt/MAUX, a leading
        # /DEMO names a nonexistent VOLUME) is 60 numbered lines; a
        # 24-row console pages 23 at a time, so L30 must NOT be
        # visible until the second page, and q at the second prompt
        # means L60 never prints at all. Key on L23 (the page's LAST
        # line), not L01 -- the echo line plus 23 rows plus the
        # prompt scrolls L01 off a 24-row glass. The deeper
        # exercise (b, G, g, search, pipes, several operands) is
        # scripts/check_more.py.
        client.call_tool('type', {'text': 'MORE DEMO/LONG\r'})

        def first_page(rs):
            blob = screen_blob(rs)
            return ('--More--' in blob and 'L23' in blob
                    and 'L30' not in blob)
        wait_for_screen_settled(client, first_page,
                                'MORE first page held at --More-- '
                                'with L30 unprinted')
        print('[check-play] MORE paged 23 rows and held')

        client.call_tool('type', {'text': ' '})

        def second_page(rs):
            blob = screen_blob(rs)
            return '--More--' in blob and 'L30' in blob \
                and 'L60' not in blob
        wait_for_screen_settled(client, second_page,
                                'SPACE paged to L30 with L60 still '
                                'unprinted')
        print('[check-play] SPACE advanced MORE one page')

        client.call_tool('type', {'text': 'q'})

        def back_at_prompt(rs):
            blob = screen_blob(rs)
            nonblank = [r for r in rs if r.strip()]
            return (bool(nonblank) and nonblank[-1].startswith('$')
                    and 'L60' not in blob)
        wait_for_screen_settled(client, back_at_prompt,
                                'q abandoned MORE before L60')
        print('[check-play] q quit MORE -- L60 never printed, '
              'prompt returned')

        # -- MAN pages a manual page through MORE when stdout is a
        # tty (man.s's own SC_FDSTAT check, docs/man/man.1). /mnt/MAUX/
        # MAN/MAN is man's OWN page, 43 lines -- over the 23-row
        # hold, so it proves the SAME pager path as the MORE phase
        # above without staging any new fixture (the page is already
        # on the carrier via man-pages/build_play_image.py). Only
        # the FIRST LINE and the hold are asserted here; the full
        # byte content is check-textaudit's `man` PAIR row instead.
        client.call_tool('type', {'text': 'MAN MAN\r'})

        def man_first_page(rs):
            blob = screen_blob(rs)
            return '--More--' in blob and 'MAN(1)' in blob
        wait_for_screen_settled(client, man_first_page,
                                'MAN paged its own page through MORE '
                                'and held with the title line shown')
        print('[check-play] MAN spawned MORE and showed the first line')

        client.call_tool('type', {'text': 'q'})
        wait_for_screen_settled(client, back_at_prompt,
                                'q abandoned MAN\'s pager view')
        print('[check-play] q quit MAN\'s pager, prompt returned')

        # Coverage is checked against UTILS by check-man-image. These
        # keyboard probes exercise newly filled gaps and the on-disk notices,
        # not just the previously existing man(1) page.
        for manual in ('SH', 'NAS', 'VI', 'LICENSES'):
            client.call_tool('type', {'text': f'MAN {manual}\r'})
            def added_manual(rs, title=f'{manual}(1)'):
                blob = screen_blob(rs)
                return '--More--' in blob and title in blob
            wait_for_screen_settled(client, added_manual,
                                    f'MAN {manual} first page and pager hold')
            client.call_tool('type', {'text': 'q'})
            wait_for_screen_settled(client, back_at_prompt,
                                    f'q returned from MAN {manual}')
            print(f'[check-play] MAN {manual}: title, pager and return OK')

        # -- nohup (eng-nohup-timeout-realpath, cut from a9034eb):
        # stdout IS a tty here (the live console), the one path
        # check-posixutil/check-textaudit cannot exercise (both
        # redirect stdout to a real file already, so nohup's own
        # SC_FDSTAT check never finds a terminal there). `NOHUP
        # ECHO HI` must print its stderr notice and NOTHING of
        # ECHO's own output to the screen; `CAT NOHUP.OUT` then
        # shows what actually landed in the file instead.
        def _idle_prompt_np(rs):
            nonblank = [r for r in rs if r.strip()]
            return bool(nonblank) and nonblank[-1].strip() == '$'
        client.call_tool('type', {'text': 'NOHUP ECHO HI\r'})
        nohup_rows = wait_for_screen_settled(
            client, _idle_prompt_np, 'NOHUP redirected and returned')
        nohup_screen = screen_blob(nohup_rows)
        if 'appending output to nohup.out' not in nohup_screen.lower():
            raise AssertionError(
                "NOHUP's own stderr notice never appeared on the "
                f'console:\n{nohup_screen}')
        if any(r.strip().upper() == 'HI' for r in nohup_rows):
            raise AssertionError(
                "ECHO's own output leaked to the console instead of "
                f'NOHUP.OUT:\n{nohup_screen}')
        print('[check-play] NOHUP redirected ECHO\'s output, notice '
              'shown, nothing leaked to the console')

        client.call_tool('type', {'text': 'CAT NOHUP.OUT\r'})

        def nohup_out_shown(rs):
            return (any(r.strip().upper() == 'HI' for r in rs)
                    and _idle_prompt_np(rs))
        wait_for_screen_settled(client, nohup_out_shown,
                                'CAT showed NOHUP.OUT\'s contents')
        print('[check-play] CAT NOHUP.OUT shows the redirected HI')

        # -- timeout (eng-nohup-timeout-realpath): the killed child
        # must be FULLY REAPED, never left a zombie -- the live proof
        # neither check-posixutil (a real timer, but no PS) nor
        # check-textaudit (no timer at all, per timeout's own
        # header) can give. PS shows every non-UNUSED PCB slot (its
        # own HEADER, " PID S BANK PPID"); capture that table BEFORE
        # spawning anything, run a TIMEOUT that kills its own child
        # (1 s deadline against SLEEP's 3 s), and capture the table
        # again -- the two must be IDENTICAL. The table is extracted
        # by its own header rather than diffing the whole screen,
        # which would also catch unrelated scroll drift from the
        # command lines and notices printed in between.
        def _ps_table(rs):
            # the LAST header on screen: old PS scrollback stays
            # visible above a second PS run in the same session, so
            # the first match would grab the STALE table instead.
            start = None
            for i, r in enumerate(rs):
                if 'PID' in r and 'BANK' in r and 'PPID' in r:
                    start = i
            if start is None:
                raise AssertionError(
                    f"PS's own header never appeared:\n{screen_blob(rs)}")
            out = []
            for r in rs[start:]:
                s = r.rstrip()
                if not s.strip() or s.lstrip().startswith('$'):
                    break
                out.append(s)
            return out

        client.call_tool('type', {'text': 'PS\r'})
        baseline_rows = wait_for_screen_settled(
            client, _idle_prompt_np, 'PS baseline settled')
        baseline_ps = _ps_table(baseline_rows)

        client.call_tool('type', {'text': 'TIMEOUT 1 SLEEP 3\r'})
        wait_for_screen_settled(client, _idle_prompt_np,
                                'TIMEOUT killed SLEEP and returned',
                                max_steps=2000)
        print('[check-play] TIMEOUT reaped its own child and '
              'returned to the prompt')

        client.call_tool('type', {'text': 'PS\r'})
        after_rows = wait_for_screen_settled(
            client, _idle_prompt_np, 'PS after TIMEOUT settled')
        after_ps = _ps_table(after_rows)
        def _ps_norm(tab):
            # The ancestors of the running PS may legitimately read R
            # or S: PS can be scheduled between the shell's spawn and
            # its wait, so the parent's state is whichever side of
            # that window the VBL tick fell on. A kernel byte move
            # shifts the phase (docs/KSPACE-NOTES.md; the same class
            # as learning:01M1AH9XWGC8ZS7HNBJVJ2JHXW). Everything else
            # -- a zombie row, a stale row, any OTHER state -- still
            # differs.
            rows = [r.split() for r in tab[1:]]
            rows = [r for r in rows if len(r) == 4]
            me = max((int(r[0]) for r in rows if r[1] == 'R'),
                     default=None)
            par = {int(r[0]): int(r[3]) for r in rows}
            anc, cur = set(), par.get(me)
            while cur and cur not in anc:
                anc.add(cur)
                cur = par.get(cur)
            return [tab[0]] + [
                ' '.join([r[0], '*' if int(r[0]) in anc else r[1],
                          r[2], r[3]]) for r in rows]

        if _ps_norm(after_ps) != _ps_norm(baseline_ps):
            raise AssertionError(
                'PS differs after TIMEOUT -- a zombie or stale row '
                f'was left behind:\nbefore: {baseline_ps}\n'
                f'after: {after_ps}')
        print('[check-play] PS is unchanged after TIMEOUT -- no '
              'zombie left behind')

        # -- jump scroll (docs/CONSOLE-OPT.md sec 6, lever 1, 2026-09-03).
        # CAT DEMO/LONG writes its 60 short lines in ONE write() (cat's
        # BUFSZ is 512); the kernel stages that in TTY_OWBUF_SZ chunks
        # and TTY_JSCROLL scrolls once per staged burst, not once per
        # line. Two assertions:
        #  1. the final screen is EXACTLY what line-at-a-time scrolling
        #     leaves -- L38..L60 on rows 0-22, the prompt on row 23. An
        #     over-count in the look-ahead would leave blank rows or
        #     misorder lines here.
        #  2. the number of scroll PASSES is small. A pass is counted by
        #     its one write to $0400 (row 0, col 0): TTY_SCROLL40's
        #     first copied byte, which nothing else touches while a
        #     program streams at the bottom of the screen. Expected 6:
        #     the echo CR, then one jump per staged chunk plus the
        #     chunk-final CR that has nothing left to look ahead at.
        # Teeth (measured before this section was trusted): TTY_JS_COUNT
        # forced to 0 gives ~40 passes here and this fails; the screen
        # assertion alone stays green under that sabotage.
        client.call_tool('type', {'text': 'CAT DEMO/LONG\r'})
        js_passes = 0
        js_first = js_last = None
        rows = []
        for _ in range(600):
            w = client.call_tool('until_write', {'addr': 0x0400,
                                                 'max_cycles': 200_000})
            if w.get('hit'):
                js_passes += 1
                js_last = w.get('cycle')
                if js_first is None:
                    js_first = js_last
                client.call_tool('step', {'cycles': 1})
                continue
            rows = screen_rows(client)
            if (len(rows) >= 24 and rows[23].startswith('$')
                    and rows[22].strip() == 'L60'):
                break
        else:
            raise RuntimeError('timed out waiting for CAT DEMO/LONG to '
                               'finish; screen was:\n' + screen_blob(rows))
        js_want = [f'L{n:02d}' for n in range(38, 61)]
        js_got = [r.strip() for r in rows[:23]]
        print(f'[check-play] jump scroll: CAT DEMO/LONG finished: '
              f'{js_passes} scroll passes'
              + (f' ({js_last - js_first} cycles first-to-last pass)'
                 if js_first is not None and js_last != js_first else ''))
        if js_got != js_want:
            print('[check-play] FAIL: jump scroll left the wrong screen '
                  f'-- got {js_got}, want {js_want}:\n{screen_blob(rows)}',
                  file=sys.stderr)
            return 1
        if not 1 <= js_passes <= 8:
            print(f'[check-play] FAIL: jump scroll: {js_passes} scroll '
                  'passes for a 60-line single-write cat, want <= 8 (one '
                  'per staged chunk, not one per line)', file=sys.stderr)
            return 1

        # -- trap (docs/SIGNALS.md sec 3): a caught signal runs its
        # stored string at the next prompt, and the EXIT trap fires
        # on the shell's exit. Run it in a fresh nested sh reading a
        # script, so `exit` there ends the nested sh (not the login
        # shell). The signal delivery is the payoff of the whole
        # held-signal kernel: `kill -2 $$` self-signals, the pump
        # drains it, TRAPHIT prints; then the nested sh's EXIT fires
        # the 0-trap, TRAPBYE prints.
        client.call_tool('type', {'text': 'SH < DEMO/TRAP\r'})

        def trap_fired(rs):
            blob = screen_blob(rs)
            return 'TRAPHIT' in blob and 'TRAPBYE' in blob

        wait_for_screen(client, trap_fired,
                        'trap: caught SIGINT ran TRAPHIT and the '
                        'EXIT trap ran TRAPBYE')
        print('[check-play] trap -- caught-signal pump ran TRAPHIT, '
              'exit trap ran TRAPBYE')

        # -----------------------------------------------------------
        # `ex` AT THE KEYBOARD (docs/EX-DESIGN.md), typed the way a
        # human types it -- NOT `ex < script`, which is all
        # `make check-ex` (extestb.s) has ever proven. ex's own
        # command letters (r/a/p/s/w/q) are literal lowercase ASCII
        # compares in edparse.s/edfile.s/excmd.s -- no STRCMPI case
        # folding exists for them the way `sh`'s builtins got
        # (docs/SH-CASE.md) -- and the append terminator is a BARE
        # "." on its own line. check-ex's own script bytes ARE real
        # lowercase (extestb.s), but they are written straight into a
        # file `ex` opens as stdin -- they never once travel
        # keyboard -> TTY_KEYIN -> cooked mode -> fd 0, which is
        # exactly the path docs/SH-CASE.md's "a gate tests the form
        # its author already knew would work" lesson is about. The
        # enhanced //e keyboard has no case-folding of its own either
        # (verified against the commons this session,
        # Understanding_the_Apple_IIe manual: lowercase is native on
        # this platform's keyboard, no shift-key mod needed) -- so if
        # this phase is proving anything new, it's the SOFTWARE path,
        # not the hardware.
        #
        # `ex FILE` (2026-09-02, filename-on-launch task): a leading
        # filename argument is loaded through the swap file at
        # startup and becomes the REMEMBERED filename, exactly like
        # real ex (Ex Reference Manual v1.1,
        # learning:01M1FX8HT89CKR9CB8T8VKCW1S -- "an initial filename
        # argument is read into the buffer"). This is the real human
        # hot path (`ex FILE` at a shell prompt), so it is launched
        # directly here instead of bare `EX` + `r EXFIX`. There is
        # still no "N lines" opening banner -- the launch load reuses
        # `r`/`w`'s own silent-on-success path (EX-DESIGN.md sec
        # 3.1's "no-surprises behavior: unchanged" for both).
        #
        # `cd DEMO` first: the swap file EX_SW_ENSURE (exbuf.s)
        # lazily creates on the first write is named EX.SWPxx and
        # lands in the session's cwd AT LAUNCH -- anchoring the
        # session there keeps the later cleanup check's `ls` a short,
        # single-screen listing instead of racing wait_for_scrolling
        # against a name that could scroll off before it's ever seen
        # (a false GREEN, not just a false RED).
        _typed_case('CD DEMO', [], 'cd into DEMO/ for the ex phase')

        def _consec(rows, words):
            """True if `words` appear as consecutive bare (stripped)
            rows, in order, anywhere in `rows`."""
            stripped = [r.strip() for r in rows]
            n = len(words)
            return any(stripped[i:i + n] == list(words)
                       for i in range(len(stripped) - n + 1))

        # EXFIX (build_play_image.py SAMPLES) is a 3-line fixture.
        # `EX EXFIX` loads it through the swap file AT LAUNCH -- no
        # `r` anywhere in this phase -- and the immediate `%p` is
        # ALSO the first proof this session is really inside `ex` at
        # all -- if EX never spawned, `%p` would instead run as an
        # unrecognized SHELL command and this exact three-line
        # sequence could never appear.
        # `%p`, NOT `,p`: after `ex FILE` the current line `.` is the
        # LAST line, and in ex/vi a bare `,` means `.,.` (the current
        # line ALONE), not ed's `1,$` -- verified against /usr/bin/ex
        # (vim): `,p` right after launch prints only the last line.
        # `%` is the whole-buffer address in every ex, so `%p` is the
        # right way to prove the launch load pulled in all three lines.
        # (This case typed `,p` until 2026-09-07 and expected the whole
        # buffer -- an ed habit; maux's ex correctly matched vim and so
        # printed one line, which read as a hang.)
        client.call_tool('type', {'text': 'EX EXFIX\r'})
        client.call_tool('type', {'text': '%p\r'})
        wait_for_screen_settled(
            client,
            lambda rs: _consec(rs, ['LINE ONE', 'LINE OLD TWO',
                                    'LINE THREE']),
            'ex: EX EXFIX loaded through the swap file at launch, '
            '%p printed it -- buffer pre-loaded, no `r` needed')
        print('[check-play] ex: `EX EXFIX` launch-loaded the fixture '
              'through the swap file, `%p` printed it with no `r`')

        # `1a` <CR>, a typed line, then a BARE "." <CR> to end insert
        # mode -- the classic ed/ex round trip, and precisely the "a
        # dot was never typed" case docs/SH-CASE.md names.
        # ED_TEXTENTRY (edbuf.s) ends insert mode on a line that is
        # EXACTLY ".". If the bare dot were swallowed or
        # mis-terminated, every command typed after it -- "%p" itself
        # -- would instead be consumed as MORE inserted text, and
        # this assertion would never see a real `%p` output again.
        client.call_tool('type', {'text': '1a\r'})
        client.call_tool('type', {'text': 'APPENDED LINE\r'})
        client.call_tool('type', {'text': '.\r'})
        client.call_tool('type', {'text': '%p\r'})
        wait_for_screen_settled(
            client,
            lambda rs: _consec(rs, ['LINE ONE', 'APPENDED LINE',
                                    'LINE OLD TWO', 'LINE THREE']),
            'ex: 1a / APPENDED LINE / . inserted after line 1 (bare-dot '
            'terminator honored)')
        print('[check-play] ex: 1a <CR>, a typed line, bare "." <CR> -- '
              'insert-mode round trip, the classic bare-dot case')

        # `3s/OLD/NEW/` -- line 3 is now "LINE OLD TWO" (the append
        # above shifted it down one). Only line 3 may change; lines
        # 1/2/4 are the control proving the substitute is not global.
        client.call_tool('type', {'text': '3s/OLD/NEW/\r'})
        client.call_tool('type', {'text': '%p\r'})
        wait_for_screen_settled(
            client,
            lambda rs: _consec(rs, ['LINE ONE', 'APPENDED LINE',
                                    'LINE NEW TWO', 'LINE THREE']),
            'ex: 3s/OLD/NEW/ rewrote only line 3')
        print('[check-play] ex: 3s/OLD/NEW/ substituted one line, `%p` '
              'confirmed it')

        # `w` (write -- silent on success, edfil2.s's ED_DOWRITE
        # prints nothing) then `q` (quit -- silent, unlinks the swap
        # file, EX-DESIGN.md sec 2.7/5.3). The shell prompt coming
        # BACK is the proof `q` actually exited ex rather than
        # hanging or crashing the session.
        client.call_tool('type', {'text': 'w EXOUT\r'})
        client.call_tool('type', {'text': 'q\r'})
        wait_for_screen_settled(client, _prompt_now,
                                'shell prompt back after ex `q`')
        print('[check-play] ex: `w EXOUT` then `q` -- back at the shell '
              'prompt')

        # The write actually landed: `cat` the target through the
        # ordinary shell, byte-exact against the same four lines `%p`
        # last showed (a stored line's own text is the same shape as
        # `%p`'s output -- text + CR per line, no decoration).
        #
        # `_typed_case`, NOT `_consec` -- and this is why: cat's
        # output here is BYTE-IDENTICAL to the `%p` output two steps
        # above, which is still sitting on screen (nothing has
        # scrolled). A whole-screen `_consec` scan is satisfied by
        # that STALE `%p` output the instant `cat` is typed, before
        # `cat` has even been spawned -- caught live, 2026-09-02: the
        # false-positive here made the harness type the NEXT command
        # (`ls`) too early, and everything downstream (including the
        # swap check and the final `cd ..`) hung on a jumbled screen.
        # `_typed_case` anchors on the FRESH echo of `cat exout`
        # itself (its own last occurrence) and requires the exact
        # output rows to follow it directly, immune to a stale
        # earlier rendering of the identical text.
        _typed_case('CAT EXOUT',
                    ['LINE ONE', 'APPENDED LINE', 'LINE NEW TWO',
                     'LINE THREE'],
                    'cat EXOUT matches what ex wrote')
        print('[check-play] ex: `w` really wrote the edited buffer -- '
              '`cat EXOUT` from the shell matches')

        # Swap cleanup -- the ex-specific behavior make check-ex
        # already covers via fd 0, but a human session should too:
        # `q` above must have CLOSE+UNLINKed EX.SWPxx (ED_QCLEANUP,
        # exbuf.s). `ls` the directory the swap lived in (small and
        # unscrolled -- DEMO/ has under a dozen entries) and confirm
        # no EX.SWP* name survived. Same before/after COUNT idiom the
        # ^L phase above uses for `$ LS` -- `_prompt_now` alone is not
        # enough here either: it just asks whether the SCREEN'S
        # bottom row is a bare "$", which a stale one from an earlier
        # phase could already satisfy before this `ls` has even run.
        before_ls = screen_blob(screen_rows(client)).count('$ LS')
        client.call_tool('type', {'text': 'LS\r'})

        def _ls_done(rs):
            if screen_blob(rs).count('$ LS') <= before_ls:
                return False
            nonblank = [r for r in rs if r.strip()]
            return bool(nonblank) and nonblank[-1].strip() == '$'

        rows = wait_for_screen_settled(client, _ls_done,
                                       'ls after ex quit, reprompted')
        if 'EX.SWP' in screen_blob(rows):
            print('[check-play] FAIL: EX.SWP* still present after `q` -- '
                  'the swap file was not unlinked on quit', file=sys.stderr)
            print(screen_blob(rows), file=sys.stderr)
            return 1
        print('[check-play] ex: swap file unlinked on `q` -- no EX.SWP* '
              'left in DEMO/')

        # -----------------------------------------------------------
        # `vi` AT THE KEYBOARD (docs/VI-DESIGN.md) -- the birth
        # certificate: `vi FILE` opens, h/j/k/l motion, `i` insert
        # with LIVE per-keystroke echo, `:` drops one command into
        # the real ex engine (ED_DISPATCH1), `:wq` writes and quits,
        # a second session's `ZZ` writes-if-dirty and quits through
        # the SAME EX_XCORE core `:x` uses, and the tty mode vi
        # replaced (cbreak+noecho) comes back COOKED+ECHO on its own
        # -- the one assertion `ex`'s own gate had no reason to make
        # (VI-DESIGN sec 7 item 6). Still in DEMO/ from the ex phase
        # above; EXFIX is untouched by it (ex wrote to EXOUT, not
        # EXFIX).
        # SYS_TTYGEO reports 24 rows; vi's text window is rows
        # 1..(VI_ROWS-1) in its OWN 1-based CSI addressing
        # (viscreen.s), with the status line the last of those --
        # unaffected by the 2026-09-03 row-0 reclaim, which only
        # changed how the KERNEL maps a CSI row onto a physical one
        # (ESC[1;1H is physical row 0 now, not row 1 -- docs/
        # CONSOLE.md sec 6). vi's own numbers are unchanged; only
        # the PHYSICAL rows they land on shift up by one, so every
        # index below is one less than vi's own row number.
        VI_TEXTROW1 = 0
        VI_TEXTROW2 = 1
        VI_TEXTROW3 = 2
        VI_STATUSROW = 23

        client.call_tool('type', {'text': 'VI EXFIX\r'})

        def _vi_initial(rs):
            return (rs[VI_TEXTROW1].rstrip() == 'LINE ONE'
                    and rs[VI_TEXTROW2].rstrip() == 'LINE OLD TWO'
                    and rs[VI_TEXTROW3].rstrip() == 'LINE THREE'
                    and '"EXFIX"' in rs[VI_STATUSROW])

        wait_for_screen_settled(client, _vi_initial,
                                'vi: initial paint of EXFIX (3 '
                                'lines + status line)')
        print('[check-play] vi: `VI EXFIX` painted the fixture\'s '
              '3 lines and the status line shows the filename')

        # h/j/k/l motion (down, down, up -- lands on line 2, "LINE
        # OLD TWO"), then `i` and ONE character -- the live-echo
        # assertion (VI-DESIGN sec 7 item 4): a fd-0-redirected test
        # could never distinguish this from cooked `a`/`i`/`c`, so
        # it has to be checked MID-TYPING, not just at the end.
        # VI_CURCOL never moves off 0 (no `l`/`h` typed), so `i`
        # inserts at column 0 -- prefix empty, the whole original
        # line becomes the suffix.
        client.call_tool('type', {'text': 'jjkiX'})
        wait_for_screen_settled(
            client,
            lambda rs: rs[VI_TEXTROW2].rstrip().startswith('X'),
            'vi: `i` + one raw keystroke echoed LIVE at the cursor '
            '(tty echo is off -- vi painted it itself)')
        client.call_tool('type', {'text': 'MARK'})
        client.call_tool('type', {'text': '\\x1b'})
        wait_for_screen_settled(
            client,
            lambda rs: rs[VI_TEXTROW2].rstrip() == 'XMARKLINE OLD TWO',
            'vi: ESC closed the insert -- line 2 now XMARKLINE OLD '
            'TWO (empty prefix, typed text, then the original '
            'suffix)')
        print('[check-play] vi: h/j/k/l landed on line 2, `i` + '
              '"XMARK" + ESC inserted it live, character by '
              'character')

        # `:` bridge -- ONE command line through the real ex engine
        # (ED_DISPATCH1), not a maux invention: `:s/OLD/NEW/` with
        # no address defaults to `.`, still line 2 (insert mode
        # never changed ED_CURLINE here -- no RETURN was typed).
        client.call_tool('type', {'text': ':s/OLD/NEW/\r'})
        wait_for_screen_settled(
            client,
            lambda rs: rs[VI_TEXTROW2].rstrip() == 'XMARKLINE NEW TWO',
            'vi: `:s/OLD/NEW/` through the `:` bridge rewrote line 2')
        print('[check-play] vi: `:s/OLD/NEW/` -- the `:` bridge ran '
              'a real ex command via ED_DISPATCH1')

        # `:wq` -- write EXFIX back and quit; the shell prompt
        # coming back is the proof it actually exited.
        client.call_tool('type', {'text': ':wq\r'})
        wait_for_screen_settled(client, _prompt_now,
                                'shell prompt back after vi `:wq`')
        print('[check-play] vi: `:wq` wrote EXFIX and quit -- back '
              'at the shell prompt')

        # The write actually landed -- byte-exact, the same
        # technique the ex phase above used for EXOUT.
        _typed_case('CAT EXFIX',
                    ['LINE ONE', 'XMARKLINE NEW TWO', 'LINE THREE'],
                    'cat EXFIX matches what vi wrote')
        print('[check-play] vi: `:wq` really wrote the edited '
              'buffer -- `cat EXFIX` from the shell matches')

        # -----------------------------------------------------------
        # `ZZ` (VI-DESIGN sec 5 item 3 / sec 7 item 6): a second
        # session, a small edit, then `ZZ` -- write-if-dirty and
        # quit through EX_XCORE, the SAME core `:x` uses, called
        # directly since `ZZ` is two keystrokes in command mode,
        # never typed after `:`.
        client.call_tool('type', {'text': 'VI EXFIX\r'})
        wait_for_screen_settled(
            client,
            lambda rs: rs[VI_TEXTROW1].rstrip() == 'LINE ONE',
            'vi: second session reopened the just-written EXFIX')
        client.call_tool('type', {'text': 'iQ'})
        client.call_tool('type', {'text': '\\x1b'})
        wait_for_screen_settled(
            client,
            lambda rs: rs[VI_TEXTROW1].rstrip() == 'QLINE ONE',
            'vi: second session\'s `i`+ESC edit landed on line 1')
        client.call_tool('type', {'text': 'ZZ'})
        wait_for_screen_settled(client, _prompt_now,
                                'shell prompt back after vi `ZZ`')
        print('[check-play] vi: `ZZ` wrote the dirty buffer and '
              'quit -- back at the shell prompt')

        _typed_case('CAT EXFIX',
                    ['QLINE ONE', 'XMARKLINE NEW TWO', 'LINE THREE'],
                    'cat EXFIX matches what ZZ wrote')
        print('[check-play] vi: `ZZ` really wrote the edited '
              'buffer -- `cat EXFIX` from the shell matches')

        # -- vi on a NEW (empty) file: multi-line insert + scroll.
        # This is the path that shipped broken (2026-09-04): an empty
        # buffer has zero lines, so insert spliced at a nonexistent
        # line 0 and the FIRST typed line was lost -- `i`, two lines,
        # ESC left only the second. And there was no page-scroll key
        # at all. Gate both now.
        client.call_tool('type', {'text': 'VI VNEW\r'})

        def _two_lines(rs):
            # after ESC the cursor is on row 1 (beta): tolerant there only
            return (rs[0].rstrip() == 'alpha'
                    and _row_eq(rs, 1, 'beta')
                    and rs[2].rstrip() == '~')
        # WAIT-1 (2026-10-21): vi must be UP (alt screen drawn) before the
        # first key. Sent straight after `VI VNEW\r`, 'ialpha' raced vi's
        # switch to raw: keys before it were echoed by the COOKED tty
        # onto the shell screen, so the `:q` row below saw 'ialpha$' as
        # its last line or not, depending on the guest's phase. Same
        # failure on main with the typeahead delayed 150,000 cycles
        # (passes at 30,000, 400,000 and 900,000): a 92-byte kernel
        # change was enough to land in the window. Typeahead before raw
        # is check-typeahead's, not this row's.
        wait_for_screen_settled(
            client, lambda rs: any(r.strip() == '~' for r in rs),
            'vi: new file is up (alt screen drawn) before the first key')
        client.call_tool('type', {'text': 'ialpha\rbeta\x1b'})
        wait_for_screen_settled(client, _two_lines,
                                'vi new file: both inserted lines '
                                'survive ESC (not just the second)')
        print('[check-play] vi: new-file `i`+two lines+ESC kept BOTH '
              'lines')

        # k/j must move between the two -- they could not when the
        # buffer had only the one surviving line.
        def _on_line1(rs):
            # after `k` the cursor is on row 0; row 1 has none: stays exact
            return _row_eq(rs, 0, 'alpha') and rs[1].rstrip() == 'beta'
        client.call_tool('type', {'text': 'k'})
        wait_for_screen_settled(client, _on_line1,
                                'vi new file: k reached line 1')
        print('[check-play] vi: k/j move between the two lines')

        # -- INSERT-ENTRY CURSOR PLACEMENT (2026-09-04 fix): a/A/I/o/O
        # move the insert point, so the LIVE echo must land there, not
        # where command mode left the cursor. Checked MID-INSERT
        # (before ESC): ESC's repaint hides the bug -- the buffer was
        # always right, the GLASS was not, so `A` typed over the last
        # char and `o` typed onto the current line. This is exactly
        # the form the operator hit that walked past every `i`-only
        # gate. `startswith` tolerates the cursor cell (a substituted
        # glyph on the blank past the text); `u` restores the buffer
        # for the fill below.
        client.call_tool('type', {'text': '1GA'})
        client.call_tool('type', {'text': 'END'})
        wait_for_screen_settled(
            client, lambda rs: rs[0].startswith('alphaEND'),
            'vi: `A` live echo appends at EOL, not over the tail')
        client.call_tool('type', {'text': '\\x1bu'})
        wait_for_screen_settled(client, _on_line1,
                                'vi: undo restored alpha/beta after A')
        client.call_tool('type', {'text': '1Go'})
        # The ~ must be GONE from the opened row BEFORE anything is
        # typed -- operator 2026-09-04: "the tilde doesn't get removed
        # from a line being inserted unless it's a CR from the line
        # above". o/O now repaint at entry, so the opened line is a
        # real blank line, not a ~. (Checked before MID is typed --
        # MID's 'M' would overwrite a stray ~ at col 0 and hide it.)
        wait_for_screen_settled(
            client, lambda rs: rs[0].rstrip() == 'alpha'
            and rs[1].strip() == '',
            'vi: `o` cleared the ~ on the opened line (no text yet)')
        client.call_tool('type', {'text': 'MID'})
        wait_for_screen_settled(
            client, lambda rs: rs[0].rstrip() == 'alpha'
            and rs[1].startswith('MID'),
            'vi: `o` live echo lands on the opened row below')
        client.call_tool('type', {'text': '\\x1bu'})
        wait_for_screen_settled(client, _on_line1,
                                'vi: undo restored the two lines after o')
        print('[check-play] vi: a/A/o place the cursor at the insert '
              'point before echoing')

        # Fill past one screen, then ^F/^B page. Type the lines in
        # small bursts with settles between: injecting 30 lines in one
        # `type` overruns the //e's one-key-per-tick keyboard latch and
        # the text arrives mangled (a test artifact, not a vi bug --
        # a human types far slower than the drain).
        client.call_tool('type', {'text': 'o'})
        for n in range(1, 31):
            client.call_tool('type', {'text': f'row{n:02d}\r'})
            for _ in range(4):
                client.call_tool('step', {'cycles': 100_000})
        client.call_tool('type', {'text': '\x1b'})

        def _last_page(rs):
            # insert-exit bottom-aligns: the tail of the file is on
            # screen (row30 among the visible text rows), not scrolled
            # off with the cursor.
            return any(r.rstrip() == 'row30' for r in rs[:23])
        wait_for_screen_settled(client, _last_page,
                                'vi: 30-line insert left the cursor '
                                'line (row30) on screen')
        print('[check-play] vi: multi-line insert follows the cursor')

        client.call_tool('type', {'text': '1G'})

        def _top(rs):
            # 1G / ^B both land the cursor on row 0 -- tolerant (see _row_eq)
            return _row_eq(rs, 0, 'alpha')
        wait_for_screen_settled(client, _top, 'vi: 1G to the top')
        client.call_tool('type', {'text': '\x06'})   # ^F

        def _paged(rs):
            return (not any(r.rstrip() == 'alpha' for r in rs)
                    and any(r.strip() and r.rstrip() != '~' for r in rs[:23]))
        wait_for_screen_settled(client, _paged,
                                'vi: ^F paged down off the first screen')
        print('[check-play] vi: ^F page-down scrolled')
        client.call_tool('type', {'text': '\x02'})   # ^B
        wait_for_screen_settled(client, _top,
                                'vi: ^B paged back to the top')
        print('[check-play] vi: ^B page-up scrolled')

        # ARROW KEYS (2026-09-04): the //e arrows arrive as CSI
        # (ESC [ A/B/C/D); vi maps them to k/j/l/h. Assertions are
        # cursor-cell tolerant -- screen_text renders the cell under
        # the cursor as a substituted glyph, so tests key on a
        # line's SUFFIX or on whole-line delete, never the cursor
        # column. Buffer here is alpha, row01..row30 (the fill
        # above). DOWN arrow (= j) then `dd`: if it moved to line 2,
        # 'row01' is deleted and 'alpha' (line 1) survives with
        # 'row02' shifted up below it; if the arrow did nothing,
        # 'alpha' is deleted and 'row01' still shows -- 'pha'
        # distinguishes them. (2026-09-05: this predicate used to
        # read 'row01' in rs[1], which is the UNFIXED-arrow outcome
        # -- it happened to pass only because a real bug, a
        # duplicate VI_RAWKEY read on every CSI-arrow dispatch
        # (vimotion.s :csifinal), silently ate `dd`'s own two
        # keystrokes and made it a no-op; fixed alongside removing
        # that duplicate.)
        client.call_tool('type', {'text': '1G\x1b[Bdd'})

        def _down_moved(rs):
            # 'ow02', not 'row02' -- the cursor sits on line 2's
            # own col 0 after `dd` (linewise delete lands the
            # cursor at the new current line's start), and
            # screen_text substitutes THAT cell's glyph, same
            # cursor-cell-tolerance reason 'pha' (not 'alpha') is
            # checked on line 1 just above.
            return 'pha' in rs[0] and 'ow02' in rs[1]
        wait_for_screen_settled(client, _down_moved,
                                'vi: DOWN arrow moved to line 2 (dd removed '
                                'it, line 1 survives)')
        print('[check-play] vi: arrow keys navigate (down-arrow = j)')

        # insert-mode LEFT arrow must NOT delete-to-EOL (the old
        # ESC+'['+'D' bug): on line 1 ('alpha', 5 chars) enter
        # insert, press left-arrow, ESC. If the bug were live, the
        # 'D' would delete to end of line and 'alpha' would collapse
        # to ~1 char. It must stay 5 (the cursor cell substitutes
        # one glyph but changes no length). Which COLUMN gets
        # substituted depends on where the left-arrow motion
        # actually lands the cursor (real vi command-mode `h`, once
        # the arrow genuinely dispatches -- see the vimotion.s
        # :csifinal fix above), so this checks length plus AT MOST
        # one substituted cell against 'alpha', rather than a fixed
        # substring like 'pha' that a different cursor column could
        # legitimately clobber.
        client.call_tool('type', {'text': '1Gi\x1b[D\x1b'})

        def _line1_whole(rs):
            row = rs[0].rstrip()
            if len(row) != 5:
                return False
            mismatches = sum(1 for a, b in zip(row, 'alpha') if a != b)
            return mismatches <= 1
        wait_for_screen_settled(client, _line1_whole,
                                'vi: insert-mode left arrow did not delete '
                                'to end of line (line 1 still 5 chars)')
        print('[check-play] vi: insert-mode arrow is safe (no delete-to-EOL)')

        # PLAIN `:q` (not :q!) must hand the screen back and restore
        # the tty -- the "terminal stuffed after :q" bug (2026-09-04):
        # plain :q fell through to the classic ED_CMD_Q, which skips
        # EX_ONQUIT, so vi's ~ tildes and status line stayed on the
        # glass and the shell prompt jammed onto the ':q' line.
        # (The buffer is dirty from the edits above, so :q would
        # normally refuse -- but plain :q has no dirty guard yet, it
        # quits; that is the pre-existing behaviour this rides on.)
        # SINCE 2026-09-08 (docs/VI-ALTSCREEN.md) "hand back" means the
        # ALTERNATE SCREEN: EX_ONQUIT emits ESC [ ? 1049 l, not ESC [
        # 2 J, so the SHELL SCREEN FROM BEFORE `VI VNEW` COMES BACK --
        # its `$ VI VNEW` launch line included -- rather than a blank
        # glass with a lone prompt. (The typeahead this phase sent
        # before vi went raw was echoed onto that screen by the cooked
        # tty and comes back with it, exactly as on a real terminal.)
        # check_vi_alt.py owns the marker-level proof; this asserts the
        # shape a human sees: no ~ tildes, the launch line survived,
        # the prompt is the last thing on the glass.
        client.call_tool('type', {'text': ':q\r'})

        def _restored_prompt(rs):
            nb = [r for r in rs if r.strip()]
            return (bool(nb) and nb[-1].strip() == '$'
                    and any(r.strip() == '$ VI VNEW' for r in rs)
                    and not any(r.strip() == '~' for r in rs))
        wait_for_screen_settled(client, _restored_prompt,
                                'vi: plain :q RESTORED the shell screen '
                                '(launch line back, no ~ tildes, prompt '
                                'last)')
        print('[check-play] vi: plain `:q` restored the shell screen '
              '(alt-screen rmcup) and the tty -- no stuffed terminal')

        # THE SABOTAGE-PROVABLE CLAIM THIS DESIGN IS BUILT AROUND
        # (VI-DESIGN sec 7 item 6): vi replaced the console's tty
        # mode with cbreak+noecho at entry (SC_TTYMODE) and must
        # restore it itself on EVERY exit path, `ZZ` included -- not
        # merely rely on the kernel's own PRC_TMD_RST crash-safety
        # backstop, which is suspenders, not the belt. Prove
        # cooked+echo is back by running an ordinary shell command
        # typed as ONE line: if EITHER bit were still off, ECHO
        # would never paint it and/or ICANON would deliver it to
        # sh's cooked read as loose fragments instead of one line,
        # and `_typed_case`'s own exact-row anchor would fail either
        # way.
        _typed_case('ECHO BACKINCOOKED', ['BACKINCOOKED'],
                    'tty mode restored to cooked+echo after `ZZ` -- '
                    'a normal command typed as one line works again')
        print('[check-play] vi: tty mode came back to cooked+echo '
              'on its own after `ZZ` -- vi restored it itself, not '
              'just the kernel\'s crash-safety backstop')

        # -----------------------------------------------------------
        # ^C mid-session (VI-DESIGN sec 3.1 / sec 7 item 7): a THIRD
        # session, ^C while idle in command mode, then prove vi is
        # still alive and still in command mode -- not quit, not
        # hung -- by running a real `i`+ESC edit right afterward.
        # `:q!` discards it (deliberately, to leave EXFIX at the
        # state the byte-exact check above already proved).
        client.call_tool('type', {'text': 'VI EXFIX\r'})
        wait_for_screen_settled(
            client,
            lambda rs: rs[VI_TEXTROW1].rstrip() == 'QLINE ONE',
            'vi: third session reopened EXFIX')
        client.call_tool('type', {'text': '\\x03iZ\\x1b'})
        wait_for_screen_settled(
            client,
            lambda rs: rs[VI_TEXTROW1].rstrip() == 'ZQLINE ONE',
            'vi: still alive and in command mode after ^C -- the '
            'post-^C `i`+ESC edit landed')
        client.call_tool('type', {'text': ':q!\r'})
        wait_for_screen_settled(client, _prompt_now,
                                'shell prompt back after vi `:q!`')
        print('[check-play] vi: ^C mid-session left the editor '
              'alive and in command mode; `:q!` then quit cleanly '
              '(the post-^C edit was never written -- q! discards '
              'it)')

        # -----------------------------------------------------------
        # Insert-entry variants + search (docs/VI-DESIGN.md sec 4.1,
        # viinsert.s's VI_INS_A/AEOL/FNB/OBLW/OABV, visearch.s). A
        # fresh session against VIFIX (build_play_image.py SAMPLES --
        # line 2's leading spaces are for `I`, "APPLE" on lines 1/3/5
        # gives `/`/`?`/`n`/`N` three occurrences). Every assertion
        # below was independently derived by SIMULATING the exact
        # splice/search algorithm against this fixture (not
        # hand-arithmetic'd), so a row mismatch here means the real
        # code diverged from that model, not a fixture-counting slip.
        client.call_tool('type', {'text': 'VI VIFIX\r'})
        wait_for_screen_settled(
            client,
            lambda rs: (rs[0].rstrip() == 'ALPHA APPLE'
                        and rs[2].rstrip() == 'GAMMA APPLE ITEM'
                        and '"VIFIX"' in rs[VI_STATUSROW]),
            'vi: fresh session opened VIFIX')

        # `A` -- append at end of line 1 ("ALPHA APPLE" has 11 chars,
        # cursor starts at col 0 -- `A` must jump it to col 11, not
        # append after col 0).
        client.call_tool('type', {'text': 'A999'})
        client.call_tool('type', {'text': '\\x1b'})
        wait_for_screen_settled(
            client,
            lambda rs: rs[0].rstrip() == 'ALPHA APPLE999',
            'vi: `A` appended at the TRUE end of line 1, not after '
            'the cursor\'s starting column')
        print('[check-play] vi: `A` + "999" + ESC -- '
              '"ALPHA APPLE999"')

        # `o` -- open a new line BELOW line 1 and insert into it;
        # line 2 ("  BETA INDENT") must SHIFT DOWN to row 3 untouched.
        client.call_tool('type', {'text': 'oNEWBELOW'})
        client.call_tool('type', {'text': '\\x1b'})
        wait_for_screen_settled(
            client,
            lambda rs: (rs[0].rstrip() == 'ALPHA APPLE999'
                        and rs[1].rstrip() == 'NEWBELOW'
                        and rs[2].rstrip() == '  BETA INDENT'),
            'vi: `o` opened a new line 2 BELOW line 1 and shifted '
              'the old line 2 down to row 3, untouched')
        print('[check-play] vi: `o` + "NEWBELOW" + ESC -- new line '
              '2, old line 2 shifted to row 3')

        # `O` -- move to row 3 (the shifted "  BETA INDENT"), open a
        # new line ABOVE it; that line must shift down again, to
        # row 4, while row 2 ("NEWBELOW") stays put.
        client.call_tool('type', {'text': 'jONEWABOVE'})
        client.call_tool('type', {'text': '\\x1b'})
        wait_for_screen_settled(
            client,
            lambda rs: (rs[1].rstrip() == 'NEWBELOW'
                        and rs[2].rstrip() == 'NEWABOVE'
                        and rs[3].rstrip() == '  BETA INDENT'),
            'vi: `O` opened a new line ABOVE row 3, pushing '
              '"  BETA INDENT" down to row 4')
        print('[check-play] vi: `j` then `O` + "NEWABOVE" + ESC -- '
              'new line 3, old line shifted to row 4')

        # `I` -- move to row 4, insert before the first NON-BLANK
        # (skipping the 2 leading spaces) -- must land between the
        # spaces and "BETA", not at column 0.
        client.call_tool('type', {'text': 'jIX'})
        client.call_tool('type', {'text': '\\x1b'})
        wait_for_screen_settled(
            client,
            lambda rs: rs[3].rstrip() == '  XBETA INDENT',
            'vi: `I` inserted before the first non-blank char, '
              'after the 2 leading spaces')
        print('[check-play] vi: `j` then `I` + "X" + ESC -- '
              '"  XBETA INDENT" (skipped the leading spaces)')

        # `/APPLE` -- forward search from row 4 (no match there) must
        # land on row 5 ("GAMMA APPLE ITEM"), col 6. Verified via a
        # SUBSEQUENT `i` + marker + ESC landing exactly there (VI-
        # DESIGN sec 7's own technique for a claim no redirected-fd
        # test could make) -- inserting "Q" right before "APPLE"
        # proves the cursor's own column, not just "some match
        # happened somewhere".
        client.call_tool('type', {'text': '/APPLE\r'})
        client.call_tool('type', {'text': 'iQ'})
        client.call_tool('type', {'text': '\\x1b'})
        wait_for_screen_settled(
            client,
            lambda rs: rs[4].rstrip() == 'GAMMA QAPPLE ITEM',
            'vi: `/APPLE` landed the cursor exactly at "APPLE"\'s '
              'own start column on row 5 (the `i`+Q+ESC insert '
              'proves the column)')
        print('[check-play] vi: `/APPLE` -> row 5, `i`+"Q"+ESC -- '
              '"GAMMA QAPPLE ITEM"')

        # `n` -- repeat forward. ESC leaves the cursor ON the Q just
        # typed (real vi; until 2026-09-05 it sat at the line's end,
        # and this step was calibrated on that bug), so a bare `n`
        # would re-find "APPLE" one column to the right on the SAME
        # row. `$` first: from the line's end, `n` must advance PAST
        # row 5 to row 7 ("EPSILON APPLE"), col 8. Same `$` before
        # every later n/N/? here, for the same reason. Expected rows
        # re-derived by replaying the whole sequence in vim -u NONE.
        client.call_tool('type', {'text': '$n'})
        client.call_tool('type', {'text': 'iZ'})
        client.call_tool('type', {'text': '\\x1b'})
        wait_for_screen_settled(
            client,
            lambda rs: rs[6].rstrip() == 'EPSILON ZAPPLE',
            'vi: `n` advanced past row 5 to the NEXT occurrence, '
              'row 7')
        print('[check-play] vi: `n` -> row 7, `i`+"Z"+ESC -- '
              '"EPSILON ZAPPLE"')

        # `n` again -- row 7 is the LAST line, so this one must WRAP
        # past end-of-file back to row 1 ("ALPHA APPLE999", now
        # matching at col 6) -- the default-ON `wrap` behavior VI-
        # DESIGN sec 1/the Ex Reference Manual names.
        client.call_tool('type', {'text': '$n'})
        client.call_tool('type', {'text': 'iW'})
        client.call_tool('type', {'text': '\\x1b'})
        wait_for_screen_settled(
            client,
            lambda rs: rs[0].rstrip() == 'ALPHA WAPPLE999',
            'vi: `n` WRAPPED past end-of-file back to row 1 (the '
              'default-ON `wrap` behavior)')
        print('[check-play] vi: `n` WRAPS past EOF -> row 1, '
              '`i`+"W"+ESC -- "ALPHA WAPPLE999"')

        # `?APPLE` -- backward search. Row 1 itself still contains
        # "APPLE" (shifted to col 7 by the `i`+W edit above), strictly
        # BEFORE the cursor once `$` parks it at row 1's own end --
        # must find it on the SAME line, not walk off to another one.
        client.call_tool('type', {'text': '$?APPLE\r'})
        client.call_tool('type', {'text': 'iV'})
        client.call_tool('type', {'text': '\\x1b'})
        wait_for_screen_settled(
            client,
            lambda rs: rs[0].rstrip() == 'ALPHA WVAPPLE999',
            'vi: `?APPLE` found the match on the SAME line, before '
              'the cursor, without needing another line')
        print('[check-play] vi: `?APPLE` -> row 1 (same line), '
              '`i`+"V"+ESC -- "ALPHA WVAPPLE999"')

        # `N` -- OPPOSITE of the last search's direction (backward),
        # so this one searches FORWARD again, landing on row 5's own
        # still-present "APPLE" (shifted to col 7 by the earlier `i`
        # +Q edit) -- from row 1's end (`$`), past row 1's own APPLE.
        client.call_tool('type', {'text': '$N'})
        client.call_tool('type', {'text': 'iR'})
        client.call_tool('type', {'text': '\\x1b'})
        wait_for_screen_settled(
            client,
            lambda rs: rs[4].rstrip() == 'GAMMA QRAPPLE ITEM',
            'vi: `N` reversed direction from the last `?` (back) to '
              'forward, landing on row 5')
        print('[check-play] vi: `N` (opposite of `?`, so forward) '
              '-> row 5, `i`+"R"+ESC -- "GAMMA QRAPPLE ITEM"')

        # No-match: search for something that genuinely is not in
        # the buffer -- status message only, cursor UNMOVED (still
        # row 5 from the `N` test above), no crash/hang.
        client.call_tool('type', {'text': '/ZZZNOTHERE\r'})
        wait_for_screen_settled(
            client,
            lambda rs: 'Pattern not found' in screen_blob(rs),
            'vi: a search with no match anywhere shows the status '
              'message, does not crash')
        client.call_tool('type', {'text': 'i9'})
        client.call_tool('type', {'text': '\\x1b'})
        wait_for_screen_settled(
            client,
            lambda rs: rs[4].rstrip() == 'GAMMA Q9RAPPLE ITEM',
            'vi: a failed search left the cursor exactly where it '
              'was (still row 5, ON the R the last insert typed)')
        print('[check-play] vi: `/ZZZNOTHERE` -> "Pattern not '
              'found", cursor stayed put -- no crash')

        client.call_tool('type', {'text': ':q!\r'})
        wait_for_screen_settled(client, _prompt_now,
                                'shell prompt back after vi `:q!` '
                                '(VIFIX edits discarded)')
        print('[check-play] vi: insert-entry variants (a A I o O -- '
              'via A/o/O/I above) and search (/ ? n N) all landed '
              'exactly where designed; `:q!` discarded the scratch '
              'edits')

        # -----------------------------------------------------------
        # vi MOTION SET (Stream 1) -- KNOWN RED: word motions w/b/e
        # walk the cursor to EOF (see memory vi-motion-merge-state).
        # Runs LAST so the insert/search phase above is proven first.
        # vi MOTION SET (docs/VI-DESIGN.md sec 4.1, this task): w/W/
        # b/B/e/E, 0/^/$, G, f/F/t/T/;/,, and the count prefix. No
        # `vi < script` equivalent exists (VI-DESIGN sec 7), so this
        # is the ONLY gate that can prove a motion actually lands the
        # cursor in the right place -- the technique is the SAME one
        # the birth phase above already used (a scriptable predicate
        # can't distinguish "cursor here" from "cursor there" any
        # other way): move, `iX` + ESC to drop a visible marker
        # exactly where the cursor is, then assert the row. Each case
        # reopens VIMOTFIX fresh and `:q!`s out without writing, so
        # the fixture stays pristine (byte-identical) for every
        # later case -- no state carried between them.
        VIM_ROW1 = 0
        VIM_ROW5 = 4
        VIM_STATUSROW = 23

        def _vi_mot_open():
            client.call_tool('type', {'text': 'VI VIMOTFIX\r'})
            wait_for_screen_settled(
                client,
                lambda rs: (rs[VIM_ROW1].rstrip() == 'FOO.BAR BAZ QUX'
                           and '"VIMOTFIX"' in rs[VIM_STATUSROW]),
                'vi: VIMOTFIX opened for the motion phase')

        def _vi_mot_case(keys, row_idx, expect, label):
            _vi_mot_open()
            client.call_tool('type', {'text': keys})
            client.call_tool('type', {'text': 'iX'})
            client.call_tool('type', {'text': '\\x1b'})
            wait_for_screen_settled(
                client,
                lambda rs: rs[row_idx].rstrip() == expect,
                label)
            print(f'[check-play] vi: {label}')
            client.call_tool('type', {'text': ':q!\r'})
            wait_for_screen_settled(client, _prompt_now,
                                    'shell prompt back after vi '
                                    f'`:q!` ({label})')

        # Line 1 is "FOO.BAR BAZ QUX" (indices F0 O1 O2 .3 B4 A5 R6
        # sp7 B8 A9 Z10 sp11 Q12 U13 X14, length 15) -- punctuation-
        # aware `w`'s own word list from col 0 is "FOO"(0) -> "."(3)
        # -> "BAR"(4) -> "BAZ"(8), hand-walked against real vi's own
        # documented word-boundary rule (a punctuation run is its
        # own word), not guessed.
        _vi_mot_case('www', VIM_ROW1, 'FOO.BAR XBAZ QUX',
                    'w x3 walks FOO -> . -> BAR -> BAZ, landing col 8')
        _vi_mot_case('wwwb', VIM_ROW1, 'FOO.XBAR BAZ QUX',
                    'b from BAZ(8) lands on the start of BAR (col 4)')
        _vi_mot_case('e', VIM_ROW1, 'FOXO.BAR BAZ QUX',
                    'e from col 0 lands on the end of FOO (col 2)')
        _vi_mot_case('www0', VIM_ROW1, 'XFOO.BAR BAZ QUX',
                    '0 after www returns to column 0')
        _vi_mot_case('$', VIM_ROW1, 'FOO.BAR BAZ QUXX',
                    '$ from col 0 lands on the LAST char (col 14)')
        # THE COUNT-PREFIX SABOTAGE TARGET: `3w` must equal `www`
        # exactly (same landing spot, col 8) -- if the digit
        # accumulator only remembered the last digit or never
        # multiplied by 10, this would silently degrade to a single
        # `w` (col 3, a DIFFERENT and clearly wrong row).
        _vi_mot_case('3w', VIM_ROW1, 'FOO.BAR XBAZ QUX',
                    '3w (one count) lands on the SAME spot www did')
        # THE `$` SABOTAGE TARGET: an off-by-one in $'s own target
        # (landing ON len instead of len-1, or not subtracting at
        # all) inserts the marker in a visibly different column.
        _vi_mot_case('fZ', VIM_ROW1, 'FOO.BAR BAXZ QUX',
                    'fZ finds the Z in BAZ (col 10) and lands ON it')
        _vi_mot_case('G', VIM_ROW5, 'XFIFTH LAST LINE',
                    'G with no count lands on the LAST line (row 5)')
        print('[check-play] vi: motion set (w/b/e, 0/$, count '
              'prefix, f, G) all landed the cursor exactly where '
              'hand-computed -- VI_DOMOTION span contract proven '
              'through VI_GOMOTION\'s command-mode path')

        # -----------------------------------------------------------
        # vi OPERATORS (Stream 3, docs/VI-DESIGN.md sec 4.1/4.3/4.4,
        # viop.s) -- d/c/y + motion, dd/cc/yy doubled, x D C Y s p P
        # J r ~. Unlike the pure-motion cases above, an operator's
        # effect is directly visible in the line text itself -- no
        # `iX`+ESC marker needed, just reopen VIMOTFIX fresh (same
        # `_vi_mot_open` every case above already used, so the
        # fixture stays pristine), run the keys, assert the exact
        # resulting row(s), `:q!` out. Each expected string below was
        # hand-derived against VIMOTFIX's own known bytes ("FOO.BAR
        # BAZ QUX" is F0 O1 O2 .3 B4 A5 R6 sp7 B8 A9 Z10 sp11 Q12 U13
        # X14, length 15; "SECOND LINE HERE" is 16 bytes), not by
        # running the code first.
        def _vi_op_case(keys, checks, label):
            _vi_mot_open()
            client.call_tool('type', {'text': keys})

            def _pred(rs):
                return all(rs[idx].rstrip() == expect
                          for idx, expect in checks)

            wait_for_screen_settled(client, _pred, label)
            print(f'[check-play] vi: {label}')
            client.call_tool('type', {'text': ':q!\r'})
            wait_for_screen_settled(client, _prompt_now,
                                    'shell prompt back after vi '
                                    f'`:q!` ({label})')

        # `dw` -- charwise EXCLUSIVE delete: col0's word run "FOO"
        # (VI_CLASS: word) ends before "." (punct, a DIFFERENT
        # class) at col3 -- VI_OP_CWD's own single-line splice path.
        _vi_op_case('dw', [(VIM_ROW1, '.BAR BAZ QUX')],
                    'dw deletes "FOO" (word span, exclusive) -- '
                    '".BAR BAZ QUX" remains')
        # `x` -- delete char forward: just col0's 'F'.
        _vi_op_case('x', [(VIM_ROW1, 'OO.BAR BAZ QUX')],
                    'x deletes the char under the cursor -- "F" gone')
        # `D` (= d$) after `www` (lands col8, on BAZ's own "B" --
        # the SAME landing spot the motion phase above proved):
        # deletes col8 through the last char (14), inclusive.
        _vi_op_case('wwwD', [(VIM_ROW1, 'FOO.BAR')],
                    'D (= d$) from col8 deletes to end of line -- '
                    '"FOO.BAR" remains')
        # `r` -- replace ONE char (no motion, no nested nested read
        # -- VI_RAWKEY reads the replacement directly).
        _vi_op_case('rZ', [(VIM_ROW1, 'ZOO.BAR BAZ QUX')],
                    'rZ replaces col0\'s "F" with "Z"')
        # `~` -- toggle case of the char under the cursor ("F" ->
        # "f"), cursor then advances past it.
        _vi_op_case('~', [(VIM_ROW1, 'fOO.BAR BAZ QUX')],
                    '~ toggles "F" to "f" at col0')
        # `cw` -- charwise change: same "FOO" span as `dw`, then
        # falls into insert (VI_INS_NOSNAP) -- typed "XYZ" replaces
        # the deleted word exactly, `.BAR BAZ QUX` untouched.
        _vi_op_case('cwXYZ\\x1b', [(VIM_ROW1, 'XYZ.BAR BAZ QUX')],
                    'cw deletes "FOO" then inserts "XYZ" -- '
                    '"XYZ.BAR BAZ QUX"')
        # `J` -- join line 1 with line 2, ONE separating space (POSIX
        # vi; the space is added inside ED_CMD_J gated on ED_D1FLAG,
        # which only vi's callers set -- ed/ex's own `j` stays
        # separator-free, 2026-09-05). Line 3 ("THIRD LINE HERE TOO")
        # shifts up to become the new row 2.
        _vi_op_case('J', [(VIM_ROW1, 'FOO.BAR BAZ QUX SECOND LINE '
                                    'HERE'),
                          (1, 'THIRD LINE HERE TOO')],
                    'J joins line 1+2 with one space, line 3 '
                    'shifts up to row 2')
        # `dd` -- linewise delete: the WHOLE line 1 disappears, line
        # 2 ("SECOND LINE HERE") shifts up to become the new row 1.
        _vi_op_case('dd', [(VIM_ROW1, 'SECOND LINE HERE')],
                    'dd deletes the whole line -- line 2 shifts up '
                    'to row 1')
        # THE COUNT-COMPOSITION SABOTAGE TARGET: `3dd` must remove
        # THREE lines total (VI_OP_DDSPAN's own count=N-total-lines
        # rule, NOT a repeat count) -- if the doubled-form count
        # path were broken (VI_OP_COMBINE never firing, or `dd`
        # itself ignoring the leading digit), this would degrade to
        # a single-line `dd` and land a DIFFERENT, wrong row 1.
        _vi_op_case('3dd', [(VIM_ROW1, 'FOURTH LINE'),
                            (1, 'FIFTH LAST LINE')],
                    '3dd removes 3 lines -- "FOURTH LINE" now row 1')
        # `yy` + `p` -- linewise yank into VI_REG (no mutation, `yy`
        # itself never moves ED_CURLINE), then `p` pastes it back as
        # a NEW line 2 -- line 1 stays the pristine original, the
        # pasted line 2 is byte-identical to it, and the old line 2
        # ("SECOND LINE HERE") shifts down to row 3.
        _vi_op_case('yyp', [(VIM_ROW1, 'FOO.BAR BAZ QUX'),
                            (1, 'FOO.BAR BAZ QUX'),
                            (2, 'SECOND LINE HERE')],
                    'yy yanks line 1 (unnamed register), p pastes '
                    'it as a new line 2')
        # `u` -- single-level undo (EX_SNAPSHOT-before-mutate, this
        # file's own discipline) reverses a WHOLE `dd`, not just
        # part of it: line 1 comes back exactly as it was, and line
        # 2 ("SECOND LINE HERE", which `dd` had shifted up to row 1)
        # is back at row 2 where it belongs.
        _vi_op_case('ddu', [(VIM_ROW1, 'FOO.BAR BAZ QUX'),
                            (1, 'SECOND LINE HERE')],
                    'u undoes a `dd` as one unit -- both lines '
                    'restored')
        print('[check-play] vi: operators (d/c/y+motion, dd/cc/yy, '
              'x D r ~, J, p, u) all mutated the buffer exactly as '
              'hand-derived -- viop.s\'s charwise splice and '
              'linewise ED_DLT_RANGE/ED_INSRT_AFTR paths both '
              'proven through the keyboard')

        _typed_case('CD ..', [], 'cd back out of DEMO/')

        # THE SHELL'S PID IS READ BEFORE ITS EXIT. init respawns the
        # console shell the moment it dies and the respawn overwrites
        # R_SH_PID, so read afterwards the cell is the NEW shell's pid
        # and "wait pid == spawn pid" held only when the respawn happened
        # to land in the dead shell's bank (a warm lazy-free hit). What
        # this compares is SPAWN's return and WAIT's return for the SAME
        # shell, which needs no allocator behaviour to hold
        # (docs/KFIX-NOTES.md item 2: a write to /BIN/SH while it runs
        # drops that tag, and the respawn then takes another bank).
        sh_pid = peek_aux1(client, R_SH_PID)[0]
        client.call_tool('type', {'text': '\\x04'})
        done = wait_for_done(client)
        err = peek_aux1(client, R_ERR)[0]
        step = peek_aux1(client, R_STEP)[0]
        wait_pid = peek_aux1(client, R_WAIT_PID)[0]
        sh_status = peek_aux1(client, R_SH_STATUS)[0]
        print(f'[check-play] done=${done:02X} err=${err:02X} step=${step:02X} '
              f'sh_pid={sh_pid} wait_pid={wait_pid} '
              f'sh_status=${sh_status:02X}')

        failures = []
        if done != 0xAA:
            failures.append(f'launcher did not finish successfully '
                            f'(done=${done:02X}, err=${err:02X}, step={step})')
        if err != 0:
            failures.append(f'R_ERR expected $00, got ${err:02X}')
        if sh_pid == 0:
            failures.append('SPAWN(SH) returned pid 0')
        if wait_pid != sh_pid:
            failures.append(f'wait pid {wait_pid} != spawn pid {sh_pid}')
        if sh_status != 0:
            failures.append(f'sh exit status expected $00, got ${sh_status:02X}')

        if failures:
            print('[check-play] final screen:', file=sys.stderr)
            print(screen_blob(rows), file=sys.stderr)
            for failure in failures:
                print(f'[check-play] FAIL: {failure}', file=sys.stderr)
            return 1

        print('[check-play] PASS: interactive shell reached tty prompt, '
              'accepted IIe left-arrow/DEL erase input, ran LS '
              'through a child process, displayed utility names on the text '
              'console, paged /DEMO/LONG through MORE (hold, SPACE, q), '
              'paged its own MAN page through MORE too (hold, q), '
              'and exited 0 on ^D EOF')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
