#!/usr/bin/env python3
"""Boot and verify the `sum`/`date` acceptance gate (`make check-
sumdate`).

Companion to src/test/sumdatetest.s / sumdatetestb.s /
scripts/build_sumdate_image.py.

  Phase 1 (`sum`): a single invocation on an empty file, a one-byte
  file and a 600-byte (2-block) file. SUMOUT is read back off the
  built image and compared byte-exact against build_sumdate_image.py's
  hand-computed (Python, independent of the 6502 rotate) expectation.

  Phase 2 (`date`): the harness spawns `date` and, immediately after
  WAIT returns (before anything else can touch the filesystem), calls
  SYS_CLOCK itself to capture the exact 4 raw bytes `date`'s own
  internal read saw (sumdatetestb.s's DO_CLOCK -- no timing race).
  This script decodes those bytes in Python -- the SAME legacy/
  Extended validity rule docs/PRODOS-VERSION.md gives -- and asserts
  DATEOUT/DATEERR/exit status against THAT decode, whatever it says,
  rather than assuming a specific wall-clock value.

  Run TWICE, against the SAME built image, once per verilogapple
  `reset(clock=...)` setting (docs/FLEET.md's own knob) -- clock
  present (the default) and clock absent -- so both of `date`'s paths
  (a real reading, and the "no valid clock" refusal) get exercised.
  The image is rebuilt between the two runs (build_sumdate_image.main())
  since the first run's CREATE calls leave SUMOUT/DATEOUT/DATEERR on
  the disk and a second CREATE of the same name would fail.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402
import build_sumdate_image  # noqa: E402
from build_sumdate_image import EXPECT_SUMOUT  # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from a2til import prodos  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'sumdate.po')
VOL = 'MAUX'

R_SUM_FD      = 0x1300
R_SUM_PID     = 0x1301
R_SUM_WAIT    = 0x1302
R_SUM_STATUS  = 0x1303
R_DATE_OUTFD  = 0x1304
R_DATE_ERRFD  = 0x1305
R_DATE_PID    = 0x1306
R_DATE_WAIT   = 0x1307
R_DATE_STATUS = 0x1308
R_CLOCK_RAW   = 0x1309
R_DONE        = 0x1390
R_ERR         = 0x1391
R_STEP        = 0x1392

NOCLKMSG = (bytes(ord(c) | 0x80 for c in 'date: no valid clock reading')
            + bytes([0x8D]))


def peek_aux1(client, addr, count=1):
    return client.call_tool('peek', {
        'addr': addr,
        'count': count,
        'bank': 'aux',
        'aux_bank': 1,
    })['bytes']


def decode_date(raw4):
    """raw4 = (date_lo, date_hi, minute, hour). Returns (text, valid)
    -- text is the expected "YYYY-MM-DD HH:MM" high-bit-ASCII CR
    string when valid, else None. Mirrors docs/PRODOS-VERSION.md's
    ruling exactly: hour<=23 AND minute<=59 (raw, unmasked) = legacy;
    year7 pivots at 78."""
    date_lo, date_hi, minute, hour = raw4
    if date_lo == 0 and date_hi == 0:
        return None
    if hour >= 24 or minute >= 60:
        return None
    day = date_lo & 0x1F
    month = ((date_lo >> 5) & 0x07) | ((date_hi & 0x01) << 3)
    year7 = (date_hi >> 1) & 0x7F
    cent = '19' if year7 >= 78 else '20'
    text = f'{cent}{year7:02d}-{month:02d}-{day:02d} {hour:02d}:{minute:02d}'
    return bytes(ord(c) | 0x80 for c in text) + bytes([0x8D])


def run_session(client, clock, label):
    r = client.call_tool('reset', {'backend': 'fast', 'clock': clock})
    print(f'[check-sumdate] {label}: reset -> {r}', file=sys.stderr)
    r = client.call_tool('mount_disk', {'path': os.path.abspath(DISK)})
    print(f'[check-sumdate] {label}: mount_disk -> {r}', file=sys.stderr)
    if r.get('ok') is False:
        raise RuntimeError(f'mount_disk failed: {r}')

    done = 0
    for _ in range(1500):
        client.call_tool('step', {'cycles': 200_000})
        done = peek_aux1(client, R_DONE)[0]
        if done in (0xAA, 0xEE):
            break

    err = peek_aux1(client, R_ERR)[0]
    step = peek_aux1(client, R_STEP)[0]
    sum_pid = peek_aux1(client, R_SUM_PID)[0]
    sum_wait = peek_aux1(client, R_SUM_WAIT)[0]
    sum_status = peek_aux1(client, R_SUM_STATUS)[0]
    date_pid = peek_aux1(client, R_DATE_PID)[0]
    date_wait = peek_aux1(client, R_DATE_WAIT)[0]
    date_status = peek_aux1(client, R_DATE_STATUS)[0]
    clock_raw = tuple(peek_aux1(client, R_CLOCK_RAW, 4))
    bf90 = tuple(client.call_tool('peek', {
        'addr': 0xBF90, 'count': 4, 'bank': 'main',
    })['bytes'])

    print(f'[check-sumdate] {label}: done=${done:02X} err=${err:02X} '
          f'step={step}', file=sys.stderr)
    print(f'[check-sumdate] {label}: sum pid={sum_pid} wait={sum_wait} '
          f'status=${sum_status:02X}', file=sys.stderr)
    print(f'[check-sumdate] {label}: date pid={date_pid} wait={date_wait} '
          f'status=${date_status:02X} clock_raw={clock_raw} '
          f'bf90={bf90}', file=sys.stderr)

    failures = []
    if done != 0xAA:
        failures.append(f'{label}: test did not finish successfully '
                        f'(done=${done:02X}, err=${err:02X}, step={step})')
        return failures, None, None, None

    if sum_pid == 0:
        failures.append(f'{label}: SPAWN(SUM) returned pid 0')
    if sum_wait != sum_pid:
        failures.append(f'{label}: wait pid {sum_wait} != spawn pid '
                        f'{sum_pid}')
    if sum_status != 0:
        failures.append(f'{label}: sum exit status expected $00, got '
                        f'${sum_status:02X}')
    if date_pid == 0:
        failures.append(f'{label}: SPAWN(DATE) returned pid 0')
    if date_wait != date_pid:
        failures.append(f'{label}: wait pid {date_wait} != spawn pid '
                        f'{date_pid}')

    # clock_raw and bf90 should agree -- both are the ProDOS global
    # page, read moments apart with no intervening file op.
    if clock_raw != bf90:
        failures.append(f'{label}: SYS_CLOCK ground truth {clock_raw} '
                        f'!= final peek of $BF90-93 {bf90} -- something '
                        f'touched the clock between them')

    prodos.mount(DISK, readonly=True)
    try:
        sumout = prodos.read(f'/mnt/{VOL}/SUMOUT')
        dateout = prodos.read(f'/mnt/{VOL}/DATEOUT')
        dateerr = prodos.read(f'/mnt/{VOL}/DATEERR')
    finally:
        prodos.unmount(VOL)

    if sumout != EXPECT_SUMOUT:
        failures.append(f'{label}: SUMOUT mismatch -- expected '
                        f'{EXPECT_SUMOUT!r}, got {sumout!r}')

    expect_dateout = decode_date(clock_raw)
    if expect_dateout is not None:
        if date_status != 0:
            failures.append(f'{label}: clock reading was VALID '
                            f'{clock_raw} but date exited '
                            f'${date_status:02X}, expected $00')
        if dateout != expect_dateout:
            failures.append(f'{label}: DATEOUT expected '
                            f'{expect_dateout!r}, got {dateout!r}')
        if dateerr != b'':
            failures.append(f'{label}: DATEERR expected empty on a '
                            f'valid clock reading, got {dateerr!r}')
    else:
        if date_status != 1:
            failures.append(f'{label}: clock reading was INVALID/ABSENT '
                            f'{clock_raw} but date exited '
                            f'${date_status:02X}, expected $01')
        if dateout != b'':
            failures.append(f'{label}: DATEOUT expected empty when the '
                            f'clock is invalid/absent, got {dateout!r}')
        if dateerr != NOCLKMSG:
            failures.append(f'{label}: DATEERR expected {NOCLKMSG!r}, '
                            f'got {dateerr!r}')

    return failures, clock_raw, expect_dateout is not None, sumout


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}',
              file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make sumdate-image first',
              file=sys.stderr)
        return 2

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    all_failures = []
    try:
        client.initialize()

        failures_a, raw_a, valid_a, _ = run_session(
            client, True, 'clock=True')
        all_failures += failures_a

        # Rebuild fresh -- session A's CREATE calls left SUMOUT/
        # DATEOUT/DATEERR on the disk; a second CREATE of the same
        # name would fail with a spurious P_ERR, not a real bug.
        rc = build_sumdate_image.main()
        if rc != 0:
            all_failures.append(f'rebuild between sessions failed '
                                f'(exit {rc})')

        failures_b, raw_b, valid_b, _ = run_session(
            client, False, 'clock=False')
        all_failures += failures_b

        if valid_a is not True:
            all_failures.append(
                f'clock=True session did not produce a VALID reading '
                f'({raw_a}) -- the "clock present" path was never '
                f'exercised')
        if valid_b is not False:
            all_failures.append(
                f'clock=False session did not produce an INVALID/'
                f'ABSENT reading ({raw_b}) -- the "clock absent" '
                f'path was never exercised')

        if all_failures:
            for failure in all_failures:
                print(f'[check-sumdate] FAIL: {failure}', file=sys.stderr)
            return 1

        print('[check-sumdate] PASS: sum -- empty/one-byte/block-'
              'crossing files, hand-computed rotate checksums, all in '
              'one invocation -- byte-exact; date -- a real clock '
              'reading printed correctly, and the absent-clock case '
              'refused on fd 2 with exit 1, both verified against the '
              'kernel\'s own raw SYS_CLOCK read, not a wall clock')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
