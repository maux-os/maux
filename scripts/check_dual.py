#!/usr/bin/env python3
"""check_dual.py -- task #7's dual-assembly gate.

    make check-dual

Assembles the maux kernel TWICE -- once with merlin32 on the host, once with
real Merlin-8 2.59 running on the emulated //e -- and requires the two images
to be byte-identical.

WHY THIS IS THE REAL GATE. Everything else in this tree checks maux against a
MODEL of Merlin: a line-length rule, a label-length rule, a module-boundary
scanner. Each of those was written from measurement and each was, at some
point, wrong or incomplete. This gate has no model in it. Real Merlin either
reads the tree or it does not.

It is also what task #8 stands on: maux cannot host Merlin assembling its own
source until real Merlin can assemble that source at all.

WHAT IT TAKES TO KEEP PASSING (all of these were found the hard way):
  * every module under Merlin's source buffer, and the top-level a thin
    MANIFEST -- the buffer holds the resident top-level AND the PUT file
    together (learning:01M051EM2HQ3ZVJTR1W9P3G86J)
  * labels <= 13 characters (learning:01M050C6KW01MPJ2TQTPMTZXN6)
  * lines <= 64 characters (learning:01M04SAJTJAYXCR3YNFW313FMZ)
  * no parentheses, no operator precedence
    (learning:01M051DJW89KV4JYM1EC9SDZ5Y)
  * no EQU defined after its first reference, and EQUs hoisted to a file head
    rather than mid-routine -- a global label ends the local-label scope
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import a2til  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MERLIN = os.path.join(ROOT, 'build', 'merlinsrc.po')
MAUX = os.path.join(ROOT, 'build', 'mauxsrc.po')
MANIFEST = 'DUAL'                 # pipewraptest.s: the leanest kernel manifest
                                  # (build_maux_src_image.py UNITS says why)
OBJECT = '/mnt/MAUXSRC/OBJ'
HOST_OBJ = os.path.join(ROOT, 'build', 'pipewraptest.bin')
MENU = 'L :Load source'


def screen(c):
    return '\n'.join(c.call_tool('screen_text', {}).get('merged', []))


def assemble_on_hardware():
    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    c = MCPClient([SUPERVISOR], env)
    try:
        c.initialize()
        for unit in range(1, 7):
            c.call_tool('eject_disk', {'unit': unit})
        c.call_tool('reset', {'backend': 'fast'})
        c.call_tool('mount_disk', {'path': MERLIN})
        c.call_tool('mount_disk', {'path': MAUX})
        for _ in range(40):
            c.call_tool('step', {'cycles': 2_000_000})
            if MENU in screen(c):
                break
        else:
            raise RuntimeError(f'Merlin did not boot; screen:\n{screen(c)}')
        for _ in range(5):
            c.call_tool('step', {'cycles': 3_000_000})
        c.call_tool('type', {'text': f'L/MAUXSRC/{MANIFEST}\r'})
        for _ in range(10):
            c.call_tool('step', {'cycles': 3_000_000})
        c.call_tool('type', {'text': 'ASM\r'})
        # LST OFF means the screen does NOT change while assembling, so
        # quiescence is not a completion signal here -- poll for the marker.
        # Wait for 'Errors:' specifically, not the earlier substring 'End
        # assembly' -- the banner ("--End assembly, NNNN bytes, Errors: N")
        # prints incrementally, and polling can catch it mid-print (e.g.
        # "--End assembly, 14" before "336 bytes, Errors: 0" has drawn),
        # which reads as a truncated/garbled line. 'Errors:' is the last
        # token on that line, so seeing it means the whole banner is on
        # screen. Found the hard way (2026-08-20, syscall.equ/errno.equ
        # split task): intermittent false "real Merlin reported errors"
        # failures on an otherwise-correct 0-error, byte-identical run.
        for _ in range(500):
            c.call_tool('step', {'cycles': 8_000_000})
            s = screen(c)
            if 'Errors:' in s or 'MEMORY IN USE' in s:
                line = next(l.strip() for l in s.splitlines()
                            if 'End assembly' in l or 'MEMORY IN USE' in l)
                # Settle a moment more before closing the connection: the
                # DSK output file's directory entry (length/EOF) is only
                # guaranteed flushed to the HOST disk-image file a short
                # while after the on-screen banner appears -- closing
                # immediately on detection was observed to read back a
                # 0-byte object file even though the assembly itself
                # completed cleanly (same root cause as the banner race
                # above: screen state and backing-store state are not
                # updated atomically).
                for _ in range(20):
                    c.call_tool('step', {'cycles': 2_000_000})
                return line
        raise RuntimeError(f'assembly did not finish; screen:\n{screen(c)}')
    finally:
        c.close()


def main():
    for p in (SUPERVISOR, MERLIN, MAUX):
        if not os.path.exists(p):
            print(f'error: missing {p} -- run `make merlin-src-image` and '
                  f'`python3 scripts/build_maux_src_image.py` first',
                  file=sys.stderr)
            return 2
    if not os.path.exists(HOST_OBJ):
        print(f'error: {HOST_OBJ} not built -- run merlin32 on '
              f'src/test/pipewraptest.s first', file=sys.stderr)
        return 2

    # Task #7's configuration invariant, asserted on the volume this very
    # run boots from: the PARMS 80-column byte must be $83. $C3 sets the
    # V-bit, which relocates ProDOS into AUX memory -- and aux is maux's
    # process space, one bank per process, so a $C3 Merlin would scribble
    # on live process banks (learning:01M041MZER5YQJQYR7JP5N7F01, PARMS.S
    # source comment). check-dialect asserts the same byte statically.
    # build_merlin_src_image.py stages PARMS only when the v2.58 source
    # disk is available and stages NOTHING otherwise -- and without a
    # PARMS the boot below would stall on the editor's "Update source"
    # prompt anyway. Fail cleanly instead of crashing with a traceback
    # (review finding N4, 2026-08-23).
    try:
        parms = a2til.open_image(MERLIN).read_file('/SOURCE/PARMS')
    except FileNotFoundError:
        print(f'[check-dual] FAIL: {MERLIN} carries no /SOURCE/PARMS -- '
              f'build_merlin_src_image.py could not find the v2.58 Merlin '
              f'disk to borrow it from, and without PARMS the build is '
              f'not unattended (the editor stops at "Update source"). '
              f'See build_merlin_src_image.py\'s PARMS section for the '
              f'source disk it needs.', file=sys.stderr)
        return 2
    if parms[4] != 0x83:
        print(f'[check-dual] FAIL: /SOURCE/PARMS byte 4 on '
              f'{MERLIN} is ${parms[4]:02X}, want $83 -- a $C3 V-bit '
              f'moves ProDOS into aux memory, which maux owns',
              file=sys.stderr)
        return 1
    print('[check-dual] PARMS 80-column byte on the boot volume: $83')

    print('[check-dual] assembling the kernel under real Merlin-8 2.59')
    line = assemble_on_hardware()
    print(f'[check-dual]   {line}')
    if 'Errors: 0' not in line:
        print('[check-dual] FAIL: real Merlin reported errors', file=sys.stderr)
        return 1

    vol = a2til.open_image(MAUX)
    m8 = vol.read_file(OBJECT)
    m32 = open(HOST_OBJ, 'rb').read()
    print(f'[check-dual] real Merlin-8 {len(m8)} bytes, '
          f'merlin32 {len(m32)} bytes')
    if m8 == m32:
        print('[check-dual] PASS: the two assemblers produce a BYTE-IDENTICAL '
              'maux kernel -- task #7')
        return 0
    diffs = [i for i, (a, b) in enumerate(zip(m8, m32)) if a != b]
    print(f'[check-dual] FAIL: {len(diffs)} differing byte(s), '
          f'length {len(m8)} vs {len(m32)}', file=sys.stderr)
    for i in diffs[:12]:
        print(f'    +${i:04X}: merlin8 ${m8[i]:02X}  merlin32 ${m32[i]:02X}',
              file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
