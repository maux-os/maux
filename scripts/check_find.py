#!/usr/bin/env python3
"""Boot and verify the ProDOS-hosted `find` acceptance gate
(`make check-find`). Companion to src/test/findtest.s /
scripts/build_find_image.py -- same shape as scripts/check_ls.py
(boot, poll the R_DONE sentinel, peek fixed result addresses in aux
bank 1, byte-exact compare), extended to the 7 runs findtestb.s's
PARENT_PROC performs: plain walk, -name, -type d, -type f, -exec,
a depth-limit overflow, and the pathname fence (a legal on-disk
child past the 64-char MLI limit, refused loudly, exit 1).

Every expected byte string here comes from
build_find_image.compute_expected() -- see that function's docstring
for why it derives expectations from the real on-disk directory
structure rather than by running find.bin and recording its output.

THE POISON, in BOTH layers (2026-08-23; check_ls.py the exemplar,
learning:01M0M9R7RT22JEPP2R0Y6J9MBX the method). Layer 1, pre-boot:
liba's whole arena AND find's own -- LIBA_ZPG..FIND_BSSEND, both
ends read from merlin32's own symbol table, never hardcoded -- are
$A5-filled in every candidate child bank (the kernel zeroes the
first 256 bytes at spawn, so the effective window is span-256).
Layer 2, BETWEEN RUNS: every run after the first executes WARM in
run 1's bank (lazy free prefers the tagged bank), so the pre-boot
poison is consumed by run 1 -- adversarial review N3. findtestb.s
parks on the R_GO handshake between every pair of runs and this
gate re-scribbles the just-freed bank before releasing it, so ALL
7 runs face $A5. Vacuity guards: pid-in-range, every gap serviced
with its poison read back, one shared bank across all runs, and
the kernel's own LZ_WARM flag set at the end.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
import arena  # noqa: E402 -- private-tree listings
import build_find_image as bf  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'find.po')

POISON = 0xA5
# Banks a spawned child can land in on this image -- bank 1 is the
# parent (findtestb.s's PARENT_PROC). Poisoned wholesale rather
# than predicted, asserted afterwards against the pids.
CAND_BANKS = range(2, 10)

R_STATUS1   = 0x1480
R_STATUS2   = 0x1481
R_STATUS3   = 0x1482
R_STATUS4   = 0x1483
R_STATUS5   = 0x1484
R_STATUS6   = 0x1485
R_TRANS1    = 0x1486
R_TRANS2    = 0x1488
R_TRANS3    = 0x148A
R_TRANS4    = 0x148C
R_TRANS5    = 0x148E
R_TRANS6    = 0x1490
R_ERRTRNS6  = 0x1492
R_SPWNPID1  = 0x1494
R_SPWNPID2  = 0x1495
R_SPWNPID3  = 0x1496
R_SPWNPID4  = 0x1497
R_SPWNPID5  = 0x1498
R_SPWNPID6  = 0x1499
R_WAITPID1  = 0x149A
R_WAITPID2  = 0x149B
R_WAITPID3  = 0x149C
R_WAITPID4  = 0x149D
R_WAITPID5  = 0x149E
R_WAITPID6  = 0x149F
R_DONE      = 0x14A0
R_ERR       = 0x14A1
R_STEP      = 0x14A2

R_DATA1     = 0x14B0
R_DATA2     = 0x1604
R_DATA3     = 0x1684
R_DATA4     = 0x1704
R_DATA5     = 0x1804
R_DATA6     = 0x1844
R_ERRDATA6  = 0x1998

R_STATUS7   = 0x1A40
R_TRANS7    = 0x1A41
R_ERRTRNS7  = 0x1A43
R_SPWNPID7  = 0x1A45
R_WAITPID7  = 0x1A46
R_DATA7     = 0x1A50
R_ERRDATA7  = 0x1BB0
R_GO_REQ    = 0x1A47
R_GO        = 0x1A48

# gap number -> the R_WAITPIDn of the run that just finished.
GAP_WAIT_PID = {1: R_WAITPID1, 2: R_WAITPID2, 3: R_WAITPID3,
                4: R_WAITPID4, 5: R_WAITPID5, 6: R_WAITPID6}


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


def peek_bank(client, bank, addr, count):
    return client.call_tool('peek', {
        'addr': addr, 'count': count, 'bank': 'aux', 'aux_bank': bank,
    })['bytes']


def poison_arena(client, bank, arena, span):
    client.call_tool('poke', {
        'addr': arena, 'bytes': [POISON] * span,
        'bank': 'aux', 'aux_bank': bank,
    })


def kernel_symbol(name):
    """Address of a MAIN-memory kernel cell in the findtest image --
    check_ls.py's technique (assemble with -v1, read the dump)."""
    lines = arena.private_listing('src/test', 'findtest.s',
                                  'MAUXFINDTEST.SYSTEM_Output.txt')
    addr = None
    for line in lines:
        m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\$([0-9A-Fa-f]+)\s*$',
                     line)
        if m and m.group(1) == name:
            addr = int(m.group(2), 16)
    if addr is None:
        raise RuntimeError(f'{name} absent from the findtest symbol dump')
    return addr


def find_arena():
    """(first byte, length) of find's liba+own `dum` arena, from
    merlin32 -- check_ls.py's liba_arena() technique verbatim: `-v1`
    writes a symbol listing, read from a private tree.
    Never hardcoded: LIBA_ZPG is LOAD_BASE + image length and
    FIND_BSSEND sits past find's own arena, so both move whenever
    find's code size does, and a stale address would poison whatever
    now lives there instead -- passing while proving nothing
    (learning:01M0M9R7RT22JEPP2R0Y6J9MBX)."""
    lines = arena.private_listing('src/bin', 'find.s',
                                  'find.bin_Output.txt')
    syms = {}
    for line in lines:
        m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\$([0-9A-Fa-f]+)\s*$',
                     line)
        if m:
            syms[m.group(1)] = int(m.group(2), 16)
    missing = [w for w in ('LIBA_ZPG', 'FIND_BSSEND') if w not in syms]
    if missing:
        raise RuntimeError(
            f'{missing} absent from find.bin_Output.txt -- has the '
            f'sec-21 layout (libabss.s put last, FIND_BSSEND at the '
            f'arena end) changed?')
    return (syms['LIBA_ZPG'], syms['FIND_BSSEND'] - syms['LIBA_ZPG'])


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}', file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make find-image first',
              file=sys.stderr)
        return 2

    expected = bf.compute_expected(disk)

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-find] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-find] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        # -- LAYER 1: the pre-boot poison (this file's header).
        arena, span = find_arena()
        print(f'[check-find] poisoning liba+find arenas '
              f'${arena:04X}+{span} (effective {span - 256} past the '
              f'kernel-zeroed page) with ${POISON:02X} in aux banks '
              f'{CAND_BANKS.start}-{CAND_BANKS.stop - 1}',
              file=sys.stderr)
        for bank in CAND_BANKS:
            poison_arena(client, bank, arena, span)
            back = peek_bank(client, bank, arena, 8)
            if any(b != POISON for b in back):
                raise RuntimeError(
                    f'poison poke into bank {bank} read back {back} -- '
                    f'it did not land, the run would prove nothing')

        warm_addr = kernel_symbol('LZ_WARM')

        # -- LAYER 2: the between-run poison. findtestb.s publishes
        # the gap number in R_GO_REQ after each run and parks until
        # R_GO matches, so the scribble lands strictly between one
        # run's reap and the next one's spawn.
        served = {}
        failed_poison = []
        done = 0
        for i in range(1600):
            client.call_tool('step', {'cycles': 200_000})
            req = peek_aux1(client, R_GO_REQ)[0]
            if req in GAP_WAIT_PID and req not in served:
                bank = peek_aux1(client, GAP_WAIT_PID[req])[0]
                poison_arena(client, bank, arena, span)
                back = peek_bank(client, bank, arena, 8)
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
                   R_STATUS6, R_STATUS7)]
        trans = [peek_u16(client, a) for a in
                 (R_TRANS1, R_TRANS2, R_TRANS3, R_TRANS4, R_TRANS5,
                  R_TRANS6, R_TRANS7)]
        err_trans = peek_u16(client, R_ERRTRNS6)
        err_trans7 = peek_u16(client, R_ERRTRNS7)
        spawn_pid = [peek_aux1(client, a)[0] for a in
                     (R_SPWNPID1, R_SPWNPID2, R_SPWNPID3, R_SPWNPID4,
                      R_SPWNPID5, R_SPWNPID6, R_SPWNPID7)]
        wait_pid = [peek_aux1(client, a)[0] for a in
                    (R_WAITPID1, R_WAITPID2, R_WAITPID3, R_WAITPID4,
                     R_WAITPID5, R_WAITPID6, R_WAITPID7)]

        data_addrs = [R_DATA1, R_DATA2, R_DATA3, R_DATA4, R_DATA5, R_DATA6,
                      R_DATA7]
        data = [bytes(peek_aux1(client, addr, trans[i])) if trans[i] else b''
                for i, addr in enumerate(data_addrs)]
        errdata6 = bytes(peek_aux1(client, R_ERRDATA6, err_trans)) \
            if err_trans else b''
        errdata7 = bytes(peek_aux1(client, R_ERRDATA7, err_trans7)) \
            if err_trans7 else b''

        print(f'[check-find] done=${done:02X} err=${err:02X} '
              f'step=${step:02X} status={status} spawn_pid={spawn_pid} '
              f'wait_pid={wait_pid} trans={trans} err_trans={err_trans} '
              f'err_trans7={err_trans7} poisoned={served} '
              f'LZ_WARM=${warm:02X}')

        failures = []
        if done != 0xAA:
            failures.append(f'test did not finish successfully '
                            f'(done=${done:02X}, err=${err:02X}, step={step})')
        if err != 0:
            failures.append(f'R_ERR expected $00, got ${err:02X}')
        for i in range(7):
            if spawn_pid[i] == 0:
                failures.append(f'run {i+1}: SPAWN(FIND) returned pid 0')
            if wait_pid[i] != spawn_pid[i]:
                failures.append(f'run {i+1}: wait pid {wait_pid[i]} != '
                                f'spawn pid {spawn_pid[i]}')
            # -- VACUITY GUARD for the poison: a pid IS its bank
            # -- (src/kernel/process.s), so a child outside the
            # -- poisoned range ran on clean memory and proved
            # -- nothing about the uncleared arena.
            if spawn_pid[i] and spawn_pid[i] not in CAND_BANKS:
                failures.append(
                    f'run {i+1}: child pid/bank {spawn_pid[i]} is outside '
                    f'the poisoned range {CAND_BANKS.start}-'
                    f'{CAND_BANKS.stop - 1}, so this run did not exercise '
                    f'find\'s uncleared arena at all. Widen CAND_BANKS.')

        # -- THE BETWEEN-RUN POISON'S OWN GUARDS (check_ls.py's set) --
        if sorted(served) != sorted(GAP_WAIT_PID):
            failures.append(f'expected to service handshake gaps '
                            f'{sorted(GAP_WAIT_PID)}, serviced '
                            f'{sorted(served)} -- the poison did not land '
                            f'between every pair of runs')
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
                f'runs did not share one bank ({spawn_pid}) -- a pid IS '
                f'its bank, so the retained bank was NOT reused and the '
                f'between-run poison went somewhere the next run never '
                f'touched. The gate is vacuous in that state.')
        if not warm:
            failures.append(
                'LZ_WARM is clear after the final run -- the kernel says '
                'the last spawn was NOT served from a retained bank, so '
                'the between-run poison never met a warm respawn at all')

        labels = ['plain walk', '-name [AND]*.TXT', '-type d', '-type f',
                  '-exec cat', 'depth overflow', 'pathname fence']
        exp_status = [expected['run1_status'], expected['run2_status'],
                      expected['run3_status'], expected['run4_status'],
                      expected['run5_status'], expected['run6_status'],
                      expected['run7_status']]
        exp_data = [expected['run1'], expected['run2'], expected['run3'],
                    expected['run4'], expected['run5'], expected['run6'],
                    expected['run7']]

        for i in range(7):
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

        # -- run 6: also the stderr diagnostic --
        if err_trans != len(expected['run6_err']):
            failures.append(f'run 6: stderr trans_count expected '
                            f'{len(expected["run6_err"])}, got {err_trans}')
        if errdata6 != expected['run6_err']:
            failures.append(f'run 6 stderr mismatch:\n'
                            f'  expected={expected["run6_err"]!r}\n'
                            f'  got     ={errdata6!r}')

        # -- run 7: the two "pathname too long" refusals --
        if err_trans7 != len(expected['run7_err']):
            failures.append(f'run 7: stderr trans_count expected '
                            f'{len(expected["run7_err"])}, got {err_trans7}')
        if errdata7 != expected['run7_err']:
            failures.append(f'run 7 stderr mismatch:\n'
                            f'  expected={expected["run7_err"]!r}\n'
                            f'  got     ={errdata7!r}')

        if failures:
            for failure in failures:
                print(f'[check-find] FAIL: {failure}', file=sys.stderr)
            return 1

        print('[check-find] PASS: find -- plain walk, -name, -type d, '
              '-type f, -exec, depth-limit overflow, and the pathname '
              'fence (two >64-char children refused loudly, the 64-char '
              'sibling still printed, exit 1) -- all byte-exact against '
              'a real spawned binary, with liba\'s arena AND find\'s own '
              f'({span} bytes, LIBA_ZPG..FIND_BSSEND; effective '
              f'{span - 256} past the kernel-zeroed page) pre-filled '
              f'with ${POISON:02X} in every candidate child bank AND '
              f're-scribbled in all {len(served)} gaps into bank '
              f'{spawn_pid[0]}, which every run reused (LZ_WARM set)')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
