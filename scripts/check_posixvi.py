#!/usr/bin/env python3
"""check_posixvi.py -- POSIX vi (XCU `vi`) conformance suite for maux's vi.

Table-driven: every CASES row is (group, name, setup lines, keystrokes,
note, oracle kind). For each row this script computes the BYTE-EXACT
expected buffer content from a real host vi/vim oracle, drives maux's vi
in the verilogapple emulator through the identical keystrokes, reads the
resulting file back off the emulated disk with a2til, and reports
PASS/FAIL with expected-vs-got. A failing case is caught and recorded,
never stops the run; the process exit status is nonzero only if any case
failed. This is a conformance REPORT, not a pass/fail gate meant to block
a build (see the Makefile comment on `check-posixvi`: intentionally NOT
in CHECK_ALL_TARGETS).

METHOD (see docs/ for the session that established this; the helpers
below are borrowed verbatim from scripts/check_vi.py and this session's
probe_dw4.py):

  - maux-side driving reuses scripts/check_vi.py's boot/open_vi/t/settle/
    line/line_eq/recover -- see that module for the //e-keyboard-latch
    and screen-glass caveats.
  - Byte-exact ACTUAL values: after the case's keystrokes, ESC, then
    `:w /mnt/MAUX/OUT<letter>`, and the file is read back with a2til
    (bit 7 stripped, split on '\\r'). The play image's /mnt/MAUX volume
    directory has only 4 free entries and vi's own swap file takes one,
    so at most 3 written files per boot -- CASES are batched into groups
    of <=3, each against a FRESH scratch copy of build/play.po, mounted
    without copy-on-write (probe_dw4.py's pattern), ejected before the
    read-back.
  - Byte-exact EXPECTED values come from a host oracle: real vim
    (nvi is not installed on this host), run two different ways --

      oracle_batch(): `vim -u NONE -N -n -Es -c 'set nocompatible'
      -c 'exe "normal! 1G<keys>"' -c 'wq! out' in`, exactly the form
      given in this suite's task brief. Fast, and correct for every
      case EXCEPT ones exercising `u` after more than one prior edit.

      oracle_interactive(): the SAME vim binary, but driven over a real
      pty with the keystrokes written one at a time with a short delay
      between each (mirroring how a human -- and the emulator's slow
      keyboard latch -- actually delivers keys), then `:wq!`.

    FINDING, this session: vim's undo-block boundaries are created when
    control returns to vim's interactive main loop between keystrokes;
    executing several edits inside one `-c`/`normal!` batch invocation
    never returns to that loop, so vim silently merges them into ONE
    undo step. Measured: setup ['HELLO'], keys '0xxu' ->
    oracle_batch() gives ['HELLO'] (both x's undone together) but
    oracle_interactive() -- and a real terminal, confirmed by hand via
    tmux -- gives ['ELLO'] (only the last x undone), which is the
    correct POSIX single-level-undo answer. Cross-checked all 62 other
    cases between the two oracles: zero other divergences. So
    oracle_batch() is used everywhere EXCEPT the two `undo` cases below,
    which are marked oracle='interactive'. This is the harness
    unreliability worth flagging: a batch-scripted vi/vim oracle is NOT
    trustworthy for undo semantics.
  - Cursor POSITION is judged by a following edit (`rZ`, `x`, ...) that
    turns position into buffer bytes -- never by reading the screen
    cursor cell (the //e inverse-fold glyph substitution is unreliable,
    per check_vi.py's line_eq).
  - Keystrokes are sent in <=40-char chunks, never ending a non-final
    chunk on ESC (the //e keyboard latch drops keys under a long burst,
    and check_vi.py's own t() does the per-chunk drain-stepping).
  - The three cases that once exercised documented maux gaps (dot-
    repeat, `"a named registers, a multi-line charwise yank) all pass
    now (2026-09-05, 2026-10-06; docs/VI-GAPS-2.md) and are ordinary
    rows. A future known gap goes in the 'gap' category with a note
    saying it is expected to FAIL -- the report is the deliverable; a
    known-gap case is not hidden or skipped.
"""
import os
import sys
import shutil
import subprocess
import tempfile
import time
import select
import pty

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_vi as V                                    # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR    # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import a2til                                             # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'play.po')
ESC = V.ESC
# Under build/posix/, where every other suite keeps its logs -- a path the
# box has (see check_posixex.py's note, same fix, same day).
SCRATCH = os.environ.get(
    'POSIXVI_SCRATCH', os.path.join(ROOT, 'build', 'posix', 'posixvi'))


# ======================================================================
# host oracle -- real vim, two delivery mechanisms (see module docstring)
# ======================================================================
def _vim_escape(raw):
    """Translate raw keystroke bytes (the SAME string sent to maux) into
    a vimscript double-quoted string literal, for `exe "normal! ..."`."""
    out = []
    for ch in raw:
        o = ord(ch)
        if ch == '\x1b':
            out.append('\\<Esc>')
        elif ch in ('\r', '\n'):
            out.append('\\<CR>')
        elif ch == '\\':
            out.append('\\\\')
        elif ch == '"':
            out.append('\\"')
        elif o < 0x20:
            out.append('\\<C-%s>' % chr(o + 0x60))
        else:
            out.append(ch)
    return ''.join(out)


def oracle_batch(lines, keys):
    """`vim -u NONE -N -n -Es ... exe "normal! 1G<keys>" ... wq! out`."""
    workdir = tempfile.mkdtemp(dir=SCRATCH)
    try:
        infile = os.path.join(workdir, 'in')
        outfile = os.path.join(workdir, 'out')
        with open(infile, 'w') as f:
            f.write('\n'.join(lines) + ('\n' if lines else ''))
        vim_keys = _vim_escape(keys) if keys else ''
        normal_cmd = ('exe "normal! 1G%s"' % vim_keys) if vim_keys \
            else 'exe "normal! 1G"'
        cmd = ['vim', '-u', 'NONE', '-N', '-n', '-Es',
               '-c', 'set nocompatible',
               '-c', normal_cmd,
               '-c', 'wq! out',
               'in']
        r = subprocess.run(cmd, cwd=workdir, capture_output=True,
                            text=True, timeout=15)
        if not os.path.exists(outfile):
            raise RuntimeError(
                f'vim oracle produced no output; rc={r.returncode} '
                f'stderr={r.stderr!r}')
        with open(outfile) as f:
            content = f.read()
        got = content.split('\n')
        if got and got[-1] == '':
            got = got[:-1]
        return got
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def _pty_drain(fd, timeout=0.05):
    while True:
        r, _, _ = select.select([fd], [], [], timeout)
        if not r:
            return
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            return
        if not chunk:
            return


def oracle_interactive(lines, keys):
    """Real vim over a pty, keys sent ONE CHARACTER AT A TIME with a
    settle delay -- so undo-block boundaries form the way they do for a
    real human (see module docstring finding)."""
    workdir = tempfile.mkdtemp(dir=SCRATCH)
    try:
        infile = os.path.join(workdir, 'in')
        with open(infile, 'w') as f:
            f.write('\n'.join(lines) + ('\n' if lines else ''))
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(workdir)
            os.execvp('vim', ['vim', '-u', 'NONE', '-N', '-n', 'in'])
            os._exit(1)
        try:
            time.sleep(0.3)
            _pty_drain(fd)
            for ch in keys:
                os.write(fd, ch.encode())
                time.sleep(0.15)
                _pty_drain(fd)
            os.write(fd, b':wq!\r')
            time.sleep(0.3)
            _pty_drain(fd)
            os.waitpid(pid, 0)
        finally:
            try:
                os.close(fd)
            except OSError:
                pass
        with open(infile) as f:
            content = f.read()
        got = content.split('\n')
        if got and got[-1] == '':
            got = got[:-1]
        return got
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def oracle(case):
    group, name, setup, keys, note, kind = case
    if kind == 'interactive':
        return oracle_interactive(setup, keys)
    return oracle_batch(setup, keys)


# ======================================================================
# maux-side keystroke helpers
# ======================================================================
def type_chunked(client, text, limit=40):
    """Send `text` in <=`limit`-char chunks, never ending a NON-FINAL
    chunk on ESC (check_vi.py's t() drains the //e keyboard latch per
    call, but a long burst still drops keys -- per this suite's brief)."""
    if not text:
        return
    i, n = 0, len(text)
    while i < n:
        j = min(i + limit, n)
        if j < n and text[j - 1] == '\x1b':
            j = min(j + 1, n)
        V.t(client, text[i:j])
        i = j


def insert_lines(client, lines):
    """Build a buffer via `i`, one setup line per t() call, ESC at the
    end -- the _fill() pattern in check_vi.py."""
    if not lines:
        return
    V.t(client, 'i')
    for idx, ln in enumerate(lines):
        type_chunked(client, ln)
        if idx < len(lines) - 1:
            V.t(client, '\r')
    V.t(client, ESC)


def settle_setup(client, lines):
    last = len(lines) - 1

    def pred(rs):
        for i, ln in enumerate(lines):
            expect = ln.rstrip()
            if i == last:
                if not V.line_eq(rs, i, expect):
                    return False
            elif V.line(rs, i) != expect:
                return False
        return True

    V.settle(client, pred, 'setup lines settled')


# ======================================================================
# case table
# ======================================================================
# (group, name, setup lines, keystrokes, note, oracle kind)
CASES = [
    # ---- motions --------------------------------------------------
    ('motion', 'h / l', ['abcdef'], '0llrZhhrQ',
     'l moves right, h moves left; r marks the landing column', 'batch'),
    ('motion', 'j / k', ['L1', 'L2', 'L3'], '1GjrZkrQ',
     'j moves down a line, k moves up', 'batch'),
    ('motion', '0 / $', ['HELLO'], '$x0x',
     '$ moves to the last column, 0 to the first', 'batch'),
    ('motion', '^ first non-blank', ['  ab'], '$^rZ',
     '^ moves to the first non-blank column, not column 0', 'batch'),
    ('motion', 'w stops at punctuation', ['one.two three'], '0wrZ',
     'w treats a run of punctuation as its own word class', 'batch'),
    ('motion', 'W skips punctuation', ['one.two three'], '0WrZ',
     'W (WORD) motion is blank-delimited only, unlike w', 'batch'),
    ('motion', 'b word back', ['one.two three'], '04lbrZ',
     'b moves to the start of the current/previous small word', 'batch'),
    ('motion', 'B WORD back', ['one.two three'], '04lBrZ',
     'B moves to the start of the current/previous WORD', 'batch'),
    ('motion', 'e word end', ['one.two three'], '0erZ',
     'e moves to the end of the current small word', 'batch'),
    ('motion', 'E WORD end', ['one.two three'], '0ErZ',
     'E moves to the end of the current WORD', 'batch'),
    ('motion', 'f find char forward', ['abcdef'], '0fdrZ',
     'f finds a char forward, landing ON it', 'batch'),
    ('motion', 'F find char backward', ['abcdef'], '$FcrZ',
     'F finds a char backward, landing ON it', 'batch'),
    ('motion', 't till char forward', ['abcdef'], '0tdrZ',
     't stops one column BEFORE the char, going forward', 'batch'),
    ('motion', 'T till char backward', ['abcdef'], '$TdrZ',
     'T stops one column AFTER the char, going backward', 'batch'),
    ('motion', '; repeats last find', ['axbxc'], '0fx;rZ',
     '; repeats the last f/F/t/T in the SAME direction', 'batch'),
    ('motion', ', reverses last find', ['axbxdx'], '$FxFx,rZ',
     ', repeats the last f/F/t/T in the OPPOSITE direction', 'batch'),
    ('motion', 'count (3l)', ['abcdef'], '03lrZ',
     'a leading count repeats the motion that many times', 'batch'),
    ('motion', 'G / 1G', ['L1', 'L2', 'L3'], '1GxGx',
     '1G goes to the first line, G (no count) to the last', 'batch'),
    ('motion', '2G to a line number', ['L1', 'L2', 'L3'], '2GrZ',
     'a count before G goes to that line number', 'batch'),

    # ---- operators (d/c/y + motions, dd/cc/yy, counts) --------------
    ('operator', 'dd deletes the line', ['L1', 'L2', 'L3'], '1Gdd',
     'dd is linewise regardless of cursor column', 'batch'),
    ('operator', '2dd counted', ['L1', 'L2', 'L3', 'L4'], '1G2dd',
     'a count before dd deletes that many whole lines', 'batch'),
    ('operator', 'D deletes to EOL', ['HELLO'], '0lD',
     'D is the d$ shortcut', 'batch'),
    ('operator', 'd$ operator+motion', ['HELLO WORLD'], '0lld$',
     'd$ deletes from the cursor to end of line', 'batch'),
    ('operator', 'd0 to column 0', ['HELLO'], '$d0',
     'd0 deletes from the cursor back to column 0 (exclusive)', 'batch'),
    ('operator', 'dw deletes a word', ['one two three'], '0dw',
     'dw on a non-final word deletes up to the next word start', 'batch'),
    ('operator', 'dw on the LAST word', ['one two three'], '0wwdw',
     'dw on a last word deletes to EOL, not past it', 'batch'),
    ('operator', 'dw on a last word never joins',
     ['aa bb', 'cc dd'], '1Gwdw',
     'dw to EOL on a last word must not pull the next line up', 'batch'),
    ('operator', 'dw on a one-word line', ['bb', 'cc'], '1Gdw',
     'dw on the only word empties the line, no linewise join', 'batch'),
    ('operator', '2dw across a line boundary',
     ['aa bb', 'cc dd'], '1Gw2dw',
     'a count that runs dw past EOL DOES join to the next line', 'batch'),
    ('operator', 'd2w two words', ['one two three'], '0d2w',
     'a count on the dw motion deletes that many words', 'batch'),
    ('operator', 'dG to EOF', ['L1', 'L2', 'L3'], '2GdG',
     'dG deletes from the cursor line through end of file', 'batch'),
    ('operator', 'dt as an operator', ['abcdef'], '0dtd',
     't as an operator argument: delete up to (not including) the char',
     'batch'),
    ('operator', 'df as an operator', ['abcdef'], '0dfd',
     'f as an operator argument: delete up to AND including the char',
     'batch'),
    ('change', 'cc changes the whole line', ['OLD line'], 'ccNEW' + ESC,
     'cc is linewise like dd, then opens insert mode', 'batch'),
    ('change', 'cw on the LAST word', ['one two three'],
     '0wwcwX' + ESC, 'cw on a last word replaces ALL of it', 'batch'),
    ('change', 'ce to word end', ['one two'], '0ceNEW' + ESC,
     'ce changes from the cursor to the current word end', 'batch'),
    ('change', 'cG to EOF', ['L1', 'L2', 'L3'], '2GcGNEW' + ESC,
     'cG changes from the cursor line through EOF', 'batch'),
    ('operator', 'yy + p paste below', ['L1', 'L2'], '1Gyyp',
     'yy yanks a whole line, p pastes it below the cursor', 'batch'),
    ('operator', 'Y + P paste above', ['L1', 'L2'], '1GYP',
     'Y is a yy synonym; P pastes above the cursor', 'batch'),

    # ---- delete/change shortcuts (x X D C Y S s r ~ J) --------------
    ('shortcut', 'x deletes under the cursor', ['ABC'], '0x',
     '', 'batch'),
    ('shortcut', 'X deletes before the cursor', ['ABCDE'], '$X',
     'X deletes the char to the LEFT of the cursor', 'batch'),
    ('shortcut', 'C changes to EOL', ['HELLO WORLD'], '0llCxx' + ESC,
     'C is the cc-to-EOL shortcut (c$)', 'batch'),
    ('shortcut', 'S changes the whole line', ['OLD line'],
     'SNEW' + ESC, 'S is a POSIX cc synonym', 'batch'),
    ('shortcut', 's substitutes a char', ['ABC'], '0sZ' + ESC,
     's deletes the char under the cursor and opens insert mode',
     'batch'),
    ('shortcut', 'r replaces one char', ['ABC'], '0rZ',
     'r replaces without entering insert mode', 'batch'),
    ('shortcut', '~ toggles case', ['abc'], '0~~~',
     '~ toggles case of the char under the cursor and advances', 'batch'),
    ('shortcut', 'J joins two lines', ['AAA', 'BBB'], '1GJ',
     'J joins the next line onto the current one', 'batch'),

    # ---- undo (see module docstring re: oracle_interactive) --------
    ('undo', 'u undoes the last change', ['HELLO'], '0xu',
     '', 'interactive'),
    ('undo', 'u is single-level', ['HELLO'], '0xxu',
     'classic/POSIX vi undo is SINGLE-LEVEL: after two x, one u '
     'undoes only the most recent one -- a batch-scripted vim oracle '
     'gets this WRONG (merges both into one undo step); this case is '
     'checked against a pty-driven interactive oracle instead (see '
     'module docstring)', 'interactive'),

    # ---- insert entry (i a A I o O) ---------------------------------
    ('insert', 'i inserts before the cursor', [], 'iHELLO' + ESC,
     '', 'batch'),
    ('insert', 'a appends after the cursor', ['HELLO'], '0aZ' + ESC,
     '', 'batch'),
    ('insert', 'A appends at end of line', ['HELLO'], 'AXYZ' + ESC,
     '', 'batch'),
    ('insert', 'I inserts at first non-blank', ['HELLO'], '$IX' + ESC,
     '', 'batch'),
    ('insert', 'o opens a line below', ['AAA'], '1GoBBB' + ESC,
     '', 'batch'),
    ('insert', 'O opens a line above', ['AAA'], '1GOZZZ' + ESC,
     '', 'batch'),
    ('insert', 'CR in insert mode splits the line', [],
     'iAAA\rBBB' + ESC, '', 'batch'),

    # ---- search (/ ? n N) -------------------------------------------
    ('search', '/ searches forward', ['foo', 'bar', 'foo'],
     '1G/bar\rx', '', 'batch'),
    ('search', '? searches backward', ['foo', 'bar', 'baz'],
     'G?bar\rrZ', '', 'batch'),
    ('search', 'n / N repeat the last search', ['x', 'x', 'x'],
     '1G/x\rnrZNrQ',
     'n repeats forward, N reverses direction once', 'batch'),

    # ---- ex bridge (:w :q :s minimal) --------------------------------
    ('ex', ':s substitutes on the current line', ['OLD text'],
     ':s/OLD/NEW/\r', '', 'batch'),
    ('ex', ':s with a /g flag substitutes every match',
     ['aa aa aa'], ':s/aa/bb/g\r', '', 'batch'),
    ('ex', ':w persists the buffer with no edits', ['HELLO'], '',
     'no keys are sent before the write -- isolates :w itself, though '
     'every OTHER case in this suite already exercises :w as its own '
     'capture mechanism', 'batch'),

    # ---- ex command NAMES (docs/EX-BADCMD.md, 2026-10-08) -------------
    # `:cxyz` ran CHANGE (the first letter won) and left vi in ex's
    # line-input mode with no message; `:dxyz` deleted the current line.
    # A refused word must change nothing and leave vi in command mode,
    # which the trailing `IX<Esc>` turns into buffer bytes (it inserts X
    # at line start only if vi is back in command mode). A real vi
    # prints "Not an editor command"; the status-row text itself is
    # asserted on the glass by check_vi.py's case_ex_unknown_word.
    # `interactive`: a failing `:` command aborts a batch `normal!`
    # string in vim, so the batch oracle would drop the keys after it.
    ('ex', ':cxyz is refused and vi stays in command mode',
     ['L1', 'L2'], '1G:cxyz\rIX\x1b', 'maux base: ran :c, swallowed the '
     'keys as text', 'interactive'),
    ('ex', ':dxyz is refused, no line is deleted',
     ['L1', 'L2'], '1G:dxyz\rIX\x1b', 'maux base: deleted the current '
     'line', 'interactive'),
    ('ex', ':axyz is refused, not run as :append',
     ['L1', 'L2'], '1G:axyz\rIX\x1b', '', 'interactive'),
    ('ex', ':wxyz is refused (it is not :w)',
     ['L1', 'L2'], '1G:wxyz\rIX\x1b', '', 'interactive'),
    ('ex', ':2delete runs as :2d', ['L1', 'L2', 'L3'],
     ':2delete\r', 'the POSIX long name reaches the verb', 'batch'),
    ('ex', ':1,2dele runs as :1,2d (any prefix down to d)',
     ['L1', 'L2', 'L3'], ':1,2dele\r', '', 'batch'),

    # ---- the former documented gaps (all closed) -----------------------
    ('change', '. dot-repeat', ['aaa', 'bbb'], '1G0xj0.',
     'POSIX vi repeats the last change with "."; implemented '
     '2026-09-05 (vicmd.s record/replay). 1G-prefixed so vim`s '
     'batch oracle does not abort on a last-line j (agent`s note). '
     'Dropped by mistake 2026-10-06 and restored in review: a passing '
     'oracle row is never removed', 'batch'),
    ('change', '"a named register', ['L1', 'L2'], '1G"ayyG"ap',
     'POSIX vi supports named registers a-z; maux implements them '
     '(virg.s, 2026-10-06). `"A`-`"Z` append and `"1`-`"9` are errors',
     'batch'),
    ('change', 'multi-line charwise yank', ['abcXdef', 'ghiYjkl'],
     '1G0y/Y\rG$p',
     'a charwise yank that spans a line boundary (via a search motion) '
     'keeps all the text and p splices it back (viop.s VI_OP_CWY, '
     'virg.s VI_OP_PML; y/ d/ c/ take / ? n N, visearch.s '
     'VI_SMO_PRE/POST)', 'batch'),
]


# ======================================================================
# batch execution against the emulator (3 written files per boot max)
# ======================================================================
def boot_group(client, img):
    r = client.call_tool('reset', {'backend': 'fast', 'aux': 'ramworks'})
    if not r.get('ok'):
        raise RuntimeError(f'reset failed: {r}')
    r = client.call_tool('mount_disk', {'path': img, 'unit': 1})
    if r.get('ok') is False:
        raise RuntimeError(f'mount_disk failed: {r}')
    V.settle(client, V._at_prompt, 'shell prompt after boot',
              max_steps=3000)


def run_case_maux(client, case, letter):
    group, name, setup, keys, note, kind = case
    V.open_vi(client)
    if setup:
        insert_lines(client, setup)
        settle_setup(client, setup)
    if keys:
        type_chunked(client, keys)
    type_chunked(client, ESC)
    V.t(client, ':w /mnt/MAUX/')
    V.t(client, f'OUT{letter}\r')
    # after `:w` the command line returns to BLANK (the status line is
    # transient now, not a persistent banner) -- that is the write-done
    # signal; the file is then read back with a2til.
    V.settle(client, lambda rs: rs[-1].strip() == '',
              f'wrote {name}', max_steps=400)
    V.recover(client)


def process_batch(env, batch, idx):
    """Run <=3 cases against a fresh scratch copy of play.po, then read
    every written file back with a2til. Returns a list, one entry per
    case in `batch`, of (case, got_lines_or_None, harness_err_or_None)."""
    letters = 'ABC'
    img = os.path.join(SCRATCH, f'grp_{idx}.po')
    shutil.copy(DISK, img)
    client = MCPClient([SUPERVISOR], env)
    outcomes = {}
    try:
        boot_group(client, img)
        for i, case in enumerate(batch):
            letter = letters[i]
            try:
                run_case_maux(client, case, letter)
                outcomes[i] = (letter, None)
            except Exception as e:  # noqa: BLE001 -- report, keep going
                outcomes[i] = (None, f'{type(e).__name__}: {e}')
                try:
                    V.recover(client)
                except Exception:
                    pass
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
    for i, case in enumerate(batch):
        letter, herr = outcomes.get(i, (None, 'case did not run'))
        if herr is not None:
            results.append((case, None, herr))
            continue
        if vol is None:
            results.append((case, None,
                             f'a2til open_image failed: {vol_err}'))
            continue
        try:
            raw = bytes(vol.read_file(f'/mnt/MAUX/OUT{letter}'))
            got = bytes(b & 0x7F for b in raw).decode(
                'ascii', errors='replace').split('\r')
            if got and got[-1] == '':
                got = got[:-1]
            results.append((case, got, None))
        except Exception as e:  # noqa: BLE001
            results.append((case, None,
                             f'a2til read_file failed: {type(e).__name__}: {e}'))
    return results


# ======================================================================
# a structural (non-byte-exact) special case: :q! discard semantics
# ======================================================================
def special_qbang(env):
    """POSIX vi's `:q!` discards unsaved edits on a named file. This is
    a MODE/reload check (like check_vi.py's case_quit_bang_discards),
    not a byte-exact oracle diff -- there is no "buffer content" the
    vim oracle would compute here, the assertion is about ex-command
    behavior itself. Runs on its own boot via check_vi's shared-image
    copy-on-write boot(), so it costs no /mnt/MAUX directory entries."""
    client = MCPClient([SUPERVISOR], env)
    try:
        V.boot(client)
        V.open_vi(client, 'PVQD')
        V.t(client, 'iKEEPA\rKEEPB' + ESC)
        V.t(client, ':wq\r')
        V.settle(client, V._at_prompt, 'PVQD written')
        V.open_vi(client, 'PVQD')
        V.settle(client,
                  lambda rs: V.line(rs, 0) == 'KEEPA'
                  and V.line(rs, 1) == 'KEEPB', 'PVQD reopened')
        V.t(client, '1Gdd')
        V.t(client, ':q!\r')
        V.settle(client, V._at_prompt, ':q! discarded and quit')
        V.open_vi(client, 'PVQD')
        V.settle(client,
                  lambda rs: V.line(rs, 0) == 'KEEPA'
                  and V.line(rs, 1) == 'KEEPB',
                  'PVQD unchanged on reopen -- :q! really discarded')
        V.t(client, ESC)
        V.recover(client)
        return True, None
    except AssertionError as e:
        return False, str(e)
    except Exception as e:  # noqa: BLE001
        return False, f'{type(e).__name__}: {e}'
    finally:
        client.close()


# ======================================================================
# main
# ======================================================================
def main():
    global DISK
    if len(sys.argv) > 1:
        DISK = os.path.abspath(sys.argv[1])
    if not os.path.exists(DISK):
        print(f'error: {DISK} not found -- run make play-image first',
              file=sys.stderr)
        return 2
    os.makedirs(SCRATCH, exist_ok=True)
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR

    # rows: (group, name, keys, note, expected, got, harness_err, oracle_err)
    report = []
    batches = [CASES[i:i + 3] for i in range(0, len(CASES), 3)]
    print(f'[check-posixvi] {len(CASES)} byte-exact cases, '
          f'{len(batches)} boot groups')
    for idx, batch in enumerate(batches):
        print(f'[check-posixvi] group {idx + 1}/{len(batches)} '
              f'({len(batch)} cases)')
        res = process_batch(env, batch, idx)
        for case, got, herr in res:
            group, name, setup, keys, note, kind = case
            try:
                expected = oracle(case)
                oerr = None
            except Exception as e:  # noqa: BLE001
                expected = None
                oerr = f'{type(e).__name__}: {e}'
            report.append((group, name, keys, note, expected, got,
                            herr, oerr))

    print('[check-posixvi] special: :q! discard (structural, not '
          'byte-exact)')
    ok, serr = special_qbang(env)
    report.append((
        'ex', ':q! discards unsaved edits (named file, structural)',
        ':wq / 1Gdd / :q! / reopen',
        'checked structurally (buffer reload after :q!), not diffed '
        'against the vim oracle -- there is no buffer-content '
        'expectation to compute here',
        'KEEPA/KEEPB survive the discard',
        'KEEPA/KEEPB survive the discard' if ok else 'discard failed',
        None if ok else serr, None))

    print()
    by_group = {}
    for row in report:
        by_group.setdefault(row[0], []).append(row)
    fails = []
    total = len(report)
    for group in sorted(by_group):
        print(f'== {group} ({len(by_group[group])} cases) ==')
        for (g, name, keys, note, expected, got, herr, oerr) in \
                by_group[group]:
            passed = herr is None and oerr is None and got == expected
            status = 'PASS' if passed else 'FAIL'
            if not passed:
                fails.append((group, name, keys, note, expected, got,
                              herr, oerr))
            print(f'  {status} {name}  keys={keys!r}')
            if not passed:
                if oerr:
                    print(f'       oracle error: {oerr}')
                else:
                    print(f'       expected: {expected!r}')
                if herr:
                    print(f'       harness error: {herr}')
                elif not oerr:
                    print(f'       got:      {got!r}')
                if note:
                    print(f'       note: {note}')
    print()
    print(f'[check-posixvi] {total - len(fails)}/{total} cases passed, '
          f'{len(fails)} FAILED')
    if fails:
        print(f'[check-posixvi] FAIL ({len(fails)}/{total} cases):',
              file=sys.stderr)
        for (group, name, keys, note, expected, got, herr, oerr) \
                in fails:
            print(f'  {group}: {name}  keys={keys!r}', file=sys.stderr)
            if oerr:
                print(f'    oracle error: {oerr}', file=sys.stderr)
            else:
                print(f'    expected={expected!r} got={got!r}',
                      file=sys.stderr)
            if herr:
                print(f'    harness error: {herr}', file=sys.stderr)
        return 1
    print(f'[check-posixvi] PASS -- {total} POSIX vi conformance '
          f'cases green')
    return 0


if __name__ == '__main__':
    sys.exit(main())
