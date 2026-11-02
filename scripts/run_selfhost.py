#!/usr/bin/env python3
"""run_selfhost.py -- boot build/mauxbig.po to completion and verify the
self-hosting strip's one hard invariant (docs/PERF-PLAN.md sec 1):
/mnt/MAUX/ECHO.OBJ, assembled BY MAUX from the tree maux itself stripped,
is byte-identical to merlin32's build/echo.bin.

NOT in check-all (the run is minutes even on the fast backend); this is
the plan's own "cheap check after any step":

    python3 scripts/build_bigdisk_image.py && python3 scripts/run_selfhost.py

Also prints the cycle count at completion, which is the before/after
number every PERF-PLAN step is judged by. Detection granularity is one
step chunk (default 20M cycles, ~1% of the baseline run), so treat
small deltas accordingly.

Boot/poll loop is profile_selfhost.py's (same sentinel: astestb.s's
R_DONE at $1260 aux bank 1, $AA=clean $EE=P_ERR); the read-back is
check_as.py's (a2til.open_image on the emulator-mutated image -- the
fast backend writes the .po in place).
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR
import a2til
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMG = os.path.join(ROOT, 'build', 'mauxbig.po')
REF = os.path.join(ROOT, 'build', 'echo.bin')
BUDGET = int(os.environ.get('BUDGET', 3_200_000_000))
CHUNK = int(os.environ.get('CHUNK', 20_000_000))
R_DONE = 0x1260
R_ERR = 0x1261
R_STEP = 0x1262

env = dict(os.environ)
env['VERILOGAPPLE_ROMS'] = ROMS_DIR
c = MCPClient([SUPERVISOR], env)
c.initialize()
c.call_tool('reset', {'backend': 'fast'})
for u in range(1, 7):
    c.call_tool('eject_disk', {'unit': u})
c.call_tool('mount_disk', {'path': IMG})

at = 0
done = 0
while at < BUDGET:
    c.call_tool('step', {'cycles': CHUNK})
    at += CHUNK
    d = c.call_tool('peek', {'addr': R_DONE, 'count': 3,
                             'bank': 'aux', 'aux_bank': 1})['bytes']
    if d[0] in (0xAA, 0xEE):
        done = d[0]
        break
c.close()

if not done:
    print(f'[run-selfhost] FAIL: no completion sentinel within {at:,} cycles',
          file=sys.stderr)
    sys.exit(1)
print(f'[run-selfhost] sentinel ${done:02X} at ~{at:,} cycles '
      f'({at/1.023e6/60:.1f} min at 1.023 MHz; R_ERR=${d[1]:02X} '
      f'R_STEP=${d[2]:02X})')
if done == 0xEE:
    print('[run-selfhost] FAIL: harness parked in P_ERR', file=sys.stderr)
    sys.exit(1)

if os.environ.get('NOAS'):
    print('[run-selfhost] NOAS run: strip only, no ECHO.OBJ to verify')
    sys.exit(0)
vol = a2til.open_image(IMG)
try:
    got = bytes(vol.read_file('/mnt/MAUX/ECHO.OBJ'))
except FileNotFoundError:
    print('[run-selfhost] FAIL: /mnt/MAUX/ECHO.OBJ does not exist -- the '
          'assembly never wrote it', file=sys.stderr)
    sys.exit(1)
ref = open(REF, 'rb').read()
if got != ref:
    ndiff = sum(1 for x, y in zip(got, ref) if x != y)
    print(f'[run-selfhost] FAIL: ECHO.OBJ differs from merlin32 in '
          f'{ndiff} byte(s) (lengths {len(got)} vs {len(ref)})',
          file=sys.stderr)
    sys.exit(1)
print(f'[run-selfhost] PASS: ECHO.OBJ byte-identical to merlin32 '
      f'({len(got)}B)')
