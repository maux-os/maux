#!/usr/bin/env python3
"""check_more.py -- the POSIX more(1) on the play image (`make
check-more`): raw single-key paging with backward motion, on a file,
on a pipe, across two operands, with -n, the redirected copy path, and
the diagnostic for a missing file.

Boots build/play.po (80-column N8 console: reads `merged`), then:

  1. `more DEMO/LONG` (60 lines L01..L60): the first screenful ends at
     L23 with `--More--(38%)`; SPACE shows L46 at 76%; `b` returns to
     L01; `G` shows L60 with `(END)`; `5g` puts L05 on the top row;
     `/L45` RETURN puts L45 there; `=` names the file and line 45;
     `q` returns to the shell.
  2. `cat DEMO/LONG | more` (a pipe, spilled to MORE.INxx): the same
     first screen, SPACE forward, `b` BACK -- the spill is what makes
     that possible -- then `q`.
  3. `more DEMO/LONG DEMO/LONG`: the :::: header, two SPACEs to the
     end of the first file with `(Next file: DEMO/LONG)`, a third SPACE
     into the second file's header, `q`.
  4. `more -n 5 DEMO/LONG`: five lines and `(8%)`; `q`.
  5. `more nonexist`: `more: cannot open nonexist`.
  6. `more DEMO/LONG > T2` (not a console: a plain copy), then
     `more -n 3 T2` shows L03 and `(5%)`; `q`.
  7. `ls | more`: a listing that fits leaves no prompt behind.
  8. `man more` (more -A, the alternate screen, docs/VI-ALTSCREEN.md):
     a marker on the shell screen is hidden while the page shows and
     is back, with the prompt, after `q`.
  9. `more -A DEMO/LONG`, then `!echo BANGOUT`: the command's output
     lands on the SHELL screen with the `------` mark; a key returns to
     the page; `q` brings the shell screen (output included) back.

Teeth (each turned the named step RED when tried during development):
BACKN's TOP arithmetic (`b` lands elsewhere), the WASEOF rule in
CMDLOOP (the second SPACE of step 3 skips the Next-file prompt), the
spill (step 2's `b` shows nothing), and the arena anchor
(`dum LIBA_BSSEND` overlays the regex's capture table: step 1's
search lands on the wrong line).
"""
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, MCPError, SUPERVISOR, ROMS_DIR  # noqa: E402
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import convert, prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)


def rows(client):
    r = client.call_tool('screen_text', {})
    return r.get('merged') or r.get('main', [])


def blob(rs):
    return '\n'.join(rs)


def wait_for(client, pred, label, max_steps=1500):
    held = False
    rs = []
    for _ in range(max_steps):
        client.call_tool('step', {'cycles': 200_000})
        rs = rows(client)
        if pred(rs):
            if held:
                return rs
            held = True
        else:
            held = False
    dump = '\n'.join(f'{i:2d}|{r.rstrip()}' for i, r in enumerate(rs))
    raise AssertionError(f'timed out waiting for {label}; screen:\n{dump}')


def type_(client, text):
    client.call_tool('type', {'text': text})


def at_prompt(rs):
    nb = [r for r in rs if r.strip()]
    return bool(nb) and nb[-1].rstrip() == '$'


def top_is(rs, text):
    return rs[0].rstrip() == text


def after_echo(rs, cmd):
    """The rows below the LAST echo of `cmd` (the screen may still hold
    an earlier run's lines above it); '' when the echo is not there."""
    idx = None
    for i, r in enumerate(rs):
        if r.rstrip() == '$ ' + cmd:
            idx = i
    return '' if idx is None else blob(rs[idx + 1:])


def lo_lines(*lines):
    """A text file as a2til / a NuFX archive / tip leave it: low ASCII,
    $0D between lines, and one after the last.

    a2til does the encoding (convert.text_from_host, bit 7 untouched for
    ProDOS-standard text): check-encoding's staging ratchet counts the
    scripts that still set bit 7 by hand, and the house answer already
    implements both conventions.
    """
    return convert.text_from_host(
        ''.join(l + '\n' for l in lines).encode('ascii'))


def numbered(n, width):
    """n lines, each exactly `width` bytes with its CR, so the file is
    n*width long and the CRs land at known offsets."""
    return [('L%02d' % i).ljust(width - 1, '.') for i in range(1, n + 1)]


#: Foreign (low-ASCII, $0D) files staged on a private copy of the image.
#: name -> (bytes, the rows `more NAME` must leave below its echo).
#: The extra-row defect (SH-DEFECTS item 6) is NOT size-dependent: more
#: tested only $8D, saw a $0D file as ONE line, and SHOWLINE's own CR at
#: end of file made a blank row after the file's last one. It looked
#: size-dependent because the small files in the report were maux-written
#: (high-bit). The sizes below are chosen for the OTHER reading, the
#: refill-boundary one (learning:01M14B7RFG1024FPA330Z9ZNM2): the chunk is
#: 256 bytes, so one file ends with a CR on byte 256 exactly (aligned),
#: one has a CR on byte 256 mid-file, and one has a line straddling it.
FOREIGN = [
    ('LOSHORT', lo_lines('alpha', 'beta', 'gamma'),
     ['alpha', 'beta', 'gamma']),
    ('LOEMPTY', lo_lines('top', '', 'bottom'), ['top', '', 'bottom']),
    ('LOALIGN', lo_lines(*numbered(16, 16)), numbered(16, 16)),
    ('LOMID', lo_lines(*numbered(17, 16)), numbered(17, 16)),
    ('LOSTRAD', lo_lines(*numbered(19, 14)), numbered(19, 14)),
]
FOREIGN_SQ = lo_lines('a', '', '', '', 'b')
FOREIGN_LONG = lo_lines(*['L%02d' % i for i in range(1, 61)])
#: Content-polarity files (SH-DEFECTS item 15): 60 rows, mixed case on
#: row 40. LOCASE is low ASCII / $0D, HICASE is maux's own high bit /
#: $8D. A pattern typed at the console is high-bit either way.
CASE_ROWS = ['R%02d' % i for i in range(1, 61)]
ROW40 = 'R40 Needle here'
CASE_ROWS[39] = ROW40
FOREIGN_CASE = lo_lines(*CASE_ROWS)
NATIVE_CASE = convert.text_from_host(
    ''.join(r + '\n' for r in CASE_ROWS).encode('ascii'), high_bit=True)


def stage_foreign(disk):
    prodos.mount(disk, replace=True)
    try:
        for name, data, _ in FOREIGN:
            prodos.write('/mnt/MAUX/' + name, data, file_type=0x04,
                         aux_type=0, overwrite=True)
        prodos.write('/mnt/MAUX/LOLONG', FOREIGN_LONG, file_type=0x04,
                     aux_type=0, overwrite=True)
        prodos.write('/mnt/MAUX/LOSQ', FOREIGN_SQ, file_type=0x04,
                     aux_type=0, overwrite=True)
        prodos.write('/mnt/MAUX/LOCASE', FOREIGN_CASE, file_type=0x04,
                     aux_type=0, overwrite=True)
        prodos.write('/mnt/MAUX/HICASE', NATIVE_CASE, file_type=0x04,
                     aux_type=0, overwrite=True)
    finally:
        prodos.unmount('MAUX')


def rows_below(rs, cmd):
    """Exact rows between the last echo of `cmd` and the final bare
    prompt; None when either is missing."""
    idx = None
    for i, r in enumerate(rs):
        if r.rstrip() == '$ ' + cmd:
            idx = i
    last = None
    for i, r in enumerate(rs):
        if r.strip():
            last = i
    if idx is None or last is None or rs[last].rstrip() != '$' or last <= idx:
        return None
    return [r.rstrip() for r in rs[idx + 1:last]]


def check_foreign(client):
    """more on a low-ASCII file: exactly the file's rows, as cat leaves
    them, and paging that sees the lines."""
    for name, _, want in FOREIGN:
        cmd = 'more ' + name
        type_(client, cmd + '\r')
        rs = wait_for(client, lambda rs: rows_below(rs, cmd) is not None,
                      cmd + ' back at the prompt')
        got = rows_below(rs, cmd)
        if got != want:
            raise AssertionError('%s left %d rows, expected %d:\n%r\nvs\n%r'
                                 % (cmd, len(got), len(want), got, want))
        print('[check-more] %s: %d rows, no extra blank' % (cmd, len(got)))
    # a long foreign file must PAGE: one screenful, then the prompt
    type_(client, 'more LOLONG\r')
    wait_for(client, lambda rs: 'L23' in blob(rs) and 'L24' not in blob(rs)
             and '--More--(38%)' in blob(rs), 'LOLONG first screen at 38%')
    # ... and move like it: the same keys as step 1, on foreign bytes.
    # `/` is the FETCH site (the searcher copies a line into LINEBUF):
    # with FETCH blind to $0D it copies the file's tail as one "line",
    # line 1 matches, and L45 never reaches the top row.
    type_(client, ' ')
    wait_for(client, lambda rs: 'L46' in blob(rs) and 'L47' not in blob(rs)
             and '(76%)' in blob(rs), 'LOLONG: SPACE to L46 at 76%')
    type_(client, 'b')
    wait_for(client, lambda rs: top_is(rs, 'L01') and 'L24' not in blob(rs)
             and '(38%)' in blob(rs), 'LOLONG: b back to L01')
    type_(client, 'G')
    wait_for(client, lambda rs: 'L60' in blob(rs) and top_is(rs, 'L38')
             and '(END)' in blob(rs), 'LOLONG: G')
    type_(client, '5g')
    wait_for(client, lambda rs: top_is(rs, 'L05') and '(45%)' in blob(rs),
             'LOLONG: 5g')
    # ^...$ (dots have no polarity) matches exactly a 3-byte line, so
    # it lands on L06 only if FETCH stops each line at its $0D.
    type_(client, '/^...$\r')
    wait_for(client, lambda rs: top_is(rs, 'L06'), 'LOLONG: /^...$ -> L06')
    # A LITERAL pattern is typed high-bit and the file holds low ASCII
    # (SH-DEFECTS item 15, content polarity): FETCH hands the matcher a
    # high-bit COPY. /L45 lands on L45 only if both the $0D end and the
    # polarity are right (the old gate could not use a literal here).
    type_(client, '/L45\r')
    wait_for(client, lambda rs: top_is(rs, 'L45'), 'LOLONG: /L45 -> L45')
    type_(client, '?L2\r')
    wait_for(client, lambda rs: top_is(rs, 'L29'), 'LOLONG: ?L2 -> L29')
    type_(client, '45g')
    wait_for(client, lambda rs: top_is(rs, 'L45'), 'LOLONG: 45g')
    type_(client, '=')
    wait_for(client, lambda rs: 'LOLONG line 45' in blob(rs), 'LOLONG: =')
    type_(client, 'q')
    wait_for(client, at_prompt, 'LOLONG: q')
    print('[check-more] more LOLONG: pages, b, G, 5g, /, = as for a high-bit file')
    # COPYONE (stdout not a console) with -s: a foreign file's blank
    # lines are squeezed. Rows pinned exactly on the copy.
    type_(client, 'more -s LOSQ > LOSQO\r')
    wait_for(client, at_prompt, 'more -s LOSQ > LOSQO')
    type_(client, 'cat LOSQO\r')
    rs = wait_for(client, lambda rs: rows_below(rs, 'cat LOSQO') is not None,
                  'cat LOSQO')
    got = rows_below(rs, 'cat LOSQO')
    if got != ['a', '', 'b']:
        raise AssertionError('more -s on a foreign file copied %r, expected '
                             "['a', '', 'b']" % (got,))
    print('[check-more] more -s LOSQ > LOSQO: blank run squeezed (COPYONE)')


def search_case(client, cmd, pat, want_row):
    """Open a 60-row file, search `pat`; want_row None means the search
    must report 'Pattern not found' (and stay on row 1)."""
    type_(client, cmd + '\r')
    wait_for(client, lambda rs: 'R23' in blob(rs) and 'R24' not in blob(rs),
             cmd + ': first screen')
    type_(client, '/' + pat + '\r')
    if want_row is None:
        wait_for(client, lambda rs: 'Pattern not found' in blob(rs)
                 and top_is(rs, 'R01'), cmd + ' /' + pat + ': not found')
    else:
        wait_for(client, lambda rs: top_is(rs, want_row),
                 cmd + ' /' + pat + ' -> ' + want_row)
    type_(client, 'q')
    wait_for(client, at_prompt, cmd + ': q')
    print('[check-more] %s /%s: %s' % (cmd, pat, want_row or 'not found'))


def check_polarity(client):
    """Literal and -i search, on a low-ASCII and on a high-bit file."""
    for f in ('LOCASE', 'HICASE'):
        search_case(client, 'more ' + f, 'Needle', ROW40)   # exact case
        search_case(client, 'more ' + f, 'needle', None)    # case matters
        search_case(client, 'more -i ' + f, 'needle', ROW40)
        search_case(client, 'more -i ' + f, 'NEEDLE', ROW40)


def verify_untouched(disk):
    """more only READS a foreign file: after every case the staged bytes
    must be byte-identical on the image (tests for $0D, never rewrites)."""
    prodos.mount(disk, replace=True, readonly=True)
    try:
        want = [(n, d) for n, d, _ in FOREIGN]
        want += [('LOLONG', FOREIGN_LONG), ('LOSQ', FOREIGN_SQ),
                 ('LOCASE', FOREIGN_CASE), ('HICASE', NATIVE_CASE)]
        for name, data in want:
            got = prodos.read('/mnt/MAUX/' + name)
            if got != data:
                raise AssertionError('more modified %s on disk: %r != %r'
                                     % (name, got[:32], data[:32]))
    finally:
        prodos.unmount('MAUX')
    print('[check-more] foreign files byte-identical on disk after more')


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    base = os.path.abspath(sys.argv[1])
    tmp = tempfile.mkdtemp(prefix='maux-more-')
    disk = os.path.join(tmp, 'more.po')
    ok_run = False
    shutil.copyfile(base, disk)
    stage_foreign(disk)
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        client.call_tool('reset', {'backend': 'fast', 'aux': 'ramworks'})
        client.call_tool('mount_disk', {'path': disk})
        wait_for(client, lambda rs: any(r.startswith('$') for r in rs),
                 'the shell prompt')

        # 1. a file
        type_(client, 'more DEMO/LONG\r')
        wait_for(client, lambda rs: 'L23' in blob(rs) and 'L24' not in blob(rs)
                 and '--More--(38%)' in blob(rs), 'first screen at 38%')
        print('[check-more] more DEMO/LONG: 23 lines, --More--(38%)')
        type_(client, ' ')
        wait_for(client, lambda rs: 'L46' in blob(rs) and 'L47' not in blob(rs)
                 and '(76%)' in blob(rs), 'SPACE to L46 at 76%')
        print('[check-more] SPACE: L24..L46, 76%')
        type_(client, 'b')
        wait_for(client, lambda rs: top_is(rs, 'L01') and 'L24' not in blob(rs)
                 and '(38%)' in blob(rs), 'b back to L01')
        print('[check-more] b: back to L01')
        type_(client, 'G')
        wait_for(client, lambda rs: 'L60' in blob(rs) and top_is(rs, 'L38')
                 and '(END)' in blob(rs), 'G to the last screenful')
        print('[check-more] G: L38..L60, (END)')
        type_(client, '5g')
        wait_for(client, lambda rs: top_is(rs, 'L05') and '(45%)' in blob(rs),
                 '5g')
        print('[check-more] 5g: L05 on top')
        type_(client, '/L45\r')
        wait_for(client, lambda rs: top_is(rs, 'L45') and '(END)' in blob(rs),
                 '/L45')
        print('[check-more] /L45: L45 on top')
        type_(client, '=')
        wait_for(client, lambda rs: 'DEMO/LONG line 45' in blob(rs), '=')
        print('[check-more] =: DEMO/LONG line 45')
        type_(client, 'q')
        wait_for(client, at_prompt, 'q back to the shell')
        print('[check-more] q: shell prompt')

        # 2. a pipe
        type_(client, 'cat DEMO/LONG | more\r')
        wait_for(client, lambda rs: 'L23' in blob(rs) and 'L24' not in blob(rs)
                 and '--More--' in blob(rs), 'pipe: first screen')
        type_(client, ' ')
        wait_for(client, lambda rs: 'L46' in blob(rs) and 'L47' not in blob(rs),
                 'pipe: SPACE')
        type_(client, 'b')
        wait_for(client, lambda rs: top_is(rs, 'L01') and 'L24' not in blob(rs),
                 'pipe: b (the spill)')
        type_(client, 'q')
        wait_for(client, at_prompt, 'pipe: q')
        print('[check-more] cat DEMO/LONG | more: pages, and b goes back')

        # 3. two operands
        type_(client, 'more DEMO/LONG DEMO/LONG\r')
        wait_for(client, lambda rs: top_is(rs, '::::::::::::::')
                 and 'L20' in blob(rs) and '(33%)' in blob(rs),
                 'two files: header + first screen')
        type_(client, ' ')
        wait_for(client, lambda rs: '(71%)' in blob(rs), 'two files: 71%')
        type_(client, ' ')
        wait_for(client, lambda rs: '(Next file: DEMO/LONG)' in blob(rs),
                 'two files: the Next-file prompt')
        type_(client, ' ')
        wait_for(client, lambda rs: top_is(rs, '::::::::::::::')
                 and '(33%)' in blob(rs), 'two files: the second header')
        type_(client, 'q')
        wait_for(client, at_prompt, 'two files: q')
        print('[check-more] two operands: header, Next file, second header')

        # 4. -n
        type_(client, 'more -n 5 DEMO/LONG\r')
        wait_for(client, lambda rs: 'L05' in after_echo(rs, 'more -n 5 DEMO/LONG')
                 and 'L06' not in after_echo(rs, 'more -n 5 DEMO/LONG')
                 and '(8%)' in after_echo(rs, 'more -n 5 DEMO/LONG'), '-n 5')
        type_(client, 'q')
        wait_for(client, at_prompt, '-n 5: q')
        print('[check-more] -n 5: five lines, 8%')

        # 5. a missing file
        type_(client, 'more nonexist\r')
        wait_for(client, lambda rs: 'more: cannot open nonexist' in blob(rs)
                 and at_prompt(rs), 'the diagnostic')
        print('[check-more] more nonexist: diagnostic')

        # 6. the copy path
        type_(client, 'more DEMO/LONG > T2\r')
        wait_for(client, at_prompt, 'redirected copy')
        type_(client, 'more -n 3 T2\r')
        wait_for(client, lambda rs: 'L03' in after_echo(rs, 'more -n 3 T2')
                 and 'L04' not in after_echo(rs, 'more -n 3 T2')
                 and '(5%)' in after_echo(rs, 'more -n 3 T2'), 'the copy paged')
        type_(client, 'q')
        wait_for(client, at_prompt, 'copy: q')
        print('[check-more] more DEMO/LONG > T2 copied; T2 pages')

        # 7. a short pipe exits by itself
        type_(client, 'ls | more\r')
        rs = wait_for(client, lambda rs: at_prompt(rs)
                      and 'T2' in after_echo(rs, 'ls | more'),
                      'ls | more back at the prompt')
        if '--More--' in after_echo(rs, 'ls | more'):
            raise AssertionError('a listing that fits still prompted')
        print('[check-more] ls | more: fits, no prompt')

        # 8. man pages on the alternate screen (more -A)
        type_(client, 'echo ALTMARK\r')
        wait_for(client, lambda rs: at_prompt(rs) and 'ALTMARK' in blob(rs),
                 'marker on the shell screen')
        type_(client, 'man more\r')
        wait_for(client, lambda rs: 'MORE(1)' in blob(rs) and '--More--' in blob(rs)
                 and 'ALTMARK' not in blob(rs),
                 'man more: the page, the marker parked')
        type_(client, 'q')
        wait_for(client, lambda rs: at_prompt(rs) and 'ALTMARK' in blob(rs)
                 and 'MORE(1)' not in blob(rs), 'man: q brings the shell screen back')
        print('[check-more] man more: alternate screen, restored on q')

        # 8b. a ONE-SCREEN page on the alternate screen must STAY until a
        # key. V7 more leaves at once when the last file fits, and under
        # -A leaving restores the shell screen -- so a stub page like
        # cxref(1) was drawn and wiped in the same instant ("starts to
        # display then dies", operator, 2026-10-01, make play). The
        # pager now parks at --More--(END) for a fitting file under -A;
        # plain more (case 7) keeps the V7 exit. Teeth: restore the
        # unconditional QUITFLG in morefile.s and the page is gone
        # before this predicate can see it beside the (END) prompt.
        type_(client, 'man cxref\r')
        wait_for(client, lambda rs: 'CXREF(1)' in blob(rs) and '(END)' in blob(rs)
                 and 'ALTMARK' not in blob(rs),
                 'man cxref: one-screen page parked at (END)')
        for _ in range(10):            # no key: it must still be there
            client.call_tool('step', {'cycles': 200_000})
        rs = rows(client)
        if 'CXREF(1)' not in blob(rs) or '(END)' not in blob(rs):
            raise AssertionError('man cxref: one-screen page vanished without a key')
        type_(client, 'q')
        wait_for(client, lambda rs: at_prompt(rs) and 'ALTMARK' in blob(rs)
                 and 'CXREF(1)' not in blob(rs), 'man cxref: q restores the shell screen')
        print('[check-more] man cxref: one-screen page waits at (END) under -A')

        # 8c. ^L back at the prompt must redraw ONLY the prompt. The ^L
        # replay shadow records the process write path since the last
        # CR; more's "--More--(END)" went up on the ALTERNATE screen with
        # no CR after it, so until VCA_EXIT reset the shadow, ^L painted
        # "--More--(END)$" on the shell row -- one more pager prompt per
        # man page visited ("previous prompts accumulate", operator,
        # 2026-10-02, make play). Settle by the clear itself: ALTMARK is
        # gone once ^L has run. Teeth: drop the stz in VCA_EXIT (tty5.s).
        type_(client, '\x0c')
        rs = wait_for(client, lambda rs: 'ALTMARK' not in blob(rs)
                      and any(r.strip() for r in rs), 'man cxref: ^L cleared')
        last = [r.rstrip() for r in rs if r.strip()][-1]
        if last != '$' or 'More' in blob(rs):
            raise AssertionError('man cxref: ^L after q redrew %r, not a bare "$"'
                                 % last)
        print('[check-more] man cxref: ^L after q redraws a bare "$"')
        type_(client, 'echo ALTMARK\r')    # the ^L took case 9's landmark
        wait_for(client, lambda rs: at_prompt(rs) and 'ALTMARK' in blob(rs),
                 'ALTMARK landmark back after ^L')

        # 9. more -A: `!` runs on the shell screen, a key returns
        type_(client, 'more -A DEMO/LONG\r')
        wait_for(client, lambda rs: top_is(rs, 'L01') and 'ALTMARK' not in blob(rs),
                 'more -A: page up, marker parked')
        type_(client, '!echo BANGOUT\r')
        wait_for(client, lambda rs: 'BANGOUT' in blob(rs) and '------' in blob(rs)
                 and 'ALTMARK' in blob(rs) and not top_is(rs, 'L01'),
                 '!: output on the shell screen, ------ mark, page parked')
        type_(client, ' ')
        wait_for(client, lambda rs: top_is(rs, 'L01') and 'BANGOUT' not in blob(rs),
                 'a key: back to the page')
        type_(client, 'q')
        wait_for(client, lambda rs: at_prompt(rs) and 'BANGOUT' in blob(rs)
                 and not top_is(rs, 'L01'), 'more -A: q restores the shell screen')
        print('[check-more] more -A: ! on the shell screen, a key back, restored on q')

        # 10. foreign text ($0D, low ASCII): SH-DEFECTS item 6
        check_foreign(client)
        check_polarity(client)
        ok_run = True
    finally:
        try:
            client.call_tool('eject_disk', {'unit': 1})
        except Exception:
            pass
        client.close()
        if ok_run:
            verify_untouched(disk)
        shutil.rmtree(tmp, ignore_errors=True)

    print('[check-more] PASS: POSIX more pages forward and back on a file '
          'and a pipe, searches, reports position, walks two operands, '
          'honours -n, copies when redirected, leaves a short '
          'listing alone, and pages man on the alternate screen')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
