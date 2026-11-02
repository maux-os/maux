#!/usr/bin/env python3
"""Boot and verify the `tail` acceptance gate (`make check-tail`).

Companion to src/test/tailtest.s / src/test/tailtestb.s /
scripts/build_tail_image.py. Six spawns of a real, liba-linked TAIL
binary, each with fd 1 (and, for run 6, fd 0 too) redirected to real
ProDOS files -- see build_tail_image.py's own header for what each run
covers and tailtestb.s's header for the R_RUNn result layout.

THE POISON, in BOTH layers (docs/STICKY.md sec 25/28/37;
scripts/check_ls.py the exemplar, learning:01M0M9R7RT22JEPP2R0Y6J9MBX
the method). Before sec 37's follow-up ("extending the poison to
check-du/check-diff/check-comm/check-tail/check-nm/check-sh is the
obvious follow-up"), this gate ran all six TAIL spawns FUNCTIONALLY but
poisoned nothing -- a read-before-write bug in tail's own `dum` arena
(RING, CBUF, PATHBUF, the ring-buffer scalars -- see tail.s's own
header for the write-before-read trace `dum` depends on) would have
read zeros, which is exactly the value such a bug needs to look
correct.

Layer 1, PRE-BOOT: liba's whole arena AND tail's own --
scripts/arena.arena_span('tail') gives (LIBA_ZPG, length) straight from
merlin32's own `-v1` dump (tail.s has no `TAIL_BSSEND` label -- see
that module's header for how the end is derived without one) -- are
$A5-filled in every candidate child bank, READ BACK to confirm the poke
landed before the machine is stepped at all (check_find.py's fix to
check_ls.py's own hole: a silent non-landing poke passes while proving
nothing).

Layer 2, BETWEEN RUNS: every run after the first executes WARM in run
1's bank -- lazy free prefers the bank already tagged with the program
being spawned -- so the pre-boot poison is consumed by run 1 alone and
runs 2..6 would run on run 1's own residue, not on $A5, without this.
tailtestb.s's PARENT_PROC parks on an R_GO handshake (WAIT_GO, four
lines, the same shape as src/test/lstestb.s's own) after every run but
the last; this script services each gap by poisoning the bank the
just-finished run's pid names, reads it back, then releases the park.
Vacuity guards: every pid in the poisoned bank range, every gap
serviced with its poison read back, one shared bank across all six
runs, and the kernel's own LZ_WARM flag set at the end.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
from build_tail_image import (  # noqa: E402
    EXPECT_RUN1, EXPECT_RUN2, EXPECT_RUN3, EXPECT_RUN4, EXPECT_RUN5,
    EXPECT_RUN6, EXPECT_STATUS,
)
import arena as arenamod  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'tail.po')

RUN_BASES = {
    1: (0x1200, EXPECT_RUN1, 'default N=10 on TAILSRC (15 lines)'),
    2: (0x1300, EXPECT_RUN2, '-3 on TAILSRC'),
    3: (0x1400, EXPECT_RUN3, '-20 on TAILSRC (N > lines available)'),
    4: (0x1500, EXPECT_RUN4, 'default N on TAILMT (empty file)'),
    5: (0x1600, EXPECT_RUN5, '-2 on TAILNOCR (no trailing CR)'),
    6: (0x1700, EXPECT_RUN6, 'default N on fd 0 (dup from TAILSRC)'),
}
READBUFLEN = 64

R_DONE = 0x1900
R_ERR = 0x1901
R_STEP = 0x1902
R_GO_REQ = 0x1903
R_GO = 0x1904

# gap number (the run that just finished) -> that run's own R_RUNn+0
# spawn-pid cell (a pid IS its bank -- src/kernel/process.s), read to
# learn WHICH bank to re-poison in that gap.
GAP_PID_ADDR = {n: base for n, (base, _, _) in RUN_BASES.items() if n < 6}

POISON = 0xA5
# Banks a spawned child can land in on this image -- bank 1 is the
# parent (tailtestb.s's PARENT_PROC). Poisoned wholesale rather than
# predicted, and asserted afterwards against the pids that came back.
CAND_BANKS = range(2, 10)


def peek_aux1(client, addr, count=1):
    return client.call_tool('peek', {
        'addr': addr,
        'count': count,
        'bank': 'aux',
        'aux_bank': 1,
    })['bytes']


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
    """Address of a MAIN-memory kernel cell in the tailtest image --
    check_ls.py's technique (assemble the harness with -v1 in a
    private tree and read the dump, arena.private_listing)."""
    import re
    lines = arenamod.private_listing('src/test', 'tailtest.s',
                                     'MAUXTAIL.SYSTEM_Output.txt')
    addr = None
    for line in lines:
        m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\$([0-9A-Fa-f]+)\s*$',
                     line)
        if m and m.group(1) == name:
            addr = int(m.group(2), 16)
    if addr is None:
        raise RuntimeError(f'{name} absent from the tailtest symbol dump')
    return addr


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}', file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make tail-image first',
              file=sys.stderr)
        return 2

    arena, span = arenamod.arena_span('tail')

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-tail] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-tail] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        # -- LAYER 1: the pre-boot poison, read back before stepping at
        # -- all (check_find.py's fix to check_ls.py's own hole).
        print(f'[check-tail] poisoning liba+tail arenas ${arena:04X}+{span} '
              f'(effective {span - 256} past the kernel-zeroed page) with '
              f'${POISON:02X} in aux banks {CAND_BANKS.start}-'
              f'{CAND_BANKS.stop - 1}', file=sys.stderr)
        for bank in CAND_BANKS:
            poison_arena(client, bank, arena, span)
            back = peek_bank(client, bank, arena, 8)
            if any(b != POISON for b in back):
                raise RuntimeError(
                    f'poison poke into bank {bank} read back {back} -- it '
                    f'did not land, the run would prove nothing')

        warm_addr = kernel_symbol('LZ_WARM')

        # -- LAYER 2: the between-run poison. tailtestb.s's PARENT_PROC
        # -- publishes the gap number in R_GO_REQ after each of the
        # -- first five runs and parks (WAIT_GO) until R_GO matches, so
        # -- the scribble lands strictly between one run's reap and the
        # -- next one's spawn -- never racing SYS_SPAWN.
        served = {}
        failed_poison = []
        done = 0
        for _ in range(1800):
            client.call_tool('step', {'cycles': 200_000})
            req = peek_aux1(client, R_GO_REQ)[0]
            if req in GAP_PID_ADDR and req not in served:
                bank = peek_aux1(client, GAP_PID_ADDR[req])[0]
                poison_arena(client, bank, arena, span)
                back = peek_bank(client, bank, arena, 8)
                if any(b != POISON for b in back):
                    failed_poison.append((req, bank, back))
                served[req] = bank
                print(f'[check-tail] gap {req}: poisoned bank {bank} '
                      f'${arena:04X}+{span} and released the parent',
                      file=sys.stderr)
                client.call_tool('poke', {
                    'addr': R_GO, 'bytes': [req],
                    'bank': 'aux', 'aux_bank': 1,
                })
            done = peek_aux1(client, R_DONE)[0]
            if done in (0xAA, 0xEE):
                break

        err = peek_aux1(client, R_ERR)[0]
        step = peek_aux1(client, R_STEP)[0]
        warm = client.call_tool('peek', {
            'addr': warm_addr, 'count': 1, 'bank': 'main'})['bytes'][0]
        print(f'[check-tail] done=${done:02X} err=${err:02X} step={step} '
              f'poisoned={served} LZ_WARM=${warm:02X}')

        failures = []
        if done != 0xAA:
            failures.append(f'test did not finish successfully '
                            f'(done=${done:02X}, err=${err:02X}, step={step})')

        spawn_pid = {}
        for run, (base, expected, label) in RUN_BASES.items():
            pid = peek_aux1(client, base)[0]
            wpid = peek_aux1(client, base + 1)[0]
            status = peek_aux1(client, base + 2)[0]
            t = peek_aux1(client, base + 3, 2)
            trans = t[0] | (t[1] << 8)
            data = bytes(peek_aux1(client, base + 6, READBUFLEN))[:len(expected)]
            spawn_pid[run] = pid
            print(f'[check-tail] run{run} ({label}): pid={pid} wpid={wpid} '
                  f'status=${status:02X} trans={trans} data={data!r}')

            if done != 0xAA:
                continue  # harness itself didn't finish -- see above
            if pid == 0:
                failures.append(f'run{run}: SPAWN(TAIL) returned pid 0')
            if wpid != pid:
                failures.append(f'run{run}: wait pid {wpid} != spawn pid {pid}')
            # -- VACUITY GUARD for the poison. A pid IS its bank
            # -- (src/kernel/process.s `sta PRC_CHLD_BANK /
            # -- sta PRC_CHILD_PID`), so a child outside the poisoned
            # -- range ran on clean memory and proves nothing about
            # -- tail's uncleared arena.
            if pid and pid not in CAND_BANKS:
                failures.append(
                    f'run{run}: child pid/bank {pid} is outside the '
                    f'poisoned range {CAND_BANKS.start}-{CAND_BANKS.stop - 1}'
                    f', so this run did not exercise tail\'s uncleared '
                    f'arena at all. Widen CAND_BANKS.')
            if status != EXPECT_STATUS:
                failures.append(f'run{run}: exit status expected '
                                f'${EXPECT_STATUS:02X}, got ${status:02X}')
            if trans != len(expected):
                failures.append(f'run{run}: trans_count expected '
                                f'{len(expected)}, got {trans}')
            if data != expected:
                failures.append(f'run{run}: output mismatch:\n'
                                f'  expected={expected!r}\n  got     ={data!r}')

        # -- THE BETWEEN-RUN POISON'S OWN GUARDS (check_ls.py's set) --
        if sorted(served) != sorted(GAP_PID_ADDR):
            failures.append(f'expected to service handshake gaps '
                            f'{sorted(GAP_PID_ADDR)}, serviced '
                            f'{sorted(served)} -- the poison did not land '
                            f'between every pair of runs')
        for gap, bank, back in failed_poison:
            failures.append(f'gap {gap}: the ${POISON:02X} poke into bank '
                            f'{bank} read back {back} -- the poison did '
                            f'not land, so the run after it proved nothing')
        for gap, bank in served.items():
            if bank != spawn_pid.get(gap):
                failures.append(f'gap {gap}: poisoned bank {bank} but run '
                                f'{gap} ran in bank {spawn_pid.get(gap)}')
        if done == 0xAA and len(set(spawn_pid.values())) != 1:
            failures.append(
                f'runs did not share one bank ({spawn_pid}) -- a pid IS its '
                f'bank, so this means the retained bank was NOT reused and '
                f'the between-run poison went somewhere the next run never '
                f'touched. The gate is vacuous in that state, not merely '
                f'weaker.')
        if done == 0xAA and not warm:
            failures.append(
                'LZ_WARM is clear after the final run -- the kernel says '
                'the last spawn was NOT served from a retained bank, so '
                'nothing here exercised the no-copy respawn path at all')

        if failures:
            for failure in failures:
                print(f'[check-tail] FAIL: {failure}', file=sys.stderr)
            return 1

        print('[check-tail] PASS: all six tail runs (default N, -3, -20 '
              '(N > lines), empty file, no-trailing-CR, fd 0) matched '
              'their hand-derived expected output byte-exact, with '
              f'liba\'s arena AND tail\'s own -- {span} bytes, '
              f'LIBA_ZPG..(derived, scripts/arena.py) -- pre-filled with '
              f'${POISON:02X} in every candidate child bank AND '
              f're-scribbled in all {len(served)} between-run gaps into '
              f'bank {list(spawn_pid.values())[0]}, which every run reused '
              f'(LZ_WARM set: the kernel copied no image)')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
