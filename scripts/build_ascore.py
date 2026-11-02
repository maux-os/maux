#!/usr/bin/env python3
"""build_ascore.py -- task #8 phase B: assemble the PATCHED Merlin core
from source using real Merlin-8 2.59, unattended (`make ascore`).

Reuses scripts/check_merlin_build.py's proven driving technique (screen()/
wait()/settle() helpers, same STEPBYSTEP sequence) but stops short of the
full four-module rebuild: the maux `as` core is ASMOBJ/PROASM.BANK1 +
ASMOBJ/AS (the assembler proper, produced by assembling MACASS.S alone --
see docs/AS-DESIGN.md section 3, "the core artifact contains ASSMAIN/
MACASS and friends, never MACED"). MACED/MACEXEC/INTERPRETER stay stock
and unassembled here; they exist on the image only so the volume boots to
a working `%`/`:` environment that can drive `L`/`ASM`.

Sequence: boot ascore.po -> `D BRUN PACKOP2` (patches the opcode table in
memory; required before MACASS.S assembles, same as check-merlin) ->
`L MACASS` -> `ASM` -> MACASS.S's own `DO SAVOBJ / SAV ASMOBJ/PROASM.BANK1`
and `.../SAV ASMOBJ/AS` directives write the two core files to disk.

Artifacts: build/ascore.bank1.bin (ASMOBJ/PROASM.BANK1, loads at $D000)
and build/ascore.as.bin (ASMOBJ/AS, loads at $E5F0) -- both WITHOUT their
2-byte ProDOS BSAVE address/length prefix stripped by a2til's read_file
(raw file payload only). check_ascore.py loads both into the same
addresses at runtime to reconstruct the live core image.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import a2til  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'ascore.po')
BANK1_OUT = os.path.join(ROOT, 'build', 'ascore.bank1.bin')
AS_OUT = os.path.join(ROOT, 'build', 'ascore.as.bin')

MENU = 'L :Load source'


def screen(c):
    return '\n'.join(c.call_tool('screen_text', {}).get('merged', []))


def wait(c, marker, tries=140, cycles=4_000_000):
    for _ in range(tries):
        c.call_tool('step', {'cycles': cycles})
        if marker in screen(c):
            return screen(c)
    raise RuntimeError(f'timed out waiting for {marker!r}; screen:\n'
                       f'{screen(c)}')


def settle(c, passes=5):
    for _ in range(passes):
        c.call_tool('step', {'cycles': 3_000_000})


def wait_quiet(c, stable=3, tries=200, cycles=4_000_000):
    last, same = None, 0
    for _ in range(tries):
        c.call_tool('step', {'cycles': cycles})
        now = screen(c)
        same = same + 1 if now == last else 0
        last = now
        if same >= stable:
            return now
    return last


def disk_command(c, cmd):
    c.call_tool('type', {'text': 'D'})
    wait(c, 'Disk command')
    c.call_tool('type', {'text': f'{cmd}\r'})
    wait_quiet(c)
    c.call_tool('type', {'text': '\r'})
    wait(c, MENU)
    settle(c, 2)


def assemble(c, name):
    c.call_tool('type', {'text': f'L{name}\r'})
    wait(c, 'Editor')
    settle(c)
    c.call_tool('type', {'text': 'ASM\r'})
    s = wait(c, 'End assembly')
    line = next(l.strip() for l in s.splitlines() if 'End assembly' in l)
    wait_quiet(c)
    c.call_tool('type', {'text': 'Q\r'})
    wait(c, MENU)
    settle(c, 2)
    return line


def main():
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}', file=sys.stderr)
        return 2
    if not os.path.exists(DISK):
        print(f'error: {DISK} not found -- run `make ascore-image` first',
              file=sys.stderr)
        return 2

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    c = MCPClient([SUPERVISOR], env)
    try:
        c.initialize()
        for unit in range(1, 7):
            c.call_tool('eject_disk', {'unit': unit})
        c.call_tool('reset', {'backend': 'fast'})
        r = c.call_tool('mount_disk', {'path': os.path.abspath(DISK)})
        if r.get('unit') != 1 or r.get('unit_count') != 1:
            raise RuntimeError(f'expected a lone image on unit 1, got {r}')
        wait(c, MENU)
        settle(c)
        print('[build-ascore] booted; assembling the patched core from '
              'source')

        disk_command(c, 'BRUN PACKOP2')
        print('[build-ascore]   BRUN PACKOP2 (opcode table patched)')
        line = assemble(c, 'MACASS')
        print(f'[build-ascore]   MACASS       {line}')
        if 'Errors: 0' not in line:
            print(f'[build-ascore] FAIL: patched MACASS.S reported errors: '
                  f'{line!r}', file=sys.stderr)
            return 1
    finally:
        c.close()

    vol = a2til.open_image(DISK)
    bank1 = vol.read_file('/SOURCE/ASMOBJ/PROASM.BANK1')
    as_obj = vol.read_file('/SOURCE/ASMOBJ/AS')
    open(BANK1_OUT, 'wb').write(bank1)
    open(AS_OUT, 'wb').write(as_obj)
    print(f'[build-ascore] ASMOBJ/PROASM.BANK1  {len(bank1):>6}B -> '
          f'{BANK1_OUT}')
    print(f'[build-ascore] ASMOBJ/AS            {len(as_obj):>6}B -> '
          f'{AS_OUT}')
    print('[build-ascore] PASS: patched core assembled from source by '
          'real Merlin-8 2.59, 0 errors')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
