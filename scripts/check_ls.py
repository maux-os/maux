#!/usr/bin/env python3
"""Boot and verify the ProDOS-hosted `ls` acceptance gate (`make check-ls`).

Companion to src/test/lstest.s / scripts/build_ls_image.py -- same shape as
scripts/check_catread.py (boot, poll the R_DONE sentinel, peek fixed result
addresses in aux bank 1, byte-exact compare), extended to the 4 runs
lstestb.s's PARENT_PROC performs: plain listing, `-l` directory listing,
`-l` single-file GET_FILE_INFO stat, and a nonexistent-path error.

Every expected byte string here comes from build_ls_image.compute_expected()
-- see that function's docstring for why it re-reads the FINAL image rather
than reusing a build-time constant (this script and build_ls_image.py are
separate `python3` processes; see the Makefile fragment in the task
report).

THE POISON (2026-08-22, docs/STICKY.md sec 25, WIDENED by sec 28).
liba's whole arena AND ls's own arena are filled with $A5 in every
candidate child bank before the machine is stepped, and `ls` then has
to produce the same four byte-exact results anyway. The span runs
LIBA_ZPG..LS_BSSEND; it used to stop at LIBA_BSSEND, which is the
first byte of ls's own arena, so before sec 28 this gate covered
liba's storage and none of the program's.

This is the counterpart to check_catread.py's poison, aimed the
other way: that gate proves the kernel's 256-byte page IS zeroed, this one
proves nothing outside it NEEDS to be. Sec 25 moved 42 more liba cells out
of emitted text and into uncleared `dum` -- readdir's whole directory
cursor, its 512-byte block buffer and its three MLI parmlists among them,
all of which used to arrive as emitted zeros in every ls/du/find image. The
claim that every one of them is written before it is read was made by
reading the code; under $A5 it is made by the machine. A cell that is
actually read first sees $A5A5 here, and `ls` -- which walks a directory
through all of it -- gets a wrong entry length, a wrong file count or a
read into a random address.

`ls` is the widest single carrier of the converted set (readdir + hex +
num, 556 of the 591 bytes), which is why the poison went here rather than
into check-du/check-find.

THE POISON *BETWEEN* RUNS (2026-08-22, docs/STICKY.md sec 25's own gate).
Lazy free makes the pre-boot poison above necessary but no longer
sufficient, and sec 25 says why: a fresh bank's uncleared memory holds an
UNRELATED occupant's leftovers, usually visibly wrong, while a RETAINED
bank holds the previous run of the SAME PROGRAM -- same addresses, same
layout -- so a write-before-read bug reads a plausible value instead of
obvious garbage, and it does so on the second invocation only.

So the arena is re-poisoned in the gap between every pair of runs, in the
bank the run that just finished actually used, and run 5 is a byte-for-byte
repeat of run 1 whose output must match run 1's exactly. lstestb.s parks on
R_GO in each gap so the poison cannot race the next SYS_SPAWN -- stepping
in chunks and poking when the driver notices would land the poison in the
middle of a spawn and prove nothing.

Four things keep it from passing vacuously:
  * every run must report the SAME pid, which IS its bank number -- that is
    what makes "the bank we poisoned" and "the bank the next run reused"
    the same bank, and it fails loudly if bank reuse ever stops happening;
  * the PRE-BOOT poke into every candidate bank is read back before the
    machine is stepped at all, and a mismatch raises immediately (stream
    T2, 2026-08-23 -- this file was the one every other poisoning gate
    copied, and it was the one gate that never checked its own pre-boot
    poke landed; scripts/check_find.py's equivalent loop always had this,
    scripts/check_poison.py's derived roster gate is what would have
    caught the gap between "poisons" and "poisons AND verifies");
  * the BETWEEN-RUN poison is read back from the child bank before the
    parent is released, so a poke that silently did not land cannot pass;
  * the kernel's own LZ_WARM flag (src/kernel/lazyfree.s) must be set at
    the end, which is the kernel saying the last spawn was served from a
    retained bank rather than loaded from disk.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
import arena  # noqa: E402 -- private-tree listings
import build_ls_image as bl  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'ls.po')

R_STATUS1     = 0x1280
R_STATUS2     = 0x1281
R_STATUS3     = 0x1282
R_STATUS4     = 0x1283
R_TRANS1      = 0x1284
R_TRANS2      = 0x1286
R_TRANS3      = 0x1288
R_TRANS4      = 0x128A
R_ERRTRANS4   = 0x128C
R_SPAWN_PID1  = 0x128E
R_SPAWN_PID2  = 0x128F
R_SPAWN_PID3  = 0x1290
R_SPAWN_PID4  = 0x1291
R_WAIT_PID1   = 0x1292
R_WAIT_PID2   = 0x1293
R_WAIT_PID3   = 0x1294
R_WAIT_PID4   = 0x1295
R_DONE        = 0x1296
R_ERR         = 0x1297
R_STEP        = 0x1298
R_DATA1       = 0x12A0
R_DATA2       = 0x12E0
R_DATA3       = 0x13C0
R_DATA4       = 0x1400
R_ERRDATA4    = 0x1440
R_STATUS5     = 0x1480
R_TRANS5      = 0x1481
R_SPAWN_PID5  = 0x1483
R_WAIT_PID5   = 0x1484
R_GO_REQ      = 0x1485
R_GO          = 0x1486
R_DATA5       = 0x14B0

# gap number -> the R_WAIT_PIDn of the run that just finished. lstestb.s
# publishes the gap in R_GO_REQ and parks until R_GO matches.
GAP_WAIT_PID = {1: R_WAIT_PID1, 2: R_WAIT_PID2, 3: R_WAIT_PID3,
                4: R_WAIT_PID4}


POISON = 0xA5
# Banks a spawned child can land in on this image -- bank 1 is the
# parent (lstestb.s's PARENT_PROC). Poisoned wholesale rather than
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


def liba_arena():
    """(first byte, length) of ls's liba `dum` arena, from merlin32.

    Same technique as scripts/check_catread.py's cat_symbols(): `-v1`
    writes a symbol listing, assembled in a private tree and read from
    there (arena.private_listing). Never hardcoded -- LIBA_ZPG is LOAD_BASE + the image
    length, so it moves every time ls's code size does, and a stale
    address would poison whatever now lives there instead.
    """
    lines = arena.private_listing('src/bin', 'ls.s',
                                  'ls.bin_Output.txt')
    syms = {}
    for line in lines:
        m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\$([0-9A-Fa-f]+)\s*$',
                     line)
        if m:
            syms[m.group(1)] = int(m.group(2), 16)
    missing = [w for w in ('LIBA_ZPG', 'LIBA_BSSEND', 'LS_BSSEND')
               if w not in syms]
    if missing:
        raise RuntimeError(
            f'{missing} absent from ls.bin_Output.txt -- has the sec-21 '
            f'layout (src/liba/libabss.s, `put` last) changed?')
    # THE SPAN RUNS TO LS_BSSEND, NOT LIBA_BSSEND (2026-08-22,
    # docs/STICKY.md sec 28). Until sec 28 this stopped at
    # LIBA_BSSEND -- which is EXACTLY where ls's own arena begins, so
    # the poison ended one byte before the storage it most needed to
    # cover. Sec 28 moved 4,443 bytes of ls's own scratch out of
    # emitted text and into that arena (ENTRIES alone is 4,096, more
    # than half of what ls.bin used to be), and a gate that poisons
    # up to the first of those bytes and stops proves nothing about
    # any of them. Both ends still come from merlin32's own symbol
    # table rather than a constant: LIBA_ZPG is LOAD_BASE + image
    # length and LS_BSSEND is past a `dum` arena, so both move every
    # time ls's code size does.
    return (syms['LIBA_ZPG'],
            syms['LS_BSSEND'] - syms['LIBA_ZPG'])


def peek_u16(client, addr):
    b = peek_aux1(client, addr, 2)
    return b[0] | (b[1] << 8)


def kernel_symbol(name):
    """Address of a MAIN-memory kernel cell in the lstest image.

    Same technique as liba_arena() one level up: assemble the image
    manifest with `-v1` in a private tree, read merlin32's own symbol
    dump. Never
    hardcoded -- LZ_WARM is a `ds` cell in src/kernel/lazyfree.s and moves
    whenever any kernel module's size does, and a stale address would read
    an unrelated byte and pass or fail for no reason.
    """
    lines = arena.private_listing('src/test', 'lstest.s',
                                  'MAUXLSTEST.SYSTEM_Output.txt')
    addr = None
    for line in lines:
        m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\$([0-9A-Fa-f]+)\s*$',
                     line)
        if m and m.group(1) == name:
            addr = int(m.group(2), 16)
    if addr is None:
        raise RuntimeError(f'{name} absent from the lstest symbol dump')
    return addr


def poison_arena(client, bank, arena, span):
    client.call_tool('poke', {
        'addr': arena, 'bytes': [POISON] * span,
        'bank': 'aux', 'aux_bank': bank,
    })


def main_lstest():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}', file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make ls-image first',
              file=sys.stderr)
        return 2

    expected = bl.compute_expected(disk)

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-ls] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-ls] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        # -- THE POISON (see this file's header). liba's arena is
        # -- uncleared `dum` except for the kernel's 256-byte page at
        # -- its head, so every byte of it that ls reads must be a
        # -- byte ls wrote first. $A5 is what "must" looks like.
        arena, span = liba_arena()
        print(f'[check-ls] poisoning liba+ls arenas ${arena:04X}+{span} '
              f'with ${POISON:02X} in aux banks {CAND_BANKS.start}-'
              f'{CAND_BANKS.stop - 1} (docs/STICKY.md sec 25)',
              file=sys.stderr)
        for bank in CAND_BANKS:
            poison_arena(client, bank, arena, span)
            back = peek_bank(client, bank, arena, 8)
            if any(b != POISON for b in back):
                raise RuntimeError(
                    f'poison poke into bank {bank} read back {back} -- '
                    f'it did not land, the run would prove nothing')

        warm_addr = kernel_symbol('LZ_WARM')

        # -- THE POISON BETWEEN RUNS. lstestb.s publishes a gap number in
        # -- R_GO_REQ after each run and parks until R_GO matches, so the
        # -- scribble lands strictly between one run's reap and the next
        # -- one's spawn.
        served = {}
        failed_poison = []
        done = 0
        for i in range(1200):
            client.call_tool('step', {'cycles': 200_000})
            req = peek_aux1(client, R_GO_REQ)[0]
            if req in GAP_WAIT_PID and req not in served:
                bank = peek_aux1(client, GAP_WAIT_PID[req])[0]
                poison_arena(client, bank, arena, span)
                back = peek_bank(client, bank, arena, 8)
                if any(b != POISON for b in back):
                    failed_poison.append((req, bank, back))
                served[req] = bank
                print(f'[check-ls] gap {req}: poisoned bank {bank} '
                      f'${arena:04X}+{span} and released the parent',
                      file=sys.stderr)
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

        status = [peek_aux1(client, a)[0]
                  for a in (R_STATUS1, R_STATUS2, R_STATUS3, R_STATUS4,
                            R_STATUS5)]
        trans = [peek_u16(client, a)
                 for a in (R_TRANS1, R_TRANS2, R_TRANS3, R_TRANS4, R_TRANS5)]
        err_trans = peek_u16(client, R_ERRTRANS4)
        spawn_pid = [peek_aux1(client, a)[0] for a in
                     (R_SPAWN_PID1, R_SPAWN_PID2, R_SPAWN_PID3, R_SPAWN_PID4,
                      R_SPAWN_PID5)]
        wait_pid = [peek_aux1(client, a)[0] for a in
                    (R_WAIT_PID1, R_WAIT_PID2, R_WAIT_PID3, R_WAIT_PID4,
                     R_WAIT_PID5)]

        data1 = bytes(peek_aux1(client, R_DATA1, len(expected['run1'])))
        data2 = bytes(peek_aux1(client, R_DATA2, len(expected['run2'])))
        data3 = bytes(peek_aux1(client, R_DATA3, len(expected['run3'])))
        data4 = bytes(peek_aux1(client, R_DATA4, trans[3])) if trans[3] else b''
        errdata4 = bytes(peek_aux1(client, R_ERRDATA4, len(expected['run4_err'])))
        data5 = bytes(peek_aux1(client, R_DATA5, len(expected['run1'])))

        print(f'[check-ls] done=${done:02X} err=${err:02X} step=${step:02X} '
              f'status={status} spawn_pid={spawn_pid} wait_pid={wait_pid} '
              f'trans={trans} err_trans={err_trans} '
              f'poisoned={served} LZ_WARM=${warm:02X}')

        failures = []
        if done != 0xAA:
            failures.append(f'test did not finish successfully '
                            f'(done=${done:02X}, err=${err:02X}, step={step})')
        if err != 0:
            failures.append(f'R_ERR expected $00, got ${err:02X}')
        for i in range(5):
            if spawn_pid[i] == 0:
                failures.append(f'run {i+1}: SPAWN(LS) returned pid 0')
            if wait_pid[i] != spawn_pid[i]:
                failures.append(f'run {i+1}: wait pid {wait_pid[i]} != '
                                f'spawn pid {spawn_pid[i]}')
            # -- VACUITY GUARD for the poison. A pid IS its bank
            # -- number (src/kernel/process.s `sta PRC_CHLD_BANK /
            # -- sta PRC_CHILD_PID`), so a child outside the poisoned
            # -- range ran on clean memory and proves nothing about
            # -- sec 25's uncleared cells.
            if spawn_pid[i] and spawn_pid[i] not in CAND_BANKS:
                failures.append(
                    f'run {i+1}: child pid/bank {spawn_pid[i]} is outside '
                    f'the poisoned range {CAND_BANKS.start}-'
                    f'{CAND_BANKS.stop - 1}, so this run did not exercise '
                    f'liba\'s uncleared arena at all. Widen CAND_BANKS.')

        # -- run 1: plain listing, sorted, case-decoded names --
        if status[0] != 0:
            failures.append(f'run 1 (ls /mnt/MAUX/LSDIR): exit status expected '
                            f'$00, got ${status[0]:02X}')
        if trans[0] != len(expected['run1']):
            failures.append(f'run 1: stdout trans_count expected '
                            f'{len(expected["run1"])}, got {trans[0]}')
        if data1 != expected['run1']:
            failures.append(f'run 1 stdout mismatch:\n'
                            f'  expected={expected["run1"]!r}\n'
                            f'  got     ={data1!r}')

        # -- run 2: -l directory listing --
        if status[1] != 0:
            failures.append(f'run 2 (ls -l /mnt/MAUX/LSDIR): exit status '
                            f'expected $00, got ${status[1]:02X}')
        if trans[1] != len(expected['run2']):
            failures.append(f'run 2: stdout trans_count expected '
                            f'{len(expected["run2"])}, got {trans[1]}')
        if data2 != expected['run2']:
            failures.append(f'run 2 stdout mismatch:\n'
                            f'  expected={expected["run2"]!r}\n'
                            f'  got     ={data2!r}')

        # -- run 3: -l single-file GET_FILE_INFO stat --
        if status[2] != 0:
            failures.append(f'run 3 (ls -l .../{bl.GFI_TARGET}): exit '
                            f'status expected $00, got ${status[2]:02X}')
        if trans[2] != len(expected['run3']):
            failures.append(f'run 3: stdout trans_count expected '
                            f'{len(expected["run3"])}, got {trans[2]}')
        if data3 != expected['run3']:
            failures.append(f'run 3 stdout mismatch:\n'
                            f'  expected={expected["run3"]!r}\n'
                            f'  got     ={data3!r}')

        # -- THE POISON-BETWEEN-RUNS GATE (docs/STICKY.md sec 25) --
        if sorted(served) != [1, 2, 3, 4]:
            failures.append(f'expected to service handshake gaps 1-4, '
                            f'serviced {sorted(served)} -- the poison did '
                            f'not land between every pair of runs')
        for gap, bank, back in failed_poison:
            failures.append(f'gap {gap}: the ${POISON:02X} poke into bank '
                            f'{bank} read back as {back} -- the poison did '
                            f'not land, so the run after it proved nothing')
        for gap, bank in served.items():
            if bank != spawn_pid[gap - 1]:
                failures.append(f'gap {gap}: poisoned bank {bank} but run '
                                f'{gap} ran in bank {spawn_pid[gap - 1]}')
        if len(set(spawn_pid)) != 1:
            failures.append(
                f'runs did not share one bank ({spawn_pid}) -- a pid IS its '
                f'bank, so this means the retained bank was NOT reused and '
                f'the between-run poison went somewhere the next run never '
                f'touched. The gate is vacuous in that state, not merely '
                f'weaker.')
        if not warm:
            failures.append(
                'LZ_WARM is clear after the final run -- the kernel says the '
                'last spawn was NOT served from a retained bank, so nothing '
                'here exercised the no-copy respawn path at all')
        if status[4] != 0:
            failures.append(f'run 5 (ls /mnt/MAUX/LSDIR, repeat of run 1): exit '
                            f'status expected $00, got ${status[4]:02X}')
        if data5 != data1:
            failures.append(
                f'run 5 is run 1 repeated -- into the SAME bank, after that '
                f'bank was poisoned with ${POISON:02X} -- and its output '
                f'differs:\n  run 1={data1!r}\n  run 5={data5!r}')
        if data5 != expected['run1']:
            failures.append(f'run 5 stdout mismatch:\n'
                            f'  expected={expected["run1"]!r}\n'
                            f'  got     ={data5!r}')

        # -- run 4: nonexistent path -- stderr message + nonzero exit --
        if status[3] != expected['run4_status']:
            failures.append(f'run 4 (ls /mnt/MAUX/NOSUCH): exit status '
                            f'expected {expected["run4_status"]}, '
                            f'got {status[3]}')
        if trans[3] != 0:
            failures.append(f'run 4: stdout expected EMPTY (0 bytes), '
                            f'got {trans[3]} bytes: {data4!r}')
        if err_trans != len(expected['run4_err']):
            failures.append(f'run 4: stderr trans_count expected '
                            f'{len(expected["run4_err"])}, got {err_trans}')
        if errdata4 != expected['run4_err']:
            failures.append(f'run 4 stderr mismatch:\n'
                            f'  expected={expected["run4_err"]!r}\n'
                            f'  got     ={errdata4!r}')

        if failures:
            for failure in failures:
                print(f'[check-ls] FAIL: {failure}', file=sys.stderr)
            return 1

        print('[check-ls] PASS: ls -- plain listing, -l directory listing, '
              '-l single-file GET_FILE_INFO stat, and the nonexistent-path '
              'error path -- all byte-exact against a real spawned binary, '
              f'with liba\'s arena AND ls\'s own -- {span} bytes, '
              f'LIBA_ZPG..LS_BSSEND -- pre-filled with '
              f'${POISON:02X} in every candidate child bank (docs/STICKY.md '
              'sec 25/sec 28: outside the kernel\'s 256-byte page, nothing '
              'liba OR ls reads may be a byte it did not write first)')
        print(f'[check-ls] PASS: poison between runs -- bank '
              f'{spawn_pid[0]} was re-scribbled with ${POISON:02X} in all '
              f'four gaps, every run reused it (LZ_WARM set: the kernel '
              f'copied no image), and run 5 -- run 1 repeated after two '
              f'`-l` runs and an error run -- came back byte-identical to '
              f'run 1 ({len(data5)} bytes)')
        return 0
    finally:
        client.close()


def main():
    """The five staged-image `ls` runs, then the runtime-create phase
    (check_ls_case.py: names the KERNEL creates/renames carry GS/OS case
    flags -- docs/PRODOS-CASE.md).  Both must pass."""
    rc = main_lstest()
    if rc:
        return rc
    import check_ls_case
    return check_ls_case.run()


if __name__ == '__main__':
    raise SystemExit(main())
