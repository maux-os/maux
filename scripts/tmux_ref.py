#!/usr/bin/env python3
"""tmux_ref.py -- render a byte stream on a real terminal emulator (tmux)
and print the result as JSON: the reference glass for check-partition's
reference rows (fixtures/partition/PROVENANCE.md). NOT run by any gate:
the box has no tmux, so the output is committed beside the stream.

  python3 scripts/tmux_ref.py STREAM.bin > STREAM.ref.json

JSON: {"rows": [24 strings of 80 chars], "rev": [24 strings of 80 chars,
'1' where the cell is reverse video], "cursor": [row, col]}.
Needs tmux (3.x) on PATH. The pane is 80x24 and TERM inside is whatever
tmux sets; the stream is fed through `cat` on a tty with output
processing off, so tmux sees exactly the stream's bytes.
"""
import json
import re
import subprocess
import sys
import time

SESSION = 'tmuxref'


def tm(*a):
    return subprocess.run(['tmux', *a], capture_output=True, text=True,
                          check=True).stdout


def render(path):
    subprocess.run(['tmux', 'kill-session', '-t', SESSION],
                   capture_output=True)
    tm('new-session', '-d', '-s', SESSION, '-x', '80', '-y', '24',
       f"stty -opost; cat '{path}'; sleep 60")
    try:
        time.sleep(1.0)
        txt = tm('capture-pane', '-p', '-t', SESSION).split('\n')
        esc = tm('capture-pane', '-p', '-e', '-t', SESSION).split('\n')
        cur = tm('display-message', '-p', '-t', SESSION,
                 '#{cursor_y} #{cursor_x}').split()
    finally:
        tm('kill-session', '-t', SESSION)
    rows = [(txt[i] if i < len(txt) else '').ljust(80) for i in range(24)]
    rev = []
    for i in range(24):
        line = esc[i] if i < len(esc) else ''
        mask, on, pos = [], False, 0
        for m in re.finditer(r'\x1b\[([0-9;]*)m|(.)', line):
            if m.group(2) is None:
                for p in (m.group(1) or '0').split(';'):
                    p = int(p or 0)
                    if p == 0 or p == 27:
                        on = False
                    elif p == 7:
                        on = True
            else:
                mask.append('1' if on else '0')
        rev.append(''.join(mask).ljust(80, '0'))
    return {'rows': rows, 'rev': rev, 'cursor': [int(cur[0]), int(cur[1])]}


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    print(json.dumps(render(sys.argv[1]), indent=0))
