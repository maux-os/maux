#!/usr/bin/env python3
"""check_vi.py -- total-coverage functional suite for the vi editor
(`make check-vi`).

Boots build/play.po and drives vi through the emulator keyboard, one
self-contained case per feature. Each case opens a fresh vi session,
sets up a known buffer, exercises ONE command, and asserts on the glass
(screen_text) -- checking MID-INSERT where the bug would only show before
ESC's repaint. A failing case is caught, recorded, and the harness
recovers to the shell so the REST still run: one invocation reports every
broken feature, not just the first.

This is the systematic replacement for finding vi bugs piecemeal. Every
command in the dispatch tables (vicmd.s / vimotion.s / viop.s /
viinsert.s / excmd.s) should have a case here; a command with no case is
a coverage gap, not a passing test.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
import gate_race as GR                                  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'play.po')
ESC = '\x1b'


# --------------------------------------------------------------------
# glass + timing
# --------------------------------------------------------------------
def rows(client):
    """The 80-col merged view (or main when 40-col)."""
    r = client.call_tool('screen_text', {})
    return r.get('merged') or r.get('main', [])


def settle(client, pred, label, max_steps=1500):
    """Step until `pred(rows)` holds on two consecutive polls (avoids a
    mid-repaint tear), else raise AssertionError with the screen."""
    held = False
    rs = []
    for _ in GR.polls(client, max_steps):
        rs = rows(client)
        if pred(rs):
            if held:
                return rs
            held = True
        else:
            held = False
    blob = '\n'.join(f'{i:2d}|{r.rstrip()}' for i, r in enumerate(rs))
    raise AssertionError(f'timed out waiting for {label}; screen was:\n'
                         f'{blob}')


def t(client, text):
    client.call_tool('type', {'text': text})
    # Drain the //e keyboard latch. It holds ONE key until read, and the
    # inject queue drops keys once it backs up (a human types far slower
    # than the drain), so give maux cycles to consume this burst before
    # the next inject -- otherwise a case silently loses keystrokes.
    for _ in range(max(4, len(text) + 2)):
        client.call_tool('step', {'cycles': 50_000})


# --------------------------------------------------------------------
# vi session lifecycle
# --------------------------------------------------------------------
def _at_prompt(rs):
    nb = [r for r in rs if r.strip()]
    return bool(nb) and nb[-1].strip() == '$'


def _in_vi(rs):
    # vi is the only thing that paints '~' past-EOF markers, and the
    # status row (bottom) carries a "filename".
    return any(r.strip() == '~' for r in rs)


def boot(client):
    r = client.call_tool('reset', {'backend': 'fast', 'aux': 'ramworks'})
    if not r.get('ok'):
        raise RuntimeError(f'reset failed: {r}')
    # copy-on-write: file-write cases (:w/:wq/ZZ) mutate a throwaway
    # overlay, never build/play.po -- so the suite leaves no VWQ/VZZ
    # droppings on the shared image.
    r = client.call_tool('mount_disk', {'path': DISK, 'unit': 1, 'copy': True})
    if r.get('ok') is False:
        raise RuntimeError(f'mount_disk failed: {r}')
    settle(client, _at_prompt, 'shell prompt after boot', max_steps=3000)


def open_vi(client, fname=''):
    """Open vi on `fname` (empty = new buffer) and wait until it paints."""
    t(client, f'VI {fname}\r' if fname else 'VI\r')
    settle(client, _in_vi, f'vi to open ({fname or "new buffer"})')


def recover(client):
    """Get back to a shell prompt whatever state a case left, WITHOUT
    writing any file (`:q!`). Tolerates already being at the shell.

    HARD fallback (2026-09-05): a case that leaves vi genuinely WEDGED
    cannot be talked back to the shell with ESC/:q!. Rather than let
    that ONE case cascade into every case after it, reboot the
    emulator so each case is independent. The wedging case still fails
    on its OWN assertion; this only stops the collateral damage.
    (The `:nu`/`:!` wedge this was written for was the ED_DISPATCH1
    `jsr EX_CMD` stack leak, fixed 2026-09-07 -- VI_D1SP, vicmd.s,
    gated by check_vi_bang.py; `:nu` now returns to vi.)
    """
    for _ in range(3):
        if _at_prompt(rows(client)):
            return
        t(client, ESC)
        t(client, ':q!\r')
        try:
            settle(client, _at_prompt, 'shell prompt (recover)',
                   max_steps=800)
            return
        except AssertionError:
            continue
    # Soft recovery failed -- the editor is wedged. Hard-reboot so the
    # NEXT case starts clean (boot() re-mounts the copy-on-write image).
    boot(client)


def line(rs, n):
    """Row n, right-stripped."""
    return rs[n].rstrip() if n < len(rs) else ''


def line_eq(rs, n, expected):
    """Row n equals `expected`, TOLERATING the single cursor cell.

    screen_text substitutes a glyph for the cell under the cursor, and
    for a lowercase letter it is a DIFFERENT glyph (the //e inverse fold
    maps 'w' -> '7', 'a' -> '!', etc.), so an exact compare on a line the
    cursor sits on is unreliable. Accept an exact match, or a same-length
    line differing in at most one position (that one being the cursor).
    A length change is a real edit and is NEVER tolerated.
    """
    got = line(rs, n)
    if got == expected:
        return True
    if len(got) != len(expected):
        return False
    return sum(a != b for a, b in zip(got, expected)) <= 1


# --------------------------------------------------------------------
# cases -- each takes the client, sets up its own buffer, asserts.
# Grouped by category. A case raises AssertionError on failure.
# --------------------------------------------------------------------

# ---- insert entry + live echo (the a/A/I/o/O cursor-placement class) --
def case_insert_i(client):
    open_vi(client)
    t(client, 'iHELLO')
    settle(client, lambda rs: line(rs, 0) == 'HELLO',
           'i: HELLO echoed live on line 1')
    t(client, ESC)
    settle(client, lambda rs: line(rs, 0) == 'HELLO', 'i: HELLO after ESC')


def case_insert_A_appends_at_eol(client):
    open_vi(client)
    t(client, 'iHELLO' + ESC)
    settle(client, lambda rs: line(rs, 0) == 'HELLO', 'setup HELLO')
    t(client, 'AXYZ')
    # MID-INSERT: XYZ must land AFTER the O, not over it.
    settle(client, lambda rs: rs[0].startswith('HELLOXYZ'),
           'A: live echo appends at EOL, not over the tail')
    t(client, ESC)


def case_insert_a_after_cursor(client):
    open_vi(client)
    t(client, 'iHELLO' + ESC)
    settle(client, lambda rs: line(rs, 0) == 'HELLO', 'setup HELLO')
    t(client, '0aZ')          # col 0 (on H), append -> after H
    settle(client, lambda rs: rs[0].startswith('HZ'),
           'a: Z inserted after the char under the cursor')
    t(client, ESC)
    settle(client, lambda rs: line(rs, 0) == 'HZELLO', 'a: HZELLO after ESC')


def case_insert_I_first_nonblank(client):
    open_vi(client)
    t(client, 'iHELLO' + ESC)
    # I inserts at first non-blank (col 0). An INSERT (unlike append)
    # echoes over the char at the cursor mid-insert -- the buffer is
    # right but the glass only reflows on ESC -- so check after ESC.
    t(client, '$IX' + ESC)
    settle(client, lambda rs: line_eq(rs, 0, 'XHELLO'),
           'I: X inserted before the first char')


def case_insert_o_below(client):
    open_vi(client)
    t(client, 'iAAA' + ESC)
    t(client, '1Go')
    # the ~ must be GONE from the opened row before anything is typed
    settle(client, lambda rs: line(rs, 0) == 'AAA' and rs[1].strip() == '',
           'o: opened a blank line below (no stray ~)')
    t(client, 'BBB')
    settle(client, lambda rs: line(rs, 0) == 'AAA' and line(rs, 1) == 'BBB',
           'o: BBB echoed on the opened row below')
    t(client, ESC)


def case_insert_O_above(client):
    open_vi(client)
    t(client, 'iAAA' + ESC)
    t(client, '1GOZZZ')
    settle(client, lambda rs: line(rs, 0) == 'ZZZ' and line(rs, 1) == 'AAA',
           'O: ZZZ opened on a new line above AAA')
    t(client, ESC)


def case_insert_cr_splits(client):
    open_vi(client)
    t(client, 'iAAA\rBBB' + ESC)
    settle(client, lambda rs: line(rs, 0) == 'AAA' and line(rs, 1) == 'BBB',
           'insert CR: split into two lines, both survive ESC')


# ---- insert-mode erase (2026-09-10) ------------------------------------
# The //e's left-arrow IS its backspace key (^H, one wire). The tty frames
# it as ESC [ D; before the kernel committed that trio as ONE line, vi's
# insert loop took the ESC as end-of-insert and the operator's Enter after
# it ran as a command-mode key ("I 'o'd a line and I can't press enter").
BS = '\x08'       # left-arrow
DEL = '\x7f'
RIGHT = '\x15'    # right-arrow


def case_ins_erase_left(client):
    open_vi(client)
    t(client, 'iHELLO' + BS + BS)
    # MID-INSERT: LO gone from the glass (the cursor cell may carry a
    # glyph, so allow one trailing cell).
    settle(client, lambda rs: line(rs, 0)[:3] == 'HEL'
           and len(line(rs, 0).rstrip()) <= 4 and line(rs, 0)[:4] != 'HELL',
           'left-arrow x2 mid-insert: HEL on the glass')
    t(client, 'X' + ESC)
    settle(client, lambda rs: line_eq(rs, 0, 'HELX'),
           'left-arrow erased in insert; typing continued: HELX')


def case_ins_erase_del(client):
    open_vi(client)
    t(client, 'iHELLO' + DEL + 'X' + ESC)
    settle(client, lambda rs: line_eq(rs, 0, 'HELLX'),
           'DEL erased the last typed char: HELLX')
    # The glass alone is not proof: a literal $FF stored in the line
    # renders as a destructive backspace and LOOKS erased (seen on the
    # pre-fix code). Two $x must leave HEL -- a stored DEL byte would
    # leave HELLO.
    t(client, '$xx')
    settle(client, lambda rs: line_eq(rs, 0, 'HEL'),
           'DEL erased in the BUFFER, not just on the glass: $xx -> HEL')


def case_ins_erase_tail(client):
    """Erase with a pushed tail: the tail is redrawn one cell left and
    the cell its last char vacated is blanked, live."""
    open_vi(client)
    t(client, 'iHELLO' + ESC)
    t(client, '0iAB' + BS)
    settle(client, lambda rs: line_eq(rs, 0, 'AHELLO'),
           'erase under a tail: AHELLO on the glass mid-insert')
    t(client, 'C' + ESC)
    settle(client, lambda rs: line_eq(rs, 0, 'ACHELLO'),
           'ACHELLO after ESC')


def case_ins_erase_floor(client):
    """POSIX: <erase> never crosses the insert point, never joins."""
    open_vi(client)
    t(client, 'iHELLO' + ESC)
    t(client, '$i' + BS + BS + DEL + 'Q' + ESC)
    settle(client, lambda rs: line_eq(rs, 0, 'HELLQO'),
           'erase at the insert point is a no-op: HELLQO')


def case_ins_erase_o_enter(client):
    """The operator's exact keystrokes (2026-09-10): o, text, seven
    left-arrows, Enter, more text, ESC. Enter must still open a line."""
    open_vi(client)
    t(client, 'iAAA' + ESC)
    t(client, 'oThis is a new line' + BS * 7 + '\rXXX' + ESC)
    settle(client, lambda rs: line(rs, 0) == 'AAA'
           and line(rs, 1) == 'This is a n' and line_eq(rs, 2, 'XXX'),
           'o + text + left-arrows + Enter + text: three lines')


def case_ins_arrow_exits(client):
    """The OTHER arrows still end the insert and move (exit-and-move):
    right-arrow after `0iZ` lands on col 1, so x eats the H."""
    open_vi(client)
    t(client, 'iHELLO' + ESC)
    t(client, '0iZ' + RIGHT + 'x')
    settle(client, lambda rs: line_eq(rs, 0, 'ZELLO'),
           'right-arrow in insert: exit, move right, x deleted H')


def case_motion_cr_plus(client):
    """Enter is `+`: next line, first non-blank; invalid on the last
    line; linewise as an operator's motion (d<CR> = two lines)."""
    open_vi(client)
    t(client, 'iAAA\r  BBB\rCCC' + ESC)
    settle(client, lambda rs: line(rs, 2) == 'CCC', 'setup 3 lines')
    # Assert with x (a LENGTH change): line_eq tolerates one differing
    # cell for the cursor glyph, so an `r` on the wrong line can pass.
    # x lands on the first NON-BLANK, so it eats a B and the blanks stay;
    # a no-move would eat an A on line 0 (AAA is asserted exactly).
    t(client, '1G\rx')
    settle(client, lambda rs: line(rs, 0) == 'AAA' and line_eq(rs, 1, '  BB'),
           'Enter: next line, first non-blank (x ate a B, blanks kept)')
    t(client, '1G+x')
    settle(client, lambda rs: line(rs, 0) == 'AAA' and line_eq(rs, 1, '  B'),
           '+: same motion')
    t(client, '3G\rx')
    settle(client, lambda rs: line(rs, 1) == '  B' and line_eq(rs, 2, 'CC'),
           'Enter on the last line: no move (x ate a C)')
    t(client, '1Gd\r')
    settle(client, lambda rs: line_eq(rs, 0, 'CC') and rs[1].strip() == '~',
           'd<CR>: deleted two lines')


# ---- motions ----------------------------------------------------------
def case_motion_dollar_zero(client):
    open_vi(client)
    t(client, 'iHELLO' + ESC)
    # $ then x deletes the last char; 0 then x deletes the first.
    t(client, '$x')
    settle(client, lambda rs: line(rs, 0) == 'HELL', '$: moved to EOL, x cut O')
    t(client, '0x')
    settle(client, lambda rs: line(rs, 0) == 'ELL', '0: moved to col 0, x cut H')
    t(client, ESC)


def case_motion_word(client):
    open_vi(client)
    t(client, 'ione two three' + ESC)
    t(client, '0wx')          # w -> start of 'two', x cuts 't'
    settle(client, lambda rs: line_eq(rs, 0, 'one wo three'),
           'w: advanced one word, x cut its first char')
    t(client, ESC)


def case_motion_G(client):
    open_vi(client)
    t(client, 'iL1\rL2\rL3' + ESC)
    t(client, '1Gx')          # top, cut first char of L1
    settle(client, lambda rs: line(rs, 0) == '1',
           'G/1G: to top line, x cut L1[0]')
    t(client, 'Gx')           # last line, cut first char of L3
    settle(client, lambda rs: line(rs, 2) == '3',
           'G: to last line, x cut L3[0]')
    t(client, ESC)


# ---- operators --------------------------------------------------------
def case_op_dd(client):
    open_vi(client)
    t(client, 'iL1\rL2\rL3' + ESC)
    t(client, '1Gdd')         # delete line 1
    settle(client, lambda rs: line(rs, 0) == 'L2' and line(rs, 1) == 'L3',
           'dd: deleted line 1, L2/L3 remain')
    t(client, ESC)


def case_op_x(client):
    open_vi(client)
    t(client, 'iABC' + ESC)
    t(client, '0x')
    settle(client, lambda rs: line(rs, 0) == 'BC', 'x: cut the char under cursor')
    t(client, ESC)


def case_op_D_to_eol(client):
    open_vi(client)
    t(client, 'iHELLO' + ESC)
    t(client, '0lD')          # col 1, D deletes to EOL -> 'H'
    settle(client, lambda rs: line(rs, 0) == 'H',
           'D: deleted from cursor to EOL')
    t(client, ESC)


def case_op_dw(client):
    open_vi(client)
    t(client, 'ione two three' + ESC)
    t(client, '0dw')          # delete word -> 'two three'
    # line_eq, not ==: the cursor lands on the 't' and renders as '4'
    # (the //e inverse fold). This passed with == only while the row
    # text and the cursor placement were SEPARATE writes and the poll
    # matched in the gap; the repaint is one write now (2026-09-05).
    settle(client, lambda rs: line_eq(rs, 0, 'two three'),
           'dw: deleted the first word')
    t(client, ESC)


# -- `w` as an OPERATOR motion at a line's end (vimotion.s VI_W_OPADJ,
# viop.s VI_OP_CWD :multi), 2026-09-05. Operator-found ("dw seems
# inconsistent"): dw on a line's LAST word left its final char behind
# ("one two e"), and with a line below it destroyed line 1 outright
# ("cc dd" alone) -- two bugs: VI_MO_ADV1 clamps the walk to the last
# char at end of buffer (exclusive end -> char kept), and the cross-
# line delete core lost the kept prefix because ED_LINETEXT/STRLEN
# clobbered the SUBSCR index. Expected values are POSIX vi's, measured
# against vim -u NONE (nvi unavailable on this host).
def case_op_dw_lastword(client):
    open_vi(client)
    t(client, 'ione two three' + ESC)
    t(client, '0wwdw')        # last word: delete to EOL, all of it
    settle(client, lambda rs: line_eq(rs, 0, 'one two'),
           "dw on the last word deletes ALL of it (was 'one two e')")
    t(client, ESC)


def case_op_dw_lastword_nojoin(client):
    open_vi(client)
    t(client, 'iaa bb\rcc dd' + ESC)
    t(client, '1Gwdw')        # last word of line 1: to EOL, NO join
    settle(client, lambda rs: line_eq(rs, 0, 'aa') and line(rs, 1) == 'cc dd',
           "dw on a last word with a line below deletes to EOL and keeps "
           "line 2 intact (was: line 1 gone, 'cc dd' on row 0)")
    t(client, ESC)


def case_op_dw_oneword_line(client):
    open_vi(client)
    t(client, 'ibb\rcc' + ESC)
    t(client, '1Gdw')         # one-word line: emptied, not deleted
    settle(client, lambda rs: rs[0].strip() == '' and line(rs, 1) == 'cc',
           'dw on a one-word line leaves it EMPTY (no linewise join)')
    t(client, ESC)


def case_op_2dw_across_lines(client):
    open_vi(client)
    t(client, 'iaa bb\rcc dd' + ESC)
    t(client, '1Gw2dw')       # count lands MID-line on line 2: joins
    settle(client, lambda rs: line_eq(rs, 0, 'aa dd')
           and rs[1].strip() in ('~', ''),
           "2dw across a line boundary joins to 'aa dd' (the cross-line "
           "delete core used to lose the 'aa ' prefix: 'dd')")
    t(client, ESC)


def case_op_cw_lastword(client):
    open_vi(client)
    t(client, 'ione two three' + ESC)
    t(client, '0wwcwX' + ESC)
    settle(client, lambda rs: line_eq(rs, 0, 'one two X'),
           "cw on the last word replaces ALL of it (was 'one two Xe')")
    t(client, ESC)


def case_ins_esc_cursor(client):
    """Operator-found 2026-09-05 ("x does weird things after adding
    characters back"): ESC out of i/a parked the cursor at END OF
    LINE (viinsert.s :doesc read the accumulator length AFTER the
    saved suffix was appended), so the next `x` deleted the line's
    last char instead of the char just typed. Real vi lands ON the
    last typed char. Three forms, each followed by `x` so the cursor
    COLUMN is what's judged, not the screen glyph."""
    open_vi(client)
    t(client, 'ihello world' + ESC)
    t(client, '0iQ' + ESC + 'x')            # x eats the Q, not the d
    settle(client, lambda rs: line_eq(rs, 0, 'hello world'),
           "i+ESC lands on the typed char: x removed the Q (was: the d)")
    t(client, '0xxx' + 'ihel' + ESC + 'x')  # cursor on the l typed
    settle(client, lambda rs: line_eq(rs, 0, 'helo world'),
           "xxx, ihel, ESC, x -> 'helo world' (was 'hello worl')")
    t(client, '0aZZ' + ESC + 'x')           # on the second Z
    settle(client, lambda rs: line_eq(rs, 0, 'hZelo world'),
           "a+ESC lands on the last typed char: x removed a Z")
    t(client, ESC)


def case_ins_live_tail(client):
    """Operator-found 2026-09-05 ("i looks like overstrike mode until
    ESC"): the live echo of each typed char overstruck the old text;
    the pushed tail was only redrawn by ESC. vi on insert-capable
    output shows the true line as you type (viinsert.s VI_INS_TAIL).
    Judged MID-insert, before ESC: the row must already read the
    spliced line, cursor on the first tail char ('h' folds to '(')."""
    open_vi(client)
    t(client, 'ihello world' + ESC)
    t(client, '0iZZ')                       # no ESC yet
    settle(client, lambda rs: line_eq(rs, 0, 'ZZhello world'),
           "mid-insert the tail is redrawn: 'ZZhello world' (was "
           "'ZZ,lo world' -- the echo overstruck 'he')")
    t(client, ESC)
    t(client, '0wiXY')                      # mid-line, still no ESC
    settle(client, lambda rs: line_eq(rs, 0, 'ZZhello XYworld'),
           "mid-line insert shows 'ZZhello XYworld' while typing")
    t(client, ESC)


def case_op_r_replace(client):
    open_vi(client)
    t(client, 'iABC' + ESC)
    t(client, '0rZ')          # replace under cursor with Z
    settle(client, lambda rs: line(rs, 0) == 'ZBC', 'r: replaced one char')
    t(client, ESC)


def case_op_J_join(client):
    open_vi(client)
    t(client, 'iAAA\rBBB' + ESC)
    t(client, '1GJ')
    # vi's J joins with a SEPARATING SPACE (POSIX) -- the old assertion
    # ('AAA' and 'BBB' both present) could not tell "AAA BBB" from
    # "AAABBB" and passed while J was joining spaceless (2026-09-05).
    settle(client, lambda rs: line_eq(rs, 0, 'AAA BBB')
           and rs[1].strip() in ('~', ''),
           'J: joined line 2 onto line 1 with ONE separating space')
    t(client, ESC)


def case_op_J_strip(client):
    # J strips the appended line's leading blanks, then one space.
    open_vi(client)
    t(client, 'iaa\r   bb' + ESC)
    t(client, '1GJ')
    settle(client, lambda rs: line_eq(rs, 0, 'aa bb'),
           "J strips the next line's leading blanks before the space")
    t(client, ESC)


def case_op_X_delete_before(client):
    # `X` deletes the char BEFORE the cursor (was unimplemented, a
    # no-op, until 2026-09-05 -- found by check_posixvi).
    open_vi(client)
    t(client, 'iABCDE' + ESC)
    t(client, '$X')            # cursor on E; X removes D
    settle(client, lambda rs: line_eq(rs, 0, 'ABCE'),
           'X: deleted the char before the cursor (D), leaving ABCE')
    t(client, '03X')           # at col 0: nothing before -> no-op
    settle(client, lambda rs: line_eq(rs, 0, 'ABCE'),
           'X at column 0 is a no-op')
    t(client, ESC)


def case_op_S_change_line(client):
    # `S` = `cc`: change the whole line (was unimplemented until
    # 2026-09-05 -- found by check_posixvi).
    open_vi(client)
    t(client, 'iOLD\rKEEP' + ESC)
    t(client, '1GSNEW' + ESC)  # change line 1
    settle(client, lambda rs: line_eq(rs, 0, 'NEW') and line(rs, 1) == 'KEEP',
           'S changed line 1 to NEW, line 2 intact')
    t(client, ESC)


def case_op_cG_change_eof(client):
    # `cG` change-to-EOF on the LAST-line path: the reopened insert
    # line landed at the TOP before 2026-09-05 (VI_OP_LWCT used dot,
    # not the deletion start) -- found by check_posixvi.
    open_vi(client)
    t(client, 'iL1\rL2' + ESC)
    t(client, '2GcGNEW' + ESC)  # change line 2 to EOF
    settle(client, lambda rs: line(rs, 0) == 'L1' and line_eq(rs, 1, 'NEW'),
           'cG from line 2 leaves L1, then NEW (not NEW at the top)')
    t(client, ESC)


def case_op_cw_ce(client):
    """cw/cW on a non-blank act as ce/cE (POSIX): change to the word
    END, not through the trailing space. Was swallowing it
    (2026-09-05, found via .-repeat)."""
    open_vi(client)
    t(client, 'iaa bb cc' + ESC)
    t(client, '1GcwXX' + ESC)
    settle(client, lambda rs: line_eq(rs, 0, 'XX bb cc'),
           "cw kept the space: XX bb cc (not XXbb cc)")
    t(client, ESC)


def case_dot_x(client):
    open_vi(client)
    t(client, 'iABCDE' + ESC)
    t(client, '0x.')
    settle(client, lambda rs: line_eq(rs, 0, 'CDE'),
           'x then . deleted two chars -> CDE')
    t(client, ESC)


def case_dot_dw(client):
    open_vi(client)
    t(client, 'ione two three x' + ESC)
    t(client, '0dw.')
    settle(client, lambda rs: line_eq(rs, 0, 'three x'),
           'dw then . deleted two words')
    t(client, ESC)


def case_dot_insert(client):
    open_vi(client)
    t(client, 'iL1\rL2' + ESC)
    t(client, '1GIXY' + ESC)
    t(client, 'j0.')
    settle(client, lambda rs: line_eq(rs, 0, 'XYL1') and line_eq(rs, 1, 'XYL2'),
           'I+ESC then j0. repeats the insert on line 2')
    t(client, ESC)


def case_dot_rZ(client):
    open_vi(client)
    t(client, 'iaaa\rbbb' + ESC)
    t(client, '1G0rZj0.')
    t(client, '1G')            # park the cursor on line 1 so line 2's
                               # first cell isn't the (glyph-folded)
                               # cursor -- r is same-length, so line_eq
                               # would otherwise tolerate 'bbb' as 'Zbb'
    settle(client, lambda rs: line_eq(rs, 0, 'Zaa') and line(rs, 1) == 'Zbb',
           'rZ then j0. repeats r on line 2 (strict on line 2)')
    t(client, ESC)


def case_dot_o(client):
    open_vi(client)
    t(client, 'ip1\rp2' + ESC)
    t(client, '1GoNEW' + ESC)
    t(client, 'j.')
    settle(client, lambda rs: line(rs, 0) == 'p1' and line_eq(rs, 1, 'NEW')
           and line(rs, 2) == 'p2' and line_eq(rs, 3, 'NEW'),
           'o+text then j. opens+types NEW below each line')
    t(client, ESC)


def case_op_p_paste(client):
    open_vi(client)
    t(client, 'iL1\rL2' + ESC)
    t(client, '1Gyyp')        # yank line 1, paste below
    settle(client, lambda rs: line(rs, 0) == 'L1' and line(rs, 1) == 'L1',
           'yy+p: duplicated line 1 below itself')
    t(client, ESC)


def _glass_put(client, keys, want, label):
    """Judge the GLASS after a linewise put/delete+put: type four
    one-word lines that differ in every cell (line_eq tolerates ONE
    cursor cell, so words must never differ by a single glyph), run
    `keys` from line 1, and require the rows to read `want` followed by
    `~` -- with NO repaint in between, so a stale or mis-placed partial
    redisplay (VI_RPINS) shows. docs/VI-GLASS-P.md: the put row used to
    paint a neighbour's text and open one row too high."""
    open_vi(client)
    t(client, 'iONE\rTWO\rTRI\rFOR' + ESC)
    t(client, '1G')
    t(client, keys)

    def ok(rs):
        return (all(line_eq(rs, i, w) for i, w in enumerate(want))
                and line(rs, len(want)) == '~')
    settle(client, ok, f'{label}: glass is {want}')


def case_put_glass_yyjp(client):
    _glass_put(client, '1Gyyjp', ['ONE', 'TWO', 'ONE', 'TRI', 'FOR'],
               '1Gyyjp')


def case_put_glass_yyGp(client):
    _glass_put(client, '1GyyGp', ['ONE', 'TWO', 'TRI', 'FOR', 'ONE'],
               '1GyyGp')


def case_put_glass_yyP(client):
    _glass_put(client, '2GyyP', ['ONE', 'TWO', 'TWO', 'TRI', 'FOR'],
               '2GyyP')


def case_put_glass_3yyp(client):
    _glass_put(client, '3yyp',
               ['ONE', 'ONE', 'TWO', 'TRI', 'TWO', 'TRI', 'FOR'], '3yyp')


def case_put_glass_ddp(client):
    _glass_put(client, '1Gddp', ['TWO', 'ONE', 'TRI', 'FOR'], '1Gddp')


def _reg_file(client, text, keys, want, label):
    """Register cases judge the BYTES (the glass of a linewise put is
    judged by the `put` cases below; the bug that once made it wrong
    is fixed, docs/VI-GLASS-P-NOTES.md): type `text`, run `keys`,
    `:wq`, `CAT` the file and compare its lines. One scratch file (VREG) for all of
    them, `RM`'d first -- the volume directory is nearly full, and a
    `dG` to empty the buffer instead leaves vi in a state that loses
    the first typed line."""
    t(client, f'RM {FIXDIR}/VREG\r')
    settle(client, _at_prompt, f'{label}: scratch file removed')
    open_vi(client, f'{FIXDIR}/VREG')
    t(client, 'i' + text + ESC)
    t(client, keys)
    t(client, ':wq\r')
    settle(client, _at_prompt, f'{label}: :wq returned to the shell')
    t(client, f'CAT {FIXDIR}/VREG\r')

    def got(rs):
        idx = [i for i, r in enumerate(rs) if 'CAT' in r and 'VREG' in r]
        if not idx:
            return None
        out = [r.rstrip() for r in rs[idx[-1] + 1:]]
        while out and not out[-1]:
            out.pop()
        if not out or out[-1] != '$':
            return None             # cat has not finished
        return out[:-1]
    settle(client, lambda rs: got(rs) == want, f'{label}: file is {want}')


def case_reg_ayy_ap(client):
    # `"ayy` fills register a; a later plain `yy` fills only the unnamed
    # one, so `"ap` must put ONE (a), not TWO (the unnamed).
    _reg_file(client, 'ONE\rTWO\rTRI\rFOR', '1G"ayyjyy"ap',
              ['ONE', 'TWO', 'ONE', 'TRI', 'FOR'], '"ayy yy "ap')


def case_reg_add_aP(client):
    # `"add` deletes into a; `"aP` puts it back above the cursor line.
    _reg_file(client, 'ONE\rTWO\rTRI\rFOR', '1G"addj"aP',
              ['TWO', 'ONE', 'TRI', 'FOR'], '"add "aP')


def case_reg_ayw(client):
    # the operator form: `"ayw` yanks the word FOO+space into a, and a
    # plain `x` afterwards fills the unnamed register, so `"aP` is a's.
    _reg_file(client, 'FOO BAR', '0"aywx"aP', ['FOO OO BAR'],
              '"ayw x "aP')


def case_reg_unsupported(client):
    # `"1` (numbered) and `"A` (append) are errors: BEL, buffer
    # untouched, no INSERT-like garble (the old `"` fell through to `a`
    # and typed the following keys into the text) -- and vi is still in
    # command mode afterwards: the `x` deletes ONE character.
    _reg_file(client, 'ABC', '0"1"Ax', ['BC'], '"1 "A then x')


def case_reg_multiline_charwise(client):
    # a charwise yank across a line boundary (a search motion) keeps ALL
    # the text and `p` splices it back with the break in the right place.
    _reg_file(client, 'AAAXDEF\rGHIYJKL', '1G0y/Y\rG$p',
              ['AAAXDEF', 'GHIYJKLAAAXDEF', 'GHI'], 'y/Y across lines + p')


# ---- undo -------------------------------------------------------------
def case_undo(client):
    open_vi(client)
    t(client, 'iHELLO' + ESC)
    t(client, 'x')            # cut a char
    t(client, 'u')            # undo it
    settle(client, lambda rs: line(rs, 0) == 'HELLO', 'u: undid the x')
    t(client, ESC)


# ---- ex bridge --------------------------------------------------------
def case_ex_pct_substitute(client):
    # `:%s/.../.../g` -- % is the whole-buffer range (1,$). Was not
    # parsed as an address until 2026-09-05, so `:%s` failed.
    open_vi(client)
    t(client, 'ifoo x foo\ry foo' + ESC)
    t(client, ':%s/foo/BAR/g\r')
    settle(client, lambda rs: line_eq(rs, 0, 'BAR x BAR')
           and line_eq(rs, 1, 'y BAR'),
           ':%s/foo/BAR/g substituted every match on every line')
    t(client, ESC)


def case_ex_substitute(client):
    open_vi(client)
    t(client, 'iOLD text' + ESC)
    t(client, ':s/OLD/NEW/\r')
    # line_eq, not == -- same cursor-glyph reason as the dw case above
    settle(client, lambda rs: line_eq(rs, 0, 'NEW text'),
           ':s substitution rewrote the line')
    t(client, ESC)


# ---- search -----------------------------------------------------------
def case_search_forward(client):
    open_vi(client)
    t(client, 'ifoo\rbar\rfoo' + ESC)
    t(client, '1G/bar\r')     # search for bar
    t(client, 'x')            # cut its first char
    settle(client, lambda rs: line_eq(rs, 1, 'ar'),
           '/bar: search moved to line 2, x cut its first char')
    t(client, ESC)


def _fill(client, n):
    """Insert n lines 'r01'..'rNN' into a fresh buffer (for paging)."""
    t(client, 'i')
    for i in range(1, n + 1):
        t(client, f'r{i:02d}' + ('\r' if i < n else ''))
    t(client, ESC)


# ---- more motions -----------------------------------------------------
def case_motion_hl(client):
    open_vi(client)
    t(client, 'iabcdef' + ESC)
    t(client, '0llrZ')        # col0, right x2 -> col2 'c', replace -> abZdef
    settle(client, lambda rs: line_eq(rs, 0, 'abZdef'),
           'l: moved right, h implicit; r marked col 2')
    t(client, 'hhrQ')         # left x2 -> col0 'a', replace -> QbZdef
    settle(client, lambda rs: line_eq(rs, 0, 'QbZdef'), 'h: moved left to col 0')
    t(client, ESC)


def case_motion_jk(client):
    open_vi(client)
    t(client, 'iL1\rL2\rL3' + ESC)
    t(client, '1GjrZ')        # line1 -> down to L2, replace L2[0] -> Z2
    settle(client, lambda rs: line_eq(rs, 1, 'Z2'), 'j: down one line')
    t(client, 'krQ')          # up to L1, replace L1[0] -> Q1
    settle(client, lambda rs: line_eq(rs, 0, 'Q1'), 'k: up one line')
    t(client, ESC)


def case_motion_b(client):
    open_vi(client)
    t(client, 'ione two' + ESC)
    t(client, '$brZ')         # $ -> last char, b -> start of 'two', replace
    settle(client, lambda rs: line_eq(rs, 0, 'one Zwo'),
           'b: back to previous word start')
    t(client, ESC)


def case_motion_e(client):
    open_vi(client)
    t(client, 'ione two' + ESC)
    t(client, '0erZ')         # e -> end of 'one' (col 2), replace
    settle(client, lambda rs: line_eq(rs, 0, 'onZ two'),
           'e: forward to word end')
    t(client, ESC)


def case_motion_caret(client):
    open_vi(client)
    t(client, 'i  ab' + ESC)   # two leading (high-bit) spaces
    t(client, '$^rZ')          # ^ -> first non-blank (col 2), replace 'a'
    settle(client, lambda rs: line_eq(rs, 0, '  Zb'),
           '^: to first non-blank column')
    t(client, ESC)


def case_motion_find_f(client):
    open_vi(client)
    t(client, 'iabcdef' + ESC)
    t(client, '0fdrZ')         # f'd' -> col 3, replace
    settle(client, lambda rs: line_eq(rs, 0, 'abcZef'), 'f: find char forward')
    t(client, ESC)


def case_motion_find_F(client):
    open_vi(client)
    t(client, 'iabcdef' + ESC)
    t(client, '$FcrZ')         # from EOL, F'c' back -> col 2, replace
    settle(client, lambda rs: line_eq(rs, 0, 'abZdef'),
           'F: find char backward')
    t(client, ESC)


def case_motion_till_t(client):
    open_vi(client)
    t(client, 'iabcdef' + ESC)
    t(client, '0tdrZ')         # t'd' stops before -> col 2, replace
    settle(client, lambda rs: line_eq(rs, 0, 'abZdef'),
           't: till char (stops before)')
    t(client, ESC)


def case_motion_semicolon(client):
    open_vi(client)
    t(client, 'iaxbxc' + ESC)
    t(client, '0fx;rZ')        # f'x' col1, ; -> next 'x' col3, replace
    settle(client, lambda rs: line_eq(rs, 0, 'axbZc'),
           '; repeat last find same direction')
    t(client, ESC)


def case_motion_comma(client):
    open_vi(client)
    t(client, 'iaxbxdx' + ESC)  # 'x' at cols 1, 3, 5
    # F'x' backward from EOL (col6) -> col5; ',' reverses to FORWARD but
    # there is no x after col5, so instead go: fx (col1), then ',' after
    # an F. Cleanest: Fx to col5 then Fx to col3, ',' reverses -> forward
    # to col5 (a REAL move, not a vacuous no-match).
    t(client, '$FxFx,rZ')       # $->5, Fx->3, Fx->1, ,->fwd->3, r
    settle(client, lambda rs: line_eq(rs, 0, 'axbZdx'),
           ', reverse find moved forward to the next match')
    t(client, ESC)


def case_motion_count(client):
    open_vi(client)
    t(client, 'iabcdef' + ESC)
    t(client, '03lrZ')         # 3l -> col 3, replace
    settle(client, lambda rs: line_eq(rs, 0, 'abcZef'),
           'count: 3l moved three columns right')
    t(client, ESC)


def case_motion_arrow_down(client):
    open_vi(client)
    t(client, 'iL1\rL2' + ESC)
    t(client, '1G' + ESC + '[BrZ')   # 1G, down-arrow (CSI B) -> line2, replace
    settle(client, lambda rs: line_eq(rs, 1, 'Z2'),
           'down-arrow maps to j')
    t(client, ESC)


# ---- paging -----------------------------------------------------------
def case_page_ctrl_f_b(client):
    open_vi(client)
    _fill(client, 28)
    t(client, '1G')
    settle(client, lambda rs: line_eq(rs, 0, 'r01'), 'paging: 1G to top')
    t(client, '\x06')          # ^F
    settle(client, lambda rs: not any(line(rs, i) == 'r01' for i in range(23)),
           '^F: page-down scrolled r01 off the top')
    t(client, '\x02')          # ^B
    settle(client, lambda rs: line_eq(rs, 0, 'r01'),
           '^B: page-up returned to the top')
    t(client, ESC)


def case_page_ctrl_d(client):
    open_vi(client)
    _fill(client, 28)
    t(client, '1G')
    settle(client, lambda rs: line_eq(rs, 0, 'r01'), 'paging: 1G to top')
    t(client, '\x04')          # ^D half page
    settle(client, lambda rs: not any(line(rs, i) == 'r01' for i in range(23)),
           '^D: half-page-down scrolled')
    t(client, ESC)


def case_page_option_u(client):
    # ^U (half-page UP) is typed OPTION+U on this keyboard -- the bare
    # ^U wire ($95) is the right-arrow and is rewritten to a CSI, so
    # Solid-Apple folds the key to a real ^U (2026-09-10). Hold the
    # button, type U, release; the window must page UP half a screen,
    # the mirror of ^D. TEETH: without the $95->VI_PAGE_U dispatch the
    # key is dropped and the top does not move.
    open_vi(client)
    _fill(client, 40)                       # r01..r40
    t(client, 'G')                          # bottom; window scrolled down
    settle(client, lambda rs: line_eq(rs, 0, 'r18'),
           'option-U: G left the last screenful (top r18)')
    client.call_tool('buttons', {'closed_apple': True})   # Solid Apple
    t(client, 'U')                          # OPTION+U -> ^U
    client.call_tool('buttons', {'closed_apple': False})
    settle(client, lambda rs: line_eq(rs, 0, 'r07'),
           'option-U: ^U paged up half a screen (top r18 -> r07)')
    t(client, ESC)


def case_scroll_partial(client):
    # `j` past the bottom row scrolls the window up one line. This is
    # the PARTIAL scroll (ESC[nS + repaint only the exposed row), not a
    # full repaint (VI-DESIGN sec 2.2, 2026-09-10). Assert the window
    # tracks line-for-line: a stale or mis-shifted partial scroll would
    # leave the wrong Lnn on the top or bottom row. TEETH: forcing
    # VI_SCROLL_DN to :full (full repaint) still passes -- this checks
    # the RESULT, which must be identical either way; the speed is what
    # differs and is measured separately.
    open_vi(client)
    _fill(client, 30)           # r01..r30
    t(client, '1G')
    settle(client, lambda rs: line_eq(rs, 0, 'r01'), 'scroll: 1G to top')
    t(client, '22j')            # cursor to the last visible row, no scroll
    settle(client, lambda rs: line_eq(rs, 0, 'r01'),
           'scroll: 22j fills the window, no scroll yet')
    t(client, 'jjj')            # three scrolling j's, one line each
    settle(client, lambda rs: line(rs, 0) == 'r04' and line_eq(rs, 22, 'r26'),
           'partial scroll: top=r04, bottom=r26, consecutive after 3 j')
    t(client, ESC)


def case_scroll_partial_up(client):
    # `k` past the top row scrolls the window DOWN one line -- the
    # reverse partial scroll (ESC[nT + repaint only the new top row),
    # mirror of case_scroll_partial. Same result-not-speed check.
    open_vi(client)
    _fill(client, 30)           # r01..r30
    t(client, '1G')
    settle(client, lambda rs: line_eq(rs, 0, 'r01'), 'scroll-up: 1G to top')
    t(client, '25j')            # scroll forward (j path) to top r04,
                                # cursor r26 on the bottom row (line_eq:
                                # the cursor cell carries a glyph)
    settle(client, lambda rs: line(rs, 0) == 'r04' and line_eq(rs, 22, 'r26'),
           'scroll-up: 25j leaves top r04, r26 on the bottom row')
    t(client, '22k')            # up to the top VISIBLE row (no scroll)
    settle(client, lambda rs: line_eq(rs, 0, 'r04'),
           'scroll-up: 22k to the top visible row, no scroll yet')
    t(client, 'kkk')            # three scrolling k's, one line each
    settle(client, lambda rs: line_eq(rs, 0, 'r01') and line_eq(rs, 22, 'r23'),
           'partial scroll-up: top=r01, bottom=r23, consecutive after 3 k')
    t(client, ESC)


def case_ildl_o_midscreen(client):
    # `o` in the MIDDLE of a FULL window: the IL path (ESC[1L + paint
    # the one new line) must push every line below down exactly one row
    # -- a full window is where a mis-shift shows (the small-buffer o
    # case has nothing below to corrupt). TEETH: the stale-Z flood bug
    # (the ldx-set-the-flag regression) painted the whole window with
    # '~' here; a mis-count leaves a duplicated or dropped rNN row.
    open_vi(client)
    _fill(client, 30)           # r01..r30, window full (r01..r23 shown)
    t(client, '1G')
    settle(client, lambda rs: line_eq(rs, 0, 'r01'), 'ildl-o: 1G to top')
    t(client, '10G')            # cursor on r11 (row 11, index 10)
    settle(client, lambda rs: line_eq(rs, 10, 'r11'), 'ildl-o: on r11')
    t(client, 'oNEW')           # open below r11, type NEW
    settle(client, lambda rs: line(rs, 10) == 'r11' and line_eq(rs, 11, 'NEW')
           and line(rs, 12) == 'r12' and line(rs, 13) == 'r13',
           'ildl-o: NEW opened below r11, r12/r13 shifted down one')
    t(client, ESC)


def case_ildl_dd_midscreen(client):
    # `dd` in the MIDDLE of a FULL window: the DL path (ESC[mM + pull
    # the lines below up) must pull every lower line up one AND scroll
    # the next line in at the bottom. TEETH: a wrong delete-row count
    # over-pulls (blank gap) or leaves a stale duplicate row.
    open_vi(client)
    _fill(client, 30)
    t(client, '1G')
    settle(client, lambda rs: line_eq(rs, 0, 'r01'), 'ildl-dd: 1G to top')
    t(client, '10G')
    settle(client, lambda rs: line_eq(rs, 10, 'r11'), 'ildl-dd: on r11')
    t(client, 'dd')            # delete r11
    settle(client, lambda rs: line(rs, 9) == 'r10' and line_eq(rs, 10, 'r12')
           and line(rs, 11) == 'r13' and line(rs, 22) == 'r24',
           'ildl-dd: r11 gone, r12.. pulled up, r24 scrolled in at bottom')
    t(client, ESC)


# ---- change operators (enter insert) ----------------------------------
def case_op_cc(client):
    open_vi(client)
    t(client, 'iOLD line' + ESC)
    t(client, 'ccNEW' + ESC)   # change whole line
    settle(client, lambda rs: line_eq(rs, 0, 'NEW'),
           'cc: changed the whole line')


def case_op_C(client):
    open_vi(client)
    t(client, 'iHELLO WORLD' + ESC)
    t(client, '0llCxx' + ESC)  # col 2, C = change to EOL -> HExx
    settle(client, lambda rs: line_eq(rs, 0, 'HExx'),
           'C: changed from cursor to EOL')


def case_op_ce(client):
    open_vi(client)
    t(client, 'ione two' + ESC)
    t(client, '0ceNEW' + ESC)  # change to word end -> NEW two
    settle(client, lambda rs: line_eq(rs, 0, 'NEW two'),
           'ce: change to word end')


def case_op_s(client):
    open_vi(client)
    t(client, 'iABC' + ESC)
    t(client, '0sZ' + ESC)     # substitute char -> ZBC
    settle(client, lambda rs: line_eq(rs, 0, 'ZBC'),
           's: substituted the char under the cursor')


# ---- more operators ---------------------------------------------------
def case_op_Y_P(client):
    open_vi(client)
    t(client, 'iL1\rL2' + ESC)
    t(client, '1GYP')          # yank line 1, put ABOVE -> L1,L1,L2
    settle(client, lambda rs: line_eq(rs, 0, 'L1') and line_eq(rs, 1, 'L1')
           and line_eq(rs, 2, 'L2'), 'Y+P: yanked a line, put it above')
    t(client, ESC)


def case_op_tilde(client):
    open_vi(client)
    t(client, 'iabc' + ESC)
    t(client, '0~~~')          # toggle case of three chars -> ABC
    settle(client, lambda rs: line_eq(rs, 0, 'ABC'),
           '~: toggled case forward, advancing')
    t(client, ESC)


def case_op_dd_count(client):
    open_vi(client)
    t(client, 'iL1\rL2\rL3\rL4' + ESC)
    t(client, '1G2dd')         # delete two lines -> L3, L4
    settle(client, lambda rs: line_eq(rs, 0, 'L3') and line_eq(rs, 1, 'L4'),
           '2dd: deleted two whole lines')
    t(client, ESC)


def case_op_d2w(client):
    open_vi(client)
    t(client, 'ione two three' + ESC)
    t(client, '0d2w')          # delete two words -> three
    settle(client, lambda rs: line_eq(rs, 0, 'three'),
           'd2w: deleted two words')
    t(client, ESC)


def case_op_dG(client):
    open_vi(client)
    t(client, 'iL1\rL2\rL3' + ESC)
    t(client, '2GdG')          # delete from line 2 to EOF -> just L1
    settle(client, lambda rs: line_eq(rs, 0, 'L1')
           and rs[1].strip() in ('~', ''), 'dG: deleted to end of file')
    t(client, ESC)


# ---- search (backward / repeat) ---------------------------------------
def case_search_backward(client):
    open_vi(client)
    t(client, 'ifoo\rbar\rbaz' + ESC)
    t(client, 'G?bar\rrZ')     # from last line, ?bar back -> line 2, replace
    settle(client, lambda rs: line_eq(rs, 1, 'Zar'),
           '?: backward search reached bar')
    t(client, ESC)


def case_search_n_N(client):
    open_vi(client)
    t(client, 'ix\rx\rx' + ESC)
    t(client, '1G/x\rn')       # /x from line1 -> line2, n -> line3
    t(client, 'rZ')
    settle(client, lambda rs: line_eq(rs, 2, 'Z'),
           'n: repeat search advanced to the next match')
    t(client, 'N')             # N reverses -> back to line 2
    t(client, 'rQ')
    settle(client, lambda rs: line_eq(rs, 1, 'Q'),
           'N: repeat search reversed to the previous match')
    t(client, ESC)


# ---- ex bridge --------------------------------------------------------
def case_ex_delete(client):
    open_vi(client)
    t(client, 'iL1\rL2\rL3' + ESC)
    t(client, ':2d\r')         # delete line 2 -> L1, L3
    settle(client, lambda rs: line_eq(rs, 0, 'L1') and line_eq(rs, 1, 'L3'),
           ':2d deleted line 2 through the ex bridge')
    t(client, ESC)


def case_ex_global_delete(client):
    open_vi(client)
    t(client, 'ikeep\rDROP\rkeep' + ESC)
    t(client, ':g/DROP/d\r')   # delete matching lines -> keep, keep
    settle(client, lambda rs: line_eq(rs, 0, 'keep') and line_eq(rs, 1, 'keep')
           and rs[2].strip() in ('~', ''),
           ':g/DROP/d deleted the matching line')
    t(client, ESC)


def case_ex_move(client):
    open_vi(client)
    t(client, 'iA\rB\rC' + ESC)
    t(client, ':1m$\r')        # move line 1 after last -> B, C, A
    settle(client, lambda rs: line_eq(rs, 0, 'B') and line_eq(rs, 1, 'C')
           and line_eq(rs, 2, 'A'), ':1m$ moved line 1 to the end')
    t(client, ESC)


def case_ex_number(client):
    # This verifies `:nu` PRINTS a numbered line, which it does. It does
    # NOT assert vi is usable afterwards: `:nu` (like `:p`/`:=`, the ex
    # line-PRINT commands) writes to the glass and its trailing CR
    # scrolls the console, wedging vi's screen model until it stops
    # taking input -- a real, pre-existing maux bug (it wedges from a
    # fresh boot at any revision; the full suite only survived it by
    # accumulated-state luck). recover()'s hard-reboot fallback keeps
    # that wedge from cascading into the cases after this one. Tracked
    # separately; not a wrap regression.
    open_vi(client)
    t(client, 'ihello' + ESC)
    t(client, ':nu\r')         # numbered print (ex rt-just format
                               # since 2026-09-06): "      1 hello"
    settle(client, lambda rs: any('hello' in r and '1' in r for r in rs),
           ':nu printed the numbered line')


def _status(rs):
    """The status row's text (the bottom line of the glass)."""
    return rs[-1].rstrip() if rs else ''


def case_ex_unknown_word(client):
    # docs/EX-BADCMD.md: `:cxyz` used to run CHANGE (first letter wins),
    # sit in line-input mode with no message, and swallow the next
    # lines typed. Now the word is refused, the message is on the
    # status row, the buffer is untouched, and vi is still in COMMAND
    # mode -- `dd` proves it by deleting the last line, and `:dxyz`
    # (which deleted a line) is refused the same way.
    open_vi(client)
    t(client, 'iL1\rL2\rL3' + ESC)
    t(client, ':cxyz\r')
    settle(client, lambda rs: 'cxyz: Not an editor command' in _status(rs),
           ':cxyz refused with a message on the status row')
    t(client, ':dxyz\r')
    settle(client, lambda rs: 'dxyz: Not an editor command' in _status(rs),
           ':dxyz refused with a message on the status row')
    rs = rows(client)
    assert line_eq(rs, 0, 'L1') and line_eq(rs, 1, 'L2') \
        and line_eq(rs, 2, 'L3'), 'a refused word changed the buffer'
    t(client, 'dd')
    settle(client, lambda rs: line_eq(rs, 0, 'L1') and line_eq(rs, 1, 'L2')
           and rs[2].strip() in ('~', ''),
           'vi stayed in command mode after the refusal (dd deleted L3)')


def case_ex_trailing(client):
    # A verb that takes no operand refuses one: `:2d3` used to delete
    # line 2 and ignore the 3.
    open_vi(client)
    t(client, 'iL1\rL2\rL3' + ESC)
    t(client, ':2d3\r')
    settle(client, lambda rs: 'Trailing characters' in _status(rs),
           ':2d3 refused: Trailing characters')
    rs = rows(client)
    assert line_eq(rs, 0, 'L1') and line_eq(rs, 1, 'L2') \
        and line_eq(rs, 2, 'L3'), ':2d3 changed the buffer'
    t(client, ESC)


def case_ex_fail_says_so(client):
    # Every ex-line failure is reported, not only the new ones: a bare
    # `:w` with no remembered filename failed in silence (ED_ERR's `?`
    # printed, then the repaint wiped it).
    open_vi(client)
    t(client, 'ihello' + ESC)
    t(client, ':w\r')
    settle(client, lambda rs: 'Command failed' in _status(rs),
           'a failing bare :w said nothing')
    t(client, ESC)


def case_ex_long_names(client):
    # The POSIX spellings reach the same verbs: `:2delete` and `:1,2d`
    # in one session, `:ma a` / `:'ad` through the mark rewrite.
    open_vi(client)
    t(client, 'iL1\rL2\rL3\rL4' + ESC)
    t(client, ':2delete\r')
    settle(client, lambda rs: line_eq(rs, 1, 'L3'), ':2delete ran as :2d')
    t(client, ':2ma a\r')
    t(client, ':1d\r')
    t(client, ":'ad\r")
    settle(client, lambda rs: line_eq(rs, 0, 'L4')
           and rs[1].strip() in ('~', ''),
           ':ma a then :\'ad deleted the marked line')
    t(client, ESC)


# ---- file round-trips (copy-on-write; nothing hits build/play.po) -----
# Fixtures live in the DEMO SUBDIRECTORY, not the volume root. The root
# is the SHIPPING play.po floppy's own directory, which a ProDOS volume
# caps at 51 entries -- and the util roster alone is 47 of them. Four
# root fixtures (VWQ/VZZ/VEDIT/VDISC) plus vi's transient swap file used
# to just fit; adding ONE utility to the roster (`reset`, 2026-09-07)
# tipped `:q! discards edits` -- its `:wq` hit a full root directory and
# hung. A subdirectory has no such cap and grows as needed, the same
# reason build_play_image.py keeps its own sample data under DEMO. (The
# writes are on the copy-on-write overlay; the shipping DEMO is never
# touched.)
FIXDIR = 'DEMO'


def case_file_wq_roundtrip(client):
    open_vi(client, f'{FIXDIR}/VWQ')
    t(client, 'iWROTE' + ESC)
    t(client, ':wq\r')
    settle(client, _at_prompt, ':wq wrote and returned to the shell')
    t(client, f'CAT {FIXDIR}/VWQ\r')
    settle(client, lambda rs: any('WROTE' in r for r in rs),
           ':wq round-trip: CAT VWQ shows WROTE')


def case_file_ZZ_roundtrip(client):
    open_vi(client, f'{FIXDIR}/VZZ')
    t(client, 'iSAVED' + ESC)
    t(client, 'ZZ')
    settle(client, _at_prompt, 'ZZ wrote and returned to the shell')
    t(client, f'CAT {FIXDIR}/VZZ\r')
    settle(client, lambda rs: any('SAVED' in r for r in rs),
           'ZZ round-trip: CAT VZZ shows SAVED')


def case_file_edit_existing(client):
    # self-contained: create VEDIT, then reopen it and confirm the
    # lines reload (exercises open-of-existing without depending on a
    # staged fixture that other gates mutate).
    open_vi(client, f'{FIXDIR}/VEDIT')
    t(client, 'iLINEA\rLINEB\rLINEC' + ESC)
    t(client, ':wq\r')
    settle(client, _at_prompt, 'VEDIT written')
    open_vi(client, f'{FIXDIR}/VEDIT')
    settle(client, lambda rs: line(rs, 0) == 'LINEA'
           and line(rs, 1) == 'LINEB' and line(rs, 2) == 'LINEC',
           'edit existing: VEDIT reloaded all three lines')
    t(client, ESC)


def case_quit_bang_discards(client):
    open_vi(client, f'{FIXDIR}/VDISC')
    t(client, 'iKEEPA\rKEEPB' + ESC)
    t(client, ':wq\r')
    settle(client, _at_prompt, 'VDISC written')
    open_vi(client, f'{FIXDIR}/VDISC')
    settle(client, lambda rs: line(rs, 0) == 'KEEPA', 'VDISC reopened')
    t(client, '1Gdd')          # delete KEEPA (dirty)
    t(client, ':q!\r')         # discard and quit
    settle(client, _at_prompt, ':q! discarded the edit and quit')
    open_vi(client, f'{FIXDIR}/VDISC')  # reopen: delete must NOT stick
    settle(client, lambda rs: line(rs, 0) == 'KEEPA'
           and line(rs, 1) == 'KEEPB',
           ':q! really discarded -- VDISC unchanged on reopen')
    t(client, ESC)


# ---- repaint-cache coverage (vicache.s, in progress by another stream) -
# vi's full repaint is about to gain a RAM line cache keyed by each
# visible line's swap-file descriptor {offset,length} (the swap file is
# append-only, so the key self-invalidates on rewrite and survives
# renumbering -- `o`, `dd`, `u`). These cases are all GREEN against
# TODAY's code (no cache exists yet); each is written so that a
# plausible cache bug -- stale text, a row-keyed (not descriptor-keyed)
# slot, or a clipped/truncated copy -- would flip its assertion. Every
# case forces at least one full repaint SEPARATELY from whatever
# populated the buffer, via one of: `o`+ESC (VI_INS_BODY's structural
# entry repaint, viinsert.s:186-205), ^F/^B paging (vimotion.s), dd's
# own repaint (viop.s), or the `:` ex bridge (VI_COLON always calls
# VI_REPAINT on return, vicmd.s :vc_ret -- verified empirically:
# `_redraw` below leaves an untouched buffer's on-screen picture
# byte-identical before and after).
def _redraw(client):
    """Force a SECOND, content-preserving full repaint via the `:` ex
    bridge. `:1` addresses line 1 without editing anything; VI_COLON
    (vicmd.s) unconditionally calls VI_REPAINT when the bridge returns,
    regardless of what the dispatched ex command did. Empirically
    verified (2026-09-05): repainting an unedited buffer through this
    path reproduces the prior repaint's screen byte-for-byte, so any
    difference the cases below observe comes from the CACHE, not from
    `:1` itself."""
    t(client, ':1\r')


def case_vicache_stale_after_edit(client):
    """Cache bug this catches: a cache keyed by physical ROW/line
    NUMBER instead of the line's swap {offset,length} descriptor, or
    one that is never invalidated on a rewrite. Rewrite an EARLIER row
    (line 1) after the buffer's first full repaint, force a SEPARATE,
    LATER full repaint via a different call site (`o`+ESC's structural
    entry repaint, viinsert.s:186-205), and require the edited text.
    The swap file is append-only, so rewriting line 1 gives it a NEW
    descriptor; a correct cache keyed on that descriptor self-
    invalidates, but a row-keyed cache would still hold "AAA" under
    "row 1"."""
    open_vi(client)
    t(client, 'iAAA\rBBB\rCCC' + ESC)      # full repaint #1 (multi-line insert)
    settle(client, lambda rs: line(rs, 0) == 'AAA' and line(rs, 1) == 'BBB'
           and line(rs, 2) == 'CCC', 'setup AAA/BBB/CCC')
    t(client, '1GrZ')                       # rewrite the EARLIER row (line 1)
    settle(client, lambda rs: line_eq(rs, 0, 'ZAA'), 'line 1 rewritten to ZAA')
    t(client, 'Go' + ESC)                   # G: last line; o+ESC: full repaint #2
    settle(client, lambda rs: line_eq(rs, 0, 'ZAA') and line(rs, 1) == 'BBB'
           and line(rs, 2) == 'CCC',
           'stale-after-edit: the LATER, separate repaint shows the EDITED '
           'line 1, not the pre-edit AAA')
    t(client, ESC)


def case_vicache_undo_repaint(client):
    """Cache bug this catches: a cache that keeps the POST-edit text (or
    isn't invalidated by `u`) under the line's slot. Undo restores the
    line's ORIGINAL swap descriptor (append-only: undo repoints to the
    earlier record, it does not erase the newer one); a full repaint
    forced SEPARATELY from the undo itself must still show the original
    text."""
    open_vi(client)
    t(client, 'iHELLO' + ESC)
    settle(client, lambda rs: line(rs, 0) == 'HELLO', 'setup HELLO')
    t(client, 'x')              # ESC left the cursor on the LAST typed char
                                # ('O'), so x cuts that -> HELL
    settle(client, lambda rs: line(rs, 0) == 'HELL', 'x cut the last char')
    t(client, 'u')              # undo -> HELLO
    settle(client, lambda rs: line(rs, 0) == 'HELLO', 'u undid the x')
    _redraw(client)             # a SEPARATE, LATER full repaint
    settle(client, lambda rs: line(rs, 0) == 'HELLO',
           'undo-then-repaint: the forced repaint still shows the ORIGINAL '
           'text, not the undone edit')
    t(client, ESC)


def case_vicache_shift_dd(client):
    """Cache bug this catches: a cache keyed by physical ROW rather than
    by each line's own descriptor. Deleting a MIDDLE line shifts every
    line below it up one row; a full repaint forced SEPARATELY from
    dd's own repaint must still show every row's CORRECT (post-shift)
    line -- a row-keyed cache would show the PRE-shift line at every
    row below the deletion."""
    open_vi(client)
    t(client, 'iL1\rL2\rL3\rL4\rL5' + ESC)
    settle(client, lambda rs: line(rs, 0) == 'L1' and line(rs, 4) == 'L5',
           'setup L1..L5')
    t(client, '3Gdd')           # delete the MIDDLE line, L3 -> L1,L2,L4,L5
    settle(client, lambda rs: line(rs, 0) == 'L1' and line(rs, 1) == 'L2'
           and line_eq(rs, 2, 'L4') and line(rs, 3) == 'L5',
           "dd shifted L4/L5 up one row (dd's own repaint)")
    _redraw(client)              # a SEPARATE, LATER full repaint
    settle(client, lambda rs: line(rs, 0) == 'L1' and line(rs, 1) == 'L2'
           and line(rs, 2) == 'L4' and line(rs, 3) == 'L5'
           and rs[4].strip() in ('~', ''),
           'shift correctness: the forced repaint still shows every '
           'remaining line in its correct, post-shift row')
    t(client, ESC)


def case_vicache_paging_thrash(client):
    """Cache bug this catches: a cache smaller than the visible window,
    or a bad victim/eviction policy, that leaves stale lines from the
    PREVIOUS page's window on screen after paging. DEMO/LONG has 60
    lines (L01..L60, scripts/build_play_image.py), longer than one
    window; page down twice then up twice with ^F/^B and require BOTH
    row 0 and a mid row to read the correct L-number after landing back
    at the top. Opened WITHOUT open_vi()'s helper: DEMO/LONG's first
    page is exactly full (23 real lines, no past-EOF `~`), and
    open_vi()'s _in_vi() detects "in vi" by that `~` marker -- it would
    time out on a screen with none, so this checks the real content
    (L01 at the top) directly instead."""
    t(client, 'VI DEMO/LONG\r')
    settle(client, lambda rs: line_eq(rs, 0, 'L01'),
           'vi opened DEMO/LONG at the top, L01')
    t(client, '\x06')           # ^F page down
    settle(client, lambda rs: not any(line(rs, i) == 'L01' for i in range(23)),
           '^F: L01 scrolled off the top')
    row0_after_f1 = line(rows(client), 0)
    t(client, '\x06')           # ^F again -- a SECOND page down
    settle(client, lambda rs: line(rs, 0) != row0_after_f1,
           '^F again: the window advanced further')
    t(client, '\x02')           # ^B page up
    t(client, '\x02')           # ^B again -- back to the top
    settle(client, lambda rs: line_eq(rs, 0, 'L01') and line(rs, 11) == 'L12',
           'paging thrash: back at the top, row 0 = L01 AND the mid row '
           '(row 11) = L12')
    t(client, ESC)


def case_vicache_aligned_fixtures(client):
    """learning:01M14B7RFG1024FPA330Z9ZNM2 -- windowed/buffered code
    needs an ALIGNED fixture. DEMO/VILEN (scripts/build_play_image.py)
    stages lines of exactly 0, 80 (=VI_COLS on this rig), 81 and 254
    bytes, each ending in a distinctive digit. Staged as a FILE, not
    typed (vi's insert accumulator VI_LBUFLEN is 250).

    WRAP (viscreen.s, 2026-09-05; VI-DESIGN sec 2.3 "vi wraps, it does
    not truncate" is now true): a line takes ceil(width/80) rows, so
    the 80-char line is one full row, the 81-char line is a full row
    plus its "2" alone on the next, and the 254-char line is three
    full rows plus a short one. KNOWN GAP, deliberately not asserted:
    the load path caps a line at 249 bytes (the 254-byte fixture reads
    back as 249 via :w -- found 2026-09-05, edfile.s), so the short
    fourth row holds 9 C's today and 13 C's + "3" once that is fixed;
    the assertion is startswith(9 C's) and the row after it must be
    the first `~`. Cold vs warm repaint must be byte-identical (the
    line cache reconstructs every row the same way both times)."""
    open_vi(client, 'DEMO/VILEN')
    rsA = settle(client, lambda rs: line(rs, 1) == 'A' * 79 + '1',
                 'cold repaint (DEMO/VILEN) settled')
    want = ['', 'A' * 79 + '1', 'B' * 80, '2', 'C' * 80, 'C' * 80, 'C' * 80]
    for i, w in enumerate(want):
        if line(rsA, i) != w:
            raise AssertionError(
                f'wrap rows: row {i} should be {w!r}, got {line(rsA, i)!r}')
    if not line(rsA, 7).startswith('C' * 9):
        raise AssertionError(
            f"wrap rows: the 254-char line's 4th row should start with "
            f"9 C's, got {line(rsA, 7)!r}")
    if line(rsA, 8) != '~':
        raise AssertionError(
            f'wrap rows: row 8 must be the first past-EOF ~, got '
            f'{line(rsA, 8)!r}')
    _redraw(client)              # a SEPARATE, WARM full repaint
    # Wait for the FULL repaint sweep, not just row 1: `_redraw` typed
    # `:1` on the command line, so the last text row (22) transiently
    # holds that echo until VI_REPAINT sweeps down and restores its `~`.
    # Settling on row 1 alone can capture that mid-sweep frame (the
    # exact moment is timing-sensitive, so it surfaces only under some
    # code layouts). Require row 22 back to `~` so the captured frame is
    # the settled one; if the echo genuinely never cleared this would
    # time out and fail, which is the point.
    rsB = settle(client, lambda rs: line(rs, 1) == 'A' * 79 + '1'
                 and line(rs, 22) == '~',
                 'warm repaint (DEMO/VILEN) settled')
    if rsA[:-1] != rsB[:-1]:      # text rows only; the status row is the
                                 # on-open banner cold, blank warm now
        diffs = [i for i, (a, b) in enumerate(zip(rsA[:-1], rsB[:-1])) if a != b]
        raise AssertionError(
            f'aligned fixture: cold vs. warm repaint DIFFERS at rows '
            f'{diffs} -- cold={rsA!r} warm={rsB!r}')


# ---- line WRAP (viscreen.s VI_REPAINT/VI_PLACE_CUR/VI_RPT_LN,
# viinsert.s VI_INS_TAIL/VI_INS_SYNC, 2026-09-05). Operator: "fix the
# wrap past column 80 too". Each case is judged on ROW CONTENT and,
# where the cursor matters, by an edit whose effect only lands right
# if the cursor's row/col math is right.
def case_wrap_cursor_end(client):
    """`$` on a wrapped line puts the cursor at the end of its LAST
    screen row; `x` there removes the line's last char and the
    one-line repaint keeps the rows (same row count)."""
    open_vi(client, 'DEMO/VILEN')
    settle(client, lambda rs: line(rs, 4) == 'C' * 80, 'VILEN painted')
    t(client, 'G$x')
    settle(client, lambda rs: line_eq(rs, 7, 'C' * 8) and line(rs, 6) == 'C' * 80
           and line(rs, 8) == '~',
           "G$x on the 254-char line removed its LAST char (4th row 9->8 C's)")
    t(client, ESC)


def case_wrap_insert_live(client):
    """Typing past column 80 flows onto the line's next row LIVE and
    pushes the line below down (VI_INS_SYNC's mid-insert repaint);
    ESC lands on the last typed char there."""
    open_vi(client)
    t(client, 'i' + 'x' * 79 + '\rsecond' + ESC)
    t(client, '1G$aabc')                     # no ESC yet
    settle(client, lambda rs: line(rs, 0) == 'x' * 79 + 'a'
           and line_eq(rs, 1, 'bc') and line(rs, 2) == 'second',
           "typing past col 80: 'a' fills row 0, 'bc' on row 1, 'second' "
           "pushed to row 2 -- while still in insert")
    t(client, ESC)
    t(client, 'x')
    settle(client, lambda rs: line_eq(rs, 1, 'b') and line(rs, 2) == 'second',
           'ESC landed on the c (row 1): x removed it')
    t(client, ESC)


def case_wrap_o_long(client):
    """`o` then 90 chars: the new line wraps as it is typed (its row
    count grows mid-insert), the line below moves down."""
    open_vi(client)
    t(client, 'ifirst\rlast' + ESC)
    t(client, '1Go' + 'y' * 45)
    t(client, 'y' * 45)                      # 90 total, no ESC yet
    settle(client, lambda rs: line(rs, 0) == 'first' and line(rs, 1) == 'y' * 80
           and line_eq(rs, 2, 'y' * 10) and line(rs, 3) == 'last',
           "o + 90 chars wraps live: 80 y's, then 10, then 'last'")
    t(client, ESC)
    settle(client, lambda rs: line_eq(rs, 2, 'y' * 10) and line(rs, 3) == 'last',
           'after ESC the wrapped new line and the pushed line stay')
    t(client, ESC)


def case_wrap_cr_split(client):
    """Enter inside insert, mid-line: the suffix moves to the new line
    at once and the lines below shift NOW (not at ESC)."""
    open_vi(client)
    t(client, 'ihello world\rtail' + ESC)
    t(client, '1G0wiAB')                      # no ESC yet; Enter goes
    t(client, '\r')                           # alone -- it repaints, and
    t(client, 'CD')                           # keys bursted behind a
                                              # repaint get dropped
    settle(client, lambda rs: line(rs, 0) == 'hello AB' and line_eq(rs, 1, 'CDworld')
           and line(rs, 2) == 'tail',
           "Enter mid-line: 'hello AB' / 'CDworld' / 'tail' while typing")
    t(client, ESC)
    settle(client, lambda rs: line_eq(rs, 1, 'CDworld') and line(rs, 2) == 'tail',
           'and after ESC')
    t(client, ESC)


def case_wrap_jk(client):
    """j/k treat a wrapped line as ONE line; `$` on it reaches the end
    of its second row; edits at each stop land where the cursor
    shows (VI_PLACE_CUR's row math over VI_LNROWS)."""
    open_vi(client)
    t(client, 'ione\r'); t(client, 'z' * 50); t(client, 'z' * 50)
    t(client, '\rthree' + ESC)
    t(client, '1G')
    settle(client, lambda rs: line_eq(rs, 0, 'one') and line(rs, 1) == 'z' * 80
           and line(rs, 2) == 'z' * 20 and line(rs, 3) == 'three',
           'setup: one / 100 z (2 rows) / three')
    t(client, 'j$x')                          # end of the z line
    settle(client, lambda rs: line(rs, 1) == 'z' * 80 and line_eq(rs, 2, 'z' * 19)
           and line(rs, 3) == 'three',
           'j$x: removed the last z on the 2nd row (row 2 now 19 z)')
    t(client, 'jx')                           # down ONE line, to three
    settle(client, lambda rs: line_eq(rs, 3, 'thre'),
           "jx: j from the wrapped line lands on 'three' (not its 2nd row)")
    t(client, 'k0x')                          # back up, first z
    settle(client, lambda rs: line_eq(rs, 1, 'z' * 80) and line(rs, 2) == 'z' * 18,
           'k0x: k returns to the wrapped line, 0 its first col -- the '
           'line is 98 z now: a full row plus 18')
    t(client, ESC)


def case_vicache_empty_lines(client):
    """Cache bug this catches: a cache that conflates several blank
    lines (which may legitimately share ONE descriptor -- same offset,
    zero length, regardless of which buffer line they are) by VALUE
    rather than by each row's own key, bleeding one blank line's
    position into another's, or showing a REAL line as blank. Blank/
    AAA/blank/BBB/blank/CCC, checked after the insert's own full
    repaint AND after a SEPARATE, forced one."""
    open_vi(client)
    t(client, 'i\rAAA\r\rBBB\r\rCCC' + ESC)
    rs = settle(client, lambda rs: line(rs, 1) == 'AAA' and line(rs, 3) == 'BBB'
                and line(rs, 5) == 'CCC',
                'setup: blank/AAA/blank/BBB/blank/CCC')
    for i in (0, 2, 4):
        if line(rs, i) != '':
            raise AssertionError(
                f'empty lines: row {i} should be blank, got {line(rs, i)!r}')
    _redraw(client)               # a SEPARATE, LATER full repaint
    rs = settle(client, lambda rs: line(rs, 1) == 'AAA' and line(rs, 3) == 'BBB'
                and line(rs, 5) == 'CCC',
                'empty lines: forced repaint still shows AAA/BBB/CCC')
    for i in (0, 2, 4):
        if line(rs, i) != '':
            raise AssertionError(
                f'empty lines (forced repaint): row {i} should be blank, '
                f'got {line(rs, i)!r}')
    t(client, ESC)


def case_vicache_cursor_col_grow(client):
    """Cache bug this catches: VI_PLACE_CUR (viscreen.s ~157) fetches
    the CURRENT line on every cursor placement -- after each repaint
    AND each motion -- to compute the on-screen column. A cache that
    feeds it a STALE (pre-edit) copy of a GROWN line produces a WRONG
    cursor column with otherwise-correct-looking text: `$` lands on the
    OLD (shorter) end, so `x` cuts the wrong character. Sequence: seed
    a middle line, `o`+ESC elsewhere to force a full repaint that
    (re-)caches it, move ONTO it (`j`), GROW it with `A` (a same-line
    edit that does NOT force a full repaint -- viinsert.s:362-366 takes
    the 2-row path, so any full-repaint cache is NOT updated here), move
    OFF and back ON (`k`/`j`, re-triggering VI_PLACE_CUR), then `$x` --
    the deleted character must be the TRUE new last character."""
    open_vi(client)
    t(client, 'iL1\rMIDROW\rL3' + ESC)
    settle(client, lambda rs: line(rs, 0) == 'L1' and line(rs, 1) == 'MIDROW'
           and line(rs, 2) == 'L3', 'setup L1/MIDROW/L3')
    t(client, '1Go' + ESC)      # 1G: top; o+ESC: structural full repaint,
                                # (re-)caching MIDROW at its new (shifted) row
    settle(client, lambda rs: line(rs, 0) == 'L1' and rs[1].strip() == ''
           and line(rs, 2) == 'MIDROW', 'o opened a blank line above MIDROW')
    t(client, 'j')               # onto MIDROW -- VI_PLACE_CUR fires
    t(client, 'A1234' + ESC)     # GROW: MIDROW -> MIDROW1234 (same-line edit)
    settle(client, lambda rs: line_eq(rs, 2, 'MIDROW1234'),
           'A: MIDROW grown to MIDROW1234')
    t(client, 'k')               # move OFF MIDROW
    t(client, 'j')               # move back ON -- VI_PLACE_CUR fires again
    t(client, '$x')              # end-of-line, delete the TRUE last char
    settle(client, lambda rs: line(rs, 2) == 'MIDROW123',
           'cursor-col (grow): $x cut the TRUE new last char (4), leaving '
           'MIDROW123 -- a stale-cache column would cut the wrong char')
    t(client, ESC)


def case_vicache_cursor_col_shrink(client):
    """Same mechanism as case_vicache_cursor_col_grow, reverse direction
    (SHRUNK line): a stale cache would still show the line's OLD
    (longer) end column, so `$x` would cut a character past the line's
    true new end (real vi clamps `$` to the true last char when it
    exists at all, so a stale-length column here is the sharper failure
    mode -- it can point at a position the CURRENT text doesn't have)."""
    open_vi(client)
    t(client, 'iL1\rMIDROW2\rL3' + ESC)
    settle(client, lambda rs: line(rs, 0) == 'L1' and line(rs, 1) == 'MIDROW2'
           and line(rs, 2) == 'L3', 'setup L1/MIDROW2/L3')
    t(client, '1Go' + ESC)       # structural full repaint, (re-)caches MIDROW2
    settle(client, lambda rs: line(rs, 0) == 'L1' and rs[1].strip() == ''
           and line(rs, 2) == 'MIDROW2', 'o opened a blank line above MIDROW2')
    t(client, 'j')                # onto MIDROW2 -- VI_PLACE_CUR fires
    t(client, '$x')               # SHRINK: cut the true last char '2' -> MIDROW
    settle(client, lambda rs: line_eq(rs, 2, 'MIDROW'),
           "x: MIDROW2 shrunk to MIDROW")
    t(client, 'k')                # move OFF MIDROW
    t(client, 'j')                # move back ON -- VI_PLACE_CUR fires again
    t(client, '$x')               # end-of-line, delete the TRUE last char
    settle(client, lambda rs: line(rs, 2) == 'MIDRO',
           'cursor-col (shrink): $x cut the TRUE new last char (W), leaving '
           'MIDRO -- a stale-cache column would try to cut a character the '
           'shrunk line no longer has')
    t(client, ESC)


# --------------------------------------------------------------------
# registry -- (category, name, fn). Expand toward TOTAL coverage.
# --------------------------------------------------------------------
CASES = [
    # insert entry + live echo
    ('insert', 'i inserts at cursor', case_insert_i),
    ('insert', 'A appends at EOL (live)', case_insert_A_appends_at_eol),
    ('insert', 'a appends after cursor (live)', case_insert_a_after_cursor),
    ('insert', 'I inserts at first non-blank', case_insert_I_first_nonblank),
    ('insert', 'o opens below (no stray ~)', case_insert_o_below),
    ('insert', 'O opens above', case_insert_O_above),
    ('insert', 'CR splits the line', case_insert_cr_splits),
    ('insert', 'left-arrow erases in insert', case_ins_erase_left),
    ('insert', 'DEL erases in insert', case_ins_erase_del),
    ('insert', 'erase under a pushed tail', case_ins_erase_tail),
    ('insert', 'erase stops at the insert point', case_ins_erase_floor),
    ('insert', 'o + left-arrows + Enter (operator repro)',
     case_ins_erase_o_enter),
    ('insert', 'right-arrow exits and moves', case_ins_arrow_exits),
    ('motion', 'Enter / + next line first non-blank', case_motion_cr_plus),
    ('insert', 'ESC lands on the last typed char', case_ins_esc_cursor),
    ('insert', 'tail redrawn live while typing', case_ins_live_tail),
    # motions
    ('motion', 'h / l', case_motion_hl),
    ('motion', 'j / k', case_motion_jk),
    ('motion', '$ / 0', case_motion_dollar_zero),
    ('motion', '^ first non-blank', case_motion_caret),
    ('motion', 'w word', case_motion_word),
    ('motion', 'b word back', case_motion_b),
    ('motion', 'e word end', case_motion_e),
    ('motion', 'f find char', case_motion_find_f),
    ('motion', 'F find char back', case_motion_find_F),
    ('motion', 't till char', case_motion_till_t),
    ('motion', '; repeat find', case_motion_semicolon),
    ('motion', ', reverse find', case_motion_comma),
    ('motion', 'count (3l)', case_motion_count),
    ('motion', 'down-arrow', case_motion_arrow_down),
    ('motion', 'G / 1G', case_motion_G),
    # paging
    ('paging', '^F / ^B', case_page_ctrl_f_b),
    ('paging', '^D half page', case_page_ctrl_d),
    ('paging', 'OPTION+U = ^U half page up', case_page_option_u),
    ('paging', 'j partial scroll tracks line-for-line', case_scroll_partial),
    ('paging', 'k partial scroll-up tracks line-for-line', case_scroll_partial_up),
    ('ildl', 'o mid-full-window shifts lines below down', case_ildl_o_midscreen),
    ('ildl', 'dd mid-full-window pulls lines up + scrolls in', case_ildl_dd_midscreen),
    # operators
    ('operator', 'x delete char', case_op_x),
    ('operator', 'dd delete line', case_op_dd),
    ('operator', '2dd count', case_op_dd_count),
    ('operator', 'D delete to EOL', case_op_D_to_eol),
    ('operator', 'dw delete word', case_op_dw),
    ('operator', 'dw on the LAST word', case_op_dw_lastword),
    ('operator', 'dw on a last word never joins', case_op_dw_lastword_nojoin),
    ('operator', 'dw on a one-word line', case_op_dw_oneword_line),
    ('operator', '2dw across a line boundary', case_op_2dw_across_lines),
    ('operator', 'cw on the LAST word', case_op_cw_lastword),
    ('operator', 'd2w delete words', case_op_d2w),
    ('operator', 'dG delete to EOF', case_op_dG),
    ('operator', 'r replace char', case_op_r_replace),
    ('operator', '~ toggle case', case_op_tilde),
    ('operator', 'J join lines (one space)', case_op_J_join),
    ('operator', 'J strips leading blanks', case_op_J_strip),
    ('operator', 'X deletes before the cursor', case_op_X_delete_before),
    ('operator', 'S changes the whole line', case_op_S_change_line),
    ('operator', 'cG change-to-EOF reopen line', case_op_cG_change_eof),
    ('change', 'cw acts as ce (keeps the space)', case_op_cw_ce),
    ('dot', 'x then . repeats delete', case_dot_x),
    ('dot', 'dw then . repeats', case_dot_dw),
    ('dot', 'I insert then . on another line', case_dot_insert),
    ('dot', 'r then . replaces again', case_dot_rZ),
    ('dot', 'o+text then . opens+types', case_dot_o),
    ('operator', 'yy + p paste below', case_op_p_paste),
    ('operator', 'Y + P paste above', case_op_Y_P),
    ('register', '"ayy / "ap named register', case_reg_ayy_ap),
    ('register', '"add / "aP named register', case_reg_add_aP),
    ('register', '"ayw operator form', case_reg_ayw),
    ('register', '"1 / "A are errors, buffer untouched',
     case_reg_unsupported),
    ('register', 'two-line charwise y/pat + p', case_reg_multiline_charwise),
    # change operators (enter insert)
    ('change', 'cc change line', case_op_cc),
    ('change', 'C change to EOL', case_op_C),
    ('change', 'ce change to word end', case_op_ce),
    ('change', 's substitute char', case_op_s),
    # undo
    ('undo', 'u undo', case_undo),
    # ex bridge
    ('ex', ':s substitute', case_ex_substitute),
    ('ex', ':%s over the whole buffer', case_ex_pct_substitute),
    ('ex', ':2d delete line', case_ex_delete),
    ('ex', ':g/re/d global', case_ex_global_delete),
    ('ex', ':m move line', case_ex_move),
    ('ex', ':nu number', case_ex_number),
    ('ex', 'an unknown word is refused, vi stays in command mode',
     case_ex_unknown_word),
    ('ex', 'trailing characters are refused', case_ex_trailing),
    ('ex', 'a failing ex line says so on the status row',
     case_ex_fail_says_so),
    ('ex', 'long names and :ma reach their verbs', case_ex_long_names),
    # search
    ('search', '/ forward', case_search_forward),
    ('search', '? backward', case_search_backward),
    ('search', 'n / N repeat', case_search_n_N),
    # file / quit
    ('file', ':wq round-trip', case_file_wq_roundtrip),
    ('file', 'ZZ round-trip', case_file_ZZ_roundtrip),
    ('file', 'edit existing file', case_file_edit_existing),
    ('file', ':q! discards edits', case_quit_bang_discards),
    # repaint-cache coverage (vicache.s, another stream) -- all GREEN on
    # today's (cache-less) code; each targets a specific plausible cache
    # bug, named in its own docstring.
    ('vicache', 'stale text after an earlier-row edit',
     case_vicache_stale_after_edit),
    ('vicache', 'undo then a forced repaint', case_vicache_undo_repaint),
    ('vicache', 'dd shift correctness under a forced repaint',
     case_vicache_shift_dd),
    ('vicache', 'paging thrash (DEMO/LONG, 60 lines)',
     case_vicache_paging_thrash),
    ('vicache', 'interleaved empty lines', case_vicache_empty_lines),
    ('wrap', 'DEMO/VILEN paints 0/80/81/254 by rows', case_vicache_aligned_fixtures),
    ('wrap', '$x on a wrapped line hits its last char', case_wrap_cursor_end),
    ('wrap', 'insert past col 80 wraps live', case_wrap_insert_live),
    ('wrap', 'o + 90 chars wraps while typing', case_wrap_o_long),
    ('wrap', 'Enter mid-line splits and shifts now', case_wrap_cr_split),
    ('wrap', 'j/k/$ across a wrapped line', case_wrap_jk),
    ('vicache', 'cursor column after a GROWN line (VI_PLACE_CUR)',
     case_vicache_cursor_col_grow),
    ('vicache', 'cursor column after a SHRUNK line (VI_PLACE_CUR)',
     case_vicache_cursor_col_shrink),
    ('put', 'glass: 1Gyyjp paints ONE on row 3', case_put_glass_yyjp),
    ('put', 'glass: 1GyyGp paints ONE at the end', case_put_glass_yyGp),
    ('put', 'glass: 2GyyP opens above, paints TWO', case_put_glass_yyP),
    ('put', 'glass: 3yyp paints ONE/TWO/TRI', case_put_glass_3yyp),
    ('put', 'glass: 1Gddp paints ONE on row 2', case_put_glass_ddp),
]


def main():
    global DISK
    if len(sys.argv) > 1:
        DISK = os.path.abspath(sys.argv[1])
    if not os.path.exists(DISK):
        print(f'error: {DISK} not found -- run make play-image first',
              file=sys.stderr)
        return 2
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    failures = []
    try:
        boot(client)
        print('[check-vi] booted; running vi coverage cases')
        for cat, name, fn in CASES:
            label = f'{cat}: {name}'
            try:
                fn(client)
                print(f'  ok   {label}')
            except AssertionError as e:
                failures.append(label)
                body = '\n'.join('         ' + ln
                                 for ln in str(e).splitlines())
                print(f'  FAIL {label}\n{body}')
            try:
                recover(client)
            except AssertionError:
                # unrecoverable -- rebuild the world so the rest run
                boot(client)
    finally:
        client.close()

    print()
    if failures:
        print(f'[check-vi] FAIL ({len(failures)}/{len(CASES)} cases):',
              file=sys.stderr)
        for f in failures:
            print(f'  {f}', file=sys.stderr)
        return 1
    print(f'[check-vi] PASS -- {len(CASES)} vi feature cases green')
    return 0


if __name__ == '__main__':
    sys.exit(main())
