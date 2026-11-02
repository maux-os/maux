#!/usr/bin/env python3
"""check_fdact.py -- spawn fdactions validation gate (docs/DUPFD-1.md,
phase K).

src/test/fdatestb.s spawns lists that are bad in every way the kernel now
refuses; this script holds the expected values and, at three handshakes
the guest raises, reads the KERNEL'S OWN cells so "nothing was created"
is measured, not inferred from an errno:

  handshake 1  before any spawn: the baseline, the vacuity guards (the
               PCB poison is there; fd 3/4 open, 5/6/7 closed), and the
               PRC_PAR_PID poison poked (see below);
  handshake 2  after the positive lists were spawned and reaped;
  handshake 3  after every bad list on the builtin path;
  handshake 4  ... and on the file path.

K1 K2 K3 K4 K7 are the errno rows (every bad list answers ERR_INVAL, on
both PRC_BLTN branches); K5 is the S2 == S3 comparison (free-bank list,
the PCB table, every OFT refcount, LZ_WANT); K6 is the positive rows. K4
is carried by the same comparison: a kernel that replays record 1 and
THEN finds record 2 bad leaves the pipe's read end one reference up.

PRC_PAR_PID is stale at validation time (it is only set after a bank is
allocated). The kernel's own cell holds 0 after boot; this gate pokes it
to a slot nobody owns at handshake 1, so the first spawn after it -- a
GOOD list with a dup in it -- fails if the validator read PRC_PAR_PID
instead of K_CURPID. Later spawns overwrite the cell, which is exactly
why the poke comes BEFORE the first one and why that one is the dup.

TEETH: scripts/teeth_fdact.py (and the notes in docs/DUPFD-1-NOTES.md).
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_race as GR                                    # noqa: E402
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR     # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# --plain: the spawnpl.s twin (fdatestp): bad lists only
PLAIN = '--plain' in sys.argv
ARGS = [a for a in sys.argv[1:] if a != '--plain']
LISTING = os.path.join(ROOT, 'build',
                       'fdatestp.bin_Output.txt' if PLAIN
                       else 'fdatest.bin_Output.txt')

R_POS_ERR = 0x1100
R_POS_PID = 0x1110
R_POS_ST = 0x1120
R_BADV = 0x1140
R_BADF = 0x1170
R_PIPE = 0x11E0
R_FIN_ERR = 0x11D0
R_FIN_ST = 0x11D1
R_DONE = 0x11F0
R_ERR = 0x11F1
R_STATE = 0x11F2
R_GO = 0x11F3

PCB_BASE = 0x0800          # aux bank 0
PCB_ENT = 16
PCB_COUNT = 48
PCB_BRK = 7
PCB_FDTABLE = 8
POISON = 0x0B              # fdatestb.s POISON
PAR_PID_POISON = 0x2F      # a slot nobody owns
ERR_INVAL = 0xE1
CHILD_ST = 0x5A

POSITIVES_ALL = [
    'P0 DUP 5<-3 (a pipe fd)',
    'P1 CLOSE 7, source byte $FF (reserved: not judged)',
    'P2 NULL list',
    'P3 DUP 0<-3, DUP 1<-4',
    'P4 32 x CLOSE 7 + END (the last legal length)',
]
POSITIVES = [] if PLAIN else POSITIVES_ALL
BADS = [
    'B0  DUP 4<-5 (fd 5 closed)                        K1',
    'B1  DUP 0<-7 (fd 7 closed)                        K1',
    'B2  DUP source 8                                  K2',
    'B3  DUP source $FF                                K2',
    'B4  DUP target 8                                  K2',
    'B5  DUP target $FF                                K2',
    'B6  CLOSE target 8                                K2',
    'B7  CLOSE target $FF                              K2',
    'B8  opcode 3                                      K3',
    'B9  opcode $FF                                    K3',
    'B10 CLOSE 7 then opcode 3                         K3',
    'B11 33 x CLOSE 7 + END (one past the bound)       K3',
    'B12 DUP target 8, source 0 (primes a stale zero)  K2',
    'B13 list pointer $C000: opcode unreadable         K3',
    'B14 DUP at $BFFE: source byte at $C000            K3',
    'B15 DUP 4<-0 at $BFFD: next opcode at $C000       K3',
    'B16 DUP 4<-3 then DUP 6<-7 (closed)               K4',
    'B17 DUP 4<-3 then opcode 3                        K4',
    'B18 DUP 4<-3 then CLOSE 8                         K4',
    'B19 255 x $02, no END (unbounded walk)            K3',
]
PATHS = ([('plain path V (spawnpl.s)', R_BADV),
          ('plain file path /BIN/X (LZ_WANT_SET)', R_BADF)] if PLAIN
         else [('builtin path V (PRC_BLTN carry set)', R_BADV),
               ('file path /BIN/X (reaches LZ_WANT_SET)', R_BADF)])


def sym(name):
    pat = re.compile(r'\|\s*00/([0-9A-F]{4})[^|]*\|\s*' + name + r'\b')
    with open(LISTING, encoding='ascii', errors='replace') as fh:
        for line in fh:
            m = pat.search(line)
            if m:
                return int(m.group(1), 16)
    raise RuntimeError(f'{name} not found in {LISTING}')


def peek(c, addr, count=1, bank='main', aux_bank=None):
    a = {'addr': addr, 'count': count, 'bank': bank}
    if aux_bank is not None:
        a['aux_bank'] = aux_bank
    r = c.call_tool('peek', a)
    return r.get('bytes') or r.get('data')


def poke(c, addr, byte, bank='main', aux_bank=None):
    a = {'addr': addr, 'bytes': [byte], 'bank': bank}
    if aux_bank is not None:
        a['aux_bank'] = aux_bank
    c.call_tool('poke', a)


def par(c, addr, n=1):
    """Parent (pid 1, bank 1) memory."""
    return peek(c, addr, n, 'aux', 1)


def snapshot(c, cells):
    """Everything the kernel could have leaked into, as plain bytes."""
    return {
        'pcb': bytes(peek(c, PCB_BASE, PCB_ENT * PCB_COUNT, 'aux', 0)),
        'free_cnt': peek(c, cells['PRC_FREE_CNT'], 1)[0],
        'free_list': bytes(peek(c, cells['PRC_FREE_LIST'], 16)),
        'oft_type': bytes(peek(c, cells['OFT_TYPE'], 16)),
        'oft_pipe': bytes(peek(c, cells['OFT_PIPE'], 16)),
        'oft_ref': bytes(peek(c, cells['OFT_REFCNT'], 16)),
        'lz_want': peek(c, cells['LZ_WANT'], 1)[0],
    }


def diff(a, b):
    out = []
    for k in a:
        if a[k] == b[k]:
            continue
        if isinstance(a[k], bytes):
            idx = [i for i in range(len(a[k])) if a[k][i] != b[k][i]]
            if k == 'pcb':
                what = ', '.join(f'pid {i // PCB_ENT} +{i % PCB_ENT}: '
                                 f'{a[k][i]:02X}->{b[k][i]:02X}'
                                 for i in idx[:12])
            else:
                what = ', '.join(f'[{i}] {a[k][i]:02X}->{b[k][i]:02X}'
                                 for i in idx[:12])
            out.append(f'{k}: {what}')
        else:
            out.append(f'{k}: {a[k]:02X} -> {b[k]:02X}')
    return out


def main():
    disk = ARGS[0] if ARGS else ('build/fdatestp.po' if PLAIN
                                 else 'build/fdatest.po')
    if not os.path.exists(disk):
        print(f'[check-fdact] FAIL: {disk} not found', file=sys.stderr)
        return 1
    cells = {n: sym(n) for n in ('PRC_FREE_CNT', 'PRC_FREE_LIST',
                                 'OFT_TYPE', 'OFT_PIPE', 'OFT_REFCNT',
                                 'LZ_WANT', 'PRC_PAR_PID')}
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    c = MCPClient([SUPERVISOR], env)
    ok = True

    def check(cond, what):
        nonlocal ok
        if cond:
            print(f'[check-fdact] PASS: {what}')
        else:
            print(f'[check-fdact] FAIL: {what}', file=sys.stderr)
            ok = False

    try:
        c.initialize()
        c.call_tool('reset', {'backend': 'fast'})
        r = c.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        if r.get('ok') is False:
            print(f'[check-fdact] FAIL: mount_disk {r}', file=sys.stderr)
            return 1

        snaps = {}

        def wait_state(n):
            for _ in GR.polls(c, 400):
                if par(c, R_STATE)[0] == n:
                    return True
                if par(c, R_DONE)[0] == 0xEE:
                    break
            return False

        # ---- handshake 1: baseline, vacuity guards, PAR_PID poison
        if not wait_state(1):
            print('[check-fdact] FAIL: the guest never reached '
                  'handshake 1', file=sys.stderr)
            return 1
        snaps[1] = snapshot(c, cells)
        pcb = snaps[1]['pcb']
        p1 = pcb[PCB_ENT:2 * PCB_ENT]
        p2 = pcb[2 * PCB_ENT:3 * PCB_ENT]
        fdt = list(p1[PCB_FDTABLE:PCB_FDTABLE + 8])
        check(p1[PCB_BRK] == POISON and p2[0] == POISON,
              'vacuity guard: the PCB bytes at fd $FF and fd 8 of pid 1 '
              f'hold the poison ${POISON:02X} (brk {p1[PCB_BRK]:02X}, '
              f'next pid byte {p2[0]:02X}) -- a missing range check '
              'would read an OPEN fd, not a zero')
        check(all(fdt[i] != 0 for i in (0, 1, 3, 4)) and
              all(fdt[i] == 0 for i in (5, 6, 7)),
              f'vacuity guard: parent fd 0/1/3/4 are the pipe, 5/6/7 '
              f'are closed (table {fdt})')
        check(snaps[1]['lz_want'] == 0, 'LZ_WANT is clear at the start')
        poke(c, cells['PRC_PAR_PID'], PAR_PID_POISON)
        poke(c, R_GO, 1, 'aux', 1)

        # ---- handshake 2: positives done
        if not wait_state(2):
            print('[check-fdact] FAIL: the guest never reached '
                  'handshake 2', file=sys.stderr)
            return 1
        snaps[2] = snapshot(c, cells)
        poke(c, R_GO, 2, 'aux', 1)

        def report_bad(which):
            for pname, base in PATHS:
                if which is not None and base != which:
                    continue
                got = par(c, base, len(BADS))
                for i, name in enumerate(BADS):
                    if got[i] == 0xFF:
                        check(False, f'{name} [{pname}] -> not reached')
                    else:
                        check(got[i] == ERR_INVAL,
                              f'{name} [{pname}] -> ${got[i]:02X} '
                              f'(want ${ERR_INVAL:02X})')

        def untouched(a, b, what):
            d = diff(snaps[a], snaps[b])
            check(not d, f'K5 kernel state {what} (free banks, PCB '
                         'table, OFT types/pipes/refcounts, LZ_WANT)'
                         + ('' if not d else ': ' + '; '.join(d)))

        # ---- handshake 3: every bad list on the builtin path done
        if not wait_state(3):
            check(False, 'the guest never reached handshake 3 (stuck '
                         'in a bad list; rows so far follow)')
            report_bad(None)
            return 1
        snaps[3] = snapshot(c, cells)
        poke(c, R_GO, 3, 'aux', 1)
        untouched(2, 3, 'after the 20 bad first-path spawns == the '
                        'state before them')

        # ---- handshake 4: ... and on the file path
        if not wait_state(4):
            check(False, 'the guest never reached handshake 4 (stuck '
                         'in a bad list; rows so far follow)')
            report_bad(None)
            return 1
        snaps[4] = snapshot(c, cells)
        poke(c, R_GO, 4, 'aux', 1)

        done = 0
        for _ in GR.polls(c, 200):
            done = par(c, R_DONE)[0]
            if done:
                break
        if done != 0xAA:
            print(f'[check-fdact] FAIL: done marker ${done:02X}',
                  file=sys.stderr)
            return 1
        check(par(c, R_ERR)[0] == 0, 'the parent recorded no error')

        # ---- K6: the positives
        errs = par(c, R_POS_ERR, len(POSITIVES)) if POSITIVES else []
        pids = par(c, R_POS_PID, len(POSITIVES)) if POSITIVES else []
        sts = par(c, R_POS_ST, len(POSITIVES)) if POSITIVES else []
        for i, name in enumerate(POSITIVES):
            check(errs[i] == 0 and pids[i] != 0 and sts[i] == CHILD_ST,
                  f'K6 {name}: spawned (pid {pids[i]}), child exited '
                  f'${sts[i]:02X}' + ('' if errs[i] == 0 else
                                      f' (spawn errno ${errs[i]:02X})'))

        # ---- K1 K2 K3 K4 K7: every bad list, both paths
        report_bad(None)

        # ---- K5: nothing was created
        untouched(3, 4, 'after the 20 bad second-path spawns == the '
                        'state before them')
        check(snaps[4]['lz_want'] == 0, 'K5 LZ_WANT is clear')
        keys = ('free_cnt', 'free_list', 'oft_ref', 'oft_type',
                'oft_pipe')
        d = diff({k: snaps[1][k] for k in keys},
                 {k: snaps[4][k] for k in keys})
        check(not d, 'K5 the positives left no bank or reference behind '
                     'either (handshake 1 == handshake 4)'
                     + ('' if not d else ': ' + '; '.join(d)))
        if not PLAIN:
            fe = par(c, R_FIN_ERR)[0]
            fs = par(c, R_FIN_ST)[0]
            check(fe == 0 and fs == CHILD_ST,
                  f'K5 a good spawn after all of it still works (errno '
                  f'${fe:02X}, child exit ${fs:02X})')
        return 0 if ok else 1
    finally:
        c.close()


if __name__ == '__main__':
    raise SystemExit(main())
