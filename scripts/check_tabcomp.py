#!/usr/bin/env python3
"""check_tabcomp.py -- TAB completion in sh's line editor (`make
check-tabcomp`; src/bin/shtabc.s, shtabc2.s, docs/TAB-A3.md,
docs/TAB-A3-NOTES.md).

TAB completes the word left of the cursor, TAB TAB (no key between)
lists, on the e2e_term idiom of check_shedit.py (one key at a time,
jittered free-run slices). Every row asserts the GLASS line, because
an extra blank still runs (review finding 14): a marker key is typed after the
completion, so `echo Z` and `echo  Z` differ, and where the point is
the executed result Enter is pressed and the OUTPUT is checked too.
Candidate names are pinned from the image's own /bin and DEMO
listings (NOT discovered by the walker under test):

  /bin    ... cal cat ...  (+ the reserved word `case`, so `ca` is
          cal, case, cat -- three candidates, LCP `ca`)
  DEMO/   LONG GREET ... (TXT); the cwd holds DELTEN.SYSTEM and DEMO

Groups, one emulator session each (`check_tabcomp.py [text40|ut|
text80|all] [group ...]`): cmd, path, refuse, cursor, big, typeahead,
noedit. Teeth: scripts/teeth_tabcomp.py.
"""
import os
import re
import sys

import e2e_term as E
from check_shedit import (CTRL, keys, need, rows, settle, run_line,
                          bare)

TAB = '\\x09'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def quiet(t, polls=400, stable=8):
    """The screen has not changed for `stable` slices in a row."""
    last, n = None, 0
    for _ in range(polls):
        cur = tuple(t.screen())
        if cur == last:
            n += 1
            if n >= stable:
                return
        else:
            n = 0
        last = cur
        t._slice()


def tab(t, n=1):
    for _ in range(n):
        t.press(TAB)
        quiet(t)


def reset(t):
    """Abandon the line and clear the glass: the next row starts at
    a bare `$` in the top row."""
    t.press(CTRL['C'])
    t.wait_prompt('abandon')
    t.press(CTRL['L'])
    quiet(t)


def clear(t):
    t.press(CTRL['L'])
    quiet(t)


def last(t):
    r = rows(t)
    return r[-1] if r else ''


def listing(t):
    """The words between the first row (the line before the list)
    and the final prompt row."""
    r = rows(t)
    return [w for x in r[1:-1] for w in x.split()]


def glass_is(t, want, what):
    need(last(t) == want, f'{what}: the glass line is {last(t)!r}, '
         f'want {want!r}', t)


def row(t, typed, ntab, marker, want, what):
    """Type `typed`, press TAB `ntab` times, then the marker key;
    the last glass row must equal `want`. Leaves the line open."""
    keys(t, typed)
    tab(t, ntab)
    keys(t, marker)
    quiet(t)
    glass_is(t, want, what)


# ---------------------------------------------------------------------
def group_cmd(t):
    t.wait_prompt('ready')
    settle(t, 4)
    clear(t)
    # `ca`: cal, case, cat -- nothing to insert, nothing listed
    row(t, 'ca', 1, 'Z', '$ caZ', 'ca TAB: refusal, line unchanged')
    need(not any('cal' in r for r in rows(t)), 'ca TAB listed', t)
    reset(t)
    # TAB TAB lists, sorted, in columns; prompt, `ca`, cursor after it
    keys(t, 'ca')
    tab(t, 2)
    need(listing(t) == ['cal', 'case', 'cat'],
         f'ca TAB TAB listed {listing(t)}', t)
    need(rows(t)[0] == '$ ca' and last(t) == '$ ca',
         'ca TAB TAB: the line before/after the list', t)
    keys(t, 'Z')
    quiet(t)
    glass_is(t, '$ caZ', 'ca TAB TAB: cursor after the redraw')
    reset(t)
    # a key between the TABs (^B ^F) is a changed revision: no list
    keys(t, 'ca')
    tab(t)
    t.press(CTRL['B'])
    t.press(CTRL['F'])
    tab(t)
    need(listing(t) == [] and last(t) == '$ ca',
         f'ca TAB ^B ^F TAB must refuse again, not list: {rows(t)}', t)
    tab(t)                              # this one is the second: lists
    need(listing(t) == ['cal', 'case', 'cat'],
         'the TAB after the refused one should list', t)
    reset(t)
    # unique: blank appended, glass AND executed result
    row(t, 'cat', 1, 'Z', '$ cat Z', 'cat TAB -> `cat `')
    reset(t)
    keys(t, 'ec')
    tab(t)
    keys(t, 'hello')
    quiet(t)
    glass_is(t, '$ echo hello', 'ec TAB (builtin ECHO and a PATH echo '
             'are ONE candidate) -> `echo `')
    t.enter()
    t.wait_prompt('echo hello')
    need(bare(t, 'hello') == 1, 'echo hello did not run once', t)
    reset(t)
    # command position after operators with no blanks around them
    # (and after prefix assignments: `A=1 ca` is a command word, SH-PREFIX)
    for pre in ('ls|', 'echo a;', 'echo a&&', '(', '! ', 'if true; then ',
                'A=1 ', 'A=1 B=2 ', 'x; A=1 '):
        keys(t, pre + 'ca')
        tab(t, 2)
        need(listing(t) == ['cal', 'case', 'cat'],
             f'{pre}ca TAB TAB is command position', t)
        reset(t)
    # unique after a prefix assignment: the command is completed
    row(t, 'A=1 ec', 1, 'Z', '$ A=1 echo Z',
        'A=1 ec TAB -> `A=1 echo `')
    reset(t)
    # a reserved word that does not take a command: pathname context
    row(t, 'echo then DEM', 1, 'Z', '$ echo then DEMO/Z',
        'echo then DEM TAB: `then` is an argument here')
    reset(t)
    # an alias is matched in EXACT case
    run_line(t, 'alias Zed=ls', 'alias')
    clear(t)
    row(t, 'z', 1, 'Q', '$ zQ', 'alias Zed: `z` offers no alias')
    reset(t)
    row(t, 'Z', 1, 'Q', '$ Zed Q', 'alias Zed: `Z` -> `Zed `')
    reset(t)
    # a component listed twice, names once
    run_line(t, 'PATH=/bin:/bin', 'PATH')
    clear(t)
    keys(t, 'ca')
    tab(t, 2)
    need(listing(t) == ['cal', 'case', 'cat'],
         f'PATH=/bin:/bin: each name once, got {listing(t)}', t)
    reset(t)


def group_path(t):
    t.wait_prompt('ready')
    settle(t, 4)
    clear(t)
    row(t, 'cat DEM', 1, 'Z', '$ cat DEMO/Z', 'cat DEM TAB -> DEMO/')
    reset(t)
    # executed: LONG's text, typed through TAB, equals the plain run
    run_line(t, 'cat DEMO/LONG | wc', 'baseline')
    base = rows(t)[-2]
    keys(t, 'cat DEMO/LO')
    tab(t)
    keys(t, '| wc')
    quiet(t)
    t.enter()
    t.wait_prompt('via TAB')
    need(rows(t)[-2] == base and base.split()[0].isdigit(),
         f'cat DEMO/LO TAB | wc printed {rows(t)[-2]!r}, want {base!r}',
         t)
    reset(t)
    # a mixed-case word: the suffix only, spelled from the entry
    row(t, 'cat dem', 1, 'Z', '$ cat demO/Z',
        'cat dem TAB: suffix `O/` only')
    reset(t)
    # `cat DE` is ambiguous (DELTEN.SYSTEM, DEMO): lists, `/` on the dir
    keys(t, 'cat DE')
    tab(t, 2)
    need(listing(t) == ['DELTEN.SYSTEM', 'DEMO/'],
         f'cat DE TAB TAB listed {listing(t)}', t)
    reset(t)
    # the kernel's virtual directories; a $0F volume is a directory
    row(t, 'ls /m', 1, 'Z', '$ ls /mnt/Z', 'ls /m TAB -> /mnt/')
    reset(t)
    row(t, 'ls /mnt/MA', 1, 'Z', '$ ls /mnt/MAUX/Z',
        'ls /mnt/MA TAB -> /mnt/MAUX/ (a volume is a directory)')
    reset(t)
    # devices are not directories: no `/`; the first TAB progressed
    # (tt -> tty) so the LIST is the third TAB
    keys(t, 'ls /dev/tt')
    tab(t)
    need(last(t) == '$ ls /dev/tty', f'ls /dev/tt TAB -> {last(t)!r}', t)
    tab(t, 2)
    need(listing(t) == ['tty', 'tty1', 'tty2', 'tty3', 'tty4',
                        'ttya0'], f'/dev/tty list {listing(t)}', t)
    reset(t)
    # redirect operands are pathnames; the command after a leading
    # redirect is still a command
    row(t, 'cat > DEM', 1, 'Z', '$ cat > DEMO/Z',
        'cat > DEM TAB: redirect operand')
    reset(t)
    keys(t, '> out ca')
    tab(t, 2)
    need(listing(t) == ['cal', 'case', 'cat'],
         f'> out ca TAB TAB is a command: {listing(t)}', t)
    reset(t)
    row(t, 'for i in DEM', 1, 'Z', '$ for i in DEMO/Z',
        'for list words are pathnames')
    reset(t)
    # a word with a slash in command position is a pathname
    row(t, 'DEMO/LO', 1, 'Z', '$ DEMO/LONG Z',
        'DEMO/LO TAB: a slash makes a pathname')
    reset(t)
    # PATH=. offers the cwd; the default PATH does not
    run_line(t, 'cd DEMO', 'cd')
    row(t, 'GREE', 1, 'Z', '$ GREEZ',
        'GRE TAB with the default PATH: not a command here')
    reset(t)
    run_line(t, 'PATH=.', 'PATH=.')
    row(t, 'GREE', 1, 'Z', '$ GREET Z', 'PATH=. offers the cwd')
    reset(t)


def group_refuse(t):
    t.wait_prompt('ready')
    settle(t, 4)
    clear(t)
    # Each line is one a wrong scanner would COMPLETE or LIST: a glob
    # `DEM*` would grow to `DEM*/`, `A=ca` / `case X in A|ca` /
    # `x 2>&` would list. TAB TAB, then a marker key: the glass line
    # is untouched and nothing was listed.
    lines = ['cat "DE MO', 'cat $HO', 'cat DEM*', 'cat DEM?',
             'cat [DEM', 'x 2>&', 'cat <<E', 'A=ca',
             'case X in A|ca', 'case X in A | ca', "cat 'DEM",
             'cat DEM\\O', 'cat `DEM', 'echo hi #DEM', 'cat x=DEM',
             'for ca', 'cat "x DEM']
    for ln in lines:
        keys(t, ln)
        tab(t, 2)
        need(listing(t) == [] and last(t) == '$ ' + ln,
             f'{ln!r} TAB TAB: want a refusal, line untouched, '
             f'nothing listed; got {rows(t)}', t)
        keys(t, 'Z')
        quiet(t)
        glass_is(t, '$ ' + ln + 'Z', f'{ln!r} TAB refused')
        reset(t)
    # the shell is alive and nothing ran
    run_line(t, 'echo alive', 'alive')
    need(bare(t, 'alive') == 1, 'shell did not survive the refusals', t)


def group_cursor(t):
    t.wait_prompt('ready')
    settle(t, 4)
    clear(t)
    # mid-word: refused, line intact, cursor where it was
    keys(t, 'cat DEMO/LONG')
    t.press(CTRL['A'])
    for _ in range(7):                   # after `cat DEM`, before `O`
        t.press(CTRL['F'])
    tab(t)
    keys(t, 'Z')
    quiet(t)
    glass_is(t, '$ cat DEMZO/LONG', 'mid-word TAB refused')
    reset(t)
    # a tail starting with a blank is kept, no doubled blank
    keys(t, 'cat DEM LONG')
    t.press(CTRL['A'])
    for _ in range(7):
        t.press(CTRL['F'])
    tab(t)
    keys(t, 'Z')
    quiet(t)
    glass_is(t, '$ cat DEMO/Z LONG', 'tail kept after DEM, TAB')
    reset(t)
    keys(t, 'cat DEMO/LO X')
    t.press(CTRL['A'])
    for _ in range(11):                  # after `cat DEMO/LO`
        t.press(CTRL['F'])
    tab(t)
    keys(t, 'Z')
    quiet(t)
    glass_is(t, '$ cat DEMO/LONGZ X', 'no second blank before the tail')
    reset(t)
    # an operator after the cursor is a legal tail
    keys(t, 'ls /m;wc')
    t.press(CTRL['A'])
    for _ in range(5):
        t.press(CTRL['F'])
    tab(t)
    keys(t, 'Z')
    quiet(t)
    glass_is(t, '$ ls /mnt/Z;wc', 'operator tail kept')
    reset(t)
    # a no-match and a bare nonsense word leave the line alone
    row(t, 'zzzz', 1, 'Z', '$ zzzzZ', 'zzzz TAB: refusal')
    reset(t)
    # all or none at the 127-character cap: a line of 125 + `O/` fits
    # (127), a line of 126 + `O/` does not (128) and inserts NOTHING
    pre = 'echo ' + 'x' * 114 + ' DEM '
    keys(t, pre + 'z')                            # 125 characters
    for _ in range(2):
        t.press(CTRL['B'])
    tab(t)
    quiet(t)
    need('DEMO/' in ' '.join(rows(t)),
         'the insertion that exactly fits (127) was refused', t)
    reset(t)
    keys(t, pre + 'zz')                           # 126 characters
    for _ in range(3):
        t.press(CTRL['B'])
    tab(t)
    quiet(t)
    need('DEMO' not in ' '.join(rows(t)) and 'DEM ' in ' '.join(rows(t)),
         'an insertion that does not fit must insert NOTHING (no '
         'half of `O/`)', t)
    reset(t)


def fixture(t, n=31):
    """/tmp holds AAA01..AAA`n` and AB (names pinned here, not read
    from the walker)."""
    run_line(t, 'cd /tmp', 'cd')
    a = [f'AAA{i:02d}' for i in range(1, n + 1)] + ['AB']
    for i in range(0, len(a), 12):
        run_line(t, 'touch ' + ' '.join(a[i:i + 12]), 'touch')


def group_big(t):
    t.wait_prompt('ready')
    settle(t, 4)
    clear(t)
    fixture(t)
    t.press(CTRL['L'])
    quiet(t)
    # review finding 10: the first 31 matches would allow `AA`; all 32 do not
    row(t, 'cat A', 1, 'Z', '$ cat AZ',
        '31 x AAA* and AB: `A` TAB inserts nothing')
    reset(t)
    # AAA* is 31 names, all shown, none dropped
    keys(t, 'cat AA')
    tab(t)                               # progress: AA -> AAA
    tab(t, 2)
    got = listing(t)
    need(got == [f'AAA{i:02d}' for i in range(1, 32)],
         f'cat AAA TAB TAB listed {got}', t)
    reset(t)
    # 32 names under `A`: 31 and a final `...` row, never whole
    keys(t, 'cat A')
    tab(t, 2)
    got = listing(t)
    need(got[-1] == '...' and len(got) == 32 and 'AB' not in got,
         f'cat A TAB TAB: want 31 names then `...`, got {got}', t)
    reset(t)


def group_typeahead(t):
    t.wait_prompt('ready')
    settle(t, 4)
    clear(t)
    keys(t, 'cat DEM')
    quiet(t)
    t.c.call_tool('type', {'text': TAB + 'LONG'})   # a burst
    quiet(t)
    glass_is(t, '$ cat DEMO/LONG', 'type-ahead after TAB lands after '
             'the completion, in order')
    reset(t)


def group_noedit(t):
    t.wait_prompt('ready')
    settle(t, 4)
    clear(t)
    # cooked reader: `cat` reading a typed line drops the TAB (the
    # kernel editor's behaviour, unchanged)
    keys(t, 'cat')
    t.enter()
    quiet(t)
    keys(t, 'ca')
    t.press(TAB)
    keys(t, 'b')
    t.enter()
    quiet(t)
    need(bare(t, 'cab') == 2, 'cat read a TAB differently: the cooked '
         'echo and cat\'s own output should both say `cab`', t)
    t.press(CTRL['D'])
    t.wait_prompt('after cat')
    # a script is read by the byte path: TAB never reaches the editor
    keys(t, "printf 'echo a\\tb\\n' > /tmp/TS")
    t.enter()
    t.wait_prompt('printf')
    run_line(t, 'sh /tmp/TS', 'script')
    need(any(re.fullmatch(r'a\s+b', r) for r in rows(t)),
         'a script with a TAB in its text must print `a`, the TAB as '
         'data, `b` -- the editor is not on the script path', t)


def lc_bank(t):
    """The shell's physical aux bank: PCB_BANK of its PCB (annex
    offset 3 of the 16-byte entry at $0800 + pid*16)."""
    from check_shedit import shell_pid
    pid = shell_pid(t)
    r = t.c.call_tool('peek', {'addr': 0x0800 + pid * 16 + 3,
                               'count': 1, 'bank': 'aux',
                               'aux_bank': 0})
    return (r.get('bytes') or r.get('data'))[0]


def lc_peek(t, bank, lo, hi):
    out = []
    for a in range(lo, hi, 64):
        n = min(64, hi - a)
        r = t.c.call_tool('peek', {'addr': a, 'count': n, 'bank': 'aux',
                                   'aux_bank': bank})
        out += list(r.get('bytes') or r.get('data'))
    return out


def group_lcfree(t):
    """TAB-A3 condition 1: the language-card bytes the completer's
    placement relies on being nobody else's are untouched by a real
    session. SH-ROOM moved the alias table out of the card (into the
    segments' dead low copy), so everything between the segment's end
    and the kernel's door ($FF00) is unowned: it is filled with $A5
    and a session is run: aliases, TAB completion (command, path, a
    list), a child spawn, a nested sh, then a warm respawn of the
    login shell. (inc/mm.lseg.equ's $FE99 hits are ProDOS's MAIN-LC
    cells -- unrelated.)"""
    import arena
    st = arena.symbol_table('sh')
    seg_end, lim = st['SH_SEG_END'], st['SH_SEG1_LIM']
    names = st['ALI_NAMES']
    regions = [(seg_end, lim)]
    t.wait_prompt('ready')
    settle(t, 4)
    clear(t)
    bank = lc_bank(t)
    # shown, not blind: an alias really lands in this bank's table
    run_line(t, 'alias aa=ls', 'alias')
    got = lc_peek(t, bank, names, names + 2)
    need(got == [0xE1, 0xE1],
         f'bank {bank}: alias aa is not at ALI_NAMES ({got}): the '
         f'poke/peek window does not see the process bank', t)
    for lo, hi in regions:
        t.c.call_tool('poke', {'addr': lo, 'bytes': [0xA5] * (hi - lo),
                               'bank': 'aux', 'aux_bank': bank})
    for lo, hi in regions:
        need(lc_peek(t, bank, lo, hi) == [0xA5] * (hi - lo),
             f'the poison did not take at ${lo:04X}', t)

    def untouched(what):
        for lo, hi in regions:
            now = lc_peek(t, bank, lo, hi)
            bad = [lo + i for i, b in enumerate(now) if b != 0xA5]
            if bad:
                need(False, f'{what}: ${bad[0]:04X} (+{len(bad)} '
                     f'bytes) changed in the LC bytes nobody should '
                     f'own', t)

    run_line(t, 'alias bb=cat', 'alias 2')
    clear(t)
    keys(t, 'ca')
    tab(t, 2)
    reset(t)
    row(t, 'cat DEM', 1, 'Z', '$ cat DEMO/Z', 'path TAB')
    reset(t)
    run_line(t, 'aa /bin', 'alias use')
    run_line(t, 'sh', 'nested sh')
    run_line(t, 'echo in', 'nested line')
    t.press(CTRL['D'])
    t.wait_prompt('back')
    untouched('after aliases, TAB, a child, a nested sh')
    # TC_ON is an arena cell the glob walker reads on EVERY word: it is
    # set by START, not by the loader. A recycled bank carries leftovers
    # (check-play poisons banks with $A5), and a stale non-zero TC_ON
    # makes the first glob word vanish. Poison it, respawn, glob.
    tcon = st['TC_ON']
    t.c.call_tool('poke', {'addr': tcon, 'bytes': [0xA5],
                           'bank': 'aux', 'aux_bank': bank})
    # warm respawn: the login shell exits and is started again; the
    # card is retained, START re-initialises only what it owns
    keys(t, 'exit')
    t.enter()
    t.wait_prompt('respawn', timeout_slices=400)
    settle(t, 6)
    clear(t)
    b2 = lc_bank(t)
    need(b2 == bank, f'the respawned shell is in bank {b2}, not {bank}: '
         f'the row cannot show a warm respawn', t)
    untouched('after a warm respawn')
    clear(t)
    run_line(t, 'echo [A] [/x/] a*zz', 'glob after respawn')
    need(any(r.rstrip() == '[A] [/x/] a*zz' for r in rows(t)),
         'a glob word after a warm respawn with a poisoned TC_ON must '
         'pass through as the literal text (START owns TC_ON)', t)


GROUPS = [
    ('cmd', group_cmd),
    ('path', group_path),
    ('refuse', group_refuse),
    ('cursor', group_cursor),
    ('big', group_big),
    ('typeahead', group_typeahead),
    ('noedit', group_noedit),
    ('lcfree', group_lcfree),
]


def main():
    args = sys.argv[1:]
    which = args[0] if args else 'all'
    backs = ['text40', 'text80', 'ut'] if which == 'all' else [which]
    names = args[1:]
    bad = 0
    for b in backs:
        for name, fn in GROUPS:
            if names and name not in names:
                continue
            ok, err = E.session(b, fn)
            print(('PASS' if ok else 'FAIL'), f'tabcomp {name} [{b}]')
            if not ok:
                print(err)
                bad += 1
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
