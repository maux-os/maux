#!/usr/bin/env python3
"""Boot and verify the `diff` acceptance gate (`make check-diff`).

Companion to src/test/difftest.s / difftestb.s /
scripts/build_diff_image.py.

difftestb.s spawns `diff` directly ten times (table-driven, see its own
header), each with fd 1 (or fd 2, for the overflow case) dup'd to a
captured output file, then builds one more file by hand ("r <A5>\\r" +
the -e case's own output + "w <RESULT>\\rq\\r") and spawns `ed` with
stdin dup'd from it -- the diff-e-then-ed round trip.

Every captured file is read back BYTE-EXACT off the built .po image
(prodos.read), same mechanism scripts/check_fleet.py uses for its own
phase-1 output files -- far simpler than peeking result buffers out of
aux memory for ten separate variable-length outputs.

THE POISON, in BOTH layers (docs/STICKY.md sec 25/28/37;
scripts/check_ls.py the exemplar, learning:01M0M9R7RT22JEPP2R0Y6J9MBX
the method). Before sec 37's follow-up ("extending the poison to
check-du/check-diff/check-comm/check-tail/check-nm/check-sh is the
obvious follow-up"), the ten `diff` spawns and the one `ed` spawn ran
functionally but poisoned nothing -- a read-before-write bug in either
program's own `dum` arena would have read zeros, exactly the value
such a bug needs to look correct.

Layer 1, PRE-BOOT: liba's whole arena AND EACH program's own --
scripts/arena.arena_span('diff') / arena_span('ed'), both straight from
merlin32's own `-v1` dump (neither program has a hand-added
`<PROG>_BSSEND` label -- see that module's header for the derivation)
-- are $A5-filled in every candidate child bank, READ BACK to confirm
the poke landed before the machine is stepped at all
(scripts/check_find.py's fix to check_ls.py's own hole).

Layer 2, BETWEEN RUNS: `diff` is spawned TEN times here, and every run
after the first executes WARM in an earlier run's bank -- lazy free
prefers the bank already tagged with the program being spawned -- so
the pre-boot poison alone is consumed by run 1 and runs 2..10 would
execute on the PREVIOUS diff run's own residue, not on $A5, without
this. difftestb.s's PARENT_PROC now records each run's own spawn pid
(R_PIDS, indexed by CASEI -- a pid IS its bank) and parks on an R_GO
handshake (WAIT_GO, four lines, the same shape as
src/test/lstestb.s's own) after every diff run but the last; this
script services each of the nine gaps by poisoning the bank the
just-finished run's pid names, reads it back, then releases the park.
`ed` is spawned only once here, so there is no between-run layer for
it to need -- the pre-boot poison alone already covers its single run
(learning:01M0M9R7RT22JEPP2R0Y6J9MBX's own distinction: the trap is
specifically about a bank a PREVIOUS run of the SAME program tagged).
Vacuity guards: every pid in the poisoned bank range, every gap
serviced with its poison read back, one shared bank across all ten
diff runs, and the kernel's own LZ_WARM flag set at the end.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
from build_diff_image import (  # noqa: E402
    EXPECT_OUT1, EXPECT_STATUS1, EXPECT_OUT2, EXPECT_STATUS2,
    EXPECT_OUT3, EXPECT_STATUS3, EXPECT_OUT4, EXPECT_STATUS4,
    EXPECT_OUT5, EXPECT_STATUS5, EXPECT_OUT6, EXPECT_STATUS6,
    EXPECT_OUT7, EXPECT_STATUS7, EXPECT_OUT8, EXPECT_STATUS8,
    EXPECT_STATUS9, EXPECT_STDERR9,
    EXPECT_OUTE, EXPECT_ESTATUS, EXPECT_RESULT, EXPECT_EDSTATUS,
)
import arena as arenamod  # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'difftest.po')
VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')

R_STATUS1   = 0x1300
R_STATUS2   = 0x1301
R_STATUS3   = 0x1302
R_STATUS4   = 0x1303
R_STATUS5   = 0x1304
R_STATUS6   = 0x1305
R_STATUS7   = 0x1306
R_STATUS8   = 0x1307
R_STATUS9   = 0x1308
R_ESTATUS   = 0x1309
R_EDSTATUS  = 0x130A
R_PIDS      = 0x1310   # 10 bytes, one spawn pid per diff run
R_EDPID     = 0x131A
R_GO_REQ    = 0x131B
R_GO        = 0x131C
R_DONE      = 0x1390
R_ERR       = 0x1391
R_STEP      = 0x1392

NCASES = 10

# name on disk -> (expected bytes, is text-compare)
CASES = [
    ('OUT1', EXPECT_OUT1, R_STATUS1, EXPECT_STATUS1),
    ('OUT2', EXPECT_OUT2, R_STATUS2, EXPECT_STATUS2),
    ('OUT3', EXPECT_OUT3, R_STATUS3, EXPECT_STATUS3),
    ('OUT4', EXPECT_OUT4, R_STATUS4, EXPECT_STATUS4),
    ('OUT5', EXPECT_OUT5, R_STATUS5, EXPECT_STATUS5),
    ('OUT6', EXPECT_OUT6, R_STATUS6, EXPECT_STATUS6),
    ('OUT7', EXPECT_OUT7, R_STATUS7, EXPECT_STATUS7),
    ('OUT8', EXPECT_OUT8, R_STATUS8, EXPECT_STATUS8),
    ('OUT9', EXPECT_STDERR9, R_STATUS9, EXPECT_STATUS9),
    ('OUTE', EXPECT_OUTE, R_ESTATUS, EXPECT_ESTATUS),
]

POISON = 0xA5
# Banks a spawned child can land in on this image -- bank 1 is the
# parent (difftestb.s's PARENT_PROC). Poisoned wholesale rather than
# predicted, and asserted afterwards against the pids that came back.
CAND_BANKS = range(2, 10)

# gap number (the diff run that just finished, 1-based) -> which byte
# of R_PIDS names the bank it ran in.
GAP_PID_ADDR = {n: R_PIDS + (n - 1) for n in range(1, NCASES)}


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


def poison_arena(client, bank, lo, span):
    client.call_tool('poke', {
        'addr': lo, 'bytes': [POISON] * span,
        'bank': 'aux', 'aux_bank': bank,
    })


def kernel_symbol(name):
    """Address of a MAIN-memory kernel cell in the difftest image --
    check_ls.py's technique (assemble the harness with -v1 in a
    private tree and read the dump, arena.private_listing)."""
    import re
    lines = arenamod.private_listing('src/test', 'difftest.s',
                                     'MAUXDIFFTEST.SYSTEM_Output.txt')
    addr = None
    for line in lines:
        m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\$([0-9A-Fa-f]+)\s*$',
                     line)
        if m and m.group(1) == name:
            addr = int(m.group(2), 16)
    if addr is None:
        raise RuntimeError(f'{name} absent from the difftest symbol dump')
    return addr


def read_prodos_files(disk):
    prodos.mount(disk)
    try:
        names = [name for name, *_ in CASES] + ['RESULT']
        return {name: prodos.read(f'/mnt/{VOL}/{name}') for name in names}
    finally:
        prodos.unmount(VOL)


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}',
              file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make diff-image first',
              file=sys.stderr)
        return 2

    diff_arena, diff_span = arenamod.arena_span('diff')
    ed_arena, ed_span = arenamod.arena_span('ed')

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-diff] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-diff] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        # -- LAYER 1: the pre-boot poison, read back before stepping at
        # -- all. Both diff's arena AND ed's -- ed is a DIFFERENT
        # -- program, tagged and poisoned independently, even though
        # -- it is only spawned once here.
        print(f'[check-diff] poisoning liba+diff arenas '
              f'${diff_arena:04X}+{diff_span} AND liba+ed arenas '
              f'${ed_arena:04X}+{ed_span} with ${POISON:02X} in aux '
              f'banks {CAND_BANKS.start}-{CAND_BANKS.stop - 1}',
              file=sys.stderr)
        for bank in CAND_BANKS:
            poison_arena(client, bank, diff_arena, diff_span)
            back = peek_bank(client, bank, diff_arena, 8)
            if any(b != POISON for b in back):
                raise RuntimeError(
                    f'diff poison poke into bank {bank} read back {back} '
                    f'-- it did not land, the run would prove nothing')
            poison_arena(client, bank, ed_arena, ed_span)
            back = peek_bank(client, bank, ed_arena, 8)
            if any(b != POISON for b in back):
                raise RuntimeError(
                    f'ed poison poke into bank {bank} read back {back} '
                    f'-- it did not land, the run would prove nothing')

        warm_addr = kernel_symbol('LZ_WARM')

        # -- LAYER 2: the between-run poison, diff runs only.
        # -- difftestb.s's PARENT_PROC publishes the gap number (the
        # -- diff run that just finished, 1-based) in R_GO_REQ after
        # -- runs 1-9 and parks (WAIT_GO) until R_GO matches, so the
        # -- scribble lands strictly between one run's reap and the
        # -- next one's spawn -- never racing SYS_SPAWN.
        served = {}
        failed_poison = []
        warm_by_gap = {}
        done = 0
        for _ in range(4000):
            client.call_tool('step', {'cycles': 200_000})
            req = peek_aux1(client, R_GO_REQ)[0]
            if req in GAP_PID_ADDR and req not in served:
                # LZ_WARM at THIS instant still describes the spawn that
                # JUST retired into the gap we're servicing (nothing else
                # spawns between a run's WAIT completing and this poke),
                # so gap N's reading is run N's own warm/cold verdict --
                # unlike the end-of-boot reading, which the final `ed`
                # spawn (a different, first-ever-spawned program) would
                # always show cold and say nothing about diff at all.
                warm_by_gap[req] = client.call_tool('peek', {
                    'addr': warm_addr, 'count': 1,
                    'bank': 'main'})['bytes'][0]
                bank = peek_aux1(client, GAP_PID_ADDR[req])[0]
                poison_arena(client, bank, diff_arena, diff_span)
                back = peek_bank(client, bank, diff_arena, 8)
                if any(b != POISON for b in back):
                    failed_poison.append((req, bank, back))
                served[req] = bank
                print(f'[check-diff] gap {req}: poisoned bank {bank} '
                      f'${diff_arena:04X}+{diff_span} and released the '
                      f'parent', file=sys.stderr)
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

        statuses = {}
        for name, _, status_addr, _ in CASES:
            statuses[name] = peek_aux1(client, status_addr)[0]
        edstatus = peek_aux1(client, R_EDSTATUS)[0]
        diff_pids = list(peek_aux1(client, R_PIDS, NCASES))
        ed_pid = peek_aux1(client, R_EDPID)[0]

        print(f'[check-diff] done=${done:02X} err=${err:02X} '
              f'step=${step:02X} poisoned={served} LZ_WARM=${warm:02X}')
        print(f'[check-diff] statuses={statuses} edstatus={edstatus} '
              f'diff_pids={diff_pids} ed_pid={ed_pid}')

        failures = []
        if done != 0xAA:
            failures.append(f'test did not finish successfully '
                            f'(done=${done:02X}, err=${err:02X}, '
                            f'step={step})')

        if done == 0xAA:
            for i, pid in enumerate(diff_pids, start=1):
                if pid == 0:
                    failures.append(f'diff run {i}: SPAWN(DIFF) returned '
                                    f'pid 0')
                # -- VACUITY GUARD for the poison: a pid IS its bank
                # -- (src/kernel/process.s), so a child outside the
                # -- poisoned range ran on clean memory and proved
                # -- nothing about diff's uncleared arena.
                if pid and pid not in CAND_BANKS:
                    failures.append(
                        f'diff run {i}: child pid/bank {pid} is outside '
                        f'the poisoned range {CAND_BANKS.start}-'
                        f'{CAND_BANKS.stop - 1}, so this run did not '
                        f'exercise diff\'s uncleared arena at all. Widen '
                        f'CAND_BANKS.')
            if ed_pid == 0:
                failures.append('ed: SPAWN(ED) returned pid 0')
            if ed_pid and ed_pid not in CAND_BANKS:
                failures.append(
                    f'ed: child pid/bank {ed_pid} is outside the poisoned '
                    f'range {CAND_BANKS.start}-{CAND_BANKS.stop - 1}, so '
                    f'the round trip did not exercise ed\'s uncleared '
                    f'arena at all. Widen CAND_BANKS.')

        for name, expect_bytes, status_addr, expect_status in CASES:
            got_status = statuses[name]
            if got_status != expect_status:
                failures.append(f'{name}: exit status expected '
                                f'{expect_status}, got {got_status}')

        if edstatus != EXPECT_EDSTATUS:
            failures.append(f'ed round trip: exit status expected '
                            f'{EXPECT_EDSTATUS}, got {edstatus}')

        # -- THE BETWEEN-RUN POISON'S OWN GUARDS (check_ls.py's set) --
        if sorted(served) != sorted(GAP_PID_ADDR):
            failures.append(f'expected to service handshake gaps '
                            f'{sorted(GAP_PID_ADDR)}, serviced '
                            f'{sorted(served)} -- the poison did not land '
                            f'between every pair of diff runs')
        for gap, bank, back in failed_poison:
            failures.append(f'gap {gap}: the ${POISON:02X} poke into bank '
                            f'{bank} read back {back} -- the poison did '
                            f'not land, so the run after it proved nothing')
        for gap, bank in served.items():
            if bank != diff_pids[gap - 1]:
                failures.append(f'gap {gap}: poisoned bank {bank} but diff '
                                f'run {gap} ran in bank {diff_pids[gap - 1]}')
        if done == 0xAA and len(set(diff_pids)) != 1:
            failures.append(
                f'diff runs did not share one bank ({diff_pids}) -- a pid '
                f'IS its bank, so this means the retained bank was NOT '
                f'reused and the between-run poison went somewhere the '
                f'next run never touched. The gate is vacuous in that '
                f'state, not merely weaker.')
        # LZ_WARM read at the very end reflects `ed`'s spawn -- the
        # first and only time ed is ever spawned here, so it is
        # ALWAYS cold and asserting on it would fail every green run.
        # The real warm-respawn proof is warm_by_gap: gap N's own
        # LZ_WARM reading describes diff run N's spawn, and runs 2..9
        # are exactly the ones that should have been served from the
        # bank run 1 (or its predecessor) tagged.
        if done == 0xAA:
            for gap in range(2, NCASES):
                if not warm_by_gap.get(gap):
                    failures.append(
                        f'LZ_WARM was clear at gap {gap} -- diff run '
                        f'{gap} was NOT served from a retained bank, so '
                        f'this run\'s poison never met a warm respawn')

        if failures:
            for failure in failures:
                print(f'[check-diff] FAIL: {failure}', file=sys.stderr)
            return 1

        files = read_prodos_files(disk)
        for name, expect_bytes, _, _ in CASES:
            got = files[name]
            if got != expect_bytes:
                print(f'[check-diff] FAIL: {name} expected '
                      f'{expect_bytes!r}, got {got!r}', file=sys.stderr)
                return 1

        result = files['RESULT']
        if result != EXPECT_RESULT:
            print(f'[check-diff] FAIL: RESULT (diff -e | ed round trip) '
                  f'expected {EXPECT_RESULT!r}, got {result!r}',
                  file=sys.stderr)
            return 1

        print('[check-diff] PASS: all 9 output-format cases (identical/'
              'add/delete/change/multi-hunk/first-line/last-line/empty/'
              'overflow) byte-exact and status-exact; diff -e | ed round '
              'trip reproduced B5 byte-exact -- with liba\'s arena AND '
              f'diff\'s own ({diff_span} bytes) pre-filled with '
              f'${POISON:02X} in every candidate child bank AND '
              f're-scribbled in all {len(served)} between-run gaps into '
              f'bank {diff_pids[0]}, which all ten diff runs reused '
              f'(LZ_WARM set at the final -- ed -- spawn); ed\'s own '
              f'arena ({ed_span} bytes) pre-filled the same way for its '
              f'single spawn (bank {ed_pid})')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
