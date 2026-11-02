#!/usr/bin/env python3
"""Boot and verify the ProDOS-hosted `du` acceptance gate (`make
check-du`). Companion to src/test/dutest.s / scripts/build_du_image.py --
same shape as scripts/check_find.py (boot, poll the R_DONE sentinel, peek
fixed result addresses in aux bank 1, byte-exact compare), extended to the
6 runs dutestb.s's PARENT_PROC performs: plain walk, -s, -a, a single-file
argument, a nonexistent-path-then-valid-path run, and the pathname fence
(legal on-disk children past the 64-char MLI limit, refused loudly and
EXCLUDED from every total, exit 1).

Every expected byte string here comes from
build_du_image.compute_expected() -- see that function's docstring for why
it derives expectations from hand-computed block math (cross-checked
against the real on-disk blocks_used), not by running du.bin and
recording its output.

THE POISON, in BOTH layers (2026-08-23) -- check_find.py's header
carries the full argument. Layer 1: LIBA_ZPG..DU_BSSEND (symbol-table
ends) $A5-filled in every candidate bank pre-boot (effective window
span-256 past the kernel-zeroed page). Layer 2: dutestb.s parks on
the R_GO handshake between every pair of runs and this gate
re-scribbles the just-freed bank -- every run after the first is
WARM in run 1's bank, so a pre-boot poison alone is consumed by run
1 (adversarial review N3). Vacuity guards: pid-in-range, every gap
serviced with read-back, one shared bank, LZ_WARM set at the end.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
import arena  # noqa: E402 -- private-tree listings
import build_du_image as bd  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'du.po')

POISON = 0xA5
CAND_BANKS = range(2, 10)


def peek_bank_du(client, bank, addr, count):
    return client.call_tool('peek', {
        'addr': addr, 'count': count, 'bank': 'aux', 'aux_bank': bank,
    })['bytes']


def poison_arena(client, bank, arena, span):
    client.call_tool('poke', {
        'addr': arena, 'bytes': [POISON] * span,
        'bank': 'aux', 'aux_bank': bank,
    })


def kernel_symbol(name):
    """LZ_WARM's address in the dutest image, from merlin32 -v1's
    own symbol dump (check_ls.py's technique)."""
    lines = arena.private_listing('src/test', 'dutest.s',
                                  'MAUXDUTEST.SYSTEM_Output.txt')
    addr = None
    for line in lines:
        m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\$([0-9A-Fa-f]+)\s*$',
                     line)
        if m and m.group(1) == name:
            addr = int(m.group(2), 16)
    if addr is None:
        raise RuntimeError(f'{name} absent from the dutest symbol dump')
    return addr


def du_arena():
    """(first byte, length) of du's liba+own `dum` arena, from
    merlin32 -v1's symbol dump -- check_ls.py's technique, never
    hardcoded (learning:01M0M9R7RT22JEPP2R0Y6J9MBX)."""
    lines = arena.private_listing('src/bin', 'du.s',
                                  'du.bin_Output.txt')
    syms = {}
    for line in lines:
        m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\$([0-9A-Fa-f]+)\s*$',
                     line)
        if m:
            syms[m.group(1)] = int(m.group(2), 16)
    missing = [w for w in ('LIBA_ZPG', 'DU_BSSEND') if w not in syms]
    if missing:
        raise RuntimeError(
            f'{missing} absent from du.bin_Output.txt -- has the '
            f'sec-21 layout (libabss.s put last, DU_BSSEND at the '
            f'arena end) changed?')
    return (syms['LIBA_ZPG'], syms['DU_BSSEND'] - syms['LIBA_ZPG'])

R_STATUS1   = 0x1500
R_STATUS2   = 0x1501
R_STATUS3   = 0x1502
R_STATUS4   = 0x1503
R_STATUS5   = 0x1504
R_TRANS1    = 0x1505
R_TRANS2    = 0x1507
R_TRANS3    = 0x1509
R_TRANS4    = 0x150B
R_TRANS5    = 0x150D
R_ERRTRNS5  = 0x150F
R_SPWNPID1  = 0x1511
R_SPWNPID2  = 0x1512
R_SPWNPID3  = 0x1513
R_SPWNPID4  = 0x1514
R_SPWNPID5  = 0x1515
R_WAITPID1  = 0x1516
R_WAITPID2  = 0x1517
R_WAITPID3  = 0x1518
R_WAITPID4  = 0x1519
R_WAITPID5  = 0x151A
R_DONE      = 0x151B
R_ERR       = 0x151C
R_STEP      = 0x151D

R_DATA1     = 0x1600
R_DATA2     = 0x1680
R_DATA3     = 0x16C0
R_DATA4     = 0x17C0
R_DATA5     = 0x1800
R_ERRDATA5  = 0x1840

R_STATUS6   = 0x1900
R_TRANS6    = 0x1901
R_ERRTRNS6  = 0x1903
R_SPWNPID6  = 0x1905
R_WAITPID6  = 0x1906
R_DATA6     = 0x1910
R_ERRDATA6  = 0x1A10
R_GO_REQ    = 0x1907
R_GO        = 0x1908

R_STATUS7   = 0x1C00
R_TRANS7    = 0x1C01
R_SPWNPID7  = 0x1C03
R_WAITPID7  = 0x1C04
R_STATUS8   = 0x1C05
R_TRANS8    = 0x1C06
R_SPWNPID8  = 0x1C08
R_WAITPID8  = 0x1C09
R_DATA7     = 0x1C10
R_DATA8     = 0x1D10


def peek_aux1(client, addr, count=1):
    return client.call_tool('peek', {
        'addr': addr,
        'count': count,
        'bank': 'aux',
        'aux_bank': 1,
    })['bytes']


def peek_u16(client, addr):
    b = peek_aux1(client, addr, 2)
    return b[0] | (b[1] << 8)


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}', file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make du-image first',
              file=sys.stderr)
        return 2

    expected = bd.compute_expected(disk)

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-du] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-du] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        # -- LAYER 1: the pre-boot poison (this file's header).
        arena, span = du_arena()
        print(f'[check-du] poisoning liba+du arenas ${arena:04X}+{span} '
              f'(effective {span - 256} past the kernel-zeroed page) '
              f'with ${POISON:02X} in aux banks {CAND_BANKS.start}-'
              f'{CAND_BANKS.stop - 1}', file=sys.stderr)
        for bank in CAND_BANKS:
            poison_arena(client, bank, arena, span)
            back = peek_bank_du(client, bank, arena, 8)
            if any(b != POISON for b in back):
                raise RuntimeError(
                    f'poison poke into bank {bank} read back {back} -- '
                    f'it did not land, the run would prove nothing')

        warm_addr = kernel_symbol('LZ_WARM')

        # -- LAYER 2: the between-run poison (gaps 1-7; dutestb.s's
        # GAPWAIT parks between every pair of runs).
        gap_wait = {1: R_WAITPID1, 2: R_WAITPID2, 3: R_WAITPID3,
                    4: R_WAITPID4, 5: R_WAITPID5, 6: R_WAITPID6,
                    7: R_WAITPID7}
        served = {}
        failed_poison = []
        done = 0
        for i in range(1600):
            client.call_tool('step', {'cycles': 200_000})
            req = peek_aux1(client, R_GO_REQ)[0]
            if req in gap_wait and req not in served:
                bank = peek_aux1(client, gap_wait[req])[0]
                poison_arena(client, bank, arena, span)
                back = peek_bank_du(client, bank, arena, 8)
                if any(b != POISON for b in back):
                    failed_poison.append((req, bank, back))
                served[req] = bank
                client.call_tool('poke', {
                    'addr': R_GO, 'bytes': [req],
                    'bank': 'aux', 'aux_bank': 1,
                })
            done = peek_aux1(client, R_DONE)[0]
            if done in (0xAA, 0xEE):
                break
        warm = client.call_tool('peek', {
            'addr': warm_addr, 'count': 1, 'bank': 'main'})['bytes'][0]
        err = peek_aux1(client, R_ERR)[0]
        step = peek_aux1(client, R_STEP)[0]

        status = [peek_aux1(client, a)[0] for a in
                  (R_STATUS1, R_STATUS2, R_STATUS3, R_STATUS4, R_STATUS5,
                   R_STATUS6, R_STATUS7, R_STATUS8)]
        trans = [peek_u16(client, a) for a in
                 (R_TRANS1, R_TRANS2, R_TRANS3, R_TRANS4, R_TRANS5,
                  R_TRANS6, R_TRANS7, R_TRANS8)]
        err_trans = peek_u16(client, R_ERRTRNS5)
        err_trans6 = peek_u16(client, R_ERRTRNS6)
        spawn_pid = [peek_aux1(client, a)[0] for a in
                     (R_SPWNPID1, R_SPWNPID2, R_SPWNPID3, R_SPWNPID4,
                      R_SPWNPID5, R_SPWNPID6, R_SPWNPID7, R_SPWNPID8)]
        wait_pid = [peek_aux1(client, a)[0] for a in
                    (R_WAITPID1, R_WAITPID2, R_WAITPID3, R_WAITPID4,
                     R_WAITPID5, R_WAITPID6, R_WAITPID7, R_WAITPID8)]

        data_addrs = [R_DATA1, R_DATA2, R_DATA3, R_DATA4, R_DATA5, R_DATA6,
                      R_DATA7, R_DATA8]
        data = [bytes(peek_aux1(client, addr, trans[i])) if trans[i] else b''
                for i, addr in enumerate(data_addrs)]
        errdata5 = bytes(peek_aux1(client, R_ERRDATA5, err_trans)) \
            if err_trans else b''
        errdata6 = bytes(peek_aux1(client, R_ERRDATA6, err_trans6)) \
            if err_trans6 else b''

        print(f'[check-du] done=${done:02X} err=${err:02X} '
              f'step=${step:02X} status={status} spawn_pid={spawn_pid} '
              f'wait_pid={wait_pid} trans={trans} err_trans={err_trans} '
              f'err_trans6={err_trans6} poisoned={served} '
              f'LZ_WARM=${warm:02X}')

        failures = []
        if done != 0xAA:
            failures.append(f'test did not finish successfully '
                            f'(done=${done:02X}, err=${err:02X}, step={step})')
        if err != 0:
            failures.append(f'R_ERR expected $00, got ${err:02X}')
        for i in range(8):
            if spawn_pid[i] == 0:
                failures.append(f'run {i+1}: SPAWN(DU) returned pid 0')
            if wait_pid[i] != spawn_pid[i]:
                failures.append(f'run {i+1}: wait pid {wait_pid[i]} != '
                                f'spawn pid {spawn_pid[i]}')
            # -- VACUITY GUARD for the poison: a pid IS its bank.
            if spawn_pid[i] and spawn_pid[i] not in CAND_BANKS:
                failures.append(
                    f'run {i+1}: child pid/bank {spawn_pid[i]} is outside '
                    f'the poisoned range {CAND_BANKS.start}-'
                    f'{CAND_BANKS.stop - 1}, so this run did not exercise '
                    f'du\'s uncleared arena at all. Widen CAND_BANKS.')

        # -- THE BETWEEN-RUN POISON'S OWN GUARDS --
        if sorted(served) != [1, 2, 3, 4, 5, 6, 7]:
            failures.append(f'expected to service handshake gaps 1-7, '
                            f'serviced {sorted(served)} -- the poison did '
                            f'not land between every pair of runs')
        for gap, bank, back in failed_poison:
            failures.append(f'gap {gap}: the ${POISON:02X} poke into bank '
                            f'{bank} read back {back} -- the poison did '
                            f'not land, so the run after it proved nothing')
        for gap, bank in served.items():
            if bank != spawn_pid[gap]:
                failures.append(f'gap {gap}: poisoned bank {bank} but run '
                                f'{gap+1} ran in bank {spawn_pid[gap]}')
        if len(set(spawn_pid)) != 1:
            failures.append(
                f'runs did not share one bank ({spawn_pid}) -- the '
                f'retained bank was NOT reused and the between-run poison '
                f'went somewhere the next run never touched.')
        if not warm:
            failures.append(
                'LZ_WARM is clear after the final run -- nothing here '
                'exercised the warm respawn path at all')

        labels = ['plain walk', '-s', '-a', 'single file arg',
                  'nonexistent + valid path', 'pathname fence',
                  'trailing-slash operand', 'no operand, cwd=DUDIR']
        exp_status = [expected['run1_status'], expected['run2_status'],
                      expected['run3_status'], expected['run4_status'],
                      expected['run5_status'], expected['run6_status'],
                      expected['run7_status'], expected['run8_status']]
        exp_data = [expected['run1'], expected['run2'], expected['run3'],
                    expected['run4'], expected['run5'], expected['run6'],
                    expected['run7'], expected['run8']]

        for i in range(8):
            label = labels[i]
            if status[i] != exp_status[i]:
                failures.append(f'run {i+1} ({label}): exit status '
                                f'expected {exp_status[i]}, got {status[i]}')
            if trans[i] != len(exp_data[i]):
                failures.append(f'run {i+1} ({label}): stdout trans_count '
                                f'expected {len(exp_data[i])}, got {trans[i]}')
            if data[i] != exp_data[i]:
                failures.append(f'run {i+1} ({label}) stdout mismatch:\n'
                                f'  expected={exp_data[i]!r}\n'
                                f'  got     ={data[i]!r}')

        # -- run 5: also the stderr diagnostic --
        if err_trans != len(expected['run5_err']):
            failures.append(f'run 5: stderr trans_count expected '
                            f'{len(expected["run5_err"])}, got {err_trans}')
        if errdata5 != expected['run5_err']:
            failures.append(f'run 5 stderr mismatch:\n'
                            f'  expected={expected["run5_err"]!r}\n'
                            f'  got     ={errdata5!r}')

        # -- run 6: the two "pathname too long" refusals --
        if err_trans6 != len(expected['run6_err']):
            failures.append(f'run 6: stderr trans_count expected '
                            f'{len(expected["run6_err"])}, got {err_trans6}')
        if errdata6 != expected['run6_err']:
            failures.append(f'run 6 stderr mismatch:\n'
                            f'  expected={expected["run6_err"]!r}\n'
                            f'  got     ={errdata6!r}')

        if failures:
            for failure in failures:
                print(f'[check-du] FAIL: {failure}', file=sys.stderr)
            return 1

        print('[check-du] PASS: du -- plain walk, -s, -a, single-file '
              'argument, nonexistent-path-then-valid-path, the '
              'trailing-slash operand (one "/", never two), no operand '
              'at a cwd (./X names, "." last) and the '
              'pathname fence (two >64-char children refused loudly and '
              'excluded from every total, the 64-char sibling counted, '
              'exit 1) -- all byte-exact against a real spawned binary, '
              'with liba\'s arena AND du\'s own '
              f'({span} bytes, LIBA_ZPG..DU_BSSEND; effective '
              f'{span - 256} past the kernel-zeroed page) pre-filled '
              f'with ${POISON:02X} in every candidate child bank AND '
              f're-scribbled in all {len(served)} gaps into bank '
              f'{spawn_pid[0]}, which every run reused (LZ_WARM set)')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
