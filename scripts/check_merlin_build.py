#!/usr/bin/env python3
"""check_merlin_build.py -- rebuild Merlin from its own source, unattended,
and byte-compare the result against the shipped binary (`make check-merlin`).

Task #7's foundation. This is the instrument that lets REAL Merlin judge
source, rather than a model of Merlin judging it -- the same gap a2til had,
where its own `check` passed a volume ProDOS rejects.

Follows the disk's own STEPBYSTEP, minus every interactive answer (see
build_merlin_src_image.py: KBD prompts are now constants and PARMS suppresses
the editor's one runtime question):

    L INTERPRETER / ASM      -> SAV INTERPRETER
    L MACED       / ASM      -> SAV ASMOBJ/ED
    L MACEXEC     / ASM      -> SAV ASMOBJ/EX
    D  BRUN PACKOP2          (patches the opcode table; required before MACASS)
    L MACASS      / ASM      -> SAV ASMOBJ/PROASM.BANK1, ASMOBJ/AS
    D  BRUN SAVE/MERLIN      (binds the four objects into MERLIN.SYSTEM)

then compares /SOURCE/MERLIN.SYSTEM against /SOURCE/SAVE/MERLIN.SYSTEM.

ON REPRODUCIBILITY: Willi Kusche's READMEFIRST records that SAVE/MERLIN emits
two pairs of five RANDOM bytes between some object modules, and that he
appended five bytes each to MACASS.S and MACEXEC.S so it stops. Those appends
are already in the sources this gate uses (they ship on VALIDATE.PO), and
build_merlin_src_image.py is byte-preserving precisely so they survive. If
this comparison ever fails on a handful of scattered bytes rather than
wholesale, suspect that mechanism before suspecting the assembler.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import a2til  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'merlinsrc.po')

MENU = 'L :Load source'
BUILT = '/SOURCE/MERLIN.SYSTEM'
REFERENCE = '/SOURCE/SAVE/MERLIN.SYSTEM'


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
    """Run until the screen stops changing.

    A fixed settle is not enough here: "End assembly" prints BEFORE the symbol
    tables, and INTERPRETER.S has thousands of symbols, so the listing can run
    far longer than any constant you would guess. Typing into that window gets
    the keystroke eaten. Waiting for quiescence scales with the actual job.
    """
    last, same = None, 0
    for _ in range(tries):
        c.call_tool('step', {'cycles': cycles})
        now = screen(c)
        same = same + 1 if now == last else 0
        last = now
        if same >= stable:
            return now
    return last


def assemble(c, name):
    c.call_tool('type', {'text': f'L{name}\r'})
    wait(c, 'Editor')
    settle(c)
    c.call_tool('type', {'text': 'ASM\r'})
    s = wait(c, 'End assembly')
    line = next(l.strip() for l in s.splitlines() if 'End assembly' in l)
    wait_quiet(c)          # let the symbol-table listing finish
    c.call_tool('type', {'text': 'Q\r'})
    wait(c, MENU)
    settle(c, 2)
    return line


def disk_command(c, cmd):
    c.call_tool('type', {'text': 'D'})
    wait(c, 'Disk command')
    c.call_tool('type', {'text': f'{cmd}\r'})
    wait_quiet(c)
    c.call_tool('type', {'text': '\r'})        # bare Enter exits the loop
    wait(c, MENU)
    settle(c, 2)


def main():
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}', file=sys.stderr)
        return 2
    if not os.path.exists(DISK):
        print(f'error: {DISK} not found -- run `make merlin-src-image` first',
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
        print('[check-merlin] booted; building Merlin from source')

        for name in ('INTERPRETER', 'MACED', 'MACEXEC'):
            print(f'[check-merlin]   {name:<12} {assemble(c, name)}')
        disk_command(c, 'BRUN PACKOP2')
        print('[check-merlin]   BRUN PACKOP2 (opcode table patched)')
        print(f'[check-merlin]   {"MACASS":<12} {assemble(c, "MACASS")}')
        disk_command(c, 'BRUN SAVE/MERLIN')
        print('[check-merlin]   BRUN SAVE/MERLIN (objects bound)')
    finally:
        c.close()

    vol = a2til.open_image(DISK)
    built = vol.read_file(BUILT)
    ref = vol.read_file(REFERENCE)
    print(f'[check-merlin] built {len(built)} bytes vs shipped {len(ref)} bytes')
    if built == ref:
        print('[check-merlin] PASS: MERLIN.SYSTEM rebuilt from source is '
              'BYTE-IDENTICAL to the shipped binary -- real Merlin can now be '
              'driven as a build tool, unattended and verifiably')
        return 0

    if len(built) != len(ref):
        print(f'[check-merlin] FAIL: length differs by '
              f'{len(built) - len(ref):+d} bytes', file=sys.stderr)
    diffs = [i for i, (a, b) in enumerate(zip(built, ref)) if a != b]
    print(f'[check-merlin] FAIL: {len(diffs)} differing byte(s)',
          file=sys.stderr)
    for i in diffs[:12]:
        print(f'    +${i:04X}: built ${built[i]:02X}  shipped ${ref[i]:02X}',
              file=sys.stderr)
    if 0 < len(diffs) <= 40:
        print('    A handful of scattered bytes is the signature of the '
              'SAVE/MERLIN random-padding issue -- see this file\'s header '
              'before suspecting the assembler.', file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
