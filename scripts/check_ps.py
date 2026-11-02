#!/usr/bin/env python3
"""check_ps.py -- `ps` shows each process's arguments (`make check-ps`,
docs/PS-ARGS.md, docs/PS-ARGS-NOTES.md).

SYS_PSTAT's slot byte carries a mode (bits 6-7): 0 the head record,
1 the raw 320 bytes at the target's $0200, 2 its spawn pathname tag.
ps validates the block and joins it; the kernel only moves bytes.  Two
boots of the play image (a2til writes the fixtures into /TMP), typed at
the shell the way a person types it.  The console is 40 columns, so
COMMAND is cut at 40 - 18 = 22 characters.

  Boot A (run)
  1. `sleep 30 &` shows `sleep 30`; a 3-stage background pipeline shows
     each stage's OWN argv in pid order; the shell shows `sh`
  2. /tmp/clob overwrites $0200-$03FF with $41: the row is `(clob)`
  3. /tmp/spin with a 100-character command line: cut at exactly 22
     characters, no row wraps; into a file (not a console) cut at 63
  4. the kernel moves exactly what it says: a probe BIN calls SYS_PSTAT
     in each mode into a buffer fenced with $5A and exits with the byte
     just past the answer: 90 for modes 0, 1 and 2
  Boot B (run_b; the pool holds 15 processes)
  5. kernel-made processes (PPID 0) show [init] and [idle], unread
  6. hostile blocks: argv[0] = ESC [2J in low and in high polarity show
     `(esclo)` and `(eschi)` and the glass is not cleared; a forged
     well-formed block shows its text (`HI`)
  7. an empty argv[0] falls back to `(empty0)`; a trailing empty
     argument leaves `A`, never a trailing space
  8. a REAL zombie: /tmp/nowait spawns /bin/true and never waits; the
     child shows `Z` and `<defunct>`
  9. the head record is PID STATE WCHAN BANK PARENT EXITSTAT of that
     PCB byte for byte (peeked from the annex), so SAVEDSP is not in it

Teeth (docs/PS-ARGS-NOTES.md sec 4): join only argv[0]; drop validation;
delete the printable test (and #$7F / cmp #$20 / cmp #$7F) alone;
one byte past the field; SAVEDSP for EXITSTAT in the head record.

ASCII only.  Exit 0 green, 1 red (listed), 2 rig problem.
"""
import argparse
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import check_devfs as D  # noqa: E402
import check_exec as X  # noqa: E402
import check_mount as M  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PCB_BASE = 0x0800           # annex bank 0, 16 bytes a pid
PCB_STATE = 1
ZOMBIE = 4
COLS = 40
CMDW = COLS - 18            # the console's COMMAND width
CMDMAX = 63

# overwrites its own argv block ($0200-$03FF) with $41, then spins
CLOB = bytes([0xA2, 0x00, 0xA9, 0x41, 0x9D, 0x00, 0x02, 0x9D, 0x00, 0x03,
              0xE8, 0xD0, 0xF7, 0x4C, 0x0D, 0x08])
SPIN = bytes([0x4C, 0x00, 0x08])            # jmp $0800


def probe(slot_mode, length, spin=False):
    """A BIN that fences $0900-$0AFF with $5A, calls SYS_PSTAT(slot_mode)
    into $0900, and exits with the byte at $0900+length (90 = untouched),
    or with 1 if the call failed.  spin=True: spins after the call
    instead, so the gate can peek the answer out of its bank."""
    sentinel = 0x0900 + length
    code = bytes([
        0xA2, 0x00, 0xA9, 0x5A,                    # ldx #0 / lda #$5A
        0x9D, 0x00, 0x09, 0x9D, 0x00, 0x0A,        # sta $0900,x / $0A00,x
        0xE8, 0xD0, 0xF7,                          # inx / bne
        0xA9, 0x80, 0xA2, 0x08, 0xA0, 0x06,        # parms $0880, SYS_PSTAT
        0x20, 0x00, 0xFF,                          # jsr $FF00
        0x90, 0x04,                                # bcc ok
        0xA9, 0x01, 0x80, 0x03,                    # lda #1 / bra exit
        0xAD, sentinel & 0xFF, sentinel >> 8,      # ok: lda sentinel
        0x8D, 0x90, 0x08,                          # exit: sta $0890
        0xA9, 0x90, 0xA2, 0x08, 0xA0, 0x02,        # parms $0890, SYS_EXIT
        0x20, 0x00, 0xFF])
    if spin:
        code = code[:22] + bytes([0x4C, (0x0800 + 22) & 0xFF, 0x08])
    img = bytearray(0x91)
    img[0:len(code)] = code
    img[0x80:0x83] = bytes([slot_mode, 0x00, 0x09])
    return bytes(img)


def block(pairs):
    """A BIN that stores each (addr, byte) and spins: a process that
    forged its own argv block."""
    code = bytearray()
    for addr, val in pairs:
        code += bytes([0xA9, val, 0x8D, addr & 0xFF, addr >> 8])
    j = 0x0800 + len(code)
    return bytes(code + bytes([0x4C, j & 0xFF, j >> 8]))


def esc(first):
    """argv = ["<first>[2J"]: an escape sequence that would clear the
    glass if ps printed it (first = ESC, low or high bit)."""
    return block([(0x0200, 1), (0x0201, 0), (0x0202, 3), (0x0300, first),
                  (0x0301, 0xDB), (0x0302, 0xB2), (0x0303, 0xCA),
                  (0x0304, 0)])


def nowait():
    """A BIN that spawns /bin/true and never waits: a REAL zombie."""
    path = bytes.fromhex('afe2e9eeaff4f2f5e5') + b'\x00'   # /bin/true
    img = bytearray(0x100)
    code = bytes([0xA9, 0x80, 0xA2, 0x08, 0xA0, 0x01,   # SYS_SPAWN
                  0x20, 0x00, 0xFF, 0x4C, 0x09, 0x08])
    img[0:len(code)] = code
    img[0xA0:0xA0 + len(path)] = path
    img[0x80:0x88] = bytes([0xA0, 0x08, 0xB0, 0x08, 0, 0, 0, 0])
    img[0xB0:0xB4] = bytes([0xA0, 0x08, 0, 0])
    return bytes(img)


FIXTURES = {
    '/TMP/CLOB': (CLOB, 0x06),
    '/TMP/SPIN': (SPIN, 0x06),
    '/TMP/PROBE0': (probe(0x01, 6), 0x06),          # head of pid 1
    '/TMP/PROBE1': (probe(0x41, 320), 0x06),        # block of pid 1
    '/TMP/PROBE2': (probe(0x80 | 4, 65), 0x06),     # tag of pid 4 (spin)
    '/TMP/PROBE0S': (probe(0x01, 6, spin=True), 0x06),
    '/TMP/ESCLO': (esc(0x1B), 0x06),
    '/TMP/ESCHI': (esc(0x9B), 0x06),
    '/TMP/OKTXT': (block([(0x0200, 1), (0x0201, 0), (0x0202, 3),
                          (0x0300, 0xC8), (0x0301, 0xC9),
                          (0x0302, 0)]), 0x06),
    '/TMP/EMPTY0': (block([(0x0200, 1), (0x0201, 0), (0x0202, 3),
                           (0x0300, 0)]), 0x06),
    '/TMP/TRAIL': (block([(0x0200, 2), (0x0201, 0), (0x0202, 3),
                          (0x0203, 2), (0x0204, 3), (0x0300, 0xC1),
                          (0x0301, 0), (0x0302, 0)]), 0x06),
    '/TMP/NOWAIT': (nowait(), 0x06),
}


def clear(client):
    """^L at the prompt clears the glass, so a command's echo and output
    are the only rows on it (a table must not scroll its own echo off)."""
    client.call_tool('type', {'text': '\x0c'})
    client.call_tool('step', {'cycles': 400_000})


def sh(client, cmd, label, f, steps=3000):
    """Clear, type `cmd`, wait until its echo is on the glass AND a bare
    prompt follows it; return the rows between.  (M.sh can see the OLD
    bare prompt before the new echo is painted and return early.)"""
    clear(client)
    client.call_tool('type', {'text': cmd + '\r'})
    echo = ('$' + cmd, '$ ' + cmd)
    rows = []
    for _ in range(steps):
        client.call_tool('step', {'cycles': 200_000})
        rows = [r.rstrip() for r in D.screen_rows(client) if r.strip()]
        if (len(rows) >= 2 and rows[-1] == '$'
                and any(r in echo for r in rows[:-1])):
            at = [i for i, r in enumerate(rows) if r in echo][-1]
            return rows[at + 1:-1]
    f.append(f'{label}: no echo + prompt for {cmd!r}; glass: {rows}')
    return []


def psrows(client, cmd, label, f):
    """Run `cmd` (a ps) and return ([header], [(pid, state, bank, ppid,
    command)])."""
    out = sh(client, cmd, label, f)
    rows = []
    for r in out[1:]:
        p = r.split(None, 4)
        if len(p) >= 4 and p[0].isdigit():
            rows.append((int(p[0]), p[1], p[2], int(p[3]),
                         p[4] if len(p) > 4 else ''))
        else:
            f.append(f'{label}: row {r!r} is not `PID S BANK PPID COMMAND`')
    return out[:1], rows


def cmds(rows):
    return [r[4] for r in rows]


def eq(label, got, want, failures):
    if got != want:
        failures.append(f'{label}: got {got!r}, want {want!r}')
    else:
        print(f'[check-ps] PASS {label}: {got!r}')


def status(client, f, label):
    out = sh(client, 'echo $?', label + ' status', f)
    return out[-1] if out else None


def run(client, f):
    # -- the jobs ----------------------------------------------------------
    sh(client, 'A=aaaaaaaaaabbbbbbbbbbcccccccccc', 'A', f)
    sh(client, '/tmp/spin $A $A $A >/dev/null &', 'bg spin', f)   # pid 4
    sh(client, 'sleep 30 >/dev/null &', 'bg sleep', f)
    sh(client, 'sleep 91|sleep 92|sleep 93 >/tmp/q &', 'bg pipe', f)
    sh(client, '/tmp/clob >/dev/null &', 'bg clob', f)
    sh(client, '( sleep 200; true ) >/dev/null &', 'bg subshell', f)
    client.call_tool('step', {'cycles': 8_000_000})   # the subshell's child
    head, rows = psrows(client, 'ps', 'ps', f)
    eq('header', head, [' PID S BANK PPID COMMAND'], f)
    by = {}
    for r in rows:
        by.setdefault(r[4], []).append(r)
    # 1 / 3 / 8: the simple rows, in pid order
    eq('1/2/3/4/5/8: every row, in pid order, as ps prints it',
       cmds(rows),
       ['[init]', '[idle]', 'sh', '/tmp/spin aaaaaaaaaabb', 'sleep 30',
        'sleep 91', 'sleep 92', 'sleep 93', '(clob)', 'sh', 'sleep 200',
        'ps'], f)
    # pipeline stages are three consecutive pids, children of the shell
    pipe = [r for r in rows if r[4] in ('sleep 91', 'sleep 92', 'sleep 93')]
    eq('2: the pipeline stages are consecutive pids of one parent',
       ([r[0] - pipe[0][0] for r in pipe], [r[3] for r in pipe]),
       ([0, 1, 2], [3, 3, 3]), f)
    long_ = by.get('/tmp/spin aaaaaaaaaabb', [])
    eq('5: the long command line is cut at exactly the console width',
       [len(r[4]) for r in long_], [CMDW], f)
    eq('5: no row wrapped (every printed row fits the console)',
       [len(r[4]) <= CMDW for r in rows], [True] * len(rows), f)
    # 6: not a console
    sh(client, 'ps > /tmp/o', 'ps file', f)
    out = sh(client, 'grep spin /tmp/o | wc -c', 'wc', f)
    eq('6: into a file, COMMAND is cut at 63 (17 + 63 + the newline)',
       [o.strip() for o in out][:1], [str(17 + CMDMAX + 1)], f)
    # 9: the kernel's answer is exactly as long as it says
    for name, what in (('probe0', 'head record (6 B)'),
                       ('probe1', 'argv block (320 B)'),
                       ('probe2', 'spawn tag (65 B)')):
        sh(client, f'/tmp/{name}', name, f)
        eq(f'9: {what}: the byte past the end is untouched (90)',
           status(client, f, name), '90', f)


def run_b(client, f):
    """A second boot (the bank pool holds 15 processes): forged and
    hostile argv blocks, a real zombie, and the head record's bytes."""
    for n in ('esclo', 'eschi', 'oktxt', 'empty0', 'trail', 'nowait'):
        sh(client, f'/tmp/{n} >/dev/null &', n, f)
    sh(client, '/tmp/probe0s >/dev/null &', 'probe0s', f)
    client.call_tool('step', {'cycles': 8_000_000})
    _, rows = psrows(client, 'ps', 'ps b', f)
    by = {}
    for r in rows:
        by.setdefault(r[4], []).append(r)
    eq('8: kernel-made processes are bracketed, never read',
       [(r[0], r[4]) for r in rows if r[3] == 0],
       [(1, '[init]'), (2, '[idle]')], f)
    eq('4a: ESC [2J as argv[0], low and high polarity: falls back to '
       'the name, and the glass is not cleared',
       [c for c in cmds(rows) if c.startswith('(esc')],
       ['(esclo)', '(eschi)'], f)
    eq('4a: a well-formed forged block shows its text',
       'HI' in cmds(rows), True, f)
    eq('3: an empty argv[0] falls back, a trailing empty arg does not '
       'leave a bare space',
       ('(empty0)' in cmds(rows), 'A' in cmds(rows)), (True, True), f)
    eq('3: no row ends in a space', [c for c in cmds(rows)
                                    if c.endswith(' ')], [], f)
    # 4b: a real zombie: nowait spawned /bin/true and never waits
    parent = [r for r in rows if r[4] == '/tmp/nowait']
    zom = [r for r in rows if r[1] == 'Z']
    eq('4b: the real zombie: Z, <defunct>, child of /tmp/nowait',
       [(r[1], r[4], r[3]) for r in zom],
       [('Z', '<defunct>', parent[0][0] if parent else -1)], f)
    # 4c: probe0's six head bytes against the PCB itself
    pr = [r for r in rows if r[4] == '/tmp/probe0s']
    if len(pr) != 1:
        f.append(f'4c: no unique probe0s row: {pr}')
        return
    got = peek_n(client, 0x0900, 6, 'aux', int(pr[0][2], 16))
    pcb = peek_n(client, PCB_BASE + 16, 7, 'aux', 0)
    eq('4c: the head record is PID STATE WCHAN BANK PARENT EXITSTAT of '
       'that PCB (SAVEDSP is not in it)',
       got, pcb[:5] + [pcb[6]], f)
    eq('4c: the fixture can tell SAVEDSP from EXITSTAT (else vacuous)',
       pcb[5] != pcb[6], True, f)


def peek_n(client, addr, n, bank, aux_bank):
    r = client.call_tool('peek', {'addr': addr, 'count': n, 'bank': bank,
                                  'aux_bank': aux_bank})
    return list(r.get('bytes') or r.get('data'))


def peek(client, addr):
    r = client.call_tool('peek', {'addr': addr, 'count': 1, 'bank': 'aux',
                                  'aux_bank': 0})
    return (r.get('bytes') or r.get('data'))[0]


def poke(client, addr, byte):
    client.call_tool('poke', {'addr': addr, 'bytes': [byte], 'bank': 'aux',
                              'aux_bank': 0})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--play', default=os.path.join(ROOT, 'build',
                                                   'play.po'))
    args = ap.parse_args()
    play = os.path.abspath(args.play)
    if not os.path.exists(play):
        print(f'check-ps: {play} missing -- make play-image')
        return 2
    failures = []
    tmp = tempfile.mkdtemp(prefix='maux-ps-')
    try:
        boot = os.path.join(tmp, 'play.po')
        shutil.copy(play, boot)
        X.stage(boot, FIXTURES)
        for part in (run, run_b):
            client = X.boot_client(boot)
            try:
                part(client, failures)
            except RuntimeError as exc:
                failures.append(str(exc))
            finally:
                client.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if failures:
        print(f'[check-ps] FAIL: {len(failures)} row(s)')
        for x in failures:
            print(f'  - {x}'.replace('\n', '\n    '))
        return 1
    print('[check-ps] PASS: ps shows each process\'s arguments')
    return 0


if __name__ == '__main__':
    sys.exit(main())
