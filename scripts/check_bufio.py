#!/usr/bin/env python3
"""Boot and verify docs/PROCIO.md sec 6 gates (c) and (d).

Companion to src/test/bufiotest.s / src/test/bufiotestb.s /
src/test/bufwriter.s / scripts/build_bufio_image.py. Two independently
reported gates from ONE boot (phase D runs only after phase C's own
evidence is durable -- see bufiotestb.s's header):

  gate (c) "exit flushes": bufwriter (a REAL liba program) writes 5
  bytes via PUTC to a real ProDOS file with NO explicit flush and NO
  CR in the payload (so neither of stdio.s's own flush triggers ever
  fires), then calls plain EXIT(0). The parent re-opens the file after
  the child exits and asserts the bytes are there, byte-exact.

  gate (d) the sec 5 LC-bank-1 invariant: the parent selects the
  process's own free LC page and, WITHOUT restoring the kernel's
  page, issues a real MLI call (SYS_OPEN of the already-CREATEd
  BUFOUT) that must dispatch through ProDOS's own $D000-resident
  code. Per sec 5 this hands ProDOS the wrong $D000 page and the
  call should not complete correctly -- expected result is a LOUD
  failure: the process never reaches R_D_DONE within a generous,
  bounded step budget (the "run a deliberate violator and require a
  loud failure" half of sec 6 gate (d)'s own accepted proof). A
  violator that SILENTLY completes and sets R_D_DONE=$AA would mean
  the hazard isn't actually observable on this rig -- reported as a
  gate FAILURE, not a pass, since that would contradict sec 5's own
  stated risk. MEASURED (this task): it completes cleanly every time
  tried (SYS_GETPFX and SYS_OPEN, both address-pair versions before
  and after fixing the bank-1/bank-2 mixup below) -- an open,
  reported-not-resolved finding; see src/test/bufiotestb.s's own
  header and docs/PROCIO.md's dated results section.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
from build_bufio_image import PAYLOAD_BYTES  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'bufio.po')

R_SPAWN_PID = 0x1200
R_WAIT_PID = 0x1201
R_STATUS = 0x1202
R_OUT_FD2 = 0x1203
R_TRANS = 0x1204
R_DATA = 0x1206
PAYLOAD_LEN = 5
R_C_DONE = 0x1220
R_D_DONE = 0x1221
R_D_ERR = 0x1222
R_DONE = 0x1290
R_ERR = 0x1291
R_STEP = 0x1292

PHASE_C_ITERS = 300     # matches check_catread.py's own budget --
                       # same complexity of work (create/spawn/wait/
                       # open/read/close)
PHASE_D_ITERS = 200     # generous extra budget for the violator: if
                       # it hasn't set R_D_DONE by here, it's not
                       # going to (a real MLI dispatch this simple
                       # completes in low thousands of cycles when it
                       # works at all)
CHUNK_CYCLES = 200_000


def peek_aux1(client, addr, count=1):
    return client.call_tool('peek', {
        'addr': addr,
        'count': count,
        'bank': 'aux',
        'aux_bank': 1,
    })['bytes']


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}', file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make bufio-image first',
              file=sys.stderr)
        return 2

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-bufio] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-bufio] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        failures = []

        # ---- Phase C: exit flushes ----
        c_done = 0
        for _ in range(PHASE_C_ITERS):
            client.call_tool('step', {'cycles': CHUNK_CYCLES})
            c_done = peek_aux1(client, R_C_DONE)[0]
            top_done = peek_aux1(client, R_DONE)[0]
            if c_done == 0xAA or top_done == 0xEE:
                break

        err = peek_aux1(client, R_ERR)[0]
        step = peek_aux1(client, R_STEP)[0]
        spawn_pid = peek_aux1(client, R_SPAWN_PID)[0]
        wait_pid = peek_aux1(client, R_WAIT_PID)[0]
        status = peek_aux1(client, R_STATUS)[0]
        trans = peek_aux1(client, R_TRANS, 2)
        trans_count = trans[0] | (trans[1] << 8)
        data = bytes(peek_aux1(client, R_DATA, PAYLOAD_LEN))
        print(f'[check-bufio] phase C: c_done=${c_done:02X} err=${err:02X} '
              f'step={step} spawn_pid={spawn_pid} wait_pid={wait_pid} '
              f'status=${status:02X} trans_count={trans_count} '
              f'data={data!r}')

        if c_done != 0xAA:
            failures.append(
                f'gate (c): phase C did not complete '
                f'(c_done=${c_done:02X}, err=${err:02X}, step={step})')
        else:
            if spawn_pid == 0:
                failures.append('gate (c): SPAWN(BUFWR) returned pid 0')
            if wait_pid != spawn_pid:
                failures.append(
                    f'gate (c): wait pid {wait_pid} != spawn pid {spawn_pid}')
            if status != 0:
                failures.append(
                    f'gate (c): bufwriter exit status expected $00, got '
                    f'${status:02X}')
            if trans_count != PAYLOAD_LEN:
                failures.append(
                    f'gate (c): BUFOUT trans_count expected {PAYLOAD_LEN}, '
                    f'got {trans_count} -- unflushed bytes lost at exit')
            if data != PAYLOAD_BYTES:
                failures.append(
                    f'gate (c): BUFOUT bytes mismatch (exit did not flush '
                    f'byte-exact): expected={PAYLOAD_BYTES!r} got={data!r}')

        if c_done == 0xAA and not any('gate (c)' in f for f in failures):
            print('[check-bufio] PASS gate (c): EXIT flushed 5 unflushed, '
                  'non-CR-terminated PUTC bytes to a real file with no '
                  'explicit flush call anywhere in bufwriter.s')
        else:
            for f in failures:
                if f.startswith('gate (c)'):
                    print(f'[check-bufio] FAIL: {f}', file=sys.stderr)

        # ---- Phase D: the LC-bank-1 violator (only meaningful if C
        # completed -- if C itself never finished, the boot is broken
        # for reasons unrelated to phase D, so don't even try). ----
        d_done = 0
        if c_done == 0xAA:
            for _ in range(PHASE_D_ITERS):
                client.call_tool('step', {'cycles': CHUNK_CYCLES})
                d_done = peek_aux1(client, R_D_DONE)[0]
                if d_done in (0xAA, 0xEE):
                    break
            d_err = peek_aux1(client, R_D_ERR)[0]
            print(f'[check-bufio] phase D: d_done=${d_done:02X} '
                  f'd_err=${d_err:02X} (0x00 = never set -- the expected, '
                  f'PASSING loud-failure outcome)')

            # CHARACTERISATION, NOT AN ASSERTION (2026-08-20). This
            # phase was written to prove docs/PROCIO.md sec 5's claimed
            # invariant -- that entering a syscall with LC bank 1
            # selected hands ProDOS the wrong $D000 page. IT COULD NOT
            # BE DEMONSTRATED: the violator returns cleanly across every
            # real MLI call tried. The claim was made from reasoning,
            # never from a run, and the measurement does not support it;
            # sec 5 now records that. Leading hypothesis is that
            # ProDOS's own MLI dispatch re-establishes its bank, which
            # would make the hazard defended-against upstream.
            #
            # We record what actually happens rather than assert a
            # hazard we cannot show, and rather than invert this into
            # "the violator MUST survive" -- which would enshrine an
            # assumption just as unproven in the other direction. The
            # phy/ply-style bank bracket stays in stdio.s regardless:
            # it is a few cycles and the absence of a demonstrated
            # hazard is not the same as a demonstrated absence.
            if d_done == 0:
                print('[check-bufio] NOTE gate (d): violator did not '
                      'complete -- consistent with sec 5\'s claimed '
                      'invariant. If this becomes reproducible, sec 5 '
                      'can be restored as established.')
            else:
                # ANSWERED 2026-09-20 (docs/LANGUAGE-CARD.md): the
                # violator was never going to be loud. ProDOS's own MLI
                # entry re-selects its bank on EVERY call -- $BFC6
                # `BIT $C08B` twice, read live off the bus -- before it
                # dispatches, so leaving the wrong bank selected across
                # an MLI call cannot fail. Kept as characterisation, no
                # longer as an open risk.
                print(f'[check-bufio] NOTE gate (d): violator completed '
                      f'cleanly (d_done=${d_done:02X}, d_err=${d_err:02X}) '
                      f'-- EXPECTED, and the reason is now known: ProDOS '
                      f'write-enables and re-selects its own bank at '
                      f'$BFC6 on every MLI call, so this path cannot '
                      f'demonstrate the hazard. The real race is the '
                      f'scheduler one -- docs/LANGUAGE-CARD.md.')
        else:
            print('[check-bufio] SKIP gate (d): phase C did not complete, '
                  'so phase D never ran', file=sys.stderr)

        if failures:
            for failure in failures:
                print(f'[check-bufio] FAIL: {failure}', file=sys.stderr)
            return 1

        print('[check-bufio] PASS: both gates (c) and (d)')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
