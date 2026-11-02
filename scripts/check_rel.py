#!/usr/bin/env python3
"""check_rel.py -- task #8a regression gate: Merlin's linker includes WHOLE
modules, so `src/liba` must be many small REL modules.

Assembles two REL modules under real Merlin-8 2.59 and links them:

    RTLIB    ONE module, TWO exports -- LIBUSED (3 bytes) and LIBUNUSED
             (65 bytes of a searchable $DE $AD $BE $EF pattern). 68 bytes.
    RTMAIN   4 bytes. EXT LIBUSED, calls it, never mentions LIBUNUSED.

and asserts the linked output is the SUM of both modules with the unreferenced
routine physically present. If a future Merlin/toolchain change ever started
dropping unused routines this gate would fail, and the liba packaging policy
in docs/REL-LIBA-SPIKE.md would need revisiting -- which is exactly why the
finding is pinned here rather than left as prose.

Needs `make rel-image` (and `make vendor-merlin` before that).

DRIVING NOTE: Merlin's screen is not cleared between operations, so waiting on
a marker that is already on screen returns instantly and desynchronises the
whole sequence. Every step here waits for a marker AND, where the previous
step left that marker up, for the old one to disappear. Entering the editor
and returning to the menu both redraw, which is what makes the sequence
deterministic. Guest commands also get settle time -- a Load issued too early
returns a bogus "4A MLI ERROR".
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = os.path.join(ROOT, 'build', 'rel.po')

LINK_ADDR = 0x2000       # relocation base handed to LINK
IMAGE_AT = 0x0900        # where LINKER.S actually builds the image
EXPECT_BYTES = 72        # RTMAIN 4 + RTLIB 68
PATTERN = [0xDE, 0xAD, 0xBE, 0xEF]
EXPECT_HITS = 16

# A line unique to the MENU. The splash screen also says "MERLIN-8".
MENU_MARKER = 'L :Load source'


def screen(c):
    return '\n'.join(c.call_tool('screen_text', {}).get('merged', []))


def wait(c, marker, gone=None, tries=60, cycles=2_000_000):
    for _ in range(tries):
        c.call_tool('step', {'cycles': cycles})
        s = screen(c)
        if marker in s and (gone is None or gone not in s):
            return s
    raise RuntimeError(f'timed out waiting for {marker!r}'
                       f'{f" (with {gone!r} gone)" if gone else ""}; screen:\n'
                       f'{screen(c)}')


def settle(c, passes=4):
    for _ in range(passes):
        c.call_tool('step', {'cycles': 2_000_000})


def set_prefix(c, prefix):
    """Set the ProDOS prefix via the menu's Disk command.

    Absolute paths given straight to Load are NOT reliable here: from a fresh
    boot `L/SOURCE/RELSPIKE/RTLIB` returns "4A MLI ERROR", the same load
    succeeds after some other load has happened, and a third can return "44
    DIRECTORY NOT FOUND" -- i.e. Merlin resolves them against its own prefix
    state in a way that is order-dependent. Setting the prefix once and then
    loading BARE names is how Merlin is documented to be driven (its own
    STEPBYSTEP says `L` then `INTERPRETER`), and it is deterministic.
    """
    c.call_tool('type', {'text': 'D'})
    wait(c, 'Disk command')
    c.call_tool('type', {'text': f'PREFIX {prefix}\r'})
    settle(c, 2)
    c.call_tool('type', {'text': '\r'})          # bare Enter leaves the loop
    wait(c, MENU_MARKER)
    settle(c, 2)


def assemble(c, name):
    """From the menu: load NAME.S, assemble it, return to the menu."""
    c.call_tool('type', {'text': f'L{name}\r'})
    wait(c, 'Editor')
    settle(c)
    c.call_tool('type', {'text': 'ASM\r'})
    wait(c, 'Update source')
    c.call_tool('type', {'text': 'N'})
    s = wait(c, 'End assembly')
    line = next(l.strip() for l in s.splitlines() if 'End assembly' in l)
    # "End assembly" prints BEFORE the symbol tables do. Typing into that
    # window gets the keystroke swallowed by the still-running listing, so
    # let it drain before quitting back to the menu.
    settle(c, 6)
    c.call_tool('type', {'text': 'Q\r'})
    # No `gone=` guard here: returning to the menu redraws the menu but does
    # NOT clear the whole screen, so the previous assembly's summary lingers
    # and any such guard would never come true. Safe anyway -- the editor
    # screen contains no menu line, and the next Load fully clears, so the
    # following 'End assembly' wait cannot match a stale one.
    wait(c, MENU_MARKER)
    return line


def main():
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}', file=sys.stderr)
        return 2
    if not os.path.exists(DISK):
        print(f'error: {DISK} not found -- run `make rel-image` first',
              file=sys.stderr)
        return 2

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    c = MCPClient([SUPERVISOR], env)
    failures = []
    try:
        c.initialize()
        # reset does NOT eject SmartPort media and mount_disk adds to the next
        # free unit, so a stale image would keep booting. Clear every unit.
        for unit in range(1, 7):
            c.call_tool('eject_disk', {'unit': unit})
        c.call_tool('reset', {'backend': 'fast'})
        r = c.call_tool('mount_disk', {'path': os.path.abspath(DISK)})
        if r.get('unit') != 1 or r.get('unit_count') != 1:
            raise RuntimeError(f'expected a lone image on unit 1, got {r}')
        # NOT 'MERLIN-8' -- that string is on the SPLASH screen too, and
        # matches after a single step, long before the menu draws. Wait
        # for a line only the menu has.
        wait(c, MENU_MARKER)
        settle(c)
        print('[check-rel] Merlin-8 2.59 booted to its menu')
        # The boot prefix is already /SOURCE/ and the spike files live at
        # the volume root, so bare names resolve -- which is also the only
        # form Merlin handles deterministically (see set_prefix's note).

        for name, want in (('RTLIB', 68), ('RTMAIN', 4)):
            line = assemble(c, name)
            print(f'[check-rel] {name:<7} {line}')
            if f'{want} bytes' not in line:
                failures.append(f'{name}: expected {want} bytes, got {line!r}')
            if 'Errors: 0' not in line:
                failures.append(f'{name}: assembly reported errors: {line!r}')

        # LINK requires an EMPTY source buffer (MACED.S compares SOURCE with
        # ENDSRC), hence NEW first.
        c.call_tool('type', {'text': 'E'})
        wait(c, 'Editor')
        settle(c)
        c.call_tool('type', {'text': 'NEW\r'})
        settle(c, 2)
        c.call_tool('type', {'text': f'LINK ${LINK_ADDR:04X},RTNAMES\r'})
        s = wait(c, 'Errors:')
        link_line = next(l.strip() for l in s.splitlines() if 'Errors:' in l)
        print(f'[check-rel] link: {link_line}')

        if f'{EXPECT_BYTES} bytes' not in link_line:
            failures.append(f'linked size: expected {EXPECT_BYTES} bytes '
                            f'(4 + 68, the sum of both modules), got '
                            f'{link_line!r}')
        if 'Errors: 0' not in link_line:
            failures.append(f'link reported errors: {link_line!r}')
        # The unreferenced routine getting a load address at all is the
        # finding: the linker placed a module nothing calls into.
        if 'LIBUNUSED' not in s:
            failures.append('LIBUNUSED absent from the link map -- the linker '
                            'may have started eliminating unused routines, '
                            'which would invalidate the liba packaging policy '
                            'in docs/REL-LIBA-SPIKE.md')

        mem = c.call_tool('peek', {'addr': IMAGE_AT, 'count': EXPECT_BYTES,
                                   'bank': 'main'})['bytes']
        hits = sum(1 for i in range(len(mem) - 3)
                   if mem[i:i + 4] == PATTERN)
        print(f'[check-rel] $DEADBEEF in linked image: {hits}/{EXPECT_HITS}')
        if hits != EXPECT_HITS:
            failures.append(f'expected {EXPECT_HITS} DEADBEEF patterns in the '
                            f'linked image at ${IMAGE_AT:04X}, found {hits}')

        if failures:
            for f in failures:
                print(f'[check-rel] FAIL: {f}', file=sys.stderr)
            return 1

        # Export the two real-Merlin REL objects as REFERENCE artifacts
        # for check-as's REL cases (S9 REL route, docs/S9-PLAN.md sec 6
        # L0): `as` assembling the SAME sources must reproduce these
        # byte-for-byte, dictionary included, with the same ProDOS type
        # ($F8) and aux (= code length). merlin32 cannot make these --
        # its `rel` output is GS/OS OMF -- so real Merlin's own output,
        # produced by THIS gate's run, is the only reference there is.
        # The objects live only on build/rel.po and rel-image rebuilds
        # that from sources (erasing them), so they are exported here,
        # at the moment they are known good.
        import json
        sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
        from a2til import prodos
        import vpath  # noqa: F401  (docs/VROOT.md)
        vol = prodos.mount(DISK, replace=True, readonly=True)
        try:
            meta = {}
            for name in ('RTLIB', 'RTMAIN'):
                path = f'/mnt/{vol}/{name}'
                ent = prodos.stat(path)
                data = prodos.read(path)
                out = os.path.join(ROOT, 'build', f'{name.lower()}.rel')
                with open(out, 'wb') as fh:
                    fh.write(data)
                meta[name.lower()] = {'type': ent.type,
                                      'aux': ent.aux_type,
                                      'len': len(data)}
                print(f'[check-rel] reference exported: {out} '
                      f'({len(data)}B, type ${ent.type:02X}, '
                      f'aux ${ent.aux_type:04X})')
            with open(os.path.join(ROOT, 'build', 'rel-meta.json'),
                      'w') as fh:
                json.dump(meta, fh, indent=1)
        finally:
            prodos.unmount(vol)

        print('[check-rel] PASS: linked output is the exact sum of both '
              'modules and contains a routine nothing references -- Merlin '
              'links WHOLE modules, so liba must be many small ones')
        return 0
    finally:
        c.close()


if __name__ == '__main__':
    raise SystemExit(main())
