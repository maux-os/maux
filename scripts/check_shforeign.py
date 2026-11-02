#!/usr/bin/env python3
"""check_shforeign.py -- a script in the system's standard text
convention (ProDOS TXT: low ASCII, `$0D` line ends) RUNS under sh
(`make check-shforeign`, docs/SH-FOREIGN.md).

The fixtures are staged onto a copy of the play image with a2til
(`prodos.write`, file type $04) -- no typed line can make a low byte --
and run with `sh F`, `. F` and `sh < F`.

Two independent defects, one fix site (RL_PHYS's file path folds each
byte to the high form as it scans, so the separators ($20/$09 -> $A0/
$89) and the terminator ($0D -> $8D) are both right):

  * the separator set is spelled high ($A0,$89,$8D) and a low `$20`
    is, inside sh, the "literal, do not split" marker;
  * the reader ends a line on `$8D` only.

WHAT EACH ROW ASSERTS.  The exact list of rows below the command's own
echo, and for the "did it RUN" rows a file the script wrote, read back
with `cat`: the console forges a row break on a file's own `$0D`, so a
script that was read as ONE line prints `echo B` as text and looks nearly
right.  Every file has TWO lines minimum (a one-line fixture cannot test
a terminator: no CR in the chunk takes the unterminated-final-line path).

The pipe path is the SH-NLVAR carrier (a bit-7-CLEAR `$0D` is data
there) and is deliberately NOT folded; check-shnlvar pins that.

Teeth: scripts/teeth_shforeign.py.  ASCII only.
Exit 0 green, 1 red (listed), 2 rig problem.
"""
import argparse
import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_shfd as F  # noqa: E402
import check_devfs as D  # noqa: E402
from mcp_drive import MCPClient, ROMS_DIR, SUPERVISOR  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

M = '/mnt/MAUX/'


def lo(text):
    """ProDOS semantics (a2til's house definition): low ASCII, `$0D`."""
    from a2til import convert
    return convert.text_from_host(text.encode('ascii'))


# bit 7 set on every 7-bit byte (a translate table; check_encoding
# pins how many scripts set the bit by hand)
HIGH = bytes.maketrans(bytes(range(128)), bytes(range(128, 256)))


def hi(text):
    """maux semantics: bit 7 set on every byte, lines end `$8D`."""
    return lo(text).translate(HIGH)


def mixed(text):
    """High-bit CONTENT, low `$0D` line ends: renders nearly right."""
    return b'\r'.join(p.translate(HIGH) for p in lo(text).split(b'\r'))


A2 = 'echo A\necho B\n'
FILES = {
    'FA2LO': lo(A2),                       # everything low
    'FA2MX': mixed(A2),                    # content high, $0D ends
    'FA2HI': hi(A2),                       # the control: maux's own
    'FA2HL': hi('echo A\n') + lo('echo B\n'),   # polarity changes
    'FSEP': lo('echo -n x\necho y\n'),     # the inter-argument $20
    'FRAN': lo('echo A\necho B > ' + M + 'RAN\n'),
    'FQV': lo('X=hi\necho "a  b" $X\n'),   # quotes, a var, no split
    'FTAB': lo('echo a\tb\n'),             # $09 splits
    'FTABH': hi('echo a\tb\n'),          # its high control
    'FSHE': lo('#!/bin/sh\necho A\necho B\n'),   # exec by #!
    'FSHEH': hi('#!/bin/sh\necho A\necho B\n'),  # ... high control
    'FDEF': lo('A=1\nB=2\necho $A$B\n'),
    # 255 bytes + CR: the CR is the 256th byte of the chunk.
    'FL255': lo('echo ' + 'x' * 244 + '|wc -c\necho B\n'),
}


def stage(boot):
    assert FILES['FA2LO'] == b'echo A\recho B\r', FILES['FA2LO']
    assert FILES['FA2MX'] == bytes.fromhex('e5e3e8efa0c10de5e3e8efa0c20d')
    assert FILES['FA2HI'] == bytes.fromhex('e5e3e8efa0c18de5e3e8efa0c28d')
    prodos.mount(boot, replace=True)
    try:
        for name, body in FILES.items():
            prodos.write(M + name, body, file_type=0x04, aux_type=0,
                         overwrite=True)
    finally:
        prodos.unmount('MAUX')


# maux's tokenizer keeps a tab inside a word (its own text does too):
# the low row must match the high control, whatever that is.
TABOUT = 'a       b'

# (label, [typed lines], want-rows)
ROWS = [
    ('S1 two low lines run (sh F)', ['sh ' + M + 'FA2LO'], ['A', 'B']),
    ('S2 content high, $0D ends: BOTH run (sh F)',
     ['sh ' + M + 'FA2MX'], ['A', 'B']),
    ('S3 control: maux text (sh F)', ['sh ' + M + 'FA2HI'], ['A', 'B']),
    ('S4 polarity changes between lines',
     ['sh ' + M + 'FA2HL'], ['A', 'B']),
    ('S5 the inter-argument $20 splits: -n is a flag',
     ['sh ' + M + 'FSEP'], ['xy']),
    ('S6 line 2 RAN (it wrote a file), not just printed',
     ['sh ' + M + 'FRAN', 'cat ' + M + 'RAN', 'rm ' + M + 'RAN'],
     ['A', 'B']),
    ('S7 quotes keep a double space; a var expands',
     ['sh ' + M + 'FQV'], ['a  b hi']),
    ('S8 a $09: same as maux text (control)',
     ['sh ' + M + 'FTABH'], [TABOUT]),
    ('S8b a low $09: same as the control',
     ['sh ' + M + 'FTAB'], [TABOUT]),
    ('S9 assignments across low lines',
     ['sh ' + M + 'FDEF'], ['12']),
    ('S9b exec by #! (maux text, control)', [M + 'FSHEH'], ['A', 'B']),
    ('S9c exec by #! (low text)', [M + 'FSHE'], ['A', 'B']),
    ('S10 sourced: . F', ['. ' + M + 'FA2LO'], ['A', 'B']),
    ('S11 sourced, content high', ['. ' + M + 'FA2MX'], ['A', 'B']),
    ('S12 stdin is a file: sh < F', ['sh < ' + M + 'FA2LO'], ['A', 'B']),
    ('S13 a 255-byte low line, then the next',
     ['sh ' + M + 'FL255'], ['245', 'B']),
]


def run_rows(client, failures, only=None):
    for label, lines, want in ROWS:
        if only and not label.startswith(only):
            continue
        got = []
        for line in lines:
            out = F.typed(client, line, label, failures)
            if out is None:
                got = None
                break
            got.extend(out)
        if got is None:
            continue
        D.assert_eq(label, got, want, failures)


def run(play, failures, only=None):
    tmp = tempfile.mkdtemp(prefix='maux-shforeign-')
    try:
        boot = os.path.join(tmp, 'play.po')
        shutil.copy(play, boot)
        stage(boot)
        env = dict(os.environ, VERILOGAPPLE_ROMS=ROMS_DIR)
        client = MCPClient([SUPERVISOR], env)
        try:
            client.initialize()
            client.call_tool('reset', {'backend': 'fast'})
            r = client.call_tool('mount_disk', {'path': boot, 'unit': 1})
            if r.get('ok') is False:
                raise RuntimeError(f'mount_disk(unit 1) failed: {r}')
            for addr, val in ((D.PT_F40_ADDR, D.PT_F40_MAG1),
                              (D.PT_F40B_ADDR, D.PT_F40_MAG2)):
                client.call_tool('poke', {'addr': addr, 'bytes': [val],
                                          'bank': 'main'})
            D.wait_for_screen(client, D.prompt_ready, 'shell prompt')
            run_rows(client, failures, only)
        finally:
            client.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--play', default=os.path.join(ROOT, 'build',
                                                   'play.po'))
    ap.add_argument('--rows', default=None,
                    help='run only rows whose label starts with this')
    args = ap.parse_args()
    play = os.path.abspath(args.play)
    if not os.path.exists(play):
        print(f'check-shforeign: {play} missing -- make play-image')
        return 2
    failures = []
    t0 = time.time()
    try:
        run(play, failures, args.rows)
    except RuntimeError as exc:
        failures.append(str(exc))
    if failures:
        print(f'[check-shforeign] FAIL: {len(failures)} row(s)')
        for x in failures:
            print(f'  - {x}'.replace('\n', '\n    '))
        return 1
    print(f'[check-shforeign] PASS: a ProDOS-standard text script runs '
          f'({time.time() - t0:.0f} s)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
